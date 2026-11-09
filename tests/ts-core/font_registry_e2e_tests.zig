const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("surface_fixture_core");
const exact = @import("surface_layout_e2e_tests.zig").expectComplete;
const Harness = sdk.TestHarness();
const policy = sdk.runtime.testing.font_registry_policy;
const font = sdk.canvas.font_ttf.geist_mono_bytes;
var modes: [6]usize = @splat(0);
fn observed(request: []const u8, output: []u8) usize {
    if (request[0] == 83) modes[request[2]] += 1;
    return core.nativeWindowPolicy(request, output);
}
const Pair = struct {
    left: *Harness,
    right: *Harness,
    fn create() !Pair {
        const a = try Harness.create(std.testing.allocator, .{});
        errdefer a.destroy(std.testing.allocator);
        const b = try Harness.create(std.testing.allocator, .{});
        errdefer b.destroy(std.testing.allocator);
        for ([_]*Harness{ a, b }, 0..) |h, i| {
            h.null_platform.gpu_surfaces = true;
            try h.start(.{ .context = h, .name = "font-registry", .source = sdk.platform.WebViewSource.html("") });
            h.runtime.started_timestamp_ns = 0;
            if (i == 1) h.runtime.font_registry_policy = observed;
            _ = try h.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = .init(0, 0, 200, 100) });
        }
        return .{ .left = a, .right = b };
    }
    fn destroy(self: Pair) void {
        self.left.destroy(std.testing.allocator);
        self.right.destroy(std.testing.allocator);
    }
    fn same(self: Pair) !void {
        @setEvalBranchQuota(10000);
        var left = self.left.runtime.automationSnapshot("font-registry");
        var right = self.right.runtime.automationSnapshot("font-registry");
        const left_errors = try std.testing.allocator.dupe(sdk.automation.snapshot.DispatchError, left.errors);
        defer std.testing.allocator.free(left_errors);
        const right_errors = try std.testing.allocator.dupe(sdk.automation.snapshot.DispatchError, right.errors);
        defer std.testing.allocator.free(right_errors);
        // Compare every populated error byte; unused storage is undefined and
        // timestamps are independently sampled OS wall clocks.
        for ([_][]sdk.automation.snapshot.DispatchError{ left_errors, right_errors }) |errors| for (errors) |*record| {
            try std.testing.expect(record.timestamp_ns > 0);
            record.timestamp_ns = 0;
            @memset(record.event_storage[record.event_len..], 0);
            @memset(record.detail_storage[record.detail_len..], 0);
        };
        left.errors = left_errors;
        right.errors = right_errors;
        try exact(left, right);
        try exact(self.left.runtime.canvas_font_count, self.right.runtime.canvas_font_count);
        try exact(self.left.runtime.invalidated, self.right.runtime.invalidated);
        for (self.left.runtime.canvas_font_entries, self.right.runtime.canvas_font_entries) |a, b| {
            try exact(a.id, b.id);
            try std.testing.expectEqualSlices(u8, a.bytes, b.bytes);
            try exact(a.host_registration_token, b.host_registration_token);
            try exact(a.host_unregister_fn != null, b.host_unregister_fn != null);
        }
        for (self.left.runtime.registeredCanvasFonts(), self.right.runtime.registeredCanvasFonts()) |a, b| {
            try exact(a.id, b.id);
            try exact(a.face.*, b.face.*);
        }
        for (self.left.runtime.views[0..self.left.runtime.view_count], self.right.runtime.views[0..self.right.runtime.view_count]) |a, b| {
            try exact(a.presented_canvas_valid, b.presented_canvas_valid);
            try exact(a.gpu_canvas_frame_requested, b.gpu_canvas_frame_requested);
        }
        try exact(self.left.null_platform.gpu_surface_frame_request_count, self.right.null_platform.gpu_surface_frame_request_count);
        try exact(self.left.runtime.textMeasureProvider() != null, self.right.runtime.textMeasureProvider() != null);
    }
};
test "compiled font registry preserves complete admission, permanent identity, capacity and owned bytes" {
    const pair = try Pair.create();
    defer pair.destroy();
    const ids = [_]u64{ 64, 9007199254740992, 9007199254740993, std.math.maxInt(u64) };
    const owned = try std.testing.allocator.dupe(u8, font);
    defer std.testing.allocator.free(owned);
    for (ids) |id| {
        for ([_]*Harness{ pair.left, pair.right }) |h| try h.runtime.registerCanvasFont(id, owned);
        try pair.same();
    }
    owned[0] ^= 255;
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        try std.testing.expectEqualSlices(u8, font, h.runtime.canvas_font_entries[0].bytes);
        try std.testing.expect(h.runtime.registeredCanvasFontFace(ids[2]) != null);
        try std.testing.expect(h.runtime.registeredCanvasFontFace(65) == null);
        try std.testing.expectError(error.FontIdInUse, h.runtime.registerCanvasFont(ids[2], font));
    }
    for (65..69) |id| for ([_]*Harness{ pair.left, pair.right }) |h| try h.runtime.registerCanvasFont(id, font);
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        try std.testing.expectError(error.FontRegistryFull, h.runtime.registerCanvasFont(69, "bad"));
        try std.testing.expectError(error.InvalidFontId, h.runtime.registerCanvasFont(0, "bad"));
        try std.testing.expectError(error.ReservedFontId, h.runtime.registerCanvasFont(63, "bad"));
        try std.testing.expectError(error.FontIdInUse, h.runtime.registerCanvasFont(64, "bad"));
    }
    try pair.same();
}
test "compiled font registry preserves allocation refusal, parse refusal, retry and frozen allocator identity" {
    const pair = try Pair.create();
    var counters = [_]std.testing.FailingAllocator{
        std.testing.FailingAllocator.init(std.testing.allocator, .{}),
        std.testing.FailingAllocator.init(std.testing.allocator, .{}),
    };
    var mutated = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    for ([_]*Harness{ pair.left, pair.right }, 0..) |h, i| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        h.runtime.owned_allocator = failing.allocator();
        try std.testing.expectError(error.OutOfMemory, h.runtime.registerCanvasFont(64, font));
        h.runtime.owned_allocator = counters[i].allocator();
        try std.testing.expectError(error.FontParseFailed, h.runtime.registerCanvasFont(64, "bad"));
        try std.testing.expectEqual(counters[i].allocated_bytes, counters[i].freed_bytes);
        try h.runtime.registerCanvasFont(64, font);
        h.runtime.options.allocator = mutated.allocator();
    }
    try pair.same();
    pair.destroy();
    for (counters) |counter| try std.testing.expectEqual(counter.allocated_bytes, counter.freed_bytes);
    try std.testing.expectEqual(@as(usize, 0), mutated.allocations);
}
fn width(_: ?*anyopaque, _: u64, _: f32, _: []const u8) f32 {
    return 42;
}
test "compiled font registry preserves host refusal without a partially committed registration" {
    const pair = try Pair.create();
    defer pair.destroy();
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        h.runtime.options.platform.services.measure_text_fn = width;
        h.runtime.options.platform.services.register_gpu_surface_font_fn = null;
        try std.testing.expectError(error.FontHostRegistrationUnsupported, h.runtime.registerCanvasFont(64, font));
        try std.testing.expectEqual(@as(usize, 0), h.runtime.canvas_font_count);
        h.runtime.options.platform.services.measure_text_fn = null;
        try h.runtime.registerCanvasFont(64, font);
    }
    try pair.same();
}
test "compiled font registry preserves complete native measurement provider precedence" {
    const pair = try Pair.create();
    defer pair.destroy();
    try pair.same();
    for ([_]*Harness{ pair.left, pair.right }) |h| try h.runtime.registerCanvasFont(64, font);
    for ([_]u64{ 1, 2, 64, 9007199254740993 }) |id| for ([_][]const u8{ "A A", "AV\n", "\xf0\x9f", "\x00\xff" }) |text| {
        const a = pair.left.runtime.textMeasureProvider().?;
        const b = pair.right.runtime.textMeasureProvider().?;
        try exact(a.measure_fn(a.context, id, 17, text), b.measure_fn(b.context, id, 17, text));
    };
    for ([_]*Harness{ pair.left, pair.right }) |h| {
        h.runtime.text_measure_provider = .{ .measure_fn = width };
        try std.testing.expect(h.runtime.textMeasureProvider().? == &h.runtime.text_measure_provider.?);
    }
    try pair.same();
}
test "compiled font registry transport preserves complete integer words and refresh retries" {
    for ([_]u64{ 0, 63, 64, 9007199254740993, std.math.maxInt(u64) }) |id| {
        const p = policy.plan(observed, .register, &.{}, 0, .{ .id = id, .length = 0, .budget = 0 });
        try std.testing.expectEqual(@as(u32, if (id == 0) 1 else if (id < 64) 2 else 0), p.status);
    }
    for (0..9) |count| for (0..9) |built| {
        const p = policy.plan(observed, .refresh, &.{}, count, .{ .built_count = built });
        try std.testing.expectEqual(@as(u32, @intFromBool(count != built)), p.action);
    };
    for (0..4) |facts| {
        try std.testing.expectEqual(@as(u32, @intFromBool(facts == 3)), policy.plan(observed, .repaint, &.{}, 0, .{ .facts = @intCast(facts) }).action);
    }
    for (modes) |count| try std.testing.expect(count != 0);
}

