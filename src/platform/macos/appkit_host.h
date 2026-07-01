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
    ZERO_NATIVE_APPKIT_EVENT_SHORTCUT = 5,
    ZERO_NATIVE_APPKIT_EVENT_NATIVE_COMMAND = 6,
    ZERO_NATIVE_APPKIT_EVENT_MENU_COMMAND = 7,
    ZERO_NATIVE_APPKIT_EVENT_APP_ACTIVATED = 8,
    ZERO_NATIVE_APPKIT_EVENT_APP_DEACTIVATED = 9,
    ZERO_NATIVE_APPKIT_EVENT_FILES_DROPPED = 10,
    ZERO_NATIVE_APPKIT_EVENT_GPU_SURFACE_FRAME = 11,
    ZERO_NATIVE_APPKIT_EVENT_GPU_SURFACE_RESIZE = 12,
    ZERO_NATIVE_APPKIT_EVENT_GPU_SURFACE_INPUT = 13,
    ZERO_NATIVE_APPKIT_EVENT_WIDGET_ACCESSIBILITY_ACTION = 14,
    ZERO_NATIVE_APPKIT_EVENT_APPEARANCE_CHANGED = 15,
} zero_native_appkit_event_kind_t;

typedef enum {
    ZERO_NATIVE_APPKIT_COLOR_SCHEME_LIGHT = 0,
    ZERO_NATIVE_APPKIT_COLOR_SCHEME_DARK = 1,
} zero_native_appkit_color_scheme_t;

typedef enum {
    ZERO_NATIVE_APPKIT_GPU_INPUT_POINTER_DOWN = 0,
    ZERO_NATIVE_APPKIT_GPU_INPUT_POINTER_UP = 1,
    ZERO_NATIVE_APPKIT_GPU_INPUT_POINTER_MOVE = 2,
    ZERO_NATIVE_APPKIT_GPU_INPUT_POINTER_DRAG = 3,
    ZERO_NATIVE_APPKIT_GPU_INPUT_SCROLL = 4,
    ZERO_NATIVE_APPKIT_GPU_INPUT_KEY_DOWN = 5,
    ZERO_NATIVE_APPKIT_GPU_INPUT_KEY_UP = 6,
    ZERO_NATIVE_APPKIT_GPU_INPUT_TEXT_INPUT = 7,
    ZERO_NATIVE_APPKIT_GPU_INPUT_IME_SET_COMPOSITION = 8,
    ZERO_NATIVE_APPKIT_GPU_INPUT_IME_COMMIT_COMPOSITION = 9,
    ZERO_NATIVE_APPKIT_GPU_INPUT_IME_CANCEL_COMPOSITION = 10,
    ZERO_NATIVE_APPKIT_GPU_INPUT_POINTER_CANCEL = 11,
} zero_native_appkit_gpu_input_kind_t;

typedef enum {
    ZERO_NATIVE_APPKIT_CURSOR_ARROW = 0,
    ZERO_NATIVE_APPKIT_CURSOR_POINTING_HAND = 1,
    ZERO_NATIVE_APPKIT_CURSOR_TEXT = 2,
    ZERO_NATIVE_APPKIT_CURSOR_RESIZE_HORIZONTAL = 3,
} zero_native_appkit_cursor_t;

