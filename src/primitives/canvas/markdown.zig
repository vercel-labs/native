//! `zero_native.markdown` — a GitHub-flavored-markdown subset mapped onto
//! the widget tree + inline span model.
//!
//! `Markdown(Msg).view(ui, source, options)` returns an ordinary builder
//! node usable inside any hand-written `view` fn: blocks become the same
//! widgets an author would compose by hand (columns, rows, panels,
//! checkboxes, separators) and inline styling becomes span paragraphs, so
//! layout, theming, semantics, and hit-testing all come from the existing
//! engine.
//!
//! Supported blocks: `#`/`##`/`###` headings (deeper levels clamp to h3),
//! paragraphs, bullet/ordered/task lists (nesting up to
//! `max_markdown_list_depth` by two-space indent), fenced code blocks,
//! `>` blockquotes, horizontal rules, and `<details>`/`<summary>`.
//! Supported inlines: `**bold**`/`__bold__`, `*italic*`/`_italic_`,
//! `` `code` ``, `~~strikethrough~~`, `[text](url)` links, `<url>`
//! autolinks, and `![alt](url)` images (rendered as their alt text).
//!
//! Deliberately unsupported in v1 (rendered as plain paragraph text, never
//! a build failure): tables, setext headings, indented code blocks,
//! backslash escapes, reference-style links, raw HTML other than
//! details/summary, and footnotes. Malformed input degrades to literal
//! text.
//!
//! State model (Elm-style, no hidden state):
//! - Task-list checkboxes render as disabled checkboxes — display only.
//! - `<details>` blocks are collapsible through the CALLER's model: pass
//!   `details_expanded` (flags indexed by details-block order in the
//!   document) and `on_details` (a Msg constructor receiving that index).
//!   The recommended wiring is a bounded bool array in the model that
//!   `update` toggles on the details message:
//!
//!   ```zig
//!   const Msg = union(enum) { open_url: []const u8, toggle_details: usize };
//!   // model.details_expanded: [8]bool = .{false} ** 8;
//!   markdown.view(ui, source, .{
//!       .on_link = Ui.linkMsg(.open_url),
//!       .on_details = Md.detailsMsg(.toggle_details),
//!       .details_expanded = &model.details_expanded,
//!   });
//!   ```
//!
//! Std-only, allocator-explicit: every allocation goes through the
//! builder's arena, and node/span buffers are capacity-bounded; documents
//! that exceed a capacity truncate deterministically.

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const text_spans = @import("text_spans.zig");
const ui_builder = @import("ui.zig");

const TextSpan = text_spans.TextSpan;

/// Capacity conventions (`canvas_limits` style): blocks per container,
/// list nesting depth, and details blocks per document. Overflow keeps
/// the tree valid and drops trailing content.
pub const max_markdown_blocks_per_container: usize = 64;
pub const max_markdown_list_items_per_list: usize = 64;
pub const max_markdown_list_depth: usize = 4;
pub const max_markdown_details_per_document: usize = 16;

/// Heading scales relative to the body typography token (GitHub's em
/// ladder), applied through the span `scale` channel so heading pixel
/// sizes stay derived from live tokens.
pub const heading_scales = [_]f32{ 2.0, 1.5, 1.25 };

