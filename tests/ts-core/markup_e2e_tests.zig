//! End-to-end: a `.native` MARKUP VIEW over a genuinely transpiled core
//! (tests/ts-core/markup_fixture.ts + markup_view.native), through the
//! first-class `TsUiApp(core)` adapter — the committed TS model is the
//! app model and markup binds its emitted fields directly: a record
//! array through `for each` + `key`, an optional scalar through `<if>`,
//! a string-literal-union filter as an enum binding, bytes text, and
//! camelCase TS fields bound by their own names — the emitted struct keeps the TS spellings.
//!
//! On top of the view, the round's platform guarantees run through the
//! transpiled app unchanged:
//!   - automation: headless widget verbs, the a11y snapshot, and
//!     published screenshot artifacts (byte-identical on an unchanged
//!     scene);
//!   - record/replay: a session of journaled USER INPUT (menu commands
//!     and raw pointer events on markup buttons) plus a `Cmd.now`
//!     effect records byte-identically twice, replays with matching
//!     state fingerprints, verified checkpoints, and verified PIXEL
//!     screenshot marks, and never calls a host;
//!   - process contract: two different transpiled cores run live side
//!     by side (each staged core owns its rt kernel instance) — the
//!     one-live-app-per-core-module contract, pinned from both sides.

const std = @import("std");
const builtin = @import("builtin");
const native_sdk = @import("native_sdk");
const board = @import("ts_markup_fixture");
const status_core = @import("ts_core_fixture");

const runtime_ns = native_sdk.runtime;
const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const automation = native_sdk.automation;

const Adapter = native_sdk.TsUiApp(board);
const App = Adapter.App;
const Bridge = Adapter.Host;

const board_markup = @embedFile("markup_view.native");
const CompiledBoardView = canvas.CompiledMarkupView(board.Model, board.Msg, board_markup);

const canvas_label = "ts-markup-canvas";

const board_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const board_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "TS Board",
    .width = 480,
    .height = 360,
    .views = &board_views,
}};
const board_scene: native_sdk.ShellConfig = .{ .windows = &board_windows };

fn boardCommand(name: []const u8) ?board.Msg {
    if (std.mem.eql(u8, name, "board.add")) return .add;
    if (std.mem.eql(u8, name, "board.cycle")) return .cycle;
    if (std.mem.eql(u8, name, "board.clear")) return .clear;
    if (std.mem.eql(u8, name, "board.stamp")) return .stamp;
    return null;
}

fn boardOptions() App.Options {
    return .{
        .name = "ts-markup-e2e",
        .scene = board_scene,
        .canvas_label = canvas_label,
        // The comptime-compiled engine over the EMITTED model — markup
        // is the whole view tier of this app.
        .view = CompiledBoardView.build,
        .on_command = boardCommand,
    };
}

