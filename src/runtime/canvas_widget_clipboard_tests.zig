const support = @import("test_support.zig");
const std = support.std;
const geometry = support.geometry;
const canvas = support.canvas;
const automation = support.automation;
const platform = support.platform;
const App = support.App;
const Runtime = support.Runtime;
const Event = support.Event;
const TestHarness = support.TestHarness;
const canvasWidgetSemanticsById = support.canvasWidgetSemanticsById;

const canvas_limits = @import("canvas_limits.zig");

/// Records the text-edit side of `canvas_widget_keyboard` events the way
/// an elm-style app would consume them (mirroring edits into a model
/// TextBuffer), including the loud paste-truncation flag.
const ClipboardTestApp = struct {
    last_edit_insert: [64]u8 = undefined,
    last_edit_insert_len: usize = 0,
    saw_empty_insert: bool = false,
    saw_truncated: bool = false,
    keyboard_count: u32 = 0,

    fn app(self: *@This()) App {
        return .{ .context = self, .name = "gpu-widget-clipboard", .source = platform.WebViewSource.html("<h1>Clipboard</h1>"), .event_fn = event };
    }

    fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
        _ = runtime;
        const self: *@This() = @ptrCast(@alignCast(context));
        switch (event_value) {
            .canvas_widget_keyboard => |keyboard_event| {
                self.keyboard_count += 1;
                if (keyboard_event.keyboard.edit_truncated) self.saw_truncated = true;
                if (keyboard_event.keyboard.edit) |edit| switch (edit) {
                    .insert_text => |text| {
                        if (text.len == 0) {
                            self.saw_empty_insert = true;
                        } else {
                            const len = @min(text.len, self.last_edit_insert.len);
                            @memcpy(self.last_edit_insert[0..len], text[0..len]);
                            self.last_edit_insert_len = len;
                        }
                    },
                    else => {},
                };
            },
            else => {},
        }
    }
};

fn createClipboardHarness(app: App) !*TestHarness() {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    harness.null_platform.gpu_surfaces = true;
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 200),
    });
    return harness;
}

fn keyInput(key: []const u8, modifiers: platform.ShortcutModifiers) platform.Event {
    return .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = .key_down,
        .key = key,
        .modifiers = modifiers,
    } };
}

fn pointerInput(kind: platform.GpuSurfaceInputKind, x: f32, y: f32) platform.Event {
    return .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "canvas",
        .kind = kind,
        .x = x,
        .y = y,
    } };
}

const cmd = platform.ShortcutModifiers{ .primary = true, .command = true };

test "cmd shortcuts copy, cut, and paste in editable text fields" {
    var app_state: ClipboardTestApp = .{};
    const app = app_state.app();
    const harness = try createClipboardHarness(app);
    defer harness.destroy(std.testing.allocator);

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 200, 36),
        .text = "Query",
        .semantics = .{ .label = "Search" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // Focus the field, select all, copy.
    try harness.runtime.dispatchPlatformEvent(app, pointerInput(.pointer_down, 100, 30));
    try harness.runtime.dispatchPlatformEvent(app, keyInput("a", cmd));
    try harness.runtime.dispatchPlatformEvent(app, keyInput("c", cmd));

    var clipboard_buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("Query", try harness.runtime.readClipboard(&clipboard_buffer));
    // Copy is not destructive: text and selection stay put.
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Query", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 0, .focus = 5 }, retained.nodes[1].widget.text_selection.?);

    // Collapse to the end and paste: the clipboard lands at the caret and
    // the app-facing keyboard event carries the same insert edit.
    try harness.runtime.dispatchPlatformEvent(app, keyInput("end", .{}));
    try harness.runtime.dispatchPlatformEvent(app, keyInput("v", cmd));
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("QueryQuery", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(10), retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualStrings("Query", app_state.last_edit_insert[0..app_state.last_edit_insert_len]);
    try std.testing.expect(!app_state.saw_truncated);

    // Select all and cut: clipboard captures the text, the field empties,
    // and the app hears the delete-selection edit.
    try harness.runtime.dispatchPlatformEvent(app, keyInput("a", cmd));
    try harness.runtime.dispatchPlatformEvent(app, keyInput("x", cmd));
    try std.testing.expectEqualStrings("QueryQuery", try harness.runtime.readClipboard(&clipboard_buffer));
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("", retained.nodes[1].widget.text);
    try std.testing.expect(app_state.saw_empty_insert);

    // Cut with a collapsed selection is a no-op and leaves the clipboard
    // alone.
    try harness.runtime.dispatchPlatformEvent(app, keyInput("x", cmd));
    try std.testing.expectEqualStrings("QueryQuery", try harness.runtime.readClipboard(&clipboard_buffer));
}

test "keyboard-only selection (shift+arrows) feeds copy" {
    var app_state: ClipboardTestApp = .{};
    const app = app_state.app();
    const harness = try createClipboardHarness(app);
    defer harness.destroy(std.testing.allocator);

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 200, 36),
        .text = "Query",
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, pointerInput(.pointer_down, 100, 30));
    try harness.runtime.dispatchPlatformEvent(app, keyInput("end", .{}));
    try harness.runtime.dispatchPlatformEvent(app, keyInput("arrowleft", .{ .shift = true }));
    try harness.runtime.dispatchPlatformEvent(app, keyInput("arrowleft", .{ .shift = true }));
    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 5, .focus = 3 }, retained.nodes[1].widget.text_selection.?);

    try harness.runtime.dispatchPlatformEvent(app, keyInput("c", cmd));
    var clipboard_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("ry", try harness.runtime.readClipboard(&clipboard_buffer));
}

