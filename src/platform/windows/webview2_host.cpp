#include <windows.h>
#include <shellapi.h>
#include <commdlg.h>
#include <shlobj.h>
#include <shobjidl.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include <map>
#include <string>

#include "webview2_host_types.h"

// Try to include WebView2 SDK if available; gracefully fall back if not
#ifdef __has_include
#if __has_include(<WebView2.h>)
#define HAVE_WEBVIEW2_SDK 1
#include <wrl.h>
#include <WebView2.h>
using Microsoft::WRL::ComPtr;
#else
#define HAVE_WEBVIEW2_SDK 0
#endif
#else
// For compilers without __has_include, assume SDK is available
#define HAVE_WEBVIEW2_SDK 1
#include <wrl.h>
#include <WebView2.h>
using Microsoft::WRL::ComPtr;
#endif

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
using TrayCallback = void (*)(void *, uint32_t);

struct Window {
    uint64_t id = 1;
    HWND hwnd = nullptr;
    std::string label;
    std::string title;
    double x = 0;
    double y = 0;
    double width = 720;
    double height = 480;
#if HAVE_WEBVIEW2_SDK
    // WebView2 controller and core webview pointers (only when SDK is available)
    Microsoft::WRL::ComPtr<ICoreWebView2Controller> controller;
    Microsoft::WRL::ComPtr<ICoreWebView2> webview;
#endif
};

