const std = @import("std");
const code_model = @import("code.zig");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const text_spans = @import("text_spans.zig");
const ui_model = @import("ui.zig");
const widget_metrics = @import("widget_metrics.zig");

const testing = std.testing;
const Ui = ui_model.Ui(enum { noop });

fn spanWithFragment(spans: []const canvas.TextSpan, fragment: []const u8) ?canvas.TextSpan {
    for (spans) |span| {
        if (std.mem.indexOf(u8, span.text, fragment) != null) return span;
    }
    return null;
}

test "diff line specs accept one-based values and compact ranges" {
    var storage: [code_model.max_diff_lines]usize = undefined;
    const lines = code_model.parseLineNumberSpec("2-4, 7, 3", &storage).?;
    try testing.expectEqualSlices(usize, &.{ 2, 3, 4, 7 }, lines);
    try testing.expectEqual(@as(usize, 0), code_model.parseLineNumberSpec("", &storage).?.len);

    const invalid = [_][]const u8{ "0", "4-2", "1-129", "1,,2", "2-", "2-3-4", "nope" };
    for (invalid) |spec| try testing.expect(code_model.parseLineNumberSpec(spec, &storage) == null);
}

test "widget diff metadata round-trips both 128-line masks" {
    var widget = canvas.Widget{ .kind = .text, .code_line_number_digits = 3 };
    const expected = canvas.CodeDiffLines{
        .added = (@as(u128, 1) << 127) | (@as(u128, 1) << 64) | 1,
        .removed = (@as(u128, 1) << 126) | (@as(u128, 1) << 63) | 2,
    };
    widget.setCodeDiffLines(expected);

    try testing.expectEqual(@as(u8, 3), widget.codeLineNumberDigits());
    try testing.expectEqual(expected.added, widget.codeDiffLines().?.added);
    try testing.expectEqual(expected.removed, widget.codeDiffLines().?.removed);
}

fn colorAtOffset(spans: []const canvas.TextSpan, offset: usize) ?canvas.TextSpanColor {
    var cursor: usize = 0;
    for (spans) |span| {
        if (offset < cursor + span.text.len) return span.color;
        cursor += span.text.len;
    }
    return null;
}

fn findByKind(widget: canvas.Widget, kind: canvas.WidgetKind) ?canvas.Widget {
    if (widget.kind == kind) return widget;
    for (widget.children) |child| {
        if (findByKind(child, kind)) |found| return found;
    }
    return null;
}

fn findByText(widget: canvas.Widget, text: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, text)) |found| return found;
    }
    return null;
}

fn countByKind(widget: canvas.Widget, kind: canvas.WidgetKind) usize {
    var count: usize = @intFromBool(widget.kind == kind);
    for (widget.children) |child| count += countByKind(child, kind);
    return count;
}

fn countTextSpans(widget: canvas.Widget) usize {
    var count = widget.spans.len;
    for (widget.children) |child| count += countTextSpans(child);
    return count;
}

fn appendTextWidgets(widget: canvas.Widget, output: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    if (widget.kind == .text) try output.appendSlice(allocator, widget.text);
    for (widget.children) |child| try appendTextWidgets(child, output, allocator);
}

fn displayListTextBytes(display_list: canvas.DisplayList) usize {
    var count: usize = 0;
    for (display_list.commands) |command| {
        switch (command) {
            .draw_text => |draw| count += draw.text.len,
            else => {},
        }
    }
    return count;
}

fn codeFontSensitiveMeasure(context: ?*anyopaque, font_id: canvas.FontId, size: f32, text: []const u8) f32 {
    _ = context;
    const advance: f32 = if (font_id == canvas.default_mono_font_id) 1 else 0.1;
    return size * advance * @as(f32, @floatFromInt(text.len));
}

const code_font_sensitive_measure = canvas.TextMeasureProvider{ .measure_fn = codeFontSensitiveMeasure };

const CodeWidthMeasure = struct {
    width_calls: usize = 0,
    advance_calls: usize = 0,

    fn width(context: ?*anyopaque, _: canvas.FontId, size: f32, text: []const u8) f32 {
        const self: *CodeWidthMeasure = @ptrCast(@alignCast(context.?));
        self.width_calls += 1;
        return size * @as(f32, @floatFromInt(text.len));
    }

    fn advances(context: ?*anyopaque, _: canvas.FontId, size: f32, text: []const u8, out: []f32) bool {
        const self: *CodeWidthMeasure = @ptrCast(@alignCast(context.?));
        self.advance_calls += 1;
        for (text, 0..) |byte, index| out[index] = if (byte == '\n') 0 else size;
        return true;
    }
};

fn expectCompleteSpanLayouts(widget: canvas.Widget) !void {
    if (widget.kind == .text and widget.spans.len > 0) {
        var runs: [text_spans.max_text_span_runs_per_paragraph]text_spans.TextSpanRun = undefined;
        const layout = text_spans.layoutTextSpans(
            widget.spans,
            .{ .size = 14, .max_width = 1 },
            &runs,
        );
        try testing.expect(!layout.truncated);
        try testing.expect(layout.line_count <= text_spans.max_text_span_lines_per_paragraph);
    }
    for (widget.children) |child| try expectCompleteSpanLayouts(child);
}

fn allTextSpansHaveColor(widget: canvas.Widget, color: canvas.TextSpanColor) bool {
    if (widget.kind == .text and widget.spans.len > 0) {
        for (widget.spans) |span| {
            if (span.color != color) return false;
        }
    }
    for (widget.children) |child| {
        if (!allTextSpansHaveColor(child, color)) return false;
    }
    return true;
}

fn expectCodeTabInsertion(source: []const u8, expected: []const u8) !void {
    const edit = canvas.widgetCodeTabTextEditEvent(.{
        .kind = .textarea,
        .runtime_flags = .{ .code_editor = true },
        .text = source,
    }, .{
        .phase = .key_down,
        .key = "tab",
    }).?;
    switch (edit) {
        .insert_text => |text| try testing.expectEqualStrings(expected, text),
        else => return error.TestExpectedEqual,
    }
}

test "HTML and JSX highlighting distinguishes tags attributes expressions and strings" {
    const source =
        \\<Accordion defaultValue={["item-1"]}>
        \\  <AccordionTrigger disabled={true}>Accessible?</AccordionTrigger>
        \\</Accordion>
    ;
    var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const spans = code_model.highlight(source, code_model.languageFromName("tsx"), &storage);

    try testing.expectEqual(code_model.Language.jsx, code_model.languageFromName("jsx"));
    try testing.expectEqual(code_model.Language.tsx, code_model.languageFromName("tsx"));
    try testing.expectEqual(code_model.Language.javascript, code_model.languageFromName("mjs"));
    try testing.expectEqual(code_model.Language.yaml, code_model.languageFromName("yaml"));
    try testing.expectEqual(code_model.Language.yaml, code_model.languageFromName("yml"));
    try testing.expectEqual(code_model.Language.markdown, code_model.languageFromName("md"));
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "Accordion").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_function, spanWithFragment(spans, "defaultValue").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "\"item-1\"").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "true").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_plain, spanWithFragment(spans, "Accessible?").?.color.?);
}

test "YAML highlighting distinguishes mapping keys scalars symbols and comments" {
    const source =
        \\---
        \\name: native
        \\runs-on: macos-15
        \\enabled: true
        \\empty: ~
        \\defaults: &defaults
        \\command: "zig build test"
        \\use: *defaults
        \\url: https://example.test/#section # trailing comment
    ;
    var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const spans = code_model.highlight(source, .yaml, &storage);

    try testing.expectEqual(canvas.TextSpanColor.syntax_keyword, spanWithFragment(spans, "---").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_property, spanWithFragment(spans, "name").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_property, spanWithFragment(spans, "runs-on").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "true").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "~").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_constant, spanWithFragment(spans, "&defaults").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_constant, spanWithFragment(spans, "*defaults").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "\"zig build test\"").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_plain, spanWithFragment(spans, "#section").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_comment, spanWithFragment(spans, "# trailing comment").?.color.?);
}

test "TSX highlights top-level TypeScript and embedded JSX in one grammar" {
    const source =
        \\import type { Metadata } from "next";
        \\export default function RootLayout() { return <html lang="en" />; }
    ;
    var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const spans = code_model.highlight(source, .tsx, &storage);

    inline for (.{ "import", "type", "from", "export", "default", "function", "return" }) |keyword| {
        try testing.expectEqual(
            canvas.TextSpanColor.syntax_keyword,
            spanWithFragment(spans, keyword).?.color.?,
        );
    }
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "\"next\"").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_function, spanWithFragment(spans, "RootLayout").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "html").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_function, spanWithFragment(spans, "lang").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "\"en\"").?.color.?);
}

test "JSX relational less-than preserves expression state and nested tags" {
    const source = "<span>{count<limit ? <Low/> : <High/>}</span>";
    var state: code_model.HighlightState = .{};
    var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const spans = code_model.highlightWithState(source, .html, &storage, &state);

    try testing.expectEqual(canvas.TextSpanColor.syntax_plain, spanWithFragment(spans, "limit").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "Low").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "High").?.color.?);
    try testing.expectEqual(@as(usize, 0), state.html_expression_depth);
    try testing.expect(!state.html_in_tag);

    var chunked_state: code_model.HighlightState = .{};
    var first_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    _ = code_model.highlightWithState("<span>{count", .html, &first_storage, &chunked_state);
    var second_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const second = code_model.highlightWithState("<limit ? <Low/> : <High/>}</span>", .html, &second_storage, &chunked_state);
    try testing.expectEqual(canvas.TextSpanColor.syntax_plain, spanWithFragment(second, "limit").?.color.?);
    try testing.expectEqual(@as(usize, 0), chunked_state.html_expression_depth);
    try testing.expect(!chunked_state.html_in_tag);
}

