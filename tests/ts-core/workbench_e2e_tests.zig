const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("workbench_core");
const decoder = @import("workbench_decoder");
const reference = @import("workbench_reference.zig");
const parity = @import("effects_media_parity.zig");
const Host = sdk.TsCoreHost(core);
const canvas = sdk.canvas;
const testing = std.testing;
const View = canvas.CompiledMarkupView(core.Model, core.Msg, @embedFile("app.native"));

fn bufferEqual(expected: anytype, actual: anytype) !void {
    try testing.expectEqualStrings(expected.text(), actual.text);
    try testing.expectEqual(@as(i64, @intCast(expected.selection.anchor)), actual.selection.anchor);
    try testing.expectEqual(@as(i64, @intCast(expected.selection.focus)), actual.selection.focus);
    try testing.expectEqual(expected.composition != null, actual.composition != null);
    if (expected.composition) |range| {
        try testing.expectEqual(@as(i64, @intCast(range.start)), actual.composition.?.start);
        try testing.expectEqual(@as(i64, @intCast(range.end)), actual.composition.?.end);
    }
    try testing.expectEqual(expected.truncated, actual.truncated);
}
fn counter(value: anytype) u64 {
    return (@as(u64, @intCast(value.upper_word)) << 32) | @as(u64, @intCast(value.lower_word));
}
fn compare(native: *const reference.Model, model: *const core.Model) !void {
    inline for (.{ "split_fraction", "chrome_top" }) |name| try testing.expectEqual(@as(f64, @field(native, name)), @field(model, name));
    try testing.expectEqual(@as(f64, @floatFromInt(native.term_scrollback)), parity.number(model.term_scrollback));
    try testing.expectEqual(@as(i64, @intCast(native.history_count)), model.history_count);
    try testing.expectEqual(@as(i64, @intCast(native.history_index)), model.history_index);
    try testing.expectEqual(native.reload_token, counter(model.reload_token));
    try testing.expectEqual(native.output_batches, counter(model.output_batches));
    try testing.expectEqual(native.shell_live, model.shell_live);
    try testing.expectEqual(native.shell_exited, model.shell_exited);
    try bufferEqual(native.address_field, model.address_field);
    try testing.expectEqual(native.history.len, model.history.len);
    for (native.history, model.history) |a, b| try bufferEqual(a, b);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    inline for (.{ "address", "currentUrl" }) |name| try testing.expectEqualStrings(@field(reference.Model, name)(native), @field(core.Model, name)(model, arena.allocator()));
    inline for (.{ "back_disabled", "forward_disabled" }) |name| try testing.expectEqual(@field(reference.Model, name)(native), @field(core.Model, name)(model));
    try testing.expectEqual(@as(f64, native.titlebar_band()), model.titlebar_band());
    var panes: [1]sdk.UiApp(reference.Model, reference.Msg).WebViewPane = undefined;
    _ = reference.webPanes(native, &panes);
    const port = model.webPanes(arena.allocator())[0];
    try testing.expectEqualStrings(panes[0].label, port.label);
    try testing.expectEqualStrings(panes[0].anchor.?, port.anchor.?);
    try testing.expectEqualStrings(panes[0].url, port.url);
    try testing.expectEqual(native.reload_token, try std.fmt.parseInt(u64, port.reloadToken, 10));
    try testing.expectEqualDeep(sdk.geometry.RectF.init(0, 0, 0, 0), panes[0].frame);
    core.rt.frameReset();
}
fn referenceKey(_: []const u8) u64 {
    return reference.shell_effect_key;
}
fn viewParity(native: *const reference.Model, model: *const core.Model) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var a = canvas.Ui(reference.Msg).init(arena.allocator());
    const expected = try a.finalize(reference.CompiledWorkbenchView.build(&a, native));
    for (0..2) |backend| {
        var b = canvas.Ui(core.Msg).init(arena.allocator());
        b.pty_key_resolver = referenceKey;
        const actual = try b.finalize(if (backend == 0) View.build(&b, model) else decoder.build(&b, model));
        core.rt.frameReset();
        try parity.equal(expected.root, actual.root);
        try testing.expectEqual(expected.handlers.len, actual.handlers.len);
        for (expected.handlers, actual.handlers) |before, after| {
            try testing.expectEqual(before.id, after.id);
            try testing.expectEqualStrings(@tagName(before.event), @tagName(after.event));
        }
        const terminal = parity.find(&actual.root, "Shell").?;
        const state = canvas.TerminalState{ .scrollback = 4294967295, .history = 400, .cols = 320, .rows = 240 };
        const echo = actual.msgForTerminal(terminal.id, state).?.term_state;
        try testing.expectEqual(@as(f64, @floatFromInt(state.scrollback)), parity.number(echo.scrollback));
        try testing.expectEqual(@as(f64, @floatFromInt(state.history)), parity.number(echo.history));
        try testing.expectEqual(@as(f64, @floatFromInt(state.cols)), parity.number(echo.cols));
        try testing.expectEqual(@as(f64, @floatFromInt(state.rows)), parity.number(echo.rows));
        var left: [128]canvas.WidgetLayoutNode = undefined;
        var right: [128]canvas.WidgetLayoutNode = undefined;
        for ([_]sdk.geometry.RectF{ .init(0, 0, 1280, 800), .init(0, 0, 900, 560), .init(0, 0, 1600, 960) }) |frame|
            try parity.equal(try canvas.layoutWidgetTree(expected.root, frame, &left), try canvas.layoutWidgetTree(actual.root, frame, &right));
    }
}
const Pair = struct {
    model: reference.Model = .{},
    fx: Host.Fx,
    native_fx: reference.Effects,
    fn create() !*Pair {
        const self = try testing.allocator.create(Pair);
        self.* = .{ .fx = .init(testing.allocator), .native_fx = .init(testing.allocator) };
        self.fx.executor = .fake;
        self.native_fx.executor = .fake;
        reference.boot(&self.model, &self.native_fx);
        Host.init(&self.fx);
        Host.dispatch(&self.fx, .{ .target_os = @tagName(@import("builtin").os.tag) });
        try self.check();
        return self;
    }
    fn destroy(self: *Pair) void {
        self.fx.deinit();
        self.native_fx.deinit();
        testing.allocator.destroy(self);
    }
    fn check(self: *Pair) !void {
        try compare(&self.model, Host.model());
        try viewParity(&self.model, Host.model());
        try testing.expectEqual(self.native_fx.pendingPtyCount(), self.fx.pendingPtyCount());
        for (0..self.fx.pendingPtyCount()) |i| {
            const a = self.native_fx.pendingPtyAt(i).?;
            const b = self.fx.pendingPtyAt(i).?;
            try testing.expectEqual(reference.shell_effect_key, a.key);
            try testing.expectEqual(Host.resolvePtyKey("shell"), b.key);
            inline for (.{ "cols", "rows", "term" }) |field| try parity.equal(@field(a, field), @field(b, field));
            try parity.equal(a.argv, b.argv);
            try testing.expectEqualStrings(self.native_fx.ptyWrittenBytes(a.key), self.fx.ptyWrittenBytes(b.key));
        }
    }
    fn step(self: *Pair, native: reference.Msg, msg: core.Msg) !void {
        reference.update(&self.model, native, &self.native_fx);
        Host.dispatch(&self.fx, msg);
        try self.check();
    }
    fn edit(self: *Pair, native: canvas.TextInputEvent, msg: core.TextInputEvent) !void {
        try self.step(.{ .address_edit = native }, .{ .address_edit = msg });
    }
    fn navigate(self: *Pair, text: []const u8) !void {
        try self.edit(.{ .set_selection = .{ .anchor = 0, .focus = self.model.address_field.len } }, .{ .set_selection = .{ .anchor = 0, .focus = @intCast(self.model.address_field.len) } });
        try self.edit(.{ .insert_text = text }, .{ .insert_text = text });
        try self.step(.navigate, .navigate);
    }
};

