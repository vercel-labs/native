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

/* The legacy host-wrapping fallback can impose an explicit line height or
 * resolve fallback faces whose metrics enlarge the line fragment. TextKit may
 * then place the first baseline somewhere other than round(font.ascender).
 * Build the layout once, translate that exact glyph range to the engine's
 * baseline, and draw through the same manager: measuring with NSLayoutManager
 * but drawing with NSString lets the two APIs choose different baselines for
 * fallback glyphs (for example a Geist run containing an emoji). */
static inline CGFloat NativeSdkAppKitDrawTextOnFirstBaseline(
    NSString *value,
    NSDictionary *attributes,
    NSFont *font,
    NSPoint engineBaseline,
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
    const CGFloat measuredOffset = NSMinY(lineFragment) + glyphLocation.y;
    /* A line height smaller than the font box legitimately moves TextKit's
     * first baseline above the container origin, producing a negative
     * offset. Preserve that answer: rejecting it would put compact runs back
     * on face-dependent ascenders and split their shared engine baseline. */
    const CGFloat offset = isfinite(measuredOffset) ? measuredOffset : fallback;
    const NSPoint containerOrigin = NSMakePoint(engineBaseline.x, engineBaseline.y - offset);
    [layoutManager drawGlyphsForGlyphRange:glyphRange atPoint:containerOrigin];
    return offset;
}

#endif