typedef enum {
    ZERO_NATIVE_APPKIT_VIEW_WEBVIEW = 0,
    ZERO_NATIVE_APPKIT_VIEW_TOOLBAR = 1,
    ZERO_NATIVE_APPKIT_VIEW_TITLEBAR_ACCESSORY = 2,
    ZERO_NATIVE_APPKIT_VIEW_SIDEBAR = 3,
    ZERO_NATIVE_APPKIT_VIEW_STATUSBAR = 4,
    ZERO_NATIVE_APPKIT_VIEW_SPLIT = 5,
    ZERO_NATIVE_APPKIT_VIEW_STACK = 6,
    ZERO_NATIVE_APPKIT_VIEW_BUTTON = 7,
    ZERO_NATIVE_APPKIT_VIEW_TEXT_FIELD = 8,
    ZERO_NATIVE_APPKIT_VIEW_SEARCH_FIELD = 9,
    ZERO_NATIVE_APPKIT_VIEW_LABEL = 10,
    ZERO_NATIVE_APPKIT_VIEW_SPACER = 11,
    ZERO_NATIVE_APPKIT_VIEW_GPU_SURFACE = 12,
    ZERO_NATIVE_APPKIT_VIEW_CHECKBOX = 13,
    ZERO_NATIVE_APPKIT_VIEW_TOGGLE = 14,
    ZERO_NATIVE_APPKIT_VIEW_PROGRESS_INDICATOR = 15,
    ZERO_NATIVE_APPKIT_VIEW_SEGMENTED_CONTROL = 16,
    ZERO_NATIVE_APPKIT_VIEW_ICON_BUTTON = 17,
    ZERO_NATIVE_APPKIT_VIEW_LIST_ITEM = 18,
} zero_native_appkit_view_kind_t;

typedef enum {
    ZERO_NATIVE_APPKIT_WIDGET_ROLE_NONE = 0,
    ZERO_NATIVE_APPKIT_WIDGET_ROLE_GROUP = 1,
    ZERO_NATIVE_APPKIT_WIDGET_ROLE_TEXT = 2,
    ZERO_NATIVE_APPKIT_WIDGET_ROLE_IMAGE = 3,
    ZERO_NATIVE_APPKIT_WIDGET_ROLE_BUTTON = 4,
    ZERO_NATIVE_APPKIT_WIDGET_ROLE_TEXTBOX = 5,
    ZERO_NATIVE_APPKIT_WIDGET_ROLE_TOOLTIP = 6,
    ZERO_NATIVE_APPKIT_WIDGET_ROLE_DIALOG = 7,
    ZERO_NATIVE_APPKIT_WIDGET_ROLE_MENU = 8,
    ZERO_NATIVE_APPKIT_WIDGET_ROLE_MENUITEM = 9,
    ZERO_NATIVE_APPKIT_WIDGET_ROLE_LIST = 10,
    ZERO_NATIVE_APPKIT_WIDGET_ROLE_LISTITEM = 11,
    ZERO_NATIVE_APPKIT_WIDGET_ROLE_ROW = 12,
    ZERO_NATIVE_APPKIT_WIDGET_ROLE_GRID = 13,
    ZERO_NATIVE_APPKIT_WIDGET_ROLE_GRIDCELL = 14,
    ZERO_NATIVE_APPKIT_WIDGET_ROLE_TAB = 15,
    ZERO_NATIVE_APPKIT_WIDGET_ROLE_CHECKBOX = 16,
    ZERO_NATIVE_APPKIT_WIDGET_ROLE_SWITCH = 17,
    ZERO_NATIVE_APPKIT_WIDGET_ROLE_SLIDER = 18,
    ZERO_NATIVE_APPKIT_WIDGET_ROLE_PROGRESSBAR = 19,
    ZERO_NATIVE_APPKIT_WIDGET_ROLE_RADIO = 20,
} zero_native_appkit_widget_role_t;

enum {
    ZERO_NATIVE_APPKIT_WIDGET_STATE_ENABLED = 1u << 0,
    ZERO_NATIVE_APPKIT_WIDGET_STATE_FOCUSED = 1u << 1,
    ZERO_NATIVE_APPKIT_WIDGET_STATE_SELECTED = 1u << 2,
    ZERO_NATIVE_APPKIT_WIDGET_STATE_PRESSED = 1u << 3,
    ZERO_NATIVE_APPKIT_WIDGET_STATE_EXPANDED = 1u << 4,
    ZERO_NATIVE_APPKIT_WIDGET_STATE_COLLAPSED = 1u << 5,
    ZERO_NATIVE_APPKIT_WIDGET_STATE_REQUIRED = 1u << 6,
    ZERO_NATIVE_APPKIT_WIDGET_STATE_READ_ONLY = 1u << 7,
    ZERO_NATIVE_APPKIT_WIDGET_STATE_INVALID = 1u << 8,
};

