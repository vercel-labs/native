#include "gtk_host.h"

#include <gtk/gtk.h>
#include <webkit/webkit.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#define ZERO_NATIVE_MAX_WINDOWS 16
#define ZERO_NATIVE_MAX_WEBVIEWS 16
#define ZERO_NATIVE_MAX_SHORTCUTS 64

#define ZERO_NATIVE_SHORTCUT_MODIFIER_PRIMARY (1u << 0)
#define ZERO_NATIVE_SHORTCUT_MODIFIER_COMMAND (1u << 1)
#define ZERO_NATIVE_SHORTCUT_MODIFIER_CONTROL (1u << 2)
#define ZERO_NATIVE_SHORTCUT_MODIFIER_OPTION  (1u << 3)
#define ZERO_NATIVE_SHORTCUT_MODIFIER_SHIFT   (1u << 4)

typedef struct zero_native_gtk_shortcut {
    char *id;
    char *key;
    uint32_t modifiers;
} zero_native_gtk_shortcut_t;

typedef struct zero_native_gtk_webview {
    char *label;
    WebKitWebView *web_view;
    double x;
    double y;
    double width;
    double height;
    int layer;
    int transparent;
    int bridge_enabled;
    WebKitUserContentManager *content_manager;
} zero_native_gtk_webview_t;

typedef struct zero_native_gtk_window {
    uint64_t id;
    GtkWindow *gtk_window;
    WebKitWebView *web_view;
    GtkWidget *stack_root;
    WebKitUserContentManager *content_manager;
    struct zero_native_gtk_host *host;
    char *label;
    char *title;
    char *asset_root;
    char *asset_entry;
    char *asset_origin;
    char *bridge_origin;
    int spa_fallback;
    double x;
    double y;
    zero_native_gtk_webview_t webviews[ZERO_NATIVE_MAX_WEBVIEWS];
    int webview_count;
} zero_native_gtk_window_t;

struct zero_native_gtk_host {
    GtkApplication *app;
    char *app_name;
    char *window_title;
    char *bundle_id;
    char *icon_path;
    char *window_label;
    double init_x, init_y, init_width, init_height;
    int restore_frame;

    zero_native_gtk_event_callback_t callback;
    void *callback_context;
    zero_native_gtk_bridge_callback_t bridge_callback;
    void *bridge_context;

    zero_native_gtk_window_t windows[ZERO_NATIVE_MAX_WINDOWS];
    int window_count;
    int did_shutdown;
    guint frame_timer;

    char **allowed_origins;
    int allowed_origins_count;
    char **allowed_external_urls;
    int allowed_external_urls_count;
    int external_link_action;
    int scheme_registered;
    zero_native_gtk_shortcut_t shortcuts[ZERO_NATIVE_MAX_SHORTCUTS];
    int shortcut_count;
};

static char *zero_native_strndup(const char *s, size_t len) {
    char *out = malloc(len + 1);
    if (!out) return NULL;
    memcpy(out, s, len);
    out[len] = '\0';
    return out;
}

static void zero_native_free_string_list(char **list, int count) {
    if (!list) return;
    for (int i = 0; i < count; i++) free(list[i]);
    free(list);
}

static char **zero_native_parse_newline_list(const char *bytes, size_t len, int *out_count) {
    *out_count = 0;
    if (!bytes || len == 0) return NULL;

    int capacity = 4;
    char **result = malloc(sizeof(char *) * (size_t)capacity);
    if (!result) return NULL;

    const char *start = bytes;
    const char *end = bytes + len;
    while (start < end) {
        const char *nl = memchr(start, '\n', (size_t)(end - start));
        size_t seg_len = nl ? (size_t)(nl - start) : (size_t)(end - start);
        while (seg_len > 0 && (start[0] == ' ' || start[0] == '\t')) { start++; seg_len--; }
        while (seg_len > 0 && (start[seg_len - 1] == ' ' || start[seg_len - 1] == '\t' || start[seg_len - 1] == '\r')) seg_len--;
        if (seg_len > 0) {
            if (*out_count >= capacity) {
                capacity *= 2;
                char **tmp = realloc(result, sizeof(char *) * (size_t)capacity);
                if (!tmp) { zero_native_free_string_list(result, *out_count); *out_count = 0; return NULL; }
                result = tmp;
            }
            result[*out_count] = zero_native_strndup(start, seg_len);
            (*out_count)++;
        }
        start = nl ? nl + 1 : end;
    }
    return result;
}

static void zero_native_replace_string(char **dest, const char *bytes, size_t len) {
    free(*dest);
    *dest = bytes && len > 0 ? zero_native_strndup(bytes, len) : NULL;
}

static void zero_native_clear_shortcuts(zero_native_gtk_host_t *host) {
    if (!host) return;
    for (int i = 0; i < host->shortcut_count; i++) {
        free(host->shortcuts[i].id);
        free(host->shortcuts[i].key);
        memset(&host->shortcuts[i], 0, sizeof(host->shortcuts[i]));
    }
    host->shortcut_count = 0;
}

static void zero_native_clear_window_source(zero_native_gtk_window_t *win) {
    free(win->asset_root);
    free(win->asset_entry);
    free(win->asset_origin);
    free(win->bridge_origin);
    win->asset_root = NULL;
    win->asset_entry = NULL;
    win->asset_origin = NULL;
    win->bridge_origin = NULL;
    win->spa_fallback = 0;
}

static int zero_native_valid_webview_frame(double x, double y, double width, double height) {
    return x >= 0 && y >= 0 && width > 0 && height > 0;
}

static int zero_native_webview_extent(double value) {
    return value > 1 ? (int)(value + 0.5) : 1;
}

static int zero_native_webview_coord(double value) {
    return value > 0 ? (int)(value + 0.5) : 0;
}

static void zero_native_apply_webview_frame(zero_native_gtk_webview_t *webview) {
    if (!webview || !webview->web_view) return;
    GtkWidget *widget = GTK_WIDGET(webview->web_view);
    gtk_widget_set_halign(widget, GTK_ALIGN_START);
    gtk_widget_set_valign(widget, GTK_ALIGN_START);
    gtk_widget_set_margin_start(widget, zero_native_webview_coord(webview->x));
    gtk_widget_set_margin_top(widget, zero_native_webview_coord(webview->y));
    gtk_widget_set_size_request(widget, zero_native_webview_extent(webview->width), zero_native_webview_extent(webview->height));
}

static void zero_native_reorder_webviews(zero_native_gtk_window_t *win) {
    if (!win || !win->stack_root) return;
    int placed[ZERO_NATIVE_MAX_WEBVIEWS] = {0};
    GtkWidget *previous = NULL;
    for (int pass = 0; pass < win->webview_count; pass++) {
        int best = -1;
        for (int i = 0; i < win->webview_count; i++) {
            if (!win->webviews[i].web_view) continue;
            if (placed[i]) continue;
            if (best < 0 || win->webviews[i].layer < win->webviews[best].layer) best = i;
        }
        if (best < 0) break;
        gtk_widget_insert_after(GTK_WIDGET(win->webviews[best].web_view), GTK_WIDGET(win->stack_root), previous);
        placed[best] = 1;
        previous = GTK_WIDGET(win->webviews[best].web_view);
    }
}

static void zero_native_clear_webview(zero_native_gtk_window_t *win, zero_native_gtk_webview_t *webview) {
    if (!webview) return;
    if (webview->web_view && win && win->stack_root) {
        gtk_overlay_remove_overlay(GTK_OVERLAY(win->stack_root), GTK_WIDGET(webview->web_view));
    }
    free(webview->label);
    memset(webview, 0, sizeof(*webview));
}

static void zero_native_remove_webview_at(zero_native_gtk_window_t *win, int index) {
    if (!win || index < 0 || index >= win->webview_count) return;
    zero_native_clear_webview(win, &win->webviews[index]);
    for (int i = index; i + 1 < win->webview_count; i++) {
        win->webviews[i] = win->webviews[i + 1];
    }
    memset(&win->webviews[win->webview_count - 1], 0, sizeof(win->webviews[win->webview_count - 1]));
    win->webview_count--;
}

static void zero_native_clear_webviews(zero_native_gtk_window_t *win) {
    if (!win) return;
    while (win->webview_count > 0) {
        zero_native_remove_webview_at(win, win->webview_count - 1);
    }
}

static void zero_native_clear_window(zero_native_gtk_window_t *win) {
    if (!win) return;
    zero_native_clear_webviews(win);
    zero_native_clear_window_source(win);
    free(win->label);
    free(win->title);
    memset(win, 0, sizeof(*win));
}

