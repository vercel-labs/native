const std = @import("std");
const geometry = @import("geometry");

const Error = error{
    TextEditBufferTooSmall,
};

pub const TextRange = struct {
    start: usize = 0,
    end: usize = 0,

    pub fn init(start: usize, end: usize) TextRange {
        return .{ .start = start, .end = end };
    }

    pub fn normalized(self: TextRange, text_len: usize) TextRange {
        const start = @min(self.start, text_len);
        const end = @min(self.end, text_len);
        return if (start <= end)
            .{ .start = start, .end = end }
        else
            .{ .start = end, .end = start };
    }

    pub fn byteLen(self: TextRange, text_len: usize) usize {
        const range = self.normalized(text_len);
        return range.end - range.start;
    }

    pub fn isCollapsed(self: TextRange, text_len: usize) bool {
        const range = self.normalized(text_len);
        return range.start == range.end;
    }
};

pub const TextSelectionRect = struct {
    range: TextRange = .{},
    rect: geometry.RectF = .{},
};

/// Which painted line owns a caret whose byte offset is shared by the
/// end of one soft-wrapped line and the start of the next.
pub const TextCaretAffinity = enum {
    upstream,
    downstream,
};

pub const TextCaretPosition = struct {
    offset: usize = 0,
    affinity: TextCaretAffinity = .upstream,
};

pub const TextSelection = struct {
    anchor: usize = 0,
    focus: usize = 0,
    /// Affinity belongs to the focus end. It only changes geometry at a
    /// soft-wrap boundary; ordinary offsets render identically.
    affinity: TextCaretAffinity = .upstream,

    pub fn collapsed(offset: usize) TextSelection {
        return .{ .anchor = offset, .focus = offset };
    }

    pub fn collapsedAt(position: TextCaretPosition) TextSelection {
        return .{
            .anchor = position.offset,
            .focus = position.offset,
            .affinity = position.affinity,
        };
    }

    pub fn range(self: TextSelection, text_len: usize) TextRange {
        return TextRange.init(self.anchor, self.focus).normalized(text_len);
    }

    pub fn isCollapsed(self: TextSelection, text_len: usize) bool {
        return self.range(text_len).isCollapsed(text_len);
    }
};

pub const TextCaretDirection = enum {
    previous,
    next,
    previous_word,
    next_word,
    start,
    end,
};

pub const TextCaretMove = struct {
    direction: TextCaretDirection,
    extend: bool = false,
};

pub const TextCompositionUpdate = struct {
    text: []const u8 = "",
    cursor: ?usize = null,
};

pub const TextInputEvent = union(enum) {
    insert_text: []const u8,
    delete_backward,
    delete_forward,
    delete_word_backward,
    delete_word_forward,
    clear,
    move_caret: TextCaretMove,
    set_selection: TextSelection,
    set_composition: TextCompositionUpdate,
    commit_composition,
    cancel_composition,
};

pub const TextEditState = struct {
    text: []const u8 = "",
    selection: TextSelection = .{},
    composition: ?TextRange = null,

    pub fn init(text: []const u8) TextEditState {
        return .{
            .text = text,
            .selection = TextSelection.collapsed(text.len),
        };
    }

    pub fn apply(self: TextEditState, event: TextInputEvent, output: []u8) Error!TextEditState {
        return applyTextInputEvent(self, event, output);
    }
};

pub fn applyTextInputEvent(state: TextEditState, event: TextInputEvent, output: []u8) Error!TextEditState {
    const normalized = normalizeTextEditState(state);
    return switch (event) {
        .insert_text => |text| replaceTextEditRange(normalized, activeTextReplaceRange(normalized), text, output, null, text.len),
        .delete_backward => deleteBackwardTextEdit(normalized, output),
        .delete_forward => deleteForwardTextEdit(normalized, output),
        .delete_word_backward => deleteWordBackwardTextEdit(normalized, output),
        .delete_word_forward => deleteWordForwardTextEdit(normalized, output),
        .clear => .{
            .text = "",
            .selection = TextSelection.collapsed(0),
            .composition = null,
        },
        .move_caret => |move| moveTextCaret(normalized, move),
        .set_selection => |selection| .{
            .text = normalized.text,
            .selection = snapTextCaretSelection(normalized.text, selection),
            .composition = null,
        },
        .set_composition => |composition| setTextComposition(normalized, composition, output),
        .commit_composition => .{
            .text = normalized.text,
            .selection = normalized.selection,
            .composition = null,
        },
        .cancel_composition => cancelTextComposition(normalized, output),
    };
}

