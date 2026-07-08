#import "appkit_host.h"

#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <ImageIO/ImageIO.h>
#import <Security/Security.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <crt_externs.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_application_mac.h"
#include "include/cef_load_handler.h"
#include "include/cef_process_message.h"
#include "include/cef_values.h"
#include "include/cef_v8.h"
#include "include/wrapper/cef_library_loader.h"
#include <math.h>
#include <map>

#ifndef NATIVE_SDK_CEF_DIR
#define NATIVE_SDK_CEF_DIR "third_party/cef/macos"
#endif

@class NativeSdkChromiumHost;

@interface NativeSdkChromiumApplication : NSApplication <CefAppProtocol>
@property(nonatomic, assign) BOOL handlingSendEvent;
@end

namespace {

static const char *kBridgeMessageName = "native_sdk_bridge";
static const char *kBridgeEnabledExtraInfo = "nativeSdkBridgeEnabled";
static const uint32_t NativeSdkShortcutModifierPrimary = 1u << 0;
static const uint32_t NativeSdkShortcutModifierCommand = 1u << 1;
static const uint32_t NativeSdkShortcutModifierControl = 1u << 2;
static const uint32_t NativeSdkShortcutModifierOption = 1u << 3;
static const uint32_t NativeSdkShortcutModifierShift = 1u << 4;
static const char *NativeSdkCefBridgeScript();
static NSRect NativeSdkConstrainFrame(NSRect frame);
static NSString *NativeSdkResolvedAssetRoot(NSString *rootPath);
static NSURL *NativeSdkAssetEntryFileURL(NSString *rootPath, NSString *entryPath);
static NSString *NativeSdkSafeAssetPath(NSURL *url, NSString *entryPath);
static NSArray<NSString *> *NativeSdkPolicyListFromBytes(const char *bytes, size_t len, NSArray<NSString *> *fallback);
static NSString *NativeSdkAbsolutePath(NSString *path);
static NSString *NativeSdkExistingPath(NSString *path);
static NSString *NativeSdkCefFrameworkPath(void);
static NSString *NativeSdkOriginForURL(NSURL *url);
static BOOL NativeSdkPolicyListMatches(NSArray<NSString *> *values, NSURL *url);
static NSString *NativeSdkShortcutKeyForEvent(NSEvent *event);
static BOOL NativeSdkShortcutUsesImplicitShift(NSString *key, NSEvent *event);
static BOOL NativeSdkShortcutModifiersMatch(uint32_t shortcutModifiers, NSEventModifierFlags eventModifiers, BOOL allowImplicitShift);

static NSString *NativeSdkStringFromBytes(const char *bytes, size_t len) {
    if (!bytes || len == 0) return nil;
    return [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
}

static uint64_t NativeSdkChromiumTimestampNanoseconds(void) {
    return (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000000000.0);
}

static NSString *NativeSdkPasteboardTypeForMime(const char *mime_type, size_t mime_type_len) {
    NSString *mime = NativeSdkStringFromBytes(mime_type, mime_type_len).lowercaseString;
    if ([mime isEqualToString:@"text"] || [mime isEqualToString:@"text/plain"]) return NSPasteboardTypeString;
    if ([mime isEqualToString:@"text/html"]) return NSPasteboardTypeHTML;
    if ([mime isEqualToString:@"text/rtf"] || [mime isEqualToString:@"application/rtf"]) return NSPasteboardTypeRTF;
    return nil;
}

static NSMutableDictionary *NativeSdkCredentialQuery(NSString *service, NSString *account) {
    return [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account,
    } mutableCopy];
}

class NativeSdkCefBridgeV8Handler final : public CefV8Handler {
public:
    bool Execute(const CefString& name, CefRefPtr<CefV8Value> object, const CefV8ValueList& arguments, CefRefPtr<CefV8Value>& retval, CefString& exception) override {
        (void)object;
        if (name == "postMessage" && arguments.size() == 1 && arguments[0]->IsString()) {
            CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kBridgeMessageName);
            message->GetArgumentList()->SetString(0, arguments[0]->GetStringValue());
            CefV8Context::GetCurrentContext()->GetFrame()->SendProcessMessage(PID_BROWSER, message);
            retval = CefV8Value::CreateBool(true);
            return true;
        }
        exception = "Invalid native-sdk bridge message";
        return true;
    }

private:
    IMPLEMENT_REFCOUNTING(NativeSdkCefBridgeV8Handler);
};

class NativeSdkCefClient final : public CefClient, public CefLifeSpanHandler, public CefLoadHandler, public CefRequestHandler {
public:
    explicit NativeSdkCefClient(NativeSdkChromiumHost *host, uint64_t window_id) : host_(host), window_id_(window_id) {}
    NativeSdkCefClient(NativeSdkChromiumHost *host, uint64_t window_id, std::string webview_key, uint64_t webview_generation, bool bridge_enabled) : host_(host), window_id_(window_id), webview_key_(webview_key), webview_generation_(webview_generation), bridge_enabled_(bridge_enabled) {}

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override {
        return this;
    }

    CefRefPtr<CefRequestHandler> GetRequestHandler() override {
        return this;
    }

    CefRefPtr<CefLoadHandler> GetLoadHandler() override {
        return this;
    }

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;
    void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, ErrorCode errorCode, const CefString& errorText, const CefString& failedUrl) override;
    bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request, bool user_gesture, bool is_redirect) override;
    bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefProcessId source_process, CefRefPtr<CefProcessMessage> message) override;
    std::string WebViewLabel() const {
        if (webview_key_.empty()) return "main";
        size_t separator = webview_key_.find(':');
        return separator == std::string::npos ? webview_key_ : webview_key_.substr(separator + 1);
    }

private:
    NativeSdkChromiumHost *host_;
    uint64_t window_id_;
    std::string webview_key_;
    uint64_t webview_generation_ = 0;
    bool bridge_enabled_ = true;
    IMPLEMENT_REFCOUNTING(NativeSdkCefClient);
};

class NativeSdkCefApp final : public CefApp, public CefRenderProcessHandler {
public:
    NativeSdkCefApp() = default;

    void OnBeforeCommandLineProcessing(const CefString& process_type, CefRefPtr<CefCommandLine> command_line) override {
        (void)process_type;
        command_line->AppendSwitchWithValue("password-store", "basic");
        command_line->AppendSwitch("use-mock-keychain");
    }

    CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
        return this;
    }

    void OnBrowserCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDictionaryValue> extra_info) override {
        if (!browser) return;
        bool bridge_enabled = false;
        if (extra_info && extra_info->HasKey(kBridgeEnabledExtraInfo)) {
            bridge_enabled = extra_info->GetBool(kBridgeEnabledExtraInfo);
        }
        bridge_enabled_by_browser_id_[browser->GetIdentifier()] = bridge_enabled;
    }

    void OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) override {
        if (!browser) return;
        bridge_enabled_by_browser_id_.erase(browser->GetIdentifier());
    }

    void OnContextCreated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefV8Context> context) override {
        if (!frame || !frame->IsMain()) return;
        const auto found = browser ? bridge_enabled_by_browser_id_.find(browser->GetIdentifier()) : bridge_enabled_by_browser_id_.end();
        if (found == bridge_enabled_by_browser_id_.end() || !found->second) return;
        CefRefPtr<CefV8Value> bridge = CefV8Value::CreateObject(nullptr, nullptr);
        bridge->SetValue("postMessage", CefV8Value::CreateFunction("postMessage", new NativeSdkCefBridgeV8Handler()), V8_PROPERTY_ATTRIBUTE_READONLY);
        context->GetGlobal()->SetValue("nativeSdkCefBridge", bridge, V8_PROPERTY_ATTRIBUTE_READONLY);
        frame->ExecuteJavaScript(CefString(NativeSdkCefBridgeScript()), frame->GetURL(), 0);
    }

private:
    std::map<int, bool> bridge_enabled_by_browser_id_;
    IMPLEMENT_REFCOUNTING(NativeSdkCefApp);
};

static CefRefPtr<CefDictionaryValue> NativeSdkCefExtraInfo(bool bridge_enabled) {
    CefRefPtr<CefDictionaryValue> extra_info = CefDictionaryValue::Create();
    extra_info->SetBool(kBridgeEnabledExtraInfo, bridge_enabled);
    return extra_info;
}

static bool g_cef_initialized = false;
static bool g_cef_shutdown = false;
static CefScopedLibraryLoader g_cef_library_loader;
static bool g_cef_library_loaded = false;

static void shutdownCefIfNeeded() {
    if (!g_cef_initialized || g_cef_shutdown) return;
    CefShutdown();
    g_cef_initialized = false;
    g_cef_shutdown = true;
}

