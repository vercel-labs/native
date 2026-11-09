//! Independent session payload codec reference.
const std = @import("std");
const geometry = @import("geometry");
const platform = @import("../platform/root.zig");
const runtime_effects = @import("effects.zig");
const journal = @import("session_journal.zig");
const JournalError = journal.JournalError;
const EffectResultRecord = journal.EffectResultRecord;
const Header = journal.Header;
const Checkpoint = journal.Checkpoint;
const ScreenshotMark = journal.ScreenshotMark;
const WindowChromeRecord = journal.WindowChromeRecord;
const WindowChromeSource = journal.WindowChromeSource;
const End = journal.End;
const EventDecodeStorage = journal.EventDecodeStorage;
const max_session_drop_paths = journal.max_session_drop_paths;

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
    video = 25,
    view_focused = 26,
    tray_command = 27,
    notification_command = 28,
    widget_context_menu_action = 29,
};

// The bit assignments below are hand-written wire layout: they are
// stated in `formatLayoutDescription` (reflection sees the bool fields,
// not the bits), so changing a bit here means updating that line too.
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
            // v6: alive-but-policy-hidden (`close_policy = .hide`).
            try cursor.writeBool(state.hidden);
        },
        .window_focused => |window_id| {
            try cursor.writeEnum(EventTag.window_focused);
            try cursor.writeInt(u64, window_id);
        },
        .view_focused => |focus| {
            try cursor.writeEnum(EventTag.view_focused);
            try cursor.writeInt(u64, focus.window_id);
            try cursor.writeStr(focus.label);
        },
        .bridge_message => |message| {
            try cursor.writeEnum(EventTag.bridge_message);
            try cursor.writeStr(message.bytes);
            try cursor.writeStr(message.origin);
            try cursor.writeInt(u64, message.window_id);
            try cursor.writeStr(message.webview_label);
        },
        .tray_action => |action| {
            try cursor.writeEnum(EventTag.tray_action);
            try cursor.writeInt(u32, action.status_item_id);
            try cursor.writeInt(u32, action.item_id);
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
        .tray_command => |command| {
            try cursor.writeEnum(EventTag.tray_command);
            try cursor.writeStr(command.name);
            try cursor.writeInt(u64, command.window_id);
            try cursor.writeInt(u32, command.status_item_id);
        },
        .notification_command => |command| {
            try cursor.writeEnum(EventTag.notification_command);
            try cursor.writeStr(command.name);
            try cursor.writeInt(u64, command.window_id);
        },
        .timer => |timer| {
            try cursor.writeEnum(EventTag.timer);
            try cursor.writeInt(u64, timer.id);
            try cursor.writeInt(u64, timer.timestamp_ns);
        },
        // Recorded for stream fidelity. On replay this event pairs with
        // its complete audio EFFECT record and delivers the recorded Msg
        // synchronously, preserving the live rebuild/query boundary.
        .audio => |audio| {
            try cursor.writeEnum(EventTag.audio);
            try cursor.writeEnum(audio.kind);
            try cursor.writeInt(u64, audio.position_ms);
            try cursor.writeInt(u64, audio.duration_ms);
            try cursor.writeBool(audio.playing);
            try cursor.writeBool(audio.buffering);
            try cursor.writeBytes(&audio.bands);
        },
        // Recorded for stream fidelity like `.audio`. On replay the
        // journaled video EFFECT records are the Msg source; the
        // platform events steer only the channel MIRRORS (the house
        // chrome's render state for handler-less playbacks), gated by
        // the load token exactly as live (`Effects.takeVideoMsg`).
        .video => |video| {
            try cursor.writeEnum(EventTag.video);
            try cursor.writeEnum(video.kind);
            try cursor.writeInt(u64, video.token);
            try cursor.writeInt(u64, video.position_ms);
            try cursor.writeInt(u64, video.duration_ms);
            try cursor.writeBool(video.playing);
            try cursor.writeBool(video.buffering);
            try cursor.writeInt(u64, video.width);
            try cursor.writeInt(u64, video.height);
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
        // This arm journals a deliberate SUBSET of the frame event (the
        // fields dispatch semantics depend on — see the fn doc). The
        // subset is stated by hand in `formatLayoutDescription`, so
        // journaling another field here means adding it to that line in
        // the same change.
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
            try cursor.writeBool(input.scroll_is_detented);
            try cursor.writeStr(input.key);
            try cursor.writeStr(input.text);
            try cursor.writeBool(input.composition_cursor != null);
            if (input.composition_cursor) |composition_cursor| {
                try cursor.writeInt(u64, @intCast(composition_cursor));
            }
            try writeModifiers(&cursor, input.modifiers);
            // v5: the pinch magnification delta (0 on non-pinch kinds).
            try cursor.writeF32(input.scale);
        },
        .gpu_surface_scroll_driver => |driver| {
            try cursor.writeEnum(EventTag.gpu_surface_scroll_driver);
            try cursor.writeInt(u64, driver.window_id);
            try cursor.writeStr(driver.label);
            try cursor.writeInt(u64, driver.driver_id);
            try cursor.writeF32(driver.offset_x);
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
        .widget_context_menu_action => |action| {
            try cursor.writeEnum(EventTag.widget_context_menu_action);
            try cursor.writeInt(u64, action.window_id);
            try cursor.writeStr(action.label);
            try cursor.writeInt(u64, action.id);
            try cursor.writeInt(u32, action.item_index);
        },
        .widget_accessibility_action => |action| {
            try cursor.writeEnum(EventTag.widget_accessibility_action);
            try cursor.writeInt(u64, action.window_id);
            try cursor.writeStr(action.label);
            try cursor.writeInt(u64, action.id);
            // The verb rides i32, not the u8 every other enum takes — a
            // hand-written width stated in `formatLayoutDescription`.
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
                .hidden = try cursor.readBool(),
            } };
        },
        .window_focused => .{ .window_focused = try cursor.readInt(u64) },
        .view_focused => .{ .view_focused = .{
            .window_id = try cursor.readInt(u64),
            .label = try cursor.readStr(),
        } },
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
        .tray_action => .{ .tray_action = .{
            .status_item_id = try cursor.readInt(u32),
            .item_id = try cursor.readInt(u32),
        } },
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
        .tray_command => blk: {
            const name = try cursor.readStr();
            break :blk .{ .tray_command = .{
                .name = name,
                .window_id = try cursor.readInt(u64),
                .status_item_id = try cursor.readInt(u32),
            } };
        },
        .notification_command => blk: {
            const name = try cursor.readStr();
            break :blk .{ .notification_command = .{
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
        .video => blk: {
            const kind = try cursor.readEnum(platform.VideoEventKind);
            break :blk .{ .video = .{
                .kind = kind,
                .token = try cursor.readInt(u64),
                .position_ms = try cursor.readInt(u64),
                .duration_ms = try cursor.readInt(u64),
                .playing = try cursor.readBool(),
                .buffering = try cursor.readBool(),
                .width = try cursor.readInt(u64),
                .height = try cursor.readInt(u64),
            } };
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
            const scroll_is_detented = try cursor.readBool();
            const key = try cursor.readStr();
            const text = try cursor.readStr();
            var composition_cursor: ?usize = null;
            if (try cursor.readBool()) {
                composition_cursor = std.math.cast(usize, try cursor.readInt(u64)) orelse return error.JournalCorrupt;
            }
            break :blk .{
                .gpu_surface_input = .{
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
                    .scroll_is_detented = scroll_is_detented,
                    .key = key,
                    .text = text,
                    .composition_cursor = composition_cursor,
                    .modifiers = try readModifiers(&cursor),
                    // v5: the pinch magnification delta (0 on non-pinch kinds).
                    .scale = try cursor.readF32(),
                },
            };
        },
        .gpu_surface_scroll_driver => blk: {
            const window_id = try cursor.readInt(u64);
            const label = try cursor.readStr();
            const driver_id = try cursor.readInt(u64);
            const offset_x = try cursor.readF32();
            const offset_y = try cursor.readF32();
            break :blk .{ .gpu_surface_scroll_driver = .{
                .window_id = window_id,
                .label = label,
                .driver_id = driver_id,
                .offset_x = offset_x,
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
        .widget_context_menu_action => blk: {
            const window_id = try cursor.readInt(u64);
            const label = try cursor.readStr();
            const id = try cursor.readInt(u64);
            const item_index = try cursor.readInt(u32);
            break :blk .{ .widget_context_menu_action = .{ .window_id = window_id, .label = label, .id = id, .item_index = item_index } };
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
    try cursor.writeEnum(record.file_event);
    try cursor.writeEnum(record.file_outcome);
    try cursor.writeInt(u64, record.file_total);
    try cursor.writeInt(i64, record.file_mtime_ms);
    try cursor.writeBool(record.file_exists);
    try cursor.writeBool(record.file_rejected_admission);
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
    try cursor.writeBytes(&record.file_blob_hash);
    try cursor.writeInt(u64, record.file_blob_len);
    try cursor.writeBytes(&record.audio_bands);
    // v7: image terminals — outcome, decoded dimensions, and the blob
    // store content address of the journaled source bytes.
    try cursor.writeEnum(record.image_outcome);
    try cursor.writeInt(u64, record.image_width);
    try cursor.writeInt(u64, record.image_height);
    try cursor.writeBytes(&record.image_blob_hash);
    try cursor.writeInt(u64, record.image_blob_len);
    // v8: channel events — the event kind and the occupancy's
    // cumulative drop total (post bytes ride `payload` inline;
    // dropped_pending rides the shared `dropped` field).
    try cursor.writeEnum(record.channel_kind);
    try cursor.writeInt(u32, record.channel_dropped_total);
    // Video terminals — the delivered event, verbatim (fingerprint
    // era: these fields move the format identity through reflection).
    try cursor.writeEnum(record.video_kind);
    try cursor.writeInt(u64, record.video_position_ms);
    try cursor.writeInt(u64, record.video_duration_ms);
    try cursor.writeBool(record.video_playing);
    try cursor.writeBool(record.video_buffering);
    try cursor.writeInt(u64, record.video_width);
    try cursor.writeInt(u64, record.video_height);
    // The producing load's identity, how replay routes the record
    // (`EffectResultRecord.video_token`).
    try cursor.writeInt(u64, record.video_token);
    // `.video_load` records: the recording host's cascade resolution.
    try cursor.writeEnum(record.video_source);
    // `.video` records: whether the delivery dispatched a Msg.
    try cursor.writeBool(record.video_handled);
    // Pty events — the event kind, the terminating signal and refused
    // writes, and the blob store content address of a journaled output
    // batch (exit code and reason ride the shared fields).
    try cursor.writeEnum(record.pty_kind);
    try cursor.writeInt(i32, record.pty_signal);
    try cursor.writeInt(u32, record.pty_dropped_writes);
    try cursor.writeBytes(&record.pty_blob_hash);
    try cursor.writeInt(u64, record.pty_blob_len);
    // Model restore is the first kind-local suffix. Keeping it conditional
    // preserves every established effect record's byte layout (tests and
    // tooling deliberately patch those records at known offsets).
    if (record.kind == .persist) {
        try cursor.writeEnum(record.persist_outcome);
        try cursor.writeBytes(&record.persist_blob_hash);
        try cursor.writeInt(u64, record.persist_blob_len);
    }
    if (record.kind == .db) {
        try cursor.writeBytes(&record.db_blob_hash);
        try cursor.writeInt(u64, record.db_blob_len);
    }
    if (record.kind == .credentials) {
        try cursor.writeEnum(record.credentials_operation);
        try cursor.writeEnum(record.credentials_outcome);
        try cursor.writeInt(u64, record.credentials_secret_len);
        try cursor.writeBytes(&record.credentials_salt);
        try cursor.writeBytes(&record.credentials_digest);
    }
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
        .file_event = try cursor.readEnum(runtime_effects.EffectFileEvent),
        .file_outcome = try cursor.readEnum(runtime_effects.EffectFileOutcome),
        .file_total = try cursor.readInt(u64),
        .file_mtime_ms = try cursor.readInt(i64),
        .file_exists = try cursor.readBool(),
        .file_rejected_admission = try cursor.readBool(),
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
    @memcpy(&record.file_blob_hash, try cursor.readBytes(record.file_blob_hash.len));
    record.file_blob_len = try cursor.readInt(u64);
    @memcpy(&record.audio_bands, try cursor.readBytes(record.audio_bands.len));
    // v7: image terminals.
    record.image_outcome = try cursor.readEnum(runtime_effects.EffectImageOutcome);
    record.image_width = try cursor.readInt(u64);
    record.image_height = try cursor.readInt(u64);
    @memcpy(&record.image_blob_hash, try cursor.readBytes(record.image_blob_hash.len));
    record.image_blob_len = try cursor.readInt(u64);
    // v8: channel events.
    record.channel_kind = try cursor.readEnum(runtime_effects.EffectChannelEventKind);
    record.channel_dropped_total = try cursor.readInt(u32);
    // Video terminals.
    record.video_kind = try cursor.readEnum(runtime_effects.EffectVideoEventKind);
    record.video_position_ms = try cursor.readInt(u64);
    record.video_duration_ms = try cursor.readInt(u64);
    record.video_playing = try cursor.readBool();
    record.video_buffering = try cursor.readBool();
    record.video_width = try cursor.readInt(u64);
    record.video_height = try cursor.readInt(u64);
    record.video_token = try cursor.readInt(u64);
    record.video_source = try cursor.readEnum(runtime_effects.EffectVideoSource);
    record.video_handled = try cursor.readBool();
    // Pty events.
    record.pty_kind = try cursor.readEnum(runtime_effects.EffectPtyEventKind);
    record.pty_signal = try cursor.readInt(i32);
    record.pty_dropped_writes = try cursor.readInt(u32);
    @memcpy(&record.pty_blob_hash, try cursor.readBytes(record.pty_blob_hash.len));
    record.pty_blob_len = try cursor.readInt(u64);
    if (record.kind == .persist) {
        record.persist_outcome = try cursor.readEnum(runtime_effects.EffectPersistOutcome);
        @memcpy(&record.persist_blob_hash, try cursor.readBytes(record.persist_blob_hash.len));
        record.persist_blob_len = try cursor.readInt(u64);
    }
    if (record.kind == .db) {
        @memcpy(&record.db_blob_hash, try cursor.readBytes(record.db_blob_hash.len));
        record.db_blob_len = try cursor.readInt(u64);
    }
    if (record.kind == .credentials) {
        record.credentials_operation = try cursor.readEnum(runtime_effects.EffectCredentialsOperation);
        record.credentials_outcome = try cursor.readEnum(runtime_effects.EffectCredentialsOutcome);
        record.credentials_secret_len = try cursor.readInt(u64);
        @memcpy(&record.credentials_salt, try cursor.readBytes(record.credentials_salt.len));
        @memcpy(&record.credentials_digest, try cursor.readBytes(record.credentials_digest.len));
    }
    if (!cursor.done()) return error.JournalCorrupt;
    return record;
}

// ----------------------------------------------------- other codecs

pub fn encodeHeader(header: Header, buffer: []u8) JournalError![]const u8 {
    var cursor = WriteCursor{ .buffer = buffer };
    try cursor.writeInt(u64, header.protocol_fingerprint);
    try cursor.writeStr(header.platform_name);
    try cursor.writeStr(header.app_name);
    try cursor.writeInt(i64, header.recorded_at_wall_ms);
    try cursor.writeF32(header.window_width);
    try cursor.writeF32(header.window_height);
    try cursor.writeEnum(header.window_chrome_source);
    return buffer[0..cursor.len];
}

pub fn decodeHeader(bytes: []const u8) JournalError!Header {
    var cursor = ReadCursor{ .bytes = bytes };
    const header: Header = .{
        .protocol_fingerprint = try cursor.readInt(u64),
        .platform_name = try cursor.readStr(),
        .app_name = try cursor.readStr(),
        .recorded_at_wall_ms = try cursor.readInt(i64),
        .window_width = try cursor.readF32(),
        .window_height = try cursor.readF32(),
        .window_chrome_source = try cursor.readEnum(WindowChromeSource),
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

pub fn encodeWindowChrome(record: WindowChromeRecord, buffer: []u8) JournalError![]const u8 {
    var cursor = WriteCursor{ .buffer = buffer };
    try cursor.writeInt(u64, record.window_id);
    try writeInsets(&cursor, record.chrome.insets);
    try writeRect(&cursor, record.chrome.buttons);
    try cursor.writeEnum(record.chrome.form_factor);
    try cursor.writeBool(record.chrome.tabs_projected);
    return buffer[0..cursor.len];
}

pub fn decodeWindowChrome(bytes: []const u8) JournalError!WindowChromeRecord {
    var cursor = ReadCursor{ .bytes = bytes };
    const record: WindowChromeRecord = .{
        .window_id = try cursor.readInt(u64),
        .chrome = .{
            .insets = try readInsets(&cursor),
            .buttons = try readRect(&cursor),
            .form_factor = try cursor.readEnum(platform.FormFactor),
            .tabs_projected = try cursor.readBool(),
        },
    };
    if (!cursor.done()) return error.JournalCorrupt;
    return record;
}

pub fn encodeEnd(end: End, buffer: []u8) JournalError![]const u8 {
    var cursor = WriteCursor{ .buffer = buffer };
    try cursor.writeInt(u64, end.event_count);
    try cursor.writeInt(u64, end.effect_count);
    try cursor.writeInt(u64, end.checkpoint_count);
    try cursor.writeInt(u64, end.screenshot_count);
    try cursor.writeInt(u64, end.window_chrome_count);
    return buffer[0..cursor.len];
}

pub fn decodeEnd(bytes: []const u8) JournalError!End {
    var cursor = ReadCursor{ .bytes = bytes };
    const end: End = .{
        .event_count = try cursor.readInt(u64),
        .effect_count = try cursor.readInt(u64),
        .checkpoint_count = try cursor.readInt(u64),
        .screenshot_count = try cursor.readInt(u64),
        .window_chrome_count = try cursor.readInt(u64),
    };
    if (!cursor.done()) return error.JournalCorrupt;
    return end;
}

