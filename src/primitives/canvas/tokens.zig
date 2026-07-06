const std = @import("std");
const canvas = @import("root.zig");
const text_metrics = @import("text_metrics.zig");

const ObjectId = canvas.ObjectId;
const FontId = canvas.FontId;
const Color = canvas.Color;
const Affine = canvas.Affine;
const CanvasRenderAnimation = canvas.CanvasRenderAnimation;
const default_sans_font_id = canvas.default_sans_font_id;
const default_mono_font_id = canvas.default_mono_font_id;
const default_sans_font_family = FontFamily.geist;
const default_mono_font_family = FontFamily.geist_mono;

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}

fn floorVirtualIndex(value: f32) usize {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    return @intFromFloat(@floor(value));
}

fn ceilVirtualIndex(value: f32) usize {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    return @intFromFloat(@ceil(value));
}

pub const Density = enum {
    compact,
    regular,
    spacious,
};

/// Minimum pointer hit-target extent in points at regular density and
/// default widget size. 18 is the smallest interactive register the house
/// controls ship (the checkbox/radio box), sitting inside the desktop
/// pointer convention band (macOS guidance asks for ~24pt around small
/// controls but AppKit's own small checkboxes are 14-18pt with row-level
/// slop; touch platforms want 44pt and get it from the 36pt control
/// height plus spacing). Consumers scale it through the same size/density
/// channel every control metric uses (`widgetSizedDensityValue`), so an
/// intentionally `sm` control at compact density keeps its floor while a
/// control squeezed below its own register is flagged. The layout audit's
/// `hit_target` rule is the enforcement point.
pub const min_pointer_hit_target: f32 = 18;

pub const Easing = enum {
    linear,
    standard,
    emphasized,
    spring,
};

pub const ColorScheme = enum {
    light,
    dark,
};

pub const ColorContrast = enum {
    standard,
    high,
};

pub const ThemeOptions = struct {
    color_scheme: ColorScheme = .light,
    contrast: ColorContrast = .standard,
    density: Density = .regular,
    reduce_motion: bool = false,
};

