//! ui-inbox: a native-rendered task inbox authored in markup + Zig.
//!
//! The view lives in `inbox.zml` (embedded into the binary, and watched for
//! hot reload in dev); this file is the logic: `Model`, `Msg`, and `update`.
//! The markup compiles to the same builder tree a hand-written `view()`
//! would produce — structural identity, flex layout, and typed message
//! dispatch all come from the same `canvas.Ui(Msg)` layer.

const std = @import("std");
const builtin = @import("builtin");
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

pub const Task = struct {
    id: u32,
    title_storage: [max_task_title]u8 = [_]u8{0} ** max_task_title,
    title_len: usize = 0,
    done: bool = false,

    pub fn title(task: *const Task) []const u8 {
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
    draft_edit: canvas.TextInputEvent,
};

pub const Model = struct {
    tasks: [max_tasks]Task = undefined,
    task_count: usize = 0,
    next_id: u32 = 1,
    filter: Filter = .all,
    // The draft field's editor state, elm-style: the model applies every
    // text edit event and is the source of truth. The runtime's reconcile
    // rule keeps them in lockstep (matching source text preserves runtime
    // caret/selection; a source-side change like clear-on-submit wins).
    draft_storage: [max_task_title]u8 = [_]u8{0} ** max_task_title,
    draft_len: usize = 0,
    draft_selection: canvas.TextSelection = .{},
    draft_composition: ?canvas.TextRange = null,

    pub const filters = [_]Filter{ .all, .active, .done };

    pub fn draft(model: *const Model) []const u8 {
        return model.draft_storage[0..model.draft_len];
    }

    pub fn draftEmpty(model: *const Model) bool {
        return std.mem.trim(u8, model.draft(), " ").len == 0;
    }

    fn applyDraftEdit(model: *Model, edit: canvas.TextInputEvent) void {
        var scratch: [max_task_title]u8 = undefined;
        const state = canvas.TextEditState{
            .text = model.draft(),
            .selection = model.draft_selection,
            .composition = model.draft_composition,
        };
        const next = canvas.applyTextInputEvent(state, edit, &scratch) catch return;
        const len = @min(next.text.len, model.draft_storage.len);
        std.mem.copyForwards(u8, model.draft_storage[0..len], next.text[0..len]);
        model.draft_len = len;
        model.draft_selection = next.selection;
        model.draft_composition = next.composition;
    }

    fn clearDraft(model: *Model) void {
        model.draft_len = 0;
        model.draft_selection = .{};
        model.draft_composition = null;
    }

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

    pub fn doneEmpty(model: *const Model) bool {
        return model.doneCount() == 0;
    }

    pub fn visible(model: *const Model, arena: std.mem.Allocator) []const Task {
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
        .add => {
            if (model.draftEmpty()) {
                model.addGeneratedTask();
            } else {
                model.addTask(std.mem.trim(u8, model.draft(), " "));
                model.clearDraft();
            }
        },
        .toggle => |id| if (model.taskById(id)) |task| {
            task.done = !task.done;
        },
        .set_filter => |filter| model.filter = filter,
        .clear_done => model.clearDone(),
        .draft_edit => |edit| model.applyDraftEdit(edit),
    }
}

// ------------------------------------------------------------------- view

pub const InboxUi = canvas.Ui(Msg);
pub const inbox_markup = @embedFile("inbox.zml");
pub const CompiledInboxView = canvas.CompiledMarkupView(Model, Msg, inbox_markup);

/// Debug builds keep the interpreter for .zml hot reload; release builds
/// ship the comptime-compiled view with no parser in the binary.
const dev_markup_reload = builtin.mode == .Debug;

// -------------------------------------------------------------------- app
//
// The runtime owns the whole loop: install on first gpu frame, presentation,
// resize, and typed pointer/keyboard dispatch into `update` + rebuild.

const InboxApp = zero_native.UiAppWithFeatures(Model, Msg, .{ .runtime_markup = dev_markup_reload });

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
        .view = CompiledInboxView.build,
        .markup = if (dev_markup_reload)
            .{ .source = inbox_markup, .watch_path = "src/inbox.zml", .io = init.io }
        else
            null,
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
