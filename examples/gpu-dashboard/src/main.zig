//! gpu-dashboard: a retained-canvas product dashboard authored with the
//! experimental `canvas.Ui` declarative builder.
//!
//! The app is one elm-style loop: `Model` -> `Msg` -> `update` -> `view`.
//! Widget identity is structural (hashed ids), layout is flex, and events
//! resolve to typed `Msg` values through the tree's handler table. The
//! non-widget chrome (background, toolbar title, separators, hero gradient)
//! is still a hand-built display-list prefix that the runtime preserves via
//! `emitCanvasWidgetDisplayListWithChrome`.

const std = @import("std");
const runner = @import("runner");
const zero_native = @import("zero-native");

pub const panic = std.debug.FullPanic(zero_native.debug.capturePanic);

const canvas = zero_native.canvas;
const geometry = zero_native.geometry;

const window_width: f32 = 1240;
const window_height: f32 = 780;
const toolbar_height: f32 = 54;
const canvas_pixel_width: usize = @intFromFloat(window_width);
const canvas_width: f32 = @floatFromInt(canvas_pixel_width);
const canvas_height: f32 = window_height;
const default_canvas_size = geometry.SizeF.init(canvas_width, canvas_height);
const statusbar_height: f32 = 34;
const max_dashboard_pipelines: usize = 8;
const max_dashboard_commands: usize = zero_native.runtime.max_canvas_commands_per_view;
const max_dashboard_glyphs: usize = zero_native.runtime.max_canvas_glyphs_per_view;
const max_dashboard_widgets: usize = 64;
const dashboard_chrome_prefix_commands: usize = 6;
const dashboard_chrome_suffix_commands: usize = 0;
const expected_dashboard_command_count: usize = 72;
const expected_dashboard_interaction_command_count: usize = 72;
const expected_dashboard_reference_signature: u64 = 17406427282194674082;
const expected_dashboard_widget_node_count: usize = 48;
const expected_dashboard_snapshot_widget_count: usize = 48;
const refresh_command = "dashboard.refresh";
const mode_command = "dashboard.mode";
const dashboard_canvas_label = "dashboard-canvas";

// Chrome display-list command ids. These live in the prefix that
// `emitCanvasWidgetDisplayListWithChrome` preserves in front of the
// widget-generated commands; they never collide with widget part ids
// (which are hashed widget ids multiplied into a distinct range).
const dashboard_background_command_id: canvas.ObjectId = 1;
const dashboard_toolbar_id: canvas.ObjectId = 80;
const dashboard_toolbar_title_id: canvas.ObjectId = 81;
const dashboard_toolbar_separator_id: canvas.ObjectId = 84;
const dashboard_status_separator_id: canvas.ObjectId = 260;
const dashboard_hero_command_id: canvas.ObjectId = 4;

// Display-list part slots used by the widget renderer for a widget's
// generated commands (`canvas.widgetCommandPartId`).
const widget_fill_slot: canvas.ObjectId = 1;
const widget_track_slot: canvas.ObjectId = 2;
const widget_thumb_slot: canvas.ObjectId = 3;
const widget_text_slot: canvas.ObjectId = 4;
const widget_composition_slot: canvas.ObjectId = 5;
const widget_popover_blur_slot: canvas.ObjectId = 12;

const initial_dashboard_status_text = "Canvas scene waiting for the first GPU frame.";
const max_dashboard_status_text: usize = 192;
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

const app_permissions = [_][]const u8{ zero_native.security.permission_command, zero_native.security.permission_view };
const shell_views = [_]zero_native.ShellView{
    .{ .label = dashboard_canvas_label, .kind = .gpu_surface, .fill = true, .min_width = 720, .layer = 12, .role = "Native-rendered dashboard canvas", .accessibility_label = "Native-rendered product dashboard canvas", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]zero_native.ShellWindow{.{
    .label = "main",
    .title = "zero-native GPU Dashboard",
    .width = window_width,
    .height = window_height,
    .restore_state = false,
    .views = &shell_views,
}};
const shell_scene: zero_native.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

const DashboardEntry = struct {
    index: u8,
    title: []const u8,
};

const nav_entries = [_]DashboardEntry{
    .{ .index = 0, .title = "Overview" },
    .{ .index = 1, .title = "Customers" },
    .{ .index = 2, .title = "Latency" },
};
const metric_entries = [_]DashboardEntry{
    .{ .index = 0, .title = "ARR $12.8M, up 18.4%" },
    .{ .index = 1, .title = "Activation 74.2%, up 6.1%" },
};
const activity_entries = [_]DashboardEntry{
    .{ .index = 0, .title = "Signed enterprise renewal" },
    .{ .index = 1, .title = "Usage spike in EU region" },
    .{ .index = 2, .title = "Latency budget recovered" },
    .{ .index = 3, .title = "Queued invoice batch" },
};
const filter_entries = [_]DashboardEntry{
    .{ .index = 0, .title = "Last 30 days" },
    .{ .index = 1, .title = "Enterprise" },
    .{ .index = 2, .title = "High intent" },
};

pub const Msg = union(enum) {
    refresh,
    set_mode,
    toggle_live,
    select_nav: u8,
    select_metric: u8,
    select_activity: u8,
    toggle_auto,
    confidence_changed,
    select_filter: u8,
    open_deployment,
    submit_forecast,
    submit_search,
};

pub const Model = struct {
    refresh_count: u32 = 0,
    mode_count: u32 = 0,
    live_count: u32 = 0,
    nav_selection: u8 = 0,
    metric_selection: ?u8 = null,
    activity_selection: ?u8 = null,
    filter_selection: ?u8 = null,
    auto_refresh: bool = true,
    confidence: f32 = 0.62,
    activity_scroll: f32 = 18,
    status_storage: [max_dashboard_status_text]u8 = undefined,
    status_len: usize = 0,

    pub fn status(model: *const Model) []const u8 {
        if (model.status_len == 0) return initial_dashboard_status_text;
        return model.status_storage[0..model.status_len];
    }

    pub fn setStatus(model: *Model, text: []const u8) void {
        const len = @min(text.len, model.status_storage.len);
        @memcpy(model.status_storage[0..len], text[0..len]);
        model.status_len = len;
    }

    fn setStatusFmt(model: *Model, comptime format: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&model.status_storage, format, args) catch {
            model.status_len = 0;
            return;
        };
        model.status_len = written.len;
    }
};

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .refresh => {
            model.refresh_count += 1;
            model.setStatusFmt("Dashboard canvas refreshed. Count {d}.", .{model.refresh_count});
        },
        .set_mode => {
            model.mode_count += 1;
            model.setStatusFmt("Dashboard mode changed. Count {d}.", .{model.mode_count});
        },
        .toggle_live => {
            model.live_count += 1;
            model.setStatusFmt("Live render pulse restarted. Count {d}.", .{model.live_count});
        },
        .select_nav => |index| {
            model.nav_selection = index;
            model.setStatusFmt("Selected {s}.", .{nav_entries[index].title});
        },
        .select_metric => |index| {
            model.metric_selection = index;
            model.setStatusFmt("Metric highlighted: {s}.", .{metric_entries[index].title});
        },
        .select_activity => |index| {
            model.activity_selection = index;
            model.setStatusFmt("Activity noted: {s}.", .{activity_entries[index].title});
        },
        .toggle_auto => {
            model.auto_refresh = !model.auto_refresh;
            model.setStatusFmt("Auto refresh {s}.", .{if (model.auto_refresh) "on" else "off"});
        },
        .confidence_changed => {
            model.setStatusFmt("Confidence threshold {d}%.", .{dashboardDirtyPercent(model.confidence)});
        },
        .select_filter => |index| {
            model.filter_selection = index;
            model.setStatusFmt("Filter {s} applied.", .{filter_entries[index].title});
        },
        .open_deployment => model.setStatus("Deployment iad1 latency opened."),
        .submit_forecast => model.setStatus("Forecast amount submitted."),
        .submit_search => model.setStatus("Segment search submitted."),
    }
}

// ------------------------------------------------------------------- view

pub const DashboardUi = canvas.Ui(Msg);

/// Leaf element with rendered text; the builder only special-cases the most
/// common text leaves (`text`, `button`, `listItem`), so widgets like the
/// segmented control, toggle, data grid, and fields set text directly.
fn textLeaf(ui: *DashboardUi, kind: canvas.WidgetKind, options: DashboardUi.ElementOptions, content: []const u8) DashboardUi.Node {
    var node = ui.el(kind, options, .{});
    node.widget.text = content;
    return node;
}

pub fn view(ui: *DashboardUi, model: *const Model) DashboardUi.Node {
    return ui.column(.{}, .{
        toolbarView(ui),
        contentView(ui, model),
        statusView(ui, model),
    });
}

fn toolbarView(ui: *DashboardUi) DashboardUi.Node {
    return ui.row(.{ .height = toolbar_height, .padding = 10, .gap = 12, .cross = .center }, .{
        // The chrome display list draws the "GPU Dashboard" title here.
        ui.el(.stack, .{ .width = 228 }, .{}),
        textLeaf(ui, .segmented_control, .{
            .width = 214,
            .semantics = .{ .label = "Dashboard mode" },
            .on_press = .set_mode,
        }, "Overview|Revenue|Latency"),
        ui.button(.{
            .variant = .secondary,
            .semantics = .{ .label = "Refresh dashboard" },
            .on_press = .refresh,
        }, "Refresh"),
        ui.spacer(1),
    });
}

fn contentView(ui: *DashboardUi, model: *const Model) DashboardUi.Node {
    return ui.row(.{ .grow = 1, .padding = 38, .gap = 24 }, .{
        heroColumn(ui, model),
        mainColumn(ui, model),
        sideColumn(ui, model),
    });
}

fn heroColumn(ui: *DashboardUi, model: *const Model) DashboardUi.Node {
    // Sits on top of the hero gradient the chrome display list paints.
    return ui.column(.{ .width = 168, .padding = 16, .gap = 12 }, .{
        ui.el(.list, .{
            .height = 108,
            .gap = 8,
            .semantics = .{ .label = "Dashboard navigation" },
        }, ui.eachCtx(model.nav_selection, &nav_entries, entryKey, navItem)),
    });
}

fn navItem(ui: *DashboardUi, selection: u8, entry: *const DashboardEntry) DashboardUi.Node {
    return ui.listItem(.{
        .selected = entry.index == selection,
        .on_press = Msg{ .select_nav = entry.index },
    }, entry.title);
}

fn mainColumn(ui: *DashboardUi, model: *const Model) DashboardUi.Node {
    return ui.column(.{ .grow = 1, .gap = 18 }, .{
        ui.column(.{ .gap = 6 }, .{
            ui.text(.{}, "Revenue pulse"),
            ui.text(.{}, "Retained canvas dashboard"),
        }),
        metricsGrid(ui, model),
        ui.el(.progress, .{
            .value = 0.68,
            .height = 10,
            .semantics = .{ .label = "Conversion progress" },
        }, .{}),
        trendPanel(ui),
        forecastPanel(ui, model),
    });
}

fn metricsGrid(ui: *DashboardUi, model: *const Model) DashboardUi.Node {
    var node = ui.el(.grid, .{
        .height = 76,
        .gap = 8,
        .semantics = .{ .role = .list, .label = "Dashboard metrics" },
    }, ui.eachCtx(model.metric_selection, &metric_entries, entryKey, metricItem));
    node.widget.layout.columns = 2;
    return node;
}

fn metricItem(ui: *DashboardUi, selection: ?u8, entry: *const DashboardEntry) DashboardUi.Node {
    return ui.listItem(.{
        .selected = selection != null and selection.? == entry.index,
        .on_press = Msg{ .select_metric = entry.index },
    }, entry.title);
}

