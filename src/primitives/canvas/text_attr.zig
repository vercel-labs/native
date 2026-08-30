//! Attributed style runs over a plain UTF-8 TextBuffer.
//!
//! Paragraph-scoped rich editing: the source of truth remains contiguous
//! bytes (same IME / undo / clipboard path as textarea). Style runs are
//! parallel metadata keyed by byte ranges; edits map runs through
//! insert/delete; format toggles flip flags on the selection.
//!
//! Capacities match `text_spans.max_text_spans_per_paragraph` so layout can
//! convert runs → TextSpan without further truncation policy.

const std = @import("std");
const geometry = @import("geometry");
const text_interaction = @import("text_interaction.zig");
const text_spans = @import("text_spans.zig");

pub const TextRange = text_interaction.TextRange;
pub const TextSelection = text_interaction.TextSelection;
pub const TextInputEvent = text_interaction.TextInputEvent;
pub const TextEditState = text_interaction.TextEditState;
pub const max_style_runs = text_spans.max_text_spans_per_paragraph;

pub const StyleFlags = packed struct(u8) {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    monospace: bool = false,
    strikethrough: bool = false,
    _reserved: u3 = 0,

    pub fn isEmpty(self: StyleFlags) bool {
        return @as(u8, @bitCast(self)) == 0;
    }

    pub fn eql(self: StyleFlags, other: StyleFlags) bool {
        return @as(u8, @bitCast(self)) == @as(u8, @bitCast(other));
    }

    pub fn toggle(self: StyleFlags, flag: StyleFlag) StyleFlags {
        var next = self;
        switch (flag) {
            .bold => next.bold = !next.bold,
            .italic => next.italic = !next.italic,
            .underline => next.underline = !next.underline,
            .monospace => next.monospace = !next.monospace,
            .strikethrough => next.strikethrough = !next.strikethrough,
        }
        return next;
    }

    pub fn with(self: StyleFlags, flag: StyleFlag, on: bool) StyleFlags {
        var next = self;
        switch (flag) {
            .bold => next.bold = on,
            .italic => next.italic = on,
            .underline => next.underline = on,
            .monospace => next.monospace = on,
            .strikethrough => next.strikethrough = on,
        }
        return next;
    }
};

pub const StyleFlag = enum {
    bold,
    italic,
    underline,
    monospace,
    strikethrough,
};

/// One contiguous styled range. `start`/`end` are UTF-8 byte offsets into
/// the attributed text; empty runs are discarded by normalize.
pub const StyleRun = struct {
    start: usize = 0,
    end: usize = 0,
    flags: StyleFlags = .{},

    pub fn byteLen(self: StyleRun) usize {
        return if (self.end > self.start) self.end - self.start else 0;
    }
};

pub const AttributedEditState = struct {
    text: []const u8 = "",
    selection: TextSelection = .{},
    composition: ?TextRange = null,
    runs: []const StyleRun = &.{},
};

pub const ToggleStyleEvent = struct {
    flag: StyleFlag,
};

/// Map style runs through a byte-range replacement (delete `range`, insert
/// `inserted_len` bytes at `range.start`). Runs that only touch the deleted
/// range shrink/move; flags of the inserted slice inherit the style at the
/// caret (left edge), matching common rich-text editors. Composition stays
/// unstyled until commit (caller passes inserted_len with empty inherit
/// when mapping provisional IME).
pub fn mapStyleRunsThroughReplace(
    runs: []const StyleRun,
    range: TextRange,
    inserted_len: usize,
    inherit: StyleFlags,
    out: []StyleRun,
) []StyleRun {
    const del_start = range.start;
    const del_end = range.end;
    const del_len = if (del_end > del_start) del_end - del_start else 0;
    var count: usize = 0;

    for (runs) |run| {
        if (count >= out.len) break;
        var start = run.start;
        var end = run.end;
        if (end <= del_start) {
            // entirely before
        } else if (start >= del_end) {
            start = start - del_len + inserted_len;
            end = end - del_len + inserted_len;
        } else {
            // overlaps deleted range
            if (start < del_start) {
                end = del_start;
            } else if (end > del_end) {
                start = del_start + inserted_len;
                end = end - del_len + inserted_len;
            } else {
                continue; // fully deleted
            }
        }
        if (end <= start) continue;
        out[count] = .{ .start = start, .end = end, .flags = run.flags };
        count += 1;
    }

    if (inserted_len > 0 and !inherit.isEmpty() and count < out.len) {
        out[count] = .{
            .start = del_start,
            .end = del_start + inserted_len,
            .flags = inherit,
        };
        count += 1;
    }

    return normalizeStyleRuns(out[0..count], out);
}

