#pragma once

#include <stddef.h>
#include <stdint.h>

enum {
  ZERO_NATIVE_WIDGET_ROLE_NONE = 0,
  ZERO_NATIVE_WIDGET_ROLE_GROUP = 1,
  ZERO_NATIVE_WIDGET_ROLE_TEXT = 2,
  ZERO_NATIVE_WIDGET_ROLE_IMAGE = 3,
  ZERO_NATIVE_WIDGET_ROLE_BUTTON = 4,
  ZERO_NATIVE_WIDGET_ROLE_TEXTBOX = 5,
  ZERO_NATIVE_WIDGET_ROLE_TOOLTIP = 6,
  ZERO_NATIVE_WIDGET_ROLE_DIALOG = 7,
  ZERO_NATIVE_WIDGET_ROLE_MENU = 8,
  ZERO_NATIVE_WIDGET_ROLE_MENUITEM = 9,
  ZERO_NATIVE_WIDGET_ROLE_LIST = 10,
  ZERO_NATIVE_WIDGET_ROLE_LISTITEM = 11,
  ZERO_NATIVE_WIDGET_ROLE_ROW = 12,
  ZERO_NATIVE_WIDGET_ROLE_GRID = 13,
  ZERO_NATIVE_WIDGET_ROLE_GRIDCELL = 14,
  ZERO_NATIVE_WIDGET_ROLE_TAB = 15,
  ZERO_NATIVE_WIDGET_ROLE_CHECKBOX = 16,
  ZERO_NATIVE_WIDGET_ROLE_SWITCH = 17,
  ZERO_NATIVE_WIDGET_ROLE_SLIDER = 18,
  ZERO_NATIVE_WIDGET_ROLE_PROGRESSBAR = 19,
};

enum {
  ZERO_NATIVE_WIDGET_FLAG_FOCUSED = 1u << 0,
  ZERO_NATIVE_WIDGET_FLAG_HOVERED = 1u << 1,
  ZERO_NATIVE_WIDGET_FLAG_PRESSED = 1u << 2,
  ZERO_NATIVE_WIDGET_FLAG_SELECTED = 1u << 3,
  ZERO_NATIVE_WIDGET_FLAG_DISABLED = 1u << 4,
  ZERO_NATIVE_WIDGET_FLAG_FOCUSABLE = 1u << 5,
};

enum {
  ZERO_NATIVE_WIDGET_ACTION_FOCUS = 1u << 0,
  ZERO_NATIVE_WIDGET_ACTION_PRESS = 1u << 1,
  ZERO_NATIVE_WIDGET_ACTION_TOGGLE = 1u << 2,
  ZERO_NATIVE_WIDGET_ACTION_INCREMENT = 1u << 3,
  ZERO_NATIVE_WIDGET_ACTION_DECREMENT = 1u << 4,
  ZERO_NATIVE_WIDGET_ACTION_SET_TEXT = 1u << 5,
  ZERO_NATIVE_WIDGET_ACTION_SET_SELECTION = 1u << 6,
  ZERO_NATIVE_WIDGET_ACTION_SELECT = 1u << 7,
  ZERO_NATIVE_WIDGET_ACTION_DRAG = 1u << 8,
  ZERO_NATIVE_WIDGET_ACTION_DROP_FILES = 1u << 9,
};

enum {
  ZERO_NATIVE_WIDGET_ACTION_KIND_FOCUS = 0,
  ZERO_NATIVE_WIDGET_ACTION_KIND_PRESS = 1,
  ZERO_NATIVE_WIDGET_ACTION_KIND_TOGGLE = 2,
  ZERO_NATIVE_WIDGET_ACTION_KIND_INCREMENT = 3,
  ZERO_NATIVE_WIDGET_ACTION_KIND_DECREMENT = 4,
  ZERO_NATIVE_WIDGET_ACTION_KIND_SET_TEXT = 5,
  ZERO_NATIVE_WIDGET_ACTION_KIND_SET_SELECTION = 6,
  ZERO_NATIVE_WIDGET_ACTION_KIND_SET_COMPOSITION = 7,
  ZERO_NATIVE_WIDGET_ACTION_KIND_COMMIT_COMPOSITION = 8,
  ZERO_NATIVE_WIDGET_ACTION_KIND_CANCEL_COMPOSITION = 9,
  ZERO_NATIVE_WIDGET_ACTION_KIND_SELECT = 10,
  ZERO_NATIVE_WIDGET_ACTION_KIND_DRAG = 11,
  ZERO_NATIVE_WIDGET_ACTION_KIND_DROP_FILES = 12,
};

