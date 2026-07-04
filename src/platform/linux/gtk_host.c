#include "gtk_host.h"

#include <gtk/gtk.h>
#include <webkit/webkit.h>
#include <glib/gstdio.h>
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#define ZERO_NATIVE_MAX_WINDOWS 16
#define ZERO_NATIVE_MAX_WEBVIEWS 16
#define ZERO_NATIVE_MAX_NATIVE_VIEWS 32
#define ZERO_NATIVE_MAX_SHORTCUTS 64
#define ZERO_NATIVE_MAX_MENU_ITEMS 128

#define ZERO_NATIVE_SHORTCUT_MODIFIER_PRIMARY (1u << 0)
#define ZERO_NATIVE_SHORTCUT_MODIFIER_COMMAND (1u << 1)
#define ZERO_NATIVE_SHORTCUT_MODIFIER_CONTROL (1u << 2)
#define ZERO_NATIVE_SHORTCUT_MODIFIER_OPTION  (1u << 3)
#define ZERO_NATIVE_SHORTCUT_MODIFIER_SHIFT   (1u << 4)

static size_t zero_native_overflow_size(size_t buffer_len) {
    return buffer_len == SIZE_MAX ? SIZE_MAX : buffer_len + 1;
}

#define ZERO_NATIVE_GTK_VIEW_WEBVIEW 0
#define ZERO_NATIVE_GTK_VIEW_TOOLBAR 1
#define ZERO_NATIVE_GTK_VIEW_TITLEBAR_ACCESSORY 2
#define ZERO_NATIVE_GTK_VIEW_SIDEBAR 3
#define ZERO_NATIVE_GTK_VIEW_STATUSBAR 4
#define ZERO_NATIVE_GTK_VIEW_SPLIT 5
#define ZERO_NATIVE_GTK_VIEW_STACK 6
#define ZERO_NATIVE_GTK_VIEW_BUTTON 7
#define ZERO_NATIVE_GTK_VIEW_TEXT_FIELD 8
#define ZERO_NATIVE_GTK_VIEW_SEARCH_FIELD 9
#define ZERO_NATIVE_GTK_VIEW_LABEL 10
#define ZERO_NATIVE_GTK_VIEW_SPACER 11
#define ZERO_NATIVE_GTK_VIEW_GPU_SURFACE 12
#define ZERO_NATIVE_GTK_VIEW_CHECKBOX 13
#define ZERO_NATIVE_GTK_VIEW_TOGGLE 14
#define ZERO_NATIVE_GTK_VIEW_PROGRESS_INDICATOR 15
#define ZERO_NATIVE_GTK_VIEW_SEGMENTED_CONTROL 16
#define ZERO_NATIVE_GTK_VIEW_ICON_BUTTON 17
#define ZERO_NATIVE_GTK_VIEW_LIST_ITEM 18

typedef struct zero_native_gtk_shortcut {
    char *id;
    char *key;
    uint32_t modifiers;
} zero_native_gtk_shortcut_t;

typedef struct zero_native_gtk_menu_action {
    char *name;
    char *command;
    struct zero_native_gtk_host *host;
} zero_native_gtk_menu_action_t;

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

typedef struct zero_native_gtk_native_view {
    char *label;
    char *parent;
    char *role;
    char *accessibility_label;
    char *text;
    char *command;
    GtkWidget *widget;
    struct zero_native_gtk_window *window;
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
} zero_native_gtk_native_view_t;

typedef struct zero_native_gtk_window {
    uint64_t id;
    GtkWindow *gtk_window;
    WebKitWebView *web_view;
    GtkWidget *root_box;
    GtkWidget *menu_bar;
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
    zero_native_gtk_native_view_t native_views[ZERO_NATIVE_MAX_NATIVE_VIEWS];
    int native_view_count;
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
    int app_active;
    guint frame_timer;

    char **allowed_origins;
    int allowed_origins_count;
    char **allowed_external_urls;
    int allowed_external_urls_count;
    int external_link_action;
    int scheme_registered;
    zero_native_gtk_shortcut_t shortcuts[ZERO_NATIVE_MAX_SHORTCUTS];
    int shortcut_count;
    GMenuModel *menu_model;
    zero_native_gtk_menu_action_t menu_actions[ZERO_NATIVE_MAX_MENU_ITEMS];
    int menu_action_count;
};

static void zero_native_emit(zero_native_gtk_host_t *host, zero_native_gtk_event_t event);
static gboolean zero_native_on_file_drop(GtkDropTarget *target, const GValue *value, double x, double y, gpointer data);
static GtkWindow *zero_native_parent_window(zero_native_gtk_host_t *host);

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

