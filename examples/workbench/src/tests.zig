//! Workbench tests: the markup's shape (one live terminal, one browser
//! toolbar, no tabs), the app-owned navigation history behind the web
//! pane, and the headline — a live pty session flowing through the
//! `<terminal>` element with no emulator wiring in this app at all.

const std = @import("std");
const native_sdk = @import("native_sdk");
const app = @import("main.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

const Model = app.Model;
const Msg = app.Msg;
const WorkbenchUi = canvas.Ui(Msg);
const WorkbenchApp = native_sdk.UiApp(Model, Msg);
const CursorPaintKind = enum { filled, hollow };

fn buildTree(arena: std.mem.Allocator, model: *const Model) !WorkbenchUi.Tree {
    var ui = WorkbenchUi.init(arena);
    return ui.finalize(app.CompiledWorkbenchView.build(&ui, model));
}

fn findByLabel(widget: canvas.Widget, label: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findByLabel(child, label)) |found| return found;
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

fn countKind(widget: canvas.Widget, kind: canvas.WidgetKind) usize {
    var total: usize = if (widget.kind == kind) 1 else 0;
    for (widget.children) |child| total += countKind(child, kind);
    return total;
}

/// Find a point that the text field's own hit mapper resolves to the
/// requested byte offset. Tests can select exact URL spans without
/// duplicating font metrics or hard-coding glyph widths.
fn pointForTextOffset(widget: canvas.Widget, tokens: canvas.DesignTokens, target: usize) ?geometry.PointF {
    var y: f32 = widget.frame.y + 2;
    while (y < widget.frame.y + widget.frame.height) : (y += 4) {
        var x: f32 = widget.frame.x + 1;
        while (x < widget.frame.x + widget.frame.width) : (x += 0.5) {
            const point = geometry.PointF.init(x, y);
            const offset = canvas.textOffsetForWidgetPoint(widget, point, tokens) orelse continue;
            if (offset == target) return point;
        }
    }
    return null;
}

/// A booted model: the history seeded and the shell spawn requested,
/// exactly as `init_fx` leaves it.
fn bootedModel(fx: *app.Effects) Model {
    var model: Model = .{};
    app.boot(&model, fx);
    return model;
}

fn fakeEffects() app.Effects {
    var fx = app.Effects.init(testing.allocator);
    fx.executor = .fake;
    return fx;
}

fn expectTerminalCursorPaint(harness: *native_sdk.TestHarness(), terminal_id: canvas.ObjectId, expected: CursorPaintKind) !void {
    const cursor_id = canvas.terminal_grid.paintIdBase(terminal_id) + 0x61_0002;
    const command = (try harness.runtime.canvasDisplayList(1, app.canvas_label)).findCommandById(cursor_id) orelse return error.TestExpectedCursor;
    switch (command.command) {
        .fill_rect => try testing.expectEqual(CursorPaintKind.filled, expected),
        .stroke_rect => try testing.expectEqual(CursorPaintKind.hollow, expected),
        else => return error.TestUnexpectedCursorCommand,
    }
}

// ------------------------------------------------------------------ layout

test "the markup lays a terminal-left split with a browser toolbar and no tabs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var fx = fakeEffects();
    defer fx.deinit();
    var model = bootedModel(&fx);

    const tree = try buildTree(arena_state.allocator(), &model);

    // One split, laid at the terminal's default third.
    const split = findByKind(tree.root, .split) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), split.value, 0.0001);
    // Two panes with the builder-synthesized divider between them.
    try testing.expectEqual(@as(usize, 3), split.children.len);
    try testing.expectEqual(canvas.WidgetKind.split_divider, split.children[1].kind);

    // The terminal pane is the FIRST child (left), and the browser
    // toolbar lives in the last — the demo's fixed geometry.
    try testing.expect(findByKind(split.children[0], .terminal) != null);
    try testing.expect(findByLabel(split.children[2], "Browser toolbar") != null);

    // Exactly one terminal, bound to the model's pty key with the
    // scrollback echo — the element carries the binding, not this app.
    try testing.expectEqual(@as(usize, 1), countKind(tree.root, .terminal));
    const terminal = findByLabel(tree.root, "Shell") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(canvas.WidgetKind.terminal, terminal.kind);
    try testing.expectEqual(app.shell_effect_key, terminal.terminal.pty);
    try testing.expectEqual(@as(u32, 0), terminal.terminal.scrollback);
    // Full-bleed terminal chrome: keyboard focus stays functional, but
    // its ring dissolves into the pane instead of leaving only the
    // exposed top edge visible as a stray horizontal rule.
    try testing.expectEqualDeep((canvas.DesignTokens{}).colors.background, terminal.style.focus_ring.?);

    // The browser chrome is the whole toolbar: back, forward, reload,
    // address bar — and nothing else. No tabs anywhere in the tree.
    const toolbar = findByLabel(tree.root, "Browser toolbar") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), countKind(toolbar, .button));
    try testing.expectEqual(@as(usize, 1), countKind(toolbar, .text_field));
    try testing.expectEqual(@as(usize, 3), countKind(tree.root, .button));
    try testing.expectEqual(@as(usize, 0), countKind(tree.root, .tabs));

    // The address bar shows the committed URL after boot.
    const address = findByLabel(tree.root, "Address") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(app.home_url, address.text);

    // The web pane's anchor exists for the webview to snap to.
    const anchor = findByLabel(tree.root, app.web_pane_anchor) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), anchor.children.len);
}

