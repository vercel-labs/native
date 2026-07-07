//! Tests for the SVG icon-subset parser (`svg_icon.zig`) and the
//! built-in icon registry (`icons.zig`): tag scanning, shape lowering,
//! style inheritance, the full path-data grammar, budgets, and a
//! stroke-dialect file rasterized through the vector core with pixel
//! goldens in the reference conventions.

const std = @import("std");
const geometry = @import("geometry");
const svg_icon = @import("svg_icon.zig");
const icons = @import("icons.zig");
const vector = @import("vector.zig");
const drawing = @import("drawing.zig");

const PointF = geometry.PointF;
const Affine = drawing.Affine;

const stroke_dialect_header =
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\" viewBox=\"0 0 24 24\" " ++
    "fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\">";

test "parses the stroke dialect header and inherits the root style" {
    var buffer = svg_icon.IconBuffer{};
    const icon = try svg_icon.parse(
        stroke_dialect_header ++ "<circle cx=\"11\" cy=\"11\" r=\"7\"/><line x1=\"16\" y1=\"16\" x2=\"21\" y2=\"21\"/></svg>",
        &buffer,
    );
    try std.testing.expectEqual(@as(f32, 24), icon.view_box.width);
    try std.testing.expectEqual(@as(f32, 24), icon.view_box.height);
    try std.testing.expectEqual(@as(usize, 2), icon.shapes.len);
    for (icon.shapes) |shape| {
        try std.testing.expectEqual(svg_icon.Paint.none, shape.style.fill);
        try std.testing.expectEqual(svg_icon.Paint.current_color, shape.style.stroke);
        try std.testing.expectEqual(@as(f32, 2), shape.style.stroke_width);
        try std.testing.expectEqual(vector.LineCap.round, shape.style.linecap);
        try std.testing.expectEqual(vector.LineJoin.round, shape.style.linejoin);
    }
}

test "element attributes override inherited style and hex colors parse" {
    var buffer = svg_icon.IconBuffer{};
    const icon = try svg_icon.parse(
        stroke_dialect_header ++
            "<rect x=\"4\" y=\"4\" width=\"16\" height=\"16\" fill=\"#3fA\" stroke=\"none\"/>" ++
            "<g stroke=\"#102030\" stroke-width=\"1.5\"><line x1=\"4\" y1=\"12\" x2=\"20\" y2=\"12\"/></g></svg>",
        &buffer,
    );
    try std.testing.expectEqual(@as(usize, 2), icon.shapes.len);
    const rect_fill = icon.shapes[0].style.fill.color;
    try std.testing.expectEqual(@as(f32, 0x33), @round(rect_fill.r * 255));
    try std.testing.expectEqual(@as(f32, 0xFF), @round(rect_fill.g * 255));
    try std.testing.expectEqual(@as(f32, 0xAA), @round(rect_fill.b * 255));
    try std.testing.expectEqual(svg_icon.Paint.none, icon.shapes[0].style.stroke);
    const line_stroke = icon.shapes[1].style.stroke.color;
    try std.testing.expectEqual(@as(f32, 0x10), @round(line_stroke.r * 255));
    try std.testing.expectEqual(@as(f32, 1.5), icon.shapes[1].style.stroke_width);
}

test "comments, xml prologs, and unknown elements are skipped" {
    var buffer = svg_icon.IconBuffer{};
    const icon = try svg_icon.parse(
        "<?xml version=\"1.0\"?><!-- a comment --><svg viewBox=\"0 0 10 10\" stroke=\"currentColor\">" ++
            "<title>ignored</title><desc>also ignored</desc><line x1=\"0\" y1=\"0\" x2=\"10\" y2=\"10\"/></svg>",
        &buffer,
    );
    try std.testing.expectEqual(@as(usize, 1), icon.shapes.len);
}