test "TSX relational less-than at top level does not open a tag" {
    const source = "const ok=count<limit; const later=true;";
    var state: code_model.HighlightState = .{};
    var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const spans = code_model.highlightWithState(source, .tsx, &storage, &state);

    try testing.expectEqual(canvas.TextSpanColor.syntax_plain, spanWithFragment(spans, "limit").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_keyword, spanWithFragment(spans, "const").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "true").?.color.?);
    try testing.expect(!state.html_in_tag);

    var chunked_state: code_model.HighlightState = .{};
    var first_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    _ = code_model.highlightWithState("const ok=count", .tsx, &first_storage, &chunked_state);
    var second_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const second = code_model.highlightWithState("<limit; const later=true;", .tsx, &second_storage, &chunked_state);
    try testing.expectEqual(canvas.TextSpanColor.syntax_plain, spanWithFragment(second, "limit").?.color.?);
    try testing.expect(!chunked_state.html_in_tag);
}

test "JSX closing tags remain structural after plain text" {
    const source = "const view = <div>Hello<span>world</span></div>; const later = true;";
    var state: code_model.HighlightState = .{};
    var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const spans = code_model.highlightWithState(source, .tsx, &storage, &state);
    const closing_name = std.mem.lastIndexOf(u8, source, "div").?;
    const nested_opening_name = std.mem.indexOf(u8, source, "span").?;
    const nested_closing_name = std.mem.lastIndexOf(u8, source, "span").?;
    const later_name = std.mem.indexOf(u8, source, "later").?;

    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, colorAtOffset(spans, closing_name).?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, colorAtOffset(spans, nested_opening_name).?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, colorAtOffset(spans, nested_closing_name).?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_plain, colorAtOffset(spans, later_name).?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "true").?.color.?);
    try testing.expectEqual(@as(usize, 0), state.html_element_len);
    try testing.expect(!state.html_in_tag);
}

test "JSX regex comparisons inside elements do not become closing tags" {
    const source = "const view = <div>{value</x/.test(text) ? 'yes' : 'no'}</div>;";
    var state: code_model.HighlightState = .{};
    var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const spans = code_model.highlightWithState(source, .tsx, &storage, &state);
    const regex_name = std.mem.indexOf(u8, source, "x/").?;
    const closing_name = std.mem.lastIndexOf(u8, source, "div").?;

    try testing.expectEqual(canvas.TextSpanColor.syntax_plain, colorAtOffset(spans, regex_name).?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, colorAtOffset(spans, closing_name).?);
    try testing.expectEqual(@as(usize, 0), state.html_element_len);
    try testing.expectEqual(@as(usize, 0), state.html_expression_depth);
    try testing.expect(!state.html_in_tag);
}

test "Markdown highlighting distinguishes structure links code and comments" {
    const source =
        \\# Heading
        \\- [Native](https://native.dev) uses `code` and **emphasis**.
        \\<!-- note -->
        \\```zig
        \\const value = true;
        \\```
    ;
    var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const spans = code_model.highlight(source, .markdown, &storage);

    try testing.expectEqual(canvas.TextSpanColor.syntax_keyword, spanWithFragment(spans, "#").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_keyword, spanWithFragment(spans, "-").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_property, spanWithFragment(spans, "[").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "https://native.dev").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "`code`").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_keyword, spanWithFragment(spans, "**").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_comment, spanWithFragment(spans, "<!-- note -->").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_constant, spanWithFragment(spans, "zig").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "const value").?.color.?);
}

test "nested JSX attribute tags restore the enclosing opening tag" {
    const source = "<Comp render={<Inner />} disabled=\"yes\">";
    var state: code_model.HighlightState = .{};
    var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const spans = code_model.highlightWithState(source, .html, &storage, &state);

    try testing.expectEqual(
        canvas.TextSpanColor.syntax_literal,
        spanWithFragment(spans, "Inner").?.color.?,
    );
    try testing.expectEqual(
        canvas.TextSpanColor.syntax_function,
        spanWithFragment(spans, "disabled").?.color.?,
    );
    try testing.expectEqual(
        canvas.TextSpanColor.syntax_literal,
        spanWithFragment(spans, "\"yes\"").?.color.?,
    );
    try testing.expectEqual(@as(usize, 0), state.html_tag_context_len);
    try testing.expect(!state.html_in_tag);
}

test "HTML and JSX lexer state survives logical line boundaries" {
    var state: code_model.HighlightState = .{};
    var first_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    _ = code_model.highlightWithState("<Button variant=\"primary\"", .html, &first_storage, &state);
    try testing.expect(state.html_in_tag);

    var second_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const second = code_model.highlightWithState("  onPress={() => save()} disabled>", .html, &second_storage, &state);
    try testing.expectEqual(canvas.TextSpanColor.syntax_function, spanWithFragment(second, "onPress").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_function, spanWithFragment(second, "disabled").?.color.?);
    try testing.expect(!state.html_in_tag);
}

test "plain HTML attribute quotes close literally after backslashes" {
    const sources = [_][]const u8{
        "<div title=\"value\\\" disabled>",
        "<div title='value\\' disabled>",
    };
    for (sources) |source| {
        var state: code_model.HighlightState = .{};
        var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
        const spans = code_model.highlightWithState(source, .html, &storage, &state);
        try testing.expect(state.string_quote == null);
        try testing.expect(!state.html_in_tag);
        try testing.expectEqual(
            canvas.TextSpanColor.syntax_function,
            spanWithFragment(spans, "disabled").?.color.?,
        );
    }

    var jsx_state: code_model.HighlightState = .{};
    var jsx_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    _ = code_model.highlightWithState(
        "<div value={{ text: \"value\\\" still\" }} disabled>",
        .html,
        &jsx_storage,
        &jsx_state,
    );
    try testing.expect(jsx_state.string_quote == null);
    try testing.expect(!jsx_state.html_in_tag);
}

test "single-quoted escapes do not leak string state into the next line" {
    const source = "'\\''\nconst next = true;";
    const languages = [_]code_model.Language{
        .zig,
        .javascript,
        .typescript,
        .python,
        .rust,
        .c_like,
        .go,
    };
    for (languages) |language| {
        var state: code_model.HighlightState = .{};
        var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
        const spans = code_model.highlightWithState(source, language, &storage, &state);
        try testing.expect(state.string_quote == null);
        try testing.expectEqual(canvas.TextSpanColor.syntax_plain, spanWithFragment(spans, "next").?.color.?);
    }
}

test "Python literals keep their case-sensitive syntax role" {
    const source = "enabled = True\nmissing = None\ndisabled = False";
    var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const spans = code_model.highlight(source, .python, &storage);

    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "True").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "None").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "False").?.color.?);
}

test "Rust lifetimes do not open string state and character literals still highlight" {
    const lifetime_source = "fn borrow<'a>(value: &'a str) -> &'a str { value }\nconst next = true;";
    var lifetime_state: code_model.HighlightState = .{};
    var lifetime_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const lifetimes = code_model.highlightWithState(
        lifetime_source,
        .rust,
        &lifetime_storage,
        &lifetime_state,
    );
    try testing.expect(lifetime_state.string_quote == null);
    try testing.expectEqual(canvas.TextSpanColor.syntax_plain, spanWithFragment(lifetimes, "'a").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_keyword, spanWithFragment(lifetimes, "const").?.color.?);

    const character_source = "let escaped: char = '\\n'; let unicode: char = '🦀';";
    var character_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const characters = code_model.highlight(character_source, .rust, &character_storage);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(characters, "'\\n'").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(characters, "'🦀'").?.color.?);
}

test "HTML prose apostrophes stay prose and JSX content expressions highlight" {
    const source = "<p>It's {true}</p>";
    var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const spans = code_model.highlight(source, .html, &storage);

    try testing.expectEqual(canvas.TextSpanColor.syntax_plain, spanWithFragment(spans, "It's ").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "true").?.color.?);
}