test "the split fraction and the terminal scrollback echo back into the view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var fx = fakeEffects();
    defer fx.deinit();
    var model = bootedModel(&fx);

    // The divider drag reports the applied fraction; the next build lays
    // the panes at exactly that value (the controlled-split contract).
    app.update(&model, .{ .split_resized = 0.62 }, &fx);
    try testing.expectApproxEqAbs(@as(f32, 0.62), model.split_fraction, 0.0001);

    // The terminal reports its applied view state; the binding hands the
    // scrollback back, so wheel scrollback survives rebuilds.
    app.update(&model, .{ .term_state = .{ .scrollback = 12, .history = 400, .cols = 80, .rows = 24 } }, &fx);
    try testing.expectEqual(@as(u32, 12), model.term_scrollback);

    const tree = try buildTree(arena_state.allocator(), &model);
    const split = findByKind(tree.root, .split) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 0.62), split.value, 0.0001);
    const terminal = findByLabel(tree.root, "Shell") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 12), terminal.terminal.scrollback);
}

test "the titlebar band clears the traffic lights and floors before the first chrome report" {
    var fx = fakeEffects();
    defer fx.deinit();
    var model = bootedModel(&fx);

    // No chrome report yet: the band still holds a terminal-window band.
    try testing.expect(model.titlebar_band() >= 38);

    app.update(&model, .{ .chrome_changed = .{ .insets = .{ .top = 52, .left = 0, .right = 0, .bottom = 0 } } }, &fx);
    try testing.expectEqual(@as(f32, 60), model.titlebar_band());

    // Fullscreen hides the lights (zero insets) and the band holds its
    // floor rather than snapping the terminal upward.
    app.update(&model, .{ .chrome_changed = .{ .insets = .{ .top = 0, .left = 0, .right = 0, .bottom = 0 } } }, &fx);
    try testing.expectEqual(@as(f32, 38), model.titlebar_band());
}

// -------------------------------------------------------------- navigation