test "compiled font registry returns captured host ownership and preserves newer shared-id registrations" {
    for ([_]bool{ false, true }) |compiled| {
        const host = try std.testing.allocator.create(sdk.NullPlatform);
        defer std.testing.allocator.destroy(host);
        host.* = .{ .gpu_surface_font_registrations = true };
        const a = try Harness.create(std.testing.allocator, .{});
        const b = try Harness.create(std.testing.allocator, .{});
        for ([_]*Harness{ a, b }) |h| {
            sdk.Runtime.initAt(&h.runtime, .{ .platform = host.platform(), .allocator = std.testing.allocator, .trace_sink = h.trace_sink.sink(), .environ = std.testing.environ });
            try h.start(.{ .context = h, .name = "font-owners", .source = sdk.platform.WebViewSource.html("") });
            if (compiled) h.runtime.font_registry_policy = observed;
            try h.runtime.registerCanvasFont(64, font);
        }
        const old = a.runtime.canvas_font_entries[0].host_registration_token;
        const newer = b.runtime.canvas_font_entries[0].host_registration_token;
        try std.testing.expect(old != 0 and newer > old);
        a.runtime.options.platform = a.null_platform.platform();
        a.destroy(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), host.gpu_surface_font_count);
        try std.testing.expectEqual(old, host.gpu_surface_font_unregister_token);
        b.runtime.options.platform = b.null_platform.platform();
        b.destroy(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), host.gpu_surface_font_count);
        try std.testing.expectEqual(newer, host.gpu_surface_font_unregister_token);
    }
}
var repaint_runtime: *sdk.Runtime = undefined;
var repaint_calls: usize = 0;
fn shrinkingRepaint(_: ?*anyopaque, _: sdk.platform.WindowId, _: []const u8) anyerror!void {
    repaint_calls += 1;
    repaint_runtime.view_count = 1;
}
test "compiled font registry retains repaint extent and current flags across host callbacks" {
    for ([_]bool{ false, true }) |compiled| {
        const h = try Harness.create(std.testing.allocator, .{});
        defer h.destroy(std.testing.allocator);
        h.null_platform.gpu_surfaces = true;
        try h.start(.{ .context = h, .name = "font-repaint", .source = sdk.platform.WebViewSource.html("") });
        _ = try h.runtime.createView(.{ .window_id = 1, .label = "first", .kind = .gpu_surface, .frame = .init(0, 0, 100, 100) });
        _ = try h.runtime.createView(.{ .window_id = 1, .label = "second", .kind = .gpu_surface, .frame = .init(0, 0, 100, 100) });
        if (compiled) h.runtime.font_registry_policy = observed;
        const extent = h.runtime.view_count;
        h.runtime.views[extent - 1].presented_canvas_valid = true;
        repaint_runtime = &h.runtime;
        repaint_calls = 0;
        const saved = h.runtime.options.platform.services.request_gpu_surface_frame_fn;
        h.runtime.options.platform.services.request_gpu_surface_frame_fn = shrinkingRepaint;
        try h.runtime.registerCanvasFont(64, font);
        try std.testing.expectEqual(@as(usize, 1), repaint_calls);
        try std.testing.expect(!h.runtime.views[extent - 1].presented_canvas_valid);
        h.runtime.view_count = extent;
        h.runtime.options.platform.services.request_gpu_surface_frame_fn = saved;
    }
}

