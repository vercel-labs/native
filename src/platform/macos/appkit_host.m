#import "appkit_host.h"

#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Security/Security.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <string.h>

@class ZeroNativeAppKitHost;

static const NSUInteger ZeroNativeMaxChildWebViews = 16;
static const NSUInteger ZeroNativeMaxNativeViews = 32;
static const NSInteger ZeroNativeBridgeFrameKeepaliveFrames = 600;
static const uint32_t ZeroNativeShortcutModifierPrimary = 1u << 0;
static const uint32_t ZeroNativeShortcutModifierCommand = 1u << 1;
static const uint32_t ZeroNativeShortcutModifierControl = 1u << 2;
static const uint32_t ZeroNativeShortcutModifierOption = 1u << 3;
static const uint32_t ZeroNativeShortcutModifierShift = 1u << 4;
static NSRect constrainFrame(NSRect frame);
static NSString *ZeroNativeAppKitBridgeScript(void);
static NSString *ZeroNativeMimeTypeForPath(NSString *path);
static NSString *ZeroNativeResolvedAssetRoot(NSString *rootPath);
static NSString *ZeroNativeSafeAssetPath(NSURL *url, NSString *entryPath);
static NSURL *ZeroNativeAssetEntryURL(NSString *origin, NSString *entryPath);
static NSArray<NSString *> *ZeroNativePolicyListFromBytes(const char *bytes, size_t len, NSArray<NSString *> *fallback);
static NSString *ZeroNativeOriginForURL(NSURL *url);
static BOOL ZeroNativePolicyListMatches(NSArray<NSString *> *values, NSURL *url);
static NSString *ZeroNativeShortcutKeyForEvent(NSEvent *event);
static BOOL ZeroNativeShortcutUsesImplicitShift(NSString *key, NSEvent *event);
static BOOL ZeroNativeShortcutModifiersMatch(uint32_t shortcutModifiers, NSEventModifierFlags eventModifiers, BOOL allowImplicitShift);
static NSEventModifierFlags ZeroNativeMenuModifierFlags(uint32_t modifiers);
static NSAccessibilityRole ZeroNativeAccessibilityRoleForNativeViewKind(NSInteger kind);

