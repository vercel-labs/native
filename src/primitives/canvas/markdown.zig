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
//! inline span grammar including links), a safe presentational HTML subset,
//! and `<details>`/`<summary>`.
//! Supported inlines: `**bold**`/`__bold__`, `*italic*`/`_italic_`,
//! `` `code` ``, `~~strikethrough~~`, `[text](url)` links, `<url>`
//! autolinks, bare `http(s)://` URLs at word boundaries (GFM-style
//! autolink extension, trailing punctuation trimmed), `#123` issue
//! references (opt-in via `Options.issue_link_base`, since resolving a
//! ref needs repo context), and `![alt](url)` images. Leading images whose
//! source appears in `Options.images` render from the caller's registered
//! `ImageId`; unresolved and mid-paragraph images retain their alt-text
//! fallback. GitHub-style HTML covers the matching native presentation:
//! emphasis/strong/strike/underline/code spans, anchors, line breaks,
//! headings, paragraphs, blockquotes, horizontal rules, registered images
//! (or image alt text),
//! harmless structural wrappers, comments, and common HTML entities.
//! Attributes other than `href`, `src`, `alt`, image `width`/`height`, and
//! block `align` are ignored; there is no DOM, CSS, script execution, or
//! implicit remote image loading. Fetch/decode remains an application effect
//! (`fx.loadImage`); Markdown only resolves the bounded model-owned mapping.
//!
//! Deliberately unsupported in v1 (rendered as plain paragraph text, never
//! a build failure): setext headings, indented code blocks, backslash
//! escapes (except `\|` inside table rows, which GFM needs to put a pipe
//! in a cell), reference-style links (their definitions are recognized and
//! hidden, but references stay literal), HTML with no native presentation
//! (scripts, styles, embeds, and forms), and footnotes. Malformed input degrades to literal
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
pub const max_markdown_html_block_depth: usize = 8;
pub const max_markdown_table_columns: usize = 8;
/// Rows per table including the header; trailing rows drop deterministically.
pub const max_markdown_table_rows: usize = 64;
/// Registered source-to-image mappings a document will inspect. This mirrors
/// the runtime's registered-image slot bound and keeps hostile model slices
/// from turning every inline image into an unbounded lookup.
pub const max_markdown_images: usize = 16;
/// Image sources discovered for the documented `fx.loadImage` workflow use
/// the effect channel's URL bound. Keeping the copy here model-owned lets the
/// collector decode HTML entities before either network loading or renderer
/// lookup, so both sides use one canonical source string.
pub const max_markdown_image_source_bytes: usize = 2048;
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

/// One image the application has already decoded and registered with the
/// canvas runtime. Markdown deliberately does not perform I/O from a view:
/// apps load `source` through `fx.loadImage`, retain the successful id and
/// dimensions in their model, then pass that model-owned mapping here.
pub const ResolvedImage = struct {
    source: []const u8,
    image: canvas.ImageId,
    width: f32,
    height: f32,
};

/// One canonical image source copied into caller-owned collection storage.
/// `value()` remains valid while this record remains alive; consume or copy
/// the slice before the caller's storage goes out of scope.
pub const CollectedImageSource = struct {
    bytes: [max_markdown_image_source_bytes]u8 = undefined,
    len: usize = 0,

    pub fn value(self: *const CollectedImageSource) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Collect distinct leading image sources the renderer can replace with native
/// image leaves, into caller-owned bounded storage. Fenced blocks, inline code,
/// comments, mid-paragraph images, and unsupported HTML tags stay inert,
/// matching the renderer's security posture and avoiding effects for sources
/// that can only use the alt-text fallback. Sources are HTML-entity-decoded
/// into `output`, so the URL loaded and the key later matched by the renderer
/// are byte-identical. An app can use this during `update` to issue
/// `fx.loadImage` effects, then pass successful mappings back through
/// `Options.images` on the next view.
pub fn collectImageSources(source: []const u8, output: []CollectedImageSource) []const CollectedImageSource {
    var lines = LineIterator{ .source = source };
    var len: usize = 0;
    var in_fence = false;
    var paragraph_open = false;
    var blockquote_open = false;
    var html_state = ImageDiscoveryHtmlState{};
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");

        // HTML comments, code/pre blocks, and unsupported elements remain
        // opaque across physical lines. Scan them before considering Markdown
        // block prefixes so hidden `<img>` lines can never become effects.
        if (html_state.active()) {
            _ = imageDiscoveryVisiblePrefix(line, &html_state);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = !in_fence;
            paragraph_open = false;
            blockquote_open = false;
            continue;
        }
        if (in_fence) continue;

        const visible = imageDiscoveryVisiblePrefix(line, &html_state);
        const visible_trimmed = std.mem.trim(u8, visible, " \t");
        if (visible_trimmed.len == 0) {
            if (trimmed.len == 0) {
                paragraph_open = false;
                blockquote_open = false;
            } else if (startsStandaloneInertHtmlBlock(trimmed)) {
                // Comments and `<pre>` lower as standalone blocks. Once
                // their multiline body ends, the next source line starts a
                // fresh renderable block and may expose a leading image.
                paragraph_open = false;
            } else {
                // A comment/opaque element on an otherwise nonblank line is
                // still part of the surrounding paragraph. Do not let the
                // next physical line masquerade as a leading image.
                paragraph_open = true;
            }
            continue;
        }

        if (isLinkReferenceDefinition(visible)) {
            paragraph_open = false;
            blockquote_open = false;
            continue;
        }

        if (headingLevel(visible_trimmed)) |level| {
            appendLeadingImageSource(output, &len, std.mem.trim(u8, visible_trimmed[level..], " \t#"));
            paragraph_open = false;
            blockquote_open = false;
            if (len >= output.len) break;
            continue;
        }
        if (listMarker(visible)) |marker| {
            appendLeadingImageSource(output, &len, marker.content);
            paragraph_open = false;
            blockquote_open = false;
            if (len >= output.len) break;
            continue;
        }
        if (std.mem.startsWith(u8, visible_trimmed, ">")) {
            var inner = visible_trimmed[1..];
            if (std.mem.startsWith(u8, inner, " ")) inner = inner[1..];
            inner = std.mem.trim(u8, inner, " \t");
            if (!blockquote_open and inner.len > 0) appendLeadingImageSource(output, &len, inner);
            if (inner.len > 0) blockquote_open = true;
            paragraph_open = false;
            if (len >= output.len) break;
            continue;
        }
        blockquote_open = false;

        if (visible.len == line.len and collectTableImageSources(&lines, visible, output, &len, &html_state)) {
            paragraph_open = false;
            if (len >= output.len) break;
            continue;
        }

        if (collectHtmlBlockImageSource(visible_trimmed, output, &len, &paragraph_open)) {
            if (len >= output.len) break;
            continue;
        }

        if (isHorizontalRule(visible_trimmed)) {
            paragraph_open = false;
            continue;
        }
        if (!paragraph_open) appendLeadingImageSource(output, &len, visible);
        paragraph_open = true;
        if (len >= output.len) break;
    }
    return output[0..len];
}

fn appendLeadingImageSource(output: []CollectedImageSource, len: *usize, text: []const u8) void {
    const image = parseLeadingInlineImage(text) orelse return;
    appendDistinctImageSource(output, len, image.source);
}