const RefreshModel = struct { rows: usize = 0 };
const RefreshMsg = union(enum) { noop };
const RefreshApp = sdk.UiApp(RefreshModel, RefreshMsg);
const refresh_text = "AV SDK 123";
fn refreshUpdate(_: *RefreshModel, _: RefreshMsg) void {}
fn refreshTokens(_: *const RefreshModel) sdk.canvas.DesignTokens {
    var tokens = sdk.canvas.DesignTokens{};
    tokens.typography.font_id = 9007199254740993;
    return tokens;
}
fn refreshRowKey(index: *const usize) sdk.canvas.UiKey {
    return sdk.canvas.uiKey(@as(u64, index.*));
}
fn refreshRow(ui: *RefreshApp.Ui, index: *const usize) RefreshApp.Ui.Node {
    return ui.text(.{}, ui.fmt("Row {d}", .{index.*}));
}
fn refreshView(ui: *RefreshApp.Ui, model: *const RefreshModel) RefreshApp.Ui.Node {
    const rows = ui.arena.alloc(usize, model.rows) catch unreachable;
    for (rows, 0..) |*row, i| row.* = i;
    return ui.column(.{ .gap = 2 }, .{
        ui.row(.{ .gap = 8, .padding = 12 }, .{ui.text(.{}, refresh_text)}),
        ui.each(rows, refreshRowKey, refreshRow),
    });
}
fn refreshWindows(_: *const RefreshModel, scratch: *RefreshApp.WindowsScratch) []const RefreshApp.WindowDescriptor {
    scratch.windows[0] = .{ .label = "panel", .canvas_label = "panel-canvas", .title = "Font panel", .width = 240, .height = 200 };
    return scratch.windows[0..1];
}
fn refreshWindowView(ui: *RefreshApp.Ui, model: *const RefreshModel, _: []const u8) RefreshApp.Ui.Node {
    return refreshView(ui, model);
}
const refresh_views = [_]sdk.app_manifest.ShellView{.{ .label = "canvas", .kind = .gpu_surface, .fill = true, .gpu_backend = .metal }};
const refresh_windows = [_]sdk.app_manifest.ShellWindow{.{ .label = "main", .title = "Font refresh", .width = 240, .height = 200, .views = &refresh_views }};
noinline fn initRefresh(state: *RefreshApp, compiled: bool) void {
    // Keep the large by-value app initializer outside the paired test frame.
    state.* = RefreshApp.init(std.testing.allocator, .{}, .{
        .name = "font-refresh",
        .scene = .{ .windows = &refresh_windows },
        .canvas_label = "canvas",
        .tokens_fn = refreshTokens,
        .update = refreshUpdate,
        .view = refreshView,
        .windows_fn = refreshWindows,
        .window_view = refreshWindowView,
        .font_registry_policy = if (compiled) observed else null,
    });
}
fn refreshFrame(h: *Harness, app: sdk.App, window: u64, frame: u64) !void {
    try h.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = window,
        .label = if (window == 1) "canvas" else "panel-canvas",
        .size = .init(240, 200),
        .scale_factor = 1,
        .frame_index = frame,
        .timestamp_ns = frame * 1_000_000,
        .nonblank = true,
    } });
}
fn refreshWidth(h: *Harness, window: u64) !f32 {
    const layout = try h.runtime.canvasWidgetLayout(window, if (window == 1) "canvas" else "panel-canvas");
    for (layout.nodes) |node| if (node.widget.kind == .text and std.mem.eql(u8, node.widget.text, refresh_text)) return node.widget.frame.width;
    return error.TestUnexpectedResult;
}
fn sameRefresh(pair: Pair, states: [2]*RefreshApp) !void {
    try pair.same();
    try exact(states[0].model, states[1].model);
    try exact(states[0].fonts_built_count, states[1].fonts_built_count);
    for ([_]u64{ 1, 2 }) |window| {
        const label = if (window == 1) "canvas" else "panel-canvas";
        const a = try pair.left.runtime.canvasWidgetLayout(window, label);
        const b = try pair.right.runtime.canvasWidgetLayout(window, label);
        try exact(a.nodes, b.nodes);
    }
}
test "compiled font registry late fonts rebuild both surfaces and retry failed rebuilds from either arriving surface" {
    const saved_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_log_level;
    for ([_]u64{ 1, 2 }) |arriving_window| {
        const pair = Pair{
            .left = try Harness.create(std.testing.allocator, .{ .size = .init(240, 200) }),
            .right = try Harness.create(std.testing.allocator, .{ .size = .init(240, 200) }),
        };
        defer pair.destroy();
        const states = [2]*RefreshApp{ try std.testing.allocator.create(RefreshApp), try std.testing.allocator.create(RefreshApp) };
        defer for (states) |state| {
            state.deinit();
            std.testing.allocator.destroy(state);
        };
        for ([_]*Harness{ pair.left, pair.right }, states, 0..) |h, state, i| {
            h.null_platform.gpu_surfaces = true;
            initRefresh(state, i == 1);
            try h.start(state.app());
            h.runtime.started_timestamp_ns = 0;
            try refreshFrame(h, state.app(), 1, 1);
            try refreshFrame(h, state.app(), 2, 2);
            h.runtime.dispatch_error_policy = .degrade;
        }
        try sameRefresh(pair, states);
        const before = try refreshWidth(pair.left, 1);
        for ([_]*Harness{ pair.left, pair.right }, states) |h, state| {
            state.model.rows = sdk.runtime.max_canvas_widget_nodes_per_view + 40;
            try h.runtime.registerCanvasFont(9007199254740993, font);
            try refreshFrame(h, state.app(), arriving_window, 3);
            try std.testing.expectEqual(@as(usize, 1), h.runtime.dispatchErrors().len);
            try std.testing.expect(state.fonts_built_count != h.runtime.registeredCanvasFontCount());
        }
        try sameRefresh(pair, states);
        for ([_]*Harness{ pair.left, pair.right }, states) |h, state| {
            state.model.rows = 0;
            try refreshFrame(h, state.app(), arriving_window, 4);
            try std.testing.expectEqual(@as(usize, 1), h.runtime.dispatchErrors().len);
            try std.testing.expectEqual(h.runtime.registeredCanvasFontCount(), state.fonts_built_count);
            const main = try refreshWidth(h, 1);
            try std.testing.expect(@abs(main - before) > 1);
            try std.testing.expectEqual(main, try refreshWidth(h, 2));
        }
        try sameRefresh(pair, states);
    }
}