test "the address bar commits a navigation the web pane picks up" {
    var fx = fakeEffects();
    defer fx.deinit();
    var model = bootedModel(&fx);
    var panes: [1]WorkbenchApp.WebViewPane = undefined;

    // Boot: the home page is the pane's URL, and back/forward are dead.
    try testing.expectEqual(@as(usize, 1), app.webPanes(&model, &panes));
    try testing.expectEqualStrings(app.web_view_label, panes[0].label);
    try testing.expectEqualStrings(app.web_pane_anchor, panes[0].anchor orelse "");
    try testing.expectEqualStrings(app.home_url, panes[0].url);
    try testing.expect(model.back_disabled());
    try testing.expect(model.forward_disabled());

    // Typing alone navigates NOTHING: the pane follows committed
    // history, never the in-progress edit.
    app.update(&model, .{ .address_edit = .{ .insert_text = "!" } }, &fx);
    _ = app.webPanes(&model, &panes);
    try testing.expectEqualStrings(app.home_url, panes[0].url);

    // Submitting commits it.
    app.update(&model, .navigate, &fx);
    _ = app.webPanes(&model, &panes);
    try testing.expectEqualStrings("https://ziglang.org!", panes[0].url);
    try testing.expect(!model.back_disabled());
    try testing.expect(model.forward_disabled());
}

test "a bare host normalizes to https and an empty address is a no-op" {
    var fx = fakeEffects();
    defer fx.deinit();
    var model = bootedModel(&fx);

    model.address_field.set("example.com");
    app.update(&model, .navigate, &fx);
    try testing.expectEqualStrings("https://example.com", model.currentUrl());
    // The bar shows the normalized URL, not what was typed.
    try testing.expectEqualStrings("https://example.com", model.address());

    // An explicit scheme passes through untouched.
    model.address_field.set("http://example.org/page");
    app.update(&model, .navigate, &fx);
    try testing.expectEqualStrings("http://example.org/page", model.currentUrl());

    // Blank (or whitespace) commits nothing and leaves history alone.
    const before = model.history_count;
    model.address_field.set("   ");
    app.update(&model, .navigate, &fx);
    try testing.expectEqual(before, model.history_count);
    try testing.expectEqualStrings("http://example.org/page", model.currentUrl());
}

test "back and forward walk the app-owned history, and a new navigation drops the tail" {
    var fx = fakeEffects();
    defer fx.deinit();
    var model = bootedModel(&fx);

    model.address_field.set("https://a.example");
    app.update(&model, .navigate, &fx);
    model.address_field.set("https://b.example");
    app.update(&model, .navigate, &fx);
    try testing.expectEqual(@as(usize, 3), model.history_count);

    // Back walks to the previous entry and re-fills the address bar.
    app.update(&model, .go_back, &fx);
    try testing.expectEqualStrings("https://a.example", model.currentUrl());
    try testing.expectEqualStrings("https://a.example", model.address());
    try testing.expect(!model.forward_disabled());

    // Forward returns.
    app.update(&model, .go_forward, &fx);
    try testing.expectEqualStrings("https://b.example", model.currentUrl());
    try testing.expect(model.forward_disabled());

    // Navigating from mid-history drops the forward entries.
    app.update(&model, .go_back, &fx);
    app.update(&model, .go_back, &fx);
    try testing.expectEqualStrings(app.home_url, model.currentUrl());
    try testing.expect(model.back_disabled());
    model.address_field.set("https://c.example");
    app.update(&model, .navigate, &fx);
    try testing.expectEqual(@as(usize, 2), model.history_count);
    try testing.expect(model.forward_disabled());

    // Past the ends both verbs are no-ops (the buttons are disabled
    // there, and the model refuses regardless).
    app.update(&model, .go_forward, &fx);
    try testing.expectEqualStrings("https://c.example", model.currentUrl());
    app.update(&model, .go_back, &fx);
    app.update(&model, .go_back, &fx);
    try testing.expectEqualStrings(app.home_url, model.currentUrl());
}

