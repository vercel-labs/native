#ifndef NATIVE_SDK_APPKIT_HOST_H
#define NATIVE_SDK_APPKIT_HOST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct native_sdk_appkit_host native_sdk_appkit_host_t;

typedef enum {
    NATIVE_SDK_APPKIT_EVENT_START = 0,
    NATIVE_SDK_APPKIT_EVENT_FRAME = 1,
    NATIVE_SDK_APPKIT_EVENT_SHUTDOWN = 2,
    NATIVE_SDK_APPKIT_EVENT_RESIZE = 3,
    NATIVE_SDK_APPKIT_EVENT_WINDOW_FRAME = 4,
    NATIVE_SDK_APPKIT_EVENT_SHORTCUT = 5,
    NATIVE_SDK_APPKIT_EVENT_NATIVE_COMMAND = 6,
    NATIVE_SDK_APPKIT_EVENT_MENU_COMMAND = 7,
    NATIVE_SDK_APPKIT_EVENT_APP_ACTIVATED = 8,
    NATIVE_SDK_APPKIT_EVENT_APP_DEACTIVATED = 9,
    NATIVE_SDK_APPKIT_EVENT_FILES_DROPPED = 10,
    NATIVE_SDK_APPKIT_EVENT_GPU_SURFACE_FRAME = 11,
    NATIVE_SDK_APPKIT_EVENT_GPU_SURFACE_RESIZE = 12,
    NATIVE_SDK_APPKIT_EVENT_GPU_SURFACE_INPUT = 13,
    NATIVE_SDK_APPKIT_EVENT_WIDGET_ACCESSIBILITY_ACTION = 14,
    NATIVE_SDK_APPKIT_EVENT_APPEARANCE_CHANGED = 15,
    NATIVE_SDK_APPKIT_EVENT_TIMER = 16,
    NATIVE_SDK_APPKIT_EVENT_WAKE = 17,
    NATIVE_SDK_APPKIT_EVENT_GPU_SURFACE_SCROLL_DRIVER = 18,
    NATIVE_SDK_APPKIT_EVENT_CONTEXT_MENU_ACTION = 19,
    NATIVE_SDK_APPKIT_EVENT_AUDIO = 20,
} native_sdk_appkit_event_kind_t;

/* Audio player reports (EVENT_AUDIO payloads). LOADED acknowledges a
 * successful native_sdk_appkit_audio_load (or a ready URL stream) with
 * the decoded duration; POSITION ticks at a coarse honest cadence
 * (~500ms) only while playing; COMPLETED fires exactly once at a
 * track's natural end; FAILED reports an asynchronous decode/device
 * failure — or a network failure that killed a stream mid-flight.
 * SPECTRUM carries a real band-magnitude analysis of the audio the
 * player is producing (audio_bands below) at a steady ~25 Hz, only
 * while audio is audibly playing — pause, stop, and a buffering stall
 * starve it. Ordinals are mirrored by the Zig side
 * (audioEventKindFromInt). */
typedef enum {
    NATIVE_SDK_APPKIT_AUDIO_EVENT_LOADED = 0,
    NATIVE_SDK_APPKIT_AUDIO_EVENT_POSITION = 1,
    NATIVE_SDK_APPKIT_AUDIO_EVENT_COMPLETED = 2,
    NATIVE_SDK_APPKIT_AUDIO_EVENT_FAILED = 3,
    NATIVE_SDK_APPKIT_AUDIO_EVENT_SPECTRUM = 4,
} native_sdk_appkit_audio_event_kind_t;

/* How many band magnitudes every SPECTRUM report carries: 32 buckets
 * with log-spaced center frequencies covering roughly 50 Hz..16 kHz.
 * Part of the event ABI — the Zig side binds the array by this count. */
#define NATIVE_SDK_APPKIT_AUDIO_SPECTRUM_BANDS 32

typedef enum {
    NATIVE_SDK_APPKIT_COLOR_SCHEME_LIGHT = 0,
    NATIVE_SDK_APPKIT_COLOR_SCHEME_DARK = 1,
} native_sdk_appkit_color_scheme_t;

