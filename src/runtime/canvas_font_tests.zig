//! Runtime canvas font registry tests: registration validation and
//! capacity bounds (loud, one-past-budget), hostile/truncated font
//! files, the registration-time glyph-budget gate (over-declaring
//! `maxp` refused whole; the real Noto Sans JP accepted and outlining
//! dense kanji when the /tmp fixture is present), the font-aware
//! measure provider, pixel parity between the present path and the
//! reference screenshot path for a registered face, and the UiApp
//! `Options.fonts` startup seam.
//!
//! The registered fixture is the ALREADY-BUNDLED Geist Mono bytes
//! (`canvas.font_ttf.geist_mono_bytes`) under a registered id: the
//! bundled face doubles as a known-good registered face, so parity can
//! assert byte-identical pixels against the built-in mono id without
//! shipping any new font binary.

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const canvas_limits = @import("canvas_limits.zig");
const ui_app_model = @import("ui_app.zig");
const support = @import("test_support.zig");

const platform = support.platform;
const App = support.App;
const TestHarness = support.TestHarness;

const registered_font_id: canvas.FontId = canvas.min_registered_font_id;
const mono_bytes = canvas.font_ttf.geist_mono_bytes;

fn startedGpuHarness(allocator: std.mem.Allocator) !*TestHarness() {
    const harness = try TestHarness().create(allocator, .{ .size = geometry.SizeF.init(240, 140) });
    errdefer harness.destroy(allocator);
    harness.null_platform.gpu_surfaces = true;
    return harness;
}

const RegistryApp = struct {
    fn app(self: *@This()) App {
        return .{ .context = self, .name = "canvas-font-registry", .source = platform.WebViewSource.html("<h1>Fonts</h1>") };
    }
};

test "canvas font registry validates ids, bytes, and capacity" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: RegistryApp = .{};
    try harness.start(app_state.app());

    // Id validation: 0 is the "inherit run font" sentinel, everything
    // below the registered floor belongs to built-in faces.
    try std.testing.expectError(error.InvalidFontId, harness.runtime.registerCanvasFont(0, mono_bytes));
    try std.testing.expectError(error.ReservedFontId, harness.runtime.registerCanvasFont(1, mono_bytes));
    try std.testing.expectError(error.ReservedFontId, harness.runtime.registerCanvasFont(canvas.min_registered_font_id - 1, mono_bytes));
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.registeredCanvasFontCount());

    // Over the per-font budget: loud, one past the documented constant,
    // registers nothing.
    const oversized = try std.testing.allocator.alloc(u8, canvas_limits.max_registered_canvas_font_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 0);
    try std.testing.expectError(error.FontTooLarge, harness.runtime.registerCanvasFont(registered_font_id, oversized));
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.registeredCanvasFontCount());

    // A good registration resolves through the registry.
    try harness.runtime.registerCanvasFont(registered_font_id, mono_bytes);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.registeredCanvasFontCount());
    const face = harness.runtime.registeredCanvasFontFace(registered_font_id).?;
    try std.testing.expect(face.glyphIndex('A') != 0);
    try std.testing.expect(harness.runtime.registeredCanvasFontFace(registered_font_id + 1) == null);

    // Registered ids are permanent: re-use fails loudly (atlas caches key
    // glyphs by font id with no content fingerprint).
    try std.testing.expectError(error.FontIdInUse, harness.runtime.registerCanvasFont(registered_font_id, mono_bytes));
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.registeredCanvasFontCount());

    // Fill every slot; the one-past registration overflows loudly.
    var id: canvas.FontId = registered_font_id + 1;
    while (harness.runtime.registeredCanvasFontCount() < canvas_limits.max_registered_canvas_fonts) : (id += 1) {
        try harness.runtime.registerCanvasFont(id, mono_bytes);
    }
    try std.testing.expectError(error.FontRegistryFull, harness.runtime.registerCanvasFont(id, mono_bytes));
    try std.testing.expectEqual(canvas_limits.max_registered_canvas_fonts, harness.runtime.registeredCanvasFontCount());

    // The registered resource set hands both renderers one entry per id.
    const resources = harness.runtime.registeredCanvasFonts();
    try std.testing.expectEqual(canvas_limits.max_registered_canvas_fonts, resources.len);
    try std.testing.expectEqual(registered_font_id, resources[0].id);
}

