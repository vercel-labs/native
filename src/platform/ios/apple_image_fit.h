#ifndef NATIVE_SDK_APPLE_IMAGE_FIT_H
#define NATIVE_SDK_APPLE_IMAGE_FIT_H

#include <math.h>
#include <stddef.h>

#define NATIVE_SDK_MAX_DECODED_IMAGE_DIMENSION 8192

/* ImageIO accepts a longest-side bound, then derives and rounds the other
 * side itself. Choose a longest side whose CEILING-rounded companion still
 * fits the caller's area budget, while also constraining pathological source
 * panoramas to the codec seam's decoded-axis ceiling. Keeping this in one C
 * header makes AppKit, CEF, and UIKit share exactly the same contract. */
static inline size_t native_sdk_apple_image_thumbnail_max_dimension(
    size_t width,
    size_t height,
    size_t max_pixels
) {
    const size_t major = width > height ? width : height;
    const size_t minor = width < height ? width : height;
    if (major == 0 || minor == 0 || max_pixels == 0) return 0;
    if (major <= max_pixels / minor && major <= NATIVE_SDK_MAX_DECODED_IMAGE_DIMENSION) return major;

    const double area_scale = sqrt((double)max_pixels / (double)major / (double)minor);
    const double axis_scale = (double)NATIVE_SDK_MAX_DECODED_IMAGE_DIMENSION / (double)major;
    const double scale = fmin(1.0, fmin(area_scale, axis_scale));
    size_t dimension = (size_t)floor((double)major * scale);
    if (dimension < 1) dimension = 1;
    if (dimension > NATIVE_SDK_MAX_DECODED_IMAGE_DIMENSION) dimension = NATIVE_SDK_MAX_DECODED_IMAGE_DIMENSION;
    while (dimension > 1) {
        const size_t minor_ceiling = (size_t)ceill((long double)minor * (long double)dimension / (long double)major);
        if (dimension <= max_pixels / minor_ceiling) break;
        dimension -= 1;
    }
    return dimension;
}

#endif
