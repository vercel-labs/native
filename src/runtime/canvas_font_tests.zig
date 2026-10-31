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

test "a fresh runtime allocates zero font bytes until a registration happens" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: RegistryApp = .{};

    // Count every runtime-allocator call: construction, startup, and
    // frames perform NONE — font byte storage is on-demand at
    // registration, so a fontless runtime carries zero font bytes. (The
    // regression pinned here: a reservation-shaped slot pool at the
    // 24 MiB CJK bound embedded 192 MiB in every Runtime, doubling the
    // docs wasm preview host's per-tile memory before any font existed.)
    // The ownership allocator is frozen at init, so the test re-freezes
    // the field directly — equivalent to constructing with the counting
    // allocator, and safe exactly because no owned bytes exist yet.
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    harness.runtime.owned_allocator = counting.allocator();
    try harness.start(app_state.app());
    try std.testing.expectEqual(@as(usize, 0), counting.allocations);

    // Even an allocator that refuses everything leaves the runtime
    // fully operational until a registration demands memory — and that
    // failure is loud and recoverable, never a partial slot. (Still
    // nothing owned, so re-freezing stays equivalent to init capture.)
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    harness.runtime.owned_allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, harness.runtime.registerCanvasFont(registered_font_id, mono_bytes));
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.registeredCanvasFontCount());

    // Registration is the first allocation: exactly one, exactly the
    // file's size (freed by Runtime.deinit through harness.destroy —
    // the leak-checked test allocator backs it).
    harness.runtime.owned_allocator = counting.allocator();
    try harness.runtime.registerCanvasFont(registered_font_id, mono_bytes);
    try std.testing.expectEqual(@as(usize, 1), counting.allocations);
    try std.testing.expectEqual(mono_bytes.len, counting.allocated_bytes);
}

test "deinit frees font bytes through the init-frozen allocator even after options.allocator is mutated" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: RegistryApp = .{};
    try harness.start(app_state.app());

    // Freeze a counting allocator as the runtime's owner (equivalent to
    // constructing with it — nothing is owned yet) and register a face
    // through it.
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    harness.runtime.owned_allocator = counting.allocator();
    try harness.runtime.registerCanvasFont(registered_font_id, mono_bytes);
    try std.testing.expectEqual(@as(usize, 1), counting.allocations);
    try std.testing.expectEqual(@as(usize, 0), counting.deallocations);

    // The hazard under test: `Runtime.options` is public and mutable, so
    // an embedder can swap `options.allocator` AFTER fonts registered.
    // Ownership must not retarget — the deinit free has to hit the
    // allocator that made the bytes, not whatever the option points at
    // by teardown time.
    var mutated = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    harness.runtime.options.allocator = mutated.allocator();
    harness.runtime.deinit();

    // Counts balance on the original identity; the mutated allocator
    // saw zero activity in either direction.
    try std.testing.expectEqual(counting.allocations, counting.deallocations);
    try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
    try std.testing.expectEqual(@as(usize, 0), mutated.allocations);
    try std.testing.expectEqual(@as(usize, 0), mutated.deallocations);
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