test "token-dense logical line falls back without dropping source" {
    const source = "const a0=0; const a1=1; const a2=2; const a3=3; const a4=4; const a5=5; const a6=6; const a7=7; const a8=8;";
    var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const spans = code_model.highlight(source, .zig, &storage);
    var joined: std.ArrayListUnmanaged(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (spans) |span| try joined.appendSlice(testing.allocator, span.text);
    try testing.expectEqualStrings(source, joined.items);
    try testing.expectEqual(text_spans.max_text_spans_per_paragraph, spans.len);
    try testing.expectEqual(canvas.TextSpanColor.syntax_plain, spans[spans.len - 1].color.?);
}

test "token-dense fallback still updates lexer state" {
    const source = "const a0=0; const a1=1; const a2=2; const a3=3; const a4=4; const a5=5; const a6=6; const a7=7; const a8=8; /*";
    var state: code_model.HighlightState = .{};
    var first_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    _ = code_model.highlightWithState(source, .zig, &first_storage, &state);
    try testing.expect(state.block_comment);

    var second_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const second = code_model.highlightWithState("closed */ const next = true;", .zig, &second_storage, &state);
    try testing.expect(!state.block_comment);
    try testing.expectEqual(canvas.TextSpanColor.syntax_keyword, spanWithFragment(second, "const").?.color.?);
}

test "callables and object keys use variable syntax roles" {
    const source = "function render() { const variable = { color: true }; return variable; }";
    var storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const spans = code_model.highlight(source, .javascript, &storage);

    try testing.expectEqual(canvas.TextSpanColor.syntax_keyword, spanWithFragment(spans, "function").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_function, spanWithFragment(spans, "render").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_plain, spanWithFragment(spans, "variable").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_plain, spanWithFragment(spans, "color").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_literal, spanWithFragment(spans, "true").?.color.?);

    const typed_source = "const options: { enabled: boolean } = { enabled: true };";
    var typed_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const typed_spans = code_model.highlight(typed_source, .typescript, &typed_storage);
    try testing.expectEqual(canvas.TextSpanColor.syntax_plain, spanWithFragment(typed_spans, "options").?.color.?);
    try testing.expectEqual(canvas.TextSpanColor.syntax_plain, spanWithFragment(typed_spans, "enabled").?.color.?);

    var css_storage: [text_spans.max_text_spans_per_paragraph]canvas.TextSpan = undefined;
    const css_spans = code_model.highlight("body { color: red; }", .css, &css_storage);
    try testing.expectEqual(canvas.TextSpanColor.syntax_property, spanWithFragment(css_spans, "color").?.color.?);
}

test "both built-in packs use the Geist Code Block syntax palette" {
    for ([_]canvas.ThemePack{ .house, .geist }) |pack| {
        const light = canvas.DesignTokens.theme(.{ .pack = pack, .color_scheme = .light }).colors;
        try testing.expectEqual(canvas.Color.rgb8(23, 23, 23), light.syntax_plain);
        try testing.expectEqual(canvas.Color.rgb8(77, 77, 77), light.syntax_comment);
        try testing.expectEqual(canvas.Color.rgb8(189, 40, 100), light.syntax_keyword);
        try testing.expectEqual(canvas.Color.rgb8(41, 122, 58), light.syntax_literal);
        try testing.expectEqual(canvas.Color.rgb8(120, 32, 188), light.syntax_function);
        try testing.expectEqual(canvas.Color.rgb8(203, 42, 47), light.syntax_property);
        try testing.expectEqual(canvas.Color.rgb8(0, 104, 214), light.syntax_constant);

        const dark = canvas.DesignTokens.theme(.{ .pack = pack, .color_scheme = .dark }).colors;
        try testing.expectEqual(canvas.Color.rgb8(237, 237, 237), dark.syntax_plain);
        try testing.expectEqual(canvas.Color.rgb8(161, 161, 161), dark.syntax_comment);
        try testing.expectEqual(canvas.Color.rgb8(247, 95, 143), dark.syntax_keyword);
        try testing.expectEqual(canvas.Color.rgb8(98, 192, 115), dark.syntax_literal);
        try testing.expectEqual(canvas.Color.rgb8(191, 122, 240), dark.syntax_function);
        try testing.expectEqual(canvas.Color.rgb8(255, 97, 102), dark.syntax_property);
        try testing.expectEqual(canvas.Color.rgb8(82, 168, 255), dark.syntax_constant);
    }
}

test "omitted custom syntax colors inherit readable text roles" {
    const colors = canvas.ColorTokens{
        .background = canvas.Color.rgb8(12, 10, 9),
        .surface_subtle = canvas.Color.rgb8(41, 37, 36),
        .text = canvas.Color.rgb8(250, 250, 249),
        .text_muted = canvas.Color.rgb8(166, 160, 155),
    };

    try testing.expectEqual(colors.text, text_spans.textSpanColorValue(colors, .syntax_plain));
    try testing.expectEqual(colors.text, text_spans.textSpanColorValue(colors, .syntax_keyword));
    try testing.expectEqual(colors.text_muted, text_spans.textSpanColorValue(colors, .syntax_comment));

    var explicit = colors;
    explicit.syntax_keyword = canvas.Color.rgb8(247, 95, 143);
    try testing.expectEqual(explicit.syntax_keyword, text_spans.textSpanColorValue(explicit, .syntax_keyword));
}

test "code wraps by default and no-wrap composes one horizontal scroller" {
    var wrapped_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer wrapped_arena.deinit();
    var wrapped_ui = Ui.init(wrapped_arena.allocator());
    const wrapped = try wrapped_ui.finalize(wrapped_ui.code(.{ .language = .zig }, "const answer: u32 = 42;"));
    try testing.expectEqual(canvas.WidgetKind.column, wrapped.root.kind);
    try testing.expectEqual(geometry.InsetsF{}, wrapped.root.layout.padding);
    try testing.expect(wrapped.root.style.background == null);
    try testing.expect(wrapped.root.style.border == null);
    try testing.expect(wrapped.root.style.radius == null);
    try testing.expect(findByKind(wrapped.root, .scroll_view) == null);
    const wrapped_text = findByKind(wrapped.root, .text).?;
    try testing.expect(!wrapped_text.text_no_wrap);
    try testing.expect(wrapped_text.spans.len > 1);

    var scroll_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer scroll_arena.deinit();
    var scroll_ui = Ui.init(scroll_arena.allocator());
    const unwrapped = try scroll_ui.finalize(scroll_ui.code(.{
        .language = .zig,
        .wrap = false,
        .width = 160,
    }, "const a_very_long_identifier_that_must_not_wrap: u32 = 42;"));
    const region = findByKind(unwrapped.root, .scroll_view).?;
    try testing.expectEqual(canvas.ScrollAxes.horizontal, region.scroll_axes);
    try testing.expect(findByKind(region, .text).?.text_no_wrap);

    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(unwrapped.root, geometry.RectF.init(0, 0, 160, 80), &nodes);
    var scroll_width: f32 = 0;
    var text_width: f32 = 0;
    for (layout.nodes) |node| {
        if (node.widget.kind == .scroll_view) scroll_width = node.frame.width;
        if (node.widget.kind == .text) text_width = node.frame.width;
    }
    try testing.expect(text_width > scroll_width);
}

test "editable code layout paints syntax-highlighted token runs" {
    const source = "const answer: u32 = 42;";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{
        .language = .zig,
        .editable = true,
        .width = 320,
        .height = 80,
    }, source));

    var nodes: [8]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        view.root,
        geometry.RectF.init(0, 0, 320, 80),
        &nodes,
    );
    const tokens = canvas.DesignTokens{};
    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetLayout(&builder, layout, tokens);

    var saw_keyword = false;
    var saw_type = false;
    var saw_literal = false;
    for (builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |draw| {
                if (std.mem.eql(u8, draw.text, "const")) {
                    try testing.expectEqual(tokens.colors.syntax_keyword, draw.color);
                    saw_keyword = true;
                } else if (std.mem.eql(u8, draw.text, "u32")) {
                    try testing.expectEqual(tokens.colors.syntax_literal, draw.color);
                    saw_type = true;
                } else if (std.mem.eql(u8, draw.text, "42")) {
                    try testing.expectEqual(tokens.colors.syntax_literal, draw.color);
                    saw_literal = true;
                }
            },
            else => {},
        }
    }
    try testing.expect(saw_keyword);
    try testing.expect(saw_type);
    try testing.expect(saw_literal);

    var selected_editor = view.root;
    // Runtime-owned text storage can be distinct from the highlighted
    // spans' source storage between an edit and the controlled rebuild.
    selected_editor.text = try arena.allocator().dupe(u8, source);
    selected_editor.text_selection = .{ .anchor = 2, .focus = 12 };
    selected_editor.state.focused = false;
    const selected_layout = try canvas.layoutWidgetTree(
        selected_editor,
        geometry.RectF.init(0, 0, 320, 80),
        &nodes,
    );
    var selected_commands: [64]canvas.CanvasCommand = undefined;
    var selected_builder = canvas.Builder.init(&selected_commands);
    try canvas.emitWidgetLayout(&selected_builder, selected_layout, tokens);
    var changes: [64]canvas.DiffChange = undefined;
    _ = try canvas.DisplayList.diff(.{}, selected_builder.displayList(), &changes);
}

test "unwrapped multiline code hugs the height of every logical line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.column(.{}, .{
        ui.code(.{ .wrap = false }, "one\ntwo\nthree\nfour"),
        ui.text(.{}, "after"),
    }));

    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        view.root,
        geometry.RectF.init(0, 0, 320, 400),
        &nodes,
    );
    var scroll_height: f32 = 0;
    var code_height: f32 = 0;
    for (layout.nodes) |node| {
        if (node.widget.kind == .scroll_view) scroll_height = node.frame.height;
        if (std.mem.eql(u8, node.widget.text, "one\ntwo\nthree\nfour")) {
            code_height = node.frame.height;
        }
    }
    try testing.expect(code_height > 0);
    try testing.expect(scroll_height >= code_height);
}

