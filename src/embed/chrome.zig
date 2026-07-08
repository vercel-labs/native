//! Declared platform chrome over the embed C ABI.
//!
//! Apps declare a tab set (and optionally one primary floating action)
//! in shell metadata (`ShellConfig.chrome`); a projecting host reads the
//! declaration through the `native_sdk_app_chrome_*` exports and builds
//! REAL native controls from it — on iOS an actual system tab bar and a
//! real button, styled by the OS, never imitated in canvas. Everything
//! here is read-only projection plumbing:
//!
//! - `MobileChromeItem` carries one declared tab or the primary action
//!   across the ABI (static manifest strings, valid for the app's
//!   lifetime).
//! - `selectedTabIndex` maps the model's selected tab id (the UiApp's
//!   `selected_tab_fn` derivation) onto the declared set, so the host's
//!   projection poll is one integer compare per frame.
//! - `renderIconPixels` rasterizes a declared icon-vocabulary glyph
//!   through the same vector core the canvas draws with, into a
//!   white-on-transparent RGBA8 template the system control tints —
//!   the artwork stays the app's, the styling stays the platform's. An
//!   unresolvable name renders the honest missing glyph, exactly like a
//!   broken icon reference in canvas.
//!
//! Taps travel the OTHER direction over the existing command path
//! (`native_sdk_app_command` with the tab or action id), so selection
//! state lives in the model and the whole loop replays deterministically
//! from the Msg journal — the native bar is never the source of truth.

const std = @import("std");
const canvas = @import("canvas");
const app_manifest = @import("app_manifest");
const platform = @import("../platform/root.zig");

/// One declared chrome tab (or the primary action) over the C ABI. The
/// string pointers reference the app's static shell metadata and stay
/// valid for the app's lifetime.
pub const MobileChromeItem = extern struct {
    id: ?[*]const u8 = null,
    id_len: usize = 0,
    label: ?[*]const u8 = null,
    label_len: usize = 0,
    icon: ?[*]const u8 = null,
    icon_len: usize = 0,
};

pub fn chromeItemFromTab(tab: app_manifest.ShellTab) MobileChromeItem {
    return .{
        .id = tab.id.ptr,
        .id_len = tab.id.len,
        .label = tab.label.ptr,
        .label_len = tab.label.len,
        .icon = if (tab.icon.len > 0) tab.icon.ptr else null,
        .icon_len = tab.icon.len,
    };
}

pub fn chromeItemFromAction(action: app_manifest.ShellPrimaryAction) MobileChromeItem {
    return .{
        .id = action.id.ptr,
        .id_len = action.id.len,
        .label = action.label.ptr,
        .label_len = action.label.len,
        .icon = if (action.icon.len > 0) action.icon.ptr else null,
        .icon_len = action.icon.len,
    };
}

/// The declared tab whose id equals the model's selected id, or -1 when
/// the selection names no declared tab (including the empty pre-install
/// selection) — the host projects "no selected item" honestly instead of
/// defaulting to the first tab.
pub fn selectedTabIndex(tabs: []const app_manifest.ShellTab, selected_id: []const u8) isize {
    if (selected_id.len == 0) return -1;
    for (tabs, 0..) |tab, index| {
        if (std.mem.eql(u8, tab.id, selected_id)) return @intCast(index);
    }
    return -1;
}

/// Form-factor ordinals over the C ABI, matching `platform.FormFactor`
/// (0 unknown, 1 compact, 2 regular). Out-of-range reports clamp to
/// unknown so a newer host never poisons an older library.
pub fn formFactorFromInt(value: c_int) platform.FormFactor {
    return switch (value) {
        1 => .compact,
        2 => .regular,
        else => .unknown,
    };
}

/// Coverage sink accumulating anti-aliased alpha into a square
/// tightly-packed RGBA8 buffer as premultiplied white — the template
/// image shape native controls tint (UIKit reads the alpha channel;
/// white keeps non-template consumers visible too). Overlapping shapes
/// keep the maximum coverage per pixel, matching how the reference
/// renderer composites an icon's fill and stroke of one color.
const TemplateSink = struct {
    pixels: []u8,
    size: usize,

    pub fn pixel(self: *TemplateSink, x: i32, y: i32, coverage: f32) void {
        if (x < 0 or y < 0) return;
        const px: usize = @intCast(x);
        const py: usize = @intCast(y);
        if (px >= self.size or py >= self.size) return;
        const alpha: u8 = @intFromFloat(@round(std.math.clamp(coverage, 0, 1) * 255));
        const base = (py * self.size + px) * 4;
        if (alpha <= self.pixels[base + 3]) return;
        self.pixels[base + 0] = alpha;
        self.pixels[base + 1] = alpha;
        self.pixels[base + 2] = alpha;
        self.pixels[base + 3] = alpha;
    }
};

pub const IconRenderError = error{
    InvalidIconRequest,
} || canvas.vector.Error;

/// Rasterize the icon-vocabulary glyph named `name` into `pixels` — a
/// tightly packed `size_px` x `size_px` RGBA8 buffer, premultiplied
/// white on transparent (a template image). Resolution follows the
/// canvas draw seam exactly (`icons.resolveOrMissing`): built-ins by
/// bare name, app-registered icons under `app:`, and any non-empty name
/// that resolves nowhere renders the visible missing glyph rather than
/// nothing. The icon is fitted contain-centered into the square with
/// stroke widths scaled, the same transform the widget draw paths use.
pub fn renderIconPixels(name: []const u8, size_px: usize, pixels: []u8) IconRenderError!void {
    if (name.len == 0 or size_px == 0 or size_px > canvas.vector.max_raster_width) return error.InvalidIconRequest;
    if (pixels.len != size_px * size_px * 4) return error.InvalidIconRequest;
    const icon = canvas.icons.resolveOrMissing(name) orelse return error.InvalidIconRequest;
    @memset(pixels, 0);

    const box = icon.view_box;
    const extent: f32 = @floatFromInt(size_px);
    const scale = @min(extent / box.width, extent / box.height);
    if (!(scale > 0)) return error.InvalidIconRequest;
    const transform = canvas.Affine{
        .a = scale,
        .b = 0,
        .c = 0,
        .d = scale,
        .tx = (extent - box.width * scale) * 0.5 - box.x * scale,
        .ty = (extent - box.height * scale) * 0.5 - box.y * scale,
    };
    const clip = canvas.vector.ClipRect{
        .x0 = 0,
        .y0 = 0,
        .x1 = @intCast(size_px),
        .y1 = @intCast(size_px),
    };
    var sink = TemplateSink{ .pixels = pixels, .size = size_px };
    for (icon.shapes) |shape| {
        const elements = icon.elements[shape.start .. shape.start + shape.len];
        if (shape.style.fill != .none) {
            try canvas.vector.fillPath(elements, transform, .nonzero, canvas.vector.default_tolerance, clip, &sink);
        }
        if (shape.style.stroke != .none and shape.style.stroke_width > 0) {
            try canvas.vector.strokePath(elements, transform, .{
                // Stroke geometry is generated in DEVICE space (the
                // transform has already run), so the authored viewBox
                // width scales with the icon.
                .width = shape.style.stroke_width * scale,
                .cap = shape.style.linecap,
                .join = shape.style.linejoin,
            }, canvas.vector.default_tolerance, clip, &sink);
        }
    }
}