test "hostile and truncated font files fail loud at registration and never corrupt the registry" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: RegistryApp = .{};
    try harness.start(app_state.app());

    // Garbage bytes.
    try std.testing.expectError(error.FontParseFailed, harness.runtime.registerCanvasFont(registered_font_id, "definitely not a font"));

    // Truncations of a real face at coarse strides: registration must
    // reject every prefix (the table directory always points past a
    // truncated file) with a recoverable error — never a crash, never a
    // partial slot.
    var len: usize = 0;
    while (len < mono_bytes.len) : (len += if (len < 64) 7 else 4099) {
        try std.testing.expectError(error.FontParseFailed, harness.runtime.registerCanvasFont(registered_font_id, mono_bytes[0..len]));
        try std.testing.expectEqual(@as(usize, 0), harness.runtime.registeredCanvasFontCount());
    }

    // Bit-flipped table directory: parse rejects or (for flips in table
    // payloads the directory does not bound) glyph reads stay
    // bounds-checked. Either way registration state stays consistent.
    var corrupted = try std.testing.allocator.dupe(u8, mono_bytes);
    defer std.testing.allocator.free(corrupted);
    var offset: usize = 4;
    var flip_id: canvas.FontId = registered_font_id;
    while (offset < 256) : (offset += 13) {
        // Leave one slot free so the good-face registration below always
        // has room (some flips — table tags the parser does not require,
        // checksum bytes — are legitimately tolerated and take a slot).
        if (harness.runtime.registeredCanvasFontCount() >= canvas_limits.max_registered_canvas_fonts - 1) break;
        corrupted[offset] ^= 0xFF;
        defer corrupted[offset] ^= 0xFF;
        const before = harness.runtime.registeredCanvasFontCount();
        if (harness.runtime.registerCanvasFont(flip_id, corrupted)) |_| {
            // A flip the parser legitimately tolerates: the slot is
            // committed and the face answers lookups without crashing.
            try std.testing.expectEqual(before + 1, harness.runtime.registeredCanvasFontCount());
            _ = harness.runtime.registeredCanvasFontFace(flip_id).?.glyphIndex('A');
            flip_id += 1;
        } else |_| {
            try std.testing.expectEqual(before, harness.runtime.registeredCanvasFontCount());
        }
    }

    // Every teaching diagnostic is available for the failures above.
    try std.testing.expect(canvas.font_ttf.parseFailureReason("definitely not a font") != null);
    try std.testing.expect(canvas.font_ttf.parseFailureReason(mono_bytes[0 .. mono_bytes.len / 2]) != null);

    // The registry still accepts a good face after the hostile parade.
    try harness.runtime.registerCanvasFont(flip_id, mono_bytes);
    try std.testing.expect(harness.runtime.registeredCanvasFontFace(flip_id) != null);
}

test "registered faces measure with their own advances through the runtime provider" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: RegistryApp = .{};
    try harness.start(app_state.app());

    // The null platform has no host measurement: no provider until a
    // font registers (layout stays on the estimator, byte-identical to
    // before this seam existed).
    try std.testing.expect(harness.runtime.textMeasureProvider() == null);

    try harness.runtime.registerCanvasFont(registered_font_id, mono_bytes);
    const provider = harness.runtime.textMeasureProvider().?;

    // Registered id: the parsed face's advances — the mono pitch, not
    // the sans advances the id-keyed estimator would guess.
    const registered_width = provider.measureWidth(registered_font_id, 10.0, "Hello");
    try std.testing.expectApproxEqAbs(@as(f32, 5 * 10.0 * canvas.mono_advance_em), registered_width, 0.001);

    // Built-in ids keep the deterministic estimator exactly.
    const sans_width = provider.measureWidth(canvas.default_sans_font_id, 10.0, "Hello");
    try std.testing.expectApproxEqAbs(canvas.estimateTextWidthForFont(canvas.default_sans_font_id, "Hello", 10.0), sans_width, 0.0001);

    // Tokens stamped through the runtime carry the provider, and the
    // pointer is stable frame to frame.
    const tokens = harness.runtime.tokensWithTextMeasure(.{});
    try std.testing.expect(tokens.text_measure == provider);
    try std.testing.expect(harness.runtime.tokensWithTextMeasure(.{}).text_measure == provider);
}

