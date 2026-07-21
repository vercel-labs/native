// Minimal Android shim for a native-sdk mobile canvas static library —
// the Android counterpart of examples/mobile-canvas/ios/main.m.
//
// Shape: a NativeActivity with no Java/Kotlin at all (`android:hasCode`
// is false; the system instantiates android.app.NativeActivity and loads
// this shared object via the android.app.lib_name meta-data). Everything
// runs single-threaded on the activity's main thread: input arrives
// through AInputQueue attached to the main looper, frames are pumped by
// AChoreographer — the Android equivalent of the iOS shim's CADisplayLink.
//
// Presentation (M2 role): the embed host renders the retained scene
// through the CPU reference renderer (`native_sdk_app_render_pixels`,
// RGBA8) and the shim copies those bytes into the ANativeWindow buffer
// (`ANativeWindow_lock` / `_unlockAndPost`). The window buffer is
// requested as WINDOW_FORMAT_RGBA_8888, which matches the renderer's byte
// order exactly — unlike the CAMetalLayer path there is no BGRA swizzle,
// only a row copy honoring the buffer's stride. The canvas revision from
// `native_sdk_app_gpu_frame_state` gates re-renders, so unchanged frames
// cost one ABI call and no copy.
//
// Input (M3 role, touch only): AMotionEvent sequences forward through the
// same touch-slop state machine the iOS shim uses (see main.m): an
// under-slop touch is a tap (pointer_down + pointer_up), an over-slop move
// that started over an overflowing scrollable widget (decided from the
// semantics export) pans it through the scroll reconciliation
// (`native_sdk_app_scroll` wheel deltas, natural direction), and an
// over-slop move elsewhere becomes pointer_down + pointer_drag so sliders
// and text selection keep desktop semantics. Coordinates are converted
// from device pixels to view points (the space the viewport export
// establishes) by dividing by the density scale. The soft keyboard / IME
// path is NOT wired here — Android IME realistically needs Java-side glue
// (InputConnection), which this no-Java shim deliberately avoids; see the
// mobile plans doc.
//
// Text metrics: none registered — layout uses the deterministic estimator
// (the Android platform measure provider is future work; the ABI seam,
// `native_sdk_app_set_text_measure`, is already exported).
//
// Automation: when the `debug.native_sdk.automation` system property is
// set (adb shell setprop debug.native_sdk.automation 1), the shim points
// the runtime's automation server at <internalDataPath>/native-sdk-
// automation, the same snapshot.txt protocol the desktop runners and the
// iOS shim use. The APK is debuggable, so `adb shell run-as <package>`
// can read the snapshots.

#include <android/asset_manager.h>
#include <android/choreographer.h>
#include <android/configuration.h>
#include <android/input.h>
#include <android/keycodes.h>
#include <android/log.h>
#include <android/looper.h>
#include <android/native_activity.h>
#include <android/native_window.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/system_properties.h>

// Shared with the iOS shim (examples/mobile-canvas/ios/native_sdk_app.h);
// the run script adds that directory to the include path so both shims
// compile against one declaration of the C ABI instead of drifting copies.
#include "native_sdk_app.h"

#define LOG_TAG "native-sdk"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

enum TouchMode {
    TOUCH_MODE_IDLE = 0,
    // Touch down seen, under slop: undecided between tap / drag / scroll.
    TOUCH_MODE_PENDING,
    // Over slop on a scrollable widget: forwarding wheel scroll deltas.
    TOUCH_MODE_SCROLLING,
    // Over slop elsewhere: forwarded pointer_down, forwarding pointer_drag.
    TOUCH_MODE_DRAGGING,
};

// 8 points, matching both the iOS shim and Android's ViewConfiguration
// touch slop (8dp).
static const float TOUCH_SLOP_POINTS = 8.0f;

