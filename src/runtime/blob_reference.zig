//! Independent native decision oracle for copied blob facts.
const std = @import("std");
const p = @import("blob_policy.zig");
pub fn plan(mode: p.Mode, f: p.Facts) p.Plan {
    var r: p.Plan = .{};
    const w = f.words;
    r.action = switch (mode) {
        .directory => if (w[0] == 0 or w[0] > w[1]) .directory_too_long else .proceed,
        .write => if (w[0] > w[1]) .over_budget else .proceed,
        .open => if (f.flags == 1) .more else .absent,
        .probe => blk: {
            if (f.flags == 0) break :blk .mismatch;
            if (w[2] == 0) break :blk if (w[1] == w[0]) .matches else .mismatch;
            r.words[0] = w[1] +% w[2];
            if (r.words[0] > w[0] or !std.mem.eql(u8, f.a, f.b)) break :blk .mismatch;
            if (w[2] < w[3]) break :blk if (r.words[0] == w[0]) .matches else .mismatch;
            break :blk .more;
        },
        .equal => blk: {
            if (f.flags == 1) break :blk if (w[0] != w[1]) .mismatch else if (w[0] == 0) .matches else .more;
            if (!std.mem.eql(u8, f.a, f.b)) break :blk .mismatch;
            r.words[0] = w[0] +% f.a.len;
            break :blk if (r.words[0] == w[1]) .matches else .more;
        },
        .find => blk: {
            r.words[0] = w[0];
            break :blk if (std.mem.eql(u8, f.a, f.b)) .found else .more;
        },
        .memory_write => blk: {
            if (w[0] > w[1]) break :blk .over_budget;
            if (f.flags & 1 != 0) {
                r.words[0] = w[2];
                if (f.flags & 2 != 0) {
                    r.words[1] = w[4] +% 1;
                    break :blk .dedup;
                }
                break :blk .repair;
            }
            if (w[2] == w[3]) break :blk .io_failed;
            r.words[0] = w[2] +% 1;
            break :blk .append;
        },
        .memory_read => if (f.flags == 0) .missing else if (w[0] > w[1]) .over_budget else .proceed,
        .read => if (f.flags & 1 == 0) .io_failed else if (f.flags & 2 == 0) (if (w[0] == w[1]) .spare else .proceed) else if (w[2] == 0) .proceed else .over_budget,
        .hash => if (std.mem.eql(u8, f.a, f.b)) .proceed else .corrupt,
        .install => if (f.flags == 1) .proceed else .io_failed,
        .path => blk: {
            const text = if (f.flags == 1)
                std.fmt.bufPrint(&r.text, "{s}/{s}.{x:0>16}.partial", .{ f.a, f.b, w[0] }) catch break :blk .io_failed
            else
                std.fmt.bufPrint(&r.text, "{s}/{s}", .{ f.a, f.b }) catch break :blk .io_failed;
            if (text.len > w[1]) break :blk .io_failed;
            r.len = text.len;
            break :blk .proceed;
        },
        .name => blk: {
            if (f.a.len != 16) @panic("invalid blob reference hash");
            r.text[0..32].* = std.fmt.bytesToHex(f.a[0..16].*, .lower);
            r.len = 32;
            break :blk .proceed;
        },
    };
    return r;
}