test "a multi-line paste into a single-line field strips line breaks; a textarea keeps them" {
    var app_state: ClipboardTestApp = .{};
    const app = app_state.app();
    const harness = try createClipboardHarness(app);
    defer harness.destroy(std.testing.allocator);

    const children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .text_field,
            .frame = geometry.RectF.init(12, 16, 200, 36),
            .text = "",
        },
        .{
            .id = 3,
            .kind = .textarea,
            .frame = geometry.RectF.init(12, 64, 280, 100),
            .text = "",
        },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // Interior LF, CRLF, and a trailing CR: the single-line field strips
    // every break (the HTML value-sanitization rule — lines join with
    // nothing between them), and the app-facing keyboard event carries
    // the SAME stripped insert so a model mirror stays byte-identical.
    try harness.runtime.writeClipboard("alpha\nbeta\r\ngamma\r");
    try harness.runtime.dispatchPlatformEvent(app, pointerInput(.pointer_down, 100, 30));
    try harness.runtime.dispatchPlatformEvent(app, keyInput("v", cmd));
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("alphabetagamma", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(14), retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqualStrings("alphabetagamma", app_state.last_edit_insert[0..app_state.last_edit_insert_len]);
    try std.testing.expect(!app_state.saw_truncated);

    // The SAME clipboard pasted into the textarea keeps its breaks: only
    // single-line kinds sanitize.
    try harness.runtime.dispatchPlatformEvent(app, pointerInput(.pointer_down, 100, 100));
    try harness.runtime.dispatchPlatformEvent(app, keyInput("v", cmd));
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("alpha\nbeta\r\ngamma\r", retained.nodes[2].widget.text);
    try std.testing.expectEqualStrings("alpha\nbeta\r\ngamma\r", app_state.last_edit_insert[0..app_state.last_edit_insert_len]);
}

test "a paste of only line breaks into a single-line field inserts nothing and keeps the selection" {
    var app_state: ClipboardTestApp = .{};
    const app = app_state.app();
    const harness = try createClipboardHarness(app);
    defer harness.destroy(std.testing.allocator);

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 200, 36),
        .text = "Keep",
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // Select all, then paste bare newlines: the sanitized insert is
    // EMPTY, so the edit suppresses — nothing inserts, the live
    // selection survives, and the app hears no insert at all (an empty
    // insert is cut's delete-selection edit, which this must never be).
    try harness.runtime.writeClipboard("\r\n\n");
    try harness.runtime.dispatchPlatformEvent(app, pointerInput(.pointer_down, 100, 30));
    try harness.runtime.dispatchPlatformEvent(app, keyInput("a", cmd));
    try harness.runtime.dispatchPlatformEvent(app, keyInput("v", cmd));
    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Keep", retained.nodes[1].widget.text);
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 0, .focus = 4 }, retained.nodes[1].widget.text_selection.?);
    try std.testing.expect(!app_state.saw_empty_insert);
    try std.testing.expectEqual(@as(usize, 0), app_state.last_edit_insert_len);
}