fn trendPanel(ui: *DashboardUi) DashboardUi.Node {
    var grid = ui.el(.data_grid, .{ .height = 28 }, ui.el(.data_row, .{ .height = 28 }, textLeaf(ui, .data_cell, .{
        .grow = 1,
        .on_press = .open_deployment,
    }, "iad1 8.6ms P95")));
    grid.widget.text = "Deployment latency";
    return ui.panel(.{ .padding = 20, .semantics = .{ .label = "Conversion trend" } }, ui.column(.{ .gap = 14 }, .{
        ui.text(.{}, "Conversion trend"),
        grid,
    }));
}

fn forecastPanel(ui: *DashboardUi, model: *const Model) DashboardUi.Node {
    return ui.panel(.{ .padding = 14, .semantics = .{ .label = "Forecast form" } }, ui.row(.{ .gap = 14, .cross = .center }, .{
        textLeaf(ui, .text_field, .{
            .semantics = .{ .label = "Forecast amount" },
            .on_submit = .submit_forecast,
        }, "$13.4M"),
        textLeaf(ui, .search_field, .{
            .semantics = .{ .label = "Segment search" },
            .on_submit = .submit_search,
        }, "enterprise"),
        textLeaf(ui, .toggle, .{
            .checked = model.auto_refresh,
            .value = if (model.auto_refresh) 1 else 0,
            .semantics = .{ .label = "Auto refresh" },
            .on_toggle = .toggle_auto,
        }, "Auto"),
        ui.el(.slider, .{
            .value = model.confidence,
            .semantics = .{ .label = "Confidence threshold" },
            .on_change = .confidence_changed,
        }, .{}),
        ui.spacer(1),
    }));
}

fn sideColumn(ui: *DashboardUi, model: *const Model) DashboardUi.Node {
    return ui.column(.{ .width = 196, .gap = 16 }, .{
        ui.button(.{
            .semantics = .{ .label = "Live render status" },
            .on_press = .toggle_live,
        }, "Live render"),
        filterPopover(ui, model),
        ui.scroll(.{
            .height = 112,
            .value = model.activity_scroll,
            .semantics = .{ .label = "Recent activity" },
        }, ui.column(.{ .gap = 4 }, ui.eachCtx(model.activity_selection, &activity_entries, entryKey, activityItem))),
    });
}

fn filterPopover(ui: *DashboardUi, model: *const Model) DashboardUi.Node {
    var node = ui.el(.popover, .{
        .height = 118,
        .padding = 12,
        .semantics = .{ .label = "Revenue filter popover" },
    }, ui.el(.menu_surface, .{
        .gap = 2,
        .semantics = .{ .label = "Filter options" },
    }, ui.eachCtx(model.filter_selection, &filter_entries, entryKey, filterItem)));
    node.widget.backdrop_blur_token = .md;
    return node;
}

fn filterItem(ui: *DashboardUi, selection: ?u8, entry: *const DashboardEntry) DashboardUi.Node {
    return textLeaf(ui, .menu_item, .{
        .selected = selection != null and selection.? == entry.index,
        .on_press = Msg{ .select_filter = entry.index },
    }, entry.title);
}

fn activityItem(ui: *DashboardUi, selection: ?u8, entry: *const DashboardEntry) DashboardUi.Node {
    return ui.listItem(.{
        .height = 32,
        .selected = selection != null and selection.? == entry.index,
        .on_press = Msg{ .select_activity = entry.index },
    }, entry.title);
}

fn statusView(ui: *DashboardUi, model: *const Model) DashboardUi.Node {
    const status = model.status();
    return ui.row(.{ .height = statusbar_height, .padding = 8, .cross = .center }, .{
        ui.text(.{ .grow = 1, .size = .sm, .semantics = .{ .label = status } }, status),
    });
}

fn entryKey(entry: *const DashboardEntry) canvas.UiKey {
    return canvas.uiKey(entry.title);
}

// -------------------------------------------------------------------- app