pub fn Markdown(comptime Msg: type) type {
    return struct {
        pub const Ui = ui_builder.Ui(Msg);
        const Node = Ui.Node;

        pub const Options = struct {
            /// Msg constructor for link presses (pair with `Ui.linkMsg`).
            /// Null renders links styled but inert.
            on_link: ?Ui.LinkMsgFn = null,
            /// Msg constructor for `<details>` summary presses; receives
            /// the details block's document-order index. Pair with
            /// `detailsMsg`. Null renders summaries inert.
            on_details: ?*const fn (index: usize) Msg = null,
            /// Expanded flags for `<details>` blocks in document order;
            /// blocks beyond the slice render collapsed.
            details_expanded: []const bool = &.{},
        };

        /// Comptime message constructor for `on_details`:
        /// `detailsMsg(.toggle_details)` yields a function building
        /// `Msg{ .toggle_details = index }`.
        pub fn detailsMsg(comptime tag: std.meta.Tag(Msg)) *const fn (index: usize) Msg {
            return struct {
                fn make(index: usize) Msg {
                    return @unionInit(Msg, @tagName(tag), index);
                }
            }.make;
        }

        /// Map a markdown source into a widget subtree. Never fails: arena
        /// exhaustion latches on the builder (surfacing from `finalize`,
        /// the existing convention) and malformed markdown degrades to
        /// plain text.
        pub fn view(ui: *Ui, source: []const u8, options: Options) Node {
            var builder = Builder{ .ui = ui, .options = options };
            var lines = LineIterator{ .source = source };
            const blocks = builder.parseBlocks(&lines, .document);
            return ui.column(.{ .gap = 12 }, blocks);
        }

        const BlockScope = enum {
            document,
            details,
        };

        const Builder = struct {
            ui: *Ui,
            options: Options,
            details_count: usize = 0,

            fn allocNodes(self: *Builder) []Node {
                return self.ui.arena.alloc(Node, max_markdown_blocks_per_container) catch {
                    self.ui.failed = true;
                    return &.{};
                };
            }

            fn parseBlocks(self: *Builder, lines: *LineIterator, scope: BlockScope) []const Node {
                const nodes = self.allocNodes();
                if (nodes.len == 0) return &.{};
                var len: usize = 0;

                while (lines.peek()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t");
                    if (scope == .details and std.ascii.startsWithIgnoreCase(trimmed, "</details>")) {
                        _ = lines.next();
                        break;
                    }
                    if (trimmed.len == 0) {
                        _ = lines.next();
                        continue;
                    }
                    const node = self.parseBlock(lines) orelse continue;
                    if (len >= nodes.len) break;
                    nodes[len] = node;
                    len += 1;
                }
                return nodes[0..len];
            }

            fn parseBlock(self: *Builder, lines: *LineIterator) ?Node {
                const line = lines.peek() orelse return null;
                const trimmed = std.mem.trim(u8, line, " \t");

                if (std.mem.startsWith(u8, trimmed, "```")) return self.parseCodeFence(lines);
                if (headingLevel(trimmed)) |level| {
                    _ = lines.next();
                    return self.heading(level, std.mem.trim(u8, trimmed[level..], " \t#"));
                }
                if (isHorizontalRule(trimmed)) {
                    _ = lines.next();
                    return self.ui.separator(.{});
                }
                if (std.mem.startsWith(u8, trimmed, ">")) return self.parseBlockquote(lines);
                if (listMarker(line)) |_| return self.parseList(lines, 0, 0);
                if (std.ascii.startsWithIgnoreCase(trimmed, "<details")) return self.parseDetails(lines);
                return self.parseParagraph(lines);
            }

            // ------------------------------------------------------ blocks

            fn heading(self: *Builder, level: usize, content: []const u8) Node {
                const scale = heading_scales[@min(level, heading_scales.len) - 1];
                var spans: [text_spans.max_text_spans_per_paragraph]TextSpan = undefined;
                const parsed = self.parseInline(content, .{ .weight = .bold, .scale = scale }, &spans);
                return self.ui.paragraph(.{ .on_link = self.options.on_link }, parsed);
            }

            fn parseParagraph(self: *Builder, lines: *LineIterator) ?Node {
                var text: []const u8 = &.{};
                while (lines.peek()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t");
                    if (trimmed.len == 0) break;
                    if (text.len > 0 and startsNewBlock(line)) break;
                    _ = lines.next();
                    text = self.joinLine(text, trimmed);
                    if (self.ui.failed) return null;
                }
                if (text.len == 0) return null;
                return self.paragraphNode(text, .{});
            }

            fn paragraphNode(self: *Builder, text: []const u8, base: TextSpan) Node {
                var spans: [text_spans.max_text_spans_per_paragraph]TextSpan = undefined;
                const parsed = self.parseInline(text, base, &spans);
                return self.ui.paragraph(.{ .on_link = self.options.on_link }, parsed);
            }

            fn parseCodeFence(self: *Builder, lines: *LineIterator) ?Node {
                _ = lines.next(); // opening fence (info string ignored)
                const start = lines.index;
                var end = start;
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "```")) break;
                    end = lines.index;
                }
                const code = std.mem.trimEnd(u8, lines.source[start..@min(end, lines.source.len)], "\n");
                const code_span = [_]TextSpan{.{ .text = code, .monospace = true }};
                return self.ui.el(.panel, .{
                    .padding = 12,
                    .style_tokens = .{ .background = .surface_subtle },
                }, .{
                    self.ui.paragraph(.{}, &code_span),
                });
            }

            fn parseBlockquote(self: *Builder, lines: *LineIterator) ?Node {
                var text: []const u8 = &.{};
                while (lines.peek()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t");
                    if (!std.mem.startsWith(u8, trimmed, ">")) break;
                    _ = lines.next();
                    var inner = trimmed[1..];
                    if (std.mem.startsWith(u8, inner, " ")) inner = inner[1..];
                    text = self.joinLine(text, std.mem.trim(u8, inner, " \t"));
                    if (self.ui.failed) return null;
                }
                if (text.len == 0) return null;
                return self.ui.row(.{ .gap = 10 }, .{
                    self.ui.el(.separator, .{ .frame = geometry.RectF.init(0, 0, 3, 0) }, .{}),
                    self.paragraphWithOptions(text, .{ .grow = 1, .style_tokens = .{ .foreground = .text_muted } }),
                });
            }

            fn paragraphWithOptions(self: *Builder, text: []const u8, options_in: Ui.ElementOptions) Node {
                var options = options_in;
                options.on_link = self.options.on_link;
                var spans: [text_spans.max_text_spans_per_paragraph]TextSpan = undefined;
                const parsed = self.parseInline(text, .{}, &spans);
                return self.ui.paragraph(options, parsed);
            }

            fn parseList(self: *Builder, lines: *LineIterator, indent: usize, depth: usize) ?Node {
                const items = self.ui.arena.alloc(Node, max_markdown_list_items_per_list) catch {
                    self.ui.failed = true;
                    return null;
                };
                var len: usize = 0;

                while (lines.peek()) |line| {
                    const marker = listMarker(line) orelse break;
                    if (marker.indent < indent) break;
                    if (marker.indent > indent) {
                        // Deeper marker: a nested list under the previous item.
                        if (len == 0 or depth + 1 >= max_markdown_list_depth) {
                            _ = lines.next();
                            continue;
                        }
                        const nested = self.parseList(lines, marker.indent, depth + 1) orelse continue;
                        items[len - 1] = self.ui.column(.{ .gap = 4 }, .{ items[len - 1], nested });
                        continue;
                    }
                    _ = lines.next();
                    if (len >= items.len) continue;
                    items[len] = self.listItemNode(marker, depth);
                    len += 1;
                }
                if (len == 0) return null;
                return self.ui.column(.{ .gap = 4 }, .{items[0..len]});
            }

            fn listItemNode(self: *Builder, marker: ListMarker, depth: usize) Node {
                const content = self.paragraphWithOptions(marker.content, .{ .grow = 1 });
                const lead: Node = switch (marker.kind) {
                    .bullet => self.ui.text(.{}, "•"),
                    .ordered => self.ui.text(.{}, marker.label),
                    .task => self.ui.checkbox(.{
                        .checked = marker.checked,
                        .disabled = true,
                        .semantics = .{ .label = marker.content },
                    }),
                };
                if (depth == 0) return self.ui.row(.{ .gap = 8 }, .{ lead, content });
                const indent = self.ui.el(.stack, .{ .width = @as(f32, @floatFromInt(depth)) * 16 }, .{});
                return self.ui.row(.{ .gap = 8 }, .{ indent, lead, content });
            }

            fn parseDetails(self: *Builder, lines: *LineIterator) ?Node {
                _ = lines.next(); // <details ...>
                const ordinal = self.details_count;
                if (ordinal >= max_markdown_details_per_document) {
                    self.skipDetails(lines);
                    return null;
                }
                self.details_count += 1;
                const expanded = ordinal < self.options.details_expanded.len and self.options.details_expanded[ordinal];

                var summary: []const u8 = "Details";
                if (lines.peek()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t");
                    if (std.ascii.startsWithIgnoreCase(trimmed, "<summary>")) {
                        _ = lines.next();
                        summary = trimmed["<summary>".len..];
                        if (std.ascii.indexOfIgnoreCase(summary, "</summary>")) |close| {
                            summary = summary[0..close];
                        }
                        summary = std.mem.trim(u8, summary, " \t");
                    }
                }

                var header = self.ui.listItem(.{
                    .key = .{ .int = @intCast(ordinal) },
                    .on_press = if (self.options.on_details) |make| make(ordinal) else null,
                }, self.ui.fmt("{s} {s}", .{ if (expanded) "▾" else "▸", summary }));
                header.widget.state.expanded = expanded;

                if (!expanded) {
                    self.skipDetails(lines);
                    return self.ui.column(.{ .gap = 4 }, .{header});
                }
                const blocks = self.parseBlocks(lines, .details);
                const body = self.ui.column(.{ .gap = 12, .padding = 8 }, blocks);
                return self.ui.column(.{ .gap = 4 }, .{ header, body });
            }

            fn skipDetails(self: *Builder, lines: *LineIterator) void {
                _ = self;
                var depth: usize = 1;
                while (lines.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t");
                    if (std.ascii.startsWithIgnoreCase(trimmed, "<details")) depth += 1;
                    if (std.ascii.startsWithIgnoreCase(trimmed, "</details>")) {
                        depth -= 1;
                        if (depth == 0) return;
                    }
                }
            }

            fn joinLine(self: *Builder, text: []const u8, line: []const u8) []const u8 {
                if (text.len == 0) return line;
                return self.ui.fmt("{s} {s}", .{ text, line });
            }

            // ----------------------------------------------------- inlines

            /// Scan inline markdown into spans carrying `base` styling
            /// (headings pass bold + scale). Delimiters without a closer,
            /// and any construct this subset does not model, fall through
            /// as literal text. Span-capacity overflow appends the rest of
            /// the text as one unstyled span.
            fn parseInline(self: *Builder, text: []const u8, base: TextSpan, spans: *[text_spans.max_text_spans_per_paragraph]TextSpan) []const TextSpan {
                _ = self;
                var len: usize = 0;
                var bold = false;
                var italic = false;
                var strike = false;
                var literal_start: usize = 0;
                var index: usize = 0;

                while (index < text.len) {
                    if (len + 2 >= spans.len) break;
                    const rest = text[index..];

                    if (rest[0] == '`') {
                        if (std.mem.indexOfScalar(u8, rest[1..], '`')) |close| {
                            flushLiteral(spans, &len, text[literal_start..index], base, bold, italic, strike);
                            appendSpan(spans, &len, spanWith(base, .{ .text = rest[1 .. 1 + close], .monospace = true }));
                            index += close + 2;
                            literal_start = index;
                            continue;
                        }
                    } else if (std.mem.startsWith(u8, rest, "**") or std.mem.startsWith(u8, rest, "__")) {
                        const delim = rest[0..2];
                        if (bold or hasCloser(rest[2..], delim)) {
                            flushLiteral(spans, &len, text[literal_start..index], base, bold, italic, strike);
                            bold = !bold;
                            index += 2;
                            literal_start = index;
                            continue;
                        }
                    } else if (std.mem.startsWith(u8, rest, "~~")) {
                        if (strike or hasCloser(rest[2..], "~~")) {
                            flushLiteral(spans, &len, text[literal_start..index], base, bold, italic, strike);
                            strike = !strike;
                            index += 2;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == '*' or rest[0] == '_') {
                        const delim = rest[0..1];
                        const boundary_ok = rest[0] == '*' or index == 0 or !isWordByte(text[index - 1]);
                        const emphasis_ok = if (italic)
                            true
                        else
                            rest.len > 1 and !isInlineSpace(rest[1]) and hasCloser(rest[1..], delim);
                        if (boundary_ok and emphasis_ok) {
                            flushLiteral(spans, &len, text[literal_start..index], base, bold, italic, strike);
                            italic = !italic;
                            index += 1;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == '[') {
                        if (parseLinkAt(rest)) |link| {
                            flushLiteral(spans, &len, text[literal_start..index], base, bold, italic, strike);
                            appendSpan(spans, &len, spanWith(base, .{ .text = link.text, .link = link.target }));
                            index += link.consumed;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == '!' and rest.len > 1 and rest[1] == '[') {
                        if (parseLinkAt(rest[1..])) |image| {
                            // Images render as their alt text in v1.
                            flushLiteral(spans, &len, text[literal_start..index], base, bold, italic, strike);
                            appendSpan(spans, &len, spanWith(base, .{ .text = image.text }));
                            index += image.consumed + 1;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == '<') {
                        if (parseAutolinkAt(rest)) |link| {
                            flushLiteral(spans, &len, text[literal_start..index], base, bold, italic, strike);
                            appendSpan(spans, &len, spanWith(base, .{ .text = link.text, .link = link.target }));
                            index += link.consumed;
                            literal_start = index;
                            continue;
                        }
                    }
                    index += 1;
                }
                // Tail (including everything after a span-capacity stop),
                // styled with the state at the stop point.
                flushLiteral(spans, &len, text[literal_start..], base, bold, italic, strike);
                if (len == 0) {
                    spans[0] = spanWith(base, .{ .text = text });
                    len = 1;
                }
                return spans[0..len];
            }

            fn flushLiteral(
                spans: *[text_spans.max_text_spans_per_paragraph]TextSpan,
                len: *usize,
                slice: []const u8,
                base: TextSpan,
                bold: bool,
                italic: bool,
                strike: bool,
            ) void {
                if (slice.len == 0) return;
                var span = spanWith(base, .{ .text = slice });
                if (bold) span.weight = .bold;
                if (italic) span.italic = true;
                if (strike) span.strikethrough = true;
                appendSpan(spans, len, span);
            }

            fn appendSpan(spans: *[text_spans.max_text_spans_per_paragraph]TextSpan, len: *usize, span: TextSpan) void {
                if (len.* >= spans.len) return;
                spans[len.*] = span;
                len.* += 1;
            }

            fn spanWith(base: TextSpan, overrides: TextSpan) TextSpan {
                var span = overrides;
                if (span.weight == .regular) span.weight = base.weight;
                if (!span.italic) span.italic = base.italic;
                if (!span.strikethrough) span.strikethrough = base.strikethrough;
                if (span.scale == 0) span.scale = base.scale;
                if (span.color == null) span.color = base.color;
                return span;
            }
        };
    };
}

// ------------------------------------------------------------ line model

const LineIterator = struct {
    source: []const u8,
    index: usize = 0,

    fn next(self: *LineIterator) ?[]const u8 {
        if (self.index >= self.source.len) return null;
        const start = self.index;
        const end = std.mem.indexOfScalarPos(u8, self.source, start, '\n') orelse self.source.len;
        self.index = @min(end + 1, self.source.len);
        return std.mem.trimEnd(u8, self.source[start..end], "\r");
    }

    fn peek(self: *LineIterator) ?[]const u8 {
        var copy = self.*;
        return copy.next();
    }
};

fn headingLevel(line: []const u8) ?usize {
    var level: usize = 0;
    while (level < line.len and line[level] == '#') level += 1;
    if (level == 0 or level > 6) return null;
    if (level < line.len and line[level] != ' ') return null;
    return level;
}

fn isHorizontalRule(line: []const u8) bool {
    if (line.len < 3) return false;
    const marker = line[0];
    if (marker != '-' and marker != '*' and marker != '_') return false;
    var count: usize = 0;
    for (line) |byte| {
        if (byte == marker) {
            count += 1;
        } else if (byte != ' ') {
            return false;
        }
    }
    return count >= 3;
}

const ListMarkerKind = enum { bullet, ordered, task };

const ListMarker = struct {
    kind: ListMarkerKind,
    /// Nesting level derived from leading spaces (two per level).
    indent: usize,
    /// Ordinal label for ordered items ("3."), empty otherwise.
    label: []const u8,
    checked: bool = false,
    content: []const u8,
};

fn listMarker(line: []const u8) ?ListMarker {
    var spaces: usize = 0;
    while (spaces < line.len and line[spaces] == ' ') spaces += 1;
    const indent = @min(spaces / 2, max_markdown_list_depth - 1);
    const rest = line[spaces..];
    if (rest.len < 2) return null;

    if ((rest[0] == '-' or rest[0] == '*' or rest[0] == '+') and rest[1] == ' ') {
        const content = std.mem.trim(u8, rest[2..], " \t");
        if (std.mem.startsWith(u8, content, "[ ] ")) {
            return .{ .kind = .task, .indent = indent, .label = "", .checked = false, .content = content[4..] };
        }
        if (std.mem.startsWith(u8, content, "[x] ") or std.mem.startsWith(u8, content, "[X] ")) {
            return .{ .kind = .task, .indent = indent, .label = "", .checked = true, .content = content[4..] };
        }
        return .{ .kind = .bullet, .indent = indent, .label = "", .content = content };
    }

    var digits: usize = 0;
    while (digits < rest.len and std.ascii.isDigit(rest[digits])) digits += 1;
    if (digits > 0 and digits + 1 < rest.len and rest[digits] == '.' and rest[digits + 1] == ' ') {
        return .{
            .kind = .ordered,
            .indent = indent,
            .label = rest[0 .. digits + 1],
            .content = std.mem.trim(u8, rest[digits + 2 ..], " \t"),
        };
    }
    return null;
}

fn startsNewBlock(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return true;
    if (std.mem.startsWith(u8, trimmed, "```")) return true;
    if (headingLevel(trimmed) != null) return true;
    if (isHorizontalRule(trimmed)) return true;
    if (std.mem.startsWith(u8, trimmed, ">")) return true;
    if (listMarker(line) != null) return true;
    if (std.ascii.startsWithIgnoreCase(trimmed, "<details")) return true;
    return false;
}

const InlineLink = struct {
    text: []const u8,
    target: []const u8,
    consumed: usize,
};

/// Parse `[text](target)` at the start of `rest`; null when malformed
/// (the caller then treats `[` as literal text).
fn parseLinkAt(rest: []const u8) ?InlineLink {
    if (rest.len < 4 or rest[0] != '[') return null;
    const close_bracket = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
    if (close_bracket + 1 >= rest.len or rest[close_bracket + 1] != '(') return null;
    const close_paren = std.mem.indexOfScalarPos(u8, rest, close_bracket + 2, ')') orelse return null;
    const text = rest[1..close_bracket];
    var target = rest[close_bracket + 2 .. close_paren];
    // Strip an optional title: [text](url "title").
    if (std.mem.indexOfScalar(u8, target, ' ')) |space| target = target[0..space];
    if (text.len == 0 or target.len == 0) return null;
    return .{ .text = text, .target = target, .consumed = close_paren + 1 };
}

/// Parse `<scheme://...>` autolinks at the start of `rest`.
fn parseAutolinkAt(rest: []const u8) ?InlineLink {
    if (rest.len < 3 or rest[0] != '<') return null;
    const close = std.mem.indexOfScalar(u8, rest, '>') orelse return null;
    const target = rest[1..close];
    if (std.mem.indexOf(u8, target, "://") == null) return null;
    if (std.mem.indexOfScalar(u8, target, ' ') != null) return null;
    return .{ .text = target, .target = target, .consumed = close + 1 };
}

fn hasCloser(rest: []const u8, delim: []const u8) bool {
    return std.mem.indexOf(u8, rest, delim) != null;
}

fn isInlineSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn isWordByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}
