//! Deterministic session journal: the on-disk format for record/replay.
//!
//! A Native SDK session consists of deterministic app init, platform
//! events, effect results, and synchronous OS chrome query results.
//! A journal file holds
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
//!   magic "NSDKSJNL" | u64 format fingerprint | records...
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
//! That feed-then-dispatch premise only holds if event boundaries are
//! CAUSAL: every result journaled ahead of an event must answer a
//! request issued by some EARLIER dispatch — otherwise the file-order
//! feed reaches a result whose request does not exist yet and replay
//! reports a false divergence. The live drain guarantees it: one drain
//! pass consumes only completions that existed when the pass began
//! (`Effects.DrainBoundary`), so a load spawned by an update handler
//! inside the pass — even one fast enough to finish before the pass
//! ends — delivers, and journals, under the NEXT wake's event record.
//!
//! Enum payloads ride as their declaration-order integer values, so
//! reordering any journaled enum is a format break — one
//! `format_fingerprint` sees on its own (the layout description
//! renders every journaled enum's names AND values).
//!
//! Coverage note: automation driving is fully journaled. Verbs that
//! synthesize PLATFORM events (widget-click/hold/context-press/drag/
//! wheel/key/pinch, resize, menu-command, shortcut, tray-action) journal
//! those events; every widget-action verb — including the direct-
//! surface ones (focus, select, set_selection, set_text, and the
//! composition edits) — journals as the outer-wins
//! `widget_accessibility_action` record its dispatch stages, with the
//! events it synthesizes inside suppressed as that record's children.
//! Replaying the action record re-runs the verb through the same
//! dispatch, so recorded sessions may drive text and selection through
//! any verb.

const std = @import("std");
const geometry = @import("geometry");
const platform = @import("../platform/root.zig");
const automation_protocol = @import("../automation/protocol.zig");
const layout_fingerprint = @import("../automation/layout_fingerprint.zig");
const runtime_effects = @import("effects.zig");
const journal_policy = @import("journal_policy.zig");
const codec = @import("session_codec.zig");

pub const EffectResultRecord = runtime_effects.EffectResultRecord;

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

/// File magic: first eight bytes of every session journal.
pub const magic = "NSDKSJNL";

/// Journal format identity. Any change to record layouts or journaled
/// enum orders moves this fingerprint ON ITS OWN — the layout
/// description below reflects over the actual record and event types —
/// and readers refuse a journal whose fingerprint differs from their
/// own, loudly, rather than misreading yesterday's shape.
///
/// This replaces the manually-bumped integer counter the preamble
/// carried through v8. No journal is ever migrated (replay refuses
/// every skew with the re-record teaching), so an ORDERED version
/// carried no information — "same or different" is the entire question
/// — while costing two recurring failures: parallel branches contending
/// for the next integer, and forgettable bumps.
///
/// History of the retired counter, kept because it documents real
/// breaks: v2 added the stream `buffering` flag to audio event and
/// audio effect records; v3 added the spectrum band bytes to both (and
/// the `.spectrum` audio kind); v4 added the composition verbs
/// (`set_composition`/`commit_composition`/`cancel_composition`, codes
/// 11-13) to the accessibility-action record's verb enum — a v3 reader
/// hitting one of those codes would have reported the file corrupt
/// instead of refusing the skew; v5 added the pinch magnification
/// `scale` field to gpu-surface input records plus the
/// `pinch_begin`/`pinch_change`/`pinch_end` input kinds (codes 12-14);
/// v6 added the `hidden` flag to window-frame records; v7 added the
/// `.image` effect-result kind (code 11) with its outcome/dimension
/// fields and the blob-store content address appended to every effect
/// record; v8 added the `.channel` effect-result kind (code 12) with
/// its event kind and cumulative drop total appended to every effect
/// record. Every one of those changes would now move the fingerprint
/// with no manual step.
pub const format_fingerprint: u64 = layout_fingerprint.hash(formatLayoutDescription(format_semantic_epoch));

/// The escape hatch for a change in MEANING that leaves the journal
/// bytes identical, which no layout description can see (the
/// automation-protocol side had exactly one: context-menu action tokens
/// becoming per-request generations — same bytes, values a stale build
/// could never match). Bump this ONLY for such semantics-only changes;
/// layout changes need NO action here — the fingerprint moves on its
/// own. Epoch 2: `.video_load` records became one-per-load (refused
/// cascades journal one too) and replay verifies the bijection — an
/// earlier journal's failed loads would replay as false divergence, so
/// the identical bytes must refuse. Epoch 3: the `video_kind` field on
/// `.video_load` records became the load's OUTCOME (`.loaded` or
/// `.failed`, steering the replayed fake's synchronous reset) where it
/// previously rode its default — same bytes, new meaning. Epoch 4:
/// `pointer_id` on gpu-surface input records reserved bit 63 as the
/// touch-source stamp (`platform.touch_pointer_id_bit`) — same bytes,
/// and an older recording whose host happened to emit ids with that
/// bit set would replay with hover-proof semantics it never had.
/// Epoch 5: audio positions and durations clamp into the exact-integer
/// window (below 2^53) at every delivery entry, and replay refuses an
/// out-of-window audio record as journal damage — an older recording
/// could journal a wider value the old feed paths accepted, which
/// would now be misreported as damage instead of refusing as a
/// different generation. Epoch 6: macOS Command+Backspace gained its
/// platform text-editor meaning (delete to field start in single-line
/// editors, or hard line start in textareas). The raw gpu-surface key record
/// is byte-identical, but replay now derives a text edit where older builds
/// derived none.
pub const format_semantic_epoch: u32 = 6;