const GpuDashboardApp = struct {
    model: Model = .{},
    arenas: [2]std.heap.ArenaAllocator,
    arena_index: usize = 0,
    tree: ?DashboardUi.Tree = null,
    live_button_id: canvas.ObjectId = 0,
    slider_id: canvas.ObjectId = 0,
    activity_scroll_id: canvas.ObjectId = 0,
    color_scheme: zero_native.ColorScheme = .light,
    reduce_motion: bool = false,
    high_contrast: bool = false,
    canvas_installed: bool = false,
    reported_planned_frame: bool = false,
    canvas_size: geometry.SizeF = default_canvas_size,
    pixel_snap_scale: f32 = 1,
    pixels: ?[]u8 = null,
    scratch: ?[]u8 = null,
    gpu_commands: [max_dashboard_commands]canvas.CanvasGpuCommand = undefined,
    packet_json: [zero_native.platform.max_gpu_surface_packet_json_bytes]u8 = undefined,
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

    fn init(backing: std.mem.Allocator) GpuDashboardApp {
        return .{ .arenas = .{
            std.heap.ArenaAllocator.init(backing),
            std.heap.ArenaAllocator.init(backing),
        } };
    }

    fn app(self: *@This()) zero_native.App {
        return .{
            .context = self,
            .name = "gpu-dashboard",
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
        self.tree = null;
        self.arenas[0].deinit();
        self.arenas[1].deinit();
    }

    fn scene(context: *anyopaque) anyerror!zero_native.ShellConfig {
        _ = context;
        return shell_scene;
    }

    fn event(context: *anyopaque, runtime: *zero_native.Runtime, event_value: zero_native.Event) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        switch (event_value) {
            .command => |command| {
                // CommandEvent is stringly by design; the shell command names
                // map onto the same typed messages the widgets dispatch.
                if (std.mem.eql(u8, command.name, refresh_command)) {
                    try self.dispatch(runtime, command.window_id, .refresh);
                } else if (std.mem.eql(u8, command.name, mode_command)) {
                    try self.dispatch(runtime, command.window_id, .set_mode);
                }
            },
            .gpu_surface_frame => |frame_event| try self.handleGpuFrame(runtime, frame_event),
            .canvas_widget_pointer => |pointer_event| try self.handleWidgetPointer(runtime, pointer_event),
            .canvas_widget_keyboard => |keyboard_event| try self.handleWidgetKeyboard(runtime, keyboard_event),
            .appearance_changed => |appearance| try self.applySystemAppearance(runtime, appearance),
            .gpu_surface_resized, .gpu_surface_input, .shortcut, .files_dropped, .canvas_widget_file_drop, .canvas_widget_drag, .lifecycle => {},
        }
    }

    fn stop(context: *anyopaque, runtime: *zero_native.Runtime) anyerror!void {
        _ = runtime;
        const self: *@This() = @ptrCast(@alignCast(context));
        self.deinit();
    }

    /// The elm-style loop: sync runtime-owned control state into the model,
    /// apply the message, and rebuild the widget tree from the model.
    fn dispatch(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId, msg: Msg) anyerror!void {
        self.syncRuntimeWidgetState(runtime, window_id);
        update(&self.model, msg);
        switch (msg) {
            .refresh => try self.reinstallCanvas(runtime, window_id),
            .toggle_live => {
                try self.rebuild(runtime, window_id);
                self.restartLivePulse(runtime, window_id);
            },
            else => try self.rebuild(runtime, window_id),
        }
    }

    /// The runtime owns transient control state that never reaches the app
    /// as a typed message payload: slider drags/steps (the `.change` message
    /// carries no value) and scroll offsets (scroll intents dispatch no
    /// message at all). Read the reconciled values back into the model
    /// before rebuilding so the next source tree does not stomp them.
    /// Slider values would also survive via `setCanvasWidgetLayout`'s
    /// control reconciliation, but scroll offsets reconcile from the source
    /// tree, so they must round-trip through the model.
    fn syncRuntimeWidgetState(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId) void {
        if (self.tree == null) return;
        const layout = runtime.canvasWidgetLayout(window_id, dashboard_canvas_label) catch return;
        if (self.slider_id != 0) {
            if (layout.findById(self.slider_id)) |node| self.model.confidence = node.widget.value;
        }
        if (self.activity_scroll_id != 0) {
            if (layout.findById(self.activity_scroll_id)) |node| self.model.activity_scroll = node.widget.value;
        }
    }

    /// Rebuild the widget tree from the model and hand it to the runtime,
    /// together with the chrome display-list prefix. The runtime copies and
    /// reconciles the layout, so the previous tree's arena stays alive only
    /// until the next rebuild (two arenas, swapped).
    fn rebuild(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId) anyerror!void {
        self.syncRuntimeWidgetState(runtime, window_id);
        const tokens = self.dashboardTokens();
        const next_index = self.arena_index ^ 1;
        _ = self.arenas[next_index].reset(.retain_capacity);
        var ui = DashboardUi.init(self.arenas[next_index].allocator());
        const tree = try ui.finalizeWithTokens(view(&ui, &self.model), tokens);

        const size = dashboardSurfaceSize(self.canvas_size);
        var nodes: [max_dashboard_widgets]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTreeWithTokens(tree.root, rect(0, 0, size.width, size.height), tokens, &nodes);

        var commands: [max_dashboard_commands]canvas.CanvasCommand = undefined;
        var builder = canvas.Builder.init(&commands);
        try buildDashboardDisplayListForSize(&builder, layout, tokens, size);
        _ = try runtime.setCanvasDisplayList(window_id, dashboard_canvas_label, builder.displayList());
        _ = try runtime.setCanvasWidgetLayout(window_id, dashboard_canvas_label, layout);
        _ = try runtime.emitCanvasWidgetDisplayListWithChrome(window_id, dashboard_canvas_label, tokens, .{
            .prefix_command_count = dashboard_chrome_prefix_commands,
            .suffix_command_count = dashboard_chrome_suffix_commands,
        });

        self.tree = tree;
        self.arena_index = next_index;
        self.live_button_id = widgetId(findWidgetKindText(tree.root, .button, "Live render"));
        self.slider_id = widgetId(findWidgetByKind(tree.root, .slider));
        self.activity_scroll_id = widgetId(findWidgetByKind(tree.root, .scroll_view));
    }

    fn handleGpuFrame(self: *@This(), runtime: *zero_native.Runtime, frame_event: zero_native.GpuSurfaceFrameEvent) anyerror!void {
        if (!std.mem.eql(u8, frame_event.label, dashboard_canvas_label)) return;
        const first_install = !self.canvas_installed;
        const scale_changed = self.updatePixelSnapScale(frame_event.scale_factor);
        const size_changed = self.updateCanvasSize(dashboardSurfaceSize(frame_event.size));
        if (first_install or scale_changed or size_changed) {
            if (first_install) self.model.setStatus("Dashboard display list presented on the GPU surface.");
            try self.rebuild(runtime, frame_event.window_id);
            try self.scheduleDashboardAnimations(runtime, frame_event.window_id, frame_event.timestamp_ns);
            try self.presentDashboardCanvas(runtime, frame_event, true);
            self.canvas_installed = true;
            return;
        }

        try self.presentDashboardCanvas(runtime, frame_event, frame_event.canvas_frame_full_repaint);
        const current_frame = try runtime.gpuSurfaceFrame(frame_event.window_id, dashboard_canvas_label);
        try self.reportFrameStatus(runtime, gpuFrameEvent(current_frame));
    }

    fn handleWidgetPointer(self: *@This(), runtime: *zero_native.Runtime, pointer_event: zero_native.runtime.CanvasWidgetPointerEvent) anyerror!void {
        if (!std.mem.eql(u8, pointer_event.view_label, dashboard_canvas_label)) return;
        const tree = self.tree orelse return;
        const target = pointer_event.target orelse return;
        if (tree.msgForPointer(target.id, pointer_event.pointer.phase)) |msg| {
            try self.dispatch(runtime, pointer_event.window_id, msg);
        }
    }

    fn handleWidgetKeyboard(self: *@This(), runtime: *zero_native.Runtime, keyboard_event: zero_native.runtime.CanvasWidgetKeyboardEvent) anyerror!void {
        if (!std.mem.eql(u8, keyboard_event.view_label, dashboard_canvas_label)) return;
        const tree = self.tree orelse return;
        const target = keyboard_event.target orelse return;
        if (tree.msgForKeyboard(target.id, keyboard_event.keyboard)) |msg| {
            try self.dispatch(runtime, keyboard_event.window_id, msg);
        }
    }

    fn reportFrameStatus(self: *@This(), runtime: *zero_native.Runtime, frame_event: zero_native.GpuSurfaceFrameEvent) anyerror!void {
        if (!self.reported_planned_frame and frame_event.canvas_command_count > 0) {
            self.reported_planned_frame = true;
            var status_buffer: [192]u8 = undefined;
            const status = try dashboardFrameStatus(&status_buffer, frame_event);
            self.model.setStatus(status);
            try self.rebuild(runtime, frame_event.window_id);
        }
    }

    /// Full reinstall path for the refresh message: reset diagnostics
    /// reporting, resync the surface size, rebuild, restart the pulse, and
    /// present a full repaint immediately (commands can arrive without a
    /// trailing frame event).
    fn reinstallCanvas(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId) anyerror!void {
        self.reported_planned_frame = false;
        const gpu_frame = runtime.gpuSurfaceFrame(window_id, dashboard_canvas_label) catch |err| switch (err) {
            error.WindowNotFound, error.ViewNotFound, error.InvalidViewOptions => {
                try self.rebuild(runtime, window_id);
                return;
            },
            else => return err,
        };
        _ = self.updateCanvasSize(dashboardSurfaceSize(gpu_frame.size));
        try self.rebuild(runtime, window_id);
        try self.scheduleDashboardAnimations(runtime, window_id, gpu_frame.timestamp_ns);
        try self.presentDashboardCanvas(runtime, gpuFrameEvent(gpu_frame), true);
    }

    fn restartLivePulse(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId) void {
        const gpu_frame = runtime.gpuSurfaceFrame(window_id, dashboard_canvas_label) catch return;
        self.scheduleDashboardAnimations(runtime, window_id, gpu_frame.timestamp_ns) catch {};
    }

    fn dashboardTokens(self: @This()) canvas.DesignTokens {
        return dashboardWidgetTokensForSchemeScaleMotionAndContrast(self.color_scheme, self.pixel_snap_scale, self.reduce_motion, self.high_contrast);
    }

    fn updatePixelSnapScale(self: *@This(), scale_factor: f32) bool {
        const next = normalizedPixelSnapScale(scale_factor);
        if (@abs(self.pixel_snap_scale - next) < 0.001) return false;
        self.pixel_snap_scale = next;
        return true;
    }

    fn updateCanvasSize(self: *@This(), size: geometry.SizeF) bool {
        if (dashboardSizesEqual(self.canvas_size, size)) return false;
        self.canvas_size = size;
        return true;
    }

    fn applySystemAppearance(self: *@This(), runtime: *zero_native.Runtime, appearance: zero_native.Appearance) anyerror!void {
        const scheme_changed = self.color_scheme != appearance.color_scheme;
        const motion_changed = self.reduce_motion != appearance.reduce_motion;
        const contrast_changed = self.high_contrast != appearance.high_contrast;
        if (!scheme_changed and !motion_changed and !contrast_changed) return;
        self.color_scheme = appearance.color_scheme;
        self.reduce_motion = appearance.reduce_motion;
        self.high_contrast = appearance.high_contrast;
        if (!self.canvas_installed) return;

        const gpu_frame = runtime.gpuSurfaceFrame(1, dashboard_canvas_label) catch |err| switch (err) {
            error.WindowNotFound, error.ViewNotFound, error.InvalidViewOptions => return,
            else => return err,
        };
        _ = self.updateCanvasSize(dashboardSurfaceSize(gpu_frame.size));
        self.model.setStatusFmt("Dashboard theme: {s} from system appearance.", .{@tagName(self.color_scheme)});
        try self.rebuild(runtime, 1);
        try self.scheduleDashboardAnimations(runtime, 1, gpu_frame.timestamp_ns);
        try self.presentDashboardCanvas(runtime, gpuFrameEvent(gpu_frame), true);
    }

    fn presentDashboardCanvas(self: *@This(), runtime: *zero_native.Runtime, frame_event: zero_native.GpuSurfaceFrameEvent, full_repaint: bool) anyerror!void {
        const surface_size = dashboardSurfaceSize(frame_event.size);
        const scale_factor = if (frame_event.scale_factor > 0) frame_event.scale_factor else 1;
        const present_scale = referencePresentScale(scale_factor);
        const packet = runtime.presentNextCanvasGpuPacketWithScale(
            frame_event.window_id,
            dashboard_canvas_label,
            .{
                .frame_index = frame_event.frame_index,
                .timestamp_ns = frame_event.timestamp_ns,
                .surface_size = surface_size,
                .scale = scale_factor,
                .full_repaint = full_repaint,
            },
            self.frameStorage(),
            color(246, 248, 252),
            &self.gpu_commands,
            &self.packet_json,
            present_scale,
        ) catch |err| switch (err) {
            error.UnsupportedService => {
                try self.presentDashboardCanvasPixels(runtime, frame_event.window_id, surface_size, scale_factor, frame_event.frame_index, frame_event.timestamp_ns, full_repaint);
                return;
            },
            else => return err,
        };
        if (!packet.fullyRepresentable()) return error.UnsupportedCommand;
    }

    fn presentDashboardCanvasPixels(
        self: *@This(),
        runtime: *zero_native.Runtime,
        window_id: zero_native.WindowId,
        surface_size: geometry.SizeF,
        scale_factor: f32,
        frame_index: u64,
        timestamp_ns: u64,
        full_repaint: bool,
    ) anyerror!void {
        const present_scale = referencePresentScale(scale_factor);
        try self.ensurePixelBuffers(surface_size, present_scale);
        _ = try runtime.presentNextCanvasFrame(
            window_id,
            dashboard_canvas_label,
            .{
                .frame_index = frame_index,
                .timestamp_ns = timestamp_ns,
                .surface_size = surface_size,
                .scale = scale_factor,
                .full_repaint = full_repaint,
            },
            self.frameStorage(),
            &self.gpu_commands,
            &self.packet_json,
            self.pixels.?,
            self.scratch.?,
            color(246, 248, 252),
            present_scale,
        );
    }

    fn referencePresentScale(scale_factor: f32) f32 {
        const normalized = if (scale_factor > 0) scale_factor else 1;
        return normalized;
    }

    fn liveButtonFillCommandId(self: *const @This()) canvas.ObjectId {
        return widgetPartCommandId(self.live_button_id, widget_fill_slot);
    }

    fn scheduleDashboardAnimations(self: *@This(), runtime: *zero_native.Runtime, window_id: zero_native.WindowId, start_ns: u64) anyerror!void {
        if (self.live_button_id == 0) return;
        const motion = dashboardWidgetTokens().motion;
        const animations = [_]canvas.CanvasRenderAnimation{
            motion.animation(.{
                .id = widgetPartCommandId(self.live_button_id, widget_fill_slot),
                .start_ns = start_ns,
                .duration = .slow,
                .from_opacity = 0.72,
                .to_opacity = 1,
                .from_transform = canvas.Affine.translate(0, -7),
                .to_transform = canvas.Affine.identity(),
            }),
            motion.animation(.{
                .id = widgetPartCommandId(self.live_button_id, widget_text_slot),
                .start_ns = start_ns,
                .duration = .slow,
                .from_opacity = 0.72,
                .to_opacity = 1,
                .from_transform = canvas.Affine.translate(0, -7),
                .to_transform = canvas.Affine.identity(),
            }),
        };
        _ = try runtime.setCanvasRenderAnimations(window_id, dashboard_canvas_label, &animations);
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

// -------------------------------------------------------- widget helpers

fn widgetId(widget: ?canvas.Widget) canvas.ObjectId {
    return if (widget) |value| value.id else 0;
}

fn widgetPartCommandId(id: canvas.ObjectId, slot: canvas.ObjectId) canvas.ObjectId {
    return canvas.widgetCommandPartId(.{ .widget_id = id, .slot = slot });
}

fn findWidgetByKind(widget: canvas.Widget, kind: canvas.WidgetKind) ?canvas.Widget {
    if (widget.kind == kind) return widget;
    for (widget.children) |child| {
        if (findWidgetByKind(child, kind)) |found| return found;
    }
    return null;
}

fn findWidgetKindText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findWidgetKindText(child, kind, text)) |found| return found;
    }
    return null;
}

fn findWidgetByLabel(widget: canvas.Widget, label: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.semantics.label, label)) return widget;
    for (widget.children) |child| {
        if (findWidgetByLabel(child, label)) |found| return found;
    }
    return null;
}

// ------------------------------------------------------- chrome + tokens

fn dashboardSurfaceSize(size: geometry.SizeF) geometry.SizeF {
    if (size.isEmpty()) return default_canvas_size;
    return .{
        .width = @max(1, size.width),
        .height = @max(1, size.height),
    };
}

fn dashboardBackdropRect(surface_size: geometry.SizeF) geometry.RectF {
    const size = dashboardSurfaceSize(surface_size);
    return rect(0, 0, size.width, size.height);
}

fn dashboardToolbarHeightForSize(surface_size: geometry.SizeF) f32 {
    const size = dashboardSurfaceSize(surface_size);
    const status_height = dashboardStatusbarHeightForSize(size);
    return @min(toolbar_height, @max(0, size.height - status_height - 1));
}

fn dashboardStatusbarHeightForSize(surface_size: geometry.SizeF) f32 {
    const size = dashboardSurfaceSize(surface_size);
    return @min(statusbar_height, @max(0, size.height - 1));
}

fn dashboardContentYForSize(surface_size: geometry.SizeF) f32 {
    return dashboardToolbarHeightForSize(surface_size);
}

fn dashboardContentHeightForSize(surface_size: geometry.SizeF) f32 {
    const size = dashboardSurfaceSize(surface_size);
    return @max(1, size.height - dashboardToolbarHeightForSize(size) - dashboardStatusbarHeightForSize(size));
}

fn dashboardHeroRect(surface_size: geometry.SizeF) geometry.RectF {
    const size = dashboardSurfaceSize(surface_size);
    return rect(38, dashboardContentYForSize(size) + 38, 168, @max(444, dashboardContentHeightForSize(size) - 76));
}

fn dashboardSizesEqual(a: geometry.SizeF, b: geometry.SizeF) bool {
    return a.width == b.width and a.height == b.height;
}