const TextReplaceResult = struct {
    text: []const u8,
    inserted_range: TextRange,
};

fn normalizeTextEditState(state: TextEditState) TextEditState {
    return .{
        .text = state.text,
        .selection = snapTextCaretSelection(state.text, state.selection),
        .composition = if (state.composition) |range| snapTextRange(state.text, range) else null,
    };
}

fn activeTextReplaceRange(state: TextEditState) TextRange {
    if (state.composition) |range| return snapTextRange(state.text, range);
    return state.selection.range(state.text.len);
}

fn replaceTextEditRange(
    state: TextEditState,
    range: TextRange,
    replacement: []const u8,
    output: []u8,
    composition: ?TextRange,
    cursor_offset: usize,
) Error!TextEditState {
    const result = try replaceTextRange(state.text, range, replacement, output);
    const cursor = snapTextCaretOffset(result.text, result.inserted_range.start + @min(cursor_offset, replacement.len));
    return .{
        .text = result.text,
        .selection = TextSelection.collapsed(cursor),
        .composition = composition,
    };
}

fn setTextComposition(state: TextEditState, composition: TextCompositionUpdate, output: []u8) Error!TextEditState {
    const range = activeTextReplaceRange(state);
    const cursor = snapTextCaretOffset(composition.text, composition.cursor orelse composition.text.len);
    const result = try replaceTextRange(state.text, range, composition.text, output);
    const absolute_cursor = snapTextCaretOffset(result.text, result.inserted_range.start + cursor);
    return .{
        .text = result.text,
        .selection = TextSelection.collapsed(absolute_cursor),
        .composition = result.inserted_range,
    };
}

fn cancelTextComposition(state: TextEditState, output: []u8) Error!TextEditState {
    const composition = state.composition orelse return state;
    const range = snapTextRange(state.text, composition);
    const result = try replaceTextRange(state.text, range, "", output);
    return .{
        .text = result.text,
        .selection = TextSelection.collapsed(snapTextCaretOffset(result.text, result.inserted_range.start)),
        .composition = null,
    };
}

fn deleteBackwardTextEdit(state: TextEditState, output: []u8) Error!TextEditState {
    const range = activeTextReplaceRange(state);
    if (!range.isCollapsed(state.text.len)) return replaceTextEditRange(state, range, "", output, null, 0);

    const caret = snapTextCaretOffset(state.text, state.selection.focus);
    if (caret == 0) return .{ .text = state.text, .selection = TextSelection.collapsed(0), .composition = null };
    return replaceTextEditRange(state, TextRange.init(previousTextCaretOffset(state.text, caret), caret), "", output, null, 0);
}

fn deleteForwardTextEdit(state: TextEditState, output: []u8) Error!TextEditState {
    const range = activeTextReplaceRange(state);
    if (!range.isCollapsed(state.text.len)) return replaceTextEditRange(state, range, "", output, null, 0);

    const caret = snapTextCaretOffset(state.text, state.selection.focus);
    if (caret >= state.text.len) return .{ .text = state.text, .selection = TextSelection.collapsed(state.text.len), .composition = null };
    return replaceTextEditRange(state, TextRange.init(caret, nextTextCaretOffset(state.text, caret)), "", output, null, 0);
}

fn deleteWordBackwardTextEdit(state: TextEditState, output: []u8) Error!TextEditState {
    const range = activeTextReplaceRange(state);
    if (!range.isCollapsed(state.text.len)) return replaceTextEditRange(state, range, "", output, null, 0);

    const caret = snapTextCaretOffset(state.text, state.selection.focus);
    if (caret == 0) return .{ .text = state.text, .selection = TextSelection.collapsed(0), .composition = null };
    return replaceTextEditRange(state, TextRange.init(previousTextWordOffset(state.text, caret), caret), "", output, null, 0);
}

