const geometry = @import("geometry");
const canvas = @import("root.zig");
const hash_model = @import("hash.zig");
const text_atlas = @import("text_atlas.zig");
const text_layout_types = @import("text_layout_types.zig");

const FontId = canvas.FontId;
const Glyph = text_atlas.Glyph;
const glyphFontId = text_atlas.glyphFontId;
const DrawText = text_layout_types.DrawText;
const TextLayoutOptions = text_layout_types.TextLayoutOptions;
const TextLayoutKey = text_layout_types.TextLayoutKey;
const resourceHashTag = hash_model.resourceHashTag;
const resourceHashBytes = hash_model.resourceHashBytes;
const resourceHashU8 = hash_model.resourceHashU8;
const resourceHashU32 = hash_model.resourceHashU32;
const resourceHashU64 = hash_model.resourceHashU64;
const resourceHashUsize = hash_model.resourceHashUsize;
const resourceHashEnum = hash_model.resourceHashEnum;
const resourceHashF32 = hash_model.resourceHashF32;
const resourceHashPoint = hash_model.resourceHashPoint;

pub fn textLayoutOptionsForDrawText(frame_options: TextLayoutOptions, text: DrawText) TextLayoutOptions {
    return text.text_layout orelse frame_options;
}

pub fn textLayoutKey(text: DrawText, options: TextLayoutOptions) TextLayoutKey {
    return .{
        .font_id = text.font_id,
        .size = text.size,
        .origin = text.origin,
        .max_width = nonNegative(options.max_width),
        .line_height = nonNegative(options.line_height),
        .wrap = options.wrap,
        .alignment = options.alignment,
        .text_len = text.text.len,
        .glyph_count = text.glyphs.len,
        .fingerprint = textLayoutFingerprint(text, options),
    };
}

fn textLayoutFingerprint(text: DrawText, options: TextLayoutOptions) u64 {
    var hash = resourceHashTag("text_layout");
    hash = resourceHashU64(hash, drawTextFingerprint(text));
    hash = resourceHashF32(hash, nonNegative(options.max_width));
    hash = resourceHashF32(hash, nonNegative(options.line_height));
    hash = resourceHashEnum(hash, @intFromEnum(options.wrap));
    hash = resourceHashEnum(hash, @intFromEnum(options.alignment));
    return hash;
}

fn drawTextFingerprint(text: DrawText) u64 {
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

pub fn textLayoutKeysEqual(a: TextLayoutKey, b: TextLayoutKey) bool {
    return a.font_id == b.font_id and
        a.size == b.size and
        a.origin.x == b.origin.x and
        a.origin.y == b.origin.y and
        a.max_width == b.max_width and
        a.line_height == b.line_height and
        a.wrap == b.wrap and
        a.alignment == b.alignment and
        a.text_len == b.text_len and
        a.glyph_count == b.glyph_count and
        a.fingerprint == b.fingerprint;
}

fn resourceHashOptionalTextLayoutOptions(hash: u64, options: ?TextLayoutOptions) u64 {
    if (options) |value| {
        var next = resourceHashU8(hash, 1);
        next = resourceHashF32(next, nonNegative(value.max_width));
        next = resourceHashF32(next, nonNegative(value.line_height));
        next = resourceHashEnum(next, @intFromEnum(value.wrap));
        next = resourceHashEnum(next, @intFromEnum(value.alignment));
        return next;
    }
    return resourceHashU8(hash, 0);
}

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}