/// The default palette is the house "neutral + blue" preset,
/// converted from its published oklch values to sRGB hex (D65, standard
/// oklch -> linear sRGB -> gamma-encoded; conversions are exact to the
/// nearest 8-bit channel). Neutral gray scale for surfaces and text, a
/// blue-violet primary for accents, translucent-white hairlines in dark
/// mode, and card/popover surfaces one step lighter than the dark
/// background. Rationale per token is on the field.
pub const ColorTokens = struct {
    /// oklch(1 0 0) = #ffffff — the page background.
    background: Color = Color.rgb8(255, 255, 255),
    /// Card/popover surface; oklch(1 0 0) = #ffffff (same as the
    /// background in light — elevation comes from the border + shadow).
    surface: Color = Color.rgb8(255, 255, 255),
    /// Muted/accent surface; oklch(0.97 0 0) = #f5f5f5 — hover washes,
    /// skeletons, secondary chrome.
    surface_subtle: Color = Color.rgb8(245, 245, 245),
    /// Pressed/selected wash and the "input" surface (switch tracks);
    /// oklch(0.922 0 0) = #e5e5e5 — the same step the border sits on.
    surface_pressed: Color = Color.rgb8(229, 229, 229),
    /// Foreground; oklch(0.145 0 0) = #0a0a0a.
    text: Color = Color.rgb8(10, 10, 10),
    /// Muted foreground; oklch(0.556 0 0) = #737373.
    text_muted: Color = Color.rgb8(115, 115, 115),
    /// Border/input hairline; oklch(0.922 0 0) = #e5e5e5.
    border: Color = Color.rgb8(229, 229, 229),
    /// Primary; oklch(0.488 0.243 264.376) = #1447e6 — the blue-violet
    /// that identifies checked, active, and filled-primary states.
    accent: Color = Color.rgb8(20, 71, 230),
    /// Primary foreground; oklch(0.97 0.014 254.604) = #eff6ff — a
    /// blue-tinted near-white that reads as white on the primary.
    accent_text: Color = Color.rgb8(239, 246, 255),
    /// Destructive; oklch(0.577 0.245 27.325) = #e7000b.
    destructive: Color = Color.rgb8(231, 0, 11),
    destructive_text: Color = Color.rgb8(250, 250, 250),
    success: Color = Color.rgb8(22, 163, 74),
    success_text: Color = Color.rgb8(250, 250, 250),
    warning: Color = Color.rgb8(217, 119, 6),
    warning_text: Color = Color.rgb8(250, 250, 250),
    /// The fourth semantic hue: violet, for identity states that are not
    /// ok/warn/fail — a merged PR badge, a "new" chip, an informational
    /// callout. Named `info` because that is the slot every component
    /// vocabulary ships (Bootstrap/MUI/Ant all have one; GitHub's Primer
    /// calls the same role `done`); colored violet rather than blue
    /// because the violet identity hue is the one GitHub-shaped apps
    /// actually need, and nothing else in the palette competes with it.
    info: Color = Color.rgb8(124, 58, 237),
    info_text: Color = Color.rgb8(250, 250, 250),
    /// Ring; oklch(0.708 0 0) = #a1a1a1 — a mid gray so the focus ring
    /// reads as an outline, not a second border color.
    focus_ring: Color = Color.rgb8(161, 161, 161),
    shadow: Color = Color.rgba8(0, 0, 0, 26),
    /// Disabled wash; the muted surface step, oklch(0.97 0 0) = #f5f5f5.
    disabled: Color = Color.rgb8(245, 245, 245),

    pub fn theme(color_scheme: ColorScheme, contrast: ColorContrast) ColorTokens {
        return switch (color_scheme) {
            .light => switch (contrast) {
                .standard => light(),
                .high => highContrastLight(),
            },
            .dark => switch (contrast) {
                .standard => dark(),
                .high => highContrastDark(),
            },
        };
    }

    pub fn light() ColorTokens {
        return .{};
    }

    pub fn dark() ColorTokens {
        return .{
            // oklch(0.145 0 0) = #0a0a0a.
            .background = Color.rgb8(10, 10, 10),
            // Card/popover one step LIGHTER than the background:
            // oklch(0.205 0 0) = #171717 — elevation by lightness.
            .surface = Color.rgb8(23, 23, 23),
            // Muted/accent surface; oklch(0.269 0 0) = #262626.
            .surface_subtle = Color.rgb8(38, 38, 38),
            // "Input" surface and pressed wash: white at 15% alpha, so
            // pressed states and switch tracks tint whatever they sit on
            // (the dark-mode input treatment).
            .surface_pressed = Color.rgba8(255, 255, 255, 38),
            // oklch(0.985 0 0) = #fafafa.
            .text = Color.rgb8(250, 250, 250),
            // Muted foreground; oklch(0.708 0 0) = #a1a1a1.
            .text_muted = Color.rgb8(161, 161, 161),
            // Dark borders are translucent white (10%), not a gray fill:
            // hairlines brighten what they overlap instead of muddying it.
            .border = Color.rgba8(255, 255, 255, 26),
            // Primary; oklch(0.424 0.199 265.638) = #193cb8 — the same
            // blue-violet hue, stepped down for dark surfaces.
            .accent = Color.rgb8(25, 60, 184),
            // Primary foreground stays the blue-tinted near-white,
            // oklch(0.97 0.014 254.604) = #eff6ff.
            .accent_text = Color.rgb8(239, 246, 255),
            // Destructive; oklch(0.704 0.191 22.216) = #ff6467.
            .destructive = Color.rgb8(255, 100, 103),
            .destructive_text = Color.rgb8(250, 250, 250),
            .success = Color.rgb8(34, 197, 94),
            .success_text = Color.rgb8(9, 9, 11),
            .warning = Color.rgb8(245, 158, 11),
            .warning_text = Color.rgb8(9, 9, 11),
            .info = Color.rgb8(167, 139, 250),
            .info_text = Color.rgb8(9, 9, 11),
            // Ring; oklch(0.556 0 0) = #737373.
            .focus_ring = Color.rgb8(115, 115, 115),
            .shadow = Color.rgba8(0, 0, 0, 150),
            // Disabled wash; the muted step, oklch(0.269 0 0) = #262626.
            .disabled = Color.rgb8(38, 38, 38),
        };
    }

    pub fn highContrastLight() ColorTokens {
        return .{
            .background = Color.rgb8(255, 255, 255),
            .surface = Color.rgb8(255, 255, 255),
            // The standard theme's neutral steps, kept on the same scale.
            .surface_subtle = Color.rgb8(245, 245, 245),
            .surface_pressed = Color.rgb8(229, 229, 229),
            .text = Color.rgb8(0, 0, 0),
            .text_muted = Color.rgb8(64, 64, 64),
            .border = Color.rgba8(0, 0, 0, 180),
            // The dark-scheme primary (oklch(0.424 0.199 265.638) =
            // #193cb8): same blue-violet identity, deep enough for
            // 8.8:1 against the near-white accent text.
            .accent = Color.rgb8(25, 60, 184),
            .accent_text = Color.rgb8(255, 255, 255),
            .destructive = Color.rgb8(127, 29, 29),
            .destructive_text = Color.rgb8(255, 255, 255),
            .success = Color.rgb8(20, 83, 45),
            .success_text = Color.rgb8(255, 255, 255),
            .warning = Color.rgb8(120, 53, 15),
            .warning_text = Color.rgb8(255, 255, 255),
            .info = Color.rgb8(76, 29, 149),
            .info_text = Color.rgb8(255, 255, 255),
            // The primary itself (oklch(0.488 0.243 264.376) = #1447e6):
            // high-contrast rings should shout, and the brand blue does.
            .focus_ring = Color.rgb8(20, 71, 230),
            .shadow = Color.rgba8(0, 0, 0, 96),
            .disabled = Color.rgb8(163, 163, 163),
        };
    }

    pub fn highContrastDark() ColorTokens {
        return .{
            .background = Color.rgb8(0, 0, 0),
            .surface = Color.rgb8(10, 10, 10),
            .surface_subtle = Color.rgb8(23, 23, 23),
            .surface_pressed = Color.rgb8(38, 38, 38),
            .text = Color.rgb8(255, 255, 255),
            .text_muted = Color.rgb8(229, 229, 229),
            .border = Color.rgba8(255, 255, 255, 190),
            // A lifted primary (oklch(0.707 0.165 254.624) = #51a2ff):
            // the blue-violet identity at 7.9:1 against black accent
            // text, replacing the old hueless white accent.
            .accent = Color.rgb8(81, 162, 255),
            .accent_text = Color.rgb8(0, 0, 0),
            .destructive = Color.rgb8(248, 113, 113),
            .destructive_text = Color.rgb8(0, 0, 0),
            .success = Color.rgb8(134, 239, 172),
            .success_text = Color.rgb8(0, 0, 0),
            .warning = Color.rgb8(252, 211, 77),
            .warning_text = Color.rgb8(0, 0, 0),
            .info = Color.rgb8(196, 181, 253),
            .info_text = Color.rgb8(0, 0, 0),
            .focus_ring = Color.rgb8(147, 197, 253),
            .shadow = Color.rgba8(0, 0, 0, 180),
            .disabled = Color.rgb8(82, 82, 82),
        };
    }
};

