const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const p = sdk.runtime.testing.input_composition_policy;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
var calls: [14]usize = @splat(0);
fn observed(request: []const u8, output: []u8) usize {
    if (request[0] == 78) calls[request[2]] += 1;
    return core.nativeSurfaceScopePolicy(request, output);
}
test "compiled input composition preserves complete native input normalization and borrowed bytes" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const ids = [_]u64{ 0, 1, 9007199254740993, std.math.maxInt(u64) };
    const raw = "\x00\xff\xc3\xa9text";
    for (std.enums.values(sdk.platform.GpuSurfaceInputKind)) |kind| for (0..32) |bits| for (ids) |id| {
        const input = sdk.platform.GpuSurfaceInputEvent{ .window_id = id, .label = "canvas", .kind = kind, .pointer_id = id, .button = -17, .x = -0.0, .y = std.math.nan(f32), .delta_x = std.math.inf(f32), .delta_y = -0.125, .scroll_is_detented = true, .key = "EsCaPe", .text = raw, .composition_cursor = std.math.maxInt(usize), .modifiers = .{ .shift = bits & 1 != 0, .control = bits & 2 != 0, .option = bits & 4 != 0, .command = bits & 8 != 0, .primary = bits & 16 != 0 } };
        const result = p.plan(observed, .normalize, input, .{}).?;
        try exact(sdk.runtime.testing.referenceInputPointer(input), p.pointerEvent(result, input));
        try exact(sdk.runtime.testing.referenceInputKeyboard(input, id), p.keyboardEvent(result, input, id, false));
        try exact(sdk.runtime.testing.referenceInputText(input, id), p.keyboardEvent(result, input, id, true));
        try exact(sdk.runtime.testing.referenceInputCommandModifier(input), result.has(1));
        try exact(sdk.runtime.testing.referenceInputEscape(input.key), result.has(2));
        if (p.keyboardEvent(result, input, id, true)) |event| {
            try std.testing.expectEqual(input.text.ptr, event.text.ptr);
        }
        const borrowed = core.rt.frameAlloc(u8, 13);
        @memset(borrowed, 0x5a);
        _ = p.plan(observed, .target, input, .{ .owner = id, .owner_present = true, .owner_kind = .text_field });
        try std.testing.expect(std.mem.allEqual(u8, borrowed, 0x5a));
        core.rt.frameReset();
        try exact(sdk.runtime.testing.referenceInputPointer(input), p.pointerEvent(result, input));
    };
}

