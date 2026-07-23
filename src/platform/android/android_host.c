// The native half of the toolkit-owned Android host: the JNI bridge
// between NativeSdkActivity.java and the embed C ABI
// (src/embed/c_api.zig), plus ANativeWindow presentation. `native dev
// --target android` and `native package --target android` compile this
// file against the app's embed static library with the NDK toolchain —
// an app project carries zero host code, and everything app-specific
// (application id, names, icons) arrives through the generated manifest
// and resources. The host tier is built ON the embed ABI, not beside it:
// a hand-written host (see examples/android) remains a first-class
// standalone use.
//
// Presentation mirrors the iOS host's raster path (uikit_host.m): the
// embed host renders the retained scene through the CPU reference
// renderer into this bridge's RETAINED staging buffer
// (`native_sdk_app_render_pixels_damage`, RGBA8) — each changed frame
// rasters only its dirty region embed-side and reports the damaged rect
// — and this bridge locks the SurfaceView's ANativeWindow with that rect
// as the dirty region, copying only the rows the lock's (possibly
// buffer-age-expanded) out-rect requires from the always-current
// staging. The window's buffer format is pinned to RGBA_8888, whose byte
// order matches the renderer's output exactly, so unlike the Metal path
// no swizzle is needed — only row copies that honor the window buffer's
// stride. The Java side pumps `native_sdk_app_frame` from a
// Choreographer callback and gates re-renders on the canvas revision
// from `native_sdk_app_gpu_frame_state`, so unchanged frames cost one
// ABI call and no copy; a revision bump with no visual change locks and
// posts nothing.
//
// The ANativeWindow is acquired once per surface (surfaceChanged) and
// released on surfaceDestroyed; the held pointer doubles as the embed
// viewport's surface token, so rotation — which recreates the surface —
// flows through the same acquire/release seam.
//
// Text metrics: nativeSetTextMeasure registers an embed measure callback
// that upcalls into the activity's Paint-backed measureText (the Android
// mirror of the iOS host's CoreText callback). The upcall resolves the
// JNIEnv through the stored JavaVM: measurement runs re-entrantly inside
// embed calls, which the host only issues from attached Java threads.

#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>

#include "native_sdk_app.h"

#define NATIVE_SDK_LOG_TAG "native-sdk"
#define NATIVE_SDK_LOGI(...) __android_log_print(ANDROID_LOG_INFO, NATIVE_SDK_LOG_TAG, __VA_ARGS__)
#define NATIVE_SDK_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, NATIVE_SDK_LOG_TAG, __VA_ARGS__)

// One activity drives one embed app per process (the manifest declares a
// single launcher activity), so the host-side presentation, measure, and
// audio state lives in a single static bundle.
static struct {
    ANativeWindow *window;
    uint8_t *pixels;
    size_t pixels_capacity;
    // Dirty-rect post bookkeeping: whether THIS window has received a
    // post since it was acquired (a fresh window's buffers hold nothing,
    // so the first post must cover the full surface) and at what
    // geometry. Reset on surfaceChanged/surfaceDestroyed.
    int posted_since_acquire;
    uintptr_t posted_width;
    uintptr_t posted_height;
    JavaVM *vm;
    jobject activity; // global ref while text measurement is registered
    jmethodID measure_method;
    // Audio upcall targets, registered by nativeSetAudioService: the
    // activity owns the platform player (android.media on the Java side),
    // and the embed audio service callbacks below call back into it.
    jobject audio_activity; // global ref while the audio service is registered
    jmethodID audio_load_method;
    jmethodID audio_load_url_method;
    jmethodID audio_play_method;
    jmethodID audio_pause_method;
    jmethodID audio_stop_method;
    jmethodID audio_seek_method;
    jmethodID audio_set_volume_method;
    // Image decode upcall target, registered by nativeSetImageService: the
    // activity owns the platform codec (BitmapFactory on the Java side),
    // and the embed image service callback below calls back into it.
    jobject image_activity; // global ref while the image service is registered
    jmethodID image_decode_method;
} host_state = {0};

static void host_log_error(void *app, const char *stage) {
    const char *name = native_sdk_app_last_error_name(app);
    if (name && name[0] != '\0') {
        NATIVE_SDK_LOGE("%s error %s", stage, name);
    }
}

