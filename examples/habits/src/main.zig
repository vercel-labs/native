//! habits: a small habit tracker authored in markup + Zig.
//!
//! The view lives in `habits.native`; this file is the logic: `Model`, `Msg`,
//! and `update`. Rows carry a markup `global-key` pinned to the habit id,
//! so a row keeps its widget identity across rebuilds and filtering.
//!
//! The markup runs on one of two engines depending on the build mode:
//! release builds use `canvas.CompiledMarkupView` — the source is parsed
//! entirely at comptime, so the binary carries no markup parser and a
//! markup mistake is a compile error — while debug builds additionally
//! ship the runtime interpreter and watch `src/habits.native`: the compiled
//! view renders until the file first changes on disk, then hot reload
//! takes over without losing streak state.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "habits-canvas";
const window_width: f32 = 720;
const window_height: f32 = 520;
const max_habits = 64;
const max_habit_name = 32;
/// The header row's natural height, and the floor `header_height` falls
/// back to when no titlebar band overlays the content (fullscreen,
/// standard chrome, tests).
pub const header_natural_height: f32 = 52;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Habit tracker canvas", .accessibility_label = "Habit tracker", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native SDK Habits",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    // Tall hidden-inset titlebar (declared in app.zon too, which threads
    // it through the STARTUP window create): the header row IS the
    // titlebar — it pads its leading edge past the traffic lights via
    // `on_chrome` and is the window's drag surface (`window-drag` in
    // habits.native).
    .titlebar = .hidden_inset_tall,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const Filter = enum { all, active };

pub const Habit = struct {
    id: u32,
    name_storage: [max_habit_name]u8 = [_]u8{0} ** max_habit_name,
    name_len: usize = 0,
    streak: u32 = 0,

    pub fn name(habit: *const Habit) []const u8 {
        return habit.name_storage[0..habit.name_len];
    }
};

pub const Msg = union(enum) {
    add,
    done: u32,
    set_filter: Filter,
    /// Chrome overlay geometry (tall hidden-inset titlebar): the header
    /// pads its leading edge past the traffic lights and matches its
    /// height to the titlebar band. Delivered through `on_chrome`.
    chrome_changed: native_sdk.WindowChrome,

    /// Zig-only dispatch (`on_chrome`): never bound in markup, so the
    /// dead-state lint must not ask for an on-* event.
    pub const view_unbound = .{"chrome_changed"};
};

pub const Model = struct {
    habits: [max_habits]Habit = undefined,
    habit_count: usize = 0,
    next_id: u32 = 1,
    filter: Filter = .all,
    /// Chrome overlay geometry from `on_chrome` (tall hidden-inset
    /// titlebar): the header leads with a spacer this wide so its
    /// controls clear the traffic lights, and matches its height to the
    /// titlebar band. Both fall back to the natural header when no band
    /// overlays the content (fullscreen, standard chrome, tests).
    chrome_leading: f32 = 0,
    header_height: f32 = header_natural_height,

    pub const filters = [_]Filter{ .all, .active };

    pub fn addHabit(model: *Model, text: []const u8, streak: u32) void {
        if (model.habit_count >= max_habits) return;
        var habit = Habit{ .id = model.next_id, .streak = streak };
        const len = @min(text.len, max_habit_name);
        @memcpy(habit.name_storage[0..len], text[0..len]);
        habit.name_len = len;
        model.habits[model.habit_count] = habit;
        model.habit_count += 1;
        model.next_id += 1;
    }

    fn addGeneratedHabit(model: *Model) void {
        var buffer: [max_habit_name]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "Habit {d}", .{model.next_id}) catch return;
        model.addHabit(text, 0);
    }

    pub fn habitById(model: *Model, id: u32) ?*Habit {
        for (model.habits[0..model.habit_count]) |*habit| {
            if (habit.id == id) return habit;
        }
        return null;
    }

    pub fn totalDays(model: *const Model) usize {
        var total: usize = 0;
        for (model.habits[0..model.habit_count]) |habit| total += habit.streak;
        return total;
    }

    /// Arena-taking scalar binding: `{summaryLine}` formats the status
    /// line into the build arena on every rebuild — derived, never stored.
    pub fn summaryLine(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "{d} habits · {d} total days", .{
            model.habit_count, model.totalDays(),
        }) catch "";
    }

    /// Habits under the current filter, copied into the build arena for
    /// the view pass. `active` means the streak is non-zero.
    pub fn visible(model: *const Model, arena: std.mem.Allocator) []const Habit {
        const out = arena.alloc(Habit, model.habit_count) catch return &.{};
        var count: usize = 0;
        for (model.habits[0..model.habit_count]) |habit| {
            const keep = switch (model.filter) {
                .all => true,
                .active => habit.streak > 0,
            };
            if (keep) {
                out[count] = habit;
                count += 1;
            }
        }
        return out[0..count];
    }
};

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .add => model.addGeneratedHabit(),
        .done => |id| if (model.habitById(id)) |habit| {
            habit.streak += 1;
        },
        .set_filter => |filter| model.filter = filter,
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

pub const HabitsUi = canvas.Ui(Msg);
pub const habits_markup = @embedFile("habits.native");

/// The comptime-compiled engine: same tree, ids, and handlers as the
/// interpreter, no parser in the binary.
pub const CompiledHabitsView = canvas.CompiledMarkupView(Model, Msg, habits_markup);

// -------------------------------------------------------------------- app

/// Debug builds keep the runtime markup engine for hot reload; release
/// builds compile it out entirely (`zig build` produces a release app —
/// grep it for parser diagnostics to confirm nothing survived).
const dev_markup_reload = builtin.mode == .Debug;

const HabitsApp = native_sdk.UiAppWithFeatures(Model, Msg, .{ .runtime_markup = dev_markup_reload });

pub fn initialModel() Model {
    var model = Model{};
    model.addHabit("Meditate", 12);
    model.addHabit("Exercise", 0);
    model.addHabit("Read 20 pages", 9);
    return model;
}

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(HabitsApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = HabitsApp.init(std.heap.page_allocator, initialModel(), .{
        .name = "habits",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update = update,
        .on_chrome = onChrome,
        .view = CompiledHabitsView.build,
        .markup = if (dev_markup_reload)
            .{ .source = habits_markup, .watch_path = "src/habits.native", .io = init.io }
        else
            null,
    });
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "habits",
        .window_title = "Native SDK Habits",
        .bundle_id = "dev.native_sdk.habits",
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
