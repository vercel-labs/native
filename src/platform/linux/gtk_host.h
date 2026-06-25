#ifndef ZERO_NATIVE_GTK_HOST_H
#define ZERO_NATIVE_GTK_HOST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct zero_native_gtk_host zero_native_gtk_host_t;

typedef enum {
    ZERO_NATIVE_GTK_EVENT_START = 0,
    ZERO_NATIVE_GTK_EVENT_FRAME = 1,
    ZERO_NATIVE_GTK_EVENT_SHUTDOWN = 2,
    ZERO_NATIVE_GTK_EVENT_RESIZE = 3,
    ZERO_NATIVE_GTK_EVENT_WINDOW_FRAME = 4,
    ZERO_NATIVE_GTK_EVENT_SHORTCUT = 5,
    ZERO_NATIVE_GTK_EVENT_NATIVE_COMMAND = 6,
} zero_native_gtk_event_kind_t;

typedef struct {
    zero_native_gtk_event_kind_t kind;
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
    const char *command_name;
    size_t command_name_len;
    const char *view_label;
    size_t view_label_len;
} zero_native_gtk_event_t;

typedef void (*zero_native_gtk_event_callback_t)(void *context, const zero_native_gtk_event_t *event);
typedef void (*zero_native_gtk_bridge_callback_t)(void *context, uint64_t window_id, const char *webview_label, size_t webview_label_len, const char *message, size_t message_len, const char *origin, size_t origin_len);

typedef struct {
    const char *title;
    size_t title_len;
    const char *default_path;
    size_t default_path_len;
    const char *extensions;
    size_t extensions_len;
    int allow_directories;
    int allow_multiple;
} zero_native_gtk_open_dialog_opts_t;

typedef struct {
    size_t count;
    size_t bytes_written;
} zero_native_gtk_open_dialog_result_t;

typedef struct {
    const char *title;
    size_t title_len;
    const char *default_path;
    size_t default_path_len;
    const char *default_name;
    size_t default_name_len;
    const char *extensions;
    size_t extensions_len;
} zero_native_gtk_save_dialog_opts_t;

typedef struct {
    int style;
    const char *title;
    size_t title_len;
    const char *message;
    size_t message_len;
    const char *informative_text;
    size_t informative_text_len;
    const char *primary_button;
    size_t primary_button_len;
    const char *secondary_button;
    size_t secondary_button_len;
    const char *tertiary_button;
    size_t tertiary_button_len;
} zero_native_gtk_message_dialog_opts_t;

zero_native_gtk_host_t *zero_native_gtk_create(const char *app_name, size_t app_name_len, const char *window_title, size_t window_title_len, const char *bundle_id, size_t bundle_id_len, const char *icon_path, size_t icon_path_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame);
void zero_native_gtk_destroy(zero_native_gtk_host_t *host);
void zero_native_gtk_run(zero_native_gtk_host_t *host, zero_native_gtk_event_callback_t callback, void *context);
void zero_native_gtk_stop(zero_native_gtk_host_t *host);
void zero_native_gtk_load_webview(zero_native_gtk_host_t *host, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback);
void zero_native_gtk_load_window_webview(zero_native_gtk_host_t *host, uint64_t window_id, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback);
void zero_native_gtk_set_bridge_callback(zero_native_gtk_host_t *host, zero_native_gtk_bridge_callback_t callback, void *context);
void zero_native_gtk_bridge_respond(zero_native_gtk_host_t *host, const char *response, size_t response_len);
void zero_native_gtk_bridge_respond_window(zero_native_gtk_host_t *host, uint64_t window_id, const char *response, size_t response_len);
void zero_native_gtk_bridge_respond_webview(zero_native_gtk_host_t *host, uint64_t window_id, const char *webview_label, size_t webview_label_len, const char *response, size_t response_len);
void zero_native_gtk_emit_window_event(zero_native_gtk_host_t *host, uint64_t window_id, const char *name, size_t name_len, const char *detail_json, size_t detail_json_len);
void zero_native_gtk_set_security_policy(zero_native_gtk_host_t *host, const char *allowed_origins, size_t allowed_origins_len, const char *external_urls, size_t external_urls_len, int external_action);
void zero_native_gtk_set_shortcuts(zero_native_gtk_host_t *host, const char *const *ids, const size_t *id_lens, const char *const *keys, const size_t *key_lens, const uint32_t *modifiers, size_t count);
int zero_native_gtk_create_window(zero_native_gtk_host_t *host, uint64_t window_id, const char *window_title, size_t window_title_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame);
int zero_native_gtk_focus_window(zero_native_gtk_host_t *host, uint64_t window_id);
int zero_native_gtk_close_window(zero_native_gtk_host_t *host, uint64_t window_id);
int zero_native_gtk_create_view(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, int kind, const char *parent, size_t parent_len, double x, double y, double width, double height, int layer, int visible, int enabled, const char *role, size_t role_len, const char *text, size_t text_len, const char *command, size_t command_len);
int zero_native_gtk_update_view(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, int has_frame, double x, double y, double width, double height, int has_layer, int layer, int has_visible, int visible, int has_enabled, int enabled, int has_role, const char *role, size_t role_len, int has_text, const char *text, size_t text_len, int has_command, const char *command, size_t command_len);
int zero_native_gtk_set_view_frame(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height);
int zero_native_gtk_set_view_visible(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, int visible);
int zero_native_gtk_focus_view(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len);
int zero_native_gtk_close_view(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len);
int zero_native_gtk_create_webview(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len, double x, double y, double width, double height, int layer, int transparent, int bridge_enabled);
int zero_native_gtk_set_webview_frame(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height);
int zero_native_gtk_navigate_webview(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len);
int zero_native_gtk_set_webview_zoom(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, double zoom);
int zero_native_gtk_set_webview_layer(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, int layer);
int zero_native_gtk_close_webview(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len);
size_t zero_native_gtk_clipboard_read(zero_native_gtk_host_t *host, char *buffer, size_t buffer_len);
void zero_native_gtk_clipboard_write(zero_native_gtk_host_t *host, const char *text, size_t text_len);
zero_native_gtk_open_dialog_result_t zero_native_gtk_show_open_dialog(zero_native_gtk_host_t *host, const zero_native_gtk_open_dialog_opts_t *opts, char *buffer, size_t buffer_len);
size_t zero_native_gtk_show_save_dialog(zero_native_gtk_host_t *host, const zero_native_gtk_save_dialog_opts_t *opts, char *buffer, size_t buffer_len);
int zero_native_gtk_show_message_dialog(zero_native_gtk_host_t *host, const zero_native_gtk_message_dialog_opts_t *opts);

#ifdef __cplusplus
}
#endif

#endif
