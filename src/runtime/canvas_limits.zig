// Per-view canvas budgets. Fixed, documented, loud: capacities are compile
// time constants sized for a dense desktop view, overflow errors name the
// budget, and the automation snapshot reports headroom (widget_nodes=N/MAX).
//
// Raised for the ovation PR round (friction #62): a real three-pane desktop
// app (sidebar tree + markdown detail pane + run surface) spent more design
// effort budgeting nodes than building UI at the old 256-node cap. The
// widget-node budget quadrupled (256 -> 1024: the measured worst realistic
// three-pane view is ~500 nodes, so 1024 leaves comfortable headroom), and
// the frame-content budgets doubled (commands 1024 -> 2048, glyphs
// 4096 -> 8192, text 16 KiB -> 32 KiB: visible content per frame grows with
// surface density, not with the retained-node cap — a full-height monospace
// diff pane is ~7200 glyphs). Memory cost is fixed-capacity address space
// in the Runtime (in-place constructed, large fields left uninitialized),
// measured at 61.3 MiB -> 119.3 MiB (RuntimeView 1.12 MiB -> 2.65 MiB x 32
// view slots); pages are only touched as views use their capacity.
pub const max_canvas_commands_per_view: usize = 2048;
pub const max_canvas_gradient_stops_per_view: usize = 64;
pub const max_canvas_path_elements_per_view: usize = 128;
pub const max_canvas_glyphs_per_view: usize = 8192;
pub const max_canvas_text_bytes_per_view: usize = 32768;
pub const max_canvas_diff_changes_per_view: usize = max_canvas_commands_per_view * 2 + 1;
pub const max_canvas_render_animations_per_view: usize = max_canvas_commands_per_view;
pub const max_canvas_render_animation_dirty_bounds_per_view: usize = 8;
pub const max_canvas_render_overrides_per_view: usize = max_canvas_commands_per_view;
pub const max_canvas_pipelines_per_view: usize = 8;
pub const max_canvas_pipeline_cache_actions_per_view: usize = max_canvas_pipelines_per_view * 2;
pub const max_canvas_path_geometries_per_view: usize = max_canvas_commands_per_view;
pub const max_canvas_path_geometry_cache_actions_per_view: usize = max_canvas_path_geometries_per_view * 2;
pub const max_canvas_images_per_view: usize = max_canvas_commands_per_view;
pub const max_canvas_image_cache_actions_per_view: usize = max_canvas_images_per_view * 2;
pub const max_canvas_layers_per_view: usize = max_canvas_commands_per_view;
pub const max_canvas_layer_cache_actions_per_view: usize = max_canvas_layers_per_view * 2;
pub const max_canvas_resources_per_view: usize = max_canvas_commands_per_view;
pub const max_canvas_resource_cache_actions_per_view: usize = max_canvas_resources_per_view * 2;
pub const max_canvas_visual_effects_per_view: usize = max_canvas_commands_per_view;
pub const max_canvas_visual_effect_cache_actions_per_view: usize = max_canvas_visual_effects_per_view * 2;
pub const max_canvas_text_layouts_per_view: usize = 512;

// Runtime-registered canvas images: decoded RGBA pixel buffers apps
// register under a caller-chosen ImageId and reference from image/icon/
// avatar widgets. Slots are runtime-wide (all views share the registry;
// the frame planner threads it into every view's `image_resources`), and
// the runtime owns the pixel copies — the app's source buffer is free the
// moment registration returns. The per-image ceiling is avatar/icon
// scale (512x512 RGBA8), not photo scale; oversized registrations and
// decodes fail loudly with `error.ImageTooLarge`.
pub const max_registered_canvas_images: usize = 16;
pub const max_registered_canvas_image_pixel_bytes: usize = 1024 * 1024;

// The retained widget-tree budgets (raised 256 -> 1024 for friction #62,
// see the header comment). `automation.snapshot.max_widgets_per_view`
// mirrors the node cap so snapshots never silently truncate widget
// enumeration; a test in canvas_widget_layout_tests.zig keeps them in
// lockstep.
pub const max_canvas_widget_nodes_per_view: usize = 1024;
pub const max_canvas_widget_semantics_per_view: usize = 1024;
// Raised from 2048 with the inline-span/markdown work: a rendered document
// retains its full plain text (paragraph bytes are stored once; span slices
// rebase into them) plus link payloads, and 2048 bytes could not hold a
// README-sized document. Raised again with the node-budget raise (#62):
// a 1024-node view retains proportionally more text.
pub const max_canvas_widget_text_bytes_per_view: usize = 65536;
pub const max_canvas_widget_source_text_entries_per_view: usize = 256;
// Inline styled runs retained across all `.text` widgets of a view. Each
// span is a small struct (style flags + slices into the widget text
// bytes); per-paragraph capacity is `canvas.max_text_spans_per_paragraph`.
pub const max_canvas_widget_spans_per_view: usize = 1024;
// Declared native context-menu entries retained across all widgets of a
// view (labels live in the widget text bytes).
pub const max_canvas_widget_context_menu_items_per_view: usize = 128;
pub const max_canvas_widget_invalidations_per_view: usize = max_canvas_widget_nodes_per_view * 2 + 1;
// Scroll containers whose offset changed since the last app dispatch:
// entries are node ids, deduped, and the dispatched event reads the
// CURRENT scroll state, so coalescing wheel + kinetic steps into one
// pending entry is lossless. A view realistically has 1-2 concurrently
// moving scrollables; ids past the bound are dropped (the offsets still
// apply and repaint — only the observation Msg is skipped).
pub const max_canvas_widget_scroll_events_per_view: usize = 8;