static void ensureCefInitialized() {
    if (g_cef_initialized) return;
    g_cef_shutdown = false;

    if (!g_cef_library_loaded) {
        if (!g_cef_library_loader.LoadInMain()) {
            fprintf(stderr, "failed to load Chromium Embedded Framework\n");
            return;
        }
        g_cef_library_loaded = true;
    }

    CefMainArgs args(*_NSGetArgc(), *_NSGetArgv());
    CefRefPtr<NativeSdkCefApp> app = new NativeSdkCefApp();
    const int exit_code = CefExecuteProcess(args, app, nullptr);
    if (exit_code >= 0) exit(exit_code);

    CefSettings settings;
    settings.no_sandbox = true;
    settings.multi_threaded_message_loop = false;
    NSString *frameworkPath = NativeSdkCefFrameworkPath();
    NSString *resourcesPath = [frameworkPath stringByAppendingPathComponent:@"Resources"];
    NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    NSString *cefDataRoot = [appSupport stringByAppendingPathComponent:@"native-sdk/CEF"];
    NSString *cefCachePath = [cefDataRoot stringByAppendingPathComponent:@"Default"];
    [[NSFileManager defaultManager] createDirectoryAtPath:cefCachePath withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *executablePath = [NSBundle mainBundle].executablePath ?: [[[NSProcessInfo processInfo] arguments] firstObject];
    CefString(&settings.framework_dir_path).FromString(frameworkPath.UTF8String);
    CefString(&settings.resources_dir_path).FromString(resourcesPath.UTF8String);
    CefString(&settings.root_cache_path).FromString(cefDataRoot.UTF8String);
    CefString(&settings.cache_path).FromString(cefCachePath.UTF8String);
    if (executablePath.length > 0) {
        CefString(&settings.browser_subprocess_path).FromString(executablePath.UTF8String);
    }
    if (!CefInitialize(args, settings, app, nullptr)) {
        fprintf(stderr, "failed to initialize Chromium Embedded Framework\n");
        return;
    }
    g_cef_initialized = true;
}

static NSString *temporaryHtmlUrl(NSString *html) {
    NSString *filename = [NSString stringWithFormat:@"native-sdk-cef-%@.html", [[NSUUID UUID] UUIDString]];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:filename];
    NSError *error = nil;
    if (![html writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        NSLog(@"native-sdk: failed to write temporary CEF HTML file: %@", error);
        return @"about:blank";
    }
    return [NSURL fileURLWithPath:path].absoluteString;
}

static NSString *NativeSdkResolvedAssetRoot(NSString *rootPath) {
    if (rootPath.length == 0 || [rootPath isEqualToString:@"."]) {
        return [NSBundle mainBundle].resourcePath ?: [[NSFileManager defaultManager] currentDirectoryPath];
    }
    if (rootPath.isAbsolutePath) return rootPath;
    NSString *resourcePath = [NSBundle mainBundle].resourcePath;
    if (resourcePath.length > 0) {
        return [resourcePath stringByAppendingPathComponent:rootPath];
    }
    return [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:rootPath];
}

static NSURL *NativeSdkAssetEntryFileURL(NSString *rootPath, NSString *entryPath) {
    NSString *entry = entryPath.length > 0 ? entryPath : @"index.html";
    while ([entry hasPrefix:@"/"]) {
        entry = [entry substringFromIndex:1];
    }
    return [NSURL fileURLWithPath:[NativeSdkResolvedAssetRoot(rootPath ?: @"") stringByAppendingPathComponent:entry]];
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

static NSString *NativeSdkAbsolutePath(NSString *path) {
    if (path.length == 0) return [[NSFileManager defaultManager] currentDirectoryPath];
    if (path.isAbsolutePath) return path;
    return [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:path];
}

static NSString *NativeSdkExistingPath(NSString *path) {
    if (path.length == 0) return nil;
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

static NSString *NativeSdkCefFrameworkPath(void) {
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *bundleFramework = [[bundle privateFrameworksPath] stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"];
    if (NativeSdkExistingPath(bundleFramework)) return bundleFramework;

    NSString *bundleContentsFramework = [[bundle.bundlePath stringByAppendingPathComponent:@"Contents/Frameworks"] stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"];
    if (NativeSdkExistingPath(bundleContentsFramework)) return bundleContentsFramework;

    NSString *devRoot = NativeSdkAbsolutePath(@NATIVE_SDK_CEF_DIR);
    return [devRoot stringByAppendingPathComponent:@"Release/Chromium Embedded Framework.framework"];
}

static NSRect NativeSdkConstrainFrame(NSRect frame) {
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

static const char *NativeSdkCefBridgeScript() {
    return "(function(){"
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

} // namespace

@implementation NativeSdkChromiumApplication

- (BOOL)isHandlingSendEvent {
    return self.handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
    _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent *)event {
    CefScopedSendingEvent scopedSendingEvent;
    [super sendEvent:event];
}

@end

@interface NativeSdkChromiumWindowDelegate : NSObject <NSWindowDelegate>
@property(nonatomic, assign) NativeSdkChromiumHost *host;
@property(nonatomic, assign) uint64_t windowId;
/// Set for tall-titlebar windows, whose delegate KVO-observes the
/// window's `contentLayoutRect` (chrome re-query timing) and must
/// unregister before the window closes.
@property(nonatomic, assign) BOOL observesContentLayout;
@end

@interface NativeSdkChromiumShortcut : NSObject
@property(nonatomic, strong) NSString *identifier;
@property(nonatomic, strong) NSString *key;
@property(nonatomic, assign) uint32_t modifiers;
@end

/* Captures the selected item id of a context-menu popUp (NSMenuItem
 * targets are weak; the presenter block keeps this alive). */
@interface NativeSdkChromiumContextMenuTarget : NSObject
@property(nonatomic, assign) uint32_t selectedItemId;
- (void)contextMenuItemClicked:(NSMenuItem *)item;
@end

@implementation NativeSdkChromiumContextMenuTarget

- (void)contextMenuItemClicked:(NSMenuItem *)item {
    NSNumber *value = item.representedObject;
    if ([value isKindOfClass:[NSNumber class]]) self.selectedItemId = value.unsignedIntValue;
}

@end

@interface NativeSdkChromiumHost : NSObject
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSView *browserContainer;
@property(nonatomic, strong) NativeSdkChromiumWindowDelegate *delegate;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSWindow *> *windows;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSView *> *browserContainers;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NativeSdkChromiumWindowDelegate *> *delegates;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *bridgeOrigins;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *internalURLPrefixes;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *assetRoots;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *assetEntries;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *assetOrigins;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *windowLabels;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *fallbackURLs;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSView *> *webviewViews;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *webviewPendingURLs;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *webviewPendingZooms;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *webviewGenerations;
@property(nonatomic, strong) NSMutableSet<NSString *> *closingWebViewKeys;
@property(nonatomic, assign) uint64_t nextWebViewGeneration;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSTimer *> *appTimers;
@property(nonatomic, strong) NSString *appName;
/* The human-facing app name (app.zon display_name, empty = appName):
 * drives the application menu title and its About/Hide/Quit labels, the
 * process name, and the About panel. */
@property(nonatomic, strong) NSString *displayName;
/* app.zon version and description for the About panel; empty when
 * undeclared. */
@property(nonatomic, strong) NSString *appVersion;
@property(nonatomic, strong) NSString *aboutDescription;
@property(nonatomic, assign) native_sdk_appkit_event_callback_t callback;
@property(nonatomic, assign) native_sdk_appkit_bridge_callback_t bridgeCallback;
@property(nonatomic, assign) void *context;
@property(nonatomic, assign) void *bridgeContext;
@property(nonatomic, assign) BOOL didShutdown;
@property(nonatomic, assign) BOOL observesApplicationActivation;
@property(nonatomic, strong) id shortcutEventMonitor;
@property(nonatomic, strong) NSArray<NativeSdkChromiumShortcut *> *shortcuts;
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, assign) native_sdk_appkit_tray_callback_t trayCallback;
@property(nonatomic, assign) void *trayContext;
@property(nonatomic) CefRefPtr<NativeSdkCefClient> cefClient;
@property(nonatomic) CefRefPtr<CefBrowser> browser;
@property(nonatomic, assign) std::map<uint64_t, CefRefPtr<NativeSdkCefClient>> *cefClients;
@property(nonatomic, assign) std::map<uint64_t, CefRefPtr<CefBrowser>> *browsers;
@property(nonatomic, assign) std::map<std::string, CefRefPtr<NativeSdkCefClient>> *webviewCefClients;
@property(nonatomic, assign) std::map<std::string, CefRefPtr<CefBrowser>> *webviewBrowsers;
@property(nonatomic, strong) NSArray<NSString *> *allowedNavigationOrigins;
@property(nonatomic, strong) NSArray<NSString *> *allowedExternalURLs;
@property(nonatomic, assign) NSInteger externalLinkAction;
- (instancetype)initWithAppName:(NSString *)appName displayName:(NSString *)displayName version:(NSString *)version aboutDescription:(NSString *)aboutDescription title:(NSString *)title width:(double)width height:(double)height;
- (void)configureApplication;
- (void)buildMenuBar;
- (NSMenuItem *)menuItem:(NSString *)title action:(SEL)action key:(NSString *)key modifiers:(NSEventModifierFlags)modifiers;
- (BOOL)createWindowWithId:(uint64_t)windowId title:(NSString *)title label:(NSString *)label x:(double)x y:(double)y width:(double)width height:(double)height restoreFrame:(BOOL)restoreFrame resizable:(BOOL)resizable makeMain:(BOOL)makeMain;
- (void)focusWindowWithId:(uint64_t)windowId;
- (void)closeWindowWithId:(uint64_t)windowId;
- (void)runWithCallback:(native_sdk_appkit_event_callback_t)callback context:(void *)context;
- (void)stop;
- (void)emitEvent:(native_sdk_appkit_event_t)event;
- (void)startAppTimerWithId:(uint64_t)timerId intervalNs:(uint64_t)intervalNs repeats:(BOOL)repeats;
- (void)cancelAppTimerWithId:(uint64_t)timerId;
- (void)invalidateAppTimers;
- (void)wakeFromAnyThread;
- (void)startApplicationActivationObservers;
- (void)stopApplicationActivationObservers;
- (void)applicationDidBecomeActive:(NSNotification *)notification;
- (void)applicationDidResignActive:(NSNotification *)notification;
- (void)emitResize;
- (void)emitResizeForWindowId:(uint64_t)windowId;
- (void)emitWindowFrameForWindowId:(uint64_t)windowId open:(BOOL)open;
- (void)emitFrame;
- (void)emitShutdown;
- (void)loadSource:(NSString *)source kind:(NSInteger)kind assetRoot:(NSString *)assetRoot entry:(NSString *)entry origin:(NSString *)origin spaFallback:(BOOL)spaFallback;
- (void)loadSource:(NSString *)source kind:(NSInteger)kind assetRoot:(NSString *)assetRoot entry:(NSString *)entry origin:(NSString *)origin spaFallback:(BOOL)spaFallback windowId:(uint64_t)windowId;
- (void)setAllowedNavigationOrigins:(NSArray<NSString *> *)origins externalURLs:(NSArray<NSString *> *)externalURLs externalAction:(NSInteger)externalAction;
- (BOOL)isInternalURL:(NSURL *)url;
- (BOOL)isInternalURL:(NSURL *)url windowId:(uint64_t)windowId;
- (BOOL)allowsNavigationURL:(NSURL *)url;
- (BOOL)openExternalURLIfAllowed:(NSURL *)url;
- (NSString *)resolvedWebViewURLString:(NSString *)url windowId:(uint64_t)windowId;
- (BOOL)createWebViewInWindow:(uint64_t)windowId label:(NSString *)label url:(NSString *)url x:(double)x y:(double)y width:(double)width height:(double)height layer:(NSInteger)layer transparent:(BOOL)transparent bridgeEnabled:(BOOL)bridgeEnabled;
- (BOOL)setWebViewFrameInWindow:(uint64_t)windowId label:(NSString *)label x:(double)x y:(double)y width:(double)width height:(double)height;
- (BOOL)navigateWebViewInWindow:(uint64_t)windowId label:(NSString *)label url:(NSString *)url;
- (BOOL)setWebViewZoomInWindow:(uint64_t)windowId label:(NSString *)label zoom:(double)zoom;
- (BOOL)setWebViewLayerInWindow:(uint64_t)windowId label:(NSString *)label layer:(NSInteger)layer;
- (BOOL)closeWebViewInWindow:(uint64_t)windowId label:(NSString *)label;
- (void)closeWebViewsInWindow:(uint64_t)windowId;
- (NSView *)stackViewForWindowId:(uint64_t)windowId;
- (void)reorderWebViewsInWindow:(uint64_t)windowId;
- (void)setBrowser:(CefRefPtr<CefBrowser>)browser windowId:(uint64_t)windowId;
- (BOOL)webViewGeneration:(uint64_t)generation matchesKey:(NSString *)key;
- (void)setWebViewBrowser:(CefRefPtr<CefBrowser>)browser key:(NSString *)key generation:(uint64_t)generation;
- (void)cleanupClosedWebViewWithKey:(NSString *)key;
- (void)cleanupClosedWebViewWithKey:(NSString *)key generation:(uint64_t)generation;
- (NSString *)fallbackURLForWindowId:(uint64_t)windowId;
- (NSString *)bridgeOriginForWindowId:(uint64_t)windowId webViewLabel:(NSString *)webViewLabel sourceURL:(NSString *)sourceURL;
- (void)receiveBridgePayload:(NSString *)payload origin:(NSString *)origin windowId:(uint64_t)windowId webViewLabel:(NSString *)webViewLabel;
- (void)completeBridgeWithResponse:(NSString *)response;
- (void)completeBridgeWithResponse:(NSString *)response windowId:(uint64_t)windowId;
- (void)completeBridgeWithResponse:(NSString *)response windowId:(uint64_t)windowId webViewLabel:(NSString *)webViewLabel;
- (void)emitEventNamed:(NSString *)name detailJSON:(NSString *)detailJSON windowId:(uint64_t)windowId;
- (void)setShortcutsWithIds:(const char *const *)ids idLengths:(const size_t *)idLengths keys:(const char *const *)keys keyLengths:(const size_t *)keyLengths modifiers:(const uint32_t *)modifiers count:(size_t)count;
- (BOOL)handleShortcutEvent:(NSEvent *)event;
- (void)emitShortcutWithId:(NSString *)identifier key:(NSString *)key modifiers:(uint32_t)modifiers event:(NSEvent *)event;
- (void)trayMenuItemClicked:(NSMenuItem *)menuItem;
@end

@implementation NativeSdkChromiumShortcut
@end

@implementation NativeSdkChromiumWindowDelegate

- (void)windowDidResize:(NSNotification *)notification {
    (void)notification;
    [self.host emitResizeForWindowId:self.windowId];
    [self.host emitWindowFrameForWindowId:self.windowId open:YES];
}

- (void)windowDidMove:(NSNotification *)notification {
    (void)notification;
    [self.host emitWindowFrameForWindowId:self.windowId open:YES];
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    (void)notification;
    [self.host emitWindowFrameForWindowId:self.windowId open:YES];
}

// Mirror of the AppKit host: the tall-titlebar toolbar is pure geometry,
// and fullscreen would otherwise keep it visible as a blank band over
// the app's own header. DID notifications, not WILL — the system
// snapshots and restores toolbar visibility across the transition and
// stomps changes made at the WILL edge; the re-emitted resize makes the
// runtime re-query chrome insets after the toggle.
// Same discipline as the AppKit host: the tall-titlebar toolbar is pure
// geometry, and fullscreen keeps it visible as a blank band over the
// app's own header — hide at the WILL edge so the transition's resizes
// see it, re-assert the restore at the DID edge (the system stomps a
// WILL-edge restore). The chrome re-query rides the contentLayoutRect
// KVO below, which fires only when the band has actually relaid out.
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

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    (void)object;
    (void)change;
    (void)context;
    if (![keyPath isEqualToString:@"contentLayoutRect"]) return;
    [self.host emitResizeForWindowId:self.windowId];
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
    NSNumber *key = @(self.windowId);
    [self.host.windows removeObjectForKey:key];
    [self.host.browserContainers removeObjectForKey:key];
    [self.host.delegates removeObjectForKey:key];
    [self.host.bridgeOrigins removeObjectForKey:key];
    [self.host.internalURLPrefixes removeObjectForKey:key];
    [self.host.assetRoots removeObjectForKey:key];
    [self.host.assetEntries removeObjectForKey:key];
    [self.host.assetOrigins removeObjectForKey:key];
    [self.host.windowLabels removeObjectForKey:key];
    [self.host.fallbackURLs removeObjectForKey:key];
    if (self.host.browsers) self.host.browsers->erase(self.windowId);
    if (self.host.cefClients) self.host.cefClients->erase(self.windowId);
    if (self.host.windows.count == 0) {
        [self.host emitShutdown];
        [self.host stop];
    }
}

@end

@implementation NativeSdkChromiumHost

- (instancetype)initWithAppName:(NSString *)appName displayName:(NSString *)displayName version:(NSString *)version aboutDescription:(NSString *)aboutDescription title:(NSString *)title width:(double)width height:(double)height {
    self = [super init];
    if (!self) return nil;

    [NativeSdkChromiumApplication sharedApplication];
    ensureCefInitialized();
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    self.appName = appName.length > 0 ? appName : @"native-sdk";
    self.displayName = displayName.length > 0 ? displayName : self.appName;
    self.appVersion = version ?: @"";
    self.aboutDescription = aboutDescription ?: @"";
    [self configureApplication];
    self.windows = [[NSMutableDictionary alloc] init];
    self.browserContainers = [[NSMutableDictionary alloc] init];
    self.delegates = [[NSMutableDictionary alloc] init];
    self.bridgeOrigins = [[NSMutableDictionary alloc] init];
    self.internalURLPrefixes = [[NSMutableDictionary alloc] init];
    self.assetRoots = [[NSMutableDictionary alloc] init];
    self.assetEntries = [[NSMutableDictionary alloc] init];
    self.assetOrigins = [[NSMutableDictionary alloc] init];
    self.windowLabels = [[NSMutableDictionary alloc] init];
    self.fallbackURLs = [[NSMutableDictionary alloc] init];
    self.webviewViews = [[NSMutableDictionary alloc] init];
    self.webviewPendingURLs = [[NSMutableDictionary alloc] init];
    self.webviewPendingZooms = [[NSMutableDictionary alloc] init];
    self.webviewGenerations = [[NSMutableDictionary alloc] init];
    self.closingWebViewKeys = [[NSMutableSet alloc] init];
    self.appTimers = [[NSMutableDictionary alloc] init];
    self.nextWebViewGeneration = 1;
    self.cefClients = new std::map<uint64_t, CefRefPtr<NativeSdkCefClient>>();
    self.browsers = new std::map<uint64_t, CefRefPtr<CefBrowser>>();
    self.webviewCefClients = new std::map<std::string, CefRefPtr<NativeSdkCefClient>>();
    self.webviewBrowsers = new std::map<std::string, CefRefPtr<CefBrowser>>();
    self.allowedNavigationOrigins = @[ @"zero://app", @"zero://inline" ];
    self.allowedExternalURLs = @[];
    self.externalLinkAction = 0;
    self.shortcuts = @[];

    [self createWindowWithId:1 title:(title.length > 0 ? title : self.appName) label:@"main" x:0 y:0 width:width height:height restoreFrame:NO resizable:YES makeMain:YES];
    self.didShutdown = NO;
    self.observesApplicationActivation = NO;
    return self;
}

- (void)configureApplication {
    [[NSProcessInfo processInfo] setProcessName:self.displayName];
    [self buildMenuBar];
}

- (void)buildMenuBar {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];
    [NSApp setMainMenu:mainMenu];

    // Every string the application menu derives \u2014 the bold menu-bar
    // title and the About/Hide/Quit labels \u2014 reads from the one display
    // name, never the binary name. No Settings item: the host has no
    // settings surface to open, and a dead item is worse than none.
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
}

- (NSMenuItem *)menuItem:(NSString *)title action:(SEL)action key:(NSString *)key modifiers:(NSEventModifierFlags)modifiers {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key ?: @""];
    item.keyEquivalentModifierMask = modifiers;
    if ([self respondsToSelector:action]) {
        item.target = self;
    }
    return item;
}

/* The standard About panel, populated explicitly so unbundled dev runs
 * show the manifest identity a packaged bundle reads from Info.plist. */
- (void)showAboutPanel:(id)sender {
    (void)sender;
    NSMutableDictionary<NSAboutPanelOptionKey, id> *options = [[NSMutableDictionary alloc] init];
    options[NSAboutPanelOptionApplicationName] = self.displayName;
    if (self.appVersion.length > 0) {
        options[NSAboutPanelOptionApplicationVersion] = self.appVersion;
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
    NSWindow *keyWindow = NSApp.keyWindow;
    uint64_t windowId = 1;
    for (NSNumber *key in self.windows) {
        if ([self.windows[key] isEqual:keyWindow]) {
            windowId = key.unsignedLongLongValue;
            break;
        }
    }
    if (self.browsers) {
        auto it = self.browsers->find(windowId);
        if (it != self.browsers->end() && it->second) {
            it->second->ReloadIgnoreCache();
        }
    }
}

- (void)dealloc {
    if (self.shortcutEventMonitor) {
        [NSEvent removeMonitor:self.shortcutEventMonitor];
        self.shortcutEventMonitor = nil;
    }
    delete self.webviewCefClients;
    delete self.webviewBrowsers;
    delete self.cefClients;
    delete self.browsers;
}

- (BOOL)createWindowWithId:(uint64_t)windowId title:(NSString *)title label:(NSString *)label x:(double)x y:(double)y width:(double)width height:(double)height restoreFrame:(BOOL)restoreFrame resizable:(BOOL)resizable makeMain:(BOOL)makeMain {
    NSNumber *key = @(windowId);
    if (self.windows[key]) return NO;

    NSRect rect = restoreFrame ? NativeSdkConstrainFrame(NSMakeRect(x, y, width, height)) : NSMakeRect(0, 0, width, height);
    NSWindowStyleMask styleMask = NSWindowStyleMaskTitled |
                                  NSWindowStyleMaskClosable |
                                  NSWindowStyleMaskMiniaturizable;
    if (resizable) {
        styleMask |= NSWindowStyleMaskResizable;
    }
    NSWindow *window = [[NSWindow alloc] initWithContentRect:rect
                                                   styleMask:styleMask
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [window setTitle:title.length > 0 ? title : @"native-sdk"];
    if (!restoreFrame) [window center];

    NSView *stackRoot = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    stackRoot.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    window.contentView = stackRoot;

    NSView *browserContainer = [[NSView alloc] initWithFrame:stackRoot.bounds];
    browserContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    browserContainer.wantsLayer = YES;
    browserContainer.layer.zPosition = 0;
    [stackRoot addSubview:browserContainer positioned:NSWindowAbove relativeTo:nil];

    NativeSdkChromiumWindowDelegate *delegate = [[NativeSdkChromiumWindowDelegate alloc] init];
    delegate.host = self;
    delegate.windowId = windowId;
    window.delegate = delegate;
    CefRefPtr<NativeSdkCefClient> client = new NativeSdkCefClient(self, windowId);

    self.windows[key] = window;
    self.browserContainers[key] = browserContainer;
    self.delegates[key] = delegate;
    self.windowLabels[key] = label.length > 0 ? label : (makeMain ? @"main" : @"");
    (*self.cefClients)[windowId] = client;
    if (makeMain) {
        self.window = window;
        self.browserContainer = browserContainer;
        self.delegate = delegate;
        self.cefClient = client;
    } else {
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    }
    return YES;
}

- (void)focusWindowWithId:(uint64_t)windowId {
    NSWindow *window = self.windows[@(windowId)];
    if (!window) return;
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self emitWindowFrameForWindowId:windowId open:YES];
}

- (void)closeWindowWithId:(uint64_t)windowId {
    void (^closeBlock)(void) = ^{
        NSWindow *window = self.windows[@(windowId)];
        if (!window) {
            return;
        }
        [self closeWebViewsInWindow:windowId];
        if (self.browsers) {
            auto it = self.browsers->find(windowId);
            if (it != self.browsers->end() && it->second) {
                [window orderOut:nil];
                [self emitWindowFrameForWindowId:windowId open:NO];
                return;
            }
        }
        [window close];
    };
    if ([NSThread isMainThread]) {
        closeBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), closeBlock);
    }
}

- (void)runWithCallback:(native_sdk_appkit_event_callback_t)callback context:(void *)context {
    self.callback = callback;
    self.context = context;

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    if (!self.shortcutEventMonitor) {
        __weak NativeSdkChromiumHost *weakSelf = self;
        self.shortcutEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
            NativeSdkChromiumHost *strongSelf = weakSelf;
            if (strongSelf && [strongSelf handleShortcutEvent:event]) return nil;
            return event;
        }];
    }

    [self emitEvent:(native_sdk_appkit_event_t){ .kind = NATIVE_SDK_APPKIT_EVENT_START }];
    // A failed START handler requests shutdown synchronously, before the
    // run loop exists — [NSApp stop:] is a no-op there. Honor the request
    // here instead of stranding a live app behind a blank window.
    if (self.didShutdown) {
        shutdownCefIfNeeded();
        return;
    }
    [self emitResize];
    [self emitWindowFrameForWindowId:1 open:YES];
    [self startApplicationActivationObservers];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 60.0)
                                                 target:self
                                               selector:@selector(emitFrame)
                                               userInfo:nil
                                                repeats:YES];
    [NSApp run];
    shutdownCefIfNeeded();
}

- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
    [self invalidateAppTimers];
    if (self.shortcutEventMonitor) {
        [NSEvent removeMonitor:self.shortcutEventMonitor];
        self.shortcutEventMonitor = nil;
    }
    [self stopApplicationActivationObservers];
    if (self.browsers) {
        for (auto &entry : *self.browsers) {
            if (entry.second) entry.second->GetHost()->CloseBrowser(true);
        }
    } else if (self.browser) {
        self.browser->GetHost()->CloseBrowser(true);
    }
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
    if (self.callback) self.callback(self.context, &event);
}

- (void)startApplicationActivationObservers {
    if (self.observesApplicationActivation) return;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(applicationDidBecomeActive:) name:NSApplicationDidBecomeActiveNotification object:NSApp];
    [center addObserver:self selector:@selector(applicationDidResignActive:) name:NSApplicationDidResignActiveNotification object:NSApp];
    self.observesApplicationActivation = YES;
}

- (void)stopApplicationActivationObservers {
    if (!self.observesApplicationActivation) return;
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

- (void)emitResize {
    [self emitResizeForWindowId:1];
}

- (void)emitResizeForWindowId:(uint64_t)windowId {
    NSWindow *window = self.windows[@(windowId)] ?: self.window;
    CefRefPtr<CefBrowser> browser;
    if (self.browsers) {
        auto it = self.browsers->find(windowId);
        if (it != self.browsers->end()) browser = it->second;
    }
    NSRect bounds = window.contentView.bounds;
    if (browser) browser->GetHost()->WasResized();
    [self emitEvent:(native_sdk_appkit_event_t){
        .kind = NATIVE_SDK_APPKIT_EVENT_RESIZE,
        .window_id = windowId,
        .width = bounds.size.width,
        .height = bounds.size.height,
        .scale = window.backingScaleFactor,
    }];
}

- (void)emitWindowFrameForWindowId:(uint64_t)windowId open:(BOOL)open {
    NSWindow *window = self.windows[@(windowId)] ?: self.window;
    NSString *label = self.windowLabels[@(windowId)] ?: @"";
    NSRect frame = window.frame;
    [self emitEvent:(native_sdk_appkit_event_t){
        .kind = NATIVE_SDK_APPKIT_EVENT_WINDOW_FRAME,
        .window_id = windowId,
        .width = frame.size.width,
        .height = frame.size.height,
        .scale = window.backingScaleFactor,
        .x = frame.origin.x,
        .y = frame.origin.y,
        .open = open ? 1 : 0,
        .focused = window.isKeyWindow ? 1 : 0,
        .label = label.UTF8String,
        .label_len = [label lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
    }];
}

- (void)emitFrame {
    CefDoMessageLoopWork();
    [self emitEvent:(native_sdk_appkit_event_t){ .kind = NATIVE_SDK_APPKIT_EVENT_FRAME }];
}

- (void)emitShutdown {
    if (self.didShutdown) return;
    self.didShutdown = YES;
    [self emitEvent:(native_sdk_appkit_event_t){ .kind = NATIVE_SDK_APPKIT_EVENT_SHUTDOWN }];
}

/* App timers and cross-thread wake, mirrored from the AppKit host: the
 * runtime's scheduler and effect queue rely on TIMER/WAKE events on both
 * engines. */
- (void)startAppTimerWithId:(uint64_t)timerId intervalNs:(uint64_t)intervalNs repeats:(BOOL)repeats {
    NSNumber *key = @(timerId);
    [self.appTimers[key] invalidate];
    NSTimeInterval interval = (NSTimeInterval)intervalNs / 1000000000.0;
    // Common modes: a timer must keep firing while the user holds a menu
    // open or live-resizes the window (same discipline as the AppKit host).
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
        .timestamp_ns = NativeSdkChromiumTimestampNanoseconds(),
    }];
}