typedef struct Shim {
    ANativeActivity *activity;
    void *native_app;
    ANativeWindow *window;
    AInputQueue *input_queue;
    AConfiguration *config;
    float scale;
    bool has_content_rect;
    ARect content_rect;

    // Presentation state (revision-gated like the iOS displayLinkTick).
    uint8_t *pixels;
    size_t pixels_capacity;
    uint64_t last_canvas_revision;
    bool has_presented_revision;
    bool needs_present;

    // Touch-slop state machine (view points).
    enum TouchMode touch_mode;
    int32_t touch_pointer_id;
    float touch_start_x, touch_start_y;
    float touch_last_x, touch_last_y;
    uint64_t touch_sequence;
} Shim;

// The choreographer callback outlives any single activity state change;
// all callbacks run on the main thread, so a single global published in
// onCreate and cleared in onDestroy is race-free.
static Shim *g_shim = NULL;

static void log_native_error(Shim *shim, const char *stage) {
    if (!shim->native_app) return;
    const char *name = native_sdk_app_last_error_name(shim->native_app);
    if (name && name[0] != '\0') {
        LOGW("%s error %s", stage, name);
    }
}

// ------------------------------------------------------------------ density

static void update_scale(Shim *shim) {
    if (!shim->config) {
        shim->scale = 1.0f;
        return;
    }
    AConfiguration_fromAssetManager(shim->config, shim->activity->assetManager);
    const int32_t density = AConfiguration_getDensity(shim->config);
    if (density <= 0 || density >= ACONFIGURATION_DENSITY_ANY) {
        shim->scale = 1.0f;
    } else {
        shim->scale = (float)density / 160.0f;
    }
}

// ----------------------------------------------------------------- viewport

// Report the window's size in points + density scale + safe-area insets to
// the embed host. Safe areas are derived from onContentRectChanged (the
// area not covered by system bars); keyboard insets stay zero — the soft
// keyboard is not wired in this shim.
static void push_viewport(Shim *shim) {
    if (!shim->native_app || !shim->window) return;
    const int32_t px_width = ANativeWindow_getWidth(shim->window);
    const int32_t px_height = ANativeWindow_getHeight(shim->window);
    if (px_width <= 0 || px_height <= 0) return;
    const float scale = shim->scale > 0 ? shim->scale : 1.0f;
    float safe_top = 0, safe_right = 0, safe_bottom = 0, safe_left = 0;
    if (shim->has_content_rect) {
        const ARect rect = shim->content_rect;
        if (rect.left > 0) safe_left = (float)rect.left / scale;
        if (rect.top > 0) safe_top = (float)rect.top / scale;
        if (rect.right > 0 && rect.right < px_width) safe_right = (float)(px_width - rect.right) / scale;
        if (rect.bottom > 0 && rect.bottom < px_height) safe_bottom = (float)(px_height - rect.bottom) / scale;
    }
    native_sdk_viewport_t viewport = {
        .width = (float)px_width / scale,
        .height = (float)px_height / scale,
        .scale = scale,
        .surface = shim->window,
        .safe_top = safe_top,
        .safe_right = safe_right,
        .safe_bottom = safe_bottom,
        .safe_left = safe_left,
    };
    native_sdk_app_viewport(shim->native_app, &viewport);
    log_native_error(shim, "viewport");
    shim->needs_present = true;
}

// -------------------------------------------------------------- present

static bool ensure_pixel_capacity(Shim *shim, size_t byte_len) {
    if (shim->pixels_capacity >= byte_len && shim->pixels) return true;
    free(shim->pixels);
    shim->pixels = malloc(byte_len);
    shim->pixels_capacity = shim->pixels ? byte_len : 0;
    return shim->pixels_capacity != 0;
}

