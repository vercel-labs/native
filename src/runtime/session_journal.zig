//! Deterministic session journal: the on-disk format for record/replay.
//!
//! A Native SDK session IS three things — the app's deterministic init,
//! the platform-event sequence, and the effect results that crossed the
//! effect boundary. This module makes that literal: a journal file holds
//! a session header, every dispatched platform event (payload + implicit
//! ordinal), every effect RESULT the drain delivered to `update` (fetch
//! response bytes, subprocess lines and exits, file reads, clipboard
//! reads), and verification checkpoints (state fingerprints per published
//! frame, plus pixel hashes at screenshot marks). Replaying the journal
//! through the same dispatch path — with effects stubbed from the
//! journaled results, so no process, network, file, or clipboard is
//! touched — reproduces the same model states.
//!
//! THE INIT CONTRACT (v1, loud on purpose): the initial model is NOT
//! serialized. Replay re-runs the app's own model init and `init_fx`,
//! which therefore MUST be deterministic — a fixed default model, no
//! clock/random/OS reads outside the effect boundary. Init-time effects
//! are fine: their results are journaled like any other effect result.
//! An app that computes init state from the wall clock or randomness
//! directly (instead of deriving it from event timestamps or effect
//! results) will replay divergent, and the fingerprint checkpoints will
//! say so at the first differing frame.
//!
//! Format (the wire-packet precedent: length-prefixed little-endian
//! binary, explicit budgets, hostile input fails loudly):
//!
//!   magic "NSDKSJNL" | u32 format version | records...
//!
//! Every record is `u8 kind | u32 payload_len | payload`. The first
//! record must be the header; the last must be the end record, whose
//! counts prove the journal was not truncated mid-stream. Unknown record
//! kinds, over-budget lengths, and short payloads are teaching errors —
//! never a crash, never a hang, never a silently partial replay.
//!
//! Ordering invariant: effect-result records precede the event record
//! during whose dispatch they were drained (the recorder stages the
//! event and commits it after dispatch). Replaying records in file order
//! therefore feeds each result into the stub executor before the event
//! that consumes it. Nested dispatches (automation-driven events inside
//! `frame_requested`) commit innermost-first for the same reason.
//!
//! Enum payloads ride as their declaration-order integer values, so
//! reordering any journaled enum is a format break: bump
//! `format_version` when one moves.
//!
//! Coverage note: automation driving that synthesizes PLATFORM events is
//! fully journaled (widget-click/hold/context-press/drag/wheel/key,
//! widget-action press/toggle/increment/decrement/set_text, resize,
//! menu-command, shortcut, tray-action). The few automation verbs that
//! mutate runtime widget state directly (widget-action
//! focus/select/set_selection and the composition edits) bypass the
//! platform boundary and do not journal in v1 — a recorded session using
//! them replays without those mutations, and the next fingerprint
//! checkpoint says so loudly. Drive text through `widget-key` and
//! selection through pointer/key input when recording.

const std = @import("std");
const geometry = @import("geometry");
const platform = @import("../platform/root.zig");
const automation_protocol = @import("../automation/protocol.zig");
const runtime_effects = @import("effects.zig");

pub const EffectResultRecord = runtime_effects.EffectResultRecord;

/// File magic: first eight bytes of every session journal.
pub const magic = "NSDKSJNL";

/// Journal format version. Any change to record layouts or journaled
/// enum orders bumps this; readers refuse other versions loudly rather
/// than misreading yesterday's shape. v2 added the stream `buffering`
/// flag to audio event and audio effect records; v3 added the spectrum
/// band bytes to both (and the `.spectrum` audio kind).
pub const format_version: u32 = 3;

// ------------------------------------------------------------- budgets
//
// Fixed, documented, loud (the canvas_limits house style): a journal
// over budget stops recording with a teaching error; a hostile file
// claiming an over-budget record is refused before a byte of payload is
// touched.

/// Maximum total journal size. Sized for hours of driven-session events
/// (an event record is tens of bytes; a frame tick well under 200) plus
/// realistic effect payloads (a 1 MiB file read is the largest single
/// result the effect system delivers).
pub const max_session_journal_bytes: usize = 128 * 1024 * 1024;

/// Maximum bytes of one record's payload. Bounded by the largest effect
/// payload (`max_effect_file_bytes`, 1 MiB) plus framing headroom; every
/// platform-event payload is far smaller.
pub const max_session_record_bytes: usize = runtime_effects.max_effect_file_bytes + 64 * 1024;

/// Maximum bytes of one staged EVENT record. Events are input-sized
/// (bridge messages are the largest realistic payload); effect results
/// have their own bound above.
pub const max_session_event_bytes: usize = 256 * 1024;

/// Maximum nesting depth of staged events (automation commands dispatch
/// platform events from inside `frame_requested`; deeper nesting than a
/// handful is a runtime bug, not a session shape).
pub const max_session_event_depth: usize = 8;

/// Maximum dropped-file paths one journaled `files_dropped` event keeps.
pub const max_session_drop_paths: usize = 32;

pub const JournalError = error{
    /// The file does not start with the session-journal magic — it is
    /// not a journal (or the first bytes were destroyed).
    JournalBadMagic,
    /// The journal was written by a different format version; replaying
    /// it here would misread payloads. Re-record with this build.
    JournalUnsupportedVersion,
    /// The byte stream ends mid-record (or the end record is missing):
    /// the recording was cut off — replay would silently stop early, so
    /// it refuses instead.
    JournalTruncated,
    /// A record's payload does not decode (unknown tags, short fields,
    /// impossible lengths): the file is damaged or hand-edited.
    JournalCorrupt,
    /// A record claims a payload beyond `max_session_record_bytes`.
    JournalRecordOverBudget,
    /// The first record is not the session header.
    JournalMissingHeader,
    /// The end record's counts disagree with the records actually read.
    JournalCountMismatch,
};

pub const RecordKind = enum(u8) {
    header = 1,
    event = 2,
    effect = 3,
    checkpoint = 4,
    screenshot = 5,
    end = 6,
};

/// Session identity, written once as the first record.
pub const Header = struct {
    /// The automation protocol version baked into the recording build —
    /// the existing CLI/app handshake, reused so a journal from a stale
    /// build is refused with the same teaching shape.
    protocol_version: u32 = automation_protocol.version,
    /// Recording platform ("macos", "linux", ...). Replay is
    /// same-platform in v1; a cross-platform journal is refused loudly.
    platform_name: []const u8,
    app_name: []const u8,
    /// Wall-clock ms at record start — provenance for humans, never
    /// consulted by replay.
    recorded_at_wall_ms: i64 = 0,
    /// Initial main-window geometry, for provenance and sanity checks.
    window_width: f32 = 0,
    window_height: f32 = 0,
};

/// A model-state fingerprint taken after the event with `event_ordinal`
/// finished dispatching (one per published frame): the Wyhash of the
/// runtime's accessibility snapshot text, which carries every window,
/// view, and widget's semantic state and none of the wall-clock or pid
/// noise the full snapshot header carries.
pub const Checkpoint = struct {
    event_ordinal: u64,
    frame_index: u64,
    fingerprint: u64,
};

/// A pixel checkpoint: an automation `screenshot` taken during the
/// recording marks the session with the deterministic reference
/// renderer's PNG hash; replay re-renders the same view at the same
/// scale and compares.
pub const ScreenshotMark = struct {
    event_ordinal: u64,
    view_label: []const u8,
    scale: f32,
    png_hash: u64,
    png_len: u64,
};

/// The final record: totals that prove the journal is whole.
pub const End = struct {
    event_count: u64,
    effect_count: u64,
    checkpoint_count: u64,
    screenshot_count: u64,
};

pub const Record = union(RecordKind) {
    header: Header,
    event: platform.Event,
    effect: EffectResultRecord,
    checkpoint: Checkpoint,
    screenshot: ScreenshotMark,
    end: End,
};