const Harness = struct {
    harness: *native_sdk.TestHarness(),
    app_state: *App,
    app: native_sdk.App,
    clock: native_sdk.TestClock,

    fn create() !*Harness {
        return createConfigured(.{});
    }

    fn createRecorded(recorder: ?*runtime_ns.SessionRecorder) !*Harness {
        return createConfigured(.{ .recorder = recorder });
    }

    const CreateConfig = struct {
        /// Attaches BEFORE start so the journal holds the app_start and
        /// installing-frame events.
        recorder: ?*runtime_ns.SessionRecorder = null,
        /// Adapter-owned knobs (boot images, env overrides).
        core: Adapter.CoreOptions = .{},
        /// The chrome geometry the null platform reports (delivered
        /// through the core's chromeMsg channel before the first view
        /// build).
        chrome: native_sdk.WindowChrome = .{},
    };

    fn createConfigured(config: CreateConfig) !*Harness {
        const self = try std.testing.allocator.create(Harness);
        errdefer std.testing.allocator.destroy(self);
        self.clock = .{};
        self.clock.setWallMs(77_000);
        self.harness = try native_sdk.TestHarness().create(std.testing.allocator, .{
            .size = geometry.SizeF.init(480, 360),
        });
        errdefer self.harness.destroy(std.testing.allocator);
        self.harness.null_platform.gpu_surfaces = true;
        self.harness.null_platform.image_decode = true;
        self.harness.null_platform.window_chrome = config.chrome;
        self.harness.runtime.options.session_recorder = config.recorder;
        self.app_state = try std.testing.allocator.create(App);
        errdefer std.testing.allocator.destroy(self.app_state);
        self.app_state.* = Adapter.init(std.heap.page_allocator, config.core, boardOptions());
        self.app_state.effects.clock = self.clock.clock();
        self.app = self.app_state.app();
        try self.harness.start(self.app);
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(480, 360),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
        } });
        try std.testing.expect(self.app_state.installed);
        return self;
    }

    fn destroy(self: *Harness) void {
        self.app_state.deinit();
        std.testing.allocator.destroy(self.app_state);
        self.harness.destroy(std.testing.allocator);
        std.testing.allocator.destroy(self);
    }

    fn menu(self: *Harness, name: []const u8) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .menu_command = .{ .name = name, .window_id = 1 } });
    }

    /// The rendered widget id of the first `kind` widget whose text
    /// matches — markup trees carry deterministic structural ids.
    fn findId(self: *Harness, kind: canvas.WidgetKind, text: []const u8) ?canvas.ObjectId {
        return findKindText(self.app_state.tree.?.root, kind, text);
    }

    fn hasText(self: *Harness, text: []const u8) bool {
        return findTextIn(self.app_state.tree.?.root, text);
    }

    /// Click a rendered widget through the AUTOMATION verb — the same
    /// headless path `native automate` drives.
    fn click(self: *Harness, id: canvas.ObjectId) !void {
        var buffer: [96]u8 = undefined;
        const command = try std.fmt.bufPrint(&buffer, "widget-click {s} {d}", .{ canvas_label, id });
        try self.harness.runtime.dispatchAutomationCommand(self.app, command);
    }

    fn viewIndex(self: *Harness) !usize {
        for (self.harness.runtime.views[0..self.harness.runtime.view_count], 0..) |view, index| {
            if (std.mem.eql(u8, view.label, canvas_label)) return index;
        }
        return error.ViewNotFound;
    }

    /// The rendered center of a widget in view coordinates — for RAW
    /// pointer events with test-fixed timestamps (the journaled-input
    /// path record/replay pins; the automation click stamps real-clock
    /// timestamps, which byte-identical recordings cannot carry).
    fn aim(self: *Harness, id: canvas.ObjectId) !geometry.PointF {
        const layout = self.harness.runtime.views[try self.viewIndex()].widgetLayoutTree();
        const node = layout.findById(id) orelse return error.WidgetNotFound;
        return node.frame.normalized().center();
    }

    fn pointerMove(self: *Harness, point: geometry.PointF, timestamp_ns: u64) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = canvas_label,
            .kind = .pointer_move,
            .timestamp_ns = timestamp_ns,
            .x = point.x,
            .y = point.y,
        } });
    }

    /// Present one frame on an explicit RECORDED timestamp — the clock
    /// the tooltip hover-intent delay (and every tween) steps on.
    fn frameAt(self: *Harness, frame_index: u64, timestamp_ns: u64) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(480, 360),
            .scale_factor = 1,
            .frame_index = frame_index,
            .timestamp_ns = timestamp_ns,
        } });
    }

    fn pointerClick(self: *Harness, point: geometry.PointF, timestamp_ns: u64) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = canvas_label,
            .kind = .pointer_down,
            .timestamp_ns = timestamp_ns,
            .x = point.x,
            .y = point.y,
            .button = 0,
        } });
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_input = .{
            .window_id = 1,
            .label = canvas_label,
            .kind = .pointer_up,
            .timestamp_ns = timestamp_ns + 1_000_000,
            .x = point.x,
            .y = point.y,
            .button = 0,
        } });
    }
};

fn findKindText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.ObjectId {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget.id;
    for (widget.children) |child| {
        if (findKindText(child, kind, text)) |id| return id;
    }
    return null;
}

fn findTextIn(widget: canvas.Widget, text: []const u8) bool {
    if (std.mem.indexOf(u8, widget.text, text) != null) return true;
    for (widget.children) |child| {
        if (findTextIn(child, text)) return true;
    }
    return false;
}

// ------------------------------------------------------- markup binding

