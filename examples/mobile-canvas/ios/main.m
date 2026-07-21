// Minimal iOS shim for a native-sdk mobile canvas static library.
//
// M2 (presentation): mirrors the macOS raster path in
// src/platform/macos/appkit_host.m — the embed host renders the retained
// scene through the CPU reference renderer (`native_sdk_app_render_pixels`,
// RGBA8); the shim uploads those bytes to a shared MTLTexture and
// blit-copies them to the CAMetalLayer drawable. A CADisplayLink pumps
// `native_sdk_app_frame` and the canvas revision from
// `native_sdk_app_gpu_frame_state` gates re-renders, so unchanged frames
// cost one ABI call and no upload. The RGBA -> BGRA swizzle happens on the
// CPU while filling the staging buffer (blit copies require matching pixel
// formats).
//
// M3 (input): UITouch sequences forward through the ABI touch/scroll
// exports in the same point coordinate space the viewport export
// established (view points; the render scale multiplies pixels, not input).
// A touch-slop state machine mirrors UIScrollView's delayed content
// touches: an under-slop touch is a tap (pointer_down + pointer_up), an
// over-slop move over a scrollable widget pans it through the existing
// scroll reconciliation (`native_sdk_app_scroll` wheel deltas), and an
// over-slop move elsewhere becomes pointer_down + pointer_drag so sliders
// and text selection keep desktop semantics. Long-press is not modeled by
// the embed ABI, so the shim does not synthesize one.
//
// The platform keyboard keys off `native_sdk_app_text_input_state`: while
// an editable text widget owns focus the canvas view holds UIKit first
// responder (system keyboard up); when focus leaves it resigns (keyboard
// down). Typed characters flow through `native_sdk_app_text` and marked
// text (UITextInput composition, dead keys, CJK) maps onto the same
// `native_sdk_app_ime` set/commit/cancel path the macOS host drives from
// NSTextInputClient — see appkit_host.m setMarkedText:/insertText:.
//
// M5 (text metrics): the shim registers a CoreText-backed measure callback
// (`native_sdk_app_set_text_measure`) before start, mirroring the macOS
// host's `native_sdk_appkit_measure_text` — layout then uses real
// typographic widths instead of the deterministic estimator. Glyph
// RENDERING stays the reference renderer's shapes; only measurement
// changes. Launch with --estimator-text-metrics to keep the estimator
// (before/after comparisons, deterministic goldens).

#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdlib.h>

#include "native_sdk_app.h"

// Zig's std.debug stack-trace symbolication (pulled in by the embed lib's
// panic path) references `_dyld_get_image_header_containing_address`, which
// the iOS SDK marks __API_UNAVAILABLE(ios). Provide the documented
// replacement (dladdr) under the old symbol so the static lib links; it
// only runs while formatting a panic trace.
const struct mach_header *_dyld_get_image_header_containing_address(const void *address) {
    Dl_info info;
    if (dladdr(address, &info) != 0 && info.dli_fbase != NULL) {
        return (const struct mach_header *)info.dli_fbase;
    }
    return NULL;
}

// ------------------------------------------------------------ text metrics

// Italicizes a resolved sans face for the reserved italic span font ids
// (5 and 6) — the iOS mirror of appkit_host.m's NativeSdkItalicSansFont.
// Prefers a real italic face from the same family via font descriptor
// traits (SF has one; Geist does not ship a sans italic) and falls back to
// a sheared descriptor matrix so a future draw path slants visibly. The
// shear leaves advance widths unchanged, so measurement matches the
// upright face either way.
static UIFont *NativeSdkItalicSansFont(UIFont *font) {
    if (!font) return nil;
    UIFontDescriptor *italic = [font.fontDescriptor fontDescriptorWithSymbolicTraits:
        (font.fontDescriptor.symbolicTraits | UIFontDescriptorTraitItalic)];
    if (italic) {
        UIFont *converted = [UIFont fontWithDescriptor:italic size:font.pointSize];
        if (converted && (converted.fontDescriptor.symbolicTraits & UIFontDescriptorTraitItalic) != 0) return converted;
    }
    UIFontDescriptor *oblique = [font.fontDescriptor fontDescriptorWithMatrix:CGAffineTransformMake(1, 0, 0.2, 1, 0, 0)];
    UIFont *sheared = oblique ? [UIFont fontWithDescriptor:oblique size:font.pointSize] : nil;
    return sheared ?: font;
}

