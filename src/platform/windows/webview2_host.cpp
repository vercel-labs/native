#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wincred.h>
#include <objbase.h>
#include <commctrl.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include <algorithm>
#include <cctype>
#include <climits>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#if __has_include(<WebView2.h>) && __has_include(<wrl.h>)
#include <WebView2.h>
#include <wrl.h>
#define ZERO_NATIVE_HAS_WEBVIEW2 1
using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
#else
#define ZERO_NATIVE_HAS_WEBVIEW2 0
#endif

namespace {

enum EventKind {
    kStart = 0,
    kFrame = 1,
    kShutdown = 2,
    kResize = 3,
    kWindowFrame = 4,
    kShortcut = 5,
    kNativeCommand = 6,
    kAppActivated = 7,
    kAppDeactivated = 8,
    kFilesDropped = 9,
    kMenuCommand = 10,
    kTrayAction = 11,
};

constexpr uint32_t kShortcutModifierPrimary = 1u << 0;
constexpr uint32_t kShortcutModifierCommand = 1u << 1;
constexpr uint32_t kShortcutModifierControl = 1u << 2;
constexpr uint32_t kShortcutModifierOption = 1u << 3;
constexpr uint32_t kShortcutModifierShift = 1u << 4;
constexpr size_t kMaxShortcuts = 64;
constexpr uint32_t kMenuCommandBase = 0x4000;
constexpr uint32_t kTrayCommandBase = 0x5000;
constexpr UINT kNotificationCallbackMessage = WM_APP + 42;

constexpr int kViewWebView = 0;
constexpr int kViewToolbar = 1;
constexpr int kViewTitlebarAccessory = 2;
constexpr int kViewSidebar = 3;
constexpr int kViewStatusbar = 4;
constexpr int kViewSplit = 5;
constexpr int kViewStack = 6;
constexpr int kViewButton = 7;
constexpr int kViewTextField = 8;
constexpr int kViewSearchField = 9;
constexpr int kViewLabel = 10;
constexpr int kViewSpacer = 11;
constexpr int kViewGpuSurface = 12;
constexpr int kViewCheckbox = 13;
constexpr int kViewToggle = 14;
constexpr int kViewProgressIndicator = 15;
constexpr int kViewSegmentedControl = 16;
constexpr int kViewIconButton = 17;

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
    const char *shortcut_id;
    size_t shortcut_id_len;
    const char *shortcut_key;
    size_t shortcut_key_len;
    uint32_t shortcut_modifiers;
    const char *command_name;
    size_t command_name_len;
    const char *view_label;
    size_t view_label_len;
    const char *drop_paths;
    size_t drop_paths_len;
    uint32_t tray_item_id;
};

struct WindowsOpenDialogOpts {
    const char *title;
    size_t title_len;
    const char *default_path;
    size_t default_path_len;
    const char *extensions;
    size_t extensions_len;
    int allow_directories;
    int allow_multiple;
};

struct WindowsOpenDialogResult {
    size_t count;
    size_t bytes_written;
};

struct WindowsSaveDialogOpts {
    const char *title;
    size_t title_len;
    const char *default_path;
    size_t default_path_len;
    const char *default_name;
    size_t default_name_len;
    const char *extensions;
    size_t extensions_len;
};

struct WindowsMessageDialogOpts {
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
};

using EventCallback = void (*)(void *, const WindowsEvent *);
using BridgeCallback = void (*)(void *, uint64_t, const char *, size_t, const char *, size_t, const char *, size_t);

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

struct ChildWebView {
    uint64_t window_id = 1;
    HWND hwnd = nullptr;
    std::string label;
    std::string url;
    double x = 0;
    double y = 0;
    double width = 0;
    double height = 0;
    double zoom = 1.0;
    int layer = 0;
    uint64_t creation_order = 0;
    bool transparent = false;
    bool bridge_enabled = false;
#if ZERO_NATIVE_HAS_WEBVIEW2
    ComPtr<ICoreWebView2Controller> controller;
    ComPtr<ICoreWebView2> webview;
#endif
};

struct NativeView {
    uint64_t window_id = 1;
    HWND hwnd = nullptr;
    std::string label;
    std::string parent;
    std::string role;
    std::string accessibility_label;
    std::string text;
    std::string command;
    double x = 0;
    double y = 0;
    double width = 0;
    double height = 0;
    int kind = kViewLabel;
    int layer = 0;
    uint64_t creation_order = 0;
    bool visible = true;
    bool enabled = true;
    bool explicit_text = false;
};

struct Shortcut {
    std::string id;
    std::string key;
    uint32_t modifiers = 0;
};

struct MenuItem {
    std::string label;
    std::string command;
    std::string key;
    uint32_t modifiers = 0;
    uint32_t command_id = 0;
    bool separator = false;
    bool enabled = true;
    bool checked = false;
};

struct Menu {
    std::string title;
    std::vector<MenuItem> items;
};

struct TrayItem {
    uint32_t id = 0;
    std::string label;
    uint32_t command_id = 0;
    bool separator = false;
    bool enabled = true;
};

struct HostLifetime {
    std::recursive_mutex mutex;
    bool alive = true;
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
    std::map<std::string, ChildWebView> webviews;
    std::map<std::string, NativeView> native_views;
    uint64_t next_child_order = 1;
    std::vector<std::string> allowed_origins;
    std::vector<std::string> allowed_external_urls;
    std::vector<Shortcut> shortcuts;
    std::vector<Menu> menus;
    std::map<uint32_t, std::string> menu_commands;
    std::vector<TrayItem> tray_items;
    int external_link_action = 0;
    bool app_active = false;
    bool notification_icon_added = false;
    bool tray_active = false;
    std::shared_ptr<HostLifetime> lifetime = std::make_shared<HostLifetime>();
};

static std::string slice(const char *bytes, size_t len) {
    return bytes && len > 0 ? std::string(bytes, len) : std::string();
}

static std::string jsonStringLiteral(const std::string &value) {
    static const char hex[] = "0123456789abcdef";
    std::string out;
    out.reserve(value.size() + 2);
    out.push_back('"');
    for (unsigned char ch : value) {
        switch (ch) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (ch < 0x20) {
                    out += "\\u00";
                    out.push_back(hex[(ch >> 4) & 0xf]);
                    out.push_back(hex[ch & 0xf]);
                } else {
                    out.push_back(static_cast<char>(ch));
                }
                break;
        }
    }
    out.push_back('"');
    return out;
}

static std::wstring widen(const std::string &value) {
    if (value.empty()) return std::wstring();
    int count = MultiByteToWideChar(CP_UTF8, 0, value.data(), (int)value.size(), nullptr, 0);
    std::wstring out((size_t)count, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, value.data(), (int)value.size(), out.data(), count);
    return out;
}

static std::wstring credentialTarget(const std::string &service, const std::string &account) {
    std::wstring service_wide = widen(service);
    std::wstring account_wide = widen(account);
    return L"zero-native:" + std::to_wstring(service_wide.size()) + L":" + service_wide + account_wide;
}