const Capture = struct {
    arena: std.heap.ArenaAllocator,
    events: std.ArrayList(sdk.runtime.CanvasWidgetKeyboardEvent) = .empty,
    remove_button: bool = false,
    recorded: bool = false,
    compiled: bool = false,
    fn app(self: *@This()) sdk.App {
        return .{ .context = self, .name = "input-composition", .source = sdk.platform.WebViewSource.html(""), .start_fn = start, .event_fn = event };
    }
    fn start(context: *anyopaque, runtime: *sdk.Runtime) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.recorded) try Pair.createView(runtime, self.compiled);
    }
    fn event(context: *anyopaque, runtime: *sdk.Runtime, event_value: sdk.Event) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (event_value == .command and self.recorded) {
            const name = event_value.command.name;
            if (std.mem.eql(u8, name, "alpha")) runtime.views[0].canvas_widget_focused_id = 9007199254740993;
            if (std.mem.eql(u8, name, "beta")) runtime.views[0].canvas_widget_focused_id = std.math.maxInt(u64);
            if (std.mem.eql(u8, name, "targetless")) runtime.views[0].canvas_widget_focused_id = 0;
            if (std.mem.eql(u8, name, "remove")) try Pair.layout(runtime, true);
            return;
        }
        if (event_value != .canvas_widget_keyboard) return;
        const a = self.arena.allocator();
        var value = event_value.canvas_widget_keyboard;
        value.view_label = try a.dupe(u8, value.view_label);
        value.route = try a.dupe(sdk.canvas.WidgetEventRouteEntry, value.route);
        value.keyboard.key = try a.dupe(u8, value.keyboard.key);
        value.keyboard.text = try a.dupe(u8, value.keyboard.text);
        if (value.keyboard.edit) |edit| value.keyboard.edit = switch (edit) {
            .insert_text => |text| .{ .insert_text = try a.dupe(u8, text) },
            .set_composition => |composition| .{ .set_composition = .{ .text = try a.dupe(u8, composition.text), .cursor = composition.cursor } },
            else => edit,
        };
        try self.events.append(a, value);
        if (self.remove_button and value.target != null and value.target.?.id == 7 and value.keyboard.phase == .key_down) {
            const children = [_]sdk.canvas.Widget{.{ .id = 9007199254740993, .kind = .text_field, .frame = .init(10, 10, 140, 32), .text = "alpha" }};
            var nodes: [8]sdk.canvas.WidgetLayoutNode = undefined;
            const tree = try sdk.canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, .init(0, 0, 320, 200), &nodes);
            _ = try runtime.setCanvasWidgetLayout(1, "canvas", tree);
        }
    }
};
const Harness = sdk.TestHarness();
const Pair = struct {
    left: *Harness,
    right: *Harness,
    captures: [2]Capture,
    fn create() !Pair {
        const a = std.testing.allocator;
        return .{ .left = try Harness.create(a, .{}), .right = try Harness.create(a, .{}), .captures = .{ .{ .arena = .init(a) }, .{ .arena = .init(a) } } };
    }
    fn destroy(self: *Pair) void {
        self.left.destroy(std.testing.allocator);
        self.right.destroy(std.testing.allocator);
        for (&self.captures) |*capture| capture.arena.deinit();
    }
    fn setup(self: *Pair) !void {
        for ([_]*Harness{ self.left, self.right }, 0..) |h, i| {
            h.null_platform.gpu_surfaces = true;
            try h.start(self.captures[i].app());
            h.runtime.started_timestamp_ns = 0;
            try createView(&h.runtime, i == 1);
        }
        try self.same();
    }
    fn createView(runtime: *sdk.Runtime, compiled: bool) !void {
        _ = try runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(0, 0, 320, 200) });
        if (compiled) runtime.views[0].canvas_widget_surface_scope_policy = observed;
        runtime.views[0].focused = true;
        try layout(runtime, false);
    }
    fn layout(runtime: *sdk.Runtime, remove: bool) !void {
        const children = [_]sdk.canvas.Widget{
            .{ .id = 9007199254740993, .kind = .text_field, .frame = .init(10, 10, 140, 32), .text = "alpha" },
            .{ .id = std.math.maxInt(u64), .kind = .text_field, .frame = .init(10, 50, 140, 32), .text = "beta" },
            .{ .id = 7, .kind = .button, .frame = .init(10, 90, 140, 32), .text = "Action" },
        };
        var nodes: [8]sdk.canvas.WidgetLayoutNode = undefined;
        const tree = try sdk.canvas.layoutWidgetTree(.{ .kind = .stack, .children = if (remove) children[1..] else &children }, .init(0, 0, 320, 200), &nodes);
        _ = try runtime.setCanvasWidgetLayout(1, "canvas", tree);
    }
    fn focus(self: *Pair, id: u64) void {
        self.left.runtime.views[0].canvas_widget_focused_id = id;
        self.right.runtime.views[0].canvas_widget_focused_id = id;
    }
    fn input(self: *Pair, kind: sdk.platform.GpuSurfaceInputKind, key: []const u8, text: []const u8) !void {
        try self.inputAt("canvas", kind, key, text);
    }
    fn inputAt(self: *Pair, label: []const u8, kind: sdk.platform.GpuSurfaceInputKind, key: []const u8, text: []const u8) !void {
        const event = sdk.platform.Event{ .gpu_surface_input = .{ .window_id = 1, .label = label, .kind = kind, .key = key, .text = text } };
        try self.left.runtime.dispatchPlatformEvent(self.captures[0].app(), event);
        try self.right.runtime.dispatchPlatformEvent(self.captures[1].app(), event);
        try self.same();
    }
    fn same(self: *Pair) !void {
        const left = &self.left.runtime;
        const right = &self.right.runtime;
        try exact(left.automationSnapshot("input-composition"), right.automationSnapshot("input-composition"));
        try exact(self.captures[0].events.items, self.captures[1].events.items);
        try exact(left.targetless_ime_preedit[0..left.targetless_ime_preedit_len], right.targetless_ime_preedit[0..right.targetless_ime_preedit_len]);
        try exact(left.targetless_ime_preedit_window, right.targetless_ime_preedit_window);
        try exact(left.targetless_ime_preedit_label[0..left.targetless_ime_preedit_label_len], right.targetless_ime_preedit_label[0..right.targetless_ime_preedit_label_len]);
        try exact(left.targetless_ime_commit_grace, right.targetless_ime_commit_grace);
        try exact(left.view_count, right.view_count);
        for (left.views[0..left.view_count], right.views[0..right.view_count]) |*a, *b| {
            inline for (.{ "canvas_widget_ime_owner_id", "canvas_widget_ime_commit_grace", "canvas_widget_claimed_key_grace", "canvas_widget_tab_input_focus_entry_held", "canvas_widget_terminal_paste_v_held", "widget_text_len", "canvas_widget_text_history_entry_count", "canvas_widget_text_history_byte_count" }) |name| try exact(@field(a, name), @field(b, name));
            try exact(a.widgetLayoutTree().nodes, b.widgetLayoutTree().nodes);
            try exact(a.widget_text_bytes[0..a.widget_text_len], b.widget_text_bytes[0..b.widget_text_len]);
        }
        core.rt.frameReset();
    }
};
test "compiled input composition preserves full runtime state through owner focus changes cancel grace and orphan resolution" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    try pair.setup();
    pair.focus(9007199254740993);
    try pair.input(.ime_set_composition, "", "é");
    pair.focus(std.math.maxInt(u64));
    try pair.input(.ime_cancel_composition, "", "");
    try pair.input(.text_input, "", "converted");
    pair.focus(9007199254740993);
    try pair.input(.ime_set_composition, "", "draft");
    try Pair.layout(&pair.left.runtime, true);
    try Pair.layout(&pair.right.runtime, true);
    pair.focus(std.math.maxInt(u64));
    try pair.input(.ime_set_composition, "", "orphan");
    try pair.input(.ime_cancel_composition, "", "");
    try pair.input(.text_input, "", "swallowed");
    try pair.input(.text_input, "", "ordinary");
}
test "compiled input composition preserves target-less resolution key claims blur and recreated-surface ownership" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    try pair.setup();
    pair.focus(0);
    try pair.input(.ime_set_composition, "", "語");
    pair.focus(7);
    try pair.input(.key_down, "enter", "");
    try pair.input(.ime_commit_composition, "", "");
    try pair.input(.key_down, "space", "");
    try pair.input(.text_input, "", " ");
    try pair.input(.key_up, "space", "");
    pair.focus(0);
    try pair.input(.ime_set_composition, "", "stale");
    try pair.input(.ime_cancel_composition, "", "");
    try pair.left.runtime.closeView(1, "canvas");
    try pair.right.runtime.closeView(1, "canvas");
    try Pair.createView(&pair.left.runtime, false);
    try Pair.createView(&pair.right.runtime, true);
    pair.focus(9007199254740993);
    try pair.input(.text_input, "", "new");
    try pair.input(.ime_set_composition, "", "active");
    sdk.runtime.testing.clearInputCompositionOnBlur(&pair.left.runtime, &pair.left.runtime.views[0]);
    sdk.runtime.testing.clearInputCompositionOnBlur(&pair.right.runtime, &pair.right.runtime.views[0]);
    try pair.same();
    for ([_]usize{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 11, 12, 13 }) |mode| try std.testing.expect(calls[mode] > 0);
}

