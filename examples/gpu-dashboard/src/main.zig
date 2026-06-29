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
const max_dashboard_pipelines: usize = 8;
const max_dashboard_commands: usize = zero_native.runtime.max_canvas_commands_per_view;
const max_dashboard_glyphs: usize = zero_native.runtime.max_canvas_glyphs_per_view;
const max_dashboard_widgets: usize = 40;
const dashboard_chrome_prefix_commands: usize = 4;
const dashboard_chrome_suffix_commands: usize = 0;
const refresh_command = "dashboard.refresh";
const mode_command = "dashboard.mode";
const live_button_fill_command_id: canvas.ObjectId = 103 * 16 + 1;
const live_button_text_command_id: canvas.ObjectId = 103 * 16 + 4;
const forecast_text_command_id: canvas.ObjectId = 131 * 16 + 4;
const forecast_composition_command_id: canvas.ObjectId = 131 * 16 + 5;
const confidence_active_command_id: canvas.ObjectId = 134 * 16 + 2;
const deployment_region_text_command_id: canvas.ObjectId = 156 * 16 + 4;
const overview_fill_command_id: canvas.ObjectId = 111 * 16 + 1;
const customers_fill_command_id: canvas.ObjectId = 112 * 16 + 1;
const activity_scroll_track_command_id: canvas.ObjectId = 120 * 16 + 2;
const activity_scroll_thumb_command_id: canvas.ObjectId = 120 * 16 + 3;
const activity_first_text_command_id: canvas.ObjectId = 121 * 16 + 3;
const filter_popover_blur_command_id: canvas.ObjectId = 140 * 16 + 12;
const dashboard_glass_blur: f32 = 14;

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
    \\      <div class="metric"><strong>retained</strong><span>Widget-emitted scene</span></div>
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
    .{ .label = "dashboard-canvas", .kind = .gpu_surface, .parent = "body", .width = canvas_width, .min_width = 560, .layer = 12, .role = "Native-rendered dashboard canvas", .accessibility_label = "Native-rendered product dashboard canvas", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
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
    pixels: ?[]u8 = null,
    scratch: ?[]u8 = null,
    render_commands: [max_dashboard_commands]canvas.RenderCommand = undefined,
    render_batches: [max_dashboard_commands]canvas.RenderBatch = undefined,
    pipeline_cache_entries: [max_dashboard_pipelines]canvas.RenderPipelineCacheEntry = undefined,
    pipeline_cache_actions: [max_dashboard_pipelines * 2]canvas.RenderPipelineCacheAction = undefined,
    layers: [max_dashboard_commands]canvas.RenderLayer = undefined,
    layer_cache_entries: [max_dashboard_commands]canvas.RenderLayerCacheEntry = undefined,
    layer_cache_actions: [max_dashboard_commands * 2]canvas.RenderLayerCacheAction = undefined,
    resources: [max_dashboard_commands]canvas.RenderResource = undefined,
    cache_entries: [max_dashboard_commands]canvas.RenderResourceCacheEntry = undefined,
    cache_actions: [max_dashboard_commands * 2]canvas.RenderResourceCacheAction = undefined,
    visual_effects: [max_dashboard_commands]canvas.VisualEffect = undefined,
    visual_effect_cache_entries: [max_dashboard_commands]canvas.VisualEffectCacheEntry = undefined,
    visual_effect_cache_actions: [max_dashboard_commands * 2]canvas.VisualEffectCacheAction = undefined,
    glyphs: [max_dashboard_glyphs]canvas.GlyphAtlasEntry = undefined,
    glyph_cache_entries: [max_dashboard_glyphs]canvas.GlyphAtlasCacheEntry = undefined,
    glyph_cache_actions: [max_dashboard_glyphs * 2]canvas.GlyphAtlasCacheAction = undefined,
    text_layout_plans: [max_dashboard_commands]canvas.TextLayoutPlan = undefined,
    text_layout_lines: [max_dashboard_glyphs]canvas.TextLine = undefined,
    text_layout_cache_entries: [max_dashboard_commands]canvas.TextLayoutCacheEntry = undefined,
    text_layout_cache_actions: [max_dashboard_commands * 2]canvas.TextLayoutCacheAction = undefined,
    changes: [max_dashboard_commands * 2 + 1]canvas.DiffChange = undefined,

    fn app(self: *@This()) zero_native.App {
        return .{
            .context = self,
            .name = "gpu-dashboard",
            .source = zero_native.WebViewSource.html(html),
            .scene_fn = scene,
            .event_fn = event,
            .stop_fn = stop,
        };
    }

    fn deinit(self: *@This()) void {
        if (self.pixels) |pixels| std.heap.page_allocator.free(pixels);
        if (self.scratch) |scratch| std.heap.page_allocator.free(scratch);
        self.pixels = null;
        self.scratch = null;
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
            .gpu_surface_resized, .gpu_surface_input, .shortcut, .files_dropped, .canvas_widget_pointer, .canvas_widget_keyboard, .canvas_widget_file_drop, .canvas_widget_drag, .lifecycle => {},
        }
    }

    fn stop(context: *anyopaque, runtime: *zero_native.Runtime) anyerror!void {
        _ = runtime;
        const self: *@This() = @ptrCast(@alignCast(context));
        self.deinit();
    }

    fn handleGpuFrame(self: *@This(), runtime: *zero_native.Runtime, frame_event: zero_native.GpuSurfaceFrameEvent) anyerror!void {
        if (!std.mem.eql(u8, frame_event.label, "dashboard-canvas")) return;
        if (!self.canvas_installed) {
            try self.installDashboardCanvas(runtime, frame_event);
            try self.updateStatus(runtime, frame_event.window_id, "Dashboard display list presented on the GPU surface.");
            return;
        }

        _ = try self.presentDashboardCanvas(runtime, frame_event, frame_event.canvas_frame_full_repaint);

        if (!self.reported_planned_frame and frame_event.canvas_command_count > 0) {
            self.reported_planned_frame = true;
            var status_buffer: [192]u8 = undefined;
            const status = try dashboardFrameStatus(&status_buffer, frame_event);
            try self.updateStatus(runtime, frame_event.window_id, status);
        }
    }

    fn installDashboardCanvas(self: *@This(), runtime: *zero_native.Runtime, frame_event: zero_native.GpuSurfaceFrameEvent) anyerror!void {
        try installDashboardCanvasModel(runtime, frame_event.window_id);
        try self.scheduleDashboardAnimations(runtime, frame_event.window_id, frame_event.timestamp_ns);
        _ = try self.presentDashboardCanvas(runtime, frame_event, true);
        self.canvas_installed = true;
    }

    fn updateStatus(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId, text: []const u8) anyerror!void {
        _ = self;
        _ = try runtime.updateView(window_id, "status-label", .{ .text = text });
    }

    fn refresh(self: *@This(), runtime: *zero_native.Runtime, command: zero_native.CommandEvent) anyerror!void {
        self.refresh_count += 1;
        self.reported_planned_frame = false;
        try installDashboardCanvasModel(runtime, command.window_id);
        const gpu_frame = try runtime.gpuSurfaceFrame(command.window_id, "dashboard-canvas");
        try self.scheduleDashboardAnimations(runtime, command.window_id, gpu_frame.timestamp_ns);
        _ = try self.presentDashboardCanvas(runtime, gpuFrameEvent(gpu_frame), true);

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

    fn presentDashboardCanvas(self: *@This(), runtime: *zero_native.Runtime, frame_event: zero_native.GpuSurfaceFrameEvent, full_repaint: bool) anyerror!canvas.CanvasFrame {
        const surface_size = if (frame_event.size.isEmpty()) geometry.SizeF.init(canvas_width, window_height - toolbar_height - statusbar_height) else frame_event.size;
        const scale_factor = if (frame_event.scale_factor > 0) frame_event.scale_factor else 1;
        try self.ensurePixelBuffers(surface_size, scale_factor);
        return try runtime.presentNextCanvasFramePixels(
            frame_event.window_id,
            "dashboard-canvas",
            .{
                .frame_index = frame_event.frame_index,
                .timestamp_ns = frame_event.timestamp_ns,
                .surface_size = surface_size,
                .scale = scale_factor,
                .full_repaint = full_repaint,
            },
            self.frameStorage(),
            self.pixels.?,
            self.scratch.?,
            color(246, 248, 252),
        );
    }

    fn scheduleDashboardAnimations(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId, start_ns: u64) anyerror!void {
        _ = self;
        const motion = dashboardWidgetTokens().motion;
        const animations = [_]canvas.CanvasRenderAnimation{
            motion.animation(.{
                .id = live_button_fill_command_id,
                .start_ns = start_ns,
                .duration = .slow,
                .from_opacity = 0.72,
                .to_opacity = 1,
                .from_transform = canvas.Affine.translate(0, -7),
                .to_transform = canvas.Affine.identity(),
            }),
            motion.animation(.{
                .id = live_button_text_command_id,
                .start_ns = start_ns,
                .duration = .slow,
                .from_opacity = 0.72,
                .to_opacity = 1,
                .from_transform = canvas.Affine.translate(0, -7),
                .to_transform = canvas.Affine.identity(),
            }),
        };
        _ = try runtime.setCanvasRenderAnimations(window_id, "dashboard-canvas", &animations);
    }

    fn frameStorage(self: *@This()) canvas.CanvasFrameStorage {
        return .{
            .render_commands = &self.render_commands,
            .render_batches = &self.render_batches,
            .pipeline_cache_entries = &self.pipeline_cache_entries,
            .pipeline_cache_actions = &self.pipeline_cache_actions,
            .layers = &self.layers,
            .layer_cache_entries = &self.layer_cache_entries,
            .layer_cache_actions = &self.layer_cache_actions,
            .resources = &self.resources,
            .resource_cache_entries = &self.cache_entries,
            .resource_cache_actions = &self.cache_actions,
            .visual_effects = &self.visual_effects,
            .visual_effect_cache_entries = &self.visual_effect_cache_entries,
            .visual_effect_cache_actions = &self.visual_effect_cache_actions,
            .glyph_atlas_entries = &self.glyphs,
            .glyph_atlas_cache_entries = &self.glyph_cache_entries,
            .glyph_atlas_cache_actions = &self.glyph_cache_actions,
            .text_layout_plans = &self.text_layout_plans,
            .text_layout_lines = &self.text_layout_lines,
            .text_layout_cache_entries = &self.text_layout_cache_entries,
            .text_layout_cache_actions = &self.text_layout_cache_actions,
            .changes = &self.changes,
        };
    }

    fn ensurePixelBuffers(self: *@This(), surface_size: geometry.SizeF, scale_factor: f32) anyerror!void {
        const pixel_size = try zero_native.runtime.canvasSurfacePixelSize(surface_size, scale_factor);
        if (self.pixels == null or self.pixels.?.len < pixel_size.byte_len) {
            if (self.pixels) |pixels| std.heap.page_allocator.free(pixels);
            self.pixels = try std.heap.page_allocator.alloc(u8, pixel_size.byte_len);
        }
        if (self.scratch == null or self.scratch.?.len < pixel_size.byte_len) {
            if (self.scratch) |scratch| std.heap.page_allocator.free(scratch);
            self.scratch = try std.heap.page_allocator.alloc(u8, pixel_size.byte_len);
        }
    }
};