test "fixed-height code surfaces scroll every overflowing axis" {
    const multiline =
        \\one
        \\two
        \\three
        \\four
        \\five
        \\six
    ;
    var wrapped_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer wrapped_arena.deinit();
    var wrapped_ui = Ui.init(wrapped_arena.allocator());
    const wrapped = try wrapped_ui.finalize(wrapped_ui.code(.{
        .width = 160,
        .height = 60,
    }, multiline));
    const wrapped_region = findByKind(wrapped.root, .scroll_view).?;
    try testing.expectEqual(canvas.ScrollAxes.vertical, wrapped_region.scroll_axes);

    var wrapped_nodes: [8]canvas.WidgetLayoutNode = undefined;
    const wrapped_layout = try canvas.layoutWidgetTree(
        wrapped.root,
        geometry.RectF.init(0, 0, 160, 60),
        &wrapped_nodes,
    );
    var wrapped_scroll_index: usize = 0;
    for (wrapped_layout.nodes, 0..) |node, index| {
        if (node.widget.kind == .scroll_view) wrapped_scroll_index = index;
    }
    const wrapped_scroll = wrapped_layout.nodes[wrapped_scroll_index];
    const wrapped_viewport = wrapped_scroll.frame.inset(wrapped_scroll.widget.layout.padding).normalized();
    const wrapped_vertical = canvas.widgetScrollAxisMetrics(
        wrapped_layout,
        wrapped_scroll_index,
        canvas.virtualWidgetScrollContentExtent,
        .vertical,
        wrapped_viewport,
    );
    try testing.expect(wrapped_vertical.content_extent > wrapped_vertical.viewport_extent);

    var both_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer both_arena.deinit();
    var both_ui = Ui.init(both_arena.allocator());
    const both = try both_ui.finalize(both_ui.code(.{
        .wrap = false,
        .width = 160,
        .height = 60,
    }, "a_very_long_identifier_that_overflows_horizontally\nsecond\nthird\nfourth"));
    const both_region = findByKind(both.root, .scroll_view).?;
    try testing.expectEqual(canvas.ScrollAxes.both, both_region.scroll_axes);

    var both_nodes: [8]canvas.WidgetLayoutNode = undefined;
    const both_layout = try canvas.layoutWidgetTree(
        both.root,
        geometry.RectF.init(0, 0, 160, 60),
        &both_nodes,
    );
    var both_scroll_index: usize = 0;
    for (both_layout.nodes, 0..) |node, index| {
        if (node.widget.kind == .scroll_view) both_scroll_index = index;
    }
    const both_scroll = both_layout.nodes[both_scroll_index];
    const both_viewport = both_scroll.frame.inset(both_scroll.widget.layout.padding).normalized();
    const both_vertical = canvas.widgetScrollAxisMetrics(
        both_layout,
        both_scroll_index,
        canvas.virtualWidgetScrollContentExtent,
        .vertical,
        both_viewport,
    );
    const both_horizontal = canvas.widgetScrollAxisMetrics(
        both_layout,
        both_scroll_index,
        canvas.virtualWidgetScrollContentExtent,
        .horizontal,
        both_viewport,
    );
    try testing.expect(both_vertical.content_extent > both_vertical.viewport_extent);
    try testing.expect(both_horizontal.content_extent > both_horizontal.viewport_extent);
}

test "line numbers are opt-in and stay paired with logical source lines" {
    var plain_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer plain_arena.deinit();
    var plain_ui = Ui.init(plain_arena.allocator());
    const plain = try plain_ui.finalize(plain_ui.code(.{}, "alpha\nbeta"));
    try testing.expect(findByText(plain.root, "1") == null);
    try testing.expectEqual(@as(usize, 1), countByKind(plain.root, .text));
    try testing.expect(findByText(plain.root, "alpha\nbeta") != null);

    var numbered_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer numbered_arena.deinit();
    var numbered_ui = Ui.init(numbered_arena.allocator());
    const numbered = try numbered_ui.finalize(numbered_ui.code(.{
        .language = .plain,
        .line_numbers = true,
    }, "alpha\nbeta"));
    try testing.expectEqual(@as(usize, 1), countByKind(numbered.root, .text));
    const numbered_text = findByText(numbered.root, "alpha\nbeta").?;
    try testing.expectEqual(@as(u8, 1), numbered_text.code_line_number_digits);

    var numbered_nodes: [8]canvas.WidgetLayoutNode = undefined;
    const numbered_layout = try canvas.layoutWidgetTree(
        numbered.root,
        geometry.RectF.init(0, 0, 160, 80),
        &numbered_nodes,
    );
    var numbered_commands: [32]canvas.CanvasCommand = undefined;
    var numbered_builder = canvas.Builder.init(&numbered_commands);
    try canvas.emitWidgetLayout(&numbered_builder, numbered_layout, .{});
    var first_marker_y: ?f32 = null;
    var second_marker_y: ?f32 = null;
    for (numbered_builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |draw| {
                if (std.mem.eql(u8, draw.text, "1")) first_marker_y = draw.origin.y;
                if (std.mem.eql(u8, draw.text, "2")) second_marker_y = draw.origin.y;
            },
            else => {},
        }
    }
    try testing.expect(first_marker_y != null);
    try testing.expect(second_marker_y != null);
    try testing.expect(second_marker_y.? > first_marker_y.?);

    var comment_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer comment_arena.deinit();
    var comment_ui = Ui.init(comment_arena.allocator());
    const comments = try comment_ui.finalize(comment_ui.code(.{
        .language = .zig,
        .line_numbers = true,
    }, "// first\nconst second = true;"));
    const comment_text = findByText(comments.root, "// first\nconst second = true;").?;
    try testing.expectEqual(canvas.TextSpanColor.syntax_keyword, spanWithFragment(comment_text.spans, "const").?.color.?);
}

test "diff lines use Geist washes and renderer-owned markers without changing source" {
    const source =
        \\module.exports = {
        \\  experimental: {
        \\    appDir: true,
        \\  },
        \\  appDir: true,
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{
        .language = .javascript,
        .line_numbers = true,
        .added_lines = &.{5},
        .removed_lines = &.{ 2, 3, 4 },
        .wrap = false,
        .width = 360,
    }, source));
    const paragraph = findByText(view.root, source).?;
    try testing.expectEqualStrings(source, paragraph.text);
    const diff_lines = paragraph.codeDiffLines().?;
    try testing.expectEqual(@as(u128, 1) << 4, diff_lines.added);
    try testing.expectEqual((@as(u128, 1) << 1) | (@as(u128, 1) << 2) | (@as(u128, 1) << 3), diff_lines.removed);

    var nodes: [16]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(view.root, geometry.RectF.init(0, 0, 360, 140), &nodes);
    for ([_]canvas.ThemePack{ .house, .geist }) |pack| {
        for ([_]canvas.ColorScheme{ .light, .dark }) |scheme| {
            const tokens = canvas.DesignTokens.theme(.{ .pack = pack, .color_scheme = scheme });
            const added_background = if (scheme == .dark)
                canvas.Color.rgb8(18, 54, 27)
            else
                canvas.Color.rgb8(218, 246, 218);
            const removed_background = if (scheme == .dark)
                canvas.Color.rgb8(86, 26, 30)
            else
                canvas.Color.rgb8(255, 230, 230);
            const added_foreground = if (scheme == .dark)
                canvas.Color.rgb8(98, 192, 115)
            else
                canvas.Color.rgb8(41, 122, 58);
            const removed_foreground = if (scheme == .dark)
                canvas.Color.rgb8(255, 97, 102)
            else
                canvas.Color.rgb8(203, 42, 47);
            var commands: [256]canvas.CanvasCommand = undefined;
            var builder = canvas.Builder.init(&commands);
            try canvas.emitWidgetLayout(&builder, layout, tokens);

            var added_washes: usize = 0;
            var removed_washes: usize = 0;
            var added_markers: usize = 0;
            var removed_markers: usize = 0;
            for (builder.displayList().commands) |command| {
                switch (command) {
                    .fill_rect => |fill| {
                        if (std.meta.eql(fill.fill.color, added_background)) added_washes += 1;
                        if (std.meta.eql(fill.fill.color, removed_background)) removed_washes += 1;
                    },
                    .draw_text => |draw| {
                        if (std.mem.eql(u8, draw.text, "+") and std.meta.eql(draw.color, added_foreground)) added_markers += 1;
                        if (std.mem.eql(u8, draw.text, "-") and std.meta.eql(draw.color, removed_foreground)) removed_markers += 1;
                    },
                    else => {},
                }
            }
            try testing.expectEqual(@as(usize, 1), added_washes);
            try testing.expectEqual(@as(usize, 3), removed_washes);
            try testing.expectEqual(@as(usize, 1), added_markers);
            try testing.expectEqual(@as(usize, 3), removed_markers);
        }
    }
}

test "diff markers reserve a gutter when line numbers are hidden" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{ .added_lines = &.{1} }, "added"));
    const paragraph = findByText(view.root, "added").?;
    try testing.expectEqual(@as(u8, 0), paragraph.codeLineNumberDigits());
    try testing.expect(widget_metrics.widgetCodeLineNumberGutterWidth(paragraph, .{}) > 0);
}

test "unwrapped editable diffs paint markers without line numbers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{
        .editable = true,
        .wrap = false,
        .added_lines = &.{1},
    }, "added"));
    var editor = findByText(view.root, "added").?;
    editor.frame = geometry.RectF.init(0, 0, 160, 48);

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetTree(&builder, editor, .{});

    var added_markers: usize = 0;
    for (builder.displayList().commands) |command| {
        if (command == .draw_text and std.mem.eql(u8, command.draw_text.text, "+")) {
            added_markers += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), added_markers);
}

test "editable diff washes paint behind text selections" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{
        .editable = true,
        .wrap = false,
        .added_lines = &.{1},
    }, "added"));
    var editor = findByText(view.root, "added").?;
    editor.frame = geometry.RectF.init(0, 0, 160, 48);
    editor.text_selection = .{ .anchor = 0, .focus = editor.text.len };

    var tokens = canvas.DesignTokens{};
    const selection_fill = canvas.Color.rgb8(7, 11, 13);
    const added_wash = canvas.Color.rgb8(218, 246, 218);
    tokens.colors.accent = selection_fill;
    tokens.colors.background = canvas.Color.rgb8(255, 255, 255);

    var commands: [128]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetTree(&builder, editor, tokens);

    var wash_index: ?usize = null;
    var selection_index: ?usize = null;
    for (builder.displayList().commands, 0..) |command, index| {
        if (command != .fill_rect) continue;
        if (std.meta.eql(command.fill_rect.fill.color, added_wash) and
            command.fill_rect.rect.width == editor.frame.width)
        {
            wash_index = index;
        }
        if (std.meta.eql(command.fill_rect.fill.color, selection_fill)) selection_index = index;
    }
    try testing.expect(wash_index != null);
    try testing.expect(selection_index != null);
    try testing.expect(wash_index.? < selection_index.?);
}

