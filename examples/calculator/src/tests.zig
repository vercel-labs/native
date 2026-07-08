//! calculator tests: exhaustive arithmetic through the real dispatch
//! paths — every keypad button via `msgForPointer`, keyboard input via
//! real `gpu_surface_input` events through the runtime's focus + text
//! routing, the Escape chrome shortcut through the platform event path —
//! plus formatting, theming, markup engine parity, automation snapshot
//! assertions, and an exact-frame precision check of the keypad grid.

const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");
const model_mod = @import("model.zig");
const theme = @import("theme.zig");
const view_mod = @import("view.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

const Model = main.Model;
const Msg = main.Msg;
const Ui = view_mod.Ui;
const App = main.CalculatorApp;

// ------------------------------------------------------------- tree utils

fn buildTree(arena: std.mem.Allocator, model: *const Model) !Ui.Tree {
    var ui = Ui.init(arena);
    return ui.finalizeWithTokens(view_mod.rootView(&ui, model), main.tokensFromModel(model));
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
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

/// Press one keypad button by its face text, through the tree's pointer
/// dispatch — exactly what a click resolves to.
const PressHarness = struct {
    arena: std.mem.Allocator,
    model: *Model,

    fn press(self: PressHarness, face: []const u8) !void {
        const tree = try buildTree(self.arena, self.model);
        const button = findByText(tree.root, .button, face) orelse return error.ButtonNotFound;
        const msg = tree.msgForPointer(button.id, .up) orelse return error.NoPointerMsg;
        main.update(self.model, msg);
    }

    /// Press a whole sequence: "12.5+4=" presses each face in order
    /// (multi-byte faces like × or ÷ are pressed via `press` directly).
    fn presses(self: PressHarness, faces: []const []const u8) !void {
        for (faces) |face| try self.press(face);
    }

    fn display(self: PressHarness) ![]const u8 {
        return self.model.displayText(self.arena);
    }

    fn expression(self: PressHarness) ![]const u8 {
        return self.model.expressionText(self.arena);
    }

    fn memory(self: PressHarness) ![]const u8 {
        return self.model.memoryText(self.arena);
    }
};

// -------------------------------------------------------------- app utils

const surface_size = geometry.SizeF.init(main.window_width, main.window_height);

const LiveApp = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *App,
    app: native_sdk.App,

    fn start() !LiveApp {
        const harness = try native_sdk.TestHarness().create(testing.allocator, .{ .size = surface_size });
        errdefer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;

        const app_state = try testing.allocator.create(App);
        errdefer testing.allocator.destroy(app_state);
        app_state.* = App.init(std.heap.page_allocator, .{}, main.calculatorOptions());
        app_state.effects.executor = .fake;
        const app = app_state.app();
        try harness.start(app);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = main.canvas_label,
            .size = surface_size,
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        return .{ .harness = harness, .app_state = app_state, .app = app };
    }

    fn stop(self: LiveApp) void {
        self.app_state.deinit();
        testing.allocator.destroy(self.app_state);
        self.harness.destroy(testing.allocator);
    }

    fn layoutNode(self: LiveApp, kind: canvas.WidgetKind) !canvas.WidgetLayoutNode {
        const layout = try self.harness.runtime.canvasWidgetLayout(1, main.canvas_label);
        for (layout.nodes) |node| {
            if (node.widget.kind == kind) return node;
        }
        return error.WidgetNotFound;
    }

    /// Click at a point through the full input pipeline (down + up), the
    /// same seam real pointer events use — including focus updates.
    fn click(self: LiveApp, point: geometry.PointF) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .label = main.canvas_label,
            .kind = .pointer_down,
            .x = point.x,
            .y = point.y,
        } });
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .label = main.canvas_label,
            .kind = .pointer_up,
            .x = point.x,
            .y = point.y,
        } });
    }

    /// One keyboard key through the real input pipeline (focus routing,
    /// keyboard + text-input events, app dispatch).
    fn key(self: LiveApp, name: []const u8, text: []const u8) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .label = main.canvas_label,
            .kind = .key_down,
            .key = name,
            .text = text,
        } });
    }

    fn typeChars(self: LiveApp, chars: []const u8) !void {
        for (chars) |char| {
            const text: [1]u8 = .{char};
            try self.key(&text, &text);
        }
    }

    fn displayText(self: LiveApp, arena: std.mem.Allocator) []const u8 {
        return self.app_state.model.displayText(arena);
    }
};

