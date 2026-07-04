//! The docs live-preview wasm host: the engine's retained canvas
//! runtime compiled to `wasm32-freestanding`, driving the SAME scene
//! catalog the static webp previews render (`docs_preview_scenes.zig`),
//! so the interactive and static previews cannot drift apart.
//!
//! Build: `zig build docs-wasm-preview` → `docs/public/wasm/component-preview.wasm`.
//!
//! Shape mirrors the embed C ABI (src/embed): create with a scene name,
//! pump input as `gpu_surface_input` events, read pixels back through
//! the deterministic CPU reference renderer. There is no platform loop
//! and no JS dependency baked in: the page owns the clock (rAF) and the
//! canvas, and `preview_render` reports whether the retained display
//! list actually changed so an idle preview never repaints.
//!
//! Everything is fixed-capacity and single-threaded, exactly like the
//! engine on every other target. Effects never run here: scenes are
//! retained widget trees with no Model/Msg app behind them, so the
//! interactivity is precisely the engine-owned control state (hover,
//! focus, toggles, radios, text editing, sliders, scroll).

const std = @import("std");
const native_sdk = @import("native_sdk");
const preview_scenes = @import("docs_preview_scenes.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const platform = native_sdk.platform;

const Ui = preview_scenes.Ui;

const view_label = "preview";
const allocator = std.heap.wasm_allocator;

/// No stdio on freestanding wasm: drop log output instead of pulling
/// `std.Io.Threaded` (and posix with it) into the module.
pub const std_options: std.Options = .{ .logFn = noopLog };

fn noopLog(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;
    _ = format;
    _ = args;
}

/// One live preview instance: a whole retained runtime around one
/// gpu-surface view showing one scene. Heap-only — the Runtime is
/// megabytes of fixed-capacity storage.
const Preview = struct {
    null_platform: platform.NullPlatform,
    runtime: native_sdk.Runtime,
    arena: std.heap.ArenaAllocator,
    /// Layout scratch: the widget tree nodes live here for the
    /// instance's lifetime (the runtime reconciles from them on install).
    layout_nodes: [native_sdk.runtime.max_canvas_widget_nodes_per_view]canvas.WidgetLayoutNode,
    width: f32 = 0,
    height: f32 = 0,
    dark: bool = false,
    frame_index: u64 = 0,
    /// Revision of the view's retained display list at the last render,
    /// so `preview_render` can report "clean" without touching pixels.
    rendered_revision: u64 = std.math.maxInt(u64),
    rendered_scale_bits: u32 = 0,

    fn app(self: *Preview) native_sdk.App {
        return .{
            .context = self,
            .name = "docs-live-preview",
            .source = platform.WebViewSource.html("<h1>preview</h1>"),
        };
    }
};

fn tokensForScheme(dark: bool) canvas.DesignTokens {
    return canvas.DesignTokens.theme(.{ .color_scheme = if (dark) .dark else .light });
}

/// Monotonic event clock, advanced by the page (`preview_set_now_ms`
/// with the rAF/event timestamp). Only relative time matters: the
/// runtime uses it for press/drag gesture recognition.
var now_ns: u64 = 0;

export fn preview_set_now_ms(ms: f64) void {
    if (!std.math.isFinite(ms) or ms <= 0) return;
    now_ns = @intFromFloat(ms * std.time.ns_per_ms);
}

// ------------------------------------------------------------- memory

export fn preview_alloc(len: usize) ?[*]u8 {
    const bytes = allocator.alloc(u8, len) catch return null;
    return bytes.ptr;
}

export fn preview_free(ptr: ?[*]u8, len: usize) void {
    const p = ptr orelse return;
    allocator.free(p[0..len]);
}

/// Heap footprint of one live instance, so the page can budget how many
/// previews it keeps live at once.
export fn preview_instance_bytes() usize {
    return @sizeOf(Preview);
}

// ---------------------------------------------------------- lifecycle

export fn preview_create(name_ptr: ?[*]const u8, name_len: usize, dark: u32) ?*Preview {
    const ptr = name_ptr orelse return null;
    const scene = preview_scenes.sceneByName(ptr[0..name_len]) orelse return null;

    const self = allocator.create(Preview) catch return null;
    errdefer allocator.destroy(self);

    self.null_platform = platform.NullPlatform.init(.{ .size = geometry.SizeF.init(scene.width, scene.height) });
    self.null_platform.gpu_surfaces = true;
    self.arena = std.heap.ArenaAllocator.init(allocator);
    self.width = scene.width;
    self.height = scene.height;
    self.dark = dark != 0;
    self.frame_index = 0;
    self.rendered_revision = std.math.maxInt(u64);
    self.rendered_scale_bits = 0;
    native_sdk.Runtime.initAt(&self.runtime, .{ .platform = self.null_platform.platform() });

    installScene(self, scene) catch {
        self.arena.deinit();
        allocator.destroy(self);
        return null;
    };
    return self;
}

fn installScene(self: *Preview, scene: *const preview_scenes.Scene) !void {
    const app = self.app();
    try self.runtime.dispatchPlatformEvent(app, .app_start);
    try self.runtime.dispatchPlatformEvent(app, .{ .surface_resized = self.null_platform.surface_value });

    _ = try self.runtime.createView(.{
        .window_id = 1,
        .label = view_label,
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, scene.width, scene.height),
    });

    const tokens = tokensForScheme(self.dark);
    var ui = Ui.init(self.arena.allocator());
    const tree = try ui.finalizeWithTokens(scene.build(&ui), tokens);
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, scene.width, scene.height), &self.layout_nodes);
    _ = try self.runtime.setCanvasWidgetLayout(1, view_label, layout);
    _ = try self.runtime.emitCanvasWidgetDisplayList(1, view_label, tokens);
}