fn installDashboardCanvasModel(runtime: *zero_native.Runtime, window_id: zero_native.WindowId) anyerror!void {
    var commands: [max_dashboard_commands]canvas.CanvasCommand = undefined;
    var nodes: [max_dashboard_widgets]canvas.WidgetLayoutNode = undefined;
    var builder = canvas.Builder.init(&commands);
    const layout = try buildDashboardWidgetLayout(&nodes);
    try buildDashboardDisplayList(&builder, layout);
    _ = try runtime.setCanvasDisplayList(window_id, "dashboard-canvas", builder.displayList());
    _ = try runtime.setCanvasWidgetLayout(window_id, "dashboard-canvas", layout);
    _ = try runtime.emitCanvasWidgetDisplayListWithChrome(window_id, "dashboard-canvas", dashboardWidgetTokens(), .{
        .prefix_command_count = dashboard_chrome_prefix_commands,
        .suffix_command_count = dashboard_chrome_suffix_commands,
    });
}

fn buildDashboardDisplayListFromWidgets(builder: *canvas.Builder) canvas.Error!void {
    var nodes: [max_dashboard_widgets]canvas.WidgetLayoutNode = undefined;
    const layout = try buildDashboardWidgetLayout(&nodes);
    try buildDashboardDisplayList(builder, layout);
}

fn buildDashboardDisplayList(builder: *canvas.Builder, layout: canvas.WidgetLayoutTree) canvas.Error!void {
    try builder.fillRect(.{ .id = 1, .rect = rect(0, 0, 720, 520), .fill = .{ .linear_gradient = .{ .start = pt(0, 0), .end = pt(720, 520), .stops = &bg_stops } } });
    try builder.shadow(.{ .id = 2, .rect = rect(24, 24, 672, 472), .radius = canvas.Radius.all(22), .offset = .{ .dx = 0, .dy = 24 }, .blur = 48, .spread = -12, .color = canvas.Color.rgba8(16, 24, 40, 42) });
    try builder.fillRoundedRect(.{ .id = 3, .rect = rect(24, 24, 672, 472), .radius = canvas.Radius.all(22), .fill = .{ .color = color(255, 255, 255) } });
    try builder.fillRoundedRect(.{ .id = 4, .rect = rect(38, 38, 158, 444), .radius = canvas.Radius.all(16), .fill = .{ .linear_gradient = .{ .start = pt(38, 38), .end = pt(196, 482), .stops = &hero_stops } } });

    try layout.emitDisplayList(builder, dashboardWidgetTokens());
}

fn dashboardWidgetTokens() canvas.DesignTokens {
    return .{
        .colors = .{
            .surface = rgba(255, 255, 255, 236),
            .surface_subtle = color(248, 250, 252),
            .surface_pressed = rgba(48, 111, 237, 24),
            .text = color(18, 24, 38),
            .text_muted = color(100, 112, 132),
            .border = color(226, 232, 240),
            .accent = color(48, 111, 237),
            .accent_text = color(255, 255, 255),
            .focus_ring = color(37, 99, 235),
            .shadow = canvas.Color.rgba8(16, 24, 40, 24),
            .disabled = color(226, 232, 240),
        },
        .typography = .{
            .font_id = 1,
            .body_size = 12,
            .label_size = 11,
            .title_size = 20,
            .button_size = 12,
        },
        .radius = .{
            .sm = 4,
            .md = 8,
            .lg = 16,
            .xl = 18,
        },
        .shadow = .{
            .sm = .{ .y = 10, .blur = 26, .spread = -12 },
            .md = .{ .y = 18, .blur = 42, .spread = -18 },
        },
        .motion = .{
            .slow_ms = 900,
            .easing = .emphasized,
        },
    };
}