test "the navigation buttons disable at the ends of history" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var fx = fakeEffects();
    defer fx.deinit();
    var model = bootedModel(&fx);

    const fresh = try buildTree(arena_state.allocator(), &model);
    try testing.expect((findByLabel(fresh.root, "Back") orelse return error.TestUnexpectedResult).state.disabled);
    try testing.expect((findByLabel(fresh.root, "Forward") orelse return error.TestUnexpectedResult).state.disabled);
    try testing.expect(!(findByLabel(fresh.root, "Reload") orelse return error.TestUnexpectedResult).state.disabled);

    model.address_field.set("https://a.example");
    app.update(&model, .navigate, &fx);
    const navigated = try buildTree(arena_state.allocator(), &model);
    try testing.expect(!(findByLabel(navigated.root, "Back") orelse return error.TestUnexpectedResult).state.disabled);
    try testing.expect((findByLabel(navigated.root, "Forward") orelse return error.TestUnexpectedResult).state.disabled);
}

test "reload bumps the pane token without changing the URL" {
    var fx = fakeEffects();
    defer fx.deinit();
    var model = bootedModel(&fx);
    var panes: [1]WorkbenchApp.WebViewPane = undefined;

    _ = app.webPanes(&model, &panes);
    const before = panes[0].reload_token;
    app.update(&model, .reload, &fx);
    _ = app.webPanes(&model, &panes);
    try testing.expect(panes[0].reload_token != before);
    try testing.expectEqualStrings(app.home_url, panes[0].url);
}

// ------------------------------------------------------------ live session

test "boot spawns the shell against the key the terminal element binds" {
    var fx = fakeEffects();
    defer fx.deinit();
    var model = bootedModel(&fx);

    try testing.expectEqual(@as(usize, 1), fx.pendingPtyCount());
    const request = fx.pendingPtyAt(0) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(app.shell_effect_key, request.key);
    try testing.expectEqualStrings(app.default_shell_argv[0], request.argv[0]);
    try testing.expectEqual(model.shell_key(), request.key);
    try testing.expect(!model.shell_live);
}

const webview_origins = [_][]const u8{ "zero://inline", "zero://app", "*" };

const Harness = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *WorkbenchApp,
    app_iface: native_sdk.App,

    fn create() !Harness {
        const harness = try native_sdk.TestHarness().create(testing.allocator, .{
            .size = geometry.SizeF.init(app.window_width, app.window_height),
        });
        errdefer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        // The scene declares a webview; the harness runtime allows the
        // origins the app's own security policy allows.
        harness.runtime.options.security.navigation.allowed_origins = &webview_origins;

        const app_state = try testing.allocator.create(WorkbenchApp);
        errdefer testing.allocator.destroy(app_state);
        app_state.* = WorkbenchApp.init(testing.allocator, .{}, .{
            .name = "workbench",
            .scene = app.shell_scene,
            .canvas_label = app.canvas_label,
            .update_fx = app.update,
            .init_fx = app.boot,
            .view = app.CompiledWorkbenchView.build,
            .on_chrome = app.onChrome,
            .web_panes = app.webPanes,
        });
        errdefer app_state.deinit();

        const app_iface = app_state.app();
        try harness.start(app_iface);
        app_state.effects.executor = .fake;
        var self = Harness{ .harness = harness, .app_state = app_state, .app_iface = app_iface };
        try self.frame();
        return self;
    }

    fn destroy(self: *Harness) void {
        self.app_state.deinit();
        testing.allocator.destroy(self.app_state);
        self.harness.destroy(testing.allocator);
    }

    var frame_index: u64 = 0;

    fn frame(self: *Harness) !void {
        frame_index += 1;
        try self.harness.runtime.dispatchPlatformEvent(self.app_iface, .{ .gpu_surface_frame = .{
            .label = app.canvas_label,
            .size = geometry.SizeF.init(app.window_width, app.window_height),
            .scale_factor = 2,
            .frame_index = frame_index,
            .timestamp_ns = frame_index * 16_000_000,
        } });
        try self.harness.runtime.dispatchPlatformEvent(self.app_iface, .wake);
        try self.harness.runtime.dispatchPlatformEvent(self.app_iface, .frame_requested);
    }

    fn click(self: *Harness, x: f32, y: f32) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app_iface, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = app.canvas_label,
            .kind = .pointer_down,
            .x = x,
            .y = y,
        } });
    }

    fn rightClick(self: *Harness, x: f32, y: f32) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app_iface, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = app.canvas_label,
            .kind = .pointer_down,
            .button = 1,
            .x = x,
            .y = y,
        } });
    }

    fn contextMenuAction(self: *Harness, token: u64, item_id: u32) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app_iface, .{ .context_menu_action = .{
            .window_id = 1,
            .view_label = app.canvas_label,
            .token = token,
            .item_id = item_id,
        } });
    }

    fn typeText(self: *Harness, text: []const u8) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app_iface, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = app.canvas_label,
            .kind = .text_input,
            .text = text,
        } });
    }

    /// The grid the painter would draw: resolved through the runtime's
    /// installed lookup, exactly as the retained tree reads it.
    fn grid(self: *Harness) !*const canvas.TerminalGrid {
        const lookup = self.app_state.terminal_sessions.lookup() orelse return error.TestExpectedGrid;
        return lookup.resolve(lookup.context, app.shell_effect_key) orelse error.TestExpectedGrid;
    }
};

