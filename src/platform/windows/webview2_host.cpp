#include <windows.h>
#include <shellapi.h>
#include <objbase.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <climits>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#if __has_include(<WebView2.h>) && __has_include(<wrl.h>)
#include <WebView2.h>
#include <wrl.h>
#define ZERO_NATIVE_HAS_WEBVIEW2 1
using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
#else
#define ZERO_NATIVE_HAS_WEBVIEW2 0
#endif

namespace {

enum EventKind {
    kStart = 0,
    kFrame = 1,
    kShutdown = 2,
    kResize = 3,
    kWindowFrame = 4,
    kShortcut = 5,
};

constexpr uint32_t kShortcutModifierPrimary = 1u << 0;
constexpr uint32_t kShortcutModifierCommand = 1u << 1;
constexpr uint32_t kShortcutModifierControl = 1u << 2;
constexpr uint32_t kShortcutModifierOption = 1u << 3;
constexpr uint32_t kShortcutModifierShift = 1u << 4;
constexpr size_t kMaxShortcuts = 64;

struct WindowsEvent {
    int kind;
    uint64_t window_id;
    double width;
    double height;
    double scale;
    double x;
    double y;
    int open;
    int focused;
    const char *label;
    size_t label_len;
    const char *title;
    size_t title_len;
    const char *shortcut_id;
    size_t shortcut_id_len;
    const char *shortcut_key;
    size_t shortcut_key_len;
    uint32_t shortcut_modifiers;
};

using EventCallback = void (*)(void *, const WindowsEvent *);
using BridgeCallback = void (*)(void *, uint64_t, const char *, size_t, const char *, size_t, const char *, size_t);

struct Window {
    uint64_t id = 1;
    HWND hwnd = nullptr;
    std::string label;
    std::string title;
    double x = 0;
    double y = 0;
    double width = 720;
    double height = 480;
};

struct ChildWebView {
    uint64_t window_id = 1;
    HWND hwnd = nullptr;
    std::string label;
    std::string url;
    double x = 0;
    double y = 0;
    double width = 0;
    double height = 0;
    double zoom = 1.0;
    int layer = 0;
    uint64_t creation_order = 0;
    bool transparent = false;
    bool bridge_enabled = false;
#if ZERO_NATIVE_HAS_WEBVIEW2
    ComPtr<ICoreWebView2Controller> controller;
    ComPtr<ICoreWebView2> webview;
#endif
};

struct Shortcut {
    std::string id;
    std::string key;
    uint32_t modifiers = 0;
};

struct HostLifetime {
    std::recursive_mutex mutex;
    bool alive = true;
};

struct Host {
    HINSTANCE instance = GetModuleHandleW(nullptr);
    std::string app_name;
    std::string window_title;
    std::string bundle_id;
    std::string icon_path;
    EventCallback callback = nullptr;
    void *callback_context = nullptr;
    BridgeCallback bridge_callback = nullptr;
    void *bridge_context = nullptr;
    bool running = false;
    std::map<uint64_t, Window> windows;
    std::map<std::string, ChildWebView> webviews;
    uint64_t next_webview_order = 1;
    std::vector<std::string> allowed_origins;
    std::vector<std::string> allowed_external_urls;
    std::vector<Shortcut> shortcuts;
    int external_link_action = 0;
    std::shared_ptr<HostLifetime> lifetime = std::make_shared<HostLifetime>();
};

static std::string slice(const char *bytes, size_t len) {
    return bytes && len > 0 ? std::string(bytes, len) : std::string();
}

static std::string jsonStringLiteral(const std::string &value) {
    static const char hex[] = "0123456789abcdef";
    std::string out;
    out.reserve(value.size() + 2);
    out.push_back('"');
    for (unsigned char ch : value) {
        switch (ch) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (ch < 0x20) {
                    out += "\\u00";
                    out.push_back(hex[(ch >> 4) & 0xf]);
                    out.push_back(hex[ch & 0xf]);
                } else {
                    out.push_back(static_cast<char>(ch));
                }
                break;
        }
    }
    out.push_back('"');
    return out;
}

static std::wstring widen(const std::string &value) {
    if (value.empty()) return std::wstring();
    int count = MultiByteToWideChar(CP_UTF8, 0, value.data(), (int)value.size(), nullptr, 0);
    std::wstring out((size_t)count, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, value.data(), (int)value.size(), out.data(), count);
    return out;
}

