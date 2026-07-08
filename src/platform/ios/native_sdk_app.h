// C declarations for the subset of the `native_sdk_app_*` embed ABI the
// toolkit-owned iOS host (uikit_host.m) drives: lifecycle, viewport, frame
// pumping, RGBA pixel readback, touch/scroll/text/IME, focus state,
// accessibility semantics, assets, and automation. The full ABI is
// declared in examples/ios/NativeSdkIOSExample/native_sdk.h; struct
// layouts mirror src/embed/types.zig.
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

// Audio event kinds accepted by native_sdk_app_audio_event (ordinals match
// the runtime's AudioEventKind and the macOS host's constants).
enum {
  NATIVE_SDK_AUDIO_EVENT_LOADED = 0,
  NATIVE_SDK_AUDIO_EVENT_POSITION = 1,
  NATIVE_SDK_AUDIO_EVENT_COMPLETED = 2,
  NATIVE_SDK_AUDIO_EVENT_FAILED = 3,
};

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

void *native_sdk_app_create(void);
void native_sdk_app_destroy(void *app);
void native_sdk_app_start(void *app);
void native_sdk_app_activate(void *app);
void native_sdk_app_deactivate(void *app);
void native_sdk_app_stop(void *app);
void native_sdk_app_viewport(void *app, float width, float height, float scale, void *surface, float safe_top, float safe_right, float safe_bottom, float safe_left, float keyboard_top, float keyboard_right, float keyboard_bottom, float keyboard_left);
int native_sdk_app_gpu_frame_state(void *app, native_sdk_gpu_frame_state_t *out);
void native_sdk_app_frame(void *app);
const char *native_sdk_app_last_error_name(void *app);
int native_sdk_app_render_pixel_size(void *app, float scale, native_sdk_canvas_pixels_t *out);
int native_sdk_app_render_pixels(void *app, float scale, uint8_t *pixels, uintptr_t pixels_len, native_sdk_canvas_pixels_t *out);
// Incremental sibling of native_sdk_app_render_pixels for a host that
// keeps `pixels` RETAINED across calls (one buffer, one consumer): the
// fast path copies only the pixels changed since the previous call —
// captured off the runtime's own dirty-scissored raster, no second
// render — and reports that region; the first call (and any size or
// scale change) fills the whole buffer with full damage.
int native_sdk_app_render_pixels_damage(void *app, float scale, uint8_t *pixels, uintptr_t pixels_len, native_sdk_canvas_pixels_damage_t *out);
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
// Platform audio service: the host registers a real player behind these
// callbacks (layout mirrors src/embed/types.zig MobileAudioService) and the
// runtime's fx.playAudio family drives it; everything asynchronous reports
// back through native_sdk_app_audio_event. Result conventions match the
// macOS host: load returns 0 loaded / 1 missing / other decode failure;
// load_url returns 0 stream started / 1 verified cache hit / other invalid
// URL; play and seek return nonzero when they applied. Registration is
// all-or-nothing for the playback tier (every entry except load_url);
// load_url on top enables streaming. Register before native_sdk_app_start;
// without a registration the runtime declines audio honestly.
typedef struct native_sdk_audio_service {
  int (*load)(void *context, const char *path, uintptr_t path_len);
  int (*load_url)(void *context, const char *url, uintptr_t url_len, const char *cache_path, uintptr_t cache_path_len, uint64_t expected_bytes);
  int (*play)(void *context);
  int (*pause)(void *context);
  int (*stop)(void *context);
  int (*seek)(void *context, uint64_t position_ms);
  int (*set_volume)(void *context, double volume);
} native_sdk_audio_service_t;
int native_sdk_app_set_audio_service(void *app, const native_sdk_audio_service_t *service, void *context);
// One audio player report (kind ordinals above; position/duration in ms).
// Call between runtime entry points on the loop thread, never from inside
// an audio service callback.
void native_sdk_app_audio_event(void *app, int kind, uint64_t position_ms, uint64_t duration_ms, int playing, int buffering);
// Platform image-decode service: the host registers the platform codec
// behind this callback (layout mirrors src/embed/types.zig
// MobileImageService) and the runtime's fx.registerImageBytes decodes
// through it synchronously. The decode contract matches the macOS host's
// native_sdk_appkit_decode_image exactly: write tightly packed, row-major,
// straight-alpha RGBA8 into `pixels`, report the dimensions, and return 1
// decoded / -1 pixels buffer too small / anything else undecodable.
// Register before native_sdk_app_start; without a registration the runtime
// declines image decoding honestly and image/avatar widgets keep their
// fallback.
typedef struct native_sdk_image_service {
  int (*decode)(void *context, const uint8_t *bytes, uintptr_t bytes_len, uint8_t *pixels, uintptr_t pixels_len, uintptr_t *out_width, uintptr_t *out_height);
} native_sdk_image_service_t;
int native_sdk_app_set_image_service(void *app, const native_sdk_image_service_t *service, void *context);
int native_sdk_app_set_automation_dir(void *app, const char *path, uintptr_t len);
void native_sdk_app_set_asset_root(void *app, const char *path, uintptr_t len);
uintptr_t native_sdk_app_widget_semantics_count(void *app);
int native_sdk_app_widget_semantics_at(void *app, uintptr_t index, native_sdk_widget_semantics_t *out);
int native_sdk_app_widget_semantics_by_id(void *app, uint64_t id, native_sdk_widget_semantics_t *out);
// Declared platform chrome (the app's shell-metadata tab set + optional
// primary action): the host queries the declaration once at startup,
// builds REAL native controls, polls the model-selected tab index each
// frame (-1 = none), and dispatches taps back through
// native_sdk_app_command with the declared ids. The icon rasterizer
// renders a declared icon-vocabulary glyph as premultiplied white on
// transparent RGBA8 (size_px * size_px * 4 bytes) — a template image
// the system control tints.
uintptr_t native_sdk_app_chrome_tab_count(void *app);
int native_sdk_app_chrome_tab_at(void *app, uintptr_t index, native_sdk_chrome_item_t *out);
int native_sdk_app_chrome_primary_action(void *app, native_sdk_chrome_item_t *out);
intptr_t native_sdk_app_chrome_selected_tab(void *app);
// Model-driven navigation depth for platform push/pop transitions (the
// app's navigation_depth_fn derivation: 0 = the root page, 1 = one push
// in), or -1 when the app declares no navigation projection. The host
// polls it each tick: depth grew = present a push, shrank = present a
// pop, and a poll that also moved the selected tab is a lateral tab
// switch (reconcile with no transition). Presentation only — the model
// owns navigation state.
intptr_t native_sdk_app_chrome_navigation_depth(void *app);
// The declared back command a completed platform back gesture dispatches
// through native_sdk_app_command: 1 with out->id filled when the app
// declares one (static app data), 0 when it does not — never arm the
// interactive back gesture without it. A cancelled gesture dispatches
// nothing.
int native_sdk_app_chrome_navigation_back_command(void *app, native_sdk_chrome_item_t *out);
int native_sdk_app_chrome_icon_pixels(void *app, const char *name, uintptr_t name_len, uintptr_t size_px, uint8_t *pixels, uintptr_t pixels_len);
// Tab taps travel the same command path as native header buttons.
void native_sdk_app_command(void *app, const char *name, uintptr_t len);
// Host chrome reports on the window-chrome channel: the reported form
// factor (host truth apps prefer over width derivation) and whether the
// declared tabs are currently projected as native controls.
int native_sdk_app_set_form_factor(void *app, int form_factor);
int native_sdk_app_set_chrome_tabs_projected(void *app, int projected);

#ifdef __cplusplus
}
#endif