test "deleting a pointer-selected address span updates the model-owned buffer" {
    var h = try Harness.create();
    defer h.destroy();

    const url = "https://test.com";
    h.app_state.model.address_field.set(url);
    try h.app_state.rebuild(&h.harness.runtime, 1);

    const layout = try h.harness.runtime.canvasWidgetLayout(1, app.canvas_label);
    var address: ?canvas.Widget = null;
    for (layout.nodes) |node| {
        if (std.mem.eql(u8, node.widget.semantics.label, "Address")) {
            address = node.widget;
            break;
        }
    }
    const field = address orelse return error.TestUnexpectedResult;
    const view_index = h.harness.runtime.findViewIndex(1, app.canvas_label) orelse return error.TestUnexpectedResult;
    const tokens = h.harness.runtime.views[view_index].widget_tokens;
    const selection_start = pointForTextOffset(field, tokens, "https://".len) orelse return error.TestUnexpectedResult;
    const selection_end = pointForTextOffset(field, tokens, "https://test".len) orelse return error.TestUnexpectedResult;

    try h.harness.runtime.dispatchPlatformEvent(h.app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .pointer_down,
        .x = selection_start.x,
        .y = selection_start.y,
    } });
    try h.harness.runtime.dispatchPlatformEvent(h.app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .pointer_drag,
        .x = selection_end.x,
        .y = selection_end.y,
    } });
    try h.harness.runtime.dispatchPlatformEvent(h.app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .pointer_up,
        .x = selection_end.x,
        .y = selection_end.y,
    } });

    try testing.expectEqualDeep(
        canvas.TextSelection{ .anchor = "https://".len, .focus = "https://test".len },
        h.app_state.model.address_field.selection,
    );

    // A MacBook's Delete key is the backward-delete key: the selected
    // "test" span must win over the buffer's old end-of-value caret.
    try h.harness.runtime.dispatchPlatformEvent(h.app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "backspace",
    } });

    try testing.expectEqualStrings("https://.com", h.app_state.model.address());
    const retained = try h.harness.runtime.canvasWidgetLayout(1, app.canvas_label);
    const retained_address = retained.findById(field.id) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("https://.com", retained_address.widget.text);
}

