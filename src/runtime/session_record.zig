//! Session recorder: streams a live session into the journal format.
//!
//! Wired through `Runtime.Options.session_recorder`, the dispatch choke
//! point stages every platform event on entry and commits it on exit, so
//! effect results drained DURING an event's dispatch land in the stream
//! BEFORE the event record — the ordering replay depends on (feed the
//! stub executor, then dispatch). Nested dispatches (automation commands
//! inside `frame_requested`) commit innermost-first for the same reason.
//! One exception: events nested inside a dispatched accessibility
//! action are suppressed — replaying the action re-derives them, so the
//! outer record is the whole representation (see `stageEvent`).
//!
//! Recording must never take the app down: any failure — a sink write
//! error, an over-budget event, a journal past its size budget — flips
//! the recorder into a failed state that says so loudly on stderr ONCE
//! and drops everything after. A failed recording has no end record, so
//! replay refuses it as truncated instead of silently replaying a
//! prefix.
//!
//! The struct embeds multi-megabyte staging buffers — construct it on
//! the heap (the Runtime precedent).

const std = @import("std");
const platform = @import("../platform/root.zig");
const runtime_clock = @import("clock.zig");
const runtime_effects = @import("effects.zig");
const journal = @import("session_journal.zig");

pub const Header = journal.Header;

/// Where journal bytes go. The app runner backs this with a file opened
/// at launch; tests back it with a growable buffer.
pub const RecorderSink = struct {
    context: *anyopaque,
    write_fn: *const fn (context: *anyopaque, bytes: []const u8) anyerror!void,
};