test "Workbench full model effects both widget trees and layout retain history editing and shell parity" {
    const pair = try Pair.create();
    defer pair.destroy();
    try pair.step(.{ .split_resized = 0.62 }, .{ .split_resized = 0.62 });
    try pair.step(.{ .term_state = .{ .scrollback = 12, .history = 400, .cols = 80, .rows = 24 } }, .{ .term_state = .{ .scrollback = 12, .history = 400, .cols = 80, .rows = 24 } });
    try pair.step(.{ .chrome_changed = .{ .insets = .{ .top = 52 } } }, .{ .chrome_changed = .{ .insets = .{ .top = 52, .left = 0, .right = 0, .bottom = 0 }, .buttons = .{ .x = 0, .y = 0, .width = 0, .height = 0 }, .tabsProjected = false } });
    try pair.navigate("  example.com  ");
    try pair.navigate("http://example.org/page");
    try pair.step(.go_back, .go_back);
    try pair.step(.go_forward, .go_forward);
    try pair.step(.go_back, .go_back);
    try pair.navigate("\tbare\t");
    try pair.navigate("   ");
    try pair.step(.reload, .reload);
    var text: [1100]u8 = @splat('a');
    try pair.navigate(&text);
    text[1019] = 0xc3;
    text[1020] = 0xa9;
    try pair.navigate(text[0..1020]);
    try pair.edit(.{ .set_selection = .{ .anchor = 7, .focus = 2 } }, .{ .set_selection = .{ .anchor = 7, .focus = 2 } });
    try pair.edit(.delete_backward, .delete_backward);
    try pair.edit(.{ .set_composition = .{ .text = "\xc3\xa9", .cursor = 1 } }, .{ .set_composition = .{ .text = "\xc3\xa9", .cursor = 1 } });
    try pair.edit(.commit_composition, .commit_composition);
    for (0..35) |i| {
        var bytes: [50]u8 = undefined;
        try pair.navigate(try std.fmt.bufPrint(&bytes, "https://page-{d}.example", .{i}));
    }
    try pair.step(.go_back, .go_back);
    try pair.step(.go_back, .go_back);
    try pair.navigate("\xff\x00://raw");
    const key = Host.resolvePtyKey("shell");
    try pair.native_fx.feedPtyOutput(reference.shell_effect_key, "demo$ hi\r\n");
    try pair.fx.feedPtyOutput(key, "demo$ hi\r\n");
    while (pair.native_fx.takeMsg()) |msg| reference.update(&pair.model, msg, &pair.native_fx);
    Host.drain(&pair.fx);
    try pair.check();
    try pair.native_fx.feedPtyExit(reference.shell_effect_key, 7, 0, .exited, 2);
    try pair.fx.feedPtyExit(key, 7, 0, .exited, 2);
    while (pair.native_fx.takeMsg()) |msg| reference.update(&pair.model, msg, &pair.native_fx);
    Host.drain(&pair.fx);
    try pair.check();
    try testing.expectEqual(key, Host.resolvePtyKey("shell"));
    try testing.expectEqual(@as(u64, 0), Host.resolvePtyKey("unknown"));
    // A second named child must never borrow the ended terminal's identity.
    Host.dispatch(&pair.fx, .{ .target_os = "linux" });
    try testing.expectEqual(key, pair.fx.pendingPtyAt(0).?.key);
    try testing.expectEqual(key, Host.resolvePtyKey("shell"));
}