typedef struct zero_native_widget_semantics {
  uint64_t id;
  uint64_t parent_id;
  int role;
  uint32_t flags;
  uint32_t actions;
  float x;
  float y;
  float width;
  float height;
  float value;
  int has_value;
  const char *label;
  uintptr_t label_len;
  const char *text;
  uintptr_t text_len;
  intptr_t text_selection_start;
  intptr_t text_selection_end;
  intptr_t text_composition_start;
  intptr_t text_composition_end;
  intptr_t grid_row_index;
  intptr_t grid_column_index;
  intptr_t grid_row_count;
  intptr_t grid_column_count;
  intptr_t list_item_index;
  intptr_t list_item_count;
  float scroll_offset;
  float scroll_viewport_extent;
  float scroll_content_extent;
  int has_scroll;
} zero_native_widget_semantics_t;

typedef struct zero_native_widget_text_geometry {
  uint64_t id;
  int has_caret_bounds;
  float caret_x;
  float caret_y;
  float caret_width;
  float caret_height;
  int has_selection_bounds;
  float selection_x;
  float selection_y;
  float selection_width;
  float selection_height;
  uintptr_t selection_rect_count;
  int has_composition_bounds;
  float composition_x;
  float composition_y;
  float composition_width;
  float composition_height;
  uintptr_t composition_rect_count;
} zero_native_widget_text_geometry_t;

typedef struct zero_native_widget_action {
  uint64_t id;
  int action;
  const char *text;
  uintptr_t text_len;
  uintptr_t selection_anchor;
  uintptr_t selection_focus;
  int has_selection;
} zero_native_widget_action_t;

typedef struct zero_native_viewport_state {
  float width;
  float height;
  float scale;
  int has_surface;
  float safe_top;
  float safe_right;
  float safe_bottom;
  float safe_left;
  float keyboard_top;
  float keyboard_right;
  float keyboard_bottom;
  float keyboard_left;
  float content_x;
  float content_y;
  float content_width;
  float content_height;
} zero_native_viewport_state_t;

void *zero_native_app_create(void);
void zero_native_app_destroy(void *app);
void zero_native_app_start(void *app);
void zero_native_app_activate(void *app);
void zero_native_app_deactivate(void *app);
void zero_native_app_stop(void *app);
void zero_native_app_resize(void *app, float width, float height, float scale, void *surface);
void zero_native_app_viewport(void *app, float width, float height, float scale, void *surface, float safe_top, float safe_right, float safe_bottom, float safe_left, float keyboard_top, float keyboard_right, float keyboard_bottom, float keyboard_left);
int zero_native_app_viewport_state(void *app, zero_native_viewport_state_t *out);
void zero_native_app_touch(void *app, uint64_t id, int phase, float x, float y, float pressure);
void zero_native_app_scroll(void *app, uint64_t id, float x, float y, float delta_x, float delta_y);
void zero_native_app_key(void *app, int phase, const char *key, uintptr_t key_len, const char *text, uintptr_t text_len, uint32_t modifiers_mask);
void zero_native_app_text(void *app, const char *text, uintptr_t len);
void zero_native_app_ime(void *app, int kind, const char *text, uintptr_t len, intptr_t cursor);
void zero_native_app_command(void *app, const char *name, uintptr_t len);
void zero_native_app_frame(void *app);
void zero_native_app_set_asset_root(void *app, const char *path, uintptr_t len);
void zero_native_app_set_asset_entry(void *app, const char *path, uintptr_t len);
uintptr_t zero_native_app_last_command_count(void *app);
const char *zero_native_app_last_command_name(void *app);
const char *zero_native_app_last_error_name(void *app);
uintptr_t zero_native_app_widget_semantics_count(void *app);
int zero_native_app_widget_semantics_at(void *app, uintptr_t index, zero_native_widget_semantics_t *out);
int zero_native_app_widget_semantics_by_id(void *app, uint64_t id, zero_native_widget_semantics_t *out);
int zero_native_app_widget_text_geometry(void *app, uint64_t id, zero_native_widget_text_geometry_t *out);
int zero_native_app_widget_action(void *app, const zero_native_widget_action_t *action);
