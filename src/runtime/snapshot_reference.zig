//! Independent native reference for explicitly selected Zig-core apps.
const std = @import("std");
const p = @import("snapshot_policy.zig");
pub fn plan(mode: p.Mode, facts: p.Facts) p.Plan {
    const w = facts.words;
    const f = facts.floats;
    const flags = facts.flags;
    var result: p.Plan = .{};
    switch (mode) {
        .bounded => {
            if (flags == 1) result.words[0] = @min(w[0], w[1]);
            result.flags = @intFromBool(w[0] == 0 or w[1] == 0 or flags == 0);
        },
        .view => result.flags = @intFromBool(flags == 3 and w[0] == w[1]),
        .widget => {
            const selected = flags & 1 != 0 or (flags & 2 != 0 and !(f[0] < 0.5) and (w[6] == 12 or w[6] == 15 or w[6] == 16 or w[6] == 17 or w[6] == 18 or w[6] == 20));
            result.flags = @intFromBool(selected);
            if (flags & 8 != 0 or (flags & 16 != 0 and flags & 32 != 0 and w[0] == w[1])) result.flags |= 2;
            if (flags & 64 == 0) result.flags |= 4;
            if (flags & 128 != 0 or (w[0] != 0 and w[0] == w[2])) result.flags |= 8;
            if (flags & 256 != 0 or (w[0] != 0 and w[0] == w[3])) result.flags |= 16;
            if (flags & 1024 != 0 and w[4] < w[5]) {
                result.flags |= 32;
                result.words[0] = w[4];
            }
            result.floats[0..4].* = .{ f[1] + f[5], f[2] + f[6], f[3], f[4] };
        },
        .virtual_range => if (flags == 1) {
            result.flags = 1;
            for (0..4) |i| result.words[i] = @min(w[i], std.math.maxInt(u32));
            result.words[4] = @min(w[1] - w[0], std.math.maxInt(u32));
        },
        .uptime => if (w[0] > 0 and w[1] >= w[0]) {
            result.words[0] = w[1] - w[0];
        },
        .elapsed => result.words[0] = w[1] -| w[0],
        .presence => result.flags = @intCast(flags),
        .record => {
            result.words[0..3].* = .{ w[1], w[2], w[3] };
            if (flags == 1) {
                result.flags = 1;
                result.words[0] = @min(w[1] + 1, 128);
                result.words[1] = (w[2] + 1) % 128;
                result.words[2] = w[3] +% 1;
                result.words[3] = @min(w[0] / 1000, std.math.maxInt(u32));
            }
        },
        .stats => {
            const len: usize = @intCast(w[0]);
            result.words[0..2].* = .{ w[0], w[1] };
            if (len > 0) {
                var sorted: [128]u32 = undefined;
                @memcpy(sorted[0..len], facts.samples[0..len]);
                std.sort.pdq(u32, sorted[0..len], {}, std.sort.asc(u32));
                result.words[2..5].* = .{ sorted[@max((len * 50 + 99) / 100, 1) - 1], sorted[@max((len * 90 + 99) / 100, 1) - 1], sorted[len - 1] };
            }
        },
        .reset => {},
        .has_samples => for (facts.samples) |sample| {
            if (sample != 0) result.flags = 1;
        },
    }
    return result;
}
