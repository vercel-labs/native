//! Independent native installation, persistence and lifecycle reference.
//! Test-only: shipped coordination belongs to the compiled TypeScript policy.
const std = @import("std");

pub fn plan(request: []const u8) [32]u8 {
    var result: [32]u8 = @splat(0);
    switch (request[1]) {
        0 => {
            const pending = request[4] != 0;
            if (request[2] == 5) {
                result[1] = @intFromBool(pending);
            } else {
                const terminal = request[2] == 2 or request[2] == 4;
                result[0] = @intFromBool(pending or (terminal and request[3] != 0));
                result[1] = @intFromBool(terminal and request[3] == 0);
            }
        },
        1 => {
            var at: usize = 0;
            if (request[2] != 0 or request[3] != 0 or request[4] != 0) {
                result[at] = if (request[2] != 0) 1 else if (request[3] != 0) 2 else 3;
                at += 1;
            }
            result[at] = 4;
            at += 1;
            if (request[4] != 0 and request[5] != 0) {
                result[at] = 5;
                at += 1;
            }
            if (request[4] != 0) {
                result[at] = 6;
                at += 1;
            }
            result[at..][0..4].* = .{ 7, 8, 9, 10 };
        },
        2 => result[0] = if (request[2] == 0) 0 else if (request[3] != 0) 1 else if (request[4] != 0) 2 else 3,
        3 => {
            result[0] = 255;
            if (request[3] == 0) return result;
            const migrated = request[2] == 2;
            const outcome: u8 = if (migrated) (if (request[4] == 0) 4 else if (std.mem.readInt(u64, request[8..16], .little) > 16 * 1024 * 1024) 6 else 0) else request[5];
            result[0] = outcome;
            var at: usize = 1;
            if (outcome == 0) {
                result[at] = 1;
                at += 1;
            }
            if (migrated and outcome == 0) {
                result[at] = 2;
                at += 1;
            }
            if (request[2] != 0) result[at] = 3;
            result[5] = @intFromBool(!migrated or outcome == 0);
        },
        4 => {
            result[0] = if (request[2] == 0) 1 else if (request[2] == 1) 2 else 3;
            if (result[0] == 3) reason(&result, switch (request[2]) {
                2 => "corrupt",
                3 => "version_unknown",
                4 => "migrate_failed",
                5 => "io_failed",
                6 => "rejected",
                else => unreachable,
            });
        },
        5 => {
            if (request[2] != 0) {
                result[0] = 1;
                reason(&result, if (request[2] == 1) "io_failed" else "rejected");
            }
        },
        6 => {
            const replay_count = std.mem.readInt(u64, request[8..16], .little);
            const live_count = std.mem.readInt(u64, request[16..24], .little);
            const index = std.mem.readInt(u64, request[24..32], .little);
            const replay = request[2] != 0 and replay_count != 0;
            if (index < (if (replay) replay_count else live_count)) {
                result[0] = if (replay) 2 else 1;
                result[1] = @intFromBool(!replay);
                std.mem.writeInt(u64, result[8..16], index, .little);
                std.mem.writeInt(u64, result[16..24], index + 1, .little);
            }
        },
        7 => {
            const name = request[3..];
            result[0] = if (request[2] < 2 and (std.mem.eql(u8, name, "core.persist") or std.mem.eql(u8, name, "core.persist.flush"))) 2 else 1;
            if (request[2] >= 5) result[1] = 2;
        },
        else => unreachable,
    }
    return result;
}

fn reason(result: *[32]u8, bytes: []const u8) void {
    result[1] = @intCast(bytes.len);
    @memcpy(result[2..][0..bytes.len], bytes);
}
