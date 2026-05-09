#import "appkit_host.h"

#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <string.h>

@class ZeroNativeAppKitHost;

static NSRect constrainFrame(NSRect frame);
static NSString *ZeroNativeAppKitBridgeScript(void);
static NSString *ZeroNativeMimeTypeForPath(NSString *path);
static int ZeroNativeCurrentTheme(void);
static NSString *ZeroNativeResolvedAssetRoot(NSString *rootPath);
static NSString *ZeroNativeSafeAssetPath(NSURL *url, NSString *entryPath);
static NSURL *ZeroNativeAssetEntryURL(NSString *origin, NSString *entryPath);
static NSArray<NSString *> *ZeroNativePolicyListFromBytes(const char *bytes, size_t len, NSArray<NSString *> *fallback);
static NSString *ZeroNativeOriginForURL(NSURL *url);
static BOOL ZeroNativePolicyListMatches(NSArray<NSString *> *values, NSURL *url);

@interface ZeroNativeWindowDelegate : NSObject <NSWindowDelegate>
@property(nonatomic, assign) ZeroNativeAppKitHost *host;
@property(nonatomic, assign) uint64_t windowId;
@end

@interface ZeroNativeBridgeScriptHandler : NSObject <WKScriptMessageHandler>
@property(nonatomic, assign) ZeroNativeAppKitHost *host;
@property(nonatomic, assign) uint64_t windowId;
@end

@interface ZeroNativeAssetSchemeHandler : NSObject <WKURLSchemeHandler>
@property(nonatomic, strong) NSString *rootPath;
@property(nonatomic, strong) NSString *entryPath;
@property(nonatomic, assign) BOOL spaFallback;
- (void)configureWithRootPath:(NSString *)rootPath entryPath:(NSString *)entryPath spaFallback:(BOOL)spaFallback;
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
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, assign) zero_native_appkit_tray_callback_t trayCallback;
@property(nonatomic, assign) void *trayContext;
@property(nonatomic, assign) zero_native_appkit_theme_callback_t themeCallback;
@property(nonatomic, assign) void *themeContext;
@property(nonatomic, assign) BOOL observesThemeChanges;
@property(nonatomic, strong) NSArray<NSString *> *allowedNavigationOrigins;
@property(nonatomic, strong) NSArray<NSString *> *allowedExternalURLs;
@property(nonatomic, assign) NSInteger externalLinkAction;
- (instancetype)initWithAppName:(NSString *)appName windowTitle:(NSString *)windowTitle bundleIdentifier:(NSString *)bundleIdentifier iconPath:(NSString *)iconPath windowLabel:(NSString *)windowLabel x:(double)x y:(double)y width:(double)width height:(double)height restoreFrame:(BOOL)restoreFrame;
- (BOOL)createWindowWithId:(uint64_t)windowId title:(NSString *)title label:(NSString *)label x:(double)x y:(double)y width:(double)width height:(double)height restoreFrame:(BOOL)restoreFrame makeMain:(BOOL)makeMain;
- (void)focusWindowWithId:(uint64_t)windowId;
- (void)closeWindowWithId:(uint64_t)windowId;
- (WKWebView *)webViewForWindowId:(uint64_t)windowId;
- (ZeroNativeAssetSchemeHandler *)assetHandlerForWindowId:(uint64_t)windowId;
- (void)configureApplication;
- (void)buildMenuBar;
- (NSMenuItem *)menuItem:(NSString *)title action:(SEL)action key:(NSString *)key modifiers:(NSEventModifierFlags)modifiers;
- (void)runWithCallback:(zero_native_appkit_event_callback_t)callback context:(void *)context;
- (void)stop;
- (void)emitEvent:(zero_native_appkit_event_t)event;
- (void)emitResize;
- (void)emitResizeForWindowId:(uint64_t)windowId;
- (void)emitWindowFrame:(BOOL)open;
- (void)emitWindowFrameForWindowId:(uint64_t)windowId open:(BOOL)open;
- (void)scheduleFrame;
- (void)emitFrame;
- (void)emitShutdown;
- (void)loadSource:(NSString *)source kind:(NSInteger)kind assetRoot:(NSString *)assetRoot entry:(NSString *)entry origin:(NSString *)origin spaFallback:(BOOL)spaFallback;
- (void)loadSource:(NSString *)source kind:(NSInteger)kind assetRoot:(NSString *)assetRoot entry:(NSString *)entry origin:(NSString *)origin spaFallback:(BOOL)spaFallback windowId:(uint64_t)windowId;
- (void)setAllowedNavigationOrigins:(NSArray<NSString *> *)origins externalURLs:(NSArray<NSString *> *)externalURLs externalAction:(NSInteger)externalAction;
- (BOOL)allowsNavigationURL:(NSURL *)url;
- (BOOL)openExternalURLIfAllowed:(NSURL *)url;
- (void)receiveBridgeMessage:(WKScriptMessage *)message windowId:(uint64_t)windowId;
- (void)completeBridgeWithResponse:(NSString *)response;
- (void)completeBridgeWithResponse:(NSString *)response windowId:(uint64_t)windowId;
- (void)emitEventNamed:(NSString *)name detailJSON:(NSString *)detailJSON windowId:(uint64_t)windowId;
- (void)themeDidChange:(NSNotification *)notification;
@end