// ------------------------------------------------------------ arithmetic

test "every keypad button dispatches a typed message through msgForPointer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model = Model{};
    const h = PressHarness{ .arena = arena_state.allocator(), .model = &model };

    // All 19 faces resolve to a pointer message.
    const faces = [_][]const u8{ "AC", "±", "%", "÷", "7", "8", "9", "×", "4", "5", "6", "−", "1", "2", "3", "+", "0", ".", "=" };
    const tree = try buildTree(h.arena, &model);
    for (faces) |face| {
        const button = findByText(tree.root, .button, face) orelse return error.ButtonNotFound;
        try testing.expect(tree.msgForPointer(button.id, .up) != null);
        // A press phase alone never dispatches; release does.
        try testing.expect(tree.msgForPointer(button.id, .down) == null);
    }

    // A real calculation, one button at a time: 12.5 + 4 = 16.5.
    try h.presses(&.{ "1", "2", ".", "5" });
    try testing.expectEqualStrings("12.5", try h.display());
    try h.press("+");
    try testing.expectEqualStrings("12.5 +", try h.expression());
    try h.press("4");
    try testing.expectEqualStrings("12.5 + 4", try h.expression());
    try h.press("=");
    try testing.expectEqualStrings("16.5", try h.display());
    try testing.expectEqualStrings("12.5 + 4 = 16.5", try h.memory());
    try testing.expectEqualStrings("", try h.expression());
}

test "immediate execution: chains apply left to right, no precedence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model = Model{};
    const h = PressHarness{ .arena = arena_state.allocator(), .model = &model };

    // 2 + 3 × 4 = 20 (not 14): × applies the pending + first.
    try h.presses(&.{ "2", "+", "3" });
    try h.press("×");
    try testing.expectEqualStrings("5", try h.display()); // intermediate shown live
    try testing.expectEqualStrings("5 ×", try h.expression());
    try h.presses(&.{ "4", "=" });
    try testing.expectEqualStrings("20", try h.display());
    try testing.expectEqualStrings("5 × 4 = 20", try h.memory());

    // Pressing another operator with no operand just switches it.
    model.clearAll();
    try h.presses(&.{ "2", "+" });
    try h.press("×");
    try testing.expectEqualStrings("2 ×", try h.expression());
    try h.presses(&.{ "3", "=" });
    try testing.expectEqualStrings("6", try h.display());

    // "5 + =" uses the display as the missing operand: 10.
    model.clearAll();
    try h.presses(&.{ "5", "+", "=" });
    try testing.expectEqualStrings("10", try h.display());

    // Repeat equals replays the last operation: 2 + 3 = 5, =, 8, =, 11.
    model.clearAll();
    try h.presses(&.{ "2", "+", "3", "=" });
    try testing.expectEqualStrings("5", try h.display());
    try h.press("=");
    try testing.expectEqualStrings("8", try h.display());
    try h.press("=");
    try testing.expectEqualStrings("11", try h.display());
    try testing.expectEqualStrings("8 + 3 = 11", try h.memory());

    // A typed number then equals repeats onto it: 7 = -> 7 + 3 = 10.
    try h.presses(&.{ "7", "=" });
    try testing.expectEqualStrings("10", try h.display());

    // Subtraction and division chains hold up: 100 − 30 ÷ 2 = 35.
    model.clearAll();
    try h.presses(&.{ "1", "0", "0", "−", "3", "0", "÷", "2", "=" });
    try testing.expectEqualStrings("35", try h.display());
}

