//! The notes app: three seeded notes, sidebar selection, and a body editor
//! riding the toolkit's text-input events (`canvas.TextBuffer` does the
//! byte splicing). The view lives in `app.native`; this file is the logic:
//! `Model`, `Msg`, and `update`.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 640;
const window_height: f32 = 400;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Notes canvas", .accessibility_label = "Notes", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Notes",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const max_body = 256;

pub const Note = struct {
    id: i64 = 0,
    title: []const u8 = "",
    /// The body is a bounded text buffer so the editor's input events
    /// splice in place (`canvas.TextBuffer.apply`).
    body: canvas.TextBuffer(max_body) = .{},
};

pub const Msg = union(enum) {
    select: i64,
    edit: canvas.TextInputEvent,
};

pub const Model = struct {
    notes: [3]Note = @splat(.{}),
    selected_id: i64 = 1,

    /// Markup binds Model decls: these pub methods are the view's derived
    /// values ({selected_title}, {editor_text}).
    pub fn selectedTitle(model: *const Model) []const u8 {
        for (&model.notes) |*n| {
            if (n.id == model.selected_id) return n.title;
        }
        return "";
    }

    pub fn editorText(model: *const Model) []const u8 {
        for (&model.notes) |*n| {
            if (n.id == model.selected_id) return n.body.text();
        }
        return "";
    }
};

fn note(id: i64, title: []const u8, body: []const u8) Note {
    return .{ .id = id, .title = title, .body = canvas.TextBuffer(max_body).init(body) };
}

pub fn initialModel() Model {
    return .{ .notes = .{
        note(1, "Groceries", "milk, eggs"),
        note(2, "Ideas", "native first"),
        note(3, "Standup", "demo the panel"),
    } };
}

fn selectedNote(model: *Model) *Note {
    for (&model.notes) |*n| {
        if (n.id == model.selected_id) return n;
    }
    return &model.notes[0];
}

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .select => |id| {
            for (model.notes) |n| {
                if (n.id == id) {
                    model.selected_id = id;
                    return;
                }
            }
        },
        .edit => |event| selectedNote(model).body.apply(event),
    }
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

// -------------------------------------------------------------------- app

const NotesApp = native_sdk.UiApp(Model, Msg);

pub fn main(init: std.process.Init) !void {
    // The app struct (and any real Model) is multi-MB: `create`
    // heap-allocates and constructs everything in place, so neither
    // ever rides the stack. Mutate `app_state.model` through the
    // pointer before running if boot state is not the default.
    const app_state = try NotesApp.create(std.heap.page_allocator, .{
        .name = "notes",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update = update,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "notes",
        .window_title = "Notes",
        .bundle_id = "dev.native_sdk.notes",
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