fn buildDashboardWidgetLayout(nodes: []canvas.WidgetLayoutNode) canvas.Error!canvas.WidgetLayoutTree {
    const metric_items = [_]canvas.Widget{
        .{ .id = 105, .kind = .list_item, .text = "ARR $12.8M, up 18.4%" },
        .{ .id = 106, .kind = .list_item, .text = "Activation 74.2%, up 6.1%" },
    };
    const nav_items = [_]canvas.Widget{
        .{ .id = 111, .kind = .list_item, .text = "Overview", .state = .{ .selected = true } },
        .{ .id = 112, .kind = .list_item, .text = "Customers" },
        .{ .id = 113, .kind = .list_item, .text = "Latency" },
    };
    const activity_items = [_]canvas.Widget{
        .{ .id = 121, .kind = .list_item, .frame = rect(0, 0, 0, 32), .text = "Signed enterprise renewal" },
        .{ .id = 122, .kind = .list_item, .frame = rect(0, 36, 0, 32), .text = "Usage spike in EU region" },
        .{ .id = 123, .kind = .list_item, .frame = rect(0, 72, 0, 32), .text = "Latency budget recovered" },
        .{ .id = 124, .kind = .list_item, .frame = rect(0, 108, 0, 32), .text = "Queued invoice batch" },
    };
    const form_fields = [_]canvas.Widget{
        .{
            .id = 131,
            .kind = .text_field,
            .frame = rect(12, 12, 116, 30),
            .text = "$13.4M",
            .semantics = .{ .label = "Forecast amount" },
        },
        .{
            .id = 132,
            .kind = .search_field,
            .frame = rect(140, 12, 126, 30),
            .text = "enterprise",
            .semantics = .{ .label = "Segment search" },
        },
        .{
            .id = 133,
            .kind = .toggle,
            .frame = rect(278, 13, 82, 28),
            .text = "Auto",
            .value = 1,
            .state = .{ .selected = true },
            .semantics = .{ .label = "Auto refresh" },
        },
        .{
            .id = 134,
            .kind = .slider,
            .frame = rect(370, 15, 40, 24),
            .value = 0.62,
            .semantics = .{ .label = "Confidence threshold" },
        },
    };
    const filter_items = [_]canvas.Widget{
        .{ .id = 142, .kind = .menu_item, .text = "Last 30 days" },
        .{ .id = 143, .kind = .menu_item, .text = "Enterprise" },
        .{ .id = 144, .kind = .menu_item, .text = "High intent" },
    };
    const filter_menu = [_]canvas.Widget{.{
        .id = 141,
        .kind = .menu_surface,
        .frame = rect(12, 12, 154, 92),
        .layout = .{ .gap = 2 },
        .semantics = .{ .label = "Filter options" },
        .children = &filter_items,
    }};
    const deployment_cells = [_]canvas.Widget{
        .{ .id = 156, .kind = .data_cell, .text = "iad1 8.6ms P95", .command = "deployment.open", .layout = .{ .grow = 1 } },
    };
    const deployment_rows = [_]canvas.Widget{
        .{ .id = 155, .kind = .data_row, .frame = rect(0, 0, 0, 28), .children = &deployment_cells },
    };
    const trend_widgets = [_]canvas.Widget{
        .{
            .id = 116,
            .kind = .text,
            .frame = rect(24, 20, 180, 18),
            .text = "Conversion trend",
        },
        .{
            .id = 150,
            .kind = .data_grid,
            .frame = rect(24, 58, 246, 28),
            .text = "Deployment latency",
            .children = &deployment_rows,
        },
    };
    const dashboard_widgets = [_]canvas.Widget{
        .{
            .id = 101,
            .kind = .text,
            .frame = rect(226, 54, 220, 28),
            .text = "Revenue pulse",
        },
        .{
            .id = 102,
            .kind = .text,
            .frame = rect(226, 88, 260, 18),
            .text = "Retained canvas dashboard",
        },
        .{
            .id = 103,
            .kind = .button,
            .frame = rect(522, 50, 128, 34),
            .text = "Live render",
            .command = mode_command,
            .semantics = .{ .label = "Live render status" },
        },
        .{
            .id = 104,
            .kind = .grid,
            .frame = rect(226, 128, 422, 96),
            .layout = .{ .columns = 3, .gap = 16 },
            .semantics = .{ .role = .list, .label = "Dashboard metrics" },
            .children = &metric_items,
        },
        .{
            .id = 108,
            .kind = .panel,
            .frame = rect(226, 248, 422, 190),
            .semantics = .{ .label = "Conversion trend" },
            .children = &trend_widgets,
        },
        .{
            .id = 109,
            .kind = .progress,
            .frame = rect(250, 454, 256, 12),
            .value = 0.68,
            .semantics = .{ .label = "Conversion progress" },
        },
        .{
            .id = 110,
            .kind = .list,
            .frame = rect(54, 136, 126, 120),
            .layout = .{ .gap = 8 },
            .semantics = .{ .label = "Dashboard navigation" },
            .children = &nav_items,
        },
        .{
            .id = 120,
            .kind = .scroll_view,
            .frame = rect(522, 248, 126, 100),
            .value = 18,
            .semantics = .{ .label = "Recent activity" },
            .children = &activity_items,
        },
        .{
            .id = 130,
            .kind = .panel,
            .frame = rect(226, 448, 422, 56),
            .semantics = .{ .label = "Forecast form" },
            .children = &form_fields,
        },
        .{
            .id = 140,
            .kind = .popover,
            .frame = rect(470, 86, 178, 122),
            .backdrop_blur = dashboard_glass_blur,
            .semantics = .{ .label = "Revenue filter popover" },
            .children = &filter_menu,
        },
    };
    return canvas.layoutWidgetTree(.{ .kind = .stack, .children = &dashboard_widgets }, rect(0, 0, canvas_width, window_height - toolbar_height - statusbar_height), nodes);
}

fn dashboardFrame(display_list: canvas.DisplayList, previous: ?canvas.DisplayList, options: canvas.CanvasFrameOptions, storage: canvas.CanvasFrameStorage) canvas.Error!canvas.CanvasFrame {
    return display_list.framePlan(previous, options, storage);
}

fn dashboardFrameStorage(
    render_commands: []canvas.RenderCommand,
    render_batches: []canvas.RenderBatch,
    pipeline_cache_entries: []canvas.RenderPipelineCacheEntry,
    pipeline_cache_actions: []canvas.RenderPipelineCacheAction,
    layers: []canvas.RenderLayer,
    layer_cache_entries: []canvas.RenderLayerCacheEntry,
    layer_cache_actions: []canvas.RenderLayerCacheAction,
    resources: []canvas.RenderResource,
    cache_entries: []canvas.RenderResourceCacheEntry,
    cache_actions: []canvas.RenderResourceCacheAction,
    visual_effects: []canvas.VisualEffect,
    visual_effect_cache_entries: []canvas.VisualEffectCacheEntry,
    visual_effect_cache_actions: []canvas.VisualEffectCacheAction,
    glyphs: []canvas.GlyphAtlasEntry,
    glyph_cache_entries: []canvas.GlyphAtlasCacheEntry,
    glyph_cache_actions: []canvas.GlyphAtlasCacheAction,
    text_layout_plans: []canvas.TextLayoutPlan,
    text_layout_lines: []canvas.TextLine,
    text_layout_cache_entries: []canvas.TextLayoutCacheEntry,
    text_layout_cache_actions: []canvas.TextLayoutCacheAction,
    changes: []canvas.DiffChange,
) canvas.CanvasFrameStorage {
    return .{
        .render_commands = render_commands,
        .render_batches = render_batches,
        .pipeline_cache_entries = pipeline_cache_entries,
        .pipeline_cache_actions = pipeline_cache_actions,
        .layers = layers,
        .layer_cache_entries = layer_cache_entries,
        .layer_cache_actions = layer_cache_actions,
        .resources = resources,
        .resource_cache_entries = cache_entries,
        .resource_cache_actions = cache_actions,
        .visual_effects = visual_effects,
        .visual_effect_cache_entries = visual_effect_cache_entries,
        .visual_effect_cache_actions = visual_effect_cache_actions,
        .glyph_atlas_entries = glyphs,
        .glyph_atlas_cache_entries = glyph_cache_entries,
        .glyph_atlas_cache_actions = glyph_cache_actions,
        .text_layout_plans = text_layout_plans,
        .text_layout_lines = text_layout_lines,
        .text_layout_cache_entries = text_layout_cache_entries,
        .text_layout_cache_actions = text_layout_cache_actions,
        .changes = changes,
    };
}