- (void)invalidateAppTimers {
    for (NSTimer *timer in self.appTimers.allValues) {
        [timer invalidate];
    }
    [self.appTimers removeAllObjects];
}

/* Called from any thread: marshal onto the main queue and emit the WAKE
 * event there, so the runtime's effect-queue drain always runs on the
 * loop thread. */
- (void)wakeFromAnyThread {
    __weak NativeSdkChromiumHost *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NativeSdkChromiumHost *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.didShutdown) return;
        [strongSelf emitEvent:(native_sdk_appkit_event_t){
            .kind = NATIVE_SDK_APPKIT_EVENT_WAKE,
            .timestamp_ns = NativeSdkChromiumTimestampNanoseconds(),
        }];
    });
}

- (void)loadSource:(NSString *)source kind:(NSInteger)kind assetRoot:(NSString *)assetRoot entry:(NSString *)entry origin:(NSString *)origin spaFallback:(BOOL)spaFallback {
    [self loadSource:source kind:kind assetRoot:assetRoot entry:entry origin:origin spaFallback:spaFallback windowId:1];
}

- (void)loadSource:(NSString *)source kind:(NSInteger)kind assetRoot:(NSString *)assetRoot entry:(NSString *)entry origin:(NSString *)origin spaFallback:(BOOL)spaFallback windowId:(uint64_t)windowId {
    NSString *urlString = source;
    NSString *bridgeOrigin = nil;
    NSString *internalURLPrefix = nil;
    NSString *assetEntryPath = nil;
    if (kind == 0) {
        urlString = temporaryHtmlUrl(source);
        bridgeOrigin = @"zero://inline";
        internalURLPrefix = urlString;
    } else if (kind == 2) {
        NSString *resolvedRoot = NativeSdkResolvedAssetRoot(assetRoot ?: @"");
        NSString *assetEntry = entry.length > 0 ? entry : @"index.html";
        while ([assetEntry hasPrefix:@"/"]) {
            assetEntry = [assetEntry substringFromIndex:1];
        }
        if (assetEntry.length == 0) assetEntry = @"index.html";
        assetEntryPath = assetEntry;
        urlString = [NSURL fileURLWithPath:[resolvedRoot stringByAppendingPathComponent:assetEntry]].absoluteString;
        bridgeOrigin = origin.length > 0 ? origin : @"zero://app";
        internalURLPrefix = [NSURL fileURLWithPath:resolvedRoot isDirectory:YES].absoluteString;
    }
    NSNumber *key = @(windowId);
    if (bridgeOrigin) {
        self.bridgeOrigins[key] = bridgeOrigin;
    } else {
        [self.bridgeOrigins removeObjectForKey:key];
    }
    if (internalURLPrefix) {
        self.internalURLPrefixes[key] = internalURLPrefix;
    } else {
        [self.internalURLPrefixes removeObjectForKey:key];
    }
    if (kind == 2) {
        self.assetRoots[key] = NativeSdkResolvedAssetRoot(assetRoot ?: @"");
        self.assetEntries[key] = assetEntryPath.length > 0 ? assetEntryPath : @"index.html";
        self.assetOrigins[key] = bridgeOrigin.length > 0 ? bridgeOrigin : @"zero://app";
    } else {
        [self.assetRoots removeObjectForKey:key];
        [self.assetEntries removeObjectForKey:key];
        [self.assetOrigins removeObjectForKey:key];
    }
    if (kind == 2 && spaFallback) {
        self.fallbackURLs[key] = urlString;
    } else {
        [self.fallbackURLs removeObjectForKey:key];
    }
    NSView *container = self.browserContainers[@(windowId)] ?: self.browserContainer;
    CefRefPtr<CefBrowser> browser;
    if (self.browsers) {
        auto browser_it = self.browsers->find(windowId);
        if (browser_it != self.browsers->end()) browser = browser_it->second;
    }
    if (browser) {
        browser->GetMainFrame()->LoadURL(std::string(urlString.UTF8String));
        return;
    }

    CefWindowInfo windowInfo;
    CefRect rect(0, 0, container.bounds.size.width, container.bounds.size.height);
    windowInfo.SetAsChild((__bridge void *)container, rect);
    CefBrowserSettings browserSettings;
    CefRefPtr<NativeSdkCefClient> client = (*self.cefClients)[windowId];
    CefBrowserHost::CreateBrowser(windowInfo, client.get(), std::string(urlString.UTF8String), browserSettings, NativeSdkCefExtraInfo(true), nullptr);
}

- (NSString *)webViewKeyForWindow:(uint64_t)windowId label:(NSString *)label {
    return [NSString stringWithFormat:@"%llu:%@", windowId, label ?: @""];
}

- (NSView *)stackViewForWindowId:(uint64_t)windowId {
    NSWindow *window = self.windows[@(windowId)] ?: (windowId == 1 ? self.window : nil);
    return window.contentView;
}

- (NSRect)webViewFrameForContainer:(NSView *)container x:(double)x y:(double)y width:(double)width height:(double)height {
    CGFloat nativeY = container.isFlipped ? y : container.bounds.size.height - y - height;
    return NSMakeRect(x, nativeY, width, height);
}

- (BOOL)createWebViewInWindow:(uint64_t)windowId label:(NSString *)label url:(NSString *)url x:(double)x y:(double)y width:(double)width height:(double)height layer:(NSInteger)layer transparent:(BOOL)transparent bridgeEnabled:(BOOL)bridgeEnabled {
    if (label.length == 0 || url.length == 0 || width <= 0 || height <= 0 || x < 0 || y < 0) return NO;
    NSView *container = self.browserContainers[@(windowId)] ?: (windowId == 1 ? self.browserContainer : nil);
    NSView *stackView = [self stackViewForWindowId:windowId];
    if (!container || !stackView) return NO;
    NSURL *targetURL = [NSURL URLWithString:url];
    if (!targetURL || ![self allowsNavigationURL:targetURL]) return NO;
    NSString *resolvedURL = [self resolvedWebViewURLString:url windowId:windowId];
    if (resolvedURL.length == 0) return NO;
    NSString *key = [self webViewKeyForWindow:windowId label:label];
    if (self.webviewViews[key]) return NO;

    NSView *webview = [[NSView alloc] initWithFrame:[self webViewFrameForContainer:stackView x:x y:y width:width height:height]];
    webview.frame = [self webViewFrameForContainer:stackView x:x y:y width:width height:height];
    webview.autoresizingMask = NSViewNotSizable;
    webview.wantsLayer = YES;
    webview.layer.zPosition = layer;
    if (transparent) webview.layer.backgroundColor = NSColor.clearColor.CGColor;
    [stackView addSubview:webview positioned:NSWindowAbove relativeTo:nil];
    self.webviewViews[key] = webview;
    uint64_t generation = self.nextWebViewGeneration++;
    if (self.nextWebViewGeneration == 0) self.nextWebViewGeneration = 1;
    self.webviewGenerations[key] = @(generation);
    [self reorderWebViewsInWindow:windowId];

    std::string keyString(key.UTF8String);
    CefRefPtr<NativeSdkCefClient> client = new NativeSdkCefClient(self, windowId, keyString, generation, bridgeEnabled);
    if (self.webviewCefClients) (*self.webviewCefClients)[keyString] = client;
    CefWindowInfo windowInfo;
    CefRect rect(0, 0, webview.bounds.size.width, webview.bounds.size.height);
    windowInfo.SetAsChild((__bridge void *)webview, rect);
    CefBrowserSettings browserSettings;
    CefBrowserHost::CreateBrowser(windowInfo, client.get(), std::string(resolvedURL.UTF8String), browserSettings, NativeSdkCefExtraInfo(bridgeEnabled), nullptr);
    return YES;
}

- (BOOL)setWebViewFrameInWindow:(uint64_t)windowId label:(NSString *)label x:(double)x y:(double)y width:(double)width height:(double)height {
    if (label.length == 0 || width <= 0 || height <= 0 || x < 0 || y < 0) return NO;
    NSView *container = self.browserContainers[@(windowId)] ?: (windowId == 1 ? self.browserContainer : nil);
    if ([label isEqualToString:@"main"]) {
        if (!container) return NO;
        NSView *parent = [self stackViewForWindowId:windowId];
        if (!parent) return NO;
        container.autoresizingMask = NSViewNotSizable;
        container.frame = [self webViewFrameForContainer:parent x:x y:y width:width height:height];
        [self reorderWebViewsInWindow:windowId];
        if (self.browsers) {
            auto it = self.browsers->find(windowId);
            if (it != self.browsers->end() && it->second) it->second->GetHost()->WasResized();
        }
        return YES;
    }
    NSView *webview = self.webviewViews[[self webViewKeyForWindow:windowId label:label]];
    NSView *stackView = [self stackViewForWindowId:windowId];
    if (!container || !stackView || !webview) return NO;
    webview.frame = [self webViewFrameForContainer:stackView x:x y:y width:width height:height];
    [self reorderWebViewsInWindow:windowId];
    std::string keyString([self webViewKeyForWindow:windowId label:label].UTF8String);
    if (self.webviewBrowsers) {
        auto it = self.webviewBrowsers->find(keyString);
        if (it != self.webviewBrowsers->end() && it->second) it->second->GetHost()->WasResized();
    }
    return YES;
}

- (BOOL)navigateWebViewInWindow:(uint64_t)windowId label:(NSString *)label url:(NSString *)url {
    if (label.length == 0 || url.length == 0) return NO;
    NSURL *targetURL = [NSURL URLWithString:url];
    if (!targetURL || ![self allowsNavigationURL:targetURL]) return NO;
    NSString *resolvedURL = [self resolvedWebViewURLString:url windowId:windowId];
    if (resolvedURL.length == 0) return NO;
    if ([label isEqualToString:@"main"]) {
        if (self.browsers) {
            auto it = self.browsers->find(windowId);
            if (it != self.browsers->end() && it->second) {
                it->second->GetMainFrame()->LoadURL(std::string(resolvedURL.UTF8String));
                return YES;
            }
        }
        return NO;
    }
    NSView *webview = self.webviewViews[[self webViewKeyForWindow:windowId label:label]];
    if (!webview) return NO;
    std::string keyString([self webViewKeyForWindow:windowId label:label].UTF8String);
    if (self.webviewBrowsers) {
        auto it = self.webviewBrowsers->find(keyString);
        if (it != self.webviewBrowsers->end() && it->second) {
            it->second->GetMainFrame()->LoadURL(std::string(resolvedURL.UTF8String));
            return YES;
        }
    }
    self.webviewPendingURLs[[self webViewKeyForWindow:windowId label:label]] = resolvedURL;
    return YES;
}