static char *zero_native_origin_for_uri(const char *uri) {
    if (!uri || !uri[0]) return g_strdup("zero://inline");
    const char *scheme_end = strstr(uri, "://");
    if (!scheme_end) return g_strdup("zero://inline");
    size_t scheme_len = (size_t)(scheme_end - uri);
    if (scheme_len == 5 && strncmp(uri, "about", 5) == 0) {
        return g_strdup("zero://inline");
    }
    if (scheme_len == 4 && strncmp(uri, "file", 4) == 0) {
        return g_strdup("file://local");
    }
    const char *host_start = scheme_end + 3;
    const char *host_end = host_start;
    while (*host_end && *host_end != '/' && *host_end != '?' && *host_end != '#') host_end++;
    if (host_end == host_start) {
        return g_strdup_printf("%.*s://local", (int)scheme_len, uri);
    }
    return g_strndup(uri, (gsize)(host_end - uri));
}

static int zero_native_policy_list_matches(char **values, int count, const char *uri) {
    char *origin = zero_native_origin_for_uri(uri);
    int matched = 0;
    for (int i = 0; i < count && !matched; i++) {
        const char *value = values[i];
        size_t len = strlen(value);
        if (strcmp(value, "*") == 0 || strcmp(value, origin) == 0 || (uri && strcmp(value, uri) == 0)) {
            matched = 1;
        } else if (len > 0 && value[len - 1] == '*') {
            matched = uri && strncmp(uri, value, len - 1) == 0;
            if (!matched) matched = strncmp(origin, value, len - 1) == 0;
        }
    }
    g_free(origin);
    return matched;
}

static int zero_native_path_is_safe(const char *path) {
    if (!path || !path[0]) return 0;
    if (path[0] == '/' || strchr(path, '\\')) return 0;
    const char *segment = path;
    while (*segment) {
        const char *slash = strchr(segment, '/');
        size_t len = slash ? (size_t)(slash - segment) : strlen(segment);
        if (len == 0) return 0;
        if ((len == 1 && segment[0] == '.') || (len == 2 && segment[0] == '.' && segment[1] == '.')) return 0;
        if (!slash) break;
        segment = slash + 1;
    }
    return 1;
}

static const char *zero_native_bridge_script(void) {
    return
        "(function(){"
        "if(window.zero&&window.zero.invoke){return;}"
        "var pending=new Map();"
        "var listeners=new Map();"
        "var nextId=1;"
        "function post(message){"
        "window.webkit.messageHandlers.zeroNativeBridge.postMessage(message);"
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
        "function optionalFramePayload(options){var frame=options.frame||((options.x!=null||options.y!=null||options.width!=null||options.height!=null)?options:null);if(!frame){return null;}return {x:frame.x==null?0:ensureNumber(frame.x,'frame.x'),y:frame.y==null?0:ensureNumber(frame.y,'frame.y'),width:ensureNumber(frame.width,'frame.width'),height:ensureNumber(frame.height,'frame.height')};}"
        "function viewCreatePayload(options){options=options||{};validateViewSelector(options);ensureString(options.kind,'kind');var payload={label:options.label,kind:options.kind,windowId:options.windowId};var frame=optionalFramePayload(options);if(frame){payload.frame=frame;}if(options.parent!=null){payload.parent=ensureString(options.parent,'parent');}if(options.role!=null){payload.role=ensureString(options.role,'role');}if(options.text!=null){payload.text=ensureString(options.text,'text');}if(options.url!=null){payload.url=ensureString(options.url,'url');}if(options.layer!=null){payload.layer=ensureNumber(options.layer,'layer');}if(options.visible!=null){payload.visible=!!options.visible;}if(options.enabled!=null){payload.enabled=!!options.enabled;}if(options.transparent!=null){payload.transparent=!!options.transparent;}if(options.bridge!=null){payload.bridge=!!options.bridge;}return payload;}"
        "function viewPatchPayload(options){options=options||{};validateViewSelector(options);var payload={label:options.label,windowId:options.windowId};var frame=optionalFramePayload(options);if(frame){payload.frame=frame;}if(options.layer!=null){payload.layer=ensureNumber(options.layer,'layer');}if(options.visible!=null){payload.visible=!!options.visible;}if(options.enabled!=null){payload.enabled=!!options.enabled;}if(options.role!=null){payload.role=ensureString(options.role,'role');}if(options.text!=null){payload.text=ensureString(options.text,'text');}if(options.url!=null){payload.url=ensureString(options.url,'url');}return payload;}"
        "function viewFramePayload(options){options=options||{};validateViewSelector(options);var frame=options.frame||options;return {label:options.label,windowId:options.windowId,frame:{x:frame.x==null?0:ensureNumber(frame.x,'frame.x'),y:frame.y==null?0:ensureNumber(frame.y,'frame.y'),width:ensureNumber(frame.width,'frame.width'),height:ensureNumber(frame.height,'frame.height')}};}"
        "function viewVisiblePayload(options){options=options||{};validateViewSelector(options);if(options.visible==null){throw new TypeError('visible is required');}return {label:options.label,windowId:options.windowId,visible:!!options.visible};}"
        "function viewHandle(info){return Object.freeze(Object.assign({},info,{update:function(patch){return views.update(Object.assign({},patch||{},{label:info.label,windowId:info.windowId}));},setFrame:function(frame){return views.setFrame({label:info.label,windowId:info.windowId,frame:frame});},setVisible:function(visible){return views.setVisible({label:info.label,windowId:info.windowId,visible:visible});},focus:function(){return views.focus({label:info.label,windowId:info.windowId});},close:function(){return views.close({label:info.label,windowId:info.windowId});}}));}"
        "function on(name,callback){if(typeof callback!=='function'){throw new TypeError('callback must be a function');}var set=listeners.get(name);if(!set){set=new Set();listeners.set(name,set);}set.add(callback);return function(){off(name,callback);};}"
        "function off(name,callback){var set=listeners.get(name);if(set){set.delete(callback);if(set.size===0){listeners.delete(name);}}}"
        "function emit(name,detail){var set=listeners.get(name);if(set){Array.from(set).forEach(function(callback){callback(detail);});}window.dispatchEvent(new CustomEvent('zero-native:'+name,{detail:detail}));}"
        "var commands=Object.freeze({"
        "invoke:function(value){return invoke('zero-native.command.invoke',commandPayload(value));}"
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
        "update:function(options){return invoke('zero-native.view.update',viewPatchPayload(options)).then(viewHandle);},"
        "setFrame:function(options){return invoke('zero-native.view.setFrame',viewFramePayload(options)).then(viewHandle);},"
        "setVisible:function(options){return invoke('zero-native.view.setVisible',viewVisiblePayload(options)).then(viewHandle);},"
        "focus:function(options){options=options||{};validateViewSelector(options);return invoke('zero-native.view.focus',{label:options.label,windowId:options.windowId}).then(viewHandle);},"
        "close:function(options){options=options||{};validateViewSelector(options);return invoke('zero-native.view.close',{label:options.label,windowId:options.windowId});}"
        "});"
        "Object.defineProperty(window,'zero',{value:Object.freeze({invoke:invoke,on:on,off:off,commands:commands,windows:windows,dialogs:dialogs,clipboard:clipboard,os:os,credentials:credentials,webviews:webviews,views:views,_complete:complete,_emit:emit}),configurable:false});"
        "})();";
}

static const char *zero_native_mime_for_ext(const char *path) {
    const char *dot = strrchr(path, '.');
    if (!dot) return "application/octet-stream";
    dot++;
    if (strcmp(dot, "html") == 0 || strcmp(dot, "htm") == 0) return "text/html";
    if (strcmp(dot, "js") == 0 || strcmp(dot, "mjs") == 0) return "text/javascript";
    if (strcmp(dot, "css") == 0) return "text/css";
    if (strcmp(dot, "json") == 0) return "application/json";
    if (strcmp(dot, "svg") == 0) return "image/svg+xml";
    if (strcmp(dot, "png") == 0) return "image/png";
    if (strcmp(dot, "jpg") == 0 || strcmp(dot, "jpeg") == 0) return "image/jpeg";
    if (strcmp(dot, "gif") == 0) return "image/gif";
    if (strcmp(dot, "webp") == 0) return "image/webp";
    if (strcmp(dot, "woff") == 0) return "font/woff";
    if (strcmp(dot, "woff2") == 0) return "font/woff2";
    if (strcmp(dot, "ttf") == 0) return "font/ttf";
    if (strcmp(dot, "otf") == 0) return "font/otf";
    if (strcmp(dot, "wasm") == 0) return "application/wasm";
    return "application/octet-stream";
}

