#include "gtk_pixels.h"

#include <float.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); \
        return 0; \
    } \
} while (0)

static int check_bounds(native_sdk_gtk_pixel_bounds_t bounds, size_t x0, size_t y0, size_t x1, size_t y1) {
    CHECK(bounds.x0 == x0);
    CHECK(bounds.y0 == y0);
    CHECK(bounds.x1 == x1);
    CHECK(bounds.y1 == y1);
    return 1;
}

static int test_buffer_reuse(void) {
    unsigned char buffer[1];
    CHECK(!native_sdk_gtk_pixels_can_reuse_buffer(NULL, 20, 10, 80, 20, 10, 80));
    CHECK(!native_sdk_gtk_pixels_can_reuse_buffer(buffer, 19, 10, 80, 20, 10, 80));
    CHECK(!native_sdk_gtk_pixels_can_reuse_buffer(buffer, 20, 9, 80, 20, 10, 80));
    CHECK(!native_sdk_gtk_pixels_can_reuse_buffer(buffer, 20, 10, 76, 20, 10, 80));
    CHECK(native_sdk_gtk_pixels_can_reuse_buffer(buffer, 20, 10, 80, 20, 10, 80));
    return 1;
}

static int test_dirty_bounds(void) {
    native_sdk_gtk_pixel_bounds_t bounds;

    CHECK(!native_sdk_gtk_pixels_dirty_bounds(10, 10, 0, 1, 1, 1, 1, 1, &bounds));
    CHECK(check_bounds(bounds, 0, 0, 10, 10));
    CHECK(!native_sdk_gtk_pixels_dirty_bounds(10, 10, 1, 0, 1, 1, 1, 1, &bounds));
    CHECK(!native_sdk_gtk_pixels_dirty_bounds(10, 10, 1, -1, 1, 1, 1, 1, &bounds));
    CHECK(!native_sdk_gtk_pixels_dirty_bounds(10, 10, 1, NAN, 1, 1, 1, 1, &bounds));
    CHECK(!native_sdk_gtk_pixels_dirty_bounds(10, 10, 1, INFINITY, 1, 1, 1, 1, &bounds));
    CHECK(!native_sdk_gtk_pixels_dirty_bounds(10, 10, 1, 1, NAN, 1, 1, 1, &bounds));
    CHECK(!native_sdk_gtk_pixels_dirty_bounds(10, 10, 1, 1, 1, INFINITY, 1, 1, &bounds));
    CHECK(!native_sdk_gtk_pixels_dirty_bounds(10, 10, 1, 1, 1, 1, NAN, 1, &bounds));
    CHECK(!native_sdk_gtk_pixels_dirty_bounds(10, 10, 1, 1, 1, 1, 1, -INFINITY, &bounds));
    CHECK(!native_sdk_gtk_pixels_dirty_bounds(10, 10, 1, 1, DBL_MAX, 0, DBL_MAX, 1, &bounds));
    CHECK(check_bounds(bounds, 0, 0, 10, 10));
    CHECK(!native_sdk_gtk_pixels_dirty_bounds(10, 10, 1, DBL_MAX, 1, 1, 1, 1, &bounds));
    CHECK(check_bounds(bounds, 0, 0, 10, 10));

    CHECK(native_sdk_gtk_pixels_dirty_bounds(10, 10, 1, 1, 1.25, 2.2, 3.25, 4.1, &bounds));
    CHECK(check_bounds(bounds, 1, 2, 5, 7));
    CHECK(native_sdk_gtk_pixels_dirty_bounds(12, 12, 1, 1.5, 1.1, 2.1, 2.6, 3.3, &bounds));
    CHECK(check_bounds(bounds, 1, 3, 6, 9));
    CHECK(native_sdk_gtk_pixels_dirty_bounds(16, 16, 1, 2, 1.25, 2.2, 3.25, 4.1, &bounds));
    CHECK(check_bounds(bounds, 2, 4, 9, 13));
    CHECK(native_sdk_gtk_pixels_dirty_bounds(12, 12, 1, 1, 5.5, 7.25, -3.25, -2, &bounds));
    CHECK(check_bounds(bounds, 2, 5, 6, 8));

    CHECK(native_sdk_gtk_pixels_dirty_bounds(10, 10, 1, 1, -2, 2, 3, 1, &bounds));
    CHECK(check_bounds(bounds, 0, 2, 1, 3));
    CHECK(native_sdk_gtk_pixels_dirty_bounds(10, 10, 1, 1, 9.2, 2, 4, 1, &bounds));
    CHECK(check_bounds(bounds, 9, 2, 10, 3));
    CHECK(native_sdk_gtk_pixels_dirty_bounds(10, 10, 1, 1, 2, -2, 1, 3, &bounds));
    CHECK(check_bounds(bounds, 2, 0, 3, 1));
    CHECK(native_sdk_gtk_pixels_dirty_bounds(10, 10, 1, 1, 2, 9.2, 1, 4, &bounds));
    CHECK(check_bounds(bounds, 2, 9, 3, 10));
    CHECK(native_sdk_gtk_pixels_dirty_bounds(10, 10, 1, 1, -4, 1, 1, 1, &bounds));
    CHECK(check_bounds(bounds, 0, 1, 0, 2));
    return 1;
}