typedef enum {
    NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_DOWN = 0,
    NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_UP = 1,
    NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_MOVE = 2,
    NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_DRAG = 3,
    NATIVE_SDK_APPKIT_GPU_INPUT_SCROLL = 4,
    NATIVE_SDK_APPKIT_GPU_INPUT_KEY_DOWN = 5,
    NATIVE_SDK_APPKIT_GPU_INPUT_KEY_UP = 6,
    NATIVE_SDK_APPKIT_GPU_INPUT_TEXT_INPUT = 7,
    NATIVE_SDK_APPKIT_GPU_INPUT_IME_SET_COMPOSITION = 8,
    NATIVE_SDK_APPKIT_GPU_INPUT_IME_COMMIT_COMPOSITION = 9,
    NATIVE_SDK_APPKIT_GPU_INPUT_IME_CANCEL_COMPOSITION = 10,
    NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_CANCEL = 11,
} native_sdk_appkit_gpu_input_kind_t;

typedef enum {
    NATIVE_SDK_APPKIT_CURSOR_ARROW = 0,
    NATIVE_SDK_APPKIT_CURSOR_POINTING_HAND = 1,
    NATIVE_SDK_APPKIT_CURSOR_TEXT = 2,
    NATIVE_SDK_APPKIT_CURSOR_RESIZE_HORIZONTAL = 3,
} native_sdk_appkit_cursor_t;

typedef enum {
    NATIVE_SDK_APPKIT_VIEW_WEBVIEW = 0,
    NATIVE_SDK_APPKIT_VIEW_TOOLBAR = 1,
    NATIVE_SDK_APPKIT_VIEW_TITLEBAR_ACCESSORY = 2,
    NATIVE_SDK_APPKIT_VIEW_SIDEBAR = 3,
    NATIVE_SDK_APPKIT_VIEW_STATUSBAR = 4,
    NATIVE_SDK_APPKIT_VIEW_SPLIT = 5,
    NATIVE_SDK_APPKIT_VIEW_STACK = 6,
    NATIVE_SDK_APPKIT_VIEW_BUTTON = 7,
    NATIVE_SDK_APPKIT_VIEW_TEXT_FIELD = 8,
    NATIVE_SDK_APPKIT_VIEW_SEARCH_FIELD = 9,
    NATIVE_SDK_APPKIT_VIEW_LABEL = 10,
    NATIVE_SDK_APPKIT_VIEW_SPACER = 11,
    NATIVE_SDK_APPKIT_VIEW_GPU_SURFACE = 12,
    NATIVE_SDK_APPKIT_VIEW_CHECKBOX = 13,
    NATIVE_SDK_APPKIT_VIEW_TOGGLE = 14,
    NATIVE_SDK_APPKIT_VIEW_PROGRESS_INDICATOR = 15,
    NATIVE_SDK_APPKIT_VIEW_SEGMENTED_CONTROL = 16,
    NATIVE_SDK_APPKIT_VIEW_ICON_BUTTON = 17,
    NATIVE_SDK_APPKIT_VIEW_LIST_ITEM = 18,
} native_sdk_appkit_view_kind_t;

typedef enum {
    NATIVE_SDK_APPKIT_WIDGET_ROLE_NONE = 0,
    NATIVE_SDK_APPKIT_WIDGET_ROLE_GROUP = 1,
    NATIVE_SDK_APPKIT_WIDGET_ROLE_TEXT = 2,
    NATIVE_SDK_APPKIT_WIDGET_ROLE_IMAGE = 3,
    NATIVE_SDK_APPKIT_WIDGET_ROLE_BUTTON = 4,
    NATIVE_SDK_APPKIT_WIDGET_ROLE_TEXTBOX = 5,
    NATIVE_SDK_APPKIT_WIDGET_ROLE_TOOLTIP = 6,
    NATIVE_SDK_APPKIT_WIDGET_ROLE_DIALOG = 7,
    NATIVE_SDK_APPKIT_WIDGET_ROLE_MENU = 8,
    NATIVE_SDK_APPKIT_WIDGET_ROLE_MENUITEM = 9,
    NATIVE_SDK_APPKIT_WIDGET_ROLE_LIST = 10,
    NATIVE_SDK_APPKIT_WIDGET_ROLE_LISTITEM = 11,
    NATIVE_SDK_APPKIT_WIDGET_ROLE_ROW = 12,
    NATIVE_SDK_APPKIT_WIDGET_ROLE_GRID = 13,
    NATIVE_SDK_APPKIT_WIDGET_ROLE_GRIDCELL = 14,
    NATIVE_SDK_APPKIT_WIDGET_ROLE_TAB = 15,
    NATIVE_SDK_APPKIT_WIDGET_ROLE_CHECKBOX = 16,
    NATIVE_SDK_APPKIT_WIDGET_ROLE_SWITCH = 17,
    NATIVE_SDK_APPKIT_WIDGET_ROLE_SLIDER = 18,
    NATIVE_SDK_APPKIT_WIDGET_ROLE_PROGRESSBAR = 19,
    NATIVE_SDK_APPKIT_WIDGET_ROLE_RADIO = 20,
} native_sdk_appkit_widget_role_t;