@implementation ZeroNativeWindowDelegate

- (void)windowDidResize:(NSNotification *)notification {
    (void)notification;
    [self.host emitWindowFrameForWindowId:self.windowId open:YES];
    [self.host emitResizeForWindowId:self.windowId];
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
    [self.host scheduleFrame];
}

- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    [self.host emitWindowFrameForWindowId:self.windowId open:NO];
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

@implementation ZeroNativeBridgeScriptHandler

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)userContentController;
    [self.host receiveBridgeMessage:message windowId:self.windowId];
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
    self.allowedNavigationOrigins = @[ @"zero://app", @"zero://inline" ];
    self.allowedExternalURLs = @[];
    self.externalLinkAction = 0;
    [self configureApplication];

    [self createWindowWithId:1 title:(windowTitle.length > 0 ? windowTitle : self.appName) label:self.windowLabel x:x y:y width:width height:height restoreFrame:restoreFrame makeMain:YES];
    self.didShutdown = NO;

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
    [userContentController addScriptMessageHandler:bridgeScriptHandler name:@"zeroNativeBridge"];
    WKUserScript *bridgeScript = [[WKUserScript alloc] initWithSource:ZeroNativeAppKitBridgeScript()
                                                        injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                     forMainFrameOnly:YES];
    [userContentController addUserScript:bridgeScript];
    configuration.userContentController = userContentController;
    if ([configuration.preferences respondsToSelector:NSSelectorFromString(@"setDeveloperExtrasEnabled:")]) {
        [configuration.preferences setValue:@YES forKey:@"developerExtrasEnabled"];
    }
    WKWebView *webView = [[WKWebView alloc] initWithFrame:rect configuration:configuration];
    if ([webView respondsToSelector:NSSelectorFromString(@"setInspectable:")]) {
        [webView setValue:@YES forKey:@"inspectable"];
    }
    webView.navigationDelegate = self;
    webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    window.contentView = webView;

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
    for (WKWebView *webView in self.webViews.allValues) {
        [webView.configuration.userContentController removeScriptMessageHandlerForName:@"zeroNativeBridge"];
    }
    if (self.observesThemeChanges) {
        [[NSDistributedNotificationCenter defaultCenter] removeObserver:self name:@"AppleInterfaceThemeChangedNotification" object:nil];
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

- (ZeroNativeAssetSchemeHandler *)assetHandlerForWindowId:(uint64_t)windowId {
    return self.assetSchemeHandlers[@(windowId)] ?: self.assetSchemeHandler;
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
        "function on(name,callback){if(typeof callback!=='function'){throw new TypeError('callback must be a function');}var set=listeners.get(name);if(!set){set=new Set();listeners.set(name,set);}set.add(callback);return function(){off(name,callback);};}"
        "function off(name,callback){var set=listeners.get(name);if(set){set.delete(callback);if(set.size===0){listeners.delete(name);}}}"
        "function emit(name,detail){var set=listeners.get(name);if(set){Array.from(set).forEach(function(callback){callback(detail);});}window.dispatchEvent(new CustomEvent('zero-native:'+name,{detail:detail}));}"
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
        "Object.defineProperty(window,'zero',{value:Object.freeze({invoke:invoke,on:on,off:off,windows:windows,dialogs:dialogs,_complete:complete,_emit:emit}),configurable:false});"
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

static int ZeroNativeCurrentTheme(void) {
    [NSApplication sharedApplication];
    NSAppearance *appearance = [NSApp effectiveAppearance] ?: [NSAppearance currentAppearance];
    NSString *match = [appearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
    return [match isEqualToString:NSAppearanceNameDarkAqua] ? 1 : 0;
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

- (NSMenuItem *)menuItem:(NSString *)title action:(SEL)action key:(NSString *)key modifiers:(NSEventModifierFlags)modifiers {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key ?: @""];
    item.keyEquivalentModifierMask = modifiers;
    if ([self respondsToSelector:action]) {
        item.target = self;
    }
    return item;
}

- (void)runWithCallback:(zero_native_appkit_event_callback_t)callback context:(void *)context {
    self.callback = callback;
    self.context = context;

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activate];

    [self emitEvent:(zero_native_appkit_event_t){ .kind = ZERO_NATIVE_APPKIT_EVENT_START }];
    [self emitResize];
    [self emitWindowFrame:YES];

    [self scheduleFrame];
    [NSApp run];
}

- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
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

- (void)emitResize {
    [self emitResizeForWindowId:1];
}

- (void)emitResizeForWindowId:(uint64_t)windowId {
    WKWebView *webView = [self webViewForWindowId:windowId];
    NSWindow *window = self.windows[@(windowId)] ?: self.window;
    NSRect bounds = webView.bounds;
    [self emitEvent:(zero_native_appkit_event_t){
        .kind = ZERO_NATIVE_APPKIT_EVENT_RESIZE,
        .window_id = windowId,
        .width = bounds.size.width,
        .height = bounds.size.height,
        .scale = window.backingScaleFactor,
    }];
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

- (void)emitFrame {
    self.timer = nil;
    [self emitEvent:(zero_native_appkit_event_t){ .kind = ZERO_NATIVE_APPKIT_EVENT_FRAME }];
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

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    (void)webView;
    NSURL *url = navigationAction.request.URL;
    if (!navigationAction.targetFrame || navigationAction.targetFrame.isMainFrame) {
        if ([self allowsNavigationURL:url]) {
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

- (void)receiveBridgeMessage:(WKScriptMessage *)message windowId:(uint64_t)windowId {
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
    self.bridgeCallback(self.bridgeContext, windowId, (const char *)messageData.bytes, messageData.length, (const char *)originData.bytes, originData.length);
    [self scheduleFrame];
}

- (void)completeBridgeWithResponse:(NSString *)response {
    [self completeBridgeWithResponse:response windowId:1];
}

- (void)completeBridgeWithResponse:(NSString *)response windowId:(uint64_t)windowId {
    WKWebView *webView = [self webViewForWindowId:windowId];
    NSString *script = [NSString stringWithFormat:@"window.zero&&window.zero._complete(%@);", response.length > 0 ? response : @"{}"];
    [webView evaluateJavaScript:script completionHandler:nil];
}

- (void)emitEventNamed:(NSString *)name detailJSON:(NSString *)detailJSON windowId:(uint64_t)windowId {
    WKWebView *webView = [self webViewForWindowId:windowId];
    NSData *nameData = [NSJSONSerialization dataWithJSONObject:name ?: @"" options:0 error:nil];
    NSString *nameJSON = nameData ? [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding] : @"\"\"";
    NSString *detail = detailJSON.length > 0 ? detailJSON : @"null";
    NSString *script = [NSString stringWithFormat:@"window.zero&&window.zero._emit(%@,%@);", nameJSON, detail];
    [webView evaluateJavaScript:script completionHandler:nil];
}

- (void)themeDidChange:(NSNotification *)notification {
    (void)notification;
    if (self.themeCallback) {
        self.themeCallback(self.themeContext, ZeroNativeCurrentTheme());
    }
}

- (void)showPreferences:(id)sender {
    (void)sender;
}

- (void)reload:(id)sender {
    (void)sender;
    WKWebView *webView = (WKWebView *)NSApp.keyWindow.contentView;
    if (![webView isKindOfClass:[WKWebView class]]) webView = self.webView;
    [webView reload];
    [self scheduleFrame];
}

- (void)toggleWebInspector:(id)sender {
    (void)sender;
    WKWebView *webView = (WKWebView *)NSApp.keyWindow.contentView;
    if (![webView isKindOfClass:[WKWebView class]]) webView = self.webView;
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

void zero_native_appkit_set_theme_callback(zero_native_appkit_host_t *host, zero_native_appkit_theme_callback_t callback, void *context) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    object.themeCallback = callback;
    object.themeContext = context;
    if (!object.observesThemeChanges) {
        [[NSDistributedNotificationCenter defaultCenter] addObserver:object selector:@selector(themeDidChange:) name:@"AppleInterfaceThemeChangedNotification" object:nil];
        object.observesThemeChanges = YES;
    }
}

int zero_native_appkit_current_theme(int *out_theme) {
    if (!out_theme) {
        return 0;
    }
    *out_theme = ZeroNativeCurrentTheme();
    return 1;
}

void zero_native_appkit_bridge_respond(zero_native_appkit_host_t *host, const char *response, size_t response_len) {
    zero_native_appkit_bridge_respond_window(host, 1, response, response_len);
}

void zero_native_appkit_bridge_respond_window(zero_native_appkit_host_t *host, uint64_t window_id, const char *response, size_t response_len) {
    ZeroNativeAppKitHost *object = (__bridge ZeroNativeAppKitHost *)host;
    NSString *responseString = response ? [[NSString alloc] initWithBytes:response length:response_len encoding:NSUTF8StringEncoding] : @"{}";
    [object completeBridgeWithResponse:responseString ?: @"{}" windowId:window_id];
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

size_t zero_native_appkit_clipboard_read(zero_native_appkit_host_t *host, char *buffer, size_t buffer_len) {
    (void)host;
    NSString *value = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString] ?: @"";
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    size_t count = MIN(buffer_len, data.length);
    memcpy(buffer, data.bytes, count);
    return count;
}

void zero_native_appkit_clipboard_write(zero_native_appkit_host_t *host, const char *text, size_t text_len) {
    (void)host;
    NSString *value = [[NSString alloc] initWithBytes:text length:text_len encoding:NSUTF8StringEncoding] ?: @"";
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setString:value forType:NSPasteboardTypeString];
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
