//! Independent native declarations and complete compiled chrome composition.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("canvas_layers_core");
const decoder = @import("canvas_layers_decoder");
const parity = @import("effects_media_parity.zig");
const canvas = sdk.canvas;
const geometry = sdk.geometry;
const testing = std.testing;
const Adapter = sdk.TsUiApp(core);
const Host = sdk.TsCoreHost(core);
const Ui = canvas.Ui(core.Msg);
const View = canvas.CompiledMarkupView(core.Model, core.Msg, @embedFile("canvas-layers/app.native"));
const Plan = canvas.render_coordination_policy.ChromePlan;

pub const NativeModel = struct { phase: u8 = 0, level: f32 = 0.5 };
pub const NativeMsg = union(enum) { next, reset, level };
pub const NativeApp = sdk.UiApp(NativeModel, NativeMsg);
const scene_views = [_]sdk.ShellView{.{ .label = "layers-canvas", .kind = .gpu_surface, .fill = true, .gpu_backend = .metal }};
const scene_windows = [_]sdk.ShellWindow{.{ .label = "main", .title = "Canvas Layers", .width = 420, .height = 340, .views = &scene_views }};
pub const scene: sdk.ShellConfig = .{ .windows = &scene_windows };
pub fn nativeUpdate(model: *NativeModel, message: NativeMsg) void {
    switch (message) {
        .next => model.phase = if (model.phase >= 3) 0 else model.phase + 1,
        .reset => model.* = .{},
        .level => {},
    }
}
pub fn nativeView(ui: *NativeApp.Ui, model: *const NativeModel) NativeApp.Ui.Node {
    return ui.column(.{ .padding = 20, .gap = 8 }, .{
        ui.button(.{ .on_press = .next, .semantics = .{ .label = "Next layer state" } }, "Next"),
        ui.button(.{ .on_press = .reset, .semantics = .{ .label = "Reset layers" } }, "Reset"),
        ui.el(.slider, .{ .value = model.level, .on_change = .level, .semantics = .{ .label = "Path shape" } }, .{}),
    });
}
pub fn nativeSync(model: *NativeModel, layout: canvas.WidgetLayoutTree) void {
    for (layout.nodes) |node| if (node.widget.kind == .slider) {
        model.level = node.widget.value;
    };
}
pub fn nativeOptions() NativeApp.Options {
    return .{
        .name = "canvas-layers",
        .scene = scene,
        .canvas_label = "layers-canvas",
        .update = nativeUpdate,
        .view = nativeView,
        .sync = nativeSync,
        .chrome = .{ .prefix_commands = 256, .suffix_commands = 256, .variable_prefix = true, .build = nativePrefix, .build_suffix = nativeSuffix },
    };
}
var stops: [3]canvas.GradientStop = undefined;
var elements: [5]canvas.PathElement = undefined;
const open_elements = [_]canvas.PathElement{
    .{ .verb = .move_to, .points = .{ .init(24.5, 260.25), .zero(), .zero() } },
    .{ .verb = .line_to, .points = .{ .init(130.25, 278.5), .zero(), .zero() } },
};
fn paint(tokens: canvas.DesignTokens) canvas.Fill {
    stops = .{ .{ .offset = 0, .color = tokens.colors.background }, .{ .offset = 0.375, .color = .rgba(0.125, 0.5, 0.875, 0.75) }, .{ .offset = 1, .color = tokens.colors.surface } };
    return .{ .linear_gradient = .{ .start = .init(0.25, 1.5), .end = .init(310.75, 280.5), .stops = &stops } };
}
fn path(level: f32) []const canvas.PathElement {
    elements = .{
        .{ .verb = .move_to, .points = .{ .init(180.25, 180.5), .init(7, 8), .init(9, 10) } },
        .{ .verb = .line_to, .points = .{ .init(225.75, 182.25), .zero(), .zero() } },
        .{ .verb = .quad_to, .points = .{ .init(265.5, 210.75), .init(222.25, 246.5), .init(11, 12) } },
        .{ .verb = .cubic_to, .points = .{ .init(205.25, 268.5), .init(155.75, 246.25), .init(160.5 + level * 8, 205.5) } },
        .{ .verb = .close, .points = .{ .init(13, 14), .init(15, 16), .init(17, 18) } },
    };
    return &elements;
}
pub fn nativePrefix(model: *const NativeModel, builder: *canvas.Builder, size: geometry.SizeF, tokens: canvas.DesignTokens) anyerror!void {
    if (model.phase == 3) return;
    try builder.fillRect(.{ .id = std.math.maxInt(u64), .rect = .init(0, 0, size.width, size.height), .fill = paint(tokens) });
    try builder.fillRoundedRect(.{ .id = 9_007_199_254_740_993, .rect = .init(20.25, 95.5, 128.75, 120.25), .radius = canvas.Radius.all(13.5), .fill = .{ .color = .rgba(0.875, 0.125, 0.375, 0.75) } });
    if (model.phase == 1) try builder.drawLine(.{ .id = 3, .from = .init(16.25, 232.5), .to = .init(300.75, 310.5), .stroke = .{ .width = 3.25, .fill = paint(tokens) } });
}
pub fn nativeSuffix(model: *const NativeModel, builder: *canvas.Builder, _: geometry.SizeF, tokens: canvas.DesignTokens) anyerror!void {
    if (model.phase == 2) return;
    try builder.strokeRect(.{ .id = 4, .rect = .init(12.5, 12.25, 380.75, 270.5), .radius = .{ .top_left = 3.25, .top_right = 6.5, .bottom_right = 9.75, .bottom_left = 13 }, .stroke = .{ .width = 2.5, .fill = .{ .color = tokens.colors.border } } });
    try builder.fillPath(.{ .id = 5, .elements = path(model.level), .fill = .{ .color = .rgba(0.25, 0.75, 0.5, 0.5) } });
    try builder.strokePath(.{ .id = 6, .elements = path(model.level), .stroke = .{ .width = 2.75, .fill = paint(tokens) }, .cap = .round });
    if (model.phase == 1) try builder.strokePath(.{ .id = 7, .elements = &open_elements, .stroke = .{ .width = 6.5, .fill = .{ .color = .rgba(0.75, 0.5, 0.25, 1) } }, .cap = .butt });
}
fn options(comptime compiled: bool) Adapter.Options {
    return .{ .name = "canvas-layers", .scene = scene, .canvas_label = "layers-canvas", .view = if (compiled) decoder.build else View.build };
}
fn pointerClick(runtime: *sdk.Runtime, app: sdk.App, root: *const canvas.Widget, name: []const u8, timestamp: u64) !void {
    const widget = parity.find(root, name) orelse return error.WidgetNotFound;
    const layout = try runtime.canvasWidgetLayout(1, "layers-canvas");
    const bounds = (layout.findById(widget.id) orelse return error.WidgetNotFound).frame;
    for ([_]sdk.platform.GpuSurfaceInputKind{ .pointer_down, .pointer_up }) |kind| {
        try runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{
            .label = "layers-canvas",
            .kind = kind,
            .timestamp_ns = timestamp,
            .x = bounds.x + bounds.width * 0.75,
            .y = bounds.y + bounds.height * 0.5,
            .button = 0,
        } });
    }
}