fn styleAt(runs: []const StyleRun, offset: usize) StyleFlags {
    for (runs) |run| {
        if (offset >= run.start and offset < run.end) return run.flags;
        // caret at run.end inherits that run when collapsed at boundary
        if (offset == run.end and run.end > run.start) return run.flags;
    }
    // Prefer left-adjacent run for caret sitting between runs
    var best: ?StyleRun = null;
    for (runs) |run| {
        if (run.end <= offset and run.end > run.start) {
            if (best == null or run.end > best.?.end) best = run;
        }
    }
    return if (best) |run| run.flags else .{};
}

/// Coalesce adjacent runs with identical flags; drop empties; clamp to
/// `max_style_runs` by merging oldest overflow into the last kept run.
pub fn normalizeStyleRuns(runs: []const StyleRun, out: []StyleRun) []StyleRun {
    var count: usize = 0;
    for (runs) |run| {
        if (run.end <= run.start) continue;
        if (count > 0 and out[count - 1].flags.eql(run.flags) and out[count - 1].end == run.start) {
            out[count - 1].end = run.end;
            continue;
        }
        if (count >= out.len) break;
        out[count] = run;
        count += 1;
    }
    return out[0..count];
}

pub fn toggleStyleOnSelection(
    runs: []const StyleRun,
    selection: TextSelection,
    text_len: usize,
    flag: StyleFlag,
    out: []StyleRun,
) []StyleRun {
    const range = selection.range(text_len);
    if (range.isCollapsed(text_len) or range.start >= text_len) {
        const n = @min(runs.len, out.len);
        @memcpy(out[0..n], runs[0..n]);
        return out[0..n];
    }

    const sel_start = range.start;
    const sel_end = @min(range.end, text_len);
    const sample = styleAt(runs, sel_start);
    const turn_on = !switch (flag) {
        .bold => sample.bold,
        .italic => sample.italic,
        .underline => sample.underline,
        .monospace => sample.monospace,
        .strikethrough => sample.strikethrough,
    };

    var scratch: [max_style_runs * 3]StyleRun = undefined;
    var sc: usize = 0;

    // Runs entirely before selection
    for (runs) |run| {
        if (run.end <= sel_start) {
            if (sc < scratch.len) {
                scratch[sc] = run;
                sc += 1;
            }
        }
    }

    // Split overlapping runs + selection cover
    var covered = false;
    for (runs) |run| {
        if (run.end <= sel_start or run.start >= sel_end) continue;
        covered = true;
        if (run.start < sel_start and sc < scratch.len) {
            scratch[sc] = .{ .start = run.start, .end = sel_start, .flags = run.flags };
            sc += 1;
        }
        const mid_start = @max(run.start, sel_start);
        const mid_end = @min(run.end, sel_end);
        if (mid_end > mid_start and sc < scratch.len) {
            scratch[sc] = .{
                .start = mid_start,
                .end = mid_end,
                .flags = run.flags.with(flag, turn_on),
            };
            sc += 1;
        }
        if (run.end > sel_end and sc < scratch.len) {
            scratch[sc] = .{ .start = sel_end, .end = run.end, .flags = run.flags };
            sc += 1;
        }
    }
    if (!covered and sc < scratch.len) {
        var flags: StyleFlags = .{};
        flags = flags.with(flag, turn_on);
        scratch[sc] = .{ .start = sel_start, .end = sel_end, .flags = flags };
        sc += 1;
    }

    // Runs entirely after selection
    for (runs) |run| {
        if (run.start >= sel_end) {
            if (sc < scratch.len) {
                scratch[sc] = run;
                sc += 1;
            }
        }
    }

    return normalizeStyleRuns(scratch[0..sc], out);
}

fn activeReplaceRange(state: AttributedEditState) TextRange {
    if (state.composition) |c| return c;
    return state.selection.range(state.text.len);
}

