#include <windows.h>
#include <shellapi.h>

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

struct WindowsEvent {
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

using EventCallback = void (*)(void *, const WindowsEvent *);
using BridgeCallback = void (*)(void *, uint64_t, const char *, size_t, const char *, size_t);

struct Window {
    uint64_t id = 1;
    HWND hwnd = nullptr;
    std::string label;
    std::string title;
    double x = 0;
    double y = 0;
    double width = 720;
    double height = 480;
};

struct Host {
    HINSTANCE instance = GetModuleHandleW(nullptr);
    std::string app_name;
    std::string window_title;
    std::string bundle_id;
    std::string icon_path;
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

static std::wstring widen(const std::string &value) {
    if (value.empty()) return std::wstring();
    int count = MultiByteToWideChar(CP_UTF8, 0, value.data(), (int)value.size(), nullptr, 0);
    std::wstring out((size_t)count, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, value.data(), (int)value.size(), out.data(), count);
    return out;
}

static size_t boundedLen(const char *text, size_t limit) {
    size_t len = 0;
    while (len < limit && text[len] != '\0') ++len;
    return len;
}

static void emit(Host *host, const Window &window, EventKind kind) {
    if (!host || !host->callback) return;
    RECT rect = {};
    if (window.hwnd) GetClientRect(window.hwnd, &rect);
    WindowsEvent event = {};
    event.kind = kind;
    event.window_id = window.id;
    event.width = rect.right > rect.left ? (double)(rect.right - rect.left) : window.width;
    event.height = rect.bottom > rect.top ? (double)(rect.bottom - rect.top) : window.height;
    event.scale = 1.0;
    event.x = window.x;
    event.y = window.y;
    event.open = window.hwnd != nullptr;
    event.focused = window.hwnd && GetFocus() == window.hwnd;
    event.label = window.label.c_str();
    event.label_len = window.label.size();
    event.title = window.title.c_str();
    event.title_len = window.title.size();
    host->callback(host->callback_context, &event);
}

static Host *hostFromWindow(HWND hwnd) {
    return reinterpret_cast<Host *>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
}

static LRESULT CALLBACK windowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_NCCREATE) {
        auto *create = reinterpret_cast<CREATESTRUCTW *>(lparam);
        auto *host = reinterpret_cast<Host *>(create->lpCreateParams);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(host));
    }
    Host *host = hostFromWindow(hwnd);
    switch (message) {
        case WM_SIZE:
            if (host) {
                for (auto &entry : host->windows) {
                    if (entry.second.hwnd == hwnd) emit(host, entry.second, kResize);
                }
            }
            return 0;
        case WM_SETFOCUS:
        case WM_KILLFOCUS:
        case WM_MOVE:
            if (host) {
                for (auto &entry : host->windows) {
                    if (entry.second.hwnd == hwnd) emit(host, entry.second, kWindowFrame);
                }
            }
            return 0;
        case WM_TIMER:
            if (host) {
                for (auto &entry : host->windows) emit(host, entry.second, kFrame);
            }
            return 0;
        case WM_CLOSE:
            DestroyWindow(hwnd);
            return 0;
        case WM_DESTROY:
            if (host) {
                for (auto &entry : host->windows) {
                    if (entry.second.hwnd == hwnd) {
                        entry.second.hwnd = nullptr;
                        emit(host, entry.second, kWindowFrame);
                    }
                }
                bool any_open = false;
                for (auto &entry : host->windows) any_open = any_open || entry.second.hwnd;
                if (!any_open) PostQuitMessage(0);
            }
            return 0;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

static ATOM registerClass(Host *host) {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = windowProc;
    wc.hInstance = host->instance;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    wc.lpszClassName = L"ZeroNativeWindowsHost";
    return RegisterClassExW(&wc);
}

static bool createNativeWindow(Host *host, Window &window) {
    registerClass(host);
    std::wstring title = widen(window.title.empty() ? host->window_title : window.title);
    HWND hwnd = CreateWindowExW(
        0,
        L"ZeroNativeWindowsHost",
        title.c_str(),
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        (int)window.width,
        (int)window.height,
        nullptr,
        nullptr,
        host->instance,
        host);
    if (!hwnd) return false;
    window.hwnd = hwnd;
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    SetTimer(hwnd, 1, 16, nullptr);
    return true;
}

} // namespace

