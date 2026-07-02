//! kanban: a three-column board (Todo / Doing / Done) written with the
//! `canvas.Ui` declarative builder on the runtime-owned `UiApp` loop.
//!
//! The board view lives in `board.zml` (embedded, hot-reloaded in dev);
//! this file is the logic. Cards carry a markup `global-key`, which pins
//! their widget ids to the card id independent of the parent chain — so a
//! card keeps its identity (and its move button keeps its handler binding)
//! when it migrates between columns.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const zero_native = @import("zero-native");

pub const panic = std.debug.FullPanic(zero_native.debug.capturePanic);

const canvas = zero_native.canvas;
const geometry = zero_native.geometry;

const canvas_label = "kanban-canvas";
const window_width: f32 = 840;
const window_height: f32 = 560;
const max_cards = 64;
const max_card_title = 32;

const root_padding: f32 = 16;
const column_gap: f32 = 12;
const board_width: f32 = window_width - 2 * root_padding;

const app_permissions = [_][]const u8{ zero_native.security.permission_command, zero_native.security.permission_view };
const shell_views = [_]zero_native.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Kanban board canvas", .accessibility_label = "Kanban board", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]zero_native.ShellWindow{.{
    .label = "main",
    .title = "zero-native Kanban",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: zero_native.ShellConfig = .{ .windows = &shell_windows };

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
};

pub const Model = struct {
    cards: [max_cards]Card = undefined,
    card_count: usize = 0,
    next_id: u32 = 1,

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
    }
}

// ------------------------------------------------------------------- view

pub const KanbanUi = canvas.Ui(Msg);
pub const board_markup = @embedFile("board.zml");
pub const CompiledBoardView = canvas.CompiledMarkupView(Model, Msg, board_markup);

/// Debug builds keep the interpreter for .zml hot reload; release builds
/// ship the comptime-compiled view with no parser in the binary.
const dev_markup_reload = builtin.mode == .Debug;

// -------------------------------------------------------------------- app

const KanbanApp = zero_native.UiAppWithFeatures(Model, Msg, .{ .runtime_markup = dev_markup_reload });

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
        .view = CompiledBoardView.build,
        .markup = if (dev_markup_reload)
            .{ .source = board_markup, .watch_path = "src/board.zml", .io = init.io }
        else
            null,
    });
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "kanban",
        .window_title = "zero-native Kanban",
        .bundle_id = "dev.zero_native.kanban",
        .icon_path = "assets/icon.icns",
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