test "line number gutter reserves at least three marker columns" {
    const tokens = canvas.DesignTokens{};
    var numbered = canvas.Widget{
        .kind = .textarea,
        .runtime_flags = .{ .code_editor = true },
        .code_line_number_digits = 1,
    };
    const one_digit_width = widget_metrics.widgetCodeLineNumberGutterWidth(numbered, tokens);
    numbered.code_line_number_digits = 3;
    const three_digit_width = widget_metrics.widgetCodeLineNumberGutterWidth(numbered, tokens);
    numbered.code_line_number_digits = 4;
    const four_digit_width = widget_metrics.widgetCodeLineNumberGutterWidth(numbered, tokens);

    try testing.expectEqual(three_digit_width, one_digit_width);
    try testing.expect(four_digit_width > three_digit_width);
}

test "editable line-number gutter masks horizontally scrolled source" {
    const source = "const deliberately_long_identifier = another_deliberately_long_identifier;\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{
        .language = .zig,
        .editable = true,
        .line_numbers = true,
        .wrap = false,
        .height = 80,
    }, source));
    var editor = findByText(view.root, source).?;
    editor.frame = geometry.RectF.init(0, 0, 220, 80);
    editor.value_x = 48;

    const tokens = canvas.DesignTokens{};
    var commands: [128]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetTree(&builder, editor, tokens);

    var source_index: ?usize = null;
    var gutter_index: ?usize = null;
    var marker_index: ?usize = null;
    var gutter_rect: ?geometry.RectF = null;
    for (builder.displayList().commands, 0..) |command, index| {
        switch (command) {
            .fill_rect => |fill| {
                if (std.meta.eql(fill.fill.color, tokens.colors.background)) {
                    gutter_index = index;
                    gutter_rect = fill.rect;
                }
            },
            .draw_text => |draw| {
                if (std.mem.eql(u8, draw.text, "1") or std.mem.eql(u8, draw.text, "2")) {
                    marker_index = index;
                } else {
                    source_index = index;
                }
            },
            else => {},
        }
    }

    try testing.expect(source_index != null);
    try testing.expect(gutter_index != null);
    try testing.expect(marker_index != null);
    try testing.expect(source_index.? < gutter_index.?);
    try testing.expect(gutter_index.? < marker_index.?);
    try testing.expectEqual(editor.frame.x, gutter_rect.?.x);
    try testing.expectEqual(editor.frame.y, gutter_rect.?.y);
    try testing.expect(gutter_rect.?.width > 0);
    try testing.expectEqual(editor.frame.height, gutter_rect.?.height);
}

test "wrapped numbered editable code emits one retained gutter" {
    const source = "alpha beta gamma delta epsilon zeta eta theta";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{
        .language = .plain,
        .editable = true,
        .line_numbers = true,
        .wrap = true,
    }, source));
    var editor = findByText(view.root, source).?;
    editor.frame = geometry.RectF.init(0, 0, 120, 80);

    var commands: [256]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetTree(&builder, editor, .{});

    var line_one_count: usize = 0;
    for (builder.displayList().commands) |command| {
        if (command == .draw_text and std.mem.eql(u8, command.draw_text.text, "1")) {
            line_one_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), line_one_count);

    var changes: [256]canvas.DiffChange = undefined;
    _ = try canvas.DisplayList.diff(.{}, builder.displayList(), &changes);
}

test "wrapped editable code re-highlights runtime-owned text" {
    const source = "const stale = true;";
    const edited = "fn fresh() void {}";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{
        .language = .zig,
        .editable = true,
        .wrap = true,
    }, source));
    var editor = findByText(view.root, source).?;
    editor.text = edited;
    editor.frame = geometry.RectF.init(0, 0, 300, 80);

    var commands: [256]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetTree(&builder, editor, .{});

    var rendered: std.ArrayListUnmanaged(u8) = .empty;
    defer rendered.deinit(testing.allocator);
    for (builder.displayList().commands) |command| {
        if (command == .draw_text) try rendered.appendSlice(testing.allocator, command.draw_text.text);
    }
    try testing.expectEqualStrings(edited, rendered.items);
}

test "wrapped editable code preserves syntax after the document exhausts the span budget" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..40) |index| {
        var line_buffer: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buffer, "const value_{d} = \"ordinary\";\n", .{index});
        try source.appendSlice(testing.allocator, line);
    }
    try source.appendSlice(testing.allocator, "const tail = \"TAIL_SENTINEL\";");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{
        .language = .zig,
        .editable = true,
        .wrap = true,
    }, source.items));
    var editor = findByText(view.root, source.items).?;
    editor.frame = geometry.RectF.init(0, 0, 800, 1_000);

    const tokens = canvas.DesignTokens{};
    var commands: [512]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetTree(&builder, editor, tokens);

    var tail_color: ?canvas.Color = null;
    for (builder.displayList().commands) |command| {
        if (command != .draw_text) continue;
        if (std.mem.indexOf(u8, command.draw_text.text, "TAIL_SENTINEL") != null) {
            tail_color = command.draw_text.color;
            break;
        }
    }
    try testing.expectEqual(tokens.colors.syntax_literal, tail_color.?);
}

test "wrapped editable code paints the visible tail of an over-capacity logical line" {
    const source = ("x" ** (text_spans.max_text_span_lines_per_paragraph * 2 + 8)) ++ "Z";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{
        .language = .plain,
        .editable = true,
        .wrap = true,
    }, source));
    var editor = findByText(view.root, source).?;

    var measured = CodeWidthMeasure{};
    const provider = canvas.TextMeasureProvider{
        .context = &measured,
        .measure_fn = CodeWidthMeasure.width,
        .measure_advances_fn = CodeWidthMeasure.advances,
    };
    const tokens = canvas.DesignTokens{ .text_measure = &provider };
    const line_height = tokens.typography.body_size * 1.25;
    editor.frame = geometry.RectF.init(
        0,
        0,
        tokens.typography.body_size * 2,
        line_height * 2,
    );
    editor.value = canvas.textInputMaxScrollOffsetForWidget(editor, tokens);
    try testing.expect(editor.value > line_height * text_spans.max_text_span_lines_per_paragraph);

    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetTree(&builder, editor, tokens);

    var saw_tail = false;
    for (builder.displayList().commands) |command| {
        if (command == .draw_text and std.mem.indexOfScalar(u8, command.draw_text.text, 'Z') != null) {
            saw_tail = true;
        }
    }
    try testing.expect(saw_tail);
}

test "editable code numbers the empty caret row after a terminal newline" {
    const source = "alpha\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{
        .language = .plain,
        .editable = true,
        .line_numbers = true,
        .wrap = false,
    }, source));
    var editor = findByText(view.root, source).?;
    editor.frame = geometry.RectF.init(0, 0, 300, 80);
    try testing.expectEqual(@as(u8, 1), editor.code_line_number_digits);

    var commands: [256]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetTree(&builder, editor, .{});

    var saw_second_line = false;
    for (builder.displayList().commands) |command| {
        if (command == .draw_text and std.mem.eql(u8, command.draw_text.text, "2")) {
            saw_second_line = true;
            break;
        }
    }
    try testing.expect(saw_second_line);
}

test "wrapped editable code measures vertical extent with its monospace font" {
    const source = "iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{
        .language = .plain,
        .editable = true,
        .line_numbers = true,
        .wrap = true,
    }, source));
    var editor = findByText(view.root, source).?;
    editor.frame = geometry.RectF.init(0, 0, 140, 20);
    const tokens = canvas.DesignTokens{ .text_measure = &code_font_sensitive_measure };

    try testing.expect(canvas.textInputContentExtentForWidget(editor, tokens) > editor.frame.height);
    try testing.expect(canvas.textInputMaxScrollOffsetForWidget(editor, tokens) > 0);
}

test "wrapped editable code paints the caret row from the interaction width" {
    const source = "ab";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{
        .language = .plain,
        .editable = true,
        .wrap = true,
    }, source));
    var editor = findByText(view.root, source).?;

    var measured = CodeWidthMeasure{};
    const provider = canvas.TextMeasureProvider{
        .context = &measured,
        .measure_fn = CodeWidthMeasure.width,
        .measure_advances_fn = CodeWidthMeasure.advances,
    };
    const tokens = canvas.DesignTokens{
        .pixel_snap = .{ .geometry = true, .scale = 1 },
        .text_measure = &provider,
    };
    const text_size = tokens.typography.body_size;
    // The exact interaction width wraps the second glyph, while the static
    // paragraph pixel hand-back would make both glyphs fit.
    editor.frame = geometry.RectF.init(0, 0, text_size * 2 - 0.6, 80);
    editor.state.focused = true;
    editor.text_selection = canvas.TextSelection.collapsed(source.len);

    var commands: [128]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetTree(&builder, editor, tokens);

    var final_glyph_baseline: ?f32 = null;
    for (builder.displayList().commands) |command| {
        if (command == .draw_text and std.mem.indexOfScalar(u8, command.draw_text.text, 'b') != null) {
            final_glyph_baseline = command.draw_text.origin.y;
        }
    }
    const caret = canvas.textGeometryForWidget(editor, tokens).caret_bounds.?;
    try testing.expect(final_glyph_baseline != null);
    try testing.expectApproxEqAbs(caret.y + text_size, final_glyph_baseline.?, 0.001);
}