pub const FontFamily = enum {
    geist,
    geist_mono,
    system_sans,
    system_mono,

    pub fn cssName(self: FontFamily) []const u8 {
        return switch (self) {
            .geist => "Geist",
            .geist_mono => "Geist Mono",
            .system_sans => "system-ui",
            .system_mono => "ui-monospace",
        };
    }
};

pub const TypographyTokens = struct {
    font_id: FontId = default_sans_font_id,
    mono_font_id: FontId = default_mono_font_id,
    font_family: FontFamily = default_sans_font_family,
    mono_font_family: FontFamily = default_mono_font_family,
    body_size: f32 = 14,
    label_size: f32 = 13,
    title_size: f32 = 20,
    button_size: f32 = 14,
    /// Section-heading rung above `title_size`: 28 continues the house
    /// step ratio (body 14 → title 20 ≈ x1.4; title 20 → heading 28 =
    /// x1.4) and doubles `body_size`, so a heading's 1.25 line height
    /// (35) still composes with body lines on the same 4pt-friendly
    /// rhythm.
    heading_size: f32 = 28,
    /// Display rung: hero stats, timer numerals, pricing figures. The
    /// jump from heading widens deliberately (28 → 48 ≈ x1.7) — display
    /// text is a focal numeral, not a bigger heading — and 48 keeps the
    /// even-number rhythm with a 1.25 line height of exactly 60, a
    /// whole-pixel line box at 1x and 2x scale factors.
    display_size: f32 = 48,

    pub fn bodyFamilyName(self: TypographyTokens) []const u8 {
        return self.font_family.cssName();
    }

    pub fn monoFamilyName(self: TypographyTokens) []const u8 {
        return self.mono_font_family.cssName();
    }
};

pub const SpacingTokens = struct {
    xs: f32 = 4,
    sm: f32 = 8,
    md: f32 = 12,
    lg: f32 = 16,
    xl: f32 = 24,
};

/// Derived from a 10px base radius, the derivation the house scale uses:
/// `--radius`: lg is the base, md steps down 2, sm steps down 4, and xl
/// steps up 4. Buttons and inputs sit on md; cards and surfaces on lg.
pub const RadiusTokens = struct {
    sm: f32 = 6,
    md: f32 = 8,
    lg: f32 = 10,
    xl: f32 = 14,
};

pub const StrokeTokens = struct {
    hairline: f32 = 1,
    regular: f32 = 1,
    focus: f32 = 2,
};

pub const ShadowToken = struct {
    y: f32 = 8,
    blur: f32 = 24,
    spread: f32 = -10,
};

pub const ShadowTokens = struct {
    none: ShadowToken = .{ .y = 0, .blur = 0, .spread = 0 },
    sm: ShadowToken = .{ .y = 2, .blur = 8, .spread = -4 },
    md: ShadowToken = .{ .y = 8, .blur = 24, .spread = -12 },
};

pub const BlurTokens = struct {
    none: f32 = 0,
    sm: f32 = 8,
    md: f32 = 16,

    pub fn value(self: BlurTokens, token: BlurTokenRef) f32 {
        return switch (token) {
            .none => self.none,
            .sm => self.sm,
            .md => self.md,
        };
    }
};

pub const MotionDuration = enum {
    fast,
    normal,
    slow,
};

pub const MotionAnimationOptions = struct {
    id: ObjectId,
    start_ns: u64 = 0,
    duration: MotionDuration = .normal,
    easing: ?Easing = null,
    spring: ?SpringToken = null,
    from_opacity: ?f32 = null,
    to_opacity: ?f32 = null,
    from_transform: ?Affine = null,
    to_transform: ?Affine = null,
};

pub const MotionTokens = struct {
    fast_ms: u32 = 120,
    normal_ms: u32 = 180,
    slow_ms: u32 = 260,
    easing: Easing = .standard,
    spring: SpringToken = .{},

    pub fn reduced() MotionTokens {
        return .{
            .fast_ms = 0,
            .normal_ms = 0,
            .slow_ms = 0,
            .easing = .linear,
        };
    }

    pub fn durationMs(self: MotionTokens, duration: MotionDuration) u32 {
        return switch (duration) {
            .fast => self.fast_ms,
            .normal => self.normal_ms,
            .slow => self.slow_ms,
        };
    }

    pub fn animation(self: MotionTokens, options: MotionAnimationOptions) CanvasRenderAnimation {
        return .{
            .id = options.id,
            .start_ns = options.start_ns,
            .duration_ms = self.durationMs(options.duration),
            .easing = options.easing orelse self.easing,
            .spring = options.spring orelse self.spring,
            .from_opacity = options.from_opacity,
            .to_opacity = options.to_opacity,
            .from_transform = options.from_transform,
            .to_transform = options.to_transform,
        };
    }
};