test "a live pty session flows through the <terminal> element: output, typing, resize" {
    if (comptime !native_sdk.runtime.terminal_sessions_enabled) return error.SkipZigTest;
    var h = try Harness.create();
    defer h.destroy();

    // The element's binding requested the session; boot's spawn is the
    // only pty wiring this app performs.
    try testing.expectEqual(@as(usize, 1), h.app_state.effects.pendingPtyCount());

    // Shell output reaches the emulator through the effects tap and
    // lands as real cells in the grid the painter reads.
    try h.app_state.effects.feedPtyOutput(app.shell_effect_key, "demo$ echo hi\r\nhi\r\ndemo$ ");
    try h.frame();
    try testing.expect(h.app_state.model.shell_live);
    const grid = try h.grid();
    try testing.expect(grid.running);
    try testing.expect(std.mem.indexOf(u8, grid.screen_text, "echo hi") != null);
    try testing.expect(std.mem.indexOf(u8, grid.screen_text, "hi") != null);

    // The layout drove the pty's size: the left third of a 1280x800
    // window is a real cols/rows pair, reported once.
    const size = h.app_state.effects.ptySize(app.shell_effect_key) orelse return error.TestUnexpectedResult;
    try testing.expect(size.cols > 0 and size.rows > 0);
    try testing.expectEqual(size.rows, @as(u16, @intCast(grid.rows.len)));

    // Focus the terminal (a click in the left pane) and type: the
    // keystrokes reach the pty through the journaled write path, with
    // no app-side keyboard handling at all. Tab belongs to the shell
    // too (completion/indentation), rather than moving focus into the
    // browser toolbar beside it.
    try h.click(200, 400);
    try h.typeText("ls");
    try h.harness.runtime.dispatchPlatformEvent(h.app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "tab",
    } });
    try testing.expectEqualStrings("ls\t", h.app_state.effects.ptyWrittenBytes(app.shell_effect_key));

    // Entering the live terminal is still traversal for the WHOLE
    // physical Shift+Tab: neither an auto-repeat nor the matching
    // release may leak into the pty (kitty reports releases, so this
    // covers the otherwise-invisible orphan-release case too).
    try h.app_state.effects.feedPtyOutput(app.shell_effect_key, "\x1b[>11u");
    try h.frame();
    const layout = try h.harness.runtime.canvasWidgetLayout(1, app.canvas_label);
    var terminal_id: canvas.ObjectId = 0;
    var divider_id: canvas.ObjectId = 0;
    for (layout.nodes) |node| {
        if (node.widget.kind == .terminal) terminal_id = node.widget.id;
        if (node.widget.kind == .split_divider) divider_id = node.widget.id;
    }
    try testing.expect(terminal_id != 0);
    try testing.expect(divider_id != 0);
    const view_index = h.harness.runtime.findViewIndex(1, app.canvas_label) orelse return error.TestUnexpectedResult;
    h.harness.runtime.views[view_index].canvas_widget_focused_id = divider_id;
    try h.harness.runtime.dispatchPlatformEvent(h.app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "tab",
        .modifiers = .{ .shift = true },
    } });
    try testing.expectEqual(terminal_id, h.harness.runtime.views[view_index].canvas_widget_focused_id);
    try h.harness.runtime.dispatchPlatformEvent(h.app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "tab",
        .modifiers = .{ .shift = true },
    } });
    try h.harness.runtime.dispatchPlatformEvent(h.app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_up,
        .key = "tab",
        .modifiers = .{ .shift = true },
    } });
    try testing.expectEqualStrings("ls\t", h.app_state.effects.ptyWrittenBytes(app.shell_effect_key));

    // The session ends exactly once and the app notes it.
    try h.app_state.effects.feedPtyExit(app.shell_effect_key, 0, 0, .exited, 0);
    try h.frame();
    try testing.expect(h.app_state.model.shell_exited);
    try testing.expect(!h.app_state.model.shell_live);
    try testing.expect(!(try h.grid()).running);

    // The binding remains the nonzero model-owned effect key after
    // exit, but the grid is no longer running. Tab therefore leaves
    // the terminal instead of becoming a dead-session focus trap.
    try h.harness.runtime.dispatchPlatformEvent(h.app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "tab",
    } });
    try testing.expectEqual(divider_id, h.harness.runtime.views[view_index].canvas_widget_focused_id);
    try testing.expectEqualStrings("", h.app_state.effects.ptyWrittenBytes(app.shell_effect_key));
}

