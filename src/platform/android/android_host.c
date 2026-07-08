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
// renderer (`native_sdk_app_render_pixels`, RGBA8) and this bridge copies
// those bytes into the SurfaceView's ANativeWindow buffer. The window's
// buffer format is pinned to RGBA_8888, whose byte order matches the
// renderer's output exactly, so unlike the Metal path no swizzle is
// needed — only a row copy that honors the window buffer's stride. The
// Java side pumps `native_sdk_app_frame` from a Choreographer callback
// and gates re-renders on the canvas revision from
// `native_sdk_app_gpu_frame_state`, so unchanged frames cost one ABI
// call and no copy.
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
}

JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeSurfaceDestroyed(JNIEnv *env, jobject self, jlong app) {
    (void)env;
    (void)self;
    (void)app;
    if (host_state.window) {
        ANativeWindow_release(host_state.window);
        host_state.window = NULL;
    }
}

// Report the viewport in density-independent points (the same coordinate
// space touch input uses; the render scale multiplies pixels, not
// input), with the safe-area and keyboard insets the Java side derived
// from WindowInsets. The held ANativeWindow is the surface token.
JNIEXPORT void JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativeViewport(JNIEnv *env, jobject self, jlong app, jfloat width, jfloat height, jfloat scale, jfloat safe_top, jfloat safe_right, jfloat safe_bottom, jfloat safe_left, jfloat keyboard_top, jfloat keyboard_right, jfloat keyboard_bottom, jfloat keyboard_left) {
    (void)env;
    (void)self;
    native_sdk_app_viewport((void *)app, width, height, scale, host_state.window, safe_top, safe_right, safe_bottom, safe_left, keyboard_top, keyboard_right, keyboard_bottom, keyboard_left);
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

// Render the retained scene at `scale` and copy it into the window
// buffer. RGBA8 renderer bytes match WINDOW_FORMAT_RGBA_8888 byte order,
// so the copy is a per-row memcpy honoring the buffer stride.
JNIEXPORT jboolean JNICALL Java_dev_native_1sdk_host_NativeSdkActivity_nativePresent(JNIEnv *env, jobject self, jlong app, jfloat scale) {
    (void)env;
    (void)self;
    ANativeWindow *window = host_state.window;
    if (!window) return JNI_FALSE;

    native_sdk_canvas_pixels_t info;
    memset(&info, 0, sizeof(info));
    if (!native_sdk_app_render_pixel_size((void *)app, scale, &info)) return JNI_FALSE;
    if (info.width == 0 || info.height == 0 || info.byte_len != info.width * info.height * 4) return JNI_FALSE;
    if (!host_ensure_pixel_capacity(info.byte_len)) return JNI_FALSE;

    native_sdk_canvas_pixels_t rendered;
    memset(&rendered, 0, sizeof(rendered));
    if (!native_sdk_app_render_pixels((void *)app, scale, host_state.pixels, info.byte_len, &rendered)) {
        host_log_error((void *)app, "render_pixels");
        return JNI_FALSE;
    }
    if (rendered.width == 0 || rendered.height == 0 || rendered.byte_len != rendered.width * rendered.height * 4) return JNI_FALSE;

    if (ANativeWindow_setBuffersGeometry(window, (int32_t)rendered.width, (int32_t)rendered.height, WINDOW_FORMAT_RGBA_8888) != 0) return JNI_FALSE;
    ANativeWindow_Buffer buffer;
    if (ANativeWindow_lock(window, &buffer, NULL) != 0) return JNI_FALSE;
    if ((uintptr_t)buffer.width < rendered.width || (uintptr_t)buffer.height < rendered.height) {
        ANativeWindow_unlockAndPost(window);
        return JNI_FALSE;
    }
    const size_t src_stride = rendered.width * 4;
    const size_t dst_stride = (size_t)buffer.stride * 4;
    uint8_t *dst = buffer.bits;
    const uint8_t *src = host_state.pixels;
    for (uintptr_t row = 0; row < rendered.height; row++) {
        memcpy(dst + row * dst_stride, src + row * src_stride, src_stride);
    }
    ANativeWindow_unlockAndPost(window);
    return JNI_TRUE;
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
