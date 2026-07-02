// C declarations for the subset of the `zero_native_app_*` embed ABI the
// canvas shim drives: create/start/viewport/frame plus the RGBA render
// exports (M2) and the touch/scroll/text/IME, focus-state, semantics, and
// automation exports (M3). The full ABI is declared in
// examples/ios/ZeroNativeIOSExample/zero_native.h; struct layouts mirror
// src/embed/types.zig.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
  ZERO_NATIVE_GPU_SURFACE_STATUS_UNAVAILABLE = 0,
  ZERO_NATIVE_GPU_SURFACE_STATUS_INITIALIZING = 1,
  ZERO_NATIVE_GPU_SURFACE_STATUS_READY = 2,
  ZERO_NATIVE_GPU_SURFACE_STATUS_LOST = 3,
};

// UITouch phases accepted by zero_native_app_touch.
enum {
  ZERO_NATIVE_TOUCH_PHASE_DOWN = 0,
  ZERO_NATIVE_TOUCH_PHASE_UP = 1,
  ZERO_NATIVE_TOUCH_PHASE_DRAG = 2,
  ZERO_NATIVE_TOUCH_PHASE_CANCEL = 3,
};

// IME event kinds accepted by zero_native_app_ime.
enum {
  ZERO_NATIVE_IME_SET_COMPOSITION = 0,
  ZERO_NATIVE_IME_COMMIT_COMPOSITION = 1,
  ZERO_NATIVE_IME_CANCEL_COMPOSITION = 2,
};

// Key phases accepted by zero_native_app_key.
enum {
  ZERO_NATIVE_KEY_PHASE_DOWN = 0,
  ZERO_NATIVE_KEY_PHASE_UP = 1,
};

typedef struct zero_native_canvas_pixels {
  uintptr_t width;
  uintptr_t height;
  uintptr_t byte_len;
} zero_native_canvas_pixels_t;

typedef struct zero_native_text_input_state {
  int active;
  uint64_t widget_id;
  float x;
  float y;
  float width;
  float height;
} zero_native_text_input_state_t;

typedef struct zero_native_widget_semantics {
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
} zero_native_widget_semantics_t;

typedef struct zero_native_gpu_frame_state {
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
} zero_native_gpu_frame_state_t;

void *zero_native_app_create(void);
void zero_native_app_destroy(void *app);
void zero_native_app_start(void *app);
void zero_native_app_activate(void *app);
void zero_native_app_deactivate(void *app);
void zero_native_app_stop(void *app);
void zero_native_app_viewport(void *app, float width, float height, float scale, void *surface, float safe_top, float safe_right, float safe_bottom, float safe_left, float keyboard_top, float keyboard_right, float keyboard_bottom, float keyboard_left);
int zero_native_app_gpu_frame_state(void *app, zero_native_gpu_frame_state_t *out);
void zero_native_app_frame(void *app);
const char *zero_native_app_last_error_name(void *app);
int zero_native_app_render_pixel_size(void *app, float scale, zero_native_canvas_pixels_t *out);
int zero_native_app_render_pixels(void *app, float scale, uint8_t *pixels, uintptr_t pixels_len, zero_native_canvas_pixels_t *out);
void zero_native_app_touch(void *app, uint64_t id, int phase, float x, float y, float pressure);
void zero_native_app_scroll(void *app, uint64_t id, float x, float y, float delta_x, float delta_y);
void zero_native_app_key(void *app, int phase, const char *key, uintptr_t key_len, const char *text, uintptr_t text_len, uint32_t modifiers_mask);
void zero_native_app_text(void *app, const char *text, uintptr_t len);
void zero_native_app_ime(void *app, int kind, const char *text, uintptr_t len, intptr_t cursor);
int zero_native_app_text_input_state(void *app, zero_native_text_input_state_t *out);
int zero_native_app_set_automation_dir(void *app, const char *path, uintptr_t len);
uintptr_t zero_native_app_widget_semantics_count(void *app);
int zero_native_app_widget_semantics_at(void *app, uintptr_t index, zero_native_widget_semantics_t *out);
int zero_native_app_widget_semantics_by_id(void *app, uint64_t id, zero_native_widget_semantics_t *out);

#ifdef __cplusplus
}
#endif
