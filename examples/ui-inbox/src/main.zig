//! ui-inbox: a native-rendered task inbox authored in markup + Zig.
//!
//! The view lives in `inbox.native` (embedded into the binary, and watched for
//! hot reload in dev); this file is the logic: `Model`, `Msg`, and `update`.
//! The markup compiles to the same builder tree a hand-written `view()`
//! would produce — structural identity, flex layout, and typed message
//! dispatch all come from the same `canvas.Ui(Msg)` layer.

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "inbox-canvas";
const window_width: f32 = 720;
const window_height: f32 = 520;
/// Content min-size floor the window enforces: the smallest size where
/// the toolbar, filter chips, and task rows lay out without clipping —
/// proven by the layout audit sweep in tests.zig, which sweeps from
/// exactly this floor.
pub const window_min_width: f32 = 520;
pub const window_min_height: f32 = 400;
const max_tasks = 64;
const max_task_title = 32;
/// The header row's natural height, and the floor `header_height` falls
/// back to when no titlebar band overlays the content (fullscreen,
/// standard chrome, tests).
pub const header_natural_height: f32 = 52;


const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Task inbox canvas", .accessibility_label = "Task inbox", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native SDK Inbox",
    .width = window_width,
    .height = window_height,
    .min_width = window_min_width,
    .min_height = window_min_height,
    .restore_state = false,
    // Tall hidden-inset titlebar (declared in app.zon too, which threads
    // it through the STARTUP window create): the header row IS the
    // titlebar — it pads its leading edge past the traffic lights via
    // `on_chrome` and is the window's drag surface (`window-drag` in
    // inbox.native).
    .titlebar = .hidden_inset_tall,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

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
    /// Chrome overlay geometry (tall hidden-inset titlebar): the header
    /// pads its leading edge past the traffic lights and matches its
    /// height to the titlebar band. Delivered through `on_chrome`.
    chrome_changed: native_sdk.WindowChrome,

    /// Zig-only dispatch (`on_chrome`): never bound in markup, so the
    /// dead-state lint must not ask for an on-* event.
    pub const view_unbound = .{"chrome_changed"};
};

pub const Model = struct {
    tasks: [max_tasks]Task = undefined,
    task_count: usize = 0,
    next_id: u32 = 1,
    filter: Filter = .all,
    /// Chrome overlay geometry from `on_chrome` (tall hidden-inset
    /// titlebar): the header leads with a spacer this wide so its
    /// controls clear the traffic lights, and matches its height to the
    /// titlebar band. Both fall back to the natural header when no band
    /// overlays the content (fullscreen, standard chrome, tests).
    chrome_leading: f32 = 0,
    header_height: f32 = header_natural_height,
    // The draft field's editor state, elm-style: the model applies every
    // text edit event and is the source of truth. The runtime's reconcile
    // rule keeps them in lockstep (matching source text preserves runtime
    // caret/selection; a source-side change like clear-on-submit wins).
    draft_buffer: canvas.TextBuffer(max_task_title) = .{},

    pub const filters = [_]Filter{ .all, .active, .done };

    pub fn draft(model: *const Model) []const u8 {
        return model.draft_buffer.text();
    }

    pub fn draftEmpty(model: *const Model) bool {
        return model.draft_buffer.isEmpty();
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
                model.draft_buffer.clear();
            }
        },
        .toggle => |id| if (model.taskById(id)) |task| {
            task.done = !task.done;
        },
        .set_filter => |filter| model.filter = filter,
        .clear_done => model.clearDone(),
        .draft_edit => |edit| model.draft_buffer.apply(edit),
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

pub const InboxUi = canvas.Ui(Msg);
pub const inbox_markup = @embedFile("inbox.native");
pub const CompiledInboxView = canvas.CompiledMarkupView(Model, Msg, inbox_markup);

/// Debug builds keep the interpreter for .native hot reload; release builds
/// ship the comptime-compiled view with no parser in the binary.
const dev_markup_reload = builtin.mode == .Debug;

// -------------------------------------------------------------------- app
//
// The runtime owns the whole loop: install on first gpu frame, presentation,
// resize, and typed pointer/keyboard dispatch into `update` + rebuild.

const InboxApp = native_sdk.UiAppWithFeatures(Model, Msg, .{ .runtime_markup = dev_markup_reload });

fn initialModel() Model {
    var model = Model{};
    model.addTask("Prove the ui builder end to end");
    model.addTask("Rewrite gpu-dashboard with it");
    model.addTask("Record the authoring decisions");
    return model;
}

// ------------------------------------------------------------------ mobile
//
// `zig build lib -Dmobile=true` compiles this same Model/Msg/update and the
// comptime-compiled .native view into the mobile embed static library
// (`native_sdk.addMobileLib`); the embed host drives it on the canonical
// single-surface canvas scene. Markup hot reload stays desktop-only.

pub fn initModel() Model {
    return initialModel();
}

pub fn mobileOptions() native_sdk.UiApp(Model, Msg).Options {
    return .{
        .name = "ui-inbox",
        .scene = native_sdk.embed.mobile_shell_scene,
        .canvas_label = native_sdk.embed.mobile_gpu_surface_label,
        .update = update,
        .view = CompiledInboxView.build,
    };
}

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(InboxApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = InboxApp.init(std.heap.page_allocator, initialModel(), .{
        .name = "ui-inbox",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update = update,
        .on_chrome = onChrome,
        .view = CompiledInboxView.build,
        .markup = if (dev_markup_reload)
            .{ .source = inbox_markup, .watch_path = "src/inbox.native", .io = init.io }
        else
            null,
    });
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "ui-inbox",
        .window_title = "Native SDK Inbox",
        .bundle_id = "dev.native_sdk.ui_inbox",
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