static zero_native_gtk_window_t *zero_native_window_for_asset_uri(zero_native_gtk_host_t *host, const char *uri) {
    char *origin = zero_native_origin_for_uri(uri);
    zero_native_gtk_window_t *fallback = NULL;
    for (int i = 0; i < host->window_count; i++) {
        zero_native_gtk_window_t *win = &host->windows[i];
        if (!win->asset_root) continue;
        if (!fallback) fallback = win;
        if (win->asset_origin && strcmp(win->asset_origin, origin) == 0) {
            g_free(origin);
            return win;
        }
    }
    g_free(origin);
    return fallback;
}

static char *zero_native_asset_relative_path(const char *uri, const char *entry) {
    const char *path = strstr(uri, "://");
    path = path ? strchr(path + 3, '/') : NULL;
    if (!path || !path[1]) return g_strdup(entry && entry[0] ? entry : "index.html");
    while (*path == '/') path++;
    char *unescaped = g_uri_unescape_string(path, NULL);
    if (!unescaped) return NULL;
    if (!zero_native_path_is_safe(unescaped)) {
        g_free(unescaped);
        return NULL;
    }
    return unescaped;
}

static void zero_native_fail_scheme_request(WebKitURISchemeRequest *request, GQuark domain, int code, const char *message) {
    GError *error = g_error_new_literal(domain, code, message);
    webkit_uri_scheme_request_finish_error(request, error);
    g_error_free(error);
}

static void zero_native_asset_scheme_request(WebKitURISchemeRequest *request, gpointer data) {
    zero_native_gtk_host_t *host = data;
    const char *uri = webkit_uri_scheme_request_get_uri(request);
    zero_native_gtk_window_t *win = zero_native_window_for_asset_uri(host, uri);
    if (!win || !win->asset_root) {
        zero_native_fail_scheme_request(request, G_IO_ERROR, G_IO_ERROR_NOT_FOUND, "No asset root is configured");
        return;
    }

    char *relative = zero_native_asset_relative_path(uri, win->asset_entry);
    if (!relative) {
        zero_native_fail_scheme_request(request, G_IO_ERROR, G_IO_ERROR_INVALID_FILENAME, "Unsafe asset path");
        return;
    }

    char *path = g_build_filename(win->asset_root, relative, NULL);
    if (!g_file_test(path, G_FILE_TEST_EXISTS) || g_file_test(path, G_FILE_TEST_IS_DIR)) {
        if (win->spa_fallback) {
            g_free(path);
            path = g_build_filename(win->asset_root, win->asset_entry && win->asset_entry[0] ? win->asset_entry : "index.html", NULL);
        }
    }

    gchar *contents = NULL;
    gsize length = 0;
    GError *read_error = NULL;
    if (!g_file_get_contents(path, &contents, &length, &read_error)) {
        webkit_uri_scheme_request_finish_error(request, read_error);
        g_error_free(read_error);
        g_free(path);
        g_free(relative);
        return;
    }

    GInputStream *stream = g_memory_input_stream_new_from_data(contents, (gssize)length, g_free);
    webkit_uri_scheme_request_finish(request, stream, (gint64)length, zero_native_mime_for_ext(path));
    g_object_unref(stream);
    g_free(path);
    g_free(relative);
}

static zero_native_gtk_window_t *zero_native_find_window(zero_native_gtk_host_t *host, uint64_t id) {
    for (int i = 0; i < host->window_count; i++) {
        if (host->windows[i].id == id && host->windows[i].gtk_window) return &host->windows[i];
    }
    return NULL;
}

static zero_native_gtk_webview_t *zero_native_find_webview(zero_native_gtk_window_t *win, const char *label) {
    if (!win || !label) return NULL;
    for (int i = 0; i < win->webview_count; i++) {
        if (win->webviews[i].label && strcmp(win->webviews[i].label, label) == 0) return &win->webviews[i];
    }
    return NULL;
}

static void zero_native_emit(zero_native_gtk_host_t *host, zero_native_gtk_event_t event) {
    if (host->callback) host->callback(host->callback_context, &event);
}

static void zero_native_emit_window_frame(zero_native_gtk_host_t *host, zero_native_gtk_window_t *win, int open) {
    if (!win || !win->gtk_window) return;
    int w = gtk_widget_get_width(GTK_WIDGET(win->gtk_window));
    int h = gtk_widget_get_height(GTK_WIDGET(win->gtk_window));
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(win->gtk_window));
    double scale = surface ? gdk_surface_get_scale_factor(surface) : 1.0;
    int focused = gtk_window_is_active(win->gtk_window) ? 1 : 0;
    zero_native_emit(host, (zero_native_gtk_event_t){
        .kind = ZERO_NATIVE_GTK_EVENT_WINDOW_FRAME,
        .window_id = win->id,
        .x = win->x, .y = win->y,
        .width = (double)w, .height = (double)h,
        .scale = scale,
        .open = open,
        .focused = focused,
        .label = win->label ? win->label : "",
        .label_len = win->label ? strlen(win->label) : 0,
        .title = win->title ? win->title : "",
        .title_len = win->title ? strlen(win->title) : 0,
    });
}

static void zero_native_emit_resize(zero_native_gtk_host_t *host, zero_native_gtk_window_t *win) {
    if (!win || !win->gtk_window) return;
    int w = gtk_widget_get_width(GTK_WIDGET(win->gtk_window));
    int h = gtk_widget_get_height(GTK_WIDGET(win->gtk_window));
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(win->gtk_window));
    double scale = surface ? gdk_surface_get_scale_factor(surface) : 1.0;
    zero_native_emit(host, (zero_native_gtk_event_t){
        .kind = ZERO_NATIVE_GTK_EVENT_RESIZE,
        .window_id = win->id,
        .width = (double)w, .height = (double)h,
        .scale = scale,
    });
}

static const char *zero_native_shortcut_key_for_keyval(guint keyval, char *buffer, size_t buffer_len, int *uses_implicit_shift) {
    if (!buffer || buffer_len < 2) return "";
    guint lower = gdk_keyval_to_lower(keyval);
    switch (lower) {
        case '!': lower = '1'; if (uses_implicit_shift) *uses_implicit_shift = 1; break;
        case '@': lower = '2'; if (uses_implicit_shift) *uses_implicit_shift = 1; break;
        case '#': lower = '3'; if (uses_implicit_shift) *uses_implicit_shift = 1; break;
        case '$': lower = '4'; if (uses_implicit_shift) *uses_implicit_shift = 1; break;
        case '%': lower = '5'; if (uses_implicit_shift) *uses_implicit_shift = 1; break;
        case '^': lower = '6'; if (uses_implicit_shift) *uses_implicit_shift = 1; break;
        case '&': lower = '7'; if (uses_implicit_shift) *uses_implicit_shift = 1; break;
        case '*': lower = '8'; if (uses_implicit_shift) *uses_implicit_shift = 1; break;
        case '(': lower = '9'; if (uses_implicit_shift) *uses_implicit_shift = 1; break;
        case ')': lower = '0'; if (uses_implicit_shift) *uses_implicit_shift = 1; break;
        case '+': lower = '='; if (uses_implicit_shift) *uses_implicit_shift = 1; break;
        case '_': lower = '-'; if (uses_implicit_shift) *uses_implicit_shift = 1; break;
        case '<': lower = ','; if (uses_implicit_shift) *uses_implicit_shift = 1; break;
        case '>': lower = '.'; if (uses_implicit_shift) *uses_implicit_shift = 1; break;
        case '?': lower = '/'; if (uses_implicit_shift) *uses_implicit_shift = 1; break;
        case ':': lower = ';'; if (uses_implicit_shift) *uses_implicit_shift = 1; break;
        case '"': lower = '\''; if (uses_implicit_shift) *uses_implicit_shift = 1; break;
        case '{': lower = '['; if (uses_implicit_shift) *uses_implicit_shift = 1; break;
        case '}': lower = ']'; if (uses_implicit_shift) *uses_implicit_shift = 1; break;
        case '|': lower = '\\'; if (uses_implicit_shift) *uses_implicit_shift = 1; break;
        case '~': lower = '`'; if (uses_implicit_shift) *uses_implicit_shift = 1; break;
        default: break;
    }
    if ((lower >= 'a' && lower <= 'z') || (lower >= '0' && lower <= '9') ||
        lower == '=' || lower == '-' || lower == ',' ||
        lower == '.' || lower == '/' || lower == ';' || lower == '\'' ||
        lower == '[' || lower == ']' || lower == '\\' || lower == '`') {
        buffer[0] = (char)lower;
        buffer[1] = '\0';
        return buffer;
    }
    switch (keyval) {
        case GDK_KEY_Escape: return "escape";
        case GDK_KEY_Return:
        case GDK_KEY_KP_Enter: return "enter";
        case GDK_KEY_Tab:
        case GDK_KEY_ISO_Left_Tab: return "tab";
        case GDK_KEY_space: return "space";
        case GDK_KEY_BackSpace: return "backspace";
        case GDK_KEY_Left: return "arrowleft";
        case GDK_KEY_Right: return "arrowright";
        case GDK_KEY_Up: return "arrowup";
        case GDK_KEY_Down: return "arrowdown";
        default: return "";
    }
}