test "decimal entry: single dot, leading zeros, twelve-digit window, backspace" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model = Model{};
    const h = PressHarness{ .arena = arena_state.allocator(), .model = &model };

    // A leading dot shows as "0." and a second dot is ignored.
    try h.press(".");
    try testing.expectEqualStrings("0.", try h.display());
    try h.presses(&.{ "5", "." });
    try testing.expectEqualStrings("0.5", try h.display());

    // 0.1 + 0.2 displays 0.3 (display rounding; the model keeps f64).
    model.clearAll();
    try h.presses(&.{ ".", "1", "+", ".", "2", "=" });
    try testing.expectEqualStrings("0.3", try h.display());

    // Leading zeros collapse: 0 0 7 types as 7.
    model.clearAll();
    try h.presses(&.{ "0", "0", "7" });
    try testing.expectEqualStrings("7", try h.display());

    // The entry window is 12 digits; the 13th is ignored.
    model.clearAll();
    for (0..13) |_| try h.press("9");
    try testing.expectEqualStrings("999999999999", try h.display());

    // Backspace edits the typed entry down to a bare zero, never past it.
    model.clearAll();
    try h.presses(&.{ "1", "2", "3" });
    model.press(.backspace);
    try testing.expectEqualStrings("12", try h.display());
    model.press(.backspace);
    model.press(.backspace);
    try testing.expectEqualStrings("0", try h.display());
    model.press(.backspace);
    try testing.expectEqualStrings("0", try h.display());

    // Results are not editable: backspace after = is a no-op.
    model.clearAll();
    try h.presses(&.{ "8", "×", "8", "=" });
    model.press(.backspace);
    try testing.expectEqualStrings("64", try h.display());
}

test "divide by zero shows Error, freezes operators, and recovers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model = Model{};
    const h = PressHarness{ .arena = arena_state.allocator(), .model = &model };

    try h.presses(&.{ "1", "2", "÷", "0", "=" });
    try testing.expectEqualStrings("Error", try h.display());
    try testing.expectEqualStrings("12 ÷ 0", try h.expression());
    try testing.expectEqualStrings("12 ÷ 0 = Error", try h.memory());

    // Operators, equals, percent, sign, and backspace are inert in error.
    try h.presses(&.{ "+", "=", "%", "±" });
    model.press(.backspace);
    try testing.expectEqualStrings("Error", try h.display());

    // A digit starts fresh; so does AC.
    try h.press("4");
    try testing.expectEqualStrings("4", try h.display());
    try testing.expect(!model.err);
    try h.presses(&.{ "÷", "0", "=" });
    try testing.expectEqualStrings("Error", try h.display());
    try h.press("AC");
    try testing.expectEqualStrings("0", try h.display());
    try testing.expectEqualStrings("", try h.memory());

    // 0 ÷ 0 (NaN) is an error too, and errors surface mid-chain: the
    // failing operator press itself shows Error.
    try h.presses(&.{ "0", "÷", "0", "=" });
    try testing.expectEqualStrings("Error", try h.display());
    model.clearAll();
    try h.presses(&.{ "5", "÷", "0", "+" });
    try testing.expectEqualStrings("Error", try h.display());
}

