#import "appkit_host.h"

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <WebKit/WebKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreText/CoreText.h>
#import <dispatch/dispatch.h>
#import <Security/Security.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

@class ZeroNativeAppKitHost;

static const NSUInteger ZeroNativeMaxChildWebViews = 16;
static const NSUInteger ZeroNativeMaxNativeViews = 32;
static const NSInteger ZeroNativeBridgeFrameKeepaliveFrames = 600;
static const NSTimeInterval ZeroNativeAutomationFramePollInterval = 0.05;
static const uint64_t ZeroNativeNanosecondsPerSecond = 1000000000ull;
static const uint32_t ZeroNativeShortcutModifierPrimary = 1u << 0;
static const uint32_t ZeroNativeShortcutModifierCommand = 1u << 1;
static const uint32_t ZeroNativeShortcutModifierControl = 1u << 2;
static const uint32_t ZeroNativeShortcutModifierOption = 1u << 3;
static const uint32_t ZeroNativeShortcutModifierShift = 1u << 4;
static void *ZeroNativeAppKitAppearanceObservationContext = &ZeroNativeAppKitAppearanceObservationContext;
static NSRect constrainFrame(NSRect frame);
static NSString *ZeroNativeAppKitBridgeScript(void);
static NSString *ZeroNativeMimeTypeForPath(NSString *path);
static NSString *ZeroNativeResolvedAssetRoot(NSString *rootPath);
static void ZeroNativeRegisterBundledFonts(void);
static NSString *ZeroNativeSafeAssetPath(NSURL *url, NSString *entryPath);
static NSURL *ZeroNativeAssetEntryURL(NSString *origin, NSString *entryPath);
static NSArray<NSString *> *ZeroNativePolicyListFromBytes(const char *bytes, size_t len, NSArray<NSString *> *fallback);
static NSString *ZeroNativeOriginForURL(NSURL *url);
static BOOL ZeroNativePolicyListMatches(NSArray<NSString *> *values, NSURL *url);
static NSString *ZeroNativeShortcutKeyForEvent(NSEvent *event);
static BOOL ZeroNativeShortcutUsesImplicitShift(NSString *key, NSEvent *event);
static BOOL ZeroNativeShortcutModifiersMatch(uint32_t shortcutModifiers, NSEventModifierFlags eventModifiers, BOOL allowImplicitShift);
static NSEventModifierFlags ZeroNativeMenuModifierFlags(uint32_t modifiers);
static uint32_t ZeroNativeModifierFlagsForEvent(NSEvent *event);
static uint64_t ZeroNativeTimestampNanoseconds(void);
static uint64_t ZeroNativeRetainedFrameIntervalNanoseconds(NSScreen *screen);
static NSAccessibilityRole ZeroNativeAccessibilityRoleForNativeViewKind(NSInteger kind);
static NSAccessibilityRole ZeroNativeAccessibilityRoleForWidgetRole(NSInteger role);
static NSCursor *ZeroNativeCursorForKind(NSInteger kind);
static NSRange ZeroNativeClampedRange(NSUInteger start, NSUInteger end, NSUInteger length);
static NSString *ZeroNativeSubstringForRange(NSString *value, NSRange range);
static NSString *ZeroNativeStringFromTextInput(id value);
static int ZeroNativeAppKitColorSchemeForAppearance(NSAppearance *appearance);
static BOOL ZeroNativeAppKitReduceMotionEnabled(void);
static BOOL ZeroNativeAppKitHighContrastEnabled(void);

static size_t ZeroNativeOverflowSize(size_t buffer_len) {
    return buffer_len == SIZE_MAX ? SIZE_MAX : buffer_len + 1;
}

static NSString *ZeroNativeStringFromBytes(const char *bytes, size_t len) {
    if (!bytes || len == 0) return nil;
    return [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
}

static NSString *ZeroNativeStringFromTextInput(id value) {
    if (!value) return @"";
    if ([value isKindOfClass:[NSAttributedString class]]) return ((NSAttributedString *)value).string ?: @"";
    if ([value isKindOfClass:[NSString class]]) return (NSString *)value;
    return [value description] ?: @"";
}

static int ZeroNativeAppKitColorSchemeForAppearance(NSAppearance *appearance) {
    NSAppearance *effective = appearance ?: NSApp.effectiveAppearance;
    NSString *bestMatch = [effective bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    return [bestMatch isEqualToString:NSAppearanceNameDarkAqua] ? ZERO_NATIVE_APPKIT_COLOR_SCHEME_DARK : ZERO_NATIVE_APPKIT_COLOR_SCHEME_LIGHT;
}

static BOOL ZeroNativeAppKitReduceMotionEnabled(void) {
    return [NSWorkspace sharedWorkspace].accessibilityDisplayShouldReduceMotion;
}

static BOOL ZeroNativeAppKitHighContrastEnabled(void) {
    return [NSWorkspace sharedWorkspace].accessibilityDisplayShouldIncreaseContrast;
}

static uint64_t ZeroNativeTimestampNanoseconds(void) {
    return (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000000000.0);
}

static uint64_t ZeroNativeRetainedFrameIntervalNanoseconds(NSScreen *screen) {
    NSInteger framesPerSecond = screen ? screen.maximumFramesPerSecond : 0;
    if (framesPerSecond <= 0) framesPerSecond = 60;
    framesPerSecond = MAX(30, MIN(120, framesPerSecond));
    return ZeroNativeNanosecondsPerSecond / (uint64_t)framesPerSecond;
}

static uint32_t ZeroNativeModifierFlagsForEvent(NSEvent *event) {
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    uint32_t modifiers = 0;
    if ((flags & NSEventModifierFlagCommand) != 0) {
        modifiers |= ZeroNativeShortcutModifierPrimary;
        modifiers |= ZeroNativeShortcutModifierCommand;
    }
    if ((flags & NSEventModifierFlagControl) != 0) modifiers |= ZeroNativeShortcutModifierControl;
    if ((flags & NSEventModifierFlagOption) != 0) modifiers |= ZeroNativeShortcutModifierOption;
    if ((flags & NSEventModifierFlagShift) != 0) modifiers |= ZeroNativeShortcutModifierShift;
    return modifiers;
}

static NSString *ZeroNativePasteboardTypeForMime(const char *mime_type, size_t mime_type_len) {
    NSString *mime = ZeroNativeStringFromBytes(mime_type, mime_type_len).lowercaseString;
    if ([mime isEqualToString:@"text"] || [mime isEqualToString:@"text/plain"]) return NSPasteboardTypeString;
    if ([mime isEqualToString:@"text/html"]) return NSPasteboardTypeHTML;
    if ([mime isEqualToString:@"text/rtf"] || [mime isEqualToString:@"application/rtf"]) return NSPasteboardTypeRTF;
    return nil;
}

static NSAccessibilityRole ZeroNativeAccessibilityRoleForNativeViewKind(NSInteger kind) {
    switch (kind) {
        case ZERO_NATIVE_APPKIT_VIEW_TOOLBAR:
        case ZERO_NATIVE_APPKIT_VIEW_TITLEBAR_ACCESSORY:
            return NSAccessibilityToolbarRole;
        case ZERO_NATIVE_APPKIT_VIEW_SPLIT:
            return NSAccessibilitySplitterRole;
        case ZERO_NATIVE_APPKIT_VIEW_BUTTON:
        case ZERO_NATIVE_APPKIT_VIEW_ICON_BUTTON:
        case ZERO_NATIVE_APPKIT_VIEW_LIST_ITEM:
        case ZERO_NATIVE_APPKIT_VIEW_TOGGLE:
            return NSAccessibilityButtonRole;
        case ZERO_NATIVE_APPKIT_VIEW_CHECKBOX:
            return NSAccessibilityCheckBoxRole;
        case ZERO_NATIVE_APPKIT_VIEW_SEGMENTED_CONTROL:
            return NSAccessibilityRadioGroupRole;
        case ZERO_NATIVE_APPKIT_VIEW_TEXT_FIELD:
        case ZERO_NATIVE_APPKIT_VIEW_SEARCH_FIELD:
            return NSAccessibilityTextFieldRole;
        case ZERO_NATIVE_APPKIT_VIEW_LABEL:
            return NSAccessibilityStaticTextRole;
        case ZERO_NATIVE_APPKIT_VIEW_PROGRESS_INDICATOR:
            return NSAccessibilityProgressIndicatorRole;
        case ZERO_NATIVE_APPKIT_VIEW_GPU_SURFACE:
        case ZERO_NATIVE_APPKIT_VIEW_STATUSBAR:
        case ZERO_NATIVE_APPKIT_VIEW_SIDEBAR:
        case ZERO_NATIVE_APPKIT_VIEW_STACK:
        case ZERO_NATIVE_APPKIT_VIEW_SPACER:
            return NSAccessibilityGroupRole;
        default:
            return NSAccessibilityUnknownRole;
    }
}

static NSAccessibilityRole ZeroNativeAccessibilityRoleForWidgetRole(NSInteger role) {
    switch (role) {
        case ZERO_NATIVE_APPKIT_WIDGET_ROLE_TEXT:
            return NSAccessibilityStaticTextRole;
        case ZERO_NATIVE_APPKIT_WIDGET_ROLE_IMAGE:
            return NSAccessibilityImageRole;
        case ZERO_NATIVE_APPKIT_WIDGET_ROLE_BUTTON:
        case ZERO_NATIVE_APPKIT_WIDGET_ROLE_TAB:
            return NSAccessibilityButtonRole;
        case ZERO_NATIVE_APPKIT_WIDGET_ROLE_TEXTBOX:
            return NSAccessibilityTextFieldRole;
        case ZERO_NATIVE_APPKIT_WIDGET_ROLE_CHECKBOX:
        case ZERO_NATIVE_APPKIT_WIDGET_ROLE_SWITCH:
            return NSAccessibilityCheckBoxRole;
        case ZERO_NATIVE_APPKIT_WIDGET_ROLE_RADIO:
            return NSAccessibilityRadioButtonRole;
        case ZERO_NATIVE_APPKIT_WIDGET_ROLE_MENU:
            return NSAccessibilityMenuRole;
        case ZERO_NATIVE_APPKIT_WIDGET_ROLE_MENUITEM:
            return NSAccessibilityMenuItemRole;
        case ZERO_NATIVE_APPKIT_WIDGET_ROLE_LIST:
            return NSAccessibilityListRole;
        case ZERO_NATIVE_APPKIT_WIDGET_ROLE_ROW:
            return NSAccessibilityRowRole;
        case ZERO_NATIVE_APPKIT_WIDGET_ROLE_GRID:
            return NSAccessibilityTableRole;
        case ZERO_NATIVE_APPKIT_WIDGET_ROLE_GRIDCELL:
            return NSAccessibilityCellRole;
        case ZERO_NATIVE_APPKIT_WIDGET_ROLE_SLIDER:
            return NSAccessibilitySliderRole;
        case ZERO_NATIVE_APPKIT_WIDGET_ROLE_PROGRESSBAR:
            return NSAccessibilityProgressIndicatorRole;
        case ZERO_NATIVE_APPKIT_WIDGET_ROLE_TOOLTIP:
        case ZERO_NATIVE_APPKIT_WIDGET_ROLE_DIALOG:
        case ZERO_NATIVE_APPKIT_WIDGET_ROLE_GROUP:
        case ZERO_NATIVE_APPKIT_WIDGET_ROLE_LISTITEM:
        case ZERO_NATIVE_APPKIT_WIDGET_ROLE_NONE:
        default:
            return NSAccessibilityGroupRole;
    }
}

static NSCursor *ZeroNativeCursorForKind(NSInteger kind) {
    switch (kind) {
        case ZERO_NATIVE_APPKIT_CURSOR_POINTING_HAND: return [NSCursor pointingHandCursor];
        case ZERO_NATIVE_APPKIT_CURSOR_TEXT: return [NSCursor IBeamCursor];
        case ZERO_NATIVE_APPKIT_CURSOR_RESIZE_HORIZONTAL: return [NSCursor resizeLeftRightCursor];
        case ZERO_NATIVE_APPKIT_CURSOR_ARROW:
        default:
            return [NSCursor arrowCursor];
    }
}

static NSRange ZeroNativeClampedRange(NSUInteger start, NSUInteger end, NSUInteger length) {
    NSUInteger clampedStart = MIN(start, length);
    NSUInteger clampedEnd = MIN(end, length);
    if (clampedEnd < clampedStart) {
        NSUInteger temp = clampedStart;
        clampedStart = clampedEnd;
        clampedEnd = temp;
    }
    return NSMakeRange(clampedStart, clampedEnd - clampedStart);
}

static NSUInteger ZeroNativeRangeEnd(NSRange range) {
    if (range.location == NSNotFound) return 0;
    if (range.length > NSUIntegerMax - range.location) return NSUIntegerMax;
    return range.location + range.length;
}

static NSString *ZeroNativeSubstringForRange(NSString *value, NSRange range) {
    if (range.location > value.length || NSMaxRange(range) > value.length) return @"";
    return [value substringWithRange:range];
}

static NSMutableDictionary *ZeroNativeCredentialQuery(NSString *service, NSString *account) {
    return [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account,
    } mutableCopy];
}

@interface ZeroNativeWindowDelegate : NSObject <NSWindowDelegate>
@property(nonatomic, assign) ZeroNativeAppKitHost *host;
@property(nonatomic, assign) uint64_t windowId;
@end

@interface ZeroNativeWebView : WKWebView <NSDraggingDestination>
@property(nonatomic, strong) NSArray<NSValue *> *coveredMouseRects;
@property(nonatomic, assign) ZeroNativeAppKitHost *host;
@property(nonatomic, assign) uint64_t windowId;
@end

@interface ZeroNativeBridgeScriptHandler : NSObject <WKScriptMessageHandler>
@property(nonatomic, assign) ZeroNativeAppKitHost *host;
@property(nonatomic, assign) uint64_t windowId;
@property(nonatomic, strong) NSString *webViewLabel;
@end

@class ZeroNativeMetalSurfaceView;

@interface ZeroNativeWidgetAccessibilityElement : NSAccessibilityElement
@property(nonatomic, assign) ZeroNativeMetalSurfaceView *surfaceView;
@property(nonatomic, assign) uint64_t widgetId;
@property(nonatomic, assign) uint32_t actionFlags;
- (BOOL)emitSetTextAccessibilityValue:(id)value;
- (BOOL)emitSetSelectionAccessibilityValue:(id)value;
@end

@interface ZeroNativeMetalSurfaceView : NSView <NSTextInputClient>
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property(nonatomic, strong) CAMetalLayer *metalLayer;
@property(nonatomic, strong) id<MTLBuffer> sampleBuffer;
@property(nonatomic, strong) id<MTLTexture> canvasTexture;
@property(nonatomic, strong) id<MTLRenderPipelineState> canvasRenderPipeline;
@property(nonatomic, strong) id<MTLSamplerState> canvasSampler;
@property(nonatomic, assign) CGColorSpaceRef canvasColorSpace;
@property(nonatomic, strong) NSTimer *displayTimer;
@property(nonatomic, assign) ZeroNativeAppKitHost *host;
@property(nonatomic, assign) uint64_t windowId;
@property(nonatomic, strong) NSString *surfaceLabel;
@property(nonatomic, assign) NSUInteger frameIndex;
@property(nonatomic, assign) BOOL renderedFrame;
@property(nonatomic, assign) BOOL verifiedNonblankFrame;
@property(nonatomic, assign) uint32_t lastSampleColor;
@property(nonatomic, assign) CGSize lastDrawableSize;
@property(nonatomic, assign) CGFloat lastScale;
@property(nonatomic, assign) NSUInteger canvasTextureWidth;
@property(nonatomic, assign) NSUInteger canvasTextureHeight;
@property(nonatomic, assign) BOOL hasCanvasTexture;
@property(nonatomic, assign) BOOL retainedFrameRequestPending;
@property(nonatomic, assign) uint64_t retainedFrameLastEmitNs;
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
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *canvasImageCache;
@property(nonatomic, strong) NSCursor *surfaceCursor;
@property(nonatomic, strong) NSTrackingArea *surfaceTrackingArea;
@property(nonatomic, copy) NSString *markedText;
@property(nonatomic, assign) NSRange markedTextRange;
@property(nonatomic, assign) NSRange selectedTextRange;
@property(nonatomic, assign) BOOL interpretedKeyEventEmittedInput;
@property(nonatomic, strong) NSArray<NSAccessibilityElement *> *widgetAccessibilityElements;
- (void)configureWithHost:(ZeroNativeAppKitHost *)host windowId:(uint64_t)windowId label:(NSString *)label;
- (BOOL)isAvailable;
- (void)updateDrawableSize;
- (BOOL)presentPixelsWithWidth:(NSUInteger)width height:(NSUInteger)height scale:(CGFloat)scale hasDirtyRect:(BOOL)hasDirtyRect dirtyX:(CGFloat)dirtyX dirtyY:(CGFloat)dirtyY dirtyWidth:(CGFloat)dirtyWidth dirtyHeight:(CGFloat)dirtyHeight rgba8:(const uint8_t *)rgba8 byteLength:(NSUInteger)byteLength;
- (NSInteger)presentGpuPacketWithSurfaceWidth:(CGFloat)surfaceWidth height:(CGFloat)surfaceHeight scale:(CGFloat)scale clearR:(uint8_t)clearR clearG:(uint8_t)clearG clearB:(uint8_t)clearB clearA:(uint8_t)clearA requiresRender:(BOOL)requiresRender commandCount:(NSUInteger)commandCount unsupportedCommandCount:(NSUInteger)unsupportedCommandCount representable:(BOOL)representable json:(const uint8_t *)json byteLength:(NSUInteger)byteLength;
- (BOOL)ensureCanvasPresenter;
- (void)updateWidgetAccessibilityWithNodes:(const zero_native_appkit_widget_accessibility_node_t *)nodes count:(NSUInteger)count;
- (void)stopDisplayTimer;
- (void)requestRetainedCanvasFrame;
- (void)emitRetainedCanvasFrameRequest;
- (void)renderFrame;
- (void)emitFrameEventWithFrameIndex:(NSUInteger)frameIndex sampleColor:(uint32_t)sampleColor nonblank:(BOOL)nonblank;
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
@end

@interface ZeroNativeAssetSchemeHandler : NSObject <WKURLSchemeHandler>
@property(nonatomic, strong) NSString *rootPath;
@property(nonatomic, strong) NSString *entryPath;
@property(nonatomic, assign) BOOL spaFallback;
- (void)configureWithRootPath:(NSString *)rootPath entryPath:(NSString *)entryPath spaFallback:(BOOL)spaFallback;
@end

@interface ZeroNativeShortcut : NSObject
@property(nonatomic, strong) NSString *identifier;
@property(nonatomic, strong) NSString *key;
@property(nonatomic, assign) uint32_t modifiers;
@end

@interface ZeroNativeAppKitHost : NSObject <WKNavigationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) ZeroNativeWindowDelegate *delegate;
@property(nonatomic, strong) ZeroNativeBridgeScriptHandler *bridgeScriptHandler;
@property(nonatomic, strong) ZeroNativeAssetSchemeHandler *assetSchemeHandler;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSWindow *> *windows;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, WKWebView *> *webViews;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, ZeroNativeWindowDelegate *> *delegates;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, ZeroNativeBridgeScriptHandler *> *bridgeScriptHandlers;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, ZeroNativeAssetSchemeHandler *> *assetSchemeHandlers;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *windowLabels;
@property(nonatomic, strong) NSMutableDictionary<NSString *, WKWebView *> *childWebViews;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSView *> *nativeViews;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *nativeViewCommands;
@property(nonatomic, strong) NSMutableSet<NSString *> *nativeViewExplicitTextKeys;
@property(nonatomic, strong) NSMutableSet<NSString *> *bridgeEnabledChildWebViewKeys;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSTimer *automationFrameTimer;
@property(nonatomic, strong) NSString *appName;
@property(nonatomic, strong) NSString *bundleIdentifier;
@property(nonatomic, strong) NSString *iconPath;
@property(nonatomic, strong) NSString *windowLabel;
@property(nonatomic, assign) zero_native_appkit_event_callback_t callback;
@property(nonatomic, assign) zero_native_appkit_bridge_callback_t bridgeCallback;
@property(nonatomic, assign) void *context;
@property(nonatomic, assign) void *bridgeContext;
@property(nonatomic, assign) BOOL didShutdown;
@property(nonatomic, assign) BOOL observesApplicationActivation;
@property(nonatomic, assign) BOOL observesAppearanceChanges;
@property(nonatomic, assign) NSInteger bridgeFrameKeepalive;
@property(nonatomic, strong) id shortcutEventMonitor;
@property(nonatomic, strong) NSArray<ZeroNativeShortcut *> *shortcuts;
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, assign) zero_native_appkit_tray_callback_t trayCallback;
@property(nonatomic, assign) void *trayContext;
@property(nonatomic, strong) NSArray<NSString *> *allowedNavigationOrigins;
@property(nonatomic, strong) NSArray<NSString *> *allowedExternalURLs;
@property(nonatomic, assign) NSInteger externalLinkAction;
- (instancetype)initWithAppName:(NSString *)appName windowTitle:(NSString *)windowTitle bundleIdentifier:(NSString *)bundleIdentifier iconPath:(NSString *)iconPath windowLabel:(NSString *)windowLabel x:(double)x y:(double)y width:(double)width height:(double)height restoreFrame:(BOOL)restoreFrame;
- (BOOL)createWindowWithId:(uint64_t)windowId title:(NSString *)title label:(NSString *)label x:(double)x y:(double)y width:(double)width height:(double)height restoreFrame:(BOOL)restoreFrame makeMain:(BOOL)makeMain;
- (void)focusWindowWithId:(uint64_t)windowId;
- (void)closeWindowWithId:(uint64_t)windowId;
- (WKWebView *)webViewForWindowId:(uint64_t)windowId;
- (WKWebView *)mainWebViewForWindow:(NSWindow *)window;
- (ZeroNativeAssetSchemeHandler *)assetHandlerForWindowId:(uint64_t)windowId;
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
- (BOOL)requestGpuSurfaceFrameInWindow:(uint64_t)windowId label:(NSString *)label;
- (BOOL)updateWidgetAccessibilityInWindow:(uint64_t)windowId label:(NSString *)label nodes:(const zero_native_appkit_widget_accessibility_node_t *)nodes count:(NSUInteger)count;
- (BOOL)nativeView:(NSView *)candidate isInSubtreeRootedAt:(NSView *)root;
- (NSArray<NSString *> *)nativeViewKeysInSubtreeForWindow:(uint64_t)windowId rootKey:(NSString *)rootKey;
- (BOOL)closeNativeViewInWindow:(uint64_t)windowId label:(NSString *)label;
- (void)closeNativeViewsInWindow:(uint64_t)windowId;
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
- (void)runWithCallback:(zero_native_appkit_event_callback_t)callback context:(void *)context;
- (void)stop;
- (void)emitEvent:(zero_native_appkit_event_t)event;
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
- (void)setAutomationFramePolling:(BOOL)enabled;
- (void)emitAutomationFramePoll;
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