/// The bundled mono bytes with `maxp.maxCompositePoints` (offset 10)
/// patched one past the flattened-composite budget: modest simple
/// maxima, composite flattening the path builder could not hold — the
/// exact face shape a simple-only gate would admit and then silently
/// block at render time.
fn overCompositeBudgetFontBytes(allocator: std.mem.Allocator) ![]u8 {
    const patched = try allocator.dupe(u8, mono_bytes);
    const maxp = maxpTableOffset(patched);
    std.mem.writeInt(u16, patched[maxp + 10 ..][0..2], @intCast(canvas.font_ttf.max_composite_points + 1), .big);
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

test "a face declaring flattened composites denser than the budgets is refused at registration" {
    const harness = try startedGpuHarness(std.testing.allocator);
    defer harness.destroy(std.testing.allocator);
    var app_state: RegistryApp = .{};
    try harness.start(app_state.app());

    // Simple maxima untouched (well within budget) — only the
    // flattened-composite declaration is over. A gate reading simple
    // maxima alone admits this face; its composites then overflow the
    // reference path builder at render time and degrade to blocks, the
    // exact silent failure registration-time validation forbids.
    const patched = try overCompositeBudgetFontBytes(std.testing.allocator);
    defer std.testing.allocator.free(patched);

    try std.testing.expectError(error.FontExceedsGlyphBudgets, harness.runtime.registerCanvasFont(registered_font_id, patched));
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.registeredCanvasFontCount());

    // The teaching names the composite budgets and the declared maxima
    // expose the face's own composite numbers.
    const reason = canvas.font_ttf.parseFailureReason(patched).?;
    try std.testing.expect(std.mem.indexOf(u8, reason, "flattened composite") != null);
    const maxima = canvas.font_ttf.declaredGlyphMaxima(patched).?;
    try std.testing.expectEqual(@as(u16, @intCast(canvas.font_ttf.max_composite_points + 1)), maxima.composite_points);
    try std.testing.expect(!maxima.withinBudgets());

    // The unpatched twin registers: the gate reads the declaration, not
    // the patch's collateral.
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

const FontAppModel = struct { presses: u32 = 0, show_uncovered_cjk: bool = false };
const FontAppMsg = union(enum) { press: void, show_uncovered_cjk: void };
const FontApp = ui_app_model.UiApp(FontAppModel, FontAppMsg);

const font_app_canvas_label = "canvas";

fn fontAppUpdate(model: *FontAppModel, msg: FontAppMsg) void {
    switch (msg) {
        .press => model.presses += 1,
        .show_uncovered_cjk => model.show_uncovered_cjk = true,
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

// ---------------------------------------------- the Chinese receipt

/// Committed CJK fixture: Noto Sans SC (OFL — the license rides beside
/// the file in testdata/fonts/OFL.txt), instanced at wght=400 from the
/// Google Fonts variable TrueType build and subsetted to exactly the
/// receipt string's four ideographs plus notdef (2.2 KB — the license
/// permits subsetting; full font binaries stay out of the repo). The
/// subset keeps the format-4 unicode cmap, real `glyf` outlines, and
/// the full font's truthful `maxp` declaration (584 points / 84
/// contours — past the old Latin-sized budgets, inside the CJK-sized
/// ones), so registration exercises the real gate and rendering inks
/// real Han ideograph outlines, deterministically, on every CI host.
const cjk_receipt_bytes = @embedFile("testdata/fonts/NotoSansSC-Receipt.ttf");

/// 你好世界 — "Hello, world".
const cjk_receipt_text = "\u{4F60}\u{597D}\u{4E16}\u{754C}";

/// 中文字体 — "Chinese font": four ideographs the subsetted fixture
/// face deliberately does NOT map (the subset carries exactly the
/// receipt string's four glyphs plus notdef; the test pins the gap
/// with glyphIndex() == 0 before relying on it). Rendered with the
/// SAME registered face, this string can only draw four notdef boxes
/// — the self-calibrating tofu baseline the receipt compares against.
const cjk_uncovered_text = "\u{4E2D}\u{6587}\u{5B57}\u{4F53}";

fn cjkAppView(ui: *FontApp.Ui, model: *const FontAppModel) FontApp.Ui.Node {
    return ui.column(.{ .gap = 8, .padding = 12 }, .{
        ui.text(.{}, if (model.show_uncovered_cjk) cjk_uncovered_text else cjk_receipt_text),
    });
}

test "the Chinese receipt: a scaffold-shaped app registers a CJK face and renders real glyphs, not tofu" {
    const harness = try TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(240, 200) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    // The scaffold shape: fonts declared on Options.fonts, tokens
    // pointing the typography face slot at the registered id, Chinese
    // text in the view.
    const fonts = [_]FontApp.FontRegistration{.{
        .id = registered_font_id,
        .name = "NotoSansSC-Receipt.ttf",
        .ttf = cjk_receipt_bytes,
    }};
    var options = fontAppOptions(&fonts);
    options.view = cjkAppView;
    const app_state = try std.testing.allocator.create(FontApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = FontApp.init(std.testing.allocator, .{}, options);
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
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.dispatchErrors().len);
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.registeredCanvasFontCount());

    // Per-glyph receipt: every ideograph resolves to its own real glyph
    // in the registered face (the bundled face maps NONE of them — the
    // exact gap the registration closes) and rasterizes with nonzero
    // ink at body and headline sizes.
    const face = harness.runtime.registeredCanvasFontFace(registered_font_id).?;
    const InkCounter = struct {
        covered: usize = 0,
        pub fn pixel(self: *@This(), x: i32, y: i32, coverage: f32) void {
            _ = x;
            _ = y;
            if (coverage > 0) self.covered += 1;
        }
    };
    var seen_glyphs: [4]u16 = undefined;
    var index: usize = 0;
    var glyph_count: usize = 0;
    while (index < cjk_receipt_text.len) : (glyph_count += 1) {
        const len = try std.unicode.utf8ByteSequenceLength(cjk_receipt_text[index]);
        const codepoint = try std.unicode.utf8Decode(cjk_receipt_text[index .. index + len]);
        index += len;

        try std.testing.expectEqual(@as(u16, 0), canvas.font_ttf.geist_regular.glyphIndex(codepoint));
        const glyph = face.glyphIndex(codepoint);
        try std.testing.expect(glyph != 0);
        // cmap distinguishes the codepoints — four ideographs, four
        // distinct glyphs, never one shared fallback shape.
        for (seen_glyphs[0..glyph_count]) |seen| try std.testing.expect(seen != glyph);
        seen_glyphs[glyph_count] = glyph;

        for ([_]f32{ 16, 40 }) |size| {
            const scale = size / face.units_per_em;
            var builder = canvas.vector.PathBuilder(2048){};
            try face.glyphOutline(glyph, .{ .a = scale, .b = 0, .c = 0, .d = -scale, .tx = 4, .ty = size }, &builder);
            try std.testing.expect(builder.slice().len > 0);
            var counter = InkCounter{};
            try canvas.vector.fillPath(
                builder.slice(),
                canvas.Affine.identity(),
                .nonzero,
                canvas.vector.default_tolerance,
                .{ .x0 = 0, .y0 = 0, .x1 = 64, .y1 = 64 },
                &counter,
            );
            try std.testing.expect(counter.covered > 0);
        }
    }
    try std.testing.expectEqual(@as(usize, 4), glyph_count);

    // Layout measures the ideographs with the registered face's own
    // advances, so measured line breaking agrees with the inked glyphs.
    const provider = harness.runtime.textMeasureProvider().?;
    try std.testing.expect(provider.measureWidth(registered_font_id, 16.0, cjk_receipt_text) > 0);

    // End-to-end pixels through the deterministic reference renderer —
    // the same path Windows and Linux present. The registered face
    // draws the string as real outlines; the same view under the
    // bundled face can only draw notdef boxes, so the two screenshots
    // MUST differ. That difference is the receipt: the Chinese text on
    // screen came from the registered face, not tofu.
    const registered_shot = try fontFixtureScreenshot(harness, std.testing.allocator, registered_font_id);
    defer std.testing.allocator.free(registered_shot);
    const tofu_shot = try fontFixtureScreenshot(harness, std.testing.allocator, canvas.default_sans_font_id);
    defer std.testing.allocator.free(tofu_shot);
    var nonblank = false;
    var pixel: usize = 0;
    while (pixel + 4 <= registered_shot.len) : (pixel += 4) {
        if (registered_shot[pixel + 3] != 0 and (registered_shot[pixel] != 0 or registered_shot[pixel + 1] != 0 or registered_shot[pixel + 2] != 0)) {
            nonblank = true;
            break;
        }
    }
    try std.testing.expect(nonblank);
    try std.testing.expect(!std.mem.eql(u8, registered_shot, tofu_shot));

    // Self-calibrating tofu control: the bundled-face comparison above
    // proves the pixels changed with the face, not that they are real
    // ideographs — a renderer that wrongly resolved every ideograph to
    // the REGISTERED face's notdef glyph and inked that glyph's own
    // outline would still differ from the bundled shot (a different
    // face's fallback pixels) and still pass nonblank. Render the same
    // view with the same registered face showing a string the fixture
    // face genuinely does not cover — first pinning that gap per
    // codepoint — so the control shot IS this face's
    // everything-uncovered rendering through the identical pipeline.
    // Had the receipt string resolved to notdef, the two shots would
    // match: same face, same per-glyph fallback, same advances.
    // Differing proves the receipt pixels are real ideograph outlines,
    // not any face's fallback.
    var uncovered_index: usize = 0;
    while (uncovered_index < cjk_uncovered_text.len) {
        const len = try std.unicode.utf8ByteSequenceLength(cjk_uncovered_text[uncovered_index]);
        const codepoint = try std.unicode.utf8Decode(cjk_uncovered_text[uncovered_index .. uncovered_index + len]);
        uncovered_index += len;
        try std.testing.expectEqual(@as(u16, 0), face.glyphIndex(codepoint));
    }
    try app_state.dispatch(&harness.runtime, 1, .show_uncovered_cjk);
    const uncovered_shot = try fontFixtureScreenshot(harness, std.testing.allocator, registered_font_id);
    defer std.testing.allocator.free(uncovered_shot);
    try std.testing.expect(!std.mem.eql(u8, registered_shot, uncovered_shot));
}

// ------------------- late registration re-measures installed layouts

/// 你好 SDK — mixed CJK + Latin, chosen so the measured width MUST move
/// when the fixture face joins late. Pure-CJK width would not move: the
/// bundled estimator's East Asian wide fallback charges 1.0 em and the
/// fixture's ideographs really advance 1.0 em. The Latin tail is what
/// moves — the estimator charges Geist's own sub-em ASCII advances,
/// while the fixture face (subsetted to four ideographs plus notdef)
/// answers every ASCII codepoint with its 1.0 em notdef advance, the
/// documented no-cascade fallback registered faces take for uncovered
/// codepoints.
const late_mixed_text = "\u{4F60}\u{597D} SDK";

const late_window_label = "late-panel";
const late_window_canvas_label = "late-panel-canvas";

fn lateFontAppView(ui: *FontApp.Ui, model: *const FontAppModel) FontApp.Ui.Node {
    _ = model;
    // A row lays text out at its MEASURED intrinsic width (a column's
    // default cross alignment stretches children to the column width),
    // so this widget's frame is a direct function of what the
    // measurement seam answers for the string.
    return ui.row(.{ .gap = 8, .padding = 12 }, .{
        ui.text(.{}, late_mixed_text),
    });
}

fn lateFontAppWindows(model: *const FontAppModel, scratch: *FontApp.WindowsScratch) []const FontApp.WindowDescriptor {
    _ = model;
    scratch.windows[0] = .{
        .label = late_window_label,
        .canvas_label = late_window_canvas_label,
        .title = "Late",
        .width = 240,
        .height = 200,
    };
    return scratch.windows[0..1];
}

fn lateFontAppWindowView(ui: *FontApp.Ui, model: *const FontAppModel, window_label: []const u8) FontApp.Ui.Node {
    std.debug.assert(std.mem.eql(u8, window_label, late_window_label));
    return lateFontAppView(ui, model);
}

/// The laid-out frame width of the view's one text widget.
fn lateTextFrameWidth(runtime: *core.Runtime, window_id: platform.WindowId, label: []const u8) !f32 {
    const layout = try runtime.canvasWidgetLayout(window_id, label);
    for (layout.nodes) |node| {
        if (node.widget.kind == .text and std.mem.eql(u8, node.widget.text, late_mixed_text)) return node.widget.frame.width;
    }
    return error.TestUnexpectedResult;
}

test "a face registered after install re-measures every installed surface's layout" {
    const harness = try TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(240, 200) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    // No declared fonts: the app installs measuring registered_font_id
    // (the tokens' face slot) through the bundled estimator, the exact
    // pre-registration state the fonts page's late-registration promise
    // starts from. A declared secondary window pins the multi-surface
    // half of the promise.
    var options = fontAppOptions(&.{});
    options.view = lateFontAppView;
    options.windows_fn = lateFontAppWindows;
    options.window_view = lateFontAppWindowView;
    const app_state = try std.testing.allocator.create(FontApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = FontApp.init(std.testing.allocator, .{}, options);
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

    // The always-declared panel window opened during the installing
    // rebuild's window reconcile; its own first frame installs its tree.
    const panel_id = blk: {
        var buffer: [platform.max_windows]platform.WindowInfo = undefined;
        for (harness.runtime.listWindows(&buffer)) |info| {
            if (std.mem.eql(u8, info.label, late_window_label)) break :blk info.id;
        }
        return error.TestUnexpectedResult;
    };
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = panel_id,
        .label = late_window_canvas_label,
        .size = geometry.SizeF.init(240, 200),
        .scale_factor = 1,
        .frame_index = 1,
        .timestamp_ns = 2_000_000,
        .nonblank = true,
    } });

    const main_before = try lateTextFrameWidth(&harness.runtime, 1, font_app_canvas_label);
    const panel_before = try lateTextFrameWidth(&harness.runtime, panel_id, late_window_canvas_label);
    try std.testing.expectEqual(main_before, panel_before);

    // Late registration through the runtime seam — the embedder path the
    // fonts page documents under the `Options.fonts` sugar.
    try harness.runtime.registerCanvasFont(registered_font_id, cjk_receipt_bytes);

    // The registration requested a frame for every open surface; ONE
    // arriving frame (the main canvas's here — arrival order is the
    // platform's) must re-measure every installed surface, not just the
    // surface whose frame landed.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = font_app_canvas_label,
        .size = geometry.SizeF.init(240, 200),
        .scale_factor = 1,
        .frame_index = 2,
        .timestamp_ns = 3_000_000,
        .nonblank = true,
    } });
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.dispatchErrors().len);

    const main_after = try lateTextFrameWidth(&harness.runtime, 1, font_app_canvas_label);
    const panel_after = try lateTextFrameWidth(&harness.runtime, panel_id, late_window_canvas_label);
    // Both surfaces now hold frames measured with the registered face's
    // own advances — the widths moved, and moved identically.
    try std.testing.expect(@abs(main_after - main_before) > 1);
    try std.testing.expect(@abs(panel_after - panel_before) > 1);
    try std.testing.expectEqual(main_after, panel_after);

    // The re-measured width IS the face-aware seam's answer scaled into
    // the frame, not merely a different guess: the face measures the
    // string wider than the estimator did (1.0 em notdef per ASCII
    // codepoint versus Geist's sub-em advances), so the frame grew.
    try std.testing.expect(main_after > main_before);
}

