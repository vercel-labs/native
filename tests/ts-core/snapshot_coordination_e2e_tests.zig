const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const p = sdk.runtime.testing.snapshot_policy;
const profile = sdk.runtime.testing.frame_profile;
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const words = [_]u64{ 0, 1, 4294967295, 4294967296, 9007199254740992, 9007199254740993, std.math.maxInt(u64) };
var modes: [11]usize = @splat(0);
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 27) modes[input[2]] += 1;
    return core.nativeEffectPolicy(input, output);
}
fn same(mode: p.Mode, facts: p.Facts) !void {
    const expected = p.plan(null, mode, facts);
    const actual = p.plan(observed, mode, facts);
    try exact(expected, actual);
    core.rt.frameReset();
    try exact(expected, actual);
}
test "compiled snapshot projection preserves exact capacities identities ranges and clocks" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for (words) |a| for (words) |b| {
        for (0..2) |flags| try same(.bounded, .{ .flags = @intCast(flags), .words = .{ a, b, 0, 0, 0, 0, 0, 0 } });
        for (0..4) |flags| try same(.view, .{ .flags = @intCast(flags), .words = .{ a, b, 0, 0, 0, 0, 0, 0 } });
        try same(.uptime, .{ .words = .{ a, b, 0, 0, 0, 0, 0, 0 } });
        try same(.elapsed, .{ .words = .{ a, b, 0, 0, 0, 0, 0, 0 } });
        if (a <= b) try same(.virtual_range, .{ .flags = 1, .words = .{ a, b, a, b, 0, 0, 0, 0 } });
    };
    try same(.virtual_range, .{});
    for (0..8) |flags| try same(.presence, .{ .flags = @intCast(flags) });
}
test "compiled snapshot widget derivation preserves complete f32 states roles and parent admission" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const floats = [_]f32{ -std.math.inf(f32), -16777216, -1, -0.0, 0, 0.49999997, 0.5, 1, 16777216, std.math.inf(f32), std.math.nan(f32) };
    for (std.enums.values(sdk.canvas.WidgetRole)) |role| for (floats) |value| for (0..2) |selected| {
        try same(.widget, .{ .flags = 2 | @as(u32, @intCast(selected)), .words = .{ 0, 0, 0, 0, 0, 0, @intFromEnum(role), 0 }, .floats = .{ value, 0, 0, -0.0, 10, 0, 0 } });
    };
    for (words) |id| for (words) |other| for ([_]u32{ 0, 8, 16, 32, 48, 64, 128, 256, 1024, 1529 }) |flags| {
        try same(.widget, .{ .flags = flags, .words = .{ id, other, other, other, id, other, 0, 0 } });
    };
    for (floats) |x| for (floats) |offset| try same(.widget, .{ .floats = .{ 0, x, offset, x, offset, offset, x } });
    const borrowed = core.rt.frameAlloc(u8, 19);
    @memset(borrowed, 0x5a);
    _ = p.plan(observed, .widget, .{});
    try std.testing.expect(std.mem.allEqual(u8, borrowed, 0x5a));
}
test "compiled snapshot profile decisions preserve saturation exact wrapping and every nearest rank" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    for (words) |count| for ([_]u64{ 0, 999, 1000, 1001, 4294967294999, 4294967295000, 4294967295001, std.math.maxInt(u64) }) |ns| {
        for ([_]u64{ 0, 1, 127, 128 }) |len| for ([_]u64{ 0, 1, 127 }) |head| {
            for (0..2) |flags| try same(.record, .{ .flags = @intCast(flags), .words = .{ ns, len, head, count, 0, 0, 0, 0 } });
        };
    };
    var samples: [128]u32 = undefined;
    for (0..129) |len| for (0..4) |pattern| {
        for (&samples, 0..) |*slot, i| slot.* = switch (pattern) {
            0 => @intCast(i),
            1 => @intCast(128 - i),
            2 => @intCast(i % 7),
            else => if (i % 2 == 0) 0 else std.math.maxInt(u32),
        };
        for (words) |total| try same(.stats, .{ .words = .{ len, total, 0, 0, 0, 0, 0, 0 }, .samples = samples[0..len] });
    };
    try same(.reset, .{});
    var lens: [12]u32 = @splat(0);
    try same(.has_samples, .{ .samples = &lens });
    for (&lens) |*len| {
        len.* = 128;
        try same(.has_samples, .{ .samples = &lens });
        len.* = 0;
    }
}
fn sameProfile(left: *const profile.FrameProfile, right: *const profile.FrameProfile) !void {
    try exact(left.enabled, right.enabled);
    try exact(left.lens, right.lens);
    try exact(left.heads, right.heads);
    try exact(left.totals, right.totals);
    try exact(left.samples_us, right.samples_us);
    try exact(left.hasSamples(), right.hasSamples());
    for (std.enums.values(profile.FrameProfileStage)) |stage| try exact(left.stats(stage), right.stats(stage));
    core.rt.frameReset();
}
test "compiled snapshot frame profile consumer preserves all rings reset and disabled storage" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var left = profile.FrameProfile{};
    var right = profile.FrameProfile{ .policy = observed };
    left.recordNs(.layout, 1000);
    right.recordNs(.layout, 1000);
    try sameProfile(&left, &right);
    left.enabled = true;
    right.enabled = true;
    for (std.enums.values(profile.FrameProfileStage)) |stage| {
        const index = @intFromEnum(stage);
        left.totals[index] = std.math.maxInt(u64);
        right.totals[index] = std.math.maxInt(u64);
        for (0..139) |i| {
            const ns = if (i == 0) std.math.maxInt(u64) else i * 1000;
            left.recordNs(stage, ns);
            right.recordNs(stage, ns);
        }
        try sameProfile(&left, &right);
    }
    left.reset();
    right.reset();
    try std.testing.expect(right.policy == observed and right.enabled);
    try sameProfile(&left, &right);
    left.enabled = false;
    right.enabled = false;
    left.recordNs(.present, 123456);
    right.recordNs(.present, 123456);
    try sameProfile(&left, &right);
    for (modes) |count| try std.testing.expect(count != 0);
}

