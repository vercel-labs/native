const std = @import("std");
const native_sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const canvas = native_sdk.canvas;
const platform = native_sdk.platform;
const policy = native_sdk.runtime.testing.accessibility_policy;
const reference = @import("accessibility_reference.zig");
const complete = @import("surface_layout_e2e_tests.zig").expectComplete;

fn compare(nodes: []const canvas.WidgetSemanticsNode, view: reference.View, capacity: usize) !void {
    var actual: [64]platform.WidgetAccessibilityNode = undefined;
    const projected = try policy.project(std.testing.allocator, core.nativeWindowPolicy, nodes, view.keyboard_active, view.focused, view.canvas_widget_focused_id, view.canvas_widget_hovered_id, view.canvas_widget_pressed_id, actual[0..capacity]);
    try std.testing.expectEqual(@min(capacity, nodes.len), projected.len);
    for (projected, 0..) |value, i| {
        try complete(reference.project(nodes, i, view, .{}), value);
        try std.testing.expectEqual(nodes[i].label.ptr, value.label.ptr);
        try std.testing.expectEqual(nodes[i].text_value.ptr, value.text_value.ptr);
        try std.testing.expectEqual(nodes[i].placeholder.ptr, value.placeholder.ptr);
    }
    core.rt.frameReset();
}

test "compiled accessibility projection preserves complete native roles states and borrowed bytes" {
    @setEvalBranchQuota(100000);
    _ = core.initialModel();
    defer core.rt.frameReset();
    const flags = [_]u8{ 0, 1, 2, 4, 8, 16, 32, 64, 128, 255 };
    inline for (@typeInfo(canvas.WidgetRole).@"enum".fields) |role| {
        for ([_]?f32{ null, -std.math.inf(f32), -0.0, 0, 0.49999997, 0.5, 1, std.math.inf(f32), std.math.nan(f32) }) |value| {
            for (flags) |bits| for ([_]?bool{ null, false, true }) |expanded| {
                var node = canvas.WidgetSemanticsNode{ .id = 9007199254740993, .role = @enumFromInt(role.value), .label = "label\x00\xff", .text_value = "\xc3\xa9 text", .placeholder = "hint", .value = value, .focusable = true, .bounds = .init(-0.0, -17, 180, 23), .text_selection = .{ .start = 7, .end = 2 }, .text_composition = .{ .start = 0, .end = 9 }, .grid_row_index = std.math.maxInt(usize), .grid_column_index = 0, .grid_row_count = 9007199254740993, .grid_column_count = 0, .list = .{ .present = bits & 1 != 0, .item_index = std.math.maxInt(u32), .item_count = 0 }, .scroll = .{ .present = bits & 2 != 0, .offset = -0.0, .viewport_extent = 17, .content_extent = 999 }, .state = .{ .expanded = expanded } };
                inline for (.{ "hovered", "pressed", "focused", "disabled", "selected", "required", "read_only", "invalid" }, 0..) |field, bit| @field(node.state, field) = bits & (@as(u8, 1) << @intCast(bit)) != 0;
                inline for (@typeInfo(canvas.WidgetActions).@"struct".fields) |field| @field(node.actions, field.name) = true;
                try compare(&.{node}, .{}, 64);
            };
        }
    }
}

test "compiled accessibility projection preserves exact identities parent reach and capacity" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var nodes: [65]canvas.WidgetSemanticsNode = undefined;
    for (&nodes, 0..) |*node, i| node.* = .{ .id = if (i == 0) 0 else if (i == 64) std.math.maxInt(u64) else 9007199254740993 + @as(u64, @intCast(i)), .role = .checkbox, .label = "", .state = .{}, .parent_index = 64, .bounds = .init(0, 0, 10, 10) };
    for ([_]usize{ 0, 1, 16, 64 }) |capacity| for ([_]u8{ 0, 1, 2, 3 }) |bits| {
        try compare(&nodes, .{ .keyboard_active = bits & 1 != 0, .focused = bits & 2 != 0, .canvas_widget_focused_id = 0, .canvas_widget_hovered_id = nodes[1].id, .canvas_widget_pressed_id = nodes[2].id }, capacity);
    };
    nodes[0].parent_index = std.math.maxInt(usize);
    nodes[1].parent_index = 0;
    try compare(&nodes, .{}, 64);
    try compare(&.{}, .{}, 64);
}

