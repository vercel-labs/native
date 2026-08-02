//! Scalar C-ABI shim over the emitted core — the wire contract the gate
//! harness speaks, byte-comparable with the hand-written oracle. Host-side
//! buffers (staged text, effect log, snapshot) live outside the core; the
//! app core behind them is the transpiler's output (inbox_core.zig).

const std = @import("std");
const core = @import("inbox_core.zig");
// The core's own kernel instance: capacities are comptime parameters of the
// emitted `core.rt`, so the shim reaches the arenas through the core.
const rt = core.rt;

// The SDK runtime installs a single minimal panic handler; emitted code's
// checked failures (arena overflow, index checks in safe builds) abort with
// a message rather than pulling the full stack-trace/DWARF printer into
// every app binary.
pub const panic = std.debug.simple_panic;

var g_model: *const core.Model = undefined;
var g_staged: [4096]u8 = undefined;
var g_staged_len: usize = 0;
var g_effects: std.ArrayList(u8) = .empty;
var g_snapshot: std.ArrayList(u8) = .empty;
const gpa = std.heap.c_allocator;

export fn inbox_reset() callconv(.c) void {
    rt.resetAll();
    g_model = core.commitModelRoot(core.initialModel());
    rt.frameReset();
    g_staged_len = 0;
    g_effects.clearRetainingCapacity();
    g_snapshot.clearRetainingCapacity();
}

export fn inbox_push_text(byte: f64) callconv(.c) void {
    if (g_staged_len < g_staged.len) {
        g_staged[g_staged_len] = @intFromFloat(byte);
        g_staged_len += 1;
    }
}

fn caretDirectionOf(i: i64) core.TextCaretDirection {
    return switch (i) {
        0 => .previous,
        1 => .next,
        2 => .previous_word,
        3 => .next_word,
        4 => .start,
        else => .end,
    };
}

/// Staged bytes become the event payload; copied into the frame arena so the
/// payload has dispatch lifetime (the JS shim built a fresh array likewise).
fn takeStaged() core.Bytes {
    const text = rt.frameAlloc(u8, g_staged_len);
    @memcpy(text, g_staged[0..g_staged_len]);
    g_staged_len = 0;
    return text;
}

fn decodeEdit(a: i64, b: i64, c: i64) core.TextInputEvent {
    switch (a) {
        0 => return .{ .insert_text = takeStaged() },
        1 => return .delete_backward,
        2 => return .delete_forward,
        3 => return .delete_word_backward,
        4 => return .delete_word_forward,
        5 => return .clear,
        6 => return .{ .move_caret = .{ .direction = caretDirectionOf(b), .extend = c != 0 } },
        7 => return .{ .set_selection = .{ .anchor = b, .focus = c } },
        8 => return .{ .set_composition = .{ .text = takeStaged(), .cursor = if (b < 0) null else b } },
        9 => return .commit_composition,
        else => return .cancel_composition,
    }
}

export fn inbox_dispatch(tag: f64, a: f64, b: f64, c: f64, f0: f64, f1: f64) callconv(.c) f64 {
    const tag_i: i64 = @intFromFloat(tag);
    const a_i: i64 = @intFromFloat(a);
    const b_i: i64 = @intFromFloat(b);
    const c_i: i64 = @intFromFloat(c);
    const msg: core.Msg = switch (tag_i) {
        0 => .add,
        1 => .{ .toggle = a_i },
        2 => .{ .set_filter = switch (a_i) {
            1 => .active,
            2 => .done,
            else => .all,
        } },
        3 => .clear_done,
        4 => .{ .draft_edit = decodeEdit(a_i, b_i, c_i) },
        else => .{ .chrome_changed = .{ .insetLeft = f0, .insetTop = f1 } },
    };

    // The dispatch cycle the transpiler emits: pure update in the frame
    // arena, commit the returned tree, free the frame wholesale.
    const next = core.update(g_model, msg);
    g_model = core.commitModelRoot(next);
    rt.frameReset();

    const m = g_model;
    const eff = [_]u8{
        @intCast(tag_i & 0xff),
        @intCast(@as(i64, @intCast(m.tasks.len)) & 0xff),
        @intCast(m.nextId & 0xff),
        @intFromEnum(m.filter),
        @intCast(@as(i64, @intCast(m.draft.bytes.len)) & 0xff),
        @intFromBool(m.draft.truncated),
        @intCast(m.draft.anchor & 0xff),
        @intCast(m.draft.focus & 0xff),
    };
    g_effects.appendSlice(gpa, &eff) catch {};
    return @floatFromInt(m.tasks.len);
}

fn pushU32(list: *std.ArrayList(u8), v: u32) void {
    list.append(gpa, @intCast(v & 0xff)) catch {};
    list.append(gpa, @intCast((v >> 8) & 0xff)) catch {};
    list.append(gpa, @intCast((v >> 16) & 0xff)) catch {};
    list.append(gpa, @intCast((v >> 24) & 0xff)) catch {};
}

export fn inbox_snapshot() callconv(.c) f64 {
    const m = g_model;
    var out = &g_snapshot;
    out.clearRetainingCapacity();
    pushU32(out, @intCast(m.tasks.len));
    pushU32(out, @intCast(m.nextId));
    out.append(gpa, @intFromEnum(m.filter)) catch {};
    pushU32(out, @intFromFloat(@round(m.chromeLeading * 256.0)));
    pushU32(out, @intFromFloat(@round(m.headerHeight * 256.0)));
    for (m.tasks) |task| {
        pushU32(out, @intCast(task.id));
        out.append(gpa, @intFromBool(task.done)) catch {};
        out.append(gpa, @intCast(@as(i64, @intCast(task.title.len)) & 0xff)) catch {};
        out.appendSlice(gpa, task.title) catch {};
    }
    const d = m.draft;
    out.append(gpa, @intCast(@as(i64, @intCast(d.bytes.len)) & 0xff)) catch {};
    out.appendSlice(gpa, d.bytes) catch {};
    pushU32(out, @intCast(d.anchor));
    pushU32(out, @intCast(d.focus));
    if (d.compStart >= 0) {
        out.append(gpa, 1) catch {};
        pushU32(out, @intCast(d.compStart));
        pushU32(out, @intCast(d.compEnd));
    } else {
        out.append(gpa, 0) catch {};
        pushU32(out, 0);
        pushU32(out, 0);
    }
    out.append(gpa, @intFromBool(d.truncated)) catch {};
    return @floatFromInt(out.items.len);
}

export fn inbox_snapshot_byte(i: f64) callconv(.c) f64 {
    const idx: usize = @intFromFloat(i);
    return @floatFromInt(g_snapshot.items[idx]);
}

export fn inbox_effect_len() callconv(.c) f64 {
    return @floatFromInt(g_effects.items.len);
}

export fn inbox_effect_byte(i: f64) callconv(.c) f64 {
    return @floatFromInt(g_effects.items[@intFromFloat(i)]);
}

// ------------------------------------------------------------- arena stats

export fn inbox_stat_frame_last() callconv(.c) f64 {
    return @floatFromInt(rt.stat_frame_last);
}

export fn inbox_stat_frame_peak() callconv(.c) f64 {
    return @floatFromInt(rt.stat_frame_peak);
}

export fn inbox_stat_commit_last() callconv(.c) f64 {
    return @floatFromInt(rt.stat_commit_last);
}

export fn inbox_stat_heap_used() callconv(.c) f64 {
    return @floatFromInt(rt.heapUsed());
}

export fn inbox_stat_compactions() callconv(.c) f64 {
    return @floatFromInt(rt.stat_compactions);
}
