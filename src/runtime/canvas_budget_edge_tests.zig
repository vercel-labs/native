//! Budget-edge matrix: drive a real `UiApp` to every `canvas_limits`
//! boundary reachable from app code and pin the three-sided contract at
//! each one —
//!   1. AT the budget the build applies and renders (no dispatch error),
//!   2. one PAST the budget the rebuild fails loudly with the teaching
//!      error (recorded in the dispatch-error ring under `.degrade`, the
//!      production policy), and
//!   3. the app SURVIVES: the next dispatch with a sane model rebuilds
//!      and applies cleanly (no wedged view, no stale-forever frame).
//!
//! Boundaries covered: widget layout nodes, widget text bytes, inline
//! spans, declared context-menu items, anchored surfaces, chart series,
//! and chart points (reachable through `.band` series: values + low both
//! charge the pool, so 32 maximal bands fill it exactly while staying
//! inside the 64-series budget). Retained packet commands are documented
//! structurally unreachable (the command budget fails first) and the
//! text-layout budgets have their own suite
//! (canvas_frame_text_layout_budget_tests.zig).

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_model = @import("ui_app.zig");
const canvas_limits = @import("canvas_limits.zig");

const canvas_label = "stress-canvas";

const StressMode = enum {
    idle,
    nodes,
    text_bytes,
    frame_text_bytes,
    spans,
    context_menus,
    anchored,
    chart_series,
    chart_points,
};

const StressConfig = struct {
    mode: StressMode = .idle,
    count: usize = 0,
};

const StressModel = struct {
    config: StressConfig = .{},

    fn indices(model: *const StressModel, arena: std.mem.Allocator) []const usize {
        const out = arena.alloc(usize, model.config.count) catch return &.{};
        for (out, 0..) |*slot, index| slot.* = index;
        return out;
    }
};

const StressMsg = union(enum) {
    set: StressConfig,
};

const StressApp = ui_app_model.UiApp(StressModel, StressMsg);

fn stressUpdate(model: *StressModel, msg: StressMsg) void {
    switch (msg) {
        .set => |config| model.config = config,
    }
}

// Static payload storage: tests are single-threaded and the view only
// reads these. Size it from the live retained-text edge so raising that
// budget cannot make this test fixture fail before the runtime does.
var text_payload: [canvas_limits.max_canvas_widget_text_bytes_per_view]u8 = undefined;
var chart_values: [256]f32 = undefined;
var chart_low: [256]f32 = undefined;

fn stressKey(index: *const usize) canvas.UiKey {
    return canvas.uiKey(@as(u64, index.*));
}

fn nodeRow(ui: *StressApp.Ui, index: *const usize) StressApp.Ui.Node {
    _ = index;
    return ui.text(.{}, "r");
}

fn spanParagraph(ui: *StressApp.Ui, span_count: usize) StressApp.Ui.Node {
    const spans = ui.arena.alloc(canvas.TextSpan, span_count) catch {
        ui.failed = true;
        return ui.text(.{}, "");
    };
    for (spans) |*span| span.* = .{ .text = "s" };
    return ui.paragraph(.{}, spans);
}

fn menuWidget(ui: *StressApp.Ui, item_count: usize) StressApp.Ui.Node {
    const items = ui.arena.alloc(StressApp.Ui.ContextMenuItem, item_count) catch {
        ui.failed = true;
        return ui.text(.{}, "");
    };
    for (items) |*item| item.* = .{ .label = "m" };
    return ui.el(.list_item, .{ .context_menu = items }, .{ui.text(.{}, "w")});
}

fn anchoredRow(ui: *StressApp.Ui, index: *const usize) StressApp.Ui.Node {
    _ = index;
    return ui.el(.stack, .{ .anchor = .below }, .{ui.text(.{}, "a")});
}