@implementation ZeroNativeWindowDelegate

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

- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
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
    if (self.host.windows.count == 0) {
        [self.host emitShutdown];
        [self.host stop];
    }
}

@end

@implementation ZeroNativeWebView

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

@implementation ZeroNativeBridgeScriptHandler

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)userContentController;
    [self.host receiveBridgeMessage:message windowId:self.windowId webViewLabel:self.webViewLabel ?: @"main"];
}

@end

@implementation ZeroNativeWidgetAccessibilityElement

- (NSArray *)accessibilityActionNames {
    if (!self.accessibilityEnabled) return @[];
    NSMutableArray *actions = [NSMutableArray arrayWithCapacity:3];
    if ((self.actionFlags & (ZERO_NATIVE_APPKIT_WIDGET_ACTION_PRESS |
                             ZERO_NATIVE_APPKIT_WIDGET_ACTION_TOGGLE |
                             ZERO_NATIVE_APPKIT_WIDGET_ACTION_SELECT |
                             ZERO_NATIVE_APPKIT_WIDGET_ACTION_FOCUS)) != 0) {
        [actions addObject:NSAccessibilityPressAction];
    }
    if ((self.actionFlags & ZERO_NATIVE_APPKIT_WIDGET_ACTION_INCREMENT) != 0) {
        [actions addObject:NSAccessibilityIncrementAction];
    }
    if ((self.actionFlags & ZERO_NATIVE_APPKIT_WIDGET_ACTION_DECREMENT) != 0) {
        [actions addObject:NSAccessibilityDecrementAction];
    }
    if ((self.actionFlags & ZERO_NATIVE_APPKIT_WIDGET_ACTION_DISMISS) != 0) {
        [actions addObject:NSAccessibilityCancelAction];
    }
    return actions;
}

- (BOOL)accessibilityPerformPress {
    if (!self.accessibilityEnabled) return NO;
    if ((self.actionFlags & ZERO_NATIVE_APPKIT_WIDGET_ACTION_TOGGLE) != 0) {
        return [self.surfaceView emitWidgetAccessibilityActionWithId:self.widgetId action:ZERO_NATIVE_APPKIT_WIDGET_ACCESSIBILITY_ACTION_TOGGLE];
    }
    if ((self.actionFlags & ZERO_NATIVE_APPKIT_WIDGET_ACTION_PRESS) != 0) {
        return [self.surfaceView emitWidgetAccessibilityActionWithId:self.widgetId action:ZERO_NATIVE_APPKIT_WIDGET_ACCESSIBILITY_ACTION_PRESS];
    }
    if ((self.actionFlags & ZERO_NATIVE_APPKIT_WIDGET_ACTION_SELECT) != 0) {
        return [self.surfaceView emitWidgetAccessibilityActionWithId:self.widgetId action:ZERO_NATIVE_APPKIT_WIDGET_ACCESSIBILITY_ACTION_SELECT];
    }
    if ((self.actionFlags & ZERO_NATIVE_APPKIT_WIDGET_ACTION_FOCUS) != 0) {
        return [self.surfaceView emitWidgetAccessibilityActionWithId:self.widgetId action:ZERO_NATIVE_APPKIT_WIDGET_ACCESSIBILITY_ACTION_FOCUS];
    }
    return NO;
}

- (BOOL)accessibilityPerformIncrement {
    if (!self.accessibilityEnabled || (self.actionFlags & ZERO_NATIVE_APPKIT_WIDGET_ACTION_INCREMENT) == 0) return NO;
    return [self.surfaceView emitWidgetAccessibilityActionWithId:self.widgetId action:ZERO_NATIVE_APPKIT_WIDGET_ACCESSIBILITY_ACTION_INCREMENT];
}

- (BOOL)accessibilityPerformDecrement {
    if (!self.accessibilityEnabled || (self.actionFlags & ZERO_NATIVE_APPKIT_WIDGET_ACTION_DECREMENT) == 0) return NO;
    return [self.surfaceView emitWidgetAccessibilityActionWithId:self.widgetId action:ZERO_NATIVE_APPKIT_WIDGET_ACCESSIBILITY_ACTION_DECREMENT];
}

- (BOOL)accessibilityPerformCancel {
    if (!self.accessibilityEnabled || (self.actionFlags & ZERO_NATIVE_APPKIT_WIDGET_ACTION_DISMISS) == 0) return NO;
    return [self.surfaceView emitWidgetAccessibilityActionWithId:self.widgetId action:ZERO_NATIVE_APPKIT_WIDGET_ACCESSIBILITY_ACTION_DISMISS];
}

- (BOOL)accessibilityIsAttributeSettable:(NSAccessibilityAttributeName)attribute {
    if (self.accessibilityEnabled && [attribute isEqualToString:NSAccessibilityValueAttribute]) {
        return (self.actionFlags & ZERO_NATIVE_APPKIT_WIDGET_ACTION_SET_TEXT) != 0;
    }
    if (self.accessibilityEnabled &&
        ([attribute isEqualToString:NSAccessibilitySelectedTextRangeAttribute] ||
         [attribute isEqualToString:NSAccessibilitySelectedTextRangesAttribute])) {
        return (self.actionFlags & ZERO_NATIVE_APPKIT_WIDGET_ACTION_SET_SELECTION) != 0;
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
    if (!self.accessibilityEnabled || (self.actionFlags & ZERO_NATIVE_APPKIT_WIDGET_ACTION_SET_TEXT) == 0) return NO;
    NSString *text = @"";
    if ([value isKindOfClass:[NSString class]]) {
        text = (NSString *)value;
    } else if (value) {
        text = [value description] ?: @"";
    }
    return [self.surfaceView emitWidgetAccessibilityActionWithId:self.widgetId
                                                          action:ZERO_NATIVE_APPKIT_WIDGET_ACCESSIBILITY_ACTION_SET_TEXT
                                                            text:text
                                                   selectedRange:NSMakeRange(0, 0)
                                                hasSelectedRange:NO];
}

- (BOOL)emitSetSelectionAccessibilityValue:(id)value {
    if (!self.accessibilityEnabled || (self.actionFlags & ZERO_NATIVE_APPKIT_WIDGET_ACTION_SET_SELECTION) == 0) return NO;
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
                                                          action:ZERO_NATIVE_APPKIT_WIDGET_ACCESSIBILITY_ACTION_SET_SELECTION
                                                            text:@""
                                                   selectedRange:selectedRange
                                                hasSelectedRange:YES];
}

@end

static CGFloat ZeroNativePacketNumber(id value, CGFloat fallback) {
    return [value respondsToSelector:@selector(doubleValue)] ? (CGFloat)[value doubleValue] : fallback;
}

static NSArray *ZeroNativePacketArray(id value, NSUInteger minCount) {
    if (![value isKindOfClass:[NSArray class]]) return nil;
    NSArray *array = (NSArray *)value;
    return array.count >= minCount ? array : nil;
}

static NSDictionary *ZeroNativePacketDictionary(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? (NSDictionary *)value : nil;
}

static NSRect ZeroNativePacketRect(id value) {
    NSArray *array = ZeroNativePacketArray(value, 4);
    if (!array) return NSZeroRect;
    return NSMakeRect(
        ZeroNativePacketNumber(array[0], 0),
        ZeroNativePacketNumber(array[1], 0),
        ZeroNativePacketNumber(array[2], 0),
        ZeroNativePacketNumber(array[3], 0)
    );
}

static BOOL ZeroNativePacketRectIntersects(NSRect a, NSRect b) {
    a = CGRectStandardize(a);
    b = CGRectStandardize(b);
    if (NSIsEmptyRect(a) || NSIsEmptyRect(b)) return NO;
    return !NSIsEmptyRect(NSIntersectionRect(a, b));
}

static NSPoint ZeroNativePacketPoint(id value) {
    NSArray *array = ZeroNativePacketArray(value, 2);
    if (!array) return NSZeroPoint;
    return NSMakePoint(ZeroNativePacketNumber(array[0], 0), ZeroNativePacketNumber(array[1], 0));
}

static BOOL ZeroNativePacketReadPoint(id value, NSPoint *point) {
    NSArray *array = ZeroNativePacketArray(value, 2);
    if (!array || !point) return NO;
    *point = NSMakePoint(ZeroNativePacketNumber(array[0], 0), ZeroNativePacketNumber(array[1], 0));
    return YES;
}

static CGFloat ZeroNativePacketRadiusAt(id value, NSUInteger index, CGFloat maximum) {
    NSArray *array = ZeroNativePacketArray(value, 1);
    if (!array) return 0;
    id radiusValue = index < array.count ? array[index] : array[0];
    return fmax(0.0, fmin(maximum, ZeroNativePacketNumber(radiusValue, 0)));
}

static NSColor *ZeroNativePacketColor(id value, CGFloat opacity) {
    NSArray *array = ZeroNativePacketArray(value, 4);
    if (!array) return nil;
    CGFloat red = fmax(0.0, fmin(1.0, ZeroNativePacketNumber(array[0], 0)));
    CGFloat green = fmax(0.0, fmin(1.0, ZeroNativePacketNumber(array[1], 0)));
    CGFloat blue = fmax(0.0, fmin(1.0, ZeroNativePacketNumber(array[2], 0)));
    CGFloat alpha = fmax(0.0, fmin(1.0, ZeroNativePacketNumber(array[3], 1) * opacity));
    return [NSColor colorWithDeviceRed:red green:green blue:blue alpha:alpha];
}