fn buildDashboardDisplayListForSize(builder: *canvas.Builder, layout: canvas.WidgetLayoutTree, tokens: canvas.DesignTokens, surface_size: geometry.SizeF) canvas.Error!void {
    const size = dashboardSurfaceSize(surface_size);
    const backdrop_rect = dashboardBackdropRect(size);
    const hero_rect = dashboardHeroRect(size);
    const content_y = dashboardContentYForSize(size);
    const content_height = dashboardContentHeightForSize(size);
    try builder.fillRect(.{ .id = dashboard_background_command_id, .rect = backdrop_rect, .fill = .{ .color = tokens.colors.background } });
    try builder.fillRect(.{ .id = dashboard_toolbar_id, .rect = rect(0, 0, size.width, toolbar_height), .fill = .{ .color = tokens.colors.surface } });
    try builder.drawText(.{
        .id = dashboard_toolbar_title_id,
        .font_id = tokens.typography.font_id,
        .size = 16,
        .origin = geometry.PointF.init(18, 33),
        .color = tokens.colors.text,
        .text = "GPU Dashboard",
        .text_layout = .{
            .max_width = 220,
            .line_height = 20,
        },
    });
    try builder.fillRect(.{ .id = dashboard_toolbar_separator_id, .rect = rect(0, toolbar_height - 1, size.width, 1), .fill = .{ .color = tokens.colors.border } });
    try builder.fillRect(.{ .id = dashboard_status_separator_id, .rect = rect(0, content_y + content_height, size.width, 1), .fill = .{ .color = tokens.colors.border } });
    try builder.fillRoundedRect(.{ .id = dashboard_hero_command_id, .rect = hero_rect, .radius = canvas.Radius.all(16), .fill = .{ .linear_gradient = .{ .start = hero_rect.topLeft(), .end = hero_rect.bottomRight(), .stops = &hero_stops } } });

    try layout.emitDisplayList(builder, tokens);
}

fn dashboardWidgetTokens() canvas.DesignTokens {
    return dashboardWidgetTokensForScale(1);
}

fn dashboardWidgetTokensForScale(pixel_snap_scale: f32) canvas.DesignTokens {
    return dashboardWidgetTokensForSchemeAndScale(.light, pixel_snap_scale);
}

fn dashboardWidgetTokensForSchemeAndScale(color_scheme: zero_native.ColorScheme, pixel_snap_scale: f32) canvas.DesignTokens {
    return dashboardWidgetTokensForSchemeScaleAndMotion(color_scheme, pixel_snap_scale, false);
}

fn dashboardWidgetTokensForSchemeScaleAndMotion(color_scheme: zero_native.ColorScheme, pixel_snap_scale: f32, reduce_motion: bool) canvas.DesignTokens {
    return dashboardWidgetTokensForSchemeScaleMotionAndContrast(color_scheme, pixel_snap_scale, reduce_motion, false);
}

fn dashboardWidgetTokensForSchemeScaleMotionAndContrast(color_scheme: zero_native.ColorScheme, pixel_snap_scale: f32, reduce_motion: bool, high_contrast: bool) canvas.DesignTokens {
    var tokens = canvas.DesignTokens.theme(.{ .color_scheme = switch (color_scheme) {
        .light => .light,
        .dark => .dark,
    }, .contrast = if (high_contrast) .high else .standard, .reduce_motion = reduce_motion });
    tokens.blur = .{
        .sm = 8,
        .md = dashboard_glass_blur,
    };
    if (!reduce_motion) tokens.motion = .{
        .slow_ms = 900,
        .easing = .emphasized,
    };
    tokens.pixel_snap = .{ .geometry = true, .text = true, .scale = normalizedPixelSnapScale(pixel_snap_scale) };
    return tokens;
}

fn normalizedPixelSnapScale(scale_factor: f32) f32 {
    if (!std.math.isFinite(scale_factor) or scale_factor <= 0) return 1;
    return scale_factor;
}

// --------------------------------------------------------- frame helpers

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
        .frame_interval_ns = frame.frame_interval_ns,
        .input_timestamp_ns = frame.input_timestamp_ns,
        .input_latency_ns = frame.input_latency_ns,
        .input_latency_budget_ns = frame.input_latency_budget_ns,
        .input_latency_budget_exceeded_count = frame.input_latency_budget_exceeded_count,
        .input_latency_budget_ok = frame.input_latency_budget_ok,
        .first_frame_latency_ns = frame.first_frame_latency_ns,
        .first_frame_latency_budget_ns = frame.first_frame_latency_budget_ns,
        .first_frame_latency_budget_exceeded_count = frame.first_frame_latency_budget_exceeded_count,
        .first_frame_latency_budget_ok = frame.first_frame_latency_budget_ok,
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
        .canvas_frame_gpu_packet_command_count = frame.canvas_frame_gpu_packet_command_count,
        .canvas_frame_gpu_packet_cache_action_count = frame.canvas_frame_gpu_packet_cache_action_count,
        .canvas_frame_gpu_packet_cached_resource_command_count = frame.canvas_frame_gpu_packet_cached_resource_command_count,
        .canvas_frame_gpu_packet_unsupported_command_count = frame.canvas_frame_gpu_packet_unsupported_command_count,
        .canvas_frame_gpu_packet_representable = frame.canvas_frame_gpu_packet_representable,
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
        "Canvas frame: {s} risk, {d} work units, {d} commands, {d} batches, packet {s}, dirty {d}%.",
        .{
            @tagName(frame_event.canvas_frame_profile_risk),
            frame_event.canvas_frame_profile_work_units,
            frame_event.canvas_command_count,
            frame_event.canvas_frame_batch_count,
            if (frame_event.canvas_frame_gpu_packet_representable) "ok" else "fallback",
            dashboardDirtyPercent(frame_event.canvas_frame_profile_dirty_ratio),
        },
    );
}