- (BOOL)setWebViewZoomInWindow:(uint64_t)windowId label:(NSString *)label zoom:(double)zoom {
    if (label.length == 0 || zoom < 0.25 || zoom > 5.0) return NO;
    const double zoomLevel = log(zoom) / log(1.2);
    if ([label isEqualToString:@"main"]) {
        if (self.browsers) {
            auto it = self.browsers->find(windowId);
            if (it != self.browsers->end() && it->second) {
                it->second->GetHost()->SetZoomLevel(zoomLevel);
                return YES;
            }
        }
        return NO;
    }
    NSString *key = [self webViewKeyForWindow:windowId label:label];
    if (!self.webviewViews[key]) return NO;
    std::string keyString(key.UTF8String);
    if (self.webviewBrowsers) {
        auto it = self.webviewBrowsers->find(keyString);
        if (it != self.webviewBrowsers->end() && it->second) {
            it->second->GetHost()->SetZoomLevel(zoomLevel);
            [self.webviewPendingZooms removeObjectForKey:key];
            return YES;
        }
    }
    self.webviewPendingZooms[key] = @(zoom);
    return YES;
}

- (BOOL)setWebViewLayerInWindow:(uint64_t)windowId label:(NSString *)label layer:(NSInteger)layer {
    if (label.length == 0) return NO;
    if ([label isEqualToString:@"main"]) {
        NSView *container = self.browserContainers[@(windowId)] ?: (windowId == 1 ? self.browserContainer : nil);
        if (!container) return NO;
        container.wantsLayer = YES;
        container.layer.zPosition = layer;
        [self reorderWebViewsInWindow:windowId];
        return YES;
    }
    NSView *webview = self.webviewViews[[self webViewKeyForWindow:windowId label:label]];
    if (!webview) return NO;
    webview.wantsLayer = YES;
    webview.layer.zPosition = layer;
    [self reorderWebViewsInWindow:windowId];
    return YES;
}

- (BOOL)closeWebViewInWindow:(uint64_t)windowId label:(NSString *)label {
    NSString *key = [self webViewKeyForWindow:windowId label:label];
    if ([self.closingWebViewKeys containsObject:key]) return YES;
    NSView *webview = self.webviewViews[key];
    if (!webview) return NO;
    std::string keyString(key.UTF8String);
    [self.closingWebViewKeys addObject:key];
    [self.webviewPendingURLs removeObjectForKey:key];
    [self.webviewPendingZooms removeObjectForKey:key];
    CefRefPtr<CefBrowser> browser;
    if (self.webviewBrowsers) {
        auto browser_it = self.webviewBrowsers->find(keyString);
        if (browser_it != self.webviewBrowsers->end() && browser_it->second) {
            browser = browser_it->second;
        }
    }
    if (browser) browser->GetHost()->CloseBrowser(true);
    [self cleanupClosedWebViewWithKey:key];
    return YES;
}

- (void)closeWebViewsInWindow:(uint64_t)windowId {
    NSString *prefix = [NSString stringWithFormat:@"%llu:", windowId];
    NSArray<NSString *> *keys = [self.webviewViews.allKeys copy];
    for (NSString *key in keys) {
        if (![key hasPrefix:prefix]) continue;
        NSRange separator = [key rangeOfString:@":"];
        NSString *label = separator.location == NSNotFound ? key : [key substringFromIndex:separator.location + 1];
        [self closeWebViewInWindow:windowId label:label];
    }
}