static int test_conversion(void) {
    const size_t width = 3;
    const size_t height = 2;
    const size_t stride = width * 4 + 8;
    const uint8_t rgba8[] = {
        0, 0, 0, 0,
        200, 100, 50, 128,
        12, 34, 56, 255,
        1, 2, 3, 255,
        100, 100, 100, 127,
        9, 8, 7, 64,
    };
    unsigned char argb[stride * height];
    memset(argb, 0xa5, sizeof(argb));
    native_sdk_gtk_pixels_convert(argb, stride, rgba8, width, native_sdk_gtk_pixels_full_bounds(width, height));
    const uint32_t *row0 = (const uint32_t *)argb;
    const uint32_t *row1 = (const uint32_t *)(argb + stride);
    CHECK(row0[0] == 0x00000000u);
    CHECK(row0[1] == 0x80643219u);
    CHECK(row0[2] == 0xff0c2238u);
    CHECK(row1[0] == 0xff010203u);
    CHECK(row1[1] == 0x7f323232u);
    CHECK(row1[2] == 0x40020202u);
    for (size_t row = 0; row < height; row++) {
        for (size_t offset = width * 4; offset < stride; offset++) CHECK(argb[row * stride + offset] == 0xa5);
    }

    unsigned char before[sizeof(argb)];
    memcpy(before, argb, sizeof(argb));
    const native_sdk_gtk_pixel_bounds_t empty = { .x0 = 0, .y0 = 1, .x1 = 0, .y1 = 2 };
    native_sdk_gtk_pixels_convert(argb, stride, rgba8, width, empty);
    CHECK(memcmp(argb, before, sizeof(argb)) == 0);
    return 1;
}

static int test_initial_and_resized_buffers_convert_fully(void) {
    enum { width = 4, height = 3, stride = width * 4 };
    const uint8_t rgba8[width * height * 4] = {
        1, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 255, 10, 11, 12, 255,
        13, 14, 15, 255, 16, 17, 18, 255, 19, 20, 21, 255, 22, 23, 24, 255,
        25, 26, 27, 255, 28, 29, 30, 255, 31, 32, 33, 255, 34, 35, 36, 255,
    };
    unsigned char initial[stride * height];
    memset(initial, 0, sizeof(initial));
    native_sdk_gtk_pixel_bounds_t bounds = native_sdk_gtk_pixels_full_bounds(width, height);
    CHECK(!native_sdk_gtk_pixels_can_reuse_buffer(NULL, 0, 0, 0, width, height, stride));
    native_sdk_gtk_pixels_convert(initial, stride, rgba8, width, bounds);
    for (size_t index = 0; index < width * height; index++) {
        const uint32_t *pixels = (const uint32_t *)initial;
        CHECK(pixels[index] == (0xff000000u |
            ((uint32_t)rgba8[index * 4 + 0] << 16) |
            ((uint32_t)rgba8[index * 4 + 1] << 8) |
            rgba8[index * 4 + 2]));
    }

    enum { resized_width = 3, resized_height = 2, resized_stride = resized_width * 4 };
    const uint8_t resized_rgba8[resized_width * resized_height * 4] = {
        100, 1, 2, 255, 101, 3, 4, 255, 102, 5, 6, 255,
        103, 7, 8, 255, 104, 9, 10, 255, 105, 11, 12, 255,
    };
    unsigned char resized[resized_stride * resized_height];
    memset(resized, 0, sizeof(resized));
    bounds = native_sdk_gtk_pixels_full_bounds(resized_width, resized_height);
    CHECK(!native_sdk_gtk_pixels_can_reuse_buffer(initial, (int)width, (int)height, (int)stride,
        resized_width, resized_height, (int)resized_stride));
    native_sdk_gtk_pixels_convert(resized, resized_stride, resized_rgba8, resized_width, bounds);
    for (size_t index = 0; index < resized_width * resized_height; index++) {
        const uint32_t *pixels = (const uint32_t *)resized;
        CHECK(pixels[index] == (0xff000000u |
            ((uint32_t)resized_rgba8[index * 4 + 0] << 16) |
            ((uint32_t)resized_rgba8[index * 4 + 1] << 8) |
            resized_rgba8[index * 4 + 2]));
    }
    return 1;
}

