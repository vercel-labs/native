//! The compiled core declares vector icons. Native validates their drawing
//! limits and owns stable storage for the process-wide icon registry.
const std = @import("std");
const canvas = @import("canvas");
const geometry = @import("geometry");

pub fn Icons(comptime core: type, comptime Model: type) type {
    return struct {
        pub const max_icons = 64;
        pub const max_name_bytes = 128;
        var names: [max_icons][max_name_bytes]u8 = undefined;
        var elements: [max_icons][canvas.svg_icon.max_icon_elements]canvas.PathElement = undefined;
        var shapes: [max_icons][canvas.svg_icon.max_icon_shapes]canvas.svg_icon.IconShape = undefined;
        var icons: [max_icons]canvas.svg_icon.Icon = undefined;
        var entries: [max_icons]canvas.icons.Entry = undefined;

        fn value(raw: anytype) if (@typeInfo(@TypeOf(raw)) == .pointer) @typeInfo(@TypeOf(raw)).pointer.child else @TypeOf(raw) {
            return if (comptime @typeInfo(@TypeOf(raw)) == .pointer) raw.* else raw;
        }
        fn number(raw: anytype) f64 {
            return if (comptime @typeInfo(@TypeOf(raw)) == .int) @floatFromInt(raw) else raw;
        }
        fn scalar(raw: anytype) !f32 {
            const n = number(raw);
            if (!std.math.isFinite(n) or @abs(n) > std.math.floatMax(f32)) return error.InvalidIconScalar;
            return @floatCast(n);
        }
        fn index(raw: anytype, bound: usize) !usize {
            const n = number(raw);
            if (!std.math.isFinite(n) or n < 0 or n > @as(f64, @floatFromInt(bound)) or @trunc(n) != n) return error.InvalidIconRange;
            return @intFromFloat(n);
        }
        fn point(raw_value: anytype) !geometry.PointF {
            const raw = value(raw_value);
            return .{ .x = try scalar(raw.x), .y = try scalar(raw.y) };
        }
        fn element(raw_value: anytype) !canvas.PathElement {
            const raw = value(raw_value);
            return .{
                .verb = std.meta.stringToEnum(canvas.PathVerb, @tagName(raw.verb)) orelse return error.InvalidIconVerb,
                .points = .{ try point(raw.first), try point(raw.second), try point(raw.third) },
            };
        }
        fn viewBox(raw_value: anytype) !geometry.RectF {
            const raw = value(raw_value);
            const rect: geometry.RectF = .{ .x = try scalar(raw.x), .y = try scalar(raw.y), .width = try scalar(raw.width), .height = try scalar(raw.height) };
            if (rect.width <= 0 or rect.height <= 0) return error.InvalidIconViewBox;
            return rect;
        }
        fn paint(raw_value: anytype) !canvas.svg_icon.Paint {
            return switch (value(raw_value)) {
                .none => .none,
                .current_color => .current_color,
                .color => |raw| blk: {
                    const c = value(raw);
                    const color: canvas.Color = .{ .r = try scalar(c.r), .g = try scalar(c.g), .b = try scalar(c.b), .a = try scalar(c.a) };
                    inline for (.{ "r", "g", "b", "a" }) |field| if (@field(color, field) < 0 or @field(color, field) > 1) return error.InvalidIconColor;
                    break :blk .{ .color = color };
                },
            };
        }
        fn shape(raw_value: anytype, element_count: usize) !canvas.svg_icon.IconShape {
            const raw = value(raw_value);
            const start = try index(raw.start, element_count);
            const count = try index(raw.count, element_count - start);
            const width = try scalar(raw.strokeWidth);
            if (width < 0) return error.InvalidIconStroke;
            return .{ .start = start, .len = count, .style = .{
                .fill = try paint(raw.fill), .stroke = try paint(raw.stroke), .stroke_width = width,
                .linecap = std.meta.stringToEnum(@FieldType(canvas.svg_icon.IconStyle, "linecap"), @tagName(raw.linecap)) orelse return error.InvalidIconLineCap,
                .linejoin = std.meta.stringToEnum(@FieldType(canvas.svg_icon.IconStyle, "linejoin"), @tagName(raw.linejoin)) orelse return error.InvalidIconLineJoin,
            } };
        }

        pub fn register(definitions: anytype) !void {
            if (definitions.len > max_icons) return error.IconLimit;
            // Check the complete batch before touching any registered data.
            // A refused install keeps the previous registry intact.
            for (definitions, 0..) |raw, ordinal| {
                const icon = value(raw);
                if (icon.name.len == 0 or icon.name.len > max_name_bytes) return error.InvalidIconName;
                for (definitions[0..ordinal]) |prior| if (std.mem.eql(u8, icon.name, value(prior).name)) return error.DuplicateIconName;
                if (icon.elements.len > canvas.svg_icon.max_icon_elements or icon.shapes.len > canvas.svg_icon.max_icon_shapes) return error.IconGeometryLimit;
                _ = try viewBox(icon.viewBox);
                for (icon.elements) |raw_element| _ = try element(raw_element);
                for (icon.shapes) |raw_shape| _ = try shape(raw_shape, icon.elements.len);
            }
            for (definitions, 0..) |raw, ordinal| {
                const icon = value(raw);
                @memcpy(names[ordinal][0..icon.name.len], icon.name);
                for (icon.elements, 0..) |raw_element, at| elements[ordinal][at] = try element(raw_element);
                for (icon.shapes, 0..) |raw_shape, at| shapes[ordinal][at] = try shape(raw_shape, icon.elements.len);
                icons[ordinal] = .{
                    .view_box = try viewBox(icon.viewBox),
                    .elements = elements[ordinal][0..icon.elements.len],
                    .shapes = shapes[ordinal][0..icon.shapes.len],
                };
                entries[ordinal] = .{ .name = names[ordinal][0..icon.name.len], .icon = &icons[ordinal] };
            }
            canvas.icons.registerAppIcons(entries[0..definitions.len]);
        }

        pub fn install(model: *const Model) !void {
            if (comptime @hasDecl(Model, "canvasIcons")) {
                const params = @typeInfo(@TypeOf(Model.canvasIcons)).@"fn".params;
                const definitions = if (comptime params.len == 1) model.canvasIcons() else model.canvasIcons(core.rt.frameAllocator());
                try register(definitions);
            }
        }
    };
}