/// The canonical description `format_fingerprint` hashes: everything
/// that defines the on-disk record layout. Reflection covers the record
/// kinds, the event-tag set, every record struct's field names/types/
/// order, the full effect record (including every journaled effect
/// enum's names and values), and each event variant's payload type.
/// Deliberate constants state what the hand-written codecs alone decide
/// — framing, string/optional/enum encodings, the modifier bit
/// assignments, the accessibility verb's i32 width, the
/// `gpu_surface_frame` journaled subset — each commented at its codec.
fn formatLayoutDescription(comptime epoch: u32) []const u8 {
    comptime {
        @setEvalBranchQuota(2_000_000);
        return "native-sdk session journal layout\n" ++
            std.fmt.comptimePrint("semantic_epoch={d}\n", .{epoch}) ++
            "magic=" ++ magic ++ "\n" ++
            "preamble=magic|u64 format fingerprint le\n" ++
            "framing=u8 kind|u32 payload_len le|payload\n" ++
            // Hand-written codec facts reflection cannot see; the
            // couplings are commented at WriteCursor, writeModifiers,
            // and the widget_accessibility_action arm.
            "codec=ints le;str=u32 len|bytes;bool=u8;enum=u8 of declaration value;optional=u8 presence|payload;" ++
            "modifiers=u8 bits primary=1 command=2 control=4 option=8 shift=16;" ++
            "accessibility action verb=i32;insets=top,right,bottom,left f32;rect=x,y,w,h f32\n" ++
            std.fmt.comptimePrint("max_drop_paths={d} (u16 count)\n", .{max_session_drop_paths}) ++
            "record_kinds=" ++ layout_fingerprint.describe(RecordKind) ++ "\n" ++
            "header=" ++ layout_fingerprint.describe(Header) ++ "\n" ++
            "checkpoint=" ++ layout_fingerprint.describe(Checkpoint) ++ "\n" ++
            "screenshot=" ++ layout_fingerprint.describe(ScreenshotMark) ++ "\n" ++
            "end=" ++ layout_fingerprint.describe(End) ++ "\n" ++
            "window_chrome=" ++ layout_fingerprint.describe(WindowChromeRecord) ++ "\n" ++
            "effect=" ++ layout_fingerprint.describe(EffectResultRecord) ++ "\n" ++
            "event_tags=" ++ layout_fingerprint.describe(EventTag) ++ "\n" ++
            // Per-variant payload types, reflected. Payload-free tags
            // (app_start, wake, ...) are covered by the tag set above; a
            // NEW tag moves the fingerprint through the tag set even
            // before its payload line lands here. `native_handle` never
            // rides the wire but its type is fixed; describing the full
            // Surface is the conservative direction (a false re-record
            // is cheap, a silent misread is not).
            "appearance_changed=" ++ layout_fingerprint.describe(platform.Appearance) ++ "\n" ++
            "surface_resized=" ++ layout_fingerprint.describe(platform.Surface) ++ "\n" ++
            "window_frame_changed=" ++ layout_fingerprint.describe(platform.WindowState) ++ "\n" ++
            "window_focused=" ++ layout_fingerprint.describe(platform.WindowId) ++ "\n" ++
            "view_focused=" ++ layout_fingerprint.describe(platform.ViewFocusEvent) ++ "\n" ++
            "bridge_message=" ++ layout_fingerprint.describe(platform.BridgeMessage) ++ "\n" ++
            "tray_action=" ++ layout_fingerprint.describe(platform.TrayItemId) ++ "\n" ++
            "shortcut=" ++ layout_fingerprint.describe(platform.ShortcutEvent) ++ "\n" ++
            "native_command=" ++ layout_fingerprint.describe(platform.NativeCommandEvent) ++ "\n" ++
            "menu_command=" ++ layout_fingerprint.describe(platform.MenuCommandEvent) ++ "\n" ++
            "tray_command=" ++ layout_fingerprint.describe(platform.TrayCommandEvent) ++ "\n" ++
            "notification_command=" ++ layout_fingerprint.describe(platform.NotificationCommandEvent) ++ "\n" ++
            "timer=" ++ layout_fingerprint.describe(platform.TimerEvent) ++ "\n" ++
            "audio=" ++ layout_fingerprint.describe(platform.AudioEvent) ++ "\n" ++
            "video=" ++ layout_fingerprint.describe(platform.VideoEvent) ++ "\n" ++
            "files_dropped=" ++ layout_fingerprint.describe(platform.FileDropEvent) ++ "\n" ++
            // gpu_surface_frame journals a deliberate SUBSET of a
            // telemetry-heavy struct (the rest is host render telemetry,
            // meaningless under replay), so its wire layout is stated by
            // hand — the coupling is commented at the encodeEvent arm.
            "gpu_surface_frame=window_id:u64,label:str,width:f32,height:f32,scale_factor:f32," ++
            "frame_index:u64,timestamp_ns:u64,frame_interval_ns:u64,input_timestamp_ns:u64,canvas_frame_full_repaint:bool\n" ++
            "gpu_surface_resized=" ++ layout_fingerprint.describe(platform.GpuSurfaceResizeEvent) ++ "\n" ++
            "gpu_surface_input=" ++ layout_fingerprint.describe(platform.GpuSurfaceInputEvent) ++ "\n" ++
            "gpu_surface_scroll_driver=" ++ layout_fingerprint.describe(platform.GpuSurfaceScrollDriverEvent) ++ "\n" ++
            "context_menu_action=" ++ layout_fingerprint.describe(platform.ContextMenuActionEvent) ++ "\n" ++
            "widget_accessibility_action=" ++ layout_fingerprint.describe(platform.WidgetAccessibilityActionEvent) ++ "\n" ++
            "widget_context_menu_action=" ++ layout_fingerprint.describe(platform.WidgetContextMenuActionEvent) ++ "\n";
    }
}

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
    /// The journal was written by a build whose journal format
    /// fingerprint differs from this one; replaying it here would
    /// misread payloads. Re-record with this build.
    JournalFormatMismatch,
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
    window_chrome = 7,
};

