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
using BridgeCallback = void (*)(void *, uint64_t, const char *, size_t, const char *, size_t);

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

struct Host {
    std::string app_name;
    std::string window_title;
    EventCallback callback = nullptr;
    void *callback_context = nullptr;
    BridgeCallback bridge_callback = nullptr;
    void *bridge_context = nullptr;
    bool running = false;
    std::map<uint64_t, Window> windows;
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

} // namespace

extern "C" {

Host *zero_native_gtk_create(const char *app_name, size_t app_name_len, const char *window_title, size_t window_title_len, const char *bundle_id, size_t bundle_id_len, const char *icon_path, size_t icon_path_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame) {
    (void)bundle_id;
    (void)bundle_id_len;
    (void)icon_path;
    (void)icon_path_len;
    (void)restore_frame;
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

void zero_native_gtk_destroy(Host *host) {
    delete host;
}

void zero_native_gtk_run(Host *host, EventCallback callback, void *context) {
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

void zero_native_gtk_stop(Host *host) {
    if (host) host->running = false;
}

void zero_native_gtk_load_webview(Host *host, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback) {
    zero_native_gtk_load_window_webview(host, 1, source, source_len, source_kind, asset_root, asset_root_len, asset_entry, asset_entry_len, asset_origin, asset_origin_len, spa_fallback);
}

void zero_native_gtk_load_window_webview(Host *host, uint64_t window_id, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback) {
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

void zero_native_gtk_set_bridge_callback(Host *host, BridgeCallback callback, void *context) {
    if (!host) return;
    host->bridge_callback = callback;
    host->bridge_context = context;
}

void zero_native_gtk_bridge_respond(Host *host, const char *response, size_t response_len) {
    zero_native_gtk_bridge_respond_window(host, 1, response, response_len);
}

void zero_native_gtk_bridge_respond_window(Host *host, uint64_t window_id, const char *response, size_t response_len) {
    (void)host;
    (void)window_id;
    (void)response;
    (void)response_len;
}

void zero_native_gtk_emit_window_event(Host *host, uint64_t window_id, const char *name, size_t name_len, const char *detail_json, size_t detail_json_len) {
    (void)host;
    (void)window_id;
    (void)name;
    (void)name_len;
    (void)detail_json;
    (void)detail_json_len;
}

void zero_native_gtk_set_security_policy(Host *host, const char *allowed_origins, size_t allowed_origins_len, const char *external_urls, size_t external_urls_len, int external_action) {
    (void)host;
    (void)allowed_origins;
    (void)allowed_origins_len;
    (void)external_urls;
    (void)external_urls_len;
    (void)external_action;
}

void zero_native_gtk_register_resource_bytes(Host *host, const char *id, size_t id_len, const char *mime, size_t mime_len, const char *bytes, size_t bytes_len, int one_shot) {
    (void)host;
    (void)id;
    (void)id_len;
    (void)mime;
    (void)mime_len;
    (void)bytes;
    (void)bytes_len;
    (void)one_shot;
}

void zero_native_gtk_revoke_resource(Host *host, const char *id, size_t id_len) {
    (void)host;
    (void)id;
    (void)id_len;
}

int zero_native_gtk_create_window(Host *host, uint64_t window_id, const char *window_title, size_t window_title_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame) {
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
    host->windows[window_id] = window;
    emit(host, host->windows[window_id], kWindowFrame);
    return 1;
}

int zero_native_gtk_focus_window(Host *host, uint64_t window_id) {
    if (!host) return 0;
    auto found = host->windows.find(window_id);
    if (found == host->windows.end()) return 0;
    for (auto &entry : host->windows) entry.second.focused = false;
    found->second.focused = true;
    emit(host, found->second, kWindowFrame);
    return 1;
}

int zero_native_gtk_close_window(Host *host, uint64_t window_id) {
    if (!host) return 0;
    auto found = host->windows.find(window_id);
    if (found == host->windows.end()) return 0;
    found->second.open = false;
    emit(host, found->second, kWindowFrame);
    return 1;
}

size_t zero_native_gtk_clipboard_read(Host *host, char *buffer, size_t buffer_len) {
    (void)host;
    (void)buffer;
    (void)buffer_len;
    return 0;
}

void zero_native_gtk_clipboard_write(Host *host, const char *text, size_t text_len) {
    (void)host;
    (void)text;
    (void)text_len;
}

OpenDialogResult zero_native_gtk_show_open_dialog(Host *host, const void *opts, char *buffer, size_t buffer_len) {
    (void)host;
    (void)opts;
    (void)buffer;
    (void)buffer_len;
    return {};
}

size_t zero_native_gtk_show_save_dialog(Host *host, const void *opts, char *buffer, size_t buffer_len) {
    (void)host;
    (void)opts;
    (void)buffer;
    (void)buffer_len;
    return 0;
}

int zero_native_gtk_show_message_dialog(Host *host, const void *opts) {
    (void)host;
    (void)opts;
    return 0;
}

}
