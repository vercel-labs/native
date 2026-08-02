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
//! engine on every other target. Effects never run here. Interactivity
//! is the engine-owned control state (hover, focus, toggles, radios,
//! text editing, sliders, scroll) PLUS each scene's mini-model: widget
//! events (press, toggle, dismiss, keyboard activation) route through
//! the scene tree's typed handler table into `preview_scenes.update`,
//! and the changed model rebuilds the tree — the same dispatch loop a
//! real UiApp runs, shrunk to the scene catalog's needs.

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
    /// Two build arenas, swapped on every rebuild (the UiApp shape): the
    /// previous tree's handler table must stay valid while an event from
    /// it is still being dispatched.
    arenas: [2]std.heap.ArenaAllocator,
    arena_index: usize = 0,
    /// Layout scratch: the widget tree nodes live here for the
    /// instance's lifetime (the runtime reconciles from them on install).
    layout_nodes: [native_sdk.runtime.max_canvas_widget_nodes_per_view]canvas.WidgetLayoutNode,
    scene: *const preview_scenes.Scene,
    /// The scene's mini-model; widget events update it and rebuild.
    model: preview_scenes.SceneModel = .{},
    /// The current tree's typed handler table (msgFor* dispatch).
    tree: ?preview_scenes.Ui.Tree = null,
    width: f32 = 0,
    height: f32 = 0,
    dark: bool = false,
    /// Which built-in theme pack resolves the token register. Packs
    /// compose with the scheme axis, so a pack swap and a light/dark
    /// flip go through the identical rebuild path.
    pack: canvas.ThemePack = .house,
    frame_index: u64 = 0,
    /// Last pointer position, kept so drag events can carry the
    /// per-event delta desktop platforms supply natively — the engine's
    /// delta consumers (the resizable's edge drag) read
    /// `input_event.delta_x`, never re-deriving it from positions.
    last_pointer: ?geometry.PointF = null,
    /// Memoized heavyweight render commands across frames: the modal
    /// scrim's full-viewport Gaussian blur alone dominated whole frames
    /// in the CPU reference renderer (hundreds of milliseconds at 2x
    /// DPR), with the surface drop shadow and the scrim wash close
    /// behind — yet the content UNDER those layers rarely changes
    /// between repaints (typing in a dialog, hover, and the caret blink
    /// all repaint content ABOVE the scrim). The memo keys on the exact
    /// source bytes each command reads, so a hit replays byte-identical
    /// pixels: determinism holds, only the time moves.
    render_memo: canvas.ReferenceRenderMemo,
    /// Revision of the view's retained display list at the last render,
    /// so `preview_render` can report "clean" without touching pixels.
    rendered_revision: u64 = std.math.maxInt(u64),
    rendered_scale_bits: u32 = 0,
    /// Whether render animations were still running at the last render:
    /// one more frame is painted after they settle so the final sampled
    /// pose (knob at rest, caret back at full opacity) lands on screen.
    rendered_animating: bool = false,
    /// Whether the current build declared windowed virtual lists
    /// (`ui.virtualList`): their window follows the runtime-owned scroll
    /// offset, so scroll observations re-derive the scene — the `UiApp`
    /// loop's shape, applied to the preview host.
    has_virtual_windows: bool = false,

    fn app(self: *Preview) native_sdk.App {
        return .{
            .context = self,
            .name = "docs-live-preview",
            .source = platform.WebViewSource.html("<h1>preview</h1>"),
            .event_fn = previewEventFn,
        };
    }
};