test "markup binds the transpiled model: lists, optionals, enums, and the TS field names" {
    const h = try Harness.create();
    defer h.destroy();

    // The boot model rendered through markup: bytes text, the enum
    // filter as its tag name, and the camelCase `nextId` bound as
    // `{nextId}` — markup binds the model's field names exactly as the
    // TS source wrote them.
    try std.testing.expect(h.hasText("ready filter all next 1"));
    try std.testing.expect(h.hasText("done 0"));
    try std.testing.expect(h.hasText("no tasks"));
    try std.testing.expect(!h.hasText("picked"));

    // Two adds: the `for each` renders the record-array items with
    // their fields, keyed by id; the else branch disappears.
    try h.click(h.findId(.button, "Add").?);
    try h.click(h.findId(.button, "Add").?);
    try std.testing.expectEqual(@as(usize, 2), Bridge.model().tasks.len);
    try std.testing.expectEqual(@as(usize, 2), h.app_state.model.tasks.len);
    try std.testing.expect(h.hasText("beta #1"));
    try std.testing.expect(h.hasText("gamma #2"));
    try std.testing.expect(h.hasText("ready filter all next 3"));
    try std.testing.expect(!h.hasText("no tasks"));

    // A payload built from the pointer item flips exactly that row: the
    // done badge appears and the derived count re-renders.
    try h.click(h.findId(.button, "Flip").?);
    try std.testing.expect(Bridge.model().tasks[0].done);
    try std.testing.expect(!Bridge.model().tasks[1].done);
    try std.testing.expect(h.hasText("done 1"));
    try std.testing.expect(findTextIn(h.app_state.tree.?.root, "done") and h.findId(.badge, "done") != null);

    // The optional gate opens on pick (f64 payload coerced from the
    // integer item binding) and the enum cycles through its members.
    try h.click(h.findId(.button, "Pick").?);
    try std.testing.expect(h.hasText("picked 1"));
    try h.click(h.findId(.button, "Cycle").?);
    try std.testing.expect(h.hasText("filter open"));

    // Clear returns to the empty state: the else branch and the new
    // banner bytes.
    try h.click(h.findId(.button, "Clear").?);
    try std.testing.expect(h.hasText("cleared filter open next 3"));
    try std.testing.expect(h.hasText("no tasks"));
    try std.testing.expect(!h.hasText("picked"));
}

test "the runtime markup interpreter builds the emitted model exactly like the compiled engine" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const first = board.Task{ .id = 1, .title = "beta", .done = true };
    const second = board.Task{ .id = 2, .title = "gamma", .done = false };
    const tasks = [_]*const board.Task{ &first, &second };
    const model = board.Model{
        .filter = .open,
        .nextId = 3,
        .doneCount = 1,
        .banner = "ready",
        .selected = 2,
        .tasks = &tasks,
        .stampMs = -1,
        .draft = "",
        .canvasWidth = 0,
        .zoom = 1,
        .dark = false,
        .chromeTop = 0,
    };

    const BoardUi = canvas.Ui(board.Msg);
    var interpreter_view = try canvas.MarkupView(board.Model, board.Msg).init(arena, board_markup);
    var interpreter_ui = BoardUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try interpreter_view.build(&interpreter_ui, &model));
    var compiled_ui = BoardUi.init(arena);
    const compiled = try compiled_ui.finalize(CompiledBoardView.build(&compiled_ui, &model));

    var interpreted_texts: std.ArrayListUnmanaged(u8) = .empty;
    defer interpreted_texts.deinit(std.testing.allocator);
    var compiled_texts: std.ArrayListUnmanaged(u8) = .empty;
    defer compiled_texts.deinit(std.testing.allocator);
    try collectTexts(interpreted.root, &interpreted_texts, std.testing.allocator);
    try collectTexts(compiled.root, &compiled_texts, std.testing.allocator);
    try std.testing.expectEqualStrings(interpreted_texts.items, compiled_texts.items);
    try std.testing.expect(std.mem.indexOf(u8, compiled_texts.items, "ready filter open next 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled_texts.items, "picked 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled_texts.items, "beta #1") != null);
}

fn collectTexts(widget: canvas.Widget, out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    try out.appendSlice(allocator, widget.text);
    try out.append(allocator, '\n');
    for (widget.children) |child| {
        try collectTexts(child, out, allocator);
    }
}

test "markup text input reaches the transpiled core and re-renders the view" {
    const h = try Harness.create();
    defer h.destroy();

    // The declared-union translation end to end: the markup text field's
    // on-input arm carries the CORE-DECLARED TextInputEvent mirror; the
    // runtime keyboard path builds the Msg through the translated
    // constructor, the core's update splices its committed draft bytes,
    // and the rebuilt view renders the new model.
    try std.testing.expect(h.hasText("draft []"));
    const field = h.findId(.text_field, "").?;
    try h.click(field); // focus the field (the automation click path)

    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .text_input,
        .text = "hi",
    } });
    try std.testing.expectEqualStrings("hi", Bridge.model().draft);
    try std.testing.expect(h.hasText("draft [hi]"));

    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .text_input,
        .text = " there",
    } });
    try std.testing.expect(h.hasText("draft [hi there]"));

    // Backspace routes the delete_backward verb arm; the core drops one
    // byte from its committed draft.
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .key_down,
        .key = "backspace",
    } });
    try std.testing.expectEqualStrings("hi ther", Bridge.model().draft);
    try std.testing.expect(h.hasText("draft [hi ther]"));

    // Caret-only events translate (move_caret arm) without touching the
    // model - the fixture's reducer ignores them by design.
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .key_down,
        .key = "arrowleft",
    } });
    try std.testing.expectEqualStrings("hi ther", Bridge.model().draft);

    // And the field itself renders the committed draft (value binding).
    try std.testing.expect(h.findId(.text_field, "hi ther") != null);
}