pub const SpringToken = struct {
    mass: f32 = 1,
    stiffness: f32 = 220,
    damping: f32 = 28,
};

pub const BlurTokenRef = enum {
    none,
    sm,
    md,
};

pub const ScrollPhysics = struct {
    wheel_multiplier: f32 = 1,
    wheel_velocity_scale: f32 = 60,
    deceleration_per_second: f32 = 0.86,
    stop_velocity: f32 = 5,
    rubberband_extent_ratio: f32 = 0,
    rubberband_max_extent: f32 = 0,
    rubberband_resistance: f32 = 0.38,
    rubberband_return_per_second: f32 = 18,
    rubberband_velocity_decay_per_second: f32 = 0,
    rubberband_snap_distance: f32 = 0.5,
};

pub const ScrollState = struct {
    offset: f32 = 0,
    velocity: f32 = 0,
    viewport_extent: f32 = 0,
    content_extent: f32 = 0,

    pub fn maxOffset(self: ScrollState) f32 {
        return @max(0, nonNegative(self.content_extent) - nonNegative(self.viewport_extent));
    }

    pub fn clamped(self: ScrollState) ScrollState {
        var next = self;
        const clamped_offset = std.math.clamp(nonNegative(next.offset), 0, next.maxOffset());
        if (clamped_offset != next.offset) next.velocity = 0;
        next.offset = clamped_offset;
        return next;
    }

    pub fn applyWheel(self: ScrollState, delta: f32, physics: ScrollPhysics) ScrollState {
        return self.applyWheelWithRubberband(delta, physics, true);
    }

    pub fn applyWheelClamped(self: ScrollState, delta: f32, physics: ScrollPhysics) ScrollState {
        return self.applyWheelWithRubberband(delta, physics, false);
    }

    pub fn visualOffset(self: ScrollState) f32 {
        return std.math.clamp(self.offset, 0, self.maxOffset());
    }

    pub fn overscroll(self: ScrollState) f32 {
        return self.offset - self.visualOffset();
    }

    pub fn needsKineticStep(self: ScrollState, physics: ScrollPhysics) bool {
        return @abs(self.velocity) > nonNegative(physics.stop_velocity) or @abs(self.overscroll()) > @max(0.01, nonNegative(physics.rubberband_snap_distance));
    }

    fn applyWheelWithRubberband(self: ScrollState, delta: f32, physics: ScrollPhysics, rubberband: bool) ScrollState {
        var next = self;
        const scaled_delta = delta * physics.wheel_multiplier;
        var effective_delta = scaled_delta;
        if (rubberband and scaled_delta != 0) {
            const max_offset = next.maxOffset();
            const moving_outward =
                (next.offset <= 0 and scaled_delta < 0) or
                (next.offset >= max_offset and scaled_delta > 0);
            if (moving_outward) {
                effective_delta *= std.math.clamp(physics.rubberband_resistance, 0, 1);
            }
        }
        next.offset += effective_delta;
        next.velocity = scaled_delta * physics.wheel_velocity_scale;
        return if (rubberband) next.rubberbanded(physics) else next.clamped();
    }

    pub fn stepKinetic(self: ScrollState, dt_ms: f32, physics: ScrollPhysics) ScrollState {
        var next = self;
        const dt_seconds = nonNegative(dt_ms) / 1000.0;
        if (@abs(next.overscroll()) > 0.01) {
            const bounded = next.visualOffset();
            const overscroll_delta = next.offset - bounded;
            const recovery = std.math.clamp(nonNegative(physics.rubberband_return_per_second) * dt_seconds, 0, 1);
            next.offset -= overscroll_delta * recovery;
            const velocity_decay = std.math.pow(f32, std.math.clamp(physics.rubberband_velocity_decay_per_second, 0, 1), dt_seconds);
            next.velocity *= velocity_decay;
            if (@abs(next.offset - bounded) <= nonNegative(physics.rubberband_snap_distance) and @abs(next.velocity) <= nonNegative(physics.stop_velocity) * 4) {
                next.offset = bounded;
                next.velocity = 0;
            }
            return next.rubberbanded(physics);
        }

        if (@abs(next.velocity) <= nonNegative(physics.stop_velocity)) {
            next.velocity = 0;
            return next;
        }

        next.offset += next.velocity * dt_seconds;
        const decay = std.math.pow(f32, std.math.clamp(physics.deceleration_per_second, 0, 1), dt_seconds);
        next.velocity *= decay;
        if (@abs(next.velocity) <= nonNegative(physics.stop_velocity)) next.velocity = 0;
        return next.rubberbanded(physics);
    }

    fn rubberbanded(self: ScrollState, physics: ScrollPhysics) ScrollState {
        const extent = self.rubberbandExtent(physics);
        if (extent <= 0) return self.clamped();
        var next = self;
        const min_offset = -extent;
        const max_offset = next.maxOffset() + extent;
        next.offset = std.math.clamp(next.offset, min_offset, max_offset);
        return next;
    }

    fn rubberbandExtent(self: ScrollState, physics: ScrollPhysics) f32 {
        const viewport_extent = nonNegative(self.viewport_extent);
        if (viewport_extent <= 0) return 0;
        const ratio_extent = viewport_extent * nonNegative(physics.rubberband_extent_ratio);
        const max_extent = nonNegative(physics.rubberband_max_extent);
        if (max_extent <= 0) return ratio_extent;
        return @min(ratio_extent, max_extent);
    }
};