fn gpuFrameEvent(frame: zero_native.platform.GpuFrame) zero_native.GpuSurfaceFrameEvent {
    return .{
        .window_id = frame.window_id,
        .label = frame.label,
        .size = frame.size,
        .scale_factor = frame.scale_factor,
        .frame_index = frame.frame_index,
        .timestamp_ns = frame.timestamp_ns,
        .input_timestamp_ns = frame.input_timestamp_ns,
        .input_latency_ns = frame.input_latency_ns,
        .input_latency_budget_ns = frame.input_latency_budget_ns,
        .input_latency_budget_exceeded_count = frame.input_latency_budget_exceeded_count,
        .input_latency_budget_ok = frame.input_latency_budget_ok,
        .nonblank = frame.nonblank,
        .sample_color = frame.sample_color,
        .backend = frame.backend,
        .pixel_format = frame.pixel_format,
        .present_mode = frame.present_mode,
        .alpha_mode = frame.alpha_mode,
        .color_space = frame.color_space,
        .vsync = frame.vsync,
        .status = frame.status,
        .canvas_revision = frame.canvas_revision,
        .canvas_command_count = frame.canvas_command_count,
        .canvas_frame_requires_render = frame.canvas_frame_requires_render,
        .canvas_frame_full_repaint = frame.canvas_frame_full_repaint,
        .canvas_frame_batch_count = frame.canvas_frame_batch_count,
        .canvas_frame_encoder_command_count = frame.canvas_frame_encoder_command_count,
        .canvas_frame_encoder_cache_action_count = frame.canvas_frame_encoder_cache_action_count,
        .canvas_frame_encoder_bind_pipeline_count = frame.canvas_frame_encoder_bind_pipeline_count,
        .canvas_frame_encoder_draw_batch_count = frame.canvas_frame_encoder_draw_batch_count,
        .canvas_frame_pipeline_count = frame.canvas_frame_pipeline_count,
        .canvas_frame_pipeline_upload_count = frame.canvas_frame_pipeline_upload_count,
        .canvas_frame_pipeline_retain_count = frame.canvas_frame_pipeline_retain_count,
        .canvas_frame_pipeline_evict_count = frame.canvas_frame_pipeline_evict_count,
        .canvas_frame_path_geometry_count = frame.canvas_frame_path_geometry_count,
        .canvas_frame_path_geometry_vertex_count = frame.canvas_frame_path_geometry_vertex_count,
        .canvas_frame_path_geometry_index_count = frame.canvas_frame_path_geometry_index_count,
        .canvas_frame_path_geometry_upload_count = frame.canvas_frame_path_geometry_upload_count,
        .canvas_frame_path_geometry_retain_count = frame.canvas_frame_path_geometry_retain_count,
        .canvas_frame_path_geometry_evict_count = frame.canvas_frame_path_geometry_evict_count,
        .canvas_frame_image_count = frame.canvas_frame_image_count,
        .canvas_frame_image_upload_count = frame.canvas_frame_image_upload_count,
        .canvas_frame_image_retain_count = frame.canvas_frame_image_retain_count,
        .canvas_frame_image_evict_count = frame.canvas_frame_image_evict_count,
        .canvas_frame_layer_count = frame.canvas_frame_layer_count,
        .canvas_frame_layer_opacity_count = frame.canvas_frame_layer_opacity_count,
        .canvas_frame_layer_clip_count = frame.canvas_frame_layer_clip_count,
        .canvas_frame_layer_transform_count = frame.canvas_frame_layer_transform_count,
        .canvas_frame_layer_upload_count = frame.canvas_frame_layer_upload_count,
        .canvas_frame_layer_retain_count = frame.canvas_frame_layer_retain_count,
        .canvas_frame_layer_evict_count = frame.canvas_frame_layer_evict_count,
        .canvas_frame_resource_count = frame.canvas_frame_resource_count,
        .canvas_frame_resource_upload_count = frame.canvas_frame_resource_upload_count,
        .canvas_frame_resource_retain_count = frame.canvas_frame_resource_retain_count,
        .canvas_frame_resource_evict_count = frame.canvas_frame_resource_evict_count,
        .canvas_frame_visual_effect_count = frame.canvas_frame_visual_effect_count,
        .canvas_frame_visual_effect_shadow_count = frame.canvas_frame_visual_effect_shadow_count,
        .canvas_frame_visual_effect_blur_count = frame.canvas_frame_visual_effect_blur_count,
        .canvas_frame_visual_effect_upload_count = frame.canvas_frame_visual_effect_upload_count,
        .canvas_frame_visual_effect_retain_count = frame.canvas_frame_visual_effect_retain_count,
        .canvas_frame_visual_effect_evict_count = frame.canvas_frame_visual_effect_evict_count,
        .canvas_frame_glyph_atlas_entry_count = frame.canvas_frame_glyph_atlas_entry_count,
        .canvas_frame_glyph_atlas_upload_count = frame.canvas_frame_glyph_atlas_upload_count,
        .canvas_frame_glyph_atlas_retain_count = frame.canvas_frame_glyph_atlas_retain_count,
        .canvas_frame_glyph_atlas_evict_count = frame.canvas_frame_glyph_atlas_evict_count,
        .canvas_frame_text_layout_count = frame.canvas_frame_text_layout_count,
        .canvas_frame_text_layout_line_count = frame.canvas_frame_text_layout_line_count,
        .canvas_frame_text_layout_upload_count = frame.canvas_frame_text_layout_upload_count,
        .canvas_frame_text_layout_retain_count = frame.canvas_frame_text_layout_retain_count,
        .canvas_frame_text_layout_evict_count = frame.canvas_frame_text_layout_evict_count,
        .canvas_frame_change_count = frame.canvas_frame_change_count,
        .canvas_frame_budget_exceeded_count = frame.canvas_frame_budget_exceeded_count,
        .canvas_frame_budget_ok = frame.canvas_frame_budget_ok,
        .canvas_frame_dirty_bounds = frame.canvas_frame_dirty_bounds,
        .canvas_frame_profile_work_units = frame.canvas_frame_profile_work_units,
        .canvas_frame_profile_risk = frame.canvas_frame_profile_risk,
        .canvas_frame_profile_surface_area = frame.canvas_frame_profile_surface_area,
        .canvas_frame_profile_dirty_area = frame.canvas_frame_profile_dirty_area,
        .canvas_frame_profile_dirty_ratio = frame.canvas_frame_profile_dirty_ratio,
        .widget_revision = frame.widget_revision,
        .widget_node_count = frame.widget_node_count,
        .widget_semantics_count = frame.widget_semantics_count,
    };
}

fn dashboardFrameStatus(buffer: []u8, frame_event: zero_native.GpuSurfaceFrameEvent) std.fmt.BufPrintError![]u8 {
    return std.fmt.bufPrint(
        buffer,
        "Canvas frame: {s} risk, {d} work units, {d} commands, {d} batches, dirty {d}%.",
        .{
            @tagName(frame_event.canvas_frame_profile_risk),
            frame_event.canvas_frame_profile_work_units,
            frame_event.canvas_command_count,
            frame_event.canvas_frame_batch_count,
            dashboardDirtyPercent(frame_event.canvas_frame_profile_dirty_ratio),
        },
    );
}

fn dashboardDirtyPercent(ratio: f32) u32 {
    return @as(u32, @intFromFloat(@round(std.math.clamp(ratio, 0, 1) * 100.0)));
}

fn dashboardSnapshotWidget(snapshot: zero_native.automation.snapshot.Input, id: u64) ?zero_native.automation.snapshot.Widget {
    for (snapshot.widgets) |widget| {
        if (widget.id == id and std.mem.eql(u8, widget.view_label, "dashboard-canvas")) return widget;
    }
    return null;
}

fn dashboardViewByLabel(runtime: *const zero_native.Runtime, label: []const u8) ?zero_native.ViewInfo {
    var views_buffer: [zero_native.platform.max_views + zero_native.platform.max_webviews + 1]zero_native.ViewInfo = undefined;
    const views = runtime.listViews(1, &views_buffer);
    for (views) |view| {
        if (std.mem.eql(u8, view.label, label)) return view;
    }
    return null;
}

fn expectDashboardTextCommand(display_list: canvas.DisplayList, id: canvas.ObjectId, expected: []const u8) !void {
    const command_ref = display_list.findCommandById(id) orelse return error.MissingDashboardCommand;
    switch (command_ref.command) {
        .draw_text => |text| try std.testing.expectEqualStrings(expected, text.text),
        else => return error.UnexpectedDashboardCommand,
    }
}

fn dashboardTextCommandOriginY(display_list: canvas.DisplayList, id: canvas.ObjectId) !f32 {
    const command_ref = display_list.findCommandById(id) orelse return error.MissingDashboardCommand;
    return switch (command_ref.command) {
        .draw_text => |text| text.origin.y,
        else => error.UnexpectedDashboardCommand,
    };
}

fn dashboardRoundedRectCommandWidth(display_list: canvas.DisplayList, id: canvas.ObjectId) !f32 {
    const command_ref = display_list.findCommandById(id) orelse return error.MissingDashboardCommand;
    return switch (command_ref.command) {
        .fill_rounded_rect => |rounded| rounded.rect.width,
        else => error.UnexpectedDashboardCommand,
    };
}

