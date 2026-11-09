//! Independent native behavior oracle for the packed request policy test ABI.
//! This module is used only by tests; it retains neither packets nor secrets.
const std = @import("std");

pub fn plan(request: []const u8, output: []u8) usize {
    const operation = request[0];
    const size: usize = if (operation == 11) 16 else if (operation == 13) 20 else 8;
    @memset(output[0..size], 0);
    if (operation == 13) {
        const names = [_][]const u8{ "core.credentials.set", "core.credentials.get", "core.credentials.delete" };
        const name = request[2..][0..request[1]];
        for (names, 0..) |candidate, kind| if (std.mem.eql(u8, name, candidate)) {
            const payload = request[2 + name.len ..];
            var at: usize = 0;
            var spans: [4]u32 = @splat(0);
            for (0..if (kind == 0) @as(usize, 2) else 1) |field| {
                if (payload.len - at < 4) return size;
                const length = std.mem.readInt(u32, payload[at..][0..4], .little);
                at += 4;
                if (length > payload.len - at) return size;
                spans[field * 2] = @intCast(at);
                spans[field * 2 + 1] = length;
                at += length;
            }
            if (at != payload.len) return size;
            output[0] = 1;
            output[1] = @intCast(kind);
            for (spans, 0..) |value, i| std.mem.writeInt(u32, output[4 + i * 4 ..][0..4], value, .little);
            return size;
        };
        return size;
    }
    if (operation == 12) {
        output[0] = 255;
        output[1] = 255;
        const name = request[2..][0..request[1]];
        var at: usize = 2 + name.len;
        const counts = [_]usize{ 36, 16, 16, 16, 4, 16, 16 };
        for (counts, 0..) |count, family| for (0..count) |slot| {
            const used = request[at] == 1;
            const flags = request[at + 1];
            const key = request[at + 3 ..][0..request[at + 2]];
            const err = request[at + 3 + key.len];
            at += 4 + key.len;
            if (name.len == 0 or !used or (family == 1 and flags == 1) or !std.mem.eql(u8, name, key)) continue;
            output[0] = @intCast(family);
            output[1] = @intCast(slot);
            output[6] = err;
            switch (family) {
                0 => {
                    output[2] = 1;
                    output[3] = 1;
                    output[5] = flags;
                    output[7] = flags;
                },
                1, 2, 3 => output[3] = 1,
                4 => {
                    output[3] = 1;
                    if (flags == 1) output[4] = 1 else output[2] = 1;
                },
                5 => {
                    output[2] = 1;
                    output[3] = 1;
                },
                6 => if (flags == 1) {
                    output[2] = 1;
                    output[3] = 1;
                },
                else => unreachable,
            }
            return size;
        };
        return size;
    }
    const name_at: usize = if (operation == 11) 16 else 12;
    const name_len = request[if (operation == 11) @as(usize, 3) else 2];
    const name = request[name_at..][0..name_len];
    const count: usize = if (operation == 11) 36 else 16;
    var entries: [36][]const u8 = undefined;
    var at: usize = name_at + name.len;
    for (0..count) |slot| {
        const len = request[at + if (operation == 11) @as(usize, 1) else 6];
        const fixed: usize = if (operation == 11) 15 else 7;
        entries[slot] = request[at .. at + fixed + len];
        at += fixed + len;
    }
    var matching: ?usize = null;
    for (entries[0..count], 0..) |entry, slot| {
        const key = if (operation == 11) entry[2..][0..entry[1]] else entry[7..];
        if (entry[0] == 1 and std.mem.eql(u8, name, key)) {
            matching = slot;
            break;
        }
    }
    output[0] = 255;
    if (operation == 11) {
        output[1] = 255;
        const action = request[1];
        if (action == 1) {
            if (matching) |slot| output[0] = @intCast(slot);
            return size;
        }
        if (action == 2) {
            const slot = request[10];
            const entry = entries[slot];
            const route = entry[2 + @as(usize, entry[1]) ..];
            const ok = request[9] == 1;
            output[0] = slot;
            output[2] = route[if (ok) @as(usize, 0) else 1];
            output[3] = if (ok and route[3] == 1) 2 else if (ok and route[2] == 1) 1 else 0;
            output[4] = 1;
            output[5] = route[4];
            if (route[4] == 1) @memcpy(output[8..16], route[5..13]);
            return size;
        }
        const first: usize = switch (request[2]) {
            0 => 0,
            1 => 16,
            2 => 32,
            else => unreachable,
        };
        const end: usize = if (request[2] == 2) 36 else first + 16;
        var free: ?usize = null;
        for (entries[first..end], first..) |entry, slot| if (entry[0] == 0) {
            free = slot;
            break;
        };
        if (action == 3) {
            if (free) |slot| output[0] = @intCast(slot);
            if (name.len > 0 and (matching != null or request[4] == 1)) output[3] = 1 else if (free == null) output[3] = 2 else if (request[11] == 1) output[3] = 3;
            return size;
        }
        output[2] = request[6];
        output[3] = request[7];
        output[4] = request[8];
        if (request[4] == 1) return size;
        if (name.len > 0) if (matching) |slot| {
            if (request[5] == 1) return size;
            if (slot >= first and slot < end) {
                output[0] = @intCast(slot);
                return size;
            }
            output[1] = @intCast(slot);
        };
        if (free) |slot| output[0] = @intCast(slot);
        return size;
    }
    std.debug.assert(operation == 14);
    output[1..4].* = request[5..8].*;
    if (request[1] == 0) {
        if (request[3] == 1) return size;
        if (name.len > 0) if (matching) |slot| {
            const entry = entries[slot];
            if (request[4] != 1 or entry[1] != 1 or entry[2] == 1) return size;
            output[0] = @intCast(slot);
            return size;
        };
        for (entries[0..16], 0..) |entry, slot| if (entry[0] == 0) {
            output[0] = @intCast(slot);
            break;
        };
        return size;
    }
    const slot = request[8];
    const entry = entries[slot];
    output[0] = slot;
    if (request[10] == 0) {
        output[4] = entry[5];
        output[5] = 2;
        output[6] = @intFromBool(entry[2] == 0);
    } else switch (request[9]) {
        0 => output[4] = entry[3],
        1 => {
            std.debug.assert(entry[1] == 1);
            output[4] = entry[4];
            output[5] = 1;
            output[6] = @intFromBool(entry[2] == 0);
        },
        2 => {
            std.debug.assert(entry[1] == 0);
            output[4] = entry[4];
            output[5] = 1;
            output[6] = 1;
        },
        else => unreachable,
    }
    return size;
}
