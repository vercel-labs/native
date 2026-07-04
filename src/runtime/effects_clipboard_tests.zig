//! Clipboard-effect coverage: `fx.writeClipboard`/`fx.readClipboard`
//! through the fake executor (deterministic request/feed round trips,
//! failure passthrough, cancel, rejection) and the real executor
//! against the null platform's clipboard store — the same
//! `PlatformServices` seam the runtime's cmd+C copy uses. Bounded,
//! key-based, one terminal Msg per effect with explicit outcomes,
//! exactly like spawn, fetch, and file effects.

const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_model = @import("ui_app.zig");
const effects_mod = @import("effects.zig");

const canvas_label = "clipboard-canvas";

const clipboard_views = [_]app_manifest.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const clipboard_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Clipboard",
    .width = 400,
    .height = 300,
    .views = &clipboard_views,
}};
const clipboard_scene: app_manifest.ShellConfig = .{ .windows = &clipboard_windows };

const max_recorded_bytes = 96;

const ClipboardModel = struct {
    result_count: usize = 0,
    last_op: ?effects_mod.EffectClipboardOp = null,
    last_outcome: ?effects_mod.EffectClipboardOutcome = null,
    dropped_before_total: u32 = 0,
    // Payload proof: length + hash for big reads, a bounded prefix for
    // exact-content assertions on small ones (the slice is drain
    // scratch, so the model copies what it keeps).
    text_len: usize = 0,
    text_hash: u64 = 0,
    text_prefix: [max_recorded_bytes]u8 = undefined,
    text_prefix_len: usize = 0,

    fn record(model: *ClipboardModel, result: effects_mod.EffectClipboardResult) void {
        model.result_count += 1;
        model.last_op = result.op;
        model.last_outcome = result.outcome;
        model.dropped_before_total += result.dropped_before;
        model.text_len = result.text.len;
        model.text_hash = std.hash.Wyhash.hash(0, result.text);
        model.text_prefix_len = @min(result.text.len, max_recorded_bytes);
        @memcpy(model.text_prefix[0..model.text_prefix_len], result.text[0..model.text_prefix_len]);
    }

    fn textPrefix(model: *const ClipboardModel) []const u8 {
        return model.text_prefix[0..model.text_prefix_len];
    }
};

const ClipboardMsg = union(enum) {
    copy,
    paste,
    stop,
    clipboard_result: effects_mod.EffectClipboardResult,
};

const ClipboardApp = ui_app_model.UiApp(ClipboardModel, ClipboardMsg);
const ClipboardEffects = ClipboardApp.Effects;

const clipboard_key: u64 = 88;

// Set by each test before dispatching `.copy`.
var test_text: []const u8 = "";

fn clipboardUpdate(model: *ClipboardModel, msg: ClipboardMsg, fx: *ClipboardEffects) void {
    switch (msg) {
        .copy => fx.writeClipboard(.{
            .key = clipboard_key,
            .text = test_text,
            .on_result = ClipboardEffects.clipboardMsg(.clipboard_result),
        }),
        .paste => fx.readClipboard(.{
            .key = clipboard_key,
            .on_result = ClipboardEffects.clipboardMsg(.clipboard_result),
        }),
        .stop => fx.cancel(clipboard_key),
        .clipboard_result => |result| model.record(result),
    }
}

fn clipboardView(ui: *ClipboardApp.Ui, model: *const ClipboardModel) ClipboardApp.Ui.Node {
    return ui.column(.{ .gap = 4, .padding = 8 }, .{
        ui.text(.{}, ui.fmt("{d} results", .{model.result_count})),
        ui.button(.{ .on_press = .copy }, "Copy"),
        ui.button(.{ .on_press = .paste }, "Paste"),
        ui.button(.{ .on_press = .stop }, "Stop"),
    });
}