// ------------------------------------------------------------ lifecycle

JNIEXPORT jlong JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeCreate(JNIEnv *env, jobject self) {
    (void)env;
    (void)self;
    return (jlong)native_sdk_app_create();
}

JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeDestroy(JNIEnv *env, jobject self, jlong app) {
    (void)self;
    native_sdk_app_destroy((void *)app);
    if (host_state.window) {
        ANativeWindow_release(host_state.window);
        host_state.window = NULL;
    }
    free(host_state.pixels);
    host_state.pixels = NULL;
    host_state.pixels_capacity = 0;
    if (host_state.activity) {
        (*env)->DeleteGlobalRef(env, host_state.activity);
        host_state.activity = NULL;
        host_state.measure_method = NULL;
    }
    if (host_state.audio_activity) {
        (*env)->DeleteGlobalRef(env, host_state.audio_activity);
        host_state.audio_activity = NULL;
        host_state.audio_load_method = NULL;
        host_state.audio_load_url_method = NULL;
        host_state.audio_play_method = NULL;
        host_state.audio_pause_method = NULL;
        host_state.audio_stop_method = NULL;
        host_state.audio_seek_method = NULL;
        host_state.audio_set_volume_method = NULL;
    }
    if (host_state.image_activity) {
        (*env)->DeleteGlobalRef(env, host_state.image_activity);
        host_state.image_activity = NULL;
        host_state.image_decode_method = NULL;
    }
}

JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeStart(JNIEnv *env, jobject self, jlong app) {
    (void)env;
    (void)self;
    native_sdk_app_start((void *)app);
    host_log_error((void *)app, "start");
}

JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeActivate(JNIEnv *env, jobject self, jlong app) {
    (void)env;
    (void)self;
    native_sdk_app_activate((void *)app);
}

JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeDeactivate(JNIEnv *env, jobject self, jlong app) {
    (void)env;
    (void)self;
    native_sdk_app_deactivate((void *)app);
}

JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeStop(JNIEnv *env, jobject self, jlong app) {
    (void)env;
    (void)self;
    native_sdk_app_stop((void *)app);
}

// ------------------------------------------------------- surface + frame

// Swap the held ANativeWindow for the SurfaceView's current surface —
// called from surfaceChanged, including the recreate that rotation
// triggers. The embedded runtime is NOT recreated: the new window simply
// becomes the viewport's surface token and the next present's target.
JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeSurfaceChanged(JNIEnv *env, jobject self, jlong app, jobject surface) {
    (void)app;
    (void)self;
    ANativeWindow *window = surface ? ANativeWindow_fromSurface(env, surface) : NULL;
    if (host_state.window) ANativeWindow_release(host_state.window);
    host_state.window = window;
    host_state.posted_since_acquire = 0;
}

JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeSurfaceDestroyed(JNIEnv *env, jobject self, jlong app) {
    (void)env;
    (void)self;
    (void)app;
    if (host_state.window) {
        ANativeWindow_release(host_state.window);
        host_state.window = NULL;
    }
    host_state.posted_since_acquire = 0;
}

// Report the viewport in density-independent points (the same coordinate
// space touch input uses; the render scale multiplies pixels, not
// input), with the safe-area and keyboard insets the Java side derived
// from WindowInsets. The held ANativeWindow is the surface token.
JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeViewport(JNIEnv *env, jobject self, jlong app, jfloat width, jfloat height, jfloat scale, jfloat safe_top, jfloat safe_right, jfloat safe_bottom, jfloat safe_left, jfloat keyboard_top, jfloat keyboard_right, jfloat keyboard_bottom, jfloat keyboard_left) {
    (void)env;
    (void)self;
    native_sdk_viewport_t viewport = {
        .width = width,
        .height = height,
        .scale = scale,
        .surface = host_state.window,
        .safe_top = safe_top,
        .safe_right = safe_right,
        .safe_bottom = safe_bottom,
        .safe_left = safe_left,
        .keyboard_top = keyboard_top,
        .keyboard_right = keyboard_right,
        .keyboard_bottom = keyboard_bottom,
        .keyboard_left = keyboard_left,
    };
    native_sdk_app_viewport((void *)app, &viewport);
    host_log_error((void *)app, "viewport");
}

JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeFrame(JNIEnv *env, jobject self, jlong app) {
    (void)env;
    (void)self;
    native_sdk_app_frame((void *)app);
}

// The retained canvas revision, the Java frame loop's re-render gate
// (unchanged revision = present skipped). -1 while no frame state exists.
JNIEXPORT jlong JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeCanvasRevision(JNIEnv *env, jobject self, jlong app) {
    (void)env;
    (void)self;
    native_sdk_gpu_frame_state_t state;
    memset(&state, 0, sizeof(state));
    if (!native_sdk_app_gpu_frame_state((void *)app, &state)) return -1;
    return (jlong)state.canvas_revision;
}

static int host_ensure_pixel_capacity(size_t byte_len) {
    if (host_state.pixels_capacity >= byte_len && host_state.pixels) return 1;
    free(host_state.pixels);
    host_state.pixels = malloc(byte_len);
    host_state.pixels_capacity = host_state.pixels ? byte_len : 0;
    return host_state.pixels_capacity != 0;
}

// Render the retained scene at `scale` into the RETAINED staging buffer
// — the embed side copies only the damaged region and names it — then
// lock the window with that rect as the dirty region and copy the rows
// the lock's out-rect requires. Returns the revision the glass now
// reflects (-1 on failure): the Java gate compares the live revision
// against THIS value, so a present the runtime produces one pump after
// its change still gets delivered instead of stranding off the glass. RGBA8 renderer bytes match
// WINDOW_FORMAT_RGBA_8888 byte order, so the copies are per-row memcpys
// honoring the buffer stride. The lock may EXPAND the dirty rect to
// cover the dequeued buffer's age (the pool rotates buffers holding
// older frames); the staging buffer always holds the complete current
// frame, so every expanded pixel copies from truth.
JNIEXPORT jlong JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativePresent(JNIEnv *env, jobject self, jlong app, jfloat scale) {
    (void)env;
    (void)self;
    ANativeWindow *window = host_state.window;
    if (!window) return -1;

    native_sdk_canvas_pixels_t info;
    memset(&info, 0, sizeof(info));
    if (!native_sdk_app_render_pixel_size((void *)app, scale, &info)) return -1;
    if (info.width == 0 || info.height == 0 || info.byte_len != info.width * info.height * 4) return -1;
    if (!host_ensure_pixel_capacity(info.byte_len)) return -1;

    native_sdk_canvas_pixels_damage_t rendered;
    memset(&rendered, 0, sizeof(rendered));
    if (!native_sdk_app_render_pixels_damage((void *)app, scale, host_state.pixels, info.byte_len, &rendered)) {
        host_log_error((void *)app, "render_pixels_damage");
        return -1;
    }
    if (rendered.width == 0 || rendered.height == 0 || rendered.byte_len != rendered.width * rendered.height * 4) {
        host_state.posted_since_acquire = 0;
        return -1;
    }
    if (rendered.damage_x + rendered.damage_width > rendered.width ||
        rendered.damage_y + rendered.damage_height > rendered.height) {
        host_state.posted_since_acquire = 0;
        return -1;
    }

    // A fresh window (or a geometry change) needs a full first post; a
    // steady-state frame with EMPTY damage needs no post at all — the
    // glass already shows it.
    const int full_needed = !host_state.posted_since_acquire ||
        host_state.posted_width != rendered.width ||
        host_state.posted_height != rendered.height;
    const int has_damage = rendered.damage_width > 0 && rendered.damage_height > 0;
    if (!full_needed && !has_damage) return (jlong)rendered.revision;

    // From here on the staging buffer is ahead of the glass (the damage
    // delivery above already consumed the accumulated region): any
    // failure before the post forces the NEXT present to cover the full
    // surface, so a failed lock can never strand delivered damage.
    host_state.posted_since_acquire = 0;
    if (ANativeWindow_setBuffersGeometry(window, (int32_t)rendered.width, (int32_t)rendered.height, WINDOW_FORMAT_RGBA_8888) != 0) return -1;
    ARect dirty;
    if (full_needed) {
        dirty.left = 0;
        dirty.top = 0;
        dirty.right = (int32_t)rendered.width;
        dirty.bottom = (int32_t)rendered.height;
    } else {
        dirty.left = (int32_t)rendered.damage_x;
        dirty.top = (int32_t)rendered.damage_y;
        dirty.right = (int32_t)(rendered.damage_x + rendered.damage_width);
        dirty.bottom = (int32_t)(rendered.damage_y + rendered.damage_height);
    }
    ANativeWindow_Buffer buffer;
    if (ANativeWindow_lock(window, &buffer, &dirty) != 0) return -1;
    if ((uintptr_t)buffer.width < rendered.width || (uintptr_t)buffer.height < rendered.height) {
        ANativeWindow_unlockAndPost(window);
        return -1;
    }
    // Clamp the (possibly expanded) out-rect to the frame and copy
    // exactly the rows and columns it names from the staging buffer.
    if (dirty.left < 0) dirty.left = 0;
    if (dirty.top < 0) dirty.top = 0;
    if (dirty.right > (int32_t)rendered.width) dirty.right = (int32_t)rendered.width;
    if (dirty.bottom > (int32_t)rendered.height) dirty.bottom = (int32_t)rendered.height;
    if (dirty.right > dirty.left && dirty.bottom > dirty.top) {
        const size_t src_stride = rendered.width * 4;
        const size_t dst_stride = (size_t)buffer.stride * 4;
        const size_t first_byte = (size_t)dirty.left * 4;
        const size_t span = (size_t)(dirty.right - dirty.left) * 4;
        uint8_t *dst = buffer.bits;
        const uint8_t *src = host_state.pixels;
        for (int32_t row = dirty.top; row < dirty.bottom; row++) {
            memcpy(dst + (size_t)row * dst_stride + first_byte, src + (size_t)row * src_stride + first_byte, span);
        }
    }
    ANativeWindow_unlockAndPost(window);
    host_state.posted_since_acquire = 1;
    host_state.posted_width = rendered.width;
    host_state.posted_height = rendered.height;
    return (jlong)rendered.revision;
}