test "numbered editable code does not invent trailing horizontal overflow" {
    const source = "const concise = true;";
    const tokens = canvas.DesignTokens{};
    var editor = canvas.Widget{
        .kind = .textarea,
        .runtime_flags = .{ .code_editor = true },
        .code_line_number_digits = 2,
        .text_no_wrap = true,
        .text = source,
        .frame = geometry.RectF.init(10, 12, 500, 80),
    };

    const broad_viewport = canvas.textInputViewportForWidget(editor, tokens).?;
    const gutter = broad_viewport.x - editor.frame.x;
    const text_width = canvas.measureTextWidthForFont(
        tokens.text_measure,
        tokens.typography.mono_font_id,
        source,
        tokens.typography.body_size,
    );
    // Exactly enough room for the gutter, source, and one-point caret.
    editor.frame.width = gutter + text_width + 1;

    const fitted_viewport = canvas.textInputViewportForWidget(editor, tokens).?;
    try testing.expectApproxEqAbs(editor.frame.maxX(), fitted_viewport.maxX(), 0.001);
    try testing.expectEqual(@as(f32, 0), canvas.textInputMaxHorizontalScrollOffsetForWidget(editor, tokens));
    try testing.expectEqual(fitted_viewport.width, canvas.textInputContentWidthForWidget(editor, tokens));
}

test "editable code caches one batched longest-line measurement across geometry reads" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..1000) |index| {
        var line_buffer: [48]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buffer, "const value_{d} = true;\n", .{index});
        try source.appendSlice(testing.allocator, line);
    }

    var measured = CodeWidthMeasure{};
    const provider = canvas.TextMeasureProvider{
        .context = &measured,
        .measure_fn = CodeWidthMeasure.width,
        .measure_advances_fn = CodeWidthMeasure.advances,
    };
    const tokens = canvas.DesignTokens{ .text_measure = &provider };
    var editor = canvas.Widget{
        .kind = .textarea,
        .runtime_flags = .{ .code_editor = true },
        .text_no_wrap = true,
        .text = source.items,
        .frame = geometry.RectF.init(0, 0, 240, 80),
    };

    canvas.cacheTextInputContentWidthForWidget(&editor, tokens);
    canvas.cacheTextInputContentWidthForWidget(&editor, tokens);
    for (0..4) |_| {
        _ = canvas.textInputMaxHorizontalScrollOffsetForWidget(editor, tokens);
        _ = canvas.textInputContentWidthForWidget(editor, tokens);
    }

    try testing.expectEqual(@as(usize, 1), measured.advance_calls);
    try testing.expectEqual(@as(usize, 0), measured.width_calls);
}

test "editable code highlights the caret row but not a text selection" {
    const source = "const first = 1;\nconst second = 2;\n";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{
        .language = .zig,
        .editable = true,
        .line_numbers = true,
        .wrap = false,
        .height = 80,
    }, source));
    var editor = findByText(view.root, source).?;
    editor.frame = geometry.RectF.init(0, 0, 220, 80);
    editor.state.focused = true;
    editor.text_selection = canvas.TextSelection.collapsed(std.mem.indexOf(u8, source, "second").?);

    var tokens = canvas.DesignTokens{};
    tokens.colors.surface_subtle = canvas.Color.rgb8(19, 23, 29);
    var commands: [128]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetTree(&builder, editor, tokens);

    const caret = canvas.textGeometryForWidget(editor, tokens).caret_bounds.?;
    var full_row_index: ?usize = null;
    var source_index: ?usize = null;
    var gutter_index: ?usize = null;
    var gutter_row_index: ?usize = null;
    var marker_index: ?usize = null;
    var full_row: ?geometry.RectF = null;
    var gutter_row: ?geometry.RectF = null;
    for (builder.displayList().commands, 0..) |command, index| {
        switch (command) {
            .fill_rect => |fill| {
                if (std.meta.eql(fill.fill.color, tokens.colors.surface_subtle)) {
                    if (fill.rect.width == editor.frame.width) {
                        full_row_index = index;
                        full_row = fill.rect;
                    } else {
                        gutter_row_index = index;
                        gutter_row = fill.rect;
                    }
                } else if (std.meta.eql(fill.fill.color, tokens.colors.background)) {
                    gutter_index = index;
                }
            },
            .draw_text => |draw| {
                if (std.mem.eql(u8, draw.text, "2")) {
                    marker_index = index;
                } else if (!std.mem.eql(u8, draw.text, "1") and !std.mem.eql(u8, draw.text, "3")) {
                    source_index = index;
                }
            },
            else => {},
        }
    }

    try testing.expect(full_row_index != null);
    try testing.expect(source_index != null);
    try testing.expect(gutter_index != null);
    try testing.expect(gutter_row_index != null);
    try testing.expect(marker_index != null);
    try testing.expect(full_row_index.? < source_index.?);
    try testing.expect(source_index.? < gutter_index.?);
    try testing.expect(gutter_index.? < gutter_row_index.?);
    try testing.expect(gutter_row_index.? < marker_index.?);
    try testing.expectEqual(editor.frame.x, full_row.?.x);
    try testing.expectEqual(editor.frame.width, full_row.?.width);
    try testing.expectEqual(caret.y, full_row.?.y);
    try testing.expectEqual(caret.height, full_row.?.height);
    try testing.expectEqual(full_row.?.y, gutter_row.?.y);
    try testing.expectEqual(full_row.?.height, gutter_row.?.height);
    try testing.expect(gutter_row.?.width < full_row.?.width);

    editor.text_selection = .{ .anchor = 0, .focus = 5 };
    var selected_commands: [128]canvas.CanvasCommand = undefined;
    var selected_builder = canvas.Builder.init(&selected_commands);
    try canvas.emitWidgetTree(&selected_builder, editor, tokens);
    for (selected_builder.displayList().commands) |command| {
        if (command == .fill_rect) {
            try testing.expect(!std.meta.eql(command.fill_rect.fill.color, tokens.colors.surface_subtle));
        }
    }

    editor.text_selection = canvas.TextSelection.collapsed(0);
    editor.state.focused = false;
    var blurred_commands: [128]canvas.CanvasCommand = undefined;
    var blurred_builder = canvas.Builder.init(&blurred_commands);
    try canvas.emitWidgetTree(&blurred_builder, editor, tokens);
    for (blurred_builder.displayList().commands) |command| {
        if (command == .fill_rect) {
            try testing.expect(!std.meta.eql(command.fill_rect.fill.color, tokens.colors.surface_subtle));
        }
    }
}

test "editable code Tab infers the file indentation and falls back to two spaces" {
    try expectCodeTabInsertion("const answer = 42;\n", "  ");
    try expectCodeTabInsertion(
        \\if (ready) {
        \\  while (running) {
        \\    tick();
        \\  }
        \\}
    , "  ");
    try expectCodeTabInsertion(
        \\if (ready) {
        \\    while (running) {
        \\        tick();
        \\    }
        \\}
    , "    ");
    try expectCodeTabInsertion(
        "if (ready) {\n\twhile (running) {\n\t\ttick();\n\t}\n}\n",
        "\t",
    );

    const plain_textarea = canvas.Widget{
        .kind = .textarea,
        .text = "plain",
    };
    try testing.expect(canvas.widgetCodeTabTextEditEvent(plain_textarea, .{
        .phase = .key_down,
        .key = "tab",
    }) == null);
    try testing.expect(canvas.widgetCodeTabTextEditEvent(.{
        .kind = .textarea,
        .runtime_flags = .{ .code_editor = true },
        .text = "code",
    }, .{
        .phase = .key_down,
        .key = "tab",
        .modifiers = .{ .shift = true },
    }) == null);
    try testing.expect(canvas.widgetCodeTabTextEditEvent(.{
        .kind = .textarea,
        .runtime_flags = .{ .code_editor = true },
        .text = "code",
    }, .{
        .phase = .key_down,
        .key = "tab",
        .focus_moved = true,
    }) == null);
}

test "empty code retains the exact source text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{
        .language = .plain,
        .line_numbers = true,
    }, ""));

    const paragraph = findByKind(view.root, .text).?;
    try testing.expectEqualStrings("", paragraph.text);
    try testing.expectEqual(@as(usize, 1), paragraph.spans.len);
    try testing.expectEqualStrings("", paragraph.spans[0].text);
    try testing.expectEqual(@as(u8, 1), paragraph.code_line_number_digits);
}

test "code preserves CRLF source without painting carriage returns" {
    const source = "const alpha = 1;\r\nconst beta = 2;";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{ .language = .zig }, source));

    const paragraph = findByText(view.root, source).?;
    var runs: [text_spans.max_text_span_runs_per_paragraph]text_spans.TextSpanRun = undefined;
    const layout = text_spans.layoutTextSpans(
        paragraph.spans,
        .{ .size = 14, .max_width = 10_000 },
        &runs,
    );
    try testing.expectEqual(@as(usize, 2), layout.line_count);
    for (layout.runs) |run| {
        try testing.expect(std.mem.indexOfScalar(u8, run.text, '\r') == null);
    }
    try testing.expectEqualStrings(source, paragraph.text);
}

test "large code blocks split at the paragraph line capacity without hiding their tail" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..129) |_| try source.appendSlice(testing.allocator, "line\n");
    try source.appendSlice(testing.allocator, "tail");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{ .language = .plain }, source.items));

    try testing.expect(countByKind(view.root, .text) > 1);
    const chunk_column = view.root.children[0];
    var expected_offset: usize = 0;
    var group_id: ?canvas.ObjectId = null;
    for (chunk_column.children) |chunk| {
        try testing.expect(chunk.static_text_group_id != 0);
        try testing.expectEqual(@as(u64, @intCast(expected_offset)), chunk.static_text_group_offset);
        if (group_id) |expected| {
            try testing.expectEqual(expected, chunk.static_text_group_id);
        } else {
            group_id = chunk.static_text_group_id;
        }
        expected_offset += chunk.text.len;
    }
    try testing.expectEqual(source.items.len, expected_offset);
    try expectCompleteSpanLayouts(view.root);
    var recovered: std.ArrayListUnmanaged(u8) = .empty;
    defer recovered.deinit(testing.allocator);
    try appendTextWidgets(view.root, &recovered, testing.allocator);
    try testing.expectEqualStrings(source.items, recovered.items);
}