static NSString *ZeroNativeStringFromBytes(const char *bytes, size_t len) {
    if (!bytes || len == 0) return nil;
    return [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
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
        case ZERO_NATIVE_APPKIT_VIEW_STATUSBAR:
        case ZERO_NATIVE_APPKIT_VIEW_SIDEBAR:
        case ZERO_NATIVE_APPKIT_VIEW_STACK:
        case ZERO_NATIVE_APPKIT_VIEW_SPACER:
            return NSAccessibilityGroupRole;
        default:
            return NSAccessibilityUnknownRole;
    }
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
- (BOOL)closeNativeViewInWindow:(uint64_t)windowId label:(NSString *)label;
- (void)closeNativeViewsInWindow:(uint64_t)windowId;
- (BOOL)createWebViewInWindow:(uint64_t)windowId label:(NSString *)label url:(NSString *)url x:(double)x y:(double)y width:(double)width height:(double)height layer:(NSInteger)layer transparent:(BOOL)transparent bridgeEnabled:(BOOL)bridgeEnabled;
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
- (void)emitResize;
- (void)emitResizeForWindowId:(uint64_t)windowId;
- (void)emitDeferredResizeForWindowId:(uint64_t)windowId;
- (void)emitWindowFrame:(BOOL)open;
- (void)emitWindowFrameForWindowId:(uint64_t)windowId open:(BOOL)open;
- (void)scheduleFrame;
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

- (BOOL)closeNativeViewInWindow:(uint64_t)windowId label:(NSString *)label {
    NSString *key = [self nativeViewKeyForWindow:windowId label:label];
    NSView *view = self.nativeViews[key];
    if (!view) return NO;
    [view removeFromSuperview];
    [self.nativeViews removeObjectForKey:key];
    [self.nativeViewCommands removeObjectForKey:key];
    [self.nativeViewExplicitTextKeys removeObject:key];
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
        "function viewCreatePayload(options){options=options||{};validateViewSelector(options);ensureString(options.kind,'kind');var payload={label:options.label,kind:options.kind,windowId:options.windowId};var frame=optionalFramePayload(options);if(frame){payload.frame=frame;}if(options.parent!=null){payload.parent=ensureString(options.parent,'parent');}if(options.role!=null){payload.role=ensureString(options.role,'role');}if(options.accessibilityLabel!=null){payload.accessibilityLabel=ensureString(options.accessibilityLabel,'accessibilityLabel');}if(options.text!=null){payload.text=ensureString(options.text,'text');}if(options.command!=null){payload.command=ensureString(options.command,'command');}if(options.url!=null){payload.url=ensureString(options.url,'url');}if(options.layer!=null){payload.layer=ensureNumber(options.layer,'layer');}if(options.visible!=null){payload.visible=!!options.visible;}if(options.enabled!=null){payload.enabled=!!options.enabled;}if(options.transparent!=null){payload.transparent=!!options.transparent;}if(options.bridge!=null){payload.bridge=!!options.bridge;}return payload;}"
        "function viewPatchPayload(options){options=options||{};validateViewSelector(options);var payload={label:options.label,windowId:options.windowId};var frame=optionalFramePayload(options);if(frame){payload.frame=frame;}if(options.layer!=null){payload.layer=ensureNumber(options.layer,'layer');}if(options.visible!=null){payload.visible=!!options.visible;}if(options.enabled!=null){payload.enabled=!!options.enabled;}if(options.role!=null){payload.role=ensureString(options.role,'role');}if(options.accessibilityLabel!=null){payload.accessibilityLabel=ensureString(options.accessibilityLabel,'accessibilityLabel');}if(options.text!=null){payload.text=ensureString(options.text,'text');}if(options.command!=null){payload.command=ensureString(options.command,'command');}if(options.url!=null){payload.url=ensureString(options.url,'url');}return payload;}"
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

    [self emitEvent:(zero_native_appkit_event_t){ .kind = ZERO_NATIVE_APPKIT_EVENT_START }];
    [self emitResize];
    [self emitWindowFrame:YES];

    [self startApplicationActivationObservers];
    [self scheduleFrame];
    [NSApp run];
}

- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
    if (self.shortcutEventMonitor) {
        [NSEvent removeMonitor:self.shortcutEventMonitor];
        self.shortcutEventMonitor = nil;
    }
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
    NSString *joined = [paths componentsJoinedByString:@"\n"];
    NSData *data = [joined dataUsingEncoding:NSUTF8StringEncoding];
    if (!data || data.length == 0) return NO;
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

static BOOL ZeroNativePolicyListMatches(NSArray<NSString *> *values, NSURL *url) {
    NSString *origin = ZeroNativeOriginForURL(url);
    NSString *absolute = url.absoluteString ?: @"";
    for (NSString *value in values) {
        if ([value isEqualToString:@"*"]) return YES;
        if ([value isEqualToString:origin] || [value isEqualToString:absolute]) return YES;
        if ([value hasSuffix:@"*"]) {
            NSString *prefix = [value substringToIndex:value.length - 1];
            if ([absolute hasPrefix:prefix] || [origin hasPrefix:prefix]) return YES;
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
        for (NSURL *url in panel.URLs) {
            NSString *path = url.path;
            NSData *data = [path dataUsingEncoding:NSUTF8StringEncoding];
            if (!data) continue;
            size_t needed = data.length + (result.count > 0 ? 1 : 0);
            if (offset + needed > buffer_len) break;
            if (result.count > 0) { buffer[offset] = '\n'; offset++; }
            memcpy(buffer + offset, data.bytes, data.length);
            offset += data.length;
            result.count++;
        }
        result.bytes_written = offset;
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
        size_t count = MIN(buffer_len, data.length);
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