// ------------------------------------------------------------------ input

JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeTouch(JNIEnv *env, jobject self, jlong app, jlong id, jint phase, jfloat x, jfloat y, jfloat pressure) {
    (void)env;
    (void)self;
    native_sdk_app_touch((void *)app, (uint64_t)id, phase, x, y, pressure);
}

JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeScroll(JNIEnv *env, jobject self, jlong app, jlong id, jfloat x, jfloat y, jfloat delta_x, jfloat delta_y) {
    (void)env;
    (void)self;
    native_sdk_app_scroll((void *)app, (uint64_t)id, x, y, delta_x, delta_y);
}

JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeKey(JNIEnv *env, jobject self, jlong app, jint phase, jstring key, jint modifiers) {
    (void)self;
    const char *key_chars = key ? (*env)->GetStringUTFChars(env, key, NULL) : NULL;
    native_sdk_app_key((void *)app, phase, key_chars ? key_chars : "", key_chars ? strlen(key_chars) : 0, "", 0, (uint32_t)modifiers);
    if (key_chars) (*env)->ReleaseStringUTFChars(env, key, key_chars);
}

// Committed text arrives as UTF-8 bytes (byte arrays, not jstring, so
// astral-plane input survives the JNI modified-UTF-8 seam).
JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeText(JNIEnv *env, jobject self, jlong app, jbyteArray text) {
    (void)self;
    if (!text) return;
    jsize len = (*env)->GetArrayLength(env, text);
    if (len <= 0) return;
    jbyte *bytes = (*env)->GetByteArrayElements(env, text, NULL);
    if (!bytes) return;
    native_sdk_app_text((void *)app, (const char *)bytes, (uintptr_t)len);
    (*env)->ReleaseByteArrayElements(env, text, bytes, JNI_ABORT);
}

// IME composition events; `cursor` is a UTF-8 byte offset into `text`
// (or negative for "end"), matching the desktop hosts' set_composition
// contract.
JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeIme(JNIEnv *env, jobject self, jlong app, jint kind, jbyteArray text, jlong cursor) {
    (void)self;
    jsize len = text ? (*env)->GetArrayLength(env, text) : 0;
    jbyte *bytes = (len > 0) ? (*env)->GetByteArrayElements(env, text, NULL) : NULL;
    native_sdk_app_ime((void *)app, kind, bytes ? (const char *)bytes : "", bytes ? (uintptr_t)len : 0, (intptr_t)cursor);
    if (bytes) (*env)->ReleaseByteArrayElements(env, text, bytes, JNI_ABORT);
}

