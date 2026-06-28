const std = @import("std");
const runner = @import("runner");
const zero_native = @import("zero-native");

pub const panic = std.debug.FullPanic(zero_native.debug.capturePanic);

const canvas = zero_native.canvas;
const geometry = zero_native.geometry;

const window_width: f32 = 1240;
const window_height: f32 = 780;
const toolbar_height: f32 = 54;
const sidebar_width: f32 = 196;
const canvas_width: f32 = 720;
const statusbar_height: f32 = 34;
const max_dashboard_commands: usize = zero_native.runtime.max_canvas_commands_per_view;
const refresh_command = "dashboard.refresh";
const mode_command = "dashboard.mode";

const bg_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = color(246, 248, 252) },
    .{ .offset = 1, .color = color(229, 241, 250) },
};
const hero_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = color(18, 24, 38) },
    .{ .offset = 0.58, .color = color(27, 72, 100) },
    .{ .offset = 1, .color = color(17, 161, 153) },
};
const accent_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = color(48, 111, 237) },
    .{ .offset = 1, .color = color(16, 185, 129) },
};
const warm_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = color(248, 113, 113) },
    .{ .offset = 1, .color = color(251, 191, 36) },
};

const html =
    \\<!doctype html>
    \\<html>
    \\<head>
    \\  <meta charset="utf-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1">
    \\  <meta http-equiv="Content-Security-Policy" content="default-src 'self'; style-src 'self' 'unsafe-inline';">
    \\  <style>
    \\    :root { color-scheme: light dark; }
    \\    * { box-sizing: border-box; }
    \\    body {
    \\      margin: 0;
    \\      min-height: 100vh;
    \\      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", Segoe UI, system-ui, sans-serif;
    \\      background: #f6f7f9;
    \\      color: #171a22;
    \\    }
    \\    main {
    \\      min-height: 100vh;
    \\      padding: 28px;
    \\      display: grid;
    \\      align-content: start;
    \\      gap: 16px;
    \\    }
    \\    h1 { margin: 0; font-size: 24px; line-height: 1.15; font-weight: 660; letter-spacing: 0; }
    \\    p { margin: 0; color: #636b77; line-height: 1.5; }
    \\    .metrics {
    \\      display: grid;
    \\      grid-template-columns: repeat(2, minmax(0, 1fr));
    \\      gap: 10px;
    \\    }
    \\    .metric {
    \\      border: 1px solid #dde3eb;
    \\      border-radius: 7px;
    \\      padding: 12px;
    \\      background: white;
    \\    }
    \\    .metric strong { display: block; font-size: 20px; margin-bottom: 4px; }
    \\    .metric span { color: #697386; font-size: 12px; }
    \\    code {
    \\      display: block;
    \\      width: 100%;
    \\      overflow-wrap: anywhere;
    \\      border: 1px solid #e2e7ee;
    \\      border-radius: 7px;
    \\      padding: 12px;
    \\      background: #fbfcfe;
    \\      color: #374151;
    \\      font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    \\    }
    \\    @media (prefers-color-scheme: dark) {
    \\      body { background: #101216; color: #f4f6f8; }
    \\      p, .metric span { color: #a2aab7; }
    \\      .metric { background: #181b21; border-color: #2b3038; }
    \\      code { color: #d8dee8; background: #151820; border-color: #2c3340; }
    \\    }
    \\  </style>
    \\</head>
    \\<body>
    \\  <main>
    \\    <h1>Renderer diagnostics</h1>
    \\    <p>The dashboard canvas is registered on the native GPU surface. The WebView stays available as an inspector surface.</p>
    \\    <div class="metrics">
    \\      <div class="metric"><strong>48</strong><span>Canvas commands</span></div>
    \\      <div class="metric"><strong>8</strong><span>Renderer resources</span></div>
    \\      <div class="metric"><strong>120</strong><span>FPS target</span></div>
    \\      <div class="metric"><strong>0</strong><span>Steady-frame layout work</span></div>
    \\    </div>
    \\    <code>display-list -> frame plan -> GPU surface diagnostics</code>
    \\  </main>
    \\</body>
    \\</html>
;

const app_permissions = [_][]const u8{ zero_native.security.permission_command, zero_native.security.permission_view };
const shell_views = [_]zero_native.ShellView{
    .{ .label = "toolbar", .kind = .toolbar, .edge = .top, .height = toolbar_height, .layer = 30, .role = "Toolbar" },
    .{ .label = "toolbar-title", .kind = .label, .parent = "toolbar", .x = 18, .y = 17, .width = 220, .height = 20, .layer = 31, .text = "GPU Dashboard" },
    .{ .label = "view-mode", .kind = .segmented_control, .parent = "toolbar", .x = 252, .y = 12, .width = 214, .height = 30, .layer = 31, .text = "Overview|Revenue|Latency", .command = mode_command },
    .{ .label = "refresh", .kind = .button, .parent = "toolbar", .x = 484, .y = 12, .width = 86, .height = 30, .layer = 31, .text = "Refresh", .command = refresh_command },
    .{ .label = "body", .kind = .split, .fill = true, .axis = .row },
    .{ .label = "sidebar", .kind = .sidebar, .parent = "body", .width = sidebar_width, .min_width = 180, .max_width = 240, .layer = 10, .role = "Navigation" },
    .{ .label = "sidebar-title", .kind = .label, .parent = "sidebar", .x = 18, .y = 22, .width = 150, .height = 20, .layer = 11, .text = "Northstar" },
    .{ .label = "nav-overview", .kind = .list_item, .parent = "sidebar", .x = 14, .y = 64, .width = 166, .height = 32, .layer = 11, .text = "Overview" },
    .{ .label = "nav-customers", .kind = .list_item, .parent = "sidebar", .x = 14, .y = 102, .width = 166, .height = 32, .layer = 11, .text = "Customers" },
    .{ .label = "nav-latency", .kind = .list_item, .parent = "sidebar", .x = 14, .y = 140, .width = 166, .height = 32, .layer = 11, .text = "Latency" },
    .{ .label = "sidebar-status", .kind = .label, .parent = "sidebar", .x = 18, .y = 690, .width = 150, .height = 20, .layer = 11, .text = "Native shell" },
    .{ .label = "dashboard-canvas", .kind = .gpu_surface, .parent = "body", .width = canvas_width, .min_width = 560, .layer = 12, .role = "Native-rendered dashboard canvas", .accessibility_label = "Native-rendered product dashboard canvas" },
    .{ .label = "inspector", .kind = .webview, .parent = "body", .url = "zero://inline", .fill = true },
    .{ .label = "statusbar", .kind = .statusbar, .edge = .bottom, .height = statusbar_height, .layer = 30, .role = "Status" },
    .{ .label = "status-label", .kind = .label, .parent = "statusbar", .x = 14, .y = 8, .width = 840, .height = 18, .layer = 31, .text = "Canvas scene waiting for the first GPU frame." },
};
const shell_windows = [_]zero_native.ShellWindow{.{
    .label = "main",
    .title = "zero-native GPU Dashboard",
    .width = window_width,
    .height = window_height,
    .views = &shell_views,
}};
const shell_scene: zero_native.ShellConfig = .{ .windows = &shell_windows };

const GpuDashboardApp = struct {
    refresh_count: u32 = 0,
    mode_count: u32 = 0,
    canvas_installed: bool = false,
    reported_planned_frame: bool = false,

    fn app(self: *@This()) zero_native.App {
        return .{
            .context = self,
            .name = "gpu-dashboard",
            .source = zero_native.WebViewSource.html(html),
            .scene_fn = scene,
            .event_fn = event,
        };
    }

    fn scene(context: *anyopaque) anyerror!zero_native.ShellConfig {
        _ = context;
        return shell_scene;
    }

    fn event(context: *anyopaque, runtime: *zero_native.Runtime, event_value: zero_native.Event) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        switch (event_value) {
            .command => |command| {
                if (std.mem.eql(u8, command.name, refresh_command)) {
                    try self.refresh(runtime, command);
                } else if (std.mem.eql(u8, command.name, mode_command)) {
                    try self.toggleMode(runtime, command);
                }
            },
            .gpu_surface_frame => |frame_event| try self.handleGpuFrame(runtime, frame_event),
            .gpu_surface_resized, .gpu_surface_input, .shortcut, .files_dropped, .canvas_widget_pointer, .canvas_widget_keyboard, .lifecycle => {},
        }
    }

    fn handleGpuFrame(self: *@This(), runtime: *zero_native.Runtime, frame_event: zero_native.GpuSurfaceFrameEvent) anyerror!void {
        if (!std.mem.eql(u8, frame_event.label, "dashboard-canvas")) return;
        if (!self.canvas_installed) {
            try self.installDashboardCanvas(runtime, frame_event.window_id);
            try self.updateStatus(runtime, frame_event.window_id, "Dashboard display list installed on the GPU surface.");
            return;
        }

        if (!self.reported_planned_frame and frame_event.canvas_command_count > 0) {
            self.reported_planned_frame = true;
            var status_buffer: [192]u8 = undefined;
            const status = try std.fmt.bufPrint(
                &status_buffer,
                "Canvas frame planned: {d} commands, {d} batches, {d} resources.",
                .{ frame_event.canvas_command_count, frame_event.canvas_frame_batch_count, frame_event.canvas_frame_resource_count },
            );
            try self.updateStatus(runtime, frame_event.window_id, status);
        }
    }

    fn installDashboardCanvas(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId) anyerror!void {
        var commands: [max_dashboard_commands]canvas.CanvasCommand = undefined;
        var builder = canvas.Builder.init(&commands);
        try buildDashboardDisplayList(&builder);
        _ = try runtime.setCanvasDisplayList(window_id, "dashboard-canvas", builder.displayList());
        self.canvas_installed = true;
    }

    fn updateStatus(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId, text: []const u8) anyerror!void {
        _ = self;
        _ = try runtime.updateView(window_id, "status-label", .{ .text = text });
    }

    fn refresh(self: *@This(), runtime: *zero_native.Runtime, command: zero_native.CommandEvent) anyerror!void {
        self.refresh_count += 1;
        self.reported_planned_frame = false;
        var commands: [max_dashboard_commands]canvas.CanvasCommand = undefined;
        var builder = canvas.Builder.init(&commands);
        try buildDashboardDisplayList(&builder);
        _ = try runtime.setCanvasDisplayList(command.window_id, "dashboard-canvas", builder.displayList());

        var status_buffer: [160]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buffer, "Dashboard canvas refreshed from {s}. Count {d}.", .{ @tagName(command.source), self.refresh_count });
        try self.updateStatus(runtime, command.window_id, status);
    }

    fn toggleMode(self: *@This(), runtime: *zero_native.Runtime, command: zero_native.CommandEvent) anyerror!void {
        self.mode_count += 1;
        var status_buffer: [160]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buffer, "Dashboard mode changed from {s}. Count {d}.", .{ @tagName(command.source), self.mode_count });
        try self.updateStatus(runtime, command.window_id, status);
    }
};

fn buildDashboardDisplayList(builder: *canvas.Builder) canvas.Error!void {
    try builder.fillRect(.{ .id = 1, .rect = rect(0, 0, 720, 520), .fill = .{ .linear_gradient = .{ .start = pt(0, 0), .end = pt(720, 520), .stops = &bg_stops } } });
    try builder.shadow(.{ .id = 2, .rect = rect(24, 24, 672, 472), .radius = canvas.Radius.all(22), .offset = .{ .dx = 0, .dy = 24 }, .blur = 48, .spread = -12, .color = canvas.Color.rgba8(16, 24, 40, 42) });
    try builder.fillRoundedRect(.{ .id = 3, .rect = rect(24, 24, 672, 472), .radius = canvas.Radius.all(22), .fill = .{ .color = color(255, 255, 255) } });
    try builder.fillRoundedRect(.{ .id = 4, .rect = rect(38, 38, 158, 444), .radius = canvas.Radius.all(16), .fill = .{ .linear_gradient = .{ .start = pt(38, 38), .end = pt(196, 482), .stops = &hero_stops } } });
    try builder.drawText(.{ .id = 5, .font_id = 1, .size = 18, .origin = pt(58, 78), .color = color(247, 250, 252), .text = "Northstar" });
    try builder.drawText(.{ .id = 6, .font_id = 1, .size = 11, .origin = pt(58, 104), .color = rgba(214, 226, 240, 220), .text = "Native GPU UI" });
    try builder.fillRoundedRect(.{ .id = 7, .rect = rect(54, 136, 126, 34), .radius = canvas.Radius.all(9), .fill = .{ .color = rgba(255, 255, 255, 34) } });
    try builder.drawText(.{ .id = 8, .font_id = 1, .size = 12, .origin = pt(70, 158), .color = color(255, 255, 255), .text = "Overview" });
    try builder.drawText(.{ .id = 9, .font_id = 1, .size = 12, .origin = pt(70, 203), .color = rgba(226, 236, 246, 210), .text = "Customers" });
    try builder.drawText(.{ .id = 10, .font_id = 1, .size = 12, .origin = pt(70, 246), .color = rgba(226, 236, 246, 210), .text = "Latency" });
    try builder.fillRoundedRect(.{ .id = 11, .rect = rect(58, 420, 104, 8), .radius = canvas.Radius.all(4), .fill = .{ .color = rgba(255, 255, 255, 42) } });
    try builder.fillRoundedRect(.{ .id = 12, .rect = rect(58, 420, 74, 8), .radius = canvas.Radius.all(4), .fill = .{ .color = color(52, 211, 153) } });
    try builder.drawText(.{ .id = 13, .font_id = 1, .size = 10, .origin = pt(58, 450), .color = rgba(226, 236, 246, 210), .text = "120 FPS path" });

    try builder.drawText(.{ .id = 14, .font_id = 1, .size = 24, .origin = pt(226, 74), .color = color(18, 24, 38), .text = "Revenue pulse" });
    try builder.drawText(.{ .id = 15, .font_id = 1, .size = 12, .origin = pt(226, 100), .color = color(100, 112, 132), .text = "Retained canvas dashboard" });
    try builder.fillRoundedRect(.{ .id = 16, .rect = rect(522, 50, 128, 34), .radius = canvas.Radius.all(10), .fill = .{ .linear_gradient = .{ .start = pt(522, 50), .end = pt(650, 84), .stops = &accent_stops } } });
    try builder.drawText(.{ .id = 17, .font_id = 1, .size = 12, .origin = pt(546, 72), .color = color(255, 255, 255), .text = "Live render" });

    try metricCard(builder, 18, rect(226, 128, 130, 96), "ARR", "$12.8M", "+18.4%", color(48, 111, 237));
    try metricCard(builder, 25, rect(372, 128, 130, 96), "Activation", "74.2%", "+6.1%", color(17, 161, 153));
    try metricCard(builder, 32, rect(518, 128, 130, 96), "Latency", "8.6ms", "-2.4ms", color(248, 113, 113));

    try builder.shadow(.{ .id = 39, .rect = rect(226, 248, 422, 190), .radius = canvas.Radius.all(18), .offset = .{ .dx = 0, .dy = 14 }, .blur = 34, .spread = -12, .color = canvas.Color.rgba8(16, 24, 40, 26) });
    try builder.fillRoundedRect(.{ .id = 40, .rect = rect(226, 248, 422, 190), .radius = canvas.Radius.all(18), .fill = .{ .color = color(255, 255, 255) } });
    try builder.drawText(.{ .id = 41, .font_id = 1, .size = 14, .origin = pt(250, 282), .color = color(18, 24, 38), .text = "Conversion trend" });
    try builder.drawLine(.{ .id = 42, .from = pt(252, 392), .to = pt(618, 392), .stroke = .{ .fill = .{ .color = color(226, 232, 240) }, .width = 1 } });
    try builder.drawLine(.{ .id = 43, .from = pt(262, 362), .to = pt(332, 326), .stroke = .{ .fill = .{ .linear_gradient = .{ .start = pt(262, 362), .end = pt(612, 294), .stops = &accent_stops } }, .width = 4 } });
    try builder.drawLine(.{ .id = 44, .from = pt(332, 326), .to = pt(402, 346), .stroke = .{ .fill = .{ .linear_gradient = .{ .start = pt(262, 362), .end = pt(612, 294), .stops = &accent_stops } }, .width = 4 } });
    try builder.drawLine(.{ .id = 45, .from = pt(402, 346), .to = pt(482, 304), .stroke = .{ .fill = .{ .linear_gradient = .{ .start = pt(262, 362), .end = pt(612, 294), .stops = &accent_stops } }, .width = 4 } });
    try builder.drawLine(.{ .id = 46, .from = pt(482, 304), .to = pt(612, 292), .stroke = .{ .fill = .{ .linear_gradient = .{ .start = pt(262, 362), .end = pt(612, 294), .stops = &accent_stops } }, .width = 4 } });

    try builder.fillRoundedRect(.{ .id = 47, .rect = rect(250, 454, 86, 12), .radius = canvas.Radius.all(6), .fill = .{ .linear_gradient = .{ .start = pt(250, 454), .end = pt(336, 454), .stops = &warm_stops } } });
    try builder.fillRoundedRect(.{ .id = 48, .rect = rect(350, 454, 156, 12), .radius = canvas.Radius.all(6), .fill = .{ .linear_gradient = .{ .start = pt(350, 454), .end = pt(506, 454), .stops = &accent_stops } } });
}

fn metricCard(builder: *canvas.Builder, comptime start_id: canvas.ObjectId, frame: geometry.RectF, label: []const u8, value: []const u8, delta: []const u8, accent: canvas.Color) canvas.Error!void {
    try builder.shadow(.{ .id = start_id, .rect = frame, .radius = canvas.Radius.all(16), .offset = .{ .dx = 0, .dy = 12 }, .blur = 28, .spread = -10, .color = canvas.Color.rgba8(16, 24, 40, 24) });
    try builder.fillRoundedRect(.{ .id = start_id + 1, .rect = frame, .radius = canvas.Radius.all(16), .fill = .{ .color = color(255, 255, 255) } });
    try builder.fillRoundedRect(.{ .id = start_id + 2, .rect = rect(frame.x + 16, frame.y + 16, 28, 5), .radius = canvas.Radius.all(3), .fill = .{ .color = accent } });
    try builder.drawText(.{ .id = start_id + 3, .font_id = 1, .size = 11, .origin = pt(frame.x + 16, frame.y + 42), .color = color(100, 112, 132), .text = label });
    try builder.drawText(.{ .id = start_id + 4, .font_id = 1, .size = 20, .origin = pt(frame.x + 16, frame.y + 68), .color = color(18, 24, 38), .text = value });
    try builder.drawText(.{ .id = start_id + 5, .font_id = 1, .size = 11, .origin = pt(frame.x + 78, frame.y + 68), .color = accent, .text = delta });
    try builder.strokeRect(.{ .id = start_id + 6, .rect = frame, .radius = canvas.Radius.all(16), .stroke = .{ .fill = .{ .color = color(226, 232, 240) }, .width = 1 } });
}

fn dashboardFrame(display_list: canvas.DisplayList, previous: ?canvas.DisplayList, options: canvas.CanvasFrameOptions, storage: canvas.CanvasFrameStorage) canvas.Error!canvas.CanvasFrame {
    return display_list.framePlan(previous, options, storage);
}

fn dashboardFrameStorage(
    render_commands: []canvas.RenderCommand,
    render_batches: []canvas.RenderBatch,
    resources: []canvas.RenderResource,
    cache_entries: []canvas.RenderResourceCacheEntry,
    cache_actions: []canvas.RenderResourceCacheAction,
    glyphs: []canvas.GlyphAtlasEntry,
    changes: []canvas.DiffChange,
) canvas.CanvasFrameStorage {
    return .{
        .render_commands = render_commands,
        .render_batches = render_batches,
        .resources = resources,
        .resource_cache_entries = cache_entries,
        .resource_cache_actions = cache_actions,
        .glyph_atlas_entries = glyphs,
        .changes = changes,
    };
}

fn color(r: u8, g: u8, b: u8) canvas.Color {
    return canvas.Color.rgb8(r, g, b);
}

fn rgba(r: u8, g: u8, b: u8, a: u8) canvas.Color {
    return canvas.Color.rgba8(r, g, b, a);
}

fn rect(x: f32, y: f32, width: f32, height: f32) geometry.RectF {
    return geometry.RectF.init(x, y, width, height);
}

fn pt(x: f32, y: f32) geometry.PointF {
    return geometry.PointF.init(x, y);
}

pub fn main(init: std.process.Init) !void {
    var app = GpuDashboardApp{};
    try runner.runWithOptions(app.app(), .{
        .app_name = "gpu-dashboard",
        .window_title = "zero-native GPU Dashboard",
        .bundle_id = "dev.zero_native.gpu_dashboard",
        .icon_path = "assets/icon.icns",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test "gpu dashboard scene declares native shell gpu canvas and inspector" {
    try std.testing.expect(shell_views[5].kind == .sidebar);
    try std.testing.expect(shell_views[11].kind == .gpu_surface);
    try std.testing.expect(shell_views[12].kind == .webview);
    try std.testing.expectEqualStrings("body", shell_views[11].parent.?);
    try std.testing.expectEqualStrings("body", shell_views[12].parent.?);
}

test "gpu dashboard display list builds a complete canvas scene" {
    var commands: [max_dashboard_commands]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try buildDashboardDisplayList(&builder);
    const display_list = builder.displayList();

    try std.testing.expectEqual(@as(usize, 48), display_list.commandCount());
    try std.testing.expect(display_list.findCommandById(1) != null);
    try std.testing.expect(display_list.findCommandById(48) != null);
    const bounds = display_list.bounds().?;
    try std.testing.expect(bounds.x <= 0);
    try std.testing.expect(bounds.y <= 0);
    try std.testing.expect(bounds.width >= 720);
    try std.testing.expect(bounds.height >= 520);
}

test "gpu dashboard display list renders through the reference surface" {
    var commands: [max_dashboard_commands]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try buildDashboardDisplayList(&builder);
    const display_list = builder.displayList();

    var render_commands: [max_dashboard_commands]canvas.RenderCommand = undefined;
    var render_batches: [max_dashboard_commands]canvas.RenderBatch = undefined;
    var resources: [max_dashboard_commands]canvas.RenderResource = undefined;
    var cache_entries: [max_dashboard_commands]canvas.RenderResourceCacheEntry = undefined;
    var cache_actions: [max_dashboard_commands * 2]canvas.RenderResourceCacheAction = undefined;
    var glyphs: [zero_native.runtime.max_canvas_glyphs_per_view]canvas.GlyphAtlasEntry = undefined;
    var changes: [max_dashboard_commands * 2 + 1]canvas.DiffChange = undefined;
    const frame = try dashboardFrame(display_list, null, .{
        .surface_size = geometry.SizeF.init(720, 520),
        .full_repaint = true,
    }, dashboardFrameStorage(&render_commands, &render_batches, &resources, &cache_entries, &cache_actions, &glyphs, &changes));

    try std.testing.expect(frame.requiresRender());
    try std.testing.expect(frame.batch_plan.batchCount() >= 8);
    try std.testing.expect(frame.resource_plan.resourceCount() >= 8);

    const pixel_count = 720 * 520 * 4;
    const pixels = try std.testing.allocator.alloc(u8, pixel_count);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0);
    const surface = try canvas.ReferenceRenderSurface.init(720, 520, pixels);
    try surface.renderPass(frame.renderPass(), color(0, 0, 0));

    try expectVisiblePixel(surface.pixelRgba8(8, 8));
    try expectVisiblePixel(surface.pixelRgba8(64, 64));
    try expectVisiblePixel(surface.pixelRgba8(240, 140));
    try std.testing.expectEqual(@as(u8, 255), surface.pixelRgba8(236, 134)[3]);
}

test "gpu dashboard render overrides animate without rebuilding commands" {
    var commands: [max_dashboard_commands]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try buildDashboardDisplayList(&builder);
    const display_list = builder.displayList();

    const animations = [_]canvas.CanvasRenderAnimation{.{
        .id = 16,
        .start_ns = 1_000_000_000,
        .duration_ms = 800,
        .from_opacity = 0.72,
        .to_opacity = 1,
        .from_transform = canvas.Affine.translate(0, -6),
        .to_transform = canvas.Affine.identity(),
    }};
    var overrides: [1]canvas.CanvasRenderOverride = undefined;
    const sampled = try canvas.sampleCanvasRenderAnimations(&animations, 1_400_000_000, &overrides);
    try std.testing.expectEqual(@as(usize, 1), sampled.len);

    var render_commands: [max_dashboard_commands]canvas.RenderCommand = undefined;
    var render_batches: [max_dashboard_commands]canvas.RenderBatch = undefined;
    var resources: [max_dashboard_commands]canvas.RenderResource = undefined;
    var cache_entries: [max_dashboard_commands]canvas.RenderResourceCacheEntry = undefined;
    var cache_actions: [max_dashboard_commands * 2]canvas.RenderResourceCacheAction = undefined;
    var glyphs: [zero_native.runtime.max_canvas_glyphs_per_view]canvas.GlyphAtlasEntry = undefined;
    var changes: [max_dashboard_commands * 2 + 1]canvas.DiffChange = undefined;

    const frame = try dashboardFrame(display_list, display_list, .{
        .surface_size = geometry.SizeF.init(720, 520),
        .render_overrides = sampled,
    }, dashboardFrameStorage(&render_commands, &render_batches, &resources, &cache_entries, &cache_actions, &glyphs, &changes));

    try std.testing.expect(frame.requiresRender());
    try std.testing.expectEqual(@as(usize, 0), frame.changes.len);
    try std.testing.expect(frame.dirty_bounds != null);
}

test "gpu dashboard app registers canvas display list on first gpu frame" {
    var harness: zero_native.TestHarness() = undefined;
    harness.init(.{ .size = geometry.SizeF.init(window_width, window_height) });
    harness.null_platform.gpu_surfaces = true;

    var app = GpuDashboardApp{};
    try harness.start(app.app());

    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_frame = .{
        .label = "dashboard-canvas",
        .size = geometry.SizeF.init(720, 520),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app.canvas_installed);

    const display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try std.testing.expectEqual(@as(usize, 48), display_list.commandCount());

    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_frame = .{
        .label = "dashboard-canvas",
        .size = geometry.SizeF.init(720, 520),
        .scale_factor = 2,
        .frame_index = 2,
        .timestamp_ns = 1_016_000_000,
        .nonblank = true,
    } });

    const frame = try harness.runtime.gpuSurfaceFrame(1, "dashboard-canvas");
    try std.testing.expectEqual(@as(u64, 1), frame.canvas_revision);
    try std.testing.expectEqual(@as(usize, 48), frame.canvas_command_count);
    try std.testing.expect(frame.canvas_frame_requires_render);
    try std.testing.expect(!frame.canvas_frame_full_repaint);
    try std.testing.expect(frame.canvas_frame_batch_count >= 8);
}

fn expectVisiblePixel(pixel: [4]u8) !void {
    try std.testing.expect(pixel[3] > 0);
    try std.testing.expect(pixel[0] != 0 or pixel[1] != 0 or pixel[2] != 0);
}