test "shapes lower to the expected verbs" {
    var buffer = svg_icon.IconBuffer{};
    const icon = try svg_icon.parse(
        "<svg viewBox=\"0 0 24 24\" stroke=\"currentColor\">" ++
            "<polyline points=\"5 13, 10 18, 19 7\"/>" ++
            "<polygon points=\"8 5 19 12 8 19\"/>" ++
            "<rect x=\"2\" y=\"2\" width=\"8\" height=\"6\" rx=\"2\"/>" ++
            "<ellipse cx=\"12\" cy=\"12\" rx=\"6\" ry=\"3\"/></svg>",
        &buffer,
    );
    try std.testing.expectEqual(@as(usize, 4), icon.shapes.len);
    // Polyline: move + 2 lines, open.
    const polyline = icon.elements[icon.shapes[0].start .. icon.shapes[0].start + icon.shapes[0].len];
    try std.testing.expectEqual(@as(usize, 3), polyline.len);
    try std.testing.expectEqual(drawing.PathVerb.move_to, polyline[0].verb);
    try std.testing.expectEqual(drawing.PathVerb.line_to, polyline[2].verb);
    // Polygon closes.
    const polygon = icon.elements[icon.shapes[1].start .. icon.shapes[1].start + icon.shapes[1].len];
    try std.testing.expectEqual(drawing.PathVerb.close, polygon[polygon.len - 1].verb);
    // Rounded rect: 4 lines + 4 corner cubics + close after the move.
    const rect = icon.elements[icon.shapes[2].start .. icon.shapes[2].start + icon.shapes[2].len];
    try std.testing.expectEqual(@as(usize, 10), rect.len);
    // Ellipse: move + 4 cubics + close.
    const ellipse = icon.elements[icon.shapes[3].start .. icon.shapes[3].start + icon.shapes[3].len];
    try std.testing.expectEqual(@as(usize, 6), ellipse.len);
    try std.testing.expectEqual(drawing.PathVerb.cubic_to, ellipse[1].verb);
}

test "path data grammar covers every command form" {
    var buffer = svg_icon.IconBuffer{};
    // Absolute/relative, H/V, S/T reflection, arcs with glued flags,
    // implicit repetition after M, negative shorthand numbers.
    const icon = try svg_icon.parse(
        "<svg viewBox=\"0 0 24 24\" stroke=\"currentColor\">" ++
            "<path d=\"M2 2 4 2 L6 2 h2 v2 H6 V2 c1 0 2 1 2 2 s1 2 2 2 " ++
            "Q14 8 14 10 T16 12 a2 2 0 01.6.3 A3 3 0 1 0 20 18 l-1-1 Z\"/></svg>",
        &buffer,
    );
    try std.testing.expectEqual(@as(usize, 1), icon.shapes.len);
    const elements = icon.elements[icon.shapes[0].start .. icon.shapes[0].start + icon.shapes[0].len];
    try std.testing.expect(elements.len > 10);
    try std.testing.expectEqual(drawing.PathVerb.close, elements[elements.len - 1].verb);
    var has_cubic = false;
    var has_quad = false;
    for (elements) |element| {
        if (element.verb == .cubic_to) has_cubic = true;
        if (element.verb == .quad_to) has_quad = true;
    }
    try std.testing.expect(has_cubic); // C/S and lowered arcs
    try std.testing.expect(has_quad); // Q/T
}

test "malformed sources fail loudly" {
    var buffer = svg_icon.IconBuffer{};
    // No <svg>.
    try std.testing.expectError(error.SvgParseFailed, svg_icon.parse("<circle r=\"5\"/>", &buffer));
    // No viewBox.
    try std.testing.expectError(error.SvgParseFailed, svg_icon.parse("<svg><line x1=\"0\" y1=\"0\" x2=\"1\" y2=\"1\"/></svg>", &buffer));
    // Unsupported paint keyword.
    try std.testing.expectError(error.SvgParseFailed, svg_icon.parse("<svg viewBox=\"0 0 1 1\" stroke=\"url(#grad)\"><line x1=\"0\" y1=\"0\" x2=\"1\" y2=\"1\"/></svg>", &buffer));
    // Broken path number.
    try std.testing.expectError(error.SvgParseFailed, svg_icon.parse("<svg viewBox=\"0 0 1 1\" stroke=\"currentColor\"><path d=\"M x\"/></svg>", &buffer));
    // Numbers trailing a close.
    try std.testing.expectError(error.SvgParseFailed, svg_icon.parse("<svg viewBox=\"0 0 1 1\" stroke=\"currentColor\"><path d=\"M0 0 L1 1 Z 5 5\"/></svg>", &buffer));
}

