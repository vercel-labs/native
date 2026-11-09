const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const policy = sdk.runtime.testing.shell_admission_policy;
const reference = sdk.runtime.testing.reference_descriptor_validation;
var modes: [12]usize = @splat(0);
var comparisons: usize = 0;
fn compiled(input: []const u8, output: []u8) usize {
    if (input[0] == 85) modes[input[2]] += 1;
    return core.nativeWindowPolicy(input, output);
}
fn failure(result: anyerror!void) ?anyerror {
    result catch |err| return err;
    return null;
}
fn scene(value: sdk.ShellConfig, compatibility: []const sdk.app_manifest.Window) !void {
    try std.testing.expectEqual(failure(sdk.app_manifest.validateShell(value, compatibility)), failure(policy.scene(compiled, value, compatibility)));
    comparisons += 1;
}
fn view(value: sdk.ShellView) !void {
    try scene(.{ .windows = &.{.{ .views = &.{value} }} }, &.{});
}
test "compiled shell admission preserves complete name command and streamed byte boundaries" {
    var bytes: [1025]u8 = @splat('x');
    for ([_]usize{ 0, 1, 2, 4, 63, 64, 65, 127, 128, 129, 255, 256, 257, 511, 512, 1024, 1025 }) |size| {
        const value = bytes[0..size];
        try view(.{ .label = value, .kind = .button });
        try view(.{ .label = "button", .kind = .button, .role = value });
        try view(.{ .label = "button", .kind = .button, .accessibility_label = value });
        try view(.{ .label = "button", .kind = .button, .text = value });
        try view(.{ .label = "button", .kind = .button, .command = value });
        try scene(.{ .windows = &.{.{ .label = value, .title = value }} }, &.{});
        if (size > 0) {
            bytes[size - 1] = 0;
            try view(.{ .label = "button", .kind = .button, .text = value });
            try view(.{ .label = "button", .kind = .button, .accessibility_label = value });
            bytes[size - 1] = 'x';
        }
    }
    for ([_][]const u8{ "", ".", "..", "...", "a/b", "a\\b", "a\x00b", "\n/", "/\n", "\n", "\t", "white space", "\xff\xfe" }) |value| {
        try view(.{ .label = value, .kind = .button });
        try view(.{ .label = "button", .kind = .button, .command = value });
    }
}
test "compiled shell admission preserves full URL hosts permissive HTTP paths and raw tails" {
    for ([_][]const u8{ "", "http://", "http://a", "http:///a", "https://a/ \x00\t", "http://a b/x", "http://[::1]:port/x", "zero://app/a", "zero://", "zero://a b", "file:///a", "file://a\x00", "HTTPS://a", "mailto:a" }) |value| {
        try view(.{ .label = "child", .kind = .webview, .url = value });
        try view(.{ .label = "button", .kind = .button, .url = value });
    }
    var value: [1030]u8 = @splat('x');
    value[0..7].* = "http://".*;
    for ([_]usize{ 255, 256, 257, 511, 512, 1025 }) |offset| {
        value[offset] = '/';
        value[offset + 1] = 0;
        try view(.{ .label = "child", .kind = .webview, .url = &value });
        value[offset] = 'x';
        try view(.{ .label = "child", .kind = .webview, .url = &value });
        value[offset + 1] = 'x';
    }
}
test "compiled shell admission preserves dimension domains optional bounds and GPU declaration presence" {
    const values = [_]f32{ -std.math.inf(f32), -1, -0.0, 0, 0.125, 1, 100, std.math.inf(f32), std.math.nan(f32) };
    for (values) |a| for (values) |b| {
        try view(.{ .label = "button", .kind = .button, .width = a, .height = b });
        try view(.{ .label = "button", .kind = .button, .min_width = a, .max_width = b });
        try view(.{ .label = "button", .kind = .button, .min_height = a, .max_height = b });
        try scene(.{ .windows = &.{.{ .width = a, .height = b }} }, &.{});
    };
    for ([_]sdk.app_manifest.ViewKind{ .button, .gpu_surface, .webview }) |kind| {
        try view(.{ .label = "view", .kind = kind });
        try view(.{ .label = "view", .kind = kind, .gpu_backend = .none });
        try view(.{ .label = "view", .kind = kind, .gpu_vsync = false });
        try view(.{ .label = "view", .kind = kind, .url = "zero://app/a", .gpu_vsync = false });
    }
}
test "compiled shell admission preserves forward parent graphs full capacity and ordered errors" {
    const labels = [_][]const u8{ "a", "b", "c", "d" };
    var views: [4]sdk.ShellView = undefined;
    for (0..625) |shape| {
        var choices = shape;
        for (&views, labels) |*v, label| {
            const parent = choices % 5;
            choices /= 5;
            v.* = .{ .label = label, .kind = .button, .parent = if (parent == 4) null else labels[parent] };
        }
        try scene(.{ .windows = &.{.{ .views = &views }} }, &.{});
    }
    var label_storage: [129][8]u8 = undefined;
    var descriptors: [129]sdk.ShellView = undefined;
    for (&descriptors, &label_storage, 0..) |*v, *storage, i| v.* = .{ .label = try std.fmt.bufPrint(storage, "v{d}", .{i}), .kind = .button };
    for (0..127) |i| descriptors[i].parent = descriptors[i + 1].label;
    try scene(.{ .windows = &.{.{ .views = descriptors[0..128] }} }, &.{});
    descriptors[127].parent = descriptors[0].label;
    try scene(.{ .windows = &.{.{ .views = descriptors[0..128] }} }, &.{});
    try scene(.{ .windows = &.{.{ .views = &descriptors }} }, &.{});
    try scene(.{ .windows = &.{.{ .views = &.{ .{ .label = "a", .kind = .button, .parent = "b" }, .{ .label = "b", .kind = .button, .parent = "a", .role = "bad/role" } } }} }, &.{});
    try scene(.{ .windows = &.{.{ .views = &.{ .{ .label = "a", .kind = .button }, .{ .label = "a", .kind = .button, .parent = "missing", .width = -1 } } }} }, &.{});
}
test "compiled shell admission preserves window collision and chrome error precedence" {
    var windows: [17]sdk.ShellWindow = @splat(.{});
    try scene(.{ .windows = &windows }, &.{});
    try scene(.{ .windows = &.{.{ .label = "same" }} }, &.{.{ .label = "same" }});
    try scene(.{ .windows = &.{ .{ .label = "same" }, .{ .label = "same", .width = -1 } } }, &.{});
    for ([_][]const u8{ "", ".", "..", "valid", "bad/id", "bad\n", "\n/" }) |id| for ([_][]const u8{ "", "title", "\t", "\x7f", "\xff" }) |label| for ([_][]const u8{ "", "play", "app:my_icon-1", "app:", "bad/icon", "UPPER" }) |icon| {
        const tab = sdk.ShellTab{ .id = id, .label = label, .icon = icon };
        try scene(.{ .chrome = .{ .tabs = &.{ tab, tab } } }, &.{});
        try scene(.{ .chrome = .{ .primary_action = .{ .id = id, .label = label, .icon = icon } } }, &.{});
    };
    const tabs = [_]sdk.ShellTab{ .{ .id = "a", .label = "A" }, .{ .id = "b", .label = "B" } };
    try scene(.{ .chrome = .{ .tabs = tabs[0..1] } }, &.{});
    try scene(.{ .chrome = .{ .tabs = &tabs, .primary_action = .{ .id = "a", .label = "A" } } }, &.{});
}
test "compiled shell admission preserves all runtime descriptor frame label and GPU rules" {
    var text: [1025]u8 = @splat('x');
    for ([_]usize{ 0, 1, 4, 64, 65, 128, 129, 256, 257, 1024, 1025 }) |count| {
        const value = text[0..count];
        for ([_]u32{ 0, 1, 2 }) |category| try std.testing.expectEqual(failure(policy.label(null, category, value)), failure(policy.label(compiled, category, value)));
        for (0..7) |member| {
            var options = sdk.platform.ViewOptions{ .label = "view", .kind = .button };
            switch (member) {
                0 => options.label = value,
                1 => options.parent = value,
                2 => options.role = value,
                3 => options.accessibility_label = value,
                4 => options.text = value,
                5 => options.command = value,
                6 => options.url = value,
                else => unreachable,
            }
            try std.testing.expectEqual(failure(reference.validateViewOptions(options)), failure(policy.runtimeView(compiled, options)));
        }
    }
    for ([_][]const u8{ "main", "", ".", "..", "\n", "a/b", "\n/", "\xff" }) |value| {
        for ([_]u32{ 0, 1, 2 }) |category| try std.testing.expectEqual(failure(policy.label(null, category, value)), failure(policy.label(compiled, category, value)));
        const options = sdk.platform.ViewOptions{ .label = "view", .kind = .button, .command = value };
        try std.testing.expectEqual(failure(reference.validateViewOptions(options)), failure(policy.runtimeView(compiled, options)));
    }
    const values = [_]f32{ -std.math.inf(f32), -1, -0.0, 0, 0.125, 1, std.math.inf(f32), std.math.nan(f32) };
    for (values) |value| for (0..4) |member| for ([_]u32{ 0, 1, 2 }) |category| {
        var numbers = [_]f32{ 0, 0, 10, 10 };
        numbers[member] = value;
        const rect = sdk.geometry.RectF.init(numbers[0], numbers[1], numbers[2], numbers[3]);
        try std.testing.expectEqual(failure(policy.frame(null, category, rect)), failure(policy.frame(compiled, category, rect)));
    };
    for ([_]sdk.platform.GpuSurfaceBackend{ .none, .metal, .direct2d, .software }) |backend| for ([_]sdk.platform.GpuSurfaceAlphaMode{ .none, .@"opaque", .premultiplied }) |alpha| for ([_]bool{ false, true }) |vsync| {
        const options = sdk.platform.ViewOptions{ .label = "gpu", .kind = .gpu_surface, .gpu_surface = .{ .backend = backend, .alpha_mode = alpha, .vsync = vsync } };
        try std.testing.expectEqual(failure(reference.validateViewOptions(options)), failure(policy.runtimeView(compiled, options)));
    };
}
test "compiled shell admission preserves complete runtime state across refusal patch and healthy retry" {
    const Harness = sdk.TestHarness();
    const a = try Harness.create(std.testing.allocator, .{});
    defer a.destroy(std.testing.allocator);
    const b = try Harness.create(std.testing.allocator, .{});
    defer b.destroy(std.testing.allocator);
    for ([_]*Harness{ a, b }, 0..) |h, i| {
        try h.start(.{ .context = h, .name = "shell-admission", .source = sdk.platform.WebViewSource.html("") });
        h.runtime.started_timestamp_ns = 0;
        if (i == 1) h.runtime.shell_admission_policy = compiled;
    }
    for ([_][]const u8{ "", "good", "\xff", "main" }) |label| {
        const options = sdk.platform.ViewOptions{ .label = label, .kind = .button, .frame = .init(0, 0, 100, 50), .command = "\n/" };
        try std.testing.expectEqual(failure(create(&a.runtime, options)), failure(create(&b.runtime, options)));
        try exact(a.runtime.automationSnapshot("shell-admission"), b.runtime.automationSnapshot("shell-admission"));
    }
    const options = sdk.platform.ViewOptions{ .label = "good", .kind = .button, .frame = .init(0, 0, 100, 50), .command = "click" };
    try std.testing.expectEqual(failure(create(&a.runtime, options)), failure(create(&b.runtime, options)));
    var too_long: [1025]u8 = @splat('x');
    for ([_]sdk.platform.ViewPatch{ .{ .text = &too_long }, .{ .role = too_long[0..65], .text = &too_long }, .{ .frame = .init(-1, 0, 10, 10), .command = "bad\n" }, .{ .command = "bad\n" }, .{ .text = "healthy", .command = "" }, .{ .frame = .init(2, 3, 120, 60) } }) |patch| {
        try std.testing.expectEqual(failure(update(&a.runtime, patch)), failure(update(&b.runtime, patch)));
        try exact(a.runtime.automationSnapshot("shell-admission"), b.runtime.automationSnapshot("shell-admission"));
        try exact(a.null_platform.views[0..a.null_platform.view_count], b.null_platform.views[0..b.null_platform.view_count]);
    }
}
fn create(runtime: *sdk.Runtime, options: sdk.platform.ViewOptions) !void {
    _ = try runtime.createView(options);
}
fn update(runtime: *sdk.Runtime, patch: sdk.platform.ViewPatch) !void {
    _ = try runtime.updateView(1, "good", patch);
}
test "compiled shell admission exercises every mode and complete scene reference corpus" {
    try std.testing.expect(comparisons > 1400);
    for (modes) |count| try std.testing.expect(count > 0);
}