// ------------------------ late registration adopts only on success

/// Model for the failed-rebuild retry test below: `row_count` extra rows
/// join the measured text, so the test can push one rebuild past the
/// per-view widget budget and then heal it.
const RetryFontModel = struct {
    row_count: usize = 0,

    pub fn rows(model: *const RetryFontModel, arena: std.mem.Allocator) []const usize {
        const out = arena.alloc(usize, model.row_count) catch return &.{};
        for (out, 0..) |*slot, index| slot.* = index;
        return out;
    }
};
const RetryFontMsg = union(enum) { noop };
const RetryFontApp = ui_app_model.UiApp(RetryFontModel, RetryFontMsg);

fn retryFontUpdate(model: *RetryFontModel, msg: RetryFontMsg) void {
    _ = model;
    _ = msg;
}

fn retryFontTokens(model: *const RetryFontModel) canvas.DesignTokens {
    _ = model;
    var tokens = canvas.DesignTokens{};
    tokens.typography.font_id = registered_font_id;
    return tokens;
}

fn retryRowKey(index: *const usize) canvas.UiKey {
    return canvas.uiKey(@as(u64, index.*));
}

fn retryRow(ui: *RetryFontApp.Ui, index: *const usize) RetryFontApp.Ui.Node {
    return ui.text(.{}, ui.fmt("Row {d}", .{index.*}));
}