fn stressView(ui: *StressApp.Ui, model: *const StressModel) StressApp.Ui.Node {
    const count = model.config.count;
    switch (model.config.mode) {
        .idle => return ui.column(.{}, .{ui.text(.{}, "idle")}),
        // count = total layout nodes desired (root column included).
        .nodes => return ui.column(.{ .gap = 1 }, ui.each(model.indices(ui.arena), stressKey, nodeRow)),
        // count = bytes of retained widget text, carried as a span LINK
        // payload: links charge the retained pool but are never drawn,
        // so the WIDGET text budget is reachable without the FRAME text
        // budget (half its size) failing first.
        .text_bytes => {
            const spans = ui.arena.alloc(canvas.TextSpan, 1) catch {
                ui.failed = true;
                return ui.column(.{}, .{});
            };
            spans[0] = .{ .text = "t", .link = text_payload[0..count] };
            return ui.column(.{}, .{ui.paragraph(.{}, spans)});
        },
        // count = bytes of VISIBLE text on one widget: the display-list
        // frame text budget is the edge that fires here.
        .frame_text_bytes => return ui.column(.{}, .{ui.text(.{}, text_payload[0..count])}),
        // count = total inline spans, packed 32 per paragraph.
        .spans => {
            const per = canvas.max_text_spans_per_paragraph;
            const paragraphs = (count + per - 1) / per;
            const nodes = ui.arena.alloc(StressApp.Ui.Node, paragraphs) catch {
                ui.failed = true;
                return ui.column(.{}, .{});
            };
            var remaining = count;
            for (nodes) |*node| {
                const take = @min(per, remaining);
                node.* = spanParagraph(ui, take);
                remaining -= take;
            }
            return ui.column(.{ .gap = 1 }, nodes);
        },
        // count = total declared context-menu items, packed 32 per widget.
        .context_menus => {
            const per = 32;
            const widgets = (count + per - 1) / per;
            const nodes = ui.arena.alloc(StressApp.Ui.Node, widgets) catch {
                ui.failed = true;
                return ui.column(.{}, .{});
            };
            var remaining = count;
            for (nodes) |*node| {
                const take = @min(per, remaining);
                node.* = menuWidget(ui, take);
                remaining -= take;
            }
            return ui.column(.{ .gap = 1 }, nodes);
        },
        // count = anchored surfaces.
        .anchored => return ui.column(.{ .gap = 1 }, ui.each(model.indices(ui.arena), stressKey, anchoredRow)),
        // count = chart series (one point each).
        .chart_series => {
            const series = ui.arena.alloc(canvas.ChartSeries, count) catch {
                ui.failed = true;
                return ui.column(.{}, .{});
            };
            for (series) |*entry| entry.* = .{ .kind = .line, .values = chart_values[0..1] };
            return ui.column(.{}, .{ui.chart(.{ .height = 64 }, series)});
        },
        // count = retained chart points, packed as maximal band series
        // (256 values + 256 low = 512 points each) plus one small line
        // series for any remainder.
        .chart_points => {
            const per = canvas.max_chart_points_per_series * 2;
            const bands = count / per;
            const remainder = count % per;
            const total = bands + @intFromBool(remainder > 0);
            const series = ui.arena.alloc(canvas.ChartSeries, total) catch {
                ui.failed = true;
                return ui.column(.{}, .{});
            };
            for (series[0..bands]) |*entry| entry.* = .{
                .kind = .band,
                .values = chart_values[0..],
                .low = chart_low[0..],
            };
            if (remainder > 0) series[bands] = .{
                .kind = .line,
                .values = chart_values[0..@min(remainder, chart_values.len)],
            };
            return ui.column(.{}, .{ui.chart(.{ .height = 64 }, series)});
        },
    }
}

const stress_views = [_]app_manifest.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const stress_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Budget edge",
    .width = 800,
    .height = 3200,
    .views = &stress_views,
}};
const stress_scene: app_manifest.ShellConfig = .{ .windows = &stress_windows };

