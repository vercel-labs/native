const std = @import("std");
const geometry = @import("geometry");
const command_model = @import("commands.zig");
const drawing_model = @import("drawing.zig");
const text_model = @import("text.zig");

const CanvasCommand = command_model.CanvasCommand;
const Color = drawing_model.Color;
const Affine = drawing_model.Affine;
const Radius = drawing_model.Radius;
const GradientStop = drawing_model.GradientStop;
const LinearGradient = drawing_model.LinearGradient;
const Fill = drawing_model.Fill;
const Stroke = drawing_model.Stroke;
const Clip = drawing_model.Clip;
const FillRect = drawing_model.FillRect;
const StrokeRect = drawing_model.StrokeRect;
const FillRoundedRect = drawing_model.FillRoundedRect;
const Line = drawing_model.Line;
const PathElement = drawing_model.PathElement;
const FillPath = drawing_model.FillPath;
const StrokePath = drawing_model.StrokePath;
const DrawImage = drawing_model.DrawImage;
const Shadow = drawing_model.Shadow;
const Blur = drawing_model.Blur;
const Glyph = text_model.Glyph;
const DrawText = text_model.DrawText;
const TextLayoutOptions = text_model.TextLayoutOptions;
const TextSelection = text_model.TextSelection;
const TextRange = text_model.TextRange;

pub fn commandsEqual(a: CanvasCommand, b: CanvasCommand) bool {
    return switch (a) {
        .push_clip => |value| switch (b) {
            .push_clip => |other| clipsEqual(value, other),
            else => false,
        },
        .pop_clip => switch (b) {
            .pop_clip => true,
            else => false,
        },
        .push_opacity => |value| switch (b) {
            .push_opacity => |other| value == other,
            else => false,
        },
        .pop_opacity => switch (b) {
            .pop_opacity => true,
            else => false,
        },
        .transform => |value| switch (b) {
            .transform => |other| affinesEqual(value, other),
            else => false,
        },
        .fill_rect => |value| switch (b) {
            .fill_rect => |other| fillRectsEqual(value, other),
            else => false,
        },
        .stroke_rect => |value| switch (b) {
            .stroke_rect => |other| strokeRectsEqual(value, other),
            else => false,
        },
        .fill_rounded_rect => |value| switch (b) {
            .fill_rounded_rect => |other| fillRoundedRectsEqual(value, other),
            else => false,
        },
        .draw_line => |value| switch (b) {
            .draw_line => |other| linesEqual(value, other),
            else => false,
        },
        .fill_path => |value| switch (b) {
            .fill_path => |other| fillPathsEqual(value, other),
            else => false,
        },
        .stroke_path => |value| switch (b) {
            .stroke_path => |other| strokePathsEqual(value, other),
            else => false,
        },
        .draw_image => |value| switch (b) {
            .draw_image => |other| drawImagesEqual(value, other),
            else => false,
        },
        .draw_text => |value| switch (b) {
            .draw_text => |other| drawTextsEqual(value, other),
            else => false,
        },
        .shadow => |value| switch (b) {
            .shadow => |other| shadowsEqual(value, other),
            else => false,
        },
        .blur => |value| switch (b) {
            .blur => |other| blursEqual(value, other),
            else => false,
        },
    };
}

pub fn clipsEqual(a: Clip, b: Clip) bool {
    return a.id == b.id and rectsEqual(a.rect, b.rect) and radiiEqual(a.radius, b.radius);
}

pub fn fillRectsEqual(a: FillRect, b: FillRect) bool {
    return a.id == b.id and rectsEqual(a.rect, b.rect) and fillsEqual(a.fill, b.fill);
}

pub fn strokeRectsEqual(a: StrokeRect, b: StrokeRect) bool {
    return a.id == b.id and rectsEqual(a.rect, b.rect) and radiiEqual(a.radius, b.radius) and strokesEqual(a.stroke, b.stroke);
}

pub fn fillRoundedRectsEqual(a: FillRoundedRect, b: FillRoundedRect) bool {
    return a.id == b.id and rectsEqual(a.rect, b.rect) and radiiEqual(a.radius, b.radius) and fillsEqual(a.fill, b.fill);
}

pub fn linesEqual(a: Line, b: Line) bool {
    return a.id == b.id and pointsEqual(a.from, b.from) and pointsEqual(a.to, b.to) and strokesEqual(a.stroke, b.stroke);
}

pub fn fillPathsEqual(a: FillPath, b: FillPath) bool {
    return a.id == b.id and pathElementsEqual(a.elements, b.elements) and fillsEqual(a.fill, b.fill);
}

pub fn strokePathsEqual(a: StrokePath, b: StrokePath) bool {
    return a.id == b.id and a.cap == b.cap and pathElementsEqual(a.elements, b.elements) and strokesEqual(a.stroke, b.stroke);
}

pub fn drawImagesEqual(a: DrawImage, b: DrawImage) bool {
    return a.id == b.id and
        a.image_id == b.image_id and
        optionalRectsEqual(a.src, b.src) and
        rectsEqual(a.dst, b.dst) and
        a.opacity == b.opacity and
        a.fit == b.fit and
        a.sampling == b.sampling and
        radiiEqual(a.radius, b.radius);
}

pub fn drawTextsEqual(a: DrawText, b: DrawText) bool {
    return a.id == b.id and
        a.font_id == b.font_id and
        a.size == b.size and
        pointsEqual(a.origin, b.origin) and
        colorsEqual(a.color, b.color) and
        std.mem.eql(u8, a.text, b.text) and
        glyphsEqual(a.glyphs, b.glyphs) and
        optionalTextLayoutOptionsEqual(a.text_layout, b.text_layout);
}