static int zero_native_shortcut_modifiers_match(uint32_t shortcut_modifiers, GdkModifierType event_modifiers, int allow_implicit_shift) {
    int needs_control = (shortcut_modifiers & ZERO_NATIVE_SHORTCUT_MODIFIER_CONTROL) != 0 ||
        (shortcut_modifiers & ZERO_NATIVE_SHORTCUT_MODIFIER_PRIMARY) != 0;
    int needs_option = (shortcut_modifiers & ZERO_NATIVE_SHORTCUT_MODIFIER_OPTION) != 0;
    int needs_shift = (shortcut_modifiers & ZERO_NATIVE_SHORTCUT_MODIFIER_SHIFT) != 0;
    int needs_command = (shortcut_modifiers & ZERO_NATIVE_SHORTCUT_MODIFIER_COMMAND) != 0;
    int has_control = (event_modifiers & GDK_CONTROL_MASK) != 0;
    int has_option = (event_modifiers & GDK_ALT_MASK) != 0;
    int has_shift = (event_modifiers & GDK_SHIFT_MASK) != 0;
    int has_command = ((event_modifiers & GDK_META_MASK) != 0) || ((event_modifiers & GDK_SUPER_MASK) != 0);
    int shift_matches = needs_shift ? has_shift : (!has_shift || allow_implicit_shift);
    return has_control == needs_control &&
        has_option == needs_option &&
        shift_matches &&
        has_command == needs_command;
}

static gboolean on_shortcut_key_pressed(GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state, gpointer data) {
    (void)controller;
    (void)keycode;
    zero_native_gtk_window_t *win = data;
    zero_native_gtk_host_t *host = win ? win->host : NULL;
    if (!host || host->shortcut_count == 0) return FALSE;
    char key_buffer[32];
    int uses_implicit_shift = 0;
    const char *key = zero_native_shortcut_key_for_keyval(keyval, key_buffer, sizeof(key_buffer), &uses_implicit_shift);
    if (!key || !key[0]) return FALSE;
    int pass_count = uses_implicit_shift ? 2 : 1;
    for (int pass = 0; pass < pass_count; pass++) {
        int allow_implicit_shift = pass == 1;
        for (int i = 0; i < host->shortcut_count; i++) {
            zero_native_gtk_shortcut_t *shortcut = &host->shortcuts[i];
            if (!shortcut->id || !shortcut->key || strcmp(shortcut->key, key) != 0) continue;
            if (!zero_native_shortcut_modifiers_match(shortcut->modifiers, state, allow_implicit_shift)) continue;
            zero_native_emit(host, (zero_native_gtk_event_t){
                .kind = ZERO_NATIVE_GTK_EVENT_SHORTCUT,
                .window_id = win->id,
                .shortcut_id = shortcut->id,
                .shortcut_id_len = strlen(shortcut->id),
                .shortcut_key = shortcut->key,
                .shortcut_key_len = strlen(shortcut->key),
                .shortcut_modifiers = shortcut->modifiers,
            });
            return TRUE;
        }
    }
    return FALSE;
}

static gboolean zero_native_frame_tick(gpointer data) {
    zero_native_gtk_host_t *host = data;
    zero_native_emit(host, (zero_native_gtk_event_t){ .kind = ZERO_NATIVE_GTK_EVENT_FRAME });
    return G_SOURCE_CONTINUE;
}

static void on_resize(GtkWidget *widget, GParamSpec *pspec, gpointer data) {
    (void)pspec;
    (void)widget;
    zero_native_gtk_window_t *win = data;
    zero_native_emit_window_frame(win->host, win, 1);
    zero_native_emit_resize(win->host, win);
}

static void on_focus(GtkWindow *window, GParamSpec *pspec, gpointer data) {
    (void)pspec;
    (void)window;
    zero_native_gtk_window_t *win = data;
    zero_native_emit_window_frame(win->host, win, 1);
}

static gboolean on_close_request(GtkWindow *window, gpointer data) {
    (void)window;
    zero_native_gtk_window_t *win = data;
    zero_native_gtk_host_t *host = win->host;
    int closed_index = -1;
    for (int i = 0; i < host->window_count; i++) {
        if (&host->windows[i] == win) {
            closed_index = i;
            break;
        }
    }
    zero_native_emit_window_frame(host, win, 0);

    if (closed_index >= 0) {
        zero_native_clear_window(&host->windows[closed_index]);
    }

    int open_count = 0;
    for (int i = 0; i < host->window_count; i++) {
        if (host->windows[i].gtk_window) open_count++;
    }
    if (open_count == 0) {
        if (!host->did_shutdown) {
            host->did_shutdown = 1;
            zero_native_emit(host, (zero_native_gtk_event_t){ .kind = ZERO_NATIVE_GTK_EVENT_SHUTDOWN });
        }
        if (host->frame_timer) {
            g_source_remove(host->frame_timer);
            host->frame_timer = 0;
        }
        g_application_quit(G_APPLICATION(host->app));
    }
    return FALSE;
}

static const char *zero_native_decision_uri(WebKitPolicyDecision *decision, WebKitPolicyDecisionType type) {
    if (type != WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) return NULL;
    WebKitNavigationPolicyDecision *navigation = WEBKIT_NAVIGATION_POLICY_DECISION(decision);
    WebKitNavigationAction *action = webkit_navigation_policy_decision_get_navigation_action(navigation);
    WebKitURIRequest *request = action ? webkit_navigation_action_get_request(action) : NULL;
    return request ? webkit_uri_request_get_uri(request) : NULL;
}

#if GTK_CHECK_VERSION(4, 10, 0)
static void zero_native_uri_launch_done(GObject *source_object, GAsyncResult *result, gpointer data) {
    (void)data;
    GtkUriLauncher *launcher = GTK_URI_LAUNCHER(source_object);
    GError *error = NULL;
    if (!gtk_uri_launcher_launch_finish(launcher, result, &error) && error) {
        g_warning("failed to open external URI: %s", error->message);
        g_error_free(error);
    }
    g_object_unref(launcher);
}
#endif

static void zero_native_open_external_uri(GtkWindow *parent, const char *uri) {
#if GTK_CHECK_VERSION(4, 10, 0)
    GtkUriLauncher *launcher = gtk_uri_launcher_new(uri);
    gtk_uri_launcher_launch(launcher, parent, NULL, zero_native_uri_launch_done, NULL);
#else
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    gtk_show_uri(parent, uri, GDK_CURRENT_TIME);
    G_GNUC_END_IGNORE_DEPRECATIONS
#endif
}

static gboolean on_decide_policy(WebKitWebView *web_view, WebKitPolicyDecision *decision, WebKitPolicyDecisionType type, gpointer data) {
    (void)web_view;
    zero_native_gtk_window_t *win = data;
    zero_native_gtk_host_t *host = win->host;
    const char *uri = zero_native_decision_uri(decision, type);
    if (!uri || !uri[0] || strncmp(uri, "about:", 6) == 0) {
        webkit_policy_decision_use(decision);
        return TRUE;
    }

    char *origin = zero_native_origin_for_uri(uri);
    int internal_asset = win->asset_origin && strcmp(origin, win->asset_origin) == 0;
    g_free(origin);
    if (internal_asset || zero_native_policy_list_matches(host->allowed_origins, host->allowed_origins_count, uri)) {
        webkit_policy_decision_use(decision);
        return TRUE;
    }

    if (host->external_link_action == 1 && zero_native_policy_list_matches(host->allowed_external_urls, host->allowed_external_urls_count, uri)) {
        zero_native_open_external_uri(win->gtk_window, uri);
        webkit_policy_decision_ignore(decision);
        return TRUE;
    }

    webkit_policy_decision_ignore(decision);
    return TRUE;
}

