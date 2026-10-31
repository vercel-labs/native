const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const p = sdk.runtime.testing.web_pane_policy;
const canvas = sdk.canvas;
const geometry = sdk.geometry;
const equal = @import("surface_layout_e2e_tests.zig").expectComplete;
var calls = [_]usize{0} ** 4;
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 99) calls[input[1]] += 1;
    return core.nativeWindowPolicy(input, output);
}
const Cases = sdk.runtime.testing.web_pane_test_cases.Cases(observed);
test "compiled web panes: ui app scene with a child webview stays main-webview-free" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case0();
}
test "compiled web panes: ui app webview pane snaps the webview to the anchor widget frame" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case1();
}
test "compiled web panes: ui app webview pane navigates on url change and reloads on token bump" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    try Cases.case2();
}

fn rectBits(a: geometry.RectF, b: geometry.RectF) !void {
    inline for (.{ "x", "y", "width", "height" }) |field|
        try std.testing.expectEqual(@as(u32, @bitCast(@field(a, field))), @as(u32, @bitCast(@field(b, field))));
}
fn node(label: []const u8, frame: geometry.RectF) canvas.WidgetLayoutNode {
    return .{ .widget = .{ .kind = .panel, .semantics = .{ .label = label } }, .frame = frame, .depth = 0, .parent_index = null };
}
test "compiled web panes preserve first anchors f32 admission raw bits and copied plans" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var nodes: [1024]canvas.WidgetLayoutNode = undefined;
    for (&nodes) |*n| n.* = node("other", .init(0, 0, 3, 4));
    for (&nodes, 0..) |*n, i| {
        n.widget.semantics.label = "anchor\x00\xff";
        const planned = p.frame(observed, &nodes, .init(10, 20, 30, 40), "anchor\x00\xff");
        core.rt.frameReset();
        try std.testing.expect(planned.kind == .apply);
        try rectBits(nodes[i].frame, planned.value);
        n.widget.semantics.label = "other";
    }
    try std.testing.expect(p.frame(observed, &nodes, .init(1, 2, 3, 4), "absent").kind == .missing_anchor);
    nodes[0] = node("first", .init(-10, -20, 0.999, 100));
    nodes[1] = node("first", .init(10, 20, 100, 100));
    try std.testing.expect(p.frame(observed, &nodes, .init(1, 2, 3, 4), "first").kind == .collapsed);
    const values = [_]f32{ -std.math.inf(f32), -1, -0.0, 0, 0.99999994, 1, 1.0000001, std.math.inf(f32), @bitCast(@as(u32, 0x7fc12345)) };
    for (values) |v| inline for (.{ "x", "y", "width", "height" }) |field| {
        var frame: geometry.RectF = .init(1, 2, 3, 4);
        @field(frame, field) = v;
        const before = frame;
        const planned = p.frame(observed, &nodes, frame, null);
        core.rt.frameReset();
        try rectBits(before, frame);
        if (frame.width < 1 or frame.height < 1) {
            try std.testing.expect(planned.kind == .collapsed);
        } else {
            frame.x = @max(frame.x, 0);
            frame.y = @max(frame.y, 0);
            try std.testing.expect(planned.kind == .apply);
            try rectBits(frame, planned.value);
        }
    };
}
const State = struct { label_storage: [64]u8 = @splat(0xa5), label_len: usize = 0 };
test "compiled web panes preserve opaque truncated duplicate labels and complete bounded lengths" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var states = [_]State{.{}} ** 4;
    const labels = [_][]const u8{ "", "one\x00\xff", "same", "same" };
    for (&states, labels) |*s, label| {
        @memcpy(s.label_storage[0..label.len], label);
        s.label_len = label.len;
    }
    const long = [_]u8{0xfe} ** 65;
    for (0..5) |count| for (labels ++ .{long[0..]}) |label| {
        const before = states;
        var expected: ?usize = null;
        for (states[0..count], 0..) |state, i| if (std.mem.eql(u8, state.label_storage[0..state.label_len], label)) {
            expected = i;
            break;
        };
        const planned = p.slot(observed, states[0..count], label, 64);
        core.rt.frameReset();
        try equal(before, states);
        if (expected) |index| {
            try equal(p.Slot{ .index = index, .create = false, .label_bytes = 0 }, planned.?);
        } else if (count < 4) {
            try equal(p.Slot{ .index = count, .create = true, .label_bytes = @min(label.len, 64) }, planned.?);
        } else try std.testing.expect(planned == null);
    };
    for ([_]usize{ 0, 1, 4095, 4096, 4097, 9007199254740993, std.math.maxInt(usize) }) |length| for ([_]usize{ 0, 1, 4096 }) |capacity| {
        const failed = p.commit(observed, false, length, capacity);
        const success = p.commit(observed, true, length, capacity);
        core.rt.frameReset();
        try std.testing.expect(failed == null);
        try std.testing.expectEqual(@min(length, capacity), success.?);
    };
}
test "compiled web panes preserve strict f32 thresholds and every reload identity word" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const tokens = [_]u64{ 0, 0xffffffff, 0x100000000, 9007199254740992, 9007199254740993, std.math.maxInt(u64) };
    for (tokens) |previous| for (tokens) |token| for ([_][]const u8{ "", "old\x00\xff" }) |old| for ([_][]const u8{ "", "old\x00\xff", "new" }) |url| {
        const actual: geometry.RectF = .init(0, 0, 3, 4);
        for ([_]f32{ -std.math.inf(f32), -0.25000003, -0.25, -0.24999999, -0.0, 0, 0.24999999, 0.25, 0.25000003, std.math.inf(f32), std.math.nan(f32) }) |delta| inline for (.{ "x", "y", "width", "height" }) |field| {
            var desired = actual;
            @field(desired, field) += delta;
            const result = p.patch(observed, actual, desired, old, url, previous, token);
            core.rt.frameReset();
            const close = @abs(actual.x - desired.x) < 0.25 and @abs(actual.y - desired.y) < 0.25 and @abs(actual.width - desired.width) < 0.25 and @abs(actual.height - desired.height) < 0.25;
            try std.testing.expectEqual(!close, result.frame);
            try std.testing.expectEqual(url.len != 0 and (old.len == 0 or !std.mem.eql(u8, old, url) or previous != token), result.url);
        };
    };
}