fn resetDashboardDirty(runtime: *zero_native.Runtime) void {
    runtime.invalidated = false;
    runtime.dirty_region_count = 0;
}

fn expectCompactDashboardDirty(runtime: *const zero_native.Runtime, max_width: f32, max_height: f32) !void {
    const regions = runtime.pendingDirtyRegions();
    try std.testing.expect(regions.len > 0);

    var dirty_area: f32 = 0;
    for (regions) |region| {
        const dirty = region.normalized();
        try std.testing.expect(dirty.width > 0);
        try std.testing.expect(dirty.height > 0);
        dirty_area += dirty.width * dirty.height;
    }
    try std.testing.expect(dirty_area < max_width * max_height);
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
    try std.testing.expect(shell_views[11].gpu_backend.? == .metal);
    try std.testing.expect(shell_views[11].gpu_pixel_format.? == .bgra8_unorm);
    try std.testing.expect(shell_views[11].gpu_present_mode.? == .timer);
    try std.testing.expect(shell_views[11].gpu_alpha_mode.? == .@"opaque");
    try std.testing.expect(shell_views[11].gpu_color_space.? == .srgb);
    try std.testing.expect(shell_views[11].gpu_vsync.?);
}

test "gpu dashboard display list builds a complete canvas scene" {
    var commands: [max_dashboard_commands]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try buildDashboardDisplayListFromWidgets(&builder);
    const display_list = builder.displayList();

    try std.testing.expectEqual(@as(usize, 64), display_list.commandCount());
    try std.testing.expect(display_list.findCommandById(1) != null);
    try std.testing.expect(display_list.findCommandById(deployment_region_text_command_id) != null);
    try std.testing.expect(display_list.findCommandById(live_button_fill_command_id) != null);
    try std.testing.expect(display_list.findCommandById(activity_scroll_track_command_id) != null);
    try std.testing.expect(display_list.findCommandById(activity_scroll_thumb_command_id) != null);
    try std.testing.expect(display_list.findCommandById(filter_popover_blur_command_id) != null);
    const bounds = display_list.bounds().?;
    try std.testing.expect(bounds.x <= 0);
    try std.testing.expect(bounds.y <= 0);
    try std.testing.expect(bounds.width >= 720);
    try std.testing.expect(bounds.height >= 520);
}

test "gpu dashboard display list renders through the reference surface" {
    var commands: [max_dashboard_commands]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try buildDashboardDisplayListFromWidgets(&builder);
    const display_list = builder.displayList();

    var render_commands: [max_dashboard_commands]canvas.RenderCommand = undefined;
    var render_batches: [max_dashboard_commands]canvas.RenderBatch = undefined;
    var pipeline_cache_entries: [max_dashboard_pipelines]canvas.RenderPipelineCacheEntry = undefined;
    var pipeline_cache_actions: [max_dashboard_pipelines * 2]canvas.RenderPipelineCacheAction = undefined;
    var layers: [max_dashboard_commands]canvas.RenderLayer = undefined;
    var layer_cache_entries: [max_dashboard_commands]canvas.RenderLayerCacheEntry = undefined;
    var layer_cache_actions: [max_dashboard_commands * 2]canvas.RenderLayerCacheAction = undefined;
    var resources: [max_dashboard_commands]canvas.RenderResource = undefined;
    var cache_entries: [max_dashboard_commands]canvas.RenderResourceCacheEntry = undefined;
    var cache_actions: [max_dashboard_commands * 2]canvas.RenderResourceCacheAction = undefined;
    var visual_effects: [max_dashboard_commands]canvas.VisualEffect = undefined;
    var visual_effect_cache_entries: [max_dashboard_commands]canvas.VisualEffectCacheEntry = undefined;
    var visual_effect_cache_actions: [max_dashboard_commands * 2]canvas.VisualEffectCacheAction = undefined;
    var glyphs: [zero_native.runtime.max_canvas_glyphs_per_view]canvas.GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [zero_native.runtime.max_canvas_glyphs_per_view]canvas.GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [zero_native.runtime.max_canvas_glyphs_per_view * 2]canvas.GlyphAtlasCacheAction = undefined;
    var text_layout_plans: [max_dashboard_commands]canvas.TextLayoutPlan = undefined;
    var text_layout_lines: [zero_native.runtime.max_canvas_glyphs_per_view]canvas.TextLine = undefined;
    var text_layout_cache_entries: [max_dashboard_commands]canvas.TextLayoutCacheEntry = undefined;
    var text_layout_cache_actions: [max_dashboard_commands * 2]canvas.TextLayoutCacheAction = undefined;
    var changes: [max_dashboard_commands * 2 + 1]canvas.DiffChange = undefined;
    const frame = try dashboardFrame(display_list, null, .{
        .surface_size = geometry.SizeF.init(720, 520),
        .full_repaint = true,
    }, dashboardFrameStorage(&render_commands, &render_batches, &pipeline_cache_entries, &pipeline_cache_actions, &layers, &layer_cache_entries, &layer_cache_actions, &resources, &cache_entries, &cache_actions, &visual_effects, &visual_effect_cache_entries, &visual_effect_cache_actions, &glyphs, &glyph_cache_entries, &glyph_cache_actions, &text_layout_plans, &text_layout_lines, &text_layout_cache_entries, &text_layout_cache_actions, &changes));

    try std.testing.expect(frame.requiresRender());
    try std.testing.expect(frame.batch_plan.batchCount() >= 8);
    try std.testing.expect(frame.pipeline_cache_plan.entryCount() >= 4);
    try std.testing.expect(frame.pipeline_cache_plan.uploadCount() >= 4);
    try std.testing.expectEqual(@as(usize, 1), frame.layer_plan.layerCount());
    try std.testing.expectEqual(@as(usize, 1), frame.layer_cache_plan.uploadCount());
    try std.testing.expect(frame.resource_plan.resourceCount() >= 8);
    try std.testing.expect(frame.visual_effect_plan.effectCount() >= 5);
    try std.testing.expect(frame.visual_effect_plan.shadowCount() >= 4);
    try std.testing.expect(frame.visual_effect_plan.blurCount() >= 1);
    try std.testing.expect(frame.visual_effect_cache_plan.uploadCount() >= 5);
    try std.testing.expect(frame.text_layout_plan.planCount() >= 10);
    var encoder_commands: [max_dashboard_glyphs + max_dashboard_commands * 3]canvas.RenderEncoderCommand = undefined;
    const encoder_plan = try frame.renderPass().encoderPlan(&encoder_commands);
    try std.testing.expectEqual(frame.batch_plan.batchCount(), encoder_plan.drawBatchCount());
    try std.testing.expect(encoder_plan.cacheActionCount() >= frame.pipeline_cache_plan.actionCount());

    const pixel_count = 720 * 520 * 4;
    const pixels = try std.testing.allocator.alloc(u8, pixel_count);
    defer std.testing.allocator.free(pixels);
    const scratch = try std.testing.allocator.alloc(u8, pixel_count);
    defer std.testing.allocator.free(scratch);
    @memset(pixels, 0);
    const surface = try canvas.ReferenceRenderSurface.initWithScratch(720, 520, pixels, scratch);
    try surface.renderPass(frame.renderPass(), color(0, 0, 0));

    try std.testing.expectEqual(@as(u64, 17535322711022946563), referenceSurfaceSignature(pixels));
    try expectVisiblePixel(surface.pixelRgba8(8, 8));
    try expectVisiblePixel(surface.pixelRgba8(64, 64));
    try expectVisiblePixel(surface.pixelRgba8(240, 140));
    try std.testing.expectEqual(@as(u8, 255), surface.pixelRgba8(236, 134)[3]);
}

