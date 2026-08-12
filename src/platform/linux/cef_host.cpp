#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <map>
#include <string>

namespace {

enum EventKind {
    kStart = 0,
    kFrame = 1,
    kShutdown = 2,
    kResize = 3,
    kWindowFrame = 4,
};

struct GtkEvent {
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
};

struct OpenDialogResult {
    size_t count;
    size_t bytes_written;
};

using EventCallback = void (*)(void *, const GtkEvent *);
using BridgeCallback = void (*)(void *, uint64_t, const char *, size_t, const char *, size_t, const char *, size_t);

struct Window {
    uint64_t id = 1;
    std::string label;
    std::string title;
    double x = 0;
    double y = 0;
    double width = 720;
    double height = 480;
    bool open = true;
    bool focused = false;
};

struct ChildWebView {
    uint64_t window_id = 1;
    std::string label;
    std::string url;
    double x = 0;
    double y = 0;
    double width = 0;
    double height = 0;
    bool open = false;
};

struct Host {
    std::string app_name;
    std::string window_title;
    EventCallback callback = nullptr;
    void *callback_context = nullptr;
    BridgeCallback bridge_callback = nullptr;
    void *bridge_context = nullptr;
    bool running = false;
    std::map<uint64_t, Window> windows;
    std::map<std::string, ChildWebView> webviews;
};

static std::string slice(const char *bytes, size_t len) {
    return bytes && len > 0 ? std::string(bytes, len) : std::string();
}

static void emit(Host *host, const Window &window, EventKind kind) {
    if (!host || !host->callback) return;
    GtkEvent event = {};
    event.kind = kind;
    event.window_id = window.id;
    event.width = window.width;
    event.height = window.height;
    event.scale = 1.0;
    event.x = window.x;
    event.y = window.y;
    event.open = window.open ? 1 : 0;
    event.focused = window.focused ? 1 : 0;
    event.label = window.label.c_str();
    event.label_len = window.label.size();
    event.title = window.title.c_str();
    event.title_len = window.title.size();
    host->callback(host->callback_context, &event);
}

static std::string webViewKey(uint64_t window_id, const std::string &label) {
    return std::to_string(window_id) + ":" + label;
}

static bool validChildWebViewFrame(double x, double y, double width, double height) {
    return x >= 0 && y >= 0 && width > 0 && height > 0;
}

static void destroyChildWebViewsForWindow(Host *host, uint64_t window_id) {
    if (!host) return;
    for (auto it = host->webviews.begin(); it != host->webviews.end();) {
        if (it->second.window_id == window_id) {
            it = host->webviews.erase(it);
        } else {
            ++it;
        }
    }
}

} // namespace

