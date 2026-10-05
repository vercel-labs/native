const std = @import("std");
const native_sdk = @import("native_sdk");
const core = @import("shell_fixture_core");
const runtime_ns = native_sdk.runtime;
const geometry = native_sdk.geometry;

fn expectShellRectBits(expected: geometry.RectF, actual: geometry.RectF) !void {
    inline for (.{ "x", "y", "width", "height" }) |field| {
        const left = @field(expected, field);
        const right = @field(actual, field);
        if (std.math.isNan(left)) try std.testing.expect(std.math.isNan(right)) else try std.testing.expectEqual(@as(u32, @bitCast(left)), @as(u32, @bitCast(right)));
    }
}

fn expectShellPlan(bounds: geometry.RectF, views: []const native_sdk.ShellView) !void {
    const expected = runtime_ns.testing.nativeShellPlan(bounds, views);
    const actual = runtime_ns.testing.compiledShellPlan(core.nativeWindowPolicy, bounds, views);
    try std.testing.expectEqual(expected.invalid_parents, actual.invalid_parents);
    try std.testing.expectEqual(expected.count, actual.count);
    for (expected.items[0..expected.count], actual.items[0..actual.count]) |left, right| {
        try std.testing.expectEqual(left.index, right.index);
        try expectShellRectBits(left.frame, right.frame);
        try expectShellRectBits(left.absolute_frame, right.absolute_frame);
        try expectShellRectBits(left.platform_frame, right.platform_frame);
    }
}

test "compiled shell planner matches every native kind edge axis constraint and f32 boundary" {
    const samples = [_]f32{ -0.0, 0, 0.000001, 1.0000001, 31.999998, 32, 32.000004, 239.99998, 240, 240.00002, 16777216, std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32) };
    inline for (@typeInfo(native_sdk.app_manifest.ViewKind).@"enum".fields) |kind_field| {
        const kind: native_sdk.app_manifest.ViewKind = @enumFromInt(kind_field.value);
        for ([_]?native_sdk.app_manifest.ShellEdge{ null, .top, .right, .bottom, .left }) |edge| {
            for ([_]bool{ false, true }) |fill| {
                try expectShellPlan(geometry.RectF.init(0, 0, 800, 600), &.{.{ .label = "defaults", .kind = kind, .edge = edge, .fill = fill }});
                for (samples) |sample| {
                    const view = native_sdk.ShellView{ .label = "v", .kind = kind, .edge = edge, .fill = fill, .width = sample, .height = sample, .min_width = 0.25, .max_height = 320 };
                    try expectShellPlan(geometry.RectF.init(-0.0, 0.125, 800.00006, 599.99994), &.{view});
                }
            }
        }
    }
    for (0..256) |mask| {
        const view = native_sdk.ShellView{
            .label = "optionals",
            .kind = .spacer,
            .fill = true,
            .x = if (mask & 1 != 0) -0.125 else null,
            .y = if (mask & 2 != 0) 0.25 else null,
            .width = if (mask & 4 != 0) 24.000002 else null,
            .height = if (mask & 8 != 0) 12.000001 else null,
            .min_width = if (mask & 16 != 0) 30.000004 else null,
            .min_height = if (mask & 32 != 0) 20.000002 else null,
            .max_width = if (mask & 64 != 0) 28.000002 else null,
            .max_height = if (mask & 128 != 0) 18.000002 else null,
        };
        try expectShellPlan(geometry.RectF.init(0, 0, 32.000004, 24.000002), &.{view});
    }
    for ([_]native_sdk.app_manifest.ViewKind{ .stack, .split, .toolbar }) |kind| {
        for ([_]native_sdk.app_manifest.ShellAxis{ .row, .column }) |axis| {
            for (samples) |sample| {
                const views = [_]native_sdk.ShellView{
                    .{ .label = "child-a", .kind = .spacer, .parent = "parent", .width = sample },
                    .{ .label = "child-b", .kind = .button, .parent = "parent", .fill = true, .max_width = sample },
                    .{ .label = "main", .kind = .webview, .parent = "child-b", .width = 2, .height = 3 },
                    .{ .label = "parent", .kind = kind, .axis = axis, .x = sample, .y = 0.125, .width = 700.00006, .height = 80.00001 },
                    .{ .label = "child-c", .kind = .label, .parent = "parent", .x = sample, .y = sample },
                };
                try expectShellPlan(geometry.RectF.init(0, 0, 800, 600), &views);
            }
        }
    }
}