export fn preview_destroy(self: ?*Preview) void {
    const p = self orelse return;
    p.arena.deinit();
    allocator.destroy(p);
}

export fn preview_logical_width(self: ?*Preview) f32 {
    return (self orelse return 0).width;
}

export fn preview_logical_height(self: ?*Preview) f32 {
    return (self orelse return 0).height;
}

/// Re-skin the retained scene for the docs theme. Control state
/// (focus, toggles, typed text) is retained across the re-emit.
export fn preview_set_theme(self: ?*Preview, dark: u32) u32 {
    const p = self orelse return 0;
    const wants_dark = dark != 0;
    if (p.dark == wants_dark) return 1;
    p.dark = wants_dark;
    _ = p.runtime.emitCanvasWidgetDisplayList(1, view_label, tokensForScheme(wants_dark)) catch return 0;
    // Theme swaps must repaint even if the revision bookkeeping ever
    // treats a pure re-emit as clean.
    p.rendered_revision = std.math.maxInt(u64);
    return 1;
}

// -------------------------------------------------------------- input

fn dispatch(self: *Preview, event: platform.GpuSurfaceInputEvent) void {
    self.runtime.dispatchPlatformEvent(self.app(), .{ .gpu_surface_input = event }) catch {};
}

/// kind: 0 down, 1 up, 2 move, 3 drag, 4 cancel (mirrors the pointer
/// phases the embed ABI's touch entry point takes).
export fn preview_pointer(self: ?*Preview, kind: u32, x: f32, y: f32) void {
    const p = self orelse return;
    const input_kind: platform.GpuSurfaceInputKind = switch (kind) {
        0 => .pointer_down,
        1 => .pointer_up,
        2 => .pointer_move,
        3 => .pointer_drag,
        4 => .pointer_cancel,
        else => return,
    };
    dispatch(p, .{
        .label = view_label,
        .kind = input_kind,
        .timestamp_ns = now_ns,
        .pointer_id = 1,
        .x = x,
        .y = y,
        .pressure = if (input_kind == .pointer_down or input_kind == .pointer_drag) 1 else 0,
    });
}

export fn preview_scroll(self: ?*Preview, x: f32, y: f32, delta_x: f32, delta_y: f32) void {
    const p = self orelse return;
    dispatch(p, .{
        .label = view_label,
        .kind = .scroll,
        .timestamp_ns = now_ns,
        .pointer_id = 1,
        .x = x,
        .y = y,
        .delta_x = delta_x,
        .delta_y = delta_y,
    });
}

/// phase: 0 down, 1 up. `key` uses the runtime's lowercase names
/// ("enter", "space", "tab", "arrowleft", …); `text` carries the
/// printable insertion for the keystroke, exactly like the embed ABI.
/// modifiers mask: 1 primary, 2 command, 4 control, 8 option, 16 shift.
export fn preview_key(
    self: ?*Preview,
    phase: u32,
    key_ptr: ?[*]const u8,
    key_len: usize,
    text_ptr: ?[*]const u8,
    text_len: usize,
    modifiers: u32,
) void {
    const p = self orelse return;
    const kind: platform.GpuSurfaceInputKind = switch (phase) {
        0 => .key_down,
        1 => .key_up,
        else => return,
    };
    dispatch(p, .{
        .label = view_label,
        .kind = kind,
        .timestamp_ns = now_ns,
        .key = if (key_ptr) |k| k[0..key_len] else "",
        .text = if (text_ptr) |t| t[0..text_len] else "",
        .modifiers = .{
            .primary = modifiers & 1 != 0,
            .command = modifiers & 2 != 0,
            .control = modifiers & 4 != 0,
            .option = modifiers & 8 != 0,
            .shift = modifiers & 16 != 0,
        },
    });
}

