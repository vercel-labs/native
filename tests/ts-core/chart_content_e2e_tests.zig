//! Compiled chart preparation against the independent native builder.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("ts_persist_core");
const canvas = sdk.canvas;
const Ui = canvas.Ui(core.Msg);
const exact = @import("component_construction_e2e_tests.zig").exact;

fn compare(arena: std.mem.Allocator, options: Ui.ChartOptions, series: []const canvas.ChartSeries) !void {
    var reference = Ui.init(arena);
    var compiled = Ui.init(arena);
    compiled.chart_content_policy = core.nativeWindowPolicy;
    const expected = reference.chart(options, series);
    const actual = compiled.chart(options, series);
    core.rt.frameReset();
    try std.testing.expect(!compiled.failed);
    exact(expected, actual) catch |err| {
        std.debug.print("chart mismatch expected={s} actual={s} word={x}\n", .{ expected.widget.semantics.label, actual.widget.semantics.label, @as(u32, @bitCast(series[0].values[0])) });
        return err;
    };
    const a = try reference.finalize(expected);
    const b = try compiled.finalize(actual);
    try exact(a, b);
    var left: [1024]canvas.WidgetLayoutNode = undefined;
    var right: [1024]canvas.WidgetLayoutNode = undefined;
    try exact(try canvas.layoutWidgetTree(a.root, .init(0, 0, 640, 480), &left), try canvas.layoutWidgetTree(b.root, .init(0, 0, 640, 480), &right));
}

test "compiled chart content preserves exact summaries at every f32 exponent boundary and random words" {
    var random: u32 = 1;
    for (0..8192) |i| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const word: u32 = if (i < 4096) blk: {
            const field: u32 = @intCast(i / 16);
            const tails = [_]u32{ 0, 1, 2, 3, 0x3fffff, 0x400000, 0x7ffffe, 0x7fffff };
            break :blk (field << 23) | tails[i % 8] | if (i % 16 >= 8) @as(u32, 0x80000000) else 0;
        } else blk: {
            random = random *% 1664525 +% 1013904223;
            break :blk random;
        };
        const values = [_]f32{@bitCast(word)};
        try compare(arena.allocator(), .{}, &.{.{ .values = &values }});
    }
}

test "compiled chart content preserves complete band data source labels extrema ties and axis admission" {
    for ([_]usize{ 0, 1, 255, 256, 257, 511, 1024, 10000 }) |count| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const values = try arena.allocator().alloc(f32, count);
        for (values, 0..) |*value, i| value.* = switch (i % 9) {
            0 => @bitCast(@as(u32, 0x7fc00037)),
            1 => -0.0,
            2 => 0,
            3 => 2000,
            4 => -2000,
            5 => std.math.inf(f32),
            6 => -std.math.inf(f32),
            else => @floatFromInt(i % 7),
        };
        const lower = values[0 .. count / 2];
        const series = [_]canvas.ChartSeries{
            .{ .kind = .line, .values = values, .low = values, .fill = true, .color = .warning, .label = "trace\x00\xff" },
            .{ .kind = .bar, .values = lower, .label = "bars" },
            .{ .kind = .band, .values = values, .low = lower, .color = .info },
            .{ .kind = .band, .values = lower, .low = values, .label = "unequal" },
        };
        for ([_][]const u8{ "", "authored\x00\xff" }) |label| try compare(arena.allocator(), .{
            .key = .{ .int = 9_007_199_254_740_993 },
            .width = 480,
            .height = 180,
            .grow = 1,
            .padding = 6,
            .y_min = -3000,
            .y_max = 3000,
            .grid_lines = 3,
            .baseline = true,
            .stroke_width = 2.5,
            .x_labels = &.{ "first\x00\xff", "last" },
            .y_labels = true,
            .hover_details = true,
            .semantics = .{ .label = label },
        }, &series);
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try compare(arena.allocator(), .{}, &.{});
}

fn corrupt(_: []const u8, output: []u8) usize {
    @memset(output, 0);
    return output.len + 1;
}
test "compiled chart content fails closed on invalid result sizes without reference fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    ui.chart_content_policy = corrupt;
    _ = ui.chart(.{}, &.{.{ .values = &.{ 1, 2, 3 } }});
    try std.testing.expect(ui.failed);
}