// Focus / IME-intent state after input dispatch: fills [widget_id] and
// [x, y, width, height]; returns whether an editable text widget owns
// focus — the Java side keys InputMethodManager show/hide on it.
JNIEXPORT jboolean JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeTextInputState(JNIEnv *env, jobject self, jlong app, jlongArray widget_id, jfloatArray frame) {
    (void)self;
    if (!widget_id || !frame) return JNI_FALSE;
    if ((*env)->GetArrayLength(env, widget_id) < 1 || (*env)->GetArrayLength(env, frame) < 4) return JNI_FALSE;
    native_sdk_text_input_state_t state;
    memset(&state, 0, sizeof(state));
    if (!native_sdk_app_text_input_state((void *)app, &state)) return JNI_FALSE;
    const jlong id_value[1] = {(jlong)state.widget_id};
    const jfloat frame_values[4] = {state.x, state.y, state.width, state.height};
    (*env)->SetLongArrayRegion(env, widget_id, 0, 1, id_value);
    (*env)->SetFloatArrayRegion(env, frame, 0, 4, frame_values);
    return state.active ? JNI_TRUE : JNI_FALSE;
}

// True when an overflowing scrollable widget's bounds contain the point —
// the pan-to-scroll decision the iOS host takes from the same semantics
// export (its mirror of UIScrollView's delayed content touches).
JNIEXPORT jboolean JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeScrollableWidgetAt(JNIEnv *env, jobject self, jlong app, jfloat x, jfloat y) {
    (void)env;
    (void)self;
    uintptr_t count = native_sdk_app_widget_semantics_count((void *)app);
    for (uintptr_t index = 0; index < count; index++) {
        native_sdk_widget_semantics_t node;
        memset(&node, 0, sizeof(node));
        if (!native_sdk_app_widget_semantics_at((void *)app, index, &node)) continue;
        if (!node.has_scroll) continue;
        if (node.scroll_content_extent <= node.scroll_viewport_extent) continue;
        if (x < node.x || x > node.x + node.width) continue;
        if (y < node.y || y > node.y + node.height) continue;
        return JNI_TRUE;
    }
    return JNI_FALSE;
}

// ------------------------------------------------------- assets/automation

JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeSetAssetRoot(JNIEnv *env, jobject self, jlong app, jstring path) {
    (void)self;
    if (!path) return;
    const char *chars = (*env)->GetStringUTFChars(env, path, NULL);
    if (!chars) return;
    native_sdk_app_set_asset_root((void *)app, chars, strlen(chars));
    host_log_error((void *)app, "asset_root");
    (*env)->ReleaseStringUTFChars(env, path, chars);
}

JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeSetAutomationDir(JNIEnv *env, jobject self, jlong app, jstring path) {
    (void)self;
    if (!path) return;
    const char *chars = (*env)->GetStringUTFChars(env, path, NULL);
    if (!chars) return;
    native_sdk_app_set_automation_dir((void *)app, chars, strlen(chars));
    host_log_error((void *)app, "automation");
    NATIVE_SDK_LOGI("automation dir %s", chars);
    (*env)->ReleaseStringUTFChars(env, path, chars);
}

// ------------------------------------------------------------ text metrics

// The embed measure callback: upcall to the activity's Paint-backed
// measureText with the run as UTF-8 bytes. A negative return (invalid
// UTF-8, measurement failure) falls back to layout's estimator; measured
// widths are memoized on the Java side.
static double host_measure_text(void *context, uint64_t font_id, double size, const char *text, uintptr_t text_len) {
    (void)context;
    if (!text || text_len == 0) return 0;
    if (!host_state.vm || !host_state.activity || !host_state.measure_method) return -1;
    JNIEnv *env = NULL;
    if ((*host_state.vm)->GetEnv(host_state.vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK || !env) return -1;
    jbyteArray bytes = (*env)->NewByteArray(env, (jsize)text_len);
    if (!bytes) return -1;
    (*env)->SetByteArrayRegion(env, bytes, 0, (jsize)text_len, (const jbyte *)text);
    jdouble width = (*env)->CallDoubleMethod(env, host_state.activity, host_state.measure_method, (jlong)font_id, (jdouble)size, bytes);
    (*env)->DeleteLocalRef(env, bytes);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return -1;
    }
    return width;
}

JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeSetTextMeasure(JNIEnv *env, jobject self, jlong app) {
    if ((*env)->GetJavaVM(env, &host_state.vm) != JNI_OK) return;
    if (host_state.activity) (*env)->DeleteGlobalRef(env, host_state.activity);
    host_state.activity = (*env)->NewGlobalRef(env, self);
    jclass cls = (*env)->GetObjectClass(env, self);
    host_state.measure_method = (*env)->GetMethodID(env, cls, "measureText", "(JD[B)D");
    (*env)->DeleteLocalRef(env, cls);
    if (!host_state.activity || !host_state.measure_method) {
        NATIVE_SDK_LOGE("text_measure registration failed");
        return;
    }
    native_sdk_app_set_text_measure((void *)app, host_measure_text, NULL);
    host_log_error((void *)app, "text_measure");
    NATIVE_SDK_LOGI("Paint text measure registered");
}

// ------------------------------------------------------------------ audio
//
// The embed audio service, bridged to the activity's Java-side player
// (android.media.MediaPlayer — see the audio section in
// NativeSdkActivity.java for the backend rationale and its constraints).
// The service callbacks run INSIDE runtime dispatch on the main thread
// (the runtime entry points are only ever called from the activity's
// thread), so the upcalls resolve the JNIEnv through the stored JavaVM
// exactly like the text-measure upcall; the Java side never emits an
// event synchronously from inside these calls — every asynchronous report
// (loaded, ticks, completion, failure) arrives on a later main-loop turn
// through nativeAudioEvent, the same next-turn discipline the desktop
// hosts keep.

