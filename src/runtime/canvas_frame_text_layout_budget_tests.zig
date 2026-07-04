//! Text-layout plan budget tests: a long real agent transcript once blew
//! the old fixed cap and killed renders. Now the per-frame plan list
//! is derived from the command budget so `TextLayoutPlanListFull` is
//! structurally unreachable through a real display list, the shared line
//! pool overflows loudly one past its own budget, and automation
//! snapshots report `text_layout_plans=N/budget` headroom on every
//! gpu_surface view line so the cliff is visible before a frame dies.

const support = @import("test_support.zig");
const std = support.std;
const geometry = support.geometry;
const canvas = support.canvas;
const platform = support.platform;
const automation = support.automation;
const App = support.App;
const TestHarness = support.TestHarness;
const canvas_limits = @import("canvas_limits.zig");

test "text layout plan budget: the command budget binds first" {
    // Every plan is born from exactly one draw_text command, and a display
    // list holds at most `max_canvas_commands_per_view` commands — with the
    // plan budget at least that large, the command budget always fails
    // first (loudly, at build time), never the plan list.
    try std.testing.expect(canvas_limits.max_canvas_text_layouts_per_view >= canvas_limits.max_canvas_commands_per_view);
}

test "text layout planner carries a full command-budget frame of text (at-budget)" {
    const allocator = std.testing.allocator;
    const count = canvas_limits.max_canvas_commands_per_view;

    const commands = try allocator.alloc(canvas.CanvasCommand, count);
    defer allocator.free(commands);
    var builder = canvas.Builder.init(commands);
    for (0..count) |index| {
        try builder.drawText(.{
            .id = @intCast(index + 1),
            .size = 12,
            .origin = geometry.PointF.init(0, @floatFromInt(14 * (index + 1))),
            .color = canvas.Color.rgb8(15, 23, 42),
            .text = "x",
        });
    }

    const plans = try allocator.alloc(canvas.TextLayoutPlan, canvas_limits.max_canvas_text_layouts_per_view);
    defer allocator.free(plans);
    const lines = try allocator.alloc(canvas.TextLine, canvas_limits.max_canvas_text_layout_lines_per_view);
    defer allocator.free(lines);
    const set = try builder.displayList().textLayoutPlan(.{}, plans, lines);
    try std.testing.expectEqual(count, set.planCount());
    try std.testing.expectEqual(count, set.lineCount());
}

test "text layout plan overflow is loud one past the plan list" {
    var commands: [3]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    for (0..3) |index| {
        try builder.drawText(.{
            .id = @intCast(index + 1),
            .size = 12,
            .origin = geometry.PointF.init(0, @floatFromInt(14 * (index + 1))),
            .color = canvas.Color.rgb8(15, 23, 42),
            .text = "x",
        });
    }

    var lines: [8]canvas.TextLine = undefined;
    // At capacity: three plans fit a three-slot list.
    var fitting_plans: [3]canvas.TextLayoutPlan = undefined;
    const set = try builder.displayList().textLayoutPlan(.{}, &fitting_plans, &lines);
    try std.testing.expectEqual(@as(usize, 3), set.planCount());
    // One past: the same frame against a two-slot list fails by name.
    var overflow_plans: [2]canvas.TextLayoutPlan = undefined;
    try std.testing.expectError(
        error.TextLayoutPlanListFull,
        builder.displayList().textLayoutPlan(.{}, &overflow_plans, &lines),
    );
}

test "text layout line overflow is loud one past the shared line pool" {
    var commands: [1]canvas.CanvasCommand = undefined;
    var builder = canvas.Builder.init(&commands);
    try builder.drawText(.{
        .id = 1,
        .size = 12,
        .origin = geometry.PointF.init(0, 14),
        .color = canvas.Color.rgb8(15, 23, 42),
        .text = "a\nb\nc",
    });

    var plans: [1]canvas.TextLayoutPlan = undefined;
    // At capacity: three explicit lines fit a three-slot pool.
    var fitting_lines: [3]canvas.TextLine = undefined;
    const set = try builder.displayList().textLayoutPlan(.{}, &plans, &fitting_lines);
    try std.testing.expectEqual(@as(usize, 3), set.lineCount());
    // One past: the same text against a two-slot pool fails by name.
    var overflow_lines: [2]canvas.TextLine = undefined;
    try std.testing.expectError(
        error.TextLayoutLineListFull,
        builder.displayList().textLayoutPlan(.{}, &plans, &overflow_lines),
    );
}

test "automation snapshots report text-layout plan and line headroom" {
    const TestApp = struct {
        fn app(self: *@This()) App {
            return .{ .context = self, .name = "gpu-canvas-text-budget", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
        }
    };

    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: TestApp = .{};
    try harness.start(app_state.app());

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 200),
    });

    const commands = [_]canvas.CanvasCommand{
        .{ .draw_text = .{
            .id = 1,
            .size = 14,
            .origin = geometry.PointF.init(12, 32),
            .color = canvas.Color.rgb8(15, 23, 42),
            .text = "one line",
        } },
        .{ .draw_text = .{
            .id = 2,
            .size = 14,
            .origin = geometry.PointF.init(12, 64),
            .color = canvas.Color.rgb8(15, 23, 42),
            .text = "two\nlines",
        } },
    };
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });
    _ = try harness.runtime.nextCanvasFrame(1, "canvas", .{ .frame_index = 1 }, harness.runtime.canvasFrameScratchStorage());

    var buffer: [16384]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try automation.snapshot.writeText(harness.runtime.automationSnapshot("Text budgets"), &writer);
    const plans_expected = std.fmt.comptimePrint("text_layout_plans=2/{d}", .{canvas_limits.max_canvas_text_layouts_per_view});
    const lines_expected = std.fmt.comptimePrint("text_layout_lines=3/{d}", .{canvas_limits.max_canvas_text_layout_lines_per_view});
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), plans_expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), lines_expected) != null);
}
