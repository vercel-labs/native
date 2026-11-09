//! Independent native callback behavior. Test-only; production ownership
//! belongs to the compiled policies, while the host retains storage and IO.
const std = @import("std");

pub fn plan(request: []const u8, output: []u8) usize {
    if (request[0] < 2) return declaration(request, output);
    if (request[0] == 17) return buffered(request, output);
    std.debug.assert(request[0] == 7);
    return timer(request, output);
}

fn declaration(request: []const u8, output: []u8) usize {
    const length: usize = request[1];
    const name = request[2..][0..length];
    const arm = request[0] == 0;
    var at = 2 + length + @as(usize, if (arm) 3 else 0);
    var matching: u8 = 255;
    var free: u8 = 255;
    for (0..16) |slot| {
        const entry = request[at..];
        const size: usize = entry[2];
        if (entry[0] == 0 and free == 255) free = @intCast(slot);
        if (entry[0] == 1 and entry[1] == 0 and matching == 255 and std.mem.eql(u8, name, entry[3..][0..size])) matching = @intCast(slot);
        at += 5 + size;
    }
    if (!arm) {
        output[0] = matching;
        return 1;
    }
    const blocked = request[2 + length] == 1;
    output[0..5].* = .{ @intFromBool(!blocked), if (blocked) 255 else free, if (blocked or length == 0) 255 else matching, request[3 + length], request[4 + length] };
    return 5;
}

fn buffered(request: []const u8, output: []u8) usize {
    const key = std.mem.readInt(u64, request[8..16], .little);
    const base = std.mem.readInt(u64, request[16..24], .little);
    const slot: usize = @intCast(key - base);
    const entry = request[24 + slot * 4 ..][0..4];
    std.debug.assert(slot < 16 and entry[0] == 1);
    @memset(output[0..8], 0);
    output[0] = @intCast(slot);
    output[4] = 1;
    if (entry[1] == 1) {
        output[1] = entry[3];
        output[5] = 1;
        if (request[1] == 1) output[2] = 6;
        return 8;
    }
    if (request[1] == 1) {
        output[1] = entry[2];
        output[2] = 6;
        return 8;
    }
    const cut = request[1] == 2 and request[4] == 1;
    if (request[3] != 0 or cut) {
        output[1] = entry[3];
        output[2] = 5;
        output[3] = if (request[3] == 0 and cut) 2 else 1;
        return 8;
    }
    output[1] = entry[2];
    output[2] = switch (request[1]) {
        0 => switch (request[2]) {
            0 => 2,
            3 => 3,
            else => 1,
        },
        2 => 4,
        3 => 2,
        else => unreachable,
    };
    return 8;
}

fn timer(request: []const u8, output: []u8) usize {
    const key = std.mem.readInt(u64, request[4..12], .little);
    const base = std.mem.readInt(u64, request[20..28], .little);
    const timestamp = std.mem.readInt(u64, request[12..20], .little);
    const slot: usize = @intCast(key - base);
    const entry = request[32 + slot * 4 ..][0..4];
    const subscription = request[1] == 1;
    std.debug.assert(slot < 16 and (subscription or entry[0] == 1));
    std.debug.assert(subscription and request[2] == 0 or !subscription and (entry[1] == 1 or request[2] == 0));
    @memset(output[0..40], 0);
    output[0] = @intCast(slot);
    output[1] = entry[3];
    if (!subscription) {
        output[2] = entry[1];
        output[3] = @intFromBool(entry[1] == 0 or entry[2] == 0 or request[2] == 1);
    }
    const ms = @as(f64, @floatFromInt(timestamp)) / std.time.ns_per_ms;
    std.mem.writeInt(u64, output[8..16], @bitCast(ms), .little);
    const text = std.fmt.bufPrint(output[16..36], "{d}", .{timestamp}) catch unreachable;
    output[4] = @intCast(text.len);
    return 40;
}