test "terminal Paste shortcuts and context menus use VT encoding and revalidate the session" {
    if (comptime !native_sdk.runtime.terminal_sessions_enabled) return error.SkipZigTest;
    var h = try Harness.create();
    defer h.destroy();

    // Mode 2004 is emulator state derived from child output. Context
    // Paste must observe it rather than treating clipboard bytes as an
    // ordinary multi-character typing commit.
    try h.app_state.effects.feedPtyOutput(app.shell_effect_key, "demo$ \x1b[?2004h\x1b[>11u");
    try h.frame();
    const pasted = "echo one\n\x1b[201~echo two\x03";
    try h.harness.runtime.writeClipboard(pasted);
    const before = h.app_state.effects.ptyWrittenBytes(app.shell_effect_key).len;

    try h.rightClick(200, 400);
    const items = h.harness.null_platform.contextMenuItems();
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expect(items[1].enabled);
    try h.contextMenuAction(h.harness.null_platform.context_menu_token, 3);

    // The encoder supplies bracketed-paste fenceposts and strips ESC /
    // VINTR from the clipboard payload. The embedded LF stays inside
    // the bracket instead of becoming an immediately executed command.
    const written = h.app_state.effects.ptyWrittenBytes(app.shell_effect_key);
    try testing.expectEqualStrings(
        "\x1b[200~echo one\n [201~echo two \x1b[201~",
        written[before..],
    );

    // Cmd+V follows the same paste encoder. Its physical key-up is
    // consumed too: kitty event reporting must not receive an orphan
    // modified-V release after the key-down became clipboard input.
    const before_shortcut = written.len;
    try h.harness.runtime.dispatchPlatformEvent(h.app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_down,
        .key = "v",
        .modifiers = .{ .primary = true, .command = true },
    } });
    try h.harness.runtime.dispatchPlatformEvent(h.app_iface, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = app.canvas_label,
        .kind = .key_up,
        .key = "v",
    } });
    try testing.expectEqualStrings(
        "\x1b[200~echo one\n [201~echo two \x1b[201~",
        h.app_state.effects.ptyWrittenBytes(app.shell_effect_key)[before_shortcut..],
    );

    // Open another live menu, then let the child exit before the native
    // action resolves (GTK's asynchronous shape). The stale Paste is a
    // no-op, and a fresh ended-session menu disables it up front.
    try h.rightClick(200, 400);
    const pending_token = h.harness.null_platform.context_menu_token;
    try h.app_state.effects.feedPtyExit(app.shell_effect_key, 0, 0, .exited, 0);
    try h.frame();
    const before_stale_action = h.app_state.effects.ptyWrittenBytes(app.shell_effect_key).len;
    try h.contextMenuAction(pending_token, 3);
    try testing.expectEqual(
        before_stale_action,
        h.app_state.effects.ptyWrittenBytes(app.shell_effect_key).len,
    );

    try h.rightClick(200, 400);
    try testing.expect(!h.harness.null_platform.contextMenuItems()[1].enabled);
}