const TestPoint = struct { x: f64 = 0, y: f64 = 0 };
const TestElement = struct {
    verb: canvas.PathVerb = .move_to,
    first: TestPoint = .{}, second: TestPoint = .{}, third: TestPoint = .{},
};
const TestColor = struct { r: f64 = 0, g: f64 = 0, b: f64 = 0, a: f64 = 1 };
const TestPaint = union(enum) { none, current_color, color: TestColor };
const TestShape = struct {
    start: f64 = 0, count: f64 = 1,
    fill: TestPaint = .none, stroke: TestPaint = .current_color, strokeWidth: f64 = 2,
    linecap: canvas.LineCap = .round, linejoin: @FieldType(canvas.svg_icon.IconStyle, "linejoin") = .round,
};
const TestRect = struct { x: f64 = 0, y: f64 = 0, width: f64 = 24, height: f64 = 24 };
const TestIcon = struct {
    name: []const u8 = "test", viewBox: TestRect = .{},
    elements: []const TestElement, shapes: []const TestShape,
};

test "canvas icon registry owns complete names vector slots paints and shape ranges" {
    const Registry = Icons(struct {}, struct {});
    const previous = canvas.icons.appIcons();
    defer canvas.icons.registerAppIcons(previous);
    var name = [_]u8{ 0xff, 0, 'x' };
    var raw_elements = [_]TestElement{.{ .verb = .cubic_to, .first = .{ .x = 1.25, .y = 2.5 }, .second = .{ .x = 3.75, .y = 4 }, .third = .{ .x = 5.25, .y = 6.5 } }};
    var raw_shapes = [_]TestShape{.{ .fill = .{ .color = .{ .r = 0.125, .g = 0.25, .b = 0.5, .a = 0.75 } } }};
    const definitions = [_]TestIcon{.{ .name = &name, .elements = &raw_elements, .shapes = &raw_shapes }};
    try Registry.register(&definitions);
    @memset(&name, 99);
    raw_elements[0] = .{};
    raw_shapes[0] = .{};
    const registered = canvas.icons.appIcons();
    try std.testing.expectEqual(@as(usize, 1), registered.len);
    try std.testing.expectEqualStrings("\xff\x00x", registered[0].name);
    try std.testing.expectEqualDeep(geometry.RectF.init(0, 0, 24, 24), registered[0].icon.view_box);
    try std.testing.expectEqualDeep(canvas.PathElement{ .verb = .cubic_to, .points = .{ .init(1.25, 2.5), .init(3.75, 4), .init(5.25, 6.5) } }, registered[0].icon.elements[0]);
    try std.testing.expectEqualDeep(canvas.svg_icon.IconShape{ .start = 0, .len = 1, .style = .{
        .fill = .{ .color = .rgba(0.125, 0.25, 0.5, 0.75) }, .stroke = .current_color,
        .stroke_width = 2, .linecap = .round, .linejoin = .round,
    } }, registered[0].icon.shapes[0]);
}

