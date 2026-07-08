#import "appkit_host.h"

#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
/* Spectrum analysis of the app's own playback: MediaToolbox provides
 * the MTAudioProcessingTap that hands the player's PCM to the host, and
 * Accelerate (vDSP) provides the FFT that turns it into band
 * magnitudes. Both in-box system frameworks — no third-party DSP. */
#import <MediaToolbox/MediaToolbox.h>
#import <Accelerate/Accelerate.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <WebKit/WebKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <dispatch/dispatch.h>
#import <Security/Security.h>
#include <dlfcn.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

@class NativeSdkAppKitHost;

static const NSUInteger NativeSdkMaxChildWebViews = 16;
static const NSUInteger NativeSdkMaxNativeViews = 32;
static const NSInteger NativeSdkBridgeFrameKeepaliveFrames = 600;
static const uint64_t NativeSdkNanosecondsPerSecond = 1000000000ull;
static const uint32_t NativeSdkShortcutModifierPrimary = 1u << 0;
static const uint32_t NativeSdkShortcutModifierCommand = 1u << 1;
static const uint32_t NativeSdkShortcutModifierControl = 1u << 2;
static const uint32_t NativeSdkShortcutModifierOption = 1u << 3;
static const uint32_t NativeSdkShortcutModifierShift = 1u << 4;
static void *NativeSdkAppKitAppearanceObservationContext = &NativeSdkAppKitAppearanceObservationContext;
/* KVO contexts for the app's single audio player: the AVPlayerItem's
 * load status (readyToPlay -> the LOADED acknowledgment; failed -> one
 * FAILED event) and the AVPlayer's timeControlStatus (waiting-to-play
 * IS the honest buffering signal for streamed sources — the transport
 * is not paused, but no audio comes out until bytes arrive). */
static void *NativeSdkAppKitAudioItemStatusContext = &NativeSdkAppKitAudioItemStatusContext;
static void *NativeSdkAppKitAudioTimeControlContext = &NativeSdkAppKitAudioTimeControlContext;
/* Render-thread ring state for the spectrum tap; defined with the rest
 * of the spectrum machinery in the audio section below. */
typedef struct native_sdk_spectrum_tap_state native_sdk_spectrum_tap_state_t;
static NSRect constrainFrame(NSRect frame);
static NSString *NativeSdkAppKitBridgeScript(void);
static NSString *NativeSdkMimeTypeForPath(NSString *path);
static NSString *NativeSdkResolvedAssetRoot(NSString *rootPath);
static void NativeSdkRegisterBundledFonts(void);
static NSString *NativeSdkSafeAssetPath(NSURL *url, NSString *entryPath);
static NSURL *NativeSdkAssetEntryURL(NSString *origin, NSString *entryPath);
static NSArray<NSString *> *NativeSdkPolicyListFromBytes(const char *bytes, size_t len, NSArray<NSString *> *fallback);
static NSString *NativeSdkOriginForURL(NSURL *url);
static BOOL NativeSdkPolicyListMatches(NSArray<NSString *> *values, NSURL *url);
static NSString *NativeSdkShortcutKeyForEvent(NSEvent *event);
static BOOL NativeSdkShortcutUsesImplicitShift(NSString *key, NSEvent *event);
static BOOL NativeSdkShortcutModifiersMatch(uint32_t shortcutModifiers, NSEventModifierFlags eventModifiers, BOOL allowImplicitShift);
static NSEventModifierFlags NativeSdkMenuModifierFlags(uint32_t modifiers);
static uint32_t NativeSdkModifierFlagsForEvent(NSEvent *event);
static uint64_t NativeSdkTimestampNanoseconds(void);
static uint64_t NativeSdkRetainedFrameIntervalNanoseconds(NSScreen *screen);
static NSAccessibilityRole NativeSdkAccessibilityRoleForNativeViewKind(NSInteger kind);
static NSAccessibilityRole NativeSdkAccessibilityRoleForWidgetRole(NSInteger role);
static NSCursor *NativeSdkCursorForKind(NSInteger kind);
static NSRange NativeSdkClampedRange(NSUInteger start, NSUInteger end, NSUInteger length);
static NSString *NativeSdkSubstringForRange(NSString *value, NSRange range);
static NSString *NativeSdkStringFromTextInput(id value);
static int NativeSdkAppKitColorSchemeForAppearance(NSAppearance *appearance);
static BOOL NativeSdkAppKitReduceMotionEnabled(void);
static BOOL NativeSdkAppKitHighContrastEnabled(void);

static size_t NativeSdkOverflowSize(size_t buffer_len) {
    return buffer_len == SIZE_MAX ? SIZE_MAX : buffer_len + 1;
}

// Launch-to-glass lap (NATIVE_SDK_WINDOW_TIMING): REALTIME wall-clock so
// an external harness can difference stamps against a pre-spawn clock.
// Same format as the engine's `launch_timing` laps.
static void NativeSdkLaunchLap(const char *name) {
    if (!getenv("NATIVE_SDK_WINDOW_TIMING")) return;
    fprintf(stderr, "native-sdk: launch %s wall_ns=%llu\n", name, (unsigned long long)clock_gettime_nsec_np(CLOCK_REALTIME));
}

static NSString *NativeSdkStringFromBytes(const char *bytes, size_t len) {
    if (!bytes || len == 0) return nil;
    return [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
}

static NSString *NativeSdkStringFromTextInput(id value) {
    if (!value) return @"";
    if ([value isKindOfClass:[NSAttributedString class]]) return ((NSAttributedString *)value).string ?: @"";
    if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
    return [value description] ?: @"";
}

static int NativeSdkAppKitColorSchemeForAppearance(NSAppearance *appearance) {
    NSAppearance *effective = appearance ?: NSApp.effectiveAppearance;
    NSString *bestMatch = [effective bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    return [bestMatch isEqualToString:NSAppearanceNameDarkAqua] ? NATIVE_SDK_APPKIT_COLOR_SCHEME_DARK : NATIVE_SDK_APPKIT_COLOR_SCHEME_LIGHT;
}

static BOOL NativeSdkAppKitReduceMotionEnabled(void) {
    return [NSWorkspace sharedWorkspace].accessibilityDisplayShouldReduceMotion;
}

static BOOL NativeSdkAppKitHighContrastEnabled(void) {
    return [NSWorkspace sharedWorkspace].accessibilityDisplayShouldIncreaseContrast;
}

static uint64_t NativeSdkTimestampNanoseconds(void) {
    return (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000000000.0);
}

static uint64_t NativeSdkRetainedFrameIntervalNanoseconds(NSScreen *screen) {
    NSInteger framesPerSecond = screen ? screen.maximumFramesPerSecond : 0;
    if (framesPerSecond <= 0) framesPerSecond = 60;
    framesPerSecond = MAX(30, MIN(120, framesPerSecond));
    return NativeSdkNanosecondsPerSecond / (uint64_t)framesPerSecond;
}

/* Pacing interval for logical frame completions while the window is
 * OCCLUDED: a ~1 Hz heartbeat instead of the display grid. An occluded
 * window never presents (renderFrame's short-circuit), so display-grid
 * completions only make the engine rebuild its display list at full
 * refresh rate for glass nobody can see — a covered window playing
 * audio measured a sustained ~100% of one core, enough to trip the OS
 * CPU-usage watchdog. Stopping completions entirely would be worse:
 * anything riding the frame channel (on_frame-driven interpolation,
 * armed tweens) would freeze mid-flight and snap on de-occlusion. The
 * heartbeat keeps those models gently current — event-driven truth
 * (audio position reports, input) still flows at its own cadence — and
 * the first-present exemption and glass-flush machinery are untouched:
 * the throttle only engages after the first real present, and every
 * heartbeat completion still marks the glass flush pending. */
static const uint64_t NativeSdkOccludedFrameHeartbeatNs = 1000000000ull;

static uint32_t NativeSdkModifierFlagsForEvent(NSEvent *event) {
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    uint32_t modifiers = 0;
    if ((flags & NSEventModifierFlagCommand) != 0) {
        modifiers |= NativeSdkShortcutModifierPrimary;
        modifiers |= NativeSdkShortcutModifierCommand;
    }
    if ((flags & NSEventModifierFlagControl) != 0) modifiers |= NativeSdkShortcutModifierControl;
    if ((flags & NSEventModifierFlagOption) != 0) modifiers |= NativeSdkShortcutModifierOption;
    if ((flags & NSEventModifierFlagShift) != 0) modifiers |= NativeSdkShortcutModifierShift;
    return modifiers;
}

static NSString *NativeSdkPasteboardTypeForMime(const char *mime_type, size_t mime_type_len) {
    NSString *mime = NativeSdkStringFromBytes(mime_type, mime_type_len).lowercaseString;
    if ([mime isEqualToString:@"text"] || [mime isEqualToString:@"text/plain"]) return NSPasteboardTypeString;
    if ([mime isEqualToString:@"text/html"]) return NSPasteboardTypeHTML;
    if ([mime isEqualToString:@"text/rtf"] || [mime isEqualToString:@"application/rtf"]) return NSPasteboardTypeRTF;
    return nil;
}

static NSAccessibilityRole NativeSdkAccessibilityRoleForNativeViewKind(NSInteger kind) {
    switch (kind) {
        case NATIVE_SDK_APPKIT_VIEW_TOOLBAR:
        case NATIVE_SDK_APPKIT_VIEW_TITLEBAR_ACCESSORY:
            return NSAccessibilityToolbarRole;
        case NATIVE_SDK_APPKIT_VIEW_SPLIT:
            return NSAccessibilitySplitterRole;
        case NATIVE_SDK_APPKIT_VIEW_BUTTON:
        case NATIVE_SDK_APPKIT_VIEW_ICON_BUTTON:
        case NATIVE_SDK_APPKIT_VIEW_LIST_ITEM:
        case NATIVE_SDK_APPKIT_VIEW_TOGGLE:
            return NSAccessibilityButtonRole;
        case NATIVE_SDK_APPKIT_VIEW_CHECKBOX:
            return NSAccessibilityCheckBoxRole;
        case NATIVE_SDK_APPKIT_VIEW_SEGMENTED_CONTROL:
            return NSAccessibilityRadioGroupRole;
        case NATIVE_SDK_APPKIT_VIEW_TEXT_FIELD:
        case NATIVE_SDK_APPKIT_VIEW_SEARCH_FIELD:
            return NSAccessibilityTextFieldRole;
        case NATIVE_SDK_APPKIT_VIEW_LABEL:
            return NSAccessibilityStaticTextRole;
        case NATIVE_SDK_APPKIT_VIEW_PROGRESS_INDICATOR:
            return NSAccessibilityProgressIndicatorRole;
        case NATIVE_SDK_APPKIT_VIEW_GPU_SURFACE:
        case NATIVE_SDK_APPKIT_VIEW_STATUSBAR:
        case NATIVE_SDK_APPKIT_VIEW_SIDEBAR:
        case NATIVE_SDK_APPKIT_VIEW_STACK:
        case NATIVE_SDK_APPKIT_VIEW_SPACER:
            return NSAccessibilityGroupRole;
        default:
            return NSAccessibilityUnknownRole;
    }
}

static NSAccessibilityRole NativeSdkAccessibilityRoleForWidgetRole(NSInteger role) {
    switch (role) {
        case NATIVE_SDK_APPKIT_WIDGET_ROLE_TEXT:
            return NSAccessibilityStaticTextRole;
        case NATIVE_SDK_APPKIT_WIDGET_ROLE_IMAGE:
            return NSAccessibilityImageRole;
        case NATIVE_SDK_APPKIT_WIDGET_ROLE_BUTTON:
        case NATIVE_SDK_APPKIT_WIDGET_ROLE_TAB:
            return NSAccessibilityButtonRole;
        case NATIVE_SDK_APPKIT_WIDGET_ROLE_TEXTBOX:
            return NSAccessibilityTextFieldRole;
        case NATIVE_SDK_APPKIT_WIDGET_ROLE_CHECKBOX:
        case NATIVE_SDK_APPKIT_WIDGET_ROLE_SWITCH:
            return NSAccessibilityCheckBoxRole;
        case NATIVE_SDK_APPKIT_WIDGET_ROLE_RADIO:
            return NSAccessibilityRadioButtonRole;
        case NATIVE_SDK_APPKIT_WIDGET_ROLE_MENU:
            return NSAccessibilityMenuRole;
        case NATIVE_SDK_APPKIT_WIDGET_ROLE_MENUITEM:
            return NSAccessibilityMenuItemRole;
        case NATIVE_SDK_APPKIT_WIDGET_ROLE_LIST:
            return NSAccessibilityListRole;
        case NATIVE_SDK_APPKIT_WIDGET_ROLE_ROW:
            return NSAccessibilityRowRole;
        case NATIVE_SDK_APPKIT_WIDGET_ROLE_GRID:
            return NSAccessibilityTableRole;
        case NATIVE_SDK_APPKIT_WIDGET_ROLE_GRIDCELL:
            return NSAccessibilityCellRole;
        case NATIVE_SDK_APPKIT_WIDGET_ROLE_SLIDER:
            return NSAccessibilitySliderRole;
        case NATIVE_SDK_APPKIT_WIDGET_ROLE_PROGRESSBAR:
            return NSAccessibilityProgressIndicatorRole;
        case NATIVE_SDK_APPKIT_WIDGET_ROLE_TOOLTIP:
        case NATIVE_SDK_APPKIT_WIDGET_ROLE_DIALOG:
        case NATIVE_SDK_APPKIT_WIDGET_ROLE_GROUP:
        case NATIVE_SDK_APPKIT_WIDGET_ROLE_LISTITEM:
        case NATIVE_SDK_APPKIT_WIDGET_ROLE_NONE:
        default:
            return NSAccessibilityGroupRole;
    }
}

static NSCursor *NativeSdkCursorForKind(NSInteger kind) {
    switch (kind) {
        case NATIVE_SDK_APPKIT_CURSOR_POINTING_HAND: return [NSCursor pointingHandCursor];
        case NATIVE_SDK_APPKIT_CURSOR_TEXT: return [NSCursor IBeamCursor];
        case NATIVE_SDK_APPKIT_CURSOR_RESIZE_HORIZONTAL: return [NSCursor resizeLeftRightCursor];
        case NATIVE_SDK_APPKIT_CURSOR_ARROW:
        default:
            return [NSCursor arrowCursor];
    }
}

static NSRange NativeSdkClampedRange(NSUInteger start, NSUInteger end, NSUInteger length) {
    NSUInteger clampedStart = MIN(start, length);
    NSUInteger clampedEnd = MIN(end, length);
    if (clampedEnd < clampedStart) {
        NSUInteger temp = clampedStart;
        clampedStart = clampedEnd;
        clampedEnd = temp;
    }
    return NSMakeRange(clampedStart, clampedEnd - clampedStart);
}

static NSUInteger NativeSdkRangeEnd(NSRange range) {
    if (range.location == NSNotFound) return 0;
    if (range.length > NSUIntegerMax - range.location) return NSUIntegerMax;
    return range.location + range.length;
}

static NSString *NativeSdkSubstringForRange(NSString *value, NSRange range) {
    if (range.location > value.length || NSMaxRange(range) > value.length) return @"";
    return [value substringWithRange:range];
}

static NSMutableDictionary *NativeSdkCredentialQuery(NSString *service, NSString *account) {
    return [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account,
    } mutableCopy];
}

/// The chromeless (titlebarStyle 3) window class: a borderless NSWindow
/// refuses key/main status by default, which would leave a fully-skinned
/// app deaf to the keyboard — this subclass restores both. Used only for
/// chromeless windows; every other style keeps plain NSWindow.
@interface NativeSdkChromelessWindow : NSWindow
@end

@implementation NativeSdkChromelessWindow
- (BOOL)canBecomeKeyWindow {
    return YES;
}
- (BOOL)canBecomeMainWindow {
    return YES;
}
@end

@interface NativeSdkWindowDelegate : NSObject <NSWindowDelegate>
@property(nonatomic, assign) NativeSdkAppKitHost *host;
@property(nonatomic, assign) uint64_t windowId;
/// Set for tall-titlebar windows, whose delegate KVO-observes the
/// window's `contentLayoutRect` (chrome re-query timing) and must
/// unregister before the window closes.
@property(nonatomic, assign) BOOL observesContentLayout;
@end

@interface NativeSdkWebView : WKWebView <NSDraggingDestination>
@property(nonatomic, strong) NSArray<NSValue *> *coveredMouseRects;
@property(nonatomic, assign) NativeSdkAppKitHost *host;
@property(nonatomic, assign) uint64_t windowId;
@end

@interface NativeSdkBridgeScriptHandler : NSObject <WKScriptMessageHandler>
@property(nonatomic, assign) NativeSdkAppKitHost *host;
@property(nonatomic, assign) uint64_t windowId;
@property(nonatomic, strong) NSString *webViewLabel;
@end

@class NativeSdkMetalSurfaceView;

/* Flipped, hit-test-transparent document view for a native scroll driver:
 * flipped so the clip view's bounds origin y IS the canvas scroll offset
 * (0 = top, +y = scrolled down), transparent so canvas content beneath
 * stays clickable. */
@interface NativeSdkScrollDriverDocumentView : NSView
@end

/* An invisible NSScrollView owning input + physics for one scrollable
 * canvas region: the OS computes momentum, rubber-band, and draws
 * the overlay scroller; the engine renders the content. Hit testing
 * passes everything through except the scrollers themselves (so the
 * overlay knob stays grabbable). */
@interface NativeSdkScrollDriverView : NSScrollView
@property(nonatomic, assign) uint64_t driverId;
@end

/* Captures the selected item id of a context-menu popUp; NSMenuItem
 * targets are weak, so the presenter keeps this alive during tracking. */
@interface NativeSdkContextMenuTarget : NSObject
@property(nonatomic, assign) uint32_t selectedItemId;
- (void)contextMenuItemClicked:(NSMenuItem *)item;
@end

/* One cached command rasterization: the command's painted output at the
 * surface's backing scale, in a premultiplied RGBA8 image covering the
 * command's pixel-aligned bounds. `command` is the exact retained
 * dictionary instance the raster was produced from — cache validity is
 * pointer identity, which is airtight because decoded command
 * dictionaries are immutable and every content change arrives as a NEW
 * instance (patch upsert or baseline rebuild). */
@interface NativeSdkPacketCommandRaster : NSObject
@property(nonatomic, strong) NSDictionary *command;
@property(nonatomic, assign) CGImageRef image;
@property(nonatomic, assign) NSRect destination;
@property(nonatomic, assign) NSUInteger byteCount;
@property(nonatomic, assign) uint64_t lastUseTick;
/* GPU composite mode (NATIVE_SDK_GPU_COMPOSITE=1): the same premultiplied
 * raster bytes as a texture, plus the device-pixel destination, so the
 * composite pass draws the entry as one textured quad instead of a CPU
 * blit. Uploaded at fill time; released with the entry, so cache eviction
 * keeps CPU raster and GPU texture in sync by construction. */
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic, assign) NSUInteger pixelX;
@property(nonatomic, assign) NSUInteger pixelY;
@property(nonatomic, assign) NSUInteger pixelWidth;
@property(nonatomic, assign) NSUInteger pixelHeight;
@end

@implementation NativeSdkPacketCommandRaster
- (void)setImage:(CGImageRef)image {
    if (image) CGImageRetain(image);
    if (_image) CGImageRelease(_image);
    _image = image;
}
- (void)dealloc {
    if (_image) CGImageRelease(_image);
    _image = NULL;
}
@end

@interface NativeSdkWidgetAccessibilityElement : NSAccessibilityElement
@property(nonatomic, assign) NativeSdkMetalSurfaceView *surfaceView;
@property(nonatomic, assign) uint64_t widgetId;
@property(nonatomic, assign) uint32_t actionFlags;
- (BOOL)emitSetTextAccessibilityValue:(id)value;
- (BOOL)emitSetSelectionAccessibilityValue:(id)value;
@end

@interface NativeSdkMetalSurfaceView : NSView <NSTextInputClient>
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong) CAMetalLayer *metalLayer;
@property(nonatomic, strong) id<MTLBuffer> sampleBuffer;
@property(nonatomic, strong) id<MTLTexture> canvasTexture;
@property(nonatomic, strong) id<MTLRenderPipelineState> canvasRenderPipeline;
@property(nonatomic, strong) id<MTLSamplerState> canvasSampler;
@property(nonatomic, assign) CGColorSpaceRef canvasColorSpace;
@property(nonatomic, strong) NSTimer *displayTimer;
@property(nonatomic, assign) NativeSdkAppKitHost *host;
@property(nonatomic, assign) uint64_t windowId;
@property(nonatomic, strong) NSString *surfaceLabel;
@property(nonatomic, assign) NSUInteger frameIndex;
/* Whether this surface has completed at least one REAL present. Gates the
 * occluded short-circuit: until the first present lands, occluded frames
 * still render (surface establishment + the nonblank verdict). */
@property(nonatomic, assign) BOOL hasEverPresented;
@property(nonatomic, assign) BOOL renderedFrame;
@property(nonatomic, assign) BOOL verifiedNonblankFrame;
@property(nonatomic, assign) uint32_t lastSampleColor;
@property(nonatomic, assign) CGSize lastDrawableSize;
@property(nonatomic, assign) CGFloat lastScale;
@property(nonatomic, assign) NSUInteger canvasTextureWidth;
@property(nonatomic, assign) NSUInteger canvasTextureHeight;
@property(nonatomic, assign) BOOL hasCanvasTexture;
/// Queue flag for the pre-first-present immediate frame request only
/// (see requestRetainedCanvasFrame's textureless branch); every steady
/// state emission rides the single scheduler below instead.
@property(nonatomic, assign) BOOL retainedFrameRequestPending;
/// One-shot: the pre-first-present immediate frame request already fired
/// (see requestRetainedCanvasFrame) — later textureless requests drop
/// like they always did, so a persistently failing present can't spin
/// an unpaced request loop.
@property(nonatomic, assign) BOOL firstCanvasFrameRequestEmitted;
@property(nonatomic, assign) uint64_t retainedFrameLastEmitNs;
/* ONE frame-event scheduler per surface. Every producer that wants a
 * frame event — runtime frame requests (armed animations, widget
 * changes), GPU present completions, and occluded logical completions —
 * funnels through scheduleFrameEventEmission, which keeps at most one
 * emission in flight and fires it on the display-interval grid anchored
 * at retainedFrameLastEmitNs. Before this gate the request stream and
 * the completion stream each kept their own once-per-interval promise
 * against the shared clock, so an armed frame loop whose phases
 * interleaved delivered TWO events per interval (measured 3.7 ms/5.5 ms
 * alternation — ~215 Hz of re-renders on a 120 Hz panel), and under
 * main-thread load the two streams' serialized blocks re-based the
 * clock from completion time each cycle, stretching armed intervals
 * frame over frame instead of holding cadence. Producers landing while
 * an emission is queued fold into it: their facts (sample color,
 * nonblank, retained canvas state) are already view state by the time
 * the block fires, so the one event carries the freshest truth. */
@property(nonatomic, assign) BOOL frameEventEmissionScheduled;
/* Supersede token for the scheduled emission: a queued dispatch block
 * whose captured generation no longer matches is stale and must no-op.
 * Bumped on de-occlusion, where a heartbeat-paced emission (parked up
 * to a second out) is replaced by an immediate full-cadence one — the
 * dispatch source itself cannot be cancelled. */
@property(nonatomic, assign) NSUInteger frameEventEmissionGeneration;
/* One-shot: an input was dispatched to this surface and its responding
 * frame must not wait out the occluded heartbeat. Input is external
 * truth on its own cadence — automation drives covered windows
 * constantly — and the response present (the input-latency stamp's
 * endpoint) rides the next frame event, so a heartbeat-paced response
 * would bill up to a second of pacing policy to a ~16 ms engine
 * response. The flag survives until one emission fires; the armed
 * animation loop that follows returns to the heartbeat, so a covered
 * window's sustained spin stays impossible. */
@property(nonatomic, assign) BOOL inputDrivenFramePending;
/* Held while the frame channel is ARMED (an emission is scheduled and
 * each fired emission re-arms another): without it the OS is free to
 * app-nap the process mid-animation, and its timer coalescing stretches
 * the paced dispatch deadlines progressively — the measured decay from
 * 5 ms deltas toward ~75 ms over six frames of a background app's
 * 180 ms tween. The assertion begins with the first scheduled emission
 * and ends the moment an emission fires with no follow-up scheduled,
 * so an IDLE app holds nothing and keeps full app-nap batching. */
@property(nonatomic, strong) id<NSObject> frameChannelActivity;
@property(nonatomic, assign) BOOL glassFlushPending;
@property(nonatomic, assign) BOOL pointerMotionInputPending;
@property(nonatomic, assign) NSInteger pendingPointerMotionKind;
@property(nonatomic, assign) NSPoint pendingPointerMotionPoint;
@property(nonatomic, assign) NSInteger pendingPointerMotionButton;
@property(nonatomic, assign) uint32_t pendingPointerMotionModifiers;
@property(nonatomic, assign) uint64_t pendingPointerMotionTimestampNs;
@property(nonatomic, assign) uint64_t pointerMotionInputLastEmitNs;
@property(nonatomic, assign) BOOL scrollInputPending;
@property(nonatomic, assign) NSPoint pendingScrollPoint;
@property(nonatomic, assign) double pendingScrollDeltaX;
@property(nonatomic, assign) double pendingScrollDeltaY;
@property(nonatomic, assign) uint32_t pendingScrollModifiers;
@property(nonatomic, assign) uint64_t pendingScrollTimestampNs;
@property(nonatomic, assign) uint64_t scrollInputLastEmitNs;
@property(nonatomic, strong) NSMutableData *canvasPacketPixels;
@property(nonatomic, assign) NSUInteger canvasPacketPixelWidth;
@property(nonatomic, assign) NSUInteger canvasPacketPixelHeight;
/* The retained backing only serves scissored dirty updates while it
 * byte-matches what a full redraw of the retained list would produce. A
 * present that fails after mutating it (unsupported command mid-draw)
 * clears the flag, and every dirty update requires it — a corrupted
 * backing can never leak stale pixels around a later scissor. */
@property(nonatomic, assign) BOOL canvasPacketPixelsValid;
/* Per-command raster cache: rendered output keyed by the engine's retain
 * key, validated by command-dictionary identity, budgeted in bytes (LRU
 * eviction), and evicted alongside the retained list (patch evicts +
 * upserts drop entries; baseline rebuilds and scale/size changes wipe).
 * Both full passes and scissored dirty updates draw through it, so the
 * two paths stay pixel-identical by construction. */
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NativeSdkPacketCommandRaster *> *canvasCommandRasterCache;
@property(nonatomic, assign) NSUInteger canvasCommandRasterCacheBytes;
@property(nonatomic, assign) uint64_t canvasCommandRasterCacheTick;
@property(nonatomic, assign) CGFloat canvasCommandRasterCacheScale;
@property(nonatomic, assign) NSUInteger canvasCommandRasterCachePixelWidth;
@property(nonatomic, assign) NSUInteger canvasCommandRasterCachePixelHeight;
/* Per-pass draw attribution for NATIVE_SDK_GPU_DRAW_TRACE=1: commands
 * actually drawn (not scissor-culled), split into raster-cache blits,
 * fresh cache fills, and direct (uncacheable) draws, plus the time each
 * group cost. The timers only run while the trace env is set. */
@property(nonatomic, assign) NSUInteger canvasTraceDrawnCount;
@property(nonatomic, assign) NSUInteger canvasTraceCacheHitCount;
@property(nonatomic, assign) NSUInteger canvasTraceCacheFillCount;
@property(nonatomic, assign) NSUInteger canvasTraceDirectCount;
@property(nonatomic, assign) uint64_t canvasTraceCacheHitNs;
@property(nonatomic, assign) uint64_t canvasTraceCacheFillNs;
@property(nonatomic, assign) uint64_t canvasTraceDirectNs;
/* Incremental-verify scratch (NATIVE_SDK_GPU_VERIFY_INCREMENTAL=1): a full
 * redraw of the retained list is compared byte-for-byte against the
 * incrementally patched backing after every scissored dirty update. */
@property(nonatomic, strong) NSMutableData *canvasVerifyPixels;
@property(nonatomic, assign) uint64_t canvasVerifyCheckCount;
@property(nonatomic, assign) uint64_t canvasVerifyMismatchCount;
/* GPU composite mode (NATIVE_SDK_GPU_COMPOSITE=1) state: two pipeline
 * variants (source-over blend for command rasters, blend-off copy for
 * clears / opaque native quads / blur output), a 1x1 texture bound on
 * flat draws, and validity tracking for the render-target canvas
 * texture (the retained GPU baseline the way canvasPacketPixelsValid
 * guards the CPU backing). */
@property(nonatomic, strong) id<MTLRenderPipelineState> canvasCompositeBlendPipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> canvasCompositeOpaquePipeline;
@property(nonatomic, strong) id<MTLTexture> canvasCompositeFlatTexture;
@property(nonatomic, assign) BOOL canvasTextureRenderable;
@property(nonatomic, assign) BOOL canvasCompositeContentValid;
@property(nonatomic, strong) id<MTLCommandBuffer> canvasCompositeLastCommandBuffer;
@property(nonatomic, strong) id<MTLTexture> canvasCompositeVerifyTexture;
/* Per-frame scratch quads (animated/over-budget commands) reuse pooled
 * textures keyed by retain key — their bytes are fully re-uploaded every
 * use, so only capacity matters; allocating per frame measurably taxed
 * the steady-state pulse. Wiped with the raster cache. */
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, id<MTLTexture>> *canvasCompositeScratchTextures;
@property(nonatomic, assign) NSUInteger canvasCompositePresentCount;
@property(nonatomic, assign) NSUInteger canvasTraceQuadCount;
@property(nonatomic, assign) NSUInteger canvasTraceBindCount;
@property(nonatomic, assign) uint64_t canvasCompareCheckCount;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *canvasImageCache;
/* Retained command display list for incremental (`patch`) presents:
 * decoded command dictionaries keyed by the engine's retain key, plus the
 * draw-order vector and the generation of the full present that built
 * them. `hasCanvasRetainedState` is YES only after a keyed full present
 * (generation > 0) or a successfully applied patch; ANY other present
 * (JSON packet, scissor-subset load, raw pixels) clears it, so a patch
 * can never composite from state the glass has moved past. */
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSDictionary *> *canvasRetainedCommands;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *canvasRetainedOrder;
@property(nonatomic, assign) uint64_t canvasRetainedGeneration;
@property(nonatomic, assign) BOOL hasCanvasRetainedState;
/* Host-side frame-profile stamps: durations of the most recent packet
 * present's payload decode and draw, carried on the next frame event and
 * cleared after it, so completion-only frames never re-report a stale
 * sample. Two clock reads per packet present — noise-level cost. */
@property(nonatomic, assign) uint64_t lastPacketDecodeNs;
@property(nonatomic, assign) uint64_t lastPacketDrawNs;
@property(nonatomic, strong) NSCursor *surfaceCursor;
@property(nonatomic, strong) NSTrackingArea *surfaceTrackingArea;
@property(nonatomic, copy) NSString *markedText;
@property(nonatomic, assign) NSRange markedTextRange;
@property(nonatomic, assign) NSRange selectedTextRange;
@property(nonatomic, assign) BOOL interpretedKeyEventEmittedInput;
@property(nonatomic, strong) NSArray<NSAccessibilityElement *> *widgetAccessibilityElements;
@property(nonatomic, strong) NSMutableArray<NativeSdkScrollDriverView *> *scrollDrivers;
@property(nonatomic, weak) NativeSdkScrollDriverView *activeWheelDriver;
@property(nonatomic, assign) BOOL applyingScrollDriverOffset;
@property(nonatomic, assign) BOOL scrollDriverEventPending;
@property(nonatomic, assign) uint64_t pendingScrollDriverId;
@property(nonatomic, assign) double pendingScrollDriverOffsetY;
@property(nonatomic, assign) uint64_t scrollDriverEventLastEmitNs;
@property(nonatomic, assign) BOOL controlClickActive;
- (void)configureWithHost:(NativeSdkAppKitHost *)host windowId:(uint64_t)windowId label:(NSString *)label;
- (BOOL)isAvailable;
- (void)updateDrawableSize;
- (BOOL)presentPixelsWithWidth:(NSUInteger)width height:(NSUInteger)height scale:(CGFloat)scale hasDirtyRect:(BOOL)hasDirtyRect dirtyX:(CGFloat)dirtyX dirtyY:(CGFloat)dirtyY dirtyWidth:(CGFloat)dirtyWidth dirtyHeight:(CGFloat)dirtyHeight dirtyRects:(NSArray<NSValue *> *)dirtyRects rgba8:(const uint8_t *)rgba8 byteLength:(NSUInteger)byteLength;
- (NSInteger)presentGpuPacketWithSurfaceWidth:(CGFloat)surfaceWidth height:(CGFloat)surfaceHeight scale:(CGFloat)scale clearR:(uint8_t)clearR clearG:(uint8_t)clearG clearB:(uint8_t)clearB clearA:(uint8_t)clearA requiresRender:(BOOL)requiresRender commandCount:(NSUInteger)commandCount unsupportedCommandCount:(NSUInteger)unsupportedCommandCount representable:(BOOL)representable json:(const uint8_t *)json byteLength:(NSUInteger)byteLength;
- (NSInteger)presentGpuPacketBinaryWithSurfaceWidth:(CGFloat)surfaceWidth height:(CGFloat)surfaceHeight scale:(CGFloat)scale clearR:(uint8_t)clearR clearG:(uint8_t)clearG clearB:(uint8_t)clearB clearA:(uint8_t)clearA requiresRender:(BOOL)requiresRender commandCount:(NSUInteger)commandCount unsupportedCommandCount:(NSUInteger)unsupportedCommandCount representable:(BOOL)representable packet:(const uint8_t *)packet byteLength:(NSUInteger)byteLength;
- (NSInteger)presentGpuPacketObject:(NSDictionary *)packet surfaceWidth:(CGFloat)surfaceWidth height:(CGFloat)surfaceHeight scale:(CGFloat)scale clearR:(uint8_t)clearR clearG:(uint8_t)clearG clearB:(uint8_t)clearB clearA:(uint8_t)clearA commandCount:(NSUInteger)commandCount;
- (void)rasterCacheWipe;
- (void)rasterCacheRemoveKey:(NSNumber *)key;
- (void)rasterCacheEnsureScale:(CGFloat)scale pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight;
- (void)rasterCacheStoreEntry:(NativeSdkPacketCommandRaster *)entry forKey:(NSNumber *)key;
- (NativeSdkPacketCommandRaster *)rasterCacheFillForCommand:(NSDictionary *)command kind:(NSString *)kind key:(NSNumber *)key scale:(CGFloat)scale pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight;
- (NativeSdkPacketCommandRaster *)rasterCacheBuildEntryForCommand:(NSDictionary *)command kind:(NSString *)kind scale:(CGFloat)scale pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight;
- (BOOL)drawPacketCommand:(NSDictionary *)command key:(NSNumber *)key context:(CGContextRef)context scale:(CGFloat)scale hasClip:(BOOL)hasClip clipRect:(NSRect)clipRect pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight;
- (NSInteger)drawPacketCommands:(NSArray *)commands keys:(NSArray *)keys pixels:(NSMutableData *)pixels pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight scale:(CGFloat)scale surfaceWidth:(CGFloat)surfaceWidth surfaceHeight:(CGFloat)surfaceHeight clearColor:(NSColor *)clearColor fullSurfacePass:(BOOL)fullSurfacePass hasScissor:(BOOL)hasScissor scissorRect:(NSRect)scissorRect dirtyRects:(NSArray<NSValue *> *)dirtyRects;
- (void)verifyIncrementalBackingWithCommands:(NSArray *)commands keys:(NSArray *)keys pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight scale:(CGFloat)scale surfaceWidth:(CGFloat)surfaceWidth surfaceHeight:(CGFloat)surfaceHeight clearColor:(NSColor *)clearColor scissorRect:(NSRect)scissorRect;
- (BOOL)ensureCanvasPresenter;
- (BOOL)ensureCanvasCompositor;
- (NSInteger)compositePacketCommands:(NSArray *)commands keys:(NSArray *)keys target:(id<MTLTexture>)target pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight scale:(CGFloat)scale clearColor:(NSColor *)clearColor fullSurfacePass:(BOOL)fullSurfacePass hasScissor:(BOOL)hasScissor scissorRect:(NSRect)scissorRect dirtyRects:(NSArray<NSValue *> *)dirtyRects waitUntilCompleted:(BOOL)waitUntilCompleted;
- (NSInteger)presentCompositePacketWithCommands:(NSArray *)commands keys:(NSArray *)keys pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight scale:(CGFloat)scale surfaceWidth:(CGFloat)surfaceWidth surfaceHeight:(CGFloat)surfaceHeight clearColor:(NSColor *)clearColor loadAction:(NSString *)loadAction fullSurfacePass:(BOOL)fullSurfacePass hasScissor:(BOOL)hasScissor scissorRect:(NSRect)scissorRect dirtyRects:(NSArray<NSValue *> *)dirtyRects directRetainedDirtyUpdate:(BOOL)directRetainedDirtyUpdate;
- (void)verifyCompositeIncrementalWithCommands:(NSArray *)commands keys:(NSArray *)keys pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight scale:(CGFloat)scale clearColor:(NSColor *)clearColor scissorRect:(NSRect)scissorRect;
- (void)compareCompositeAgainstReferenceWithCommands:(NSArray *)commands keys:(NSArray *)keys pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight scale:(CGFloat)scale surfaceWidth:(CGFloat)surfaceWidth surfaceHeight:(CGFloat)surfaceHeight clearColor:(NSColor *)clearColor;
- (void)dumpCompositeShotWithPixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight;
- (void)recordCanvasRetainedStateForPacket:(NSDictionary *)packet commands:(NSArray *)commands patchLoadAction:(BOOL)patchLoadAction clearLoadAction:(BOOL)clearLoadAction;
- (void)updateWidgetAccessibilityWithNodes:(const native_sdk_appkit_widget_accessibility_node_t *)nodes count:(NSUInteger)count;
- (void)stopDisplayTimer;
- (void)requestRetainedCanvasFrame;
- (void)noteGpuSurfaceInputActivity;
- (void)rescheduleParkedFrameEventEmission;
- (void)flushQueuedFirstCanvasFrameRequestNow;
- (void)advanceRetainedFramePacingClock;
- (void)emitFirstCanvasFrameRequest;
- (void)renderFrame;
- (BOOL)occludedFramePacingActive;
- (void)scheduleFrameEventEmission;
- (void)scheduleFrameEventEmissionForPresentCompletion:(BOOL)presentCompletion;
- (void)emitScheduledFrameEvent;
- (void)emitFrameEventWithFrameIndex:(NSUInteger)frameIndex sampleColor:(uint32_t)sampleColor nonblank:(BOOL)nonblank occluded:(BOOL)occluded;
- (void)emitResizeEvent;
- (void)emitInputEventWithKind:(NSInteger)kind event:(NSEvent *)event button:(NSInteger)button deltaX:(double)deltaX deltaY:(double)deltaY;
- (void)queuePointerMotionInputEvent:(NSEvent *)event kind:(NSInteger)kind button:(NSInteger)button;
- (void)emitQueuedPointerMotionInputEvent;
- (void)queueScrollInputEvent:(NSEvent *)event deltaX:(double)deltaX deltaY:(double)deltaY;
- (void)emitQueuedScrollInputEvent;
- (void)emitInputEventWithKind:(NSInteger)kind point:(NSPoint)point timestampNs:(uint64_t)timestampNs modifiers:(uint32_t)modifiers keyText:(NSString *)keyText inputText:(NSString *)inputText button:(NSInteger)button deltaX:(double)deltaX deltaY:(double)deltaY;
- (void)emitSyntheticKeyDownWithKey:(NSString *)key modifiers:(uint32_t)modifiers;
- (void)updateSurfaceTrackingArea;
- (void)emitSelectAllTextInputCommand;
- (void)emitTextInputEventWithKind:(NSInteger)kind text:(NSString *)text compositionCursor:(NSInteger)compositionCursor;
- (NSAccessibilityElement *)focusedTextAccessibilityElement;
- (BOOL)emitWidgetAccessibilityActionWithId:(uint64_t)widgetId action:(NSInteger)action;
- (BOOL)emitWidgetAccessibilityActionWithId:(uint64_t)widgetId action:(NSInteger)action text:(NSString *)text selectedRange:(NSRange)selectedRange hasSelectedRange:(BOOL)hasSelectedRange;
- (void)setSurfaceCursor:(NSCursor *)cursor;
- (void)setScrollDrivers:(const native_sdk_appkit_scroll_driver_t *)drivers count:(NSUInteger)count;
@end

@interface NativeSdkAssetSchemeHandler : NSObject <WKURLSchemeHandler>
@property(nonatomic, strong) NSString *rootPath;
@property(nonatomic, strong) NSString *entryPath;
@property(nonatomic, assign) BOOL spaFallback;
- (void)configureWithRootPath:(NSString *)rootPath entryPath:(NSString *)entryPath spaFallback:(BOOL)spaFallback;
@end

@interface NativeSdkShortcut : NSObject
@property(nonatomic, strong) NSString *identifier;
@property(nonatomic, strong) NSString *key;
@property(nonatomic, assign) uint32_t modifiers;
@end

@interface NativeSdkAppKitHost : NSObject <WKNavigationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) NativeSdkWindowDelegate *delegate;
@property(nonatomic, strong) NativeSdkBridgeScriptHandler *bridgeScriptHandler;
@property(nonatomic, strong) NativeSdkAssetSchemeHandler *assetSchemeHandler;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSWindow *> *windows;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, WKWebView *> *webViews;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NativeSdkWindowDelegate *> *delegates;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NativeSdkBridgeScriptHandler *> *bridgeScriptHandlers;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NativeSdkAssetSchemeHandler *> *assetSchemeHandlers;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *windowLabels;
/// Present-before-show bookkeeping: windows created with the deferred
/// show policy stay ordered OUT until their first gpu-surface present
/// lands (or the fallback deadline fires). Values are the creation
/// timestamps (ns) so the show can report create→first-present timing.
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *deferredShowWindows;
/// Last NSWindow.backgroundColor applied from a canvas packet's clear
/// color, packed RGBA8 per window — so residual gaps (resize slack,
/// titlebar bands) show the app's background, never a blank default.
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *windowClearColors;
@property(nonatomic, strong) NSMutableDictionary<NSString *, WKWebView *> *childWebViews;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSView *> *nativeViews;
/// App-owned NSViews adopted into native view containers (native-surface
/// adoption): container key → adopted view. Kept alongside `nativeViews`
/// so close paths can drop the adoption bookkeeping with the container.
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSView *> *adoptedViewSurfaces;
/// Reclaims keyboard focus for adopted surfaces on click (see adoptViewSurfaceInWindow).
@property(nonatomic, strong) id adoptedSurfaceClickMonitor;
/// Host-wide binary image-upload side-channel store: image id (decimal
/// string, the packet image cache key namespace) → straight-alpha RGBA8
/// NSImage. Uploaded out-of-band before packets reference the id, shared
/// by every gpu-surface view, dropped on the unregister path.
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *canvasImageStore;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *nativeViewCommands;
@property(nonatomic, strong) NSMutableSet<NSString *> *nativeViewExplicitTextKeys;
@property(nonatomic, strong) NSMutableSet<NSString *> *bridgeEnabledChildWebViewKeys;
@property(nonatomic, strong) NSTimer *timer;
/* Coalescing flag for cross-thread frame requests: set (atomically) by
 * requestFrameFromAnyThread before it posts to the main queue, cleared
 * by the posted block before it emits — so a burst of requests between
 * loop turns delivers ONE frame event, and a request arriving after the
 * block starts still gets its own turn. */
@property(atomic, assign) BOOL crossThreadFramePending;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSTimer *> *appTimers;
/* The app's single audio player and its position-tick timer. One player
 * is the whole surface: a music app plays one track at a time, and a
 * second concurrent stream would be mixer design the platform seam has
 * not earned. The tick timer runs only while playing, at a coarse
 * honest cadence — position is a readout, not a frame clock.
 *
 * ONE AVPlayer serves every source. Local files and verified cache
 * hits used to ride AVAudioPlayer, but that player exposes no PCM, and
 * the SPECTRUM reports need the rendered samples — so local sources
 * moved onto the same AVPlayer the streams always used, where one
 * MTAudioProcessingTap covers everything the deck can play. The proven
 * synchronous decode verdict AVAudioPlayer gave local loads survives
 * as a probe (see audioLoadPath). */
@property(nonatomic, strong) AVPlayer *audioPlayer;
@property(nonatomic, strong) AVPlayerItem *audioItem;
@property(nonatomic, strong) NSTimer *audioPositionTimer;
/* Whether the loaded source is a local file (a plain path or a
 * verified cache entry): local sources never report buffering and run
 * no cache-fill download. */
@property(nonatomic, assign) BOOL audioSourceIsLocal;
/* NSNotificationCenter block-observer tokens for the item's natural
 * end and mid-flight failure; removed on teardown. */
@property(nonatomic, strong) id audioEndObserver;
@property(nonatomic, strong) id audioFailObserver;
/* KVO registration flag so teardown removes observers exactly once. */
@property(nonatomic, assign) BOOL audioObservingStatus;
/* The LOADED acknowledgment fires once per load (item status can
 * bounce through readyToPlay again after a stall). */
@property(nonatomic, assign) BOOL audioLoadedEmitted;
/* The honest buffering mirror emitted with every audio event: YES from
 * stream start (no bytes yet) until the player reports it is actually
 * rolling, then follows timeControlStatus. Never set for local files. */
@property(nonatomic, assign) BOOL audioBuffering;
/* The spectrum tap (see the spectrum section): the MediaToolbox tap on
 * the item's audio mix, its render-thread ring state, the 40 ms
 * analysis timer, the freshness cursor that keeps a stalled tap from
 * re-emitting yesterday's window, and the lazily built vDSP plan
 * (created once, kept for the host's lifetime). */
@property(nonatomic, assign) MTAudioProcessingTapRef audioSpectrumTap;
@property(nonatomic, assign) native_sdk_spectrum_tap_state_t *audioSpectrumState;
@property(nonatomic, strong) NSTimer *audioSpectrumTimer;
@property(nonatomic, assign) uint64_t audioSpectrumLastWritten;
@property(nonatomic, assign) uint64_t audioSpectrumFreshNs;
@property(nonatomic, assign) FFTSetup audioSpectrumFft;
/* The cache fill: a parallel download of the same URL, installed at
 * the cache path only after an atomic size-verified rename. Cancelled
 * when a new load replaces the stream; orphaned (left to finish) when
 * the stream completes naturally. */
@property(nonatomic, strong) NSURLSessionDownloadTask *audioCacheDownload;
@property(nonatomic, strong) NSString *appName;
/* The human-facing app name (app.zon display_name, falling back through
 * the window title to the binary name). Everything the OS labels the
 * app with derives from it: the application menu and its About/Hide/
 * Quit items, the process name, the Dock tile / app switcher entry, and
 * the About panel. */
@property(nonatomic, strong) NSString *displayName;
/* app.zon version, shown in the About panel; empty when undeclared. */
@property(nonatomic, strong) NSString *appVersion;
/* app.zon description, the About panel credits line; empty when
 * undeclared. */
@property(nonatomic, strong) NSString *aboutDescription;
/* Whether the manifest declares web content. Gates the web-only default
 * menu items (Reload, Toggle Web Inspector, Undo/Redo) so canvas-only
 * apps never ship menu items nothing answers. */
@property(nonatomic, assign) BOOL hasWebContent;
/* The decoded manifest icon (nil until the async decode lands, or when
 * the file is missing). The About panel needs it passed explicitly:
 * unbundled dev binaries have no bundle icon for the standard panel to
 * find, and it does not read NSApp.applicationIconImage. */
@property(nonatomic, strong) NSImage *appIcon;
@property(nonatomic, strong) NSString *bundleIdentifier;
@property(nonatomic, strong) NSString *iconPath;
@property(nonatomic, strong) NSString *windowLabel;
@property(nonatomic, assign) native_sdk_appkit_event_callback_t callback;
@property(nonatomic, assign) native_sdk_appkit_bridge_callback_t bridgeCallback;
@property(nonatomic, assign) void *context;
@property(nonatomic, assign) void *bridgeContext;
@property(nonatomic, assign) BOOL didShutdown;
@property(nonatomic, assign) BOOL observesApplicationActivation;
@property(nonatomic, assign) BOOL observesAppearanceChanges;
@property(nonatomic, assign) NSInteger bridgeFrameKeepalive;
@property(nonatomic, strong) id shortcutEventMonitor;
@property(nonatomic, strong) id willTerminateObserver;
@property(nonatomic, strong) dispatch_source_t sigtermSource;
@property(nonatomic, strong) NSArray<NativeSdkShortcut *> *shortcuts;
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, assign) native_sdk_appkit_tray_callback_t trayCallback;
@property(nonatomic, assign) void *trayContext;
@property(nonatomic, strong) NSArray<NSString *> *allowedNavigationOrigins;
@property(nonatomic, strong) NSArray<NSString *> *allowedExternalURLs;
@property(nonatomic, assign) NSInteger externalLinkAction;
- (instancetype)initWithAppName:(NSString *)appName displayName:(NSString *)displayName version:(NSString *)version aboutDescription:(NSString *)aboutDescription hasWebContent:(BOOL)hasWebContent windowTitle:(NSString *)windowTitle bundleIdentifier:(NSString *)bundleIdentifier iconPath:(NSString *)iconPath windowLabel:(NSString *)windowLabel x:(double)x y:(double)y width:(double)width height:(double)height restoreFrame:(BOOL)restoreFrame resizable:(BOOL)resizable titlebarStyle:(int)titlebarStyle showPolicy:(int)showPolicy;
- (BOOL)createWindowWithId:(uint64_t)windowId title:(NSString *)title label:(NSString *)label x:(double)x y:(double)y width:(double)width height:(double)height restoreFrame:(BOOL)restoreFrame resizable:(BOOL)resizable titlebarStyle:(int)titlebarStyle showPolicy:(int)showPolicy makeMain:(BOOL)makeMain;
- (void)showDeferredWindowIfPending:(uint64_t)windowId reason:(const char *)reason;
- (void)applyWindowClearColor:(uint64_t)windowId red:(uint8_t)red green:(uint8_t)green blue:(uint8_t)blue alpha:(uint8_t)alpha;
- (void)focusWindowWithId:(uint64_t)windowId;
- (void)closeWindowWithId:(uint64_t)windowId;
- (BOOL)startWindowDragWithId:(uint64_t)windowId;
- (BOOL)chromeInsetsForWindowId:(uint64_t)windowId top:(double *)top left:(double *)left bottom:(double *)bottom right:(double *)right buttonsX:(double *)buttonsX buttonsY:(double *)buttonsY buttonsWidth:(double *)buttonsWidth buttonsHeight:(double *)buttonsHeight;
- (WKWebView *)ensureMainWebViewForWindowId:(uint64_t)windowId;
- (WKWebView *)webViewForWindowId:(uint64_t)windowId;
- (WKWebView *)mainWebViewForWindow:(NSWindow *)window;
- (NativeSdkAssetSchemeHandler *)assetHandlerForWindowId:(uint64_t)windowId;
- (NSString *)nativeViewKeyForWindow:(uint64_t)windowId label:(NSString *)label;
- (NSRect)viewFrameForContainer:(NSView *)container x:(double)x y:(double)y width:(double)width height:(double)height;
- (NSView *)nativeParentViewForWindow:(uint64_t)windowId parent:(NSString *)parent;
- (NSView *)makeNativeViewWithKind:(NSInteger)kind label:(NSString *)label role:(NSString *)role text:(NSString *)text;
- (void)applyNativeViewState:(NSView *)view enabled:(BOOL)enabled role:(NSString *)role accessibilityLabel:(NSString *)accessibilityLabel text:(NSString *)text;
- (void)applySegmentedControl:(NSSegmentedControl *)control text:(NSString *)text;
- (void)configureNativeView:(NSView *)view command:(NSString *)command key:(NSString *)key;
- (void)emitNativeCommandForSender:(id)sender;
- (BOOL)createNativeViewInWindow:(uint64_t)windowId label:(NSString *)label kind:(NSInteger)kind parent:(NSString *)parent x:(double)x y:(double)y width:(double)width height:(double)height layer:(NSInteger)layer visible:(BOOL)visible enabled:(BOOL)enabled role:(NSString *)role accessibilityLabel:(NSString *)accessibilityLabel text:(NSString *)text command:(NSString *)command;
- (BOOL)updateNativeViewInWindow:(uint64_t)windowId label:(NSString *)label hasFrame:(BOOL)hasFrame x:(double)x y:(double)y width:(double)width height:(double)height hasLayer:(BOOL)hasLayer layer:(NSInteger)layer hasVisible:(BOOL)hasVisible visible:(BOOL)visible hasEnabled:(BOOL)hasEnabled enabled:(BOOL)enabled hasRole:(BOOL)hasRole role:(NSString *)role hasAccessibilityLabel:(BOOL)hasAccessibilityLabel accessibilityLabel:(NSString *)accessibilityLabel hasText:(BOOL)hasText text:(NSString *)text hasCommand:(BOOL)hasCommand command:(NSString *)command;
- (BOOL)setNativeViewFrameInWindow:(uint64_t)windowId label:(NSString *)label x:(double)x y:(double)y width:(double)width height:(double)height;
- (BOOL)setNativeViewVisibleInWindow:(uint64_t)windowId label:(NSString *)label visible:(BOOL)visible;
- (BOOL)focusNativeViewInWindow:(uint64_t)windowId label:(NSString *)label;
- (BOOL)presentGpuSurfacePixelsInWindow:(uint64_t)windowId label:(NSString *)label width:(NSUInteger)width height:(NSUInteger)height scale:(CGFloat)scale hasDirtyRect:(BOOL)hasDirtyRect dirtyX:(CGFloat)dirtyX dirtyY:(CGFloat)dirtyY dirtyWidth:(CGFloat)dirtyWidth dirtyHeight:(CGFloat)dirtyHeight rgba8:(const uint8_t *)rgba8 byteLength:(NSUInteger)byteLength;
- (NSInteger)presentGpuSurfacePacketInWindow:(uint64_t)windowId label:(NSString *)label surfaceWidth:(CGFloat)surfaceWidth height:(CGFloat)surfaceHeight scale:(CGFloat)scale clearR:(uint8_t)clearR clearG:(uint8_t)clearG clearB:(uint8_t)clearB clearA:(uint8_t)clearA requiresRender:(BOOL)requiresRender commandCount:(NSUInteger)commandCount unsupportedCommandCount:(NSUInteger)unsupportedCommandCount representable:(BOOL)representable json:(const uint8_t *)json byteLength:(NSUInteger)byteLength;
- (NSInteger)presentGpuSurfacePacketBinaryInWindow:(uint64_t)windowId label:(NSString *)label surfaceWidth:(CGFloat)surfaceWidth height:(CGFloat)surfaceHeight scale:(CGFloat)scale clearR:(uint8_t)clearR clearG:(uint8_t)clearG clearB:(uint8_t)clearB clearA:(uint8_t)clearA requiresRender:(BOOL)requiresRender commandCount:(NSUInteger)commandCount unsupportedCommandCount:(NSUInteger)unsupportedCommandCount representable:(BOOL)representable packet:(const uint8_t *)packet byteLength:(NSUInteger)byteLength;
- (BOOL)requestGpuSurfaceFrameInWindow:(uint64_t)windowId label:(NSString *)label;
- (BOOL)noteGpuSurfaceInputInWindow:(uint64_t)windowId label:(NSString *)label;
- (BOOL)setGpuSurfaceScrollDriversInWindow:(uint64_t)windowId label:(NSString *)label drivers:(const native_sdk_appkit_scroll_driver_t *)drivers count:(NSUInteger)count;
- (BOOL)showContextMenuInWindow:(uint64_t)windowId label:(NSString *)label x:(double)x y:(double)y token:(uint64_t)token items:(const native_sdk_appkit_context_menu_item_t *)items count:(NSUInteger)count;
- (BOOL)uploadGpuSurfaceImageWithId:(uint64_t)imageId width:(NSUInteger)width height:(NSUInteger)height rgba8:(const uint8_t *)rgba8 byteLength:(NSUInteger)byteLength;
- (BOOL)removeGpuSurfaceImageWithId:(uint64_t)imageId;
- (BOOL)updateWidgetAccessibilityInWindow:(uint64_t)windowId label:(NSString *)label nodes:(const native_sdk_appkit_widget_accessibility_node_t *)nodes count:(NSUInteger)count;
- (BOOL)nativeView:(NSView *)candidate isInSubtreeRootedAt:(NSView *)root;
- (NSArray<NSString *> *)nativeViewKeysInSubtreeForWindow:(uint64_t)windowId rootKey:(NSString *)rootKey;
- (BOOL)closeNativeViewInWindow:(uint64_t)windowId label:(NSString *)label;
- (void)closeNativeViewsInWindow:(uint64_t)windowId;
- (BOOL)adoptViewSurfaceInWindow:(uint64_t)windowId label:(NSString *)label surface:(NSView *)surface;
- (BOOL)viewIsAdoptedSurfaceDescendant:(NSView *)view;
- (void)installAdoptedSurfaceClickMonitor;
- (BOOL)releaseViewSurfaceInWindow:(uint64_t)windowId label:(NSString *)label;
- (BOOL)createWebViewInWindow:(uint64_t)windowId label:(NSString *)label url:(NSString *)url x:(double)x y:(double)y width:(double)width height:(double)height layer:(NSInteger)layer transparent:(BOOL)transparent bridgeEnabled:(BOOL)bridgeEnabled;
- (BOOL)setNativeViewCursorInWindow:(uint64_t)windowId label:(NSString *)label cursor:(NSInteger)cursor;
- (BOOL)setWebViewFrameInWindow:(uint64_t)windowId label:(NSString *)label x:(double)x y:(double)y width:(double)width height:(double)height;
- (BOOL)navigateWebViewInWindow:(uint64_t)windowId label:(NSString *)label url:(NSString *)url;
- (BOOL)setWebViewZoomInWindow:(uint64_t)windowId label:(NSString *)label zoom:(double)zoom;
- (BOOL)setWebViewLayerInWindow:(uint64_t)windowId label:(NSString *)label layer:(NSInteger)layer;
- (BOOL)closeWebViewInWindow:(uint64_t)windowId label:(NSString *)label;
- (void)closeWebViewsInWindow:(uint64_t)windowId;
- (void)reorderWebViewsInWindow:(uint64_t)windowId;
- (void)updateCoveredMouseRectsInWindow:(uint64_t)windowId;
- (void)applyCoveredMouseRects:(NSArray<NSValue *> *)rects toWebView:(WKWebView *)webView;
- (void)removeBridgeHandlerForChildWebView:(WKWebView *)webView key:(NSString *)key;
- (void)removeAllChildBridgeHandlers;
- (void)configureApplication;
- (void)buildMenuBar;
- (void)addApplicationMenuToMenu:(NSMenu *)mainMenu;
- (NSMenuItem *)menuItem:(NSString *)title action:(SEL)action key:(NSString *)key modifiers:(NSEventModifierFlags)modifiers;
- (NSMenuItem *)commandMenuItem:(NSString *)title command:(NSString *)command key:(NSString *)key modifiers:(uint32_t)modifiers enabled:(BOOL)enabled checked:(BOOL)checked;
- (void)menuCommandItemClicked:(NSMenuItem *)menuItem;
- (uint64_t)activeCommandWindowId;
- (void)setMenusWithTitles:(const char *const *)menuTitles titleLengths:(const size_t *)menuTitleLengths count:(size_t)menuCount itemMenuIndices:(const uint32_t *)itemMenuIndices itemLabels:(const char *const *)itemLabels itemLabelLengths:(const size_t *)itemLabelLengths itemCommands:(const char *const *)itemCommands itemCommandLengths:(const size_t *)itemCommandLengths itemKeys:(const char *const *)itemKeys itemKeyLengths:(const size_t *)itemKeyLengths itemModifiers:(const uint32_t *)itemModifiers itemSeparators:(const int *)itemSeparators itemEnabled:(const int *)itemEnabled itemChecked:(const int *)itemChecked itemCount:(size_t)itemCount;
- (void)runWithCallback:(native_sdk_appkit_event_callback_t)callback context:(void *)context;
- (void)stop;
- (void)emitEvent:(native_sdk_appkit_event_t)event;
- (BOOL)emitDroppedFileURLs:(NSArray<NSURL *> *)urls windowId:(uint64_t)windowId;
- (void)startApplicationActivationObservers;
- (void)stopApplicationActivationObservers;
- (void)applicationDidBecomeActive:(NSNotification *)notification;
- (void)applicationDidResignActive:(NSNotification *)notification;
- (void)startAppearanceObservers;
- (void)stopAppearanceObservers;
- (void)emitAppearanceChanged;
- (void)emitResize;
- (void)emitResizeForWindowId:(uint64_t)windowId;
- (void)emitDeferredResizeForWindowId:(uint64_t)windowId;
- (void)emitWindowFrame:(BOOL)open;
- (void)emitWindowFrameForWindowId:(uint64_t)windowId open:(BOOL)open;
- (void)scheduleFrame;
- (void)requestFrameFromAnyThread;
- (void)startAppTimerWithId:(uint64_t)timerId intervalNs:(uint64_t)intervalNs repeats:(BOOL)repeats;
- (void)cancelAppTimerWithId:(uint64_t)timerId;
- (void)appTimerFired:(NSTimer *)timer;
- (void)invalidateAppTimers;
- (int)audioLoadPath:(NSString *)path;
- (int)audioLoadURL:(NSString *)urlString cachePath:(NSString *)cachePath expectedBytes:(uint64_t)expectedBytes;
- (void)audioInstallItem:(AVPlayerItem *)item asset:(AVURLAsset *)asset localSource:(BOOL)localSource;
- (void)startAudioCacheDownloadFrom:(NSURL *)url toPath:(NSString *)cachePath expectedBytes:(uint64_t)expectedBytes;
- (void)audioTearDownPlayerCancellingDownload:(BOOL)cancelDownload;
- (void)audioItemStatusChanged;
- (void)audioTimeControlChanged;
- (void)audioDidPlayToEnd;
- (void)audioDidFail;
- (int)audioPlay;
- (int)audioPause;
- (int)audioStop;
- (int)audioSeekToMs:(uint64_t)positionMs;
- (int)audioSetVolume:(double)volume;
- (void)emitAudioEventOfKind:(int)kind;
- (void)stopAudioPositionTimer;
- (void)audioInstallSpectrumTapForItem:(AVPlayerItem *)item asset:(AVURLAsset *)asset;
- (void)audioTearDownSpectrumTap;
- (void)stopAudioSpectrumTimer;
- (BOOL)anyHostWindowVisibleOnGlass;
- (void)audioSpectrumTimerFired:(NSTimer *)timer;
- (void)wakeFromAnyThread;
- (void)scheduleBridgeFrames;
- (void)emitFrame;
- (void)emitShutdown;
- (void)loadSource:(NSString *)source kind:(NSInteger)kind assetRoot:(NSString *)assetRoot entry:(NSString *)entry origin:(NSString *)origin spaFallback:(BOOL)spaFallback;
- (void)loadSource:(NSString *)source kind:(NSInteger)kind assetRoot:(NSString *)assetRoot entry:(NSString *)entry origin:(NSString *)origin spaFallback:(BOOL)spaFallback windowId:(uint64_t)windowId;
- (void)setAllowedNavigationOrigins:(NSArray<NSString *> *)origins externalURLs:(NSArray<NSString *> *)externalURLs externalAction:(NSInteger)externalAction;
- (BOOL)allowsNavigationURL:(NSURL *)url;
- (BOOL)openExternalURLIfAllowed:(NSURL *)url;
- (void)emitNavigationForWebView:(WKWebView *)webView url:(NSURL *)url;
- (void)receiveBridgeMessage:(WKScriptMessage *)message windowId:(uint64_t)windowId webViewLabel:(NSString *)webViewLabel;
- (void)completeBridgeWithResponse:(NSString *)response;
- (void)completeBridgeWithResponse:(NSString *)response windowId:(uint64_t)windowId;
- (void)completeBridgeWithResponse:(NSString *)response windowId:(uint64_t)windowId webViewLabel:(NSString *)webViewLabel;
- (void)emitEventNamed:(NSString *)name detailJSON:(NSString *)detailJSON windowId:(uint64_t)windowId;
- (void)setShortcutsWithIds:(const char *const *)ids idLengths:(const size_t *)idLengths keys:(const char *const *)keys keyLengths:(const size_t *)keyLengths modifiers:(const uint32_t *)modifiers count:(size_t)count;
- (BOOL)handleShortcutEvent:(NSEvent *)event;
- (void)emitShortcutWithId:(NSString *)identifier key:(NSString *)key modifiers:(uint32_t)modifiers event:(NSEvent *)event;
@end

// Recursively re-emit the gpu-surface resize event for every metal
// surface under `view` (the tall-titlebar chrome re-query path).
static void NativeSdkEmitGpuSurfaceResizes(NSView *view) {
    if ([view isKindOfClass:[NativeSdkMetalSurfaceView class]]) {
        [(NativeSdkMetalSurfaceView *)view emitResizeEvent];
    }
    for (NSView *subview in view.subviews) {
        NativeSdkEmitGpuSurfaceResizes(subview);
    }
}

@implementation NativeSdkWindowDelegate

- (void)windowDidResize:(NSNotification *)notification {
    (void)notification;
    [self.host emitWindowFrameForWindowId:self.windowId open:YES];
    [self.host emitResizeForWindowId:self.windowId];
    [self.host emitDeferredResizeForWindowId:self.windowId];
    [self.host scheduleFrame];
}

- (void)windowDidMove:(NSNotification *)notification {
    (void)notification;
    [self.host emitWindowFrameForWindowId:self.windowId open:YES];
    [self.host scheduleFrame];
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    (void)notification;
    [self.host emitWindowFrameForWindowId:self.windowId open:YES];
    [self.host emitResizeForWindowId:self.windowId];
    [self.host emitDeferredResizeForWindowId:self.windowId];
    [self.host scheduleFrame];
}

// The tall-titlebar toolbar is pure geometry (it exists only to get the
// unified band height and centered traffic lights), but in fullscreen
// the system keeps an attached toolbar VISIBLE as a blank band covering
// the app's own header. Hide it for the fullscreen stay and restore it
// on exit — at the DID notifications, because the system snapshots and
// restores toolbar visibility across the transition and stomps changes
// made at the WILL edge. Re-emitting the resize after the toggle makes
// the runtime re-query chrome insets AFTER the change, so
// contentLayoutRect's new truth (zero overlay in fullscreen, tall band
// back on exit) reaches the app deterministically.
// The tall-titlebar toolbar is pure geometry (it exists only for the
// unified band height and centered traffic lights), but fullscreen
// keeps an attached toolbar VISIBLE as a blank band covering the app's
// own header — so hide it for the fullscreen stay and restore it on
// exit. Hiding lands at the WILL edge so every transition resize (and
// its chrome re-query) already sees the hidden toolbar; the restore is
// RE-ASSERTED at the DID edge because the system snapshots toolbar
// visibility across the transition and stomps a WILL-edge restore.
// The chrome re-query itself rides the `contentLayoutRect` KVO below,
// which fires only when the band's geometry has ACTUALLY changed —
// re-querying at the notification edges reads the stale rect.
- (void)windowWillEnterFullScreen:(NSNotification *)notification {
    (void)notification;
    [self setToolbarVisible:NO];
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification {
    (void)notification;
    [self setToolbarVisible:NO];
}

- (void)windowWillExitFullScreen:(NSNotification *)notification {
    (void)notification;
    [self setToolbarVisible:YES];
}

- (void)windowDidExitFullScreen:(NSNotification *)notification {
    (void)notification;
    [self setToolbarVisible:YES];
}

- (void)setToolbarVisible:(BOOL)visible {
    NSWindow *window = self.host.windows[@(self.windowId)];
    if (!window.toolbar) return;
    window.toolbar.visible = visible;
}

// Registered for tall-titlebar windows only (`observesContentLayout`):
// whenever the titlebar band actually grows or shrinks — toolbar
// visibility flips settle a layout pass after the notification edges —
// re-emit the resizes so the runtime re-queries the chrome insets
// against the settled rect. The gpu-surface resize is the one that
// reaches a canvas app's chrome re-query (its frame is unchanged, but
// the runtime re-queries chrome on every resize event and dedupes
// unchanged geometry model-side).
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    (void)object;
    (void)change;
    (void)context;
    if (![keyPath isEqualToString:@"contentLayoutRect"]) return;
    [self.host emitResizeForWindowId:self.windowId];
    NSWindow *window = self.host.windows[@(self.windowId)];
    if (window.contentView) NativeSdkEmitGpuSurfaceResizes(window.contentView);
    [self.host scheduleFrame];
}

// The window is a dragging destination now that the main WebView (whose
// registration used to catch every drop) is lazy: NSWindow forwards
// these to its delegate, and the emit path is byte-identical to the
// WebView's. A present main/child WebView still wins (views outrank the
// window for registered types), and its handler emits the same event.
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    (void)sender;
    return NSDragOperationCopy;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPasteboard *pasteboard = sender.draggingPasteboard;
    NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[ [NSURL class] ]
                                                       options:@{ NSPasteboardURLReadingFileURLsOnlyKey : @YES }];
    return [self.host emitDroppedFileURLs:urls windowId:self.windowId];
}

- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    if (self.observesContentLayout) {
        NSWindow *window = self.host.windows[@(self.windowId)];
        [window removeObserver:self forKeyPath:@"contentLayoutRect"];
        self.observesContentLayout = NO;
    }
    [self.host emitWindowFrameForWindowId:self.windowId open:NO];
    [self.host closeWebViewsInWindow:self.windowId];
    [self.host closeNativeViewsInWindow:self.windowId];
    NSNumber *key = @(self.windowId);
    [self.host.windows removeObjectForKey:key];
    [self.host.webViews removeObjectForKey:key];
    [self.host.delegates removeObjectForKey:key];
    [self.host.bridgeScriptHandlers removeObjectForKey:key];
    [self.host.assetSchemeHandlers removeObjectForKey:key];
    [self.host.windowLabels removeObjectForKey:key];
    [self.host.deferredShowWindows removeObjectForKey:key];
    [self.host.windowClearColors removeObjectForKey:key];
    if (self.host.windows.count == 0) {
        [self.host emitShutdown];
        [self.host stop];
    }
}

@end

@implementation NativeSdkWebView

- (BOOL)pointIsCovered:(NSPoint)point {
    for (NSValue *value in self.coveredMouseRects) {
        if (NSPointInRect(point, value.rectValue)) return YES;
    }
    return NO;
}

- (BOOL)eventIsCovered:(NSEvent *)event {
    if (!event) return NO;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    return [self pointIsCovered:point];
}

- (NSView *)hitTest:(NSPoint)point {
    if ([self pointIsCovered:point]) return nil;
    return [super hitTest:point];
}

- (void)mouseEntered:(NSEvent *)event { if (![self eventIsCovered:event]) [super mouseEntered:event]; }
- (void)mouseExited:(NSEvent *)event { if (![self eventIsCovered:event]) [super mouseExited:event]; }
- (void)mouseMoved:(NSEvent *)event { if (![self eventIsCovered:event]) [super mouseMoved:event]; }
- (void)mouseDown:(NSEvent *)event { if (![self eventIsCovered:event]) [super mouseDown:event]; }
- (void)mouseUp:(NSEvent *)event { if (![self eventIsCovered:event]) [super mouseUp:event]; }
- (void)mouseDragged:(NSEvent *)event { if (![self eventIsCovered:event]) [super mouseDragged:event]; }
- (void)rightMouseDown:(NSEvent *)event { if (![self eventIsCovered:event]) [super rightMouseDown:event]; }
- (void)rightMouseUp:(NSEvent *)event { if (![self eventIsCovered:event]) [super rightMouseUp:event]; }

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    (void)sender;
    return NSDragOperationCopy;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPasteboard *pasteboard = sender.draggingPasteboard;
    NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[[NSURL class]]
                                                       options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
    return [self.host emitDroppedFileURLs:urls windowId:self.windowId];
}

@end

@implementation NativeSdkBridgeScriptHandler

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)userContentController;
    [self.host receiveBridgeMessage:message windowId:self.windowId webViewLabel:self.webViewLabel ?: @"main"];
}

@end

@implementation NativeSdkWidgetAccessibilityElement

/* The action-flag gate for advertising AXPress: press, toggle, and
 * select all have an honest press-shaped actuation (activate, flip,
 * or move the selection — the same things a pointer press does on
 * those widgets). Focusability alone is NOT one: a press that merely
 * moves focus is a no-op to the user who invoked "press", so a
 * focus-only element must not advertise the action at all. */
static const uint32_t NativeSdkWidgetPressActionFlags =
    NATIVE_SDK_APPKIT_WIDGET_ACTION_PRESS |
    NATIVE_SDK_APPKIT_WIDGET_ACTION_TOGGLE |
    NATIVE_SDK_APPKIT_WIDGET_ACTION_SELECT;

- (NSArray *)accessibilityActionNames {
    if (!self.accessibilityEnabled) return @[];
    NSMutableArray *actions = [NSMutableArray arrayWithCapacity:3];
    if ((self.actionFlags & NativeSdkWidgetPressActionFlags) != 0) {
        [actions addObject:NSAccessibilityPressAction];
    }
    if ((self.actionFlags & NATIVE_SDK_APPKIT_WIDGET_ACTION_INCREMENT) != 0) {
        [actions addObject:NSAccessibilityIncrementAction];
    }
    if ((self.actionFlags & NATIVE_SDK_APPKIT_WIDGET_ACTION_DECREMENT) != 0) {
        [actions addObject:NSAccessibilityDecrementAction];
    }
    if ((self.actionFlags & NATIVE_SDK_APPKIT_WIDGET_ACTION_DISMISS) != 0) {
        [actions addObject:NSAccessibilityCancelAction];
    }
    return actions;
}

/* AppKit derives the action list an external assistive client sees
 * from which accessibilityPerform* selectors the ELEMENT allows — not
 * from accessibilityActionNames — so a class that implements all four
 * selectors advertises all four actions on every element (AXIncrement
 * on a static label), and performing an unsupported one "succeeds" as
 * a no-op: AppKit reports success to the AX client regardless of the
 * method's NO return. This override is the per-element truth: a
 * selector is allowed exactly when the published widget's action
 * flags back it, so unsupported actions disappear from the advertised
 * list instead of no-op'ing on invocation. */
- (BOOL)isAccessibilitySelectorAllowed:(SEL)selector {
    if (selector == @selector(accessibilityPerformPress)) {
        return self.accessibilityEnabled && (self.actionFlags & NativeSdkWidgetPressActionFlags) != 0;
    }
    if (selector == @selector(accessibilityPerformIncrement)) {
        return self.accessibilityEnabled && (self.actionFlags & NATIVE_SDK_APPKIT_WIDGET_ACTION_INCREMENT) != 0;
    }
    if (selector == @selector(accessibilityPerformDecrement)) {
        return self.accessibilityEnabled && (self.actionFlags & NATIVE_SDK_APPKIT_WIDGET_ACTION_DECREMENT) != 0;
    }
    if (selector == @selector(accessibilityPerformCancel)) {
        return self.accessibilityEnabled && (self.actionFlags & NATIVE_SDK_APPKIT_WIDGET_ACTION_DISMISS) != 0;
    }
    return [super isAccessibilitySelectorAllowed:selector];
}

- (BOOL)accessibilityPerformPress {
    if (!self.accessibilityEnabled) return NO;
    if ((self.actionFlags & NATIVE_SDK_APPKIT_WIDGET_ACTION_TOGGLE) != 0) {
        return [self.surfaceView emitWidgetAccessibilityActionWithId:self.widgetId action:NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_TOGGLE];
    }
    if ((self.actionFlags & NATIVE_SDK_APPKIT_WIDGET_ACTION_PRESS) != 0) {
        return [self.surfaceView emitWidgetAccessibilityActionWithId:self.widgetId action:NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_PRESS];
    }
    if ((self.actionFlags & NATIVE_SDK_APPKIT_WIDGET_ACTION_SELECT) != 0) {
        return [self.surfaceView emitWidgetAccessibilityActionWithId:self.widgetId action:NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_SELECT];
    }
    return NO;
}

- (BOOL)accessibilityPerformIncrement {
    if (!self.accessibilityEnabled || (self.actionFlags & NATIVE_SDK_APPKIT_WIDGET_ACTION_INCREMENT) == 0) return NO;
    return [self.surfaceView emitWidgetAccessibilityActionWithId:self.widgetId action:NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_INCREMENT];
}

- (BOOL)accessibilityPerformDecrement {
    if (!self.accessibilityEnabled || (self.actionFlags & NATIVE_SDK_APPKIT_WIDGET_ACTION_DECREMENT) == 0) return NO;
    return [self.surfaceView emitWidgetAccessibilityActionWithId:self.widgetId action:NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_DECREMENT];
}

- (BOOL)accessibilityPerformCancel {
    if (!self.accessibilityEnabled || (self.actionFlags & NATIVE_SDK_APPKIT_WIDGET_ACTION_DISMISS) == 0) return NO;
    return [self.surfaceView emitWidgetAccessibilityActionWithId:self.widgetId action:NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_DISMISS];
}

/* An assistive client focuses a widget by WRITING AXFocused (the
 * platform idiom for moving keyboard focus into a text field). The
 * inherited setter only stores the flag on this snapshot element —
 * the app's real focus never moves, which is the same
 * success-without-actuation dishonesty the press path had. Route the
 * write to the runtime's focus dispatch; the next semantics publish
 * reports the app's actual focus back. */
- (void)setAccessibilityFocused:(BOOL)focused {
    [super setAccessibilityFocused:focused];
    if (!focused || !self.accessibilityEnabled) return;
    if ((self.actionFlags & NATIVE_SDK_APPKIT_WIDGET_ACTION_FOCUS) == 0) return;
    [self.surfaceView emitWidgetAccessibilityActionWithId:self.widgetId action:NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_FOCUS];
}

- (BOOL)accessibilityIsAttributeSettable:(NSAccessibilityAttributeName)attribute {
    if (self.accessibilityEnabled && [attribute isEqualToString:NSAccessibilityValueAttribute]) {
        return (self.actionFlags & NATIVE_SDK_APPKIT_WIDGET_ACTION_SET_TEXT) != 0;
    }
    if (self.accessibilityEnabled &&
        ([attribute isEqualToString:NSAccessibilitySelectedTextRangeAttribute] ||
         [attribute isEqualToString:NSAccessibilitySelectedTextRangesAttribute])) {
        return (self.actionFlags & NATIVE_SDK_APPKIT_WIDGET_ACTION_SET_SELECTION) != 0;
    }
    return [super accessibilityIsAttributeSettable:attribute];
}

- (void)accessibilitySetValue:(id)value forAttribute:(NSAccessibilityAttributeName)attribute {
    if ([attribute isEqualToString:NSAccessibilityValueAttribute]) {
        [self emitSetTextAccessibilityValue:value];
        return;
    }
    if ([attribute isEqualToString:NSAccessibilitySelectedTextRangeAttribute] ||
        [attribute isEqualToString:NSAccessibilitySelectedTextRangesAttribute]) {
        [self emitSetSelectionAccessibilityValue:value];
        return;
    }
    [super accessibilitySetValue:value forAttribute:attribute];
}

- (BOOL)emitSetTextAccessibilityValue:(id)value {
    if (!self.accessibilityEnabled || (self.actionFlags & NATIVE_SDK_APPKIT_WIDGET_ACTION_SET_TEXT) == 0) return NO;
    NSString *text = @"";
    if ([value isKindOfClass:[NSString class]]) {
        text = (NSString *)value;
    } else if (value) {
        text = [value description] ?: @"";
    }
    return [self.surfaceView emitWidgetAccessibilityActionWithId:self.widgetId
                                                          action:NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_SET_TEXT
                                                            text:text
                                                   selectedRange:NSMakeRange(0, 0)
                                                hasSelectedRange:NO];
}

- (BOOL)emitSetSelectionAccessibilityValue:(id)value {
    if (!self.accessibilityEnabled || (self.actionFlags & NATIVE_SDK_APPKIT_WIDGET_ACTION_SET_SELECTION) == 0) return NO;
    NSRange selectedRange = NSMakeRange(NSNotFound, 0);
    if ([value isKindOfClass:[NSValue class]]) {
        selectedRange = [(NSValue *)value rangeValue];
    } else if ([value isKindOfClass:[NSArray class]]) {
        id firstRange = [(NSArray *)value firstObject];
        if ([firstRange isKindOfClass:[NSValue class]]) {
            selectedRange = [(NSValue *)firstRange rangeValue];
        }
    }
    if (selectedRange.location == NSNotFound) return NO;
    return [self.surfaceView emitWidgetAccessibilityActionWithId:self.widgetId
                                                          action:NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_SET_SELECTION
                                                            text:@""
                                                   selectedRange:selectedRange
                                                hasSelectedRange:YES];
}

@end

static CGFloat NativeSdkPacketNumber(id value, CGFloat fallback) {
    return [value respondsToSelector:@selector(doubleValue)] ? (CGFloat)[value doubleValue] : fallback;
}

static NSArray *NativeSdkPacketArray(id value, NSUInteger minCount) {
    if (![value isKindOfClass:[NSArray class]]) return nil;
    NSArray *array = (NSArray *)value;
    return array.count >= minCount ? array : nil;
}

static NSDictionary *NativeSdkPacketDictionary(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? (NSDictionary *)value : nil;
}

static NSRect NativeSdkPacketRect(id value) {
    NSArray *array = NativeSdkPacketArray(value, 4);
    if (!array) return NSZeroRect;
    return NSMakeRect(
        NativeSdkPacketNumber(array[0], 0),
        NativeSdkPacketNumber(array[1], 0),
        NativeSdkPacketNumber(array[2], 0),
        NativeSdkPacketNumber(array[3], 0)
    );
}

static BOOL NativeSdkPacketRectIntersects(NSRect a, NSRect b) {
    a = CGRectStandardize(a);
    b = CGRectStandardize(b);
    if (NSIsEmptyRect(a) || NSIsEmptyRect(b)) return NO;
    return !NSIsEmptyRect(NSIntersectionRect(a, b));
}

static NSPoint NativeSdkPacketPoint(id value) {
    NSArray *array = NativeSdkPacketArray(value, 2);
    if (!array) return NSZeroPoint;
    return NSMakePoint(NativeSdkPacketNumber(array[0], 0), NativeSdkPacketNumber(array[1], 0));
}

static BOOL NativeSdkPacketReadPoint(id value, NSPoint *point) {
    NSArray *array = NativeSdkPacketArray(value, 2);
    if (!array || !point) return NO;
    *point = NSMakePoint(NativeSdkPacketNumber(array[0], 0), NativeSdkPacketNumber(array[1], 0));
    return YES;
}

static CGFloat NativeSdkPacketRadiusAt(id value, NSUInteger index, CGFloat maximum) {
    NSArray *array = NativeSdkPacketArray(value, 1);
    if (!array) return 0;
    id radiusValue = index < array.count ? array[index] : array[0];
    return fmax(0.0, fmin(maximum, NativeSdkPacketNumber(radiusValue, 0)));
}

static NSColor *NativeSdkPacketColor(id value, CGFloat opacity) {
    NSArray *array = NativeSdkPacketArray(value, 4);
    if (!array) return nil;
    CGFloat red = fmax(0.0, fmin(1.0, NativeSdkPacketNumber(array[0], 0)));
    CGFloat green = fmax(0.0, fmin(1.0, NativeSdkPacketNumber(array[1], 0)));
    CGFloat blue = fmax(0.0, fmin(1.0, NativeSdkPacketNumber(array[2], 0)));
    CGFloat alpha = fmax(0.0, fmin(1.0, NativeSdkPacketNumber(array[3], 1) * opacity));
    return [NSColor colorWithDeviceRed:red green:green blue:blue alpha:alpha];
}

static NSBezierPath *NativeSdkPacketRoundedRectPath(NSRect rect, id radiusValue) {
    rect = CGRectStandardize(rect);
    CGFloat maxRadius = fmax(0.0, fmin(rect.size.width, rect.size.height) * 0.5);
    CGFloat topLeft = NativeSdkPacketRadiusAt(radiusValue, 0, maxRadius);
    CGFloat topRight = NativeSdkPacketRadiusAt(radiusValue, 1, maxRadius);
    CGFloat bottomRight = NativeSdkPacketRadiusAt(radiusValue, 2, maxRadius);
    CGFloat bottomLeft = NativeSdkPacketRadiusAt(radiusValue, 3, maxRadius);
    CGFloat minX = NSMinX(rect);
    CGFloat minY = NSMinY(rect);
    CGFloat maxX = NSMaxX(rect);
    CGFloat maxY = NSMaxY(rect);
    const CGFloat kappa = 0.5522847498307936;
    NSBezierPath *path = [NSBezierPath bezierPath];

    [path moveToPoint:NSMakePoint(minX + topLeft, minY)];
    [path lineToPoint:NSMakePoint(maxX - topRight, minY)];
    if (topRight > 0) {
        [path curveToPoint:NSMakePoint(maxX, minY + topRight)
             controlPoint1:NSMakePoint(maxX - topRight + topRight * kappa, minY)
             controlPoint2:NSMakePoint(maxX, minY + topRight - topRight * kappa)];
    } else {
        [path lineToPoint:NSMakePoint(maxX, minY)];
    }

    [path lineToPoint:NSMakePoint(maxX, maxY - bottomRight)];
    if (bottomRight > 0) {
        [path curveToPoint:NSMakePoint(maxX - bottomRight, maxY)
             controlPoint1:NSMakePoint(maxX, maxY - bottomRight + bottomRight * kappa)
             controlPoint2:NSMakePoint(maxX - bottomRight + bottomRight * kappa, maxY)];
    } else {
        [path lineToPoint:NSMakePoint(maxX, maxY)];
    }

    [path lineToPoint:NSMakePoint(minX + bottomLeft, maxY)];
    if (bottomLeft > 0) {
        [path curveToPoint:NSMakePoint(minX, maxY - bottomLeft)
             controlPoint1:NSMakePoint(minX + bottomLeft - bottomLeft * kappa, maxY)
             controlPoint2:NSMakePoint(minX, maxY - bottomLeft + bottomLeft * kappa)];
    } else {
        [path lineToPoint:NSMakePoint(minX, maxY)];
    }

    [path lineToPoint:NSMakePoint(minX, minY + topLeft)];
    if (topLeft > 0) {
        [path curveToPoint:NSMakePoint(minX + topLeft, minY)
             controlPoint1:NSMakePoint(minX, minY + topLeft - topLeft * kappa)
             controlPoint2:NSMakePoint(minX + topLeft - topLeft * kappa, minY)];
    } else {
        [path lineToPoint:NSMakePoint(minX, minY)];
    }
    [path closePath];
    return path;
}

static NSBezierPath *NativeSdkPacketShapePath(NSDictionary *shape) {
    if (!shape) return nil;
    NSString *kind = [shape[@"kind"] isKindOfClass:[NSString class]] ? shape[@"kind"] : @"";
    if ([kind isEqualToString:@"path"]) {
        NSArray *elements = NativeSdkPacketArray(shape[@"path"], 0);
        if (!elements) return nil;
        NSBezierPath *path = [NSBezierPath bezierPath];
        BOOL hasCurrentPoint = NO;
        NSPoint currentPoint = NSZeroPoint;
        NSPoint subpathStart = NSZeroPoint;
        for (id elementObject in elements) {
            NSDictionary *element = NativeSdkPacketDictionary(elementObject);
            if (!element) return nil;
            NSString *verb = [element[@"verb"] isKindOfClass:[NSString class]] ? element[@"verb"] : @"";
            NSArray *points = NativeSdkPacketArray(element[@"points"], 0);
            if (!points) return nil;
            if ([verb isEqualToString:@"move_to"]) {
                NSPoint point = NSZeroPoint;
                if (points.count < 1 || !NativeSdkPacketReadPoint(points[0], &point)) return nil;
                [path moveToPoint:point];
                currentPoint = point;
                subpathStart = point;
                hasCurrentPoint = YES;
            } else if ([verb isEqualToString:@"line_to"]) {
                NSPoint point = NSZeroPoint;
                if (!hasCurrentPoint || points.count < 1 || !NativeSdkPacketReadPoint(points[0], &point)) return nil;
                [path lineToPoint:point];
                currentPoint = point;
            } else if ([verb isEqualToString:@"quad_to"]) {
                NSPoint control = NSZeroPoint;
                NSPoint end = NSZeroPoint;
                if (!hasCurrentPoint || points.count < 2 || !NativeSdkPacketReadPoint(points[0], &control) || !NativeSdkPacketReadPoint(points[1], &end)) return nil;
                NSPoint control1 = NSMakePoint(currentPoint.x + (control.x - currentPoint.x) * 2.0 / 3.0, currentPoint.y + (control.y - currentPoint.y) * 2.0 / 3.0);
                NSPoint control2 = NSMakePoint(end.x + (control.x - end.x) * 2.0 / 3.0, end.y + (control.y - end.y) * 2.0 / 3.0);
                [path curveToPoint:end controlPoint1:control1 controlPoint2:control2];
                currentPoint = end;
            } else if ([verb isEqualToString:@"cubic_to"]) {
                NSPoint control1 = NSZeroPoint;
                NSPoint control2 = NSZeroPoint;
                NSPoint end = NSZeroPoint;
                if (!hasCurrentPoint || points.count < 3 || !NativeSdkPacketReadPoint(points[0], &control1) || !NativeSdkPacketReadPoint(points[1], &control2) || !NativeSdkPacketReadPoint(points[2], &end)) return nil;
                [path curveToPoint:end controlPoint1:control1 controlPoint2:control2];
                currentPoint = end;
            } else if ([verb isEqualToString:@"close"]) {
                if (!hasCurrentPoint) return nil;
                [path closePath];
                currentPoint = subpathStart;
            } else {
                return nil;
            }
        }
        return path;
    }
    if ([kind isEqualToString:@"rect"]) {
        return [NSBezierPath bezierPathWithRect:NativeSdkPacketRect(shape[@"rect"])];
    }
    if ([kind isEqualToString:@"rounded_rect"] || [kind isEqualToString:@"stroke_rect"]) {
        NSRect rect = NativeSdkPacketRect(shape[@"rect"]);
        return NativeSdkPacketRoundedRectPath(rect, shape[@"radius"]);
    }
    if ([kind isEqualToString:@"line"]) {
        NSBezierPath *path = [NSBezierPath bezierPath];
        [path moveToPoint:NativeSdkPacketPoint(shape[@"from"])];
        [path lineToPoint:NativeSdkPacketPoint(shape[@"to"])];
        path.lineWidth = MAX(1, NativeSdkPacketNumber(shape[@"width"], 1));
        return path;
    }
    return nil;
}

static BOOL NativeSdkPacketDrawPaintedPath(NSBezierPath *path, NSDictionary *paint, CGFloat opacity, BOOL stroke) {
    if (!path || !paint) return NO;
    NSString *kind = [paint[@"kind"] isKindOfClass:[NSString class]] ? paint[@"kind"] : @"";
    if ([kind isEqualToString:@"color"]) {
        NSColor *color = NativeSdkPacketColor(paint[@"color"], opacity);
        if (!color) return NO;
        if (stroke) {
            [color setStroke];
            [path stroke];
        } else {
            [color setFill];
            [path fill];
        }
        return YES;
    }
    if ([kind isEqualToString:@"linear_gradient"]) {
        NSArray *stops = NativeSdkPacketArray(paint[@"stops"], 1);
        if (!stops) return NO;
        NSUInteger count = MIN(stops.count, 16);
        NSMutableArray<NSColor *> *colors = [NSMutableArray arrayWithCapacity:count];
        CGFloat locations[16] = {0};
        for (NSUInteger index = 0; index < count; index++) {
            NSDictionary *stop = NativeSdkPacketDictionary(stops[index]);
            if (!stop) return NO;
            NSColor *color = NativeSdkPacketColor(stop[@"color"], opacity);
            if (!color) return NO;
            [colors addObject:color];
            locations[index] = fmax(0.0, fmin(1.0, NativeSdkPacketNumber(stop[@"offset"], (CGFloat)index / (CGFloat)MAX(1, count - 1))));
        }
        if (stroke) {
            [colors.firstObject setStroke];
            [path stroke];
            return YES;
        }
        NSGradient *gradient = [[NSGradient alloc] initWithColors:colors atLocations:locations colorSpace:NSColorSpace.deviceRGBColorSpace];
        if (!gradient) return NO;
        [NSGraphicsContext saveGraphicsState];
        [path addClip];
        [gradient drawFromPoint:NativeSdkPacketPoint(paint[@"start"]) toPoint:NativeSdkPacketPoint(paint[@"end"]) options:0];
        [NSGraphicsContext restoreGraphicsState];
        return YES;
    }
    return NO;
}

static NSPoint NativeSdkPacketTransformPoint(id value, NSPoint point) {
    NSArray *array = NativeSdkPacketArray(value, 6);
    if (!array) return point;
    CGFloat a = NativeSdkPacketNumber(array[0], 1);
    CGFloat b = NativeSdkPacketNumber(array[1], 0);
    CGFloat c = NativeSdkPacketNumber(array[2], 0);
    CGFloat d = NativeSdkPacketNumber(array[3], 1);
    CGFloat tx = NativeSdkPacketNumber(array[4], 0);
    CGFloat ty = NativeSdkPacketNumber(array[5], 0);
    return NSMakePoint(a * point.x + c * point.y + tx, b * point.x + d * point.y + ty);
}

static NSRect NativeSdkPacketTransformRect(id value, NSRect rect) {
    NSArray *array = NativeSdkPacketArray(value, 6);
    if (!array) return rect;
    rect = CGRectStandardize(rect);
    NSPoint points[4] = {
        NativeSdkPacketTransformPoint(array, NSMakePoint(NSMinX(rect), NSMinY(rect))),
        NativeSdkPacketTransformPoint(array, NSMakePoint(NSMaxX(rect), NSMinY(rect))),
        NativeSdkPacketTransformPoint(array, NSMakePoint(NSMaxX(rect), NSMaxY(rect))),
        NativeSdkPacketTransformPoint(array, NSMakePoint(NSMinX(rect), NSMaxY(rect))),
    };
    CGFloat minX = points[0].x;
    CGFloat maxX = points[0].x;
    CGFloat minY = points[0].y;
    CGFloat maxY = points[0].y;
    for (NSUInteger index = 1; index < 4; index++) {
        minX = fmin(minX, points[index].x);
        maxX = fmax(maxX, points[index].x);
        minY = fmin(minY, points[index].y);
        maxY = fmax(maxY, points[index].y);
    }
    return NSMakeRect(minX, minY, maxX - minX, maxY - minY);
}

static CGFloat NativeSdkPacketTransformScale(id value) {
    NSArray *array = NativeSdkPacketArray(value, 6);
    if (!array) return 1;
    CGFloat a = NativeSdkPacketNumber(array[0], 1);
    CGFloat b = NativeSdkPacketNumber(array[1], 0);
    CGFloat c = NativeSdkPacketNumber(array[2], 0);
    CGFloat d = NativeSdkPacketNumber(array[3], 1);
    CGFloat xScale = sqrt(a * a + b * b);
    CGFloat yScale = sqrt(c * c + d * d);
    return fmax(0.0001, fmax(xScale, yScale));
}

static BOOL NativeSdkPacketApplyBlur(NSDictionary *effect, CGFloat opacity, CGContextRef context, CGFloat scale, id transformValue, BOOL hasClip, NSRect clipRect) {
    if (!effect || !context) return NO;
    void *contextData = CGBitmapContextGetData(context);
    if (!contextData) return NO;
    const size_t width = CGBitmapContextGetWidth(context);
    const size_t height = CGBitmapContextGetHeight(context);
    const size_t bytesPerRow = CGBitmapContextGetBytesPerRow(context);
    if (width == 0 || height == 0 || bytesPerRow < width * 4) return NO;

    NSRect rect = CGRectStandardize(NativeSdkPacketTransformRect(transformValue, NativeSdkPacketRect(effect[@"rect"])));
    if (hasClip) {
        rect = NSIntersectionRect(rect, clipRect);
    }
    if (NSIsEmptyRect(rect)) return YES;

    CGFloat normalizedScale = scale > 0 ? scale : 1;
    CGFloat minXFloat = floor(NSMinX(rect) * normalizedScale);
    CGFloat minYFloat = floor(NSMinY(rect) * normalizedScale);
    CGFloat maxXFloat = ceil(NSMaxX(rect) * normalizedScale);
    CGFloat maxYFloat = ceil(NSMaxY(rect) * normalizedScale);
    minXFloat = fmax(0.0, fmin((CGFloat)width, minXFloat));
    minYFloat = fmax(0.0, fmin((CGFloat)height, minYFloat));
    maxXFloat = fmax(minXFloat, fmin((CGFloat)width, maxXFloat));
    maxYFloat = fmax(minYFloat, fmin((CGFloat)height, maxYFloat));

    NSUInteger minX = (NSUInteger)minXFloat;
    NSUInteger minY = (NSUInteger)minYFloat;
    NSUInteger maxX = (NSUInteger)maxXFloat;
    NSUInteger maxY = (NSUInteger)maxYFloat;
    if (maxX <= minX || maxY <= minY) return YES;

    NSUInteger radius = (NSUInteger)llround(fmax(0.0, NativeSdkPacketNumber(effect[@"radius"], 0) * normalizedScale * NativeSdkPacketTransformScale(transformValue)));
    radius = MIN(radius, (NSUInteger)64);
    if (radius == 0) return YES;
    CGFloat mix = fmax(0.0, fmin(1.0, opacity));
    if (mix <= 0) return YES;

    NSUInteger expandedMinX = minX > radius ? minX - radius : 0;
    NSUInteger expandedMaxX = MIN((NSUInteger)width, maxX + radius);
    NSUInteger expandedMinY = minY > radius ? minY - radius : 0;
    NSUInteger expandedMaxY = MIN((NSUInteger)height, maxY + radius);
    if (expandedMaxX <= expandedMinX || expandedMaxY <= expandedMinY) return YES;

    NSUInteger regionWidth = expandedMaxX - expandedMinX;
    NSUInteger regionHeight = expandedMaxY - expandedMinY;
    size_t regionBytesPerRow = regionWidth * 4;
    size_t regionByteLength = regionBytesPerRow * regionHeight;
    NSMutableData *sourceData = [NSMutableData dataWithLength:regionByteLength];
    NSMutableData *horizontalData = [NSMutableData dataWithLength:regionByteLength];
    if (!sourceData || !horizontalData) return NO;
    uint8_t *destination = (uint8_t *)contextData;
    uint8_t *source = (uint8_t *)sourceData.mutableBytes;
    uint8_t *horizontal = (uint8_t *)horizontalData.mutableBytes;
    for (NSUInteger row = 0; row < regionHeight; row++) {
        memcpy(
            source + row * regionBytesPerRow,
            destination + (expandedMinY + row) * bytesPerRow + expandedMinX * 4,
            regionBytesPerRow
        );
    }

    /* Both passes keep the ORIGINAL clamped-window box average — the
     * window shrinks at the surface edges exactly as before — but slide
     * the window incrementally (add the entering sample, subtract the
     * leaving one), turning O(region x radius) into O(region). The sums
     * are the same integers the per-pixel rescan produced, so the output
     * is byte-identical; a full-window dirty pass that repaints a
     * backdrop-blurred popover stops costing milliseconds of scalar
     * resampling. */
    for (NSUInteger y = expandedMinY; y < expandedMaxY; y++) {
        const uint8_t *sourceRow = source + (y - expandedMinY) * regionBytesPerRow;
        uint8_t *horizontalRow = horizontal + (y - expandedMinY) * regionBytesPerRow;
        NSUInteger windowMinX = minX > radius ? minX - radius : 0;
        NSUInteger windowMaxX = MIN((NSUInteger)width - 1, minX + radius);
        uint64_t sums[4] = {0, 0, 0, 0};
        for (NSUInteger sx = windowMinX; sx <= windowMaxX; sx++) {
            const uint8_t *pixel = sourceRow + (sx - expandedMinX) * 4;
            sums[0] += pixel[0];
            sums[1] += pixel[1];
            sums[2] += pixel[2];
            sums[3] += pixel[3];
        }
        for (NSUInteger x = minX; x < maxX; x++) {
            NSUInteger sampleMinX = x > radius ? x - radius : 0;
            NSUInteger sampleMaxX = MIN((NSUInteger)width - 1, x + radius);
            while (windowMaxX < sampleMaxX) {
                windowMaxX += 1;
                const uint8_t *pixel = sourceRow + (windowMaxX - expandedMinX) * 4;
                sums[0] += pixel[0];
                sums[1] += pixel[1];
                sums[2] += pixel[2];
                sums[3] += pixel[3];
            }
            while (windowMinX < sampleMinX) {
                const uint8_t *pixel = sourceRow + (windowMinX - expandedMinX) * 4;
                sums[0] -= pixel[0];
                sums[1] -= pixel[1];
                sums[2] -= pixel[2];
                sums[3] -= pixel[3];
                windowMinX += 1;
            }
            NSUInteger count = sampleMaxX - sampleMinX + 1;
            uint8_t *out = horizontalRow + (x - expandedMinX) * 4;
            out[0] = (uint8_t)(sums[0] / count);
            out[1] = (uint8_t)(sums[1] / count);
            out[2] = (uint8_t)(sums[2] / count);
            out[3] = (uint8_t)(sums[3] / count);
        }
    }

    for (NSUInteger x = minX; x < maxX; x++) {
        const uint8_t *horizontalColumn = horizontal + (x - expandedMinX) * 4;
        NSUInteger windowMinY = minY > radius ? minY - radius : 0;
        NSUInteger windowMaxY = MIN((NSUInteger)height - 1, minY + radius);
        uint64_t sums[4] = {0, 0, 0, 0};
        for (NSUInteger sy = windowMinY; sy <= windowMaxY; sy++) {
            const uint8_t *pixel = horizontalColumn + (sy - expandedMinY) * regionBytesPerRow;
            sums[0] += pixel[0];
            sums[1] += pixel[1];
            sums[2] += pixel[2];
            sums[3] += pixel[3];
        }
        for (NSUInteger y = minY; y < maxY; y++) {
            NSUInteger sampleMinY = y > radius ? y - radius : 0;
            NSUInteger sampleMaxY = MIN((NSUInteger)height - 1, y + radius);
            while (windowMaxY < sampleMaxY) {
                windowMaxY += 1;
                const uint8_t *pixel = horizontalColumn + (windowMaxY - expandedMinY) * regionBytesPerRow;
                sums[0] += pixel[0];
                sums[1] += pixel[1];
                sums[2] += pixel[2];
                sums[3] += pixel[3];
            }
            while (windowMinY < sampleMinY) {
                const uint8_t *pixel = horizontalColumn + (windowMinY - expandedMinY) * regionBytesPerRow;
                sums[0] -= pixel[0];
                sums[1] -= pixel[1];
                sums[2] -= pixel[2];
                sums[3] -= pixel[3];
                windowMinY += 1;
            }
            NSUInteger count = sampleMaxY - sampleMinY + 1;
            uint8_t *out = destination + y * bytesPerRow + x * 4;
            for (NSUInteger channel = 0; channel < 4; channel++) {
                CGFloat blurred = (CGFloat)(sums[channel] / count);
                CGFloat original = (CGFloat)source[(y - expandedMinY) * regionBytesPerRow + (x - expandedMinX) * 4 + channel];
                out[channel] = (uint8_t)llround(original + (blurred - original) * mix);
            }
        }
    }
    return YES;
}

static NSLineBreakMode NativeSdkPacketTextLineBreakMode(NSString *wrap) {
    if ([wrap isEqualToString:@"none"]) return NSLineBreakByClipping;
    if ([wrap isEqualToString:@"character"]) return NSLineBreakByCharWrapping;
    return NSLineBreakByWordWrapping;
}

static NSTextAlignment NativeSdkPacketTextAlignment(NSString *align) {
    if ([align isEqualToString:@"center"]) return NSTextAlignmentCenter;
    if ([align isEqualToString:@"end"]) return NSTextAlignmentRight;
    return NSTextAlignmentNatural;
}

// Italicizes a resolved sans face for the reserved italic span font ids
// (5 and 6). Prefers a real italic face from the same family via
// NSFontManager (SF has one; Geist does not ship a sans italic), and falls
// back to a sheared font matrix so the slant is always visible. The shear
// leaves advance widths unchanged, keeping measured layout in step with the
// upright face the estimator models.
static NSFont *NativeSdkItalicSansFont(NSFont *font) {
    if (!font) return nil;
    NSFontManager *manager = [NSFontManager sharedFontManager];
    NSFont *converted = [manager convertFont:font toHaveTrait:NSItalicFontMask];
    if (converted && ([manager traitsOfFont:converted] & NSItalicFontMask) != 0) return converted;
    CGFloat size = font.pointSize;
    NSAffineTransform *transform = [NSAffineTransform transform];
    NSAffineTransformStruct shear = { size, 0, size * 0.2, size, 0, 0 };
    transform.transformStruct = shear;
    NSFont *oblique = [NSFont fontWithDescriptor:font.fontDescriptor textTransform:transform];
    return oblique ?: font;
}

// Resolves the weighted sans faces behind the reserved span font ids 3
// (medium) and 4/6 (bold): explicit weighted candidate names first (Geist
// Medium / Geist Bold when installed), then an NSFontManager family
// conversion from the resolved regular face, then the matching SF weight.
// Never answers with the regular face — a weighted span id that draws at
// regular weight is invisible, which defeats the id.
static NSFont *NativeSdkWeightedSansFont(NSArray<NSString *> *names, NSFont *base, NSFontWeight systemWeight, BOOL bold, CGFloat size) {
    for (NSString *name in names) {
        NSFont *font = [NSFont fontWithName:name size:size];
        if (font) return font;
    }
    NSFontManager *manager = [NSFontManager sharedFontManager];
    NSString *family = base.familyName;
    if (family) {
        NSFont *converted = [manager fontWithFamily:family traits:(bold ? NSBoldFontMask : 0) weight:(bold ? 9 : 6) size:size];
        if (converted) {
            BOOL heavier = bold ? ([manager traitsOfFont:converted] & NSBoldFontMask) != 0
                                : [manager weightOfFont:converted] > [manager weightOfFont:base];
            if (heavier) return converted;
        }
    }
    return [NSFont systemFontOfSize:size weight:systemWeight];
}

// Runtime-registered font faces (the engine's canvas font registry,
// pushed through native_sdk_appkit_register_font before any layout can
// reference the id): parsed CTFontDescriptors keyed by canvas font id,
// plus a per-(id, size) NSFont cache. One table guards both with
// @synchronized because registration arrives on the runtime loop thread
// while packet drawing and measurement resolve on the main thread.
static NSMutableDictionary<NSNumber *, id> *NativeSdkRegisteredFontDescriptors(void) {
    static NSMutableDictionary<NSNumber *, id> *table = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [[NSMutableDictionary alloc] init];
    });
    return table;
}

// The registered face for a canvas font id at `size`, or nil when the id
// has no registered face. Checked BEFORE the built-in candidates and
// their cache so a registered id can never be masked by a font resolved
// for that id earlier (ids are engine-validated and permanent, so cached
// NSFonts here never go stale).
static NSFont *NativeSdkRegisteredFontForId(unsigned long long value, CGFloat size) {
    NSMutableDictionary<NSNumber *, id> *table = NativeSdkRegisteredFontDescriptors();
    static NSMutableDictionary<NSString *, NSFont *> *sizeCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sizeCache = [[NSMutableDictionary alloc] init];
    });
    @synchronized (table) {
        id descriptorObject = table[@(value)];
        if (!descriptorObject) return nil;
        NSString *key = [NSString stringWithFormat:@"%llu/%.3f", value, (double)size];
        NSFont *cached = sizeCache[key];
        if (cached) return cached;
        CTFontRef created = CTFontCreateWithFontDescriptor((__bridge CTFontDescriptorRef)descriptorObject, size, NULL);
        if (!created) return nil;
        NSFont *font = (__bridge_transfer NSFont *)created;
        sizeCache[key] = font;
        return font;
    }
}

// Engine-validated TrueType bytes for a registered canvas font id: parse
// them into a font descriptor once and key it by id, so measurement and
// packet text drawing resolve the id to this exact face. Returns 1 on
// success, 0 when CoreText rejects the data — the engine already parsed
// the face, so a rejection here is surfaced as a loud registration
// error engine-side, never a silent fallback at draw time.
int native_sdk_appkit_register_font(uint64_t font_id, const uint8_t *bytes, size_t bytes_len) {
    if (font_id == 0 || !bytes || bytes_len == 0) return 0;
    @autoreleasepool {
        NSData *data = [NSData dataWithBytes:bytes length:bytes_len];
        CTFontDescriptorRef descriptor = CTFontManagerCreateFontDescriptorFromData((__bridge CFDataRef)data);
        if (!descriptor) return 0;
        NSMutableDictionary<NSNumber *, id> *table = NativeSdkRegisteredFontDescriptors();
        @synchronized (table) {
            table[@(font_id)] = (__bridge_transfer id)descriptor;
        }
        return 1;
    }
}

// Resolves a canvas font id to the NSFont presentation draws with. Both
// packet text drawing and native_sdk_appkit_measure_text go through this
// single function so measured layout and drawn glyphs share font
// resolution. Ids 3-6 are the reserved sans span variants (medium, bold,
// italic, bold italic); everything else keeps the regular sans/mono
// candidates. Registered faces win first (see above). Resolved
// built-in fonts are cached per (font id, size).
static NSFont *NativeSdkFontForFontId(unsigned long long value, CGFloat size) {
    NSFont *registered = NativeSdkRegisteredFontForId(value, size);
    if (registered) return registered;
    static NSCache<NSString *, NSFont *> *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 256;
    });
    NSString *key = [NSString stringWithFormat:@"%llu/%.3f", value, (double)size];
    NSFont *cached = [cache objectForKey:key];
    if (cached) return cached;
    NSFont *font = nil;
    if (value == 2) {
        NSArray<NSString *> *candidates = @[ @"Geist Mono", @"GeistMono-Regular", @"Geist Mono Regular" ];
        for (NSString *name in candidates) {
            font = [NSFont fontWithName:name size:size];
            if (font) break;
        }
        if (!font) font = [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
    } else {
        NSArray<NSString *> *candidates = @[ @"Geist", @"Geist-Regular", @"Geist Sans", @"Geist Sans Regular" ];
        NSFont *base = nil;
        for (NSString *name in candidates) {
            base = [NSFont fontWithName:name size:size];
            if (base) break;
        }
        if (!base) base = [NSFont systemFontOfSize:size];
        switch (value) {
        case 3:
            font = NativeSdkWeightedSansFont(@[ @"Geist-Medium", @"Geist Medium" ], base, NSFontWeightMedium, NO, size);
            break;
        case 4:
            font = NativeSdkWeightedSansFont(@[ @"Geist-Bold", @"Geist Bold" ], base, NSFontWeightBold, YES, size);
            break;
        case 5:
            font = NativeSdkItalicSansFont(base);
            break;
        case 6:
            font = NativeSdkItalicSansFont(NativeSdkWeightedSansFont(@[ @"Geist-Bold", @"Geist Bold" ], base, NSFontWeightBold, YES, size));
            break;
        default:
            font = base;
            break;
        }
    }
    if (font) [cache setObject:font forKey:key];
    return font;
}

static NSFont *NativeSdkPacketPreferredFont(NSDictionary *text, CGFloat size) {
    NSNumber *fontId = [text[@"font"] isKindOfClass:[NSNumber class]] ? text[@"font"] : nil;
    unsigned long long value = fontId ? fontId.unsignedLongLongValue : 1;
    return NativeSdkFontForFontId(value, size);
}

// Typographic width of a single-line run, measured with the same font
// resolution and string-attribute metrics ([NSString sizeWithAttributes:])
// the packet renderer draws with. Returns a negative value when the bytes
// are not valid UTF-8 so the caller can fall back to its estimator.
// Shaped widths are memoized host-side.
double native_sdk_appkit_measure_text(uint64_t font_id, double size, const char *text, size_t text_len) {
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
        NSFont *font = NativeSdkFontForFontId(font_id, clamped);
        if (!font) return -1;
        double width = [value sizeWithAttributes:@{ NSFontAttributeName : font }].width;
        [widthCache setObject:@(width) forKey:key];
        return width;
    }
}

// Batched per-cluster advances for a single-line run: one CTLine over
// the whole run (the same attributed-string shaping the width above
// summarizes), glyph advances accumulated onto the UTF-16 character
// each glyph belongs to, then folded onto UTF-8 cluster lead bytes.
// Kerning and ligatures ride the glyph advances: a ligature's whole
// advance lands on its first cluster and the swallowed clusters hold 0,
// so cumulative widths stay honest at every cluster boundary. One host
// call per text run replaces one measure_text round-trip per cluster of
// every growing line prefix — the engine caches the batch, so a run is
// typically shaped here once per content change, not once per frame.
int native_sdk_appkit_measure_text_advances(uint64_t font_id, double size, const char *text, size_t text_len, float *advances) {
    if (!text || text_len == 0 || !advances) return 0;
    CGFloat clamped = MAX(1, size);
    @autoreleasepool {
        NSString *value = [[NSString alloc] initWithBytes:text length:text_len encoding:NSUTF8StringEncoding];
        if (!value) return 0;
        NSFont *font = NativeSdkFontForFontId(font_id, clamped);
        if (!font) return 0;
        NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:value
                                                                         attributes:@{ NSFontAttributeName : font }];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);
        if (!line) return 0;

        // Per-UTF-16-unit accumulation. UTF-16 length never exceeds the
        // UTF-8 byte length (1-3 byte sequences map to one unit, 4-byte
        // sequences to two), so text_len bounds the buffer.
        NSUInteger utf16_len = value.length;
        double *unit_advances = calloc(utf16_len > 0 ? utf16_len : 1, sizeof(double));
        if (!unit_advances) {
            CFRelease(line);
            return 0;
        }
        CFArrayRef runs = CTLineGetGlyphRuns(line);
        CFIndex run_count = runs ? CFArrayGetCount(runs) : 0;
        for (CFIndex run_index = 0; run_index < run_count; run_index++) {
            CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, run_index);
            CFIndex glyph_count = CTRunGetGlyphCount(run);
            CGSize advance_chunk[64];
            CFIndex index_chunk[64];
            for (CFIndex start = 0; start < glyph_count; start += 64) {
                CFIndex chunk = MIN(64, glyph_count - start);
                CTRunGetAdvances(run, CFRangeMake(start, chunk), advance_chunk);
                CTRunGetStringIndices(run, CFRangeMake(start, chunk), index_chunk);
                for (CFIndex glyph = 0; glyph < chunk; glyph++) {
                    CFIndex string_index = index_chunk[glyph];
                    if (string_index >= 0 && (NSUInteger)string_index < utf16_len) {
                        unit_advances[string_index] += advance_chunk[glyph].width;
                    }
                }
            }
        }
        CFRelease(line);

        // Fold UTF-16 unit advances onto UTF-8 cluster lead bytes. The
        // walks stay in lockstep because NSString accepted the bytes as
        // valid UTF-8: 1-3 byte clusters own one UTF-16 unit, 4-byte
        // clusters own a surrogate pair (two units).
        size_t byte_index = 0;
        NSUInteger unit_index = 0;
        while (byte_index < text_len) {
            unsigned char lead = (unsigned char)text[byte_index];
            size_t cluster_bytes = (lead & 0x80) == 0 ? 1
                : (lead & 0xE0) == 0xC0               ? 2
                : (lead & 0xF0) == 0xE0               ? 3
                : (lead & 0xF8) == 0xF0               ? 4
                                                      : 1;
            if (cluster_bytes > text_len - byte_index) cluster_bytes = text_len - byte_index;
            NSUInteger cluster_units = cluster_bytes == 4 ? 2 : 1;
            double total = 0;
            for (NSUInteger unit = 0; unit < cluster_units && unit_index + unit < utf16_len; unit++) {
                total += unit_advances[unit_index + unit];
            }
            for (size_t offset = 1; offset < cluster_bytes; offset++) {
                advances[byte_index + offset] = 0;
            }
            advances[byte_index] = (float)total;
            unit_index += cluster_units;
            byte_index += cluster_bytes;
        }
        free(unit_advances);
        return 1;
    }
}

// Platform image decoder: CGImageSource (ImageIO) handles PNG, JPEG, and
// every other codec the OS ships — the framework bundles none. The image
// draws into a premultiplied RGBA8 bitmap context (the only RGBA layout
// CGBitmapContext can render into) and is un-premultiplied in place,
// because the canvas image pipeline — the reference renderer and the
// packet host's kCGImageAlphaLast upload — expects straight alpha.
int native_sdk_appkit_decode_image(const uint8_t *bytes, size_t bytes_len, uint8_t *pixels, size_t pixels_len, size_t *out_width, size_t *out_height) {
    if (out_width) *out_width = 0;
    if (out_height) *out_height = 0;
    if (!bytes || bytes_len == 0 || !pixels) return 0;
    @autoreleasepool {
        NSData *data = [NSData dataWithBytesNoCopy:(void *)bytes length:bytes_len freeWhenDone:NO];
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (!source) return 0;
        CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
        if (!image) return 0;

        size_t width = CGImageGetWidth(image);
        size_t height = CGImageGetHeight(image);
        if (width == 0 || height == 0 || width > 8192 || height > 8192) {
            CGImageRelease(image);
            return 0;
        }
        if (out_width) *out_width = width;
        if (out_height) *out_height = height;
        size_t byte_len = width * height * 4;
        if (byte_len / 4 / height != width || pixels_len < byte_len) {
            CGImageRelease(image);
            return -1;
        }

        CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
        if (!color_space) {
            CGImageRelease(image);
            return 0;
        }
        CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, width * 4, color_space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(color_space);
        if (!context) {
            CGImageRelease(image);
            return 0;
        }
        memset(pixels, 0, byte_len);
        CGContextSetBlendMode(context, kCGBlendModeCopy);
        CGContextDrawImage(context, CGRectMake(0, 0, (CGFloat)width, (CGFloat)height), image);
        CGContextRelease(context);
        CGImageRelease(image);

        // Un-premultiply: round to nearest so opaque pixels survive exactly.
        for (size_t offset = 0; offset < byte_len; offset += 4) {
            uint8_t alpha = pixels[offset + 3];
            if (alpha == 0) {
                pixels[offset + 0] = 0;
                pixels[offset + 1] = 0;
                pixels[offset + 2] = 0;
            } else if (alpha != 255) {
                pixels[offset + 0] = (uint8_t)MIN(255, ((size_t)pixels[offset + 0] * 255 + alpha / 2) / alpha);
                pixels[offset + 1] = (uint8_t)MIN(255, ((size_t)pixels[offset + 1] * 255 + alpha / 2) / alpha);
                pixels[offset + 2] = (uint8_t)MIN(255, ((size_t)pixels[offset + 2] * 255 + alpha / 2) / alpha);
            }
        }
        return 1;
    }
}

static BOOL NativeSdkPacketDrawText(NSDictionary *text, CGFloat opacity) {
    if (!text) return NO;
    NSString *value = [text[@"text"] isKindOfClass:[NSString class]] ? text[@"text"] : @"";
    NSColor *color = NativeSdkPacketColor(text[@"color"], opacity);
    if (!color) return NO;
    CGFloat size = MAX(1, NativeSdkPacketNumber(text[@"size"], 12));
    NSFont *font = NativeSdkPacketPreferredFont(text, size);
    NSPoint origin = NativeSdkPacketPoint(text[@"origin"]);
    NSDictionary *baseAttributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
    };
    NSDictionary *layout = NativeSdkPacketDictionary(text[@"layout"]);
    if (!layout) {
        [value drawAtPoint:NSMakePoint(origin.x, origin.y - size) withAttributes:baseAttributes];
        return YES;
    }

    // Engine-measured line breaks: the packet carries the exact lines the
    // layout already broke the text into (the same breaks the reference
    // renderer draws and intrinsic sizing measured), so draw them verbatim.
    // Re-breaking here with AppKit's own line breaker disagreed with the
    // engine on tight boxes and wrapped single-line labels mid-word.
    // Wrap, alignment, line height, and max width are all baked into
    // each line's text slice and pen position.
    NSArray *packetLines = [text[@"lines"] isKindOfClass:[NSArray class]] ? text[@"lines"] : nil;
    if (packetLines) {
        for (id lineObject in packetLines) {
            NSDictionary *line = NativeSdkPacketDictionary(lineObject);
            if (!line) return NO;
            NSString *lineText = [line[@"text"] isKindOfClass:[NSString class]] ? line[@"text"] : @"";
            if (lineText.length == 0) continue;
            CGFloat lineX = NativeSdkPacketNumber(line[@"x"], origin.x);
            CGFloat baseline = NativeSdkPacketNumber(line[@"baseline"], origin.y);
            [lineText drawAtPoint:NSMakePoint(lineX, baseline - size) withAttributes:baseAttributes];
        }
        return YES;
    }

    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    NSString *wrap = [layout[@"wrap"] isKindOfClass:[NSString class]] ? layout[@"wrap"] : @"word";
    NSString *align = [layout[@"align"] isKindOfClass:[NSString class]] ? layout[@"align"] : @"start";
    paragraph.lineBreakMode = NativeSdkPacketTextLineBreakMode(wrap);
    paragraph.alignment = NativeSdkPacketTextAlignment(align);
    CGFloat lineHeight = NativeSdkPacketNumber(layout[@"lineHeight"], 0);
    if (lineHeight > 0) {
        paragraph.minimumLineHeight = lineHeight;
        paragraph.maximumLineHeight = lineHeight;
    }

    NSMutableDictionary *attributes = [baseAttributes mutableCopy];
    attributes[NSParagraphStyleAttributeName] = paragraph;
    CGFloat maxWidth = NativeSdkPacketNumber(layout[@"maxWidth"], 0);
    CGFloat measuredWidth = ceil([value sizeWithAttributes:attributes].width + size);
    CGFloat textWidth = maxWidth > 0 ? maxWidth : MAX(size, measuredWidth);
    CGFloat textHeight = MAX(lineHeight > 0 ? lineHeight : size * 1.25, size * 1.25);
    NSRect measuredRect = [value boundingRectWithSize:NSMakeSize(textWidth, CGFLOAT_MAX)
                                             options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                          attributes:attributes];
    textHeight = MAX(textHeight, ceil(measuredRect.size.height + 1));
    [value drawWithRect:NSMakeRect(origin.x, origin.y - size, textWidth, textHeight)
                options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
             attributes:attributes];
    return YES;
}

static BOOL NativeSdkPacketDrawEffect(NSDictionary *effect, CGFloat opacity, CGContextRef context, CGFloat scale, id transformValue, BOOL hasClip, NSRect clipRect) {
    if (!effect) return NO;
    NSString *kind = [effect[@"kind"] isKindOfClass:[NSString class]] ? effect[@"kind"] : @"";
    if ([kind isEqualToString:@"blur"]) {
        return NativeSdkPacketApplyBlur(effect, opacity, context, scale, transformValue, hasClip, clipRect);
    }
    if ([kind isEqualToString:@"shadow"]) {
        NSColor *color = NativeSdkPacketColor(effect[@"color"], opacity);
        if (!color) return NO;
        NSRect rect = NativeSdkPacketRect(effect[@"rect"]);
        NSArray *offset = NativeSdkPacketArray(effect[@"offset"], 2);
        NSSize shadowOffset = offset ? NSMakeSize(NativeSdkPacketNumber(offset[0], 0), NativeSdkPacketNumber(offset[1], 0)) : NSZeroSize;
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowColor = color;
        shadow.shadowOffset = shadowOffset;
        shadow.shadowBlurRadius = MAX(0, NativeSdkPacketNumber(effect[@"blur"], 0));
        NSBezierPath *path = NativeSdkPacketRoundedRectPath(rect, effect[@"radius"]);
        [NSGraphicsContext saveGraphicsState];
        [shadow set];
        [[color colorWithAlphaComponent:0.01] setFill];
        [path fill];
        [NSGraphicsContext restoreGraphicsState];
        return YES;
    }
    return NO;
}

static BOOL NativeSdkPacketApplyTransform(id value) {
    NSArray *array = NativeSdkPacketArray(value, 6);
    if (!array) return YES;
    NSAffineTransformStruct transform = {
        .m11 = NativeSdkPacketNumber(array[0], 1),
        .m12 = NativeSdkPacketNumber(array[1], 0),
        .m21 = NativeSdkPacketNumber(array[2], 0),
        .m22 = NativeSdkPacketNumber(array[3], 1),
        .tX = NativeSdkPacketNumber(array[4], 0),
        .tY = NativeSdkPacketNumber(array[5], 0),
    };
    NSAffineTransform *affine = [NSAffineTransform transform];
    [affine setTransformStruct:transform];
    [affine concat];
    return YES;
}

static NSString *NativeSdkPacketImageCacheKey(id value) {
    if (![value respondsToSelector:@selector(unsignedLongLongValue)]) return nil;
    return [NSString stringWithFormat:@"%llu", [value unsignedLongLongValue]];
}

static NSRect NativeSdkPacketNormalizedRect(NSRect rect) {
    if (rect.size.width < 0) {
        rect.origin.x += rect.size.width;
        rect.size.width = -rect.size.width;
    }
    if (rect.size.height < 0) {
        rect.origin.y += rect.size.height;
        rect.size.height = -rect.size.height;
    }
    return rect;
}

static NSData *NativeSdkPacketImagePixelData(NSArray *pixels, NSUInteger byteLength) {
    if (!pixels || pixels.count < byteLength) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:byteLength];
    if (!data) return nil;
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger index = 0; index < byteLength; index++) {
        bytes[index] = (uint8_t)llround(fmax(0.0, fmin(255.0, NativeSdkPacketNumber(pixels[index], 0))));
    }
    return data;
}

// Wrap tightly packed, straight-alpha RGBA8 pixel bytes as an NSImage
// (kCGImageAlphaLast — the same convention the decode seam produces and
// the reference renderer consumes). `pixelData` is retained by the
// CGDataProvider, so callers may pass transient copies.
static NSImage *NativeSdkCreateRGBA8Image(NSUInteger width, NSUInteger height, NSData *pixelData) {
    if (width == 0 || height == 0 || width > 8192 || height > 8192) return nil;
    if (width > NSUIntegerMax / height || width * height > NSUIntegerMax / 4) return nil;
    NSUInteger byteLength = width * height * 4;
    if (!pixelData || pixelData.length != byteLength) return nil;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (!colorSpace) return nil;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixelData);
    if (!provider) {
        CGColorSpaceRelease(colorSpace);
        return nil;
    }
    CGImageRef cgImage = CGImageCreate(width, height, 8, 32, width * 4, colorSpace, kCGImageAlphaLast | kCGBitmapByteOrder32Big, provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
    if (!cgImage) return nil;
    NSImage *result = [[NSImage alloc] initWithCGImage:cgImage size:NSMakeSize((CGFloat)width, (CGFloat)height)];
    CGImageRelease(cgImage);
    return result;
}

// Legacy packet-embedded pixels: packets from this tree never carry pixel
// payloads anymore (the binary upload side-channel owns them), but a
// packet that does include them still decodes.
static NSImage *NativeSdkPacketCreateImage(NSDictionary *image) {
    if (!image) return nil;
    NSUInteger width = (NSUInteger)llround(NativeSdkPacketNumber(image[@"width"], 0));
    NSUInteger height = (NSUInteger)llround(NativeSdkPacketNumber(image[@"height"], 0));
    if (width == 0 || height == 0) return nil;
    if (width > NSUIntegerMax / height || width * height > NSUIntegerMax / 4) return nil;
    NSUInteger byteLength = width * height * 4;
    NSData *pixelData = NativeSdkPacketImagePixelData(NativeSdkPacketArray(image[@"pixels"], byteLength), byteLength);
    return NativeSdkCreateRGBA8Image(width, height, pixelData);
}

// Apply the packet's image cache actions onto the view's cache, resolving
// upload pixels from the host-wide side-channel store (uploaded through
// `native_sdk_appkit_upload_gpu_surface_image` before the packet was
// presented). Evictions run FIRST so an id re-registered under a new
// content fingerprint (upload of the new key + evict of the old key in
// one packet) keeps its freshly uploaded image — the per-view cache is
// keyed by image id. An upload whose id has no store entry (and no legacy
// embedded pixels) is an ABSENT resource — "not registered (yet/anymore)"
// is a legitimate transient state — so the cache entry is dropped and
// draws referencing the id skip, exactly like the CPU reference renderer.
static BOOL NativeSdkPacketApplyImageActions(NSArray *actions, NSArray *images, NSMutableDictionary<NSString *, NSImage *> *imageCache, NSDictionary<NSString *, NSImage *> *imageStore) {
    if (!imageCache) return NO;
    for (id actionObject in actions ?: @[]) {
        NSDictionary *action = NativeSdkPacketDictionary(actionObject);
        if (!action) return NO;
        NSString *kind = [action[@"kind"] isKindOfClass:[NSString class]] ? action[@"kind"] : @"";
        if ([kind isEqualToString:@"evict"]) {
            NSDictionary *key = NativeSdkPacketDictionary(action[@"key"]);
            NSString *cacheKey = NativeSdkPacketImageCacheKey(key[@"imageId"]);
            if (cacheKey) [imageCache removeObjectForKey:cacheKey];
        } else if (![kind isEqualToString:@"upload"] && ![kind isEqualToString:@"retain"]) {
            return NO;
        }
    }
    for (id actionObject in actions ?: @[]) {
        NSDictionary *action = NativeSdkPacketDictionary(actionObject);
        NSString *kind = [action[@"kind"] isKindOfClass:[NSString class]] ? action[@"kind"] : @"";
        if (![kind isEqualToString:@"upload"]) continue;
        NSInteger imageIndex = [action[@"imageIndex"] respondsToSelector:@selector(integerValue)] ? [action[@"imageIndex"] integerValue] : -1;
        if (imageIndex < 0 || (NSUInteger)imageIndex >= images.count) return NO;
        NSDictionary *image = NativeSdkPacketDictionary(images[(NSUInteger)imageIndex]);
        NSString *cacheKey = NativeSdkPacketImageCacheKey(image[@"imageId"]);
        if (!cacheKey) return NO;
        NSImage *resolved = imageStore ? imageStore[cacheKey] : nil;
        if (!resolved) resolved = NativeSdkPacketCreateImage(image);
        if (resolved) {
            imageCache[cacheKey] = resolved;
        } else {
            [imageCache removeObjectForKey:cacheKey];
        }
    }
    return YES;
}

static NSRect NativeSdkPacketImageSourceRect(NSDictionary *packetImage, NSImage *image) {
    NSRect full = NSMakeRect(0, 0, image.size.width, image.size.height);
    NSArray *src = NativeSdkPacketArray(packetImage[@"src"], 4);
    if (!src) return full;
    NSRect requested = NativeSdkPacketNormalizedRect(NativeSdkPacketRect(src));
    NSRect clipped = NSIntersectionRect(requested, full);
    return clipped;
}

static NSRect NativeSdkPacketImageDestinationRect(NSRect dst, NSRect src, NSString *fit) {
    NSRect normalized = NativeSdkPacketNormalizedRect(dst);
    if (normalized.size.width <= 0 || normalized.size.height <= 0 || src.size.width <= 0 || src.size.height <= 0) return NSZeroRect;
    if (![fit isEqualToString:@"contain"] && ![fit isEqualToString:@"cover"]) return normalized;

    CGFloat srcAspect = src.size.width / src.size.height;
    CGFloat dstAspect = normalized.size.width / normalized.size.height;
    CGFloat width = normalized.size.width;
    CGFloat height = normalized.size.height;
    if ([fit isEqualToString:@"contain"]) {
        if (dstAspect > srcAspect) {
            height = normalized.size.height;
            width = height * srcAspect;
        } else {
            width = normalized.size.width;
            height = width / srcAspect;
        }
    } else {
        if (dstAspect > srcAspect) {
            width = normalized.size.width;
            height = width / srcAspect;
        } else {
            height = normalized.size.height;
            width = height * srcAspect;
        }
    }

    return NSMakeRect(normalized.origin.x + (normalized.size.width - width) * 0.5, normalized.origin.y + (normalized.size.height - height) * 0.5, width, height);
}

static BOOL NativeSdkPacketDrawImage(NSDictionary *packetImage, NSDictionary<NSString *, NSImage *> *imageCache, CGFloat opacity) {
    if (!packetImage || !imageCache) return NO;
    NSString *cacheKey = NativeSdkPacketImageCacheKey(packetImage[@"image"]);
    if (!cacheKey) return NO;
    NSImage *image = imageCache[cacheKey];
    // Absent image: the id is not registered (yet/anymore) — a legitimate
    // transient state (avatar mid-fetch, LRU-evicted id in a stale tree).
    // Skip the draw exactly like the CPU reference renderer instead of
    // failing the whole packet back to the software pixel path.
    if (!image) return YES;
    NSRect src = NativeSdkPacketImageSourceRect(packetImage, image);
    if (src.size.width <= 0 || src.size.height <= 0) return NO;
    NSString *fit = [packetImage[@"fit"] isKindOfClass:[NSString class]] ? packetImage[@"fit"] : @"stretch";
    NSRect dst = NativeSdkPacketImageDestinationRect(NativeSdkPacketRect(packetImage[@"dst"]), src, fit);
    if (dst.size.width <= 0 || dst.size.height <= 0) return NO;

    CGFloat imageOpacity = fmax(0.0, fmin(1.0, NativeSdkPacketNumber(packetImage[@"opacity"], 1)));
    NSString *sampling = [packetImage[@"sampling"] isKindOfClass:[NSString class]] ? packetImage[@"sampling"] : @"linear";
    [NSGraphicsContext saveGraphicsState];
    /* Rounded-corner mask over the REQUESTED destination (the widget
     * frame) — the avatar circle clip; a `cover` fit expands `dst`, so
     * the mask uses the packet's original dst rect. */
    NSArray *radius = NativeSdkPacketArray(packetImage[@"radius"], 4);
    if (radius) {
        CGFloat maxCorner = 0;
        for (NSUInteger index = 0; index < 4; index += 1) {
            maxCorner = fmax(maxCorner, NativeSdkPacketNumber(radius[index], 0));
        }
        if (maxCorner > 0) {
            [NativeSdkPacketRoundedRectPath(NativeSdkPacketRect(NativeSdkPacketArray(packetImage[@"dst"], 4)), packetImage[@"radius"]) addClip];
        }
    }
    [NSGraphicsContext.currentContext setImageInterpolation:[sampling isEqualToString:@"nearest"] ? NSImageInterpolationNone : NSImageInterpolationHigh];
    [image drawInRect:dst fromRect:src operation:NSCompositingOperationSourceOver fraction:(opacity * imageOpacity) respectFlipped:YES hints:nil];
    [NSGraphicsContext restoreGraphicsState];
    return YES;
}

static BOOL NativeSdkPacketDrawCommandBody(NSDictionary *command, NSString *kind, CGFloat opacity, CGContextRef context, CGFloat scale, BOOL hasEffectiveClip, NSRect effectiveClip, NSDictionary<NSString *, NSImage *> *imageCache);

static BOOL NativeSdkPacketDrawCommand(NSDictionary *command, CGContextRef context, CGFloat scale, BOOL hasClip, NSRect clipRect, NSDictionary<NSString *, NSImage *> *imageCache) {
    if (!command) return NO;
    if (hasClip) {
        NSArray *bounds = NativeSdkPacketArray(command[@"bounds"], 4);
        if (bounds && !NativeSdkPacketRectIntersects(NativeSdkPacketRect(bounds), clipRect)) return YES;
    }

    NSString *kind = [command[@"kind"] isKindOfClass:[NSString class]] ? command[@"kind"] : @"";
    CGFloat opacity = fmax(0.0, fmin(1.0, NativeSdkPacketNumber(command[@"opacity"], 1)));
    id clip = command[@"clip"];
    BOOL hasEffectiveClip = hasClip;
    NSRect effectiveClip = clipRect;

    [NSGraphicsContext saveGraphicsState];
    if (hasClip) {
        [NSBezierPath clipRect:clipRect];
    }
    if ([clip isKindOfClass:[NSArray class]]) {
        NSRect commandClip = NativeSdkPacketRect(clip);
        [NSBezierPath clipRect:commandClip];
        effectiveClip = hasEffectiveClip ? NSIntersectionRect(effectiveClip, commandClip) : commandClip;
        hasEffectiveClip = YES;
    }
    if (!NativeSdkPacketApplyTransform(command[@"transform"])) {
        [NSGraphicsContext restoreGraphicsState];
        return NO;
    }

    BOOL ok = NativeSdkPacketDrawCommandBody(command, kind, opacity, context, scale, hasEffectiveClip, effectiveClip, imageCache);

    [NSGraphicsContext restoreGraphicsState];
    return ok;
}

/* Kind dispatch shared by direct draws and raster-cache fills: expects
 * clip/transform state already applied to the current graphics context. */
static BOOL NativeSdkPacketDrawCommandBody(NSDictionary *command, NSString *kind, CGFloat opacity, CGContextRef context, CGFloat scale, BOOL hasEffectiveClip, NSRect effectiveClip, NSDictionary<NSString *, NSImage *> *imageCache) {
    BOOL ok = YES;
    if ([kind hasPrefix:@"fill_rect"] || [kind hasPrefix:@"fill_rounded_rect"]) {
        ok = NativeSdkPacketDrawPaintedPath(NativeSdkPacketShapePath(NativeSdkPacketDictionary(command[@"shape"])), NativeSdkPacketDictionary(command[@"paint"]), opacity, NO);
    } else if ([kind hasPrefix:@"stroke_rect"]) {
        NSBezierPath *path = NativeSdkPacketShapePath(NativeSdkPacketDictionary(command[@"shape"]));
        path.lineWidth = MAX(1, NativeSdkPacketNumber(command[@"strokeWidth"], path.lineWidth));
        ok = NativeSdkPacketDrawPaintedPath(path, NativeSdkPacketDictionary(command[@"paint"]), opacity, YES);
    } else if ([kind hasPrefix:@"draw_line"]) {
        ok = NativeSdkPacketDrawPaintedPath(NativeSdkPacketShapePath(NativeSdkPacketDictionary(command[@"shape"])), NativeSdkPacketDictionary(command[@"paint"]), opacity, YES);
    } else if ([kind isEqualToString:@"fill_path"]) {
        ok = NativeSdkPacketDrawPaintedPath(NativeSdkPacketShapePath(NativeSdkPacketDictionary(command[@"shape"])), NativeSdkPacketDictionary(command[@"paint"]), opacity, NO);
    } else if ([kind isEqualToString:@"stroke_path"]) {
        NSBezierPath *path = NativeSdkPacketShapePath(NativeSdkPacketDictionary(command[@"shape"]));
        path.lineWidth = MAX(1, NativeSdkPacketNumber(command[@"strokeWidth"], path.lineWidth));
        ok = NativeSdkPacketDrawPaintedPath(path, NativeSdkPacketDictionary(command[@"paint"]), opacity, YES);
    } else if ([kind isEqualToString:@"draw_text"]) {
        ok = NativeSdkPacketDrawText(NativeSdkPacketDictionary(command[@"text"]), opacity);
    } else if ([kind isEqualToString:@"shadow"] || [kind isEqualToString:@"blur"]) {
        ok = NativeSdkPacketDrawEffect(NativeSdkPacketDictionary(command[@"effect"]), opacity, context, scale, command[@"transform"], hasEffectiveClip, effectiveClip);
    } else if ([kind isEqualToString:@"draw_image"]) {
        ok = NativeSdkPacketDrawImage(NativeSdkPacketDictionary(command[@"image"]), imageCache, opacity);
    } else {
        ok = NO;
    }
    return ok;
}

/* Raster-cache budgets (house-budget style: fixed, deterministic). A
 * command whose pixel-aligned bounds exceed the per-entry cap draws
 * directly (a full-surface background fill is cheaper to paint than to
 * hold); the total cap evicts least-recently-used entries. */
enum {
    NativeSdkPacketRasterCacheMaxEntryBytes = 4 * 1024 * 1024,
    NativeSdkPacketRasterCacheMaxBytes = 64 * 1024 * 1024,
};

/* GPU composite mode (prototype, default OFF): packet presents composite
 * on the GPU — cached command rasters become textures drawn as quads by a
 * render command encoder targeting the canvas texture — instead of CPU
 * blits into the retained backing plus a texture upload. The CG path
 * stays byte-for-byte untouched while this is unset. */
static BOOL NativeSdkGpuCompositeEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *value = getenv("NATIVE_SDK_GPU_COMPOSITE");
        enabled = value && value[0] != 0 && strcmp(value, "0") != 0;
    });
    return enabled;
}

/* A command is raster-cacheable when its painted output is a pure
 * function of the command itself: no backdrop reads (blur samples the
 * pixels beneath it) and no animated transform (applied per frame via
 * the CTM). A command CLIP is a plain rect carried by the command, so
 * clipped output is still a pure function of the command — the fill
 * applies the clip and the raster extent shrinks to bounds∩clip.
 * (Clipped panel/scroll content dominates content-heavy views; leaving
 * it out forced a full CoreText re-raster of every clipped run on any
 * wide dirty rect.) A drawn image (fit, sampling, corner mask) is a
 * pure function of the command plus the registered pixels it references:
 * cache entries for draw_image are dropped whenever an image
 * upload/evict action lands, so a re-registered id re-rasterizes — and
 * caching the SCALED output turns the expensive per-present resample
 * (the dominant cost of image-heavy first frames) into a 1:1 blit. */
static BOOL NativeSdkPacketCommandRasterCacheable(NSDictionary *command, NSString *kind) {
    if (command[@"transform"]) return NO;
    if (command[@"clip"] && !NativeSdkPacketArray(command[@"clip"], 4)) return NO;
    if ([kind isEqualToString:@"draw_text"] || [kind isEqualToString:@"shadow"]) return YES;
    if ([kind hasPrefix:@"fill_rect"] || [kind hasPrefix:@"fill_rounded_rect"] || [kind hasPrefix:@"stroke_rect"] || [kind hasPrefix:@"draw_line"]) return YES;
    if ([kind isEqualToString:@"fill_path"] || [kind isEqualToString:@"stroke_path"]) return YES;
    if ([kind isEqualToString:@"draw_image"]) return YES;
    return NO;
}

/* Snap a point-space rect outward to the device-pixel grid and clamp it
 * to the surface. Integer-aligned clip edges keep the scissored redraw
 * byte-identical to a full redraw: a fractional clip edge antialiases,
 * blending fresh paint with retained pixels at the seam. */
static NSRect NativeSdkPacketAlignRectToPixels(NSRect rect, CGFloat scale, NSUInteger pixelWidth, NSUInteger pixelHeight) {
    rect = CGRectStandardize(rect);
    CGFloat minX = floor(NSMinX(rect) * scale);
    CGFloat minY = floor(NSMinY(rect) * scale);
    CGFloat maxX = ceil(NSMaxX(rect) * scale);
    CGFloat maxY = ceil(NSMaxY(rect) * scale);
    minX = fmax(0.0, fmin((CGFloat)pixelWidth, minX));
    minY = fmax(0.0, fmin((CGFloat)pixelHeight, minY));
    maxX = fmax(minX, fmin((CGFloat)pixelWidth, maxX));
    maxY = fmax(minY, fmin((CGFloat)pixelHeight, maxY));
    return NSMakeRect(minX / scale, minY / scale, (maxX - minX) / scale, (maxY - minY) / scale);
}

/* ---------------------------------------------------------------------------
 * Compact binary gpu-surface packet decoding (wire format v3).
 *
 * Little-endian, length-prefixed, mirror of the engine's binary packet
 * encoder (serialization.zig, `writeCanvasGpuPacketBinary` and the patch
 * writer in canvas_frame.zig). Both sides pin the layout and tag tables
 * independently: any disagreement makes a bounds-checked read fail here,
 * the present is refused (return 0), and the runtime records the refusal
 * and resyncs (full present, then its pixel fallback) — never garbage on
 * the glass. The decoder reconstructs the exact dictionary shape the JSON
 * path produces, so every draw function above serves both encodings
 * unchanged; v2 added a retained-state generation, a retain key per
 * command, and the `patch` load action carrying an edit script (evicts +
 * keyed upserts + the full draw-order vector) against the view's retained
 * command dictionary; v3 added the flag-gated dirty rect list after the
 * scissor. The version this comment names and the encoder's spec comment
 * must agree with `binary_packet_version` (serialization.zig); the
 * `test-wire-format-version-prose` build check pins all three.
 */

/* Retained commands per view; pins the engine's
 * `canvas_limits.max_canvas_retained_packet_commands_per_view`. A patch
 * that would grow the dictionary past this refuses (and drops the
 * retained state) so the engine resyncs with a full present — never a
 * partially applied edit script. */
enum { NativeSdkPacketRetainedCommandCap = 2048 };

typedef struct {
    const uint8_t *bytes;
    NSUInteger length;
    NSUInteger offset;
    BOOL failed;
} NativeSdkBinaryPacketReader;

static BOOL NativeSdkBinaryHasBytes(NativeSdkBinaryPacketReader *reader, NSUInteger count) {
    if (reader->failed || reader->length - reader->offset < count) {
        reader->failed = YES;
        return NO;
    }
    return YES;
}

static uint8_t NativeSdkBinaryReadU8(NativeSdkBinaryPacketReader *reader) {
    if (!NativeSdkBinaryHasBytes(reader, 1)) return 0;
    return reader->bytes[reader->offset++];
}

static uint32_t NativeSdkBinaryReadU32(NativeSdkBinaryPacketReader *reader) {
    if (!NativeSdkBinaryHasBytes(reader, 4)) return 0;
    uint32_t value = 0;
    memcpy(&value, reader->bytes + reader->offset, 4);
    reader->offset += 4;
    return CFSwapInt32LittleToHost(value);
}

static uint64_t NativeSdkBinaryReadU64(NativeSdkBinaryPacketReader *reader) {
    if (!NativeSdkBinaryHasBytes(reader, 8)) return 0;
    uint64_t value = 0;
    memcpy(&value, reader->bytes + reader->offset, 8);
    reader->offset += 8;
    return CFSwapInt64LittleToHost(value);
}

static CGFloat NativeSdkBinaryReadF32(NativeSdkBinaryPacketReader *reader) {
    uint32_t bits = NativeSdkBinaryReadU32(reader);
    float value = 0;
    memcpy(&value, &bits, 4);
    return (CGFloat)value;
}

static NSNumber *NativeSdkBinaryReadF32Number(NativeSdkBinaryPacketReader *reader) {
    return @(NativeSdkBinaryReadF32(reader));
}

/* n consecutive f32s as the NSNumber array shape the JSON parse yields
 * for rects (4), points (2), colors (4), radii (4), and affines (6). */
static NSArray *NativeSdkBinaryReadF32Array(NativeSdkBinaryPacketReader *reader, NSUInteger count) {
    NSMutableArray *values = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        [values addObject:NativeSdkBinaryReadF32Number(reader)];
    }
    return reader->failed ? nil : values;
}

static NSString *NativeSdkBinaryReadString(NativeSdkBinaryPacketReader *reader) {
    uint32_t length = NativeSdkBinaryReadU32(reader);
    if (!NativeSdkBinaryHasBytes(reader, length)) return nil;
    NSString *value = [[NSString alloc] initWithBytes:reader->bytes + reader->offset length:length encoding:NSUTF8StringEncoding];
    reader->offset += length;
    if (!value) reader->failed = YES;
    return value;
}

/* Stable wire codes for the command kind; must match the engine's
 * `binaryCommandKindCode` table. */
static NSString *NativeSdkBinaryCommandKindName(uint8_t code) {
    switch (code) {
    case 0: return @"fill_rect_solid";
    case 1: return @"fill_rect_gradient";
    case 2: return @"fill_rounded_rect_solid";
    case 3: return @"fill_rounded_rect_gradient";
    case 4: return @"stroke_rect_solid";
    case 5: return @"stroke_rect_gradient";
    case 6: return @"draw_line_solid";
    case 7: return @"draw_line_gradient";
    case 8: return @"fill_path";
    case 9: return @"stroke_path";
    case 10: return @"draw_image";
    case 11: return @"draw_text";
    case 12: return @"shadow";
    case 13: return @"blur";
    default: return nil;
    }
}

static NSDictionary *NativeSdkBinaryReadShape(NativeSdkBinaryPacketReader *reader) {
    uint8_t tag = NativeSdkBinaryReadU8(reader);
    switch (tag) {
    case 1: {
        NSArray *rect = NativeSdkBinaryReadF32Array(reader, 4);
        if (!rect) return nil;
        return @{ @"kind" : @"rect", @"rect" : rect };
    }
    case 2: {
        NSArray *rect = NativeSdkBinaryReadF32Array(reader, 4);
        NSArray *radius = NativeSdkBinaryReadF32Array(reader, 4);
        if (!rect || !radius) return nil;
        return @{ @"kind" : @"rounded_rect", @"rect" : rect, @"radius" : radius };
    }
    case 3: {
        NSArray *rect = NativeSdkBinaryReadF32Array(reader, 4);
        NSArray *radius = NativeSdkBinaryReadF32Array(reader, 4);
        NSNumber *width = NativeSdkBinaryReadF32Number(reader);
        if (!rect || !radius || reader->failed) return nil;
        return @{ @"kind" : @"stroke_rect", @"rect" : rect, @"radius" : radius, @"width" : width };
    }
    case 4: {
        NSArray *from = NativeSdkBinaryReadF32Array(reader, 2);
        NSArray *to = NativeSdkBinaryReadF32Array(reader, 2);
        NSNumber *width = NativeSdkBinaryReadF32Number(reader);
        if (!from || !to || reader->failed) return nil;
        return @{ @"kind" : @"line", @"from" : from, @"to" : to, @"width" : width };
    }
    case 5: {
        uint32_t elementCount = NativeSdkBinaryReadU32(reader);
        /* Each element carries at least its verb byte; a count past the
         * remaining bytes is a corrupt packet, refused before any
         * allocation grows around it. */
        if (reader->failed || elementCount > reader->length - reader->offset) {
            reader->failed = YES;
            return nil;
        }
        NSMutableArray *elements = [NSMutableArray arrayWithCapacity:elementCount];
        for (uint32_t index = 0; index < elementCount; index++) {
            uint8_t verbCode = NativeSdkBinaryReadU8(reader);
            NSString *verb = nil;
            NSUInteger pointCount = 0;
            switch (verbCode) {
            case 0: verb = @"move_to"; pointCount = 1; break;
            case 1: verb = @"line_to"; pointCount = 1; break;
            case 2: verb = @"quad_to"; pointCount = 2; break;
            case 3: verb = @"cubic_to"; pointCount = 3; break;
            case 4: verb = @"close"; pointCount = 0; break;
            default: reader->failed = YES; return nil;
            }
            NSMutableArray *points = [NSMutableArray arrayWithCapacity:pointCount];
            for (NSUInteger pointIndex = 0; pointIndex < pointCount; pointIndex++) {
                NSArray *point = NativeSdkBinaryReadF32Array(reader, 2);
                if (!point) return nil;
                [points addObject:point];
            }
            [elements addObject:@{ @"verb" : verb, @"points" : points }];
        }
        return @{ @"kind" : @"path", @"path" : elements };
    }
    default:
        reader->failed = YES;
        return nil;
    }
}

static NSDictionary *NativeSdkBinaryReadPaint(NativeSdkBinaryPacketReader *reader) {
    uint8_t tag = NativeSdkBinaryReadU8(reader);
    switch (tag) {
    case 1: {
        NSArray *color = NativeSdkBinaryReadF32Array(reader, 4);
        if (!color) return nil;
        return @{ @"kind" : @"color", @"color" : color };
    }
    case 2: {
        NSArray *start = NativeSdkBinaryReadF32Array(reader, 2);
        NSArray *end = NativeSdkBinaryReadF32Array(reader, 2);
        uint32_t stopCount = NativeSdkBinaryReadU32(reader);
        if (reader->failed || stopCount > reader->length - reader->offset) {
            reader->failed = YES;
            return nil;
        }
        NSMutableArray *stops = [NSMutableArray arrayWithCapacity:stopCount];
        for (uint32_t index = 0; index < stopCount; index++) {
            NSNumber *offset = NativeSdkBinaryReadF32Number(reader);
            NSArray *color = NativeSdkBinaryReadF32Array(reader, 4);
            if (!color) return nil;
            [stops addObject:@{ @"offset" : offset, @"color" : color }];
        }
        if (!start || !end) return nil;
        return @{ @"kind" : @"linear_gradient", @"start" : start, @"end" : end, @"stops" : stops };
    }
    default:
        reader->failed = YES;
        return nil;
    }
}

static NSDictionary *NativeSdkBinaryReadImage(NativeSdkBinaryPacketReader *reader) {
    uint64_t imageId = NativeSdkBinaryReadU64(reader);
    uint8_t hasSrc = NativeSdkBinaryReadU8(reader);
    NSArray *src = hasSrc ? NativeSdkBinaryReadF32Array(reader, 4) : nil;
    NSArray *dst = NativeSdkBinaryReadF32Array(reader, 4);
    NSNumber *opacity = NativeSdkBinaryReadF32Number(reader);
    uint8_t fitCode = NativeSdkBinaryReadU8(reader);
    uint8_t samplingCode = NativeSdkBinaryReadU8(reader);
    NSArray *radius = NativeSdkBinaryReadF32Array(reader, 4);
    if (reader->failed || !dst || !radius || (hasSrc && !src)) return nil;
    NSString *fit = fitCode == 1 ? @"contain" : (fitCode == 2 ? @"cover" : @"stretch");
    NSString *sampling = samplingCode == 0 ? @"nearest" : @"linear";
    NSMutableDictionary *image = [NSMutableDictionary dictionaryWithDictionary:@{
        @"image" : @(imageId),
        @"dst" : dst,
        @"opacity" : opacity,
        @"fit" : fit,
        @"sampling" : sampling,
        @"radius" : radius,
    }];
    if (src) image[@"src"] = src;
    return image;
}

static NSDictionary *NativeSdkBinaryReadText(NativeSdkBinaryPacketReader *reader) {
    uint64_t fontId = NativeSdkBinaryReadU64(reader);
    NSNumber *size = NativeSdkBinaryReadF32Number(reader);
    NSArray *origin = NativeSdkBinaryReadF32Array(reader, 2);
    NSArray *color = NativeSdkBinaryReadF32Array(reader, 4);
    NSString *text = NativeSdkBinaryReadString(reader);
    if (reader->failed || !origin || !color || !text) return nil;
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:@{
        @"font" : @(fontId),
        @"size" : size,
        @"origin" : origin,
        @"color" : color,
        @"text" : text,
    }];
    uint8_t hasLayout = NativeSdkBinaryReadU8(reader);
    if (reader->failed) return nil;
    if (!hasLayout) return result;

    NSNumber *maxWidth = NativeSdkBinaryReadF32Number(reader);
    NSNumber *lineHeight = NativeSdkBinaryReadF32Number(reader);
    uint8_t wrapCode = NativeSdkBinaryReadU8(reader);
    uint8_t alignCode = NativeSdkBinaryReadU8(reader);
    if (reader->failed) return nil;
    NSString *wrap = wrapCode == 0 ? @"none" : (wrapCode == 2 ? @"character" : @"word");
    NSString *align = alignCode == 1 ? @"center" : (alignCode == 2 ? @"end" : @"start");
    result[@"layout"] = @{ @"maxWidth" : maxWidth, @"lineHeight" : lineHeight, @"wrap" : wrap, @"align" : align };

    uint8_t hasLines = NativeSdkBinaryReadU8(reader);
    if (reader->failed) return nil;
    /* No measured lines = the run exceeded the engine's line budget;
     * omitting the key keeps the host's legacy wrapping fallback, same
     * as JSON's "lines":null. */
    if (!hasLines) return result;
    uint32_t lineCount = NativeSdkBinaryReadU32(reader);
    if (reader->failed || lineCount > reader->length - reader->offset) {
        reader->failed = YES;
        return nil;
    }
    NSMutableArray *lines = [NSMutableArray arrayWithCapacity:lineCount];
    for (uint32_t index = 0; index < lineCount; index++) {
        NSNumber *x = NativeSdkBinaryReadF32Number(reader);
        NSNumber *baseline = NativeSdkBinaryReadF32Number(reader);
        NSString *lineText = NativeSdkBinaryReadString(reader);
        if (reader->failed || !lineText) return nil;
        [lines addObject:@{ @"x" : x, @"baseline" : baseline, @"text" : lineText }];
    }
    result[@"lines"] = lines;
    return result;
}

static NSDictionary *NativeSdkBinaryReadEffect(NativeSdkBinaryPacketReader *reader) {
    uint8_t tag = NativeSdkBinaryReadU8(reader);
    switch (tag) {
    case 1: {
        NSArray *rect = NativeSdkBinaryReadF32Array(reader, 4);
        NSArray *radius = NativeSdkBinaryReadF32Array(reader, 4);
        NSArray *offset = NativeSdkBinaryReadF32Array(reader, 2);
        NSNumber *blur = NativeSdkBinaryReadF32Number(reader);
        NSNumber *spread = NativeSdkBinaryReadF32Number(reader);
        NSArray *color = NativeSdkBinaryReadF32Array(reader, 4);
        if (reader->failed || !rect || !radius || !offset || !color) return nil;
        return @{ @"kind" : @"shadow", @"rect" : rect, @"radius" : radius, @"offset" : offset, @"blur" : blur, @"spread" : spread, @"color" : color };
    }
    case 2: {
        NSArray *rect = NativeSdkBinaryReadF32Array(reader, 4);
        NSNumber *radius = NativeSdkBinaryReadF32Number(reader);
        if (reader->failed || !rect) return nil;
        return @{ @"kind" : @"blur", @"rect" : rect, @"radius" : radius };
    }
    default:
        reader->failed = YES;
        return nil;
    }
}

/* Command flag bits; must match the engine's binary_command_flag_* set. */
enum {
    NativeSdkBinaryCommandFlagId = 0x01,
    NativeSdkBinaryCommandFlagClip = 0x02,
    NativeSdkBinaryCommandFlagTransform = 0x04,
    NativeSdkBinaryCommandFlagShape = 0x08,
    NativeSdkBinaryCommandFlagPaint = 0x10,
    NativeSdkBinaryCommandFlagImage = 0x20,
    NativeSdkBinaryCommandFlagText = 0x40,
    NativeSdkBinaryCommandFlagEffect = 0x80,
};

static NSDictionary *NativeSdkBinaryReadCommand(NativeSdkBinaryPacketReader *reader) {
    uint8_t kindCode = NativeSdkBinaryReadU8(reader);
    uint8_t flags = NativeSdkBinaryReadU8(reader);
    NSString *kind = NativeSdkBinaryCommandKindName(kindCode);
    NSArray *bounds = NativeSdkBinaryReadF32Array(reader, 4);
    NSNumber *opacity = NativeSdkBinaryReadF32Number(reader);
    NSNumber *strokeWidth = NativeSdkBinaryReadF32Number(reader);
    if (reader->failed || !kind || !bounds) {
        reader->failed = YES;
        return nil;
    }
    NSMutableDictionary *command = [NSMutableDictionary dictionaryWithDictionary:@{
        @"kind" : kind,
        @"bounds" : bounds,
        @"opacity" : opacity,
        @"strokeWidth" : strokeWidth,
    }];
    if (flags & NativeSdkBinaryCommandFlagId) command[@"id"] = @(NativeSdkBinaryReadU64(reader));
    if (flags & NativeSdkBinaryCommandFlagClip) {
        NSArray *clip = NativeSdkBinaryReadF32Array(reader, 4);
        if (!clip) return nil;
        command[@"clip"] = clip;
    }
    if (flags & NativeSdkBinaryCommandFlagTransform) {
        NSArray *transform = NativeSdkBinaryReadF32Array(reader, 6);
        if (!transform) return nil;
        command[@"transform"] = transform;
    }
    if (flags & NativeSdkBinaryCommandFlagShape) {
        NSDictionary *shape = NativeSdkBinaryReadShape(reader);
        if (!shape) return nil;
        command[@"shape"] = shape;
    }
    if (flags & NativeSdkBinaryCommandFlagPaint) {
        NSDictionary *paint = NativeSdkBinaryReadPaint(reader);
        if (!paint) return nil;
        command[@"paint"] = paint;
    }
    if (flags & NativeSdkBinaryCommandFlagImage) {
        NSDictionary *image = NativeSdkBinaryReadImage(reader);
        if (!image) return nil;
        command[@"image"] = image;
    }
    if (flags & NativeSdkBinaryCommandFlagText) {
        NSDictionary *text = NativeSdkBinaryReadText(reader);
        if (!text) return nil;
        command[@"text"] = text;
    }
    if (flags & NativeSdkBinaryCommandFlagEffect) {
        NSDictionary *effect = NativeSdkBinaryReadEffect(reader);
        if (!effect) return nil;
        command[@"effect"] = effect;
    }
    return reader->failed ? nil : command;
}

/* Decode a whole binary packet into the exact dictionary shape the JSON
 * parse produces, so the shared present path serves both encodings.
 * Full presents additionally carry @"generation" and @"commandKeys" (an
 * NSNumber per command, parallel to @"commands"); patch presents carry
 * @"generation", @"patchEvicts" (keys), @"patchUpserts" (pairs of
 * @"key" + @"command"), and @"patchOrder" (keys). Returns nil on any
 * framing violation (bad magic, unknown version or tag, truncated
 * payload, trailing bytes). */
static NSDictionary *NativeSdkPacketDictionaryFromBinary(const uint8_t *bytes, NSUInteger length) {
    if (!bytes || length < 16) return nil;
    NativeSdkBinaryPacketReader reader = { .bytes = bytes, .length = length, .offset = 0, .failed = NO };
    if (memcmp(bytes, "NSGP", 4) != 0) return nil;
    reader.offset = 4;
    uint8_t version = NativeSdkBinaryReadU8(&reader);
    if (version != 3) return nil;
    uint8_t loadActionCode = NativeSdkBinaryReadU8(&reader);
    uint8_t packetFlags = NativeSdkBinaryReadU8(&reader);
    (void)NativeSdkBinaryReadU8(&reader); /* reserved */
    uint64_t generation = NativeSdkBinaryReadU64(&reader);
    BOOL isPatch = loadActionCode == 3;
    NSString *loadAction = loadActionCode == 1 ? @"load" : (loadActionCode == 2 ? @"clear" : (isPatch ? @"patch" : nil));
    if (!loadAction || reader.failed) return nil;

    NSMutableDictionary *packet = [NSMutableDictionary dictionaryWithDictionary:@{ @"loadAction" : loadAction, @"generation" : @(generation) }];
    if (packetFlags & 0x01) {
        NSArray *scissor = NativeSdkBinaryReadF32Array(&reader, 4);
        if (!scissor) return nil;
        packet[@"scissorBounds"] = scissor;
    }
    if (packetFlags & 0x02) {
        /* v3 dirty rect list: the exact rects the edit script touches,
         * each inside the scissor (their union). */
        if (!(packetFlags & 0x01)) return nil;
        uint32_t dirtyRectCount = NativeSdkBinaryReadU32(&reader);
        if (reader.failed || dirtyRectCount == 0 || dirtyRectCount > 8) return nil;
        NSMutableArray *dirtyRects = [NSMutableArray arrayWithCapacity:dirtyRectCount];
        for (uint32_t index = 0; index < dirtyRectCount; index++) {
            NSArray *rect = NativeSdkBinaryReadF32Array(&reader, 4);
            if (!rect) return nil;
            [dirtyRects addObject:rect];
        }
        packet[@"dirtyRects"] = dirtyRects;
    }

    uint32_t imageCount = NativeSdkBinaryReadU32(&reader);
    if (reader.failed || imageCount > reader.length - reader.offset) return nil;
    NSMutableArray *images = [NSMutableArray arrayWithCapacity:imageCount];
    for (uint32_t index = 0; index < imageCount; index++) {
        uint64_t imageId = NativeSdkBinaryReadU64(&reader);
        uint64_t fingerprint = NativeSdkBinaryReadU64(&reader);
        uint32_t width = NativeSdkBinaryReadU32(&reader);
        uint32_t height = NativeSdkBinaryReadU32(&reader);
        if (reader.failed) return nil;
        [images addObject:@{ @"imageId" : @(imageId), @"fingerprint" : @(fingerprint), @"width" : @(width), @"height" : @(height) }];
    }
    packet[@"images"] = images;

    uint32_t actionCount = NativeSdkBinaryReadU32(&reader);
    if (reader.failed || actionCount > reader.length - reader.offset) return nil;
    NSMutableArray *actions = [NSMutableArray arrayWithCapacity:actionCount];
    for (uint32_t index = 0; index < actionCount; index++) {
        uint8_t kindCode = NativeSdkBinaryReadU8(&reader);
        uint64_t keyImageId = NativeSdkBinaryReadU64(&reader);
        uint64_t keyFingerprint = NativeSdkBinaryReadU64(&reader);
        uint32_t imageIndex = NativeSdkBinaryReadU32(&reader);
        if (reader.failed) return nil;
        NSString *kind = kindCode == 0 ? @"upload" : (kindCode == 1 ? @"retain" : (kindCode == 2 ? @"evict" : nil));
        if (!kind) return nil;
        NSMutableDictionary *action = [NSMutableDictionary dictionaryWithDictionary:@{
            @"kind" : kind,
            @"key" : @{ @"imageId" : @(keyImageId), @"fingerprint" : @(keyFingerprint) },
        }];
        if (imageIndex != 0xFFFFFFFFu) action[@"imageIndex"] = @(imageIndex);
        [actions addObject:action];
    }
    packet[@"imageActions"] = actions;

    if (isPatch) {
        uint32_t evictCount = NativeSdkBinaryReadU32(&reader);
        if (reader.failed || evictCount > reader.length - reader.offset) return nil;
        NSMutableArray *evicts = [NSMutableArray arrayWithCapacity:evictCount];
        for (uint32_t index = 0; index < evictCount; index++) {
            uint64_t key = NativeSdkBinaryReadU64(&reader);
            if (reader.failed) return nil;
            [evicts addObject:@(key)];
        }
        packet[@"patchEvicts"] = evicts;

        uint32_t upsertCount = NativeSdkBinaryReadU32(&reader);
        if (reader.failed || upsertCount > reader.length - reader.offset) return nil;
        NSMutableArray *upserts = [NSMutableArray arrayWithCapacity:upsertCount];
        for (uint32_t index = 0; index < upsertCount; index++) {
            uint64_t key = NativeSdkBinaryReadU64(&reader);
            NSDictionary *command = NativeSdkBinaryReadCommand(&reader);
            if (!command) return nil;
            [upserts addObject:@{ @"key" : @(key), @"command" : command }];
        }
        packet[@"patchUpserts"] = upserts;

        uint32_t orderCount = NativeSdkBinaryReadU32(&reader);
        if (reader.failed || orderCount > reader.length - reader.offset) return nil;
        NSMutableArray *order = [NSMutableArray arrayWithCapacity:orderCount];
        for (uint32_t index = 0; index < orderCount; index++) {
            uint64_t key = NativeSdkBinaryReadU64(&reader);
            if (reader.failed) return nil;
            [order addObject:@(key)];
        }
        packet[@"patchOrder"] = order;
    } else {
        uint32_t commandCount = NativeSdkBinaryReadU32(&reader);
        if (reader.failed || commandCount > reader.length - reader.offset) return nil;
        NSMutableArray *commands = [NSMutableArray arrayWithCapacity:commandCount];
        NSMutableArray *commandKeys = [NSMutableArray arrayWithCapacity:commandCount];
        for (uint32_t index = 0; index < commandCount; index++) {
            uint64_t key = NativeSdkBinaryReadU64(&reader);
            NSDictionary *command = NativeSdkBinaryReadCommand(&reader);
            if (!command) return nil;
            [commandKeys addObject:@(key)];
            [commands addObject:command];
        }
        packet[@"commands"] = commands;
        packet[@"commandKeys"] = commandKeys;
    }

    /* Trailing bytes mean the encoder and decoder disagree about the
     * layout — refuse rather than trust a partial parse. */
    if (reader.failed || reader.offset != reader.length) return nil;
    return packet;
}

@implementation NativeSdkScrollDriverDocumentView

- (BOOL)isFlipped {
    return YES;
}

@end

@implementation NativeSdkScrollDriverView

- (NSView *)hitTest:(NSPoint)point {
    // Scroll-wheel events route to the driver through the ordinary hit
    // test so AppKit's own (responsive) scrolling machinery handles them
    // — a programmatically forwarded scrollWheel: is ignored by that
    // path. Everything else passes through to the canvas beneath, except
    // the overlay scrollers themselves (the knob stays grabbable).
    NSView *hit = [super hitTest:point];
    if (!hit) return nil;
    NSEvent *current = NSApp.currentEvent;
    if (current && current.type == NSEventTypeScrollWheel) return hit;
    NSView *candidate = hit;
    while (candidate && candidate != self) {
        if ([candidate isKindOfClass:[NSScroller class]]) return hit;
        candidate = candidate.superview;
    }
    return nil;
}

@end

@implementation NativeSdkContextMenuTarget

- (void)contextMenuItemClicked:(NSMenuItem *)item {
    NSNumber *value = item.representedObject;
    if ([value isKindOfClass:[NSNumber class]]) self.selectedItemId = value.unsignedIntValue;
}

@end

@implementation NativeSdkMetalSurfaceView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;

    _device = MTLCreateSystemDefaultDevice();
    if (!_device) return self;

    _commandQueue = [_device newCommandQueue];
    _metalLayer = [CAMetalLayer layer];
    _metalLayer.device = _device;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _metalLayer.framebufferOnly = NO;
    _metalLayer.opaque = YES;
    _metalLayer.contentsGravity = kCAGravityTopLeft;
    // No nextDrawable timeout: with the timeout allowed (the default), a
    // non-composited window's starved pool makes nextDrawable stall a full
    // second per frame before returning nil. Disallowing it means
    // nextDrawable BLOCKS until a drawable is free — which is why frame
    // completion events are paced to the display interval (see
    // scheduleFrameEventEmission): a paced loop keeps pool
    // slack so the block is momentary. Occluded windows that do return a
    // nil drawable take the retained-completion path in renderFrame.
    _metalLayer.allowsNextDrawableTimeout = NO;

    self.wantsLayer = YES;
    self.layer = _metalLayer;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;
    self.accessibilityRole = NSAccessibilityGroupRole;
    _surfaceCursor = [NSCursor arrowCursor];
    _canvasImageCache = [NSMutableDictionary dictionary];
    self.markedText = @"";
    self.markedTextRange = NSMakeRange(NSNotFound, 0);
    self.selectedTextRange = NSMakeRange(0, 0);

    [self updateDrawableSize];
    // Common modes: default-mode timers stall inside AppKit tracking
    // runloops (live window resize, menu tracking), freezing frames for
    // the whole gesture.
    _displayTimer = [NSTimer timerWithTimeInterval:(1.0 / 60.0) target:self selector:@selector(renderFrame) userInfo:nil repeats:YES];
    _displayTimer.tolerance = 1.0 / 240.0;
    [[NSRunLoop mainRunLoop] addTimer:_displayTimer forMode:NSRunLoopCommonModes];
    [self renderFrame];
    return self;
}

- (void)configureWithHost:(NativeSdkAppKitHost *)host windowId:(uint64_t)windowId label:(NSString *)label {
    self.host = host;
    self.windowId = windowId;
    self.surfaceLabel = label ?: @"";
    __weak NativeSdkMetalSurfaceView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NativeSdkMetalSurfaceView *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf updateDrawableSize];
        [strongSelf emitResizeEvent];
        [strongSelf renderFrame];
    });
}

- (void)dealloc {
    [self stopDisplayTimer];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (self.canvasColorSpace) {
        CGColorSpaceRelease(self.canvasColorSpace);
        self.canvasColorSpace = NULL;
    }
}

- (NSArray *)accessibilityChildren {
    return self.widgetAccessibilityElements ?: @[];
}

- (BOOL)isAvailable {
    return self.device != nil && self.commandQueue != nil && self.metalLayer != nil;
}

- (BOOL)isOpaque {
    return YES;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    self.window.acceptsMouseMovedEvents = YES;
    [self updateDrawableSize];
    [self updateSurfaceTrackingArea];
    // Re-present retained content once the window is composited again
    // after occlusion: frames completed logically while occluded
    // (renderFrame's nil-drawable path) still owe the glass their
    // latest retained pixels.
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidChangeOcclusionStateNotification object:nil];
    if (self.window) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowOcclusionStateChanged:)
                                                     name:NSWindowDidChangeOcclusionStateNotification
                                                   object:self.window];
    }
}

- (void)windowOcclusionStateChanged:(NSNotification *)notification {
    NSWindow *window = notification.object;
    if (window != self.window) return;
    if ((window.occlusionState & NSWindowOcclusionStateVisible) == 0) return;
    // De-occlusion restores full cadence without dropping a beat: an
    // armed channel may have its one emission parked on the heartbeat
    // (up to a second out). The queued block cannot be cancelled, so
    // supersede it — the last emit is at least a heartbeat old, so the
    // replacement's display-grid delay computes to zero and it fires on
    // the next queue turn.
    [self rescheduleParkedFrameEventEmission];
    if (!self.glassFlushPending) return;
    [self renderFrame];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self updateDrawableSize];
}

- (void)setFrame:(NSRect)frame {
    [super setFrame:frame];
    [self updateDrawableSize];
}

- (void)setBounds:(NSRect)bounds {
    [super setBounds:bounds];
    [self updateDrawableSize];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    [self updateSurfaceTrackingArea];
}

- (void)updateSurfaceTrackingArea {
    if (self.surfaceTrackingArea) {
        [self removeTrackingArea:self.surfaceTrackingArea];
        self.surfaceTrackingArea = nil;
    }
    if (!self.window) return;

    NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited |
                                    NSTrackingMouseMoved |
                                    NSTrackingActiveInKeyWindow |
                                    NSTrackingInVisibleRect;
    self.surfaceTrackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                            options:options
                                                              owner:self
                                                           userInfo:nil];
    [self addTrackingArea:self.surfaceTrackingArea];
}

- (void)updateDrawableSize {
    if (!self.metalLayer) return;
    CGFloat scale = self.window.backingScaleFactor;
    if (scale <= 0) scale = NSScreen.mainScreen.backingScaleFactor;
    if (scale <= 0) scale = 1;
    NSSize size = self.bounds.size;
    CGSize drawableSize = CGSizeMake(MAX(1.0, ceil(size.width * scale)), MAX(1.0, ceil(size.height * scale)));
    BOOL changed = fabs(self.lastDrawableSize.width - drawableSize.width) > 0.5 ||
        fabs(self.lastDrawableSize.height - drawableSize.height) > 0.5 ||
        fabs(self.lastScale - scale) > 0.001;
    self.metalLayer.contentsScale = scale;
    self.metalLayer.drawableSize = drawableSize;
    self.lastDrawableSize = drawableSize;
    self.lastScale = scale;
    if (changed) {
        [self emitResizeEvent];
        [self requestRetainedCanvasFrame];
    }
}

- (BOOL)presentPixelsWithWidth:(NSUInteger)width height:(NSUInteger)height scale:(CGFloat)scale hasDirtyRect:(BOOL)hasDirtyRect dirtyX:(CGFloat)dirtyX dirtyY:(CGFloat)dirtyY dirtyWidth:(CGFloat)dirtyWidth dirtyHeight:(CGFloat)dirtyHeight dirtyRects:(NSArray<NSValue *> *)dirtyRects rgba8:(const uint8_t *)rgba8 byteLength:(NSUInteger)byteLength {
    if (![self isAvailable] || !rgba8 || width == 0 || height == 0) return NO;
    if (byteLength != width * height * 4) return NO;
    if (![self ensureCanvasPresenter]) return NO;

    BOOL textureChanged = NO;
    if (!self.canvasTexture || self.canvasTextureWidth != width || self.canvasTextureHeight != height) {
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead;
        if (NativeSdkGpuCompositeEnabled() && [self.device hasUnifiedMemory]) {
            /* Composite mode renders into this texture; keep raw-pixel
             * presents and composite presents on one texture. */
            descriptor.usage |= MTLTextureUsageRenderTarget;
            self.canvasTextureRenderable = YES;
        } else {
            self.canvasTextureRenderable = NO;
        }
        descriptor.storageMode = MTLStorageModeShared;
        self.canvasTexture = [self.device newTextureWithDescriptor:descriptor];
        self.canvasTextureWidth = width;
        self.canvasTextureHeight = height;
        textureChanged = YES;
    }
    if (!self.canvasTexture) return NO;
    /* Foreign bytes move the texture past any composited baseline; the
     * next composite dirty update must refuse into a full present. */
    self.canvasCompositeContentValid = NO;

    BOOL uploadFullTexture = textureChanged || !hasDirtyRect || scale <= 0 || dirtyWidth <= 0 || dirtyHeight <= 0;
    if (uploadFullTexture) dirtyRects = nil;
    /* Upload each refined dirty rect (or the single dirty rect) into the
     * texture and mirror the same bytes into the retained backing. */
    NSUInteger uploadRectCount = dirtyRects ? dirtyRects.count : 1;
    void *backingBytes = NULL;
    if (!self.canvasPacketPixels || self.canvasPacketPixelWidth != width || self.canvasPacketPixelHeight != height || self.canvasPacketPixels.length != byteLength) {
        self.canvasPacketPixels = [NSMutableData dataWithLength:byteLength];
        self.canvasPacketPixelWidth = width;
        self.canvasPacketPixelHeight = height;
        self.canvasPacketPixelsValid = NO;
    }
    if (self.canvasPacketPixels && self.canvasPacketPixels.length == byteLength) {
        backingBytes = self.canvasPacketPixels.mutableBytes;
        if ((const void *)backingBytes == (const void *)rgba8) backingBytes = NULL;
    }
    for (NSUInteger rectIndex = 0; rectIndex < uploadRectCount; rectIndex += 1) {
        CGFloat rectX = dirtyX;
        CGFloat rectY = dirtyY;
        CGFloat rectWidth = dirtyWidth;
        CGFloat rectHeight = dirtyHeight;
        if (dirtyRects) {
            NSRect rect = dirtyRects[rectIndex].rectValue;
            rectX = rect.origin.x;
            rectY = rect.origin.y;
            rectWidth = rect.size.width;
            rectHeight = rect.size.height;
        }
        NSUInteger uploadX = 0;
        NSUInteger uploadY = 0;
        NSUInteger uploadWidth = width;
        NSUInteger uploadHeight = height;
        if (!uploadFullTexture) {
            CGFloat minX = floor(rectX * scale);
            CGFloat minY = floor(rectY * scale);
            CGFloat maxX = ceil((rectX + rectWidth) * scale);
            CGFloat maxY = ceil((rectY + rectHeight) * scale);
            minX = fmax(0.0, fmin((CGFloat)width, minX));
            minY = fmax(0.0, fmin((CGFloat)height, minY));
            maxX = fmax(minX, fmin((CGFloat)width, maxX));
            maxY = fmax(minY, fmin((CGFloat)height, maxY));
            uploadX = (NSUInteger)minX;
            uploadY = (NSUInteger)minY;
            uploadWidth = (NSUInteger)(maxX - minX);
            uploadHeight = (NSUInteger)(maxY - minY);
            if (uploadWidth == 0 || uploadHeight == 0) {
                if (dirtyRects) continue;
                return YES;
            }
        }
        const uint8_t *uploadBytes = rgba8 + ((uploadY * width + uploadX) * 4);
        [self.canvasTexture replaceRegion:MTLRegionMake2D(uploadX, uploadY, uploadWidth, uploadHeight)
                              mipmapLevel:0
                                withBytes:uploadBytes
                              bytesPerRow:width * 4];
        if (backingBytes) {
            if (uploadFullTexture) {
                memcpy(backingBytes, rgba8, byteLength);
                /* A full foreign upload (raw-pixels present) makes the
                 * backing match the glass byte-for-byte again. */
                self.canvasPacketPixelsValid = YES;
            } else {
                for (NSUInteger row = 0; row < uploadHeight; row++) {
                    const NSUInteger rowOffset = ((uploadY + row) * width + uploadX) * 4;
                    memcpy((uint8_t *)backingBytes + rowOffset, rgba8 + rowOffset, uploadWidth * 4);
                }
            }
        }
    }
    self.hasCanvasTexture = YES;
    (void)scale;
    [self stopDisplayTimer];
    [self renderFrame];
    return YES;
}

- (NSInteger)presentGpuPacketWithSurfaceWidth:(CGFloat)surfaceWidth height:(CGFloat)surfaceHeight scale:(CGFloat)scale clearR:(uint8_t)clearR clearG:(uint8_t)clearG clearB:(uint8_t)clearB clearA:(uint8_t)clearA requiresRender:(BOOL)requiresRender commandCount:(NSUInteger)commandCount unsupportedCommandCount:(NSUInteger)unsupportedCommandCount representable:(BOOL)representable json:(const uint8_t *)json byteLength:(NSUInteger)byteLength {
    if (![self isAvailable]) return -1;
    if (!requiresRender) return 1;
    if (!representable || unsupportedCommandCount != 0 || !json || byteLength == 0 || surfaceWidth <= 0 || surfaceHeight <= 0) return 0;

    const uint64_t decodeBeginNs = NativeSdkTimestampNanoseconds();
    NSData *packetData = [NSData dataWithBytes:json length:byteLength];
    NSError *jsonError = nil;
    id packetObject = [NSJSONSerialization JSONObjectWithData:packetData options:0 error:&jsonError];
    NSDictionary *packet = NativeSdkPacketDictionary(packetObject);
    if (!packet || jsonError) return 0;
    const uint64_t drawBeginNs = NativeSdkTimestampNanoseconds();
    const NSInteger result = [self presentGpuPacketObject:packet surfaceWidth:surfaceWidth height:surfaceHeight scale:scale clearR:clearR clearG:clearG clearB:clearB clearA:clearA commandCount:commandCount];
    if (result == 1) {
        self.lastPacketDecodeNs = drawBeginNs - decodeBeginNs;
        self.lastPacketDrawNs = NativeSdkTimestampNanoseconds() - drawBeginNs;
    }
    return result;
}

/* Compact binary packet present: same guards and same shared present
 * path as the JSON entry — only the payload decode differs, so the two
 * encodings can never draw differently. */
- (NSInteger)presentGpuPacketBinaryWithSurfaceWidth:(CGFloat)surfaceWidth height:(CGFloat)surfaceHeight scale:(CGFloat)scale clearR:(uint8_t)clearR clearG:(uint8_t)clearG clearB:(uint8_t)clearB clearA:(uint8_t)clearA requiresRender:(BOOL)requiresRender commandCount:(NSUInteger)commandCount unsupportedCommandCount:(NSUInteger)unsupportedCommandCount representable:(BOOL)representable packet:(const uint8_t *)packet byteLength:(NSUInteger)byteLength {
    if (![self isAvailable]) return -1;
    if (!requiresRender) return 1;
    if (!representable || unsupportedCommandCount != 0 || !packet || byteLength == 0 || surfaceWidth <= 0 || surfaceHeight <= 0) return 0;

    const uint64_t decodeBeginNs = NativeSdkTimestampNanoseconds();
    NSDictionary *decoded = NativeSdkPacketDictionaryFromBinary(packet, byteLength);
    if (!decoded) return 0;
    const uint64_t drawBeginNs = NativeSdkTimestampNanoseconds();
    const NSInteger result = [self presentGpuPacketObject:decoded surfaceWidth:surfaceWidth height:surfaceHeight scale:scale clearR:clearR clearG:clearG clearB:clearB clearA:clearA commandCount:commandCount];
    if (result == 1) {
        self.lastPacketDecodeNs = drawBeginNs - decodeBeginNs;
        self.lastPacketDrawNs = NativeSdkTimestampNanoseconds() - drawBeginNs;
    }
    return result;
}

/* Draw-trace mode (NATIVE_SDK_GPU_DRAW_TRACE=1): per-present phase and
 * per-group draw timing on stderr. The per-command timers below only
 * run while this is set. */
static BOOL NativeSdkGpuDrawTraceEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *value = getenv("NATIVE_SDK_GPU_DRAW_TRACE");
        enabled = value && value[0] != 0 && strcmp(value, "0") != 0;
    });
    return enabled;
}

/* Frame-trace mode (NATIVE_SDK_GPU_FRAME_TRACE=1): one stderr line per
 * renderFrame naming the path taken (occluded short-circuit, nil
 * drawable, or a real present) plus how long nextDrawable held the main
 * thread. The vend duration is the line's whole point: nextDrawable runs
 * with its timeout DISALLOWED (see the layer setup), so a window whose
 * compositing is parked can silently turn each frame into a main-thread
 * stall — this trace is how that shows up as a number instead of a
 * mystery. */
static BOOL NativeSdkGpuFrameTraceEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *value = getenv("NATIVE_SDK_GPU_FRAME_TRACE");
        enabled = value && value[0] != 0 && strcmp(value, "0") != 0;
    });
    return enabled;
}

/* Incremental-verify mode: byte-compare every scissored dirty update
 * against a from-scratch full redraw of the same command list. Test-only
 * (the full redraw doubles the draw cost); enabled by environment. */
static BOOL NativeSdkGpuVerifyIncrementalEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *value = getenv("NATIVE_SDK_GPU_VERIFY_INCREMENTAL");
        enabled = value && value[0] != 0 && strcmp(value, "0") != 0;
    });
    return enabled;
}

/* GPU-vs-reference comparison mode (NATIVE_SDK_GPU_COMPARE=1, composite
 * mode only): after every composite the full command list is redrawn
 * through the CPU reference path and diffed against the composited
 * texture readback — per-channel max delta and differing-pixel count on
 * stderr. Test-only (the reference redraw plus readback doubles cost). */
static BOOL NativeSdkGpuCompareEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *value = getenv("NATIVE_SDK_GPU_COMPARE");
        enabled = value && value[0] != 0 && strcmp(value, "0") != 0;
    });
    return enabled;
}

/* Composite screenshot dumps (NATIVE_SDK_GPU_SHOT_DIR=<dir>, composite
 * mode only): the actual composited texture is read back and written as
 * PNG every 30th present (and on the first), for visual spot checks of
 * real GPU output. */
static const char *NativeSdkGpuShotDir(void) {
    static char dir[1024];
    static BOOL present;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *value = getenv("NATIVE_SDK_GPU_SHOT_DIR");
        if (value && value[0] != 0) {
            strncpy(dir, value, sizeof(dir) - 1);
            dir[sizeof(dir) - 1] = 0;
            present = YES;
        }
    });
    return present ? dir : NULL;
}

/* ---------------------------------------------------------------------------
 * GPU composite pass (NATIVE_SDK_GPU_COMPOSITE=1, prototype).
 *
 * Packet presents encode a real render pass targeting the canvas texture
 * instead of CPU-blitting into the retained backing and re-uploading:
 *   - cached command rasters draw as textured quads (integer texture
 *     reads, premultiplied source-over blend — the same bytes the CPU
 *     blit composited);
 *   - pixel-aligned fully-opaque solid rect fills draw as flat quads on
 *     a blend-off pipeline (exact color copy; this covers the
 *     over-cache-budget full-surface background fill);
 *   - transform-carrying and over-budget commands rasterize per frame
 *     through the same CG code, clipped to the repaint region, and draw
 *     as transient textured quads;
 *   - blur reads the backdrop, so the pass splits around it: commit +
 *     wait, read the target back, run the existing scalar box blur on
 *     the readback, upload the blurred rect, and continue — a hybrid
 *     frame, CPU only where the effect is inherently a backdrop read.
 * Scissor/dirty-rect semantics mirror the CPU path: full passes clear
 * everything via the pass load action; dirty updates load the retained
 * texture, clear each refined rect with a copy quad, and scissor every
 * command draw to the rect list (rects are merged until disjoint so each
 * pixel composites exactly once, like the CPU union clip). */

typedef struct {
    uint8_t type; /* 0 skip, 1 flat copy quad, 2 textured blend quad, 3 blur sandwich */
    BOOL hasCullBounds;
    NSRect cullBounds;      /* point space */
    float pxX, pxY, pxW, pxH; /* device-pixel quad */
    float colorR, colorG, colorB, colorA; /* premultiplied flat color */
    NSUInteger commandIndex;
    void *texture; /* unretained; kept alive by opTextures/raster cache */
} NativeSdkCompositeOp;

typedef struct {
    float viewport[2];
    float rectOrigin[2];
    float rectSize[2];
    float texOrigin[2];
    float color[4];
    uint32_t textured;
    uint32_t pad[3];
} NativeSdkCompositeUniforms;

static void NativeSdkCompositeEncodeQuad(id<MTLRenderCommandEncoder> encoder, NSUInteger viewportWidth, NSUInteger viewportHeight, float pxX, float pxY, float pxW, float pxH, float texOriginX, float texOriginY, const float color[4], BOOL textured, id<MTLTexture> texture) {
    NativeSdkCompositeUniforms uniforms;
    memset(&uniforms, 0, sizeof(uniforms));
    uniforms.viewport[0] = (float)viewportWidth;
    uniforms.viewport[1] = (float)viewportHeight;
    uniforms.rectOrigin[0] = pxX;
    uniforms.rectOrigin[1] = pxY;
    uniforms.rectSize[0] = pxW;
    uniforms.rectSize[1] = pxH;
    uniforms.texOrigin[0] = texOriginX;
    uniforms.texOrigin[1] = texOriginY;
    if (color) memcpy(uniforms.color, color, sizeof(uniforms.color));
    uniforms.textured = textured ? 1 : 0;
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentTexture:texture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

/* Device-pixel region the blur effect will write: mirror of
 * NativeSdkPacketApplyBlur's own rect derivation, so the copied-back quad
 * covers exactly the bytes the blur modified. Returns NO when the blur
 * degenerates to a no-op (empty rect, zero radius, zero mix). */
static BOOL NativeSdkCompositeBlurWriteRegion(NSDictionary *command, CGFloat scale, NSUInteger pixelWidth, NSUInteger pixelHeight, BOOL hasScissor, NSRect scissorRect, MTLRegion *outRegion) {
    NSDictionary *effect = NativeSdkPacketDictionary(command[@"effect"]);
    if (!effect) return NO;
    id transformValue = command[@"transform"];
    CGFloat opacity = fmax(0.0, fmin(1.0, NativeSdkPacketNumber(command[@"opacity"], 1)));
    if (opacity <= 0) return NO;
    BOOL hasEffectiveClip = hasScissor;
    NSRect effectiveClip = scissorRect;
    NSArray *clipArray = NativeSdkPacketArray(command[@"clip"], 4);
    if (clipArray) {
        NSRect commandClip = NativeSdkPacketRect(clipArray);
        effectiveClip = hasEffectiveClip ? NSIntersectionRect(effectiveClip, commandClip) : commandClip;
        hasEffectiveClip = YES;
    }
    NSRect rect = CGRectStandardize(NativeSdkPacketTransformRect(transformValue, NativeSdkPacketRect(effect[@"rect"])));
    if (hasEffectiveClip) rect = NSIntersectionRect(rect, effectiveClip);
    if (NSIsEmptyRect(rect)) return NO;
    CGFloat normalizedScale = scale > 0 ? scale : 1;
    CGFloat minXFloat = floor(NSMinX(rect) * normalizedScale);
    CGFloat minYFloat = floor(NSMinY(rect) * normalizedScale);
    CGFloat maxXFloat = ceil(NSMaxX(rect) * normalizedScale);
    CGFloat maxYFloat = ceil(NSMaxY(rect) * normalizedScale);
    minXFloat = fmax(0.0, fmin((CGFloat)pixelWidth, minXFloat));
    minYFloat = fmax(0.0, fmin((CGFloat)pixelHeight, minYFloat));
    maxXFloat = fmax(minXFloat, fmin((CGFloat)pixelWidth, maxXFloat));
    maxYFloat = fmax(minYFloat, fmin((CGFloat)pixelHeight, maxYFloat));
    if (maxXFloat <= minXFloat || maxYFloat <= minYFloat) return NO;
    NSUInteger radius = (NSUInteger)llround(fmax(0.0, NativeSdkPacketNumber(effect[@"radius"], 0) * normalizedScale * NativeSdkPacketTransformScale(transformValue)));
    radius = MIN(radius, (NSUInteger)64);
    if (radius == 0) return NO;
    if (outRegion) {
        *outRegion = MTLRegionMake2D((NSUInteger)minXFloat, (NSUInteger)minYFloat, (NSUInteger)(maxXFloat - minXFloat), (NSUInteger)(maxYFloat - minYFloat));
    }
    return YES;
}

- (BOOL)ensureCanvasCompositor {
    if (self.canvasCompositeBlendPipeline && self.canvasCompositeOpaquePipeline && self.canvasCompositeFlatTexture) return YES;
    if (!self.device || !self.commandQueue) return NO;
    /* Shared-storage render targets (needed for cheap readback and the
     * blur sandwich) require unified memory. */
    if (![self.device hasUnifiedMemory]) return NO;

    static NSString *shaderSource =
        @"#include <metal_stdlib>\n"
        @"using namespace metal;\n"
        @"struct NativeSdkCompositeUniforms {\n"
        @"  float2 viewport; float2 rect_origin; float2 rect_size; float2 tex_origin;\n"
        @"  float4 color; uint textured; uint3 pad;\n"
        @"};\n"
        @"struct NativeSdkCompositeVertexOut { float4 position [[position]]; };\n"
        @"vertex NativeSdkCompositeVertexOut native_sdk_composite_vertex(uint vertex_id [[vertex_id]], constant NativeSdkCompositeUniforms &u [[buffer(0)]]) {\n"
        @"  float2 corner = float2(float(vertex_id & 1u), float(vertex_id >> 1u));\n"
        @"  float2 px = u.rect_origin + corner * u.rect_size;\n"
        @"  NativeSdkCompositeVertexOut out;\n"
        @"  out.position = float4(px.x / u.viewport.x * 2.0 - 1.0, 1.0 - px.y / u.viewport.y * 2.0, 0.0, 1.0);\n"
        @"  return out;\n"
        @"}\n"
        @"fragment float4 native_sdk_composite_fragment(NativeSdkCompositeVertexOut in [[stage_in]], constant NativeSdkCompositeUniforms &u [[buffer(0)]], texture2d<float, access::read> quad_texture [[texture(0)]]) {\n"
        @"  if (u.textured == 0u) return u.color;\n"
        @"  int2 pixel = int2(in.position.xy);\n"
        @"  int2 texel = pixel - int2(u.rect_origin) + int2(u.tex_origin);\n"
        @"  texel = clamp(texel, int2(0), int2(int(quad_texture.get_width()) - 1, int(quad_texture.get_height()) - 1));\n"
        @"  return quad_texture.read(uint2(texel));\n"
        @"}\n";

    NSError *libraryError = nil;
    id<MTLLibrary> library = [self.device newLibraryWithSource:shaderSource options:nil error:&libraryError];
    if (!library) return NO;
    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"native_sdk_composite_vertex"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"native_sdk_composite_fragment"];
    if (!vertexFunction || !fragmentFunction) return NO;

    MTLRenderPipelineDescriptor *blendDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    blendDescriptor.label = @"native-sdk composite blend";
    blendDescriptor.vertexFunction = vertexFunction;
    blendDescriptor.fragmentFunction = fragmentFunction;
    blendDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    blendDescriptor.colorAttachments[0].blendingEnabled = YES;
    blendDescriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    blendDescriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    blendDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    blendDescriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    blendDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    blendDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    NSError *pipelineError = nil;
    id<MTLRenderPipelineState> blendPipeline = [self.device newRenderPipelineStateWithDescriptor:blendDescriptor error:&pipelineError];
    if (!blendPipeline) return NO;

    MTLRenderPipelineDescriptor *opaqueDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    opaqueDescriptor.label = @"native-sdk composite copy";
    opaqueDescriptor.vertexFunction = vertexFunction;
    opaqueDescriptor.fragmentFunction = fragmentFunction;
    opaqueDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    opaqueDescriptor.colorAttachments[0].blendingEnabled = NO;
    id<MTLRenderPipelineState> opaquePipeline = [self.device newRenderPipelineStateWithDescriptor:opaqueDescriptor error:&pipelineError];
    if (!opaquePipeline) return NO;

    MTLTextureDescriptor *flatDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
    flatDescriptor.usage = MTLTextureUsageShaderRead;
    flatDescriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> flatTexture = [self.device newTextureWithDescriptor:flatDescriptor];
    if (!flatTexture) return NO;
    const uint8_t flatPixel[4] = {0, 0, 0, 0};
    [flatTexture replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:flatPixel bytesPerRow:4];

    self.canvasCompositeBlendPipeline = blendPipeline;
    self.canvasCompositeOpaquePipeline = opaquePipeline;
    self.canvasCompositeFlatTexture = flatTexture;
    return YES;
}

/* Rasterize one command per frame through the direct CG path (its own
 * clip + transform + opacity) into a transient texture over the padded,
 * pixel-aligned intersection of its bounds and the repaint region. Used
 * for transform-carrying and over-cache-budget commands. */
- (id<MTLTexture>)compositeScratchTextureForCommand:(NSDictionary *)command poolKey:(NSNumber *)poolKey scale:(CGFloat)scale pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight repaintRect:(NSRect)repaintRect hasRepaintRect:(BOOL)hasRepaintRect outRegion:(MTLRegion *)outRegion {
    NSArray *boundsArray = NativeSdkPacketArray(command[@"bounds"], 4);
    if (!boundsArray || !self.canvasColorSpace) return nil;
    NSRect bounds = CGRectStandardize(NativeSdkPacketRect(boundsArray));
    if (hasRepaintRect) bounds = NSIntersectionRect(bounds, repaintRect);
    if (NSIsEmptyRect(bounds)) return nil;
    CGFloat minX = floor(NSMinX(bounds) * scale) - 1;
    CGFloat minY = floor(NSMinY(bounds) * scale) - 1;
    CGFloat maxX = ceil(NSMaxX(bounds) * scale) + 1;
    CGFloat maxY = ceil(NSMaxY(bounds) * scale) + 1;
    minX = fmax(0.0, fmin((CGFloat)pixelWidth, minX));
    minY = fmax(0.0, fmin((CGFloat)pixelHeight, minY));
    maxX = fmax(minX, fmin((CGFloat)pixelWidth, maxX));
    maxY = fmax(minY, fmin((CGFloat)pixelHeight, maxY));
    NSUInteger rasterWidth = (NSUInteger)(maxX - minX);
    NSUInteger rasterHeight = (NSUInteger)(maxY - minY);
    if (rasterWidth == 0 || rasterHeight == 0) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:rasterWidth * rasterHeight * 4];
    if (!data) return nil;
    CGContextRef bitmap = CGBitmapContextCreate(data.mutableBytes, rasterWidth, rasterHeight, 8, rasterWidth * 4, self.canvasColorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!bitmap) return nil;
    CGContextSetAllowsAntialiasing(bitmap, true);
    CGContextSetShouldAntialias(bitmap, true);
    CGContextTranslateCTM(bitmap, 0, (CGFloat)rasterHeight);
    CGContextScaleCTM(bitmap, scale, -scale);
    CGContextTranslateCTM(bitmap, -minX / scale, -minY / scale);
    NSGraphicsContext *graphics = [NSGraphicsContext graphicsContextWithCGContext:bitmap flipped:YES];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:graphics];
    BOOL ok = NativeSdkPacketDrawCommand(command, bitmap, scale, NO, NSZeroRect, self.canvasImageCache);
    [NSGraphicsContext restoreGraphicsState];
    CGContextRelease(bitmap);
    if (!ok) return nil;
    id<MTLTexture> texture = nil;
    if (poolKey) {
        if (!self.canvasCompositeScratchTextures) self.canvasCompositeScratchTextures = [NSMutableDictionary dictionary];
        id<MTLTexture> pooled = self.canvasCompositeScratchTextures[poolKey];
        if (pooled && pooled.width >= rasterWidth && pooled.height >= rasterHeight) texture = pooled;
    }
    if (!texture) {
        /* Round capacity up so an animated command's wobbling padded
         * extent keeps hitting the same pooled texture. */
        NSUInteger capacityWidth = MIN((NSUInteger)8192, (rasterWidth + 63) / 64 * 64);
        NSUInteger capacityHeight = MIN((NSUInteger)8192, (rasterHeight + 63) / 64 * 64);
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:capacityWidth height:capacityHeight mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModeShared;
        texture = [self.device newTextureWithDescriptor:descriptor];
        if (!texture) return nil;
        if (poolKey) {
            if (self.canvasCompositeScratchTextures.count >= 64) [self.canvasCompositeScratchTextures removeAllObjects];
            self.canvasCompositeScratchTextures[poolKey] = texture;
        }
    }
    [texture replaceRegion:MTLRegionMake2D(0, 0, rasterWidth, rasterHeight) mipmapLevel:0 withBytes:data.bytes bytesPerRow:rasterWidth * 4];
    if (outRegion) *outRegion = MTLRegionMake2D((NSUInteger)minX, (NSUInteger)minY, rasterWidth, rasterHeight);
    return texture;
}

- (NSInteger)compositePacketCommands:(NSArray *)commands keys:(NSArray *)keys target:(id<MTLTexture>)target pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight scale:(CGFloat)scale clearColor:(NSColor *)clearColor fullSurfacePass:(BOOL)fullSurfacePass hasScissor:(BOOL)hasScissor scissorRect:(NSRect)scissorRect dirtyRects:(NSArray<NSValue *> *)dirtyRects waitUntilCompleted:(BOOL)waitUntilCompleted {
    if (!target) return -1;
    if (fullSurfacePass || !hasScissor || dirtyRects.count == 0) dirtyRects = nil;
    if (!self.canvasColorSpace) self.canvasColorSpace = CGColorSpaceCreateDeviceRGB();
    if (!self.canvasColorSpace) return -1;
    /* Pooled scratch textures are rewritten below while the previous
     * frame's pass may still read them; the passes are microseconds of
     * GPU work paced a display interval apart, so this wait is normally
     * an immediate return. */
    if (self.canvasCompositeLastCommandBuffer) {
        [self.canvasCompositeLastCommandBuffer waitUntilCompleted];
        self.canvasCompositeLastCommandBuffer = nil;
    }
    self.canvasTraceDrawnCount = 0;
    self.canvasTraceCacheHitCount = 0;
    self.canvasTraceCacheFillCount = 0;
    self.canvasTraceDirectCount = 0;
    self.canvasTraceCacheHitNs = 0;
    self.canvasTraceCacheFillNs = 0;
    self.canvasTraceDirectNs = 0;
    self.canvasTraceQuadCount = 0;
    self.canvasTraceBindCount = 0;

    /* Repaint rect list in device pixels (merged until disjoint so a
     * command overlapping two rects never composites a pixel twice) and
     * in points (for culling). */
    enum { NativeSdkCompositeMaxRects = 9 };
    MTLScissorRect pxRects[NativeSdkCompositeMaxRects];
    NSRect pointRects[NativeSdkCompositeMaxRects];
    NSUInteger rectCount = 0;
    if (fullSurfacePass || !hasScissor) {
        pxRects[0] = (MTLScissorRect){0, 0, pixelWidth, pixelHeight};
        pointRects[0] = NSMakeRect(0, 0, (CGFloat)pixelWidth / scale, (CGFloat)pixelHeight / scale);
        rectCount = 1;
    } else if (dirtyRects) {
        for (NSValue *value in dirtyRects) {
            if (rectCount >= NativeSdkCompositeMaxRects) break;
            pointRects[rectCount] = value.rectValue;
            rectCount += 1;
        }
    } else {
        pointRects[0] = scissorRect;
        rectCount = 1;
    }
    if (!fullSurfacePass && hasScissor) {
        /* Merge overlapping point rects until pairwise disjoint. */
        BOOL merged = YES;
        while (merged) {
            merged = NO;
            for (NSUInteger a = 0; a < rectCount && !merged; a += 1) {
                for (NSUInteger b = a + 1; b < rectCount && !merged; b += 1) {
                    if (NativeSdkPacketRectIntersects(pointRects[a], pointRects[b])) {
                        pointRects[a] = NSUnionRect(pointRects[a], pointRects[b]);
                        pointRects[b] = pointRects[rectCount - 1];
                        rectCount -= 1;
                        merged = YES;
                    }
                }
            }
        }
        for (NSUInteger index = 0; index < rectCount; index += 1) {
            NSRect aligned = NativeSdkPacketAlignRectToPixels(pointRects[index], scale, pixelWidth, pixelHeight);
            pointRects[index] = aligned;
            pxRects[index] = (MTLScissorRect){
                (NSUInteger)llround(NSMinX(aligned) * scale),
                (NSUInteger)llround(NSMinY(aligned) * scale),
                (NSUInteger)llround(NSWidth(aligned) * scale),
                (NSUInteger)llround(NSHeight(aligned) * scale),
            };
        }
    }
    if (rectCount == 0) return 0;
    NSRect repaintUnion = pointRects[0];
    for (NSUInteger index = 1; index < rectCount; index += 1) repaintUnion = NSUnionRect(repaintUnion, pointRects[index]);
    const BOOL cullToRects = !fullSurfacePass && hasScissor;

    /* Prepare pass: classify and validate every command (and do all the
     * CPU raster work) BEFORE anything is encoded, so an unsupported
     * command refuses with the target untouched. */
    NSMutableData *opsData = [NSMutableData dataWithLength:MAX((NSUInteger)1, commands.count) * sizeof(NativeSdkCompositeOp)];
    if (!opsData) return -1;
    NativeSdkCompositeOp *ops = (NativeSdkCompositeOp *)opsData.mutableBytes;
    NSMutableArray *opTextures = [NSMutableArray array];
    [self rasterCacheEnsureScale:scale pixelWidth:pixelWidth pixelHeight:pixelHeight];
    for (NSUInteger index = 0; index < commands.count; index += 1) {
        NativeSdkCompositeOp *op = &ops[index];
        op->type = 0;
        op->commandIndex = index;
        NSDictionary *command = NativeSdkPacketDictionary(commands[index]);
        if (!command) return 0;
        NSString *kind = [command[@"kind"] isKindOfClass:[NSString class]] ? command[@"kind"] : @"";
        NSArray *boundsArray = NativeSdkPacketArray(command[@"bounds"], 4);
        op->hasCullBounds = boundsArray != nil;
        op->cullBounds = boundsArray ? CGRectStandardize(NativeSdkPacketRect(boundsArray)) : NSZeroRect;
        const BOOL knownKind = [kind hasPrefix:@"fill_rect"] || [kind hasPrefix:@"fill_rounded_rect"] || [kind hasPrefix:@"stroke_rect"] || [kind hasPrefix:@"draw_line"] ||
            [kind isEqualToString:@"fill_path"] || [kind isEqualToString:@"stroke_path"] || [kind isEqualToString:@"draw_text"] ||
            [kind isEqualToString:@"shadow"] || [kind isEqualToString:@"blur"] || [kind isEqualToString:@"draw_image"];
        if (!knownKind) return 0;
        if (cullToRects && op->hasCullBounds) {
            BOOL intersects = NO;
            for (NSUInteger rectIndex = 0; rectIndex < rectCount && !intersects; rectIndex += 1) {
                intersects = NativeSdkPacketRectIntersects(op->cullBounds, pointRects[rectIndex]);
            }
            if (!intersects) continue;
        }
        self.canvasTraceDrawnCount += 1;
        if ([kind isEqualToString:@"blur"]) {
            MTLRegion region = {0};
            if (!NativeSdkCompositeBlurWriteRegion(command, scale, pixelWidth, pixelHeight, hasScissor, scissorRect, &region)) {
                self.canvasTraceDrawnCount -= 1;
                continue; /* degenerate blur writes nothing */
            }
            op->type = 3;
            op->pxX = (float)region.origin.x;
            op->pxY = (float)region.origin.y;
            op->pxW = (float)region.size.width;
            op->pxH = (float)region.size.height;
            self.canvasTraceDirectCount += 1;
            continue;
        }
        /* Pixel-aligned fully-opaque solid rect: exact flat quad. */
        if ([kind isEqualToString:@"fill_rect_solid"] && !command[@"transform"]) {
            NSDictionary *paint = NativeSdkPacketDictionary(command[@"paint"]);
            NSDictionary *shape = NativeSdkPacketDictionary(command[@"shape"]);
            NSArray *colorArray = paint ? NativeSdkPacketArray(paint[@"color"], 4) : nil;
            CGFloat opacity = fmax(0.0, fmin(1.0, NativeSdkPacketNumber(command[@"opacity"], 1)));
            if (colorArray && shape && [[paint[@"kind"] description] isEqualToString:@"color"] && opacity >= 1.0 &&
                NativeSdkPacketNumber(colorArray[3], 1) >= 1.0) {
                NSRect rect = CGRectStandardize(NativeSdkPacketRect(shape[@"rect"]));
                NSArray *clipArray = NativeSdkPacketArray(command[@"clip"], 4);
                BOOL clipUsable = command[@"clip"] == nil || clipArray != nil;
                if (clipArray) rect = NSIntersectionRect(rect, CGRectStandardize(NativeSdkPacketRect(clipArray)));
                CGFloat pxMinX = NSMinX(rect) * scale;
                CGFloat pxMinY = NSMinY(rect) * scale;
                CGFloat pxMaxX = NSMaxX(rect) * scale;
                CGFloat pxMaxY = NSMaxY(rect) * scale;
                const BOOL aligned = fabs(pxMinX - round(pxMinX)) < 1e-6 && fabs(pxMinY - round(pxMinY)) < 1e-6 &&
                    fabs(pxMaxX - round(pxMaxX)) < 1e-6 && fabs(pxMaxY - round(pxMaxY)) < 1e-6;
                if (clipUsable && aligned && !NSIsEmptyRect(rect)) {
                    pxMinX = fmax(0.0, fmin((CGFloat)pixelWidth, round(pxMinX)));
                    pxMinY = fmax(0.0, fmin((CGFloat)pixelHeight, round(pxMinY)));
                    pxMaxX = fmax(pxMinX, fmin((CGFloat)pixelWidth, round(pxMaxX)));
                    pxMaxY = fmax(pxMinY, fmin((CGFloat)pixelHeight, round(pxMaxY)));
                    if (pxMaxX > pxMinX && pxMaxY > pxMinY) {
                        op->type = 1;
                        op->pxX = (float)pxMinX;
                        op->pxY = (float)pxMinY;
                        op->pxW = (float)(pxMaxX - pxMinX);
                        op->pxH = (float)(pxMaxY - pxMinY);
                        op->colorR = (float)fmax(0.0, fmin(1.0, NativeSdkPacketNumber(colorArray[0], 0)));
                        op->colorG = (float)fmax(0.0, fmin(1.0, NativeSdkPacketNumber(colorArray[1], 0)));
                        op->colorB = (float)fmax(0.0, fmin(1.0, NativeSdkPacketNumber(colorArray[2], 0)));
                        op->colorA = 1;
                        self.canvasTraceDirectCount += 1;
                        continue;
                    }
                }
            }
        }
        /* Cached raster as a textured quad. */
        NSNumber *key = nil;
        if (keys && index < keys.count && [keys[index] isKindOfClass:[NSNumber class]]) key = keys[index];
        if (key && op->hasCullBounds && self.canvasCommandRasterCache && NativeSdkPacketCommandRasterCacheable(command, kind)) {
            NativeSdkPacketCommandRaster *entry = self.canvasCommandRasterCache[key];
            if (entry && entry.command != command) {
                [self rasterCacheRemoveKey:key];
                entry = nil;
            }
            BOOL filled = NO;
            if (!entry) {
                const uint64_t fillBegin = NativeSdkTimestampNanoseconds();
                entry = [self rasterCacheFillForCommand:command kind:kind key:key scale:scale pixelWidth:pixelWidth pixelHeight:pixelHeight];
                filled = entry != nil;
                if (filled) self.canvasTraceCacheFillNs += NativeSdkTimestampNanoseconds() - fillBegin;
            }
            if (entry && !entry.texture) {
                /* Entry from a pre-composite present or a failed upload:
                 * refresh it so the quad has a texture. */
                [self rasterCacheRemoveKey:key];
                const uint64_t fillBegin = NativeSdkTimestampNanoseconds();
                entry = [self rasterCacheFillForCommand:command kind:kind key:key scale:scale pixelWidth:pixelWidth pixelHeight:pixelHeight];
                filled = entry != nil;
                if (filled) self.canvasTraceCacheFillNs += NativeSdkTimestampNanoseconds() - fillBegin;
            }
            if (entry && entry.texture) {
                if (filled) self.canvasTraceCacheFillCount += 1; else self.canvasTraceCacheHitCount += 1;
                self.canvasCommandRasterCacheTick += 1;
                entry.lastUseTick = self.canvasCommandRasterCacheTick;
                op->type = 2;
                op->pxX = (float)entry.pixelX;
                op->pxY = (float)entry.pixelY;
                op->pxW = (float)entry.pixelWidth;
                op->pxH = (float)entry.pixelHeight;
                op->texture = (__bridge void *)entry.texture;
                [opTextures addObject:entry.texture];
                continue;
            }
            /* Over budget or clamped empty: fall through to scratch. */
        }
        MTLRegion region = {0};
        const uint64_t scratchBegin = NativeSdkTimestampNanoseconds();
        id<MTLTexture> scratch = [self compositeScratchTextureForCommand:command poolKey:key scale:scale pixelWidth:pixelWidth pixelHeight:pixelHeight repaintRect:repaintUnion hasRepaintRect:cullToRects outRegion:&region];
        self.canvasTraceDirectNs += NativeSdkTimestampNanoseconds() - scratchBegin;
        if (!scratch) return 0;
        self.canvasTraceDirectCount += 1;
        op->type = 2;
        op->pxX = (float)region.origin.x;
        op->pxY = (float)region.origin.y;
        op->pxW = (float)region.size.width;
        op->pxH = (float)region.size.height;
        op->texture = (__bridge void *)scratch;
        [opTextures addObject:scratch];
    }

    /* Encode. Everything is validated; failures past this point are
     * device-level and surface as -1 (present failure -> engine resync). */
    float clearComponents[4] = {0, 0, 0, 1};
    {
        NSColor *deviceClear = [clearColor colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace] ?: clearColor;
        CGFloat r = 0, g = 0, b = 0, a = 1;
        [deviceClear getRed:&r green:&g blue:&b alpha:&a];
        clearComponents[0] = (float)(r * a);
        clearComponents[1] = (float)(g * a);
        clearComponents[2] = (float)(b * a);
        clearComponents[3] = (float)a;
    }
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (!commandBuffer) return -1;
    MTLRenderPassDescriptor *descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    descriptor.colorAttachments[0].texture = target;
    descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    if (fullSurfacePass) {
        descriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(clearComponents[0], clearComponents[1], clearComponents[2], clearComponents[3]);
    } else {
        descriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;
    }
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:descriptor];
    if (!encoder) return -1;
    id<MTLRenderPipelineState> currentPipeline = nil;
    const MTLScissorRect fullScissor = {0, 0, pixelWidth, pixelHeight};
    if (!fullSurfacePass && hasScissor) {
        /* Copy-clear each repaint rect (the CPU path's
         * NSCompositingOperationCopy clears). */
        [encoder setRenderPipelineState:self.canvasCompositeOpaquePipeline];
        currentPipeline = self.canvasCompositeOpaquePipeline;
        self.canvasTraceBindCount += 1;
        for (NSUInteger rectIndex = 0; rectIndex < rectCount; rectIndex += 1) {
            [encoder setScissorRect:pxRects[rectIndex]];
            NativeSdkCompositeEncodeQuad(encoder, pixelWidth, pixelHeight, (float)pxRects[rectIndex].x, (float)pxRects[rectIndex].y, (float)pxRects[rectIndex].width, (float)pxRects[rectIndex].height, 0, 0, clearComponents, NO, self.canvasCompositeFlatTexture);
            self.canvasTraceQuadCount += 1;
        }
    }
    BOOL failed = NO;
    BOOL mutated = fullSurfacePass; /* load-action clear already mutates */
    for (NSUInteger index = 0; index < commands.count && !failed; index += 1) {
        NativeSdkCompositeOp *op = &ops[index];
        if (op->type == 0) continue;
        if (op->type == 3) {
            /* Blur sandwich: flush the pass, read the target back, run
             * the reference scalar blur on the readback, upload the
             * blurred rect, and continue compositing above it. */
            [encoder endEncoding];
            encoder = nil;
            [commandBuffer commit];
            [commandBuffer waitUntilCompleted];
            mutated = YES;
            NSDictionary *command = NativeSdkPacketDictionary(commands[op->commandIndex]);
            NSMutableData *readback = [NSMutableData dataWithLength:pixelWidth * pixelHeight * 4];
            CGContextRef bitmap = readback ? CGBitmapContextCreate(readback.mutableBytes, pixelWidth, pixelHeight, 8, pixelWidth * 4, self.canvasColorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big) : NULL;
            id<MTLTexture> blurTexture = nil;
            if (bitmap) {
                [target getBytes:readback.mutableBytes bytesPerRow:pixelWidth * 4 fromRegion:MTLRegionMake2D(0, 0, pixelWidth, pixelHeight) mipmapLevel:0];
                NSDictionary *effect = NativeSdkPacketDictionary(command[@"effect"]);
                CGFloat opacity = fmax(0.0, fmin(1.0, NativeSdkPacketNumber(command[@"opacity"], 1)));
                BOOL hasEffectiveClip = hasScissor;
                NSRect effectiveClip = scissorRect;
                NSArray *clipArray = NativeSdkPacketArray(command[@"clip"], 4);
                if (clipArray) {
                    NSRect commandClip = NativeSdkPacketRect(clipArray);
                    effectiveClip = hasEffectiveClip ? NSIntersectionRect(effectiveClip, commandClip) : commandClip;
                    hasEffectiveClip = YES;
                }
                const uint64_t blurBegin = NativeSdkTimestampNanoseconds();
                BOOL blurred = NativeSdkPacketApplyBlur(effect, opacity, bitmap, scale, command[@"transform"], hasEffectiveClip, effectiveClip);
                self.canvasTraceDirectNs += NativeSdkTimestampNanoseconds() - blurBegin;
                CGContextRelease(bitmap);
                if (blurred) {
                    MTLRegion region = MTLRegionMake2D((NSUInteger)op->pxX, (NSUInteger)op->pxY, (NSUInteger)op->pxW, (NSUInteger)op->pxH);
                    MTLTextureDescriptor *blurDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:region.size.width height:region.size.height mipmapped:NO];
                    blurDescriptor.usage = MTLTextureUsageShaderRead;
                    blurDescriptor.storageMode = MTLStorageModeShared;
                    blurTexture = [self.device newTextureWithDescriptor:blurDescriptor];
                    if (blurTexture) {
                        const uint8_t *base = (const uint8_t *)readback.bytes + (region.origin.y * pixelWidth + region.origin.x) * 4;
                        [blurTexture replaceRegion:MTLRegionMake2D(0, 0, region.size.width, region.size.height) mipmapLevel:0 withBytes:base bytesPerRow:pixelWidth * 4];
                        [opTextures addObject:blurTexture];
                    }
                }
            }
            if (!blurTexture) {
                failed = YES;
                break;
            }
            commandBuffer = [self.commandQueue commandBuffer];
            if (!commandBuffer) {
                failed = YES;
                break;
            }
            MTLRenderPassDescriptor *resume = [MTLRenderPassDescriptor renderPassDescriptor];
            resume.colorAttachments[0].texture = target;
            resume.colorAttachments[0].loadAction = MTLLoadActionLoad;
            resume.colorAttachments[0].storeAction = MTLStoreActionStore;
            encoder = [commandBuffer renderCommandEncoderWithDescriptor:resume];
            if (!encoder) {
                failed = YES;
                break;
            }
            [encoder setRenderPipelineState:self.canvasCompositeOpaquePipeline];
            currentPipeline = self.canvasCompositeOpaquePipeline;
            self.canvasTraceBindCount += 1;
            [encoder setScissorRect:fullScissor];
            NativeSdkCompositeEncodeQuad(encoder, pixelWidth, pixelHeight, op->pxX, op->pxY, op->pxW, op->pxH, 0, 0, NULL, YES, blurTexture);
            self.canvasTraceQuadCount += 1;
            continue;
        }
        id<MTLRenderPipelineState> wanted = op->type == 1 ? self.canvasCompositeOpaquePipeline : self.canvasCompositeBlendPipeline;
        for (NSUInteger rectIndex = 0; rectIndex < rectCount; rectIndex += 1) {
            if (cullToRects && op->hasCullBounds && !NativeSdkPacketRectIntersects(op->cullBounds, pointRects[rectIndex])) continue;
            if (currentPipeline != wanted) {
                [encoder setRenderPipelineState:wanted];
                currentPipeline = wanted;
                self.canvasTraceBindCount += 1;
            }
            [encoder setScissorRect:pxRects[rectIndex]];
            if (op->type == 1) {
                const float color[4] = {op->colorR, op->colorG, op->colorB, op->colorA};
                NativeSdkCompositeEncodeQuad(encoder, pixelWidth, pixelHeight, op->pxX, op->pxY, op->pxW, op->pxH, 0, 0, color, NO, self.canvasCompositeFlatTexture);
            } else {
                NativeSdkCompositeEncodeQuad(encoder, pixelWidth, pixelHeight, op->pxX, op->pxY, op->pxW, op->pxH, 0, 0, NULL, YES, (__bridge id<MTLTexture>)op->texture);
            }
            self.canvasTraceQuadCount += 1;
        }
    }
    if (encoder) [encoder endEncoding];
    if (failed) {
        if (mutated) self.canvasCompositeContentValid = NO;
        return -1;
    }
    [commandBuffer commit];
    self.canvasCompositeLastCommandBuffer = commandBuffer;
    if (waitUntilCompleted) [commandBuffer waitUntilCompleted];
    (void)opTextures;
    return 1;
}

/* Composite-mode present: the packet's frame reaches the glass through
 * the GPU pass above; the CPU retained backing is untouched (and marked
 * stale). Refusal semantics mirror the CPU path: a dirty update against
 * a missing/resized/invalid target refuses (0) so the engine resyncs
 * with a full present. */
- (NSInteger)presentCompositePacketWithCommands:(NSArray *)commands keys:(NSArray *)keys pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight scale:(CGFloat)scale surfaceWidth:(CGFloat)surfaceWidth surfaceHeight:(CGFloat)surfaceHeight clearColor:(NSColor *)clearColor loadAction:(NSString *)loadAction fullSurfacePass:(BOOL)fullSurfacePass hasScissor:(BOOL)hasScissor scissorRect:(NSRect)scissorRect dirtyRects:(NSArray<NSValue *> *)dirtyRects directRetainedDirtyUpdate:(BOOL)directRetainedDirtyUpdate {
    const BOOL needNewTexture = !self.canvasTexture || !self.canvasTextureRenderable ||
        self.canvasTextureWidth != pixelWidth || self.canvasTextureHeight != pixelHeight;
    if (!fullSurfacePass && (needNewTexture || !self.canvasCompositeContentValid)) return 0;
    if (needNewTexture) {
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:pixelWidth height:pixelHeight mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        descriptor.storageMode = MTLStorageModeShared;
        id<MTLTexture> texture = [self.device newTextureWithDescriptor:descriptor];
        if (!texture) return -1;
        self.canvasTexture = texture;
        self.canvasTextureWidth = pixelWidth;
        self.canvasTextureHeight = pixelHeight;
        self.canvasTextureRenderable = YES;
        self.canvasCompositeContentValid = NO;
        self.canvasCompositeVerifyTexture = nil;
    }
    const uint64_t traceDrawBeginNs = NativeSdkTimestampNanoseconds();
    NSInteger result = [self compositePacketCommands:commands keys:keys target:self.canvasTexture pixelWidth:pixelWidth pixelHeight:pixelHeight scale:scale clearColor:clearColor fullSurfacePass:fullSurfacePass hasScissor:hasScissor scissorRect:scissorRect dirtyRects:dirtyRects waitUntilCompleted:NO];
    const uint64_t traceDrawEndNs = NativeSdkTimestampNanoseconds();
    if (result != 1) return result;
    if (fullSurfacePass) self.canvasCompositeContentValid = YES;
    self.canvasPacketPixelsValid = NO;
    self.hasCanvasTexture = YES;
    self.canvasCompositePresentCount += 1;
    [self stopDisplayTimer];
    [self renderFrame];
    if (NativeSdkGpuDrawTraceEnabled()) {
        const uint64_t tracePresentEndNs = NativeSdkTimestampNanoseconds();
        fprintf(stderr, "native-sdk: gpu draw-trace action=%s mode=gpu scissor=%d rect=%.0fx%.0f rects=%lu draw_us=%llu present_us=%llu drawn=%lu hit=%lu fill=%lu/%lluus direct=%lu/%lluus quads=%lu binds=%lu\n",
                loadAction.UTF8String, hasScissor ? 1 : 0, scissorRect.size.width, scissorRect.size.height,
                (unsigned long)dirtyRects.count,
                (unsigned long long)((traceDrawEndNs - traceDrawBeginNs) / 1000),
                (unsigned long long)((tracePresentEndNs - traceDrawEndNs) / 1000),
                (unsigned long)self.canvasTraceDrawnCount,
                (unsigned long)self.canvasTraceCacheHitCount,
                (unsigned long)self.canvasTraceCacheFillCount,
                (unsigned long long)(self.canvasTraceCacheFillNs / 1000),
                (unsigned long)self.canvasTraceDirectCount,
                (unsigned long long)(self.canvasTraceDirectNs / 1000),
                (unsigned long)self.canvasTraceQuadCount,
                (unsigned long)self.canvasTraceBindCount);
    }
    if (directRetainedDirtyUpdate && NativeSdkGpuVerifyIncrementalEnabled()) {
        [self verifyCompositeIncrementalWithCommands:commands keys:keys pixelWidth:pixelWidth pixelHeight:pixelHeight scale:scale clearColor:clearColor scissorRect:scissorRect];
    }
    if (NativeSdkGpuCompareEnabled()) {
        [self compareCompositeAgainstReferenceWithCommands:commands keys:keys pixelWidth:pixelWidth pixelHeight:pixelHeight scale:scale surfaceWidth:surfaceWidth surfaceHeight:surfaceHeight clearColor:clearColor];
    }
    if (NativeSdkGpuShotDir() && (self.canvasCompositePresentCount == 1 || self.canvasCompositePresentCount % 30 == 0)) {
        [self dumpCompositeShotWithPixelWidth:pixelWidth pixelHeight:pixelHeight];
    }
    return 1;
}

/* Composite-mode incremental verify: recomposite the full command list
 * from scratch into a scratch render target and byte-compare against the
 * incrementally updated canvas texture — the GPU analog of the CPU
 * backing verify, same log lines, driven by the same smoke leg. */
- (void)verifyCompositeIncrementalWithCommands:(NSArray *)commands keys:(NSArray *)keys pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight scale:(CGFloat)scale clearColor:(NSColor *)clearColor scissorRect:(NSRect)scissorRect {
    if (!self.canvasTexture) return;
    if (self.canvasCompositeLastCommandBuffer) [self.canvasCompositeLastCommandBuffer waitUntilCompleted];
    if (!self.canvasCompositeVerifyTexture || self.canvasCompositeVerifyTexture.width != pixelWidth || self.canvasCompositeVerifyTexture.height != pixelHeight) {
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:pixelWidth height:pixelHeight mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        descriptor.storageMode = MTLStorageModeShared;
        self.canvasCompositeVerifyTexture = [self.device newTextureWithDescriptor:descriptor];
    }
    if (!self.canvasCompositeVerifyTexture) return;
    if ([self compositePacketCommands:commands keys:keys target:self.canvasCompositeVerifyTexture pixelWidth:pixelWidth pixelHeight:pixelHeight scale:scale clearColor:clearColor fullSurfacePass:YES hasScissor:NO scissorRect:NSZeroRect dirtyRects:nil waitUntilCompleted:YES] != 1) {
        return;
    }
    NSUInteger byteLength = pixelWidth * pixelHeight * 4;
    NSMutableData *incrementalData = [NSMutableData dataWithLength:byteLength];
    NSMutableData *referenceData = [NSMutableData dataWithLength:byteLength];
    if (!incrementalData || !referenceData) return;
    [self.canvasTexture getBytes:incrementalData.mutableBytes bytesPerRow:pixelWidth * 4 fromRegion:MTLRegionMake2D(0, 0, pixelWidth, pixelHeight) mipmapLevel:0];
    [self.canvasCompositeVerifyTexture getBytes:referenceData.mutableBytes bytesPerRow:pixelWidth * 4 fromRegion:MTLRegionMake2D(0, 0, pixelWidth, pixelHeight) mipmapLevel:0];
    self.canvasVerifyCheckCount += 1;
    const uint8_t *incremental = (const uint8_t *)incrementalData.bytes;
    const uint8_t *reference = (const uint8_t *)referenceData.bytes;
    if (memcmp(incremental, reference, byteLength) != 0) {
        self.canvasVerifyMismatchCount += 1;
        NSUInteger firstDiff = 0;
        while (firstDiff < byteLength && incremental[firstDiff] == reference[firstDiff]) firstDiff += 1;
        NSUInteger diffPixel = firstDiff / 4;
        fprintf(stderr, "native-sdk: gpu incremental verify MISMATCH view=%s check=%llu pixel=(%lu,%lu) scissor=(%.2f,%.2f %.2fx%.2f)\n",
                self.surfaceLabel.UTF8String ?: "", (unsigned long long)self.canvasVerifyCheckCount,
                (unsigned long)(diffPixel % pixelWidth), (unsigned long)(diffPixel / pixelWidth),
                scissorRect.origin.x, scissorRect.origin.y, scissorRect.size.width, scissorRect.size.height);
    }
    if (self.canvasVerifyCheckCount == 1 || self.canvasVerifyCheckCount % 30 == 0 || self.canvasVerifyMismatchCount > 0) {
        fprintf(stderr, "native-sdk: gpu incremental verify view=%s checks=%llu mismatches=%llu\n",
                self.surfaceLabel.UTF8String ?: "",
                (unsigned long long)self.canvasVerifyCheckCount,
                (unsigned long long)self.canvasVerifyMismatchCount);
    }
}

/* Composite-vs-reference comparison: full CPU reference redraw (through
 * the same raster cache, so blend arithmetic is the only variable)
 * diffed against the composited texture. Reports differing pixels and
 * the max per-channel delta — the honest parity number. */
- (void)compareCompositeAgainstReferenceWithCommands:(NSArray *)commands keys:(NSArray *)keys pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight scale:(CGFloat)scale surfaceWidth:(CGFloat)surfaceWidth surfaceHeight:(CGFloat)surfaceHeight clearColor:(NSColor *)clearColor {
    if (!self.canvasTexture) return;
    if (self.canvasCompositeLastCommandBuffer) [self.canvasCompositeLastCommandBuffer waitUntilCompleted];
    NSUInteger byteLength = pixelWidth * pixelHeight * 4;
    if (!self.canvasVerifyPixels || self.canvasVerifyPixels.length != byteLength) {
        self.canvasVerifyPixels = [NSMutableData dataWithLength:byteLength];
    }
    NSMutableData *gpuData = [NSMutableData dataWithLength:byteLength];
    if (!self.canvasVerifyPixels || !gpuData) return;
    if ([self drawPacketCommands:commands keys:keys pixels:self.canvasVerifyPixels pixelWidth:pixelWidth pixelHeight:pixelHeight scale:scale surfaceWidth:surfaceWidth surfaceHeight:surfaceHeight clearColor:clearColor fullSurfacePass:YES hasScissor:NO scissorRect:NSZeroRect dirtyRects:nil] != 1) {
        return;
    }
    [self.canvasTexture getBytes:gpuData.mutableBytes bytesPerRow:pixelWidth * 4 fromRegion:MTLRegionMake2D(0, 0, pixelWidth, pixelHeight) mipmapLevel:0];
    const uint8_t *gpu = (const uint8_t *)gpuData.bytes;
    const uint8_t *reference = (const uint8_t *)self.canvasVerifyPixels.bytes;
    NSUInteger diffPixels = 0;
    NSUInteger maxDelta = 0;
    NSUInteger firstX = 0;
    NSUInteger firstY = 0;
    for (NSUInteger pixel = 0; pixel < pixelWidth * pixelHeight; pixel += 1) {
        NSUInteger offset = pixel * 4;
        NSUInteger pixelDelta = 0;
        for (NSUInteger channel = 0; channel < 4; channel += 1) {
            NSUInteger delta = gpu[offset + channel] > reference[offset + channel] ?
                (NSUInteger)(gpu[offset + channel] - reference[offset + channel]) :
                (NSUInteger)(reference[offset + channel] - gpu[offset + channel]);
            if (delta > pixelDelta) pixelDelta = delta;
        }
        if (pixelDelta > 0) {
            if (diffPixels == 0) {
                firstX = pixel % pixelWidth;
                firstY = pixel / pixelWidth;
            }
            diffPixels += 1;
            if (pixelDelta > maxDelta) maxDelta = pixelDelta;
        }
    }
    self.canvasCompareCheckCount += 1;
    fprintf(stderr, "native-sdk: gpu compare view=%s checks=%llu diff_pixels=%lu max_delta=%lu total_pixels=%lu first=(%lu,%lu)\n",
            self.surfaceLabel.UTF8String ?: "",
            (unsigned long long)self.canvasCompareCheckCount,
            (unsigned long)diffPixels,
            (unsigned long)maxDelta,
            (unsigned long)(pixelWidth * pixelHeight),
            (unsigned long)firstX, (unsigned long)firstY);
}

/* Visual spot-check dump: the composited texture readback as PNG. */
- (void)dumpCompositeShotWithPixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight {
    const char *dir = NativeSdkGpuShotDir();
    if (!dir || !self.canvasTexture || !self.canvasColorSpace) return;
    if (self.canvasCompositeLastCommandBuffer) [self.canvasCompositeLastCommandBuffer waitUntilCompleted];
    NSUInteger byteLength = pixelWidth * pixelHeight * 4;
    NSMutableData *data = [NSMutableData dataWithLength:byteLength];
    if (!data) return;
    [self.canvasTexture getBytes:data.mutableBytes bytesPerRow:pixelWidth * 4 fromRegion:MTLRegionMake2D(0, 0, pixelWidth, pixelHeight) mipmapLevel:0];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    if (!provider) return;
    CGImageRef image = CGImageCreate(pixelWidth, pixelHeight, 8, 32, pixelWidth * 4, self.canvasColorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big, provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    if (!image) return;
    NSString *label = self.surfaceLabel.length > 0 ? self.surfaceLabel : @"surface";
    NSString *path = [NSString stringWithFormat:@"%s/%@-p%lu.png", dir, label, (unsigned long)self.canvasCompositePresentCount];
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
    if (destination) {
        CGImageDestinationAddImage(destination, image, NULL);
        CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    CGImageRelease(image);
}

- (void)rasterCacheWipe {
    [self.canvasCommandRasterCache removeAllObjects];
    self.canvasCommandRasterCacheBytes = 0;
    [self.canvasCompositeScratchTextures removeAllObjects];
}

- (void)rasterCacheRemoveKey:(NSNumber *)key {
    if (!key || !self.canvasCommandRasterCache) return;
    NativeSdkPacketCommandRaster *entry = self.canvasCommandRasterCache[key];
    if (!entry) return;
    self.canvasCommandRasterCacheBytes -= MIN(entry.byteCount, self.canvasCommandRasterCacheBytes);
    [self.canvasCommandRasterCache removeObjectForKey:key];
}

/* Raster destinations are clamped to the surface, so a scale or surface
 * size change invalidates every entry. */
- (void)rasterCacheEnsureScale:(CGFloat)scale pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight {
    if (self.canvasCommandRasterCache && self.canvasCommandRasterCacheScale == scale &&
        self.canvasCommandRasterCachePixelWidth == pixelWidth && self.canvasCommandRasterCachePixelHeight == pixelHeight) {
        return;
    }
    [self rasterCacheWipe];
    if (!self.canvasCommandRasterCache) self.canvasCommandRasterCache = [NSMutableDictionary dictionary];
    self.canvasCommandRasterCacheScale = scale;
    self.canvasCommandRasterCachePixelWidth = pixelWidth;
    self.canvasCommandRasterCachePixelHeight = pixelHeight;
}

- (void)rasterCacheStoreEntry:(NativeSdkPacketCommandRaster *)entry forKey:(NSNumber *)key {
    if (!entry || !key || !self.canvasCommandRasterCache) return;
    [self rasterCacheRemoveKey:key];
    while (self.canvasCommandRasterCacheBytes + entry.byteCount > NativeSdkPacketRasterCacheMaxBytes && self.canvasCommandRasterCache.count > 0) {
        NSNumber *lruKey = nil;
        uint64_t lruTick = UINT64_MAX;
        for (NSNumber *candidate in self.canvasCommandRasterCache) {
            NativeSdkPacketCommandRaster *candidateEntry = self.canvasCommandRasterCache[candidate];
            if (candidateEntry.lastUseTick <= lruTick) {
                lruTick = candidateEntry.lastUseTick;
                lruKey = candidate;
            }
        }
        if (!lruKey) break;
        [self rasterCacheRemoveKey:lruKey];
    }
    self.canvasCommandRasterCache[key] = entry;
    self.canvasCommandRasterCacheBytes += entry.byteCount;
}

/* Rasterize one cacheable command into a premultiplied RGBA8 image over
 * its pixel-aligned bounds (padded one device pixel for antialiasing
 * overhang, clamped to the surface). The bitmap uses the exact CTM stack
 * of the surface draw — flip, backing scale, then a whole-pixel
 * translation — so glyph and path coverage land on the same subpixel
 * grid and the blit composites the same bytes a direct draw would. */
- (NativeSdkPacketCommandRaster *)rasterCacheFillForCommand:(NSDictionary *)command kind:(NSString *)kind key:(NSNumber *)key scale:(CGFloat)scale pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight {
    NativeSdkPacketCommandRaster *entry = [self rasterCacheBuildEntryForCommand:command kind:kind scale:scale pixelWidth:pixelWidth pixelHeight:pixelHeight];
    if (entry) [self rasterCacheStoreEntry:entry forKey:key];
    return entry;
}

/* The pure half of a cache fill: build the raster entry WITHOUT touching
 * the cache. Reads only immutable/frozen state (the command dictionary,
 * the color space, the applied per-view image cache — mutated only
 * between passes on the main thread), draws into its own bitmap through
 * the thread-local NSGraphicsContext stack, and CoreText is thread-safe;
 * registered NSImages are single-rep bitmaps never mutated after upload.
 * That makes this safe to run CONCURRENTLY for independent commands —
 * the full-pass prepass fans misses out across cores; stores stay
 * serialized on the calling thread. */
- (NativeSdkPacketCommandRaster *)rasterCacheBuildEntryForCommand:(NSDictionary *)command kind:(NSString *)kind scale:(CGFloat)scale pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight {
    NSRect bounds = CGRectStandardize(NativeSdkPacketRect(command[@"bounds"]));
    /* A command clip bounds the visible output: the raster extent is
     * bounds∩clip (scrolled content with mostly-offscreen bounds must
     * not rasterize its full extent), and the fill below applies the
     * clip so painted coverage — including the clip edge's antialiased
     * falloff — matches the direct draw byte-for-byte. */
    NSArray *clipArray = NativeSdkPacketArray(command[@"clip"], 4);
    BOOL hasCommandClip = clipArray != nil;
    NSRect commandClip = hasCommandClip ? CGRectStandardize(NativeSdkPacketRect(clipArray)) : NSZeroRect;
    if (hasCommandClip) {
        bounds = NSIntersectionRect(bounds, commandClip);
        if (NSIsEmptyRect(bounds)) return nil;
    }
    CGFloat minX = floor(NSMinX(bounds) * scale) - 1;
    CGFloat minY = floor(NSMinY(bounds) * scale) - 1;
    CGFloat maxX = ceil(NSMaxX(bounds) * scale) + 1;
    CGFloat maxY = ceil(NSMaxY(bounds) * scale) + 1;
    minX = fmax(0.0, fmin((CGFloat)pixelWidth, minX));
    minY = fmax(0.0, fmin((CGFloat)pixelHeight, minY));
    maxX = fmax(minX, fmin((CGFloat)pixelWidth, maxX));
    maxY = fmax(minY, fmin((CGFloat)pixelHeight, maxY));
    NSUInteger rasterWidth = (NSUInteger)(maxX - minX);
    NSUInteger rasterHeight = (NSUInteger)(maxY - minY);
    if (rasterWidth == 0 || rasterHeight == 0) return nil;
    NSUInteger byteCount = rasterWidth * rasterHeight * 4;
    if (byteCount > NativeSdkPacketRasterCacheMaxEntryBytes) return nil;
    if (!self.canvasColorSpace) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:byteCount];
    if (!data) return nil;
    CGContextRef bitmap = CGBitmapContextCreate(data.mutableBytes, rasterWidth, rasterHeight, 8, rasterWidth * 4, self.canvasColorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!bitmap) return nil;
    CGContextSetAllowsAntialiasing(bitmap, true);
    CGContextSetShouldAntialias(bitmap, true);
    CGContextTranslateCTM(bitmap, 0, (CGFloat)rasterHeight);
    CGContextScaleCTM(bitmap, scale, -scale);
    CGContextTranslateCTM(bitmap, -minX / scale, -minY / scale);
    NSGraphicsContext *graphics = [NSGraphicsContext graphicsContextWithCGContext:bitmap flipped:YES];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:graphics];
    CGFloat opacity = fmax(0.0, fmin(1.0, NativeSdkPacketNumber(command[@"opacity"], 1)));
    if (hasCommandClip) {
        [NSBezierPath clipRect:commandClip];
    }
    BOOL ok = NativeSdkPacketDrawCommandBody(command, kind, opacity, bitmap, scale, hasCommandClip, commandClip, self.canvasImageCache);
    [NSGraphicsContext restoreGraphicsState];
    CGImageRef cgImage = ok ? CGBitmapContextCreateImage(bitmap) : NULL;
    CGContextRelease(bitmap);
    if (!cgImage) return nil;
    NSRect destination = NSMakeRect(minX / scale, minY / scale, (maxX - minX) / scale, (maxY - minY) / scale);
    NativeSdkPacketCommandRaster *entry = [[NativeSdkPacketCommandRaster alloc] init];
    entry.command = command;
    entry.image = cgImage;
    entry.destination = destination;
    entry.byteCount = byteCount;
    CGImageRelease(cgImage);
    entry.pixelX = (NSUInteger)minX;
    entry.pixelY = (NSUInteger)minY;
    entry.pixelWidth = rasterWidth;
    entry.pixelHeight = rasterHeight;
    if (NativeSdkGpuCompositeEnabled() && self.device) {
        /* Same premultiplied bytes as a texture: the composite pass draws
         * the entry as one quad. A failed upload leaves texture nil and
         * the composite pass re-rasterizes it as a transient quad. */
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:rasterWidth height:rasterHeight mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModeShared;
        id<MTLTexture> texture = [self.device newTextureWithDescriptor:descriptor];
        if (texture) {
            [texture replaceRegion:MTLRegionMake2D(0, 0, rasterWidth, rasterHeight) mipmapLevel:0 withBytes:data.bytes bytesPerRow:rasterWidth * 4];
            entry.texture = texture;
        }
    }
    return entry;
}

/* Draw one command, through the raster cache when it has a retain key
 * and a cacheable kind: an identity hit blits the cached image instead
 * of re-rasterizing (CoreText shaping and glyph rendering dominate the
 * per-present draw cost), a miss rasterizes once and blits. Both full
 * passes and dirty updates take this path, so their pixels agree. */
- (BOOL)drawPacketCommand:(NSDictionary *)command key:(NSNumber *)key context:(CGContextRef)context scale:(CGFloat)scale hasClip:(BOOL)hasClip clipRect:(NSRect)clipRect pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight {
    if (!command) return NO;
    NSArray *boundsArray = NativeSdkPacketArray(command[@"bounds"], 4);
    if (hasClip && boundsArray && !NativeSdkPacketRectIntersects(NativeSdkPacketRect(boundsArray), clipRect)) return YES;
    const BOOL tracing = NativeSdkGpuDrawTraceEnabled();
    const uint64_t traceBeginNs = tracing ? NativeSdkTimestampNanoseconds() : 0;
    self.canvasTraceDrawnCount += 1;
    NSString *kind = [command[@"kind"] isKindOfClass:[NSString class]] ? command[@"kind"] : @"";
    if (key && boundsArray && self.canvasCommandRasterCache && NativeSdkPacketCommandRasterCacheable(command, kind)) {
        NativeSdkPacketCommandRaster *entry = self.canvasCommandRasterCache[key];
        if (entry && entry.command != command) {
            /* Same key, new content instance: the raster is stale. */
            [self rasterCacheRemoveKey:key];
            entry = nil;
        }
        BOOL filled = NO;
        if (!entry) {
            entry = [self rasterCacheFillForCommand:command kind:kind key:key scale:scale pixelWidth:pixelWidth pixelHeight:pixelHeight];
            filled = entry != nil;
        }
        if (entry) {
            if (filled) {
                self.canvasTraceCacheFillCount += 1;
            } else {
                self.canvasTraceCacheHitCount += 1;
            }
            self.canvasCommandRasterCacheTick += 1;
            entry.lastUseTick = self.canvasCommandRasterCacheTick;
            /* Raw CG blit: the raster was produced under the flipped
             * surface CTM, so its first byte row is the visual top; a
             * local flip around the destination rect lands it upright.
             * The rect is device-pixel aligned and the image is the
             * rect's exact pixel size, so the source-over composite is
             * a 1:1 copy blend — no resampling. */
            CGContextSaveGState(context);
            if (hasClip) CGContextClipToRect(context, NSRectToCGRect(clipRect));
            CGContextSetInterpolationQuality(context, kCGInterpolationNone);
            CGContextTranslateCTM(context, entry.destination.origin.x, entry.destination.origin.y + entry.destination.size.height);
            CGContextScaleCTM(context, 1, -1);
            CGContextDrawImage(context, CGRectMake(0, 0, entry.destination.size.width, entry.destination.size.height), entry.image);
            CGContextRestoreGState(context);
            if (tracing) {
                const uint64_t elapsed = NativeSdkTimestampNanoseconds() - traceBeginNs;
                if (filled) self.canvasTraceCacheFillNs += elapsed; else self.canvasTraceCacheHitNs += elapsed;
                /* NATIVE_SDK_GPU_DRAW_TRACE_KINDS=1 (with the draw trace
                 * on): per-command attribution for slow cache fills, so a
                 * hot first pass names the commands that cost it. */
                if (filled && getenv("NATIVE_SDK_GPU_DRAW_TRACE_KINDS") && elapsed > 300000) {
                    NSArray *b = boundsArray;
                    fprintf(stderr, "native-sdk: gpu cmd-trace mode=fill kind=%s us=%llu bounds=%.0f,%.0f %.0fx%.0f\n", kind.UTF8String, (unsigned long long)(elapsed / 1000), b ? NativeSdkPacketNumber(b[0], 0) : -1, b ? NativeSdkPacketNumber(b[1], 0) : -1, b ? NativeSdkPacketNumber(b[2], 0) : -1, b ? NativeSdkPacketNumber(b[3], 0) : -1);
                }
            }
            return YES;
        }
        /* Over budget or clamped empty: fall through to a direct draw. */
    }
    self.canvasTraceDirectCount += 1;
    BOOL ok = NativeSdkPacketDrawCommand(command, context, scale, hasClip, clipRect, self.canvasImageCache);
    if (tracing) {
        const uint64_t elapsed = NativeSdkTimestampNanoseconds() - traceBeginNs;
        self.canvasTraceDirectNs += elapsed;
        /* NATIVE_SDK_GPU_DRAW_TRACE_KINDS=1 (with the draw trace on):
         * per-command attribution for slow direct draws, including WHY
         * the raster cache was skipped (key/transform/clip). */
        if (getenv("NATIVE_SDK_GPU_DRAW_TRACE_KINDS") && elapsed > 300000) {
            NSArray *b = NativeSdkPacketArray(command[@"bounds"], 4);
            fprintf(stderr, "native-sdk: gpu cmd-trace mode=direct kind=%s us=%llu key=%d transform=%d clip=%d cacheable=%d bounds=%.0f,%.0f %.0fx%.0f\n", kind.UTF8String, (unsigned long long)(elapsed / 1000), key != nil, command[@"transform"] != nil, command[@"clip"] != nil, (int)NativeSdkPacketCommandRasterCacheable(command, kind), b ? NativeSdkPacketNumber(b[0], 0) : -1, b ? NativeSdkPacketNumber(b[1], 0) : -1, b ? NativeSdkPacketNumber(b[2], 0) : -1, b ? NativeSdkPacketNumber(b[3], 0) : -1);
        }
    }
    return ok;
}

/* The one shared raster pass over a command list: both packet presents
 * and the incremental verifier's reference redraw run through here, so
 * the two can never draw differently. Returns 1 on success, 0 when a
 * command is unsupported, -1 when the bitmap context cannot be built. */
- (NSInteger)drawPacketCommands:(NSArray *)commands keys:(NSArray *)keys pixels:(NSMutableData *)pixels pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight scale:(CGFloat)scale surfaceWidth:(CGFloat)surfaceWidth surfaceHeight:(CGFloat)surfaceHeight clearColor:(NSColor *)clearColor fullSurfacePass:(BOOL)fullSurfacePass hasScissor:(BOOL)hasScissor scissorRect:(NSRect)scissorRect dirtyRects:(NSArray<NSValue *> *)dirtyRects {
    (void)surfaceWidth;
    (void)surfaceHeight;
    /* The dirty rect list only refines a scissored dirty update; a full
     * pass repaints everything and must not clip to it. */
    if (fullSurfacePass || !hasScissor || dirtyRects.count == 0) dirtyRects = nil;
    if (!self.canvasColorSpace) self.canvasColorSpace = CGColorSpaceCreateDeviceRGB();
    if (!self.canvasColorSpace) return -1;
    self.canvasTraceDrawnCount = 0;
    self.canvasTraceCacheHitCount = 0;
    self.canvasTraceCacheFillCount = 0;
    self.canvasTraceDirectCount = 0;
    self.canvasTraceCacheHitNs = 0;
    self.canvasTraceCacheFillNs = 0;
    self.canvasTraceDirectNs = 0;

    /* Parallel fill prepass: collect every command this pass will draw
     * whose raster-cache lookup would MISS (no entry, or a stale entry
     * for a new content instance), rasterize them concurrently through
     * the pure build half (independent bitmaps, thread-local context
     * stacks, immutable inputs — see rasterCacheBuildEntryForCommand),
     * then store serially in command order so cache/LRU bookkeeping
     * stays single-threaded. The draw loop below then hits for every
     * prepped key and blits, cutting a first full pass (dozens of
     * shadow/text/image rasters back to back) to roughly its longest
     * single raster. Output is byte-identical to serial fills: each
     * raster is a deterministic function of one command, and blit order
     * is unchanged. Entries evicted by budget pressure between store
     * and draw simply refill inline, exactly as a serial miss would. */
    if (self.canvasCommandRasterCache && keys) {
        NSMutableArray<NSDictionary *> *missCommands = [NSMutableArray array];
        NSMutableArray<NSString *> *missKinds = [NSMutableArray array];
        NSMutableArray<NSNumber *> *missKeys = [NSMutableArray array];
        for (NSUInteger index = 0; index < commands.count; index += 1) {
            NSDictionary *command = NativeSdkPacketDictionary(commands[index]);
            if (!command) continue;
            NSNumber *key = index < keys.count && [keys[index] isKindOfClass:[NSNumber class]] ? keys[index] : nil;
            if (!key) continue;
            NSArray *boundsArray = NativeSdkPacketArray(command[@"bounds"], 4);
            if (!boundsArray) continue;
            NSRect commandBounds = NativeSdkPacketRect(boundsArray);
            /* Mirror the draw loop's culls: never prefill a command this
             * pass would not draw (wasted rasters would also churn LRU). */
            if (hasScissor && !NativeSdkPacketRectIntersects(commandBounds, scissorRect)) continue;
            if (dirtyRects) {
                BOOL intersectsDirty = NO;
                for (NSValue *value in dirtyRects) {
                    if (NativeSdkPacketRectIntersects(commandBounds, value.rectValue)) {
                        intersectsDirty = YES;
                        break;
                    }
                }
                if (!intersectsDirty) continue;
            }
            NSString *kind = [command[@"kind"] isKindOfClass:[NSString class]] ? command[@"kind"] : @"";
            if (!NativeSdkPacketCommandRasterCacheable(command, kind)) continue;
            NativeSdkPacketCommandRaster *entry = self.canvasCommandRasterCache[key];
            if (entry && entry.command == command && entry.image) continue;
            [missCommands addObject:command];
            [missKinds addObject:kind];
            [missKeys addObject:key];
        }
        if (missCommands.count >= 2) {
            const uint64_t prepassBegin = NativeSdkTimestampNanoseconds();
            const NSUInteger missCount = missCommands.count;
            void **built = calloc(missCount, sizeof(void *));
            if (built) {
                dispatch_apply(missCount, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^(size_t missIndex) {
                    NativeSdkPacketCommandRaster *entry = [self rasterCacheBuildEntryForCommand:missCommands[missIndex] kind:missKinds[missIndex] scale:scale pixelWidth:pixelWidth pixelHeight:pixelHeight];
                    if (entry) built[missIndex] = (void *)CFBridgingRetain(entry);
                });
                for (NSUInteger missIndex = 0; missIndex < missCount; missIndex += 1) {
                    if (!built[missIndex]) continue;
                    NativeSdkPacketCommandRaster *entry = CFBridgingRelease(built[missIndex]);
                    [self rasterCacheStoreEntry:entry forKey:missKeys[missIndex]];
                    self.canvasTraceCacheFillCount += 1;
                }
                free(built);
                /* Fill time is the prepass WALL clock — the number that
                 * moved — not summed per-thread raster time. */
                self.canvasTraceCacheFillNs += NativeSdkTimestampNanoseconds() - prepassBegin;
            }
        }
    }

    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, pixelWidth, pixelHeight, 8, pixelWidth * 4, self.canvasColorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!context) return -1;

    CGContextSetAllowsAntialiasing(context, true);
    CGContextSetShouldAntialias(context, true);
    CGContextTranslateCTM(context, 0, (CGFloat)pixelHeight);
    CGContextScaleCTM(context, scale, -scale);

    NSGraphicsContext *graphics = [NSGraphicsContext graphicsContextWithCGContext:context flipped:YES];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:graphics];
    if (fullSurfacePass) {
        /* Fill the whole pixel extent (not just the point-space surface
         * rect): the backing is reused across presents, so the fractional
         * last row/column a point-space fill leaves partially covered
         * must be repainted deterministically, not blend with history.
         * Explicit copy compositing for the same reason — the clear
         * REPLACES history (a translucent clear must not accumulate). */
        [clearColor setFill];
        NSRectFillUsingOperation(NSMakeRect(0, 0, (CGFloat)pixelWidth / scale, (CGFloat)pixelHeight / scale), NSCompositingOperationCopy);
    } else if (hasScissor && dirtyRects) {
        /* Refined pass: only the listed rects clear and repaint — the
         * pixels between two far-apart changes stay retained. */
        [clearColor setFill];
        for (NSValue *value in dirtyRects) {
            NSRectFillUsingOperation(value.rectValue, NSCompositingOperationCopy);
        }
    } else if (hasScissor) {
        [clearColor setFill];
        NSRectFillUsingOperation(scissorRect, NSCompositingOperationCopy);
    }
    if (hasScissor) {
        [NSBezierPath clipRect:scissorRect];
        if (dirtyRects) {
            NSBezierPath *dirtyPath = [NSBezierPath bezierPath];
            for (NSValue *value in dirtyRects) {
                [dirtyPath appendBezierPathWithRect:value.rectValue];
            }
            [dirtyPath addClip];
        }
    }

    BOOL supported = YES;
    for (NSUInteger index = 0; index < commands.count; index += 1) {
        NSDictionary *command = NativeSdkPacketDictionary(commands[index]);
        NSNumber *key = nil;
        if (keys && index < keys.count && [keys[index] isKindOfClass:[NSNumber class]]) key = keys[index];
        if (dirtyRects && command) {
            /* Cull against the refined rects: a command outside all of
             * them cannot change a pixel this pass may touch. */
            NSArray *boundsArray = NativeSdkPacketArray(command[@"bounds"], 4);
            if (boundsArray) {
                NSRect commandBounds = NativeSdkPacketRect(boundsArray);
                BOOL intersectsDirty = NO;
                for (NSValue *value in dirtyRects) {
                    if (NativeSdkPacketRectIntersects(commandBounds, value.rectValue)) {
                        intersectsDirty = YES;
                        break;
                    }
                }
                if (!intersectsDirty) continue;
            }
        }
        if (![self drawPacketCommand:command key:key context:context scale:scale hasClip:hasScissor clipRect:scissorRect pixelWidth:pixelWidth pixelHeight:pixelHeight]) {
            supported = NO;
            break;
        }
    }
    [NSGraphicsContext restoreGraphicsState];
    CGContextRelease(context);
    return supported ? 1 : 0;
}

- (void)verifyIncrementalBackingWithCommands:(NSArray *)commands keys:(NSArray *)keys pixelWidth:(NSUInteger)pixelWidth pixelHeight:(NSUInteger)pixelHeight scale:(CGFloat)scale surfaceWidth:(CGFloat)surfaceWidth surfaceHeight:(CGFloat)surfaceHeight clearColor:(NSColor *)clearColor scissorRect:(NSRect)scissorRect {
    NSUInteger byteLength = pixelWidth * pixelHeight * 4;
    if (!self.canvasPacketPixels || self.canvasPacketPixels.length != byteLength) return;
    if (!self.canvasVerifyPixels || self.canvasVerifyPixels.length != byteLength) {
        self.canvasVerifyPixels = [NSMutableData dataWithLength:byteLength];
    }
    if (!self.canvasVerifyPixels) return;
    if ([self drawPacketCommands:commands keys:keys pixels:self.canvasVerifyPixels pixelWidth:pixelWidth pixelHeight:pixelHeight scale:scale surfaceWidth:surfaceWidth surfaceHeight:surfaceHeight clearColor:clearColor fullSurfacePass:YES hasScissor:NO scissorRect:NSZeroRect dirtyRects:nil] != 1) {
        return;
    }
    self.canvasVerifyCheckCount += 1;
    const uint8_t *incremental = (const uint8_t *)self.canvasPacketPixels.bytes;
    const uint8_t *reference = (const uint8_t *)self.canvasVerifyPixels.bytes;
    if (memcmp(incremental, reference, byteLength) != 0) {
        self.canvasVerifyMismatchCount += 1;
        NSUInteger firstDiff = 0;
        while (firstDiff < byteLength && incremental[firstDiff] == reference[firstDiff]) firstDiff += 1;
        NSUInteger diffPixel = firstDiff / 4;
        fprintf(stderr, "native-sdk: gpu incremental verify MISMATCH view=%s check=%llu pixel=(%lu,%lu) scissor=(%.2f,%.2f %.2fx%.2f)\n",
                self.surfaceLabel.UTF8String ?: "", (unsigned long long)self.canvasVerifyCheckCount,
                (unsigned long)(diffPixel % pixelWidth), (unsigned long)(diffPixel / pixelWidth),
                scissorRect.origin.x, scissorRect.origin.y, scissorRect.size.width, scissorRect.size.height);
    }
    if (self.canvasVerifyCheckCount == 1 || self.canvasVerifyCheckCount % 30 == 0 || self.canvasVerifyMismatchCount > 0) {
        fprintf(stderr, "native-sdk: gpu incremental verify view=%s checks=%llu mismatches=%llu\n",
                self.surfaceLabel.UTF8String ?: "",
                (unsigned long long)self.canvasVerifyCheckCount,
                (unsigned long long)self.canvasVerifyMismatchCount);
    }
}

- (NSInteger)presentGpuPacketObject:(NSDictionary *)packet surfaceWidth:(CGFloat)surfaceWidth height:(CGFloat)surfaceHeight scale:(CGFloat)scale clearR:(uint8_t)clearR clearG:(uint8_t)clearG clearB:(uint8_t)clearB clearA:(uint8_t)clearA commandCount:(NSUInteger)commandCount {
    if (!packet) return 0;
    CGFloat normalizedScale = scale > 0 ? scale : 1;
    NSUInteger pixelWidth = (NSUInteger)ceil(surfaceWidth * normalizedScale);
    NSUInteger pixelHeight = (NSUInteger)ceil(surfaceHeight * normalizedScale);
    if (pixelWidth == 0 || pixelHeight == 0) return 0;
    if (pixelWidth > 8192 || pixelHeight > 8192) return 0;

    NSString *loadAction = [packet[@"loadAction"] isKindOfClass:[NSString class]] ? packet[@"loadAction"] : @"";
    BOOL clearLoadAction = [loadAction isEqualToString:@"clear"];
    BOOL retainedLoadAction = [loadAction isEqualToString:@"load"];
    BOOL patchLoadAction = [loadAction isEqualToString:@"patch"];
    if (!clearLoadAction && !retainedLoadAction && !patchLoadAction) return 0;

    NSArray *commands = nil;
    if (patchLoadAction) {
        /* Incremental present: apply the edit script to the retained
         * command dictionary, then draw from it. Every precondition
         * failure refuses (return 0) so the engine resyncs with a full
         * present; failures after mutation begins ALSO drop the retained
         * state so a refused half-applied patch can never be patched
         * again — resync or nothing, never partial state. */
        if (!self.hasCanvasRetainedState || !self.canvasRetainedCommands || !self.canvasRetainedOrder) return 0;
        uint64_t generation = [packet[@"generation"] respondsToSelector:@selector(unsignedLongLongValue)] ? [packet[@"generation"] unsignedLongLongValue] : 0;
        if (generation == 0 || generation != self.canvasRetainedGeneration) return 0;
        NSArray *evicts = NativeSdkPacketArray(packet[@"patchEvicts"], 0);
        NSArray *upserts = NativeSdkPacketArray(packet[@"patchUpserts"], 0);
        NSArray *order = NativeSdkPacketArray(packet[@"patchOrder"], 0);
        if (!evicts || !upserts || !order) return 0;
        for (id evictObject in evicts) {
            if (![evictObject isKindOfClass:[NSNumber class]]) { self.hasCanvasRetainedState = NO; return 0; }
            /* Evicting a key we do not hold means the two sides disagree
             * about the baseline — drift, refuse. */
            if (!self.canvasRetainedCommands[evictObject]) { self.hasCanvasRetainedState = NO; return 0; }
            [self.canvasRetainedCommands removeObjectForKey:evictObject];
            [self rasterCacheRemoveKey:evictObject];
        }
        for (id upsertObject in upserts) {
            NSDictionary *upsert = NativeSdkPacketDictionary(upsertObject);
            NSNumber *key = [upsert[@"key"] isKindOfClass:[NSNumber class]] ? upsert[@"key"] : nil;
            NSDictionary *command = NativeSdkPacketDictionary(upsert[@"command"]);
            if (!key || !command) { self.hasCanvasRetainedState = NO; return 0; }
            self.canvasRetainedCommands[key] = command;
            [self rasterCacheRemoveKey:key];
        }
        if (self.canvasRetainedCommands.count > NativeSdkPacketRetainedCommandCap) { self.hasCanvasRetainedState = NO; return 0; }
        /* Draw order comes exclusively from the order vector, and it must
         * name the retained set exactly — a dangling or missing key is
         * drift. */
        if (order.count != self.canvasRetainedCommands.count) { self.hasCanvasRetainedState = NO; return 0; }
        NSMutableArray *ordered = [NSMutableArray arrayWithCapacity:order.count];
        NSMutableArray *orderKeys = [NSMutableArray arrayWithCapacity:order.count];
        for (id keyObject in order) {
            NSDictionary *command = [keyObject isKindOfClass:[NSNumber class]] ? self.canvasRetainedCommands[keyObject] : nil;
            if (!command) { self.hasCanvasRetainedState = NO; return 0; }
            [ordered addObject:command];
            [orderKeys addObject:keyObject];
        }
        self.canvasRetainedOrder = orderKeys;
        commands = ordered;
    } else {
        commands = NativeSdkPacketArray(packet[@"commands"], 0);
    }
    if (!commands) return 0;
    if (commandCount != 0 && commands.count != commandCount) {
        if (patchLoadAction) self.hasCanvasRetainedState = NO;
        return 0;
    }
    NSArray *images = NativeSdkPacketArray(packet[@"images"], 0) ?: @[];
    NSArray *imageActions = NativeSdkPacketArray(packet[@"imageActions"], 0) ?: @[];
    if (!self.canvasImageCache) self.canvasImageCache = [NSMutableDictionary dictionary];
    if (!NativeSdkPacketApplyImageActions(imageActions, images, self.canvasImageCache, self.host.canvasImageStore)) {
        if (patchLoadAction) self.hasCanvasRetainedState = NO;
        return 0;
    }
    if (imageActions.count > 0 && self.canvasCommandRasterCache.count > 0) {
        /* The raster cache holds drawn image output per command; an image
         * upload/evict changes that output under an unchanged command
         * dictionary, so drop cached image rasters when actions arrive. */
        BOOL imagesTouched = NO;
        for (id actionObject in imageActions) {
            NSString *kind = [NativeSdkPacketDictionary(actionObject)[@"kind"] isKindOfClass:[NSString class]] ? NativeSdkPacketDictionary(actionObject)[@"kind"] : @"";
            if ([kind isEqualToString:@"upload"] || [kind isEqualToString:@"evict"]) {
                imagesTouched = YES;
                break;
            }
        }
        if (imagesTouched) {
            NSMutableArray *imageRasterKeys = [NSMutableArray array];
            for (NSNumber *cacheKey in self.canvasCommandRasterCache) {
                NativeSdkPacketCommandRaster *entry = self.canvasCommandRasterCache[cacheKey];
                if ([[entry.command[@"kind"] description] isEqualToString:@"draw_image"]) [imageRasterKeys addObject:cacheKey];
            }
            for (NSNumber *cacheKey in imageRasterKeys) [self rasterCacheRemoveKey:cacheKey];
        }
    }
    NSArray *scissor = NativeSdkPacketArray(packet[@"scissorBounds"], 4);
    BOOL hasScissor = scissor != nil;
    /* Snap the scissor outward to the device-pixel grid: fractional clip
     * edges antialias, blending fresh paint with retained pixels at the
     * region boundary — a seam, and a byte difference vs a full redraw. */
    NSRect scissorRect = hasScissor ? NativeSdkPacketAlignRectToPixels(NativeSdkPacketRect(scissor), normalizedScale, pixelWidth, pixelHeight) : NSZeroRect;
    /* Optional v3 refinement: the exact rects the edit script touches,
     * snapped like the scissor and bounded by it. */
    NSMutableArray<NSValue *> *dirtyRects = nil;
    NSArray *dirtyRectArrays = NativeSdkPacketArray(packet[@"dirtyRects"], 0);
    if (hasScissor && dirtyRectArrays.count > 0 && dirtyRectArrays.count <= 8) {
        dirtyRects = [NSMutableArray arrayWithCapacity:dirtyRectArrays.count];
        for (id rectValue in dirtyRectArrays) {
            NSArray *rectArray = NativeSdkPacketArray(rectValue, 4);
            if (!rectArray) {
                dirtyRects = nil;
                break;
            }
            NSRect snapped = NativeSdkPacketAlignRectToPixels(NativeSdkPacketRect(rectArray), normalizedScale, pixelWidth, pixelHeight);
            snapped = NSIntersectionRect(snapped, scissorRect);
            if (NSIsEmptyRect(snapped)) continue;
            [dirtyRects addObject:[NSValue valueWithRect:snapped]];
        }
        if (dirtyRects.count == 0) dirtyRects = nil;
    }

    /* A patch without a scissor repaints the whole surface from the
     * retained list — clear semantics over the retained backing. */
    BOOL fullSurfacePass = clearLoadAction || (patchLoadAction && !hasScissor);
    NSUInteger byteLengthRequired = pixelWidth * pixelHeight * 4;
    BOOL directRetainedDirtyUpdate = (retainedLoadAction || patchLoadAction) && hasScissor;
    [self rasterCacheEnsureScale:normalizedScale pixelWidth:pixelWidth pixelHeight:pixelHeight];
    if (NativeSdkGpuCompositeEnabled() && [self ensureCanvasCompositor]) {
        /* GPU composite path (prototype, env-gated): the frame is drawn
         * by a render command encoder into the canvas texture; the CPU
         * retained backing is not touched. Shares the retained-state
         * bookkeeping below via the same helper. */
        NSColor *compositeClearColor = [NSColor colorWithDeviceRed:(CGFloat)clearR / 255.0 green:(CGFloat)clearG / 255.0 blue:(CGFloat)clearB / 255.0 alpha:(CGFloat)clearA / 255.0];
        NSArray *compositeKeys = nil;
        if (patchLoadAction) {
            compositeKeys = self.canvasRetainedOrder;
        } else {
            NSArray *packetCommandKeys = NativeSdkPacketArray(packet[@"commandKeys"], 0);
            if (packetCommandKeys.count == commands.count) compositeKeys = packetCommandKeys;
        }
        NSInteger compositeResult = [self presentCompositePacketWithCommands:commands keys:compositeKeys pixelWidth:pixelWidth pixelHeight:pixelHeight scale:normalizedScale surfaceWidth:surfaceWidth surfaceHeight:surfaceHeight clearColor:compositeClearColor loadAction:loadAction fullSurfacePass:fullSurfacePass hasScissor:hasScissor scissorRect:scissorRect dirtyRects:dirtyRects directRetainedDirtyUpdate:directRetainedDirtyUpdate];
        if (compositeResult != 1) {
            if (patchLoadAction) self.hasCanvasRetainedState = NO;
            return compositeResult;
        }
        [self recordCanvasRetainedStateForPacket:packet commands:commands patchLoadAction:patchLoadAction clearLoadAction:clearLoadAction];
        return 1;
    }
    if (fullSurfacePass) {
        /* Full passes paint every pixel of the retained backing in place —
         * no per-present 16 MB buffer, no copy-back after the upload. The
         * validity flag covers the mutation window: a draw that fails
         * mid-pass leaves the backing dirty and every later dirty update
         * refuses until a successful full pass repaints it. */
        if (!self.canvasPacketPixels || self.canvasPacketPixelWidth != pixelWidth || self.canvasPacketPixelHeight != pixelHeight || self.canvasPacketPixels.length != byteLengthRequired) {
            self.canvasPacketPixels = [NSMutableData dataWithLength:byteLengthRequired];
            self.canvasPacketPixelWidth = pixelWidth;
            self.canvasPacketPixelHeight = pixelHeight;
        }
        self.canvasPacketPixelsValid = NO;
    } else {
        if (!self.canvasPacketPixels || !self.canvasPacketPixelsValid || self.canvasPacketPixelWidth != pixelWidth || self.canvasPacketPixelHeight != pixelHeight || self.canvasPacketPixels.length != byteLengthRequired) {
            if (patchLoadAction) self.hasCanvasRetainedState = NO;
            return 0;
        }
        self.canvasPacketPixelsValid = NO;
    }
    NSMutableData *pixels = self.canvasPacketPixels;
    if (!pixels || pixels.length != byteLengthRequired) return -1;

    NSColor *clearColor = [NSColor colorWithDeviceRed:(CGFloat)clearR / 255.0 green:(CGFloat)clearG / 255.0 blue:(CGFloat)clearB / 255.0 alpha:(CGFloat)clearA / 255.0];
    /* Retain keys parallel to the draw order feed the raster cache; a
     * packet without keys (JSON without commandKeys) draws direct. */
    NSArray *drawKeys = nil;
    if (patchLoadAction) {
        drawKeys = self.canvasRetainedOrder;
    } else {
        NSArray *packetCommandKeys = NativeSdkPacketArray(packet[@"commandKeys"], 0);
        if (packetCommandKeys.count == commands.count) drawKeys = packetCommandKeys;
    }

    const uint64_t traceDrawBeginNs = NativeSdkTimestampNanoseconds();
    NSInteger drawResult = [self drawPacketCommands:commands keys:drawKeys pixels:pixels pixelWidth:pixelWidth pixelHeight:pixelHeight scale:normalizedScale surfaceWidth:surfaceWidth surfaceHeight:surfaceHeight clearColor:clearColor fullSurfacePass:fullSurfacePass hasScissor:hasScissor scissorRect:scissorRect dirtyRects:dirtyRects];
    const uint64_t traceDrawEndNs = NativeSdkTimestampNanoseconds();
    if (drawResult < 0) return -1;
    if (drawResult == 0) {
        if (patchLoadAction) self.hasCanvasRetainedState = NO;
        return 0;
    }
    self.canvasPacketPixelsValid = YES;

    if (directRetainedDirtyUpdate && NativeSdkGpuVerifyIncrementalEnabled()) {
        /* The drawn list is always the FULL retained command list (a
         * scissor only narrows the repaint), so a from-scratch full
         * redraw of the same list must byte-match the patched backing. */
        [self verifyIncrementalBackingWithCommands:commands keys:drawKeys pixelWidth:pixelWidth pixelHeight:pixelHeight scale:normalizedScale surfaceWidth:surfaceWidth surfaceHeight:surfaceHeight clearColor:clearColor scissorRect:scissorRect];
    }

    BOOL uploadDirtyRect = directRetainedDirtyUpdate;
    BOOL presented = [self presentPixelsWithWidth:pixelWidth height:pixelHeight scale:normalizedScale hasDirtyRect:uploadDirtyRect dirtyX:scissorRect.origin.x dirtyY:scissorRect.origin.y dirtyWidth:scissorRect.size.width dirtyHeight:scissorRect.size.height dirtyRects:(uploadDirtyRect ? dirtyRects : nil) rgba8:(const uint8_t *)pixels.bytes byteLength:pixels.length];
    if (getenv("NATIVE_SDK_GPU_DRAW_TRACE")) {
        /* Per-present phase split (draw vs texture upload + Metal present),
         * NATIVE_SDK_WINDOW_TIMING-style stderr diagnostics. */
        const uint64_t tracePresentEndNs = NativeSdkTimestampNanoseconds();
        fprintf(stderr, "native-sdk: gpu draw-trace action=%s scissor=%d rect=%.0fx%.0f rects=%lu draw_us=%llu present_us=%llu drawn=%lu hit=%lu/%lluus fill=%lu/%lluus direct=%lu/%lluus\n",
                loadAction.UTF8String, hasScissor ? 1 : 0, scissorRect.size.width, scissorRect.size.height,
                (unsigned long)dirtyRects.count,
                (unsigned long long)((traceDrawEndNs - traceDrawBeginNs) / 1000),
                (unsigned long long)((tracePresentEndNs - traceDrawEndNs) / 1000),
                (unsigned long)self.canvasTraceDrawnCount,
                (unsigned long)self.canvasTraceCacheHitCount,
                (unsigned long long)(self.canvasTraceCacheHitNs / 1000),
                (unsigned long)self.canvasTraceCacheFillCount,
                (unsigned long long)(self.canvasTraceCacheFillNs / 1000),
                (unsigned long)self.canvasTraceDirectCount,
                (unsigned long long)(self.canvasTraceDirectNs / 1000));
    }
    if (!presented) {
        if (patchLoadAction) self.hasCanvasRetainedState = NO;
        return -1;
    }

    [self recordCanvasRetainedStateForPacket:packet commands:commands patchLoadAction:patchLoadAction clearLoadAction:clearLoadAction];
    return 1;
}

/* Retained-state bookkeeping, only after the frame actually reached
 * the glass (shared by the CPU and GPU-composite present paths). A keyed
 * `clear` under a nonzero generation is a baseline: rebuild the
 * dictionary + order. A patch already updated them during apply. Every
 * OTHER present (scissor-subset load, JSON packets without keys,
 * generation-0 binary) moves the glass past the dictionary, so the
 * retained state drops and the next patch attempt refuses into a full
 * resync. */
- (void)recordCanvasRetainedStateForPacket:(NSDictionary *)packet commands:(NSArray *)commands patchLoadAction:(BOOL)patchLoadAction clearLoadAction:(BOOL)clearLoadAction {
    if (patchLoadAction) {
        /* state updated during apply; generation unchanged */
        return;
    }
    uint64_t generation = [packet[@"generation"] respondsToSelector:@selector(unsignedLongLongValue)] ? [packet[@"generation"] unsignedLongLongValue] : 0;
    NSArray *commandKeys = NativeSdkPacketArray(packet[@"commandKeys"], 0);
    BOOL retainable = clearLoadAction && generation != 0 && commandKeys != nil &&
        commandKeys.count == commands.count && commands.count <= NativeSdkPacketRetainedCommandCap;
    if (retainable) {
        NSMutableDictionary *retained = [NSMutableDictionary dictionaryWithCapacity:commands.count];
        NSMutableArray *order = [NSMutableArray arrayWithCapacity:commands.count];
        for (NSUInteger index = 0; index < commands.count; index += 1) {
            NSNumber *key = [commandKeys[index] isKindOfClass:[NSNumber class]] ? commandKeys[index] : nil;
            NSDictionary *command = NativeSdkPacketDictionary(commands[index]);
            if (!key || !command || retained[key]) { retainable = NO; break; }
            retained[key] = command;
            [order addObject:key];
        }
        if (retainable) {
            self.canvasRetainedCommands = retained;
            self.canvasRetainedOrder = order;
            self.canvasRetainedGeneration = generation;
            self.hasCanvasRetainedState = YES;
        }
    }
    if (!retainable) {
        self.hasCanvasRetainedState = NO;
        /* Keys from the dropped dictionary may never be seen again;
         * identity checks keep stale entries harmless, this keeps
         * them from holding memory. */
        [self rasterCacheWipe];
    }
}

- (BOOL)ensureCanvasPresenter {
    if (self.canvasRenderPipeline && self.canvasSampler) return YES;
    if (!self.device || !self.metalLayer) return NO;

    static NSString *shaderSource =
        @"#include <metal_stdlib>\n"
        @"using namespace metal;\n"
        @"struct NativeSdkCanvasVertexOut { float4 position [[position]]; float2 uv; };\n"
        @"vertex NativeSdkCanvasVertexOut native_sdk_canvas_vertex(uint vertex_id [[vertex_id]]) {\n"
        @"  constexpr float2 positions[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };\n"
        @"  constexpr float2 uvs[4] = { float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0) };\n"
        @"  NativeSdkCanvasVertexOut out;\n"
        @"  out.position = float4(positions[vertex_id], 0.0, 1.0);\n"
        @"  out.uv = uvs[vertex_id];\n"
        @"  return out;\n"
        @"}\n"
        @"fragment float4 native_sdk_canvas_fragment(NativeSdkCanvasVertexOut in [[stage_in]], texture2d<float> canvas_texture [[texture(0)]], sampler texture_sampler [[sampler(0)]]) {\n"
        @"  return canvas_texture.sample(texture_sampler, in.uv);\n"
        @"}\n";

    NSError *libraryError = nil;
    id<MTLLibrary> library = [self.device newLibraryWithSource:shaderSource options:nil error:&libraryError];
    if (!library) return NO;
    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"native_sdk_canvas_vertex"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"native_sdk_canvas_fragment"];
    if (!vertexFunction || !fragmentFunction) return NO;

    MTLRenderPipelineDescriptor *pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDescriptor.label = @"native-sdk canvas presenter";
    pipelineDescriptor.vertexFunction = vertexFunction;
    pipelineDescriptor.fragmentFunction = fragmentFunction;
    pipelineDescriptor.colorAttachments[0].pixelFormat = self.metalLayer.pixelFormat;

    NSError *pipelineError = nil;
    id<MTLRenderPipelineState> pipeline = [self.device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&pipelineError];
    if (!pipeline) return NO;

    // The canvas texture is already rasterized at backing scale; present it without filtering.
    MTLSamplerDescriptor *samplerDescriptor = [[MTLSamplerDescriptor alloc] init];
    samplerDescriptor.minFilter = MTLSamplerMinMagFilterNearest;
    samplerDescriptor.magFilter = MTLSamplerMinMagFilterNearest;
    samplerDescriptor.mipFilter = MTLSamplerMipFilterNotMipmapped;
    samplerDescriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
    samplerDescriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
    id<MTLSamplerState> sampler = [self.device newSamplerStateWithDescriptor:samplerDescriptor];
    if (!sampler) return NO;

    self.canvasRenderPipeline = pipeline;
    self.canvasSampler = sampler;
    return YES;
}

- (void)updateWidgetAccessibilityWithNodes:(const native_sdk_appkit_widget_accessibility_node_t *)nodes count:(NSUInteger)count {
    if (!nodes || count == 0) {
        self.widgetAccessibilityElements = @[];
        NSAccessibilityPostNotification(self, NSAccessibilityLayoutChangedNotification);
        return;
    }

    NSMutableArray<NSAccessibilityElement *> *elements = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        const native_sdk_appkit_widget_accessibility_node_t node = nodes[index];
        NSString *label = NativeSdkStringFromBytes(node.label, node.label_len) ?: @"";
        NSString *textValue = NativeSdkStringFromBytes(node.text_value, node.text_value_len) ?: @"";
        NSString *placeholder = NativeSdkStringFromBytes(node.placeholder, node.placeholder_len) ?: @"";
        NSString *name = label.length > 0 ? label : textValue;
        NativeSdkWidgetAccessibilityElement *element = [[NativeSdkWidgetAccessibilityElement alloc] init];
        element.surfaceView = self;
        element.widgetId = node.id;
        element.actionFlags = node.action_flags;
        element.accessibilityParent = self;
        element.accessibilityRole = NativeSdkAccessibilityRoleForWidgetRole(node.role);
        element.accessibilityIdentifier = [NSString stringWithFormat:@"native-sdk-widget-%llu", node.id];
        element.accessibilityLabel = name;
        if (node.has_value) {
            element.accessibilityValue = [NSString stringWithFormat:@"%.3f", node.value];
        } else if (textValue.length > 0) {
            element.accessibilityValue = textValue;
        }
        if (placeholder.length > 0 && [element respondsToSelector:@selector(setAccessibilityPlaceholderValue:)]) {
            element.accessibilityPlaceholderValue = placeholder;
        }
        if (node.has_grid_row_count) {
            element.accessibilityRowCount = (NSInteger)node.grid_row_count;
        }
        if (node.has_grid_column_count) {
            element.accessibilityColumnCount = (NSInteger)node.grid_column_count;
        }
        if (node.has_grid_row_index) {
            element.accessibilityRowIndexRange = NSMakeRange(node.grid_row_index, 1);
            if (node.role == NATIVE_SDK_APPKIT_WIDGET_ROLE_ROW) {
                element.accessibilityIndex = (NSInteger)node.grid_row_index;
            }
        }
        if (node.has_grid_column_index) {
            element.accessibilityColumnIndexRange = NSMakeRange(node.grid_column_index, 1);
        }
        if (node.has_list_item_index) {
            element.accessibilityIndex = (NSInteger)node.list_item_index;
            if (node.has_list_item_count && !node.has_value) {
                uint32_t displayIndex = node.list_item_index == UINT32_MAX ? node.list_item_index : node.list_item_index + 1;
                element.accessibilityValueDescription = [NSString stringWithFormat:@"%u of %u", displayIndex, node.list_item_count];
            }
        }
        if (node.has_scroll_offset) {
            element.accessibilityMinValue = @0;
            if (node.has_scroll_viewport_extent && node.has_scroll_content_extent) {
                element.accessibilityMaxValue = @(MAX(0, node.scroll_content_extent - node.scroll_viewport_extent));
            }
            element.accessibilityValue = @(node.scroll_offset);
        }
        if (textValue.length > 0) {
            NSRange visibleRange = NSMakeRange(0, textValue.length);
            element.accessibilityNumberOfCharacters = (NSInteger)textValue.length;
            element.accessibilityVisibleCharacterRange = visibleRange;
            if (node.has_text_selection) {
                NSRange selectedRange = NativeSdkClampedRange(node.text_selection_start, node.text_selection_end, textValue.length);
                element.accessibilitySelectedTextRange = selectedRange;
                element.accessibilitySelectedTextRanges = @[[NSValue valueWithRange:selectedRange]];
                element.accessibilitySelectedText = NativeSdkSubstringForRange(textValue, selectedRange);
                element.accessibilityInsertionPointLineNumber = 0;
            }
        }
        element.accessibilityEnabled = (node.state_flags & NATIVE_SDK_APPKIT_WIDGET_STATE_ENABLED) != 0;
        element.accessibilityFocused = (node.state_flags & NATIVE_SDK_APPKIT_WIDGET_STATE_FOCUSED) != 0;
        element.accessibilitySelected = (node.state_flags & NATIVE_SDK_APPKIT_WIDGET_STATE_SELECTED) != 0;
        if ((node.state_flags & NATIVE_SDK_APPKIT_WIDGET_STATE_EXPANDED) != 0) {
            element.accessibilityExpanded = YES;
        } else if ((node.state_flags & NATIVE_SDK_APPKIT_WIDGET_STATE_COLLAPSED) != 0) {
            element.accessibilityExpanded = NO;
        }
        if ([element respondsToSelector:@selector(setAccessibilityRequired:)]) {
            element.accessibilityRequired = (node.state_flags & NATIVE_SDK_APPKIT_WIDGET_STATE_REQUIRED) != 0;
        }
        NSMutableArray<NSString *> *stateDescriptions = [NSMutableArray array];
        if ((node.state_flags & NATIVE_SDK_APPKIT_WIDGET_STATE_READ_ONLY) != 0) {
            [stateDescriptions addObject:@"Read only"];
        }
        if ((node.state_flags & NATIVE_SDK_APPKIT_WIDGET_STATE_INVALID) != 0) {
            [stateDescriptions addObject:@"Invalid"];
        }
        if (stateDescriptions.count > 0 && element.accessibilityValueDescription.length == 0) {
            element.accessibilityValueDescription = [stateDescriptions componentsJoinedByString:@", "];
        }
        CGFloat nativeY = self.bounds.size.height - node.y - node.height;
        element.accessibilityFrameInParentSpace = NSMakeRect(node.x, nativeY, node.width, node.height);
        [elements addObject:element];
    }
    self.widgetAccessibilityElements = elements;
    NSAccessibilityPostNotification(self, NSAccessibilityLayoutChangedNotification);
}

- (void)stopDisplayTimer {
    [self.displayTimer invalidate];
    self.displayTimer = nil;
}

- (void)requestRetainedCanvasFrame {
    if (!self.hasCanvasTexture) {
        // FIRST canvas frame: nothing is retained and nothing has ever
        // presented, so there is no drawable pool to protect with pacing.
        // Dropping the request here (the old behavior) left the first
        // present waiting for the 60 Hz placeholder timer to tick — a
        // measured 40+ ms of launch-to-glass latency. Emit the request
        // immediately instead, once; failures fall back to the timer.
        if (self.retainedFrameRequestPending || self.firstCanvasFrameRequestEmitted) return;
        self.firstCanvasFrameRequestEmitted = YES;
        self.retainedFrameRequestPending = YES;
        __weak NativeSdkMetalSurfaceView *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            NativeSdkMetalSurfaceView *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf emitFirstCanvasFrameRequest];
        });
        return;
    }
    [self scheduleFrameEventEmission];
}

/* The runtime dispatched an input to this surface (real or automation —
 * automation input is synthesized runtime-side and never passes through
 * this host's event methods, which is why the note crosses the ABI):
 * the input's responding frame must fire at display-grid promptness even
 * while occluded. A parked heartbeat emission is superseded the same way
 * de-occlusion supersedes one; the one-shot flag covers the frame
 * request that arrives during the input dispatch itself. */
- (void)noteGpuSurfaceInputActivity {
    self.inputDrivenFramePending = YES;
    [self rescheduleParkedFrameEventEmission];
}

/* Supersede a parked emission with a freshly-paced one (de-occlusion,
 * input activity): bump the generation to strand the queued block and
 * schedule the replacement. If the reschedule is refused (the view went
 * hidden or unavailable while the block was parked), release the armed-
 * channel activity here — the stranded block no-ops on its generation
 * check, so nothing else would. */
- (void)rescheduleParkedFrameEventEmission {
    if (!self.frameEventEmissionScheduled) return;
    self.frameEventEmissionGeneration += 1;
    self.frameEventEmissionScheduled = NO;
    [self scheduleFrameEventEmission];
    if (!self.frameEventEmissionScheduled && self.frameChannelActivity) {
        [[NSProcessInfo processInfo] endActivity:self.frameChannelActivity];
        self.frameChannelActivity = nil;
    }
}

// Synchronous pre-run flush for a first-frame request queued during the
// START dispatch: the async main-queue hop only runs once [NSApp run]
// starts pumping, a measured ~40 ms after launch work is otherwise done.
// runWithCallback calls this after its start/appearance/resize/frame
// emits, when the host is between engine dispatches — the same safe
// re-entry point those emits use.
- (void)flushQueuedFirstCanvasFrameRequestNow {
    if (!self.retainedFrameRequestPending || self.hasCanvasTexture) return;
    [self emitFirstCanvasFrameRequest];
}

// Advance the pacing clock for an emission that was SCHEDULED at
// lastEmit + interval: stamping fire-time `now` (the old behavior)
// folded the dispatch timer's delivery latency into every period, so
// the paced loop ran at 8.33 ms + ~1.2 ms == ~105 Hz on a 120 Hz panel.
// Stamping the scheduled deadline keeps the average period exactly one
// display interval (jitter stays, drift doesn't). A fire more than one
// interval late used to reset the clock to `now`, which re-based every
// following period on completion time — under sustained main-thread
// load each armed interval then carried the full work time on top of
// the display interval, the measured frame-over-frame stretch. Advance
// to the last GRID point at or before `now` instead: whole missed
// intervals are skipped (never queued as a catch-up burst), and the
// next emission lands back on cadence.
- (void)advanceRetainedFramePacingClock {
    const uint64_t now = NativeSdkTimestampNanoseconds();
    const uint64_t frameIntervalNs = NativeSdkRetainedFrameIntervalNanoseconds(self.window.screen ?: NSScreen.mainScreen);
    if (self.retainedFrameLastEmitNs == 0) {
        self.retainedFrameLastEmitNs = now;
        return;
    }
    const uint64_t scheduledNs = self.retainedFrameLastEmitNs + frameIntervalNs;
    if (now < scheduledNs) {
        // Fired before the deadline (clock skew); re-basing at `now`
        // keeps the next delay a full interval instead of stretching it.
        self.retainedFrameLastEmitNs = now;
    } else {
        self.retainedFrameLastEmitNs = scheduledNs + ((now - scheduledNs) / frameIntervalNs) * frameIntervalNs;
    }
}

- (void)emitFirstCanvasFrameRequest {
    // Both the queued async fallback and the synchronous pre-run flush
    // route here; whichever runs first clears the pending flag and the
    // other no-ops.
    if (!self.retainedFrameRequestPending) return;
    self.retainedFrameRequestPending = NO;
    if (self.hasCanvasTexture) {
        // A texture landed while the request was queued: the paced
        // scheduler (with its own guards) owns it now.
        [self scheduleFrameEventEmission];
        return;
    }
    if (![self isAvailable] || self.hidden || self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;
    [self updateDrawableSize];
    self.retainedFrameLastEmitNs = NativeSdkTimestampNanoseconds();
    const NSUInteger requestedFrameIndex = self.frameIndex;
    self.frameIndex += 1;
    // Pre-first-present: the occluded short-circuit (and therefore the
    // occluded pacing) is not yet in force, so this completion is never
    // an occluded logical one.
    [self emitFrameEventWithFrameIndex:requestedFrameIndex sampleColor:0 nonblank:NO occluded:NO];
}

/* Frame completions run on the occluded heartbeat when the window
 * exists but is not being composited AND the first present has landed —
 * the same two facts that gate renderFrame's occluded short-circuit, so
 * every emission this paces is one that could not have flipped glass. A
 * view not yet in a window, or one still owed its first present, keeps
 * full cadence. */
- (BOOL)occludedFramePacingActive {
    NSWindow *window = self.window;
    return window != nil && (window.occlusionState & NSWindowOcclusionStateVisible) == 0 && self.hasEverPresented;
}

/* Schedule the surface's next frame event on the display-interval grid.
 * At most one emission is ever in flight; producers arriving while it
 * is queued fold into it (see the property comment). Always fires
 * through the queue — a request lands mid engine dispatch and a
 * synchronous emission would re-enter the engine — and the pacing
 * clock's grid stamping keeps the queue hop out of the period. */
- (void)scheduleFrameEventEmission {
    [self scheduleFrameEventEmissionForPresentCompletion:NO];
}

/* presentCompletion distinguishes the one producer whose facts must not
 * wait out a heartbeat: a REAL present's GPU completion (first-present
 * exemption, or a visible window). Its verdicts (nonblank, the sample
 * color automation reads) are new discrete facts, and while occluded
 * only the exempt FIRST present ever completes — promptly emitting it
 * cannot reopen the sustained spin, because every following cycle short-
 * circuits without presenting. A present completion also SUPERSEDES an
 * already-parked heartbeat emission (generation bump, same discipline as
 * de-occlusion) so a request that armed first cannot hold the verdict
 * hostage for a second. */
- (void)scheduleFrameEventEmissionForPresentCompletion:(BOOL)presentCompletion {
    if (![self isAvailable] || self.hidden || self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;
    if (self.frameEventEmissionScheduled) {
        if (!presentCompletion) return;
        self.frameEventEmissionGeneration += 1;
        self.frameEventEmissionScheduled = NO;
    }
    self.frameEventEmissionScheduled = YES;
    // Armed: suspend app-nap timer coalescing until the channel goes
    // quiet, so the paced deadlines below fire on time even for an
    // unfocused or occluded window (see the property comment) — the
    // occluded heartbeat relies on this as much as the display grid
    // does; an app-napped heartbeat would stretch arbitrarily.
    if (!self.frameChannelActivity) {
        self.frameChannelActivity = [[NSProcessInfo processInfo] beginActivityWithOptions:(NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical) reason:@"armed gpu-surface frame channel"];
    }
    const uint64_t now = NativeSdkTimestampNanoseconds();
    const uint64_t frameIntervalNs = NativeSdkRetainedFrameIntervalNanoseconds(self.window.screen ?: NSScreen.mainScreen);
    // Occluded surfaces pace on the heartbeat, not the display grid:
    // nothing this emission drives can reach the glass, so full cadence
    // is pure display-list churn (see NativeSdkOccludedFrameHeartbeatNs).
    // Exempt: a real present's completion and an input's responding
    // frame (see the callers' comments) — neither can sustain a spin.
    // De-occlusion supersedes a parked heartbeat emission immediately
    // (windowOcclusionStateChanged), so the long delay never gates the
    // return to full cadence.
    const BOOL heartbeatPaced = !presentCompletion && !self.inputDrivenFramePending && [self occludedFramePacingActive];
    const uint64_t paceNs = heartbeatPaced ? NativeSdkOccludedFrameHeartbeatNs : frameIntervalNs;
    uint64_t delayNs = 0;
    if (self.retainedFrameLastEmitNs > 0 && now < self.retainedFrameLastEmitNs + paceNs) {
        delayNs = self.retainedFrameLastEmitNs + paceNs - now;
    }
    const NSUInteger generation = self.frameEventEmissionGeneration;
    __weak NativeSdkMetalSurfaceView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayNs), dispatch_get_main_queue(), ^{
        NativeSdkMetalSurfaceView *strongSelf = weakSelf;
        if (!strongSelf) return;
        // Superseded (de-occlusion rescheduled a fresher emission while
        // this block sat in the queue): the replacement owns the flag
        // and the activity — touch nothing.
        if (strongSelf.frameEventEmissionGeneration != generation) return;
        strongSelf.frameEventEmissionScheduled = NO;
        [strongSelf emitScheduledFrameEvent];
        // The emission's engine dispatch re-arms the channel when more
        // frames are wanted; if it did not, the animation is over —
        // release the activity so the idle app naps again.
        if (!strongSelf.frameEventEmissionScheduled && strongSelf.frameChannelActivity) {
            [[NSProcessInfo processInfo] endActivity:strongSelf.frameChannelActivity];
            strongSelf.frameChannelActivity = nil;
        }
    });
}

/* The single frame-event emission: retained canvas state is the
 * payload (the completion handlers already folded their sample color
 * and nonblank verdicts into view state before scheduling), so one
 * event serves frame requests and present completions alike. */
- (void)emitScheduledFrameEvent {
    if (![self isAvailable] || self.hidden || self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;
    // The input's responding frame is THIS one; the follow-up schedule
    // (an armed animation re-requesting) returns to the occluded
    // heartbeat unless another input lands.
    self.inputDrivenFramePending = NO;
    [self updateDrawableSize];
    [self advanceRetainedFramePacingClock];
    const NSUInteger requestedFrameIndex = self.frameIndex;
    self.frameIndex += 1;
    const BOOL nonblank = self.verifiedNonblankFrame || self.hasCanvasTexture;
    const uint32_t sampleColor = self.verifiedNonblankFrame ? self.lastSampleColor : 0;
    [self emitFrameEventWithFrameIndex:requestedFrameIndex sampleColor:sampleColor nonblank:nonblank occluded:[self occludedFramePacingActive]];
}

- (void)renderFrame {
    if (![self isAvailable] || self.hidden || self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;
    [self updateDrawableSize];

    /* Occluded (or minimized, or hidden-app) windows never touch the
     * drawable pool: complete the frame logically from retained state
     * instead. The layer's nextDrawable runs with its timeout DISALLOWED
     * (see the layer setup), so it BLOCKS until the window server hands a
     * drawable back — and for a window whose compositing is parked that
     * hand-back is not on the display grid but on the server's own lazy
     * schedule, which turns each armed animation step into a main-thread
     * stall of unbounded length (an armed 180 ms tween then crawls over
     * seconds, stepping only when the parked present queue is serviced).
     * Whether an occluded layer vends drawables promptly, slowly, or
     * returns nil varies by OS release and pool pressure, so don't gamble
     * on it: the occlusion bit is the honest signal. The deliberate
     * occluded cadence is the ~1 Hz heartbeat (scheduleFrameEventEmission
     * picks it via occludedFramePacingActive; the rationale lives at
     * NativeSdkOccludedFrameHeartbeatNs): frame-channel consumers stay
     * roughly current instead of stepping at full display rate for glass
     * nobody can see, and the occlusion observer restores full cadence
     * and flushes the retained canvas the moment the window is composited
     * again. A view not yet in a window keeps the present path: there is
     * no occlusion truth to read before the window exists. */
    NSWindow *window = self.window;
    const BOOL occluded = window != nil && (window.occlusionState & NSWindowOcclusionStateVisible) == 0;
    // The FIRST present is exempt from the occluded short-circuit: it is
    // what establishes the surface's glass and proves the frame nonblank
    // (the correctness verdict automation reads), and a window can launch
    // fully covered — or behind a locked session — where the bit never
    // clears. One bounded present to invisible glass is the honest price;
    // the sustained-stream skip applies from the second frame on.
    if (occluded && self.hasEverPresented) {
        if (NativeSdkGpuFrameTraceEnabled()) {
            fprintf(stderr, "native-sdk: gpu frame-trace path=occluded frame=%lu\n", (unsigned long)self.frameIndex);
        }
        self.glassFlushPending = YES;
        [self scheduleFrameEventEmission];
        return;
    }

    const uint64_t vendBeginNs = NativeSdkGpuFrameTraceEnabled() ? NativeSdkTimestampNanoseconds() : 0;
    id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
    if (NativeSdkGpuFrameTraceEnabled()) {
        fprintf(stderr, "native-sdk: gpu frame-trace path=%s frame=%lu vend_us=%llu\n",
                drawable ? "present" : "nil-drawable",
                (unsigned long)self.frameIndex,
                (unsigned long long)((NativeSdkTimestampNanoseconds() - vendBeginNs) / 1000));
    }
    if (!drawable) {
        // The layer can decline a drawable even for a visible window
        // (mid-resize size flux, transient pool pressure, a window whose
        // compositing stopped before the occlusion bit flipped). Dropping
        // the frame here silently is not an option: the present-completion
        // event drives the runtime's frame loop (input latency recording,
        // canvas animations, automation snapshot refresh), so the window
        // would go dead — frames requested by the runtime never completed.
        // The content is already retained (canvasTexture holds the latest
        // canvas pixels), so complete the frame logically instead, exactly
        // like the occluded short-circuit above: advance the frame index
        // and emit the completion event from retained state, paced at the
        // display's refresh interval (a successful present is vsync-paced
        // by drawable availability; without pacing an animation loop here
        // would spin unthrottled). The retained content flushes to the
        // glass when the window is next composited (occlusion observer
        // below). Policy: a frame requested by the runtime always
        // completes regardless of window visibility; only the physical
        // glass flush is deferred to visibility.
        self.glassFlushPending = YES;
        [self scheduleFrameEventEmission];
        return;
    }
    const double phase = (double)(self.frameIndex % 360) / 360.0;
    const double red = self.hasCanvasTexture ? 0.965 : 0.10 + 0.08 * sin(phase * 6.283185307179586);
    const double green = self.hasCanvasTexture ? 0.973 : 0.18 + 0.10 * sin((phase + 0.33) * 6.283185307179586);
    const double blue = self.hasCanvasTexture ? 0.988 : 0.34 + 0.16 * sin((phase + 0.66) * 6.283185307179586);

    MTLRenderPassDescriptor *descriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    descriptor.colorAttachments[0].texture = drawable.texture;
    descriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    descriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    descriptor.colorAttachments[0].clearColor = MTLClearColorMake(red, green, blue, 1.0);

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (!commandBuffer) return;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:descriptor];
    const BOOL canvasTextureMatchesDrawable = self.canvasTextureWidth == drawable.texture.width &&
        self.canvasTextureHeight == drawable.texture.height;
    if (self.hasCanvasTexture && canvasTextureMatchesDrawable && self.canvasTexture && self.canvasRenderPipeline && self.canvasSampler) {
        [encoder setRenderPipelineState:self.canvasRenderPipeline];
        [encoder setFragmentTexture:self.canvasTexture atIndex:0];
        [encoder setFragmentSamplerState:self.canvasSampler atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    [encoder endEncoding];

    const BOOL shouldSample = !self.verifiedNonblankFrame;
    if (shouldSample && !self.sampleBuffer) {
        self.sampleBuffer = [self.device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    }
    id<MTLBuffer> sampleBuffer = shouldSample ? self.sampleBuffer : nil;
    if (sampleBuffer) {
        NSUInteger sampleX = drawable.texture.width > 1 ? drawable.texture.width / 2 : 0;
        NSUInteger sampleY = drawable.texture.height > 1 ? drawable.texture.height / 2 : 0;
        id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
        [blit copyFromTexture:drawable.texture
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(sampleX, sampleY, 0)
                   sourceSize:MTLSizeMake(1, 1, 1)
                     toBuffer:sampleBuffer
            destinationOffset:0
       destinationBytesPerRow:256
     destinationBytesPerImage:256];
        [blit endEncoding];
    }

    __weak NativeSdkMetalSurfaceView *weakSelf = self;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completedBuffer) {
        (void)completedBuffer;
        uint32_t sampleColor = 0;
        BOOL nonblank = NO;
        if (sampleBuffer && completedBuffer.status == MTLCommandBufferStatusCompleted) {
            const uint8_t *bytes = (const uint8_t *)sampleBuffer.contents;
            sampleColor = ((uint32_t)bytes[3] << 24) | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[1] << 8) | (uint32_t)bytes[0];
            nonblank = bytes[0] != 0 || bytes[1] != 0 || bytes[2] != 0;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NativeSdkMetalSurfaceView *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (nonblank) {
                strongSelf.verifiedNonblankFrame = YES;
                strongSelf.lastSampleColor = sampleColor;
            }
            strongSelf.renderedFrame = YES;
            /* Fold the completion into the surface's ONE frame-event
             * scheduler. The completion handler fires when the GPU
             * finishes rendering — microseconds of work, well before the
             * glass flip — so an unpaced emission spins the engine's
             * frame loop as fast as the drawable pool recycles (measured
             * ~240 Hz): every cycle re-plans, re-draws, and then stalls
             * in nextDrawable waiting for the pool, which is exactly
             * where the present stage's milliseconds went. The shared
             * scheduler paces the emission to the display interval AND
             * coalesces it with any pending frame request, so an armed
             * animation loop sees one event per interval, not one per
             * producer. The verdict above is already view state, so the
             * scheduled event carries this completion's truth. A real
             * present's completion never waits out the occluded
             * heartbeat (see the method's comment). */
            [strongSelf scheduleFrameEventEmissionForPresentCompletion:YES];
        });
    }];

    self.glassFlushPending = NO;
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    self.hasEverPresented = YES;

    self.frameIndex += 1;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:self.surfaceCursor ?: [NSCursor arrowCursor]];
}

- (void)setSurfaceCursor:(NSCursor *)cursor {
    _surfaceCursor = cursor ?: [NSCursor arrowCursor];
    [self.window invalidateCursorRectsForView:self];
    [_surfaceCursor set];
}

- (void)mouseDown:(NSEvent *)event {
    [self emitQueuedPointerMotionInputEvent];
    [self.window makeFirstResponder:self];
    if ((event.modifierFlags & NSEventModifierFlagControl) != 0) {
        // macOS convention: ctrl-click is a context click. Report it as
        // the secondary button so the runtime presents the context menu.
        self.controlClickActive = YES;
        [self emitInputEventWithKind:NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_DOWN event:event button:1 deltaX:0 deltaY:0];
        return;
    }
    [self emitInputEventWithKind:NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_DOWN event:event button:0 deltaX:0 deltaY:0];
}

- (void)mouseUp:(NSEvent *)event {
    [self emitQueuedPointerMotionInputEvent];
    if (self.controlClickActive) {
        self.controlClickActive = NO;
        [self emitInputEventWithKind:NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_UP event:event button:1 deltaX:0 deltaY:0];
        return;
    }
    [self emitInputEventWithKind:NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_UP event:event button:0 deltaX:0 deltaY:0];
}

- (void)mouseMoved:(NSEvent *)event {
    [self queuePointerMotionInputEvent:event kind:NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_MOVE button:0];
}

- (void)mouseExited:(NSEvent *)event {
    [self emitQueuedPointerMotionInputEvent];
    [self emitInputEventWithKind:NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_CANCEL event:event button:0 deltaX:0 deltaY:0];
}

- (void)mouseDragged:(NSEvent *)event {
    [self queuePointerMotionInputEvent:event kind:NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_DRAG button:0];
}

- (void)rightMouseDown:(NSEvent *)event {
    [self emitQueuedPointerMotionInputEvent];
    [self.window makeFirstResponder:self];
    [self emitInputEventWithKind:NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_DOWN event:event button:1 deltaX:0 deltaY:0];
}

- (void)rightMouseUp:(NSEvent *)event {
    [self emitQueuedPointerMotionInputEvent];
    [self emitInputEventWithKind:NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_UP event:event button:1 deltaX:0 deltaY:0];
}

- (void)rightMouseDragged:(NSEvent *)event {
    [self queuePointerMotionInputEvent:event kind:NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_DRAG button:1];
}

- (void)otherMouseDown:(NSEvent *)event {
    [self emitQueuedPointerMotionInputEvent];
    [self.window makeFirstResponder:self];
    [self emitInputEventWithKind:NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_DOWN event:event button:(NSInteger)event.buttonNumber deltaX:0 deltaY:0];
}

- (void)otherMouseUp:(NSEvent *)event {
    [self emitQueuedPointerMotionInputEvent];
    [self emitInputEventWithKind:NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_UP event:event button:(NSInteger)event.buttonNumber deltaX:0 deltaY:0];
}

- (void)otherMouseDragged:(NSEvent *)event {
    [self queuePointerMotionInputEvent:event kind:NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_DRAG button:(NSInteger)event.buttonNumber];
}

- (void)scrollWheel:(NSEvent *)event {
    NativeSdkScrollDriverView *driver = [self scrollDriverForWheelEvent:event];
    if (driver) {
        // The OS scroller owns input + physics for this region (momentum,
        // rubber-band, overlay scroller); the resulting contentOffset
        // flows back through the clip-view bounds-change notification.
        [driver scrollWheel:event];
        return;
    }
    [self queueScrollInputEvent:event deltaX:-event.scrollingDeltaX deltaY:-event.scrollingDeltaY];
}

- (void)keyDown:(NSEvent *)event {
    if ([self focusedTextAccessibilityElement]) {
        self.interpretedKeyEventEmittedInput = NO;
        [self interpretKeyEvents:@[event]];
        if (!self.interpretedKeyEventEmittedInput) {
            [self emitInputEventWithKind:NATIVE_SDK_APPKIT_GPU_INPUT_KEY_DOWN event:event button:0 deltaX:0 deltaY:0];
        }
        self.interpretedKeyEventEmittedInput = NO;
        return;
    }
    [self emitInputEventWithKind:NATIVE_SDK_APPKIT_GPU_INPUT_KEY_DOWN event:event button:0 deltaX:0 deltaY:0];
    [self interpretKeyEvents:@[event]];
}

- (void)keyUp:(NSEvent *)event {
    [self emitInputEventWithKind:NATIVE_SDK_APPKIT_GPU_INPUT_KEY_UP event:event button:0 deltaX:0 deltaY:0];
}

- (void)emitFrameEventWithFrameIndex:(NSUInteger)frameIndex sampleColor:(uint32_t)sampleColor nonblank:(BOOL)nonblank occluded:(BOOL)occluded {
    if (!self.host || self.surfaceLabel.length == 0) return;
    const char *labelBytes = self.surfaceLabel.UTF8String ?: "";
    /* Capture-and-clear BEFORE the emit: the engine presents the next
     * packet synchronously INSIDE this event dispatch, so a post-emit
     * reset would clobber the stamps that present just recorded. One
     * report per packet present; completion-only frames carry zeros. */
    const uint64_t packetDecodeNs = self.lastPacketDecodeNs;
    const uint64_t packetDrawNs = self.lastPacketDrawNs;
    self.lastPacketDecodeNs = 0;
    self.lastPacketDrawNs = 0;
    [self.host emitEvent:(native_sdk_appkit_event_t){
        .kind = NATIVE_SDK_APPKIT_EVENT_GPU_SURFACE_FRAME,
        .window_id = self.windowId,
        .width = self.bounds.size.width,
        .height = self.bounds.size.height,
        .scale = self.lastScale > 0 ? self.lastScale : 1,
        .view_label = labelBytes,
        .view_label_len = [self.surfaceLabel lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        .frame_index = frameIndex,
        .timestamp_ns = NativeSdkTimestampNanoseconds(),
        .frame_interval_ns = NativeSdkRetainedFrameIntervalNanoseconds(self.window.screen ?: NSScreen.mainScreen),
        .nonblank = nonblank ? 1 : 0,
        .sample_color = sampleColor,
        .packet_decode_ns = packetDecodeNs,
        .packet_draw_ns = packetDrawNs,
        .occluded = occluded ? 1 : 0,
    }];
    [self.host scheduleFrame];
}

- (void)emitResizeEvent {
    if (!self.host || self.surfaceLabel.length == 0) return;
    CGFloat y = self.superview ? (self.superview.bounds.size.height - NSMaxY(self.frame)) : self.frame.origin.y;
    const char *labelBytes = self.surfaceLabel.UTF8String ?: "";
    [self.host emitEvent:(native_sdk_appkit_event_t){
        .kind = NATIVE_SDK_APPKIT_EVENT_GPU_SURFACE_RESIZE,
        .window_id = self.windowId,
        .x = self.frame.origin.x,
        .y = y,
        .width = self.bounds.size.width,
        .height = self.bounds.size.height,
        .scale = self.lastScale > 0 ? self.lastScale : 1,
        .view_label = labelBytes,
        .view_label_len = [self.surfaceLabel lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
    }];
}

- (void)emitInputEventWithKind:(NSInteger)kind event:(NSEvent *)event button:(NSInteger)button deltaX:(double)deltaX deltaY:(double)deltaY {
    if (!self.host || self.surfaceLabel.length == 0) return;
    NSPoint point = event ? [self convertPoint:event.locationInWindow fromView:nil] : NSMakePoint(0, 0);
    BOOL keyEvent = kind == NATIVE_SDK_APPKIT_GPU_INPUT_KEY_DOWN || kind == NATIVE_SDK_APPKIT_GPU_INPUT_KEY_UP;
    NSString *keyText = keyEvent && event ? NativeSdkShortcutKeyForEvent(event) : @"";
    [self emitInputEventWithKind:kind
                           point:point
                     timestampNs:NativeSdkTimestampNanoseconds()
                       modifiers:event ? NativeSdkModifierFlagsForEvent(event) : 0
                         keyText:keyText
                       inputText:@""
                          button:button
                          deltaX:deltaX
                          deltaY:deltaY];
}

- (void)queuePointerMotionInputEvent:(NSEvent *)event kind:(NSInteger)kind button:(NSInteger)button {
    if (!self.host || self.surfaceLabel.length == 0 || !event) return;
    self.pendingPointerMotionKind = kind;
    self.pendingPointerMotionPoint = [self convertPoint:event.locationInWindow fromView:nil];
    self.pendingPointerMotionButton = button;
    self.pendingPointerMotionModifiers = NativeSdkModifierFlagsForEvent(event);
    self.pendingPointerMotionTimestampNs = NativeSdkTimestampNanoseconds();
    if (self.pointerMotionInputPending) return;
    self.pointerMotionInputPending = YES;

    const uint64_t now = self.pendingPointerMotionTimestampNs;
    const uint64_t frameIntervalNs = NativeSdkRetainedFrameIntervalNanoseconds(self.window.screen ?: NSScreen.mainScreen);
    uint64_t delayNs = 0;
    if (self.pointerMotionInputLastEmitNs > 0 && now < self.pointerMotionInputLastEmitNs + frameIntervalNs) {
        delayNs = self.pointerMotionInputLastEmitNs + frameIntervalNs - now;
    }
    __weak NativeSdkMetalSurfaceView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayNs), dispatch_get_main_queue(), ^{
        NativeSdkMetalSurfaceView *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf emitQueuedPointerMotionInputEvent];
    });
}

- (void)emitQueuedPointerMotionInputEvent {
    if (!self.pointerMotionInputPending) return;
    const NSInteger kind = self.pendingPointerMotionKind;
    const NSPoint point = self.pendingPointerMotionPoint;
    const NSInteger button = self.pendingPointerMotionButton;
    const uint32_t modifiers = self.pendingPointerMotionModifiers;
    const uint64_t timestampNs = self.pendingPointerMotionTimestampNs > 0 ? self.pendingPointerMotionTimestampNs : NativeSdkTimestampNanoseconds();
    self.pointerMotionInputPending = NO;
    self.pendingPointerMotionKind = 0;
    self.pendingPointerMotionButton = 0;
    self.pendingPointerMotionModifiers = 0;
    self.pendingPointerMotionTimestampNs = 0;
    self.pointerMotionInputLastEmitNs = NativeSdkTimestampNanoseconds();
    [self emitInputEventWithKind:kind
                           point:point
                     timestampNs:timestampNs
                       modifiers:modifiers
                         keyText:@""
                       inputText:@""
                          button:button
                          deltaX:0
                          deltaY:0];
}

- (void)queueScrollInputEvent:(NSEvent *)event deltaX:(double)deltaX deltaY:(double)deltaY {
    if (!self.host || self.surfaceLabel.length == 0 || !event) return;
    if (deltaX == 0 && deltaY == 0) return;
    self.pendingScrollPoint = [self convertPoint:event.locationInWindow fromView:nil];
    self.pendingScrollDeltaX += deltaX;
    self.pendingScrollDeltaY += deltaY;
    self.pendingScrollModifiers = NativeSdkModifierFlagsForEvent(event);
    self.pendingScrollTimestampNs = NativeSdkTimestampNanoseconds();
    if (self.scrollInputPending) return;
    self.scrollInputPending = YES;

    const uint64_t now = self.pendingScrollTimestampNs;
    const uint64_t frameIntervalNs = NativeSdkRetainedFrameIntervalNanoseconds(self.window.screen ?: NSScreen.mainScreen);
    uint64_t delayNs = 0;
    if (self.scrollInputLastEmitNs > 0 && now < self.scrollInputLastEmitNs + frameIntervalNs) {
        delayNs = self.scrollInputLastEmitNs + frameIntervalNs - now;
    }
    __weak NativeSdkMetalSurfaceView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayNs), dispatch_get_main_queue(), ^{
        NativeSdkMetalSurfaceView *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf emitQueuedScrollInputEvent];
    });
}

- (void)emitQueuedScrollInputEvent {
    if (!self.scrollInputPending) return;
    const NSPoint point = self.pendingScrollPoint;
    const double deltaX = self.pendingScrollDeltaX;
    const double deltaY = self.pendingScrollDeltaY;
    const uint32_t modifiers = self.pendingScrollModifiers;
    const uint64_t timestampNs = self.pendingScrollTimestampNs > 0 ? self.pendingScrollTimestampNs : NativeSdkTimestampNanoseconds();
    self.scrollInputPending = NO;
    self.pendingScrollDeltaX = 0;
    self.pendingScrollDeltaY = 0;
    self.pendingScrollModifiers = 0;
    self.pendingScrollTimestampNs = 0;
    if (deltaX == 0 && deltaY == 0) return;
    self.scrollInputLastEmitNs = NativeSdkTimestampNanoseconds();
    [self emitInputEventWithKind:NATIVE_SDK_APPKIT_GPU_INPUT_SCROLL
                           point:point
                     timestampNs:timestampNs
                       modifiers:modifiers
                         keyText:@""
                       inputText:@""
                          button:0
                          deltaX:deltaX
                          deltaY:deltaY];
}

// --- Native scroll drivers ---------------------------------------------
// Each scrollable canvas region gets an invisible NSScrollView subview
// sized to the region and backed by a flipped document view sized to the
// content extent. Wheel events over a region forward to its driver, so
// the OS computes momentum (and rubber-band, for regions whose spec asks
// for it) and draws the overlay scroller; the clip view's bounds origin y
// IS the canvas scroll offset, reported back per frame interval through
// GPU_SURFACE_SCROLL_DRIVER events.

- (void)setScrollDrivers:(const native_sdk_appkit_scroll_driver_t *)drivers count:(NSUInteger)count {
    if (!self.scrollDrivers) self.scrollDrivers = [[NSMutableArray alloc] init];
    for (NSInteger index = (NSInteger)self.scrollDrivers.count - 1; index >= 0; index -= 1) {
        NativeSdkScrollDriverView *driver = self.scrollDrivers[(NSUInteger)index];
        BOOL present = NO;
        for (NSUInteger spec = 0; spec < count; spec += 1) {
            if (drivers[spec].driver_id == driver.driverId) {
                present = YES;
                break;
            }
        }
        if (present) continue;
        [[NSNotificationCenter defaultCenter] removeObserver:self name:NSViewBoundsDidChangeNotification object:driver.contentView];
        [driver removeFromSuperview];
        [self.scrollDrivers removeObjectAtIndex:(NSUInteger)index];
    }
    for (NSUInteger spec = 0; spec < count; spec += 1) {
        const native_sdk_appkit_scroll_driver_t desired = drivers[spec];
        NativeSdkScrollDriverView *driver = nil;
        for (NativeSdkScrollDriverView *candidate in self.scrollDrivers) {
            if (candidate.driverId == desired.driver_id) {
                driver = candidate;
                break;
            }
        }
        BOOL created = NO;
        if (!driver) {
            created = YES;
            driver = [[NativeSdkScrollDriverView alloc] initWithFrame:NSMakeRect(0, 0, MAX(desired.width, 1), MAX(desired.height, 1))];
            driver.driverId = desired.driver_id;
            driver.drawsBackground = NO;
            driver.hasVerticalScroller = YES;
            driver.hasHorizontalScroller = NO;
            driver.scrollerStyle = NSScrollerStyleOverlay;
            driver.autohidesScrollers = YES;
            driver.horizontalScrollElasticity = NSScrollElasticityNone;
            driver.automaticallyAdjustsContentInsets = NO;
            NativeSdkScrollDriverDocumentView *document = [[NativeSdkScrollDriverDocumentView alloc] initWithFrame:NSMakeRect(0, 0, MAX(desired.content_width, 1), MAX(desired.content_height, 1))];
            driver.documentView = document;
            driver.contentView.postsBoundsChangedNotifications = YES;
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(scrollDriverBoundsDidChange:) name:NSViewBoundsDidChangeNotification object:driver.contentView];
            [self addSubview:driver];
            [self.scrollDrivers addObject:driver];
        }
        // Reconcile against the live view state every push — comparing
        // against anything but the actual frame races with relayout.
        // Elasticity rides the same reconcile: a region's edge behavior
        // (pin at the edges vs bounce past them) is per-region state the
        // runtime owns.
        NSScrollElasticity elasticity = desired.rubber_band ? NSScrollElasticityAllowed : NSScrollElasticityNone;
        if (driver.verticalScrollElasticity != elasticity) driver.verticalScrollElasticity = elasticity;
        NSRect target = NSMakeRect(desired.x, self.bounds.size.height - desired.y - desired.height, desired.width, desired.height);
        if (!NSEqualRects(driver.frame, target)) driver.frame = target;
        NSSize contentSize = NSMakeSize(MAX(desired.content_width, 1), MAX(desired.content_height, 1));
        if (driver.documentView && !NSEqualSizes(driver.documentView.frame.size, contentSize)) {
            [driver.documentView setFrameSize:contentSize];
        }
        if (created || desired.set_offset) [self applyScrollDriverOffset:driver offsetY:desired.offset_y];
    }
}

- (void)applyScrollDriverOffset:(NativeSdkScrollDriverView *)driver offsetY:(double)offsetY {
    self.applyingScrollDriverOffset = YES;
    [driver.contentView setBoundsOrigin:NSMakePoint(0, offsetY)];
    [driver reflectScrolledClipView:driver.contentView];
    self.applyingScrollDriverOffset = NO;
}

- (NativeSdkScrollDriverView *)scrollDriverForPoint:(NSPoint)viewPoint {
    // Driver specs arrive in layout pre-order, so the LAST hit is the
    // deepest scroll region under the pointer.
    NativeSdkScrollDriverView *result = nil;
    for (NativeSdkScrollDriverView *driver in self.scrollDrivers) {
        if (NSPointInRect(viewPoint, driver.frame)) result = driver;
    }
    return result;
}

- (NativeSdkScrollDriverView *)scrollDriverForWheelEvent:(NSEvent *)event {
    if (self.scrollDrivers.count == 0) return nil;
    const BOOL legacy = event.phase == NSEventPhaseNone && event.momentumPhase == NSEventPhaseNone;
    if (legacy) {
        return [self scrollDriverForPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    }
    if (event.phase == NSEventPhaseBegan || event.phase == NSEventPhaseMayBegin) {
        // Lock the gesture to the region under the pointer so momentum
        // keeps scrolling it after the pointer wanders.
        self.activeWheelDriver = [self scrollDriverForPoint:[self convertPoint:event.locationInWindow fromView:nil]];
    }
    NativeSdkScrollDriverView *driver = self.activeWheelDriver;
    if (event.momentumPhase == NSEventPhaseEnded || event.momentumPhase == NSEventPhaseCancelled) {
        self.activeWheelDriver = nil;
    }
    return driver;
}

- (void)scrollDriverBoundsDidChange:(NSNotification *)note {
    if (self.applyingScrollDriverOffset) return;
    NSClipView *clipView = note.object;
    for (NativeSdkScrollDriverView *driver in self.scrollDrivers) {
        if (driver.contentView != clipView) continue;
        [self queueScrollDriverEventWithId:driver.driverId offsetY:clipView.bounds.origin.y];
        return;
    }
}

- (void)queueScrollDriverEventWithId:(uint64_t)driverId offsetY:(double)offsetY {
    if (!self.host || self.surfaceLabel.length == 0) return;
    if (self.scrollDriverEventPending && self.pendingScrollDriverId != driverId) {
        [self emitQueuedScrollDriverEvent];
    }
    self.pendingScrollDriverId = driverId;
    self.pendingScrollDriverOffsetY = offsetY;
    if (self.scrollDriverEventPending) return;
    self.scrollDriverEventPending = YES;

    const uint64_t now = NativeSdkTimestampNanoseconds();
    const uint64_t frameIntervalNs = NativeSdkRetainedFrameIntervalNanoseconds(self.window.screen ?: NSScreen.mainScreen);
    uint64_t delayNs = 0;
    if (self.scrollDriverEventLastEmitNs > 0 && now < self.scrollDriverEventLastEmitNs + frameIntervalNs) {
        delayNs = self.scrollDriverEventLastEmitNs + frameIntervalNs - now;
    }
    __weak NativeSdkMetalSurfaceView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayNs), dispatch_get_main_queue(), ^{
        NativeSdkMetalSurfaceView *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf emitQueuedScrollDriverEvent];
    });
}

- (void)emitQueuedScrollDriverEvent {
    if (!self.scrollDriverEventPending) return;
    const uint64_t driverId = self.pendingScrollDriverId;
    const double offsetY = self.pendingScrollDriverOffsetY;
    self.scrollDriverEventPending = NO;
    if (!self.host || self.surfaceLabel.length == 0) return;
    self.scrollDriverEventLastEmitNs = NativeSdkTimestampNanoseconds();
    const char *labelBytes = self.surfaceLabel.UTF8String ?: "";
    [self.host emitEvent:(native_sdk_appkit_event_t){
        .kind = NATIVE_SDK_APPKIT_EVENT_GPU_SURFACE_SCROLL_DRIVER,
        .window_id = self.windowId,
        .view_label = labelBytes,
        .view_label_len = [self.surfaceLabel lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        .timestamp_ns = NativeSdkTimestampNanoseconds(),
        .widget_id = driverId,
        .scroll_driver_offset_y = offsetY,
    }];
}

- (void)emitInputEventWithKind:(NSInteger)kind point:(NSPoint)point timestampNs:(uint64_t)timestampNs modifiers:(uint32_t)modifiers keyText:(NSString *)keyText inputText:(NSString *)inputText button:(NSInteger)button deltaX:(double)deltaX deltaY:(double)deltaY {
    if (!self.host || self.surfaceLabel.length == 0) return;
    CGFloat y = self.bounds.size.height - point.y;
    const char *labelBytes = self.surfaceLabel.UTF8String ?: "";
    NSString *safeKeyText = keyText ?: @"";
    NSString *safeInputText = inputText ?: @"";
    const char *keyBytes = safeKeyText.UTF8String ?: "";
    const char *inputBytes = safeInputText.UTF8String ?: "";
    [self.host emitEvent:(native_sdk_appkit_event_t){
        .kind = NATIVE_SDK_APPKIT_EVENT_GPU_SURFACE_INPUT,
        .window_id = self.windowId,
        .timestamp_ns = timestampNs,
        .x = point.x,
        .y = y,
        .view_label = labelBytes,
        .view_label_len = [self.surfaceLabel lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        .key_text = keyBytes,
        .key_text_len = [safeKeyText lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        .input_text = inputBytes,
        .input_text_len = [safeInputText lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        .shortcut_modifiers = modifiers,
        .input_kind = (int)kind,
        .button = (int)button,
        .delta_x = deltaX,
        .delta_y = deltaY,
    }];
    [self requestRetainedCanvasFrame];
}

- (void)emitSyntheticKeyDownWithKey:(NSString *)key modifiers:(uint32_t)modifiers {
    if (!self.host || self.surfaceLabel.length == 0 || key.length == 0) return;
    self.interpretedKeyEventEmittedInput = YES;
    const char *labelBytes = self.surfaceLabel.UTF8String ?: "";
    const char *keyBytes = key.UTF8String ?: "";
    [self.host emitEvent:(native_sdk_appkit_event_t){
        .kind = NATIVE_SDK_APPKIT_EVENT_GPU_SURFACE_INPUT,
        .window_id = self.windowId,
        .timestamp_ns = NativeSdkTimestampNanoseconds(),
        .view_label = labelBytes,
        .view_label_len = [self.surfaceLabel lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        .key_text = keyBytes,
        .key_text_len = [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        .shortcut_modifiers = modifiers,
        .input_kind = NATIVE_SDK_APPKIT_GPU_INPUT_KEY_DOWN,
    }];
    [self requestRetainedCanvasFrame];
}

- (void)emitSelectAllTextInputCommand {
    [self emitSyntheticKeyDownWithKey:@"a" modifiers:(NativeSdkShortcutModifierPrimary | NativeSdkShortcutModifierCommand)];
}

- (void)emitTextInputEventWithKind:(NSInteger)kind text:(NSString *)text compositionCursor:(NSInteger)compositionCursor {
    if (!self.host || self.surfaceLabel.length == 0) return;
    self.interpretedKeyEventEmittedInput = YES;
    NSString *inputText = text ?: @"";
    const char *labelBytes = self.surfaceLabel.UTF8String ?: "";
    const char *inputBytes = inputText.UTF8String ?: "";
    BOOL hasCompositionCursor = compositionCursor >= 0;
    [self.host emitEvent:(native_sdk_appkit_event_t){
        .kind = NATIVE_SDK_APPKIT_EVENT_GPU_SURFACE_INPUT,
        .window_id = self.windowId,
        .timestamp_ns = NativeSdkTimestampNanoseconds(),
        .view_label = labelBytes,
        .view_label_len = [self.surfaceLabel lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        .input_text = inputBytes,
        .input_text_len = [inputText lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        .input_kind = (int)kind,
        .has_composition_cursor = hasCompositionCursor ? 1 : 0,
        .composition_cursor = hasCompositionCursor ? (size_t)compositionCursor : 0,
    }];
    [self requestRetainedCanvasFrame];
}

- (BOOL)hasMarkedText {
    return self.markedText.length > 0;
}

- (NSRange)markedRange {
    return self.markedTextRange;
}

- (NSRange)selectedRange {
    return self.selectedTextRange;
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    (void)replacementRange;
    NSString *text = NativeSdkStringFromTextInput(string);
    BOOL hadMarkedText = [self hasMarkedText];
    if (text.length == 0) {
        self.markedText = @"";
        self.markedTextRange = NSMakeRange(NSNotFound, 0);
        self.selectedTextRange = NSMakeRange(0, 0);
        if (hadMarkedText) {
            [self emitTextInputEventWithKind:NATIVE_SDK_APPKIT_GPU_INPUT_IME_CANCEL_COMPOSITION text:@"" compositionCursor:-1];
        }
        return;
    }

    NSUInteger cursor = text.length;
    if (selectedRange.location != NSNotFound) {
        cursor = MIN(text.length, selectedRange.location + selectedRange.length);
        self.selectedTextRange = NSMakeRange(MIN(selectedRange.location, text.length), MIN(selectedRange.length, text.length - MIN(selectedRange.location, text.length)));
    } else {
        self.selectedTextRange = NSMakeRange(text.length, 0);
    }
    self.markedText = text;
    self.markedTextRange = NSMakeRange(0, text.length);
    [self emitTextInputEventWithKind:NATIVE_SDK_APPKIT_GPU_INPUT_IME_SET_COMPOSITION text:text compositionCursor:(NSInteger)cursor];
}

- (void)unmarkText {
    BOOL hadMarkedText = [self hasMarkedText];
    self.markedText = @"";
    self.markedTextRange = NSMakeRange(NSNotFound, 0);
    self.selectedTextRange = NSMakeRange(0, 0);
    if (hadMarkedText) {
        [self emitTextInputEventWithKind:NATIVE_SDK_APPKIT_GPU_INPUT_IME_COMMIT_COMPOSITION text:@"" compositionCursor:-1];
    }
}

- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText {
    return @[];
}

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    if (actualRange) *actualRange = NSMakeRange(NSNotFound, 0);
    (void)range;
    return nil;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    NSAccessibilityElement *element = [self focusedTextAccessibilityElement];
    if (!element || !self.window) return 0;

    NSRect frame = element.accessibilityFrameInParentSpace;
    if (NSIsEmptyRect(frame)) return 0;

    NSPoint windowPoint = [self.window convertPointFromScreen:point];
    NSPoint localPoint = [self convertPoint:windowPoint fromView:nil];
    CGFloat inset = MIN(12.0, MAX(4.0, frame.size.width * 0.08));
    CGFloat usableWidth = MAX(1.0, frame.size.width - inset * 2.0);
    CGFloat x = MIN(MAX(localPoint.x, frame.origin.x + inset), frame.origin.x + inset + usableWidth);
    NSInteger characterCount = MAX(0, element.accessibilityNumberOfCharacters);
    if (characterCount <= 0) return 0;
    CGFloat ratio = (x - frame.origin.x - inset) / usableWidth;
    return (NSUInteger)MIN((CGFloat)characterCount, MAX(0.0, round(ratio * (CGFloat)characterCount)));
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    NSAccessibilityElement *element = [self focusedTextAccessibilityElement];
    NSRect localRect = NSZeroRect;
    if (element) {
        NSRect frame = element.accessibilityFrameInParentSpace;
        NSInteger characterCount = MAX(0, element.accessibilityNumberOfCharacters);
        NSUInteger location = range.location == NSNotFound ? 0 : MIN(range.location, (NSUInteger)characterCount);
        NSUInteger length = range.location == NSNotFound ? 0 : MIN(range.length, (NSUInteger)characterCount - location);
        if (actualRange) *actualRange = NSMakeRange(location, length);

        CGFloat inset = MIN(12.0, MAX(4.0, frame.size.width * 0.08));
        CGFloat usableWidth = MAX(1.0, frame.size.width - inset * 2.0);
        CGFloat denominator = MAX(1.0, (CGFloat)MAX(1, characterCount));
        CGFloat startRatio = (CGFloat)location / denominator;
        CGFloat endRatio = (CGFloat)(location + MAX((NSUInteger)1, length)) / denominator;
        CGFloat x = frame.origin.x + inset + usableWidth * MIN(1.0, MAX(0.0, startRatio));
        CGFloat width = MAX(1.0, usableWidth * (MIN(1.0, MAX(0.0, endRatio)) - MIN(1.0, MAX(0.0, startRatio))));
        localRect = NSMakeRect(x, frame.origin.y, width, MAX(1.0, frame.size.height));
    }
    if (NSIsEmptyRect(localRect)) {
        if (actualRange) *actualRange = range;
        localRect = NSMakeRect(0, 0, 1, MAX(1, self.bounds.size.height));
    }
    NSRect windowRect = [self convertRect:localRect toView:nil];
    return self.window ? [self.window convertRectToScreen:windowRect] : windowRect;
}

- (NSAccessibilityElement *)focusedTextAccessibilityElement {
    for (NSAccessibilityElement *element in self.widgetAccessibilityElements ?: @[]) {
        if (!element.accessibilityFocused) continue;
        if ([element.accessibilityRole isEqualToString:NSAccessibilityTextFieldRole]) return element;
    }
    return nil;
}

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    (void)replacementRange;
    NSString *text = NativeSdkStringFromTextInput(string);
    if (text.length == 0) return;

    BOOL hadMarkedText = [self hasMarkedText];
    NSString *markedText = self.markedText ?: @"";
    self.markedText = @"";
    self.markedTextRange = NSMakeRange(NSNotFound, 0);
    self.selectedTextRange = NSMakeRange(text.length, 0);

    if (hadMarkedText && [markedText isEqualToString:text]) {
        [self emitTextInputEventWithKind:NATIVE_SDK_APPKIT_GPU_INPUT_IME_COMMIT_COMPOSITION text:@"" compositionCursor:-1];
        return;
    }
    if (hadMarkedText) {
        [self emitTextInputEventWithKind:NATIVE_SDK_APPKIT_GPU_INPUT_IME_CANCEL_COMPOSITION text:@"" compositionCursor:-1];
    }
    [self emitTextInputEventWithKind:NATIVE_SDK_APPKIT_GPU_INPUT_TEXT_INPUT text:text compositionCursor:-1];
}

- (void)selectAll:(id)sender {
    (void)sender;
    if (![self focusedTextAccessibilityElement]) return;
    [self emitSelectAllTextInputCommand];
}

// Edit-menu clipboard actions on the canvas: the runtime already
// resolves cmd+C/X/V key events against the focused editable widget or
// the view's text selection, so the menu items ride the same path as
// the shortcuts — one clipboard implementation, two entry points.
// Copy stays permissive (a selection can exist without a focused text
// field); cut/paste require a focused editable so the items gray out
// where they could not act.
- (void)copy:(id)sender {
    (void)sender;
    [self emitSyntheticKeyDownWithKey:@"c" modifiers:(NativeSdkShortcutModifierPrimary | NativeSdkShortcutModifierCommand)];
}

- (void)cut:(id)sender {
    (void)sender;
    if (![self focusedTextAccessibilityElement]) return;
    [self emitSyntheticKeyDownWithKey:@"x" modifiers:(NativeSdkShortcutModifierPrimary | NativeSdkShortcutModifierCommand)];
}

- (void)paste:(id)sender {
    (void)sender;
    if (![self focusedTextAccessibilityElement]) return;
    [self emitSyntheticKeyDownWithKey:@"v" modifiers:(NativeSdkShortcutModifierPrimary | NativeSdkShortcutModifierCommand)];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action == @selector(cut:) || menuItem.action == @selector(paste:) || menuItem.action == @selector(selectAll:)) {
        return [self focusedTextAccessibilityElement] != nil;
    }
    return YES;
}

- (void)doCommandBySelector:(SEL)selector {
    if (![self focusedTextAccessibilityElement]) return;
    if (selector == @selector(deleteBackward:)) {
        [self emitSyntheticKeyDownWithKey:@"backspace" modifiers:0];
    } else if (selector == @selector(deleteForward:)) {
        [self emitSyntheticKeyDownWithKey:@"delete" modifiers:0];
    } else if (selector == @selector(moveLeft:)) {
        [self emitSyntheticKeyDownWithKey:@"arrowleft" modifiers:0];
    } else if (selector == @selector(moveRight:)) {
        [self emitSyntheticKeyDownWithKey:@"arrowright" modifiers:0];
    } else if (selector == @selector(moveUp:)) {
        [self emitSyntheticKeyDownWithKey:@"arrowup" modifiers:0];
    } else if (selector == @selector(moveDown:)) {
        [self emitSyntheticKeyDownWithKey:@"arrowdown" modifiers:0];
    } else if (selector == @selector(moveLeftAndModifySelection:)) {
        [self emitSyntheticKeyDownWithKey:@"arrowleft" modifiers:NativeSdkShortcutModifierShift];
    } else if (selector == @selector(moveRightAndModifySelection:)) {
        [self emitSyntheticKeyDownWithKey:@"arrowright" modifiers:NativeSdkShortcutModifierShift];
    } else if (selector == @selector(moveUpAndModifySelection:)) {
        [self emitSyntheticKeyDownWithKey:@"arrowup" modifiers:NativeSdkShortcutModifierShift];
    } else if (selector == @selector(moveDownAndModifySelection:)) {
        [self emitSyntheticKeyDownWithKey:@"arrowdown" modifiers:NativeSdkShortcutModifierShift];
    } else if (selector == @selector(moveToBeginningOfLine:)) {
        [self emitSyntheticKeyDownWithKey:@"home" modifiers:0];
    } else if (selector == @selector(moveToEndOfLine:)) {
        [self emitSyntheticKeyDownWithKey:@"end" modifiers:0];
    } else if (selector == @selector(moveToBeginningOfLineAndModifySelection:)) {
        [self emitSyntheticKeyDownWithKey:@"home" modifiers:NativeSdkShortcutModifierShift];
    } else if (selector == @selector(moveToEndOfLineAndModifySelection:)) {
        [self emitSyntheticKeyDownWithKey:@"end" modifiers:NativeSdkShortcutModifierShift];
    } else if (selector == @selector(selectAll:)) {
        [self emitSelectAllTextInputCommand];
    } else if (selector == @selector(insertNewline:)) {
        [self emitSyntheticKeyDownWithKey:@"enter" modifiers:0];
    } else if (selector == @selector(insertTab:)) {
        [self emitSyntheticKeyDownWithKey:@"tab" modifiers:0];
    } else if (selector == @selector(insertBacktab:)) {
        [self emitSyntheticKeyDownWithKey:@"tab" modifiers:NativeSdkShortcutModifierShift];
    } else if (selector == @selector(cancelOperation:)) {
        [self emitSyntheticKeyDownWithKey:@"escape" modifiers:0];
    }
}

- (BOOL)emitWidgetAccessibilityActionWithId:(uint64_t)widgetId action:(NSInteger)action {
    return [self emitWidgetAccessibilityActionWithId:widgetId
                                             action:action
                                               text:@""
                                      selectedRange:NSMakeRange(0, 0)
                                   hasSelectedRange:NO];
}

- (BOOL)emitWidgetAccessibilityActionWithId:(uint64_t)widgetId action:(NSInteger)action text:(NSString *)text selectedRange:(NSRange)selectedRange hasSelectedRange:(BOOL)hasSelectedRange {
    if (!self.host || self.surfaceLabel.length == 0 || widgetId == 0) return NO;
    const char *labelBytes = self.surfaceLabel.UTF8String ?: "";
    NSString *payloadText = text ?: @"";
    const char *textBytes = payloadText.UTF8String ?: "";
    [self.host emitEvent:(native_sdk_appkit_event_t){
        .kind = NATIVE_SDK_APPKIT_EVENT_WIDGET_ACCESSIBILITY_ACTION,
        .window_id = self.windowId,
        .timestamp_ns = NativeSdkTimestampNanoseconds(),
        .view_label = labelBytes,
        .view_label_len = [self.surfaceLabel lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        .widget_id = widgetId,
        .widget_action = (int)action,
        .widget_text = textBytes,
        .widget_text_len = [payloadText lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        .has_widget_text_selection = hasSelectedRange ? 1 : 0,
        .widget_text_selection_start = hasSelectedRange ? selectedRange.location : 0,
        .widget_text_selection_end = hasSelectedRange ? NativeSdkRangeEnd(selectedRange) : 0,
    }];
    [self requestRetainedCanvasFrame];
    return YES;
}

@end

@implementation NativeSdkAssetSchemeHandler

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.rootPath = @"";
    self.entryPath = @"index.html";
    self.spaFallback = YES;
    return self;
}

- (void)configureWithRootPath:(NSString *)rootPath entryPath:(NSString *)entryPath spaFallback:(BOOL)spaFallback {
    self.rootPath = NativeSdkResolvedAssetRoot(rootPath ?: @"");
    self.entryPath = entryPath.length > 0 ? entryPath : @"index.html";
    self.spaFallback = spaFallback;
}

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
    (void)webView;
    NSString *relativePath = NativeSdkSafeAssetPath(urlSchemeTask.request.URL, self.entryPath);
    if (!relativePath) {
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL userInfo:nil];
        [urlSchemeTask didFailWithError:error];
        return;
    }

    NSString *filePath = [self.rootPath stringByAppendingPathComponent:relativePath];
    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath isDirectory:&isDirectory] || isDirectory) {
        if (self.spaFallback) {
            filePath = [self.rootPath stringByAppendingPathComponent:self.entryPath];
        }
    }

    NSData *data = [NSData dataWithContentsOfFile:filePath];
    if (!data) {
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil];
        [urlSchemeTask didFailWithError:error];
        return;
    }

    NSURLResponse *response = [[NSURLResponse alloc] initWithURL:urlSchemeTask.request.URL
                                                        MIMEType:NativeSdkMimeTypeForPath(filePath)
                                           expectedContentLength:(NSInteger)data.length
                                                textEncodingName:nil];
    [urlSchemeTask didReceiveResponse:response];
    [urlSchemeTask didReceiveData:data];
    [urlSchemeTask didFinish];
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
    (void)webView;
    (void)urlSchemeTask;
}

@end

@implementation NativeSdkShortcut
@end

@implementation NativeSdkAppKitHost

- (instancetype)initWithAppName:(NSString *)appName displayName:(NSString *)displayName version:(NSString *)version aboutDescription:(NSString *)aboutDescription hasWebContent:(BOOL)hasWebContent windowTitle:(NSString *)windowTitle bundleIdentifier:(NSString *)bundleIdentifier iconPath:(NSString *)iconPath windowLabel:(NSString *)windowLabel x:(double)x y:(double)y width:(double)width height:(double)height restoreFrame:(BOOL)restoreFrame resizable:(BOOL)resizable titlebarStyle:(int)titlebarStyle showPolicy:(int)showPolicy {
    self = [super init];
    if (!self) {
        return nil;
    }

    NativeSdkLaunchLap("host_init");
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NativeSdkLaunchLap("nsapp_ready");
    NativeSdkRegisterBundledFonts();
    NativeSdkLaunchLap("fonts_registered");
    self.appName = appName.length > 0 ? appName : @"native-sdk";
    self.displayName = displayName.length > 0 ? displayName : self.appName;
    self.appVersion = version ?: @"";
    self.aboutDescription = aboutDescription ?: @"";
    self.hasWebContent = hasWebContent;
    self.bundleIdentifier = bundleIdentifier.length > 0 ? bundleIdentifier : @"dev.native_sdk.app";
    self.iconPath = iconPath ?: @"";
    self.windowLabel = windowLabel.length > 0 ? windowLabel : @"main";
    self.windows = [[NSMutableDictionary alloc] init];
    self.webViews = [[NSMutableDictionary alloc] init];
    self.delegates = [[NSMutableDictionary alloc] init];
    self.bridgeScriptHandlers = [[NSMutableDictionary alloc] init];
    self.assetSchemeHandlers = [[NSMutableDictionary alloc] init];
    self.windowLabels = [[NSMutableDictionary alloc] init];
    self.deferredShowWindows = [[NSMutableDictionary alloc] init];
    self.windowClearColors = [[NSMutableDictionary alloc] init];
    self.childWebViews = [[NSMutableDictionary alloc] init];
    self.nativeViews = [[NSMutableDictionary alloc] init];
    self.adoptedViewSurfaces = [[NSMutableDictionary alloc] init];
    self.canvasImageStore = [[NSMutableDictionary alloc] init];
    self.nativeViewCommands = [[NSMutableDictionary alloc] init];
    self.nativeViewExplicitTextKeys = [[NSMutableSet alloc] init];
    self.bridgeEnabledChildWebViewKeys = [[NSMutableSet alloc] init];
    self.appTimers = [[NSMutableDictionary alloc] init];
    self.allowedNavigationOrigins = @[ @"zero://app", @"zero://inline" ];
    self.allowedExternalURLs = @[];
    self.externalLinkAction = 0;
    self.shortcuts = @[];
    [self configureApplication];
    NativeSdkLaunchLap("app_configured");

    [self createWindowWithId:1 title:(windowTitle.length > 0 ? windowTitle : self.appName) label:self.windowLabel x:x y:y width:width height:height restoreFrame:restoreFrame resizable:resizable titlebarStyle:titlebarStyle showPolicy:showPolicy makeMain:YES];
    self.didShutdown = NO;
    self.observesApplicationActivation = NO;

    return self;
}

- (BOOL)createWindowWithId:(uint64_t)windowId title:(NSString *)title label:(NSString *)label x:(double)x y:(double)y width:(double)width height:(double)height restoreFrame:(BOOL)restoreFrame resizable:(BOOL)resizable titlebarStyle:(int)titlebarStyle showPolicy:(int)showPolicy makeMain:(BOOL)makeMain {
    NSNumber *key = @(windowId);
    if (self.windows[key]) {
        return NO;
    }

    NSRect rect = restoreFrame ? NSMakeRect(x, y, width, height) : NSMakeRect(0, 0, width, height);
    if (restoreFrame) {
        rect = constrainFrame(rect);
    }
    NSWindowStyleMask styleMask = NSWindowStyleMaskTitled |
                                  NSWindowStyleMaskClosable |
                                  NSWindowStyleMaskMiniaturizable;
    if (resizable) {
        styleMask |= NSWindowStyleMaskResizable;
    }
    // titlebarStyle 1 = hidden_inset (the modern editor-app shape): the
    // content view extends under a transparent titlebar with the title
    // hidden; the traffic lights stay. titlebarStyle 2 = hidden_inset_tall:
    // the same shape with the unified-toolbar-height band (the Notes
    // look), where the system vertically centers the traffic lights.
    // Drag regions and inset-aware header layout are the app's concern.
    if (titlebarStyle == 1 || titlebarStyle == 2) {
        styleMask |= NSWindowStyleMaskFullSizeContentView;
    }
    // titlebarStyle 3 = chromeless (the fully-skinned-app shape): a
    // borderless window — no titlebar band, no traffic lights, square
    // hardware corners. Closable/Miniaturizable stay in the mask so the
    // real window verbs (`closeWindowWithId:`, `miniaturizeWindowWithId:`,
    // the drag channel's double-click convention) keep their OS
    // semantics; without Titled nothing is drawn. The app declares this
    // only when its chassis provides its own working window controls.
    if (titlebarStyle == 3) {
        styleMask = NSWindowStyleMaskBorderless |
                    NSWindowStyleMaskClosable |
                    NSWindowStyleMaskMiniaturizable;
        if (resizable) {
            styleMask |= NSWindowStyleMaskResizable;
        }
    }
    NSWindow *window = titlebarStyle == 3
        ? [[NativeSdkChromelessWindow alloc] initWithContentRect:rect
                                                       styleMask:styleMask
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO]
        : [[NSWindow alloc] initWithContentRect:rect
                                      styleMask:styleMask
                                        backing:NSBackingStoreBuffered
                                          defer:NO];
    // The host's `windows` dictionary owns the window's lifetime under
    // ARC. NSWindow's releasedWhenClosed defaults to YES, which sends
    // an extra ARC-invisible release on close — fatal for the
    // model-declared secondary windows that close mid-run (user close
    // or reconcile close both over-released the window and crashed the
    // next autorelease-pool drain; the main window only ever closes at
    // shutdown, which is why this stayed hidden until windows_fn).
    window.releasedWhenClosed = NO;
    [window setTitle:(title.length > 0 ? title : self.appName)];
    if (titlebarStyle == 1 || titlebarStyle == 2) {
        window.titlebarAppearsTransparent = YES;
        window.titleVisibility = NSWindowTitleHidden;
    }
    if (titlebarStyle == 2) {
        // The tall band: an empty borderless toolbar switches the
        // titlebar to the unified-toolbar height (~52pt) and the system
        // vertically centers the traffic lights in it. The toolbar is
        // pure geometry — no items, no delegate, nothing drawn — and
        // `titlebarSeparatorStyle = none` (the modern
        // `showsBaselineSeparator`) removes the hairline it would draw
        // over the app's own header.
        NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"native-sdk-tall-titlebar"];
        toolbar.allowsUserCustomization = NO;
        window.toolbar = toolbar;
        window.toolbarStyle = NSWindowToolbarStyleUnified;
        window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
    }
    if (!restoreFrame) {
        [window center];
    }
    if (makeMain) NativeSdkLaunchLap("window_chrome_ready");

    NSView *container = [[NSView alloc] initWithFrame:rect];
    container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    window.contentView = container;
    // The window's MAIN WebView is created lazily
    // (`ensureMainWebViewForWindowId:`): a canvas-first app never loads
    // it, and instantiating WKWebView spins up the whole out-of-process
    // WebKit stack (~30+ ms of launch latency plus resident helper
    // processes) for a view that would sit blank under the canvas
    // forever. File drops used to ride the eager WebView's dragging
    // destination, so the WINDOW registers now and the delegate forwards
    // drops to the same host path.
    [window registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];

    NativeSdkWindowDelegate *delegate = [[NativeSdkWindowDelegate alloc] init];
    delegate.host = self;
    delegate.windowId = windowId;
    window.delegate = delegate;
    if (titlebarStyle == 2) {
        // The chrome re-query rides the settled contentLayoutRect (see
        // the delegate's observeValueForKeyPath:), not the fullscreen
        // notification edges, which fire before the band relayouts.
        delegate.observesContentLayout = YES;
        [window addObserver:delegate forKeyPath:@"contentLayoutRect" options:0 context:NULL];
    }

    self.windows[key] = window;
    self.delegates[key] = delegate;
    self.windowLabels[key] = label.length > 0 ? label : @"main";
    // Present-before-show: a deferred window stays ordered OUT until its
    // first gpu-surface present lands (`showDeferredWindowIfPending`, at
    // the bottom of every present path) — the user never sees a blank
    // window while the first frame renders. The fallback deadline is the
    // honest safety net: a wedged first frame surfaces as a late window,
    // never as an invisible app.
    if (showPolicy == 1) {
        self.deferredShowWindows[key] = @(NativeSdkTimestampNanoseconds());
        NativeSdkLaunchLap("window_created");
        __weak NativeSdkAppKitHost *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [weakSelf showDeferredWindowIfPending:windowId reason:"fallback-deadline"];
        });
    }
    if (makeMain) {
        self.window = window;
        self.delegate = delegate;
        self.windowLabel = label.length > 0 ? label : @"main";
    } else if (showPolicy != 1) {
        [window makeKeyAndOrderFront:nil];
        [NSApp activate];
    }
    return YES;
}

// Order a deferred-show window front exactly once — from the first
// gpu-surface present (the contract), or from the fallback deadline.
// `NATIVE_SDK_WINDOW_TIMING=1` logs the create→show latency.
- (void)showDeferredWindowIfPending:(uint64_t)windowId reason:(const char *)reason {
    NSNumber *key = @(windowId);
    NSNumber *createdNs = self.deferredShowWindows[key];
    if (!createdNs) return;
    [self.deferredShowWindows removeObjectForKey:key];
    NSWindow *window = self.windows[key];
    if (!window) return;
    if (getenv("NATIVE_SDK_WINDOW_TIMING")) {
        const double elapsedMs = (double)(NativeSdkTimestampNanoseconds() - createdNs.unsignedLongLongValue) / 1e6;
        fprintf(stderr, "native-sdk: window %llu shown (%s) %.1f ms after create wall_ns=%llu\n", (unsigned long long)windowId, reason, elapsedMs, (unsigned long long)clock_gettime_nsec_np(CLOCK_REALTIME));
    }
    [window makeKeyAndOrderFront:nil];
    [NSApp activate];
    [self emitWindowFrameForWindowId:windowId open:YES];
    [self scheduleFrame];
}

// NSWindow.backgroundColor from the canvas packet's clear color, so any
// residual gap (resize slack, the titlebar band before content lands)
// shows the app's background instead of the system default. Applied on
// change only; presents carry the color on every packet.
- (void)applyWindowClearColor:(uint64_t)windowId red:(uint8_t)red green:(uint8_t)green blue:(uint8_t)blue alpha:(uint8_t)alpha {
    NSNumber *key = @(windowId);
    const uint32_t packed = ((uint32_t)red << 24) | ((uint32_t)green << 16) | ((uint32_t)blue << 8) | (uint32_t)alpha;
    NSNumber *previous = self.windowClearColors[key];
    if (previous && previous.unsignedIntValue == packed) return;
    NSWindow *window = self.windows[key];
    if (!window) return;
    self.windowClearColors[key] = @(packed);
    window.backgroundColor = [NSColor colorWithSRGBRed:red / 255.0 green:green / 255.0 blue:blue / 255.0 alpha:alpha / 255.0];
}

- (void)dealloc {
    [self invalidateAppTimers];
    [self audioStop];
    /* The vDSP plan outlives individual playbacks (created lazily
     * once); the host's end is where it retires. */
    if (self.audioSpectrumFft) {
        vDSP_destroy_fftsetup(self.audioSpectrumFft);
        self.audioSpectrumFft = NULL;
    }
    [self stopAppearanceObservers];
    if (self.shortcutEventMonitor) {
        [NSEvent removeMonitor:self.shortcutEventMonitor];
        self.shortcutEventMonitor = nil;
    }
    [self removeAllChildBridgeHandlers];
    for (WKWebView *webView in self.webViews.allValues) {
        [webView.configuration.userContentController removeScriptMessageHandlerForName:@"nativeSdkBridge"];
    }
}

- (void)focusWindowWithId:(uint64_t)windowId {
    NSWindow *window = self.windows[@(windowId)];
    if (!window) return;
    // An explicit focus overrides a pending present-before-show defer:
    // the runtime asked for the window NOW.
    [self.deferredShowWindows removeObjectForKey:@(windowId)];
    [window makeKeyAndOrderFront:nil];
    [NSApp activate];
    [self emitWindowFrameForWindowId:windowId open:YES];
    [self scheduleFrame];
}

- (void)closeWindowWithId:(uint64_t)windowId {
    NSWindow *window = self.windows[@(windowId)];
    if (!window) return;
    // performClose: simulates the titlebar close button, which a
    // chromeless (borderless) window does not have — AppKit just beeps.
    // Closing directly runs the same delegate teardown
    // (`windowWillClose`), so both paths carry identical semantics.
    if ((window.styleMask & NSWindowStyleMaskTitled) == 0) {
        [window close];
        return;
    }
    [window performClose:nil];
}

// The real OS minimize verb, for app-drawn window controls (chromeless
// windows have no traffic lights to click): the window genies into the
// Dock exactly like the yellow button. miniaturize: is used over
// performMiniaturize: for the same reason closeWindowWithId: closes
// directly — the perform variant simulates a titlebar button a
// chromeless window does not have.
- (void)miniaturizeWindowWithId:(uint64_t)windowId {
    NSWindow *window = self.windows[@(windowId)];
    if (!window) return;
    [window miniaturize:nil];
}

// The window-drag region channel. Called synchronously while the runtime
// dispatches the pointer-down that started the gesture, so
// NSApp.currentEvent IS that mouse-down NSEvent (the host forwards input
// events synchronously from the view's mouseDown:). A double-click
// applies the user's titlebar double-click preference
// (AppleActionOnDoubleClick: Maximize/zoom by default, Minimize, or
// None); a single press hands the event to performWindowDragWithEvent:,
// which moves the window only on actual movement — a plain click is a
// no-op, exactly like the native titlebar.
- (BOOL)startWindowDragWithId:(uint64_t)windowId {
    NSWindow *window = self.windows[@(windowId)];
    if (!window) return NO;
    NSEvent *event = NSApp.currentEvent;
    if (!event) return YES;
    if (event.type != NSEventTypeLeftMouseDown && event.type != NSEventTypeLeftMouseDragged) return YES;
    if (event.type == NSEventTypeLeftMouseDown && event.clickCount >= 2) {
        NSString *action = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppleActionOnDoubleClick"] ?: @"Maximize";
        if ([action isEqualToString:@"Minimize"]) {
            [window performMiniaturize:nil];
        } else if (![action isEqualToString:@"None"]) {
            [window performZoom:nil];
        }
        return YES;
    }
    [window performWindowDragWithEvent:event];
    return YES;
}

// Chrome overlay geometry for hidden-titlebar windows: how far the
// transparent titlebar (top) and the traffic lights (leading edge)
// overlay the content view, plus the traffic-light cluster's bounding
// frame in content coordinates (top-left origin) — the vertical truth a
// header needs to center against the lights in the tall unified band.
// Derived from live AppKit geometry — contentLayoutRect for the titlebar
// band and the window buttons' frames for their extent — so fullscreen
// (where the system hides both) honestly reports zero. Standard-chrome
// windows report zero: their content never extends under the titlebar.
- (BOOL)chromeInsetsForWindowId:(uint64_t)windowId top:(double *)top left:(double *)left bottom:(double *)bottom right:(double *)right buttonsX:(double *)buttonsX buttonsY:(double *)buttonsY buttonsWidth:(double *)buttonsWidth buttonsHeight:(double *)buttonsHeight {
    NSWindow *window = self.windows[@(windowId)];
    if (!window) return NO;
    *top = 0;
    *left = 0;
    *bottom = 0;
    *right = 0;
    *buttonsX = 0;
    *buttonsY = 0;
    *buttonsWidth = 0;
    *buttonsHeight = 0;
    if ((window.styleMask & NSWindowStyleMaskFullSizeContentView) == 0) return YES;
    NSView *contentView = window.contentView;
    if (!contentView) return YES;
    NSRect contentBounds = contentView.bounds;
    NSRect layoutRect = [contentView convertRect:window.contentLayoutRect fromView:nil];
    double titlebarHeight = NSMaxY(contentBounds) - NSMaxY(layoutRect);
    if (titlebarHeight <= 0.5) return YES;
    *top = titlebarHeight;
    NSButton *closeButton = [window standardWindowButton:NSWindowCloseButton];
    NSButton *miniaturizeButton = [window standardWindowButton:NSWindowMiniaturizeButton];
    NSButton *zoomButton = [window standardWindowButton:NSWindowZoomButton];
    NSButton *buttons[3] = { closeButton, miniaturizeButton, zoomButton };
    NSRect cluster = NSZeroRect;
    BOOL anyButtonVisible = NO;
    for (size_t index = 0; index < 3; index += 1) {
        NSButton *button = buttons[index];
        if (!button || button.hidden || !button.superview) continue;
        NSRect buttonFrame = [contentView convertRect:button.frame fromView:button.superview];
        cluster = anyButtonVisible ? NSUnionRect(cluster, buttonFrame) : buttonFrame;
        anyButtonVisible = YES;
    }
    if (!anyButtonVisible) return YES;
    // The cluster in content coordinates, flipped to a top-left origin
    // (the runtime's canvas convention).
    *buttonsX = NSMinX(cluster);
    *buttonsY = NSMaxY(contentBounds) - NSMaxY(cluster);
    *buttonsWidth = NSWidth(cluster);
    *buttonsHeight = NSHeight(cluster);
    if (NSMinX(cluster) < NSMidX(contentBounds)) {
        // LTR: the buttons sit at the leading (left) edge; pad by their
        // far edge plus the same margin the system leaves before them.
        *left = NSMaxX(cluster) + (NSMinX(cluster) - NSMinX(contentBounds));
    } else {
        // RTL layouts park the buttons on the right.
        *right = (NSMaxX(contentBounds) - NSMinX(cluster)) + (NSMaxX(contentBounds) - NSMaxX(cluster));
    }
    return YES;
}

// Create-on-first-use for a window's main WebView. Pure peek reads
// (event emission, bridge completion echoes, reorder passes) keep going
// through `webViewForWindowId:` and skip absent WebViews — a page that
// was never created has no listeners to miss. Paths that MATERIALIZE
// web content (load, navigate, frame/zoom/layer placement) ensure first,
// so webview-first apps behave exactly as before while canvas-first
// apps never pay for the WebKit stack.
- (WKWebView *)ensureMainWebViewForWindowId:(uint64_t)windowId {
    NSNumber *key = @(windowId);
    WKWebView *existing = self.webViews[key];
    if (existing) return existing;
    NSWindow *window = self.windows[key] ?: (windowId == 1 ? self.window : nil);
    NSView *container = window.contentView;
    if (!container) return nil;

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    NativeSdkAssetSchemeHandler *assetSchemeHandler = [[NativeSdkAssetSchemeHandler alloc] init];
    [configuration setURLSchemeHandler:assetSchemeHandler forURLScheme:@"zero"];
    WKUserContentController *userContentController = [[WKUserContentController alloc] init];
    NativeSdkBridgeScriptHandler *bridgeScriptHandler = [[NativeSdkBridgeScriptHandler alloc] init];
    bridgeScriptHandler.host = self;
    bridgeScriptHandler.windowId = windowId;
    bridgeScriptHandler.webViewLabel = @"main";
    [userContentController addScriptMessageHandler:bridgeScriptHandler name:@"nativeSdkBridge"];
    WKUserScript *bridgeScript = [[WKUserScript alloc] initWithSource:NativeSdkAppKitBridgeScript()
                                                        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                     forMainFrameOnly:YES];
    [userContentController addUserScript:bridgeScript];
    configuration.userContentController = userContentController;
    if ([configuration.preferences respondsToSelector:NSSelectorFromString(@"setDeveloperExtrasEnabled:")]) {
        [configuration.preferences setValue:@YES forKey:@"developerExtrasEnabled"];
    }
    WKWebView *webView = [[NativeSdkWebView alloc] initWithFrame:container.bounds configuration:configuration];
    ((NativeSdkWebView *)webView).host = self;
    ((NativeSdkWebView *)webView).windowId = windowId;
    [webView registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    webView.wantsLayer = YES;
    webView.layer.zPosition = 0;
    webView.layer.backgroundColor = NSColor.clearColor.CGColor;
    [webView setValue:@NO forKey:@"drawsBackground"];
    if ([webView respondsToSelector:NSSelectorFromString(@"setInspectable:")]) {
        [webView setValue:@YES forKey:@"inspectable"];
    }
    webView.navigationDelegate = self;
    webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    // Bottom of the sibling stack, where the eager create used to put it
    // (everything later was added above); the zPosition reorder pass
    // settles the final order exactly like any other webview mutation.
    [container addSubview:webView positioned:NSWindowBelow relativeTo:nil];

    self.webViews[key] = webView;
    self.bridgeScriptHandlers[key] = bridgeScriptHandler;
    self.assetSchemeHandlers[key] = assetSchemeHandler;
    if (window == self.window) {
        self.webView = webView;
        self.bridgeScriptHandler = bridgeScriptHandler;
        self.assetSchemeHandler = assetSchemeHandler;
    }
    [self reorderWebViewsInWindow:windowId];
    NativeSdkLaunchLap("main_webview_ready");
    return webView;
}

- (WKWebView *)webViewForWindowId:(uint64_t)windowId {
    return self.webViews[@(windowId)] ?: self.webView;
}

- (WKWebView *)mainWebViewForWindow:(NSWindow *)window {
    if (!window) return self.webView;
    for (NSNumber *key in self.windows) {
        if (self.windows[key] == window) return self.webViews[key] ?: self.webView;
    }
    return self.webView;
}

- (NativeSdkAssetSchemeHandler *)assetHandlerForWindowId:(uint64_t)windowId {
    return self.assetSchemeHandlers[@(windowId)] ?: self.assetSchemeHandler;
}

- (NSString *)webViewKeyForWindow:(uint64_t)windowId label:(NSString *)label {
    return [NSString stringWithFormat:@"%llu:%@", windowId, label ?: @""];
}

- (NSRect)webViewFrameForWindow:(NSWindow *)window x:(double)x y:(double)y width:(double)width height:(double)height {
    NSView *contentView = window.contentView;
    CGFloat nativeY = contentView.isFlipped ? y : contentView.bounds.size.height - y - height;
    return NSMakeRect(x, nativeY, width, height);
}

- (NSString *)nativeViewKeyForWindow:(uint64_t)windowId label:(NSString *)label {
    return [NSString stringWithFormat:@"%llu:%@", windowId, label ?: @""];
}

- (NSRect)viewFrameForContainer:(NSView *)container x:(double)x y:(double)y width:(double)width height:(double)height {
    CGFloat nativeY = container.isFlipped ? y : container.bounds.size.height - y - height;
    return NSMakeRect(x, nativeY, width, height);
}

- (NSView *)nativeParentViewForWindow:(uint64_t)windowId parent:(NSString *)parent {
    if (parent.length > 0) {
        NSView *parentView = self.nativeViews[[self nativeViewKeyForWindow:windowId label:parent]];
        return parentView;
    }
    NSWindow *window = self.windows[@(windowId)] ?: (windowId == 1 ? self.window : nil);
    return window.contentView;
}

- (NSView *)makeNativeViewWithKind:(NSInteger)kind label:(NSString *)label role:(NSString *)role text:(NSString *)text {
    NSString *displayText = text.length > 0 ? text : (role.length > 0 ? role : (label ?: @""));
    NSView *view = nil;
    switch (kind) {
        case NATIVE_SDK_APPKIT_VIEW_TOOLBAR:
        case NATIVE_SDK_APPKIT_VIEW_TITLEBAR_ACCESSORY:
        case NATIVE_SDK_APPKIT_VIEW_STATUSBAR:
        case NATIVE_SDK_APPKIT_VIEW_SIDEBAR:
        case NATIVE_SDK_APPKIT_VIEW_SPLIT:
        case NATIVE_SDK_APPKIT_VIEW_STACK:
        case NATIVE_SDK_APPKIT_VIEW_SPACER: {
            view = [[NSView alloc] initWithFrame:NSZeroRect];
            view.wantsLayer = YES;
            NSColor *color = NSColor.clearColor;
            if (kind == NATIVE_SDK_APPKIT_VIEW_TOOLBAR || kind == NATIVE_SDK_APPKIT_VIEW_STATUSBAR || kind == NATIVE_SDK_APPKIT_VIEW_TITLEBAR_ACCESSORY) {
                color = NSColor.controlBackgroundColor;
            } else if (kind == NATIVE_SDK_APPKIT_VIEW_SIDEBAR) {
                color = NSColor.windowBackgroundColor;
            }
            view.layer.backgroundColor = color.CGColor;
            break;
        }
        case NATIVE_SDK_APPKIT_VIEW_BUTTON: {
            NSButton *button = [NSButton buttonWithTitle:(displayText.length > 0 ? displayText : @"Button") target:nil action:nil];
            button.bezelStyle = NSBezelStyleRounded;
            view = button;
            break;
        }
        case NATIVE_SDK_APPKIT_VIEW_ICON_BUTTON: {
            NSButton *button = [NSButton buttonWithTitle:(displayText.length > 0 ? displayText : @"...") target:nil action:nil];
            button.bezelStyle = NSBezelStyleTexturedRounded;
            view = button;
            break;
        }
        case NATIVE_SDK_APPKIT_VIEW_LIST_ITEM: {
            NSButton *button = [NSButton buttonWithTitle:(displayText.length > 0 ? displayText : @"Item") target:nil action:nil];
            button.bezelStyle = NSBezelStyleRegularSquare;
            button.bordered = NO;
            button.alignment = NSTextAlignmentLeft;
            button.imagePosition = NSNoImage;
            view = button;
            break;
        }
        case NATIVE_SDK_APPKIT_VIEW_CHECKBOX: {
            NSButton *checkbox = [NSButton checkboxWithTitle:(displayText.length > 0 ? displayText : @"Checkbox") target:nil action:nil];
            view = checkbox;
            break;
        }
        case NATIVE_SDK_APPKIT_VIEW_TOGGLE: {
            NSButton *toggle = [NSButton buttonWithTitle:(displayText.length > 0 ? displayText : @"Toggle") target:nil action:nil];
            [toggle setButtonType:NSButtonTypePushOnPushOff];
            toggle.bezelStyle = NSBezelStyleRounded;
            view = toggle;
            break;
        }
        case NATIVE_SDK_APPKIT_VIEW_SEGMENTED_CONTROL: {
            NSSegmentedControl *segmented = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
            segmented.segmentStyle = NSSegmentStyleTexturedRounded;
            segmented.trackingMode = NSSegmentSwitchTrackingSelectOne;
            [self applySegmentedControl:segmented text:(text.length > 0 ? text : @"One|Two")];
            view = segmented;
            break;
        }
        case NATIVE_SDK_APPKIT_VIEW_PROGRESS_INDICATOR: {
            NSProgressIndicator *indicator = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
            indicator.style = NSProgressIndicatorSpinningStyle;
            indicator.indeterminate = YES;
            [indicator startAnimation:nil];
            view = indicator;
            break;
        }
        case NATIVE_SDK_APPKIT_VIEW_GPU_SURFACE: {
            NativeSdkMetalSurfaceView *surface = [[NativeSdkMetalSurfaceView alloc] initWithFrame:NSZeroRect];
            if (![surface isAvailable]) return nil;
            view = surface;
            break;
        }
        case NATIVE_SDK_APPKIT_VIEW_TEXT_FIELD: {
            NSTextField *field = [[NSTextField alloc] initWithFrame:NSZeroRect];
            field.stringValue = @"";
            field.placeholderString = displayText.length > 0 ? displayText : label ?: @"";
            field.bezelStyle = NSTextFieldRoundedBezel;
            field.drawsBackground = YES;
            field.editable = YES;
            field.selectable = YES;
            view = field;
            break;
        }
        case NATIVE_SDK_APPKIT_VIEW_SEARCH_FIELD: {
            NSSearchField *field = [[NSSearchField alloc] initWithFrame:NSZeroRect];
            field.stringValue = @"";
            field.placeholderString = displayText.length > 0 ? displayText : @"Search";
            view = field;
            break;
        }
        case NATIVE_SDK_APPKIT_VIEW_LABEL: {
            NSTextField *text = [NSTextField labelWithString:(displayText.length > 0 ? displayText : label ?: @"")];
            text.lineBreakMode = NSLineBreakByTruncatingTail;
            view = text;
            break;
        }
        default:
            return nil;
    }
    view.identifier = label;
    view.wantsLayer = YES;
    view.accessibilityRole = NativeSdkAccessibilityRoleForNativeViewKind(kind);
    return view;
}

- (void)applySegmentedControl:(NSSegmentedControl *)control text:(NSString *)text {
    NSArray<NSString *> *rawLabels = [(text.length > 0 ? text : @"One|Two") componentsSeparatedByString:@"|"];
    NSMutableArray<NSString *> *labels = [NSMutableArray arrayWithCapacity:rawLabels.count];
    for (NSString *raw in rawLabels) {
        NSString *label = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (label.length > 0) [labels addObject:label];
    }
    if (labels.count == 0) [labels addObject:@"Segment"];
    control.segmentCount = labels.count;
    for (NSInteger index = 0; index < (NSInteger)labels.count; index++) {
        [control setLabel:labels[index] forSegment:index];
    }
    if (control.selectedSegment < 0 && labels.count > 0) control.selectedSegment = 0;
}

- (void)applyNativeViewState:(NSView *)view enabled:(BOOL)enabled role:(NSString *)role accessibilityLabel:(NSString *)accessibilityLabel text:(NSString *)text {
    if ([view respondsToSelector:@selector(setEnabled:)]) {
        ((void (*)(id, SEL, BOOL))[view methodForSelector:@selector(setEnabled:)])(view, @selector(setEnabled:), enabled);
    }
    if (text) {
        if ([view isKindOfClass:[NSSegmentedControl class]]) {
            [self applySegmentedControl:(NSSegmentedControl *)view text:text];
        } else if ([view isKindOfClass:[NSSearchField class]]) {
            ((NSSearchField *)view).placeholderString = text;
        } else if ([view isKindOfClass:[NSTextField class]]) {
            NSTextField *field = (NSTextField *)view;
            if (field.isEditable) {
                field.placeholderString = text;
            } else {
                field.stringValue = text;
            }
        } else if ([view isKindOfClass:[NSButton class]]) {
            ((NSButton *)view).title = text;
        }
    }
    if (accessibilityLabel) {
        [view setAccessibilityLabel:accessibilityLabel];
    } else if (role) {
        [view setAccessibilityLabel:(role.length > 0 ? role : (text.length > 0 ? text : @""))];
    } else if (text) {
        [view setAccessibilityLabel:text];
    }
}

- (void)configureNativeView:(NSView *)view command:(NSString *)command key:(NSString *)key {
    if (command.length > 0) {
        self.nativeViewCommands[key] = command;
    } else {
        [self.nativeViewCommands removeObjectForKey:key];
    }
    if ([view isKindOfClass:[NSControl class]]) {
        NSControl *control = (NSControl *)view;
        control.target = command.length > 0 ? self : nil;
        control.action = command.length > 0 ? @selector(emitNativeCommandForSender:) : nil;
    }
}

- (void)emitNativeCommandForSender:(id)sender {
    __block NSString *matchedKey = nil;
    [self.nativeViews enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSView *view, BOOL *stop) {
        if (view == sender) {
            matchedKey = key;
            *stop = YES;
        }
    }];
    if (!matchedKey) return;
    NSString *command = self.nativeViewCommands[matchedKey];
    if (command.length == 0) return;
    NSRange separator = [matchedKey rangeOfString:@":"];
    if (separator.location == NSNotFound) return;
    uint64_t windowId = (uint64_t)[[matchedKey substringToIndex:separator.location] longLongValue];
    NSString *label = [matchedKey substringFromIndex:separator.location + 1];
    const char *commandBytes = [command UTF8String];
    const char *labelBytes = [label UTF8String];
    [self emitEvent:(native_sdk_appkit_event_t){
        .kind = NATIVE_SDK_APPKIT_EVENT_NATIVE_COMMAND,
        .window_id = windowId,
        .command_name = commandBytes,
        .command_name_len = [command lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        .view_label = labelBytes,
        .view_label_len = [label lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
    }];
}

- (BOOL)createNativeViewInWindow:(uint64_t)windowId label:(NSString *)label kind:(NSInteger)kind parent:(NSString *)parent x:(double)x y:(double)y width:(double)width height:(double)height layer:(NSInteger)layer visible:(BOOL)visible enabled:(BOOL)enabled role:(NSString *)role accessibilityLabel:(NSString *)accessibilityLabel text:(NSString *)text command:(NSString *)command {
    if (label.length == 0 || x < 0 || y < 0 || width < 0 || height < 0) return NO;
    if (self.nativeViews.count >= NativeSdkMaxNativeViews) return NO;
    NSWindow *window = self.windows[@(windowId)] ?: (windowId == 1 ? self.window : nil);
    if (!window || !window.contentView) return NO;

    NSString *key = [self nativeViewKeyForWindow:windowId label:label];
    if (self.nativeViews[key]) return NO;

    NSView *parentView = [self nativeParentViewForWindow:windowId parent:parent];
    if (!parentView) return NO;

    NSView *view = [self makeNativeViewWithKind:kind label:label role:role text:text];
    if (!view) return NO;
    view.frame = [self viewFrameForContainer:parentView x:x y:y width:width height:height];
    view.hidden = !visible;
    view.layer.zPosition = layer;
    NSString *initialText = text.length > 0 ? text : (role.length > 0 ? role : nil);
    NSString *initialAccessibilityLabel = accessibilityLabel.length > 0 ? accessibilityLabel : nil;
    [self applyNativeViewState:view enabled:enabled role:role accessibilityLabel:initialAccessibilityLabel text:initialText];
    [self configureNativeView:view command:command key:key];

    [parentView addSubview:view positioned:NSWindowAbove relativeTo:nil];
    if ([view isKindOfClass:[NativeSdkMetalSurfaceView class]]) {
        [(NativeSdkMetalSurfaceView *)view configureWithHost:self windowId:windowId label:label];
    }
    self.nativeViews[key] = view;
    if (text.length > 0) {
        [self.nativeViewExplicitTextKeys addObject:key];
    } else {
        [self.nativeViewExplicitTextKeys removeObject:key];
    }
    [self reorderWebViewsInWindow:windowId];
    [self scheduleFrame];
    return YES;
}

- (BOOL)updateNativeViewInWindow:(uint64_t)windowId label:(NSString *)label hasFrame:(BOOL)hasFrame x:(double)x y:(double)y width:(double)width height:(double)height hasLayer:(BOOL)hasLayer layer:(NSInteger)layer hasVisible:(BOOL)hasVisible visible:(BOOL)visible hasEnabled:(BOOL)hasEnabled enabled:(BOOL)enabled hasRole:(BOOL)hasRole role:(NSString *)role hasAccessibilityLabel:(BOOL)hasAccessibilityLabel accessibilityLabel:(NSString *)accessibilityLabel hasText:(BOOL)hasText text:(NSString *)text hasCommand:(BOOL)hasCommand command:(NSString *)command {
    NSString *key = [self nativeViewKeyForWindow:windowId label:label];
    NSView *view = self.nativeViews[key];
    if (!view) return NO;
    if (hasFrame) {
        if (x < 0 || y < 0 || width < 0 || height < 0) return NO;
        NSView *parent = view.superview;
        if (!parent) return NO;
        view.frame = [self viewFrameForContainer:parent x:x y:y width:width height:height];
    }
    if (hasLayer) {
        view.wantsLayer = YES;
        view.layer.zPosition = layer;
    }
    if (hasVisible) view.hidden = !visible;
    BOOL shouldApplyState = hasEnabled || hasRole || hasAccessibilityLabel || hasText;
    if (hasText) {
        if (text.length > 0) {
            [self.nativeViewExplicitTextKeys addObject:key];
        } else {
            [self.nativeViewExplicitTextKeys removeObject:key];
        }
    }
    if (shouldApplyState) {
        BOOL currentEnabled = enabled;
        if (!hasEnabled) {
            currentEnabled = YES;
            if ([view respondsToSelector:@selector(isEnabled)]) {
                currentEnabled = ((BOOL (*)(id, SEL))[view methodForSelector:@selector(isEnabled)])(view, @selector(isEnabled));
            }
        }
        BOOL explicitText = [self.nativeViewExplicitTextKeys containsObject:key];
        NSString *displayText = hasText ? text : ((!explicitText && hasRole) ? role : nil);
        [self applyNativeViewState:view enabled:currentEnabled role:(hasRole ? role : nil) accessibilityLabel:(hasAccessibilityLabel ? accessibilityLabel : nil) text:displayText];
    }
    if (hasCommand) [self configureNativeView:view command:command key:key];
    [self reorderWebViewsInWindow:windowId];
    [self scheduleFrame];
    return YES;
}

- (BOOL)setNativeViewFrameInWindow:(uint64_t)windowId label:(NSString *)label x:(double)x y:(double)y width:(double)width height:(double)height {
    return [self updateNativeViewInWindow:windowId label:label hasFrame:YES x:x y:y width:width height:height hasLayer:NO layer:0 hasVisible:NO visible:YES hasEnabled:NO enabled:YES hasRole:NO role:@"" hasAccessibilityLabel:NO accessibilityLabel:@"" hasText:NO text:@"" hasCommand:NO command:@""];
}

- (BOOL)setNativeViewVisibleInWindow:(uint64_t)windowId label:(NSString *)label visible:(BOOL)visible {
    return [self updateNativeViewInWindow:windowId label:label hasFrame:NO x:0 y:0 width:0 height:0 hasLayer:NO layer:0 hasVisible:YES visible:visible hasEnabled:NO enabled:YES hasRole:NO role:@"" hasAccessibilityLabel:NO accessibilityLabel:@"" hasText:NO text:@"" hasCommand:NO command:@""];
}

- (BOOL)focusNativeViewInWindow:(uint64_t)windowId label:(NSString *)label {
    NSWindow *window = self.windows[@(windowId)] ?: (windowId == 1 ? self.window : nil);
    if (!window) return NO;
    if ([label isEqualToString:@"main"]) {
        WKWebView *webView = [self webViewForWindowId:windowId];
        if (!webView || webView.hidden) return NO;
        [window makeKeyAndOrderFront:nil];
        return [window makeFirstResponder:webView];
    }
    WKWebView *webView = self.childWebViews[[self webViewKeyForWindow:windowId label:label]];
    if (webView && !webView.hidden) {
        [window makeKeyAndOrderFront:nil];
        return [window makeFirstResponder:webView];
    }
    NSView *view = self.nativeViews[[self nativeViewKeyForWindow:windowId label:label]];
    if (!view || view.hidden) return NO;
    window = view.window ?: window;
    return [window makeFirstResponder:view];
}

- (BOOL)presentGpuSurfacePixelsInWindow:(uint64_t)windowId label:(NSString *)label width:(NSUInteger)width height:(NSUInteger)height scale:(CGFloat)scale hasDirtyRect:(BOOL)hasDirtyRect dirtyX:(CGFloat)dirtyX dirtyY:(CGFloat)dirtyY dirtyWidth:(CGFloat)dirtyWidth dirtyHeight:(CGFloat)dirtyHeight rgba8:(const uint8_t *)rgba8 byteLength:(NSUInteger)byteLength {
    NSString *key = [self nativeViewKeyForWindow:windowId label:label];
    NSView *view = self.nativeViews[key];
    if (![view isKindOfClass:[NativeSdkMetalSurfaceView class]]) return NO;
    NativeSdkMetalSurfaceView *surface = (NativeSdkMetalSurfaceView *)view;
    /* A raw pixel present moves the glass past the retained command
     * dictionary; the next patch attempt must refuse into a full
     * resync. (The packet path calls presentPixelsWithWidth internally,
     * so the invalidation lives here at the raw entry, not inside it.) */
    surface.hasCanvasRetainedState = NO;
    const BOOL presented = [surface presentPixelsWithWidth:width height:height scale:scale hasDirtyRect:hasDirtyRect dirtyX:dirtyX dirtyY:dirtyY dirtyWidth:dirtyWidth dirtyHeight:dirtyHeight dirtyRects:nil rgba8:rgba8 byteLength:byteLength];
    if (presented) [self showDeferredWindowIfPending:windowId reason:"first-present"];
    return presented;
}

- (NSInteger)presentGpuSurfacePacketInWindow:(uint64_t)windowId label:(NSString *)label surfaceWidth:(CGFloat)surfaceWidth height:(CGFloat)surfaceHeight scale:(CGFloat)scale clearR:(uint8_t)clearR clearG:(uint8_t)clearG clearB:(uint8_t)clearB clearA:(uint8_t)clearA requiresRender:(BOOL)requiresRender commandCount:(NSUInteger)commandCount unsupportedCommandCount:(NSUInteger)unsupportedCommandCount representable:(BOOL)representable json:(const uint8_t *)json byteLength:(NSUInteger)byteLength {
    NSString *key = [self nativeViewKeyForWindow:windowId label:label];
    NSView *view = self.nativeViews[key];
    if (![view isKindOfClass:[NativeSdkMetalSurfaceView class]]) return -1;
    const NSInteger result = [(NativeSdkMetalSurfaceView *)view presentGpuPacketWithSurfaceWidth:surfaceWidth height:surfaceHeight scale:scale clearR:clearR clearG:clearG clearB:clearB clearA:clearA requiresRender:requiresRender commandCount:commandCount unsupportedCommandCount:unsupportedCommandCount representable:representable json:json byteLength:byteLength];
    if (result == 1) {
        [self applyWindowClearColor:windowId red:clearR green:clearG blue:clearB alpha:clearA];
        [self showDeferredWindowIfPending:windowId reason:"first-present"];
    }
    return result;
}

- (NSInteger)presentGpuSurfacePacketBinaryInWindow:(uint64_t)windowId label:(NSString *)label surfaceWidth:(CGFloat)surfaceWidth height:(CGFloat)surfaceHeight scale:(CGFloat)scale clearR:(uint8_t)clearR clearG:(uint8_t)clearG clearB:(uint8_t)clearB clearA:(uint8_t)clearA requiresRender:(BOOL)requiresRender commandCount:(NSUInteger)commandCount unsupportedCommandCount:(NSUInteger)unsupportedCommandCount representable:(BOOL)representable packet:(const uint8_t *)packet byteLength:(NSUInteger)byteLength {
    NSString *key = [self nativeViewKeyForWindow:windowId label:label];
    NSView *view = self.nativeViews[key];
    if (![view isKindOfClass:[NativeSdkMetalSurfaceView class]]) return -1;
    static BOOL firstPacketLapDone = NO;
    if (!firstPacketLapDone) {
        firstPacketLapDone = YES;
        NativeSdkLaunchLap("first_packet_present_begin");
    }
    const NSInteger result = [(NativeSdkMetalSurfaceView *)view presentGpuPacketBinaryWithSurfaceWidth:surfaceWidth height:surfaceHeight scale:scale clearR:clearR clearG:clearG clearB:clearB clearA:clearA requiresRender:requiresRender commandCount:commandCount unsupportedCommandCount:unsupportedCommandCount representable:representable packet:packet byteLength:byteLength];
    if (result == 1) {
        [self applyWindowClearColor:windowId red:clearR green:clearG blue:clearB alpha:clearA];
        [self showDeferredWindowIfPending:windowId reason:"first-present"];
    }
    return result;
}

- (BOOL)requestGpuSurfaceFrameInWindow:(uint64_t)windowId label:(NSString *)label {
    NSString *key = [self nativeViewKeyForWindow:windowId label:label];
    NSView *view = self.nativeViews[key];
    if (![view isKindOfClass:[NativeSdkMetalSurfaceView class]]) return NO;
    [(NativeSdkMetalSurfaceView *)view requestRetainedCanvasFrame];
    return YES;
}

- (BOOL)noteGpuSurfaceInputInWindow:(uint64_t)windowId label:(NSString *)label {
    NSString *key = [self nativeViewKeyForWindow:windowId label:label];
    NSView *view = self.nativeViews[key];
    if (![view isKindOfClass:[NativeSdkMetalSurfaceView class]]) return NO;
    [(NativeSdkMetalSurfaceView *)view noteGpuSurfaceInputActivity];
    return YES;
}

- (BOOL)setGpuSurfaceScrollDriversInWindow:(uint64_t)windowId label:(NSString *)label drivers:(const native_sdk_appkit_scroll_driver_t *)drivers count:(NSUInteger)count {
    NSString *key = [self nativeViewKeyForWindow:windowId label:label];
    NSView *view = self.nativeViews[key];
    if (![view isKindOfClass:[NativeSdkMetalSurfaceView class]]) return NO;
    [(NativeSdkMetalSurfaceView *)view setScrollDrivers:drivers count:count];
    return YES;
}

- (BOOL)showContextMenuInWindow:(uint64_t)windowId label:(NSString *)label x:(double)x y:(double)y token:(uint64_t)token items:(const native_sdk_appkit_context_menu_item_t *)items count:(NSUInteger)count {
    NSView *view = nil;
    if (label.length > 0) view = self.nativeViews[[self nativeViewKeyForWindow:windowId label:label]];
    if (!view) view = ((NSWindow *)self.windows[@(windowId)]).contentView;
    if (!view || count == 0) return NO;

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    menu.autoenablesItems = NO;
    NativeSdkContextMenuTarget *target = [[NativeSdkContextMenuTarget alloc] init];
    for (NSUInteger index = 0; index < count; index += 1) {
        const native_sdk_appkit_context_menu_item_t item = items[index];
        if (item.separator) {
            [menu addItem:[NSMenuItem separatorItem]];
            continue;
        }
        NSString *title = item.label ? [[NSString alloc] initWithBytes:item.label length:item.label_len encoding:NSUTF8StringEncoding] : @"";
        NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:title ?: @"" action:@selector(contextMenuItemClicked:) keyEquivalent:@""];
        menuItem.target = target;
        menuItem.enabled = item.enabled != 0;
        menuItem.representedObject = @(item.item_id);
        [menu addItem:menuItem];
    }

    // The runtime's point is view-local y-down; the presentation view is
    // AppKit-unflipped unless it says otherwise.
    NSPoint location = NSMakePoint(x, view.isFlipped ? y : view.bounds.size.height - y);
    NSString *eventLabel = [label copy] ?: @"";
    __weak NativeSdkAppKitHost *weakSelf = self;
    // Present on the next loop turn: the request arrives mid input
    // dispatch and popUp runs its own nested tracking loop. The selection
    // event is emitted one further turn later so a pending item action
    // (delivered during menu teardown) always lands first.
    dispatch_async(dispatch_get_main_queue(), ^{
        NativeSdkAppKitHost *presentSelf = weakSelf;
        if (!presentSelf) return;
        [menu popUpMenuPositioningItem:nil atLocation:location inView:view];
        dispatch_async(dispatch_get_main_queue(), ^{
            NativeSdkAppKitHost *emitSelf = weakSelf;
            if (!emitSelf) return;
            const char *labelBytes = eventLabel.UTF8String ?: "";
            [emitSelf emitEvent:(native_sdk_appkit_event_t){
                .kind = NATIVE_SDK_APPKIT_EVENT_CONTEXT_MENU_ACTION,
                .window_id = windowId,
                .view_label = labelBytes,
                .view_label_len = [eventLabel lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                .timestamp_ns = NativeSdkTimestampNanoseconds(),
                .widget_id = token,
                .menu_item_id = target.selectedItemId,
            }];
        });
    });
    return YES;
}

- (BOOL)uploadGpuSurfaceImageWithId:(uint64_t)imageId width:(NSUInteger)width height:(NSUInteger)height rgba8:(const uint8_t *)rgba8 byteLength:(NSUInteger)byteLength {
    if (imageId == 0 || !rgba8 || width == 0 || height == 0) return NO;
    if (width > NSUIntegerMax / height || width * height > NSUIntegerMax / 4) return NO;
    if (byteLength != width * height * 4) return NO;
    // Copy the caller's bytes: the runtime's slot pool is reused on
    // register/unregister, while the store's NSImage lives until the id
    // is removed or replaced.
    NSData *pixelData = [NSData dataWithBytes:rgba8 length:byteLength];
    NSImage *image = NativeSdkCreateRGBA8Image(width, height, pixelData);
    if (!image) return NO;
    if (!self.canvasImageStore) self.canvasImageStore = [[NSMutableDictionary alloc] init];
    NSString *key = [NSString stringWithFormat:@"%llu", (unsigned long long)imageId];
    self.canvasImageStore[key] = image;
    return YES;
}

- (BOOL)removeGpuSurfaceImageWithId:(uint64_t)imageId {
    if (imageId == 0) return NO;
    NSString *key = [NSString stringWithFormat:@"%llu", (unsigned long long)imageId];
    [self.canvasImageStore removeObjectForKey:key];
    return YES;
}

- (BOOL)setNativeViewCursorInWindow:(uint64_t)windowId label:(NSString *)label cursor:(NSInteger)cursor {
    NSString *key = [self nativeViewKeyForWindow:windowId label:label];
    NSView *view = self.nativeViews[key];
    if (![view isKindOfClass:[NativeSdkMetalSurfaceView class]]) return NO;
    [(NativeSdkMetalSurfaceView *)view setSurfaceCursor:NativeSdkCursorForKind(cursor)];
    return YES;
}

- (BOOL)updateWidgetAccessibilityInWindow:(uint64_t)windowId label:(NSString *)label nodes:(const native_sdk_appkit_widget_accessibility_node_t *)nodes count:(NSUInteger)count {
    NSString *key = [self nativeViewKeyForWindow:windowId label:label];
    NSView *view = self.nativeViews[key];
    if (![view isKindOfClass:[NativeSdkMetalSurfaceView class]]) return NO;
    [(NativeSdkMetalSurfaceView *)view updateWidgetAccessibilityWithNodes:nodes count:count];
    return YES;
}

- (BOOL)nativeView:(NSView *)candidate isInSubtreeRootedAt:(NSView *)root {
    for (NSView *view = candidate; view; view = view.superview) {
        if (view == root) return YES;
    }
    return NO;
}

- (NSArray<NSString *> *)nativeViewKeysInSubtreeForWindow:(uint64_t)windowId rootKey:(NSString *)rootKey {
    NSView *root = self.nativeViews[rootKey];
    if (!root) return @[];
    NSString *prefix = [NSString stringWithFormat:@"%llu:", windowId];
    NSMutableArray<NSString *> *keys = [[NSMutableArray alloc] init];
    for (NSString *key in self.nativeViews) {
        if (![key hasPrefix:prefix]) continue;
        NSView *view = self.nativeViews[key];
        if (view && [self nativeView:view isInSubtreeRootedAt:root]) {
            [keys addObject:key];
        }
    }
    return keys;
}

- (BOOL)closeNativeViewInWindow:(uint64_t)windowId label:(NSString *)label {
    NSString *key = [self nativeViewKeyForWindow:windowId label:label];
    NSArray<NSString *> *keys = [self nativeViewKeysInSubtreeForWindow:windowId rootKey:key];
    if (keys.count == 0) return NO;
    for (NSString *viewKey in keys) {
        [self dropAdoptedViewSurfaceForKey:viewKey];
        NSView *view = self.nativeViews[viewKey];
        [view removeFromSuperview];
        [self.nativeViews removeObjectForKey:viewKey];
        [self.nativeViewCommands removeObjectForKey:viewKey];
        [self.nativeViewExplicitTextKeys removeObject:viewKey];
    }
    [self reorderWebViewsInWindow:windowId];
    [self scheduleFrame];
    return YES;
}

- (void)closeNativeViewsInWindow:(uint64_t)windowId {
    NSString *prefix = [NSString stringWithFormat:@"%llu:", windowId];
    NSArray<NSString *> *keys = [self.nativeViews.allKeys copy];
    for (NSString *key in keys) {
        if (![key hasPrefix:prefix]) continue;
        [self dropAdoptedViewSurfaceForKey:key];
        NSView *view = self.nativeViews[key];
        [view removeFromSuperview];
        [self.nativeViews removeObjectForKey:key];
        [self.nativeViewCommands removeObjectForKey:key];
        [self.nativeViewExplicitTextKeys removeObject:key];
    }
    [self reorderWebViewsInWindow:windowId];
}

- (void)dropAdoptedViewSurfaceForKey:(NSString *)key {
    NSView *adopted = self.adoptedViewSurfaces[key];
    if (!adopted) return;
    [adopted removeFromSuperview];
    [self.adoptedViewSurfaces removeObjectForKey:key];
}

- (BOOL)adoptViewSurfaceInWindow:(uint64_t)windowId label:(NSString *)label surface:(NSView *)surface {
    if (label.length == 0 || ![surface isKindOfClass:[NSView class]]) return NO;
    NSString *key = [self nativeViewKeyForWindow:windowId label:label];
    NSView *container = self.nativeViews[key];
    if (!container) return NO;
    [self dropAdoptedViewSurfaceForKey:key];
    surface.frame = container.bounds;
    surface.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [container addSubview:surface positioned:NSWindowAbove relativeTo:nil];
    self.adoptedViewSurfaces[key] = surface;
    // The adopted view owns keyboard input while it has focus (a VM display,
    // a video view): hand it first responder at adoption, and reclaim on
    // clicks inside it (plain NSViews never claim focus on mouseDown, so
    // without this the canvas keeps the keyboard forever).
    [container.window makeFirstResponder:surface];
    [self installAdoptedSurfaceClickMonitor];
    [self scheduleFrame];
    return YES;
}

- (BOOL)viewIsAdoptedSurfaceDescendant:(NSView *)view {
    for (NSView *candidate = view; candidate; candidate = candidate.superview) {
        for (NSView *surface in self.adoptedViewSurfaces.allValues) {
            if (candidate == surface) return YES;
        }
    }
    return NO;
}

- (void)installAdoptedSurfaceClickMonitor {
    if (self.adoptedSurfaceClickMonitor) return;
    __weak NativeSdkAppKitHost *weakSelf = self;
    self.adoptedSurfaceClickMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^NSEvent *(NSEvent *event) {
        NativeSdkAppKitHost *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.adoptedViewSurfaces.count == 0) return event;
        NSWindow *window = event.window;
        if (!window || !window.contentView) return event;
        NSView *hit = [window.contentView hitTest:[window.contentView convertPoint:event.locationInWindow fromView:nil]];
        if (hit && [strongSelf viewIsAdoptedSurfaceDescendant:hit] && window.firstResponder != hit) {
            [window makeFirstResponder:hit];
        }
        return event;
    }];
}

- (BOOL)releaseViewSurfaceInWindow:(uint64_t)windowId label:(NSString *)label {
    NSString *key = [self nativeViewKeyForWindow:windowId label:label];
    if (!self.adoptedViewSurfaces[key]) return NO;
    [self dropAdoptedViewSurfaceForKey:key];
    [self scheduleFrame];
    return YES;
}

- (BOOL)createWebViewInWindow:(uint64_t)windowId label:(NSString *)label url:(NSString *)url x:(double)x y:(double)y width:(double)width height:(double)height layer:(NSInteger)layer transparent:(BOOL)transparent bridgeEnabled:(BOOL)bridgeEnabled {
    if (label.length == 0 || url.length == 0 || width <= 0 || height <= 0 || x < 0 || y < 0) return NO;
    NSWindow *window = self.windows[@(windowId)] ?: (windowId == 1 ? self.window : nil);
    if (!window || !window.contentView) return NO;
    NSURL *targetURL = [NSURL URLWithString:url];
    if (!targetURL) return NO;
    if (![self allowsNavigationURL:targetURL]) return NO;
    if (self.childWebViews.count >= NativeSdkMaxChildWebViews) return NO;

    NSString *key = [self webViewKeyForWindow:windowId label:label];
    WKWebView *existing = self.childWebViews[key];
    if (existing) return NO;

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    NativeSdkAssetSchemeHandler *assetSchemeHandler = [self assetHandlerForWindowId:windowId];
    if (assetSchemeHandler) {
        [configuration setURLSchemeHandler:assetSchemeHandler forURLScheme:@"zero"];
    }
    if (bridgeEnabled) {
        WKUserContentController *controller = [[WKUserContentController alloc] init];
        NativeSdkBridgeScriptHandler *handler = [[NativeSdkBridgeScriptHandler alloc] init];
        handler.host = self;
        handler.windowId = windowId;
        handler.webViewLabel = label;
        [controller addScriptMessageHandler:handler name:@"nativeSdkBridge"];
        [controller addUserScript:[[WKUserScript alloc] initWithSource:NativeSdkAppKitBridgeScript() injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
        configuration.userContentController = controller;
    }
    if ([configuration.preferences respondsToSelector:NSSelectorFromString(@"setDeveloperExtrasEnabled:")]) {
        [configuration.preferences setValue:@YES forKey:@"developerExtrasEnabled"];
    }

    WKWebView *webview = [[NativeSdkWebView alloc] initWithFrame:[self webViewFrameForWindow:window x:x y:y width:width height:height] configuration:configuration];
    ((NativeSdkWebView *)webview).host = self;
    ((NativeSdkWebView *)webview).windowId = windowId;
    [webview registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    webview.wantsLayer = YES;
    webview.layer.zPosition = layer;
    if (transparent) {
        webview.layer.backgroundColor = NSColor.clearColor.CGColor;
        [webview setValue:@NO forKey:@"drawsBackground"];
    }
    if ([webview respondsToSelector:NSSelectorFromString(@"setInspectable:")]) {
        [webview setValue:@YES forKey:@"inspectable"];
    }
    webview.navigationDelegate = self;
    webview.autoresizingMask = NSViewNotSizable;
    [window.contentView addSubview:webview positioned:NSWindowAbove relativeTo:nil];
    [webview loadRequest:[NSURLRequest requestWithURL:targetURL]];
    self.childWebViews[key] = webview;
    if (bridgeEnabled) [self.bridgeEnabledChildWebViewKeys addObject:key];
    [self reorderWebViewsInWindow:windowId];
    [self scheduleBridgeFrames];
    return YES;
}

- (BOOL)setWebViewFrameInWindow:(uint64_t)windowId label:(NSString *)label x:(double)x y:(double)y width:(double)width height:(double)height {
    if (label.length == 0 || width <= 0 || height <= 0 || x < 0 || y < 0) return NO;
    NSWindow *window = self.windows[@(windowId)] ?: (windowId == 1 ? self.window : nil);
    if ([label isEqualToString:@"main"]) {
        WKWebView *webView = [self ensureMainWebViewForWindowId:windowId];
        if (!window || !webView) return NO;
        webView.autoresizingMask = NSViewNotSizable;
        webView.frame = [self webViewFrameForWindow:window x:x y:y width:width height:height];
        [self reorderWebViewsInWindow:windowId];
        [self scheduleBridgeFrames];
        return YES;
    }
    WKWebView *webview = self.childWebViews[[self webViewKeyForWindow:windowId label:label]];
    if (!window || !webview) return NO;
    webview.frame = [self webViewFrameForWindow:window x:x y:y width:width height:height];
    [self reorderWebViewsInWindow:windowId];
    [self scheduleBridgeFrames];
    return YES;
}

- (BOOL)navigateWebViewInWindow:(uint64_t)windowId label:(NSString *)label url:(NSString *)url {
    if (label.length == 0 || url.length == 0) return NO;
    NSURL *targetURL = [NSURL URLWithString:url ?: @""];
    if ([label isEqualToString:@"main"]) {
        WKWebView *webView = [self ensureMainWebViewForWindowId:windowId];
        if (!webView || !targetURL) return NO;
        if (![self allowsNavigationURL:targetURL]) return NO;
        [webView loadRequest:[NSURLRequest requestWithURL:targetURL]];
        [self scheduleBridgeFrames];
        return YES;
    }
    WKWebView *webview = self.childWebViews[[self webViewKeyForWindow:windowId label:label]];
    if (!webview || !targetURL) return NO;
    if (![self allowsNavigationURL:targetURL]) return NO;
    [webview loadRequest:[NSURLRequest requestWithURL:targetURL]];
    [self scheduleBridgeFrames];
    return YES;
}

- (BOOL)setWebViewZoomInWindow:(uint64_t)windowId label:(NSString *)label zoom:(double)zoom {
    if (label.length == 0 || zoom < 0.25 || zoom > 5.0) return NO;
    if ([label isEqualToString:@"main"]) {
        WKWebView *webView = [self ensureMainWebViewForWindowId:windowId];
        if (!webView) return NO;
        webView.pageZoom = zoom;
        return YES;
    }
    WKWebView *webview = self.childWebViews[[self webViewKeyForWindow:windowId label:label]];
    if (!webview) return NO;
    webview.pageZoom = zoom;
    return YES;
}

- (BOOL)setWebViewLayerInWindow:(uint64_t)windowId label:(NSString *)label layer:(NSInteger)layer {
    if (label.length == 0) return NO;
    if ([label isEqualToString:@"main"]) {
        WKWebView *webView = [self ensureMainWebViewForWindowId:windowId];
        if (!webView) return NO;
        webView.wantsLayer = YES;
        webView.layer.zPosition = layer;
        [self reorderWebViewsInWindow:windowId];
        return YES;
    }
    WKWebView *webview = self.childWebViews[[self webViewKeyForWindow:windowId label:label]];
    if (!webview) return NO;
    webview.wantsLayer = YES;
    webview.layer.zPosition = layer;
    [self reorderWebViewsInWindow:windowId];
    return YES;
}

- (BOOL)closeWebViewInWindow:(uint64_t)windowId label:(NSString *)label {
    NSString *key = [self webViewKeyForWindow:windowId label:label];
    WKWebView *webview = self.childWebViews[key];
    if (!webview) return NO;
    [self removeBridgeHandlerForChildWebView:webview key:key];
    [webview removeFromSuperview];
    [self.childWebViews removeObjectForKey:key];
    [self reorderWebViewsInWindow:windowId];
    [self scheduleBridgeFrames];
    return YES;
}

- (void)closeWebViewsInWindow:(uint64_t)windowId {
    NSString *prefix = [NSString stringWithFormat:@"%llu:", windowId];
    NSArray<NSString *> *keys = [self.childWebViews.allKeys copy];
    for (NSString *key in keys) {
        if (![key hasPrefix:prefix]) continue;
        WKWebView *webview = self.childWebViews[key];
        [self removeBridgeHandlerForChildWebView:webview key:key];
        [webview removeFromSuperview];
        [self.childWebViews removeObjectForKey:key];
    }
    [self reorderWebViewsInWindow:windowId];
}

- (void)reorderWebViewsInWindow:(uint64_t)windowId {
    NSWindow *window = self.windows[@(windowId)] ?: (windowId == 1 ? self.window : nil);
    NSView *contentView = window.contentView;
    if (!contentView) return;

    NSMutableArray<NSView *> *views = [[NSMutableArray alloc] init];
    WKWebView *mainWebView = self.webViews[@(windowId)];
    if (mainWebView && mainWebView.superview == contentView) {
        [views addObject:mainWebView];
    }

    NSString *prefix = [NSString stringWithFormat:@"%llu:", windowId];
    for (NSString *key in self.childWebViews) {
        if (![key hasPrefix:prefix]) continue;
        WKWebView *view = self.childWebViews[key];
        if (view && view.superview == contentView) {
            [views addObject:view];
        }
    }
    for (NSString *key in self.nativeViews) {
        if (![key hasPrefix:prefix]) continue;
        NSView *view = self.nativeViews[key];
        if (view && view.superview == contentView) {
            [views addObject:view];
        }
    }

    [views sortUsingComparator:^NSComparisonResult(NSView *first, NSView *second) {
        CGFloat firstLayer = first.layer.zPosition;
        CGFloat secondLayer = second.layer.zPosition;
        if (firstLayer < secondLayer) return NSOrderedAscending;
        if (firstLayer > secondLayer) return NSOrderedDescending;
        NSUInteger firstIndex = [contentView.subviews indexOfObjectIdenticalTo:first];
        NSUInteger secondIndex = [contentView.subviews indexOfObjectIdenticalTo:second];
        if (firstIndex < secondIndex) return NSOrderedAscending;
        if (firstIndex > secondIndex) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSView *previous = nil;
    for (NSView *view in views) {
        [contentView addSubview:view positioned:NSWindowAbove relativeTo:previous];
        previous = view;
    }
    [self updateCoveredMouseRectsInWindow:windowId];
}

- (void)updateCoveredMouseRectsInWindow:(uint64_t)windowId {
    NSWindow *window = self.windows[@(windowId)] ?: (windowId == 1 ? self.window : nil);
    NSView *contentView = window.contentView;
    if (!contentView) return;

    NSMutableArray<NSView *> *views = [[NSMutableArray alloc] init];
    WKWebView *mainWebView = self.webViews[@(windowId)];
    if ([mainWebView isKindOfClass:[NativeSdkWebView class]] && mainWebView.superview == contentView) {
        [views addObject:mainWebView];
    }

    NSString *prefix = [NSString stringWithFormat:@"%llu:", windowId];
    for (NSString *key in self.childWebViews) {
        if (![key hasPrefix:prefix]) continue;
        WKWebView *webView = self.childWebViews[key];
        if ([webView isKindOfClass:[NativeSdkWebView class]] && webView.superview == contentView) {
            [views addObject:webView];
        }
    }
    for (NSString *key in self.nativeViews) {
        if (![key hasPrefix:prefix]) continue;
        NSView *view = self.nativeViews[key];
        if (view && view.superview == contentView) {
            [views addObject:view];
        }
    }

    [views sortUsingComparator:^NSComparisonResult(NSView *first, NSView *second) {
        CGFloat firstLayer = first.layer.zPosition;
        CGFloat secondLayer = second.layer.zPosition;
        if (firstLayer < secondLayer) return NSOrderedAscending;
        if (firstLayer > secondLayer) return NSOrderedDescending;
        NSUInteger firstIndex = [contentView.subviews indexOfObjectIdenticalTo:first];
        NSUInteger secondIndex = [contentView.subviews indexOfObjectIdenticalTo:second];
        if (firstIndex < secondIndex) return NSOrderedAscending;
        if (firstIndex > secondIndex) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    for (NSUInteger index = 0; index < views.count; index++) {
        if (![views[index] isKindOfClass:[NativeSdkWebView class]]) continue;
        NativeSdkWebView *webView = (NativeSdkWebView *)views[index];
        NSMutableArray<NSValue *> *coveredRects = [[NSMutableArray alloc] init];
        for (NSUInteger coverIndex = index + 1; coverIndex < views.count; coverIndex++) {
            NSView *coveringView = views[coverIndex];
            if (coveringView.hidden) continue;
            NSRect intersection = NSIntersectionRect(webView.frame, coveringView.frame);
            if (NSIsEmptyRect(intersection)) continue;
            [coveredRects addObject:[NSValue valueWithRect:[webView convertRect:intersection fromView:contentView]]];
        }
        webView.coveredMouseRects = coveredRects;
        [self applyCoveredMouseRects:coveredRects toWebView:webView];
    }
}

- (void)applyCoveredMouseRects:(NSArray<NSValue *> *)rects toWebView:(WKWebView *)webView {
    NSMutableString *rectsJson = [[NSMutableString alloc] initWithString:@"["];
    for (NSUInteger index = 0; index < rects.count; index++) {
        NSRect rect = rects[index].rectValue;
        CGFloat x = rect.origin.x;
        CGFloat y = webView.isFlipped ? rect.origin.y : webView.bounds.size.height - rect.origin.y - rect.size.height;
        if (index > 0) [rectsJson appendString:@","];
        [rectsJson appendFormat:@"{\"x\":%.3f,\"y\":%.3f,\"width\":%.3f,\"height\":%.3f}", x, y, rect.size.width, rect.size.height];
    }
    [rectsJson appendString:@"]"];

    // WKWebView can keep CSS hover active via internal tracking even after
    // AppKit hit-testing excludes the view, so mirror native coverage into the
    // document as transparent fixed-position event covers.
    NSString *script = [NSString stringWithFormat:
        @"(function(rects){"
         "var id='__native_sdk_covered_mouse_rects__';"
         "var root=document.getElementById(id);"
         "if(!rects.length){if(root)root.remove();return;}"
         "var parent=document.documentElement||document.body;"
         "if(!parent)return;"
         "if(!root){"
           "root=document.createElement('div');"
           "root.id=id;"
           "root.style.cssText='position:fixed;left:0;top:0;width:0;height:0;z-index:2147483647;pointer-events:none;';"
           "parent.appendChild(root);"
         "}"
         "root.textContent='';"
         "rects.forEach(function(r){"
           "var cover=document.createElement('div');"
           "cover.style.cssText='position:fixed;left:'+r.x+'px;top:'+r.y+'px;width:'+r.width+'px;height:'+r.height+'px;background:transparent;z-index:2147483647;pointer-events:auto;';"
           "['pointerover','pointerenter','pointermove','pointerout','pointerleave','pointerdown','pointerup','pointercancel','mouseover','mouseenter','mousemove','mouseout','mouseleave','mousedown','mouseup','click','contextmenu'].forEach(function(type){"
             "cover.addEventListener(type,function(event){event.preventDefault();event.stopPropagation();},true);"
           "});"
           "root.appendChild(cover);"
         "});"
        "})(%@);", rectsJson];
    [webView evaluateJavaScript:script completionHandler:nil];
}

- (void)removeBridgeHandlerForChildWebView:(WKWebView *)webView key:(NSString *)key {
    if (!webView || key.length == 0 || ![self.bridgeEnabledChildWebViewKeys containsObject:key]) return;
    [webView.configuration.userContentController removeScriptMessageHandlerForName:@"nativeSdkBridge"];
    [self.bridgeEnabledChildWebViewKeys removeObject:key];
}

- (void)removeAllChildBridgeHandlers {
    NSArray<NSString *> *keys = [self.bridgeEnabledChildWebViewKeys.allObjects copy];
    for (NSString *key in keys) {
        [self removeBridgeHandlerForChildWebView:self.childWebViews[key] key:key];
    }
}

static NSRect constrainFrame(NSRect frame) {
    NSScreen *screen = [NSScreen mainScreen];
    if (!screen) return frame;
    NSRect visible = screen.visibleFrame;
    if (frame.size.width > visible.size.width) frame.size.width = visible.size.width;
    if (frame.size.height > visible.size.height) frame.size.height = visible.size.height;
    if (NSMinX(frame) < NSMinX(visible)) frame.origin.x = NSMinX(visible);
    if (NSMinY(frame) < NSMinY(visible)) frame.origin.y = NSMinY(visible);
    if (NSMaxX(frame) > NSMaxX(visible)) frame.origin.x = NSMaxX(visible) - frame.size.width;
    if (NSMaxY(frame) > NSMaxY(visible)) frame.origin.y = NSMaxY(visible) - frame.size.height;
    return frame;
}

static NSString *NativeSdkAppKitBridgeScript(void) {
    return @"(function(){"
        "if(window.zero&&window.zero.invoke){return;}"
        "var pending=new Map();"
        "var listeners=new Map();"
        "var nextId=1;"
        "function post(message){"
        "if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.nativeSdkBridge){window.webkit.messageHandlers.nativeSdkBridge.postMessage(message);return;}"
        "if(window.nativeSdkCefBridge&&window.nativeSdkCefBridge.postMessage){window.nativeSdkCefBridge.postMessage(message);return;}"
        "throw new Error('native-sdk bridge transport is unavailable');"
        "}"
        "function complete(response){"
        "var id=response&&response.id!=null?String(response.id):'';"
        "var entry=pending.get(id);"
        "if(!entry){return;}"
        "pending.delete(id);"
        "if(response.ok){entry.resolve(response.result===undefined?null:response.result);return;}"
        "var errorInfo=response.error||{};"
        "var error=new Error(errorInfo.message||'Native command failed');"
        "error.code=errorInfo.code||'internal_error';"
        "entry.reject(error);"
        "}"
        "function invoke(command,payload){"
        "if(typeof command!=='string'||command.length===0){return Promise.reject(new TypeError('command must be a non-empty string'));}"
        "var id=String(nextId++);"
        "var envelope=JSON.stringify({id:id,command:command,payload:payload===undefined?null:payload});"
        "return new Promise(function(resolve,reject){"
        "pending.set(id,{resolve:resolve,reject:reject});"
        "try{post(envelope);}catch(error){pending.delete(id);reject(error);}"
        "});"
        "}"
        "function selector(value){return typeof value==='number'?{id:value}:{label:String(value)};}"
        "function ensureString(value,name){if(typeof value!=='string'||value.length===0){throw new TypeError(name+' must be a non-empty string');}return value;}"
        "function ensureText(value,name){if(typeof value!=='string'){throw new TypeError(name+' must be a string');}return value;}"
        "function ensureNumber(value,name){if(typeof value!=='number'||!isFinite(value)){throw new TypeError(name+' must be a finite number');}return value;}"
        "function commandPayload(value){if(typeof value==='string'){return {name:ensureString(value,'command')};}value=value||{};var name=value.name!=null?value.name:value.id;return {name:ensureString(name,'command')};}"
        "function validateWebViewSelector(options){if(options.label!=null){ensureString(options.label,'label');}if(options.windowId!=null&&(typeof options.windowId!=='number'||!isFinite(options.windowId)||options.windowId<0||Math.floor(options.windowId)!==options.windowId)){throw new TypeError('windowId must be a non-negative integer');}}"
        "function framePayload(options){options=options||{};validateWebViewSelector(options);var frame=options.frame||options;return {label:options.label,windowId:options.windowId,url:options.url,frame:{x:frame.x==null?0:ensureNumber(frame.x,'frame.x'),y:frame.y==null?0:ensureNumber(frame.y,'frame.y'),width:ensureNumber(frame.width,'frame.width'),height:ensureNumber(frame.height,'frame.height')}};}"
        "function createPayload(options){options=options||{};ensureString(options.url,'url');var payload=framePayload(options);if(options.layer!=null){payload.layer=ensureNumber(options.layer,'layer');}if(options.transparent!=null){payload.transparent=!!options.transparent;}if(options.bridge!=null){payload.bridge=!!options.bridge;}return payload;}"
        "function navigatePayload(options){options=options||{};validateWebViewSelector(options);ensureString(options.url,'url');return {label:options.label,windowId:options.windowId,url:options.url};}"
        "function closePayload(options){options=options||{};validateWebViewSelector(options);return {label:options.label,windowId:options.windowId};}"
        "function webviewHandle(info){return Object.freeze(Object.assign({},info,{setFrame:function(frame){return webviews.setFrame({label:info.label,windowId:info.windowId,frame:frame});},navigate:function(url){return webviews.navigate({label:info.label,windowId:info.windowId,url:url});},setZoom:function(zoom){return webviews.setZoom({label:info.label,windowId:info.windowId,zoom:zoom});},setLayer:function(layer){return webviews.setLayer({label:info.label,windowId:info.windowId,layer:layer});},close:function(){return webviews.close({label:info.label,windowId:info.windowId});}}));}"
        "function validateViewSelector(options){options=options||{};ensureString(options.label,'label');if(options.windowId!=null&&(typeof options.windowId!=='number'||!isFinite(options.windowId)||options.windowId<0||Math.floor(options.windowId)!==options.windowId)){throw new TypeError('windowId must be a non-negative integer');}}"
        "function viewSelectorPayload(options){if(typeof options==='string'){return {label:ensureString(options,'label')};}options=options||{};validateViewSelector(options);return {label:options.label,windowId:options.windowId};}"
        "function optionalFramePayload(options){var frame=options.frame||((options.x!=null||options.y!=null||options.width!=null||options.height!=null)?options:null);if(!frame){return null;}return {x:frame.x==null?0:ensureNumber(frame.x,'frame.x'),y:frame.y==null?0:ensureNumber(frame.y,'frame.y'),width:ensureNumber(frame.width,'frame.width'),height:ensureNumber(frame.height,'frame.height')};}"
        "function viewCreatePayload(options){options=options||{};validateViewSelector(options);ensureString(options.kind,'kind');var payload={label:options.label,kind:options.kind,windowId:options.windowId};var frame=optionalFramePayload(options);if(frame){payload.frame=frame;}if(options.parent!=null){payload.parent=ensureString(options.parent,'parent');}if(options.role!=null){payload.role=ensureText(options.role,'role');}if(options.accessibilityLabel!=null){payload.accessibilityLabel=ensureText(options.accessibilityLabel,'accessibilityLabel');}if(options.text!=null){payload.text=ensureText(options.text,'text');}if(options.command!=null){payload.command=ensureText(options.command,'command');}if(options.url!=null){payload.url=ensureString(options.url,'url');}if(options.layer!=null){payload.layer=ensureNumber(options.layer,'layer');}if(options.visible!=null){payload.visible=!!options.visible;}if(options.enabled!=null){payload.enabled=!!options.enabled;}if(options.transparent!=null){payload.transparent=!!options.transparent;}if(options.bridge!=null){payload.bridge=!!options.bridge;}return payload;}"
        "function viewPatchPayload(options){options=options||{};validateViewSelector(options);var payload={label:options.label,windowId:options.windowId};var frame=optionalFramePayload(options);if(frame){payload.frame=frame;}if(options.layer!=null){payload.layer=ensureNumber(options.layer,'layer');}if(options.visible!=null){payload.visible=!!options.visible;}if(options.enabled!=null){payload.enabled=!!options.enabled;}if(options.role!=null){payload.role=ensureText(options.role,'role');}if(options.accessibilityLabel!=null){payload.accessibilityLabel=ensureText(options.accessibilityLabel,'accessibilityLabel');}if(options.text!=null){payload.text=ensureText(options.text,'text');}if(options.command!=null){payload.command=ensureText(options.command,'command');}if(options.url!=null){payload.url=ensureString(options.url,'url');}return payload;}"
        "function viewFramePayload(options){options=options||{};validateViewSelector(options);var frame=options.frame||options;return {label:options.label,windowId:options.windowId,frame:{x:frame.x==null?0:ensureNumber(frame.x,'frame.x'),y:frame.y==null?0:ensureNumber(frame.y,'frame.y'),width:ensureNumber(frame.width,'frame.width'),height:ensureNumber(frame.height,'frame.height')}};}"
        "function viewVisiblePayload(options){options=options||{};validateViewSelector(options);if(options.visible==null){throw new TypeError('visible is required');}return {label:options.label,windowId:options.windowId,visible:!!options.visible};}"
        "function viewHandle(info){return Object.freeze(Object.assign({},info,{update:function(patch){return views.update(Object.assign({},patch||{},{label:info.label,windowId:info.windowId}));},setFrame:function(frame){return views.setFrame({label:info.label,windowId:info.windowId,frame:frame});},setVisible:function(visible){return views.setVisible({label:info.label,windowId:info.windowId,visible:visible});},focus:function(){return views.focus({label:info.label,windowId:info.windowId});},close:function(){return views.close({label:info.label,windowId:info.windowId});}}));}"
        "function on(name,callback){if(typeof callback!=='function'){throw new TypeError('callback must be a function');}var set=listeners.get(name);if(!set){set=new Set();listeners.set(name,set);}set.add(callback);return function(){off(name,callback);};}"
        "function off(name,callback){var set=listeners.get(name);if(set){set.delete(callback);if(set.size===0){listeners.delete(name);}}}"
        "function emit(name,detail){var set=listeners.get(name);if(set){Array.from(set).forEach(function(callback){callback(detail);});}window.dispatchEvent(new CustomEvent('native-sdk:'+name,{detail:detail}));}"
        "var commands=Object.freeze({"
        "invoke:function(value){return invoke('native-sdk.command.invoke',commandPayload(value));},"
        "list:function(){return invoke('native-sdk.command.list',{});}"
        "});"
        "var windows=Object.freeze({"
        "create:function(options){return invoke('native-sdk.window.create',options||{});},"
        "list:function(){return invoke('native-sdk.window.list',{});},"
        "focus:function(value){return invoke('native-sdk.window.focus',selector(value));},"
        "close:function(value){return invoke('native-sdk.window.close',selector(value));}"
        "});"
        "var dialogs=Object.freeze({"
        "openFile:function(options){return invoke('native-sdk.dialog.openFile',options||{});},"
        "saveFile:function(options){return invoke('native-sdk.dialog.saveFile',options||{});},"
        "showMessage:function(options){return invoke('native-sdk.dialog.showMessage',options||{});}"
        "});"
        "function clipboardReadPayload(value){value=value||{};return {mimeType:ensureString(value.mimeType||value.type||'text/plain','mimeType')};}"
        "function clipboardWritePayload(value){if(typeof value==='string'){return {mimeType:'text/plain',data:value};}value=value||{};var data=value.data!=null?value.data:(value.text!=null?value.text:value.value);return {mimeType:ensureString(value.mimeType||value.type||'text/plain','mimeType'),data:ensureText(data,'data')};}"
        "var clipboard=Object.freeze({"
        "readText:function(){return invoke('native-sdk.clipboard.readText',{});},"
        "writeText:function(value){var text=typeof value==='string'?value:(value||{}).text;return invoke('native-sdk.clipboard.writeText',{text:ensureText(text,'text')});},"
        "read:function(value){return invoke('native-sdk.clipboard.read',clipboardReadPayload(value));},"
        "write:function(value){return invoke('native-sdk.clipboard.write',clipboardWritePayload(value));}"
        "});"
        "var os=Object.freeze({"
        "openUrl:function(value){var options=typeof value==='string'?{url:value}:(value||{});return invoke('native-sdk.os.openUrl',{url:ensureString(options.url,'url')});},"
        "showNotification:function(value){var options=typeof value==='string'?{title:value}:(value||{});var payload={title:ensureString(options.title,'title')};if(options.subtitle!=null){payload.subtitle=ensureString(options.subtitle,'subtitle');}if(options.body!=null){payload.body=ensureString(options.body,'body');}return invoke('native-sdk.os.showNotification',payload);},"
        "revealPath:function(value){var options=typeof value==='string'?{path:value}:(value||{});return invoke('native-sdk.os.revealPath',{path:ensureString(options.path,'path')});},"
        "addRecentDocument:function(value){var options=typeof value==='string'?{path:value}:(value||{});return invoke('native-sdk.os.addRecentDocument',{path:ensureString(options.path,'path')});},"
        "clearRecentDocuments:function(){return invoke('native-sdk.os.clearRecentDocuments',{});}"
        "});"
        "function credentialPayload(value){value=value||{};return {service:ensureString(value.service,'service'),account:ensureString(value.account,'account')};}"
        "function credentialSetPayload(value){var payload=credentialPayload(value);payload.secret=ensureString(value.secret!=null?value.secret:value.value,'secret');return payload;}"
        "var credentials=Object.freeze({"
        "set:function(value){return invoke('native-sdk.credentials.set',credentialSetPayload(value));},"
        "get:function(value){return invoke('native-sdk.credentials.get',credentialPayload(value));},"
        "delete:function(value){return invoke('native-sdk.credentials.delete',credentialPayload(value));}"
        "});"
        "function platformFeaturePayload(value){if(typeof value==='string'){return {feature:ensureString(value,'feature')};}value=value||{};return {feature:ensureString(value.feature!=null?value.feature:value.name,'feature')};}"
        "var platform=Object.freeze({"
        "supports:function(value){return invoke('native-sdk.platform.supports',platformFeaturePayload(value));}"
        "});"
        "function zoomPayload(options){options=options||{};validateWebViewSelector(options);return {label:options.label,windowId:options.windowId,zoom:ensureNumber(options.zoom,'zoom')};}"
        "function layerPayload(options){options=options||{};validateWebViewSelector(options);return {label:options.label,windowId:options.windowId,layer:ensureNumber(options.layer,'layer')};}"
        "var webviews=Object.freeze({"
        "create:function(options){return invoke('native-sdk.webview.create',createPayload(options)).then(webviewHandle);},"
        "list:function(){return invoke('native-sdk.webview.list',{});},"
        "setFrame:function(options){return invoke('native-sdk.webview.setFrame',framePayload(options));},"
        "navigate:function(options){return invoke('native-sdk.webview.navigate',navigatePayload(options));},"
        "setZoom:function(options){return invoke('native-sdk.webview.setZoom',zoomPayload(options));},"
        "setLayer:function(options){return invoke('native-sdk.webview.setLayer',layerPayload(options));},"
        "close:function(options){return invoke('native-sdk.webview.close',closePayload(options));}"
        "});"
        "var views=Object.freeze({"
        "create:function(options){return invoke('native-sdk.view.create',viewCreatePayload(options)).then(viewHandle);},"
        "list:function(){return invoke('native-sdk.view.list',{});},"
        "update:function(options,patch){if(typeof options==='string'){return invoke('native-sdk.view.update',viewPatchPayload(Object.assign({},patch||{},{label:options}))).then(viewHandle);}return invoke('native-sdk.view.update',viewPatchPayload(options)).then(viewHandle);},"
        "setFrame:function(options){return invoke('native-sdk.view.setFrame',viewFramePayload(options)).then(viewHandle);},"
        "setVisible:function(options){return invoke('native-sdk.view.setVisible',viewVisiblePayload(options)).then(viewHandle);},"
        "focus:function(options){return invoke('native-sdk.view.focus',viewSelectorPayload(options)).then(viewHandle);},"
        "focusNext:function(options){options=options||{};return invoke('native-sdk.view.focusNext',{windowId:options.windowId}).then(viewHandle);},"
        "focusPrevious:function(options){options=options||{};return invoke('native-sdk.view.focusPrevious',{windowId:options.windowId}).then(viewHandle);},"
        "close:function(options){return invoke('native-sdk.view.close',viewSelectorPayload(options));}"
        "});"
        "Object.defineProperty(window,'zero',{value:Object.freeze({invoke:invoke,on:on,off:off,commands:commands,windows:windows,dialogs:dialogs,clipboard:clipboard,os:os,credentials:credentials,platform:platform,webviews:webviews,views:views,_complete:complete,_emit:emit}),configurable:false});"
        "})();";
}

static NSString *NativeSdkMimeTypeForPath(NSString *path) {
    NSString *ext = path.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"html"] || [ext isEqualToString:@"htm"]) return @"text/html";
    if ([ext isEqualToString:@"js"] || [ext isEqualToString:@"mjs"]) return @"text/javascript";
    if ([ext isEqualToString:@"css"]) return @"text/css";
    if ([ext isEqualToString:@"json"]) return @"application/json";
    if ([ext isEqualToString:@"svg"]) return @"image/svg+xml";
    if ([ext isEqualToString:@"png"]) return @"image/png";
    if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) return @"image/jpeg";
    if ([ext isEqualToString:@"gif"]) return @"image/gif";
    if ([ext isEqualToString:@"webp"]) return @"image/webp";
    if ([ext isEqualToString:@"woff"]) return @"font/woff";
    if ([ext isEqualToString:@"woff2"]) return @"font/woff2";
    if ([ext isEqualToString:@"ttf"]) return @"font/ttf";
    if ([ext isEqualToString:@"otf"]) return @"font/otf";
    if ([ext isEqualToString:@"wasm"]) return @"application/wasm";
    return @"application/octet-stream";
}

static BOOL NativeSdkDirectoryExists(NSString *path) {
    BOOL isDirectory = NO;
    return path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory;
}

/* Resolve a relative asset FILE path the way the webview asset root and
 * the bundled-font roots resolve directories: inside a packaged .app the
 * bundle's Resources mirrors the app directory's asset tree at the same
 * relative paths, so "assets/music/track.mp3" names Resources/assets/
 * music/track.mp3 when it exists there. Outside a bundle — and for any
 * path the bundle does not carry — the path keeps its plain meaning
 * (cwd-relative), so dev runs and terminal launches are unchanged and a
 * missing bundled file still reports missing to the caller (the audio
 * source cascade falls through to its URL source on exactly that
 * answer). Absolute paths pass through untouched. */
static NSString *NativeSdkResolvedAssetFilePath(NSString *path) {
    if (path.length == 0 || path.isAbsolutePath) return path;
    if (![[NSBundle mainBundle].bundlePath.pathExtension.lowercaseString isEqualToString:@"app"]) return path;
    NSString *resourcePath = [NSBundle mainBundle].resourcePath;
    if (resourcePath.length == 0) return path;
    NSString *bundled = [resourcePath stringByAppendingPathComponent:path];
    BOOL isDirectory = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:bundled isDirectory:&isDirectory] && !isDirectory) return bundled;
    return path;
}

static NSString *NativeSdkResolvedAssetRoot(NSString *rootPath) {
    NSString *resourcePath = [NSBundle mainBundle].resourcePath;
    BOOL isAppBundle = [[NSBundle mainBundle].bundlePath.pathExtension.lowercaseString isEqualToString:@"app"];
    if (rootPath.length == 0 || [rootPath isEqualToString:@"."]) {
        return (isAppBundle && resourcePath.length > 0) ? resourcePath : [[NSFileManager defaultManager] currentDirectoryPath];
    }
    if (rootPath.isAbsolutePath) return rootPath;
    NSString *cwdPath = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:rootPath];
    if (!isAppBundle && NativeSdkDirectoryExists(cwdPath)) return cwdPath;
    if (resourcePath.length > 0) {
        NSString *resourceRoot = [resourcePath stringByAppendingPathComponent:rootPath];
        if (isAppBundle || NativeSdkDirectoryExists(resourceRoot)) return resourceRoot;
    }
    return cwdPath;
}

static BOOL NativeSdkFontAssetExtension(NSString *path) {
    NSString *extension = path.pathExtension.lowercaseString;
    return [extension isEqualToString:@"ttf"] ||
        [extension isEqualToString:@"otf"] ||
        [extension isEqualToString:@"ttc"] ||
        [extension isEqualToString:@"otc"] ||
        [extension isEqualToString:@"woff"] ||
        [extension isEqualToString:@"woff2"];
}

static void NativeSdkRegisterFontsInDirectory(NSString *directoryPath) {
    if (directoryPath.length == 0 || !NativeSdkDirectoryExists(directoryPath)) return;
    NSURL *directoryURL = [NSURL fileURLWithPath:directoryPath isDirectory:YES];
    NSDirectoryEnumerator<NSURL *> *enumerator = [[NSFileManager defaultManager]
        enumeratorAtURL:directoryURL
        includingPropertiesForKeys:@[ NSURLIsRegularFileKey ]
        options:NSDirectoryEnumerationSkipsHiddenFiles
        errorHandler:nil];
    for (NSURL *url in enumerator) {
        NSNumber *isRegularFile = nil;
        if (![url getResourceValue:&isRegularFile forKey:NSURLIsRegularFileKey error:nil] || !isRegularFile.boolValue) continue;
        if (!NativeSdkFontAssetExtension(url.path)) continue;
        CFErrorRef error = NULL;
        CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &error);
        if (error) CFRelease(error);
    }
}

// Bundled-font activation for hosts WITHOUT a live AppKit host object
// (headless session replay measures text through the same CoreText seam
// a live host uses, so the bundled faces must be registered the same
// way). Safe to call alongside a live host: the underlying registration
// is dispatch_once.
void native_sdk_appkit_register_bundled_fonts(void) {
    NativeSdkRegisterBundledFonts();
}

static void NativeSdkRegisterBundledFonts(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *bundle = [NSBundle mainBundle];
        BOOL isAppBundle = [bundle.bundlePath.pathExtension.lowercaseString isEqualToString:@"app"];
        NSString *root = isAppBundle ? bundle.resourcePath : [[NSFileManager defaultManager] currentDirectoryPath];
        if (root.length == 0) return;
        NSArray<NSString *> *relativeFontRoots = @[ @"fonts", @"Fonts", @"assets/fonts" ];
        for (NSString *relativePath in relativeFontRoots) {
            NativeSdkRegisterFontsInDirectory([root stringByAppendingPathComponent:relativePath]);
        }
    });
}

static BOOL NativeSdkPathHasUnsafeSegment(NSString *path) {
    for (NSString *segment in [path componentsSeparatedByString:@"/"]) {
        if (segment.length == 0) continue;
        if ([segment isEqualToString:@"."] || [segment isEqualToString:@".."]) return YES;
        if ([segment containsString:@"\\"]) return YES;
    }
    return NO;
}

static NSString *NativeSdkSafeAssetPath(NSURL *url, NSString *entryPath) {
    if (!url) return nil;
    NSString *path = url.path.stringByRemovingPercentEncoding ?: url.path;
    if (path.length == 0 || [path isEqualToString:@"/"]) return entryPath.length > 0 ? entryPath : @"index.html";
    while ([path hasPrefix:@"/"]) {
        path = [path substringFromIndex:1];
    }
    if (path.length == 0) return entryPath.length > 0 ? entryPath : @"index.html";
    if (NativeSdkPathHasUnsafeSegment(path)) return nil;
    return path;
}

static NSURL *NativeSdkAssetEntryURL(NSString *origin, NSString *entryPath) {
    NSString *base = origin.length > 0 ? origin : @"zero://app";
    while ([base hasSuffix:@"/"]) {
        base = [base substringToIndex:base.length - 1];
    }
    NSString *entry = entryPath.length > 0 ? entryPath : @"index.html";
    while ([entry hasPrefix:@"/"]) {
        entry = [entry substringFromIndex:1];
    }
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@", base, entry]];
}

/* Ask the process services layer to show the display name for this
 * process in the Dock tile and the app switcher. Unbundled dev binaries
 * otherwise show their executable name there — packaged bundles get the
 * name from Info.plist instead, so this is dev-run-only polish. The
 * call is a private services entry resolved at runtime; when the
 * symbols are absent the name simply stays the executable's.
 *
 * Hard macOS limit, for the record: the Dock hover label and the app
 * switcher read the LaunchServices registration, and a bundle-less
 * process has NO public API to rename that registration — Info.plist
 * is the only sanctioned channel, and it requires a bundle. What is
 * honestly settable without one: the application menu (the host builds
 * its own NSMenu titled with the display name, in buildMenuBar) and
 * NSProcessInfo's processName. Everything beyond that either follows
 * this best-effort services call or stays the executable name. */
static void NativeSdkApplyProcessDisplayName(NSString *displayName) {
    if (displayName.length == 0) return;
    if ([NSBundle.mainBundle.bundlePath.pathExtension.lowercaseString isEqualToString:@"app"]) return;
    typedef CFTypeRef (*NativeSdkCurrentASNFn)(void);
    typedef OSStatus (*NativeSdkSetInfoItemFn)(int, CFTypeRef, CFStringRef, CFStringRef, CFDictionaryRef *);
    NativeSdkCurrentASNFn currentASN = (NativeSdkCurrentASNFn)dlsym(RTLD_DEFAULT, "_LSGetCurrentApplicationASN");
    NativeSdkSetInfoItemFn setInfoItem = (NativeSdkSetInfoItemFn)dlsym(RTLD_DEFAULT, "_LSSetApplicationInformationItem");
    CFStringRef *displayNameKey = (CFStringRef *)dlsym(RTLD_DEFAULT, "_kLSDisplayNameKey");
    if (!currentASN || !setInfoItem) return;
    CFTypeRef asn = currentASN();
    if (!asn) return;
    CFStringRef key = (displayNameKey && *displayNameKey) ? *displayNameKey : CFSTR("LSDisplayName");
    (void)setInfoItem(-2 /* current session */, asn, key, (__bridge CFStringRef)displayName, NULL);
}

- (void)configureApplication {
    [[NSProcessInfo processInfo] setProcessName:self.displayName];
    NativeSdkApplyProcessDisplayName(self.displayName);
    [self buildMenuBar];
    NativeSdkLaunchLap("menu_built");
    [self loadDockIconFromFile:self.iconPath];
}

/* Decode a Dock icon file off the launch path: the synchronous .icns
 * read+decode cost ~25 ms of launch-to-glass. The dock tile updates a
 * few frames after launch instead — imperceptible, and identical when
 * the file is missing (no icon either way). Shared by the manifest
 * path (configureApplication) and the Debug dev-run fallback for when
 * the pre-masked render is unavailable. */
- (void)loadDockIconFromFile:(NSString *)iconPath {
    if (iconPath.length == 0) return;
    __weak NativeSdkAppKitHost *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSImage *icon = [[NSImage alloc] initWithContentsOfFile:iconPath];
        if (!icon) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf adoptDockIcon:icon];
        });
    });
}

/* Main-thread Dock icon adoption: the Dock/app-switcher tile and the
 * About panel copy (unbundled binaries have no bundle icon for the
 * standard panel to find, so it is retained on the host explicitly). */
- (void)adoptDockIcon:(NSImage *)icon {
    if (!icon) return;
    self.appIcon = icon;
    [NSApp setApplicationIconImage:icon];
}

- (void)buildMenuBar {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];
    [NSApp setMainMenu:mainMenu];
    [self addApplicationMenuToMenu:mainMenu];

    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
    [mainMenu addItem:fileMenuItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenuItem setSubmenu:fileMenu];
    [fileMenu addItem:[self menuItem:@"Close Window" action:@selector(performClose:) key:@"w" modifiers:NSEventModifierFlagCommand]];

    NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
    [mainMenu addItem:editMenuItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenuItem setSubmenu:editMenu];
    if (self.hasWebContent) {
        // Undo/Redo answer only inside web content (the webview's own
        // editing stack); the canvas text editor has no undo stack, so
        // canvas-only apps do not show items nothing can perform.
        [editMenu addItem:[self menuItem:@"Undo" action:@selector(undo:) key:@"z" modifiers:NSEventModifierFlagCommand]];
        [editMenu addItem:[self menuItem:@"Redo" action:@selector(redo:) key:@"Z" modifiers:NSEventModifierFlagCommand]];
        [editMenu addItem:[NSMenuItem separatorItem]];
    }
    [editMenu addItem:[self menuItem:@"Cut" action:@selector(cut:) key:@"x" modifiers:NSEventModifierFlagCommand]];
    [editMenu addItem:[self menuItem:@"Copy" action:@selector(copy:) key:@"c" modifiers:NSEventModifierFlagCommand]];
    [editMenu addItem:[self menuItem:@"Paste" action:@selector(paste:) key:@"v" modifiers:NSEventModifierFlagCommand]];
    [editMenu addItem:[self menuItem:@"Select All" action:@selector(selectAll:) key:@"a" modifiers:NSEventModifierFlagCommand]];

    // The View menu carries web items only when the manifest declares
    // web content — in a canvas-only app Reload and the inspector have
    // no webview to act on, so the items do not exist. Enter Full
    // Screen is real for every window shape.
    NSMenuItem *viewMenuItem = [[NSMenuItem alloc] initWithTitle:@"View" action:nil keyEquivalent:@""];
    [mainMenu addItem:viewMenuItem];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    [viewMenuItem setSubmenu:viewMenu];
    if (self.hasWebContent) {
        [viewMenu addItem:[self menuItem:@"Reload" action:@selector(reload:) key:@"r" modifiers:NSEventModifierFlagCommand]];
        [viewMenu addItem:[self menuItem:@"Toggle Web Inspector" action:@selector(toggleWebInspector:) key:@"i" modifiers:(NSEventModifierFlagCommand | NSEventModifierFlagOption)]];
        [viewMenu addItem:[NSMenuItem separatorItem]];
    }
    [viewMenu addItem:[self menuItem:@"Enter Full Screen" action:@selector(toggleFullScreen:) key:@"f" modifiers:(NSEventModifierFlagCommand | NSEventModifierFlagControl)]];

    // A real Window menu: Minimize/Zoom act through the responder
    // chain, and registering it as NSApp.windowsMenu lets the system
    // append the open-window list (and its own tiling section) to it.
    NSMenuItem *windowMenuItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""];
    [mainMenu addItem:windowMenuItem];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenuItem setSubmenu:windowMenu];
    [windowMenu addItem:[self menuItem:@"Minimize" action:@selector(performMiniaturize:) key:@"m" modifiers:NSEventModifierFlagCommand]];
    [windowMenu addItem:[self menuItem:@"Zoom" action:@selector(performZoom:) key:@"" modifiers:0]];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItem:[self menuItem:@"Bring All to Front" action:@selector(arrangeInFront:) key:@"" modifiers:0]];
    [NSApp setWindowsMenu:windowMenu];
}

- (void)addApplicationMenuToMenu:(NSMenu *)mainMenu {
    // Every string the application menu derives — the bold menu-bar
    // title and the About/Hide/Quit labels — reads from the one display
    // name, never the binary name. No Settings item: the host has no
    // settings surface to open, and a dead item is worse than none
    // (apps add their own through custom menus when they grow one).
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:self.displayName action:nil keyEquivalent:@""];
    [mainMenu addItem:appMenuItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:self.displayName];
    [appMenuItem setSubmenu:appMenu];
    [appMenu addItem:[self menuItem:[NSString stringWithFormat:@"About %@", self.displayName] action:@selector(showAboutPanel:) key:@"" modifiers:0]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:[self menuItem:[NSString stringWithFormat:@"Hide %@", self.displayName] action:@selector(hide:) key:@"h" modifiers:NSEventModifierFlagCommand]];
    [appMenu addItem:[self menuItem:@"Hide Others" action:@selector(hideOtherApplications:) key:@"h" modifiers:(NSEventModifierFlagCommand | NSEventModifierFlagOption)]];
    [appMenu addItem:[self menuItem:@"Show All" action:@selector(unhideAllApplications:) key:@"" modifiers:0]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:[self menuItem:[NSString stringWithFormat:@"Quit %@", self.displayName] action:@selector(terminate:) key:@"q" modifiers:NSEventModifierFlagCommand]];
}

- (NSMenuItem *)menuItem:(NSString *)title action:(SEL)action key:(NSString *)key modifiers:(NSEventModifierFlags)modifiers {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key ?: @""];
    item.keyEquivalentModifierMask = modifiers;
    if ([self respondsToSelector:action]) {
        item.target = self;
    }
    return item;
}

- (NSMenuItem *)commandMenuItem:(NSString *)title command:(NSString *)command key:(NSString *)key modifiers:(uint32_t)modifiers enabled:(BOOL)enabled checked:(BOOL)checked {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title ?: @"" action:@selector(menuCommandItemClicked:) keyEquivalent:key ?: @""];
    item.target = self;
    item.enabled = enabled;
    item.representedObject = command ?: @"";
    item.keyEquivalentModifierMask = NativeSdkMenuModifierFlags(modifiers);
    item.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
    return item;
}

- (uint64_t)activeCommandWindowId {
    NSWindow *activeWindow = NSApp.keyWindow ?: self.window;
    for (NSNumber *key in self.windows) {
        if (self.windows[key] == activeWindow) return key.unsignedLongLongValue;
    }
    return 1;
}

- (void)menuCommandItemClicked:(NSMenuItem *)menuItem {
    NSString *command = [menuItem.representedObject isKindOfClass:[NSString class]] ? (NSString *)menuItem.representedObject : @"";
    if (command.length == 0) return;
    const char *commandBytes = [command UTF8String];
    [self emitEvent:(native_sdk_appkit_event_t){
        .kind = NATIVE_SDK_APPKIT_EVENT_MENU_COMMAND,
        .window_id = [self activeCommandWindowId],
        .command_name = commandBytes,
        .command_name_len = [command lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
    }];
}

- (void)setMenusWithTitles:(const char *const *)menuTitles titleLengths:(const size_t *)menuTitleLengths count:(size_t)menuCount itemMenuIndices:(const uint32_t *)itemMenuIndices itemLabels:(const char *const *)itemLabels itemLabelLengths:(const size_t *)itemLabelLengths itemCommands:(const char *const *)itemCommands itemCommandLengths:(const size_t *)itemCommandLengths itemKeys:(const char *const *)itemKeys itemKeyLengths:(const size_t *)itemKeyLengths itemModifiers:(const uint32_t *)itemModifiers itemSeparators:(const int *)itemSeparators itemEnabled:(const int *)itemEnabled itemChecked:(const int *)itemChecked itemCount:(size_t)itemCount {
    if (menuCount == 0) {
        [self buildMenuBar];
        return;
    }

    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];
    [NSApp setMainMenu:mainMenu];
    [self addApplicationMenuToMenu:mainMenu];

    for (size_t menuIndex = 0; menuIndex < menuCount; menuIndex++) {
        NSString *title = [[NSString alloc] initWithBytes:menuTitles[menuIndex] length:menuTitleLengths[menuIndex] encoding:NSUTF8StringEncoding] ?: @"";
        NSMenuItem *topItem = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        [mainMenu addItem:topItem];
        NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
        [topItem setSubmenu:menu];

        for (size_t itemIndex = 0; itemIndex < itemCount; itemIndex++) {
            if (itemMenuIndices[itemIndex] != menuIndex) continue;
            if (itemSeparators[itemIndex]) {
                [menu addItem:[NSMenuItem separatorItem]];
                continue;
            }
            NSString *label = [[NSString alloc] initWithBytes:itemLabels[itemIndex] length:itemLabelLengths[itemIndex] encoding:NSUTF8StringEncoding] ?: @"";
            NSString *command = [[NSString alloc] initWithBytes:itemCommands[itemIndex] length:itemCommandLengths[itemIndex] encoding:NSUTF8StringEncoding] ?: @"";
            NSString *key = [[NSString alloc] initWithBytes:itemKeys[itemIndex] length:itemKeyLengths[itemIndex] encoding:NSUTF8StringEncoding] ?: @"";
            [menu addItem:[self commandMenuItem:label command:command key:key modifiers:itemModifiers[itemIndex] enabled:(itemEnabled[itemIndex] != 0) checked:(itemChecked[itemIndex] != 0)]];
        }
    }
}

- (void)runWithCallback:(native_sdk_appkit_event_callback_t)callback context:(void *)context {
    self.callback = callback;
    self.context = context;

    // Present-before-show: a deferred startup window stays ordered out
    // here and appears when its first canvas present lands (or the
    // create-time fallback deadline fires).
    if (!self.deferredShowWindows[@1]) {
        [self.window makeKeyAndOrderFront:nil];
    }
    [NSApp activate];
    if (!self.shortcutEventMonitor) {
        __weak NativeSdkAppKitHost *weakSelf = self;
        self.shortcutEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
            NativeSdkAppKitHost *strongSelf = weakSelf;
            if (!strongSelf) return event;
            // An adopted surface with the keyboard (a VM display) gets raw
            // keys; app shortcuts resume when focus returns to app chrome.
            NSResponder *first = event.window.firstResponder;
            if ([first isKindOfClass:[NSView class]] && [strongSelf viewIsAdoptedSurfaceDescendant:(NSView *)first]) return event;
            if ([strongSelf handleShortcutEvent:event]) return nil;
            return event;
        }];
    }

    [self startApplicationActivationObservers];
    [self startAppearanceObservers];

    [self emitEvent:(native_sdk_appkit_event_t){ .kind = NATIVE_SDK_APPKIT_EVENT_START }];
    // A failed START handler requests shutdown synchronously, before the
    // run loop exists — [NSApp stop:] is a no-op there. Honor the request
    // here instead of stranding a live app behind a blank window.
    if (self.didShutdown) return;
    [self emitAppearanceChanged];
    [self emitResize];
    [self emitWindowFrame:YES];

    // First canvas frame, synchronously: a canvas-first startup window's
    // first frame request was queued during the START dispatch above and
    // would otherwise wait for [NSApp run]'s first queue pump. Emitting
    // it here puts first content on the glass before the run loop even
    // starts.
    for (NSView *view in self.nativeViews.allValues) {
        if ([view isKindOfClass:[NativeSdkMetalSurfaceView class]]) {
            [(NativeSdkMetalSurfaceView *)view flushQueuedFirstCanvasFrameRequestNow];
        }
    }

    // Terminations that bypass the host's own stop path — cmd+Q's
    // default NSApp terminate, an AppleScript quit — must still deliver
    // the shutdown event synchronously before the process exits: the
    // runtime's app.stop hook and the session recorder's journal seal
    // both hang off it (an unsealed journal is refused by replay as
    // truncated).
    __weak NativeSdkAppKitHost *weakSelf = self;
    self.willTerminateObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationWillTerminateNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                    (void)note;
                    [weakSelf emitShutdown];
                }];
    // SIGTERM becomes a graceful quit (dispatch source, never a raw
    // signal handler): drivers that stop a recorded app with `kill`
    // get the same sealed journal a menu quit produces.
    signal(SIGTERM, SIG_IGN);
    dispatch_source_t sigterm_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(sigterm_source, ^{
        [NSApp terminate:nil];
    });
    dispatch_activate(sigterm_source);
    self.sigtermSource = sigterm_source;

    [self scheduleFrame];
    [NSApp run];
}

- (void)stop {
    if (self.willTerminateObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.willTerminateObserver];
        self.willTerminateObserver = nil;
    }
    if (self.sigtermSource) {
        dispatch_source_cancel(self.sigtermSource);
        self.sigtermSource = nil;
    }
    [self.timer invalidate];
    self.timer = nil;
    [self invalidateAppTimers];
    [self audioStop];
    if (self.shortcutEventMonitor) {
        [NSEvent removeMonitor:self.shortcutEventMonitor];
        self.shortcutEventMonitor = nil;
    }
    [self stopAppearanceObservers];
    [self stopApplicationActivationObservers];
    [NSApp stop:nil];
    NSEvent *event = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                        location:NSZeroPoint
                                   modifierFlags:0
                                       timestamp:0
                                    windowNumber:0
                                         context:nil
                                         subtype:0
                                           data1:0
                                           data2:0];
    [NSApp postEvent:event atStart:NO];
}

- (void)emitEvent:(native_sdk_appkit_event_t)event {
    if (self.callback) {
        self.callback(self.context, &event);
    }
}

- (void)startApplicationActivationObservers {
    if (self.observesApplicationActivation) {
        return;
    }
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(applicationDidBecomeActive:) name:NSApplicationDidBecomeActiveNotification object:NSApp];
    [center addObserver:self selector:@selector(applicationDidResignActive:) name:NSApplicationDidResignActiveNotification object:NSApp];
    self.observesApplicationActivation = YES;
}

- (void)stopApplicationActivationObservers {
    if (!self.observesApplicationActivation) {
        return;
    }
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:self name:NSApplicationDidBecomeActiveNotification object:NSApp];
    [center removeObserver:self name:NSApplicationDidResignActiveNotification object:NSApp];
    self.observesApplicationActivation = NO;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    [self emitEvent:(native_sdk_appkit_event_t){ .kind = NATIVE_SDK_APPKIT_EVENT_APP_ACTIVATED }];
}

- (void)applicationDidResignActive:(NSNotification *)notification {
    (void)notification;
    [self emitEvent:(native_sdk_appkit_event_t){ .kind = NATIVE_SDK_APPKIT_EVENT_APP_DEACTIVATED }];
}

- (void)startAppearanceObservers {
    if (self.observesAppearanceChanges) {
        return;
    }
    [NSApp addObserver:self forKeyPath:@"effectiveAppearance" options:NSKeyValueObservingOptionNew context:NativeSdkAppKitAppearanceObservationContext];
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                           selector:@selector(accessibilityDisplayOptionsDidChange:)
                                                               name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
                                                             object:nil];
    self.observesAppearanceChanges = YES;
}

- (void)stopAppearanceObservers {
    if (!self.observesAppearanceChanges) {
        return;
    }
    [NSApp removeObserver:self forKeyPath:@"effectiveAppearance" context:NativeSdkAppKitAppearanceObservationContext];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self
                                                                  name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
                                                                object:nil];
    self.observesAppearanceChanges = NO;
}

- (void)accessibilityDisplayOptionsDidChange:(NSNotification *)notification {
    (void)notification;
    [self emitAppearanceChanged];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    (void)keyPath;
    (void)object;
    (void)change;
    if (context == NativeSdkAppKitAppearanceObservationContext) {
        [self emitAppearanceChanged];
        return;
    }
    /* AVPlayer/AVPlayerItem KVO can fire on background threads; every
     * audio entry point is loop-thread only, so hop before touching
     * player state or emitting. */
    if (context == NativeSdkAppKitAudioItemStatusContext) {
        __weak NativeSdkAppKitHost *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf audioItemStatusChanged];
        });
        return;
    }
    if (context == NativeSdkAppKitAudioTimeControlContext) {
        __weak NativeSdkAppKitHost *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf audioTimeControlChanged];
        });
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)emitAppearanceChanged {
    [self emitEvent:(native_sdk_appkit_event_t){
        .kind = NATIVE_SDK_APPKIT_EVENT_APPEARANCE_CHANGED,
        .color_scheme = NativeSdkAppKitColorSchemeForAppearance(NSApp.effectiveAppearance),
        .reduce_motion = NativeSdkAppKitReduceMotionEnabled() ? 1 : 0,
        .high_contrast = NativeSdkAppKitHighContrastEnabled() ? 1 : 0,
    }];
}

- (void)emitResize {
    [self emitResizeForWindowId:1];
}

- (void)emitResizeForWindowId:(uint64_t)windowId {
    NSWindow *window = self.windows[@(windowId)] ?: self.window;
    NSRect bounds = window.contentView.bounds;
    [self emitEvent:(native_sdk_appkit_event_t){
        .kind = NATIVE_SDK_APPKIT_EVENT_RESIZE,
        .window_id = windowId,
        .width = bounds.size.width,
        .height = bounds.size.height,
        .scale = window.backingScaleFactor,
    }];
}

- (void)emitDeferredResizeForWindowId:(uint64_t)windowId {
    __weak NativeSdkAppKitHost *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NativeSdkAppKitHost *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.windows[@(windowId)]) return;
        [strongSelf emitWindowFrameForWindowId:windowId open:YES];
        [strongSelf emitResizeForWindowId:windowId];
        [strongSelf scheduleFrame];
    });
}

- (void)emitWindowFrame:(BOOL)open {
    [self emitWindowFrameForWindowId:1 open:open];
}

- (void)emitWindowFrameForWindowId:(uint64_t)windowId open:(BOOL)open {
    NSWindow *window = self.windows[@(windowId)] ?: self.window;
    NSString *label = self.windowLabels[@(windowId)] ?: (windowId == 1 ? self.windowLabel : @"");
    NSRect frame = window.frame;
    [self emitEvent:(native_sdk_appkit_event_t){
        .kind = NATIVE_SDK_APPKIT_EVENT_WINDOW_FRAME,
        .window_id = windowId,
        .x = frame.origin.x,
        .y = frame.origin.y,
        .width = frame.size.width,
        .height = frame.size.height,
        .scale = window.backingScaleFactor,
        .open = open ? 1 : 0,
        .focused = window.isKeyWindow ? 1 : 0,
        .label = label.UTF8String,
        .label_len = [label lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
    }];
}

- (void)scheduleFrame {
    if (self.timer) return;
    // Common modes so frames keep pumping during live resize and menu
    // tracking (default-mode timers do not fire in tracking runloops).
    NSTimer *frame_timer = [NSTimer timerWithTimeInterval:(1.0 / 60.0)
                                                   target:self
                                                 selector:@selector(emitFrame)
                                                 userInfo:nil
                                                  repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:frame_timer forMode:NSRunLoopCommonModes];
    self.timer = frame_timer;
}

/* Called from any thread: marshal onto the main queue and emit ONE FRAME
 * event there. This is the automation arrival watcher's wake — a command
 * landing in the dropbox produces the frame that drains it, instead of
 * the app waiting for an unrelated frame source. Deliberately timer-free
 * (unlike scheduleFrame's 1/60 s one-shot): a queued main-queue block is
 * delivered promptly even when the app is backgrounded/occluded and the
 * OS is coalescing its timers, which is exactly the state a driver-run
 * app idles in. */
- (void)requestFrameFromAnyThread {
    if (self.crossThreadFramePending) return;
    self.crossThreadFramePending = YES;
    __weak NativeSdkAppKitHost *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NativeSdkAppKitHost *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.crossThreadFramePending = NO;
        if (strongSelf.didShutdown) return;
        [strongSelf emitEvent:(native_sdk_appkit_event_t){ .kind = NATIVE_SDK_APPKIT_EVENT_FRAME }];
    });
}

/* Called from any thread: marshal onto the main queue and emit the WAKE
 * event there, so the runtime's effect-queue drain always runs on the
 * loop thread. */
- (void)wakeFromAnyThread {
    __weak NativeSdkAppKitHost *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NativeSdkAppKitHost *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.didShutdown) return;
        [strongSelf emitEvent:(native_sdk_appkit_event_t){
            .kind = NATIVE_SDK_APPKIT_EVENT_WAKE,
            .timestamp_ns = NativeSdkTimestampNanoseconds(),
        }];
    });
}

- (void)startAppTimerWithId:(uint64_t)timerId intervalNs:(uint64_t)intervalNs repeats:(BOOL)repeats {
    NSNumber *key = @(timerId);
    [self.appTimers[key] invalidate];
    NSTimeInterval interval = (NSTimeInterval)intervalNs / (NSTimeInterval)NativeSdkNanosecondsPerSecond;
    // Common modes: an app's fx timer (a live sampler, a debounce) must
    // fire while the user holds a menu open or live-resizes the window.
    NSTimer *app_timer = [NSTimer timerWithTimeInterval:interval
                                                 target:self
                                               selector:@selector(appTimerFired:)
                                               userInfo:@{ @"id": key, @"repeats": @(repeats) }
                                                repeats:repeats];
    [[NSRunLoop mainRunLoop] addTimer:app_timer forMode:NSRunLoopCommonModes];
    self.appTimers[key] = app_timer;
}

- (void)cancelAppTimerWithId:(uint64_t)timerId {
    NSNumber *key = @(timerId);
    [self.appTimers[key] invalidate];
    [self.appTimers removeObjectForKey:key];
}

- (void)appTimerFired:(NSTimer *)timer {
    NSDictionary *info = (NSDictionary *)timer.userInfo;
    NSNumber *key = info[@"id"];
    if (!key) return;
    // A non-repeating timer invalidates itself after this fire; drop the
    // bookkeeping entry before the callback so it may start a replacement
    // timer with the same id.
    if (![info[@"repeats"] boolValue] && self.appTimers[key] == timer) {
        [self.appTimers removeObjectForKey:key];
    }
    [self emitEvent:(native_sdk_appkit_event_t){
        .kind = NATIVE_SDK_APPKIT_EVENT_TIMER,
        .timer_id = key.unsignedLongLongValue,
        .timestamp_ns = NativeSdkTimestampNanoseconds(),
    }];
}

- (void)invalidateAppTimers {
    for (NSTimer *timer in self.appTimers.allValues) {
        [timer invalidate];
    }
    [self.appTimers removeAllObjects];
}

/* CMTime arithmetic by hand, on purpose: CMTimeGetSeconds and friends
 * are exported by CoreMedia, and linking CoreMedia would have to ripple
 * through every example's explicit framework list for two one-line
 * conversions. The struct and its flag constants are header-only, so
 * reading value/timescale directly keeps the link set unchanged. */
static double NativeSdkSecondsFromCMTime(CMTime time) {
    if ((time.flags & kCMTimeFlags_Valid) == 0) return 0.0;
    if ((time.flags & (kCMTimeFlags_Indefinite | kCMTimeFlags_PositiveInfinity | kCMTimeFlags_NegativeInfinity)) != 0) return 0.0;
    if (time.timescale == 0) return 0.0;
    return (double)time.value / (double)time.timescale;
}

static CMTime NativeSdkCMTimeFromMs(uint64_t ms) {
    CMTime time;
    time.value = (CMTimeValue)ms;
    time.timescale = 1000;
    time.flags = kCMTimeFlags_Valid;
    time.epoch = 0;
    return time;
}

/* ---------------------------------------------------- spectrum tap
 *
 * Real spectrum analysis of the app's own playback: an
 * MTAudioProcessingTap on the single AVPlayer's audio mix hands every
 * rendered PCM buffer to the host, a render-thread-safe mono ring
 * buffer carries the samples to the loop thread, and a 40 ms timer
 * (the SPECTRUM cadence, ~25 Hz) runs a vDSP FFT over the freshest
 * window and folds the bins into the 32 documented bands (log-spaced
 * 50 Hz..16 kHz; each byte linear-in-dB from -60 dBFS to full scale).
 * The tap sits PRE-effects, so the bands describe the decoded signal —
 * the track itself — not the app's volume fader.
 *
 * Threading: the process callback runs on CoreAudio's render thread
 * and must never touch ObjC or block, so it only downmixes into the
 * ring and bumps an atomic write counter. The loop-thread reader copies
 * the last FFT window by that counter; the writer could only overwrite
 * bytes under the copy after producing RING-FFT_SIZE further samples
 * (tens of milliseconds of audio) inside a microseconds-long memcpy,
 * so a torn window is not a real case — and the worst outcome would be
 * one blended visualization frame, not corrupted state. */

#define NATIVE_SDK_SPECTRUM_FFT_SIZE 2048
#define NATIVE_SDK_SPECTRUM_FFT_LOG2 11
#define NATIVE_SDK_SPECTRUM_RING_SIZE 8192
#define NATIVE_SDK_SPECTRUM_INTERVAL_SECONDS 0.04
#define NATIVE_SDK_SPECTRUM_FLOOR_DB (-60.0f)
#define NATIVE_SDK_SPECTRUM_LOW_HZ 50.0
#define NATIVE_SDK_SPECTRUM_HIGH_HZ 16000.0

struct native_sdk_spectrum_tap_state {
    float ring[NATIVE_SDK_SPECTRUM_RING_SIZE];
    /* Total mono samples ever written; the ring index is written %
     * RING_SIZE. Release-published by the render thread, acquired by
     * the loop-thread reader. */
    _Atomic uint64_t written;
    /* From the tap's prepare callback: the processing format the
     * process callback will see. */
    _Atomic double sample_rate;
    _Atomic int channels;
    _Atomic int interleaved;
};

static void NativeSdkSpectrumTapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    (void)tap;
    *tapStorageOut = clientInfo;
}

/* The tap owns its state's lifetime end: finalize runs once the mix
 * and every render-thread user are done with the tap, which is the
 * only moment the buffer is provably unreachable. The host clears its
 * own pointer BEFORE releasing the tap (same thread as the reader), so
 * nothing reads after free. */
static void NativeSdkSpectrumTapFinalize(MTAudioProcessingTapRef tap) {
    free(MTAudioProcessingTapGetStorage(tap));
}

static void NativeSdkSpectrumTapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *format) {
    (void)maxFrames;
    native_sdk_spectrum_tap_state_t *state = MTAudioProcessingTapGetStorage(tap);
    atomic_store(&state->sample_rate, format->mSampleRate);
    atomic_store(&state->channels, (int)format->mChannelsPerFrame);
    atomic_store(&state->interleaved, (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 0 : 1);
}

static void NativeSdkSpectrumTapUnprepare(MTAudioProcessingTapRef tap) {
    (void)tap;
}

static void NativeSdkSpectrumTapProcess(MTAudioProcessingTapRef tap, CMItemCount numberFrames, MTAudioProcessingTapFlags flags, AudioBufferList *bufferListInOut, CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *flagsOut) {
    (void)flags;
    if (MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, NULL, numberFramesOut) != noErr) return;
    native_sdk_spectrum_tap_state_t *state = MTAudioProcessingTapGetStorage(tap);
    const int channels = atomic_load(&state->channels);
    const int interleaved = atomic_load(&state->interleaved);
    if (channels <= 0 || bufferListInOut->mNumberBuffers == 0) return;
    uint64_t written = atomic_load_explicit(&state->written, memory_order_relaxed);
    const CMItemCount frames = *numberFramesOut;
    for (CMItemCount frame = 0; frame < frames; frame += 1) {
        float sum = 0.0f;
        if (interleaved) {
            const float *samples = (const float *)bufferListInOut->mBuffers[0].mData;
            if (!samples) return;
            for (int channel = 0; channel < channels; channel += 1) {
                sum += samples[frame * channels + channel];
            }
        } else {
            const UInt32 buffers = bufferListInOut->mNumberBuffers;
            for (UInt32 buffer = 0; buffer < buffers; buffer += 1) {
                const float *samples = (const float *)bufferListInOut->mBuffers[buffer].mData;
                if (samples) sum += samples[frame];
            }
        }
        state->ring[written % NATIVE_SDK_SPECTRUM_RING_SIZE] = sum / (float)channels;
        written += 1;
    }
    atomic_store_explicit(&state->written, written, memory_order_release);
}

/* Fold the freshest FFT window into the 32 documented bands. Returns 0
 * when the ring has not yet seen a full window (bands untouched). The
 * dB reference: a full-scale sine (amplitude 1.0) lands at 0 dBFS —
 * with vDSP_fft_zrip's 2x packing and the Hann window's 0.5 coherent
 * gain, that sine's peak bin magnitude is N/2, so amplitude =
 * 2*sqrt(power)/N against zvmags' squared magnitudes. */
static int NativeSdkSpectrumComputeBands(native_sdk_spectrum_tap_state_t *state, FFTSetup fft, const float *window, uint8_t bands[NATIVE_SDK_APPKIT_AUDIO_SPECTRUM_BANDS]) {
    const uint64_t written = atomic_load_explicit(&state->written, memory_order_acquire);
    if (written < NATIVE_SDK_SPECTRUM_FFT_SIZE) return 0;
    const double sample_rate = atomic_load(&state->sample_rate);
    if (sample_rate <= 0) return 0;

    float samples[NATIVE_SDK_SPECTRUM_FFT_SIZE];
    const uint64_t start = written - NATIVE_SDK_SPECTRUM_FFT_SIZE;
    for (int index = 0; index < NATIVE_SDK_SPECTRUM_FFT_SIZE; index += 1) {
        samples[index] = state->ring[(start + index) % NATIVE_SDK_SPECTRUM_RING_SIZE];
    }
    vDSP_vmul(samples, 1, window, 1, samples, 1, NATIVE_SDK_SPECTRUM_FFT_SIZE);

    float real[NATIVE_SDK_SPECTRUM_FFT_SIZE / 2];
    float imag[NATIVE_SDK_SPECTRUM_FFT_SIZE / 2];
    DSPSplitComplex split = { .realp = real, .imagp = imag };
    vDSP_ctoz((const DSPComplex *)samples, 2, &split, 1, NATIVE_SDK_SPECTRUM_FFT_SIZE / 2);
    vDSP_fft_zrip(fft, &split, 1, NATIVE_SDK_SPECTRUM_FFT_LOG2, kFFTDirection_Forward);
    float power[NATIVE_SDK_SPECTRUM_FFT_SIZE / 2];
    vDSP_zvmags(&split, 1, power, 1, NATIVE_SDK_SPECTRUM_FFT_SIZE / 2);

    /* Log-spaced bucket edges over 50 Hz..16 kHz; per bucket the PEAK
     * bin, matching how a bar analyzer reads (an average would smear
     * narrow tones into invisibility). Bin 0 (DC) never contributes. */
    const double ratio = NATIVE_SDK_SPECTRUM_HIGH_HZ / NATIVE_SDK_SPECTRUM_LOW_HZ;
    const double hz_per_bin = sample_rate / (double)NATIVE_SDK_SPECTRUM_FFT_SIZE;
    for (int band = 0; band < NATIVE_SDK_APPKIT_AUDIO_SPECTRUM_BANDS; band += 1) {
        const double low_hz = NATIVE_SDK_SPECTRUM_LOW_HZ * pow(ratio, (double)band / NATIVE_SDK_APPKIT_AUDIO_SPECTRUM_BANDS);
        const double high_hz = NATIVE_SDK_SPECTRUM_LOW_HZ * pow(ratio, (double)(band + 1) / NATIVE_SDK_APPKIT_AUDIO_SPECTRUM_BANDS);
        int low_bin = (int)(low_hz / hz_per_bin);
        int high_bin = (int)ceil(high_hz / hz_per_bin);
        if (low_bin < 1) low_bin = 1;
        if (high_bin > NATIVE_SDK_SPECTRUM_FFT_SIZE / 2 - 1) high_bin = NATIVE_SDK_SPECTRUM_FFT_SIZE / 2 - 1;
        if (high_bin < low_bin) high_bin = low_bin;
        float peak = 0.0f;
        for (int bin = low_bin; bin <= high_bin; bin += 1) {
            if (power[bin] > peak) peak = power[bin];
        }
        const float amplitude = 2.0f * sqrtf(peak) / (float)NATIVE_SDK_SPECTRUM_FFT_SIZE;
        float db = amplitude > 0.0f ? 20.0f * log10f(amplitude) : NATIVE_SDK_SPECTRUM_FLOOR_DB;
        if (db < NATIVE_SDK_SPECTRUM_FLOOR_DB) db = NATIVE_SDK_SPECTRUM_FLOOR_DB;
        if (db > 0.0f) db = 0.0f;
        bands[band] = (uint8_t)lroundf((db - NATIVE_SDK_SPECTRUM_FLOOR_DB) / -NATIVE_SDK_SPECTRUM_FLOOR_DB * 255.0f);
    }
    return 1;
}

/* Emit one audio report carrying the live position/duration readout of
 * the app's single AVPlayer. Runs on the loop thread — every audio
 * entry point is loop-thread only; the player's KVO and notification
 * handlers hop to the main queue before landing here. */
- (void)emitAudioEventOfKind:(int)kind {
    AVPlayer *player = self.audioPlayer;
    uint64_t position_ms = 0;
    uint64_t duration_ms = 0;
    int playing = 0;
    int buffering = 0;
    if (player) {
        double position = NativeSdkSecondsFromCMTime(player.currentTime);
        double duration = self.audioItem ? NativeSdkSecondsFromCMTime(self.audioItem.duration) : 0.0;
        if (position > 0) position_ms = (uint64_t)llround(position * 1000.0);
        if (duration > 0) duration_ms = (uint64_t)llround(duration * 1000.0);
        /* rate > 0 is the transport intent (un-paused); the buffering
         * flag beside it says whether audio is actually coming out.
         * Local files never buffer — the flag is stream-only. */
        playing = player.rate > 0 ? 1 : 0;
        buffering = (!self.audioSourceIsLocal && self.audioBuffering) ? 1 : 0;
    }
    if (kind == NATIVE_SDK_APPKIT_AUDIO_EVENT_COMPLETED) {
        /* A finished player rewinds itself to zero; report the honest
         * terminal position instead. */
        position_ms = duration_ms;
        playing = 0;
        buffering = 0;
    }
    [self emitEvent:(native_sdk_appkit_event_t){
        .kind = NATIVE_SDK_APPKIT_EVENT_AUDIO,
        .audio_kind = kind,
        .audio_position_ms = position_ms,
        .audio_duration_ms = duration_ms,
        .audio_playing = playing,
        .audio_buffering = buffering,
        .timestamp_ns = NativeSdkTimestampNanoseconds(),
    }];
}

- (void)stopAudioPositionTimer {
    [self.audioPositionTimer invalidate];
    self.audioPositionTimer = nil;
}

- (void)audioPositionTimerFired:(NSTimer *)timer {
    if (!self.audioPlayer) {
        [self stopAudioPositionTimer];
        return;
    }
    [self emitAudioEventOfKind:NATIVE_SDK_APPKIT_AUDIO_EVENT_POSITION];
}

- (void)stopAudioSpectrumTimer {
    [self.audioSpectrumTimer invalidate];
    self.audioSpectrumTimer = nil;
}

/* Whether any of the host's windows currently reaches the glass: the
 * per-window NSWindowOcclusionStateVisible fact — the exact signal the
 * occluded frame heartbeat paces on — checked across the whole window
 * table, because a spectrum consumer may draw its bands in any of the
 * app's windows. Miniaturized windows, windows fully covered by other
 * apps, windows on inactive Spaces, and a hidden app all report
 * invisible; an empty table means nothing displays at all. Loop-thread
 * only, like every audio entry point. */
- (BOOL)anyHostWindowVisibleOnGlass {
    for (NSWindow *window in [self.windows objectEnumerator]) {
        if (window.occlusionState & NSWindowOcclusionStateVisible) return YES;
    }
    return NO;
}

/* One SPECTRUM report per 40 ms tick, and only when the analysis is
 * honestly live: a player, an un-paused transport, no buffering stall,
 * and a tap that has rendered RECENTLY. The render side delivers PCM
 * in bursts larger than one tick (ahead-of-time decode), so freshness
 * is a short grace window rather than per-tick: emits stay at the
 * steady ~25 Hz cadence between bursts, and a render that actually
 * stopped (a stall the transport has not reported, a route change)
 * goes quiet within a quarter second — never re-emitting yesterday's
 * window as if the music were still moving. Silence while playing is
 * a row of floor bytes, emitted: the cadence follows the transport,
 * the magnitudes tell the truth. */
- (void)audioSpectrumTimerFired:(NSTimer *)timer {
    (void)timer;
    AVPlayer *player = self.audioPlayer;
    native_sdk_spectrum_tap_state_t *state = self.audioSpectrumState;
    if (!player) {
        [self stopAudioSpectrumTimer];
        return;
    }
    /* The tap attaches asynchronously (the asset's track table loads
     * off-thread) and may never attach at all (no analyzable track):
     * tick idle until samples exist — honest absence, not an error. */
    if (!state) return;
    if (player.rate <= 0) return;
    if (!self.audioSourceIsLocal && self.audioBuffering) return;
    /* The occluded-emission rule: SPECTRUM bands describe a display.
     * While no host window reaches the glass (all minimized, fully
     * covered, or the app hidden — the same occlusion fact the occluded
     * frame heartbeat paces on), there is nothing the bands could
     * describe, so the tick parks HERE, before the FFT: no analysis is
     * computed for a report that will not be sent, no event wakes the
     * runtime's update loop, and the journal records the occluded
     * stretch as honest silence (replay shows exactly what a viewer
     * could have seen — nothing). The 40 ms cadence keeps ticking and
     * the render tap keeps filling its ring, so the first tick after a
     * reveal analyzes a fresh window immediately: the glass is honest
     * within one report. Position ticks are untouched — the transport
     * keeps telling the truth at its own cadence. */
    if (![self anyHostWindowVisibleOnGlass]) return;
    const uint64_t now_ns = NativeSdkTimestampNanoseconds();
    const uint64_t written = atomic_load_explicit(&state->written, memory_order_acquire);
    if (written < NATIVE_SDK_SPECTRUM_FFT_SIZE) return;
    if (written != self.audioSpectrumLastWritten) {
        self.audioSpectrumLastWritten = written;
        self.audioSpectrumFreshNs = now_ns;
    } else if (self.audioSpectrumFreshNs == 0 || now_ns - self.audioSpectrumFreshNs > 250000000ull) {
        return;
    }
    if (!self.audioSpectrumFft) {
        self.audioSpectrumFft = vDSP_create_fftsetup(NATIVE_SDK_SPECTRUM_FFT_LOG2, kFFTRadix2);
        if (!self.audioSpectrumFft) return;
    }
    /* The Hann window is a pure function of the FFT size; computed
     * once. DENORM is the textbook 0.5-0.5cos shape whose 0.5 coherent
     * gain the dB calibration in NativeSdkSpectrumComputeBands assumes. */
    static float window[NATIVE_SDK_SPECTRUM_FFT_SIZE];
    static dispatch_once_t window_once;
    dispatch_once(&window_once, ^{
        vDSP_hann_window(window, NATIVE_SDK_SPECTRUM_FFT_SIZE, vDSP_HANN_DENORM);
    });
    native_sdk_appkit_event_t event = {
        .kind = NATIVE_SDK_APPKIT_EVENT_AUDIO,
        .audio_kind = NATIVE_SDK_APPKIT_AUDIO_EVENT_SPECTRUM,
        .timestamp_ns = NativeSdkTimestampNanoseconds(),
    };
    if (!NativeSdkSpectrumComputeBands(state, self.audioSpectrumFft, window, event.audio_bands)) return;
    double position = NativeSdkSecondsFromCMTime(player.currentTime);
    double duration = self.audioItem ? NativeSdkSecondsFromCMTime(self.audioItem.duration) : 0.0;
    if (position > 0) event.audio_position_ms = (uint64_t)llround(position * 1000.0);
    if (duration > 0) event.audio_duration_ms = (uint64_t)llround(duration * 1000.0);
    event.audio_playing = 1;
    [self emitEvent:event];
}

/* Local files (plain paths and verified cache entries) on the SAME
 * AVPlayer streams use — one tappable path, so the SPECTRUM analysis
 * covers everything the player can play. AVAudioPlayer still serves
 * one job it does better: a synchronous decode verdict. AVPlayer only
 * discovers an undecodable file asynchronously, but this seam's
 * callers pin two behaviors on the synchronous answer — a corrupt
 * cache entry must be discarded and re-streamed HERE (audioLoadURL's
 * cache branch), and a plain local decode failure must refuse the
 * load without falling through to the URL — so a throwaway
 * AVAudioPlayer probes the file first (header decode, no playback,
 * discarded before return) and the proven verdict survives the player
 * unification. */
- (int)audioLoadPath:(NSString *)path {
    [self audioStop];
    /* Relative paths resolve against the bundle's Resources inside a
     * packaged .app (where the process cwd is meaningless — `open`
     * launches at /), and keep their cwd meaning everywhere else. */
    NSString *resolved = NativeSdkResolvedAssetFilePath(path);
    if (![[NSFileManager defaultManager] fileExistsAtPath:resolved]) return 1;
    NSError *error = nil;
    AVAudioPlayer *probe = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:resolved]
                                                                  error:&error];
    if (!probe || error) return 2;
    if (![probe prepareToPlay]) return 2;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:resolved] options:nil];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    [self audioInstallItem:item asset:asset localSource:YES];
    return 0;
}

/* URL sources: verified cache entry first (plays as a plain local
 * file, no network), then a progressive AVPlayer stream with a
 * parallel cache-filling download. Returns 1 for the cache hit, 0 for
 * a started stream, 2 when the URL cannot be parsed; everything
 * asynchronous — readiness, stalls, natural end, network death —
 * arrives as EVENT_AUDIO reports. */
- (int)audioLoadURL:(NSString *)urlString cachePath:(NSString *)cachePath expectedBytes:(uint64_t)expectedBytes {
    [self audioStop];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url || !url.scheme) return 2;
    if (cachePath.length > 0) {
        NSFileManager *manager = [NSFileManager defaultManager];
        NSDictionary *attributes = [manager attributesOfItemAtPath:cachePath error:nil];
        if (attributes) {
            unsigned long long size = [attributes fileSize];
            if (expectedBytes == 0 || size == (unsigned long long)expectedBytes) {
                if ([self audioLoadPath:cachePath] == 0) return 1;
                /* An entry with the right size that will not decode is
                 * corrupt — fall through to discard and re-stream. */
            }
            /* Partial, stale, or corrupt: a bad cache entry never
             * plays, and never survives to fool the next lookup. */
            [manager removeItemAtPath:cachePath error:nil];
        }
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    [self audioInstallItem:item asset:asset localSource:NO];
    if (cachePath.length > 0) {
        [self startAudioCacheDownloadFrom:url toPath:cachePath expectedBytes:expectedBytes];
    }
    return 0;
}

/* Shared install for both sources: the single AVPlayer, its status and
 * time-control observers, the end/failure notifications, and the
 * spectrum tap. The LOADED acknowledgment stays asynchronous by
 * contract (readyToPlay KVO -> audioItemStatusChanged): emitting inside
 * the service call would re-enter the runtime while it is still
 * dispatching the command that asked for the load. */
- (void)audioInstallItem:(AVPlayerItem *)item asset:(AVURLAsset *)asset localSource:(BOOL)localSource {
    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    /* Stall policy by source: a local file has all its bytes, so
     * playback starts immediately; a stream keeps the default — start
     * as soon as sustained playback is likely, roll through short gaps.
     * Stated explicitly because immediate progressive start is the
     * contract for streams. */
    player.automaticallyWaitsToMinimizeStalling = localSource ? NO : YES;
    self.audioItem = item;
    self.audioPlayer = player;
    self.audioSourceIsLocal = localSource;
    /* A stream starts with no bytes; a local file never buffers. */
    self.audioBuffering = localSource ? NO : YES;
    self.audioLoadedEmitted = NO;
    [item addObserver:self
           forKeyPath:@"status"
              options:NSKeyValueObservingOptionNew
              context:NativeSdkAppKitAudioItemStatusContext];
    [player addObserver:self
             forKeyPath:@"timeControlStatus"
                options:NSKeyValueObservingOptionNew
                context:NativeSdkAppKitAudioTimeControlContext];
    self.audioObservingStatus = YES;
    __weak NativeSdkAppKitHost *weakSelf = self;
    self.audioEndObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                    object:item
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                    (void)note;
                    [weakSelf audioDidPlayToEnd];
                }];
    self.audioFailObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification
                    object:item
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                    (void)note;
                    [weakSelf audioDidFail];
                }];
    [self audioInstallSpectrumTapForItem:item asset:asset];
}

/* Attach the MTAudioProcessingTap once the asset's tracks are known —
 * the audio mix needs the real audio track, and a remote asset loads
 * its track table asynchronously. Failure at any step means NO
 * spectrum for this playback (the resting-glass degrade downstream),
 * never a playback failure: analysis is additive. */
- (void)audioInstallSpectrumTapForItem:(AVPlayerItem *)item asset:(AVURLAsset *)asset {
    __weak NativeSdkAppKitHost *weakSelf = self;
    [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ] completionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            NativeSdkAppKitHost *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.didShutdown) return;
            /* A replaced or stopped playback loads no tap: the item is
             * no longer the player's. */
            if (strongSelf.audioItem != item) return;
            if ([asset statusOfValueForKey:@"tracks" error:NULL] != AVKeyValueStatusLoaded) return;
            NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
            if (tracks.count == 0) return;
            native_sdk_spectrum_tap_state_t *state = calloc(1, sizeof(*state));
            if (!state) return;
            MTAudioProcessingTapCallbacks callbacks = {
                .version = kMTAudioProcessingTapCallbacksVersion_0,
                .clientInfo = state,
                .init = NativeSdkSpectrumTapInit,
                .finalize = NativeSdkSpectrumTapFinalize,
                .prepare = NativeSdkSpectrumTapPrepare,
                .unprepare = NativeSdkSpectrumTapUnprepare,
                .process = NativeSdkSpectrumTapProcess,
            };
            MTAudioProcessingTapRef tap = NULL;
            if (MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap) != noErr || !tap) {
                /* The tap never took ownership; the state is still ours
                 * to free. */
                free(state);
                return;
            }
            AVMutableAudioMixInputParameters *parameters = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:tracks.firstObject];
            parameters.audioTapProcessor = tap;
            AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
            mix.inputParameters = @[ parameters ];
            item.audioMix = mix;
            strongSelf.audioSpectrumTap = tap;
            strongSelf.audioSpectrumState = state;
            strongSelf.audioSpectrumLastWritten = 0;
            strongSelf.audioSpectrumFreshNs = 0;
        });
    }];
}

/* The cache fill is a PARALLEL download, not a tee off the player's
 * own connection: an AVAssetResourceLoader tee needs a custom URL
 * scheme plus a hand-rolled range-request server between AVPlayer and
 * the network, and a partially buffered stream must never masquerade
 * as a cache entry. One extra request on a track's first (uncached)
 * play buys a stock streaming path and a cache whose entries are
 * whole files by construction: downloaded beside the final name,
 * size-verified against the manifest, and renamed into place — a
 * same-directory rename, so a partial file never occupies the cache
 * name even across a crash. */
- (void)startAudioCacheDownloadFrom:(NSURL *)url toPath:(NSString *)cachePath expectedBytes:(uint64_t)expectedBytes {
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession]
        downloadTaskWithURL:url
          completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
              /* Background queue: file moves only, no host state. A
               * failed or cancelled download simply leaves no cache
               * entry — the next play streams again. */
              if (error || !location) return;
              if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                  NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
                  if (status != 200) return;
              }
              NSFileManager *manager = [NSFileManager defaultManager];
              NSString *directory = [cachePath stringByDeletingLastPathComponent];
              [manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
              NSString *partPath = [cachePath stringByAppendingPathExtension:@"part"];
              [manager removeItemAtPath:partPath error:nil];
              if (![manager moveItemAtURL:location toURL:[NSURL fileURLWithPath:partPath] error:nil]) return;
              NSDictionary *attributes = [manager attributesOfItemAtPath:partPath error:nil];
              unsigned long long size = attributes ? [attributes fileSize] : 0;
              if (expectedBytes != 0 && size != (unsigned long long)expectedBytes) {
                  /* Truncated or wrong content: never installed. */
                  [manager removeItemAtPath:partPath error:nil];
                  return;
              }
              [manager removeItemAtPath:cachePath error:nil];
              [manager moveItemAtPath:partPath toPath:cachePath error:nil];
          }];
    self.audioCacheDownload = task;
    [task resume];
}

/* Retire the spectrum tap with its item: the mix is detached, the
 * host's state pointer is cleared BEFORE the tap is released (same
 * thread as every reader), and the tap's finalize frees the ring once
 * the render side is provably done with it. */
- (void)audioTearDownSpectrumTap {
    [self stopAudioSpectrumTimer];
    if (self.audioItem) self.audioItem.audioMix = nil;
    self.audioSpectrumState = NULL;
    self.audioSpectrumLastWritten = 0;
    self.audioSpectrumFreshNs = 0;
    if (self.audioSpectrumTap) {
        CFRelease(self.audioSpectrumTap);
        self.audioSpectrumTap = NULL;
    }
}

/* Release the player and its observers. The download is cancelled when
 * a new load replaces a stream mid-flight (a skipped track should not
 * keep burning bandwidth) but ORPHANED on natural completion — it is
 * usually already done, and letting a straggler finish installs the
 * cache entry the completed play earned. */
- (void)audioTearDownPlayerCancellingDownload:(BOOL)cancelDownload {
    [self audioTearDownSpectrumTap];
    AVPlayerItem *item = self.audioItem;
    AVPlayer *player = self.audioPlayer;
    if (self.audioObservingStatus) {
        [item removeObserver:self forKeyPath:@"status" context:NativeSdkAppKitAudioItemStatusContext];
        [player removeObserver:self forKeyPath:@"timeControlStatus" context:NativeSdkAppKitAudioTimeControlContext];
        self.audioObservingStatus = NO;
    }
    if (self.audioEndObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.audioEndObserver];
        self.audioEndObserver = nil;
    }
    if (self.audioFailObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.audioFailObserver];
        self.audioFailObserver = nil;
    }
    [player pause];
    self.audioItem = nil;
    self.audioPlayer = nil;
    self.audioSourceIsLocal = NO;
    self.audioBuffering = NO;
    self.audioLoadedEmitted = NO;
    if (cancelDownload) [self.audioCacheDownload cancel];
    self.audioCacheDownload = nil;
}

/* Item status flipped (main queue, hopped from KVO): readyToPlay is
 * the load's LOADED acknowledgment — the duration is decoded and
 * playback is rolling or about to; failed is the honest terminal
 * report for an unreachable host or an undecodable payload. */
- (void)audioItemStatusChanged {
    AVPlayerItem *item = self.audioItem;
    if (!item) return;
    if (item.status == AVPlayerItemStatusReadyToPlay) {
        if (self.audioLoadedEmitted) return;
        self.audioLoadedEmitted = YES;
        [self emitAudioEventOfKind:NATIVE_SDK_APPKIT_AUDIO_EVENT_LOADED];
        return;
    }
    if (item.status == AVPlayerItemStatusFailed) {
        [self audioDidFail];
    }
}

/* timeControlStatus flipped (main queue, hopped from KVO): waiting to
 * play at the requested rate IS buffering — for streams. A local file
 * has all its bytes, so the flag never surfaces for local sources
 * (waits-to-minimize-stalling is off for them anyway). Emit the
 * transition immediately as a position report so the UI flips its
 * buffering state now, not at the next 500ms tick. */
- (void)audioTimeControlChanged {
    AVPlayer *player = self.audioPlayer;
    if (!player || self.audioSourceIsLocal) return;
    BOOL buffering = player.timeControlStatus == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate;
    if (buffering == self.audioBuffering) return;
    self.audioBuffering = buffering;
    [self emitAudioEventOfKind:NATIVE_SDK_APPKIT_AUDIO_EVENT_POSITION];
}

/* Natural end of the track, both sources. Retire-before-emit: the
 * completion Msg routinely starts the NEXT track from inside its own
 * dispatch (a music app auto-advancing), and tearing down afterwards
 * would destroy the player that load just installed. The duration is
 * captured first so the event still carries the honest terminal
 * position. */
- (void)audioDidPlayToEnd {
    if (!self.audioPlayer) return;
    [self stopAudioPositionTimer];
    uint64_t duration_ms = 0;
    if (self.audioItem) {
        double duration = NativeSdkSecondsFromCMTime(self.audioItem.duration);
        if (duration > 0) duration_ms = (uint64_t)llround(duration * 1000.0);
    }
    [self audioTearDownPlayerCancellingDownload:NO];
    [self emitEvent:(native_sdk_appkit_event_t){
        .kind = NATIVE_SDK_APPKIT_EVENT_AUDIO,
        .audio_kind = NATIVE_SDK_APPKIT_AUDIO_EVENT_COMPLETED,
        .audio_position_ms = duration_ms,
        .audio_duration_ms = duration_ms,
        .audio_playing = 0,
        .audio_buffering = 0,
        .timestamp_ns = NativeSdkTimestampNanoseconds(),
    }];
}

/* Playback died — a stream lost its network, a local file hit a decode
 * error mid-file, or an item never became playable (offline with a
 * cold cache): one FAILED event, player retired first. The cache
 * download is cancelled too — bytes from a failing source are not
 * trustworthy. */
- (void)audioDidFail {
    if (!self.audioPlayer) return;
    [self stopAudioPositionTimer];
    [self audioTearDownPlayerCancellingDownload:YES];
    [self emitEvent:(native_sdk_appkit_event_t){
        .kind = NATIVE_SDK_APPKIT_EVENT_AUDIO,
        .audio_kind = NATIVE_SDK_APPKIT_AUDIO_EVENT_FAILED,
        .audio_position_ms = 0,
        .audio_duration_ms = 0,
        .audio_playing = 0,
        .audio_buffering = 0,
        .timestamp_ns = NativeSdkTimestampNanoseconds(),
    }];
}

- (int)audioPlay {
    AVPlayer *player = self.audioPlayer;
    if (!player) return 0;
    /* AVPlayer's play is asynchronous by nature (it starts when
     * buffered bytes allow), so play always "applies" — readiness and
     * stalls report through the event stream. */
    [player play];
    if (!self.audioPositionTimer) {
        /* Common modes for the same reason app timers use them: the
         * readout must keep ticking while a menu is open or the window
         * is live-resizing. */
        NSTimer *tick = [NSTimer timerWithTimeInterval:0.5
                                                target:self
                                              selector:@selector(audioPositionTimerFired:)
                                              userInfo:nil
                                               repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:tick forMode:NSRunLoopCommonModes];
        self.audioPositionTimer = tick;
    }
    if (!self.audioSpectrumTimer) {
        /* The analysis cadence (~25 Hz). Armed with the transport like
         * the position tick; the fire handler additionally requires
         * fresh tap samples, so a stalled or tapless playback emits
         * nothing — never stale bars. */
        NSTimer *tick = [NSTimer timerWithTimeInterval:NATIVE_SDK_SPECTRUM_INTERVAL_SECONDS
                                                target:self
                                              selector:@selector(audioSpectrumTimerFired:)
                                              userInfo:nil
                                               repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:tick forMode:NSRunLoopCommonModes];
        self.audioSpectrumTimer = tick;
    }
    return 1;
}

- (int)audioPause {
    AVPlayer *player = self.audioPlayer;
    if (!player) return 0;
    [player pause];
    [self stopAudioPositionTimer];
    [self stopAudioSpectrumTimer];
    return 1;
}

- (int)audioStop {
    [self stopAudioPositionTimer];
    [self stopAudioSpectrumTimer];
    if (!self.audioPlayer) return 0;
    /* Replacement or explicit stop: a mid-flight cache download dies
     * with the playback — a skipped track should not keep burning
     * bandwidth (its next play streams and fills again). */
    [self audioTearDownPlayerCancellingDownload:YES];
    return 1;
}

- (int)audioSeekToMs:(uint64_t)positionMs {
    AVPlayer *player = self.audioPlayer;
    if (!player) return 0;
    /* AVPlayer clamps to the seekable ranges it has (or fetches the
     * range it needs); exact tolerance keeps the readout honest
     * against the requested position. */
    CMTime zero = NativeSdkCMTimeFromMs(0);
    [player seekToTime:NativeSdkCMTimeFromMs(positionMs)
       toleranceBefore:zero
        toleranceAfter:zero];
    return 1;
}

- (int)audioSetVolume:(double)volume {
    AVPlayer *player = self.audioPlayer;
    if (!player) return 0;
    player.volume = (float)volume;
    return 1;
}

- (void)scheduleBridgeFrames {
    self.bridgeFrameKeepalive = NativeSdkBridgeFrameKeepaliveFrames;
    [self scheduleFrame];
}

- (void)emitFrame {
    self.timer = nil;
    [self emitEvent:(native_sdk_appkit_event_t){ .kind = NATIVE_SDK_APPKIT_EVENT_FRAME }];
    if (self.bridgeFrameKeepalive > 0) {
        self.bridgeFrameKeepalive -= 1;
        [self scheduleFrame];
    }
}

- (void)emitShutdown {
    if (self.didShutdown) {
        return;
    }
    self.didShutdown = YES;
    [self emitEvent:(native_sdk_appkit_event_t){ .kind = NATIVE_SDK_APPKIT_EVENT_SHUTDOWN }];
}

- (void)loadSource:(NSString *)source kind:(NSInteger)kind assetRoot:(NSString *)assetRoot entry:(NSString *)entry origin:(NSString *)origin spaFallback:(BOOL)spaFallback {
    [self loadSource:source kind:kind assetRoot:assetRoot entry:entry origin:origin spaFallback:spaFallback windowId:1];
}

- (void)loadSource:(NSString *)source kind:(NSInteger)kind assetRoot:(NSString *)assetRoot entry:(NSString *)entry origin:(NSString *)origin spaFallback:(BOOL)spaFallback windowId:(uint64_t)windowId {
    WKWebView *webView = [self ensureMainWebViewForWindowId:windowId];
    NativeSdkAssetSchemeHandler *assetSchemeHandler = [self assetHandlerForWindowId:windowId];
    if (kind == 1) {
        NSURL *url = [NSURL URLWithString:source];
        if (url) {
            [webView loadRequest:[NSURLRequest requestWithURL:url]];
        }
    } else if (kind == 2) {
        [assetSchemeHandler configureWithRootPath:assetRoot entryPath:entry spaFallback:spaFallback];
        NSURL *url = NativeSdkAssetEntryURL(origin.length > 0 ? origin : @"zero://app", entry.length > 0 ? entry : @"index.html");
        if (url) {
            [webView loadRequest:[NSURLRequest requestWithURL:url]];
        }
    } else {
        [webView loadHTMLString:source baseURL:nil];
    }
}

- (void)setAllowedNavigationOrigins:(NSArray<NSString *> *)origins externalURLs:(NSArray<NSString *> *)externalURLs externalAction:(NSInteger)externalAction {
    self.allowedNavigationOrigins = origins.count > 0 ? origins : @[ @"zero://app", @"zero://inline" ];
    self.allowedExternalURLs = externalURLs ?: @[];
    self.externalLinkAction = externalAction;
}

- (BOOL)allowsNavigationURL:(NSURL *)url {
    if (!url) return YES;
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if (scheme.length == 0 || [scheme isEqualToString:@"about"]) return YES;
    return NativeSdkPolicyListMatches(self.allowedNavigationOrigins, url);
}

- (BOOL)openExternalURLIfAllowed:(NSURL *)url {
    if (self.externalLinkAction != 1) return NO;
    if (!NativeSdkPolicyListMatches(self.allowedExternalURLs, url)) return NO;
    [[NSWorkspace sharedWorkspace] openURL:url];
    return YES;
}

- (void)emitNavigationForWebView:(WKWebView *)webView url:(NSURL *)url {
    if (!webView || !url) return;
    uint64_t windowId = 1;
    NSString *label = @"main";
    for (NSNumber *key in self.webViews) {
        if (self.webViews[key] != webView) continue;
        windowId = key.unsignedLongLongValue;
        label = @"main";
        break;
    }
    for (NSString *key in self.childWebViews) {
        if (self.childWebViews[key] != webView) continue;
        NSRange separator = [key rangeOfString:@":"];
        if (separator.location != NSNotFound) {
            windowId = (uint64_t)[[key substringToIndex:separator.location] longLongValue];
            label = [key substringFromIndex:separator.location + 1];
        }
        break;
    }
    if ([label isEqualToString:@"main"]) return;
    NSDictionary *detail = @{ @"windowId": @(windowId), @"label": label, @"url": url.absoluteString ?: @"" };
    NSData *data = [NSJSONSerialization dataWithJSONObject:detail options:0 error:nil];
    if (!data) return;
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [self emitEventNamed:@"webview:navigate" detailJSON:json ?: @"{}" windowId:windowId];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    (void)navigation;
    for (NSNumber *key in self.webViews) {
        if (self.webViews[key] == webView) {
            [self updateCoveredMouseRectsInWindow:key.unsignedLongLongValue];
            return;
        }
    }
    for (NSString *key in self.childWebViews) {
        if (self.childWebViews[key] != webView) continue;
        NSRange separator = [key rangeOfString:@":"];
        if (separator.location != NSNotFound) {
            uint64_t windowId = (uint64_t)[[key substringToIndex:separator.location] longLongValue];
            [self updateCoveredMouseRectsInWindow:windowId];
        }
        return;
    }
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    if (!navigationAction.targetFrame || navigationAction.targetFrame.isMainFrame) {
        if ([self allowsNavigationURL:url]) {
            [self emitNavigationForWebView:webView url:url];
            decisionHandler(WKNavigationActionPolicyAllow);
            return;
        }
        if ([self openExternalURLIfAllowed:url]) {
            decisionHandler(WKNavigationActionPolicyCancel);
            return;
        }
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (NSString *)bridgeOriginForMessage:(WKScriptMessage *)message {
    WKSecurityOrigin *securityOrigin = message.frameInfo.securityOrigin;
    if (securityOrigin.protocol.length == 0 || [securityOrigin.protocol isEqualToString:@"about"]) {
        return @"zero://inline";
    }
    if (securityOrigin.host.length == 0) {
        return [NSString stringWithFormat:@"%@://local", securityOrigin.protocol];
    }
    if (securityOrigin.port > 0) {
        return [NSString stringWithFormat:@"%@://%@:%ld", securityOrigin.protocol, securityOrigin.host, (long)securityOrigin.port];
    }
    return [NSString stringWithFormat:@"%@://%@", securityOrigin.protocol, securityOrigin.host];
}

- (void)receiveBridgeMessage:(WKScriptMessage *)message windowId:(uint64_t)windowId webViewLabel:(NSString *)webViewLabel {
    if (!self.bridgeCallback) {
        return;
    }

    NSString *messageString = nil;
    if ([message.body isKindOfClass:[NSString class]]) {
        messageString = (NSString *)message.body;
    } else if ([NSJSONSerialization isValidJSONObject:message.body]) {
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:message.body options:0 error:nil];
        if (jsonData) {
            messageString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        }
    }
    if (!messageString) {
        messageString = @"{}";
    }

    NSString *origin = [self bridgeOriginForMessage:message];
    NSData *messageData = [messageString dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSData *originData = [origin dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSData *labelData = [(webViewLabel.length > 0 ? webViewLabel : @"main") dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    self.bridgeCallback(self.bridgeContext, windowId, (const char *)labelData.bytes, labelData.length, (const char *)messageData.bytes, messageData.length, (const char *)originData.bytes, originData.length);
    [self scheduleFrame];
}

- (void)completeBridgeWithResponse:(NSString *)response {
    [self completeBridgeWithResponse:response windowId:1 webViewLabel:@"main"];
}

- (void)completeBridgeWithResponse:(NSString *)response windowId:(uint64_t)windowId {
    [self completeBridgeWithResponse:response windowId:windowId webViewLabel:@"main"];
}

- (void)completeBridgeWithResponse:(NSString *)response windowId:(uint64_t)windowId webViewLabel:(NSString *)webViewLabel {
    WKWebView *webView = [self webViewForWindowId:windowId];
    NSString *script = [NSString stringWithFormat:@"window.zero&&window.zero._complete(%@);", response.length > 0 ? response : @"{}"];
    NSString *label = webViewLabel.length > 0 ? webViewLabel : @"main";
    if ([label isEqualToString:@"main"]) {
        if (!webView) return;
        [webView evaluateJavaScript:script completionHandler:nil];
    } else {
        WKWebView *child = self.childWebViews[[self webViewKeyForWindow:windowId label:label]];
        if (!child) return;
        [child evaluateJavaScript:script completionHandler:nil];
    }
    [self scheduleBridgeFrames];
}

- (void)emitEventNamed:(NSString *)name detailJSON:(NSString *)detailJSON windowId:(uint64_t)windowId {
    WKWebView *webView = [self webViewForWindowId:windowId];
    NSData *nameData = [NSJSONSerialization dataWithJSONObject:name ?: @"" options:NSJSONWritingFragmentsAllowed error:nil];
    NSString *nameJSON = nameData ? [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding] : @"\"\"";
    NSString *detail = detailJSON.length > 0 ? detailJSON : @"null";
    NSString *script = [NSString stringWithFormat:@"window.zero&&window.zero._emit(%@,%@);", nameJSON, detail];
    [webView evaluateJavaScript:script completionHandler:nil];
    [self scheduleBridgeFrames];
}

- (BOOL)handleShortcutEvent:(NSEvent *)event {
    if (event.type != NSEventTypeKeyDown) return NO;
    NSString *key = NativeSdkShortcutKeyForEvent(event);
    if (key.length == 0) return NO;
    BOOL usesImplicitShift = NativeSdkShortcutUsesImplicitShift(key, event);

    for (NSUInteger pass = 0; pass < (usesImplicitShift ? 2 : 1); pass++) {
        BOOL allowImplicitShift = pass == 1;
        for (NativeSdkShortcut *shortcut in self.shortcuts) {
            if (![shortcut.key isEqualToString:key]) continue;
            if (!NativeSdkShortcutModifiersMatch(shortcut.modifiers, event.modifierFlags, allowImplicitShift)) continue;
            [self emitShortcutWithId:shortcut.identifier key:shortcut.key modifiers:shortcut.modifiers event:event];
            return YES;
        }
    }

    return NO;
}

- (void)emitShortcutWithId:(NSString *)identifier key:(NSString *)key modifiers:(uint32_t)modifiers event:(NSEvent *)event {
    uint64_t windowId = 1;
    NSWindow *window = event.window ?: NSApp.keyWindow;
    for (NSNumber *keyValue in self.windows) {
        if (self.windows[keyValue] == window) {
            windowId = keyValue.unsignedLongLongValue;
            break;
        }
    }
    const char *identifierBytes = identifier.UTF8String ? identifier.UTF8String : "";
    const char *keyBytes = key.UTF8String ? key.UTF8String : "";
    [self emitEvent:(native_sdk_appkit_event_t){
        .kind = NATIVE_SDK_APPKIT_EVENT_SHORTCUT,
        .window_id = windowId,
        .shortcut_id = identifierBytes,
        .shortcut_id_len = [identifier lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        .shortcut_key = keyBytes,
        .shortcut_key_len = [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        .shortcut_modifiers = modifiers,
    }];
}

- (BOOL)emitDroppedFileURLs:(NSArray<NSURL *> *)urls windowId:(uint64_t)windowId {
    if (urls.count == 0) return NO;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSURL *url in urls) {
        if (!url.isFileURL || url.path.length == 0) continue;
        [paths addObject:url.path];
    }
    if (paths.count == 0) return NO;
    NSMutableData *data = [NSMutableData data];
    const char separator = '\0';
    for (NSString *path in paths) {
        NSData *pathData = [path dataUsingEncoding:NSUTF8StringEncoding];
        if (!pathData || pathData.length == 0) continue;
        if (data.length > 0) [data appendBytes:&separator length:1];
        [data appendData:pathData];
    }
    if (data.length == 0) return NO;
    [self emitEvent:(native_sdk_appkit_event_t){
        .kind = NATIVE_SDK_APPKIT_EVENT_FILES_DROPPED,
        .window_id = windowId,
        .drop_paths = data.bytes,
        .drop_paths_len = data.length,
    }];
    return YES;
}

- (void)setShortcutsWithIds:(const char *const *)ids idLengths:(const size_t *)idLengths keys:(const char *const *)keys keyLengths:(const size_t *)keyLengths modifiers:(const uint32_t *)modifiers count:(size_t)count {
    NSMutableArray<NativeSdkShortcut *> *items = [[NSMutableArray alloc] initWithCapacity:count];
    for (size_t index = 0; index < count; index++) {
        NSString *identifier = ids[index] ? [[NSString alloc] initWithBytes:ids[index] length:idLengths[index] encoding:NSUTF8StringEncoding] : @"";
        NSString *key = keys[index] ? [[NSString alloc] initWithBytes:keys[index] length:keyLengths[index] encoding:NSUTF8StringEncoding] : @"";
        if (identifier.length == 0 || key.length == 0) continue;
        NativeSdkShortcut *shortcut = [[NativeSdkShortcut alloc] init];
        shortcut.identifier = identifier;
        shortcut.key = key.lowercaseString;
        shortcut.modifiers = modifiers[index];
        [items addObject:shortcut];
    }
    self.shortcuts = items;
}

/* The standard About panel, populated explicitly so unbundled dev runs
 * show the same identity a packaged bundle reads from Info.plist: the
 * display name, the app.zon version, and the description as the
 * credits line. The icon is NSApp.applicationIconImage, which
 * configureApplication loads from the manifest icon. */
- (void)showAboutPanel:(id)sender {
    (void)sender;
    NSMutableDictionary<NSAboutPanelOptionKey, id> *options = [[NSMutableDictionary alloc] init];
    options[NSAboutPanelOptionApplicationName] = self.displayName;
    if (self.appIcon) {
        options[NSAboutPanelOptionApplicationIcon] = self.appIcon;
    }
    if (self.appVersion.length > 0) {
        options[NSAboutPanelOptionApplicationVersion] = self.appVersion;
        // Suppress the parenthesized build-number line unbundled
        // binaries have no honest value for.
        options[NSAboutPanelOptionVersion] = @"";
    }
    if (self.aboutDescription.length > 0) {
        NSDictionary<NSAttributedStringKey, id> *creditAttributes = @{
            NSFontAttributeName : [NSFont systemFontOfSize:11],
            NSForegroundColorAttributeName : NSColor.secondaryLabelColor,
        };
        options[NSAboutPanelOptionCredits] = [[NSAttributedString alloc] initWithString:self.aboutDescription attributes:creditAttributes];
    }
    [NSApp orderFrontStandardAboutPanelWithOptions:options];
}

- (void)reload:(id)sender {
    (void)sender;
    WKWebView *webView = [self mainWebViewForWindow:NSApp.keyWindow];
    if (!webView) return;
    [webView reload];
    [self scheduleFrame];
}

- (void)toggleWebInspector:(id)sender {
    (void)sender;
    WKWebView *webView = [self mainWebViewForWindow:NSApp.keyWindow];
    if (!webView) return;
    SEL selector = NSSelectorFromString(@"_showInspector");
    if ([webView respondsToSelector:selector]) {
        ((void (*)(id, SEL))[webView methodForSelector:selector])(webView, selector);
    }
}

- (void)trayMenuItemClicked:(NSMenuItem *)menuItem {
    if (self.trayCallback) {
        self.trayCallback(self.trayContext, (uint32_t)menuItem.tag);
    }
}

@end

static NSArray<NSString *> *NativeSdkPolicyListFromBytes(const char *bytes, size_t len, NSArray<NSString *> *fallback) {
    if (!bytes || len == 0) return fallback ?: @[];
    NSString *joined = [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
    if (joined.length == 0) return fallback ?: @[];
    NSMutableArray<NSString *> *values = [[NSMutableArray alloc] init];
    for (NSString *part in [joined componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length > 0) [values addObject:trimmed];
    }
    return values.count > 0 ? values : (fallback ?: @[]);
}

static NSString *NativeSdkOriginForURL(NSURL *url) {
    if (!url) return @"";
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if (scheme.length == 0 || [scheme isEqualToString:@"about"]) return @"zero://inline";
    if ([scheme isEqualToString:@"file"]) return @"file://local";
    NSString *host = url.host ?: @"";
    if (host.length == 0) return [NSString stringWithFormat:@"%@://local", scheme];
    NSNumber *port = url.port;
    if (port) return [NSString stringWithFormat:@"%@://%@:%@", scheme, host, port];
    return [NSString stringWithFormat:@"%@://%@", scheme, host];
}

static NSString *NativeSdkShortcutKeyForEvent(NSEvent *event) {
    NSString *characters = event.charactersIgnoringModifiers ?: @"";
    if (characters.length == 0) return @"";
    unichar ch = [characters characterAtIndex:0];
    switch (ch) {
        case NSUpArrowFunctionKey: return @"arrowup";
        case NSDownArrowFunctionKey: return @"arrowdown";
        case NSLeftArrowFunctionKey: return @"arrowleft";
        case NSRightArrowFunctionKey: return @"arrowright";
        case NSDeleteFunctionKey: return @"delete";
        case NSHomeFunctionKey: return @"home";
        case NSEndFunctionKey: return @"end";
        case 0x1b: return @"escape";
        case '\r': return @"enter";
        case '\t': return @"tab";
        case NSBackTabCharacter: return @"tab";
        case ' ': return @"space";
        case 0x7f: return @"backspace";
        case '!': return @"1";
        case '@': return @"2";
        case '#': return @"3";
        case '$': return @"4";
        case '%': return @"5";
        case '^': return @"6";
        case '&': return @"7";
        case '*': return @"8";
        case '(': return @"9";
        case ')': return @"0";
        case '+': return @"=";
        case '_': return @"-";
        case '<': return @",";
        case '>': return @".";
        case '?': return @"/";
        case ':': return @";";
        case '"': return @"'";
        case '{': return @"[";
        case '}': return @"]";
        case '|': return @"\\";
        case '~': return @"`";
        default: return characters.lowercaseString;
    }
}

static BOOL NativeSdkShortcutUsesImplicitShift(NSString *key, NSEvent *event) {
    if ((event.modifierFlags & NSEventModifierFlagShift) == 0) return NO;
    if (key.length != 1) return NO;
    unichar ch = [key characterAtIndex:0];
    return (ch >= '0' && ch <= '9') ||
        ch == '=' || ch == '-' || ch == ',' ||
        ch == '.' || ch == '/' || ch == ';' || ch == '\'' ||
        ch == '[' || ch == ']' || ch == '\\' || ch == '`';
}

static BOOL NativeSdkShortcutModifiersMatch(uint32_t shortcutModifiers, NSEventModifierFlags eventModifiers, BOOL allowImplicitShift) {
    NSEventModifierFlags flags = eventModifiers & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL needsCommand = (shortcutModifiers & NativeSdkShortcutModifierCommand) != 0 || (shortcutModifiers & NativeSdkShortcutModifierPrimary) != 0;
    BOOL needsControl = (shortcutModifiers & NativeSdkShortcutModifierControl) != 0;
    BOOL needsOption = (shortcutModifiers & NativeSdkShortcutModifierOption) != 0;
    BOOL needsShift = (shortcutModifiers & NativeSdkShortcutModifierShift) != 0;
    BOOL hasCommand = (flags & NSEventModifierFlagCommand) != 0;
    BOOL hasControl = (flags & NSEventModifierFlagControl) != 0;
    BOOL hasOption = (flags & NSEventModifierFlagOption) != 0;
    BOOL hasShift = (flags & NSEventModifierFlagShift) != 0;
    BOOL shiftMatches = needsShift ? hasShift : (!hasShift || allowImplicitShift);
    return hasCommand == needsCommand && hasControl == needsControl && hasOption == needsOption && shiftMatches;
}

static NSEventModifierFlags NativeSdkMenuModifierFlags(uint32_t modifiers) {
    NSEventModifierFlags flags = 0;
    if ((modifiers & NativeSdkShortcutModifierPrimary) != 0 || (modifiers & NativeSdkShortcutModifierCommand) != 0) flags |= NSEventModifierFlagCommand;
    if ((modifiers & NativeSdkShortcutModifierControl) != 0) flags |= NSEventModifierFlagControl;
    if ((modifiers & NativeSdkShortcutModifierOption) != 0) flags |= NSEventModifierFlagOption;
    if ((modifiers & NativeSdkShortcutModifierShift) != 0) flags |= NSEventModifierFlagShift;
    return flags;
}

static BOOL NativeSdkWildcardPrefixHasPath(NSString *prefix) {
    NSURLComponents *components = [NSURLComponents componentsWithString:prefix ?: @""];
    return components.scheme.length > 0 && components.host.length > 0 && components.percentEncodedPath.length > 0;
}

static BOOL NativeSdkPolicyListMatches(NSArray<NSString *> *values, NSURL *url) {
    NSString *origin = NativeSdkOriginForURL(url);
    NSString *absolute = url.absoluteString ?: @"";
    for (NSString *value in values) {
        if ([value isEqualToString:@"*"]) return YES;
        if ([value isEqualToString:origin] || [value isEqualToString:absolute]) return YES;
        if ([value hasSuffix:@"*"]) {
            NSString *prefix = [value substringToIndex:value.length - 1];
            if (NativeSdkWildcardPrefixHasPath(prefix) && [absolute hasPrefix:prefix]) return YES;
        }
    }
    return NO;
}

native_sdk_appkit_host_t *native_sdk_appkit_create(const char *app_name, size_t app_name_len, const char *display_name, size_t display_name_len, const char *version, size_t version_len, const char *about_description, size_t about_description_len, int has_web_content, const char *window_title, size_t window_title_len, const char *bundle_id, size_t bundle_id_len, const char *icon_path, size_t icon_path_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame, int resizable, int titlebar_style, int show_policy) {
    @autoreleasepool {
        NSString *appNameString = [[NSString alloc] initWithBytes:app_name length:app_name_len encoding:NSUTF8StringEncoding] ?: @"native-sdk";
        NSString *displayNameString = [[NSString alloc] initWithBytes:display_name length:display_name_len encoding:NSUTF8StringEncoding] ?: @"";
        NSString *versionString = [[NSString alloc] initWithBytes:version length:version_len encoding:NSUTF8StringEncoding] ?: @"";
        NSString *aboutDescriptionString = [[NSString alloc] initWithBytes:about_description length:about_description_len encoding:NSUTF8StringEncoding] ?: @"";
        NSString *windowTitleString = [[NSString alloc] initWithBytes:window_title length:window_title_len encoding:NSUTF8StringEncoding] ?: appNameString;
        NSString *bundleIdString = [[NSString alloc] initWithBytes:bundle_id length:bundle_id_len encoding:NSUTF8StringEncoding] ?: @"dev.native_sdk.app";
        NSString *iconPathString = [[NSString alloc] initWithBytes:icon_path length:icon_path_len encoding:NSUTF8StringEncoding] ?: @"";
        NSString *windowLabelString = [[NSString alloc] initWithBytes:window_label length:window_label_len encoding:NSUTF8StringEncoding] ?: @"main";
        NativeSdkAppKitHost *host = [[NativeSdkAppKitHost alloc] initWithAppName:appNameString displayName:displayNameString version:versionString aboutDescription:aboutDescriptionString hasWebContent:(has_web_content != 0) windowTitle:windowTitleString bundleIdentifier:bundleIdString iconPath:iconPathString windowLabel:windowLabelString x:x y:y width:width height:height restoreFrame:(restore_frame != 0) resizable:(resizable != 0) titlebarStyle:titlebar_style showPolicy:show_policy];
        return (__bridge_retained native_sdk_appkit_host_t *)host;
    }
}

void native_sdk_appkit_destroy(native_sdk_appkit_host_t *host) {
    if (!host) {
        return;
    }
    CFBridgingRelease(host);
}

void native_sdk_appkit_set_dock_icon_rgba(native_sdk_appkit_host_t *host, const uint8_t *pixels, size_t width, size_t height) {
    if (!host || !pixels || width == 0 || height == 0) return;
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    @autoreleasepool {
        /* Wrap the straight-alpha RGBA8 rows in a bitmap rep the image
         * owns: the caller frees its buffer on return, so the pixels are
         * copied row-by-row into the rep's own allocation (planes:NULL
         * makes the rep allocate). Safe off the main thread — image
         * construction is, only the NSApp adoption needs main. */
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                        pixelsWide:(NSInteger)width
                                                                        pixelsHigh:(NSInteger)height
                                                                     bitsPerSample:8
                                                                   samplesPerPixel:4
                                                                          hasAlpha:YES
                                                                          isPlanar:NO
                                                                    colorSpaceName:NSCalibratedRGBColorSpace
                                                                      bitmapFormat:NSBitmapFormatAlphaNonpremultiplied
                                                                       bytesPerRow:0
                                                                      bitsPerPixel:32];
        if (!rep || !rep.bitmapData) return;
        const size_t source_stride = width * 4;
        const size_t dest_stride = (size_t)rep.bytesPerRow;
        unsigned char *dest = rep.bitmapData;
        for (size_t y = 0; y < height; y += 1) {
            memcpy(dest + y * dest_stride, pixels + y * source_stride, source_stride);
        }
        NSImage *icon = [[NSImage alloc] initWithSize:NSMakeSize((CGFloat)width, (CGFloat)height)];
        [icon addRepresentation:rep];
        __weak NativeSdkAppKitHost *weakObject = object;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakObject adoptDockIcon:icon];
        });
    }
}

void native_sdk_appkit_set_dock_icon_file(native_sdk_appkit_host_t *host, const char *path, size_t path_len) {
    if (!host || !path || path_len == 0) return;
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    @autoreleasepool {
        NSString *pathString = [[NSString alloc] initWithBytes:path length:path_len encoding:NSUTF8StringEncoding];
        if (pathString.length == 0) return;
        [object loadDockIconFromFile:pathString];
    }
}

void native_sdk_appkit_run(native_sdk_appkit_host_t *host, native_sdk_appkit_event_callback_t callback, void *context) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    [object runWithCallback:callback context:context];
}

void native_sdk_appkit_request_frame(native_sdk_appkit_host_t *host) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    [object requestFrameFromAnyThread];
}

void native_sdk_appkit_start_timer(native_sdk_appkit_host_t *host, uint64_t timer_id, uint64_t interval_ns, int repeats) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    [object startAppTimerWithId:timer_id intervalNs:interval_ns repeats:(repeats != 0)];
}

void native_sdk_appkit_cancel_timer(native_sdk_appkit_host_t *host, uint64_t timer_id) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    [object cancelAppTimerWithId:timer_id];
}

int native_sdk_appkit_audio_load(native_sdk_appkit_host_t *host, const char *path, size_t path_len) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *path_string = [[NSString alloc] initWithBytes:path length:path_len encoding:NSUTF8StringEncoding];
    if (!path_string) return 1;
    return [object audioLoadPath:path_string];
}

int native_sdk_appkit_audio_load_url(native_sdk_appkit_host_t *host, const char *url, size_t url_len, const char *cache_path, size_t cache_path_len, uint64_t expected_bytes) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *url_string = [[NSString alloc] initWithBytes:url length:url_len encoding:NSUTF8StringEncoding];
    if (!url_string) return 2;
    NSString *cache_string = @"";
    if (cache_path_len > 0) {
        cache_string = [[NSString alloc] initWithBytes:cache_path length:cache_path_len encoding:NSUTF8StringEncoding];
        if (!cache_string) return 2;
    }
    return [object audioLoadURL:url_string cachePath:cache_string expectedBytes:expected_bytes];
}

int native_sdk_appkit_audio_play(native_sdk_appkit_host_t *host) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    return [object audioPlay];
}

int native_sdk_appkit_audio_pause(native_sdk_appkit_host_t *host) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    return [object audioPause];
}

int native_sdk_appkit_audio_stop(native_sdk_appkit_host_t *host) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    return [object audioStop];
}

int native_sdk_appkit_audio_seek(native_sdk_appkit_host_t *host, uint64_t position_ms) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    return [object audioSeekToMs:position_ms];
}

int native_sdk_appkit_audio_set_volume(native_sdk_appkit_host_t *host, double volume) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    return [object audioSetVolume:volume];
}

void native_sdk_appkit_wake(native_sdk_appkit_host_t *host) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    [object wakeFromAnyThread];
}

void native_sdk_appkit_stop(native_sdk_appkit_host_t *host) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    [object emitShutdown];
    [object stop];
}

void native_sdk_appkit_load_webview(native_sdk_appkit_host_t *host, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback) {
    native_sdk_appkit_load_window_webview(host, 1, source, source_len, source_kind, asset_root, asset_root_len, asset_entry, asset_entry_len, asset_origin, asset_origin_len, spa_fallback);
}

void native_sdk_appkit_load_window_webview(native_sdk_appkit_host_t *host, uint64_t window_id, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *sourceString = source ? [[NSString alloc] initWithBytes:source length:source_len encoding:NSUTF8StringEncoding] : @"";
    NSString *assetRoot = asset_root ? [[NSString alloc] initWithBytes:asset_root length:asset_root_len encoding:NSUTF8StringEncoding] : @"";
    NSString *assetEntry = asset_entry ? [[NSString alloc] initWithBytes:asset_entry length:asset_entry_len encoding:NSUTF8StringEncoding] : @"";
    NSString *assetOrigin = asset_origin ? [[NSString alloc] initWithBytes:asset_origin length:asset_origin_len encoding:NSUTF8StringEncoding] : @"";
    [object loadSource:sourceString ?: @""
                  kind:source_kind
             assetRoot:assetRoot ?: @""
                 entry:assetEntry ?: @""
                origin:assetOrigin ?: @""
           spaFallback:(spa_fallback != 0)
              windowId:window_id];
}

void native_sdk_appkit_set_bridge_callback(native_sdk_appkit_host_t *host, native_sdk_appkit_bridge_callback_t callback, void *context) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    object.bridgeCallback = callback;
    object.bridgeContext = context;
}

void native_sdk_appkit_bridge_respond(native_sdk_appkit_host_t *host, const char *response, size_t response_len) {
    native_sdk_appkit_bridge_respond_window(host, 1, response, response_len);
}

void native_sdk_appkit_bridge_respond_window(native_sdk_appkit_host_t *host, uint64_t window_id, const char *response, size_t response_len) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *responseString = response ? [[NSString alloc] initWithBytes:response length:response_len encoding:NSUTF8StringEncoding] : @"{}";
    [object completeBridgeWithResponse:responseString ?: @"{}" windowId:window_id];
}

void native_sdk_appkit_bridge_respond_webview(native_sdk_appkit_host_t *host, uint64_t window_id, const char *webview_label, size_t webview_label_len, const char *response, size_t response_len) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = webview_label ? [[NSString alloc] initWithBytes:webview_label length:webview_label_len encoding:NSUTF8StringEncoding] : @"main";
    NSString *responseString = response ? [[NSString alloc] initWithBytes:response length:response_len encoding:NSUTF8StringEncoding] : @"{}";
    [object completeBridgeWithResponse:responseString ?: @"{}" windowId:window_id webViewLabel:labelString ?: @"main"];
}

void native_sdk_appkit_emit_window_event(native_sdk_appkit_host_t *host, uint64_t window_id, const char *name, size_t name_len, const char *detail_json, size_t detail_json_len) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *nameString = name ? [[NSString alloc] initWithBytes:name length:name_len encoding:NSUTF8StringEncoding] : @"";
    NSString *detailString = detail_json ? [[NSString alloc] initWithBytes:detail_json length:detail_json_len encoding:NSUTF8StringEncoding] : @"null";
    [object emitEventNamed:nameString ?: @"" detailJSON:detailString ?: @"null" windowId:window_id];
}

void native_sdk_appkit_set_security_policy(native_sdk_appkit_host_t *host, const char *allowed_origins, size_t allowed_origins_len, const char *external_urls, size_t external_urls_len, int external_action) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSArray<NSString *> *origins = NativeSdkPolicyListFromBytes(allowed_origins, allowed_origins_len, @[ @"zero://app", @"zero://inline" ]);
    NSArray<NSString *> *externalURLs = NativeSdkPolicyListFromBytes(external_urls, external_urls_len, @[]);
    [object setAllowedNavigationOrigins:origins externalURLs:externalURLs externalAction:external_action];
}

void native_sdk_appkit_set_menus(native_sdk_appkit_host_t *host, const char *const *menu_titles, const size_t *menu_title_lens, size_t menu_count, const uint32_t *item_menu_indices, const char *const *item_labels, const size_t *item_label_lens, const char *const *item_commands, const size_t *item_command_lens, const char *const *item_keys, const size_t *item_key_lens, const uint32_t *item_modifiers, const int *item_separators, const int *item_enabled, const int *item_checked, size_t item_count) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    [object setMenusWithTitles:menu_titles titleLengths:menu_title_lens count:menu_count itemMenuIndices:item_menu_indices itemLabels:item_labels itemLabelLengths:item_label_lens itemCommands:item_commands itemCommandLengths:item_command_lens itemKeys:item_keys itemKeyLengths:item_key_lens itemModifiers:item_modifiers itemSeparators:item_separators itemEnabled:item_enabled itemChecked:item_checked itemCount:item_count];
}

void native_sdk_appkit_set_shortcuts(native_sdk_appkit_host_t *host, const char *const *ids, const size_t *id_lens, const char *const *keys, const size_t *key_lens, const uint32_t *modifiers, size_t count) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    [object setShortcutsWithIds:ids idLengths:id_lens keys:keys keyLengths:key_lens modifiers:modifiers count:count];
}

int native_sdk_appkit_create_window(native_sdk_appkit_host_t *host, uint64_t window_id, const char *window_title, size_t window_title_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame, int resizable, int titlebar_style, int show_policy) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *titleString = window_title ? [[NSString alloc] initWithBytes:window_title length:window_title_len encoding:NSUTF8StringEncoding] : @"";
    NSString *labelString = window_label ? [[NSString alloc] initWithBytes:window_label length:window_label_len encoding:NSUTF8StringEncoding] : @"";
    return [object createWindowWithId:window_id title:titleString ?: @"" label:labelString ?: @"" x:x y:y width:width height:height restoreFrame:(restore_frame != 0) resizable:(resizable != 0) titlebarStyle:titlebar_style showPolicy:show_policy makeMain:NO] ? 1 : 0;
}

int native_sdk_appkit_set_window_content_min_size(native_sdk_appkit_host_t *host, uint64_t window_id, double min_width, double min_height) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSWindow *window = object.windows[@(window_id)];
    if (!window) return 0;
    // The declared floor is CONTENT size (matches the frame the runtime
    // reasons about); AppKit adds the chrome on top. Axes <= 0 keep
    // AppKit's default minimum for that axis.
    NSSize current = window.contentMinSize;
    window.contentMinSize = NSMakeSize(min_width > 0 ? min_width : current.width,
                                       min_height > 0 ? min_height : current.height);
    return 1;
}

int native_sdk_appkit_focus_window(native_sdk_appkit_host_t *host, uint64_t window_id) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    if (!object.windows[@(window_id)]) return 0;
    [object focusWindowWithId:window_id];
    return 1;
}

int native_sdk_appkit_close_window(native_sdk_appkit_host_t *host, uint64_t window_id) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    if (!object.windows[@(window_id)]) return 0;
    [object closeWindowWithId:window_id];
    return 1;
}

int native_sdk_appkit_minimize_window(native_sdk_appkit_host_t *host, uint64_t window_id) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    if (!object.windows[@(window_id)]) return 0;
    [object miniaturizeWindowWithId:window_id];
    return 1;
}

int native_sdk_appkit_start_window_drag(native_sdk_appkit_host_t *host, uint64_t window_id) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    return [object startWindowDragWithId:window_id] ? 1 : 0;
}

int native_sdk_appkit_window_chrome_insets(native_sdk_appkit_host_t *host, uint64_t window_id, double *top, double *left, double *bottom, double *right, double *buttons_x, double *buttons_y, double *buttons_width, double *buttons_height) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    return [object chromeInsetsForWindowId:window_id top:top left:left bottom:bottom right:right buttonsX:buttons_x buttonsY:buttons_y buttonsWidth:buttons_width buttonsHeight:buttons_height] ? 1 : 0;
}

int native_sdk_appkit_create_view(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int kind, const char *parent, size_t parent_len, double x, double y, double width, double height, int layer, int visible, int enabled, const char *role, size_t role_len, const char *accessibility_label, size_t accessibility_label_len, const char *text, size_t text_len, const char *command, size_t command_len) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    NSString *parentString = parent ? [[NSString alloc] initWithBytes:parent length:parent_len encoding:NSUTF8StringEncoding] : @"";
    NSString *roleString = role ? [[NSString alloc] initWithBytes:role length:role_len encoding:NSUTF8StringEncoding] : @"";
    NSString *accessibilityLabelString = accessibility_label ? [[NSString alloc] initWithBytes:accessibility_label length:accessibility_label_len encoding:NSUTF8StringEncoding] : @"";
    NSString *textString = text ? [[NSString alloc] initWithBytes:text length:text_len encoding:NSUTF8StringEncoding] : @"";
    NSString *commandString = command ? [[NSString alloc] initWithBytes:command length:command_len encoding:NSUTF8StringEncoding] : @"";
    return [object createNativeViewInWindow:window_id label:labelString ?: @"" kind:kind parent:parentString ?: @"" x:x y:y width:width height:height layer:layer visible:(visible != 0) enabled:(enabled != 0) role:roleString ?: @"" accessibilityLabel:accessibilityLabelString ?: @"" text:textString ?: @"" command:commandString ?: @""] ? 1 : 0;
}

int native_sdk_appkit_update_view(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int has_frame, double x, double y, double width, double height, int has_layer, int layer, int has_visible, int visible, int has_enabled, int enabled, int has_role, const char *role, size_t role_len, int has_accessibility_label, const char *accessibility_label, size_t accessibility_label_len, int has_text, const char *text, size_t text_len, int has_command, const char *command, size_t command_len) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    NSString *roleString = role ? [[NSString alloc] initWithBytes:role length:role_len encoding:NSUTF8StringEncoding] : @"";
    NSString *accessibilityLabelString = accessibility_label ? [[NSString alloc] initWithBytes:accessibility_label length:accessibility_label_len encoding:NSUTF8StringEncoding] : @"";
    NSString *textString = text ? [[NSString alloc] initWithBytes:text length:text_len encoding:NSUTF8StringEncoding] : @"";
    NSString *commandString = command ? [[NSString alloc] initWithBytes:command length:command_len encoding:NSUTF8StringEncoding] : @"";
    return [object updateNativeViewInWindow:window_id label:labelString ?: @"" hasFrame:(has_frame != 0) x:x y:y width:width height:height hasLayer:(has_layer != 0) layer:layer hasVisible:(has_visible != 0) visible:(visible != 0) hasEnabled:(has_enabled != 0) enabled:(enabled != 0) hasRole:(has_role != 0) role:roleString ?: @"" hasAccessibilityLabel:(has_accessibility_label != 0) accessibilityLabel:accessibilityLabelString ?: @"" hasText:(has_text != 0) text:textString ?: @"" hasCommand:(has_command != 0) command:commandString ?: @""] ? 1 : 0;
}

int native_sdk_appkit_set_view_frame(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object setNativeViewFrameInWindow:window_id label:labelString ?: @"" x:x y:y width:width height:height] ? 1 : 0;
}

int native_sdk_appkit_set_view_visible(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int visible) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object setNativeViewVisibleInWindow:window_id label:labelString ?: @"" visible:(visible != 0)] ? 1 : 0;
}

int native_sdk_appkit_set_view_cursor(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int cursor) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object setNativeViewCursorInWindow:window_id label:labelString ?: @"" cursor:cursor] ? 1 : 0;
}

int native_sdk_appkit_focus_view(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object focusNativeViewInWindow:window_id label:labelString ?: @""] ? 1 : 0;
}

int native_sdk_appkit_close_view(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object closeNativeViewInWindow:window_id label:labelString ?: @""] ? 1 : 0;
}

int native_sdk_appkit_adopt_view_surface(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, void *ns_view) {
    if (!ns_view) return 0;
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    NSView *surface = (__bridge NSView *)ns_view;
    return [object adoptViewSurfaceInWindow:window_id label:labelString ?: @"" surface:surface] ? 1 : 0;
}

int native_sdk_appkit_release_view_surface(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object releaseViewSurfaceInWindow:window_id label:labelString ?: @""] ? 1 : 0;
}

int native_sdk_appkit_present_gpu_surface_pixels(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, size_t width, size_t height, double scale, int has_dirty_rect, double dirty_x, double dirty_y, double dirty_width, double dirty_height, const uint8_t *rgba8, size_t rgba8_len) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object presentGpuSurfacePixelsInWindow:window_id label:labelString ?: @"" width:width height:height scale:scale hasDirtyRect:(has_dirty_rect != 0) dirtyX:dirty_x dirtyY:dirty_y dirtyWidth:dirty_width dirtyHeight:dirty_height rgba8:rgba8 byteLength:rgba8_len] ? 1 : 0;
}

int native_sdk_appkit_present_gpu_surface_packet(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double surface_width, double surface_height, double scale, uint8_t clear_r, uint8_t clear_g, uint8_t clear_b, uint8_t clear_a, int requires_render, size_t command_count, size_t unsupported_command_count, int representable, const uint8_t *json, size_t json_len) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return (int)[object presentGpuSurfacePacketInWindow:window_id label:labelString ?: @"" surfaceWidth:surface_width height:surface_height scale:scale clearR:clear_r clearG:clear_g clearB:clear_b clearA:clear_a requiresRender:(requires_render != 0) commandCount:command_count unsupportedCommandCount:unsupported_command_count representable:(representable != 0) json:json byteLength:json_len];
}

int native_sdk_appkit_present_gpu_surface_packet_binary(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double surface_width, double surface_height, double scale, uint8_t clear_r, uint8_t clear_g, uint8_t clear_b, uint8_t clear_a, int requires_render, size_t command_count, size_t unsupported_command_count, int representable, const uint8_t *packet, size_t packet_len) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return (int)[object presentGpuSurfacePacketBinaryInWindow:window_id label:labelString ?: @"" surfaceWidth:surface_width height:surface_height scale:scale clearR:clear_r clearG:clear_g clearB:clear_b clearA:clear_a requiresRender:(requires_render != 0) commandCount:command_count unsupportedCommandCount:unsupported_command_count representable:(representable != 0) packet:packet byteLength:packet_len];
}

int native_sdk_appkit_request_gpu_surface_frame(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object requestGpuSurfaceFrameInWindow:window_id label:labelString ?: @""] ? 1 : 0;
}

int native_sdk_appkit_note_gpu_surface_input(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object noteGpuSurfaceInputInWindow:window_id label:labelString ?: @""] ? 1 : 0;
}

int native_sdk_appkit_set_gpu_surface_scroll_drivers(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, const native_sdk_appkit_scroll_driver_t *drivers, size_t count) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object setGpuSurfaceScrollDriversInWindow:window_id label:labelString ?: @"" drivers:drivers count:count] ? 1 : 0;
}

int native_sdk_appkit_show_context_menu(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, uint64_t token, const native_sdk_appkit_context_menu_item_t *items, size_t count) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object showContextMenuInWindow:window_id label:labelString ?: @"" x:x y:y token:token items:items count:count] ? 1 : 0;
}

int native_sdk_appkit_upload_gpu_surface_image(native_sdk_appkit_host_t *host, uint64_t image_id, size_t width, size_t height, const uint8_t *rgba8, size_t rgba8_len) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    return [object uploadGpuSurfaceImageWithId:image_id width:width height:height rgba8:rgba8 byteLength:rgba8_len] ? 1 : 0;
}

int native_sdk_appkit_remove_gpu_surface_image(native_sdk_appkit_host_t *host, uint64_t image_id) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    return [object removeGpuSurfaceImageWithId:image_id] ? 1 : 0;
}

int native_sdk_appkit_update_widget_accessibility(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, const native_sdk_appkit_widget_accessibility_node_t *nodes, size_t node_count) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object updateWidgetAccessibilityInWindow:window_id label:labelString ?: @"" nodes:nodes count:node_count] ? 1 : 0;
}

int native_sdk_appkit_create_webview(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len, double x, double y, double width, double height, int layer, int transparent, int bridge_enabled) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    NSString *urlString = url ? [[NSString alloc] initWithBytes:url length:url_len encoding:NSUTF8StringEncoding] : @"";
    return [object createWebViewInWindow:window_id label:labelString ?: @"" url:urlString ?: @"" x:x y:y width:width height:height layer:layer transparent:transparent != 0 bridgeEnabled:bridge_enabled != 0] ? 1 : 0;
}

int native_sdk_appkit_set_webview_frame(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object setWebViewFrameInWindow:window_id label:labelString ?: @"" x:x y:y width:width height:height] ? 1 : 0;
}

int native_sdk_appkit_navigate_webview(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    NSString *urlString = url ? [[NSString alloc] initWithBytes:url length:url_len encoding:NSUTF8StringEncoding] : @"";
    return [object navigateWebViewInWindow:window_id label:labelString ?: @"" url:urlString ?: @""] ? 1 : 0;
}

int native_sdk_appkit_set_webview_zoom(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double zoom) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object setWebViewZoomInWindow:window_id label:labelString ?: @"" zoom:zoom] ? 1 : 0;
}

int native_sdk_appkit_set_webview_layer(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int layer) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object setWebViewLayerInWindow:window_id label:labelString ?: @"" layer:layer] ? 1 : 0;
}

int native_sdk_appkit_close_webview(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object closeWebViewInWindow:window_id label:labelString ?: @""] ? 1 : 0;
}

size_t native_sdk_appkit_clipboard_read(native_sdk_appkit_host_t *host, char *buffer, size_t buffer_len) {
    return native_sdk_appkit_clipboard_read_data(host, "text/plain", strlen("text/plain"), buffer, buffer_len);
}

void native_sdk_appkit_clipboard_write(native_sdk_appkit_host_t *host, const char *text, size_t text_len) {
    (void)native_sdk_appkit_clipboard_write_data(host, "text/plain", strlen("text/plain"), text, text_len);
}

size_t native_sdk_appkit_clipboard_read_data(native_sdk_appkit_host_t *host, const char *mime_type, size_t mime_type_len, char *buffer, size_t buffer_len) {
    (void)host;
    NSString *type = NativeSdkPasteboardTypeForMime(mime_type, mime_type_len);
    if (!type || !buffer) return 0;
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    NSData *data = nil;
    if ([type isEqualToString:NSPasteboardTypeString] || [type isEqualToString:NSPasteboardTypeHTML]) {
        NSString *value = [pasteboard stringForType:type] ?: @"";
        data = [value dataUsingEncoding:NSUTF8StringEncoding];
    } else {
        data = [pasteboard dataForType:type] ?: [NSData data];
    }
    if (data.length > buffer_len) return data.length;
    size_t count = data.length;
    memcpy(buffer, data.bytes, count);
    return count;
}

int native_sdk_appkit_clipboard_write_data(native_sdk_appkit_host_t *host, const char *mime_type, size_t mime_type_len, const char *bytes, size_t bytes_len) {
    (void)host;
    NSString *type = NativeSdkPasteboardTypeForMime(mime_type, mime_type_len);
    if (!type || (!bytes && bytes_len > 0)) return 0;
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    if ([type isEqualToString:NSPasteboardTypeString] || [type isEqualToString:NSPasteboardTypeHTML]) {
        NSString *value = [[NSString alloc] initWithBytes:bytes length:bytes_len encoding:NSUTF8StringEncoding] ?: @"";
        return [pasteboard setString:value forType:type] ? 1 : 0;
    }
    NSData *data = [NSData dataWithBytes:bytes length:bytes_len];
    return [pasteboard setData:data forType:type] ? 1 : 0;
}

int native_sdk_appkit_show_notification(native_sdk_appkit_host_t *host, const char *title, size_t title_len, const char *subtitle, size_t subtitle_len, const char *body, size_t body_len) {
    (void)host;
    NSString *titleString = title ? [[NSString alloc] initWithBytes:title length:title_len encoding:NSUTF8StringEncoding] : @"";
    if (titleString.length == 0) return 0;
    NSString *subtitleString = subtitle ? [[NSString alloc] initWithBytes:subtitle length:subtitle_len encoding:NSUTF8StringEncoding] : @"";
    NSString *bodyString = body ? [[NSString alloc] initWithBytes:body length:body_len encoding:NSUTF8StringEncoding] : @"";
    NSUserNotification *notification = [[NSUserNotification alloc] init];
    notification.title = titleString;
    if (subtitleString.length > 0) notification.subtitle = subtitleString;
    if (bodyString.length > 0) notification.informativeText = bodyString;
    [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
    return 1;
}

int native_sdk_appkit_open_external_url(native_sdk_appkit_host_t *host, const char *url, size_t url_len) {
    (void)host;
    NSString *urlString = url ? [[NSString alloc] initWithBytes:url length:url_len encoding:NSUTF8StringEncoding] : @"";
    if (urlString.length == 0) return 0;
    NSURL *target = [NSURL URLWithString:urlString];
    if (!target || target.scheme.length == 0) return 0;
    return [[NSWorkspace sharedWorkspace] openURL:target] ? 1 : 0;
}

int native_sdk_appkit_reveal_path(native_sdk_appkit_host_t *host, const char *path, size_t path_len) {
    (void)host;
    NSString *pathString = path ? [[NSString alloc] initWithBytes:path length:path_len encoding:NSUTF8StringEncoding] : @"";
    if (pathString.length == 0) return 0;
    NSURL *fileURL = [NSURL fileURLWithPath:pathString];
    if (!fileURL) return 0;
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ fileURL ]];
    return 1;
}

int native_sdk_appkit_add_recent_document(native_sdk_appkit_host_t *host, const char *path, size_t path_len) {
    (void)host;
    NSString *pathString = path ? [[NSString alloc] initWithBytes:path length:path_len encoding:NSUTF8StringEncoding] : @"";
    if (pathString.length == 0) return 0;
    NSURL *fileURL = [NSURL fileURLWithPath:pathString];
    if (!fileURL) return 0;
    [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:fileURL];
    return 1;
}

int native_sdk_appkit_clear_recent_documents(native_sdk_appkit_host_t *host) {
    (void)host;
    [[NSDocumentController sharedDocumentController] clearRecentDocuments:nil];
    return 1;
}

int native_sdk_appkit_set_credential(native_sdk_appkit_host_t *host, const char *service, size_t service_len, const char *account, size_t account_len, const char *secret, size_t secret_len) {
    (void)host;
    @autoreleasepool {
        NSString *serviceString = NativeSdkStringFromBytes(service, service_len);
        NSString *accountString = NativeSdkStringFromBytes(account, account_len);
        if (serviceString.length == 0 || accountString.length == 0 || !secret || secret_len == 0) return 0;
        NSData *secretData = [NSData dataWithBytes:secret length:secret_len];
        NSMutableDictionary *query = NativeSdkCredentialQuery(serviceString, accountString);
        NSDictionary *update = @{ (__bridge id)kSecValueData: secretData };
        OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)update);
        if (status == errSecItemNotFound) {
            query[(__bridge id)kSecValueData] = secretData;
            status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
        }
        return status == errSecSuccess ? 1 : 0;
    }
}

size_t native_sdk_appkit_get_credential(native_sdk_appkit_host_t *host, const char *service, size_t service_len, const char *account, size_t account_len, char *buffer, size_t buffer_len) {
    (void)host;
    @autoreleasepool {
        NSString *serviceString = NativeSdkStringFromBytes(service, service_len);
        NSString *accountString = NativeSdkStringFromBytes(account, account_len);
        if (serviceString.length == 0 || accountString.length == 0 || !buffer) return 0;
        NSMutableDictionary *query = NativeSdkCredentialQuery(serviceString, accountString);
        query[(__bridge id)kSecReturnData] = @YES;
        query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        if (status != errSecSuccess || !result) return 0;
        NSData *data = CFBridgingRelease(result);
        if (data.length > buffer_len) return data.length;
        memcpy(buffer, data.bytes, data.length);
        return data.length;
    }
}

int native_sdk_appkit_delete_credential(native_sdk_appkit_host_t *host, const char *service, size_t service_len, const char *account, size_t account_len) {
    (void)host;
    @autoreleasepool {
        NSString *serviceString = NativeSdkStringFromBytes(service, service_len);
        NSString *accountString = NativeSdkStringFromBytes(account, account_len);
        if (serviceString.length == 0 || accountString.length == 0) return 0;
        NSMutableDictionary *query = NativeSdkCredentialQuery(serviceString, accountString);
        OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
        return status == errSecSuccess ? 1 : 0;
    }
}

static NSArray<NSString *> *NativeSdkParseExtensions(const char *extensions, size_t len) {
    if (!extensions || len == 0) return nil;
    NSString *str = [[NSString alloc] initWithBytes:extensions length:len encoding:NSUTF8StringEncoding];
    if (!str || str.length == 0) return nil;
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (NSString *ext in [str componentsSeparatedByString:@";"]) {
        NSString *trimmed = [ext stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (trimmed.length > 0) [result addObject:trimmed];
    }
    return result.count > 0 ? result : nil;
}

static void NativeSdkConfigurePanelExtensions(NSSavePanel *panel, NSArray<NSString *> *extensions) {
    if (!extensions || extensions.count == 0) return;
    if (@available(macOS 11.0, *)) {
        NSMutableArray *types = [NSMutableArray array];
        for (NSString *ext in extensions) {
            UTType *type = [UTType typeWithFilenameExtension:ext];
            if (type) [types addObject:type];
        }
        if (types.count > 0) panel.allowedContentTypes = types;
    }
}

native_sdk_appkit_open_dialog_result_t native_sdk_appkit_show_open_dialog(native_sdk_appkit_host_t *host, const native_sdk_appkit_open_dialog_opts_t *opts, char *buffer, size_t buffer_len) {
    (void)host;
    native_sdk_appkit_open_dialog_result_t result = { .count = 0, .bytes_written = 0 };
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        if (opts->title && opts->title_len > 0) {
            panel.title = [[NSString alloc] initWithBytes:opts->title length:opts->title_len encoding:NSUTF8StringEncoding];
        }
        if (opts->default_path && opts->default_path_len > 0) {
            NSString *path = [[NSString alloc] initWithBytes:opts->default_path length:opts->default_path_len encoding:NSUTF8StringEncoding];
            panel.directoryURL = [NSURL fileURLWithPath:path];
        }
        panel.canChooseFiles = YES;
        panel.canChooseDirectories = opts->allow_directories != 0;
        panel.allowsMultipleSelection = opts->allow_multiple != 0;
        NativeSdkConfigurePanelExtensions(panel, NativeSdkParseExtensions(opts->extensions, opts->extensions_len));

        if ([panel runModal] != NSModalResponseOK) return result;

        size_t offset = 0;
        BOOL overflow = NO;
        for (NSURL *url in panel.URLs) {
            NSString *path = url.path;
            NSData *data = [path dataUsingEncoding:NSUTF8StringEncoding];
            if (!data) continue;
            size_t needed = data.length + (result.count > 0 ? 1 : 0);
            if (needed > buffer_len - offset) {
                overflow = YES;
                break;
            }
            if (result.count > 0) { buffer[offset] = '\n'; offset++; }
            memcpy(buffer + offset, data.bytes, data.length);
            offset += data.length;
            result.count++;
        }
        result.bytes_written = overflow ? NativeSdkOverflowSize(buffer_len) : offset;
    }
    return result;
}

size_t native_sdk_appkit_show_save_dialog(native_sdk_appkit_host_t *host, const native_sdk_appkit_save_dialog_opts_t *opts, char *buffer, size_t buffer_len) {
    (void)host;
    @autoreleasepool {
        NSSavePanel *panel = [NSSavePanel savePanel];
        if (opts->title && opts->title_len > 0) {
            panel.title = [[NSString alloc] initWithBytes:opts->title length:opts->title_len encoding:NSUTF8StringEncoding];
        }
        if (opts->default_path && opts->default_path_len > 0) {
            NSString *path = [[NSString alloc] initWithBytes:opts->default_path length:opts->default_path_len encoding:NSUTF8StringEncoding];
            panel.directoryURL = [NSURL fileURLWithPath:path];
        }
        if (opts->default_name && opts->default_name_len > 0) {
            panel.nameFieldStringValue = [[NSString alloc] initWithBytes:opts->default_name length:opts->default_name_len encoding:NSUTF8StringEncoding];
        }
        NativeSdkConfigurePanelExtensions(panel, NativeSdkParseExtensions(opts->extensions, opts->extensions_len));

        if ([panel runModal] != NSModalResponseOK) return 0;

        NSString *path = panel.URL.path;
        NSData *data = [path dataUsingEncoding:NSUTF8StringEncoding];
        if (!data) return 0;
        size_t count = data.length;
        if (count > buffer_len) return NativeSdkOverflowSize(buffer_len);
        memcpy(buffer, data.bytes, count);
        return count;
    }
}

int native_sdk_appkit_show_message_dialog(native_sdk_appkit_host_t *host, const native_sdk_appkit_message_dialog_opts_t *opts) {
    (void)host;
    @autoreleasepool {
        NSAlert *alert = [[NSAlert alloc] init];
        switch (opts->style) {
            case 1: alert.alertStyle = NSAlertStyleWarning; break;
            case 2: alert.alertStyle = NSAlertStyleCritical; break;
            default: alert.alertStyle = NSAlertStyleInformational; break;
        }
        NSString *title = opts->title && opts->title_len > 0 ? [[NSString alloc] initWithBytes:opts->title length:opts->title_len encoding:NSUTF8StringEncoding] : nil;
        NSString *message = opts->message && opts->message_len > 0 ? [[NSString alloc] initWithBytes:opts->message length:opts->message_len encoding:NSUTF8StringEncoding] : nil;
        NSString *informative = opts->informative_text && opts->informative_text_len > 0 ? [[NSString alloc] initWithBytes:opts->informative_text length:opts->informative_text_len encoding:NSUTF8StringEncoding] : nil;
        if (message.length > 0) {
            alert.messageText = message;
        } else if (title.length > 0) {
            alert.messageText = title;
        }
        if (informative.length > 0) {
            alert.informativeText = informative;
        }
        if (opts->message && opts->message_len > 0) {
            alert.window.title = title.length > 0 ? title : @"";
        }
        if (opts->primary_button && opts->primary_button_len > 0) {
            [alert addButtonWithTitle:[[NSString alloc] initWithBytes:opts->primary_button length:opts->primary_button_len encoding:NSUTF8StringEncoding]];
        } else {
            [alert addButtonWithTitle:@"OK"];
        }
        if (opts->secondary_button && opts->secondary_button_len > 0) {
            [alert addButtonWithTitle:[[NSString alloc] initWithBytes:opts->secondary_button length:opts->secondary_button_len encoding:NSUTF8StringEncoding]];
        }
        if (opts->tertiary_button && opts->tertiary_button_len > 0) {
            [alert addButtonWithTitle:[[NSString alloc] initWithBytes:opts->tertiary_button length:opts->tertiary_button_len encoding:NSUTF8StringEncoding]];
        }

        NSModalResponse response = [alert runModal];
        if (response == NSAlertFirstButtonReturn) return 0;
        if (response == NSAlertSecondButtonReturn) return 1;
        return 2;
    }
}

void native_sdk_appkit_create_tray(native_sdk_appkit_host_t *host, const char *icon_path, size_t icon_path_len, const char *title, size_t title_len, const char *tooltip, size_t tooltip_len) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    @autoreleasepool {
        if (object.statusItem) {
            [[NSStatusBar systemStatusBar] removeStatusItem:object.statusItem];
        }
        // A titled menu-bar extra needs variable width; icon-only status
        // items keep the classic square well.
        BOOL hasTitle = title != NULL && title_len > 0;
        object.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:hasTitle ? NSVariableStatusItemLength : NSSquareStatusItemLength];

        if (icon_path && icon_path_len > 0) {
            NSString *path = [[NSString alloc] initWithBytes:icon_path length:icon_path_len encoding:NSUTF8StringEncoding];
            NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
            if (image) {
                image.template = YES;
                image.size = NSMakeSize(18, 18);
                object.statusItem.button.image = image;
            }
        }
        if (hasTitle) {
            object.statusItem.button.title = [[NSString alloc] initWithBytes:title length:title_len encoding:NSUTF8StringEncoding] ?: @"";
        }
        if (!object.statusItem.button.image && object.statusItem.button.title.length == 0) {
            object.statusItem.button.title = object.appName.length > 0 ? [object.appName substringToIndex:MIN(1, object.appName.length)] : @"Z";
        }
        if (tooltip && tooltip_len > 0) {
            object.statusItem.button.toolTip = [[NSString alloc] initWithBytes:tooltip length:tooltip_len encoding:NSUTF8StringEncoding];
        }
    }
}

void native_sdk_appkit_update_tray_menu(native_sdk_appkit_host_t *host, const uint32_t *item_ids, const char *const *labels, const size_t *label_lens, const int *separators, const int *enabled_flags, size_t count) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    @autoreleasepool {
        if (!object.statusItem) return;
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
        for (size_t i = 0; i < count; i++) {
            if (separators[i]) {
                [menu addItem:[NSMenuItem separatorItem]];
                continue;
            }
            NSString *label = labels[i] ? [[NSString alloc] initWithBytes:labels[i] length:label_lens[i] encoding:NSUTF8StringEncoding] : @"";
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:label ?: @""
                                                          action:@selector(trayMenuItemClicked:)
                                                   keyEquivalent:@""];
            item.tag = (NSInteger)item_ids[i];
            item.target = object;
            item.enabled = enabled_flags[i] != 0;
            [menu addItem:item];
        }
        object.statusItem.menu = menu;
    }
}

void native_sdk_appkit_update_tray_title(native_sdk_appkit_host_t *host, const char *title, size_t title_len) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    @autoreleasepool {
        if (!object.statusItem) return;
        BOOL hasTitle = title != NULL && title_len > 0;
        NSString *value = hasTitle ? ([[NSString alloc] initWithBytes:title length:title_len encoding:NSUTF8StringEncoding] ?: @"") : @"";
        object.statusItem.button.title = value;
        if (!object.statusItem.button.image && value.length == 0) {
            // Same fallback as create: a bare status item must still show
            // SOMETHING to stay clickable.
            object.statusItem.button.title = object.appName.length > 0 ? [object.appName substringToIndex:MIN(1, object.appName.length)] : @"Z";
        }
        // Titled extras need variable width; icon-only ones keep the
        // classic square well (mirrors create's length choice).
        object.statusItem.length = object.statusItem.button.title.length > 0 ? NSVariableStatusItemLength : NSSquareStatusItemLength;
    }
}

void native_sdk_appkit_remove_tray(native_sdk_appkit_host_t *host) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    if (object.statusItem) {
        [[NSStatusBar systemStatusBar] removeStatusItem:object.statusItem];
        object.statusItem = nil;
    }
}

void native_sdk_appkit_set_tray_callback(native_sdk_appkit_host_t *host, native_sdk_appkit_tray_callback_t callback, void *context) {
    NativeSdkAppKitHost *object = (__bridge NativeSdkAppKitHost *)host;
    object.trayCallback = callback;
    object.trayContext = context;
}