static std::string narrow(const std::wstring &value) {
    if (value.empty()) return std::string();
    int count = WideCharToMultiByte(CP_UTF8, 0, value.data(), (int)value.size(), nullptr, 0, nullptr, nullptr);
    std::string out((size_t)count, '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.data(), (int)value.size(), out.data(), count, nullptr, nullptr);
    return out;
}

static HWND parentWindow(Host *host) {
    if (!host) return nullptr;
    for (auto &entry : host->windows) {
        if (entry.second.hwnd) return entry.second.hwnd;
    }
    return nullptr;
}

static void copyWideField(wchar_t *dest, size_t dest_len, const std::wstring &value) {
    if (!dest || dest_len == 0) return;
    size_t count = std::min(value.size(), dest_len - 1);
    if (count > 0) memcpy(dest, value.data(), count * sizeof(wchar_t));
    dest[count] = L'\0';
}

static NOTIFYICONDATAW notificationIconData(Host *host) {
    NOTIFYICONDATAW data = {};
    data.cbSize = sizeof(data);
    data.hWnd = parentWindow(host);
    data.uID = 1;
    return data;
}

static HICON loadNotificationIcon(Host *host, const std::string &icon_path, bool *destroy_icon) {
    *destroy_icon = false;
    std::string path = !icon_path.empty() ? icon_path : (host ? host->icon_path : std::string());
    if (!path.empty()) {
        std::wstring wide_path = widen(path);
        HICON icon = reinterpret_cast<HICON>(LoadImageW(nullptr, wide_path.c_str(), IMAGE_ICON, 0, 0, LR_LOADFROMFILE | LR_DEFAULTSIZE));
        if (icon) {
            *destroy_icon = true;
            return icon;
        }
    }
    return LoadIconW(nullptr, MAKEINTRESOURCEW(32512));
}

static bool setNotificationIcon(Host *host, const std::string &icon_path, const std::string &tooltip, bool update_existing) {
    if (!host) return false;
    if (host->notification_icon_added && !update_existing) return true;
    NOTIFYICONDATAW data = notificationIconData(host);
    if (!data.hWnd) return false;
    data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    data.uCallbackMessage = kNotificationCallbackMessage;
    bool destroy_icon = false;
    data.hIcon = loadNotificationIcon(host, icon_path, &destroy_icon);
    std::wstring tip = widen(!tooltip.empty() ? tooltip : (host->app_name.empty() ? std::string("zero-native") : host->app_name));
    copyWideField(data.szTip, ARRAYSIZE(data.szTip), tip);
    BOOL ok = Shell_NotifyIconW(host->notification_icon_added ? NIM_MODIFY : NIM_ADD, &data);
    if (destroy_icon && data.hIcon) DestroyIcon(data.hIcon);
    if (!ok) return false;
    if (!host->notification_icon_added) {
        data.uVersion = NOTIFYICON_VERSION_4;
        Shell_NotifyIconW(NIM_SETVERSION, &data);
    }
    host->notification_icon_added = true;
    return true;
}

static bool ensureNotificationIcon(Host *host) {
    return setNotificationIcon(host, std::string(), std::string(), false);
}

static void removeNotificationIcon(Host *host) {
    if (!host || !host->notification_icon_added) return;
    NOTIFYICONDATAW data = notificationIconData(host);
    if (data.hWnd) Shell_NotifyIconW(NIM_DELETE, &data);
    host->notification_icon_added = false;
}

static bool initializeCom(bool *uninitialize) {
    *uninitialize = false;
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    if (SUCCEEDED(hr)) {
        *uninitialize = true;
        return true;
    }
    return false;
}

static void finishCom(bool uninitialize) {
    if (uninitialize) CoUninitialize();
}

static void setDialogTitle(IFileDialog *dialog, const char *title, size_t title_len) {
    if (!dialog || !title || title_len == 0) return;
    std::wstring title_wide = widen(slice(title, title_len));
    if (!title_wide.empty()) dialog->SetTitle(title_wide.c_str());
}

static void setDialogFolder(IFileDialog *dialog, const char *path, size_t path_len) {
    if (!dialog || !path || path_len == 0) return;
    std::wstring path_wide = widen(slice(path, path_len));
    if (path_wide.empty()) return;
    IShellItem *folder = nullptr;
    if (SUCCEEDED(SHCreateItemFromParsingName(path_wide.c_str(), nullptr, IID_PPV_ARGS(&folder))) && folder) {
        dialog->SetFolder(folder);
        folder->Release();
    }
}

static std::wstring fileDialogPattern(const char *extensions, size_t extensions_len) {
    std::string flat = slice(extensions, extensions_len);
    std::wstring pattern;
    size_t start = 0;
    while (start < flat.size()) {
        size_t end = flat.find(';', start);
        if (end == std::string::npos) end = flat.size();
        std::string ext = flat.substr(start, end - start);
        while (!ext.empty() && (ext.front() == ' ' || ext.front() == '\t')) ext.erase(ext.begin());
        while (!ext.empty() && (ext.back() == ' ' || ext.back() == '\t' || ext.back() == '\r')) ext.pop_back();
        if (!ext.empty()) {
            if (!pattern.empty()) pattern += L";";
            if (ext.find('*') != std::string::npos) {
                pattern += widen(ext);
            } else if (!ext.empty() && ext.front() == '.') {
                pattern += L"*" + widen(ext);
            } else {
                pattern += L"*." + widen(ext);
            }
        }
        start = end + 1;
    }
    return pattern;
}

static void setDialogFilters(IFileDialog *dialog, const char *extensions, size_t extensions_len) {
    std::wstring pattern = fileDialogPattern(extensions, extensions_len);
    if (!dialog || pattern.empty()) return;
    COMDLG_FILTERSPEC specs[2] = {
        { L"Matching files", pattern.c_str() },
        { L"All files", L"*.*" },
    };
    dialog->SetFileTypes(2, specs);
    dialog->SetFileTypeIndex(1);
}

static bool appendPathToBuffer(char *buffer, size_t buffer_len, size_t *offset, size_t *count, const std::wstring &path_wide) {
    std::string path = narrow(path_wide);
    if (path.empty()) return false;
    size_t needed = path.size() + (*count > 0 ? 1 : 0);
    if (*offset + needed > buffer_len) return false;
    if (*count > 0) buffer[(*offset)++] = '\n';
    memcpy(buffer + *offset, path.data(), path.size());
    *offset += path.size();
    *count += 1;
    return true;
}

static std::vector<std::string> parseNewlineList(const char *bytes, size_t len) {
    std::vector<std::string> result;
    if (!bytes || len == 0) return result;
    const char *start = bytes;
    const char *end = bytes + len;
    while (start < end) {
        const char *nl = static_cast<const char *>(memchr(start, '\n', (size_t)(end - start)));
        size_t seg_len = nl ? (size_t)(nl - start) : (size_t)(end - start);
        while (seg_len > 0 && (*start == ' ' || *start == '\t')) {
            ++start;
            --seg_len;
        }
        while (seg_len > 0 && (start[seg_len - 1] == ' ' || start[seg_len - 1] == '\t' || start[seg_len - 1] == '\r')) --seg_len;
        if (seg_len > 0) result.emplace_back(start, seg_len);
        start = nl ? nl + 1 : end;
    }
    return result;
}

static std::string originForUrl(const std::string &url) {
    if (url.empty() || url.rfind("about:", 0) == 0) return "zero://inline";
    size_t scheme_end = url.find("://");
    if (scheme_end == std::string::npos) return "zero://inline";
    if (url.compare(0, scheme_end, "file") == 0) return "file://local";
    size_t host_start = scheme_end + 3;
    size_t host_end = host_start;
    while (host_end < url.size() && url[host_end] != '/' && url[host_end] != '?' && url[host_end] != '#') ++host_end;
    if (host_end == host_start) return url.substr(0, scheme_end) + "://local";
    return url.substr(0, host_end);
}

static bool policyListMatches(const std::vector<std::string> &values, const std::string &url) {
    std::string origin = originForUrl(url);
    for (const std::string &value : values) {
        if (value == "*" || value == origin || value == url) return true;
        if (!value.empty() && value.back() == '*') {
            const std::string prefix = value.substr(0, value.size() - 1);
            if (url.rfind(prefix, 0) == 0 || origin.rfind(prefix, 0) == 0) return true;
        }
    }
    return false;
}

static size_t boundedWideLen(const wchar_t *text, size_t limit) {
    size_t len = 0;
    while (len < limit && text[len] != L'\0') ++len;
    return len;
}

static size_t copyBytesToBuffer(char *buffer, size_t buffer_len, const std::string &bytes) {
    if (!buffer || buffer_len == 0) return 0;
    size_t len = std::min(buffer_len, bytes.size());
    if (len > 0) memcpy(buffer, bytes.data(), len);
    return len;
}

static std::string lowerAscii(std::string value) {
    for (char &ch : value) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    return value;
}

static UINT htmlClipboardFormat() {
    static UINT format = RegisterClipboardFormatA("HTML Format");
    return format;
}

static UINT rtfClipboardFormat() {
    static UINT format = RegisterClipboardFormatA("Rich Text Format");
    return format;
}

static UINT clipboardFormatForMime(const char *mime_type, size_t mime_type_len) {
    std::string mime = lowerAscii(slice(mime_type, mime_type_len));
    if (mime == "text" || mime == "text/plain") return CF_UNICODETEXT;
    if (mime == "text/html") return htmlClipboardFormat();
    if (mime == "text/rtf" || mime == "application/rtf") return rtfClipboardFormat();
    return 0;
}

static bool patchCfHtmlOffset(std::string &header, const char *key, size_t value) {
    size_t index = header.find(key);
    if (index == std::string::npos) return false;
    index += strlen(key);
    if (index + 10 > header.size()) return false;
    char digits[11] = {};
    snprintf(digits, sizeof(digits), "%010zu", value);
    header.replace(index, 10, digits);
    return true;
}

static std::string htmlClipboardPayload(const std::string &fragment) {
    const std::string start_marker = "<!--StartFragment-->";
    const std::string end_marker = "<!--EndFragment-->";
    const std::string html_prefix = "<html><body>" + start_marker;
    const std::string html_suffix = end_marker + "</body></html>";
    std::string header =
        "Version:0.9\r\n"
        "StartHTML:0000000000\r\n"
        "EndHTML:0000000000\r\n"
        "StartFragment:0000000000\r\n"
        "EndFragment:0000000000\r\n";
    std::string html = html_prefix + fragment + html_suffix;
    size_t start_html = header.size();
    size_t start_fragment = start_html + html_prefix.size();
    size_t end_fragment = start_fragment + fragment.size();
    size_t end_html = start_html + html.size();
    patchCfHtmlOffset(header, "StartHTML:", start_html);
    patchCfHtmlOffset(header, "EndHTML:", end_html);
    patchCfHtmlOffset(header, "StartFragment:", start_fragment);
    patchCfHtmlOffset(header, "EndFragment:", end_fragment);
    return header + html;
}

static bool parseCfHtmlOffset(const std::string &payload, const char *key, size_t *out) {
    size_t index = payload.find(key);
    if (index == std::string::npos) return false;
    index += strlen(key);
    size_t value = 0;
    size_t digits = 0;
    while (index < payload.size() && payload[index] >= '0' && payload[index] <= '9') {
        value = value * 10 + static_cast<size_t>(payload[index] - '0');
        index++;
        digits++;
    }
    if (digits == 0) return false;
    *out = value;
    return true;
}

static std::string extractHtmlClipboardFragment(const std::string &payload) {
    size_t start = 0;
    size_t end = 0;
    if (parseCfHtmlOffset(payload, "StartFragment:", &start) &&
        parseCfHtmlOffset(payload, "EndFragment:", &end) &&
        start <= end &&
        end <= payload.size()) {
        return payload.substr(start, end - start);
    }
    return payload;
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

static void emitFileDrop(Host *host, const Window &window, const std::string &paths) {
    if (!host || !host->callback || paths.empty()) return;
    WindowsEvent event = {};
    event.kind = kFilesDropped;
    event.window_id = window.id;
    event.drop_paths = paths.c_str();
    event.drop_paths_len = paths.size();
    host->callback(host->callback_context, &event);
}

static std::string droppedFilePaths(HDROP drop) {
    std::string paths;
    UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
    for (UINT index = 0; index < count; ++index) {
        UINT len = DragQueryFileW(drop, index, nullptr, 0);
        if (len == 0) continue;
        std::wstring path((size_t)len + 1, L'\0');
        DragQueryFileW(drop, index, path.data(), len + 1);
        path.resize(len);
        std::string utf8_path = narrow(path);
        if (utf8_path.empty()) continue;
        if (!paths.empty()) paths.push_back('\n');
        paths += utf8_path;
    }
    return paths;
}

static std::string shortcutKeyFromWParam(WPARAM wparam) {
    if (wparam >= 'A' && wparam <= 'Z') return std::string(1, static_cast<char>('a' + (wparam - 'A')));
    if (wparam >= '0' && wparam <= '9') return std::string(1, static_cast<char>(wparam));
    switch (wparam) {
        case VK_ESCAPE: return "escape";
        case VK_RETURN: return "enter";
        case VK_TAB: return "tab";
        case VK_SPACE: return "space";
        case VK_BACK: return "backspace";
        case VK_LEFT: return "arrowleft";
        case VK_RIGHT: return "arrowright";
        case VK_UP: return "arrowup";
        case VK_DOWN: return "arrowdown";
        case VK_OEM_PLUS: return "=";
        case VK_OEM_MINUS: return "-";
        case VK_OEM_COMMA: return ",";
        case VK_OEM_PERIOD: return ".";
        case VK_OEM_2: return "/";
        case VK_OEM_1: return ";";
        case VK_OEM_7: return "'";
        case VK_OEM_4: return "[";
        case VK_OEM_6: return "]";
        case VK_OEM_5: return "\\";
        case VK_OEM_3: return "`";
        default: return std::string();
    }
}

static bool keyDown(int virtual_key) {
    return (GetKeyState(virtual_key) & 0x8000) != 0;
}

static bool shortcutKeyCanUseImplicitShift(const std::string &key) {
    if (key.size() != 1) return false;
    char ch = key[0];
    return (ch >= '0' && ch <= '9') ||
        ch == '=' || ch == '-' || ch == ',' ||
        ch == '.' || ch == '/' || ch == ';' || ch == '\'' ||
        ch == '[' || ch == ']' || ch == '\\' || ch == '`';
}

static bool shortcutModifiersMatch(uint32_t shortcut_modifiers, bool allow_implicit_shift) {
    bool needs_control = (shortcut_modifiers & kShortcutModifierControl) != 0 ||
        (shortcut_modifiers & kShortcutModifierPrimary) != 0;
    bool needs_command = (shortcut_modifiers & kShortcutModifierCommand) != 0;
    bool needs_option = (shortcut_modifiers & kShortcutModifierOption) != 0;
    bool needs_shift = (shortcut_modifiers & kShortcutModifierShift) != 0;
    bool has_control = keyDown(VK_CONTROL);
    bool has_command = keyDown(VK_LWIN) || keyDown(VK_RWIN);
    bool has_option = keyDown(VK_MENU);
    bool has_shift = keyDown(VK_SHIFT);
    bool shift_matches = needs_shift ? has_shift : (!has_shift || allow_implicit_shift);
    return has_control == needs_control &&
        has_command == needs_command &&
        has_option == needs_option &&
        shift_matches;
}

static const Window *windowForId(Host *host, uint64_t window_id) {
    if (!host) return nullptr;
    auto found = host->windows.find(window_id);
    if (found == host->windows.end()) return nullptr;
    return &found->second;
}

static const Window *windowForHwnd(Host *host, HWND hwnd) {
    if (!host) return nullptr;
    for (auto &entry : host->windows) {
        if (entry.second.hwnd == hwnd) return &entry.second;
    }
    return nullptr;
}

static std::string shortcutKeyLabel(const std::string &key) {
    if (key.size() == 1) {
        char ch = key[0];
        return std::string(1, static_cast<char>(std::toupper(static_cast<unsigned char>(ch))));
    }
    if (key == "escape") return "Esc";
    if (key == "enter") return "Enter";
    if (key == "tab") return "Tab";
    if (key == "space") return "Space";
    if (key == "backspace") return "Backspace";
    if (key == "arrowleft") return "Left";
    if (key == "arrowright") return "Right";
    if (key == "arrowup") return "Up";
    if (key == "arrowdown") return "Down";
    return key;
}

static std::string menuShortcutSuffix(const MenuItem &item) {
    if (item.key.empty()) return std::string();
    std::string suffix = "\t";
    bool has_prefix = false;
    auto append = [&](const char *value) {
        if (has_prefix) suffix += "+";
        suffix += value;
        has_prefix = true;
    };
    if ((item.modifiers & kShortcutModifierPrimary) != 0 || (item.modifiers & kShortcutModifierControl) != 0) append("Ctrl");
    if ((item.modifiers & kShortcutModifierCommand) != 0) append("Win");
    if ((item.modifiers & kShortcutModifierOption) != 0) append("Alt");
    if ((item.modifiers & kShortcutModifierShift) != 0) append("Shift");
    if (has_prefix) suffix += "+";
    suffix += shortcutKeyLabel(item.key);
    return suffix;
}

static HMENU buildMenuBar(Host *host) {
    if (!host || host->menus.empty()) return nullptr;
    HMENU menu_bar = CreateMenu();
    if (!menu_bar) return nullptr;

    for (const Menu &menu : host->menus) {
        HMENU popup = CreatePopupMenu();
        if (!popup) {
            DestroyMenu(menu_bar);
            return nullptr;
        }
        for (const MenuItem &item : menu.items) {
            if (item.separator) {
                AppendMenuW(popup, MF_SEPARATOR, 0, nullptr);
                continue;
            }
            UINT flags = MF_STRING;
            if (!item.enabled) flags |= MF_GRAYED;
            if (item.checked) flags |= MF_CHECKED;
            std::wstring label = widen(item.label + menuShortcutSuffix(item));
            AppendMenuW(popup, flags, item.command_id, label.c_str());
        }
        std::wstring title = widen(menu.title);
        AppendMenuW(menu_bar, MF_POPUP, reinterpret_cast<UINT_PTR>(popup), title.c_str());
    }

    return menu_bar;
}

static void applyMenusToWindow(Host *host, Window &window) {
    if (!host || !window.hwnd) return;
    HMENU old_menu = GetMenu(window.hwnd);
    HMENU new_menu = buildMenuBar(host);
    SetMenu(window.hwnd, new_menu);
    DrawMenuBar(window.hwnd);
    if (old_menu) DestroyMenu(old_menu);
}

static bool emitMenuCommandForId(Host *host, HWND hwnd, uint32_t command_id) {
    if (!host || !host->callback) return false;
    auto found = host->menu_commands.find(command_id);
    if (found == host->menu_commands.end()) return false;
    const Window *window = windowForHwnd(host, hwnd);
    if (!window) return false;
    WindowsEvent event = {};
    event.kind = kMenuCommand;
    event.window_id = window->id;
    event.command_name = found->second.c_str();
    event.command_name_len = found->second.size();
    host->callback(host->callback_context, &event);
    return true;
}

static bool emitTrayActionForCommandId(Host *host, uint32_t command_id) {
    if (!host || !host->callback) return false;
    for (const TrayItem &item : host->tray_items) {
        if (item.separator || item.command_id != command_id) continue;
        WindowsEvent event = {};
        event.kind = kTrayAction;
        event.tray_item_id = item.id;
        host->callback(host->callback_context, &event);
        return true;
    }
    return false;
}

static void showTrayMenu(Host *host, HWND hwnd) {
    if (!host || !host->tray_active || host->tray_items.empty() || !hwnd) return;
    HMENU menu = CreatePopupMenu();
    if (!menu) return;
    for (const TrayItem &item : host->tray_items) {
        if (item.separator) {
            AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
            continue;
        }
        UINT flags = MF_STRING;
        if (!item.enabled) flags |= MF_GRAYED;
        std::wstring label = widen(item.label);
        AppendMenuW(menu, flags, item.command_id, label.c_str());
    }
    POINT cursor = {};
    GetCursorPos(&cursor);
    SetForegroundWindow(hwnd);
    UINT command_id = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, hwnd, nullptr);
    DestroyMenu(menu);
    if (command_id != 0) emitTrayActionForCommandId(host, command_id);
    PostMessageW(hwnd, WM_NULL, 0, 0);
}

static bool emitShortcutForWindow(Host *host, const Window *window, WPARAM wparam) {
    if (!host || host->shortcuts.empty()) return false;
    if (!window) return false;
    std::string key = shortcutKeyFromWParam(wparam);
    if (key.empty()) return false;
    bool uses_implicit_shift = keyDown(VK_SHIFT) && shortcutKeyCanUseImplicitShift(key);
    const int pass_count = uses_implicit_shift ? 2 : 1;
    for (int pass = 0; pass < pass_count; ++pass) {
        bool allow_implicit_shift = pass == 1;
        for (const Shortcut &shortcut : host->shortcuts) {
            if (shortcut.key != key) continue;
            if (!shortcutModifiersMatch(shortcut.modifiers, allow_implicit_shift)) continue;
            if (!host->callback) return true;
            WindowsEvent event = {};
            event.kind = kShortcut;
            event.window_id = window->id;
            event.shortcut_id = shortcut.id.c_str();
            event.shortcut_id_len = shortcut.id.size();
            event.shortcut_key = shortcut.key.c_str();
            event.shortcut_key_len = shortcut.key.size();
            event.shortcut_modifiers = shortcut.modifiers;
            host->callback(host->callback_context, &event);
            return true;
        }
    }
    return false;
}

static bool emitShortcutForHwnd(Host *host, HWND hwnd, WPARAM wparam) {
    return emitShortcutForWindow(host, windowForHwnd(host, hwnd), wparam);
}

static bool emitShortcutForWindowId(Host *host, uint64_t window_id, WPARAM wparam) {
    return emitShortcutForWindow(host, windowForId(host, window_id), wparam);
}

static std::string webViewKey(uint64_t window_id, const std::string &label) {
    return std::to_string(window_id) + ":" + label;
}

static std::string nativeViewKey(uint64_t window_id, const std::string &label) {
    return std::to_string(window_id) + ":" + label;
}

static int webViewCoord(double value) {
    return value > 0 ? (int)(value + 0.5) : 0;
}

static int webViewExtent(double value) {
    return value > 1 ? (int)(value + 0.5) : 1;
}

static bool validChildWebViewFrame(double x, double y, double width, double height) {
    return x >= 0 && y >= 0 && width > 0 && height > 0;
}

static int nativeViewCoord(double value) {
    return value > 0 ? (int)(value + 0.5) : 0;
}

static int nativeViewExtent(double value) {
    return value > 0 ? (int)(value + 0.5) : 0;
}

static bool validNativeViewFrame(double x, double y, double width, double height) {
    return x >= 0 && y >= 0 && width >= 0 && height >= 0;
}

static bool isNativeContainerKind(int kind) {
    return kind == kViewToolbar ||
        kind == kViewTitlebarAccessory ||
        kind == kViewSidebar ||
        kind == kViewStatusbar ||
        kind == kViewSplit ||
        kind == kViewStack ||
        kind == kViewSpacer;
}

static bool isSupportedNativeViewKind(int kind) {
    return isNativeContainerKind(kind) ||
        kind == kViewButton ||
        kind == kViewIconButton ||
        kind == kViewCheckbox ||
        kind == kViewToggle ||
        kind == kViewSegmentedControl ||
        kind == kViewTextField ||
        kind == kViewSearchField ||
        kind == kViewLabel ||
        kind == kViewProgressIndicator;
}

static std::string nativeViewDisplayText(const NativeView &view) {
    if (!view.text.empty()) return view.text;
    if (!view.role.empty()) return view.role;
    return view.label;
}

static std::vector<std::string> segmentedLabels(const std::string &text) {
    std::vector<std::string> labels;
    const std::string source = text.empty() ? "One|Two" : text;
    size_t start = 0;
    while (start <= source.size()) {
        size_t end = source.find('|', start);
        if (end == std::string::npos) end = source.size();
        size_t first = start;
        while (first < end && std::isspace(static_cast<unsigned char>(source[first]))) first++;
        size_t last = end;
        while (last > first && std::isspace(static_cast<unsigned char>(source[last - 1]))) last--;
        if (last > first) labels.push_back(source.substr(first, last - first));
        if (end == source.size()) break;
        start = end + 1;
    }
    if (labels.empty()) labels.push_back("Segment");
    return labels;
}

static void applySegmentedControlText(HWND hwnd, const std::string &text) {
    if (!hwnd) return;
    TabCtrl_DeleteAllItems(hwnd);
    std::vector<std::string> labels = segmentedLabels(text);
    for (size_t index = 0; index < labels.size(); index++) {
        std::wstring wide = widen(labels[index]);
        TCITEMW item = {};
        item.mask = TCIF_TEXT;
        item.pszText = const_cast<LPWSTR>(wide.c_str());
        TabCtrl_InsertItem(hwnd, static_cast<int>(index), &item);
    }
    TabCtrl_SetCurSel(hwnd, 0);
}

static POINT nativeViewAbsoluteOrigin(Host *host, const NativeView &view) {
    POINT point = { nativeViewCoord(view.x), nativeViewCoord(view.y) };
    if (!host || view.parent.empty()) return point;
    auto parent = host->native_views.find(nativeViewKey(view.window_id, view.parent));
    while (parent != host->native_views.end()) {
        point.x += nativeViewCoord(parent->second.x);
        point.y += nativeViewCoord(parent->second.y);
        if (parent->second.parent.empty()) break;
        parent = host->native_views.find(nativeViewKey(parent->second.window_id, parent->second.parent));
    }
    return point;
}

static void applyNativeViewText(NativeView &view, const std::string &text) {
    if (!view.hwnd) return;
    std::wstring wide = widen(text);
    switch (view.kind) {
        case kViewTextField:
        case kViewSearchField:
            SendMessageW(view.hwnd, EM_SETCUEBANNER, TRUE, reinterpret_cast<LPARAM>(wide.c_str()));
            break;
        case kViewSegmentedControl:
            applySegmentedControlText(view.hwnd, text);
            break;
        case kViewProgressIndicator:
        case kViewSpacer:
        case kViewToolbar:
        case kViewTitlebarAccessory:
        case kViewSidebar:
        case kViewStatusbar:
            break;
        default:
            SetWindowTextW(view.hwnd, wide.c_str());
            break;
    }
}

static void applyNativeViewFrame(Host *host, NativeView &view) {
    if (!view.hwnd) return;
    POINT origin = nativeViewAbsoluteOrigin(host, view);
    MoveWindow(view.hwnd, origin.x, origin.y, nativeViewExtent(view.width), nativeViewExtent(view.height), TRUE);
}

static void applyNativeViewState(NativeView &view, bool update_text, const std::string &text) {
    if (!view.hwnd) return;
    ShowWindow(view.hwnd, view.visible ? SW_SHOW : SW_HIDE);
    EnableWindow(view.hwnd, view.enabled ? TRUE : FALSE);
    if (update_text) applyNativeViewText(view, text);
}

static void reorderWindowChildren(Host *host, uint64_t window_id) {
    if (!host) return;
    struct LayerItem {
        HWND hwnd;
        int layer;
        uint64_t order;
    };
    std::vector<LayerItem> items;
    for (auto &entry : host->webviews) {
        ChildWebView &webview = entry.second;
        if (webview.window_id == window_id && webview.hwnd) {
            items.push_back({ webview.hwnd, webview.layer, webview.creation_order });
        }
    }
    for (auto &entry : host->native_views) {
        NativeView &view = entry.second;
        if (view.window_id == window_id && view.hwnd) {
            items.push_back({ view.hwnd, view.layer, view.creation_order });
        }
    }
    std::sort(items.begin(), items.end(), [](const LayerItem &a, const LayerItem &b) {
        if (a.layer != b.layer) return a.layer < b.layer;
        return a.order < b.order;
    });
    for (const LayerItem &item : items) {
        SetWindowPos(item.hwnd, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }
}

static bool emitNativeCommandForHwnd(Host *host, HWND hwnd, UINT notification_code) {
    if (!host || !host->callback || !hwnd) return false;
    for (auto &entry : host->native_views) {
        NativeView &view = entry.second;
        if (view.hwnd != hwnd || view.command.empty()) continue;
        const bool button_like = view.kind == kViewButton || view.kind == kViewIconButton || view.kind == kViewCheckbox || view.kind == kViewToggle;
        const bool segmented = view.kind == kViewSegmentedControl;
        if ((button_like && notification_code != BN_CLICKED) || (segmented && notification_code != TCN_SELCHANGE) || (!button_like && !segmented)) return false;
        WindowsEvent event = {};
        event.kind = kNativeCommand;
        event.window_id = view.window_id;
        event.command_name = view.command.c_str();
        event.command_name_len = view.command.size();
        event.view_label = view.label.c_str();
        event.view_label_len = view.label.size();
        host->callback(host->callback_context, &event);
        return true;
    }
    return false;
}

static void applyNativeChildFrames(Host *host, uint64_t window_id, const std::string &parent_label) {
    if (!host) return;
    for (auto &entry : host->native_views) {
        NativeView &view = entry.second;
        if (view.window_id == window_id && view.parent == parent_label) {
            applyNativeViewFrame(host, view);
            applyNativeChildFrames(host, window_id, view.label);
        }
    }
}

static void destroyNativeViewAndChildren(Host *host, const std::string &key) {
    if (!host) return;
    auto found = host->native_views.find(key);
    if (found == host->native_views.end()) return;
    uint64_t window_id = found->second.window_id;
    std::string label = found->second.label;
    std::vector<std::string> children;
    for (const auto &entry : host->native_views) {
        if (entry.second.window_id == window_id && entry.second.parent == label) children.push_back(entry.first);
    }
    for (const std::string &child : children) destroyNativeViewAndChildren(host, child);
    if (found->second.hwnd) DestroyWindow(found->second.hwnd);
    host->native_views.erase(found);
}

static void destroyNativeViewsForWindow(Host *host, uint64_t window_id) {
    if (!host) return;
    std::vector<std::string> keys;
    for (const auto &entry : host->native_views) {
        if (entry.second.window_id == window_id) keys.push_back(entry.first);
    }
    for (const std::string &key : keys) destroyNativeViewAndChildren(host, key);
}

static void destroyChildWebViewsForWindow(Host *host, uint64_t window_id) {
    if (!host) return;
    for (auto it = host->webviews.begin(); it != host->webviews.end();) {
        if (it->second.window_id == window_id) {
#if ZERO_NATIVE_HAS_WEBVIEW2
            if (it->second.controller) it->second.controller->Close();
#endif
            if (it->second.hwnd) DestroyWindow(it->second.hwnd);
            it = host->webviews.erase(it);
        } else {
            ++it;
        }
    }
}

static void destroyAllWindows(Host *host) {
    if (!host) return;
    for (auto &entry : host->windows) {
        destroyNativeViewsForWindow(host, entry.first);
        destroyChildWebViewsForWindow(host, entry.first);
        if (entry.second.hwnd) {
            DestroyWindow(entry.second.hwnd);
            entry.second.hwnd = nullptr;
        }
    }
}

#if ZERO_NATIVE_HAS_WEBVIEW2
using CreateEnvironmentFn = HRESULT (STDAPICALLTYPE *)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions *, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *);

static const wchar_t *zeroNativeBridgeScript() {
    return LR"ZN((function(){
	if(window.zero&&window.zero.invoke&&window.zero.on&&window.zero._emit){return;}
	var pending=new Map();
	var listeners=new Map();
	var nextId=1;
	function post(message){
	if(window.chrome&&window.chrome.webview&&window.chrome.webview.postMessage){window.chrome.webview.postMessage(message);return;}
	throw new Error('zero-native bridge transport is unavailable');
	}
	function complete(response){
	var id=response&&response.id!=null?String(response.id):'';
	var entry=pending.get(id);
	if(!entry){return;}
	pending.delete(id);
	if(response.ok){entry.resolve(response.result===undefined?null:response.result);return;}
	var errorInfo=response.error||{};
	var error=new Error(errorInfo.message||'Native command failed');
	error.code=errorInfo.code||'internal_error';
	entry.reject(error);
	}
	function invoke(command,payload){
	if(typeof command!=='string'||command.length===0){return Promise.reject(new TypeError('command must be a non-empty string'));}
	var id=String(nextId++);
	var envelope=JSON.stringify({id:id,command:command,payload:payload===undefined?null:payload});
	return new Promise(function(resolve,reject){
	pending.set(id,{resolve:resolve,reject:reject});
	try{post(envelope);}catch(error){pending.delete(id);reject(error);}
	});
	}
	function selector(value){return typeof value==='number'?{id:value}:{label:String(value)};}
	function ensureString(value,name){if(typeof value!=='string'||value.length===0){throw new TypeError(name+' must be a non-empty string');}return value;}
	function ensureText(value,name){if(typeof value!=='string'){throw new TypeError(name+' must be a string');}return value;}
	function ensureNumber(value,name){if(typeof value!=='number'||!isFinite(value)){throw new TypeError(name+' must be a finite number');}return value;}
	function commandPayload(value){if(typeof value==='string'){return {name:ensureString(value,'command')};}value=value||{};var name=value.name!=null?value.name:value.id;return {name:ensureString(name,'command')};}
	function validateWebViewSelector(options){if(options.label!=null){ensureString(options.label,'label');}if(options.windowId!=null&&(typeof options.windowId!=='number'||!isFinite(options.windowId)||options.windowId<0||Math.floor(options.windowId)!==options.windowId)){throw new TypeError('windowId must be a non-negative integer');}}
	function framePayload(options){options=options||{};validateWebViewSelector(options);var frame=options.frame||options;return {label:options.label,windowId:options.windowId,url:options.url,frame:{x:frame.x==null?0:ensureNumber(frame.x,'frame.x'),y:frame.y==null?0:ensureNumber(frame.y,'frame.y'),width:ensureNumber(frame.width,'frame.width'),height:ensureNumber(frame.height,'frame.height')}};}
	function createPayload(options){options=options||{};ensureString(options.url,'url');var payload=framePayload(options);if(options.layer!=null){payload.layer=ensureNumber(options.layer,'layer');}if(options.transparent!=null){payload.transparent=!!options.transparent;}if(options.bridge!=null){payload.bridge=!!options.bridge;}return payload;}
	function navigatePayload(options){options=options||{};validateWebViewSelector(options);ensureString(options.url,'url');return {label:options.label,windowId:options.windowId,url:options.url};}
	function closePayload(options){options=options||{};validateWebViewSelector(options);return {label:options.label,windowId:options.windowId};}
	function webviewHandle(info){return Object.freeze(Object.assign({},info,{setFrame:function(frame){return webviews.setFrame({label:info.label,windowId:info.windowId,frame:frame});},navigate:function(url){return webviews.navigate({label:info.label,windowId:info.windowId,url:url});},setZoom:function(zoom){return webviews.setZoom({label:info.label,windowId:info.windowId,zoom:zoom});},setLayer:function(layer){return webviews.setLayer({label:info.label,windowId:info.windowId,layer:layer});},close:function(){return webviews.close({label:info.label,windowId:info.windowId});}}));}
	function validateViewSelector(options){options=options||{};ensureString(options.label,'label');if(options.windowId!=null&&(typeof options.windowId!=='number'||!isFinite(options.windowId)||options.windowId<0||Math.floor(options.windowId)!==options.windowId)){throw new TypeError('windowId must be a non-negative integer');}}
	function viewSelectorPayload(options){if(typeof options==='string'){return {label:ensureString(options,'label')};}options=options||{};validateViewSelector(options);return {label:options.label,windowId:options.windowId};}
	function optionalFramePayload(options){var frame=options.frame||((options.x!=null||options.y!=null||options.width!=null||options.height!=null)?options:null);if(!frame){return null;}return {x:frame.x==null?0:ensureNumber(frame.x,'frame.x'),y:frame.y==null?0:ensureNumber(frame.y,'frame.y'),width:ensureNumber(frame.width,'frame.width'),height:ensureNumber(frame.height,'frame.height')};}
	function viewCreatePayload(options){options=options||{};validateViewSelector(options);ensureString(options.kind,'kind');var payload={label:options.label,kind:options.kind,windowId:options.windowId};var frame=optionalFramePayload(options);if(frame){payload.frame=frame;}if(options.parent!=null){payload.parent=ensureString(options.parent,'parent');}if(options.role!=null){payload.role=ensureString(options.role,'role');}if(options.accessibilityLabel!=null){payload.accessibilityLabel=ensureString(options.accessibilityLabel,'accessibilityLabel');}if(options.text!=null){payload.text=ensureString(options.text,'text');}if(options.command!=null){payload.command=ensureString(options.command,'command');}if(options.url!=null){payload.url=ensureString(options.url,'url');}if(options.layer!=null){payload.layer=ensureNumber(options.layer,'layer');}if(options.visible!=null){payload.visible=!!options.visible;}if(options.enabled!=null){payload.enabled=!!options.enabled;}if(options.transparent!=null){payload.transparent=!!options.transparent;}if(options.bridge!=null){payload.bridge=!!options.bridge;}return payload;}
	function viewPatchPayload(options){options=options||{};validateViewSelector(options);var payload={label:options.label,windowId:options.windowId};var frame=optionalFramePayload(options);if(frame){payload.frame=frame;}if(options.layer!=null){payload.layer=ensureNumber(options.layer,'layer');}if(options.visible!=null){payload.visible=!!options.visible;}if(options.enabled!=null){payload.enabled=!!options.enabled;}if(options.role!=null){payload.role=ensureString(options.role,'role');}if(options.accessibilityLabel!=null){payload.accessibilityLabel=ensureString(options.accessibilityLabel,'accessibilityLabel');}if(options.text!=null){payload.text=ensureString(options.text,'text');}if(options.command!=null){payload.command=ensureString(options.command,'command');}if(options.url!=null){payload.url=ensureString(options.url,'url');}return payload;}
	function viewFramePayload(options){options=options||{};validateViewSelector(options);var frame=options.frame||options;return {label:options.label,windowId:options.windowId,frame:{x:frame.x==null?0:ensureNumber(frame.x,'frame.x'),y:frame.y==null?0:ensureNumber(frame.y,'frame.y'),width:ensureNumber(frame.width,'frame.width'),height:ensureNumber(frame.height,'frame.height')}};}
	function viewVisiblePayload(options){options=options||{};validateViewSelector(options);if(options.visible==null){throw new TypeError('visible is required');}return {label:options.label,windowId:options.windowId,visible:!!options.visible};}
	function viewHandle(info){return Object.freeze(Object.assign({},info,{update:function(patch){return views.update(Object.assign({},patch||{},{label:info.label,windowId:info.windowId}));},setFrame:function(frame){return views.setFrame({label:info.label,windowId:info.windowId,frame:frame});},setVisible:function(visible){return views.setVisible({label:info.label,windowId:info.windowId,visible:visible});},focus:function(){return views.focus({label:info.label,windowId:info.windowId});},close:function(){return views.close({label:info.label,windowId:info.windowId});}}));}
	function on(name,callback){if(typeof callback!=='function'){throw new TypeError('callback must be a function');}var set=listeners.get(name);if(!set){set=new Set();listeners.set(name,set);}set.add(callback);return function(){off(name,callback);};}
	function off(name,callback){var set=listeners.get(name);if(set){set.delete(callback);if(set.size===0){listeners.delete(name);}}}
	function emit(name,detail){var set=listeners.get(name);if(set){Array.from(set).forEach(function(callback){callback(detail);});}window.dispatchEvent(new CustomEvent('zero-native:'+name,{detail:detail}));}
	var commands=Object.freeze({
	invoke:function(value){return invoke('zero-native.command.invoke',commandPayload(value));},
	list:function(){return invoke('zero-native.command.list',{});}
	});
	var windows=Object.freeze({
	create:function(options){return invoke('zero-native.window.create',options||{});},
	list:function(){return invoke('zero-native.window.list',{});},
	focus:function(value){return invoke('zero-native.window.focus',selector(value));},
	close:function(value){return invoke('zero-native.window.close',selector(value));}
	});
	var dialogs=Object.freeze({
	openFile:function(options){return invoke('zero-native.dialog.openFile',options||{});},
	saveFile:function(options){return invoke('zero-native.dialog.saveFile',options||{});},
	showMessage:function(options){return invoke('zero-native.dialog.showMessage',options||{});}
	});
	function clipboardReadPayload(value){value=value||{};return {mimeType:ensureString(value.mimeType||value.type||'text/plain','mimeType')};}
	function clipboardWritePayload(value){if(typeof value==='string'){return {mimeType:'text/plain',data:value};}value=value||{};var data=value.data!=null?value.data:(value.text!=null?value.text:value.value);return {mimeType:ensureString(value.mimeType||value.type||'text/plain','mimeType'),data:ensureText(data,'data')};}
	var clipboard=Object.freeze({
	readText:function(){return invoke('zero-native.clipboard.readText',{});},
	writeText:function(value){var text=typeof value==='string'?value:(value||{}).text;return invoke('zero-native.clipboard.writeText',{text:ensureText(text,'text')});},
	read:function(value){return invoke('zero-native.clipboard.read',clipboardReadPayload(value));},
	write:function(value){return invoke('zero-native.clipboard.write',clipboardWritePayload(value));}
	});
	var os=Object.freeze({
	openUrl:function(value){var options=typeof value==='string'?{url:value}:(value||{});return invoke('zero-native.os.openUrl',{url:ensureString(options.url,'url')});},
	showNotification:function(value){var options=typeof value==='string'?{title:value}:(value||{});var payload={title:ensureString(options.title,'title')};if(options.subtitle!=null){payload.subtitle=ensureString(options.subtitle,'subtitle');}if(options.body!=null){payload.body=ensureString(options.body,'body');}return invoke('zero-native.os.showNotification',payload);},
	revealPath:function(value){var options=typeof value==='string'?{path:value}:(value||{});return invoke('zero-native.os.revealPath',{path:ensureString(options.path,'path')});},
	addRecentDocument:function(value){var options=typeof value==='string'?{path:value}:(value||{});return invoke('zero-native.os.addRecentDocument',{path:ensureString(options.path,'path')});},
	clearRecentDocuments:function(){return invoke('zero-native.os.clearRecentDocuments',{});}
	});
	function credentialPayload(value){value=value||{};return {service:ensureString(value.service,'service'),account:ensureString(value.account,'account')};}
	function credentialSetPayload(value){var payload=credentialPayload(value);payload.secret=ensureString(value.secret!=null?value.secret:value.value,'secret');return payload;}
	var credentials=Object.freeze({
	set:function(value){return invoke('zero-native.credentials.set',credentialSetPayload(value));},
	get:function(value){return invoke('zero-native.credentials.get',credentialPayload(value));},
	delete:function(value){return invoke('zero-native.credentials.delete',credentialPayload(value));}
	});
	function platformFeaturePayload(value){if(typeof value==='string'){return {feature:ensureString(value,'feature')};}value=value||{};return {feature:ensureString(value.feature!=null?value.feature:value.name,'feature')};}
	var platform=Object.freeze({
	supports:function(value){return invoke('zero-native.platform.supports',platformFeaturePayload(value));}
	});
	function zoomPayload(options){options=options||{};validateWebViewSelector(options);return {label:options.label,windowId:options.windowId,zoom:ensureNumber(options.zoom,'zoom')};}
	function layerPayload(options){options=options||{};validateWebViewSelector(options);return {label:options.label,windowId:options.windowId,layer:ensureNumber(options.layer,'layer')};}
	var webviews=Object.freeze({
	create:function(options){return invoke('zero-native.webview.create',createPayload(options)).then(webviewHandle);},
	list:function(){return invoke('zero-native.webview.list',{});},
	setFrame:function(options){return invoke('zero-native.webview.setFrame',framePayload(options));},
	navigate:function(options){return invoke('zero-native.webview.navigate',navigatePayload(options));},
	setZoom:function(options){return invoke('zero-native.webview.setZoom',zoomPayload(options));},
	setLayer:function(options){return invoke('zero-native.webview.setLayer',layerPayload(options));},
	close:function(options){return invoke('zero-native.webview.close',closePayload(options));}
	});
	var views=Object.freeze({
	create:function(options){return invoke('zero-native.view.create',viewCreatePayload(options)).then(viewHandle);},
	list:function(){return invoke('zero-native.view.list',{});},
	update:function(options,patch){if(typeof options==='string'){return invoke('zero-native.view.update',viewPatchPayload(Object.assign({},patch||{},{label:options}))).then(viewHandle);}return invoke('zero-native.view.update',viewPatchPayload(options)).then(viewHandle);},
	setFrame:function(options){return invoke('zero-native.view.setFrame',viewFramePayload(options)).then(viewHandle);},
	setVisible:function(options){return invoke('zero-native.view.setVisible',viewVisiblePayload(options)).then(viewHandle);},
	focus:function(options){return invoke('zero-native.view.focus',viewSelectorPayload(options)).then(viewHandle);},
	focusNext:function(options){options=options||{};return invoke('zero-native.view.focusNext',{windowId:options.windowId}).then(viewHandle);},
	focusPrevious:function(options){options=options||{};return invoke('zero-native.view.focusPrevious',{windowId:options.windowId}).then(viewHandle);},
	close:function(options){return invoke('zero-native.view.close',viewSelectorPayload(options));}
	});
	try{Object.defineProperty(window,'zero',{value:Object.freeze({invoke:invoke,on:on,off:off,commands:commands,windows:windows,dialogs:dialogs,clipboard:clipboard,os:os,credentials:credentials,platform:platform,webviews:webviews,views:views,_complete:complete,_emit:emit}),configurable:false});}catch(error){}
	})();
	)ZN";
}