static NSBezierPath *ZeroNativePacketRoundedRectPath(NSRect rect, id radiusValue) {
    rect = CGRectStandardize(rect);
    CGFloat maxRadius = fmax(0.0, fmin(rect.size.width, rect.size.height) * 0.5);
    CGFloat topLeft = ZeroNativePacketRadiusAt(radiusValue, 0, maxRadius);
    CGFloat topRight = ZeroNativePacketRadiusAt(radiusValue, 1, maxRadius);
    CGFloat bottomRight = ZeroNativePacketRadiusAt(radiusValue, 2, maxRadius);
    CGFloat bottomLeft = ZeroNativePacketRadiusAt(radiusValue, 3, maxRadius);
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

static NSBezierPath *ZeroNativePacketShapePath(NSDictionary *shape) {
    if (!shape) return nil;
    NSString *kind = [shape[@"kind"] isKindOfClass:[NSString class]] ? shape[@"kind"] : @"";
    if ([kind isEqualToString:@"path"]) {
        NSArray *elements = ZeroNativePacketArray(shape[@"path"], 0);
        if (!elements) return nil;
        NSBezierPath *path = [NSBezierPath bezierPath];
        BOOL hasCurrentPoint = NO;
        NSPoint currentPoint = NSZeroPoint;
        NSPoint subpathStart = NSZeroPoint;
        for (id elementObject in elements) {
            NSDictionary *element = ZeroNativePacketDictionary(elementObject);
            if (!element) return nil;
            NSString *verb = [element[@"verb"] isKindOfClass:[NSString class]] ? element[@"verb"] : @"";
            NSArray *points = ZeroNativePacketArray(element[@"points"], 0);
            if (!points) return nil;
            if ([verb isEqualToString:@"move_to"]) {
                NSPoint point = NSZeroPoint;
                if (points.count < 1 || !ZeroNativePacketReadPoint(points[0], &point)) return nil;
                [path moveToPoint:point];
                currentPoint = point;
                subpathStart = point;
                hasCurrentPoint = YES;
            } else if ([verb isEqualToString:@"line_to"]) {
                NSPoint point = NSZeroPoint;
                if (!hasCurrentPoint || points.count < 1 || !ZeroNativePacketReadPoint(points[0], &point)) return nil;
                [path lineToPoint:point];
                currentPoint = point;
            } else if ([verb isEqualToString:@"quad_to"]) {
                NSPoint control = NSZeroPoint;
                NSPoint end = NSZeroPoint;
                if (!hasCurrentPoint || points.count < 2 || !ZeroNativePacketReadPoint(points[0], &control) || !ZeroNativePacketReadPoint(points[1], &end)) return nil;
                NSPoint control1 = NSMakePoint(currentPoint.x + (control.x - currentPoint.x) * 2.0 / 3.0, currentPoint.y + (control.y - currentPoint.y) * 2.0 / 3.0);
                NSPoint control2 = NSMakePoint(end.x + (control.x - end.x) * 2.0 / 3.0, end.y + (control.y - end.y) * 2.0 / 3.0);
                [path curveToPoint:end controlPoint1:control1 controlPoint2:control2];
                currentPoint = end;
            } else if ([verb isEqualToString:@"cubic_to"]) {
                NSPoint control1 = NSZeroPoint;
                NSPoint control2 = NSZeroPoint;
                NSPoint end = NSZeroPoint;
                if (!hasCurrentPoint || points.count < 3 || !ZeroNativePacketReadPoint(points[0], &control1) || !ZeroNativePacketReadPoint(points[1], &control2) || !ZeroNativePacketReadPoint(points[2], &end)) return nil;
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
        return [NSBezierPath bezierPathWithRect:ZeroNativePacketRect(shape[@"rect"])];
    }
    if ([kind isEqualToString:@"rounded_rect"] || [kind isEqualToString:@"stroke_rect"]) {
        NSRect rect = ZeroNativePacketRect(shape[@"rect"]);
        return ZeroNativePacketRoundedRectPath(rect, shape[@"radius"]);
    }
    if ([kind isEqualToString:@"line"]) {
        NSBezierPath *path = [NSBezierPath bezierPath];
        [path moveToPoint:ZeroNativePacketPoint(shape[@"from"])];
        [path lineToPoint:ZeroNativePacketPoint(shape[@"to"])];
        path.lineWidth = MAX(1, ZeroNativePacketNumber(shape[@"width"], 1));
        return path;
    }
    return nil;
}

static BOOL ZeroNativePacketDrawPaintedPath(NSBezierPath *path, NSDictionary *paint, CGFloat opacity, BOOL stroke) {
    if (!path || !paint) return NO;
    NSString *kind = [paint[@"kind"] isKindOfClass:[NSString class]] ? paint[@"kind"] : @"";
    if ([kind isEqualToString:@"color"]) {
        NSColor *color = ZeroNativePacketColor(paint[@"color"], opacity);
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
        NSArray *stops = ZeroNativePacketArray(paint[@"stops"], 1);
        if (!stops) return NO;
        NSUInteger count = MIN(stops.count, 16);
        NSMutableArray<NSColor *> *colors = [NSMutableArray arrayWithCapacity:count];
        CGFloat locations[16] = {0};
        for (NSUInteger index = 0; index < count; index++) {
            NSDictionary *stop = ZeroNativePacketDictionary(stops[index]);
            if (!stop) return NO;
            NSColor *color = ZeroNativePacketColor(stop[@"color"], opacity);
            if (!color) return NO;
            [colors addObject:color];
            locations[index] = fmax(0.0, fmin(1.0, ZeroNativePacketNumber(stop[@"offset"], (CGFloat)index / (CGFloat)MAX(1, count - 1))));
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
        [gradient drawFromPoint:ZeroNativePacketPoint(paint[@"start"]) toPoint:ZeroNativePacketPoint(paint[@"end"]) options:0];
        [NSGraphicsContext restoreGraphicsState];
        return YES;
    }
    return NO;
}

static NSPoint ZeroNativePacketTransformPoint(id value, NSPoint point) {
    NSArray *array = ZeroNativePacketArray(value, 6);
    if (!array) return point;
    CGFloat a = ZeroNativePacketNumber(array[0], 1);
    CGFloat b = ZeroNativePacketNumber(array[1], 0);
    CGFloat c = ZeroNativePacketNumber(array[2], 0);
    CGFloat d = ZeroNativePacketNumber(array[3], 1);
    CGFloat tx = ZeroNativePacketNumber(array[4], 0);
    CGFloat ty = ZeroNativePacketNumber(array[5], 0);
    return NSMakePoint(a * point.x + c * point.y + tx, b * point.x + d * point.y + ty);
}

static NSRect ZeroNativePacketTransformRect(id value, NSRect rect) {
    NSArray *array = ZeroNativePacketArray(value, 6);
    if (!array) return rect;
    rect = CGRectStandardize(rect);
    NSPoint points[4] = {
        ZeroNativePacketTransformPoint(array, NSMakePoint(NSMinX(rect), NSMinY(rect))),
        ZeroNativePacketTransformPoint(array, NSMakePoint(NSMaxX(rect), NSMinY(rect))),
        ZeroNativePacketTransformPoint(array, NSMakePoint(NSMaxX(rect), NSMaxY(rect))),
        ZeroNativePacketTransformPoint(array, NSMakePoint(NSMinX(rect), NSMaxY(rect))),
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

static CGFloat ZeroNativePacketTransformScale(id value) {
    NSArray *array = ZeroNativePacketArray(value, 6);
    if (!array) return 1;
    CGFloat a = ZeroNativePacketNumber(array[0], 1);
    CGFloat b = ZeroNativePacketNumber(array[1], 0);
    CGFloat c = ZeroNativePacketNumber(array[2], 0);
    CGFloat d = ZeroNativePacketNumber(array[3], 1);
    CGFloat xScale = sqrt(a * a + b * b);
    CGFloat yScale = sqrt(c * c + d * d);
    return fmax(0.0001, fmax(xScale, yScale));
}

static BOOL ZeroNativePacketApplyBlur(NSDictionary *effect, CGFloat opacity, CGContextRef context, CGFloat scale, id transformValue, BOOL hasClip, NSRect clipRect) {
    if (!effect || !context) return NO;
    void *contextData = CGBitmapContextGetData(context);
    if (!contextData) return NO;
    const size_t width = CGBitmapContextGetWidth(context);
    const size_t height = CGBitmapContextGetHeight(context);
    const size_t bytesPerRow = CGBitmapContextGetBytesPerRow(context);
    if (width == 0 || height == 0 || bytesPerRow < width * 4) return NO;

    NSRect rect = CGRectStandardize(ZeroNativePacketTransformRect(transformValue, ZeroNativePacketRect(effect[@"rect"])));
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

    NSUInteger radius = (NSUInteger)llround(fmax(0.0, ZeroNativePacketNumber(effect[@"radius"], 0) * normalizedScale * ZeroNativePacketTransformScale(transformValue)));
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

    for (NSUInteger y = expandedMinY; y < expandedMaxY; y++) {
        for (NSUInteger x = minX; x < maxX; x++) {
            NSUInteger sampleMinX = x > radius ? x - radius : 0;
            NSUInteger sampleMaxX = MIN((NSUInteger)width - 1, x + radius);
            uint64_t sums[4] = {0, 0, 0, 0};
            for (NSUInteger sx = sampleMinX; sx <= sampleMaxX; sx++) {
                const uint8_t *pixel = source + (y - expandedMinY) * regionBytesPerRow + (sx - expandedMinX) * 4;
                sums[0] += pixel[0];
                sums[1] += pixel[1];
                sums[2] += pixel[2];
                sums[3] += pixel[3];
            }
            NSUInteger count = sampleMaxX - sampleMinX + 1;
            uint8_t *out = horizontal + (y - expandedMinY) * regionBytesPerRow + (x - expandedMinX) * 4;
            out[0] = (uint8_t)(sums[0] / count);
            out[1] = (uint8_t)(sums[1] / count);
            out[2] = (uint8_t)(sums[2] / count);
            out[3] = (uint8_t)(sums[3] / count);
        }
    }

    for (NSUInteger y = minY; y < maxY; y++) {
        for (NSUInteger x = minX; x < maxX; x++) {
            NSUInteger sampleMinY = y > radius ? y - radius : 0;
            NSUInteger sampleMaxY = MIN((NSUInteger)height - 1, y + radius);
            uint64_t sums[4] = {0, 0, 0, 0};
            for (NSUInteger sy = sampleMinY; sy <= sampleMaxY; sy++) {
                const uint8_t *pixel = horizontal + (sy - expandedMinY) * regionBytesPerRow + (x - expandedMinX) * 4;
                sums[0] += pixel[0];
                sums[1] += pixel[1];
                sums[2] += pixel[2];
                sums[3] += pixel[3];
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

static NSLineBreakMode ZeroNativePacketTextLineBreakMode(NSString *wrap) {
    if ([wrap isEqualToString:@"none"]) return NSLineBreakByClipping;
    if ([wrap isEqualToString:@"character"]) return NSLineBreakByCharWrapping;
    return NSLineBreakByWordWrapping;
}

static NSTextAlignment ZeroNativePacketTextAlignment(NSString *align) {
    if ([align isEqualToString:@"center"]) return NSTextAlignmentCenter;
    if ([align isEqualToString:@"end"]) return NSTextAlignmentRight;
    return NSTextAlignmentNatural;
}

static NSFont *ZeroNativePacketPreferredFont(NSDictionary *text, CGFloat size) {
    NSNumber *fontId = [text[@"font"] isKindOfClass:[NSNumber class]] ? text[@"font"] : nil;
    unsigned long long value = fontId ? fontId.unsignedLongLongValue : 1;
    NSArray<NSString *> *candidates = value == 2
        ? @[ @"Geist Mono", @"GeistMono-Regular", @"Geist Mono Regular" ]
        : @[ @"Geist", @"Geist-Regular", @"Geist Sans", @"Geist Sans Regular" ];
    for (NSString *name in candidates) {
        NSFont *font = [NSFont fontWithName:name size:size];
        if (font) return font;
    }
    if (value == 2) return [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
    return [NSFont systemFontOfSize:size];
}

static BOOL ZeroNativePacketDrawText(NSDictionary *text, CGFloat opacity) {
    if (!text) return NO;
    NSString *value = [text[@"text"] isKindOfClass:[NSString class]] ? text[@"text"] : @"";
    NSColor *color = ZeroNativePacketColor(text[@"color"], opacity);
    if (!color) return NO;
    CGFloat size = MAX(1, ZeroNativePacketNumber(text[@"size"], 12));
    NSFont *font = ZeroNativePacketPreferredFont(text, size);
    NSPoint origin = ZeroNativePacketPoint(text[@"origin"]);
    NSDictionary *baseAttributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
    };
    NSDictionary *layout = ZeroNativePacketDictionary(text[@"layout"]);
    if (!layout) {
        [value drawAtPoint:NSMakePoint(origin.x, origin.y - size) withAttributes:baseAttributes];
        return YES;
    }

    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    NSString *wrap = [layout[@"wrap"] isKindOfClass:[NSString class]] ? layout[@"wrap"] : @"word";
    NSString *align = [layout[@"align"] isKindOfClass:[NSString class]] ? layout[@"align"] : @"start";
    paragraph.lineBreakMode = ZeroNativePacketTextLineBreakMode(wrap);
    paragraph.alignment = ZeroNativePacketTextAlignment(align);
    CGFloat lineHeight = ZeroNativePacketNumber(layout[@"lineHeight"], 0);
    if (lineHeight > 0) {
        paragraph.minimumLineHeight = lineHeight;
        paragraph.maximumLineHeight = lineHeight;
    }

    NSMutableDictionary *attributes = [baseAttributes mutableCopy];
    attributes[NSParagraphStyleAttributeName] = paragraph;
    CGFloat maxWidth = ZeroNativePacketNumber(layout[@"maxWidth"], 0);
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

static BOOL ZeroNativePacketDrawEffect(NSDictionary *effect, CGFloat opacity, CGContextRef context, CGFloat scale, id transformValue, BOOL hasClip, NSRect clipRect) {
    if (!effect) return NO;
    NSString *kind = [effect[@"kind"] isKindOfClass:[NSString class]] ? effect[@"kind"] : @"";
    if ([kind isEqualToString:@"blur"]) {
        return ZeroNativePacketApplyBlur(effect, opacity, context, scale, transformValue, hasClip, clipRect);
    }
    if ([kind isEqualToString:@"shadow"]) {
        NSColor *color = ZeroNativePacketColor(effect[@"color"], opacity);
        if (!color) return NO;
        NSRect rect = ZeroNativePacketRect(effect[@"rect"]);
        NSArray *offset = ZeroNativePacketArray(effect[@"offset"], 2);
        NSSize shadowOffset = offset ? NSMakeSize(ZeroNativePacketNumber(offset[0], 0), ZeroNativePacketNumber(offset[1], 0)) : NSZeroSize;
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowColor = color;
        shadow.shadowOffset = shadowOffset;
        shadow.shadowBlurRadius = MAX(0, ZeroNativePacketNumber(effect[@"blur"], 0));
        NSBezierPath *path = ZeroNativePacketRoundedRectPath(rect, effect[@"radius"]);
        [NSGraphicsContext saveGraphicsState];
        [shadow set];
        [[color colorWithAlphaComponent:0.01] setFill];
        [path fill];
        [NSGraphicsContext restoreGraphicsState];
        return YES;
    }
    return NO;
}

static BOOL ZeroNativePacketApplyTransform(id value) {
    NSArray *array = ZeroNativePacketArray(value, 6);
    if (!array) return YES;
    NSAffineTransformStruct transform = {
        .m11 = ZeroNativePacketNumber(array[0], 1),
        .m12 = ZeroNativePacketNumber(array[1], 0),
        .m21 = ZeroNativePacketNumber(array[2], 0),
        .m22 = ZeroNativePacketNumber(array[3], 1),
        .tX = ZeroNativePacketNumber(array[4], 0),
        .tY = ZeroNativePacketNumber(array[5], 0),
    };
    NSAffineTransform *affine = [NSAffineTransform transform];
    [affine setTransformStruct:transform];
    [affine concat];
    return YES;
}

static NSString *ZeroNativePacketImageCacheKey(id value) {
    if (![value respondsToSelector:@selector(unsignedLongLongValue)]) return nil;
    return [NSString stringWithFormat:@"%llu", [value unsignedLongLongValue]];
}

static NSRect ZeroNativePacketNormalizedRect(NSRect rect) {
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

static NSData *ZeroNativePacketImagePixelData(NSArray *pixels, NSUInteger byteLength) {
    if (!pixels || pixels.count < byteLength) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:byteLength];
    if (!data) return nil;
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger index = 0; index < byteLength; index++) {
        bytes[index] = (uint8_t)llround(fmax(0.0, fmin(255.0, ZeroNativePacketNumber(pixels[index], 0))));
    }
    return data;
}

static NSImage *ZeroNativePacketCreateImage(NSDictionary *image) {
    if (!image) return nil;
    NSUInteger width = (NSUInteger)llround(ZeroNativePacketNumber(image[@"width"], 0));
    NSUInteger height = (NSUInteger)llround(ZeroNativePacketNumber(image[@"height"], 0));
    if (width == 0 || height == 0 || width > 8192 || height > 8192) return nil;
    if (width > NSUIntegerMax / height || width * height > NSUIntegerMax / 4) return nil;
    NSUInteger byteLength = width * height * 4;
    NSData *pixelData = ZeroNativePacketImagePixelData(ZeroNativePacketArray(image[@"pixels"], byteLength), byteLength);
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

static BOOL ZeroNativePacketApplyImageActions(NSArray *actions, NSArray *images, NSMutableDictionary<NSString *, NSImage *> *imageCache) {
    if (!imageCache) return NO;
    for (id actionObject in actions ?: @[]) {
        NSDictionary *action = ZeroNativePacketDictionary(actionObject);
        if (!action) return NO;
        NSString *kind = [action[@"kind"] isKindOfClass:[NSString class]] ? action[@"kind"] : @"";
        if ([kind isEqualToString:@"upload"]) {
            NSInteger imageIndex = [action[@"imageIndex"] respondsToSelector:@selector(integerValue)] ? [action[@"imageIndex"] integerValue] : -1;
            if (imageIndex < 0 || (NSUInteger)imageIndex >= images.count) return NO;
            NSDictionary *image = ZeroNativePacketDictionary(images[(NSUInteger)imageIndex]);
            NSString *cacheKey = ZeroNativePacketImageCacheKey(image[@"imageId"]);
            NSImage *decoded = ZeroNativePacketCreateImage(image);
            if (!cacheKey || !decoded) return NO;
            imageCache[cacheKey] = decoded;
        } else if ([kind isEqualToString:@"evict"]) {
            NSDictionary *key = ZeroNativePacketDictionary(action[@"key"]);
            NSString *cacheKey = ZeroNativePacketImageCacheKey(key[@"imageId"]);
            if (cacheKey) [imageCache removeObjectForKey:cacheKey];
        } else if ([kind isEqualToString:@"retain"]) {
            continue;
        } else {
            return NO;
        }
    }
    return YES;
}

static NSRect ZeroNativePacketImageSourceRect(NSDictionary *packetImage, NSImage *image) {
    NSRect full = NSMakeRect(0, 0, image.size.width, image.size.height);
    NSArray *src = ZeroNativePacketArray(packetImage[@"src"], 4);
    if (!src) return full;
    NSRect requested = ZeroNativePacketNormalizedRect(ZeroNativePacketRect(src));
    NSRect clipped = NSIntersectionRect(requested, full);
    return clipped;
}

static NSRect ZeroNativePacketImageDestinationRect(NSRect dst, NSRect src, NSString *fit) {
    NSRect normalized = ZeroNativePacketNormalizedRect(dst);
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

static BOOL ZeroNativePacketDrawImage(NSDictionary *packetImage, NSDictionary<NSString *, NSImage *> *imageCache, CGFloat opacity) {
    if (!packetImage || !imageCache) return NO;
    NSString *cacheKey = ZeroNativePacketImageCacheKey(packetImage[@"image"]);
    NSImage *image = cacheKey ? imageCache[cacheKey] : nil;
    if (!image) return NO;
    NSRect src = ZeroNativePacketImageSourceRect(packetImage, image);
    if (src.size.width <= 0 || src.size.height <= 0) return NO;
    NSString *fit = [packetImage[@"fit"] isKindOfClass:[NSString class]] ? packetImage[@"fit"] : @"stretch";
    NSRect dst = ZeroNativePacketImageDestinationRect(ZeroNativePacketRect(packetImage[@"dst"]), src, fit);
    if (dst.size.width <= 0 || dst.size.height <= 0) return NO;

    CGFloat imageOpacity = fmax(0.0, fmin(1.0, ZeroNativePacketNumber(packetImage[@"opacity"], 1)));
    NSString *sampling = [packetImage[@"sampling"] isKindOfClass:[NSString class]] ? packetImage[@"sampling"] : @"linear";
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext.currentContext setImageInterpolation:[sampling isEqualToString:@"nearest"] ? NSImageInterpolationNone : NSImageInterpolationHigh];
    [image drawInRect:dst fromRect:src operation:NSCompositingOperationSourceOver fraction:(opacity * imageOpacity) respectFlipped:YES hints:nil];
    [NSGraphicsContext restoreGraphicsState];
    return YES;
}

static BOOL ZeroNativePacketDrawCommand(NSDictionary *command, CGContextRef context, CGFloat scale, BOOL hasClip, NSRect clipRect, NSDictionary<NSString *, NSImage *> *imageCache) {
    if (!command) return NO;
    if (hasClip) {
        NSArray *bounds = ZeroNativePacketArray(command[@"bounds"], 4);
        if (bounds && !ZeroNativePacketRectIntersects(ZeroNativePacketRect(bounds), clipRect)) return YES;
    }

    NSString *kind = [command[@"kind"] isKindOfClass:[NSString class]] ? command[@"kind"] : @"";
    CGFloat opacity = fmax(0.0, fmin(1.0, ZeroNativePacketNumber(command[@"opacity"], 1)));
    id clip = command[@"clip"];
    BOOL hasEffectiveClip = hasClip;
    NSRect effectiveClip = clipRect;

    [NSGraphicsContext saveGraphicsState];
    if (hasClip) {
        [NSBezierPath clipRect:clipRect];
    }
    if ([clip isKindOfClass:[NSArray class]]) {
        NSRect commandClip = ZeroNativePacketRect(clip);
        [NSBezierPath clipRect:commandClip];
        effectiveClip = hasEffectiveClip ? NSIntersectionRect(effectiveClip, commandClip) : commandClip;
        hasEffectiveClip = YES;
    }
    if (!ZeroNativePacketApplyTransform(command[@"transform"])) {
        [NSGraphicsContext restoreGraphicsState];
        return NO;
    }

    BOOL ok = YES;
    if ([kind hasPrefix:@"fill_rect"] || [kind hasPrefix:@"fill_rounded_rect"]) {
        ok = ZeroNativePacketDrawPaintedPath(ZeroNativePacketShapePath(ZeroNativePacketDictionary(command[@"shape"])), ZeroNativePacketDictionary(command[@"paint"]), opacity, NO);
    } else if ([kind hasPrefix:@"stroke_rect"]) {
        NSBezierPath *path = ZeroNativePacketShapePath(ZeroNativePacketDictionary(command[@"shape"]));
        path.lineWidth = MAX(1, ZeroNativePacketNumber(command[@"strokeWidth"], path.lineWidth));
        ok = ZeroNativePacketDrawPaintedPath(path, ZeroNativePacketDictionary(command[@"paint"]), opacity, YES);
    } else if ([kind hasPrefix:@"draw_line"]) {
        ok = ZeroNativePacketDrawPaintedPath(ZeroNativePacketShapePath(ZeroNativePacketDictionary(command[@"shape"])), ZeroNativePacketDictionary(command[@"paint"]), opacity, YES);
    } else if ([kind isEqualToString:@"fill_path"]) {
        ok = ZeroNativePacketDrawPaintedPath(ZeroNativePacketShapePath(ZeroNativePacketDictionary(command[@"shape"])), ZeroNativePacketDictionary(command[@"paint"]), opacity, NO);
    } else if ([kind isEqualToString:@"stroke_path"]) {
        NSBezierPath *path = ZeroNativePacketShapePath(ZeroNativePacketDictionary(command[@"shape"]));
        path.lineWidth = MAX(1, ZeroNativePacketNumber(command[@"strokeWidth"], path.lineWidth));
        ok = ZeroNativePacketDrawPaintedPath(path, ZeroNativePacketDictionary(command[@"paint"]), opacity, YES);
    } else if ([kind isEqualToString:@"draw_text"]) {
        ok = ZeroNativePacketDrawText(ZeroNativePacketDictionary(command[@"text"]), opacity);
    } else if ([kind isEqualToString:@"shadow"] || [kind isEqualToString:@"blur"]) {
        ok = ZeroNativePacketDrawEffect(ZeroNativePacketDictionary(command[@"effect"]), opacity, context, scale, command[@"transform"], hasEffectiveClip, effectiveClip);
    } else if ([kind isEqualToString:@"draw_image"]) {
        ok = ZeroNativePacketDrawImage(ZeroNativePacketDictionary(command[@"image"]), imageCache, opacity);
    } else {
        ok = NO;
    }

    [NSGraphicsContext restoreGraphicsState];
    return ok;
}

@implementation ZeroNativeMetalSurfaceView

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
    _displayTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 60.0) target:self selector:@selector(renderFrame) userInfo:nil repeats:YES];
    _displayTimer.tolerance = 1.0 / 240.0;
    [self renderFrame];
    return self;
}

- (void)configureWithHost:(ZeroNativeAppKitHost *)host windowId:(uint64_t)windowId label:(NSString *)label {
    self.host = host;
    self.windowId = windowId;
    self.surfaceLabel = label ?: @"";
    __weak ZeroNativeMetalSurfaceView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ZeroNativeMetalSurfaceView *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf updateDrawableSize];
        [strongSelf emitResizeEvent];
        [strongSelf renderFrame];
    });
}

- (void)dealloc {
    [self stopDisplayTimer];
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

- (BOOL)presentPixelsWithWidth:(NSUInteger)width height:(NSUInteger)height scale:(CGFloat)scale hasDirtyRect:(BOOL)hasDirtyRect dirtyX:(CGFloat)dirtyX dirtyY:(CGFloat)dirtyY dirtyWidth:(CGFloat)dirtyWidth dirtyHeight:(CGFloat)dirtyHeight rgba8:(const uint8_t *)rgba8 byteLength:(NSUInteger)byteLength {
    if (![self isAvailable] || !rgba8 || width == 0 || height == 0) return NO;
    if (byteLength != width * height * 4) return NO;
    if (![self ensureCanvasPresenter]) return NO;

    BOOL textureChanged = NO;
    if (!self.canvasTexture || self.canvasTextureWidth != width || self.canvasTextureHeight != height) {
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModeShared;
        self.canvasTexture = [self.device newTextureWithDescriptor:descriptor];
        self.canvasTextureWidth = width;
        self.canvasTextureHeight = height;
        textureChanged = YES;
    }
    if (!self.canvasTexture) return NO;

    BOOL uploadFullTexture = textureChanged || !hasDirtyRect || scale <= 0 || dirtyWidth <= 0 || dirtyHeight <= 0;
    NSUInteger uploadX = 0;
    NSUInteger uploadY = 0;
    NSUInteger uploadWidth = width;
    NSUInteger uploadHeight = height;
    if (!uploadFullTexture) {
        CGFloat minX = floor(dirtyX * scale);
        CGFloat minY = floor(dirtyY * scale);
        CGFloat maxX = ceil((dirtyX + dirtyWidth) * scale);
        CGFloat maxY = ceil((dirtyY + dirtyHeight) * scale);
        minX = fmax(0.0, fmin((CGFloat)width, minX));
        minY = fmax(0.0, fmin((CGFloat)height, minY));
        maxX = fmax(minX, fmin((CGFloat)width, maxX));
        maxY = fmax(minY, fmin((CGFloat)height, maxY));
        uploadX = (NSUInteger)minX;
        uploadY = (NSUInteger)minY;
        uploadWidth = (NSUInteger)(maxX - minX);
        uploadHeight = (NSUInteger)(maxY - minY);
        if (uploadWidth == 0 || uploadHeight == 0) return YES;
    }

    const uint8_t *uploadBytes = rgba8 + ((uploadY * width + uploadX) * 4);
    [self.canvasTexture replaceRegion:MTLRegionMake2D(uploadX, uploadY, uploadWidth, uploadHeight)
                          mipmapLevel:0
                            withBytes:uploadBytes
                          bytesPerRow:width * 4];
    if (!self.canvasPacketPixels || self.canvasPacketPixelWidth != width || self.canvasPacketPixelHeight != height || self.canvasPacketPixels.length != byteLength) {
        self.canvasPacketPixels = [NSMutableData dataWithLength:byteLength];
        self.canvasPacketPixelWidth = width;
        self.canvasPacketPixelHeight = height;
    }
    if (self.canvasPacketPixels && self.canvasPacketPixels.length == byteLength) {
        void *backingBytes = self.canvasPacketPixels.mutableBytes;
        if ((const void *)backingBytes != (const void *)rgba8) {
            if (uploadFullTexture) {
                memcpy(backingBytes, rgba8, byteLength);
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
    CGFloat normalizedScale = scale > 0 ? scale : 1;
    NSUInteger pixelWidth = (NSUInteger)ceil(surfaceWidth * normalizedScale);
    NSUInteger pixelHeight = (NSUInteger)ceil(surfaceHeight * normalizedScale);
    if (pixelWidth == 0 || pixelHeight == 0) return 0;
    if (pixelWidth > 8192 || pixelHeight > 8192) return 0;

    NSData *packetData = [NSData dataWithBytes:json length:byteLength];
    NSError *jsonError = nil;
    id packetObject = [NSJSONSerialization JSONObjectWithData:packetData options:0 error:&jsonError];
    NSDictionary *packet = ZeroNativePacketDictionary(packetObject);
    if (!packet || jsonError) return 0;
    NSString *loadAction = [packet[@"loadAction"] isKindOfClass:[NSString class]] ? packet[@"loadAction"] : @"";
    BOOL clearLoadAction = [loadAction isEqualToString:@"clear"];
    BOOL retainedLoadAction = [loadAction isEqualToString:@"load"];
    if (!clearLoadAction && !retainedLoadAction) return 0;
    NSArray *commands = ZeroNativePacketArray(packet[@"commands"], 0);
    if (!commands) return 0;
    if (commandCount != 0 && commands.count != commandCount) return 0;
    NSArray *images = ZeroNativePacketArray(packet[@"images"], 0) ?: @[];
    NSArray *imageActions = ZeroNativePacketArray(packet[@"imageActions"], 0) ?: @[];
    if (!self.canvasImageCache) self.canvasImageCache = [NSMutableDictionary dictionary];
    if (!ZeroNativePacketApplyImageActions(imageActions, images, self.canvasImageCache)) return 0;
    NSArray *scissor = ZeroNativePacketArray(packet[@"scissorBounds"], 4);
    BOOL hasScissor = scissor != nil;
    NSRect scissorRect = hasScissor ? ZeroNativePacketRect(scissor) : NSZeroRect;

    NSUInteger byteLengthRequired = pixelWidth * pixelHeight * 4;
    NSMutableData *pixels = nil;
    BOOL directRetainedDirtyUpdate = retainedLoadAction && hasScissor;
    if (clearLoadAction) {
        pixels = [NSMutableData dataWithLength:byteLengthRequired];
    } else {
        if (!self.canvasPacketPixels || self.canvasPacketPixelWidth != pixelWidth || self.canvasPacketPixelHeight != pixelHeight || self.canvasPacketPixels.length != byteLengthRequired) return 0;
        pixels = directRetainedDirtyUpdate ? self.canvasPacketPixels : [self.canvasPacketPixels mutableCopy];
    }
    if (!pixels || pixels.length != byteLengthRequired) return -1;
    if (!self.canvasColorSpace) self.canvasColorSpace = CGColorSpaceCreateDeviceRGB();
    if (!self.canvasColorSpace) return -1;
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, pixelWidth, pixelHeight, 8, pixelWidth * 4, self.canvasColorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!context) return -1;

    CGContextSetAllowsAntialiasing(context, true);
    CGContextSetShouldAntialias(context, true);
    CGContextTranslateCTM(context, 0, (CGFloat)pixelHeight);
    CGContextScaleCTM(context, normalizedScale, -normalizedScale);

    NSGraphicsContext *graphics = [NSGraphicsContext graphicsContextWithCGContext:context flipped:YES];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:graphics];
    if (clearLoadAction) {
        [[NSColor colorWithDeviceRed:(CGFloat)clearR / 255.0 green:(CGFloat)clearG / 255.0 blue:(CGFloat)clearB / 255.0 alpha:(CGFloat)clearA / 255.0] setFill];
        NSRectFill(NSMakeRect(0, 0, surfaceWidth, surfaceHeight));
    } else if (retainedLoadAction && hasScissor) {
        [[NSColor colorWithDeviceRed:(CGFloat)clearR / 255.0 green:(CGFloat)clearG / 255.0 blue:(CGFloat)clearB / 255.0 alpha:(CGFloat)clearA / 255.0] setFill];
        NSRectFill(scissorRect);
    }
    if (hasScissor) {
        [NSBezierPath clipRect:scissorRect];
    }

    BOOL supported = YES;
    for (id commandObject in commands) {
        NSDictionary *command = ZeroNativePacketDictionary(commandObject);
        if (!ZeroNativePacketDrawCommand(command, context, normalizedScale, hasScissor, scissorRect, self.canvasImageCache)) {
            supported = NO;
            break;
        }
    }
    [NSGraphicsContext restoreGraphicsState];
    CGContextRelease(context);
    if (!supported) return 0;

    BOOL uploadDirtyRect = retainedLoadAction && hasScissor;
    return [self presentPixelsWithWidth:pixelWidth height:pixelHeight scale:normalizedScale hasDirtyRect:uploadDirtyRect dirtyX:scissorRect.origin.x dirtyY:scissorRect.origin.y dirtyWidth:scissorRect.size.width dirtyHeight:scissorRect.size.height rgba8:(const uint8_t *)pixels.bytes byteLength:pixels.length] ? 1 : -1;
}

- (BOOL)ensureCanvasPresenter {
    if (self.canvasRenderPipeline && self.canvasSampler) return YES;
    if (!self.device || !self.metalLayer) return NO;

    static NSString *shaderSource =
        @"#include <metal_stdlib>\n"
        @"using namespace metal;\n"
        @"struct ZeroNativeCanvasVertexOut { float4 position [[position]]; float2 uv; };\n"
        @"vertex ZeroNativeCanvasVertexOut zero_native_canvas_vertex(uint vertex_id [[vertex_id]]) {\n"
        @"  constexpr float2 positions[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };\n"
        @"  constexpr float2 uvs[4] = { float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0) };\n"
        @"  ZeroNativeCanvasVertexOut out;\n"
        @"  out.position = float4(positions[vertex_id], 0.0, 1.0);\n"
        @"  out.uv = uvs[vertex_id];\n"
        @"  return out;\n"
        @"}\n"
        @"fragment float4 zero_native_canvas_fragment(ZeroNativeCanvasVertexOut in [[stage_in]], texture2d<float> canvas_texture [[texture(0)]], sampler texture_sampler [[sampler(0)]]) {\n"
        @"  return canvas_texture.sample(texture_sampler, in.uv);\n"
        @"}\n";

    NSError *libraryError = nil;
    id<MTLLibrary> library = [self.device newLibraryWithSource:shaderSource options:nil error:&libraryError];
    if (!library) return NO;
    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"zero_native_canvas_vertex"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"zero_native_canvas_fragment"];
    if (!vertexFunction || !fragmentFunction) return NO;

    MTLRenderPipelineDescriptor *pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDescriptor.label = @"zero-native canvas presenter";
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

- (void)updateWidgetAccessibilityWithNodes:(const zero_native_appkit_widget_accessibility_node_t *)nodes count:(NSUInteger)count {
    if (!nodes || count == 0) {
        self.widgetAccessibilityElements = @[];
        NSAccessibilityPostNotification(self, NSAccessibilityLayoutChangedNotification);
        return;
    }

    NSMutableArray<NSAccessibilityElement *> *elements = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        const zero_native_appkit_widget_accessibility_node_t node = nodes[index];
        NSString *label = ZeroNativeStringFromBytes(node.label, node.label_len) ?: @"";
        NSString *textValue = ZeroNativeStringFromBytes(node.text_value, node.text_value_len) ?: @"";
        NSString *placeholder = ZeroNativeStringFromBytes(node.placeholder, node.placeholder_len) ?: @"";
        NSString *name = label.length > 0 ? label : textValue;
        ZeroNativeWidgetAccessibilityElement *element = [[ZeroNativeWidgetAccessibilityElement alloc] init];
        element.surfaceView = self;
        element.widgetId = node.id;
        element.actionFlags = node.action_flags;
        element.accessibilityParent = self;
        element.accessibilityRole = ZeroNativeAccessibilityRoleForWidgetRole(node.role);
        element.accessibilityIdentifier = [NSString stringWithFormat:@"zero-native-widget-%llu", node.id];
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
            if (node.role == ZERO_NATIVE_APPKIT_WIDGET_ROLE_ROW) {
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
                NSRange selectedRange = ZeroNativeClampedRange(node.text_selection_start, node.text_selection_end, textValue.length);
                element.accessibilitySelectedTextRange = selectedRange;
                element.accessibilitySelectedTextRanges = @[[NSValue valueWithRange:selectedRange]];
                element.accessibilitySelectedText = ZeroNativeSubstringForRange(textValue, selectedRange);
                element.accessibilityInsertionPointLineNumber = 0;
            }
        }
        element.accessibilityEnabled = (node.state_flags & ZERO_NATIVE_APPKIT_WIDGET_STATE_ENABLED) != 0;
        element.accessibilityFocused = (node.state_flags & ZERO_NATIVE_APPKIT_WIDGET_STATE_FOCUSED) != 0;
        element.accessibilitySelected = (node.state_flags & ZERO_NATIVE_APPKIT_WIDGET_STATE_SELECTED) != 0;
        if ((node.state_flags & ZERO_NATIVE_APPKIT_WIDGET_STATE_EXPANDED) != 0) {
            element.accessibilityExpanded = YES;
        } else if ((node.state_flags & ZERO_NATIVE_APPKIT_WIDGET_STATE_COLLAPSED) != 0) {
            element.accessibilityExpanded = NO;
        }
        if ([element respondsToSelector:@selector(setAccessibilityRequired:)]) {
            element.accessibilityRequired = (node.state_flags & ZERO_NATIVE_APPKIT_WIDGET_STATE_REQUIRED) != 0;
        }
        NSMutableArray<NSString *> *stateDescriptions = [NSMutableArray array];
        if ((node.state_flags & ZERO_NATIVE_APPKIT_WIDGET_STATE_READ_ONLY) != 0) {
            [stateDescriptions addObject:@"Read only"];
        }
        if ((node.state_flags & ZERO_NATIVE_APPKIT_WIDGET_STATE_INVALID) != 0) {
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
    if (!self.hasCanvasTexture || self.retainedFrameRequestPending) return;
    self.retainedFrameRequestPending = YES;
    const uint64_t now = ZeroNativeTimestampNanoseconds();
    const uint64_t frameIntervalNs = ZeroNativeRetainedFrameIntervalNanoseconds(self.window.screen ?: NSScreen.mainScreen);
    uint64_t delayNs = 0;
    if (self.retainedFrameLastEmitNs > 0 && now < self.retainedFrameLastEmitNs + frameIntervalNs) {
        delayNs = self.retainedFrameLastEmitNs + frameIntervalNs - now;
    }
    __weak ZeroNativeMetalSurfaceView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayNs), dispatch_get_main_queue(), ^{
        ZeroNativeMetalSurfaceView *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf emitRetainedCanvasFrameRequest];
    });
}

- (void)emitRetainedCanvasFrameRequest {
    self.retainedFrameRequestPending = NO;
    if (![self isAvailable] || self.hidden || !self.hasCanvasTexture || self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;
    [self updateDrawableSize];
    self.retainedFrameLastEmitNs = ZeroNativeTimestampNanoseconds();
    const NSUInteger requestedFrameIndex = self.frameIndex;
    self.frameIndex += 1;
    const BOOL nonblank = self.verifiedNonblankFrame || self.hasCanvasTexture;
    const uint32_t sampleColor = self.verifiedNonblankFrame ? self.lastSampleColor : 0;
    [self emitFrameEventWithFrameIndex:requestedFrameIndex sampleColor:sampleColor nonblank:nonblank];
}

- (void)renderFrame {
    if (![self isAvailable] || self.hidden || self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return;
    [self updateDrawableSize];

    id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
    if (!drawable) return;

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

    const NSUInteger completedFrameIndex = self.frameIndex;
    __weak ZeroNativeMetalSurfaceView *weakSelf = self;
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
            ZeroNativeMetalSurfaceView *strongSelf = weakSelf;
            if (!strongSelf) return;
            BOOL eventNonblank = nonblank;
            uint32_t eventSampleColor = sampleColor;
            if (eventNonblank) {
                strongSelf.verifiedNonblankFrame = YES;
                strongSelf.lastSampleColor = eventSampleColor;
            } else if (strongSelf.verifiedNonblankFrame) {
                eventNonblank = YES;
                eventSampleColor = strongSelf.lastSampleColor;
            }
            strongSelf.renderedFrame = YES;
            [strongSelf emitFrameEventWithFrameIndex:completedFrameIndex sampleColor:eventSampleColor nonblank:eventNonblank];
        });
    }];

    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];

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
    [self emitInputEventWithKind:ZERO_NATIVE_APPKIT_GPU_INPUT_POINTER_DOWN event:event button:0 deltaX:0 deltaY:0];
}

- (void)mouseUp:(NSEvent *)event {
    [self emitQueuedPointerMotionInputEvent];
    [self emitInputEventWithKind:ZERO_NATIVE_APPKIT_GPU_INPUT_POINTER_UP event:event button:0 deltaX:0 deltaY:0];
}

- (void)mouseMoved:(NSEvent *)event {
    [self queuePointerMotionInputEvent:event kind:ZERO_NATIVE_APPKIT_GPU_INPUT_POINTER_MOVE button:0];
}

- (void)mouseExited:(NSEvent *)event {
    [self emitQueuedPointerMotionInputEvent];
    [self emitInputEventWithKind:ZERO_NATIVE_APPKIT_GPU_INPUT_POINTER_CANCEL event:event button:0 deltaX:0 deltaY:0];
}

- (void)mouseDragged:(NSEvent *)event {
    [self queuePointerMotionInputEvent:event kind:ZERO_NATIVE_APPKIT_GPU_INPUT_POINTER_DRAG button:0];
}

- (void)rightMouseDown:(NSEvent *)event {
    [self emitQueuedPointerMotionInputEvent];
    [self.window makeFirstResponder:self];
    [self emitInputEventWithKind:ZERO_NATIVE_APPKIT_GPU_INPUT_POINTER_DOWN event:event button:1 deltaX:0 deltaY:0];
}

- (void)rightMouseUp:(NSEvent *)event {
    [self emitQueuedPointerMotionInputEvent];
    [self emitInputEventWithKind:ZERO_NATIVE_APPKIT_GPU_INPUT_POINTER_UP event:event button:1 deltaX:0 deltaY:0];
}

- (void)rightMouseDragged:(NSEvent *)event {
    [self queuePointerMotionInputEvent:event kind:ZERO_NATIVE_APPKIT_GPU_INPUT_POINTER_DRAG button:1];
}

- (void)otherMouseDown:(NSEvent *)event {
    [self emitQueuedPointerMotionInputEvent];
    [self.window makeFirstResponder:self];
    [self emitInputEventWithKind:ZERO_NATIVE_APPKIT_GPU_INPUT_POINTER_DOWN event:event button:(NSInteger)event.buttonNumber deltaX:0 deltaY:0];
}

- (void)otherMouseUp:(NSEvent *)event {
    [self emitQueuedPointerMotionInputEvent];
    [self emitInputEventWithKind:ZERO_NATIVE_APPKIT_GPU_INPUT_POINTER_UP event:event button:(NSInteger)event.buttonNumber deltaX:0 deltaY:0];
}

- (void)otherMouseDragged:(NSEvent *)event {
    [self queuePointerMotionInputEvent:event kind:ZERO_NATIVE_APPKIT_GPU_INPUT_POINTER_DRAG button:(NSInteger)event.buttonNumber];
}

- (void)scrollWheel:(NSEvent *)event {
    [self queueScrollInputEvent:event deltaX:-event.scrollingDeltaX deltaY:-event.scrollingDeltaY];
}

- (void)keyDown:(NSEvent *)event {
    if ([self focusedTextAccessibilityElement]) {
        self.interpretedKeyEventEmittedInput = NO;
        [self interpretKeyEvents:@[event]];
        if (!self.interpretedKeyEventEmittedInput) {
            [self emitInputEventWithKind:ZERO_NATIVE_APPKIT_GPU_INPUT_KEY_DOWN event:event button:0 deltaX:0 deltaY:0];
        }
        self.interpretedKeyEventEmittedInput = NO;
        return;
    }
    [self emitInputEventWithKind:ZERO_NATIVE_APPKIT_GPU_INPUT_KEY_DOWN event:event button:0 deltaX:0 deltaY:0];
    [self interpretKeyEvents:@[event]];
}

- (void)keyUp:(NSEvent *)event {
    [self emitInputEventWithKind:ZERO_NATIVE_APPKIT_GPU_INPUT_KEY_UP event:event button:0 deltaX:0 deltaY:0];
}

- (void)emitFrameEventWithFrameIndex:(NSUInteger)frameIndex sampleColor:(uint32_t)sampleColor nonblank:(BOOL)nonblank {
    if (!self.host || self.surfaceLabel.length == 0) return;
    const char *labelBytes = self.surfaceLabel.UTF8String ?: "";
    [self.host emitEvent:(zero_native_appkit_event_t){
        .kind = ZERO_NATIVE_APPKIT_EVENT_GPU_SURFACE_FRAME,
        .window_id = self.windowId,
        .width = self.bounds.size.width,
        .height = self.bounds.size.height,
        .scale = self.lastScale > 0 ? self.lastScale : 1,
        .view_label = labelBytes,
        .view_label_len = [self.surfaceLabel lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        .frame_index = frameIndex,
        .timestamp_ns = ZeroNativeTimestampNanoseconds(),
        .frame_interval_ns = ZeroNativeRetainedFrameIntervalNanoseconds(self.window.screen ?: NSScreen.mainScreen),
        .nonblank = nonblank ? 1 : 0,
        .sample_color = sampleColor,
    }];
    [self.host scheduleFrame];
}

- (void)emitResizeEvent {
    if (!self.host || self.surfaceLabel.length == 0) return;
    CGFloat y = self.superview ? (self.superview.bounds.size.height - NSMaxY(self.frame)) : self.frame.origin.y;
    const char *labelBytes = self.surfaceLabel.UTF8String ?: "";
    [self.host emitEvent:(zero_native_appkit_event_t){
        .kind = ZERO_NATIVE_APPKIT_EVENT_GPU_SURFACE_RESIZE,
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
    BOOL keyEvent = kind == ZERO_NATIVE_APPKIT_GPU_INPUT_KEY_DOWN || kind == ZERO_NATIVE_APPKIT_GPU_INPUT_KEY_UP;
    NSString *keyText = keyEvent && event ? ZeroNativeShortcutKeyForEvent(event) : @"";
    [self emitInputEventWithKind:kind
                           point:point
                     timestampNs:ZeroNativeTimestampNanoseconds()
                       modifiers:event ? ZeroNativeModifierFlagsForEvent(event) : 0
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
    self.pendingPointerMotionModifiers = ZeroNativeModifierFlagsForEvent(event);
    self.pendingPointerMotionTimestampNs = ZeroNativeTimestampNanoseconds();
    if (self.pointerMotionInputPending) return;
    self.pointerMotionInputPending = YES;

    const uint64_t now = self.pendingPointerMotionTimestampNs;
    const uint64_t frameIntervalNs = ZeroNativeRetainedFrameIntervalNanoseconds(self.window.screen ?: NSScreen.mainScreen);
    uint64_t delayNs = 0;
    if (self.pointerMotionInputLastEmitNs > 0 && now < self.pointerMotionInputLastEmitNs + frameIntervalNs) {
        delayNs = self.pointerMotionInputLastEmitNs + frameIntervalNs - now;
    }
    __weak ZeroNativeMetalSurfaceView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayNs), dispatch_get_main_queue(), ^{
        ZeroNativeMetalSurfaceView *strongSelf = weakSelf;
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
    const uint64_t timestampNs = self.pendingPointerMotionTimestampNs > 0 ? self.pendingPointerMotionTimestampNs : ZeroNativeTimestampNanoseconds();
    self.pointerMotionInputPending = NO;
    self.pendingPointerMotionKind = 0;
    self.pendingPointerMotionButton = 0;
    self.pendingPointerMotionModifiers = 0;
    self.pendingPointerMotionTimestampNs = 0;
    self.pointerMotionInputLastEmitNs = ZeroNativeTimestampNanoseconds();
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
    self.pendingScrollModifiers = ZeroNativeModifierFlagsForEvent(event);
    self.pendingScrollTimestampNs = ZeroNativeTimestampNanoseconds();
    if (self.scrollInputPending) return;
    self.scrollInputPending = YES;

    const uint64_t now = self.pendingScrollTimestampNs;
    const uint64_t frameIntervalNs = ZeroNativeRetainedFrameIntervalNanoseconds(self.window.screen ?: NSScreen.mainScreen);
    uint64_t delayNs = 0;
    if (self.scrollInputLastEmitNs > 0 && now < self.scrollInputLastEmitNs + frameIntervalNs) {
        delayNs = self.scrollInputLastEmitNs + frameIntervalNs - now;
    }
    __weak ZeroNativeMetalSurfaceView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayNs), dispatch_get_main_queue(), ^{
        ZeroNativeMetalSurfaceView *strongSelf = weakSelf;
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
    const uint64_t timestampNs = self.pendingScrollTimestampNs > 0 ? self.pendingScrollTimestampNs : ZeroNativeTimestampNanoseconds();
    self.scrollInputPending = NO;
    self.pendingScrollDeltaX = 0;
    self.pendingScrollDeltaY = 0;
    self.pendingScrollModifiers = 0;
    self.pendingScrollTimestampNs = 0;
    if (deltaX == 0 && deltaY == 0) return;
    self.scrollInputLastEmitNs = ZeroNativeTimestampNanoseconds();
    [self emitInputEventWithKind:ZERO_NATIVE_APPKIT_GPU_INPUT_SCROLL
                           point:point
                     timestampNs:timestampNs
                       modifiers:modifiers
                         keyText:@""
                       inputText:@""
                          button:0
                          deltaX:deltaX
                          deltaY:deltaY];
}

- (void)emitInputEventWithKind:(NSInteger)kind point:(NSPoint)point timestampNs:(uint64_t)timestampNs modifiers:(uint32_t)modifiers keyText:(NSString *)keyText inputText:(NSString *)inputText button:(NSInteger)button deltaX:(double)deltaX deltaY:(double)deltaY {
    if (!self.host || self.surfaceLabel.length == 0) return;
    CGFloat y = self.bounds.size.height - point.y;
    const char *labelBytes = self.surfaceLabel.UTF8String ?: "";
    NSString *safeKeyText = keyText ?: @"";
    NSString *safeInputText = inputText ?: @"";
    const char *keyBytes = safeKeyText.UTF8String ?: "";
    const char *inputBytes = safeInputText.UTF8String ?: "";
    [self.host emitEvent:(zero_native_appkit_event_t){
        .kind = ZERO_NATIVE_APPKIT_EVENT_GPU_SURFACE_INPUT,
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
    [self.host emitEvent:(zero_native_appkit_event_t){
        .kind = ZERO_NATIVE_APPKIT_EVENT_GPU_SURFACE_INPUT,
        .window_id = self.windowId,
        .timestamp_ns = ZeroNativeTimestampNanoseconds(),
        .view_label = labelBytes,
        .view_label_len = [self.surfaceLabel lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        .key_text = keyBytes,
        .key_text_len = [key lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        .shortcut_modifiers = modifiers,
        .input_kind = ZERO_NATIVE_APPKIT_GPU_INPUT_KEY_DOWN,
    }];
    [self requestRetainedCanvasFrame];
}

- (void)emitSelectAllTextInputCommand {
    [self emitSyntheticKeyDownWithKey:@"a" modifiers:(ZeroNativeShortcutModifierPrimary | ZeroNativeShortcutModifierCommand)];
}

- (void)emitTextInputEventWithKind:(NSInteger)kind text:(NSString *)text compositionCursor:(NSInteger)compositionCursor {
    if (!self.host || self.surfaceLabel.length == 0) return;
    self.interpretedKeyEventEmittedInput = YES;
    NSString *inputText = text ?: @"";
    const char *labelBytes = self.surfaceLabel.UTF8String ?: "";
    const char *inputBytes = inputText.UTF8String ?: "";
    BOOL hasCompositionCursor = compositionCursor >= 0;
    [self.host emitEvent:(zero_native_appkit_event_t){
        .kind = ZERO_NATIVE_APPKIT_EVENT_GPU_SURFACE_INPUT,
        .window_id = self.windowId,
        .timestamp_ns = ZeroNativeTimestampNanoseconds(),
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
    NSString *text = ZeroNativeStringFromTextInput(string);
    BOOL hadMarkedText = [self hasMarkedText];
    if (text.length == 0) {
        self.markedText = @"";
        self.markedTextRange = NSMakeRange(NSNotFound, 0);
        self.selectedTextRange = NSMakeRange(0, 0);
        if (hadMarkedText) {
            [self emitTextInputEventWithKind:ZERO_NATIVE_APPKIT_GPU_INPUT_IME_CANCEL_COMPOSITION text:@"" compositionCursor:-1];
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
    [self emitTextInputEventWithKind:ZERO_NATIVE_APPKIT_GPU_INPUT_IME_SET_COMPOSITION text:text compositionCursor:(NSInteger)cursor];
}

- (void)unmarkText {
    BOOL hadMarkedText = [self hasMarkedText];
    self.markedText = @"";
    self.markedTextRange = NSMakeRange(NSNotFound, 0);
    self.selectedTextRange = NSMakeRange(0, 0);
    if (hadMarkedText) {
        [self emitTextInputEventWithKind:ZERO_NATIVE_APPKIT_GPU_INPUT_IME_COMMIT_COMPOSITION text:@"" compositionCursor:-1];
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
    NSString *text = ZeroNativeStringFromTextInput(string);
    if (text.length == 0) return;

    BOOL hadMarkedText = [self hasMarkedText];
    NSString *markedText = self.markedText ?: @"";
    self.markedText = @"";
    self.markedTextRange = NSMakeRange(NSNotFound, 0);
    self.selectedTextRange = NSMakeRange(text.length, 0);

    if (hadMarkedText && [markedText isEqualToString:text]) {
        [self emitTextInputEventWithKind:ZERO_NATIVE_APPKIT_GPU_INPUT_IME_COMMIT_COMPOSITION text:@"" compositionCursor:-1];
        return;
    }
    if (hadMarkedText) {
        [self emitTextInputEventWithKind:ZERO_NATIVE_APPKIT_GPU_INPUT_IME_CANCEL_COMPOSITION text:@"" compositionCursor:-1];
    }
    [self emitTextInputEventWithKind:ZERO_NATIVE_APPKIT_GPU_INPUT_TEXT_INPUT text:text compositionCursor:-1];
}

- (void)selectAll:(id)sender {
    (void)sender;
    if (![self focusedTextAccessibilityElement]) return;
    [self emitSelectAllTextInputCommand];
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
        [self emitSyntheticKeyDownWithKey:@"arrowleft" modifiers:ZeroNativeShortcutModifierShift];
    } else if (selector == @selector(moveRightAndModifySelection:)) {
        [self emitSyntheticKeyDownWithKey:@"arrowright" modifiers:ZeroNativeShortcutModifierShift];
    } else if (selector == @selector(moveUpAndModifySelection:)) {
        [self emitSyntheticKeyDownWithKey:@"arrowup" modifiers:ZeroNativeShortcutModifierShift];
    } else if (selector == @selector(moveDownAndModifySelection:)) {
        [self emitSyntheticKeyDownWithKey:@"arrowdown" modifiers:ZeroNativeShortcutModifierShift];
    } else if (selector == @selector(moveToBeginningOfLine:)) {
        [self emitSyntheticKeyDownWithKey:@"home" modifiers:0];
    } else if (selector == @selector(moveToEndOfLine:)) {
        [self emitSyntheticKeyDownWithKey:@"end" modifiers:0];
    } else if (selector == @selector(moveToBeginningOfLineAndModifySelection:)) {
        [self emitSyntheticKeyDownWithKey:@"home" modifiers:ZeroNativeShortcutModifierShift];
    } else if (selector == @selector(moveToEndOfLineAndModifySelection:)) {
        [self emitSyntheticKeyDownWithKey:@"end" modifiers:ZeroNativeShortcutModifierShift];
    } else if (selector == @selector(selectAll:)) {
        [self emitSelectAllTextInputCommand];
    } else if (selector == @selector(insertNewline:)) {
        [self emitSyntheticKeyDownWithKey:@"enter" modifiers:0];
    } else if (selector == @selector(insertTab:)) {
        [self emitSyntheticKeyDownWithKey:@"tab" modifiers:0];
    } else if (selector == @selector(insertBacktab:)) {
        [self emitSyntheticKeyDownWithKey:@"tab" modifiers:ZeroNativeShortcutModifierShift];
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
    [self.host emitEvent:(zero_native_appkit_event_t){
        .kind = ZERO_NATIVE_APPKIT_EVENT_WIDGET_ACCESSIBILITY_ACTION,
        .window_id = self.windowId,
        .timestamp_ns = ZeroNativeTimestampNanoseconds(),
        .view_label = labelBytes,
        .view_label_len = [self.surfaceLabel lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        .widget_id = widgetId,
        .widget_action = (int)action,
        .widget_text = textBytes,
        .widget_text_len = [payloadText lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        .has_widget_text_selection = hasSelectedRange ? 1 : 0,
        .widget_text_selection_start = hasSelectedRange ? selectedRange.location : 0,
        .widget_text_selection_end = hasSelectedRange ? ZeroNativeRangeEnd(selectedRange) : 0,
    }];
    [self requestRetainedCanvasFrame];
    return YES;
}

@end

@implementation ZeroNativeAssetSchemeHandler

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.rootPath = @"";
    self.entryPath = @"index.html";
    self.spaFallback = YES;
    return self;
}

- (void)configureWithRootPath:(NSString *)rootPath entryPath:(NSString *)entryPath spaFallback:(BOOL)spaFallback {
    self.rootPath = ZeroNativeResolvedAssetRoot(rootPath ?: @"");
    self.entryPath = entryPath.length > 0 ? entryPath : @"index.html";
    self.spaFallback = spaFallback;
}

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
    (void)webView;
    NSString *relativePath = ZeroNativeSafeAssetPath(urlSchemeTask.request.URL, self.entryPath);
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
                                                        MIMEType:ZeroNativeMimeTypeForPath(filePath)
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

@implementation ZeroNativeShortcut
@end

@implementation ZeroNativeAppKitHost

- (instancetype)initWithAppName:(NSString *)appName windowTitle:(NSString *)windowTitle bundleIdentifier:(NSString *)bundleIdentifier iconPath:(NSString *)iconPath windowLabel:(NSString *)windowLabel x:(double)x y:(double)y width:(double)width height:(double)height restoreFrame:(BOOL)restoreFrame {
    self = [super init];
    if (!self) {
        return nil;
    }

    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    ZeroNativeRegisterBundledFonts();
    self.appName = appName.length > 0 ? appName : @"zero-native";
    self.bundleIdentifier = bundleIdentifier.length > 0 ? bundleIdentifier : @"dev.zero_native.app";
    self.iconPath = iconPath ?: @"";
    self.windowLabel = windowLabel.length > 0 ? windowLabel : @"main";
    self.windows = [[NSMutableDictionary alloc] init];
    self.webViews = [[NSMutableDictionary alloc] init];
    self.delegates = [[NSMutableDictionary alloc] init];
    self.bridgeScriptHandlers = [[NSMutableDictionary alloc] init];
    self.assetSchemeHandlers = [[NSMutableDictionary alloc] init];
    self.windowLabels = [[NSMutableDictionary alloc] init];
    self.childWebViews = [[NSMutableDictionary alloc] init];
    self.nativeViews = [[NSMutableDictionary alloc] init];
    self.nativeViewCommands = [[NSMutableDictionary alloc] init];
    self.nativeViewExplicitTextKeys = [[NSMutableSet alloc] init];
    self.bridgeEnabledChildWebViewKeys = [[NSMutableSet alloc] init];
    self.allowedNavigationOrigins = @[ @"zero://app", @"zero://inline" ];
    self.allowedExternalURLs = @[];
    self.externalLinkAction = 0;
    self.shortcuts = @[];
    [self configureApplication];

    [self createWindowWithId:1 title:(windowTitle.length > 0 ? windowTitle : self.appName) label:self.windowLabel x:x y:y width:width height:height restoreFrame:restoreFrame makeMain:YES];
    self.didShutdown = NO;
    self.observesApplicationActivation = NO;

    return self;
}

- (BOOL)createWindowWithId:(uint64_t)windowId title:(NSString *)title label:(NSString *)label x:(double)x y:(double)y width:(double)width height:(double)height restoreFrame:(BOOL)restoreFrame makeMain:(BOOL)makeMain {
    NSNumber *key = @(windowId);
    if (self.windows[key]) {
        return NO;
    }

    NSRect rect = restoreFrame ? NSMakeRect(x, y, width, height) : NSMakeRect(0, 0, width, height);
    if (restoreFrame) {
        rect = constrainFrame(rect);
    }
    NSWindow *window = [[NSWindow alloc] initWithContentRect:rect
                                                   styleMask:(NSWindowStyleMaskTitled |
                                                              NSWindowStyleMaskClosable |
                                                              NSWindowStyleMaskResizable |
                                                              NSWindowStyleMaskMiniaturizable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [window setTitle:(title.length > 0 ? title : self.appName)];
    if (!restoreFrame) {
        [window center];
    }

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    ZeroNativeAssetSchemeHandler *assetSchemeHandler = [[ZeroNativeAssetSchemeHandler alloc] init];
    [configuration setURLSchemeHandler:assetSchemeHandler forURLScheme:@"zero"];
    WKUserContentController *userContentController = [[WKUserContentController alloc] init];
    ZeroNativeBridgeScriptHandler *bridgeScriptHandler = [[ZeroNativeBridgeScriptHandler alloc] init];
    bridgeScriptHandler.host = self;
    bridgeScriptHandler.windowId = windowId;
    bridgeScriptHandler.webViewLabel = @"main";
    [userContentController addScriptMessageHandler:bridgeScriptHandler name:@"zeroNativeBridge"];
    WKUserScript *bridgeScript = [[WKUserScript alloc] initWithSource:ZeroNativeAppKitBridgeScript()
                                                        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                     forMainFrameOnly:YES];
    [userContentController addUserScript:bridgeScript];
    configuration.userContentController = userContentController;
    if ([configuration.preferences respondsToSelector:NSSelectorFromString(@"setDeveloperExtrasEnabled:")]) {
        [configuration.preferences setValue:@YES forKey:@"developerExtrasEnabled"];
    }
    NSView *container = [[NSView alloc] initWithFrame:rect];
    container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    WKWebView *webView = [[ZeroNativeWebView alloc] initWithFrame:container.bounds configuration:configuration];
    ((ZeroNativeWebView *)webView).host = self;
    ((ZeroNativeWebView *)webView).windowId = windowId;
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
    [container addSubview:webView positioned:NSWindowAbove relativeTo:nil];
    window.contentView = container;

    ZeroNativeWindowDelegate *delegate = [[ZeroNativeWindowDelegate alloc] init];
    delegate.host = self;
    delegate.windowId = windowId;
    window.delegate = delegate;

    self.windows[key] = window;
    self.webViews[key] = webView;
    self.delegates[key] = delegate;
    self.bridgeScriptHandlers[key] = bridgeScriptHandler;
    self.assetSchemeHandlers[key] = assetSchemeHandler;
    self.windowLabels[key] = label.length > 0 ? label : @"main";
    if (makeMain) {
        self.window = window;
        self.webView = webView;
        self.delegate = delegate;
        self.bridgeScriptHandler = bridgeScriptHandler;
        self.assetSchemeHandler = assetSchemeHandler;
        self.windowLabel = label.length > 0 ? label : @"main";
    } else {
        [window makeKeyAndOrderFront:nil];
        [NSApp activate];
    }
    return YES;
}

- (void)dealloc {
    [self.automationFrameTimer invalidate];
    self.automationFrameTimer = nil;
    [self stopAppearanceObservers];
    if (self.shortcutEventMonitor) {
        [NSEvent removeMonitor:self.shortcutEventMonitor];
        self.shortcutEventMonitor = nil;
    }
    [self removeAllChildBridgeHandlers];
    for (WKWebView *webView in self.webViews.allValues) {
        [webView.configuration.userContentController removeScriptMessageHandlerForName:@"zeroNativeBridge"];
    }
}

- (void)focusWindowWithId:(uint64_t)windowId {
    NSWindow *window = self.windows[@(windowId)];
    if (!window) return;
    [window makeKeyAndOrderFront:nil];
    [NSApp activate];
    [self emitWindowFrameForWindowId:windowId open:YES];
    [self scheduleFrame];
}

- (void)closeWindowWithId:(uint64_t)windowId {
    NSWindow *window = self.windows[@(windowId)];
    if (!window) return;
    [window performClose:nil];
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

- (ZeroNativeAssetSchemeHandler *)assetHandlerForWindowId:(uint64_t)windowId {
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
        case ZERO_NATIVE_APPKIT_VIEW_TOOLBAR:
        case ZERO_NATIVE_APPKIT_VIEW_TITLEBAR_ACCESSORY:
        case ZERO_NATIVE_APPKIT_VIEW_STATUSBAR:
        case ZERO_NATIVE_APPKIT_VIEW_SIDEBAR:
        case ZERO_NATIVE_APPKIT_VIEW_SPLIT:
        case ZERO_NATIVE_APPKIT_VIEW_STACK:
        case ZERO_NATIVE_APPKIT_VIEW_SPACER: {
            view = [[NSView alloc] initWithFrame:NSZeroRect];
            view.wantsLayer = YES;
            NSColor *color = NSColor.clearColor;
            if (kind == ZERO_NATIVE_APPKIT_VIEW_TOOLBAR || kind == ZERO_NATIVE_APPKIT_VIEW_STATUSBAR || kind == ZERO_NATIVE_APPKIT_VIEW_TITLEBAR_ACCESSORY) {
                color = NSColor.controlBackgroundColor;
            } else if (kind == ZERO_NATIVE_APPKIT_VIEW_SIDEBAR) {
                color = NSColor.windowBackgroundColor;
            }
            view.layer.backgroundColor = color.CGColor;
            break;
        }
        case ZERO_NATIVE_APPKIT_VIEW_BUTTON: {
            NSButton *button = [NSButton buttonWithTitle:(displayText.length > 0 ? displayText : @"Button") target:nil action:nil];
            button.bezelStyle = NSBezelStyleRounded;
            view = button;
            break;
        }
        case ZERO_NATIVE_APPKIT_VIEW_ICON_BUTTON: {
            NSButton *button = [NSButton buttonWithTitle:(displayText.length > 0 ? displayText : @"...") target:nil action:nil];
            button.bezelStyle = NSBezelStyleTexturedRounded;
            view = button;
            break;
        }
        case ZERO_NATIVE_APPKIT_VIEW_LIST_ITEM: {
            NSButton *button = [NSButton buttonWithTitle:(displayText.length > 0 ? displayText : @"Item") target:nil action:nil];
            button.bezelStyle = NSBezelStyleRegularSquare;
            button.bordered = NO;
            button.alignment = NSTextAlignmentLeft;
            button.imagePosition = NSNoImage;
            view = button;
            break;
        }
        case ZERO_NATIVE_APPKIT_VIEW_CHECKBOX: {
            NSButton *checkbox = [NSButton checkboxWithTitle:(displayText.length > 0 ? displayText : @"Checkbox") target:nil action:nil];
            view = checkbox;
            break;
        }
        case ZERO_NATIVE_APPKIT_VIEW_TOGGLE: {
            NSButton *toggle = [NSButton buttonWithTitle:(displayText.length > 0 ? displayText : @"Toggle") target:nil action:nil];
            [toggle setButtonType:NSButtonTypePushOnPushOff];
            toggle.bezelStyle = NSBezelStyleRounded;
            view = toggle;
            break;
        }
        case ZERO_NATIVE_APPKIT_VIEW_SEGMENTED_CONTROL: {
            NSSegmentedControl *segmented = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
            segmented.segmentStyle = NSSegmentStyleTexturedRounded;
            segmented.trackingMode = NSSegmentSwitchTrackingSelectOne;
            [self applySegmentedControl:segmented text:(text.length > 0 ? text : @"One|Two")];
            view = segmented;
            break;
        }
        case ZERO_NATIVE_APPKIT_VIEW_PROGRESS_INDICATOR: {
            NSProgressIndicator *indicator = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
            indicator.style = NSProgressIndicatorSpinningStyle;
            indicator.indeterminate = YES;
            [indicator startAnimation:nil];
            view = indicator;
            break;
        }
        case ZERO_NATIVE_APPKIT_VIEW_GPU_SURFACE: {
            ZeroNativeMetalSurfaceView *surface = [[ZeroNativeMetalSurfaceView alloc] initWithFrame:NSZeroRect];
            if (![surface isAvailable]) return nil;
            view = surface;
            break;
        }
        case ZERO_NATIVE_APPKIT_VIEW_TEXT_FIELD: {
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
        case ZERO_NATIVE_APPKIT_VIEW_SEARCH_FIELD: {
            NSSearchField *field = [[NSSearchField alloc] initWithFrame:NSZeroRect];
            field.stringValue = @"";
            field.placeholderString = displayText.length > 0 ? displayText : @"Search";
            view = field;
            break;
        }
        case ZERO_NATIVE_APPKIT_VIEW_LABEL: {
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
    view.accessibilityRole = ZeroNativeAccessibilityRoleForNativeViewKind(kind);
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
    [self emitEvent:(zero_native_appkit_event_t){
        .kind = ZERO_NATIVE_APPKIT_EVENT_NATIVE_COMMAND,
        .window_id = windowId,
        .command_name = commandBytes,
        .command_name_len = [command lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        .view_label = labelBytes,
        .view_label_len = [label lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
    }];
}

- (BOOL)createNativeViewInWindow:(uint64_t)windowId label:(NSString *)label kind:(NSInteger)kind parent:(NSString *)parent x:(double)x y:(double)y width:(double)width height:(double)height layer:(NSInteger)layer visible:(BOOL)visible enabled:(BOOL)enabled role:(NSString *)role accessibilityLabel:(NSString *)accessibilityLabel text:(NSString *)text command:(NSString *)command {
    if (label.length == 0 || x < 0 || y < 0 || width < 0 || height < 0) return NO;
    if (self.nativeViews.count >= ZeroNativeMaxNativeViews) return NO;
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
    if ([view isKindOfClass:[ZeroNativeMetalSurfaceView class]]) {
        [(ZeroNativeMetalSurfaceView *)view configureWithHost:self windowId:windowId label:label];
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
    if (![view isKindOfClass:[ZeroNativeMetalSurfaceView class]]) return NO;
    return [(ZeroNativeMetalSurfaceView *)view presentPixelsWithWidth:width height:height scale:scale hasDirtyRect:hasDirtyRect dirtyX:dirtyX dirtyY:dirtyY dirtyWidth:dirtyWidth dirtyHeight:dirtyHeight rgba8:rgba8 byteLength:byteLength];
}

- (NSInteger)presentGpuSurfacePacketInWindow:(uint64_t)windowId label:(NSString *)label surfaceWidth:(CGFloat)surfaceWidth height:(CGFloat)surfaceHeight scale:(CGFloat)scale clearR:(uint8_t)clearR clearG:(uint8_t)clearG clearB:(uint8_t)clearB clearA:(uint8_t)clearA requiresRender:(BOOL)requiresRender commandCount:(NSUInteger)commandCount unsupportedCommandCount:(NSUInteger)unsupportedCommandCount representable:(BOOL)representable json:(const uint8_t *)json byteLength:(NSUInteger)byteLength {
    NSString *key = [self nativeViewKeyForWindow:windowId label:label];
    NSView *view = self.nativeViews[key];
    if (![view isKindOfClass:[ZeroNativeMetalSurfaceView class]]) return -1;
    return [(ZeroNativeMetalSurfaceView *)view presentGpuPacketWithSurfaceWidth:surfaceWidth height:surfaceHeight scale:scale clearR:clearR clearG:clearG clearB:clearB clearA:clearA requiresRender:requiresRender commandCount:commandCount unsupportedCommandCount:unsupportedCommandCount representable:representable json:json byteLength:byteLength];
}

- (BOOL)requestGpuSurfaceFrameInWindow:(uint64_t)windowId label:(NSString *)label {
    NSString *key = [self nativeViewKeyForWindow:windowId label:label];
    NSView *view = self.nativeViews[key];
    if (![view isKindOfClass:[ZeroNativeMetalSurfaceView class]]) return NO;
    [(ZeroNativeMetalSurfaceView *)view requestRetainedCanvasFrame];
    return YES;
}

- (BOOL)setNativeViewCursorInWindow:(uint64_t)windowId label:(NSString *)label cursor:(NSInteger)cursor {
    NSString *key = [self nativeViewKeyForWindow:windowId label:label];
    NSView *view = self.nativeViews[key];
    if (![view isKindOfClass:[ZeroNativeMetalSurfaceView class]]) return NO;
    [(ZeroNativeMetalSurfaceView *)view setSurfaceCursor:ZeroNativeCursorForKind(cursor)];
    return YES;
}

- (BOOL)updateWidgetAccessibilityInWindow:(uint64_t)windowId label:(NSString *)label nodes:(const zero_native_appkit_widget_accessibility_node_t *)nodes count:(NSUInteger)count {
    NSString *key = [self nativeViewKeyForWindow:windowId label:label];
    NSView *view = self.nativeViews[key];
    if (![view isKindOfClass:[ZeroNativeMetalSurfaceView class]]) return NO;
    [(ZeroNativeMetalSurfaceView *)view updateWidgetAccessibilityWithNodes:nodes count:count];
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
        NSView *view = self.nativeViews[key];
        [view removeFromSuperview];
        [self.nativeViews removeObjectForKey:key];
        [self.nativeViewCommands removeObjectForKey:key];
        [self.nativeViewExplicitTextKeys removeObject:key];
    }
    [self reorderWebViewsInWindow:windowId];
}

- (BOOL)createWebViewInWindow:(uint64_t)windowId label:(NSString *)label url:(NSString *)url x:(double)x y:(double)y width:(double)width height:(double)height layer:(NSInteger)layer transparent:(BOOL)transparent bridgeEnabled:(BOOL)bridgeEnabled {
    if (label.length == 0 || url.length == 0 || width <= 0 || height <= 0 || x < 0 || y < 0) return NO;
    NSWindow *window = self.windows[@(windowId)] ?: (windowId == 1 ? self.window : nil);
    if (!window || !window.contentView) return NO;
    NSURL *targetURL = [NSURL URLWithString:url];
    if (!targetURL) return NO;
    if (![self allowsNavigationURL:targetURL]) return NO;
    if (self.childWebViews.count >= ZeroNativeMaxChildWebViews) return NO;

    NSString *key = [self webViewKeyForWindow:windowId label:label];
    WKWebView *existing = self.childWebViews[key];
    if (existing) return NO;

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    ZeroNativeAssetSchemeHandler *assetSchemeHandler = [self assetHandlerForWindowId:windowId];
    if (assetSchemeHandler) {
        [configuration setURLSchemeHandler:assetSchemeHandler forURLScheme:@"zero"];
    }
    if (bridgeEnabled) {
        WKUserContentController *controller = [[WKUserContentController alloc] init];
        ZeroNativeBridgeScriptHandler *handler = [[ZeroNativeBridgeScriptHandler alloc] init];
        handler.host = self;
        handler.windowId = windowId;
        handler.webViewLabel = label;
        [controller addScriptMessageHandler:handler name:@"zeroNativeBridge"];
        [controller addUserScript:[[WKUserScript alloc] initWithSource:ZeroNativeAppKitBridgeScript() injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
        configuration.userContentController = controller;
    }
    if ([configuration.preferences respondsToSelector:NSSelectorFromString(@"setDeveloperExtrasEnabled:")]) {
        [configuration.preferences setValue:@YES forKey:@"developerExtrasEnabled"];
    }

    WKWebView *webview = [[ZeroNativeWebView alloc] initWithFrame:[self webViewFrameForWindow:window x:x y:y width:width height:height] configuration:configuration];
    ((ZeroNativeWebView *)webview).host = self;
    ((ZeroNativeWebView *)webview).windowId = windowId;
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
        WKWebView *webView = [self webViewForWindowId:windowId];
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
        WKWebView *webView = [self webViewForWindowId:windowId];
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
        WKWebView *webView = [self webViewForWindowId:windowId];
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
        WKWebView *webView = [self webViewForWindowId:windowId];
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
    if ([mainWebView isKindOfClass:[ZeroNativeWebView class]] && mainWebView.superview == contentView) {
        [views addObject:mainWebView];
    }

    NSString *prefix = [NSString stringWithFormat:@"%llu:", windowId];
    for (NSString *key in self.childWebViews) {
        if (![key hasPrefix:prefix]) continue;
        WKWebView *webView = self.childWebViews[key];
        if ([webView isKindOfClass:[ZeroNativeWebView class]] && webView.superview == contentView) {
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
        if (![views[index] isKindOfClass:[ZeroNativeWebView class]]) continue;
        ZeroNativeWebView *webView = (ZeroNativeWebView *)views[index];
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
         "var id='__zero_native_covered_mouse_rects__';"
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
    [webView.configuration.userContentController removeScriptMessageHandlerForName:@"zeroNativeBridge"];
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

static NSString *ZeroNativeAppKitBridgeScript(void) {
    return @"(function(){"
        "if(window.zero&&window.zero.invoke){return;}"
        "var pending=new Map();"
        "var listeners=new Map();"
        "var nextId=1;"
        "function post(message){"
        "if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.zeroNativeBridge){window.webkit.messageHandlers.zeroNativeBridge.postMessage(message);return;}"
        "if(window.zeroNativeCefBridge&&window.zeroNativeCefBridge.postMessage){window.zeroNativeCefBridge.postMessage(message);return;}"
        "throw new Error('zero-native bridge transport is unavailable');"
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
        "function emit(name,detail){var set=listeners.get(name);if(set){Array.from(set).forEach(function(callback){callback(detail);});}window.dispatchEvent(new CustomEvent('zero-native:'+name,{detail:detail}));}"
        "var commands=Object.freeze({"
        "invoke:function(value){return invoke('zero-native.command.invoke',commandPayload(value));},"
        "list:function(){return invoke('zero-native.command.list',{});}"
        "});"
        "var windows=Object.freeze({"
        "create:function(options){return invoke('zero-native.window.create',options||{});},"
        "list:function(){return invoke('zero-native.window.list',{});},"
        "focus:function(value){return invoke('zero-native.window.focus',selector(value));},"
        "close:function(value){return invoke('zero-native.window.close',selector(value));}"
        "});"
        "var dialogs=Object.freeze({"
        "openFile:function(options){return invoke('zero-native.dialog.openFile',options||{});},"
        "saveFile:function(options){return invoke('zero-native.dialog.saveFile',options||{});},"
        "showMessage:function(options){return invoke('zero-native.dialog.showMessage',options||{});}"
        "});"
        "function clipboardReadPayload(value){value=value||{};return {mimeType:ensureString(value.mimeType||value.type||'text/plain','mimeType')};}"
        "function clipboardWritePayload(value){if(typeof value==='string'){return {mimeType:'text/plain',data:value};}value=value||{};var data=value.data!=null?value.data:(value.text!=null?value.text:value.value);return {mimeType:ensureString(value.mimeType||value.type||'text/plain','mimeType'),data:ensureText(data,'data')};}"
        "var clipboard=Object.freeze({"
        "readText:function(){return invoke('zero-native.clipboard.readText',{});},"
        "writeText:function(value){var text=typeof value==='string'?value:(value||{}).text;return invoke('zero-native.clipboard.writeText',{text:ensureText(text,'text')});},"
        "read:function(value){return invoke('zero-native.clipboard.read',clipboardReadPayload(value));},"
        "write:function(value){return invoke('zero-native.clipboard.write',clipboardWritePayload(value));}"
        "});"
        "var os=Object.freeze({"
        "openUrl:function(value){var options=typeof value==='string'?{url:value}:(value||{});return invoke('zero-native.os.openUrl',{url:ensureString(options.url,'url')});},"
        "showNotification:function(value){var options=typeof value==='string'?{title:value}:(value||{});var payload={title:ensureString(options.title,'title')};if(options.subtitle!=null){payload.subtitle=ensureString(options.subtitle,'subtitle');}if(options.body!=null){payload.body=ensureString(options.body,'body');}return invoke('zero-native.os.showNotification',payload);},"
        "revealPath:function(value){var options=typeof value==='string'?{path:value}:(value||{});return invoke('zero-native.os.revealPath',{path:ensureString(options.path,'path')});},"
        "addRecentDocument:function(value){var options=typeof value==='string'?{path:value}:(value||{});return invoke('zero-native.os.addRecentDocument',{path:ensureString(options.path,'path')});},"
        "clearRecentDocuments:function(){return invoke('zero-native.os.clearRecentDocuments',{});}"
        "});"
        "function credentialPayload(value){value=value||{};return {service:ensureString(value.service,'service'),account:ensureString(value.account,'account')};}"
        "function credentialSetPayload(value){var payload=credentialPayload(value);payload.secret=ensureString(value.secret!=null?value.secret:value.value,'secret');return payload;}"
        "var credentials=Object.freeze({"
        "set:function(value){return invoke('zero-native.credentials.set',credentialSetPayload(value));},"
        "get:function(value){return invoke('zero-native.credentials.get',credentialPayload(value));},"
        "delete:function(value){return invoke('zero-native.credentials.delete',credentialPayload(value));}"
        "});"
        "function platformFeaturePayload(value){if(typeof value==='string'){return {feature:ensureString(value,'feature')};}value=value||{};return {feature:ensureString(value.feature!=null?value.feature:value.name,'feature')};}"
        "var platform=Object.freeze({"
        "supports:function(value){return invoke('zero-native.platform.supports',platformFeaturePayload(value));}"
        "});"
        "function zoomPayload(options){options=options||{};validateWebViewSelector(options);return {label:options.label,windowId:options.windowId,zoom:ensureNumber(options.zoom,'zoom')};}"
        "function layerPayload(options){options=options||{};validateWebViewSelector(options);return {label:options.label,windowId:options.windowId,layer:ensureNumber(options.layer,'layer')};}"
        "var webviews=Object.freeze({"
        "create:function(options){return invoke('zero-native.webview.create',createPayload(options)).then(webviewHandle);},"
        "list:function(){return invoke('zero-native.webview.list',{});},"
        "setFrame:function(options){return invoke('zero-native.webview.setFrame',framePayload(options));},"
        "navigate:function(options){return invoke('zero-native.webview.navigate',navigatePayload(options));},"
        "setZoom:function(options){return invoke('zero-native.webview.setZoom',zoomPayload(options));},"
        "setLayer:function(options){return invoke('zero-native.webview.setLayer',layerPayload(options));},"
        "close:function(options){return invoke('zero-native.webview.close',closePayload(options));}"
        "});"
        "var views=Object.freeze({"
        "create:function(options){return invoke('zero-native.view.create',viewCreatePayload(options)).then(viewHandle);},"
        "list:function(){return invoke('zero-native.view.list',{});},"
        "update:function(options,patch){if(typeof options==='string'){return invoke('zero-native.view.update',viewPatchPayload(Object.assign({},patch||{},{label:options}))).then(viewHandle);}return invoke('zero-native.view.update',viewPatchPayload(options)).then(viewHandle);},"
        "setFrame:function(options){return invoke('zero-native.view.setFrame',viewFramePayload(options)).then(viewHandle);},"
        "setVisible:function(options){return invoke('zero-native.view.setVisible',viewVisiblePayload(options)).then(viewHandle);},"
        "focus:function(options){return invoke('zero-native.view.focus',viewSelectorPayload(options)).then(viewHandle);},"
        "focusNext:function(options){options=options||{};return invoke('zero-native.view.focusNext',{windowId:options.windowId}).then(viewHandle);},"
        "focusPrevious:function(options){options=options||{};return invoke('zero-native.view.focusPrevious',{windowId:options.windowId}).then(viewHandle);},"
        "close:function(options){return invoke('zero-native.view.close',viewSelectorPayload(options));}"
        "});"
        "Object.defineProperty(window,'zero',{value:Object.freeze({invoke:invoke,on:on,off:off,commands:commands,windows:windows,dialogs:dialogs,clipboard:clipboard,os:os,credentials:credentials,platform:platform,webviews:webviews,views:views,_complete:complete,_emit:emit}),configurable:false});"
        "})();";
}

static NSString *ZeroNativeMimeTypeForPath(NSString *path) {
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

static BOOL ZeroNativeDirectoryExists(NSString *path) {
    BOOL isDirectory = NO;
    return path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory;
}

static NSString *ZeroNativeResolvedAssetRoot(NSString *rootPath) {
    NSString *resourcePath = [NSBundle mainBundle].resourcePath;
    BOOL isAppBundle = [[NSBundle mainBundle].bundlePath.pathExtension.lowercaseString isEqualToString:@"app"];
    if (rootPath.length == 0 || [rootPath isEqualToString:@"."]) {
        return (isAppBundle && resourcePath.length > 0) ? resourcePath : [[NSFileManager defaultManager] currentDirectoryPath];
    }
    if (rootPath.isAbsolutePath) return rootPath;
    NSString *cwdPath = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:rootPath];
    if (!isAppBundle && ZeroNativeDirectoryExists(cwdPath)) return cwdPath;
    if (resourcePath.length > 0) {
        NSString *resourceRoot = [resourcePath stringByAppendingPathComponent:rootPath];
        if (isAppBundle || ZeroNativeDirectoryExists(resourceRoot)) return resourceRoot;
    }
    return cwdPath;
}

static BOOL ZeroNativeFontAssetExtension(NSString *path) {
    NSString *extension = path.pathExtension.lowercaseString;
    return [extension isEqualToString:@"ttf"] ||
        [extension isEqualToString:@"otf"] ||
        [extension isEqualToString:@"ttc"] ||
        [extension isEqualToString:@"otc"] ||
        [extension isEqualToString:@"woff"] ||
        [extension isEqualToString:@"woff2"];
}

static void ZeroNativeRegisterFontsInDirectory(NSString *directoryPath) {
    if (directoryPath.length == 0 || !ZeroNativeDirectoryExists(directoryPath)) return;
    NSURL *directoryURL = [NSURL fileURLWithPath:directoryPath isDirectory:YES];
    NSDirectoryEnumerator<NSURL *> *enumerator = [[NSFileManager defaultManager]
        enumeratorAtURL:directoryURL
        includingPropertiesForKeys:@[ NSURLIsRegularFileKey ]
        options:NSDirectoryEnumerationSkipsHiddenFiles
        errorHandler:nil];
    for (NSURL *url in enumerator) {
        NSNumber *isRegularFile = nil;
        if (![url getResourceValue:&isRegularFile forKey:NSURLIsRegularFileKey error:nil] || !isRegularFile.boolValue) continue;
        if (!ZeroNativeFontAssetExtension(url.path)) continue;
        CFErrorRef error = NULL;
        CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &error);
        if (error) CFRelease(error);
    }
}

static void ZeroNativeRegisterBundledFonts(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *bundle = [NSBundle mainBundle];
        BOOL isAppBundle = [bundle.bundlePath.pathExtension.lowercaseString isEqualToString:@"app"];
        NSString *root = isAppBundle ? bundle.resourcePath : [[NSFileManager defaultManager] currentDirectoryPath];
        if (root.length == 0) return;
        NSArray<NSString *> *relativeFontRoots = @[ @"fonts", @"Fonts", @"assets/fonts" ];
        for (NSString *relativePath in relativeFontRoots) {
            ZeroNativeRegisterFontsInDirectory([root stringByAppendingPathComponent:relativePath]);
        }
    });
}

static BOOL ZeroNativePathHasUnsafeSegment(NSString *path) {
    for (NSString *segment in [path componentsSeparatedByString:@"/"]) {
        if (segment.length == 0) continue;
        if ([segment isEqualToString:@"."] || [segment isEqualToString:@".."]) return YES;
        if ([segment containsString:@"\\"]) return YES;
    }
    return NO;
}

static NSString *ZeroNativeSafeAssetPath(NSURL *url, NSString *entryPath) {
    if (!url) return nil;
    NSString *path = url.path.stringByRemovingPercentEncoding ?: url.path;
    if (path.length == 0 || [path isEqualToString:@"/"]) return entryPath.length > 0 ? entryPath : @"index.html";
    while ([path hasPrefix:@"/"]) {
        path = [path substringFromIndex:1];
    }
    if (path.length == 0) return entryPath.length > 0 ? entryPath : @"index.html";
    if (ZeroNativePathHasUnsafeSegment(path)) return nil;
    return path;
}

static NSURL *ZeroNativeAssetEntryURL(NSString *origin, NSString *entryPath) {
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

- (void)configureApplication {
    [[NSProcessInfo processInfo] setProcessName:self.appName];
    [self buildMenuBar];
    if (self.iconPath.length > 0) {
        NSImage *icon = [[NSImage alloc] initWithContentsOfFile:self.iconPath];
        if (icon) {
            [NSApp setApplicationIconImage:icon];
        }
    }
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
    [editMenu addItem:[self menuItem:@"Undo" action:@selector(undo:) key:@"z" modifiers:NSEventModifierFlagCommand]];
    [editMenu addItem:[self menuItem:@"Redo" action:@selector(redo:) key:@"Z" modifiers:NSEventModifierFlagCommand]];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItem:[self menuItem:@"Cut" action:@selector(cut:) key:@"x" modifiers:NSEventModifierFlagCommand]];
    [editMenu addItem:[self menuItem:@"Copy" action:@selector(copy:) key:@"c" modifiers:NSEventModifierFlagCommand]];
    [editMenu addItem:[self menuItem:@"Paste" action:@selector(paste:) key:@"v" modifiers:NSEventModifierFlagCommand]];
    [editMenu addItem:[self menuItem:@"Select All" action:@selector(selectAll:) key:@"a" modifiers:NSEventModifierFlagCommand]];

    NSMenuItem *viewMenuItem = [[NSMenuItem alloc] initWithTitle:@"View" action:nil keyEquivalent:@""];
    [mainMenu addItem:viewMenuItem];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    [viewMenuItem setSubmenu:viewMenu];
    [viewMenu addItem:[self menuItem:@"Reload" action:@selector(reload:) key:@"r" modifiers:NSEventModifierFlagCommand]];
    [viewMenu addItem:[self menuItem:@"Toggle Web Inspector" action:@selector(toggleWebInspector:) key:@"i" modifiers:(NSEventModifierFlagCommand | NSEventModifierFlagOption)]];
}

- (void)addApplicationMenuToMenu:(NSMenu *)mainMenu {
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:self.appName action:nil keyEquivalent:@""];
    [mainMenu addItem:appMenuItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:self.appName];
    [appMenuItem setSubmenu:appMenu];
    [appMenu addItem:[self menuItem:[NSString stringWithFormat:@"About %@", self.appName] action:@selector(orderFrontStandardAboutPanel:) key:@"" modifiers:0]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:[self menuItem:[NSString stringWithFormat:@"Preferences..."] action:@selector(showPreferences:) key:@"," modifiers:NSEventModifierFlagCommand]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:[self menuItem:[NSString stringWithFormat:@"Hide %@", self.appName] action:@selector(hide:) key:@"h" modifiers:NSEventModifierFlagCommand]];
    [appMenu addItem:[self menuItem:@"Hide Others" action:@selector(hideOtherApplications:) key:@"h" modifiers:(NSEventModifierFlagCommand | NSEventModifierFlagOption)]];
    [appMenu addItem:[self menuItem:@"Show All" action:@selector(unhideAllApplications:) key:@"" modifiers:0]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:[self menuItem:[NSString stringWithFormat:@"Quit %@", self.appName] action:@selector(terminate:) key:@"q" modifiers:NSEventModifierFlagCommand]];
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
    item.keyEquivalentModifierMask = ZeroNativeMenuModifierFlags(modifiers);
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
    [self emitEvent:(zero_native_appkit_event_t){
        .kind = ZERO_NATIVE_APPKIT_EVENT_MENU_COMMAND,
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

- (void)runWithCallback:(zero_native_appkit_event_callback_t)callback context:(void *)context {
    self.callback = callback;
    self.context = context;

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activate];
    if (!self.shortcutEventMonitor) {
        __weak ZeroNativeAppKitHost *weakSelf = self;
        self.shortcutEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
            ZeroNativeAppKitHost *strongSelf = weakSelf;
            if (strongSelf && [strongSelf handleShortcutEvent:event]) return nil;
            return event;
        }];
    }

    [self startApplicationActivationObservers];
    [self startAppearanceObservers];

    [self emitEvent:(zero_native_appkit_event_t){ .kind = ZERO_NATIVE_APPKIT_EVENT_START }];
    [self emitAppearanceChanged];
    [self emitResize];
    [self emitWindowFrame:YES];

    [self scheduleFrame];
    [NSApp run];
}

- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
    [self.automationFrameTimer invalidate];
    self.automationFrameTimer = nil;
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

- (void)emitEvent:(zero_native_appkit_event_t)event {
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
    [self emitEvent:(zero_native_appkit_event_t){ .kind = ZERO_NATIVE_APPKIT_EVENT_APP_ACTIVATED }];
}

- (void)applicationDidResignActive:(NSNotification *)notification {
    (void)notification;
    [self emitEvent:(zero_native_appkit_event_t){ .kind = ZERO_NATIVE_APPKIT_EVENT_APP_DEACTIVATED }];
}

- (void)startAppearanceObservers {
    if (self.observesAppearanceChanges) {
        return;
    }
    [NSApp addObserver:self forKeyPath:@"effectiveAppearance" options:NSKeyValueObservingOptionNew context:ZeroNativeAppKitAppearanceObservationContext];
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
    [NSApp removeObserver:self forKeyPath:@"effectiveAppearance" context:ZeroNativeAppKitAppearanceObservationContext];
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
    if (context == ZeroNativeAppKitAppearanceObservationContext) {
        [self emitAppearanceChanged];
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)emitAppearanceChanged {
    [self emitEvent:(zero_native_appkit_event_t){
        .kind = ZERO_NATIVE_APPKIT_EVENT_APPEARANCE_CHANGED,
        .color_scheme = ZeroNativeAppKitColorSchemeForAppearance(NSApp.effectiveAppearance),
        .reduce_motion = ZeroNativeAppKitReduceMotionEnabled() ? 1 : 0,
        .high_contrast = ZeroNativeAppKitHighContrastEnabled() ? 1 : 0,
    }];
}

- (void)emitResize {
    [self emitResizeForWindowId:1];
}

- (void)emitResizeForWindowId:(uint64_t)windowId {
    NSWindow *window = self.windows[@(windowId)] ?: self.window;
    NSRect bounds = window.contentView.bounds;
    [self emitEvent:(zero_native_appkit_event_t){
        .kind = ZERO_NATIVE_APPKIT_EVENT_RESIZE,
        .window_id = windowId,
        .width = bounds.size.width,
        .height = bounds.size.height,
        .scale = window.backingScaleFactor,
    }];
}

- (void)emitDeferredResizeForWindowId:(uint64_t)windowId {
    __weak ZeroNativeAppKitHost *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ZeroNativeAppKitHost *strongSelf = weakSelf;
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
    [self emitEvent:(zero_native_appkit_event_t){
        .kind = ZERO_NATIVE_APPKIT_EVENT_WINDOW_FRAME,
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
    self.timer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 60.0)
                                                 target:self
                                               selector:@selector(emitFrame)
                                               userInfo:nil
                                                repeats:NO];
}

- (void)setAutomationFramePolling:(BOOL)enabled {
    if (!enabled) {
        [self.automationFrameTimer invalidate];
        self.automationFrameTimer = nil;
        return;
    }
    if (self.automationFrameTimer) return;
    self.automationFrameTimer = [NSTimer scheduledTimerWithTimeInterval:ZeroNativeAutomationFramePollInterval
                                                                 target:self
                                                               selector:@selector(emitAutomationFramePoll)
                                                               userInfo:nil
                                                                repeats:YES];
}

- (void)emitAutomationFramePoll {
    [self scheduleFrame];
}

- (void)scheduleBridgeFrames {
    self.bridgeFrameKeepalive = ZeroNativeBridgeFrameKeepaliveFrames;
    [self scheduleFrame];
}

- (void)emitFrame {
    self.timer = nil;
    [self emitEvent:(zero_native_appkit_event_t){ .kind = ZERO_NATIVE_APPKIT_EVENT_FRAME }];
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
    [self emitEvent:(zero_native_appkit_event_t){ .kind = ZERO_NATIVE_APPKIT_EVENT_SHUTDOWN }];
}

- (void)loadSource:(NSString *)source kind:(NSInteger)kind assetRoot:(NSString *)assetRoot entry:(NSString *)entry origin:(NSString *)origin spaFallback:(BOOL)spaFallback {
    [self loadSource:source kind:kind assetRoot:assetRoot entry:entry origin:origin spaFallback:spaFallback windowId:1];
}

- (void)loadSource:(NSString *)source kind:(NSInteger)kind assetRoot:(NSString *)assetRoot entry:(NSString *)entry origin:(NSString *)origin spaFallback:(BOOL)spaFallback windowId:(uint64_t)windowId {
    WKWebView *webView = [self webViewForWindowId:windowId];
    ZeroNativeAssetSchemeHandler *assetSchemeHandler = [self assetHandlerForWindowId:windowId];
    if (kind == 1) {
        NSURL *url = [NSURL URLWithString:source];
        if (url) {
            [webView loadRequest:[NSURLRequest requestWithURL:url]];
        }
    } else if (kind == 2) {
        [assetSchemeHandler configureWithRootPath:assetRoot entryPath:entry spaFallback:spaFallback];
        NSURL *url = ZeroNativeAssetEntryURL(origin.length > 0 ? origin : @"zero://app", entry.length > 0 ? entry : @"index.html");
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
    return ZeroNativePolicyListMatches(self.allowedNavigationOrigins, url);
}

- (BOOL)openExternalURLIfAllowed:(NSURL *)url {
    if (self.externalLinkAction != 1) return NO;
    if (!ZeroNativePolicyListMatches(self.allowedExternalURLs, url)) return NO;
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
    NSString *key = ZeroNativeShortcutKeyForEvent(event);
    if (key.length == 0) return NO;
    BOOL usesImplicitShift = ZeroNativeShortcutUsesImplicitShift(key, event);

    for (NSUInteger pass = 0; pass < (usesImplicitShift ? 2 : 1); pass++) {
        BOOL allowImplicitShift = pass == 1;
        for (ZeroNativeShortcut *shortcut in self.shortcuts) {
            if (![shortcut.key isEqualToString:key]) continue;
            if (!ZeroNativeShortcutModifiersMatch(shortcut.modifiers, event.modifierFlags, allowImplicitShift)) continue;
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
    [self emitEvent:(zero_native_appkit_event_t){
        .kind = ZERO_NATIVE_APPKIT_EVENT_SHORTCUT,
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
    [self emitEvent:(zero_native_appkit_event_t){
        .kind = ZERO_NATIVE_APPKIT_EVENT_FILES_DROPPED,
        .window_id = windowId,
        .drop_paths = data.bytes,
        .drop_paths_len = data.length,
    }];
    return YES;
}

- (void)setShortcutsWithIds:(const char *const *)ids idLengths:(const size_t *)idLengths keys:(const char *const *)keys keyLengths:(const size_t *)keyLengths modifiers:(const uint32_t *)modifiers count:(size_t)count {
    NSMutableArray<ZeroNativeShortcut *> *items = [[NSMutableArray alloc] initWithCapacity:count];
    for (size_t index = 0; index < count; index++) {
        NSString *identifier = ids[index] ? [[NSString alloc] initWithBytes:ids[index] length:idLengths[index] encoding:NSUTF8StringEncoding] : @"";
        NSString *key = keys[index] ? [[NSString alloc] initWithBytes:keys[index] length:keyLengths[index] encoding:NSUTF8StringEncoding] : @"";
        if (identifier.length == 0 || key.length == 0) continue;
        ZeroNativeShortcut *shortcut = [[ZeroNativeShortcut alloc] init];
        shortcut.identifier = identifier;
        shortcut.key = key.lowercaseString;
        shortcut.modifiers = modifiers[index];
        [items addObject:shortcut];
    }
    self.shortcuts = items;
}

- (void)showPreferences:(id)sender {
    (void)sender;
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

static NSArray<NSString *> *ZeroNativePolicyListFromBytes(const char *bytes, size_t len, NSArray<NSString *> *fallback) {
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

static NSString *ZeroNativeOriginForURL(NSURL *url) {
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

static NSString *ZeroNativeShortcutKeyForEvent(NSEvent *event) {
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

static BOOL ZeroNativeShortcutUsesImplicitShift(NSString *key, NSEvent *event) {
    if ((event.modifierFlags & NSEventModifierFlagShift) == 0) return NO;
    if (key.length != 1) return NO;
    unichar ch = [key characterAtIndex:0];
    return (ch >= '0' && ch <= '9') ||
        ch == '=' || ch == '-' || ch == ',' ||
        ch == '.' || ch == '/' || ch == ';' || ch == '\'' ||
        ch == '[' || ch == ']' || ch == '\\' || ch == '`';
}

static BOOL ZeroNativeShortcutModifiersMatch(uint32_t shortcutModifiers, NSEventModifierFlags eventModifiers, BOOL allowImplicitShift) {
    NSEventModifierFlags flags = eventModifiers & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL needsCommand = (shortcutModifiers & ZeroNativeShortcutModifierCommand) != 0 || (shortcutModifiers & ZeroNativeShortcutModifierPrimary) != 0;
    BOOL needsControl = (shortcutModifiers & ZeroNativeShortcutModifierControl) != 0;
    BOOL needsOption = (shortcutModifiers & ZeroNativeShortcutModifierOption) != 0;
    BOOL needsShift = (shortcutModifiers & ZeroNativeShortcutModifierShift) != 0;
    BOOL hasCommand = (flags & NSEventModifierFlagCommand) != 0;
    BOOL hasControl = (flags & NSEventModifierFlagControl) != 0;
    BOOL hasOption = (flags & NSEventModifierFlagOption) != 0;
    BOOL hasShift = (flags & NSEventModifierFlagShift) != 0;
    BOOL shiftMatches = needsShift ? hasShift : (!hasShift || allowImplicitShift);
    return hasCommand == needsCommand && hasControl == needsControl && hasOption == needsOption && shiftMatches;
}

static NSEventModifierFlags ZeroNativeMenuModifierFlags(uint32_t modifiers) {
    NSEventModifierFlags flags = 0;
    if ((modifiers & ZeroNativeShortcutModifierPrimary) != 0 || (modifiers & ZeroNativeShortcutModifierCommand) != 0) flags |= NSEventModifierFlagCommand;
    if ((modifiers & ZeroNativeShortcutModifierControl) != 0) flags |= NSEventModifierFlagControl;
    if ((modifiers & ZeroNativeShortcutModifierOption) != 0) flags |= NSEventModifierFlagOption;
    if ((modifiers & ZeroNativeShortcutModifierShift) != 0) flags |= NSEventModifierFlagShift;
    return flags;
}

static BOOL ZeroNativeWildcardPrefixHasPath(NSString *prefix) {
    NSURLComponents *components = [NSURLComponents componentsWithString:prefix ?: @""];
    return components.scheme.length > 0 && components.host.length > 0 && components.percentEncodedPath.length > 0;
}

static BOOL ZeroNativePolicyListMatches(NSArray<NSString *> *values, NSURL *url) {
    NSString *origin = ZeroNativeOriginForURL(url);
    NSString *absolute = url.absoluteString ?: @"";
    for (NSString *value in values) {
        if ([value isEqualToString:@"*"]) return YES;
        if ([value isEqualToString:origin] || [value isEqualToString:absolute]) return YES;
        if ([value hasSuffix:@"*"]) {
            NSString *prefix = [value substringToIndex:value.length - 1];
            if (ZeroNativeWildcardPrefixHasPath(prefix) && [absolute hasPrefix:prefix]) return YES;
        }
    }
    return NO;
}

zero_native_appkit_host_t *zero_native_appkit_create(const char *app_name, size_t app_name_len, const char *window_title, size_t window_title_len, const char *bundle_id, size_t bundle_id_len, const char *icon_path, size_t icon_path_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame) {
    @autoreleasepool {
        NSString *appNameString = [[NSString alloc] initWithBytes:app_name length:app_name_len encoding:NSUTF8StringEncoding] ?: @"zero-native";
        NSString *windowTitleString = [[NSString alloc] initWithBytes:window_title length:window_title_len encoding:NSUTF8StringEncoding] ?: appNameString;
        NSString *bundleIdString = [[NSString alloc] initWithBytes:bundle_id length:bundle_id_len encoding:NSUTF8StringEncoding] ?: @"dev.zero_native.app";
        NSString *iconPathString = [[NSString alloc] initWithBytes:icon_path length:icon_path_len encoding:NSUTF8StringEncoding] ?: @"";
        NSString *windowLabelString = [[NSString alloc] initWithBytes:window_label length:window_label_len encoding:NSUTF8StringEncoding] ?: @"main";
        ZeroNativeAppKitHost *host = [[ZeroNativeAppKitHost alloc] initWithAppName:appNameString windowTitle:windowTitleString bundleIdentifier:bundleIdString iconPath:iconPathString windowLabel:windowLabelString x:x y:y width:width height:height restoreFrame:(restore_frame != 0)];
        return (__bridge_retained zero_native_appkit_host_t *)host;
    }
}

void zero_native_appkit_destroy(zero_native_appkit_host_t *host) {
    if (!host) {
        return;
    }
    CFBridgingRelease(host);
}

void zero_native_appkit_run(zero_native_appkit_host_t *host, zero_native_appkit_event_callback_t callback, void *context) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    [object runWithCallback:callback context:context];
}

void zero_native_appkit_set_automation_frame_polling(zero_native_appkit_host_t *host, int enabled) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    [object setAutomationFramePolling:(enabled != 0)];
}

void zero_native_appkit_stop(zero_native_appkit_host_t *host) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    [object emitShutdown];
    [object stop];
}

void zero_native_appkit_load_webview(zero_native_appkit_host_t *host, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback) {
    zero_native_appkit_load_window_webview(host, 1, source, source_len, source_kind, asset_root, asset_root_len, asset_entry, asset_entry_len, asset_origin, asset_origin_len, spa_fallback);
}

void zero_native_appkit_load_window_webview(zero_native_appkit_host_t *host, uint64_t window_id, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
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

void zero_native_appkit_set_bridge_callback(zero_native_appkit_host_t *host, zero_native_appkit_bridge_callback_t callback, void *context) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    object.bridgeCallback = callback;
    object.bridgeContext = context;
}

void zero_native_appkit_bridge_respond(zero_native_appkit_host_t *host, const char *response, size_t response_len) {
    zero_native_appkit_bridge_respond_window(host, 1, response, response_len);
}

void zero_native_appkit_bridge_respond_window(zero_native_appkit_host_t *host, uint64_t window_id, const char *response, size_t response_len) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *responseString = response ? [[NSString alloc] initWithBytes:response length:response_len encoding:NSUTF8StringEncoding] : @"{}";
    [object completeBridgeWithResponse:responseString ?: @"{}" windowId:window_id];
}

void zero_native_appkit_bridge_respond_webview(zero_native_appkit_host_t *host, uint64_t window_id, const char *webview_label, size_t webview_label_len, const char *response, size_t response_len) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *labelString = webview_label ? [[NSString alloc] initWithBytes:webview_label length:webview_label_len encoding:NSUTF8StringEncoding] : @"main";
    NSString *responseString = response ? [[NSString alloc] initWithBytes:response length:response_len encoding:NSUTF8StringEncoding] : @"{}";
    [object completeBridgeWithResponse:responseString ?: @"{}" windowId:window_id webViewLabel:labelString ?: @"main"];
}

void zero_native_appkit_emit_window_event(zero_native_appkit_host_t *host, uint64_t window_id, const char *name, size_t name_len, const char *detail_json, size_t detail_json_len) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *nameString = name ? [[NSString alloc] initWithBytes:name length:name_len encoding:NSUTF8StringEncoding] : @"";
    NSString *detailString = detail_json ? [[NSString alloc] initWithBytes:detail_json length:detail_json_len encoding:NSUTF8StringEncoding] : @"null";
    [object emitEventNamed:nameString ?: @"" detailJSON:detailString ?: @"null" windowId:window_id];
}

void zero_native_appkit_set_security_policy(zero_native_appkit_host_t *host, const char *allowed_origins, size_t allowed_origins_len, const char *external_urls, size_t external_urls_len, int external_action) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSArray<NSString *> *origins = ZeroNativePolicyListFromBytes(allowed_origins, allowed_origins_len, @[ @"zero://app", @"zero://inline" ]);
    NSArray<NSString *> *externalURLs = ZeroNativePolicyListFromBytes(external_urls, external_urls_len, @[]);
    [object setAllowedNavigationOrigins:origins externalURLs:externalURLs externalAction:external_action];
}

void zero_native_appkit_set_menus(zero_native_appkit_host_t *host, const char *const *menu_titles, const size_t *menu_title_lens, size_t menu_count, const uint32_t *item_menu_indices, const char *const *item_labels, const size_t *item_label_lens, const char *const *item_commands, const size_t *item_command_lens, const char *const *item_keys, const size_t *item_key_lens, const uint32_t *item_modifiers, const int *item_separators, const int *item_enabled, const int *item_checked, size_t item_count) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    [object setMenusWithTitles:menu_titles titleLengths:menu_title_lens count:menu_count itemMenuIndices:item_menu_indices itemLabels:item_labels itemLabelLengths:item_label_lens itemCommands:item_commands itemCommandLengths:item_command_lens itemKeys:item_keys itemKeyLengths:item_key_lens itemModifiers:item_modifiers itemSeparators:item_separators itemEnabled:item_enabled itemChecked:item_checked itemCount:item_count];
}

void zero_native_appkit_set_shortcuts(zero_native_appkit_host_t *host, const char *const *ids, const size_t *id_lens, const char *const *keys, const size_t *key_lens, const uint32_t *modifiers, size_t count) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    [object setShortcutsWithIds:ids idLengths:id_lens keys:keys keyLengths:key_lens modifiers:modifiers count:count];
}

int zero_native_appkit_create_window(zero_native_appkit_host_t *host, uint64_t window_id, const char *window_title, size_t window_title_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *titleString = window_title ? [[NSString alloc] initWithBytes:window_title length:window_title_len encoding:NSUTF8StringEncoding] : @"";
    NSString *labelString = window_label ? [[NSString alloc] initWithBytes:window_label length:window_label_len encoding:NSUTF8StringEncoding] : @"";
    return [object createWindowWithId:window_id title:titleString ?: @"" label:labelString ?: @"" x:x y:y width:width height:height restoreFrame:(restore_frame != 0) makeMain:NO] ? 1 : 0;
}

int zero_native_appkit_focus_window(zero_native_appkit_host_t *host, uint64_t window_id) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    if (!object.windows[@(window_id)]) return 0;
    [object focusWindowWithId:window_id];
    return 1;
}

int zero_native_appkit_close_window(zero_native_appkit_host_t *host, uint64_t window_id) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    if (!object.windows[@(window_id)]) return 0;
    [object closeWindowWithId:window_id];
    return 1;
}

int zero_native_appkit_create_view(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int kind, const char *parent, size_t parent_len, double x, double y, double width, double height, int layer, int visible, int enabled, const char *role, size_t role_len, const char *accessibility_label, size_t accessibility_label_len, const char *text, size_t text_len, const char *command, size_t command_len) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    NSString *parentString = parent ? [[NSString alloc] initWithBytes:parent length:parent_len encoding:NSUTF8StringEncoding] : @"";
    NSString *roleString = role ? [[NSString alloc] initWithBytes:role length:role_len encoding:NSUTF8StringEncoding] : @"";
    NSString *accessibilityLabelString = accessibility_label ? [[NSString alloc] initWithBytes:accessibility_label length:accessibility_label_len encoding:NSUTF8StringEncoding] : @"";
    NSString *textString = text ? [[NSString alloc] initWithBytes:text length:text_len encoding:NSUTF8StringEncoding] : @"";
    NSString *commandString = command ? [[NSString alloc] initWithBytes:command length:command_len encoding:NSUTF8StringEncoding] : @"";
    return [object createNativeViewInWindow:window_id label:labelString ?: @"" kind:kind parent:parentString ?: @"" x:x y:y width:width height:height layer:layer visible:(visible != 0) enabled:(enabled != 0) role:roleString ?: @"" accessibilityLabel:accessibilityLabelString ?: @"" text:textString ?: @"" command:commandString ?: @""] ? 1 : 0;
}

int zero_native_appkit_update_view(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int has_frame, double x, double y, double width, double height, int has_layer, int layer, int has_visible, int visible, int has_enabled, int enabled, int has_role, const char *role, size_t role_len, int has_accessibility_label, const char *accessibility_label, size_t accessibility_label_len, int has_text, const char *text, size_t text_len, int has_command, const char *command, size_t command_len) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    NSString *roleString = role ? [[NSString alloc] initWithBytes:role length:role_len encoding:NSUTF8StringEncoding] : @"";
    NSString *accessibilityLabelString = accessibility_label ? [[NSString alloc] initWithBytes:accessibility_label length:accessibility_label_len encoding:NSUTF8StringEncoding] : @"";
    NSString *textString = text ? [[NSString alloc] initWithBytes:text length:text_len encoding:NSUTF8StringEncoding] : @"";
    NSString *commandString = command ? [[NSString alloc] initWithBytes:command length:command_len encoding:NSUTF8StringEncoding] : @"";
    return [object updateNativeViewInWindow:window_id label:labelString ?: @"" hasFrame:(has_frame != 0) x:x y:y width:width height:height hasLayer:(has_layer != 0) layer:layer hasVisible:(has_visible != 0) visible:(visible != 0) hasEnabled:(has_enabled != 0) enabled:(enabled != 0) hasRole:(has_role != 0) role:roleString ?: @"" hasAccessibilityLabel:(has_accessibility_label != 0) accessibilityLabel:accessibilityLabelString ?: @"" hasText:(has_text != 0) text:textString ?: @"" hasCommand:(has_command != 0) command:commandString ?: @""] ? 1 : 0;
}

int zero_native_appkit_set_view_frame(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object setNativeViewFrameInWindow:window_id label:labelString ?: @"" x:x y:y width:width height:height] ? 1 : 0;
}

int zero_native_appkit_set_view_visible(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int visible) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object setNativeViewVisibleInWindow:window_id label:labelString ?: @"" visible:(visible != 0)] ? 1 : 0;
}

int zero_native_appkit_set_view_cursor(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int cursor) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object setNativeViewCursorInWindow:window_id label:labelString ?: @"" cursor:cursor] ? 1 : 0;
}

int zero_native_appkit_focus_view(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object focusNativeViewInWindow:window_id label:labelString ?: @""] ? 1 : 0;
}

int zero_native_appkit_close_view(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object closeNativeViewInWindow:window_id label:labelString ?: @""] ? 1 : 0;
}

int zero_native_appkit_present_gpu_surface_pixels(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, size_t width, size_t height, double scale, int has_dirty_rect, double dirty_x, double dirty_y, double dirty_width, double dirty_height, const uint8_t *rgba8, size_t rgba8_len) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object presentGpuSurfacePixelsInWindow:window_id label:labelString ?: @"" width:width height:height scale:scale hasDirtyRect:(has_dirty_rect != 0) dirtyX:dirty_x dirtyY:dirty_y dirtyWidth:dirty_width dirtyHeight:dirty_height rgba8:rgba8 byteLength:rgba8_len] ? 1 : 0;
}

int zero_native_appkit_present_gpu_surface_packet(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double surface_width, double surface_height, double scale, uint8_t clear_r, uint8_t clear_g, uint8_t clear_b, uint8_t clear_a, int requires_render, size_t command_count, size_t unsupported_command_count, int representable, const uint8_t *json, size_t json_len) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return (int)[object presentGpuSurfacePacketInWindow:window_id label:labelString ?: @"" surfaceWidth:surface_width height:surface_height scale:scale clearR:clear_r clearG:clear_g clearB:clear_b clearA:clear_a requiresRender:(requires_render != 0) commandCount:command_count unsupportedCommandCount:unsupported_command_count representable:(representable != 0) json:json byteLength:json_len];
}

int zero_native_appkit_request_gpu_surface_frame(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object requestGpuSurfaceFrameInWindow:window_id label:labelString ?: @""] ? 1 : 0;
}

int zero_native_appkit_update_widget_accessibility(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, const zero_native_appkit_widget_accessibility_node_t *nodes, size_t node_count) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object updateWidgetAccessibilityInWindow:window_id label:labelString ?: @"" nodes:nodes count:node_count] ? 1 : 0;
}

int zero_native_appkit_create_webview(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len, double x, double y, double width, double height, int layer, int transparent, int bridge_enabled) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    NSString *urlString = url ? [[NSString alloc] initWithBytes:url length:url_len encoding:NSUTF8StringEncoding] : @"";
    return [object createWebViewInWindow:window_id label:labelString ?: @"" url:urlString ?: @"" x:x y:y width:width height:height layer:layer transparent:transparent != 0 bridgeEnabled:bridge_enabled != 0] ? 1 : 0;
}

int zero_native_appkit_set_webview_frame(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object setWebViewFrameInWindow:window_id label:labelString ?: @"" x:x y:y width:width height:height] ? 1 : 0;
}

int zero_native_appkit_navigate_webview(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    NSString *urlString = url ? [[NSString alloc] initWithBytes:url length:url_len encoding:NSUTF8StringEncoding] : @"";
    return [object navigateWebViewInWindow:window_id label:labelString ?: @"" url:urlString ?: @""] ? 1 : 0;
}

int zero_native_appkit_set_webview_zoom(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double zoom) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object setWebViewZoomInWindow:window_id label:labelString ?: @"" zoom:zoom] ? 1 : 0;
}

int zero_native_appkit_set_webview_layer(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int layer) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object setWebViewLayerInWindow:window_id label:labelString ?: @"" layer:layer] ? 1 : 0;
}

int zero_native_appkit_close_webview(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object closeWebViewInWindow:window_id label:labelString ?: @""] ? 1 : 0;
}

