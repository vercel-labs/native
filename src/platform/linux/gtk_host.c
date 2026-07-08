#include "gtk_host.h"

#include <gtk/gtk.h>
#include <webkit/webkit.h>
#include <glib/gstdio.h>
#include <dlfcn.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#define NATIVE_SDK_MAX_WINDOWS 16
#define NATIVE_SDK_MAX_WEBVIEWS 16
#define NATIVE_SDK_MAX_TIMERS 64
#define NATIVE_SDK_MAX_NATIVE_VIEWS 32
#define NATIVE_SDK_MAX_SHORTCUTS 64
#define NATIVE_SDK_MAX_MENU_ITEMS 128

/* Tall hidden-titlebar band floor in logical pixels: the same 52 the
 * macOS host's unified-toolbar band settles at, so a toolbar-height app
 * header meets the same band across platforms. Applied as a size
 * REQUEST on the header bar — a theme that needs more keeps its own
 * height; nothing is ever clipped. */
#define NATIVE_SDK_GTK_TALL_TITLEBAR_PX 52

#define NATIVE_SDK_SHORTCUT_MODIFIER_PRIMARY (1u << 0)
#define NATIVE_SDK_SHORTCUT_MODIFIER_COMMAND (1u << 1)
#define NATIVE_SDK_SHORTCUT_MODIFIER_CONTROL (1u << 2)
#define NATIVE_SDK_SHORTCUT_MODIFIER_OPTION  (1u << 3)
#define NATIVE_SDK_SHORTCUT_MODIFIER_SHIFT   (1u << 4)

static size_t native_sdk_overflow_size(size_t buffer_len) {
    return buffer_len == SIZE_MAX ? SIZE_MAX : buffer_len + 1;
}

#define NATIVE_SDK_GTK_VIEW_WEBVIEW 0
#define NATIVE_SDK_GTK_VIEW_TOOLBAR 1
#define NATIVE_SDK_GTK_VIEW_TITLEBAR_ACCESSORY 2
#define NATIVE_SDK_GTK_VIEW_SIDEBAR 3
#define NATIVE_SDK_GTK_VIEW_STATUSBAR 4
#define NATIVE_SDK_GTK_VIEW_SPLIT 5
#define NATIVE_SDK_GTK_VIEW_STACK 6
#define NATIVE_SDK_GTK_VIEW_BUTTON 7
#define NATIVE_SDK_GTK_VIEW_TEXT_FIELD 8
#define NATIVE_SDK_GTK_VIEW_SEARCH_FIELD 9
#define NATIVE_SDK_GTK_VIEW_LABEL 10
#define NATIVE_SDK_GTK_VIEW_SPACER 11
#define NATIVE_SDK_GTK_VIEW_GPU_SURFACE 12
#define NATIVE_SDK_GTK_VIEW_CHECKBOX 13
#define NATIVE_SDK_GTK_VIEW_TOGGLE 14
#define NATIVE_SDK_GTK_VIEW_PROGRESS_INDICATOR 15
#define NATIVE_SDK_GTK_VIEW_SEGMENTED_CONTROL 16
#define NATIVE_SDK_GTK_VIEW_ICON_BUTTON 17
#define NATIVE_SDK_GTK_VIEW_LIST_ITEM 18

typedef struct native_sdk_gtk_shortcut {
    char *id;
    char *key;
    uint32_t modifiers;
} native_sdk_gtk_shortcut_t;

typedef struct native_sdk_gtk_menu_action {
    char *name;
    char *command;
    struct native_sdk_gtk_host *host;
} native_sdk_gtk_menu_action_t;

/* One rectangle of the runtime-pushed window-drag mirror (markup
 * `window-drag="true"`), in the owning gpu_surface view's logical
 * coordinates. Exclusions are the press-claiming widgets INSIDE a drag
 * region — a button in a drag header keeps its press. */
typedef struct native_sdk_gtk_drag_region {
    double x;
    double y;
    double width;
    double height;
    int exclusion;
} native_sdk_gtk_drag_region_t;

typedef struct native_sdk_gtk_webview {
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
} native_sdk_gtk_webview_t;

typedef struct native_sdk_gtk_native_view {
    char *label;
    char *parent;
    char *role;
    char *accessibility_label;
    char *text;
    char *command;
    GtkWidget *widget;
    struct native_sdk_gtk_window *window;
    double x;
    double y;
    double width;
    double height;
    int kind;
    int layer;
    int visible;
    int enabled;
    int explicit_text;
    gulong action_handler;
    /* gpu_surface (software canvas) state */
    unsigned char *gpu_argb;
    int gpu_buf_width;
    int gpu_buf_height;
    int gpu_buf_stride;
    /* Pre-first-present placeholder pump ONLY: a repeating timeout that
     * arms the scheduler below until the first present lands, then
     * removes itself (the macOS host's placeholder display timer, in
     * GLib terms). Steady state never ticks it. */
    guint gpu_frame_timer;
    /* ONE frame-event scheduler per surface (the macOS design): every
     * producer that wants a frame event — runtime frame requests, pixel
     * presents (the completion analog), the placeholder pump — funnels
     * through native_sdk_gpu_surface_schedule_frame_emission, which keeps
     * at most one emission in flight (gpu_emit_source is its GLib source)
     * and fires it on the frame-interval grid anchored at
     * gpu_last_emit_ns. Producers landing while one is queued fold into
     * it: their facts (nonblank, sample color, buffer contents) are
     * already view state when the emission fires. gpu_presented flips on
     * the first present and retires the placeholder pump — from then on
     * frames are demand-driven, so an idle surface emits ZERO frame
     * events (the idle law the macOS host enforces). */
    guint gpu_emit_source;
    uint64_t gpu_last_emit_ns;
    int gpu_presented;
    uint64_t gpu_frame_index;
    double gpu_emitted_width;
    double gpu_emitted_height;
    double gpu_emitted_scale;
    int gpu_nonblank;
    uint32_t gpu_sample_color;
    int gpu_pointer_down;
    double gpu_pointer_x;
    double gpu_pointer_y;
    GtkIMContext *gpu_im_context;
    char *gpu_preedit_text;
    /* Window-drag region mirror (see native_sdk_gtk_drag_region_t),
     * malloc'd on each runtime push and replaced wholesale. The press
     * gesture consults it BEFORE emitting pointer_down, so a drag-region
     * press becomes a system window move the widget pipeline never sees
     * — the GTK reading of the Win32 host answering WM_NCHITTEST with
     * HTCAPTION. gpu_drag_claimed_press remembers a claimed press so the
     * matching release is swallowed too (no orphaned pointer_up). */
    native_sdk_gtk_drag_region_t *drag_regions;
    size_t drag_region_count;
    int gpu_drag_claimed_press;
} native_sdk_gtk_native_view_t;

typedef struct native_sdk_gtk_app_timer {
    uint64_t id;
    guint source;
    int repeats;
    struct native_sdk_gtk_host *host;
    int in_use;
} native_sdk_gtk_app_timer_t;

/* The app's single audio player (see the audio section further down for
 * the backend rationale). All fields are main-loop-thread state: the
 * pipeline's bus messages arrive through a bus signal watch, which is a
 * GSource on the default GLib main context — the same loop GTK runs —
 * so unlike the other desktop hosts no explicit cross-thread
 * marshalling is needed. The one worker, the cache-fill download
 * thread, touches only files, the network, and its own GCancellable. */
typedef struct native_sdk_gtk_audio {
    int active;
    int url_source;
    /* Preroll complete (the pipeline's first async-done): transport
     * calls apply directly; before this they queue as pending_play /
     * pending seek. */
    int ready;
    /* Transport intent (un-paused), the `playing` flag events carry. */
    int playing;
    /* The honest buffering mirror: true from a stream's load until the
     * pipeline actually reaches PLAYING, and across mid-stream refills. */
    int buffering;
    /* A queue refill is in progress (buffering < 100% seen): the
     * pipeline is held paused internally — transport intent unchanged —
     * until the 100% report, the canonical streaming discipline. */
    int refilling;
    int loaded_emitted;
    int pending_play;
    int has_pending_seek;
    uint64_t pending_seek_ms;
    uint64_t duration_ms;
    double volume;
    guint position_timer;
    /* When a verified cache entry is playing, its path: a right-sized
     * entry that then fails to play is corrupt and is deleted before
     * the FAILED report so it never fools the next lookup. */
    char *cache_entry_path;
    void *playbin; /* GstElement* */
    void *bus;     /* GstBus* */
    /* The playbin's audio-filter `spectrum` analyzer (one ref owned
     * here; the playbin holds its own). NULL whenever the analyzer
     * could not be built — playback never depends on it, the SPECTRUM
     * reports simply never flow. */
    void *spectrum; /* GstElement* */
    /* Sample rate learned from the analyzer's sink caps at the first
     * spectrum message; 0 until negotiated. Per-pipeline state: every
     * load builds a fresh playbin, so a track's rate never leaks into
     * the next. */
    int spectrum_rate;
    gulong bus_handlers[6];
    GCancellable *download_cancel;
} native_sdk_gtk_audio_t;

typedef struct native_sdk_gtk_window {
    uint64_t id;
    GtkWindow *gtk_window;
    WebKitWebView *web_view;
    GtkWidget *root_box;
    GtkWidget *menu_bar;
    GtkWidget *stack_root;
    /* Client-side decoration state for the hidden titlebar styles: the
     * GtkHeaderBar installed as the window's titlebar and the two
     * GtkWindowControls packed at its ends (either may render empty,
     * depending on which side the user's gtk-decoration-layout puts the
     * buttons). NULL on .standard windows. */
    GtkWidget *header_bar;
    GtkWidget *window_controls_start;
    GtkWidget *window_controls_end;
    WebKitUserContentManager *content_manager;
    struct native_sdk_gtk_host *host;
    char *label;
    char *title;
    char *asset_root;
    char *asset_entry;
    char *asset_origin;
    char *bridge_origin;
    int spa_fallback;
    double x;
    double y;
    double emitted_width;
    double emitted_height;
    double emitted_scale;
    /* The window WebView's z-position among the overlay children. 0 is
     * the classic bottom-most main child; apps that layer native views
     * UNDER the WebView (or the WebView over a canvas) set it through
     * the same layer channel the child views use. */
    int main_webview_layer;
    /* Last pointer press on a gpu_surface view, in window coordinates —
     * what an interactive window move begins from. The device/time pair
     * comes from the originating event; a zero time means no press has
     * been recorded yet. */
    GdkDevice *last_press_device;
    guint32 last_press_time;
    int last_press_button;
    double last_press_x;
    double last_press_y;
    native_sdk_gtk_webview_t webviews[NATIVE_SDK_MAX_WEBVIEWS];
    int webview_count;
    native_sdk_gtk_native_view_t native_views[NATIVE_SDK_MAX_NATIVE_VIEWS];
    int native_view_count;
} native_sdk_gtk_window_t;

struct native_sdk_gtk_host {
    GtkApplication *app;
    char *app_name;
    char *window_title;
    char *bundle_id;
    char *icon_path;
    char *window_label;
    double init_x, init_y, init_width, init_height;
    int restore_frame;
    /* Startup-window options applied when on_activate creates @w1 (the
     * window does not exist yet when the host is created). */
    int init_resizable;
    int init_titlebar_style;
    double init_min_width;
    double init_min_height;

    native_sdk_gtk_event_callback_t callback;
    void *callback_context;
    native_sdk_gtk_bridge_callback_t bridge_callback;
    void *bridge_context;

    native_sdk_gtk_window_t windows[NATIVE_SDK_MAX_WINDOWS];
    int window_count;
    /* App timers (runtime `startTimer`) on the GLib main loop. */
    native_sdk_gtk_app_timer_t timers[NATIVE_SDK_MAX_TIMERS];
    int did_shutdown;
    int app_active;
    guint frame_timer;

    char **allowed_origins;
    int allowed_origins_count;
    char **allowed_external_urls;
    int allowed_external_urls_count;
    int external_link_action;
    int scheme_registered;
    native_sdk_gtk_shortcut_t shortcuts[NATIVE_SDK_MAX_SHORTCUTS];
    int shortcut_count;
    GMenuModel *menu_model;
    native_sdk_gtk_menu_action_t menu_actions[NATIVE_SDK_MAX_MENU_ITEMS];
    int menu_action_count;
    native_sdk_gtk_audio_t audio;
};

static void native_sdk_emit(native_sdk_gtk_host_t *host, native_sdk_gtk_event_t event);
static gboolean native_sdk_nudge_chrome_requery(gpointer data);
static gboolean native_sdk_on_file_drop(GtkDropTarget *target, const GValue *value, double x, double y, gpointer data);
static GtkWindow *native_sdk_parent_window(native_sdk_gtk_host_t *host);
static const char *native_sdk_shortcut_key_for_keyval(guint keyval, char *buffer, size_t buffer_len, int *uses_implicit_shift);
static void native_sdk_audio_release(native_sdk_gtk_host_t *host, int cancel_download);

static char *native_sdk_strndup(const char *s, size_t len) {
    char *out = malloc(len + 1);
    if (!out) return NULL;
    memcpy(out, s, len);
    out[len] = '\0';
    return out;
}

static void native_sdk_free_string_list(char **list, int count) {
    if (!list) return;
    for (int i = 0; i < count; i++) free(list[i]);
    free(list);
}

static char **native_sdk_parse_newline_list(const char *bytes, size_t len, int *out_count) {
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
                if (!tmp) { native_sdk_free_string_list(result, *out_count); *out_count = 0; return NULL; }
                result = tmp;
            }
            result[*out_count] = native_sdk_strndup(start, seg_len);
            (*out_count)++;
        }
        start = nl ? nl + 1 : end;
    }
    return result;
}

static void native_sdk_replace_string(char **dest, const char *bytes, size_t len) {
    free(*dest);
    *dest = bytes && len > 0 ? native_sdk_strndup(bytes, len) : NULL;
}

static void native_sdk_clear_shortcuts(native_sdk_gtk_host_t *host) {
    if (!host) return;
    for (int i = 0; i < host->shortcut_count; i++) {
        free(host->shortcuts[i].id);
        free(host->shortcuts[i].key);
        memset(&host->shortcuts[i], 0, sizeof(host->shortcuts[i]));
    }
    host->shortcut_count = 0;
}

static void native_sdk_clear_menu_actions(native_sdk_gtk_host_t *host) {
    if (!host) return;
    const char *empty_accels[] = { NULL };
    for (int i = 0; i < host->menu_action_count; i++) {
        native_sdk_gtk_menu_action_t *action = &host->menu_actions[i];
        if (action->name && host->app) {
            char *detailed = g_strdup_printf("app.%s", action->name);
            gtk_application_set_accels_for_action(host->app, detailed, empty_accels);
            g_free(detailed);
            g_action_map_remove_action(G_ACTION_MAP(host->app), action->name);
        }
        g_free(action->name);
        free(action->command);
        memset(action, 0, sizeof(*action));
    }
    host->menu_action_count = 0;
}

static void native_sdk_clear_window_source(native_sdk_gtk_window_t *win) {
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

static int native_sdk_strings_equal(const char *a, const char *b) {
    return a && b && strcmp(a, b) == 0;
}

static int native_sdk_window_uses_public_asset_origin(native_sdk_gtk_host_t *host, native_sdk_gtk_window_t *current, const char *origin) {
    if (!origin) return 0;
    for (int i = 0; i < host->window_count; i++) {
        native_sdk_gtk_window_t *win = &host->windows[i];
        if (win == current || !win->asset_root || !win->bridge_origin) continue;
        if (strcmp(win->bridge_origin, origin) == 0) return 1;
    }
    return 0;
}

static char *native_sdk_internal_asset_origin(uint64_t window_id) {
    char buffer[96];
    int len = snprintf(buffer, sizeof(buffer), "zero://native-sdk-window-%llu", (unsigned long long)window_id);
    if (len <= 0 || (size_t)len >= sizeof(buffer)) return NULL;
    return native_sdk_strndup(buffer, (size_t)len);
}

static int native_sdk_window_allows_asset_origin(native_sdk_gtk_window_t *win, const char *origin) {
    return native_sdk_strings_equal(win->asset_origin, origin) || native_sdk_strings_equal(win->bridge_origin, origin);
}

typedef WebKitWebView *(*native_sdk_request_get_web_view_fn)(WebKitURISchemeRequest *request);

static native_sdk_request_get_web_view_fn native_sdk_request_get_web_view(void) {
    static int resolved = 0;
    static native_sdk_request_get_web_view_fn get_web_view = NULL;
    if (!resolved) {
        get_web_view = (native_sdk_request_get_web_view_fn)dlsym(RTLD_DEFAULT, "webkit_uri_scheme_request_get_web_view");
        resolved = 1;
    }
    return get_web_view;
}

static int native_sdk_request_web_view_supported(void) {
    return native_sdk_request_get_web_view() != NULL;
}

static WebKitWebView *native_sdk_request_web_view(WebKitURISchemeRequest *request) {
    native_sdk_request_get_web_view_fn get_web_view = native_sdk_request_get_web_view();
    return get_web_view ? get_web_view(request) : NULL;
}

static native_sdk_gtk_window_t *native_sdk_window_for_web_view(native_sdk_gtk_host_t *host, WebKitWebView *web_view) {
    if (!web_view) return NULL;
    for (int i = 0; i < host->window_count; i++) {
        native_sdk_gtk_window_t *win = &host->windows[i];
        if (win->web_view == web_view) return win;
        for (int j = 0; j < win->webview_count; j++) {
            if (win->webviews[j].web_view == web_view) return win;
        }
    }
    return NULL;
}

static int native_sdk_valid_webview_frame(double x, double y, double width, double height) {
    return x >= 0 && y >= 0 && width > 0 && height > 0;
}

static int native_sdk_webview_extent(double value) {
    return value > 1 ? (int)(value + 0.5) : 1;
}

static int native_sdk_webview_coord(double value) {
    return value > 0 ? (int)(value + 0.5) : 0;
}

static void native_sdk_apply_webview_frame(native_sdk_gtk_webview_t *webview) {
    if (!webview || !webview->web_view) return;
    GtkWidget *widget = GTK_WIDGET(webview->web_view);
    gtk_widget_set_halign(widget, GTK_ALIGN_START);
    gtk_widget_set_valign(widget, GTK_ALIGN_START);
    gtk_widget_set_margin_start(widget, native_sdk_webview_coord(webview->x));
    gtk_widget_set_margin_top(widget, native_sdk_webview_coord(webview->y));
    gtk_widget_set_size_request(widget, native_sdk_webview_extent(webview->width), native_sdk_webview_extent(webview->height));
}

static int native_sdk_valid_native_view_frame(double x, double y, double width, double height) {
    return x >= 0 && y >= 0 && width >= 0 && height >= 0;
}

static int native_sdk_native_extent(double value) {
    return value > 0 ? (int)(value + 0.5) : 0;
}

static int native_sdk_native_coord(double value) {
    return value > 0 ? (int)(value + 0.5) : 0;
}

static int native_sdk_is_native_container_kind(int kind) {
    return kind == NATIVE_SDK_GTK_VIEW_TOOLBAR ||
        kind == NATIVE_SDK_GTK_VIEW_TITLEBAR_ACCESSORY ||
        kind == NATIVE_SDK_GTK_VIEW_SIDEBAR ||
        kind == NATIVE_SDK_GTK_VIEW_STATUSBAR ||
        kind == NATIVE_SDK_GTK_VIEW_SPLIT ||
        kind == NATIVE_SDK_GTK_VIEW_STACK ||
        kind == NATIVE_SDK_GTK_VIEW_SPACER;
}

static int native_sdk_is_supported_native_view_kind(int kind) {
    return native_sdk_is_native_container_kind(kind) ||
        kind == NATIVE_SDK_GTK_VIEW_GPU_SURFACE ||
        kind == NATIVE_SDK_GTK_VIEW_BUTTON ||
        kind == NATIVE_SDK_GTK_VIEW_ICON_BUTTON ||
        kind == NATIVE_SDK_GTK_VIEW_LIST_ITEM ||
        kind == NATIVE_SDK_GTK_VIEW_CHECKBOX ||
        kind == NATIVE_SDK_GTK_VIEW_TOGGLE ||
        kind == NATIVE_SDK_GTK_VIEW_SEGMENTED_CONTROL ||
        kind == NATIVE_SDK_GTK_VIEW_TEXT_FIELD ||
        kind == NATIVE_SDK_GTK_VIEW_SEARCH_FIELD ||
        kind == NATIVE_SDK_GTK_VIEW_LABEL ||
        kind == NATIVE_SDK_GTK_VIEW_PROGRESS_INDICATOR;
}

static const char *native_sdk_native_display_text(native_sdk_gtk_native_view_t *view) {
    if (!view) return "";
    if (view->text && view->text[0]) return view->text;
    if (view->role && view->role[0]) return view->role;
    return view->label ? view->label : "";
}

static const char *native_sdk_native_accessibility_label(native_sdk_gtk_native_view_t *view) {
    if (!view) return "";
    if (view->accessibility_label && view->accessibility_label[0]) return view->accessibility_label;
    if (view->role && view->role[0]) return view->role;
    if (view->text && view->text[0]) return view->text;
    return view->label ? view->label : "";
}

static native_sdk_gtk_native_view_t *native_sdk_find_native_view(native_sdk_gtk_window_t *win, const char *label) {
    if (!win || !label) return NULL;
    for (int i = 0; i < NATIVE_SDK_MAX_NATIVE_VIEWS; i++) {
        if (win->native_views[i].label && strcmp(win->native_views[i].label, label) == 0) return &win->native_views[i];
    }
    return NULL;
}

static void native_sdk_configure_segmented_widget(GtkWidget *box, const char *text) {
    if (!GTK_IS_BOX(box)) return;
    GtkWidget *child = gtk_widget_get_first_child(box);
    while (child) {
        GtkWidget *next = gtk_widget_get_next_sibling(child);
        gtk_box_remove(GTK_BOX(box), child);
        child = next;
    }

    const char *source = text && text[0] ? text : "One|Two";
    const char *start = source;
    int count = 0;
    for (const char *cursor = source;; cursor++) {
        if (*cursor != '|' && *cursor != '\0') continue;
        size_t len = (size_t)(cursor - start);
        while (len > 0 && (*start == ' ' || *start == '\t')) {
            start++;
            len--;
        }
        while (len > 0 && (start[len - 1] == ' ' || start[len - 1] == '\t')) len--;
        if (len > 0) {
            char *segment = g_strndup(start, len);
            GtkWidget *button = gtk_toggle_button_new_with_label(segment);
            gtk_widget_add_css_class(button, "flat");
            if (count == 0) gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(button), TRUE);
            gtk_box_append(GTK_BOX(box), button);
            g_free(segment);
            count++;
        }
        if (*cursor == '\0') break;
        start = cursor + 1;
    }

    if (count == 0) {
        GtkWidget *button = gtk_toggle_button_new_with_label("Segment");
        gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(button), TRUE);
        gtk_box_append(GTK_BOX(box), button);
    }
}

static GtkWidget *native_sdk_make_native_widget(int kind, const char *label, const char *text) {
    const char *display_text = text && text[0] ? text : (label ? label : "");
    switch (kind) {
        case NATIVE_SDK_GTK_VIEW_TOOLBAR:
        case NATIVE_SDK_GTK_VIEW_TITLEBAR_ACCESSORY:
        case NATIVE_SDK_GTK_VIEW_SIDEBAR:
        case NATIVE_SDK_GTK_VIEW_STATUSBAR:
        case NATIVE_SDK_GTK_VIEW_SPLIT:
        case NATIVE_SDK_GTK_VIEW_STACK:
        case NATIVE_SDK_GTK_VIEW_SPACER:
            return gtk_fixed_new();
        case NATIVE_SDK_GTK_VIEW_BUTTON:
            return gtk_button_new_with_label(display_text[0] ? display_text : "Button");
        case NATIVE_SDK_GTK_VIEW_ICON_BUTTON: {
            GtkWidget *button = gtk_button_new_with_label(display_text[0] ? display_text : "...");
            gtk_widget_add_css_class(button, "flat");
            gtk_widget_add_css_class(button, "circular");
            return button;
        }
        case NATIVE_SDK_GTK_VIEW_LIST_ITEM: {
            GtkWidget *button = gtk_button_new_with_label(display_text[0] ? display_text : "Item");
            gtk_widget_add_css_class(button, "flat");
            gtk_widget_set_halign(button, GTK_ALIGN_FILL);
            GtkWidget *child = gtk_widget_get_first_child(button);
            if (GTK_IS_LABEL(child)) gtk_label_set_xalign(GTK_LABEL(child), 0.0f);
            return button;
        }
        case NATIVE_SDK_GTK_VIEW_CHECKBOX:
            return gtk_check_button_new_with_label(display_text[0] ? display_text : "Checkbox");
        case NATIVE_SDK_GTK_VIEW_TOGGLE:
            return gtk_toggle_button_new_with_label(display_text[0] ? display_text : "Toggle");
        case NATIVE_SDK_GTK_VIEW_SEGMENTED_CONTROL: {
            GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
            gtk_widget_add_css_class(box, "linked");
            native_sdk_configure_segmented_widget(box, display_text[0] ? display_text : "One|Two");
            return box;
        }
        case NATIVE_SDK_GTK_VIEW_TEXT_FIELD: {
            GtkWidget *entry = gtk_entry_new();
            gtk_entry_set_placeholder_text(GTK_ENTRY(entry), display_text);
            return entry;
        }
        case NATIVE_SDK_GTK_VIEW_SEARCH_FIELD: {
            GtkWidget *entry = gtk_entry_new();
            gtk_entry_set_placeholder_text(GTK_ENTRY(entry), display_text[0] ? display_text : "Search");
            return entry;
        }
        case NATIVE_SDK_GTK_VIEW_LABEL: {
            GtkWidget *view = gtk_label_new(display_text);
            gtk_label_set_ellipsize(GTK_LABEL(view), PANGO_ELLIPSIZE_END);
            gtk_label_set_xalign(GTK_LABEL(view), 0.0f);
            return view;
        }
        case NATIVE_SDK_GTK_VIEW_PROGRESS_INDICATOR: {
            GtkWidget *spinner = gtk_spinner_new();
            gtk_spinner_start(GTK_SPINNER(spinner));
            return spinner;
        }
        case NATIVE_SDK_GTK_VIEW_GPU_SURFACE: {
            GtkWidget *area = gtk_drawing_area_new();
            gtk_widget_set_focusable(area, TRUE);
            return area;
        }
        default:
            return NULL;
    }
}

/* ---------------------------------------------------------------- gpu surface
 *
 * A gpu_surface view is a GtkDrawingArea driven by the CPU pixel path: the
 * runtime rasterizes canvas frames with the reference renderer and hands
 * RGBA8 buffers to native_sdk_gtk_present_gpu_surface_pixels, which converts
 * them into a premultiplied CAIRO_FORMAT_ARGB32 buffer and queues a redraw.
 * Frame events are DEMAND-DRIVEN through one scheduler per surface (the
 * macOS host's design): runtime frame requests and pixel presents each
 * arm a single grid-anchored emission, so an armed animation loop sees
 * one gpu_surface_frame per frame interval and an idle surface sees
 * none. Until the first present lands, a placeholder pump arms the same
 * scheduler every 16 ms (the runtime's install choreography rides the
 * first frame events), then removes itself. gpu_surface_resize rides
 * the drawing area's resize/scale signals, no longer a poll. Pointer,
 * scroll, and key input map onto the same gpu_surface_input kinds the
 * AppKit host emits.
 *
 * Text input flows through a GtkIMContext (gtk_im_multicontext_new, so ibus /
 * fcitx / GtkIMContextSimple all work): key presses are offered to the IM
 * context first, committed text becomes text_input events, and preedit
 * updates become ime_set_composition / ime_commit_composition /
 * ime_cancel_composition — the same kinds the AppKit host derives from
 * insertText / setMarkedText / unmarkText. Keys the IM context consumes are
 * still surfaced as key_down events with an empty text payload (mirroring
 * AppKit, whose key_down never carries text), so activation keys like space
 * and enter keep working without double-inserting text.
 */

#define NATIVE_SDK_GTK_GPU_FRAME_INTERVAL_NS 16666667ull

#define NATIVE_SDK_GTK_GPU_INPUT_POINTER_DOWN 0
#define NATIVE_SDK_GTK_GPU_INPUT_POINTER_UP 1
#define NATIVE_SDK_GTK_GPU_INPUT_POINTER_MOVE 2
#define NATIVE_SDK_GTK_GPU_INPUT_POINTER_DRAG 3
#define NATIVE_SDK_GTK_GPU_INPUT_SCROLL 4
#define NATIVE_SDK_GTK_GPU_INPUT_KEY_DOWN 5
#define NATIVE_SDK_GTK_GPU_INPUT_KEY_UP 6
#define NATIVE_SDK_GTK_GPU_INPUT_TEXT_INPUT 7
#define NATIVE_SDK_GTK_GPU_INPUT_IME_SET_COMPOSITION 8
#define NATIVE_SDK_GTK_GPU_INPUT_IME_COMMIT_COMPOSITION 9
#define NATIVE_SDK_GTK_GPU_INPUT_IME_CANCEL_COMPOSITION 10

static uint64_t native_sdk_gpu_timestamp_ns(void) {
    return (uint64_t)g_get_monotonic_time() * 1000ull;
}

static uint32_t native_sdk_gpu_modifier_flags(GdkModifierType state) {
    uint32_t flags = 0;
    if (state & GDK_CONTROL_MASK) flags |= NATIVE_SDK_SHORTCUT_MODIFIER_PRIMARY | NATIVE_SDK_SHORTCUT_MODIFIER_CONTROL;
    if (state & GDK_ALT_MASK) flags |= NATIVE_SDK_SHORTCUT_MODIFIER_OPTION;
    if (state & GDK_SHIFT_MASK) flags |= NATIVE_SDK_SHORTCUT_MODIFIER_SHIFT;
    if ((state & GDK_META_MASK) || (state & GDK_SUPER_MASK)) flags |= NATIVE_SDK_SHORTCUT_MODIFIER_COMMAND;
    return flags;
}