static RECT webViewRect(const ChildWebView &webview) {
    RECT rect = {};
    rect.left = 0;
    rect.top = 0;
    rect.right = webViewExtent(webview.width);
    rect.bottom = webViewExtent(webview.height);
    return rect;
}

static CreateEnvironmentFn webView2Factory() {
    static HMODULE loader = LoadLibraryW(L"WebView2Loader.dll");
    if (!loader) return nullptr;
    return reinterpret_cast<CreateEnvironmentFn>(GetProcAddress(loader, "CreateCoreWebView2EnvironmentWithOptions"));
}

static void cleanupPendingChildWebView(Host *host, const std::string &key) {
    if (!host) return;
    auto found = host->webviews.find(key);
    if (found == host->webviews.end()) return;
    if (found->second.controller) found->second.controller->Close();
    if (found->second.hwnd) DestroyWindow(found->second.hwnd);
    host->webviews.erase(found);
}

static bool createChildWebView(Host *host, const std::string &key) {
    auto factory = webView2Factory();
    if (!factory) return false;
    auto found = host->webviews.find(key);
    if (found == host->webviews.end() || !found->second.hwnd) return false;
    HWND parent = found->second.hwnd;
    std::weak_ptr<HostLifetime> lifetime = host->lifetime;
    HRESULT hr = factory(nullptr, nullptr, nullptr, Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
        [host, key, parent, lifetime](HRESULT result, ICoreWebView2Environment *environment) -> HRESULT {
            auto token = lifetime.lock();
            if (!token) return S_OK;
            std::lock_guard<std::recursive_mutex> guard(token->mutex);
            if (!token->alive) return S_OK;
            auto found = host->webviews.find(key);
            if (found == host->webviews.end() || found->second.hwnd != parent || !IsWindow(parent)) return S_OK;
            if (FAILED(result) || !environment) {
                cleanupPendingChildWebView(host, key);
                return result;
            }
            return environment->CreateCoreWebView2Controller(parent, Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                [host, key, lifetime](HRESULT controller_result, ICoreWebView2Controller *controller) -> HRESULT {
                    auto token = lifetime.lock();
                    if (!token) {
                        if (controller) controller->Close();
                        return S_OK;
                    }
                    std::lock_guard<std::recursive_mutex> guard(token->mutex);
                    if (!token->alive) {
                        if (controller) controller->Close();
                        return S_OK;
                    }
                    if (FAILED(controller_result) || !controller) {
                        cleanupPendingChildWebView(host, key);
                        return controller_result;
                    }
                    auto found = host->webviews.find(key);
                    if (found == host->webviews.end()) {
                        controller->Close();
                        return S_OK;
                    }
                    found->second.controller = controller;
                    controller->get_CoreWebView2(&found->second.webview);
                    RECT bounds = webViewRect(found->second);
                    controller->put_Bounds(bounds);
                    controller->put_ZoomFactor(found->second.zoom);
                    controller->put_IsVisible(TRUE);
                    if (found->second.webview) {
                        if (found->second.bridge_enabled) {
                            found->second.webview->AddScriptToExecuteOnDocumentCreated(zeroNativeBridgeScript(), nullptr);
                            EventRegistrationToken bridge_token = {};
                            uint64_t bridge_window_id = found->second.window_id;
                            std::string bridge_label = found->second.label;
                            found->second.webview->add_WebMessageReceived(Callback<ICoreWebView2WebMessageReceivedEventHandler>(
                                [host, bridge_window_id, bridge_label, lifetime](ICoreWebView2 *, ICoreWebView2WebMessageReceivedEventArgs *args) -> HRESULT {
                                    auto token = lifetime.lock();
                                    if (!token) return S_OK;
                                    std::lock_guard<std::recursive_mutex> guard(token->mutex);
                                    if (!token->alive || !args || !host->bridge_callback) return S_OK;

                                    LPWSTR message_bytes = nullptr;
                                    if (FAILED(args->TryGetWebMessageAsString(&message_bytes)) || !message_bytes) return S_OK;
                                    std::wstring message_wide(message_bytes);
                                    CoTaskMemFree(message_bytes);
                                    std::string message = narrow(message_wide);

                                    std::string origin = "zero://inline";
                                    LPWSTR source_bytes = nullptr;
                                    if (SUCCEEDED(args->get_Source(&source_bytes)) && source_bytes) {
                                        std::wstring source_wide(source_bytes);
                                        CoTaskMemFree(source_bytes);
                                        origin = originForUrl(narrow(source_wide));
                                    }

                                    host->bridge_callback(
                                        host->bridge_context,
                                        bridge_window_id,
                                        bridge_label.c_str(),
                                        bridge_label.size(),
                                        message.c_str(),
                                        message.size(),
                                        origin.c_str(),
                                        origin.size());
                                    return S_OK;
                                }).Get(), &bridge_token);
                        }
                        EventRegistrationToken accelerator_token = {};
                        uint64_t accelerator_window_id = found->second.window_id;
                        found->second.controller->add_AcceleratorKeyPressed(Callback<ICoreWebView2AcceleratorKeyPressedEventHandler>(
                            [host, accelerator_window_id, lifetime](ICoreWebView2Controller *, ICoreWebView2AcceleratorKeyPressedEventArgs *args) -> HRESULT {
                                auto token = lifetime.lock();
                                if (!token) return S_OK;
                                std::lock_guard<std::recursive_mutex> guard(token->mutex);
                                if (!token->alive || !args) return S_OK;
                                COREWEBVIEW2_KEY_EVENT_KIND kind = COREWEBVIEW2_KEY_EVENT_KIND_KEY_DOWN;
                                if (FAILED(args->get_KeyEventKind(&kind))) return S_OK;
                                if (kind != COREWEBVIEW2_KEY_EVENT_KIND_KEY_DOWN && kind != COREWEBVIEW2_KEY_EVENT_KIND_SYSTEM_KEY_DOWN) return S_OK;
                                UINT virtual_key = 0;
                                if (FAILED(args->get_VirtualKey(&virtual_key))) return S_OK;
                                if (emitShortcutForWindowId(host, accelerator_window_id, virtual_key)) {
                                    args->put_Handled(TRUE);
                                }
                                return S_OK;
                            }).Get(), &accelerator_token);

                        EventRegistrationToken token = {};
                        found->second.webview->add_NavigationStarting(Callback<ICoreWebView2NavigationStartingEventHandler>(
                            [host, lifetime](ICoreWebView2 *, ICoreWebView2NavigationStartingEventArgs *args) -> HRESULT {
                                auto token = lifetime.lock();
                                if (!token) return S_OK;
                                std::lock_guard<std::recursive_mutex> guard(token->mutex);
                                if (!token->alive) return S_OK;
                                LPWSTR uri_bytes = nullptr;
                                if (!args || FAILED(args->get_Uri(&uri_bytes))) return S_OK;
                                std::wstring uri_wide = uri_bytes ? std::wstring(uri_bytes) : std::wstring();
                                if (uri_bytes) CoTaskMemFree(uri_bytes);
                                std::string uri = narrow(uri_wide);
                                if (uri.empty() || uri.rfind("about:", 0) == 0 || policyListMatches(host->allowed_origins, uri)) return S_OK;
                                if (host->external_link_action == 1 && policyListMatches(host->allowed_external_urls, uri)) {
                                    ShellExecuteW(nullptr, L"open", uri_wide.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
                                }
                                args->put_Cancel(TRUE);
                                return S_OK;
                            }).Get(), &token);
                        std::wstring latest_url = widen(found->second.url);
                        if (!latest_url.empty()) found->second.webview->Navigate(latest_url.c_str());
                    }
                    return S_OK;
                }).Get());
        }).Get());
    return SUCCEEDED(hr);
}
#endif