fn pairedViews(comptime compiled: bool) !void {
    const native = try NativeApp.create(testing.allocator, nativeOptions());
    defer native.destroy();
    const state = try Adapter.create(testing.allocator, .{}, options(compiled));
    defer state.destroy();
    const left = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(420, 340) });
    defer left.destroy(testing.allocator);
    const right = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(420, 340) });
    defer right.destroy(testing.allocator);
    left.null_platform.gpu_surfaces = true;
    right.null_platform.gpu_surfaces = true;
    try left.start(native.app());
    try right.start(state.app());
    // Both independent hosts receive the same synthetic OS clock facts.
    // These tests have no live host-uptime measurement.
    left.runtime.started_timestamp_ns = 0;
    right.runtime.started_timestamp_ns = 0;
    left.runtime.views[0].gpu_surface_created_timestamp_ns = 1;
    right.runtime.views[0].gpu_surface_created_timestamp_ns = 1;
    for (0..16) |ordinal| {
        const timestamp = 9_007_199_254_740_993 + ordinal;
        const frame: sdk.platform.GpuSurfaceFrameEvent = .{ .label = "layers-canvas", .size = if (ordinal % 2 == 0) .init(420, 340) else .init(640, 480), .frame_index = ordinal + 1, .timestamp_ns = timestamp, .frame_interval_ns = 16_666_667 };
        try left.runtime.dispatchPlatformEvent(native.app(), .{ .gpu_surface_frame = frame });
        try right.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_frame = frame });
        const name = if (ordinal % 3 == 0) "Path shape" else "Next layer state";
        try pointerClick(&left.runtime, native.app(), &native.tree.?.root, name, timestamp);
        try pointerClick(&right.runtime, state.app(), &state.tree.?.root, name, timestamp);
        const model = core.snapshotModel();
        try testing.expectEqual(@as(i64, native.model.phase), model.phase);
        try testing.expectEqual(@as(f64, native.model.level), model.level);
        const left_snapshot = left.runtime.automationSnapshot("canvas-layers");
        const right_snapshot = right.runtime.automationSnapshot("canvas-layers");
        inline for (@typeInfo(sdk.platform.ViewInfo).@"struct".fields) |field| {
            parity.equal(@field(left_snapshot.views[0], field.name), @field(right_snapshot.views[0], field.name)) catch |err| {
                std.debug.print("canvas view field: {s}\n", .{field.name});
                return err;
            };
        }
        try parity.equal(left_snapshot, right_snapshot);
        try parity.equal(try left.runtime.canvasWidgetLayout(1, "layers-canvas"), try right.runtime.canvasWidgetLayout(1, "layers-canvas"));
        const a = try left.runtime.canvasDisplayList(1, "layers-canvas");
        const b = try right.runtime.canvasDisplayList(1, "layers-canvas");
        try parity.equal(a.commands, b.commands);
        try testing.expectEqual(@as(usize, 0), native.effects.pendingTimerCount());
        try testing.expectEqual(@as(usize, 0), state.effects.pendingTimerCount());
        core.rt.frameReset();
    }
}
test "compiled layers retain complete native models widgets snapshots and commands on both views" {
    try pairedViews(false);
    try pairedViews(true);
}

