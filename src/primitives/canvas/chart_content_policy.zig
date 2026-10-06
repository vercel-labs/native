//! Chart preparation packets. Native owns series/sample storage and copies
//! selected source words and summary bytes before the compiled arena resets.
const std = @import("std");
const chart = @import("chart.zig");
pub const Policy = *const fn ([]const u8, []u8) usize;
pub const Prepared = struct { series: []const chart.ChartSeries, summary: []const u8, downsampled: bool };

pub fn prepare(arena: std.mem.Allocator, policy: Policy, source: []const chart.ChartSeries) !Prepared {
    if (source.len > std.math.maxInt(u32)) return error.InvalidChartSource;
    var input_len: usize = 8;
    var output_len: usize = 14;
    for (source) |series| {
        for ([_]usize{ series.label.len, series.values.len, series.low.len }) |len| if (len > std.math.maxInt(u32)) return error.InvalidChartSource;
        input_len = try std.math.add(usize, input_len, try std.math.add(usize, 16 + series.label.len, try std.math.mul(usize, 4, try std.math.add(usize, series.values.len, series.low.len))));
        output_len = try std.math.add(usize, output_len, try std.math.add(usize, 96 + series.label.len, 4 * (chart.downsampledChartLen(series.values.len) + if (series.kind == .band) chart.downsampledChartLen(series.low.len) else 0)));
    }
    const request = try arena.alloc(u8, input_len);
    const output = try arena.alloc(u8, output_len);
    @memset(request, 0);
    request[0] = 21;
    std.mem.writeInt(u32, request[4..8], @intCast(source.len), .little);
    var at: usize = 8;
    for (source) |series| {
        request[at] = switch (series.kind) {
            .line => 0,
            .bar => 1,
            .band => 2,
        };
        std.mem.writeInt(u32, request[at + 4 ..][0..4], @intCast(series.label.len), .little);
        std.mem.writeInt(u32, request[at + 8 ..][0..4], @intCast(series.values.len), .little);
        std.mem.writeInt(u32, request[at + 12 ..][0..4], @intCast(series.low.len), .little);
        at += 16;
        @memcpy(request[at..][0..series.label.len], series.label);
        at += series.label.len;
        for (series.values) |value| {
            std.mem.writeInt(u32, request[at..][0..4], @bitCast(value), .little);
            at += 4;
        }
        for (series.low) |value| {
            std.mem.writeInt(u32, request[at..][0..4], @bitCast(value), .little);
            at += 4;
        }
    }
    const length = policy(request, output);
    if (length < 8 or length > output.len or output[0] > 1 or output[1] != 0 or output[2] != 0 or output[3] != 0) return error.InvalidChartPlan;
    const summary_len = std.mem.readInt(u32, output[4..8], .little);
    if (summary_len > length - 8) return error.InvalidChartPlan;
    const summary = output[8..][0..summary_len];
    at = 8 + summary_len;
    const stored = try arena.alloc(chart.ChartSeries, source.len);
    for (source, stored) |series, *entry| {
        if (at > length or length - at < 8) return error.InvalidChartPlan;
        const count = std.mem.readInt(u32, output[at..][0..4], .little);
        const low_count = std.mem.readInt(u32, output[at + 4 ..][0..4], .little);
        at += 8;
        if (count != chart.downsampledChartLen(series.values.len) or low_count != (if (series.kind == .band) chart.downsampledChartLen(series.low.len) else 0)) return error.InvalidChartPlan;
        entry.* = series;
        entry.values = try selected(arena, output[0..length], &at, series.values, count);
        entry.low = try selected(arena, output[0..length], &at, series.low, low_count);
    }
    if (at != length) return error.InvalidChartPlan;
    return .{ .series = stored, .summary = summary, .downsampled = output[0] == 1 };
}

fn selected(arena: std.mem.Allocator, output: []const u8, at: *usize, source: []const f32, count: u32) ![]const f32 {
    if (count > (output.len - at.*) / 4) return error.InvalidChartPlan;
    const values = try arena.alloc(f32, count);
    for (values) |*value| {
        const index = std.mem.readInt(u32, output[at.*..][0..4], .little);
        at.* += 4;
        if (index >= source.len) return error.InvalidChartPlan;
        value.* = source[index];
    }
    return values;
}