test "maximal newline-heavy code stays within retained span and node budgets" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..65_536) |_| try source.append(testing.allocator, '\n');

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{ .language = .plain }, source.items));

    try testing.expectEqual(Ui.max_code_spans_per_surface, countTextSpans(view.root));
    try expectCompleteSpanLayouts(view.root);
    var nodes: [1024]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        view.root,
        geometry.RectF.init(0, 0, 320, 20_000),
        &nodes,
    );
    // One panel + one chunk column + one text node per 128 source
    // newlines: 514 stays well below the 1024-node runtime view cap.
    try testing.expectEqual(Ui.max_code_spans_per_surface + 2, layout.nodes.len);

    var recovered: std.ArrayListUnmanaged(u8) = .empty;
    defer recovered.deinit(testing.allocator);
    try appendTextWidgets(view.root, &recovered, testing.allocator);
    try testing.expectEqualStrings(source.items, recovered.items);
}

test "large code retains all source while emitting only visible text" {
    const source = try testing.allocator.alloc(u8, 65_536);
    defer testing.allocator.free(source);
    @memset(source, 'x');

    for ([_]bool{ true, false }) |wrap| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var ui = Ui.init(arena.allocator());
        const view = try ui.finalize(ui.code(.{
            .wrap = wrap,
            .height = 80,
        }, source));

        var recovered: std.ArrayListUnmanaged(u8) = .empty;
        defer recovered.deinit(testing.allocator);
        try appendTextWidgets(view.root, &recovered, testing.allocator);
        try testing.expectEqualStrings(source, recovered.items);

        var nodes: [1024]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(
            view.root,
            geometry.RectF.init(0, 0, 320, 80),
            &nodes,
        );
        var commands: [2048]canvas.CanvasCommand = undefined;
        var builder = canvas.Builder.init(&commands);
        try canvas.emitWidgetLayout(&builder, layout, .{});
        const display_list = builder.displayList();

        try testing.expect(display_list.commands.len < commands.len);
        try testing.expect(displayListTextBytes(display_list) <= canvas.max_display_list_text_bytes);
        try testing.expect(displayListTextBytes(display_list) < source.len);
    }
}

test "large editable code selection repaints only visible glyphs" {
    const source = try testing.allocator.alloc(u8, 65_536);
    defer testing.allocator.free(source);
    @memset(source, 'x');

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{
        .editable = true,
        .wrap = false,
        .height = 80,
    }, source));
    var editor = findByText(view.root, source).?;
    editor.frame = geometry.RectF.init(0, 0, 320, 80);
    editor.text_selection = .{ .anchor = 0, .focus = 5 };

    var commands: [256]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetTree(&builder, editor, .{});

    const text_bytes = displayListTextBytes(builder.displayList());
    try testing.expect(text_bytes <= canvas.max_display_list_text_bytes);
    try testing.expect(text_bytes < source.len);
}

test "direct tree code emission honors scroll viewports and later layout pages" {
    const horizontal_source = "x" ** 65_536;
    const horizontal_spans = [_]canvas.TextSpan{.{
        .text = horizontal_source,
        .monospace = true,
        .color = .syntax_plain,
    }};
    const horizontal_children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(0, 0, 400_000, 20),
        .text = horizontal_source,
        .spans = &horizontal_spans,
        .text_no_wrap = true,
    }};
    const horizontal_root = canvas.Widget{
        .id = 1,
        .kind = .scroll_view,
        .frame = geometry.RectF.init(0, 0, 320, 80),
        .runtime_flags = .{ .native_scroll = true },
        .children = &horizontal_children,
    };
    var horizontal_commands: [64]canvas.CanvasCommand = undefined;
    var horizontal_builder = canvas.Builder.init(&horizontal_commands);
    try canvas.emitWidgetTree(&horizontal_builder, horizontal_root, .{});
    const horizontal_list = horizontal_builder.displayList();
    try testing.expect(displayListTextBytes(horizontal_list) <= canvas.max_display_list_text_bytes);
    try testing.expect(displayListTextBytes(horizontal_list) < horizontal_source.len);

    const vertical_source = ("x\n" ** 139) ++ "x";
    const vertical_spans = [_]canvas.TextSpan{.{
        .text = vertical_source,
        .monospace = true,
        .color = .syntax_plain,
    }};
    const vertical_children = [_]canvas.Widget{.{
        .id = 4,
        .kind = .text,
        .frame = geometry.RectF.init(0, -2400, 100, 2450),
        .text = vertical_source,
        .spans = &vertical_spans,
    }};
    const vertical_root = canvas.Widget{
        .id = 3,
        .kind = .scroll_view,
        .frame = geometry.RectF.init(0, 0, 100, 100),
        .runtime_flags = .{ .native_scroll = true },
        .children = &vertical_children,
    };
    var vertical_commands: [64]canvas.CanvasCommand = undefined;
    var vertical_builder = canvas.Builder.init(&vertical_commands);
    try canvas.emitWidgetTree(&vertical_builder, vertical_root, .{});

    var visible_text_commands: usize = 0;
    for (vertical_builder.displayList().commands) |command| {
        switch (command) {
            .draw_text => |draw| {
                if (draw.origin.y >= 0 and draw.origin.y <= vertical_root.frame.maxY()) {
                    visible_text_commands += 1;
                }
            },
            else => {},
        }
    }
    try testing.expect(visible_text_commands > 0);
}

test "editable code highlights the visible tail of a ten-thousand-line source" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..9_997) |_| {
        try source.appendSlice(testing.allocator, ":root { --color: #fff; }\n");
    }
    try source.appendSlice(testing.allocator, "body {\n  color: red;\n}\n");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{
        .language = .css,
        .editable = true,
        .line_numbers = true,
        .wrap = false,
        .height = 100,
    }, source.items));
    var editor = findByText(view.root, source.items).?;
    try testing.expect(editor.runtime_flags.code_editor);
    try testing.expectEqual(code_model.Language.css, editor.code_language);
    try testing.expectEqual(@as(usize, 1), editor.spans.len);
    try testing.expectEqual(@as(u8, 5), editor.code_line_number_digits);

    const tokens = canvas.DesignTokens{};
    const line_height = tokens.typography.body_size * 1.25;
    editor.frame = geometry.RectF.init(0, 0, 500, 100);
    editor.value = 9_997 * line_height;

    var commands: [256]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetTree(&builder, editor, tokens);

    var saw_body = false;
    var saw_property = false;
    var saw_late_line_number = false;
    for (builder.displayList().commands) |command| {
        if (command != .draw_text) continue;
        const draw = command.draw_text;
        if (std.mem.eql(u8, draw.text, "body")) {
            saw_body = true;
            try testing.expectEqual(tokens.colors.syntax_literal, draw.color);
        }
        if (std.mem.eql(u8, draw.text, "color")) {
            saw_property = true;
            try testing.expectEqual(tokens.colors.syntax_property, draw.color);
        }
        if (std.mem.eql(u8, draw.text, "9998")) saw_late_line_number = true;
    }
    try testing.expect(saw_body);
    try testing.expect(saw_property);
    try testing.expect(saw_late_line_number);
}

test "maximal one-line numbered code adds no retained gutter bytes" {
    const source = try testing.allocator.alloc(u8, 65_536);
    defer testing.allocator.free(source);
    @memset(source, 'x');

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{
        .language = .plain,
        .line_numbers = true,
        .wrap = false,
    }, source));

    try testing.expectEqual(@as(usize, 1), countByKind(view.root, .text));
    const paragraph = findByText(view.root, source).?;
    try testing.expectEqual(@as(u8, 1), paragraph.code_line_number_digits);
    var retained_text: std.ArrayListUnmanaged(u8) = .empty;
    defer retained_text.deinit(testing.allocator);
    try appendTextWidgets(view.root, &retained_text, testing.allocator);
    try testing.expectEqual(source.len, retained_text.items.len);
    try testing.expectEqualStrings(source, retained_text.items);
}

test "transformed code culling maps the window back into paragraph space" {
    const source = ("x\n" ** 139) ++ "x";
    const spans = [_]canvas.TextSpan{.{
        .text = source,
        .monospace = true,
        .color = .syntax_plain,
    }};
    const root_frame = geometry.RectF.init(0, 0, 100, 100);

    const translated_frame = geometry.RectF.init(0, 200, 20, 2450);
    const translated_nodes = [_]canvas.WidgetLayoutNode{
        .{
            .widget = .{ .id = 1, .kind = .stack },
            .frame = root_frame,
            .depth = 0,
        },
        .{
            .widget = .{
                .id = 2,
                .kind = .text,
                .text = source,
                .spans = &spans,
                .transform = canvas.Affine.translate(0, -200),
            },
            .frame = translated_frame,
            .depth = 1,
            .parent_index = 0,
        },
    };
    var translated_commands: [64]canvas.CanvasCommand = undefined;
    var translated_builder = canvas.Builder.init(&translated_commands);
    try canvas.emitWidgetLayout(
        &translated_builder,
        canvas.WidgetLayoutTree{ .nodes = &translated_nodes },
        .{},
    );
    try testing.expect(displayListTextBytes(translated_builder.displayList()) > 0);

    const scaled_frame = geometry.RectF.init(0, 0, 20, 2450);
    const scaled_nodes = [_]canvas.WidgetLayoutNode{
        .{
            .widget = .{ .id = 1, .kind = .stack },
            .frame = root_frame,
            .depth = 0,
        },
        .{
            .widget = .{
                .id = 2,
                .kind = .text,
                .text = source,
                .spans = &spans,
                .transform = canvas.Affine.scale(0.01, 0.01),
            },
            .frame = scaled_frame,
            .depth = 1,
            .parent_index = 0,
        },
    };
    var scaled_commands: [256]canvas.CanvasCommand = undefined;
    var scaled_builder = canvas.Builder.init(&scaled_commands);
    try canvas.emitWidgetLayout(
        &scaled_builder,
        canvas.WidgetLayoutTree{ .nodes = &scaled_nodes },
        .{},
    );
    var drawn_lines: usize = 0;
    for (scaled_builder.displayList().commands) |command| {
        if (command == .draw_text) drawn_lines += 1;
    }
    try testing.expectEqual(@as(usize, 140), drawn_lines);
}