test "compiled accessibility publication preserves exact hash comparisons retry and frame settlement" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]u64{ 0, 1, 9007199254740993, std.math.maxInt(u64) }) |previous| for ([_]u64{ 0, 1, 9007199254740993, std.math.maxInt(u64) }) |next| {
        for ([_]bool{ false, true }) |published| for ([_]bool{ false, true }) |allow| for ([_]bool{ false, true }) |live| {
            const expected: policy.Publication = if (published and previous == next) .unchanged else if (allow and live) .deferred else .publish;
            try std.testing.expectEqual(expected, policy.publication(core.nativeWindowPolicy, published, previous, next, allow, live));
            core.rt.frameReset();
        };
    };
    for ([_]bool{ false, true }) |pending| for ([_]bool{ false, true }) |frame| for ([_]bool{ false, true }) |force| {
        try std.testing.expectEqual(pending and (force or !frame), policy.flush(core.nativeWindowPolicy, pending, frame, force));
        core.rt.frameReset();
    };
}

const publication = native_sdk.runtime.testing.accessibility_publication;
const Capture = struct {
    context: ?*anyopaque = null,
    attempts: usize = 0,
    fail: bool = false,
    count: usize = 0,
    nodes: [64]platform.WidgetAccessibilityNode = undefined,
    labels: [64][128]u8 = undefined,
    texts: [64][128]u8 = undefined,
    placeholders: [64][128]u8 = undefined,

    fn publish(context: ?*anyopaque, snapshot: platform.WidgetAccessibilitySnapshot) anyerror!void {
        const self = if (context == captures[0].?.context) captures[0].? else captures[1].?;
        self.attempts += 1;
        if (self.fail) return error.AccessibilityUnavailable;
        try std.testing.expectEqual(@as(u64, 1), snapshot.window_id);
        try std.testing.expectEqualStrings("canvas", snapshot.view_label);
        self.count = snapshot.nodes.len;
        for (snapshot.nodes, 0..) |node, i| {
            self.nodes[i] = node;
            @memcpy(self.labels[i][0..node.label.len], node.label);
            @memcpy(self.texts[i][0..node.text_value.len], node.text_value);
            @memcpy(self.placeholders[i][0..node.placeholder.len], node.placeholder);
            self.nodes[i].label = self.labels[i][0..node.label.len];
            self.nodes[i].text_value = self.texts[i][0..node.text_value.len];
            self.nodes[i].placeholder = self.placeholders[i][0..node.placeholder.len];
        }
    }
};
var captures: [2]?*Capture = @splat(null);

fn runtimeParity(left: *native_sdk.Runtime, right: *native_sdk.Runtime) !void {
    try complete(captures[0].?.attempts, captures[1].?.attempts);
    try complete(captures[0].?.nodes[0..captures[0].?.count], captures[1].?.nodes[0..captures[1].?.count]);
    try complete(left.automationSnapshot("accessibility"), right.automationSnapshot("accessibility"));
    try complete(left.views[0].widget_accessibility_published, right.views[0].widget_accessibility_published);
    try complete(left.views[0].widget_accessibility_published_hash, right.views[0].widget_accessibility_published_hash);
    try complete(left.views[0].widget_accessibility_publish_deferred, right.views[0].widget_accessibility_publish_deferred);
    core.rt.frameReset();
}