static JNIEnv *host_audio_env(void) {
    if (!host_state.vm || !host_state.audio_activity) return NULL;
    JNIEnv *env = NULL;
    if ((*host_state.vm)->GetEnv(host_state.vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return NULL;
    return env;
}

// UTF-8 bytes cross as byte arrays (not jstring) so paths and URLs
// survive the JNI modified-UTF-8 seam, mirroring the input direction.
static jbyteArray host_audio_bytes(JNIEnv *env, const char *bytes, uintptr_t len) {
    jbyteArray array = (*env)->NewByteArray(env, (jsize)len);
    if (!array) return NULL;
    if (len > 0) (*env)->SetByteArrayRegion(env, array, 0, (jsize)len, (const jbyte *)bytes);
    return array;
}

static int host_audio_call_cleared(JNIEnv *env, int failure_result, jint result) {
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return failure_result;
    }
    return (int)result;
}

static int host_audio_load(void *context, const char *path, uintptr_t path_len) {
    (void)context;
    JNIEnv *env = host_audio_env();
    if (!env) return 2;
    jbyteArray bytes = host_audio_bytes(env, path, path_len);
    if (!bytes) return 2;
    jint result = (*env)->CallIntMethod(env, host_state.audio_activity, host_state.audio_load_method, bytes);
    (*env)->DeleteLocalRef(env, bytes);
    return host_audio_call_cleared(env, 2, result);
}

static int host_audio_load_url(void *context, const char *url, uintptr_t url_len, const char *cache_path, uintptr_t cache_path_len, uint64_t expected_bytes) {
    (void)context;
    JNIEnv *env = host_audio_env();
    if (!env) return 2;
    jbyteArray url_bytes = host_audio_bytes(env, url, url_len);
    if (!url_bytes) return 2;
    jbyteArray cache_bytes = host_audio_bytes(env, cache_path ? cache_path : "", cache_path ? cache_path_len : 0);
    if (!cache_bytes) {
        (*env)->DeleteLocalRef(env, url_bytes);
        return 2;
    }
    jint result = (*env)->CallIntMethod(env, host_state.audio_activity, host_state.audio_load_url_method, url_bytes, cache_bytes, (jlong)expected_bytes);
    (*env)->DeleteLocalRef(env, url_bytes);
    (*env)->DeleteLocalRef(env, cache_bytes);
    return host_audio_call_cleared(env, 2, result);
}

static int host_audio_transport(jmethodID method) {
    JNIEnv *env = host_audio_env();
    if (!env || !method) return 0;
    jint result = (*env)->CallIntMethod(env, host_state.audio_activity, method);
    return host_audio_call_cleared(env, 0, result);
}

static int host_audio_play(void *context) {
    (void)context;
    return host_audio_transport(host_state.audio_play_method);
}

static int host_audio_pause(void *context) {
    (void)context;
    return host_audio_transport(host_state.audio_pause_method);
}

static int host_audio_stop(void *context) {
    (void)context;
    return host_audio_transport(host_state.audio_stop_method);
}

static int host_audio_seek(void *context, uint64_t position_ms) {
    (void)context;
    JNIEnv *env = host_audio_env();
    if (!env) return 0;
    jint result = (*env)->CallIntMethod(env, host_state.audio_activity, host_state.audio_seek_method, (jlong)position_ms);
    return host_audio_call_cleared(env, 0, result);
}

static int host_audio_set_volume(void *context, double volume) {
    (void)context;
    JNIEnv *env = host_audio_env();
    if (!env) return 0;
    jint result = (*env)->CallIntMethod(env, host_state.audio_activity, host_state.audio_set_volume_method, (jdouble)volume);
    return host_audio_call_cleared(env, 0, result);
}

// Register the activity's player as the embed platform audio service —
// the full table (playback + streaming tiers), matching what the Java
// side actually implements. Called before nativeStart, like the text
// measure, so the first effect dispatch already sees the service.
JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeSetAudioService(JNIEnv *env, jobject self, jlong app) {
    if ((*env)->GetJavaVM(env, &host_state.vm) != JNI_OK) return;
    if (host_state.audio_activity) (*env)->DeleteGlobalRef(env, host_state.audio_activity);
    host_state.audio_activity = (*env)->NewGlobalRef(env, self);
    jclass cls = (*env)->GetObjectClass(env, self);
    host_state.audio_load_method = (*env)->GetMethodID(env, cls, "audioLoad", "([B)I");
    host_state.audio_load_url_method = (*env)->GetMethodID(env, cls, "audioLoadUrl", "([B[BJ)I");
    host_state.audio_play_method = (*env)->GetMethodID(env, cls, "audioPlay", "()I");
    host_state.audio_pause_method = (*env)->GetMethodID(env, cls, "audioPause", "()I");
    host_state.audio_stop_method = (*env)->GetMethodID(env, cls, "audioStop", "()I");
    host_state.audio_seek_method = (*env)->GetMethodID(env, cls, "audioSeek", "(J)I");
    host_state.audio_set_volume_method = (*env)->GetMethodID(env, cls, "audioSetVolume", "(D)I");
    (*env)->DeleteLocalRef(env, cls);
    if (!host_state.audio_activity || !host_state.audio_load_method || !host_state.audio_load_url_method ||
        !host_state.audio_play_method || !host_state.audio_pause_method || !host_state.audio_stop_method ||
        !host_state.audio_seek_method || !host_state.audio_set_volume_method) {
        NATIVE_SDK_LOGE("audio_service registration failed");
        return;
    }
    static const native_sdk_audio_service_t service = {
        .load = host_audio_load,
        .load_url = host_audio_load_url,
        .play = host_audio_play,
        .pause = host_audio_pause,
        .stop = host_audio_stop,
        .seek = host_audio_seek,
        .set_volume = host_audio_set_volume,
    };
    native_sdk_app_set_audio_service((void *)app, &service, NULL);
    host_log_error((void *)app, "audio_service");
    NATIVE_SDK_LOGI("audio service registered");
}

// ------------------------------------------------------------------ images
//
// The embed image-decode service, bridged to the activity's Java-side
// codec (android.graphics.BitmapFactory — see the image section in
// NativeSdkActivity.java). The decode callback runs INSIDE runtime
// dispatch on the main thread (a synchronous fx.registerImageBytes call),
// so the upcall resolves the JNIEnv through the stored JavaVM exactly
// like the text-measure and audio upcalls. The runtime's decode scratch
// buffer crosses as a direct ByteBuffer so the Java side writes pixels
// straight into it — no second pixel copy on the JNI seam.

// Decode `bytes` into straight-alpha RGBA8 written into `pixels`.
// Returns 1 decoded (dimensions in out_width/out_height), -1 when the
// decoded pixels do not fit pixels_len, 0 undecodable — the embed image
// service contract (native_sdk_app.h).
static int host_image_decode(void *context, const uint8_t *bytes, uintptr_t bytes_len, uint8_t *pixels, uintptr_t pixels_len, uintptr_t *out_width, uintptr_t *out_height) {
    (void)context;
    if (out_width) *out_width = 0;
    if (out_height) *out_height = 0;
    if (!bytes || bytes_len == 0 || !pixels) return 0;
    if (!host_state.vm || !host_state.image_activity || !host_state.image_decode_method) return 0;
    JNIEnv *env = NULL;
    if ((*host_state.vm)->GetEnv(host_state.vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK || !env) return 0;
    jbyteArray encoded = (*env)->NewByteArray(env, (jsize)bytes_len);
    if (!encoded) return 0;
    (*env)->SetByteArrayRegion(env, encoded, 0, (jsize)bytes_len, (const jbyte *)bytes);
    jobject buffer = (*env)->NewDirectByteBuffer(env, pixels, (jlong)pixels_len);
    if (!buffer) {
        (*env)->DeleteLocalRef(env, encoded);
        return 0;
    }
    jlongArray dims = (*env)->NewLongArray(env, 2);
    if (!dims) {
        (*env)->DeleteLocalRef(env, buffer);
        (*env)->DeleteLocalRef(env, encoded);
        return 0;
    }
    jint result = (*env)->CallIntMethod(env, host_state.image_activity, host_state.image_decode_method, encoded, buffer, dims);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        result = 0;
    } else if (result == 1) {
        jlong values[2] = {0, 0};
        (*env)->GetLongArrayRegion(env, dims, 0, 2, values);
        if (out_width) *out_width = (uintptr_t)values[0];
        if (out_height) *out_height = (uintptr_t)values[1];
    }
    (*env)->DeleteLocalRef(env, dims);
    (*env)->DeleteLocalRef(env, buffer);
    (*env)->DeleteLocalRef(env, encoded);
    return (int)result;
}

// Register the activity's codec as the embed platform image decoder.
// Called before nativeStart, like the audio service, so a boot-effect
// fx.registerImageBytes already decodes.
JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeSetImageService(JNIEnv *env, jobject self, jlong app) {
    if ((*env)->GetJavaVM(env, &host_state.vm) != JNI_OK) return;
    if (host_state.image_activity) (*env)->DeleteGlobalRef(env, host_state.image_activity);
    host_state.image_activity = (*env)->NewGlobalRef(env, self);
    jclass cls = (*env)->GetObjectClass(env, self);
    host_state.image_decode_method = (*env)->GetMethodID(env, cls, "imageDecode", "([BLjava/nio/ByteBuffer;[J)I");
    (*env)->DeleteLocalRef(env, cls);
    if (!host_state.image_activity || !host_state.image_decode_method) {
        NATIVE_SDK_LOGE("image_service registration failed");
        return;
    }
    static const native_sdk_image_service_t service = {
        .decode = host_image_decode,
    };
    native_sdk_app_set_image_service((void *)app, &service, NULL);
    host_log_error((void *)app, "image_service");
    NATIVE_SDK_LOGI("image decode service registered");
}

// One player report from the Java side (kind ordinals in
// native_sdk_app.h), called on the main thread between runtime entry
// points — never from inside an audio service callback.
JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeAudioEvent(JNIEnv *env, jobject self, jlong app, jint kind, jlong position_ms, jlong duration_ms, jint playing, jint buffering) {
    (void)env;
    (void)self;
    native_sdk_app_audio_event((void *)app, (int)kind, (uint64_t)position_ms, (uint64_t)duration_ms, (int)playing, (int)buffering);
}

JNIEXPORT jstring JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeLastError(JNIEnv *env, jobject self, jlong app) {
    (void)self;
    const char *name = native_sdk_app_last_error_name((void *)app);
    return (*env)->NewStringUTF(env, name ? name : "");
}
