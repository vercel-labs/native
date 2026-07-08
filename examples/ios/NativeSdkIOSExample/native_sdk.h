#pragma once

#include <stddef.h>
#include <stdint.h>

enum {
  NATIVE_SDK_WIDGET_ROLE_NONE = 0,
  NATIVE_SDK_WIDGET_ROLE_GROUP = 1,
  NATIVE_SDK_WIDGET_ROLE_TEXT = 2,
  NATIVE_SDK_WIDGET_ROLE_IMAGE = 3,
  NATIVE_SDK_WIDGET_ROLE_BUTTON = 4,
  NATIVE_SDK_WIDGET_ROLE_TEXTBOX = 5,
  NATIVE_SDK_WIDGET_ROLE_TOOLTIP = 6,
  NATIVE_SDK_WIDGET_ROLE_DIALOG = 7,
  NATIVE_SDK_WIDGET_ROLE_MENU = 8,
  NATIVE_SDK_WIDGET_ROLE_MENUITEM = 9,
  NATIVE_SDK_WIDGET_ROLE_LIST = 10,
  NATIVE_SDK_WIDGET_ROLE_LISTITEM = 11,
  NATIVE_SDK_WIDGET_ROLE_ROW = 12,
  NATIVE_SDK_WIDGET_ROLE_GRID = 13,
  NATIVE_SDK_WIDGET_ROLE_GRIDCELL = 14,
  NATIVE_SDK_WIDGET_ROLE_TAB = 15,
  NATIVE_SDK_WIDGET_ROLE_CHECKBOX = 16,
  NATIVE_SDK_WIDGET_ROLE_SWITCH = 17,
  NATIVE_SDK_WIDGET_ROLE_SLIDER = 18,
  NATIVE_SDK_WIDGET_ROLE_PROGRESSBAR = 19,
};

enum {
  NATIVE_SDK_WIDGET_FLAG_FOCUSED = 1u << 0,
  NATIVE_SDK_WIDGET_FLAG_HOVERED = 1u << 1,
  NATIVE_SDK_WIDGET_FLAG_PRESSED = 1u << 2,
  NATIVE_SDK_WIDGET_FLAG_SELECTED = 1u << 3,
  NATIVE_SDK_WIDGET_FLAG_DISABLED = 1u << 4,
  NATIVE_SDK_WIDGET_FLAG_FOCUSABLE = 1u << 5,
  NATIVE_SDK_WIDGET_FLAG_EXPANDED = 1u << 6,
  NATIVE_SDK_WIDGET_FLAG_COLLAPSED = 1u << 7,
  NATIVE_SDK_WIDGET_FLAG_REQUIRED = 1u << 8,
  NATIVE_SDK_WIDGET_FLAG_READ_ONLY = 1u << 9,
  NATIVE_SDK_WIDGET_FLAG_INVALID = 1u << 10,
};

enum {
  NATIVE_SDK_WIDGET_ACTION_FOCUS = 1u << 0,
  NATIVE_SDK_WIDGET_ACTION_PRESS = 1u << 1,
  NATIVE_SDK_WIDGET_ACTION_TOGGLE = 1u << 2,
  NATIVE_SDK_WIDGET_ACTION_INCREMENT = 1u << 3,
  NATIVE_SDK_WIDGET_ACTION_DECREMENT = 1u << 4,
  NATIVE_SDK_WIDGET_ACTION_SET_TEXT = 1u << 5,
  NATIVE_SDK_WIDGET_ACTION_SET_SELECTION = 1u << 6,
  NATIVE_SDK_WIDGET_ACTION_SELECT = 1u << 7,
  NATIVE_SDK_WIDGET_ACTION_DRAG = 1u << 8,
  NATIVE_SDK_WIDGET_ACTION_DROP_FILES = 1u << 9,
};

