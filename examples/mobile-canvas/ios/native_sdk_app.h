// C declarations for the subset of the `native_sdk_app_*` embed ABI the
// canvas shim drives: create/start/viewport/frame plus the RGBA render
// exports (M2) and the touch/scroll/text/IME, focus-state, semantics, and
// automation exports (M3). The full ABI is declared in
// examples/ios/NativeSdkIOSExample/native_sdk.h; struct layouts mirror
// src/embed/types.zig.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
  NATIVE_SDK_GPU_SURFACE_STATUS_UNAVAILABLE = 0,
  NATIVE_SDK_GPU_SURFACE_STATUS_INITIALIZING = 1,
  NATIVE_SDK_GPU_SURFACE_STATUS_READY = 2,
  NATIVE_SDK_GPU_SURFACE_STATUS_LOST = 3,
};

// UITouch phases accepted by native_sdk_app_touch.
enum {
  NATIVE_SDK_TOUCH_PHASE_DOWN = 0,
  NATIVE_SDK_TOUCH_PHASE_UP = 1,
  NATIVE_SDK_TOUCH_PHASE_DRAG = 2,
  NATIVE_SDK_TOUCH_PHASE_CANCEL = 3,
};

// IME event kinds accepted by native_sdk_app_ime.
enum {
  NATIVE_SDK_IME_SET_COMPOSITION = 0,
  NATIVE_SDK_IME_COMMIT_COMPOSITION = 1,
  NATIVE_SDK_IME_CANCEL_COMPOSITION = 2,
};

// Key phases accepted by native_sdk_app_key.
enum {
  NATIVE_SDK_KEY_PHASE_DOWN = 0,
  NATIVE_SDK_KEY_PHASE_UP = 1,
};

typedef struct native_sdk_canvas_pixels {
  uintptr_t width;
  uintptr_t height;
  uintptr_t byte_len;
} native_sdk_canvas_pixels_t;

typedef struct native_sdk_text_input_state {
  int active;
  uint64_t widget_id;
  float x;
  float y;
  float width;
  float height;
} native_sdk_text_input_state_t;

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

typedef struct native_sdk_viewport {
  float width;
  float height;
  float scale;
  void *surface;
  float safe_top;
  float safe_right;
  float safe_bottom;
  float safe_left;
  float keyboard_top;
  float keyboard_right;
  float keyboard_bottom;
  float keyboard_left;
} native_sdk_viewport_t;

void *native_sdk_app_create(void);
void native_sdk_app_destroy(void *app);
void native_sdk_app_start(void *app);
void native_sdk_app_activate(void *app);
void native_sdk_app_deactivate(void *app);
void native_sdk_app_stop(void *app);
void native_sdk_app_viewport(void *app, const native_sdk_viewport_t *viewport);
int native_sdk_app_gpu_frame_state(void *app, native_sdk_gpu_frame_state_t *out);
void native_sdk_app_frame(void *app);
const char *native_sdk_app_last_error_name(void *app);
int native_sdk_app_render_pixel_size(void *app, float scale, native_sdk_canvas_pixels_t *out);
int native_sdk_app_render_pixels(void *app, float scale, uint8_t *pixels, uintptr_t pixels_len, native_sdk_canvas_pixels_t *out);
void native_sdk_app_touch(void *app, uint64_t id, int phase, float x, float y, float pressure);
void native_sdk_app_scroll(void *app, uint64_t id, float x, float y, float delta_x, float delta_y);
void native_sdk_app_key(void *app, int phase, const char *key, uintptr_t key_len, const char *text, uintptr_t text_len, uint32_t modifiers_mask);
void native_sdk_app_text(void *app, const char *text, uintptr_t len);
void native_sdk_app_ime(void *app, int kind, const char *text, uintptr_t len, intptr_t cursor);
int native_sdk_app_text_input_state(void *app, native_sdk_text_input_state_t *out);
// Platform text measurement for layout (M5): returns the typographic width
// of a single-line UTF-8 run at `size` for `font_id` (1 = sans, 2 = mono),
// measured with the same font resolution presentation draws with. Return a
// negative value to fall back to the deterministic estimator (e.g. invalid
// UTF-8). Register before native_sdk_app_start; pass NULL to fall back to
// the estimator on the next layout.
typedef double (*native_sdk_text_measure_fn)(void *context, uint64_t font_id, double size, const char *text, uintptr_t text_len);
int native_sdk_app_set_text_measure(void *app, native_sdk_text_measure_fn measure, void *context);
int native_sdk_app_set_automation_dir(void *app, const char *path, uintptr_t len);
uintptr_t native_sdk_app_widget_semantics_count(void *app);
int native_sdk_app_widget_semantics_at(void *app, uintptr_t index, native_sdk_widget_semantics_t *out);
int native_sdk_app_widget_semantics_by_id(void *app, uint64_t id, native_sdk_widget_semantics_t *out);

#ifdef __cplusplus
}
#endif