static std::string narrow(const std::wstring &value) {
    if (value.empty()) return std::string();
    int count = WideCharToMultiByte(CP_UTF8, 0, value.data(), (int)value.size(), nullptr, 0, nullptr, nullptr);
    std::string out((size_t)count, '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.data(), (int)value.size(), out.data(), count, nullptr, nullptr);
    return out;
}

static std::vector<std::string> parseNewlineList(const char *bytes, size_t len) {
    std::vector<std::string> result;
    if (!bytes || len == 0) return result;
    const char *start = bytes;
    const char *end = bytes + len;
    while (start < end) {
        const char *nl = static_cast<const char *>(memchr(start, '\n', (size_t)(end - start)));
        size_t seg_len = nl ? (size_t)(nl - start) : (size_t)(end - start);
        while (seg_len > 0 && (*start == ' ' || *start == '\t')) {
            ++start;
            --seg_len;
        }
        while (seg_len > 0 && (start[seg_len - 1] == ' ' || start[seg_len - 1] == '\t' || start[seg_len - 1] == '\r')) --seg_len;
        if (seg_len > 0) result.emplace_back(start, seg_len);
        start = nl ? nl + 1 : end;
    }
    return result;
}

static std::string originForUrl(const std::string &url) {
    if (url.empty() || url.rfind("about:", 0) == 0) return "zero://inline";
    size_t scheme_end = url.find("://");
    if (scheme_end == std::string::npos) return "zero://inline";
    if (url.compare(0, scheme_end, "file") == 0) return "file://local";
    size_t host_start = scheme_end + 3;
    size_t host_end = host_start;
    while (host_end < url.size() && url[host_end] != '/' && url[host_end] != '?' && url[host_end] != '#') ++host_end;
    if (host_end == host_start) return url.substr(0, scheme_end) + "://local";
    return url.substr(0, host_end);
}

static bool policyListMatches(const std::vector<std::string> &values, const std::string &url) {
    std::string origin = originForUrl(url);
    for (const std::string &value : values) {
        if (value == "*" || value == origin || value == url) return true;
        if (!value.empty() && value.back() == '*') {
            const std::string prefix = value.substr(0, value.size() - 1);
            if (url.rfind(prefix, 0) == 0 || origin.rfind(prefix, 0) == 0) return true;
        }
    }
    return false;
}

static size_t boundedLen(const char *text, size_t limit) {
    size_t len = 0;
    while (len < limit && text[len] != '\0') ++len;
    return len;
}

static void emit(Host *host, const Window &window, EventKind kind) {
    if (!host || !host->callback) return;
    RECT rect = {};
    if (window.hwnd) GetClientRect(window.hwnd, &rect);
    WindowsEvent event = {};
    event.kind = kind;
    event.window_id = window.id;
    event.width = rect.right > rect.left ? (double)(rect.right - rect.left) : window.width;
    event.height = rect.bottom > rect.top ? (double)(rect.bottom - rect.top) : window.height;
    event.scale = 1.0;
    event.x = window.x;
    event.y = window.y;
    event.open = window.hwnd != nullptr;
    event.focused = window.hwnd && GetFocus() == window.hwnd;
    event.label = window.label.c_str();
    event.label_len = window.label.size();
    event.title = window.title.c_str();
    event.title_len = window.title.size();
    host->callback(host->callback_context, &event);
}

static std::string shortcutKeyFromWParam(WPARAM wparam) {
    if (wparam >= 'A' && wparam <= 'Z') return std::string(1, static_cast<char>('a' + (wparam - 'A')));
    if (wparam >= '0' && wparam <= '9') return std::string(1, static_cast<char>(wparam));
    switch (wparam) {
        case VK_ESCAPE: return "escape";
        case VK_RETURN: return "enter";
        case VK_TAB: return "tab";
        case VK_SPACE: return "space";
        case VK_BACK: return "backspace";
        case VK_LEFT: return "arrowleft";
        case VK_RIGHT: return "arrowright";
        case VK_UP: return "arrowup";
        case VK_DOWN: return "arrowdown";
        case VK_OEM_PLUS: return "=";
        case VK_OEM_MINUS: return "-";
        case VK_OEM_COMMA: return ",";
        case VK_OEM_PERIOD: return ".";
        case VK_OEM_2: return "/";
        case VK_OEM_1: return ";";
        case VK_OEM_7: return "'";
        case VK_OEM_4: return "[";
        case VK_OEM_6: return "]";
        case VK_OEM_5: return "\\";
        case VK_OEM_3: return "`";
        default: return std::string();
    }
}

static bool keyDown(int virtual_key) {
    return (GetKeyState(virtual_key) & 0x8000) != 0;
}

static bool shortcutKeyCanUseImplicitShift(const std::string &key) {
    if (key.size() != 1) return false;
    char ch = key[0];
    return (ch >= '0' && ch <= '9') ||
        ch == '=' || ch == '-' || ch == ',' ||
        ch == '.' || ch == '/' || ch == ';' || ch == '\'' ||
        ch == '[' || ch == ']' || ch == '\\' || ch == '`';
}

static bool shortcutModifiersMatch(uint32_t shortcut_modifiers, bool allow_implicit_shift) {
    bool needs_control = (shortcut_modifiers & kShortcutModifierControl) != 0 ||
        (shortcut_modifiers & kShortcutModifierPrimary) != 0;
    bool needs_command = (shortcut_modifiers & kShortcutModifierCommand) != 0;
    bool needs_option = (shortcut_modifiers & kShortcutModifierOption) != 0;
    bool needs_shift = (shortcut_modifiers & kShortcutModifierShift) != 0;
    bool has_control = keyDown(VK_CONTROL);
    bool has_command = keyDown(VK_LWIN) || keyDown(VK_RWIN);
    bool has_option = keyDown(VK_MENU);
    bool has_shift = keyDown(VK_SHIFT);
    bool shift_matches = needs_shift ? has_shift : (!has_shift || allow_implicit_shift);
    return has_control == needs_control &&
        has_command == needs_command &&
        has_option == needs_option &&
        shift_matches;
}

static const Window *windowForId(Host *host, uint64_t window_id) {
    if (!host) return nullptr;
    auto found = host->windows.find(window_id);
    if (found == host->windows.end()) return nullptr;
    return &found->second;
}

static const Window *windowForHwnd(Host *host, HWND hwnd) {
    if (!host) return nullptr;
    for (auto &entry : host->windows) {
        if (entry.second.hwnd == hwnd) return &entry.second;
    }
    return nullptr;
}

static bool emitShortcutForWindow(Host *host, const Window *window, WPARAM wparam) {
    if (!host || host->shortcuts.empty()) return false;
    if (!window) return false;
    std::string key = shortcutKeyFromWParam(wparam);
    if (key.empty()) return false;
    bool uses_implicit_shift = keyDown(VK_SHIFT) && shortcutKeyCanUseImplicitShift(key);
    const int pass_count = uses_implicit_shift ? 2 : 1;
    for (int pass = 0; pass < pass_count; ++pass) {
        bool allow_implicit_shift = pass == 1;
        for (const Shortcut &shortcut : host->shortcuts) {
            if (shortcut.key != key) continue;
            if (!shortcutModifiersMatch(shortcut.modifiers, allow_implicit_shift)) continue;
            if (!host->callback) return true;
            WindowsEvent event = {};
            event.kind = kShortcut;
            event.window_id = window->id;
            event.shortcut_id = shortcut.id.c_str();
            event.shortcut_id_len = shortcut.id.size();
            event.shortcut_key = shortcut.key.c_str();
            event.shortcut_key_len = shortcut.key.size();
            event.shortcut_modifiers = shortcut.modifiers;
            host->callback(host->callback_context, &event);
            return true;
        }
    }
    return false;
}

static bool emitShortcutForHwnd(Host *host, HWND hwnd, WPARAM wparam) {
    return emitShortcutForWindow(host, windowForHwnd(host, hwnd), wparam);
}

static bool emitShortcutForWindowId(Host *host, uint64_t window_id, WPARAM wparam) {
    return emitShortcutForWindow(host, windowForId(host, window_id), wparam);
}

static std::string webViewKey(uint64_t window_id, const std::string &label) {
    return std::to_string(window_id) + ":" + label;
}

static int webViewCoord(double value) {
    return value > 0 ? (int)(value + 0.5) : 0;
}

static int webViewExtent(double value) {
    return value > 1 ? (int)(value + 0.5) : 1;
}

static bool validChildWebViewFrame(double x, double y, double width, double height) {
    return x >= 0 && y >= 0 && width > 0 && height > 0;
}

static void destroyChildWebViewsForWindow(Host *host, uint64_t window_id) {
    if (!host) return;
    for (auto it = host->webviews.begin(); it != host->webviews.end();) {
        if (it->second.window_id == window_id) {
#if ZERO_NATIVE_HAS_WEBVIEW2
            if (it->second.controller) it->second.controller->Close();
#endif
            if (it->second.hwnd) DestroyWindow(it->second.hwnd);
            it = host->webviews.erase(it);
        } else {
            ++it;
        }
    }
}

static void destroyAllWindows(Host *host) {
    if (!host) return;
    for (auto &entry : host->windows) {
        destroyChildWebViewsForWindow(host, entry.first);
        if (entry.second.hwnd) {
            DestroyWindow(entry.second.hwnd);
            entry.second.hwnd = nullptr;
        }
    }
}

#if ZERO_NATIVE_HAS_WEBVIEW2
using CreateEnvironmentFn = HRESULT (STDAPICALLTYPE *)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions *, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *);