test "compiled canvas layers preserve all native primitives and storage across helper reuse" {
    var fx = Host.Fx.init(testing.allocator);
    defer fx.deinit();
    Host.init(&fx);
    const config = Adapter.mobileOptions(.{}, options(true));
    var expected_commands: [8]canvas.CanvasCommand = undefined;
    var actual_commands: [8]canvas.CanvasCommand = undefined;
    for (0..4) |phase| {
        for ([_]f32{ 0, 0.125, 0.5, 0.875, 1 }) |level| {
            Host.dispatch(&fx, .{ .level = level });
            for ([_]geometry.SizeF{ .init(420, 340), .init(640, 480), .init(1, 1) }) |size| {
                var expected = canvas.Builder.init(&expected_commands);
                var actual = canvas.Builder.init(&actual_commands);
                const native: NativeModel = .{ .phase = @intCast(phase), .level = level };
                try nativePrefix(&native, &expected, size, .{});
                const prefix_count = expected.len;
                try nativeSuffix(&native, &expected, size, .{});
                try config.chrome.?.build(Host.model(), &actual, size, .{});
                try testing.expectEqual(prefix_count, actual.len);
                core.rt.frameReset();
                try config.chrome.?.build_suffix.?(Host.model(), &actual, size, .{});
                try parity.equal(expected.displayList().commands, actual.displayList().commands);
                core.rt.frameReset();
                try parity.equal(expected.displayList().commands, actual.displayList().commands);
            }
        }
        Host.dispatch(&fx, .next);
    }
}

test "compiled canvas composition preserves u64 budgets and complete accepted and refused plans" {
    _ = core.initialModel();
    const values = [_]usize{ 0, 1, 2, 63, 64, 255, 256, 512, std.math.maxInt(u32), @as(usize, std.math.maxInt(u32)) + 1, 9_007_199_254_740_993, std.math.maxInt(usize) };
    for (values) |prefix_budget| for (values) |suffix_budget| for ([_]usize{ 0, 1, 2, 64, 256, 512 }) |count| for ([_]?usize{ null, 0, 1, 256, 512 }) |before| for ([_]bool{ false, true }) |variable| {
        const first = before orelse (std.math.sub(usize, count, suffix_budget) catch std.math.maxInt(usize));
        const valid = first <= count and (if (variable) first <= prefix_budget else first == prefix_budget) and
            (if (before != null) count - first <= suffix_budget else suffix_budget <= count);
        if (valid) {
            const result = try Plan.init(core.nativeWindowPolicy, prefix_budget, suffix_budget, count, before, variable);
            try testing.expectEqual(first, result.prefix);
            try testing.expectEqual(count - first, result.suffix);
            core.rt.frameReset();
            try testing.expectEqual(first, result.prefix);
        } else try testing.expectError(error.InvalidChromeCommandCount, Plan.init(core.nativeWindowPolicy, prefix_budget, suffix_budget, count, before, variable));
    };
}