const Model = struct { phase: usize = 0, token: u64 = 9007199254740993, extent: f32 = 220 };
const Msg = union(enum) { phase: usize, token: u64, extent: f32, again };
const App = sdk.UiApp(Model, Msg);
const initial_url = "https://example.com/one";
const second_url = "https://example.com/two";
const denied_url = "https://denied.example/three";
fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .phase => |v| model.phase = v,
        .token => |v| model.token = v,
        .extent => |v| model.extent = v,
        .again => {},
    }
}
fn view(ui: *App.Ui, model: *const Model) App.Ui.Node {
    return ui.column(.{ .gap = 8 }, .{
        ui.text(.{}, "Embedded pane coordination"),
        ui.panel(.{ .height = if (model.phase == 6) 0 else model.extent, .semantics = .{ .label = "anchor" } }, .{}),
        ui.text(.{}, "Retained footer"),
    });
}
const long_label = [_]u8{'x'} ** 65;
const large_url = "https://example.com/" ++ ([_]u8{'a'} ** 4096);
fn panes(model: *const Model, out: []App.WebViewPane) usize {
    out[0] = .{ .label = "preview", .anchor = "anchor", .url = initial_url, .reload_token = model.token };
    switch (model.phase) {
        1 => out[0].url = second_url,
        2 => {
            out[1] = out[0];
            out[1].url = second_url;
            out[1].reload_token = model.token ^ 1;
            return 2;
        },
        3 => out[0].url = denied_url,
        4 => out[0].url = "",
        5 => out[0].anchor = "missing",
        7 => out[0].label = "missing-view",
        8 => out[0].label = &long_label,
        9 => out[0].url = large_url,
        10 => {
            out[0].label = "other";
            out[0].anchor = null;
            out[0].frame = .init(-10, -20, 101, 102);
        },
        11 => {
            out[0].anchor = null;
            out[0].frame = .init(-0.0, -0.0, 123, 124);
        },
        else => {},
    }
    return 1;
}
const scene: sdk.app_manifest.ShellConfig = .{ .windows = &.{.{ .label = "main", .title = "Web panes", .width = 400, .height = 300, .views = &.{
    .{ .label = "canvas", .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
    .{ .label = "preview", .kind = .webview, .parent = "canvas", .url = initial_url, .width = 200, .height = 100 },
    .{ .label = "other", .kind = .webview, .parent = "canvas", .url = initial_url, .width = 200, .height = 100 },
} }} };
const Pair = struct {
    h: *sdk.TestHarness(),
    app: *App,
    fn create(compiled: bool) !Pair {
        const h = try sdk.TestHarness().create(std.testing.allocator, .{ .size = .init(400, 300) });
        errdefer h.destroy(std.testing.allocator);
        h.null_platform.gpu_surfaces = true;
        h.runtime.options.security.navigation.allowed_origins = &.{"https://example.com"};
        const a = try std.testing.allocator.create(App);
        errdefer std.testing.allocator.destroy(a);
        a.* = App.init(std.heap.page_allocator, .{}, .{ .name = "web-pane-test", .scene = scene, .canvas_label = "canvas", .view = view, .update = update, .web_panes = panes, .web_pane_policy = if (compiled) observed else null });
        try h.start(a.app());
        h.runtime.started_timestamp_ns = 0;
        try h.runtime.dispatchPlatformEvent(a.app(), .{ .gpu_surface_frame = .{ .label = "canvas", .size = .init(400, 300), .scale_factor = 1, .frame_index = 1, .timestamp_ns = 1000000, .nonblank = true } });
        return .{ .h = h, .app = a };
    }
    fn destroy(self: Pair) void {
        self.app.deinit();
        std.testing.allocator.destroy(self.app);
        self.h.destroy(std.testing.allocator);
    }
};
fn same(a: Pair, b: Pair) !void {
    core.rt.frameReset();
    try equal(a.app.model, b.app.model);
    try equal(a.app.tree.?.root, b.app.tree.?.root);
    try equal(try a.h.runtime.canvasWidgetLayout(1, "canvas"), try b.h.runtime.canvasWidgetLayout(1, "canvas"));
    try equal(a.app.web_pane_state_count, b.app.web_pane_state_count);
    for (a.app.web_pane_states[0..a.app.web_pane_state_count], b.app.web_pane_states[0..b.app.web_pane_state_count]) |left, right| {
        try equal(left.label_storage[0..left.label_len], right.label_storage[0..right.label_len]);
        try equal(left.url_storage[0..left.url_len], right.url_storage[0..right.url_len]);
        try equal(left.reload_token, right.reload_token);
    }
    try equal(a.h.null_platform.webview_navigate_count, b.h.null_platform.webview_navigate_count);
    try equal(a.h.runtime.automationSnapshot("Web panes"), b.h.runtime.automationSnapshot("Web panes"));
    try equal(a.h.null_platform.webview_count, b.h.null_platform.webview_count);
    for (a.h.null_platform.webviews[0..a.h.null_platform.webview_count], b.h.null_platform.webviews[0..b.h.null_platform.webview_count]) |left, right| {
        try equal(left.window_id, right.window_id);
        try equal(left.label, right.label);
        try equal(left.url, right.url);
        try equal(left.frame, right.frame);
        try equal(left.layer, right.layer);
        try equal(left.transparent, right.transparent);
        try equal(left.bridge_enabled, right.bridge_enabled);
        try equal(left.zoom, right.zoom);
        try equal(left.open, right.open);
    }
}
fn dispatch(a: Pair, b: Pair, msg: Msg) !void {
    try a.app.dispatch(&a.h.runtime, 1, msg);
    try b.app.dispatch(&b.h.runtime, 1, msg);
    try same(a, b);
}
test "compiled web panes preserve complete runtime snapshots retained state failures and retries" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const a = try Pair.create(false);
    defer a.destroy();
    const b = try Pair.create(true);
    defer b.destroy();
    try same(a, b);
    for ([_]Msg{ .again, .{ .phase = 1 }, .again, .{ .token = 9007199254740992 }, .{ .token = std.math.maxInt(u64) }, .{ .phase = 2 }, .again, .{ .phase = 5 }, .{ .phase = 6 }, .{ .phase = 0 } }) |msg| try dispatch(a, b, msg);
    try dispatch(a, b, .{ .phase = 11 });
    try dispatch(a, b, .{ .phase = 0 });
    const before = a.h.null_platform.webview_navigate_count;
    const retained = a.app.web_pane_states[0];
    try dispatch(a, b, .{ .phase = 3 });
    try std.testing.expectEqual(before, a.h.null_platform.webview_navigate_count);
    try equal(retained.url_storage[0..retained.url_len], a.app.web_pane_states[0].url_storage[0..a.app.web_pane_states[0].url_len]);
    for ([_]Pair{ a, b }) |lane| lane.h.runtime.options.security.navigation.allowed_origins = &.{ "https://example.com", "https://denied.example" };
    try dispatch(a, b, .again);
    try std.testing.expectEqual(before + 1, a.h.null_platform.webview_navigate_count);
    try dispatch(a, b, .{ .phase = 4 });
    const navigations = a.h.null_platform.webview_navigate_count;
    try dispatch(a, b, .{ .extent = 180 });
    try std.testing.expectEqual(navigations, a.h.null_platform.webview_navigate_count);
    try std.testing.expectEqual(@as(usize, 0), a.app.web_pane_states[0].url_len);
    try dispatch(a, b, .{ .phase = 0 });
    try std.testing.expectEqual(navigations + 1, a.h.null_platform.webview_navigate_count);
    try dispatch(a, b, .{ .phase = 9 });
    try std.testing.expectEqual(navigations + 1, a.h.null_platform.webview_navigate_count);
    for ([_]Msg{ .{ .phase = 7 }, .{ .phase = 8 }, .again, .again, .{ .phase = 10 } }) |msg| try dispatch(a, b, msg);
    try std.testing.expectEqual(@as(usize, 4), a.app.web_pane_state_count);
    try std.testing.expectEqualStrings("missing-view", a.app.web_pane_states[1].label_storage[0..a.app.web_pane_states[1].label_len]);
    try std.testing.expectEqual(@as(usize, 64), a.app.web_pane_states[2].label_len);
    try std.testing.expectEqual(@as(usize, 64), a.app.web_pane_states[3].label_len);
}