static gboolean on_webview_decide_policy(WebKitWebView *web_view, WebKitPolicyDecision *decision, WebKitPolicyDecisionType type, gpointer data) {
    (void)web_view;
    zero_native_gtk_window_t *win = data;
    zero_native_gtk_host_t *host = win->host;
    const char *uri = zero_native_decision_uri(decision, type);
    if (!uri || !uri[0] || strncmp(uri, "about:", 6) == 0) {
        webkit_policy_decision_use(decision);
        return TRUE;
    }
    char *origin = zero_native_origin_for_uri(uri);
    int internal_asset = win->asset_origin && strcmp(origin, win->asset_origin) == 0;
    g_free(origin);
    if (internal_asset || zero_native_policy_list_matches(host->allowed_origins, host->allowed_origins_count, uri)) {
        webkit_policy_decision_use(decision);
        return TRUE;
    }
    if (host->external_link_action == 1 && zero_native_policy_list_matches(host->allowed_external_urls, host->allowed_external_urls_count, uri)) {
        zero_native_open_external_uri(win->gtk_window, uri);
    }
    webkit_policy_decision_ignore(decision);
    return TRUE;
}

static void on_bridge_message(WebKitUserContentManager *manager, JSCValue *js_result, gpointer data) {
    zero_native_gtk_window_t *win = data;
    zero_native_gtk_host_t *host = win->host;
    if (!host->bridge_callback) return;

    char *message = jsc_value_to_string(js_result);
    if (!message) return;

    const char *label = "main";
    WebKitWebView *source_webview = win->web_view;
    if (manager != win->content_manager) {
        for (int i = 0; i < win->webview_count; i++) {
            if (win->webviews[i].content_manager == manager) {
                label = win->webviews[i].label ? win->webviews[i].label : "webview";
                source_webview = win->webviews[i].web_view;
                break;
            }
        }
    }
    const char *uri = webkit_web_view_get_uri(source_webview);
    char *computed_origin = win->bridge_origin && strcmp(label, "main") == 0 ? g_strdup(win->bridge_origin) : zero_native_origin_for_uri(uri);
    host->bridge_callback(host->bridge_context, win->id, label, strlen(label), message, strlen(message), computed_origin, strlen(computed_origin));
    g_free(computed_origin);
    g_free(message);
}

static void zero_native_setup_bridge(zero_native_gtk_window_t *win) {
    WebKitUserContentManager *manager = win->content_manager;
    g_signal_connect(manager, "script-message-received::zeroNativeBridge", G_CALLBACK(on_bridge_message), win);
    webkit_user_content_manager_register_script_message_handler(manager, "zeroNativeBridge", NULL);

    WebKitUserScript *script = webkit_user_script_new(
        zero_native_bridge_script(),
        WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
        WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
        NULL, NULL);
    webkit_user_content_manager_add_script(manager, script);
    webkit_user_script_unref(script);
}

static zero_native_gtk_window_t *zero_native_create_window_internal(zero_native_gtk_host_t *host, uint64_t window_id, const char *title, const char *label, double x, double y, double width, double height, int restore_frame) {
    if (zero_native_find_window(host, window_id)) return NULL;

    int slot = -1;
    for (int i = 0; i < host->window_count; i++) {
        if (!host->windows[i].gtk_window) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        if (host->window_count >= ZERO_NATIVE_MAX_WINDOWS) return NULL;
        slot = host->window_count++;
    }

    zero_native_gtk_window_t *win = &host->windows[slot];
    memset(win, 0, sizeof(*win));
    win->id = window_id;
    win->host = host;
    win->x = restore_frame ? x : 0;
    win->y = restore_frame ? y : 0;
    win->label = zero_native_strndup(label && label[0] ? label : "main", strlen(label && label[0] ? label : "main"));
    win->title = zero_native_strndup(title && title[0] ? title : host->app_name, strlen(title && title[0] ? title : host->app_name));
    if (!win->label || !win->title) {
        free(win->label);
        free(win->title);
        memset(win, 0, sizeof(*win));
        return NULL;
    }

    win->gtk_window = GTK_WINDOW(gtk_application_window_new(host->app));
    gtk_window_set_title(win->gtk_window, win->title);
    gtk_window_set_default_size(win->gtk_window, (int)width, (int)height);

    win->content_manager = webkit_user_content_manager_new();
    WebKitWebView *wv = WEBKIT_WEB_VIEW(
        g_object_new(WEBKIT_TYPE_WEB_VIEW,
            "user-content-manager", win->content_manager,
            NULL));
    win->web_view = wv;
    if (!host->scheme_registered) {
        webkit_web_context_register_uri_scheme(webkit_web_view_get_context(wv), "zero", zero_native_asset_scheme_request, host, NULL);
        host->scheme_registered = 1;
    }
    zero_native_setup_bridge(win);

    win->stack_root = gtk_overlay_new();
    gtk_overlay_set_child(GTK_OVERLAY(win->stack_root), GTK_WIDGET(wv));
    gtk_window_set_child(win->gtk_window, win->stack_root);

    g_signal_connect(win->gtk_window, "notify::default-width", G_CALLBACK(on_resize), win);
    g_signal_connect(win->gtk_window, "notify::default-height", G_CALLBACK(on_resize), win);
    g_signal_connect(win->gtk_window, "notify::is-active", G_CALLBACK(on_focus), win);
    g_signal_connect(win->gtk_window, "close-request", G_CALLBACK(on_close_request), win);
    g_signal_connect(win->web_view, "decide-policy", G_CALLBACK(on_decide_policy), win);
    GtkEventController *shortcut_controller = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(shortcut_controller, GTK_PHASE_CAPTURE);
    g_signal_connect(shortcut_controller, "key-pressed", G_CALLBACK(on_shortcut_key_pressed), win);
    gtk_widget_add_controller(GTK_WIDGET(win->gtk_window), shortcut_controller);

    return win;
}

static void on_activate(GtkApplication *app, gpointer data) {
    (void)app;
    zero_native_gtk_host_t *host = data;

    zero_native_gtk_window_t *win = zero_native_create_window_internal(
        host, 1, host->window_title, host->window_label,
        host->init_x, host->init_y,
        host->init_width > 0 ? host->init_width : 720,
        host->init_height > 0 ? host->init_height : 480,
        host->restore_frame);
    if (!win) return;

    gtk_window_present(win->gtk_window);

    zero_native_emit(host, (zero_native_gtk_event_t){ .kind = ZERO_NATIVE_GTK_EVENT_START });
    zero_native_emit_resize(host, win);
    zero_native_emit_window_frame(host, win, 1);

    host->frame_timer = g_timeout_add(16, zero_native_frame_tick, host);
}

zero_native_gtk_host_t *zero_native_gtk_create(
    const char *app_name, size_t app_name_len,
    const char *window_title, size_t window_title_len,
    const char *bundle_id, size_t bundle_id_len,
    const char *icon_path, size_t icon_path_len,
    const char *window_label, size_t window_label_len,
    double x, double y, double width, double height,
    int restore_frame)
{
    zero_native_gtk_host_t *host = calloc(1, sizeof(zero_native_gtk_host_t));
    if (!host) return NULL;

    host->app_name = app_name_len > 0 ? zero_native_strndup(app_name, app_name_len) : zero_native_strndup("zero-native", 11);
    host->window_title = window_title_len > 0 ? zero_native_strndup(window_title, window_title_len) : zero_native_strndup(host->app_name, strlen(host->app_name));
    host->bundle_id = bundle_id_len > 0 ? zero_native_strndup(bundle_id, bundle_id_len) : zero_native_strndup("dev.zero_native.app", 19);
    host->icon_path = icon_path_len > 0 ? zero_native_strndup(icon_path, icon_path_len) : NULL;
    host->window_label = window_label_len > 0 ? zero_native_strndup(window_label, window_label_len) : zero_native_strndup("main", 4);
    host->init_x = x;
    host->init_y = y;
    host->init_width = width;
    host->init_height = height;
    host->restore_frame = restore_frame;

    host->allowed_origins = NULL;
    host->allowed_origins_count = 0;
    host->allowed_external_urls = NULL;
    host->allowed_external_urls_count = 0;

    host->app = gtk_application_new(host->bundle_id, G_APPLICATION_DEFAULT_FLAGS);

    return host;
}

void zero_native_gtk_destroy(zero_native_gtk_host_t *host) {
    if (!host) return;
    if (host->frame_timer) g_source_remove(host->frame_timer);
    for (int i = 0; i < host->window_count; i++) {
        zero_native_clear_window(&host->windows[i]);
    }
    g_object_unref(host->app);
    free(host->app_name);
    free(host->window_title);
    free(host->bundle_id);
    free(host->icon_path);
    free(host->window_label);
    zero_native_free_string_list(host->allowed_origins, host->allowed_origins_count);
    zero_native_free_string_list(host->allowed_external_urls, host->allowed_external_urls_count);
    zero_native_clear_shortcuts(host);
    free(host);
}