fn deleteWordForwardTextEdit(state: TextEditState, output: []u8) Error!TextEditState {
    const range = activeTextReplaceRange(state);
    if (!range.isCollapsed(state.text.len)) return replaceTextEditRange(state, range, "", output, null, 0);

    const caret = snapTextCaretOffset(state.text, state.selection.focus);
    if (caret >= state.text.len) return .{ .text = state.text, .selection = TextSelection.collapsed(state.text.len), .composition = null };
    return replaceTextEditRange(state, TextRange.init(caret, nextTextWordOffset(state.text, caret)), "", output, null, 0);
}

fn moveTextCaret(state: TextEditState, move: TextCaretMove) TextEditState {
    const range = state.selection.range(state.text.len);
    const focus = snapTextCaretOffset(state.text, state.selection.focus);
    const target = switch (move.direction) {
        .previous => if (!move.extend and !range.isCollapsed(state.text.len)) range.start else previousTextCaretOffset(state.text, focus),
        .next => if (!move.extend and !range.isCollapsed(state.text.len)) range.end else nextTextCaretOffset(state.text, focus),
        .previous_word => if (!move.extend and !range.isCollapsed(state.text.len)) range.start else previousTextWordOffset(state.text, focus),
        .next_word => if (!move.extend and !range.isCollapsed(state.text.len)) range.end else nextTextWordOffset(state.text, focus),
        .start => 0,
        .end => state.text.len,
    };
    const selection = if (move.extend)
        TextSelection{ .anchor = state.selection.anchor, .focus = target }
    else
        TextSelection.collapsed(target);
    return .{
        .text = state.text,
        .selection = snapTextCaretSelection(state.text, selection),
        .composition = null,
    };
}

fn replaceTextRange(source: []const u8, range: TextRange, replacement: []const u8, output: []u8) Error!TextReplaceResult {
    const snapped = snapTextRange(source, range);
    const prefix_len = snapped.start;
    const suffix = source[snapped.end..];
    const suffix_start = prefix_len + replacement.len;
    const next_len = prefix_len + replacement.len + suffix.len;
    if (next_len > output.len) return error.TextEditBufferTooSmall;

    if (suffix_start > snapped.end) {
        std.mem.copyBackwards(u8, output[suffix_start..next_len], suffix);
        std.mem.copyForwards(u8, output[0..prefix_len], source[0..prefix_len]);
        std.mem.copyForwards(u8, output[prefix_len..suffix_start], replacement);
    } else {
        std.mem.copyForwards(u8, output[0..prefix_len], source[0..prefix_len]);
        std.mem.copyForwards(u8, output[prefix_len..suffix_start], replacement);
        std.mem.copyForwards(u8, output[suffix_start..next_len], suffix);
    }
    return .{
        .text = output[0..next_len],
        .inserted_range = TextRange.init(prefix_len, suffix_start),
    };
}

pub fn snapTextSelection(text: []const u8, selection: TextSelection) TextSelection {
    return .{
        .anchor = snapTextOffset(text, selection.anchor),
        .focus = snapTextOffset(text, selection.focus),
        .affinity = selection.affinity,
    };
}

/// Snap a caret to a valid UTF-8 boundary that cannot split a CRLF hard
/// line ending. Layout represents the painted end of a CRLF line at the
/// LF-side byte offset; editing canonicalizes that position before CR.
pub fn snapTextCaretPosition(text: []const u8, position: TextCaretPosition) TextCaretPosition {
    const offset = snapTextOffset(text, position.offset);
    if (offset > 0 and
        offset < text.len and
        text[offset] == '\n' and
        text[offset - 1] == '\r')
    {
        return .{ .offset = offset - 1, .affinity = .upstream };
    }
    return .{ .offset = offset, .affinity = position.affinity };
}