enum {
    ZERO_NATIVE_APPKIT_WIDGET_ACTION_FOCUS = 1u << 0,
    ZERO_NATIVE_APPKIT_WIDGET_ACTION_PRESS = 1u << 1,
    ZERO_NATIVE_APPKIT_WIDGET_ACTION_TOGGLE = 1u << 2,
    ZERO_NATIVE_APPKIT_WIDGET_ACTION_INCREMENT = 1u << 3,
    ZERO_NATIVE_APPKIT_WIDGET_ACTION_DECREMENT = 1u << 4,
    ZERO_NATIVE_APPKIT_WIDGET_ACTION_SET_TEXT = 1u << 5,
    ZERO_NATIVE_APPKIT_WIDGET_ACTION_SET_SELECTION = 1u << 6,
    ZERO_NATIVE_APPKIT_WIDGET_ACTION_SELECT = 1u << 7,
    ZERO_NATIVE_APPKIT_WIDGET_ACTION_DRAG = 1u << 8,
    ZERO_NATIVE_APPKIT_WIDGET_ACTION_DROP_FILES = 1u << 9,
    ZERO_NATIVE_APPKIT_WIDGET_ACTION_DISMISS = 1u << 10,
};

typedef enum {
    ZERO_NATIVE_APPKIT_WIDGET_ACCESSIBILITY_ACTION_FOCUS = 0,
    ZERO_NATIVE_APPKIT_WIDGET_ACCESSIBILITY_ACTION_PRESS = 1,
    ZERO_NATIVE_APPKIT_WIDGET_ACCESSIBILITY_ACTION_TOGGLE = 2,
    ZERO_NATIVE_APPKIT_WIDGET_ACCESSIBILITY_ACTION_INCREMENT = 3,
    ZERO_NATIVE_APPKIT_WIDGET_ACCESSIBILITY_ACTION_DECREMENT = 4,
    ZERO_NATIVE_APPKIT_WIDGET_ACCESSIBILITY_ACTION_SET_TEXT = 5,
    ZERO_NATIVE_APPKIT_WIDGET_ACCESSIBILITY_ACTION_SET_SELECTION = 6,
    ZERO_NATIVE_APPKIT_WIDGET_ACCESSIBILITY_ACTION_SELECT = 7,
    ZERO_NATIVE_APPKIT_WIDGET_ACCESSIBILITY_ACTION_DRAG = 8,
    ZERO_NATIVE_APPKIT_WIDGET_ACCESSIBILITY_ACTION_DROP_FILES = 9,
    ZERO_NATIVE_APPKIT_WIDGET_ACCESSIBILITY_ACTION_DISMISS = 10,
} zero_native_appkit_widget_accessibility_action_t;

