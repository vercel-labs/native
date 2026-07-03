pub const max_canvas_commands_per_view: usize = 1024;
pub const max_canvas_gradient_stops_per_view: usize = 64;
pub const max_canvas_path_elements_per_view: usize = 128;
pub const max_canvas_glyphs_per_view: usize = 4096;
pub const max_canvas_text_bytes_per_view: usize = 16384;
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

pub const max_canvas_widget_nodes_per_view: usize = 256;
pub const max_canvas_widget_semantics_per_view: usize = 256;
// Raised from 2048 with the inline-span/markdown work: a rendered document
// retains its full plain text (paragraph bytes are stored once; span slices
// rebase into them) plus link payloads, and 2048 bytes could not hold a
// README-sized document. Sized to match max_canvas_text_bytes_per_view.
pub const max_canvas_widget_text_bytes_per_view: usize = 16384;
pub const max_canvas_widget_source_text_entries_per_view: usize = 64;
// Inline styled runs retained across all `.text` widgets of a view. Each
// span is a small struct (style flags + slices into the widget text
// bytes); per-paragraph capacity is `canvas.max_text_spans_per_paragraph`.
pub const max_canvas_widget_spans_per_view: usize = 256;
pub const max_canvas_widget_invalidations_per_view: usize = max_canvas_widget_nodes_per_view * 2 + 1;
