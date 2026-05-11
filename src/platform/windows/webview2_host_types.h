#ifndef ZERO_NATIVE_WEBVIEW2_HOST_TYPES_H
#define ZERO_NATIVE_WEBVIEW2_HOST_TYPES_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char *title;
    size_t title_len;
    const char *default_path;
    size_t default_path_len;
    const char *extensions;
    size_t extensions_len;
    int allow_directories;
    int allow_multiple;
} WindowsOpenDialogOpts;

typedef struct {
    size_t count;
    size_t bytes_written;
} WindowsOpenDialogResult;

typedef struct {
    const char *title;
    size_t title_len;
    const char *default_path;
    size_t default_path_len;
    const char *default_name;
    size_t default_name_len;
    const char *extensions;
    size_t extensions_len;
} WindowsSaveDialogOpts;

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
} WindowsMessageDialogOpts;

#ifdef __cplusplus
}
#endif

#endif /* ZERO_NATIVE_WEBVIEW2_HOST_TYPES_H */