test "automation set_text drives a transpiled-core text field (select-all sentinel translates)" {
    const h = try Harness.create();
    defer h.destroy();

    // Seed the field through real typing so the replace verb's select-all
    // has a selection to make.
    const field = h.findId(.text_field, "").?;
    try h.click(field);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .text_input,
        .text = "hi",
    } });
    try std.testing.expectEqualStrings("hi", Bridge.model().draft);

    // The automation replace verb routes through the REAL input path:
    // focus, cmd/ctrl+A, then the replacement text. Select-all synthesizes
    // `set_selection` carrying the `focus = maxInt(usize)` "to the end"
    // sentinel, and the declared-union translation must SATURATE it into
    // the core's i64 field class — @intCast here panicked "integer does
    // not fit in destination type" on every transpiled-core text field
    // (the live-GUI smoke's soundboard-ts search crash).
    var buffer: [96]u8 = undefined;
    const command = try std.fmt.bufPrint(&buffer, "widget-action {s} {d} set-text yo", .{ canvas_label, field });
    try h.harness.runtime.dispatchAutomationCommand(h.app, command);

    // The mirror heard the select-all (the fixture's deliberately
    // append-only reducer ignores selection verbs) and then the
    // replacement text — the whole sequence delivered, nothing panicked.
    try std.testing.expectEqualStrings("hiyo", Bridge.model().draft);
}

// ------------------------------------------------- host-event channels

test "the wiring channels drive the core: frame, key, appearance, and chrome" {
    const h = try Harness.createConfigured(.{
        .chrome = .{
            .insets = .{ .top = 52, .left = 78 },
            .buttons = geometry.RectF.init(12, 14, 54, 16),
        },
    });
    defer h.destroy();

    // frameMsg: presented frames dispatch through the core's frame arm
    // (the installing frame is excluded by the UiApp contract, so the
    // first PRESENTED frame corrects the model's seed width — the
    // album-grid derivation shape) and a live resize re-dispatches; the
    // core returns null for a same-width frame, so the channel starves
    // when nothing changes (the idle law).
    try std.testing.expectEqual(@as(i64, 0), Bridge.model().canvasWidth);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(480, 360),
        .scale_factor = 1,
        .frame_index = 2,
        .timestamp_ns = 2_000_000,
    } });
    try std.testing.expectEqual(@as(i64, 480), Bridge.model().canvasWidth);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_frame = .{
        .label = canvas_label,
        .size = geometry.SizeF.init(512, 360),
        .scale_factor = 1,
        .frame_index = 3,
        .timestamp_ns = 3_000_000,
    } });
    try std.testing.expectEqual(@as(i64, 512), Bridge.model().canvasWidth);

    // chromeMsg: the hidden-titlebar geometry landed BEFORE the first
    // view build, built by field name into the declared record.
    try std.testing.expectEqual(@as(f64, 52), Bridge.model().chromeTop);

    // appearanceMsg: the system flip lands as an ordinary Msg; the
    // declared light/dark enum matches by member name.
    try std.testing.expect(!Bridge.model().dark);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .appearance_changed = .{ .color_scheme = .dark } });
    try std.testing.expect(Bridge.model().dark);

    // keyMsg: the app-level key FALLBACK — the key name arrives
    // lowercased, so the core's `key.key === "space"` matches the
    // platform's "Space" spelling, and the modifier booleans ride along.
    try std.testing.expect(Bridge.model().filter == .all);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .key_down,
        .key = "Space",
    } });
    try std.testing.expect(Bridge.model().filter == .open);
    try std.testing.expect(h.hasText("filter open"));

    // pinchMsg: the trackpad pinch channel — the phase alias matches by
    // member name, begin/end gate to null in the core, and each change
    // compounds the zoom by (1 + delta): two +25% deltas land on the
    // PRODUCT 1.5625, never a sum's 1.45.
    try std.testing.expectEqual(@as(f64, 1), Bridge.model().zoom);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pinch_begin,
        .x = 120,
        .y = 80,
    } });
    try std.testing.expectEqual(@as(f64, 1), Bridge.model().zoom);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pinch_change,
        .x = 120,
        .y = 80,
        .scale = 0.25,
    } });
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pinch_change,
        .x = 120,
        .y = 80,
        .scale = 0.25,
    } });
    try h.harness.runtime.dispatchPlatformEvent(h.app, .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = canvas_label,
        .kind = .pinch_end,
        .x = 120,
        .y = 80,
    } });
    try std.testing.expectEqual(@as(f64, 1.5625), Bridge.model().zoom);

    // The automation pinch verb dispatches the same real events into the
    // transpiled core: one gesture whose change carries scale - 1.
    var pinch_buffer: [96]u8 = undefined;
    const pinch = try std.fmt.bufPrint(&pinch_buffer, "widget-pinch {s} 2", .{canvas_label});
    try h.harness.runtime.dispatchAutomationCommand(h.app, pinch);
    try std.testing.expectEqual(@as(f64, 3.125), Bridge.model().zoom);
}