static void native_sdk_emit_gpu_surface_input(native_sdk_gtk_native_view_t *view, int input_kind, double x, double y, int button, double delta_x, double delta_y, const char *key, const char *text, uint32_t modifiers) {
    if (!view || !view->window || !view->window->host || !view->label) return;
    native_sdk_emit(view->window->host, (native_sdk_gtk_event_t){
        .kind = NATIVE_SDK_GTK_EVENT_GPU_SURFACE_INPUT,
        .window_id = view->window->id,
        .view_label = view->label,
        .view_label_len = strlen(view->label),
        .x = x,
        .y = y,
        .timestamp_ns = native_sdk_gpu_timestamp_ns(),
        .input_kind = input_kind,
        .button = button,
        .delta_x = delta_x,
        .delta_y = delta_y,
        .key_text = key ? key : "",
        .key_text_len = key ? strlen(key) : 0,
        .input_text = text ? text : "",
        .input_text_len = text ? strlen(text) : 0,
        .shortcut_modifiers = modifiers,
    });
}

static void native_sdk_emit_gpu_surface_text_input(native_sdk_gtk_native_view_t *view, int input_kind, const char *text, int has_composition_cursor, size_t composition_cursor) {
    if (!view || !view->window || !view->window->host || !view->label) return;
    native_sdk_emit(view->window->host, (native_sdk_gtk_event_t){
        .kind = NATIVE_SDK_GTK_EVENT_GPU_SURFACE_INPUT,
        .window_id = view->window->id,
        .view_label = view->label,
        .view_label_len = strlen(view->label),
        .timestamp_ns = native_sdk_gpu_timestamp_ns(),
        .input_kind = input_kind,
        .key_text = "",
        .key_text_len = 0,
        .input_text = text ? text : "",
        .input_text_len = text ? strlen(text) : 0,
        .has_composition_cursor = has_composition_cursor,
        .composition_cursor = composition_cursor,
    });
}

static int native_sdk_gpu_surface_has_preedit(const native_sdk_gtk_native_view_t *view) {
    return view && view->gpu_preedit_text && view->gpu_preedit_text[0];
}

static void native_sdk_gpu_surface_clear_preedit(native_sdk_gtk_native_view_t *view) {
    if (!view) return;
    free(view->gpu_preedit_text);
    view->gpu_preedit_text = NULL;
}

/* IM context committed text. Mirrors AppKit's insertText: committing exactly
 * the marked text becomes ime_commit_composition; committing different text
 * while a composition is active cancels it first, then inserts. */
static void native_sdk_gpu_im_commit(GtkIMContext *context, const char *text, gpointer data) {
    (void)context;
    native_sdk_gtk_native_view_t *view = data;
    if (!view || !text || !text[0]) return;
    const int had_preedit = native_sdk_gpu_surface_has_preedit(view);
    if (had_preedit && strcmp(view->gpu_preedit_text, text) == 0) {
        native_sdk_gpu_surface_clear_preedit(view);
        native_sdk_emit_gpu_surface_text_input(view, NATIVE_SDK_GTK_GPU_INPUT_IME_COMMIT_COMPOSITION, "", 0, 0);
        return;
    }
    if (had_preedit) {
        native_sdk_gpu_surface_clear_preedit(view);
        native_sdk_emit_gpu_surface_text_input(view, NATIVE_SDK_GTK_GPU_INPUT_IME_CANCEL_COMPOSITION, "", 0, 0);
    }
    native_sdk_emit_gpu_surface_text_input(view, NATIVE_SDK_GTK_GPU_INPUT_TEXT_INPUT, text, 0, 0);
}

/* IM context preedit (composition) changed. Mirrors AppKit's setMarkedText:
 * non-empty preedit becomes ime_set_composition with a byte cursor into the
 * preedit text; an emptied preedit cancels the composition. */
static void native_sdk_gpu_im_preedit_changed(GtkIMContext *context, gpointer data) {
    native_sdk_gtk_native_view_t *view = data;
    if (!view || !context) return;
    char *preedit = NULL;
    PangoAttrList *attrs = NULL;
    gint cursor_chars = 0;
    gtk_im_context_get_preedit_string(context, &preedit, &attrs, &cursor_chars);
    if (attrs) pango_attr_list_unref(attrs);
    if (!preedit || !preedit[0]) {
        g_free(preedit);
        if (native_sdk_gpu_surface_has_preedit(view)) {
            native_sdk_gpu_surface_clear_preedit(view);
            native_sdk_emit_gpu_surface_text_input(view, NATIVE_SDK_GTK_GPU_INPUT_IME_CANCEL_COMPOSITION, "", 0, 0);
        }
        return;
    }

    const glong preedit_chars = g_utf8_strlen(preedit, -1);
    glong clamped_cursor = cursor_chars;
    if (clamped_cursor < 0) clamped_cursor = preedit_chars;
    if (clamped_cursor > preedit_chars) clamped_cursor = preedit_chars;
    const size_t cursor_bytes = (size_t)(g_utf8_offset_to_pointer(preedit, clamped_cursor) - preedit);

    free(view->gpu_preedit_text);
    view->gpu_preedit_text = strdup(preedit);
    native_sdk_emit_gpu_surface_text_input(view, NATIVE_SDK_GTK_GPU_INPUT_IME_SET_COMPOSITION, preedit, 1, cursor_bytes);
    g_free(preedit);
}

static double native_sdk_gpu_surface_width(native_sdk_gtk_native_view_t *view) {
    int width = view->widget ? gtk_widget_get_width(view->widget) : 0;
    if (width > 0) return (double)width;
    if (view->width > 0) return view->width;
    if (view->window && view->window->stack_root) {
        width = gtk_widget_get_width(view->window->stack_root);
        if (width > 0) return (double)width;
    }
    return 0;
}

static double native_sdk_gpu_surface_height(native_sdk_gtk_native_view_t *view) {
    int height = view->widget ? gtk_widget_get_height(view->widget) : 0;
    if (height > 0) return (double)height;
    if (view->height > 0) return view->height;
    if (view->window && view->window->stack_root) {
        height = gtk_widget_get_height(view->window->stack_root);
        if (height > 0) return (double)height;
    }
    return 0;
}

/* Emit a gpu_surface_resize when the widget's logical size or device scale
 * differ from the last emitted values. Returns 1 when an event was sent. */
static int native_sdk_gpu_surface_sync_geometry(native_sdk_gtk_native_view_t *view, double width, double height, double scale) {
    if (!view || !view->window || !view->window->host) return 0;
    if (width == view->gpu_emitted_width && height == view->gpu_emitted_height && scale == view->gpu_emitted_scale) return 0;
    view->gpu_emitted_width = width;
    view->gpu_emitted_height = height;
    view->gpu_emitted_scale = scale;
    native_sdk_emit(view->window->host, (native_sdk_gtk_event_t){
        .kind = NATIVE_SDK_GTK_EVENT_GPU_SURFACE_RESIZE,
        .window_id = view->window->id,
        .view_label = view->label,
        .view_label_len = view->label ? strlen(view->label) : 0,
        .x = view->x,
        .y = view->y,
        .width = width,
        .height = height,
        .scale = scale,
        .timestamp_ns = native_sdk_gpu_timestamp_ns(),
    });
    return 1;
}

/* notify::scale-factor on the drawing area (e.g. the window moved to a
 * monitor with a different device scale): report the new scale immediately
 * instead of waiting for the next frame tick, so the runtime can rebuild its
 * pixel buffers at the new density. */
static void native_sdk_gpu_surface_scale_changed(GObject *object, GParamSpec *pspec, gpointer data) {
    (void)object;
    (void)pspec;
    native_sdk_gtk_native_view_t *view = data;
    if (!view || !view->widget) return;
    const double width = native_sdk_gpu_surface_width(view);
    const double height = native_sdk_gpu_surface_height(view);
    if (width <= 0 || height <= 0) return;
    const double scale = (double)gtk_widget_get_scale_factor(view->widget);
    if (native_sdk_gpu_surface_sync_geometry(view, width, height, scale)) {
        gtk_widget_queue_draw(view->widget);
    }
}

/* Advance the pacing clock for an emission that was SCHEDULED at
 * lastEmit + interval (the macOS host's clock discipline, mirrored):
 * stamping fire time would fold the timeout's delivery latency into
 * every period, so the paced loop would drift slow; stamping the
 * scheduled deadline keeps the average period exactly one frame
 * interval (jitter stays, drift doesn't). A fire more than one interval
 * late advances to the last GRID point at or before now — whole missed
 * intervals are skipped, never queued as a catch-up burst, and a
 * re-base from fire time (which would stretch every following period
 * by the delivery latency) never happens. */
static void native_sdk_gpu_surface_advance_pacing_clock(native_sdk_gtk_native_view_t *view) {
    const uint64_t now = native_sdk_gpu_timestamp_ns();
    if (view->gpu_last_emit_ns == 0) {
        view->gpu_last_emit_ns = now;
        return;
    }
    const uint64_t scheduled_ns = view->gpu_last_emit_ns + NATIVE_SDK_GTK_GPU_FRAME_INTERVAL_NS;
    if (now < scheduled_ns) {
        /* Fired before the deadline (timer granularity); re-basing at
         * now keeps the next delay a full interval. */
        view->gpu_last_emit_ns = now;
    } else {
        view->gpu_last_emit_ns = scheduled_ns + ((now - scheduled_ns) / NATIVE_SDK_GTK_GPU_FRAME_INTERVAL_NS) * NATIVE_SDK_GTK_GPU_FRAME_INTERVAL_NS;
    }
}

/* The single frame-event emission: view state (nonblank verdict, sample
 * color, buffer geometry) is the payload, so one event serves frame
 * requests and present completions alike. */
static void native_sdk_gpu_surface_emit_frame(native_sdk_gtk_native_view_t *view) {
    if (!view || !view->widget || !view->window || !view->window->host) return;

    const double width = native_sdk_gpu_surface_width(view);
    const double height = native_sdk_gpu_surface_height(view);
    const double scale = (double)gtk_widget_get_scale_factor(view->widget);
    if (width <= 0 || height <= 0) return;

    (void)native_sdk_gpu_surface_sync_geometry(view, width, height, scale);
    native_sdk_gpu_surface_advance_pacing_clock(view);

    view->gpu_frame_index += 1;
    native_sdk_emit(view->window->host, (native_sdk_gtk_event_t){
        .kind = NATIVE_SDK_GTK_EVENT_GPU_SURFACE_FRAME,
        .window_id = view->window->id,
        .view_label = view->label,
        .view_label_len = view->label ? strlen(view->label) : 0,
        .width = width,
        .height = height,
        .scale = scale,
        .frame_index = view->gpu_frame_index,
        .timestamp_ns = native_sdk_gpu_timestamp_ns(),
        .frame_interval_ns = NATIVE_SDK_GTK_GPU_FRAME_INTERVAL_NS,
        .nonblank = view->gpu_nonblank,
        .sample_color = view->gpu_sample_color,
    });
}

/* One-shot timeout body for the scheduled emission below. */
static gboolean native_sdk_gpu_surface_emit_scheduled(gpointer data) {
    native_sdk_gtk_native_view_t *view = data;
    if (!view) return G_SOURCE_REMOVE;
    /* Clear BEFORE emitting: the emission's engine dispatch may present
     * and re-arm the scheduler, and that arm must see the slot free. */
    view->gpu_emit_source = 0;
    native_sdk_gpu_surface_emit_frame(view);
    return G_SOURCE_REMOVE;
}

/* Schedule the surface's next frame event on the frame-interval grid.
 * At most one emission is ever in flight; producers arriving while it
 * is queued fold into it. Always fires through the main loop — a
 * request lands mid engine dispatch and a synchronous emission would
 * re-enter the engine — and the pacing clock's grid stamping keeps the
 * loop hop out of the period.
 *
 * The emission runs at G_PRIORITY_DEFAULT_IDLE (200), BELOW GTK's
 * layout (GTK_PRIORITY_RESIZE, 110) and paint (GDK_PRIORITY_REDRAW,
 * 120) sources — never at plain g_timeout_add's G_PRIORITY_DEFAULT (0).
 * The ordering is load-bearing: when an armed frame loop's cycle costs
 * more than one frame interval (a large software-rendered canvas),
 * every present re-arms at delay 0, and a default-priority timeout that
 * is ready on every main-loop iteration starves everything below it.
 * Presents keep landing in the retained pixel buffer and queue_draw
 * keeps requesting a repaint, but the paint source never dispatches:
 * the visible window freezes on stale glass for as long as the loop
 * stays armed, while input and model updates (also default priority)
 * keep flowing — layout and paint are the only casualties, so a resize
 * during the stall does not even re-layout. At idle priority the
 * pending paint and relayout win each cycle instead, so every presented
 * frame reaches the glass before the next frame event spins the engine
 * again. The idle law is untouched: nothing here ticks periodically,
 * an emission still exists only when a producer armed one.
 *
 * No occluded/minimized throttle here, DELIBERATELY. The macOS host
 * paces completions to a ~1 Hz heartbeat while the window is occluded
 * and the Windows host does the same while minimized, because each has
 * a reliable signal (the occlusion bit; IsIconic). GTK4 has none that
 * holds across backends: a toplevel fully covered by other windows is
 * not reported at all, minimize is invisible to the client on Wayland
 * (only the compositor knows), and the toplevel "suspended" state is
 * compositor-dependent, absent on X11, and can arrive seconds late or
 * never. Throttling on a signal that may never fire (or never clear)
 * would freeze visible windows on some desktops — worse than the CPU
 * cost it saves. If a dependable cross-backend visibility fact lands in
 * the toolkit's GTK floor, pace on it here exactly like the other
 * hosts: heartbeat while hidden, immediate re-arm on reveal. */
static void native_sdk_gpu_surface_schedule_frame_emission(native_sdk_gtk_native_view_t *view) {
    if (!view || !view->widget || !view->window || !view->window->host) return;
    if (view->gpu_emit_source) return;
    const uint64_t now = native_sdk_gpu_timestamp_ns();
    uint64_t delay_ns = 0;
    if (view->gpu_last_emit_ns > 0 && now < view->gpu_last_emit_ns + NATIVE_SDK_GTK_GPU_FRAME_INTERVAL_NS) {
        delay_ns = view->gpu_last_emit_ns + NATIVE_SDK_GTK_GPU_FRAME_INTERVAL_NS - now;
    }
    view->gpu_emit_source = g_timeout_add_full(G_PRIORITY_DEFAULT_IDLE, (guint)((delay_ns + 500000ull) / 1000000ull), native_sdk_gpu_surface_emit_scheduled, view, NULL);
}

/* Placeholder pump: arms the scheduler every 16 ms until the first
 * present lands, so the runtime's install choreography (fonts, first
 * rebuild, first present) has frame events to ride before any producer
 * exists. The first present retires it; steady state never ticks it. */
static gboolean native_sdk_gpu_surface_placeholder_tick(gpointer data) {
    native_sdk_gtk_native_view_t *view = data;
    if (!view || !view->widget || !view->window || !view->window->host) return G_SOURCE_REMOVE;
    if (view->gpu_presented) {
        view->gpu_frame_timer = 0;
        return G_SOURCE_REMOVE;
    }
    native_sdk_gpu_surface_schedule_frame_emission(view);
    return G_SOURCE_CONTINUE;
}

/* GtkDrawingArea resize: report the new logical size immediately (the
 * demand-driven scheduler has no poll to catch it) so the runtime can
 * re-render at the new geometry; its present re-arms the scheduler. */
static void native_sdk_gpu_surface_resized(GtkDrawingArea *area, int width, int height, gpointer data) {
    (void)area;
    (void)width;
    (void)height;
    native_sdk_gtk_native_view_t *view = data;
    if (!view || !view->widget) return;
    const double logical_width = native_sdk_gpu_surface_width(view);
    const double logical_height = native_sdk_gpu_surface_height(view);
    if (logical_width <= 0 || logical_height <= 0) return;
    const double scale = (double)gtk_widget_get_scale_factor(view->widget);
    if (native_sdk_gpu_surface_sync_geometry(view, logical_width, logical_height, scale)) {
        gtk_widget_queue_draw(view->widget);
    }
}

static void native_sdk_gpu_surface_draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    native_sdk_gtk_native_view_t *view = data;
    if (!view || !view->gpu_argb || view->gpu_buf_width <= 0 || view->gpu_buf_height <= 0) return;
    cairo_surface_t *surface = cairo_image_surface_create_for_data(view->gpu_argb, CAIRO_FORMAT_ARGB32, view->gpu_buf_width, view->gpu_buf_height, view->gpu_buf_stride);
    if (!surface || cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        if (surface) cairo_surface_destroy(surface);
        return;
    }
    cairo_save(cr);
    /* The buffer is rendered at logical-size x scale-factor. Declare that
     * density as the surface's device scale so cairo maps one buffer pixel
     * to one device pixel; when the buffer matches the widget's current
     * scale exactly (the steady state), use nearest filtering for a
     * resample-free blit. Mid-resize frames where the buffer is stale
     * stretch with bilinear filtering until the next presented frame. */
    if (width > 0 && height > 0) {
        const double device_scale_x = (double)view->gpu_buf_width / (double)width;
        const double device_scale_y = (double)view->gpu_buf_height / (double)height;
        cairo_surface_set_device_scale(surface, device_scale_x, device_scale_y);
        const double widget_scale = (double)gtk_widget_get_scale_factor(GTK_WIDGET(area));
        const int exact = device_scale_x == widget_scale && device_scale_y == widget_scale;
        cairo_set_source_surface(cr, surface, 0, 0);
        cairo_pattern_set_filter(cairo_get_source(cr), exact ? CAIRO_FILTER_NEAREST : CAIRO_FILTER_BILINEAR);
    } else {
        cairo_set_source_surface(cr, surface, 0, 0);
        cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_BILINEAR);
    }
    cairo_paint(cr);
    cairo_restore(cr);
    cairo_surface_destroy(surface);
}

/* Begin the windowing system's interactive move from the window's last
 * recorded pointer press. Shared by the runtime `window_drag` channel
 * (native_sdk_gtk_start_window_drag) and the press-time drag-mirror
 * claim below. */
static void native_sdk_window_begin_interactive_move(native_sdk_gtk_window_t *win) {
    if (!win || !win->gtk_window) return;
    if (!win->last_press_device || win->last_press_time == 0) return;
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(win->gtk_window));
    if (!surface || !GDK_IS_TOPLEVEL(surface)) return;
    gdk_toplevel_begin_move(GDK_TOPLEVEL(surface), win->last_press_device,
                            win->last_press_button > 0 ? win->last_press_button : 1,
                            win->last_press_x, win->last_press_y, win->last_press_time);
}

/* A double press in a drag region follows the user's titlebar
 * double-click convention (the gtk-titlebar-double-click setting), the
 * same way the header bar itself would: toggle-maximize by default,
 * minimize/lower as configured, none disables it. The maximize variants
 * all toggle; a non-resizable window never maximizes. */
static void native_sdk_window_apply_titlebar_double_click(native_sdk_gtk_window_t *win) {
    if (!win || !win->gtk_window) return;
    char *configured = NULL;
    GtkSettings *settings = gtk_settings_get_default();
    if (settings) g_object_get(settings, "gtk-titlebar-double-click", &configured, NULL);
    const char *action = configured ? configured : "toggle-maximize";
    if (strncmp(action, "toggle-maximize", strlen("toggle-maximize")) == 0) {
        if (gtk_window_is_maximized(win->gtk_window)) {
            gtk_window_unmaximize(win->gtk_window);
        } else if (gtk_window_get_resizable(win->gtk_window)) {
            gtk_window_maximize(win->gtk_window);
        }
    } else if (strcmp(action, "minimize") == 0) {
        gtk_window_minimize(win->gtk_window);
    } else if (strcmp(action, "lower") == 0) {
        GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(win->gtk_window));
        if (surface && GDK_IS_TOPLEVEL(surface)) gdk_toplevel_lower(GDK_TOPLEVEL(surface));
    }
    g_free(configured);
}

/* A view-local logical point against the runtime-pushed drag mirror:
 * inside any exclusion rect -> not draggable (the widget keeps its
 * press), else inside any region rect -> draggable. */
static int native_sdk_gpu_point_in_drag_region(const native_sdk_gtk_native_view_t *view, double x, double y) {
    for (size_t i = 0; i < view->drag_region_count; i++) {
        const native_sdk_gtk_drag_region_t *rect = &view->drag_regions[i];
        if (!rect->exclusion) continue;
        if (x >= rect->x && x < rect->x + rect->width && y >= rect->y && y < rect->y + rect->height) return 0;
    }
    for (size_t i = 0; i < view->drag_region_count; i++) {
        const native_sdk_gtk_drag_region_t *rect = &view->drag_regions[i];
        if (rect->exclusion) continue;
        if (x >= rect->x && x < rect->x + rect->width && y >= rect->y && y < rect->y + rect->height) return 1;
    }
    return 0;
}

static void native_sdk_gpu_pointer_pressed(GtkGestureClick *gesture, int n_press, double x, double y, gpointer data) {
    native_sdk_gtk_native_view_t *view = data;
    if (!view || !view->widget) return;
    gtk_widget_grab_focus(view->widget);
    view->gpu_pointer_x = x;
    view->gpu_pointer_y = y;
    const int button = (int)gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture)) - 1;
    const uint32_t modifiers = native_sdk_gpu_modifier_flags(gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(gesture)));
    /* Stash the press for the widget `window_drag` channel: an
     * interactive window move must begin from the originating device,
     * button, position, and event time. */
    if (view->window) {
        GdkEvent *event = gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(gesture));
        graphene_point_t window_point = { (float)x, (float)y };
        graphene_point_t translated;
        if (view->window->gtk_window &&
            gtk_widget_compute_point(view->widget, GTK_WIDGET(view->window->gtk_window), &window_point, &translated)) {
            window_point = translated;
        }
        view->window->last_press_device = event ? gdk_event_get_device(event) : NULL;
        view->window->last_press_time = event ? gdk_event_get_time(event) : GDK_CURRENT_TIME;
        view->window->last_press_button = button < 0 ? 0 : button + 1;
        view->window->last_press_x = window_point.x;
        view->window->last_press_y = window_point.y;
    }
    /* The drag-region mirror is consumed HERE, at the press — the GTK
     * reading of the Win32 host answering WM_NCHITTEST with HTCAPTION:
     * a primary press inside a markup `window-drag` region (and outside
     * its press-claiming exclusions) hands the gesture to the window
     * before the widget pipeline ever hears about it, so no widget is
     * left pressed while the compositor owns the pointer. A double
     * press applies the user's titlebar double-click convention instead
     * of beginning a move, exactly like the real titlebar. */
    if (button == 0 && view->window && native_sdk_gpu_point_in_drag_region(view, x, y)) {
        view->gpu_drag_claimed_press = 1;
        if (n_press >= 2) {
            native_sdk_window_apply_titlebar_double_click(view->window);
        } else {
            native_sdk_window_begin_interactive_move(view->window);
        }
        return;
    }
    view->gpu_pointer_down = 1;
    native_sdk_emit_gpu_surface_input(view, NATIVE_SDK_GTK_GPU_INPUT_POINTER_DOWN, x, y, button < 0 ? 0 : button, 0, 0, "", "", modifiers);
}

static void native_sdk_gpu_pointer_released(GtkGestureClick *gesture, int n_press, double x, double y, gpointer data) {
    (void)n_press;
    native_sdk_gtk_native_view_t *view = data;
    if (!view) return;
    view->gpu_pointer_down = 0;
    view->gpu_pointer_x = x;
    view->gpu_pointer_y = y;
    /* The matching release of a drag-claimed press: the widget pipeline
     * never saw the down, so it must not see an orphaned up either. */
    if (view->gpu_drag_claimed_press) {
        view->gpu_drag_claimed_press = 0;
        return;
    }
    const int button = (int)gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture)) - 1;
    const uint32_t modifiers = native_sdk_gpu_modifier_flags(gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(gesture)));
    native_sdk_emit_gpu_surface_input(view, NATIVE_SDK_GTK_GPU_INPUT_POINTER_UP, x, y, button < 0 ? 0 : button, 0, 0, "", "", modifiers);
}

static void native_sdk_gpu_pointer_motion(GtkEventControllerMotion *controller, double x, double y, gpointer data) {
    native_sdk_gtk_native_view_t *view = data;
    if (!view) return;
    view->gpu_pointer_x = x;
    view->gpu_pointer_y = y;
    const uint32_t modifiers = native_sdk_gpu_modifier_flags(gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(controller)));
    const int kind = view->gpu_pointer_down ? NATIVE_SDK_GTK_GPU_INPUT_POINTER_DRAG : NATIVE_SDK_GTK_GPU_INPUT_POINTER_MOVE;
    native_sdk_emit_gpu_surface_input(view, kind, x, y, 0, 0, 0, "", "", modifiers);
}

static gboolean native_sdk_gpu_scroll(GtkEventControllerScroll *controller, double dx, double dy, gpointer data) {
    native_sdk_gtk_native_view_t *view = data;
    if (!view) return FALSE;
    double delta_x = dx;
    double delta_y = dy;
#if GTK_CHECK_VERSION(4, 8, 0)
    if (gtk_event_controller_scroll_get_unit(controller) == GDK_SCROLL_UNIT_WHEEL) {
        delta_x *= 40.0;
        delta_y *= 40.0;
    }
#else
    delta_x *= 40.0;
    delta_y *= 40.0;
#endif
    const uint32_t modifiers = native_sdk_gpu_modifier_flags(gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(controller)));
    native_sdk_emit_gpu_surface_input(view, NATIVE_SDK_GTK_GPU_INPUT_SCROLL, view->gpu_pointer_x, view->gpu_pointer_y, 0, delta_x, delta_y, "", "", modifiers);
    return TRUE;
}

static gboolean native_sdk_gpu_key_event(native_sdk_gtk_native_view_t *view, guint keyval, GdkModifierType state, int input_kind, int include_text) {
    char key_buffer[32];
    int uses_implicit_shift = 0;
    const char *key = native_sdk_shortcut_key_for_keyval(keyval, key_buffer, sizeof(key_buffer), &uses_implicit_shift);

    char text_buffer[8] = {0};
    if (include_text && input_kind == NATIVE_SDK_GTK_GPU_INPUT_KEY_DOWN &&
        (state & (GDK_CONTROL_MASK | GDK_ALT_MASK | GDK_META_MASK | GDK_SUPER_MASK)) == 0) {
        gunichar ch = gdk_keyval_to_unicode(keyval);
        if (ch >= 0x20 && ch != 0x7f) {
            int len = g_unichar_to_utf8(ch, text_buffer);
            text_buffer[len < 0 ? 0 : len] = '\0';
        }
    }

    if ((!key || !key[0]) && !text_buffer[0]) return FALSE;
    const uint32_t modifiers = native_sdk_gpu_modifier_flags(state);
    native_sdk_emit_gpu_surface_input(view, input_kind, view->gpu_pointer_x, view->gpu_pointer_y, 0, 0, 0, key, text_buffer, modifiers);
    return TRUE;
}

static gboolean native_sdk_gpu_key_pressed(GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state, gpointer data) {
    (void)keycode;
    native_sdk_gtk_native_view_t *view = data;
    if (!view) return FALSE;
    GdkEvent *event = gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(controller));
    if (view->gpu_im_context && event && gtk_im_context_filter_keypress(view->gpu_im_context, event)) {
        /* The IM context consumed the key: committed text and preedit updates
         * already flowed through the commit / preedit-changed handlers as
         * text_input / ime_* events. Still surface a key_down with an empty
         * text payload so activation keys (space, enter) and canvas key
         * handlers keep firing; the runtime only inserts text from key_down
         * events that carry text, so nothing is inserted twice. */
        (void)native_sdk_gpu_key_event(view, keyval, state, NATIVE_SDK_GTK_GPU_INPUT_KEY_DOWN, 0);
        return TRUE;
    }
    return native_sdk_gpu_key_event(view, keyval, state, NATIVE_SDK_GTK_GPU_INPUT_KEY_DOWN, 1);
}

static void native_sdk_gpu_key_released(GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state, gpointer data) {
    (void)keycode;
    native_sdk_gtk_native_view_t *view = data;
    if (!view) return;
    GdkEvent *event = gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(controller));
    if (view->gpu_im_context && event) (void)gtk_im_context_filter_keypress(view->gpu_im_context, event);
    (void)native_sdk_gpu_key_event(view, keyval, state, NATIVE_SDK_GTK_GPU_INPUT_KEY_UP, 0);
}

static void native_sdk_gpu_focus_enter(GtkEventControllerFocus *controller, gpointer data) {
    (void)controller;
    native_sdk_gtk_native_view_t *view = data;
    if (view && view->gpu_im_context) gtk_im_context_focus_in(view->gpu_im_context);
}

static void native_sdk_gpu_focus_leave(GtkEventControllerFocus *controller, gpointer data) {
    (void)controller;
    native_sdk_gtk_native_view_t *view = data;
    if (!view || !view->gpu_im_context) return;
    /* Losing focus mid-composition cancels it, like AppKit's unmarkText-on-
     * resign path; reset the IM context so a stale compose state does not
     * leak into the next focus. */
    if (native_sdk_gpu_surface_has_preedit(view)) {
        native_sdk_gpu_surface_clear_preedit(view);
        native_sdk_emit_gpu_surface_text_input(view, NATIVE_SDK_GTK_GPU_INPUT_IME_CANCEL_COMPOSITION, "", 0, 0);
    }
    gtk_im_context_reset(view->gpu_im_context);
    gtk_im_context_focus_out(view->gpu_im_context);
}