fn dashboardDirtyPercent(ratio: f32) u32 {
    return @as(u32, @intFromFloat(@round(std.math.clamp(ratio, 0, 1) * 100.0)));
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
    var app = GpuDashboardApp.init(std.heap.page_allocator);
    try runner.runWithOptions(app.app(), .{
        .app_name = "gpu-dashboard",
        .window_title = "zero-native GPU Dashboard",
        .bundle_id = "dev.zero_native.gpu_dashboard",
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

// ------------------------------------------------------------------ tests

fn buildTestTree(arena: std.mem.Allocator, model: *const Model) !DashboardUi.Tree {
    var ui = DashboardUi.init(arena);
    return ui.finalizeWithTokens(view(&ui, model), dashboardWidgetTokens());
}

fn layoutTestTree(tree: DashboardUi.Tree, size: geometry.SizeF, nodes: []canvas.WidgetLayoutNode) !canvas.WidgetLayoutTree {
    return canvas.layoutWidgetTreeWithTokens(tree.root, rect(0, 0, size.width, size.height), dashboardWidgetTokens(), nodes);
}

fn dashboardSnapshotWidgetNamed(snapshot: zero_native.automation.snapshot.Input, role: []const u8, name: []const u8) ?zero_native.automation.snapshot.Widget {
    for (snapshot.widgets) |widget| {
        if (!std.mem.eql(u8, widget.view_label, dashboard_canvas_label)) continue;
        if (!std.mem.eql(u8, widget.role, role)) continue;
        if (std.mem.eql(u8, widget.name, name)) return widget;
    }
    return null;
}

fn dashboardSnapshotWidgetNameContains(snapshot: zero_native.automation.snapshot.Input, role: []const u8, fragment: []const u8) ?zero_native.automation.snapshot.Widget {
    for (snapshot.widgets) |widget| {
        if (!std.mem.eql(u8, widget.view_label, dashboard_canvas_label)) continue;
        if (!std.mem.eql(u8, widget.role, role)) continue;
        if (std.mem.indexOf(u8, widget.name, fragment) != null) return widget;
    }
    return null;
}

fn dashboardSnapshotWidgetById(snapshot: zero_native.automation.snapshot.Input, id: u64) ?zero_native.automation.snapshot.Widget {
    for (snapshot.widgets) |widget| {
        if (widget.id == id and std.mem.eql(u8, widget.view_label, dashboard_canvas_label)) return widget;
    }
    return null;
}

fn expectDashboardFillRectFrame(display_list: canvas.DisplayList, id: canvas.ObjectId, expected: geometry.RectF) !void {
    const command_ref = display_list.findCommandById(id) orelse return error.MissingDashboardCommand;
    switch (command_ref.command) {
        .fill_rect => |fill| try expectDashboardRect(fill.rect, expected),
        else => return error.UnexpectedDashboardCommand,
    }
}

fn expectDashboardFillRectColor(display_list: canvas.DisplayList, id: canvas.ObjectId, expected: canvas.Color) !void {
    const command_ref = display_list.findCommandById(id) orelse return error.MissingDashboardCommand;
    switch (command_ref.command) {
        .fill_rect => |fill| switch (fill.fill) {
            .color => |actual| try std.testing.expectEqualDeep(expected, actual),
            else => return error.UnexpectedDashboardCommand,
        },
        else => return error.UnexpectedDashboardCommand,
    }
}

fn expectDashboardRoundedRectFrame(display_list: canvas.DisplayList, id: canvas.ObjectId, expected: geometry.RectF) !void {
    const command_ref = display_list.findCommandById(id) orelse return error.MissingDashboardCommand;
    switch (command_ref.command) {
        .fill_rounded_rect => |rounded| try expectDashboardRect(rounded.rect, expected),
        else => return error.UnexpectedDashboardCommand,
    }
}

fn expectDashboardTextCommand(display_list: canvas.DisplayList, id: canvas.ObjectId, expected: []const u8) !void {
    const command_ref = display_list.findCommandById(id) orelse return error.MissingDashboardCommand;
    switch (command_ref.command) {
        .draw_text => |text| try std.testing.expectEqualStrings(expected, text.text),
        else => return error.UnexpectedDashboardCommand,
    }
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

fn dashboardLayoutFrame(layout: canvas.WidgetLayoutTree, id: canvas.ObjectId) !geometry.RectF {
    const node = layout.findById(id) orelse return error.TestUnexpectedResult;
    return node.frame;
}

fn expectDashboardFramesDoNotOverlap(layout: canvas.WidgetLayoutTree, a_id: canvas.ObjectId, b_id: canvas.ObjectId) !void {
    const a = try dashboardLayoutFrame(layout, a_id);
    const b = try dashboardLayoutFrame(layout, b_id);
    try std.testing.expect(geometry.RectF.intersection(a.normalized(), b.normalized()).isEmpty());
}

fn expectDashboardFrameVisible(layout: canvas.WidgetLayoutTree, id: canvas.ObjectId, bounds: geometry.RectF) !void {
    const frame = (try dashboardLayoutFrame(layout, id)).normalized();
    try std.testing.expect(frame.width > 0);
    try std.testing.expect(frame.height > 0);
    try std.testing.expect(frame.x >= bounds.x - 0.001);
    try std.testing.expect(frame.y >= bounds.y - 0.001);
    try std.testing.expect(frame.maxX() <= bounds.maxX() + 0.001);
    try std.testing.expect(frame.maxY() <= bounds.maxY() + 0.001);
}

fn expectDashboardRect(actual: geometry.RectF, expected: geometry.RectF) !void {
    try std.testing.expectApproxEqAbs(expected.x, actual.x, 0.001);
    try std.testing.expectApproxEqAbs(expected.y, actual.y, 0.001);
    try std.testing.expectApproxEqAbs(expected.width, actual.width, 0.001);
    try std.testing.expectApproxEqAbs(expected.height, actual.height, 0.001);
}

test "gpu dashboard scene declares one full-window zero-native canvas" {
    try std.testing.expectEqual(@as(usize, 1), shell_views.len);
    try std.testing.expect(shell_views[0].kind == .gpu_surface);
    try std.testing.expect(shell_views[0].parent == null);
    try std.testing.expect(shell_views[0].fill);
    try std.testing.expect(shell_views[0].gpu_backend.? == .metal);
    try std.testing.expect(shell_views[0].gpu_pixel_format.? == .bgra8_unorm);
    try std.testing.expect(shell_views[0].gpu_present_mode.? == .timer);
    try std.testing.expect(shell_views[0].gpu_alpha_mode.? == .@"opaque");
    try std.testing.expect(shell_views[0].gpu_color_space.? == .srgb);
    try std.testing.expect(shell_views[0].gpu_vsync.?);
}

test "gpu dashboard view builds a complete retained display list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const model = Model{};
    const tree = try buildTestTree(arena_state.allocator(), &model);
    var nodes: [max_dashboard_widgets]canvas.WidgetLayoutNode = undefined;
    const layout = try layoutTestTree(tree, default_canvas_size, &nodes);

    var commands: [max_dashboard_commands]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try buildDashboardDisplayListForSize(&builder, layout, dashboardWidgetTokens(), default_canvas_size);
    const display_list = builder.displayList();

    try std.testing.expectEqual(@as(usize, expected_dashboard_command_count), display_list.commandCount());
    try std.testing.expect(display_list.findCommandById(dashboard_background_command_id) != null);
    try std.testing.expect(display_list.findCommandById(dashboard_hero_command_id) != null);

    const live_button = findWidgetKindText(tree.root, .button, "Live render").?;
    try std.testing.expect(display_list.findCommandById(widgetPartCommandId(live_button.id, widget_fill_slot)) != null);
    try std.testing.expect(display_list.findCommandById(widgetPartCommandId(live_button.id, widget_text_slot)) != null);

    const scroll = findWidgetByKind(tree.root, .scroll_view).?;
    try std.testing.expect(display_list.findCommandById(widgetPartCommandId(scroll.id, widget_track_slot)) != null);
    try std.testing.expect(display_list.findCommandById(widgetPartCommandId(scroll.id, widget_thumb_slot)) != null);

    const popover = findWidgetByKind(tree.root, .popover).?;
    try std.testing.expect(display_list.findCommandById(widgetPartCommandId(popover.id, widget_popover_blur_slot)) != null);

    const cell = findWidgetByKind(tree.root, .data_cell).?;
    try expectDashboardTextCommand(display_list, widgetPartCommandId(cell.id, widget_text_slot), "iad1 8.6ms P95");

    const bounds = display_list.bounds().?;
    try std.testing.expect(bounds.x <= 0);
    try std.testing.expect(bounds.y <= 0);
    try std.testing.expect(bounds.width >= canvas_width);
    try std.testing.expect(bounds.height >= canvas_height);
}

test "gpu dashboard flex layout keeps controls visually separated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const model = Model{};
    const tree = try buildTestTree(arena_state.allocator(), &model);
    var nodes: [max_dashboard_widgets]canvas.WidgetLayoutNode = undefined;
    const layout = try layoutTestTree(tree, default_canvas_size, &nodes);

    const canvas_bounds = rect(0, 0, canvas_width, canvas_height);
    const segmented = findWidgetByKind(tree.root, .segmented_control).?;
    const refresh_button = findWidgetKindText(tree.root, .button, "Refresh").?;
    const live_button = findWidgetKindText(tree.root, .button, "Live render").?;
    const metrics = findWidgetByLabel(tree.root, "Dashboard metrics").?;
    const progress = findWidgetByKind(tree.root, .progress).?;
    const trend_panel = findWidgetByLabel(tree.root, "Conversion trend").?;
    const forecast_panel = findWidgetByLabel(tree.root, "Forecast form").?;
    const nav_list = findWidgetByLabel(tree.root, "Dashboard navigation").?;
    const scroll = findWidgetByKind(tree.root, .scroll_view).?;
    const popover = findWidgetByKind(tree.root, .popover).?;
    const forecast_field = findWidgetByKind(tree.root, .text_field).?;
    const search_field = findWidgetByKind(tree.root, .search_field).?;
    const auto_toggle = findWidgetByKind(tree.root, .toggle).?;
    const slider = findWidgetByKind(tree.root, .slider).?;
    const status_text = findWidgetByLabel(tree.root, initial_dashboard_status_text).?;

    // Everything lands inside the canvas with a real hit-testable area.
    const ids = [_]canvas.ObjectId{
        segmented.id,      refresh_button.id, live_button.id, metrics.id, progress.id,
        trend_panel.id,    forecast_panel.id, nav_list.id,    scroll.id,  popover.id,
        forecast_field.id, search_field.id,   auto_toggle.id, slider.id,  status_text.id,
    };
    for (ids) |id| try expectDashboardFrameVisible(layout, id, canvas_bounds);

    // Toolbar controls clear the chrome title and each other.
    const segmented_frame = try dashboardLayoutFrame(layout, segmented.id);
    try std.testing.expect(segmented_frame.x >= 238);
    try std.testing.expect(segmented_frame.maxY() <= toolbar_height + 0.001);
    try expectDashboardFramesDoNotOverlap(layout, segmented.id, refresh_button.id);

    // Content sections do not collide.
    try expectDashboardFramesDoNotOverlap(layout, live_button.id, popover.id);
    try expectDashboardFramesDoNotOverlap(layout, metrics.id, popover.id);
    try expectDashboardFramesDoNotOverlap(layout, metrics.id, progress.id);
    try expectDashboardFramesDoNotOverlap(layout, progress.id, trend_panel.id);
    try expectDashboardFramesDoNotOverlap(layout, trend_panel.id, scroll.id);
    try expectDashboardFramesDoNotOverlap(layout, trend_panel.id, forecast_panel.id);
    try expectDashboardFramesDoNotOverlap(layout, scroll.id, forecast_panel.id);
    try expectDashboardFramesDoNotOverlap(layout, nav_list.id, metrics.id);
    try expectDashboardFramesDoNotOverlap(layout, forecast_field.id, search_field.id);
    try expectDashboardFramesDoNotOverlap(layout, search_field.id, auto_toggle.id);
    try expectDashboardFramesDoNotOverlap(layout, auto_toggle.id, slider.id);

    // The nav list sits on the hero gradient the chrome paints.
    const nav_frame = try dashboardLayoutFrame(layout, nav_list.id);
    const hero = dashboardHeroRect(default_canvas_size);
    try std.testing.expect(!geometry.RectF.intersection(nav_frame.normalized(), hero.normalized()).isEmpty());

    // The status line stays under the content area, over the status bar.
    const status_frame = try dashboardLayoutFrame(layout, status_text.id);
    const content_end = dashboardContentYForSize(default_canvas_size) + dashboardContentHeightForSize(default_canvas_size);
    try std.testing.expect(status_frame.y >= content_end);
}

test "gpu dashboard typed messages drive the model" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = Model{};

    // Toolbar refresh resolves through the pointer intent cascade.
    var tree = try buildTestTree(arena, &model);
    const refresh_button = findWidgetKindText(tree.root, .button, "Refresh").?;
    update(&model, tree.msgForPointer(refresh_button.id, .up).?);
    try std.testing.expectEqual(@as(u32, 1), model.refresh_count);
    try std.testing.expectEqualStrings("Dashboard canvas refreshed. Count 1.", model.status());
    try std.testing.expectEqual(@as(?Msg, null), tree.msgForPointer(refresh_button.id, .down));

    // The segmented control and the shell command map to the same message.
    const segmented = findWidgetByKind(tree.root, .segmented_control).?;
    try std.testing.expectEqual(Msg.set_mode, tree.msgForPointer(segmented.id, .up).?);

    // Selecting a nav row updates the selection and its id survives rebuild.
    const customers = findWidgetKindText(tree.root, .list_item, "Customers").?;
    update(&model, tree.msgForPointer(customers.id, .up).?);
    try std.testing.expectEqual(@as(u8, 1), model.nav_selection);
    try std.testing.expectEqualStrings("Selected Customers.", model.status());

    tree = try buildTestTree(arena, &model);
    const rebuilt_customers = findWidgetKindText(tree.root, .list_item, "Customers").?;
    try std.testing.expectEqual(customers.id, rebuilt_customers.id);
    try std.testing.expect(rebuilt_customers.state.selected);

    // Space on the focused toggle flips auto refresh.
    const auto_toggle = findWidgetByKind(tree.root, .toggle).?;
    const space_down = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "space" };
    update(&model, tree.msgForKeyboard(auto_toggle.id, space_down).?);
    try std.testing.expect(!model.auto_refresh);
    try std.testing.expectEqualStrings("Auto refresh off.", model.status());

    // Enter submits from the forecast field.
    const forecast_field = findWidgetByKind(tree.root, .text_field).?;
    const enter_down = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "enter" };
    update(&model, tree.msgForKeyboard(forecast_field.id, enter_down).?);
    try std.testing.expectEqualStrings("Forecast amount submitted.", model.status());

    // Slider arrow steps resolve to the change message.
    const slider = findWidgetByKind(tree.root, .slider).?;
    const arrow_right = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "arrowright" };
    try std.testing.expectEqual(Msg.confidence_changed, tree.msgForKeyboard(slider.id, arrow_right).?);

    // Widgets without handlers dispatch nothing.
    tree = try buildTestTree(arena, &model);
    const status_text = findWidgetByLabel(tree.root, model.status()).?;
    try std.testing.expectEqual(@as(?Msg, null), tree.msgForPointer(status_text.id, .up));
}

test "gpu dashboard display list renders through the reference surface" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const model = Model{};
    const tree = try buildTestTree(arena_state.allocator(), &model);
    var nodes: [max_dashboard_widgets]canvas.WidgetLayoutNode = undefined;
    const layout = try layoutTestTree(tree, default_canvas_size, &nodes);

    var commands: [max_dashboard_commands]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try buildDashboardDisplayListForSize(&builder, layout, dashboardWidgetTokens(), default_canvas_size);
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
        .surface_size = geometry.SizeF.init(canvas_width, canvas_height),
        .full_repaint = true,
    }, dashboardFrameStorage(&render_commands, &render_batches, &pipeline_cache_entries, &pipeline_cache_actions, &layers, &layer_cache_entries, &layer_cache_actions, &resources, &cache_entries, &cache_actions, &visual_effects, &visual_effect_cache_entries, &visual_effect_cache_actions, &glyphs, &glyph_cache_entries, &glyph_cache_actions, &text_layout_plans, &text_layout_lines, &text_layout_cache_entries, &text_layout_cache_actions, &changes));

    try std.testing.expect(frame.requiresRender());
    try std.testing.expect(frame.batch_plan.batchCount() >= 8);
    try std.testing.expect(frame.pipeline_cache_plan.entryCount() >= 4);
    try std.testing.expect(frame.pipeline_cache_plan.uploadCount() >= 4);
    try std.testing.expectEqual(@as(usize, 1), frame.layer_plan.layerCount());
    try std.testing.expectEqual(@as(usize, 1), frame.layer_cache_plan.uploadCount());
    try std.testing.expect(frame.resource_plan.resourceCount() >= 8);
    try std.testing.expect(frame.visual_effect_plan.effectCount() >= 4);
    try std.testing.expect(frame.visual_effect_plan.shadowCount() >= 3);
    try std.testing.expect(frame.visual_effect_plan.blurCount() >= 1);
    try std.testing.expect(frame.visual_effect_cache_plan.uploadCount() >= 4);
    try std.testing.expect(frame.text_layout_plan.planCount() >= 10);
    var encoder_commands: [max_dashboard_glyphs + max_dashboard_commands * 3]canvas.RenderEncoderCommand = undefined;
    const encoder_plan = try frame.renderPass().encoderPlan(&encoder_commands);
    try std.testing.expectEqual(frame.batch_plan.batchCount(), encoder_plan.drawBatchCount());
    try std.testing.expect(encoder_plan.cacheActionCount() >= frame.pipeline_cache_plan.actionCount());

    const pixel_count = canvas_pixel_width * @as(usize, @intFromFloat(canvas_height)) * 4;
    const pixels = try std.testing.allocator.alloc(u8, pixel_count);
    defer std.testing.allocator.free(pixels);
    const scratch = try std.testing.allocator.alloc(u8, pixel_count);
    defer std.testing.allocator.free(scratch);
    @memset(pixels, 0);
    const surface = try canvas.ReferenceRenderSurface.initWithScratch(canvas_pixel_width, @intFromFloat(canvas_height), pixels, scratch);
    try surface.renderPass(frame.renderPass(), color(0, 0, 0));

    try std.testing.expectEqual(@as(u64, expected_dashboard_reference_signature), referenceSurfaceSignature(pixels));
    try expectVisiblePixel(surface.pixelRgba8(8, 8));
    try expectVisiblePixel(surface.pixelRgba8(64, 140));
    try expectVisiblePixel(surface.pixelRgba8(620, 390));
    try std.testing.expectEqual(@as(u8, 255), surface.pixelRgba8(620, 390)[3]);
}