size_t zero_native_appkit_clipboard_read(zero_native_appkit_host_t *host, char *buffer, size_t buffer_len) {
    return zero_native_appkit_clipboard_read_data(host, "text/plain", strlen("text/plain"), buffer, buffer_len);
}

void zero_native_appkit_clipboard_write(zero_native_appkit_host_t *host, const char *text, size_t text_len) {
    (void)zero_native_appkit_clipboard_write_data(host, "text/plain", strlen("text/plain"), text, text_len);
}

size_t zero_native_appkit_clipboard_read_data(zero_native_appkit_host_t *host, const char *mime_type, size_t mime_type_len, char *buffer, size_t buffer_len) {
    (void)host;
    NSString *type = ZeroNativePasteboardTypeForMime(mime_type, mime_type_len);
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

int zero_native_appkit_clipboard_write_data(zero_native_appkit_host_t *host, const char *mime_type, size_t mime_type_len, const char *bytes, size_t bytes_len) {
    (void)host;
    NSString *type = ZeroNativePasteboardTypeForMime(mime_type, mime_type_len);
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

int zero_native_appkit_show_notification(zero_native_appkit_host_t *host, const char *title, size_t title_len, const char *subtitle, size_t subtitle_len, const char *body, size_t body_len) {
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

int zero_native_appkit_open_external_url(zero_native_appkit_host_t *host, const char *url, size_t url_len) {
    (void)host;
    NSString *urlString = url ? [[NSString alloc] initWithBytes:url length:url_len encoding:NSUTF8StringEncoding] : @"";
    if (urlString.length == 0) return 0;
    NSURL *target = [NSURL URLWithString:urlString];
    if (!target || target.scheme.length == 0) return 0;
    return [[NSWorkspace sharedWorkspace] openURL:target] ? 1 : 0;
}

int zero_native_appkit_reveal_path(zero_native_appkit_host_t *host, const char *path, size_t path_len) {
    (void)host;
    NSString *pathString = path ? [[NSString alloc] initWithBytes:path length:path_len encoding:NSUTF8StringEncoding] : @"";
    if (pathString.length == 0) return 0;
    NSURL *fileURL = [NSURL fileURLWithPath:pathString];
    if (!fileURL) return 0;
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ fileURL ]];
    return 1;
}

int zero_native_appkit_add_recent_document(zero_native_appkit_host_t *host, const char *path, size_t path_len) {
    (void)host;
    NSString *pathString = path ? [[NSString alloc] initWithBytes:path length:path_len encoding:NSUTF8StringEncoding] : @"";
    if (pathString.length == 0) return 0;
    NSURL *fileURL = [NSURL fileURLWithPath:pathString];
    if (!fileURL) return 0;
    [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:fileURL];
    return 1;
}

int zero_native_appkit_clear_recent_documents(zero_native_appkit_host_t *host) {
    (void)host;
    [[NSDocumentController sharedDocumentController] clearRecentDocuments:nil];
    return 1;
}

int zero_native_appkit_set_credential(zero_native_appkit_host_t *host, const char *service, size_t service_len, const char *account, size_t account_len, const char *secret, size_t secret_len) {
    (void)host;
    @autoreleasepool {
        NSString *serviceString = ZeroNativeStringFromBytes(service, service_len);
        NSString *accountString = ZeroNativeStringFromBytes(account, account_len);
        if (serviceString.length == 0 || accountString.length == 0 || !secret || secret_len == 0) return 0;
        NSData *secretData = [NSData dataWithBytes:secret length:secret_len];
        NSMutableDictionary *query = ZeroNativeCredentialQuery(serviceString, accountString);
        NSDictionary *update = @{ (__bridge id)kSecValueData: secretData };
        OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)update);
        if (status == errSecItemNotFound) {
            query[(__bridge id)kSecValueData] = secretData;
            status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
        }
        return status == errSecSuccess ? 1 : 0;
    }
}