static void applyChildWebViewLayer(Host *host, uint64_t window_id, const std::string &label) {
    if (!host) return;
    (void)label;
    reorderWindowChildren(host, window_id);
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
        case kNotificationCallbackMessage:
            if (host && host->tray_active) {
                UINT tray_event = LOWORD(lparam);
                if (tray_event == WM_CONTEXTMENU || tray_event == WM_RBUTTONUP || tray_event == WM_LBUTTONUP) {
                    showTrayMenu(host, hwnd);
                    return 0;
                }
            }
            break;
        case WM_KEYDOWN:
        case WM_SYSKEYDOWN:
            if (host && emitShortcutForHwnd(host, hwnd, wparam)) return 0;
            break;
        case WM_COMMAND:
            if (host) {
                if (lparam != 0 && emitNativeCommandForHwnd(host, reinterpret_cast<HWND>(lparam), HIWORD(wparam))) return 0;
                if (lparam == 0 && emitMenuCommandForId(host, hwnd, LOWORD(wparam))) return 0;
            }
            break;
        case WM_NOTIFY:
            if (host && lparam != 0) {
                NMHDR *header = reinterpret_cast<NMHDR *>(lparam);
                if (header && emitNativeCommandForHwnd(host, header->hwndFrom, header->code)) return 0;
            }
            break;
        case WM_ACTIVATEAPP:
            if (host) {
                bool active = wparam != FALSE;
                if (host->app_active != active) {
                    host->app_active = active;
                    for (auto &entry : host->windows) {
                        if (entry.second.hwnd == hwnd) {
                            emit(host, entry.second, active ? kAppActivated : kAppDeactivated);
                            break;
                        }
                    }
                }
            }
            break;
        case WM_DROPFILES:
            if (host) {
                HDROP drop = reinterpret_cast<HDROP>(wparam);
                std::string paths = droppedFilePaths(drop);
                DragFinish(drop);
                if (!paths.empty()) {
                    for (auto &entry : host->windows) {
                        if (entry.second.hwnd == hwnd) {
                            emitFileDrop(host, entry.second, paths);
                            break;
                        }
                    }
                }
            }
            return 0;
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
                        destroyNativeViewsForWindow(host, entry.first);
                        destroyChildWebViewsForWindow(host, entry.first);
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
    DragAcceptFiles(hwnd, TRUE);
    window.hwnd = hwnd;
    applyMenusToWindow(host, window);
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    SetTimer(hwnd, 1, 16, nullptr);
    return true;
}

} // namespace