test "gpu dashboard render overrides animate without rebuilding commands" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const model = Model{};
    const tree = try buildTestTree(arena_state.allocator(), &model);
    var nodes: [max_dashboard_widgets]canvas.WidgetLayoutNode = undefined;
    const layout = try layoutTestTree(tree, default_canvas_size, &nodes);
    const live_button = findWidgetKindText(tree.root, .button, "Live render").?;
    const live_fill_command_id = widgetPartCommandId(live_button.id, widget_fill_slot);

    var commands: [max_dashboard_commands]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try buildDashboardDisplayListForSize(&builder, layout, dashboardWidgetTokens(), default_canvas_size);
    const display_list = builder.displayList();

    const motion = dashboardWidgetTokens().motion;
    const animations = [_]canvas.CanvasRenderAnimation{motion.animation(.{
        .id = live_fill_command_id,
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
    var gpu_commands: [max_dashboard_commands]canvas.CanvasGpuCommand = undefined;

    const frame = try dashboardFrame(display_list, display_list, .{
        .surface_size = geometry.SizeF.init(canvas_width, canvas_height),
        .render_overrides = sampled,
    }, dashboardFrameStorage(&render_commands, &render_batches, &pipeline_cache_entries, &pipeline_cache_actions, &layers, &layer_cache_entries, &layer_cache_actions, &resources, &cache_entries, &cache_actions, &visual_effects, &visual_effect_cache_entries, &visual_effect_cache_actions, &glyphs, &glyph_cache_entries, &glyph_cache_actions, &text_layout_plans, &text_layout_lines, &text_layout_cache_entries, &text_layout_cache_actions, &changes));

    try std.testing.expect(frame.requiresRender());
    try std.testing.expect(frame.pipeline_cache_plan.entryCount() >= 4);
    try std.testing.expectEqual(@as(usize, 2), frame.layer_plan.layerCount());
    try std.testing.expectEqual(@as(usize, 2), frame.layer_cache_plan.uploadCount());
    try std.testing.expectEqual(@as(usize, 2), frame.renderPass().layerActionCount());
    try std.testing.expect(frame.visual_effect_plan.effectCount() >= 4);
    try std.testing.expectEqual(@as(usize, 0), frame.changes.len);
    try std.testing.expect(frame.dirty_bounds != null);

    const packet = try frame.gpuPacket(&gpu_commands);
    try std.testing.expect(packet.requiresRender());
    try std.testing.expect(packet.fullyRepresentable());
    var found_transformed_live_button = false;
    for (packet.commands) |command| {
        if (command.id) |id| {
            if (id == live_fill_command_id) {
                try std.testing.expect(command.transform.ty < 0);
                found_transformed_live_button = true;
            }
        }
    }
    try std.testing.expect(found_transformed_live_button);
}

test "gpu dashboard scheduled animations render without display list rebuild" {
    // The runtime and the app are both multi-megabyte structs; keep them off
    // the test thread's stack.
    const harness = try std.testing.allocator.create(zero_native.TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{ .size = geometry.SizeF.init(window_width, window_height) });
    harness.null_platform.gpu_surfaces = true;

    const app = try std.testing.allocator.create(GpuDashboardApp);
    defer std.testing.allocator.destroy(app);
    app.* = GpuDashboardApp.init(std.heap.page_allocator);
    defer app.deinit();
    try harness.start(app.app());

    const start_ns: u64 = 1_000_000_000;
    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_frame = .{
        .label = "dashboard-canvas",
        .size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = start_ns,
        .nonblank = true,
    } });
    try std.testing.expect(app.canvas_installed);
    const initial_frame = try harness.runtime.gpuSurfaceFrame(1, "dashboard-canvas");
    try std.testing.expect(initial_frame.canvas_revision > 0);
    try std.testing.expectEqual(@as(usize, expected_dashboard_command_count), initial_frame.canvas_command_count);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_packet_present_count);

    const animation_frame = try harness.runtime.nextCanvasFrame(1, "dashboard-canvas", .{
        .frame_index = 2,
        .timestamp_ns = start_ns + 450_000_000,
        .surface_size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale = 2,
    }, app.frameStorage());
    const animation_view_frame = try harness.runtime.gpuSurfaceFrame(1, "dashboard-canvas");
    try std.testing.expectEqual(initial_frame.canvas_revision, animation_view_frame.canvas_revision);
    try std.testing.expectEqual(@as(usize, expected_dashboard_command_count), animation_frame.display_list.commandCount());
    try std.testing.expect(animation_frame.requiresRender());
    try std.testing.expect(!animation_frame.full_repaint);
    try std.testing.expectEqual(@as(usize, 0), animation_frame.changes.len);
    try std.testing.expect(animation_frame.dirty_bounds != null);
    try std.testing.expect(animation_frame.layer_plan.opacityLayerCount() > 0);
    try std.testing.expect(animation_frame.layer_plan.transformLayerCount() > 0);
    try std.testing.expect(animation_frame.layer_cache_plan.uploadCount() > 0);
    try std.testing.expectEqual(@as(usize, 0), animation_frame.pipeline_cache_plan.uploadCount());
    try std.testing.expect(animation_frame.text_layout_plan.planCount() >= 10);
    try std.testing.expectEqual(@as(usize, 0), animation_frame.text_layout_cache_plan.uploadCount());
    try std.testing.expect(animation_frame.text_layout_cache_plan.retainCount() >= 10);
    try std.testing.expectEqual(@as(usize, 0), animation_frame.text_layout_cache_plan.evictCount());

    var gpu_commands: [max_dashboard_commands]canvas.CanvasGpuCommand = undefined;
    const packet = try animation_frame.gpuPacket(&gpu_commands);
    try std.testing.expect(packet.requiresRender());
    try std.testing.expectEqual(@as(usize, 0), packet.unsupported_command_count);
    try std.testing.expect(packet.fullyRepresentable());
}

