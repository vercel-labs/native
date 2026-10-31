//! Independent journal reference for explicitly selected Zig-core apps.
const std = @import("std");
const p = @import("journal_policy.zig");
pub fn plan(stage: p.Stage, facts: p.Facts) p.Plan {
    var result: p.Plan = .{ .pos = facts.b, .counts = facts.counts };
    switch (stage) {
        .init => {
            if (facts.a < 16 or !std.mem.eql(u8, facts.sample[0..8], "NSDKSJNL")) result.action = .bad_magic else if (std.mem.readInt(u64, facts.sample[8..16], .little) != facts.fingerprint) result.action = .format_mismatch else result.pos = 16;
        },
        .preamble => {
            result.preamble[0..8].* = "NSDKSJNL".*;
            std.mem.writeInt(u64, result.preamble[8..16], facts.fingerprint, .little);
        },
        .frame => {
            if (facts.a > facts.limit or facts.b < 5 + facts.a) result.action = .over_budget else {
                result.frame[0] = facts.kind;
                std.mem.writeInt(u32, result.frame[1..5], @intCast(facts.a), .little);
            }
        },
        .next => {
            if (facts.ended) {
                result.action = if (facts.b != facts.a) .corrupt else .done;
                return result;
            }
            if (facts.a - facts.b < 5) {
                result.action = .truncated;
                return result;
            }
            const kind = facts.sample[0];
            if (kind < 1 or kind > 7) {
                result.action = .corrupt;
                return result;
            }
            const length = std.mem.readInt(u32, facts.sample[1..5], .little);
            if (length > facts.limit) {
                result.action = .over_budget;
                return result;
            }
            if (facts.a - facts.b - 5 < length) {
                result.action = .truncated;
                return result;
            }
            result.kind = kind;
            result.length = length;
            result.pos += 5 + @as(u64, length);
            if (!facts.header and kind != 1) result.action = .missing_header else if (facts.header and kind == 1) result.action = .corrupt else if (kind >= 2 and kind <= 5) result.counts[kind - 2] += 1 else if (kind == 7) result.counts[4] += 1;
        },
        .seal => for (facts.counts, facts.sealed) |count, sealed| {
            if (count != sealed) result.action = .count_mismatch;
        },
    }
    return result;
}
