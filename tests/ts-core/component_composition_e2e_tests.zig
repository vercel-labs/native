//! Complete composed trees and typed handlers against the native reference.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("ts_persist_core");
const canvas = sdk.canvas;
const Ui = canvas.Ui(core.Msg);
const exact = @import("component_construction_e2e_tests.zig").exact;

fn msg() core.Msg {
    inline for (@typeInfo(core.Msg).@"union".fields) |field| if (field.type == void) return @unionInit(core.Msg, field.name, {});
    @compileError("composition fixture needs a void Msg");
}

fn builders(arena: std.mem.Allocator) [2]Ui {
    var result = [2]Ui{ Ui.init(arena), Ui.init(arena) };
    result[1].construction_policy = core.nativeWindowPolicy;
    result[1].composition_policy = core.nativeWindowPolicy;
    return result;
}

test "compiled composition preserves complete stepper trees and all u64 active values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const steps = [_]Ui.StepperStep{ .{ .label = "Start\x00\xff" }, .{ .label = "Review café" }, .{ .label = "Done" } };
    for ([_]usize{ 0, 1, 2, 3, 4, 9007199254740993, std.math.maxInt(usize) }) |active| for (0..4) |count| {
        var pair = builders(arena.allocator());
        const options: Ui.StepperOptions = .{ .active = active, .key = .{ .str = "stages" }, .grow = 1, .semantics = .{ .label = "Workflow" } };
        const expected = try pair[0].finalize(pair[0].stepper(options, steps[0..count]));
        const actual = try pair[1].finalize(pair[1].stepper(options, steps[0..count]));
        core.rt.frameReset();
        try exact(expected, actual);
    };
}

test "compiled composition preserves complete timeline variants optional children spans and root press" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (0..32) |mask| for (std.enums.values(canvas.WidgetVariant)) |variant| {
        var pair = builders(arena.allocator());
        const options: Ui.TimelineItemOptions = .{ .title = "Title\x00\xff", .description = if (mask & 1 != 0) "Preview\x00\xff" else "", .meta = if (mask & 2 != 0) "meta café" else "", .connector = mask & 4 != 0, .on_press = if (mask & 8 != 0) msg() else null, .indicator = if (mask & 16 != 0) "3" else "", .variant = variant, .selected = mask & 1 != 0, .key = .{ .str = "item" } };
        const expected = try pair[0].finalize(pair[0].timeline(.{ .gap = 7, .grow = 1, .key = .{ .str = "ledger" } }, .{pair[0].timelineItem(options)}));
        const actual = try pair[1].finalize(pair[1].timeline(.{ .gap = 7, .grow = 1, .key = .{ .str = "ledger" } }, .{pair[1].timelineItem(options)}));
        core.rt.frameReset();
        try exact(expected, actual);
    };
}

fn grouped(ui: *Ui, mask: usize, grow: f32) Ui.Node {
    const transparent = canvas.Color.rgba8(0, 0, 0, 0);
    const entry = ui.el(.textarea, .{ .text = "draft\x00\xff", .grow = grow, .style = .{ .background = if (mask & 1 != 0) transparent else null, .border = if (mask & 2 != 0) transparent else null, .focus_ring = if (mask & 4 != 0) transparent else null }, .style_tokens = .{ .background = if (mask & 8 != 0) .surface else null, .border_color = if (mask & 16 != 0) .border else null, .focus_ring = if (mask & 32 != 0) .accent else null }, .semantics = .{ .label = "Draft" } }, .{});
    const actions = ui.inputGroupActions(.{ .gap = 5, .key = .{ .str = "actions" } }, .{ui.button(.{ .on_press = msg() }, "Send")});
    return ui.inputGroup(.{ .width = 360, .height = 160, .min_width = 100, .grow = 1, .key = .{ .str = "composer" }, .semantics = .{ .label = "Compose" } }, entry, if (mask & 64 != 0) actions else null);
}

test "compiled composition preserves grouped entry chrome authored tokens focus and exact grow words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (0..128) |mask| for ([_]u32{ 0, 0x80000000, 0x3f000000, 0x7fc00037 }) |word| {
        var pair = builders(arena.allocator());
        const expected = try pair[0].finalize(grouped(&pair[0], mask, @bitCast(word)));
        const actual = try pair[1].finalize(grouped(&pair[1], mask, @bitCast(word)));
        core.rt.frameReset();
        try exact(expected, actual);
    };
}

fn pages(ui: *Ui) [3]Ui.Node {
    return .{ ui.text(.{}, "One"), ui.text(.{ .key = .{ .str = "authored" } }, "Two"), ui.text(.{ .global_key = .{ .str = "global" } }, "Three") };
}
test "compiled composition preserves navigation mounting hidden state keys and max u64 active index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]usize{ 0, 1, 2, 3, 9007199254740993, std.math.maxInt(usize) }) |active| for ([_]bool{ false, true }) |retain| for (0..4) |count| {
        var pair = builders(arena.allocator());
        const before = pages(&pair[0]);
        const after = pages(&pair[1]);
        const options: Ui.NavOptions = .{ .active = active, .retain = retain, .grow = 1, .min_width = 240, .semantics = .{ .label = "Pages" } };
        const expected = try pair[0].finalize(pair[0].nav(options, before[0..count]));
        const actual = try pair[1].finalize(pair[1].nav(options, after[0..count]));
        core.rt.frameReset();
        try exact(expected, actual);
    };
}
