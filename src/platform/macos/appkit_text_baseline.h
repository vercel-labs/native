#ifndef NATIVE_SDK_APPKIT_TEXT_BASELINE_H
#define NATIVE_SDK_APPKIT_TEXT_BASELINE_H

#import <AppKit/AppKit.h>

#include <math.h>

/* NSString drawing in a flipped AppKit context takes the upper-left of a
 * line fragment, not a baseline. AppKit snaps the resolved face's ascent to
 * the point grid when it places that fragment's baseline, so reverse that
 * exact conversion. Point size is not a font metric: using it here puts two
 * faces with different ascenders on different baselines even when the engine
 * supplied one shared baseline. */
static inline CGFloat NativeSdkAppKitLineFragmentOriginY(NSFont *font, CGFloat baseline) {
    return baseline - round(font.ascender);
}

/* The legacy host-wrapping fallback can impose an explicit line height.
 * TextKit may then distribute extra leading around the first line, so its
 * baseline offset is not necessarily round(font.ascender). Ask the same
 * layout machinery drawWithRect: uses and translate its container so the
 * first baseline still lands on the engine's coordinate. */
static inline CGFloat NativeSdkAppKitFirstBaselineOffset(
    NSString *value,
    NSDictionary *attributes,
    NSFont *font,
    NSSize containerSize
) {
    const CGFloat fallback = round(font.ascender);
    if (value.length == 0 || containerSize.width <= 0 || containerSize.height <= 0) return fallback;

    NSTextStorage *storage = [[NSTextStorage alloc] initWithString:value attributes:attributes];
    NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
    layoutManager.usesFontLeading = YES;
    NSTextContainer *container = [[NSTextContainer alloc] initWithContainerSize:containerSize];
    container.lineFragmentPadding = 0;
    [storage addLayoutManager:layoutManager];
    [layoutManager addTextContainer:container];

    const NSRange glyphRange = [layoutManager glyphRangeForTextContainer:container];
    if (glyphRange.length == 0) return fallback;
    const NSUInteger firstGlyph = glyphRange.location;
    const NSRect lineFragment = [layoutManager lineFragmentRectForGlyphAtIndex:firstGlyph effectiveRange:NULL];
    const NSPoint glyphLocation = [layoutManager locationForGlyphAtIndex:firstGlyph];
    const CGFloat offset = NSMinY(lineFragment) + glyphLocation.y;
    return isfinite(offset) && offset >= 0 ? offset : fallback;
}

#endif