enum {
  NATIVE_SDK_WIDGET_ACTION_KIND_FOCUS = 0,
  NATIVE_SDK_WIDGET_ACTION_KIND_PRESS = 1,
  NATIVE_SDK_WIDGET_ACTION_KIND_TOGGLE = 2,
  NATIVE_SDK_WIDGET_ACTION_KIND_INCREMENT = 3,
  NATIVE_SDK_WIDGET_ACTION_KIND_DECREMENT = 4,
  NATIVE_SDK_WIDGET_ACTION_KIND_SET_TEXT = 5,
  NATIVE_SDK_WIDGET_ACTION_KIND_SET_SELECTION = 6,
  NATIVE_SDK_WIDGET_ACTION_KIND_SET_COMPOSITION = 7,
  NATIVE_SDK_WIDGET_ACTION_KIND_COMMIT_COMPOSITION = 8,
  NATIVE_SDK_WIDGET_ACTION_KIND_CANCEL_COMPOSITION = 9,
  NATIVE_SDK_WIDGET_ACTION_KIND_SELECT = 10,
  NATIVE_SDK_WIDGET_ACTION_KIND_DRAG = 11,
  NATIVE_SDK_WIDGET_ACTION_KIND_DROP_FILES = 12,
};
enum {
  NATIVE_SDK_GPU_SURFACE_STATUS_UNAVAILABLE = 0,
  NATIVE_SDK_GPU_SURFACE_STATUS_INITIALIZING = 1,
  NATIVE_SDK_GPU_SURFACE_STATUS_READY = 2,
  NATIVE_SDK_GPU_SURFACE_STATUS_LOST = 3,
};

typedef struct native_sdk_widget_semantics {
  uint64_t id;
  uint64_t parent_id;
  int role;
  uint32_t flags;
  uint32_t actions;
  float x;
  float y;
  float width;
  float height;
  float value;
  int has_value;
  const char *label;
  uintptr_t label_len;
  const char *text;
  uintptr_t text_len;
  const char *placeholder;
  uintptr_t placeholder_len;
  intptr_t text_selection_start;
  intptr_t text_selection_end;
  intptr_t text_composition_start;
  intptr_t text_composition_end;
  intptr_t grid_row_index;
  intptr_t grid_column_index;
  intptr_t grid_row_count;
  intptr_t grid_column_count;
  intptr_t list_item_index;
  intptr_t list_item_count;
  float scroll_offset;
  float scroll_viewport_extent;
  float scroll_content_extent;
  int has_scroll;
} native_sdk_widget_semantics_t;

typedef struct native_sdk_widget_text_geometry {
  uint64_t id;
  int has_caret_bounds;
  float caret_x;
  float caret_y;
  float caret_width;
  float caret_height;
  int has_selection_bounds;
  float selection_x;
  float selection_y;
  float selection_width;
  float selection_height;
  uintptr_t selection_rect_count;
  int has_composition_bounds;
  float composition_x;
  float composition_y;
  float composition_width;
  float composition_height;
  uintptr_t composition_rect_count;
} native_sdk_widget_text_geometry_t;

typedef struct native_sdk_widget_action {
  uint64_t id;
  int action;
  const char *text;
  uintptr_t text_len;
  uintptr_t selection_anchor;
  uintptr_t selection_focus;
  int has_selection;
} native_sdk_widget_action_t;

typedef struct native_sdk_canvas_pixels {
  uintptr_t width;
  uintptr_t height;
  uintptr_t byte_len;
} native_sdk_canvas_pixels_t;

// Result of native_sdk_app_render_pixels_damage: the surface dimensions
// plus the damaged region the call wrote into the caller's RETAINED
// buffer, in device pixels. damage_width == 0 (or damage_height == 0)
// means nothing changed since the previous call: the buffer already
// shows the current frame and the host skips its upload entirely.
typedef struct native_sdk_canvas_pixels_damage {
  uintptr_t width;
  uintptr_t height;
  uintptr_t byte_len;
  uintptr_t damage_x;
  uintptr_t damage_y;
  uintptr_t damage_width;
  uintptr_t damage_height;
  // The retained-canvas revision the buffer now REFLECTS: gate re-renders
  // on canvas_revision != this value (a change whose frame has not
  // presented yet reports the OLD revision with empty damage - call again
  // next tick), never on your own last sighting of canvas_revision.
  uint64_t revision;
} native_sdk_canvas_pixels_damage_t;

