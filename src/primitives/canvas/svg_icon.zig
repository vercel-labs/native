//! SVG icon-subset parser: exactly the closed dialect the popular open
//! 24x24 stroke-icon sets are written in, parseable
//! at comptime (`parseComptime`) or runtime (`parse` into caller
//! buffers), std-only and allocation-free.
//!
//! Supported: `<svg viewBox>`, `<g>` (style inheritance), `<path d>`,
//! `<circle>`, `<ellipse>`, `<rect>` (with `rx`/`ry`), `<line>`,
//! `<polyline>`, `<polygon>`; presentation attributes `fill`, `stroke`,
//! `stroke-width`, `stroke-linecap`, `stroke-linejoin` with
//! `currentColor` and `#rgb`/`#rrggbb` literals. Path data supports the
//! full command set (M L H V C S Q T A Z, absolute and relative, with
//! implicit repetition).
//!
//! Explicitly NOT SVG: no CSS, no `style=""`, no gradients, no filters,
//! no text, no animation, no transforms, no `use`. Unknown elements
//! (`<title>`, `<desc>`, metadata) are skipped; unknown attributes are
//! ignored — a stock icon-set file drops in unchanged.
//!
//! Shapes are lowered to the wire path model (`drawing.PathElement`) via
//! `vector.PathBuilder`, so an icon is just ranges of packet-compatible
//! path elements plus per-shape paint style: the reference renderer
//! rasterizes them through the vector core and AppKit draws the same
//! commands natively.

const std = @import("std");
const geometry = @import("geometry");
const drawing_model = @import("drawing.zig");
const vector = @import("vector.zig");

const PointF = geometry.PointF;
const PathElement = drawing_model.PathElement;
const Color = drawing_model.Color;

pub const Error = error{
    /// Structurally invalid markup, an unsupported paint, or malformed
    /// numbers/path data.
    SvgParseFailed,
    /// The icon exceeds the fixed shape/element budgets.
    SvgTooComplex,
} || vector.Error;

pub const max_icon_shapes: usize = 48;
pub const max_icon_elements: usize = 512;
const max_group_depth: usize = 8;

/// How a shape region is painted. The closed set keeps icons themeable:
/// `current_color` resolves to the widget's foreground color token at
/// draw time (the SVG `currentColor` keyword); literal hex colors pass
/// through for the rare multi-color icon.
pub const Paint = union(enum) {
    none,
    current_color,
    color: Color,
};

pub const IconStyle = struct {
    fill: Paint = .{ .color = Color.rgb8(0, 0, 0) }, // SVG default fill is black.
    stroke: Paint = .none,
    stroke_width: f32 = 1,
    linecap: vector.LineCap = .butt,
    linejoin: vector.LineJoin = .miter,
};

/// One paintable region: a range of path elements plus its style.
pub const IconShape = struct {
    style: IconStyle = .{},
    start: usize = 0,
    len: usize = 0,
};

/// A parsed icon referencing caller- (or comptime-) owned storage.
pub const Icon = struct {
    view_box: geometry.RectF,
    elements: []const PathElement,
    shapes: []const IconShape,
};

/// Fixed-capacity runtime parse storage.
pub const IconBuffer = struct {
    elements: vector.PathBuilder(max_icon_elements) = .{},
    shapes: [max_icon_shapes]IconShape = undefined,
    shape_count: usize = 0,
};

/// Parse at comptime into static storage: the returned icon's slices
/// point at comptime-materialized arrays, so it can back a `pub const`
/// registry with zero runtime work. Malformed sources are compile
/// errors.
pub fn parseComptime(comptime source: []const u8) Icon {
    comptime {
        @setEvalBranchQuota(2_000_000);
        var buffer = IconBuffer{};
        const parsed = parse(source, &buffer) catch |err|
            @compileError("invalid icon svg: " ++ @errorName(err));
        var elements: [parsed.elements.len]PathElement = undefined;
        @memcpy(&elements, parsed.elements);
        var shapes: [parsed.shapes.len]IconShape = undefined;
        @memcpy(&shapes, parsed.shapes);
        const const_elements = elements;
        const const_shapes = shapes;
        return .{
            .view_box = parsed.view_box,
            .elements = &const_elements,
            .shapes = &const_shapes,
        };
    }
}