test "percent and sign toggle on entries, results, and pending operands" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model = Model{};
    const h = PressHarness{ .arena = arena_state.allocator(), .model = &model };

    // Percent divides the current entry by 100 (the documented model).
    try h.presses(&.{ "5", "0", "%" });
    try testing.expectEqualStrings("0.5", try h.display());

    // Percent of a result: 200 + 100 = 300, % -> 3.
    model.clearAll();
    try h.presses(&.{ "2", "0", "0", "+", "1", "0", "0", "=", "%" });
    try testing.expectEqualStrings("3", try h.display());

    // Percent then equals uses the percented value as the operand:
    // 80 × 25 % = -> 80 × 0.25 = 20.
    model.clearAll();
    try h.presses(&.{ "8", "0", "×", "2", "5", "%", "=" });
    try testing.expectEqualStrings("20", try h.display());

    // Sign toggles the entry while typing (including a bare zero).
    model.clearAll();
    try h.presses(&.{ "4", "2", "±" });
    try testing.expectEqualStrings("-42", try h.display());
    try h.press("±");
    try testing.expectEqualStrings("42", try h.display());
    model.clearAll();
    try h.press("±");
    try testing.expectEqualStrings("0", try h.display());

    // Sign toggles a result and the negated value feeds the next op.
    model.clearAll();
    try h.presses(&.{ "6", "×", "7", "=", "±" });
    try testing.expectEqualStrings("-42", try h.display());
    try h.presses(&.{ "+", "2", "=" });
    try testing.expectEqualStrings("-40", try h.display());

    // Sign while an operator is pending negates the standing operand.
    model.clearAll();
    try h.presses(&.{ "9", "+", "3", "±" });
    try testing.expectEqualStrings("-3", try h.display());
    try h.press("=");
    try testing.expectEqualStrings("6", try h.display());
}

test "the pending operator highlights on the keypad and clears on equals" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model = Model{};
    const h = PressHarness{ .arena = arena_state.allocator(), .model = &model };

    try h.presses(&.{ "8", "×" });
    var tree = try buildTree(h.arena, &model);
    try testing.expect(findByText(tree.root, .button, "×").?.state.selected);
    try testing.expect(!findByText(tree.root, .button, "+").?.state.selected);

    try h.press("+");
    tree = try buildTree(h.arena, &model);
    try testing.expect(!findByText(tree.root, .button, "×").?.state.selected);
    try testing.expect(findByText(tree.root, .button, "+").?.state.selected);

    try h.presses(&.{ "2", "=" });
    tree = try buildTree(h.arena, &model);
    try testing.expect(!findByText(tree.root, .button, "+").?.state.selected);
}

// ------------------------------------------------------------ formatting

test "formatValue is honest about f64" {
    var buffer: [model_mod.max_value_chars]u8 = undefined;

    // Integers print exactly up to the 12-digit window.
    try testing.expectEqualStrings("0", model_mod.formatValue(&buffer, 0));
    try testing.expectEqualStrings("0", model_mod.formatValue(&buffer, -0.0));
    try testing.expectEqualStrings("84", model_mod.formatValue(&buffer, 84));
    try testing.expectEqualStrings("-2048", model_mod.formatValue(&buffer, -2048));
    try testing.expectEqualStrings("999999999999", model_mod.formatValue(&buffer, 999999999999));

    // Fractions trim to at most 10 decimals.
    try testing.expectEqualStrings("0.3", model_mod.formatValue(&buffer, 0.1 + 0.2));
    try testing.expectEqualStrings("0.5", model_mod.formatValue(&buffer, 0.5));
    try testing.expectEqualStrings("-12.25", model_mod.formatValue(&buffer, -12.25));
    try testing.expectEqualStrings("3.3333333333", model_mod.formatValue(&buffer, 10.0 / 3.0));
    try testing.expectEqualStrings("3", model_mod.formatValue(&buffer, 3.0000000000000004));

    // Beyond the window: scientific, with the mantissa trimmed.
    try testing.expectEqualStrings("1e12", model_mod.formatValue(&buffer, 1e12));
    try testing.expectEqualStrings("2.5e13", model_mod.formatValue(&buffer, 2.5e13));
    try testing.expectEqualStrings("-1.5e15", model_mod.formatValue(&buffer, -1.5e15));
    try testing.expectEqualStrings("1e-10", model_mod.formatValue(&buffer, 1e-10));

    // Non-finite is an error, never digits.
    try testing.expectEqualStrings("Error", model_mod.formatValue(&buffer, std.math.inf(f64)));
    try testing.expectEqualStrings("Error", model_mod.formatValue(&buffer, -std.math.inf(f64)));
    try testing.expectEqualStrings("Error", model_mod.formatValue(&buffer, std.math.nan(f64)));
}