test "gpu dashboard render overrides animate without rebuilding commands" {
    var commands: [max_dashboard_commands]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try buildDashboardDisplayListFromWidgets(&builder);
    const display_list = builder.displayList();

    const motion = dashboardWidgetTokens().motion;
    const animations = [_]canvas.CanvasRenderAnimation{motion.animation(.{
        .id = live_button_fill_command_id,
        .start_ns = 1_000_000_000,
        .duration = .slow,
        .from_opacity = 0.72,
        .to_opacity = 1,
        .from_transform = canvas.Affine.translate(0, -6),
        .to_transform = canvas.Affine.identity(),
    })};
    try std.testing.expectEqual(@as(u32, 900), animations[0].duration_ms);
    try std.testing.expectEqual(canvas.Easing.emphasized, animations[0].easing);
    var overrides: [1]canvas.CanvasRenderOverride = undefined;
    const sampled = try canvas.sampleCanvasRenderAnimations(&animations, 1_400_000_000, &overrides);
    try std.testing.expectEqual(@as(usize, 1), sampled.len);

    var render_commands: [max_dashboard_commands]canvas.RenderCommand = undefined;
    var render_batches: [max_dashboard_commands]canvas.RenderBatch = undefined;
    var pipeline_cache_entries: [max_dashboard_pipelines]canvas.RenderPipelineCacheEntry = undefined;
    var pipeline_cache_actions: [max_dashboard_pipelines * 2]canvas.RenderPipelineCacheAction = undefined;
    var layers: [max_dashboard_commands]canvas.RenderLayer = undefined;
    var layer_cache_entries: [max_dashboard_commands]canvas.RenderLayerCacheEntry = undefined;
    var layer_cache_actions: [max_dashboard_commands * 2]canvas.RenderLayerCacheAction = undefined;
    var resources: [max_dashboard_commands]canvas.RenderResource = undefined;
    var cache_entries: [max_dashboard_commands]canvas.RenderResourceCacheEntry = undefined;
    var cache_actions: [max_dashboard_commands * 2]canvas.RenderResourceCacheAction = undefined;
    var visual_effects: [max_dashboard_commands]canvas.VisualEffect = undefined;
    var visual_effect_cache_entries: [max_dashboard_commands]canvas.VisualEffectCacheEntry = undefined;
    var visual_effect_cache_actions: [max_dashboard_commands * 2]canvas.VisualEffectCacheAction = undefined;
    var glyphs: [zero_native.runtime.max_canvas_glyphs_per_view]canvas.GlyphAtlasEntry = undefined;
    var glyph_cache_entries: [zero_native.runtime.max_canvas_glyphs_per_view]canvas.GlyphAtlasCacheEntry = undefined;
    var glyph_cache_actions: [zero_native.runtime.max_canvas_glyphs_per_view * 2]canvas.GlyphAtlasCacheAction = undefined;
    var text_layout_plans: [max_dashboard_commands]canvas.TextLayoutPlan = undefined;
    var text_layout_lines: [zero_native.runtime.max_canvas_glyphs_per_view]canvas.TextLine = undefined;
    var text_layout_cache_entries: [max_dashboard_commands]canvas.TextLayoutCacheEntry = undefined;
    var text_layout_cache_actions: [max_dashboard_commands * 2]canvas.TextLayoutCacheAction = undefined;
    var changes: [max_dashboard_commands * 2 + 1]canvas.DiffChange = undefined;

    const frame = try dashboardFrame(display_list, display_list, .{
        .surface_size = geometry.SizeF.init(720, 520),
        .render_overrides = sampled,
    }, dashboardFrameStorage(&render_commands, &render_batches, &pipeline_cache_entries, &pipeline_cache_actions, &layers, &layer_cache_entries, &layer_cache_actions, &resources, &cache_entries, &cache_actions, &visual_effects, &visual_effect_cache_entries, &visual_effect_cache_actions, &glyphs, &glyph_cache_entries, &glyph_cache_actions, &text_layout_plans, &text_layout_lines, &text_layout_cache_entries, &text_layout_cache_actions, &changes));

    try std.testing.expect(frame.requiresRender());
    try std.testing.expect(frame.pipeline_cache_plan.entryCount() >= 4);
    try std.testing.expectEqual(@as(usize, 2), frame.layer_plan.layerCount());
    try std.testing.expectEqual(@as(usize, 2), frame.layer_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 2), frame.renderPass().layerActionCount());
    try std.testing.expect(frame.visual_effect_plan.effectCount() >= 5);
    try std.testing.expectEqual(@as(usize, 0), frame.changes.len);
    try std.testing.expect(frame.dirty_bounds != null);
}

