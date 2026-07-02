//! ui-inbox: a native-rendered task inbox written entirely with the
//! experimental `canvas.Ui` declarative builder.
//!
//! The app is one elm-style loop: `Model` -> `Msg` -> `update` -> `view`.
//! There are no hand-assigned widget ids, no absolute frames, and no string
//! command dispatch — widget identity is structural, layout is flex, and
//! events resolve to typed `Msg` values through the tree's handler table.

const std = @import("std");
const runner = @import("runner");
const zero_native = @import("zero-native");

pub const panic = std.debug.FullPanic(zero_native.debug.capturePanic);

const canvas = zero_native.canvas;
const geometry = zero_native.geometry;

const canvas_label = "inbox-canvas";
const window_width: f32 = 720;
const window_height: f32 = 520;
const max_tasks = 64;
const max_task_title = 32;


const app_permissions = [_][]const u8{ zero_native.security.permission_command, zero_native.security.permission_view };
const shell_views = [_]zero_native.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Task inbox canvas", .accessibility_label = "Task inbox", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]zero_native.ShellWindow{.{
    .label = "main",
    .title = "zero-native Inbox",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: zero_native.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const Filter = enum { all, active, done };
const filter_values = [_]Filter{ .all, .active, .done };

pub const Task = struct {
    id: u32,
    title_storage: [max_task_title]u8 = [_]u8{0} ** max_task_title,
    title_len: usize = 0,
    done: bool = false,

    fn title(task: *const Task) []const u8 {
        return task.title_storage[0..task.title_len];
    }

    fn key(task: *const Task) canvas.UiKey {
        return canvas.uiKey(task.id);
    }
};

pub const Msg = union(enum) {
    add,
    toggle: u32,
    set_filter: Filter,
    clear_done,
};

pub const Model = struct {
    tasks: [max_tasks]Task = undefined,
    task_count: usize = 0,
    next_id: u32 = 1,
    filter: Filter = .all,

    pub fn addTask(model: *Model, text: []const u8) void {
        if (model.task_count >= max_tasks) return;
        var task = Task{ .id = model.next_id };
        const len = @min(text.len, max_task_title);
        @memcpy(task.title_storage[0..len], text[0..len]);
        task.title_len = len;
        model.tasks[model.task_count] = task;
        model.task_count += 1;
        model.next_id += 1;
    }

    fn addGeneratedTask(model: *Model) void {
        var buffer: [max_task_title]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "Task {d}", .{model.next_id}) catch return;
        model.addTask(text);
    }

    fn taskById(model: *Model, id: u32) ?*Task {
        for (model.tasks[0..model.task_count]) |*task| {
            if (task.id == id) return task;
        }
        return null;
    }

    fn clearDone(model: *Model) void {
        var kept: usize = 0;
        for (model.tasks[0..model.task_count]) |task| {
            if (!task.done) {
                model.tasks[kept] = task;
                kept += 1;
            }
        }
        model.task_count = kept;
    }

    pub fn openCount(model: *const Model) usize {
        var open: usize = 0;
        for (model.tasks[0..model.task_count]) |task| open += @intFromBool(!task.done);
        return open;
    }

    pub fn doneCount(model: *const Model) usize {
        return model.task_count - model.openCount();
    }

    fn visible(model: *const Model, arena: std.mem.Allocator) []const Task {
        const out = arena.alloc(Task, model.task_count) catch return &.{};
        var count: usize = 0;
        for (model.tasks[0..model.task_count]) |task| {
            const keep = switch (model.filter) {
                .all => true,
                .active => !task.done,
                .done => task.done,
            };
            if (keep) {
                out[count] = task;
                count += 1;
            }
        }
        return out[0..count];
    }
};

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .add => model.addGeneratedTask(),
        .toggle => |id| if (model.taskById(id)) |task| {
            task.done = !task.done;
        },
        .set_filter => |filter| model.filter = filter,
        .clear_done => model.clearDone(),
    }
}

// ------------------------------------------------------------------- view

pub const InboxUi = canvas.Ui(Msg);

pub fn view(ui: *InboxUi, model: *const Model) InboxUi.Node {
    return ui.column(.{ .gap = 12, .padding = 16 }, .{
        ui.row(.{ .gap = 8, .cross = .center }, .{
            ui.text(.{ .grow = 1 }, "Inbox"),
            ui.button(.{ .variant = .primary, .on_press = .add }, "Add task"),
            ui.button(.{ .variant = .ghost, .on_press = .clear_done, .disabled = model.doneCount() == 0 }, "Clear done"),
        }),
        ui.row(.{ .gap = 8 }, ui.eachCtx(model.filter, &filter_values, filterKey, filterButton)),
        ui.scroll(.{ .grow = 1 }, ui.column(.{ .gap = 2 }, ui.each(model.visible(ui.arena), Task.key, taskRow))),
        ui.statusBar(.{}, ui.fmt("{d} open · {d} done", .{ model.openCount(), model.doneCount() })),
    });
}

fn filterKey(filter: *const Filter) canvas.UiKey {
    return canvas.uiKey(@as(u32, @intFromEnum(filter.*)));
}

fn filterButton(ui: *InboxUi, selected: Filter, filter: *const Filter) InboxUi.Node {
    return ui.button(.{
        .variant = if (filter.* == selected) .secondary else .outline,
        .size = .sm,
        .selected = filter.* == selected,
        .on_press = Msg{ .set_filter = filter.* },
    }, @tagName(filter.*));
}

fn taskRow(ui: *InboxUi, task: *const Task) InboxUi.Node {
    return ui.row(.{ .gap = 8, .padding = 6, .cross = .center }, .{
        ui.checkbox(.{ .checked = task.done, .on_toggle = Msg{ .toggle = task.id } }),
        ui.text(.{ .grow = 1 }, task.title()),
    });
}

// -------------------------------------------------------------------- app
//
// The runtime owns the whole loop: install on first gpu frame, presentation,
// resize, and typed pointer/keyboard dispatch into `update` + rebuild.

const InboxApp = zero_native.UiApp(Model, Msg);

fn initialModel() Model {
    var model = Model{};
    model.addTask("Prove the ui builder end to end");
    model.addTask("Rewrite gpu-dashboard with it");
    model.addTask("Record the authoring decisions");
    return model;
}

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(InboxApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = InboxApp.init(std.heap.page_allocator, initialModel(), .{
        .name = "ui-inbox",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update = update,
        .view = view,
    });
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "ui-inbox",
        .window_title = "zero-native Inbox",
        .bundle_id = "dev.zero_native.ui_inbox",
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
