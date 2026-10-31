const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const snapshot = sdk.automation.snapshot;
var modes: [22]usize = @splat(0);
fn observed(input: []const u8, output: []u8) usize {
    if (input[0] == 29) modes[input[2]] += 1;
    return core.nativeEffectPolicy(input, output);
}
fn serialize(input: snapshot.Input, writer: anytype, variant: u8) !void {
    switch (variant) {
        0 => try snapshot.writeText(input, writer),
        1 => try snapshot.writeA11yText(input, writer),
        2 => try snapshot.writeWindowsText(input, writer),
        else => unreachable,
    }
}
fn same(input: snapshot.Input) !void {
    var compiled = input;
    compiled.serialization_policy = observed;
    for (0..3) |variant| {
        var a = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer a.deinit();
        var b = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer b.deinit();
        try serialize(input, &a.writer, @intCast(variant));
        try serialize(compiled, &b.writer, @intCast(variant));
        try std.testing.expectEqualSlices(u8, a.written(), b.written());
        core.rt.frameReset();
        try std.testing.expectEqualSlices(u8, a.written(), b.written());
        var left: [7]u8 = undefined;
        var right: [7]u8 = undefined;
        var ah = std.Io.Writer.Hashing(std.hash.Wyhash).initHasher(std.hash.Wyhash.init(0), &left);
        var bh = std.Io.Writer.Hashing(std.hash.Wyhash).initHasher(std.hash.Wyhash.init(0), &right);
        try serialize(input, &ah.writer, @intCast(variant));
        try serialize(compiled, &bh.writer, @intCast(variant));
        try ah.writer.flush();
        try bh.writer.flush();
        try std.testing.expectEqual(ah.hasher.final(), bh.hasher.final());
        core.rt.frameReset();
    }
}