fn cloneValue(comptime T: type, value: T, allocator: std.mem.Allocator) !T {
    return switch (@typeInfo(T)) {
        .pointer => |info| if (info.size == .slice) blk: {
            const result = try allocator.alloc(info.child, value.len);
            for (value, result) |old, *new| new.* = try cloneValue(info.child, old, allocator);
            break :blk result;
        } else value,
        .@"struct" => |info| blk: {
            var result: T = undefined;
            inline for (info.fields) |field| @field(result, field.name) = try cloneValue(field.type, @field(value, field.name), allocator);
            break :blk result;
        },
        .@"union" => switch (value) {
            inline else => |payload, tag| @unionInit(T, @tagName(tag), try cloneValue(@TypeOf(payload), payload, allocator)),
        },
        .array => |info| blk: {
            var result: T = undefined;
            for (value, &result) |old, *new| new.* = try cloneValue(info.child, old, allocator);
            break :blk result;
        },
        .optional => |info| if (value) |old| try cloneValue(info.child, old, allocator) else null,
        else => value,
    };
}

fn retainedReplay(comptime compiled: bool, comptime record: bool) !void {
    var buffer = parity.JournalBuffer.init();
    defer buffer.deinit();
    var recorder = sdk.runtime.SessionRecorder.init(.{ .context = &buffer, .write_fn = parity.JournalBuffer.write });
    recorder.begin(sdk.runtime.sessionHeaderNow(sdk.runtime.sessionPlatformName(), "canvas-layers", 420, 340));
    var fingerprint: u64 = 0;
    var saved: ?[]u8 = null;
    defer if (saved) |bytes| testing.allocator.free(bytes);
    {
        const state = try Adapter.create(testing.allocator, .{}, options(compiled));
        defer state.destroy();
        const harness = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(420, 340) });
        defer harness.destroy(testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        if (record) harness.runtime.options.session_recorder = &recorder;
        try harness.start(state.app());
        try harness.runtime.dispatchPlatformEvent(state.app(), .{ .gpu_surface_frame = .{ .label = "layers-canvas", .size = .init(420, 340), .frame_index = 1 } });
        for (0..8) |_| {
            try parity.action(&harness.runtime, state.app(), &state.tree.?.root, "layers-canvas", "Next layer state", "press");
            try parity.action(&harness.runtime, state.app(), &state.tree.?.root, "layers-canvas", "Path shape", "increment");
            if (!record) {
                var arena = std.heap.ArenaAllocator.init(testing.allocator);
                defer arena.deinit();
                const full = try harness.runtime.canvasDisplayList(1, "layers-canvas");
                const before = try cloneValue(@TypeOf(full.commands), full.commands, arena.allocator());
                try testing.expectEqualStrings("layers-canvas", harness.runtime.views[0].label);
                try testing.expect(harness.runtime.views[0].canvas_display_list_widget_owned);
                // The return value reports paint changes. An identical
                // retained rebuild must preserve every command and be idle.
                try testing.expect(!try harness.runtime.refreshCanvasWidgetDisplayListIfOwned(0));
                const after = try harness.runtime.canvasDisplayList(1, "layers-canvas");
                try parity.equal(before, after.commands);
            }
        }
        fingerprint = harness.runtime.sessionStateFingerprint();
        saved = try testing.allocator.dupe(u8, core.modelSnapshot());
        recorder.finish();
        try testing.expect(!recorder.failed);
    }
    if (!record) return;
    const state = try Adapter.create(testing.allocator, .{}, options(compiled));
    defer state.destroy();
    const harness = try sdk.TestHarness().create(testing.allocator, .{ .size = .init(420, 340) });
    defer harness.destroy(testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const report = try sdk.runtime.replaySession(&harness.runtime, state.app(), buffer.bytes.written(), .{ .require_same_platform = false });
    try testing.expect(report.ok());
    try testing.expectEqual(recorder.event_count, report.events_replayed);
    try testing.expectEqual(recorder.checkpoint_count, report.checkpoints_verified);
    try testing.expectEqual(recorder.effect_count, report.effects_fed);
    try testing.expectEqual(fingerprint, harness.runtime.sessionStateFingerprint());
    try testing.expectEqualSlices(u8, saved.?, core.modelSnapshot());
}
test "compiled variable canvas layers survive retained widget updates and complete replay on both views" {
    try retainedReplay(false, false);
    try retainedReplay(true, false);
    try retainedReplay(false, true);
    try retainedReplay(true, true);
}