pub const VirtualListOptions = struct {
    item_count: usize = 0,
    item_extent: f32 = 0,
    item_gap: f32 = 0,
    viewport_extent: f32 = 0,
    scroll_offset: f32 = 0,
    overscan: usize = 0,
};

pub const VirtualListRange = struct {
    start_index: usize = 0,
    end_index: usize = 0,
    first_visible_index: usize = 0,
    last_visible_index: usize = 0,
    item_extent: f32 = 0,
    item_gap: f32 = 0,
    scroll_offset: f32 = 0,
    layout_offset: f32 = 0,
    content_extent: f32 = 0,
    before_extent: f32 = 0,
    after_extent: f32 = 0,
    /// VARIABLE-extent windows only (`item_extent == 0`): the offset
    /// table's leading edge for `first_visible_index` — the row the
    /// layout pass anchors the built window on, so estimate error in
    /// freshly mounted rows surfaces off-screen (above the anchor),
    /// never under the user's eyes. Uniform windows leave it 0.
    anchor_extent: f32 = 0,

    pub fn itemCount(self: VirtualListRange) usize {
        return self.end_index - self.start_index;
    }

    pub fn isEmpty(self: VirtualListRange) bool {
        return self.start_index >= self.end_index;
    }
};

pub fn virtualListRange(options: VirtualListOptions) VirtualListRange {
    if (options.item_count == 0 or options.item_extent <= 0 or options.viewport_extent <= 0) return .{};

    const item_extent = nonNegative(options.item_extent);
    const item_gap = nonNegative(options.item_gap);
    const stride = item_extent + item_gap;
    const item_count_f = @as(f32, @floatFromInt(options.item_count));
    const content_extent = item_count_f * item_extent + @max(0, item_count_f - 1) * item_gap;
    const viewport_extent = nonNegative(options.viewport_extent);
    const max_offset = @max(0, content_extent - viewport_extent);
    const raw_offset = if (std.math.isFinite(options.scroll_offset)) options.scroll_offset else 0;
    const offset = std.math.clamp(nonNegative(raw_offset), 0, max_offset);
    const layout_offset = std.math.clamp(raw_offset, -viewport_extent, max_offset + viewport_extent);

    const first_visible = @min(options.item_count - 1, floorVirtualIndex(offset / stride));
    const visible_end = @min(options.item_count, ceilVirtualIndex((offset + viewport_extent + item_gap) / stride));
    const start_index = if (first_visible > options.overscan) first_visible - options.overscan else 0;
    const end_index = @min(options.item_count, visible_end + options.overscan);

    return .{
        .start_index = start_index,
        .end_index = end_index,
        .first_visible_index = first_visible,
        .last_visible_index = if (visible_end > 0) visible_end - 1 else first_visible,
        .item_extent = item_extent,
        .item_gap = item_gap,
        .scroll_offset = offset,
        .layout_offset = layout_offset,
        .content_extent = content_extent,
        .before_extent = @as(f32, @floatFromInt(start_index)) * stride,
        .after_extent = @as(f32, @floatFromInt(options.item_count - end_index)) * stride,
    };
}

pub const LayerTokens = struct {
    base: i32 = 0,
    floating: i32 = 100,
    overlay: i32 = 200,
    modal: i32 = 300,
};

pub const PixelSnapTokens = struct {
    geometry: bool = false,
    text: bool = false,
    scale: f32 = 1,
};

pub const ControlVisualTokens = struct {
    background: ?Color = null,
    hover_background: ?Color = null,
    active_background: ?Color = null,
    foreground: ?Color = null,
    border: ?Color = null,
    radius: ?f32 = null,
    stroke_width: ?f32 = null,
};

pub const ControlTokens = struct {
    button_default: ControlVisualTokens = .{},
    button_primary: ControlVisualTokens = .{},
    button_secondary: ControlVisualTokens = .{},
    button_outline: ControlVisualTokens = .{},
    button_ghost: ControlVisualTokens = .{},
    button_destructive: ControlVisualTokens = .{},
    toggle_button: ControlVisualTokens = .{},
    accordion: ControlVisualTokens = .{},
    alert: ControlVisualTokens = .{},
    bubble: ControlVisualTokens = .{},
    card: ControlVisualTokens = .{},
    dialog: ControlVisualTokens = .{},
    drawer: ControlVisualTokens = .{},
    sheet: ControlVisualTokens = .{},
    select: ControlVisualTokens = .{},
    input: ControlVisualTokens = .{},
    text_field: ControlVisualTokens = .{},
    search_field: ControlVisualTokens = .{},
    combobox: ControlVisualTokens = .{},
    textarea: ControlVisualTokens = .{},
    list_item: ControlVisualTokens = .{},
    menu_item: ControlVisualTokens = .{},
    data_cell: ControlVisualTokens = .{},
    /// The tabs LIST container (the house tab-strip treatment): the muted rounded
    /// wash the `segmented_control` triggers sit on.
    tabs: ControlVisualTokens = .{},
    segmented_control: ControlVisualTokens = .{},
    checkbox: ControlVisualTokens = .{},
    radio: ControlVisualTokens = .{},
    toggle: ControlVisualTokens = .{},
    slider: ControlVisualTokens = .{},
    progress: ControlVisualTokens = .{},
    scrollbar: ControlVisualTokens = .{},
    panel: ControlVisualTokens = .{},
    resizable: ControlVisualTokens = .{},
    popover: ControlVisualTokens = .{},
    menu_surface: ControlVisualTokens = .{},
    dropdown_menu: ControlVisualTokens = .{},
    tooltip: ControlVisualTokens = .{},
    avatar: ControlVisualTokens = .{},
    badge: ControlVisualTokens = .{},
    separator: ControlVisualTokens = .{},
    skeleton: ControlVisualTokens = .{},
    spinner: ControlVisualTokens = .{},
};