test "registered faces answer the batched advances seam identically to per-prefix widths" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: RegistryApp = .{};
    try harness.start(app_state.app());

    const generation_before = canvas.textMeasureGeneration();
    try harness.runtime.registerCanvasFont(registered_font_id, mono_bytes);
    // Registration changes what the seam answers for the id: cached
    // advances and retained wrap results must miss.
    try std.testing.expect(canvas.textMeasureGeneration() > generation_before);

    const provider = harness.runtime.textMeasureProvider().?;
    try std.testing.expect(provider.measure_advances_fn != null);

    // Batched advances sum to exactly the per-prefix width for both a
    // registered id (face advances) and a built-in id (estimator
    // advances) — the additive property the parity law rides on.
    const text = "Hello 123 \xc3\xa9";
    const ids = [_]canvas.FontId{ registered_font_id, canvas.default_sans_font_id };
    for (ids) |font_id| {
        var advances: [text.len]f32 = undefined;
        try std.testing.expect(provider.measureAdvances(font_id, 10.0, text, &advances));
        var sum: f32 = 0;
        for (advances) |advance| sum += advance;
        try std.testing.expectEqual(provider.measureWidth(font_id, 10.0, text), sum);
    }
}

/// Byte offset of the `maxp` table in a TrueType file (test fixture
/// helper for building over-declaring faces out of the bundled bytes).
fn maxpTableOffset(bytes: []const u8) usize {
    const table_count = std.mem.readInt(u16, bytes[4..6], .big);
    var index: usize = 0;
    while (index < table_count) : (index += 1) {
        const record = 12 + index * 16;
        if (std.mem.eql(u8, bytes[record .. record + 4], "maxp")) {
            return std.mem.readInt(u32, bytes[record + 8 ..][0..4], .big);
        }
    }
    unreachable; // the bundled faces always carry maxp
}

/// The bundled mono bytes with `maxp.maxPoints` patched one past the
/// glyph-point budget: a face that DECLARES denser glyphs than the
/// outline pipeline's budgets and must be refused whole at
/// registration, never degraded per glyph at render time.
fn overBudgetFontBytes(allocator: std.mem.Allocator) ![]u8 {
    const patched = try allocator.dupe(u8, mono_bytes);
    const maxp = maxpTableOffset(patched);
    std.mem.writeInt(u16, patched[maxp + 6 ..][0..2], @intCast(canvas.font_ttf.max_glyph_points + 1), .big);
    return patched;
}

test "a face declaring glyphs denser than the budgets is refused at registration" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: RegistryApp = .{};
    try harness.start(app_state.app());

    const patched = try overBudgetFontBytes(std.testing.allocator);
    defer std.testing.allocator.free(patched);

    try std.testing.expectError(error.FontExceedsGlyphBudgets, harness.runtime.registerCanvasFont(registered_font_id, patched));
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.registeredCanvasFontCount());

    // The teaching machinery names the refusal: parse-reason carries the
    // budget sentence, and the declared maxima expose the face's own
    // numbers for callers that format (UiApp's fonts teaching).
    try std.testing.expect(std.mem.indexOf(u8, canvas.font_ttf.parseFailureReason(patched).?, "budgets") != null);
    const maxima = canvas.font_ttf.declaredGlyphMaxima(patched).?;
    try std.testing.expectEqual(@as(u16, @intCast(canvas.font_ttf.max_glyph_points + 1)), maxima.points);
    try std.testing.expect(!maxima.withinBudgets());

    // No partial slot: the honest twin registers under the same id.
    try harness.runtime.registerCanvasFont(registered_font_id, mono_bytes);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.registeredCanvasFontCount());
}