enum {
    NATIVE_SDK_APPKIT_WIDGET_STATE_ENABLED = 1u << 0,
    NATIVE_SDK_APPKIT_WIDGET_STATE_FOCUSED = 1u << 1,
    NATIVE_SDK_APPKIT_WIDGET_STATE_SELECTED = 1u << 2,
    NATIVE_SDK_APPKIT_WIDGET_STATE_PRESSED = 1u << 3,
    NATIVE_SDK_APPKIT_WIDGET_STATE_EXPANDED = 1u << 4,
    NATIVE_SDK_APPKIT_WIDGET_STATE_COLLAPSED = 1u << 5,
    NATIVE_SDK_APPKIT_WIDGET_STATE_REQUIRED = 1u << 6,
    NATIVE_SDK_APPKIT_WIDGET_STATE_READ_ONLY = 1u << 7,
    NATIVE_SDK_APPKIT_WIDGET_STATE_INVALID = 1u << 8,
};

enum {
    NATIVE_SDK_APPKIT_WIDGET_ACTION_FOCUS = 1u << 0,
    NATIVE_SDK_APPKIT_WIDGET_ACTION_PRESS = 1u << 1,
    NATIVE_SDK_APPKIT_WIDGET_ACTION_TOGGLE = 1u << 2,
    NATIVE_SDK_APPKIT_WIDGET_ACTION_INCREMENT = 1u << 3,
    NATIVE_SDK_APPKIT_WIDGET_ACTION_DECREMENT = 1u << 4,
    NATIVE_SDK_APPKIT_WIDGET_ACTION_SET_TEXT = 1u << 5,
    NATIVE_SDK_APPKIT_WIDGET_ACTION_SET_SELECTION = 1u << 6,
    NATIVE_SDK_APPKIT_WIDGET_ACTION_SELECT = 1u << 7,
    NATIVE_SDK_APPKIT_WIDGET_ACTION_DRAG = 1u << 8,
    NATIVE_SDK_APPKIT_WIDGET_ACTION_DROP_FILES = 1u << 9,
    NATIVE_SDK_APPKIT_WIDGET_ACTION_DISMISS = 1u << 10,
};

typedef enum {
    NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_FOCUS = 0,
    NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_PRESS = 1,
    NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_TOGGLE = 2,
    NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_INCREMENT = 3,
    NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_DECREMENT = 4,
    NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_SET_TEXT = 5,
    NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_SET_SELECTION = 6,
    NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_SELECT = 7,
    NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_DRAG = 8,
    NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_DROP_FILES = 9,
    NATIVE_SDK_APPKIT_WIDGET_ACCESSIBILITY_ACTION_DISMISS = 10,
} native_sdk_appkit_widget_accessibility_action_t;

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
} native_sdk_appkit_widget_accessibility_node_t;

typedef struct {
    native_sdk_appkit_event_kind_t kind;
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
    uint64_t timer_id;
    /* GPU_SURFACE_SCROLL_DRIVER / CONTEXT_MENU_ACTION payloads: widget_id
     * carries the driver id / menu token; scroll_driver_offset_y the new
     * content offset (canvas points, y-down, overscroll passes through);
     * menu_item_id the selected context-menu item (0 = dismissed). */
    double scroll_driver_offset_y;
    uint32_t menu_item_id;
    /* GPU_SURFACE_FRAME payloads: host-stamped durations of the most
     * recent packet present's decode and draw (0 when no packet present
     * happened since the last frame event), so the engine's frame
     * profile can attribute host time without a second channel. */
    uint64_t packet_decode_ns;
    uint64_t packet_draw_ns;
    /* Nonzero when this frame completed LOGICALLY while the window was
     * occluded (no glass flip; heartbeat pacing): the completion keeps
     * frame-channel consumers current, but its timestamp measures the
     * deliberate occluded cadence, not present latency — consumers must
     * not stamp latency measurements from it. */
    int occluded;
    /* EVENT_AUDIO payloads: the report kind
     * (native_sdk_appkit_audio_event_kind_t) plus the player's
     * position/duration readout in milliseconds at emit time. */
    int audio_kind;
    uint64_t audio_position_ms;
    uint64_t audio_duration_ms;
    int audio_playing;
    /* Nonzero while a streamed URL source is stalled waiting for
     * network bytes — distinct from audio_playing (transport intent):
     * a stream can be un-paused yet silent until bytes arrive. Local
     * files never buffer. */
    int audio_buffering;
    /* SPECTRUM payloads: the band magnitudes on the documented scale
     * (log-spaced 50 Hz..16 kHz buckets; each byte linear-in-dB from
     * the -60 dBFS analysis floor at 0 to full scale at 255). Zeros on
     * every other event kind. */
    uint8_t audio_bands[NATIVE_SDK_APPKIT_AUDIO_SPECTRUM_BANDS];
} native_sdk_appkit_event_t;