test "gpu dashboard app registers canvas display list on first gpu frame" {
    var harness: zero_native.TestHarness() = undefined;
    harness.init(.{ .size = geometry.SizeF.init(window_width, window_height) });
    harness.null_platform.gpu_surfaces = true;

    var app = GpuDashboardApp{};
    defer app.deinit();
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

    var display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try std.testing.expectEqual(@as(usize, 64), display_list.commandCount());
    try std.testing.expect(display_list.findCommandById(1) != null);
    try std.testing.expect(display_list.findCommandById(deployment_region_text_command_id) != null);
    try std.testing.expect(display_list.findCommandById(activity_scroll_track_command_id) != null);
    try std.testing.expect(display_list.findCommandById(activity_scroll_thumb_command_id) != null);
    try std.testing.expect(display_list.findCommandById(overview_fill_command_id) != null);
    try std.testing.expect(display_list.findCommandById(customers_fill_command_id) == null);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_present_count);
    try std.testing.expectEqual(@as(usize, 1440), harness.null_platform.gpu_surface_present_width);
    try std.testing.expectEqual(@as(usize, 1040), harness.null_platform.gpu_surface_present_height);
    const animations = try harness.runtime.canvasRenderAnimations(1, "dashboard-canvas");
    try std.testing.expectEqual(@as(usize, 2), animations.len);
    try std.testing.expectEqual(live_button_fill_command_id, animations[0].id);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), animations[0].start_ns);

    const widget_layout = try harness.runtime.canvasWidgetLayout(1, "dashboard-canvas");
    try std.testing.expectEqual(@as(usize, 32), widget_layout.nodeCount());
    try std.testing.expectEqualStrings("Dashboard metrics", widget_layout.nodes[4].widget.semantics.label);

    var snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expectEqual(@as(usize, 31), snapshot.widgets.len);

    const live_render = dashboardSnapshotWidget(snapshot, 103).?;
    try std.testing.expectEqualStrings("button", live_render.role);
    try std.testing.expectEqualStrings("Live render status", live_render.name);
    try std.testing.expect(live_render.actions.press);

    const progress = dashboardSnapshotWidget(snapshot, 109).?;
    try std.testing.expectEqualStrings("progressbar", progress.role);
    try std.testing.expectEqualStrings("Conversion progress", progress.name);

    const nav_list = dashboardSnapshotWidget(snapshot, 110).?;
    try std.testing.expectEqualStrings("list", nav_list.role);
    try std.testing.expectEqualStrings("Dashboard navigation", nav_list.name);

    const overview = dashboardSnapshotWidget(snapshot, 111).?;
    try std.testing.expectEqualStrings("listitem", overview.role);
    try std.testing.expect(overview.selected);
    try std.testing.expect(overview.list.present);
    try std.testing.expectEqual(@as(u32, 0), overview.list.item_index);
    try std.testing.expectEqual(@as(u32, 3), overview.list.item_count);

    const recent = dashboardSnapshotWidget(snapshot, 120).?;
    try std.testing.expectEqualStrings("group", recent.role);
    try std.testing.expectEqualStrings("Recent activity", recent.name);
    try std.testing.expect(recent.scroll.present);
    try std.testing.expect(recent.scroll.content_extent > recent.scroll.viewport_extent);
    try std.testing.expect(recent.actions.increment);
    try std.testing.expect(recent.actions.decrement);

    const forecast = dashboardSnapshotWidget(snapshot, 131).?;
    try std.testing.expectEqualStrings("textbox", forecast.role);
    try std.testing.expectEqualStrings("Forecast amount", forecast.name);
    try std.testing.expectEqualStrings("$13.4M", forecast.text_value);
    try std.testing.expect(forecast.actions.set_text);
    try std.testing.expect(forecast.actions.set_selection);

    const search = dashboardSnapshotWidget(snapshot, 132).?;
    try std.testing.expectEqualStrings("textbox", search.role);
    try std.testing.expectEqualStrings("Segment search", search.name);
    try std.testing.expectEqualStrings("enterprise", search.text_value);

    const auto_refresh = dashboardSnapshotWidget(snapshot, 133).?;
    try std.testing.expectEqualStrings("switch", auto_refresh.role);
    try std.testing.expectEqualStrings("Auto refresh", auto_refresh.name);
    try std.testing.expectEqual(@as(?f32, 1), auto_refresh.value);
    try std.testing.expect(auto_refresh.selected);
    try std.testing.expect(auto_refresh.actions.toggle);

    const confidence = dashboardSnapshotWidget(snapshot, 134).?;
    try std.testing.expectEqualStrings("slider", confidence.role);
    try std.testing.expectEqualStrings("Confidence threshold", confidence.name);
    try std.testing.expectApproxEqAbs(@as(f32, 0.62), confidence.value.?, 0.001);
    try std.testing.expect(confidence.actions.increment);
    try std.testing.expect(confidence.actions.decrement);

    const popover = dashboardSnapshotWidget(snapshot, 140).?;
    try std.testing.expectEqualStrings("dialog", popover.role);
    try std.testing.expectEqualStrings("Revenue filter popover", popover.name);

    const menu = dashboardSnapshotWidget(snapshot, 141).?;
    try std.testing.expectEqualStrings("menu", menu.role);
    try std.testing.expectEqualStrings("Filter options", menu.name);

    const menu_item = dashboardSnapshotWidget(snapshot, 142).?;
    try std.testing.expectEqualStrings("menuitem", menu_item.role);
    try std.testing.expectEqualStrings("Last 30 days", menu_item.name);

    const deployment_grid = dashboardSnapshotWidget(snapshot, 150).?;
    try std.testing.expectEqualStrings("grid", deployment_grid.role);
    try std.testing.expectEqualStrings("Deployment latency", deployment_grid.name);
    try std.testing.expectEqual(@as(?usize, 1), deployment_grid.grid_row_count);
    try std.testing.expectEqual(@as(?usize, 1), deployment_grid.grid_column_count);

    const deployment_cell = dashboardSnapshotWidget(snapshot, 156).?;
    try std.testing.expectEqualStrings("gridcell", deployment_cell.role);
    try std.testing.expectEqualStrings("iad1 8.6ms P95", deployment_cell.name);
    try std.testing.expectEqual(@as(?usize, 0), deployment_cell.grid_row_index);
    try std.testing.expectEqual(@as(?usize, 0), deployment_cell.grid_column_index);
    try std.testing.expect(deployment_cell.actions.select);
    try std.testing.expect(deployment_cell.actions.press);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 103 press");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, window_height - toolbar_height - statusbar_height);
    try std.testing.expectEqual(@as(u32, 1), app.mode_count);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expect(dashboardSnapshotWidget(snapshot, 103).?.focused);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "dashboard-canvas",
        .kind = .key_down,
        .key = "tab",
    } });
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, window_height - toolbar_height - statusbar_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expect(!dashboardSnapshotWidget(snapshot, 103).?.focused);
    try std.testing.expect(dashboardSnapshotWidget(snapshot, 105).?.focused);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "dashboard-canvas",
        .kind = .key_down,
        .key = "tab",
        .modifiers = .{ .shift = true },
    } });
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, window_height - toolbar_height - statusbar_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expect(dashboardSnapshotWidget(snapshot, 103).?.focused);
    try std.testing.expect(!dashboardSnapshotWidget(snapshot, 105).?.focused);

    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 112 select");
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expect(!dashboardSnapshotWidget(snapshot, 111).?.selected);
    try std.testing.expect(dashboardSnapshotWidget(snapshot, 112).?.selected);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try std.testing.expect(display_list.findCommandById(1) != null);
    try std.testing.expect(display_list.findCommandById(deployment_region_text_command_id) != null);
    try std.testing.expect(display_list.findCommandById(overview_fill_command_id) == null);
    try std.testing.expect(display_list.findCommandById(customers_fill_command_id) != null);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 156 select");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, window_height - toolbar_height - statusbar_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expect(dashboardSnapshotWidget(snapshot, 156).?.selected);
    try std.testing.expect(dashboardSnapshotWidget(snapshot, 156).?.focused);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 131 set-text $14.1M");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, window_height - toolbar_height - statusbar_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const updated_forecast = dashboardSnapshotWidget(snapshot, 131).?;
    try std.testing.expectEqualStrings("$14.1M", updated_forecast.text_value);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 6, .end = 6 }, updated_forecast.text_selection.?);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try expectDashboardTextCommand(display_list, forecast_text_command_id, "$14.1M");
    const activity_y_before_scroll = try dashboardTextCommandOriginY(display_list, activity_first_text_command_id);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 131 set-composition est");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, window_height - toolbar_height - statusbar_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const composing_forecast = dashboardSnapshotWidget(snapshot, 131).?;
    try std.testing.expectEqualStrings("$14.1Mest", composing_forecast.text_value);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 9, .end = 9 }, composing_forecast.text_selection.?);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 6, .end = 9 }, composing_forecast.text_composition.?);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try expectDashboardTextCommand(display_list, forecast_text_command_id, "$14.1Mest");
    try std.testing.expect(display_list.findCommandById(forecast_composition_command_id) != null);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 131 cancel-composition");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, window_height - toolbar_height - statusbar_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const canceled_forecast = dashboardSnapshotWidget(snapshot, 131).?;
    try std.testing.expectEqualStrings("$14.1M", canceled_forecast.text_value);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 6, .end = 6 }, canceled_forecast.text_selection.?);
    try std.testing.expect(canceled_forecast.text_composition == null);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try expectDashboardTextCommand(display_list, forecast_text_command_id, "$14.1M");
    try std.testing.expect(display_list.findCommandById(forecast_composition_command_id) == null);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 131 set-composition !");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, window_height - toolbar_height - statusbar_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const final_composing_forecast = dashboardSnapshotWidget(snapshot, 131).?;
    try std.testing.expectEqualStrings("$14.1M!", final_composing_forecast.text_value);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 6, .end = 7 }, final_composing_forecast.text_composition.?);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 131 commit-composition");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, window_height - toolbar_height - statusbar_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const committed_forecast = dashboardSnapshotWidget(snapshot, 131).?;
    try std.testing.expectEqualStrings("$14.1M!", committed_forecast.text_value);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 7, .end = 7 }, committed_forecast.text_selection.?);
    try std.testing.expect(committed_forecast.text_composition == null);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try expectDashboardTextCommand(display_list, forecast_text_command_id, "$14.1M!");
    try std.testing.expect(display_list.findCommandById(forecast_composition_command_id) == null);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 133 toggle");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, window_height - toolbar_height - statusbar_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const disabled_auto_refresh = dashboardSnapshotWidget(snapshot, 133).?;
    try std.testing.expectEqual(@as(?f32, 0), disabled_auto_refresh.value);
    try std.testing.expect(!disabled_auto_refresh.selected);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 134 increment");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, window_height - toolbar_height - statusbar_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const updated_confidence = dashboardSnapshotWidget(snapshot, 134).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.67), updated_confidence.value.?, 0.001);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try std.testing.expectApproxEqAbs(@as(f32, 26.8), try dashboardRoundedRectCommandWidth(display_list, confidence_active_command_id), 0.001);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 120 increment");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, window_height - toolbar_height - statusbar_height);
    var scrolled_layout = try harness.runtime.canvasWidgetLayout(1, "dashboard-canvas");
    try std.testing.expectEqual(@as(f32, 40), scrolled_layout.findById(120).?.widget.value);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expectEqual(@as(f32, 40), dashboardSnapshotWidget(snapshot, 120).?.scroll.offset);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    const activity_y_after_increment = try dashboardTextCommandOriginY(display_list, activity_first_text_command_id);
    try std.testing.expect(activity_y_after_increment < activity_y_before_scroll);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), "widget-action dashboard-canvas 120 decrement");
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, window_height - toolbar_height - statusbar_height);
    scrolled_layout = try harness.runtime.canvasWidgetLayout(1, "dashboard-canvas");
    try std.testing.expectEqual(@as(f32, 5), scrolled_layout.findById(120).?.widget.value);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expectEqual(@as(f32, 5), dashboardSnapshotWidget(snapshot, 120).?.scroll.offset);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    const activity_y_after_decrement = try dashboardTextCommandOriginY(display_list, activity_first_text_command_id);
    try std.testing.expect(activity_y_after_decrement > activity_y_after_increment);

    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_frame = .{
        .label = "dashboard-canvas",
        .size = geometry.SizeF.init(720, 520),
        .scale_factor = 2,
        .frame_index = 2,
        .timestamp_ns = 1_016_000_000,
        .nonblank = true,
    } });
    const status_view = dashboardViewByLabel(&harness.runtime, "status-label").?;
    try std.testing.expect(std.mem.indexOf(u8, status_view.text, "Canvas frame:") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_view.text, "risk") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_view.text, "work units") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_view.text, "dirty") != null);

    const frame = try harness.runtime.gpuSurfaceFrame(1, "dashboard-canvas");
    try std.testing.expect(frame.canvas_revision > 1);
    try std.testing.expectEqual(@as(usize, 64), frame.canvas_command_count);
    try std.testing.expect(frame.canvas_frame_requires_render);
    try std.testing.expect(!frame.canvas_frame_full_repaint);
    try std.testing.expect(frame.canvas_frame_change_count > 0);
    try std.testing.expect(frame.canvas_frame_dirty_bounds != null);
    try std.testing.expect(frame.canvas_frame_batch_count >= 8);
    try std.testing.expect(frame.canvas_frame_encoder_command_count >= frame.canvas_frame_batch_count);
    try std.testing.expectEqual(frame.canvas_frame_batch_count, frame.canvas_frame_encoder_draw_batch_count);
    try std.testing.expect(frame.canvas_frame_pipeline_count >= 4);
    try std.testing.expect(frame.canvas_frame_pipeline_retain_count >= 4);
}