test "compiled input composition preserves full replacement failure and never commits superseded preedit" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    try pair.setup();
    pair.focus(0);
    try pair.input(.ime_set_composition, "", "prior");
    var failure = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failure.allocator();
    pair.left.runtime.owned_allocator = allocator;
    pair.right.runtime.owned_allocator = allocator;
    const replacement: [16384]u8 = @splat('r');
    try pair.input(.ime_set_composition, "", &replacement);
    pair.left.runtime.owned_allocator = std.testing.allocator;
    pair.right.runtime.owned_allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 0), pair.right.runtime.targetless_ime_preedit_len);
    try pair.input(.ime_commit_composition, "", "");
    try std.testing.expectEqual(@as(usize, 0), pair.captures[1].events.items.len);
}

test "compiled input composition keeps a split activation claimed across a reentrant tree replacement" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    try pair.setup();
    pair.focus(7);
    for (&pair.captures) |*capture| capture.remove_button = true;
    try pair.input(.key_down, "space", "");
    try std.testing.expect(pair.right.runtime.views[0].widgetLayoutTree().findById(7) == null);
    try pair.input(.text_input, "", " ");
    try std.testing.expectEqual(@as(usize, 1), pair.captures[1].events.items.len);
    try pair.input(.text_input, "", "x");
    try std.testing.expectEqual(@as(usize, 2), pair.captures[1].events.items.len);
}