/// Decode scratch for payloads that need an outer slice (dropped-file
/// path lists). Owned by the Reader; decoded events reference it until
/// the next `next()` call.
pub const EventDecodeStorage = struct {
    drop_paths: [max_session_drop_paths][]const u8 = undefined,
};

// ------------------------------------------------------------ cursors

const WriteCursor = struct {
    buffer: []u8,
    len: usize = 0,

    fn remaining(self: *const WriteCursor) usize {
        return self.buffer.len - self.len;
    }

    fn writeBytes(self: *WriteCursor, bytes: []const u8) JournalError!void {
        if (bytes.len > self.remaining()) return error.JournalRecordOverBudget;
        @memcpy(self.buffer[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn writeByte(self: *WriteCursor, value: u8) JournalError!void {
        try self.writeBytes(&.{value});
    }

    fn writeBool(self: *WriteCursor, value: bool) JournalError!void {
        try self.writeByte(@intFromBool(value));
    }

    fn writeInt(self: *WriteCursor, comptime T: type, value: T) JournalError!void {
        var bytes: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, .little);
        try self.writeBytes(&bytes);
    }

    fn writeF32(self: *WriteCursor, value: f32) JournalError!void {
        try self.writeInt(u32, @bitCast(value));
    }

    fn writeEnum(self: *WriteCursor, value: anytype) JournalError!void {
        const int_value = @intFromEnum(value);
        if (int_value < 0 or int_value > std.math.maxInt(u8)) return error.JournalRecordOverBudget;
        try self.writeByte(@intCast(int_value));
    }

    fn writeStr(self: *WriteCursor, bytes: []const u8) JournalError!void {
        if (bytes.len > std.math.maxInt(u32)) return error.JournalRecordOverBudget;
        try self.writeInt(u32, @intCast(bytes.len));
        try self.writeBytes(bytes);
    }
};

const ReadCursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn readBytes(self: *ReadCursor, len: usize) JournalError![]const u8 {
        if (len > self.bytes.len - self.pos) return error.JournalCorrupt;
        const slice = self.bytes[self.pos .. self.pos + len];
        self.pos += len;
        return slice;
    }

    fn readByte(self: *ReadCursor) JournalError!u8 {
        return (try self.readBytes(1))[0];
    }

    fn readBool(self: *ReadCursor) JournalError!bool {
        return switch (try self.readByte()) {
            0 => false,
            1 => true,
            else => error.JournalCorrupt,
        };
    }

    fn readInt(self: *ReadCursor, comptime T: type) JournalError!T {
        const size = @divExact(@typeInfo(T).int.bits, 8);
        const bytes = try self.readBytes(size);
        return std.mem.readInt(T, bytes[0..size], .little);
    }

    fn readF32(self: *ReadCursor) JournalError!f32 {
        return @bitCast(try self.readInt(u32));
    }

    fn readEnum(self: *ReadCursor, comptime T: type) JournalError!T {
        return std.enums.fromInt(T, try self.readByte()) orelse error.JournalCorrupt;
    }

    fn readStr(self: *ReadCursor) JournalError![]const u8 {
        const len = try self.readInt(u32);
        return self.readBytes(len);
    }

    fn done(self: *const ReadCursor) bool {
        return self.pos == self.bytes.len;
    }
};

// ------------------------------------------------------- event codec
//
// Explicit stable tags per event variant (never `@intFromEnum` of the
// union tag, whose order is free to change).

const EventTag = enum(u8) {
    app_start = 1,
    app_activated = 2,
    app_deactivated = 3,
    appearance_changed = 4,
    frame_requested = 5,
    app_shutdown = 6,
    surface_resized = 7,
    window_frame_changed = 8,
    window_focused = 9,
    bridge_message = 10,
    tray_action = 11,
    shortcut = 12,
    native_command = 13,
    menu_command = 14,
    timer = 15,
    wake = 16,
    files_dropped = 17,
    gpu_surface_frame = 18,
    gpu_surface_resized = 19,
    gpu_surface_input = 20,
    gpu_surface_scroll_driver = 21,
    context_menu_action = 22,
    widget_accessibility_action = 23,
    audio = 24,
};

fn writeModifiers(cursor: *WriteCursor, modifiers: platform.ShortcutModifiers) JournalError!void {
    var bits: u8 = 0;
    if (modifiers.primary) bits |= 1;
    if (modifiers.command) bits |= 2;
    if (modifiers.control) bits |= 4;
    if (modifiers.option) bits |= 8;
    if (modifiers.shift) bits |= 16;
    try cursor.writeByte(bits);
}

fn readModifiers(cursor: *ReadCursor) JournalError!platform.ShortcutModifiers {
    const bits = try cursor.readByte();
    if (bits > 31) return error.JournalCorrupt;
    return .{
        .primary = bits & 1 != 0,
        .command = bits & 2 != 0,
        .control = bits & 4 != 0,
        .option = bits & 8 != 0,
        .shift = bits & 16 != 0,
    };
}

fn writeInsets(cursor: *WriteCursor, insets: geometry.InsetsF) JournalError!void {
    try cursor.writeF32(insets.top);
    try cursor.writeF32(insets.right);
    try cursor.writeF32(insets.bottom);
    try cursor.writeF32(insets.left);
}

fn readInsets(cursor: *ReadCursor) JournalError!geometry.InsetsF {
    return .{
        .top = try cursor.readF32(),
        .right = try cursor.readF32(),
        .bottom = try cursor.readF32(),
        .left = try cursor.readF32(),
    };
}

fn writeRect(cursor: *WriteCursor, rect: geometry.RectF) JournalError!void {
    try cursor.writeF32(rect.x);
    try cursor.writeF32(rect.y);
    try cursor.writeF32(rect.width);
    try cursor.writeF32(rect.height);
}

fn readRect(cursor: *ReadCursor) JournalError!geometry.RectF {
    const x = try cursor.readF32();
    const y = try cursor.readF32();
    const width = try cursor.readF32();
    const height = try cursor.readF32();
    return geometry.RectF.init(x, y, width, height);
}

/// Encode one platform event into `buffer`, returning the encoded
/// payload. `gpu_surface_frame` deliberately journals only the fields
/// dispatch semantics depend on (identity, geometry, frame index and
/// timestamps, full-repaint) — the rest of that struct is host render
/// telemetry about the PREVIOUS present, meaningless under replay's
/// null host; decode fills those with defaults.
pub fn encodeEvent(event: platform.Event, buffer: []u8) JournalError![]const u8 {
    var cursor = WriteCursor{ .buffer = buffer };
    switch (event) {
        .app_start => try cursor.writeEnum(EventTag.app_start),
        .app_activated => try cursor.writeEnum(EventTag.app_activated),
        .app_deactivated => try cursor.writeEnum(EventTag.app_deactivated),
        .frame_requested => try cursor.writeEnum(EventTag.frame_requested),
        .app_shutdown => try cursor.writeEnum(EventTag.app_shutdown),
        .wake => try cursor.writeEnum(EventTag.wake),
        .appearance_changed => |appearance| {
            try cursor.writeEnum(EventTag.appearance_changed);
            try cursor.writeEnum(appearance.color_scheme);
            try cursor.writeBool(appearance.reduce_motion);
            try cursor.writeBool(appearance.high_contrast);
        },
        .surface_resized => |surface| {
            try cursor.writeEnum(EventTag.surface_resized);
            try cursor.writeInt(u64, surface.id);
            try cursor.writeF32(surface.size.width);
            try cursor.writeF32(surface.size.height);
            try cursor.writeF32(surface.scale_factor);
            try writeInsets(&cursor, surface.safe_area_insets);
            try writeInsets(&cursor, surface.keyboard_insets);
            // `native_handle` is process-local and never journaled.
        },
        .window_frame_changed => |state| {
            try cursor.writeEnum(EventTag.window_frame_changed);
            try cursor.writeInt(u64, state.id);
            try cursor.writeStr(state.label);
            try cursor.writeStr(state.title);
            try writeRect(&cursor, state.frame);
            try cursor.writeF32(state.scale_factor);
            try cursor.writeBool(state.open);
            try cursor.writeBool(state.focused);
            try cursor.writeBool(state.maximized);
            try cursor.writeBool(state.fullscreen);
        },
        .window_focused => |window_id| {
            try cursor.writeEnum(EventTag.window_focused);
            try cursor.writeInt(u64, window_id);
        },
        .bridge_message => |message| {
            try cursor.writeEnum(EventTag.bridge_message);
            try cursor.writeStr(message.bytes);
            try cursor.writeStr(message.origin);
            try cursor.writeInt(u64, message.window_id);
            try cursor.writeStr(message.webview_label);
        },
        .tray_action => |item_id| {
            try cursor.writeEnum(EventTag.tray_action);
            try cursor.writeInt(u32, item_id);
        },
        .shortcut => |shortcut| {
            try cursor.writeEnum(EventTag.shortcut);
            try cursor.writeStr(shortcut.id);
            try cursor.writeStr(shortcut.key);
            try writeModifiers(&cursor, shortcut.modifiers);
            try cursor.writeInt(u64, shortcut.window_id);
        },
        .native_command => |command| {
            try cursor.writeEnum(EventTag.native_command);
            try cursor.writeStr(command.name);
            try cursor.writeInt(u64, command.window_id);
            try cursor.writeStr(command.view_label);
        },
        .menu_command => |command| {
            try cursor.writeEnum(EventTag.menu_command);
            try cursor.writeStr(command.name);
            try cursor.writeInt(u64, command.window_id);
        },
        .timer => |timer| {
            try cursor.writeEnum(EventTag.timer);
            try cursor.writeInt(u64, timer.id);
            try cursor.writeInt(u64, timer.timestamp_ns);
        },
        // Recorded for stream fidelity; inert on replay (the journaled
        // audio EFFECT records are the Msg source — `takeAudioMsg`
        // ignores platform audio events under replay).
        .audio => |audio| {
            try cursor.writeEnum(EventTag.audio);
            try cursor.writeEnum(audio.kind);
            try cursor.writeInt(u64, audio.position_ms);
            try cursor.writeInt(u64, audio.duration_ms);
            try cursor.writeBool(audio.playing);
            try cursor.writeBool(audio.buffering);
            try cursor.writeBytes(&audio.bands);
        },
        .files_dropped => |drop| {
            try cursor.writeEnum(EventTag.files_dropped);
            try cursor.writeInt(u64, drop.window_id);
            try cursor.writeStr(drop.view_label);
            try cursor.writeBool(drop.point != null);
            if (drop.point) |point| {
                try cursor.writeF32(point.x);
                try cursor.writeF32(point.y);
            }
            if (drop.paths.len > max_session_drop_paths) return error.JournalRecordOverBudget;
            try cursor.writeInt(u16, @intCast(drop.paths.len));
            for (drop.paths) |path| try cursor.writeStr(path);
        },
        .gpu_surface_frame => |frame| {
            try cursor.writeEnum(EventTag.gpu_surface_frame);
            try cursor.writeInt(u64, frame.window_id);
            try cursor.writeStr(frame.label);
            try cursor.writeF32(frame.size.width);
            try cursor.writeF32(frame.size.height);
            try cursor.writeF32(frame.scale_factor);
            try cursor.writeInt(u64, frame.frame_index);
            try cursor.writeInt(u64, frame.timestamp_ns);
            try cursor.writeInt(u64, frame.frame_interval_ns);
            try cursor.writeInt(u64, frame.input_timestamp_ns);
            try cursor.writeBool(frame.canvas_frame_full_repaint);
        },
        .gpu_surface_resized => |resize| {
            try cursor.writeEnum(EventTag.gpu_surface_resized);
            try cursor.writeInt(u64, resize.window_id);
            try cursor.writeStr(resize.label);
            try writeRect(&cursor, resize.frame);
            try cursor.writeF32(resize.scale_factor);
        },
        .gpu_surface_input => |input| {
            try cursor.writeEnum(EventTag.gpu_surface_input);
            try cursor.writeInt(u64, input.window_id);
            try cursor.writeStr(input.label);
            try cursor.writeEnum(input.kind);
            try cursor.writeInt(u64, input.timestamp_ns);
            try cursor.writeInt(u64, input.pointer_id);
            try cursor.writeF32(input.x);
            try cursor.writeF32(input.y);
            try cursor.writeInt(i32, input.button);
            try cursor.writeF32(input.pressure);
            try cursor.writeF32(input.delta_x);
            try cursor.writeF32(input.delta_y);
            try cursor.writeStr(input.key);
            try cursor.writeStr(input.text);
            try cursor.writeBool(input.composition_cursor != null);
            if (input.composition_cursor) |composition_cursor| {
                try cursor.writeInt(u64, @intCast(composition_cursor));
            }
            try writeModifiers(&cursor, input.modifiers);
        },
        .gpu_surface_scroll_driver => |driver| {
            try cursor.writeEnum(EventTag.gpu_surface_scroll_driver);
            try cursor.writeInt(u64, driver.window_id);
            try cursor.writeStr(driver.label);
            try cursor.writeInt(u64, driver.driver_id);
            try cursor.writeF32(driver.offset_y);
            try cursor.writeInt(u64, driver.timestamp_ns);
        },
        .context_menu_action => |action| {
            try cursor.writeEnum(EventTag.context_menu_action);
            try cursor.writeInt(u64, action.window_id);
            try cursor.writeStr(action.view_label);
            try cursor.writeInt(u64, action.token);
            try cursor.writeInt(u32, action.item_id);
        },
        .widget_accessibility_action => |action| {
            try cursor.writeEnum(EventTag.widget_accessibility_action);
            try cursor.writeInt(u64, action.window_id);
            try cursor.writeStr(action.label);
            try cursor.writeInt(u64, action.id);
            try cursor.writeInt(i32, @intFromEnum(action.action));
            try cursor.writeStr(action.text);
            try cursor.writeBool(action.selection != null);
            if (action.selection) |selection| {
                try cursor.writeInt(u64, @intCast(selection.start));
                try cursor.writeInt(u64, @intCast(selection.end));
            }
        },
    }
    return buffer[0..cursor.len];
}

/// Decode one event payload. Returned slices reference `bytes` (and
/// `storage` for path lists) — valid until the caller's buffers move.
pub fn decodeEvent(bytes: []const u8, storage: *EventDecodeStorage) JournalError!platform.Event {
    var cursor = ReadCursor{ .bytes = bytes };
    const tag = try cursor.readEnum(EventTag);
    const event: platform.Event = switch (tag) {
        .app_start => .app_start,
        .app_activated => .app_activated,
        .app_deactivated => .app_deactivated,
        .frame_requested => .frame_requested,
        .app_shutdown => .app_shutdown,
        .wake => .wake,
        .appearance_changed => .{ .appearance_changed = .{
            .color_scheme = try cursor.readEnum(platform.ColorScheme),
            .reduce_motion = try cursor.readBool(),
            .high_contrast = try cursor.readBool(),
        } },
        .surface_resized => blk: {
            const id = try cursor.readInt(u64);
            const width = try cursor.readF32();
            const height = try cursor.readF32();
            const scale_factor = try cursor.readF32();
            const safe_area = try readInsets(&cursor);
            const keyboard = try readInsets(&cursor);
            break :blk .{ .surface_resized = .{
                .id = id,
                .size = geometry.SizeF.init(width, height),
                .scale_factor = scale_factor,
                .safe_area_insets = safe_area,
                .keyboard_insets = keyboard,
            } };
        },
        .window_frame_changed => blk: {
            const id = try cursor.readInt(u64);
            const label = try cursor.readStr();
            const title = try cursor.readStr();
            const frame = try readRect(&cursor);
            const scale_factor = try cursor.readF32();
            break :blk .{ .window_frame_changed = .{
                .id = id,
                .label = label,
                .title = title,
                .frame = frame,
                .scale_factor = scale_factor,
                .open = try cursor.readBool(),
                .focused = try cursor.readBool(),
                .maximized = try cursor.readBool(),
                .fullscreen = try cursor.readBool(),
            } };
        },
        .window_focused => .{ .window_focused = try cursor.readInt(u64) },
        .bridge_message => blk: {
            const message_bytes = try cursor.readStr();
            const origin = try cursor.readStr();
            const window_id = try cursor.readInt(u64);
            const webview_label = try cursor.readStr();
            break :blk .{ .bridge_message = .{
                .bytes = message_bytes,
                .origin = origin,
                .window_id = window_id,
                .webview_label = webview_label,
            } };
        },
        .tray_action => .{ .tray_action = try cursor.readInt(u32) },
        .shortcut => blk: {
            const id = try cursor.readStr();
            const key = try cursor.readStr();
            const modifiers = try readModifiers(&cursor);
            break :blk .{ .shortcut = .{
                .id = id,
                .key = key,
                .modifiers = modifiers,
                .window_id = try cursor.readInt(u64),
            } };
        },
        .native_command => blk: {
            const name = try cursor.readStr();
            const window_id = try cursor.readInt(u64);
            break :blk .{ .native_command = .{
                .name = name,
                .window_id = window_id,
                .view_label = try cursor.readStr(),
            } };
        },
        .menu_command => blk: {
            const name = try cursor.readStr();
            break :blk .{ .menu_command = .{
                .name = name,
                .window_id = try cursor.readInt(u64),
            } };
        },
        .timer => blk: {
            const id = try cursor.readInt(u64);
            break :blk .{ .timer = .{
                .id = id,
                .timestamp_ns = try cursor.readInt(u64),
            } };
        },
        .audio => blk: {
            const kind = try cursor.readEnum(platform.AudioEventKind);
            var decoded: platform.AudioEvent = .{
                .kind = kind,
                .position_ms = try cursor.readInt(u64),
                .duration_ms = try cursor.readInt(u64),
                .playing = try cursor.readBool(),
                .buffering = try cursor.readBool(),
            };
            @memcpy(&decoded.bands, try cursor.readBytes(decoded.bands.len));
            break :blk .{ .audio = decoded };
        },
        .files_dropped => blk: {
            const window_id = try cursor.readInt(u64);
            const view_label = try cursor.readStr();
            var point: ?geometry.PointF = null;
            if (try cursor.readBool()) {
                const x = try cursor.readF32();
                const y = try cursor.readF32();
                point = geometry.PointF.init(x, y);
            }
            const count = try cursor.readInt(u16);
            if (count > max_session_drop_paths) return error.JournalCorrupt;
            for (0..count) |index| {
                storage.drop_paths[index] = try cursor.readStr();
            }
            break :blk .{ .files_dropped = .{
                .window_id = window_id,
                .view_label = view_label,
                .point = point,
                .paths = storage.drop_paths[0..count],
            } };
        },
        .gpu_surface_frame => blk: {
            const window_id = try cursor.readInt(u64);
            const label = try cursor.readStr();
            const width = try cursor.readF32();
            const height = try cursor.readF32();
            break :blk .{ .gpu_surface_frame = .{
                .window_id = window_id,
                .label = label,
                .size = geometry.SizeF.init(width, height),
                .scale_factor = try cursor.readF32(),
                .frame_index = try cursor.readInt(u64),
                .timestamp_ns = try cursor.readInt(u64),
                .frame_interval_ns = try cursor.readInt(u64),
                .input_timestamp_ns = try cursor.readInt(u64),
                .canvas_frame_full_repaint = try cursor.readBool(),
            } };
        },
        .gpu_surface_resized => blk: {
            const window_id = try cursor.readInt(u64);
            const label = try cursor.readStr();
            const frame = try readRect(&cursor);
            break :blk .{ .gpu_surface_resized = .{
                .window_id = window_id,
                .label = label,
                .frame = frame,
                .scale_factor = try cursor.readF32(),
            } };
        },
        .gpu_surface_input => blk: {
            const window_id = try cursor.readInt(u64);
            const label = try cursor.readStr();
            const kind = try cursor.readEnum(platform.GpuSurfaceInputKind);
            const timestamp_ns = try cursor.readInt(u64);
            const pointer_id = try cursor.readInt(u64);
            const x = try cursor.readF32();
            const y = try cursor.readF32();
            const button = try cursor.readInt(i32);
            const pressure = try cursor.readF32();
            const delta_x = try cursor.readF32();
            const delta_y = try cursor.readF32();
            const key = try cursor.readStr();
            const text = try cursor.readStr();
            var composition_cursor: ?usize = null;
            if (try cursor.readBool()) {
                composition_cursor = std.math.cast(usize, try cursor.readInt(u64)) orelse return error.JournalCorrupt;
            }
            break :blk .{ .gpu_surface_input = .{
                .window_id = window_id,
                .label = label,
                .kind = kind,
                .timestamp_ns = timestamp_ns,
                .pointer_id = pointer_id,
                .x = x,
                .y = y,
                .button = button,
                .pressure = pressure,
                .delta_x = delta_x,
                .delta_y = delta_y,
                .key = key,
                .text = text,
                .composition_cursor = composition_cursor,
                .modifiers = try readModifiers(&cursor),
            } };
        },
        .gpu_surface_scroll_driver => blk: {
            const window_id = try cursor.readInt(u64);
            const label = try cursor.readStr();
            const driver_id = try cursor.readInt(u64);
            const offset_y = try cursor.readF32();
            break :blk .{ .gpu_surface_scroll_driver = .{
                .window_id = window_id,
                .label = label,
                .driver_id = driver_id,
                .offset_y = offset_y,
                .timestamp_ns = try cursor.readInt(u64),
            } };
        },
        .context_menu_action => blk: {
            const window_id = try cursor.readInt(u64);
            const view_label = try cursor.readStr();
            const token = try cursor.readInt(u64);
            break :blk .{ .context_menu_action = .{
                .window_id = window_id,
                .view_label = view_label,
                .token = token,
                .item_id = try cursor.readInt(u32),
            } };
        },
        .widget_accessibility_action => blk: {
            const window_id = try cursor.readInt(u64);
            const label = try cursor.readStr();
            const id = try cursor.readInt(u64);
            const action = std.enums.fromInt(platform.WidgetAccessibilityActionKind, try cursor.readInt(i32)) orelse return error.JournalCorrupt;
            const text = try cursor.readStr();
            var selection: ?platform.WidgetAccessibilityTextRange = null;
            if (try cursor.readBool()) {
                const start = std.math.cast(usize, try cursor.readInt(u64)) orelse return error.JournalCorrupt;
                const end = std.math.cast(usize, try cursor.readInt(u64)) orelse return error.JournalCorrupt;
                selection = .{ .start = start, .end = end };
            }
            break :blk .{ .widget_accessibility_action = .{
                .window_id = window_id,
                .label = label,
                .id = id,
                .action = action,
                .text = text,
                .selection = selection,
            } };
        },
    };
    if (!cursor.done()) return error.JournalCorrupt;
    return event;
}

// ------------------------------------------------------ effect codec

pub fn encodeEffect(record: EffectResultRecord, buffer: []u8) JournalError![]const u8 {
    var cursor = WriteCursor{ .buffer = buffer };
    try cursor.writeEnum(record.kind);
    try cursor.writeInt(u64, record.key);
    try cursor.writeStr(record.payload);
    try cursor.writeStr(record.stderr_tail);
    try cursor.writeBool(record.truncated);
    try cursor.writeInt(u32, record.dropped);
    try cursor.writeInt(i32, record.code);
    try cursor.writeEnum(record.exit_reason);
    try cursor.writeBool(record.output_truncated);
    try cursor.writeBool(record.stderr_truncated);
    try cursor.writeInt(u16, record.status);
    try cursor.writeEnum(record.fetch_outcome);
    try cursor.writeEnum(record.file_op);
    try cursor.writeEnum(record.file_outcome);
    try cursor.writeEnum(record.clipboard_op);
    try cursor.writeEnum(record.clipboard_outcome);
    try cursor.writeInt(u64, record.timer_timestamp_ns);
    try cursor.writeEnum(record.timer_outcome);
    try cursor.writeInt(i64, record.clock_wall_ms);
    try cursor.writeEnum(record.audio_kind);
    try cursor.writeInt(u64, record.audio_position_ms);
    try cursor.writeInt(u64, record.audio_duration_ms);
    try cursor.writeBool(record.audio_playing);
    try cursor.writeBool(record.audio_buffering);
    try cursor.writeBytes(&record.audio_bands);
    return buffer[0..cursor.len];
}

pub fn decodeEffect(bytes: []const u8) JournalError!EffectResultRecord {
    var cursor = ReadCursor{ .bytes = bytes };
    var record: EffectResultRecord = .{
        .kind = try cursor.readEnum(runtime_effects.EffectResultKind),
        .key = try cursor.readInt(u64),
        .payload = try cursor.readStr(),
        .stderr_tail = try cursor.readStr(),
        .truncated = try cursor.readBool(),
        .dropped = try cursor.readInt(u32),
        .code = try cursor.readInt(i32),
        .exit_reason = try cursor.readEnum(runtime_effects.EffectExitReason),
        .output_truncated = try cursor.readBool(),
        .stderr_truncated = try cursor.readBool(),
        .status = try cursor.readInt(u16),
        .fetch_outcome = try cursor.readEnum(runtime_effects.EffectFetchOutcome),
        .file_op = try cursor.readEnum(runtime_effects.EffectFileOp),
        .file_outcome = try cursor.readEnum(runtime_effects.EffectFileOutcome),
        .clipboard_op = try cursor.readEnum(runtime_effects.EffectClipboardOp),
        .clipboard_outcome = try cursor.readEnum(runtime_effects.EffectClipboardOutcome),
        .timer_timestamp_ns = try cursor.readInt(u64),
        .timer_outcome = try cursor.readEnum(runtime_effects.EffectTimerOutcome),
        .clock_wall_ms = try cursor.readInt(i64),
        .audio_kind = try cursor.readEnum(runtime_effects.EffectAudioEventKind),
        .audio_position_ms = try cursor.readInt(u64),
        .audio_duration_ms = try cursor.readInt(u64),
        .audio_playing = try cursor.readBool(),
        .audio_buffering = try cursor.readBool(),
    };
    @memcpy(&record.audio_bands, try cursor.readBytes(record.audio_bands.len));
    if (!cursor.done()) return error.JournalCorrupt;
    return record;
}

// ----------------------------------------------------- other codecs

pub fn encodeHeader(header: Header, buffer: []u8) JournalError![]const u8 {
    var cursor = WriteCursor{ .buffer = buffer };
    try cursor.writeInt(u32, header.protocol_version);
    try cursor.writeStr(header.platform_name);
    try cursor.writeStr(header.app_name);
    try cursor.writeInt(i64, header.recorded_at_wall_ms);
    try cursor.writeF32(header.window_width);
    try cursor.writeF32(header.window_height);
    return buffer[0..cursor.len];
}

pub fn decodeHeader(bytes: []const u8) JournalError!Header {
    var cursor = ReadCursor{ .bytes = bytes };
    const header: Header = .{
        .protocol_version = try cursor.readInt(u32),
        .platform_name = try cursor.readStr(),
        .app_name = try cursor.readStr(),
        .recorded_at_wall_ms = try cursor.readInt(i64),
        .window_width = try cursor.readF32(),
        .window_height = try cursor.readF32(),
    };
    if (!cursor.done()) return error.JournalCorrupt;
    return header;
}

pub fn encodeCheckpoint(checkpoint: Checkpoint, buffer: []u8) JournalError![]const u8 {
    var cursor = WriteCursor{ .buffer = buffer };
    try cursor.writeInt(u64, checkpoint.event_ordinal);
    try cursor.writeInt(u64, checkpoint.frame_index);
    try cursor.writeInt(u64, checkpoint.fingerprint);
    return buffer[0..cursor.len];
}

pub fn decodeCheckpoint(bytes: []const u8) JournalError!Checkpoint {
    var cursor = ReadCursor{ .bytes = bytes };
    const checkpoint: Checkpoint = .{
        .event_ordinal = try cursor.readInt(u64),
        .frame_index = try cursor.readInt(u64),
        .fingerprint = try cursor.readInt(u64),
    };
    if (!cursor.done()) return error.JournalCorrupt;
    return checkpoint;
}

pub fn encodeScreenshot(mark: ScreenshotMark, buffer: []u8) JournalError![]const u8 {
    var cursor = WriteCursor{ .buffer = buffer };
    try cursor.writeInt(u64, mark.event_ordinal);
    try cursor.writeStr(mark.view_label);
    try cursor.writeF32(mark.scale);
    try cursor.writeInt(u64, mark.png_hash);
    try cursor.writeInt(u64, mark.png_len);
    return buffer[0..cursor.len];
}

pub fn decodeScreenshot(bytes: []const u8) JournalError!ScreenshotMark {
    var cursor = ReadCursor{ .bytes = bytes };
    const ordinal = try cursor.readInt(u64);
    const label = try cursor.readStr();
    const mark: ScreenshotMark = .{
        .event_ordinal = ordinal,
        .view_label = label,
        .scale = try cursor.readF32(),
        .png_hash = try cursor.readInt(u64),
        .png_len = try cursor.readInt(u64),
    };
    if (!cursor.done()) return error.JournalCorrupt;
    return mark;
}

pub fn encodeEnd(end: End, buffer: []u8) JournalError![]const u8 {
    var cursor = WriteCursor{ .buffer = buffer };
    try cursor.writeInt(u64, end.event_count);
    try cursor.writeInt(u64, end.effect_count);
    try cursor.writeInt(u64, end.checkpoint_count);
    try cursor.writeInt(u64, end.screenshot_count);
    return buffer[0..cursor.len];
}

pub fn decodeEnd(bytes: []const u8) JournalError!End {
    var cursor = ReadCursor{ .bytes = bytes };
    const end: End = .{
        .event_count = try cursor.readInt(u64),
        .effect_count = try cursor.readInt(u64),
        .checkpoint_count = try cursor.readInt(u64),
        .screenshot_count = try cursor.readInt(u64),
    };
    if (!cursor.done()) return error.JournalCorrupt;
    return end;
}

// ------------------------------------------------------------ framing

/// Frame one record (kind + u32 length prefix + payload) into `buffer`.
pub fn frameRecord(kind: RecordKind, payload: []const u8, buffer: []u8) JournalError![]const u8 {
    if (payload.len > max_session_record_bytes) return error.JournalRecordOverBudget;
    if (buffer.len < 5 + payload.len) return error.JournalRecordOverBudget;
    buffer[0] = @intFromEnum(kind);
    std.mem.writeInt(u32, buffer[1..5], @intCast(payload.len), .little);
    @memcpy(buffer[5 .. 5 + payload.len], payload);
    return buffer[0 .. 5 + payload.len];
}

/// The journal preamble (magic + format version).
pub fn writePreamble(buffer: []u8) []const u8 {
    @memcpy(buffer[0..magic.len], magic);
    std.mem.writeInt(u32, buffer[magic.len..][0..4], format_version, .little);
    return buffer[0 .. magic.len + 4];
}

pub const preamble_len: usize = magic.len + 4;

/// Sequential journal reader over a whole in-memory journal. Validates
/// the preamble at init, enforces record budgets, and requires header
/// first and end record last (with matching counts) — a truncated or
/// tampered file fails loudly at the exact offending offset, never
/// crashes, never loops.
pub const Reader = struct {
    bytes: []const u8,
    pos: usize,
    storage: EventDecodeStorage = .{},
    header: ?Header = null,
    end: ?End = null,
    event_count: u64 = 0,
    effect_count: u64 = 0,
    checkpoint_count: u64 = 0,
    screenshot_count: u64 = 0,

    pub fn init(bytes: []const u8) JournalError!Reader {
        if (bytes.len < preamble_len) return error.JournalBadMagic;
        if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.JournalBadMagic;
        const version = std.mem.readInt(u32, bytes[magic.len..][0..4], .little);
        if (version != format_version) return error.JournalUnsupportedVersion;
        return .{ .bytes = bytes, .pos = preamble_len };
    }

    /// The next record, or null after the end record. Records after the
    /// end record, a missing end record, and count mismatches are all
    /// refused.
    pub fn next(self: *Reader) JournalError!?Record {
        if (self.end != null) {
            if (self.pos != self.bytes.len) return error.JournalCorrupt;
            return null;
        }
        if (self.pos == self.bytes.len) return error.JournalTruncated;
        if (self.bytes.len - self.pos < 5) return error.JournalTruncated;
        const kind = std.enums.fromInt(RecordKind, self.bytes[self.pos]) orelse return error.JournalCorrupt;
        const len = std.mem.readInt(u32, self.bytes[self.pos + 1 ..][0..4], .little);
        if (len > max_session_record_bytes) return error.JournalRecordOverBudget;
        if (self.bytes.len - self.pos - 5 < len) return error.JournalTruncated;
        const payload = self.bytes[self.pos + 5 .. self.pos + 5 + len];
        self.pos += 5 + len;

        if (self.header == null and kind != .header) return error.JournalMissingHeader;
        switch (kind) {
            .header => {
                if (self.header != null) return error.JournalCorrupt;
                const header = try decodeHeader(payload);
                self.header = header;
                return .{ .header = header };
            },
            .event => {
                self.event_count += 1;
                return .{ .event = try decodeEvent(payload, &self.storage) };
            },
            .effect => {
                self.effect_count += 1;
                return .{ .effect = try decodeEffect(payload) };
            },
            .checkpoint => {
                self.checkpoint_count += 1;
                return .{ .checkpoint = try decodeCheckpoint(payload) };
            },
            .screenshot => {
                self.screenshot_count += 1;
                return .{ .screenshot = try decodeScreenshot(payload) };
            },
            .end => {
                const end = try decodeEnd(payload);
                if (end.event_count != self.event_count or
                    end.effect_count != self.effect_count or
                    end.checkpoint_count != self.checkpoint_count or
                    end.screenshot_count != self.screenshot_count)
                {
                    return error.JournalCountMismatch;
                }
                self.end = end;
                return .{ .end = end };
            },
        }
    }
};

/// A one-line teaching description per journal error, for CLI and
/// replay-report output.
pub fn describeError(err: JournalError) []const u8 {
    return switch (err) {
        error.JournalBadMagic => "not a session journal (bad magic) - record one with NATIVE_SDK_SESSION_RECORD=<path>",
        error.JournalUnsupportedVersion => "journal format version differs from this build - re-record the session with the same build that replays it",
        error.JournalTruncated => "journal ends mid-record (the recording was cut off) - re-record, and keep the app running until it exits cleanly",
        error.JournalCorrupt => "journal payload does not decode (damaged or hand-edited bytes)",
        error.JournalRecordOverBudget => "journal claims a record beyond max_session_record_bytes - the file is damaged or hostile",
        error.JournalMissingHeader => "journal does not start with a session header record",
        error.JournalCountMismatch => "journal end-record counts disagree with its contents (records were lost or injected)",
    };
}

// -------------------------------------------------------------- tests

const testing = std.testing;

fn roundTripEvent(event: platform.Event) !platform.Event {
    var buffer: [max_session_event_bytes]u8 = undefined;
    const encoded = try encodeEvent(event, &buffer);
    // Decode from a COPY so returned slices never alias the encode
    // buffer (catches accidental aliasing in the codec).
    var copy: [max_session_event_bytes]u8 = undefined;
    @memcpy(copy[0..encoded.len], encoded);
    var storage: EventDecodeStorage = .{};
    return decodeEvent(copy[0..encoded.len], &storage);
}

test "event codec round-trips every payload variant" {
    {
        const decoded = try roundTripEvent(.app_start);
        try testing.expect(decoded == .app_start);
    }
    {
        const decoded = try roundTripEvent(.{ .appearance_changed = .{ .color_scheme = .dark, .high_contrast = true } });
        try testing.expectEqual(platform.ColorScheme.dark, decoded.appearance_changed.color_scheme);
        try testing.expect(decoded.appearance_changed.high_contrast);
        try testing.expect(!decoded.appearance_changed.reduce_motion);
    }
    {
        const decoded = try roundTripEvent(.{ .surface_resized = .{
            .id = 7,
            .size = geometry.SizeF.init(320, 240),
            .scale_factor = 2,
            .safe_area_insets = .{ .top = 44 },
        } });
        try testing.expectEqual(@as(u64, 7), decoded.surface_resized.id);
        try testing.expectEqual(@as(f32, 320), decoded.surface_resized.size.width);
        try testing.expectEqual(@as(f32, 44), decoded.surface_resized.safe_area_insets.top);
        try testing.expectEqual(@as(?*anyopaque, null), decoded.surface_resized.native_handle);
    }
    {
        const decoded = try roundTripEvent(.{ .window_frame_changed = .{
            .id = 2,
            .label = "settings",
            .title = "Settings",
            .frame = geometry.RectF.init(10, 20, 480, 360),
            .open = false,
            .focused = false,
        } });
        try testing.expectEqualStrings("settings", decoded.window_frame_changed.label);
        try testing.expect(!decoded.window_frame_changed.open);
    }
    {
        const decoded = try roundTripEvent(.{ .bridge_message = .{
            .bytes = "{\"id\":1}",
            .origin = "zero://inline",
            .window_id = 3,
            .webview_label = "main",
        } });
        try testing.expectEqualStrings("{\"id\":1}", decoded.bridge_message.bytes);
        try testing.expectEqual(@as(u64, 3), decoded.bridge_message.window_id);
    }
    {
        const decoded = try roundTripEvent(.{ .shortcut = .{
            .id = "clear",
            .key = "escape",
            .modifiers = .{ .primary = true, .shift = true },
            .window_id = 1,
        } });
        try testing.expectEqualStrings("clear", decoded.shortcut.id);
        try testing.expect(decoded.shortcut.modifiers.primary);
        try testing.expect(decoded.shortcut.modifiers.shift);
        try testing.expect(!decoded.shortcut.modifiers.option);
    }
    {
        const decoded = try roundTripEvent(.{ .timer = .{ .id = 42, .timestamp_ns = 123456 } });
        try testing.expectEqual(@as(u64, 42), decoded.timer.id);
        try testing.expectEqual(@as(u64, 123456), decoded.timer.timestamp_ns);
    }
    {
        const decoded = try roundTripEvent(.{ .audio = .{
            .kind = .completed,
            .position_ms = 89_160,
            .duration_ms = 89_160,
            .playing = false,
        } });
        try testing.expectEqual(platform.AudioEventKind.completed, decoded.audio.kind);
        try testing.expectEqual(@as(u64, 89_160), decoded.audio.position_ms);
        try testing.expectEqual(@as(u64, 89_160), decoded.audio.duration_ms);
        try testing.expect(!decoded.audio.playing);
    }
    {
        // Spectrum events journal their band bytes verbatim — replay
        // must repaint identical bars from the decoded record alone.
        var bands: [platform.audio_spectrum_band_count]u8 = undefined;
        for (&bands, 0..) |*band, index| band.* = @intCast(index * 7 % 256);
        const decoded = try roundTripEvent(.{ .audio = .{
            .kind = .spectrum,
            .position_ms = 4_240,
            .duration_ms = 89_160,
            .playing = true,
            .bands = bands,
        } });
        try testing.expectEqual(platform.AudioEventKind.spectrum, decoded.audio.kind);
        try testing.expectEqual(@as(u64, 4_240), decoded.audio.position_ms);
        try testing.expect(decoded.audio.playing);
        try testing.expectEqualSlices(u8, &bands, &decoded.audio.bands);
    }
    {
        const paths = [_][]const u8{ "/tmp/a.txt", "/tmp/b.txt" };
        const decoded = try roundTripEvent(.{ .files_dropped = .{
            .window_id = 1,
            .view_label = "canvas",
            .point = geometry.PointF.init(12, 34),
            .paths = &paths,
        } });
        try testing.expectEqual(@as(usize, 2), decoded.files_dropped.paths.len);
        try testing.expectEqualStrings("/tmp/b.txt", decoded.files_dropped.paths[1]);
        try testing.expectEqual(@as(f32, 34), decoded.files_dropped.point.?.y);
    }
    {
        const decoded = try roundTripEvent(.{ .gpu_surface_frame = .{
            .window_id = 1,
            .label = "calc-canvas",
            .size = geometry.SizeF.init(320, 490),
            .scale_factor = 2,
            .frame_index = 9,
            .timestamp_ns = 777,
            .canvas_frame_full_repaint = true,
        } });
        try testing.expectEqualStrings("calc-canvas", decoded.gpu_surface_frame.label);
        try testing.expectEqual(@as(u64, 9), decoded.gpu_surface_frame.frame_index);
        try testing.expect(decoded.gpu_surface_frame.canvas_frame_full_repaint);
        // Host render telemetry decodes to defaults, by design.
        try testing.expectEqual(@as(u32, 0), decoded.gpu_surface_frame.sample_color);
    }
    {
        const decoded = try roundTripEvent(.{ .gpu_surface_input = .{
            .label = "calc-canvas",
            .kind = .text_input,
            .timestamp_ns = 5,
            .x = 1.5,
            .y = 2.5,
            .text = "7",
            .composition_cursor = 3,
            .modifiers = .{ .control = true },
        } });
        try testing.expectEqual(platform.GpuSurfaceInputKind.text_input, decoded.gpu_surface_input.kind);
        try testing.expectEqualStrings("7", decoded.gpu_surface_input.text);
        try testing.expectEqual(@as(?usize, 3), decoded.gpu_surface_input.composition_cursor);
        try testing.expect(decoded.gpu_surface_input.modifiers.control);
    }
    {
        const decoded = try roundTripEvent(.{ .widget_accessibility_action = .{
            .label = "canvas",
            .id = 12,
            .action = .set_text,
            .text = "hello",
            .selection = .{ .start = 1, .end = 4 },
        } });
        try testing.expectEqual(platform.WidgetAccessibilityActionKind.set_text, decoded.widget_accessibility_action.action);
        try testing.expectEqual(@as(usize, 4), decoded.widget_accessibility_action.selection.?.end);
    }
    {
        const decoded = try roundTripEvent(.{ .gpu_surface_scroll_driver = .{
            .label = "canvas",
            .driver_id = 88,
            .offset_y = -12.5,
            .timestamp_ns = 4,
        } });
        try testing.expectEqual(@as(f32, -12.5), decoded.gpu_surface_scroll_driver.offset_y);
    }
    {
        const decoded = try roundTripEvent(.{ .context_menu_action = .{ .view_label = "canvas", .token = 5, .item_id = 2 } });
        try testing.expectEqual(@as(u32, 2), decoded.context_menu_action.item_id);
    }
    {
        const decoded = try roundTripEvent(.{ .native_command = .{ .name = "refresh", .window_id = 1, .view_label = "toolbar" } });
        try testing.expectEqualStrings("refresh", decoded.native_command.name);
    }
    {
        const decoded = try roundTripEvent(.{ .menu_command = .{ .name = "app.about", .window_id = 1 } });
        try testing.expectEqualStrings("app.about", decoded.menu_command.name);
    }
    {
        const decoded = try roundTripEvent(.{ .tray_action = 9 });
        try testing.expectEqual(@as(platform.TrayItemId, 9), decoded.tray_action);
    }
    {
        const decoded = try roundTripEvent(.{ .window_focused = 4 });
        try testing.expectEqual(@as(u64, 4), decoded.window_focused);
    }
    {
        const decoded = try roundTripEvent(.{ .gpu_surface_resized = .{
            .label = "canvas",
            .frame = geometry.RectF.init(0, 0, 640, 480),
            .scale_factor = 2,
        } });
        try testing.expectEqual(@as(f32, 640), decoded.gpu_surface_resized.frame.width);
    }
}

test "effect codec round-trips payloads and outcomes" {
    var buffer: [4096]u8 = undefined;
    const encoded = try encodeEffect(.{
        .kind = .response,
        .key = 77,
        .payload = "{\"ok\":true}",
        .truncated = true,
        .dropped = 3,
        .status = 200,
        .fetch_outcome = .ok,
    }, &buffer);
    const decoded = try decodeEffect(encoded);
    try testing.expectEqual(runtime_effects.EffectResultKind.response, decoded.kind);
    try testing.expectEqual(@as(u64, 77), decoded.key);
    try testing.expectEqualStrings("{\"ok\":true}", decoded.payload);
    try testing.expect(decoded.truncated);
    try testing.expectEqual(@as(u16, 200), decoded.status);

    const exit_encoded = try encodeEffect(.{
        .kind = .exit,
        .key = 5,
        .payload = "collected stdout",
        .stderr_tail = "warning: x",
        .code = 2,
        .exit_reason = .exited,
        .output_truncated = true,
    }, &buffer);
    const exit_decoded = try decodeEffect(exit_encoded);
    try testing.expectEqualStrings("collected stdout", exit_decoded.payload);
    try testing.expectEqualStrings("warning: x", exit_decoded.stderr_tail);
    try testing.expectEqual(@as(i32, 2), exit_decoded.code);
    try testing.expect(exit_decoded.output_truncated);

    const audio_encoded = try encodeEffect(.{
        .kind = .audio,
        .key = 41,
        .audio_kind = .position,
        .audio_position_ms = 1_500,
        .audio_duration_ms = 89_160,
        .audio_playing = true,
        .audio_buffering = true,
    }, &buffer);
    const audio_decoded = try decodeEffect(audio_encoded);
    try testing.expectEqual(runtime_effects.EffectResultKind.audio, audio_decoded.kind);
    try testing.expectEqual(@as(u64, 41), audio_decoded.key);
    try testing.expectEqual(runtime_effects.EffectAudioEventKind.position, audio_decoded.audio_kind);
    try testing.expectEqual(@as(u64, 1_500), audio_decoded.audio_position_ms);
    try testing.expectEqual(@as(u64, 89_160), audio_decoded.audio_duration_ms);
    try testing.expect(audio_decoded.audio_playing);
    try testing.expect(audio_decoded.audio_buffering);

    // Spectrum effect records carry their band bytes verbatim: the
    // journaled record is the replay's ONLY source for the bars.
    var spectrum_bands: [platform.audio_spectrum_band_count]u8 = undefined;
    for (&spectrum_bands, 0..) |*band, index| band.* = @intCast((index * 11 + 3) % 256);
    const spectrum_encoded = try encodeEffect(.{
        .kind = .audio,
        .key = 41,
        .audio_kind = .spectrum,
        .audio_position_ms = 4_240,
        .audio_duration_ms = 89_160,
        .audio_playing = true,
        .audio_bands = spectrum_bands,
    }, &buffer);
    const spectrum_decoded = try decodeEffect(spectrum_encoded);
    try testing.expectEqual(runtime_effects.EffectAudioEventKind.spectrum, spectrum_decoded.audio_kind);
    try testing.expectEqualSlices(u8, &spectrum_bands, &spectrum_decoded.audio_bands);
}

test "header, checkpoint, screenshot, and end codecs round-trip" {
    var buffer: [1024]u8 = undefined;
    const header = try decodeHeader(try encodeHeader(.{
        .platform_name = "macos",
        .app_name = "calculator",
        .recorded_at_wall_ms = 1234,
        .window_width = 320,
        .window_height = 490,
    }, &buffer));
    try testing.expectEqualStrings("macos", header.platform_name);
    try testing.expectEqualStrings("calculator", header.app_name);
    try testing.expectEqual(automation_protocol.version, header.protocol_version);

    const checkpoint = try decodeCheckpoint(try encodeCheckpoint(.{ .event_ordinal = 10, .frame_index = 4, .fingerprint = 0xdead }, &buffer));
    try testing.expectEqual(@as(u64, 0xdead), checkpoint.fingerprint);

    const mark = try decodeScreenshot(try encodeScreenshot(.{
        .event_ordinal = 11,
        .view_label = "calc-canvas",
        .scale = 1,
        .png_hash = 42,
        .png_len = 1000,
    }, &buffer));
    try testing.expectEqualStrings("calc-canvas", mark.view_label);
    try testing.expectEqual(@as(u64, 42), mark.png_hash);

    const end = try decodeEnd(try encodeEnd(.{ .event_count = 3, .effect_count = 2, .checkpoint_count = 1, .screenshot_count = 0 }, &buffer));
    try testing.expectEqual(@as(u64, 3), end.event_count);
}

fn buildTestJournal(buffer: []u8) !usize {
    var len: usize = 0;
    const preamble = writePreamble(buffer);
    len += preamble.len;
    var payload: [4096]u8 = undefined;
    var frame: [4200]u8 = undefined;

    const header_payload = try encodeHeader(.{ .platform_name = "macos", .app_name = "demo" }, &payload);
    var framed = try frameRecord(.header, header_payload, &frame);
    @memcpy(buffer[len .. len + framed.len], framed);
    len += framed.len;

    const event_payload = try encodeEvent(.app_start, &payload);
    framed = try frameRecord(.event, event_payload, &frame);
    @memcpy(buffer[len .. len + framed.len], framed);
    len += framed.len;

    const effect_payload = try encodeEffect(.{ .kind = .line, .key = 1, .payload = "cpu 12.5" }, &payload);
    framed = try frameRecord(.effect, effect_payload, &frame);
    @memcpy(buffer[len .. len + framed.len], framed);
    len += framed.len;

    const checkpoint_payload = try encodeCheckpoint(.{ .event_ordinal = 1, .frame_index = 1, .fingerprint = 99 }, &payload);
    framed = try frameRecord(.checkpoint, checkpoint_payload, &frame);
    @memcpy(buffer[len .. len + framed.len], framed);
    len += framed.len;

    const end_payload = try encodeEnd(.{ .event_count = 1, .effect_count = 1, .checkpoint_count = 1, .screenshot_count = 0 }, &payload);
    framed = try frameRecord(.end, end_payload, &frame);
    @memcpy(buffer[len .. len + framed.len], framed);
    len += framed.len;
    return len;
}

test "reader walks a whole journal and stops at the end record" {
    var buffer: [16384]u8 = undefined;
    const len = try buildTestJournal(&buffer);
    var reader = try Reader.init(buffer[0..len]);
    const header = (try reader.next()).?;
    try testing.expectEqualStrings("demo", header.header.app_name);
    const event = (try reader.next()).?;
    try testing.expect(event.event == .app_start);
    const effect = (try reader.next()).?;
    try testing.expectEqualStrings("cpu 12.5", effect.effect.payload);
    const checkpoint = (try reader.next()).?;
    try testing.expectEqual(@as(u64, 99), checkpoint.checkpoint.fingerprint);
    const end = (try reader.next()).?;
    try testing.expectEqual(@as(u64, 1), end.end.event_count);
    try testing.expectEqual(@as(?Record, null), try reader.next());
}

test "reader refuses bad magic and version skew" {
    var buffer: [16384]u8 = undefined;
    const len = try buildTestJournal(&buffer);
    try testing.expectError(error.JournalBadMagic, Reader.init("not a journal at all"));
    try testing.expectError(error.JournalBadMagic, Reader.init(""));
    var skewed: [16384]u8 = undefined;
    @memcpy(skewed[0..len], buffer[0..len]);
    std.mem.writeInt(u32, skewed[magic.len..][0..4], format_version + 1, .little);
    try testing.expectError(error.JournalUnsupportedVersion, Reader.init(skewed[0..len]));
}

test "reader fails loudly on truncation at every boundary" {
    var buffer: [16384]u8 = undefined;
    const len = try buildTestJournal(&buffer);
    // Cut the journal at a sweep of lengths: every cut must produce a
    // teaching error (or a clean early stop is impossible — the end
    // record is missing), never a crash or an infinite loop.
    var cut: usize = preamble_len;
    while (cut < len) : (cut += 7) {
        var reader = Reader.init(buffer[0..cut]) catch continue;
        var records: usize = 0;
        const failed = while (records < 64) : (records += 1) {
            const record = reader.next() catch break true;
            if (record == null) break false;
        } else false;
        try testing.expect(failed);
    }
}

test "reader fails loudly on bit flips" {
    var buffer: [16384]u8 = undefined;
    const len = try buildTestJournal(&buffer);
    var offset: usize = 0;
    while (offset < len) : (offset += 3) {
        var flipped: [16384]u8 = undefined;
        @memcpy(flipped[0..len], buffer[0..len]);
        flipped[offset] ^= 0x40;
        var reader = Reader.init(flipped[0..len]) catch continue;
        // Either some record fails to decode, or every record decodes
        // but a payload VALUE changed (a bit flip inside a string is
        // undetectable at the framing layer — the replay fingerprints
        // catch those). Just prove no crash and no hang.
        var records: usize = 0;
        while (records < 64) : (records += 1) {
            const record = reader.next() catch break;
            if (record == null) break;
        }
        try testing.expect(records < 64);
    }
}

test "reader refuses count mismatches and over-budget records" {
    var buffer: [16384]u8 = undefined;
    var len: usize = 0;
    const preamble = writePreamble(&buffer);
    len += preamble.len;
    var payload: [4096]u8 = undefined;
    var frame: [4200]u8 = undefined;
    const header_payload = try encodeHeader(.{ .platform_name = "macos", .app_name = "demo" }, &payload);
    var framed = try frameRecord(.header, header_payload, &frame);
    @memcpy(buffer[len .. len + framed.len], framed);
    len += framed.len;
    // End record claims one event; none were written.
    const end_payload = try encodeEnd(.{ .event_count = 1, .effect_count = 0, .checkpoint_count = 0, .screenshot_count = 0 }, &payload);
    framed = try frameRecord(.end, end_payload, &frame);
    @memcpy(buffer[len .. len + framed.len], framed);
    len += framed.len;
    var reader = try Reader.init(buffer[0..len]);
    _ = try reader.next(); // header
    try testing.expectError(error.JournalCountMismatch, reader.next());

    // A record whose length prefix exceeds the budget is refused before
    // any payload is touched.
    var hostile: [preamble_len + 5]u8 = undefined;
    _ = writePreamble(&hostile);
    hostile[preamble_len] = @intFromEnum(RecordKind.header);
    std.mem.writeInt(u32, hostile[preamble_len + 1 ..][0..4], std.math.maxInt(u32), .little);
    var hostile_reader = try Reader.init(&hostile);
    try testing.expectError(error.JournalRecordOverBudget, hostile_reader.next());
}

test "reader requires the header first" {
    var buffer: [1024]u8 = undefined;
    var len: usize = 0;
    len += writePreamble(&buffer).len;
    var payload: [64]u8 = undefined;
    var frame: [128]u8 = undefined;
    const event_payload = try encodeEvent(.app_start, &payload);
    const framed = try frameRecord(.event, event_payload, &frame);
    @memcpy(buffer[len .. len + framed.len], framed);
    len += framed.len;
    var reader = try Reader.init(buffer[0..len]);
    try testing.expectError(error.JournalMissingHeader, reader.next());
}