static int test_incremental_conversion(void) {
    const size_t width = 1400;
    const size_t height = 900;
    const size_t stride = width * 4 + 8;
    const size_t pixel_count = width * height;
    uint8_t *first = malloc(pixel_count * 4);
    uint8_t *next = malloc(pixel_count * 4);
    unsigned char *argb = malloc(stride * height);
    unsigned char *before = malloc(stride * height);
    CHECK(first && next && argb && before);
    memset(first, 0, pixel_count * 4);
    memset(next, 0, pixel_count * 4);
    for (size_t index = 0; index < pixel_count; index++) {
        first[index * 4 + 0] = 10;
        first[index * 4 + 1] = 20;
        first[index * 4 + 2] = 30;
        first[index * 4 + 3] = 255;
        next[index * 4 + 0] = 40;
        next[index * 4 + 1] = 50;
        next[index * 4 + 2] = 60;
        next[index * 4 + 3] = 255;
    }
    memset(argb, 0xa5, stride * height);
    native_sdk_gtk_pixels_convert(argb, stride, first, width, native_sdk_gtk_pixels_full_bounds(width, height));
    memcpy(before, argb, stride * height);

    native_sdk_gtk_pixel_bounds_t dirty;
    CHECK(native_sdk_gtk_pixels_dirty_bounds(width, height, 1, 1, 100, 100, 20, 20, &dirty));
    CHECK(check_bounds(dirty, 100, 100, 120, 120));
    native_sdk_gtk_pixels_convert(argb, stride, next, width, dirty);
    size_t updated = 0;
    for (size_t y = 0; y < height; y++) {
        const uint32_t *row = (const uint32_t *)(argb + y * stride);
        const uint32_t *old_row = (const uint32_t *)(before + y * stride);
        for (size_t x = 0; x < width; x++) {
            const int in_dirty = x >= 100 && x < 120 && y >= 100 && y < 120;
            if (in_dirty) {
                CHECK(row[x] == 0xff28323cu);
                updated++;
            } else {
                CHECK(row[x] == old_row[x]);
            }
        }
        for (size_t offset = width * 4; offset < stride; offset++) CHECK(argb[y * stride + offset] == 0xa5);
    }
    CHECK(updated == 400);

    free(before);
    free(argb);
    free(next);
    free(first);
    return 1;
}

static int test_partial_matches_full_when_damage_is_complete(void) {
    const size_t width = 6;
    const size_t height = 5;
    const size_t stride = width * 4 + 4;
    uint8_t first[width * height * 4];
    uint8_t next[width * height * 4];
    unsigned char partial[stride * height];
    unsigned char full[stride * height];
    for (size_t index = 0; index < width * height; index++) {
        first[index * 4 + 0] = (uint8_t)(index + 1);
        first[index * 4 + 1] = (uint8_t)(index + 2);
        first[index * 4 + 2] = (uint8_t)(index + 3);
        first[index * 4 + 3] = 255;
    }
    memcpy(next, first, sizeof(next));
    for (size_t y = 1; y < 4; y++) for (size_t x = 2; x < 5; x++) {
        const size_t index = (y * width + x) * 4;
        next[index + 0] = 200;
        next[index + 1] = 100;
        next[index + 2] = 50;
        next[index + 3] = 128;
    }
    memset(partial, 0xa5, sizeof(partial));
    memset(full, 0xa5, sizeof(full));
    native_sdk_gtk_pixels_convert(partial, stride, first, width, native_sdk_gtk_pixels_full_bounds(width, height));
    memcpy(full, partial, sizeof(full));
    native_sdk_gtk_pixel_bounds_t dirty;
    CHECK(native_sdk_gtk_pixels_dirty_bounds(width, height, 1, 1, 2, 1, 3, 3, &dirty));
    native_sdk_gtk_pixels_convert(partial, stride, next, width, dirty);
    native_sdk_gtk_pixels_convert(full, stride, next, width, native_sdk_gtk_pixels_full_bounds(width, height));
    CHECK(memcmp(partial, full, sizeof(full)) == 0);
    return 1;
}

int main(void) {
    return !(test_buffer_reuse() && test_dirty_bounds() && test_conversion() &&
        test_initial_and_resized_buffers_convert_fully() && test_incremental_conversion() &&
        test_partial_matches_full_when_damage_is_complete());
}
