#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <stdint.h>
#include "../ios/apple_image_fit.h"

/* Test-only ImageIO probe linked by build.zig, not by apps. It exercises the
 * platform's real secondary-dimension rounding against the shared fit helper
 * without pulling the full AppKit host into the framework unit-test binary. */
int native_sdk_test_imageio_thumbnail_dimensions(
    const uint8_t *bytes,
    size_t bytes_len,
    size_t source_width,
    size_t source_height,
    size_t max_pixels,
    size_t *out_width,
    size_t *out_height
) {
    if (out_width) *out_width = 0;
    if (out_height) *out_height = 0;
    if (!bytes || bytes_len == 0) return 0;
    @autoreleasepool {
        NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes length:bytes_len freeWhenDone:NO];
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (!source) return 0;
        const size_t max_dimension = native_sdk_apple_image_thumbnail_max_dimension(
            source_width,
            source_height,
            max_pixels
        );
        NSDictionary *options = @{
            (NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
            (NSString *)kCGImageSourceThumbnailMaxPixelSize: @(max_dimension),
            (NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        };
        CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
        CFRelease(source);
        if (!image) return 0;
        if (out_width) *out_width = CGImageGetWidth(image);
        if (out_height) *out_height = CGImageGetHeight(image);
        CGImageRelease(image);
        return 1;
    }
}
