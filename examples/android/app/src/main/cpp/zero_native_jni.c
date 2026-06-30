#include <jni.h>
#include <stdint.h>
#include <string.h>

#include "zero_native.h"

static jbyteArray zero_native_jni_bytes(JNIEnv *env, const char *ptr, uintptr_t len) {
    jbyteArray out = (*env)->NewByteArray(env, (jsize)len);
    if (!out) return NULL;
    if (ptr && len > 0) {
        (*env)->SetByteArrayRegion(env, out, 0, (jsize)len, (const jbyte *)ptr);
    }
    return out;
}

JNIEXPORT jlong JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeCreate(JNIEnv *env, jobject self) {
    (void)env;
    (void)self;
    return (jlong)zero_native_app_create();
}

JNIEXPORT void JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeDestroy(JNIEnv *env, jobject self, jlong app) {
    (void)env;
    (void)self;
    zero_native_app_destroy((void *)app);
}

JNIEXPORT void JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeStart(JNIEnv *env, jobject self, jlong app) {
    (void)env;
    (void)self;
    zero_native_app_start((void *)app);
}

JNIEXPORT void JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeActivate(JNIEnv *env, jobject self, jlong app) {
    (void)env;
    (void)self;
    zero_native_app_activate((void *)app);
}

JNIEXPORT void JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeDeactivate(JNIEnv *env, jobject self, jlong app) {
    (void)env;
    (void)self;
    zero_native_app_deactivate((void *)app);
}

JNIEXPORT void JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeStop(JNIEnv *env, jobject self, jlong app) {
    (void)env;
    (void)self;
    zero_native_app_stop((void *)app);
}

JNIEXPORT void JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeResize(JNIEnv *env, jobject self, jlong app, jfloat width, jfloat height, jfloat scale, jobject surface) {
    (void)env;
    (void)self;
    zero_native_app_resize((void *)app, width, height, scale, surface);
}

JNIEXPORT void JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeViewport(JNIEnv *env, jobject self, jlong app, jfloat width, jfloat height, jfloat scale, jobject surface, jfloat safe_top, jfloat safe_right, jfloat safe_bottom, jfloat safe_left, jfloat keyboard_top, jfloat keyboard_right, jfloat keyboard_bottom, jfloat keyboard_left) {
    (void)env;
    (void)self;
    zero_native_app_viewport((void *)app, width, height, scale, surface, safe_top, safe_right, safe_bottom, safe_left, keyboard_top, keyboard_right, keyboard_bottom, keyboard_left);
}

JNIEXPORT void JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeTouch(JNIEnv *env, jobject self, jlong app, jlong id, jint phase, jfloat x, jfloat y, jfloat pressure) {
    (void)env;
    (void)self;
    zero_native_app_touch((void *)app, (uint64_t)id, phase, x, y, pressure);
}

JNIEXPORT void JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeScroll(JNIEnv *env, jobject self, jlong app, jlong id, jfloat x, jfloat y, jfloat delta_x, jfloat delta_y) {
    (void)env;
    (void)self;
    zero_native_app_scroll((void *)app, (uint64_t)id, x, y, delta_x, delta_y);
}

JNIEXPORT void JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeKey(JNIEnv *env, jobject self, jlong app, jint phase, jstring key, jstring text, jint modifiers) {
    (void)self;
    const char *key_chars = key ? (*env)->GetStringUTFChars(env, key, NULL) : NULL;
    const char *text_chars = text ? (*env)->GetStringUTFChars(env, text, NULL) : NULL;
    zero_native_app_key((void *)app, phase, key_chars, key_chars ? strlen(key_chars) : 0, text_chars, text_chars ? strlen(text_chars) : 0, (uint32_t)modifiers);
    if (key_chars) (*env)->ReleaseStringUTFChars(env, key, key_chars);
    if (text_chars) (*env)->ReleaseStringUTFChars(env, text, text_chars);
}

JNIEXPORT void JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeText(JNIEnv *env, jobject self, jlong app, jstring text) {
    (void)self;
    const char *text_chars = (*env)->GetStringUTFChars(env, text, NULL);
    if (!text_chars) return;
    zero_native_app_text((void *)app, text_chars, strlen(text_chars));
    (*env)->ReleaseStringUTFChars(env, text, text_chars);
}

JNIEXPORT void JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeIme(JNIEnv *env, jobject self, jlong app, jint kind, jstring text, jlong cursor) {
    (void)self;
    const char *text_chars = text ? (*env)->GetStringUTFChars(env, text, NULL) : NULL;
    zero_native_app_ime((void *)app, kind, text_chars, text_chars ? strlen(text_chars) : 0, (intptr_t)cursor);
    if (text_chars) (*env)->ReleaseStringUTFChars(env, text, text_chars);
}