- (void)reorderWebViewsInWindow:(uint64_t)windowId {
    NSView *stackView = [self stackViewForWindowId:windowId];
    if (!stackView) return;

    NSMutableArray<NSView *> *views = [[NSMutableArray alloc] init];
    NSView *mainView = self.browserContainers[@(windowId)] ?: (windowId == 1 ? self.browserContainer : nil);
    if (mainView && mainView.superview == stackView) {
        mainView.wantsLayer = YES;
        [views addObject:mainView];
    }

    NSString *prefix = [NSString stringWithFormat:@"%llu:", windowId];
    for (NSString *key in self.webviewViews) {
        if (![key hasPrefix:prefix]) continue;
        NSView *webView = self.webviewViews[key];
        if (webView && webView.superview == stackView) {
            webView.wantsLayer = YES;
            [views addObject:webView];
        }
    }

    [views sortUsingComparator:^NSComparisonResult(NSView *first, NSView *second) {
        CGFloat firstLayer = first.layer.zPosition;
        CGFloat secondLayer = second.layer.zPosition;
        if (firstLayer < secondLayer) return NSOrderedAscending;
        if (firstLayer > secondLayer) return NSOrderedDescending;
        NSUInteger firstIndex = [stackView.subviews indexOfObjectIdenticalTo:first];
        NSUInteger secondIndex = [stackView.subviews indexOfObjectIdenticalTo:second];
        if (firstIndex < secondIndex) return NSOrderedAscending;
        if (firstIndex > secondIndex) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSView *previous = nil;
    for (NSView *view in views) {
        [stackView addSubview:view positioned:NSWindowAbove relativeTo:previous];
        previous = view;
    }
}

- (void)setAllowedNavigationOrigins:(NSArray<NSString *> *)origins externalURLs:(NSArray<NSString *> *)externalURLs externalAction:(NSInteger)externalAction {
    self.allowedNavigationOrigins = origins.count > 0 ? origins : @[ @"zero://app", @"zero://inline" ];
    self.allowedExternalURLs = externalURLs ?: @[];
    self.externalLinkAction = externalAction;
}

- (BOOL)isInternalURL:(NSURL *)url {
    NSString *absolute = url.absoluteString ?: @"";
    for (NSString *prefix in self.internalURLPrefixes.allValues) {
        if ([absolute hasPrefix:prefix]) return YES;
    }
    return NO;
}

- (BOOL)isInternalURL:(NSURL *)url windowId:(uint64_t)windowId {
    NSString *prefix = self.internalURLPrefixes[@(windowId)];
    NSString *absolute = url.absoluteString ?: @"";
    return prefix.length > 0 && [absolute hasPrefix:prefix];
}

- (BOOL)allowsNavigationURL:(NSURL *)url {
    if (!url) return YES;
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if (scheme.length == 0 || [scheme isEqualToString:@"about"]) return YES;
    if ([self isInternalURL:url]) return YES;
    return NativeSdkPolicyListMatches(self.allowedNavigationOrigins, url);
}

- (BOOL)openExternalURLIfAllowed:(NSURL *)url {
    if (self.externalLinkAction != 1) return NO;
    if (!NativeSdkPolicyListMatches(self.allowedExternalURLs, url)) return NO;
    [[NSWorkspace sharedWorkspace] openURL:url];
    return YES;
}

- (NSString *)resolvedWebViewURLString:(NSString *)url windowId:(uint64_t)windowId {
    NSURL *targetURL = [NSURL URLWithString:url ?: @""];
    if (!targetURL) return nil;
    NSNumber *key = @(windowId);
    NSString *assetOrigin = self.assetOrigins[key];
    NSString *assetRoot = self.assetRoots[key];
    NSString *assetEntry = self.assetEntries[key];
    if (assetOrigin.length == 0 || assetRoot.length == 0) return url;
    if (![NativeSdkOriginForURL(targetURL) isEqualToString:assetOrigin]) return url;

    NSString *relativePath = NativeSdkSafeAssetPath(targetURL, assetEntry.length > 0 ? assetEntry : @"index.html");
    if (!relativePath) return nil;
    NSURL *fileURL = [NSURL fileURLWithPath:[assetRoot stringByAppendingPathComponent:relativePath]];
    NSURLComponents *components = [NSURLComponents componentsWithURL:fileURL resolvingAgainstBaseURL:NO];
    components.query = targetURL.query;
    components.fragment = targetURL.fragment;
    return components.URL.absoluteString ?: fileURL.absoluteString;
}

- (void)setBrowser:(CefRefPtr<CefBrowser>)browser windowId:(uint64_t)windowId {
    if (self.browsers) (*self.browsers)[windowId] = browser;
    if (windowId == 1) self.browser = browser;
}

- (BOOL)webViewGeneration:(uint64_t)generation matchesKey:(NSString *)key {
    NSNumber *current = self.webviewGenerations[key];
    return current && current.unsignedLongLongValue == generation;
}

- (void)setWebViewBrowser:(CefRefPtr<CefBrowser>)browser key:(NSString *)key generation:(uint64_t)generation {
    if (!self.webviewBrowsers || key.length == 0) return;
    if (![self webViewGeneration:generation matchesKey:key] || [self.closingWebViewKeys containsObject:key]) {
        if (browser) browser->GetHost()->CloseBrowser(true);
        return;
    }
    (*self.webviewBrowsers)[std::string(key.UTF8String)] = browser;
    NSString *pendingURL = self.webviewPendingURLs[key];
    if (pendingURL.length > 0 && browser) {
        browser->GetMainFrame()->LoadURL(std::string(pendingURL.UTF8String));
        [self.webviewPendingURLs removeObjectForKey:key];
    }
    NSNumber *pendingZoom = self.webviewPendingZooms[key];
    if (pendingZoom && browser) {
        browser->GetHost()->SetZoomLevel(log(pendingZoom.doubleValue) / log(1.2));
        [self.webviewPendingZooms removeObjectForKey:key];
    }
}

- (void)cleanupClosedWebViewWithKey:(NSString *)key {
    if (key.length == 0) return;
    std::string keyString(key.UTF8String);
    if (self.webviewBrowsers) self.webviewBrowsers->erase(keyString);
    if (self.webviewCefClients) self.webviewCefClients->erase(keyString);
    [self.webviewPendingURLs removeObjectForKey:key];
    [self.webviewPendingZooms removeObjectForKey:key];
    [self.webviewGenerations removeObjectForKey:key];
    [self.webviewViews[key] removeFromSuperview];
    [self.webviewViews removeObjectForKey:key];
    [self.closingWebViewKeys removeObject:key];
}

- (void)cleanupClosedWebViewWithKey:(NSString *)key generation:(uint64_t)generation {
    if (![self webViewGeneration:generation matchesKey:key]) return;
    [self cleanupClosedWebViewWithKey:key];
}

- (NSString *)fallbackURLForWindowId:(uint64_t)windowId {
    return self.fallbackURLs[@(windowId)];
}

- (NSString *)bridgeOriginForWindowId:(uint64_t)windowId webViewLabel:(NSString *)webViewLabel sourceURL:(NSString *)sourceURL {
    NSURL *url = [NSURL URLWithString:sourceURL ?: @""];
    NSString *label = webViewLabel.length > 0 ? webViewLabel : @"main";
    NSString *assetOrigin = self.assetOrigins[@(windowId)];
    if ([label isEqualToString:@"main"]) {
        NSString *origin = self.bridgeOrigins[@(windowId)];
        if (origin.length > 0) return origin;
    } else if (assetOrigin.length > 0 && [self isInternalURL:url windowId:windowId]) {
        return assetOrigin;
    }
    return NativeSdkOriginForURL(url);
}

- (void)receiveBridgePayload:(NSString *)payload origin:(NSString *)origin windowId:(uint64_t)windowId webViewLabel:(NSString *)webViewLabel {
    if (!self.bridgeCallback) return;
    NSData *payloadData = [payload dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSData *originData = [origin dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSData *labelData = [(webViewLabel.length > 0 ? webViewLabel : @"main") dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    self.bridgeCallback(self.bridgeContext, windowId, (const char *)labelData.bytes, labelData.length, (const char *)payloadData.bytes, payloadData.length, (const char *)originData.bytes, originData.length);
}

- (void)completeBridgeWithResponse:(NSString *)response {
    [self completeBridgeWithResponse:response windowId:1 webViewLabel:@"main"];
}

- (void)completeBridgeWithResponse:(NSString *)response windowId:(uint64_t)windowId {
    [self completeBridgeWithResponse:response windowId:windowId webViewLabel:@"main"];
}

- (void)completeBridgeWithResponse:(NSString *)response windowId:(uint64_t)windowId webViewLabel:(NSString *)webViewLabel {
    CefRefPtr<CefBrowser> browser;
    NSString *label = webViewLabel.length > 0 ? webViewLabel : @"main";
    if ([label isEqualToString:@"main"] && self.browsers) {
        auto it = self.browsers->find(windowId);
        if (it != self.browsers->end()) browser = it->second;
    } else if (self.webviewBrowsers) {
        std::string key = std::string([[self webViewKeyForWindow:windowId label:label] UTF8String]);
        auto it = self.webviewBrowsers->find(key);
        if (it != self.webviewBrowsers->end()) browser = it->second;
    }
    if (!browser) return;
    CefRefPtr<CefFrame> frame = browser->GetMainFrame();
    if (!frame) return;
    NSString *script = [NSString stringWithFormat:@"window.zero&&window.zero._complete(%@);", response.length > 0 ? response : @"{}"];
    std::string scriptString(script.UTF8String);
    frame->ExecuteJavaScript(scriptString, frame->GetURL(), 0);
}

- (void)emitEventNamed:(NSString *)name detailJSON:(NSString *)detailJSON windowId:(uint64_t)windowId {
    CefRefPtr<CefBrowser> browser;
    if (self.browsers) {
        auto it = self.browsers->find(windowId);
        if (it != self.browsers->end()) browser = it->second;
    }
    if (!browser) return;
    CefRefPtr<CefFrame> frame = browser->GetMainFrame();
    if (!frame) return;
    NSData *nameData = [NSJSONSerialization dataWithJSONObject:name ?: @"" options:NSJSONWritingFragmentsAllowed error:nil];
    NSString *nameJSON = nameData ? [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding] : @"\"\"";
    NSString *detail = detailJSON.length > 0 ? detailJSON : @"null";
    NSString *script = [NSString stringWithFormat:@"window.zero&&window.zero._emit(%@,%@);", nameJSON, detail];
    frame->ExecuteJavaScript(std::string(script.UTF8String), frame->GetURL(), 0);
}

- (BOOL)handleShortcutEvent:(NSEvent *)event {
    if (event.type != NSEventTypeKeyDown) return NO;
    NSString *key = NativeSdkShortcutKeyForEvent(event);
    if (key.length == 0) return NO;
    BOOL usesImplicitShift = NativeSdkShortcutUsesImplicitShift(key, event);

    for (NSUInteger pass = 0; pass < (usesImplicitShift ? 2 : 1); pass++) {
        BOOL allowImplicitShift = pass == 1;
        for (NativeSdkChromiumShortcut *shortcut in self.shortcuts) {
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

- (void)setShortcutsWithIds:(const char *const *)ids idLengths:(const size_t *)idLengths keys:(const char *const *)keys keyLengths:(const size_t *)keyLengths modifiers:(const uint32_t *)modifiers count:(size_t)count {
    NSMutableArray<NativeSdkChromiumShortcut *> *items = [[NSMutableArray alloc] initWithCapacity:count];
    for (size_t index = 0; index < count; index++) {
        NSString *identifier = ids[index] ? [[NSString alloc] initWithBytes:ids[index] length:idLengths[index] encoding:NSUTF8StringEncoding] : @"";
        NSString *key = keys[index] ? [[NSString alloc] initWithBytes:keys[index] length:keyLengths[index] encoding:NSUTF8StringEncoding] : @"";
        if (identifier.length == 0 || key.length == 0) continue;
        NativeSdkChromiumShortcut *shortcut = [[NativeSdkChromiumShortcut alloc] init];
        shortcut.identifier = identifier;
        shortcut.key = key.lowercaseString;
        shortcut.modifiers = modifiers[index];
        [items addObject:shortcut];
    }
    self.shortcuts = items;
}

- (void)trayMenuItemClicked:(NSMenuItem *)menuItem {
    if (self.trayCallback) self.trayCallback(self.trayContext, (uint32_t)menuItem.tag);
}

@end

namespace {

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

void NativeSdkCefClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
    if (!webview_key_.empty()) {
        NSString *key = [[NSString alloc] initWithBytes:webview_key_.data() length:webview_key_.size() encoding:NSUTF8StringEncoding];
        [host_ setWebViewBrowser:browser key:key ?: @"" generation:webview_generation_];
        return;
    }
    [host_ setBrowser:browser windowId:window_id_];
}

void NativeSdkCefClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
    (void)browser;
    if (webview_key_.empty()) return;
    NSString *key = [[NSString alloc] initWithBytes:webview_key_.data() length:webview_key_.size() encoding:NSUTF8StringEncoding];
    [host_ cleanupClosedWebViewWithKey:key ?: @"" generation:webview_generation_];
}

void NativeSdkCefClient::OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, ErrorCode errorCode, const CefString& errorText, const CefString& failedUrl) {
    (void)browser;
    (void)errorText;
    if (!frame || !frame->IsMain() || errorCode != ERR_FILE_NOT_FOUND) return;
    NSString *fallback = [host_ fallbackURLForWindowId:window_id_];
    if (fallback.length == 0) return;
    std::string failed = failedUrl.ToString();
    NSString *failedString = [[NSString alloc] initWithBytes:failed.data() length:failed.size() encoding:NSUTF8StringEncoding] ?: @"";
    if ([failedString isEqualToString:fallback]) return;
    frame->LoadURL(std::string(fallback.UTF8String));
}

bool NativeSdkCefClient::OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request, bool user_gesture, bool is_redirect) {
    (void)browser;
    (void)user_gesture;
    (void)is_redirect;
    if (frame && !frame->IsMain()) return false;
    std::string url = request ? request->GetURL().ToString() : std::string();
    NSString *urlString = [[NSString alloc] initWithBytes:url.data() length:url.size() encoding:NSUTF8StringEncoding] ?: @"";
    NSURL *nsURL = [NSURL URLWithString:urlString];
    if ([host_ allowsNavigationURL:nsURL]) return false;
    if ([host_ openExternalURLIfAllowed:nsURL]) return true;
    return true;
}

bool NativeSdkCefClient::OnProcessMessageReceived(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefProcessId source_process, CefRefPtr<CefProcessMessage> message) {
    (void)browser;
    (void)source_process;
    if (message->GetName() != kBridgeMessageName) return false;
    if (!bridge_enabled_) return true;

    std::string payload = message->GetArgumentList()->GetString(0);
    std::string source_url = frame ? frame->GetURL().ToString() : std::string();
    std::string label = WebViewLabel();
    NSString *payloadString = [[NSString alloc] initWithBytes:payload.data() length:payload.size() encoding:NSUTF8StringEncoding] ?: @"{}";
    NSString *sourceURLString = [[NSString alloc] initWithBytes:source_url.data() length:source_url.size() encoding:NSUTF8StringEncoding] ?: @"";
    NSString *labelString = [[NSString alloc] initWithBytes:label.data() length:label.size() encoding:NSUTF8StringEncoding] ?: @"main";
    NSString *originString = [host_ bridgeOriginForWindowId:window_id_ webViewLabel:labelString sourceURL:sourceURLString];
    [host_ receiveBridgePayload:payloadString origin:originString windowId:window_id_ webViewLabel:labelString];
    return true;
}

} // namespace

static void NativeSdkApplyHiddenInsetTitlebar(NSWindow *window, int titlebar_style, NativeSdkChromiumWindowDelegate *delegate) {
    if (!window || (titlebar_style != 1 && titlebar_style != 2)) return;
    window.styleMask |= NSWindowStyleMaskFullSizeContentView;
    window.titlebarAppearsTransparent = YES;
    window.titleVisibility = NSWindowTitleHidden;
    if (titlebar_style == 2) {
        // hidden_inset_tall: an empty borderless toolbar switches the
        // titlebar to the unified-toolbar height and the system centers
        // the traffic lights in it (same trick as the AppKit host).
        NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"native-sdk-tall-titlebar"];
        toolbar.allowsUserCustomization = NO;
        window.toolbar = toolbar;
        window.toolbarStyle = NSWindowToolbarStyleUnified;
        window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
        if (delegate && !delegate.observesContentLayout) {
            // Chrome re-query timing rides the settled contentLayoutRect
            // (see the delegate's observeValueForKeyPath:).
            delegate.observesContentLayout = YES;
            [window addObserver:delegate forKeyPath:@"contentLayoutRect" options:0 context:NULL];
        }
    }
}

native_sdk_appkit_host_t *native_sdk_appkit_create(const char *app_name, size_t app_name_len, const char *display_name, size_t display_name_len, const char *version, size_t version_len, const char *about_description, size_t about_description_len, int has_web_content, const char *window_title, size_t window_title_len, const char *bundle_id, size_t bundle_id_len, const char *icon_path, size_t icon_path_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame, int resizable, int titlebar_style, int show_policy) {
    @autoreleasepool {
        // Present-before-show is a canvas contract; the Chromium host
        // hosts webviews only (gpu-surface presents are unsupported on
        // this engine), so the policy is accepted for ABI parity and
        // windows show immediately — the web engine owns first paint.
        // has_web_content is likewise ABI parity: this host always
        // hosts web content, and its menus already assume it.
        (void)show_policy;
        (void)has_web_content;
        (void)bundle_id;
        (void)bundle_id_len;
        (void)icon_path;
        (void)icon_path_len;
        (void)window_label;
        (void)window_label_len;
        NSString *appNameString = [[NSString alloc] initWithBytes:app_name length:app_name_len encoding:NSUTF8StringEncoding] ?: @"native-sdk";
        NSString *displayNameString = [[NSString alloc] initWithBytes:display_name length:display_name_len encoding:NSUTF8StringEncoding] ?: @"";
        NSString *versionString = [[NSString alloc] initWithBytes:version length:version_len encoding:NSUTF8StringEncoding] ?: @"";
        NSString *aboutDescriptionString = [[NSString alloc] initWithBytes:about_description length:about_description_len encoding:NSUTF8StringEncoding] ?: @"";
        NSString *titleString = [[NSString alloc] initWithBytes:window_title length:window_title_len encoding:NSUTF8StringEncoding] ?: appNameString;
        NativeSdkChromiumHost *host = [[NativeSdkChromiumHost alloc] initWithAppName:appNameString displayName:displayNameString version:versionString aboutDescription:aboutDescriptionString title:titleString width:width height:height];
        if (restore_frame) {
            [host.window setFrame:NativeSdkConstrainFrame(NSMakeRect(x, y, width, height)) display:NO];
        }
        if (!resizable) {
            host.window.styleMask &= ~NSWindowStyleMaskResizable;
        }
        NativeSdkApplyHiddenInsetTitlebar(host.window, titlebar_style, host.delegates[@1]);
        return (__bridge_retained native_sdk_appkit_host_t *)host;
    }
}

void native_sdk_appkit_destroy(native_sdk_appkit_host_t *host) {
    if (!host) return;
    CFBridgingRelease(host);
}

void native_sdk_appkit_run(native_sdk_appkit_host_t *host, native_sdk_appkit_event_callback_t callback, void *context) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    [object runWithCallback:callback context:context];
}

void native_sdk_appkit_stop(native_sdk_appkit_host_t *host) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    [object emitShutdown];
    [object stop];
}

void native_sdk_appkit_load_webview(native_sdk_appkit_host_t *host, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback) {
    native_sdk_appkit_load_window_webview(host, 1, source, source_len, source_kind, asset_root, asset_root_len, asset_entry, asset_entry_len, asset_origin, asset_origin_len, spa_fallback);
}

void native_sdk_appkit_load_window_webview(native_sdk_appkit_host_t *host, uint64_t window_id, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
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
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    object.bridgeCallback = callback;
    object.bridgeContext = context;
}

void native_sdk_appkit_bridge_respond(native_sdk_appkit_host_t *host, const char *response, size_t response_len) {
    native_sdk_appkit_bridge_respond_window(host, 1, response, response_len);
}

void native_sdk_appkit_bridge_respond_window(native_sdk_appkit_host_t *host, uint64_t window_id, const char *response, size_t response_len) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    NSString *responseString = response ? [[NSString alloc] initWithBytes:response length:response_len encoding:NSUTF8StringEncoding] : @"{}";
    [object completeBridgeWithResponse:responseString ?: @"{}" windowId:window_id];
}