test "the real Noto Sans JP face registers and outlines dense kanji (guarded by /tmp/NotoSansJP.ttf)" {
    // Ground-truth end-to-end proof with the face the budgets were
    // sized from: the Google Fonts TrueType build of Noto Sans JP
    // (OFL). Font binaries stay out of the repo, so the fixture is a
    // local download; environments without it skip.
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "/tmp/NotoSansJP.ttf",
        std.testing.allocator,
        .limited(canvas_limits.max_registered_canvas_font_bytes),
    ) catch return error.SkipZigTest;
    defer std.testing.allocator.free(bytes);

    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: RegistryApp = .{};
    try harness.start(app_state.app());

    // Registration passes the byte bound, the maxp gate, and the host
    // seam — the whole registration-time validation doctrine.
    try harness.runtime.registerCanvasFont(registered_font_id, bytes);
    const face = harness.runtime.registeredCanvasFontFace(registered_font_id).?;

    // Everyday-dense kanji resolve to real outlines, not notdef blocks:
    // 鬱 U+9B31 measures 237 points / 26 contours in this face — far
    // past the old Latin-sized 128-point/24-contour budgets that made
    // it render as a block.
    const dense_kanji = [_]u21{ 0x9B31, 0x9A5A, 0x7C60, 0x9451 }; // 鬱 驚 籠 鑑
    for (dense_kanji) |codepoint| {
        const glyph = face.glyphIndex(codepoint);
        try std.testing.expect(glyph != 0);
        var builder = canvas.vector.PathBuilder(2048){};
        try face.glyphOutline(glyph, canvas.Affine.identity(), &builder);
        try std.testing.expect(builder.slice().len > 0);
    }

    // The dense outline rasterizes within the vector budgets at body
    // and headline sizes.
    const InkCounter = struct {
        covered: usize = 0,
        pub fn pixel(self: *@This(), x: i32, y: i32, coverage: f32) void {
            _ = x;
            _ = y;
            if (coverage > 0) self.covered += 1;
        }
    };
    for ([_]f32{ 16, 96 }) |size| {
        const glyph = face.glyphIndex(0x9B31);
        const scale = size / face.units_per_em;
        var builder = canvas.vector.PathBuilder(2048){};
        try face.glyphOutline(glyph, .{ .a = scale, .b = 0, .c = 0, .d = -scale, .tx = 4, .ty = size }, &builder);
        var counter = InkCounter{};
        try canvas.vector.fillPath(
            builder.slice(),
            canvas.Affine.identity(),
            .nonzero,
            canvas.vector.default_tolerance,
            .{ .x0 = 0, .y0 = 0, .x1 = 128, .y1 = 128 },
            &counter,
        );
        try std.testing.expect(counter.covered > 0);
    }

    // Layout measures the registered face's own advances for the kanji.
    const provider = harness.runtime.textMeasureProvider().?;
    try std.testing.expect(provider.measureWidth(registered_font_id, 16.0, "鬱") > 0);
}

fn installFontFixtureWidgets(harness: anytype) !void {
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 240, 140),
    });
    const controls = [_]canvas.Widget{.{
        .id = 2,
        .kind = .text,
        .frame = geometry.RectF.init(10, 10, 220, 40),
        .text = "Hello 123",
    }};
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &controls }, geometry.RectF.init(0, 0, 240, 140), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
}

fn fontFixtureTokens(runtime: *core.Runtime, font_id: canvas.FontId) canvas.DesignTokens {
    var tokens = canvas.DesignTokens{};
    tokens.typography.font_id = font_id;
    return runtime.tokensWithTextMeasure(tokens);
}