/// The mini-model dispatch loop: resolve runtime widget events through
/// the scene tree's typed handler table — the same seams `UiApp` uses —
/// update the model, and rebuild. Scenes without handlers never resolve
/// a Msg, so stateless previews cost nothing here.
fn previewEventFn(context: *anyopaque, runtime: *native_sdk.Runtime, event: native_sdk.runtime.Event) anyerror!void {
    const self: *Preview = @ptrCast(@alignCast(context));
    _ = runtime;
    const tree = &(self.tree orelse return);
    const msg: ?preview_scenes.Msg = switch (event) {
        .canvas_widget_pointer => |pointer_event| blk: {
            // A pointer gesture that performed a text edit (the text
            // field's built-in clear button): the runtime already
            // applied it, and the model hears it through `on_input` so
            // a source-owned buffer (the combobox query) follows.
            if (pointer_event.edit) |edit| {
                if (pointer_event.target) |edit_target| {
                    if (tree.msgForTextEdit(edit_target.id, edit)) |edit_msg| {
                        preview_scenes.update(&self.model, edit_msg);
                        rebuildScene(self) catch {};
                    }
                }
            }
            const target = pointer_event.press_target orelse break :blk null;
            break :blk tree.msgForPointer(target.id, pointer_event.pointer.phase);
        },
        .canvas_widget_keyboard => |keyboard_event| blk: {
            const target = keyboard_event.target orelse break :blk null;
            break :blk tree.msgForKeyboard(target.id, keyboard_event.keyboard);
        },
        .canvas_widget_dismiss => |dismiss_event| tree.msgForDismiss(dismiss_event.id),
        .canvas_widget_scroll => blk: {
            // Windowed virtual lists follow the runtime-owned offset:
            // the scroll observation itself re-derives the scene, no
            // Msg needed (the UiApp shape).
            if (self.has_virtual_windows) rebuildScene(self) catch {};
            break :blk null;
        },
        else => null,
    };
    if (msg) |value| {
        preview_scenes.update(&self.model, value);
        rebuildScene(self) catch {};
    }
}

fn tokensForTheme(dark: bool, pack: canvas.ThemePack) canvas.DesignTokens {
    return canvas.DesignTokens.theme(.{
        .color_scheme = if (dark) .dark else .light,
        .pack = pack,
    });
}

/// The preview host's window source (`Ui.virtualWindow`): the retained
/// node's scroll offset and content viewport, falling back to the tile
/// height before the list first mounts.
fn previewVirtualWindowState(context: ?*anyopaque, id: canvas.ObjectId) ?canvas.VirtualWindowState {
    const self: *Preview = @ptrCast(@alignCast(context orelse return null));
    const layout = self.runtime.canvasWidgetLayout(1, view_label) catch
        return .{ .offset = 0, .viewport_extent = self.height };
    if (layout.findById(id)) |node| {
        const viewport = node.frame.inset(node.widget.layout.padding).normalized();
        return .{ .offset = node.widget.value, .viewport_extent = viewport.height };
    }
    return .{ .offset = 0, .viewport_extent = self.height };
}

/// Monotonic event clock, advanced by the page (`preview_set_now_ms`
/// with the rAF/event timestamp, i.e. `performance.now()`). This is the
/// build's ONE time source: it stamps input and frame events (gesture
/// recognition, render-animation start times) AND feeds the runtime
/// clock seam, which otherwise reads 0 on freestanding — frozen time is
/// dead time-driven rendering (knob travel, caret blink).
var now_ns: u64 = 0;

export fn preview_set_now_ms(ms: f64) void {
    if (!std.math.isFinite(ms) or ms <= 0) return;
    now_ns = @intFromFloat(ms * std.time.ns_per_ms);
    native_sdk.setFreestandingMonotonicNanoseconds(now_ns);
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
    self.arenas = .{
        std.heap.ArenaAllocator.init(allocator),
        std.heap.ArenaAllocator.init(allocator),
    };
    self.arena_index = 0;
    self.scene = scene;
    self.model = scene.model;
    self.tree = null;
    self.width = scene.width;
    self.height = scene.height;
    self.dark = dark != 0;
    self.pack = .house;
    self.frame_index = 0;
    self.last_pointer = null;
    self.render_memo = canvas.ReferenceRenderMemo.init(allocator);
    self.rendered_revision = std.math.maxInt(u64);
    self.rendered_scale_bits = 0;
    self.rendered_animating = false;
    native_sdk.Runtime.initAt(&self.runtime, .{ .platform = self.null_platform.platform(), .allocator = allocator });

    installScene(self) catch {
        self.runtime.deinit();
        self.render_memo.deinit();
        self.arenas[0].deinit();
        self.arenas[1].deinit();
        allocator.destroy(self);
        return null;
    };
    return self;
}