/// Parse SVG text into `buffer`, returning an icon view over it.
pub fn parse(source: []const u8, buffer: *IconBuffer) Error!Icon {
    buffer.elements.reset();
    buffer.shape_count = 0;

    var view_box: ?geometry.RectF = null;
    var style_stack: [max_group_depth]IconStyle = undefined;
    var depth: usize = 0;
    style_stack[0] = .{};
    var saw_svg = false;

    var cursor: usize = 0;
    while (nextTag(source, &cursor)) |tag| {
        if (tag.closing) {
            if (std.mem.eql(u8, tag.name, "g") and depth > 0) depth -= 1;
            continue;
        }
        if (std.mem.eql(u8, tag.name, "svg")) {
            saw_svg = true;
            style_stack[0] = try applyStyleAttrs(tag.attrs, IconStyle{});
            if (findAttr(tag.attrs, "viewBox")) |value| {
                view_box = try parseViewBox(value);
            }
            continue;
        }
        if (!saw_svg) continue;
        if (std.mem.eql(u8, tag.name, "g")) {
            if (!tag.self_closing) {
                if (depth + 1 >= max_group_depth) return error.SvgTooComplex;
                style_stack[depth + 1] = try applyStyleAttrs(tag.attrs, style_stack[depth]);
                depth += 1;
            }
            continue;
        }

        const style = try applyStyleAttrs(tag.attrs, style_stack[depth]);
        const start = buffer.elements.len;
        if (std.mem.eql(u8, tag.name, "path")) {
            const data = findAttr(tag.attrs, "d") orelse return error.SvgParseFailed;
            try parsePathData(data, &buffer.elements);
        } else if (std.mem.eql(u8, tag.name, "circle")) {
            const cx = try attrFloat(tag.attrs, "cx", 0);
            const cy = try attrFloat(tag.attrs, "cy", 0);
            const r = try attrFloat(tag.attrs, "r", 0);
            if (r > 0) try buffer.elements.circle(PointF.init(cx, cy), r);
        } else if (std.mem.eql(u8, tag.name, "ellipse")) {
            const cx = try attrFloat(tag.attrs, "cx", 0);
            const cy = try attrFloat(tag.attrs, "cy", 0);
            const rx = try attrFloat(tag.attrs, "rx", 0);
            const ry = try attrFloat(tag.attrs, "ry", 0);
            if (rx > 0 and ry > 0) try appendEllipse(&buffer.elements, cx, cy, rx, ry);
        } else if (std.mem.eql(u8, tag.name, "rect")) {
            const x = try attrFloat(tag.attrs, "x", 0);
            const y = try attrFloat(tag.attrs, "y", 0);
            const width = try attrFloat(tag.attrs, "width", 0);
            const height = try attrFloat(tag.attrs, "height", 0);
            var rx = try attrFloat(tag.attrs, "rx", -1);
            var ry = try attrFloat(tag.attrs, "ry", -1);
            if (rx < 0 and ry < 0) {
                rx = 0;
                ry = 0;
            } else if (rx < 0) {
                rx = ry;
            } else if (ry < 0) {
                ry = rx;
            }
            if (width > 0 and height > 0) try appendRect(&buffer.elements, x, y, width, height, rx, ry);
        } else if (std.mem.eql(u8, tag.name, "line")) {
            const x1 = try attrFloat(tag.attrs, "x1", 0);
            const y1 = try attrFloat(tag.attrs, "y1", 0);
            const x2 = try attrFloat(tag.attrs, "x2", 0);
            const y2 = try attrFloat(tag.attrs, "y2", 0);
            try buffer.elements.moveTo(PointF.init(x1, y1));
            try buffer.elements.lineTo(PointF.init(x2, y2));
        } else if (std.mem.eql(u8, tag.name, "polyline") or std.mem.eql(u8, tag.name, "polygon")) {
            const points = findAttr(tag.attrs, "points") orelse return error.SvgParseFailed;
            try appendPolyline(&buffer.elements, points, std.mem.eql(u8, tag.name, "polygon"));
        } else {
            // <title>, <desc>, <defs> contents, metadata: skipped.
            continue;
        }

        const len = buffer.elements.len - start;
        if (len == 0) continue;
        if (style.fill == .none and style.stroke == .none) continue;
        if (buffer.shape_count >= max_icon_shapes) return error.SvgTooComplex;
        buffer.shapes[buffer.shape_count] = .{ .style = style, .start = start, .len = len };
        buffer.shape_count += 1;
    }

    if (!saw_svg) return error.SvgParseFailed;
    return .{
        .view_box = view_box orelse return error.SvgParseFailed,
        .elements = buffer.elements.slice(),
        .shapes = buffer.shapes[0..buffer.shape_count],
    };
}