// Mirror of the iOS renderAndPresent, with ANativeWindow_lock in place of
// the Metal staging texture + blit: render RGBA8 at the density scale,
// size the window buffers to the rendered pixel size (the compositor
// scales if they ever diverge), then row-copy into the locked buffer
// honoring its stride.
static bool render_and_present(Shim *shim) {
    if (!shim->native_app || !shim->window) return false;
    const float scale = shim->scale > 0 ? shim->scale : 1.0f;

    native_sdk_canvas_pixels_t info = {0};
    if (native_sdk_app_render_pixel_size(shim->native_app, scale, &info) != 1) return false;
    if (info.width == 0 || info.height == 0 || info.byte_len != info.width * info.height * 4) return false;
    if (!ensure_pixel_capacity(shim, info.byte_len)) return false;

    native_sdk_canvas_pixels_t rendered = {0};
    if (native_sdk_app_render_pixels(shim->native_app, scale, shim->pixels, info.byte_len, &rendered) != 1) {
        log_native_error(shim, "render_pixels");
        return false;
    }
    const size_t width = rendered.width;
    const size_t height = rendered.height;
    if (width == 0 || height == 0 || rendered.byte_len != width * height * 4) return false;

    if (ANativeWindow_setBuffersGeometry(shim->window, (int32_t)width, (int32_t)height,
                                         WINDOW_FORMAT_RGBA_8888) != 0) {
        return false;
    }
    ANativeWindow_Buffer buffer;
    if (ANativeWindow_lock(shim->window, &buffer, NULL) != 0) return false;

    const size_t copy_rows = height < (size_t)buffer.height ? height : (size_t)buffer.height;
    const size_t copy_pixels = width < (size_t)buffer.width ? width : (size_t)buffer.width;
    uint8_t *dst = buffer.bits;
    const uint8_t *src = shim->pixels;
    for (size_t row = 0; row < copy_rows; row++) {
        memcpy(dst + row * (size_t)buffer.stride * 4, src + row * width * 4, copy_pixels * 4);
    }
    ANativeWindow_unlockAndPost(shim->window);
    return true;
}

// ------------------------------------------------------------ frame pump

static void schedule_frame(void);

// Host-pumped frame, the AChoreographer twin of the iOS displayLinkTick:
// synthesize the gpu_surface_frame event, then re-render + post only when
// the retained canvas revision moved (or a viewport change forced it).
static void frame_callback(int64_t frame_time_nanos, void *data) {
    (void)frame_time_nanos;
    (void)data;
    Shim *shim = g_shim;
    if (!shim) return;
    schedule_frame();
    if (!shim->native_app) return;

    native_sdk_app_frame(shim->native_app);

    native_sdk_gpu_frame_state_t state = {0};
    const bool have_state = native_sdk_app_gpu_frame_state(shim->native_app, &state) == 1;
    if (!shim->needs_present && have_state && shim->has_presented_revision &&
        state.canvas_revision == shim->last_canvas_revision) {
        return;
    }
    if (render_and_present(shim)) {
        if (have_state) {
            shim->last_canvas_revision = state.canvas_revision;
            shim->has_presented_revision = true;
        }
        shim->needs_present = false;
    }
}

static void schedule_frame(void) {
    AChoreographer *choreographer = AChoreographer_getInstance();
    if (!choreographer) return;
    AChoreographer_postFrameCallback64(choreographer, frame_callback, NULL);
}

// -------------------------------------------------------------------- touch

static void forward_touch_phase(Shim *shim, int phase, float x, float y, float pressure) {
    if (!shim->native_app) return;
    native_sdk_app_touch(shim->native_app, shim->touch_sequence, phase, x, y, pressure);
}

// True when an overflowing scrollable widget's bounds contain the point —
// the same pan-to-scroll decision the iOS shim takes from the semantics
// export (see main.m scrollableWidgetAtPoint:).
static bool scrollable_widget_at_point(Shim *shim, float x, float y) {
    if (!shim->native_app) return false;
    const uintptr_t count = native_sdk_app_widget_semantics_count(shim->native_app);
    for (uintptr_t index = 0; index < count; index++) {
        native_sdk_widget_semantics_t node = {0};
        if (native_sdk_app_widget_semantics_at(shim->native_app, index, &node) != 1) continue;
        if (!node.has_scroll) continue;
        if (node.scroll_content_extent <= node.scroll_viewport_extent) continue;
        if (x < node.x || x > node.x + node.width) continue;
        if (y < node.y || y > node.y + node.height) continue;
        return true;
    }
    return false;
}