test "shape budget overflow is a deterministic error" {
    var source: [8192]u8 = undefined;
    var stream = std.Io.Writer.fixed(&source);
    stream.writeAll("<svg viewBox=\"0 0 24 24\" stroke=\"currentColor\">") catch unreachable;
    var index: usize = 0;
    while (index < svg_icon.max_icon_shapes + 1) : (index += 1) {
        stream.print("<line x1=\"0\" y1=\"{d}\" x2=\"24\" y2=\"{d}\"/>", .{ index, index }) catch unreachable;
    }
    stream.writeAll("</svg>") catch unreachable;
    var buffer = svg_icon.IconBuffer{};
    try std.testing.expectError(error.SvgTooComplex, svg_icon.parse(stream.buffered(), &buffer));
}

// ---------------------------------------------------------------------------
// Built-in registry
// ---------------------------------------------------------------------------

test "registry entries and known names stay in lockstep" {
    try std.testing.expectEqual(icons.entries.len, icons.known_icon_names.len);
    for (&icons.entries, icons.known_icon_names) |*entry, name| {
        try std.testing.expectEqualStrings(entry.name, name);
        try std.testing.expectEqual(entry.icon, icons.find(name).?);
    }
    try std.testing.expectEqual(@as(?*const icons.Icon, null), icons.find("not-an-icon"));
    // Deliberate size bound: the curated set is 49 after the pane and
    // tool-identity round (panel-left/panel-right for sidebar toggles,
    // terminal/wrench for agent-transcript tool calls; before that, 45
    // when the anchored-floating-surface round completed the GitHub
    // vocabulary). Growing it is fine — raise the bound consciously and
    // update the docs/skill name lists (the mirror-list lockstep test
    // catches the validator; prose lists are on you).
    try std.testing.expect(icons.entries.len >= 45);
    try std.testing.expect(icons.entries.len <= 52);
}

test "app icon registration resolves for drawing but never widens the closed vocabulary" {
    var buffer = svg_icon.IconBuffer{};
    const parsed = try svg_icon.parse(
        "<svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"><line x1=\"4\" y1=\"12\" x2=\"20\" y2=\"12\"/></svg>",
        &buffer,
    );
    const app_table = [_]icons.Entry{.{ .name = "app-rule", .icon = &parsed }};
    icons.registerAppIcons(&app_table);
    defer icons.registerAppIcons(&.{});
    // Draw-path resolution sees the app icon; the comptime-safe `find`
    // (markup validation, Ui.icon) does not.
    try std.testing.expectEqual(@as(?*const icons.Icon, &parsed), icons.resolve("app-rule"));
    try std.testing.expectEqual(@as(?*const icons.Icon, null), icons.find("app-rule"));
    // Built-ins win on collision, and resolution falls through to them.
    const shadowing = [_]icons.Entry{.{ .name = "check", .icon = &parsed }};
    icons.registerAppIcons(&shadowing);
    try std.testing.expectEqual(icons.find("check").?, icons.resolve("check").?);
    // The app: namespace reaches ONLY the registered table: a shadowed
    // name resolves to the app icon through it, and a built-in name is
    // never an answer for an app: reference.
    try std.testing.expectEqual(@as(?*const icons.Icon, &parsed), icons.resolve("app:check"));
    try std.testing.expectEqual(@as(?*const icons.Icon, null), icons.resolve("app:search"));
}

test "the explicit icon channel resolves unknown names to the missing-icon fallback" {
    // Empty means "no icon"; a name that resolves nowhere yields the
    // fallback glyph so a broken reference draws its failure, never a
    // silent gap (the paired Debug warning names the value).
    try std.testing.expectEqual(@as(?*const icons.Icon, null), icons.resolveOrMissing(""));
    try std.testing.expectEqual(@as(?*const icons.Icon, icons.missing_icon), icons.resolveOrMissing("sparkle-pony"));
    try std.testing.expectEqual(@as(?*const icons.Icon, icons.missing_icon), icons.resolveOrMissing("app:sparkle-pony"));
    try std.testing.expectEqual(@as(?*const icons.Icon, icons.find("search").?), icons.resolveOrMissing("search"));
    // The fallback is deliberately NOT vocabulary: no name reaches it.
    for (icons.known_icon_names) |name| {
        try std.testing.expect(icons.find(name).? != icons.missing_icon);
    }
}

