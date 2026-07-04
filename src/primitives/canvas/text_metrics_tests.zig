//! Estimator agreement tests. The deterministic estimator derives its
//! advances from the bundled Geist face at comptime; these tests pin
//! (a) that lockstep — the estimator IS the face's `cmap`/`hmtx`, plus
//! the two documented fallbacks — and (b) on macOS, that CoreText
//! shaping the same bundled bytes measures within a stated tolerance,
//! i.e. the provider path and the estimator agree up to kerning and
//! floating-point rounding.

const std = @import("std");
const builtin = @import("builtin");
const canvas = @import("root.zig");
const font_ttf = @import("font_ttf.zig");
const text_metrics = @import("text_metrics.zig");

const testing = std.testing;

fn faceAdvanceEm(codepoint: u21) f32 {
    const face = &font_ttf.geist_regular;
    const glyph = face.glyphIndex(codepoint);
    if (glyph == 0) return 0;
    return face.advance(glyph) / face.units_per_em;
}

fn estimatorAdvanceEm(font_id: canvas.FontId, bytes: []const u8) f32 {
    return text_metrics.estimateTextAdvanceForBytes(font_id, bytes, 1.0);
}

// Multibyte codepoints the bundled face covers, spanning the widths the
// old flat 0.65 em guess got most wrong: · (0.207 em), → (0.808 em),
// plus accents, dashes, ellipsis, quotes, and the degree sign.
const covered_multibyte_samples = [_][]const u8{ "·", "→", "é", "–", "—", "…", "\u{201C}", "°", "€" };

test "estimator advances are the bundled face's advance table" {
    // Printable ASCII: the comptime table must be exactly hmtx/upem.
    var byte: u8 = 0x20;
    while (byte < 0x7F) : (byte += 1) {
        const bytes = [_]u8{byte};
        try testing.expectEqual(faceAdvanceEm(byte), estimatorAdvanceEm(canvas.default_sans_font_id, &bytes));
    }
    // Covered multibyte codepoints: the runtime lookup must answer with
    // the same face advance the renderer inks the outline at.
    for (covered_multibyte_samples) |sample| {
        const advance = estimatorAdvanceEm(canvas.default_sans_font_id, sample);
        const codepoint = try std.unicode.utf8Decode(sample);
        try testing.expect(faceAdvanceEm(codepoint) > 0);
        try testing.expectEqual(faceAdvanceEm(codepoint), advance);
    }
}

test "estimator fallbacks charge notdef and east asian wide cells" {
    const notdef_em = font_ttf.geist_regular.advance(0) / font_ttf.geist_regular.units_per_em;
    try testing.expectEqual(@as(f32, 0.6), notdef_em);

    // CJK / fullwidth / emoji: uncovered by the bundled face, charged a
    // full em (the advance CJK fallback fonts use for these cells).
    try testing.expectEqual(@as(f32, 1.0), estimatorAdvanceEm(canvas.default_sans_font_id, "中"));
    try testing.expectEqual(@as(f32, 1.0), estimatorAdvanceEm(canvas.default_sans_font_id, "あ"));
    try testing.expectEqual(@as(f32, 1.0), estimatorAdvanceEm(canvas.default_sans_font_id, "\u{FF21}"));
    try testing.expectEqual(@as(f32, 1.0), estimatorAdvanceEm(canvas.default_sans_font_id, "😀"));

    // Uncovered non-wide codepoints (Hebrew alef) and malformed bytes:
    // the face's own `.notdef` advance.
    try testing.expectEqual(notdef_em, estimatorAdvanceEm(canvas.default_sans_font_id, "\u{05D0}"));
    try testing.expectEqual(notdef_em, estimatorAdvanceEm(canvas.default_sans_font_id, &[_]u8{0xC3}));
    try testing.expectEqual(notdef_em, estimatorAdvanceEm(canvas.default_sans_font_id, &[_]u8{ 0xE2, 0x86 }));
    try testing.expectEqual(notdef_em, estimatorAdvanceEm(canvas.default_sans_font_id, &[_]u8{0x07}));

    // Uncovered symbol/pictograph blocks (GitHub markdown's U+2610/U+2611
    // ballot boxes, ⌘, geometric shapes): 0.8 em, the documented
    // approximation of the AppleSymbols cascade class live macOS text
    // falls back to (measured 0.83 em for the ballot boxes). Covered
    // symbols like → keep their exact face advance (pinned above).
    try testing.expectEqual(@as(f32, 0.8), estimatorAdvanceEm(canvas.default_sans_font_id, "☐"));
    try testing.expectEqual(@as(f32, 0.8), estimatorAdvanceEm(canvas.default_sans_font_id, "☑"));
    try testing.expectEqual(@as(f32, 0.8), estimatorAdvanceEm(canvas.default_sans_font_id, "⌘"));

    // Mono keeps its documented 0.6 em design pitch (Geist Mono's real
    // advance; no mono face is bundled), and the sans span variants keep
    // their width factors on top of the derived regular advances.
    try testing.expectEqual(@as(f32, 0.6), estimatorAdvanceEm(canvas.default_mono_font_id, "M"));
    try testing.expectEqual(@as(f32, 0.6), estimatorAdvanceEm(canvas.default_mono_font_id, "i"));
    const regular = estimatorAdvanceEm(canvas.default_sans_font_id, "n");
    try testing.expectEqual(regular * 1.02, estimatorAdvanceEm(canvas.default_sans_medium_font_id, "n"));
    try testing.expectEqual(regular * 1.04, estimatorAdvanceEm(canvas.default_sans_bold_font_id, "n"));
}