test "gpu dashboard app registers canvas display list on first gpu frame" {
    // The runtime and the app are both multi-megabyte structs; keep them off
    // the test thread's stack.
    const harness = try std.testing.allocator.create(zero_native.TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{ .size = geometry.SizeF.init(window_width, window_height) });
    harness.null_platform.gpu_surfaces = true;

    const app = try std.testing.allocator.create(GpuDashboardApp);
    defer std.testing.allocator.destroy(app);
    app.* = GpuDashboardApp.init(std.heap.page_allocator);
    defer app.deinit();
    try harness.start(app.app());

    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_frame = .{
        .label = "dashboard-canvas",
        .size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app.canvas_installed);
    try std.testing.expectEqualDeep(dashboardWidgetTokensForScale(2), try harness.runtime.canvasWidgetDesignTokens(1, "dashboard-canvas"));

    const tree = app.tree.?;
    const live_button = findWidgetKindText(tree.root, .button, "Live render").?;
    const auto_toggle = findWidgetByKind(tree.root, .toggle).?;
    const slider = findWidgetByKind(tree.root, .slider).?;
    const scroll = findWidgetByKind(tree.root, .scroll_view).?;
    const forecast_field = findWidgetByKind(tree.root, .text_field).?;
    const customers_item = findWidgetKindText(tree.root, .list_item, "Customers").?;
    const overview_item = findWidgetKindText(tree.root, .list_item, "Overview").?;

    var display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try std.testing.expectEqual(@as(usize, expected_dashboard_command_count), display_list.commandCount());
    try std.testing.expect(display_list.findCommandById(dashboard_background_command_id) != null);
    try std.testing.expect(display_list.findCommandById(dashboard_hero_command_id) != null);
    try std.testing.expect(display_list.findCommandById(widgetPartCommandId(scroll.id, widget_track_slot)) != null);
    try std.testing.expect(display_list.findCommandById(widgetPartCommandId(scroll.id, widget_thumb_slot)) != null);
    // The selected nav row paints a fill; unselected rows do not.
    try std.testing.expect(display_list.findCommandById(widgetPartCommandId(overview_item.id, widget_fill_slot)) != null);
    try std.testing.expect(display_list.findCommandById(widgetPartCommandId(customers_item.id, widget_fill_slot)) == null);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_present_count);
    try std.testing.expectEqualDeep(geometry.SizeF.init(canvas_width, canvas_height), harness.null_platform.gpu_surface_packet_present_surface_size);
    try std.testing.expectEqual(@as(f32, 2), harness.null_platform.gpu_surface_packet_present_scale_factor);
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_representable);
    try std.testing.expect(app.pixels == null);
    try std.testing.expect(app.scratch == null);
    const animations = try harness.runtime.canvasRenderAnimations(1, "dashboard-canvas");
    try std.testing.expectEqual(@as(usize, 2), animations.len);
    try std.testing.expectEqual(app.liveButtonFillCommandId(), animations[0].id);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), animations[0].start_ns);

    const widget_layout = try harness.runtime.canvasWidgetLayout(1, "dashboard-canvas");
    try std.testing.expectEqual(@as(usize, expected_dashboard_widget_node_count), widget_layout.nodeCount());
    try std.testing.expectEqualStrings("Dashboard metrics", findWidgetByLabel(tree.root, "Dashboard metrics").?.semantics.label);

    var snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expectEqual(@as(usize, expected_dashboard_snapshot_widget_count), snapshot.widgets.len);

    // Without a command string the segmented control exposes `select`; the
    // typed press handler rides the select intent in the pointer cascade.
    const toolbar_mode = dashboardSnapshotWidgetNamed(snapshot, "tab", "Dashboard mode").?;
    try std.testing.expect(toolbar_mode.actions.select);

    const toolbar_refresh = dashboardSnapshotWidgetNamed(snapshot, "button", "Refresh dashboard").?;
    try std.testing.expect(toolbar_refresh.actions.press);

    const initial_status = dashboardSnapshotWidgetNamed(snapshot, "text", "Dashboard display list presented on the GPU surface.").?;
    try std.testing.expectEqualStrings("text", initial_status.role);

    const live_render = dashboardSnapshotWidgetNamed(snapshot, "button", "Live render status").?;
    try std.testing.expect(live_render.actions.press);

    const progress = dashboardSnapshotWidgetNamed(snapshot, "progressbar", "Conversion progress").?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.68), progress.value.?, 0.001);

    const nav_list = dashboardSnapshotWidgetNamed(snapshot, "list", "Dashboard navigation").?;
    try std.testing.expectEqualStrings("list", nav_list.role);

    const overview = dashboardSnapshotWidgetNamed(snapshot, "listitem", "Overview").?;
    try std.testing.expect(overview.selected);
    try std.testing.expect(overview.list.present);
    try std.testing.expectEqual(@as(u32, 0), overview.list.item_index);
    try std.testing.expectEqual(@as(u32, 3), overview.list.item_count);

    const recent = dashboardSnapshotWidgetNamed(snapshot, "group", "Recent activity").?;
    try std.testing.expect(recent.scroll.present);
    try std.testing.expect(recent.scroll.content_extent > recent.scroll.viewport_extent);
    try std.testing.expect(recent.actions.increment);
    try std.testing.expect(recent.actions.decrement);

    const forecast = dashboardSnapshotWidgetNamed(snapshot, "textbox", "Forecast amount").?;
    try std.testing.expectEqualStrings("$13.4M", forecast.text_value);
    try std.testing.expect(forecast.actions.set_text);
    try std.testing.expect(forecast.actions.set_selection);

    const search = dashboardSnapshotWidgetNamed(snapshot, "textbox", "Segment search").?;
    try std.testing.expectEqualStrings("enterprise", search.text_value);

    const auto_refresh = dashboardSnapshotWidgetNamed(snapshot, "switch", "Auto refresh").?;
    try std.testing.expectEqual(@as(?f32, 1), auto_refresh.value);
    try std.testing.expect(auto_refresh.selected);
    try std.testing.expect(auto_refresh.actions.toggle);

    const confidence = dashboardSnapshotWidgetNamed(snapshot, "slider", "Confidence threshold").?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.62), confidence.value.?, 0.001);
    try std.testing.expect(confidence.actions.increment);
    try std.testing.expect(confidence.actions.decrement);

    try std.testing.expect(dashboardSnapshotWidgetNamed(snapshot, "dialog", "Revenue filter popover") != null);
    try std.testing.expect(dashboardSnapshotWidgetNamed(snapshot, "menu", "Filter options") != null);
    try std.testing.expect(dashboardSnapshotWidgetNamed(snapshot, "menuitem", "Last 30 days") != null);

    const deployment_grid = dashboardSnapshotWidgetNamed(snapshot, "grid", "Deployment latency").?;
    try std.testing.expectEqual(@as(?usize, 1), deployment_grid.grid_row_count);
    try std.testing.expectEqual(@as(?usize, 1), deployment_grid.grid_column_count);

    const deployment = dashboardSnapshotWidgetNamed(snapshot, "gridcell", "iad1 8.6ms P95").?;
    try std.testing.expectEqual(@as(?usize, 0), deployment.grid_row_index);
    try std.testing.expectEqual(@as(?usize, 0), deployment.grid_column_index);
    try std.testing.expect(deployment.actions.select);

    var command_buffer: [96]u8 = undefined;

    // Pressing the live button dispatches the typed message, restarts the
    // pulse, and repaints incrementally.
    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), try std.fmt.bufPrint(&command_buffer, "widget-action dashboard-canvas {d} press", .{live_button.id}));
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, canvas_height);
    try std.testing.expectEqual(@as(u32, 1), app.model.live_count);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expect(dashboardSnapshotWidgetById(snapshot, live_button.id).?.focused);
    try std.testing.expect(dashboardSnapshotWidgetNamed(snapshot, "text", "Live render pulse restarted. Count 1.") != null);

    // Keyboard focus traversal moves between the form fields and survives
    // the TEA rebuilds (structural ids keep the focus target stable).
    try harness.runtime.dispatchAutomationCommand(app.app(), try std.fmt.bufPrint(&command_buffer, "widget-action dashboard-canvas {d} focus", .{forecast_field.id}));
    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "dashboard-canvas",
        .kind = .key_down,
        .key = "tab",
    } });
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, canvas_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expect(!dashboardSnapshotWidgetById(snapshot, forecast_field.id).?.focused);
    try std.testing.expect(dashboardSnapshotWidgetNamed(snapshot, "textbox", "Segment search").?.focused);

    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_input = .{
        .window_id = 1,
        .label = "dashboard-canvas",
        .kind = .key_down,
        .key = "tab",
        .modifiers = .{ .shift = true },
    } });
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expect(dashboardSnapshotWidgetById(snapshot, forecast_field.id).?.focused);
    try std.testing.expect(!dashboardSnapshotWidgetNamed(snapshot, "textbox", "Segment search").?.focused);

    // Clicking a nav row routes pointer input through the typed handler and
    // moves the model selection.
    try harness.runtime.dispatchAutomationCommand(app.app(), try std.fmt.bufPrint(&command_buffer, "widget-click dashboard-canvas {d}", .{customers_item.id}));
    try std.testing.expectEqual(@as(u8, 1), app.model.nav_selection);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expect(!dashboardSnapshotWidgetNamed(snapshot, "listitem", "Overview").?.selected);
    try std.testing.expect(dashboardSnapshotWidgetNamed(snapshot, "listitem", "Customers").?.selected);
    try std.testing.expect(dashboardSnapshotWidgetNamed(snapshot, "text", "Selected Customers.") != null);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try std.testing.expect(display_list.findCommandById(widgetPartCommandId(overview_item.id, widget_fill_slot)) == null);
    try std.testing.expect(display_list.findCommandById(widgetPartCommandId(customers_item.id, widget_fill_slot)) != null);

    // Runtime-owned text editing state survives model-driven rebuilds.
    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), try std.fmt.bufPrint(&command_buffer, "widget-action dashboard-canvas {d} set-text $14.1M", .{forecast_field.id}));
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, canvas_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const updated_forecast = dashboardSnapshotWidgetNamed(snapshot, "textbox", "Forecast amount").?;
    try std.testing.expectEqualStrings("$14.1M", updated_forecast.text_value);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 6, .end = 6 }, updated_forecast.text_selection.?);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try expectDashboardTextCommand(display_list, widgetPartCommandId(forecast_field.id, widget_text_slot), "$14.1M");

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), try std.fmt.bufPrint(&command_buffer, "widget-action dashboard-canvas {d} set-composition est", .{forecast_field.id}));
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, canvas_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const composing_forecast = dashboardSnapshotWidgetNamed(snapshot, "textbox", "Forecast amount").?;
    try std.testing.expectEqualStrings("$14.1Mest", composing_forecast.text_value);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 6, .end = 9 }, composing_forecast.text_composition.?);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try std.testing.expect(display_list.findCommandById(widgetPartCommandId(forecast_field.id, widget_composition_slot)) != null);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), try std.fmt.bufPrint(&command_buffer, "widget-action dashboard-canvas {d} cancel-composition", .{forecast_field.id}));
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, canvas_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const canceled_forecast = dashboardSnapshotWidgetNamed(snapshot, "textbox", "Forecast amount").?;
    try std.testing.expectEqualStrings("$14.1M", canceled_forecast.text_value);
    try std.testing.expect(canceled_forecast.text_composition == null);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try std.testing.expect(display_list.findCommandById(widgetPartCommandId(forecast_field.id, widget_composition_slot)) == null);

    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), try std.fmt.bufPrint(&command_buffer, "widget-action dashboard-canvas {d} set-composition !", .{forecast_field.id}));
    try harness.runtime.dispatchAutomationCommand(app.app(), try std.fmt.bufPrint(&command_buffer, "widget-action dashboard-canvas {d} commit-composition", .{forecast_field.id}));
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const committed_forecast = dashboardSnapshotWidgetNamed(snapshot, "textbox", "Forecast amount").?;
    try std.testing.expectEqualStrings("$14.1M!", committed_forecast.text_value);
    try std.testing.expectEqualDeep(zero_native.automation.snapshot.TextRange{ .start = 7, .end = 7 }, committed_forecast.text_selection.?);
    try std.testing.expect(committed_forecast.text_composition == null);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try expectDashboardTextCommand(display_list, widgetPartCommandId(forecast_field.id, widget_text_slot), "$14.1M!");

    // Toggling auto refresh routes through the typed handler, mutates the
    // model, and updates the human-readable status.
    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), try std.fmt.bufPrint(&command_buffer, "widget-action dashboard-canvas {d} toggle", .{auto_toggle.id}));
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, canvas_height);
    try std.testing.expect(!app.model.auto_refresh);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const disabled_auto_refresh = dashboardSnapshotWidgetNamed(snapshot, "switch", "Auto refresh").?;
    try std.testing.expectEqual(@as(?f32, 0), disabled_auto_refresh.value);
    try std.testing.expect(!disabled_auto_refresh.selected);
    try std.testing.expect(dashboardSnapshotWidgetNamed(snapshot, "text", "Auto refresh off.") != null);

    // Slider steps reach the model through the read-back in dispatch.
    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), try std.fmt.bufPrint(&command_buffer, "widget-action dashboard-canvas {d} increment", .{slider.id}));
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, canvas_height);
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const updated_confidence = dashboardSnapshotWidgetNamed(snapshot, "slider", "Confidence threshold").?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.67), updated_confidence.value.?, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.67), app.model.confidence, 0.001);
    try std.testing.expect(dashboardSnapshotWidgetNamed(snapshot, "text", "Confidence threshold 67%.") != null);

    // Scroll offsets are runtime-owned and survive model-driven rebuilds.
    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), try std.fmt.bufPrint(&command_buffer, "widget-action dashboard-canvas {d} increment", .{scroll.id}));
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, canvas_height);
    var scrolled_layout = try harness.runtime.canvasWidgetLayout(1, "dashboard-canvas");
    const scrolled_offset = scrolled_layout.findById(scroll.id).?.widget.value;
    try std.testing.expect(scrolled_offset > 18);
    // A model-driven rebuild must not reset the runtime scroll offset.
    try harness.runtime.dispatchAutomationCommand(app.app(), try std.fmt.bufPrint(&command_buffer, "widget-action dashboard-canvas {d} toggle", .{auto_toggle.id}));
    try std.testing.expect(app.model.auto_refresh);
    scrolled_layout = try harness.runtime.canvasWidgetLayout(1, "dashboard-canvas");
    try std.testing.expectEqual(scrolled_offset, scrolled_layout.findById(scroll.id).?.widget.value);
    resetDashboardDirty(&harness.runtime);
    try harness.runtime.dispatchAutomationCommand(app.app(), try std.fmt.bufPrint(&command_buffer, "widget-action dashboard-canvas {d} decrement", .{scroll.id}));
    try expectCompactDashboardDirty(&harness.runtime, canvas_width, canvas_height);
    scrolled_layout = try harness.runtime.canvasWidgetLayout(1, "dashboard-canvas");
    try std.testing.expect(scrolled_layout.findById(scroll.id).?.widget.value < scrolled_offset);

    // The next frame reports plan diagnostics into the status line and the
    // canvas settles back to an idle profile.
    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_frame = .{
        .label = "dashboard-canvas",
        .size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale_factor = 2,
        .frame_index = 2,
        .timestamp_ns = 1_016_000_000,
        .nonblank = true,
    } });
    snapshot = harness.runtime.automationSnapshot("Dashboard");
    const status_widget = dashboardSnapshotWidgetNameContains(snapshot, "text", "Canvas frame:").?;
    try std.testing.expect(std.mem.indexOf(u8, status_widget.name, "risk") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_widget.name, "work units") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_widget.name, "dirty") != null);

    const frame = try harness.runtime.gpuSurfaceFrame(1, "dashboard-canvas");
    try std.testing.expect(frame.canvas_revision > 1);
    try std.testing.expectEqual(@as(usize, expected_dashboard_interaction_command_count), frame.canvas_command_count);
    try std.testing.expect(!frame.canvas_frame_requires_render);
    try std.testing.expect(!frame.canvas_frame_full_repaint);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_change_count);
    try std.testing.expect(frame.canvas_frame_dirty_bounds == null);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_batch_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_encoder_command_count);
    try std.testing.expectEqual(frame.canvas_frame_batch_count, frame.canvas_frame_encoder_draw_batch_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_pipeline_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_pipeline_retain_count);
    try std.testing.expectEqual(@as(usize, 0), frame.canvas_frame_profile_work_units);
    try std.testing.expectEqual(zero_native.platform.CanvasFrameProfileRisk.idle, frame.canvas_frame_profile_risk);
}