const Harness = struct {
    harness: *core.TestHarness(),
    app_state: *ClipboardApp,
    app: core.App,

    fn create() !Harness {
        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(400, 300) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        const app_state = try std.testing.allocator.create(ClipboardApp);
        errdefer std.testing.allocator.destroy(app_state);
        app_state.* = ClipboardApp.init(std.heap.page_allocator, .{}, .{
            .name = "effects-clipboard",
            .scene = clipboard_scene,
            .canvas_label = canvas_label,
            .update_fx = clipboardUpdate,
            .view = clipboardView,
        });
        const app = app_state.app();
        try harness.start(app);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(400, 300),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        try std.testing.expect(app_state.installed);
        return .{ .harness = harness, .app_state = app_state, .app = app };
    }

    fn destroy(self: *Harness) void {
        self.app_state.deinit();
        std.testing.allocator.destroy(self.app_state);
        self.harness.destroy(std.testing.allocator);
    }

    fn drainWakes(self: *Harness) !void {
        var nudged = false;
        while (self.harness.null_platform.takeWake()) |_| nudged = true;
        if (nudged) try self.harness.runtime.dispatchPlatformEvent(self.app, .wake);
    }
};

// ------------------------------------------------------------ fake executor

test "fake executor records clipboard requests and feeds results back as msgs" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    // Write: the request is recorded whole, not executed — nothing
    // touches the platform clipboard.
    test_text = "vercel/ai#7417 — packet rasterizer wraps host-side";
    try h.app_state.dispatch(&h.harness.runtime, 1, .copy);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingClipboardCount());
    const write_request = fx.pendingClipboardAt(0).?;
    try std.testing.expectEqual(clipboard_key, write_request.key);
    try std.testing.expectEqual(effects_mod.EffectClipboardOp.write, write_request.op);
    try std.testing.expectEqualStrings("vercel/ai#7417 — packet rasterizer wraps host-side", write_request.text);
    try std.testing.expectEqual(@as(usize, 0), h.harness.null_platform.clipboardWriteCount());

    try fx.feedClipboardResult(clipboard_key, .ok, "");
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.EffectClipboardOp.write, h.app_state.model.last_op.?);
    try std.testing.expectEqual(effects_mod.EffectClipboardOutcome.ok, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.text_len);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingClipboardCount());

    // Read: the fed content arrives as the terminal Msg's text.
    try h.app_state.dispatch(&h.harness.runtime, 1, .paste);
    const read_request = fx.pendingClipboardAt(0).?;
    try std.testing.expectEqual(effects_mod.EffectClipboardOp.read, read_request.op);
    try std.testing.expectEqualStrings("", read_request.text);
    try fx.feedClipboardResult(clipboard_key, .ok, "pasted text");
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(@as(usize, 2), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.EffectClipboardOp.read, h.app_state.model.last_op.?);
    try std.testing.expectEqual(effects_mod.EffectClipboardOutcome.ok, h.app_state.model.last_outcome.?);
    try std.testing.expectEqualStrings("pasted text", h.app_state.model.textPrefix());

    // Failure outcomes pass through as fed.
    try h.app_state.dispatch(&h.harness.runtime, 1, .paste);
    try fx.feedClipboardResult(clipboard_key, .failed, "");
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);
    try std.testing.expectEqual(effects_mod.EffectClipboardOutcome.failed, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.text_len);
}

test "fake reads over the clipboard bound fail whole, never cut" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    const oversized = try std.testing.allocator.alloc(u8, effects_mod.max_effect_clipboard_bytes + 3);
    defer std.testing.allocator.free(oversized);
    for (oversized, 0..) |*byte, index| byte.* = @truncate(index);

    try h.app_state.dispatch(&h.harness.runtime, 1, .paste);
    try fx.feedClipboardResult(clipboard_key, .ok, oversized);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .wake);

    // The real reader fails whole on over-bound clipboard content (a
    // cut clipboard string must never pass for the clipboard); the
    // fake mirrors it.
    try std.testing.expectEqual(effects_mod.EffectClipboardOutcome.failed, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.text_len);
}

test "cancelling a fake clipboard effect delivers one cancelled terminal" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    test_text = "pending copy";
    try h.app_state.dispatch(&h.harness.runtime, 1, .copy);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingClipboardCount());

    try h.app_state.dispatch(&h.harness.runtime, 1, .stop);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.EffectClipboardOutcome.cancelled, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(effects_mod.EffectClipboardOp.write, h.app_state.model.last_op.?);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingClipboardCount());

    // The key is terminal: feeding it now reports EffectNotFound.
    try std.testing.expectError(error.EffectNotFound, fx.feedClipboardResult(clipboard_key, .ok, ""));
}