extern "C" {

void zero_native_windows_load_window_webview(Host *host, uint64_t window_id, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback);
void zero_native_windows_bridge_respond_window(Host *host, uint64_t window_id, const char *response, size_t response_len);
size_t zero_native_windows_clipboard_read_data(Host *host, const char *mime_type, size_t mime_type_len, char *buffer, size_t buffer_len);
int zero_native_windows_clipboard_write_data(Host *host, const char *mime_type, size_t mime_type_len, const char *bytes, size_t bytes_len);

Host *zero_native_windows_create(const char *app_name, size_t app_name_len, const char *window_title, size_t window_title_len, const char *bundle_id, size_t bundle_id_len, const char *icon_path, size_t icon_path_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame) {
    (void)restore_frame;
    INITCOMMONCONTROLSEX controls = {};
    controls.dwSize = sizeof(controls);
    controls.dwICC = ICC_PROGRESS_CLASS | ICC_TAB_CLASSES;
    InitCommonControlsEx(&controls);

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
    std::shared_ptr<HostLifetime> lifetime = host->lifetime;
    std::lock_guard<std::recursive_mutex> guard(lifetime->mutex);
    lifetime->alive = false;
    removeNotificationIcon(host);
    destroyAllWindows(host);
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

void zero_native_windows_bridge_respond_webview(Host *host, uint64_t window_id, const char *webview_label, size_t webview_label_len, const char *response, size_t response_len) {
#if ZERO_NATIVE_HAS_WEBVIEW2
    if (!host) return;
    std::string label = slice(webview_label, webview_label_len);
    auto found = host->webviews.find(webViewKey(window_id, label));
    if (found == host->webviews.end() || !found->second.webview) return;
    std::string response_string = response && response_len > 0 ? slice(response, response_len) : std::string("{}");
    std::string script = "window.zero&&window.zero._complete(" + response_string + ");";
    std::wstring script_wide = widen(script);
    found->second.webview->ExecuteScript(script_wide.c_str(), nullptr);
#else
    (void)host;
    (void)window_id;
    (void)webview_label;
    (void)webview_label_len;
    (void)response;
    (void)response_len;
#endif
}

void zero_native_windows_emit_window_event(Host *host, uint64_t window_id, const char *name, size_t name_len, const char *detail_json, size_t detail_json_len) {
#if ZERO_NATIVE_HAS_WEBVIEW2
    if (!host) return;
    std::string event_name = slice(name, name_len);
    if (event_name.empty()) return;
    std::string detail = detail_json && detail_json_len > 0 ? slice(detail_json, detail_json_len) : std::string("null");
    std::string script = "(function(){var name=" + jsonStringLiteral(event_name) + ";var detail=" + detail + ";if(window.zero&&window.zero._emit){window.zero._emit(name,detail);return;}window.dispatchEvent(new CustomEvent('zero-native:'+name,{detail:detail}));})();";
    std::wstring script_wide = widen(script);
    for (auto &entry : host->webviews) {
        ChildWebView &webview = entry.second;
        if (webview.window_id != window_id || !webview.bridge_enabled || !webview.webview) continue;
        webview.webview->ExecuteScript(script_wide.c_str(), nullptr);
    }
#else
    (void)host;
    (void)window_id;
    (void)name;
    (void)name_len;
    (void)detail_json;
    (void)detail_json_len;
#endif
}

void zero_native_windows_set_security_policy(Host *host, const char *allowed_origins, size_t allowed_origins_len, const char *external_urls, size_t external_urls_len, int external_action) {
    if (!host) return;
    host->allowed_origins = parseNewlineList(allowed_origins, allowed_origins_len);
    host->allowed_external_urls = parseNewlineList(external_urls, external_urls_len);
    host->external_link_action = external_action;
}

void zero_native_windows_set_menus(Host *host, const char *const *menu_titles, const size_t *menu_title_lens, size_t menu_count, const uint32_t *item_menu_indices, const char *const *item_labels, const size_t *item_label_lens, const char *const *item_commands, const size_t *item_command_lens, const char *const *item_keys, const size_t *item_key_lens, const uint32_t *item_modifiers, const int *item_separators, const int *item_enabled, const int *item_checked, size_t item_count) {
    if (!host) return;
    host->menus.clear();
    host->menu_commands.clear();

    if (menu_count > 0 && (!menu_titles || !menu_title_lens)) return;
    host->menus.reserve(menu_count);
    for (size_t index = 0; index < menu_count; ++index) {
        Menu menu;
        menu.title = slice(menu_titles[index], menu_title_lens[index]);
        host->menus.push_back(menu);
    }

    if (item_count > 0 && (!item_menu_indices || !item_labels || !item_label_lens || !item_commands || !item_command_lens || !item_keys || !item_key_lens || !item_modifiers || !item_separators || !item_enabled || !item_checked)) return;
    uint32_t next_command_id = kMenuCommandBase;
    for (size_t index = 0; index < item_count; ++index) {
        uint32_t menu_index = item_menu_indices[index];
        if (menu_index >= host->menus.size()) continue;
        MenuItem item;
        item.label = slice(item_labels[index], item_label_lens[index]);
        item.command = slice(item_commands[index], item_command_lens[index]);
        item.key = slice(item_keys[index], item_key_lens[index]);
        for (char &ch : item.key) {
            if (ch >= 'A' && ch <= 'Z') ch = static_cast<char>(ch - 'A' + 'a');
        }
        item.modifiers = item_modifiers[index];
        item.separator = item_separators[index] != 0;
        item.enabled = item_enabled[index] != 0;
        item.checked = item_checked[index] != 0;
        if (!item.separator && !item.command.empty()) {
            item.command_id = next_command_id++;
            host->menu_commands[item.command_id] = item.command;
        }
        host->menus[menu_index].items.push_back(item);
    }

    for (auto &entry : host->windows) {
        if (entry.second.hwnd) applyMenusToWindow(host, entry.second);
    }
}

void zero_native_windows_set_shortcuts(Host *host, const char *const *ids, const size_t *id_lens, const char *const *keys, const size_t *key_lens, const uint32_t *modifiers, size_t count) {
    if (!host) return;
    host->shortcuts.clear();
    if (!ids || !id_lens || !keys || !key_lens || !modifiers) return;
    const size_t limit = count < kMaxShortcuts ? count : kMaxShortcuts;
    for (size_t i = 0; i < limit; ++i) {
        if (!ids[i] || !keys[i] || id_lens[i] == 0 || key_lens[i] == 0) continue;
        Shortcut shortcut;
        shortcut.id = slice(ids[i], id_lens[i]);
        shortcut.key = slice(keys[i], key_lens[i]);
        for (char &ch : shortcut.key) {
            if (ch >= 'A' && ch <= 'Z') ch = static_cast<char>(ch - 'A' + 'a');
        }
        shortcut.modifiers = modifiers[i];
        host->shortcuts.push_back(shortcut);
    }
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
    if (!ok) return 0;
    host->windows[window_id] = window;
    return 1;
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
    destroyNativeViewsForWindow(host, window_id);
    destroyChildWebViewsForWindow(host, window_id);
    DestroyWindow(found->second.hwnd);
    return 1;
}

int zero_native_windows_create_view(Host *host, uint64_t window_id, const char *label, size_t label_len, int kind, const char *parent, size_t parent_len, double x, double y, double width, double height, int layer, int visible, int enabled, const char *role, size_t role_len, const char *accessibility_label, size_t accessibility_label_len, const char *text, size_t text_len, const char *command, size_t command_len) {
    if (!host || label_len == 0 || !isSupportedNativeViewKind(kind) || !validNativeViewFrame(x, y, width, height)) return 0;
    auto window = host->windows.find(window_id);
    if (window == host->windows.end() || !window->second.hwnd) return 0;

    std::string label_string = slice(label, label_len);
    std::string key = nativeViewKey(window_id, label_string);
    if (host->native_views.find(key) != host->native_views.end()) return 0;

    std::string parent_string = slice(parent, parent_len);
    if (!parent_string.empty()) {
        auto parent_view = host->native_views.find(nativeViewKey(window_id, parent_string));
        if (parent_view == host->native_views.end() || !parent_view->second.hwnd || !isNativeContainerKind(parent_view->second.kind)) return 0;
    }

    NativeView view;
    view.window_id = window_id;
    view.label = label_string;
    view.parent = parent_string;
    view.role = slice(role, role_len);
    view.accessibility_label = slice(accessibility_label, accessibility_label_len);
    view.text = slice(text, text_len);
    view.command = slice(command, command_len);
    view.x = x;
    view.y = y;
    view.width = width;
    view.height = height;
    view.kind = kind;
    view.layer = layer;
    view.creation_order = host->next_child_order++;
    view.visible = visible != 0;
    view.enabled = enabled != 0;
    view.explicit_text = text_len > 0;

    const std::string display_text = nativeViewDisplayText(view);
    std::wstring wide_text = widen(display_text);
    std::wstring class_name;
    DWORD style = WS_CHILD | WS_CLIPSIBLINGS;
    DWORD ex_style = 0;
    switch (kind) {
        case kViewToolbar:
        case kViewTitlebarAccessory:
        case kViewSidebar:
        case kViewStatusbar:
        case kViewSplit:
        case kViewStack:
        case kViewSpacer:
            class_name = L"STATIC";
            style |= WS_CLIPCHILDREN | SS_GRAYRECT;
            wide_text.clear();
            break;
        case kViewButton:
            class_name = L"BUTTON";
            style |= BS_PUSHBUTTON | WS_TABSTOP;
            break;
        case kViewIconButton:
            class_name = L"BUTTON";
            style |= BS_PUSHBUTTON | WS_TABSTOP | BS_CENTER | BS_VCENTER;
            break;
        case kViewCheckbox:
            class_name = L"BUTTON";
            style |= BS_AUTOCHECKBOX | WS_TABSTOP;
            break;
        case kViewToggle:
            class_name = L"BUTTON";
            style |= BS_AUTOCHECKBOX | BS_PUSHLIKE | WS_TABSTOP;
            break;
        case kViewSegmentedControl:
            class_name = WC_TABCONTROLW;
            style |= TCS_BUTTONS | TCS_FIXEDWIDTH | WS_TABSTOP;
            wide_text.clear();
            break;
        case kViewTextField:
        case kViewSearchField:
            class_name = L"EDIT";
            style |= ES_AUTOHSCROLL | WS_TABSTOP | WS_BORDER;
            wide_text.clear();
            ex_style = WS_EX_CLIENTEDGE;
            break;
        case kViewLabel:
            class_name = L"STATIC";
            style |= SS_LEFT | SS_ENDELLIPSIS;
            break;
        case kViewProgressIndicator:
            class_name = PROGRESS_CLASSW;
            style |= PBS_MARQUEE;
            wide_text.clear();
            break;
        default:
            return 0;
    }
    if (view.visible) style |= WS_VISIBLE;

    POINT origin = nativeViewAbsoluteOrigin(host, view);
    HWND hwnd = CreateWindowExW(
        ex_style,
        class_name.c_str(),
        wide_text.c_str(),
        style,
        origin.x,
        origin.y,
        nativeViewExtent(width),
        nativeViewExtent(height),
        window->second.hwnd,
        nullptr,
        host->instance,
        nullptr);
    if (!hwnd) return 0;

    view.hwnd = hwnd;
    applyNativeViewState(view, true, display_text);
    if (view.kind == kViewProgressIndicator) {
        SendMessageW(view.hwnd, PBM_SETMARQUEE, TRUE, 30);
    }
    host->native_views[key] = view;
    reorderWindowChildren(host, window_id);
    return 1;
}

int zero_native_windows_update_view(Host *host, uint64_t window_id, const char *label, size_t label_len, int has_frame, double x, double y, double width, double height, int has_layer, int layer, int has_visible, int visible, int has_enabled, int enabled, int has_role, const char *role, size_t role_len, int has_accessibility_label, const char *accessibility_label, size_t accessibility_label_len, int has_text, const char *text, size_t text_len, int has_command, const char *command, size_t command_len) {
    if (!host || label_len == 0) return 0;
    std::string label_string = slice(label, label_len);
    auto found = host->native_views.find(nativeViewKey(window_id, label_string));
    if (found == host->native_views.end() || !found->second.hwnd) return 0;
    NativeView &view = found->second;

    if (has_frame) {
        if (!validNativeViewFrame(x, y, width, height)) return 0;
        view.x = x;
        view.y = y;
        view.width = width;
        view.height = height;
        applyNativeViewFrame(host, view);
        applyNativeChildFrames(host, window_id, view.label);
    }
    if (has_layer) view.layer = layer;
    if (has_visible) view.visible = visible != 0;
    if (has_enabled) view.enabled = enabled != 0;
    if (has_role) view.role = slice(role, role_len);
    if (has_accessibility_label) view.accessibility_label = slice(accessibility_label, accessibility_label_len);
    if (has_text) {
        view.text = slice(text, text_len);
        view.explicit_text = text_len > 0;
    }
    if (has_command) view.command = slice(command, command_len);

    bool update_text = has_text || (has_role && !view.explicit_text);
    std::string display_text = has_text ? view.text : nativeViewDisplayText(view);
    if (has_visible || has_enabled || update_text) applyNativeViewState(view, update_text, display_text);
    if (has_layer) reorderWindowChildren(host, window_id);
    return 1;
}

int zero_native_windows_set_view_frame(Host *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height) {
    return zero_native_windows_update_view(host, window_id, label, label_len, 1, x, y, width, height, 0, 0, 0, 1, 0, 1, 0, "", 0, 0, "", 0, 0, "", 0, 0, "", 0);
}

int zero_native_windows_set_view_visible(Host *host, uint64_t window_id, const char *label, size_t label_len, int visible) {
    return zero_native_windows_update_view(host, window_id, label, label_len, 0, 0, 0, 0, 0, 0, 0, 1, visible, 0, 1, 0, "", 0, 0, "", 0, 0, "", 0, 0, "", 0);
}

int zero_native_windows_focus_view(Host *host, uint64_t window_id, const char *label, size_t label_len) {
    if (!host || label_len == 0) return 0;
    std::string label_string = slice(label, label_len);
    if (label_string == "main") {
        auto window = host->windows.find(window_id);
        if (window == host->windows.end() || !window->second.hwnd) return 0;
        SetFocus(window->second.hwnd);
        return GetFocus() == window->second.hwnd ? 1 : 0;
    }
    auto webview = host->webviews.find(webViewKey(window_id, label_string));
    if (webview != host->webviews.end() && webview->second.hwnd) {
        SetFocus(webview->second.hwnd);
        return GetFocus() == webview->second.hwnd ? 1 : 0;
    }
    auto found = host->native_views.find(nativeViewKey(window_id, label_string));
    if (found == host->native_views.end() || !found->second.hwnd || !found->second.visible || !found->second.enabled) return 0;
    SetFocus(found->second.hwnd);
    return GetFocus() == found->second.hwnd ? 1 : 0;
}

int zero_native_windows_close_view(Host *host, uint64_t window_id, const char *label, size_t label_len) {
    if (!host || label_len == 0) return 0;
    std::string label_string = slice(label, label_len);
    std::string key = nativeViewKey(window_id, label_string);
    if (host->native_views.find(key) == host->native_views.end()) return 0;
    destroyNativeViewAndChildren(host, key);
    reorderWindowChildren(host, window_id);
    return 1;
}

WindowsOpenDialogResult zero_native_windows_show_open_dialog(Host *host, const WindowsOpenDialogOpts *opts, char *buffer, size_t buffer_len) {
    WindowsOpenDialogResult result = {};
    if (!host || !opts || !buffer || buffer_len == 0) return result;
    bool uninitialize = false;
    if (!initializeCom(&uninitialize)) return result;

    IFileOpenDialog *dialog = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
    if (FAILED(hr) || !dialog) {
        finishCom(uninitialize);
        return result;
    }

    DWORD options = 0;
    if (SUCCEEDED(dialog->GetOptions(&options))) {
        options |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
        if (opts->allow_directories) options |= FOS_PICKFOLDERS;
        else options |= FOS_FILEMUSTEXIST;
        if (opts->allow_multiple) options |= FOS_ALLOWMULTISELECT;
        dialog->SetOptions(options);
    }
    setDialogTitle(dialog, opts->title, opts->title_len);
    setDialogFolder(dialog, opts->default_path, opts->default_path_len);
    if (!opts->allow_directories) setDialogFilters(dialog, opts->extensions, opts->extensions_len);

    if (SUCCEEDED(dialog->Show(parentWindow(host)))) {
        IShellItemArray *items = nullptr;
        if (SUCCEEDED(dialog->GetResults(&items)) && items) {
            DWORD count = 0;
            items->GetCount(&count);
            size_t offset = 0;
            size_t written_count = 0;
            for (DWORD index = 0; index < count; ++index) {
                IShellItem *item = nullptr;
                if (SUCCEEDED(items->GetItemAt(index, &item)) && item) {
                    PWSTR path = nullptr;
                    if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) && path) {
                        appendPathToBuffer(buffer, buffer_len, &offset, &written_count, std::wstring(path));
                        CoTaskMemFree(path);
                    }
                    item->Release();
                }
            }
            result.count = written_count;
            result.bytes_written = offset;
            items->Release();
        }
    }

    dialog->Release();
    finishCom(uninitialize);
    return result;
}