/// Snap both editable selection endpoints to caret-safe boundaries. This
/// is deliberately separate from `snapTextSelection`: non-editing text
/// ranges may still address either scalar byte of a CRLF delimiter.
pub fn snapTextCaretSelection(text: []const u8, selection: TextSelection) TextSelection {
    const focus = snapTextCaretPosition(text, .{
        .offset = selection.focus,
        .affinity = selection.affinity,
    });
    return .{
        .anchor = snapTextCaretOffset(text, selection.anchor),
        .focus = focus.offset,
        .affinity = focus.affinity,
    };
}

fn snapTextCaretOffset(text: []const u8, offset: usize) usize {
    return snapTextCaretPosition(text, .{ .offset = offset }).offset;
}

pub fn snapTextRange(text: []const u8, range: TextRange) TextRange {
    const normalized = range.normalized(text.len);
    return TextRange.init(
        snapTextOffset(text, normalized.start),
        snapTextOffset(text, normalized.end),
    ).normalized(text.len);
}

pub fn previousTextOffset(text: []const u8, offset: usize) usize {
    var cursor = snapTextOffset(text, offset);
    if (cursor == 0) return 0;
    cursor -= 1;
    while (cursor > 0 and isUtf8ContinuationByte(text[cursor])) {
        cursor -= 1;
    }
    return cursor;
}

pub fn nextTextOffset(text: []const u8, offset: usize) usize {
    const cursor = snapTextOffset(text, offset);
    if (cursor >= text.len) return text.len;
    const next = @min(text.len, cursor + utf8SequenceLength(text[cursor]));
    // Invalid UTF-8 must never stall or reverse the walk: an orphan
    // continuation byte at `offset` snaps back to the previous lead,
    // whose sequence length can land at or before `offset` — and every
    // scalar loop over this function (glyph-atlas planning, line wrap,
    // caret movement) would spin forever on one stray 0x80 byte. Such
    // bytes advance one byte instead: the fallback-scalar rule.
    if (next <= offset) return @min(text.len, offset + 1);
    return next;
}

/// Caret editing treats CRLF as one hard-line boundary even though layout
/// still walks both scalar bytes to recognize and paint that boundary.
fn previousTextCaretOffset(text: []const u8, offset: usize) usize {
    const previous = previousTextOffset(text, offset);
    if (previous > 0 and text[previous] == '\n' and text[previous - 1] == '\r') {
        return previous - 1;
    }
    return previous;
}

fn nextTextCaretOffset(text: []const u8, offset: usize) usize {
    const cursor = snapTextOffset(text, offset);
    if (cursor < text.len and text[cursor] == '\r' and cursor + 1 < text.len and text[cursor + 1] == '\n') {
        return cursor + 2;
    }
    return nextTextOffset(text, cursor);
}

pub fn previousTextWordOffset(text: []const u8, offset: usize) usize {
    var cursor = snapTextOffset(text, offset);
    while (cursor > 0) {
        const previous = previousTextOffset(text, cursor);
        if (textOffsetStartsWord(text, previous)) break;
        cursor = previous;
    }
    while (cursor > 0) {
        const previous = previousTextOffset(text, cursor);
        if (!textOffsetStartsWord(text, previous)) break;
        cursor = previous;
    }
    return cursor;
}

pub fn nextTextWordOffset(text: []const u8, offset: usize) usize {
    var cursor = snapTextOffset(text, offset);
    while (cursor < text.len and !textOffsetStartsWord(text, cursor)) {
        cursor = nextTextOffset(text, cursor);
    }
    while (cursor < text.len and textOffsetStartsWord(text, cursor)) {
        cursor = nextTextOffset(text, cursor);
    }
    return cursor;
}

pub fn snapTextOffset(text: []const u8, offset: usize) usize {
    var cursor = @min(offset, text.len);
    while (cursor > 0 and cursor < text.len and isUtf8ContinuationByte(text[cursor])) {
        cursor -= 1;
    }
    return cursor;
}