extern "C" {

void zero_native_windows_load_window_webview(Host *host, uint64_t window_id, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback);
void zero_native_windows_bridge_respond_window(Host *host, uint64_t window_id, const char *response, size_t response_len);

Host *zero_native_windows_create(const char *app_name, size_t app_name_len, const char *window_title, size_t window_title_len, const char *bundle_id, size_t bundle_id_len, const char *icon_path, size_t icon_path_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame) {
    (void)restore_frame;
    Host *host = new Host();
    host->app_name = slice(app_name, app_name_len);
    host->window_title = slice(window_title, window_title_len);
    host->bundle_id = slice(bundle_id, bundle_id_len);
    host->icon_path = slice(icon_path, icon_path_len);
    Window window;
    window.id = 1;
    window.label = slice(window_label, window_label_len);
    window.title = host->window_title.empty() ? host->app_name : host->window_title;
    window.x = x;
    window.y = y;
    window.width = width;
    window.height = height;
    host->windows[window.id] = window;
    return host;
}

void zero_native_windows_destroy(Host *host) {
    if (!host) return;
    delete host;
}

void zero_native_windows_run(Host *host, EventCallback callback, void *context) {
    if (!host) return;
    host->callback = callback;
    host->callback_context = context;
    host->running = true;
    if (!host->windows.empty()) createNativeWindow(host, host->windows.begin()->second);
    WindowsEvent start = {};
    start.kind = kStart;
    start.window_id = 1;
    callback(context, &start);
    for (auto &entry : host->windows) {
        emit(host, entry.second, kResize);
        emit(host, entry.second, kWindowFrame);
    }
    MSG message = {};
    while (host->running && GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    WindowsEvent shutdown = {};
    shutdown.kind = kShutdown;
    shutdown.window_id = 1;
    callback(context, &shutdown);
}

void zero_native_windows_stop(Host *host) {
    if (!host) return;
    host->running = false;
    PostQuitMessage(0);
}

void zero_native_windows_load_webview(Host *host, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback) {
    zero_native_windows_load_window_webview(host, 1, source, source_len, source_kind, asset_root, asset_root_len, asset_entry, asset_entry_len, asset_origin, asset_origin_len, spa_fallback);
}

void zero_native_windows_load_window_webview(Host *host, uint64_t window_id, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback) {
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

void zero_native_windows_set_bridge_callback(Host *host, BridgeCallback callback, void *context) {
    if (!host) return;
    host->bridge_callback = callback;
    host->bridge_context = context;
}

void zero_native_windows_bridge_respond(Host *host, const char *response, size_t response_len) {
    zero_native_windows_bridge_respond_window(host, 1, response, response_len);
}

void zero_native_windows_bridge_respond_window(Host *host, uint64_t window_id, const char *response, size_t response_len) {
    (void)host;
    (void)window_id;
    (void)response;
    (void)response_len;
}

void zero_native_windows_emit_window_event(Host *host, uint64_t window_id, const char *name, size_t name_len, const char *detail_json, size_t detail_json_len) {
    (void)host;
    (void)window_id;
    (void)name;
    (void)name_len;
    (void)detail_json;
    (void)detail_json_len;
}

void zero_native_windows_set_security_policy(Host *host, const char *allowed_origins, size_t allowed_origins_len, const char *external_urls, size_t external_urls_len, int external_action) {
    (void)host;
    (void)allowed_origins;
    (void)allowed_origins_len;
    (void)external_urls;
    (void)external_urls_len;
    (void)external_action;
}

void zero_native_windows_register_resource_bytes(Host *host, const char *id, size_t id_len, const char *mime, size_t mime_len, const char *bytes, size_t bytes_len, int one_shot) {
    (void)host;
    (void)id;
    (void)id_len;
    (void)mime;
    (void)mime_len;
    (void)bytes;
    (void)bytes_len;
    (void)one_shot;
}

void zero_native_windows_revoke_resource(Host *host, const char *id, size_t id_len) {
    (void)host;
    (void)id;
    (void)id_len;
}

int zero_native_windows_create_window(Host *host, uint64_t window_id, const char *window_title, size_t window_title_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame) {
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
    bool ok = createNativeWindow(host, window);
    host->windows[window_id] = window;
    return ok ? 1 : 0;
}

int zero_native_windows_focus_window(Host *host, uint64_t window_id) {
    if (!host) return 0;
    auto found = host->windows.find(window_id);
    if (found == host->windows.end() || !found->second.hwnd) return 0;
    SetForegroundWindow(found->second.hwnd);
    SetFocus(found->second.hwnd);
    return 1;
}

int zero_native_windows_close_window(Host *host, uint64_t window_id) {
    if (!host) return 0;
    auto found = host->windows.find(window_id);
    if (found == host->windows.end() || !found->second.hwnd) return 0;
    DestroyWindow(found->second.hwnd);
    return 1;
}

size_t zero_native_windows_clipboard_read(Host *host, char *buffer, size_t buffer_len) {
    (void)host;
    if (!buffer || buffer_len == 0 || !OpenClipboard(nullptr)) return 0;
    HANDLE handle = GetClipboardData(CF_TEXT);
    if (!handle) {
        CloseClipboard();
        return 0;
    }
    const char *text = static_cast<const char *>(GlobalLock(handle));
    if (!text) {
        CloseClipboard();
        return 0;
    }
    size_t len = boundedLen(text, buffer_len);
    memcpy(buffer, text, len);
    GlobalUnlock(handle);
    CloseClipboard();
    return len;
}

void zero_native_windows_clipboard_write(Host *host, const char *text, size_t text_len) {
    (void)host;
    if (!OpenClipboard(nullptr)) return;
    EmptyClipboard();
    HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, text_len + 1);
    if (handle) {
        char *dest = static_cast<char *>(GlobalLock(handle));
        memcpy(dest, text, text_len);
        dest[text_len] = '\0';
        GlobalUnlock(handle);
        SetClipboardData(CF_TEXT, handle);
    }
    CloseClipboard();
}

}