test "a near-capacity multi-line paste sanitizes before it clamps" {
    var app_state: ClipboardTestApp = .{};
    const app = app_state.app();
    const harness = try createClipboardHarness(app);
    defer harness.destroy(std.testing.allocator);

    // Fill the view's shared widget-text storage to EXACTLY three free
    // bytes, the boundary where the sanitize/clamp ordering shows:
    // pasting "a\nbc" must land "abc" (sanitized 3 bytes, fits whole).
    // Clamping the raw clipboard first would spend the third byte on
    // the '\n' the seam strips anyway — "a\nb" then "ab" — silently
    // discarding the valid 'c' and flagging a truncation that never
    // happened to the bytes that count.
    const fill_len = canvas_limits.max_canvas_widget_text_bytes_per_view - 3;
    const fill = try std.testing.allocator.alloc(u8, fill_len);
    defer std.testing.allocator.free(fill);
    @memset(fill, 'x');
    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 200, 36),
        .text = fill,
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    // Pin the boundary premise: exactly 3 bytes of capacity remain.
    try std.testing.expectEqual(fill_len, harness.runtime.views[0].widget_text_len);

    try harness.runtime.writeClipboard("a\nbc");
    try harness.runtime.dispatchPlatformEvent(app, pointerInput(.pointer_down, 100, 30));
    try harness.runtime.dispatchPlatformEvent(app, keyInput("end", .{}));
    try harness.runtime.dispatchPlatformEvent(app, keyInput("v", cmd));

    // The retained editor holds the whole sanitized suffix ...
    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    const text = retained.nodes[1].widget.text;
    try std.testing.expectEqual(fill_len + 3, text.len);
    try std.testing.expectEqualStrings("abc", text[text.len - 3 ..]);
    try std.testing.expectEqualDeep(canvas.TextSelection.collapsed(text.len), retained.nodes[1].widget.text_selection.?);
    // ... the app's stamped edit is byte-identical to what the editor
    // applied, and nothing was (falsely) reported truncated.
    try std.testing.expectEqualStrings("abc", app_state.last_edit_insert[0..app_state.last_edit_insert_len]);
    try std.testing.expect(!app_state.saw_truncated);
}

test "paste clamps to view text capacity and flags truncation loudly" {
    var app_state: ClipboardTestApp = .{};
    const app = app_state.app();
    const harness = try createClipboardHarness(app);
    defer harness.destroy(std.testing.allocator);

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .textarea,
        .frame = geometry.RectF.init(12, 16, 280, 120),
        .text = "",
        .semantics = .{ .label = "Notes" },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    const used = harness.runtime.views[0].widget_text_len;
    const available = canvas_limits.max_canvas_widget_text_bytes_per_view - used;

    // A clipboard payload over the view's REMAINING shared text storage
    // (the semantics label already consumed a few bytes, and the widget
    // text capacity now matches the clipboard bound exactly).
    const big = try std.testing.allocator.alloc(u8, platform.max_clipboard_data_bytes);
    defer std.testing.allocator.free(big);
    @memset(big, 'a');
    try harness.runtime.writeClipboard(big);

    try harness.runtime.dispatchPlatformEvent(app, pointerInput(.pointer_down, 100, 30));
    try harness.runtime.dispatchPlatformEvent(app, keyInput("v", cmd));

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(available, retained.nodes[1].widget.text.len);
    try std.testing.expect(app_state.saw_truncated);

    // Pasting again into the now-full view is truncated to nothing and
    // still reports the truncation.
    app_state.saw_truncated = false;
    try harness.runtime.dispatchPlatformEvent(app, keyInput("v", cmd));
    const after = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(available, after.nodes[1].widget.text.len);
    try std.testing.expect(app_state.saw_truncated);
}

test "paste with an empty clipboard is a no-op" {
    var app_state: ClipboardTestApp = .{};
    const app = app_state.app();
    const harness = try createClipboardHarness(app);
    defer harness.destroy(std.testing.allocator);

    const text_field = canvas.Widget{
        .id = 2,
        .kind = .text_field,
        .frame = geometry.RectF.init(12, 16, 200, 36),
        .text = "Keep",
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, pointerInput(.pointer_down, 100, 30));
    try harness.runtime.dispatchPlatformEvent(app, keyInput("v", cmd));
    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("Keep", retained.nodes[1].widget.text);
    try std.testing.expect(!app_state.saw_truncated);
}

