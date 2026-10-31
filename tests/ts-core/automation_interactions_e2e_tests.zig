const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const p = sdk.runtime.testing.automation_interaction_policy;
var modes: [13]usize = @splat(0);
fn compiled(input: []const u8, output: []u8) usize {
    if (input[0] == 91) modes[input[2]] += 1;
    return core.nativeWindowPolicy(input, output);
}

// Copy every delivered field before the next dispatch can release its storage.
// Wall-clock timestamps are the sole projected fields; zero stays zero so the
// accessibility drag's untimestamped events cannot hide behind this projection.
fn owned(comptime T: type, value: T, a: std.mem.Allocator) anyerror!T {
    if (T == sdk.runtime.DispatchError) {
        var result = value;
        result.event_storage = @splat(0);
        result.detail_storage = @splat(0);
        // Only each declared prefix is initialized or observable. Compare
        // every prefix byte and length without reading undefined spare slots.
        @memcpy(result.event_storage[0..value.event_len], value.event());
        @memcpy(result.detail_storage[0..value.detail_len], value.detail());
        result.timestamp_ns = if (value.timestamp_ns == 0) 0 else 1;
        return result;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var result = value;
            inline for (info.fields) |field| {
                if (comptime std.mem.eql(u8, field.name, "timestamp_ns") or std.mem.eql(u8, field.name, "gpu_input_timestamp_ns")) {
                    @field(result, field.name) = if (@field(value, field.name) == 0) 0 else 1;
                } else @field(result, field.name) = try owned(field.type, @field(value, field.name), a);
            }
            return result;
        },
        .pointer => |info| {
            if (info.size != .slice) return value;
            const result = try a.alloc(info.child, value.len);
            for (value, result) |v, *out| out.* = try owned(info.child, v, a);
            return result;
        },
        .optional => if (value) |v| return try owned(@TypeOf(v), v, a) else return null,
        .array => {
            var result = value;
            for (value, &result) |v, *out| out.* = try owned(@TypeOf(v), v, a);
            return result;
        },
        .@"union" => switch (value) {
            inline else => |v, tag| return @unionInit(T, @tagName(tag), try owned(@TypeOf(v), v, a)),
        },
        else => return value,
    }
}
const Capture = struct {
    arena: std.heap.ArenaAllocator,
    events: std.ArrayList(sdk.Event) = .empty,
    fail_pointer: bool = false,
    close_on_dismiss: bool = false,
    fail_dismiss: bool = false,
    fn app(self: *@This()) sdk.App {
        return .{ .context = self, .name = "automation-interactions", .source = sdk.platform.WebViewSource.html(""), .event_fn = event };
    }
    fn event(context: *anyopaque, runtime: *sdk.Runtime, value: sdk.Event) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.events.append(self.arena.allocator(), try owned(sdk.Event, value, self.arena.allocator()));
        if (value == .canvas_widget_pointer and self.fail_pointer) return error.PointerFailed;
        if (value == .canvas_widget_context_menu_dismissed) {
            if (self.close_on_dismiss) try runtime.closeView(1, "canvas");
            if (self.fail_dismiss) return error.DismissFailed;
        }
    }
};
const Harness = sdk.TestHarness();
const menu = [_]sdk.canvas.WidgetContextMenuItem{ .{ .label = "Choose" }, .{ .label = "Disabled", .enabled = false }, .{ .label = "Separator", .separator = true } };
const Pair = struct {
    lanes: [2]*Harness,
    captures: [2]Capture,
    fn create() !Pair {
        return .{ .lanes = .{ try Harness.create(std.testing.allocator, .{}), try Harness.create(std.testing.allocator, .{}) }, .captures = .{ .{ .arena = .init(std.testing.allocator) }, .{ .arena = .init(std.testing.allocator) } } };
    }
    fn destroy(self: *Pair) void {
        for (self.lanes) |h| h.destroy(std.testing.allocator);
        for (&self.captures) |*c| c.arena.deinit();
    }
    fn setup(self: *Pair) !void {
        for (self.lanes, 0..) |h, i| {
            h.null_platform.gpu_surfaces = true;
            try h.start(self.captures[i].app());
            h.runtime.started_timestamp_ns = 0;
            _ = try h.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(0, 0, 320, 240) });
            const children = [_]sdk.canvas.Widget{
                .{ .id = 1, .kind = .button, .frame = .init(10, 10, 120, 32), .text = "Action", .context_menu = &menu, .semantics = .{ .actions = .{ .drop_files = true } } },
                .{ .id = 9007199254740993, .kind = .text_field, .frame = .init(10, 52, 120, 32), .text = "alpha" },
                .{ .id = 3, .kind = .slider, .frame = .init(10, 94, 120, 32), .value = 0.5, .semantics = .{ .actions = .{ .drag = true } } },
                .{ .id = 4, .kind = .text, .frame = .init(10, 138, 120, 32), .text = "Plain" },
            };
            var nodes: [16]sdk.canvas.WidgetLayoutNode = undefined;
            const tree = try sdk.canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, .init(0, 0, 320, 240), &nodes);
            _ = try h.runtime.setCanvasWidgetLayout(1, "canvas", tree);
            if (i == 1) {
                h.runtime.automation_interaction_policy = compiled;
                h.runtime.context_menu_policy = compiled;
            }
        }
        try self.same();
    }
    fn command(self: *Pair, bytes: []const u8) !void {
        var result: [2]?anyerror = .{ null, null };
        for (self.lanes, 0..) |h, i| h.runtime.dispatchAutomationCommand(self.captures[i].app(), bytes) catch |err| {
            result[i] = err;
        };
        try exact(result[0], result[1]);
        try self.same();
    }
    fn same(self: *Pair) !void {
        const a = &self.lanes[0].runtime;
        const b = &self.lanes[1].runtime;
        const allocator = self.captures[0].arena.allocator();
        const left_snapshot = a.automationSnapshot("automation-interactions");
        const right_snapshot = b.automationSnapshot("automation-interactions");
        try exact(try owned(@TypeOf(left_snapshot), left_snapshot, allocator), try owned(@TypeOf(right_snapshot), right_snapshot, allocator));
        try exact(self.captures[0].events.items, self.captures[1].events.items);
        try exact(a.canvas_widget_context_menu_pending, b.canvas_widget_context_menu_pending);
        try exact(a.view_count, b.view_count);
        try exact(a.canvas_widget_display_list_refresh_batch_depth, b.canvas_widget_display_list_refresh_batch_depth);
        for (a.views[0..a.view_count], b.views[0..b.view_count]) |*left, *right| {
            try exact(left.widgetLayoutTree().nodes, right.widgetLayoutTree().nodes);
            try exact(left.widget_text_bytes[0..left.widget_text_len], right.widget_text_bytes[0..right.widget_text_len]);
            try exact(left.canvasWidgetRenderState(), right.canvasWidgetRenderState());
            try exact(left.canvas_widget_drag_start_point, right.canvas_widget_drag_start_point);
            try exact(left.canvas_widget_drag_pointer_id, right.canvas_widget_drag_pointer_id);
        }
        core.rt.frameReset();
    }
};
test "compiled automation interactions preserve complete event streams and retained state" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    try pair.setup();
    for ([_][]const u8{
        "widget-click canvas 1",                                    "widget-hold canvas 1",                           "widget-context-press canvas 1",    "widget-context-menu canvas 1 0",
        "widget-wheel canvas 3 -3 5",                               "widget-key canvas cmd+a",                        "widget-key canvas left",           "widget-pinch canvas 1.5",
        "widget-pinch canvas 0.5 7 9",                              "widget-drag canvas 3 0.25 0.5 0.75 0.5",
        "widget-action canvas 9007199254740993 set-text é",
        "widget-action canvas 9007199254740993 set-composition 字",
        "widget-action canvas 9007199254740993 commit-composition", "widget-action canvas 9007199254740993 set-text", "widget-action canvas 3 drag -3 4", "widget-action canvas 1 drop-files one two",
    }) |command| {
        try pair.command(command);
        try std.testing.expectEqual(@as(u64, 0), pair.lanes[1].runtime.dispatch_error_total);
    }
    for (modes, 0..) |count, mode| {
        if (count == 0) std.debug.print("interaction mode {d} was not exercised\n", .{mode});
        try std.testing.expect(count > 0);
    }
}
test "compiled automation interactions preserve full refusal precedence without partial events" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    try pair.setup();
    for ([_][]const u8{
        "widget-click canvas 999",           "widget-hold absent 1",              "widget-context-press canvas 4",
        "widget-wheel canvas 999 1",         "widget-wheel canvas 4 1",           "widget-pinch canvas 1e-20",
        "widget-pinch canvas 2.9802326e-8",  "widget-context-menu canvas 1 1",    "widget-context-menu canvas 1 2",
        "widget-context-menu canvas 1 3",    "widget-context-menu canvas 3 0",    "widget-action canvas 1 set-text ignored",
        "widget-action canvas 4 drop-files", "widget-action canvas 1 drop-files",
    }) |command| try pair.command(command);
}
test "compiled automation interactions flush failed click batches and restore drag press state" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    try pair.setup();
    for (&pair.captures) |*c| c.fail_pointer = true;
    try pair.command("widget-click canvas 1");
    try pair.command("widget-action canvas 3 drag -3 4");
}
test "compiled automation interactions preserve context-menu closure and notice-error precedence" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]bool{ false, true }) |fail| {
        var pair = try Pair.create();
        defer pair.destroy();
        try pair.setup();
        try pair.command("widget-context-press canvas 1");
        for (&pair.captures) |*c| {
            c.close_on_dismiss = true;
            c.fail_dismiss = fail;
        }
        try pair.command("widget-context-menu canvas 1 0");
        try std.testing.expect(pair.lanes[1].runtime.canvas_widget_context_menu_pending == null);
    }
}
test "compiled automation interactions preserve every token bit across superseded and closed menus" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const token = std.math.maxInt(u64);
    try std.testing.expectEqual(@as(u32, 0), p.plan(compiled, .menu_completion, .{ .facts = p.Fact.pending | p.Fact.view, .expected_token = token, .current_token = token }).status);
    for (0..64) |bit| {
        const result = p.plan(compiled, .menu_completion, .{ .facts = p.Fact.pending | p.Fact.view, .expected_token = token, .current_token = token ^ (@as(u64, 1) << @intCast(bit)) });
        try std.testing.expectError(error.ContextMenuSuperseded, result.admit());
        try std.testing.expectEqual(@as(usize, 0), result.count);
        core.rt.frameReset();
    }
    const closed = p.plan(compiled, .menu_completion, .{ .facts = p.Fact.pending, .expected_token = token, .current_token = token });
    try std.testing.expectError(error.ContextMenuViewClosed, closed.admit());
    try std.testing.expectEqual(@as(u32, 32), closed.flags);
}