static void reset_touch_tracking(Shim *shim) {
    shim->touch_mode = TOUCH_MODE_IDLE;
    shim->touch_pointer_id = -1;
}

static int32_t handle_motion_event(Shim *shim, const AInputEvent *event) {
    const int32_t action = AMotionEvent_getAction(event) & AMOTION_EVENT_ACTION_MASK;
    const float scale = shim->scale > 0 ? shim->scale : 1.0f;

    // Track the primary pointer only, like the iOS shim's single-touch
    // canvas view; secondary pointers are ignored.
    if (action == AMOTION_EVENT_ACTION_DOWN) {
        if (shim->touch_mode != TOUCH_MODE_IDLE) return 1;
        shim->touch_pointer_id = AMotionEvent_getPointerId(event, 0);
        shim->touch_sequence += 1;
        shim->touch_mode = TOUCH_MODE_PENDING;
        shim->touch_start_x = AMotionEvent_getX(event, 0) / scale;
        shim->touch_start_y = AMotionEvent_getY(event, 0) / scale;
        shim->touch_last_x = shim->touch_start_x;
        shim->touch_last_y = shim->touch_start_y;
        return 1;
    }
    if (shim->touch_mode == TOUCH_MODE_IDLE || shim->touch_pointer_id < 0) return 0;

    // Locate the tracked pointer in this event; it may have been lifted.
    int32_t pointer_index = -1;
    const size_t pointer_count = AMotionEvent_getPointerCount(event);
    for (size_t index = 0; index < pointer_count; index++) {
        if (AMotionEvent_getPointerId(event, index) == shim->touch_pointer_id) {
            pointer_index = (int32_t)index;
            break;
        }
    }
    if (pointer_index < 0) return 1;
    const float x = AMotionEvent_getX(event, pointer_index) / scale;
    const float y = AMotionEvent_getY(event, pointer_index) / scale;

    switch (action) {
    case AMOTION_EVENT_ACTION_MOVE: {
        if (shim->touch_mode == TOUCH_MODE_PENDING) {
            const float dx = x - shim->touch_start_x;
            const float dy = y - shim->touch_start_y;
            if (dx * dx + dy * dy < TOUCH_SLOP_POINTS * TOUCH_SLOP_POINTS) return 1;
            if (scrollable_widget_at_point(shim, shim->touch_start_x, shim->touch_start_y)) {
                shim->touch_mode = TOUCH_MODE_SCROLLING;
            } else {
                shim->touch_mode = TOUCH_MODE_DRAGGING;
                forward_touch_phase(shim, NATIVE_SDK_TOUCH_PHASE_DOWN,
                                    shim->touch_start_x, shim->touch_start_y, 1);
            }
        }
        if (shim->touch_mode == TOUCH_MODE_SCROLLING) {
            // Natural scrolling: finger up moves content up = offset grows,
            // so the wheel delta is the negated finger delta.
            const float delta_x = shim->touch_last_x - x;
            const float delta_y = shim->touch_last_y - y;
            if (shim->native_app && (delta_x != 0 || delta_y != 0)) {
                native_sdk_app_scroll(shim->native_app, shim->touch_sequence, x, y, delta_x, delta_y);
            }
        } else if (shim->touch_mode == TOUCH_MODE_DRAGGING) {
            forward_touch_phase(shim, NATIVE_SDK_TOUCH_PHASE_DRAG, x, y, 1);
        }
        shim->touch_last_x = x;
        shim->touch_last_y = y;
        return 1;
    }
    case AMOTION_EVENT_ACTION_UP: {
        switch (shim->touch_mode) {
        case TOUCH_MODE_PENDING:
            // Under-slop touch: a tap at the start point.
            forward_touch_phase(shim, NATIVE_SDK_TOUCH_PHASE_DOWN,
                                shim->touch_start_x, shim->touch_start_y, 1);
            forward_touch_phase(shim, NATIVE_SDK_TOUCH_PHASE_UP,
                                shim->touch_start_x, shim->touch_start_y, 0);
            break;
        case TOUCH_MODE_DRAGGING:
            forward_touch_phase(shim, NATIVE_SDK_TOUCH_PHASE_UP, x, y, 0);
            break;
        default:
            break;
        }
        reset_touch_tracking(shim);
        return 1;
    }
    case AMOTION_EVENT_ACTION_CANCEL: {
        if (shim->touch_mode == TOUCH_MODE_DRAGGING) {
            forward_touch_phase(shim, NATIVE_SDK_TOUCH_PHASE_CANCEL,
                                shim->touch_last_x, shim->touch_last_y, 0);
        }
        reset_touch_tracking(shim);
        return 1;
    }
    default:
        return 0;
    }
}