void native_sdk_appkit_bridge_respond_webview(native_sdk_appkit_host_t *host, uint64_t window_id, const char *webview_label, size_t webview_label_len, const char *response, size_t response_len) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    NSString *labelString = webview_label ? [[NSString alloc] initWithBytes:webview_label length:webview_label_len encoding:NSUTF8StringEncoding] : @"main";
    NSString *responseString = response ? [[NSString alloc] initWithBytes:response length:response_len encoding:NSUTF8StringEncoding] : @"{}";
    [object completeBridgeWithResponse:responseString ?: @"{}" windowId:window_id webViewLabel:labelString ?: @"main"];
}

void native_sdk_appkit_emit_window_event(native_sdk_appkit_host_t *host, uint64_t window_id, const char *name, size_t name_len, const char *detail_json, size_t detail_json_len) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    NSString *nameString = name ? [[NSString alloc] initWithBytes:name length:name_len encoding:NSUTF8StringEncoding] : @"";
    NSString *detailString = detail_json ? [[NSString alloc] initWithBytes:detail_json length:detail_json_len encoding:NSUTF8StringEncoding] : @"null";
    [object emitEventNamed:nameString ?: @"" detailJSON:detailString ?: @"null" windowId:window_id];
}

void native_sdk_appkit_set_security_policy(native_sdk_appkit_host_t *host, const char *allowed_origins, size_t allowed_origins_len, const char *external_urls, size_t external_urls_len, int external_action) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    NSArray<NSString *> *origins = NativeSdkPolicyListFromBytes(allowed_origins, allowed_origins_len, @[ @"zero://app", @"zero://inline" ]);
    NSArray<NSString *> *externalURLs = NativeSdkPolicyListFromBytes(external_urls, external_urls_len, @[]);
    [object setAllowedNavigationOrigins:origins externalURLs:externalURLs externalAction:external_action];
}

void native_sdk_appkit_set_menus(native_sdk_appkit_host_t *host, const char *const *menu_titles, const size_t *menu_title_lens, size_t menu_count, const uint32_t *item_menu_indices, const char *const *item_labels, const size_t *item_label_lens, const char *const *item_commands, const size_t *item_command_lens, const char *const *item_keys, const size_t *item_key_lens, const uint32_t *item_modifiers, const int *item_separators, const int *item_enabled, const int *item_checked, size_t item_count) {
    (void)host;
    (void)menu_titles;
    (void)menu_title_lens;
    (void)menu_count;
    (void)item_menu_indices;
    (void)item_labels;
    (void)item_label_lens;
    (void)item_commands;
    (void)item_command_lens;
    (void)item_keys;
    (void)item_key_lens;
    (void)item_modifiers;
    (void)item_separators;
    (void)item_enabled;
    (void)item_checked;
    (void)item_count;
}

int native_sdk_appkit_create_view(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int kind, const char *parent, size_t parent_len, double x, double y, double width, double height, int layer, int visible, int enabled, const char *role, size_t role_len, const char *accessibility_label, size_t accessibility_label_len, const char *text, size_t text_len, const char *command, size_t command_len) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    (void)kind;
    (void)parent;
    (void)parent_len;
    (void)x;
    (void)y;
    (void)width;
    (void)height;
    (void)layer;
    (void)visible;
    (void)enabled;
    (void)role;
    (void)role_len;
    (void)accessibility_label;
    (void)accessibility_label_len;
    (void)text;
    (void)text_len;
    (void)command;
    (void)command_len;
    return 0;
}

int native_sdk_appkit_update_view(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int has_frame, double x, double y, double width, double height, int has_layer, int layer, int has_visible, int visible, int has_enabled, int enabled, int has_role, const char *role, size_t role_len, int has_accessibility_label, const char *accessibility_label, size_t accessibility_label_len, int has_text, const char *text, size_t text_len, int has_command, const char *command, size_t command_len) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    (void)has_frame;
    (void)x;
    (void)y;
    (void)width;
    (void)height;
    (void)has_layer;
    (void)layer;
    (void)has_visible;
    (void)visible;
    (void)has_enabled;
    (void)enabled;
    (void)has_role;
    (void)role;
    (void)role_len;
    (void)has_accessibility_label;
    (void)accessibility_label;
    (void)accessibility_label_len;
    (void)has_text;
    (void)text;
    (void)text_len;
    (void)has_command;
    (void)command;
    (void)command_len;
    return 0;
}

int native_sdk_appkit_set_view_frame(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    (void)x;
    (void)y;
    (void)width;
    (void)height;
    return 0;
}

int native_sdk_appkit_set_view_visible(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int visible) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    (void)visible;
    return 0;
}

int native_sdk_appkit_set_view_cursor(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int cursor) {
    // Native child views are system-engine-only (create_view above); no
    // view exists for the label, so this reports it like the other stubs.
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    (void)cursor;
    return 0;
}

int native_sdk_appkit_focus_view(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    return 0;
}

int native_sdk_appkit_close_view(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    return 0;
}

void native_sdk_appkit_set_shortcuts(native_sdk_appkit_host_t *host, const char *const *ids, const size_t *id_lens, const char *const *keys, const size_t *key_lens, const uint32_t *modifiers, size_t count) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    [object setShortcutsWithIds:ids idLengths:id_lens keys:keys keyLengths:key_lens modifiers:modifiers count:count];
}

int native_sdk_appkit_create_window(native_sdk_appkit_host_t *host, uint64_t window_id, const char *window_title, size_t window_title_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame, int resizable, int titlebar_style, int show_policy) {
    // Accepted for ABI parity; see native_sdk_appkit_create.
    (void)show_policy;
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    NSString *titleString = window_title ? [[NSString alloc] initWithBytes:window_title length:window_title_len encoding:NSUTF8StringEncoding] : @"native-sdk";
    NSString *labelString = window_label ? [[NSString alloc] initWithBytes:window_label length:window_label_len encoding:NSUTF8StringEncoding] : @"";
    if (![object createWindowWithId:window_id title:titleString ?: @"native-sdk" label:labelString ?: @"" x:x y:y width:width height:height restoreFrame:(restore_frame != 0) resizable:(resizable != 0) makeMain:NO]) return 0;
    NativeSdkApplyHiddenInsetTitlebar(object.windows[@(window_id)], titlebar_style, object.delegates[@(window_id)]);
    return 1;
}

int native_sdk_appkit_focus_window(native_sdk_appkit_host_t *host, uint64_t window_id) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    if (!object.windows[@(window_id)]) return 0;
    [object focusWindowWithId:window_id];
    return 1;
}

int native_sdk_appkit_close_window(native_sdk_appkit_host_t *host, uint64_t window_id) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    if (!object.windows[@(window_id)]) return 0;
    [object closeWindowWithId:window_id];
    return 1;
}

int native_sdk_appkit_minimize_window(native_sdk_appkit_host_t *host, uint64_t window_id) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    NSWindow *window = object.windows[@(window_id)];
    if (!window) return 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        [window miniaturize:nil];
    });
    return 1;
}

int native_sdk_appkit_start_window_drag(native_sdk_appkit_host_t *host, uint64_t window_id) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    NSWindow *window = object.windows[@(window_id)];
    if (!window) return 0;
    NSEvent *event = NSApp.currentEvent;
    if (!event) return 1;
    if (event.type != NSEventTypeLeftMouseDown && event.type != NSEventTypeLeftMouseDragged) return 1;
    if (event.type == NSEventTypeLeftMouseDown && event.clickCount >= 2) {
        NSString *action = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppleActionOnDoubleClick"] ?: @"Maximize";
        if ([action isEqualToString:@"Minimize"]) {
            [window performMiniaturize:nil];
        } else if (![action isEqualToString:@"None"]) {
            [window performZoom:nil];
        }
        return 1;
    }
    [window performWindowDragWithEvent:event];
    return 1;
}

int native_sdk_appkit_window_chrome_insets(native_sdk_appkit_host_t *host, uint64_t window_id, double *top, double *left, double *bottom, double *right, double *buttons_x, double *buttons_y, double *buttons_width, double *buttons_height) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    NSWindow *window = object.windows[@(window_id)];
    if (!window) return 0;
    *top = 0;
    *left = 0;
    *bottom = 0;
    *right = 0;
    *buttons_x = 0;
    *buttons_y = 0;
    *buttons_width = 0;
    *buttons_height = 0;
    if ((window.styleMask & NSWindowStyleMaskFullSizeContentView) == 0) return 1;
    NSView *contentView = window.contentView;
    if (!contentView) return 1;
    NSRect contentBounds = contentView.bounds;
    NSRect layoutRect = [contentView convertRect:window.contentLayoutRect fromView:nil];
    double titlebarHeight = NSMaxY(contentBounds) - NSMaxY(layoutRect);
    if (titlebarHeight <= 0.5) return 1;
    *top = titlebarHeight;
    NSButton *buttons[3] = {
        [window standardWindowButton:NSWindowCloseButton],
        [window standardWindowButton:NSWindowMiniaturizeButton],
        [window standardWindowButton:NSWindowZoomButton],
    };
    NSRect cluster = NSZeroRect;
    BOOL anyButtonVisible = NO;
    for (size_t index = 0; index < 3; index += 1) {
        NSButton *button = buttons[index];
        if (!button || button.hidden || !button.superview) continue;
        NSRect buttonFrame = [contentView convertRect:button.frame fromView:button.superview];
        cluster = anyButtonVisible ? NSUnionRect(cluster, buttonFrame) : buttonFrame;
        anyButtonVisible = YES;
    }
    if (!anyButtonVisible) return 1;
    *buttons_x = NSMinX(cluster);
    *buttons_y = NSMaxY(contentBounds) - NSMaxY(cluster);
    *buttons_width = NSWidth(cluster);
    *buttons_height = NSHeight(cluster);
    if (NSMinX(cluster) < NSMidX(contentBounds)) {
        *left = NSMaxX(cluster) + (NSMinX(cluster) - NSMinX(contentBounds));
    } else {
        *right = (NSMaxX(contentBounds) - NSMinX(cluster)) + (NSMaxX(contentBounds) - NSMaxX(cluster));
    }
    return 1;
}

int native_sdk_appkit_create_webview(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len, double x, double y, double width, double height, int layer, int transparent, int bridge_enabled) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    NSString *urlString = url ? [[NSString alloc] initWithBytes:url length:url_len encoding:NSUTF8StringEncoding] : @"";
    return [object createWebViewInWindow:window_id label:labelString ?: @"" url:urlString ?: @"" x:x y:y width:width height:height layer:layer transparent:transparent != 0 bridgeEnabled:bridge_enabled != 0] ? 1 : 0;
}

int native_sdk_appkit_set_webview_frame(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object setWebViewFrameInWindow:window_id label:labelString ?: @"" x:x y:y width:width height:height] ? 1 : 0;
}

int native_sdk_appkit_navigate_webview(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    NSString *urlString = url ? [[NSString alloc] initWithBytes:url length:url_len encoding:NSUTF8StringEncoding] : @"";
    return [object navigateWebViewInWindow:window_id label:labelString ?: @"" url:urlString ?: @""] ? 1 : 0;
}

int native_sdk_appkit_set_webview_zoom(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double zoom) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object setWebViewZoomInWindow:window_id label:labelString ?: @"" zoom:zoom] ? 1 : 0;
}

int native_sdk_appkit_set_webview_layer(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int layer) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object setWebViewLayerInWindow:window_id label:labelString ?: @"" layer:layer] ? 1 : 0;
}

int native_sdk_appkit_close_webview(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    NSString *labelString = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    return [object closeWebViewInWindow:window_id label:labelString ?: @""] ? 1 : 0;
}