test "every built-in icon is a 24x24 stroke-dialect icon" {
    for (&icons.entries) |*entry| {
        const icon = entry.icon;
        try std.testing.expectEqual(@as(f32, 24), icon.view_box.width);
        try std.testing.expectEqual(@as(f32, 24), icon.view_box.height);
        try std.testing.expect(icon.shapes.len > 0);
        try std.testing.expect(icon.elements.len > 0);
        for (icon.shapes) |shape| {
            try std.testing.expect(shape.len > 0);
            try std.testing.expect(shape.start + shape.len <= icon.elements.len);
            // The curated set strokes in currentColor only: fully
            // token-tintable, no baked-in colors.
            try std.testing.expectEqual(svg_icon.Paint.current_color, shape.style.stroke);
            try std.testing.expectEqual(svg_icon.Paint.none, shape.style.fill);
            try std.testing.expectEqual(@as(f32, 2), shape.style.stroke_width);
        }
    }
}

// ---------------------------------------------------------------------------
// Rasterization goldens
// ---------------------------------------------------------------------------

const grid_size: usize = 24;

const Grid = struct {
    data: [grid_size * grid_size]u8 = [_]u8{0} ** (grid_size * grid_size),

    pub fn pixel(self: *Grid, x: i32, y: i32, coverage: f32) void {
        if (x < 0 or y < 0) return;
        const px: usize = @intCast(x);
        const py: usize = @intCast(y);
        if (px >= grid_size or py >= grid_size) return;
        self.data[py * grid_size + px] = @intFromFloat(@round(std.math.clamp(coverage, 0, 1) * 255));
    }

    fn signature(self: *const Grid) u64 {
        var hash: u64 = 14695981039346656037;
        for (self.data) |byte| {
            hash = (hash ^ byte) *% 1099511628211;
        }
        return hash;
    }

    fn inkCount(self: *const Grid) usize {
        var count: usize = 0;
        for (self.data) |byte| {
            if (byte > 0) count += 1;
        }
        return count;
    }
};

fn rasterizeIcon(icon: *const icons.Icon, grid: *Grid) !void {
    const clip = vector.ClipRect{ .x0 = 0, .y0 = 0, .x1 = @intCast(grid_size), .y1 = @intCast(grid_size) };
    for (icon.shapes) |shape| {
        const elements = icon.elements[shape.start .. shape.start + shape.len];
        if (shape.style.stroke != .none and shape.style.stroke_width > 0) {
            try vector.strokePath(elements, Affine.identity(), .{
                .width = shape.style.stroke_width,
                .cap = shape.style.linecap,
                .join = shape.style.linejoin,
            }, vector.default_tolerance, clip, grid);
        }
        if (shape.style.fill != .none) {
            try vector.fillPath(elements, Affine.identity(), .nonzero, vector.default_tolerance, clip, grid);
        }
    }
}

test "the check icon rasterizes deterministically and is pinned" {
    var grid = Grid{};
    try rasterizeIcon(icons.find("check").?, &grid);
    try std.testing.expect(grid.inkCount() > 20);
    var second = Grid{};
    try rasterizeIcon(icons.find("check").?, &second);
    try std.testing.expectEqualSlices(u8, &grid.data, &second.data);
    try std.testing.expectEqual(@as(u64, 9706765741162478182), grid.signature());
}

test "a real stroke-dialect file rasterizes through the same pipeline" {
    // The exact attribute/element shape of a stock `circle-x`-style
    // icon (geometry authored here): root-level presentation attributes,
    // self-closing shape tags, arc-free and arc-bearing paths both.
    var buffer = svg_icon.IconBuffer{};
    const icon = try svg_icon.parse(
        stroke_dialect_header ++
            "<circle cx=\"12\" cy=\"12\" r=\"10\"/>" ++
            "<path d=\"m15 9-6 6\"/><path d=\"m9 9 6 6\"/></svg>",
        &buffer,
    );
    try std.testing.expectEqual(@as(usize, 3), icon.shapes.len);
    var grid = Grid{};
    const clip = vector.ClipRect{ .x0 = 0, .y0 = 0, .x1 = @intCast(grid_size), .y1 = @intCast(grid_size) };
    for (icon.shapes) |shape| {
        try vector.strokePath(
            icon.elements[shape.start .. shape.start + shape.len],
            Affine.identity(),
            .{ .width = shape.style.stroke_width, .cap = shape.style.linecap, .join = shape.style.linejoin },
            vector.default_tolerance,
            clip,
            &grid,
        );
    }
    try std.testing.expect(grid.inkCount() > 60);
}