typedef void (*native_sdk_appkit_event_callback_t)(void *context, const native_sdk_appkit_event_t *event);
typedef void (*native_sdk_appkit_bridge_callback_t)(void *context, uint64_t window_id, const char *webview_label, size_t webview_label_len, const char *message, size_t message_len, const char *origin, size_t origin_len);

// show_policy 0 = immediate (ordered front at create), 1 = deferred to
// the first canvas present (present-before-show: the window is created
// ordered-out and `makeKeyAndOrderFront` runs after the first
// gpu-surface present lands, with a short fallback deadline so a wedged
// first frame cannot leave the window invisible).
//
// display_name is the human-facing app name (empty = fall back to
// app_name): it drives the application menu title and its About/Hide/
// Quit labels, the process name, the Dock/app-switcher entry, and the
// About panel, which also shows version and about_description when
// non-empty. has_web_content declares whether the app hosts a webview;
// web-only default menu items (Reload, Toggle Web Inspector, Undo/Redo)
// exist only when it is set.
native_sdk_appkit_host_t *native_sdk_appkit_create(const char *app_name, size_t app_name_len, const char *display_name, size_t display_name_len, const char *version, size_t version_len, const char *about_description, size_t about_description_len, int has_web_content, const char *window_title, size_t window_title_len, const char *bundle_id, size_t bundle_id_len, const char *icon_path, size_t icon_path_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame, int resizable, int titlebar_style, int show_policy);
void native_sdk_appkit_destroy(native_sdk_appkit_host_t *host);
// Adopt pre-rendered straight-alpha RGBA8 pixels as the Dock icon (and
// the About panel copy). The pixels are copied before return, so the
// caller may free its buffer immediately; adoption happens on the main
// queue. The Debug dev-run path renders the packaging pipeline's masked
// macOS canvas and delivers it here, so a raw square icon source shows
// the same rounded tile a packaged bundle would.
void native_sdk_appkit_set_dock_icon_rgba(native_sdk_appkit_host_t *host, const uint8_t *pixels, size_t width, size_t height);
// Load the Dock icon from an image file off the calling thread — the
// same decode configureApplication runs for the manifest icon. The
// Debug dev-run path falls back to this when its masked render fails,
// keeping the pre-masking behavior (icon shown unshaped) as the floor.
void native_sdk_appkit_set_dock_icon_file(native_sdk_appkit_host_t *host, const char *path, size_t path_len);
void native_sdk_appkit_run(native_sdk_appkit_host_t *host, native_sdk_appkit_event_callback_t callback, void *context);
void native_sdk_appkit_stop(native_sdk_appkit_host_t *host);
void native_sdk_appkit_load_webview(native_sdk_appkit_host_t *host, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback);
void native_sdk_appkit_load_window_webview(native_sdk_appkit_host_t *host, uint64_t window_id, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback);
void native_sdk_appkit_set_bridge_callback(native_sdk_appkit_host_t *host, native_sdk_appkit_bridge_callback_t callback, void *context);
void native_sdk_appkit_bridge_respond(native_sdk_appkit_host_t *host, const char *response, size_t response_len);
void native_sdk_appkit_bridge_respond_window(native_sdk_appkit_host_t *host, uint64_t window_id, const char *response, size_t response_len);
void native_sdk_appkit_bridge_respond_webview(native_sdk_appkit_host_t *host, uint64_t window_id, const char *webview_label, size_t webview_label_len, const char *response, size_t response_len);
void native_sdk_appkit_emit_window_event(native_sdk_appkit_host_t *host, uint64_t window_id, const char *name, size_t name_len, const char *detail_json, size_t detail_json_len);
void native_sdk_appkit_set_security_policy(native_sdk_appkit_host_t *host, const char *allowed_origins, size_t allowed_origins_len, const char *external_urls, size_t external_urls_len, int external_action);
void native_sdk_appkit_set_menus(native_sdk_appkit_host_t *host, const char *const *menu_titles, const size_t *menu_title_lens, size_t menu_count, const uint32_t *item_menu_indices, const char *const *item_labels, const size_t *item_label_lens, const char *const *item_commands, const size_t *item_command_lens, const char *const *item_keys, const size_t *item_key_lens, const uint32_t *item_modifiers, const int *item_separators, const int *item_enabled, const int *item_checked, size_t item_count);
void native_sdk_appkit_set_shortcuts(native_sdk_appkit_host_t *host, const char *const *ids, const size_t *id_lens, const char *const *keys, const size_t *key_lens, const uint32_t *modifiers, size_t count);
int native_sdk_appkit_create_window(native_sdk_appkit_host_t *host, uint64_t window_id, const char *window_title, size_t window_title_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame, int resizable, int titlebar_style, int show_policy);
// Content min-size floor for a created window (NSWindow contentMinSize):
// the user's resize stops at the floor. Values <= 0 leave that axis at
// AppKit's default minimum. Returns 0 when the window id is unknown.
int native_sdk_appkit_set_window_content_min_size(native_sdk_appkit_host_t *host, uint64_t window_id, double min_width, double min_height);
int native_sdk_appkit_focus_window(native_sdk_appkit_host_t *host, uint64_t window_id);
int native_sdk_appkit_close_window(native_sdk_appkit_host_t *host, uint64_t window_id);
// The real OS minimize verb (NSWindow miniaturize:), for app-drawn
// window controls on chromeless windows. Returns 0 when the window id
// is unknown.
int native_sdk_appkit_minimize_window(native_sdk_appkit_host_t *host, uint64_t window_id);
// Window-drag region channel: called during dispatch of the pointer-down
// that starts the gesture. Single click hands the event to
// -[NSWindow performWindowDragWithEvent:] (moves only on actual
// movement); a double-click applies the user's titlebar double-click
// action (zoom by default). Returns 0 when the window id is unknown.
int native_sdk_appkit_start_window_drag(native_sdk_appkit_host_t *host, uint64_t window_id);
// Chrome overlay geometry for hidden-titlebar windows: the bands where
// the transparent titlebar and traffic lights overlay the content view,
// plus the traffic-light cluster's bounding frame (content coordinates,
// top-left origin — so headers can vertically center against the lights
// in the tall unified band), in points. Standard-chrome windows and
// fullscreen report all-zero. Returns 0 when the window id is unknown
// (out-params untouched).
int native_sdk_appkit_window_chrome_insets(native_sdk_appkit_host_t *host, uint64_t window_id, double *top, double *left, double *bottom, double *right, double *buttons_x, double *buttons_y, double *buttons_width, double *buttons_height);
/* Per-window child WebViews. Both hosts implement these; declaring them
 * here keeps the definitions on C linkage (the Objective-C++ Chromium
 * host would otherwise mangle them and break the platform layer's extern
 * bindings). Each returns 1 on success, 0 when the window or webview is
 * unknown. */