// ------------------------------------------------------------------ tags

const Tag = struct {
    name: []const u8,
    attrs: []const u8,
    closing: bool,
    self_closing: bool,
};

/// Scan to the next element tag, skipping comments, doctypes, and
/// processing instructions.
fn nextTag(source: []const u8, cursor: *usize) ?Tag {
    var index = cursor.*;
    while (index < source.len) {
        const open = std.mem.indexOfScalarPos(u8, source, index, '<') orelse {
            cursor.* = source.len;
            return null;
        };
        if (std.mem.startsWith(u8, source[open..], "<!--")) {
            const end = std.mem.indexOfPos(u8, source, open + 4, "-->") orelse {
                cursor.* = source.len;
                return null;
            };
            index = end + 3;
            continue;
        }
        if (open + 1 < source.len and (source[open + 1] == '?' or source[open + 1] == '!')) {
            const end = std.mem.indexOfScalarPos(u8, source, open + 1, '>') orelse {
                cursor.* = source.len;
                return null;
            };
            index = end + 1;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, source, open + 1, '>') orelse {
            cursor.* = source.len;
            return null;
        };
        var inner: []const u8 = source[open + 1 .. end];
        var closing = false;
        var self_closing = false;
        if (inner.len > 0 and inner[0] == '/') {
            closing = true;
            inner = inner[1..];
        }
        if (inner.len > 0 and inner[inner.len - 1] == '/') {
            self_closing = true;
            inner = inner[0 .. inner.len - 1];
        }
        var name_end: usize = 0;
        while (name_end < inner.len and !isXmlSpace(inner[name_end])) name_end += 1;
        cursor.* = end + 1;
        return .{
            .name = inner[0..name_end],
            .attrs = if (name_end < inner.len) inner[name_end..] else "",
            .closing = closing,
            .self_closing = self_closing,
        };
    }
    cursor.* = source.len;
    return null;
}

/// Find `name="value"` inside a tag's attribute text.
fn findAttr(attrs: []const u8, name: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index < attrs.len) {
        while (index < attrs.len and isXmlSpace(attrs[index])) index += 1;
        if (index >= attrs.len) return null;
        const name_start = index;
        while (index < attrs.len and attrs[index] != '=' and !isXmlSpace(attrs[index])) index += 1;
        const attr_name = attrs[name_start..index];
        while (index < attrs.len and isXmlSpace(attrs[index])) index += 1;
        if (index >= attrs.len or attrs[index] != '=') continue; // valueless attr
        index += 1;
        while (index < attrs.len and isXmlSpace(attrs[index])) index += 1;
        if (index >= attrs.len or (attrs[index] != '"' and attrs[index] != '\'')) return null;
        const quote = attrs[index];
        index += 1;
        const value_start = index;
        while (index < attrs.len and attrs[index] != quote) index += 1;
        if (index >= attrs.len) return null;
        const value = attrs[value_start..index];
        index += 1;
        if (std.mem.eql(u8, attr_name, name)) return value;
    }
    return null;
}

fn isXmlSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

// ---------------------------------------------------------------- styles

fn applyStyleAttrs(attrs: []const u8, base: IconStyle) Error!IconStyle {
    var style = base;
    if (findAttr(attrs, "fill")) |value| style.fill = try parsePaint(value);
    if (findAttr(attrs, "stroke")) |value| style.stroke = try parsePaint(value);
    if (findAttr(attrs, "stroke-width")) |value| style.stroke_width = parseFloat(value) catch return error.SvgParseFailed;
    if (findAttr(attrs, "stroke-linecap")) |value| {
        if (std.mem.eql(u8, value, "round")) {
            style.linecap = .round;
        } else if (std.mem.eql(u8, value, "butt")) {
            style.linecap = .butt;
        } else if (std.mem.eql(u8, value, "square")) {
            // Square caps are not in the stroke model; round is the
            // closest icon-faithful shape.
            style.linecap = .round;
        } else return error.SvgParseFailed;
    }
    if (findAttr(attrs, "stroke-linejoin")) |value| {
        if (std.mem.eql(u8, value, "round")) {
            style.linejoin = .round;
        } else if (std.mem.eql(u8, value, "miter") or std.mem.eql(u8, value, "arcs") or std.mem.eql(u8, value, "bevel")) {
            style.linejoin = .miter;
        } else return error.SvgParseFailed;
    }
    return style;
}