typedef struct native_sdk_text_input_state {
  int active;
  uint64_t widget_id;
  float x;
  float y;
  float width;
  float height;
} native_sdk_text_input_state_t;

typedef struct native_sdk_viewport_state {
  float width;
  float height;
  float scale;
  int has_surface;
  float safe_top;
  float safe_right;
  float safe_bottom;
  float safe_left;
  float keyboard_top;
  float keyboard_right;
  float keyboard_bottom;
  float keyboard_left;
  float content_x;
  float content_y;
  float content_width;
  float content_height;
} native_sdk_viewport_state_t;
typedef struct native_sdk_gpu_frame_state {
  uint64_t surface_id;
  uint64_t window_id;
  float width;
  float height;
  float scale;
  uint64_t frame_index;
  uint64_t timestamp_ns;
  uint64_t frame_interval_ns;
  uint64_t input_timestamp_ns;
  uint64_t input_latency_ns;
  uint64_t input_latency_budget_ns;
  uintptr_t input_latency_budget_exceeded_count;
  int input_latency_budget_ok;
  uint64_t first_frame_latency_ns;
  uint64_t first_frame_latency_budget_ns;
  uintptr_t first_frame_latency_budget_exceeded_count;
  int first_frame_latency_budget_ok;
  int nonblank;
  uint32_t sample_color;
  int status;
  int vsync;
  uint64_t canvas_revision;
  uintptr_t canvas_command_count;
  int canvas_frame_requires_render;
  int canvas_frame_full_repaint;
  uintptr_t canvas_frame_batch_count;
  uintptr_t canvas_frame_budget_exceeded_count;
  int canvas_frame_budget_ok;
  uint64_t widget_revision;
  uintptr_t widget_node_count;
  uintptr_t widget_semantics_count;
} native_sdk_gpu_frame_state_t;

// Form-factor ordinals accepted by native_sdk_app_set_form_factor.
enum {
  NATIVE_SDK_FORM_FACTOR_UNKNOWN = 0,
  NATIVE_SDK_FORM_FACTOR_COMPACT = 1,
  NATIVE_SDK_FORM_FACTOR_REGULAR = 2,
};

// One declared platform-chrome tab (or the primary action) from the
// app's shell metadata. Strings reference static app data (valid for
// the app's lifetime, not NUL-terminated). Layout mirrors
// src/embed/chrome.zig MobileChromeItem.
typedef struct native_sdk_chrome_item {
  const char *id;
  uintptr_t id_len;
  const char *label;
  uintptr_t label_len;
  const char *icon;
  uintptr_t icon_len;
} native_sdk_chrome_item_t;