static void native_sdk_setup_gpu_surface_view(native_sdk_gtk_native_view_t *view) {
    if (!view || !view->widget || view->kind != NATIVE_SDK_GTK_VIEW_GPU_SURFACE) return;

    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(view->widget), native_sdk_gpu_surface_draw, view, NULL);

    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), 0);
    g_signal_connect(click, "pressed", G_CALLBACK(native_sdk_gpu_pointer_pressed), view);
    g_signal_connect(click, "released", G_CALLBACK(native_sdk_gpu_pointer_released), view);
    gtk_widget_add_controller(view->widget, GTK_EVENT_CONTROLLER(click));

    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(native_sdk_gpu_pointer_motion), view);
    gtk_widget_add_controller(view->widget, motion);

    GtkEventController *scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
    g_signal_connect(scroll, "scroll", G_CALLBACK(native_sdk_gpu_scroll), view);
    gtk_widget_add_controller(view->widget, scroll);

    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(native_sdk_gpu_key_pressed), view);
    g_signal_connect(keys, "key-released", G_CALLBACK(native_sdk_gpu_key_released), view);
    gtk_widget_add_controller(view->widget, keys);

    view->gpu_im_context = gtk_im_multicontext_new();
    gtk_im_context_set_client_widget(view->gpu_im_context, view->widget);
    g_signal_connect(view->gpu_im_context, "commit", G_CALLBACK(native_sdk_gpu_im_commit), view);
    g_signal_connect(view->gpu_im_context, "preedit-changed", G_CALLBACK(native_sdk_gpu_im_preedit_changed), view);

    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "enter", G_CALLBACK(native_sdk_gpu_focus_enter), view);
    g_signal_connect(focus, "leave", G_CALLBACK(native_sdk_gpu_focus_leave), view);
    gtk_widget_add_controller(view->widget, focus);

    g_signal_connect(view->widget, "notify::scale-factor", G_CALLBACK(native_sdk_gpu_surface_scale_changed), view);
    g_signal_connect(view->widget, "resize", G_CALLBACK(native_sdk_gpu_surface_resized), view);

    gtk_widget_grab_focus(view->widget);
    view->gpu_frame_timer = g_timeout_add(16, native_sdk_gpu_surface_placeholder_tick, view);
}

static void native_sdk_teardown_gpu_surface_view(native_sdk_gtk_native_view_t *view) {
    if (!view) return;
    if (view->gpu_frame_timer) {
        g_source_remove(view->gpu_frame_timer);
        view->gpu_frame_timer = 0;
    }
    if (view->gpu_emit_source) {
        g_source_remove(view->gpu_emit_source);
        view->gpu_emit_source = 0;
    }
    if (view->widget && view->kind == NATIVE_SDK_GTK_VIEW_GPU_SURFACE) {
        gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(view->widget), NULL, NULL, NULL);
        g_signal_handlers_disconnect_by_data(view->widget, view);
    }
    if (view->gpu_im_context) {
        g_signal_handlers_disconnect_by_data(view->gpu_im_context, view);
        gtk_im_context_set_client_widget(view->gpu_im_context, NULL);
        g_object_unref(view->gpu_im_context);
        view->gpu_im_context = NULL;
    }
    native_sdk_gpu_surface_clear_preedit(view);
    free(view->gpu_argb);
    view->gpu_argb = NULL;
    view->gpu_buf_width = 0;
    view->gpu_buf_height = 0;
    view->gpu_buf_stride = 0;
}

static void native_sdk_apply_native_view_frame(native_sdk_gtk_native_view_t *view) {
    if (!view || !view->widget) return;
    GtkWidget *widget = view->widget;
    gtk_widget_set_halign(widget, GTK_ALIGN_START);
    gtk_widget_set_valign(widget, GTK_ALIGN_START);
    gtk_widget_set_size_request(widget, native_sdk_native_extent(view->width), native_sdk_native_extent(view->height));
    if (view->parent && view->parent[0]) {
        native_sdk_gtk_native_view_t *parent = native_sdk_find_native_view(view->window, view->parent);
        if (parent && parent->widget && GTK_IS_FIXED(parent->widget)) {
            gtk_fixed_move(GTK_FIXED(parent->widget), widget, view->x, view->y);
        }
        return;
    }
    gtk_widget_set_margin_start(widget, native_sdk_native_coord(view->x));
    gtk_widget_set_margin_top(widget, native_sdk_native_coord(view->y));
}

static void native_sdk_apply_native_view_text(native_sdk_gtk_native_view_t *view, const char *text) {
    if (!view || !view->widget || !text) return;
    GtkWidget *widget = view->widget;
    if (GTK_IS_CHECK_BUTTON(widget)) {
        gtk_check_button_set_label(GTK_CHECK_BUTTON(widget), text);
    } else if (GTK_IS_BUTTON(widget)) {
        gtk_button_set_label(GTK_BUTTON(widget), text);
    } else if (GTK_IS_LABEL(widget)) {
        gtk_label_set_text(GTK_LABEL(widget), text);
    } else if (GTK_IS_ENTRY(widget)) {
        gtk_entry_set_placeholder_text(GTK_ENTRY(widget), text);
    } else if (GTK_IS_BOX(widget) && view->kind == NATIVE_SDK_GTK_VIEW_SEGMENTED_CONTROL) {
        native_sdk_configure_segmented_widget(widget, text);
    }
}

static void native_sdk_apply_native_view_state(native_sdk_gtk_native_view_t *view, int update_text, const char *text) {
    if (!view || !view->widget) return;
    gtk_widget_set_visible(view->widget, view->visible != 0);
    gtk_widget_set_sensitive(view->widget, view->enabled != 0);
    if (update_text) native_sdk_apply_native_view_text(view, text);
    gtk_accessible_update_property(GTK_ACCESSIBLE(view->widget), GTK_ACCESSIBLE_PROPERTY_LABEL, native_sdk_native_accessibility_label(view), -1);
}

static void native_sdk_emit_native_action(GtkWidget *widget, gpointer data) {
    (void)widget;
    native_sdk_gtk_native_view_t *view = data;
    if (!view || !view->window || !view->command || !view->command[0]) return;
    native_sdk_emit(view->window->host, (native_sdk_gtk_event_t){
        .kind = NATIVE_SDK_GTK_EVENT_NATIVE_COMMAND,
        .window_id = view->window->id,
        .command_name = view->command,
        .command_name_len = strlen(view->command),
        .view_label = view->label ? view->label : "",
        .view_label_len = view->label ? strlen(view->label) : 0,
    });
}

static void native_sdk_configure_native_view_action(native_sdk_gtk_native_view_t *view) {
    if (!view || !view->widget) return;
    if (view->action_handler != 0) {
        g_signal_handler_disconnect(view->widget, view->action_handler);
        view->action_handler = 0;
    }
    if (GTK_IS_BOX(view->widget) && view->kind == NATIVE_SDK_GTK_VIEW_SEGMENTED_CONTROL) {
        GtkWidget *child = gtk_widget_get_first_child(view->widget);
        while (child) {
            g_signal_handlers_disconnect_by_data(child, view);
            if (GTK_IS_BUTTON(child)) {
                if (view->command && view->command[0]) g_signal_connect(child, "clicked", G_CALLBACK(native_sdk_emit_native_action), view);
            }
            child = gtk_widget_get_next_sibling(child);
        }
        return;
    }
    if (!view->command || !view->command[0]) return;
    if (GTK_IS_CHECK_BUTTON(view->widget)) {
        view->action_handler = g_signal_connect(view->widget, "toggled", G_CALLBACK(native_sdk_emit_native_action), view);
    } else if (GTK_IS_BUTTON(view->widget)) {
        view->action_handler = g_signal_connect(view->widget, "clicked", G_CALLBACK(native_sdk_emit_native_action), view);
    }
}

static void native_sdk_reorder_overlays(native_sdk_gtk_window_t *win) {
    if (!win || !win->stack_root) return;
    int placed[NATIVE_SDK_MAX_WEBVIEWS] = {0};
    int native_placed[NATIVE_SDK_MAX_NATIVE_VIEWS] = {0};
    /* GTK picks and paints later siblings on top, so ascending layer =
     * ascending sibling order. The window WebView participates with
     * `main_webview_layer` (default 0) and wins ties, keeping it the
     * bottom-most sibling for the classic overlays-above-main layout
     * while letting apps sink it under (or float it over) child views. */
    GtkWidget *previous = NULL;
    int main_placed = win->web_view ? 0 : 1;
    int total = win->webview_count + win->native_view_count + (main_placed ? 0 : 1);
    for (int pass = 0; pass < total; pass++) {
        int best_webview = -1;
        int best_native = -1;
        for (int i = 0; i < win->webview_count; i++) {
            if (!win->webviews[i].web_view) continue;
            if (placed[i]) continue;
            if (best_webview < 0 || win->webviews[i].layer < win->webviews[best_webview].layer) best_webview = i;
        }
        for (int i = 0; i < NATIVE_SDK_MAX_NATIVE_VIEWS; i++) {
            native_sdk_gtk_native_view_t *view = &win->native_views[i];
            if (!view->widget || (view->parent && view->parent[0])) continue;
            if (native_placed[i]) continue;
            if (best_native < 0 || view->layer < win->native_views[best_native].layer) best_native = i;
        }

        GtkWidget *next = NULL;
        if (!main_placed) {
            int take_main = 1;
            if (best_webview >= 0 && win->webviews[best_webview].layer < win->main_webview_layer) take_main = 0;
            if (best_native >= 0 && win->native_views[best_native].layer < win->main_webview_layer) take_main = 0;
            if (take_main) {
                next = GTK_WIDGET(win->web_view);
                main_placed = 1;
            }
        }
        if (!next && best_webview >= 0 && best_native >= 0) {
            if (win->webviews[best_webview].layer <= win->native_views[best_native].layer) {
                next = GTK_WIDGET(win->webviews[best_webview].web_view);
                placed[best_webview] = 1;
            } else {
                next = win->native_views[best_native].widget;
                native_placed[best_native] = 1;
            }
        } else if (!next && best_webview >= 0) {
            next = GTK_WIDGET(win->webviews[best_webview].web_view);
            placed[best_webview] = 1;
        } else if (!next && best_native >= 0) {
            next = win->native_views[best_native].widget;
            native_placed[best_native] = 1;
        }
        if (!next) break;

        gtk_widget_insert_after(next, GTK_WIDGET(win->stack_root), previous);
        previous = next;
    }
}

static void native_sdk_clear_native_view(native_sdk_gtk_window_t *win, native_sdk_gtk_native_view_t *view);

static void native_sdk_remove_native_children(native_sdk_gtk_window_t *win, const char *parent_label) {
    if (!win || !parent_label) return;
    for (int i = 0; i < NATIVE_SDK_MAX_NATIVE_VIEWS; i++) {
        native_sdk_gtk_native_view_t *child = &win->native_views[i];
        if (!child->label || !child->parent || strcmp(child->parent, parent_label) != 0) continue;
        native_sdk_clear_native_view(win, child);
    }
}

static void native_sdk_clear_native_view(native_sdk_gtk_window_t *win, native_sdk_gtk_native_view_t *view) {
    if (!view || !view->label) return;
    char *label = native_sdk_strndup(view->label, strlen(view->label));
    if (label) {
        native_sdk_remove_native_children(win, label);
        free(label);
    }
    native_sdk_teardown_gpu_surface_view(view);
    if (view->widget) {
        if (view->action_handler != 0) {
            g_signal_handler_disconnect(view->widget, view->action_handler);
            view->action_handler = 0;
        }
        if (view->parent && view->parent[0]) {
            native_sdk_gtk_native_view_t *parent = native_sdk_find_native_view(win, view->parent);
            if (parent && parent->widget && GTK_IS_FIXED(parent->widget)) {
                gtk_fixed_remove(GTK_FIXED(parent->widget), view->widget);
            } else {
                gtk_widget_unparent(view->widget);
            }
        } else if (win && win->stack_root) {
            gtk_overlay_remove_overlay(GTK_OVERLAY(win->stack_root), view->widget);
        } else {
            gtk_widget_unparent(view->widget);
        }
    }
    free(view->label);
    free(view->parent);
    free(view->role);
    free(view->accessibility_label);
    free(view->text);
    free(view->command);
    free(view->drag_regions);
    memset(view, 0, sizeof(*view));
    if (win && win->native_view_count > 0) win->native_view_count--;
}

static void native_sdk_clear_native_views(native_sdk_gtk_window_t *win) {
    if (!win) return;
    for (int i = 0; i < NATIVE_SDK_MAX_NATIVE_VIEWS; i++) {
        if (win->native_views[i].label) native_sdk_clear_native_view(win, &win->native_views[i]);
    }
    win->native_view_count = 0;
}

static void native_sdk_clear_webview(native_sdk_gtk_window_t *win, native_sdk_gtk_webview_t *webview) {
    if (!webview) return;
    if (webview->web_view && win && win->stack_root) {
        gtk_overlay_remove_overlay(GTK_OVERLAY(win->stack_root), GTK_WIDGET(webview->web_view));
    }
    free(webview->label);
    memset(webview, 0, sizeof(*webview));
}

static void native_sdk_remove_webview_at(native_sdk_gtk_window_t *win, int index) {
    if (!win || index < 0 || index >= win->webview_count) return;
    native_sdk_clear_webview(win, &win->webviews[index]);
    for (int i = index; i + 1 < win->webview_count; i++) {
        win->webviews[i] = win->webviews[i + 1];
    }
    memset(&win->webviews[win->webview_count - 1], 0, sizeof(win->webviews[win->webview_count - 1]));
    win->webview_count--;
}

static void native_sdk_clear_webviews(native_sdk_gtk_window_t *win) {
    if (!win) return;
    while (win->webview_count > 0) {
        native_sdk_remove_webview_at(win, win->webview_count - 1);
    }
}

static void native_sdk_clear_window(native_sdk_gtk_window_t *win) {
    if (!win) return;
    native_sdk_clear_native_views(win);
    native_sdk_clear_webviews(win);
    native_sdk_clear_window_source(win);
    free(win->label);
    free(win->title);
    memset(win, 0, sizeof(*win));
}