/// Maximum synchronous chrome queries consumed by one recorded event.
/// Per-event staging preserves nested dispatch and accessibility ownership.
pub const max_session_window_chrome_queries: usize = 256;

/// One OS capability result, consumed in query order by the following event.
/// Values are copied; no native window or borrowed storage crosses replay.
pub const WindowChromeRecord = struct {
    window_id: platform.WindowId,
    chrome: platform.WindowChrome,
};

/// A logic-only host has no window chrome capability. Its explicit
/// absence replays as zero geometry; native sessions capture every query.
pub const WindowChromeSource = enum(u8) { native_queries, unavailable };

/// Session identity, written once as the first record.
pub const Header = struct {
    /// The automation protocol fingerprint baked into the recording
    /// build — the existing CLI/app handshake identity, reused so a
    /// journal from a stale build is refused with the same teaching
    /// shape.
    protocol_fingerprint: u64 = automation_protocol.fingerprint,
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
    window_chrome_source: WindowChromeSource = .native_queries,
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
    window_chrome_count: u64 = 0,
};

pub const Record = union(RecordKind) {
    header: Header,
    event: platform.Event,
    effect: EffectResultRecord,
    checkpoint: Checkpoint,
    screenshot: ScreenshotMark,
    end: End,
    window_chrome: WindowChromeRecord,
};

/// Decode scratch for payloads that need an outer slice (dropped-file
/// path lists). Owned by the Reader; decoded events reference it until
/// the next `next()` call.
pub const EventDecodeStorage = struct {
    drop_paths: [max_session_drop_paths][]const u8 = undefined,
};

// ------------------------------------------------------------ cursors
//
// The primitive encodings these cursors hand-write (little-endian ints,
// u32-length-prefixed strings, u8 bools, enums as their u8 declaration
// value, bool-prefixed optionals) are stated as deliberate constants in
// `formatLayoutDescription` — reflection cannot see them, so changing
// one here means updating that description's `codec=` line in the same
// change.

pub fn encodeEvent(value: platform.Event, buffer: []u8) JournalError![]const u8 {
    return encodeEventWithPolicy(null, value, buffer);
}
pub fn encodeEventWithPolicy(policy: journal_policy.Policy, value: platform.Event, buffer: []u8) JournalError![]const u8 {
    return codec.encodeEvent(policy, value, buffer);
}
pub fn decodeEvent(bytes: []const u8, storage: *EventDecodeStorage) JournalError!platform.Event {
    return decodeEventWithPolicy(null, bytes, storage);
}
pub fn decodeEventWithPolicy(policy: journal_policy.Policy, bytes: []const u8, storage: *EventDecodeStorage) JournalError!platform.Event {
    return codec.decodeEvent(policy, bytes, storage);
}

pub fn encodeEffect(value: EffectResultRecord, buffer: []u8) JournalError![]const u8 {
    return encodeEffectWithPolicy(null, value, buffer);
}
pub fn encodeEffectWithPolicy(policy: journal_policy.Policy, value: EffectResultRecord, buffer: []u8) JournalError![]const u8 {
    return codec.encodeEffect(policy, value, buffer);
}
pub fn decodeEffect(bytes: []const u8) JournalError!EffectResultRecord {
    return decodeEffectWithPolicy(null, bytes);
}
pub fn decodeEffectWithPolicy(policy: journal_policy.Policy, bytes: []const u8) JournalError!EffectResultRecord {
    return codec.decodeEffect(policy, bytes);
}

pub fn encodeHeader(value: Header, buffer: []u8) JournalError![]const u8 {
    return encodeHeaderWithPolicy(null, value, buffer);
}
pub fn encodeHeaderWithPolicy(policy: journal_policy.Policy, value: Header, buffer: []u8) JournalError![]const u8 {
    return codec.encodeHeader(policy, value, buffer);
}
pub fn decodeHeader(bytes: []const u8) JournalError!Header {
    return decodeHeaderWithPolicy(null, bytes);
}
pub fn decodeHeaderWithPolicy(policy: journal_policy.Policy, bytes: []const u8) JournalError!Header {
    return codec.decodeHeader(policy, bytes);
}