// Use a custom message for tray notifications to avoid conflicts
#define WM_TRAY_CALLBACK (WM_APP + 1)

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
    TrayCallback tray_callback = nullptr;
    void *tray_context = nullptr;
    bool running = false;
    std::map<uint64_t, Window> windows;
    HWND message_window = nullptr;
    UINT taskbar_created = 0;
    UINT_PTR tray_id_counter = 1;
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
    WINDOWPLACEMENT wp = {};
    wp.length = sizeof(wp);
    if (window.hwnd) GetWindowPlacement(window.hwnd, &wp);
    WindowsEvent event = {};
    event.kind = kind;
    event.window_id = window.id;
    event.width = rect.right > rect.left ? (double)(rect.right - rect.left) : window.width;
    event.height = rect.bottom > rect.top ? (double)(rect.bottom - rect.top) : window.height;
    event.scale = 1.0;
    event.x = (double)wp.rcNormalPosition.left;
    event.y = (double)wp.rcNormalPosition.top;
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
                    if (entry.second.hwnd == hwnd) {
#if HAVE_WEBVIEW2_SDK
                        // Resize WebView2 to match window client area
                        if (entry.second.controller) {
                            RECT bounds;
                            GetClientRect(hwnd, &bounds);
                            entry.second.controller->put_Bounds(bounds);
                        }
#endif
                        emit(host, entry.second, kResize);
                    }
                }
            }
            return 0;
        case WM_SETFOCUS:
        case WM_KILLFOCUS:
            if (host) {
                for (auto &entry : host->windows) {
                    if (entry.second.hwnd == hwnd) emit(host, entry.second, kWindowFrame);
                }
            }
            return 0;
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
        case WM_DESTROY: {
            if (host) {
                for (auto &entry : host->windows) {
                    if (entry.second.hwnd == hwnd) {
#if HAVE_WEBVIEW2_SDK
                        // Clean up WebView2 objects
                        if (entry.second.webview) {
                            entry.second.webview.Reset();
                        }
                        if (entry.second.controller) {
                            entry.second.controller->Close();
                            entry.second.controller.Reset();
                        }
#endif
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
        case WM_NCDESTROY: {
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            return 0;
        }
        case WM_TRAY_CALLBACK:
            if (host && host->tray_callback && lparam == WM_LBUTTONUP) {
                host->tray_callback(host->tray_context, (uint32_t)wparam);
            }
            return 0;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

static LRESULT CALLBACK messageWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_COPYDATA) {
        Host *host = reinterpret_cast<Host *>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
        if (host) {
            COPYDATASTRUCT *cds = reinterpret_cast<COPYDATASTRUCT *>(lparam);
            if (cds && cds->dwData == 0) {
                HWND main_hwnd = nullptr;
                for (auto &entry : host->windows) {
                    if (entry.second.hwnd) { main_hwnd = entry.second.hwnd; break; }
                }
                if (main_hwnd) return CallWindowProcW(reinterpret_cast<WNDPROC>(GetWindowLongPtrW(main_hwnd, GWLP_WNDPROC)), main_hwnd, message, wparam, lparam);
            }
        }
        return 0;
    }
    if (message == WM_TRAY_CALLBACK) {
        Host *host = reinterpret_cast<Host *>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
        if (host && host->tray_callback) {
            if (lparam == WM_LBUTTONUP || lparam == WM_RBUTTONUP) {
                host->tray_callback(host->tray_context, (uint32_t)wparam);
            }
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

static ATOM registerMessageClass(Host *host) {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = messageWindowProc;
    wc.hInstance = host->instance;
    wc.lpszClassName = L"ZeroNativeWindowsMessage";
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

// WebView2 handler structs (C++ structures, defined outside extern "C")
#if HAVE_WEBVIEW2_SDK

struct NavigationStartingHandler : public ICoreWebView2NavigationStartingEventHandler {
    ULONG refCount = 1;
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **ppvObject) override {
        (void)riid;
        if (!ppvObject) return E_POINTER;
        *ppvObject = static_cast<ICoreWebView2NavigationStartingEventHandler*>(this);
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refCount; }
    ULONG STDMETHODCALLTYPE Release() override { ULONG c = --refCount; if (!c) delete this; return c; }
    HRESULT STDMETHODCALLTYPE Invoke(ICoreWebView2 *sender, ICoreWebView2NavigationStartingEventArgs *args) override {
        (void)sender;
        (void)args;
        return S_OK;
    }
};

struct NavigationCompletedHandler : public ICoreWebView2NavigationCompletedEventHandler {
    struct ScriptResultHandler : public ICoreWebView2ExecuteScriptCompletedHandler {
        ULONG refCount = 1;
        HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **ppvObject) override {
            (void)riid;
            if (!ppvObject) return E_POINTER;
            *ppvObject = static_cast<ICoreWebView2ExecuteScriptCompletedHandler*>(this);
            AddRef();
            return S_OK;
        }
        ULONG STDMETHODCALLTYPE AddRef() override { return ++refCount; }
        ULONG STDMETHODCALLTYPE Release() override { ULONG c = --refCount; if (!c) delete this; return c; }
        HRESULT STDMETHODCALLTYPE Invoke(HRESULT errorCode, LPCWSTR resultObjectAsJson) override {
            if (FAILED(errorCode)) {
                fprintf(stderr, "[webview2] execute script failed hr=0x%08lx\n", (unsigned long)errorCode);
                return S_OK;
            }
            fprintf(stderr, "[webview2] root child count json=%ls\n", resultObjectAsJson ? resultObjectAsJson : L"<null>");
            return S_OK;
        }
    };

    ULONG refCount = 1;
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **ppvObject) override {
        (void)riid;
        if (!ppvObject) return E_POINTER;
        *ppvObject = static_cast<ICoreWebView2NavigationCompletedEventHandler*>(this);
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refCount; }
    ULONG STDMETHODCALLTYPE Release() override { ULONG c = --refCount; if (!c) delete this; return c; }
    HRESULT STDMETHODCALLTYPE Invoke(ICoreWebView2 *sender, ICoreWebView2NavigationCompletedEventArgs *args) override {
        (void)sender;
        BOOL success = FALSE;
        if (args) args->get_IsSuccess(&success);
        COREWEBVIEW2_WEB_ERROR_STATUS status = COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN;
        if (args) args->get_WebErrorStatus(&status);
        fprintf(stderr, "[webview2] navigation completed success=%d status=%d\n", success ? 1 : 0, (int)status);
        if (success && sender) {
            sender->ExecuteScript(
                L"(() => { const r = document.getElementById('root'); return r ? r.childElementCount : -1; })()",
                new ScriptResultHandler()
            );
        }
        return S_OK;
    }
};

struct EnvHandler : public ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler {
    ULONG refCount = 1;
    Host *host;
    Window *win;
    std::wstring wsource;
    int source_kind;
    std::string asset_root;
    std::string asset_entry;

    EnvHandler(Host *h, Window *w, std::wstring ws, int kind, const std::string &ar, const std::string &ae) 
        : host(h), win(w), wsource(std::move(ws)), source_kind(kind), asset_root(ar), asset_entry(ae) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **ppvObject) override {
        (void)riid;
        if (!ppvObject) return E_POINTER;
        *ppvObject = static_cast<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*>(this);
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refCount; }
    ULONG STDMETHODCALLTYPE Release() override { ULONG c = --refCount; if (!c) delete this; return c; }

    HRESULT STDMETHODCALLTYPE Invoke(HRESULT result, ICoreWebView2Environment *env) override {
        if (FAILED(result) || !env) return result;
        env->CreateCoreWebView2Controller(win->hwnd, new ControllerHandler(host, win, wsource, source_kind, asset_root, asset_entry));
        return S_OK;
    }

    struct ControllerHandler : public ICoreWebView2CreateCoreWebView2ControllerCompletedHandler {
        ULONG refCount = 1;
        Host *host;
        Window *win;
        std::wstring wsource;
        int source_kind;
        std::string asset_root;
        std::string asset_entry;

        ControllerHandler(Host *h, Window *w, std::wstring ws, int kind, const std::string &ar, const std::string &ae)
            : host(h), win(w), wsource(std::move(ws)), source_kind(kind), asset_root(ar), asset_entry(ae) {}

        HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **ppvObject) override {
            (void)riid;
            if (!ppvObject) return E_POINTER;
            *ppvObject = static_cast<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler*>(this);
            AddRef();
            return S_OK;
        }
        ULONG STDMETHODCALLTYPE AddRef() override { return ++refCount; }
        ULONG STDMETHODCALLTYPE Release() override { ULONG c = --refCount; if (!c) delete this; return c; }

        HRESULT STDMETHODCALLTYPE Invoke(HRESULT result, ICoreWebView2Controller *controller) override {
            if (FAILED(result) || !controller) return result;

            ComPtr<ICoreWebView2Controller> ctrl(controller);
            win->controller = ctrl;

            ComPtr<ICoreWebView2> core;
            ctrl->get_CoreWebView2(&core);
            win->webview = core;

            ComPtr<ICoreWebView2Settings> settings;
            if (SUCCEEDED(core->get_Settings(&settings))) {
                settings->put_IsWebMessageEnabled(TRUE);
                settings->put_IsScriptEnabled(TRUE);
            }

            EventRegistrationToken tokenStart{}, tokenComplete{};
            core->add_NavigationStarting(new NavigationStartingHandler(), &tokenStart);
            core->add_NavigationCompleted(new NavigationCompletedHandler(), &tokenComplete);

            if (source_kind == 1) {
                if (!wsource.empty()) core->Navigate(wsource.c_str());
            } else if (source_kind == 0) {
                core->NavigateToString(wsource.c_str());
            } else if (source_kind == 2) {
                std::wstring wroot = widen(asset_root);
                std::wstring abs_root = wroot;
                if (!wroot.empty()) {
                    DWORD needed = GetFullPathNameW(wroot.c_str(), 0, nullptr, nullptr);
                    if (needed > 0) {
                        std::wstring buffer((size_t)needed, L'\0');
                        DWORD written = GetFullPathNameW(wroot.c_str(), needed, buffer.data(), nullptr);
                        if (written > 0 && written < needed) {
                            buffer.resize((size_t)written);
                            abs_root = std::move(buffer);
                        }
                    }

                    // If the CWD-resolved path doesn't exist, try exe-relative package layout:
                    // <exe_dir>/../resources/<asset_root>
                    DWORD attrs = GetFileAttributesW(abs_root.c_str());
                    if (attrs == INVALID_FILE_ATTRIBUTES || !(attrs & FILE_ATTRIBUTE_DIRECTORY)) {
                        wchar_t exe_path[MAX_PATH];
                        DWORD exe_len = GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
                        if (exe_len > 0 && exe_len < MAX_PATH) {
                            std::wstring exe_dir(exe_path, exe_len);
                            auto sep = exe_dir.find_last_of(L"\\/");
                            if (sep != std::wstring::npos) {
                                exe_dir.resize(sep);
                                std::wstring pkg_candidate = exe_dir + L"\\..\\resources\\" + wroot;
                                DWORD pkg_needed = GetFullPathNameW(pkg_candidate.c_str(), 0, nullptr, nullptr);
                                if (pkg_needed > 0) {
                                    std::wstring pkg_buffer((size_t)pkg_needed, L'\0');
                                    DWORD pkg_written = GetFullPathNameW(pkg_candidate.c_str(), pkg_needed, pkg_buffer.data(), nullptr);
                                    if (pkg_written > 0 && pkg_written < pkg_needed) {
                                        pkg_buffer.resize((size_t)pkg_written);
                                        DWORD pkg_attrs = GetFileAttributesW(pkg_buffer.c_str());
                                        if (pkg_attrs != INVALID_FILE_ATTRIBUTES && (pkg_attrs & FILE_ATTRIBUTE_DIRECTORY)) {
                                            abs_root = std::move(pkg_buffer);
                                            fprintf(stderr, "[webview2] resolved package assets path=%ls\n", abs_root.c_str());
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                std::wstring wpath = abs_root;
                if (!wpath.empty() && wpath.back() != L'/' && wpath.back() != L'\\') {
                    wpath += L'\\';
                }
                wpath += widen(asset_entry);

                // Prefer mapped https origin over file:// to avoid local file/module restrictions.
                HRESULT map_hr = E_NOINTERFACE;
                ICoreWebView2_3 *core3 = nullptr;
                if (core) {
                    map_hr = core->QueryInterface(IID_ICoreWebView2_3, reinterpret_cast<void **>(&core3));
                }

                std::wstring entry_url_path = widen(asset_entry);
                for (auto &ch : entry_url_path) {
                    if (ch == L'\\') ch = L'/';
                }

                bool used_mapped = false;
                if (SUCCEEDED(map_hr) && core3) {
                    HRESULT set_map_hr = core3->SetVirtualHostNameToFolderMapping(
                        L"appassets.local",
                        abs_root.c_str(),
                        COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW
                    );
                    core3->Release();
                    if (SUCCEEDED(set_map_hr)) {
                        std::wstring mapped_url = L"https://appassets.local/";
                        mapped_url += entry_url_path;
                        fprintf(stderr, "[webview2] navigate mapped url=%ls\n", mapped_url.c_str());
                        core->Navigate(mapped_url.c_str());
                        used_mapped = true;
                    }
                }

                if (!used_mapped) {
                    std::wstring url = L"file:///";
                    for (auto c : wpath) {
                        url += (c == L'\\') ? L'/' : c;
                    }
                    fprintf(stderr, "[webview2] navigate url=%ls\n", url.c_str());
                    core->Navigate(url.c_str());
                }
            }

            RECT bounds;
            GetClientRect(win->hwnd, &bounds);
            ctrl->put_Bounds(bounds);

            emit(host, *win, kWindowFrame);
            return S_OK;
        }
    };
};

#endif  // HAVE_WEBVIEW2_SDK

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
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
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
    CoUninitialize();
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

#if HAVE_WEBVIEW2_SDK

void zero_native_windows_load_window_webview(Host *host, uint64_t window_id, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback) {
    if (!host) return;
    auto found = host->windows.find(window_id);
    if (found == host->windows.end()) return;
    Window &win = found->second;

    // Convert source (UTF-8) to wide string for navigation when needed.
    std::wstring wsource;
    if (source && source_len) {
        int wlen = MultiByteToWideChar(CP_UTF8, 0, source, (int)source_len, nullptr, 0);
        if (wlen > 0) {
            wsource.resize(wlen);
            MultiByteToWideChar(CP_UTF8, 0, source, (int)source_len, wsource.data(), wlen);
        }
    }

    // Convert asset paths for file:// URL construction
    std::string asset_root_str(asset_root ? asset_root : "", asset_root_len);
    std::string asset_entry_str(asset_entry ? asset_entry : "", asset_entry_len);

    // Kick off environment creation with the handler defined above.
    CreateCoreWebView2EnvironmentWithOptions(nullptr, nullptr, nullptr, new EnvHandler(host, &win, wsource, source_kind, asset_root_str, asset_entry_str));
}

#else  // !HAVE_WEBVIEW2_SDK

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

#endif  // HAVE_WEBVIEW2_SDK


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

// Dialog/tray support
static void flattenFilters(const char *filters, size_t filters_len, char *buffer, size_t buffer_len, size_t *out_len) {
    *out_len = 0;
    if (!filters || filters_len == 0) return;
    const char *p = filters;
    const char *end = filters + filters_len;
    int need_semicolon = 0;
    while (p < end) {
        // Skip filter name (until first ';')
        while (p < end && *p != ';') p++;
        if (p >= end) break;
        if (need_semicolon && *out_len < buffer_len) {
            buffer[*out_len] = ';';
            (*out_len)++;
        }
        need_semicolon = 0;
        p++; // skip ';'
        // Copy extensions until next filter name (next non-semicolon sequence starting a new filter)
        const char *ext_start = p;
        while (p < end && *p != ';') p++;
        size_t ext_len = (size_t)(p - ext_start);
        if (ext_len > 0) {
            size_t copy_len = ext_len;
            if (copy_len > buffer_len - *out_len) copy_len = buffer_len - *out_len;
            memcpy(buffer + *out_len, ext_start, copy_len);
            *out_len += copy_len;
            need_semicolon = 1;
        }
    }
}

WindowsOpenDialogResult zero_native_windows_show_open_dialog(Host *host, const WindowsOpenDialogOpts *opts, char *buffer, size_t buffer_len) {
    (void)host;
    WindowsOpenDialogResult result = { .count = 0, .bytes_written = 0 };
    IFileOpenDialog *pfd = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&pfd));
    if (FAILED(hr) || !pfd) return result;

    // Set title
    if (opts->title && opts->title_len > 0) {
        wchar_t *wtitle = new wchar_t[opts->title_len + 1];
        MultiByteToWideChar(CP_UTF8, 0, opts->title, (int)opts->title_len, wtitle, (int)opts->title_len + 1);
        pfd->SetTitle(wtitle);
        delete[] wtitle;
    }

    // Set default folder
    if (opts->default_path && opts->default_path_len > 0) {
        wchar_t *wpath = new wchar_t[opts->default_path_len + 1];
        MultiByteToWideChar(CP_UTF8, 0, opts->default_path, (int)opts->default_path_len, wpath, (int)opts->default_path_len + 1);
        IShellItem *psi = nullptr;
        if (SUCCEEDED(SHCreateItemFromParsingName(wpath, nullptr, IID_PPV_ARGS(&psi)))) {
            pfd->SetFolder(psi);
            psi->Release();
        }
        delete[] wpath;
    }

    // Set file type filter
    if (opts->extensions && opts->extensions_len > 0) {
        std::wstring extStr;
        const char *p = opts->extensions;
        const char *end = opts->extensions + opts->extensions_len;
        while (p < end) {
            if (p > opts->extensions) extStr += L";";
            size_t len = 0;
            while (p + len < end && p[len] != ';') len++;
            int wlen = MultiByteToWideChar(CP_UTF8, 0, p, (int)len, nullptr, 0);
            if (wlen > 0) {
                wchar_t *wext = new wchar_t[wlen + 1];
                MultiByteToWideChar(CP_UTF8, 0, p, (int)len, wext, wlen + 1);
                wext[wlen] = L'\0';
                extStr += wext;
                delete[] wext;
            }
            p += len + 1;
        }
        if (!extStr.empty()) {
            COMDLG_FILTERSPEC spec = { extStr.c_str(), extStr.c_str() };
            pfd->SetFileTypes(1, &spec);
        }
    }

    // Set options
    DWORD options = 0;
    if (opts->allow_directories) options |= FOS_PICKFOLDERS;
    if (opts->allow_multiple) options |= FOS_ALLOWMULTISELECT;
    pfd->SetOptions(options);

    hr = pfd->Show(nullptr);
    if (FAILED(hr)) {
        pfd->Release();
        return result;
    }

    IShellItemArray *item_result = nullptr;
    hr = pfd->GetResults(&item_result);
    if (FAILED(hr) || !item_result) {
        pfd->Release();
        return result;
    }

    IEnumShellItems *pEnum = nullptr;
    hr = item_result->EnumItems(&pEnum);
    if (FAILED(hr) || !pEnum) {
        item_result->Release();
        pfd->Release();
        return result;
    }

    size_t offset = 0;
    size_t count = 0;
    IShellItem *item = nullptr;
    while (pEnum->Next(1, &item, nullptr) == S_OK) {
        PWSTR path = nullptr;
        if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) && path) {
            // Convert wide string to UTF-8
            int utf8len = WideCharToMultiByte(CP_UTF8, 0, path, -1, nullptr, 0, nullptr, nullptr);
            if (utf8len > 0) {
                size_t needed = (size_t)(utf8len - 1); // exclude null terminator
                if (offset > 0 && offset < buffer_len) {
                    buffer[offset] = '\n';
                    offset++;
                }
                if (offset + needed <= buffer_len) {
                    WideCharToMultiByte(CP_UTF8, 0, path, -1, buffer + offset, (int)(buffer_len - offset), nullptr, nullptr);
                    offset += needed;
                    count++;
                }
            }
            CoTaskMemFree(path);
        }
        item->Release();
    }

    pEnum->Release();
    item_result->Release();
    pfd->Release();
    result.count = count;
    result.bytes_written = offset;
    return result;
}

size_t zero_native_windows_show_save_dialog(Host *host, const WindowsSaveDialogOpts *opts, char *buffer, size_t buffer_len) {
    (void)host;
    IFileDialog *pfd = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&pfd));
    if (FAILED(hr) || !pfd) return 0;

    if (opts->title && opts->title_len > 0) {
        wchar_t *wtitle = new wchar_t[opts->title_len + 1];
        MultiByteToWideChar(CP_UTF8, 0, opts->title, (int)opts->title_len, wtitle, (int)opts->title_len + 1);
        pfd->SetTitle(wtitle);
        delete[] wtitle;
    }

    if (opts->default_path && opts->default_path_len > 0) {
        wchar_t *wpath = new wchar_t[opts->default_path_len + 1];
        MultiByteToWideChar(CP_UTF8, 0, opts->default_path, (int)opts->default_path_len, wpath, (int)opts->default_path_len + 1);
        IShellItem *psi = nullptr;
        if (SUCCEEDED(SHCreateItemFromParsingName(wpath, nullptr, IID_PPV_ARGS(&psi)))) {
            pfd->SetFolder(psi);
            psi->Release();
        }
        delete[] wpath;
    }

    if (opts->default_name && opts->default_name_len > 0) {
        wchar_t *wname = new wchar_t[opts->default_name_len + 1];
        MultiByteToWideChar(CP_UTF8, 0, opts->default_name, (int)opts->default_name_len, wname, (int)opts->default_name_len + 1);
        pfd->SetFileName(wname);
        delete[] wname;
    }

    if (opts->extensions && opts->extensions_len > 0) {
        std::wstring extStr;
        const char *p = opts->extensions;
        const char *end = opts->extensions + opts->extensions_len;
        while (p < end) {
            if (p > opts->extensions) extStr += L";";
            size_t len = 0;
            while (p + len < end && p[len] != ';') len++;
            int wlen = MultiByteToWideChar(CP_UTF8, 0, p, (int)len, nullptr, 0);
            if (wlen > 0) {
                wchar_t *wext = new wchar_t[wlen + 1];
                MultiByteToWideChar(CP_UTF8, 0, p, (int)len, wext, wlen + 1);
                wext[wlen] = L'\0';
                extStr += wext;
                delete[] wext;
            }
            p += len + 1;
        }
        if (!extStr.empty()) {
            COMDLG_FILTERSPEC spec = { extStr.c_str(), extStr.c_str() };
            pfd->SetFileTypes(1, &spec);
        }
    }

    hr = pfd->Show(nullptr);
    if (FAILED(hr)) {
        pfd->Release();
        return 0;
    }

    IShellItem *result = nullptr;
    hr = pfd->GetResult(&result);
    if (FAILED(hr) || !result) {
        pfd->Release();
        return 0;
    }

    PWSTR path = nullptr;
    size_t written = 0;
    if (SUCCEEDED(result->GetDisplayName(SIGDN_FILESYSPATH, &path)) && path) {
        int utf8len = WideCharToMultiByte(CP_UTF8, 0, path, -1, nullptr, 0, nullptr, nullptr);
        if (utf8len > 0) {
            written = (size_t)(utf8len - 1);
            if (written > buffer_len) written = buffer_len;
            WideCharToMultiByte(CP_UTF8, 0, path, -1, buffer, (int)buffer_len, nullptr, nullptr);
        }
        CoTaskMemFree(path);
    }

    result->Release();
    pfd->Release();
    return written;
}

int zero_native_windows_show_message_dialog(Host *host, const WindowsMessageDialogOpts *opts) {
    (void)host;
    UINT type = MB_OK;
    if (opts->style == 1) type = MB_ICONWARNING | MB_OK;
    else if (opts->style == 2) type = MB_ICONERROR | MB_OK;
    else type = MB_ICONINFORMATION | MB_OK;

    std::wstring wmsg;
    if (opts->informative_text && opts->informative_text_len > 0) {
        int len = MultiByteToWideChar(CP_UTF8, 0, opts->informative_text, (int)opts->informative_text_len, nullptr, 0);
        if (len > 0) {
            wchar_t *buf = new wchar_t[len + 1];
            MultiByteToWideChar(CP_UTF8, 0, opts->informative_text, (int)opts->informative_text_len, buf, len);
            buf[len] = L'\0';
            wmsg += buf;
            delete[] buf;
        }
    }
    if (opts->message && opts->message_len > 0) {
        if (!wmsg.empty()) wmsg += L"\n\n";
        int len = MultiByteToWideChar(CP_UTF8, 0, opts->message, (int)opts->message_len, nullptr, 0);
        if (len > 0) {
            wchar_t *buf = new wchar_t[len + 1];
            MultiByteToWideChar(CP_UTF8, 0, opts->message, (int)opts->message_len, buf, len);
            buf[len] = L'\0';
            wmsg += buf;
            delete[] buf;
        }
    }

    std::wstring wtitle;
    if (opts->title && opts->title_len > 0) {
        int len = MultiByteToWideChar(CP_UTF8, 0, opts->title, (int)opts->title_len, nullptr, 0);
        if (len > 0) {
            wchar_t *buf = new wchar_t[len + 1];
            MultiByteToWideChar(CP_UTF8, 0, opts->title, (int)opts->title_len, buf, len);
            buf[len] = L'\0';
            wtitle = buf;
            delete[] buf;
        }
    }

    int result = MessageBoxW(nullptr, wmsg.c_str(), wtitle.c_str(), type);
    if (result == IDOK) return 0;
    if (result == IDCANCEL) return 1;
    return 2;
}

void zero_native_windows_create_tray(Host *host, const char *icon_path, size_t icon_path_len, const char *tooltip, size_t tooltip_len) {
    if (!host) return;

    // Create a hidden message window for tray messages
    if (!host->message_window) {
        registerMessageClass(host);
        host->message_window = CreateWindowExW(
            0, L"ZeroNativeWindowsMessage", L"", 0, 0, 0, 0, 0,
            HWND_MESSAGE, nullptr, host->instance, host);
        if (host->message_window) {
            SetWindowLongPtrW(host->message_window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(host));
        }
    }

    NOTIFYICONDATAW nid = {};
    nid.cbSize = sizeof(nid);
    nid.hWnd = host->message_window ? host->message_window : (host->windows.begin()->second.hwnd);
    nid.uID = 1;
    nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    nid.uCallbackMessage = WM_TRAY_CALLBACK;

    if (icon_path && icon_path_len > 0) {
        wchar_t *wicon = new wchar_t[icon_path_len + 1];
        MultiByteToWideChar(CP_UTF8, 0, icon_path, (int)icon_path_len, wicon, (int)icon_path_len + 1);
        HICON icon = (HICON)LoadImageW(nullptr, wicon, IMAGE_ICON, 0, 0, LR_LOADFROMFILE);
        if (icon) {
            nid.hIcon = icon;
            Shell_NotifyIconW(NIM_ADD, &nid);
            DestroyIcon(icon);
        }
        delete[] wicon;
    }

    if (tooltip && tooltip_len > 0) {
        MultiByteToWideChar(CP_UTF8, 0, tooltip, (int)tooltip_len, nid.szTip, (int)std::min(tooltip_len, (size_t)127));
    }
}

void zero_native_windows_update_tray_menu(Host *host, const uint32_t *item_ids, const char *const *labels, const size_t *label_lens, const int *separators, const int *enabled_flags, size_t count) {
    (void)host;
    (void)item_ids;
    (void)labels;
    (void)label_lens;
    (void)separators;
    (void)enabled_flags;
    (void)count;
    // Menu construction would require HMENU; this is a simplified stub.
    // Full implementation would track the HMENU and rebuild on updates.
}

void zero_native_windows_remove_tray(Host *host) {
    if (!host) return;
    NOTIFYICONDATAW nid = {};
    nid.cbSize = sizeof(nid);
    nid.hWnd = host->message_window ? host->message_window : (host->windows.begin()->second.hwnd);
    nid.uID = 1;
    Shell_NotifyIconW(NIM_DELETE, &nid);

    if (host->message_window) {
        DestroyWindow(host->message_window);
        host->message_window = nullptr;
    }
}

void zero_native_windows_set_tray_callback(Host *host, TrayCallback callback, void *context) {
    if (!host) return;
    host->tray_callback = callback;
    host->tray_context = context;
}

}