test "compiled accessibility runtime preserves complete snapshots focused history deferral and failed publication retry" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const gpa = std.testing.allocator;
    const left = try native_sdk.TestHarness().create(gpa, .{ .size = .init(320, 200) });
    defer left.destroy(gpa);
    left.null_platform.gpu_surfaces = true;
    const right = try native_sdk.TestHarness().create(gpa, .{ .size = .init(320, 200) });
    defer right.destroy(gpa);
    right.null_platform.gpu_surfaces = true;
    for (&captures, 0..) |*slot, i| {
        slot.* = try gpa.create(Capture);
        slot.*.?.* = .{ .context = if (i == 0) &left.null_platform else &right.null_platform };
    }
    defer for (&captures) |*slot| {
        gpa.destroy(slot.*.?);
        slot.* = null;
    };
    var context: u8 = 0;
    const app = native_sdk.App{ .context = &context, .name = "accessibility", .source = platform.WebViewSource.html("") };
    const runtimes = [_]*native_sdk.Runtime{ &left.runtime, &right.runtime };
    const children = [_]canvas.Widget{
        .{ .id = 9007199254740993, .kind = .input, .text = "Draft", .placeholder = "Search", .frame = .init(10, 10, 150, 30) },
        .{ .id = 7, .kind = .button, .text = "Play", .frame = .init(10, 50, 100, 30) },
    };
    const root = canvas.Widget{ .id = std.math.maxInt(u64), .kind = .stack, .frame = .init(0, 0, 320, 200), .children = &children };
    var layout_nodes: [8]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(root, .init(0, 0, 320, 200), &layout_nodes);
    for (runtimes, 0..) |runtime, i| {
        runtime.options.platform.services.update_widget_accessibility_fn = Capture.publish;
        try runtime.dispatchPlatformEvent(app, .app_start);
        // This publication-only fixture has no elapsed wall-clock stage.
        // Disable its uptime origin before comparing full unmodified snapshots.
        runtime.started_timestamp_ns = 0;
        _ = try runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(0, 0, 320, 200) });
        if (i == 1) runtime.views[0].widget_tokens.accessibility_policy = core.nativeWindowPolicy;
        _ = try runtime.setCanvasWidgetLayout(1, "canvas", layout);
    }
    try runtimeParity(runtimes[0], runtimes[1]);
    const initial_attempts = captures[0].?.attempts;
    for (runtimes) |runtime| try publication.publishCanvasWidgetAccessibility(runtime, 0);
    try std.testing.expectEqual(initial_attempts, captures[0].?.attempts);
    try runtimeParity(runtimes[0], runtimes[1]);
    for (runtimes) |runtime| {
        runtime.views[0].focused = true;
        runtime.views[0].keyboard_active = true;
        runtime.views[0].canvas_widget_focused_id = children[0].id;
        _ = try runtime.views[0].applyCanvasWidgetTextEdit(children[0].id, .{ .insert_text = "!" });
        _ = try runtime.refreshCanvasWidgetDisplayListIfOwned(0);
    }
    try std.testing.expect(captures[0].?.nodes[1].can_undo);
    try std.testing.expect(!captures[0].?.nodes[1].can_redo);
    try runtimeParity(runtimes[0], runtimes[1]);
    for (runtimes) |runtime| {
        const target = runtime.views[0].widgetLayoutTree().focusTargetById(children[0].id).?;
        const undo = runtime.views[0].canvasWidgetTextHistoryShortcut(target, .{ .phase = .key_down, .key = "z", .modifiers = .{ .super = true } }).?;
        _ = try runtime.views[0].applyCanvasWidgetTextEditWithoutHistory(children[0].id, undo.edit);
        runtime.views[0].commitCanvasWidgetTextHistoryReplayIfComplete(target, undo.serial, undo.redo);
        _ = try runtime.refreshCanvasWidgetDisplayListIfOwned(0);
    }
    try std.testing.expect(!captures[0].?.nodes[1].can_undo);
    try std.testing.expect(captures[0].?.nodes[1].can_redo);
    try runtimeParity(runtimes[0], runtimes[1]);
    for (runtimes) |runtime| {
        runtime.views[0].canvas_widget_focused_id = 7;
        try publication.publishCanvasWidgetAccessibility(runtime, 0);
    }
    try std.testing.expect(!captures[0].?.nodes[1].can_undo and !captures[0].?.nodes[1].can_redo);
    try runtimeParity(runtimes[0], runtimes[1]);
    for (runtimes) |runtime| {
        runtime.views[0].canvas_widget_focused_id = children[0].id;
        try publication.publishCanvasWidgetAccessibility(runtime, 0);
    }
    try std.testing.expect(captures[0].?.nodes[1].can_redo);
    try runtimeParity(runtimes[0], runtimes[1]);
    const before_defer = captures[0].?.attempts;
    for (runtimes) |runtime| {
        runtime.canvas_widget_accessibility_defer_depth = 1;
        runtime.views[0].canvas_widget_hovered_id = 7;
        try publication.publishCanvasWidgetAccessibility(runtime, 0);
        runtime.canvas_widget_accessibility_defer_depth = 0;
        runtime.views[0].gpu_canvas_frame_requested = true;
        try publication.settleDeferredCanvasWidgetAccessibility(runtime);
        try std.testing.expect(runtime.views[0].widget_accessibility_publish_deferred);
    }
    try std.testing.expectEqual(before_defer, captures[0].?.attempts);
    try runtimeParity(runtimes[0], runtimes[1]);
    for (runtimes) |runtime| try publication.flushDeferredCanvasWidgetAccessibility(runtime);
    try std.testing.expectEqual(before_defer + 1, captures[0].?.attempts);
    try runtimeParity(runtimes[0], runtimes[1]);
    for (runtimes) |runtime| {
        runtime.canvas_widget_accessibility_defer_depth = 1;
        runtime.views[0].canvas_widget_hovered_id = 0;
        try publication.publishCanvasWidgetAccessibility(runtime, 0);
        runtime.canvas_widget_accessibility_defer_depth = 0;
        runtime.views[0].gpu_canvas_frame_requested = false;
        try publication.settleDeferredCanvasWidgetAccessibility(runtime);
    }
    try std.testing.expectEqual(before_defer + 2, captures[0].?.attempts);
    try runtimeParity(runtimes[0], runtimes[1]);
    const last_hash = runtimes[0].views[0].widget_accessibility_published_hash;
    for (runtimes, 0..) |runtime, i| {
        captures[i].?.fail = true;
        runtime.views[0].canvas_widget_pressed_id = 7;
        try std.testing.expectError(error.AccessibilityUnavailable, publication.publishCanvasWidgetAccessibility(runtime, 0));
        try std.testing.expectError(error.AccessibilityUnavailable, publication.publishCanvasWidgetAccessibility(runtime, 0));
        try std.testing.expectEqual(last_hash, runtime.views[0].widget_accessibility_published_hash);
    }
    try runtimeParity(runtimes[0], runtimes[1]);
    for (runtimes, 0..) |runtime, i| {
        captures[i].?.fail = false;
        try publication.publishCanvasWidgetAccessibility(runtime, 0);
        try std.testing.expect(runtime.views[0].widget_accessibility_published_hash != last_hash);
    }
    try runtimeParity(runtimes[0], runtimes[1]);
    // Reverting to the last published tree cancels a pending changed tree.
    for (runtimes) |runtime| {
        runtime.canvas_widget_accessibility_defer_depth = 1;
        runtime.views[0].canvas_widget_pressed_id = 0;
        try publication.publishCanvasWidgetAccessibility(runtime, 0);
        runtime.views[0].canvas_widget_pressed_id = 7;
        try publication.publishCanvasWidgetAccessibility(runtime, 0);
        try std.testing.expect(!runtime.views[0].widget_accessibility_publish_deferred);
        runtime.canvas_widget_accessibility_defer_depth = 0;
        try publication.flushDeferredCanvasWidgetAccessibility(runtime);
    }
    try runtimeParity(runtimes[0], runtimes[1]);
}