fn installScene(self: *Preview) !void {
    const app = self.app();
    try self.runtime.dispatchPlatformEvent(app, .app_start);
    try self.runtime.dispatchPlatformEvent(app, .{ .surface_resized = self.null_platform.surface_value });

    _ = try self.runtime.createView(.{
        .window_id = 1,
        .label = view_label,
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, self.width, self.height),
    });

    try rebuildScene(self);
}

/// Build the scene from its mini-model, hand the layout to the runtime
/// (which reconciles engine-owned control state by id), and re-emit the
/// display list with the current theme's tokens. Runs on install, on
/// every dispatched Msg, and on theme swaps (token-resolved styles like
/// muted text re-resolve here).
fn rebuildScene(self: *Preview) !void {
    const tokens = tokensForTheme(self.dark, self.pack);
    const next_index = self.arena_index ^ 1;
    _ = self.arenas[next_index].reset(.retain_capacity);
    var ui = Ui.init(self.arenas[next_index].allocator());
    // Windowed virtual lists resolve their visible range against the
    // RETAINED scroll state, exactly like the app loop.
    ui.virtual_window_context = @ptrCast(self);
    ui.virtual_window_source = previewVirtualWindowState;
    const tree = try ui.finalizeWithTokens(self.scene.build(&ui, &self.model), tokens);
    self.has_virtual_windows = ui.virtualWindows().len > 0;
    // Layout with the SAME resolved tokens the paint pass reads: packs
    // restate layout metrics too (control ladders, group gaps), and a
    // house-token layout under a pack's paint would silently hide every
    // metric the pack changes. Pack and scheme swaps both route through
    // this rebuild, so a toggle re-lays as well as repaints.
    const layout = try canvas.layoutWidgetTreeWithTokens(tree.root, geometry.RectF.init(0, 0, self.width, self.height), tokens, &self.layout_nodes);
    _ = try self.runtime.setCanvasWidgetLayout(1, view_label, layout);
    _ = try self.runtime.emitCanvasWidgetDisplayList(1, view_label, tokens);
    self.tree = tree;
    self.arena_index = next_index;
}

export fn preview_destroy(self: ?*Preview) void {
    const p = self orelse return;
    p.runtime.deinit();
    p.render_memo.deinit();
    p.arenas[0].deinit();
    p.arenas[1].deinit();
    allocator.destroy(p);
}

export fn preview_logical_width(self: ?*Preview) f32 {
    return (self orelse return 0).width;
}

export fn preview_logical_height(self: ?*Preview) f32 {
    return (self orelse return 0).height;
}

/// Re-skin the retained scene for the docs theme: a full rebuild, so
/// token-resolved widget styles (muted text resolved at finalize time)
/// re-resolve against the new scheme. Engine-owned control state
/// (focus, toggles, typed text) is retained through the layout
/// reconcile.
export fn preview_set_theme(self: ?*Preview, dark: u32) u32 {
    const p = self orelse return 0;
    const wants_dark = dark != 0;
    if (p.dark == wants_dark) return 1;
    p.dark = wants_dark;
    rebuildScene(p) catch return 0;
    // Theme swaps must repaint even if the revision bookkeeping ever
    // treats a pure re-emit as clean.
    p.rendered_revision = std.math.maxInt(u64);
    return 1;
}

