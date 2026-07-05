const geometry = @import("geometry");
const canvas = @import("canvas");
const canvas_limits = @import("canvas_limits.zig");
const canvas_widget_runtime = @import("canvas_widget_runtime.zig");
const view_canvas = @import("view_canvas.zig");
const view_widget_control = @import("view_widget_control.zig");
const view_widget_scroll = @import("view_widget_scroll.zig");
const view_widget_text = @import("view_widget_text.zig");
const view_widget_tree = @import("view_widget_tree.zig");
const platform = @import("../platform/root.zig");

const max_canvas_commands_per_view = canvas_limits.max_canvas_commands_per_view;
const max_canvas_retained_packet_commands_per_view = canvas_limits.max_canvas_retained_packet_commands_per_view;
const max_canvas_gradient_stops_per_view = canvas_limits.max_canvas_gradient_stops_per_view;
const max_canvas_path_elements_per_view = canvas_limits.max_canvas_path_elements_per_view;
const max_canvas_glyphs_per_view = canvas_limits.max_canvas_glyphs_per_view;
const max_canvas_text_bytes_per_view = canvas_limits.max_canvas_text_bytes_per_view;
const max_canvas_render_animations_per_view = canvas_limits.max_canvas_render_animations_per_view;
const max_canvas_render_animation_dirty_bounds_per_view = canvas_limits.max_canvas_render_animation_dirty_bounds_per_view;
const max_canvas_render_overrides_per_view = canvas_limits.max_canvas_render_overrides_per_view;
const max_canvas_pipelines_per_view = canvas_limits.max_canvas_pipelines_per_view;
const max_canvas_path_geometries_per_view = canvas_limits.max_canvas_path_geometries_per_view;
const max_canvas_images_per_view = canvas_limits.max_canvas_images_per_view;
const max_canvas_layers_per_view = canvas_limits.max_canvas_layers_per_view;
const max_canvas_resources_per_view = canvas_limits.max_canvas_resources_per_view;
const max_canvas_visual_effects_per_view = canvas_limits.max_canvas_visual_effects_per_view;
const max_canvas_text_layouts_per_view = canvas_limits.max_canvas_text_layouts_per_view;
const max_canvas_widget_nodes_per_view = canvas_limits.max_canvas_widget_nodes_per_view;
const max_canvas_widget_semantics_per_view = canvas_limits.max_canvas_widget_semantics_per_view;
const max_canvas_widget_text_bytes_per_view = canvas_limits.max_canvas_widget_text_bytes_per_view;
const max_canvas_widget_source_text_entries_per_view = canvas_limits.max_canvas_widget_source_text_entries_per_view;

const CanvasWidgetSourceTextEntry = canvas_widget_runtime.CanvasWidgetSourceTextEntry;
const CanvasWidgetSourceScrollEntry = canvas_widget_runtime.CanvasWidgetSourceScrollEntry;
fn copyInto(buffer: []u8, value: []const u8) ![]const u8 {
    if (value.len > buffer.len) return error.NoSpaceLeft;
    @memcpy(buffer[0..value.len], value);
    return buffer[0..value.len];
}

pub const CanvasWidgetScrollSource = view_widget_scroll.CanvasWidgetScrollSource;
pub const CanvasWidgetToggleAnimation = view_widget_control.CanvasWidgetToggleAnimation;
pub const CanvasWidgetDisplayListChrome = view_canvas.CanvasWidgetDisplayListChrome;
pub const CanvasRenderAnimationDirtyBounds = view_canvas.CanvasRenderAnimationDirtyBounds;
pub const CanvasResourceCounts = view_canvas.CanvasResourceCounts;
pub const CanvasDisplayListScratch = view_canvas.CanvasDisplayListScratch;
pub const PresentedCanvasCommand = view_canvas.PresentedCanvasCommand;

pub fn canvasRenderAnimationStartNsForView(view: *const RuntimeView) u64 {
    return @max(view.gpu_input_timestamp_ns, view.gpu_timestamp_ns);
}