size_t zero_native_windows_show_save_dialog(Host *host, const WindowsSaveDialogOpts *opts, char *buffer, size_t buffer_len) {
    if (!host || !opts || !buffer || buffer_len == 0) return 0;
    bool uninitialize = false;
    if (!initializeCom(&uninitialize)) return 0;

    IFileSaveDialog *dialog = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
    if (FAILED(hr) || !dialog) {
        finishCom(uninitialize);
        return 0;
    }

    DWORD options = 0;
    if (SUCCEEDED(dialog->GetOptions(&options))) dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
    setDialogTitle(dialog, opts->title, opts->title_len);
    setDialogFolder(dialog, opts->default_path, opts->default_path_len);
    setDialogFilters(dialog, opts->extensions, opts->extensions_len);
    std::wstring default_name = widen(slice(opts->default_name, opts->default_name_len));
    if (!default_name.empty()) dialog->SetFileName(default_name.c_str());

    size_t written = 0;
    if (SUCCEEDED(dialog->Show(parentWindow(host)))) {
        IShellItem *item = nullptr;
        if (SUCCEEDED(dialog->GetResult(&item)) && item) {
            PWSTR path = nullptr;
            if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) && path) {
                std::string utf8_path = narrow(std::wstring(path));
                written = utf8_path.size() < buffer_len ? utf8_path.size() : buffer_len;
                if (written > 0) memcpy(buffer, utf8_path.data(), written);
                CoTaskMemFree(path);
            }
            item->Release();
        }
    }

    dialog->Release();
    finishCom(uninitialize);
    return written;
}