test "compiled shell plan preserves full declaration passes opaque parents and unresolved prefixes" {
    const bounds = geometry.RectF.init(0.0625, -0.125, 1000.00006, 700.00006);
    const views = [_]native_sdk.ShellView{
        .{ .label = "leaf", .kind = .label, .parent = "row", .width = 120.00001 },
        .{ .label = "row", .kind = .stack, .parent = "\xff\x00", .axis = .row, .height = 64.00001 },
        .{ .label = "main", .kind = .webview, .parent = "leaf", .x = 0.125, .y = 0.25, .fill = true },
        .{ .label = "fill", .kind = .webview, .fill = true },
        .{ .label = "top", .kind = .toolbar, .edge = .top },
        .{ .label = "\xff\x00", .kind = .sidebar, .edge = .left, .axis = .column },
        .{ .label = "status", .kind = .statusbar, .edge = .bottom },
        .{ .label = "right", .kind = .sidebar, .edge = .right, .max_width = 128.00002 },
    };
    try expectShellPlan(bounds, &views);
    try expectShellPlan(bounds, &.{});
    try expectShellPlan(bounds, &.{ views[0], views[4] });
    try expectShellPlan(bounds, &.{ .{ .label = "a", .kind = .stack, .parent = "b" }, .{ .label = "b", .kind = .split, .parent = "a" }, views[4] });
    try expectShellPlan(bounds, &.{
        .{ .label = "duplicate", .kind = .stack, .parent = "later", .width = 80, .height = 40 },
        .{ .label = "main", .kind = .webview, .parent = "duplicate", .x = 2, .width = 16, .height = 24 },
        .{ .label = "duplicate", .kind = .split, .x = 5, .width = 200, .height = 80 },
        .{ .label = "later", .kind = .stack, .x = 40, .width = 400, .height = 160 },
    });
    var maximum: [128]native_sdk.ShellView = undefined;
    var names: [128][3]u8 = undefined;
    for (&maximum, 0..) |*view, i| {
        names[i] = .{ 255, @intCast(i), 0 };
        view.* = .{ .label = &names[i], .kind = .stack, .x = 0.125, .width = 32.000004, .height = 64 };
        if (i > 0) view.parent = &names[i - 1];
    }
    try expectShellPlan(bounds, &maximum);
    std.mem.reverse(native_sdk.ShellView, &maximum);
    try expectShellPlan(bounds, &maximum);
}

test "compiled shell copied plans preserve borrowed core bytes and repeated collection" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const borrowed = core.rt.frameAlloc(u8, 9);
    @memcpy(borrowed, "keep\x00\xffabi");
    const views = [_]native_sdk.ShellView{.{ .label = "fill", .kind = .gpu_surface, .fill = true }};
    const first = runtime_ns.testing.compiledShellPlan(core.nativeWindowPolicy, geometry.RectF.init(0, 0, 640, 480), &views);
    try std.testing.expectEqualSlices(u8, "keep\x00\xffabi", borrowed);
    _ = runtime_ns.testing.compiledShellPlan(core.nativeWindowPolicy, geometry.RectF.init(0, 0, 320, 240), &views);
    try std.testing.expectEqualSlices(u8, "keep\x00\xffabi", borrowed);
    core.rt.frameReset();
    try expectShellRectBits(geometry.RectF.init(0, 0, 640, 480), first.items[0].platform_frame);
}