pub const SessionRecorder = struct {
    sink: RecorderSink,
    began: bool = false,
    finished: bool = false,
    failed: bool = false,
    bytes_written: u64 = 0,
    event_count: u64 = 0,
    effect_count: u64 = 0,
    checkpoint_count: u64 = 0,
    screenshot_count: u64 = 0,
    /// Frame index of the last recorded checkpoint, so exactly one
    /// checkpoint follows each published frame.
    last_checkpoint_frame: u64 = 0,
    depth: usize = 0,
    /// Staging-stack depth of the `widget_accessibility_action` event
    /// currently being dispatched, if any. While set, nested
    /// stage/commit pairs are suppressed: the outer action record is the
    /// journal's WHOLE representation of the interaction (see
    /// `stageEvent`).
    suppress_owner_depth: ?usize = null,
    staged_lens: [journal.max_session_event_depth]usize = [_]usize{0} ** journal.max_session_event_depth,
    staged_suppressed: [journal.max_session_event_depth]bool = [_]bool{false} ** journal.max_session_event_depth,
    staged: [journal.max_session_event_depth][journal.max_session_event_bytes]u8 = undefined,
    /// Encode scratch for effect payloads (up to a whole file read).
    effect_buffer: [journal.max_session_record_bytes]u8 = undefined,
    small_buffer: [1024]u8 = undefined,

    pub fn init(sink: RecorderSink) SessionRecorder {
        return .{ .sink = sink };
    }

    /// Write the preamble and session header. Must run before the first
    /// dispatched event.
    pub fn begin(self: *SessionRecorder, header: Header) void {
        if (self.began or self.failed) return;
        self.began = true;
        var preamble_buffer: [journal.preamble_len]u8 = undefined;
        self.write(journal.writePreamble(&preamble_buffer));
        const payload = journal.encodeHeader(header, &self.small_buffer) catch {
            return self.fail("session header does not fit its record budget");
        };
        self.writeRecord(.header, payload);
    }

    /// Serialize `event` into the staging stack. Effect results drained
    /// during its dispatch write directly to the stream; `commitEvent`
    /// then appends the event record after them.
    ///
    /// Accessibility actions journal OUTER-WINS: a dispatched
    /// `widget_accessibility_action` synthesizes real platform events
    /// (a press dispatches its Enter key, set_text a select-all plus a
    /// text input, composition its ime inputs) through the same choke
    /// point, so recording both the action and its children would make
    /// replay dispatch the children twice — once from their own records,
    /// then again when replaying the action re-runs the verb. The outer
    /// record wins because the children are deterministic derivations of
    /// the action against runtime state replay has already rebuilt, and
    /// because it keeps the ASSISTIVE semantics visible in the journal
    /// ("press on widget 12", not an anonymous key event). While the
    /// action sits on the staging stack, nested stage/commit pairs are
    /// therefore suppressed — staged as placeholders so commit pairing
    /// stays balanced, never written, never counted (`event_count` must
    /// keep matching the records a replay reader will actually see;
    /// checkpoints fire only at depth 0, so no ordinal can land inside
    /// the suppressed window). Effect results are NOT suppressed: they
    /// write directly to the stream and still precede the action record,
    /// exactly the feed-then-dispatch order replay depends on. BOTH
    /// entry surfaces stage the action record: the platform AX event
    /// path stages it at the dispatch choke point, and the direct verb
    /// surfaces (an embed host's `widgetAction`, automation
    /// `widget_action` commands) stage a synthetic one inside
    /// `dispatchCanvasWidgetAccessibilityAction` — without it, their
    /// journaled children were untargeted inputs routed by focus while
    /// the verb's focus write stayed unjournaled, so a fresh replay
    /// delivered them against the wrong editor. A second accessibility
    /// action staged while one is already on the stack (the direct
    /// dispatch reached through a staged platform AX event) is just a
    /// suppressed placeholder: the outermost action owns the window and
    /// the journal keeps exactly one record.
    pub fn stageEvent(self: *SessionRecorder, event: platform.Event) void {
        if (!self.began or self.failed or self.finished) return;
        if (self.depth >= journal.max_session_event_depth) {
            return self.fail("dispatch nesting exceeded max_session_event_depth - this is a runtime bug, not a session shape");
        }
        if (self.suppress_owner_depth != null) {
            self.staged_suppressed[self.depth] = true;
            self.staged_lens[self.depth] = 0;
            self.depth += 1;
            return;
        }
        const encoded = journal.encodeEvent(event, &self.staged[self.depth]) catch {
            return self.fail("a platform event exceeded max_session_event_bytes");
        };
        self.staged_lens[self.depth] = encoded.len;
        self.staged_suppressed[self.depth] = false;
        if (event == .widget_accessibility_action) self.suppress_owner_depth = self.depth;
        self.depth += 1;
    }

    /// Append the innermost staged event record. Call exactly once per
    /// successful `stageEvent`, on dispatch exit.
    pub fn commitEvent(self: *SessionRecorder) void {
        if (!self.began or self.failed or self.finished) return;
        if (self.depth == 0) return;
        self.depth -= 1;
        if (self.staged_suppressed[self.depth]) return;
        if (self.suppress_owner_depth) |owner_depth| {
            if (owner_depth == self.depth) self.suppress_owner_depth = null;
        }
        self.writeRecord(.event, self.staged[self.depth][0..self.staged_lens[self.depth]]);
        if (!self.failed) self.event_count += 1;
    }

    /// True when dispatch just returned to the top level and the frame
    /// index moved — the once-per-published-frame checkpoint gate.
    pub fn wantsCheckpoint(self: *const SessionRecorder, frame_index: u64) bool {
        return self.began and !self.failed and !self.finished and
            self.depth == 0 and frame_index != self.last_checkpoint_frame;
    }

    pub fn recordCheckpoint(self: *SessionRecorder, frame_index: u64, fingerprint: u64) void {
        if (!self.began or self.failed or self.finished) return;
        self.last_checkpoint_frame = frame_index;
        const payload = journal.encodeCheckpoint(.{
            .event_ordinal = self.event_count,
            .frame_index = frame_index,
            .fingerprint = fingerprint,
        }, &self.small_buffer) catch return self.fail("checkpoint record over budget");
        self.writeRecord(.checkpoint, payload);
        if (!self.failed) self.checkpoint_count += 1;
    }

    /// Mark the session with a pixel checkpoint (an automation
    /// `screenshot` during recording): replay re-renders the same view
    /// at the same scale through the deterministic reference renderer
    /// and compares hashes.
    pub fn recordScreenshot(self: *SessionRecorder, view_label: []const u8, scale: f32, png_hash: u64, png_len: u64) void {
        if (!self.began or self.failed or self.finished) return;
        const payload = journal.encodeScreenshot(.{
            .event_ordinal = self.event_count,
            .view_label = view_label,
            .scale = scale,
            .png_hash = png_hash,
            .png_len = png_len,
        }, &self.small_buffer) catch return self.fail("screenshot record over budget");
        self.writeRecord(.screenshot, payload);
        if (!self.failed) self.screenshot_count += 1;
    }

    /// Record one drained effect result (the `Effects.bindJournal`
    /// callback target).
    pub fn recordEffect(self: *SessionRecorder, record: runtime_effects.EffectResultRecord) void {
        if (!self.began or self.failed or self.finished) return;
        const payload = journal.encodeEffect(record, &self.effect_buffer) catch {
            return self.fail("an effect result exceeded max_session_record_bytes");
        };
        self.writeRecord(.effect, payload);
        if (!self.failed) self.effect_count += 1;
    }

    /// The type-erased binding `Effects.bindJournal` takes.
    pub fn effectJournal(self: *SessionRecorder) runtime_effects.EffectJournal {
        return .{ .context = self, .record_fn = recordEffectErased };
    }

    fn recordEffectErased(context: *anyopaque, record: runtime_effects.EffectResultRecord) void {
        const self: *SessionRecorder = @ptrCast(@alignCast(context));
        self.recordEffect(record);
    }

    /// Write the end record, sealing the journal. A failed recording
    /// seals nothing: without the end record, replay refuses the file
    /// as truncated rather than silently replaying a prefix.
    pub fn finish(self: *SessionRecorder) void {
        if (!self.began or self.failed or self.finished) return;
        self.finished = true;
        const payload = journal.encodeEnd(.{
            .event_count = self.event_count,
            .effect_count = self.effect_count,
            .checkpoint_count = self.checkpoint_count,
            .screenshot_count = self.screenshot_count,
        }, &self.small_buffer) catch return self.fail("end record over budget");
        self.writeRecord(.end, payload);
    }

    fn writeRecord(self: *SessionRecorder, kind: journal.RecordKind, payload: []const u8) void {
        if (self.failed) return;
        if (payload.len > journal.max_session_record_bytes) {
            return self.fail("a record exceeded max_session_record_bytes");
        }
        const total = self.bytes_written + 5 + payload.len;
        if (total > journal.max_session_journal_bytes) {
            return self.fail("the journal exceeded max_session_journal_bytes - recording stopped");
        }
        var record_header: [5]u8 = undefined;
        record_header[0] = @intFromEnum(kind);
        std.mem.writeInt(u32, record_header[1..5], @intCast(payload.len), .little);
        self.write(&record_header);
        self.write(payload);
        if (!self.failed) self.bytes_written = total;
    }

    fn write(self: *SessionRecorder, bytes: []const u8) void {
        if (self.failed) return;
        self.sink.write_fn(self.sink.context, bytes) catch |err| {
            self.fail(@errorName(err));
        };
    }

    /// Flip into the failed state, loudly, once. Recording failures
    /// degrade — the app keeps running; only the journal dies.
    fn fail(self: *SessionRecorder, reason: []const u8) void {
        if (self.failed) return;
        self.failed = true;
        // No stderr on freestanding targets (the docs' wasm preview
        // host): analyzing the print would drag `std.Io.Threaded` in.
        if (comptime @import("builtin").os.tag != .freestanding) {
            std.debug.print("session recording failed and stopped: {s} (the partial journal has no end record; replay will refuse it)\n", .{reason});
        }
    }
};