pub fn encodeCheckpoint(value: Checkpoint, buffer: []u8) JournalError![]const u8 {
    return encodeCheckpointWithPolicy(null, value, buffer);
}
pub fn encodeCheckpointWithPolicy(policy: journal_policy.Policy, value: Checkpoint, buffer: []u8) JournalError![]const u8 {
    return codec.encodeCheckpoint(policy, value, buffer);
}
pub fn decodeCheckpoint(bytes: []const u8) JournalError!Checkpoint {
    return decodeCheckpointWithPolicy(null, bytes);
}
pub fn decodeCheckpointWithPolicy(policy: journal_policy.Policy, bytes: []const u8) JournalError!Checkpoint {
    return codec.decodeCheckpoint(policy, bytes);
}

pub fn encodeScreenshot(value: ScreenshotMark, buffer: []u8) JournalError![]const u8 {
    return encodeScreenshotWithPolicy(null, value, buffer);
}
pub fn encodeScreenshotWithPolicy(policy: journal_policy.Policy, value: ScreenshotMark, buffer: []u8) JournalError![]const u8 {
    return codec.encodeScreenshot(policy, value, buffer);
}
pub fn decodeScreenshot(bytes: []const u8) JournalError!ScreenshotMark {
    return decodeScreenshotWithPolicy(null, bytes);
}
pub fn decodeScreenshotWithPolicy(policy: journal_policy.Policy, bytes: []const u8) JournalError!ScreenshotMark {
    return codec.decodeScreenshot(policy, bytes);
}

pub fn encodeWindowChrome(value: WindowChromeRecord, buffer: []u8) JournalError![]const u8 {
    return encodeWindowChromeWithPolicy(null, value, buffer);
}
pub fn encodeWindowChromeWithPolicy(policy: journal_policy.Policy, value: WindowChromeRecord, buffer: []u8) JournalError![]const u8 {
    return codec.encodeWindowChrome(policy, value, buffer);
}
pub fn decodeWindowChrome(bytes: []const u8) JournalError!WindowChromeRecord {
    return decodeWindowChromeWithPolicy(null, bytes);
}
pub fn decodeWindowChromeWithPolicy(policy: journal_policy.Policy, bytes: []const u8) JournalError!WindowChromeRecord {
    return codec.decodeWindowChrome(policy, bytes);
}

pub fn encodeEnd(value: End, buffer: []u8) JournalError![]const u8 {
    return encodeEndWithPolicy(null, value, buffer);
}
pub fn encodeEndWithPolicy(policy: journal_policy.Policy, value: End, buffer: []u8) JournalError![]const u8 {
    return codec.encodeEnd(policy, value, buffer);
}
pub fn decodeEnd(bytes: []const u8) JournalError!End {
    return decodeEndWithPolicy(null, bytes);
}
pub fn decodeEndWithPolicy(policy: journal_policy.Policy, bytes: []const u8) JournalError!End {
    return codec.decodeEnd(policy, bytes);
}

// ------------------------------------------------------------ framing

/// Frame one record (kind + u32 length prefix + payload) into `buffer`.
pub fn frameRecord(kind: RecordKind, payload: []const u8, buffer: []u8) JournalError![]const u8 {
    return frameRecordWithPolicy(null, kind, payload, buffer);
}

pub fn frameRecordWithPolicy(policy: journal_policy.Policy, kind: RecordKind, payload: []const u8, buffer: []u8) JournalError![]const u8 {
    const frame = try frameHeader(policy, kind, payload.len, buffer.len);
    @memcpy(buffer[0..5], &frame);
    @memcpy(buffer[5 .. 5 + payload.len], payload);
    return buffer[0 .. 5 + payload.len];
}

/// A copied frame header; the caller still owns the payload and sink writes.
pub fn frameHeader(policy: journal_policy.Policy, kind: RecordKind, length: usize, capacity: usize) JournalError![5]u8 {
    const decision = journal_policy.plan(policy, .frame, .{ .kind = @intFromEnum(kind), .a = length, .b = capacity, .limit = max_session_record_bytes });
    try checkPlan(decision);
    return decision.frame;
}

fn checkPlan(decision: journal_policy.Plan) JournalError!void {
    switch (decision.action) {
        .proceed, .done => {},
        .bad_magic => return error.JournalBadMagic,
        .format_mismatch => return error.JournalFormatMismatch,
        .truncated => return error.JournalTruncated,
        .corrupt => return error.JournalCorrupt,
        .over_budget => return error.JournalRecordOverBudget,
        .missing_header => return error.JournalMissingHeader,
        .count_mismatch => return error.JournalCountMismatch,
    }
}

/// The journal preamble (magic + format fingerprint). The fingerprint
/// field widened from the retired u32 counter to the full u64 hash when
/// identity replaced ordering — this change refuses every older journal
/// anyway, and the full width keeps the refuse-on-mismatch tripwire's
/// collision odds at 2^-64 instead of 2^-32 for free.
pub fn writePreamble(buffer: []u8) []const u8 {
    return writePreambleWithPolicy(null, buffer);
}