pub fn utf8SequenceLength(lead: u8) usize {
    if ((lead & 0x80) == 0) return 1;
    if ((lead & 0xe0) == 0xc0) return 2;
    if ((lead & 0xf0) == 0xe0) return 3;
    if ((lead & 0xf8) == 0xf0) return 4;
    return 1;
}

pub fn isUtf8ContinuationByte(byte: u8) bool {
    return (byte & 0xc0) == 0x80;
}

/// The three character classes the double-click gesture selects runs
/// of. `word` is deliberately the SAME class the caret's word-jump
/// (`previousTextWordOffset`/`nextTextWordOffset`) walks — ASCII
/// alphanumerics, `_`, and every non-ASCII codepoint — so a
/// double-click and an alt+arrow agree on where a word ends. The
/// non-word remainder splits in two: whitespace runs and punctuation
/// clusters select separately, matching platform text fields (a
/// double-click between words selects the gap, not the neighbors).
const TextRunClass = enum { word, space, other };

/// Class of the codepoint whose UTF-8 sequence contains `offset`
/// (continuation bytes snap back to their lead). Null past the end of
/// the text. Multibyte sequences classify by their lead byte alone —
/// all their bytes have the high bit set, so a run never splits a
/// codepoint.
fn textRunClassAt(text: []const u8, offset: usize) ?TextRunClass {
    const cursor = snapTextOffset(text, offset);
    if (cursor >= text.len) return null;
    const lead = text[cursor];
    if ((lead & 0x80) != 0) return .word;
    if (std.ascii.isAlphanumeric(lead) or lead == '_') return .word;
    if (std.ascii.isWhitespace(lead)) return .space;
    return .other;
}

/// The double-click selection: the run of same-class codepoints under
/// `offset` (word characters, whitespace, or punctuation — see
/// `TextRunClass`). A click at or past the end of the text selects the
/// trailing run, the platform text-field convention. Anchor is the run
/// start and focus the run end, so a subsequent shift-arrow extends
/// forward from the word.
pub fn textWordSelectionAtOffset(text: []const u8, offset: usize) TextSelection {
    if (text.len == 0) return TextSelection.collapsed(0);
    var cursor = snapTextOffset(text, offset);
    if (cursor >= text.len) cursor = previousTextOffset(text, text.len);
    const class = textRunClassAt(text, cursor) orelse return TextSelection.collapsed(text.len);
    var start = cursor;
    while (start > 0) {
        const previous = previousTextOffset(text, start);
        const previous_class = textRunClassAt(text, previous) orelse break;
        if (previous_class != class) break;
        start = previous;
    }
    var end = nextTextOffset(text, cursor);
    while (end < text.len) {
        const next_class = textRunClassAt(text, end) orelse break;
        if (next_class != class) break;
        end = nextTextOffset(text, end);
    }
    return .{ .anchor = start, .focus = end };
}

/// The triple-click selection in a multi-line editor: the hard-newline
/// delimited line containing `offset`. The trailing newline stays
/// OUTSIDE the selection (pinned: deleting a triple-click selection
/// empties the line but keeps the line break, and copy takes the line's
/// text without a stray terminator). Scanning raw bytes for `\n` is
/// UTF-8 safe — 0x0A never appears inside a multibyte sequence.
pub fn textLineSelectionAtOffset(text: []const u8, offset: usize) TextSelection {
    return .{
        .anchor = textLineStartOffset(text, offset),
        .focus = textLineEndOffset(text, offset),
    };
}

/// Start of the hard-newline-delimited line containing `offset`. The
/// offset is snapped to a UTF-8 boundary first; scanning for ASCII LF is
/// byte-safe because it cannot occur inside a multibyte sequence.
pub fn textLineStartOffset(text: []const u8, offset: usize) usize {
    var cursor = snapTextOffset(text, offset);
    while (cursor > 0 and text[cursor - 1] != '\n') cursor -= 1;
    return cursor;
}

/// End of the hard-newline-delimited line containing `offset`, excluding
/// its line break. CRLF documents exclude both bytes from the line.
pub fn textLineEndOffset(text: []const u8, offset: usize) usize {
    var cursor = snapTextOffset(text, offset);
    while (cursor < text.len and text[cursor] != '\n') cursor += 1;
    if (cursor > 0 and cursor < text.len and text[cursor - 1] == '\r') return cursor - 1;
    return cursor;
}

