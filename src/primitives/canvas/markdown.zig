//! `native_sdk.markdown` — a GitHub-flavored-markdown subset mapped onto
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
//! `max_markdown_list_depth` by two-space indent), fenced code blocks
//! (source indentation preserved and language-tagged fences highlighted),
//! `>` blockquotes, horizontal rules, GFM pipe tables (header row +
//! delimiter row + body rows onto `table`/`data_row`/`data_cell` widgets;
//! `:---`/`:--:`/`---:` delimiter cells set per-column start/center/end
//! text alignment, header cells render bold, and every cell runs the full
//! inline span grammar including links), and `<details>`/`<summary>`.
//! Supported inlines: `**bold**`/`__bold__`, `*italic*`/`_italic_`,
//! `` `code` ``, `~~strikethrough~~`, `[text](url)` links, `<url>`
//! autolinks, bare `http(s)://` URLs at word boundaries (GFM-style
//! autolink extension, trailing punctuation trimmed), `#123` issue
//! references (opt-in via `Options.issue_link_base`, since resolving a
//! ref needs repo context), and `![alt](url)` images (rendered as their
//! alt text).
//!
//! Deliberately unsupported in v1 (rendered as plain paragraph text, never
//! a build failure): setext headings, indented code blocks, backslash
//! escapes (except `\|` inside table rows, which GFM needs to put a pipe
//! in a cell), reference-style links, raw HTML other than
//! details/summary, and footnotes. Malformed input degrades to literal
//! text — a pipe block whose delimiter row is missing or does not match
//! the header's column count renders as plain paragraphs, and tables
//! wider than `max_markdown_table_columns` degrade the same way rather
//! than silently dropping columns.
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
const code_model = @import("code.zig");
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
pub const max_markdown_table_columns: usize = 8;
/// Rows per table including the header; trailing rows drop deterministically.
pub const max_markdown_table_rows: usize = 64;
/// Joined bytes per paragraph or blockquote (consecutive source lines
/// collapse into one text widget). Sized generously past real GitHub
/// prose — paragraphs beyond a couple of KiB are pathological input —
/// and well under the runtime's per-view widget-text budget, so a
/// hostile megabyte-long "paragraph" truncates deterministically here
/// instead of ballooning the build arena. The block's remaining lines
/// are still consumed, so parsing resumes at the next block.
pub const max_markdown_paragraph_bytes: usize = 8192;

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
            /// Non-null turns `#123` issue references at word boundaries
            /// (issue-tracker-client semantics: not preceded by a word
            /// byte, `/`, or `&`; digits end at a word boundary) into
            /// link spans whose target is this prefix followed by the
            /// number — an app scheme (`"ghissue://"`) or a web base
            /// (`"https://github.com/owner/repo/issues/"`). The press
            /// dispatches through `on_link` like any other link. Null
            /// keeps refs as plain text (they need repo context to
            /// resolve, so there is no default).
            issue_link_base: ?[]const u8 = null,
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
                if (isTableStart(lines)) return self.parseTable(lines);
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
                const text = self.collectJoined(lines, .paragraph);
                if (text.len == 0) return null;
                return self.paragraphNode(text, .{});
            }

            const JoinKind = enum { paragraph, blockquote };

            /// The next joined piece of a paragraph or blockquote at
            /// `lines`' current position, or null when the block ends
            /// there. `joined_len` is the text joined so far (the
            /// paragraph break rules only apply once the block has
            /// content). Tables interrupt paragraphs (GFM): a header
            /// line followed by a matching delimiter row starts a table.
            fn joinPiece(lines: *LineIterator, kind: JoinKind, joined_len: usize) ?[]const u8 {
                const line = lines.peek() orelse return null;
                const trimmed = std.mem.trim(u8, line, " \t");
                switch (kind) {
                    .blockquote => {
                        if (!std.mem.startsWith(u8, trimmed, ">")) return null;
                        var inner = trimmed[1..];
                        if (std.mem.startsWith(u8, inner, " ")) inner = inner[1..];
                        return std.mem.trim(u8, inner, " \t");
                    },
                    .paragraph => {
                        if (trimmed.len == 0) return null;
                        if (joined_len > 0 and (startsNewBlock(line) or isTableStart(lines))) return null;
                        return trimmed;
                    },
                }
            }

            /// Join a block's consecutive lines with single spaces into
            /// ONE arena allocation. Measuring first keeps hostile input
            /// linear: re-joining per line is quadratic in both time and
            /// arena memory (a megabyte-long single paragraph used to
            /// demand gigabytes). Joined text truncates deterministically
            /// at `max_markdown_paragraph_bytes`; the block's remaining
            /// lines are still consumed either way.
            fn collectJoined(self: *Builder, lines: *LineIterator, kind: JoinKind) []const u8 {
                // Pass 1: measure the block's extent and joined size.
                var probe = lines.*;
                var total: usize = 0;
                while (joinPiece(&probe, kind, total)) |piece| {
                    _ = probe.next();
                    if (total > 0) total += 1;
                    total += piece.len;
                }
                if (total == 0) {
                    lines.* = probe;
                    return &.{};
                }

                const out = self.ui.arena.alloc(u8, @min(total, max_markdown_paragraph_bytes)) catch {
                    self.ui.failed = true;
                    lines.* = probe;
                    return &.{};
                };

                // Pass 2: identical walk, copying until the cap.
                var len: usize = 0;
                var joined: usize = 0;
                while (joinPiece(lines, kind, joined)) |piece| {
                    _ = lines.next();
                    if (joined > 0 and len < out.len) {
                        out[len] = ' ';
                        len += 1;
                    }
                    if (joined > 0) joined += 1;
                    joined += piece.len;
                    const take = @min(piece.len, out.len - len);
                    @memcpy(out[len..][0..take], piece[0..take]);
                    len += take;
                }
                return out[0..len];
            }

            fn paragraphNode(self: *Builder, text: []const u8, base: TextSpan) Node {
                var spans: [text_spans.max_text_spans_per_paragraph]TextSpan = undefined;
                const parsed = self.parseInline(text, base, &spans);
                return self.ui.paragraph(.{ .on_link = self.options.on_link }, parsed);
            }

            fn parseCodeFence(self: *Builder, lines: *LineIterator) ?Node {
                const opening = lines.next() orelse return null;
                const language = code_model.languageFromFence(opening);
                const start = lines.index;
                var end = start;
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "```")) break;
                    end = lines.index;
                }
                const code = std.mem.trimEnd(u8, lines.source[start..@min(end, lines.source.len)], "\n");
                return self.ui.code(.{ .language = language }, code);
            }

            fn parseBlockquote(self: *Builder, lines: *LineIterator) ?Node {
                const text = self.collectJoined(lines, .blockquote);
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
                // The outer row must keep stretch alignment so a wrapped
                // paragraph receives the row's full measured height. A
                // one-child column consumes that stretched marker slot
                // while laying its marker at the slot's leading edge.
                const lead_top = self.ui.column(.{}, .{lead});
                if (depth == 0) return self.ui.row(.{ .gap = 8 }, .{ lead_top, content });
                const indent = self.ui.el(.stack, .{ .width = @as(f32, @floatFromInt(depth)) * 16 }, .{});
                return self.ui.row(.{ .gap = 8 }, .{ indent, lead_top, content });
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

            /// GFM pipe table: the caller (`isTableStart`) has verified a
            /// header row followed by a delimiter row with a matching
            /// column count. Body rows run until a blank line or a line
            /// without a pipe; short rows pad with empty cells and long
            /// rows drop trailing cells (GFM semantics). Rows past
            /// `max_markdown_table_rows` drop deterministically.
            fn parseTable(self: *Builder, lines: *LineIterator) ?Node {
                const header_line = lines.next() orelse return null;
                const header = splitTableRow(header_line) orelse return null;
                const delimiter_line = lines.next() orelse return null;
                const alignments = tableDelimiterAlignments(delimiter_line) orelse return null;
                if (alignments.len != header.len) return null;

                const rows = self.ui.arena.alloc(Node, max_markdown_table_rows) catch {
                    self.ui.failed = true;
                    return null;
                };
                rows[0] = self.tableRowNode(header, alignments, true);
                var len: usize = 1;
                while (lines.peek()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t");
                    if (trimmed.len == 0) break;
                    if (std.mem.indexOfScalar(u8, trimmed, '|') == null) break;
                    const row = splitTableRow(line) orelse break;
                    _ = lines.next();
                    if (len >= rows.len) continue;
                    rows[len] = self.tableRowNode(row, alignments, false);
                    len += 1;
                }
                return self.ui.el(.table, .{}, .{rows[0..len]});
            }

            fn tableRowNode(self: *Builder, row: TableRow, alignments: TableAlignments, is_header: bool) Node {
                const cells = self.ui.arena.alloc(Node, alignments.len) catch {
                    self.ui.failed = true;
                    return self.ui.el(.data_row, .{}, .{});
                };
                for (cells, 0..) |*cell, column| {
                    const content = if (column < row.len) row.cells[column] else "";
                    cell.* = self.tableCellNode(content, alignments.columns[column], is_header);
                }
                return self.ui.el(.data_row, .{}, .{cells});
            }

            /// One cell: a `data_cell` widget carrying inline spans (the
            /// full inline grammar, links included), per-column text
            /// alignment from the delimiter row, and bold header styling.
            fn tableCellNode(self: *Builder, content: []const u8, alignment: canvas.TextAlign, is_header: bool) Node {
                const text = self.unescapeTablePipes(content);
                const base: TextSpan = if (is_header) .{ .weight = .bold } else .{};
                var spans: [text_spans.max_text_spans_per_paragraph]TextSpan = undefined;
                const parsed = self.parseInline(text, base, &spans);
                var cell = self.ui.paragraph(.{
                    .grow = 1,
                    .padding = 8,
                    .on_link = self.options.on_link,
                }, parsed);
                cell.widget.kind = .data_cell;
                cell.widget.text_alignment = alignment;
                return cell;
            }

            /// `\|` is the one backslash escape tables need (a literal
            /// pipe inside a cell); everything else keeps the mapper's
            /// no-escapes policy.
            fn unescapeTablePipes(self: *Builder, text: []const u8) []const u8 {
                if (std.mem.indexOf(u8, text, "\\|") == null) return text;
                const out = self.ui.arena.alloc(u8, text.len) catch {
                    self.ui.failed = true;
                    return text;
                };
                var len: usize = 0;
                var index: usize = 0;
                while (index < text.len) : (index += 1) {
                    if (text[index] == '\\' and index + 1 < text.len and text[index + 1] == '|') continue;
                    out[len] = text[index];
                    len += 1;
                }
                return out[0..len];
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

            // ----------------------------------------------------- inlines

            /// Scan inline markdown into spans carrying `base` styling
            /// (headings pass bold + scale). Delimiters without a closer,
            /// and any construct this subset does not model, fall through
            /// as literal text. Span-capacity overflow appends the rest of
            /// the text as one unstyled span.
            fn parseInline(self: *Builder, text: []const u8, base: TextSpan, spans: *[text_spans.max_text_spans_per_paragraph]TextSpan) []const TextSpan {
                var len: usize = 0;
                var bold = false;
                var italic = false;
                var strike = false;
                var literal_start: usize = 0;
                var index: usize = 0;
                var scan_cache = ScanCache{};

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
                        if (parseLinkAt(text, index, &scan_cache)) |link| {
                            flushLiteral(spans, &len, text[literal_start..index], base, bold, italic, strike);
                            appendSpan(spans, &len, spanWith(base, .{ .text = link.text, .link = link.target }));
                            index += link.consumed;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == '!' and rest.len > 1 and rest[1] == '[') {
                        if (parseLinkAt(text, index + 1, &scan_cache)) |image| {
                            // Images render as their alt text in v1.
                            flushLiteral(spans, &len, text[literal_start..index], base, bold, italic, strike);
                            appendSpan(spans, &len, spanWith(base, .{ .text = image.text }));
                            index += image.consumed + 1;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == '<') {
                        if (parseAutolinkAt(text, index, &scan_cache)) |link| {
                            flushLiteral(spans, &len, text[literal_start..index], base, bold, italic, strike);
                            appendSpan(spans, &len, spanWith(base, .{ .text = link.text, .link = link.target }));
                            index += link.consumed;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == 'h' and atAutolinkBoundary(text, index)) {
                        if (parseBareUrlAt(rest)) |link| {
                            flushLiteral(spans, &len, text[literal_start..index], base, bold, italic, strike);
                            appendSpan(spans, &len, spanWith(base, .{ .text = link.text, .link = link.target }));
                            index += link.consumed;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == '#' and atAutolinkBoundary(text, index)) {
                        if (self.options.issue_link_base) |issue_base| {
                            if (parseIssueRefAt(rest)) |ref| {
                                flushLiteral(spans, &len, text[literal_start..index], base, bold, italic, strike);
                                appendSpan(spans, &len, spanWith(base, .{
                                    .text = rest[0..ref.consumed],
                                    .link = self.ui.fmt("{s}{s}", .{ issue_base, ref.digits }),
                                }));
                                index += ref.consumed;
                                literal_start = index;
                                continue;
                            }
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

    fn peekSecond(self: *LineIterator) ?[]const u8 {
        var copy = self.*;
        _ = copy.next() orelse return null;
        return copy.next();
    }
};

// ----------------------------------------------------------- table model

const TableRow = struct {
    cells: [max_markdown_table_columns][]const u8 = undefined,
    len: usize = 0,
};

const TextAlignValue = canvas.TextAlign;

const TableAlignments = struct {
    columns: [max_markdown_table_columns]TextAlignValue = undefined,
    len: usize = 0,
};

/// Split a pipe row into trimmed cell slices. Null when the line has no
/// pipe, yields no cells, or has more than `max_markdown_table_columns`
/// cells (the caller then degrades the block to plain text). `\|` does
/// not split (GFM's in-cell pipe escape); the cell text is unescaped at
/// emit time.
fn splitTableRow(line: []const u8) ?TableRow {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    if (std.mem.indexOfScalar(u8, trimmed, '|') == null) return null;
    var rest = trimmed;
    if (rest[0] == '|') rest = rest[1..];
    if (rest.len > 0 and rest[rest.len - 1] == '|' and !(rest.len > 1 and rest[rest.len - 2] == '\\')) {
        rest = rest[0 .. rest.len - 1];
    }
    var row = TableRow{};
    var start: usize = 0;
    var index: usize = 0;
    while (index < rest.len) : (index += 1) {
        if (rest[index] == '\\') {
            index += 1; // Skip the escaped byte (covers `\|`).
            continue;
        }
        if (rest[index] != '|') continue;
        if (row.len >= max_markdown_table_columns) return null;
        row.cells[row.len] = std.mem.trim(u8, rest[start..index], " \t");
        row.len += 1;
        start = index + 1;
    }
    if (row.len >= max_markdown_table_columns) return null;
    row.cells[row.len] = std.mem.trim(u8, rest[@min(start, rest.len)..], " \t");
    row.len += 1;
    return row;
}

/// Parse a GFM delimiter row (`| --- | :--: | ---: |`): every cell must
/// be dashes with optional leading/trailing colons mapping to
/// start/center/end column alignment.
fn tableDelimiterAlignments(line: []const u8) ?TableAlignments {
    const row = splitTableRow(line) orelse return null;
    var result = TableAlignments{ .len = row.len };
    for (row.cells[0..row.len], 0..) |cell, column| {
        if (cell.len == 0) return null;
        var body = cell;
        const leading = body[0] == ':';
        if (leading) body = body[1..];
        var trailing = false;
        if (body.len > 0 and body[body.len - 1] == ':') {
            trailing = true;
            body = body[0 .. body.len - 1];
        }
        if (body.len == 0) return null;
        for (body) |byte| {
            if (byte != '-') return null;
        }
        result.columns[column] = if (leading and trailing)
            .center
        else if (trailing)
            .end
        else
            .start;
    }
    return result;
}

/// A table starts at a pipe header row whose next line is a delimiter row
/// with the same column count (GFM). Anything else falls through to the
/// paragraph path.
fn isTableStart(lines: *LineIterator) bool {
    const first = lines.peek() orelse return false;
    const header = splitTableRow(first) orelse return false;
    const second = lines.peekSecond() orelse return false;
    const alignments = tableDelimiterAlignments(second) orelse return false;
    return alignments.len == header.len;
}

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

/// Memoized forward scans for one `parseInline` pass. The inline walk
/// only moves forward, so the next occurrence of a closer (or of the
/// autolink scheme separator) found from one position stays the answer
/// for every position up to it — without this, a wall of `[`, `<`, or
/// `![` rescans to the terminator at every byte, and a kilobyte of
/// hostile input costs a megabyte of scanning (quadratic; a real
/// pasted-garbage hang).
const ScanCache = struct {
    close_bracket: Slot = .{}, // ']'
    close_paren: Slot = .{}, // ')'
    angle_close: Slot = .{}, // '>'
    /// ' ' queried by autolink target checks (from just past `<`).
    space: Slot = .{}, // ' '
    /// ' ' queried by link title-strips (from just past `](`). A
    /// separate slot: the two query streams sit at different offsets,
    /// and sharing one memo lets them evict each other back into
    /// quadratic rescans on interleaved `[`/`<` walls.
    title_space: Slot = .{}, // ' '
    scheme_sep: Slot = .{}, // "://"

    const Slot = struct {
        valid: bool = false,
        scanned_from: usize = 0,
        /// Next occurrence at/after `scanned_from`; null when the scan
        /// proved none remains.
        pos: ?usize = null,
    };

    fn nextScalar(slot: *Slot, text: []const u8, from: usize, byte: u8) ?usize {
        if (cached(slot, from)) |hit| return hit.pos;
        const found = std.mem.indexOfScalarPos(u8, text, from, byte);
        slot.* = .{ .valid = true, .scanned_from = from, .pos = found };
        return found;
    }

    fn nextPattern(slot: *Slot, text: []const u8, from: usize, pattern: []const u8) ?usize {
        if (cached(slot, from)) |hit| return hit.pos;
        const found = std.mem.indexOfPos(u8, text, from, pattern);
        slot.* = .{ .valid = true, .scanned_from = from, .pos = found };
        return found;
    }

    const Hit = struct { pos: ?usize };

    fn cached(slot: *Slot, from: usize) ?Hit {
        if (!slot.valid or from < slot.scanned_from) return null;
        if (slot.pos) |pos| {
            if (from > pos) return null;
            return .{ .pos = pos };
        }
        return .{ .pos = null };
    }
};

/// Parse `[text](target)` at `source[index]`; null when malformed (the
/// caller then treats `[` as literal text). `consumed` is relative to
/// `index`.
fn parseLinkAt(source: []const u8, index: usize, cache: *ScanCache) ?InlineLink {
    const rest = source[index..];
    if (rest.len < 4 or rest[0] != '[') return null;
    const close_bracket_abs = ScanCache.nextScalar(&cache.close_bracket, source, index, ']') orelse return null;
    const close_bracket = close_bracket_abs - index;
    if (close_bracket + 1 >= rest.len or rest[close_bracket + 1] != '(') return null;
    const close_paren_abs = ScanCache.nextScalar(&cache.close_paren, source, close_bracket_abs + 2, ')') orelse return null;
    const close_paren = close_paren_abs - index;
    const text = rest[1..close_bracket];
    var target = rest[close_bracket + 2 .. close_paren];
    // Strip an optional title: [text](url "title"). Memoized like the
    // closers: an unbounded target rescanned per failed attempt is the
    // same quadratic wall.
    if (ScanCache.nextScalar(&cache.title_space, source, close_bracket_abs + 2, ' ')) |space_abs| {
        if (space_abs < close_paren_abs) target = target[0 .. space_abs - (close_bracket_abs + 2)];
    }
    if (text.len == 0 or target.len == 0) return null;
    return .{ .text = text, .target = target, .consumed = close_paren + 1 };
}

/// Parse `<scheme://...>` autolinks at `source[index]`. `consumed` is
/// relative to `index`.
fn parseAutolinkAt(source: []const u8, index: usize, cache: *ScanCache) ?InlineLink {
    const rest = source[index..];
    if (rest.len < 3 or rest[0] != '<') return null;
    const close_abs = ScanCache.nextScalar(&cache.angle_close, source, index, '>') orelse return null;
    const close = close_abs - index;
    const target = rest[1..close];
    const sep_abs = ScanCache.nextPattern(&cache.scheme_sep, source, index + 1, "://") orelse return null;
    if (sep_abs + "://".len > close_abs) return null;
    if (ScanCache.nextScalar(&cache.space, source, index + 1, ' ')) |space_abs| {
        if (space_abs < close_abs) return null;
    }
    return .{ .text = target, .target = target, .consumed = close + 1 };
}

/// Word-boundary test for bare-URL and `#N` autolinking (the classic
/// `(^|[^\w/&])` register): don't link when continuing a word, a
/// path (`/`), or an HTML entity (`&`).
fn atAutolinkBoundary(text: []const u8, index: usize) bool {
    if (index == 0) return true;
    const previous = text[index - 1];
    return !isWordByte(previous) and previous != '/' and previous != '&';
}

/// Parse a bare `http://`/`https://` URL at the start of `rest`
/// (GFM-style autolink extension): the URL runs to whitespace or `<`,
/// then trailing punctuation and unbalanced close parens are trimmed so
/// prose like "see https://example.com." links cleanly.
fn parseBareUrlAt(rest: []const u8) ?InlineLink {
    const scheme_len: usize = if (std.mem.startsWith(u8, rest, "https://"))
        "https://".len
    else if (std.mem.startsWith(u8, rest, "http://"))
        "http://".len
    else
        return null;
    var end = scheme_len;
    var balance: isize = 0;
    while (end < rest.len) : (end += 1) {
        const byte = rest[end];
        if (isInlineSpace(byte) or byte == '\n' or byte == '<' or byte == '>') break;
        if (byte == '(') balance += 1;
        if (byte == ')') balance -= 1;
    }
    // Trim trailing punctuation, keeping the paren balance current
    // incrementally — recomputing it per trimmed ')' is quadratic in the
    // tail length (a hostile URL ending in a wall of parens used to
    // hang).
    while (end > scheme_len) {
        const byte = rest[end - 1];
        if (byte == ')') {
            if (balance < 0) {
                end -= 1;
                balance += 1;
                continue;
            }
            break;
        }
        switch (byte) {
            '.', ',', ';', ':', '!', '?', '\'', '"' => end -= 1,
            else => break,
        }
    }
    if (end == scheme_len) return null;
    const target = rest[0..end];
    return .{ .text = target, .target = target, .consumed = end };
}

const IssueRef = struct {
    /// The digits after `#`.
    digits: []const u8,
    consumed: usize,
};

/// Parse `#123` at the start of `rest`: one or more digits ending at a
/// word boundary (the classic `#(\d+)\b` register). The caller checks
/// the leading boundary and supplies the link base.
fn parseIssueRefAt(rest: []const u8) ?IssueRef {
    if (rest.len < 2 or rest[0] != '#') return null;
    var end: usize = 1;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    if (end == 1) return null;
    if (end < rest.len and isWordByte(rest[end])) return null;
    return .{ .digits = rest[1..end], .consumed = end };
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
