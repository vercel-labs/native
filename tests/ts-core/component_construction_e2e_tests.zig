//! Complete construction comparisons through the shipped scriptc library.
const std = @import("std");
const sdk = @import("native_sdk");
const core = @import("ts_persist_core");
const canvas = sdk.canvas;
const Ui = canvas.Ui(core.Msg);

fn exact(expected: anytype, actual: @TypeOf(expected)) anyerror!void {
    const T = @TypeOf(expected);
    switch (@typeInfo(T)) {
        .float => {
            if (@sizeOf(T) == 4) try std.testing.expectEqual(@as(u32, @bitCast(expected)), @as(u32, @bitCast(actual))) else try std.testing.expectEqual(@as(u64, @bitCast(expected)), @as(u64, @bitCast(actual)));
        },
        .optional => {
            try std.testing.expectEqual(expected != null, actual != null);
            if (expected) |v| try exact(v, actual.?);
        },
        .@"struct" => inline for (@typeInfo(T).@"struct".fields) |field| try exact(@field(expected, field.name), @field(actual, field.name)),
        .@"union" => {
            const tag = std.meta.activeTag(expected);
            try std.testing.expectEqual(tag, std.meta.activeTag(actual));
            inline for (@typeInfo(T).@"union".fields) |field| if (std.mem.eql(u8, field.name, @tagName(tag))) try exact(@field(expected, field.name), @field(actual, field.name));
        },
        .pointer => |pointer| {
            if (pointer.size == .slice) {
                try std.testing.expectEqual(expected.len, actual.len);
                for (expected, actual) |a, b| try exact(a, b);
            } else try std.testing.expectEqual(expected, actual);
        },
        .array => for (expected, actual) |a, b| try exact(a, b),
        else => try std.testing.expectEqual(expected, actual),
    }
}

test "compiled construction preserves every element kind size spacing and complete widget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reference = Ui.init(arena.allocator());
    var compiled = Ui.init(arena.allocator());
    compiled.construction_policy = core.nativeWindowPolicy;
    for (std.enums.values(canvas.WidgetKind)) |kind| for (std.enums.values(canvas.WidgetSize)) |size| for ([_]?f32{ null, 0, 7 }) |padding| for (0..4) |flags| {
        const options: Ui.ElementOptions = .{
            .size = size,
            .padding = padding,
            .gap = if (flags & 1 != 0) 5 else 0,
            .checked = flags & 1 != 0,
            .selected = flags & 2 != 0,
            .width = if (flags & 1 != 0) 100 else 0,
            .height = 80,
            .min_width = 120,
            .max_width = 200,
            .value = 0.25,
            .cross = @enumFromInt(flags),
            .disabled = flags & 2 != 0,
            .text = "bytes\x00\xff",
            .placeholder = "placeholder",
            .key = .{ .str = "control" },
        };
        const expected = reference.el(kind, options, .{});
        const actual = compiled.el(kind, options, .{});
        try exact(expected, actual);
        try exact(try reference.finalize(expected), try compiled.finalize(actual));
    };
    const words = [_]u32{ 0, 0x80000000, 0x3f800000, 0xbf800000, 0x7f800000, 0xff800000, 0x7fc00037 };
    for (words) |a| for (words) |b| {
        const options: Ui.ElementOptions = .{ .width = @bitCast(a), .min_width = @bitCast(b), .max_width = @bitCast(a), .height = @bitCast(b), .value = @bitCast(a) };
        try exact(reference.el(.panel, options, .{}), compiled.el(.panel, options, .{}));
    };
    // The callback is borrowed executable code, absent from each retained
    // widget. Every descriptor and field survives resetting its result arena.
    const expected = reference.el(.card, .{ .padding = 0, .text = "owned" }, .{});
    const actual = compiled.el(.card, .{ .padding = 0, .text = "owned" }, .{});
    core.rt.frameReset();
    try exact(expected, actual);
}

fn voidMsg() core.Msg {
    inline for (@typeInfo(core.Msg).@"union".fields) |field| if (field.type == void) return @unionInit(core.Msg, field.name, {});
    @compileError("construction fixture needs a void message");
}
fn inputMsg(_: canvas.TextInputEvent) core.Msg {
    return voidMsg();
}
fn valueMsg(_: f32) core.Msg {
    return voidMsg();
}