static const wchar_t *zeroNativeBridgeScript() {
    return LR"ZN((function(){
	if(window.zero&&window.zero.invoke&&window.zero.on&&window.zero._emit){return;}
	var pending=new Map();
	var listeners=new Map();
	var nextId=1;
	function post(message){
	if(window.chrome&&window.chrome.webview&&window.chrome.webview.postMessage){window.chrome.webview.postMessage(message);return;}
	throw new Error('zero-native bridge transport is unavailable');
	}
	function complete(response){
	var id=response&&response.id!=null?String(response.id):'';
	var entry=pending.get(id);
	if(!entry){return;}
	pending.delete(id);
	if(response.ok){entry.resolve(response.result===undefined?null:response.result);return;}
	var errorInfo=response.error||{};
	var error=new Error(errorInfo.message||'Native command failed');
	error.code=errorInfo.code||'internal_error';
	entry.reject(error);
	}
	function invoke(command,payload){
	if(typeof command!=='string'||command.length===0){return Promise.reject(new TypeError('command must be a non-empty string'));}
	var id=String(nextId++);
	var envelope=JSON.stringify({id:id,command:command,payload:payload===undefined?null:payload});
	return new Promise(function(resolve,reject){
	pending.set(id,{resolve:resolve,reject:reject});
	try{post(envelope);}catch(error){pending.delete(id);reject(error);}
	});
	}
	function selector(value){return typeof value==='number'?{id:value}:{label:String(value)};}
	function ensureString(value,name){if(typeof value!=='string'||value.length===0){throw new TypeError(name+' must be a non-empty string');}return value;}
	function ensureText(value,name){if(typeof value!=='string'){throw new TypeError(name+' must be a string');}return value;}
	function ensureNumber(value,name){if(typeof value!=='number'||!isFinite(value)){throw new TypeError(name+' must be a finite number');}return value;}
	function commandPayload(value){if(typeof value==='string'){return {name:ensureString(value,'command')};}value=value||{};var name=value.name!=null?value.name:value.id;return {name:ensureString(name,'command')};}
	function validateWebViewSelector(options){if(options.label!=null){ensureString(options.label,'label');}if(options.windowId!=null&&(typeof options.windowId!=='number'||!isFinite(options.windowId)||options.windowId<0||Math.floor(options.windowId)!==options.windowId)){throw new TypeError('windowId must be a non-negative integer');}}
	function framePayload(options){options=options||{};validateWebViewSelector(options);var frame=options.frame||options;return {label:options.label,windowId:options.windowId,url:options.url,frame:{x:frame.x==null?0:ensureNumber(frame.x,'frame.x'),y:frame.y==null?0:ensureNumber(frame.y,'frame.y'),width:ensureNumber(frame.width,'frame.width'),height:ensureNumber(frame.height,'frame.height')}};}
	function createPayload(options){options=options||{};ensureString(options.url,'url');var payload=framePayload(options);if(options.layer!=null){payload.layer=ensureNumber(options.layer,'layer');}if(options.transparent!=null){payload.transparent=!!options.transparent;}if(options.bridge!=null){payload.bridge=!!options.bridge;}return payload;}
	function navigatePayload(options){options=options||{};validateWebViewSelector(options);ensureString(options.url,'url');return {label:options.label,windowId:options.windowId,url:options.url};}
	function closePayload(options){options=options||{};validateWebViewSelector(options);return {label:options.label,windowId:options.windowId};}
	function webviewHandle(info){return Object.freeze(Object.assign({},info,{setFrame:function(frame){return webviews.setFrame({label:info.label,windowId:info.windowId,frame:frame});},navigate:function(url){return webviews.navigate({label:info.label,windowId:info.windowId,url:url});},setZoom:function(zoom){return webviews.setZoom({label:info.label,windowId:info.windowId,zoom:zoom});},setLayer:function(layer){return webviews.setLayer({label:info.label,windowId:info.windowId,layer:layer});},close:function(){return webviews.close({label:info.label,windowId:info.windowId});}}));}
	function validateViewSelector(options){options=options||{};ensureString(options.label,'label');if(options.windowId!=null&&(typeof options.windowId!=='number'||!isFinite(options.windowId)||options.windowId<0||Math.floor(options.windowId)!==options.windowId)){throw new TypeError('windowId must be a non-negative integer');}}
	function optionalFramePayload(options){var frame=options.frame||((options.x!=null||options.y!=null||options.width!=null||options.height!=null)?options:null);if(!frame){return null;}return {x:frame.x==null?0:ensureNumber(frame.x,'frame.x'),y:frame.y==null?0:ensureNumber(frame.y,'frame.y'),width:ensureNumber(frame.width,'frame.width'),height:ensureNumber(frame.height,'frame.height')};}
	function viewCreatePayload(options){options=options||{};validateViewSelector(options);ensureString(options.kind,'kind');var payload={label:options.label,kind:options.kind,windowId:options.windowId};var frame=optionalFramePayload(options);if(frame){payload.frame=frame;}if(options.parent!=null){payload.parent=ensureString(options.parent,'parent');}if(options.role!=null){payload.role=ensureString(options.role,'role');}if(options.text!=null){payload.text=ensureString(options.text,'text');}if(options.url!=null){payload.url=ensureString(options.url,'url');}if(options.layer!=null){payload.layer=ensureNumber(options.layer,'layer');}if(options.visible!=null){payload.visible=!!options.visible;}if(options.enabled!=null){payload.enabled=!!options.enabled;}if(options.transparent!=null){payload.transparent=!!options.transparent;}if(options.bridge!=null){payload.bridge=!!options.bridge;}return payload;}
	function viewPatchPayload(options){options=options||{};validateViewSelector(options);var payload={label:options.label,windowId:options.windowId};var frame=optionalFramePayload(options);if(frame){payload.frame=frame;}if(options.layer!=null){payload.layer=ensureNumber(options.layer,'layer');}if(options.visible!=null){payload.visible=!!options.visible;}if(options.enabled!=null){payload.enabled=!!options.enabled;}if(options.role!=null){payload.role=ensureString(options.role,'role');}if(options.text!=null){payload.text=ensureString(options.text,'text');}if(options.url!=null){payload.url=ensureString(options.url,'url');}return payload;}
	function viewFramePayload(options){options=options||{};validateViewSelector(options);var frame=options.frame||options;return {label:options.label,windowId:options.windowId,frame:{x:frame.x==null?0:ensureNumber(frame.x,'frame.x'),y:frame.y==null?0:ensureNumber(frame.y,'frame.y'),width:ensureNumber(frame.width,'frame.width'),height:ensureNumber(frame.height,'frame.height')}};}
	function viewVisiblePayload(options){options=options||{};validateViewSelector(options);if(options.visible==null){throw new TypeError('visible is required');}return {label:options.label,windowId:options.windowId,visible:!!options.visible};}
	function viewHandle(info){return Object.freeze(Object.assign({},info,{update:function(patch){return views.update(Object.assign({},patch||{},{label:info.label,windowId:info.windowId}));},setFrame:function(frame){return views.setFrame({label:info.label,windowId:info.windowId,frame:frame});},setVisible:function(visible){return views.setVisible({label:info.label,windowId:info.windowId,visible:visible});},focus:function(){return views.focus({label:info.label,windowId:info.windowId});},close:function(){return views.close({label:info.label,windowId:info.windowId});}}));}
	function on(name,callback){if(typeof callback!=='function'){throw new TypeError('callback must be a function');}var set=listeners.get(name);if(!set){set=new Set();listeners.set(name,set);}set.add(callback);return function(){off(name,callback);};}
	function off(name,callback){var set=listeners.get(name);if(set){set.delete(callback);if(set.size===0){listeners.delete(name);}}}
	function emit(name,detail){var set=listeners.get(name);if(set){Array.from(set).forEach(function(callback){callback(detail);});}window.dispatchEvent(new CustomEvent('zero-native:'+name,{detail:detail}));}
	var commands=Object.freeze({
	invoke:function(value){return invoke('zero-native.command.invoke',commandPayload(value));}
	});
	var windows=Object.freeze({
	create:function(options){return invoke('zero-native.window.create',options||{});},
	list:function(){return invoke('zero-native.window.list',{});},
	focus:function(value){return invoke('zero-native.window.focus',selector(value));},
	close:function(value){return invoke('zero-native.window.close',selector(value));}
	});
	var dialogs=Object.freeze({
	openFile:function(options){return invoke('zero-native.dialog.openFile',options||{});},
	saveFile:function(options){return invoke('zero-native.dialog.saveFile',options||{});},
	showMessage:function(options){return invoke('zero-native.dialog.showMessage',options||{});}
	});
	function clipboardReadPayload(value){value=value||{};return {mimeType:ensureString(value.mimeType||value.type||'text/plain','mimeType')};}
	function clipboardWritePayload(value){if(typeof value==='string'){return {mimeType:'text/plain',data:value};}value=value||{};var data=value.data!=null?value.data:(value.text!=null?value.text:value.value);return {mimeType:ensureString(value.mimeType||value.type||'text/plain','mimeType'),data:ensureText(data,'data')};}
	var clipboard=Object.freeze({
	readText:function(){return invoke('zero-native.clipboard.readText',{});},
	writeText:function(value){var text=typeof value==='string'?value:(value||{}).text;return invoke('zero-native.clipboard.writeText',{text:ensureText(text,'text')});},
	read:function(value){return invoke('zero-native.clipboard.read',clipboardReadPayload(value));},
	write:function(value){return invoke('zero-native.clipboard.write',clipboardWritePayload(value));}
	});
	var os=Object.freeze({
	openUrl:function(value){var options=typeof value==='string'?{url:value}:(value||{});return invoke('zero-native.os.openUrl',{url:ensureString(options.url,'url')});},
	showNotification:function(value){var options=typeof value==='string'?{title:value}:(value||{});var payload={title:ensureString(options.title,'title')};if(options.subtitle!=null){payload.subtitle=ensureString(options.subtitle,'subtitle');}if(options.body!=null){payload.body=ensureString(options.body,'body');}return invoke('zero-native.os.showNotification',payload);},
	revealPath:function(value){var options=typeof value==='string'?{path:value}:(value||{});return invoke('zero-native.os.revealPath',{path:ensureString(options.path,'path')});},
	addRecentDocument:function(value){var options=typeof value==='string'?{path:value}:(value||{});return invoke('zero-native.os.addRecentDocument',{path:ensureString(options.path,'path')});},
	clearRecentDocuments:function(){return invoke('zero-native.os.clearRecentDocuments',{});}
	});
	function credentialPayload(value){value=value||{};return {service:ensureString(value.service,'service'),account:ensureString(value.account,'account')};}
	function credentialSetPayload(value){var payload=credentialPayload(value);payload.secret=ensureString(value.secret!=null?value.secret:value.value,'secret');return payload;}
	var credentials=Object.freeze({
	set:function(value){return invoke('zero-native.credentials.set',credentialSetPayload(value));},
	get:function(value){return invoke('zero-native.credentials.get',credentialPayload(value));},
	delete:function(value){return invoke('zero-native.credentials.delete',credentialPayload(value));}
	});
	function zoomPayload(options){options=options||{};validateWebViewSelector(options);return {label:options.label,windowId:options.windowId,zoom:ensureNumber(options.zoom,'zoom')};}
	function layerPayload(options){options=options||{};validateWebViewSelector(options);return {label:options.label,windowId:options.windowId,layer:ensureNumber(options.layer,'layer')};}
	var webviews=Object.freeze({
	create:function(options){return invoke('zero-native.webview.create',createPayload(options)).then(webviewHandle);},
	list:function(){return invoke('zero-native.webview.list',{});},
	setFrame:function(options){return invoke('zero-native.webview.setFrame',framePayload(options));},
	navigate:function(options){return invoke('zero-native.webview.navigate',navigatePayload(options));},
	setZoom:function(options){return invoke('zero-native.webview.setZoom',zoomPayload(options));},
	setLayer:function(options){return invoke('zero-native.webview.setLayer',layerPayload(options));},
	close:function(options){return invoke('zero-native.webview.close',closePayload(options));}
	});
	var views=Object.freeze({
	create:function(options){return invoke('zero-native.view.create',viewCreatePayload(options)).then(viewHandle);},
	list:function(){return invoke('zero-native.view.list',{});},
	update:function(options){return invoke('zero-native.view.update',viewPatchPayload(options)).then(viewHandle);},
	setFrame:function(options){return invoke('zero-native.view.setFrame',viewFramePayload(options)).then(viewHandle);},
	setVisible:function(options){return invoke('zero-native.view.setVisible',viewVisiblePayload(options)).then(viewHandle);},
	focus:function(options){options=options||{};validateViewSelector(options);return invoke('zero-native.view.focus',{label:options.label,windowId:options.windowId}).then(viewHandle);},
	close:function(options){options=options||{};validateViewSelector(options);return invoke('zero-native.view.close',{label:options.label,windowId:options.windowId});}
	});
	try{Object.defineProperty(window,'zero',{value:Object.freeze({invoke:invoke,on:on,off:off,commands:commands,windows:windows,dialogs:dialogs,clipboard:clipboard,os:os,credentials:credentials,webviews:webviews,views:views,_complete:complete,_emit:emit}),configurable:false});}catch(error){}
	})();
	)ZN";
}

