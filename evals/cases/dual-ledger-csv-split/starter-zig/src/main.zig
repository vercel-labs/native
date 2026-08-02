//! The expense-ledger app: seeded expenses, removal, derived totals. The
//! view lives in `app.native`; this file is the logic: `Model`, `Msg`, and
//! `update`.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 560;
const window_height: f32 = 380;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Expenses canvas", .accessibility_label = "Expenses", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Expenses",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const max_expenses = 16;
pub const max_label = 48;

pub const Category = enum { food, gear, travel };

pub const Expense = struct {
    id: i64,
    label_buf: [max_label]u8,
    label_len: usize,
    category: Category,
    cents: i64,

    pub fn label(self: *const Expense) []const u8 {
        return self.label_buf[0..self.label_len];
    }
};

pub const Msg = union(enum) {
    remove: i64,
    reset,
};

pub const Model = struct {
    expenses: [max_expenses]Expense = undefined,
    expense_count_storage: usize = 0,

    pub fn rows(model: *const Model) []const Expense {
        return model.expenses[0..model.expense_count_storage];
    }

    pub fn totalCents(model: *const Model) i64 {
        var total: i64 = 0;
        for (model.rows()) |*e| total += e.cents;
        return total;
    }

    pub fn expenseCount(model: *const Model) i64 {
        return @intCast(model.expense_count_storage);
    }
};

fn makeExpense(id: i64, label_text: []const u8, category: Category, cents: i64) Expense {
    var expense = Expense{ .id = id, .label_buf = undefined, .label_len = label_text.len, .category = category, .cents = cents };
    @memcpy(expense.label_buf[0..label_text.len], label_text);
    return expense;
}

fn seedExpenses(model: *Model) void {
    model.expenses[0] = makeExpense(1, "Standing desk", .gear, 45900);
    model.expenses[1] = makeExpense(2, "Cable, HDMI 2m", .gear, 1900);
    model.expenses[2] = makeExpense(3, "Team lunch", .food, 6400);
    model.expenses[3] = makeExpense(4, "Mug \"Team\" x4", .gear, 1250);
    model.expense_count_storage = 4;
}

pub fn initialModel() Model {
    var model = Model{};
    seedExpenses(&model);
    return model;
}

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .remove => |id| {
            var at: usize = 0;
            while (at < model.expense_count_storage) : (at += 1) {
                if (model.expenses[at].id == id) break;
            } else return;
            while (at + 1 < model.expense_count_storage) : (at += 1) {
                model.expenses[at] = model.expenses[at + 1];
            }
            model.expense_count_storage -= 1;
        },
        .reset => seedExpenses(model),
    }
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

// -------------------------------------------------------------------- app

const LedgerApp = native_sdk.UiApp(Model, Msg);

pub fn main(init: std.process.Init) !void {
    // The app struct (and any real Model) is multi-MB: `create`
    // heap-allocates and constructs everything in place, so neither
    // ever rides the stack. Mutate `app_state.model` through the
    // pointer before running if boot state is not the default.
    const app_state = try LedgerApp.create(std.heap.page_allocator, .{
        .name = "expenses",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update = update,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "expenses",
        .window_title = "Expenses",
        .bundle_id = "dev.native_sdk.expenses",
        .icon_path = "assets/icon.png",
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