fn retryFontView(ui: *RetryFontApp.Ui, model: *const RetryFontModel) RetryFontApp.Ui.Node {
    // The measured text rides in a row (intrinsic width, like
    // lateFontAppView above) so its frame moves when the registered
    // face's advances replace the estimator's.
    return ui.column(.{ .gap = 2 }, .{
        ui.row(.{ .gap = 8, .padding = 12 }, .{ ui.text(.{}, late_mixed_text) }),
        ui.each(model.rows(ui.arena), retryRowKey, retryRow),
    });
}

test "a failed late-font rebuild leaves the count unadopted so the next healthy frame retries" {
    // The failing rebuild teaches through std.log; without lowering the
    // level the warning would fail the build runner's stderr check.
    const saved_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved_log_level;

    const harness = try TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(240, 200) });
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;

    const app_state = try std.testing.allocator.create(RetryFontApp);
    defer std.testing.allocator.destroy(app_state);
    app_state.* = RetryFontApp.init(std.testing.allocator, .{}, .{
        .name = "ui-app-font-retry",
        .scene = font_app_scene,
        .canvas_label = font_app_canvas_label,
        .tokens_fn = retryFontTokens,
        .update = retryFontUpdate,
        .view = retryFontView,
    });
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
    const width_before = try lateTextFrameWidth(&harness.runtime, 1, font_app_canvas_label);

    // Production policy: dispatch degrades errors instead of dying —
    // the policy under which a rebuild that adopted the font count
    // BEFORE succeeding would strand stale layouts marked font-current,
    // never retried.
    harness.runtime.dispatch_error_policy = .degrade;

    // Grow the model past the per-view widget budget (mutated directly
    // — no dispatch, so no rebuild yet), then register a face late so
    // the next frame's late-registration rebuild is the failing one.
    app_state.model.row_count = core.max_canvas_widget_nodes_per_view + 40;
    try harness.runtime.registerCanvasFont(registered_font_id, cjk_receipt_bytes);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = font_app_canvas_label,
        .size = geometry.SizeF.init(240, 200),
        .scale_factor = 1,
        .frame_index = 2,
        .timestamp_ns = 2_000_000,
        .nonblank = true,
    } });
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.dispatchErrors().len);
    // The failed rebuild must NOT adopt the count: the mismatch it
    // leaves behind is exactly what the next presented frame reads as
    // its retry trigger.
    try std.testing.expect(app_state.fonts_built_count != harness.runtime.registeredCanvasFontCount());

    // Heal the model; the next presented frame observes the mismatch,
    // rebuilds every surface, and only then adopts.
    app_state.model.row_count = 0;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .label = font_app_canvas_label,
        .size = geometry.SizeF.init(240, 200),
        .scale_factor = 1,
        .frame_index = 3,
        .timestamp_ns = 3_000_000,
        .nonblank = true,
    } });
    try std.testing.expectEqual(@as(usize, 1), harness.runtime.dispatchErrors().len);
    try std.testing.expectEqual(harness.runtime.registeredCanvasFontCount(), app_state.fonts_built_count);

    // The retried rebuild re-measured with the registered face, not
    // merely repainted: the face answers the mixed string wider than
    // the estimator did (1.0 em notdef per ASCII codepoint), so the
    // text widget's frame grew.
    const width_after = try lateTextFrameWidth(&harness.runtime, 1, font_app_canvas_label);
    try std.testing.expect(width_after > width_before);
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
