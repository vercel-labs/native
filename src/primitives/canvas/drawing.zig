const geometry = @import("geometry");

const ObjectId = u64;
const ImageId = u64;

pub const Color = struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn rgb8(r: u8, g: u8, b: u8) Color {
        return rgba8(r, g, b, 255);
    }

    pub fn rgba8(r: u8, g: u8, b: u8, a: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = @as(f32, @floatFromInt(a)) / 255.0,
        };
    }
};

pub const Affine = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    tx: f32 = 0,
    ty: f32 = 0,

    pub fn identity() Affine {
        return .{};
    }

    pub fn translate(x: f32, y: f32) Affine {
        return .{ .tx = x, .ty = y };
    }

    pub fn scale(x: f32, y: f32) Affine {
        return .{ .a = x, .d = y };
    }

    pub fn multiply(self: Affine, other: Affine) Affine {
        return .{
            .a = self.a * other.a + self.c * other.b,
            .b = self.b * other.a + self.d * other.b,
            .c = self.a * other.c + self.c * other.d,
            .d = self.b * other.c + self.d * other.d,
            .tx = self.a * other.tx + self.c * other.ty + self.tx,
            .ty = self.b * other.tx + self.d * other.ty + self.ty,
        };
    }

    pub fn transformPoint(self: Affine, point: geometry.PointF) geometry.PointF {
        return .{
            .x = self.a * point.x + self.c * point.y + self.tx,
            .y = self.b * point.x + self.d * point.y + self.ty,
        };
    }

    pub fn transformRect(self: Affine, rect: geometry.RectF) geometry.RectF {
        const normalized = rect.normalized();
        return boundsFromPoints(&.{
            self.transformPoint(normalized.topLeft()),
            self.transformPoint(normalized.topRight()),
            self.transformPoint(normalized.bottomLeft()),
            self.transformPoint(normalized.bottomRight()),
        }) orelse geometry.RectF.zero();
    }

    pub fn inverse(self: Affine) ?Affine {
        const determinant = self.a * self.d - self.b * self.c;
        if (@abs(determinant) <= 0.000001) return null;
        const inv = 1 / determinant;
        return .{
            .a = self.d * inv,
            .b = -self.b * inv,
            .c = -self.c * inv,
            .d = self.a * inv,
            .tx = (self.c * self.ty - self.d * self.tx) * inv,
            .ty = (self.b * self.tx - self.a * self.ty) * inv,
        };
    }
};

pub const Radius = struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_right: f32 = 0,
    bottom_left: f32 = 0,

    pub fn all(value: f32) Radius {
        return .{
            .top_left = value,
            .top_right = value,
            .bottom_right = value,
            .bottom_left = value,
        };
    }
};

pub const GradientStop = struct {
    offset: f32,
    color: Color,
};

pub const LinearGradient = struct {
    start: geometry.PointF,
    end: geometry.PointF,
    stops: []const GradientStop = &.{},
};

pub const Fill = union(enum) {
    color: Color,
    linear_gradient: LinearGradient,
};

pub const Stroke = struct {
    fill: Fill,
    width: f32 = 1,
};

pub const Clip = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    radius: Radius = .{},
};

pub const FillRect = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    fill: Fill,
};

pub const StrokeRect = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    radius: Radius = .{},
    stroke: Stroke,
};

pub const FillRoundedRect = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    radius: Radius,
    fill: Fill,
};

pub const Line = struct {
    id: ObjectId = 0,
    from: geometry.PointF,
    to: geometry.PointF,
    stroke: Stroke,
};

pub const PathVerb = enum {
    move_to,
    line_to,
    quad_to,
    cubic_to,
    close,
};

pub const PathElement = struct {
    verb: PathVerb,
    points: [3]geometry.PointF = [_]geometry.PointF{geometry.PointF.zero()} ** 3,
};

pub const FillPath = struct {
    id: ObjectId = 0,
    elements: []const PathElement = &.{},
    fill: Fill,
};

pub const StrokePath = struct {
    id: ObjectId = 0,
    elements: []const PathElement = &.{},
    stroke: Stroke,
};

pub const ImageFit = enum {
    stretch,
    contain,
    cover,
};

pub const ImageSampling = enum {
    nearest,
    linear,
};

pub const DrawImage = struct {
    id: ObjectId = 0,
    image_id: ImageId,
    src: ?geometry.RectF = null,
    dst: geometry.RectF,
    opacity: f32 = 1,
    fit: ImageFit = .stretch,
    sampling: ImageSampling = .linear,
};

pub const Shadow = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    radius: Radius = .{},
    offset: geometry.OffsetF = .{},
    blur: f32 = 0,
    spread: f32 = 0,
    color: Color,
};

pub const Blur = struct {
    id: ObjectId = 0,
    rect: geometry.RectF,
    radius: f32 = 0,
};

pub fn strokeBounds(rect: geometry.RectF, width: f32) geometry.RectF {
    return rect.normalized().inflate(geometry.InsetsF.all(nonNegative(width) * 0.5));
}

pub fn shadowBounds(value: Shadow) geometry.RectF {
    const spread = nonNegative(@abs(value.spread));
    const blur_radius = nonNegative(value.blur);
    return value.rect
        .normalized()
        .translate(value.offset)
        .inflate(geometry.InsetsF.all(spread + blur_radius));
}

pub fn pathBounds(elements: []const PathElement) ?geometry.RectF {
    var has_point = false;
    var min_x: f32 = 0;
    var min_y: f32 = 0;
    var max_x: f32 = 0;
    var max_y: f32 = 0;
    for (elements) |element| {
        const point_count: usize = switch (element.verb) {
            .move_to, .line_to => 1,
            .quad_to => 2,
            .cubic_to => 3,
            .close => 0,
        };
        for (element.points[0..point_count]) |point| {
            if (!has_point) {
                has_point = true;
                min_x = point.x;
                min_y = point.y;
                max_x = point.x;
                max_y = point.y;
            } else {
                min_x = @min(min_x, point.x);
                min_y = @min(min_y, point.y);
                max_x = @max(max_x, point.x);
                max_y = @max(max_y, point.y);
            }
        }
    }
    if (!has_point) return null;
    return geometry.RectF.init(min_x, min_y, max_x - min_x, max_y - min_y);
}

fn boundsFromPoints(points: []const geometry.PointF) ?geometry.RectF {
    if (points.len == 0) return null;
    var min_x = points[0].x;
    var min_y = points[0].y;
    var max_x = points[0].x;
    var max_y = points[0].y;
    for (points[1..]) |point| {
        min_x = @min(min_x, point.x);
        min_y = @min(min_y, point.y);
        max_x = @max(max_x, point.x);
        max_y = @max(max_y, point.y);
    }
    return geometry.RectF.init(min_x, min_y, max_x - min_x, max_y - min_y);
}

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}