test "compiled snapshot runtime projection preserves complete snapshots menus media and owned storage" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const Harness = sdk.TestHarness();
    const left = try Harness.create(std.testing.allocator, .{});
    defer left.destroy(std.testing.allocator);
    const right = try Harness.create(std.testing.allocator, .{});
    defer right.destroy(std.testing.allocator);
    var context: u8 = 0;
    const app = sdk.App{ .context = &context, .name = "snapshot", .source = sdk.platform.WebViewSource.html("") };
    const lanes = [_]*sdk.Runtime{ &left.runtime, &right.runtime };
    const menu = [_]sdk.canvas.WidgetContextMenuItem{ .{ .label = "Choose" }, .{ .label = "Disabled", .enabled = false }, .{ .label = "Separator", .separator = true } };
    for (lanes, 0..) |rt, i| {
        if (i == 1) {
            rt.snapshot_policy = observed;
            rt.frame_profile.policy = observed;
        }
        rt.started_timestamp_ns = 0;
    }
    var fallback = right.runtime.automationSnapshot("fallback");
    try std.testing.expect(fallback.serialization_policy == observed);
    fallback.serialization_policy = null;
    try exact(left.runtime.automationSnapshot("fallback"), fallback);
    for (lanes, 0..) |rt, i| {
        if (i == 0) left.null_platform.gpu_surfaces = true else right.null_platform.gpu_surfaces = true;
        var owned_app = app;
        if (i == 1) owned_app.snapshot_policy = observed;
        try rt.dispatchPlatformEvent(owned_app, .app_start);
        rt.started_timestamp_ns = 0;
        _ = try rt.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(17, 23, 320, 240) });
        const children = [_]sdk.canvas.Widget{
            .{ .id = 9007199254740993, .kind = .button, .frame = .init(10, 10, 100, 32), .text = "raw\x00\xff", .context_menu = &menu },
            .{ .id = std.math.maxInt(u64), .kind = .checkbox, .frame = .init(10, 52, 100, 32), .text = "Selected", .value = 1 },
            .{ .id = 3, .kind = .text_field, .frame = .init(10, 94, 100, 32), .text = "Draft", .placeholder = "Search" },
        };
        var nodes: [16]sdk.canvas.WidgetLayoutNode = undefined;
        const tree = try sdk.canvas.layoutWidgetTree(.{ .id = 4, .kind = .stack, .children = &children }, .init(0, 0, 320, 240), &nodes);
        _ = try rt.setCanvasWidgetLayout(1, "canvas", tree);
        rt.views[0].canvas_widget_focused_id = 3;
        rt.views[0].canvas_widget_hovered_id = 9007199254740993;
        rt.views[0].canvas_widget_pressed_id = std.math.maxInt(u64);
        rt.views[0].keyboard_active = true;
        rt.views[0].focused = true;
        rt.audio_active = true;
        rt.audio_key = std.math.maxInt(u64);
        rt.audio_position_ms = 9007199254740993;
        rt.video_active = true;
        rt.video_key = 9007199254740993;
        rt.video_duration_ms = std.math.maxInt(u64);
        rt.frame_profile.enabled = true;
        for (std.enums.values(profile.FrameProfileStage)) |stage| {
            rt.frame_profile.recordNs(stage, 1000);
            rt.frame_profile.recordNs(stage, std.math.maxInt(u64));
        }
        rt.status_items[1].active = true;
        rt.status_items[1].id = std.math.maxInt(u32);
        rt.status_items[1].title = "Tray";
        rt.status_items[1].item_count = 3;
        rt.status_items[1].items[0] = .{ .id = std.math.maxInt(u32), .label = "raw\x00\xff", .command = "choose", .detail = "Detail", .key = "K", .modifiers = .{ .command = true }, .enabled = false };
        rt.status_items[1].items[1] = .{ .separator = true };
        rt.status_items[1].items[2] = .{ .label = "Last", .command = "last" };
    }
    const expected = left.runtime.automationSnapshot("snapshot");
    var actual = right.runtime.automationSnapshot("snapshot");
    try std.testing.expect(actual.serialization_policy == observed);
    actual.serialization_policy = null;
    try exact(expected, actual);
    core.rt.frameReset();
    try exact(expected, actual);
    try std.testing.expect(actual.widgets.len != 0 and actual.trays.len == 1 and actual.audio != null and actual.video != null and actual.frame_profile != null);
    try std.testing.expect(actual.windows.ptr == &right.runtime.automation_windows);
    try std.testing.expect(actual.widgets.ptr == &right.runtime.automation_widgets);
    for (lanes) |rt| {
        rt.window_count = 0;
        rt.audio_active = false;
        rt.video_active = false;
        rt.frame_profile.enabled = false;
    }
    var final_fallback = right.runtime.automationSnapshot("fallback");
    final_fallback.serialization_policy = null;
    try exact(left.runtime.automationSnapshot("fallback"), final_fallback);
}