test "boot images register and launch env overrides dispatch at install" {
    // A tiny PNG through the engine's own encoder — the register path
    // the wiring's app.zon assets ride, no side door into the registry.
    const rgba = [_]u8{ 255, 0, 0, 255 } ** 4;
    var encoded: [256]u8 = undefined;
    var png_writer = std.Io.Writer.fixed(&encoded);
    try canvas.png.writeRgba8(&png_writer, 2, 2, &rgba);

    const boot_images = [_]Adapter.BootImage{.{ .id = 7, .bytes = png_writer.buffered() }};
    const env_values = [_]Adapter.EnvValue{.{ .msg = "banner_set", .value = "from the launch env" }};
    const h = try Harness.createConfigured(.{ .core = .{
        .boot_images = &boot_images,
        .env_values = &env_values,
    } });
    defer h.destroy();

    // The image registered on the installing frame (init_fx semantics —
    // before the first view build).
    try std.testing.expectEqual(@as(usize, 1), h.harness.runtime.canvas_image_count);

    // The env override dispatched through its one-bytes-field arm right
    // after the boot command: the committed model and the rendered view
    // both carry it before any user input.
    try std.testing.expectEqualStrings("from the launch env", Bridge.model().banner);
    try std.testing.expect(h.hasText("from the launch env"));
}

// ----------------------------------------------------------- automation

test "the automation surface drives the transpiled markup app headlessly" {
    const directory = ".zig-cache/tmp/ts-markup-automation";
    std.Io.Dir.cwd().deleteTree(std.testing.io, directory) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, directory) catch {};

    const h = try Harness.create();
    defer h.destroy();
    h.harness.runtime.options.automation = automation.Server.init(std.testing.io, directory, "TS Board");

    // The a11y snapshot names the markup-rendered controls.
    const snapshot = h.harness.runtime.automationSnapshot("TS Board");
    var a11y_buffer: [8192]u8 = undefined;
    var a11y_writer = std.Io.Writer.fixed(&a11y_buffer);
    try automation.snapshot.writeA11yText(snapshot, &a11y_writer);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "role=button name=\"Add\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, a11y_writer.buffered(), "no tasks") != null);

    // Menu commands and widget verbs drive the core; the refreshed
    // snapshot reports the new state.
    try h.menu("board.add");
    try h.click(h.findId(.button, "Flip").?);
    try std.testing.expect(Bridge.model().tasks[0].done);
    const after = h.harness.runtime.automationSnapshot("TS Board");
    var after_buffer: [8192]u8 = undefined;
    var after_writer = std.Io.Writer.fixed(&after_buffer);
    try automation.snapshot.writeA11yText(after, &after_writer);
    try std.testing.expect(std.mem.indexOf(u8, after_writer.buffered(), "beta #1") != null);

    // The screenshot verb publishes a parseable PNG artifact, and an
    // unchanged scene captures byte-identically — the pixel-stability
    // pin for the deterministic reference renderer over a TS core.
    try h.harness.runtime.dispatchAutomationCommand(h.app, "screenshot " ++ canvas_label);
    const artifact_path = directory ++ "/screenshot-" ++ canvas_label ++ ".png";
    const first = try readAutomationFile(std.testing.allocator, std.testing.io, artifact_path);
    defer std.testing.allocator.free(first);
    try h.harness.runtime.dispatchAutomationCommand(h.app, "screenshot " ++ canvas_label);
    const second = try readAutomationFile(std.testing.allocator, std.testing.io, artifact_path);
    defer std.testing.allocator.free(second);
    try std.testing.expect(first.len > 0);
    try std.testing.expectEqualSlices(u8, first, second);

    // A model change changes the pixels.
    try h.menu("board.clear");
    try h.harness.runtime.dispatchAutomationCommand(h.app, "screenshot " ++ canvas_label);
    const changed = try readAutomationFile(std.testing.allocator, std.testing.io, artifact_path);
    defer std.testing.allocator.free(changed);
    try std.testing.expect(!std.mem.eql(u8, first, changed));
}