// Resolves the weighted sans faces behind the reserved span font ids 3
// (medium) and 4/6 (bold) — the iOS mirror of appkit_host.m's
// NativeSdkWeightedSansFont: explicit weighted candidate names first
// (Geist Medium / Geist Bold when bundled), then the matching SF weight.
// Never answers with the regular face, so weighted span ids always measure
// (and will draw) heavier than regular.
static UIFont *NativeSdkWeightedSansFont(NSArray<NSString *> *names, UIFontWeight systemWeight, CGFloat size) {
    for (NSString *name in names) {
        UIFont *font = [UIFont fontWithName:name size:size];
        if (font) return font;
    }
    return [UIFont systemFontOfSize:size weight:systemWeight];
}

// Resolves a canvas font id to the UIFont measurement uses — the iOS
// mirror of appkit_host.m's NativeSdkFontForFontId (Geist when bundled,
// system fonts otherwise). Ids 3-6 are the reserved sans span variants
// (medium, bold, italic, bold italic); everything else keeps the regular
// sans/mono candidates. Resolved fonts are cached per (font id, size).
static UIFont *NativeSdkFontForFontId(uint64_t value, CGFloat size) {
    static NSCache<NSString *, UIFont *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 256;
    });
    NSString *key = [NSString stringWithFormat:@"%llu/%.3f", (unsigned long long)value, (double)size];
    UIFont *cached = [cache objectForKey:key];
    if (cached) return cached;
    UIFont *font = nil;
    if (value == 2) {
        NSArray<NSString *> *candidates = @[ @"Geist Mono", @"GeistMono-Regular", @"Geist Mono Regular" ];
        for (NSString *name in candidates) {
            font = [UIFont fontWithName:name size:size];
            if (font) break;
        }
        if (!font) font = [UIFont monospacedSystemFontOfSize:size weight:UIFontWeightRegular];
    } else {
        NSArray<NSString *> *candidates = @[ @"Geist", @"Geist-Regular", @"Geist Sans", @"Geist Sans Regular" ];
        UIFont *base = nil;
        for (NSString *name in candidates) {
            base = [UIFont fontWithName:name size:size];
            if (base) break;
        }
        if (!base) base = [UIFont systemFontOfSize:size];
        switch (value) {
        case 3:
            font = NativeSdkWeightedSansFont(@[ @"Geist-Medium", @"Geist Medium" ], UIFontWeightMedium, size);
            break;
        case 4:
            font = NativeSdkWeightedSansFont(@[ @"Geist-Bold", @"Geist Bold" ], UIFontWeightBold, size);
            break;
        case 5:
            font = NativeSdkItalicSansFont(base);
            break;
        case 6:
            font = NativeSdkItalicSansFont(NativeSdkWeightedSansFont(@[ @"Geist-Bold", @"Geist Bold" ], UIFontWeightBold, size));
            break;
        default:
            font = base;
            break;
        }
    }
    if (font) [cache setObject:font forKey:key];
    return font;
}

// CoreText-backed measure callback registered over the embed ABI: the
// typographic width of a single-line run, measured with the same font
// resolution and string-attribute metrics ([NSString sizeWithAttributes:])
// the macOS packet renderer draws with. Returns a negative value when the
// bytes are not valid UTF-8 so layout falls back to its estimator. Shaped
// widths are memoized shim-side.
static double NativeSdkMeasureText(void *context, uint64_t font_id, double size, const char *text, uintptr_t text_len) {
    (void)context;
    if (!text || text_len == 0) return 0;
    CGFloat clamped = MAX(1, size);
    @autoreleasepool {
        NSString *value = [[NSString alloc] initWithBytes:text length:text_len encoding:NSUTF8StringEncoding];
        if (!value) return -1;
        static NSCache<NSString *, NSNumber *> *widthCache = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            widthCache = [[NSCache alloc] init];
            widthCache.countLimit = 16384;
        });
        NSString *key = [NSString stringWithFormat:@"%llu/%.3f/%@", (unsigned long long)font_id, (double)clamped, value];
        NSNumber *cached = [widthCache objectForKey:key];
        if (cached) return cached.doubleValue;
        UIFont *font = NativeSdkFontForFontId(font_id, clamped);
        if (!font) return -1;
        double width = [value sizeWithAttributes:@{ NSFontAttributeName : font }].width;
        [widthCache setObject:@(width) forKey:key];
        return width;
    }
}

// ---------------------------------------------------------------- UITextInput
// Index-based position/range objects over the local marked-text store (the
// "document" the system IME edits is the composition only, matching the
// macOS host's NSTextInputClient implementation).

@interface NativeSdkTextPosition : UITextPosition
@property(nonatomic) NSInteger index;
+ (instancetype)positionWithIndex:(NSInteger)index;
@end

@implementation NativeSdkTextPosition
+ (instancetype)positionWithIndex:(NSInteger)index {
    NativeSdkTextPosition *position = [[self alloc] init];
    position.index = index;
    return position;
}
@end