pub fn writePreambleWithPolicy(policy: journal_policy.Policy, buffer: []u8) []const u8 {
    std.debug.assert(buffer.len >= preamble_len);
    const decision = journal_policy.plan(policy, .preamble, .{ .fingerprint = format_fingerprint });
    if (decision.action != .proceed) @panic("invalid compiled journal preamble");
    @memcpy(buffer[0..preamble_len], &decision.preamble);
    return buffer[0..preamble_len];
}

pub const preamble_len: usize = magic.len + 8;

/// Sequential journal reader over a whole in-memory journal. Validates
/// the preamble at init, enforces record budgets, and requires header
/// first and end record last (with matching counts) — a truncated or
/// tampered file fails loudly at the exact offending offset, never
/// crashes, never loops.
pub const Reader = struct {
    bytes: []const u8,
    pos: usize,
    policy: journal_policy.Policy = null,
    storage: EventDecodeStorage = .{},
    header: ?Header = null,
    end: ?End = null,
    event_count: u64 = 0,
    effect_count: u64 = 0,
    checkpoint_count: u64 = 0,
    screenshot_count: u64 = 0,
    window_chrome_count: u64 = 0,

    pub fn init(bytes: []const u8) JournalError!Reader {
        return initWithPolicy(bytes, null);
    }

    pub fn initWithPolicy(bytes: []const u8, policy: journal_policy.Policy) JournalError!Reader {
        const decision = journal_policy.plan(policy, .init, .{ .a = bytes.len, .fingerprint = format_fingerprint, .sample = bytes[0..@min(bytes.len, preamble_len)] });
        try checkPlan(decision);
        return .{ .bytes = bytes, .pos = @intCast(decision.pos), .policy = policy };
    }

    fn counts(self: *const Reader) [5]u64 {
        return .{ self.event_count, self.effect_count, self.checkpoint_count, self.screenshot_count, self.window_chrome_count };
    }

    /// The next record, or null after the end record. Records after the
    /// end record, a missing end record, and count mismatches are all
    /// refused.
    pub fn next(self: *Reader) JournalError!?Record {
        const old_pos = self.pos;
        const decision = journal_policy.plan(self.policy, .next, .{
            .a = self.bytes.len,
            .b = self.pos,
            .header = self.header != null,
            .ended = self.end != null,
            .counts = self.counts(),
            .sample = self.bytes[self.pos..][0..@min(self.bytes.len - self.pos, 5)],
            .limit = max_session_record_bytes,
        });
        // The admitted frame advances position and counters before payload
        // decoding. Even failed decodes retain those mutations.
        self.pos = @intCast(decision.pos);
        self.event_count = decision.counts[0];
        self.effect_count = decision.counts[1];
        self.checkpoint_count = decision.counts[2];
        self.screenshot_count = decision.counts[3];
        self.window_chrome_count = decision.counts[4];
        try checkPlan(decision);
        if (decision.action == .done) return null;
        const kind = std.enums.fromInt(RecordKind, decision.kind) orelse @panic("invalid compiled journal record kind");
        const payload = self.bytes[old_pos + 5 .. self.pos];

        switch (kind) {
            .header => {
                const header = try decodeHeaderWithPolicy(self.policy, payload);
                self.header = header;
                return .{ .header = header };
            },
            .event => {
                return .{ .event = try decodeEventWithPolicy(self.policy, payload, &self.storage) };
            },
            .effect => {
                return .{ .effect = try decodeEffectWithPolicy(self.policy, payload) };
            },
            .checkpoint => {
                return .{ .checkpoint = try decodeCheckpointWithPolicy(self.policy, payload) };
            },
            .screenshot => {
                return .{ .screenshot = try decodeScreenshotWithPolicy(self.policy, payload) };
            },
            .window_chrome => {
                return .{ .window_chrome = try decodeWindowChromeWithPolicy(self.policy, payload) };
            },
            .end => {
                const end = try decodeEndWithPolicy(self.policy, payload);
                try checkPlan(journal_policy.plan(self.policy, .seal, .{ .counts = self.counts(), .sealed = .{ end.event_count, end.effect_count, end.checkpoint_count, end.screenshot_count, end.window_chrome_count } }));
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
        error.JournalFormatMismatch => "journal was recorded by a build whose journal format differs from this build's - re-record the session with the same build that replays it",
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
        try testing.expect(!decoded.window_frame_changed.hidden);
    }
    {
        // v6: a policy-hide keeps the window alive (`open` true) and
        // rides the `hidden` flag — both must survive the round trip.
        const decoded = try roundTripEvent(.{ .window_frame_changed = .{
            .id = 1,
            .label = "main",
            .title = "Player",
            .frame = geometry.RectF.init(0, 0, 480, 360),
            .open = true,
            .focused = false,
            .hidden = true,
        } });
        try testing.expect(decoded.window_frame_changed.open);
        try testing.expect(decoded.window_frame_changed.hidden);
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
        // Video events journal the whole shape including the stream
        // dimensions the `.loaded` acknowledgment carries.
        const decoded = try roundTripEvent(.{ .video = .{
            .kind = .loaded,
            .position_ms = 0,
            .duration_ms = 92_500,
            .playing = true,
            .buffering = true,
            .width = 1280,
            .height = 720,
        } });
        try testing.expectEqual(platform.VideoEventKind.loaded, decoded.video.kind);
        try testing.expectEqual(@as(u64, 92_500), decoded.video.duration_ms);
        try testing.expect(decoded.video.playing);
        try testing.expect(decoded.video.buffering);
        try testing.expectEqual(@as(u64, 1280), decoded.video.width);
        try testing.expectEqual(@as(u64, 720), decoded.video.height);
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
        try testing.expectEqual(@as(f32, 0), decoded.gpu_surface_input.scale);
        try testing.expect(!decoded.gpu_surface_input.scroll_is_detented);
    }
    {
        const decoded = try roundTripEvent(.{ .gpu_surface_input = .{
            .label = "feed-canvas",
            .kind = .scroll,
            .delta_y = 40,
            .scroll_is_detented = true,
        } });
        try testing.expectEqual(platform.GpuSurfaceInputKind.scroll, decoded.gpu_surface_input.kind);
        try testing.expectEqual(@as(f32, 40), decoded.gpu_surface_input.delta_y);
        try testing.expect(decoded.gpu_surface_input.scroll_is_detented);
    }
    {
        // Command+Backspace journals as the raw platform key chord; replay
        // re-derives the semantic delete_to_start/delete_to_line_start edit
        // from the focused widget kind.
        const decoded = try roundTripEvent(.{ .gpu_surface_input = .{
            .label = "editor-canvas",
            .kind = .key_down,
            .key = "backspace",
            .modifiers = .{ .primary = true, .command = true },
        } });
        try testing.expectEqualStrings("backspace", decoded.gpu_surface_input.key);
        try testing.expect(decoded.gpu_surface_input.modifiers.primary);
        try testing.expect(decoded.gpu_surface_input.modifiers.command);
        try testing.expect(!decoded.gpu_surface_input.modifiers.control);
    }
    {
        // v5: pinch records carry the magnification delta and the
        // gesture kinds appended at codes 12-14.
        const decoded = try roundTripEvent(.{ .gpu_surface_input = .{
            .label = "timeline-canvas",
            .kind = .pinch_change,
            .timestamp_ns = 6,
            .x = 160,
            .y = 120,
            .scale = 0.25,
        } });
        try testing.expectEqual(platform.GpuSurfaceInputKind.pinch_change, decoded.gpu_surface_input.kind);
        try testing.expectEqual(@as(f32, 0.25), decoded.gpu_surface_input.scale);
        try testing.expectEqual(@as(f32, 160), decoded.gpu_surface_input.x);
        const begin = try roundTripEvent(.{ .gpu_surface_input = .{ .label = "timeline-canvas", .kind = .pinch_begin } });
        try testing.expectEqual(platform.GpuSurfaceInputKind.pinch_begin, begin.gpu_surface_input.kind);
        const end = try roundTripEvent(.{ .gpu_surface_input = .{ .label = "timeline-canvas", .kind = .pinch_end } });
        try testing.expectEqual(platform.GpuSurfaceInputKind.pinch_end, end.gpu_surface_input.kind);
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
            .offset_x = 7.25,
            .offset_y = -12.5,
            .timestamp_ns = 4,
        } });
        try testing.expectEqual(@as(f32, -12.5), decoded.gpu_surface_scroll_driver.offset_y);
        try testing.expectEqual(@as(f32, 7.25), decoded.gpu_surface_scroll_driver.offset_x);
    }
    {
        const decoded = try roundTripEvent(.{ .widget_context_menu_action = .{ .window_id = 7, .label = "secondary", .id = 0xffffffffffffffff, .item_index = 31 } });
        try testing.expectEqualDeep(platform.WidgetContextMenuActionEvent{ .window_id = 7, .label = "secondary", .id = 0xffffffffffffffff, .item_index = 31 }, decoded.widget_context_menu_action);
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
        const decoded = try roundTripEvent(.{ .tray_command = .{ .name = "app.refresh", .window_id = 3 } });
        try testing.expectEqualStrings("app.refresh", decoded.tray_command.name);
        try testing.expectEqual(@as(platform.WindowId, 3), decoded.tray_command.window_id);
    }
    {
        const decoded = try roundTripEvent(.{ .notification_command = .{ .name = "build.open", .window_id = 2 } });
        try testing.expectEqualStrings("build.open", decoded.notification_command.name);
        try testing.expectEqual(@as(platform.WindowId, 2), decoded.notification_command.window_id);
    }
    {
        const decoded = try roundTripEvent(.{ .tray_action = .{ .status_item_id = 3, .item_id = 9 } });
        try testing.expectEqual(@as(platform.StatusItemId, 3), decoded.tray_action.status_item_id);
        try testing.expectEqual(@as(platform.TrayItemId, 9), decoded.tray_action.item_id);
    }
    {
        const decoded = try roundTripEvent(.{ .window_focused = 4 });
        try testing.expectEqual(@as(u64, 4), decoded.window_focused);
    }
    {
        const decoded = try roundTripEvent(.{ .view_focused = .{ .window_id = 4, .label = "preview" } });
        try testing.expectEqual(@as(u64, 4), decoded.view_focused.window_id);
        try testing.expectEqualStrings("preview", decoded.view_focused.label);
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

    const delete_encoded = try encodeEffect(.{
        .kind = .file,
        .key = 78,
        .file_op = .delete,
        .file_outcome = .not_found,
    }, &buffer);
    const delete_decoded = try decodeEffect(delete_encoded);
    try testing.expectEqual(runtime_effects.EffectResultKind.file, delete_decoded.kind);
    try testing.expectEqual(runtime_effects.EffectFileOp.delete, delete_decoded.file_op);
    try testing.expectEqual(runtime_effects.EffectFileOutcome.not_found, delete_decoded.file_outcome);

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

    // v8: channel records carry their event kind and the cumulative
    // drop total; the post bytes ride the shared payload field INLINE
    // (never the blob store).
    const channel_encoded = try encodeEffect(.{
        .kind = .channel,
        .key = 88,
        .payload = "cpu 12.5",
        .dropped = 2,
        .channel_kind = .data,
        .channel_dropped_total = 7,
    }, &buffer);
    const channel_decoded = try decodeEffect(channel_encoded);
    try testing.expectEqual(runtime_effects.EffectResultKind.channel, channel_decoded.kind);
    try testing.expectEqual(@as(u64, 88), channel_decoded.key);
    try testing.expectEqualStrings("cpu 12.5", channel_decoded.payload);
    try testing.expectEqual(runtime_effects.EffectChannelEventKind.data, channel_decoded.channel_kind);
    try testing.expectEqual(@as(u32, 2), channel_decoded.dropped);
    try testing.expectEqual(@as(u32, 7), channel_decoded.channel_dropped_total);

    const closed_encoded = try encodeEffect(.{
        .kind = .channel,
        .key = 88,
        .channel_kind = .closed,
        .channel_dropped_total = 7,
    }, &buffer);
    const closed_decoded = try decodeEffect(closed_encoded);
    try testing.expectEqual(runtime_effects.EffectChannelEventKind.closed, closed_decoded.channel_kind);
    try testing.expectEqual(@as(usize, 0), closed_decoded.payload.len);

    // Video effect records round-trip the whole delivered event —
    // including the dimensions the `.loaded` acknowledgment carries —
    // because the journaled record is replay's only Msg source.
    const video_encoded = try encodeEffect(.{
        .kind = .video,
        .key = 61,
        .video_kind = .loaded,
        .video_position_ms = 0,
        .video_duration_ms = 92_500,
        .video_playing = true,
        .video_buffering = true,
        .video_width = 1280,
        .video_height = 720,
    }, &buffer);
    const video_decoded = try decodeEffect(video_encoded);
    try testing.expectEqual(runtime_effects.EffectResultKind.video, video_decoded.kind);
    try testing.expectEqual(@as(u64, 61), video_decoded.key);
    try testing.expectEqual(runtime_effects.EffectVideoEventKind.loaded, video_decoded.video_kind);
    try testing.expectEqual(@as(u64, 92_500), video_decoded.video_duration_ms);
    try testing.expect(video_decoded.video_playing);
    try testing.expect(video_decoded.video_buffering);
    try testing.expectEqual(@as(u64, 1280), video_decoded.video_width);
    try testing.expectEqual(@as(u64, 720), video_decoded.video_height);

    // Persistence is a kind-local suffix: successful restore bytes live in
    // the blob store, while the journal carries its closed outcome/address.
    const persist_hash: [runtime_effects.effect_image_blob_hash_len]u8 = @splat(0xa5);
    const persist_encoded = try encodeEffect(.{
        .kind = .persist,
        .key = 0,
        .persist_outcome = .ok,
        .persist_blob_hash = persist_hash,
        .persist_blob_len = 4096,
    }, &buffer);
    const persist_decoded = try decodeEffect(persist_encoded);
    try testing.expectEqual(runtime_effects.EffectResultKind.persist, persist_decoded.kind);
    try testing.expectEqual(runtime_effects.EffectPersistOutcome.ok, persist_decoded.persist_outcome);
    try testing.expectEqualSlices(u8, &persist_hash, &persist_decoded.persist_blob_hash);
    try testing.expectEqual(@as(u64, 4096), persist_decoded.persist_blob_len);

    const db_hash: [runtime_effects.effect_image_blob_hash_len]u8 = @splat(0x5a);
    const db_encoded = try encodeEffect(.{
        .kind = .db,
        .key = 73,
        .code = runtime_effects.dbJournalCode(.page, .ok),
        .db_blob_hash = db_hash,
        .db_blob_len = 96 * 1024,
    }, &buffer);
    const db_decoded = try decodeEffect(db_encoded);
    try testing.expectEqual(runtime_effects.EffectResultKind.db, db_decoded.kind);
    try testing.expectEqualSlices(u8, &db_hash, &db_decoded.db_blob_hash);
    try testing.expectEqual(@as(u64, 96 * 1024), db_decoded.db_blob_len);

    const credential_digest: [32]u8 = @splat(0x39);
    const credential_salt: [16]u8 = @splat(0x17);
    const credential_encoded = try encodeEffect(.{
        .kind = .credentials,
        .key = 81,
        .credentials_operation = .get,
        .credentials_outcome = .ok,
        .credentials_secret_len = 27,
        .credentials_salt = credential_salt,
        .credentials_digest = credential_digest,
    }, &buffer);
    const credential_decoded = try decodeEffect(credential_encoded);
    try testing.expectEqual(runtime_effects.EffectResultKind.credentials, credential_decoded.kind);
    try testing.expectEqual(runtime_effects.EffectCredentialsOperation.get, credential_decoded.credentials_operation);
    try testing.expectEqual(runtime_effects.EffectCredentialsOutcome.ok, credential_decoded.credentials_outcome);
    try testing.expectEqual(@as(u64, 27), credential_decoded.credentials_secret_len);
    try testing.expectEqualSlices(u8, &credential_salt, &credential_decoded.credentials_salt);
    try testing.expectEqualSlices(u8, &credential_digest, &credential_decoded.credentials_digest);
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
    try testing.expectEqual(automation_protocol.fingerprint, header.protocol_fingerprint);

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

test "reader refuses bad magic and format skew" {
    var buffer: [16384]u8 = undefined;
    const len = try buildTestJournal(&buffer);
    try testing.expectError(error.JournalBadMagic, Reader.init("not a journal at all"));
    try testing.expectError(error.JournalBadMagic, Reader.init(""));
    // A journal whose recorded fingerprint differs from this build's —
    // any other build's journal, in either direction — is refused at
    // the preamble, before any record layout is consulted, instead of
    // reporting an unknown payload code as corruption.
    var skewed: [16384]u8 = undefined;
    @memcpy(skewed[0..len], buffer[0..len]);
    std.mem.writeInt(u64, skewed[magic.len..][0..8], format_fingerprint +% 1, .little);
    try testing.expectError(error.JournalFormatMismatch, Reader.init(skewed[0..len]));
    std.mem.writeInt(u64, skewed[magic.len..][0..8], format_fingerprint -% 1, .little);
    try testing.expectError(error.JournalFormatMismatch, Reader.init(skewed[0..len]));
    // A journal from the retired integer-counter era (u32 version after
    // the magic, so this reader's u64 read spans the counter plus the
    // first record's framing bytes) is the same honest mismatch.
    var legacy: [preamble_len]u8 = undefined;
    @memcpy(legacy[0..magic.len], magic);
    std.mem.writeInt(u32, legacy[magic.len..][0..4], 8, .little);
    legacy[magic.len + 4] = @intFromEnum(RecordKind.header);
    std.mem.writeInt(u24, legacy[magic.len + 5 ..][0..3], 42, .little);
    try testing.expectError(error.JournalFormatMismatch, Reader.init(&legacy));
    // The teaching says whose build differs and what to do about it,
    // so the reader of the error never suspects file damage.
    const teaching = describeError(error.JournalFormatMismatch);
    try testing.expect(std.mem.indexOf(u8, teaching, "journal format") != null);
    try testing.expect(std.mem.indexOf(u8, teaching, "re-record") != null);
}

test "layout description moves with the semantic epoch" {
    // Same layout, bumped epoch: the combined fingerprint must move, so
    // a meaning-only change (identical bytes) still refuses replay of
    // journals recorded before it.
    const bumped = layout_fingerprint.hash(comptime formatLayoutDescription(format_semantic_epoch + 1));
    try testing.expect(bumped != format_fingerprint);
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

test "window chrome codec preserves every OS field and refuses damaged payloads" {
    const expected: WindowChromeRecord = .{
        .window_id = 18446744073709551615,
        .chrome = .{ .insets = .{ .top = 66, .right = 7.25, .bottom = 3.5, .left = 98 }, .buttons = .init(20, 26, 68, 14), .form_factor = .compact, .tabs_projected = true },
    };
    var buffer: [64]u8 = undefined;
    const bytes = try encodeWindowChrome(expected, &buffer);
    try testing.expectEqualDeep(expected, try decodeWindowChrome(bytes));
    for (0..bytes.len) |len| try testing.expectError(error.JournalCorrupt, decodeWindowChrome(bytes[0..len]));
    buffer[bytes.len] = 0;
    try testing.expectError(error.JournalCorrupt, decodeWindowChrome(buffer[0 .. bytes.len + 1]));
    buffer[40] = 255;
    try testing.expectError(error.JournalCorrupt, decodeWindowChrome(bytes));
    buffer[40] = 1;
    buffer[41] = 2;
    try testing.expectError(error.JournalCorrupt, decodeWindowChrome(bytes));
}

comptime {
    if (!std.mem.eql(u8, magic, "NSDKSJNL") or preamble_len != 16 or max_session_record_bytes != 1114112 or
        @typeInfo(RecordKind).@"enum".fields.len != 7 or @intFromEnum(RecordKind.header) != 1 or
        @intFromEnum(RecordKind.event) != 2 or @intFromEnum(RecordKind.effect) != 3 or
        @intFromEnum(RecordKind.checkpoint) != 4 or @intFromEnum(RecordKind.screenshot) != 5 or
        @intFromEnum(RecordKind.end) != 6 or @intFromEnum(RecordKind.window_chrome) != 7)
        @compileError("update the portable journal framing schema with the journal format");
}