fn readAutomationFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(8 * 1024 * 1024));
}

// -------------------------------------------------------- record / replay

const JournalBuffer = struct {
    bytes: [256 * 1024]u8 = undefined,
    len: usize = 0,

    fn sink(self: *JournalBuffer) runtime_ns.SessionRecorderSink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *JournalBuffer = @ptrCast(@alignCast(context));
        if (self.len + bytes.len > self.bytes.len) return error.NoSpaceLeft;
        @memcpy(self.bytes[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn journalBytes(self: *const JournalBuffer) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// A value snapshot of the board model (committed slices live in the
/// core's heap — copy what outlives a session).
const BoardSnapshot = struct {
    task_count: usize,
    first_done: bool,
    doneCount: i64,
    nextId: i64,
    stampMs: f64,
    banner: [16]u8,
    banner_len: usize,

    fn take() BoardSnapshot {
        const m = Bridge.model();
        var snapshot: BoardSnapshot = .{
            .task_count = m.tasks.len,
            .first_done = m.tasks.len > 0 and m.tasks[0].done,
            .doneCount = m.doneCount,
            .nextId = m.nextId,
            .stampMs = m.stampMs,
            .banner = [_]u8{0} ** 16,
            .banner_len = @min(m.banner.len, 16),
        };
        @memcpy(snapshot.banner[0..snapshot.banner_len], m.banner[0..snapshot.banner_len]);
        return snapshot;
    }
};

/// Record the reference markup session: user input as journaled menu
/// commands AND raw pointer events on a markup button (test-fixed
/// timestamps, so two recordings are byte-identical), one `Cmd.now`
/// effect through the journaled clock, per-frame fingerprint
/// checkpoints, and one PIXEL screenshot mark through the automation
/// verb.
fn recordBoardSession(buffer: *JournalBuffer, screenshot_dir: []const u8) !struct {
    snapshot: BoardSnapshot,
    fingerprint: u64,
} {
    const recorder = try std.heap.page_allocator.create(runtime_ns.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = runtime_ns.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "ts-markup-e2e", .window_width = 480, .window_height = 360 });

    const h = try Harness.createRecorded(recorder);
    defer h.destroy();
    h.harness.runtime.options.automation = automation.Server.init(std.testing.io, screenshot_dir, "TS Board");

    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);

    // Journaled user input: menu commands add two tasks.
    try h.menu("board.add");
    try h.menu("board.add");
    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);

    // Journaled user input: a RAW pointer click on the first row's Flip
    // button (fixed timestamps; the aim point derives from the
    // deterministic layout, so both recordings compute the same one).
    const flip = h.findId(.button, "Flip").?;
    try h.pointerClick(try h.aim(flip), 5_000_000);
    try std.testing.expect(Bridge.model().tasks[0].done);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);

    // One effect: Cmd.now reads the journaled clock synchronously.
    try h.menu("board.stamp");
    try std.testing.expectEqual(@as(f64, 77_000), Bridge.model().stampMs);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);

    // A screenshot taken during a recorded session marks a pixel
    // checkpoint the replay must re-render to the same hash.
    try h.harness.runtime.dispatchAutomationCommand(h.app, "screenshot " ++ canvas_label);
    try h.harness.runtime.dispatchPlatformEvent(h.app, .frame_requested);

    recorder.finish();
    try std.testing.expect(!recorder.failed);
    return .{ .snapshot = BoardSnapshot.take(), .fingerprint = h.harness.runtime.sessionStateFingerprint() };
}

test "a recorded markup session replays byte-identically with verified fingerprints and pixel marks" {
    const directory = ".zig-cache/tmp/ts-markup-replay";
    std.Io.Dir.cwd().deleteTree(std.testing.io, directory) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, directory) catch {};

    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    const recorded = try recordBoardSession(buffer, directory);
    try std.testing.expectEqual(@as(usize, 2), recorded.snapshot.task_count);
    try std.testing.expect(recorded.snapshot.first_done);
    try std.testing.expectEqual(@as(i64, 1), recorded.snapshot.doneCount);
    try std.testing.expectEqual(@as(f64, 77_000), recorded.snapshot.stampMs);

    // Determinism pin: the same driven session records byte-identical
    // journal bytes — pointer aim points, checkpoint fingerprints, and
    // the screenshot mark's pixel hash included.
    const second = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(second);
    second.len = 0;
    const recorded_again = try recordBoardSession(second, directory);
    try std.testing.expectEqualDeep(recorded.snapshot, recorded_again.snapshot);
    try std.testing.expectEqualSlices(u8, buffer.journalBytes(), second.journalBytes());

    // Replay into a fresh app with NO automation server and NO host
    // binding: events (pointer clicks included) re-dispatch from the
    // journal, the clock read feeds from its record, checkpoints and
    // the pixel screenshot mark verify against the re-rendered frames.
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{
        .size = geometry.SizeF.init(480, 360),
    });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = Adapter.init(std.heap.page_allocator, .{}, boardOptions());
    defer app_state.deinit();

    const report = try runtime_ns.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
    });
    try std.testing.expect(report.ok());
    try std.testing.expect(report.events_replayed > 0);
    try std.testing.expect(report.checkpoints_verified > 0);
    try std.testing.expectEqual(@as(u64, 1), report.screenshots_verified);
    // The one journaled effect result is the Cmd.now clock read.
    try std.testing.expectEqual(@as(u64, 1), report.effects_fed);
    try std.testing.expectEqualDeep(recorded.snapshot, BoardSnapshot.take());
    try std.testing.expectEqual(recorded.fingerprint, harness.runtime.sessionStateFingerprint());
}