fn appendDistinctImageSource(output: []CollectedImageSource, len: *usize, source: []const u8) void {
    if (source.len == 0 or len.* >= output.len) return;
    const decoded = decodeHtmlEntitiesInto(source, &output[len.*].bytes) orelse return;
    for (output[0..len.*]) |*existing| {
        if (std.mem.eql(u8, existing.value(), decoded)) return;
    }
    output[len.*].len = decoded.len;
    len.* += 1;
}

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
            /// Source-to-registered-ImageId mappings owned by the caller's
            /// model. A matching leading Markdown image or HTML `<img src>`
            /// renders only when the id and dimensions are valid; otherwise
            /// its alt text remains visible. At most `max_markdown_images`
            /// entries are inspected.
            images: []const ResolvedImage = &.{},
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
            /// GitHub permits `align` on a few safe block wrappers. A
            /// standalone `<div align="center">` commonly wraps several
            /// README blocks, so remember that presentation until its
            /// closing wrapper rather than requiring a browser layout tree.
            html_alignment: ?canvas.TextAlign = null,
            html_block_scope_stack: [16]HtmlBlockScope = undefined,
            html_block_scope_depth: usize = 0,
            html_block_scope_overflow_depth: usize = 0,
            html_block_depth: usize = 0,

            const HtmlBlockScope = struct {
                name: []const u8,
                previous_alignment: ?canvas.TextAlign,
                list_kind: ?HtmlListKind = null,
                next_ordinal: usize = 1,
            };

            const HtmlPresentationSnapshot = struct {
                alignment: ?canvas.TextAlign,
                scope_depth: usize,
                overflow_depth: usize,
            };

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

                    const scope_close = if (self.activeHtmlBlockScopeName()) |name|
                        findUnbalancedHtmlClosingTag(line, name)
                    else if (self.html_block_scope_overflow_depth > 0)
                        findUnbalancedHtmlScopeClosingTag(line)
                    else
                        null;
                    if (scope_close) |match| {
                        _ = lines.next();
                        self.appendHtmlLineFragment(nodes, &len, line[0..match.start]);
                        const suffix = line[match.end..];
                        if (suffix.len > 0) lines.prepend(suffix);
                        _ = self.closeHtmlBlockScope(match.tag);
                        continue;
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

            fn appendHtmlLineFragment(self: *Builder, nodes: []Node, len: *usize, fragment: []const u8) void {
                var fragment_lines = LineIterator{ .source = fragment };
                while (fragment_lines.peek()) |line| {
                    if (std.mem.trim(u8, line, " \t").len == 0) {
                        _ = fragment_lines.next();
                        continue;
                    }
                    const node = self.parseBlock(&fragment_lines) orelse continue;
                    if (len.* >= nodes.len) return;
                    nodes[len.*] = node;
                    len.* += 1;
                }
            }

            fn parseBlock(self: *Builder, lines: *LineIterator) ?Node {
                const line = lines.peek() orelse return null;
                const trimmed = std.mem.trim(u8, line, " \t");

                // Definitions are block syntax even when no reference uses
                // them. GitHub bots use that property for hidden metadata
                // (`[vc]: #...`): consume the definition without needing to
                // implement reference-link resolution.
                if (isLinkReferenceDefinition(line)) {
                    _ = lines.next();
                    return null;
                }
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
                switch (self.parseHtmlBlock(lines, trimmed)) {
                    .not_html => {},
                    .skipped => return null,
                    .node => |node| return node,
                }
                if (isTableStart(lines)) return self.parseTable(lines);
                return self.parseParagraph(lines);
            }

            // ------------------------------------------------------ blocks

            fn heading(self: *Builder, level: usize, content: []const u8) Node {
                const scale = heading_scales[@min(level, heading_scales.len) - 1];
                return self.inlineParagraphNode(content, .{ .weight = .bold, .scale = scale }, .{
                    .on_link = self.options.on_link,
                    .text_alignment = self.html_alignment orelse .start,
                });
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
            fn joinPiece(
                self: *Builder,
                lines: *LineIterator,
                kind: JoinKind,
                joined_len: usize,
                opaque_html: *HtmlOpaqueState,
            ) ?[]const u8 {
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
                        // Unsupported elements are literal opaque regions,
                        // even when they contain blank lines or block-shaped
                        // allowlisted tags. Keep collecting until the outer
                        // unsupported element closes so `parseInline` sees and
                        // preserves the region as one unit.
                        if (!opaque_html.active()) {
                            if (trimmed.len == 0) return null;
                        }
                        if (joined_len > 0 and !opaque_html.active()) {
                            const closes_scope = if (self.activeHtmlBlockScopeName()) |name|
                                findUnbalancedHtmlClosingTag(line, name) != null
                            else if (self.html_block_scope_overflow_depth > 0)
                                findUnbalancedHtmlScopeClosingTag(line) != null
                            else
                                false;
                            if (closes_scope or startsNewBlock(line) or isTableStart(lines)) return null;
                        }
                        updateHtmlOpaqueState(line, opaque_html);
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
                var probe_opaque = HtmlOpaqueState{};
                while (self.joinPiece(&probe, kind, total, &probe_opaque)) |piece| {
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
                var opaque_html = HtmlOpaqueState{};
                while (self.joinPiece(lines, kind, joined, &opaque_html)) |piece| {
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
                return self.inlineParagraphNode(text, base, .{
                    .on_link = self.options.on_link,
                    .text_alignment = self.html_alignment orelse .start,
                });
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
                if (self.html_alignment) |alignment| options.text_alignment = alignment;
                return self.inlineParagraphNode(text, .{}, options);
            }

            fn inlineParagraphNode(self: *Builder, text: []const u8, base: TextSpan, options: Ui.ElementOptions) Node {
                if (self.resolvedLeadingImage(text)) |resolved| {
                    var children: [2]Node = undefined;
                    var child_len: usize = 0;
                    children[child_len] = self.resolvedImageNode(resolved);
                    child_len += 1;

                    const suffix = std.mem.trimStart(u8, text[resolved.consumed..], " \t");
                    if (suffix.len > 0) {
                        var suffix_spans: [text_spans.max_text_spans_per_paragraph]TextSpan = undefined;
                        const parsed_suffix = self.parseInline(suffix, base, &suffix_spans);
                        children[child_len] = self.ui.paragraph(.{
                            .grow = 1,
                            .on_link = options.on_link,
                            .text_alignment = options.text_alignment,
                            .style = options.style,
                            .style_tokens = options.style_tokens,
                        }, parsed_suffix);
                        child_len += 1;
                    }

                    return self.ui.row(.{
                        .grow = options.grow,
                        .padding = options.padding,
                        .gap = 6,
                        .main = imageMainAlignment(options.text_alignment),
                        .cross = .center,
                    }, .{children[0..child_len]});
                }

                var spans: [text_spans.max_text_spans_per_paragraph]TextSpan = undefined;
                const parsed = self.parseInline(text, base, &spans);
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

            const HtmlBlockResult = union(enum) {
                not_html,
                skipped,
                node: Node,
            };

            /// Lower the small block-shaped portion of GitHub's safe HTML
            /// vocabulary onto native widgets. Inline-shaped tags are left
            /// to `parseInline`; unsupported tags fall through literally.
            fn parseHtmlBlock(self: *Builder, lines: *LineIterator, trimmed: []const u8) HtmlBlockResult {
                if (std.mem.startsWith(u8, trimmed, "<!--")) {
                    if (consumeHtmlCommentBlock(lines)) return .skipped;
                    return .not_html;
                }

                const opening = parseHtmlTagAt(trimmed, 0) orelse return .not_html;
                if (opening.closing or !isHtmlBlockTag(opening)) {
                    if (opening.consumed == trimmed.len and opening.closing and isHtmlStructuralTag(opening)) {
                        if (!self.closeHtmlBlockScope(opening)) return .not_html;
                        _ = lines.next();
                        return .skipped;
                    }
                    return .not_html;
                }

                if (opening.kind == .horizontal_rule) {
                    consumeHtmlOpeningLine(lines, trimmed, opening);
                    return .{ .node = self.ui.separator(.{}) };
                }

                if (opening.kind == .blockquote) {
                    const block_start = lines.*;
                    consumeHtmlOpeningLine(lines, trimmed, opening);
                    if (opening.self_closing) return .skipped;
                    if (self.html_block_depth >= max_markdown_html_block_depth) {
                        skipHtmlElement(lines, opening.name);
                        return .skipped;
                    }
                    const element = self.collectHtmlElementLines(lines, opening.name);
                    if (!element.closed) {
                        lines.* = block_start;
                        return .not_html;
                    }
                    const presentation = self.htmlPresentationSnapshot();
                    defer self.restoreHtmlPresentation(presentation);
                    if (htmlTagAlignment(opening)) |alignment| self.html_alignment = alignment;
                    self.html_block_depth += 1;
                    defer self.html_block_depth -= 1;
                    var content_lines = LineIterator{ .source = element.content };
                    const blocks = self.parseBlocks(&content_lines, .document);
                    return .{ .node = self.ui.row(.{ .gap = 10 }, .{
                        self.ui.el(.separator, .{ .frame = geometry.RectF.init(0, 0, 3, 0) }, .{}),
                        self.ui.column(.{ .gap = 12, .grow = 1 }, blocks),
                    }) };
                }

                if (opening.kind == .preformatted) {
                    const block_start = lines.*;
                    consumeHtmlOpeningLine(lines, trimmed, opening);
                    if (opening.self_closing) return .skipped;
                    const element = self.collectHtmlElementLines(lines, opening.name);
                    if (!element.closed) {
                        lines.* = block_start;
                        return .not_html;
                    }
                    const content = std.mem.trim(u8, element.content, "\r\n");
                    const code = std.mem.trim(u8, unwrapHtmlCode(content), "\r\n");
                    return .{ .node = self.ui.code(.{}, self.decodeHtmlEntities(code)) };
                }

                if (opening.kind == .heading or opening.kind == .paragraph or opening.kind == .list_item) {
                    const block_start = lines.*;
                    consumeHtmlOpeningLine(lines, trimmed, opening);
                    if (opening.self_closing) return .skipped;
                    const element = self.collectHtmlElementLines(lines, opening.name);
                    if (!element.closed) {
                        lines.* = block_start;
                        return .not_html;
                    }
                    const content = self.collapseHtmlWhitespace(element.content);
                    const alignment = htmlTagAlignment(opening) orelse self.html_alignment orelse .start;
                    return switch (opening.kind) {
                        .heading => .{ .node = self.htmlHeading(opening.heading_level, content, alignment) },
                        .paragraph => .{ .node = self.htmlParagraph(content, alignment) },
                        .list_item => .{ .node = self.htmlListItem(opening, content) },
                        else => unreachable,
                    };
                }

                if (singleLineHtmlElement(trimmed, opening)) |element| {
                    const alignment = htmlTagAlignment(opening) orelse self.html_alignment orelse .start;
                    return switch (opening.kind) {
                        .list => blk: {
                            _ = lines.next();
                            const presentation = self.htmlPresentationSnapshot();
                            defer self.restoreHtmlPresentation(presentation);
                            self.openHtmlBlockScope(opening);
                            var content_lines = LineIterator{ .source = element.content };
                            const blocks = self.parseBlocks(&content_lines, .document);
                            break :blk .{ .node = self.ui.column(.{ .gap = 4 }, blocks) };
                        },
                        .container, .table, .table_section, .table_row, .table_cell => blk: {
                            _ = lines.next();
                            break :blk .{ .node = self.htmlParagraph(element.content, alignment) };
                        },
                        else => .not_html,
                    };
                }

                // A structural tag on its own line is presentation-only.
                // Keep its alignment/heading scope for the Markdown blocks
                // between the opener and closer, then emit no empty widget.
                if (opening.consumed == trimmed.len and isHtmlStructuralTag(opening)) {
                    _ = lines.next();
                    if (opening.self_closing) return .skipped;
                    self.openHtmlBlockScope(opening);
                    return .skipped;
                }
                return .not_html;
            }

            fn openHtmlBlockScope(self: *Builder, tag: HtmlTag) void {
                if (!isHtmlBlockScopeTag(tag) or tag.self_closing) return;
                if (self.html_block_scope_depth < self.html_block_scope_stack.len) {
                    self.html_block_scope_stack[self.html_block_scope_depth] = .{
                        .name = tag.name,
                        .previous_alignment = self.html_alignment,
                        .list_kind = htmlListKind(tag),
                    };
                    self.html_block_scope_depth += 1;
                } else {
                    self.html_block_scope_overflow_depth += 1;
                    return;
                }
                if (htmlTagAlignment(tag)) |alignment| self.html_alignment = alignment;
            }

            fn activeHtmlBlockScopeName(self: *Builder) ?[]const u8 {
                if (self.html_block_scope_overflow_depth > 0 or self.html_block_scope_depth == 0) return null;
                return self.html_block_scope_stack[self.html_block_scope_depth - 1].name;
            }

            fn activeHtmlListScope(self: *Builder) ?*HtmlBlockScope {
                if (self.html_block_scope_overflow_depth > 0) return null;
                var index = self.html_block_scope_depth;
                while (index > 0) {
                    index -= 1;
                    const scope = &self.html_block_scope_stack[index];
                    if (scope.list_kind != null) return scope;
                }
                return null;
            }

            fn closeHtmlBlockScope(self: *Builder, tag: HtmlTag) bool {
                if (!isHtmlBlockScopeTag(tag)) return true;
                if (self.html_block_scope_overflow_depth > 0) {
                    self.html_block_scope_overflow_depth -= 1;
                    return true;
                }
                if (self.html_block_scope_depth == 0) return false;
                const scope = self.html_block_scope_stack[self.html_block_scope_depth - 1];
                if (!std.ascii.eqlIgnoreCase(scope.name, tag.name)) return false;
                self.html_block_scope_depth -= 1;
                self.html_alignment = scope.previous_alignment;
                return true;
            }

            fn htmlPresentationSnapshot(self: *Builder) HtmlPresentationSnapshot {
                return .{
                    .alignment = self.html_alignment,
                    .scope_depth = self.html_block_scope_depth,
                    .overflow_depth = self.html_block_scope_overflow_depth,
                };
            }

            fn restoreHtmlPresentation(self: *Builder, snapshot: HtmlPresentationSnapshot) void {
                self.html_alignment = snapshot.alignment;
                self.html_block_scope_depth = snapshot.scope_depth;
                self.html_block_scope_overflow_depth = snapshot.overflow_depth;
            }

            /// Consume lines through the matching closer for an opening tag
            /// that the caller has already removed. The returned arena slice
            /// contains only the element body; any bytes after the closer are
            /// prepended so ordinary block parsing resumes on them.
            const CollectedHtmlElement = struct {
                content: []const u8,
                closed: bool,
            };

            fn collectHtmlElementLines(self: *Builder, lines: *LineIterator, name: []const u8) CollectedHtmlElement {
                var probe = lines.*;
                var probe_depth: usize = 1;
                var probe_opaque = HtmlOpaqueState{};
                var total: usize = 0;
                var closed = false;
                while (probe.next()) |line| {
                    const scan = scanHtmlElementLine(line, name, &probe_depth, &probe_opaque);
                    total = @min(max_markdown_paragraph_bytes, total +| scan.content_end);
                    if (scan.closing_end) |closing_end| {
                        const suffix = line[closing_end..];
                        if (suffix.len > 0) probe.prepend(suffix);
                        closed = true;
                        break;
                    }
                    total = @min(max_markdown_paragraph_bytes, total +| 1);
                }
                if (!closed) return .{ .content = &.{}, .closed = false };

                const out = self.ui.arena.alloc(u8, total) catch {
                    self.ui.failed = true;
                    lines.* = probe;
                    return .{ .content = &.{}, .closed = true };
                };
                var depth: usize = 1;
                var opaque_html = HtmlOpaqueState{};
                var len: usize = 0;
                while (lines.next()) |line| {
                    const scan = scanHtmlElementLine(line, name, &depth, &opaque_html);
                    if (scan.content_end > 0 and len < out.len) {
                        const take = @min(scan.content_end, out.len - len);
                        @memcpy(out[len..][0..take], line[0..take]);
                        len += take;
                    }
                    if (scan.closing_end) |closing_end| {
                        const suffix = line[closing_end..];
                        if (suffix.len > 0) lines.prepend(suffix);
                        break;
                    }
                    if (len < out.len) {
                        out[len] = '\n';
                        len += 1;
                    }
                }
                return .{ .content = out[0..len], .closed = true };
            }

            /// HTML collapses source line boundaries in phrasing content.
            /// Keep within-line bytes exact (including attribute values), but
            /// turn CR/LF boundaries into spaces before inline lowering.
            fn collapseHtmlWhitespace(self: *Builder, raw: []const u8) []const u8 {
                const trimmed = std.mem.trim(u8, raw, " \t\r\n");
                if (std.mem.indexOfAny(u8, trimmed, "\r\n") == null) return trimmed;
                const out = self.ui.arena.alloc(u8, trimmed.len) catch {
                    self.ui.failed = true;
                    return trimmed;
                };
                var len: usize = 0;
                var index: usize = 0;
                while (index < trimmed.len) : (index += 1) {
                    if (trimmed[index] == '\r') {
                        if (index + 1 < trimmed.len and trimmed[index + 1] == '\n') index += 1;
                        out[len] = ' ';
                    } else if (trimmed[index] == '\n') {
                        out[len] = ' ';
                    } else {
                        out[len] = trimmed[index];
                    }
                    len += 1;
                }
                return out[0..len];
            }

            fn htmlHeading(self: *Builder, level: usize, content: []const u8, alignment: canvas.TextAlign) Node {
                const scale = heading_scales[@min(level, heading_scales.len) - 1];
                return self.inlineParagraphNode(content, .{ .weight = .bold, .scale = scale }, .{
                    .on_link = self.options.on_link,
                    .text_alignment = alignment,
                });
            }

            fn htmlParagraph(self: *Builder, content: []const u8, alignment: canvas.TextAlign) Node {
                return self.htmlParagraphWithOptions(content, alignment, .{});
            }

            fn htmlParagraphWithOptions(
                self: *Builder,
                content: []const u8,
                alignment: canvas.TextAlign,
                options_in: Ui.ElementOptions,
            ) Node {
                return self.htmlParagraphWithBase(content, alignment, options_in, .{});
            }

            fn htmlParagraphWithBase(
                self: *Builder,
                content: []const u8,
                alignment: canvas.TextAlign,
                options_in: Ui.ElementOptions,
                base: TextSpan,
            ) Node {
                var options = options_in;
                options.on_link = self.options.on_link;
                options.text_alignment = alignment;
                return self.inlineParagraphNode(content, base, options);
            }

            fn htmlListItem(self: *Builder, tag: HtmlTag, content: []const u8) Node {
                if (std.ascii.eqlIgnoreCase(tag.name, "dt")) {
                    return self.htmlParagraphWithBase(content, self.html_alignment orelse .start, .{}, .{ .weight = .bold });
                }
                if (std.ascii.eqlIgnoreCase(tag.name, "dd")) {
                    return self.ui.row(.{ .gap = 8 }, .{
                        self.ui.el(.stack, .{ .width = 16 }, .{}),
                        self.htmlParagraphWithBase(content, self.html_alignment orelse .start, .{ .grow = 1 }, .{}),
                    });
                }

                var marker = ListMarker{ .kind = .bullet, .indent = 0, .label = "", .content = content };
                if (self.activeHtmlListScope()) |scope| {
                    if (scope.list_kind == .ordered) {
                        marker.kind = .ordered;
                        marker.label = self.ui.fmt("{d}.", .{scope.next_ordinal});
                        scope.next_ordinal +|= 1;
                    }
                }
                return self.listItemNode(marker, 0);
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

                const indicator = if (expanded) "▾" else "▸";
                const summary_node = self.paragraphWithOptions(summary, .{ .grow = 1 });
                const header_label = self.ui.fmt("{s} {s}", .{ indicator, summary_node.widget.text });
                var header = self.ui.el(.list_item, .{
                    .key = .{ .int = @intCast(ordinal) },
                    .on_press = if (self.options.on_details) |make| make(ordinal) else null,
                    .gap = 6,
                    .semantics = .{ .label = header_label },
                }, .{
                    self.ui.text(.{}, indicator),
                    summary_node,
                });
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

            /// One cell: ordinarily a `data_cell` widget carrying inline
            /// spans (the full inline grammar, links included). A resolved
            /// leading image becomes a real image leaf beside the remaining
            /// span paragraph, while the cell retains its gridcell semantics,
            /// padding, alignment, and chrome.
            fn tableCellNode(self: *Builder, content: []const u8, alignment: canvas.TextAlign, is_header: bool) Node {
                const text = self.unescapeTablePipes(content);
                const base: TextSpan = if (is_header) .{ .weight = .bold } else .{};
                if (self.resolvedLeadingImage(text)) |resolved| {
                    var children: [2]Node = undefined;
                    var child_len: usize = 0;
                    children[child_len] = self.resolvedImageNode(resolved);
                    child_len += 1;

                    const suffix = std.mem.trimStart(u8, text[resolved.consumed..], " \t");
                    if (suffix.len > 0) {
                        var suffix_spans: [text_spans.max_text_spans_per_paragraph]TextSpan = undefined;
                        const parsed_suffix = self.parseInline(suffix, base, &suffix_spans);
                        children[child_len] = self.ui.paragraph(.{
                            .grow = 1,
                            .on_link = self.options.on_link,
                            .text_alignment = alignment,
                        }, parsed_suffix);
                        child_len += 1;
                    }

                    var cell = self.ui.el(.data_cell, .{
                        .grow = 1,
                        .padding = 8,
                        .gap = 6,
                        .main = imageMainAlignment(alignment),
                        .cross = .center,
                    }, .{children[0..child_len]});
                    cell.widget.text_alignment = alignment;
                    return cell;
                }

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

            const ResolvedLeadingImage = struct {
                mapping: ResolvedImage,
                consumed: usize,
                alt: []const u8,
                link: []const u8,
                width: f32,
                height: f32,
            };

            fn resolvedLeadingImage(self: *Builder, text: []const u8) ?ResolvedLeadingImage {
                const parsed = parseLeadingInlineImage(text) orelse return null;
                const source = self.decodeHtmlEntities(parsed.source);
                const mapping = self.findResolvedImage(source) orelse return null;
                const alt = self.decodeHtmlEntities(parsed.alt);
                const link = self.decodeHtmlEntities(parsed.link);
                const dimensions = resolvedInlineImageDimensions(mapping, parsed.width, parsed.height);
                return .{
                    .mapping = mapping,
                    .consumed = parsed.consumed,
                    .alt = alt,
                    .link = link,
                    .width = dimensions.width,
                    .height = dimensions.height,
                };
            }

            fn resolvedImageNode(self: *Builder, resolved: ResolvedLeadingImage) Node {
                return self.ui.image(.{
                    .image = resolved.mapping.image,
                    .width = resolved.width,
                    .height = resolved.height,
                    .semantics = .{
                        .role = if (resolved.link.len > 0) .link else .image,
                        .label = resolved.alt,
                        .focusable = resolved.link.len > 0,
                    },
                    .on_press = if (resolved.link.len > 0 and self.options.on_link != null)
                        self.options.on_link.?(resolved.link)
                    else
                        null,
                });
            }

            fn findResolvedImage(self: *const Builder, source: []const u8) ?ResolvedImage {
                for (self.options.images[0..@min(self.options.images.len, max_markdown_images)]) |image| {
                    if (image.image == 0 or !validImageDimension(image.width) or !validImageDimension(image.height)) continue;
                    if (std.mem.eql(u8, image.source, source)) return image;
                }
                return null;
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
                var style = InlineStyleState{};
                var literal_start: usize = 0;
                var index: usize = 0;
                var scan_cache = ScanCache{};
                var consumed_html = false;
                var html_open_tags: [text_spans.max_text_spans_per_paragraph]HtmlInlineOpenTag = undefined;
                var html_open_depth: usize = 0;

                while (index < text.len) {
                    if (len + 2 >= spans.len) break;
                    const rest = text[index..];

                    if (rest[0] == '`') {
                        if (std.mem.indexOfScalar(u8, rest[1..], '`')) |close| {
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            appendStyledSpan(spans, &len, base, style, .{ .text = rest[1 .. 1 + close], .monospace = true });
                            index += close + 2;
                            literal_start = index;
                            continue;
                        }
                    } else if (std.mem.startsWith(u8, rest, "**") or std.mem.startsWith(u8, rest, "__")) {
                        const delim = rest[0..2];
                        if (style.markdown_bold or hasCloser(rest[2..], delim)) {
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            style.markdown_bold = !style.markdown_bold;
                            index += 2;
                            literal_start = index;
                            continue;
                        }
                    } else if (std.mem.startsWith(u8, rest, "~~")) {
                        if (style.markdown_strike or hasCloser(rest[2..], "~~")) {
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            style.markdown_strike = !style.markdown_strike;
                            index += 2;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == '*' or rest[0] == '_') {
                        const delim = rest[0..1];
                        const boundary_ok = rest[0] == '*' or index == 0 or !isWordByte(text[index - 1]);
                        const emphasis_ok = if (style.markdown_italic)
                            true
                        else
                            rest.len > 1 and !isInlineSpace(rest[1]) and hasCloser(rest[1..], delim);
                        if (boundary_ok and emphasis_ok) {
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            style.markdown_italic = !style.markdown_italic;
                            index += 1;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == '[') {
                        if (parseLinkAt(text, index, &scan_cache)) |link| {
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            appendStyledSpan(spans, &len, base, style, .{ .text = link.text, .link = link.target });
                            index += link.consumed;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == '!' and rest.len > 1 and rest[1] == '[') {
                        if (parseLinkAt(text, index + 1, &scan_cache)) |image| {
                            // Images render as their alt text in v1.
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            appendStyledSpan(spans, &len, base, style, .{ .text = image.text });
                            index += image.consumed + 1;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == '<') {
                        if (parseHtmlCommentAt(text, index, &scan_cache)) |comment| {
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            consumed_html = true;
                            index += comment.consumed;
                            literal_start = index;
                            continue;
                        } else if (parseAutolinkAt(text, index, &scan_cache)) |link| {
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            appendStyledSpan(spans, &len, base, style, .{ .text = link.text, .link = link.target });
                            index += link.consumed;
                            literal_start = index;
                            continue;
                        } else if (parseHtmlTagAt(text, index)) |tag| {
                            const requires_closer = htmlTagRequiresClosing(tag);
                            const accepted = if (tag.closing)
                                requires_closer and html_open_depth > 0 and
                                    std.ascii.eqlIgnoreCase(html_open_tags[html_open_depth - 1].name, tag.name)
                            else if (tag.self_closing or !requires_closer)
                                true
                            else
                                html_open_depth < html_open_tags.len and
                                    hasMatchingHtmlClosingTag(text, index + tag.consumed, tag.name);
                            if (!accepted) {
                                // Keep malformed/stray syntax in the pending
                                // literal run, but skip its bytes as a unit so
                                // Markdown-looking attribute text stays inert.
                                index += tag.consumed;
                                continue;
                            }
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            consumed_html = true;
                            self.applyHtmlTag(spans, &len, base, &style, tag);
                            if (tag.closing) {
                                html_open_depth -= 1;
                            } else if (requires_closer and !tag.self_closing) {
                                html_open_tags[html_open_depth] = .{ .name = tag.name };
                                html_open_depth += 1;
                            }
                            index += tag.consumed;
                            literal_start = index;
                            continue;
                        } else if (parseHtmlTagSyntaxAt(text, index)) |tag| {
                            // Unsupported HTML is one opaque literal region:
                            // do not style allowlisted descendants or decode
                            // entities inside scripts, styles, embeds, forms,
                            // or unknown wrappers.
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            const end = unsupportedHtmlElementEnd(text, index, tag);
                            appendStyledSpan(spans, &len, base, style, .{ .text = text[index..end] });
                            index = end;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == '&') {
                        if (self.decodeHtmlEntity(rest)) |entity| {
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            appendStyledSpan(spans, &len, base, style, .{ .text = entity.text });
                            consumed_html = true;
                            index += entity.consumed;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == 'h' and atAutolinkBoundary(text, index)) {
                        if (parseBareUrlAt(rest)) |link| {
                            flushLiteral(spans, &len, text[literal_start..index], base, style);
                            appendStyledSpan(spans, &len, base, style, .{ .text = link.text, .link = link.target });
                            index += link.consumed;
                            literal_start = index;
                            continue;
                        }
                    } else if (rest[0] == '#' and atAutolinkBoundary(text, index)) {
                        if (self.options.issue_link_base) |issue_base| {
                            if (parseIssueRefAt(rest)) |ref| {
                                flushLiteral(spans, &len, text[literal_start..index], base, style);
                                appendStyledSpan(spans, &len, base, style, .{
                                    .text = rest[0..ref.consumed],
                                    .link = self.ui.fmt("{s}{s}", .{ issue_base, ref.digits }),
                                });
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
                flushLiteral(spans, &len, text[literal_start..], base, style);
                if (len == 0 and !consumed_html) {
                    spans[0] = spanWith(base, .{ .text = text });
                    len = 1;
                }
                return spans[0..len];
            }

            const InlineStyleState = struct {
                markdown_bold: bool = false,
                markdown_italic: bool = false,
                markdown_strike: bool = false,
                html_bold: usize = 0,
                html_italic: usize = 0,
                html_strike: usize = 0,
                html_underline: usize = 0,
                html_monospace: usize = 0,
                html_mark: usize = 0,
                html_small: usize = 0,
                html_heading_level: ?usize = null,
                html_link: []const u8 = "",
            };

            const HtmlInlineOpenTag = struct {
                name: []const u8,
            };

            fn applyHtmlTag(
                self: *Builder,
                spans: *[text_spans.max_text_spans_per_paragraph]TextSpan,
                len: *usize,
                base: TextSpan,
                style: *InlineStyleState,
                tag: HtmlTag,
            ) void {
                const active = !tag.self_closing;
                switch (tag.kind) {
                    .bold => updateHtmlDepth(&style.html_bold, tag.closing, active),
                    .italic => updateHtmlDepth(&style.html_italic, tag.closing, active),
                    .strike => updateHtmlDepth(&style.html_strike, tag.closing, active),
                    .underline => updateHtmlDepth(&style.html_underline, tag.closing, active),
                    .monospace, .preformatted => updateHtmlDepth(&style.html_monospace, tag.closing, active),
                    .mark => updateHtmlDepth(&style.html_mark, tag.closing, active),
                    .small => updateHtmlDepth(&style.html_small, tag.closing, active),
                    .heading => style.html_heading_level = if (tag.closing or tag.self_closing) null else tag.heading_level,
                    .link => {
                        if (tag.closing or tag.self_closing) {
                            style.html_link = "";
                        } else {
                            const href = htmlAttribute(tag, "href") orelse "";
                            style.html_link = self.decodeHtmlEntities(href);
                        }
                    },
                    .line_break => if (!tag.closing) appendStyledSpan(spans, len, base, style.*, .{ .text = "\n" }),
                    .word_break => if (!tag.closing) appendStyledSpan(spans, len, base, style.*, .{ .text = "\u{200b}" }),
                    .image => if (!tag.closing) {
                        if (htmlAttribute(tag, "alt")) |alt| {
                            appendStyledSpan(spans, len, base, style.*, .{ .text = self.decodeHtmlEntities(alt) });
                        }
                    },
                    .quote => if (!tag.self_closing) appendStyledSpan(spans, len, base, style.*, .{ .text = if (tag.closing) "”" else "“" }),
                    .list_item => if (!tag.self_closing) appendStyledSpan(spans, len, base, style.*, .{ .text = if (tag.closing) "\n" else "• " }),
                    .table_cell => if (tag.closing) appendStyledSpan(spans, len, base, style.*, .{ .text = "\t" }),
                    .table_row => if (tag.closing) appendStyledSpan(spans, len, base, style.*, .{ .text = "\n" }),
                    .horizontal_rule => if (!tag.closing) appendStyledSpan(spans, len, base, style.*, .{ .text = "\n" }),
                    .paragraph, .blockquote, .list, .table, .table_section, .container => {},
                }
            }

            fn decodeHtmlEntities(self: *Builder, text: []const u8) []const u8 {
                if (std.mem.indexOfScalar(u8, text, '&') == null) return text;
                const out = self.ui.arena.alloc(u8, text.len) catch {
                    self.ui.failed = true;
                    return text;
                };
                var source_index: usize = 0;
                var out_len: usize = 0;
                while (source_index < text.len) {
                    if (text[source_index] == '&') {
                        if (self.decodeHtmlEntity(text[source_index..])) |entity| {
                            @memcpy(out[out_len..][0..entity.text.len], entity.text);
                            out_len += entity.text.len;
                            source_index += entity.consumed;
                            continue;
                        }
                    }
                    out[out_len] = text[source_index];
                    out_len += 1;
                    source_index += 1;
                }
                return out[0..out_len];
            }

            fn decodeHtmlEntity(self: *Builder, rest: []const u8) ?DecodedHtmlEntity {
                if (std.mem.startsWith(u8, rest, "&amp;")) return .{ .text = "&", .consumed = 5 };
                if (std.mem.startsWith(u8, rest, "&lt;")) return .{ .text = "<", .consumed = 4 };
                if (std.mem.startsWith(u8, rest, "&gt;")) return .{ .text = ">", .consumed = 4 };
                if (std.mem.startsWith(u8, rest, "&quot;")) return .{ .text = "\"", .consumed = 6 };
                if (std.mem.startsWith(u8, rest, "&apos;")) return .{ .text = "'", .consumed = 6 };
                if (std.mem.startsWith(u8, rest, "&nbsp;")) return .{ .text = "\u{a0}", .consumed = 6 };
                if (!std.mem.startsWith(u8, rest, "&#")) return null;

                const semi = std.mem.indexOfScalar(u8, rest[2..@min(rest.len, 14)], ';') orelse return null;
                const body_end = semi + 2;
                var digits = rest[2..body_end];
                var radix: u8 = 10;
                if (digits.len > 1 and (digits[0] == 'x' or digits[0] == 'X')) {
                    radix = 16;
                    digits = digits[1..];
                }
                if (digits.len == 0) return null;
                const codepoint = std.fmt.parseUnsigned(u21, digits, radix) catch return null;
                if (codepoint == 0 or codepoint > 0x10ffff or (codepoint >= 0xd800 and codepoint <= 0xdfff)) return null;
                const bytes = self.ui.arena.alloc(u8, 4) catch {
                    self.ui.failed = true;
                    return null;
                };
                const encoded = std.unicode.utf8Encode(codepoint, bytes) catch return null;
                return .{ .text = bytes[0..encoded], .consumed = body_end + 1 };
            }

            fn flushLiteral(
                spans: *[text_spans.max_text_spans_per_paragraph]TextSpan,
                len: *usize,
                slice: []const u8,
                base: TextSpan,
                style: InlineStyleState,
            ) void {
                if (slice.len == 0) return;
                appendStyledSpan(spans, len, base, style, .{ .text = slice });
            }

            fn appendStyledSpan(
                spans: *[text_spans.max_text_spans_per_paragraph]TextSpan,
                len: *usize,
                base: TextSpan,
                style: InlineStyleState,
                overrides: TextSpan,
            ) void {
                var span = spanWith(base, overrides);
                // An empty-alt image inside an HTML anchor has no native
                // presentation. Do not turn that zero-byte placeholder into
                // an empty focusable link in the accessibility tree.
                if (span.text.len == 0) return;
                if (style.markdown_bold or style.html_bold > 0 or style.html_heading_level != null) span.weight = .bold;
                if (style.markdown_italic or style.html_italic > 0) span.italic = true;
                if (style.markdown_strike or style.html_strike > 0) span.strikethrough = true;
                if (style.html_underline > 0) span.underline = true;
                if (style.html_monospace > 0) span.monospace = true;
                if (style.html_mark > 0) span.background = .surface_pressed;
                if (style.html_small > 0) span.scale = if (span.scale > 0) span.scale * 0.875 else 0.875;
                if (style.html_heading_level) |level| span.scale = heading_scales[@min(level, heading_scales.len) - 1];
                if (span.link.len == 0 and style.html_link.len > 0) span.link = style.html_link;
                // Markdown keeps its conventional underlined-link register,
                // while the underlying TextSpan renderer leaves decoration
                // entirely under the span's explicit `underline` flag.
                if (span.link.len > 0) span.underline = true;
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

const LeadingInlineImage = struct {
    source: []const u8,
    alt: []const u8,
    link: []const u8 = "",
    width: ?f32 = null,
    height: ?f32 = null,
    consumed: usize,
};

const InlineImageDimensions = struct { width: f32, height: f32 };

/// Recognize the presentation shape GitHub emits for a leading image: a
/// Markdown image directly, an HTML `<img>`, or an image wrapped in harmless
/// inline presentation tags such as `<a><sup>…</sup></a>`. Consuming the
/// matching wrappers as one unit prevents their now-empty tags from leaking
/// into the text paragraph beside the native image leaf.
fn parseLeadingInlineImage(text: []const u8) ?LeadingInlineImage {
    var cursor: usize = 0;
    while (cursor < text.len and isInlineSpace(text[cursor])) cursor += 1;

    if (cursor + 1 < text.len and text[cursor] == '!' and text[cursor + 1] == '[') {
        var cache = ScanCache{};
        const parsed = parseLinkAt(text, cursor + 1, &cache) orelse return null;
        return .{
            .source = parsed.target,
            .alt = parsed.text,
            .consumed = cursor + parsed.consumed + 1,
        };
    }

    var wrappers: [8][]const u8 = undefined;
    var wrapper_len: usize = 0;
    var link: []const u8 = "";
    while (cursor < text.len) {
        const tag = parseHtmlTagAt(text, cursor) orelse return null;
        if (tag.closing) return null;
        if (tag.kind == .image) {
            const source = htmlAttribute(tag, "src") orelse return null;
            const alt = htmlAttribute(tag, "alt") orelse "";
            cursor += tag.consumed;
            while (wrapper_len > 0) {
                while (cursor < text.len and isInlineSpace(text[cursor])) cursor += 1;
                const closing = parseHtmlTagAt(text, cursor) orelse return null;
                if (!closing.closing or !std.ascii.eqlIgnoreCase(closing.name, wrappers[wrapper_len - 1])) return null;
                cursor += closing.consumed;
                wrapper_len -= 1;
            }
            return .{
                .source = source,
                .alt = alt,
                .link = link,
                .width = htmlImageDimension(tag, "width"),
                .height = htmlImageDimension(tag, "height"),
                .consumed = cursor,
            };
        }
        const wrapper_allowed = switch (tag.kind) {
            .link, .small, .bold, .italic, .strike, .underline, .mark, .container => true,
            else => false,
        };
        if (!wrapper_allowed or tag.self_closing or wrapper_len >= wrappers.len) return null;
        if (tag.kind == .link) link = htmlAttribute(tag, "href") orelse "";
        wrappers[wrapper_len] = tag.name;
        wrapper_len += 1;
        cursor += tag.consumed;
        while (cursor < text.len and isInlineSpace(text[cursor])) cursor += 1;
    }
    return null;
}

/// Decode the entity forms accepted by the renderer into caller-owned storage.
/// Entity decoding never expands the input, but the explicit capacity check
/// keeps the public source bound honest even for a pathological URL.
fn decodeHtmlEntitiesInto(text: []const u8, output: []u8) ?[]const u8 {
    var source_index: usize = 0;
    var out_len: usize = 0;
    while (source_index < text.len) {
        if (text[source_index] == '&') {
            const rest = text[source_index..];
            const named: ?[]const u8 = if (std.mem.startsWith(u8, rest, "&amp;"))
                "&"
            else if (std.mem.startsWith(u8, rest, "&lt;"))
                "<"
            else if (std.mem.startsWith(u8, rest, "&gt;"))
                ">"
            else if (std.mem.startsWith(u8, rest, "&quot;"))
                "\""
            else if (std.mem.startsWith(u8, rest, "&apos;"))
                "'"
            else if (std.mem.startsWith(u8, rest, "&nbsp;"))
                "\u{a0}"
            else
                null;
            if (named) |decoded| {
                if (out_len + decoded.len > output.len) return null;
                @memcpy(output[out_len..][0..decoded.len], decoded);
                out_len += decoded.len;
                source_index += if (std.mem.startsWith(u8, rest, "&amp;"))
                    5
                else if (std.mem.startsWith(u8, rest, "&lt;") or std.mem.startsWith(u8, rest, "&gt;"))
                    4
                else
                    6;
                continue;
            }

            if (std.mem.startsWith(u8, rest, "&#")) {
                const semi = std.mem.indexOfScalar(u8, rest[2..@min(rest.len, 14)], ';');
                if (semi) |relative_semi| {
                    const body_end = relative_semi + 2;
                    var digits = rest[2..body_end];
                    var radix: u8 = 10;
                    if (digits.len > 1 and (digits[0] == 'x' or digits[0] == 'X')) {
                        radix = 16;
                        digits = digits[1..];
                    }
                    if (digits.len > 0) {
                        if (std.fmt.parseUnsigned(u21, digits, radix)) |codepoint| {
                            if (codepoint != 0 and codepoint <= 0x10ffff and
                                !(codepoint >= 0xd800 and codepoint <= 0xdfff))
                            {
                                var encoded_storage: [4]u8 = undefined;
                                const encoded = std.unicode.utf8Encode(codepoint, &encoded_storage) catch 0;
                                if (encoded > 0) {
                                    if (out_len + encoded > output.len) return null;
                                    @memcpy(output[out_len..][0..encoded], encoded_storage[0..encoded]);
                                    out_len += encoded;
                                    source_index += body_end + 1;
                                    continue;
                                }
                            }
                        } else |_| {}
                    }
                }
            }
        }

        if (out_len >= output.len) return null;
        output[out_len] = text[source_index];
        out_len += 1;
        source_index += 1;
    }
    return output[0..out_len];
}

fn htmlImageDimension(tag: HtmlTag, name: []const u8) ?f32 {
    const raw = htmlAttribute(tag, name) orelse return null;
    const value = std.fmt.parseFloat(f32, std.mem.trim(u8, raw, " \t")) catch return null;
    return if (validImageDimension(value)) value else null;
}

fn validImageDimension(value: f32) bool {
    return std.math.isFinite(value) and value > 0;
}

fn resolvedInlineImageDimensions(mapping: ResolvedImage, requested_width: ?f32, requested_height: ?f32) InlineImageDimensions {
    var width = requested_width orelse mapping.width;
    var height = requested_height orelse mapping.height;
    if (requested_width != null and requested_height == null) {
        height = width * mapping.height / mapping.width;
    } else if (requested_width == null and requested_height != null) {
        width = height * mapping.width / mapping.height;
    }
    // Inline source dimensions are presentation hints, not permission for an
    // untrusted document to manufacture unbounded layout extents. Scale both
    // axes together so either natural or author-requested proportions survive
    // the cap instead of turning a wide banner into a squashed rectangle.
    const scale = @min(@as(f32, 1), @min(512 / width, 512 / height));
    return .{ .width = width * scale, .height = height * scale };
}

fn imageMainAlignment(alignment: canvas.TextAlign) canvas.WidgetMainAlignment {
    return switch (alignment) {
        .start => .start,
        .center => .center,
        .end => .end,
    };
}

// ------------------------------------------------------------- safe HTML

/// The HTML vocabulary is deliberately presentational. Every accepted tag
/// has a native text/widget lowering; everything else stays visible as
/// literal source, so accepting Markdown never creates a DOM or an execution
/// surface.
const HtmlTagKind = enum {
    bold,
    italic,
    strike,
    underline,
    monospace,
    mark,
    small,
    link,
    image,
    line_break,
    word_break,
    quote,
    heading,
    horizontal_rule,
    paragraph,
    blockquote,
    preformatted,
    list,
    list_item,
    table,
    table_section,
    table_row,
    table_cell,
    container,
};

const HtmlListKind = enum {
    unordered,
    ordered,
    definition,
};

const HtmlTag = struct {
    kind: HtmlTagKind,
    name: []const u8,
    attributes: []const u8,
    closing: bool = false,
    self_closing: bool = false,
    heading_level: usize = 0,
    consumed: usize,
};

const HtmlTagSyntax = struct {
    name: []const u8,
    attributes: []const u8,
    closing: bool = false,
    self_closing: bool = false,
    consumed: usize,
};

const HtmlTagMatch = struct {
    start: usize,
    end: usize,
    tag: HtmlTag,
};

/// State for source regions whose contents must remain opaque to tag matching.
/// The unsupported-element name aliases the Markdown source, which outlives
/// the streaming parse; comment state persists across source lines.
const HtmlOpaqueState = struct {
    name: []const u8 = "",
    depth: usize = 0,
    comment: bool = false,

    fn active(self: HtmlOpaqueState) bool {
        return self.depth > 0 or self.comment;
    }

    fn elementActive(self: HtmlOpaqueState) bool {
        return self.depth > 0;
    }
};

/// The source collector has no widget tree to consult, so it carries the
/// subset of HTML state that makes image effects inert. Unsupported elements
/// and comments reuse the renderer's opaque model; HTML code/pre tags have a
/// small exact-name stack because their contents render as text, never images.
const ImageDiscoveryHtmlState = struct {
    opaque_html: HtmlOpaqueState = .{},
    code_stack: [8][]const u8 = undefined,
    code_depth: usize = 0,
    code_overflow_depth: usize = 0,

    fn active(self: ImageDiscoveryHtmlState) bool {
        return self.opaque_html.active() or self.code_depth > 0 or self.code_overflow_depth > 0;
    }
};

fn isDetailsHtmlTagName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "details") or std.ascii.eqlIgnoreCase(name, "summary");
}

fn startsStandaloneInertHtmlBlock(trimmed: []const u8) bool {
    if (std.mem.startsWith(u8, trimmed, "<!--")) return true;
    const tag = parseHtmlTagAt(trimmed, 0) orelse return false;
    return !tag.closing and tag.kind == .preformatted;
}

/// Return the prefix of one physical line that is eligible for image-source
/// discovery, while advancing multiline comment/unsupported/code state. Once
/// an inert region begins, the rest of that line is conservatively excluded;
/// a leading image before a trailing comment remains eligible.
fn imageDiscoveryVisiblePrefix(line: []const u8, state: *ImageDiscoveryHtmlState) []const u8 {
    const started_inert = state.active();
    var first_inert: ?usize = if (started_inert) 0 else null;
    var cursor: usize = 0;

    while (cursor < line.len) {
        if (state.opaque_html.comment) {
            if (first_inert == null) first_inert = cursor;
            const close = std.mem.indexOfPos(u8, line, cursor, "-->") orelse return line[0 .. first_inert orelse 0];
            state.opaque_html.comment = false;
            cursor = close + 3;
            continue;
        }

        const start = std.mem.indexOfScalarPos(u8, line, cursor, '<') orelse break;
        if (std.mem.startsWith(u8, line[start..], "<!--")) {
            if (first_inert == null) first_inert = start;
            const close = std.mem.indexOfPos(u8, line, start + 4, "-->") orelse {
                state.opaque_html.comment = true;
                break;
            };
            cursor = close + 3;
            continue;
        }

        const syntax = parseHtmlTagSyntaxAt(line, start) orelse {
            cursor = start + 1;
            continue;
        };
        cursor = start + syntax.consumed;

        if (state.opaque_html.elementActive()) {
            if (first_inert == null) first_inert = start;
            if (!std.ascii.eqlIgnoreCase(syntax.name, state.opaque_html.name)) continue;
            if (syntax.closing) {
                state.opaque_html.depth -= 1;
                if (!state.opaque_html.elementActive()) state.opaque_html.name = "";
            } else if (!syntax.self_closing) {
                state.opaque_html.depth += 1;
            }
            continue;
        }

        const classified = classifyHtmlTag(syntax.name);
        if (classified == null and !isDetailsHtmlTagName(syntax.name)) {
            if (first_inert == null) first_inert = start;
            if (!syntax.closing and !syntax.self_closing and !isHtmlVoidTagName(syntax.name)) {
                state.opaque_html = .{ .name = syntax.name, .depth = 1 };
            }
            continue;
        }

        const code_like = if (classified) |tag|
            tag.kind == .monospace or tag.kind == .preformatted
        else
            false;
        if (!code_like) continue;
        if (first_inert == null) first_inert = start;
        if (syntax.self_closing) continue;
        if (syntax.closing) {
            if (state.code_overflow_depth > 0) {
                state.code_overflow_depth -= 1;
            } else if (state.code_depth > 0 and
                std.ascii.eqlIgnoreCase(state.code_stack[state.code_depth - 1], syntax.name))
            {
                state.code_depth -= 1;
            }
        } else if (state.code_depth < state.code_stack.len) {
            state.code_stack[state.code_depth] = syntax.name;
            state.code_depth += 1;
        } else {
            state.code_overflow_depth += 1;
        }
    }
    return line[0 .. first_inert orelse line.len];
}

fn collectTableImageSources(
    lines: *LineIterator,
    header_line: []const u8,
    output: []CollectedImageSource,
    len: *usize,
    html_state: *ImageDiscoveryHtmlState,
) bool {
    const header = splitTableRow(header_line) orelse return false;
    const delimiter_line = lines.peek() orelse return false;
    const alignments = tableDelimiterAlignments(delimiter_line) orelse return false;
    if (alignments.len != header.len) return false;

    for (header.cells) |cell| appendLeadingImageSource(output, len, cell);
    _ = lines.next(); // delimiter
    while (lines.peek()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, '|') == null) break;
        _ = lines.next();
        const visible = imageDiscoveryVisiblePrefix(line, html_state);
        if (splitTableRow(visible)) |row| {
            for (row.cells) |cell| appendLeadingImageSource(output, len, cell);
        }
        if (len.* >= output.len) break;
    }
    return true;
}

/// Consume the block-shaped syntax that can expose a new leading-inline
/// position on the same line. Multiline bodies are handled by the caller's
/// paragraph state on subsequent lines.
fn collectHtmlBlockImageSource(
    trimmed: []const u8,
    output: []CollectedImageSource,
    len: *usize,
    paragraph_open: *bool,
) bool {
    if (std.ascii.startsWithIgnoreCase(trimmed, "<summary>")) {
        var content = trimmed["<summary>".len..];
        if (std.ascii.indexOfIgnoreCase(content, "</summary>")) |close| content = content[0..close];
        appendLeadingImageSource(output, len, std.mem.trim(u8, content, " \t"));
        paragraph_open.* = false;
        return true;
    }
    if (parseHtmlTagSyntaxAt(trimmed, 0)) |syntax| {
        if (isDetailsHtmlTagName(syntax.name)) {
            paragraph_open.* = false;
            return true;
        }
    }

    const opening = parseHtmlTagAt(trimmed, 0) orelse return false;
    if (!isHtmlBlockTag(opening)) return false;
    if (opening.kind == .horizontal_rule or opening.self_closing) {
        paragraph_open.* = false;
        return true;
    }
    if (opening.closing) {
        const suffix = std.mem.trimStart(u8, trimmed[opening.consumed..], " \t");
        if (suffix.len > 0) appendLeadingImageSource(output, len, suffix);
        paragraph_open.* = suffix.len > 0;
        return true;
    }
    if (singleLineHtmlElement(trimmed, opening)) |element| {
        appendLeadingImageSource(output, len, std.mem.trim(u8, element.content, " \t"));
        paragraph_open.* = false;
        return true;
    }

    const suffix = std.mem.trimStart(u8, trimmed[opening.consumed..], " \t");
    if (suffix.len > 0) appendLeadingImageSource(output, len, suffix);
    paragraph_open.* = suffix.len > 0;
    return true;
}

/// Return the next allowlisted tag while treating unsupported elements as
/// opaque regions, carrying multiline-comment state across block scans, and
/// skipping complete Markdown code spans so literal `</tag>` text cannot close
/// a structural wrapper.
fn nextHtmlTagMatch(
    source: []const u8,
    cursor: *usize,
    opaque_html: *HtmlOpaqueState,
    scan_cache: *ScanCache,
) ?HtmlTagMatch {
    while (cursor.* < source.len) {
        if (opaque_html.comment) {
            const close = std.mem.indexOfPos(u8, source, cursor.*, "-->") orelse {
                cursor.* = source.len;
                return null;
            };
            opaque_html.comment = false;
            cursor.* = close + 3;
            continue;
        }

        const start = std.mem.indexOfScalarPos(u8, source, cursor.*, '<') orelse return null;
        if (!opaque_html.elementActive()) {
            if (ScanCache.nextScalar(&scan_cache.html_code_tick, source, cursor.*, '`')) |code_open| {
                if (code_open < start) {
                    if (ScanCache.nextScalar(&scan_cache.html_code_tick, source, code_open + 1, '`')) |code_close| {
                        cursor.* = code_close + 1;
                    } else {
                        // An unpaired backtick is literal in the inline grammar;
                        // advance past it and keep looking for real HTML.
                        cursor.* = code_open + 1;
                    }
                    continue;
                }
            }
        }

        if (std.mem.startsWith(u8, source[start..], "<!--")) {
            const close = std.mem.indexOfPos(u8, source, start + 4, "-->") orelse {
                opaque_html.comment = true;
                cursor.* = source.len;
                return null;
            };
            cursor.* = close + 3;
            continue;
        }
        const syntax = parseHtmlTagSyntaxAt(source, start) orelse {
            cursor.* = start + 1;
            continue;
        };
        cursor.* = start + syntax.consumed;

        if (opaque_html.elementActive()) {
            if (!std.ascii.eqlIgnoreCase(syntax.name, opaque_html.name)) continue;
            if (syntax.closing) {
                opaque_html.depth -= 1;
                if (!opaque_html.elementActive()) opaque_html.name = "";
            } else if (!syntax.self_closing) {
                opaque_html.depth += 1;
            }
            continue;
        }

        if (classifyHtmlTag(syntax.name)) |classified| {
            const tag = HtmlTag{
                .kind = classified.kind,
                .name = syntax.name,
                .attributes = syntax.attributes,
                .closing = syntax.closing,
                .self_closing = syntax.self_closing,
                .heading_level = classified.heading_level,
                .consumed = syntax.consumed,
            };
            return .{ .start = start, .end = cursor.*, .tag = tag };
        }

        if (!syntax.closing and !syntax.self_closing and !isHtmlVoidTagName(syntax.name)) {
            opaque_html.* = .{ .name = syntax.name, .depth = 1 };
        }
    }
    return null;
}

fn updateHtmlOpaqueState(source: []const u8, opaque_html: *HtmlOpaqueState) void {
    var cursor: usize = 0;
    var scan_cache = ScanCache{};
    while (nextHtmlTagMatch(source, &cursor, opaque_html, &scan_cache)) |_| {}
}

fn htmlTagRequiresClosing(tag: HtmlTag) bool {
    return switch (tag.kind) {
        .image, .line_break, .word_break, .horizontal_rule => false,
        else => true,
    };
}

fn hasMatchingHtmlClosingTag(source: []const u8, from: usize, name: []const u8) bool {
    var cursor = from;
    var nested: usize = 0;
    var opaque_html = HtmlOpaqueState{};
    var scan_cache = ScanCache{};
    while (nextHtmlTagMatch(source, &cursor, &opaque_html, &scan_cache)) |match| {
        if (!std.ascii.eqlIgnoreCase(match.tag.name, name)) continue;
        if (!match.tag.closing) {
            if (!match.tag.self_closing) nested += 1;
            continue;
        }
        if (nested == 0) return true;
        nested -= 1;
    }
    return false;
}

/// Find a closer for an already-open block scope, ignoring matching tags
/// opened and closed wholly within this line.
fn findUnbalancedHtmlClosingTag(source: []const u8, name: []const u8) ?HtmlTagMatch {
    var cursor: usize = 0;
    var nested: usize = 0;
    var opaque_html = HtmlOpaqueState{};
    var scan_cache = ScanCache{};
    while (nextHtmlTagMatch(source, &cursor, &opaque_html, &scan_cache)) |match| {
        if (!std.ascii.eqlIgnoreCase(match.tag.name, name)) continue;
        if (!match.tag.closing) {
            if (!match.tag.self_closing) nested += 1;
            continue;
        }
        if (nested == 0) return match;
        nested -= 1;
    }
    return null;
}

fn findUnbalancedHtmlScopeClosingTag(source: []const u8) ?HtmlTagMatch {
    var cursor: usize = 0;
    var nested: usize = 0;
    var opaque_html = HtmlOpaqueState{};
    var scan_cache = ScanCache{};
    while (nextHtmlTagMatch(source, &cursor, &opaque_html, &scan_cache)) |match| {
        if (!isHtmlBlockScopeTag(match.tag)) continue;
        if (!match.tag.closing) {
            if (!match.tag.self_closing) nested += 1;
            continue;
        }
        if (nested == 0) return match;
        nested -= 1;
    }
    return null;
}

const HtmlElementLineScan = struct {
    content_end: usize,
    closing_end: ?usize = null,
};

fn scanHtmlElementLine(
    line: []const u8,
    name: []const u8,
    depth: *usize,
    opaque_html: *HtmlOpaqueState,
) HtmlElementLineScan {
    var cursor: usize = 0;
    var scan_cache = ScanCache{};
    while (nextHtmlTagMatch(line, &cursor, opaque_html, &scan_cache)) |match| {
        if (!std.ascii.eqlIgnoreCase(match.tag.name, name)) continue;
        if (!match.tag.closing) {
            if (!match.tag.self_closing) depth.* += 1;
            continue;
        }
        if (depth.* > 0) depth.* -= 1;
        if (depth.* == 0) return .{ .content_end = match.start, .closing_end = match.end };
    }
    return .{ .content_end = line.len };
}

const HtmlComment = struct { consumed: usize };
const DecodedHtmlEntity = struct { text: []const u8, consumed: usize };

const SingleLineHtmlElement = struct { content: []const u8 };

/// Parse one allowlisted tag at `source[index]`. The scan rejects another
/// `<` outside a quoted attribute and caps a tag at 1 KiB, keeping a hostile
/// wall of plausible openers linear and capacity-bounded.
fn parseHtmlTagAt(source: []const u8, index: usize) ?HtmlTag {
    const syntax = parseHtmlTagSyntaxAt(source, index) orelse return null;
    const classified = classifyHtmlTag(syntax.name) orelse return null;
    return .{
        .kind = classified.kind,
        .name = syntax.name,
        .attributes = syntax.attributes,
        .closing = syntax.closing,
        .self_closing = syntax.self_closing,
        .heading_level = classified.heading_level,
        .consumed = syntax.consumed,
    };
}

/// Parse one syntactically valid tag regardless of whether its name is in
/// the safe presentation vocabulary. Unsupported elements use this shape to
/// remain opaque literal source through their matching closer.
fn parseHtmlTagSyntaxAt(source: []const u8, index: usize) ?HtmlTagSyntax {
    if (index >= source.len or source[index] != '<') return null;
    var cursor = index + 1;
    var closing = false;
    if (cursor < source.len and source[cursor] == '/') {
        closing = true;
        cursor += 1;
    }
    if (cursor >= source.len or !std.ascii.isAlphabetic(source[cursor])) return null;

    const name_start = cursor;
    while (cursor < source.len and (std.ascii.isAlphanumeric(source[cursor]) or source[cursor] == '-')) cursor += 1;
    const name = source[name_start..cursor];
    if (cursor < source.len and source[cursor] != '>' and source[cursor] != '/' and !std.ascii.isWhitespace(source[cursor])) return null;

    const attributes_start = cursor;
    const limit = @min(source.len, index + 1024);
    var quote: ?u8 = null;
    while (cursor < limit) : (cursor += 1) {
        const byte = source[cursor];
        if (quote) |delimiter| {
            if (byte == delimiter) quote = null;
            continue;
        }
        if (byte == '"' or byte == '\'') {
            quote = byte;
            continue;
        }
        if (byte == '<') return null;
        if (byte != '>') continue;

        const attributes = source[attributes_start..cursor];
        const trimmed_attributes = std.mem.trim(u8, attributes, " \t\r\n");
        return .{
            .name = name,
            .attributes = attributes,
            .closing = closing,
            .self_closing = !closing and trimmed_attributes.len > 0 and trimmed_attributes[trimmed_attributes.len - 1] == '/',
            .consumed = cursor + 1 - index,
        };
    }
    return null;
}

const ClassifiedHtmlTag = struct {
    kind: HtmlTagKind,
    heading_level: usize = 0,
};

fn classifyHtmlTag(name: []const u8) ?ClassifiedHtmlTag {
    if (std.ascii.eqlIgnoreCase(name, "b") or std.ascii.eqlIgnoreCase(name, "strong")) return .{ .kind = .bold };
    if (std.ascii.eqlIgnoreCase(name, "i") or std.ascii.eqlIgnoreCase(name, "em") or
        std.ascii.eqlIgnoreCase(name, "var") or std.ascii.eqlIgnoreCase(name, "cite")) return .{ .kind = .italic };
    if (std.ascii.eqlIgnoreCase(name, "s") or std.ascii.eqlIgnoreCase(name, "strike") or std.ascii.eqlIgnoreCase(name, "del")) return .{ .kind = .strike };
    if (std.ascii.eqlIgnoreCase(name, "u") or std.ascii.eqlIgnoreCase(name, "ins")) return .{ .kind = .underline };
    if (std.ascii.eqlIgnoreCase(name, "code") or std.ascii.eqlIgnoreCase(name, "kbd") or
        std.ascii.eqlIgnoreCase(name, "samp") or std.ascii.eqlIgnoreCase(name, "tt")) return .{ .kind = .monospace };
    if (std.ascii.eqlIgnoreCase(name, "mark")) return .{ .kind = .mark };
    if (std.ascii.eqlIgnoreCase(name, "small") or std.ascii.eqlIgnoreCase(name, "sub") or std.ascii.eqlIgnoreCase(name, "sup")) return .{ .kind = .small };
    if (std.ascii.eqlIgnoreCase(name, "a")) return .{ .kind = .link };
    if (std.ascii.eqlIgnoreCase(name, "img")) return .{ .kind = .image };
    if (std.ascii.eqlIgnoreCase(name, "br")) return .{ .kind = .line_break };
    if (std.ascii.eqlIgnoreCase(name, "wbr")) return .{ .kind = .word_break };
    if (std.ascii.eqlIgnoreCase(name, "q")) return .{ .kind = .quote };
    if (name.len == 2 and (name[0] == 'h' or name[0] == 'H') and name[1] >= '1' and name[1] <= '6') {
        return .{ .kind = .heading, .heading_level = name[1] - '0' };
    }
    if (std.ascii.eqlIgnoreCase(name, "hr")) return .{ .kind = .horizontal_rule };
    if (std.ascii.eqlIgnoreCase(name, "p")) return .{ .kind = .paragraph };
    if (std.ascii.eqlIgnoreCase(name, "blockquote")) return .{ .kind = .blockquote };
    if (std.ascii.eqlIgnoreCase(name, "pre")) return .{ .kind = .preformatted };
    if (std.ascii.eqlIgnoreCase(name, "ol") or std.ascii.eqlIgnoreCase(name, "ul") or std.ascii.eqlIgnoreCase(name, "dl")) return .{ .kind = .list };
    if (std.ascii.eqlIgnoreCase(name, "li") or std.ascii.eqlIgnoreCase(name, "dt") or std.ascii.eqlIgnoreCase(name, "dd")) return .{ .kind = .list_item };
    if (std.ascii.eqlIgnoreCase(name, "table")) return .{ .kind = .table };
    if (std.ascii.eqlIgnoreCase(name, "thead") or std.ascii.eqlIgnoreCase(name, "tbody") or std.ascii.eqlIgnoreCase(name, "tfoot")) return .{ .kind = .table_section };
    if (std.ascii.eqlIgnoreCase(name, "tr")) return .{ .kind = .table_row };
    if (std.ascii.eqlIgnoreCase(name, "td") or std.ascii.eqlIgnoreCase(name, "th")) return .{ .kind = .table_cell };
    if (std.ascii.eqlIgnoreCase(name, "abbr") or std.ascii.eqlIgnoreCase(name, "bdo") or
        std.ascii.eqlIgnoreCase(name, "caption") or std.ascii.eqlIgnoreCase(name, "center") or
        std.ascii.eqlIgnoreCase(name, "div") or std.ascii.eqlIgnoreCase(name, "span") or
        std.ascii.eqlIgnoreCase(name, "section") or std.ascii.eqlIgnoreCase(name, "article") or
        std.ascii.eqlIgnoreCase(name, "header") or std.ascii.eqlIgnoreCase(name, "footer") or
        std.ascii.eqlIgnoreCase(name, "main") or std.ascii.eqlIgnoreCase(name, "figure") or
        std.ascii.eqlIgnoreCase(name, "figcaption") or std.ascii.eqlIgnoreCase(name, "time") or
        std.ascii.eqlIgnoreCase(name, "ruby") or std.ascii.eqlIgnoreCase(name, "rt") or
        std.ascii.eqlIgnoreCase(name, "rp")) return .{ .kind = .container };
    return null;
}

fn unsupportedHtmlElementEnd(source: []const u8, index: usize, opening: HtmlTagSyntax) usize {
    const opening_end = index + opening.consumed;
    if (opening.closing or opening.self_closing or isHtmlVoidTagName(opening.name)) return opening_end;

    var cursor = opening_end;
    var depth: usize = 1;
    var scan_cache = ScanCache{};
    while (std.mem.indexOfScalarPos(u8, source, cursor, '<')) |start| {
        if (parseHtmlCommentAt(source, start, &scan_cache)) |comment| {
            cursor = start + comment.consumed;
            continue;
        }
        const tag = parseHtmlTagSyntaxAt(source, start) orelse {
            cursor = start + 1;
            continue;
        };
        cursor = start + tag.consumed;
        if (!std.ascii.eqlIgnoreCase(tag.name, opening.name)) continue;
        if (tag.closing) {
            depth -= 1;
            if (depth == 0) return cursor;
        } else if (!tag.self_closing) {
            depth += 1;
        }
    }
    return source.len;
}

fn isHtmlVoidTagName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "area") or std.ascii.eqlIgnoreCase(name, "base") or
        std.ascii.eqlIgnoreCase(name, "col") or std.ascii.eqlIgnoreCase(name, "embed") or
        std.ascii.eqlIgnoreCase(name, "input") or std.ascii.eqlIgnoreCase(name, "link") or
        std.ascii.eqlIgnoreCase(name, "meta") or std.ascii.eqlIgnoreCase(name, "param") or
        std.ascii.eqlIgnoreCase(name, "source") or std.ascii.eqlIgnoreCase(name, "track");
}

fn parseHtmlCommentAt(source: []const u8, index: usize, cache: ?*ScanCache) ?HtmlComment {
    if (index > source.len or !std.mem.startsWith(u8, source[index..], "<!--")) return null;
    const close = if (cache) |scan|
        ScanCache.nextPattern(&scan.html_comment_close, source, index + 4, "-->")
    else
        std.mem.indexOfPos(u8, source, index + 4, "-->");
    const close_index = close orelse return null;
    return .{ .consumed = close_index + 3 - index };
}

fn singleLineHtmlElement(line: []const u8, opening: HtmlTag) ?SingleLineHtmlElement {
    if (opening.closing or opening.self_closing) return null;
    const close_start = std.mem.lastIndexOfScalar(u8, line, '<') orelse return null;
    if (close_start < opening.consumed) return null;
    const closing = parseHtmlTagAt(line, close_start) orelse return null;
    if (!closing.closing or closing.consumed != line.len - close_start or
        !std.ascii.eqlIgnoreCase(opening.name, closing.name)) return null;
    return .{ .content = line[opening.consumed..close_start] };
}

fn unwrapHtmlCode(content: []const u8) []const u8 {
    const opening = parseHtmlTagAt(content, 0) orelse return content;
    if (opening.kind != .monospace or opening.closing) return content;
    const element = singleLineHtmlElement(content, opening) orelse return content;
    return element.content;
}

fn consumeHtmlOpeningLine(lines: *LineIterator, trimmed: []const u8, opening: HtmlTag) void {
    _ = lines.next();
    const suffix = trimmed[opening.consumed..];
    if (suffix.len > 0) lines.prepend(suffix);
}

/// Consume a comment beginning on the current line through its closing
/// marker, including intervening blank lines. The iterator is unchanged when
/// no closer exists so malformed comments still degrade to literal text.
fn consumeHtmlCommentBlock(lines: *LineIterator) bool {
    var probe = lines.*;
    const first = probe.next() orelse return false;
    const opening = std.mem.indexOf(u8, first, "<!--") orelse return false;
    if (std.mem.indexOfPos(u8, first, opening + 4, "-->")) |close| {
        const suffix = first[close + 3 ..];
        if (suffix.len > 0) probe.prepend(suffix);
        lines.* = probe;
        return true;
    }
    while (probe.next()) |line| {
        const close = std.mem.indexOf(u8, line, "-->") orelse continue;
        const suffix = line[close + 3 ..];
        if (suffix.len > 0) probe.prepend(suffix);
        lines.* = probe;
        return true;
    }
    return false;
}

fn skipHtmlElement(lines: *LineIterator, name: []const u8) void {
    var depth: usize = 1;
    var opaque_html = HtmlOpaqueState{};
    while (lines.next()) |line| {
        const scan = scanHtmlElementLine(line, name, &depth, &opaque_html);
        if (scan.closing_end) |closing_end| {
            const suffix = line[closing_end..];
            if (suffix.len > 0) lines.prepend(suffix);
            return;
        }
    }
}

fn isHtmlBlockTag(tag: HtmlTag) bool {
    return switch (tag.kind) {
        .heading, .horizontal_rule, .paragraph, .blockquote, .preformatted, .list, .list_item, .table, .table_section, .table_row, .table_cell => true,
        .container => isHtmlStructuralTag(tag),
        else => false,
    };
}

fn isHtmlStructuralTag(tag: HtmlTag) bool {
    if (tag.kind != .container) return isHtmlBlockTagWithoutContainer(tag.kind);
    return std.ascii.eqlIgnoreCase(tag.name, "center") or std.ascii.eqlIgnoreCase(tag.name, "div") or
        std.ascii.eqlIgnoreCase(tag.name, "section") or std.ascii.eqlIgnoreCase(tag.name, "article") or
        std.ascii.eqlIgnoreCase(tag.name, "header") or std.ascii.eqlIgnoreCase(tag.name, "footer") or
        std.ascii.eqlIgnoreCase(tag.name, "main") or std.ascii.eqlIgnoreCase(tag.name, "figure") or
        std.ascii.eqlIgnoreCase(tag.name, "figcaption") or std.ascii.eqlIgnoreCase(tag.name, "caption");
}

fn isHtmlBlockTagWithoutContainer(kind: HtmlTagKind) bool {
    return switch (kind) {
        .heading, .horizontal_rule, .paragraph, .blockquote, .preformatted, .list, .list_item, .table, .table_section, .table_row, .table_cell => true,
        else => false,
    };
}

fn isHtmlBlockScopeTag(tag: HtmlTag) bool {
    // Complete elements (headings, paragraphs, blockquotes, pre, and list
    // items) are consumed by their dedicated collectors before reaching the
    // streaming scope path. Every remaining structural wrapper needs an exact
    // opener/closer entry so stray closing tags can stay literal.
    return isHtmlStructuralTag(tag);
}

fn htmlListKind(tag: HtmlTag) ?HtmlListKind {
    if (tag.kind != .list) return null;
    if (std.ascii.eqlIgnoreCase(tag.name, "ol")) return .ordered;
    if (std.ascii.eqlIgnoreCase(tag.name, "dl")) return .definition;
    return .unordered;
}

fn htmlTagAlignment(tag: HtmlTag) ?canvas.TextAlign {
    if (std.ascii.eqlIgnoreCase(tag.name, "center")) return .center;
    const value = htmlAttribute(tag, "align") orelse return null;
    if (std.ascii.eqlIgnoreCase(value, "center")) return .center;
    if (std.ascii.eqlIgnoreCase(value, "right") or std.ascii.eqlIgnoreCase(value, "end")) return .end;
    if (std.ascii.eqlIgnoreCase(value, "left") or std.ascii.eqlIgnoreCase(value, "start")) return .start;
    return null;
}

/// Return one attribute value without exposing any other attribute to the
/// widget engine. Quoted and unquoted values are accepted case-insensitively,
/// matching the forms commonly found in README HTML.
fn htmlAttribute(tag: HtmlTag, wanted: []const u8) ?[]const u8 {
    var cursor: usize = 0;
    while (cursor < tag.attributes.len) {
        while (cursor < tag.attributes.len and std.ascii.isWhitespace(tag.attributes[cursor])) cursor += 1;
        if (cursor >= tag.attributes.len or tag.attributes[cursor] == '/') break;
        const name_start = cursor;
        while (cursor < tag.attributes.len and (std.ascii.isAlphanumeric(tag.attributes[cursor]) or
            tag.attributes[cursor] == '-' or tag.attributes[cursor] == '_' or tag.attributes[cursor] == ':')) cursor += 1;
        if (cursor == name_start) {
            cursor += 1;
            continue;
        }
        const name = tag.attributes[name_start..cursor];
        while (cursor < tag.attributes.len and std.ascii.isWhitespace(tag.attributes[cursor])) cursor += 1;
        if (cursor >= tag.attributes.len or tag.attributes[cursor] != '=') continue;
        cursor += 1;
        while (cursor < tag.attributes.len and std.ascii.isWhitespace(tag.attributes[cursor])) cursor += 1;
        if (cursor >= tag.attributes.len) return null;

        var value: []const u8 = undefined;
        if (tag.attributes[cursor] == '"' or tag.attributes[cursor] == '\'') {
            const quote = tag.attributes[cursor];
            cursor += 1;
            const value_start = cursor;
            while (cursor < tag.attributes.len and tag.attributes[cursor] != quote) cursor += 1;
            if (cursor >= tag.attributes.len) return null;
            value = tag.attributes[value_start..cursor];
            cursor += 1;
        } else {
            const value_start = cursor;
            while (cursor < tag.attributes.len and !std.ascii.isWhitespace(tag.attributes[cursor])) cursor += 1;
            value = tag.attributes[value_start..cursor];
        }
        if (std.ascii.eqlIgnoreCase(name, wanted)) return value;
    }
    return null;
}

fn updateHtmlDepth(depth: *usize, closing: bool, active: bool) void {
    if (closing) {
        if (depth.* > 0) depth.* -= 1;
    } else if (active and depth.* < std.math.maxInt(usize)) {
        depth.* += 1;
    }
}

// ------------------------------------------------------------ line model

const LineIterator = struct {
    source: []const u8,
    index: usize = 0,
    pending: ?[]const u8 = null,

    fn next(self: *LineIterator) ?[]const u8 {
        if (self.pending) |line| {
            self.pending = null;
            return line;
        }
        if (self.index >= self.source.len) return null;
        const start = self.index;
        const end = std.mem.indexOfScalarPos(u8, self.source, start, '\n') orelse self.source.len;
        self.index = @min(end + 1, self.source.len);
        return std.mem.trimEnd(u8, self.source[start..end], "\r");
    }

    fn prepend(self: *LineIterator, line: []const u8) void {
        std.debug.assert(self.pending == null);
        self.pending = line;
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

/// Recognize the common single-line form of a CommonMark link reference
/// definition. Definitions are block metadata and never render by themselves,
/// even when no reference uses their label. Reference-link resolution remains
/// outside this widget's subset; recognizing the definition is still necessary
/// to avoid exposing bot metadata such as Vercel's `[vc]: #hash:payload` line.
fn isLinkReferenceDefinition(line: []const u8) bool {
    var cursor: usize = 0;
    while (cursor < line.len and line[cursor] == ' ') cursor += 1;
    if (cursor > 3 or cursor >= line.len or line[cursor] != '[') return false;

    cursor += 1;
    var label_has_content = false;
    var closed_label = false;
    while (cursor < line.len) {
        const byte = line[cursor];
        if (byte == '\\' and cursor + 1 < line.len and isAsciiPunctuation(line[cursor + 1])) {
            label_has_content = label_has_content or !isInlineSpace(line[cursor + 1]);
            cursor += 2;
            continue;
        }
        if (byte == '[') return false;
        if (byte == ']') {
            closed_label = true;
            cursor += 1;
            break;
        }
        label_has_content = label_has_content or !isInlineSpace(byte);
        cursor += 1;
    }
    if (!closed_label or !label_has_content or cursor >= line.len or line[cursor] != ':') return false;

    cursor += 1;
    cursor = skipInlineSpaces(line, cursor);
    cursor = parseLinkReferenceDestination(line, cursor) orelse return false;
    const destination_end = cursor;
    cursor = skipInlineSpaces(line, cursor);
    if (cursor == line.len) return true;
    if (cursor == destination_end) return false;

    cursor = parseLinkReferenceTitle(line, cursor) orelse return false;
    return skipInlineSpaces(line, cursor) == line.len;
}

fn parseLinkReferenceDestination(line: []const u8, start: usize) ?usize {
    if (start >= line.len) return null;
    var cursor = start;
    if (line[cursor] == '<') {
        cursor += 1;
        while (cursor < line.len) {
            const byte = line[cursor];
            if (byte == '\\' and cursor + 1 < line.len and isAsciiPunctuation(line[cursor + 1])) {
                cursor += 2;
                continue;
            }
            if (byte == '<' or byte == '\n' or byte == '\r') return null;
            if (byte == '>') return cursor + 1;
            cursor += 1;
        }
        return null;
    }

    var paren_depth: usize = 0;
    while (cursor < line.len and !isInlineSpace(line[cursor])) {
        const byte = line[cursor];
        if (byte < 0x20 or byte == 0x7f or byte == '<') return null;
        if (byte == '\\' and cursor + 1 < line.len and isAsciiPunctuation(line[cursor + 1])) {
            cursor += 2;
            continue;
        }
        if (byte == '(') {
            paren_depth += 1;
        } else if (byte == ')') {
            if (paren_depth == 0) return null;
            paren_depth -= 1;
        }
        cursor += 1;
    }
    if (cursor == start or paren_depth != 0) return null;
    return cursor;
}

fn parseLinkReferenceTitle(line: []const u8, start: usize) ?usize {
    if (start >= line.len) return null;
    const close: u8 = switch (line[start]) {
        '"' => '"',
        '\'' => '\'',
        '(' => ')',
        else => return null,
    };
    var cursor = start + 1;
    while (cursor < line.len) {
        if (line[cursor] == '\\' and cursor + 1 < line.len and isAsciiPunctuation(line[cursor + 1])) {
            cursor += 2;
            continue;
        }
        if (line[cursor] == close) return cursor + 1;
        cursor += 1;
    }
    return null;
}

fn skipInlineSpaces(text: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < text.len and isInlineSpace(text[cursor])) cursor += 1;
    return cursor;
}

fn isAsciiPunctuation(byte: u8) bool {
    return (byte >= 0x21 and byte <= 0x2f) or
        (byte >= 0x3a and byte <= 0x40) or
        (byte >= 0x5b and byte <= 0x60) or
        (byte >= 0x7b and byte <= 0x7e);
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
    if (parseHtmlTagAt(trimmed, 0)) |tag| {
        if (isHtmlBlockTag(tag)) return true;
    }
    if (std.mem.startsWith(u8, trimmed, "<!--")) return true;
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
    html_comment_close: Slot = .{}, // "-->"
    html_code_tick: Slot = .{}, // '`' while scanning tags outside code spans

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
