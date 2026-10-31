const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const hash_model = @import("hash.zig");
const text_model = @import("text.zig");

const ObjectId = canvas.ObjectId;
const ImageId = canvas.ImageId;
const FontId = canvas.FontId;
const ReferenceImage = canvas.ReferenceImage;
const Affine = drawing_model.Affine;
const LinearGradient = drawing_model.LinearGradient;
const Fill = drawing_model.Fill;
const Stroke = drawing_model.Stroke;
const DrawImage = drawing_model.DrawImage;
const Shadow = drawing_model.Shadow;
const Blur = drawing_model.Blur;
const Glyph = text_model.Glyph;
const DrawText = text_model.DrawText;
const TextLayoutOptions = text_model.TextLayoutOptions;

const resourceHashTag = hash_model.resourceHashTag;
const resourceHashBytes = hash_model.resourceHashBytes;
const resourceHashU8 = hash_model.resourceHashU8;
const resourceHashU32 = hash_model.resourceHashU32;
const resourceHashU64 = hash_model.resourceHashU64;
const resourceHashUsize = hash_model.resourceHashUsize;
const resourceHashEnum = hash_model.resourceHashEnum;
const resourceHashF32 = hash_model.resourceHashF32;
const resourceHashPoint = hash_model.resourceHashPoint;
const resourceHashRect = hash_model.resourceHashRect;
const resourceHashOptionalRect = hash_model.resourceHashOptionalRect;
const resourceHashOptionalObjectId = hash_model.resourceHashOptionalObjectId;
const resourceHashAffine = hash_model.resourceHashAffine;
const resourceHashRadius = hash_model.resourceHashRadius;
const resourceHashColor = hash_model.resourceHashColor;
const resourceHashPath = hash_model.resourceHashPath;

pub fn drawImageFingerprint(image: DrawImage) u64 {
    var hash = resourceHashTag("image");
    hash = resourceHashU64(hash, image.image_id);
    hash = resourceHashOptionalRect(hash, image.src);
    hash = resourceHashEnum(hash, @intFromEnum(image.fit));
    hash = resourceHashEnum(hash, @intFromEnum(image.sampling));
    return hash;
}

pub fn renderImageFingerprint(image_id: ImageId) u64 {
    return resourceHashU64(resourceHashTag("image_texture"), image_id);
}

pub fn renderImageFingerprintForResource(image_id: ImageId, image: ?ReferenceImage) u64 {
    const value = image orelse return renderImageFingerprint(image_id);
    var hash = renderImageFingerprint(image_id);
    hash = resourceHashUsize(hash, value.width);
    hash = resourceHashUsize(hash, value.height);
    // A precomputed content fingerprint stands in for the pixel bytes:
    // media-surface textures stamp one at adoption so the planner never
    // re-hashes a full video frame per plan. Any content change changes
    // the stamp, so upload/retain/evict keying is untouched; resources
    // without one (every registered canvas image) hash bytes as always.
    if (value.content_fingerprint != 0) {
        return resourceHashU64(hash, value.content_fingerprint);
    }
    hash = resourceHashBytes(hash, value.pixels);
    return hash;
}

pub fn renderLayerFingerprint(command: anytype) u64 {
    var hash = resourceHashTag("layer");
    hash = resourceHashF32(hash, command.opacity);
    hash = resourceHashOptionalRect(hash, command.clip);
    hash = resourceHashAffine(hash, command.transform);
    return renderLayerFingerprintAppend(hash, command);
}

pub fn renderLayerFingerprintAppend(hash: u64, command: anytype) u64 {
    return resourceHashU64(hash, renderCommandFingerprint(command));
}

pub fn renderCommandFingerprint(command: anytype) u64 {
    var hash = resourceHashTag("render_command");
    hash = resourceHashOptionalObjectId(hash, command.id);
    hash = resourceHashRect(hash, command.local_bounds);
    hash = resourceHashRect(hash, command.bounds);
    return resourceHashCanvasCommand(hash, command.command);
}

pub fn linearGradientFingerprint(gradient: LinearGradient) u64 {
    var hash = resourceHashTag("linear_gradient");
    hash = resourceHashPoint(hash, gradient.start);
    hash = resourceHashPoint(hash, gradient.end);
    hash = resourceHashUsize(hash, gradient.stops.len);
    for (gradient.stops) |stop| {
        hash = resourceHashF32(hash, stop.offset);
        hash = resourceHashColor(hash, stop.color);
    }
    return hash;
}

pub fn drawTextFingerprint(text: DrawText) u64 {
    var hash = resourceHashTag("glyph_run");
    hash = resourceHashU64(hash, text.font_id);
    hash = resourceHashF32(hash, text.size);
    hash = resourceHashPoint(hash, text.origin);
    hash = resourceHashBytes(hash, text.text);
    hash = resourceHashUsize(hash, text.glyphs.len);
    for (text.glyphs) |glyph| {
        hash = resourceHashU32(hash, glyph.id);
        hash = resourceHashU64(hash, glyphFontId(text.font_id, glyph));
        hash = resourceHashF32(hash, glyph.x);
        hash = resourceHashF32(hash, glyph.y);
        hash = resourceHashF32(hash, glyph.advance);
        hash = resourceHashUsize(hash, glyph.text_start);
        hash = resourceHashUsize(hash, glyph.text_len);
    }
    hash = resourceHashOptionalTextLayoutOptions(hash, text.text_layout);
    return hash;
}