test "compiled snapshot serialization preserves complete catalogs telemetry semantics and media" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    var raw: [256]u8 = undefined;
    for (&raw, 0..) |*byte, i| byte.* = @intCast(i);
    const maximum = std.math.maxInt(u64);
    const windows = [_]snapshot.Window{ .{ .id = std.math.maxInt(u32), .title = &raw, .bounds = .init(-0.0, -12.5, 700.125, 400), .focused = false }, .{ .title = "second", .bounds = .{} } };
    const views = [_]sdk.platform.ViewInfo{
        .{ .kind = .gpu_surface, .label = &raw, .role = &raw, .accessibility_label = &raw, .text = &raw, .layer = -123, .gpu_sample_color = 0xfedcba98, .gpu_frame_index = maximum, .gpu_timestamp_ns = 9007199254740993, .canvas_frame_dirty_bounds = .init(-0.0, 1, 2, 3), .canvas_frame_profile_dirty_ratio = 0.33333334, .gpu_present_fallback_command_kind = &raw },
        .{ .kind = .gpu_surface, .label = "null-dirty", .text = "fallback" },
        .{ .kind = .webview, .label = "web", .url = &raw },
        .{ .kind = .gpu_surface, .label = "label-name" },
    };
    const context = [_]snapshot.WidgetContextMenuItem{ .{ .label = &raw, .enabled = false }, .{ .separator = true }, .{ .label = "last" } };
    const widgets = [_]snapshot.Widget{
        .{ .view_label = &raw, .id = maximum, .parent_id = maximum - 1, .name = &raw, .role = &raw, .value = -0.0, .text_value = &raw, .placeholder = &raw, .grid_row_index = 0, .grid_column_index = 3, .grid_row_count = 4, .grid_column_count = 5, .list = .{ .present = true, .item_index = 7, .item_count = 9 }, .scroll = .{ .present = true, .offset = -0.0, .viewport_extent = 0.125, .content_extent = std.math.inf(f32) }, .virtual_range = .{ .present = true, .start_index = 0, .end_index = 10, .first_visible_index = 1, .last_visible_index = 9, .rendered_count = 10 }, .focused = true, .enabled = false, .hovered = true, .pressed = true, .selected = true, .expanded = false, .required = true, .read_only = true, .invalid = true, .actions = .{ .focus = true, .press = true, .toggle = true, .increment = true, .decrement = true, .set_text = true, .set_selection = true, .select = true, .drag = true, .drop_files = true, .dismiss = true }, .text_selection = .{ .start = 0, .end = 9007199254740993 }, .text_composition = .{ .start = 1, .end = std.math.maxInt(usize) }, .context_menu = &context },
        .{ .id = 0, .parent_id = 0, .grid_column_count = 0, .expanded = true },
        .{},
    };
    const commands = [_]sdk.app_manifest.Command{ .{ .id = &raw, .title = &raw, .enabled = false, .checked = true }, .{ .id = "", .title = "" } };
    const menus = [_]sdk.platform.Menu{ .{ .title = &raw, .items = &.{ .{ .label = &raw, .command = &raw, .key = &raw, .enabled = false, .checked = true, .modifiers = .{ .primary = true, .command = true, .control = true, .option = true, .shift = true } }, .{ .separator = true } } }, .{ .title = "empty" } };
    const segments = sdk.platform.TraySegmentedRow{ .options = &.{ .{ .id = 0, .label = &raw, .command = &raw, .enabled = false, .selected = true }, .{ .id = 1, .label = "", .command = "" } } };
    const metric = sdk.platform.TrayMetricRow{ .primary_text = &raw, .secondary_text = &raw, .accessibility_label = &raw };
    const chart = sdk.platform.TrayChartRow{ .values = &.{ -0.0, std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), 0.125 }, .min_value = -12.5, .max_value = 9, .leading_caption = &raw, .trailing_summary = &raw, .accessibility_label = &raw };
    const trays = [_]snapshot.Tray{ .{ .id = std.math.maxInt(u32), .title = &raw, .visible = false, .items = &.{ .{ .separator = true, .segmented = segments, .metric = metric, .chart = chart }, .{ .segmented = segments, .metric = metric, .chart = chart }, .{ .metric = metric, .chart = chart }, .{ .chart = chart }, .{ .label = &raw, .command = &raw, .detail = &raw, .role = .hero, .key = &raw, .modifiers = .{ .primary = true, .command = true, .control = true, .option = true, .shift = true }, .enabled = false }, .{ .segmented = .{} }, .{ .chart = .{} } } }, .{ .title = "empty" } };
    var errors = [_]snapshot.DispatchError{ .{ .timestamp_ns = maximum, .error_name = &raw }, .{ .error_name = "without-detail" } };
    for (&errors) |*e| e.setEvent(&raw);
    errors[0].setDetail(&raw);
    try same(.{ .windows = &windows, .views = &views, .widgets = &widgets, .commands = &commands, .menus = &menus, .trays = &trays, .errors = &errors, .diagnostics = .{ .frame_index = maximum, .command_count = std.math.maxInt(usize), .runtime_uptime_ns = maximum, .publisher_pid = std.math.maxInt(u32), .dispatch_error_count = maximum, .dropped_trace_records = maximum, .markup_watch_armed = true }, .frame_profile = .{ .stages = &.{ .{ .name = &raw, .p50_us = maximum, .p90_us = maximum, .max_us = maximum, .count = maximum }, .{} } }, .audio = .{ .key = maximum, .playing = true, .buffering = true, .source = &raw, .position_ms = maximum, .duration_ms = maximum, .spectrum_events = maximum, .spectrum_bands = &raw }, .video = .{ .key = maximum, .surface = maximum, .playing = true, .buffering = true, .source = &raw, .position_ms = maximum, .duration_ms = maximum, .width = maximum, .height = maximum, .looping = true, .muted = true }, .source = sdk.platform.WebViewSource.html(&raw), .widget_node_budget = std.math.maxInt(usize), .widget_semantics_budget = 31, .widget_context_menu_item_budget = 32, .text_layout_plan_budget = 33, .text_layout_line_budget = 34 });
    for (modes[0..17]) |count| try std.testing.expect(count != 0);
    try std.testing.expect(modes[20] != 0 and modes[21] != 0);
}

test "compiled snapshot serialization preserves every optional numeric branch and transport state" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const values = [_]f32{ -std.math.inf(f32), -16777216, -1, -0.0, 0, std.math.floatMin(f32), 0.49999997, 1, std.math.floatMax(f32), std.math.inf(f32), std.math.nan(f32) };
    for (values) |value| for (0..16) |bits| {
        const widgets = [_]snapshot.Widget{.{ .value = value, .grid_row_index = if (bits & 1 != 0) 0 else null, .grid_column_index = if (bits & 2 != 0) 1 else null, .grid_row_count = if (bits & 4 != 0) 2 else null, .grid_column_count = if (bits & 8 != 0) 3 else null, .expanded = if (bits & 1 != 0) bits & 2 != 0 else null }};
        try same(.{ .windows = &.{}, .widgets = &widgets, .audio = .{ .playing = bits & 1 != 0, .buffering = bits & 2 != 0, .spectrum_events = if (bits & 4 != 0) 1 else 0, .spectrum_bands = &.{ 0, 255 } }, .video = .{ .playing = bits & 1 != 0, .buffering = bits & 2 != 0, .looping = bits & 4 != 0, .muted = bits & 8 != 0 } });
    };
    try same(.{ .windows = &.{}, .frame_profile = .{} });
    const borrowed = core.rt.frameAlloc(u8, 17);
    @memset(borrowed, 0x5a);
    var output: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    try snapshot.writeA11yText(.{ .windows = &.{}, .serialization_policy = observed }, &writer);
    try std.testing.expect(std.mem.allEqual(u8, borrowed, 0x5a));
}