void zero_native_gtk_run(zero_native_gtk_host_t *host, zero_native_gtk_event_callback_t callback, void *context) {
    host->callback = callback;
    host->callback_context = context;
    g_signal_connect(host->app, "activate", G_CALLBACK(on_activate), host);
    g_application_run(G_APPLICATION(host->app), 0, NULL);
}

void zero_native_gtk_stop(zero_native_gtk_host_t *host) {
    if (!host->did_shutdown) {
        host->did_shutdown = 1;
        zero_native_emit(host, (zero_native_gtk_event_t){ .kind = ZERO_NATIVE_GTK_EVENT_SHUTDOWN });
    }
    if (host->frame_timer) {
        g_source_remove(host->frame_timer);
        host->frame_timer = 0;
    }
    g_application_quit(G_APPLICATION(host->app));
}

void zero_native_gtk_load_webview(zero_native_gtk_host_t *host, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback) {
    zero_native_gtk_load_window_webview(host, 1, source, source_len, source_kind, asset_root, asset_root_len, asset_entry, asset_entry_len, asset_origin, asset_origin_len, spa_fallback);
}

void zero_native_gtk_load_window_webview(zero_native_gtk_host_t *host, uint64_t window_id, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback) {
    zero_native_gtk_window_t *win = zero_native_find_window(host, window_id);
    if (!win || !win->web_view) return;

    char *src = zero_native_strndup(source, source_len);
    if (!src) return;

    zero_native_clear_window_source(win);
    if (source_kind == 1) {
        webkit_web_view_load_uri(win->web_view, src);
    } else if (source_kind == 2) {
        char *root = asset_root_len > 0 ? zero_native_strndup(asset_root, asset_root_len) : zero_native_strndup(".", 1);
        char *entry = asset_entry_len > 0 ? zero_native_strndup(asset_entry, asset_entry_len) : zero_native_strndup("index.html", strlen("index.html"));
        char *origin = asset_origin_len > 0 ? zero_native_strndup(asset_origin, asset_origin_len) : zero_native_strndup("zero://app", strlen("zero://app"));
        if (!root || !entry || !origin) {
            free(root);
            free(entry);
            free(origin);
            free(src);
            return;
        }
        while (entry[0] == '/') memmove(entry, entry + 1, strlen(entry));
        if (!zero_native_path_is_safe(entry)) {
            free(entry);
            entry = zero_native_strndup("index.html", strlen("index.html"));
        }
        char *canonical_root = g_canonicalize_filename(root, NULL);
        free(root);
        win->asset_root = canonical_root ? zero_native_strndup(canonical_root, strlen(canonical_root)) : zero_native_strndup(".", 1);
        g_free(canonical_root);
        win->asset_entry = entry;
        win->asset_origin = origin;
        win->bridge_origin = zero_native_strndup(origin, strlen(origin));
        win->spa_fallback = spa_fallback != 0;

        char *uri = g_strdup_printf("%s/%s", origin, entry);
        webkit_web_view_load_uri(win->web_view, uri);
        g_free(uri);
    } else {
        win->bridge_origin = zero_native_strndup("zero://inline", strlen("zero://inline"));
        webkit_web_view_load_html(win->web_view, src, "zero://inline");
    }
    free(src);
}

void zero_native_gtk_set_bridge_callback(zero_native_gtk_host_t *host, zero_native_gtk_bridge_callback_t callback, void *context) {
    host->bridge_callback = callback;
    host->bridge_context = context;
}

void zero_native_gtk_bridge_respond(zero_native_gtk_host_t *host, const char *response, size_t response_len) {
    zero_native_gtk_bridge_respond_window(host, 1, response, response_len);
}

void zero_native_gtk_bridge_respond_window(zero_native_gtk_host_t *host, uint64_t window_id, const char *response, size_t response_len) {
    zero_native_gtk_bridge_respond_webview(host, window_id, "main", 4, response, response_len);
}

void zero_native_gtk_bridge_respond_webview(zero_native_gtk_host_t *host, uint64_t window_id, const char *webview_label, size_t webview_label_len, const char *response, size_t response_len) {
    zero_native_gtk_window_t *win = zero_native_find_window(host, window_id);
    if (!win || !win->web_view) return;
    char *label = webview_label_len > 0 ? zero_native_strndup(webview_label, webview_label_len) : zero_native_strndup("main", 4);
    if (!label) return;
    WebKitWebView *target = NULL;
    if (strcmp(label, "main") == 0) {
        target = win->web_view;
    } else {
        zero_native_gtk_webview_t *webview = zero_native_find_webview(win, label);
        if (webview) target = webview->web_view;
    }
    free(label);
    if (!target) return;

    char *resp = zero_native_strndup(response, response_len);
    if (!resp) return;

    size_t prefix_len = strlen("window.zero&&window.zero._complete(");
    size_t suffix_len = 2; /* ); */
    size_t script_len = prefix_len + response_len + suffix_len;
    char *script = malloc(script_len + 1);
    if (script) {
        memcpy(script, "window.zero&&window.zero._complete(", prefix_len);
        memcpy(script + prefix_len, resp, response_len);
        memcpy(script + prefix_len + response_len, ");", suffix_len);
        script[script_len] = '\0';
        webkit_web_view_evaluate_javascript(target, script, -1, NULL, NULL, NULL, NULL, NULL);
        free(script);
    }
    free(resp);
}

void zero_native_gtk_emit_window_event(zero_native_gtk_host_t *host, uint64_t window_id, const char *name, size_t name_len, const char *detail_json, size_t detail_json_len) {
    zero_native_gtk_window_t *win = zero_native_find_window(host, window_id);
    if (!win || !win->web_view) return;
    char *event_name = zero_native_strndup(name, name_len);
    char *detail = zero_native_strndup(detail_json, detail_json_len);
    if (!event_name || !detail) {
        free(event_name);
        free(detail);
        return;
    }
    GString *script = g_string_new("window.zero&&window.zero._emit(");
    g_string_append_c(script, '"');
    for (const char *p = event_name; *p; p++) {
        if (*p == '"' || *p == '\\') g_string_append_c(script, '\\');
        g_string_append_c(script, *p);
    }
    g_string_append(script, "\",");
    g_string_append(script, detail[0] ? detail : "null");
    g_string_append(script, ");");
    webkit_web_view_evaluate_javascript(win->web_view, script->str, -1, NULL, NULL, NULL, NULL, NULL);
    g_string_free(script, TRUE);
    free(event_name);
    free(detail);
}

void zero_native_gtk_set_security_policy(zero_native_gtk_host_t *host, const char *allowed_origins, size_t allowed_origins_len, const char *external_urls, size_t external_urls_len, int external_action) {
    zero_native_free_string_list(host->allowed_origins, host->allowed_origins_count);
    zero_native_free_string_list(host->allowed_external_urls, host->allowed_external_urls_count);
    host->allowed_origins = zero_native_parse_newline_list(allowed_origins, allowed_origins_len, &host->allowed_origins_count);
    host->allowed_external_urls = zero_native_parse_newline_list(external_urls, external_urls_len, &host->allowed_external_urls_count);
    host->external_link_action = external_action;
}

void zero_native_gtk_set_shortcuts(zero_native_gtk_host_t *host, const char *const *ids, const size_t *id_lens, const char *const *keys, const size_t *key_lens, const uint32_t *modifiers, size_t count) {
    if (!host) return;
    zero_native_clear_shortcuts(host);
    if (!ids || !id_lens || !keys || !key_lens || !modifiers) return;
    size_t limit = count < ZERO_NATIVE_MAX_SHORTCUTS ? count : ZERO_NATIVE_MAX_SHORTCUTS;
    for (size_t i = 0; i < limit; i++) {
        if (!ids[i] || !keys[i] || id_lens[i] == 0 || key_lens[i] == 0) continue;
        zero_native_gtk_shortcut_t *shortcut = &host->shortcuts[host->shortcut_count];
        shortcut->id = zero_native_strndup(ids[i], id_lens[i]);
        shortcut->key = zero_native_strndup(keys[i], key_lens[i]);
        shortcut->modifiers = modifiers[i];
        if (!shortcut->id || !shortcut->key) {
            free(shortcut->id);
            free(shortcut->key);
            memset(shortcut, 0, sizeof(*shortcut));
            continue;
        }
        for (char *p = shortcut->key; *p; p++) {
            if (*p >= 'A' && *p <= 'Z') *p = (char)(*p - 'A' + 'a');
        }
        host->shortcut_count++;
    }
}