pub const ColorTokenOverrides = struct {
    background: ?Color = null,
    surface: ?Color = null,
    surface_subtle: ?Color = null,
    surface_pressed: ?Color = null,
    text: ?Color = null,
    text_muted: ?Color = null,
    border: ?Color = null,
    accent: ?Color = null,
    accent_text: ?Color = null,
    destructive: ?Color = null,
    destructive_text: ?Color = null,
    success: ?Color = null,
    success_text: ?Color = null,
    warning: ?Color = null,
    warning_text: ?Color = null,
    info: ?Color = null,
    info_text: ?Color = null,
    focus_ring: ?Color = null,
    shadow: ?Color = null,
    disabled: ?Color = null,

    pub fn apply(self: ColorTokenOverrides, base: ColorTokens) ColorTokens {
        return applyFlatTokenOverrides(ColorTokens, base, self);
    }
};

pub const TypographyTokenOverrides = struct {
    font_id: ?FontId = null,
    mono_font_id: ?FontId = null,
    font_family: ?FontFamily = null,
    mono_font_family: ?FontFamily = null,
    body_size: ?f32 = null,
    label_size: ?f32 = null,
    title_size: ?f32 = null,
    button_size: ?f32 = null,
    heading_size: ?f32 = null,
    display_size: ?f32 = null,

    pub fn apply(self: TypographyTokenOverrides, base: TypographyTokens) TypographyTokens {
        return applyFlatTokenOverrides(TypographyTokens, base, self);
    }
};

pub const SpacingTokenOverrides = struct {
    xs: ?f32 = null,
    sm: ?f32 = null,
    md: ?f32 = null,
    lg: ?f32 = null,
    xl: ?f32 = null,

    pub fn apply(self: SpacingTokenOverrides, base: SpacingTokens) SpacingTokens {
        return applyFlatTokenOverrides(SpacingTokens, base, self);
    }
};

pub const RadiusTokenOverrides = struct {
    sm: ?f32 = null,
    md: ?f32 = null,
    lg: ?f32 = null,
    xl: ?f32 = null,

    pub fn apply(self: RadiusTokenOverrides, base: RadiusTokens) RadiusTokens {
        return applyFlatTokenOverrides(RadiusTokens, base, self);
    }
};

pub const StrokeTokenOverrides = struct {
    hairline: ?f32 = null,
    regular: ?f32 = null,
    focus: ?f32 = null,

    pub fn apply(self: StrokeTokenOverrides, base: StrokeTokens) StrokeTokens {
        return applyFlatTokenOverrides(StrokeTokens, base, self);
    }
};

pub const ShadowTokenOverrides = struct {
    y: ?f32 = null,
    blur: ?f32 = null,
    spread: ?f32 = null,

    pub fn apply(self: ShadowTokenOverrides, base: ShadowToken) ShadowToken {
        return applyFlatTokenOverrides(ShadowToken, base, self);
    }
};

pub const ShadowTokensOverrides = struct {
    none: ShadowTokenOverrides = .{},
    sm: ShadowTokenOverrides = .{},
    md: ShadowTokenOverrides = .{},

    pub fn apply(self: ShadowTokensOverrides, base: ShadowTokens) ShadowTokens {
        var next = base;
        next.none = self.none.apply(next.none);
        next.sm = self.sm.apply(next.sm);
        next.md = self.md.apply(next.md);
        return next;
    }
};

pub const BlurTokenOverrides = struct {
    none: ?f32 = null,
    sm: ?f32 = null,
    md: ?f32 = null,

    pub fn apply(self: BlurTokenOverrides, base: BlurTokens) BlurTokens {
        return applyFlatTokenOverrides(BlurTokens, base, self);
    }
};

pub const SpringTokenOverrides = struct {
    mass: ?f32 = null,
    stiffness: ?f32 = null,
    damping: ?f32 = null,

    pub fn apply(self: SpringTokenOverrides, base: SpringToken) SpringToken {
        return applyFlatTokenOverrides(SpringToken, base, self);
    }
};

pub const MotionTokenOverrides = struct {
    fast_ms: ?u32 = null,
    normal_ms: ?u32 = null,
    slow_ms: ?u32 = null,
    easing: ?Easing = null,
    spring: SpringTokenOverrides = .{},

    pub fn apply(self: MotionTokenOverrides, base: MotionTokens) MotionTokens {
        var next = applyFlatTokenOverrides(MotionTokens, base, .{
            .fast_ms = self.fast_ms,
            .normal_ms = self.normal_ms,
            .slow_ms = self.slow_ms,
            .easing = self.easing,
        });
        next.spring = self.spring.apply(next.spring);
        return next;
    }
};