fn textOffsetStartsWord(text: []const u8, offset: usize) bool {
    const class = textRunClassAt(text, offset) orelse return false;
    return class == .word;
}

/// Fixed-capacity editor state for elm-style text fields: the model applies
/// every `TextInputEvent` and stays an exact mirror of the runtime's editor
/// (text, selection, and composition), so rebuild reconciliation preserves
/// runtime caret state while the texts match and model-side changes (like
/// clearing on submit) win.
pub fn TextBuffer(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        storage: [capacity]u8 = undefined,
        len: usize = 0,
        selection: TextSelection = .{},
        composition: ?TextRange = null,
        /// True when the most recent `apply` had to clamp (insertions) or
        /// reject (other edits) the event to stay within capacity. Loud
        /// seam for paste: check after applying a clipboard insert.
        truncated: bool = false,

        pub fn init(initial: []const u8) Self {
            var self = Self{};
            self.set(initial);
            return self;
        }

        pub fn text(self: *const Self) []const u8 {
            return self.storage[0..self.len];
        }

        pub fn isEmpty(self: *const Self) bool {
            return std.mem.trim(u8, self.text(), " \t").len == 0;
        }

        /// Apply one edit event. Insertions that would exceed capacity are
        /// clamped to the bytes that fit (at a UTF-8 boundary); any other
        /// over-capacity edit is rejected. Both set `truncated`.
        pub fn apply(self: *Self, event: TextInputEvent) void {
            var scratch: [capacity]u8 = undefined;
            const state = TextEditState{
                .text = self.text(),
                .selection = self.selection,
                .composition = self.composition,
            };
            const next = applyTextInputEvent(state, event, &scratch) catch {
                self.truncated = true;
                const clamped = clampedInsertEvent(state, event, capacity) orelse return;
                const next_clamped = applyTextInputEvent(state, clamped, &scratch) catch return;
                self.commit(next_clamped);
                return;
            };
            self.truncated = false;
            self.commit(next);
        }

        fn commit(self: *Self, next: TextEditState) void {
            const next_len = @min(next.text.len, capacity);
            std.mem.copyForwards(u8, self.storage[0..next_len], next.text[0..next_len]);
            self.len = next_len;
            self.selection = next.selection;
            self.composition = next.composition;
        }

        pub fn set(self: *Self, new_text: []const u8) void {
            const next_len = @min(new_text.len, capacity);
            std.mem.copyForwards(u8, self.storage[0..next_len], new_text[0..next_len]);
            self.len = next_len;
            self.selection = TextSelection.collapsed(next_len);
            self.composition = null;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
            self.selection = .{};
            self.composition = null;
        }
    };
}

/// For an over-capacity `.insert_text`, the same event with its payload
/// clamped (at a UTF-8 boundary) to the bytes that fit alongside the text
/// the edit keeps. Null when the event is not an insertion or when
/// nothing fits.
fn clampedInsertEvent(state: TextEditState, event: TextInputEvent, capacity: usize) ?TextInputEvent {
    const insertion = switch (event) {
        .insert_text => |text| text,
        else => return null,
    };
    const normalized = normalizeTextEditState(state);
    const replaced = activeTextReplaceRange(normalized).byteLen(normalized.text.len);
    const kept = normalized.text.len - replaced;
    if (kept >= capacity) return null;
    const available = capacity - kept;
    if (available >= insertion.len) return null;
    const clamped_len = snapTextOffset(insertion, available);
    if (clamped_len == 0) return null;
    return .{ .insert_text = insertion[0..clamped_len] };
}