test "compiled construction finalizes complete token styles wraps and typed handler actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reference = Ui.init(arena.allocator());
    var compiled = Ui.init(arena.allocator());
    compiled.construction_policy = core.nativeWindowPolicy;
    var tokens: canvas.DesignTokens = .{};
    tokens.colors.text = .{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 1 };
    tokens.colors.text_muted = .{ .r = 0.75, .g = 0.25, .b = 0.5, .a = 1 };
    tokens.radius.none = 99;
    for (std.enums.values(canvas.ColorTokenName)) |color| for (std.enums.values(canvas.RadiusTokenName)) |radius| for (0..4) |style_case| {
        const options: Ui.ElementOptions = .{
            .text = "a\x00\xff",
            .wrap = if (style_case == 0) null else style_case & 1 != 0,
            .style_tokens = .{ .background = color, .foreground = color, .accent = color, .accent_foreground = color, .border_color = color, .focus_ring = color, .radius = radius },
            .style = if (style_case == 3) .{ .background = .{ .r = -0.0, .g = @bitCast(@as(u32, 0x7fc00037)), .b = 0.25, .a = 0 }, .radius = 0 } else .{},
            .on_press = voidMsg(),
            .on_drag = voidMsg(),
            .on_double_press = voidMsg(),
            .on_toggle = voidMsg(),
            .on_hold = voidMsg(),
            .on_hover_enter = voidMsg(),
            .on_hover_leave = voidMsg(),
            .on_input = inputMsg,
            .on_value = valueMsg,
            .on_change = voidMsg(),
            .semantics = .{ .actions = .{ .focus = true, .set_selection = true, .select = true, .drop_files = true, .dismiss = true } },
        };
        const expected = try reference.finalizeWithTokens(reference.el(.text, options, .{}), tokens);
        const actual = try compiled.finalizeWithTokens(compiled.el(.text, options, .{}), tokens);
        core.rt.frameReset();
        try exact(expected, actual);
        if (actual.root.spans.len > 0) try std.testing.expectEqual(actual.root.text.ptr, actual.root.spans[0].text.ptr);
    };
    for (0..1024) |handlers| {
        const options: Ui.ElementOptions = .{
            .on_press = if (handlers & 1 != 0) voidMsg() else null,
            .on_drag = if (handlers & 2 != 0) voidMsg() else null,
            .on_double_press = if (handlers & 4 != 0) voidMsg() else null,
            .on_toggle = if (handlers & 8 != 0) voidMsg() else null,
            .on_hold = if (handlers & 16 != 0) voidMsg() else null,
            .on_hover_enter = if (handlers & 32 != 0) voidMsg() else null,
            .on_hover_leave = if (handlers & 64 != 0) voidMsg() else null,
            .on_input = if (handlers & 128 != 0) inputMsg else null,
            .on_value = if (handlers & 256 != 0) valueMsg else null,
            .on_change = if (handlers & 512 != 0) voidMsg() else null,
        };
        try exact(try reference.finalize(reference.el(.slider, options, .{})), try compiled.finalize(compiled.el(.slider, options, .{})));
    }
}

fn composed(ui: *Ui) Ui.Node {
    return ui.el(.split, .{ .value = 0.37, .disabled = true }, .{
        ui.el(.card, .{ .key = .{ .str = "left" }, .text = "left", .on_press = voidMsg() }, .{}),
        ui.el(.panel, .{ .key = .{ .str = "right" }, .text = "right", .context_menu = &.{
            .{ .label = "Enabled\x00\xff", .msg = voidMsg() },
            .{ .separator = true, .label = "must not become text" },
            .{ .label = "Disabled", .enabled = false, .msg = voidMsg() },
        } }, .{}),
    });
}

test "compiled construction synthesizes split and menu children with exact ids handlers and arena ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]?sdk.geometry.PointF{ null, .{ .x = 17, .y = 29 } }) |point| {
        var reference = Ui.init(arena.allocator());
        var compiled = Ui.init(arena.allocator());
        compiled.construction_policy = core.nativeWindowPolicy;
        const seed = try reference.finalize(composed(&reference));
        reference.context_menu_fallback_target = seed.root.children[2].id;
        compiled.context_menu_fallback_target = reference.context_menu_fallback_target;
        reference.context_menu_fallback_point = point;
        compiled.context_menu_fallback_point = point;
        const expected = try reference.finalize(composed(&reference));
        const actual = try compiled.finalize(composed(&compiled));
        core.rt.frameReset();
        try exact(expected, actual);
        try std.testing.expectEqualStrings("Split divider", actual.root.children[1].semantics.label);
        const menu = actual.root.children[2].children[0];
        try std.testing.expectEqualStrings("Context menu", menu.semantics.label);
        try std.testing.expectEqual(@as(usize, 3), actual.context_menu_fallback.?.item_ids.len);
        try std.testing.expectEqual(@as(u64, 0), actual.context_menu_fallback.?.item_ids[1]);
        try std.testing.expect(!menu.children[2].semantics.actions.press);
        try std.testing.expectEqual(voidMsg(), actual.msgForContextMenu(reference.context_menu_fallback_target, 0).?);
    }
}