test "gpu dashboard frame event adapter preserves renderer diagnostics" {
    const frame = zero_native.platform.GpuFrame{
        .window_id = 7,
        .label = "dashboard-canvas",
        .size = geometry.SizeF.init(720, 520),
        .scale_factor = 2,
        .frame_index = 42,
        .timestamp_ns = 1234,
        .nonblank = true,
        .sample_color = 0xff112233,
        .backend = .metal,
        .pixel_format = .bgra8_unorm,
        .present_mode = .timer,
        .alpha_mode = .@"opaque",
        .color_space = .srgb,
        .vsync = true,
        .status = .ready,
        .canvas_revision = 3,
        .canvas_command_count = 62,
        .canvas_frame_requires_render = true,
        .canvas_frame_full_repaint = false,
        .canvas_frame_batch_count = 12,
        .canvas_frame_encoder_command_count = 18,
        .canvas_frame_encoder_cache_action_count = 4,
        .canvas_frame_encoder_bind_pipeline_count = 5,
        .canvas_frame_encoder_draw_batch_count = 12,
        .canvas_frame_pipeline_count = 5,
        .canvas_frame_pipeline_upload_count = 1,
        .canvas_frame_pipeline_retain_count = 4,
        .canvas_frame_pipeline_evict_count = 0,
        .canvas_frame_path_geometry_count = 2,
        .canvas_frame_path_geometry_vertex_count = 36,
        .canvas_frame_path_geometry_index_count = 54,
        .canvas_frame_path_geometry_upload_count = 1,
        .canvas_frame_path_geometry_retain_count = 1,
        .canvas_frame_path_geometry_evict_count = 0,
        .canvas_frame_image_count = 3,
        .canvas_frame_image_upload_count = 1,
        .canvas_frame_image_retain_count = 2,
        .canvas_frame_image_evict_count = 0,
        .canvas_frame_layer_count = 2,
        .canvas_frame_layer_opacity_count = 1,
        .canvas_frame_layer_clip_count = 0,
        .canvas_frame_layer_transform_count = 1,
        .canvas_frame_layer_upload_count = 1,
        .canvas_frame_layer_retain_count = 1,
        .canvas_frame_layer_evict_count = 0,
        .canvas_frame_resource_count = 8,
        .canvas_frame_resource_upload_count = 2,
        .canvas_frame_resource_retain_count = 6,
        .canvas_frame_resource_evict_count = 0,
        .canvas_frame_visual_effect_count = 4,
        .canvas_frame_visual_effect_shadow_count = 3,
        .canvas_frame_visual_effect_blur_count = 1,
        .canvas_frame_visual_effect_upload_count = 1,
        .canvas_frame_visual_effect_retain_count = 3,
        .canvas_frame_visual_effect_evict_count = 0,
        .canvas_frame_glyph_atlas_entry_count = 16,
        .canvas_frame_glyph_atlas_upload_count = 2,
        .canvas_frame_glyph_atlas_retain_count = 14,
        .canvas_frame_glyph_atlas_evict_count = 0,
        .canvas_frame_text_layout_count = 10,
        .canvas_frame_text_layout_line_count = 10,
        .canvas_frame_text_layout_upload_count = 1,
        .canvas_frame_text_layout_retain_count = 9,
        .canvas_frame_text_layout_evict_count = 0,
        .canvas_frame_change_count = 0,
        .canvas_frame_budget_exceeded_count = 0,
        .canvas_frame_budget_ok = true,
        .canvas_frame_dirty_bounds = rect(10, 20, 30, 40),
        .canvas_frame_profile_work_units = 88,
        .canvas_frame_profile_risk = .moderate,
        .canvas_frame_profile_surface_area = 374400,
        .canvas_frame_profile_dirty_area = 1200,
        .canvas_frame_profile_dirty_ratio = 0.003205128,
        .widget_revision = 2,
        .widget_node_count = 10,
        .widget_semantics_count = 9,
    };
    const event_value = gpuFrameEvent(frame);

    try std.testing.expectEqual(frame.window_id, event_value.window_id);
    try std.testing.expectEqualStrings(frame.label, event_value.label);
    try std.testing.expectEqualDeep(frame.size, event_value.size);
    try std.testing.expectEqual(frame.present_mode, event_value.present_mode);
    try std.testing.expectEqual(frame.alpha_mode, event_value.alpha_mode);
    try std.testing.expectEqual(frame.color_space, event_value.color_space);
    try std.testing.expectEqual(frame.vsync, event_value.vsync);
    try std.testing.expectEqual(frame.canvas_frame_path_geometry_count, event_value.canvas_frame_path_geometry_count);
    try std.testing.expectEqual(frame.canvas_frame_path_geometry_vertex_count, event_value.canvas_frame_path_geometry_vertex_count);
    try std.testing.expectEqual(frame.canvas_frame_image_count, event_value.canvas_frame_image_count);
    try std.testing.expectEqual(frame.canvas_frame_layer_transform_count, event_value.canvas_frame_layer_transform_count);
    try std.testing.expectEqual(frame.canvas_frame_visual_effect_shadow_count, event_value.canvas_frame_visual_effect_shadow_count);
    try std.testing.expectEqual(frame.canvas_frame_text_layout_retain_count, event_value.canvas_frame_text_layout_retain_count);
    try std.testing.expectEqualDeep(frame.canvas_frame_dirty_bounds.?, event_value.canvas_frame_dirty_bounds.?);
    try std.testing.expectEqual(frame.canvas_frame_profile_work_units, event_value.canvas_frame_profile_work_units);
    try std.testing.expectEqual(frame.canvas_frame_profile_risk, event_value.canvas_frame_profile_risk);
    try std.testing.expectEqual(frame.canvas_frame_profile_surface_area, event_value.canvas_frame_profile_surface_area);
    try std.testing.expectEqual(frame.canvas_frame_profile_dirty_area, event_value.canvas_frame_profile_dirty_area);
    try std.testing.expectEqual(frame.canvas_frame_profile_dirty_ratio, event_value.canvas_frame_profile_dirty_ratio);
    try std.testing.expectEqual(frame.widget_semantics_count, event_value.widget_semantics_count);

    var status_buffer: [128]u8 = undefined;
    const status = try dashboardFrameStatus(&status_buffer, event_value);
    try std.testing.expectEqualStrings("Canvas frame: moderate risk, 88 work units, 62 commands, 12 batches, dirty 0%.", status);
}

fn expectVisiblePixel(pixel: [4]u8) !void {
    try std.testing.expect(pixel[3] > 0);
    try std.testing.expect(pixel[0] != 0 or pixel[1] != 0 or pixel[2] != 0);
}

fn referenceSurfaceSignature(pixels: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (pixels) |byte| {
        hash = (hash ^ byte) *% 1099511628211;
    }
    return hash;
}