// -------------------------------------------------------------- keyboard

test "keyboard input flows through the focused expression field" {
    const live = try LiveApp.start();
    defer live.stop();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = &live.app_state.model;

    // Unfocused, keystrokes go nowhere (the honest seam: focus first).
    try live.typeChars("5");
    try testing.expectEqualStrings("0", live.displayText(arena));

    // Click the expression field to focus it, then type a calculation.
    const field = try live.layoutNode(.text_field);
    try live.click(geometry.PointF.init(
        field.frame.x + field.frame.width / 2,
        field.frame.y + field.frame.height / 2,
    ));
    try live.typeChars("12+7");
    try testing.expectEqualStrings("12 + 7", model.expressionText(arena));
    try live.key("enter", "");
    try testing.expectEqualStrings("19", live.displayText(arena));

    // Backspace edits the entry through the same path.
    try live.typeChars("305");
    try live.key("backspace", "");
    try testing.expectEqualStrings("30", live.displayText(arena));

    // Operator aliases: * x / and = all mean what a keyboard means.
    try live.typeChars("*4=");
    try testing.expectEqualStrings("120", live.displayText(arena));
    try live.typeChars("81/9=");
    try testing.expectEqualStrings("9", live.displayText(arena));
    try live.typeChars("6x7=");
    try testing.expectEqualStrings("42", live.displayText(arena));

    // Unknown characters are ignored; the model text never shows them.
    try live.typeChars("e#5");
    try testing.expectEqualStrings("5", live.displayText(arena));

    // 'c' clears.
    try live.typeChars("c");
    try testing.expectEqualStrings("0", live.displayText(arena));
    try testing.expect(model.last == null);
}

test "the Escape chrome shortcut clears without any widget focus" {
    // The registered shortcut is valid platform-side (escape may be
    // unmodified; character keys may not).
    for (main.app_shortcuts) |shortcut| {
        try native_sdk.platform.validateShortcut(shortcut);
    }
    try testing.expect(main.onCommand("clear") != null);
    try testing.expect(main.onCommand("unknown") == null);

    const live = try LiveApp.start();
    defer live.stop();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Work through pointer presses only — no widget ever gets keyboard
    // focus — then fire the shortcut like the platform would.
    var model = &live.app_state.model;
    model.press(.d9);
    model.press(.multiply);
    model.press(.d9);
    try testing.expectEqualStrings("9", live.displayText(arena));
    try live.harness.runtime.dispatchPlatformEvent(live.app, .{ .shortcut = .{
        .id = "clear",
        .key = "escape",
    } });
    try testing.expectEqualStrings("0", live.displayText(arena));
    try testing.expect(model.pending == null);
}

// ---------------------------------------------------------------- theming

test "system appearance drives the custom tokens live" {
    const live = try LiveApp.start();
    defer live.stop();
    const app_state = live.app_state;

    // Default: light system appearance = custom light palette.
    try testing.expectEqualDeep(theme.light_colors, main.tokensFromModel(&app_state.model).colors);

    // The OS flips to dark; the app follows it, live, into the runtime -
    // there is no in-window theme control by design.
    try live.harness.runtime.dispatchPlatformEvent(live.app, .{ .appearance_changed = .{ .color_scheme = .dark } });
    try testing.expectEqualDeep(theme.dark_colors, (try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label)).colors);

    // And back to light.
    try live.harness.runtime.dispatchPlatformEvent(live.app, .{ .appearance_changed = .{ .color_scheme = .light } });
    try testing.expectEqualDeep(theme.light_colors, (try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label)).colors);

    // The pending operator is the one accent: primary keys at rest are
    // the inverted monochrome, selected fills with accent.
    const tokens = main.tokensFromModel(&app_state.model);
    try testing.expectEqualDeep(theme.light_colors.accent, tokens.controls.button_primary.active_background.?);

    // High contrast falls back to the framework palette (accessibility
    // beats brand) and restores the brand palette when it lifts.
    try live.harness.runtime.dispatchPlatformEvent(live.app, .{ .appearance_changed = .{ .color_scheme = .dark, .high_contrast = true } });
    try testing.expectEqualDeep(canvas.ColorTokens.highContrastDark(), (try live.harness.runtime.canvasWidgetDesignTokens(1, main.canvas_label)).colors);
}

