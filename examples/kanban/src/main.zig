//! kanban: a three-column board (Todo / Doing / Done) written with the
//! `canvas.Ui` declarative builder on the runtime-owned `UiApp` loop.
//!
//! The board view lives in `board.native` (embedded, hot-reloaded in dev);
//! this file is the logic. Cards carry a markup `global-key`, which pins
//! their widget ids to the card id independent of the parent chain — so a
//! card keeps its identity (and its move button keeps its handler binding)
//! when it migrates between columns.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "kanban-canvas";
const window_width: f32 = 840;
const window_height: f32 = 560;
/// Content min-size floor the window enforces: the board is machined
/// from the designed window width, so shrinking below it can only clip
/// the columns — the floor is the designed size itself, proven by the
/// layout audit sweep in tests.zig.
pub const window_min_width: f32 = window_width;
pub const window_min_height: f32 = window_height;
const max_cards = 64;
const max_card_title = 32;

const root_padding: f32 = 16;
/// The header row's natural height, and the floor `header_height` falls
/// back to when no titlebar band overlays the content (fullscreen,
/// standard chrome, tests).
pub const header_natural_height: f32 = 52;
const column_gap: f32 = 12;
const board_width: f32 = window_width - 2 * root_padding;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Kanban board canvas", .accessibility_label = "Kanban board", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native SDK Kanban",
    .width = window_width,
    .height = window_height,
    .min_width = window_min_width,
    .min_height = window_min_height,
    .restore_state = false,
    // Tall hidden-inset titlebar (declared in app.zon too, which threads
    // it through the STARTUP window create): the header row IS the
    // titlebar — it pads its leading edge past the traffic lights via
    // `on_chrome` and is the window's drag surface (`window-drag` in
    // board.native).
    .titlebar = .hidden_inset_tall,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const Column = enum {
    todo,
    doing,
    done,

    pub fn next(column: Column) ?Column {
        return switch (column) {
            .todo => .doing,
            .doing => .done,
            .done => null,
        };
    }

    pub fn title(column: Column) []const u8 {
        return switch (column) {
            .todo => "Todo",
            .doing => "Doing",
            .done => "Done",
        };
    }
};

pub const column_values = [_]Column{ .todo, .doing, .done };

pub const Card = struct {
    id: u32,
    column: Column = .todo,
    title_storage: [max_card_title]u8 = [_]u8{0} ** max_card_title,
    title_len: usize = 0,

    pub fn title(card: *const Card) []const u8 {
        return card.title_storage[0..card.title_len];
    }

    pub fn key(card: *const Card) canvas.UiKey {
        return canvas.uiKey(card.id);
    }

    pub fn movable(card: *const Card) bool {
        return card.column.next() != null;
    }
};

pub const Msg = union(enum) {
    add,
    move_right: u32,
    /// Chrome overlay geometry (tall hidden-inset titlebar): the header
    /// pads its leading edge past the traffic lights and matches its
    /// height to the titlebar band. Delivered through `on_chrome`.
    chrome_changed: native_sdk.WindowChrome,

    /// Zig-only dispatch (`on_chrome`): never bound in markup, so the
    /// dead-state lint must not ask for an on-* event.
    pub const view_unbound = .{"chrome_changed"};
};