int native_sdk_appkit_create_webview(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len, double x, double y, double width, double height, int layer, int transparent, int bridge_enabled);
int native_sdk_appkit_set_webview_frame(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height);
int native_sdk_appkit_navigate_webview(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len);
int native_sdk_appkit_set_webview_zoom(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double zoom);
int native_sdk_appkit_set_webview_layer(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int layer);
int native_sdk_appkit_close_webview(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len);
int native_sdk_appkit_create_view(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int kind, const char *parent, size_t parent_len, double x, double y, double width, double height, int layer, int visible, int enabled, const char *role, size_t role_len, const char *accessibility_label, size_t accessibility_label_len, const char *text, size_t text_len, const char *command, size_t command_len);
int native_sdk_appkit_update_view(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int has_frame, double x, double y, double width, double height, int has_layer, int layer, int has_visible, int visible, int has_enabled, int enabled, int has_role, const char *role, size_t role_len, int has_accessibility_label, const char *accessibility_label, size_t accessibility_label_len, int has_text, const char *text, size_t text_len, int has_command, const char *command, size_t command_len);
int native_sdk_appkit_set_view_frame(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height);
int native_sdk_appkit_set_view_visible(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int visible);
int native_sdk_appkit_set_view_cursor(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, int cursor);
int native_sdk_appkit_focus_view(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len);
int native_sdk_appkit_close_view(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len);
/* Native-surface adoption: install an app-owned NSView (`ns_view`, an
 * unretained NSView* the caller keeps alive elsewhere or transfers via the
 * superview retain) as the fill content of an existing native view created
 * through `native_sdk_appkit_create_view`. The adopted view is sized to the
 * container's bounds and autoresizes with it, so shell relayout keeps it
 * attached — the same containment shape webview-backed child views use,
 * generalized to views the framework did not construct (a
 * VZVirtualMachineView, an MKMapView, ...). Adopting over an existing
 * adoption replaces it. Main-thread only, like every other view call.
 * Returns 1 on success, 0 when the container is unknown or `ns_view` is not
 * an NSView. */