/// Record the tooltip hover-dwell session: raw pointer hovers with
/// test-fixed timestamps arm the Add button's anchored tooltip
/// (tooltip-delay="200" in the fixture markup), explicit frame events
/// on the recorded clock carry the dwell past the deadline (show),
/// and a final hover off the trigger hides it — every transition on
/// journaled time, so two recordings are byte-identical.
fn recordTooltipDwellSession(buffer: *JournalBuffer) !u64 {
    const recorder = try std.heap.page_allocator.create(runtime_ns.SessionRecorder);
    defer std.heap.page_allocator.destroy(recorder);
    recorder.* = runtime_ns.SessionRecorder.init(buffer.sink());
    recorder.begin(.{ .platform_name = "test", .app_name = "ts-markup-e2e", .window_width = 480, .window_height = 360 });

    const h = try Harness.createRecorded(recorder);
    defer h.destroy();

    const add_button = h.findId(.button, "Add").?;
    const tooltip_id = h.findId(.tooltip, "Add a task").?;
    const view = &h.harness.runtime.views[try h.viewIndex()];

    // The anchored tooltip adopts hidden; hovering the trigger arms the
    // 200ms declared delay without painting anything.
    try h.pointerMove(try h.aim(add_button), 10_000_000);
    try std.testing.expectEqual(tooltip_id, view.canvas_tooltip_armed_id);
    try h.frameAt(2, 60_000_000);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), view.canvas_tooltip_shown_id);

    // The first frame at/past the deadline (10ms + 200ms) shows the
    // tooltip — a deterministic frame on the recorded clock.
    try h.frameAt(3, 215_000_000);
    try std.testing.expectEqual(tooltip_id, view.canvas_tooltip_shown_id);

    // Leaving the trigger hides it; the hide frame is recorded too.
    try h.pointerMove(.{ .x = 4, .y = 350 }, 260_000_000);
    try std.testing.expectEqual(@as(canvas.ObjectId, 0), view.canvas_tooltip_shown_id);
    try h.frameAt(4, 280_000_000);

    recorder.finish();
    try std.testing.expect(!recorder.failed);
    return h.harness.runtime.sessionStateFingerprint();
}

test "a recorded tooltip hover dwell replays its show and hide frames byte-identically" {
    const buffer = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(buffer);
    buffer.len = 0;
    const fingerprint = try recordTooltipDwellSession(buffer);

    // Determinism pin: the same driven dwell records byte-identical
    // journal bytes — hover timestamps, the show frame, the hide frame,
    // and every per-frame fingerprint checkpoint included.
    const second = try std.heap.page_allocator.create(JournalBuffer);
    defer std.heap.page_allocator.destroy(second);
    second.len = 0;
    const fingerprint_again = try recordTooltipDwellSession(second);
    try std.testing.expectEqual(fingerprint, fingerprint_again);
    try std.testing.expectEqualSlices(u8, buffer.journalBytes(), second.journalBytes());

    // Replay into a fresh app: the journaled hovers re-arm the intent
    // machine, the journaled frame timestamps re-fire the delay, and the
    // per-frame fingerprint checkpoints verify the tooltip's show and
    // hide frames — on the recorded clock, never a wall clock.
    const harness = try native_sdk.TestHarness().create(std.testing.allocator, .{
        .size = geometry.SizeF.init(480, 360),
    });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const app_state = try std.testing.allocator.create(App);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = Adapter.init(std.heap.page_allocator, .{}, boardOptions());
    defer app_state.deinit();

    const report = try runtime_ns.replaySession(&harness.runtime, app_state.app(), buffer.journalBytes(), .{
        .verify = true,
        .require_same_platform = false,
    });
    try std.testing.expect(report.ok());
    try std.testing.expect(report.events_replayed > 0);
    try std.testing.expect(report.checkpoints_verified > 0);
    try std.testing.expectEqual(fingerprint, harness.runtime.sessionStateFingerprint());
}