static int32_t handle_input_event(Shim *shim, const AInputEvent *event) {
    switch (AInputEvent_getType(event)) {
    case AINPUT_EVENT_TYPE_MOTION:
        return handle_motion_event(shim, event);
    case AINPUT_EVENT_TYPE_KEY:
        // Let the system own BACK (finish the activity); everything else is
        // unhandled — hardware keyboard / IME routing is not wired in this
        // shim.
        if (AKeyEvent_getKeyCode(event) == AKEYCODE_BACK &&
            AKeyEvent_getAction(event) == AKEY_EVENT_ACTION_UP) {
            ANativeActivity_finish(shim->activity);
            return 1;
        }
        return 0;
    default:
        return 0;
    }
}

// Drains the input queue on the main looper. preDispatchEvent hands events
// to the IME first, matching the android_native_app_glue contract.
static int input_queue_callback(int fd, int events, void *data) {
    (void)fd;
    (void)events;
    Shim *shim = data;
    if (!shim || !shim->input_queue) return 1;
    AInputEvent *event = NULL;
    while (AInputQueue_getEvent(shim->input_queue, &event) >= 0) {
        if (AInputQueue_preDispatchEvent(shim->input_queue, event)) continue;
        const int32_t handled = handle_input_event(shim, event);
        AInputQueue_finishEvent(shim->input_queue, event, handled);
    }
    return 1;
}

// -------------------------------------------------------------- automation

// Verification harness: `adb shell setprop debug.native_sdk.automation 1`
// before launch makes the embedded runtime publish snapshot.txt into the
// app's internal files dir — same protocol as the desktop
// -Dautomation=true runners and the iOS shim's NATIVE_SDK_AUTOMATION env.
static void configure_automation(Shim *shim) {
    char value[PROP_VALUE_MAX] = {0};
    const int len = __system_property_get("debug.native_sdk.automation", value);
    if (len <= 0 || value[0] == '\0' || strcmp(value, "0") == 0) return;
    if (!shim->activity->internalDataPath) return;
    char path[1024];
    const int written = snprintf(path, sizeof(path), "%s/native-sdk-automation",
                                 shim->activity->internalDataPath);
    if (written <= 0 || (size_t)written >= sizeof(path)) return;
    native_sdk_app_set_automation_dir(shim->native_app, path, (uintptr_t)written);
    log_native_error(shim, "automation");
    LOGI("automation dir %s", path);
}

// ------------------------------------------------------ activity callbacks

static void on_native_window_created(ANativeActivity *activity, ANativeWindow *window) {
    Shim *shim = activity->instance;
    shim->window = window;
    ANativeWindow_setBuffersGeometry(window, 0, 0, WINDOW_FORMAT_RGBA_8888);
    update_scale(shim);
    push_viewport(shim);
}

static void on_native_window_resized(ANativeActivity *activity, ANativeWindow *window) {
    Shim *shim = activity->instance;
    if (shim->window != window) return;
    push_viewport(shim);
}

static void on_native_window_redraw_needed(ANativeActivity *activity, ANativeWindow *window) {
    Shim *shim = activity->instance;
    if (shim->window != window) return;
    // The system expects the frame to be posted before this returns.
    shim->needs_present = true;
    if (shim->native_app) native_sdk_app_frame(shim->native_app);
    if (render_and_present(shim)) shim->needs_present = false;
}