test "canvas icon registry refuses invalid complete batches without changing registered data" {
    const Registry = Icons(struct {}, struct {});
    const previous = canvas.icons.appIcons();
    defer canvas.icons.registerAppIcons(previous);
    var raw_elements = [_]TestElement{ .{} };
    var raw_shapes = [_]TestShape{ .{} };
    var definitions = [_]TestIcon{.{ .elements = &raw_elements, .shapes = &raw_shapes }};
    try Registry.register(&definitions);
    const expected_element = canvas.icons.appIcons()[0].icon.elements[0];
    const expected_shape = canvas.icons.appIcons()[0].icon.shapes[0];
    inline for (.{ "start", "count" }) |field| for ([_]f64{ -1, 0.5, 2, std.math.nan(f64), std.math.inf(f64), 9_007_199_254_740_992 }) |bad| {
        raw_shapes[0] = .{};
        @field(raw_shapes[0], field) = bad;
        try std.testing.expectError(error.InvalidIconRange, Registry.register(&definitions));
        try std.testing.expectEqualDeep(expected_element, canvas.icons.appIcons()[0].icon.elements[0]);
        try std.testing.expectEqualDeep(expected_shape, canvas.icons.appIcons()[0].icon.shapes[0]);
    };
    raw_shapes[0] = .{};
    inline for (.{ "first", "second", "third" }) |slot| inline for (.{ "x", "y" }) |coordinate| for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), 3.5e38 }) |bad| {
        raw_elements[0] = .{};
        @field(@field(raw_elements[0], slot), coordinate) = bad;
        try std.testing.expectError(error.InvalidIconScalar, Registry.register(&definitions));
        try std.testing.expectEqualDeep(expected_element, canvas.icons.appIcons()[0].icon.elements[0]);
    };
    raw_elements[0] = .{};
    definitions[0].name = "";
    try std.testing.expectError(error.InvalidIconName, Registry.register(&definitions));
    const long_name = [_]u8{'x'} ** (Registry.max_name_bytes + 1);
    definitions[0].name = &long_name;
    try std.testing.expectError(error.InvalidIconName, Registry.register(&definitions));
    definitions[0].name = "test";
    const duplicate = [_]TestIcon{ definitions[0], definitions[0] };
    try std.testing.expectError(error.DuplicateIconName, Registry.register(&duplicate));
    for ([_]f64{ 0, -1 }) |bad| {
        definitions[0].viewBox.width = bad;
        try std.testing.expectError(error.InvalidIconViewBox, Registry.register(&definitions));
    }
    definitions[0].viewBox.width = 24;
    raw_shapes[0].strokeWidth = -1;
    try std.testing.expectError(error.InvalidIconStroke, Registry.register(&definitions));
    raw_shapes[0].strokeWidth = 2;
    inline for (.{ "r", "g", "b", "a" }) |field| for ([_]f64{ -0.25, 1.25 }) |bad| {
        var c: TestColor = .{}; @field(c, field) = bad;
        raw_shapes[0].fill = .{ .color = c };
        try std.testing.expectError(error.InvalidIconColor, Registry.register(&definitions));
    };
    try std.testing.expectEqual(@as(usize, 1), canvas.icons.appIcons().len);
    try std.testing.expectEqualStrings("test", canvas.icons.appIcons()[0].name);
    try std.testing.expectEqualDeep(expected_element, canvas.icons.appIcons()[0].icon.elements[0]);
    try std.testing.expectEqualDeep(expected_shape, canvas.icons.appIcons()[0].icon.shapes[0]);
}

test "canvas icon registry preserves exact capacity limits and empty replacement" {
    const Registry = Icons(struct {}, struct {});
    const previous = canvas.icons.appIcons();
    defer canvas.icons.registerAppIcons(previous);
    const raw_elements = [_]TestElement{ .{} } ** (canvas.svg_icon.max_icon_elements + 1);
    const raw_shapes = [_]TestShape{ .{ .start = 512, .count = 0 } } ** (canvas.svg_icon.max_icon_shapes + 1);
    var names: [Registry.max_icons + 1][Registry.max_name_bytes]u8 = undefined;
    var definitions: [Registry.max_icons + 1]TestIcon = undefined;
    for (&definitions, 0..) |*definition, ordinal| {
        @memset(&names[ordinal], @intCast(ordinal + 1));
        definition.* = .{ .name = &names[ordinal], .elements = raw_elements[0..canvas.svg_icon.max_icon_elements], .shapes = raw_shapes[0..canvas.svg_icon.max_icon_shapes] };
    }
    try Registry.register(definitions[0..Registry.max_icons]);
    try std.testing.expectEqual(@as(usize, Registry.max_icons), canvas.icons.appIcons().len);
    for (canvas.icons.appIcons(), 0..) |entry, ordinal| {
        try std.testing.expectEqualSlices(u8, &names[ordinal], entry.name);
        try std.testing.expectEqual(@as(usize, 512), entry.icon.elements.len);
        try std.testing.expectEqual(@as(usize, 48), entry.icon.shapes.len);
        for (entry.icon.shapes) |registered| { try std.testing.expectEqual(@as(usize, 512), registered.start); try std.testing.expectEqual(@as(usize, 0), registered.len); }
    }
    try std.testing.expectError(error.IconLimit, Registry.register(&definitions));
    definitions[0].elements = &raw_elements;
    try std.testing.expectError(error.IconGeometryLimit, Registry.register(definitions[0..1]));
    definitions[0].elements = raw_elements[0..512]; definitions[0].shapes = &raw_shapes;
    try std.testing.expectError(error.IconGeometryLimit, Registry.register(definitions[0..1]));
    try std.testing.expectEqual(@as(usize, Registry.max_icons), canvas.icons.appIcons().len);
    try Registry.register(definitions[0..0]);
    try std.testing.expectEqual(@as(usize, 0), canvas.icons.appIcons().len);
}
