#ifndef NATIVE_SDK_GTK_PIXELS_H
#define NATIVE_SDK_GTK_PIXELS_H

#include <math.h>
#include <stddef.h>
#include <stdint.h>

/* GTK's software canvas retains a Cairo ARGB32 buffer between presents.
 * Keep the damage and conversion logic independent from GTK so its edge
 * cases can be exercised without a display server or GTK development files. */
typedef struct native_sdk_gtk_pixel_bounds {
    size_t x0;
    size_t y0;
    size_t x1;
    size_t y1;
} native_sdk_gtk_pixel_bounds_t;

static inline int native_sdk_gtk_pixels_can_reuse_buffer(
    const unsigned char *buffer,
    int buffer_width,
    int buffer_height,
    int buffer_stride,
    size_t width,
    size_t height,
    int stride
) {
    return buffer != NULL && buffer_width == (int)width &&
        buffer_height == (int)height && buffer_stride == stride;
}

static inline native_sdk_gtk_pixel_bounds_t native_sdk_gtk_pixels_full_bounds(size_t width, size_t height) {
    return (native_sdk_gtk_pixel_bounds_t){
        .x0 = 0,
        .y0 = 0,
        .x1 = width,
        .y1 = height,
    };
}

/* Sets bounds to the complete surface unless every input can describe a
 * finite, positive-scale logical damage rectangle. A valid rectangle may
 * still clamp to an empty range, which deliberately needs no conversion. */
static inline int native_sdk_gtk_pixels_dirty_bounds(
    size_t width,
    size_t height,
    int has_dirty_rect,
    double scale,
    double dirty_x,
    double dirty_y,
    double dirty_width,
    double dirty_height,
    native_sdk_gtk_pixel_bounds_t *bounds
) {
    if (!bounds) return 0;
    *bounds = native_sdk_gtk_pixels_full_bounds(width, height);
    if (!has_dirty_rect || !isfinite(scale) || scale <= 0 ||
        !isfinite(dirty_x) || !isfinite(dirty_y) ||
        !isfinite(dirty_width) || !isfinite(dirty_height))
    {
        return 0;
    }

    const double dirty_x_end = dirty_x + dirty_width;
    const double dirty_y_end = dirty_y + dirty_height;
    if (!isfinite(dirty_x_end) || !isfinite(dirty_y_end)) return 0;

    const double logical_x0 = dirty_x < dirty_x_end ? dirty_x : dirty_x_end;
    const double logical_y0 = dirty_y < dirty_y_end ? dirty_y : dirty_y_end;
    const double logical_x1 = dirty_x > dirty_x_end ? dirty_x : dirty_x_end;
    const double logical_y1 = dirty_y > dirty_y_end ? dirty_y : dirty_y_end;
    const double device_x0 = logical_x0 * scale;
    const double device_y0 = logical_y0 * scale;
    const double device_x1 = logical_x1 * scale;
    const double device_y1 = logical_y1 * scale;
    if (!isfinite(device_x0) || !isfinite(device_y0) ||
        !isfinite(device_x1) || !isfinite(device_y1))
    {
        return 0;
    }

    const double clamped_x0 = fmax(0.0, fmin((double)width, floor(device_x0)));
    const double clamped_y0 = fmax(0.0, fmin((double)height, floor(device_y0)));
    const double clamped_x1 = fmax(0.0, fmin((double)width, ceil(device_x1)));
    const double clamped_y1 = fmax(0.0, fmin((double)height, ceil(device_y1)));
    bounds->x0 = (size_t)clamped_x0;
    bounds->y0 = (size_t)clamped_y0;
    bounds->x1 = (size_t)clamped_x1;
    bounds->y1 = (size_t)clamped_y1;
    return 1;
}

/* Straight RGBA8 -> premultiplied native-endian ARGB32 for Cairo. Bounds
 * are half-open device-pixel coordinates and may describe an empty range. */
static inline void native_sdk_gtk_pixels_convert(
    unsigned char *argb,
    size_t argb_stride,
    const uint8_t *rgba8,
    size_t width,
    native_sdk_gtk_pixel_bounds_t bounds
) {
    for (size_t row = bounds.y0; row < bounds.y1; row++) {
        const uint8_t *src = rgba8 + (row * width + bounds.x0) * 4;
        uint32_t *dst = (uint32_t *)(argb + row * argb_stride) + bounds.x0;
        for (size_t col = bounds.x0; col < bounds.x1; col++) {
            const uint32_t r = src[0];
            const uint32_t g = src[1];
            const uint32_t b = src[2];
            const uint32_t a = src[3];
            const uint32_t pr = (r * a + 127) / 255;
            const uint32_t pg = (g * a + 127) / 255;
            const uint32_t pb = (b * a + 127) / 255;
            *dst++ = (a << 24) | (pr << 16) | (pg << 8) | pb;
            src += 4;
        }
    }
}

#endif