test "terminal and address focus yield to the webview and recover on canvas click" {
    if (comptime !native_sdk.runtime.terminal_sessions_enabled) return error.SkipZigTest;
    var h = try Harness.create();
    defer h.destroy();

    try h.app_state.effects.feedPtyOutput(app.shell_effect_key, "demo$ ");
    try h.frame();
    try h.click(200, 400);

    const layout = try h.harness.runtime.canvasWidgetLayout(1, app.canvas_label);
    var terminal_id: canvas.ObjectId = 0;
    var address_id: canvas.ObjectId = 0;
    for (layout.nodes) |node| {
        if (node.widget.kind == .terminal) terminal_id = node.widget.id;
        if (std.mem.eql(u8, node.widget.semantics.label, "Address")) address_id = node.widget.id;
    }
    try testing.expect(terminal_id != 0);
    try testing.expect(address_id != 0);
    const view_index = h.harness.runtime.findViewIndex(1, app.canvas_label) orelse return error.TestUnexpectedResult;
    var webview_index: ?usize = null;
    for (h.harness.runtime.webviews[0..h.harness.runtime.webview_count], 0..) |webview, index| {
        if (webview.window_id == 1 and std.mem.eql(u8, webview.label, app.web_view_label)) {
            webview_index = index;
            break;
        }
    }
    const web_index = webview_index orelse return error.TestUnexpectedResult;
    try testing.expectEqual(terminal_id, h.harness.runtime.views[view_index].canvas_widget_focused_id);
    try expectTerminalCursorPaint(h.harness, terminal_id, .filled);

    // The toolbar is still canvas content: clicking its address field
    // moves widget focus within the canvas and hollows the terminal.
    try h.click(900, 24);
    try testing.expectEqual(address_id, h.harness.runtime.views[view_index].canvas_widget_focused_id);
    try testing.expect(h.harness.runtime.views[view_index].focused);
    try expectTerminalCursorPaint(h.harness, terminal_id, .hollow);

    // The embedded page owns its pointer stream, so its host focus edge
    // names the webview directly. The canvas retains the address id as
    // focus memory but no longer paints or reports it as keyboard focus.
    try h.harness.runtime.dispatchPlatformEvent(h.app_iface, .{ .view_focused = .{
        .window_id = 1,
        .label = app.web_view_label,
    } });
    try testing.expect(!h.harness.runtime.views[view_index].focused);
    try testing.expect(h.harness.runtime.webviews[web_index].focused);
    try testing.expectEqual(address_id, h.harness.runtime.views[view_index].canvas_widget_focused_id);
    try expectTerminalCursorPaint(h.harness, terminal_id, .hollow);

    // A canvas click is the symmetric edge: the canvas view retakes
    // keyboard ownership and normal hit-testing moves widget focus.
    try h.click(200, 400);
    try testing.expect(h.harness.runtime.views[view_index].focused);
    try testing.expect(!h.harness.runtime.webviews[web_index].focused);
    try testing.expectEqual(terminal_id, h.harness.runtime.views[view_index].canvas_widget_focused_id);
    try expectTerminalCursorPaint(h.harness, terminal_id, .filled);

    // App blur hollows the cursor but preserves the per-window focus
    // memory that activation restores.
    try h.harness.runtime.dispatchPlatformEvent(h.app_iface, .app_deactivated);
    try testing.expectEqual(terminal_id, h.harness.runtime.views[view_index].canvas_widget_focused_id);
    try expectTerminalCursorPaint(h.harness, terminal_id, .hollow);
    try h.harness.runtime.dispatchPlatformEvent(h.app_iface, .app_activated);
    try expectTerminalCursorPaint(h.harness, terminal_id, .filled);

    // Moving key status to another app window has the same pixel
    // consequence without discarding the first window's remembered
    // widget focus.
    const second = try h.harness.runtime.createWindow(.{
        .label = "tools",
        .title = "Tools",
        .source = native_sdk.platform.WebViewSource.html("<p>Tools</p>"),
    });
    try h.harness.runtime.dispatchPlatformEvent(h.app_iface, .{ .window_focused = second.id });
    try testing.expectEqual(terminal_id, h.harness.runtime.views[view_index].canvas_widget_focused_id);
    try expectTerminalCursorPaint(h.harness, terminal_id, .hollow);
    try h.harness.runtime.dispatchPlatformEvent(h.app_iface, .{ .window_focused = 1 });
    try expectTerminalCursorPaint(h.harness, terminal_id, .filled);
}