void native_sdk_appkit_start_timer(native_sdk_appkit_host_t *host, uint64_t timer_id, uint64_t interval_ns, int repeats) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    [object startAppTimerWithId:timer_id intervalNs:interval_ns repeats:(repeats != 0)];
}

void native_sdk_appkit_cancel_timer(native_sdk_appkit_host_t *host, uint64_t timer_id) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    [object cancelAppTimerWithId:timer_id];
}

void native_sdk_appkit_wake(native_sdk_appkit_host_t *host) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    [object wakeFromAnyThread];
}

/* Audio playback lives in the system-engine AppKit host (AVAudioPlayer).
 * The Chromium host reports the feature unsupported and the Zig side
 * refuses before calling, so these exist only to satisfy the shared C
 * ABI — each answers with its honest failure code. */
int native_sdk_appkit_audio_load(native_sdk_appkit_host_t *host, const char *path, size_t path_len) {
    (void)host;
    (void)path;
    (void)path_len;
    return 2;
}

int native_sdk_appkit_audio_load_url(native_sdk_appkit_host_t *host, const char *url, size_t url_len, const char *cache_path, size_t cache_path_len, uint64_t expected_bytes) {
    (void)host;
    (void)url;
    (void)url_len;
    (void)cache_path;
    (void)cache_path_len;
    (void)expected_bytes;
    return 2;
}

int native_sdk_appkit_audio_play(native_sdk_appkit_host_t *host) {
    (void)host;
    return 0;
}

int native_sdk_appkit_audio_pause(native_sdk_appkit_host_t *host) {
    (void)host;
    return 0;
}

int native_sdk_appkit_audio_stop(native_sdk_appkit_host_t *host) {
    (void)host;
    return 0;
}

int native_sdk_appkit_audio_seek(native_sdk_appkit_host_t *host, uint64_t position_ms) {
    (void)host;
    (void)position_ms;
    return 0;
}

int native_sdk_appkit_audio_set_volume(native_sdk_appkit_host_t *host, double volume) {
    (void)host;
    (void)volume;
    return 0;
}

void native_sdk_appkit_request_frame(native_sdk_appkit_host_t *host) {
    // The AppKit host pauses FRAME events when idle, so a cross-thread
    // frame request is how the automation arrival watcher wakes it. The
    // Chromium host pumps FRAME unconditionally at 60Hz from its
    // message-loop timer (see emitFrame), so the next tick is never more
    // than ~16 ms away and a request has nothing to add.
    (void)host;
}

/* GPU-surface compositing (pixel/packet presents, image store, scroll
 * drivers, widget accessibility trees) is implemented by the system-engine
 * AppKit host only; the Chromium host renders every window through the web
 * engine and creates no gpu-surface views (see native_sdk_appkit_create_view
 * above). These report failure through the same channel as an unknown view
 * so callers see an explicit error instead of silently dropped frames. */
int native_sdk_appkit_adopt_view_surface(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, void *ns_view) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    (void)ns_view;
    return 0;
}

int native_sdk_appkit_release_view_surface(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    return 0;
}

int native_sdk_appkit_request_gpu_surface_frame(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    return 0;
}

int native_sdk_appkit_note_gpu_surface_input(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    return 0;
}

int native_sdk_appkit_set_gpu_surface_scroll_drivers(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, const native_sdk_appkit_scroll_driver_t *drivers, size_t count) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    (void)drivers;
    (void)count;
    return 0;
}

int native_sdk_appkit_present_gpu_surface_pixels(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, size_t width, size_t height, double scale, int has_dirty_rect, double dirty_x, double dirty_y, double dirty_width, double dirty_height, const uint8_t *rgba8, size_t rgba8_len) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    (void)width;
    (void)height;
    (void)scale;
    (void)has_dirty_rect;
    (void)dirty_x;
    (void)dirty_y;
    (void)dirty_width;
    (void)dirty_height;
    (void)rgba8;
    (void)rgba8_len;
    return 0;
}

int native_sdk_appkit_present_gpu_surface_packet(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double surface_width, double surface_height, double scale, uint8_t clear_r, uint8_t clear_g, uint8_t clear_b, uint8_t clear_a, int requires_render, size_t command_count, size_t unsupported_command_count, int representable, const uint8_t *json, size_t json_len) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    (void)surface_width;
    (void)surface_height;
    (void)scale;
    (void)clear_r;
    (void)clear_g;
    (void)clear_b;
    (void)clear_a;
    (void)requires_render;
    (void)command_count;
    (void)unsupported_command_count;
    (void)representable;
    (void)json;
    (void)json_len;
    return 0;
}

int native_sdk_appkit_present_gpu_surface_packet_binary(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double surface_width, double surface_height, double scale, uint8_t clear_r, uint8_t clear_g, uint8_t clear_b, uint8_t clear_a, int requires_render, size_t command_count, size_t unsupported_command_count, int representable, const uint8_t *packet, size_t packet_len) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    (void)surface_width;
    (void)surface_height;
    (void)scale;
    (void)clear_r;
    (void)clear_g;
    (void)clear_b;
    (void)clear_a;
    (void)requires_render;
    (void)command_count;
    (void)unsupported_command_count;
    (void)representable;
    (void)packet;
    (void)packet_len;
    return 0;
}

int native_sdk_appkit_upload_gpu_surface_image(native_sdk_appkit_host_t *host, uint64_t image_id, size_t width, size_t height, const uint8_t *rgba8, size_t rgba8_len) {
    (void)host;
    (void)image_id;
    (void)width;
    (void)height;
    (void)rgba8;
    (void)rgba8_len;
    return 0;
}

int native_sdk_appkit_remove_gpu_surface_image(native_sdk_appkit_host_t *host, uint64_t image_id) {
    (void)host;
    (void)image_id;
    return 0;
}

int native_sdk_appkit_update_widget_accessibility(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, const native_sdk_appkit_widget_accessibility_node_t *nodes, size_t node_count) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    (void)nodes;
    (void)node_count;
    return 0;
}

/* The Chromium host has no packet text renderer and reports no host text
 * metrics (see native_sdk_appkit_measure_text below), so a registered
 * face has no host-side consumer: the engine's font-aware provider
 * measures registered ids and the reference path inks them. Accept the
 * registration so `Options.fonts` apps start identically under both
 * hosts; refusing here would fail startup for a face this host never
 * resolves. */
int native_sdk_appkit_register_font(uint64_t font_id, const uint8_t *bytes, size_t bytes_len) {
    if (font_id == 0 || !bytes || bytes_len == 0) return 0;
    return 1;
}

/* The Chromium host has no packet text renderer, so there are no host
 * metrics to match: return the documented negative sentinel and the canvas
 * provider uses its estimator (the same fallback the AppKit host takes for
 * invalid UTF-8). */
double native_sdk_appkit_measure_text(uint64_t font_id, double size, const char *text, size_t text_len) {
    (void)font_id;
    (void)size;
    (void)text;
    (void)text_len;
    return -1;
}

/* Batched advances twin of the decline above: no host metrics means no
 * host advances either. Returning 0 declines the batch, and the engine
 * takes the same estimator fallback the per-prefix seam takes — the
 * decline route is pinned by the text batch parity tests. */
int native_sdk_appkit_measure_text_advances(uint64_t font_id, double size, const char *text, size_t text_len, float *advances) {
    (void)font_id;
    (void)size;
    (void)text;
    (void)text_len;
    (void)advances;
    return 0;
}

/* Mirror of the AppKit host's decoder: pure CoreGraphics/ImageIO with no
 * host state, so both engines decode identically. See appkit_host.h for
 * the pixel-format and return-value contract. */
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

static size_t NativeSdkOverflowSize(size_t buffer_len) {
    return buffer_len == SIZE_MAX ? SIZE_MAX : buffer_len + 1;
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
        if (opts->title && opts->title_len > 0) {
            alert.messageText = [[NSString alloc] initWithBytes:opts->title length:opts->title_len encoding:NSUTF8StringEncoding];
        }
        if (opts->message && opts->message_len > 0) {
            alert.informativeText = [[NSString alloc] initWithBytes:opts->message length:opts->message_len encoding:NSUTF8StringEncoding];
        }
        if (opts->informative_text && opts->informative_text_len > 0) {
            alert.informativeText = [[NSString alloc] initWithBytes:opts->informative_text length:opts->informative_text_len encoding:NSUTF8StringEncoding];
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
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
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
                [image setTemplate:YES];
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
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
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

int native_sdk_appkit_set_window_content_min_size(native_sdk_appkit_host_t *host, uint64_t window_id, double min_width, double min_height) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
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

void native_sdk_appkit_update_tray_title(native_sdk_appkit_host_t *host, const char *title, size_t title_len) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
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
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    if (object.statusItem) {
        [[NSStatusBar systemStatusBar] removeStatusItem:object.statusItem];
        object.statusItem = nil;
    }
}

/* Dock icon entry points, CEF engine: the Chromium shell is still a
 * macOS app with a Dock tile, so the dev-run icon path (including the
 * Debug-only masked render of raw image sources) applies here exactly
 * as under the system host. The rgba form copies the caller's
 * straight-alpha rows into a rep the image owns (the caller frees its
 * buffer on return); only the NSApp adoption needs the main queue. */
void native_sdk_appkit_set_dock_icon_rgba(native_sdk_appkit_host_t *host, const uint8_t *pixels, size_t width, size_t height) {
    (void)host;
    if (!pixels || width == 0 || height == 0) return;
    @autoreleasepool {
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
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp setApplicationIconImage:icon];
        });
    }
}

void native_sdk_appkit_set_dock_icon_file(native_sdk_appkit_host_t *host, const char *path, size_t path_len) {
    (void)host;
    if (!path || path_len == 0) return;
    @autoreleasepool {
        NSString *pathString = [[NSString alloc] initWithBytes:path length:path_len encoding:NSUTF8StringEncoding];
        if (pathString.length == 0) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSImage *icon = [[NSImage alloc] initWithContentsOfFile:pathString];
            if (!icon) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSApp setApplicationIconImage:icon];
            });
        });
    }
}

void native_sdk_appkit_set_tray_callback(native_sdk_appkit_host_t *host, native_sdk_appkit_tray_callback_t callback, void *context) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    object.trayCallback = callback;
    object.trayContext = context;
}

/* Native context menu, CEF engine: same NSMenu presentation as the
 * system-engine host, anchored to the window content view (gpu-surface
 * views are system-engine-only, so `label` resolves to the window). */
int native_sdk_appkit_show_context_menu(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, uint64_t token, const native_sdk_appkit_context_menu_item_t *items, size_t count) {
    NativeSdkChromiumHost *object = (__bridge NativeSdkChromiumHost *)host;
    NSWindow *window = object.windows[@(window_id)] ?: (window_id == 1 ? object.window : nil);
    NSView *view = window.contentView;
    if (!view || count == 0) return 0;

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    menu.autoenablesItems = NO;
    NativeSdkChromiumContextMenuTarget *target = [[NativeSdkChromiumContextMenuTarget alloc] init];
    for (size_t index = 0; index < count; index += 1) {
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

    NSString *eventLabel = label ? [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding] : @"";
    NSPoint location = NSMakePoint(x, view.isFlipped ? y : view.bounds.size.height - y);
    __weak NativeSdkChromiumHost *weakSelf = object;
    dispatch_async(dispatch_get_main_queue(), ^{
        NativeSdkChromiumHost *presentSelf = weakSelf;
        if (!presentSelf) return;
        [menu popUpMenuPositioningItem:nil atLocation:location inView:view];
        dispatch_async(dispatch_get_main_queue(), ^{
            NativeSdkChromiumHost *emitSelf = weakSelf;
            if (!emitSelf) return;
            const char *labelBytes = eventLabel.UTF8String ?: "";
            [emitSelf emitEvent:(native_sdk_appkit_event_t){
                .kind = NATIVE_SDK_APPKIT_EVENT_CONTEXT_MENU_ACTION,
                .window_id = window_id,
                .view_label = labelBytes,
                .view_label_len = [eventLabel lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
                .widget_id = token,
                .menu_item_id = target.selectedItemId,
            }];
        });
    });
    return 1;
}