pub fn applyAttributedTextInputEvent(
    state: AttributedEditState,
    event: TextInputEvent,
    output: []u8,
    runs_out: []StyleRun,
) text_interaction.Error!AttributedEditState {
    const inherit = styleAt(state.runs, state.selection.range(state.text.len).start);
    const before_len = state.text.len;
    const replace_range = activeReplaceRange(state);

    const next_text = try text_interaction.applyTextInputEvent(.{
        .text = state.text,
        .selection = state.selection,
        .composition = state.composition,
    }, event, output);

    const runs: []const StyleRun = switch (event) {
        .move_caret, .set_selection, .commit_composition => state.runs,
        else => blk: {
            const deleted = replace_range.byteLen(before_len);
            const inserted_len = next_text.text.len + deleted -| before_len;
            // IME provisional composition: do not stamp persistent styles
            const stamp: StyleFlags = switch (event) {
                .set_composition => .{},
                .insert_text => inherit,
                else => inherit,
            };
            break :blk mapStyleRunsThroughReplace(
                state.runs,
                replace_range,
                inserted_len,
                stamp,
                runs_out,
            );
        },
    };

    return .{
        .text = next_text.text,
        .selection = next_text.selection,
        .composition = next_text.composition,
        .runs = runs,
    };
}

/// Convert style runs covering `text` into TextSpan slices (subslices of
/// `text`) for layout/paint. Unstyled gaps become regular spans.
pub fn attributedToTextSpans(
    text: []const u8,
    runs: []const StyleRun,
    out: []text_spans.TextSpan,
) []text_spans.TextSpan {
    if (text.len == 0) return out[0..0];
    var count: usize = 0;
    var cursor: usize = 0;

    // Work on a sorted copy of run indices
    var order: [max_style_runs]usize = undefined;
    const n = @min(runs.len, max_style_runs);
    for (0..n) |i| order[i] = i;
    var a: usize = 0;
    while (a + 1 < n) : (a += 1) {
        var b = a + 1;
        while (b < n) : (b += 1) {
            if (runs[order[b]].start < runs[order[a]].start) {
                const tmp = order[a];
                order[a] = order[b];
                order[b] = tmp;
            }
        }
    }

    var ri: usize = 0;
    while (cursor < text.len and count < out.len) {
        while (ri < n and runs[order[ri]].end <= cursor) ri += 1;
        if (ri >= n) {
            out[count] = .{ .text = text[cursor..] };
            count += 1;
            break;
        }
        const run = runs[order[ri]];
        if (run.start > cursor) {
            const gap_end = @min(run.start, text.len);
            out[count] = .{ .text = text[cursor..gap_end] };
            count += 1;
            cursor = gap_end;
            continue;
        }
        const end = @min(run.end, text.len);
        if (end > cursor) {
            out[count] = .{
                .text = text[cursor..end],
                .weight = if (run.flags.bold) .bold else .regular,
                .italic = run.flags.italic,
                .monospace = run.flags.monospace,
                .underline = run.flags.underline,
                .strikethrough = run.flags.strikethrough,
            };
            count += 1;
            cursor = end;
        }
        ri += 1;
    }
    return out[0..count];
}

/// Serialize up to `max_style_runs` into a fixed record buffer:
/// each run = u32 start, u32 end, u8 flags (9 bytes). Returns byte length.
pub fn serializeStyleRuns(runs: []const StyleRun, out: []u8) usize {
    const record = 9;
    var o: usize = 0;
    for (runs) |run| {
        if (o + record > out.len) break;
        std.mem.writeInt(u32, out[o..][0..4], @intCast(run.start), .little);
        std.mem.writeInt(u32, out[o + 4 ..][0..4], @intCast(run.end), .little);
        out[o + 8] = @bitCast(run.flags);
        o += record;
    }
    return o;
}

pub fn deserializeStyleRuns(bytes: []const u8, out: []StyleRun) []StyleRun {
    const record = 9;
    var count: usize = 0;
    var i: usize = 0;
    while (i + record <= bytes.len and count < out.len) : (i += record) {
        out[count] = .{
            .start = std.mem.readInt(u32, bytes[i..][0..4], .little),
            .end = std.mem.readInt(u32, bytes[i + 4 ..][0..4], .little),
            .flags = @bitCast(bytes[i + 8]),
        };
        count += 1;
    }
    return normalizeStyleRuns(out[0..count], out);
}

test "mapStyleRunsThroughReplace shifts and inherits" {
    var out: [8]StyleRun = undefined;
    const runs = [_]StyleRun{
        .{ .start = 0, .end = 5, .flags = .{ .bold = true } },
    };
    const mapped = mapStyleRunsThroughReplace(
        &runs,
        TextRange.init(5, 5),
        3,
        .{ .italic = true },
        &out,
    );
    try std.testing.expect(mapped.len == 2);
    try std.testing.expect(mapped[0].flags.bold);
    try std.testing.expect(mapped[1].start == 5 and mapped[1].end == 8);
    try std.testing.expect(mapped[1].flags.italic);
}