pub const RuntimeView = struct {
    id: platform.ViewId = 0,
    window_id: platform.WindowId = 1,
    label: []const u8 = "",
    kind: platform.ViewKind = .toolbar,
    parent: ?[]const u8 = null,
    frame: geometry.RectF = geometry.RectF.init(0, 0, 0, 0),
    layer: i32 = 0,
    visible: bool = true,
    enabled: bool = true,
    role: []const u8 = "",
    accessibility_label: []const u8 = "",
    text: []const u8 = "",
    command: []const u8 = "",
    transparent: bool = false,
    bridge_enabled: bool = false,
    gpu_size: geometry.SizeF = geometry.SizeF.init(0, 0),
    gpu_scale_factor: f32 = 1,
    gpu_frame_index: u64 = 0,
    gpu_timestamp_ns: u64 = 0,
    gpu_frame_interval_ns: u64 = platform.default_gpu_frame_interval_ns,
    gpu_pending_input_timestamp_ns: u64 = 0,
    gpu_input_timestamp_ns: u64 = 0,
    gpu_input_latency_ns: u64 = 0,
    gpu_input_latency_budget_ns: u64 = platform.default_gpu_frame_interval_ns,
    gpu_input_latency_budget_custom: bool = false,
    gpu_input_latency_budget_exceeded_count: usize = 0,
    gpu_input_latency_budget_ok: bool = true,
    gpu_surface_created_timestamp_ns: u64 = 0,
    gpu_first_frame_latency_ns: u64 = 0,
    gpu_first_frame_latency_budget_ns: u64 = platform.default_gpu_first_frame_latency_budget_ns,
    gpu_first_frame_latency_budget_exceeded_count: usize = 0,
    gpu_first_frame_latency_budget_ok: bool = true,
    gpu_first_frame_latency_recorded: bool = false,
    gpu_frame_nonblank: bool = false,
    gpu_sample_color: u32 = 0,
    gpu_backend: platform.GpuSurfaceBackend = .none,
    gpu_pixel_format: platform.GpuSurfacePixelFormat = .none,
    gpu_present_mode: platform.GpuSurfacePresentMode = .none,
    gpu_alpha_mode: platform.GpuSurfaceAlphaMode = .none,
    gpu_color_space: platform.GpuSurfaceColorSpace = .none,
    gpu_vsync: bool = false,
    gpu_status: platform.GpuSurfaceStatus = .unavailable,
    /// The presentation path that last painted this surface: `.packet`
    /// after a successful `presentGpuSurfacePacket`, `.pixels` after a
    /// successful `presentGpuSurfacePixels`, `.none` before the first
    /// present. Stamped only on platform present success — a failed
    /// packet attempt that fell back to pixels reports `.pixels`, and
    /// idle skips (no repaint needed) keep the previous value.
    gpu_present_path: platform.GpuPresentPath = .none,
    /// Why the most recent packet attempt fell back to the pixel path
    /// (`.none` while packets present cleanly). Cleared on every
    /// successful packet present; the frame counter below never resets,
    /// so a view that oscillates between paths shows a climbing count
    /// even when a snapshot lands on a healthy frame.
    gpu_present_fallback_reason: platform.GpuPresentFallbackReason = .none,
    gpu_present_fallback_needed_bytes: usize = 0,
    gpu_present_fallback_limit_bytes: usize = 0,
    gpu_present_fallback_command_kind_storage: [platform.max_gpu_present_fallback_detail_bytes]u8 = undefined,
    gpu_present_fallback_command_kind_len: usize = 0,
    gpu_present_fallback_frame_count: usize = 0,
    /// Fallback count at the last emitted debug diagnostic — the log is
    /// rate-limited to the first fallback and every interval after, so a
    /// per-frame oscillation cannot flood stderr.
    gpu_present_fallback_logged_count: usize = 0,
    /// Incremental packet presentation state: the engine's mirror of the
    /// host's retained command dictionary. `canvas_packet_generation` is
    /// bumped by every successful keyed FULL binary present (the baseline
    /// patches edit); the key+fingerprint arrays record, in draw order,
    /// the commands that baseline (or the last applied patch) left
    /// retained host-side. `canvas_packet_baseline_valid` is the single
    /// gate for attempting a patch — any present that bypasses the
    /// retained protocol (JSON, pixels, non-retained binary) clears it,
    /// and the next binary present rebuilds via FULL. Sized by
    /// `canvas_limits.max_canvas_retained_packet_commands_per_view`.
    canvas_packet_generation: u64 = 0,
    canvas_packet_baseline_valid: bool = false,
    canvas_packet_baseline_count: usize = 0,
    canvas_packet_baseline_surface_size: geometry.SizeF = geometry.SizeF.init(0, 0),
    canvas_packet_baseline_scale: f32 = 1,
    canvas_packet_baseline_keys: [max_canvas_retained_packet_commands_per_view]u64 = undefined,
    canvas_packet_baseline_fingerprints: [max_canvas_retained_packet_commands_per_view]u64 = undefined,
    /// Patch telemetry surfaced on the automation snapshot view line
    /// (present_mode= / present_patch_*= / present_retained_commands=).
    gpu_present_packet_mode: platform.GpuPresentPacketMode = .none,
    gpu_present_patch_bytes: usize = 0,
    gpu_present_patch_upsert_count: usize = 0,
    gpu_present_patch_evict_count: usize = 0,
    canvas_commands: [max_canvas_commands_per_view]canvas.CanvasCommand = undefined,
    canvas_command_count: usize = 0,
    canvas_revision: u64 = 0,
    canvas_gradient_stops: [max_canvas_gradient_stops_per_view]canvas.GradientStop = undefined,
    canvas_gradient_stop_count: usize = 0,
    canvas_path_elements: [max_canvas_path_elements_per_view]canvas.PathElement = undefined,
    canvas_path_element_count: usize = 0,
    canvas_glyphs: [max_canvas_glyphs_per_view]canvas.Glyph = undefined,
    canvas_glyph_count: usize = 0,
    canvas_text_bytes: [max_canvas_text_bytes_per_view]u8 = undefined,
    canvas_text_len: usize = 0,
    canvas_display_list_widget_owned: bool = false,
    canvas_widget_display_list_prefix_count: usize = 0,
    canvas_widget_display_list_suffix_count: usize = 0,
    canvas_widget_display_list_reserved_count: usize = 0,
    /// Clear color from the most recent canvas presentation (GPU packet or
    /// pixel path); automation screenshots reuse it so the rendered PNG
    /// matches what presentation cleared to.
    canvas_clear_color: canvas.Color = .{},
    presented_canvas_valid: bool = false,
    presented_canvas_revision: u64 = 0,
    presented_canvas_surface_size: geometry.SizeF = geometry.SizeF.init(0, 0),
    presented_canvas_scale: f32 = 1,
    presented_canvas_commands: [max_canvas_commands_per_view]PresentedCanvasCommand = undefined,
    presented_canvas_command_count: usize = 0,
    presented_canvas_has_unkeyed: bool = false,
    canvas_render_animations: [max_canvas_render_animations_per_view]canvas.CanvasRenderAnimation = undefined,
    canvas_render_animation_count: usize = 0,
    /// Command id of the caret currently carrying the looping blink
    /// animation (0 when no caret is showing), so display-list refreshes
    /// can retarget or remove the blink as focus and selection move.
    canvas_widget_caret_blink_id: canvas.ObjectId = 0,
    /// Arc command ids of the spinners currently carrying the looping
    /// rotation animation, so display-list refreshes can remove the
    /// animations of spinners that unmounted (and the view goes idle).
    canvas_widget_spinner_ids: [canvas_limits.max_canvas_widget_spinner_animations_per_view]canvas.ObjectId = undefined,
    canvas_widget_spinner_count: usize = 0,
    canvas_render_animation_dirty_bounds: [max_canvas_render_animation_dirty_bounds_per_view]CanvasRenderAnimationDirtyBounds = undefined,
    canvas_render_animation_dirty_bounds_count: usize = 0,
    canvas_frame_render_overrides: [max_canvas_render_overrides_per_view]canvas.CanvasRenderOverride = undefined,
    canvas_frame_render_override_count: usize = 0,
    canvas_frame_path_geometry_cache: [max_canvas_path_geometries_per_view]canvas.RenderPathGeometryCacheEntry = undefined,
    canvas_frame_path_geometry_cache_count: usize = 0,
    canvas_frame_image_cache: [max_canvas_images_per_view]canvas.RenderImageCacheEntry = undefined,
    canvas_frame_image_cache_count: usize = 0,
    canvas_frame_layer_cache: [max_canvas_layers_per_view]canvas.RenderLayerCacheEntry = undefined,
    canvas_frame_layer_cache_count: usize = 0,
    canvas_frame_resource_cache: [max_canvas_resources_per_view]canvas.RenderResourceCacheEntry = undefined,
    canvas_frame_resource_cache_count: usize = 0,
    canvas_frame_visual_effect_cache: [max_canvas_visual_effects_per_view]canvas.VisualEffectCacheEntry = undefined,
    canvas_frame_visual_effect_cache_count: usize = 0,
    canvas_frame_glyph_atlas_cache: [max_canvas_glyphs_per_view]canvas.GlyphAtlasCacheEntry = undefined,
    canvas_frame_glyph_atlas_cache_count: usize = 0,
    canvas_frame_text_layout_cache: [max_canvas_text_layouts_per_view]canvas.TextLayoutCacheEntry = undefined,
    canvas_frame_text_layout_cache_count: usize = 0,
    canvas_frame_pipeline_cache: [max_canvas_pipelines_per_view]canvas.RenderPipelineCacheEntry = undefined,
    canvas_frame_pipeline_cache_count: usize = 0,
    canvas_frame_requires_render: bool = false,
    canvas_frame_full_repaint: bool = false,
    canvas_frame_batch_count: usize = 0,
    canvas_frame_encoder_command_count: usize = 0,
    canvas_frame_encoder_cache_action_count: usize = 0,
    canvas_frame_encoder_bind_pipeline_count: usize = 0,
    canvas_frame_encoder_draw_batch_count: usize = 0,
    canvas_frame_pipeline_count: usize = 0,
    canvas_frame_pipeline_upload_count: usize = 0,
    canvas_frame_pipeline_retain_count: usize = 0,
    canvas_frame_pipeline_evict_count: usize = 0,
    canvas_frame_path_geometry_count: usize = 0,
    canvas_frame_path_geometry_vertex_count: usize = 0,
    canvas_frame_path_geometry_index_count: usize = 0,
    canvas_frame_path_geometry_upload_count: usize = 0,
    canvas_frame_path_geometry_retain_count: usize = 0,
    canvas_frame_path_geometry_evict_count: usize = 0,
    canvas_frame_image_count: usize = 0,
    canvas_frame_image_upload_count: usize = 0,
    canvas_frame_image_retain_count: usize = 0,
    canvas_frame_image_evict_count: usize = 0,
    canvas_frame_layer_count: usize = 0,
    canvas_frame_layer_opacity_count: usize = 0,
    canvas_frame_layer_clip_count: usize = 0,
    canvas_frame_layer_transform_count: usize = 0,
    canvas_frame_layer_upload_count: usize = 0,
    canvas_frame_layer_retain_count: usize = 0,
    canvas_frame_layer_evict_count: usize = 0,
    canvas_frame_resource_count: usize = 0,
    canvas_frame_resource_upload_count: usize = 0,
    canvas_frame_resource_retain_count: usize = 0,
    canvas_frame_resource_evict_count: usize = 0,
    canvas_frame_visual_effect_count: usize = 0,
    canvas_frame_visual_effect_shadow_count: usize = 0,
    canvas_frame_visual_effect_blur_count: usize = 0,
    canvas_frame_visual_effect_upload_count: usize = 0,
    canvas_frame_visual_effect_retain_count: usize = 0,
    canvas_frame_visual_effect_evict_count: usize = 0,
    canvas_frame_glyph_atlas_entry_count: usize = 0,
    canvas_frame_glyph_atlas_upload_count: usize = 0,
    canvas_frame_glyph_atlas_retain_count: usize = 0,
    canvas_frame_glyph_atlas_evict_count: usize = 0,
    canvas_frame_text_layout_count: usize = 0,
    canvas_frame_text_layout_line_count: usize = 0,
    canvas_frame_text_layout_upload_count: usize = 0,
    canvas_frame_text_layout_retain_count: usize = 0,
    canvas_frame_text_layout_evict_count: usize = 0,
    canvas_frame_gpu_packet_command_count: usize = 0,
    canvas_frame_gpu_packet_cache_action_count: usize = 0,
    canvas_frame_gpu_packet_cached_resource_command_count: usize = 0,
    canvas_frame_gpu_packet_unsupported_command_count: usize = 0,
    canvas_frame_gpu_packet_representable: bool = true,
    canvas_frame_change_count: usize = 0,
    canvas_frame_budget: canvas.CanvasFrameBudget = .{},
    canvas_frame_budget_status: canvas.CanvasFrameBudgetStatus = .{},
    canvas_frame_dirty_bounds: ?geometry.RectF = null,
    canvas_frame_profile_work_units: usize = 0,
    canvas_frame_profile_risk: platform.CanvasFrameProfileRisk = .idle,
    canvas_frame_profile_surface_area: f32 = 0,
    canvas_frame_profile_dirty_area: f32 = 0,
    canvas_frame_profile_dirty_ratio: f32 = 0,
    widget_layout_nodes: [max_canvas_widget_nodes_per_view]canvas.WidgetLayoutNode = undefined,
    widget_layout_node_count: usize = 0,
    widget_semantics_nodes: [max_canvas_widget_semantics_per_view]canvas.WidgetSemanticsNode = undefined,
    widget_semantics_node_count: usize = 0,
    /// Fingerprint of the last accessibility tree actually handed to the
    /// platform (and whether one ever was): the publish path skips the
    /// platform call when the assembled nodes are unchanged, so typing
    /// and animation refreshes stop paying the host's full
    /// tree-assembly/publish cost on every refresh.
    widget_accessibility_published: bool = false,
    widget_accessibility_published_hash: u64 = 0,
    widget_revision: u64 = 0,
    widget_tokens: canvas.DesignTokens = .{},
    widget_scroll_states: [max_canvas_widget_nodes_per_view]canvas.ScrollState = undefined,
    /// Scroll nodes whose offset changed since the last app dispatch
    /// (wheel, kinetic, keyboard, accessibility): drained into
    /// `canvas_widget_scroll` events at the gpu-surface dispatch points.
    /// Deduped by id; the dispatched event reads the CURRENT state, so
    /// coalescing wheel + kinetic steps per node is lossless (see
    /// `canvas_limits.max_canvas_widget_scroll_events_per_view`).
    widget_scroll_event_ids: [canvas_limits.max_canvas_widget_scroll_events_per_view]canvas.ObjectId = undefined,
    widget_scroll_event_count: usize = 0,
    /// Split nodes whose fraction changed since the last app dispatch
    /// (divider drag, keyboard, accessibility): drained into
    /// `canvas_widget_resize` events at the gpu-surface dispatch points.
    /// Deduped by id; the dispatched event reads the CURRENT fraction,
    /// so coalescing drag steps per node is lossless (see
    /// `canvas_limits.max_canvas_widget_resize_events_per_view`).
    widget_resize_event_ids: [canvas_limits.max_canvas_widget_resize_events_per_view]canvas.ObjectId = undefined,
    widget_resize_event_count: usize = 0,
    widget_source_text_entries: [max_canvas_widget_source_text_entries_per_view]CanvasWidgetSourceTextEntry = undefined,
    widget_source_text_count: usize = 0,
    widget_source_scroll_entries: [canvas_limits.max_canvas_widget_nodes_per_view]CanvasWidgetSourceScrollEntry = undefined,
    widget_source_scroll_count: usize = 0,
    /// SOURCE-side selected state per control on the previous rebuild:
    /// the control reconcile reads it to tell model-driven
    /// toggle-buttons (source wins) from uncontrolled ones (retained
    /// state wins).
    widget_source_control_entries: [canvas_limits.max_canvas_widget_nodes_per_view]canvas_widget_runtime.CanvasWidgetSourceControlEntry = undefined,
    widget_source_control_count: usize = 0,
    /// SOURCE-side autofocus ids on the previous rebuild: the edge
    /// detector — a rebuild only moves focus to a widget whose flag was
    /// NOT in this set (newly mounted or freshly flipped on).
    widget_autofocus_ids: [canvas_limits.max_canvas_widget_autofocus_per_view]canvas.ObjectId = undefined,
    widget_autofocus_count: usize = 0,
    /// Native scroll-driver tracking: each installed driver's id and
    /// the last offset it reported (or was pushed), so the sync only
    /// forces `set_offset` when a non-driver source moved the offset.
    scroll_driver_ids: [platform.max_gpu_surface_scroll_drivers]u64 = undefined,
    scroll_driver_offsets: [platform.max_gpu_surface_scroll_drivers]f32 = undefined,
    scroll_driver_count: usize = 0,
    canvas_widget_focused_id: canvas.ObjectId = 0,
    canvas_widget_focus_visible_id: canvas.ObjectId = 0,
    canvas_widget_hovered_id: canvas.ObjectId = 0,
    canvas_widget_pressed_id: canvas.ObjectId = 0,
    /// The static `.text` widget owning the view's active click-drag
    /// selection (0 = none). One static selection per view; starting a
    /// selection elsewhere (or pressing anywhere else) clears it.
    canvas_widget_selected_text_id: canvas.ObjectId = 0,
    canvas_widget_cursor: platform.Cursor = .arrow,
    widget_text_bytes: [max_canvas_widget_text_bytes_per_view]u8 = undefined,
    widget_text_len: usize = 0,
    widget_span_entries: [canvas_limits.max_canvas_widget_spans_per_view]canvas.TextSpan = undefined,
    widget_span_len: usize = 0,
    widget_context_menu_items: [canvas_limits.max_canvas_widget_context_menu_items_per_view]canvas.WidgetContextMenuItem = undefined,
    widget_context_menu_len: usize = 0,
    /// Chart series and points retained across all `.chart` widgets of
    /// the view (labels ride `widget_text_bytes`), same bump-copy
    /// discipline as spans.
    widget_chart_series_entries: [canvas_limits.max_canvas_widget_chart_series_per_view]canvas.ChartSeries = undefined,
    widget_chart_series_len: usize = 0,
    widget_chart_points: [canvas_limits.max_canvas_widget_chart_points_per_view]f32 = undefined,
    widget_chart_points_len: usize = 0,
    focused: bool = false,
    open: bool = false,
    label_storage: [platform.max_view_label_bytes]u8 = undefined,
    parent_storage: [platform.max_view_label_bytes]u8 = undefined,
    role_storage: [platform.max_view_role_bytes]u8 = undefined,
    accessibility_label_storage: [platform.max_view_accessibility_label_bytes]u8 = undefined,
    text_storage: [platform.max_view_text_bytes]u8 = undefined,
    command_storage: [platform.max_view_command_bytes]u8 = undefined,

    const CanvasWidgetTextMethods = view_widget_text.RuntimeViewCanvasWidgetText(RuntimeView);
    pub const applyCanvasWidgetTextEdit = CanvasWidgetTextMethods.applyCanvasWidgetTextEdit;
    pub const canvasWidgetKeyboardTextEdit = CanvasWidgetTextMethods.canvasWidgetKeyboardTextEdit;
    pub const canEditCanvasWidgetText = CanvasWidgetTextMethods.canEditCanvasWidgetText;
    pub const applyCanvasWidgetTextPointer = CanvasWidgetTextMethods.applyCanvasWidgetTextPointer;
    pub const clearCanvasWidgetStaticTextSelection = CanvasWidgetTextMethods.clearCanvasWidgetStaticTextSelection;
    pub const canvasWidgetCopyText = CanvasWidgetTextMethods.canvasWidgetCopyText;
    pub const rewriteCanvasWidgetTextStorage = CanvasWidgetTextMethods.rewriteCanvasWidgetTextStorage;
    pub const setCanvasWidgetTextValue = CanvasWidgetTextMethods.setCanvasWidgetTextValue;

    const CanvasWidgetScrollMethods = view_widget_scroll.RuntimeViewCanvasWidgetScroll(RuntimeView);
    pub const canvasWidgetKineticScrollActive = CanvasWidgetScrollMethods.canvasWidgetKineticScrollActive;
    pub const applyCanvasWidgetScrollRoute = CanvasWidgetScrollMethods.applyCanvasWidgetScrollRoute;
    pub const deepestCanvasWidgetScrollIndex = CanvasWidgetScrollMethods.deepestCanvasWidgetScrollIndex;
    pub const canvasWidgetScrollState = CanvasWidgetScrollMethods.canvasWidgetScrollState;
    pub const canvasWidgetScrollStateById = CanvasWidgetScrollMethods.canvasWidgetScrollStateById;
    pub const noteCanvasWidgetScrollEvent = CanvasWidgetScrollMethods.noteCanvasWidgetScrollEvent;
    pub const canvasWidgetScrollCanConsume = CanvasWidgetScrollMethods.canvasWidgetScrollCanConsume;
    pub const applyCanvasWidgetScroll = CanvasWidgetScrollMethods.applyCanvasWidgetScroll;
    pub const applyCanvasWidgetTextareaScroll = CanvasWidgetScrollMethods.applyCanvasWidgetTextareaScroll;
    pub const applyCanvasWidgetScrollDriverOffset = CanvasWidgetScrollMethods.applyCanvasWidgetScrollDriverOffset;
    pub const applyCanvasWidgetScrollKeyboardTarget = CanvasWidgetScrollMethods.applyCanvasWidgetScrollKeyboardTarget;
    pub const stepCanvasWidgetKineticScroll = CanvasWidgetScrollMethods.stepCanvasWidgetKineticScroll;
    pub const canvasWidgetScrollContentExtent = CanvasWidgetScrollMethods.canvasWidgetScrollContentExtent;
    pub const translateCanvasWidgetScrollDescendants = CanvasWidgetScrollMethods.translateCanvasWidgetScrollDescendants;
    pub const scrollCanvasTextareaCaretIntoView = CanvasWidgetScrollMethods.scrollCanvasTextareaCaretIntoView;

    const CanvasWidgetControlMethods = view_widget_control.RuntimeViewCanvasWidgetControl(RuntimeView);
    pub const canvasWidgetToggleAnimation = CanvasWidgetControlMethods.canvasWidgetToggleAnimation;
    pub const canvasWidgetToggleAnimationForPointer = CanvasWidgetControlMethods.canvasWidgetToggleAnimationForPointer;
    pub const canvasWidgetToggleAnimationForKeyboard = CanvasWidgetControlMethods.canvasWidgetToggleAnimationForKeyboard;
    pub const applyCanvasWidgetControlPointer = CanvasWidgetControlMethods.applyCanvasWidgetControlPointer;
    pub const applyCanvasWidgetResizableDelta = CanvasWidgetControlMethods.applyCanvasWidgetResizableDelta;
    pub const applyCanvasWidgetSplitPointer = CanvasWidgetControlMethods.applyCanvasWidgetSplitPointer;
    pub const applyCanvasWidgetSplitFraction = CanvasWidgetControlMethods.applyCanvasWidgetSplitFraction;
    pub const noteCanvasWidgetResizeEvent = CanvasWidgetControlMethods.noteCanvasWidgetResizeEvent;
    pub const translateCanvasWidgetDescendantsX = CanvasWidgetControlMethods.translateCanvasWidgetDescendantsX;
    pub const toggleCanvasWidgetTreeItemExpanded = CanvasWidgetControlMethods.toggleCanvasWidgetTreeItemExpanded;
    pub const applyCanvasWidgetControlKeyboard = CanvasWidgetControlMethods.applyCanvasWidgetControlKeyboard;
    pub const applyCanvasWidgetControlIntent = CanvasWidgetControlMethods.applyCanvasWidgetControlIntent;
    pub const applyCanvasWidgetSliderValue = CanvasWidgetControlMethods.applyCanvasWidgetSliderValue;
    pub const toggleCanvasWidgetBooleanControl = CanvasWidgetControlMethods.toggleCanvasWidgetBooleanControl;
    pub const setCanvasWidgetSelected = CanvasWidgetControlMethods.setCanvasWidgetSelected;
    pub const setCanvasWidgetValue = CanvasWidgetControlMethods.setCanvasWidgetValue;

    const CanvasFrameMethods = view_canvas.RuntimeViewCanvasFrame(RuntimeView);
    pub const canvasDisplayList = CanvasFrameMethods.canvasDisplayList;
    pub const validateCanvasWidgetDisplayListChrome = CanvasFrameMethods.validateCanvasWidgetDisplayListChrome;
    pub const canvasFrameResourceCache = CanvasFrameMethods.canvasFrameResourceCache;
    pub const canvasFramePathGeometryCache = CanvasFrameMethods.canvasFramePathGeometryCache;
    pub const canvasFrameImageCache = CanvasFrameMethods.canvasFrameImageCache;
    pub const canvasFrameLayerCache = CanvasFrameMethods.canvasFrameLayerCache;
    pub const canvasFrameVisualEffectCache = CanvasFrameMethods.canvasFrameVisualEffectCache;
    pub const canvasRenderAnimations = CanvasFrameMethods.canvasRenderAnimations;
    pub const canvasFrameRenderOverrides = CanvasFrameMethods.canvasFrameRenderOverrides;
    pub const canvasFramePipelineCache = CanvasFrameMethods.canvasFramePipelineCache;
    pub const canvasFrameGlyphAtlasCache = CanvasFrameMethods.canvasFrameGlyphAtlasCache;
    pub const canvasFrameTextLayoutCache = CanvasFrameMethods.canvasFrameTextLayoutCache;
    pub const copyCanvasDisplayList = CanvasFrameMethods.copyCanvasDisplayList;
    pub const copyCanvasFrameResourceCache = CanvasFrameMethods.copyCanvasFrameResourceCache;
    pub const copyCanvasFramePathGeometryCache = CanvasFrameMethods.copyCanvasFramePathGeometryCache;
    pub const copyCanvasFrameImageCache = CanvasFrameMethods.copyCanvasFrameImageCache;
    pub const copyCanvasFrameLayerCache = CanvasFrameMethods.copyCanvasFrameLayerCache;
    pub const copyCanvasFrameVisualEffectCache = CanvasFrameMethods.copyCanvasFrameVisualEffectCache;
    pub const copyCanvasRenderAnimations = CanvasFrameMethods.copyCanvasRenderAnimations;
    pub const replaceCanvasRenderAnimation = CanvasFrameMethods.replaceCanvasRenderAnimation;
    pub const removeCanvasRenderAnimation = CanvasFrameMethods.removeCanvasRenderAnimation;
    pub const replaceCanvasRenderAnimationDirtyBounds = CanvasFrameMethods.replaceCanvasRenderAnimationDirtyBounds;
    pub const removeCanvasRenderAnimationDirtyBounds = CanvasFrameMethods.removeCanvasRenderAnimationDirtyBounds;
    pub const canvasRenderAnimationDirtyBoundsForOverrides = CanvasFrameMethods.canvasRenderAnimationDirtyBoundsForOverrides;
    pub const copyCanvasFrameRenderOverrides = CanvasFrameMethods.copyCanvasFrameRenderOverrides;
    pub const compactCanvasFrameRenderOverrideNoops = CanvasFrameMethods.compactCanvasFrameRenderOverrideNoops;
    pub const sampleCanvasRenderAnimations = CanvasFrameMethods.sampleCanvasRenderAnimations;
    pub const pruneCompletedNoopCanvasRenderAnimations = CanvasFrameMethods.pruneCompletedNoopCanvasRenderAnimations;
    pub const canvasRenderAnimationsActive = CanvasFrameMethods.canvasRenderAnimationsActive;
    pub const copyCanvasFramePipelineCache = CanvasFrameMethods.copyCanvasFramePipelineCache;
    pub const copyCanvasFrameGlyphAtlasCache = CanvasFrameMethods.copyCanvasFrameGlyphAtlasCache;
    pub const copyCanvasFrameTextLayoutCache = CanvasFrameMethods.copyCanvasFrameTextLayoutCache;
    pub const recordCanvasFrame = CanvasFrameMethods.recordCanvasFrame;
    pub const recordCanvasFramePresentationComplete = CanvasFrameMethods.recordCanvasFramePresentationComplete;
    pub const refreshCanvasFrameBudgetStatus = CanvasFrameMethods.refreshCanvasFrameBudgetStatus;
    pub const copyPresentedCanvasSummary = CanvasFrameMethods.copyPresentedCanvasSummary;
    pub const copyPresentedCanvasSummaryFrom = CanvasFrameMethods.copyPresentedCanvasSummaryFrom;
    pub const currentCanvasHasUnkeyed = CanvasFrameMethods.currentCanvasHasUnkeyed;
    pub const diffPresentedCanvasSummary = CanvasFrameMethods.diffPresentedCanvasSummary;
    pub const currentCanvasCommandById = CanvasFrameMethods.currentCanvasCommandById;
    pub const presentedCanvasCommandById = CanvasFrameMethods.presentedCanvasCommandById;
    pub const copyCanvasCommand = CanvasFrameMethods.copyCanvasCommand;
    pub const copyCanvasStroke = CanvasFrameMethods.copyCanvasStroke;
    pub const copyCanvasFill = CanvasFrameMethods.copyCanvasFill;
    pub const copyCanvasGradientStops = CanvasFrameMethods.copyCanvasGradientStops;
    pub const copyCanvasPathElements = CanvasFrameMethods.copyCanvasPathElements;
    pub const copyCanvasGlyphs = CanvasFrameMethods.copyCanvasGlyphs;
    pub const copyCanvasText = CanvasFrameMethods.copyCanvasText;

    const CanvasWidgetTreeMethods = view_widget_tree.RuntimeViewCanvasWidgetTree(RuntimeView);
    pub const widgetLayoutTree = CanvasWidgetTreeMethods.widgetLayoutTree;
    pub const widgetSemantics = CanvasWidgetTreeMethods.widgetSemantics;
    pub const widgetSourceTextEntries = CanvasWidgetTreeMethods.widgetSourceTextEntries;
    pub const copyCanvasWidgetSourceText = CanvasWidgetTreeMethods.copyCanvasWidgetSourceText;
    pub const widgetSourceScrollEntries = CanvasWidgetTreeMethods.widgetSourceScrollEntries;
    pub const copyCanvasWidgetSourceScroll = CanvasWidgetTreeMethods.copyCanvasWidgetSourceScroll;
    pub const widgetSourceControlEntries = CanvasWidgetTreeMethods.widgetSourceControlEntries;
    pub const canvasWidgetAutofocusTarget = CanvasWidgetTreeMethods.canvasWidgetAutofocusTarget;
    pub const copyCanvasWidgetSourceControls = CanvasWidgetTreeMethods.copyCanvasWidgetSourceControls;
    pub const copyWidgetLayoutTree = CanvasWidgetTreeMethods.copyWidgetLayoutTree;
    pub const canvasWidgetCursorForId = CanvasWidgetTreeMethods.canvasWidgetCursorForId;
    pub const canvasWidgetRenderState = CanvasWidgetTreeMethods.canvasWidgetRenderState;
    pub const reconcileCanvasWidgetRenderStateAfterScroll = CanvasWidgetTreeMethods.reconcileCanvasWidgetRenderStateAfterScroll;
    pub const dismissCanvasWidgetSurfaceFromEscape = CanvasWidgetTreeMethods.dismissCanvasWidgetSurfaceFromEscape;
    pub const dismissCanvasWidgetSurfaceForTarget = CanvasWidgetTreeMethods.dismissCanvasWidgetSurfaceForTarget;
    pub const dismissCanvasWidgetSurfaceForTargetIndex = CanvasWidgetTreeMethods.dismissCanvasWidgetSurfaceForTargetIndex;
    pub const dismissCanvasWidgetSurfaceForPointerOutsideFocusedTarget = CanvasWidgetTreeMethods.dismissCanvasWidgetSurfaceForPointerOutsideFocusedTarget;
    pub const dismissCanvasWidgetSurfaceAtIndex = CanvasWidgetTreeMethods.dismissCanvasWidgetSurfaceAtIndex;
    pub const canvasWidgetDismissibleSurfaceIndexForTarget = CanvasWidgetTreeMethods.canvasWidgetDismissibleSurfaceIndexForTarget;
    pub const canvasWidgetAnchoredDismissibleChildIndex = CanvasWidgetTreeMethods.canvasWidgetAnchoredDismissibleChildIndex;
    pub const canvasWidgetTopmostAnchoredDismissibleIndex = CanvasWidgetTreeMethods.canvasWidgetTopmostAnchoredDismissibleIndex;
    pub const canvasWidgetRouteDescendsFromIndex = CanvasWidgetTreeMethods.canvasWidgetRouteDescendsFromIndex;
    pub const canvasWidgetScopedFocusTarget = CanvasWidgetTreeMethods.canvasWidgetScopedFocusTarget;
    pub const canvasWidgetFocusTargetInScope = CanvasWidgetTreeMethods.canvasWidgetFocusTargetInScope;
    pub const canvasWidgetForwardFocusTargetInScope = CanvasWidgetTreeMethods.canvasWidgetForwardFocusTargetInScope;
    pub const canvasWidgetBackwardFocusTargetInScope = CanvasWidgetTreeMethods.canvasWidgetBackwardFocusTargetInScope;
    pub const canvasWidgetFocusTargetAtScopedIndex = CanvasWidgetTreeMethods.canvasWidgetFocusTargetAtScopedIndex;
    pub const canvasWidgetIdDescendsFromIndex = CanvasWidgetTreeMethods.canvasWidgetIdDescendsFromIndex;
    pub const canvasWidgetNodeIndexDescendsFrom = CanvasWidgetTreeMethods.canvasWidgetNodeIndexDescendsFrom;
    pub const canvasWidgetNodeIndexById = CanvasWidgetTreeMethods.canvasWidgetNodeIndexById;
    pub const canvasWidgetCommand = CanvasWidgetTreeMethods.canvasWidgetCommand;
    pub const canvasWidgetStepKey = CanvasWidgetTreeMethods.canvasWidgetStepKey;
    pub const refreshCanvasWidgetSemantics = CanvasWidgetTreeMethods.refreshCanvasWidgetSemantics;
    pub const canvasWidgetDirtyBounds = CanvasWidgetTreeMethods.canvasWidgetDirtyBounds;
    pub const copyWidgetLayoutNode = CanvasWidgetTreeMethods.copyWidgetLayoutNode;
    pub const copyWidgetText = CanvasWidgetTreeMethods.copyWidgetText;
    pub const copyWidgetSpans = CanvasWidgetTreeMethods.copyWidgetSpans;
    pub const copyWidgetContextMenu = CanvasWidgetTreeMethods.copyWidgetContextMenu;
    pub const copyWidgetChart = CanvasWidgetTreeMethods.copyWidgetChart;

    // By pointer, never by value: a RuntimeView is multiple MiB of fixed
    // capacity arrays, and a by-value self parameter copies it onto the
    // caller's stack (method syntax auto-refs, so callers are unchanged).
    pub fn info(self: *const RuntimeView) platform.ViewInfo {
        return .{
            .id = self.id,
            .window_id = self.window_id,
            .label = self.label,
            .kind = self.kind,
            .parent = self.parent,
            .frame = self.frame,
            .layer = self.layer,
            .visible = self.visible,
            .enabled = self.enabled,
            .role = self.role,
            .accessibility_label = self.accessibility_label,
            .text = self.text,
            .command = self.command,
            .url = "",
            .transparent = self.transparent,
            .bridge_enabled = self.bridge_enabled,
            .gpu_size = self.gpu_size,
            .gpu_scale_factor = self.gpu_scale_factor,
            .gpu_frame_index = self.gpu_frame_index,
            .gpu_timestamp_ns = self.gpu_timestamp_ns,
            .gpu_frame_interval_ns = self.gpu_frame_interval_ns,
            .gpu_input_timestamp_ns = self.gpu_input_timestamp_ns,
            .gpu_input_latency_ns = self.gpu_input_latency_ns,
            .gpu_input_latency_budget_ns = self.gpu_input_latency_budget_ns,
            .gpu_input_latency_budget_exceeded_count = self.gpu_input_latency_budget_exceeded_count,
            .gpu_input_latency_budget_ok = self.gpu_input_latency_budget_ok,
            .gpu_first_frame_latency_ns = self.gpu_first_frame_latency_ns,
            .gpu_first_frame_latency_budget_ns = self.gpu_first_frame_latency_budget_ns,
            .gpu_first_frame_latency_budget_exceeded_count = self.gpu_first_frame_latency_budget_exceeded_count,
            .gpu_first_frame_latency_budget_ok = self.gpu_first_frame_latency_budget_ok,
            .gpu_frame_nonblank = self.gpu_frame_nonblank,
            .gpu_sample_color = self.gpu_sample_color,
            .gpu_backend = self.gpu_backend,
            .gpu_pixel_format = self.gpu_pixel_format,
            .gpu_present_mode = self.gpu_present_mode,
            .gpu_alpha_mode = self.gpu_alpha_mode,
            .gpu_color_space = self.gpu_color_space,
            .gpu_vsync = self.gpu_vsync,
            .gpu_status = self.gpu_status,
            .gpu_present_path = self.gpu_present_path,
            .gpu_present_fallback_reason = self.gpu_present_fallback_reason,
            .gpu_present_fallback_needed_bytes = self.gpu_present_fallback_needed_bytes,
            .gpu_present_fallback_limit_bytes = self.gpu_present_fallback_limit_bytes,
            .gpu_present_fallback_command_kind = self.gpu_present_fallback_command_kind_storage[0..self.gpu_present_fallback_command_kind_len],
            .gpu_present_fallback_frame_count = self.gpu_present_fallback_frame_count,
            .gpu_present_packet_mode = self.gpu_present_packet_mode,
            .gpu_present_patch_bytes = self.gpu_present_patch_bytes,
            .gpu_present_patch_upsert_count = self.gpu_present_patch_upsert_count,
            .gpu_present_patch_evict_count = self.gpu_present_patch_evict_count,
            .gpu_present_retained_command_count = if (self.canvas_packet_baseline_valid) self.canvas_packet_baseline_count else 0,
            .canvas_revision = self.canvas_revision,
            .canvas_command_count = self.canvas_command_count,
            .canvas_frame_requires_render = self.canvas_frame_requires_render,
            .canvas_frame_full_repaint = self.canvas_frame_full_repaint,
            .canvas_frame_batch_count = self.canvas_frame_batch_count,
            .canvas_frame_encoder_command_count = self.canvas_frame_encoder_command_count,
            .canvas_frame_encoder_cache_action_count = self.canvas_frame_encoder_cache_action_count,
            .canvas_frame_encoder_bind_pipeline_count = self.canvas_frame_encoder_bind_pipeline_count,
            .canvas_frame_encoder_draw_batch_count = self.canvas_frame_encoder_draw_batch_count,
            .canvas_frame_pipeline_count = self.canvas_frame_pipeline_count,
            .canvas_frame_pipeline_upload_count = self.canvas_frame_pipeline_upload_count,
            .canvas_frame_pipeline_retain_count = self.canvas_frame_pipeline_retain_count,
            .canvas_frame_pipeline_evict_count = self.canvas_frame_pipeline_evict_count,
            .canvas_frame_path_geometry_count = self.canvas_frame_path_geometry_count,
            .canvas_frame_path_geometry_vertex_count = self.canvas_frame_path_geometry_vertex_count,
            .canvas_frame_path_geometry_index_count = self.canvas_frame_path_geometry_index_count,
            .canvas_frame_path_geometry_upload_count = self.canvas_frame_path_geometry_upload_count,
            .canvas_frame_path_geometry_retain_count = self.canvas_frame_path_geometry_retain_count,
            .canvas_frame_path_geometry_evict_count = self.canvas_frame_path_geometry_evict_count,
            .canvas_frame_image_count = self.canvas_frame_image_count,
            .canvas_frame_image_upload_count = self.canvas_frame_image_upload_count,
            .canvas_frame_image_retain_count = self.canvas_frame_image_retain_count,
            .canvas_frame_image_evict_count = self.canvas_frame_image_evict_count,
            .canvas_frame_layer_count = self.canvas_frame_layer_count,
            .canvas_frame_layer_opacity_count = self.canvas_frame_layer_opacity_count,
            .canvas_frame_layer_clip_count = self.canvas_frame_layer_clip_count,
            .canvas_frame_layer_transform_count = self.canvas_frame_layer_transform_count,
            .canvas_frame_layer_upload_count = self.canvas_frame_layer_upload_count,
            .canvas_frame_layer_retain_count = self.canvas_frame_layer_retain_count,
            .canvas_frame_layer_evict_count = self.canvas_frame_layer_evict_count,
            .canvas_frame_resource_count = self.canvas_frame_resource_count,
            .canvas_frame_resource_upload_count = self.canvas_frame_resource_upload_count,
            .canvas_frame_resource_retain_count = self.canvas_frame_resource_retain_count,
            .canvas_frame_resource_evict_count = self.canvas_frame_resource_evict_count,
            .canvas_frame_visual_effect_count = self.canvas_frame_visual_effect_count,
            .canvas_frame_visual_effect_shadow_count = self.canvas_frame_visual_effect_shadow_count,
            .canvas_frame_visual_effect_blur_count = self.canvas_frame_visual_effect_blur_count,
            .canvas_frame_visual_effect_upload_count = self.canvas_frame_visual_effect_upload_count,
            .canvas_frame_visual_effect_retain_count = self.canvas_frame_visual_effect_retain_count,
            .canvas_frame_visual_effect_evict_count = self.canvas_frame_visual_effect_evict_count,
            .canvas_frame_glyph_atlas_entry_count = self.canvas_frame_glyph_atlas_entry_count,
            .canvas_frame_glyph_atlas_upload_count = self.canvas_frame_glyph_atlas_upload_count,
            .canvas_frame_glyph_atlas_retain_count = self.canvas_frame_glyph_atlas_retain_count,
            .canvas_frame_glyph_atlas_evict_count = self.canvas_frame_glyph_atlas_evict_count,
            .canvas_frame_text_layout_count = self.canvas_frame_text_layout_count,
            .canvas_frame_text_layout_line_count = self.canvas_frame_text_layout_line_count,
            .canvas_frame_text_layout_upload_count = self.canvas_frame_text_layout_upload_count,
            .canvas_frame_text_layout_retain_count = self.canvas_frame_text_layout_retain_count,
            .canvas_frame_text_layout_evict_count = self.canvas_frame_text_layout_evict_count,
            .canvas_frame_gpu_packet_command_count = self.canvas_frame_gpu_packet_command_count,
            .canvas_frame_gpu_packet_cache_action_count = self.canvas_frame_gpu_packet_cache_action_count,
            .canvas_frame_gpu_packet_cached_resource_command_count = self.canvas_frame_gpu_packet_cached_resource_command_count,
            .canvas_frame_gpu_packet_unsupported_command_count = self.canvas_frame_gpu_packet_unsupported_command_count,
            .canvas_frame_gpu_packet_representable = self.canvas_frame_gpu_packet_representable,
            .canvas_frame_change_count = self.canvas_frame_change_count,
            .canvas_frame_budget_exceeded_count = self.canvas_frame_budget_status.exceededCount(),
            .canvas_frame_budget_ok = self.canvas_frame_budget_status.ok(),
            .canvas_frame_dirty_bounds = self.canvas_frame_dirty_bounds,
            .canvas_frame_profile_work_units = self.canvas_frame_profile_work_units,
            .canvas_frame_profile_risk = self.canvas_frame_profile_risk,
            .canvas_frame_profile_surface_area = self.canvas_frame_profile_surface_area,
            .canvas_frame_profile_dirty_area = self.canvas_frame_profile_dirty_area,
            .canvas_frame_profile_dirty_ratio = self.canvas_frame_profile_dirty_ratio,
            .widget_revision = self.widget_revision,
            .widget_node_count = self.widget_layout_node_count,
            .widget_semantics_count = self.widget_semantics_node_count,
            .widget_context_menu_item_count = self.widget_context_menu_len,
            .cursor = self.canvas_widget_cursor,
            .focused = self.focused,
            .open = self.open,
        };
    }

    pub fn recordGpuSurfaceInputTimestamp(self: *RuntimeView, timestamp_ns: u64) void {
        if (timestamp_ns == 0) return;
        self.gpu_pending_input_timestamp_ns = timestamp_ns;
        self.gpu_input_timestamp_ns = timestamp_ns;
    }

    pub fn recordGpuSurfaceInputLatencyForFrame(self: *RuntimeView, timestamp_ns: u64) void {
        const input_timestamp_ns = self.gpu_pending_input_timestamp_ns;
        if (input_timestamp_ns == 0 or timestamp_ns < input_timestamp_ns) return;
        self.gpu_pending_input_timestamp_ns = 0;
        self.gpu_input_timestamp_ns = input_timestamp_ns;
        self.gpu_input_latency_ns = timestamp_ns - input_timestamp_ns;
        self.refreshGpuSurfaceInputLatencyBudgetStatus();
    }

    pub fn refreshGpuSurfaceInputLatencyBudgetStatus(self: *RuntimeView) void {
        self.gpu_input_latency_budget_exceeded_count = if (self.gpu_input_latency_budget_ns > 0 and self.gpu_input_latency_ns > self.gpu_input_latency_budget_ns) 1 else 0;
        self.gpu_input_latency_budget_ok = self.gpu_input_latency_budget_exceeded_count == 0;
    }

    pub fn recordGpuSurfaceFrameInterval(self: *RuntimeView, frame_interval_ns: u64) void {
        const normalized = if (frame_interval_ns > 0) frame_interval_ns else platform.default_gpu_frame_interval_ns;
        self.gpu_frame_interval_ns = normalized;
        if (!self.gpu_input_latency_budget_custom) {
            self.gpu_input_latency_budget_ns = normalized;
            self.refreshGpuSurfaceInputLatencyBudgetStatus();
        }
    }

    pub fn recordGpuSurfaceFirstFrameLatency(self: *RuntimeView, timestamp_ns: u64) void {
        if (self.gpu_first_frame_latency_recorded) return;
        if (self.gpu_surface_created_timestamp_ns == 0 or timestamp_ns < self.gpu_surface_created_timestamp_ns) return;
        self.gpu_first_frame_latency_recorded = true;
        self.gpu_first_frame_latency_ns = timestamp_ns - self.gpu_surface_created_timestamp_ns;
        self.refreshGpuSurfaceFirstFrameLatencyBudgetStatus();
    }

    pub fn refreshGpuSurfaceFirstFrameLatencyBudgetStatus(self: *RuntimeView) void {
        self.gpu_first_frame_latency_budget_exceeded_count = if (self.gpu_first_frame_latency_budget_ns > 0 and self.gpu_first_frame_latency_ns > self.gpu_first_frame_latency_budget_ns) 1 else 0;
        self.gpu_first_frame_latency_budget_ok = self.gpu_first_frame_latency_budget_exceeded_count == 0;
    }

    pub fn copyRuntimeStateFrom(self: *RuntimeView, source: *const RuntimeView, scratch: *canvas_widget_runtime.CanvasWidgetCopyScratch) void {
        self.* = source.*;
        self.label = copyInto(&self.label_storage, source.label) catch unreachable;
        self.parent = if (source.parent) |parent| copyInto(&self.parent_storage, parent) catch unreachable else null;
        self.role = copyInto(&self.role_storage, source.role) catch unreachable;
        self.accessibility_label = copyInto(&self.accessibility_label_storage, source.accessibility_label) catch unreachable;
        self.text = copyInto(&self.text_storage, source.text) catch unreachable;
        self.command = copyInto(&self.command_storage, source.command) catch unreachable;
        self.copyCanvasDisplayList(source.canvasDisplayList()) catch unreachable;
        self.canvas_revision = source.canvas_revision;
        self.copyPresentedCanvasSummaryFrom(source);
        self.copyWidgetLayoutTree(source.widgetLayoutTree(), scratch) catch unreachable;
        self.widget_revision = source.widget_revision;
        @memcpy(self.widget_scroll_states[0..source.widget_layout_node_count], source.widget_scroll_states[0..source.widget_layout_node_count]);
    }
};