fn parsePaint(value: []const u8) Error!Paint {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "currentColor")) return .current_color;
    if (value.len > 0 and value[0] == '#') {
        const hex = value[1..];
        if (hex.len == 3) {
            const r = hexNibble(hex[0]) orelse return error.SvgParseFailed;
            const g = hexNibble(hex[1]) orelse return error.SvgParseFailed;
            const b = hexNibble(hex[2]) orelse return error.SvgParseFailed;
            return .{ .color = Color.rgb8(r * 17, g * 17, b * 17) };
        }
        if (hex.len == 6) {
            const r = hexByte(hex[0], hex[1]) orelse return error.SvgParseFailed;
            const g = hexByte(hex[2], hex[3]) orelse return error.SvgParseFailed;
            const b = hexByte(hex[4], hex[5]) orelse return error.SvgParseFailed;
            return .{ .color = Color.rgb8(r, g, b) };
        }
        return error.SvgParseFailed;
    }
    if (std.mem.eql(u8, value, "black")) return .{ .color = Color.rgb8(0, 0, 0) };
    if (std.mem.eql(u8, value, "white")) return .{ .color = Color.rgb8(255, 255, 255) };
    return error.SvgParseFailed;
}

fn hexNibble(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn hexByte(hi: u8, lo: u8) ?u8 {
    const h = hexNibble(hi) orelse return null;
    const l = hexNibble(lo) orelse return null;
    return h * 16 + l;
}

fn parseViewBox(value: []const u8) Error!geometry.RectF {
    var scanner = NumberScanner{ .text = value };
    const x = scanner.next() orelse return error.SvgParseFailed;
    const y = scanner.next() orelse return error.SvgParseFailed;
    const width = scanner.next() orelse return error.SvgParseFailed;
    const height = scanner.next() orelse return error.SvgParseFailed;
    if (!(width > 0 and height > 0)) return error.SvgParseFailed;
    return geometry.RectF.init(x, y, width, height);
}

fn attrFloat(attrs: []const u8, name: []const u8, default: f32) Error!f32 {
    const value = findAttr(attrs, name) orelse return default;
    return parseFloat(value) catch error.SvgParseFailed;
}

fn parseFloat(text: []const u8) !f32 {
    return std.fmt.parseFloat(f32, std.mem.trim(u8, text, " \t\r\n"));
}

// ---------------------------------------------------------------- shapes

fn appendRect(builder: anytype, x: f32, y: f32, width: f32, height: f32, rx_in: f32, ry_in: f32) Error!void {
    const rx = @min(@max(0, rx_in), width * 0.5);
    const ry = @min(@max(0, ry_in), height * 0.5);
    if (rx <= 0 or ry <= 0) {
        try builder.moveTo(PointF.init(x, y));
        try builder.lineTo(PointF.init(x + width, y));
        try builder.lineTo(PointF.init(x + width, y + height));
        try builder.lineTo(PointF.init(x, y + height));
        try builder.close();
        return;
    }
    const kx = vector.circle_kappa * rx;
    const ky = vector.circle_kappa * ry;
    try builder.moveTo(PointF.init(x + rx, y));
    try builder.lineTo(PointF.init(x + width - rx, y));
    try builder.cubicTo(PointF.init(x + width - rx + kx, y), PointF.init(x + width, y + ry - ky), PointF.init(x + width, y + ry));
    try builder.lineTo(PointF.init(x + width, y + height - ry));
    try builder.cubicTo(PointF.init(x + width, y + height - ry + ky), PointF.init(x + width - rx + kx, y + height), PointF.init(x + width - rx, y + height));
    try builder.lineTo(PointF.init(x + rx, y + height));
    try builder.cubicTo(PointF.init(x + rx - kx, y + height), PointF.init(x, y + height - ry + ky), PointF.init(x, y + height - ry));
    try builder.lineTo(PointF.init(x, y + ry));
    try builder.cubicTo(PointF.init(x, y + ry - ky), PointF.init(x + rx - kx, y), PointF.init(x + rx, y));
    try builder.close();
}

fn appendEllipse(builder: anytype, cx: f32, cy: f32, rx: f32, ry: f32) Error!void {
    const kx = vector.circle_kappa * rx;
    const ky = vector.circle_kappa * ry;
    try builder.moveTo(PointF.init(cx + rx, cy));
    try builder.cubicTo(PointF.init(cx + rx, cy + ky), PointF.init(cx + kx, cy + ry), PointF.init(cx, cy + ry));
    try builder.cubicTo(PointF.init(cx - kx, cy + ry), PointF.init(cx - rx, cy + ky), PointF.init(cx - rx, cy));
    try builder.cubicTo(PointF.init(cx - rx, cy - ky), PointF.init(cx - kx, cy - ry), PointF.init(cx, cy - ry));
    try builder.cubicTo(PointF.init(cx + kx, cy - ry), PointF.init(cx + rx, cy - ky), PointF.init(cx + rx, cy));
    try builder.close();
}

fn appendPolyline(builder: anytype, points: []const u8, close: bool) Error!void {
    var scanner = NumberScanner{ .text = points };
    var first = true;
    while (scanner.next()) |x| {
        const y = scanner.next() orelse return error.SvgParseFailed;
        if (first) {
            try builder.moveTo(PointF.init(x, y));
            first = false;
        } else {
            try builder.lineTo(PointF.init(x, y));
        }
    }
    if (first) return error.SvgParseFailed;
    if (close) try builder.close();
}

// -------------------------------------------------------------- path data

const NumberScanner = struct {
    text: []const u8,
    index: usize = 0,

    fn skipSeparators(self: *NumberScanner) void {
        while (self.index < self.text.len) {
            const byte = self.text[self.index];
            if (isXmlSpace(byte) or byte == ',') {
                self.index += 1;
            } else break;
        }
    }

    fn next(self: *NumberScanner) ?f32 {
        self.skipSeparators();
        if (self.index >= self.text.len) return null;
        const start = self.index;
        var seen_digit = false;
        var seen_dot = false;
        var seen_exp = false;
        while (self.index < self.text.len) {
            const byte = self.text[self.index];
            if (byte >= '0' and byte <= '9') {
                seen_digit = true;
                self.index += 1;
            } else if (byte == '.' and !seen_dot and !seen_exp) {
                seen_dot = true;
                self.index += 1;
            } else if ((byte == '-' or byte == '+') and (self.index == start or
                (seen_exp and (self.text[self.index - 1] == 'e' or self.text[self.index - 1] == 'E'))))
            {
                self.index += 1;
            } else if ((byte == 'e' or byte == 'E') and seen_digit and !seen_exp) {
                seen_exp = true;
                self.index += 1;
            } else if (byte == '.' and seen_dot) {
                // SVG path shorthand: "1.5.5" is 1.5 then .5.
                break;
            } else break;
        }
        if (!seen_digit) return null;
        return std.fmt.parseFloat(f32, self.text[start..self.index]) catch null;
    }

    /// An SVG arc flag is a single `0`/`1` that may be glued to the next
    /// number ("a1 1 0 01.6.3"), so it cannot be scanned as a float.
    fn nextFlag(self: *NumberScanner) ?bool {
        self.skipSeparators();
        if (self.index >= self.text.len) return null;
        const byte = self.text[self.index];
        if (byte != '0' and byte != '1') return null;
        self.index += 1;
        return byte == '1';
    }
};

/// Full SVG path-data grammar over the builder verbs. Arcs lower to
/// cubics inside `PathBuilder.arcTo`.
fn parsePathData(data: []const u8, builder: anytype) Error!void {
    var scanner = NumberScanner{ .text = data };
    var command: u8 = 0;
    var current = PointF.zero();
    var subpath_start = PointF.zero();
    // Reflection state for S/T shorthands.
    var last_cubic_control: ?PointF = null;
    var last_quad_control: ?PointF = null;

    while (true) {
        scanner.skipSeparators();
        if (scanner.index >= scanner.text.len) return;
        const byte = scanner.text[scanner.index];
        if ((byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z')) {
            command = byte;
            scanner.index += 1;
        } else if (command == 0 or command == 'Z' or command == 'z') {
            // Numbers with no command in force (or trailing a close).
            return error.SvgParseFailed;
        } else if (command == 'M') {
            command = 'L'; // Implicit repetition of moveto continues as lineto.
        } else if (command == 'm') {
            command = 'l';
        }

        const relative = command >= 'a' and command <= 'z';
        const upper = if (relative) command - 32 else command;
        const origin = if (relative) current else PointF.zero();

        switch (upper) {
            'M' => {
                const x = scanner.next() orelse return error.SvgParseFailed;
                const y = scanner.next() orelse return error.SvgParseFailed;
                current = PointF.init(origin.x + x, origin.y + y);
                subpath_start = current;
                try builder.moveTo(current);
                last_cubic_control = null;
                last_quad_control = null;
            },
            'L' => {
                const x = scanner.next() orelse return error.SvgParseFailed;
                const y = scanner.next() orelse return error.SvgParseFailed;
                current = PointF.init(origin.x + x, origin.y + y);
                try builder.lineTo(current);
                last_cubic_control = null;
                last_quad_control = null;
            },
            'H' => {
                const x = scanner.next() orelse return error.SvgParseFailed;
                current = PointF.init(origin.x + x, current.y);
                try builder.lineTo(current);
                last_cubic_control = null;
                last_quad_control = null;
            },
            'V' => {
                const y = scanner.next() orelse return error.SvgParseFailed;
                current = PointF.init(current.x, origin.y + y);
                try builder.lineTo(current);
                last_cubic_control = null;
                last_quad_control = null;
            },
            'C' => {
                const x1 = scanner.next() orelse return error.SvgParseFailed;
                const y1 = scanner.next() orelse return error.SvgParseFailed;
                const x2 = scanner.next() orelse return error.SvgParseFailed;
                const y2 = scanner.next() orelse return error.SvgParseFailed;
                const x = scanner.next() orelse return error.SvgParseFailed;
                const y = scanner.next() orelse return error.SvgParseFailed;
                const c1 = PointF.init(origin.x + x1, origin.y + y1);
                const c2 = PointF.init(origin.x + x2, origin.y + y2);
                current = PointF.init(origin.x + x, origin.y + y);
                try builder.cubicTo(c1, c2, current);
                last_cubic_control = c2;
                last_quad_control = null;
            },
            'S' => {
                const x2 = scanner.next() orelse return error.SvgParseFailed;
                const y2 = scanner.next() orelse return error.SvgParseFailed;
                const x = scanner.next() orelse return error.SvgParseFailed;
                const y = scanner.next() orelse return error.SvgParseFailed;
                const c1 = if (last_cubic_control) |control|
                    PointF.init(2 * current.x - control.x, 2 * current.y - control.y)
                else
                    current;
                const c2 = PointF.init(origin.x + x2, origin.y + y2);
                current = PointF.init(origin.x + x, origin.y + y);
                try builder.cubicTo(c1, c2, current);
                last_cubic_control = c2;
                last_quad_control = null;
            },
            'Q' => {
                const x1 = scanner.next() orelse return error.SvgParseFailed;
                const y1 = scanner.next() orelse return error.SvgParseFailed;
                const x = scanner.next() orelse return error.SvgParseFailed;
                const y = scanner.next() orelse return error.SvgParseFailed;
                const control = PointF.init(origin.x + x1, origin.y + y1);
                current = PointF.init(origin.x + x, origin.y + y);
                try builder.quadTo(control, current);
                last_quad_control = control;
                last_cubic_control = null;
            },
            'T' => {
                const x = scanner.next() orelse return error.SvgParseFailed;
                const y = scanner.next() orelse return error.SvgParseFailed;
                const control = if (last_quad_control) |previous|
                    PointF.init(2 * current.x - previous.x, 2 * current.y - previous.y)
                else
                    current;
                current = PointF.init(origin.x + x, origin.y + y);
                try builder.quadTo(control, current);
                last_quad_control = control;
                last_cubic_control = null;
            },
            'A' => {
                const rx = scanner.next() orelse return error.SvgParseFailed;
                const ry = scanner.next() orelse return error.SvgParseFailed;
                const rotation = scanner.next() orelse return error.SvgParseFailed;
                const large_arc = scanner.nextFlag() orelse return error.SvgParseFailed;
                const sweep = scanner.nextFlag() orelse return error.SvgParseFailed;
                const x = scanner.next() orelse return error.SvgParseFailed;
                const y = scanner.next() orelse return error.SvgParseFailed;
                const end = PointF.init(origin.x + x, origin.y + y);
                try builder.arcTo(rx, ry, rotation, large_arc, sweep, end);
                current = end;
                last_cubic_control = null;
                last_quad_control = null;
            },
            'Z' => {
                try builder.close();
                current = subpath_start;
                last_cubic_control = null;
                last_quad_control = null;
            },
            else => return error.SvgParseFailed,
        }
    }
}