fn replay(comptime compiled: bool) !void {
    const Adapter = sdk.TsUiApp(core);
    const env = [_]Adapter.EnvValue{.{ .msg = "target_os", .value = "linux" }};
    var journal = parity.JournalBuffer.init();
    defer journal.deinit();
    const recorder = try testing.allocator.create(sdk.runtime.SessionRecorder);
    defer testing.allocator.destroy(recorder);
    var blobs = sdk.runtime.session_blobs.MemoryBlobStore.init(testing.allocator);
    defer blobs.deinit();
    recorder.* = .init(.{ .context = &journal, .write_fn = parity.JournalBuffer.write });
    recorder.blob_sink = blobs.sink();
    recorder.begin(sdk.runtime.sessionHeaderNow(sdk.runtime.sessionPlatformName(), "workbench", 1280, 800));
    var full: ?[]u8 = null;
    defer if (full) |bytes| testing.allocator.free(bytes);
    var fingerprint: u64 = 0;
    {
        const app = try Adapter.create(testing.allocator, .{ .env_values = &env }, .{ .name = "workbench", .scene = reference.shell_scene, .canvas_label = reference.canvas_label, .view = if (compiled) decoder.build else View.build });
        defer app.destroy();
        const harness = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(1280, 800) });
        defer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        harness.runtime.options.security.navigation.allowed_origins = &.{"*"};
        harness.runtime.options.session_recorder = recorder;
        try harness.start(app.app());
        app.effects.executor = .fake;
        try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_frame = .{ .label = reference.canvas_label, .size = .init(1280, 800), .scale_factor = 1, .frame_index = 1, .timestamp_ns = 1_000_000 } });
        const key = Host.resolvePtyKey("shell");
        try testing.expect(key != 0);
        try app.effects.feedPtyOutput(key, "demo$ echo hi\r\nhi\r\ndemo$ ");
        try harness.runtime.dispatchPlatformEvent(app.app(), .wake);
        try parity.action(&harness.runtime, app.app(), &app.tree.?.root, reference.canvas_label, "Reload", "press");
        try app.effects.feedPtyExit(key, 0, 0, .exited, 0);
        try harness.runtime.dispatchPlatformEvent(app.app(), .wake);
        try testing.expect(app.model.shell_exited);
        try testing.expectEqual(key, parity.find(&app.tree.?.root, "Shell").?.terminal.pty);
        try harness.runtime.dispatchPlatformEvent(app.app(), .frame_requested);
        full = try std.json.Stringify.valueAlloc(testing.allocator, app.model, .{});
        fingerprint = harness.runtime.sessionStateFingerprint();
        recorder.finish();
        try testing.expect(!recorder.failed);
    }
    const app = try Adapter.create(testing.allocator, .{ .env_values = &env }, .{ .name = "workbench", .scene = reference.shell_scene, .canvas_label = reference.canvas_label, .view = if (compiled) decoder.build else View.build });
    defer app.destroy();
    const harness = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(1280, 800) });
    defer harness.destroy(testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.runtime.options.security.navigation.allowed_origins = &.{"*"};
    const report = try sdk.runtime.replaySession(&harness.runtime, app.app(), journal.bytes.written(), .{ .require_same_platform = false, .blobs = blobs.source() });
    try testing.expect(report.ok());
    try testing.expectEqual(recorder.event_count, report.events_replayed);
    try testing.expectEqual(recorder.effect_count, report.effects_fed);
    try testing.expectEqual(recorder.checkpoint_count, report.checkpoints_verified);
    try testing.expectEqual(fingerprint, harness.runtime.sessionStateFingerprint());
    const actual = try std.json.Stringify.valueAlloc(testing.allocator, app.model, .{});
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(full.?, actual);
}
test "Workbench full committed snapshots PTY effects and every checkpoint replay on both views" {
    try replay(false);
    try replay(true);
}