typedef struct {
    uint64_t id;
    int role;
    const char *label;
    size_t label_len;
    const char *text_value;
    size_t text_value_len;
    const char *placeholder;
    size_t placeholder_len;
    int has_text_selection;
    size_t text_selection_start;
    size_t text_selection_end;
    int has_text_composition;
    size_t text_composition_start;
    size_t text_composition_end;
    int has_value;
    double value;
    int has_grid_row_index;
    size_t grid_row_index;
    int has_grid_column_index;
    size_t grid_column_index;
    int has_grid_row_count;
    size_t grid_row_count;
    int has_grid_column_count;
    size_t grid_column_count;
    int has_list_item_index;
    uint32_t list_item_index;
    int has_list_item_count;
    uint32_t list_item_count;
    int has_scroll_offset;
    double scroll_offset;
    int has_scroll_viewport_extent;
    double scroll_viewport_extent;
    int has_scroll_content_extent;
    double scroll_content_extent;
    double x;
    double y;
    double width;
    double height;
    uint32_t state_flags;
    uint32_t action_flags;
} zero_native_appkit_widget_accessibility_node_t;

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
    const char *shortcut_id;
    size_t shortcut_id_len;
    const char *shortcut_key;
    size_t shortcut_key_len;
    uint32_t shortcut_modifiers;
    const char *command_name;
    size_t command_name_len;
    const char *view_label;
    size_t view_label_len;
    const char *key_text;
    size_t key_text_len;
    const char *input_text;
    size_t input_text_len;
    const char *drop_paths;
    size_t drop_paths_len;
    uint64_t frame_index;
    uint64_t timestamp_ns;
    uint64_t frame_interval_ns;
    int nonblank;
    uint32_t sample_color;
    int input_kind;
    int button;
    double delta_x;
    double delta_y;
    uint64_t widget_id;
    int widget_action;
    const char *widget_text;
    size_t widget_text_len;
    int has_widget_text_selection;
    size_t widget_text_selection_start;
    size_t widget_text_selection_end;
    int has_composition_cursor;
    size_t composition_cursor;
    int color_scheme;
    int reduce_motion;
    int high_contrast;
} zero_native_appkit_event_t;

typedef void (*zero_native_appkit_event_callback_t)(void *context, const zero_native_appkit_event_t *event);
typedef void (*zero_native_appkit_bridge_callback_t)(void *context, uint64_t window_id, const char *webview_label, size_t webview_label_len, const char *message, size_t message_len, const char *origin, size_t origin_len);