static RECT webViewRect(const ChildWebView &webview) {
    RECT rect = {};
    rect.left = 0;
    rect.top = 0;
    rect.right = webViewExtent(webview.width);
    rect.bottom = webViewExtent(webview.height);
    return rect;
}

static CreateEnvironmentFn webView2Factory() {
    static HMODULE loader = LoadLibraryW(L"WebView2Loader.dll");
    if (!loader) return nullptr;
    return reinterpret_cast<CreateEnvironmentFn>(GetProcAddress(loader, "CreateCoreWebView2EnvironmentWithOptions"));
}

static void cleanupPendingChildWebView(Host *host, const std::string &key) {
    if (!host) return;
    auto found = host->webviews.find(key);
    if (found == host->webviews.end()) return;
    if (found->second.controller) found->second.controller->Close();
    if (found->second.hwnd) DestroyWindow(found->second.hwnd);
    host->webviews.erase(found);
}

static bool createChildWebView(Host *host, const std::string &key) {
    auto factory = webView2Factory();
    if (!factory) return false;
    auto found = host->webviews.find(key);
    if (found == host->webviews.end() || !found->second.hwnd) return false;
    HWND parent = found->second.hwnd;
    std::weak_ptr<HostLifetime> lifetime = host->lifetime;
    HRESULT hr = factory(nullptr, nullptr, nullptr, Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
        [host, key, parent, lifetime](HRESULT result, ICoreWebView2Environment *environment) -> HRESULT {
            auto token = lifetime.lock();
            if (!token) return S_OK;
            std::lock_guard<std::recursive_mutex> guard(token->mutex);
            if (!token->alive) return S_OK;
            auto found = host->webviews.find(key);
            if (found == host->webviews.end() || found->second.hwnd != parent || !IsWindow(parent)) return S_OK;
            if (FAILED(result) || !environment) {
                cleanupPendingChildWebView(host, key);
                return result;
            }
            return environment->CreateCoreWebView2Controller(parent, Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                [host, key, lifetime](HRESULT controller_result, ICoreWebView2Controller *controller) -> HRESULT {
                    auto token = lifetime.lock();
                    if (!token) {
                        if (controller) controller->Close();
                        return S_OK;
                    }
                    std::lock_guard<std::recursive_mutex> guard(token->mutex);
                    if (!token->alive) {
                        if (controller) controller->Close();
                        return S_OK;
                    }
                    if (FAILED(controller_result) || !controller) {
                        cleanupPendingChildWebView(host, key);
                        return controller_result;
                    }
                    auto found = host->webviews.find(key);
                    if (found == host->webviews.end()) {
                        controller->Close();
                        return S_OK;
                    }
                    found->second.controller = controller;
                    controller->get_CoreWebView2(&found->second.webview);
                    RECT bounds = webViewRect(found->second);
                    controller->put_Bounds(bounds);
                    controller->put_ZoomFactor(found->second.zoom);
                    controller->put_IsVisible(TRUE);
                    if (found->second.webview) {
                        if (found->second.bridge_enabled) {
                            found->second.webview->AddScriptToExecuteOnDocumentCreated(zeroNativeBridgeScript(), nullptr);
                            EventRegistrationToken bridge_token = {};
                            uint64_t bridge_window_id = found->second.window_id;
                            std::string bridge_label = found->second.label;
                            found->second.webview->add_WebMessageReceived(Callback<ICoreWebView2WebMessageReceivedEventHandler>(
                                [host, bridge_window_id, bridge_label, lifetime](ICoreWebView2 *, ICoreWebView2WebMessageReceivedEventArgs *args) -> HRESULT {
                                    auto token = lifetime.lock();
                                    if (!token) return S_OK;
                                    std::lock_guard<std::recursive_mutex> guard(token->mutex);
                                    if (!token->alive || !args || !host->bridge_callback) return S_OK;

                                    LPWSTR message_bytes = nullptr;
                                    if (FAILED(args->TryGetWebMessageAsString(&message_bytes)) || !message_bytes) return S_OK;
                                    std::wstring message_wide(message_bytes);
                                    CoTaskMemFree(message_bytes);
                                    std::string message = narrow(message_wide);

                                    std::string origin = "zero://inline";
                                    LPWSTR source_bytes = nullptr;
                                    if (SUCCEEDED(args->get_Source(&source_bytes)) && source_bytes) {
                                        std::wstring source_wide(source_bytes);
                                        CoTaskMemFree(source_bytes);
                                        origin = originForUrl(narrow(source_wide));
                                    }

                                    host->bridge_callback(
                                        host->bridge_context,
                                        bridge_window_id,
                                        bridge_label.c_str(),
                                        bridge_label.size(),
                                        message.c_str(),
                                        message.size(),
                                        origin.c_str(),
                                        origin.size());
                                    return S_OK;
                                }).Get(), &bridge_token);
                        }
                        EventRegistrationToken accelerator_token = {};
                        uint64_t accelerator_window_id = found->second.window_id;
                        found->second.controller->add_AcceleratorKeyPressed(Callback<ICoreWebView2AcceleratorKeyPressedEventHandler>(
                            [host, accelerator_window_id, lifetime](ICoreWebView2Controller *, ICoreWebView2AcceleratorKeyPressedEventArgs *args) -> HRESULT {
                                auto token = lifetime.lock();
                                if (!token) return S_OK;
                                std::lock_guard<std::recursive_mutex> guard(token->mutex);
                                if (!token->alive || !args) return S_OK;
                                COREWEBVIEW2_KEY_EVENT_KIND kind = COREWEBVIEW2_KEY_EVENT_KIND_KEY_DOWN;
                                if (FAILED(args->get_KeyEventKind(&kind))) return S_OK;
                                if (kind != COREWEBVIEW2_KEY_EVENT_KIND_KEY_DOWN && kind != COREWEBVIEW2_KEY_EVENT_KIND_SYSTEM_KEY_DOWN) return S_OK;
                                UINT virtual_key = 0;
                                if (FAILED(args->get_VirtualKey(&virtual_key))) return S_OK;
                                if (emitShortcutForWindowId(host, accelerator_window_id, virtual_key)) {
                                    args->put_Handled(TRUE);
                                }
                                return S_OK;
                            }).Get(), &accelerator_token);

                        EventRegistrationToken token = {};
                        found->second.webview->add_NavigationStarting(Callback<ICoreWebView2NavigationStartingEventHandler>(
                            [host, lifetime](ICoreWebView2 *, ICoreWebView2NavigationStartingEventArgs *args) -> HRESULT {
                                auto token = lifetime.lock();
                                if (!token) return S_OK;
                                std::lock_guard<std::recursive_mutex> guard(token->mutex);
                                if (!token->alive) return S_OK;
                                LPWSTR uri_bytes = nullptr;
                                if (!args || FAILED(args->get_Uri(&uri_bytes))) return S_OK;
                                std::wstring uri_wide = uri_bytes ? std::wstring(uri_bytes) : std::wstring();
                                if (uri_bytes) CoTaskMemFree(uri_bytes);
                                std::string uri = narrow(uri_wide);
                                if (uri.empty() || uri.rfind("about:", 0) == 0 || policyListMatches(host->allowed_origins, uri)) return S_OK;
                                if (host->external_link_action == 1 && policyListMatches(host->allowed_external_urls, uri)) {
                                    ShellExecuteW(nullptr, L"open", uri_wide.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
                                }
                                args->put_Cancel(TRUE);
                                return S_OK;
                            }).Get(), &token);
                        std::wstring latest_url = widen(found->second.url);
                        if (!latest_url.empty()) found->second.webview->Navigate(latest_url.c_str());
                    }
                    return S_OK;
                }).Get());
        }).Get());
    return SUCCEEDED(hr);
}
#endif