/// A convenience header for the app runner: identity plus the recording
/// wall-clock stamp.
pub fn headerNow(platform_name: []const u8, app_name: []const u8, window_width: f32, window_height: f32) Header {
    return .{
        .platform_name = platform_name,
        .app_name = app_name,
        .recorded_at_wall_ms = runtime_clock.nowMs(),
        .window_width = window_width,
        .window_height = window_height,
    };
}

// -------------------------------------------------------------- tests

const testing = std.testing;

const BufferSink = struct {
    buffer: [1 << 16]u8 = undefined,
    len: usize = 0,
    fail_after: ?usize = null,

    fn sink(self: *BufferSink) RecorderSink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: *anyopaque, chunk: []const u8) anyerror!void {
        const self: *BufferSink = @ptrCast(@alignCast(context));
        if (self.fail_after) |limit| {
            if (self.len + chunk.len > limit) return error.NoSpaceLeft;
        }
        @memcpy(self.buffer[self.len .. self.len + chunk.len], chunk);
        self.len += chunk.len;
    }

    fn bytes(self: *const BufferSink) []const u8 {
        return self.buffer[0..self.len];
    }
};

test "recorder orders effect results before their consuming event" {
    var buffer_sink = BufferSink{};
    const recorder = try testing.allocator.create(SessionRecorder);
    defer testing.allocator.destroy(recorder);
    recorder.* = SessionRecorder.init(buffer_sink.sink());

    recorder.begin(.{ .platform_name = "test", .app_name = "demo" });
    recorder.stageEvent(.app_start);
    recorder.commitEvent();
    recorder.stageEvent(.wake);
    // Drained during the wake dispatch:
    recorder.recordEffect(.{ .kind = .line, .key = 1, .payload = "hello" });
    recorder.commitEvent();
    recorder.recordCheckpoint(1, 0xabc);
    recorder.finish();
    try testing.expect(!recorder.failed);

    var reader = try journal.Reader.init(buffer_sink.bytes());
    _ = (try reader.next()).?; // header
    try testing.expect((try reader.next()).?.event == .app_start);
    const effect = (try reader.next()).?;
    try testing.expectEqualStrings("hello", effect.effect.payload);
    const event = (try reader.next()).?;
    try testing.expect(event.event == .wake);
    const checkpoint = (try reader.next()).?;
    try testing.expectEqual(@as(u64, 0xabc), checkpoint.checkpoint.fingerprint);
    try testing.expectEqual(@as(u64, 2), checkpoint.checkpoint.event_ordinal);
    const end = (try reader.next()).?;
    try testing.expectEqual(@as(u64, 2), end.end.event_count);
    try testing.expectEqual(@as(u64, 1), end.end.effect_count);
}