pub const Model = struct {
    cards: [max_cards]Card = undefined,
    card_count: usize = 0,
    next_id: u32 = 1,
    /// Chrome overlay geometry from `on_chrome` (tall hidden-inset
    /// titlebar): the header leads with a spacer this wide so its
    /// controls clear the traffic lights, and matches its height to the
    /// titlebar band. Both fall back to the natural header when no band
    /// overlays the content (fullscreen, standard chrome, tests).
    chrome_leading: f32 = 0,
    header_height: f32 = header_natural_height,

    /// Update-only state: the view binds the per-column query fns, never
    /// the backing store — opting these out keeps `native check`'s
    /// dead-state lint quiet without weakening it for real drift.
    pub const view_unbound = .{ "cards", "card_count", "next_id" };

    pub fn addCard(model: *Model, text: []const u8) void {
        if (model.card_count >= max_cards) return;
        var card = Card{ .id = model.next_id };
        const len = @min(text.len, max_card_title);
        @memcpy(card.title_storage[0..len], text[0..len]);
        card.title_len = len;
        model.cards[model.card_count] = card;
        model.card_count += 1;
        model.next_id += 1;
    }

    fn addGeneratedCard(model: *Model) void {
        var buffer: [max_card_title]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "Card {d}", .{model.next_id}) catch return;
        model.addCard(text);
    }

    pub fn cardById(model: *Model, id: u32) ?*Card {
        for (model.cards[0..model.card_count]) |*card| {
            if (card.id == id) return card;
        }
        return null;
    }

    /// Advance a card to the next column and re-append it so it lands at
    /// the bottom of the target column. Done cards stay put.
    pub fn moveRight(model: *Model, id: u32) void {
        var index: usize = model.card_count;
        for (model.cards[0..model.card_count], 0..) |card, i| {
            if (card.id == id) index = i;
        }
        if (index >= model.card_count) return;
        var card = model.cards[index];
        const target = card.column.next() orelse return;
        card.column = target;
        for (model.cards[index + 1 .. model.card_count], index..) |moved, slot| {
            model.cards[slot] = moved;
        }
        model.cards[model.card_count - 1] = card;
    }

    pub fn count(model: *const Model, column: Column) usize {
        var total: usize = 0;
        for (model.cards[0..model.card_count]) |card| total += @intFromBool(card.column == column);
        return total;
    }

    pub fn todoCards(model: *const Model, arena: std.mem.Allocator) []const Card {
        return model.columnCards(arena, .todo);
    }

    pub fn doingCards(model: *const Model, arena: std.mem.Allocator) []const Card {
        return model.columnCards(arena, .doing);
    }

    pub fn doneCards(model: *const Model, arena: std.mem.Allocator) []const Card {
        return model.columnCards(arena, .done);
    }

    pub fn todoCount(model: *const Model) usize {
        return model.count(.todo);
    }

    pub fn doingCount(model: *const Model) usize {
        return model.count(.doing);
    }

    pub fn doneCount(model: *const Model) usize {
        return model.count(.done);
    }

    /// Cards belonging to one column, in model order, copied into the
    /// build arena for the view pass.
    fn columnCards(model: *const Model, arena: std.mem.Allocator, column: Column) []const Card {
        const out = arena.alloc(Card, model.card_count) catch return &.{};
        var len: usize = 0;
        for (model.cards[0..model.card_count]) |card| {
            if (card.column == column) {
                out[len] = card;
                len += 1;
            }
        }
        return out[0..len];
    }
};

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .add => model.addGeneratedCard(),
        .move_right => |id| model.moveRight(id),
        .chrome_changed => |chrome| {
            model.chrome_leading = chrome.insets.left;
            // Match the header to the titlebar band so its centered
            // controls share the traffic lights' centerline; the natural
            // height is the floor when no band overlays the content.
            model.header_height = @max(header_natural_height, chrome.insets.top);
        },
    }
}

/// Chrome overlay geometry flows into the model (tall hidden-inset
/// titlebar): delivered before the first view build and again when it
/// changes — entering fullscreen hides the traffic lights and this goes
/// to zero.
pub fn onChrome(chrome: native_sdk.WindowChrome) ?Msg {
    return .{ .chrome_changed = chrome };
}

// ------------------------------------------------------------------- view

pub const KanbanUi = canvas.Ui(Msg);
pub const board_markup = @embedFile("board.native");
/// The board's markup source set: the root view plus its import closure,
/// paths relative to this directory. One list feeds both engines — the
/// compiled view resolves it at comptime, and the runtime interpreter
/// resolves the same set for the embedded source (hot reload re-resolves
/// from disk, so edits to imported files reload too).
pub const board_markup_files = [_]canvas.ui_markup.SourceFile{
    .{ .path = "board.native", .source = board_markup },
    .{ .path = "components/board-column.native", .source = @embedFile("components/board-column.native") },
};
pub const CompiledBoardView = canvas.CompiledMarkupImports(Model, Msg, "board.native", &board_markup_files);

/// Debug builds keep the interpreter for .native hot reload; release builds
/// ship the comptime-compiled view with no parser in the binary.
const dev_markup_reload = builtin.mode == .Debug;

// -------------------------------------------------------------------- app

const KanbanApp = native_sdk.UiAppWithFeatures(Model, Msg, .{ .runtime_markup = dev_markup_reload });

fn initialModel() Model {
    var model = Model{};
    model.addCard("Sketch the board layout");
    model.addCard("Wire typed dispatch");
    model.addCard("Write loop tests");
    model.addCard("Copy inbox scaffolding");
    model.addCard("Read the builder source");
    model.moveRight(3); // "Write loop tests" -> doing
    model.moveRight(4); // "Copy inbox scaffolding" -> doing -> done
    model.moveRight(4);
    model.moveRight(5); // "Read the builder source" -> doing -> done
    model.moveRight(5);
    return model;
}

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(KanbanApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = KanbanApp.init(std.heap.page_allocator, initialModel(), .{
        .name = "kanban",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update = update,
        .on_chrome = onChrome,
        .view = CompiledBoardView.build,
        .markup = if (dev_markup_reload)
            .{ .source = board_markup, .sources = &board_markup_files, .watch_path = "src/board.native", .io = init.io }
        else
            null,
    });
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "kanban",
        .window_title = "Native SDK Kanban",
        .bundle_id = "dev.native_sdk.kanban",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