@interface NativeSdkTextRange : UITextRange
@property(nonatomic) NSInteger location;
@property(nonatomic) NSInteger length;
+ (instancetype)rangeWithLocation:(NSInteger)location length:(NSInteger)length;
@end

@implementation NativeSdkTextRange
+ (instancetype)rangeWithLocation:(NSInteger)location length:(NSInteger)length {
    NativeSdkTextRange *range = [[self alloc] init];
    range.location = location;
    range.length = length;
    return range;
}
- (BOOL)isEmpty {
    return self.length == 0;
}
- (UITextPosition *)start {
    return [NativeSdkTextPosition positionWithIndex:self.location];
}
- (UITextPosition *)end {
    return [NativeSdkTextPosition positionWithIndex:self.location + self.length];
}
@end

typedef NS_ENUM(NSInteger, NativeSdkTouchMode) {
    NativeSdkTouchModeIdle = 0,
    // Touch down seen, under slop: undecided between tap / drag / scroll.
    NativeSdkTouchModePending,
    // Over slop on a scrollable widget: forwarding wheel scroll deltas.
    NativeSdkTouchModeScrolling,
    // Over slop elsewhere: forwarded pointer_down, forwarding pointer_drag.
    NativeSdkTouchModeDragging,
};

static const CGFloat NativeSdkTouchSlop = 8.0;

@interface NativeSdkCanvasView : UIView <UIKeyInput, UITextInput>
@property(nonatomic) void *nativeApp;
@property(nonatomic, weak) UITouch *trackedTouch;
@property(nonatomic) NativeSdkTouchMode touchMode;
@property(nonatomic) CGPoint touchStartPoint;
@property(nonatomic) CGPoint touchLastPoint;
@property(nonatomic) uint64_t touchSequence;
@property(nonatomic, copy) NSString *markedText;
@property(nonatomic) NSRange markedSelectedRange;
@property(nonatomic) uint64_t focusedTextWidget;
@property(nonatomic, copy) NSDictionary<NSAttributedStringKey, id> *markedTextStyle;
@property(nonatomic, weak) id<UITextInputDelegate> inputDelegate;
@end

@implementation NativeSdkCanvasView

+ (Class)layerClass {
    return [CAMetalLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _markedText = @"";
        _markedSelectedRange = NSMakeRange(NSNotFound, 0);
        self.multipleTouchEnabled = NO;
    }
    return self;
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

// ------------------------------------------------------------------- touch

- (void)forwardTouchPhase:(int)phase point:(CGPoint)point pressure:(float)pressure {
    if (!self.nativeApp) return;
    native_sdk_app_touch(self.nativeApp, self.touchSequence, phase, (float)point.x, (float)point.y, pressure);
}

// True when an overflowing scrollable widget's bounds contain the point —
// the pan-to-scroll decision UIScrollView makes with delayed content
// touches, taken from the semantics export instead of a native hierarchy.
- (BOOL)scrollableWidgetAtPoint:(CGPoint)point {
    if (!self.nativeApp) return NO;
    uintptr_t count = native_sdk_app_widget_semantics_count(self.nativeApp);
    for (uintptr_t index = 0; index < count; index++) {
        native_sdk_widget_semantics_t node = {0};
        if (native_sdk_app_widget_semantics_at(self.nativeApp, index, &node) != 1) continue;
        if (!node.has_scroll) continue;
        if (node.scroll_content_extent <= node.scroll_viewport_extent) continue;
        if (point.x < node.x || point.x > node.x + node.width) continue;
        if (point.y < node.y || point.y > node.y + node.height) continue;
        return YES;
    }
    return NO;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.trackedTouch) return;
    UITouch *touch = touches.anyObject;
    self.trackedTouch = touch;
    self.touchSequence += 1;
    self.touchMode = NativeSdkTouchModePending;
    self.touchStartPoint = [touch locationInView:self];
    self.touchLastPoint = self.touchStartPoint;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!self.trackedTouch || ![touches containsObject:self.trackedTouch]) return;
    CGPoint point = [self.trackedTouch locationInView:self];

    if (self.touchMode == NativeSdkTouchModePending) {
        CGFloat dx = point.x - self.touchStartPoint.x;
        CGFloat dy = point.y - self.touchStartPoint.y;
        if (dx * dx + dy * dy < NativeSdkTouchSlop * NativeSdkTouchSlop) return;
        if ([self scrollableWidgetAtPoint:self.touchStartPoint]) {
            self.touchMode = NativeSdkTouchModeScrolling;
        } else {
            self.touchMode = NativeSdkTouchModeDragging;
            [self forwardTouchPhase:NATIVE_SDK_TOUCH_PHASE_DOWN point:self.touchStartPoint pressure:1];
        }
    }

    if (self.touchMode == NativeSdkTouchModeScrolling) {
        // Natural scrolling: finger up moves content up = offset grows, so
        // the wheel delta is the negated finger delta.
        float deltaX = (float)(self.touchLastPoint.x - point.x);
        float deltaY = (float)(self.touchLastPoint.y - point.y);
        if (self.nativeApp && (deltaX != 0 || deltaY != 0)) {
            native_sdk_app_scroll(self.nativeApp, self.touchSequence, (float)point.x, (float)point.y, deltaX, deltaY);
        }
    } else if (self.touchMode == NativeSdkTouchModeDragging) {
        [self forwardTouchPhase:NATIVE_SDK_TOUCH_PHASE_DRAG point:point pressure:1];
    }
    self.touchLastPoint = point;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!self.trackedTouch || ![touches containsObject:self.trackedTouch]) return;
    CGPoint point = [self.trackedTouch locationInView:self];
    switch (self.touchMode) {
        case NativeSdkTouchModePending:
            // Under-slop touch: a tap at the start point.
            [self forwardTouchPhase:NATIVE_SDK_TOUCH_PHASE_DOWN point:self.touchStartPoint pressure:1];
            [self forwardTouchPhase:NATIVE_SDK_TOUCH_PHASE_UP point:self.touchStartPoint pressure:0];
            break;
        case NativeSdkTouchModeDragging:
            [self forwardTouchPhase:NATIVE_SDK_TOUCH_PHASE_UP point:point pressure:0];
            break;
        default:
            break;
    }
    [self resetTouchTracking];
    [self syncTextInput];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!self.trackedTouch || ![touches containsObject:self.trackedTouch]) return;
    if (self.touchMode == NativeSdkTouchModeDragging) {
        [self forwardTouchPhase:NATIVE_SDK_TOUCH_PHASE_CANCEL point:self.touchLastPoint pressure:0];
    }
    [self resetTouchTracking];
    [self syncTextInput];
}