extern "C" {

Host *native_sdk_gtk_create(const char *app_name, size_t app_name_len, const char *window_title, size_t window_title_len, const char *bundle_id, size_t bundle_id_len, const char *icon_path, size_t icon_path_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame, int resizable, int titlebar_style, double min_width, double min_height) {
    (void)bundle_id;
    (void)bundle_id_len;
    (void)icon_path;
    (void)icon_path_len;
    (void)restore_frame;
    (void)resizable;
    (void)titlebar_style;
    (void)min_width;
    (void)min_height;
    Host *host = new Host();
    host->app_name = slice(app_name, app_name_len);
    host->window_title = slice(window_title, window_title_len);
    Window window;
    window.id = 1;
    window.label = slice(window_label, window_label_len);
    window.title = host->window_title.empty() ? host->app_name : host->window_title;
    window.x = x;
    window.y = y;
    window.width = width;
    window.height = height;
    window.focused = true;
    host->windows[window.id] = window;
    return host;
}

void native_sdk_gtk_destroy(Host *host) {
    delete host;
}

void native_sdk_gtk_run(Host *host, EventCallback callback, void *context) {
    if (!host) return;
    host->callback = callback;
    host->callback_context = context;
    host->running = true;
    GtkEvent start = {};
    start.kind = kStart;
    start.window_id = 1;
    callback(context, &start);
    for (auto &entry : host->windows) {
        emit(host, entry.second, kResize);
        emit(host, entry.second, kWindowFrame);
    }
    for (int i = 0; host->running && i < 2; ++i) {
        for (auto &entry : host->windows) emit(host, entry.second, kFrame);
    }
    GtkEvent shutdown = {};
    shutdown.kind = kShutdown;
    shutdown.window_id = 1;
    callback(context, &shutdown);
}

void native_sdk_gtk_stop(Host *host) {
    if (host) host->running = false;
}

void native_sdk_gtk_load_webview(Host *host, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback) {
    native_sdk_gtk_load_window_webview(host, 1, source, source_len, source_kind, asset_root, asset_root_len, asset_entry, asset_entry_len, asset_origin, asset_origin_len, spa_fallback);
}

void native_sdk_gtk_load_window_webview(Host *host, uint64_t window_id, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback) {
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

void native_sdk_gtk_set_bridge_callback(Host *host, BridgeCallback callback, void *context) {
    if (!host) return;
    host->bridge_callback = callback;
    host->bridge_context = context;
}

void native_sdk_gtk_bridge_respond(Host *host, const char *response, size_t response_len) {
    native_sdk_gtk_bridge_respond_window(host, 1, response, response_len);
}

void native_sdk_gtk_bridge_respond_window(Host *host, uint64_t window_id, const char *response, size_t response_len) {
    (void)host;
    (void)window_id;
    (void)response;
    (void)response_len;
}

void native_sdk_gtk_bridge_respond_webview(Host *host, uint64_t window_id, const char *webview_label, size_t webview_label_len, const char *response, size_t response_len) {
    (void)host;
    (void)window_id;
    (void)webview_label;
    (void)webview_label_len;
    (void)response;
    (void)response_len;
}

void native_sdk_gtk_emit_window_event(Host *host, uint64_t window_id, const char *name, size_t name_len, const char *detail_json, size_t detail_json_len) {
    (void)host;
    (void)window_id;
    (void)name;
    (void)name_len;
    (void)detail_json;
    (void)detail_json_len;
}

void native_sdk_gtk_set_security_policy(Host *host, const char *allowed_origins, size_t allowed_origins_len, const char *external_urls, size_t external_urls_len, int external_action) {
    (void)host;
    (void)allowed_origins;
    (void)allowed_origins_len;
    (void)external_urls;
    (void)external_urls_len;
    (void)external_action;
}

void native_sdk_gtk_set_shortcuts(Host *host, const char *const *ids, const size_t *id_lens, const char *const *keys, const size_t *key_lens, const uint32_t *modifiers, size_t count) {
    (void)host;
    (void)ids;
    (void)id_lens;
    (void)keys;
    (void)key_lens;
    (void)modifiers;
    (void)count;
}

int native_sdk_gtk_create_window(Host *host, uint64_t window_id, const char *window_title, size_t window_title_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame, int resizable, int titlebar_style, double min_width, double min_height) {
    (void)restore_frame;
    (void)resizable;
    (void)titlebar_style;
    (void)min_width;
    (void)min_height;
    if (!host || host->windows.find(window_id) != host->windows.end()) return 0;
    Window window;
    window.id = window_id;
    window.title = slice(window_title, window_title_len);
    window.label = slice(window_label, window_label_len);
    window.x = x;
    window.y = y;
    window.width = width;
    window.height = height;
    host->windows[window_id] = window;
    emit(host, host->windows[window_id], kWindowFrame);
    return 1;
}

void native_sdk_gtk_start_timer(Host *host, uint64_t timer_id, uint64_t interval_ns, int repeats) {
    // Headless CEF tooling host: no main loop to schedule app timers on.
    (void)host;
    (void)timer_id;
    (void)interval_ns;
    (void)repeats;
}

void native_sdk_gtk_cancel_timer(Host *host, uint64_t timer_id) {
    (void)host;
    (void)timer_id;
}

int native_sdk_gtk_start_window_drag(Host *host, uint64_t window_id) {
    // Headless CEF tooling host: no windowing system to move a window
    // through, so the drag request reports "window not draggable".
    (void)host;
    (void)window_id;
    return 0;
}

int native_sdk_gtk_focus_window(Host *host, uint64_t window_id) {
    if (!host) return 0;
    auto found = host->windows.find(window_id);
    if (found == host->windows.end()) return 0;
    for (auto &entry : host->windows) entry.second.focused = false;
    found->second.focused = true;
    emit(host, found->second, kWindowFrame);
    return 1;
}

int native_sdk_gtk_close_window(Host *host, uint64_t window_id) {
    if (!host) return 0;
    auto found = host->windows.find(window_id);
    if (found == host->windows.end()) return 0;
    destroyChildWebViewsForWindow(host, window_id);
    found->second.open = false;
    emit(host, found->second, kWindowFrame);
    return 1;
}

int native_sdk_gtk_create_view(Host *host, uint64_t window_id, const char *label, size_t label_len, int kind, const char *parent, size_t parent_len, double x, double y, double width, double height, int layer, int visible, int enabled, const char *role, size_t role_len, const char *accessibility_label, size_t accessibility_label_len, const char *text, size_t text_len, const char *command, size_t command_len) {
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

int native_sdk_gtk_update_view(Host *host, uint64_t window_id, const char *label, size_t label_len, int has_frame, double x, double y, double width, double height, int has_layer, int layer, int has_visible, int visible, int has_enabled, int enabled, int has_role, const char *role, size_t role_len, int has_accessibility_label, const char *accessibility_label, size_t accessibility_label_len, int has_text, const char *text, size_t text_len, int has_command, const char *command, size_t command_len) {
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

int native_sdk_gtk_set_view_frame(Host *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height) {
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

int native_sdk_gtk_set_view_visible(Host *host, uint64_t window_id, const char *label, size_t label_len, int visible) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    (void)visible;
    return 0;
}

int native_sdk_gtk_focus_view(Host *host, uint64_t window_id, const char *label, size_t label_len) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    return 0;
}

int native_sdk_gtk_close_view(Host *host, uint64_t window_id, const char *label, size_t label_len) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    return 0;
}

int native_sdk_gtk_create_webview(Host *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len, double x, double y, double width, double height, int layer, int transparent, int bridge_enabled) {
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
}

int native_sdk_gtk_set_webview_frame(Host *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height) {
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

int native_sdk_gtk_navigate_webview(Host *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    (void)url;
    (void)url_len;
    return 0;
}

int native_sdk_gtk_set_webview_zoom(Host *host, uint64_t window_id, const char *label, size_t label_len, double zoom) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    (void)zoom;
    return 0;
}

int native_sdk_gtk_set_webview_layer(Host *host, uint64_t window_id, const char *label, size_t label_len, int layer) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    (void)layer;
    return 0;
}

int native_sdk_gtk_close_webview(Host *host, uint64_t window_id, const char *label, size_t label_len) {
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    return 0;
}

int native_sdk_gtk_open_external_url(Host *host, const char *url, size_t url_len) {
    (void)host;
    (void)url;
    (void)url_len;
    return 0;
}

int native_sdk_gtk_reveal_path(Host *host, const char *path, size_t path_len) {
    (void)host;
    (void)path;
    (void)path_len;
    return 0;
}

int native_sdk_gtk_show_notification(Host *host, const char *title, size_t title_len, const char *subtitle, size_t subtitle_len, const char *body, size_t body_len) {
    (void)host;
    (void)title;
    (void)title_len;
    (void)subtitle;
    (void)subtitle_len;
    (void)body;
    (void)body_len;
    return 0;
}

int native_sdk_gtk_add_recent_document(Host *host, const char *path, size_t path_len) {
    (void)host;
    (void)path;
    (void)path_len;
    return 0;
}

int native_sdk_gtk_clear_recent_documents(Host *host) {
    (void)host;
    return 0;
}

int native_sdk_gtk_credentials_available(Host *host) {
    (void)host;
    return 0;
}

int native_sdk_gtk_set_credential(Host *host, const char *service, size_t service_len, const char *account, size_t account_len, const char *secret, size_t secret_len) {
    (void)host;
    (void)service;
    (void)service_len;
    (void)account;
    (void)account_len;
    (void)secret;
    (void)secret_len;
    return 0;
}

size_t native_sdk_gtk_get_credential(Host *host, const char *service, size_t service_len, const char *account, size_t account_len, char *buffer, size_t buffer_len) {
    (void)host;
    (void)service;
    (void)service_len;
    (void)account;
    (void)account_len;
    (void)buffer;
    (void)buffer_len;
    return SIZE_MAX - 1;
}

int native_sdk_gtk_delete_credential(Host *host, const char *service, size_t service_len, const char *account, size_t account_len) {
    (void)host;
    (void)service;
    (void)service_len;
    (void)account;
    (void)account_len;
    return 0;
}

size_t native_sdk_gtk_clipboard_read(Host *host, char *buffer, size_t buffer_len) {
    (void)host;
    (void)buffer;
    (void)buffer_len;
    return 0;
}

void native_sdk_gtk_clipboard_write(Host *host, const char *text, size_t text_len) {
    (void)host;
    (void)text;
    (void)text_len;
}

size_t native_sdk_gtk_clipboard_read_data(Host *host, const char *mime_type, size_t mime_type_len, char *buffer, size_t buffer_len) {
    (void)host;
    (void)mime_type;
    (void)mime_type_len;
    (void)buffer;
    (void)buffer_len;
    return 0;
}

int native_sdk_gtk_clipboard_write_data(Host *host, const char *mime_type, size_t mime_type_len, const char *bytes, size_t bytes_len) {
    (void)host;
    (void)mime_type;
    (void)mime_type_len;
    (void)bytes;
    (void)bytes_len;
    return 0;
}

OpenDialogResult native_sdk_gtk_show_open_dialog(Host *host, const void *opts, char *buffer, size_t buffer_len) {
    (void)host;
    (void)opts;
    (void)buffer;
    (void)buffer_len;
    return {};
}

size_t native_sdk_gtk_show_save_dialog(Host *host, const void *opts, char *buffer, size_t buffer_len) {
    (void)host;
    (void)opts;
    (void)buffer;
    (void)buffer_len;
    return 0;
}

int native_sdk_gtk_show_message_dialog(Host *host, const void *opts) {
    (void)host;
    (void)opts;
    return 0;
}

}