test "textWordSelectionAtOffset selects word, whitespace, and punctuation runs" {
    const text = "hello  world, ok";
    // Middle of a word selects the whole word.
    try std.testing.expectEqualDeep(TextSelection{ .anchor = 0, .focus = 5 }, textWordSelectionAtOffset(text, 2));
    // The word's first byte belongs to the word too.
    try std.testing.expectEqualDeep(TextSelection{ .anchor = 0, .focus = 5 }, textWordSelectionAtOffset(text, 0));
    // A click on whitespace selects the whitespace run, not a neighbor.
    try std.testing.expectEqualDeep(TextSelection{ .anchor = 5, .focus = 7 }, textWordSelectionAtOffset(text, 5));
    try std.testing.expectEqualDeep(TextSelection{ .anchor = 5, .focus = 7 }, textWordSelectionAtOffset(text, 6));
    // Punctuation selects the punctuation cluster.
    try std.testing.expectEqualDeep(TextSelection{ .anchor = 12, .focus = 13 }, textWordSelectionAtOffset(text, 12));
    // At (or past) the end of the text the trailing run selects.
    try std.testing.expectEqualDeep(TextSelection{ .anchor = 14, .focus = 16 }, textWordSelectionAtOffset(text, text.len));
    try std.testing.expectEqualDeep(TextSelection{ .anchor = 14, .focus = 16 }, textWordSelectionAtOffset(text, 99));
    // Empty text collapses at 0.
    try std.testing.expectEqualDeep(TextSelection.collapsed(0), textWordSelectionAtOffset("", 0));
}

test "textWordSelectionAtOffset never splits multibyte codepoints" {
    // "héllo wörld" — é and ö are 2-byte codepoints; non-ASCII is word
    // class, so accented words select whole.
    const text = "h\xc3\xa9llo w\xc3\xb6rld";
    try std.testing.expectEqualDeep(TextSelection{ .anchor = 0, .focus = 6 }, textWordSelectionAtOffset(text, 0));
    // Offset landing on the continuation byte snaps to its codepoint.
    try std.testing.expectEqualDeep(TextSelection{ .anchor = 0, .focus = 6 }, textWordSelectionAtOffset(text, 2));
    try std.testing.expectEqualDeep(TextSelection{ .anchor = 7, .focus = 13 }, textWordSelectionAtOffset(text, 9));
    // Underscores join words, the caret word-jump's rule.
    try std.testing.expectEqualDeep(TextSelection{ .anchor = 0, .focus = 9 }, textWordSelectionAtOffset("snake_car go", 3));
}

test "textLineSelectionAtOffset selects the newline-delimited line without its break" {
    const text = "first line\nsecond\n\nfourth";
    try std.testing.expectEqualDeep(TextSelection{ .anchor = 0, .focus = 10 }, textLineSelectionAtOffset(text, 4));
    try std.testing.expectEqualDeep(TextSelection{ .anchor = 11, .focus = 17 }, textLineSelectionAtOffset(text, 13));
    // A click on an empty line collapses on it (nothing to select).
    try std.testing.expectEqualDeep(TextSelection{ .anchor = 18, .focus = 18 }, textLineSelectionAtOffset(text, 18));
    // The last line has no trailing newline; it still selects fully.
    try std.testing.expectEqualDeep(TextSelection{ .anchor = 19, .focus = 25 }, textLineSelectionAtOffset(text, 22));

    try std.testing.expectEqual(@as(usize, 11), textLineStartOffset(text, 15));
    try std.testing.expectEqual(@as(usize, 17), textLineEndOffset(text, 15));
    try std.testing.expectEqual(@as(usize, 3), textLineEndOffset("one\r\ntwo", 1));
    // A bare CR at EOF is content, not the first half of a CRLF break.
    try std.testing.expectEqual(@as(usize, 4), textLineEndOffset("one\r", 1));
}