test "compiled input composition scopes global preedit and one shot grace across distinct surfaces" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    try pair.setup();
    for ([_]*Harness{ pair.left, pair.right }, 0..) |h, i| {
        _ = try h.runtime.createView(.{ .window_id = 1, .label = "other", .kind = .gpu_surface, .frame = .init(0, 0, 320, 200) });
        h.runtime.views[1].focused = true;
        if (i == 1) h.runtime.views[1].canvas_widget_surface_scope_policy = observed;
    }
    pair.focus(0);
    try pair.input(.ime_set_composition, "", "語");
    try pair.inputAt("other", .key_up, "enter", "");
    try std.testing.expectEqualStrings("語", pair.right.runtime.targetless_ime_preedit[0..pair.right.runtime.targetless_ime_preedit_len]);
    try pair.inputAt("other", .ime_commit_composition, "", "");
    try std.testing.expectEqualStrings("語", pair.right.runtime.targetless_ime_preedit[0..pair.right.runtime.targetless_ime_preedit_len]);
    try pair.input(.ime_cancel_composition, "", "");
    try std.testing.expect(pair.right.runtime.targetless_ime_commit_grace);
    try pair.inputAt("other", .text_input, "", "elsewhere");
    try std.testing.expect(!pair.right.runtime.targetless_ime_commit_grace);
    pair.focus(9007199254740993);
    try pair.input(.text_input, "", "fresh");
    pair.focus(0);
    try pair.input(.ime_set_composition, "", "blurred");
    try pair.inputAt("other", .key_down, "enter", "");
    try std.testing.expectEqual(@as(usize, 0), pair.right.runtime.targetless_ime_preedit_len);
}

test "compiled input composition retires Escape owner and consumes exactly one physical paste release" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    try pair.setup();
    pair.focus(9007199254740993);
    try pair.input(.ime_set_composition, "", "draft");
    try pair.input(.key_down, "escape", "");
    try std.testing.expectEqual(@as(u64, 0), pair.right.runtime.views[0].canvas_widget_ime_owner_id);
    for ([_]*Harness{ pair.left, pair.right }) |h| h.runtime.views[0].canvas_widget_terminal_paste_v_held = true;
    try pair.input(.key_up, "V", "");
    try std.testing.expect(!pair.right.runtime.views[0].canvas_widget_terminal_paste_v_held);
    try pair.input(.key_up, "V", "");
    for ([_]*Harness{ pair.left, pair.right }) |h| h.runtime.views[0].canvas_widget_terminal_paste_v_held = true;
    try pair.input(.key_down, "v", "");
    try std.testing.expect(!pair.right.runtime.views[0].canvas_widget_terminal_paste_v_held);
    try std.testing.expect(calls[9] > 0 and calls[10] > 0);
}