int zero_native_windows_show_message_dialog(Host *host, const WindowsMessageDialogOpts *opts) {
    if (!host || !opts) return 0;
    std::wstring title = widen(slice(opts->title, opts->title_len));
    std::wstring message = widen(slice(opts->message, opts->message_len));
    std::wstring informative = widen(slice(opts->informative_text, opts->informative_text_len));
    std::wstring primary = widen(slice(opts->primary_button, opts->primary_button_len));
    std::wstring secondary = widen(slice(opts->secondary_button, opts->secondary_button_len));
    std::wstring tertiary = widen(slice(opts->tertiary_button, opts->tertiary_button_len));
    if (primary.empty()) primary = L"OK";

    TASKDIALOG_BUTTON buttons[3] = {};
    int button_count = 0;
    buttons[button_count++] = { 100, primary.c_str() };
    if (!secondary.empty()) buttons[button_count++] = { 101, secondary.c_str() };
    if (!tertiary.empty()) buttons[button_count++] = { 102, tertiary.c_str() };

    TASKDIALOGCONFIG config = {};
    config.cbSize = sizeof(config);
    config.hwndParent = parentWindow(host);
    config.dwFlags = TDF_ALLOW_DIALOG_CANCELLATION;
    config.pszWindowTitle = title.empty() ? L"zero-native" : title.c_str();
    config.pszMainInstruction = message.empty() ? config.pszWindowTitle : message.c_str();
    config.pszContent = informative.empty() ? nullptr : informative.c_str();
    config.cButtons = static_cast<UINT>(button_count);
    config.pButtons = buttons;
    config.nDefaultButton = 100;
    config.pszMainIcon = opts->style == 2 ? TD_ERROR_ICON : (opts->style == 1 ? TD_WARNING_ICON : TD_INFORMATION_ICON);

    int pressed = 100;
    HRESULT hr = TaskDialogIndirect(&config, &pressed, nullptr, nullptr);
    if (FAILED(hr)) return 0;
    if (pressed == 101) return 1;
    if (pressed == 102) return 2;
    return 0;
}

int zero_native_windows_show_notification(Host *host, const char *title, size_t title_len, const char *subtitle, size_t subtitle_len, const char *body, size_t body_len) {
    if (!host || !title || title_len == 0) return 0;
    if ((subtitle_len > 0 && !subtitle) || (body_len > 0 && !body)) return 0;
    if (!ensureNotificationIcon(host)) return 0;

    std::wstring title_wide = widen(slice(title, title_len));
    std::wstring body_wide;
    if (subtitle && subtitle_len > 0) body_wide += widen(slice(subtitle, subtitle_len));
    if (subtitle_len > 0 && body_len > 0) body_wide += L"\n";
    if (body && body_len > 0) body_wide += widen(slice(body, body_len));

    NOTIFYICONDATAW data = notificationIconData(host);
    if (!data.hWnd) return 0;
    data.uFlags = NIF_INFO;
    data.dwInfoFlags = NIIF_INFO;
    copyWideField(data.szInfoTitle, ARRAYSIZE(data.szInfoTitle), title_wide);
    copyWideField(data.szInfo, ARRAYSIZE(data.szInfo), body_wide);
    return Shell_NotifyIconW(NIM_MODIFY, &data) ? 1 : 0;
}

int zero_native_windows_create_tray(Host *host, const char *icon_path, size_t icon_path_len, const char *tooltip, size_t tooltip_len) {
    if (!host) return 0;
    std::string icon = slice(icon_path, icon_path_len);
    std::string tip = slice(tooltip, tooltip_len);
    if (!setNotificationIcon(host, icon, tip, true)) return 0;
    host->tray_active = true;
    return 1;
}

int zero_native_windows_update_tray_menu(Host *host, const uint32_t *item_ids, const char *const *labels, const size_t *label_lens, const int *separators, const int *enabled_flags, size_t count) {
    if (!host || !host->tray_active) return 0;
    host->tray_items.clear();
    if (count > 0 && (!item_ids || !labels || !label_lens || !separators || !enabled_flags)) return 0;
    host->tray_items.reserve(count);
    for (size_t index = 0; index < count; ++index) {
        TrayItem item;
        item.id = item_ids[index];
        item.label = slice(labels[index], label_lens[index]);
        item.separator = separators[index] != 0;
        item.enabled = enabled_flags[index] != 0;
        if (!item.separator) item.command_id = kTrayCommandBase + static_cast<uint32_t>(index);
        host->tray_items.push_back(item);
    }
    return 1;
}

void zero_native_windows_remove_tray(Host *host) {
    if (!host) return;
    host->tray_active = false;
    host->tray_items.clear();
    removeNotificationIcon(host);
}