/// Switch the built-in theme pack by its manifest-facing name ("house",
/// "geist") — the pack axis of the same live re-theme `preview_set_theme`
/// performs on the scheme axis: a full rebuild so every token-resolved
/// widget style re-resolves against the pack's register, with
/// engine-owned control state (focus, toggles, typed text) retained
/// through the layout reconcile. Unknown names return 0 and leave the
/// instance untouched, so the page can keep its selection honest.
export fn preview_set_theme_pack(self: ?*Preview, name_ptr: ?[*]const u8, name_len: usize) u32 {
    const p = self orelse return 0;
    const ptr = name_ptr orelse return 0;
    const pack = canvas.ThemePack.fromName(ptr[0..name_len]) orelse return 0;
    if (p.pack == pack) return 1;
    p.pack = pack;
    rebuildScene(p) catch return 0;
    // Same forced repaint as the scheme flip: a pack swap must never be
    // reported clean.
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
    // Drags carry the position delta since the previous pointer event,
    // matching the desktop platforms' native events: the engine's delta
    // consumers (the resizable's edge drag) read `delta_x` directly and
    // never re-derive it from positions.
    const point = geometry.PointF.init(x, y);
    var delta_x: f32 = 0;
    var delta_y: f32 = 0;
    if (input_kind == .pointer_drag) {
        if (p.last_pointer) |last| {
            delta_x = point.x - last.x;
            delta_y = point.y - last.y;
        }
    }
    p.last_pointer = switch (input_kind) {
        .pointer_down, .pointer_drag, .pointer_move => point,
        else => null,
    };
    dispatch(p, .{
        .label = view_label,
        .kind = input_kind,
        .timestamp_ns = now_ns,
        .pointer_id = 1,
        .x = x,
        .y = y,
        .delta_x = delta_x,
        .delta_y = delta_y,
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

/// Mirror of the canvas element's DOM focus. The engine view gains
/// focus implicitly from pointer/key downs, but nothing in the input
/// stream says "focus left", so a blurred preview would keep its focus
/// ring, caret, and blink animation (and the rAF loop pumping) forever.
/// The page calls this from the canvas blur/focus handlers; the re-emit
/// drops or restores the focus affordances and the blink reconciler
/// with them, so the loop parks after a blur.
export fn preview_set_focused(self: ?*Preview, focused: u32) void {
    const p = self orelse return;
    const wants_focus = focused != 0;
    if (p.runtime.views[0].focused == wants_focus) return;
    p.runtime.views[0].focused = wants_focus;
    _ = p.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, view_label) catch {};
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

/// The engine's cursor channel for the pointer's current hover target,
/// following the native register (arrow over controls, hand only over
/// links, I-beam over text fields, resize over dividers), so the page
/// can mirror it onto the canvas's CSS cursor. 0 default, 1 pointer,
/// 2 text, 3 col-resize.
export fn preview_cursor(self: ?*Preview) u32 {
    const p = self orelse return 0;
    return switch (p.runtime.views[0].canvas_widget_cursor) {
        .arrow => 0,
        .pointing_hand => 1,
        .text => 2,
        .resize_horizontal => 3,
    };
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
    // Render animations (switch knob travel, caret blink) are sampled at
    // render time and never touch the display-list revision, so the view
    // stays dirty while any animation runs — plus ONE settling frame so
    // the final pose is painted — and only then reports clean again.
    const animating = p.runtime.views[0].canvasRenderAnimationsActive(now_ns);
    const settling = !animating and p.rendered_animating;
    if (!animating and !settling and revision == p.rendered_revision and scale_bits == p.rendered_scale_bits) return 0;

    _ = p.runtime.renderCanvasScreenshotWithMemo(
        1,
        view_label,
        renderScale(scale),
        pixels[0..pixels_len],
        scratch[0..scratch_len],
        &p.render_memo,
    ) catch return -2;
    p.rendered_revision = revision;
    p.rendered_scale_bits = scale_bits;
    p.rendered_animating = animating;
    return 1;
}

fn renderScale(scale: f32) ?f32 {
    if (!std.math.isFinite(scale) or scale <= 0) return null;
    return scale;
}