// ---- CoreText agreement (macOS) --------------------------------------
//
// Shapes the BUNDLED bytes through CoreText — the same shaper behind the
// live provider path (`native_sdk_appkit_measure_text`) — so the check
// is independent of whatever Geist version the host machine has
// installed. Tolerances, stated and justified:
//
//   * per-codepoint: 0.001 em. Advances come from the same `hmtx` table
//     read by two parsers; the only residue is f32-vs-f64 rounding.
//   * whole strings: 2.5% relative. CTLine applies the face's GPOS
//     kerning, the estimator deliberately does not (it must stay a pure
//     per-cluster sum for incremental layout). Measured over the sample
//     set the kerning residue is 1.5–2.1% (short strings kern denser);
//     adversarial all-kerning text (e.g. "AVAWAY") can exceed this —
//     that residual class is kerning, not advance error, and is a
//     known, accepted divergence.

const CFIndex = isize;
const CGSize = extern struct { width: f64, height: f64 };

extern "c" fn CFDataCreate(allocator: ?*anyopaque, bytes: [*]const u8, length: CFIndex) ?*anyopaque;
extern "c" fn CTFontManagerCreateFontDescriptorFromData(data: ?*anyopaque) ?*anyopaque;
extern "c" fn CTFontCreateWithFontDescriptor(descriptor: ?*anyopaque, size: f64, matrix: ?*const anyopaque) ?*anyopaque;
extern "c" fn CTFontGetGlyphsForCharacters(font: ?*anyopaque, characters: [*]const u16, glyphs: [*]u16, count: CFIndex) bool;
extern "c" fn CTFontGetAdvancesForGlyphs(font: ?*anyopaque, orientation: u32, glyphs: [*]const u16, advances: ?[*]CGSize, count: CFIndex) f64;
extern "c" fn CFStringCreateWithBytes(allocator: ?*anyopaque, bytes: [*]const u8, num_bytes: CFIndex, encoding: u32, external: bool) ?*anyopaque;
extern "c" fn CFDictionaryCreate(
    allocator: ?*anyopaque,
    keys: [*]const ?*const anyopaque,
    values: [*]const ?*const anyopaque,
    num_values: CFIndex,
    key_callbacks: ?*const anyopaque,
    value_callbacks: ?*const anyopaque,
) ?*anyopaque;
extern "c" fn CFAttributedStringCreate(allocator: ?*anyopaque, string: ?*anyopaque, attributes: ?*anyopaque) ?*anyopaque;
extern "c" fn CTLineCreateWithAttributedString(attributed: ?*anyopaque) ?*anyopaque;
extern "c" fn CTLineGetTypographicBounds(line: ?*anyopaque, ascent: ?*f64, descent: ?*f64, leading: ?*f64) f64;
extern "c" fn CFRelease(cf: ?*anyopaque) void;
extern const kCTFontAttributeName: ?*const anyopaque;
extern const kCFTypeDictionaryKeyCallBacks: [6]usize;
extern const kCFTypeDictionaryValueCallBacks: [6]usize;

const cf_string_encoding_utf8: u32 = 0x0800_0100;

fn bundledCoreTextFont(size: f64) !?*anyopaque {
    const bytes = font_ttf.geist_regular_bytes;
    const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return error.SkipZigTest;
    defer CFRelease(data);
    const descriptor = CTFontManagerCreateFontDescriptorFromData(data) orelse return error.SkipZigTest;
    defer CFRelease(descriptor);
    return CTFontCreateWithFontDescriptor(descriptor, size, null) orelse error.SkipZigTest;
}