int native_sdk_appkit_adopt_view_surface(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, void *ns_view);
/* Remove the adopted surface from a container (the view itself stays
 * alive for the caller to reuse). Returns 1 on success, 0 when the
 * container has no adopted surface. */
int native_sdk_appkit_release_view_surface(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len);
int native_sdk_appkit_present_gpu_surface_pixels(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, size_t width, size_t height, double scale, int has_dirty_rect, double dirty_x, double dirty_y, double dirty_width, double dirty_height, const uint8_t *rgba8, size_t rgba8_len);
int native_sdk_appkit_present_gpu_surface_packet(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double surface_width, double surface_height, double scale, uint8_t clear_r, uint8_t clear_g, uint8_t clear_b, uint8_t clear_a, int requires_render, size_t command_count, size_t unsupported_command_count, int representable, const uint8_t *json, size_t json_len);
int native_sdk_appkit_present_gpu_surface_packet_binary(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double surface_width, double surface_height, double scale, uint8_t clear_r, uint8_t clear_g, uint8_t clear_b, uint8_t clear_a, int requires_render, size_t command_count, size_t unsupported_command_count, int representable, const uint8_t *packet, size_t packet_len);
int native_sdk_appkit_request_gpu_surface_frame(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len);
/* Input was dispatched to the surface (real or automation-synthesized):
 * the responding frame emission must not wait out the occluded
 * heartbeat. One-shot; a no-op for hosts/views without occluded pacing. */
int native_sdk_appkit_note_gpu_surface_input(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len);
/* Binary image-upload side-channel: create or replace the host-wide image
 * for `image_id` from tightly packed, row-major, straight-alpha RGBA8
 * bytes (`rgba8_len` must equal width * height * 4). Packet upload cache
 * actions resolve pixels from this store — packet JSON never carries pixel
 * payloads. Returns 1 on success, 0 on invalid arguments. */
int native_sdk_appkit_upload_gpu_surface_image(native_sdk_appkit_host_t *host, uint64_t image_id, size_t width, size_t height, const uint8_t *rgba8, size_t rgba8_len);
/* Drop the host-wide image for `image_id` (the unregister path). Removing
 * an unknown id is a no-op. Returns 1 on success, 0 on invalid arguments. */
int native_sdk_appkit_remove_gpu_surface_image(native_sdk_appkit_host_t *host, uint64_t image_id);
void native_sdk_appkit_start_timer(native_sdk_appkit_host_t *host, uint64_t timer_id, uint64_t interval_ns, int repeats);
void native_sdk_appkit_cancel_timer(native_sdk_appkit_host_t *host, uint64_t timer_id);

/* The app's single audio player (AVAudioPlayer). Load replaces whatever
 * was loaded before, paused at position zero; returns 0 on success, 1
 * when the file is missing/unreadable, 2 when it cannot be decoded. A
 * successful load is followed by one EVENT_AUDIO/LOADED on the run loop
 * carrying the decoded duration. Play/pause/stop/seek/set_volume return
 * 1 when applied, 0 when there is no loaded player to apply to (stop,
 * pause, and set_volume treat that as a harmless no-op on the Zig side).
 * All entries are loop-thread only. */
int native_sdk_appkit_audio_load(native_sdk_appkit_host_t *host, const char *path, size_t path_len);
/* URL sources on the same single player. Resolution is honest and
 * two-step: a verified cache entry at cache_path (present, and
 * expected_bytes matches when nonzero — a partial or stale entry never
 * plays; it is deleted and re-streamed) plays as a plain local file and
 * returns 1; otherwise playback STREAMS progressively via AVPlayer —
 * audible as soon as enough bytes arrive, never download-then-play —
 * while a parallel download fills cache_path for next time (written to
 * a .part sibling, size-verified, then atomically renamed into place)
 * and the call returns 0. An empty cache_path disables caching. Returns
 * 2 when the URL cannot even be parsed. Async failures (unreachable
 * host, mid-stream network loss, undecodable payload) arrive as one
 * EVENT_AUDIO/FAILED on the run loop. Loop-thread only. */