static char *native_sdk_origin_for_uri(const char *uri) {
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

static int native_sdk_policy_wildcard_prefix_has_path(const char *prefix, size_t prefix_len) {
    if (!prefix || prefix_len == 0) return 0;
    const char *end = prefix + prefix_len;
    const char *scheme_end = strstr(prefix, "://");
    if (!scheme_end || scheme_end >= end) return 0;
    const char *host_start = scheme_end + 3;
    if (host_start >= end) return 0;
    const char *slash = memchr(host_start, '/', (size_t)(end - host_start));
    return slash && slash > host_start;
}

static int native_sdk_policy_list_matches(char **values, int count, const char *uri) {
    char *origin = native_sdk_origin_for_uri(uri);
    int matched = 0;
    for (int i = 0; i < count && !matched; i++) {
        const char *value = values[i];
        size_t len = strlen(value);
        if (strcmp(value, "*") == 0 || strcmp(value, origin) == 0 || (uri && strcmp(value, uri) == 0)) {
            matched = 1;
        } else if (len > 0 && value[len - 1] == '*') {
            size_t prefix_len = len - 1;
            matched = uri && native_sdk_policy_wildcard_prefix_has_path(value, prefix_len) && strncmp(uri, value, prefix_len) == 0;
        }
    }
    g_free(origin);
    return matched;
}

static int native_sdk_path_is_safe(const char *path) {
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

static const char *native_sdk_bridge_script(void) {
    return
        "(function(){"
        "if(window.zero&&window.zero.invoke){return;}"
        "var pending=new Map();"
        "var listeners=new Map();"
        "var nextId=1;"
        "function post(message){"
        "window.webkit.messageHandlers.nativeSdkBridge.postMessage(message);"
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
        "update:function(options,patch){if(typeof options==='string'){return invoke('native-sdk.view.update',viewPatchPayload(Object.assign({},patch||{},{label:options}))).then(viewHandle);}"
        "return invoke('native-sdk.view.update',viewPatchPayload(options)).then(viewHandle);},"
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

static const char *native_sdk_mime_for_ext(const char *path) {
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

static native_sdk_gtk_window_t *native_sdk_window_for_asset_uri(native_sdk_gtk_host_t *host, const char *uri, WebKitWebView *request_web_view, int request_web_view_supported) {
    char *origin = native_sdk_origin_for_uri(uri);
    if (!origin) return NULL;

    if (request_web_view_supported) {
        native_sdk_gtk_window_t *win = native_sdk_window_for_web_view(host, request_web_view);
        if (win && win->asset_root && native_sdk_window_allows_asset_origin(win, origin)) {
            g_free(origin);
            return win;
        }
        g_free(origin);
        return NULL;
    }

    native_sdk_gtk_window_t *public_match = NULL;
    int public_match_count = 0;
    for (int i = 0; i < host->window_count; i++) {
        native_sdk_gtk_window_t *win = &host->windows[i];
        if (!win->asset_root) continue;
        if (native_sdk_strings_equal(win->asset_origin, origin)) {
            g_free(origin);
            return win;
        }
        if (native_sdk_strings_equal(win->bridge_origin, origin)) {
            public_match = win;
            public_match_count += 1;
        }
    }
    if (public_match_count == 1) {
        g_free(origin);
        return public_match;
    }
    g_free(origin);
    return NULL;
}

static char *native_sdk_asset_relative_path(const char *uri, const char *entry) {
    const char *path = strstr(uri, "://");
    path = path ? strchr(path + 3, '/') : NULL;
    if (!path || !path[1]) return g_strdup(entry && entry[0] ? entry : "index.html");
    while (*path == '/') path++;
    const char *path_end = path;
    while (*path_end && *path_end != '?' && *path_end != '#') path_end++;
    if (path_end == path) return g_strdup(entry && entry[0] ? entry : "index.html");
    char *raw = g_strndup(path, (gsize)(path_end - path));
    if (!raw) return NULL;
    char *unescaped = g_uri_unescape_string(raw, NULL);
    g_free(raw);
    if (!unescaped) return NULL;
    if (!native_sdk_path_is_safe(unescaped)) {
        g_free(unescaped);
        return NULL;
    }
    return unescaped;
}

static void native_sdk_fail_scheme_request(WebKitURISchemeRequest *request, GQuark domain, int code, const char *message) {
    GError *error = g_error_new_literal(domain, code, message);
    webkit_uri_scheme_request_finish_error(request, error);
    g_error_free(error);
}

static void native_sdk_asset_scheme_request(WebKitURISchemeRequest *request, gpointer data) {
    native_sdk_gtk_host_t *host = data;
    const char *uri = webkit_uri_scheme_request_get_uri(request);
    int request_web_view_supported = native_sdk_request_web_view_supported();
    WebKitWebView *request_web_view = request_web_view_supported ? native_sdk_request_web_view(request) : NULL;
    native_sdk_gtk_window_t *win = native_sdk_window_for_asset_uri(host, uri, request_web_view, request_web_view_supported);
    if (!win || !win->asset_root) {
        native_sdk_fail_scheme_request(request, G_IO_ERROR, G_IO_ERROR_NOT_FOUND, "No asset root is configured");
        return;
    }

    char *relative = native_sdk_asset_relative_path(uri, win->asset_entry);
    if (!relative) {
        native_sdk_fail_scheme_request(request, G_IO_ERROR, G_IO_ERROR_INVALID_FILENAME, "Unsafe asset path");
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
    webkit_uri_scheme_request_finish(request, stream, (gint64)length, native_sdk_mime_for_ext(path));
    g_object_unref(stream);
    g_free(path);
    g_free(relative);
}

static native_sdk_gtk_window_t *native_sdk_find_window(native_sdk_gtk_host_t *host, uint64_t id) {
    for (int i = 0; i < host->window_count; i++) {
        if (host->windows[i].id == id && host->windows[i].gtk_window) return &host->windows[i];
    }
    return NULL;
}

static native_sdk_gtk_webview_t *native_sdk_find_webview(native_sdk_gtk_window_t *win, const char *label) {
    if (!win || !label) return NULL;
    for (int i = 0; i < win->webview_count; i++) {
        if (win->webviews[i].label && strcmp(win->webviews[i].label, label) == 0) return &win->webviews[i];
    }
    return NULL;
}

static void native_sdk_emit(native_sdk_gtk_host_t *host, native_sdk_gtk_event_t event) {
    if (host->callback) host->callback(host->callback_context, &event);
}

static void native_sdk_append_file_path(GString *paths, GFile *file) {
    if (!paths || !file) return;
    char *path = g_file_get_path(file);
    if (!path || path[0] == '\0') {
        g_free(path);
        return;
    }
    if (paths->len > 0) g_string_append_c(paths, '\0');
    g_string_append(paths, path);
    g_free(path);
}

static gboolean native_sdk_emit_file_drop(native_sdk_gtk_window_t *win, const char *paths, size_t paths_len) {
    if (!win || !win->host || !paths || paths_len == 0) return FALSE;
    native_sdk_emit(win->host, (native_sdk_gtk_event_t){
        .kind = NATIVE_SDK_GTK_EVENT_FILES_DROPPED,
        .window_id = win->id,
        .drop_paths = paths,
        .drop_paths_len = paths_len,
    });
    return TRUE;
}

static gboolean native_sdk_on_file_drop(GtkDropTarget *target, const GValue *value, double x, double y, gpointer data) {
    (void)target;
    (void)x;
    (void)y;
    native_sdk_gtk_window_t *win = data;
    if (!win || !value) return FALSE;

    GString *paths = g_string_new(NULL);
    if (!paths) return FALSE;
    if (G_VALUE_HOLDS(value, G_TYPE_FILE)) {
        native_sdk_append_file_path(paths, G_FILE(g_value_get_object(value)));
    }
#ifdef GDK_TYPE_FILE_LIST
    else if (G_VALUE_HOLDS(value, GDK_TYPE_FILE_LIST)) {
        GdkFileList *file_list = g_value_get_boxed(value);
        if (file_list) {
            GSList *files = gdk_file_list_get_files(file_list);
            for (GSList *item = files; item; item = item->next) {
                native_sdk_append_file_path(paths, G_FILE(item->data));
            }
            g_slist_free(files);
        }
    }
#endif

    gboolean handled = native_sdk_emit_file_drop(win, paths->str, paths->len);
    g_string_free(paths, TRUE);
    return handled;
}

static void native_sdk_install_file_drop_target(native_sdk_gtk_window_t *win) {
    if (!win || !win->root_box) return;
    GtkDropTarget *target = gtk_drop_target_new(G_TYPE_FILE, GDK_ACTION_COPY);
    if (!target) return;
#ifdef GDK_TYPE_FILE_LIST
    GType drop_types[] = { G_TYPE_FILE, GDK_TYPE_FILE_LIST };
    gtk_drop_target_set_gtypes(target, drop_types, G_N_ELEMENTS(drop_types));
#endif
    g_signal_connect(target, "drop", G_CALLBACK(native_sdk_on_file_drop), win);
    gtk_widget_add_controller(win->root_box, GTK_EVENT_CONTROLLER(target));
}

static uint64_t native_sdk_active_window_id(native_sdk_gtk_host_t *host) {
    if (!host) return 1;
    GtkWindow *active = host->app ? gtk_application_get_active_window(host->app) : NULL;
    if (active) {
        for (int i = 0; i < host->window_count; i++) {
            if (host->windows[i].gtk_window == active) return host->windows[i].id;
        }
    }
    for (int i = 0; i < host->window_count; i++) {
        if (host->windows[i].gtk_window) return host->windows[i].id;
    }
    return 1;
}

static void native_sdk_menu_action_activate(GSimpleAction *action, GVariant *parameter, gpointer data) {
    (void)action;
    (void)parameter;
    native_sdk_gtk_menu_action_t *menu_action = data;
    if (!menu_action || !menu_action->host || !menu_action->command || !menu_action->command[0]) return;
    native_sdk_emit(menu_action->host, (native_sdk_gtk_event_t){
        .kind = NATIVE_SDK_GTK_EVENT_MENU_COMMAND,
        .window_id = native_sdk_active_window_id(menu_action->host),
        .command_name = menu_action->command,
        .command_name_len = strlen(menu_action->command),
    });
}

static void native_sdk_apply_menu_model_to_window(native_sdk_gtk_host_t *host, native_sdk_gtk_window_t *win) {
    if (!host || !win || !win->menu_bar) return;
    gtk_popover_menu_bar_set_menu_model(GTK_POPOVER_MENU_BAR(win->menu_bar), host->menu_model);
    gtk_widget_set_visible(win->menu_bar, host->menu_model != NULL);
}

static const char *native_sdk_accel_key_name(const char *key) {
    if (!key || !key[0]) return "";
    if (strcmp(key, "escape") == 0) return "Escape";
    if (strcmp(key, "enter") == 0) return "Return";
    if (strcmp(key, "tab") == 0) return "Tab";
    if (strcmp(key, "space") == 0) return "space";
    if (strcmp(key, "backspace") == 0) return "BackSpace";
    if (strcmp(key, "arrowleft") == 0) return "Left";
    if (strcmp(key, "arrowright") == 0) return "Right";
    if (strcmp(key, "arrowup") == 0) return "Up";
    if (strcmp(key, "arrowdown") == 0) return "Down";
    return key;
}

static char *native_sdk_menu_accel(const char *key, uint32_t modifiers) {
    if (!key || !key[0]) return NULL;
    GString *accel = g_string_new("");
    if ((modifiers & NATIVE_SDK_SHORTCUT_MODIFIER_PRIMARY) != 0 || (modifiers & NATIVE_SDK_SHORTCUT_MODIFIER_CONTROL) != 0) g_string_append(accel, "<Control>");
    if ((modifiers & NATIVE_SDK_SHORTCUT_MODIFIER_COMMAND) != 0) g_string_append(accel, "<Super>");
    if ((modifiers & NATIVE_SDK_SHORTCUT_MODIFIER_OPTION) != 0) g_string_append(accel, "<Alt>");
    if ((modifiers & NATIVE_SDK_SHORTCUT_MODIFIER_SHIFT) != 0) g_string_append(accel, "<Shift>");
    g_string_append(accel, native_sdk_accel_key_name(key));
    return g_string_free(accel, FALSE);
}

static void native_sdk_append_menu_section(GMenu *menu, GMenu **section) {
    if (!menu || !section || !*section) return;
    if (g_menu_model_get_n_items(G_MENU_MODEL(*section)) > 0) {
        g_menu_append_section(menu, NULL, G_MENU_MODEL(*section));
    }
    g_object_unref(*section);
    *section = g_menu_new();
}

static int native_sdk_any_window_active(native_sdk_gtk_host_t *host) {
    if (!host) return 0;
    for (int i = 0; i < host->window_count; i++) {
        native_sdk_gtk_window_t *win = &host->windows[i];
        if (win->gtk_window && gtk_window_is_active(win->gtk_window)) return 1;
    }
    return 0;
}

static void native_sdk_emit_app_active_if_changed(native_sdk_gtk_host_t *host) {
    if (!host) return;
    int active = native_sdk_any_window_active(host);
    if (host->app_active == active) return;
    host->app_active = active;
    native_sdk_emit(host, (native_sdk_gtk_event_t){
        .kind = active ? NATIVE_SDK_GTK_EVENT_APP_ACTIVATED : NATIVE_SDK_GTK_EVENT_APP_DEACTIVATED,
    });
}

/* Current window content size, falling back to the pending default size
 * while the widget is not yet allocated. `notify::default-width` fires
 * before the first allocation, and reporting that transient 0x0 as truth
 * would poison the runtime's window bounds right when startup shell
 * layout runs (hosts with synchronous window creation always report the
 * real initial frame). */
static void native_sdk_window_content_size(native_sdk_gtk_window_t *win, int *out_width, int *out_height) {
    /* The area the runtime lays views into is the window CHILD's
     * allocation: on hidden-titlebar (client-side decorated) windows
     * the header bar owns the top band and the child sits below it, so
     * the window widget's own height would over-report by the bar.
     * Standard windows allocate the child the full widget, so the two
     * reads agree there. */
    int w = win->root_box ? gtk_widget_get_width(win->root_box) : 0;
    int h = win->root_box ? gtk_widget_get_height(win->root_box) : 0;
    if (w <= 0 || h <= 0) {
        w = gtk_widget_get_width(GTK_WIDGET(win->gtk_window));
        h = gtk_widget_get_height(GTK_WIDGET(win->gtk_window));
    }
    if (w <= 0 || h <= 0) {
        int default_w = 0, default_h = 0;
        gtk_window_get_default_size(win->gtk_window, &default_w, &default_h);
        if (w <= 0) w = default_w;
        if (h <= 0) h = default_h;
    }
    *out_width = w;
    *out_height = h;
}

/* Appearance from the toolkit settings: the application dark preference
 * (or a theme whose name says dark), disabled animations as the reduce-
 * motion signal, and a high-contrast theme name. Emitted once after
 * START and again whenever any of those settings change. */
static void native_sdk_emit_appearance(native_sdk_gtk_host_t *host) {
    GtkSettings *settings = gtk_settings_get_default();
    if (!settings) return;
    gboolean prefer_dark = FALSE;
    gboolean enable_animations = TRUE;
    char *theme_name = NULL;
    g_object_get(settings,
                 "gtk-application-prefer-dark-theme", &prefer_dark,
                 "gtk-enable-animations", &enable_animations,
                 "gtk-theme-name", &theme_name,
                 NULL);
    int dark = prefer_dark ? 1 : 0;
    int high_contrast = 0;
    if (theme_name) {
        char *lower = g_ascii_strdown(theme_name, -1);
        if (strstr(lower, "dark")) dark = 1;
        if (strstr(lower, "highcontrast") || strstr(lower, "high-contrast")) high_contrast = 1;
        g_free(lower);
        g_free(theme_name);
    }
    native_sdk_emit(host, (native_sdk_gtk_event_t){
        .kind = NATIVE_SDK_GTK_EVENT_APPEARANCE,
        .color_scheme = dark,
        .reduce_motion = enable_animations ? 0 : 1,
        .high_contrast = high_contrast,
    });
}

static void native_sdk_on_appearance_setting_changed(GObject *settings, GParamSpec *pspec, gpointer data) {
    (void)settings;
    (void)pspec;
    native_sdk_emit_appearance((native_sdk_gtk_host_t *)data);
}

/* The user moved the window buttons (the gtk-decoration-layout
 * setting): the header-bar control clusters re-fill on the next layout
 * pass, so nudge every hidden-titlebar canvas with its current
 * geometry once idle — the runtime re-queries window chrome on every
 * canvas resize event and dispatches to the app only when the geometry
 * actually changed. Low priority so the nudge lands after the bar has
 * re-laid out. */
static gboolean native_sdk_nudge_chrome_requery(gpointer data) {
    native_sdk_gtk_host_t *host = data;
    for (int i = 0; i < host->window_count; i++) {
        native_sdk_gtk_window_t *win = &host->windows[i];
        if (!win->gtk_window || !win->header_bar) continue;
        for (int v = 0; v < NATIVE_SDK_MAX_NATIVE_VIEWS; v++) {
            native_sdk_gtk_native_view_t *view = &win->native_views[v];
            if (!view->label || view->kind != NATIVE_SDK_GTK_VIEW_GPU_SURFACE) continue;
            if (view->gpu_emitted_width <= 0 || view->gpu_emitted_height <= 0) continue;
            native_sdk_emit(host, (native_sdk_gtk_event_t){
                .kind = NATIVE_SDK_GTK_EVENT_GPU_SURFACE_RESIZE,
                .window_id = win->id,
                .view_label = view->label,
                .view_label_len = strlen(view->label),
                .x = view->x,
                .y = view->y,
                .width = view->gpu_emitted_width,
                .height = view->gpu_emitted_height,
                .scale = view->gpu_emitted_scale,
                .timestamp_ns = native_sdk_gpu_timestamp_ns(),
            });
        }
    }
    return G_SOURCE_REMOVE;
}

static void native_sdk_on_decoration_layout_changed(GObject *settings, GParamSpec *pspec, gpointer data) {
    (void)settings;
    (void)pspec;
    g_idle_add_full(G_PRIORITY_LOW, native_sdk_nudge_chrome_requery, data, NULL);
}

static void native_sdk_on_header_bar_mapped(GtkWidget *widget, gpointer data) {
    (void)widget;
    g_idle_add_full(G_PRIORITY_LOW, native_sdk_nudge_chrome_requery, data, NULL);
}

static void native_sdk_watch_appearance(native_sdk_gtk_host_t *host) {
    GtkSettings *settings = gtk_settings_get_default();
    if (!settings) return;
    g_signal_connect(settings, "notify::gtk-application-prefer-dark-theme", G_CALLBACK(native_sdk_on_appearance_setting_changed), host);
    g_signal_connect(settings, "notify::gtk-theme-name", G_CALLBACK(native_sdk_on_appearance_setting_changed), host);
    g_signal_connect(settings, "notify::gtk-enable-animations", G_CALLBACK(native_sdk_on_appearance_setting_changed), host);
    g_signal_connect(settings, "notify::gtk-decoration-layout", G_CALLBACK(native_sdk_on_decoration_layout_changed), host);
}

static void native_sdk_emit_window_frame(native_sdk_gtk_host_t *host, native_sdk_gtk_window_t *win, int open) {
    if (!win || !win->gtk_window) return;
    int w = 0, h = 0;
    native_sdk_window_content_size(win, &w, &h);
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(win->gtk_window));
    double scale = surface ? gdk_surface_get_scale_factor(surface) : 1.0;
    int focused = gtk_window_is_active(win->gtk_window) ? 1 : 0;
    native_sdk_emit(host, (native_sdk_gtk_event_t){
        .kind = NATIVE_SDK_GTK_EVENT_WINDOW_FRAME,
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

static void native_sdk_emit_resize(native_sdk_gtk_host_t *host, native_sdk_gtk_window_t *win) {
    if (!win || !win->gtk_window) return;
    int w = 0, h = 0;
    native_sdk_window_content_size(win, &w, &h);
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(win->gtk_window));
    double scale = surface ? gdk_surface_get_scale_factor(surface) : 1.0;
    native_sdk_emit(host, (native_sdk_gtk_event_t){
        .kind = NATIVE_SDK_GTK_EVENT_RESIZE,
        .window_id = win->id,
        .width = (double)w, .height = (double)h,
        .scale = scale,
    });
}

static const char *native_sdk_shortcut_key_for_keyval(guint keyval, char *buffer, size_t buffer_len, int *uses_implicit_shift) {
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

static int native_sdk_shortcut_modifiers_match(uint32_t shortcut_modifiers, GdkModifierType event_modifiers, int allow_implicit_shift) {
    int needs_control = (shortcut_modifiers & NATIVE_SDK_SHORTCUT_MODIFIER_CONTROL) != 0 ||
        (shortcut_modifiers & NATIVE_SDK_SHORTCUT_MODIFIER_PRIMARY) != 0;
    int needs_option = (shortcut_modifiers & NATIVE_SDK_SHORTCUT_MODIFIER_OPTION) != 0;
    int needs_shift = (shortcut_modifiers & NATIVE_SDK_SHORTCUT_MODIFIER_SHIFT) != 0;
    int needs_command = (shortcut_modifiers & NATIVE_SDK_SHORTCUT_MODIFIER_COMMAND) != 0;
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
    native_sdk_gtk_window_t *win = data;
    native_sdk_gtk_host_t *host = win ? win->host : NULL;
    if (!host || host->shortcut_count == 0) return FALSE;
    char key_buffer[32];
    int uses_implicit_shift = 0;
    const char *key = native_sdk_shortcut_key_for_keyval(keyval, key_buffer, sizeof(key_buffer), &uses_implicit_shift);
    if (!key || !key[0]) return FALSE;
    int pass_count = uses_implicit_shift ? 2 : 1;
    for (int pass = 0; pass < pass_count; pass++) {
        int allow_implicit_shift = pass == 1;
        for (int i = 0; i < host->shortcut_count; i++) {
            native_sdk_gtk_shortcut_t *shortcut = &host->shortcuts[i];
            if (!shortcut->id || !shortcut->key || strcmp(shortcut->key, key) != 0) continue;
            if (!native_sdk_shortcut_modifiers_match(shortcut->modifiers, state, allow_implicit_shift)) continue;
            native_sdk_emit(host, (native_sdk_gtk_event_t){
                .kind = NATIVE_SDK_GTK_EVENT_SHORTCUT,
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

static gboolean native_sdk_frame_tick(gpointer data) {
    native_sdk_gtk_host_t *host = data;
    /* GTK only reports the window's real allocation after mapping (and never
     * re-fires notify::default-width for it), so poll for allocation/scale
     * changes here and re-emit resize + window frame events; shell layout
     * depends on a non-zero surface size. */
    for (int i = 0; i < host->window_count; i++) {
        native_sdk_gtk_window_t *win = &host->windows[i];
        if (!win->gtk_window) continue;
        const double w = (double)gtk_widget_get_width(GTK_WIDGET(win->gtk_window));
        const double h = (double)gtk_widget_get_height(GTK_WIDGET(win->gtk_window));
        GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(win->gtk_window));
        const double scale = surface ? gdk_surface_get_scale_factor(surface) : 1.0;
        if (w > 0 && h > 0 && (w != win->emitted_width || h != win->emitted_height || scale != win->emitted_scale)) {
            win->emitted_width = w;
            win->emitted_height = h;
            win->emitted_scale = scale;
            native_sdk_emit_resize(host, win);
            native_sdk_emit_window_frame(host, win, 1);
        }
    }
    native_sdk_emit(host, (native_sdk_gtk_event_t){ .kind = NATIVE_SDK_GTK_EVENT_FRAME });
    return G_SOURCE_CONTINUE;
}

static void on_resize(GtkWidget *widget, GParamSpec *pspec, gpointer data) {
    (void)pspec;
    (void)widget;
    native_sdk_gtk_window_t *win = data;
    native_sdk_emit_window_frame(win->host, win, 1);
    native_sdk_emit_resize(win->host, win);
}

static void on_focus(GtkWindow *window, GParamSpec *pspec, gpointer data) {
    (void)pspec;
    (void)window;
    native_sdk_gtk_window_t *win = data;
    native_sdk_emit_window_frame(win->host, win, 1);
    native_sdk_emit_app_active_if_changed(win->host);
}

static gboolean on_close_request(GtkWindow *window, gpointer data) {
    (void)window;
    native_sdk_gtk_window_t *win = data;
    native_sdk_gtk_host_t *host = win->host;
    int closed_index = -1;
    for (int i = 0; i < host->window_count; i++) {
        if (&host->windows[i] == win) {
            closed_index = i;
            break;
        }
    }
    native_sdk_emit_window_frame(host, win, 0);

    if (closed_index >= 0) {
        native_sdk_clear_window(&host->windows[closed_index]);
    }

    int open_count = 0;
    for (int i = 0; i < host->window_count; i++) {
        if (host->windows[i].gtk_window) open_count++;
    }
    if (open_count == 0) {
        if (!host->did_shutdown) {
            host->did_shutdown = 1;
            native_sdk_emit(host, (native_sdk_gtk_event_t){ .kind = NATIVE_SDK_GTK_EVENT_SHUTDOWN });
        }
        if (host->frame_timer) {
            g_source_remove(host->frame_timer);
            host->frame_timer = 0;
        }
        g_application_quit(G_APPLICATION(host->app));
    }
    return FALSE;
}

static const char *native_sdk_decision_uri(WebKitPolicyDecision *decision, WebKitPolicyDecisionType type) {
    if (type != WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) return NULL;
    WebKitNavigationPolicyDecision *navigation = WEBKIT_NAVIGATION_POLICY_DECISION(decision);
    WebKitNavigationAction *action = webkit_navigation_policy_decision_get_navigation_action(navigation);
    WebKitURIRequest *request = action ? webkit_navigation_action_get_request(action) : NULL;
    return request ? webkit_uri_request_get_uri(request) : NULL;
}

#if GTK_CHECK_VERSION(4, 10, 0)
static void native_sdk_uri_launch_done(GObject *source_object, GAsyncResult *result, gpointer data) {
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

static void native_sdk_open_external_uri(GtkWindow *parent, const char *uri) {
#if GTK_CHECK_VERSION(4, 10, 0)
    GtkUriLauncher *launcher = gtk_uri_launcher_new(uri);
    gtk_uri_launcher_launch(launcher, parent, NULL, native_sdk_uri_launch_done, NULL);
#else
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    gtk_show_uri(parent, uri, GDK_CURRENT_TIME);
    G_GNUC_END_IGNORE_DEPRECATIONS
#endif
}

static gboolean on_decide_policy(WebKitWebView *web_view, WebKitPolicyDecision *decision, WebKitPolicyDecisionType type, gpointer data) {
    (void)web_view;
    native_sdk_gtk_window_t *win = data;
    native_sdk_gtk_host_t *host = win->host;
    const char *uri = native_sdk_decision_uri(decision, type);
    if (!uri || !uri[0] || strncmp(uri, "about:", 6) == 0) {
        webkit_policy_decision_use(decision);
        return TRUE;
    }

    char *origin = native_sdk_origin_for_uri(uri);
    int internal_asset = origin && native_sdk_window_allows_asset_origin(win, origin);
    g_free(origin);
    if (internal_asset || native_sdk_policy_list_matches(host->allowed_origins, host->allowed_origins_count, uri)) {
        webkit_policy_decision_use(decision);
        return TRUE;
    }

    if (host->external_link_action == 1 && native_sdk_policy_list_matches(host->allowed_external_urls, host->allowed_external_urls_count, uri)) {
        native_sdk_open_external_uri(win->gtk_window, uri);
        webkit_policy_decision_ignore(decision);
        return TRUE;
    }

    webkit_policy_decision_ignore(decision);
    return TRUE;
}

static gboolean on_webview_decide_policy(WebKitWebView *web_view, WebKitPolicyDecision *decision, WebKitPolicyDecisionType type, gpointer data) {
    (void)web_view;
    native_sdk_gtk_window_t *win = data;
    native_sdk_gtk_host_t *host = win->host;
    const char *uri = native_sdk_decision_uri(decision, type);
    if (!uri || !uri[0] || strncmp(uri, "about:", 6) == 0) {
        webkit_policy_decision_use(decision);
        return TRUE;
    }
    char *origin = native_sdk_origin_for_uri(uri);
    int internal_asset = origin && native_sdk_window_allows_asset_origin(win, origin);
    g_free(origin);
    if (internal_asset || native_sdk_policy_list_matches(host->allowed_origins, host->allowed_origins_count, uri)) {
        webkit_policy_decision_use(decision);
        return TRUE;
    }
    if (host->external_link_action == 1 && native_sdk_policy_list_matches(host->allowed_external_urls, host->allowed_external_urls_count, uri)) {
        native_sdk_open_external_uri(win->gtk_window, uri);
    }
    webkit_policy_decision_ignore(decision);
    return TRUE;
}

static void on_bridge_message(WebKitUserContentManager *manager, JSCValue *js_result, gpointer data) {
    native_sdk_gtk_window_t *win = data;
    native_sdk_gtk_host_t *host = win->host;
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
    char *computed_origin = win->bridge_origin && strcmp(label, "main") == 0 ? g_strdup(win->bridge_origin) : native_sdk_origin_for_uri(uri);
    host->bridge_callback(host->bridge_context, win->id, label, strlen(label), message, strlen(message), computed_origin, strlen(computed_origin));
    g_free(computed_origin);
    g_free(message);
}

static void native_sdk_setup_bridge(native_sdk_gtk_window_t *win) {
    WebKitUserContentManager *manager = win->content_manager;
    g_signal_connect(manager, "script-message-received::nativeSdkBridge", G_CALLBACK(on_bridge_message), win);
    webkit_user_content_manager_register_script_message_handler(manager, "nativeSdkBridge", NULL);

    WebKitUserScript *script = webkit_user_script_new(
        native_sdk_bridge_script(),
        WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
        WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
        NULL, NULL);
    webkit_user_content_manager_add_script(manager, script);
    webkit_user_script_unref(script);
}

static native_sdk_gtk_window_t *native_sdk_create_window_internal(native_sdk_gtk_host_t *host, uint64_t window_id, const char *title, const char *label, double x, double y, double width, double height, int restore_frame, int resizable, int titlebar_style, double min_width, double min_height) {
    if (native_sdk_find_window(host, window_id)) return NULL;

    int slot = -1;
    for (int i = 0; i < host->window_count; i++) {
        if (!host->windows[i].gtk_window) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        if (host->window_count >= NATIVE_SDK_MAX_WINDOWS) return NULL;
        slot = host->window_count++;
    }

    native_sdk_gtk_window_t *win = &host->windows[slot];
    memset(win, 0, sizeof(*win));
    win->id = window_id;
    win->host = host;
    win->x = restore_frame ? x : 0;
    win->y = restore_frame ? y : 0;
    win->label = native_sdk_strndup(label && label[0] ? label : "main", strlen(label && label[0] ? label : "main"));
    win->title = native_sdk_strndup(title && title[0] ? title : host->app_name, strlen(title && title[0] ? title : host->app_name));
    if (!win->label || !win->title) {
        free(win->label);
        free(win->title);
        memset(win, 0, sizeof(*win));
        return NULL;
    }

    win->gtk_window = GTK_WINDOW(gtk_application_window_new(host->app));
    gtk_window_set_title(win->gtk_window, win->title);
    gtk_window_set_default_size(win->gtk_window, (int)width, (int)height);
    gtk_window_set_resizable(win->gtk_window, resizable ? TRUE : FALSE);
    /* The hidden titlebar styles are client-side decorations, never an
     * undecorated window: a real GtkHeaderBar titlebar keeps the
     * desktop-themed close/minimize/maximize buttons, the system drag
     * and double-click conventions, and the compositor's shadows and
     * resize borders all genuine. The app's canvas stays the full
     * client area below the bar; the bar carries only the window
     * controls. */
    if (titlebar_style == 3) {
        /* Chromeless (titlebar_style 3): NO chrome at all — the
         * undecorated window the hidden styles deliberately are not. No
         * header bar, no themed buttons; the explicit opt-in for
         * fully-skinned apps that draw their own working window
         * controls, and the drag channel (gdk_toplevel_begin_move)
         * works without decorations. */
        gtk_window_set_decorated(win->gtk_window, FALSE);
    } else if (titlebar_style >= 1) {
        GtkWidget *bar = gtk_header_bar_new();
        /* Explicit GtkWindowControls at both ends instead of the header
         * bar's built-in title buttons: the same themed clusters GTK
         * itself would compose, but as addressable children the chrome
         * channel can measure. Each cluster renders its half of the
         * user's gtk-decoration-layout setting (the part before the
         * colon fills the start side, the part after fills the end
         * side), so button side and order follow the desktop and update
         * live when the user changes the setting; a side with no
         * entries renders empty. */
        gtk_header_bar_set_show_title_buttons(GTK_HEADER_BAR(bar), FALSE);
        win->window_controls_start = gtk_window_controls_new(GTK_PACK_START);
        win->window_controls_end = gtk_window_controls_new(GTK_PACK_END);
        gtk_header_bar_pack_start(GTK_HEADER_BAR(bar), win->window_controls_start);
        gtk_header_bar_pack_end(GTK_HEADER_BAR(bar), win->window_controls_end);
        /* Hidden styles hide the title text (the AppKit host's
         * NSWindowTitleHidden): the app's own header owns the visible
         * title. An empty title widget keeps the band's center clear. */
        gtk_header_bar_set_title_widget(GTK_HEADER_BAR(bar), gtk_label_new(NULL));
        if (titlebar_style == 2) {
            gtk_widget_set_size_request(bar, -1, NATIVE_SDK_GTK_TALL_TITLEBAR_PX);
        }
        gtk_window_set_titlebar(win->gtk_window, bar);
        win->header_bar = bar;
        /* The canvas's first resize can fire in the same layout pass
         * that allocates the bar, BEFORE the bar has its geometry — the
         * chrome query answered then carries the band height (a measure)
         * but no control clusters yet. Nudge a re-query once the bar is
         * mapped and laid out, the way the AppKit host re-emits resizes
         * off its settled contentLayoutRect. */
        g_signal_connect(bar, "map", G_CALLBACK(native_sdk_on_header_bar_mapped), win->host);
    }

    win->content_manager = webkit_user_content_manager_new();
    WebKitWebView *wv = WEBKIT_WEB_VIEW(
        g_object_new(WEBKIT_TYPE_WEB_VIEW,
            "user-content-manager", win->content_manager,
            NULL));
    win->web_view = wv;
    if (!host->scheme_registered) {
        webkit_web_context_register_uri_scheme(webkit_web_view_get_context(wv), "zero", native_sdk_asset_scheme_request, host, NULL);
        host->scheme_registered = 1;
    }
    native_sdk_setup_bridge(win);

    win->root_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    /* Declared content min-size floor: the size request on the content
     * box floors user resizes without inflating the default size (the
     * AppKit side expresses the same floor as contentMinSize). Axes
     * <= 0 keep the natural minimum. */
    if (min_width > 0 || min_height > 0) {
        gtk_widget_set_size_request(win->root_box,
                                    min_width > 0 ? (int)min_width : -1,
                                    min_height > 0 ? (int)min_height : -1);
    }
    win->menu_bar = gtk_popover_menu_bar_new_from_model(host->menu_model);
    gtk_widget_set_visible(win->menu_bar, host->menu_model != NULL);
    gtk_box_append(GTK_BOX(win->root_box), win->menu_bar);

    win->stack_root = gtk_overlay_new();
    gtk_widget_set_hexpand(win->stack_root, TRUE);
    gtk_widget_set_vexpand(win->stack_root, TRUE);
    gtk_overlay_set_child(GTK_OVERLAY(win->stack_root), GTK_WIDGET(wv));
    gtk_box_append(GTK_BOX(win->root_box), win->stack_root);
    gtk_window_set_child(win->gtk_window, win->root_box);
    native_sdk_install_file_drop_target(win);

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
    native_sdk_gtk_host_t *host = data;

    native_sdk_gtk_window_t *win = native_sdk_create_window_internal(
        host, 1, host->window_title, host->window_label,
        host->init_x, host->init_y,
        host->init_width > 0 ? host->init_width : 720,
        host->init_height > 0 ? host->init_height : 480,
        host->restore_frame, host->init_resizable, host->init_titlebar_style,
        host->init_min_width, host->init_min_height);
    if (!win) return;

    gtk_window_present(win->gtk_window);
    native_sdk_emit_app_active_if_changed(host);

    native_sdk_emit(host, (native_sdk_gtk_event_t){ .kind = NATIVE_SDK_GTK_EVENT_START });
    native_sdk_emit_appearance(host);
    native_sdk_watch_appearance(host);
    native_sdk_emit_resize(host, win);
    native_sdk_emit_window_frame(host, win, 1);

    host->frame_timer = g_timeout_add(16, native_sdk_frame_tick, host);
}

native_sdk_gtk_host_t *native_sdk_gtk_create(
    const char *app_name, size_t app_name_len,
    const char *window_title, size_t window_title_len,
    const char *bundle_id, size_t bundle_id_len,
    const char *icon_path, size_t icon_path_len,
    const char *window_label, size_t window_label_len,
    double x, double y, double width, double height,
    int restore_frame, int resizable, int titlebar_style,
    double min_width, double min_height)
{
    native_sdk_gtk_host_t *host = calloc(1, sizeof(native_sdk_gtk_host_t));
    if (!host) return NULL;

    host->app_name = app_name_len > 0 ? native_sdk_strndup(app_name, app_name_len) : native_sdk_strndup("native-sdk", 11);
    host->window_title = window_title_len > 0 ? native_sdk_strndup(window_title, window_title_len) : native_sdk_strndup(host->app_name, strlen(host->app_name));
    host->bundle_id = bundle_id_len > 0 ? native_sdk_strndup(bundle_id, bundle_id_len) : native_sdk_strndup("dev.native_sdk.app", 19);
    host->icon_path = icon_path_len > 0 ? native_sdk_strndup(icon_path, icon_path_len) : NULL;
    host->window_label = window_label_len > 0 ? native_sdk_strndup(window_label, window_label_len) : native_sdk_strndup("main", 4);
    host->init_x = x;
    host->init_y = y;
    host->init_width = width;
    host->init_height = height;
    host->restore_frame = restore_frame;
    host->init_resizable = resizable;
    host->init_titlebar_style = titlebar_style;
    host->init_min_width = min_width;
    host->init_min_height = min_height;

    host->allowed_origins = NULL;
    host->allowed_origins_count = 0;
    host->allowed_external_urls = NULL;
    host->allowed_external_urls_count = 0;

    host->app = gtk_application_new(host->bundle_id, G_APPLICATION_DEFAULT_FLAGS);

    return host;
}

void native_sdk_gtk_destroy(native_sdk_gtk_host_t *host) {
    if (!host) return;
    /* Retire the audio pipeline (and cancel its cache download) before
     * anything else goes away; everything runs on this thread. */
    native_sdk_audio_release(host, 1);
    if (host->frame_timer) g_source_remove(host->frame_timer);
    for (int i = 0; i < NATIVE_SDK_MAX_TIMERS; i++) {
        if (host->timers[i].in_use && host->timers[i].source) g_source_remove(host->timers[i].source);
        host->timers[i].in_use = 0;
    }
    for (int i = 0; i < host->window_count; i++) {
        native_sdk_clear_window(&host->windows[i]);
    }
    g_object_unref(host->app);
    free(host->app_name);
    free(host->window_title);
    free(host->bundle_id);
    free(host->icon_path);
    free(host->window_label);
    native_sdk_free_string_list(host->allowed_origins, host->allowed_origins_count);
    native_sdk_free_string_list(host->allowed_external_urls, host->allowed_external_urls_count);
    native_sdk_clear_shortcuts(host);
    native_sdk_clear_menu_actions(host);
    if (host->menu_model) g_object_unref(host->menu_model);
    free(host);
}

void native_sdk_gtk_run(native_sdk_gtk_host_t *host, native_sdk_gtk_event_callback_t callback, void *context) {
    host->callback = callback;
    host->callback_context = context;
    g_signal_connect(host->app, "activate", G_CALLBACK(on_activate), host);
    g_application_run(G_APPLICATION(host->app), 0, NULL);
}

void native_sdk_gtk_stop(native_sdk_gtk_host_t *host) {
    if (!host->did_shutdown) {
        host->did_shutdown = 1;
        native_sdk_emit(host, (native_sdk_gtk_event_t){ .kind = NATIVE_SDK_GTK_EVENT_SHUTDOWN });
    }
    if (host->frame_timer) {
        g_source_remove(host->frame_timer);
        host->frame_timer = 0;
    }
    g_application_quit(G_APPLICATION(host->app));
}

/* Runs on the GLib main loop: emit the wake event there, so the runtime
 * drains effect completions on its own thread. */
static gboolean native_sdk_emit_wake_idle(gpointer data) {
    native_sdk_gtk_host_t *host = data;
    if (host && !host->did_shutdown) {
        native_sdk_emit(host, (native_sdk_gtk_event_t){ .kind = NATIVE_SDK_GTK_EVENT_WAKE });
    }
    return G_SOURCE_REMOVE;
}

void native_sdk_gtk_wake(native_sdk_gtk_host_t *host) {
    if (!host) return;
    /* g_idle_add is documented thread-safe: any thread may schedule onto
     * the default main context. */
    g_idle_add(native_sdk_emit_wake_idle, host);
}

/* Runs on the GLib main loop: emit one FRAME event there, so a
 * cross-thread frame request turns into an ordinary frame turn. */
static gboolean native_sdk_emit_frame_idle(gpointer data) {
    native_sdk_gtk_host_t *host = data;
    if (host && !host->did_shutdown) {
        native_sdk_emit(host, (native_sdk_gtk_event_t){ .kind = NATIVE_SDK_GTK_EVENT_FRAME });
    }
    return G_SOURCE_REMOVE;
}

void native_sdk_gtk_request_frame(native_sdk_gtk_host_t *host) {
    if (!host) return;
    /* The automation arrival watcher's wake. Today the GTK host also
     * pumps FRAME continuously from frame_timer, so this only advances a
     * command by up to one tick — but the watcher must not DEPEND on
     * that pump: when frame emission becomes demand-driven this stays
     * the liveness guarantee for commands landing while the app idles. */
    g_idle_add(native_sdk_emit_frame_idle, host);
}

/* Platform image decoder: gdk-pixbuf handles PNG, JPEG, and every other
 * codec its loaders ship — the framework bundles none. Decoded rows are
 * repacked tightly (gdk-pixbuf rowstride may pad) as straight-alpha RGBA8,
 * the layout the canvas image pipeline expects. */
int native_sdk_gtk_decode_image(const uint8_t *bytes, size_t bytes_len, uint8_t *pixels, size_t pixels_len, size_t *out_width, size_t *out_height) {
    if (out_width) *out_width = 0;
    if (out_height) *out_height = 0;
    if (!bytes || bytes_len == 0 || !pixels) return 0;

    GdkPixbufLoader *loader = gdk_pixbuf_loader_new();
    if (!loader) return 0;
    gboolean ok = gdk_pixbuf_loader_write(loader, bytes, bytes_len, NULL);
    ok = gdk_pixbuf_loader_close(loader, NULL) && ok;
    GdkPixbuf *decoded = ok ? gdk_pixbuf_loader_get_pixbuf(loader) : NULL;
    if (!decoded) {
        g_object_unref(loader);
        return 0;
    }

    /* Normalize to 8-bit RGBA (palette/grayscale decode as RGB(A)); the
     * added alpha channel is opaque, gdk-pixbuf alpha is already straight. */
    GdkPixbuf *rgba = gdk_pixbuf_get_has_alpha(decoded)
        ? g_object_ref(decoded)
        : gdk_pixbuf_add_alpha(decoded, FALSE, 0, 0, 0);
    if (!rgba || gdk_pixbuf_get_bits_per_sample(rgba) != 8 || gdk_pixbuf_get_n_channels(rgba) != 4) {
        if (rgba) g_object_unref(rgba);
        g_object_unref(loader);
        return 0;
    }

    int width_px = gdk_pixbuf_get_width(rgba);
    int height_px = gdk_pixbuf_get_height(rgba);
    if (width_px <= 0 || height_px <= 0 || width_px > 8192 || height_px > 8192) {
        g_object_unref(rgba);
        g_object_unref(loader);
        return 0;
    }
    size_t width = (size_t)width_px;
    size_t height = (size_t)height_px;
    if (out_width) *out_width = width;
    if (out_height) *out_height = height;
    size_t byte_len = width * height * 4;
    if (pixels_len < byte_len) {
        g_object_unref(rgba);
        g_object_unref(loader);
        return -1;
    }

    const guchar *source = gdk_pixbuf_read_pixels(rgba);
    size_t rowstride = (size_t)gdk_pixbuf_get_rowstride(rgba);
    for (size_t row = 0; row < height; row += 1) {
        memcpy(pixels + row * width * 4, source + row * rowstride, width * 4);
    }
    g_object_unref(rgba);
    g_object_unref(loader);
    return 1;
}

void native_sdk_gtk_load_webview(native_sdk_gtk_host_t *host, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback) {
    native_sdk_gtk_load_window_webview(host, 1, source, source_len, source_kind, asset_root, asset_root_len, asset_entry, asset_entry_len, asset_origin, asset_origin_len, spa_fallback);
}

void native_sdk_gtk_load_window_webview(native_sdk_gtk_host_t *host, uint64_t window_id, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback) {
    native_sdk_gtk_window_t *win = native_sdk_find_window(host, window_id);
    if (!win || !win->web_view) return;

    char *src = native_sdk_strndup(source, source_len);
    if (!src) return;

    native_sdk_clear_window_source(win);
    if (source_kind == 1) {
        webkit_web_view_load_uri(win->web_view, src);
    } else if (source_kind == 2) {
        char *root = asset_root_len > 0 ? native_sdk_strndup(asset_root, asset_root_len) : native_sdk_strndup(".", 1);
        char *entry = asset_entry_len > 0 ? native_sdk_strndup(asset_entry, asset_entry_len) : native_sdk_strndup("index.html", strlen("index.html"));
        char *public_origin = asset_origin_len > 0 ? native_sdk_strndup(asset_origin, asset_origin_len) : native_sdk_strndup("zero://app", strlen("zero://app"));
        int needs_private_origin = public_origin && !native_sdk_request_web_view_supported() && native_sdk_window_uses_public_asset_origin(host, win, public_origin);
        char *origin = needs_private_origin ? native_sdk_internal_asset_origin(window_id) : (public_origin ? native_sdk_strndup(public_origin, strlen(public_origin)) : NULL);
        if (!root || !entry || !public_origin || !origin) {
            free(root);
            free(entry);
            free(origin);
            free(public_origin);
            free(src);
            return;
        }
        while (entry[0] == '/') memmove(entry, entry + 1, strlen(entry));
        if (!native_sdk_path_is_safe(entry)) {
            free(entry);
            entry = native_sdk_strndup("index.html", strlen("index.html"));
            if (!entry) {
                free(root);
                free(origin);
                free(public_origin);
                free(src);
                return;
            }
        }
        char *canonical_root = g_canonicalize_filename(root, NULL);
        free(root);
        win->asset_root = canonical_root ? native_sdk_strndup(canonical_root, strlen(canonical_root)) : native_sdk_strndup(".", 1);
        g_free(canonical_root);
        win->asset_entry = entry;
        win->asset_origin = origin;
        win->bridge_origin = public_origin;
        win->spa_fallback = spa_fallback != 0;

        char *uri = g_strdup_printf("%s/%s", origin, entry);
        webkit_web_view_load_uri(win->web_view, uri);
        g_free(uri);
    } else {
        win->bridge_origin = native_sdk_strndup("zero://inline", strlen("zero://inline"));
        webkit_web_view_load_html(win->web_view, src, "zero://inline");
    }
    free(src);
}

void native_sdk_gtk_set_bridge_callback(native_sdk_gtk_host_t *host, native_sdk_gtk_bridge_callback_t callback, void *context) {
    host->bridge_callback = callback;
    host->bridge_context = context;
}

void native_sdk_gtk_bridge_respond(native_sdk_gtk_host_t *host, const char *response, size_t response_len) {
    native_sdk_gtk_bridge_respond_window(host, 1, response, response_len);
}

void native_sdk_gtk_bridge_respond_window(native_sdk_gtk_host_t *host, uint64_t window_id, const char *response, size_t response_len) {
    native_sdk_gtk_bridge_respond_webview(host, window_id, "main", 4, response, response_len);
}

void native_sdk_gtk_bridge_respond_webview(native_sdk_gtk_host_t *host, uint64_t window_id, const char *webview_label, size_t webview_label_len, const char *response, size_t response_len) {
    native_sdk_gtk_window_t *win = native_sdk_find_window(host, window_id);
    if (!win || !win->web_view) return;
    char *label = webview_label_len > 0 ? native_sdk_strndup(webview_label, webview_label_len) : native_sdk_strndup("main", 4);
    if (!label) return;
    WebKitWebView *target = NULL;
    if (strcmp(label, "main") == 0) {
        target = win->web_view;
    } else {
        native_sdk_gtk_webview_t *webview = native_sdk_find_webview(win, label);
        if (webview) target = webview->web_view;
    }
    free(label);
    if (!target) return;

    char *resp = native_sdk_strndup(response, response_len);
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

void native_sdk_gtk_emit_window_event(native_sdk_gtk_host_t *host, uint64_t window_id, const char *name, size_t name_len, const char *detail_json, size_t detail_json_len) {
    native_sdk_gtk_window_t *win = native_sdk_find_window(host, window_id);
    if (!win || !win->web_view) return;
    char *event_name = native_sdk_strndup(name, name_len);
    char *detail = native_sdk_strndup(detail_json, detail_json_len);
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

void native_sdk_gtk_set_security_policy(native_sdk_gtk_host_t *host, const char *allowed_origins, size_t allowed_origins_len, const char *external_urls, size_t external_urls_len, int external_action) {
    native_sdk_free_string_list(host->allowed_origins, host->allowed_origins_count);
    native_sdk_free_string_list(host->allowed_external_urls, host->allowed_external_urls_count);
    host->allowed_origins = native_sdk_parse_newline_list(allowed_origins, allowed_origins_len, &host->allowed_origins_count);
    host->allowed_external_urls = native_sdk_parse_newline_list(external_urls, external_urls_len, &host->allowed_external_urls_count);
    host->external_link_action = external_action;
}

void native_sdk_gtk_set_menus(native_sdk_gtk_host_t *host, const char *const *menu_titles, const size_t *menu_title_lens, size_t menu_count, const uint32_t *item_menu_indices, const char *const *item_labels, const size_t *item_label_lens, const char *const *item_commands, const size_t *item_command_lens, const char *const *item_keys, const size_t *item_key_lens, const uint32_t *item_modifiers, const int *item_separators, const int *item_enabled, const int *item_checked, size_t item_count) {
    if (!host) return;
    native_sdk_clear_menu_actions(host);
    if (host->menu_model) {
        g_object_unref(host->menu_model);
        host->menu_model = NULL;
    }

    if (menu_count == 0) {
        for (int i = 0; i < host->window_count; i++) native_sdk_apply_menu_model_to_window(host, &host->windows[i]);
        return;
    }
    if (!menu_titles || !menu_title_lens) return;
    if (item_count > 0 && (!item_menu_indices || !item_labels || !item_label_lens || !item_commands || !item_command_lens || !item_keys || !item_key_lens || !item_modifiers || !item_separators || !item_enabled || !item_checked)) return;

    GMenu *menubar = g_menu_new();
    for (size_t menu_index = 0; menu_index < menu_count; menu_index++) {
        char *title = native_sdk_strndup(menu_titles[menu_index], menu_title_lens[menu_index]);
        if (!title) continue;
        GMenu *menu = g_menu_new();
        GMenu *section = g_menu_new();

        for (size_t item_index = 0; item_index < item_count; item_index++) {
            if (item_menu_indices[item_index] != menu_index) continue;
            if (item_separators[item_index]) {
                native_sdk_append_menu_section(menu, &section);
                continue;
            }
            if (host->menu_action_count >= NATIVE_SDK_MAX_MENU_ITEMS) continue;

            char *label = native_sdk_strndup(item_labels[item_index], item_label_lens[item_index]);
            char *command = native_sdk_strndup(item_commands[item_index], item_command_lens[item_index]);
            char *key = native_sdk_strndup(item_keys[item_index], item_key_lens[item_index]);
            if (!label || !command || !key) {
                free(label);
                free(command);
                free(key);
                continue;
            }

            native_sdk_gtk_menu_action_t *menu_action = &host->menu_actions[host->menu_action_count];
            memset(menu_action, 0, sizeof(*menu_action));
            menu_action->name = g_strdup_printf("zn-menu-%d", host->menu_action_count + 1);
            menu_action->command = command;
            menu_action->host = host;
            if (!menu_action->name || !menu_action->command) {
                g_free(menu_action->name);
                free(menu_action->command);
                memset(menu_action, 0, sizeof(*menu_action));
                free(label);
                free(key);
                continue;
            }

            GSimpleAction *action = item_checked[item_index]
                ? g_simple_action_new_stateful(menu_action->name, NULL, g_variant_new_boolean(TRUE))
                : g_simple_action_new(menu_action->name, NULL);
            g_simple_action_set_enabled(action, item_enabled[item_index] != 0);
            g_signal_connect(action, "activate", G_CALLBACK(native_sdk_menu_action_activate), menu_action);
            g_action_map_add_action(G_ACTION_MAP(host->app), G_ACTION(action));
            g_object_unref(action);

            char *detailed = g_strdup_printf("app.%s", menu_action->name);
            GMenuItem *gitem = g_menu_item_new(label, detailed);
            if (item_checked[item_index]) g_menu_item_set_attribute(gitem, "toggle-type", "s", "check");
            g_menu_append_item(section, gitem);
            g_object_unref(gitem);

            char *accel = native_sdk_menu_accel(key, item_modifiers[item_index]);
            if (accel && accel[0]) {
                const char *accels[] = { accel, NULL };
                gtk_application_set_accels_for_action(host->app, detailed, accels);
            }
            g_free(detailed);
            g_free(accel);
            free(label);
            free(key);
            host->menu_action_count++;
        }

        native_sdk_append_menu_section(menu, &section);
        g_object_unref(section);
        g_menu_append_submenu(menubar, title, G_MENU_MODEL(menu));
        g_object_unref(menu);
        free(title);
    }

    host->menu_model = G_MENU_MODEL(menubar);
    for (int i = 0; i < host->window_count; i++) native_sdk_apply_menu_model_to_window(host, &host->windows[i]);
}

void native_sdk_gtk_set_shortcuts(native_sdk_gtk_host_t *host, const char *const *ids, const size_t *id_lens, const char *const *keys, const size_t *key_lens, const uint32_t *modifiers, size_t count) {
    if (!host) return;
    native_sdk_clear_shortcuts(host);
    if (!ids || !id_lens || !keys || !key_lens || !modifiers) return;
    size_t limit = count < NATIVE_SDK_MAX_SHORTCUTS ? count : NATIVE_SDK_MAX_SHORTCUTS;
    for (size_t i = 0; i < limit; i++) {
        if (!ids[i] || !keys[i] || id_lens[i] == 0 || key_lens[i] == 0) continue;
        native_sdk_gtk_shortcut_t *shortcut = &host->shortcuts[host->shortcut_count];
        shortcut->id = native_sdk_strndup(ids[i], id_lens[i]);
        shortcut->key = native_sdk_strndup(keys[i], key_lens[i]);
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

int native_sdk_gtk_create_window(native_sdk_gtk_host_t *host, uint64_t window_id, const char *window_title, size_t window_title_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame, int resizable, int titlebar_style, double min_width, double min_height) {
    char *title = window_title_len > 0 ? native_sdk_strndup(window_title, window_title_len) : NULL;
    char *label = window_label_len > 0 ? native_sdk_strndup(window_label, window_label_len) : NULL;
    native_sdk_gtk_window_t *win = native_sdk_create_window_internal(host, window_id, title, label, x, y, width, height, restore_frame, resizable, titlebar_style, min_width, min_height);
    free(title);
    free(label);
    if (!win) return 0;

    gtk_window_present(win->gtk_window);
    return 1;
}

static gboolean native_sdk_app_timer_tick(gpointer data) {
    native_sdk_gtk_app_timer_t *slot = data;
    if (!slot || !slot->in_use || !slot->host) return G_SOURCE_REMOVE;
    const uint64_t timer_id = slot->id;
    const int repeats = slot->repeats;
    /* A non-repeating timer frees its slot BEFORE emitting so the
     * handler may re-arm the same id (same contract as the AppKit
     * host's app timers). */
    if (!repeats) {
        slot->in_use = 0;
        slot->source = 0;
    }
    native_sdk_emit(slot->host, (native_sdk_gtk_event_t){
        .kind = NATIVE_SDK_GTK_EVENT_TIMER,
        .timer_id = timer_id,
        .timestamp_ns = native_sdk_gpu_timestamp_ns(),
    });
    return repeats ? G_SOURCE_CONTINUE : G_SOURCE_REMOVE;
}

void native_sdk_gtk_start_timer(native_sdk_gtk_host_t *host, uint64_t timer_id, uint64_t interval_ns, int repeats) {
    if (!host) return;
    native_sdk_gtk_cancel_timer(host, timer_id);
    native_sdk_gtk_app_timer_t *slot = NULL;
    for (int i = 0; i < NATIVE_SDK_MAX_TIMERS; i++) {
        if (!host->timers[i].in_use) {
            slot = &host->timers[i];
            break;
        }
    }
    if (!slot) return;
    guint interval_ms = (guint)(interval_ns / 1000000u);
    if (interval_ms == 0) interval_ms = 1;
    slot->id = timer_id;
    slot->repeats = repeats;
    slot->host = host;
    slot->in_use = 1;
    slot->source = g_timeout_add(interval_ms, native_sdk_app_timer_tick, slot);
}

void native_sdk_gtk_cancel_timer(native_sdk_gtk_host_t *host, uint64_t timer_id) {
    if (!host) return;
    for (int i = 0; i < NATIVE_SDK_MAX_TIMERS; i++) {
        if (host->timers[i].in_use && host->timers[i].id == timer_id) {
            if (host->timers[i].source) g_source_remove(host->timers[i].source);
            host->timers[i].in_use = 0;
            host->timers[i].source = 0;
        }
    }
}

int native_sdk_gtk_start_window_drag(native_sdk_gtk_host_t *host, uint64_t window_id) {
    native_sdk_gtk_window_t *win = native_sdk_find_window(host, window_id);
    if (!win || !win->gtk_window) return 0;
    /* No recorded press (synthetic automation input, or a drag request
     * outside any pointer gesture): succeed as a no-op — only an unknown
     * window is an error, matching the AppKit host. */
    native_sdk_window_begin_interactive_move(win);
    return 1;
}

int native_sdk_gtk_set_window_drag_regions(native_sdk_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, const double *rects, const int *exclusions, size_t count) {
    if (!host || !label || label_len == 0) return 0;
    native_sdk_gtk_window_t *win = native_sdk_find_window(host, window_id);
    if (!win) return 0;
    char *label_copy = native_sdk_strndup(label, label_len);
    if (!label_copy) return 0;
    native_sdk_gtk_native_view_t *view = native_sdk_find_native_view(win, label_copy);
    free(label_copy);
    if (!view || view->kind != NATIVE_SDK_GTK_VIEW_GPU_SURFACE) return 0;
    free(view->drag_regions);
    view->drag_regions = NULL;
    view->drag_region_count = 0;
    if (count == 0) return 1;
    view->drag_regions = malloc(count * sizeof(*view->drag_regions));
    if (!view->drag_regions) return 0;
    for (size_t i = 0; i < count; i++) {
        view->drag_regions[i].x = rects[i * 4 + 0];
        view->drag_regions[i].y = rects[i * 4 + 1];
        view->drag_regions[i].width = rects[i * 4 + 2];
        view->drag_regions[i].height = rects[i * 4 + 3];
        view->drag_regions[i].exclusion = exclusions[i];
    }
    view->drag_region_count = count;
    return 1;
}

/* Chrome geometry for hidden-titlebar (client-side decorated) windows.
 * Everything is live widget geometry, never a hardcoded pixel count:
 * the band height is the header bar's allocation (its natural measure
 * before the first layout pass), and the control insets come from the
 * two GtkWindowControls clusters, so a theme change or a user flipping
 * gtk-decoration-layout is reflected on the next query. Side is decided
 * by MEASURED position, not by pack end — right-to-left locales mirror
 * the packing, and the inset is a visual-edge fact. The inset formula
 * mirrors the AppKit host: the cluster's far edge plus the margin the
 * bar leaves before it, so padded content stays visually symmetric.
 * The buttons frame is reported in the BAND's coordinates (top-left
 * origin at the band's top-left): on this toolkit the band sits above
 * the canvas rather than overlaying it, so the band, not the content,
 * is the frame the cluster lives in. Fullscreen hides the titlebar and
 * honestly reports zero; .standard windows report zero always. */
int native_sdk_gtk_window_chrome(native_sdk_gtk_host_t *host, uint64_t window_id, double *top, double *left, double *bottom, double *right, double *buttons_x, double *buttons_y, double *buttons_width, double *buttons_height) {
    *top = 0;
    *left = 0;
    *bottom = 0;
    *right = 0;
    *buttons_x = 0;
    *buttons_y = 0;
    *buttons_width = 0;
    *buttons_height = 0;
    native_sdk_gtk_window_t *win = native_sdk_find_window(host, window_id);
    if (!win || !win->gtk_window) return 0;
    if (!win->header_bar) return 1;
    if (gtk_window_is_fullscreen(win->gtk_window)) return 1;
    int bar_height = gtk_widget_get_height(win->header_bar);
    const int bar_width = gtk_widget_get_width(win->header_bar);
    if (bar_height <= 0) {
        int minimum = 0;
        int natural = 0;
        gtk_widget_measure(win->header_bar, GTK_ORIENTATION_VERTICAL, -1, &minimum, &natural, NULL, NULL);
        bar_height = natural > minimum ? natural : minimum;
    }
    if (bar_height <= 0) return 1;
    *top = (double)bar_height;
    /* Pre-first-allocation there is no measured control geometry yet;
     * the runtime re-queries chrome on every canvas resize, and the
     * first real layout pass delivers the clusters. */
    if (bar_width <= 0) return 1;
    GtkWidget *clusters[2] = { win->window_controls_start, win->window_controls_end };
    graphene_rect_t united;
    int have_cluster = 0;
    for (int i = 0; i < 2; i++) {
        GtkWidget *controls = clusters[i];
        if (!controls || gtk_window_controls_get_empty(GTK_WINDOW_CONTROLS(controls))) continue;
        graphene_rect_t bounds;
        if (!gtk_widget_compute_bounds(controls, win->header_bar, &bounds)) continue;
        if (bounds.size.width <= 0 || bounds.size.height <= 0) continue;
        const double min_x = bounds.origin.x;
        const double max_x = bounds.origin.x + bounds.size.width;
        if ((min_x + max_x) / 2 < (double)bar_width / 2) {
            const double inset = max_x + min_x;
            if (inset > *left) *left = inset;
        } else {
            const double inset = ((double)bar_width - min_x) + ((double)bar_width - max_x);
            if (inset > *right) *right = inset;
        }
        if (have_cluster) {
            graphene_rect_union(&united, &bounds, &united);
        } else {
            united = bounds;
            have_cluster = 1;
        }
    }
    if (have_cluster) {
        *buttons_x = united.origin.x;
        *buttons_y = united.origin.y;
        *buttons_width = united.size.width;
        *buttons_height = united.size.height;
    }
    return 1;
}

int native_sdk_gtk_focus_window(native_sdk_gtk_host_t *host, uint64_t window_id) {
    native_sdk_gtk_window_t *win = native_sdk_find_window(host, window_id);
    if (!win || !win->gtk_window) return 0;
    gtk_window_present(win->gtk_window);
    native_sdk_emit_window_frame(host, win, 1);
    return 1;
}

int native_sdk_gtk_close_window(native_sdk_gtk_host_t *host, uint64_t window_id) {
    native_sdk_gtk_window_t *win = native_sdk_find_window(host, window_id);
    if (!win || !win->gtk_window) return 0;
    gtk_window_close(win->gtk_window);
    return 1;
}

/* The real OS minimize verb, for app-drawn window controls (a chromeless
 * window has no themed button cluster): the same call the drag channel's
 * double-click convention already uses. */
int native_sdk_gtk_minimize_window(native_sdk_gtk_host_t *host, uint64_t window_id) {
    native_sdk_gtk_window_t *win = native_sdk_find_window(host, window_id);
    if (!win || !win->gtk_window) return 0;
    gtk_window_minimize(win->gtk_window);
    return 1;
}

int native_sdk_gtk_create_view(native_sdk_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, int kind, const char *parent, size_t parent_len, double x, double y, double width, double height, int layer, int visible, int enabled, const char *role, size_t role_len, const char *accessibility_label, size_t accessibility_label_len, const char *text, size_t text_len, const char *command, size_t command_len) {
    native_sdk_gtk_window_t *win = native_sdk_find_window(host, window_id);
    if (!win || !win->stack_root || label_len == 0 || !native_sdk_valid_native_view_frame(x, y, width, height)) return 0;
    if (!native_sdk_is_supported_native_view_kind(kind)) return 0;
    if (win->native_view_count >= NATIVE_SDK_MAX_NATIVE_VIEWS) return 0;

    char *label_copy = native_sdk_strndup(label, label_len);
    char *parent_copy = parent_len > 0 ? native_sdk_strndup(parent, parent_len) : NULL;
    char *role_copy = role_len > 0 ? native_sdk_strndup(role, role_len) : NULL;
    char *accessibility_label_copy = accessibility_label_len > 0 ? native_sdk_strndup(accessibility_label, accessibility_label_len) : NULL;
    char *text_copy = text_len > 0 ? native_sdk_strndup(text, text_len) : NULL;
    char *command_copy = command_len > 0 ? native_sdk_strndup(command, command_len) : NULL;
    if (!label_copy || (parent_len > 0 && !parent_copy) || (role_len > 0 && !role_copy) || (accessibility_label_len > 0 && !accessibility_label_copy) || (text_len > 0 && !text_copy) || (command_len > 0 && !command_copy)) {
        free(label_copy);
        free(parent_copy);
        free(role_copy);
        free(accessibility_label_copy);
        free(text_copy);
        free(command_copy);
        return 0;
    }
    if (native_sdk_find_native_view(win, label_copy)) {
        free(label_copy);
        free(parent_copy);
        free(role_copy);
        free(accessibility_label_copy);
        free(text_copy);
        free(command_copy);
        return 0;
    }

    GtkWidget *parent_widget = win->stack_root;
    if (parent_copy && parent_copy[0]) {
        native_sdk_gtk_native_view_t *parent_view = native_sdk_find_native_view(win, parent_copy);
        if (!parent_view || !parent_view->widget || !GTK_IS_FIXED(parent_view->widget)) {
            free(label_copy);
            free(parent_copy);
            free(role_copy);
            free(accessibility_label_copy);
            free(text_copy);
            free(command_copy);
            return 0;
        }
        parent_widget = parent_view->widget;
    }

    const char *display_text = text_copy && text_copy[0] ? text_copy : (role_copy && role_copy[0] ? role_copy : label_copy);
    GtkWidget *widget = native_sdk_make_native_widget(kind, label_copy, display_text);
    if (!widget) {
        free(label_copy);
        free(parent_copy);
        free(role_copy);
        free(accessibility_label_copy);
        free(text_copy);
        free(command_copy);
        return 0;
    }

    int slot = -1;
    for (int i = 0; i < NATIVE_SDK_MAX_NATIVE_VIEWS; i++) {
        if (!win->native_views[i].label) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        g_object_ref_sink(widget);
        g_object_unref(widget);
        free(label_copy);
        free(parent_copy);
        free(role_copy);
        free(accessibility_label_copy);
        free(text_copy);
        free(command_copy);
        return 0;
    }

    native_sdk_gtk_native_view_t *view = &win->native_views[slot];
    memset(view, 0, sizeof(*view));
    view->label = label_copy;
    view->parent = parent_copy;
    view->role = role_copy;
    view->accessibility_label = accessibility_label_copy;
    view->text = text_copy;
    view->command = command_copy;
    view->widget = widget;
    view->window = win;
    view->x = x;
    view->y = y;
    view->width = width;
    view->height = height;
    view->kind = kind;
    view->layer = layer;
    view->visible = visible != 0;
    view->enabled = enabled != 0;
    view->explicit_text = text_len > 0;

    if (view->parent && view->parent[0]) {
        gtk_fixed_put(GTK_FIXED(parent_widget), widget, x, y);
    } else {
        gtk_overlay_add_overlay(GTK_OVERLAY(parent_widget), widget);
    }
    native_sdk_apply_native_view_frame(view);
    native_sdk_apply_native_view_state(view, 1, display_text);
    native_sdk_configure_native_view_action(view);
    if (kind == NATIVE_SDK_GTK_VIEW_GPU_SURFACE) native_sdk_setup_gpu_surface_view(view);
    win->native_view_count++;
    native_sdk_reorder_overlays(win);
    return 1;
}

int native_sdk_gtk_request_gpu_surface_frame(native_sdk_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    native_sdk_gtk_window_t *win = native_sdk_find_window(host, window_id);
    char *label_copy = label_len > 0 ? native_sdk_strndup(label, label_len) : NULL;
    native_sdk_gtk_native_view_t *view = native_sdk_find_native_view(win, label_copy);
    free(label_copy);
    if (!view || view->kind != NATIVE_SDK_GTK_VIEW_GPU_SURFACE || !view->widget) return 0;
    /* A runtime frame request is a producer on the surface's single
     * frame-event scheduler: redraw retained content and arm the next
     * grid-paced emission (folding into one already in flight). */
    gtk_widget_queue_draw(view->widget);
    native_sdk_gpu_surface_schedule_frame_emission(view);
    return 1;
}

int native_sdk_gtk_present_gpu_surface_pixels(native_sdk_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, size_t width, size_t height, double scale, int has_dirty_rect, double dirty_x, double dirty_y, double dirty_width, double dirty_height, const uint8_t *rgba8, size_t rgba8_len) {
    (void)scale;
    (void)has_dirty_rect;
    (void)dirty_x;
    (void)dirty_y;
    (void)dirty_width;
    (void)dirty_height;
    native_sdk_gtk_window_t *win = native_sdk_find_window(host, window_id);
    char *label_copy = label_len > 0 ? native_sdk_strndup(label, label_len) : NULL;
    native_sdk_gtk_native_view_t *view = native_sdk_find_native_view(win, label_copy);
    free(label_copy);
    if (!view || view->kind != NATIVE_SDK_GTK_VIEW_GPU_SURFACE || !view->widget) return 0;
    if (!rgba8 || width == 0 || height == 0) return 0;
    if (width > INT_MAX || height > INT_MAX) return 0;
    if (rgba8_len != width * height * 4) return 0;

    const int stride = cairo_format_stride_for_width(CAIRO_FORMAT_ARGB32, (int)width);
    if (stride <= 0) return 0;
    if (view->gpu_buf_width != (int)width || view->gpu_buf_height != (int)height || view->gpu_buf_stride != stride || !view->gpu_argb) {
        unsigned char *buffer = malloc((size_t)stride * height);
        if (!buffer) return 0;
        free(view->gpu_argb);
        view->gpu_argb = buffer;
        view->gpu_buf_width = (int)width;
        view->gpu_buf_height = (int)height;
        view->gpu_buf_stride = stride;
    }

    /* Straight RGBA8 -> premultiplied native-endian ARGB32 for cairo. */
    for (size_t row = 0; row < height; row++) {
        const uint8_t *src = rgba8 + row * width * 4;
        uint32_t *dst = (uint32_t *)(view->gpu_argb + (size_t)row * (size_t)stride);
        for (size_t col = 0; col < width; col++) {
            const uint32_t r = src[col * 4 + 0];
            const uint32_t g = src[col * 4 + 1];
            const uint32_t b = src[col * 4 + 2];
            const uint32_t a = src[col * 4 + 3];
            const uint32_t pr = (r * a + 127) / 255;
            const uint32_t pg = (g * a + 127) / 255;
            const uint32_t pb = (b * a + 127) / 255;
            dst[col] = (a << 24) | (pr << 16) | (pg << 8) | pb;
        }
    }

    const size_t sample_index = ((height / 2) * width + width / 2) * 4;
    const uint8_t sr = rgba8[sample_index + 0];
    const uint8_t sg = rgba8[sample_index + 1];
    const uint8_t sb = rgba8[sample_index + 2];
    const uint8_t sa = rgba8[sample_index + 3];
    if (sr != 0 || sg != 0 || sb != 0) {
        view->gpu_nonblank = 1;
        view->gpu_sample_color = ((uint32_t)sa << 24) | ((uint32_t)sr << 16) | ((uint32_t)sg << 8) | (uint32_t)sb;
    }

    gtk_widget_queue_draw(view->widget);
    /* A present is the completion producer on the surface's single
     * frame-event scheduler: the completion event it arms is what
     * drives the runtime's frame loop (an armed animation presents,
     * this echo steps it again). The first present also retires the
     * placeholder pump — from here on frames exist only on demand. */
    view->gpu_presented = 1;
    native_sdk_gpu_surface_schedule_frame_emission(view);
    return 1;
}

int native_sdk_gtk_update_view(native_sdk_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, int has_frame, double x, double y, double width, double height, int has_layer, int layer, int has_visible, int visible, int has_enabled, int enabled, int has_role, const char *role, size_t role_len, int has_accessibility_label, const char *accessibility_label, size_t accessibility_label_len, int has_text, const char *text, size_t text_len, int has_command, const char *command, size_t command_len) {
    native_sdk_gtk_window_t *win = native_sdk_find_window(host, window_id);
    char *label_copy = label_len > 0 ? native_sdk_strndup(label, label_len) : NULL;
    native_sdk_gtk_native_view_t *view = native_sdk_find_native_view(win, label_copy);
    free(label_copy);
    if (!view || !view->widget) return 0;

    if (has_frame) {
        if (!native_sdk_valid_native_view_frame(x, y, width, height)) return 0;
        view->x = x;
        view->y = y;
        view->width = width;
        view->height = height;
        native_sdk_apply_native_view_frame(view);
    }
    if (has_layer) view->layer = layer;
    if (has_visible) view->visible = visible != 0;
    if (has_enabled) view->enabled = enabled != 0;
    if (has_role) native_sdk_replace_string(&view->role, role, role_len);
    if (has_accessibility_label) native_sdk_replace_string(&view->accessibility_label, accessibility_label, accessibility_label_len);
    if (has_text) {
        native_sdk_replace_string(&view->text, text, text_len);
        view->explicit_text = text_len > 0;
    }
    if (has_command) {
        native_sdk_replace_string(&view->command, command, command_len);
        native_sdk_configure_native_view_action(view);
    }

    int update_text = has_text || (has_role && !view->explicit_text);
    const char *display_text = has_text ? (view->text ? view->text : "") : native_sdk_native_display_text(view);
    if (has_visible || has_enabled || has_role || has_accessibility_label || update_text) native_sdk_apply_native_view_state(view, update_text, display_text);
    if (update_text && view->kind == NATIVE_SDK_GTK_VIEW_SEGMENTED_CONTROL) native_sdk_configure_native_view_action(view);
    if (has_layer) native_sdk_reorder_overlays(win);
    return 1;
}

int native_sdk_gtk_set_view_frame(native_sdk_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height) {
    return native_sdk_gtk_update_view(host, window_id, label, label_len, 1, x, y, width, height, 0, 0, 0, 1, 0, 1, 0, "", 0, 0, "", 0, 0, "", 0, 0, "", 0);
}

int native_sdk_gtk_set_view_visible(native_sdk_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, int visible) {
    return native_sdk_gtk_update_view(host, window_id, label, label_len, 0, 0, 0, 0, 0, 0, 0, 1, visible, 0, 1, 0, "", 0, 0, "", 0, 0, "", 0, 0, "", 0);
}

int native_sdk_gtk_focus_view(native_sdk_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    native_sdk_gtk_window_t *win = native_sdk_find_window(host, window_id);
    char *label_copy = label_len > 0 ? native_sdk_strndup(label, label_len) : NULL;
    if (!win) {
        free(label_copy);
        return 0;
    }
    if (label_copy && strcmp(label_copy, "main") == 0) {
        GtkWidget *widget = win->web_view ? GTK_WIDGET(win->web_view) : NULL;
        free(label_copy);
        if (!widget || !gtk_widget_get_visible(widget) || !gtk_widget_get_sensitive(widget)) return 0;
        return gtk_widget_grab_focus(widget) ? 1 : 0;
    }
    native_sdk_gtk_webview_t *webview = native_sdk_find_webview(win, label_copy);
    if (webview && webview->web_view) {
        GtkWidget *widget = GTK_WIDGET(webview->web_view);
        free(label_copy);
        if (!gtk_widget_get_visible(widget) || !gtk_widget_get_sensitive(widget)) return 0;
        return gtk_widget_grab_focus(widget) ? 1 : 0;
    }
    native_sdk_gtk_native_view_t *view = native_sdk_find_native_view(win, label_copy);
    free(label_copy);
    if (!view || !view->widget || !gtk_widget_get_visible(view->widget) || !gtk_widget_get_sensitive(view->widget)) return 0;
    return gtk_widget_grab_focus(view->widget) ? 1 : 0;
}

int native_sdk_gtk_close_view(native_sdk_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    native_sdk_gtk_window_t *win = native_sdk_find_window(host, window_id);
    char *label_copy = label_len > 0 ? native_sdk_strndup(label, label_len) : NULL;
    native_sdk_gtk_native_view_t *view = native_sdk_find_native_view(win, label_copy);
    free(label_copy);
    if (!view || !view->widget) return 0;
    native_sdk_clear_native_view(win, view);
    native_sdk_reorder_overlays(win);
    return 1;
}

int native_sdk_gtk_create_webview(native_sdk_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len, double x, double y, double width, double height, int layer, int transparent, int bridge_enabled) {
    native_sdk_gtk_window_t *win = native_sdk_find_window(host, window_id);
    if (!win || !win->stack_root || label_len == 0 || url_len == 0 || !native_sdk_valid_webview_frame(x, y, width, height)) return 0;
    if (win->webview_count >= NATIVE_SDK_MAX_WEBVIEWS) return 0;

    char *label_copy = native_sdk_strndup(label, label_len);
    char *url_copy = native_sdk_strndup(url, url_len);
    if (!label_copy || !url_copy) {
        free(label_copy);
        free(url_copy);
        return 0;
    }
    if (native_sdk_find_webview(win, label_copy) || !native_sdk_policy_list_matches(host->allowed_origins, host->allowed_origins_count, url_copy)) {
        free(label_copy);
        free(url_copy);
        return 0;
    }

    WebKitUserContentManager *manager = webkit_user_content_manager_new();
    if (bridge_enabled) {
        g_signal_connect(manager, "script-message-received::nativeSdkBridge", G_CALLBACK(on_bridge_message), win);
        webkit_user_content_manager_register_script_message_handler(manager, "nativeSdkBridge", NULL);
        WebKitUserScript *script = webkit_user_script_new(
            native_sdk_bridge_script(),
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

    native_sdk_gtk_webview_t *webview = &win->webviews[win->webview_count++];
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
    native_sdk_apply_webview_frame(webview);
    gtk_overlay_add_overlay(GTK_OVERLAY(win->stack_root), GTK_WIDGET(web_view));
    if (transparent) {
        GdkRGBA transparent_color = {0, 0, 0, 0};
        webkit_web_view_set_background_color(web_view, &transparent_color);
    }
    native_sdk_reorder_overlays(win);
    g_signal_connect(web_view, "decide-policy", G_CALLBACK(on_webview_decide_policy), win);
    webkit_web_view_load_uri(web_view, url_copy);
    free(url_copy);
    return 1;
}

int native_sdk_gtk_set_webview_frame(native_sdk_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height) {
    native_sdk_gtk_window_t *win = native_sdk_find_window(host, window_id);
    char *label_copy = label_len > 0 ? native_sdk_strndup(label, label_len) : NULL;
    if (label_copy && strcmp(label_copy, "main") == 0 && win && win->web_view && native_sdk_valid_webview_frame(x, y, width, height)) {
        GtkWidget *widget = GTK_WIDGET(win->web_view);
        gtk_widget_set_halign(widget, GTK_ALIGN_START);
        gtk_widget_set_valign(widget, GTK_ALIGN_START);
        gtk_widget_set_margin_start(widget, native_sdk_webview_coord(x));
        gtk_widget_set_margin_top(widget, native_sdk_webview_coord(y));
        gtk_widget_set_size_request(widget, native_sdk_webview_extent(width), native_sdk_webview_extent(height));
        free(label_copy);
        return 1;
    }
    native_sdk_gtk_webview_t *webview = native_sdk_find_webview(win, label_copy);
    free(label_copy);
    if (!webview || !native_sdk_valid_webview_frame(x, y, width, height)) return 0;
    webview->x = x;
    webview->y = y;
    webview->width = width;
    webview->height = height;
    native_sdk_apply_webview_frame(webview);
    return 1;
}

int native_sdk_gtk_navigate_webview(native_sdk_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len) {
    native_sdk_gtk_window_t *win = native_sdk_find_window(host, window_id);
    char *label_copy = label_len > 0 ? native_sdk_strndup(label, label_len) : NULL;
    char *url_copy = url_len > 0 ? native_sdk_strndup(url, url_len) : NULL;
    native_sdk_gtk_webview_t *webview = native_sdk_find_webview(win, label_copy);
    if (!webview || !url_copy || !native_sdk_policy_list_matches(host->allowed_origins, host->allowed_origins_count, url_copy)) {
        free(label_copy);
        free(url_copy);
        return 0;
    }
    webkit_web_view_load_uri(webview->web_view, url_copy);
    free(label_copy);
    free(url_copy);
    return 1;
}

int native_sdk_gtk_set_webview_zoom(native_sdk_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, double zoom) {
    native_sdk_gtk_window_t *win = native_sdk_find_window(host, window_id);
    char *label_copy = label_len > 0 ? native_sdk_strndup(label, label_len) : NULL;
    if (label_copy && strcmp(label_copy, "main") == 0 && win && win->web_view && zoom >= 0.25 && zoom <= 5.0) {
        webkit_web_view_set_zoom_level(win->web_view, zoom);
        free(label_copy);
        return 1;
    }
    native_sdk_gtk_webview_t *webview = native_sdk_find_webview(win, label_copy);
    free(label_copy);
    if (!webview || !webview->web_view || zoom < 0.25 || zoom > 5.0) return 0;
    webkit_web_view_set_zoom_level(webview->web_view, zoom);
    return 1;
}

int native_sdk_gtk_set_webview_layer(native_sdk_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, int layer) {
    native_sdk_gtk_window_t *win = native_sdk_find_window(host, window_id);
    char *label_copy = label_len > 0 ? native_sdk_strndup(label, label_len) : NULL;
    if (label_copy && strcmp(label_copy, "main") == 0 && win && win->web_view) {
        free(label_copy);
        win->main_webview_layer = layer;
        native_sdk_reorder_overlays(win);
        return 1;
    }
    native_sdk_gtk_webview_t *webview = native_sdk_find_webview(win, label_copy);
    free(label_copy);
    if (!webview || !webview->web_view) return 0;
    webview->layer = layer;
    native_sdk_reorder_overlays(win);
    return 1;
}

int native_sdk_gtk_close_webview(native_sdk_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    native_sdk_gtk_window_t *win = native_sdk_find_window(host, window_id);
    char *label_copy = label_len > 0 ? native_sdk_strndup(label, label_len) : NULL;
    if (!win || !label_copy) {
        free(label_copy);
        return 0;
    }
    for (int i = 0; i < win->webview_count; i++) {
        if (win->webviews[i].label && strcmp(win->webviews[i].label, label_copy) == 0) {
            free(label_copy);
            native_sdk_remove_webview_at(win, i);
            return 1;
        }
    }
    free(label_copy);
    return 0;
}

int native_sdk_gtk_open_external_url(native_sdk_gtk_host_t *host, const char *url, size_t url_len) {
    if (!host || !url || url_len == 0) return 0;
    char *url_copy = native_sdk_strndup(url, url_len);
    if (!url_copy) return 0;
    native_sdk_open_external_uri(native_sdk_parent_window(host), url_copy);
    free(url_copy);
    return 1;
}

int native_sdk_gtk_reveal_path(native_sdk_gtk_host_t *host, const char *path, size_t path_len) {
    if (!host || !path || path_len == 0) return 0;
    char *path_copy = native_sdk_strndup(path, path_len);
    if (!path_copy) return 0;
    char *target = NULL;
    if (g_file_test(path_copy, G_FILE_TEST_IS_DIR)) {
        target = g_strdup(path_copy);
    } else {
        target = g_path_get_dirname(path_copy);
    }
    free(path_copy);
    if (!target) return 0;
    char *uri = g_filename_to_uri(target, NULL, NULL);
    g_free(target);
    if (!uri) return 0;
    native_sdk_open_external_uri(native_sdk_parent_window(host), uri);
    g_free(uri);
    return 1;
}

int native_sdk_gtk_show_notification(native_sdk_gtk_host_t *host, const char *title, size_t title_len, const char *subtitle, size_t subtitle_len, const char *body, size_t body_len) {
    if (!host || !host->app || !title || title_len == 0) return 0;
    if ((subtitle_len > 0 && !subtitle) || (body_len > 0 && !body)) return 0;
    char *title_copy = native_sdk_strndup(title, title_len);
    if (!title_copy) return 0;

    GNotification *notification = g_notification_new(title_copy);
    free(title_copy);
    if (!notification) return 0;

    size_t message_len = subtitle_len + body_len + ((subtitle_len > 0 && body_len > 0) ? 1 : 0);
    if (message_len > 0) {
        char *message = malloc(message_len + 1);
        if (!message) {
            g_object_unref(notification);
            return 0;
        }
        size_t offset = 0;
        if (subtitle && subtitle_len > 0) {
            memcpy(message + offset, subtitle, subtitle_len);
            offset += subtitle_len;
        }
        if (subtitle_len > 0 && body_len > 0) message[offset++] = '\n';
        if (body && body_len > 0) {
            memcpy(message + offset, body, body_len);
            offset += body_len;
        }
        message[offset] = '\0';
        g_notification_set_body(notification, message);
        free(message);
    }

    g_application_send_notification(G_APPLICATION(host->app), NULL, notification);
    g_object_unref(notification);
    return 1;
}

static char *native_sdk_recent_bookmarks_path(void) {
    const char *data_dir = g_get_user_data_dir();
    if (!data_dir || data_dir[0] == '\0') return NULL;
    if (g_mkdir_with_parents(data_dir, 0700) != 0) return NULL;
    return g_build_filename(data_dir, "recently-used.xbel", NULL);
}

static const char *native_sdk_recent_app_name(native_sdk_gtk_host_t *host) {
    if (host && host->app_name && host->app_name[0] != '\0') return host->app_name;
    const char *application_name = g_get_application_name();
    if (application_name && application_name[0] != '\0') return application_name;
    return "native-sdk";
}

static GBookmarkFile *native_sdk_load_recent_bookmarks(char **out_path) {
    *out_path = native_sdk_recent_bookmarks_path();
    if (!*out_path) return NULL;

    GBookmarkFile *bookmarks = g_bookmark_file_new();
    if (!bookmarks) {
        g_free(*out_path);
        *out_path = NULL;
        return NULL;
    }

    GError *error = NULL;
    if (!g_bookmark_file_load_from_file(bookmarks, *out_path, &error)) {
        gboolean missing = error && g_error_matches(error, G_FILE_ERROR, G_FILE_ERROR_NOENT);
        if (error) g_error_free(error);
        if (!missing) {
            g_bookmark_file_free(bookmarks);
            g_free(*out_path);
            *out_path = NULL;
            return NULL;
        }
    }

    return bookmarks;
}

static int native_sdk_write_recent_bookmarks(GBookmarkFile *bookmarks, const char *path) {
    GError *error = NULL;
    gboolean ok = g_bookmark_file_to_file(bookmarks, path, &error);
    if (error) g_error_free(error);
    return ok ? 1 : 0;
}

int native_sdk_gtk_add_recent_document(native_sdk_gtk_host_t *host, const char *path, size_t path_len) {
    if (!host || !path || path_len == 0) return 0;
    char *path_copy = native_sdk_strndup(path, path_len);
    if (!path_copy) return 0;

    char *uri = g_filename_to_uri(path_copy, NULL, NULL);
    if (!uri) {
        free(path_copy);
        return 0;
    }

    char *bookmarks_path = NULL;
    GBookmarkFile *bookmarks = native_sdk_load_recent_bookmarks(&bookmarks_path);
    if (!bookmarks) {
        g_free(uri);
        free(path_copy);
        return 0;
    }

    char *title = g_path_get_basename(path_copy);
    if (title && g_utf8_validate(title, -1, NULL)) {
        g_bookmark_file_set_title(bookmarks, uri, title);
    }
    g_free(title);

    gboolean uncertain = FALSE;
    char *content_type = g_content_type_guess(path_copy, NULL, 0, &uncertain);
    (void)uncertain;
    char *mime_type = content_type ? g_content_type_get_mime_type(content_type) : NULL;
    g_bookmark_file_set_mime_type(bookmarks, uri, mime_type ? mime_type : "application/octet-stream");
    g_free(mime_type);
    g_free(content_type);

    g_bookmark_file_add_application(bookmarks, uri, native_sdk_recent_app_name(host), NULL);
    int ok = native_sdk_write_recent_bookmarks(bookmarks, bookmarks_path);

    g_bookmark_file_free(bookmarks);
    g_free(bookmarks_path);
    g_free(uri);
    free(path_copy);
    return ok;
}

int native_sdk_gtk_clear_recent_documents(native_sdk_gtk_host_t *host) {
    if (!host) return 0;
    char *bookmarks_path = NULL;
    GBookmarkFile *bookmarks = native_sdk_load_recent_bookmarks(&bookmarks_path);
    if (!bookmarks) return 0;

    const char *app_name = native_sdk_recent_app_name(host);
    gsize uri_count = 0;
    char **uris = g_bookmark_file_get_uris(bookmarks, &uri_count);
    int changed = 0;

    for (gsize i = 0; uris && i < uri_count; i++) {
        GError *remove_error = NULL;
        if (g_bookmark_file_remove_application(bookmarks, uris[i], app_name, &remove_error)) {
            changed = 1;

            GError *apps_error = NULL;
            gsize app_count = 0;
            char **apps = g_bookmark_file_get_applications(bookmarks, uris[i], &app_count, &apps_error);
            if (!apps_error && app_count == 0) {
                GError *item_error = NULL;
                (void)g_bookmark_file_remove_item(bookmarks, uris[i], &item_error);
                if (item_error) g_error_free(item_error);
            }
            if (apps_error) g_error_free(apps_error);
            g_strfreev(apps);
        }
        if (remove_error) g_error_free(remove_error);
    }

    g_strfreev(uris);
    int ok = changed ? native_sdk_write_recent_bookmarks(bookmarks, bookmarks_path) : 1;
    g_bookmark_file_free(bookmarks);
    g_free(bookmarks_path);
    return ok;
}

typedef struct native_sdk_secret_schema_attribute {
    const char *name;
    int type;
} native_sdk_secret_schema_attribute_t;

typedef struct native_sdk_secret_schema {
    const char *name;
    int flags;
    native_sdk_secret_schema_attribute_t attributes[32];
} native_sdk_secret_schema_t;

typedef gboolean (*native_sdk_secret_password_store_sync_fn)(const native_sdk_secret_schema_t *schema, const char *collection, const char *label, const char *password, GCancellable *cancellable, GError **error, ...);
typedef char *(*native_sdk_secret_password_lookup_sync_fn)(const native_sdk_secret_schema_t *schema, GCancellable *cancellable, GError **error, ...);
typedef gboolean (*native_sdk_secret_password_clear_sync_fn)(const native_sdk_secret_schema_t *schema, GCancellable *cancellable, GError **error, ...);

typedef struct native_sdk_secret_api {
    int attempted;
    void *handle;
    native_sdk_secret_password_store_sync_fn store_sync;
    native_sdk_secret_password_lookup_sync_fn lookup_sync;
    native_sdk_secret_password_clear_sync_fn clear_sync;
} native_sdk_secret_api_t;

static native_sdk_secret_api_t native_sdk_secret_api = {0};

static const native_sdk_secret_schema_t native_sdk_credential_schema = {
    "dev.native_sdk.Credential",
    0,
    {
        { "service", 0 },
        { "account", 0 },
        { NULL, 0 },
    },
};

static void *native_sdk_dlsym(void *handle, const char *name) {
    dlerror();
    void *symbol = dlsym(handle, name);
    return dlerror() ? NULL : symbol;
}

static native_sdk_secret_api_t *native_sdk_load_secret_api(void) {
    if (native_sdk_secret_api.attempted) return native_sdk_secret_api.handle ? &native_sdk_secret_api : NULL;
    native_sdk_secret_api.attempted = 1;

    void *handle = dlopen("libsecret-1.so.0", RTLD_NOW | RTLD_LOCAL);
    if (!handle) handle = dlopen("libsecret-1.so", RTLD_NOW | RTLD_LOCAL);
    if (!handle) return NULL;

    native_sdk_secret_api.store_sync = (native_sdk_secret_password_store_sync_fn)native_sdk_dlsym(handle, "secret_password_store_sync");
    native_sdk_secret_api.lookup_sync = (native_sdk_secret_password_lookup_sync_fn)native_sdk_dlsym(handle, "secret_password_lookup_sync");
    native_sdk_secret_api.clear_sync = (native_sdk_secret_password_clear_sync_fn)native_sdk_dlsym(handle, "secret_password_clear_sync");
    if (!native_sdk_secret_api.store_sync || !native_sdk_secret_api.lookup_sync || !native_sdk_secret_api.clear_sync) {
        dlclose(handle);
        memset(&native_sdk_secret_api, 0, sizeof(native_sdk_secret_api));
        native_sdk_secret_api.attempted = 1;
        return NULL;
    }

    native_sdk_secret_api.handle = handle;
    return &native_sdk_secret_api;
}

static void native_sdk_secure_free(char *bytes, size_t len) {
    if (!bytes) return;
    volatile char *cursor = bytes;
    for (size_t i = 0; i < len; i++) cursor[i] = 0;
    free(bytes);
}

int native_sdk_gtk_credentials_available(native_sdk_gtk_host_t *host) {
    (void)host;
    return native_sdk_load_secret_api() ? 1 : 0;
}

int native_sdk_gtk_set_credential(native_sdk_gtk_host_t *host, const char *service, size_t service_len, const char *account, size_t account_len, const char *secret, size_t secret_len) {
    (void)host;
    native_sdk_secret_api_t *api = native_sdk_load_secret_api();
    if (!api || !service || service_len == 0 || !account || account_len == 0 || !secret || secret_len == 0) return 0;

    char *service_copy = native_sdk_strndup(service, service_len);
    char *account_copy = native_sdk_strndup(account, account_len);
    char *secret_copy = native_sdk_strndup(secret, secret_len);
    if (!service_copy || !account_copy || !secret_copy) {
        free(service_copy);
        free(account_copy);
        native_sdk_secure_free(secret_copy, secret_len);
        return 0;
    }

    char *label = g_strdup_printf("%s:%s", service_copy, account_copy);
    if (!label) {
        free(service_copy);
        free(account_copy);
        native_sdk_secure_free(secret_copy, secret_len);
        return 0;
    }

    GError *error = NULL;
    gboolean ok = api->store_sync(&native_sdk_credential_schema, "default", label, secret_copy, NULL, &error, "service", service_copy, "account", account_copy, NULL);
    if (error) g_error_free(error);

    g_free(label);
    free(service_copy);
    free(account_copy);
    native_sdk_secure_free(secret_copy, secret_len);
    return ok ? 1 : 0;
}

size_t native_sdk_gtk_get_credential(native_sdk_gtk_host_t *host, const char *service, size_t service_len, const char *account, size_t account_len, char *buffer, size_t buffer_len) {
    (void)host;
    native_sdk_secret_api_t *api = native_sdk_load_secret_api();
    if (!api || !service || service_len == 0 || !account || account_len == 0 || !buffer) return 0;

    char *service_copy = native_sdk_strndup(service, service_len);
    char *account_copy = native_sdk_strndup(account, account_len);
    if (!service_copy || !account_copy) {
        free(service_copy);
        free(account_copy);
        return 0;
    }

    GError *error = NULL;
    char *password = api->lookup_sync(&native_sdk_credential_schema, NULL, &error, "service", service_copy, "account", account_copy, NULL);
    free(service_copy);
    free(account_copy);
    if (error) {
        g_error_free(error);
        return (size_t)-1;
    }
    if (!password) return 0;

    size_t password_len = strlen(password);
    if (password_len <= buffer_len && password_len > 0) memcpy(buffer, password, password_len);
    g_free(password);
    return password_len;
}

int native_sdk_gtk_delete_credential(native_sdk_gtk_host_t *host, const char *service, size_t service_len, const char *account, size_t account_len) {
    (void)host;
    native_sdk_secret_api_t *api = native_sdk_load_secret_api();
    if (!api || !service || service_len == 0 || !account || account_len == 0) return 0;

    char *service_copy = native_sdk_strndup(service, service_len);
    char *account_copy = native_sdk_strndup(account, account_len);
    if (!service_copy || !account_copy) {
        free(service_copy);
        free(account_copy);
        return 0;
    }

    GError *error = NULL;
    gboolean ok = api->clear_sync(&native_sdk_credential_schema, NULL, &error, "service", service_copy, "account", account_copy, NULL);
    free(service_copy);
    free(account_copy);
    if (error) {
        g_error_free(error);
        return -1;
    }
    return ok ? 1 : 0;
}

/* ---------------------------------------------------------------- audio
 *
 * Backend: the GStreamer PLAYBIN pipeline (gst-1.0). One in-box element
 * covers the whole contract the other desktop hosts implement: local
 * MP3 decode, progressive HTTP(S) streaming (audible before the
 * download finishes, with honest buffering reports), pause/resume,
 * accurate seek, per-pipeline volume, duration, and natural-end EOS.
 * The library is runtime-loaded with dlopen exactly like libsecret
 * above, so the toolkit's build inputs and link surface stay GTK +
 * WebKitGTK only; a host without GStreamer reports the audio
 * capabilities unsupported and every call degrades to the explicit
 * unsupported answer — never a crash.
 *
 * Contract mirror of the macOS and Windows hosts: one player for the
 * whole app; URL sources resolve verified-cache-first, then stream
 * while a PARALLEL download fills the cache (part file beside the final
 * name, size-verified against the manifest, atomic same-directory
 * rename — a partial file never occupies the cache name, even across a
 * crash); LOADED is asynchronous (preroll complete), position ticks
 * ride a 500 ms GLib timer armed only while playing, completion and
 * failure are single terminal reports. Threading is simpler here than
 * on the other hosts: the bus signal watch is a GSource on the default
 * GLib main context — the same loop GTK runs — so every pipeline
 * message already arrives on the loop thread and host state stays
 * loop-thread-owned with no marshalling layer.
 *
 * The cache fill downloads over libsoup (session_send + GInputStream),
 * also dlopen-loaded: WebKitGTK links libsoup-3.0, so the library is
 * present wherever this host runs, and it handles TLS, redirects, and
 * chunked transfer that a hand-rolled socket client would have to
 * rebuild. No fill download runs when it is unavailable — the stream
 * still plays; the next play streams again. */

#define NATIVE_SDK_AUDIO_EVENT_LOADED 0
#define NATIVE_SDK_AUDIO_EVENT_POSITION 1
#define NATIVE_SDK_AUDIO_EVENT_COMPLETED 2
#define NATIVE_SDK_AUDIO_EVENT_FAILED 3
#define NATIVE_SDK_AUDIO_EVENT_SPECTRUM 4

/* 500 ms is the shared coarse position cadence (macOS, Windows, and the
 * null platform tick the same), so frame-clock scrubber interpolation
 * behaves identically across hosts. */
#define NATIVE_SDK_AUDIO_POSITION_INTERVAL_MS 500

/* Spectrum analysis contract (shared across hosts, see the SDK's audio
 * event documentation): 32 report bands with log-spaced buckets
 * covering 50 Hz..16 kHz; each byte is the bucket's PEAK magnitude in
 * dBFS clamped to [-60, 0] and mapped linearly onto 0..255. The
 * analyzer itself runs at a higher LINEAR resolution (128 bins over
 * 0..rate/2) so the log fold has real data in the low buckets, and
 * posts every 40 ms — only while samples actually flow, so pause and
 * stop starve the reports naturally. The interval is nanoseconds
 * (GStreamer clock time, hand-mirrored like the other constants). */
#define NATIVE_SDK_AUDIO_SPECTRUM_BANDS 32
#define NATIVE_SDK_AUDIO_SPECTRUM_SOURCE_BANDS 128
#define NATIVE_SDK_AUDIO_SPECTRUM_INTERVAL_NS ((guint64)40000000)
#define NATIVE_SDK_AUDIO_SPECTRUM_FLOOR_DB (-60.0f)
#define NATIVE_SDK_AUDIO_SPECTRUM_MIN_HZ 50.0f
#define NATIVE_SDK_AUDIO_SPECTRUM_MAX_HZ 16000.0f

/* GStreamer core constants, mirrored from the stable public API (the
 * same hand-mirroring the libsecret schema above uses): element states,
 * the time format, and the flushing/accurate seek flags. */
#define NATIVE_SDK_GST_STATE_NULL 1
#define NATIVE_SDK_GST_STATE_PAUSED 3
#define NATIVE_SDK_GST_STATE_PLAYING 4
#define NATIVE_SDK_GST_STATE_CHANGE_FAILURE 0
#define NATIVE_SDK_GST_STATE_CHANGE_ASYNC 2
#define NATIVE_SDK_GST_FORMAT_TIME 3
#define NATIVE_SDK_GST_SEEK_FLAG_FLUSH (1 << 0)
#define NATIVE_SDK_GST_SEEK_FLAG_ACCURATE (1 << 1)
/* playbin "flags": decode audio with software volume only — no video
 * sink is ever built (the deselected-non-audio-streams discipline the
 * other hosts apply); BUFFERING additionally emits buffering messages
 * while a stream's queue fills, the honest stall signal. */
#define NATIVE_SDK_GST_PLAY_FLAG_AUDIO (1u << 1)
#define NATIVE_SDK_GST_PLAY_FLAG_SOFT_VOLUME (1u << 4)
#define NATIVE_SDK_GST_PLAY_FLAG_BUFFERING (1u << 8)

typedef int (*native_sdk_gst_init_check_fn)(int *argc, char ***argv, GError **error);
typedef void *(*native_sdk_gst_element_factory_find_fn)(const char *factory_name);
typedef void *(*native_sdk_gst_element_factory_make_fn)(const char *factory_name, const char *name);
typedef int (*native_sdk_gst_element_set_state_fn)(void *element, int state);
typedef int (*native_sdk_gst_element_query_position_fn)(void *element, int format, int64_t *cur);
typedef int (*native_sdk_gst_element_query_duration_fn)(void *element, int format, int64_t *dur);
typedef int (*native_sdk_gst_element_seek_simple_fn)(void *element, int format, int seek_flags, int64_t seek_pos);
typedef void *(*native_sdk_gst_element_get_bus_fn)(void *element);
typedef void (*native_sdk_gst_bus_add_signal_watch_fn)(void *bus);
typedef void (*native_sdk_gst_bus_remove_signal_watch_fn)(void *bus);
typedef void (*native_sdk_gst_message_parse_buffering_fn)(void *message, int *percent);
typedef void (*native_sdk_gst_message_parse_state_changed_fn)(void *message, int *old_state, int *new_state, int *pending_state);

typedef struct native_sdk_gst_api {
    int attempted;
    int ready;
    void *handle;
    native_sdk_gst_init_check_fn init_check;
    native_sdk_gst_element_factory_find_fn element_factory_find;
    native_sdk_gst_element_factory_make_fn element_factory_make;
    native_sdk_gst_element_set_state_fn element_set_state;
    native_sdk_gst_element_query_position_fn element_query_position;
    native_sdk_gst_element_query_duration_fn element_query_duration;
    native_sdk_gst_element_seek_simple_fn element_seek_simple;
    native_sdk_gst_element_get_bus_fn element_get_bus;
    native_sdk_gst_bus_add_signal_watch_fn bus_add_signal_watch;
    native_sdk_gst_bus_remove_signal_watch_fn bus_remove_signal_watch;
    native_sdk_gst_message_parse_buffering_fn message_parse_buffering;
    native_sdk_gst_message_parse_state_changed_fn message_parse_state_changed;
} native_sdk_gst_api_t;

static native_sdk_gst_api_t native_sdk_gst_api = {0};

static native_sdk_gst_api_t *native_sdk_load_gst_api(void) {
    if (native_sdk_gst_api.attempted) return native_sdk_gst_api.ready ? &native_sdk_gst_api : NULL;
    native_sdk_gst_api.attempted = 1;

    void *handle = dlopen("libgstreamer-1.0.so.0", RTLD_NOW | RTLD_LOCAL);
    if (!handle) handle = dlopen("libgstreamer-1.0.so", RTLD_NOW | RTLD_LOCAL);
    if (!handle) return NULL;

    native_sdk_gst_api.init_check = (native_sdk_gst_init_check_fn)native_sdk_dlsym(handle, "gst_init_check");
    native_sdk_gst_api.element_factory_find = (native_sdk_gst_element_factory_find_fn)native_sdk_dlsym(handle, "gst_element_factory_find");
    native_sdk_gst_api.element_factory_make = (native_sdk_gst_element_factory_make_fn)native_sdk_dlsym(handle, "gst_element_factory_make");
    native_sdk_gst_api.element_set_state = (native_sdk_gst_element_set_state_fn)native_sdk_dlsym(handle, "gst_element_set_state");
    native_sdk_gst_api.element_query_position = (native_sdk_gst_element_query_position_fn)native_sdk_dlsym(handle, "gst_element_query_position");
    native_sdk_gst_api.element_query_duration = (native_sdk_gst_element_query_duration_fn)native_sdk_dlsym(handle, "gst_element_query_duration");
    native_sdk_gst_api.element_seek_simple = (native_sdk_gst_element_seek_simple_fn)native_sdk_dlsym(handle, "gst_element_seek_simple");
    native_sdk_gst_api.element_get_bus = (native_sdk_gst_element_get_bus_fn)native_sdk_dlsym(handle, "gst_element_get_bus");
    native_sdk_gst_api.bus_add_signal_watch = (native_sdk_gst_bus_add_signal_watch_fn)native_sdk_dlsym(handle, "gst_bus_add_signal_watch");
    native_sdk_gst_api.bus_remove_signal_watch = (native_sdk_gst_bus_remove_signal_watch_fn)native_sdk_dlsym(handle, "gst_bus_remove_signal_watch");
    native_sdk_gst_api.message_parse_buffering = (native_sdk_gst_message_parse_buffering_fn)native_sdk_dlsym(handle, "gst_message_parse_buffering");
    native_sdk_gst_api.message_parse_state_changed = (native_sdk_gst_message_parse_state_changed_fn)native_sdk_dlsym(handle, "gst_message_parse_state_changed");
    const int resolved = native_sdk_gst_api.init_check && native_sdk_gst_api.element_factory_find &&
        native_sdk_gst_api.element_factory_make &&
        native_sdk_gst_api.element_set_state && native_sdk_gst_api.element_query_position &&
        native_sdk_gst_api.element_query_duration && native_sdk_gst_api.element_seek_simple &&
        native_sdk_gst_api.element_get_bus && native_sdk_gst_api.bus_add_signal_watch &&
        native_sdk_gst_api.bus_remove_signal_watch && native_sdk_gst_api.message_parse_buffering &&
        native_sdk_gst_api.message_parse_state_changed;
    if (!resolved) {
        dlclose(handle);
        memset(&native_sdk_gst_api, 0, sizeof(native_sdk_gst_api));
        native_sdk_gst_api.attempted = 1;
        return NULL;
    }
    /* One-time library bring-up (registry scan). A failed init leaves
     * the handle open — the library may hold global state by now — and
     * simply reports the backend unavailable. */
    if (!native_sdk_gst_api.init_check(NULL, NULL, NULL)) return NULL;
    /* The library alone is not a player: playbin ships in the base
     * plugin set, which distros package separately (the core library is
     * even a transitive WebKitGTK dependency, so it is nearly always
     * present). Probe the actual runtime variable — a host whose plugin
     * set cannot build a playbin answers unsupported up front instead of
     * failing every load. */
    void *playbin_factory = native_sdk_gst_api.element_factory_find("playbin");
    if (!playbin_factory) return NULL;
    g_object_unref(playbin_factory);
    native_sdk_gst_api.handle = handle;
    native_sdk_gst_api.ready = 1;
    return &native_sdk_gst_api;
}

/* The spectrum-only slice of the GStreamer surface, resolved SEPARATELY
 * from the core player symbols on purpose: these are needed only to
 * parse the `spectrum` element's bus messages and read the negotiated
 * sample rate, so a host where any of them is missing keeps a fully
 * working player and merely reports analysis unavailable — the additive
 * capability degrades alone, never the playback it rides on. GLib and
 * GObject calls (g_object_set, g_value_get_float) stay direct links,
 * as everywhere else in this file; only GStreamer goes through dlsym
 * because the toolkit's link surface is GTK + WebKitGTK. */
typedef const void *(*native_sdk_gst_message_get_structure_fn)(void *message);
typedef const char *(*native_sdk_gst_structure_get_name_fn)(const void *structure);
typedef const GValue *(*native_sdk_gst_structure_get_value_fn)(const void *structure, const char *fieldname);
typedef unsigned (*native_sdk_gst_value_list_get_size_fn)(const GValue *value);
typedef const GValue *(*native_sdk_gst_value_list_get_value_fn)(const GValue *value, unsigned index);
typedef void *(*native_sdk_gst_element_get_static_pad_fn)(void *element, const char *name);
typedef void *(*native_sdk_gst_pad_get_current_caps_fn)(void *pad);
typedef void *(*native_sdk_gst_caps_get_structure_fn)(void *caps, unsigned index);
typedef int (*native_sdk_gst_structure_get_int_fn)(const void *structure, const char *fieldname, int *value);
typedef void (*native_sdk_gst_mini_object_unref_fn)(void *mini_object);

typedef struct native_sdk_gst_spectrum_api {
    int attempted;
    int ready;
    native_sdk_gst_message_get_structure_fn message_get_structure;
    native_sdk_gst_structure_get_name_fn structure_get_name;
    native_sdk_gst_structure_get_value_fn structure_get_value;
    native_sdk_gst_value_list_get_size_fn value_list_get_size;
    native_sdk_gst_value_list_get_value_fn value_list_get_value;
    native_sdk_gst_element_get_static_pad_fn element_get_static_pad;
    native_sdk_gst_pad_get_current_caps_fn pad_get_current_caps;
    native_sdk_gst_caps_get_structure_fn caps_get_structure;
    native_sdk_gst_structure_get_int_fn structure_get_int;
    /* GstCaps is a GstMiniObject, not a GObject — its release goes
     * through gst_mini_object_unref (the header-only gst_caps_unref is
     * an inline over exactly this call). */
    native_sdk_gst_mini_object_unref_fn mini_object_unref;
} native_sdk_gst_spectrum_api_t;

static native_sdk_gst_spectrum_api_t native_sdk_gst_spectrum_api = {0};

static native_sdk_gst_spectrum_api_t *native_sdk_load_gst_spectrum_api(void) {
    if (native_sdk_gst_spectrum_api.attempted) return native_sdk_gst_spectrum_api.ready ? &native_sdk_gst_spectrum_api : NULL;
    /* Rides the core loader's handle: without a playable backend there
     * is nothing to analyze. */
    native_sdk_gst_api_t *gst = native_sdk_load_gst_api();
    native_sdk_gst_spectrum_api.attempted = 1;
    if (!gst) return NULL;
    void *handle = gst->handle;
    native_sdk_gst_spectrum_api.message_get_structure = (native_sdk_gst_message_get_structure_fn)native_sdk_dlsym(handle, "gst_message_get_structure");
    native_sdk_gst_spectrum_api.structure_get_name = (native_sdk_gst_structure_get_name_fn)native_sdk_dlsym(handle, "gst_structure_get_name");
    native_sdk_gst_spectrum_api.structure_get_value = (native_sdk_gst_structure_get_value_fn)native_sdk_dlsym(handle, "gst_structure_get_value");
    native_sdk_gst_spectrum_api.value_list_get_size = (native_sdk_gst_value_list_get_size_fn)native_sdk_dlsym(handle, "gst_value_list_get_size");
    native_sdk_gst_spectrum_api.value_list_get_value = (native_sdk_gst_value_list_get_value_fn)native_sdk_dlsym(handle, "gst_value_list_get_value");
    native_sdk_gst_spectrum_api.element_get_static_pad = (native_sdk_gst_element_get_static_pad_fn)native_sdk_dlsym(handle, "gst_element_get_static_pad");
    native_sdk_gst_spectrum_api.pad_get_current_caps = (native_sdk_gst_pad_get_current_caps_fn)native_sdk_dlsym(handle, "gst_pad_get_current_caps");
    native_sdk_gst_spectrum_api.caps_get_structure = (native_sdk_gst_caps_get_structure_fn)native_sdk_dlsym(handle, "gst_caps_get_structure");
    native_sdk_gst_spectrum_api.structure_get_int = (native_sdk_gst_structure_get_int_fn)native_sdk_dlsym(handle, "gst_structure_get_int");
    native_sdk_gst_spectrum_api.mini_object_unref = (native_sdk_gst_mini_object_unref_fn)native_sdk_dlsym(handle, "gst_mini_object_unref");
    const int resolved = native_sdk_gst_spectrum_api.message_get_structure &&
        native_sdk_gst_spectrum_api.structure_get_name && native_sdk_gst_spectrum_api.structure_get_value &&
        native_sdk_gst_spectrum_api.value_list_get_size && native_sdk_gst_spectrum_api.value_list_get_value &&
        native_sdk_gst_spectrum_api.element_get_static_pad && native_sdk_gst_spectrum_api.pad_get_current_caps &&
        native_sdk_gst_spectrum_api.caps_get_structure && native_sdk_gst_spectrum_api.structure_get_int &&
        native_sdk_gst_spectrum_api.mini_object_unref;
    if (!resolved) {
        /* The handle belongs to the core api — never closed here. */
        memset(&native_sdk_gst_spectrum_api, 0, sizeof(native_sdk_gst_spectrum_api));
        native_sdk_gst_spectrum_api.attempted = 1;
        return NULL;
    }
    native_sdk_gst_spectrum_api.ready = 1;
    return &native_sdk_gst_spectrum_api;
}

typedef void *(*native_sdk_soup_session_new_fn)(void);
typedef void *(*native_sdk_soup_message_new_fn)(const char *method, const char *uri_string);
typedef void *(*native_sdk_soup_session_send_fn)(void *session, void *message, GCancellable *cancellable, GError **error);
typedef unsigned (*native_sdk_soup_message_get_status_fn)(void *message);

typedef struct native_sdk_soup_api {
    int attempted;
    void *handle;
    native_sdk_soup_session_new_fn session_new;
    native_sdk_soup_message_new_fn message_new;
    native_sdk_soup_session_send_fn session_send;
    native_sdk_soup_message_get_status_fn message_get_status;
} native_sdk_soup_api_t;

static native_sdk_soup_api_t native_sdk_soup_api = {0};

static native_sdk_soup_api_t *native_sdk_load_soup_api(void) {
    if (native_sdk_soup_api.attempted) return native_sdk_soup_api.handle ? &native_sdk_soup_api : NULL;
    native_sdk_soup_api.attempted = 1;

    void *handle = dlopen("libsoup-3.0.so.0", RTLD_NOW | RTLD_LOCAL);
    if (!handle) handle = dlopen("libsoup-3.0.so", RTLD_NOW | RTLD_LOCAL);
    if (!handle) return NULL;

    native_sdk_soup_api.session_new = (native_sdk_soup_session_new_fn)native_sdk_dlsym(handle, "soup_session_new");
    native_sdk_soup_api.message_new = (native_sdk_soup_message_new_fn)native_sdk_dlsym(handle, "soup_message_new");
    native_sdk_soup_api.session_send = (native_sdk_soup_session_send_fn)native_sdk_dlsym(handle, "soup_session_send");
    native_sdk_soup_api.message_get_status = (native_sdk_soup_message_get_status_fn)native_sdk_dlsym(handle, "soup_message_get_status");
    if (!native_sdk_soup_api.session_new || !native_sdk_soup_api.message_new || !native_sdk_soup_api.session_send || !native_sdk_soup_api.message_get_status) {
        dlclose(handle);
        memset(&native_sdk_soup_api, 0, sizeof(native_sdk_soup_api));
        native_sdk_soup_api.attempted = 1;
        return NULL;
    }
    native_sdk_soup_api.handle = handle;
    return &native_sdk_soup_api;
}

/* The cache fill is a PARALLEL download, not a tee off the pipeline's
 * own network source: a partially buffered stream must never masquerade
 * as a cache entry. One extra request on a track's first (uncached)
 * play buys a stock streaming path and a cache whose entries are whole
 * files by construction: downloaded beside the final name,
 * size-verified against the manifest, and renamed into place — a
 * same-directory rename, so a partial file never occupies the cache
 * name even across a crash. Detached GLib thread, file and network work
 * only, never host state; a failed or cancelled download simply leaves
 * no cache entry (the next play streams again). */
typedef struct native_sdk_audio_download {
    char *url;
    char *cache_path;
    uint64_t expected_bytes;
    GCancellable *cancel; /* the job owns one reference */
} native_sdk_audio_download_t;

static gpointer native_sdk_audio_download_thread(gpointer data) {
    native_sdk_audio_download_t *job = data;
    native_sdk_soup_api_t *soup = native_sdk_load_soup_api();
    char *part_path = g_strdup_printf("%s.part", job->cache_path);
    int ok = 0;
    if (soup && part_path) {
        char *directory = g_path_get_dirname(job->cache_path);
        if (directory) {
            g_mkdir_with_parents(directory, 0700);
            g_free(directory);
        }
        g_remove(part_path);
        void *session = soup->session_new();
        void *message = session ? soup->message_new("GET", job->url) : NULL;
        GInputStream *stream = message ? (GInputStream *)soup->session_send(session, message, job->cancel, NULL) : NULL;
        FILE *file = NULL;
        /* Only a 200 installs bytes — an error page must never
         * masquerade as a track. */
        if (stream && soup->message_get_status(message) == 200) file = g_fopen(part_path, "wb");
        if (file) {
            char buffer[64 * 1024];
            for (;;) {
                gssize count = g_input_stream_read(stream, buffer, sizeof(buffer), job->cancel, NULL);
                if (count < 0) break; /* network error or cancelled */
                if (count == 0) {
                    ok = 1;
                    break;
                }
                if (fwrite(buffer, 1, (size_t)count, file) != (size_t)count) break;
            }
            if (fclose(file) != 0) ok = 0;
        }
        if (stream) {
            g_input_stream_close(stream, NULL, NULL);
            g_object_unref(stream);
        }
        if (message) g_object_unref(message);
        if (session) g_object_unref(session);
    }
    if (ok && part_path && !g_cancellable_is_cancelled(job->cancel)) {
        GStatBuf stat_buf;
        /* Truncated or wrong content: never installed. */
        ok = g_stat(part_path, &stat_buf) == 0 &&
            (job->expected_bytes == 0 || (uint64_t)stat_buf.st_size == job->expected_bytes);
        if (ok) {
            g_remove(job->cache_path);
            ok = g_rename(part_path, job->cache_path) == 0;
        }
    } else {
        ok = 0;
    }
    if (!ok && part_path) g_remove(part_path);
    g_free(part_path);
    free(job->url);
    free(job->cache_path);
    g_object_unref(job->cancel);
    free(job);
    return NULL;
}

static void native_sdk_audio_emit_report(native_sdk_gtk_host_t *host, int kind, uint64_t position_ms, uint64_t duration_ms, int playing, int buffering) {
    native_sdk_emit(host, (native_sdk_gtk_event_t){
        .kind = NATIVE_SDK_GTK_EVENT_AUDIO,
        .timestamp_ns = native_sdk_gpu_timestamp_ns(),
        .audio_kind = kind,
        .audio_position_ms = position_ms,
        .audio_duration_ms = duration_ms,
        .audio_playing = playing,
        .audio_buffering = buffering,
    });
}

/* Live position off the pipeline clock; unanswerable (pre-preroll) reads
 * report 0. Nanoseconds to ms. */
static uint64_t native_sdk_audio_position_ms(native_sdk_gtk_host_t *host) {
    native_sdk_gst_api_t *gst = native_sdk_load_gst_api();
    if (!gst || !host->audio.playbin) return 0;
    int64_t position = 0;
    if (!gst->element_query_position(host->audio.playbin, NATIVE_SDK_GST_FORMAT_TIME, &position) || position < 0) return 0;
    return (uint64_t)position / 1000000ull;
}

static void native_sdk_audio_emit_event(native_sdk_gtk_host_t *host, int kind) {
    native_sdk_gtk_audio_t *audio = &host->audio;
    native_sdk_audio_emit_report(host, kind, native_sdk_audio_position_ms(host), audio->duration_ms, audio->playing ? 1 : 0, audio->buffering ? 1 : 0);
}

/* The SPECTRUM sibling of the report emit above: the transport readout
 * fills exactly like a position tick's (live position at emit time)
 * with the folded band bytes on top. Every other emit in this section
 * zero-initializes the event struct, so audio_bands is all zeros on
 * every non-spectrum event by construction.
 *
 * No occluded/minimized emission gate here, DELIBERATELY — the same
 * reasoning as the frame emission's missing occlusion throttle: GTK4
 * offers no visibility fact that holds across backends (full coverage
 * is unreported, Wayland keeps minimize compositor-private, and the
 * toplevel "suspended" state is compositor-dependent and can arrive
 * late or never), and gating on a signal that may never clear would
 * freeze visible bars on some desktops — worse than the CPU the gate
 * saves. The macOS host parks its spectrum tick while no window is
 * visible and the Windows host drops emission while every window is
 * minimized; if a dependable cross-backend visibility fact lands in
 * the toolkit's GTK floor, gate here exactly like them: no events
 * while hidden, next report immediately on reveal. */
static void native_sdk_audio_emit_spectrum(native_sdk_gtk_host_t *host, const uint8_t bands[NATIVE_SDK_AUDIO_SPECTRUM_BANDS]) {
    native_sdk_gtk_audio_t *audio = &host->audio;
    native_sdk_gtk_event_t event = {
        .kind = NATIVE_SDK_GTK_EVENT_AUDIO,
        .timestamp_ns = native_sdk_gpu_timestamp_ns(),
        .audio_kind = NATIVE_SDK_AUDIO_EVENT_SPECTRUM,
        .audio_position_ms = native_sdk_audio_position_ms(host),
        .audio_duration_ms = audio->duration_ms,
        .audio_playing = audio->playing ? 1 : 0,
        .audio_buffering = audio->buffering ? 1 : 0,
    };
    memcpy(event.audio_bands, bands, sizeof(event.audio_bands));
    native_sdk_emit(host, event);
}

/* WM-timer analog for the audio position tick: one position report per
 * interval while a playback is live; a straggler after teardown retires
 * itself. Streams may learn their real duration late — re-query while
 * it is still unknown so the tick's readout converges on the truth. */
static gboolean native_sdk_audio_position_tick(gpointer data) {
    native_sdk_gtk_host_t *host = data;
    native_sdk_gtk_audio_t *audio = &host->audio;
    if (!audio->active) {
        audio->position_timer = 0;
        return G_SOURCE_REMOVE;
    }
    if (audio->duration_ms == 0) {
        native_sdk_gst_api_t *gst = native_sdk_load_gst_api();
        int64_t duration = 0;
        if (gst && audio->playbin && gst->element_query_duration(audio->playbin, NATIVE_SDK_GST_FORMAT_TIME, &duration) && duration > 0) {
            audio->duration_ms = (uint64_t)duration / 1000000ull;
        }
    }
    native_sdk_audio_emit_event(host, NATIVE_SDK_AUDIO_EVENT_POSITION);
    return G_SOURCE_CONTINUE;
}

static void native_sdk_audio_stop_position_timer(native_sdk_gtk_host_t *host) {
    if (host->audio.position_timer) {
        g_source_remove(host->audio.position_timer);
        host->audio.position_timer = 0;
    }
}

static void native_sdk_audio_start_position_timer(native_sdk_gtk_host_t *host) {
    if (host->audio.position_timer) return;
    host->audio.position_timer = g_timeout_add(NATIVE_SDK_AUDIO_POSITION_INTERVAL_MS, native_sdk_audio_position_tick, host);
}

/* Release the whole pipeline. The bus watch comes off first, so no
 * message outlives the player it belonged to. The cache download is
 * cancelled when the caller says so (replacement, explicit stop,
 * failure — a skipped track should not keep burning bandwidth) but
 * ORPHANED on natural completion: it is usually already done, and
 * letting a straggler finish installs the cache entry the completed
 * play earned. */
static void native_sdk_audio_release(native_sdk_gtk_host_t *host, int cancel_download) {
    native_sdk_gtk_audio_t *audio = &host->audio;
    native_sdk_gst_api_t *gst = native_sdk_load_gst_api();
    native_sdk_audio_stop_position_timer(host);
    if (audio->bus) {
        for (size_t i = 0; i < G_N_ELEMENTS(audio->bus_handlers); i++) {
            if (audio->bus_handlers[i]) g_signal_handler_disconnect(audio->bus, audio->bus_handlers[i]);
            audio->bus_handlers[i] = 0;
        }
        if (gst) gst->bus_remove_signal_watch(audio->bus);
        g_object_unref(audio->bus);
        audio->bus = NULL;
    }
    if (audio->playbin) {
        if (gst) gst->element_set_state(audio->playbin, NATIVE_SDK_GST_STATE_NULL);
        g_object_unref(audio->playbin);
        audio->playbin = NULL;
    }
    if (audio->spectrum) {
        /* The playbin owned the analyzer's pipeline membership and is
         * already released; this drops the one ref sunk at attach. */
        g_object_unref(audio->spectrum);
        audio->spectrum = NULL;
    }
    if (audio->download_cancel) {
        if (cancel_download) g_cancellable_cancel(audio->download_cancel);
        g_object_unref(audio->download_cancel);
        audio->download_cancel = NULL;
    }
    free(audio->cache_entry_path);
    memset(audio, 0, sizeof(*audio));
    audio->volume = 1.0;
}

/* Bus signal handlers. All of these run on the GLib main loop (the bus
 * signal watch is a main-context GSource), so they touch host state
 * directly — the loop-thread-ownership rule the other hosts enforce
 * with an explicit marshalling hop holds here by construction. */

/* Preroll complete: the pipeline knows its duration and accepts
 * transport calls. Apply the queued intent (seek, play), THEN
 * acknowledge with LOADED so the event carries the honest playing flag
 * — the runtime issues play immediately after load, before readiness,
 * exactly like the other hosts. Later async-done messages (each
 * flushing seek produces one) change nothing here. */
static void native_sdk_audio_on_async_done(void *bus, void *message, gpointer data) {
    (void)bus;
    (void)message;
    native_sdk_gtk_host_t *host = data;
    native_sdk_gtk_audio_t *audio = &host->audio;
    native_sdk_gst_api_t *gst = native_sdk_load_gst_api();
    if (!gst || !audio->active || !audio->playbin || audio->ready) return;
    audio->ready = 1;
    int64_t duration = 0;
    if (gst->element_query_duration(audio->playbin, NATIVE_SDK_GST_FORMAT_TIME, &duration) && duration > 0) {
        audio->duration_ms = (uint64_t)duration / 1000000ull;
    }
    if (audio->has_pending_seek) {
        audio->has_pending_seek = 0;
        gst->element_seek_simple(audio->playbin, NATIVE_SDK_GST_FORMAT_TIME, NATIVE_SDK_GST_SEEK_FLAG_FLUSH | NATIVE_SDK_GST_SEEK_FLAG_ACCURATE, (int64_t)audio->pending_seek_ms * 1000000);
    }
    if (audio->pending_play) {
        audio->pending_play = 0;
        if (!audio->refilling) gst->element_set_state(audio->playbin, NATIVE_SDK_GST_STATE_PLAYING);
    }
    if (!audio->loaded_emitted) {
        audio->loaded_emitted = 1;
        native_sdk_audio_emit_event(host, NATIVE_SDK_AUDIO_EVENT_LOADED);
    }
}

/* The pipeline actually reached PLAYING: a fresh stream's optimistic
 * buffering flag drops here and is emitted immediately (not at the next
 * tick), the same transition report the other hosts make when their
 * transport starts rolling. */
static void native_sdk_audio_on_state_changed(void *bus, void *message, gpointer data) {
    (void)bus;
    native_sdk_gtk_host_t *host = data;
    native_sdk_gtk_audio_t *audio = &host->audio;
    native_sdk_gst_api_t *gst = native_sdk_load_gst_api();
    if (!gst || !audio->active || !audio->buffering || audio->refilling) return;
    int old_state = 0;
    int new_state = 0;
    int pending_state = 0;
    gst->message_parse_state_changed(message, &old_state, &new_state, &pending_state);
    if (new_state != NATIVE_SDK_GST_STATE_PLAYING) return;
    audio->buffering = 0;
    native_sdk_audio_emit_event(host, NATIVE_SDK_AUDIO_EVENT_POSITION);
}

/* The sample rate the analyzer negotiated, read from its sink pad's
 * current caps: the spectrum element reports linear bins over
 * 0..rate/2, so the fold needs the real rate to place bin centers on
 * the frequency axis. Cached once learned (one pipeline analyzes one
 * track, the rate never changes mid-stream); until caps exist the
 * fold assumes 48 kHz WITHOUT caching, so a later message can still
 * learn the truth. */
static int native_sdk_audio_spectrum_rate(native_sdk_gtk_host_t *host) {
    native_sdk_gtk_audio_t *audio = &host->audio;
    if (audio->spectrum_rate > 0) return audio->spectrum_rate;
    native_sdk_gst_spectrum_api_t *api = native_sdk_load_gst_spectrum_api();
    int rate = 0;
    void *pad = api ? api->element_get_static_pad(audio->spectrum, "sink") : NULL;
    if (pad) {
        void *caps = api->pad_get_current_caps(pad);
        if (caps) {
            const void *structure = api->caps_get_structure(caps, 0);
            if (!structure || !api->structure_get_int(structure, "rate", &rate)) rate = 0;
            api->mini_object_unref(caps);
        }
        g_object_unref(pad);
    }
    if (rate > 0) {
        audio->spectrum_rate = rate;
        return rate;
    }
    return 48000;
}

/* ELEMENT bus messages: the analyzer posts one GstStructure named
 * "spectrum" per interval — but only while samples flow through it, so
 * pause, stop, and a buffering stall end the reports without any
 * bookkeeping here. The "magnitude" field is a GValue LIST of floats,
 * one dB magnitude per linear bin over 0..rate/2; the fold below maps
 * each bin center onto the 32 log-spaced 50 Hz..16 kHz report buckets
 * and keeps the bucket PEAK. Low buckets narrower than one linear bin
 * borrow the bin that covers their center frequency, so the bass bars
 * read the real (coarser) magnitude instead of resting at the floor. */
static void native_sdk_audio_on_element(void *bus, void *message, gpointer data) {
    (void)bus;
    native_sdk_gtk_host_t *host = data;
    native_sdk_gtk_audio_t *audio = &host->audio;
    native_sdk_gst_spectrum_api_t *api = native_sdk_load_gst_spectrum_api();
    if (!api || !audio->active || !audio->spectrum) return;
    const void *structure = api->message_get_structure(message);
    if (!structure) return;
    const char *name = api->structure_get_name(structure);
    if (!name || strcmp(name, "spectrum") != 0) return;
    const GValue *magnitudes = api->structure_get_value(structure, "magnitude");
    if (!magnitudes) return;
    const unsigned bins = api->value_list_get_size(magnitudes);
    if (bins == 0) return;

    const int rate = native_sdk_audio_spectrum_rate(host);
    const float bin_hz = ((float)rate * 0.5f) / (float)bins;
    if (bin_hz <= 0.0f) return;
    /* Log-spaced bucket edges: edge(k) = 50 Hz * (16000/50)^(k/32). */
    const float span = logf(NATIVE_SDK_AUDIO_SPECTRUM_MAX_HZ / NATIVE_SDK_AUDIO_SPECTRUM_MIN_HZ);

    float peak_db[NATIVE_SDK_AUDIO_SPECTRUM_BANDS];
    int filled[NATIVE_SDK_AUDIO_SPECTRUM_BANDS] = {0};
    for (int k = 0; k < NATIVE_SDK_AUDIO_SPECTRUM_BANDS; k++) peak_db[k] = NATIVE_SDK_AUDIO_SPECTRUM_FLOOR_DB;
    for (unsigned i = 0; i < bins; i++) {
        const float center = ((float)i + 0.5f) * bin_hz;
        if (center < NATIVE_SDK_AUDIO_SPECTRUM_MIN_HZ || center >= NATIVE_SDK_AUDIO_SPECTRUM_MAX_HZ) continue;
        int bucket = (int)((float)NATIVE_SDK_AUDIO_SPECTRUM_BANDS * logf(center / NATIVE_SDK_AUDIO_SPECTRUM_MIN_HZ) / span);
        if (bucket < 0) bucket = 0;
        if (bucket >= NATIVE_SDK_AUDIO_SPECTRUM_BANDS) bucket = NATIVE_SDK_AUDIO_SPECTRUM_BANDS - 1;
        const GValue *value = api->value_list_get_value(magnitudes, i);
        if (!value) continue;
        const float magnitude = g_value_get_float(value);
        if (!filled[bucket] || magnitude > peak_db[bucket]) {
            peak_db[bucket] = magnitude;
            filled[bucket] = 1;
        }
    }
    for (int k = 0; k < NATIVE_SDK_AUDIO_SPECTRUM_BANDS; k++) {
        if (filled[k]) continue;
        /* No bin center landed in this bucket (it is narrower than one
         * linear bin): read the bin covering the bucket's geometric
         * center instead. */
        const float lo = NATIVE_SDK_AUDIO_SPECTRUM_MIN_HZ * expf(span * (float)k / (float)NATIVE_SDK_AUDIO_SPECTRUM_BANDS);
        const float hi = NATIVE_SDK_AUDIO_SPECTRUM_MIN_HZ * expf(span * (float)(k + 1) / (float)NATIVE_SDK_AUDIO_SPECTRUM_BANDS);
        const unsigned bin = (unsigned)(sqrtf(lo * hi) / bin_hz);
        if (bin >= bins) continue;
        const GValue *value = api->value_list_get_value(magnitudes, bin);
        if (value) peak_db[k] = g_value_get_float(value);
    }

    uint8_t bands[NATIVE_SDK_AUDIO_SPECTRUM_BANDS];
    for (int k = 0; k < NATIVE_SDK_AUDIO_SPECTRUM_BANDS; k++) {
        float magnitude = peak_db[k];
        if (magnitude < NATIVE_SDK_AUDIO_SPECTRUM_FLOOR_DB) magnitude = NATIVE_SDK_AUDIO_SPECTRUM_FLOOR_DB;
        if (magnitude > 0.0f) magnitude = 0.0f;
        bands[k] = (uint8_t)((magnitude - NATIVE_SDK_AUDIO_SPECTRUM_FLOOR_DB) * (255.0f / -NATIVE_SDK_AUDIO_SPECTRUM_FLOOR_DB) + 0.5f);
    }
    native_sdk_audio_emit_spectrum(host, bands);
}

/* Stream buffering reports. Below 100% the queue is refilling: hold the
 * pipeline paused internally (transport intent unchanged — the events
 * keep saying playing+buffering, the honest stall shape) until the
 * 100% report resumes it. */
static void native_sdk_audio_on_buffering(void *bus, void *message, gpointer data) {
    (void)bus;
    native_sdk_gtk_host_t *host = data;
    native_sdk_gtk_audio_t *audio = &host->audio;
    native_sdk_gst_api_t *gst = native_sdk_load_gst_api();
    if (!gst || !audio->active || !audio->playbin) return;
    int percent = 0;
    gst->message_parse_buffering(message, &percent);
    if (percent < 100) {
        audio->refilling = 1;
        if (!audio->buffering) {
            audio->buffering = 1;
            native_sdk_audio_emit_event(host, NATIVE_SDK_AUDIO_EVENT_POSITION);
        }
        if (audio->playing && audio->ready) gst->element_set_state(audio->playbin, NATIVE_SDK_GST_STATE_PAUSED);
    } else {
        audio->refilling = 0;
        if (audio->playing && audio->ready) {
            /* The flag normally drops at the PLAYING state-changed
             * message. But when the refill resolved before the earlier
             * PAUSED request ever completed, the pipeline never left
             * PLAYING, this set_state is a no-op, and no transition
             * message will ever fire — the flag would ride every
             * position tick for the rest of the track. GStreamer
             * reports exactly that case through the set_state result:
             * anything other than ASYNC means no transition is in
             * flight (the pipeline is at the target state now, or the
             * error path owns it), so no message is coming and the
             * flag drops here. ASYNC means a real transition is
             * rolling and the state-changed handler keeps ownership of
             * the drop, emitted the moment PLAYING is actually
             * reached. */
            const int change = gst->element_set_state(audio->playbin, NATIVE_SDK_GST_STATE_PLAYING);
            if (change != NATIVE_SDK_GST_STATE_CHANGE_ASYNC &&
                change != NATIVE_SDK_GST_STATE_CHANGE_FAILURE &&
                audio->buffering) {
                audio->buffering = 0;
                native_sdk_audio_emit_event(host, NATIVE_SDK_AUDIO_EVENT_POSITION);
            }
        } else if (audio->buffering && !audio->playing) {
            audio->buffering = 0;
            native_sdk_audio_emit_event(host, NATIVE_SDK_AUDIO_EVENT_POSITION);
        }
    }
}

/* Natural end of the track. Retire-before-emit discipline (mirroring
 * the other hosts): the completion Msg routinely starts the NEXT track
 * from inside its own dispatch, and tearing down afterwards would
 * destroy the player that load just installed. The duration is captured
 * first so the event carries the honest terminal position. The cache
 * download is orphaned, not cancelled — completion is what earned the
 * cache entry. */
static void native_sdk_audio_on_eos(void *bus, void *message, gpointer data) {
    (void)bus;
    (void)message;
    native_sdk_gtk_host_t *host = data;
    if (!host->audio.active) return;
    const uint64_t duration_ms = host->audio.duration_ms;
    native_sdk_audio_release(host, 0);
    native_sdk_audio_emit_report(host, NATIVE_SDK_AUDIO_EVENT_COMPLETED, duration_ms, duration_ms, 0, 0);
}

/* A load that never became playable or a pipeline that died mid-flight:
 * one FAILED report, player retired first. The cache download dies too
 * — bytes from a failing source are not trustworthy — and a verified
 * cache entry that failed to play is corrupt: deleted here so it never
 * fools the next lookup (that play streams and refills). */
static void native_sdk_audio_on_error(void *bus, void *message, gpointer data) {
    (void)bus;
    (void)message;
    native_sdk_gtk_host_t *host = data;
    if (!host->audio.active) return;
    if (host->audio.cache_entry_path) g_remove(host->audio.cache_entry_path);
    native_sdk_audio_release(host, 1);
    native_sdk_audio_emit_report(host, NATIVE_SDK_AUDIO_EVENT_FAILED, 0, 0, 0, 0);
}

/* Build one playbin around a URI, arm the bus watch, and start the
 * asynchronous preroll (LOADED follows at async-done). */
static int native_sdk_audio_attach(native_sdk_gtk_host_t *host, const char *uri, int streaming) {
    native_sdk_gst_api_t *gst = native_sdk_load_gst_api();
    if (!gst) return 0;
    native_sdk_gtk_audio_t *audio = &host->audio;
    void *playbin = gst->element_factory_make("playbin", "native-sdk-audio");
    if (!playbin) return 0;
    unsigned int flags = NATIVE_SDK_GST_PLAY_FLAG_AUDIO | NATIVE_SDK_GST_PLAY_FLAG_SOFT_VOLUME;
    if (streaming) flags |= NATIVE_SDK_GST_PLAY_FLAG_BUFFERING;
    g_object_set(playbin, "uri", uri, "flags", flags, "volume", audio->volume, NULL);
    /* Spectrum analysis, strictly additive: a `spectrum` element
     * (gst-plugins-good) installed as the playbin's audio-filter, so
     * the analyzer sees exactly the samples this app plays — never a
     * capture of the system mix. Built only when the spectrum-only
     * symbol slice AND the element factory resolve; on any miss the
     * playbin plays exactly as before and SPECTRUM reports simply
     * never flow. Configured for the shared contract: a higher LINEAR
     * bin count for the log fold, one message per 40 ms, the -60 dB
     * analysis floor, magnitudes only (phase is never read). */
    if (native_sdk_load_gst_spectrum_api()) {
        void *analyzer = gst->element_factory_make("spectrum", "native-sdk-audio-spectrum");
        if (analyzer) {
            /* A fresh element is floating; sinking one ref here keeps
             * the analyzer alive for rate queries until release even
             * if the playbin drops its own. */
            g_object_ref_sink(analyzer);
            g_object_set(analyzer,
                "bands", (guint)NATIVE_SDK_AUDIO_SPECTRUM_SOURCE_BANDS,
                "interval", NATIVE_SDK_AUDIO_SPECTRUM_INTERVAL_NS,
                "threshold", (gint)NATIVE_SDK_AUDIO_SPECTRUM_FLOOR_DB,
                "post-messages", (gboolean)TRUE,
                "message-magnitude", (gboolean)TRUE,
                "message-phase", (gboolean)FALSE,
                NULL);
            g_object_set(playbin, "audio-filter", analyzer, NULL);
            audio->spectrum = analyzer;
        }
    }
    void *bus = gst->element_get_bus(playbin);
    if (!bus) {
        g_object_unref(playbin);
        return 0;
    }
    gst->bus_add_signal_watch(bus);
    audio->bus_handlers[0] = g_signal_connect(bus, "message::eos", G_CALLBACK(native_sdk_audio_on_eos), host);
    audio->bus_handlers[1] = g_signal_connect(bus, "message::error", G_CALLBACK(native_sdk_audio_on_error), host);
    audio->bus_handlers[2] = g_signal_connect(bus, "message::buffering", G_CALLBACK(native_sdk_audio_on_buffering), host);
    audio->bus_handlers[3] = g_signal_connect(bus, "message::async-done", G_CALLBACK(native_sdk_audio_on_async_done), host);
    audio->bus_handlers[4] = g_signal_connect(bus, "message::state-changed", G_CALLBACK(native_sdk_audio_on_state_changed), host);
    if (audio->spectrum) audio->bus_handlers[5] = g_signal_connect(bus, "message::element", G_CALLBACK(native_sdk_audio_on_element), host);
    audio->playbin = playbin;
    audio->bus = bus;
    if (gst->element_set_state(playbin, NATIVE_SDK_GST_STATE_PAUSED) == NATIVE_SDK_GST_STATE_CHANGE_FAILURE) {
        native_sdk_audio_release(host, 0);
        return 0;
    }
    return 1;
}

/* Synchronous local-file load: 0 loading (the asynchronous LOADED
 * acknowledgment follows at preroll), 1 missing file, 2 unusable, 3 no
 * backend — the shared result contract, with the runtime-dependency
 * value on top. An undecodable-but-present file surfaces as one
 * asynchronous FAILED report (resolution here is asynchronous by
 * design). */
static int native_sdk_audio_load_path_internal(native_sdk_gtk_host_t *host, const char *path) {
    native_sdk_audio_release(host, 1);
    if (!native_sdk_load_gst_api()) return 3;
    if (!g_file_test(path, G_FILE_TEST_IS_REGULAR)) return 1;
    char *absolute = g_canonicalize_filename(path, NULL);
    char *uri = g_filename_to_uri(absolute ? absolute : path, NULL, NULL);
    g_free(absolute);
    if (!uri) return 2;
    const int attached = native_sdk_audio_attach(host, uri, 0);
    g_free(uri);
    if (!attached) {
        native_sdk_audio_release(host, 0);
        return 2;
    }
    host->audio.active = 1;
    return 0;
}

/* URL sources: verified cache entry first (plays as a plain local file,
 * no network), then a progressive stream with a parallel cache-filling
 * download. Returns 1 for the cache hit, 0 for a started stream, 2 when
 * the URL cannot be used, 3 without the backend; everything
 * asynchronous — readiness, stalls, natural end, network death —
 * arrives as audio reports. */
static int native_sdk_audio_load_url_internal(native_sdk_gtk_host_t *host, const char *url, const char *cache_path, uint64_t expected_bytes) {
    native_sdk_audio_release(host, 1);
    if (!native_sdk_load_gst_api()) return 3;
    if (!strstr(url, "://")) return 2;
    if (cache_path && cache_path[0]) {
        GStatBuf stat_buf;
        if (g_stat(cache_path, &stat_buf) == 0) {
            if (expected_bytes == 0 || (uint64_t)stat_buf.st_size == expected_bytes) {
                if (native_sdk_audio_load_path_internal(host, cache_path) == 0) {
                    host->audio.cache_entry_path = native_sdk_strndup(cache_path, strlen(cache_path));
                    return 1;
                }
            }
            /* Partial or stale: a bad cache entry never plays, and
             * never survives to fool the next lookup. */
            g_remove(cache_path);
        }
    }
    if (!native_sdk_audio_attach(host, url, 1)) {
        native_sdk_audio_release(host, 0);
        return 2;
    }
    host->audio.active = 1;
    host->audio.url_source = 1;
    /* A fresh stream has no bytes yet: buffering starts true and drops
     * when the pipeline actually starts rolling. */
    host->audio.buffering = 1;
    if (cache_path && cache_path[0]) {
        native_sdk_audio_download_t *job = calloc(1, sizeof(*job));
        if (job) {
            job->url = native_sdk_strndup(url, strlen(url));
            job->cache_path = native_sdk_strndup(cache_path, strlen(cache_path));
            job->expected_bytes = expected_bytes;
            if (job->url && job->cache_path) {
                host->audio.download_cancel = g_cancellable_new();
                job->cancel = g_object_ref(host->audio.download_cancel);
                GThread *thread = g_thread_new("native-sdk-audio-cache", native_sdk_audio_download_thread, job);
                g_thread_unref(thread); /* detached: the job owns its state */
            } else {
                free(job->url);
                free(job->cache_path);
                free(job);
            }
        }
    }
    return 0;
}

/* Audio entry points. All loop-thread only, like every other service
 * call: the runtime dispatches them from inside the main loop's event
 * callback. */

int native_sdk_gtk_audio_available(native_sdk_gtk_host_t *host) {
    (void)host;
    return native_sdk_load_gst_api() ? 1 : 0;
}

/* Spectrum analysis is a separate capability from playback: the
 * `spectrum` element ships in gst-plugins-good, packaged apart from
 * the playbin set, so a host can play audio yet honestly lack the
 * analyzer. Probed against the actual runtime variables — the core
 * library, the spectrum-only symbol slice, and the element factory —
 * exactly like the playbin probe in the loader above. */
int native_sdk_gtk_audio_spectrum_available(native_sdk_gtk_host_t *host) {
    (void)host;
    native_sdk_gst_api_t *gst = native_sdk_load_gst_api();
    if (!gst || !native_sdk_load_gst_spectrum_api()) return 0;
    void *spectrum_factory = gst->element_factory_find("spectrum");
    if (!spectrum_factory) return 0;
    g_object_unref(spectrum_factory);
    return 1;
}

int native_sdk_gtk_audio_load(native_sdk_gtk_host_t *host, const char *path, size_t path_len) {
    if (!host || !path || path_len == 0) return 2;
    char *copy = native_sdk_strndup(path, path_len);
    if (!copy) return 2;
    const int result = native_sdk_audio_load_path_internal(host, copy);
    free(copy);
    return result;
}

int native_sdk_gtk_audio_load_url(native_sdk_gtk_host_t *host, const char *url, size_t url_len, const char *cache_path, size_t cache_path_len, uint64_t expected_bytes) {
    if (!host || !url || url_len == 0) return 2;
    char *url_copy = native_sdk_strndup(url, url_len);
    char *cache_copy = cache_path_len > 0 ? native_sdk_strndup(cache_path, cache_path_len) : NULL;
    if (!url_copy) {
        free(cache_copy);
        return 2;
    }
    const int result = native_sdk_audio_load_url_internal(host, url_copy, cache_copy ? cache_copy : "", expected_bytes);
    free(url_copy);
    free(cache_copy);
    return result;
}

int native_sdk_gtk_audio_play(native_sdk_gtk_host_t *host) {
    if (!host || !host->audio.active) return 0;
    native_sdk_gtk_audio_t *audio = &host->audio;
    native_sdk_gst_api_t *gst = native_sdk_load_gst_api();
    audio->playing = 1;
    if (audio->ready) {
        /* Mid-refill the intent is recorded and the 100% buffering
         * report flips the pipeline to PLAYING. */
        if (!audio->refilling && gst && audio->playbin) gst->element_set_state(audio->playbin, NATIVE_SDK_GST_STATE_PLAYING);
    } else {
        /* Applied at preroll; readiness and stalls report through the
         * event stream, so play always "applies" — the same
         * asynchronous-by-nature contract as the other hosts. */
        audio->pending_play = 1;
    }
    native_sdk_audio_start_position_timer(host);
    return 1;
}

int native_sdk_gtk_audio_pause(native_sdk_gtk_host_t *host) {
    if (!host || !host->audio.active) return 0;
    native_sdk_gtk_audio_t *audio = &host->audio;
    native_sdk_gst_api_t *gst = native_sdk_load_gst_api();
    audio->playing = 0;
    audio->pending_play = 0;
    if (audio->ready && gst && audio->playbin) gst->element_set_state(audio->playbin, NATIVE_SDK_GST_STATE_PAUSED);
    native_sdk_audio_stop_position_timer(host);
    return 1;
}

int native_sdk_gtk_audio_stop(native_sdk_gtk_host_t *host) {
    if (!host) return 0;
    const int had_player = host->audio.active ? 1 : 0;
    /* Replacement or explicit stop: the cache download dies with the
     * playback (its next play streams and fills again). */
    native_sdk_audio_release(host, 1);
    return had_player;
}

int native_sdk_gtk_audio_seek(native_sdk_gtk_host_t *host, uint64_t position_ms) {
    if (!host || !host->audio.active) return 0;
    native_sdk_gtk_audio_t *audio = &host->audio;
    native_sdk_gst_api_t *gst = native_sdk_load_gst_api();
    if (audio->duration_ms > 0 && position_ms > audio->duration_ms) position_ms = audio->duration_ms;
    if (audio->ready && gst && audio->playbin) {
        /* A flushing seek repositions a paused transport in place —
         * the scrub lands paused at the new position. */
        gst->element_seek_simple(audio->playbin, NATIVE_SDK_GST_FORMAT_TIME, NATIVE_SDK_GST_SEEK_FLAG_FLUSH | NATIVE_SDK_GST_SEEK_FLAG_ACCURATE, (int64_t)position_ms * 1000000);
    } else {
        audio->has_pending_seek = 1;
        audio->pending_seek_ms = position_ms;
    }
    return 1;
}

int native_sdk_gtk_audio_set_volume(native_sdk_gtk_host_t *host, double volume) {
    if (!host || !host->audio.active) return 0;
    host->audio.volume = volume;
    /* Pipeline-local software volume (the SOFT_VOLUME flag above) — the
     * system mixer entry is never mutated. */
    if (host->audio.playbin) g_object_set(host->audio.playbin, "volume", volume, NULL);
    return 1;
}

typedef struct native_sdk_clipboard_read_state {
    GMainLoop *loop;
    char *text;
} native_sdk_clipboard_read_state_t;

typedef struct native_sdk_clipboard_data_read_state {
    GMainLoop *loop;
    GBytes *bytes;
} native_sdk_clipboard_data_read_state_t;

static gboolean native_sdk_clipboard_is_plain_text(const char *mime_type, size_t mime_type_len) {
    return (mime_type_len == 4 && g_ascii_strncasecmp(mime_type, "text", 4) == 0) ||
        (mime_type_len == 10 && g_ascii_strncasecmp(mime_type, "text/plain", 10) == 0);
}

static size_t native_sdk_copy_bytes(char *buffer, size_t buffer_len, const void *bytes, size_t bytes_len) {
    if (!buffer || buffer_len == 0 || !bytes) return 0;
    size_t count = bytes_len < buffer_len ? bytes_len : buffer_len;
    if (count > 0) memcpy(buffer, bytes, count);
    return bytes_len;
}

static void native_sdk_clipboard_read_done(GObject *source, GAsyncResult *result, gpointer data) {
    native_sdk_clipboard_read_state_t *state = data;
    GError *error = NULL;
    state->text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(source), result, &error);
    if (error) g_error_free(error);
    g_main_loop_quit(state->loop);
}

static void native_sdk_clipboard_data_read_done(GObject *source, GAsyncResult *result, gpointer data) {
    native_sdk_clipboard_data_read_state_t *state = data;
    GError *error = NULL;
    const char *out_mime_type = NULL;
    GInputStream *stream = gdk_clipboard_read_finish(GDK_CLIPBOARD(source), result, &out_mime_type, &error);
    (void)out_mime_type;
    if (stream) {
        GByteArray *array = g_byte_array_new();
        char chunk[4096];
        while (!error) {
            gssize count = g_input_stream_read(stream, chunk, sizeof(chunk), NULL, &error);
            if (count <= 0) break;
            g_byte_array_append(array, (const guint8 *)chunk, (guint)count);
        }
        if (!error) {
            state->bytes = g_byte_array_free_to_bytes(array);
        } else {
            g_byte_array_unref(array);
        }
        g_object_unref(stream);
    }
    if (error) g_error_free(error);
    g_main_loop_quit(state->loop);
}

size_t native_sdk_gtk_clipboard_read(native_sdk_gtk_host_t *host, char *buffer, size_t buffer_len) {
    return native_sdk_gtk_clipboard_read_data(host, "text/plain", strlen("text/plain"), buffer, buffer_len);
}

void native_sdk_gtk_clipboard_write(native_sdk_gtk_host_t *host, const char *text, size_t text_len) {
    (void)native_sdk_gtk_clipboard_write_data(host, "text/plain", strlen("text/plain"), text, text_len);
}

size_t native_sdk_gtk_clipboard_read_data(native_sdk_gtk_host_t *host, const char *mime_type, size_t mime_type_len, char *buffer, size_t buffer_len) {
    (void)host;
    if (!mime_type || mime_type_len == 0 || !buffer || buffer_len == 0) return 0;
    GdkDisplay *display = gdk_display_get_default();
    if (!display) return 0;
    GdkClipboard *clipboard = gdk_display_get_clipboard(display);
    if (!clipboard) return 0;
    if (!native_sdk_clipboard_is_plain_text(mime_type, mime_type_len)) {
        char *mime = native_sdk_strndup(mime_type, mime_type_len);
        if (!mime) return 0;
        const char *mime_types[] = { mime, NULL };
        native_sdk_clipboard_data_read_state_t data_state = {0};
        data_state.loop = g_main_loop_new(NULL, FALSE);
        if (!data_state.loop) {
            free(mime);
            return 0;
        }
        gdk_clipboard_read_async(clipboard, mime_types, G_PRIORITY_DEFAULT, NULL, native_sdk_clipboard_data_read_done, &data_state);
        g_main_loop_run(data_state.loop);
        g_main_loop_unref(data_state.loop);
        free(mime);
        if (!data_state.bytes) return 0;
        gsize len = 0;
        const void *data = g_bytes_get_data(data_state.bytes, &len);
        size_t count = native_sdk_copy_bytes(buffer, buffer_len, data, len);
        g_bytes_unref(data_state.bytes);
        return count;
    }

    native_sdk_clipboard_read_state_t state = {0};
    state.loop = g_main_loop_new(NULL, FALSE);
    if (!state.loop) return 0;
    gdk_clipboard_read_text_async(clipboard, NULL, native_sdk_clipboard_read_done, &state);
    g_main_loop_run(state.loop);
    g_main_loop_unref(state.loop);
    if (!state.text) return 0;
    size_t len = strlen(state.text);
    size_t count = native_sdk_copy_bytes(buffer, buffer_len, state.text, len);
    g_free(state.text);
    return count;
}

int native_sdk_gtk_clipboard_write_data(native_sdk_gtk_host_t *host, const char *mime_type, size_t mime_type_len, const char *bytes, size_t bytes_len) {
    (void)host;
    if (!mime_type || mime_type_len == 0 || (!bytes && bytes_len > 0)) return 0;
    GdkDisplay *display = gdk_display_get_default();
    if (!display) return 0;
    GdkClipboard *clipboard = gdk_display_get_clipboard(display);
    if (!clipboard) return 0;
    if (native_sdk_clipboard_is_plain_text(mime_type, mime_type_len)) {
        char *copy = native_sdk_strndup(bytes, bytes_len);
        if (!copy) return 0;
        gdk_clipboard_set_text(clipboard, copy);
        free(copy);
        return 1;
    }
    char *mime = native_sdk_strndup(mime_type, mime_type_len);
    if (!mime) {
        return 0;
    }
    GBytes *data = g_bytes_new(bytes, bytes_len);
    GdkContentProvider *provider = gdk_content_provider_new_for_bytes(mime, data);
    gboolean ok = provider ? gdk_clipboard_set_content(clipboard, provider) : FALSE;
    if (provider) g_object_unref(provider);
    g_bytes_unref(data);
    free(mime);
    return ok ? 1 : 0;
}

typedef struct native_sdk_file_dialog_state {
    GMainLoop *loop;
    GListModel *files;
    GFile *file;
} native_sdk_file_dialog_state_t;

static GtkWindow *native_sdk_parent_window(native_sdk_gtk_host_t *host) {
    for (int i = 0; i < host->window_count; i++) {
        if (host->windows[i].gtk_window) return host->windows[i].gtk_window;
    }
    return NULL;
}

static char *native_sdk_bytes_to_string(const char *bytes, size_t len) {
    return bytes && len > 0 ? native_sdk_strndup(bytes, len) : NULL;
}

static void native_sdk_open_dialog_done(GObject *source, GAsyncResult *result, gpointer data) {
    native_sdk_file_dialog_state_t *state = data;
    GError *error = NULL;
    state->files = gtk_file_dialog_open_multiple_finish(GTK_FILE_DIALOG(source), result, &error);
    if (error) g_error_free(error);
    g_main_loop_quit(state->loop);
}

static void native_sdk_folder_dialog_done(GObject *source, GAsyncResult *result, gpointer data) {
    native_sdk_file_dialog_state_t *state = data;
    GError *error = NULL;
    state->files = gtk_file_dialog_select_multiple_folders_finish(GTK_FILE_DIALOG(source), result, &error);
    if (error) g_error_free(error);
    g_main_loop_quit(state->loop);
}

static void native_sdk_save_dialog_done(GObject *source, GAsyncResult *result, gpointer data) {
    native_sdk_file_dialog_state_t *state = data;
    GError *error = NULL;
    state->file = gtk_file_dialog_save_finish(GTK_FILE_DIALOG(source), result, &error);
    if (error) g_error_free(error);
    g_main_loop_quit(state->loop);
}

native_sdk_gtk_open_dialog_result_t native_sdk_gtk_show_open_dialog(native_sdk_gtk_host_t *host, const native_sdk_gtk_open_dialog_opts_t *opts, char *buffer, size_t buffer_len) {
    native_sdk_gtk_open_dialog_result_t result = {0};
    GtkFileDialog *dialog = gtk_file_dialog_new();
    char *title = native_sdk_bytes_to_string(opts->title, opts->title_len);
    if (title) gtk_file_dialog_set_title(dialog, title);
    GtkWindow *parent = native_sdk_parent_window(host);
    native_sdk_file_dialog_state_t state = { .loop = g_main_loop_new(NULL, FALSE) };
    if (!state.loop) {
        if (title) free(title);
        g_object_unref(dialog);
        return result;
    }
    if (opts->allow_directories) {
        gtk_file_dialog_select_multiple_folders(dialog, parent, NULL, native_sdk_folder_dialog_done, &state);
    } else {
        gtk_file_dialog_open_multiple(dialog, parent, NULL, native_sdk_open_dialog_done, &state);
    }
    g_main_loop_run(state.loop);
    g_main_loop_unref(state.loop);
    if (state.files) {
        size_t offset = 0;
        int overflow = 0;
        guint count = g_list_model_get_n_items(state.files);
        for (guint i = 0; i < count; i++) {
            GFile *file = G_FILE(g_list_model_get_item(state.files, i));
            char *path = g_file_get_path(file);
            if (path) {
                size_t len = strlen(path);
                size_t needed = len + (result.count > 0 ? 1 : 0);
                if (needed <= buffer_len - offset) {
                    if (result.count > 0) buffer[offset++] = '\n';
                    memcpy(buffer + offset, path, len);
                    offset += len;
                    result.count++;
                } else {
                    overflow = 1;
                }
                g_free(path);
            }
            g_object_unref(file);
            if (overflow) break;
        }
        result.bytes_written = overflow ? native_sdk_overflow_size(buffer_len) : offset;
        g_object_unref(state.files);
    }
    if (title) free(title);
    g_object_unref(dialog);
    return result;
}

size_t native_sdk_gtk_show_save_dialog(native_sdk_gtk_host_t *host, const native_sdk_gtk_save_dialog_opts_t *opts, char *buffer, size_t buffer_len) {
    GtkFileDialog *dialog = gtk_file_dialog_new();
    char *title = native_sdk_bytes_to_string(opts->title, opts->title_len);
    char *default_name = native_sdk_bytes_to_string(opts->default_name, opts->default_name_len);
    if (title) gtk_file_dialog_set_title(dialog, title);
    if (default_name) gtk_file_dialog_set_initial_name(dialog, default_name);
    GtkWindow *parent = native_sdk_parent_window(host);
    native_sdk_file_dialog_state_t state = { .loop = g_main_loop_new(NULL, FALSE) };
    if (!state.loop) {
        if (title) free(title);
        if (default_name) free(default_name);
        g_object_unref(dialog);
        return 0;
    }
    gtk_file_dialog_save(dialog, parent, NULL, native_sdk_save_dialog_done, &state);
    g_main_loop_run(state.loop);
    g_main_loop_unref(state.loop);
    size_t written = 0;
    if (state.file) {
        char *path = g_file_get_path(state.file);
        if (path) {
            size_t len = strlen(path);
            if (len > buffer_len) {
                written = native_sdk_overflow_size(buffer_len);
            } else {
                written = len;
                memcpy(buffer, path, written);
            }
            g_free(path);
        }
        g_object_unref(state.file);
    }
    if (title) free(title);
    if (default_name) free(default_name);
    g_object_unref(dialog);
    return written;
}

typedef struct native_sdk_alert_state {
    GMainLoop *loop;
    int response;
} native_sdk_alert_state_t;

static void native_sdk_alert_done(GObject *source, GAsyncResult *result, gpointer data) {
    native_sdk_alert_state_t *state = data;
    GError *error = NULL;
    state->response = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(source), result, &error);
    if (error) {
        g_error_free(error);
        state->response = 0;
    }
    g_main_loop_quit(state->loop);
}

int native_sdk_gtk_show_message_dialog(native_sdk_gtk_host_t *host, const native_sdk_gtk_message_dialog_opts_t *opts) {
    GtkAlertDialog *dialog = gtk_alert_dialog_new(NULL);
    char *title = native_sdk_bytes_to_string(opts->title, opts->title_len);
    char *message = native_sdk_bytes_to_string(opts->message, opts->message_len);
    char *informative = native_sdk_bytes_to_string(opts->informative_text, opts->informative_text_len);
    char *primary = native_sdk_bytes_to_string(opts->primary_button, opts->primary_button_len);
    char *secondary = native_sdk_bytes_to_string(opts->secondary_button, opts->secondary_button_len);
    char *tertiary = native_sdk_bytes_to_string(opts->tertiary_button, opts->tertiary_button_len);
    gtk_alert_dialog_set_message(dialog, title ? title : (message ? message : ""));
    if (informative || (title && message)) gtk_alert_dialog_set_detail(dialog, informative ? informative : message);
    const char *buttons[4] = { primary ? primary : "OK", NULL, NULL, NULL };
    if (secondary) buttons[1] = secondary;
    if (tertiary) buttons[2] = tertiary;
    gtk_alert_dialog_set_buttons(dialog, buttons);
    native_sdk_alert_state_t state = { .loop = g_main_loop_new(NULL, FALSE), .response = 0 };
    if (state.loop) {
        gtk_alert_dialog_choose(dialog, native_sdk_parent_window(host), NULL, native_sdk_alert_done, &state);
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