int zero_native_gtk_create_window(zero_native_gtk_host_t *host, uint64_t window_id, const char *window_title, size_t window_title_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame) {
    char *title = window_title_len > 0 ? zero_native_strndup(window_title, window_title_len) : NULL;
    char *label = window_label_len > 0 ? zero_native_strndup(window_label, window_label_len) : NULL;
    zero_native_gtk_window_t *win = zero_native_create_window_internal(host, window_id, title, label, x, y, width, height, restore_frame);
    free(title);
    free(label);
    if (!win) return 0;

    gtk_window_present(win->gtk_window);
    return 1;
}

int zero_native_gtk_focus_window(zero_native_gtk_host_t *host, uint64_t window_id) {
    zero_native_gtk_window_t *win = zero_native_find_window(host, window_id);
    if (!win || !win->gtk_window) return 0;
    gtk_window_present(win->gtk_window);
    zero_native_emit_window_frame(host, win, 1);
    return 1;
}

int zero_native_gtk_close_window(zero_native_gtk_host_t *host, uint64_t window_id) {
    zero_native_gtk_window_t *win = zero_native_find_window(host, window_id);
    if (!win || !win->gtk_window) return 0;
    gtk_window_close(win->gtk_window);
    return 1;
}

int zero_native_gtk_create_webview(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len, double x, double y, double width, double height, int layer, int transparent, int bridge_enabled) {
    zero_native_gtk_window_t *win = zero_native_find_window(host, window_id);
    if (!win || !win->stack_root || label_len == 0 || url_len == 0 || !zero_native_valid_webview_frame(x, y, width, height)) return 0;
    if (win->webview_count >= ZERO_NATIVE_MAX_WEBVIEWS) return 0;

    char *label_copy = zero_native_strndup(label, label_len);
    char *url_copy = zero_native_strndup(url, url_len);
    if (!label_copy || !url_copy) {
        free(label_copy);
        free(url_copy);
        return 0;
    }
    if (zero_native_find_webview(win, label_copy) || !zero_native_policy_list_matches(host->allowed_origins, host->allowed_origins_count, url_copy)) {
        free(label_copy);
        free(url_copy);
        return 0;
    }

    WebKitUserContentManager *manager = webkit_user_content_manager_new();
    if (bridge_enabled) {
        g_signal_connect(manager, "script-message-received::zeroNativeBridge", G_CALLBACK(on_bridge_message), win);
        webkit_user_content_manager_register_script_message_handler(manager, "zeroNativeBridge", NULL);
        WebKitUserScript *script = webkit_user_script_new(
            zero_native_bridge_script(),
            WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
            WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
            NULL, NULL);
        webkit_user_content_manager_add_script(manager, script);
        webkit_user_script_unref(script);
    }
    WebKitWebView *web_view = WEBKIT_WEB_VIEW(
        g_object_new(WEBKIT_TYPE_WEB_VIEW,
            "user-content-manager", manager,
            NULL));
    g_object_unref(manager);
    if (!web_view) {
        free(label_copy);
        free(url_copy);
        return 0;
    }

    zero_native_gtk_webview_t *webview = &win->webviews[win->webview_count++];
    memset(webview, 0, sizeof(*webview));
    webview->label = label_copy;
    webview->web_view = web_view;
    webview->x = x;
    webview->y = y;
    webview->width = width;
    webview->height = height;
    webview->layer = layer;
    webview->transparent = transparent != 0;
    webview->bridge_enabled = bridge_enabled != 0;
    webview->content_manager = manager;
    zero_native_apply_webview_frame(webview);
    gtk_overlay_add_overlay(GTK_OVERLAY(win->stack_root), GTK_WIDGET(web_view));
    if (transparent) {
        GdkRGBA transparent_color = {0, 0, 0, 0};
        webkit_web_view_set_background_color(web_view, &transparent_color);
    }
    zero_native_reorder_webviews(win);
    g_signal_connect(web_view, "decide-policy", G_CALLBACK(on_webview_decide_policy), win);
    webkit_web_view_load_uri(web_view, url_copy);
    free(url_copy);
    return 1;
}

int zero_native_gtk_set_webview_frame(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height) {
    zero_native_gtk_window_t *win = zero_native_find_window(host, window_id);
    char *label_copy = label_len > 0 ? zero_native_strndup(label, label_len) : NULL;
    if (label_copy && strcmp(label_copy, "main") == 0 && win && win->web_view && zero_native_valid_webview_frame(x, y, width, height)) {
        GtkWidget *widget = GTK_WIDGET(win->web_view);
        gtk_widget_set_halign(widget, GTK_ALIGN_START);
        gtk_widget_set_valign(widget, GTK_ALIGN_START);
        gtk_widget_set_margin_start(widget, zero_native_webview_coord(x));
        gtk_widget_set_margin_top(widget, zero_native_webview_coord(y));
        gtk_widget_set_size_request(widget, zero_native_webview_extent(width), zero_native_webview_extent(height));
        free(label_copy);
        return 1;
    }
    zero_native_gtk_webview_t *webview = zero_native_find_webview(win, label_copy);
    free(label_copy);
    if (!webview || !zero_native_valid_webview_frame(x, y, width, height)) return 0;
    webview->x = x;
    webview->y = y;
    webview->width = width;
    webview->height = height;
    zero_native_apply_webview_frame(webview);
    return 1;
}

int zero_native_gtk_navigate_webview(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len) {
    zero_native_gtk_window_t *win = zero_native_find_window(host, window_id);
    char *label_copy = label_len > 0 ? zero_native_strndup(label, label_len) : NULL;
    char *url_copy = url_len > 0 ? zero_native_strndup(url, url_len) : NULL;
    zero_native_gtk_webview_t *webview = zero_native_find_webview(win, label_copy);
    if (!webview || !url_copy || !zero_native_policy_list_matches(host->allowed_origins, host->allowed_origins_count, url_copy)) {
        free(label_copy);
        free(url_copy);
        return 0;
    }
    webkit_web_view_load_uri(webview->web_view, url_copy);
    free(label_copy);
    free(url_copy);
    return 1;
}

int zero_native_gtk_set_webview_zoom(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, double zoom) {
    zero_native_gtk_window_t *win = zero_native_find_window(host, window_id);
    char *label_copy = label_len > 0 ? zero_native_strndup(label, label_len) : NULL;
    if (label_copy && strcmp(label_copy, "main") == 0 && win && win->web_view && zoom >= 0.25 && zoom <= 5.0) {
        webkit_web_view_set_zoom_level(win->web_view, zoom);
        free(label_copy);
        return 1;
    }
    zero_native_gtk_webview_t *webview = zero_native_find_webview(win, label_copy);
    free(label_copy);
    if (!webview || !webview->web_view || zoom < 0.25 || zoom > 5.0) return 0;
    webkit_web_view_set_zoom_level(webview->web_view, zoom);
    return 1;
}

int zero_native_gtk_set_webview_layer(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, int layer) {
    zero_native_gtk_window_t *win = zero_native_find_window(host, window_id);
    char *label_copy = label_len > 0 ? zero_native_strndup(label, label_len) : NULL;
    if (label_copy && strcmp(label_copy, "main") == 0 && win && win->web_view) {
        free(label_copy);
        return 0;
    }
    zero_native_gtk_webview_t *webview = zero_native_find_webview(win, label_copy);
    free(label_copy);
    if (!webview || !webview->web_view) return 0;
    webview->layer = layer;
    zero_native_reorder_webviews(win);
    return 1;
}

int zero_native_gtk_close_webview(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    zero_native_gtk_window_t *win = zero_native_find_window(host, window_id);
    char *label_copy = label_len > 0 ? zero_native_strndup(label, label_len) : NULL;
    if (!win || !label_copy) {
        free(label_copy);
        return 0;
    }
    for (int i = 0; i < win->webview_count; i++) {
        if (win->webviews[i].label && strcmp(win->webviews[i].label, label_copy) == 0) {
            free(label_copy);
            zero_native_remove_webview_at(win, i);
            return 1;
        }
    }
    free(label_copy);
    return 0;
}

typedef struct zero_native_clipboard_read_state {
    GMainLoop *loop;
    char *text;
} zero_native_clipboard_read_state_t;

static void zero_native_clipboard_read_done(GObject *source, GAsyncResult *result, gpointer data) {
    zero_native_clipboard_read_state_t *state = data;
    GError *error = NULL;
    state->text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(source), result, &error);
    if (error) g_error_free(error);
    g_main_loop_quit(state->loop);
}