test "caret movement and deletion cross CRLF atomically" {
    const text = "one\r\ntwo";
    var scratch: [32]u8 = undefined;

    // Programmatic selections and raw edit state cannot expose the byte
    // between CR and LF as a caret or selection endpoint.
    const inside_break = TextEditState{
        .text = text,
        .selection = TextSelection.collapsed(4),
    };
    const selected_inside_break = try inside_break.apply(.{
        .set_selection = TextSelection.collapsed(4),
    }, &scratch);
    try std.testing.expectEqualDeep(TextSelection.collapsed(3), selected_inside_break.selection);
    const inserted_inside_break = try inside_break.apply(.{ .insert_text = "X" }, &scratch);
    try std.testing.expectEqualStrings("oneX\r\ntwo", inserted_inside_break.text);
    try std.testing.expectEqualDeep(TextSelection.collapsed(4), inserted_inside_break.selection);

    try std.testing.expectEqualDeep(
        TextSelection{ .anchor = 3, .focus = 5 },
        snapTextCaretSelection(text, .{ .anchor = 4, .focus = 5 }),
    );

    const before_break = TextEditState{
        .text = text,
        .selection = TextSelection.collapsed(3),
    };
    const moved_next = try before_break.apply(.{ .move_caret = .{ .direction = .next } }, &scratch);
    try std.testing.expectEqualDeep(TextSelection.collapsed(5), moved_next.selection);
    const deleted_forward = try before_break.apply(.delete_forward, &scratch);
    try std.testing.expectEqualStrings("onetwo", deleted_forward.text);
    try std.testing.expectEqualDeep(TextSelection.collapsed(3), deleted_forward.selection);

    const after_break = TextEditState{
        .text = text,
        .selection = TextSelection.collapsed(5),
    };
    const moved_previous = try after_break.apply(.{ .move_caret = .{ .direction = .previous } }, &scratch);
    try std.testing.expectEqualDeep(TextSelection.collapsed(3), moved_previous.selection);
    const deleted_backward = try after_break.apply(.delete_backward, &scratch);
    try std.testing.expectEqualStrings("onetwo", deleted_backward.text);
    try std.testing.expectEqualDeep(TextSelection.collapsed(3), deleted_backward.selection);
}

test "TextBuffer mirrors edits, truncates at capacity, and clears" {
    var buffer = TextBuffer(8){};
    buffer.apply(.{ .insert_text = "hi" });
    buffer.apply(.{ .insert_text = " there" });
    try @import("std").testing.expectEqualStrings("hi there", buffer.text());
    try @import("std").testing.expect(!buffer.truncated);

    // Over-capacity edits truncate rather than fail, and say so.
    buffer.apply(.{ .insert_text = "!" });
    try @import("std").testing.expectEqual(@as(usize, 8), buffer.text().len);
    try @import("std").testing.expect(buffer.truncated);

    buffer.apply(.delete_backward);
    try @import("std").testing.expectEqualStrings("hi ther", buffer.text());
    try @import("std").testing.expect(!buffer.truncated);

    buffer.clear();
    try @import("std").testing.expectEqualStrings("", buffer.text());
    try @import("std").testing.expect(buffer.isEmpty());
}

test "TextBuffer clamps over-capacity insertions at a UTF-8 boundary" {
    const std_testing = @import("std").testing;
    var buffer = TextBuffer(8){};
    buffer.apply(.{ .insert_text = "hi" });
    // 8-byte insertion into 6 available bytes clamps to what fits.
    buffer.apply(.{ .insert_text = " there!!" });
    try std_testing.expectEqualStrings("hi there", buffer.text());
    try std_testing.expect(buffer.truncated);
    try std_testing.expectEqualDeep(TextSelection.collapsed(8), buffer.selection);

    // Multi-byte codepoints never split: "é" is 2 bytes and only 1 fits.
    var accents = TextBuffer(3){};
    accents.apply(.{ .insert_text = "ab" });
    accents.apply(.{ .insert_text = "\xc3\xa9\xc3\xa9" });
    try std_testing.expectEqualStrings("ab", accents.text());
    try std_testing.expect(accents.truncated);

    // A selection being replaced frees its bytes for the insertion.
    var replace = TextBuffer(8){};
    replace.apply(.{ .insert_text = "abcdefgh" });
    replace.apply(.{ .set_selection = .{ .anchor = 0, .focus = 8 } });
    replace.apply(.{ .insert_text = "0123456789" });
    try std_testing.expectEqualStrings("01234567", replace.text());
    try std_testing.expect(replace.truncated);
}