const Harness = struct {
    harness: *core.TestHarness(),
    app_state: *StressApp,

    fn create() !Harness {
        @memset(text_payload[0..], 'x');
        for (&chart_values, 0..) |*value, index| value.* = @floatFromInt(index % 7);
        for (&chart_low, 0..) |*value, index| value.* = @as(f32, @floatFromInt(index % 5)) - 4;

        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(800, 3200) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;

        const app_state = try std.testing.allocator.create(StressApp);
        errdefer std.testing.allocator.destroy(app_state);
        app_state.* = StressApp.init(std.heap.page_allocator, .{}, .{
            .name = "budget-edge",
            .scene = stress_scene,
            .canvas_label = canvas_label,
            .update = stressUpdate,
            .view = stressView,
        });
        const app = app_state.app();
        try harness.start(app);
        try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
            .label = canvas_label,
            .size = geometry.SizeF.init(800, 3200),
            .scale_factor = 1,
            .frame_index = 1,
            .timestamp_ns = 1_000_000,
            .nonblank = true,
        } });
        // Production policy: budget overflows record and degrade, never
        // crash the loop — the survival half of the contract.
        harness.runtime.dispatch_error_policy = .degrade;
        return .{ .harness = harness, .app_state = app_state };
    }

    fn destroy(self: Harness) void {
        self.app_state.deinit();
        std.testing.allocator.destroy(self.app_state);
        self.harness.destroy(std.testing.allocator);
    }

    fn set(self: Harness, config: StressConfig) !void {
        try self.app_state.dispatch(&self.harness.runtime, 1, .{ .set = config });
    }

    fn layoutNodeCount(self: Harness) !usize {
        const layout = try self.harness.runtime.canvasWidgetLayout(1, canvas_label);
        return layout.nodes.len;
    }

    /// One budget edge, all three sides: at-budget applies, one-past
    /// fails loudly with the NAMED teaching error, and a follow-up sane
    /// rebuild applies (survival — the failed rebuild never half-applies
    /// or wedges the view). Errors surface directly here because
    /// `UiApp.dispatch` propagates; the production degrade-and-record
    /// path (dispatch-error ring + snapshot `error event=` lines) for a
    /// budget overflow is pinned by ui_app_tests' effects-wake capacity
    /// test.
    fn expectEdge(self: Harness, mode: StressMode, at_budget: usize, expected_error: anyerror) !void {
        try self.set(.{ .mode = mode, .count = at_budget });
        const at_nodes = try self.layoutNodeCount();
        try std.testing.expect(at_nodes > 0);

        try std.testing.expectError(expected_error, self.set(.{ .mode = mode, .count = at_budget + 1 }));
        // The failed rebuild never half-applies: the retained tree is
        // still the at-budget one.
        try std.testing.expectEqual(at_nodes, try self.layoutNodeCount());

        // Survival: the next sane dispatch rebuilds and applies.
        try self.set(.{ .mode = .idle, .count = 0 });
        try std.testing.expectEqual(@as(usize, 2), try self.layoutNodeCount());
    }
};

test "budget edge: widget layout nodes" {
    const saved_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_log_level;
    const h = try Harness.create();
    defer h.destroy();

    // Root column + children: at the cap the tree is exactly
    // max_canvas_widget_nodes_per_view nodes.
    const at = canvas_limits.max_canvas_widget_nodes_per_view - 1;
    try h.set(.{ .mode = .nodes, .count = at });
    try std.testing.expectEqual(canvas_limits.max_canvas_widget_nodes_per_view, try h.layoutNodeCount());
    try h.expectEdge(.nodes, at, error.WidgetLayoutListFull);
}

