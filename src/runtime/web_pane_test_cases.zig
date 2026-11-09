const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_model = @import("ui_app.zig");
const effects_mod = @import("effects.zig");
const automation = @import("../automation/root.zig");
const zero_platform = @import("../platform/root.zig");
const null_platform_mod = @import("../platform/null_platform.zig");
const canvas_frame_helpers = @import("canvas_frame_helpers.zig");

pub fn Cases(comptime policy: ?*const fn ([]const u8, []u8) usize) type {
    return struct {
        const preview_canvas_label = "preview-canvas";
        const preview_pane_anchor = "preview-pane";
        const example_url = "https://example.com/";
        const docs_url = "https://native-sdk.dev/";

        const PreviewModel = struct {
            show_docs: bool = false,
            reload_token: u64 = 0,

            fn url(model: *const PreviewModel) []const u8 {
                return if (model.show_docs) docs_url else example_url;
            }
        };

        const PreviewMsg = union(enum) {
            show_docs,
            show_example,
            reload,
        };

        const PreviewApp = ui_app_model.UiApp(PreviewModel, PreviewMsg);

        fn previewUpdate(model: *PreviewModel, msg: PreviewMsg) void {
            switch (msg) {
                .show_docs => model.show_docs = true,
                .show_example => model.show_docs = false,
                .reload => model.reload_token += 1,
            }
        }

        fn previewView(ui: *PreviewApp.Ui, model: *const PreviewModel) PreviewApp.Ui.Node {
            _ = model;
            return ui.row(.{ .gap = 0 }, .{
                ui.column(.{ .width = 200, .padding = 12, .gap = 8 }, .{
                    ui.button(.{ .on_press = .show_docs }, "Docs"),
                    ui.button(.{ .on_press = .show_example }, "Example"),
                    ui.button(.{ .on_press = .reload }, "Reload"),
                }),
                // The empty panel that reserves the webview region: the pane
                // anchor resolves to this widget's layout frame.
                ui.panel(.{ .grow = 1, .semantics = .{ .label = preview_pane_anchor } }, .{}),
            });
        }

        fn previewPanes(model: *const PreviewModel, out: []PreviewApp.WebViewPane) usize {
            out[0] = .{
                .label = "preview",
                .anchor = preview_pane_anchor,
                .url = model.url(),
                .reload_token = model.reload_token,
            };
            return 1;
        }

        const preview_views = [_]app_manifest.ShellView{
            .{ .label = preview_canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
            .{ .label = "preview", .kind = .webview, .parent = preview_canvas_label, .url = example_url, .x = 200, .y = 0, .width = 440, .height = 480 },
        };
        const preview_windows = [_]app_manifest.ShellWindow{.{
            .label = "main",
            .title = "Preview",
            .width = 640,
            .height = 480,
            .views = &preview_views,
        }};
        const preview_scene: app_manifest.ShellConfig = .{ .windows = &preview_windows };
        const preview_origins = [_][]const u8{ "https://example.com", "https://native-sdk.dev", "zero://app", "zero://inline" };

        fn previewOptions() PreviewApp.Options {
            return .{
                .name = "ui-app-preview",
                .scene = preview_scene,
                .canvas_label = preview_canvas_label,
                .update = previewUpdate,
                .view = previewView,
                .web_panes = previewPanes,
                .web_pane_policy = policy,
            };
        }

        fn previewHarnessAndApp(app_state: *PreviewApp) !*core.TestHarness() {
            const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(640, 480) });
            errdefer harness.destroy(std.testing.allocator);
            harness.null_platform.gpu_surfaces = true;
            harness.runtime.options.security.navigation.allowed_origins = &preview_origins;

            app_state.* = PreviewApp.init(std.heap.page_allocator, .{}, previewOptions());
            const app = app_state.app();
            try harness.start(app);
            try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
                .label = preview_canvas_label,
                .size = geometry.SizeF.init(640, 480),
                .scale_factor = 1,
                .frame_index = 1,
                .timestamp_ns = 1_000_000,
                .nonblank = true,
            } });
            return harness;
        }

        fn previewNullWebView(harness: *core.TestHarness()) !null_platform_mod.NullWebView {
            for (harness.null_platform.webviews[0..harness.null_platform.webview_count]) |webview| {
                if (std.mem.eql(u8, webview.label, "preview")) return webview;
            }
            return error.TestUnexpectedResult;
        }

        pub fn case0() !void {
            const app_state = try std.testing.allocator.create(PreviewApp);
            defer std.testing.allocator.destroy(app_state);
            const harness = try previewHarnessAndApp(app_state);
            defer harness.destroy(std.testing.allocator);
            defer app_state.deinit();

            // The canvas-first scene never grows an implicit main webview: the
            // loaded source stays null and only the declared views exist.
            try std.testing.expect(harness.runtime.loaded_source == null);
            var views_buffer: [8]zero_platform.ViewInfo = undefined;
            const views = harness.runtime.listViews(1, &views_buffer);
            try std.testing.expectEqual(@as(usize, 2), views.len);
            for (views) |view| {
                try std.testing.expect(!std.mem.eql(u8, view.label, "main"));
            }
        }

        pub fn case1() !void {
            const app_state = try std.testing.allocator.create(PreviewApp);
            defer std.testing.allocator.destroy(app_state);
            const harness = try previewHarnessAndApp(app_state);
            defer harness.destroy(std.testing.allocator);
            defer app_state.deinit();

            try std.testing.expect(app_state.installed);
            const webview = try previewNullWebView(harness);
            try std.testing.expect(webview.open);
            try std.testing.expectEqualStrings(example_url, webview.url);

            // The pane frame is the anchor widget's layout frame: the row's
            // remaining width after the 200pt sidebar column.
            const layout = try harness.runtime.canvasWidgetLayout(1, preview_canvas_label);
            var anchor_frame: ?geometry.RectF = null;
            for (layout.nodes) |node| {
                if (std.mem.eql(u8, node.widget.semantics.label, preview_pane_anchor)) anchor_frame = node.frame;
            }
            try std.testing.expect(anchor_frame != null);
            try std.testing.expect(anchor_frame.?.width > 0);
            try std.testing.expectApproxEqAbs(anchor_frame.?.x, webview.frame.x, 0.5);
            try std.testing.expectApproxEqAbs(anchor_frame.?.y, webview.frame.y, 0.5);
            try std.testing.expectApproxEqAbs(anchor_frame.?.width, webview.frame.width, 0.5);
            try std.testing.expectApproxEqAbs(anchor_frame.?.height, webview.frame.height, 0.5);

            // A resize rebuild follows the anchor to its new frame.
            try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_resized = .{
                .label = preview_canvas_label,
                .window_id = 1,
                .frame = geometry.RectF.init(0, 0, 900, 600),
                .scale_factor = 1,
            } });
            const resized = try previewNullWebView(harness);
            try std.testing.expectApproxEqAbs(@as(f32, 900 - 200), resized.frame.width, 0.5);
            try std.testing.expectApproxEqAbs(@as(f32, 600), resized.frame.height, 0.5);
        }

        pub fn case2() !void {
            const app_state = try std.testing.allocator.create(PreviewApp);
            defer std.testing.allocator.destroy(app_state);
            const harness = try previewHarnessAndApp(app_state);
            defer harness.destroy(std.testing.allocator);
            defer app_state.deinit();

            const navigations_after_install = harness.null_platform.webview_navigate_count;

            // A model-driven URL change navigates the webview.
            try app_state.dispatch(&harness.runtime, 1, .show_docs);
            var webview = try previewNullWebView(harness);
            try std.testing.expectEqualStrings(docs_url, webview.url);
            try std.testing.expectEqual(navigations_after_install + 1, harness.null_platform.webview_navigate_count);

            // A rebuild without a URL change does not renavigate.
            try app_state.dispatch(&harness.runtime, 1, .show_docs);
            try std.testing.expectEqual(navigations_after_install + 1, harness.null_platform.webview_navigate_count);

            // Bumping the reload token renavigates the same URL.
            try app_state.dispatch(&harness.runtime, 1, .reload);
            webview = try previewNullWebView(harness);
            try std.testing.expectEqualStrings(docs_url, webview.url);
            try std.testing.expectEqual(navigations_after_install + 2, harness.null_platform.webview_navigate_count);
        }
    };
}