pub fn optionalTextLayoutOptionsEqual(a: ?TextLayoutOptions, b: ?TextLayoutOptions) bool {
    if (a) |left| {
        if (b) |right| return textLayoutOptionsEqual(left, right);
        return false;
    }
    return b == null;
}

pub fn textLayoutOptionsEqual(a: TextLayoutOptions, b: TextLayoutOptions) bool {
    return nonNegative(a.max_width) == nonNegative(b.max_width) and
        nonNegative(a.line_height) == nonNegative(b.line_height) and
        a.wrap == b.wrap and
        a.alignment == b.alignment and
        a.overflow == b.overflow;
}

pub fn shadowsEqual(a: Shadow, b: Shadow) bool {
    return a.id == b.id and
        rectsEqual(a.rect, b.rect) and
        radiiEqual(a.radius, b.radius) and
        offsetsEqual(a.offset, b.offset) and
        a.blur == b.blur and
        a.spread == b.spread and
        colorsEqual(a.color, b.color);
}

pub fn blursEqual(a: Blur, b: Blur) bool {
    return a.id == b.id and rectsEqual(a.rect, b.rect) and a.radius == b.radius;
}

pub fn fillsEqual(a: Fill, b: Fill) bool {
    return switch (a) {
        .color => |value| switch (b) {
            .color => |other| colorsEqual(value, other),
            else => false,
        },
        .linear_gradient => |value| switch (b) {
            .linear_gradient => |other| linearGradientsEqual(value, other),
            else => false,
        },
    };
}

pub fn strokesEqual(a: Stroke, b: Stroke) bool {
    return a.width == b.width and fillsEqual(a.fill, b.fill);
}

pub fn linearGradientsEqual(a: LinearGradient, b: LinearGradient) bool {
    return pointsEqual(a.start, b.start) and pointsEqual(a.end, b.end) and gradientStopsEqual(a.stops, b.stops);
}

pub fn gradientStopsEqual(a: []const GradientStop, b: []const GradientStop) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.offset != right.offset or !colorsEqual(left.color, right.color)) return false;
    }
    return true;
}

pub fn pathElementsEqual(a: []const PathElement, b: []const PathElement) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.verb != right.verb) return false;
        if (!pointsEqual(left.points[0], right.points[0])) return false;
        if (!pointsEqual(left.points[1], right.points[1])) return false;
        if (!pointsEqual(left.points[2], right.points[2])) return false;
    }
    return true;
}

pub fn glyphsEqual(a: []const Glyph, b: []const Glyph) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.id != right.id or
            left.font_id != right.font_id or
            left.x != right.x or
            left.y != right.y or
            left.advance != right.advance or
            left.text_start != right.text_start or
            left.text_len != right.text_len) return false;
    }
    return true;
}

pub fn rectsEqual(a: geometry.RectF, b: geometry.RectF) bool {
    return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
}

pub fn optionalRectsEqual(a: ?geometry.RectF, b: ?geometry.RectF) bool {
    if (a) |left| {
        if (b) |right| return rectsEqual(left, right);
        return false;
    }
    return b == null;
}

pub fn sizesEqual(a: geometry.SizeF, b: geometry.SizeF) bool {
    return a.width == b.width and a.height == b.height;
}

pub fn optionalSizesEqual(a: ?geometry.SizeF, b: ?geometry.SizeF) bool {
    if (a) |left| {
        if (b) |right| return sizesEqual(left, right);
        return false;
    }
    return b == null;
}

pub fn insetsEqual(a: geometry.InsetsF, b: geometry.InsetsF) bool {
    return a.top == b.top and
        a.right == b.right and
        a.bottom == b.bottom and
        a.left == b.left;
}

pub fn pointsEqual(a: geometry.PointF, b: geometry.PointF) bool {
    return a.x == b.x and a.y == b.y;
}

pub fn offsetsEqual(a: geometry.OffsetF, b: geometry.OffsetF) bool {
    return a.dx == b.dx and a.dy == b.dy;
}

pub fn colorsEqual(a: Color, b: Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

pub fn optionalColorsEqual(a: ?Color, b: ?Color) bool {
    if (a) |left| {
        if (b) |right| return colorsEqual(left, right);
        return false;
    }
    return b == null;
}

pub fn radiiEqual(a: Radius, b: Radius) bool {
    return a.top_left == b.top_left and
        a.top_right == b.top_right and
        a.bottom_right == b.bottom_right and
        a.bottom_left == b.bottom_left;
}

pub fn affinesEqual(a: Affine, b: Affine) bool {
    return a.a == b.a and
        a.b == b.b and
        a.c == b.c and
        a.d == b.d and
        a.tx == b.tx and
        a.ty == b.ty;
}

pub fn optionalF32Equal(a: ?f32, b: ?f32) bool {
    if (a) |left| {
        if (b) |right| return left == right;
        return false;
    }
    return b == null;
}

pub fn optionalTextSelectionsEqual(a: ?TextSelection, b: ?TextSelection) bool {
    if (a) |left| {
        if (b) |right| return left.anchor == right.anchor and left.focus == right.focus;
        return false;
    }
    return b == null;
}

pub fn optionalTextRangesEqual(a: ?TextRange, b: ?TextRange) bool {
    if (a) |left| {
        if (b) |right| return left.start == right.start and left.end == right.end;
        return false;
    }
    return b == null;
}

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}