static void applyChildWebViewLayer(Host *host, uint64_t window_id, const std::string &label) {
    if (!host) return;
    auto found = host->webviews.find(webViewKey(window_id, label));
    if (found == host->webviews.end() || !found->second.hwnd) return;
    HWND insert_after = HWND_TOP;
    bool found_above = false;
    int best_layer = INT_MAX;
    uint64_t best_order = UINT64_MAX;
    for (auto &entry : host->webviews) {
        const ChildWebView &candidate = entry.second;
        if (candidate.window_id != window_id || candidate.label == label || !candidate.hwnd) continue;
        const bool candidate_above = candidate.layer > found->second.layer ||
            (candidate.layer == found->second.layer && candidate.creation_order > found->second.creation_order);
        if (!candidate_above) continue;
        if (!found_above ||
            candidate.layer < best_layer ||
            (candidate.layer == best_layer && candidate.creation_order < best_order)) {
            insert_after = candidate.hwnd;
            found_above = true;
            best_layer = candidate.layer;
            best_order = candidate.creation_order;
        }
    }
    SetWindowPos(found->second.hwnd, insert_after, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

static Host *hostFromWindow(HWND hwnd) {
    return reinterpret_cast<Host *>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
}

static LRESULT CALLBACK windowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_NCCREATE) {
        auto *create = reinterpret_cast<CREATESTRUCTW *>(lparam);
        auto *host = reinterpret_cast<Host *>(create->lpCreateParams);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(host));
    }
    Host *host = hostFromWindow(hwnd);
    switch (message) {
        case WM_KEYDOWN:
        case WM_SYSKEYDOWN:
            if (host && emitShortcutForHwnd(host, hwnd, wparam)) return 0;
            break;
        case WM_SIZE:
            if (host) {
                for (auto &entry : host->windows) {
                    if (entry.second.hwnd == hwnd) emit(host, entry.second, kResize);
                }
            }
            return 0;
        case WM_SETFOCUS:
        case WM_KILLFOCUS:
        case WM_MOVE:
            if (host) {
                for (auto &entry : host->windows) {
                    if (entry.second.hwnd == hwnd) emit(host, entry.second, kWindowFrame);
                }
            }
            return 0;
        case WM_TIMER:
            if (host) {
                for (auto &entry : host->windows) emit(host, entry.second, kFrame);
            }
            return 0;
        case WM_CLOSE:
            DestroyWindow(hwnd);
            return 0;
        case WM_DESTROY:
            if (host) {
                for (auto &entry : host->windows) {
                    if (entry.second.hwnd == hwnd) {
                        destroyChildWebViewsForWindow(host, entry.first);
                        entry.second.hwnd = nullptr;
                        emit(host, entry.second, kWindowFrame);
                    }
                }
                bool any_open = false;
                for (auto &entry : host->windows) any_open = any_open || entry.second.hwnd;
                if (!any_open) PostQuitMessage(0);
            }
            return 0;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

static ATOM registerClass(Host *host) {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = windowProc;
    wc.hInstance = host->instance;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    wc.lpszClassName = L"ZeroNativeWindowsHost";
    return RegisterClassExW(&wc);
}

static bool createNativeWindow(Host *host, Window &window) {
    registerClass(host);
    std::wstring title = widen(window.title.empty() ? host->window_title : window.title);
    HWND hwnd = CreateWindowExW(
        0,
        L"ZeroNativeWindowsHost",
        title.c_str(),
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        (int)window.width,
        (int)window.height,
        nullptr,
        nullptr,
        host->instance,
        host);
    if (!hwnd) return false;
    window.hwnd = hwnd;
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    SetTimer(hwnd, 1, 16, nullptr);
    return true;
}

} // namespace