fn fontFixtureScreenshot(harness: anytype, allocator: std.mem.Allocator, font_id: canvas.FontId) ![]u8 {
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", fontFixtureTokens(&harness.runtime, font_id));
    const pixel_size = try harness.runtime.canvasScreenshotPixelSize(1, "canvas", null);
    const pixels = try allocator.alloc(u8, pixel_size.byte_len);
    defer allocator.free(pixels);
    const scratch = try allocator.alloc(u8, pixel_size.byte_len);
    defer allocator.free(scratch);
    const screenshot = try harness.runtime.renderCanvasScreenshot(1, "canvas", null, pixels, scratch);
    return allocator.dupe(u8, screenshot.rgba8);
}

test "a registered face renders pixel-identically on the present path and the reference path" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: RegistryApp = .{};
    try harness.start(app_state.app());
    try installFontFixtureWidgets(harness);

    try harness.runtime.registerCanvasFont(registered_font_id, mono_bytes);

    // Present path: the software pixel present (the packet fallback and
    // GTK-class platforms' real path) planned through the same
    // font-resource threading every present uses.
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", fontFixtureTokens(&harness.runtime, registered_font_id));
    const pixel_size = try harness.runtime.canvasScreenshotPixelSize(1, "canvas", null);
    const present_pixels = try std.testing.allocator.alloc(u8, pixel_size.byte_len);
    defer std.testing.allocator.free(present_pixels);
    const present_scratch = try std.testing.allocator.alloc(u8, pixel_size.byte_len);
    defer std.testing.allocator.free(present_scratch);
    const clear_color = (canvas.DesignTokens{}).colors.background;
    _ = try harness.runtime.presentNextCanvasFramePixels(1, "canvas", .{ .full_repaint = true }, harness.runtime.canvasFrameScratchStorage(), present_pixels, present_scratch, clear_color);

    // Reference path: the screenshot renderer, planned independently.
    const reference = try fontFixtureScreenshot(harness, std.testing.allocator, registered_font_id);
    defer std.testing.allocator.free(reference);
    try std.testing.expectEqualSlices(u8, present_pixels[0..reference.len], reference);

    // Cross-check against the face itself: the registered id carries the
    // bundled mono bytes, so its pixels must be byte-identical to the
    // built-in mono id — layout (advances) AND ink (outlines) both
    // honored the registered face.
    const builtin_mono = try fontFixtureScreenshot(harness, std.testing.allocator, canvas.default_mono_font_id);
    defer std.testing.allocator.free(builtin_mono);
    try std.testing.expectEqualSlices(u8, builtin_mono, reference);

    // And it is genuinely a different face than the default sans — the
    // registered id changed the pixels, not just the fingerprints.
    const sans = try fontFixtureScreenshot(harness, std.testing.allocator, canvas.default_sans_font_id);
    defer std.testing.allocator.free(sans);
    try std.testing.expect(!std.mem.eql(u8, sans, reference));
}

// ------------------------------------------------ UiApp Options.fonts

const FontAppModel = struct { presses: u32 = 0 };
const FontAppMsg = union(enum) { press: void };
const FontApp = ui_app_model.UiApp(FontAppModel, FontAppMsg);

const font_app_canvas_label = "canvas";

fn fontAppUpdate(model: *FontAppModel, msg: FontAppMsg) void {
    switch (msg) {
        .press => model.presses += 1,
    }
}

fn fontAppView(ui: *FontApp.Ui, model: *const FontAppModel) FontApp.Ui.Node {
    _ = model;
    return ui.column(.{ .gap = 8, .padding = 12 }, .{
        ui.text(.{}, "Registered face body text"),
    });
}

fn fontAppTokens(model: *const FontAppModel) canvas.DesignTokens {
    _ = model;
    var tokens = canvas.DesignTokens{};
    tokens.typography.font_id = registered_font_id;
    return tokens;
}