test "gpu dashboard shell commands map to typed messages" {
    // The runtime and the app are both multi-megabyte structs; keep them off
    // the test thread's stack.
    const harness = try std.testing.allocator.create(zero_native.TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{ .size = geometry.SizeF.init(window_width, window_height) });
    harness.null_platform.gpu_surfaces = true;

    const app = try std.testing.allocator.create(GpuDashboardApp);
    defer std.testing.allocator.destroy(app);
    app.* = GpuDashboardApp.init(std.heap.page_allocator);
    defer app.deinit();
    try harness.start(app.app());

    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_frame = .{
        .label = "dashboard-canvas",
        .size = default_canvas_size,
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app.canvas_installed);

    try harness.runtime.dispatchCommand(app.app(), .{ .name = refresh_command, .window_id = 1, .source = .menu });
    try std.testing.expectEqual(@as(u32, 1), app.model.refresh_count);
    try std.testing.expectEqualStrings("Dashboard canvas refreshed. Count 1.", app.model.status());

    try harness.runtime.dispatchCommand(app.app(), .{ .name = mode_command, .window_id = 1, .source = .menu });
    try std.testing.expectEqual(@as(u32, 1), app.model.mode_count);
    try std.testing.expectEqualStrings("Dashboard mode changed. Count 1.", app.model.status());

    const snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expect(dashboardSnapshotWidgetNamed(snapshot, "text", "Dashboard mode changed. Count 1.") != null);
}

test "gpu dashboard follows system appearance tokens" {
    // The runtime and the app are both multi-megabyte structs; keep them off
    // the test thread's stack.
    const harness = try std.testing.allocator.create(zero_native.TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{ .size = geometry.SizeF.init(window_width, window_height) });
    harness.null_platform.gpu_surfaces = true;

    const app = try std.testing.allocator.create(GpuDashboardApp);
    defer std.testing.allocator.destroy(app);
    app.* = GpuDashboardApp.init(std.heap.page_allocator);
    defer app.deinit();
    const app_handle = app.app();
    try harness.start(app_handle);

    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .gpu_surface_frame = .{
        .label = "dashboard-canvas",
        .size = default_canvas_size,
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000_000,
        .nonblank = true,
    } });
    try std.testing.expectEqualDeep(dashboardWidgetTokensForSchemeAndScale(.light, 2), try harness.runtime.canvasWidgetDesignTokens(1, "dashboard-canvas"));
    var display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try expectDashboardFillRectColor(display_list, dashboard_background_command_id, dashboardWidgetTokensForSchemeAndScale(.light, 2).colors.background);

    const packet_count_before_dark = harness.null_platform.gpu_surface_packet_present_count;
    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .appearance_changed = .{ .color_scheme = .dark, .reduce_motion = true, .high_contrast = true } });
    try std.testing.expectEqual(zero_native.ColorScheme.dark, app.color_scheme);
    try std.testing.expect(app.reduce_motion);
    try std.testing.expect(app.high_contrast);
    try std.testing.expectEqualDeep(dashboardWidgetTokensForSchemeScaleMotionAndContrast(.dark, 2, true, true), try harness.runtime.canvasWidgetDesignTokens(1, "dashboard-canvas"));
    try std.testing.expect(harness.null_platform.gpu_surface_packet_present_count > packet_count_before_dark);
    display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try expectDashboardFillRectColor(display_list, dashboard_background_command_id, dashboardWidgetTokensForSchemeScaleMotionAndContrast(.dark, 2, true, true).colors.background);
    const snapshot = harness.runtime.automationSnapshot("Dashboard");
    try std.testing.expect(dashboardSnapshotWidgetNamed(snapshot, "text", "Dashboard theme: dark from system appearance.") != null);
}

test "gpu dashboard app rebuilds retained scene for resized gpu surfaces" {
    // The runtime and the app are both multi-megabyte structs; keep them off
    // the test thread's stack.
    const harness = try std.testing.allocator.create(zero_native.TestHarness());
    defer std.testing.allocator.destroy(harness);
    harness.init(.{ .size = geometry.SizeF.init(window_width, window_height) });
    harness.null_platform.gpu_surfaces = true;

    const app = try std.testing.allocator.create(GpuDashboardApp);
    defer std.testing.allocator.destroy(app);
    app.* = GpuDashboardApp.init(std.heap.page_allocator);
    defer app.deinit();
    const app_handle = app.app();
    try harness.start(app_handle);

    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .gpu_surface_frame = .{
        .label = "dashboard-canvas",
        .size = default_canvas_size,
        .scale_factor = 2,
        .frame_index = 1,
        .timestamp_ns = 1_000_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app.canvas_installed);
    try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_packet_present_count);

    const resized_size = geometry.SizeF.init(canvas_width + 240, canvas_height + 160);
    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .gpu_surface_resized = .{
        .window_id = 1,
        .label = "dashboard-canvas",
        .frame = geometry.RectF.init(0, 0, resized_size.width, resized_size.height),
        .scale_factor = 2,
    } });
    const packet_count_before_resize_frame = harness.null_platform.gpu_surface_packet_present_count;
    try harness.runtime.dispatchPlatformEvent(app_handle, .{ .gpu_surface_frame = .{
        .label = "dashboard-canvas",
        .size = resized_size,
        .scale_factor = 2,
        .frame_index = 2,
        .timestamp_ns = 1_016_000_000,
        .nonblank = true,
    } });

    try std.testing.expectEqual(packet_count_before_resize_frame + 1, harness.null_platform.gpu_surface_packet_present_count);
    try std.testing.expectEqualDeep(resized_size, harness.null_platform.gpu_surface_packet_present_surface_size);
    const resized_frame = try harness.runtime.gpuSurfaceFrame(1, "dashboard-canvas");
    try std.testing.expect(!resized_frame.canvas_frame_requires_render);
    try std.testing.expect(!resized_frame.canvas_frame_full_repaint);
    try std.testing.expectEqualDeep(resized_size, resized_frame.size);

    const display_list = try harness.runtime.canvasDisplayList(1, "dashboard-canvas");
    try expectDashboardFillRectFrame(display_list, dashboard_background_command_id, dashboardBackdropRect(resized_size));
    try expectDashboardRoundedRectFrame(display_list, dashboard_hero_command_id, dashboardHeroRect(resized_size));

    // The flex tree relayouts to the new surface: the side column tracks the
    // right edge and the status line tracks the bottom edge.
    const tree = app.tree.?;
    const live_button = findWidgetKindText(tree.root, .button, "Live render").?;
    const status_text = findWidgetByLabel(tree.root, app.model.status()).?;
    const widget_layout = try harness.runtime.canvasWidgetLayout(1, "dashboard-canvas");
    const live_frame = try dashboardLayoutFrame(widget_layout, live_button.id);
    try std.testing.expect(live_frame.maxX() > canvas_width);
    try std.testing.expect(live_frame.maxX() <= resized_size.width);
    const status_frame = try dashboardLayoutFrame(widget_layout, status_text.id);
    const content_end = dashboardContentYForSize(resized_size) + dashboardContentHeightForSize(resized_size);
    try std.testing.expect(status_frame.y >= content_end);
}

test "gpu dashboard frame event adapter preserves renderer diagnostics" {
    const frame = zero_native.platform.GpuFrame{
        .window_id = 7,
        .label = "dashboard-canvas",
        .size = geometry.SizeF.init(canvas_width, canvas_height),
        .scale_factor = 2,
        .frame_index = 42,
        .timestamp_ns = 1234,
        .first_frame_latency_ns = 54,
        .first_frame_latency_budget_ns = 150,
        .first_frame_latency_budget_exceeded_count = 0,
        .first_frame_latency_budget_ok = true,
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
        .canvas_frame_gpu_packet_command_count = 62,
        .canvas_frame_gpu_packet_cache_action_count = 14,
        .canvas_frame_gpu_packet_cached_resource_command_count = 11,
        .canvas_frame_gpu_packet_unsupported_command_count = 0,
        .canvas_frame_gpu_packet_representable = true,
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
    try std.testing.expectEqual(frame.first_frame_latency_ns, event_value.first_frame_latency_ns);
    try std.testing.expectEqual(frame.first_frame_latency_budget_ns, event_value.first_frame_latency_budget_ns);
    try std.testing.expectEqual(frame.first_frame_latency_budget_exceeded_count, event_value.first_frame_latency_budget_exceeded_count);
    try std.testing.expectEqual(frame.first_frame_latency_budget_ok, event_value.first_frame_latency_budget_ok);
    try std.testing.expectEqual(frame.canvas_frame_path_geometry_count, event_value.canvas_frame_path_geometry_count);
    try std.testing.expectEqual(frame.canvas_frame_path_geometry_vertex_count, event_value.canvas_frame_path_geometry_vertex_count);
    try std.testing.expectEqual(frame.canvas_frame_image_count, event_value.canvas_frame_image_count);
    try std.testing.expectEqual(frame.canvas_frame_layer_transform_count, event_value.canvas_frame_layer_transform_count);
    try std.testing.expectEqual(frame.canvas_frame_visual_effect_shadow_count, event_value.canvas_frame_visual_effect_shadow_count);
    try std.testing.expectEqual(frame.canvas_frame_text_layout_retain_count, event_value.canvas_frame_text_layout_retain_count);
    try std.testing.expectEqual(frame.canvas_frame_gpu_packet_command_count, event_value.canvas_frame_gpu_packet_command_count);
    try std.testing.expectEqual(frame.canvas_frame_gpu_packet_cache_action_count, event_value.canvas_frame_gpu_packet_cache_action_count);
    try std.testing.expectEqual(frame.canvas_frame_gpu_packet_cached_resource_command_count, event_value.canvas_frame_gpu_packet_cached_resource_command_count);
    try std.testing.expectEqual(frame.canvas_frame_gpu_packet_unsupported_command_count, event_value.canvas_frame_gpu_packet_unsupported_command_count);
    try std.testing.expectEqual(frame.canvas_frame_gpu_packet_representable, event_value.canvas_frame_gpu_packet_representable);
    try std.testing.expectEqualDeep(frame.canvas_frame_dirty_bounds.?, event_value.canvas_frame_dirty_bounds.?);
    try std.testing.expectEqual(frame.canvas_frame_profile_work_units, event_value.canvas_frame_profile_work_units);
    try std.testing.expectEqual(frame.canvas_frame_profile_risk, event_value.canvas_frame_profile_risk);
    try std.testing.expectEqual(frame.canvas_frame_profile_surface_area, event_value.canvas_frame_profile_surface_area);
    try std.testing.expectEqual(frame.canvas_frame_profile_dirty_area, event_value.canvas_frame_profile_dirty_area);
    try std.testing.expectEqual(frame.canvas_frame_profile_dirty_ratio, event_value.canvas_frame_profile_dirty_ratio);
    try std.testing.expectEqual(frame.widget_semantics_count, event_value.widget_semantics_count);

    var status_buffer: [128]u8 = undefined;
    const status = try dashboardFrameStatus(&status_buffer, event_value);
    try std.testing.expectEqualStrings("Canvas frame: moderate risk, 88 work units, 62 commands, 12 batches, packet ok, dirty 0%.", status);
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