extern "C" {

void zero_native_windows_load_window_webview(Host *host, uint64_t window_id, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback);
void zero_native_windows_bridge_respond_window(Host *host, uint64_t window_id, const char *response, size_t response_len);

Host *zero_native_windows_create(const char *app_name, size_t app_name_len, const char *window_title, size_t window_title_len, const char *bundle_id, size_t bundle_id_len, const char *icon_path, size_t icon_path_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame) {
    (void)restore_frame;
    Host *host = new Host();
    host->app_name = slice(app_name, app_name_len);
    host->window_title = slice(window_title, window_title_len);
    host->bundle_id = slice(bundle_id, bundle_id_len);
    host->icon_path = slice(icon_path, icon_path_len);
    Window window;
    window.id = 1;
    window.label = slice(window_label, window_label_len);
    window.title = host->window_title.empty() ? host->app_name : host->window_title;
    window.x = x;
    window.y = y;
    window.width = width;
    window.height = height;
    host->windows[window.id] = window;
    return host;
}

void zero_native_windows_destroy(Host *host) {
    if (!host) return;
    std::shared_ptr<HostLifetime> lifetime = host->lifetime;
    std::lock_guard<std::recursive_mutex> guard(lifetime->mutex);
    lifetime->alive = false;
    destroyAllWindows(host);
    delete host;
}

void zero_native_windows_run(Host *host, EventCallback callback, void *context) {
    if (!host) return;
    host->callback = callback;
    host->callback_context = context;
    host->running = true;
    if (!host->windows.empty()) createNativeWindow(host, host->windows.begin()->second);
    WindowsEvent start = {};
    start.kind = kStart;
    start.window_id = 1;
    callback(context, &start);
    for (auto &entry : host->windows) {
        emit(host, entry.second, kResize);
        emit(host, entry.second, kWindowFrame);
    }
    MSG message = {};
    while (host->running && GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    WindowsEvent shutdown = {};
    shutdown.kind = kShutdown;
    shutdown.window_id = 1;
    callback(context, &shutdown);
}

void zero_native_windows_stop(Host *host) {
    if (!host) return;
    host->running = false;
    PostQuitMessage(0);
}

void zero_native_windows_load_webview(Host *host, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback) {
    zero_native_windows_load_window_webview(host, 1, source, source_len, source_kind, asset_root, asset_root_len, asset_entry, asset_entry_len, asset_origin, asset_origin_len, spa_fallback);
}

void zero_native_windows_load_window_webview(Host *host, uint64_t window_id, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback) {
    (void)source;
    (void)source_len;
    (void)source_kind;
    (void)asset_root;
    (void)asset_root_len;
    (void)asset_entry;
    (void)asset_entry_len;
    (void)asset_origin;
    (void)asset_origin_len;
    (void)spa_fallback;
    if (!host) return;
    auto found = host->windows.find(window_id);
    if (found != host->windows.end()) emit(host, found->second, kWindowFrame);
}

void zero_native_windows_set_bridge_callback(Host *host, BridgeCallback callback, void *context) {
    if (!host) return;
    host->bridge_callback = callback;
    host->bridge_context = context;
}

void zero_native_windows_bridge_respond(Host *host, const char *response, size_t response_len) {
    zero_native_windows_bridge_respond_window(host, 1, response, response_len);
}

void zero_native_windows_bridge_respond_window(Host *host, uint64_t window_id, const char *response, size_t response_len) {
    (void)host;
    (void)window_id;
    (void)response;
    (void)response_len;
}

void zero_native_windows_bridge_respond_webview(Host *host, uint64_t window_id, const char *webview_label, size_t webview_label_len, const char *response, size_t response_len) {
#if ZERO_NATIVE_HAS_WEBVIEW2
    if (!host) return;
    std::string label = slice(webview_label, webview_label_len);
    auto found = host->webviews.find(webViewKey(window_id, label));
    if (found == host->webviews.end() || !found->second.webview) return;
    std::string response_string = response && response_len > 0 ? slice(response, response_len) : std::string("{}");
    std::string script = "window.zero&&window.zero._complete(" + response_string + ");";
    std::wstring script_wide = widen(script);
    found->second.webview->ExecuteScript(script_wide.c_str(), nullptr);
#else
    (void)host;
    (void)window_id;
    (void)webview_label;
    (void)webview_label_len;
    (void)response;
    (void)response_len;
#endif
}

void zero_native_windows_emit_window_event(Host *host, uint64_t window_id, const char *name, size_t name_len, const char *detail_json, size_t detail_json_len) {
#if ZERO_NATIVE_HAS_WEBVIEW2
    if (!host) return;
    std::string event_name = slice(name, name_len);
    if (event_name.empty()) return;
    std::string detail = detail_json && detail_json_len > 0 ? slice(detail_json, detail_json_len) : std::string("null");
    std::string script = "(function(){var name=" + jsonStringLiteral(event_name) + ";var detail=" + detail + ";if(window.zero&&window.zero._emit){window.zero._emit(name,detail);return;}window.dispatchEvent(new CustomEvent('zero-native:'+name,{detail:detail}));})();";
    std::wstring script_wide = widen(script);
    for (auto &entry : host->webviews) {
        ChildWebView &webview = entry.second;
        if (webview.window_id != window_id || !webview.bridge_enabled || !webview.webview) continue;
        webview.webview->ExecuteScript(script_wide.c_str(), nullptr);
    }
#else
    (void)host;
    (void)window_id;
    (void)name;
    (void)name_len;
    (void)detail_json;
    (void)detail_json_len;
#endif
}

void zero_native_windows_set_security_policy(Host *host, const char *allowed_origins, size_t allowed_origins_len, const char *external_urls, size_t external_urls_len, int external_action) {
    if (!host) return;
    host->allowed_origins = parseNewlineList(allowed_origins, allowed_origins_len);
    host->allowed_external_urls = parseNewlineList(external_urls, external_urls_len);
    host->external_link_action = external_action;
}

void zero_native_windows_set_shortcuts(Host *host, const char *const *ids, const size_t *id_lens, const char *const *keys, const size_t *key_lens, const uint32_t *modifiers, size_t count) {
    if (!host) return;
    host->shortcuts.clear();
    if (!ids || !id_lens || !keys || !key_lens || !modifiers) return;
    const size_t limit = count < kMaxShortcuts ? count : kMaxShortcuts;
    for (size_t i = 0; i < limit; ++i) {
        if (!ids[i] || !keys[i] || id_lens[i] == 0 || key_lens[i] == 0) continue;
        Shortcut shortcut;
        shortcut.id = slice(ids[i], id_lens[i]);
        shortcut.key = slice(keys[i], key_lens[i]);
        for (char &ch : shortcut.key) {
            if (ch >= 'A' && ch <= 'Z') ch = static_cast<char>(ch - 'A' + 'a');
        }
        shortcut.modifiers = modifiers[i];
        host->shortcuts.push_back(shortcut);
    }
}

int zero_native_windows_create_window(Host *host, uint64_t window_id, const char *window_title, size_t window_title_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame) {
    (void)restore_frame;
    if (!host || host->windows.find(window_id) != host->windows.end()) return 0;
    Window window;
    window.id = window_id;
    window.title = slice(window_title, window_title_len);
    window.label = slice(window_label, window_label_len);
    window.x = x;
    window.y = y;
    window.width = width;
    window.height = height;
    bool ok = createNativeWindow(host, window);
    if (!ok) return 0;
    host->windows[window_id] = window;
    return 1;
}

int zero_native_windows_focus_window(Host *host, uint64_t window_id) {
    if (!host) return 0;
    auto found = host->windows.find(window_id);
    if (found == host->windows.end() || !found->second.hwnd) return 0;
    SetForegroundWindow(found->second.hwnd);
    SetFocus(found->second.hwnd);
    return 1;
}

int zero_native_windows_close_window(Host *host, uint64_t window_id) {
    if (!host) return 0;
    auto found = host->windows.find(window_id);
    if (found == host->windows.end() || !found->second.hwnd) return 0;
    destroyChildWebViewsForWindow(host, window_id);
    DestroyWindow(found->second.hwnd);
    return 1;
}

int zero_native_windows_create_webview(Host *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len, double x, double y, double width, double height, int layer, int transparent, int bridge_enabled) {
#if !ZERO_NATIVE_HAS_WEBVIEW2
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    (void)url;
    (void)url_len;
    (void)x;
    (void)y;
    (void)width;
    (void)height;
    (void)layer;
    (void)transparent;
    (void)bridge_enabled;
    return 0;
#else
    if (!host || label_len == 0 || url_len == 0 || !validChildWebViewFrame(x, y, width, height)) return 0;
    auto window = host->windows.find(window_id);
    if (window == host->windows.end() || !window->second.hwnd) return 0;
    std::string label_string = slice(label, label_len);
    std::string key = webViewKey(window_id, label_string);
    if (host->webviews.find(key) != host->webviews.end()) return 0;

    std::string url_string = slice(url, url_len);
    HWND hwnd = CreateWindowExW(
        0,
        L"STATIC",
        L"",
        WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
        webViewCoord(x),
        webViewCoord(y),
        webViewExtent(width),
        webViewExtent(height),
        window->second.hwnd,
        nullptr,
        host->instance,
        nullptr);
    if (!hwnd) return 0;

    ChildWebView webview;
    webview.window_id = window_id;
    webview.hwnd = hwnd;
    webview.label = label_string;
    webview.url = url_string;
    webview.x = x;
    webview.y = y;
    webview.width = width;
    webview.height = height;
    webview.layer = layer;
    webview.creation_order = host->next_webview_order++;
    webview.transparent = transparent != 0;
    webview.bridge_enabled = bridge_enabled != 0;
    host->webviews[key] = webview;
    applyChildWebViewLayer(host, window_id, label_string);
    if (!createChildWebView(host, key)) {
        DestroyWindow(hwnd);
        host->webviews.erase(key);
        return 0;
    }
    return 1;
#endif
}

int zero_native_windows_set_webview_frame(Host *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height) {
    if (!host || label_len == 0 || !validChildWebViewFrame(x, y, width, height)) return 0;
    if (slice(label, label_len) == "main") return 1;
    auto found = host->webviews.find(webViewKey(window_id, slice(label, label_len)));
    if (found == host->webviews.end() || !found->second.hwnd) return 0;
    found->second.x = x;
    found->second.y = y;
    found->second.width = width;
    found->second.height = height;
    MoveWindow(found->second.hwnd, webViewCoord(x), webViewCoord(y), webViewExtent(width), webViewExtent(height), TRUE);
#if ZERO_NATIVE_HAS_WEBVIEW2
    if (found->second.controller) {
        RECT bounds = webViewRect(found->second);
        found->second.controller->put_Bounds(bounds);
    }
#endif
    return 1;
}

int zero_native_windows_navigate_webview(Host *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len) {
#if !ZERO_NATIVE_HAS_WEBVIEW2
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    (void)url;
    (void)url_len;
    return 0;
#else
    if (!host || label_len == 0 || url_len == 0) return 0;
    auto found = host->webviews.find(webViewKey(window_id, slice(label, label_len)));
    if (found == host->webviews.end() || !found->second.hwnd) return 0;
    found->second.url = slice(url, url_len);
    if (found->second.webview) {
        std::wstring target = widen(found->second.url);
        found->second.webview->Navigate(target.c_str());
        return 1;
    }
    // WebView2 initializes asynchronously; keep the newest URL and apply it in the creation callback.
    return 1;
#endif
}

int zero_native_windows_set_webview_zoom(Host *host, uint64_t window_id, const char *label, size_t label_len, double zoom) {
#if !ZERO_NATIVE_HAS_WEBVIEW2
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    (void)zoom;
    return 0;
#else
    if (!host || label_len == 0 || zoom < 0.25 || zoom > 5.0) return 0;
    std::string label_string = slice(label, label_len);
    if (label_string == "main") return 0;
    auto found = host->webviews.find(webViewKey(window_id, label_string));
    if (found == host->webviews.end() || !found->second.hwnd) return 0;
    found->second.zoom = zoom;
    if (found->second.controller) {
        found->second.controller->put_ZoomFactor(zoom);
    }
    return 1;
#endif
}

int zero_native_windows_set_webview_layer(Host *host, uint64_t window_id, const char *label, size_t label_len, int layer) {
    if (!host || label_len == 0) return 0;
    std::string label_string = slice(label, label_len);
    if (label_string == "main") return 0;
    auto found = host->webviews.find(webViewKey(window_id, label_string));
    if (found == host->webviews.end() || !found->second.hwnd) return 0;
    found->second.layer = layer;
    applyChildWebViewLayer(host, window_id, label_string);
    return 1;
}

int zero_native_windows_close_webview(Host *host, uint64_t window_id, const char *label, size_t label_len) {
    if (!host || label_len == 0) return 0;
    auto found = host->webviews.find(webViewKey(window_id, slice(label, label_len)));
    if (found == host->webviews.end()) return 0;
#if ZERO_NATIVE_HAS_WEBVIEW2
    if (found->second.controller) found->second.controller->Close();
#endif
    if (found->second.hwnd) DestroyWindow(found->second.hwnd);
    host->webviews.erase(found);
    return 1;
}

size_t zero_native_windows_clipboard_read(Host *host, char *buffer, size_t buffer_len) {
    (void)host;
    if (!buffer || buffer_len == 0 || !OpenClipboard(nullptr)) return 0;
    HANDLE handle = GetClipboardData(CF_TEXT);
    if (!handle) {
        CloseClipboard();
        return 0;
    }
    const char *text = static_cast<const char *>(GlobalLock(handle));
    if (!text) {
        CloseClipboard();
        return 0;
    }
    size_t len = boundedLen(text, buffer_len);
    memcpy(buffer, text, len);
    GlobalUnlock(handle);
    CloseClipboard();
    return len;
}

void zero_native_windows_clipboard_write(Host *host, const char *text, size_t text_len) {
    (void)host;
    if (!OpenClipboard(nullptr)) return;
    EmptyClipboard();
    HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, text_len + 1);
    if (handle) {
        char *dest = static_cast<char *>(GlobalLock(handle));
        memcpy(dest, text, text_len);
        dest[text_len] = '\0';
        GlobalUnlock(handle);
        SetClipboardData(CF_TEXT, handle);
    }
    CloseClipboard();
}

}