const font_app_views = [_]app_manifest.ShellView{
    .{ .label = font_app_canvas_label, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const font_app_windows = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Fonts",
    .width = 240,
    .height = 200,
    .views = &font_app_views,
}};
const font_app_scene: app_manifest.ShellConfig = .{ .windows = &font_app_windows };

fn fontAppOptions(fonts: []const FontApp.FontRegistration) FontApp.Options {
    return .{
        .name = "ui-app-fonts",
        .scene = font_app_scene,
        .canvas_label = font_app_canvas_label,
        .tokens_fn = fontAppTokens,
        .update = fontAppUpdate,
        .view = fontAppView,
        .fonts = fonts,
    };
}

test "ui app registers declared fonts before the first view build" {
    const harness = try TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(240, 200) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const fonts = [_]FontApp.FontRegistration{.{
        .id = registered_font_id,
        .name = "GeistMono-Regular.ttf",
        .ttf = mono_bytes,
    }};
    const app_state = try std.testing.allocator.create(FontApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = FontApp.init(std.testing.allocator, .{}, fontAppOptions(&fonts));
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = font_app_canvas_label,
        .size = geometry.SizeF.init(240, 200),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.registeredCanvasFontCount());
    try std.testing.expect(harness.runtime.registeredCanvasFontFace(registered_font_id) != null);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.dispatchErrors().len);
}

test "ui app declared font failures are teaching errors, not crashes or silent fallbacks" {
    const harness = try TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(240, 200) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const fonts = [_]FontApp.FontRegistration{.{
        .id = registered_font_id,
        .name = "Broken.ttf",
        .ttf = mono_bytes[0..512],
    }};
    const app_state = try std.testing.allocator.create(FontApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = FontApp.init(std.testing.allocator, .{}, fontAppOptions(&fonts));
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);

    // Production loops degrade dispatch errors into the loud error
    // channel (error event + teaching log) instead of dying; mirror that
    // policy here (the harness default propagates so capacity bugs fail
    // tests).
    harness.runtime.dispatch_error_policy = .degrade;

    // The installing frame surfaces the failure through the dispatch
    // error channel and the app stays alive.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = font_app_canvas_label,
        .size = geometry.SizeF.init(240, 200),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.registeredCanvasFontCount());
    const first_errors = harness.runtime.dispatchErrorTotal();
    try std.testing.expect(first_errors > 0);

    // Registration does not retry every frame: a second frame installs
    // the app without re-raising a registration error per frame.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = font_app_canvas_label,
        .size = geometry.SizeF.init(240, 200),
        .scale_factor = 1,
        .frame_index = 2,
        .timestamp_ns = 2_000_000,
        .nonblank = true,
    } });
    try std.testing.expect(app_state.installed);
    try std.testing.expectEqual(first_errors, harness.runtime.dispatchErrorTotal());
}

test "ui app fonts option surfaces the glyph-budget refusal as a teaching error" {
    const harness = try TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(240, 200) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const patched = try overBudgetFontBytes(std.testing.allocator);
    defer std.testing.allocator.free(patched);

    const fonts = [_]FontApp.FontRegistration{.{
        .id = registered_font_id,
        .name = "TooDense.ttf",
        .ttf = patched,
    }};
    const app_state = try std.testing.allocator.create(FontApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = FontApp.init(std.testing.allocator, .{}, fontAppOptions(&fonts));
    defer app_state.deinit();
    const app = app_state.app();
    try harness.start(app);
    harness.runtime.dispatch_error_policy = .degrade;

    // The installing frame surfaces the refusal through the dispatch
    // error channel (the warn log names the face's declared maxima
    // against the budgets); nothing registers, the app stays alive.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = font_app_canvas_label,
        .size = geometry.SizeF.init(240, 200),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 1_000_000,
        .nonblank = true,
    } });
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.registeredCanvasFontCount());
    try std.testing.expect(harness.runtime.dispatchErrorTotal() > 0);
}