test "clipboard requests that cannot run are rejected loudly, never silently" {
    var h = try Harness.create();
    defer h.destroy();
    const fx = &h.app_state.effects;
    fx.executor = .fake;

    // Over-bound write text: rejected outright, never cut on the
    // clipboard.
    const oversized = try std.testing.allocator.alloc(u8, effects_mod.max_effect_clipboard_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'c');
    test_text = oversized;
    try h.app_state.dispatch(&h.harness.runtime, 1, .copy);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.EffectClipboardOutcome.rejected, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(effects_mod.EffectClipboardOp.write, h.app_state.model.last_op.?);
    try std.testing.expectEqual(@as(usize, 0), fx.pendingClipboardCount());

    // Duplicate active key.
    test_text = "small";
    try h.app_state.dispatch(&h.harness.runtime, 1, .copy);
    try std.testing.expectEqual(@as(usize, 1), fx.pendingClipboardCount());
    try h.app_state.dispatch(&h.harness.runtime, 1, .paste);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 2), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.EffectClipboardOutcome.rejected, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(effects_mod.EffectClipboardOp.read, h.app_state.model.last_op.?);
    // The original write is still pending, untouched by the rejection.
    try std.testing.expectEqual(@as(usize, 1), fx.pendingClipboardCount());
}

// ------------------------------------------------------------ real executor

test "real executor writes the platform clipboard and reads it back" {
    var h = try Harness.create();
    defer h.destroy();

    // Write: the text lands on the platform clipboard through the same
    // PlatformServices seam the runtime's cmd+C copy uses, and one
    // terminal ok Msg drains back into update.
    test_text = "shared from the soundboard";
    try h.app_state.dispatch(&h.harness.runtime, 1, .copy);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.EffectClipboardOp.write, h.app_state.model.last_op.?);
    try std.testing.expectEqual(effects_mod.EffectClipboardOutcome.ok, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.text_len);
    try std.testing.expectEqual(@as(usize, 1), h.harness.null_platform.clipboardWriteCount());
    try std.testing.expectEqualStrings("text/plain", h.harness.null_platform.lastClipboardMimeType());
    try std.testing.expectEqualStrings("shared from the soundboard", h.harness.null_platform.lastClipboardData());

    // And the read effect round-trips it.
    try h.app_state.dispatch(&h.harness.runtime, 1, .paste);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 2), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.EffectClipboardOp.read, h.app_state.model.last_op.?);
    try std.testing.expectEqual(effects_mod.EffectClipboardOutcome.ok, h.app_state.model.last_outcome.?);
    try std.testing.expectEqualStrings("shared from the soundboard", h.app_state.model.textPrefix());

    // A rewrite replaces the clipboard whole.
    test_text = "second copy";
    try h.app_state.dispatch(&h.harness.runtime, 1, .copy);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 2), h.harness.null_platform.clipboardWriteCount());
    try std.testing.expectEqualStrings("second copy", h.harness.null_platform.lastClipboardData());
}

test "real executor reports a refused platform clipboard as failed" {
    var h = try Harness.create();
    defer h.destroy();

    // The null platform rejects reads whose stored mime type does not
    // match — an empty clipboard reads as a refusal, and the effect
    // reports it as one explicit failed Msg, never a silent empty ok.
    try h.app_state.dispatch(&h.harness.runtime, 1, .paste);
    try h.drainWakes();
    try std.testing.expectEqual(@as(usize, 1), h.app_state.model.result_count);
    try std.testing.expectEqual(effects_mod.EffectClipboardOp.read, h.app_state.model.last_op.?);
    try std.testing.expectEqual(effects_mod.EffectClipboardOutcome.failed, h.app_state.model.last_outcome.?);
    try std.testing.expectEqual(@as(usize, 0), h.app_state.model.text_len);
}