JNIEXPORT jint JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeCommand(JNIEnv *env, jobject self, jlong app, jstring command) {
    (void)self;
    const char *command_chars = (*env)->GetStringUTFChars(env, command, NULL);
    if (!command_chars) return 0;
    zero_native_app_command((void *)app, command_chars, strlen(command_chars));
    (*env)->ReleaseStringUTFChars(env, command, command_chars);
    return (jint)zero_native_app_last_command_count((void *)app);
}

JNIEXPORT void JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeFrame(JNIEnv *env, jobject self, jlong app) {
    (void)env;
    (void)self;
    zero_native_app_frame((void *)app);
}

JNIEXPORT jint JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeWidgetSemanticsCount(JNIEnv *env, jobject self, jlong app) {
    (void)env;
    (void)self;
    return (jint)zero_native_app_widget_semantics_count((void *)app);
}

JNIEXPORT jboolean JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeWidgetSemanticsFields(JNIEnv *env, jobject self, jlong app, jint index, jlongArray ids, jintArray ints, jfloatArray floats) {
    (void)self;
    if (!ids || !ints || !floats) return JNI_FALSE;
    if ((*env)->GetArrayLength(env, ids) < 12 || (*env)->GetArrayLength(env, ints) < 5 || (*env)->GetArrayLength(env, floats) < 8) return JNI_FALSE;

    zero_native_widget_semantics_t node;
    memset(&node, 0, sizeof(node));
    if (!zero_native_app_widget_semantics_at((void *)app, (uintptr_t)index, &node)) return JNI_FALSE;

    const jlong id_values[12] = {
        (jlong)node.id,
        (jlong)node.parent_id,
        (jlong)node.text_selection_start,
        (jlong)node.text_selection_end,
        (jlong)node.text_composition_start,
        (jlong)node.text_composition_end,
        (jlong)node.grid_row_index,
        (jlong)node.grid_column_index,
        (jlong)node.grid_row_count,
        (jlong)node.grid_column_count,
        (jlong)node.list_item_index,
        (jlong)node.list_item_count,
    };
    const jint int_values[5] = {
        (jint)node.role,
        (jint)node.flags,
        (jint)node.actions,
        (jint)node.has_value,
        (jint)node.has_scroll,
    };
    const jfloat float_values[8] = {
        (jfloat)node.x,
        (jfloat)node.y,
        (jfloat)node.width,
        (jfloat)node.height,
        (jfloat)node.value,
        (jfloat)node.scroll_offset,
        (jfloat)node.scroll_viewport_extent,
        (jfloat)node.scroll_content_extent,
    };
    (*env)->SetLongArrayRegion(env, ids, 0, 12, id_values);
    (*env)->SetIntArrayRegion(env, ints, 0, 5, int_values);
    (*env)->SetFloatArrayRegion(env, floats, 0, 8, float_values);
    return JNI_TRUE;
}

JNIEXPORT jbyteArray JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeWidgetSemanticsLabel(JNIEnv *env, jobject self, jlong app, jint index) {
    (void)self;
    zero_native_widget_semantics_t node;
    memset(&node, 0, sizeof(node));
    if (!zero_native_app_widget_semantics_at((void *)app, (uintptr_t)index, &node)) return zero_native_jni_bytes(env, "", 0);
    return zero_native_jni_bytes(env, node.label, node.label_len);
}

JNIEXPORT jbyteArray JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeWidgetSemanticsText(JNIEnv *env, jobject self, jlong app, jint index) {
    (void)self;
    zero_native_widget_semantics_t node;
    memset(&node, 0, sizeof(node));
    if (!zero_native_app_widget_semantics_at((void *)app, (uintptr_t)index, &node)) return zero_native_jni_bytes(env, "", 0);
    return zero_native_jni_bytes(env, node.text, node.text_len);
}

