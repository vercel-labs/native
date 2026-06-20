#ifndef ZERO_NATIVE_APPKIT_HOST_H
#define ZERO_NATIVE_APPKIT_HOST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct zero_native_appkit_host zero_native_appkit_host_t;

typedef enum {
    ZERO_NATIVE_APPKIT_EVENT_START = 0,
    ZERO_NATIVE_APPKIT_EVENT_FRAME = 1,
    ZERO_NATIVE_APPKIT_EVENT_SHUTDOWN = 2,
    ZERO_NATIVE_APPKIT_EVENT_RESIZE = 3,
    ZERO_NATIVE_APPKIT_EVENT_WINDOW_FRAME = 4,
} zero_native_appkit_event_kind_t;

typedef struct {
    zero_native_appkit_event_kind_t kind;
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
} zero_native_appkit_event_t;

typedef void (*zero_native_appkit_event_callback_t)(void *context, const zero_native_appkit_event_t *event);
typedef void (*zero_native_appkit_bridge_callback_t)(void *context, uint64_t window_id, const char *message, size_t message_len, const char *origin, size_t origin_len);

zero_native_appkit_host_t *zero_native_appkit_create(const char *app_name, size_t app_name_len, const char *window_title, size_t window_title_len, const char *bundle_id, size_t bundle_id_len, const char *icon_path, size_t icon_path_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame);
void zero_native_appkit_destroy(zero_native_appkit_host_t *host);
void zero_native_appkit_run(zero_native_appkit_host_t *host, zero_native_appkit_event_callback_t callback, void *context);
void zero_native_appkit_stop(zero_native_appkit_host_t *host);
void zero_native_appkit_load_webview(zero_native_appkit_host_t *host, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback);
void zero_native_appkit_load_window_webview(zero_native_appkit_host_t *host, uint64_t window_id, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback);
void zero_native_appkit_set_bridge_callback(zero_native_appkit_host_t *host, zero_native_appkit_bridge_callback_t callback, void *context);
void zero_native_appkit_bridge_respond(zero_native_appkit_host_t *host, const char *response, size_t response_len);
void zero_native_appkit_bridge_respond_window(zero_native_appkit_host_t *host, uint64_t window_id, const char *response, size_t response_len);
void zero_native_appkit_emit_window_event(zero_native_appkit_host_t *host, uint64_t window_id, const char *name, size_t name_len, const char *detail_json, size_t detail_json_len);
void zero_native_appkit_set_security_policy(zero_native_appkit_host_t *host, const char *allowed_origins, size_t allowed_origins_len, const char *external_urls, size_t external_urls_len, int external_action);
int zero_native_appkit_create_window(zero_native_appkit_host_t *host, uint64_t window_id, const char *window_title, size_t window_title_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame);
int zero_native_appkit_focus_window(zero_native_appkit_host_t *host, uint64_t window_id);
int zero_native_appkit_close_window(zero_native_appkit_host_t *host, uint64_t window_id);
size_t zero_native_appkit_clipboard_read(zero_native_appkit_host_t *host, char *buffer, size_t buffer_len);
void zero_native_appkit_clipboard_write(zero_native_appkit_host_t *host, const char *text, size_t text_len);

typedef struct {
    const char *title;
    size_t title_len;
    const char *default_path;
    size_t default_path_len;
    const char *extensions;
    size_t extensions_len;
    int allow_directories;
    int allow_multiple;
} zero_native_appkit_open_dialog_opts_t;

typedef struct {
    size_t count;
    size_t bytes_written;
} zero_native_appkit_open_dialog_result_t;

typedef struct {
    const char *title;
    size_t title_len;
    const char *default_path;
    size_t default_path_len;
    const char *default_name;
    size_t default_name_len;
    const char *extensions;
    size_t extensions_len;
} zero_native_appkit_save_dialog_opts_t;

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
} zero_native_appkit_message_dialog_opts_t;

typedef void (*zero_native_appkit_http_fetch_callback_t)(void *ctx, int status, const char *json_utf8, size_t json_len);

void zero_native_appkit_http_fetch_async(zero_native_appkit_host_t *host, const char *url, size_t url_len, zero_native_appkit_http_fetch_callback_t callback, void *ctx);

typedef void (*zero_native_appkit_tray_callback_t)(void *context, uint32_t item_id);

zero_native_appkit_open_dialog_result_t zero_native_appkit_show_open_dialog(zero_native_appkit_host_t *host, const zero_native_appkit_open_dialog_opts_t *opts, char *buffer, size_t buffer_len);
size_t zero_native_appkit_show_save_dialog(zero_native_appkit_host_t *host, const zero_native_appkit_save_dialog_opts_t *opts, char *buffer, size_t buffer_len);
int zero_native_appkit_show_message_dialog(zero_native_appkit_host_t *host, const zero_native_appkit_message_dialog_opts_t *opts);
void zero_native_appkit_create_tray(zero_native_appkit_host_t *host, const char *icon_path, size_t icon_path_len, const char *tooltip, size_t tooltip_len);
void zero_native_appkit_update_tray_menu(zero_native_appkit_host_t *host, const uint32_t *item_ids, const char *const *labels, const size_t *label_lens, const int *separators, const int *enabled_flags, size_t count);
void zero_native_appkit_remove_tray(zero_native_appkit_host_t *host);
void zero_native_appkit_set_tray_callback(zero_native_appkit_host_t *host, zero_native_appkit_tray_callback_t callback, void *context);

#ifdef __cplusplus
}
#endif

#endif