int native_sdk_appkit_audio_load_url(native_sdk_appkit_host_t *host, const char *url, size_t url_len, const char *cache_path, size_t cache_path_len, uint64_t expected_bytes);
int native_sdk_appkit_audio_play(native_sdk_appkit_host_t *host);
int native_sdk_appkit_audio_pause(native_sdk_appkit_host_t *host);
int native_sdk_appkit_audio_stop(native_sdk_appkit_host_t *host);
int native_sdk_appkit_audio_seek(native_sdk_appkit_host_t *host, uint64_t position_ms);
int native_sdk_appkit_audio_set_volume(native_sdk_appkit_host_t *host, double volume);
/* Thread-safe: nudges the main run loop to emit a WAKE event. May be
 * called from any thread (worker threads streaming effect results). */
void native_sdk_appkit_wake(native_sdk_appkit_host_t *host);
/* Thread-safe: asks the main run loop to emit ONE coalesced FRAME event.
 * May be called from any thread; the automation arrival watcher uses it
 * so a command landing in the dropbox wakes an idle app's frame loop the
 * way user input does. Timer-free by design: the event is posted through
 * the main queue, so it is delivered promptly even when the app is
 * backgrounded and its NSTimers are being coalesced. */
void native_sdk_appkit_request_frame(native_sdk_appkit_host_t *host);
int native_sdk_appkit_update_widget_accessibility(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, const native_sdk_appkit_widget_accessibility_node_t *nodes, size_t node_count);
size_t native_sdk_appkit_clipboard_read(native_sdk_appkit_host_t *host, char *buffer, size_t buffer_len);
double native_sdk_appkit_measure_text(uint64_t font_id, double size, const char *text, size_t text_len);

/* Batched measurement: fill advances[text_len] with per-cluster
 * typographic advances for the whole single-line run, shaped with the
 * same font resolution native_sdk_appkit_measure_text measures with.
 * Layout contract: the advance of the UTF-8 cluster starting at byte i
 * lands at advances[i]; the cluster's continuation bytes hold exactly 0.
 * One call per run replaces one measure_text round-trip per cluster of
 * every growing line prefix. Returns 1 on success, 0 when the bytes are
 * not valid UTF-8 or the font id cannot resolve (the engine then keeps
 * its per-prefix path for that run). */
int native_sdk_appkit_measure_text_advances(uint64_t font_id, double size, const char *text, size_t text_len, float *advances);

// Register engine-validated TrueType bytes under a canvas font id so
// measurement and packet text drawing resolve the id to this exact face.
// Returns 1 on success, 0 when CoreText rejects the data.
int native_sdk_appkit_register_font(uint64_t font_id, const uint8_t *bytes, size_t bytes_len);
/* Decode encoded image bytes (PNG, JPEG, ... — whatever ImageIO supports)
 * through CGImageSource into tightly packed, row-major, straight-alpha
 * (non-premultiplied) RGBA8 written into `pixels`. Returns 1 on success
 * (with `out_width`/`out_height` set), 0 when the bytes cannot be decoded,
 * and -1 when the decoded pixels do not fit `pixels_len` (`out_width`/
 * `out_height` still report the decoded dimensions). Pure CoreGraphics —
 * no AppKit state — so it needs no host and is main-thread independent. */
int native_sdk_appkit_decode_image(const uint8_t *bytes, size_t bytes_len, uint8_t *pixels, size_t pixels_len, size_t *out_width, size_t *out_height);
void native_sdk_appkit_clipboard_write(native_sdk_appkit_host_t *host, const char *text, size_t text_len);
size_t native_sdk_appkit_clipboard_read_data(native_sdk_appkit_host_t *host, const char *mime_type, size_t mime_type_len, char *buffer, size_t buffer_len);
int native_sdk_appkit_clipboard_write_data(native_sdk_appkit_host_t *host, const char *mime_type, size_t mime_type_len, const char *bytes, size_t bytes_len);
int native_sdk_appkit_show_notification(native_sdk_appkit_host_t *host, const char *title, size_t title_len, const char *subtitle, size_t subtitle_len, const char *body, size_t body_len);
int native_sdk_appkit_open_external_url(native_sdk_appkit_host_t *host, const char *url, size_t url_len);
int native_sdk_appkit_reveal_path(native_sdk_appkit_host_t *host, const char *path, size_t path_len);
int native_sdk_appkit_add_recent_document(native_sdk_appkit_host_t *host, const char *path, size_t path_len);
int native_sdk_appkit_clear_recent_documents(native_sdk_appkit_host_t *host);
int native_sdk_appkit_set_credential(native_sdk_appkit_host_t *host, const char *service, size_t service_len, const char *account, size_t account_len, const char *secret, size_t secret_len);
size_t native_sdk_appkit_get_credential(native_sdk_appkit_host_t *host, const char *service, size_t service_len, const char *account, size_t account_len, char *buffer, size_t buffer_len);
int native_sdk_appkit_delete_credential(native_sdk_appkit_host_t *host, const char *service, size_t service_len, const char *account, size_t account_len);