test "compiled snapshot serialization handles huge borrowed catalogs with bounded chunks" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const raw = try std.testing.allocator.alloc(u8, 65539);
    defer std.testing.allocator.free(raw);
    for (raw, 0..) |*byte, i| byte.* = @truncate(i);
    const widgets = [_]snapshot.Widget{.{ .name = raw, .text_value = raw, .context_menu = &.{.{ .label = raw }} }};
    const commands = [_]sdk.app_manifest.Command{.{ .id = raw, .title = raw }};
    try same(.{ .windows = &.{.{ .title = raw, .bounds = .{} }}, .widgets = &widgets, .commands = &commands, .audio = .{ .spectrum_events = 1, .spectrum_bands = raw } });
    try std.testing.expectEqual(@as(u8, 0), raw[0]);
    try std.testing.expectEqual(@as(u8, 2), raw[65538]);
}

test "compiled snapshot serialization preserves complete prefixes at every fixed writer failure" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const input = snapshot.Input{ .windows = &.{.{ .title = "raw\x00\xff\n", .bounds = .init(-0.0, -10.25, 12, 13) }}, .commands = &.{.{ .id = "quote\"\\\n\r\t\x00\x7f\xff", .title = "title" }}, .widgets = &.{.{ .value = -0.0, .actions = .{ .focus = true }, .context_menu = &.{ .{ .separator = true }, .{ .label = "disabled", .enabled = false } } }} };
    var compiled = input;
    compiled.serialization_policy = observed;
    for (0..3) |variant| {
        var total = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer total.deinit();
        try serialize(input, &total.writer, @intCast(variant));
        var a: [2048]u8 = undefined;
        var b: [2048]u8 = undefined;
        for (0..total.written().len + 1) |capacity| {
            var left = std.Io.Writer.fixed(a[0..capacity]);
            var right = std.Io.Writer.fixed(b[0..capacity]);
            const x = serialize(input, &left, @intCast(variant));
            const y = serialize(compiled, &right, @intCast(variant));
            if (x) |_| {
                try y;
            } else |err| try std.testing.expectError(err, y);
            try std.testing.expectEqualSlices(u8, left.buffered(), right.buffered());
            core.rt.frameReset();
        }
    }
}

test "compiled snapshot serialization runtime consumers preserve session fingerprints and published windows" {
    _ = core.initialModel();
    defer core.rt.frameReset();
    const Harness = sdk.TestHarness();
    const a = try Harness.create(std.testing.allocator, .{});
    defer a.destroy(std.testing.allocator);
    const b = try Harness.create(std.testing.allocator, .{});
    defer b.destroy(std.testing.allocator);
    b.runtime.snapshot_policy = observed;
    try std.testing.expectEqual(a.runtime.sessionStateFingerprint(), b.runtime.sessionStateFingerprint());
    const input = b.runtime.automationSnapshot("Test");
    try std.testing.expect(input.serialization_policy == observed);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [256]u8 = undefined;
    const directory = try std.fmt.bufPrint(&path, ".zig-cache/tmp/{s}/published", .{tmp.sub_path});
    try sdk.automation.Server.init(std.testing.io, directory, "Test").publish(input);
    const names = [_][]const u8{ "snapshot.txt", "accessibility.txt", "windows.txt" };
    for (names, 0..) |name, variant| {
        var expected = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer expected.deinit();
        var reference = input;
        reference.serialization_policy = null;
        try serialize(reference, &expected.writer, @intCast(variant));
        var file_path: [512]u8 = undefined;
        const published = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.fmt.bufPrint(&file_path, "{s}/{s}", .{ directory, name }), std.testing.allocator, .limited(1048576));
        defer std.testing.allocator.free(published);
        try std.testing.expectEqualSlices(u8, expected.written(), published);
    }
}