test "recorder commits nested events innermost-first" {
    var buffer_sink = BufferSink{};
    const recorder = try testing.allocator.create(SessionRecorder);
    defer testing.allocator.destroy(recorder);
    recorder.* = SessionRecorder.init(buffer_sink.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "demo" });
    recorder.stageEvent(.frame_requested);
    recorder.stageEvent(.{ .menu_command = .{ .name = "app.about", .window_id = 1 } });
    recorder.commitEvent();
    recorder.commitEvent();
    recorder.finish();

    var reader = try journal.Reader.init(buffer_sink.bytes());
    _ = (try reader.next()).?;
    const inner = (try reader.next()).?;
    try testing.expectEqualStrings("app.about", inner.event.menu_command.name);
    const outer = (try reader.next()).?;
    try testing.expect(outer.event == .frame_requested);
}

test "accessibility actions suppress their synthesized children in the journal" {
    var buffer_sink = BufferSink{};
    const recorder = try testing.allocator.create(SessionRecorder);
    defer testing.allocator.destroy(recorder);
    recorder.* = SessionRecorder.init(buffer_sink.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "demo" });

    // An AX press dispatches its synthesized Enter key through the same
    // choke point: the nested event must not land — replaying the action
    // re-derives it — but an effect result drained during the dispatch
    // still writes through, ahead of the action record.
    recorder.stageEvent(.{ .widget_accessibility_action = .{
        .window_id = 1,
        .label = "canvas",
        .id = 7,
        .action = .press,
    } });
    recorder.stageEvent(.{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "enter",
    } });
    recorder.recordEffect(.{ .kind = .line, .key = 3, .payload = "drained" });
    recorder.commitEvent();
    recorder.commitEvent();
    // Suppression ends with the action: a later top-level input records.
    recorder.stageEvent(.{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "tab",
    } });
    recorder.commitEvent();
    recorder.recordCheckpoint(1, 0xbeef);
    recorder.finish();
    try testing.expect(!recorder.failed);

    var reader = try journal.Reader.init(buffer_sink.bytes());
    _ = (try reader.next()).?; // header
    const effect = (try reader.next()).?;
    try testing.expectEqualStrings("drained", effect.effect.payload);
    const action = (try reader.next()).?;
    try testing.expectEqual(platform.WidgetAccessibilityActionKind.press, action.event.widget_accessibility_action.action);
    const key = (try reader.next()).?;
    try testing.expectEqualStrings("tab", key.event.gpu_surface_input.key);
    // The checkpoint ordinal and end counts see only the two surviving
    // events — coherent with what a replay reader will process.
    const checkpoint = (try reader.next()).?;
    try testing.expectEqual(@as(u64, 2), checkpoint.checkpoint.event_ordinal);
    const end = (try reader.next()).?;
    try testing.expectEqual(@as(u64, 2), end.end.event_count);
    try testing.expectEqual(@as(u64, 1), end.end.effect_count);
}

