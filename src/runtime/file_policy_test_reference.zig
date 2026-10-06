//! Independent test-only oracle preserving native file/clipboard coordination.
const std = @import("std");

pub fn plan(request: []const u8, output: []u8) usize {
    const file = request[0] == 15;
    const size: usize = if (file) 8 else 4;
    const header: usize = if (file) 12 else 8;
    const fixed: usize = if (file) 8 else 3;
    const count: usize = if (file) 4 else 16;
    const name = request[header..][0..request[2]];
    var slots: [16][]const u8 = undefined;
    var at: usize = header + name.len;
    for (0..count) |index| {
        const length = request[at + fixed - 1];
        slots[index] = request[at..][0 .. fixed + length];
        at += fixed + length;
    }
    var matching: ?usize = null;
    for (slots[0..count], 0..) |entry, index| {
        if (entry[0] == 1 and (file or name.len > 0) and std.mem.eql(u8, name, entry[fixed..])) {
            matching = index;
            break;
        }
    }
    var free: ?usize = null;
    for (slots[0..count], 0..) |entry, index| if (entry[0] == 0) {
        free = index;
        break;
    };
    @memset(output[0..size], 0);
    output[0] = 255;
    const action = request[1];
    if (!file) {
        output[1] = request[5];
        switch (action) {
            0 => if (matching) |index| {
                output[0] = @intCast(index);
            },
            1 => if (request[3] == 0 and matching == null) {
                if (free) |index| output[0] = @intCast(index);
            },
            2 => {
                output[0] = request[4];
                output[1] = slots[request[4]][1];
                output[2] = 1;
            },
            else => unreachable,
        }
        return size;
    }
    if (action == 0) {
        if (matching) |index| output[0] = @intCast(index);
        return size;
    }
    output[2] = request[10];
    if (action == 1 or action == 2) {
        output[1] = 1;
        if (request[3] == 1) return size;
        var selected = free;
        if (action == 1 and name.len > 0) {
            if (matching) |index| {
                if (slots[index][1] == 1) return size;
                selected = index;
            }
        } else if (action == 2 and (name.len == 0 or matching != null)) return size;
        if (selected) |index| {
            output[0] = @intCast(index);
            output[1] = 0;
            output[2] = request[9];
        }
        return size;
    }
    if (action == 3 or action == 4) {
        output[1] = 2;
        const index = matching orelse return size;
        const entry = slots[index];
        if (entry[1] != 1 or entry[3] == 1) return size;
        if (entry[2] == 1) {
            output[1] = 3;
            return size;
        }
        output[0] = @intCast(index);
        output[1] = 0;
        output[2] = request[9];
        return size;
    }
    const index = request[4];
    const entry = slots[index];
    const op = request[5];
    const event = request[6];
    const outcome = request[7];
    output[0] = index;
    output[2] = entry[6];
    output[3] = 3;
    if (entry[3] == 1 and outcome == 5) {
        output[4] = 1;
    } else if (op == 4 and event == 1 and outcome == 0) {
        output[2] = entry[4];
        output[3] = 1;
    } else if (op == 4 and event == 2 and outcome == 0) {
        output[2] = entry[5];
        output[3] = 2;
        output[4] = 1;
    } else if (outcome == 0) {
        output[2] = entry[5];
        output[3] = 0;
        output[5] = 1;
        output[4] = @intFromBool(op == 7);
    } else if (op == 6 and (outcome == 4 or outcome == 7)) {
        output[5] = 1;
    } else output[4] = 1;
    return size;
}