size_t zero_native_appkit_get_credential(zero_native_appkit_host_t *host, const char *service, size_t service_len, const char *account, size_t account_len, char *buffer, size_t buffer_len) {
    (void)host;
    @autoreleasepool {
        NSString *serviceString = ZeroNativeStringFromBytes(service, service_len);
        NSString *accountString = ZeroNativeStringFromBytes(account, account_len);
        if (serviceString.length == 0 || accountString.length == 0 || !buffer) return 0;
        NSMutableDictionary *query = ZeroNativeCredentialQuery(serviceString, accountString);
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

int zero_native_appkit_delete_credential(zero_native_appkit_host_t *host, const char *service, size_t service_len, const char *account, size_t account_len) {
    (void)host;
    @autoreleasepool {
        NSString *serviceString = ZeroNativeStringFromBytes(service, service_len);
        NSString *accountString = ZeroNativeStringFromBytes(account, account_len);
        if (serviceString.length == 0 || accountString.length == 0) return 0;
        NSMutableDictionary *query = ZeroNativeCredentialQuery(serviceString, accountString);
        OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
        return status == errSecSuccess ? 1 : 0;
    }
}

static NSArray<NSString *> *ZeroNativeParseExtensions(const char *extensions, size_t len) {
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

static void ZeroNativeConfigurePanelExtensions(NSSavePanel *panel, NSArray<NSString *> *extensions) {
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

zero_native_appkit_open_dialog_result_t zero_native_appkit_show_open_dialog(zero_native_appkit_host_t *host, const zero_native_appkit_open_dialog_opts_t *opts, char *buffer, size_t buffer_len) {
    (void)host;
    zero_native_appkit_open_dialog_result_t result = { .count = 0, .bytes_written = 0 };
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
        ZeroNativeConfigurePanelExtensions(panel, ZeroNativeParseExtensions(opts->extensions, opts->extensions_len));

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
        result.bytes_written = overflow ? ZeroNativeOverflowSize(buffer_len) : offset;
    }
    return result;
}

size_t zero_native_appkit_show_save_dialog(zero_native_appkit_host_t *host, const zero_native_appkit_save_dialog_opts_t *opts, char *buffer, size_t buffer_len) {
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
        ZeroNativeConfigurePanelExtensions(panel, ZeroNativeParseExtensions(opts->extensions, opts->extensions_len));

        if ([panel runModal] != NSModalResponseOK) return 0;

        NSString *path = panel.URL.path;
        NSData *data = [path dataUsingEncoding:NSUTF8StringEncoding];
        if (!data) return 0;
        size_t count = data.length;
        if (count > buffer_len) return ZeroNativeOverflowSize(buffer_len);
        memcpy(buffer, data.bytes, count);
        return count;
    }
}

int zero_native_appkit_show_message_dialog(zero_native_appkit_host_t *host, const zero_native_appkit_message_dialog_opts_t *opts) {
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

void zero_native_appkit_create_tray(zero_native_appkit_host_t *host, const char *icon_path, size_t icon_path_len, const char *tooltip, size_t tooltip_len) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    @autoreleasepool {
        if (object.statusItem) {
            [[NSStatusBar systemStatusBar] removeStatusItem:object.statusItem];
        }
        object.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];

        if (icon_path && icon_path_len > 0) {
            NSString *path = [[NSString alloc] initWithBytes:icon_path length:icon_path_len encoding:NSUTF8StringEncoding];
            NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
            if (image) {
                image.template = YES;
                image.size = NSMakeSize(18, 18);
                object.statusItem.button.image = image;
            }
        }
        if (!object.statusItem.button.image) {
            object.statusItem.button.title = object.appName.length > 0 ? [object.appName substringToIndex:MIN(1, object.appName.length)] : @"Z";
        }
        if (tooltip && tooltip_len > 0) {
            object.statusItem.button.toolTip = [[NSString alloc] initWithBytes:tooltip length:tooltip_len encoding:NSUTF8StringEncoding];
        }
    }
}

void zero_native_appkit_update_tray_menu(zero_native_appkit_host_t *host, const uint32_t *item_ids, const char *const *labels, const size_t *label_lens, const int *separators, const int *enabled_flags, size_t count) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
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

void zero_native_appkit_remove_tray(zero_native_appkit_host_t *host) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    if (object.statusItem) {
        [[NSStatusBar systemStatusBar] removeStatusItem:object.statusItem];
        object.statusItem = nil;
    }
}

void zero_native_appkit_set_tray_callback(zero_native_appkit_host_t *host, zero_native_appkit_tray_callback_t callback, void *context) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    object.trayCallback = callback;
    object.trayContext = context;
}
