//! The tasks app: seeded tasks, open/done toggling, filter chips, a draft
//! entry riding the toolkit's text-input events, and derived counts. The
//! view lives in `app.native`; this file is the logic: `Model`, `Msg`, and
//! `update`.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 520;
const window_height: f32 = 400;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Tasks canvas", .accessibility_label = "Tasks", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Tasks",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const max_tasks = 16;
pub const max_title = 40;
pub const max_draft = 64;

pub const Filter = enum { all, open, done };

pub const Task = struct {
    id: i64,
    title_buf: [max_title]u8,
    title_len: usize,
    done: bool,

    pub fn title(self: *const Task) []const u8 {
        return self.title_buf[0..self.title_len];
    }
};

pub const Msg = union(enum) {
    draft_edit: canvas.TextInputEvent,
    add,
    toggle: i64,
    delete: i64,
    set_filter: Filter,
};

pub const Model = struct {
    tasks: [max_tasks]Task = undefined,
    task_count: usize = 0,
    next_id: i64 = 4,
    filter: Filter = .all,
    draft: canvas.TextBuffer(max_draft) = .{},
    /// The rows the list shows, refreshed whenever the tasks change.
    visible: [max_tasks]Task = undefined,
    visible_count: usize = 0,

    pub const filter_choices = [_]Filter{ .all, .open, .done };

    pub fn visibleTasks(model: *const Model) []const Task {
        return model.visible[0..model.visible_count];
    }

    pub fn openCount(model: *const Model) i64 {
        var open: i64 = 0;
        for (model.tasks[0..model.task_count]) |*t| {
            if (!t.done) open += 1;
        }
        return open;
    }

    pub fn draftText(model: *const Model) []const u8 {
        return model.draft.text();
    }
};

fn makeTask(id: i64, title_text: []const u8, done: bool) Task {
    var task = Task{ .id = id, .title_buf = undefined, .title_len = title_text.len, .done = done };
    @memcpy(task.title_buf[0..title_text.len], title_text);
    return task;
}

fn rebuildVisible(model: *Model) void {
    model.visible_count = 0;
    for (model.tasks[0..model.task_count]) |*t| {
        const shown = switch (model.filter) {
            .all => true,
            .open => !t.done,
            .done => t.done,
        };
        if (shown) {
            model.visible[model.visible_count] = t.*;
            model.visible_count += 1;
        }
    }
}

pub fn initialModel() Model {
    var model = Model{};
    model.tasks[0] = makeTask(1, "Ship the fix", false);
    model.tasks[1] = makeTask(2, "Write the tests", true);
    model.tasks[2] = makeTask(3, "Update the docs", false);
    model.task_count = 3;
    rebuildVisible(&model);
    return model;
}

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .draft_edit => |event| model.draft.apply(event),
        .add => {
            const title_text = std.mem.trim(u8, model.draft.text(), " \t");
            if (title_text.len == 0 or model.task_count == max_tasks or title_text.len > max_title) return;
            model.tasks[model.task_count] = makeTask(model.next_id, title_text, false);
            model.task_count += 1;
            model.next_id += 1;
            model.draft = .{};
            rebuildVisible(model);
        },
        .toggle => |id| {
            for (model.tasks[0..model.task_count]) |*t| {
                if (t.id == id) t.done = !t.done;
            }
            rebuildVisible(model);
        },
        .delete => |id| {
            var at: usize = 0;
            while (at < model.task_count) : (at += 1) {
                if (model.tasks[at].id == id) break;
            } else return;
            while (at + 1 < model.task_count) : (at += 1) {
                model.tasks[at] = model.tasks[at + 1];
            }
            model.task_count -= 1;
        },
        .set_filter => |filter| {
            model.filter = filter;
            rebuildVisible(model);
        },
    }
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

// -------------------------------------------------------------------- app

const TasksApp = native_sdk.UiApp(Model, Msg);

pub fn main(init: std.process.Init) !void {
    // The app struct (and any real Model) is multi-MB: `create`
    // heap-allocates and constructs everything in place, so neither
    // ever rides the stack. Mutate `app_state.model` through the
    // pointer before running if boot state is not the default.
    const app_state = try TasksApp.create(std.heap.page_allocator, .{
        .name = "tasks",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update = update,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "tasks",
        .window_title = "Tasks",
        .bundle_id = "dev.native_sdk.tasks",
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