fn glyphFontId(run_font_id: FontId, glyph: Glyph) FontId {
    return if (glyph.font_id == 0) run_font_id else glyph.font_id;
}

pub fn shadowFingerprint(shadow: Shadow) u64 {
    var hash = resourceHashTag("shadow");
    hash = resourceHashRect(hash, shadow.rect);
    hash = resourceHashRadius(hash, shadow.radius);
    hash = resourceHashF32(hash, shadow.offset.dx);
    hash = resourceHashF32(hash, shadow.offset.dy);
    hash = resourceHashF32(hash, shadow.blur);
    hash = resourceHashF32(hash, shadow.spread);
    hash = resourceHashColor(hash, shadow.color);
    return hash;
}

pub fn blurFingerprint(blur: Blur) u64 {
    var hash = resourceHashTag("blur");
    hash = resourceHashRect(hash, blur.rect);
    hash = resourceHashF32(hash, blur.radius);
    return hash;
}

fn resourceHashOptionalTextLayoutOptions(hash: u64, options: ?TextLayoutOptions) u64 {
    if (options) |value| {
        var next = resourceHashU8(hash, 1);
        next = resourceHashF32(next, nonNegative(value.max_width));
        next = resourceHashF32(next, nonNegative(value.line_height));
        next = resourceHashEnum(next, @intFromEnum(value.wrap));
        next = resourceHashEnum(next, @intFromEnum(value.alignment));
        // The default overflow stays out of the hash so fingerprints of
        // runs untouched by elision keep their pinned values; a
        // non-default (clip) run hashes apart from its elided twin.
        if (value.overflow != .ellipsis) {
            next = resourceHashEnum(resourceHashBytes(next, "text_overflow"), @intFromEnum(value.overflow));
        }
        return next;
    }
    return resourceHashU8(hash, 0);
}

fn resourceHashCanvasCommand(hash: u64, command: anytype) u64 {
    var next = resourceHashBytes(hash, @tagName(command));
    switch (command) {
        .push_clip => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashRect(next, value.rect);
            next = resourceHashRadius(next, value.radius);
        },
        .pop_clip, .push_opacity, .pop_opacity, .transform => {},
        .fill_rect => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashRect(next, value.rect);
            next = resourceHashFill(next, value.fill);
        },
        .stroke_rect => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashRect(next, value.rect);
            next = resourceHashRadius(next, value.radius);
            next = resourceHashStroke(next, value.stroke);
        },
        .fill_rounded_rect => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashRect(next, value.rect);
            next = resourceHashRadius(next, value.radius);
            next = resourceHashFill(next, value.fill);
        },
        .draw_line => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashPoint(next, value.from);
            next = resourceHashPoint(next, value.to);
            next = resourceHashStroke(next, value.stroke);
        },
        .fill_path => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashPath(next, value.elements);
            next = resourceHashFill(next, value.fill);
        },
        .stroke_path => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashPath(next, value.elements);
            next = resourceHashStroke(next, value.stroke);
            // The cap changes rendered pixels at open subpath ends, so a
            // cap flip must invalidate any cached render keyed off this.
            next = resourceHashEnum(next, @intFromEnum(value.cap));
        },
        .draw_image => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashU64(next, drawImageFingerprint(value));
            next = resourceHashRect(next, value.dst);
            next = resourceHashF32(next, value.opacity);
            next = resourceHashRadius(next, value.radius);
        },
        .draw_text => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashU64(next, drawTextFingerprint(value));
            next = resourceHashColor(next, value.color);
        },
        .shadow => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashU64(next, shadowFingerprint(value));
        },
        .blur => |value| {
            next = resourceHashOptionalObjectId(next, nonZeroObjectId(value.id));
            next = resourceHashU64(next, blurFingerprint(value));
        },
    }
    return next;
}

fn resourceHashFill(hash: u64, fill: Fill) u64 {
    return switch (fill) {
        .color => |color| resourceHashColor(resourceHashBytes(hash, "color"), color),
        .linear_gradient => |gradient| resourceHashU64(resourceHashBytes(hash, "linear_gradient"), linearGradientFingerprint(gradient)),
    };
}

fn resourceHashStroke(hash: u64, stroke: Stroke) u64 {
    var next = resourceHashF32(resourceHashBytes(hash, "stroke"), stroke.width);
    next = resourceHashFill(next, stroke.fill);
    return next;
}

pub fn nonZeroObjectId(id: ObjectId) ?ObjectId {
    return if (id == 0) null else id;
}

pub fn affinesEqual(a: Affine, b: Affine) bool {
    return a.a == b.a and
        a.b == b.b and
        a.c == b.c and
        a.d == b.d and
        a.tx == b.tx and
        a.ty == b.ty;
}

pub fn referenceTransformScale(transform: Affine) f32 {
    const x_scale = @sqrt(transform.a * transform.a + transform.b * transform.b);
    const y_scale = @sqrt(transform.c * transform.c + transform.d * transform.d);
    return @max(0.0001, @max(x_scale, y_scale));
}

pub fn nonNegative(value: f32) f32 {
    return @max(0, value);
}