// ----------------------------------------------------------------- markup

test "markup engine parity: the keypad builds identical trees" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};
    model.press(.d8);
    model.press(.multiply);

    inline for (.{
        .{ view_mod.keypad_markup, view_mod.CompiledKeypadView },
    }) |case| {
        var interpreter = try canvas.MarkupView(Model, Msg).init(arena, case[0]);
        var compiled_ui = Ui.init(arena);
        const compiled = try compiled_ui.finalize(case[1].build(&compiled_ui, &model));
        var interpreted_ui = Ui.init(arena);
        const interpreted = try interpreted_ui.finalize(try interpreter.build(&interpreted_ui, &model));

        var compiled_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
        defer compiled_ids.deinit(testing.allocator);
        var interpreted_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
        defer interpreted_ids.deinit(testing.allocator);
        try collectIds(compiled.root, &compiled_ids, testing.allocator);
        try collectIds(interpreted.root, &interpreted_ids, testing.allocator);
        try testing.expectEqualSlices(canvas.ObjectId, interpreted_ids.items, compiled_ids.items);
        try testing.expectEqual(interpreted.handlers.len, compiled.handlers.len);
    }
}

fn collectIds(widget: canvas.Widget, ids: *std.ArrayListUnmanaged(canvas.ObjectId), allocator: std.mem.Allocator) !void {
    try ids.append(allocator, widget.id);
    for (widget.children) |child| try collectIds(child, ids, allocator);
}

// ------------------------------------------------------------- precision

test "the keypad grid lays out to exact frames inside the fixed window" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var model = Model{};
    const tree = try buildTree(arena_state.allocator(), &model);
    var nodes: [512]canvas.WidgetLayoutNode = undefined;
    // Lay out with the THEME tokens, exactly like the running app: the
    // result line sits on the display typography rung the theme tunes
    // to the keypad column (36px), so the display block's height — and
    // therefore every key row's y — depends on them.
    const layout = try canvas.layoutWidgetTreeWithTokens(tree.root, geometry.RectF.init(0, 0, main.window_width, main.window_height), main.tokensFromModel(&model), &nodes);
    try testing.expect(layout.nodes.len > 0);
    try testing.expect(layout.nodes.len < 128); // tiny app, tiny tree

    const pad = view_mod.window_padding;
    const kw = view_mod.key_width;
    const gap = view_mod.key_gap;
    const columns = [_]f32{ pad, pad + kw + gap, pad + (kw + gap) * 2, pad + (kw + gap) * 3 };

    var buttons_seen: usize = 0;
    var rows_top: [5]f32 = @splat(0);
    var rows_seen: usize = 0;
    for (layout.nodes) |node| {
        if (node.widget.kind != .button) continue;
        buttons_seen += 1;

        // Every key is exactly 66x54 — except the double-width zero.
        const expected_width: f32 = if (std.mem.eql(u8, node.widget.text, "0")) view_mod.zero_width else kw;
        try testing.expectEqual(expected_width, node.frame.width);
        try testing.expectEqual(view_mod.key_height, node.frame.height);

        // Every key sits on one of the four column x positions.
        var on_column = false;
        for (columns) |x| {
            if (node.frame.x == x) on_column = true;
        }
        try testing.expect(on_column);

        // Nothing escapes the window (right edge and bottom edge).
        try testing.expect(node.frame.x + node.frame.width <= main.window_width - pad);
        try testing.expect(node.frame.y + node.frame.height <= main.window_height - pad + 0.5);

        // Track distinct row tops.
        var known_row = false;
        for (rows_top[0..rows_seen]) |top| {
            if (top == node.frame.y) known_row = true;
        }
        if (!known_row) {
            rows_top[rows_seen] = node.frame.y;
            rows_seen += 1;
        }
    }
    try testing.expectEqual(@as(usize, 19), buttons_seen);
    try testing.expectEqual(@as(usize, 5), rows_seen);

    // Rows are evenly spaced at key height + gap.
    std.mem.sort(f32, rows_top[0..rows_seen], {}, std.sort.asc(f32));
    for (rows_top[1..rows_seen], 0..) |top, index| {
        try testing.expectEqual(rows_top[index] + view_mod.key_height + gap, top);
    }

    // The display column spans exactly the keypad width, right-aligned
    // to the same edge.
    const field = findByKind(tree.root, .text_field).?;
    for (layout.nodes) |node| {
        if (node.widget.id != field.id) continue;
        try testing.expectEqual(pad, node.frame.x);
        try testing.expectEqual(view_mod.content_width, node.frame.width);
    }
}