test "compiled automation interactions preserve native float32 geometry and pinch wire boundaries" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const samples = [_]f32{ -std.math.inf(f32), -16777215, -80.00001, -1, -0.0, 0, 0x1p-149, 0.000001, 0.25, 80.00001, 16777215, std.math.inf(f32), std.math.nan(f32) };
    for (0..4) |axis| for (samples) |sample| {
        var coordinates = [_]f32{ 10.00001, 20.00001, 80.00001, 60.00001 };
        coordinates[axis] = sample;
        const frame = sdk.geometry.RectF.init(coordinates[0], coordinates[1], coordinates[2], coordinates[3]);
        const normalized = frame.normalized();
        const result = p.plan(compiled, .wheel, .{ .facts = p.Fact.node | p.Fact.interactive, .frame = frame, .delta = .{ .dx = -0.0, .dy = 0.125 } });
        if (normalized.isEmpty()) {
            try std.testing.expectError(error.WheelTargetHasEmptyBounds, result.admit());
            try std.testing.expectEqual(@as(usize, 0), result.count);
        } else {
            try result.admit();
            try std.testing.expectEqual(@as(usize, 1), result.count);
            try exact(normalized.center(), result.steps[0].point);
            try exact(sdk.geometry.OffsetF{ .dx = -0.0, .dy = 0.125 }, result.steps[0].delta);
            const drag = p.plan(compiled, .pointer_drag, .{ .facts = p.Fact.node | p.Fact.interactive, .frame = frame, .ratios = .{ 0.25, 0.125, 0.75, 0.875 } });
            const start = sdk.geometry.PointF.init(normalized.x + normalized.width * @as(f32, 0.25), normalized.y + normalized.height * @as(f32, 0.125));
            const end = sdk.geometry.PointF.init(normalized.x + normalized.width * @as(f32, 0.75), normalized.y + normalized.height * @as(f32, 0.875));
            try drag.admit();
            try std.testing.expectEqual(@as(usize, 3), drag.count);
            try exact(start, drag.origin);
            try exact(end, drag.end);
            try exact(start, drag.steps[0].point);
            try exact(end, drag.steps[1].point);
            try exact(end, drag.steps[2].point);
            try exact(sdk.geometry.OffsetF{ .dx = end.x - start.x, .dy = end.y - start.y }, drag.steps[1].delta);
        }
        core.rt.frameReset();
    };
    for ([_]u32{ 0, 1, 0x32ffffff, 0x33000000, 0x33000001, 0x3f800000, 0x7f800000 }) |bits| {
        const scale: f32 = @bitCast(bits);
        const delta = scale - 1;
        const result = p.plan(compiled, .pinch, .{ .delta = .{ .dx = scale, .dy = 0 } });
        if (1 + delta <= 0) {
            try std.testing.expectError(error.PinchScaleBelowWireMinimum, result.admit());
            try std.testing.expectEqual(@as(usize, 0), result.count);
        } else {
            try result.admit();
            try std.testing.expectEqual(@as(usize, 3), result.count);
            try exact(delta, result.steps[1].scale);
        }
        core.rt.frameReset();
    }
}