test "scaled code degrades under the display-list command budget" {
    const source = ("x\n" ** 2999) ++ "x";
    const spans = [_]canvas.TextSpan{.{
        .text = source,
        .monospace = true,
        .color = .syntax_plain,
    }};
    const nodes = [_]canvas.WidgetLayoutNode{
        .{
            .widget = .{ .id = 1, .kind = .stack },
            .frame = geometry.RectF.init(0, 0, 100, 100),
            .depth = 0,
        },
        .{
            .widget = .{
                .id = 2,
                .kind = .text,
                .text = source,
                .spans = &spans,
                .transform = canvas.Affine.scale(0.001, 0.001),
            },
            .frame = geometry.RectF.init(0, 0, 20, 52_500),
            .depth = 1,
            .parent_index = 0,
        },
    };
    var commands: [2048]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try canvas.emitWidgetLayout(
        &builder,
        canvas.WidgetLayoutTree{ .nodes = &nodes },
        .{},
    );

    var drawn_lines: usize = 0;
    for (builder.displayList().commands) |command| {
        if (command == .draw_text) drawn_lines += 1;
    }
    try testing.expect(drawn_lines > 0);
    try testing.expect(drawn_lines < 3000);
    try testing.expect(builder.displayList().commands.len < commands.len);
}

test "scaled long code line degrades under the display-list text budget" {
    const source = "x" ** 65_536;
    const preceding_text = "y" ** 20_000;
    const spans = [_]canvas.TextSpan{.{
        .text = source,
        .monospace = true,
        .color = .syntax_plain,
    }};
    const nodes = [_]canvas.WidgetLayoutNode{
        .{
            .widget = .{ .id = 1, .kind = .stack },
            .frame = geometry.RectF.init(0, 0, 1000, 100),
            .depth = 0,
        },
        .{
            .widget = .{
                .id = 2,
                .kind = .text,
                .text = source,
                .spans = &spans,
                .text_no_wrap = true,
                .transform = canvas.Affine.scale(0.001, 0.001),
            },
            .frame = geometry.RectF.init(0, 0, 400_000, 20),
            .depth = 1,
            .parent_index = 0,
        },
    };
    var commands: [64]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try builder.drawText(.{
        .id = 99,
        .font_id = 2,
        .size = 12,
        .origin = geometry.PointF.init(0, 0),
        .color = canvas.Color.rgb8(255, 255, 255),
        .text = preceding_text,
    });
    try canvas.emitWidgetLayout(
        &builder,
        canvas.WidgetLayoutTree{ .nodes = &nodes },
        .{},
    );

    const text_bytes = displayListTextBytes(builder.displayList());
    try testing.expect(text_bytes > preceding_text.len);
    try testing.expect(text_bytes <= canvas.max_display_list_text_bytes);
    try testing.expect(text_bytes < preceding_text.len + source.len);
}

test "wrapped code keeps an over-capacity logical line in one paragraph" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "// ");
    for (0..130) |_| try source.appendSlice(testing.allocator, "é");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const view = try ui.finalize(ui.code(.{ .language = .zig }, source.items));

    try testing.expectEqual(@as(usize, 1), countByKind(view.root, .text));
    try testing.expect(allTextSpansHaveColor(view.root, .syntax_comment));

    const text_widget = findByKind(view.root, .text).?;
    var runs: [text_spans.max_text_span_runs_per_paragraph]text_spans.TextSpanRun = undefined;
    const wide_layout = text_spans.layoutTextSpans(
        text_widget.spans,
        .{ .size = 14, .max_width = 10_000 },
        &runs,
    );
    try testing.expectEqual(@as(usize, 1), wide_layout.line_count);
    try testing.expect(!wide_layout.truncated);

    var recovered: std.ArrayListUnmanaged(u8) = .empty;
    defer recovered.deinit(testing.allocator);
    try appendTextWidgets(view.root, &recovered, testing.allocator);
    try testing.expectEqualStrings(source.items, recovered.items);
}

test "numbered code keeps one selectable source paragraph at its limit" {
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..Ui.max_code_lines) |_| {
        try source.append(testing.allocator, 'x');
        try source.append(testing.allocator, '\n');
    }

    var numbered_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer numbered_arena.deinit();
    var numbered_ui = Ui.init(numbered_arena.allocator());
    const numbered = try numbered_ui.finalize(numbered_ui.code(.{
        .line_numbers = true,
        .wrap = false,
    }, source.items));

    var numbered_nodes: [1024]canvas.WidgetLayoutNode = undefined;
    const numbered_layout = try canvas.layoutWidgetTree(
        numbered.root,
        geometry.RectF.init(0, 0, 320, 4000),
        &numbered_nodes,
    );
    // Panel + horizontal scroll + track + one source paragraph +
    // scrollbar spacer. Gutter markers are renderer-owned decoration.
    try testing.expectEqual(@as(usize, 5), numbered_layout.nodes.len);
    try testing.expectEqual(@as(usize, 1), countByKind(numbered.root, .text));
    try testing.expectEqual(
        @as(u8, 3),
        findByText(numbered.root, source.items).?.code_line_number_digits,
    );

    try source.append(testing.allocator, 'x');
    var fallback_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer fallback_arena.deinit();
    var fallback_ui = Ui.init(fallback_arena.allocator());
    const fallback = try fallback_ui.finalize(fallback_ui.code(.{
        .line_numbers = true,
        .wrap = false,
    }, source.items));
    try testing.expectEqual(
        @as(u8, 0),
        findByKind(fallback.root, .text).?.code_line_number_digits,
    );
    var fallback_nodes: [1024]canvas.WidgetLayoutNode = undefined;
    _ = try canvas.layoutWidgetTree(
        fallback.root,
        geometry.RectF.init(0, 0, 320, 4000),
        &fallback_nodes,
    );

    var long_source: std.ArrayListUnmanaged(u8) = .empty;
    defer long_source.deinit(testing.allocator);
    for (0..100) |line_index| {
        if (line_index > 0) try long_source.append(testing.allocator, '\n');
        for (0..130) |_| try long_source.append(testing.allocator, 'x');
    }
    var long_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer long_arena.deinit();
    var long_ui = Ui.init(long_arena.allocator());
    const long_fallback = try long_ui.finalize(long_ui.code(.{
        .line_numbers = true,
    }, long_source.items));
    // Long logical lines remain one selectable paragraph even when their
    // visual wrapping crosses the painter's first retained line page.
    try testing.expectEqual(@as(usize, 1), countByKind(long_fallback.root, .text));
    try testing.expectEqual(
        @as(u8, 3),
        findByText(long_fallback.root, long_source.items).?.code_line_number_digits,
    );
    var long_nodes: [1024]canvas.WidgetLayoutNode = undefined;
    _ = try canvas.layoutWidgetTree(
        long_fallback.root,
        geometry.RectF.init(0, 0, 320, 20_000),
        &long_nodes,
    );
}

test "token-dense numbered code preserves all source in one paragraph" {
    const dense_line = "const a0 = 0; const a1 = 1; const a2 = 2;";
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..79) |line_index| {
        if (line_index > 0) try source.append(testing.allocator, '\n');
        try source.appendSlice(testing.allocator, dense_line);
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ui = Ui.init(arena.allocator());
    const fallback = try ui.finalize(ui.code(.{
        .language = .zig,
        .line_numbers = true,
    }, source.items));

    try testing.expectEqual(@as(usize, 1), countByKind(fallback.root, .text));
    try testing.expect(countTextSpans(fallback.root) <= text_spans.max_text_spans_per_paragraph);
    try testing.expectEqual(
        @as(u8, 2),
        findByText(fallback.root, source.items).?.code_line_number_digits,
    );

    var recovered: std.ArrayListUnmanaged(u8) = .empty;
    defer recovered.deinit(testing.allocator);
    try appendTextWidgets(fallback.root, &recovered, testing.allocator);
    try testing.expectEqualStrings(source.items, recovered.items);
}

test "unwrapped multiline intrinsic width is the widest logical line" {
    const spans = [_]canvas.TextSpan{
        .{ .text = "12345\n12", .monospace = true },
        .{ .text = "345", .monospace = true },
    };
    const options = canvas.TextSpanLayoutOptions{ .size = 10, .wrap = .none };
    const combined = [_]canvas.TextSpan{.{ .text = "12345", .monospace = true }};
    try testing.expectApproxEqAbs(
        text_spans.textSpansIntrinsicWidth(&combined, options),
        text_spans.textSpansIntrinsicWidth(&spans, options),
        0.001,
    );
}