pub const ScrollPhysicsOverrides = struct {
    wheel_multiplier: ?f32 = null,
    wheel_velocity_scale: ?f32 = null,
    deceleration_per_second: ?f32 = null,
    stop_velocity: ?f32 = null,
    rubberband_extent_ratio: ?f32 = null,
    rubberband_max_extent: ?f32 = null,
    rubberband_resistance: ?f32 = null,
    rubberband_return_per_second: ?f32 = null,
    rubberband_velocity_decay_per_second: ?f32 = null,
    rubberband_snap_distance: ?f32 = null,

    pub fn apply(self: ScrollPhysicsOverrides, base: ScrollPhysics) ScrollPhysics {
        return applyFlatTokenOverrides(ScrollPhysics, base, self);
    }
};

pub const LayerTokenOverrides = struct {
    base: ?i32 = null,
    floating: ?i32 = null,
    overlay: ?i32 = null,
    modal: ?i32 = null,

    pub fn apply(self: LayerTokenOverrides, base: LayerTokens) LayerTokens {
        return applyFlatTokenOverrides(LayerTokens, base, self);
    }
};

pub const PixelSnapTokenOverrides = struct {
    geometry: ?bool = null,
    text: ?bool = null,
    scale: ?f32 = null,

    pub fn apply(self: PixelSnapTokenOverrides, base: PixelSnapTokens) PixelSnapTokens {
        return applyFlatTokenOverrides(PixelSnapTokens, base, self);
    }
};

pub const ControlVisualTokenOverrides = struct {
    background: ?Color = null,
    hover_background: ?Color = null,
    active_background: ?Color = null,
    foreground: ?Color = null,
    border: ?Color = null,
    radius: ?f32 = null,
    stroke_width: ?f32 = null,

    pub fn apply(self: ControlVisualTokenOverrides, base: ControlVisualTokens) ControlVisualTokens {
        return applyFlatTokenOverrides(ControlVisualTokens, base, self);
    }
};

pub const ControlTokenOverrides = struct {
    button_default: ControlVisualTokenOverrides = .{},
    button_primary: ControlVisualTokenOverrides = .{},
    button_secondary: ControlVisualTokenOverrides = .{},
    button_outline: ControlVisualTokenOverrides = .{},
    button_ghost: ControlVisualTokenOverrides = .{},
    button_destructive: ControlVisualTokenOverrides = .{},
    toggle_button: ControlVisualTokenOverrides = .{},
    accordion: ControlVisualTokenOverrides = .{},
    alert: ControlVisualTokenOverrides = .{},
    bubble: ControlVisualTokenOverrides = .{},
    card: ControlVisualTokenOverrides = .{},
    dialog: ControlVisualTokenOverrides = .{},
    drawer: ControlVisualTokenOverrides = .{},
    sheet: ControlVisualTokenOverrides = .{},
    select: ControlVisualTokenOverrides = .{},
    input: ControlVisualTokenOverrides = .{},
    text_field: ControlVisualTokenOverrides = .{},
    search_field: ControlVisualTokenOverrides = .{},
    combobox: ControlVisualTokenOverrides = .{},
    textarea: ControlVisualTokenOverrides = .{},
    list_item: ControlVisualTokenOverrides = .{},
    menu_item: ControlVisualTokenOverrides = .{},
    data_cell: ControlVisualTokenOverrides = .{},
    tabs: ControlVisualTokenOverrides = .{},
    segmented_control: ControlVisualTokenOverrides = .{},
    checkbox: ControlVisualTokenOverrides = .{},
    radio: ControlVisualTokenOverrides = .{},
    toggle: ControlVisualTokenOverrides = .{},
    slider: ControlVisualTokenOverrides = .{},
    progress: ControlVisualTokenOverrides = .{},
    scrollbar: ControlVisualTokenOverrides = .{},
    panel: ControlVisualTokenOverrides = .{},
    resizable: ControlVisualTokenOverrides = .{},
    popover: ControlVisualTokenOverrides = .{},
    menu_surface: ControlVisualTokenOverrides = .{},
    dropdown_menu: ControlVisualTokenOverrides = .{},
    tooltip: ControlVisualTokenOverrides = .{},
    avatar: ControlVisualTokenOverrides = .{},
    badge: ControlVisualTokenOverrides = .{},
    separator: ControlVisualTokenOverrides = .{},
    skeleton: ControlVisualTokenOverrides = .{},
    spinner: ControlVisualTokenOverrides = .{},

    pub fn apply(self: ControlTokenOverrides, base: ControlTokens) ControlTokens {
        var next = base;
        next.button_default = self.button_default.apply(next.button_default);
        next.button_primary = self.button_primary.apply(next.button_primary);
        next.button_secondary = self.button_secondary.apply(next.button_secondary);
        next.button_outline = self.button_outline.apply(next.button_outline);
        next.button_ghost = self.button_ghost.apply(next.button_ghost);
        next.button_destructive = self.button_destructive.apply(next.button_destructive);
        next.toggle_button = self.toggle_button.apply(next.toggle_button);
        next.accordion = self.accordion.apply(next.accordion);
        next.alert = self.alert.apply(next.alert);
        next.bubble = self.bubble.apply(next.bubble);
        next.card = self.card.apply(next.card);
        next.dialog = self.dialog.apply(next.dialog);
        next.drawer = self.drawer.apply(next.drawer);
        next.sheet = self.sheet.apply(next.sheet);
        next.select = self.select.apply(next.select);
        next.input = self.input.apply(next.input);
        next.text_field = self.text_field.apply(next.text_field);
        next.search_field = self.search_field.apply(next.search_field);
        next.combobox = self.combobox.apply(next.combobox);
        next.textarea = self.textarea.apply(next.textarea);
        next.list_item = self.list_item.apply(next.list_item);
        next.menu_item = self.menu_item.apply(next.menu_item);
        next.data_cell = self.data_cell.apply(next.data_cell);
        next.tabs = self.tabs.apply(next.tabs);
        next.segmented_control = self.segmented_control.apply(next.segmented_control);
        next.checkbox = self.checkbox.apply(next.checkbox);
        next.radio = self.radio.apply(next.radio);
        next.toggle = self.toggle.apply(next.toggle);
        next.slider = self.slider.apply(next.slider);
        next.progress = self.progress.apply(next.progress);
        next.scrollbar = self.scrollbar.apply(next.scrollbar);
        next.panel = self.panel.apply(next.panel);
        next.resizable = self.resizable.apply(next.resizable);
        next.popover = self.popover.apply(next.popover);
        next.menu_surface = self.menu_surface.apply(next.menu_surface);
        next.dropdown_menu = self.dropdown_menu.apply(next.dropdown_menu);
        next.tooltip = self.tooltip.apply(next.tooltip);
        next.avatar = self.avatar.apply(next.avatar);
        next.badge = self.badge.apply(next.badge);
        next.separator = self.separator.apply(next.separator);
        next.skeleton = self.skeleton.apply(next.skeleton);
        next.spinner = self.spinner.apply(next.spinner);
        return next;
    }
};