JNIEXPORT jboolean JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeWidgetSemanticsByIdFields(JNIEnv *env, jobject self, jlong app, jlong id, jlongArray ids, jintArray ints, jfloatArray floats) {
    (void)self;
    if (!ids || !ints || !floats) return JNI_FALSE;
    if ((*env)->GetArrayLength(env, ids) < 12 || (*env)->GetArrayLength(env, ints) < 5 || (*env)->GetArrayLength(env, floats) < 8) return JNI_FALSE;

    zero_native_widget_semantics_t node;
    memset(&node, 0, sizeof(node));
    if (!zero_native_app_widget_semantics_by_id((void *)app, (uint64_t)id, &node)) return JNI_FALSE;

    const jlong id_values[12] = {
        (jlong)node.id,
        (jlong)node.parent_id,
        (jlong)node.text_selection_start,
        (jlong)node.text_selection_end,
        (jlong)node.text_composition_start,
        (jlong)node.text_composition_end,
        (jlong)node.grid_row_index,
        (jlong)node.grid_column_index,
        (jlong)node.grid_row_count,
        (jlong)node.grid_column_count,
        (jlong)node.list_item_index,
        (jlong)node.list_item_count,
    };
    const jint int_values[5] = {
        (jint)node.role,
        (jint)node.flags,
        (jint)node.actions,
        (jint)node.has_value,
        (jint)node.has_scroll,
    };
    const jfloat float_values[8] = {
        (jfloat)node.x,
        (jfloat)node.y,
        (jfloat)node.width,
        (jfloat)node.height,
        (jfloat)node.value,
        (jfloat)node.scroll_offset,
        (jfloat)node.scroll_viewport_extent,
        (jfloat)node.scroll_content_extent,
    };
    (*env)->SetLongArrayRegion(env, ids, 0, 12, id_values);
    (*env)->SetIntArrayRegion(env, ints, 0, 5, int_values);
    (*env)->SetFloatArrayRegion(env, floats, 0, 8, float_values);
    return JNI_TRUE;
}

JNIEXPORT jbyteArray JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeWidgetSemanticsByIdLabel(JNIEnv *env, jobject self, jlong app, jlong id) {
    (void)self;
    zero_native_widget_semantics_t node;
    memset(&node, 0, sizeof(node));
    if (!zero_native_app_widget_semantics_by_id((void *)app, (uint64_t)id, &node)) return zero_native_jni_bytes(env, "", 0);
    return zero_native_jni_bytes(env, node.label, node.label_len);
}

JNIEXPORT jbyteArray JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeWidgetSemanticsByIdText(JNIEnv *env, jobject self, jlong app, jlong id) {
    (void)self;
    zero_native_widget_semantics_t node;
    memset(&node, 0, sizeof(node));
    if (!zero_native_app_widget_semantics_by_id((void *)app, (uint64_t)id, &node)) return zero_native_jni_bytes(env, "", 0);
    return zero_native_jni_bytes(env, node.text, node.text_len);
}

JNIEXPORT jboolean JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeWidgetTextGeometry(JNIEnv *env, jobject self, jlong app, jlong id, jintArray ints, jfloatArray floats) {
    (void)self;
    if (!ints || !floats) return JNI_FALSE;
    if ((*env)->GetArrayLength(env, ints) < 5 || (*env)->GetArrayLength(env, floats) < 12) return JNI_FALSE;

    zero_native_widget_text_geometry_t geometry;
    memset(&geometry, 0, sizeof(geometry));
    if (!zero_native_app_widget_text_geometry((void *)app, (uint64_t)id, &geometry)) return JNI_FALSE;

    const jint int_values[5] = {
        (jint)geometry.has_caret_bounds,
        (jint)geometry.has_selection_bounds,
        (jint)geometry.selection_rect_count,
        (jint)geometry.has_composition_bounds,
        (jint)geometry.composition_rect_count,
    };
    const jfloat float_values[12] = {
        (jfloat)geometry.caret_x,
        (jfloat)geometry.caret_y,
        (jfloat)geometry.caret_width,
        (jfloat)geometry.caret_height,
        (jfloat)geometry.selection_x,
        (jfloat)geometry.selection_y,
        (jfloat)geometry.selection_width,
        (jfloat)geometry.selection_height,
        (jfloat)geometry.composition_x,
        (jfloat)geometry.composition_y,
        (jfloat)geometry.composition_width,
        (jfloat)geometry.composition_height,
    };
    (*env)->SetIntArrayRegion(env, ints, 0, 5, int_values);
    (*env)->SetFloatArrayRegion(env, floats, 0, 12, float_values);
    return JNI_TRUE;
}

JNIEXPORT jboolean JNICALL Java_dev_zero_1native_examples_android_MainActivity_nativeWidgetAction(JNIEnv *env, jobject self, jlong app, jlong id, jint action, jstring text, jlong selection_anchor, jlong selection_focus, jboolean has_selection) {
    (void)self;
    const char *text_chars = text ? (*env)->GetStringUTFChars(env, text, NULL) : NULL;
    zero_native_widget_action_t request;
    memset(&request, 0, sizeof(request));
    request.id = (uint64_t)id;
    request.action = (int)action;
    request.text = text_chars;
    request.text_len = text_chars ? strlen(text_chars) : 0;
    request.selection_anchor = (uintptr_t)selection_anchor;
    request.selection_focus = (uintptr_t)selection_focus;
    request.has_selection = has_selection ? 1 : 0;
    const int ok = zero_native_app_widget_action((void *)app, &request);
    if (text_chars) (*env)->ReleaseStringUTFChars(env, text, text_chars);
    return ok ? JNI_TRUE : JNI_FALSE;
}