test "layout audit sweep: nothing clips, overlaps, or escapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    // A live expression + result so the display block audits with real
    // content, not the empty boot state.
    var model = Model{};
    const h = PressHarness{ .arena = arena_state.allocator(), .model = &model };
    try h.presses(&.{ "1", "2", "8", "×", "9", "6", "=" });

    const tree = try buildTree(arena_state.allocator(), &model);
    // The window is fixed (precision keypad), so the sweep collapses to
    // one size; density variants and the pseudo-locale text expansion
    // still run against the machined geometry.
    try canvas.expectLayoutAuditSweepClean(testing.allocator, tree.root, .{
        .tokens = main.tokensFromModel(&model),
        .min_size = surface_size,
        .default_size = surface_size,
        .large_size = surface_size,
    });
}

test "a11y audit sweep: every interactive widget is named, reachable, and unambiguous" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    // The same live state the layout sweep audits: a real expression and
    // result, so dynamic labels are the ones assistive tech would hear.
    var model = Model{};
    const h = PressHarness{ .arena = arena_state.allocator(), .model = &model };
    try h.presses(&.{ "1", "2", "8", "×", "9", "6", "=" });

    const tree = try buildTree(arena_state.allocator(), &model);
    try canvas.expectA11yAuditSweepClean(testing.allocator, tree.root, .{
        .tokens = main.tokensFromModel(&model),
        .min_size = surface_size,
        .default_size = surface_size,
        .large_size = surface_size,
    });
}

// ------------------------------------------------------------- snapshots

test "automation snapshot names every key and mirrors the display" {
    const live = try LiveApp.start();
    defer live.stop();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var snapshot = live.harness.runtime.automationSnapshot("Calculator");
    const key_names = [_][]const u8{ "All clear", "Toggle sign", "Percent", "Divide", "Multiply", "Subtract", "Add", "Equals", "Zero", "Decimal point", "7", "8", "9", "4", "5", "6", "1", "2", "3" };
    for (key_names) |name| {
        try testing.expect(snapshotButton(snapshot, name) != null);
    }
    try testing.expect(snapshotWidget(snapshot, "textbox", "Expression") != null);

    // Click 7 × 6 = through the automation widget-click path and watch
    // the snapshot's result text follow.
    try clickSnapshotButton(live, &snapshot, "7");
    try clickSnapshotButton(live, &snapshot, "Multiply");
    try clickSnapshotButton(live, &snapshot, "6");
    try clickSnapshotButton(live, &snapshot, "Equals");
    try testing.expectEqualStrings("42", live.displayText(arena));
    // The result paragraph's semantic label IS the value, so the
    // snapshot names it "42" — assistive tech reads the result directly.
    snapshot = live.harness.runtime.automationSnapshot("Calculator");
    try testing.expect(snapshotWidget(snapshot, "text", "42") != null);
    // The memory line follows too.
    try testing.expect(snapshotWidget(snapshot, "text", "Last calculation") != null);
}