pub const DesignTokenOverrides = struct {
    colors: ColorTokenOverrides = .{},
    typography: TypographyTokenOverrides = .{},
    spacing: SpacingTokenOverrides = .{},
    radius: RadiusTokenOverrides = .{},
    stroke: StrokeTokenOverrides = .{},
    shadow: ShadowTokensOverrides = .{},
    blur: BlurTokenOverrides = .{},
    motion: MotionTokenOverrides = .{},
    scroll: ScrollPhysicsOverrides = .{},
    layer: LayerTokenOverrides = .{},
    pixel_snap: PixelSnapTokenOverrides = .{},
    controls: ControlTokenOverrides = .{},
    density: ?Density = null,

    pub fn apply(self: DesignTokenOverrides, base: DesignTokens) DesignTokens {
        return base.withOverrides(self);
    }
};

pub const DesignTokens = struct {
    colors: ColorTokens = .{},
    typography: TypographyTokens = .{},
    spacing: SpacingTokens = .{},
    radius: RadiusTokens = .{},
    stroke: StrokeTokens = .{},
    shadow: ShadowTokens = .{},
    blur: BlurTokens = .{},
    motion: MotionTokens = .{},
    scroll: ScrollPhysics = .{},
    layer: LayerTokens = .{},
    pixel_snap: PixelSnapTokens = .{},
    controls: ControlTokens = .{},
    density: Density = .regular,
    /// Optional platform text measurement. Null (the default) keeps every
    /// layout computation on the deterministic estimator; runtimes install
    /// a provider so widget layout agrees with the fonts the platform
    /// actually draws. Not themed and not part of overrides: the runtime
    /// stamps it after theme resolution.
    text_measure: ?*const text_metrics.TextMeasureProvider = null,

    pub fn theme(options: ThemeOptions) DesignTokens {
        return .{
            .colors = ColorTokens.theme(options.color_scheme, options.contrast),
            .motion = if (options.reduce_motion) MotionTokens.reduced() else .{},
            .density = options.density,
        };
    }

    pub fn themeWithOverrides(options: ThemeOptions, overrides: DesignTokenOverrides) DesignTokens {
        return theme(options).withOverrides(overrides);
    }

    pub fn withOverrides(self: DesignTokens, overrides: DesignTokenOverrides) DesignTokens {
        var next = self;
        next.colors = overrides.colors.apply(next.colors);
        next.typography = overrides.typography.apply(next.typography);
        next.spacing = overrides.spacing.apply(next.spacing);
        next.radius = overrides.radius.apply(next.radius);
        next.stroke = overrides.stroke.apply(next.stroke);
        next.shadow = overrides.shadow.apply(next.shadow);
        next.blur = overrides.blur.apply(next.blur);
        next.motion = overrides.motion.apply(next.motion);
        next.scroll = overrides.scroll.apply(next.scroll);
        next.layer = overrides.layer.apply(next.layer);
        next.pixel_snap = overrides.pixel_snap.apply(next.pixel_snap);
        next.controls = overrides.controls.apply(next.controls);
        if (overrides.density) |density| next.density = density;
        return next;
    }
};

fn applyFlatTokenOverrides(comptime Token: type, base: Token, overrides: anytype) Token {
    var next = base;
    inline for (@typeInfo(@TypeOf(overrides)).@"struct".fields) |field| {
        if (@field(overrides, field.name)) |value| {
            @field(next, field.name) = value;
        }
    }
    return next;
}