int zero_native_windows_open_external_url(Host *host, const char *url, size_t url_len) {
    (void)host;
    if (!url || url_len == 0) return 0;
    std::wstring target = widen(slice(url, url_len));
    HINSTANCE result = ShellExecuteW(nullptr, L"open", target.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    return reinterpret_cast<intptr_t>(result) > 32 ? 1 : 0;
}

int zero_native_windows_reveal_path(Host *host, const char *path, size_t path_len) {
    (void)host;
    if (!path || path_len == 0) return 0;
    std::wstring target = widen(slice(path, path_len));
    std::wstring args = L"/select,\"" + target + L"\"";
    HINSTANCE result = ShellExecuteW(nullptr, L"open", L"explorer.exe", args.c_str(), nullptr, SW_SHOWNORMAL);
    return reinterpret_cast<intptr_t>(result) > 32 ? 1 : 0;
}

int zero_native_windows_add_recent_document(Host *host, const char *path, size_t path_len) {
    (void)host;
    if (!path || path_len == 0) return 0;
    std::wstring target = widen(slice(path, path_len));
    SHAddToRecentDocs(SHARD_PATHW, target.c_str());
    return 1;
}

int zero_native_windows_clear_recent_documents(Host *host) {
    (void)host;
    SHAddToRecentDocs(SHARD_PIDL, nullptr);
    return 1;
}

int zero_native_windows_set_credential(Host *host, const char *service, size_t service_len, const char *account, size_t account_len, const char *secret, size_t secret_len) {
    (void)host;
    if (!service || service_len == 0 || !account || account_len == 0 || !secret || secret_len == 0 || secret_len > UINT32_MAX) return 0;
    HMODULE advapi = LoadLibraryW(L"advapi32.dll");
    if (!advapi) return 0;
    auto cred_write = reinterpret_cast<BOOL (WINAPI *)(PCREDENTIALW, DWORD)>(GetProcAddress(advapi, "CredWriteW"));
    if (!cred_write) {
        FreeLibrary(advapi);
        return 0;
    }

    std::string service_string = slice(service, service_len);
    std::string account_string = slice(account, account_len);
    std::wstring target = credentialTarget(service_string, account_string);
    std::wstring user_name = widen(account_string);
    CREDENTIALW credential = {};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = const_cast<LPWSTR>(target.c_str());
    credential.CredentialBlobSize = static_cast<DWORD>(secret_len);
    credential.CredentialBlob = reinterpret_cast<LPBYTE>(const_cast<char *>(secret));
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    credential.UserName = const_cast<LPWSTR>(user_name.c_str());

    BOOL ok = cred_write(&credential, 0);
    FreeLibrary(advapi);
    return ok ? 1 : 0;
}

size_t zero_native_windows_get_credential(Host *host, const char *service, size_t service_len, const char *account, size_t account_len, char *buffer, size_t buffer_len) {
    (void)host;
    if (!service || service_len == 0 || !account || account_len == 0 || !buffer) return 0;
    HMODULE advapi = LoadLibraryW(L"advapi32.dll");
    if (!advapi) return 0;
    auto cred_read = reinterpret_cast<BOOL (WINAPI *)(LPCWSTR, DWORD, DWORD, PCREDENTIALW *)>(GetProcAddress(advapi, "CredReadW"));
    auto cred_free = reinterpret_cast<void (WINAPI *)(PVOID)>(GetProcAddress(advapi, "CredFree"));
    if (!cred_read || !cred_free) {
        FreeLibrary(advapi);
        return 0;
    }

    std::wstring target = credentialTarget(slice(service, service_len), slice(account, account_len));
    PCREDENTIALW credential = nullptr;
    BOOL ok = cred_read(target.c_str(), CRED_TYPE_GENERIC, 0, &credential);
    if (!ok || !credential) {
        FreeLibrary(advapi);
        return 0;
    }

    size_t secret_len = credential->CredentialBlobSize;
    if (secret_len > buffer_len) {
        cred_free(credential);
        FreeLibrary(advapi);
        return secret_len;
    }
    if (secret_len > 0) memcpy(buffer, credential->CredentialBlob, secret_len);
    cred_free(credential);
    FreeLibrary(advapi);
    return secret_len;
}

int zero_native_windows_delete_credential(Host *host, const char *service, size_t service_len, const char *account, size_t account_len) {
    (void)host;
    if (!service || service_len == 0 || !account || account_len == 0) return 0;
    HMODULE advapi = LoadLibraryW(L"advapi32.dll");
    if (!advapi) return 0;
    auto cred_delete = reinterpret_cast<BOOL (WINAPI *)(LPCWSTR, DWORD, DWORD)>(GetProcAddress(advapi, "CredDeleteW"));
    if (!cred_delete) {
        FreeLibrary(advapi);
        return 0;
    }

    std::wstring target = credentialTarget(slice(service, service_len), slice(account, account_len));
    BOOL ok = cred_delete(target.c_str(), CRED_TYPE_GENERIC, 0);
    FreeLibrary(advapi);
    return ok ? 1 : 0;
}

int zero_native_windows_create_webview(Host *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len, double x, double y, double width, double height, int layer, int transparent, int bridge_enabled) {
#if !ZERO_NATIVE_HAS_WEBVIEW2
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    (void)url;
    (void)url_len;
    (void)x;
    (void)y;
    (void)width;
    (void)height;
    (void)layer;
    (void)transparent;
    (void)bridge_enabled;
    return 0;
#else
    if (!host || label_len == 0 || url_len == 0 || !validChildWebViewFrame(x, y, width, height)) return 0;
    auto window = host->windows.find(window_id);
    if (window == host->windows.end() || !window->second.hwnd) return 0;
    std::string label_string = slice(label, label_len);
    std::string key = webViewKey(window_id, label_string);
    if (host->webviews.find(key) != host->webviews.end()) return 0;

    std::string url_string = slice(url, url_len);
    HWND hwnd = CreateWindowExW(
        0,
        L"STATIC",
        L"",
        WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
        webViewCoord(x),
        webViewCoord(y),
        webViewExtent(width),
        webViewExtent(height),
        window->second.hwnd,
        nullptr,
        host->instance,
        nullptr);
    if (!hwnd) return 0;

    ChildWebView webview;
    webview.window_id = window_id;
    webview.hwnd = hwnd;
    webview.label = label_string;
    webview.url = url_string;
    webview.x = x;
    webview.y = y;
    webview.width = width;
    webview.height = height;
    webview.layer = layer;
    webview.creation_order = host->next_child_order++;
    webview.transparent = transparent != 0;
    webview.bridge_enabled = bridge_enabled != 0;
    host->webviews[key] = webview;
    applyChildWebViewLayer(host, window_id, label_string);
    if (!createChildWebView(host, key)) {
        DestroyWindow(hwnd);
        host->webviews.erase(key);
        return 0;
    }
    return 1;
#endif
}

int zero_native_windows_set_webview_frame(Host *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height) {
    if (!host || label_len == 0 || !validChildWebViewFrame(x, y, width, height)) return 0;
    if (slice(label, label_len) == "main") return 1;
    auto found = host->webviews.find(webViewKey(window_id, slice(label, label_len)));
    if (found == host->webviews.end() || !found->second.hwnd) return 0;
    found->second.x = x;
    found->second.y = y;
    found->second.width = width;
    found->second.height = height;
    MoveWindow(found->second.hwnd, webViewCoord(x), webViewCoord(y), webViewExtent(width), webViewExtent(height), TRUE);
#if ZERO_NATIVE_HAS_WEBVIEW2
    if (found->second.controller) {
        RECT bounds = webViewRect(found->second);
        found->second.controller->put_Bounds(bounds);
    }
#endif
    return 1;
}

int zero_native_windows_navigate_webview(Host *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len) {
#if !ZERO_NATIVE_HAS_WEBVIEW2
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    (void)url;
    (void)url_len;
    return 0;
#else
    if (!host || label_len == 0 || url_len == 0) return 0;
    auto found = host->webviews.find(webViewKey(window_id, slice(label, label_len)));
    if (found == host->webviews.end() || !found->second.hwnd) return 0;
    found->second.url = slice(url, url_len);
    if (found->second.webview) {
        std::wstring target = widen(found->second.url);
        found->second.webview->Navigate(target.c_str());
        return 1;
    }
    // WebView2 initializes asynchronously; keep the newest URL and apply it in the creation callback.
    return 1;
#endif
}

int zero_native_windows_set_webview_zoom(Host *host, uint64_t window_id, const char *label, size_t label_len, double zoom) {
#if !ZERO_NATIVE_HAS_WEBVIEW2
    (void)host;
    (void)window_id;
    (void)label;
    (void)label_len;
    (void)zoom;
    return 0;
#else
    if (!host || label_len == 0 || zoom < 0.25 || zoom > 5.0) return 0;
    std::string label_string = slice(label, label_len);
    if (label_string == "main") return 0;
    auto found = host->webviews.find(webViewKey(window_id, label_string));
    if (found == host->webviews.end() || !found->second.hwnd) return 0;
    found->second.zoom = zoom;
    if (found->second.controller) {
        found->second.controller->put_ZoomFactor(zoom);
    }
    return 1;
#endif
}

int zero_native_windows_set_webview_layer(Host *host, uint64_t window_id, const char *label, size_t label_len, int layer) {
    if (!host || label_len == 0) return 0;
    std::string label_string = slice(label, label_len);
    if (label_string == "main") return 0;
    auto found = host->webviews.find(webViewKey(window_id, label_string));
    if (found == host->webviews.end() || !found->second.hwnd) return 0;
    found->second.layer = layer;
    applyChildWebViewLayer(host, window_id, label_string);
    return 1;
}

int zero_native_windows_close_webview(Host *host, uint64_t window_id, const char *label, size_t label_len) {
    if (!host || label_len == 0) return 0;
    auto found = host->webviews.find(webViewKey(window_id, slice(label, label_len)));
    if (found == host->webviews.end()) return 0;
#if ZERO_NATIVE_HAS_WEBVIEW2
    if (found->second.controller) found->second.controller->Close();
#endif
    if (found->second.hwnd) DestroyWindow(found->second.hwnd);
    host->webviews.erase(found);
    return 1;
}

size_t zero_native_windows_clipboard_read(Host *host, char *buffer, size_t buffer_len) {
    return zero_native_windows_clipboard_read_data(host, "text/plain", strlen("text/plain"), buffer, buffer_len);
}

void zero_native_windows_clipboard_write(Host *host, const char *text, size_t text_len) {
    (void)zero_native_windows_clipboard_write_data(host, "text/plain", strlen("text/plain"), text, text_len);
}

size_t zero_native_windows_clipboard_read_data(Host *host, const char *mime_type, size_t mime_type_len, char *buffer, size_t buffer_len) {
    (void)host;
    UINT format = clipboardFormatForMime(mime_type, mime_type_len);
    if (!format || !buffer || buffer_len == 0 || !OpenClipboard(nullptr)) return 0;
    HANDLE handle = GetClipboardData(format);
    if (!handle) {
        CloseClipboard();
        return 0;
    }
    void *locked = GlobalLock(handle);
    if (!locked) {
        CloseClipboard();
        return 0;
    }
    std::string bytes;
    if (format == CF_UNICODETEXT) {
        const wchar_t *wide_text = static_cast<const wchar_t *>(locked);
        size_t wide_limit = GlobalSize(handle) / sizeof(wchar_t);
        bytes = narrow(std::wstring(wide_text, boundedWideLen(wide_text, wide_limit)));
    } else {
        const char *data = static_cast<const char *>(locked);
        size_t data_len = GlobalSize(handle);
        if (data_len > 0 && data[data_len - 1] == '\0') data_len--;
        bytes.assign(data, data_len);
        if (format == htmlClipboardFormat()) bytes = extractHtmlClipboardFragment(bytes);
    }
    size_t copied = copyBytesToBuffer(buffer, buffer_len, bytes);
    GlobalUnlock(handle);
    CloseClipboard();
    return copied;
}

int zero_native_windows_clipboard_write_data(Host *host, const char *mime_type, size_t mime_type_len, const char *bytes, size_t bytes_len) {
    (void)host;
    UINT format = clipboardFormatForMime(mime_type, mime_type_len);
    if (!format || (!bytes && bytes_len > 0) || !OpenClipboard(nullptr)) return 0;
    EmptyClipboard();

    HGLOBAL handle = nullptr;
    if (format == CF_UNICODETEXT) {
        std::wstring wide = widen(slice(bytes, bytes_len));
        size_t byte_count = (wide.size() + 1) * sizeof(wchar_t);
        handle = GlobalAlloc(GMEM_MOVEABLE, byte_count);
        if (handle) {
            wchar_t *dest = static_cast<wchar_t *>(GlobalLock(handle));
            if (wide.size() > 0) memcpy(dest, wide.data(), wide.size() * sizeof(wchar_t));
            dest[wide.size()] = L'\0';
            GlobalUnlock(handle);
        }
    } else {
        std::string payload = format == htmlClipboardFormat()
            ? htmlClipboardPayload(slice(bytes, bytes_len))
            : slice(bytes, bytes_len);
        handle = GlobalAlloc(GMEM_MOVEABLE, payload.size() + 1);
        if (handle) {
            char *dest = static_cast<char *>(GlobalLock(handle));
            if (payload.size() > 0) memcpy(dest, payload.data(), payload.size());
            dest[payload.size()] = '\0';
            GlobalUnlock(handle);
        }
    }

    int ok = 0;
    if (handle) {
        if (SetClipboardData(format, handle)) {
            ok = 1;
            handle = nullptr;
        }
    }
    if (handle) GlobalFree(handle);
    CloseClipboard();
    return ok;
}

}
