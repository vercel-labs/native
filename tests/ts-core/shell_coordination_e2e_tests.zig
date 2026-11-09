const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const Harness = sdk.TestHarness();
const p = sdk.runtime.testing.shell_coordination_policy;
var modes: [8]usize = @splat(0);
fn observed(request: []const u8, output: []u8) usize {
    if (request[0] == 84) modes[request[2]] += 1;
    return core.nativeWindowPolicy(request, output);
}
const Pair = struct {
    left: *Harness,
    right: *Harness,
    fn create() !Pair {
        const a = try Harness.create(std.testing.allocator, .{});
        errdefer a.destroy(std.testing.allocator);
        const b = try Harness.create(std.testing.allocator, .{});
        errdefer b.destroy(std.testing.allocator);
        for ([_]*Harness{ a, b }, 0..) |h, i| {
            h.null_platform.gpu_surfaces = true;
            try h.start(.{ .context = h, .name = "shell-coordination", .source = sdk.platform.WebViewSource.html("") });
            h.runtime.started_timestamp_ns = 0;
            if (i == 1) {
                h.runtime.shell_coordination_policy = observed;
                h.runtime.shell_layout_policy = observed;
            }
        }
        return .{ .left = a, .right = b };
    }
    fn destroy(self: Pair) void {
        self.left.destroy(std.testing.allocator);
        self.right.destroy(std.testing.allocator);
    }
    fn same(self: Pair) !void {
        var left = self.left.runtime.automationSnapshot("shell-coordination");
        var right = self.right.runtime.automationSnapshot("shell-coordination");
        const left_errors = try std.testing.allocator.dupe(sdk.automation.snapshot.DispatchError, left.errors);
        defer std.testing.allocator.free(left_errors);
        const right_errors = try std.testing.allocator.dupe(sdk.automation.snapshot.DispatchError, right.errors);
        defer std.testing.allocator.free(right_errors);
        // Retain every populated error field; each lane independently samples
        // the OS error clock and unused buffer tails are undefined storage.
        for ([_][]sdk.automation.snapshot.DispatchError{ left_errors, right_errors }) |errors| for (errors) |*record| {
            try std.testing.expect(record.timestamp_ns > 0);
            record.timestamp_ns = 0;
            @memset(record.event_storage[record.event_len..], 0);
            @memset(record.detail_storage[record.detail_len..], 0);
        };
        left.errors = left_errors;
        right.errors = right_errors;
        try exact(left, right);
        try exact(self.left.null_platform.views[0..self.left.null_platform.view_count], self.right.null_platform.views[0..self.right.null_platform.view_count]);
        try exact(self.left.null_platform.webviews[0..self.left.null_platform.webview_count], self.right.null_platform.webviews[0..self.right.null_platform.webview_count]);
        try exact(self.left.runtime.shell_layout_count, self.right.runtime.shell_layout_count);
        for (self.left.runtime.shell_layouts[0..self.left.runtime.shell_layout_count], self.right.runtime.shell_layouts[0..self.right.runtime.shell_layout_count]) |*a, *b| {
            try exact(a.window_id, b.window_id);
            try exact(a.viewSlice(), b.viewSlice());
        }
        for (self.left.runtime.windows[0..self.left.runtime.window_count], self.right.runtime.windows[0..self.right.runtime.window_count]) |a, b| {
            try exact(a.info, b.info);
            try exact(a.main_frame, b.main_frame);
            try exact(a.main_frame_set, b.main_frame_set);
            try exact(a.main_layer, b.main_layer);
            try exact(a.main_parent, b.main_parent);
            try exact(a.source, b.source);
            try exact(a.source_policy, b.source_policy);
        }
        try exact(self.left.runtime.next_window_id, self.right.runtime.next_window_id);
        try exact(self.left.runtime.next_view_id, self.right.runtime.next_view_id);
    }
};
test "compiled shell coordination preserves scene routing and presentation precedence" {
    const kinds = [_]sdk.ShellView{
        .{ .kind = .webview, .label = "main" },
        .{ .kind = .webview, .label = "child" },
        .{ .kind = .gpu_surface, .label = "canvas" },
        .{ .kind = .button, .label = "button" },
    };
    for (0..16) |mask| for ([_]bool{ false, true }) |empty| for ([_]bool{ false, true }) |hidden| {
        var views: [4]sdk.ShellView = undefined;
        var count: usize = 0;
        for (kinds, 0..) |view, i| if (mask & (@as(usize, 1) << @intCast(i)) != 0) {
            views[count] = view;
            count += 1;
        };
        const window = sdk.ShellWindow{ .label = "shell", .views = views[0..count], .initially_hidden = hidden };
        const compiled = p.scene(observed, &.{window}, empty);
        var has_main = false;
        var has_web = false;
        var has_gpu = false;
        for (views[0..count]) |view| {
            if (view.kind == .webview) has_web = true;
            if (view.kind == .gpu_surface) has_gpu = true;
            if (view.kind == .webview and std.mem.eql(u8, view.label, "main")) has_main = true;
        }
        try std.testing.expectEqual(has_main or !empty, compiled.decisions != 0);
        try std.testing.expectEqual(has_main or (!(has_gpu and !has_web) and !empty), compiled.choices[0] & 4 != 0);
        const presentation = p.presentation(observed, window);
        try std.testing.expectEqual(@as(sdk.platform.WindowShowMode, if (hidden) .hidden else if (has_gpu) .on_first_present else .immediate), presentation.show);
        try std.testing.expectEqual(sdk.platform.WindowInitialPlacement.default, presentation.placement);
    };
    var oversized: [129]sdk.ShellView = @splat(.{ .kind = .button, .label = "button" });
    oversized[128].kind = .gpu_surface;
    try std.testing.expectEqual(sdk.platform.WindowShowMode.on_first_present, p.presentation(observed, .{ .views = &oversized, .x = 0 }).show);
    try std.testing.expectEqual(sdk.platform.WindowInitialPlacement.explicit, p.presentation(observed, .{ .views = &oversized, .x = 0 }).placement);
}
test "compiled shell coordination preserves exact opaque labels and invalid oversized duplicates" {
    for ([_]usize{ 0, 1, 4, 15, 16, 17, 63, 64, 65, 255 }) |n| {
        var a: [255]u8 = @splat(0xff);
        var b = a;
        try std.testing.expect(p.equal(observed, a[0..n], b[0..n]));
        if (n > 0) {
            b[n - 1] = 0;
            try std.testing.expect(!p.equal(observed, a[0..n], b[0..n]));
            try std.testing.expect(!p.equal(observed, a[0..n], a[0 .. n - 1]));
        }
    }
    const pair = try Pair.create();
    defer pair.destroy();
    var label: [65]u8 = @splat('a');
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        try std.testing.expectError(error.DuplicateViewLabel, sdk.runtime.testing.shell_view_methods.validateShellViewCreatePlan(&h.runtime, 1, &.{ .{ .kind = .button, .label = &label }, .{ .kind = .button, .label = &label } }));
    }
    try pair.same();
}
test "compiled shell coordination preserves parent-first application owned storage and relayout" {
    const pair = try Pair.create();
    defer pair.destroy();
    var root_label = [_]u8{ 'r', 'o', 'o', 't' };
    const views = [_]sdk.ShellView{
        .{ .label = "action", .parent = &root_label, .kind = .button },
        .{ .label = &root_label, .kind = .stack, .fill = true },
        .{ .label = "canvas", .kind = .gpu_surface, .parent = &root_label, .x = 120, .width = 200, .height = 80 },
    };
    for ([_]*Harness{ pair.left, pair.right }) |h| try h.runtime.createShellViews(1, &views, .init(0, 0, 800, 600));
    try pair.same();
    root_label[0] = 'x';
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        try h.runtime.relayoutShellViews(1);
        h.runtime.windows[0].info.frame = .init(0, 0, 960, 720);
        try h.runtime.relayoutShellViews(1);
    }
    try pair.same();
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        try h.runtime.closeView(1, "action");
        try h.runtime.relayoutShellViews(1);
    }
    try pair.same();
}
test "compiled shell coordination preserves prefix rollback and healthy retry" {
    const pair = try Pair.create();
    defer pair.destroy();
    const bad = [_]sdk.ShellView{
        .{ .label = "main", .kind = .webview, .x = 11, .y = 12, .width = 400, .height = 300, .layer = 2 },
        .{ .label = "first", .kind = .button },
        .{ .label = "orphan", .kind = .button, .parent = "missing" },
    };
    for ([_]*Harness{ pair.left, pair.right }) |h| try std.testing.expectError(error.InvalidViewOptions, h.runtime.createShellViews(1, &bad, .init(0, 0, 800, 600)));
    try pair.same();
    for ([_]*Harness{ pair.left, pair.right }) |h| try h.runtime.createShellViews(1, bad[0..2], .init(0, 0, 800, 600));
    try pair.same();
    for ([_]*Harness{ pair.left, pair.right }) |h| try std.testing.expectError(error.DuplicateViewLabel, h.runtime.createShellViews(1, bad[0..2], .init(0, 0, 800, 600)));
    try pair.same();
}
test "compiled shell coordination preserves admission error precedence and failed binding copy" {
    const pair = try Pair.create();
    defer pair.destroy();
    const labels = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "aa", "ab", "ac", "ad", "ae", "af", "ag" };
    var views: [33]sdk.ShellView = undefined;
    for (&views, labels) |*view, label| view.* = .{ .label = label, .kind = .button };
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        try std.testing.expectError(error.WindowNotFound, sdk.runtime.testing.shell_view_methods.validateShellViewCreatePlan(&h.runtime, 999, &views));
        try std.testing.expectError(error.ViewLimitReached, sdk.runtime.testing.shell_view_methods.validateShellViewCreatePlan(&h.runtime, 1, &views));
        try h.runtime.createShellViews(1, views[0..1], .init(0, 0, 800, 600));
        var long: [65]u8 = @splat('z');
        try std.testing.expectError(error.NoSpaceLeft, sdk.runtime.testing.window_storage_methods.bindShellViews(&h.runtime, 1, &.{.{ .label = &long, .kind = .button }}));
    }
    try pair.same();
}
test "compiled shell coordination preserves exact binding identities and capacity" {
    const pair = try Pair.create();
    defer pair.destroy();
    const ids = [_]u64{ 9007199254740992, 9007199254740993, std.math.maxInt(u64) };
    for (ids) |id| {
        for ([_]*Harness{ pair.left, pair.right }) |h| try sdk.runtime.testing.window_storage_methods.bindShellViews(&h.runtime, id, &.{});
        try pair.same();
    }
    for (0..13) |i| for ([_]*Harness{ pair.left, pair.right }) |h| try sdk.runtime.testing.window_storage_methods.bindShellViews(&h.runtime, i + 1, &.{});
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        try std.testing.expectError(error.WindowLimitReached, sdk.runtime.testing.window_storage_methods.bindShellViews(&h.runtime, 99, &.{}));
        try sdk.runtime.testing.window_storage_methods.bindShellViews(&h.runtime, ids[1], &.{});
    }
    try pair.same();
}
const Trace = struct {
    base: sdk.platform.PlatformServices,
    entries: [64]u8 = @splat(0),
    count: usize = 0,
    creates: usize = 0,
    fail_create: ?usize = null,
    fail_restore: bool = false,
    mutate: bool = false,
    runtime: *sdk.Runtime,
    fn append(self: *Trace, kind: u8) void {
        self.entries[self.count] = kind;
        self.count += 1;
    }
};
var traces: [2]Trace = undefined;
fn trace(context: ?*anyopaque) *Trace {
    for (&traces) |*t| if (t.base.context == context) return t;
    unreachable;
}
fn create(context: ?*anyopaque, options: sdk.platform.ViewOptions) !void {
    const t = trace(context);
    t.append(1);
    const index = t.creates;
    t.creates += 1;
    if (t.fail_create == index) return error.ShellCreateRefused;
    try t.base.createView(options);
    if (t.mutate) {
        t.runtime.windows[0].main_layer = 17;
        t.runtime.windows[0].main_frame = .init(3, 4, 250, 150);
        t.runtime.windows[0].main_frame_set = true;
    }
}
fn close(context: ?*anyopaque, window: u64, label: []const u8) !void {
    const t = trace(context);
    t.append(if (std.mem.eql(u8, label, "a")) 2 else 3);
    try t.base.closeView(window, label);
}
fn frame(context: ?*anyopaque, window: u64, label: []const u8, value: sdk.geometry.RectF) !void {
    const t = trace(context);
    t.append(if (value.width == 400) 4 else 5);
    if (t.fail_restore and value.width != 400) return error.ShellRestoreFrameRefused;
    try t.base.setWebViewFrame(window, label, value);
}
fn layer(context: ?*anyopaque, window: u64, label: []const u8, value: i32) !void {
    const t = trace(context);
    t.append(if (value == 2) 6 else 7);
    if (t.fail_restore and value != 2) return error.ShellRestoreLayerRefused;
    try t.base.setWebViewLayer(window, label, value);
}
test "compiled shell coordination preserves OS refusal reverse cleanup restoration and retry" {
    const pair = try Pair.create();
    defer pair.destroy();
    for ([_]*Harness{ pair.left, pair.right }, 0..) |h, i| {
        traces[i] = .{ .base = h.runtime.options.platform.services, .runtime = &h.runtime, .fail_create = 2, .fail_restore = true };
        h.runtime.options.platform.services.create_view_fn = create;
        h.runtime.options.platform.services.close_view_fn = close;
        h.runtime.options.platform.services.set_webview_frame_fn = frame;
        h.runtime.options.platform.services.set_webview_layer_fn = layer;
    }
    const views = [_]sdk.ShellView{
        .{ .label = "main", .kind = .webview, .width = 400, .height = 300, .layer = 2 },
        .{ .label = "a", .kind = .button },
        .{ .label = "b", .kind = .button },
        .{ .label = "c", .kind = .button },
    };
    for ([_]*Harness{ pair.left, pair.right }) |h| try std.testing.expectError(error.ShellCreateRefused, h.runtime.createShellViews(1, &views, .init(0, 0, 800, 600)));
    try pair.same();
    try exact(traces[0].entries[0..traces[0].count], traces[1].entries[0..traces[1].count]);
    try std.testing.expectEqualSlices(u8, &.{ 4, 6, 1, 1, 1, 3, 2, 5, 7 }, traces[0].entries[0..traces[0].count]);
    for (&traces) |*t| {
        t.fail_create = null;
        t.fail_restore = false;
    }
    for ([_]*Harness{ pair.left, pair.right }) |h| try h.runtime.createShellViews(1, &views, .init(0, 0, 800, 600));
    try pair.same();
    try exact(traces[0].entries[0..traces[0].count], traces[1].entries[0..traces[1].count]);
}
test "compiled shell coordination retains original restoration copy across callback mutation" {
    const pair = try Pair.create();
    defer pair.destroy();
    // Captured main state is restored even if a callback changes current
    // state during the transaction. No borrowed result is reset.
    for ([_]*Harness{ pair.left, pair.right }, 0..) |h, i| {
        traces[i] = .{ .base = h.runtime.options.platform.services, .runtime = &h.runtime, .fail_create = 1, .mutate = true };
        h.runtime.options.platform.services.create_view_fn = create;
        h.runtime.options.platform.services.close_view_fn = close;
    }
    const views = [_]sdk.ShellView{ .{ .label = "a", .kind = .button }, .{ .label = "b", .kind = .button } };
    for ([_]*Harness{ pair.left, pair.right }) |h| try std.testing.expectError(error.ShellCreateRefused, h.runtime.createShellViews(1, &views, .init(0, 0, 800, 600)));
    try pair.same();
    try exact(traces[0].entries[0..traces[0].count], traces[1].entries[0..traces[1].count]);
}
const Scene = struct {
    windows: []const sdk.ShellWindow,
    source_calls: usize = 0,
    scene_calls: usize = 0,
    mutate: ?*sdk.ShellView = null,
    replace_window: ?*sdk.ShellWindow = null,
    replacement: []const sdk.ShellView = &.{},
    fn scene(context: *anyopaque) !sdk.ShellConfig {
        const self: *Scene = @ptrCast(@alignCast(context));
        self.scene_calls += 1;
        return .{ .windows = self.windows };
    }
    fn source(context: *anyopaque) !sdk.platform.WebViewSource {
        const self: *Scene = @ptrCast(@alignCast(context));
        self.source_calls += 1;
        if (self.mutate) |view| {
            view.kind = .gpu_surface;
            view.url = null;
        }
        if (self.replace_window) |window| window.views = self.replacement;
        return sdk.platform.WebViewSource.html("<p>Owned scene source</p>");
    }
};
test "compiled shell coordination loads complete hybrid scenes and reobserves source callback mutations" {
    for ([_]bool{ false, true }) |mutate| {
        var harnesses: [2]*Harness = undefined;
        var created: usize = 0;
        defer for (harnesses[0..created]) |h| h.destroy(std.testing.allocator);
        var scenes: [2]Scene = undefined;
        var child_views: [2][1]sdk.ShellView = @splat(.{.{ .label = "child", .kind = .webview, .url = "zero://app/child", .fill = true }});
        const canvas_views = [_]sdk.ShellView{.{ .label = "canvas", .kind = .gpu_surface, .fill = true }};
        var windows: [2][2]sdk.ShellWindow = undefined;
        for (&harnesses, 0..) |*h, i| {
            windows[i] = .{
                .{ .label = "canvas-window", .views = &canvas_views },
                .{ .label = "source-window", .views = &child_views[i] },
            };
            scenes[i] = .{ .windows = &windows[i], .mutate = if (mutate) &child_views[i][0] else null };
            h.* = try Harness.create(std.testing.allocator, .{});
            created += 1;
            h.*.null_platform.gpu_surfaces = true;
            try h.*.start(.{ .context = &scenes[i], .name = "shell-coordination", .source_fn = Scene.source, .scene_fn = Scene.scene, .shell_coordination_policy = if (i == 1) observed else null, .shell_layout_policy = if (i == 1) observed else null });
            h.*.runtime.started_timestamp_ns = 0;
        }
        const pair = Pair{ .left = harnesses[0], .right = harnesses[1] };
        try pair.same();
        try std.testing.expectEqual(@as(usize, 1), scenes[0].source_calls);
        try std.testing.expectEqual(scenes[0].source_calls, scenes[1].source_calls);
        try std.testing.expectEqual(scenes[0].scene_calls, scenes[1].scene_calls);
        try std.testing.expect(pair.left.runtime.windows[0].source == null);
        try std.testing.expectEqual(!mutate, pair.left.runtime.windows[1].source != null);
    }
}
test "compiled shell coordination retains creation errors after oversized source callback mutation" {
    var harnesses: [2]*Harness = undefined;
    var created: usize = 0;
    defer for (harnesses[0..created]) |h| h.destroy(std.testing.allocator);
    const initial = [_]sdk.ShellView{.{ .label = "canvas", .kind = .gpu_surface, .fill = true }};
    var replacement: [129]sdk.ShellView = @splat(.{ .label = "oversized", .kind = .button });
    replacement[128].kind = .gpu_surface;
    var windows: [2][1]sdk.ShellWindow = undefined;
    var scenes: [2]Scene = undefined;
    for (&harnesses, 0..) |*h, i| {
        windows[i] = .{.{ .label = "canvas-window", .views = &initial }};
        scenes[i] = .{ .windows = &windows[i], .replace_window = &windows[i][0], .replacement = &replacement };
        h.* = try Harness.create(std.testing.allocator, .{});
        created += 1;
        h.*.null_platform.gpu_surfaces = true;
        try std.testing.expectError(error.ViewLimitReached, h.*.start(.{ .context = &scenes[i], .name = "shell-coordination", .source_fn = Scene.source, .scene_fn = Scene.scene, .shell_coordination_policy = if (i == 1) observed else null, .shell_layout_policy = if (i == 1) observed else null }));
        h.*.runtime.started_timestamp_ns = 0;
    }
    const pair = Pair{ .left = harnesses[0], .right = harnesses[1] };
    try pair.same();
    try std.testing.expectEqual(@as(usize, 1), scenes[0].source_calls);
    try std.testing.expectEqual(scenes[0].source_calls, scenes[1].source_calls);
}
test "compiled shell coordination exercises every decision mode" {
    for (modes) |count| try std.testing.expect(count > 0);
}