test "Workbench u64 counters preserve exact word carries full decimal pane tokens and reload wrap" {
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    var native_fx = reference.Effects.init(testing.allocator);
    defer native_fx.deinit();
    native_fx.executor = .fake;
    for ([_]u64{ 0xFFFFFFFF, 9007199254740991, 9007199254740992, 0x8000000000000000, std.math.maxInt(u64) - 1, std.math.maxInt(u64) }) |count| {
        Host.init(&fx);
        var native: reference.Model = .{};
        reference.boot(&native, &native_fx);
        native.reload_token = count;
        native.output_batches = if (count == std.math.maxInt(u64)) count - 1 else count;
        const snapshot = try testing.allocator.dupe(u8, core.persistenceSnapshot());
        defer testing.allocator.free(snapshot);
        var at: usize = 4;
        for (0..std.mem.readInt(u32, snapshot[0..4], .little)) |_| {
            const tag = std.mem.readInt(u32, snapshot[at..][0..4], .little);
            const len = std.mem.readInt(u32, snapshot[at + 4 ..][0..4], .little);
            at += 8;
            if (tag == 7 or tag == 10) {
                try testing.expectEqual(@as(u32, 16), len);
                const value = if (tag == 7) native.reload_token else native.output_batches;
                std.mem.writeInt(i64, snapshot[at..][0..8], @intCast(value >> 32), .little);
                std.mem.writeInt(i64, snapshot[at + 8 ..][0..8], @intCast(value & 0xFFFFFFFF), .little);
            }
            at += len;
        }
        const model = core.restoreModel(snapshot);
        try compare(&native, model);
        reference.update(&native, .reload, &native_fx);
        const reloaded = core.update(model, .reload).model;
        try compare(&native, reloaded);
        reference.update(&native, .{ .shell = .{ .key = 1, .kind = .output, .bytes = "carry" } }, &native_fx);
        const next = core.update(reloaded, .{ .shell = .{ .key = "shell", .state = .output, .bytes = "carry", .code = 0, .reason = .exited, .signal = 0, .droppedWrites = 0 } }).model;
        try compare(&native, next);
        core.rt.frameReset();
    }
}

test "Workbench compiled decoder guards terminal resource and event ownership" {
    try decoder.testTerminalRecords();
}
