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

pub const TextSelection = struct {
    anchor: usize = 0,
    focus: usize = 0,

    pub fn collapsed(offset: usize) TextSelection {
        return .{ .anchor = offset, .focus = offset };
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
            .selection = snapTextSelection(normalized.text, selection),
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
        .selection = snapTextSelection(state.text, state.selection),
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
    const cursor = snapTextOffset(result.text, result.inserted_range.start + @min(cursor_offset, replacement.len));
    return .{
        .text = result.text,
        .selection = TextSelection.collapsed(cursor),
        .composition = composition,
    };
}

fn setTextComposition(state: TextEditState, composition: TextCompositionUpdate, output: []u8) Error!TextEditState {
    const range = activeTextReplaceRange(state);
    const cursor = snapTextOffset(composition.text, composition.cursor orelse composition.text.len);
    const result = try replaceTextRange(state.text, range, composition.text, output);
    const absolute_cursor = snapTextOffset(result.text, result.inserted_range.start + cursor);
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
        .selection = TextSelection.collapsed(result.inserted_range.start),
        .composition = null,
    };
}

fn deleteBackwardTextEdit(state: TextEditState, output: []u8) Error!TextEditState {
    const range = activeTextReplaceRange(state);
    if (!range.isCollapsed(state.text.len)) return replaceTextEditRange(state, range, "", output, null, 0);

    const caret = snapTextOffset(state.text, state.selection.focus);
    if (caret == 0) return .{ .text = state.text, .selection = TextSelection.collapsed(0), .composition = null };
    return replaceTextEditRange(state, TextRange.init(previousTextOffset(state.text, caret), caret), "", output, null, 0);
}

fn deleteForwardTextEdit(state: TextEditState, output: []u8) Error!TextEditState {
    const range = activeTextReplaceRange(state);
    if (!range.isCollapsed(state.text.len)) return replaceTextEditRange(state, range, "", output, null, 0);

    const caret = snapTextOffset(state.text, state.selection.focus);
    if (caret >= state.text.len) return .{ .text = state.text, .selection = TextSelection.collapsed(state.text.len), .composition = null };
    return replaceTextEditRange(state, TextRange.init(caret, nextTextOffset(state.text, caret)), "", output, null, 0);
}

fn deleteWordBackwardTextEdit(state: TextEditState, output: []u8) Error!TextEditState {
    const range = activeTextReplaceRange(state);
    if (!range.isCollapsed(state.text.len)) return replaceTextEditRange(state, range, "", output, null, 0);

    const caret = snapTextOffset(state.text, state.selection.focus);
    if (caret == 0) return .{ .text = state.text, .selection = TextSelection.collapsed(0), .composition = null };
    return replaceTextEditRange(state, TextRange.init(previousTextWordOffset(state.text, caret), caret), "", output, null, 0);
}

fn deleteWordForwardTextEdit(state: TextEditState, output: []u8) Error!TextEditState {
    const range = activeTextReplaceRange(state);
    if (!range.isCollapsed(state.text.len)) return replaceTextEditRange(state, range, "", output, null, 0);

    const caret = snapTextOffset(state.text, state.selection.focus);
    if (caret >= state.text.len) return .{ .text = state.text, .selection = TextSelection.collapsed(state.text.len), .composition = null };
    return replaceTextEditRange(state, TextRange.init(caret, nextTextWordOffset(state.text, caret)), "", output, null, 0);
}

fn moveTextCaret(state: TextEditState, move: TextCaretMove) TextEditState {
    const range = state.selection.range(state.text.len);
    const focus = snapTextOffset(state.text, state.selection.focus);
    const target = switch (move.direction) {
        .previous => if (!move.extend and !range.isCollapsed(state.text.len)) range.start else previousTextOffset(state.text, focus),
        .next => if (!move.extend and !range.isCollapsed(state.text.len)) range.end else nextTextOffset(state.text, focus),
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
        .selection = snapTextSelection(state.text, selection),
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
    };
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
    return @min(text.len, cursor + utf8SequenceLength(text[cursor]));
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

fn textOffsetStartsWord(text: []const u8, offset: usize) bool {
    const cursor = snapTextOffset(text, offset);
    if (cursor >= text.len) return false;
    const lead = text[cursor];
    if ((lead & 0x80) != 0) return true;
    return std.ascii.isAlphanumeric(lead) or lead == '_';
}
