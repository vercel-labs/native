//! canvas-preview: the "both architectures in one window" dogfood app.
//!
//! One window hosts a native-sdk canvas (native-rendered toolbar and
//! sidebar on a Metal-backed gpu_surface) and a live platform webview
//! side by side. The webview is declared in the scene like any other
//! shell view; `UiApp.Options.web_panes` then keeps it snapped to a
//! canvas widget's layout frame (the empty panel carrying the
//! `preview-pane` semantics label) and drives navigation from the model
//! — the model owns `url` + `reload_token`, exactly the CenterPane
//! consumer shape a Preview tab needs.
//!
//! The same app installs a menu-bar extra (`status_item`): an
//! NSStatusItem whose menu items dispatch the same commands the
//! toolbar buttons do, through the ordinary `on_command` path.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

pub const canvas_label = "preview-canvas";
pub const webview_label = "preview";
pub const pane_anchor = "preview-pane";
pub const example_url = "https://example.com/";
pub const docs_url = "https://zero-native.dev/";
pub const example_command = "app.example";
pub const docs_command = "app.docs";
pub const reload_command = "app.reload";

const window_width: f32 = 960;
const window_height: f32 = 640;
const sidebar_width: f32 = 224;
const toolbar_height: f32 = 56;

pub const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Canvas chrome", .accessibility_label = "Canvas Preview chrome", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
    // The live webview: a scene view like any other. Parented to the
    // canvas view so pane frames share the canvas coordinate space; the
    // initial frame is a placeholder the first rebuild replaces with the
    // anchor widget's layout frame.
    .{ .label = webview_label, .kind = .webview, .parent = canvas_label, .url = example_url, .x = sidebar_width + 16, .y = toolbar_height + 20, .width = window_width - sidebar_width - 32, .height = window_height - toolbar_height - 36, .layer = 20 },
};
pub const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native SDK Canvas Preview",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const Page = enum {
    example,
    docs,

    pub fn url(page: Page) []const u8 {
        return switch (page) {
            .example => example_url,
            .docs => docs_url,
        };
    }

    pub fn title(page: Page) []const u8 {
        return switch (page) {
            .example => "Example",
            .docs => "Docs",
        };
    }
};

pub const Model = struct {
    page: Page = .example,
    reload_token: u64 = 0,
    reload_count: u32 = 0,
    gpu_frames_seen: bool = false,
};

pub const Msg = union(enum) {
    show_example,
    show_docs,
    reload,
    frame_presented,
};

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .show_example => model.page = .example,
        .show_docs => model.page = .docs,
        .reload => {
            model.reload_token += 1;
            model.reload_count += 1;
        },
        .frame_presented => model.gpu_frames_seen = true,
    }
}

// ------------------------------------------------------------------- view

const PreviewApp = native_sdk.UiApp(Model, Msg);
pub const PreviewUi = canvas.Ui(Msg);

pub fn view(ui: *PreviewUi, model: *const Model) PreviewUi.Node {
    return ui.column(.{ .gap = 0, .style_tokens = .{ .background = .background } }, .{
        ui.row(.{ .height = toolbar_height, .padding = 12, .gap = 8, .cross = .center }, .{
            ui.text(.{ .size = .lg }, "Canvas Preview"),
            ui.spacer(1),
            ui.button(.{ .variant = if (model.page == .example) .primary else .secondary, .on_press = .show_example }, "Example"),
            ui.button(.{ .variant = if (model.page == .docs) .primary else .secondary, .on_press = .show_docs }, "Docs"),
            ui.button(.{ .on_press = .reload }, "Reload"),
        }),
        ui.row(.{ .grow = 1, .gap = 0 }, .{
            ui.column(.{ .width = sidebar_width, .padding = 12, .gap = 8, .style_tokens = .{ .background = .surface } }, .{
                ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "Native canvas rail"),
                ui.text(.{}, ui.fmt("URL: {s}", .{model.page.url()})),
                ui.text(.{}, ui.fmt("Reloads: {d}", .{model.reload_count})),
                ui.spacer(1),
                ui.statusBar(.{}, if (model.gpu_frames_seen) "canvas presenting + webview live" else "waiting for first frame"),
            }),
            // The webview region: an empty panel whose layout frame the
            // runtime maps onto the webview's bounds every rebuild.
            ui.panel(.{ .grow = 1, .semantics = .{ .label = pane_anchor } }, .{}),
        }),
    });
}

// ------------------------------------------------------ webview pane seam

pub fn panes(model: *const Model, out: []PreviewApp.WebViewPane) usize {
    out[0] = .{
        .label = webview_label,
        .anchor = pane_anchor,
        .url = model.page.url(),
        .reload_token = model.reload_token,
    };
    return 1;
}

// -------------------------------------------------------------- commands

pub fn command(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, example_command)) return .show_example;
    if (std.mem.eql(u8, name, docs_command)) return .show_docs;
    if (std.mem.eql(u8, name, reload_command)) return .reload;
    return null;
}

fn onFrame(model: *const Model, frame: native_sdk.platform.GpuFrame) ?Msg {
    _ = frame;
    if (model.gpu_frames_seen) return null;
    return .frame_presented;
}

/// Menu-bar extra (macOS NSStatusItem): the same commands the toolbar
/// dispatches, reachable while the window is in the background.
pub const status_items = [_]native_sdk.TrayMenuItem{
    .{ .id = 1, .label = "Show Example", .command = example_command },
    .{ .id = 2, .label = "Show Docs", .command = docs_command },
    .{ .separator = true },
    .{ .id = 3, .label = "Reload Preview", .command = reload_command },
};

pub fn options() PreviewApp.Options {
    return .{
        .name = "canvas-preview",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update = update,
        .view = view,
        .web_panes = panes,
        .on_command = command,
        .on_frame = onFrame,
        .status_item = .{
            .title = "NS",
            .tooltip = "Native SDK Canvas Preview",
            .items = &status_items,
        },
    };
}

// -------------------------------------------------------------------- app

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(PreviewApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = PreviewApp.init(std.heap.page_allocator, .{}, options());
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "canvas-preview",
        .window_title = "Native SDK Canvas Preview",
        .bundle_id = "dev.native_sdk.canvas_preview",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app", "https://example.com", "https://zero-native.dev" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