test "shell runtime consumes copied frame plans across startup resize and OS refusal" {
    const Fixture = struct {
        const views = [_]native_sdk.ShellView{
            .{ .label = "child", .kind = .button, .parent = "toolbar", .command = "refresh", .text = "Refresh" },
            .{ .label = "canvas", .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
            .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = 52.000004 },
            .{ .label = "sidebar", .kind = .sidebar, .edge = .left, .width = 128.00002 },
            .{ .label = "status", .kind = .statusbar, .edge = .bottom },
        };
        fn app(self: *@This(), compiled: bool) native_sdk.App {
            return .{ .context = self, .name = "shell-plan-runtime", .source = native_sdk.WebViewSource.html(""), .shell_layout_policy = if (compiled) core.nativeWindowPolicy else null };
        }
    };
    var expected_frames: [2][5]geometry.RectF = undefined;
    var expected_counts: [2][4]usize = undefined;
    for ([_]bool{ false, true }, 0..) |compiled, lane| {
        const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{ .id = 1, .size = geometry.SizeF.init(800, 600) });
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        var fixture: Fixture = .{};
        try harness.start(fixture.app(compiled));
        try std.testing.expect((harness.runtime.shell_layout_policy != null) == compiled);
        try harness.runtime.createShellViews(1, &Fixture.views, geometry.RectF.init(0, 0, 800, 600));
        try harness.runtime.dispatchPlatformEvent(fixture.app(compiled), .{ .surface_resized = .{ .id = 1, .size = geometry.SizeF.init(1000.00006, 700.00006) } });
        var buffer: [16]native_sdk.platform.ViewInfo = undefined;
        const views = harness.runtime.listViews(1, &buffer);
        for (Fixture.views, 0..) |source, i| {
            for (views) |view| if (std.mem.eql(u8, source.label, view.label)) {
                expected_frames[lane][i] = view.frame;
                try std.testing.expectEqualDeep(source.parent, view.parent);
                try std.testing.expectEqualStrings(source.command orelse "", view.command);
                try std.testing.expectEqualStrings(source.text orelse "", view.text);
                break;
            };
        }
        try harness.runtime.closeView(1, "child");
        try harness.runtime.relayoutShellViews(1); // missing native update remains a no-op
        const refusal = [_]native_sdk.ShellView{ .{ .label = "accepted", .kind = .label, .width = 32, .height = 24 }, .{ .label = "refused", .kind = .gpu_surface, .width = 32, .height = 24 } };
        harness.null_platform.gpu_surfaces = false;
        try std.testing.expectError(error.UnsupportedViewKind, harness.runtime.createShellViews(1, &refusal, geometry.RectF.init(0, 0, 640, 480)));
        expected_counts[lane] = .{ harness.runtime.view_count, harness.runtime.webview_count, harness.null_platform.view_count, harness.runtime.shell_layout_count };
        const remaining = harness.runtime.listViews(1, &buffer);
        for (remaining) |view| try std.testing.expect(!std.mem.eql(u8, view.label, "accepted") and !std.mem.eql(u8, view.label, "refused"));
        try harness.stop(fixture.app(compiled));
    }
    for (expected_frames[0], expected_frames[1]) |left, right| try expectShellRectBits(left, right);
    try std.testing.expectEqualDeep(expected_counts[0], expected_counts[1]);
}

test "shell runtime obeys compiler frame and ordering decisions without native derivation" {
    const Forced = struct {
        fn plan(request: []const u8, output: []u8) usize {
            const count = core.nativeWindowPolicy(request, output);
            const items = std.mem.readInt(u16, output[1..3], .little);
            for (0..items) |index| {
                std.mem.writeInt(u32, output[3 + index * 50 + 34 ..][0..4], @bitCast(@as(f32, 13.25)), .little);
            }
            if (items == 2) {
                const saved = output[3..53].*;
                @memcpy(output[3..53], output[53..103]);
                @memcpy(output[53..103], &saved);
            }
            return count;
        }
        fn app(self: *@This()) native_sdk.App {
            return .{ .context = self, .name = "forced-shell-plan", .shell_layout_policy = plan };
        }
    };
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var fixture: Forced = .{};
    try harness.start(fixture.app());
    try harness.runtime.createShellViews(1, &.{ .{ .label = "first", .kind = .label, .width = 32, .height = 24 }, .{ .label = "second", .kind = .label, .width = 48, .height = 24 } }, geometry.RectF.init(0, 0, 640, 480));
    try std.testing.expectEqualStrings("second", harness.null_platform.views[0].label);
    try std.testing.expectEqualStrings("first", harness.null_platform.views[1].label);
    try std.testing.expectEqual(@as(f32, 13.25), harness.null_platform.views[0].frame.x);
    try std.testing.expectEqual(@as(f32, 13.25), harness.null_platform.views[1].frame.x);
}

test "bounded shell planner timing covers the maximum reversed parent chain" {
    var views: [128]native_sdk.ShellView = undefined;
    var names: [128][2]u8 = undefined;
    for (&views, 0..) |*view, index| {
        names[index] = .{ 255, @intCast(index) };
        view.* = .{ .label = &names[index], .kind = .stack, .width = 240, .height = 80 };
        if (index > 0) view.parent = &names[index - 1];
    }
    std.mem.reverse(native_sdk.ShellView, &views);
    const bounds = geometry.RectF.init(0, 0, 800, 600);
    var samples: [2]i128 = undefined;
    var witness: usize = 0;
    for (0..2) |lane| {
        const begin = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
        for (0..100) |_| {
            const plan = if (lane == 0) runtime_ns.testing.nativeShellPlan(bounds, &views) else runtime_ns.testing.compiledShellPlan(core.nativeWindowPolicy, bounds, &views);
            witness += plan.count;
            core.rt.frameReset();
        }
        samples[lane] = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - begin;
    }
    try std.testing.expectEqual(@as(usize, 25600), witness);
    std.debug.print("shell 128-view reversed chain: native {d} ns/plan, compiled {d} ns/plan\n", .{ @divTrunc(samples[0], 100), @divTrunc(samples[1], 100) });
}