size_t zero_native_gtk_clipboard_read(zero_native_gtk_host_t *host, char *buffer, size_t buffer_len) {
    (void)host;
    GdkDisplay *display = gdk_display_get_default();
    if (!display) return 0;
    GdkClipboard *clipboard = gdk_display_get_clipboard(display);
    if (!clipboard) return 0;
    zero_native_clipboard_read_state_t state = {0};
    state.loop = g_main_loop_new(NULL, FALSE);
    if (!state.loop) return 0;
    gdk_clipboard_read_text_async(clipboard, NULL, zero_native_clipboard_read_done, &state);
    g_main_loop_run(state.loop);
    g_main_loop_unref(state.loop);
    if (!state.text) return 0;
    size_t len = strlen(state.text);
    size_t count = len < buffer_len ? len : buffer_len;
    memcpy(buffer, state.text, count);
    g_free(state.text);
    return count;
}

void zero_native_gtk_clipboard_write(zero_native_gtk_host_t *host, const char *text, size_t text_len) {
    (void)host;
    GdkDisplay *display = gdk_display_get_default();
    if (!display) return;
    GdkClipboard *clipboard = gdk_display_get_clipboard(display);
    if (!clipboard) return;
    char *copy = zero_native_strndup(text, text_len);
    if (!copy) return;
    gdk_clipboard_set_text(clipboard, copy);
    free(copy);
}

typedef struct zero_native_file_dialog_state {
    GMainLoop *loop;
    GListModel *files;
    GFile *file;
} zero_native_file_dialog_state_t;

static GtkWindow *zero_native_parent_window(zero_native_gtk_host_t *host) {
    for (int i = 0; i < host->window_count; i++) {
        if (host->windows[i].gtk_window) return host->windows[i].gtk_window;
    }
    return NULL;
}

static char *zero_native_bytes_to_string(const char *bytes, size_t len) {
    return bytes && len > 0 ? zero_native_strndup(bytes, len) : NULL;
}

static void zero_native_open_dialog_done(GObject *source, GAsyncResult *result, gpointer data) {
    zero_native_file_dialog_state_t *state = data;
    GError *error = NULL;
    state->files = gtk_file_dialog_open_multiple_finish(GTK_FILE_DIALOG(source), result, &error);
    if (error) g_error_free(error);
    g_main_loop_quit(state->loop);
}

static void zero_native_folder_dialog_done(GObject *source, GAsyncResult *result, gpointer data) {
    zero_native_file_dialog_state_t *state = data;
    GError *error = NULL;
    state->files = gtk_file_dialog_select_multiple_folders_finish(GTK_FILE_DIALOG(source), result, &error);
    if (error) g_error_free(error);
    g_main_loop_quit(state->loop);
}

static void zero_native_save_dialog_done(GObject *source, GAsyncResult *result, gpointer data) {
    zero_native_file_dialog_state_t *state = data;
    GError *error = NULL;
    state->file = gtk_file_dialog_save_finish(GTK_FILE_DIALOG(source), result, &error);
    if (error) g_error_free(error);
    g_main_loop_quit(state->loop);
}

zero_native_gtk_open_dialog_result_t zero_native_gtk_show_open_dialog(zero_native_gtk_host_t *host, const zero_native_gtk_open_dialog_opts_t *opts, char *buffer, size_t buffer_len) {
    zero_native_gtk_open_dialog_result_t result = {0};
    GtkFileDialog *dialog = gtk_file_dialog_new();
    char *title = zero_native_bytes_to_string(opts->title, opts->title_len);
    if (title) gtk_file_dialog_set_title(dialog, title);
    GtkWindow *parent = zero_native_parent_window(host);
    zero_native_file_dialog_state_t state = { .loop = g_main_loop_new(NULL, FALSE) };
    if (!state.loop) {
        if (title) free(title);
        g_object_unref(dialog);
        return result;
    }
    if (opts->allow_directories) {
        gtk_file_dialog_select_multiple_folders(dialog, parent, NULL, zero_native_folder_dialog_done, &state);
    } else {
        gtk_file_dialog_open_multiple(dialog, parent, NULL, zero_native_open_dialog_done, &state);
    }
    g_main_loop_run(state.loop);
    g_main_loop_unref(state.loop);
    if (state.files) {
        size_t offset = 0;
        guint count = g_list_model_get_n_items(state.files);
        for (guint i = 0; i < count; i++) {
            GFile *file = G_FILE(g_list_model_get_item(state.files, i));
            char *path = g_file_get_path(file);
            if (path) {
                size_t len = strlen(path);
                size_t needed = len + (result.count > 0 ? 1 : 0);
                if (offset + needed <= buffer_len) {
                    if (result.count > 0) buffer[offset++] = '\n';
                    memcpy(buffer + offset, path, len);
                    offset += len;
                    result.count++;
                }
                g_free(path);
            }
            g_object_unref(file);
        }
        result.bytes_written = offset;
        g_object_unref(state.files);
    }
    if (title) free(title);
    g_object_unref(dialog);
    return result;
}

size_t zero_native_gtk_show_save_dialog(zero_native_gtk_host_t *host, const zero_native_gtk_save_dialog_opts_t *opts, char *buffer, size_t buffer_len) {
    GtkFileDialog *dialog = gtk_file_dialog_new();
    char *title = zero_native_bytes_to_string(opts->title, opts->title_len);
    char *default_name = zero_native_bytes_to_string(opts->default_name, opts->default_name_len);
    if (title) gtk_file_dialog_set_title(dialog, title);
    if (default_name) gtk_file_dialog_set_initial_name(dialog, default_name);
    GtkWindow *parent = zero_native_parent_window(host);
    zero_native_file_dialog_state_t state = { .loop = g_main_loop_new(NULL, FALSE) };
    if (!state.loop) {
        if (title) free(title);
        if (default_name) free(default_name);
        g_object_unref(dialog);
        return 0;
    }
    gtk_file_dialog_save(dialog, parent, NULL, zero_native_save_dialog_done, &state);
    g_main_loop_run(state.loop);
    g_main_loop_unref(state.loop);
    size_t written = 0;
    if (state.file) {
        char *path = g_file_get_path(state.file);
        if (path) {
            size_t len = strlen(path);
            written = len < buffer_len ? len : buffer_len;
            memcpy(buffer, path, written);
            g_free(path);
        }
        g_object_unref(state.file);
    }
    if (title) free(title);
    if (default_name) free(default_name);
    g_object_unref(dialog);
    return written;
}

typedef struct zero_native_alert_state {
    GMainLoop *loop;
    int response;
} zero_native_alert_state_t;

static void zero_native_alert_done(GObject *source, GAsyncResult *result, gpointer data) {
    zero_native_alert_state_t *state = data;
    GError *error = NULL;
    state->response = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(source), result, &error);
    if (error) {
        g_error_free(error);
        state->response = 0;
    }
    g_main_loop_quit(state->loop);
}

int zero_native_gtk_show_message_dialog(zero_native_gtk_host_t *host, const zero_native_gtk_message_dialog_opts_t *opts) {
    GtkAlertDialog *dialog = gtk_alert_dialog_new(NULL);
    char *title = zero_native_bytes_to_string(opts->title, opts->title_len);
    char *message = zero_native_bytes_to_string(opts->message, opts->message_len);
    char *informative = zero_native_bytes_to_string(opts->informative_text, opts->informative_text_len);
    char *primary = zero_native_bytes_to_string(opts->primary_button, opts->primary_button_len);
    char *secondary = zero_native_bytes_to_string(opts->secondary_button, opts->secondary_button_len);
    char *tertiary = zero_native_bytes_to_string(opts->tertiary_button, opts->tertiary_button_len);
    gtk_alert_dialog_set_message(dialog, title ? title : (message ? message : ""));
    if (informative || (title && message)) gtk_alert_dialog_set_detail(dialog, informative ? informative : message);
    const char *buttons[4] = { primary ? primary : "OK", NULL, NULL, NULL };
    if (secondary) buttons[1] = secondary;
    if (tertiary) buttons[2] = tertiary;
    gtk_alert_dialog_set_buttons(dialog, buttons);
    zero_native_alert_state_t state = { .loop = g_main_loop_new(NULL, FALSE), .response = 0 };
    if (state.loop) {
        gtk_alert_dialog_choose(dialog, zero_native_parent_window(host), NULL, zero_native_alert_done, &state);
        g_main_loop_run(state.loop);
        g_main_loop_unref(state.loop);
    }
    if (title) free(title);
    if (message) free(message);
    if (informative) free(informative);
    if (primary) free(primary);
    if (secondary) free(secondary);
    if (tertiary) free(tertiary);
    g_object_unref(dialog);
    if (state.response <= 0) return 0;
    if (state.response == 1) return 1;
    return 2;
}