test "a nested accessibility action stays a suppressed placeholder" {
    var buffer_sink = BufferSink{};
    const recorder = try testing.allocator.create(SessionRecorder);
    defer testing.allocator.destroy(recorder);
    recorder.* = SessionRecorder.init(buffer_sink.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "demo" });

    // The platform AX event path stages tag 23 at the dispatch choke
    // point, then `dispatchCanvasWidgetAccessibilityAction` stages its
    // synthetic copy of the same action: the inner stage must ride the
    // suppression window as a placeholder (one journal record, the
    // outer one), and suppression must survive the inner commit so the
    // verb's children staged AFTER it stay suppressed too.
    recorder.stageEvent(.{ .widget_accessibility_action = .{
        .window_id = 1,
        .label = "canvas",
        .id = 7,
        .action = .set_text,
        .text = "outer",
    } });
    recorder.stageEvent(.{ .widget_accessibility_action = .{
        .window_id = 1,
        .label = "canvas",
        .id = 7,
        .action = .set_text,
        .text = "synthetic",
    } });
    recorder.stageEvent(.{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .text_input,
        .text = "outer",
    } });
    recorder.commitEvent();
    recorder.commitEvent();
    recorder.commitEvent();
    // The window closed with the outer action: a later input records.
    recorder.stageEvent(.{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = "tab",
    } });
    recorder.commitEvent();
    recorder.finish();
    try testing.expect(!recorder.failed);

    var reader = try journal.Reader.init(buffer_sink.bytes());
    _ = (try reader.next()).?; // header
    const action = (try reader.next()).?;
    try testing.expectEqualStrings("outer", action.event.widget_accessibility_action.text);
    const key = (try reader.next()).?;
    try testing.expectEqualStrings("tab", key.event.gpu_surface_input.key);
    const end = (try reader.next()).?;
    try testing.expectEqual(@as(u64, 2), end.end.event_count);
}

test "recorder fails loudly once and seals nothing after a sink error" {
    var buffer_sink = BufferSink{ .fail_after = 32 };
    const recorder = try testing.allocator.create(SessionRecorder);
    defer testing.allocator.destroy(recorder);
    recorder.* = SessionRecorder.init(buffer_sink.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "demo" });
    var index: usize = 0;
    while (index < 8) : (index += 1) {
        recorder.stageEvent(.frame_requested);
        recorder.commitEvent();
    }
    try testing.expect(recorder.failed);
    recorder.finish();
    // Whatever landed before the failure has no end record: replay
    // refuses the file as truncated.
    if (journal.Reader.init(buffer_sink.bytes())) |reader_value| {
        var reader = reader_value;
        const failed = while (true) {
            const record = reader.next() catch break true;
            if (record == null) break false;
        };
        try testing.expect(failed);
    } else |_| {}
}

test "checkpoint gate fires once per frame index" {
    var buffer_sink = BufferSink{};
    const recorder = try testing.allocator.create(SessionRecorder);
    defer testing.allocator.destroy(recorder);
    recorder.* = SessionRecorder.init(buffer_sink.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "demo" });
    try testing.expect(recorder.wantsCheckpoint(1));
    recorder.recordCheckpoint(1, 5);
    try testing.expect(!recorder.wantsCheckpoint(1));
    try testing.expect(recorder.wantsCheckpoint(2));
}
