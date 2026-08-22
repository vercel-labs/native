#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>

#include <stdint.h>
#include <stdlib.h>

#include "appkit_text_baseline.h"

typedef struct {
    int first;
    int last;
} NativeSdkTestInkRows;

static NSFont *NativeSdkTestFont(const uint8_t *bytes, size_t length, CGFloat size) {
    NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes length:length freeWhenDone:NO];
    CTFontDescriptorRef descriptor = CTFontManagerCreateFontDescriptorFromData((__bridge CFDataRef)data);
    if (!descriptor) return nil;
    CTFontRef coreTextFont = CTFontCreateWithFontDescriptor(descriptor, size, NULL);
    CFRelease(descriptor);
    return CFBridgingRelease(coreTextFont);
}

static NativeSdkTestInkRows NativeSdkTestDrawText(
    NSFont *font,
    CGFloat size,
    CGFloat baseline,
    BOOL corrected,
    BOOL wrapped
) {
    const size_t width = 96;
    const size_t height = 72;
    const size_t bytesPerRow = width * 4;
    uint8_t *pixels = calloc(height, bytesPerRow);
    if (!pixels) return (NativeSdkTestInkRows){ .first = -1, .last = -1 };
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        pixels,
        width,
        height,
        8,
        bytesPerRow,
        colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        free(pixels);
        return (NativeSdkTestInkRows){ .first = -1, .last = -1 };
    }

    /* Match appkit_host.m's packet bitmap and flipped NSGraphicsContext. */
    CGContextSetAllowsAntialiasing(context, true);
    CGContextSetShouldAntialias(context, true);
    CGContextTranslateCTM(context, 0, (CGFloat)height);
    CGContextScaleCTM(context, 1, -1);
    NSGraphicsContext *graphics = [NSGraphicsContext graphicsContextWithCGContext:context flipped:YES];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:graphics];

    NSMutableDictionary *attributes = [@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: NSColor.whiteColor,
    } mutableCopy];
    if (wrapped) {
        NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
        paragraph.minimumLineHeight = 20;
        paragraph.maximumLineHeight = 20;
        attributes[NSParagraphStyleAttributeName] = paragraph;
        const NSSize extent = NSMakeSize(80, 30);
        const CGFloat offset = corrected
            ? NativeSdkAppKitFirstBaselineOffset(@"H", attributes, font, extent)
            : size;
        [@"H" drawWithRect:NSMakeRect(8, baseline - offset, extent.width, extent.height)
                    options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                 attributes:attributes];
    } else {
        const CGFloat y = corrected
            ? NativeSdkAppKitLineFragmentOriginY(font, baseline)
            : baseline - size;
        [@"H" drawAtPoint:NSMakePoint(8, y) withAttributes:attributes];
    }

    [NSGraphicsContext restoreGraphicsState];
    CGContextRelease(context);

    NativeSdkTestInkRows rows = { .first = -1, .last = -1 };
    for (size_t row = 0; row < height; row++) {
        BOOL hasInk = NO;
        for (size_t column = 0; column < width; column++) {
            if (pixels[row * bytesPerRow + column * 4 + 3] != 0) {
                hasInk = YES;
                break;
            }
        }
        if (!hasInk) continue;
        if (rows.first < 0) rows.first = (int)row;
        rows.last = (int)row;
    }
    free(pixels);
    return rows;
}

/* Test-only AppKit pixel probe linked by build.zig, not by apps. The bundled
 * Geist fixtures have the same cap height but different vertical metrics at
 * 14.5pt, making them a hermetic regression for mixed-face baselines. */
int native_sdk_test_appkit_text_baselines(
    const uint8_t *regularBytes,
    size_t regularLength,
    const uint8_t *monoBytes,
    size_t monoLength,
    double size,
    double baseline,
    double *outRegularOffset,
    double *outMonoOffset,
    int *outOldRegularFirst,
    int *outOldMonoFirst,
    int *outFixedRegularFirst,
    int *outFixedMonoFirst,
    int *outWrappedRegularFirst,
    int *outWrappedMonoFirst
) {
    @autoreleasepool {
        NSFont *regular = NativeSdkTestFont(regularBytes, regularLength, size);
        NSFont *mono = NativeSdkTestFont(monoBytes, monoLength, size);
        if (!regular || !mono) return 0;

        const NativeSdkTestInkRows oldRegular = NativeSdkTestDrawText(regular, size, baseline, NO, NO);
        const NativeSdkTestInkRows oldMono = NativeSdkTestDrawText(mono, size, baseline, NO, NO);
        const NativeSdkTestInkRows fixedRegular = NativeSdkTestDrawText(regular, size, baseline, YES, NO);
        const NativeSdkTestInkRows fixedMono = NativeSdkTestDrawText(mono, size, baseline, YES, NO);
        const NativeSdkTestInkRows wrappedRegular = NativeSdkTestDrawText(regular, size, baseline, YES, YES);
        const NativeSdkTestInkRows wrappedMono = NativeSdkTestDrawText(mono, size, baseline, YES, YES);

        if (outRegularOffset) *outRegularOffset = round(regular.ascender);
        if (outMonoOffset) *outMonoOffset = round(mono.ascender);
        if (outOldRegularFirst) *outOldRegularFirst = oldRegular.first;
        if (outOldMonoFirst) *outOldMonoFirst = oldMono.first;
        if (outFixedRegularFirst) *outFixedRegularFirst = fixedRegular.first;
        if (outFixedMonoFirst) *outFixedMonoFirst = fixedMono.first;
        if (outWrappedRegularFirst) *outWrappedRegularFirst = wrappedRegular.first;
        if (outWrappedMonoFirst) *outWrappedMonoFirst = wrappedMono.first;

        return oldRegular.first >= 0 && oldMono.first >= 0 && oldRegular.first != oldMono.first &&
            fixedRegular.first == fixedMono.first && fixedRegular.last == fixedMono.last &&
            wrappedRegular.first == wrappedMono.first && wrappedRegular.last == wrappedMono.last &&
            fixedRegular.first == wrappedRegular.first && fixedRegular.last == wrappedRegular.last;
    }
}