export fn preview_text(self: ?*Preview, text_ptr: ?[*]const u8, text_len: usize) void {
    const p = self orelse return;
    const ptr = text_ptr orelse return;
    dispatch(p, .{
        .label = view_label,
        .kind = .text_input,
        .timestamp_ns = now_ns,
        .text = ptr[0..text_len],
    });
}

/// Nonzero while an editable text widget owns focus — the page keys
/// mobile keyboard / inputmode hints on it (same contract as the embed
/// ABI's text-input state).
export fn preview_text_input_active(self: ?*Preview) u32 {
    const p = self orelse return 0;
    const view = &p.runtime.views[0];
    if (!view.open or view.canvas_widget_focused_id == 0) return 0;
    return if (view.canEditCanvasWidgetText(view.canvas_widget_focused_id)) 1 else 0;
}

/// Synthesize the per-tick `gpu_surface_frame` event a platform display
/// link would deliver: steps engine-owned frame animations (scroll
/// momentum) so a wheel fling keeps coasting. Cheap when nothing is
/// animating; the page calls it from its rAF loop while the preview is
/// active and checks `preview_render` for actual repaints.
export fn preview_frame(self: ?*Preview) void {
    const p = self orelse return;
    p.frame_index += 1;
    p.runtime.dispatchPlatformEvent(p.app(), .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = view_label,
        .size = geometry.SizeF.init(p.width, p.height),
        .scale_factor = 1,
        .frame_index = p.frame_index,
        .timestamp_ns = now_ns,
        .status = .ready,
    } }) catch {};
}

// ------------------------------------------------------------- render

export fn preview_pixel_width(self: ?*Preview, scale: f32) u32 {
    const p = self orelse return 0;
    const size = p.runtime.canvasScreenshotPixelSize(1, view_label, renderScale(scale)) catch return 0;
    return size.width;
}

export fn preview_pixel_height(self: ?*Preview, scale: f32) u32 {
    const p = self orelse return 0;
    const size = p.runtime.canvasScreenshotPixelSize(1, view_label, renderScale(scale)) catch return 0;
    return size.height;
}

export fn preview_pixel_byte_len(self: ?*Preview, scale: f32) usize {
    const p = self orelse return 0;
    const size = p.runtime.canvasScreenshotPixelSize(1, view_label, renderScale(scale)) catch return 0;
    return size.byte_len;
}

/// Render the retained scene through the CPU reference renderer into
/// the caller's RGBA8 buffer (`preview_pixel_byte_len` sizes it; the
/// scratch buffer must be at least as large).
///
/// Returns 1 when pixels were (re)drawn, 0 when the display list is
/// unchanged since the last render at this scale (buffer untouched —
/// skip the canvas blit), negative on error.
export fn preview_render(
    self: ?*Preview,
    scale: f32,
    pixels_ptr: ?[*]u8,
    pixels_len: usize,
    scratch_ptr: ?[*]u8,
    scratch_len: usize,
) i32 {
    const p = self orelse return -1;
    const pixels = pixels_ptr orelse return -1;
    const scratch = scratch_ptr orelse return -1;

    const normalized_scale: f32 = if (std.math.isFinite(scale) and scale > 0) scale else 1;
    const scale_bits: u32 = @bitCast(normalized_scale);
    const revision = p.runtime.views[0].canvas_revision;
    if (revision == p.rendered_revision and scale_bits == p.rendered_scale_bits) return 0;

    _ = p.runtime.renderCanvasScreenshot(
        1,
        view_label,
        renderScale(scale),
        pixels[0..pixels_len],
        scratch[0..scratch_len],
    ) catch return -2;
    p.rendered_revision = revision;
    p.rendered_scale_bits = scale_bits;
    return 1;
}

fn renderScale(scale: f32) ?f32 {
    if (!std.math.isFinite(scale) or scale <= 0) return null;
    return scale;
}