test "budget edge: widget text bytes (retained, via span links)" {
    const saved_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_log_level;
    const h = try Harness.create();
    defer h.destroy();

    // One span-link payload carrying every retained byte the view may
    // hold, minus the view's fixed overhead (span text + labels riding
    // the same pool). Measured empirically at a small size so the edge
    // stays exact if fixed labels change.
    try h.set(.{ .mode = .text_bytes, .count = 16 });
    const used = h.harness.runtime.views[try viewIndex(h)].widget_text_len;
    const overhead = used - 16;
    const at = canvas_limits.max_canvas_widget_text_bytes_per_view - overhead;
    try h.expectEdge(.text_bytes, at, error.WidgetTextTooLarge);
}

test "budget edge: frame text bytes (visible text hits the display-list budget first)" {
    const saved_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_log_level;
    const h = try Harness.create();
    defer h.destroy();

    // Visible text is charged against the per-frame display-list text
    // budget (HALF the retained widget budget), so that is the edge an
    // app showing one giant string actually hits.
    try h.set(.{ .mode = .frame_text_bytes, .count = 16 });
    const used = h.harness.runtime.views[try viewIndex(h)].canvas_text_len;
    const overhead = used - 16;
    const at = canvas_limits.max_canvas_text_bytes_per_view - overhead;
    try h.expectEdge(.frame_text_bytes, at, error.CanvasTextTooLarge);
}

fn viewIndex(h: Harness) !usize {
    // The stress scene has exactly one gpu_surface view.
    for (h.harness.runtime.views[0..h.harness.runtime.view_count], 0..) |view, index| {
        if (std.mem.eql(u8, view.label, canvas_label)) return index;
    }
    return error.ViewNotFound;
}

test "budget edge: inline spans" {
    const saved_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_log_level;
    const h = try Harness.create();
    defer h.destroy();
    try h.expectEdge(.spans, canvas_limits.max_canvas_widget_spans_per_view, error.WidgetSpanLimitReached);
}

test "budget edge: declared context-menu items" {
    const saved_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_log_level;
    const h = try Harness.create();
    defer h.destroy();
    try h.expectEdge(.context_menus, canvas_limits.max_canvas_widget_context_menu_items_per_view, error.WidgetContextMenuLimitReached);
}

test "budget edge: anchored surfaces" {
    const saved_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_log_level;
    const h = try Harness.create();
    defer h.destroy();
    try h.expectEdge(.anchored, canvas_limits.max_canvas_widget_anchored_per_view, error.WidgetAnchoredSurfaceLimitReached);
}

test "budget edge: chart series" {
    const saved_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_log_level;
    const h = try Harness.create();
    defer h.destroy();
    try h.expectEdge(.chart_series, canvas_limits.max_canvas_widget_chart_series_per_view, error.WidgetChartSeriesLimitReached);
}

test "budget edge: chart points through band series" {
    const saved_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_log_level;
    const h = try Harness.create();
    defer h.destroy();

    const points_budget = canvas_limits.max_canvas_widget_chart_points_per_view;

    // The retained points pool cannot be fully DRAWN in one frame: a
    // visible band charges ~one path element per point, so the per-view
    // path-element budget bounds rendered chart complexity first. AT the
    // pool budget (32 maximal bands = 16384 points) the retained tree
    // applies, then emit fails loudly and the frame stays on the
    // previous coherent display list — no tear, no silence.
    try std.testing.expectError(
        error.ChartPathElementListFull,
        h.set(.{ .mode = .chart_points, .count = points_budget }),
    );
    const applied_nodes = try h.layoutNodeCount();
    try std.testing.expect(applied_nodes > 0);

    // One PAST the pool, the copy pre-validation fires first — atomic,
    // named, the just-applied tree untouched (the +1 remainder series
    // stays far inside the series budget, so the points pool is the
    // budget that trips).
    try std.testing.expectError(
        error.WidgetChartPointsLimitReached,
        h.set(.{ .mode = .chart_points, .count = points_budget + 1 }),
    );
    try std.testing.expectEqual(applied_nodes, try h.layoutNodeCount());

    // Survival either way.
    try h.set(.{ .mode = .idle, .count = 0 });
    try std.testing.expectEqual(@as(usize, 2), try h.layoutNodeCount());
}