- (void)resetTouchTracking {
    self.trackedTouch = nil;
    self.touchMode = NativeSdkTouchModeIdle;
}

// ------------------------------------------------- keyboard <-> focus sync

// Reconcile UIKit first responder with the runtime's focus/IME-intent
// state: keyboard up while an editable text widget owns focus, down when
// focus leaves. Called after every dispatched input and once per display
// tick (focus can also move from key handling or model updates).
- (void)syncTextInput {
    if (!self.nativeApp || !self.window) return;
    native_sdk_text_input_state_t state = {0};
    if (native_sdk_app_text_input_state(self.nativeApp, &state) != 1) return;
    if (state.active) {
        if (state.widget_id != self.focusedTextWidget) {
            self.focusedTextWidget = state.widget_id;
            [self clearMarkedTextState];
        }
        if (!self.isFirstResponder) [self becomeFirstResponder];
    } else {
        self.focusedTextWidget = 0;
        if (self.isFirstResponder) {
            [self clearMarkedTextState];
            [self resignFirstResponder];
        }
    }
}

- (void)clearMarkedTextState {
    self.markedText = @"";
    self.markedSelectedRange = NSMakeRange(NSNotFound, 0);
}

- (void)emitKeyDownUp:(NSString *)key {
    if (!self.nativeApp) return;
    const char *bytes = key.UTF8String ?: "";
    uintptr_t length = [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    native_sdk_app_key(self.nativeApp, NATIVE_SDK_KEY_PHASE_DOWN, bytes, length, "", 0, 0);
    native_sdk_app_key(self.nativeApp, NATIVE_SDK_KEY_PHASE_UP, bytes, length, "", 0, 0);
}

- (void)emitImeEvent:(int)kind text:(NSString *)text cursor:(intptr_t)cursor {
    if (!self.nativeApp) return;
    NSString *value = text ?: @"";
    native_sdk_app_ime(self.nativeApp,
                        kind,
                        value.UTF8String ?: "",
                        [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                        cursor);
}

// -------------------------------------------------------------- UIKeyInput

- (BOOL)hasText {
    if (!self.nativeApp || self.focusedTextWidget == 0) return self.markedText.length > 0;
    native_sdk_widget_semantics_t node = {0};
    if (native_sdk_app_widget_semantics_by_id(self.nativeApp, self.focusedTextWidget, &node) != 1) return NO;
    return node.text_len > 0;
}

// Mirrors appkit_host.m insertText: committing identical marked text maps
// to commit_composition; divergent marked text cancels before the plain
// text insert so the runtime never double-applies the composition.
- (void)insertText:(NSString *)text {
    if (text.length == 0) return;
    if ([text isEqualToString:@"\n"]) {
        BOOL hadMarkedText = self.markedText.length > 0;
        [self clearMarkedTextState];
        if (hadMarkedText) {
            [self emitImeEvent:NATIVE_SDK_IME_COMMIT_COMPOSITION text:@"" cursor:-1];
        }
        [self emitKeyDownUp:@"enter"];
        [self syncTextInput];
        return;
    }

    BOOL hadMarkedText = self.markedText.length > 0;
    NSString *previousMarkedText = self.markedText;
    [self clearMarkedTextState];

    if (hadMarkedText && [previousMarkedText isEqualToString:text]) {
        [self emitImeEvent:NATIVE_SDK_IME_COMMIT_COMPOSITION text:@"" cursor:-1];
        return;
    }
    if (hadMarkedText) {
        [self emitImeEvent:NATIVE_SDK_IME_CANCEL_COMPOSITION text:@"" cursor:-1];
    }
    if (self.nativeApp) {
        native_sdk_app_text(self.nativeApp,
                             text.UTF8String ?: "",
                             [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    }
}

- (void)deleteBackward {
    if (self.markedText.length > 0) {
        [self clearMarkedTextState];
        [self emitImeEvent:NATIVE_SDK_IME_CANCEL_COMPOSITION text:@"" cursor:-1];
        return;
    }
    [self emitKeyDownUp:@"backspace"];
}

// ------------------------------------------------------------- UITextInput

- (NSString *)textInRange:(UITextRange *)range {
    NativeSdkTextRange *value = (NativeSdkTextRange *)range;
    if (!value || value.location < 0) return @"";
    NSInteger max = (NSInteger)self.markedText.length;
    NSInteger location = MIN(value.location, max);
    NSInteger length = MIN(value.length, max - location);
    return [self.markedText substringWithRange:NSMakeRange(location, length)];
}

- (void)replaceRange:(UITextRange *)range withText:(NSString *)text {
    (void)range;
    [self insertText:text];
}

- (UITextRange *)selectedTextRange {
    NSInteger caret = (NSInteger)self.markedText.length;
    if (self.markedSelectedRange.location != NSNotFound) {
        caret = MIN((NSInteger)(self.markedSelectedRange.location + self.markedSelectedRange.length), caret);
    }
    return [NativeSdkTextRange rangeWithLocation:caret length:0];
}

- (void)setSelectedTextRange:(UITextRange *)range {
    NativeSdkTextRange *value = (NativeSdkTextRange *)range;
    if (!value) return;
    self.markedSelectedRange = NSMakeRange(MAX(0, value.location), MAX(0, value.length));
}

- (UITextRange *)markedTextRange {
    if (self.markedText.length == 0) return nil;
    return [NativeSdkTextRange rangeWithLocation:0 length:(NSInteger)self.markedText.length];
}

// Marked text is the live composition: forward it (with the caret as a
// UTF-8 byte offset) through the same set_composition path the desktop
// hosts use, so dead keys and multi-stage IMEs stay correct.
- (void)setMarkedText:(NSString *)markedText selectedRange:(NSRange)selectedRange {
    NSString *text = markedText ?: @"";
    BOOL hadMarkedText = self.markedText.length > 0;
    if (text.length == 0) {
        [self clearMarkedTextState];
        if (hadMarkedText) {
            [self emitImeEvent:NATIVE_SDK_IME_CANCEL_COMPOSITION text:@"" cursor:-1];
        }
        return;
    }

    NSUInteger cursor = text.length;
    if (selectedRange.location != NSNotFound) {
        cursor = MIN(text.length, selectedRange.location + selectedRange.length);
        self.markedSelectedRange = selectedRange;
    } else {
        self.markedSelectedRange = NSMakeRange(text.length, 0);
    }
    self.markedText = text;
    intptr_t cursorBytes = (intptr_t)[[text substringToIndex:cursor] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    [self emitImeEvent:NATIVE_SDK_IME_SET_COMPOSITION text:text cursor:cursorBytes];
}

- (void)unmarkText {
    BOOL hadMarkedText = self.markedText.length > 0;
    [self clearMarkedTextState];
    if (hadMarkedText) {
        [self emitImeEvent:NATIVE_SDK_IME_COMMIT_COMPOSITION text:@"" cursor:-1];
    }
}

- (UITextPosition *)beginningOfDocument {
    return [NativeSdkTextPosition positionWithIndex:0];
}

- (UITextPosition *)endOfDocument {
    return [NativeSdkTextPosition positionWithIndex:(NSInteger)self.markedText.length];
}

- (UITextRange *)textRangeFromPosition:(UITextPosition *)fromPosition toPosition:(UITextPosition *)toPosition {
    NSInteger from = ((NativeSdkTextPosition *)fromPosition).index;
    NSInteger to = ((NativeSdkTextPosition *)toPosition).index;
    return [NativeSdkTextRange rangeWithLocation:MIN(from, to) length:ABS(to - from)];
}

- (UITextPosition *)positionFromPosition:(UITextPosition *)position offset:(NSInteger)offset {
    NSInteger index = ((NativeSdkTextPosition *)position).index + offset;
    if (index < 0 || index > (NSInteger)self.markedText.length) return nil;
    return [NativeSdkTextPosition positionWithIndex:index];
}

- (UITextPosition *)positionFromPosition:(UITextPosition *)position inDirection:(UITextLayoutDirection)direction offset:(NSInteger)offset {
    NSInteger delta = (direction == UITextLayoutDirectionLeft || direction == UITextLayoutDirectionUp) ? -offset : offset;
    return [self positionFromPosition:position offset:delta];
}

- (NSComparisonResult)comparePosition:(UITextPosition *)position toPosition:(UITextPosition *)other {
    NSInteger a = ((NativeSdkTextPosition *)position).index;
    NSInteger b = ((NativeSdkTextPosition *)other).index;
    if (a < b) return NSOrderedAscending;
    if (a > b) return NSOrderedDescending;
    return NSOrderedSame;
}

- (NSInteger)offsetFromPosition:(UITextPosition *)fromPosition toPosition:(UITextPosition *)toPosition {
    return ((NativeSdkTextPosition *)toPosition).index - ((NativeSdkTextPosition *)fromPosition).index;
}

- (id<UITextInputTokenizer>)tokenizer {
    return [[UITextInputStringTokenizer alloc] initWithTextInput:self];
}

- (UITextPosition *)positionWithinRange:(UITextRange *)range farthestInDirection:(UITextLayoutDirection)direction {
    if (direction == UITextLayoutDirectionLeft || direction == UITextLayoutDirectionUp) return range.start;
    return range.end;
}

- (UITextRange *)characterRangeByExtendingPosition:(UITextPosition *)position inDirection:(UITextLayoutDirection)direction {
    NSInteger index = ((NativeSdkTextPosition *)position).index;
    if (direction == UITextLayoutDirectionLeft || direction == UITextLayoutDirectionUp) {
        return [NativeSdkTextRange rangeWithLocation:0 length:index];
    }
    return [NativeSdkTextRange rangeWithLocation:index length:(NSInteger)self.markedText.length - index];
}

- (NSWritingDirection)baseWritingDirectionForPosition:(UITextPosition *)position inDirection:(UITextStorageDirection)direction {
    (void)position;
    (void)direction;
    return NSWritingDirectionNatural;
}

- (void)setBaseWritingDirection:(NSWritingDirection)writingDirection forRange:(UITextRange *)range {
    (void)writingDirection;
    (void)range;
}

- (CGRect)focusedWidgetRect {
    if (!self.nativeApp) return CGRectZero;
    native_sdk_text_input_state_t state = {0};
    if (native_sdk_app_text_input_state(self.nativeApp, &state) != 1 || !state.active) return CGRectZero;
    return CGRectMake(state.x, state.y, state.width, state.height);
}

- (CGRect)firstRectForRange:(UITextRange *)range {
    (void)range;
    CGRect rect = [self focusedWidgetRect];
    return CGRectIsEmpty(rect) ? self.bounds : rect;
}

- (CGRect)caretRectForPosition:(UITextPosition *)position {
    (void)position;
    CGRect rect = [self focusedWidgetRect];
    if (CGRectIsEmpty(rect)) return CGRectMake(0, 0, 2, 24);
    return CGRectMake(CGRectGetMaxX(rect) - 2, rect.origin.y, 2, rect.size.height);
}

- (NSArray<UITextSelectionRect *> *)selectionRectsForRange:(UITextRange *)range {
    (void)range;
    return @[];
}

- (UITextPosition *)closestPositionToPoint:(CGPoint)point {
    (void)point;
    return [self endOfDocument];
}

- (UITextPosition *)closestPositionToPoint:(CGPoint)point withinRange:(UITextRange *)range {
    (void)point;
    return range.end;
}

- (UITextRange *)characterRangeAtPoint:(CGPoint)point {
    (void)point;
    return nil;
}

// -------------------------------------------------------- UITextInputTraits
// Deterministic input for tests and desktop-parity text handling: the
// runtime owns editing behavior, so system rewriting stays off.

- (UITextAutocorrectionType)autocorrectionType {
    return UITextAutocorrectionTypeNo;
}

- (UITextSpellCheckingType)spellCheckingType {
    return UITextSpellCheckingTypeNo;
}

- (UITextSmartQuotesType)smartQuotesType {
    return UITextSmartQuotesTypeNo;
}

- (UITextSmartDashesType)smartDashesType {
    return UITextSmartDashesTypeNo;
}

- (UITextSmartInsertDeleteType)smartInsertDeleteType {
    return UITextSmartInsertDeleteTypeNo;
}

- (UITextAutocapitalizationType)autocapitalizationType {
    return UITextAutocapitalizationTypeNone;
}

@end

@interface NativeSdkCanvasViewController : UIViewController
@property(nonatomic) void *nativeApp;
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong) id<MTLTexture> canvasTexture;
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic) uint8_t *rgbaBytes;
@property(nonatomic) uint8_t *bgraBytes;
@property(nonatomic) size_t stagingCapacity;
@property(nonatomic) uint64_t lastCanvasRevision;
@property(nonatomic) BOOL hasPresentedRevision;
@property(nonatomic) BOOL needsPresent;
@property(nonatomic) CGFloat viewportScale;
@end

@implementation NativeSdkCanvasViewController

- (CAMetalLayer *)metalLayer {
    return (CAMetalLayer *)self.view.layer;
}

- (NativeSdkCanvasView *)canvasView {
    return (NativeSdkCanvasView *)self.view;
}

- (void)loadView {
    self.view = [[NativeSdkCanvasView alloc] init];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.device = MTLCreateSystemDefaultDevice();
    self.commandQueue = [self.device newCommandQueue];
    self.viewportScale = 1;

    CAMetalLayer *layer = [self metalLayer];
    layer.device = self.device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    // Blit destination: the drawable texture must stay CPU/blit-accessible.
    layer.framebufferOnly = NO;
    layer.opaque = YES;
    self.view.backgroundColor = [UIColor whiteColor];

    self.nativeApp = native_sdk_app_create();
    if (!self.nativeApp) {
        NSLog(@"native-sdk: native_sdk_app_create failed");
        return;
    }
    [self canvasView].nativeApp = self.nativeApp;

    // Real text metrics (M5): register the CoreText measure callback before
    // start so the installing layout already measures with the fonts
    // presentation would draw with. The estimator opt-out is a LAUNCH
    // ARGUMENT (simctl launch <udid> <bundle> --estimator-text-metrics),
    // not an environment variable: the simulator's launchd replays a
    // previous launch's SIMCTL_CHILD_* environment, so env toggles are not
    // deterministic across relaunches; process arguments are.
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--estimator-text-metrics"]) {
        NSLog(@"native-sdk: text measure disabled (estimator metrics)");
    } else {
        native_sdk_app_set_text_measure(self.nativeApp, NativeSdkMeasureText, NULL);
        [self logNativeErrorIfAny:@"text_measure"];
        NSLog(@"native-sdk: CoreText text measure registered");
    }

    // Verification harness: with NATIVE_SDK_AUTOMATION set (simctl launch
    // exports SIMCTL_CHILD_* into the app) the embedded runtime publishes
    // snapshot.txt into the app's data container, same protocol as the
    // desktop -Dautomation=true runners.
    if (getenv("NATIVE_SDK_AUTOMATION")) {
        NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"native-sdk-automation"];
        if (dir) {
            native_sdk_app_set_automation_dir(self.nativeApp,
                                               dir.UTF8String,
                                               [dir lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
            [self logNativeErrorIfAny:@"automation"];
            NSLog(@"native-sdk: automation dir %@", dir);
        }
    }

    native_sdk_app_start(self.nativeApp);
    native_sdk_app_activate(self.nativeApp);
    [self logNativeErrorIfAny:@"start"];

    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkTick:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)dealloc {
    [self.displayLink invalidate];
    if (self.nativeApp) {
        native_sdk_app_stop(self.nativeApp);
        native_sdk_app_destroy(self.nativeApp);
    }
    free(self.rgbaBytes);
    free(self.bgraBytes);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self pushViewport];
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self pushViewport];
}

// Report the view's size in points + contentScale + safe-area insets to the
// embed host (keyboard insets stay zero: IME is M3).
- (void)pushViewport {
    if (!self.nativeApp) return;
    CGSize size = self.view.bounds.size;
    if (size.width <= 0 || size.height <= 0) return;
    UIScreen *screen = self.view.window.screen ?: UIScreen.mainScreen;
    CGFloat scale = screen.scale > 0 ? screen.scale : 1;
    self.viewportScale = scale;
    [self metalLayer].contentsScale = scale;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    native_sdk_viewport_t viewport = {
        .width = (float)size.width,
        .height = (float)size.height,
        .scale = (float)scale,
        .surface = (__bridge void *)[self metalLayer],
        .safe_top = (float)safe.top,
        .safe_right = (float)safe.right,
        .safe_bottom = (float)safe.bottom,
        .safe_left = (float)safe.left,
    };
    native_sdk_app_viewport(self.nativeApp, &viewport);
    [self logNativeErrorIfAny:@"viewport"];
    self.needsPresent = YES;
}

- (void)displayLinkTick:(CADisplayLink *)link {
    if (!self.nativeApp) return;

    // Host-pumped frame: synthesizes the gpu_surface_frame event (first
    // tick installs the widget tree, later ticks re-present).
    native_sdk_app_frame(self.nativeApp);

    // Keyboard show/hide follows the runtime's focus state each tick, not
    // only after shim-forwarded input: focus can also move from keyboard
    // handling (tab/escape) or model updates.
    [[self canvasView] syncTextInput];

    // Only re-render + blit when the retained canvas actually changed.
    native_sdk_gpu_frame_state_t state = {0};
    BOOL haveState = native_sdk_app_gpu_frame_state(self.nativeApp, &state) == 1;
    if (!self.needsPresent && haveState && self.hasPresentedRevision &&
        state.canvas_revision == self.lastCanvasRevision) {
        return;
    }

    if ([self renderAndPresent]) {
        if (haveState) {
            self.lastCanvasRevision = state.canvas_revision;
            self.hasPresentedRevision = YES;
        }
        self.needsPresent = NO;
    }
}

- (BOOL)ensureStagingCapacity:(size_t)byteLength {
    if (self.stagingCapacity >= byteLength && self.rgbaBytes && self.bgraBytes) return YES;
    free(self.rgbaBytes);
    free(self.bgraBytes);
    self.rgbaBytes = malloc(byteLength);
    self.bgraBytes = malloc(byteLength);
    self.stagingCapacity = (self.rgbaBytes && self.bgraBytes) ? byteLength : 0;
    return self.stagingCapacity != 0;
}

- (BOOL)renderAndPresent {
    float scale = (float)self.viewportScale;

    native_sdk_canvas_pixels_t info = {0};
    if (native_sdk_app_render_pixel_size(self.nativeApp, scale, &info) != 1) return NO;
    if (info.width == 0 || info.height == 0 || info.byte_len != info.width * info.height * 4) return NO;
    if (![self ensureStagingCapacity:info.byte_len]) return NO;

    native_sdk_canvas_pixels_t rendered = {0};
    if (native_sdk_app_render_pixels(self.nativeApp, scale, self.rgbaBytes, info.byte_len, &rendered) != 1) {
        [self logNativeErrorIfAny:@"render_pixels"];
        return NO;
    }
    NSUInteger width = rendered.width;
    NSUInteger height = rendered.height;
    if (width == 0 || height == 0 || rendered.byte_len != width * height * 4) return NO;

    // RGBA8 (renderer) -> BGRA8 (drawable) swizzle into the upload buffer.
    const uint8_t *rgba = self.rgbaBytes;
    uint8_t *bgra = self.bgraBytes;
    size_t pixelCount = (size_t)width * (size_t)height;
    for (size_t i = 0; i < pixelCount; i++) {
        const size_t offset = i * 4;
        bgra[offset + 0] = rgba[offset + 2];
        bgra[offset + 1] = rgba[offset + 1];
        bgra[offset + 2] = rgba[offset + 0];
        bgra[offset + 3] = rgba[offset + 3];
    }

    if (!self.canvasTexture || self.canvasTexture.width != width || self.canvasTexture.height != height) {
        MTLTextureDescriptor *descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:width
                                                              height:height
                                                           mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModeShared;
        self.canvasTexture = [self.device newTextureWithDescriptor:descriptor];
    }
    if (!self.canvasTexture) return NO;
    [self.canvasTexture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                          mipmapLevel:0
                            withBytes:bgra
                          bytesPerRow:width * 4];

    CAMetalLayer *layer = [self metalLayer];
    layer.drawableSize = CGSizeMake(width, height);
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable) return NO;
    if (drawable.texture.width != width || drawable.texture.height != height) return NO;

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    [blit copyFromTexture:self.canvasTexture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(width, height, 1)
                toTexture:drawable.texture
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    return YES;
}

- (void)logNativeErrorIfAny:(NSString *)stage {
    const char *name = native_sdk_app_last_error_name(self.nativeApp);
    if (name && name[0] != '\0') {
        NSLog(@"native-sdk: %@ error %s", stage, name);
    }
}

@end

@interface NativeSdkAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation NativeSdkAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[NativeSdkCanvasViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([NativeSdkAppDelegate class]));
    }
}
