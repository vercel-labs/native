const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const p = sdk.runtime.testing.view_coordination_policy;
const methods = sdk.runtime.testing.view_coordination_methods;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const Harness = sdk.TestHarness();
var calls: [11]usize = @splat(0);
fn observed(request: []const u8, output: []u8) usize {
    if (request[0] == 80) calls[request[2]] += 1;
    return core.nativeWindowPolicy(request, output);
}
const Entry = struct {
    kind: u8,
    window: u64,
    length: usize,
    label: [64]u8 = @splat(0),
    frame: sdk.geometry.RectF = .zero(),
};
const Trace = struct {
    base: sdk.platform.PlatformServices = .{},
    entries: [128]Entry = undefined,
    count: usize = 0,
    fail_at: ?usize = null,
    runtime: ?*sdk.Runtime = null,
    reparent_after_first_call: bool = false,
    fn mutate(self: *Trace) void {
        if (self.reparent_after_first_call and self.count == 1) self.runtime.?.webviews[0].parent = "missing";
    }
    fn append(self: *Trace, kind: u8, window: u64, label: []const u8, value: sdk.geometry.RectF) !void {
        const at = self.count;
        try std.testing.expect(at < self.entries.len);
        self.entries[at] = .{ .kind = kind, .window = window, .length = label.len, .frame = value };
        @memcpy(self.entries[at].label[0..label.len], label);
        self.count += 1;
        if (self.fail_at == at) return error.TestViewFailure;
    }
};
var traces: [2]Trace = .{ .{}, .{} };
fn trace(context: ?*anyopaque) *Trace {
    for (&traces) |*t| if (t.base.context == context) return t;
    unreachable;
}
fn focus(context: ?*anyopaque, window: u64, label: []const u8) !void {
    const t = trace(context);
    try t.append(0, window, label, .zero());
    try t.base.focusView(window, label);
}
fn frame(context: ?*anyopaque, window: u64, label: []const u8, value: sdk.geometry.RectF) !void {
    const t = trace(context);
    try t.append(1, window, label, value);
    try t.base.setWebViewFrame(window, label, value);
    t.mutate();
}
fn close(context: ?*anyopaque, window: u64, label: []const u8) !void {
    const t = trace(context);
    try t.append(2, window, label, .zero());
    try t.base.closeWebView(window, label);
    t.mutate();
}
const Pair = struct {
    left: *Harness,
    right: *Harness,
    fn create() !Pair {
        const a = std.testing.allocator;
        var pair = Pair{ .left = try Harness.create(a, .{}), .right = try Harness.create(a, .{}) };
        for ([_]*Harness{ pair.left, pair.right }, 0..) |h, i| {
            h.null_platform.gpu_surfaces = true;
            try h.start(.{ .context = h, .name = "view-coordination", .source = sdk.platform.WebViewSource.html("") });
            h.runtime.started_timestamp_ns = 0;
            traces[i] = .{ .base = h.runtime.options.platform.services, .runtime = &h.runtime };
            h.runtime.options.platform.services.focus_view_fn = focus;
            h.runtime.options.platform.services.set_webview_frame_fn = frame;
            h.runtime.options.platform.services.close_webview_fn = close;
            if (i == 1) h.runtime.view_coordination_policy = observed;
        }
        try pair.same();
        return pair;
    }
    fn destroy(self: *Pair) void {
        self.left.destroy(std.testing.allocator);
        self.right.destroy(std.testing.allocator);
    }
    fn setup(self: *Pair) !void {
        for ([_]*Harness{ self.left, self.right }) |h| {
            for ([_]sdk.platform.ViewOptions{
                .{ .label = "root", .kind = .stack, .frame = .init(10, 20, 600, 400) },
                .{ .label = "child", .parent = "root", .kind = .stack, .frame = .init(3, 4, 200, 100) },
                .{ .label = "action", .parent = "child", .kind = .button, .frame = .init(5, 6, 80, 30) },
                .{ .label = "canvas", .parent = "root", .kind = .gpu_surface, .frame = .init(8, 9, 200, 100) },
                .{ .label = "disabled", .kind = .button, .frame = .init(0, 0, 80, 30), .enabled = false },
                .{ .label = "hidden", .kind = .button, .frame = .init(0, 0, 80, 30), .visible = false },
                .{ .label = "preview", .parent = "root", .kind = .webview, .url = "zero://app/preview", .frame = .init(50, 60, 100, 80) },
                .{ .label = "nested-web", .parent = "preview", .kind = .webview, .url = "zero://app/nested", .frame = .init(7, 8, 60, 50) },
                .{ .label = "child-web", .parent = "child", .kind = .webview, .url = "zero://app/child", .frame = .init(9, 10, 60, 50) },
            }) |options| _ = try h.runtime.createView(options);
        }
        try self.same();
    }
    fn same(self: *Pair) !void {
        try exact(self.left.runtime.automationSnapshot("view-coordination"), self.right.runtime.automationSnapshot("view-coordination"));
        try exact(self.left.null_platform.views[0..self.left.null_platform.view_count], self.right.null_platform.views[0..self.right.null_platform.view_count]);
        try exact(self.left.null_platform.webviews[0..self.left.null_platform.webview_count], self.right.null_platform.webviews[0..self.right.null_platform.webview_count]);
        try std.testing.expectEqual(self.left.runtime.view_count, self.right.runtime.view_count);
        try std.testing.expectEqual(self.left.runtime.webview_count, self.right.runtime.webview_count);
        for (0..self.left.runtime.view_count) |i| {
            const a = &self.left.runtime.views[i];
            const b = &self.right.runtime.views[i];
            try exact(a.info(), b.info());
            try exact(a.parent, b.parent);
            try exact(a.canvasWidgetRenderState(), b.canvasWidgetRenderState());
            inline for (.{ "canvas_widget_ime_commit_grace", "canvas_widget_ime_owner_id", "canvas_widget_tab_input_focus_entry_held", "canvas_widget_terminal_paste_v_held" }) |name| try exact(@field(a, name), @field(b, name));
        }
        for (0..self.left.runtime.webview_count) |i| try exact(self.left.runtime.webviews[i], self.right.runtime.webviews[i]);
        inline for (.{ "targetless_ime_preedit_len", "targetless_ime_commit_grace", "invalidated" }) |name| try exact(@field(self.left.runtime, name), @field(self.right.runtime, name));
        try exact(traces[0].entries[0..traces[0].count], traces[1].entries[0..traces[1].count]);
        traces[0].count = 0;
        traces[1].count = 0;
        core.rt.frameReset();
    }
};
fn sameFrame(left: anyerror!sdk.geometry.RectF, right: anyerror!sdk.geometry.RectF) !void {
    if (left) |a| try exact(a, try right) else |e| try std.testing.expectError(e, right);
    core.rt.frameReset();
}
test "compiled view coordination preserves complete view enumeration and capacity prefixes" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    try pair.setup();
    for (0..50) |capacity| {
        var a: [49]sdk.platform.ViewInfo = undefined;
        var b: [49]sdk.platform.ViewInfo = undefined;
        try exact(pair.left.runtime.listViews(1, a[0..capacity]), pair.right.runtime.listViews(1, b[0..capacity]));
        core.rt.frameReset();
    }
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        h.runtime.views[0].open = false;
        h.runtime.webviews[0].open = false;
    }
    try pair.same();
    for ([_]u64{ 1, 2, 9007199254740993, std.math.maxInt(u64) }) |id| {
        var a: [49]sdk.platform.ViewInfo = undefined;
        var b: [49]sdk.platform.ViewInfo = undefined;
        try exact(pair.left.runtime.listViews(id, &a), pair.right.runtime.listViews(id, &b));
        core.rt.frameReset();
    }
}
test "compiled view coordination preserves focus adjacency wrap and complete repair effects" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    try pair.setup();
    for (0..18) |_| {
        try exact(try pair.left.runtime.focusNextView(1), try pair.right.runtime.focusNextView(1));
        try pair.same();
    }
    for (0..18) |_| {
        try exact(try pair.left.runtime.focusPreviousView(1), try pair.right.runtime.focusPreviousView(1));
        try pair.same();
    }
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        h.runtime.windows[0].main_focused = false;
        for (h.runtime.views[0..h.runtime.view_count]) |*v| v.focused = false;
        for (h.runtime.webviews[0..h.runtime.webview_count]) |*v| v.focused = false;
    }
    methods.ensureFocusableViewFocused(&pair.left.runtime, 1);
    methods.ensureFocusableViewFocused(&pair.right.runtime, 1);
    try pair.same();
    try std.testing.expect(pair.right.runtime.windows[0].main_focused);
}
test "compiled view coordination preserves explicit focus refusal and failed repair clearing" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    try pair.setup();
    for ([_][]const u8{ "disabled", "hidden", "missing" }) |label| {
        const a = pair.left.runtime.focusView(1, label);
        if (a) |_| return error.ExpectedFocusRefusal else |e| try std.testing.expectError(e, pair.right.runtime.focusView(1, label));
        try pair.same();
    }
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        h.runtime.windows[0].main_focused = false;
        for (h.runtime.views[0..h.runtime.view_count]) |*v| v.focused = false;
        for (h.runtime.webviews[0..h.runtime.webview_count]) |*v| v.focused = false;
    }
    traces[0].fail_at = 0;
    traces[1].fail_at = 0;
    methods.ensureFocusableViewFocused(&pair.left.runtime, 1);
    methods.ensureFocusableViewFocused(&pair.right.runtime, 1);
    try pair.same();
    try std.testing.expect(!pair.right.runtime.windows[0].main_focused);
}
test "compiled view coordination preserves complete per-view blur IME and tooltip hygiene" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    try pair.setup();
    for ([_]*Harness{ pair.left, pair.right }, 0..) |h, i| {
        try h.runtime.focusView(1, "canvas");
        const v = &h.runtime.views[3];
        if (i == 1) v.canvas_widget_surface_scope_policy = core.nativeSurfaceScopePolicy;
        v.canvas_widget_ime_commit_grace = .route_to_owner;
        v.canvas_widget_ime_owner_id = 9007199254740993;
        v.canvas_widget_tab_input_focus_entry_held = true;
        v.canvas_widget_terminal_paste_v_held = true;
        h.runtime.targetless_ime_preedit_window = 1;
        h.runtime.targetless_ime_preedit_label_len = "canvas".len;
        @memcpy(h.runtime.targetless_ime_preedit_label[0.."canvas".len], "canvas");
        h.runtime.targetless_ime_commit_grace = true;
    }
    try pair.same();
    try pair.left.runtime.focusView(1, "action");
    try pair.right.runtime.focusView(1, "action");
    try pair.same();
    try std.testing.expectEqual(@as(u64, 0), pair.right.runtime.views[3].canvas_widget_ime_owner_id);
    try std.testing.expect(!pair.right.runtime.targetless_ime_commit_grace);
    try methods.clearFocusedView(&pair.left.runtime, 1);
    try methods.clearFocusedView(&pair.right.runtime, 1);
    try pair.same();
}
test "compiled view coordination preserves raw parent admission and exact error precedence" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    try pair.setup();
    for ([_]?[]const u8{ null, "root", "main", "preview", "missing", "self" }) |parent| {
        const a = methods.validateViewParentLink(&pair.left.runtime, 1, "self", parent);
        if (a) |_| try methods.validateViewParentLink(&pair.right.runtime, 1, "self", parent) else |e| try std.testing.expectError(e, methods.validateViewParentLink(&pair.right.runtime, 1, "self", parent));
        core.rt.frameReset();
    }
    for ([_]u64{ 1, 2, 9007199254740993, std.math.maxInt(u64) }) |id| {
        const a = methods.validateViewParent(&pair.left.runtime, id);
        if (a) |_| try methods.validateViewParent(&pair.right.runtime, id) else |e| try std.testing.expectError(e, methods.validateViewParent(&pair.right.runtime, id));
        const link = methods.validateViewParentLink(&pair.left.runtime, id, "child", "main");
        if (link) |_| try methods.validateViewParentLink(&pair.right.runtime, id, "child", "main") else |e| try std.testing.expectError(e, methods.validateViewParentLink(&pair.right.runtime, id, "child", "main"));
        core.rt.frameReset();
    }
}
test "compiled view coordination preserves all f32 ancestor frames and local platform conversions" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    try pair.setup();
    const values = [_]f32{ -std.math.inf(f32), -16777216, -1, -0.0, 0, 0.000001, 1.0000001, 16777216, std.math.inf(f32), std.math.nan(f32) };
    for (values) |x| for (values) |y| {
        for ([_]*Harness{ pair.left, pair.right }) |h| {
            h.runtime.views[0].frame.x = x;
            h.runtime.views[0].frame.y = y;
        }
        for ([_][]const u8{ "main", "root", "child", "action", "preview", "missing" }) |label| {
            try sameFrame(methods.absoluteViewFrame(&pair.left.runtime, 1, label, 0), methods.absoluteViewFrame(&pair.right.runtime, 1, label, 0));
        }
        const base = sdk.geometry.RectF.init(x, y, -0.0, 0.000001);
        for ([_]?[]const u8{ null, "root", "child", "preview", "missing" }) |parent| {
            try sameFrame(methods.platformFrameForView(&pair.left.runtime, 1, parent, base), methods.platformFrameForView(&pair.right.runtime, 1, parent, base));
            try sameFrame(methods.localFrameForView(&pair.left.runtime, 1, parent, base), methods.localFrameForView(&pair.right.runtime, 1, parent, base));
        }
    };
    for ([_]usize{ 48, 49, 50, std.math.maxInt(usize) }) |depth| try sameFrame(methods.absoluteViewFrame(&pair.left.runtime, 1, "action", depth), methods.absoluteViewFrame(&pair.right.runtime, 1, "action", depth));
}
test "compiled view coordination preserves complete nested WebView relayout and postorder close calls" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    try pair.setup();
    for ([_]*Harness{ pair.left, pair.right }) |h| _ = try h.runtime.updateView(1, "root", .{ .frame = .init(100, 200, 600, 400) });
    try std.testing.expectEqual(@as(usize, 3), traces[1].count);
    try std.testing.expectEqualStrings("child-web", traces[1].entries[0].label[0..traces[1].entries[0].length]);
    try std.testing.expectEqualStrings("preview", traces[1].entries[1].label[0..traces[1].entries[1].length]);
    try std.testing.expectEqualStrings("nested-web", traces[1].entries[2].label[0..traces[1].entries[2].length]);
    try pair.same();
    for ([_]*Harness{ pair.left, pair.right }) |h| try methods.closeDescendantWebViewBackends(&h.runtime, 1, "root");
    try std.testing.expectEqualStrings("child-web", traces[1].entries[0].label[0..traces[1].entries[0].length]);
    try std.testing.expectEqualStrings("nested-web", traces[1].entries[1].label[0..traces[1].entries[1].length]);
    try std.testing.expectEqualStrings("preview", traces[1].entries[2].label[0..traces[1].entries[2].length]);
    try pair.same();
}
test "compiled view coordination preserves capability failure prefixes during descendant relayout" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for (0..3) |failure| {
        var pair = try Pair.create();
        defer pair.destroy();
        try pair.setup();
        traces[0].fail_at = failure;
        traces[1].fail_at = failure;
        for ([_]*Harness{ pair.left, pair.right }) |h| try std.testing.expectError(error.TestViewFailure, h.runtime.updateView(1, "root", .{ .frame = .init(100, 200, 600, 400) }));
        try pair.same();
        try std.testing.expectEqual(@as(f32, 100), pair.right.runtime.views[0].frame.x);
    }
}
test "compiled view coordination observes descendant membership changed by capability callbacks" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for ([_]bool{ false, true }) |closing| {
        var pair = try Pair.create();
        defer pair.destroy();
        try pair.setup();
        traces[0].reparent_after_first_call = true;
        traces[1].reparent_after_first_call = true;
        for ([_]*Harness{ pair.left, pair.right }) |h| {
            if (closing) try methods.closeDescendantWebViewBackends(&h.runtime, 1, "root") else _ = try h.runtime.updateView(1, "root", .{ .frame = .init(100, 200, 600, 400) });
        }
        try std.testing.expectEqual(@as(usize, 1), traces[1].count);
        try pair.same();
    }
}
test "compiled view coordination preserves subtree focus depth bounds and parent retirement" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var pair = try Pair.create();
    defer pair.destroy();
    try pair.setup();
    for ([_][]const u8{ "action", "canvas", "preview", "nested-web", "main" }) |focused| {
        for ([_]*Harness{ pair.left, pair.right }) |h| try h.runtime.focusView(1, focused);
        for ([_][]const u8{ "root", "child", "preview", "main", "missing" }) |label| for ([_]usize{ 0, 47, 48, 49 }) |depth| {
            try std.testing.expectEqual(methods.viewTreeHasFocusedDepth(&pair.left.runtime, 1, label, depth), methods.viewTreeHasFocusedDepth(&pair.right.runtime, 1, label, depth));
            core.rt.frameReset();
        };
        try pair.same();
    }
    for ([_]*Harness{ pair.left, pair.right }) |h| try h.runtime.closeView(1, "root");
    try pair.same();
    try std.testing.expectEqual(@as(usize, 2), pair.right.runtime.view_count);
    try std.testing.expectEqual(@as(usize, 0), pair.right.runtime.webview_count);
    for (0..11) |mode| try std.testing.expect(calls[mode] > 0);
}
