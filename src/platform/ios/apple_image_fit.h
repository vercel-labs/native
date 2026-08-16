#ifndef NATIVE_SDK_APPLE_IMAGE_FIT_H
#define NATIVE_SDK_APPLE_IMAGE_FIT_H

#include <math.h>
#include <stddef.h>

/* ImageIO accepts a longest-side bound, then derives and rounds the other
 * side itself. Choose a longest side whose CEILING-rounded companion still
 * fits the caller's area budget. Keeping this in one C header makes AppKit,
 * CEF, and UIKit share exactly the same rounding contract. */
static inline size_t native_sdk_apple_image_thumbnail_max_dimension(
    size_t width,
    size_t height,
    size_t max_pixels
) {
    const size_t major = width > height ? width : height;
    const size_t minor = width < height ? width : height;
    if (major == 0 || minor == 0 || max_pixels == 0) return 0;
    if (major <= max_pixels / minor) return major;

    const double scale = sqrt((double)max_pixels / ((double)major * (double)minor));
    size_t dimension = (size_t)floor((double)major * scale);
    if (dimension < 1) dimension = 1;
    while (dimension > 1) {
        const size_t minor_ceiling = (minor * dimension + major - 1) / major;
        if (dimension <= max_pixels / minor_ceiling) break;
        dimension -= 1;
    }
    return dimension;
}

#endif
