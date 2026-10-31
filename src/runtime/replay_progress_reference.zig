//! Independent portable reference for explicitly selected Zig-core apps.
const std = @import("std");
const p = @import("replay_progress_policy.zig");
pub fn plan(stage: p.Stage, facts: p.Facts) p.Plan {
    var result: p.Plan = .{};
    switch (stage) {
        .count => result.counter = facts.a + 1,
        .compare => {
            result.counter = facts.a + 1;
            result.mismatch_count = facts.b;
            if (facts.c != facts.d) {
                result.mismatch = true;
                if (facts.b < 16) result.mismatch_slot = @intCast(facts.b);
                result.mismatch_count += 1;
            }
        },
        .blob_admission => result.action = if (facts.code == 0) .missing else if (facts.a > facts.b) .over_budget else .proceed,
        .blob_result => result.action = if (facts.a != facts.b) .corrupt else .proceed,
        .finish => result.action = if (facts.code == 2) .divergence else .proceed,
        .window => for (facts.slots, 0..) |slot, i| {
            if (slot.open and slot.id == facts.a) {
                result.index = i;
                break;
            }
        },
        .view => for (facts.slots, 0..) |slot, i| {
            if (slot.open and slot.kind == .gpu_surface and std.mem.eql(u8, slot.label, facts.label)) {
                result.index = i;
                break;
            }
        },
    }
    return result;
}