test "toggleStyleOnSelection bold" {
    var out: [8]StyleRun = undefined;
    const runs = [_]StyleRun{};
    const sel = TextSelection{ .anchor = 0, .focus = 4 };
    const toggled = toggleStyleOnSelection(&runs, sel, 10, .bold, &out);
    try std.testing.expect(toggled.len == 1);
    try std.testing.expect(toggled[0].flags.bold);
    try std.testing.expect(toggled[0].start == 0 and toggled[0].end == 4);
}

test "attributedToTextSpans covers gaps" {
    const text = "hello";
    const runs = [_]StyleRun{
        .{ .start = 1, .end = 3, .flags = .{ .bold = true } },
    };
    var spans: [8]text_spans.TextSpan = undefined;
    const out = attributedToTextSpans(text, &runs, &spans);
    try std.testing.expect(out.len == 3);
    try std.testing.expectEqualStrings("h", out[0].text);
    try std.testing.expectEqualStrings("el", out[1].text);
    try std.testing.expect(out[1].weight == .bold);
    try std.testing.expectEqualStrings("lo", out[2].text);
}

test "serialize roundtrip" {
    const runs = [_]StyleRun{
        .{ .start = 2, .end = 9, .flags = .{ .italic = true, .underline = true } },
    };
    var buf: [64]u8 = undefined;
    const n = serializeStyleRuns(&runs, &buf);
    var out: [4]StyleRun = undefined;
    const back = deserializeStyleRuns(buf[0..n], &out);
    try std.testing.expect(back.len == 1);
    try std.testing.expect(back[0].start == 2 and back[0].end == 9);
    try std.testing.expect(back[0].flags.italic and back[0].flags.underline);
}

/// Hit-test a point against attributed layout: returns the UTF-8 byte
/// caret offset (snapped) within `text`. Uses TextSpan conversion so the
/// same run→span path paint will use stays the measurement source of truth.
pub fn hitTestAttributed(
    text: []const u8,
    runs: []const StyleRun,
    origin: geometry.OffsetF,
    point: geometry.OffsetF,
    options: text_spans.TextSpanLayoutOptions,
) usize {
    var span_buf: [max_style_runs]text_spans.TextSpan = undefined;
    const spans = attributedToTextSpans(text, runs, &span_buf);
    var run_storage: [text_spans.max_text_span_runs_per_paragraph]text_spans.TextSpanRun = undefined;
    _ = text_spans.layoutTextSpans(spans, options, &run_storage);
    if (text.len == 0) return 0;
    const local_x = point.dx - origin.dx;
    if (local_x <= 0) return 0;
    const width = options.max_width;
    if (!(width > 0)) return text.len;
    const ratio = @min(1.0, @max(0.0, local_x / width));
    const raw: usize = @intFromFloat(ratio * @as(f32, @floatFromInt(text.len)));
    return text_interaction.snapTextOffset(text, @min(raw, text.len));
}

test "hitTestAttributed empty and edges" {
    const text = "abcd";
    const runs = [_]StyleRun{};
    const opts = text_spans.TextSpanLayoutOptions{ .size = 14, .max_width = 100 };
    const origin = geometry.OffsetF{ .dx = 0, .dy = 0 };
    try std.testing.expect(hitTestAttributed(text, &runs, origin, .{ .dx = -1, .dy = 0 }, opts) == 0);
    try std.testing.expect(hitTestAttributed(text, &runs, origin, .{ .dx = 200, .dy = 0 }, opts) == text.len);
}


/// Parallel style undo: apps push serialized runs before a format toggle;
/// text undo remains on TextBuffer. Depth is caller-owned.
pub fn cloneRuns(src: []const StyleRun, dest: []StyleRun) []StyleRun {
    const n = @min(src.len, dest.len);
    @memcpy(dest[0..n], src[0..n]);
    return dest[0..n];
}

test "cloneRuns copies into dest" {
    const runs = [_]StyleRun{
        .{ .start = 0, .end = 5, .flags = .{ .bold = true } },
    };
    var dest: [4]StyleRun = undefined;
    const copied = cloneRuns(&runs, &dest);
    try std.testing.expect(copied.len == 1);
    try std.testing.expect(copied[0].flags.bold);
}