typedef struct {
    const char *title;
    size_t title_len;
    const char *default_path;
    size_t default_path_len;
    const char *extensions;
    size_t extensions_len;
    int allow_directories;
    int allow_multiple;
} native_sdk_appkit_open_dialog_opts_t;

typedef struct {
    size_t count;
    size_t bytes_written;
} native_sdk_appkit_open_dialog_result_t;

typedef struct {
    const char *title;
    size_t title_len;
    const char *default_path;
    size_t default_path_len;
    const char *default_name;
    size_t default_name_len;
    const char *extensions;
    size_t extensions_len;
} native_sdk_appkit_save_dialog_opts_t;

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
} native_sdk_appkit_message_dialog_opts_t;

typedef void (*native_sdk_appkit_tray_callback_t)(void *context, uint32_t item_id);

/* One native scroll driver's desired state (see PlatformServices
 * set_gpu_surface_scroll_drivers_fn). Frame coordinates are view-local
 * canvas points (top-left origin, y-down); the host flips to AppKit
 * coordinates itself. */
typedef struct {
    uint64_t driver_id;
    double x;
    double y;
    double width;
    double height;
    double content_width;
    double content_height;
    double offset_y;
    int set_offset;
    /* Edge behavior: 0 pins scrolling at the content edges, nonzero lets
     * the scroller bounce past them (vertical elasticity). */
    int rubber_band;
} native_sdk_appkit_scroll_driver_t;

/* One native context-menu entry. */
typedef struct {
    uint32_t item_id;
    const char *label;
    size_t label_len;
    int enabled;
    int separator;
} native_sdk_appkit_context_menu_item_t;

/* Reconcile the gpu-surface view's native scroll drivers against the full
 * desired set: create missing NSScrollViews, update frames / content
 * extents / (when set_offset) offsets, remove drivers absent from the
 * list. Idempotent; called every layout install and every presented
 * frame. Returns 1 on success, 0 when the view does not exist. */
int native_sdk_appkit_set_gpu_surface_scroll_drivers(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, const native_sdk_appkit_scroll_driver_t *drivers, size_t count);

/* Present a native context menu (NSMenu popUpMenuPositioningItem) at the
 * view-local point on the next main-loop turn. The selection (or
 * dismissal: menu_item_id 0) is emitted asynchronously as a
 * CONTEXT_MENU_ACTION event echoing `token` in widget_id. Returns 1 when
 * the request was queued, 0 when the window does not exist. */
int native_sdk_appkit_show_context_menu(native_sdk_appkit_host_t *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, uint64_t token, const native_sdk_appkit_context_menu_item_t *items, size_t count);

native_sdk_appkit_open_dialog_result_t native_sdk_appkit_show_open_dialog(native_sdk_appkit_host_t *host, const native_sdk_appkit_open_dialog_opts_t *opts, char *buffer, size_t buffer_len);
size_t native_sdk_appkit_show_save_dialog(native_sdk_appkit_host_t *host, const native_sdk_appkit_save_dialog_opts_t *opts, char *buffer, size_t buffer_len);
int native_sdk_appkit_show_message_dialog(native_sdk_appkit_host_t *host, const native_sdk_appkit_message_dialog_opts_t *opts);
void native_sdk_appkit_create_tray(native_sdk_appkit_host_t *host, const char *icon_path, size_t icon_path_len, const char *title, size_t title_len, const char *tooltip, size_t tooltip_len);
void native_sdk_appkit_update_tray_menu(native_sdk_appkit_host_t *host, const uint32_t *item_ids, const char *const *labels, const size_t *label_lens, const int *separators, const int *enabled_flags, size_t count);
/* Retitle the live status item's button without re-creating it (create
 * would flicker and reshuffle the menu bar). Empty title falls back to
 * the icon-only square well, or the app-name initial when there is no
 * icon either — the same fallbacks as create. */
void native_sdk_appkit_update_tray_title(native_sdk_appkit_host_t *host, const char *title, size_t title_len);
void native_sdk_appkit_remove_tray(native_sdk_appkit_host_t *host);
void native_sdk_appkit_set_tray_callback(native_sdk_appkit_host_t *host, native_sdk_appkit_tray_callback_t callback, void *context);

#ifdef __cplusplus
}
#endif

#endif