// ------------------------------------------------- two live cores

/// A minimal host stub for the status core's boot request (the markup
/// core performs no host calls).
const CoexistStub = struct {
    var request_count: usize = 0;
    var context: u8 = 0;

    fn send(ctx: *anyopaque, name: []const u8, payload: []const u8) void {
        _ = ctx;
        _ = name;
        _ = payload;
    }

    fn request(ctx: *anyopaque, name: []const u8, key: u64, payload: []const u8) void {
        _ = ctx;
        _ = name;
        _ = key;
        _ = payload;
        request_count += 1;
    }

    fn cancelNotice(ctx: *anyopaque, key: u64) void {
        _ = ctx;
        _ = key;
    }

    fn binding() native_sdk.HostCallBinding {
        return .{ .context = @ptrCast(&context), .send_fn = send, .request_fn = request, .cancel_fn = cancelNotice };
    }
};

const StatusAdapter = native_sdk.TsUiApp(status_core);
const StatusApp = StatusAdapter.App;

const status_canvas_label = "ts-core-canvas";
const status_views = [_]native_sdk.ShellView{
    .{ .label = status_canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const status_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "TS Core",
    .width = 400,
    .height = 300,
    .views = &status_views,
}};
const status_scene: native_sdk.ShellConfig = .{ .windows = &status_windows };

fn statusView(ui: *StatusApp.Ui, model: *const status_core.Model) StatusApp.Ui.Node {
    return ui.column(.{ .gap = 4, .padding = 8 }, .{
        ui.text(.{}, ui.fmt("ticks {d}", .{model.ticks})),
    });
}

fn statusCommand(name: []const u8) ?status_core.Msg {
    if (std.mem.eql(u8, name, "core.stamp")) return .stamp;
    if (std.mem.eql(u8, name, "core.toggle")) return .toggle;
    return null;
}

test "two live transpiled cores coexist: each staged core owns its kernel and committed root" {
    // The markup board app...
    const h = try Harness.create();
    defer h.destroy();

    // ...and the status-poller app from the OTHER emitted core, live in
    // the same process at the same time.
    CoexistStub.request_count = 0;
    var status_clock: native_sdk.TestClock = .{};
    status_clock.setWallMs(90_000);
    const status_harness = try native_sdk.TestHarness().create(std.testing.allocator, .{
        .size = geometry.SizeF.init(400, 300),
    });
    defer status_harness.destroy(std.testing.allocator);
    status_harness.null_platform.gpu_surfaces = true;
    const status_state = try std.testing.allocator.create(StatusApp);
    defer std.testing.allocator.destroy(status_state);
    status_state.* = StatusAdapter.init(std.heap.page_allocator, .{}, .{
        .name = "ts-core-coexist",
        .scene = status_scene,
        .canvas_label = status_canvas_label,
        .view = statusView,
        .on_command = statusCommand,
    });
    defer status_state.deinit();
    status_state.effects.bindHostCalls(CoexistStub.binding());
    status_state.effects.clock = status_clock.clock();
    const status_app = status_state.app();
    try status_harness.start(status_app);
    try status_harness.runtime.dispatchPlatformEvent(status_app, .{ .gpu_surface_frame = .{
        .label = status_canvas_label,
        .size = geometry.SizeF.init(400, 300),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    try std.testing.expect(status_state.installed);
    try std.testing.expectEqual(@as(usize, 1), CoexistStub.request_count);

    // Interleaved dispatches: each core's committed model progresses
    // independently — no shared frame arena, no shared heap, no shared
    // bridge tables.
    try h.click(h.findId(.button, "Add").?);
    try status_harness.runtime.dispatchPlatformEvent(status_app, .{ .menu_command = .{ .name = "core.stamp", .window_id = 1 } });
    try h.click(h.findId(.button, "Add").?);
    try status_harness.runtime.dispatchPlatformEvent(status_app, .{ .menu_command = .{ .name = "core.toggle", .window_id = 1 } });

    try std.testing.expectEqual(@as(usize, 2), Bridge.model().tasks.len);
    try std.testing.expectEqualStrings("beta", Bridge.model().tasks[0].title);
    try std.testing.expectEqual(@as(f64, 90_000), StatusAdapter.Host.model().stampMs);
    try std.testing.expect(!StatusAdapter.Host.model().polling);

    // And the markup app still renders its own core's state.
    try std.testing.expect(h.hasText("beta #1"));
    try std.testing.expect(h.hasText("gamma #2"));
}