fn coreTextGlyphAdvanceEm(font: ?*anyopaque, size: f64, unit: u16) !f64 {
    var characters = [_]u16{unit};
    var glyphs = [_]u16{0};
    try testing.expect(CTFontGetGlyphsForCharacters(font, &characters, &glyphs, 1));
    try testing.expect(glyphs[0] != 0);
    return CTFontGetAdvancesForGlyphs(font, 0, &glyphs, null, 1) / size;
}

fn coreTextLineWidthEm(font: ?*anyopaque, size: f64, text: []const u8) !f64 {
    const string = CFStringCreateWithBytes(null, text.ptr, @intCast(text.len), cf_string_encoding_utf8, false) orelse return error.TestUnexpectedResult;
    defer CFRelease(string);
    var keys = [_]?*const anyopaque{kCTFontAttributeName};
    var values = [_]?*const anyopaque{font};
    const attributes = CFDictionaryCreate(null, &keys, &values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) orelse return error.TestUnexpectedResult;
    defer CFRelease(attributes);
    const attributed = CFAttributedStringCreate(null, string, attributes) orelse return error.TestUnexpectedResult;
    defer CFRelease(attributed);
    const line = CTLineCreateWithAttributedString(attributed) orelse return error.TestUnexpectedResult;
    defer CFRelease(line);
    return CTLineGetTypographicBounds(line, null, null, null) / size;
}

test "estimator agrees with CoreText shaping the bundled face" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;

    const size: f64 = 1000;
    const font = try bundledCoreTextFont(size);
    defer CFRelease(font);

    // Per-codepoint advances over printable ASCII: max divergence must
    // stay within f32/f64 rounding (0.001 em).
    var worst: f64 = 0;
    var unit: u16 = 0x20;
    while (unit < 0x7F) : (unit += 1) {
        const byte = [_]u8{@intCast(unit)};
        const estimated: f64 = @floatCast(estimatorAdvanceEm(canvas.default_sans_font_id, &byte));
        const shaped = try coreTextGlyphAdvanceEm(font, size, unit);
        worst = @max(worst, @abs(estimated - shaped));
    }
    try testing.expect(worst <= 0.001);

    // Multibyte sample set (all BMP, one UTF-16 unit each).
    for (covered_multibyte_samples) |sample| {
        const codepoint = try std.unicode.utf8Decode(sample);
        const estimated: f64 = @floatCast(estimatorAdvanceEm(canvas.default_sans_font_id, sample));
        const shaped = try coreTextGlyphAdvanceEm(font, size, @intCast(codepoint));
        try testing.expect(@abs(estimated - shaped) <= 0.001);
    }

    // Whole lines through CTLine (the provider's shaping path): the
    // estimator must land within 2.5% — the kerning the estimator
    // deliberately omits.
    const line_samples = [_][]const u8{
        "All notes",
        "6 tracks · 2:41",
        "The quick brown fox jumps over the lazy dog.",
        "Search customers — no API tokens to manage",
    };
    for (line_samples) |sample| {
        const estimated: f64 = @floatCast(text_metrics.estimateTextWidthForFont(canvas.default_sans_font_id, sample, 1.0));
        const shaped = try coreTextLineWidthEm(font, size, sample);
        try testing.expect(shaped > 0);
        try testing.expect(@abs(estimated - shaped) / shaped <= 0.025);
    }
}

test "CoreText cascades codepoints the bundled face lacks" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;

    // The packet host draws text through the system string stack, which
    // falls back through CoreText's cascade for glyphs the resolved font
    // lacks — that is the live no-tofu guarantee for DYNAMIC strings
    // (GitHub markdown ballot boxes et al). Shape them behind the bundled
    // face itself: the line must come back with real positive width (a
    // face without cascade answers .notdef zero-ink), and the width class
    // must be the one the estimator's 0.8 em symbol fallback models —
    // clearly wider than the face's 0.6 em .notdef, at most a full em.
    const size: f64 = 1000;
    const font = try bundledCoreTextFont(size);
    defer CFRelease(font);

    for ([_][]const u8{ "☐", "☑" }) |sample| {
        // The bundled face itself has no glyph (that is why the reference
        // renderer draws its documented .notdef block)...
        const codepoint = try std.unicode.utf8Decode(sample);
        try testing.expectEqual(@as(u16, 0), font_ttf.geist_regular.glyphIndex(codepoint));
        // ...but the shaped line cascades to a real symbol font.
        const shaped = try coreTextLineWidthEm(font, size, sample);
        try testing.expect(shaped >= 0.7);
        try testing.expect(shaped <= 1.0);
    }
}