const Journal = struct {
    bytes: std.ArrayList(u8) = .empty,
    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.bytes.appendSlice(std.testing.allocator, bytes);
    }
    fn sink(self: *@This()) sdk.runtime.SessionRecorderSink {
        return .{ .context = self, .write_fn = write };
    }
};
test "compiled input composition sealed journals replay complete keyboard payloads and final runtime state" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var journals: [2]Journal = .{ .{}, .{} };
    defer for (&journals) |*journal| journal.bytes.deinit(std.testing.allocator);
    var pair = try Pair.create();
    defer pair.destroy();
    for ([_]*Harness{ pair.left, pair.right }, 0..) |h, i| {
        h.null_platform.gpu_surfaces = true;
        pair.captures[i].recorded = true;
        pair.captures[i].compiled = i == 1;
    }
    // Recorder is heap-owned because its bounded encoder scratch is large.
    const recorders = try std.testing.allocator.alloc(sdk.runtime.SessionRecorder, 2);
    defer std.testing.allocator.free(recorders);
    for (recorders, 0..) |*recorder, i| {
        recorder.* = sdk.runtime.SessionRecorder.init(journals[i].sink());
        if (i == 1) recorder.recording_policy = @import("session_recording_e2e_tests.zig").observed;
        recorder.begin(.{ .platform_name = "null", .app_name = "input-composition" });
        const h = if (i == 0) pair.left else pair.right;
        h.runtime.options.session_recorder = recorder;
        try h.start(pair.captures[i].app());
        h.runtime.started_timestamp_ns = 0;
    }
    const session = [_]sdk.platform.Event{
        .{ .menu_command = .{ .name = "alpha", .window_id = 1 } },
        .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .ime_set_composition, .text = "é語", .composition_cursor = 2 } },
        .{ .menu_command = .{ .name = "beta", .window_id = 1 } },
        .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .ime_cancel_composition } },
        .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .text_input, .text = "converted" } },
        .{ .menu_command = .{ .name = "targetless", .window_id = 1 } },
        .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .ime_set_composition, .text = "字" } },
        .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .key_down, .key = "enter" } },
        .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .ime_commit_composition } },
        .{ .menu_command = .{ .name = "alpha", .window_id = 1 } },
        .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .ime_set_composition, .text = "orphan" } },
        .{ .menu_command = .{ .name = "remove", .window_id = 1 } },
        .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .ime_cancel_composition } },
        .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .text_input, .text = "swallowed" } },
    };
    for (session) |event| {
        try pair.left.runtime.dispatchPlatformEvent(pair.captures[0].app(), event);
        try pair.right.runtime.dispatchPlatformEvent(pair.captures[1].app(), event);
        try pair.same();
    }
    for (recorders) |*recorder| {
        recorder.finish();
        try std.testing.expect(recorder.finished and !recorder.failed);
    }
    try std.testing.expectEqualSlices(u8, journals[0].bytes.items, journals[1].bytes.items);
    for (0..2) |i| {
        const h = try Harness.create(std.testing.allocator, .{});
        defer h.destroy(std.testing.allocator);
        h.null_platform.gpu_surfaces = true;
        var capture = Capture{ .arena = .init(std.testing.allocator), .recorded = true, .compiled = i == 1 };
        defer capture.arena.deinit();
        const report = try sdk.runtime.replaySession(&h.runtime, capture.app(), journals[i].bytes.items, .{ .verify = true, .require_same_platform = false });
        try std.testing.expect(report.ok());
        try std.testing.expectEqual(recorders[i].event_count, report.events_replayed);
        try exact(pair.captures[i].events.items, capture.events.items);
        const recorded = if (i == 0) pair.left else pair.right;
        try std.testing.expectEqual(recorded.runtime.sessionStateFingerprint(), h.runtime.sessionStateFingerprint());
        h.runtime.started_timestamp_ns = 0;
        try exact(recorded.runtime.automationSnapshot("input-composition"), h.runtime.automationSnapshot("input-composition"));
        try exact(recorded.runtime.views[0].widgetLayoutTree().nodes, h.runtime.views[0].widgetLayoutTree().nodes);
    }
}