void *native_sdk_app_create(void);
void native_sdk_app_destroy(void *app);
void native_sdk_app_start(void *app);
void native_sdk_app_activate(void *app);
void native_sdk_app_deactivate(void *app);
void native_sdk_app_stop(void *app);
void native_sdk_app_resize(void *app, float width, float height, float scale, void *surface);
void native_sdk_app_viewport(void *app, float width, float height, float scale, void *surface, float safe_top, float safe_right, float safe_bottom, float safe_left, float keyboard_top, float keyboard_right, float keyboard_bottom, float keyboard_left);
int native_sdk_app_viewport_state(void *app, native_sdk_viewport_state_t *out);
int native_sdk_app_gpu_frame_state(void *app, native_sdk_gpu_frame_state_t *out);
void native_sdk_app_touch(void *app, uint64_t id, int phase, float x, float y, float pressure);
void native_sdk_app_scroll(void *app, uint64_t id, float x, float y, float delta_x, float delta_y);
void native_sdk_app_key(void *app, int phase, const char *key, uintptr_t key_len, const char *text, uintptr_t text_len, uint32_t modifiers_mask);
void native_sdk_app_text(void *app, const char *text, uintptr_t len);
void native_sdk_app_ime(void *app, int kind, const char *text, uintptr_t len, intptr_t cursor);
void native_sdk_app_command(void *app, const char *name, uintptr_t len);
void native_sdk_app_frame(void *app);
// Declared platform chrome (the app's shell-metadata tab set + optional
// primary action): query the declaration once at startup, build REAL
// native controls, poll the model-selected tab index each frame (-1 =
// none), and dispatch taps back through native_sdk_app_command with the
// declared ids. The icon rasterizer renders a declared icon-vocabulary
// glyph as premultiplied white on transparent RGBA8 (size_px * size_px
// * 4 bytes) — a template image the system control tints.
uintptr_t native_sdk_app_chrome_tab_count(void *app);
int native_sdk_app_chrome_tab_at(void *app, uintptr_t index, native_sdk_chrome_item_t *out);
int native_sdk_app_chrome_primary_action(void *app, native_sdk_chrome_item_t *out);
intptr_t native_sdk_app_chrome_selected_tab(void *app);
// Model-driven navigation depth for platform push/pop transitions (0 =
// the root page, 1 = one push in; -1 = the app declares no navigation
// projection), polled each tick, and the declared back command a
// completed platform back gesture dispatches through
// native_sdk_app_command (1 with out->id filled when declared, 0
// otherwise — never arm the interactive back gesture without it).
intptr_t native_sdk_app_chrome_navigation_depth(void *app);
int native_sdk_app_chrome_navigation_back_command(void *app, native_sdk_chrome_item_t *out);
int native_sdk_app_chrome_icon_pixels(void *app, const char *name, uintptr_t name_len, uintptr_t size_px, uint8_t *pixels, uintptr_t pixels_len);
// Host chrome reports on the window-chrome channel: the reported form
// factor (host truth apps prefer over width derivation) and whether the
// declared tabs are currently projected as native controls.
int native_sdk_app_set_form_factor(void *app, int form_factor);
int native_sdk_app_set_chrome_tabs_projected(void *app, int projected);
void native_sdk_app_set_asset_root(void *app, const char *path, uintptr_t len);
void native_sdk_app_set_asset_entry(void *app, const char *path, uintptr_t len);
uintptr_t native_sdk_app_last_command_count(void *app);
const char *native_sdk_app_last_command_name(void *app);
const char *native_sdk_app_last_error_name(void *app);
uintptr_t native_sdk_app_widget_semantics_count(void *app);
int native_sdk_app_widget_semantics_at(void *app, uintptr_t index, native_sdk_widget_semantics_t *out);
int native_sdk_app_widget_semantics_by_id(void *app, uint64_t id, native_sdk_widget_semantics_t *out);
int native_sdk_app_widget_text_geometry(void *app, uint64_t id, native_sdk_widget_text_geometry_t *out);
int native_sdk_app_widget_action(void *app, const native_sdk_widget_action_t *action);
int native_sdk_app_text_input_state(void *app, native_sdk_text_input_state_t *out);
// Platform text measurement for layout: returns the typographic width of a
// single-line UTF-8 run at `size` for `font_id` (1 = sans, 2 = mono),
// measured with the same font resolution presentation draws with. Return a
// negative value to fall back to the deterministic estimator (e.g. invalid
// UTF-8). Register before native_sdk_app_start; pass NULL to fall back to
// the estimator on the next layout.
typedef double (*native_sdk_text_measure_fn)(void *context, uint64_t font_id, double size, const char *text, uintptr_t text_len);
int native_sdk_app_set_text_measure(void *app, native_sdk_text_measure_fn measure, void *context);
int native_sdk_app_set_automation_dir(void *app, const char *path, uintptr_t len);
int native_sdk_app_render_pixel_size(void *app, float scale, native_sdk_canvas_pixels_t *out);
int native_sdk_app_render_pixels(void *app, float scale, uint8_t *pixels, uintptr_t pixels_len, native_sdk_canvas_pixels_t *out);
// Incremental sibling of native_sdk_app_render_pixels for a host that
// keeps `pixels` RETAINED across calls (one buffer, one consumer): the
// fast path copies only the pixels changed since the previous call —
// captured off the runtime's own dirty-scissored raster, no second
// render — and reports that region; the first call (and any size or
// scale change) fills the whole buffer with full damage.
int native_sdk_app_render_pixels_damage(void *app, float scale, uint8_t *pixels, uintptr_t pixels_len, native_sdk_canvas_pixels_damage_t *out);
