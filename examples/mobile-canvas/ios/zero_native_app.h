// C declarations for the subset of the `zero_native_app_*` embed ABI the
// canvas presentation shim drives (create/start/viewport/frame plus the
// RGBA render exports added for M2). The full ABI is declared in
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

typedef struct zero_native_canvas_pixels {
  uintptr_t width;
  uintptr_t height;
  uintptr_t byte_len;
} zero_native_canvas_pixels_t;

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

#ifdef __cplusplus
}
#endif