test "compiled construction covers all builtin defaults and independent author overrides" {
    for (std.enums.values(canvas.BuiltinComponentKind)) |kind| for (0..7) |size_case| for (0..7) |variant_case| for (0..8) |spacing| {
        const options: canvas.BuiltinComponentOptions = .{
            .id = 42,
            .text = "component\x00\xff",
            .value = 0.25,
            .size = if (size_case == 6) null else @enumFromInt(size_case),
            .variant = if (variant_case == 6) null else @enumFromInt(variant_case),
            .layout = .{
                .padding = if (spacing & 1 != 0) .{ .top = 0, .right = 7, .bottom = 0, .left = 0 } else .{},
                .gap = if (spacing & 2 != 0) 5 else 0,
                .cross_alignment = if (spacing & 4 != 0) .end else .stretch,
                .min_size = if (spacing & 4 != 0) .{ .width = 7, .height = 0 } else .{},
            },
            .semantics = .{ .role = if (spacing & 1 != 0) .link else .none },
        };
        const expected = canvas.builtinComponentWidget(kind, options);
        var selected = options;
        selected.construction_policy = core.nativeWindowPolicy;
        const actual = canvas.builtinComponentWidget(kind, selected);
        core.rt.frameReset();
        try exact(expected, actual);
    };
}

test "compiled construction retains split capacity and allocation failure behavior" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (0..5) |count| {
        var reference = Ui.init(arena.allocator());
        var compiled = Ui.init(arena.allocator());
        compiled.construction_policy = core.nativeWindowPolicy;
        const a = try arena.allocator().alloc(Ui.Node, count);
        const b = try arena.allocator().alloc(Ui.Node, count);
        for (a, b) |*left, *right| {
            left.* = reference.text(.{}, "pane");
            right.* = compiled.text(.{}, "pane");
        }
        const expected = try reference.finalize(reference.el(.split, .{}, a));
        const actual = try compiled.finalize(compiled.el(.split, .{}, b));
        try exact(expected, actual);
        try std.testing.expectEqual(if (count == 2) @as(usize, 3) else count, actual.root.children.len);
    }
    for ([_]?canvas.ComponentConstructionPolicy.Policy{ null, core.nativeWindowPolicy }) |policy| {
        var ui = Ui.init(std.testing.failing_allocator);
        ui.construction_policy = policy;
        const node = ui.el(.text, .{ .text = "wrap", .wrap = true }, .{});
        try std.testing.expectError(error.OutOfMemory, ui.finalize(node));
    }
}

test "compiled construction owner reaches primary and secondary app builders" {
    const Adapter = sdk.TsUiApp(core);
    const Factory = struct {
        var primary: bool = false;
        var secondary: bool = false;
        fn view(ui: *Ui, _: *const core.Model) Ui.Node {
            primary = ui.construction_policy == core.nativeWindowPolicy;
            return ui.el(.card, .{ .padding = 0, .on_press = voidMsg() }, .{ui.text(.{}, "primary")});
        }
        fn windowView(ui: *Ui, _: *const core.Model, _: []const u8) Ui.Node {
            secondary = ui.construction_policy == core.nativeWindowPolicy;
            return ui.el(.card, .{ .padding = 0, .on_press = voidMsg() }, .{ui.text(.{}, "secondary")});
        }
        fn windows(_: *const core.Model, scratch: *Adapter.App.WindowsScratch) []const Adapter.App.WindowDescriptor {
            scratch.windows[0] = .{ .label = "panel", .canvas_label = "panel-canvas", .title = "Panel" };
            return scratch.windows[0..1];
        }
    };
    Factory.primary = false;
    Factory.secondary = false;
    const harness = try sdk.TestHarness().create(std.testing.allocator, .{ .size = .init(320, 200) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    const app = try Adapter.create(std.testing.allocator, .{}, .{
        .name = "construction",
        .scene = .{ .windows = &.{.{ .label = "main", .title = "Main", .width = 320, .height = 200, .views = &.{.{ .label = "main-canvas", .kind = .gpu_surface, .fill = true, .gpu_backend = .metal }} }} },
        .canvas_label = "main-canvas",
        .view = Factory.view,
        .windows_fn = Factory.windows,
        .window_view = Factory.windowView,
    });
    defer app.destroy();
    try std.testing.expect(app.options.construction_policy == core.nativeWindowPolicy);
    try harness.start(app.app());
    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_frame = .{
        .label = "main-canvas",
        .size = .init(320, 200),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
    } });
    var buffer: [sdk.platform.max_windows]sdk.WindowInfo = undefined;
    var panel_id: sdk.WindowId = 0;
    for (harness.runtime.listWindows(&buffer)) |window| if (std.mem.eql(u8, window.label, "panel")) {
        panel_id = window.id;
    };
    try std.testing.expect(panel_id != 0);
    try harness.runtime.dispatchPlatformEvent(app.app(), .{ .gpu_surface_frame = .{
        .window_id = panel_id,
        .label = "panel-canvas",
        .size = .init(480, 360),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 2_000_000,
    } });
    try std.testing.expect(Factory.primary);
    try std.testing.expect(Factory.secondary);
    try harness.stop(app.app());
}