static void on_native_window_destroyed(ANativeActivity *activity, ANativeWindow *window) {
    Shim *shim = activity->instance;
    if (shim->window == window) shim->window = NULL;
}

static void on_input_queue_created(ANativeActivity *activity, AInputQueue *queue) {
    Shim *shim = activity->instance;
    shim->input_queue = queue;
    ALooper *looper = ALooper_forThread();
    if (looper) {
        AInputQueue_attachLooper(queue, looper, ALOOPER_POLL_CALLBACK, input_queue_callback, shim);
    }
}

static void on_input_queue_destroyed(ANativeActivity *activity, AInputQueue *queue) {
    Shim *shim = activity->instance;
    if (shim->input_queue == queue) {
        AInputQueue_detachLooper(queue);
        shim->input_queue = NULL;
    }
}

static void on_content_rect_changed(ANativeActivity *activity, const ARect *rect) {
    Shim *shim = activity->instance;
    if (!rect) return;
    shim->content_rect = *rect;
    shim->has_content_rect = true;
    push_viewport(shim);
}

static void on_configuration_changed(ANativeActivity *activity) {
    Shim *shim = activity->instance;
    update_scale(shim);
    push_viewport(shim);
}

static void on_resume(ANativeActivity *activity) {
    Shim *shim = activity->instance;
    if (shim->native_app) native_sdk_app_activate(shim->native_app);
}

static void on_pause(ANativeActivity *activity) {
    Shim *shim = activity->instance;
    if (shim->native_app) native_sdk_app_deactivate(shim->native_app);
}

static void on_destroy(ANativeActivity *activity) {
    Shim *shim = activity->instance;
    g_shim = NULL;
    if (shim->input_queue) {
        AInputQueue_detachLooper(shim->input_queue);
        shim->input_queue = NULL;
    }
    if (shim->native_app) {
        native_sdk_app_stop(shim->native_app);
        native_sdk_app_destroy(shim->native_app);
        shim->native_app = NULL;
    }
    if (shim->config) {
        AConfiguration_delete(shim->config);
        shim->config = NULL;
    }
    free(shim->pixels);
    free(shim);
    activity->instance = NULL;
}

JNIEXPORT void ANativeActivity_onCreate(ANativeActivity *activity, void *saved_state, size_t saved_state_size) {
    (void)saved_state;
    (void)saved_state_size;

    Shim *shim = calloc(1, sizeof(Shim));
    if (!shim) {
        LOGW("shim allocation failed");
        return;
    }
    shim->activity = activity;
    shim->scale = 1.0f;
    shim->touch_pointer_id = -1;
    activity->instance = shim;

    activity->callbacks->onNativeWindowCreated = on_native_window_created;
    activity->callbacks->onNativeWindowResized = on_native_window_resized;
    activity->callbacks->onNativeWindowRedrawNeeded = on_native_window_redraw_needed;
    activity->callbacks->onNativeWindowDestroyed = on_native_window_destroyed;
    activity->callbacks->onInputQueueCreated = on_input_queue_created;
    activity->callbacks->onInputQueueDestroyed = on_input_queue_destroyed;
    activity->callbacks->onContentRectChanged = on_content_rect_changed;
    activity->callbacks->onConfigurationChanged = on_configuration_changed;
    activity->callbacks->onResume = on_resume;
    activity->callbacks->onPause = on_pause;
    activity->callbacks->onDestroy = on_destroy;

    shim->config = AConfiguration_new();
    update_scale(shim);

    shim->native_app = native_sdk_app_create();
    if (!shim->native_app) {
        LOGW("native_sdk_app_create failed");
        return;
    }

    configure_automation(shim);

    native_sdk_app_start(shim->native_app);
    native_sdk_app_activate(shim->native_app);
    log_native_error(shim, "start");

    g_shim = shim;
    schedule_frame();
    LOGI("native-sdk canvas shim started (scale %.2f)", (double)shim->scale);
}