fn snapshotWidget(snapshot: native_sdk.automation.snapshot.Input, role: []const u8, name: []const u8) ?native_sdk.automation.snapshot.Widget {
    for (snapshot.widgets) |widget| {
        if (std.mem.eql(u8, widget.role, role) and std.mem.eql(u8, widget.name, name)) return widget;
    }
    return null;
}

fn snapshotButton(snapshot: native_sdk.automation.snapshot.Input, name: []const u8) ?native_sdk.automation.snapshot.Widget {
    return snapshotWidget(snapshot, "button", name);
}

fn clickSnapshotButton(live: LiveApp, snapshot: *native_sdk.automation.snapshot.Input, name: []const u8) !void {
    snapshot.* = live.harness.runtime.automationSnapshot("Calculator");
    const button = snapshotButton(snapshot.*, name) orelse return error.ButtonNotFound;
    var command_buffer: [96]u8 = undefined;
    const command = try std.fmt.bufPrint(&command_buffer, "widget-click {s} {d}", .{ main.canvas_label, button.id });
    try live.harness.runtime.dispatchAutomationCommand(live.app, command);
}

// Env-gated homepage screenshot renderer (skipped by default, never in
// CI): the docs-homepage showcase state — a finished calculation so the
// display, memory line, and keypad all carry real content — once per
// color scheme, same state in both. PNGs land in
// /tmp/homepage-shots/calculator-{light,dark}-artifacts/. To use:
//
//   HOMEPAGE_SHOTS=1 zig build test
test "render homepage screenshots (env-gated)" {
    if (!envGateSet("HOMEPAGE_SHOTS")) return error.SkipZigTest;
    const io = testing.io;

    const live = try LiveApp.start();
    defer live.stop();

    // 128 × 96 = 12,288 through the real dispatch path, then an operator
    // pending so the shot is genuinely mid-calculation: the memory line
    // holds the finished multiply, the expression line shows the pending
    // "12288 +", and the + key wears its live highlight.
    for ([_]Msg{ .d1, .d2, .d8, .multiply, .d9, .d6, .equals, .add }) |msg| {
        try live.app_state.dispatch(&live.harness.runtime, 1, msg);
    }

    // The app follows the system appearance: drive the platform event
    // once per scheme, the same channel the OS uses.
    try live.harness.runtime.dispatchPlatformEvent(live.app, .{ .appearance_changed = .{ .color_scheme = .light } });
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/homepage-shots/calculator-light-artifacts", "Calculator");
    try live.harness.runtime.dispatchAutomationCommand(live.app, "screenshot calc-canvas 2");

    try live.harness.runtime.dispatchPlatformEvent(live.app, .{ .appearance_changed = .{ .color_scheme = .dark } });
    live.harness.runtime.options.automation = native_sdk.automation.Server.init(io, "/tmp/homepage-shots/calculator-dark-artifacts", "Calculator");
    try live.harness.runtime.dispatchAutomationCommand(live.app, "screenshot calc-canvas 2");
}

/// Env-gated dump switch. `std.c.getenv` needs libc, which this test
/// build only links on targets whose platform layer pulls it in; when
/// libc is absent the gate reads as unset and the gated test skips.
fn envGateSet(name: [*:0]const u8) bool {
    if (comptime !@import("builtin").link_libc) return false;
    return std.c.getenv(name) != null;
}