static void zero_native_clear_menu_actions(zero_native_gtk_host_t *host) {
    if (!host) return;
    const char *empty_accels[] = { NULL };
    for (int i = 0; i < host->menu_action_count; i++) {
        zero_native_gtk_menu_action_t *action = &host->menu_actions[i];
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

static int zero_native_strings_equal(const char *a, const char *b) {
    return a && b && strcmp(a, b) == 0;
}

static int zero_native_window_uses_public_asset_origin(zero_native_gtk_host_t *host, zero_native_gtk_window_t *current, const char *origin) {
    if (!origin) return 0;
    for (int i = 0; i < host->window_count; i++) {
        zero_native_gtk_window_t *win = &host->windows[i];
        if (win == current || !win->asset_root || !win->bridge_origin) continue;
        if (strcmp(win->bridge_origin, origin) == 0) return 1;
    }
    return 0;
}

static char *zero_native_internal_asset_origin(uint64_t window_id) {
    char buffer[96];
    int len = snprintf(buffer, sizeof(buffer), "zero://zero-native-window-%llu", (unsigned long long)window_id);
    if (len <= 0 || (size_t)len >= sizeof(buffer)) return NULL;
    return zero_native_strndup(buffer, (size_t)len);
}

static int zero_native_window_allows_asset_origin(zero_native_gtk_window_t *win, const char *origin) {
    return zero_native_strings_equal(win->asset_origin, origin) || zero_native_strings_equal(win->bridge_origin, origin);
}

typedef WebKitWebView *(*zero_native_request_get_web_view_fn)(WebKitURISchemeRequest *request);

static zero_native_request_get_web_view_fn zero_native_request_get_web_view(void) {
    static int resolved = 0;
    static zero_native_request_get_web_view_fn get_web_view = NULL;
    if (!resolved) {
        get_web_view = (zero_native_request_get_web_view_fn)dlsym(RTLD_DEFAULT, "webkit_uri_scheme_request_get_web_view");
        resolved = 1;
    }
    return get_web_view;
}

static int zero_native_request_web_view_supported(void) {
    return zero_native_request_get_web_view() != NULL;
}

static WebKitWebView *zero_native_request_web_view(WebKitURISchemeRequest *request) {
    zero_native_request_get_web_view_fn get_web_view = zero_native_request_get_web_view();
    return get_web_view ? get_web_view(request) : NULL;
}

static zero_native_gtk_window_t *zero_native_window_for_web_view(zero_native_gtk_host_t *host, WebKitWebView *web_view) {
    if (!web_view) return NULL;
    for (int i = 0; i < host->window_count; i++) {
        zero_native_gtk_window_t *win = &host->windows[i];
        if (win->web_view == web_view) return win;
        for (int j = 0; j < win->webview_count; j++) {
            if (win->webviews[j].web_view == web_view) return win;
        }
    }
    return NULL;
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

static int zero_native_valid_native_view_frame(double x, double y, double width, double height) {
    return x >= 0 && y >= 0 && width >= 0 && height >= 0;
}

static int zero_native_native_extent(double value) {
    return value > 0 ? (int)(value + 0.5) : 0;
}

static int zero_native_native_coord(double value) {
    return value > 0 ? (int)(value + 0.5) : 0;
}

static int zero_native_is_native_container_kind(int kind) {
    return kind == ZERO_NATIVE_GTK_VIEW_TOOLBAR ||
        kind == ZERO_NATIVE_GTK_VIEW_TITLEBAR_ACCESSORY ||
        kind == ZERO_NATIVE_GTK_VIEW_SIDEBAR ||
        kind == ZERO_NATIVE_GTK_VIEW_STATUSBAR ||
        kind == ZERO_NATIVE_GTK_VIEW_SPLIT ||
        kind == ZERO_NATIVE_GTK_VIEW_STACK ||
        kind == ZERO_NATIVE_GTK_VIEW_SPACER;
}

static int zero_native_is_supported_native_view_kind(int kind) {
    return zero_native_is_native_container_kind(kind) ||
        kind == ZERO_NATIVE_GTK_VIEW_BUTTON ||
        kind == ZERO_NATIVE_GTK_VIEW_ICON_BUTTON ||
        kind == ZERO_NATIVE_GTK_VIEW_LIST_ITEM ||
        kind == ZERO_NATIVE_GTK_VIEW_CHECKBOX ||
        kind == ZERO_NATIVE_GTK_VIEW_TOGGLE ||
        kind == ZERO_NATIVE_GTK_VIEW_SEGMENTED_CONTROL ||
        kind == ZERO_NATIVE_GTK_VIEW_TEXT_FIELD ||
        kind == ZERO_NATIVE_GTK_VIEW_SEARCH_FIELD ||
        kind == ZERO_NATIVE_GTK_VIEW_LABEL ||
        kind == ZERO_NATIVE_GTK_VIEW_PROGRESS_INDICATOR;
}

static const char *zero_native_native_display_text(zero_native_gtk_native_view_t *view) {
    if (!view) return "";
    if (view->text && view->text[0]) return view->text;
    if (view->role && view->role[0]) return view->role;
    return view->label ? view->label : "";
}

static const char *zero_native_native_accessibility_label(zero_native_gtk_native_view_t *view) {
    if (!view) return "";
    if (view->accessibility_label && view->accessibility_label[0]) return view->accessibility_label;
    if (view->role && view->role[0]) return view->role;
    if (view->text && view->text[0]) return view->text;
    return view->label ? view->label : "";
}

static zero_native_gtk_native_view_t *zero_native_find_native_view(zero_native_gtk_window_t *win, const char *label) {
    if (!win || !label) return NULL;
    for (int i = 0; i < ZERO_NATIVE_MAX_NATIVE_VIEWS; i++) {
        if (win->native_views[i].label && strcmp(win->native_views[i].label, label) == 0) return &win->native_views[i];
    }
    return NULL;
}

static void zero_native_configure_segmented_widget(GtkWidget *box, const char *text) {
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

static GtkWidget *zero_native_make_native_widget(int kind, const char *label, const char *text) {
    const char *display_text = text && text[0] ? text : (label ? label : "");
    switch (kind) {
        case ZERO_NATIVE_GTK_VIEW_TOOLBAR:
        case ZERO_NATIVE_GTK_VIEW_TITLEBAR_ACCESSORY:
        case ZERO_NATIVE_GTK_VIEW_SIDEBAR:
        case ZERO_NATIVE_GTK_VIEW_STATUSBAR:
        case ZERO_NATIVE_GTK_VIEW_SPLIT:
        case ZERO_NATIVE_GTK_VIEW_STACK:
        case ZERO_NATIVE_GTK_VIEW_SPACER:
            return gtk_fixed_new();
        case ZERO_NATIVE_GTK_VIEW_BUTTON:
            return gtk_button_new_with_label(display_text[0] ? display_text : "Button");
        case ZERO_NATIVE_GTK_VIEW_ICON_BUTTON: {
            GtkWidget *button = gtk_button_new_with_label(display_text[0] ? display_text : "...");
            gtk_widget_add_css_class(button, "flat");
            gtk_widget_add_css_class(button, "circular");
            return button;
        }
        case ZERO_NATIVE_GTK_VIEW_LIST_ITEM: {
            GtkWidget *button = gtk_button_new_with_label(display_text[0] ? display_text : "Item");
            gtk_widget_add_css_class(button, "flat");
            gtk_widget_set_halign(button, GTK_ALIGN_FILL);
            GtkWidget *child = gtk_widget_get_first_child(button);
            if (GTK_IS_LABEL(child)) gtk_label_set_xalign(GTK_LABEL(child), 0.0f);
            return button;
        }
        case ZERO_NATIVE_GTK_VIEW_CHECKBOX:
            return gtk_check_button_new_with_label(display_text[0] ? display_text : "Checkbox");
        case ZERO_NATIVE_GTK_VIEW_TOGGLE:
            return gtk_toggle_button_new_with_label(display_text[0] ? display_text : "Toggle");
        case ZERO_NATIVE_GTK_VIEW_SEGMENTED_CONTROL: {
            GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
            gtk_widget_add_css_class(box, "linked");
            zero_native_configure_segmented_widget(box, display_text[0] ? display_text : "One|Two");
            return box;
        }
        case ZERO_NATIVE_GTK_VIEW_TEXT_FIELD: {
            GtkWidget *entry = gtk_entry_new();
            gtk_entry_set_placeholder_text(GTK_ENTRY(entry), display_text);
            return entry;
        }
        case ZERO_NATIVE_GTK_VIEW_SEARCH_FIELD: {
            GtkWidget *entry = gtk_entry_new();
            gtk_entry_set_placeholder_text(GTK_ENTRY(entry), display_text[0] ? display_text : "Search");
            return entry;
        }
        case ZERO_NATIVE_GTK_VIEW_LABEL: {
            GtkWidget *view = gtk_label_new(display_text);
            gtk_label_set_ellipsize(GTK_LABEL(view), PANGO_ELLIPSIZE_END);
            gtk_label_set_xalign(GTK_LABEL(view), 0.0f);
            return view;
        }
        case ZERO_NATIVE_GTK_VIEW_PROGRESS_INDICATOR: {
            GtkWidget *spinner = gtk_spinner_new();
            gtk_spinner_start(GTK_SPINNER(spinner));
            return spinner;
        }
        default:
            return NULL;
    }
}

static void zero_native_apply_native_view_frame(zero_native_gtk_native_view_t *view) {
    if (!view || !view->widget) return;
    GtkWidget *widget = view->widget;
    gtk_widget_set_halign(widget, GTK_ALIGN_START);
    gtk_widget_set_valign(widget, GTK_ALIGN_START);
    gtk_widget_set_size_request(widget, zero_native_native_extent(view->width), zero_native_native_extent(view->height));
    if (view->parent && view->parent[0]) {
        zero_native_gtk_native_view_t *parent = zero_native_find_native_view(view->window, view->parent);
        if (parent && parent->widget && GTK_IS_FIXED(parent->widget)) {
            gtk_fixed_move(GTK_FIXED(parent->widget), widget, view->x, view->y);
        }
        return;
    }
    gtk_widget_set_margin_start(widget, zero_native_native_coord(view->x));
    gtk_widget_set_margin_top(widget, zero_native_native_coord(view->y));
}

static void zero_native_apply_native_view_text(zero_native_gtk_native_view_t *view, const char *text) {
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
    } else if (GTK_IS_BOX(widget) && view->kind == ZERO_NATIVE_GTK_VIEW_SEGMENTED_CONTROL) {
        zero_native_configure_segmented_widget(widget, text);
    }
}

static void zero_native_apply_native_view_state(zero_native_gtk_native_view_t *view, int update_text, const char *text) {
    if (!view || !view->widget) return;
    gtk_widget_set_visible(view->widget, view->visible != 0);
    gtk_widget_set_sensitive(view->widget, view->enabled != 0);
    if (update_text) zero_native_apply_native_view_text(view, text);
    gtk_accessible_update_property(GTK_ACCESSIBLE(view->widget), GTK_ACCESSIBLE_PROPERTY_LABEL, zero_native_native_accessibility_label(view), -1);
}

static void zero_native_emit_native_action(GtkWidget *widget, gpointer data) {
    (void)widget;
    zero_native_gtk_native_view_t *view = data;
    if (!view || !view->window || !view->command || !view->command[0]) return;
    zero_native_emit(view->window->host, (zero_native_gtk_event_t){
        .kind = ZERO_NATIVE_GTK_EVENT_NATIVE_COMMAND,
        .window_id = view->window->id,
        .command_name = view->command,
        .command_name_len = strlen(view->command),
        .view_label = view->label ? view->label : "",
        .view_label_len = view->label ? strlen(view->label) : 0,
    });
}

static void zero_native_configure_native_view_action(zero_native_gtk_native_view_t *view) {
    if (!view || !view->widget) return;
    if (view->action_handler != 0) {
        g_signal_handler_disconnect(view->widget, view->action_handler);
        view->action_handler = 0;
    }
    if (GTK_IS_BOX(view->widget) && view->kind == ZERO_NATIVE_GTK_VIEW_SEGMENTED_CONTROL) {
        GtkWidget *child = gtk_widget_get_first_child(view->widget);
        while (child) {
            g_signal_handlers_disconnect_by_data(child, view);
            if (GTK_IS_BUTTON(child)) {
                if (view->command && view->command[0]) g_signal_connect(child, "clicked", G_CALLBACK(zero_native_emit_native_action), view);
            }
            child = gtk_widget_get_next_sibling(child);
        }
        return;
    }
    if (!view->command || !view->command[0]) return;
    if (GTK_IS_CHECK_BUTTON(view->widget)) {
        view->action_handler = g_signal_connect(view->widget, "toggled", G_CALLBACK(zero_native_emit_native_action), view);
    } else if (GTK_IS_BUTTON(view->widget)) {
        view->action_handler = g_signal_connect(view->widget, "clicked", G_CALLBACK(zero_native_emit_native_action), view);
    }
}

static void zero_native_reorder_overlays(zero_native_gtk_window_t *win) {
    if (!win || !win->stack_root) return;
    int placed[ZERO_NATIVE_MAX_WEBVIEWS] = {0};
    int native_placed[ZERO_NATIVE_MAX_NATIVE_VIEWS] = {0};
    GtkWidget *previous = NULL;
    int total = win->webview_count + win->native_view_count;
    for (int pass = 0; pass < total; pass++) {
        int best_webview = -1;
        int best_native = -1;
        for (int i = 0; i < win->webview_count; i++) {
            if (!win->webviews[i].web_view) continue;
            if (placed[i]) continue;
            if (best_webview < 0 || win->webviews[i].layer < win->webviews[best_webview].layer) best_webview = i;
        }
        for (int i = 0; i < ZERO_NATIVE_MAX_NATIVE_VIEWS; i++) {
            zero_native_gtk_native_view_t *view = &win->native_views[i];
            if (!view->widget || (view->parent && view->parent[0])) continue;
            if (native_placed[i]) continue;
            if (best_native < 0 || view->layer < win->native_views[best_native].layer) best_native = i;
        }

        GtkWidget *next = NULL;
        if (best_webview >= 0 && best_native >= 0) {
            if (win->webviews[best_webview].layer <= win->native_views[best_native].layer) {
                next = GTK_WIDGET(win->webviews[best_webview].web_view);
                placed[best_webview] = 1;
            } else {
                next = win->native_views[best_native].widget;
                native_placed[best_native] = 1;
            }
        } else if (best_webview >= 0) {
            next = GTK_WIDGET(win->webviews[best_webview].web_view);
            placed[best_webview] = 1;
        } else if (best_native >= 0) {
            next = win->native_views[best_native].widget;
            native_placed[best_native] = 1;
        } else {
            break;
        }

        gtk_widget_insert_after(next, GTK_WIDGET(win->stack_root), previous);
        previous = next;
    }
}

static void zero_native_clear_native_view(zero_native_gtk_window_t *win, zero_native_gtk_native_view_t *view);

static void zero_native_remove_native_children(zero_native_gtk_window_t *win, const char *parent_label) {
    if (!win || !parent_label) return;
    for (int i = 0; i < ZERO_NATIVE_MAX_NATIVE_VIEWS; i++) {
        zero_native_gtk_native_view_t *child = &win->native_views[i];
        if (!child->label || !child->parent || strcmp(child->parent, parent_label) != 0) continue;
        zero_native_clear_native_view(win, child);
    }
}

static void zero_native_clear_native_view(zero_native_gtk_window_t *win, zero_native_gtk_native_view_t *view) {
    if (!view || !view->label) return;
    char *label = zero_native_strndup(view->label, strlen(view->label));
    if (label) {
        zero_native_remove_native_children(win, label);
        free(label);
    }
    if (view->widget) {
        if (view->action_handler != 0) {
            g_signal_handler_disconnect(view->widget, view->action_handler);
            view->action_handler = 0;
        }
        if (view->parent && view->parent[0]) {
            zero_native_gtk_native_view_t *parent = zero_native_find_native_view(win, view->parent);
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
    memset(view, 0, sizeof(*view));
    if (win && win->native_view_count > 0) win->native_view_count--;
}

static void zero_native_clear_native_views(zero_native_gtk_window_t *win) {
    if (!win) return;
    for (int i = 0; i < ZERO_NATIVE_MAX_NATIVE_VIEWS; i++) {
        if (win->native_views[i].label) zero_native_clear_native_view(win, &win->native_views[i]);
    }
    win->native_view_count = 0;
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
    zero_native_clear_native_views(win);
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

static int zero_native_policy_wildcard_prefix_has_path(const char *prefix, size_t prefix_len) {
    if (!prefix || prefix_len == 0) return 0;
    const char *end = prefix + prefix_len;
    const char *scheme_end = strstr(prefix, "://");
    if (!scheme_end || scheme_end >= end) return 0;
    const char *host_start = scheme_end + 3;
    if (host_start >= end) return 0;
    const char *slash = memchr(host_start, '/', (size_t)(end - host_start));
    return slash && slash > host_start;
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
            size_t prefix_len = len - 1;
            matched = uri && zero_native_policy_wildcard_prefix_has_path(value, prefix_len) && strncmp(uri, value, prefix_len) == 0;
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
        "function viewSelectorPayload(options){if(typeof options==='string'){return {label:ensureString(options,'label')};}options=options||{};validateViewSelector(options);return {label:options.label,windowId:options.windowId};}"
        "function optionalFramePayload(options){var frame=options.frame||((options.x!=null||options.y!=null||options.width!=null||options.height!=null)?options:null);if(!frame){return null;}return {x:frame.x==null?0:ensureNumber(frame.x,'frame.x'),y:frame.y==null?0:ensureNumber(frame.y,'frame.y'),width:ensureNumber(frame.width,'frame.width'),height:ensureNumber(frame.height,'frame.height')};}"
        "function viewCreatePayload(options){options=options||{};validateViewSelector(options);ensureString(options.kind,'kind');var payload={label:options.label,kind:options.kind,windowId:options.windowId};var frame=optionalFramePayload(options);if(frame){payload.frame=frame;}if(options.parent!=null){payload.parent=ensureString(options.parent,'parent');}if(options.role!=null){payload.role=ensureText(options.role,'role');}if(options.accessibilityLabel!=null){payload.accessibilityLabel=ensureText(options.accessibilityLabel,'accessibilityLabel');}if(options.text!=null){payload.text=ensureText(options.text,'text');}if(options.command!=null){payload.command=ensureText(options.command,'command');}if(options.url!=null){payload.url=ensureString(options.url,'url');}if(options.layer!=null){payload.layer=ensureNumber(options.layer,'layer');}if(options.visible!=null){payload.visible=!!options.visible;}if(options.enabled!=null){payload.enabled=!!options.enabled;}if(options.transparent!=null){payload.transparent=!!options.transparent;}if(options.bridge!=null){payload.bridge=!!options.bridge;}return payload;}"
        "function viewPatchPayload(options){options=options||{};validateViewSelector(options);var payload={label:options.label,windowId:options.windowId};var frame=optionalFramePayload(options);if(frame){payload.frame=frame;}if(options.layer!=null){payload.layer=ensureNumber(options.layer,'layer');}if(options.visible!=null){payload.visible=!!options.visible;}if(options.enabled!=null){payload.enabled=!!options.enabled;}if(options.role!=null){payload.role=ensureText(options.role,'role');}if(options.accessibilityLabel!=null){payload.accessibilityLabel=ensureText(options.accessibilityLabel,'accessibilityLabel');}if(options.text!=null){payload.text=ensureText(options.text,'text');}if(options.command!=null){payload.command=ensureText(options.command,'command');}if(options.url!=null){payload.url=ensureString(options.url,'url');}return payload;}"
        "function viewFramePayload(options){options=options||{};validateViewSelector(options);var frame=options.frame||options;return {label:options.label,windowId:options.windowId,frame:{x:frame.x==null?0:ensureNumber(frame.x,'frame.x'),y:frame.y==null?0:ensureNumber(frame.y,'frame.y'),width:ensureNumber(frame.width,'frame.width'),height:ensureNumber(frame.height,'frame.height')}};}"
        "function viewVisiblePayload(options){options=options||{};validateViewSelector(options);if(options.visible==null){throw new TypeError('visible is required');}return {label:options.label,windowId:options.windowId,visible:!!options.visible};}"
        "function viewHandle(info){return Object.freeze(Object.assign({},info,{update:function(patch){return views.update(Object.assign({},patch||{},{label:info.label,windowId:info.windowId}));},setFrame:function(frame){return views.setFrame({label:info.label,windowId:info.windowId,frame:frame});},setVisible:function(visible){return views.setVisible({label:info.label,windowId:info.windowId,visible:visible});},focus:function(){return views.focus({label:info.label,windowId:info.windowId});},close:function(){return views.close({label:info.label,windowId:info.windowId});}}));}"
        "function on(name,callback){if(typeof callback!=='function'){throw new TypeError('callback must be a function');}var set=listeners.get(name);if(!set){set=new Set();listeners.set(name,set);}set.add(callback);return function(){off(name,callback);};}"
        "function off(name,callback){var set=listeners.get(name);if(set){set.delete(callback);if(set.size===0){listeners.delete(name);}}}"
        "function emit(name,detail){var set=listeners.get(name);if(set){Array.from(set).forEach(function(callback){callback(detail);});}window.dispatchEvent(new CustomEvent('zero-native:'+name,{detail:detail}));}"
        "var commands=Object.freeze({"
        "invoke:function(value){return invoke('zero-native.command.invoke',commandPayload(value));},"
        "list:function(){return invoke('zero-native.command.list',{});}"
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
        "function platformFeaturePayload(value){if(typeof value==='string'){return {feature:ensureString(value,'feature')};}value=value||{};return {feature:ensureString(value.feature!=null?value.feature:value.name,'feature')};}"
        "var platform=Object.freeze({"
        "supports:function(value){return invoke('zero-native.platform.supports',platformFeaturePayload(value));}"
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
        "update:function(options,patch){if(typeof options==='string'){return invoke('zero-native.view.update',viewPatchPayload(Object.assign({},patch||{},{label:options}))).then(viewHandle);}"
        "return invoke('zero-native.view.update',viewPatchPayload(options)).then(viewHandle);},"
        "setFrame:function(options){return invoke('zero-native.view.setFrame',viewFramePayload(options)).then(viewHandle);},"
        "setVisible:function(options){return invoke('zero-native.view.setVisible',viewVisiblePayload(options)).then(viewHandle);},"
        "focus:function(options){return invoke('zero-native.view.focus',viewSelectorPayload(options)).then(viewHandle);},"
        "focusNext:function(options){options=options||{};return invoke('zero-native.view.focusNext',{windowId:options.windowId}).then(viewHandle);},"
        "focusPrevious:function(options){options=options||{};return invoke('zero-native.view.focusPrevious',{windowId:options.windowId}).then(viewHandle);},"
        "close:function(options){return invoke('zero-native.view.close',viewSelectorPayload(options));}"
        "});"
        "Object.defineProperty(window,'zero',{value:Object.freeze({invoke:invoke,on:on,off:off,commands:commands,windows:windows,dialogs:dialogs,clipboard:clipboard,os:os,credentials:credentials,platform:platform,webviews:webviews,views:views,_complete:complete,_emit:emit}),configurable:false});"
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

static zero_native_gtk_window_t *zero_native_window_for_asset_uri(zero_native_gtk_host_t *host, const char *uri, WebKitWebView *request_web_view, int request_web_view_supported) {
    char *origin = zero_native_origin_for_uri(uri);
    if (!origin) return NULL;

    if (request_web_view_supported) {
        zero_native_gtk_window_t *win = zero_native_window_for_web_view(host, request_web_view);
        if (win && win->asset_root && zero_native_window_allows_asset_origin(win, origin)) {
            g_free(origin);
            return win;
        }
        g_free(origin);
        return NULL;
    }

    zero_native_gtk_window_t *public_match = NULL;
    int public_match_count = 0;
    for (int i = 0; i < host->window_count; i++) {
        zero_native_gtk_window_t *win = &host->windows[i];
        if (!win->asset_root) continue;
        if (zero_native_strings_equal(win->asset_origin, origin)) {
            g_free(origin);
            return win;
        }
        if (zero_native_strings_equal(win->bridge_origin, origin)) {
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

static char *zero_native_asset_relative_path(const char *uri, const char *entry) {
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
    int request_web_view_supported = zero_native_request_web_view_supported();
    WebKitWebView *request_web_view = request_web_view_supported ? zero_native_request_web_view(request) : NULL;
    zero_native_gtk_window_t *win = zero_native_window_for_asset_uri(host, uri, request_web_view, request_web_view_supported);
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

static void zero_native_append_file_path(GString *paths, GFile *file) {
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

static gboolean zero_native_emit_file_drop(zero_native_gtk_window_t *win, const char *paths, size_t paths_len) {
    if (!win || !win->host || !paths || paths_len == 0) return FALSE;
    zero_native_emit(win->host, (zero_native_gtk_event_t){
        .kind = ZERO_NATIVE_GTK_EVENT_FILES_DROPPED,
        .window_id = win->id,
        .drop_paths = paths,
        .drop_paths_len = paths_len,
    });
    return TRUE;
}

static gboolean zero_native_on_file_drop(GtkDropTarget *target, const GValue *value, double x, double y, gpointer data) {
    (void)target;
    (void)x;
    (void)y;
    zero_native_gtk_window_t *win = data;
    if (!win || !value) return FALSE;

    GString *paths = g_string_new(NULL);
    if (!paths) return FALSE;
    if (G_VALUE_HOLDS(value, G_TYPE_FILE)) {
        zero_native_append_file_path(paths, G_FILE(g_value_get_object(value)));
    }
#ifdef GDK_TYPE_FILE_LIST
    else if (G_VALUE_HOLDS(value, GDK_TYPE_FILE_LIST)) {
        GdkFileList *file_list = g_value_get_boxed(value);
        if (file_list) {
            GSList *files = gdk_file_list_get_files(file_list);
            for (GSList *item = files; item; item = item->next) {
                zero_native_append_file_path(paths, G_FILE(item->data));
            }
            g_slist_free(files);
        }
    }
#endif

    gboolean handled = zero_native_emit_file_drop(win, paths->str, paths->len);
    g_string_free(paths, TRUE);
    return handled;
}

static void zero_native_install_file_drop_target(zero_native_gtk_window_t *win) {
    if (!win || !win->root_box) return;
    GtkDropTarget *target = gtk_drop_target_new(G_TYPE_FILE, GDK_ACTION_COPY);
    if (!target) return;
#ifdef GDK_TYPE_FILE_LIST
    GType drop_types[] = { G_TYPE_FILE, GDK_TYPE_FILE_LIST };
    gtk_drop_target_set_gtypes(target, drop_types, G_N_ELEMENTS(drop_types));
#endif
    g_signal_connect(target, "drop", G_CALLBACK(zero_native_on_file_drop), win);
    gtk_widget_add_controller(win->root_box, GTK_EVENT_CONTROLLER(target));
}

static uint64_t zero_native_active_window_id(zero_native_gtk_host_t *host) {
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

static void zero_native_menu_action_activate(GSimpleAction *action, GVariant *parameter, gpointer data) {
    (void)action;
    (void)parameter;
    zero_native_gtk_menu_action_t *menu_action = data;
    if (!menu_action || !menu_action->host || !menu_action->command || !menu_action->command[0]) return;
    zero_native_emit(menu_action->host, (zero_native_gtk_event_t){
        .kind = ZERO_NATIVE_GTK_EVENT_MENU_COMMAND,
        .window_id = zero_native_active_window_id(menu_action->host),
        .command_name = menu_action->command,
        .command_name_len = strlen(menu_action->command),
    });
}

static void zero_native_apply_menu_model_to_window(zero_native_gtk_host_t *host, zero_native_gtk_window_t *win) {
    if (!host || !win || !win->menu_bar) return;
    gtk_popover_menu_bar_set_menu_model(GTK_POPOVER_MENU_BAR(win->menu_bar), host->menu_model);
    gtk_widget_set_visible(win->menu_bar, host->menu_model != NULL);
}

static const char *zero_native_accel_key_name(const char *key) {
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

static char *zero_native_menu_accel(const char *key, uint32_t modifiers) {
    if (!key || !key[0]) return NULL;
    GString *accel = g_string_new("");
    if ((modifiers & ZERO_NATIVE_SHORTCUT_MODIFIER_PRIMARY) != 0 || (modifiers & ZERO_NATIVE_SHORTCUT_MODIFIER_CONTROL) != 0) g_string_append(accel, "<Control>");
    if ((modifiers & ZERO_NATIVE_SHORTCUT_MODIFIER_COMMAND) != 0) g_string_append(accel, "<Super>");
    if ((modifiers & ZERO_NATIVE_SHORTCUT_MODIFIER_OPTION) != 0) g_string_append(accel, "<Alt>");
    if ((modifiers & ZERO_NATIVE_SHORTCUT_MODIFIER_SHIFT) != 0) g_string_append(accel, "<Shift>");
    g_string_append(accel, zero_native_accel_key_name(key));
    return g_string_free(accel, FALSE);
}

static void zero_native_append_menu_section(GMenu *menu, GMenu **section) {
    if (!menu || !section || !*section) return;
    if (g_menu_model_get_n_items(G_MENU_MODEL(*section)) > 0) {
        g_menu_append_section(menu, NULL, G_MENU_MODEL(*section));
    }
    g_object_unref(*section);
    *section = g_menu_new();
}

static int zero_native_any_window_active(zero_native_gtk_host_t *host) {
    if (!host) return 0;
    for (int i = 0; i < host->window_count; i++) {
        zero_native_gtk_window_t *win = &host->windows[i];
        if (win->gtk_window && gtk_window_is_active(win->gtk_window)) return 1;
    }
    return 0;
}

static void zero_native_emit_app_active_if_changed(zero_native_gtk_host_t *host) {
    if (!host) return;
    int active = zero_native_any_window_active(host);
    if (host->app_active == active) return;
    host->app_active = active;
    zero_native_emit(host, (zero_native_gtk_event_t){
        .kind = active ? ZERO_NATIVE_GTK_EVENT_APP_ACTIVATED : ZERO_NATIVE_GTK_EVENT_APP_DEACTIVATED,
    });
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
    zero_native_emit_app_active_if_changed(win->host);
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
    int internal_asset = origin && zero_native_window_allows_asset_origin(win, origin);
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
    int internal_asset = origin && zero_native_window_allows_asset_origin(win, origin);
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

    win->root_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    win->menu_bar = gtk_popover_menu_bar_new_from_model(host->menu_model);
    gtk_widget_set_visible(win->menu_bar, host->menu_model != NULL);
    gtk_box_append(GTK_BOX(win->root_box), win->menu_bar);

    win->stack_root = gtk_overlay_new();
    gtk_widget_set_hexpand(win->stack_root, TRUE);
    gtk_widget_set_vexpand(win->stack_root, TRUE);
    gtk_overlay_set_child(GTK_OVERLAY(win->stack_root), GTK_WIDGET(wv));
    gtk_box_append(GTK_BOX(win->root_box), win->stack_root);
    gtk_window_set_child(win->gtk_window, win->root_box);
    zero_native_install_file_drop_target(win);

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
    zero_native_emit_app_active_if_changed(host);

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

    host->app = gtk_application_new(host->bundle_id, G_APPLICATION_NON_UNIQUE);

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
    zero_native_clear_menu_actions(host);
    if (host->menu_model) g_object_unref(host->menu_model);
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
        char *public_origin = asset_origin_len > 0 ? zero_native_strndup(asset_origin, asset_origin_len) : zero_native_strndup("zero://app", strlen("zero://app"));
        int needs_private_origin = public_origin && !zero_native_request_web_view_supported() && zero_native_window_uses_public_asset_origin(host, win, public_origin);
        char *origin = needs_private_origin ? zero_native_internal_asset_origin(window_id) : (public_origin ? zero_native_strndup(public_origin, strlen(public_origin)) : NULL);
        if (!root || !entry || !public_origin || !origin) {
            free(root);
            free(entry);
            free(origin);
            free(public_origin);
            free(src);
            return;
        }
        while (entry[0] == '/') memmove(entry, entry + 1, strlen(entry));
        if (!zero_native_path_is_safe(entry)) {
            free(entry);
            entry = zero_native_strndup("index.html", strlen("index.html"));
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
        win->asset_root = canonical_root ? zero_native_strndup(canonical_root, strlen(canonical_root)) : zero_native_strndup(".", 1);
        g_free(canonical_root);
        win->asset_entry = entry;
        win->asset_origin = origin;
        win->bridge_origin = public_origin;
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

void zero_native_gtk_set_menus(zero_native_gtk_host_t *host, const char *const *menu_titles, const size_t *menu_title_lens, size_t menu_count, const uint32_t *item_menu_indices, const char *const *item_labels, const size_t *item_label_lens, const char *const *item_commands, const size_t *item_command_lens, const char *const *item_keys, const size_t *item_key_lens, const uint32_t *item_modifiers, const int *item_separators, const int *item_enabled, const int *item_checked, size_t item_count) {
    if (!host) return;
    zero_native_clear_menu_actions(host);
    if (host->menu_model) {
        g_object_unref(host->menu_model);
        host->menu_model = NULL;
    }

    if (menu_count == 0) {
        for (int i = 0; i < host->window_count; i++) zero_native_apply_menu_model_to_window(host, &host->windows[i]);
        return;
    }
    if (!menu_titles || !menu_title_lens) return;
    if (item_count > 0 && (!item_menu_indices || !item_labels || !item_label_lens || !item_commands || !item_command_lens || !item_keys || !item_key_lens || !item_modifiers || !item_separators || !item_enabled || !item_checked)) return;

    GMenu *menubar = g_menu_new();
    for (size_t menu_index = 0; menu_index < menu_count; menu_index++) {
        char *title = zero_native_strndup(menu_titles[menu_index], menu_title_lens[menu_index]);
        if (!title) continue;
        GMenu *menu = g_menu_new();
        GMenu *section = g_menu_new();

        for (size_t item_index = 0; item_index < item_count; item_index++) {
            if (item_menu_indices[item_index] != menu_index) continue;
            if (item_separators[item_index]) {
                zero_native_append_menu_section(menu, &section);
                continue;
            }
            if (host->menu_action_count >= ZERO_NATIVE_MAX_MENU_ITEMS) continue;

            char *label = zero_native_strndup(item_labels[item_index], item_label_lens[item_index]);
            char *command = zero_native_strndup(item_commands[item_index], item_command_lens[item_index]);
            char *key = zero_native_strndup(item_keys[item_index], item_key_lens[item_index]);
            if (!label || !command || !key) {
                free(label);
                free(command);
                free(key);
                continue;
            }

            zero_native_gtk_menu_action_t *menu_action = &host->menu_actions[host->menu_action_count];
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
            g_signal_connect(action, "activate", G_CALLBACK(zero_native_menu_action_activate), menu_action);
            g_action_map_add_action(G_ACTION_MAP(host->app), G_ACTION(action));
            g_object_unref(action);

            char *detailed = g_strdup_printf("app.%s", menu_action->name);
            GMenuItem *gitem = g_menu_item_new(label, detailed);
            if (item_checked[item_index]) g_menu_item_set_attribute(gitem, "toggle-type", "s", "check");
            g_menu_append_item(section, gitem);
            g_object_unref(gitem);

            char *accel = zero_native_menu_accel(key, item_modifiers[item_index]);
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

        zero_native_append_menu_section(menu, &section);
        g_object_unref(section);
        g_menu_append_submenu(menubar, title, G_MENU_MODEL(menu));
        g_object_unref(menu);
        free(title);
    }

    host->menu_model = G_MENU_MODEL(menubar);
    for (int i = 0; i < host->window_count; i++) zero_native_apply_menu_model_to_window(host, &host->windows[i]);
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

int zero_native_gtk_create_view(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, int kind, const char *parent, size_t parent_len, double x, double y, double width, double height, int layer, int visible, int enabled, const char *role, size_t role_len, const char *accessibility_label, size_t accessibility_label_len, const char *text, size_t text_len, const char *command, size_t command_len) {
    zero_native_gtk_window_t *win = zero_native_find_window(host, window_id);
    if (!win || !win->stack_root || label_len == 0 || !zero_native_valid_native_view_frame(x, y, width, height)) return 0;
    if (!zero_native_is_supported_native_view_kind(kind)) return 0;
    if (win->native_view_count >= ZERO_NATIVE_MAX_NATIVE_VIEWS) return 0;

    char *label_copy = zero_native_strndup(label, label_len);
    char *parent_copy = parent_len > 0 ? zero_native_strndup(parent, parent_len) : NULL;
    char *role_copy = role_len > 0 ? zero_native_strndup(role, role_len) : NULL;
    char *accessibility_label_copy = accessibility_label_len > 0 ? zero_native_strndup(accessibility_label, accessibility_label_len) : NULL;
    char *text_copy = text_len > 0 ? zero_native_strndup(text, text_len) : NULL;
    char *command_copy = command_len > 0 ? zero_native_strndup(command, command_len) : NULL;
    if (!label_copy || (parent_len > 0 && !parent_copy) || (role_len > 0 && !role_copy) || (accessibility_label_len > 0 && !accessibility_label_copy) || (text_len > 0 && !text_copy) || (command_len > 0 && !command_copy)) {
        free(label_copy);
        free(parent_copy);
        free(role_copy);
        free(accessibility_label_copy);
        free(text_copy);
        free(command_copy);
        return 0;
    }
    if (zero_native_find_native_view(win, label_copy)) {
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
        zero_native_gtk_native_view_t *parent_view = zero_native_find_native_view(win, parent_copy);
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
    GtkWidget *widget = zero_native_make_native_widget(kind, label_copy, display_text);
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
    for (int i = 0; i < ZERO_NATIVE_MAX_NATIVE_VIEWS; i++) {
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

    zero_native_gtk_native_view_t *view = &win->native_views[slot];
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
    zero_native_apply_native_view_frame(view);
    zero_native_apply_native_view_state(view, 1, display_text);
    zero_native_configure_native_view_action(view);
    win->native_view_count++;
    zero_native_reorder_overlays(win);
    return 1;
}

int zero_native_gtk_update_view(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, int has_frame, double x, double y, double width, double height, int has_layer, int layer, int has_visible, int visible, int has_enabled, int enabled, int has_role, const char *role, size_t role_len, int has_accessibility_label, const char *accessibility_label, size_t accessibility_label_len, int has_text, const char *text, size_t text_len, int has_command, const char *command, size_t command_len) {
    zero_native_gtk_window_t *win = zero_native_find_window(host, window_id);
    char *label_copy = label_len > 0 ? zero_native_strndup(label, label_len) : NULL;
    zero_native_gtk_native_view_t *view = zero_native_find_native_view(win, label_copy);
    free(label_copy);
    if (!view || !view->widget) return 0;

    if (has_frame) {
        if (!zero_native_valid_native_view_frame(x, y, width, height)) return 0;
        view->x = x;
        view->y = y;
        view->width = width;
        view->height = height;
        zero_native_apply_native_view_frame(view);
    }
    if (has_layer) view->layer = layer;
    if (has_visible) view->visible = visible != 0;
    if (has_enabled) view->enabled = enabled != 0;
    if (has_role) zero_native_replace_string(&view->role, role, role_len);
    if (has_accessibility_label) zero_native_replace_string(&view->accessibility_label, accessibility_label, accessibility_label_len);
    if (has_text) {
        zero_native_replace_string(&view->text, text, text_len);
        view->explicit_text = text_len > 0;
    }
    if (has_command) {
        zero_native_replace_string(&view->command, command, command_len);
        zero_native_configure_native_view_action(view);
    }

    int update_text = has_text || (has_role && !view->explicit_text);
    const char *display_text = has_text ? (view->text ? view->text : "") : zero_native_native_display_text(view);
    if (has_visible || has_enabled || has_role || has_accessibility_label || update_text) zero_native_apply_native_view_state(view, update_text, display_text);
    if (update_text && view->kind == ZERO_NATIVE_GTK_VIEW_SEGMENTED_CONTROL) zero_native_configure_native_view_action(view);
    if (has_layer) zero_native_reorder_overlays(win);
    return 1;
}

int zero_native_gtk_set_view_frame(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height) {
    return zero_native_gtk_update_view(host, window_id, label, label_len, 1, x, y, width, height, 0, 0, 0, 1, 0, 1, 0, "", 0, 0, "", 0, 0, "", 0, 0, "", 0);
}

int zero_native_gtk_set_view_visible(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len, int visible) {
    return zero_native_gtk_update_view(host, window_id, label, label_len, 0, 0, 0, 0, 0, 0, 0, 1, visible, 0, 1, 0, "", 0, 0, "", 0, 0, "", 0, 0, "", 0);
}

int zero_native_gtk_focus_view(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    zero_native_gtk_window_t *win = zero_native_find_window(host, window_id);
    char *label_copy = label_len > 0 ? zero_native_strndup(label, label_len) : NULL;
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
    zero_native_gtk_webview_t *webview = zero_native_find_webview(win, label_copy);
    if (webview && webview->web_view) {
        GtkWidget *widget = GTK_WIDGET(webview->web_view);
        free(label_copy);
        if (!gtk_widget_get_visible(widget) || !gtk_widget_get_sensitive(widget)) return 0;
        return gtk_widget_grab_focus(widget) ? 1 : 0;
    }
    zero_native_gtk_native_view_t *view = zero_native_find_native_view(win, label_copy);
    free(label_copy);
    if (!view || !view->widget || !gtk_widget_get_visible(view->widget) || !gtk_widget_get_sensitive(view->widget)) return 0;
    return gtk_widget_grab_focus(view->widget) ? 1 : 0;
}

int zero_native_gtk_close_view(zero_native_gtk_host_t *host, uint64_t window_id, const char *label, size_t label_len) {
    zero_native_gtk_window_t *win = zero_native_find_window(host, window_id);
    char *label_copy = label_len > 0 ? zero_native_strndup(label, label_len) : NULL;
    zero_native_gtk_native_view_t *view = zero_native_find_native_view(win, label_copy);
    free(label_copy);
    if (!view || !view->widget) return 0;
    zero_native_clear_native_view(win, view);
    zero_native_reorder_overlays(win);
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
    zero_native_reorder_overlays(win);
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
    zero_native_reorder_overlays(win);
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

int zero_native_gtk_open_external_url(zero_native_gtk_host_t *host, const char *url, size_t url_len) {
    if (!host || !url || url_len == 0) return 0;
    char *url_copy = zero_native_strndup(url, url_len);
    if (!url_copy) return 0;
    zero_native_open_external_uri(zero_native_parent_window(host), url_copy);
    free(url_copy);
    return 1;
}

int zero_native_gtk_reveal_path(zero_native_gtk_host_t *host, const char *path, size_t path_len) {
    if (!host || !path || path_len == 0) return 0;
    char *path_copy = zero_native_strndup(path, path_len);
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
    zero_native_open_external_uri(zero_native_parent_window(host), uri);
    g_free(uri);
    return 1;
}

int zero_native_gtk_show_notification(zero_native_gtk_host_t *host, const char *title, size_t title_len, const char *subtitle, size_t subtitle_len, const char *body, size_t body_len) {
    if (!host || !host->app || !title || title_len == 0) return 0;
    if ((subtitle_len > 0 && !subtitle) || (body_len > 0 && !body)) return 0;
    char *title_copy = zero_native_strndup(title, title_len);
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

static char *zero_native_recent_bookmarks_path(void) {
    const char *data_dir = g_get_user_data_dir();
    if (!data_dir || data_dir[0] == '\0') return NULL;
    if (g_mkdir_with_parents(data_dir, 0700) != 0) return NULL;
    return g_build_filename(data_dir, "recently-used.xbel", NULL);
}

static const char *zero_native_recent_app_name(zero_native_gtk_host_t *host) {
    if (host && host->app_name && host->app_name[0] != '\0') return host->app_name;
    const char *application_name = g_get_application_name();
    if (application_name && application_name[0] != '\0') return application_name;
    return "zero-native";
}

static GBookmarkFile *zero_native_load_recent_bookmarks(char **out_path) {
    *out_path = zero_native_recent_bookmarks_path();
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

static int zero_native_write_recent_bookmarks(GBookmarkFile *bookmarks, const char *path) {
    GError *error = NULL;
    gboolean ok = g_bookmark_file_to_file(bookmarks, path, &error);
    if (error) g_error_free(error);
    return ok ? 1 : 0;
}

int zero_native_gtk_add_recent_document(zero_native_gtk_host_t *host, const char *path, size_t path_len) {
    if (!host || !path || path_len == 0) return 0;
    char *path_copy = zero_native_strndup(path, path_len);
    if (!path_copy) return 0;

    char *uri = g_filename_to_uri(path_copy, NULL, NULL);
    if (!uri) {
        free(path_copy);
        return 0;
    }

    char *bookmarks_path = NULL;
    GBookmarkFile *bookmarks = zero_native_load_recent_bookmarks(&bookmarks_path);
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

    g_bookmark_file_add_application(bookmarks, uri, zero_native_recent_app_name(host), NULL);
    int ok = zero_native_write_recent_bookmarks(bookmarks, bookmarks_path);

    g_bookmark_file_free(bookmarks);
    g_free(bookmarks_path);
    g_free(uri);
    free(path_copy);
    return ok;
}

int zero_native_gtk_clear_recent_documents(zero_native_gtk_host_t *host) {
    if (!host) return 0;
    char *bookmarks_path = NULL;
    GBookmarkFile *bookmarks = zero_native_load_recent_bookmarks(&bookmarks_path);
    if (!bookmarks) return 0;

    const char *app_name = zero_native_recent_app_name(host);
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
    int ok = changed ? zero_native_write_recent_bookmarks(bookmarks, bookmarks_path) : 1;
    g_bookmark_file_free(bookmarks);
    g_free(bookmarks_path);
    return ok;
}

typedef struct zero_native_secret_schema_attribute {
    const char *name;
    int type;
} zero_native_secret_schema_attribute_t;

typedef struct zero_native_secret_schema {
    const char *name;
    int flags;
    zero_native_secret_schema_attribute_t attributes[32];
} zero_native_secret_schema_t;

typedef gboolean (*zero_native_secret_password_store_sync_fn)(const zero_native_secret_schema_t *schema, const char *collection, const char *label, const char *password, GCancellable *cancellable, GError **error, ...);
typedef char *(*zero_native_secret_password_lookup_sync_fn)(const zero_native_secret_schema_t *schema, GCancellable *cancellable, GError **error, ...);
typedef gboolean (*zero_native_secret_password_clear_sync_fn)(const zero_native_secret_schema_t *schema, GCancellable *cancellable, GError **error, ...);

typedef struct zero_native_secret_api {
    int attempted;
    void *handle;
    zero_native_secret_password_store_sync_fn store_sync;
    zero_native_secret_password_lookup_sync_fn lookup_sync;
    zero_native_secret_password_clear_sync_fn clear_sync;
} zero_native_secret_api_t;

static zero_native_secret_api_t zero_native_secret_api = {0};

static const zero_native_secret_schema_t zero_native_credential_schema = {
    "dev.zero_native.Credential",
    0,
    {
        { "service", 0 },
        { "account", 0 },
        { NULL, 0 },
    },
};

static void *zero_native_dlsym(void *handle, const char *name) {
    dlerror();
    void *symbol = dlsym(handle, name);
    return dlerror() ? NULL : symbol;
}

static zero_native_secret_api_t *zero_native_load_secret_api(void) {
    if (zero_native_secret_api.attempted) return zero_native_secret_api.handle ? &zero_native_secret_api : NULL;
    zero_native_secret_api.attempted = 1;

    void *handle = dlopen("libsecret-1.so.0", RTLD_NOW | RTLD_LOCAL);
    if (!handle) handle = dlopen("libsecret-1.so", RTLD_NOW | RTLD_LOCAL);
    if (!handle) return NULL;

    zero_native_secret_api.store_sync = (zero_native_secret_password_store_sync_fn)zero_native_dlsym(handle, "secret_password_store_sync");
    zero_native_secret_api.lookup_sync = (zero_native_secret_password_lookup_sync_fn)zero_native_dlsym(handle, "secret_password_lookup_sync");
    zero_native_secret_api.clear_sync = (zero_native_secret_password_clear_sync_fn)zero_native_dlsym(handle, "secret_password_clear_sync");
    if (!zero_native_secret_api.store_sync || !zero_native_secret_api.lookup_sync || !zero_native_secret_api.clear_sync) {
        dlclose(handle);
        memset(&zero_native_secret_api, 0, sizeof(zero_native_secret_api));
        zero_native_secret_api.attempted = 1;
        return NULL;
    }

    zero_native_secret_api.handle = handle;
    return &zero_native_secret_api;
}

static void zero_native_secure_free(char *bytes, size_t len) {
    if (!bytes) return;
    volatile char *cursor = bytes;
    for (size_t i = 0; i < len; i++) cursor[i] = 0;
    free(bytes);
}

int zero_native_gtk_credentials_available(zero_native_gtk_host_t *host) {
    (void)host;
    return zero_native_load_secret_api() ? 1 : 0;
}

int zero_native_gtk_set_credential(zero_native_gtk_host_t *host, const char *service, size_t service_len, const char *account, size_t account_len, const char *secret, size_t secret_len) {
    (void)host;
    zero_native_secret_api_t *api = zero_native_load_secret_api();
    if (!api || !service || service_len == 0 || !account || account_len == 0 || !secret || secret_len == 0) return 0;

    char *service_copy = zero_native_strndup(service, service_len);
    char *account_copy = zero_native_strndup(account, account_len);
    char *secret_copy = zero_native_strndup(secret, secret_len);
    if (!service_copy || !account_copy || !secret_copy) {
        free(service_copy);
        free(account_copy);
        zero_native_secure_free(secret_copy, secret_len);
        return 0;
    }

    char *label = g_strdup_printf("%s:%s", service_copy, account_copy);
    if (!label) {
        free(service_copy);
        free(account_copy);
        zero_native_secure_free(secret_copy, secret_len);
        return 0;
    }

    GError *error = NULL;
    gboolean ok = api->store_sync(&zero_native_credential_schema, "default", label, secret_copy, NULL, &error, "service", service_copy, "account", account_copy, NULL);
    if (error) g_error_free(error);

    g_free(label);
    free(service_copy);
    free(account_copy);
    zero_native_secure_free(secret_copy, secret_len);
    return ok ? 1 : 0;
}

size_t zero_native_gtk_get_credential(zero_native_gtk_host_t *host, const char *service, size_t service_len, const char *account, size_t account_len, char *buffer, size_t buffer_len) {
    (void)host;
    zero_native_secret_api_t *api = zero_native_load_secret_api();
    if (!api || !service || service_len == 0 || !account || account_len == 0 || !buffer) return 0;

    char *service_copy = zero_native_strndup(service, service_len);
    char *account_copy = zero_native_strndup(account, account_len);
    if (!service_copy || !account_copy) {
        free(service_copy);
        free(account_copy);
        return 0;
    }

    GError *error = NULL;
    char *password = api->lookup_sync(&zero_native_credential_schema, NULL, &error, "service", service_copy, "account", account_copy, NULL);
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

int zero_native_gtk_delete_credential(zero_native_gtk_host_t *host, const char *service, size_t service_len, const char *account, size_t account_len) {
    (void)host;
    zero_native_secret_api_t *api = zero_native_load_secret_api();
    if (!api || !service || service_len == 0 || !account || account_len == 0) return 0;

    char *service_copy = zero_native_strndup(service, service_len);
    char *account_copy = zero_native_strndup(account, account_len);
    if (!service_copy || !account_copy) {
        free(service_copy);
        free(account_copy);
        return 0;
    }

    GError *error = NULL;
    gboolean ok = api->clear_sync(&zero_native_credential_schema, NULL, &error, "service", service_copy, "account", account_copy, NULL);
    free(service_copy);
    free(account_copy);
    if (error) {
        g_error_free(error);
        return -1;
    }
    return ok ? 1 : 0;
}

typedef struct zero_native_clipboard_read_state {
    GMainLoop *loop;
    char *text;
} zero_native_clipboard_read_state_t;

typedef struct zero_native_clipboard_data_read_state {
    GMainLoop *loop;
    GBytes *bytes;
} zero_native_clipboard_data_read_state_t;

static gboolean zero_native_clipboard_is_plain_text(const char *mime_type, size_t mime_type_len) {
    return (mime_type_len == 4 && g_ascii_strncasecmp(mime_type, "text", 4) == 0) ||
        (mime_type_len == 10 && g_ascii_strncasecmp(mime_type, "text/plain", 10) == 0);
}

static size_t zero_native_copy_bytes(char *buffer, size_t buffer_len, const void *bytes, size_t bytes_len) {
    if (!buffer || buffer_len == 0 || !bytes) return 0;
    size_t count = bytes_len < buffer_len ? bytes_len : buffer_len;
    if (count > 0) memcpy(buffer, bytes, count);
    return bytes_len;
}

static void zero_native_clipboard_read_done(GObject *source, GAsyncResult *result, gpointer data) {
    zero_native_clipboard_read_state_t *state = data;
    GError *error = NULL;
    state->text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(source), result, &error);
    if (error) g_error_free(error);
    g_main_loop_quit(state->loop);
}

static void zero_native_clipboard_data_read_done(GObject *source, GAsyncResult *result, gpointer data) {
    zero_native_clipboard_data_read_state_t *state = data;
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

size_t zero_native_gtk_clipboard_read(zero_native_gtk_host_t *host, char *buffer, size_t buffer_len) {
    return zero_native_gtk_clipboard_read_data(host, "text/plain", strlen("text/plain"), buffer, buffer_len);
}

void zero_native_gtk_clipboard_write(zero_native_gtk_host_t *host, const char *text, size_t text_len) {
    (void)zero_native_gtk_clipboard_write_data(host, "text/plain", strlen("text/plain"), text, text_len);
}

size_t zero_native_gtk_clipboard_read_data(zero_native_gtk_host_t *host, const char *mime_type, size_t mime_type_len, char *buffer, size_t buffer_len) {
    (void)host;
    if (!mime_type || mime_type_len == 0 || !buffer || buffer_len == 0) return 0;
    GdkDisplay *display = gdk_display_get_default();
    if (!display) return 0;
    GdkClipboard *clipboard = gdk_display_get_clipboard(display);
    if (!clipboard) return 0;
    if (!zero_native_clipboard_is_plain_text(mime_type, mime_type_len)) {
        char *mime = zero_native_strndup(mime_type, mime_type_len);
        if (!mime) return 0;
        const char *mime_types[] = { mime, NULL };
        zero_native_clipboard_data_read_state_t data_state = {0};
        data_state.loop = g_main_loop_new(NULL, FALSE);
        if (!data_state.loop) {
            free(mime);
            return 0;
        }
        gdk_clipboard_read_async(clipboard, mime_types, G_PRIORITY_DEFAULT, NULL, zero_native_clipboard_data_read_done, &data_state);
        g_main_loop_run(data_state.loop);
        g_main_loop_unref(data_state.loop);
        free(mime);
        if (!data_state.bytes) return 0;
        gsize len = 0;
        const void *data = g_bytes_get_data(data_state.bytes, &len);
        size_t count = zero_native_copy_bytes(buffer, buffer_len, data, len);
        g_bytes_unref(data_state.bytes);
        return count;
    }

    zero_native_clipboard_read_state_t state = {0};
    state.loop = g_main_loop_new(NULL, FALSE);
    if (!state.loop) return 0;
    gdk_clipboard_read_text_async(clipboard, NULL, zero_native_clipboard_read_done, &state);
    g_main_loop_run(state.loop);
    g_main_loop_unref(state.loop);
    if (!state.text) return 0;
    size_t len = strlen(state.text);
    size_t count = zero_native_copy_bytes(buffer, buffer_len, state.text, len);
    g_free(state.text);
    return count;
}

int zero_native_gtk_clipboard_write_data(zero_native_gtk_host_t *host, const char *mime_type, size_t mime_type_len, const char *bytes, size_t bytes_len) {
    (void)host;
    if (!mime_type || mime_type_len == 0 || (!bytes && bytes_len > 0)) return 0;
    GdkDisplay *display = gdk_display_get_default();
    if (!display) return 0;
    GdkClipboard *clipboard = gdk_display_get_clipboard(display);
    if (!clipboard) return 0;
    if (zero_native_clipboard_is_plain_text(mime_type, mime_type_len)) {
        char *copy = zero_native_strndup(bytes, bytes_len);
        if (!copy) return 0;
        gdk_clipboard_set_text(clipboard, copy);
        free(copy);
        return 1;
    }
    char *mime = zero_native_strndup(mime_type, mime_type_len);
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
        result.bytes_written = overflow ? zero_native_overflow_size(buffer_len) : offset;
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
            if (len > buffer_len) {
                written = zero_native_overflow_size(buffer_len);
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