test "static text drag selection highlights, copies, and clears" {
    var app_state: ClipboardTestApp = .{};
    const app = app_state.app();
    const harness = try createClipboardHarness(app);
    defer harness.destroy(std.testing.allocator);

    const body = "The quick brown fox jumps over the lazy dog";
    const children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .text,
            .frame = geometry.RectF.init(12, 16, 200, 60),
            .text = body,
        },
        .{
            .id = 3,
            .kind = .button,
            .frame = geometry.RectF.init(12, 120, 120, 32),
            .text = "Run",
        },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // Press at the top-left of the paragraph, drag past the bottom-right:
    // the whole paragraph is selected.
    try harness.runtime.dispatchPlatformEvent(app, pointerInput(.pointer_down, 13, 18));
    try harness.runtime.dispatchPlatformEvent(app, pointerInput(.pointer_drag, 211, 75));
    var retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 0, .focus = body.len }, retained.nodes[1].widget.text_selection.?);
    try std.testing.expectEqual(@as(canvas.ObjectId, 2), harness.runtime.views[0].canvas_widget_selected_text_id);

    // Selection is visible in semantics (and therefore automation).
    const semantics = canvasWidgetSemanticsById(harness.runtime.views[0].widgetSemantics(), 2).?;
    try std.testing.expectEqualDeep(canvas.TextRange.init(0, body.len), semantics.text_selection.?);
    const snapshot = harness.runtime.automationSnapshot("Widgets");
    var saw_selected_text_widget = false;
    for (snapshot.widgets) |widget| {
        if (widget.text_selection) |selection| {
            if (selection.start == 0 and selection.end == body.len) saw_selected_text_widget = true;
        }
    }
    try std.testing.expect(saw_selected_text_widget);

    // The display list draws the highlight behind the paragraph.
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    var display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var saw_highlight = false;
    for (display_list.commands) |command| {
        switch (command) {
            .fill_rounded_rect => |rect| {
                if (rect.id == canvas.textSelectionCommandId(2, 0)) saw_highlight = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_highlight);

    // Copy reads the selection even though static text is not focusable.
    try harness.runtime.dispatchPlatformEvent(app, keyInput("c", cmd));
    var clipboard_buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(body, try harness.runtime.readClipboard(&clipboard_buffer));

    // A rebuild with unchanged text keeps the selection.
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualDeep(canvas.TextSelection{ .anchor = 0, .focus = body.len }, retained.nodes[1].widget.text_selection.?);

    // Pressing elsewhere clears the selection and its highlight.
    try harness.runtime.dispatchPlatformEvent(app, pointerInput(.pointer_down, 60, 130));
    retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expect(retained.nodes[1].widget.text_selection == null);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_selected_text_id);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    for (display_list.commands) |command| {
        switch (command) {
            .fill_rounded_rect => |rect| try std.testing.expect(rect.id != canvas.textSelectionCommandId(2, 0)),
            else => {},
        }
    }

    // With nothing selected, copy leaves the clipboard untouched.
    try harness.runtime.dispatchPlatformEvent(app, keyInput("c", cmd));
    try std.testing.expectEqualStrings(body, try harness.runtime.readClipboard(&clipboard_buffer));
}

test "span paragraph drag selection copies the concatenated bytes" {
    var app_state: ClipboardTestApp = .{};
    const app = app_state.app();
    const harness = try createClipboardHarness(app);
    defer harness.destroy(std.testing.allocator);

    const paragraph = "Bold opening then a calm plain finish";
    const spans = [_]canvas.TextSpan{
        .{ .text = paragraph[0..12], .weight = .bold },
        .{ .text = paragraph[12..] },
    };
    const children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .text,
            .frame = geometry.RectF.init(12, 16, 220, 60),
            .text = paragraph,
            .spans = &spans,
        },
    };
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    try harness.runtime.dispatchPlatformEvent(app, pointerInput(.pointer_down, 13, 18));
    try harness.runtime.dispatchPlatformEvent(app, pointerInput(.pointer_drag, 231, 75));
    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    const selection = retained.nodes[1].widget.text_selection.?;
    const range = selection.range(paragraph.len);
    try std.testing.expect(!range.isCollapsed(paragraph.len));

    try harness.runtime.dispatchPlatformEvent(app, keyInput("c", cmd));
    var clipboard_buffer: [128]u8 = undefined;
    const copied = try harness.runtime.readClipboard(&clipboard_buffer);
    try std.testing.expectEqualStrings(paragraph[range.start..range.end], copied);
    try std.testing.expectEqualStrings(paragraph, copied);
}

test "focused editable selection wins copy over a stale static selection" {
    var app_state: ClipboardTestApp = .{};
    const app = app_state.app();
    const harness = try createClipboardHarness(app);
    defer harness.destroy(std.testing.allocator);

    const body = "Static body";
    const children = [_]canvas.Widget{
        .{
            .id = 2,
            .kind = .text,
            .frame = geometry.RectF.init(12, 16, 200, 40),
            .text = body,
        },
        .{
            .id = 3,
            .kind = .text_field,
            .frame = geometry.RectF.init(12, 80, 200, 36),
            .text = "Field",
        },
    };
    var nodes: [3]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 320, 200), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // Select the static text, then tab focus into the field via pointer:
    // the press clears the static selection, and select-all + copy reads
    // the field.
    try harness.runtime.dispatchPlatformEvent(app, pointerInput(.pointer_down, 13, 18));
    try harness.runtime.dispatchPlatformEvent(app, pointerInput(.pointer_drag, 211, 55));
    try harness.runtime.dispatchPlatformEvent(app, pointerInput(.pointer_down, 100, 95));
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), harness.runtime.views[0].canvas_widget_selected_text_id);
    try harness.runtime.dispatchPlatformEvent(app, keyInput("a", cmd));
    try harness.runtime.dispatchPlatformEvent(app, keyInput("c", cmd));
    var clipboard_buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Field", try harness.runtime.readClipboard(&clipboard_buffer));
}