zero_native_appkit_host_t *zero_native_appkit_create(const char *app_name, size_t app_name_len, const char *window_title, size_t window_title_len, const char *bundle_id, size_t bundle_id_len, const char *icon_path, size_t icon_path_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame);
void zero_native_appkit_destroy(zero_native_appkit_host_t *host);
void zero_native_appkit_run(zero_native_appkit_host_t *host, zero_native_appkit_event_callback_t callback, void *context);
void zero_native_appkit_stop(zero_native_appkit_host_t *host);
void zero_native_appkit_load_webview(zero_native_appkit_host_t *host, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback);
void zero_native_appkit_load_window_webview(zero_native_appkit_host_t *host, uint64_t window_id, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback);
void zero_native_appkit_set_bridge_callback(zero_native_appkit_host_t *host, zero_native_appkit_bridge_callback_t callback, void *context);
void zero_native_appkit_bridge_respond(zero_native_appkit_host_t *host, const char *response, size_t response_len);
void zero_native_appkit_bridge_respond_window(zero_native_appkit_host_t *host, uint64_t window_id, const char *response, size_t response_len);
void zero_native_appkit_bridge_respond_webview(zero_native_appkit_host_t *host, uint64_t window_id, const char *webview_label, size_t webview_label_len, const char *response, size_t response_len);
void zero_native_appkit_emit_window_event(zero_native_appkit_host_t *host, uint64_t window_id, const char *name, size_t name_len, const char *detail_json, size_t detail_json_len);
void zero_native_appkit_set_security_policy(zero_native_appkit_host_t *host, const char *allowed_origins, size_t allowed_origins_len, const char *external_urls, size_t external_urls_len, int external_action);
void zero_native_appkit_set_menus(zero_native_appkit_host_t *host, const char *const *menu_titles, const size_t *menu_title_lens, size_t menu_count, const uint32_t *item_menu_indices, const char *const *item_labels, const size_t *item_label_lens, const char *const *item_commands, const size_t *item_command_lens, const char *const *item_keys, const size_t *item_key_lens, const uint32_t *item_modifiers, const int *item_separators, const int *item_enabled, const int *item_checked, size_t item_count);
void zero_native_appkit_set_shortcuts(zero_native_appkit_host_t *host, const char *const *ids, const size_t *id_lens, const char *const *keys, const size_t *key_lens, const uint32_t *modifiers, size_t count);
void zero_native_appkit_set_automation_frame_polling(zero_native_appkit_host_t *host, int enabled);
int zero_native_appkit_create_window(zero_native_appkit_host_t *host, uint64_t window_id, const char *window_title, size_t window_title_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame);
int zero_native_appkit_focus_window(zero_native_appkit_host_t *host, uint64_t window_id);
int zero_native_appkit_close_window(zero_native_appkit_host_t *host, uint64_t window_id);
int zero_native_appkit_create_view(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int kind, const char *parent, size_t parent_len, double x, double y, double width, double height, int layer, int visible, int enabled, const char *role, size_t role_len, const char *accessibility_label, size_t accessibility_label_len, const char *text, size_t text_len, const char *command, size_t command_len);
int zero_native_appkit_update_view(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int has_frame, double x, double y, double width, double height, int has_layer, int layer, int has_visible, int visible, int has_enabled, int enabled, int has_role, const char *role, size_t role_len, int has_accessibility_label, const char *accessibility_label, size_t accessibility_label_len, int has_text, const char *text, size_t text_len, int has_command, const char *command, size_t command_len);
int zero_native_appkit_set_view_frame(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height);
int zero_native_appkit_set_view_visible(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int visible);
int zero_native_appkit_set_view_cursor(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int cursor);
int zero_native_appkit_focus_view(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len);
int zero_native_appkit_close_view(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len);
int zero_native_appkit_present_gpu_surface_pixels(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, size_t width, size_t height, double scale, int has_dirty_rect, double dirty_x, double dirty_y, double dirty_width, double dirty_height, const uint8_t *rgba8, size_t rgba8_len);
int zero_native_appkit_present_gpu_surface_packet(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double surface_width, double surface_height, double scale, uint8_t clear_r, uint8_t clear_g, uint8_t clear_b, uint8_t clear_a, int requires_render, size_t command_count, size_t unsupported_command_count, int representable, const uint8_t *json, size_t json_len);
int zero_native_appkit_request_gpu_surface_frame(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len);
int zero_native_appkit_update_widget_accessibility(zero_native_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, const zero_native_appkit_widget_accessibility_node_t *nodes, size_t node_count);
size_t zero_native_appkit_clipboard_read(zero_native_appkit_host_t *host, char *buffer, size_t buffer_len);
void zero_native_appkit_clipboard_write(zero_native_appkit_host_t *host, const char *text, size_t text_len);
size_t zero_native_appkit_clipboard_read_data(zero_native_appkit_host_t *host, const char *mime_type, size_t mime_type_len, char *buffer, size_t buffer_len);
int zero_native_appkit_clipboard_write_data(zero_native_appkit_host_t *host, const char *mime_type, size_t mime_type_len, const char *bytes, size_t bytes_len);
int zero_native_appkit_show_notification(zero_native_appkit_host_t *host, const char *title, size_t title_len, const char *subtitle, size_t subtitle_len, const char *body, size_t body_len);
int zero_native_appkit_open_external_url(zero_native_appkit_host_t *host, const char *url, size_t url_len);
int zero_native_appkit_reveal_path(zero_native_appkit_host_t *host, const char *path, size_t path_len);
int zero_native_appkit_add_recent_document(zero_native_appkit_host_t *host, const char *path, size_t path_len);
int zero_native_appkit_clear_recent_documents(zero_native_appkit_host_t *host);
int zero_native_appkit_set_credential(zero_native_appkit_host_t *host, const char *service, size_t service_len, const char *account, size_t account_len, const char *secret, size_t secret_len);
size_t zero_native_appkit_get_credential(zero_native_appkit_host_t *host, const char *service, size_t service_len, const char *account, size_t account_len, char *buffer, size_t buffer_len);
int zero_native_appkit_delete_credential(zero_native_appkit_host_t *host, const char *service, size_t service_len, const char *account, size_t account_len);

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
