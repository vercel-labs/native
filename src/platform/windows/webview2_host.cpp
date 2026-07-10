#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wincred.h>
#include <objbase.h>
#include <commctrl.h>
#include <oleacc.h>
#include <wincodec.h>
#include <uxtheme.h>
#include <dwmapi.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <climits>
#include <cmath>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#if __has_include(<WebView2.h>) && __has_include(<wrl.h>)
#include <WebView2.h>
#include <wrl.h>
#define NATIVE_SDK_HAS_WEBVIEW2 1
using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
#else
#define NATIVE_SDK_HAS_WEBVIEW2 0
/* Loud on purpose: without the WebView2 SDK header on the include path
 * the host builds with the embedded WebView layer stubbed out — canvas
 * apps are unaffected, but apps that load a WebView report
 * WebViewNotFound at start. */
#pragma message("WebView2.h not found: building the Windows host without the embedded WebView layer (canvas apps unaffected; WebView loads will report WebViewNotFound)")
#endif

/* Media Foundation (the audio backend below) + WinHTTP (the audio cache
 * fill). initguid.h makes the DEFINE_GUID declarations in the MF headers
 * instantiate here (selectany), so no separate GUID import library is
 * needed — the same self-containment the WIC decoder uses further down.
 * Included last so only the Media Foundation GUIDs are affected. */
#include <initguid.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mferror.h>
#include <winhttp.h>

/* WASAPI process-scoped loopback (the spectrum analysis capture below).
 * The activation-parameter declarations arrived with the Windows 10 2004
 * SDK in audioclientactivationparams.h; the mingw-w64 headers zig ships
 * do not carry that file yet, so the handful of structures are declared
 * locally when it is absent — byte-for-byte the OS ABI layout.
 * ActivateAudioInterfaceAsync itself is resolved from mmdevapi.dll at
 * runtime, so no new import library enters the build. */
#include <mmdeviceapi.h>
#include <audioclient.h>
#if __has_include(<audioclientactivationparams.h>)
#include <audioclientactivationparams.h>
#else
typedef enum {
    AUDIOCLIENT_ACTIVATION_TYPE_DEFAULT = 0,
    AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK = 1,
} AUDIOCLIENT_ACTIVATION_TYPE;

typedef enum {
    PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE = 0,
    PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE = 1,
} PROCESS_LOOPBACK_MODE;

typedef struct {
    DWORD TargetProcessId;
    PROCESS_LOOPBACK_MODE ProcessLoopbackMode;
} AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS;

typedef struct {
    AUDIOCLIENT_ACTIVATION_TYPE ActivationType;
    union {
        AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS ProcessLoopbackParams;
    };
} AUDIOCLIENT_ACTIVATION_PARAMS;

#define VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK L"VAD\\Process_Loopback"
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
    kGpuSurfaceFrame = 12,
    kGpuSurfaceResize = 13,
    kGpuSurfaceInput = 14,
    kWake = 15,
    kTimer = 16,
    kAppearance = 17,
    kAudio = 18,
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
/* Posted from any thread (effect worker threads) via
 * native_sdk_windows_wake; the window procedure emits kWake on the
 * message loop thread. */
constexpr UINT kWakeMessage = WM_APP + 43;
/* Posted from any thread via native_sdk_windows_request_frame; the
 * window procedure emits ONE kFrame on the message loop thread. The
 * automation arrival watcher uses it so a queued command wakes an idle
 * frame loop without depending on the 16 ms frame pump. */
constexpr UINT kRequestFrameMessage = WM_APP + 44;
/* Posted from Media Foundation worker threads (the audio backend's event
 * pump and source resolver); the window procedure hands the distilled
 * note to audioHandleSessionMessage on the message loop thread. */
constexpr UINT kAudioSessionMessage = WM_APP + 45;
/* Posted from the spectrum capture thread every ~40 ms; the window
 * procedure snapshots the analysis bands and emits one SPECTRUM report
 * on the loop thread. A posted message rather than a loop-thread timer
 * on purpose: WM_TIMER is the lowest-priority message and a busy frame
 * loop starves it far below the contract cadence, while posted messages
 * keep their place in the queue. */
constexpr UINT kAudioSpectrumMessage = WM_APP + 46;
constexpr const char *kAssetVirtualOrigin = "https://native-sdk-app.localhost";

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
constexpr int kViewListItem = 18;

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
    uint64_t frame_index;
    uint64_t timestamp_ns;
    uint64_t frame_interval_ns;
    int nonblank;
    uint32_t sample_color;
    /* Nonzero when the frame completed logically while the top-level
     * window was minimized (heartbeat pacing; nothing painted): its
     * timestamp is pacing policy, never a latency endpoint. */
    int occluded;
    int input_kind;
    int button;
    double delta_x;
    double delta_y;
    const char *key_text;
    size_t key_text_len;
    const char *input_text;
    size_t input_text_len;
    int has_composition_cursor;
    size_t composition_cursor;
    uint64_t timer_id;
    int color_scheme;
    int reduce_motion;
    int high_contrast;
    int audio_kind;
    uint64_t audio_position_ms;
    uint64_t audio_duration_ms;
    int audio_playing;
    int audio_buffering;
    /* SPECTRUM report payload: the 32 band magnitude bytes on the
     * documented scale (log-spaced 50 Hz..16 kHz buckets, linear-in-dB
     * from -60 dBFS at 0 to full scale at 255). Zeros on every other
     * event kind — every emit site value-initializes the struct. */
    uint8_t audio_bands[32];
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
    bool resizable = true;
    /* 0 standard, 1 hidden_inset, 2 hidden_inset_tall. The hidden styles
     * keep the FULL system frame and the DWM-drawn caption buttons; only
     * the caption band is handed to the client (WM_NCCALCSIZE), so the
     * app draws its header into the band while min/max/close, snap
     * layouts, and the resize borders stay the OS's own. */
    int titlebar_style = 0;
    /* Declared content min-size floor for user resizes; axes <= 0 keep
     * the natural minimum (WM_GETMINMAXINFO applies the floor). */
    double min_width = 0;
    double min_height = 0;
    /* Last DWMWA_CAPTION_COLOR pushed for the hidden styles (sampled
     * from the presented header pixels so the DWM caption material
     * behind the button cluster matches the app's header). */
    COLORREF hidden_caption_color = 0;
    bool hidden_caption_color_set = false;
};

/* One rectangle of a canvas view's window-drag mirror (runtime push,
 * view-local logical coordinates). `exclusion` rects are the
 * press-claiming widgets INSIDE a drag region — a point is draggable
 * only inside a region rect and outside every exclusion rect, the same
 * carve-out the runtime's own pointer walk applies. */
struct DragRegionRect {
    double x = 0;
    double y = 0;
    double width = 0;
    double height = 0;
    bool exclusion = false;
};

struct ChildWebView {
    uint64_t window_id = 1;
    HWND hwnd = nullptr;
    std::string label;
    std::string url;
    std::string source;
    int source_kind = 1;
    std::string asset_root;
    std::string asset_entry;
    std::string asset_origin;
    bool spa_fallback = false;
    double x = 0;
    double y = 0;
    double width = 0;
    double height = 0;
    double zoom = 1.0;
    int layer = 0;
    uint64_t creation_order = 0;
    bool transparent = false;
    bool bridge_enabled = false;
    bool frame_explicit = true;
#if NATIVE_SDK_HAS_WEBVIEW2
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
    /* gpu_surface (software canvas) state */
    std::vector<uint8_t> gpu_bgra;
    int gpu_buf_width = 0;
    int gpu_buf_height = 0;
    /* ONE frame-event scheduler per surface (the macOS design): every
     * producer that wants a frame event — runtime frame requests, pixel
     * presents (the completion analog), the pre-first-present placeholder
     * pump — funnels through gpuSurfaceScheduleFrameEmission, which keeps
     * at most one emission in flight (a one-shot WM_TIMER) and fires it
     * on the frame-interval grid anchored at gpu_last_emit_ns. Producers
     * landing while one is queued fold into it: their facts (nonblank,
     * sample color, buffer contents) are already view state when the
     * emission fires. gpu_presented flips on the first present and
     * retires the placeholder pump — from then on frames are
     * demand-driven, so an idle surface emits ZERO frame events (the
     * idle law the macOS host enforces). */
    bool gpu_emission_scheduled = false;
    bool gpu_presented = false;
    /* One-shot: the next scheduled emission must fire at grid
     * promptness even while minimized. Two producers set it — an input
     * dispatched to the surface (its responding frame is the
     * input-latency stamp's endpoint; see
     * native_sdk_windows_note_gpu_surface_input) and the FIRST present
     * (its emission carries the nonblank verdict automation reads).
     * Neither can sustain a spin. Cleared when the emission fires. */
    bool gpu_prompt_frame_pending = false;
    uint64_t gpu_last_emit_ns = 0;
    uint64_t gpu_frame_index = 0;
    double gpu_emitted_width = 0;
    double gpu_emitted_height = 0;
    double gpu_emitted_scale = 0;
    int gpu_nonblank = 0;
    uint32_t gpu_sample_color = 0;
    int gpu_pointer_down = 0;
    double gpu_pointer_x = 0;
    double gpu_pointer_y = 0;
    WCHAR gpu_pending_high_surrogate = 0;
    /* UTF-8 preedit last sent as ime_set_composition; empty = no active
     * composition. Mirrors gpu_preedit_text in the GTK host and markedText
     * in the AppKit host. */
    std::string gpu_ime_preedit;
    /* The runtime-pushed window-drag mirror (hidden-titlebar windows):
     * WM_NCHITTEST consults it so the markup's drag header behaves like
     * the system caption. */
    std::vector<DragRegionRect> drag_regions;
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

/* App timers (runtime `startTimer`) on the Win32 message loop: each slot
 * owns the SetTimer id kAppTimerIdBase + slot index, scheduled on the
 * first live top-level window so WM_TIMER lands in windowProc. */
constexpr size_t kMaxAppTimers = 64;
constexpr UINT_PTR kAppTimerIdBase = 0x1000;
/* The 16 ms per-window frame-pump timer (SetTimer id on each top-level
 * window; distinct from the app-timer id range). */
constexpr UINT_PTR kFrameTimerId = 1;

struct AppTimer {
    uint64_t id = 0;
    HWND hwnd = nullptr;
    bool repeats = false;
    bool in_use = false;
};

/* Cancellation handle for the audio cache-fill download: the host and
 * the detached download thread share it, so a replaced or stopped
 * playback can abandon the transfer without touching thread state. */
struct AudioDownloadCancel {
    std::atomic<bool> cancelled{false};
};

/* Band count of a SPECTRUM audio report — part of the event ABI on
 * every host (see the spectrum analysis section further down). */
constexpr size_t kAudioSpectrumBandCount = 32;

/* State shared between the loop thread and the detached spectrum
 * capture thread, download-cancel style: the loop thread flips `stop`
 * and drops its reference; the capture thread owns its own reference
 * and winds down without anyone blocking on a join. `bands` is the
 * freshest analysis snapshot; `hwnd` and `generation` are fixed before
 * the thread starts (the emission posts carry the generation so a
 * replaced capture's stragglers are dropped on the loop side). */
struct AudioSpectrumShared {
    std::atomic<bool> stop{false};
    std::mutex mutex;
    uint8_t bands[kAudioSpectrumBandCount] = {};
    HWND hwnd = nullptr;
    uint64_t generation = 0;
};

/* The loop-thread half of spectrum analysis: the live capture handle
 * (null while idle) and the running generation stamp. Deliberately
 * OUTSIDE AudioState — releaseSession resets that struct wholesale, and
 * the capture teardown must run as an explicit step, not a field wipe. */
struct AudioSpectrumState {
    std::shared_ptr<AudioSpectrumShared> shared;
    uint64_t generation = 0;
};

/* The app's single audio player (see the audio section further down for
 * the backend rationale). All fields are message-loop-thread state; the
 * lifetime mutex additionally guards `generation` and `source` because
 * the asynchronous URL source resolver hands its result over from a
 * Media Foundation worker thread. */
struct AudioState {
    /* Bumped on every load/stop: worker-thread stragglers (resolver
     * completions, retired-session events) carry the generation they
     * were born with and are ignored when it no longer matches. */
    uint64_t generation = 0;
    bool active = false;
    bool url_source = false;
    /* Topology resolved: transport calls apply directly; before this
     * they queue as pending_play / pending seek. */
    bool ready = false;
    /* Transport intent (un-paused), the `playing` flag events carry. */
    bool playing = false;
    /* The honest buffering mirror: true from a stream's load until the
     * session actually starts, and across MEBufferingStarted/Stopped. */
    bool buffering = false;
    bool loaded_emitted = false;
    bool pending_play = false;
    bool has_pending_seek = false;
    bool position_timer_armed = false;
    float volume = 1.0f;
    uint64_t pending_seek_ms = 0;
    uint64_t duration_ms = 0;
    HWND timer_hwnd = nullptr;
    IMFMediaSession *session = nullptr;
    IMFMediaSource *source = nullptr;
    IMFPresentationClock *clock = nullptr;
    std::shared_ptr<AudioDownloadCancel> download_cancel;
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
    AppTimer app_timers[kMaxAppTimers];
    /* Last emitted appearance values; -1 = nothing emitted yet, so the
     * post-start emission always fires and setting-change re-reads only
     * emit when something actually changed. */
    int appearance_color_scheme = -1;
    int appearance_reduce_motion = -1;
    int appearance_high_contrast = -1;
    AudioState audio;
    AudioSpectrumState spectrum;
    std::shared_ptr<HostLifetime> lifetime = std::make_shared<HostLifetime>();
};

static std::string webViewKey(uint64_t window_id, const std::string &label);

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
    return L"native-sdk:" + std::to_wstring(service_wide.size()) + L":" + service_wide + account_wide;
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
    std::wstring tip = widen(!tooltip.empty() ? tooltip : (host->app_name.empty() ? std::string("native-sdk") : host->app_name));
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

static size_t overflowSize(size_t buffer_len) {
    return buffer_len == SIZE_MAX ? SIZE_MAX : buffer_len + 1;
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
    if (path.empty()) return true;
    size_t needed = path.size() + (*count > 0 ? 1 : 0);
    if (needed > buffer_len - *offset) {
        *offset = overflowSize(buffer_len);
        return false;
    }
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

static std::string trimLeadingPathSeparators(std::string value) {
    while (!value.empty() && (value.front() == '/' || value.front() == '\\')) value.erase(value.begin());
    return value;
}

static std::string assetOrigin(const ChildWebView &webview) {
    return webview.asset_origin.empty() ? std::string("zero://app") : webview.asset_origin;
}

static bool isHexDigit(char ch) {
    return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F');
}

static unsigned char hexByte(char high, char low) {
    auto nibble = [](char ch) -> unsigned char {
        if (ch >= '0' && ch <= '9') return static_cast<unsigned char>(ch - '0');
        if (ch >= 'a' && ch <= 'f') return static_cast<unsigned char>(ch - 'a' + 10);
        return static_cast<unsigned char>(ch - 'A' + 10);
    };
    return static_cast<unsigned char>((nibble(high) << 4) | nibble(low));
}

static bool urlDecodePath(const std::string &value, std::string *out) {
    if (!out) return false;
    out->clear();
    for (size_t index = 0; index < value.size(); ++index) {
        char ch = value[index];
        if (ch == '%') {
            if (index + 2 >= value.size() || !isHexDigit(value[index + 1]) || !isHexDigit(value[index + 2])) return false;
            out->push_back(static_cast<char>(hexByte(value[index + 1], value[index + 2])));
            index += 2;
        } else {
            out->push_back(ch);
        }
    }
    return true;
}

static bool safeAssetRelativePath(const std::string &value) {
    if (value.empty()) return false;
    size_t start = 0;
    while (start <= value.size()) {
        size_t end = value.find('/', start);
        if (end == std::string::npos) end = value.size();
        std::string segment = value.substr(start, end - start);
        if (!segment.empty()) {
            if (segment == "." || segment == "..") return false;
            for (unsigned char ch : segment) {
                if (ch < 0x20 || ch == 0x7f || ch == '\\' || ch == ':') return false;
            }
        }
        if (end == value.size()) break;
        start = end + 1;
    }
    return true;
}

static std::string safeAssetEntryPath(const std::string &entry) {
    std::string clean_entry = trimLeadingPathSeparators(entry.empty() ? std::string("index.html") : entry);
    return safeAssetRelativePath(clean_entry) ? clean_entry : std::string("index.html");
}

static bool assetRelativePathFromUrl(const std::string &url, const std::string &entry, std::string *out) {
    if (!out) return false;
    std::string raw;
    size_t scheme_end = url.find("://");
    size_t path_start = scheme_end == std::string::npos ? std::string::npos : url.find('/', scheme_end + 3);
    if (path_start == std::string::npos) {
        raw = entry.empty() ? std::string("index.html") : entry;
    } else {
        size_t path_end = url.find_first_of("?#", path_start);
        raw = url.substr(path_start + 1, path_end == std::string::npos ? std::string::npos : path_end - path_start - 1);
    }

    std::string decoded;
    if (!urlDecodePath(raw, &decoded)) return false;
    decoded = trimLeadingPathSeparators(decoded);
    if (decoded.empty()) decoded = entry.empty() ? std::string("index.html") : trimLeadingPathSeparators(entry);
    if (!safeAssetRelativePath(decoded)) return false;
    *out = decoded;
    return true;
}

static std::string originAssetEntryUrl(const std::string &entry, const std::string &origin) {
    std::string clean_entry = safeAssetEntryPath(entry);
    std::string base = origin.empty() ? std::string("zero://app") : origin;
    if (!base.empty() && base.back() != '/') base.push_back('/');
    return base + clean_entry;
}

static std::string virtualAssetEntryUrl(const std::string &entry) {
    return originAssetEntryUrl(entry, kAssetVirtualOrigin);
}

static std::string urlQueryOrFragmentSuffix(const std::string &url) {
    size_t scheme_end = url.find("://");
    size_t search_start = scheme_end == std::string::npos ? 0 : scheme_end + 3;
    size_t suffix_start = url.find_first_of("?#", search_start);
    return suffix_start == std::string::npos ? std::string() : url.substr(suffix_start);
}

static std::string assetEntryUrl(const ChildWebView &webview) {
    if (!webview.url.empty() && originForUrl(webview.url) == assetOrigin(webview)) {
        std::string relative;
        if (assetRelativePathFromUrl(webview.url, webview.asset_entry, &relative)) {
            return virtualAssetEntryUrl(relative) + urlQueryOrFragmentSuffix(webview.url);
        }
    }
    return virtualAssetEntryUrl(webview.asset_entry);
}

static bool inheritAssetSourceForUrl(Host *host, uint64_t window_id, ChildWebView &webview, const std::string &url) {
    if (!host) return false;
    auto main = host->webviews.find(webViewKey(window_id, "main"));
    if (main == host->webviews.end() || main->second.source_kind != 2) return false;
    if (originForUrl(url) != assetOrigin(main->second)) return false;
    webview.source_kind = 2;
    webview.asset_root = main->second.asset_root;
    webview.asset_entry = main->second.asset_entry;
    webview.asset_origin = main->second.asset_origin;
    webview.spa_fallback = main->second.spa_fallback;
    return true;
}

static bool isInternalAssetUrl(const ChildWebView &webview, const std::string &url) {
    if (webview.source_kind != 2) return false;
    const std::string origin = originForUrl(url);
    if (!webview.asset_root.empty() && origin == kAssetVirtualOrigin) return true;
    return origin == assetOrigin(webview);
}

static std::string bridgeOriginForWebViewUrl(const ChildWebView &webview, const std::string &url) {
    return isInternalAssetUrl(webview, url) ? assetOrigin(webview) : originForUrl(url);
}

static std::wstring assetFilePath(const ChildWebView &webview, const std::string &relative) {
    std::string path = webview.asset_root.empty() ? std::string(".") : webview.asset_root;
    if (!path.empty() && path.back() != '/' && path.back() != '\\') path.push_back('\\');
    std::string native_relative = relative;
    std::replace(native_relative.begin(), native_relative.end(), '/', '\\');
    path += native_relative;
    return widen(path);
}

static bool regularFileExists(const std::wstring &path) {
    DWORD attrs = GetFileAttributesW(path.c_str());
    return attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

static bool readFileBytes(const std::wstring &path, std::string *out) {
    if (!out) return false;
    out->clear();
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER size = {};
    if (!GetFileSizeEx(file, &size) || size.QuadPart < 0) {
        CloseHandle(file);
        return false;
    }
    if (size.QuadPart == 0) {
        CloseHandle(file);
        return true;
    }
    out->resize(static_cast<size_t>(size.QuadPart));
    size_t offset = 0;
    while (offset < out->size()) {
        DWORD chunk = static_cast<DWORD>(std::min<size_t>(out->size() - offset, 64 * 1024));
        DWORD read = 0;
        if (!ReadFile(file, &(*out)[offset], chunk, &read, nullptr) || read == 0) {
            CloseHandle(file);
            return false;
        }
        offset += read;
    }
    CloseHandle(file);
    return true;
}

static std::string mimeTypeForPath(const std::string &path) {
    size_t dot = path.find_last_of('.');
    std::string ext = dot == std::string::npos ? std::string() : path.substr(dot + 1);
    for (char &ch : ext) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    if (ext == "html" || ext == "htm") return "text/html";
    if (ext == "js" || ext == "mjs") return "text/javascript";
    if (ext == "css") return "text/css";
    if (ext == "json") return "application/json";
    if (ext == "svg") return "image/svg+xml";
    if (ext == "png") return "image/png";
    if (ext == "jpg" || ext == "jpeg") return "image/jpeg";
    if (ext == "gif") return "image/gif";
    if (ext == "webp") return "image/webp";
    if (ext == "woff") return "font/woff";
    if (ext == "woff2") return "font/woff2";
    if (ext == "ttf") return "font/ttf";
    if (ext == "otf") return "font/otf";
    if (ext == "wasm") return "application/wasm";
    return "application/octet-stream";
}

static bool policyWildcardPrefixHasPath(const std::string &prefix) {
    size_t scheme_end = prefix.find("://");
    if (scheme_end == std::string::npos) return false;
    size_t host_start = scheme_end + 3;
    if (host_start >= prefix.size()) return false;
    size_t slash = prefix.find('/', host_start);
    return slash != std::string::npos && slash > host_start;
}

static bool policyListMatches(const std::vector<std::string> &values, const std::string &url) {
    std::string origin = originForUrl(url);
    for (const std::string &value : values) {
        if (value == "*" || value == origin || value == url) return true;
        if (!value.empty() && value.back() == '*') {
            const std::string prefix = value.substr(0, value.size() - 1);
            if (policyWildcardPrefixHasPath(prefix) && url.rfind(prefix, 0) == 0) return true;
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
    return bytes.size();
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

static UINT dpiForWindow(HWND hwnd);

static void emit(Host *host, const Window &window, EventKind kind) {
    if (!host || !host->callback) return;
    RECT rect = {};
    if (window.hwnd) GetClientRect(window.hwnd, &rect);
    WindowsEvent event = {};
    event.kind = kind;
    event.window_id = window.id;
    /* Window geometry crosses the runtime boundary in LOGICAL points:
     * the client rect is physical pixels, so divide by the window's
     * device scale. In a DPI-unaware process the reported DPI is 96 and
     * the two units coincide, so this stays the identity there. */
    const double scale = window.hwnd ? (double)dpiForWindow(window.hwnd) / 96.0 : 1.0;
    event.width = rect.right > rect.left ? (double)(rect.right - rect.left) / scale : window.width;
    event.height = rect.bottom > rect.top ? (double)(rect.bottom - rect.top) / scale : window.height;
    event.scale = scale;
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
        if (!paths.empty()) paths.push_back('\0');
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

/* Explicit webview frames arrive from the runtime in LOGICAL points and
 * scale to physical pixels at the window's DPI, exactly like native view
 * frames. The auto-filling main webview is the one exception: its frame
 * is copied straight from the physical client rect (the top-level
 * WM_SIZE handler), so it passes through unscaled. */
static double webViewFrameScale(const ChildWebView &webview) {
    if (!webview.frame_explicit || !webview.hwnd) return 1.0;
    return (double)dpiForWindow(webview.hwnd) / 96.0;
}

static bool validChildWebViewFrame(double x, double y, double width, double height) {
    return x >= 0 && y >= 0 && width > 0 && height > 0;
}

static constexpr int nativeViewCoord(double value) {
    return value > 0 ? (int)(value + 0.5) : 0;
}

/* Compile-time proof of the accumulate-then-round frame policy (see
 * nativeViewPhysicalFrame): rounding each nesting level separately drifts
 * from the round of the logical sum — parent x=10.4 plus child x=10.4 at
 * scale 1.5 is round(15.6) + round(15.6) = 32, one pixel right of the
 * true origin round(20.8 * 1.5) = 31 — and an independently rounded
 * extent opens the same one-pixel seam against an edge derived from the
 * accumulated logical coordinates: origin 10.2 with width 10.2 at scale
 * 1.5 ends at round(15.3) + round(15.3) = 30, but the true right edge is
 * round(20.4 * 1.5) = 31. */
static_assert(nativeViewCoord(10.4 * 1.5) + nativeViewCoord(10.4 * 1.5) == 32 && nativeViewCoord((10.4 + 10.4) * 1.5) == 31,
    "per-level rounding must drift so the accumulate-then-round policy is load-bearing");
static_assert(nativeViewCoord(10.2 * 1.5) + nativeViewCoord(10.2 * 1.5) == 30 && nativeViewCoord((10.2 + 10.2) * 1.5) == 31,
    "independently rounded extents must open seams that edge-derived extents close");

/* A scaled window CONTENT extent rounded to whole physical pixels — the
 * same round-once policy as native view frames (see
 * nativeViewPhysicalFrame). Truncating instead would land fractional-DPI
 * windows one physical pixel short of the request: logical 726 at 125%
 * is 907.5 physical, which must become 908, not 907. Every conversion of
 * a scaled content size to a physical extent goes through here so the
 * standard-chrome and hidden-titlebar paths cannot drift apart. */
static constexpr LONG physicalContentExtent(double value) {
    return (LONG)(value + 0.5);
}

static_assert(physicalContentExtent(726 * 1.25) == 908 && (LONG)(726 * 1.25) == 907,
    "truncation must land a pixel short of the round so the rounding is load-bearing");

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
        kind == kViewListItem ||
        kind == kViewCheckbox ||
        kind == kViewToggle ||
        kind == kViewSegmentedControl ||
        kind == kViewTextField ||
        kind == kViewSearchField ||
        kind == kViewLabel ||
        kind == kViewProgressIndicator ||
        kind == kViewGpuSurface;
}

static std::string nativeViewDisplayText(const NativeView &view) {
    if (!view.text.empty()) return view.text;
    if (!view.role.empty()) return view.role;
    return view.label;
}

static std::string nativeViewAccessibilityName(const NativeView &view) {
    if (!view.accessibility_label.empty()) return view.accessibility_label;
    if (!view.role.empty()) return view.role;
    return nativeViewDisplayText(view);
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

/* Scale for converting the runtime's LOGICAL view frames into physical
 * client pixels: the owning top-level window's DPI over 96. A
 * DPI-unaware process reports 96, so this is 1.0 there and view frames
 * pass through unchanged. */
static double nativeViewFrameScale(Host *host, const NativeView &view) {
    if (!host) return 1.0;
    auto window = host->windows.find(view.window_id);
    if (window == host->windows.end() || !window->second.hwnd) return 1.0;
    return (double)dpiForWindow(window->second.hwnd) / 96.0;
}

/* Absolute LOGICAL origin of a view: its own frame origin plus every
 * ancestor's, summed before any scaling or rounding. */
static void nativeViewLogicalOrigin(Host *host, const NativeView &view, double *logical_x, double *logical_y) {
    *logical_x = view.x;
    *logical_y = view.y;
    if (!host || view.parent.empty()) return;
    auto parent = host->native_views.find(nativeViewKey(view.window_id, view.parent));
    while (parent != host->native_views.end()) {
        *logical_x += parent->second.x;
        *logical_y += parent->second.y;
        if (parent->second.parent.empty()) break;
        parent = host->native_views.find(nativeViewKey(parent->second.window_id, parent->second.parent));
    }
}

/* Physical frame policy: every physical EDGE is the once-rounded product
 * of an ACCUMULATED logical coordinate and the window scale. Accumulating
 * before rounding matters because the sum of per-level rounds drifts from
 * the round of the sum at fractional scales (and at fractional logical
 * coordinates even at scale 1.0) — see the static_asserts beside
 * nativeViewCoord for the numeric proof. Width and height fall out as
 * edge differences (right = round((logical_x + width) * scale)) rather
 * than independently rounded extents, so frames that abut logically —
 * a sibling starting where the previous one ends, a child flush against
 * its parent's edge — land on the same physical pixel column with no
 * one-pixel gap or overlap at any scale. */
static RECT nativeViewPhysicalFrame(Host *host, const NativeView &view, double scale) {
    double logical_x = 0;
    double logical_y = 0;
    nativeViewLogicalOrigin(host, view, &logical_x, &logical_y);
    RECT frame = {};
    frame.left = nativeViewCoord(logical_x * scale);
    frame.top = nativeViewCoord(logical_y * scale);
    frame.right = nativeViewCoord((logical_x + view.width) * scale);
    frame.bottom = nativeViewCoord((logical_y + view.height) * scale);
    return frame;
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
        case kViewGpuSurface:
            break;
        default:
            SetWindowTextW(view.hwnd, wide.c_str());
            break;
    }
}

static void applyNativeViewAccessibility(NativeView &view) {
    if (!view.hwnd) return;
    std::wstring name = widen(nativeViewAccessibilityName(view));
    bool uninitialize = false;
    initializeCom(&uninitialize);
    IAccPropServices *services = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_AccPropServices, nullptr, CLSCTX_SERVER, IID_IAccPropServices, reinterpret_cast<void **>(&services));
    if (SUCCEEDED(hr) && services) {
        services->SetHwndPropStr(view.hwnd, OBJID_CLIENT, CHILDID_SELF, PROPID_ACC_NAME, name.c_str());
        services->Release();
    }
    finishCom(uninitialize);
}

static void applyNativeViewFrame(Host *host, NativeView &view) {
    if (!view.hwnd) return;
    const double scale = nativeViewFrameScale(host, view);
    RECT frame = nativeViewPhysicalFrame(host, view, scale);
    MoveWindow(view.hwnd, frame.left, frame.top, frame.right - frame.left, frame.bottom - frame.top, TRUE);
}

static void applyNativeViewState(NativeView &view, bool update_text, const std::string &text) {
    if (!view.hwnd) return;
    ShowWindow(view.hwnd, view.visible ? SW_SHOW : SW_HIDE);
    EnableWindow(view.hwnd, view.enabled ? TRUE : FALSE);
    if (update_text) applyNativeViewText(view, text);
    applyNativeViewAccessibility(view);
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
        const bool button_like = view.kind == kViewButton || view.kind == kViewIconButton || view.kind == kViewListItem || view.kind == kViewCheckbox || view.kind == kViewToggle;
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

/* ---------------------------------------------------------------- gpu surface
 *
 * A gpu_surface view is a plain Win32 child HWND driven by the CPU pixel
 * path: the runtime rasterizes canvas frames with the reference renderer
 * and hands RGBA8 buffers to native_sdk_windows_present_gpu_surface_pixels,
 * which swizzles them into a top-down 32bpp BGRA DIB and invalidates the
 * child; WM_PAINT blits with SetDIBitsToDevice (StretchDIBits while a
 * resize is in flight). Frame events are DEMAND-DRIVEN through one
 * scheduler per surface (the macOS host's design): runtime frame
 * requests and pixel presents each arm a single grid-anchored one-shot
 * WM_TIMER emission, so an armed animation loop sees one
 * gpu_surface_frame per frame interval and an idle surface sees none.
 * Until the first present lands, a placeholder 16 ms WM_TIMER pump arms
 * the same scheduler (the runtime's install choreography rides the
 * first frame events), then removes itself. WM_TIMER granularity
 * (~10-16 ms, coalesced under load) quantizes individual periods; the
 * grid-anchored clock turns that into jitter, never drift.
 * gpu_surface_resize rides WM_SIZE/DPI changes plus each emission's
 * geometry sync. Mouse, wheel, and
 * key input map onto the same gpu_surface_input kinds the other hosts
 * emit; printable text arrives through WM_CHAR as text_input events while
 * WM_KEYDOWN carries only the key name, so nothing inserts twice.
 *
 * IME composition flows through WM_IME_COMPOSITION: GCS_COMPSTR preedit
 * updates become ime_set_composition events carrying the full preedit
 * text and a UTF-8 byte cursor (from GCS_CURSORPOS), an emptied preedit
 * or WM_IME_ENDCOMPOSITION with preedit still pending becomes
 * ime_cancel_composition, and GCS_RESULTSTR maps exactly like AppKit's
 * insertText / GTK's im-commit: a result equal to the pending preedit is
 * ime_commit_composition (the runtime already holds the text), anything
 * else cancels the composition first and inserts as a plain text_input.
 * WM_IME_COMPOSITION is fully handled (never forwarded to DefWindowProc)
 * so the IME does not synthesize duplicate WM_CHARs for the result
 * string, and WM_IME_SETCONTEXT drops ISC_SHOWUICOMPOSITIONWINDOW so the
 * canvas draws the preedit inline instead of the IME's floating window.
 */

constexpr int kGpuInputPointerDown = 0;
constexpr int kGpuInputPointerUp = 1;
constexpr int kGpuInputPointerMove = 2;
constexpr int kGpuInputPointerDrag = 3;
constexpr int kGpuInputScroll = 4;
constexpr int kGpuInputKeyDown = 5;
constexpr int kGpuInputKeyUp = 6;
constexpr int kGpuInputTextInput = 7;
constexpr int kGpuInputImeSetComposition = 8;
constexpr int kGpuInputImeCommitComposition = 9;
constexpr int kGpuInputImeCancelComposition = 10;
constexpr int kGpuInputPointerCancel = 11;
constexpr uint64_t kGpuFrameIntervalNs = 16666667ull;
/* Pacing interval for logical frame completions while the top-level
 * window is MINIMIZED: a ~1 Hz heartbeat instead of the frame grid. A
 * minimized window's presents reach nothing (WM_PAINT never arrives for
 * an iconic window; the DIB blit is deferred to restore), so frame-grid
 * completions only make the engine rebuild its display list at 60 Hz
 * for pixels nobody can see — a minimized app playing audio would burn
 * a core forever. Stopping completions entirely would starve anything
 * riding the frame channel (on_frame interpolation, armed tweens) and
 * snap it on restore; the heartbeat keeps those models gently current
 * while event-driven truth (audio position, input) flows at its own
 * cadence. Minimize (IsIconic on the root window) is the one occlusion
 * signal Win32 reports reliably for this GDI-presenting host; a window
 * fully covered by other windows has no dependable signal without a
 * DXGI presentation path, so covered-but-not-minimized windows keep
 * full cadence deliberately rather than guess. */
constexpr uint64_t kGpuOccludedHeartbeatNs = 1000000000ull;
/* Placeholder pump timer (repeating, retired by the first present). */
constexpr UINT_PTR kGpuFrameTimerId = 1;
/* The one-shot scheduled-emission timer (the single frame-event gate). */
constexpr UINT_PTR kGpuEmitTimerId = 2;

static uint64_t gpuTimestampNs() {
    static LARGE_INTEGER frequency = {};
    if (frequency.QuadPart == 0) QueryPerformanceFrequency(&frequency);
    if (frequency.QuadPart <= 0) return (uint64_t)GetTickCount64() * 1000000ull;
    LARGE_INTEGER counter = {};
    QueryPerformanceCounter(&counter);
    const uint64_t seconds = (uint64_t)(counter.QuadPart / frequency.QuadPart);
    const uint64_t remainder = (uint64_t)(counter.QuadPart % frequency.QuadPart);
    return seconds * 1000000000ull + remainder * 1000000000ull / (uint64_t)frequency.QuadPart;
}

/* Device scale for a gpu_surface child: the shared per-window DPI
 * resolution (dpiForWindow) over the 96-dpi baseline. In a DPI-unaware
 * process the resolved DPI is 96, so logical size == client pixels,
 * matching how the rest of this host treats coordinates. */
static double gpuSurfaceScale(HWND hwnd) {
    return hwnd ? (double)dpiForWindow(hwnd) / 96.0 : 1.0;
}

static NativeView *gpuSurfaceViewForHwnd(Host *host, HWND hwnd) {
    if (!host || !hwnd) return nullptr;
    for (auto &entry : host->native_views) {
        if (entry.second.hwnd == hwnd && entry.second.kind == kViewGpuSurface) return &entry.second;
    }
    return nullptr;
}

/* ------------------------------------------------------------------------
 * Hidden-titlebar window chrome (the Win32 custom-frame pattern).
 *
 * `hidden_inset` / `hidden_inset_tall` windows keep WS_OVERLAPPEDWINDOW —
 * the full system frame, the DWM-drawn caption buttons, snap layouts —
 * and reclaim ONLY the caption band for the client through WM_NCCALCSIZE.
 * DwmExtendFrameIntoClientArea extends the DWM frame over the top band so
 * the system's min/max/close render there; the app's opaque pixels cover
 * everything in the band EXCEPT a hole punched over the button cluster
 * (GDI black = zero alpha in the redirection surface, where the extended
 * DWM frame shows through — the documented custom-frame compositing
 * contract). DwmDefWindowProc gets first claim on every message so the
 * buttons keep their hover/press visuals and Windows 11 offers snap
 * layouts from the maximize button; nothing here hand-draws chrome.
 * The DWM entry points resolve dynamically so hosts without dwmapi
 * (very old cores, bare Wine prefixes) degrade to a frameless-looking
 * band instead of failing to load. */

struct DwmApi {
    using ExtendFrameFn = HRESULT(WINAPI *)(HWND, const MARGINS *);
    using DefWindowProcFn = BOOL(WINAPI *)(HWND, UINT, WPARAM, LPARAM, LRESULT *);
    using SetWindowAttributeFn = HRESULT(WINAPI *)(HWND, DWORD, LPCVOID, DWORD);
    ExtendFrameFn extend_frame = nullptr;
    DefWindowProcFn def_window_proc = nullptr;
    SetWindowAttributeFn set_window_attribute = nullptr;
};

static const DwmApi &dwmApi() {
    static const DwmApi api = [] {
        DwmApi resolved;
        HMODULE dwm = LoadLibraryW(L"dwmapi.dll");
        if (dwm) {
            resolved.extend_frame = reinterpret_cast<DwmApi::ExtendFrameFn>(
                reinterpret_cast<void *>(GetProcAddress(dwm, "DwmExtendFrameIntoClientArea")));
            resolved.def_window_proc = reinterpret_cast<DwmApi::DefWindowProcFn>(
                reinterpret_cast<void *>(GetProcAddress(dwm, "DwmDefWindowProc")));
            resolved.set_window_attribute = reinterpret_cast<DwmApi::SetWindowAttributeFn>(
                reinterpret_cast<void *>(GetProcAddress(dwm, "DwmSetWindowAttribute")));
        }
        return resolved;
    }();
    return api;
}

/* Windows 11 window attributes, spelled numerically so older SDK headers
 * still compile; DwmSetWindowAttribute answers E_INVALIDARG (ignored) on
 * builds that predate them. */
constexpr DWORD kDwmwaUseImmersiveDarkMode = 20;
constexpr DWORD kDwmwaCaptionColor = 35;

static bool windowUsesHiddenTitlebar(const Window &window) {
    /* The hidden styles only (1, 2): they keep the system frame and the
     * DWM caption buttons and reclaim just the band. Chromeless (3) is
     * a different shape entirely — a caption-less popup with no DWM
     * caption machinery — and must stay out of every branch this
     * predicate gates. */
    return window.titlebar_style == 1 || window.titlebar_style == 2;
}

/* titlebar_style 3 = chromeless: NO OS chrome at all — no caption, no
 * caption buttons. The explicit opt-in for fully-skinned apps that draw
 * their own working window controls. */
static bool windowIsChromeless(const Window &window) {
    return window.titlebar_style == 3;
}

static Window *hiddenTitlebarWindowForHwnd(Host *host, HWND hwnd) {
    if (!host || !hwnd) return nullptr;
    for (auto &entry : host->windows) {
        if (entry.second.hwnd == hwnd && windowUsesHiddenTitlebar(entry.second)) return &entry.second;
    }
    return nullptr;
}

static Window *chromelessWindowForHwnd(Host *host, HWND hwnd) {
    if (!host || !hwnd) return nullptr;
    for (auto &entry : host->windows) {
        if (entry.second.hwnd == hwnd && windowIsChromeless(entry.second)) return &entry.second;
    }
    return nullptr;
}

static UINT systemDpi();

/* Per-window DPI, resolved dynamically to mirror the awareness chain
 * the embedded manifest declares. GetDpiForWindow (Windows 10 1607+,
 * per-monitor v2 — modern Wine prefixes export it too) is preferred;
 * where it is absent, shcore's GetDpiForMonitor reports the effective
 * DPI of the window's monitor (Windows 8.1+, matching per-monitor v1
 * awareness); where shcore is absent too, the system DPI (matching
 * system-DPI awareness; older Wine prefixes land here through
 * systemDpi's GetDeviceCaps branch). A DPI-unaware process reports 96
 * on every branch, so logical points == client pixels there. */
static UINT dpiForWindow(HWND hwnd) {
    using GetDpiForWindowFn = UINT(WINAPI *)(HWND);
    static GetDpiForWindowFn get_dpi = reinterpret_cast<GetDpiForWindowFn>(
        reinterpret_cast<void *>(GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetDpiForWindow")));
    if (get_dpi && hwnd) {
        const UINT dpi = get_dpi(hwnd);
        if (dpi > 0) return dpi;
    }
    using GetDpiForMonitorFn = HRESULT(WINAPI *)(HMONITOR, int, UINT *, UINT *);
    static GetDpiForMonitorFn get_monitor_dpi = []() -> GetDpiForMonitorFn {
        HMODULE shcore = LoadLibraryW(L"shcore.dll");
        if (!shcore) return nullptr;
        return reinterpret_cast<GetDpiForMonitorFn>(
            reinterpret_cast<void *>(GetProcAddress(shcore, "GetDpiForMonitor")));
    }();
    if (get_monitor_dpi && hwnd) {
        HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        UINT dpi_x = 0;
        UINT dpi_y = 0;
        /* 0 = MDT_EFFECTIVE_DPI, spelled numerically so headers that
         * predate shellscalingapi.h still compile. */
        if (monitor && get_monitor_dpi(monitor, 0, &dpi_x, &dpi_y) == S_OK && dpi_y > 0) return dpi_y;
    }
    return systemDpi();
}

/* Caption metrics MUST scale with the monitor the window sits on, or a
 * mixed-dpi setup mis-sizes the reclaimed band; GetSystemMetricsForDpi
 * is resolved dynamically (Windows 10 1607+) with the process-global
 * metric as fallback. */
static int systemMetricForDpi(int index, UINT dpi) {
    using GetSystemMetricsForDpiFn = int(WINAPI *)(int, UINT);
    static GetSystemMetricsForDpiFn get_metric = reinterpret_cast<GetSystemMetricsForDpiFn>(
        reinterpret_cast<void *>(GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetSystemMetricsForDpi")));
    if (get_metric) return get_metric(index, dpi);
    return GetSystemMetrics(index);
}

/* System DPI for sizing a window that does not exist yet (creation
 * scales the requested logical content size to physical pixels before
 * the first monitor is known; WM_DPICHANGED re-derives the frame when
 * the window lands elsewhere), and the tail of dpiForWindow's chain
 * where no per-monitor API is available. GetDpiForSystem is resolved
 * dynamically (Windows 10 1607+) with the desktop DC's LOGPIXELSY,
 * then 96, as fallbacks. A DPI-unaware process reports 96 on every
 * branch, keeping points == pixels exactly as before. */
static UINT systemDpi() {
    using GetDpiForSystemFn = UINT(WINAPI *)();
    static GetDpiForSystemFn get_dpi = reinterpret_cast<GetDpiForSystemFn>(
        reinterpret_cast<void *>(GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetDpiForSystem")));
    if (get_dpi) {
        const UINT dpi = get_dpi();
        if (dpi > 0) return dpi;
    }
    HDC dc = GetDC(nullptr);
    if (dc) {
        const int dpi = GetDeviceCaps(dc, LOGPIXELSY);
        ReleaseDC(nullptr, dc);
        if (dpi > 0) return (UINT)dpi;
    }
    return 96;
}

/* AdjustWindowRectEx pinned to an explicit DPI so the frame borders
 * match the monitor the window is being sized against; resolved
 * dynamically (Windows 10 1607+) with the classic system-metric call
 * as the fallback. */
static BOOL adjustWindowRectForDpi(RECT *rect, DWORD style, BOOL menu, DWORD ex_style, UINT dpi) {
    using AdjustWindowRectExForDpiFn = BOOL(WINAPI *)(LPRECT, DWORD, BOOL, DWORD, UINT);
    static AdjustWindowRectExForDpiFn adjust = reinterpret_cast<AdjustWindowRectExForDpiFn>(
        reinterpret_cast<void *>(GetProcAddress(GetModuleHandleW(L"user32.dll"), "AdjustWindowRectExForDpi")));
    if (adjust) return adjust(rect, style, menu, ex_style, dpi);
    return AdjustWindowRectEx(rect, style, menu, ex_style);
}

/* Thickness of the top resize frame (sizing border + padded border) at
 * the window's dpi: the WM_NCCALCSIZE maximize inset and the
 * WM_NCHITTEST top resize band are both exactly this tall. */
static int hiddenFrameTopThickness(HWND hwnd) {
    const UINT dpi = dpiForWindow(hwnd);
    return systemMetricForDpi(SM_CYSIZEFRAME, dpi) + systemMetricForDpi(SM_CXPADDEDBORDER, dpi);
}

/* Height of the standard caption band (frame + caption) at the window's
 * dpi — the DWM frame extension depth, and the chrome-channel top inset
 * fallback when the live button rects are unavailable. */
static int hiddenCaptionBandHeight(HWND hwnd) {
    const UINT dpi = dpiForWindow(hwnd);
    return systemMetricForDpi(SM_CYCAPTION, dpi) + hiddenFrameTopThickness(hwnd);
}

/* The DWM caption-button cluster (min/max/close union) in CLIENT
 * coordinates. WM_GETTITLEBARINFOEX is answered by DefWindowProc from
 * the same style + metrics the DWM lays the buttons out from, so the
 * rects track dpi, maximize (where the whole cluster shifts inward),
 * and RTL layouts without this host re-deriving any of it. rgrect
 * indices: 2 minimize, 3 maximize, 5 close (0 is the bar, 4 help). */
static bool captionButtonsClientRect(HWND hwnd, RECT *out) {
    if (!hwnd) return false;
    TITLEBARINFOEX info = {};
    info.cbSize = sizeof(info);
    SendMessageW(hwnd, WM_GETTITLEBARINFOEX, 0, reinterpret_cast<LPARAM>(&info));
    const int indices[3] = { 2, 3, 5 };
    RECT cluster = {};
    bool any = false;
    for (int index : indices) {
        const RECT &rect = info.rgrect[index];
        if (rect.right <= rect.left || rect.bottom <= rect.top) continue;
        if (!any) {
            cluster = rect;
        } else {
            cluster.left = cluster.left < rect.left ? cluster.left : rect.left;
            cluster.top = cluster.top < rect.top ? cluster.top : rect.top;
            cluster.right = cluster.right > rect.right ? cluster.right : rect.right;
            cluster.bottom = cluster.bottom > rect.bottom ? cluster.bottom : rect.bottom;
        }
        any = true;
    }
    if (!any) return false;
    POINT top_left = { cluster.left, cluster.top };
    POINT bottom_right = { cluster.right, cluster.bottom };
    ScreenToClient(hwnd, &top_left);
    ScreenToClient(hwnd, &bottom_right);
    out->left = top_left.x;
    out->top = top_left.y;
    out->right = bottom_right.x;
    out->bottom = bottom_right.y;
    return out->right > out->left && out->bottom > out->top;
}

/* Extend the DWM frame over the reclaimed caption band so the system
 * caption buttons composite there. Idempotent; re-applied on WM_ACTIVATE
 * because a composition restart (session reconnect) drops extensions. */
static void applyHiddenTitlebarFrame(Window &window) {
    if (!window.hwnd || !windowUsesHiddenTitlebar(window)) return;
    const DwmApi &dwm = dwmApi();
    if (!dwm.extend_frame) return;
    MARGINS margins = { 0, 0, hiddenCaptionBandHeight(window.hwnd), 0 };
    dwm.extend_frame(window.hwnd, &margins);
}

/* Outer (track) size for a desired CONTENT size under the hidden
 * styles' live NC shape: WM_NCCALCSIZE hands the entire top band to the
 * client, so the outer rect carries NO top chrome — just the side and
 * bottom borders, plus the menu bar when one is attached. Plain
 * AdjustWindowRectEx would count the caption band the custom calc gives
 * back, landing the client one band taller than requested. */
static SIZE hiddenOuterSizeForContent(DWORD style, DWORD ex_style, bool has_menu, double content_width, double content_height, UINT dpi) {
    RECT borders = { 0, 0, 0, 0 };
    adjustWindowRectForDpi(&borders, style & ~WS_CAPTION, FALSE, ex_style, dpi);
    SIZE outer = {};
    outer.cx = physicalContentExtent(content_width) + (borders.right - borders.left);
    outer.cy = physicalContentExtent(content_height) + borders.bottom + (has_menu ? systemMetricForDpi(SM_CYMENU, dpi) : 0);
    return outer;
}

/* The gpu-surface child's origin in its parent's client coordinates. */
static POINT childOriginInParentClient(HWND child, HWND parent) {
    RECT rect = {};
    GetWindowRect(child, &rect);
    POINT origin = { rect.left, rect.top };
    ScreenToClient(parent, &origin);
    return origin;
}

/* A view-local logical point against the view's drag mirror: inside any
 * exclusion -> not draggable (the widget keeps its press), else inside
 * any region -> draggable. */
static bool pointInHiddenDragRegion(const NativeView &view, double x, double y) {
    for (const DragRegionRect &rect : view.drag_regions) {
        if (!rect.exclusion) continue;
        if (x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height) return false;
    }
    for (const DragRegionRect &rect : view.drag_regions) {
        if (rect.exclusion) continue;
        if (x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height) return true;
    }
    return false;
}

/* A parent-client point against every canvas child's drag mirror. */
static bool windowDragRegionHit(Host *host, const Window &window, POINT client) {
    if (!host || !window.hwnd) return false;
    for (auto &entry : host->native_views) {
        const NativeView &view = entry.second;
        if (view.window_id != window.id || view.kind != kViewGpuSurface || !view.hwnd) continue;
        if (view.drag_regions.empty()) continue;
        const POINT origin = childOriginInParentClient(view.hwnd, window.hwnd);
        const double scale = gpuSurfaceScale(view.hwnd);
        if (scale <= 0) continue;
        const double local_x = (double)(client.x - origin.x) / scale;
        const double local_y = (double)(client.y - origin.y) / scale;
        if (pointInHiddenDragRegion(view, local_x, local_y)) return true;
    }
    return false;
}

/* Cut the caption-button cluster out of the presented canvas: fill it
 * with GDI black, whose ZERO alpha byte tells the DWM (whose frame
 * extends over the band) to composite its own caption material and the
 * real min/max/close buttons there instead of the app's pixels. This is
 * the one spot the app's surface yields to the OS; everywhere else in
 * the band the present path's alpha-255 pixels win, so the header
 * visually extends into the titlebar like the macOS hidden-inset shape. */
static void punchHiddenCaptionButtonHole(Host *host, const NativeView &view, HWND hwnd, HDC dc) {
    if (!host) return;
    auto found = host->windows.find(view.window_id);
    if (found == host->windows.end() || !found->second.hwnd || !windowUsesHiddenTitlebar(found->second)) return;
    RECT cluster = {};
    if (!captionButtonsClientRect(found->second.hwnd, &cluster)) return;
    const POINT origin = childOriginInParentClient(hwnd, found->second.hwnd);
    RECT local = { cluster.left - origin.x, cluster.top - origin.y, cluster.right - origin.x, cluster.bottom - origin.y };
    FillRect(dc, &local, reinterpret_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
}

/* Keep the DWM caption material behind the punched button hole matched
 * to the app's own header: sample the presented pixel just leading of
 * the cluster at its vertical middle and push it as the Windows 11
 * caption color (plus the immersive dark flag, which picks the button
 * glyph/hover palette). Older builds reject the attribute and keep the
 * system caption material — the buttons still draw and work. */
static void syncHiddenCaptionColor(Host *host, Window &window, const NativeView &view, const uint8_t *rgba8, size_t width, size_t height) {
    if (!windowUsesHiddenTitlebar(window) || !window.hwnd || !view.hwnd) return;
    const DwmApi &dwm = dwmApi();
    if (!dwm.set_window_attribute) return;
    RECT cluster = {};
    if (!captionButtonsClientRect(window.hwnd, &cluster)) return;
    const POINT origin = childOriginInParentClient(view.hwnd, window.hwnd);
    long sample_x = (long)(cluster.left - origin.x) - 8;
    long sample_y = (long)((cluster.top + cluster.bottom) / 2 - origin.y);
    if (sample_x < 0) sample_x = 0;
    if (sample_x >= (long)width) sample_x = (long)width - 1;
    if (sample_y < 0) sample_y = 0;
    if (sample_y >= (long)height) sample_y = (long)height - 1;
    const uint8_t *pixel = rgba8 + ((size_t)sample_y * width + (size_t)sample_x) * 4;
    const COLORREF color = RGB(pixel[0], pixel[1], pixel[2]);
    if (window.hidden_caption_color_set && window.hidden_caption_color == color) return;
    window.hidden_caption_color = color;
    window.hidden_caption_color_set = true;
    dwm.set_window_attribute(window.hwnd, kDwmwaCaptionColor, &color, sizeof(color));
    const BOOL dark = (299 * pixel[0] + 587 * pixel[1] + 114 * pixel[2]) / 1000 < 128 ? TRUE : FALSE;
    dwm.set_window_attribute(window.hwnd, kDwmwaUseImmersiveDarkMode, &dark, sizeof(dark));
}

static uint32_t gpuModifierFlags() {
    uint32_t flags = 0;
    if (keyDown(VK_CONTROL)) flags |= kShortcutModifierPrimary | kShortcutModifierControl;
    if (keyDown(VK_MENU)) flags |= kShortcutModifierOption;
    if (keyDown(VK_SHIFT)) flags |= kShortcutModifierShift;
    if (keyDown(VK_LWIN) || keyDown(VK_RWIN)) flags |= kShortcutModifierCommand;
    return flags;
}

static void emitGpuSurfaceEvent(Host *host, const NativeView &view, WindowsEvent &event) {
    if (!host || !host->callback) return;
    event.window_id = view.window_id;
    event.view_label = view.label.c_str();
    event.view_label_len = view.label.size();
    if (!event.key_text) event.key_text = "";
    if (!event.input_text) event.input_text = "";
    host->callback(host->callback_context, &event);
}

static void emitGpuSurfaceInput(Host *host, NativeView &view, int input_kind, double x, double y, int button, double delta_x, double delta_y, const char *key, const char *text, uint32_t modifiers) {
    WindowsEvent event = {};
    event.kind = kGpuSurfaceInput;
    event.x = x;
    event.y = y;
    event.timestamp_ns = gpuTimestampNs();
    event.input_kind = input_kind;
    event.button = button;
    event.delta_x = delta_x;
    event.delta_y = delta_y;
    event.key_text = key ? key : "";
    event.key_text_len = key ? strlen(key) : 0;
    event.input_text = text ? text : "";
    event.input_text_len = text ? strlen(text) : 0;
    event.shortcut_modifiers = modifiers;
    emitGpuSurfaceEvent(host, view, event);
}

/* Text/composition emit variant: no pointer payload, optional byte cursor
 * into the UTF-8 text (mirrors native_sdk_emit_gpu_surface_text_input in
 * the GTK host and emitTextInputEventWithKind in the AppKit host). */
static void emitGpuSurfaceTextInput(Host *host, NativeView &view, int input_kind, const std::string &text, bool has_composition_cursor, size_t composition_cursor) {
    WindowsEvent event = {};
    event.kind = kGpuSurfaceInput;
    event.timestamp_ns = gpuTimestampNs();
    event.input_kind = input_kind;
    event.key_text = "";
    event.key_text_len = 0;
    event.input_text = text.c_str();
    event.input_text_len = text.size();
    event.has_composition_cursor = has_composition_cursor ? 1 : 0;
    event.composition_cursor = has_composition_cursor ? composition_cursor : 0;
    emitGpuSurfaceEvent(host, view, event);
}

/* Fetch one composition string (GCS_COMPSTR / GCS_RESULTSTR) from the
 * input context. ImmGetCompositionStringW returns a byte count for the
 * sizing call and the data for the filling call; errors return empty. */
static std::wstring gpuImeCompositionString(HIMC imc, DWORD kind) {
    const LONG bytes = ImmGetCompositionStringW(imc, kind, nullptr, 0);
    if (bytes <= 0) return std::wstring();
    std::wstring value((size_t)bytes / sizeof(WCHAR), L'\0');
    if (value.empty()) return value;
    const LONG copied = ImmGetCompositionStringW(imc, kind, value.data(), (DWORD)bytes);
    if (copied <= 0) return std::wstring();
    value.resize((size_t)copied / sizeof(WCHAR));
    return value;
}

/* Clamp a GCS_CURSORPOS value (UTF-16 code units into the preedit) to a
 * character boundary and convert it into a UTF-8 byte offset, the cursor
 * unit the shared gpu_surface contract uses (the GTK host converts Pango's
 * char offsets the same way). A cursor landing on a low surrogate is
 * nudged past the pair so the substring below never splits a code point. */
static size_t gpuImeCursorBytes(const std::wstring &preedit, LONG cursor_units) {
    size_t units = cursor_units < 0 ? preedit.size() : (size_t)cursor_units;
    if (units > preedit.size()) units = preedit.size();
    if (units < preedit.size() && preedit[units] >= 0xDC00 && preedit[units] <= 0xDFFF) units += 1;
    return narrow(preedit.substr(0, units)).size();
}

/* How a GCS_RESULTSTR commit maps onto the shared composition events.
 * Mirrors AppKit insertText / GTK im-commit: committing exactly the
 * pending preedit is a commit of the composition the runtime already
 * buffers; committing different text (or with no composition at all)
 * inserts the result, cancelling any pending preedit first. */
enum GpuImeCommitAction {
    kGpuImeCommitComposition = 0,
    kGpuImeCancelThenInsert = 1,
    kGpuImeInsertOnly = 2,
};

static GpuImeCommitAction gpuImeCommitAction(const std::string &pending_preedit, const std::string &result) {
    if (pending_preedit.empty()) return kGpuImeInsertOnly;
    return pending_preedit == result ? kGpuImeCommitComposition : kGpuImeCancelThenInsert;
}

/* WM_IME_COMPOSITION. Handles GCS_RESULTSTR before GCS_COMPSTR: IMEs that
 * commit one segment and keep composing the next (e.g. Japanese phrase
 * conversion) pack both into a single message, and the commit belongs to
 * the old composition. */
static void gpuSurfaceImeComposition(Host *host, NativeView &view, HWND hwnd, LPARAM lparam) {
    HIMC imc = ImmGetContext(hwnd);
    if (!imc) return;

    if (lparam & GCS_RESULTSTR) {
        const std::string result = narrow(gpuImeCompositionString(imc, GCS_RESULTSTR));
        const std::string pending = view.gpu_ime_preedit;
        view.gpu_ime_preedit.clear();
        if (!result.empty()) {
            switch (gpuImeCommitAction(pending, result)) {
                case kGpuImeCommitComposition:
                    emitGpuSurfaceTextInput(host, view, kGpuInputImeCommitComposition, std::string(), false, 0);
                    break;
                case kGpuImeCancelThenInsert:
                    emitGpuSurfaceTextInput(host, view, kGpuInputImeCancelComposition, std::string(), false, 0);
                    emitGpuSurfaceTextInput(host, view, kGpuInputTextInput, result, false, 0);
                    break;
                case kGpuImeInsertOnly:
                    emitGpuSurfaceTextInput(host, view, kGpuInputTextInput, result, false, 0);
                    break;
            }
        } else if (!pending.empty()) {
            emitGpuSurfaceTextInput(host, view, kGpuInputImeCancelComposition, std::string(), false, 0);
        }
    }

    /* A cursor-only update (caret moved inside an unchanged preedit)
     * still re-reads GCS_COMPSTR — the string is current in the context —
     * and re-emits set_composition so the runtime tracks the caret. */
    const bool composition_update = (lparam & GCS_COMPSTR) != 0 || ((lparam & GCS_CURSORPOS) != 0 && !view.gpu_ime_preedit.empty());
    if (composition_update) {
        const std::wstring preedit_wide = gpuImeCompositionString(imc, GCS_COMPSTR);
        if (preedit_wide.empty()) {
            if (!view.gpu_ime_preedit.empty()) {
                view.gpu_ime_preedit.clear();
                emitGpuSurfaceTextInput(host, view, kGpuInputImeCancelComposition, std::string(), false, 0);
            }
        } else {
            LONG cursor_units = -1;
            if (lparam & GCS_CURSORPOS) cursor_units = ImmGetCompositionStringW(imc, GCS_CURSORPOS, nullptr, 0);
            const size_t cursor_bytes = gpuImeCursorBytes(preedit_wide, cursor_units);
            view.gpu_ime_preedit = narrow(preedit_wide);
            emitGpuSurfaceTextInput(host, view, kGpuInputImeSetComposition, view.gpu_ime_preedit, true, cursor_bytes);
        }
    }

    ImmReleaseContext(hwnd, imc);
}

/* Emit a gpu_surface_resize when the child's logical size or device scale
 * differ from the last emitted values. Returns true when an event was sent. */
static bool syncGpuSurfaceGeometry(Host *host, NativeView &view, double width, double height, double scale) {
    if (width == view.gpu_emitted_width && height == view.gpu_emitted_height && scale == view.gpu_emitted_scale) return false;
    view.gpu_emitted_width = width;
    view.gpu_emitted_height = height;
    view.gpu_emitted_scale = scale;
    WindowsEvent event = {};
    event.kind = kGpuSurfaceResize;
    event.x = view.x;
    event.y = view.y;
    event.width = width;
    event.height = height;
    event.scale = scale;
    event.timestamp_ns = gpuTimestampNs();
    emitGpuSurfaceEvent(host, view, event);
    return true;
}

static bool gpuSurfaceLogicalSize(const NativeView &view, HWND hwnd, double scale, double *out_width, double *out_height) {
    RECT rect = {};
    GetClientRect(hwnd, &rect);
    double width = scale > 0 ? (double)(rect.right - rect.left) / scale : 0;
    double height = scale > 0 ? (double)(rect.bottom - rect.top) / scale : 0;
    if (width <= 0 && view.width > 0) width = view.width;
    if (height <= 0 && view.height > 0) height = view.height;
    *out_width = width;
    *out_height = height;
    return width > 0 && height > 0;
}

/* Advance the pacing clock for an emission that was SCHEDULED at
 * lastEmit + interval (the macOS host's clock discipline, mirrored):
 * stamping fire time would fold WM_TIMER's delivery latency into every
 * period, so the paced loop would drift slow; stamping the scheduled
 * deadline keeps the average period exactly one frame interval (jitter
 * stays, drift doesn't). A fire more than one interval late advances to
 * the last GRID point at or before now — whole missed intervals are
 * skipped, never queued as a catch-up burst, and a re-base from fire
 * time (which would stretch every following period by the delivery
 * latency) never happens. */
static void gpuSurfaceAdvancePacingClock(NativeView &view) {
    const uint64_t now = gpuTimestampNs();
    if (view.gpu_last_emit_ns == 0) {
        view.gpu_last_emit_ns = now;
        return;
    }
    const uint64_t scheduled_ns = view.gpu_last_emit_ns + kGpuFrameIntervalNs;
    if (now < scheduled_ns) {
        /* Fired before the deadline (timer granularity); re-basing at
         * now keeps the next delay a full interval. */
        view.gpu_last_emit_ns = now;
    } else {
        view.gpu_last_emit_ns = scheduled_ns + ((now - scheduled_ns) / kGpuFrameIntervalNs) * kGpuFrameIntervalNs;
    }
}

/* Frame completions run on the minimized heartbeat when the surface has
 * presented at least once and its top-level window is iconic — the same
 * first-present exemption the macOS occluded pacing keeps, so surface
 * establishment (and the nonblank verdict automation reads) is never
 * throttled. */
static bool gpuSurfaceOccludedPacingActive(const NativeView &view) {
    if (!view.gpu_presented || !view.hwnd) return false;
    HWND root = GetAncestor(view.hwnd, GA_ROOT);
    return root != nullptr && IsIconic(root);
}

/* The single frame-event emission: view state (nonblank verdict, sample
 * color, buffer geometry) is the payload, so one event serves frame
 * requests and present completions alike. */
static void gpuSurfaceEmitFrame(Host *host, NativeView &view, HWND hwnd) {
    /* The input's responding frame is THIS one; the follow-up schedule
     * (an armed animation re-requesting) returns to the minimized
     * heartbeat unless another input lands. */
    view.gpu_prompt_frame_pending = false;
    const double scale = gpuSurfaceScale(hwnd);
    double width = 0;
    double height = 0;
    if (!gpuSurfaceLogicalSize(view, hwnd, scale, &width, &height)) return;
    (void)syncGpuSurfaceGeometry(host, view, width, height, scale);
    gpuSurfaceAdvancePacingClock(view);

    view.gpu_frame_index += 1;
    WindowsEvent event = {};
    event.kind = kGpuSurfaceFrame;
    event.width = width;
    event.height = height;
    event.scale = scale;
    event.frame_index = view.gpu_frame_index;
    event.timestamp_ns = gpuTimestampNs();
    event.frame_interval_ns = kGpuFrameIntervalNs;
    event.nonblank = view.gpu_nonblank;
    event.sample_color = view.gpu_sample_color;
    /* Heartbeat-paced completions are not latency endpoints: their
     * timestamp measures the deliberate minimized cadence, not a paint
     * — the runtime skips input-latency stamping for them. */
    event.occluded = gpuSurfaceOccludedPacingActive(view) ? 1 : 0;
    emitGpuSurfaceEvent(host, view, event);
}

/* Schedule the surface's next frame event on the frame-interval grid.
 * At most one emission is ever in flight; producers arriving while it
 * is queued fold into it. Always fires through the message loop — a
 * request lands mid engine dispatch and a synchronous emission would
 * re-enter the engine — and the pacing clock's grid stamping keeps the
 * message hop out of the period. SetTimer clamps short delays up to its
 * ~10 ms floor; the clock absorbs that as jitter, not drift. */
static void gpuSurfaceScheduleFrameEmission(NativeView &view) {
    if (!view.hwnd || view.gpu_emission_scheduled) return;
    const uint64_t now = gpuTimestampNs();
    /* Minimized surfaces pace on the heartbeat, not the frame grid —
     * see kGpuOccludedHeartbeatNs. Exempt: an input's responding frame
     * (external truth on its own cadence; it cannot sustain a spin).
     * Restore re-arms the pending timer at the grid delay (the
     * top-level WM_SIZE handler), so the long delay never gates the
     * return to full cadence. */
    const uint64_t pace_ns = (!view.gpu_prompt_frame_pending && gpuSurfaceOccludedPacingActive(view)) ? kGpuOccludedHeartbeatNs : kGpuFrameIntervalNs;
    uint64_t delay_ns = 0;
    if (view.gpu_last_emit_ns > 0 && now < view.gpu_last_emit_ns + pace_ns) {
        delay_ns = view.gpu_last_emit_ns + pace_ns - now;
    }
    const UINT delay_ms = (UINT)((delay_ns + 500000ull) / 1000000ull);
    if (SetTimer(view.hwnd, kGpuEmitTimerId, delay_ms, nullptr)) {
        view.gpu_emission_scheduled = true;
    }
}

static void paintGpuSurface(NativeView &view, HWND hwnd, HDC dc) {
    if (view.gpu_bgra.empty() || view.gpu_buf_width <= 0 || view.gpu_buf_height <= 0) return;
    RECT rect = {};
    GetClientRect(hwnd, &rect);
    const int client_width = rect.right - rect.left;
    const int client_height = rect.bottom - rect.top;
    if (client_width <= 0 || client_height <= 0) return;

    BITMAPINFO info = {};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = view.gpu_buf_width;
    /* Negative height marks the DIB as top-down, matching the renderer's
     * row order; BI_RGB 32bpp rows are B,G,R,X bytes (the present path
     * already swizzled from RGBA8). */
    info.bmiHeader.biHeight = -view.gpu_buf_height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;

    if (client_width == view.gpu_buf_width && client_height == view.gpu_buf_height) {
        SetDIBitsToDevice(dc, 0, 0, view.gpu_buf_width, view.gpu_buf_height, 0, 0, 0, view.gpu_buf_height, view.gpu_bgra.data(), &info, DIB_RGB_COLORS);
        return;
    }
    /* Mid-resize frames where the buffer is stale stretch until the next
     * presented frame replaces them. */
    SetStretchBltMode(dc, HALFTONE);
    SetBrushOrgEx(dc, 0, 0, nullptr);
    StretchDIBits(dc, 0, 0, client_width, client_height, 0, 0, view.gpu_buf_width, view.gpu_buf_height, view.gpu_bgra.data(), &info, DIB_RGB_COLORS, SRCCOPY);
}

/* Key names match shortcutKeyFromWParam (which mirrors the GTK/AppKit gpu
 * key set) plus the navigation keys the canvas text editor understands. */
static std::string gpuSurfaceKeyName(WPARAM wparam) {
    std::string key = shortcutKeyFromWParam(wparam);
    if (!key.empty()) return key;
    switch (wparam) {
        case VK_DELETE: return "delete";
        case VK_HOME: return "home";
        case VK_END: return "end";
        case VK_PRIOR: return "pageup";
        case VK_NEXT: return "pagedown";
        default: return std::string();
    }
}

static void gpuSurfaceCharInput(Host *host, NativeView &view, WPARAM wparam) {
    const WCHAR unit = (WCHAR)wparam;
    std::wstring wide;
    if (unit >= 0xD800 && unit <= 0xDBFF) {
        view.gpu_pending_high_surrogate = unit;
        return;
    }
    if (unit >= 0xDC00 && unit <= 0xDFFF) {
        if (!view.gpu_pending_high_surrogate) return;
        wide.push_back(view.gpu_pending_high_surrogate);
        view.gpu_pending_high_surrogate = 0;
        wide.push_back(unit);
    } else {
        view.gpu_pending_high_surrogate = 0;
        if (unit < 0x20 || unit == 0x7f) return;
        wide.push_back(unit);
    }
    /* Control/alt chords produce control characters or menu accelerators,
     * not text; mirror the GTK path, which skips text for modified keys. */
    if (keyDown(VK_CONTROL) || keyDown(VK_MENU) || keyDown(VK_LWIN) || keyDown(VK_RWIN)) return;
    const std::string text = narrow(wide);
    if (text.empty()) return;
    emitGpuSurfaceInput(host, view, kGpuInputTextInput, view.gpu_pointer_x, view.gpu_pointer_y, 0, 0, 0, "", text.c_str(), gpuModifierFlags());
}

static LRESULT CALLBACK gpuSurfaceProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    Host *host = reinterpret_cast<Host *>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    NativeView *view = gpuSurfaceViewForHwnd(host, hwnd);
    if (!view) return DefWindowProcW(hwnd, message, wparam, lparam);
    const double scale = gpuSurfaceScale(hwnd);
    switch (message) {
        case WM_TIMER:
            if (wparam == kGpuFrameTimerId) {
                /* Placeholder pump: arm the scheduler until the first
                 * present lands, then retire (SetTimer repeats until
                 * KillTimer). */
                if (view->gpu_presented) {
                    KillTimer(hwnd, kGpuFrameTimerId);
                    return 0;
                }
                gpuSurfaceScheduleFrameEmission(*view);
                return 0;
            }
            if (wparam == kGpuEmitTimerId) {
                /* The one scheduled emission fires: one-shot semantics
                 * (KillTimer before the emit — SetTimer timers repeat),
                 * and the scheduled flag clears BEFORE emitting so the
                 * emission's engine dispatch can re-arm the scheduler. */
                KillTimer(hwnd, kGpuEmitTimerId);
                view->gpu_emission_scheduled = false;
                gpuSurfaceEmitFrame(host, *view, hwnd);
                return 0;
            }
            break;
        case WM_PAINT: {
            PAINTSTRUCT paint = {};
            HDC dc = BeginPaint(hwnd, &paint);
            if (dc) {
                paintGpuSurface(*view, hwnd, dc);
                /* Hidden-titlebar parents: yield the caption-button
                 * cluster back to the DWM (see the helper's comment). */
                punchHiddenCaptionButtonHole(host, *view, hwnd, dc);
            }
            EndPaint(hwnd, &paint);
            return 0;
        }
        case WM_ERASEBKGND:
            return 1;
        case WM_NCHITTEST: {
            /* This child covers the parent's whole client area, so the
             * parent's WM_NCHITTEST — where the hidden-titlebar caption
             * behavior lives — is only ever consulted where this child
             * answers HTTRANSPARENT. Hand back exactly the zones that
             * belong to the window, not the canvas: the top resize band
             * (the custom WM_NCCALCSIZE moved the top frame INSIDE the
             * client), the DWM caption-button cluster, and the markup's
             * window-drag regions minus their press-claiming exclusions.
             * Everything else stays HTCLIENT and flows into the canvas
             * input pipeline unchanged. */
            Window *chrome_window = nullptr;
            if (host) {
                auto found = host->windows.find(view->window_id);
                if (found != host->windows.end() && found->second.hwnd && windowUsesHiddenTitlebar(found->second)) chrome_window = &found->second;
            }
            if (!chrome_window) break;
            POINT point = { (int)(short)LOWORD(lparam), (int)(short)HIWORD(lparam) };
            ScreenToClient(chrome_window->hwnd, &point);
            if (chrome_window->resizable && !IsZoomed(chrome_window->hwnd) && point.y >= 0 && point.y < hiddenFrameTopThickness(chrome_window->hwnd)) return HTTRANSPARENT;
            RECT cluster = {};
            if (captionButtonsClientRect(chrome_window->hwnd, &cluster) && PtInRect(&cluster, point)) return HTTRANSPARENT;
            if (windowDragRegionHit(host, *chrome_window, point)) return HTTRANSPARENT;
            break;
        }
        case WM_SIZE: {
            double width = 0;
            double height = 0;
            if (gpuSurfaceLogicalSize(*view, hwnd, scale, &width, &height)) {
                (void)syncGpuSurfaceGeometry(host, *view, width, height, scale);
            }
            return 0;
        }
        case WM_LBUTTONDOWN:
        case WM_RBUTTONDOWN:
        case WM_MBUTTONDOWN: {
            SetFocus(hwnd);
            SetCapture(hwnd);
            const double x = (double)(short)LOWORD(lparam) / scale;
            const double y = (double)(short)HIWORD(lparam) / scale;
            view->gpu_pointer_down = 1;
            view->gpu_pointer_x = x;
            view->gpu_pointer_y = y;
            const int button = message == WM_LBUTTONDOWN ? 0 : message == WM_RBUTTONDOWN ? 1 : 2;
            emitGpuSurfaceInput(host, *view, kGpuInputPointerDown, x, y, button, 0, 0, "", "", gpuModifierFlags());
            return 0;
        }
        case WM_LBUTTONUP:
        case WM_RBUTTONUP:
        case WM_MBUTTONUP: {
            const double x = (double)(short)LOWORD(lparam) / scale;
            const double y = (double)(short)HIWORD(lparam) / scale;
            view->gpu_pointer_down = 0;
            view->gpu_pointer_x = x;
            view->gpu_pointer_y = y;
            const int button = message == WM_LBUTTONUP ? 0 : message == WM_RBUTTONUP ? 1 : 2;
            emitGpuSurfaceInput(host, *view, kGpuInputPointerUp, x, y, button, 0, 0, "", "", gpuModifierFlags());
            if (GetCapture() == hwnd) ReleaseCapture();
            return 0;
        }
        case WM_MOUSEMOVE: {
            const double x = (double)(short)LOWORD(lparam) / scale;
            const double y = (double)(short)HIWORD(lparam) / scale;
            view->gpu_pointer_x = x;
            view->gpu_pointer_y = y;
            const int kind = view->gpu_pointer_down ? kGpuInputPointerDrag : kGpuInputPointerMove;
            emitGpuSurfaceInput(host, *view, kind, x, y, 0, 0, 0, "", "", gpuModifierFlags());
            return 0;
        }
        case WM_CAPTURECHANGED:
            if (view->gpu_pointer_down) {
                view->gpu_pointer_down = 0;
                emitGpuSurfaceInput(host, *view, kGpuInputPointerCancel, view->gpu_pointer_x, view->gpu_pointer_y, 0, 0, 0, "", "", gpuModifierFlags());
            }
            break;
        case WM_MOUSEWHEEL:
        case WM_MOUSEHWHEEL: {
            POINT point = { (int)(short)LOWORD(lparam), (int)(short)HIWORD(lparam) };
            ScreenToClient(hwnd, &point);
            const double x = (double)point.x / scale;
            const double y = (double)point.y / scale;
            view->gpu_pointer_x = x;
            view->gpu_pointer_y = y;
            /* One wheel notch scrolls 40 logical units, the cadence the GTK
             * host uses; forward wheel rotation (positive Win32 delta) means
             * scroll up, which the shared input semantics express as a
             * negative delta_y. */
            const double delta = (double)(short)HIWORD(wparam) / (double)WHEEL_DELTA * 40.0;
            const double delta_x = message == WM_MOUSEHWHEEL ? delta : 0;
            const double delta_y = message == WM_MOUSEWHEEL ? -delta : 0;
            emitGpuSurfaceInput(host, *view, kGpuInputScroll, x, y, 0, delta_x, delta_y, "", "", gpuModifierFlags());
            return 0;
        }
        case WM_KEYDOWN:
        case WM_SYSKEYDOWN: {
            if (emitShortcutForHwnd(host, GetAncestor(hwnd, GA_ROOT), wparam)) return 0;
            const std::string key = gpuSurfaceKeyName(wparam);
            if (!key.empty()) {
                emitGpuSurfaceInput(host, *view, kGpuInputKeyDown, view->gpu_pointer_x, view->gpu_pointer_y, 0, 0, 0, key.c_str(), "", gpuModifierFlags());
            }
            break;
        }
        case WM_KEYUP:
        case WM_SYSKEYUP: {
            const std::string key = gpuSurfaceKeyName(wparam);
            if (!key.empty()) {
                emitGpuSurfaceInput(host, *view, kGpuInputKeyUp, view->gpu_pointer_x, view->gpu_pointer_y, 0, 0, 0, key.c_str(), "", gpuModifierFlags());
            }
            break;
        }
        case WM_CHAR:
            gpuSurfaceCharInput(host, *view, wparam);
            return 0;
        case WM_IME_SETCONTEXT:
            /* Keep the IME's candidate list but suppress its floating
             * composition window: the canvas renders the preedit inline
             * from ime_set_composition events, like the other hosts. */
            return DefWindowProcW(hwnd, message, wparam, lparam & ~(LPARAM)ISC_SHOWUICOMPOSITIONWINDOW);
        case WM_IME_STARTCOMPOSITION:
            /* No event: the shared contract has no explicit start —
             * the first ime_set_composition opens the composition.
             * Returning without DefWindowProc keeps the IME's default
             * composition window from being created. */
            return 0;
        case WM_IME_COMPOSITION:
            gpuSurfaceImeComposition(host, *view, hwnd, lparam);
            /* Fully handled: DefWindowProc would have the IME synthesize
             * WM_CHARs for GCS_RESULTSTR, double-inserting the commit. */
            return 0;
        case WM_IME_CHAR:
            /* Commits already travel through the GCS_RESULTSTR path;
             * letting DefWindowProc translate WM_IME_CHAR into WM_CHAR
             * would insert them twice. */
            return 0;
        case WM_IME_ENDCOMPOSITION:
            /* A composition that ends while preedit is still pending was
             * cancelled (focus loss, Escape); a committed one already
             * cleared the preedit in the GCS_RESULTSTR path. */
            if (!view->gpu_ime_preedit.empty()) {
                view->gpu_ime_preedit.clear();
                emitGpuSurfaceTextInput(host, *view, kGpuInputImeCancelComposition, std::string(), false, 0);
            }
            return 0;
        case WM_KILLFOCUS:
            /* Mirror AppKit (unmarkText on resign) and GTK (focus-out
             * resets the IM context): composition cannot outlive focus. */
            if (!view->gpu_ime_preedit.empty()) {
                view->gpu_ime_preedit.clear();
                emitGpuSurfaceTextInput(host, *view, kGpuInputImeCancelComposition, std::string(), false, 0);
            }
            break;
        case WM_GETDLGCODE:
            return DLGC_WANTALLKEYS | DLGC_WANTCHARS | DLGC_WANTARROWS;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

static const wchar_t *gpuSurfaceClassName(Host *host) {
    static bool registered = false;
    if (!registered) {
        WNDCLASSEXW wc = {};
        wc.cbSize = sizeof(wc);
        wc.style = CS_HREDRAW | CS_VREDRAW;
        wc.lpfnWndProc = gpuSurfaceProc;
        wc.hInstance = host->instance;
        wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
        wc.lpszClassName = L"NativeSdkGpuSurface";
        registered = RegisterClassExW(&wc) != 0;
    }
    return L"NativeSdkGpuSurface";
}

/* ---------------------------------------------------------------- audio
 *
 * Backend: the Media Foundation MEDIA SESSION — IMFMediaSession driving
 * a source-resolver media source into the Streaming Audio Renderer.
 * The choice, weighed against the alternatives that ship with Windows
 * 10/11: MFPlay (IMFPMediaPlayer) is deprecated and off the table;
 * Source Reader + WASAPI means hand-rolling decode, resampling, device
 * buffering, and a presentation clock — hundreds of lines to rebuild
 * what the session already is; the session gives local MP3 decode, HTTP(S)
 * progressive streaming (audible before the download finishes, with
 * honest MEBufferingStarted/Stopped signals), pause/resume, sample-
 * accurate seek, per-stream volume, duration, and natural-end events in
 * one in-box object graph (mf.dll + mfplat.dll, no external
 * dependencies).
 *
 * Contract mirror of the macOS host: one player for the whole app; URL
 * sources resolve verified-cache-first, then stream while a PARALLEL
 * WinHTTP download fills the cache (part file beside the final name,
 * size-verified against the manifest, atomic same-directory rename —
 * a partial file never occupies the cache name, even across a crash);
 * LOADED is asynchronous (topology ready), position ticks ride a 500 ms
 * timer armed only while playing, completion and failure are single
 * terminal reports. Media Foundation callbacks land on its worker
 * threads; everything they learn crosses to the message loop as a
 * distilled kAudioSessionMessage PostMessage, the same marshalling the
 * wake path uses, so all host state stays loop-thread-owned. */

constexpr int kAudioEventLoaded = 0;
constexpr int kAudioEventPosition = 1;
constexpr int kAudioEventCompleted = 2;
constexpr int kAudioEventFailed = 3;
constexpr int kAudioEventSpectrum = 4;

/* Distilled session notes (kAudioSessionMessage wparam); lparam carries
 * the generation the note belongs to. */
constexpr WPARAM kAudioNoteSourceResolved = 1;
constexpr WPARAM kAudioNoteSourceFailed = 2;
constexpr WPARAM kAudioNoteTopologyReady = 3;
constexpr WPARAM kAudioNoteStarted = 4;
constexpr WPARAM kAudioNoteEnded = 5;
constexpr WPARAM kAudioNoteBufferingStarted = 6;
constexpr WPARAM kAudioNoteBufferingStopped = 7;
constexpr WPARAM kAudioNoteError = 8;

/* Position tick on the first top-level window, outside the app-timer id
 * range; 500 ms is the shared coarse cadence (macOS and the null
 * platform tick the same), so frame-clock scrubber interpolation
 * behaves identically across hosts. */
constexpr UINT_PTR kAudioPositionTimerId = 0x3000;
constexpr UINT kAudioPositionIntervalMs = 500;

/* Spectrum emission cadence: ~25 Hz is the shared coarse analysis
 * cadence every host that can reach the player's PCM emits at, fast
 * enough for honest bar motion and far below any rate that would
 * matter to the event channel. The capture thread paces itself to this
 * interval and posts kAudioSpectrumMessage each beat. */
constexpr UINT kAudioSpectrumIntervalMs = 40;

/* IMFMediaSession::Start's time-format argument: GUID_NULL means
 * 100-nanosecond units. Defined locally like the WIC GUIDs. */
static const GUID kNativeSdkAudioTimeFormat = { 0, 0, 0, { 0, 0, 0, 0, 0, 0, 0, 0 } };

/* One-time Media Foundation bring-up on the loop thread. COM and MF stay
 * up for the process lifetime: retired sessions finish closing on Media
 * Foundation worker threads, so pairing MFShutdown with host destroy
 * would race their teardown; the OS reclaims both at process exit. */
static bool audioEnsureMediaFoundation() {
    static bool attempted = false;
    static bool ready = false;
    if (attempted) return ready;
    attempted = true;
    /* S_FALSE (already initialized) and RPC_E_CHANGED_MODE (an MTA is
     * already active) both leave a usable COM state for MF. */
    (void)CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    ready = SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_FULL));
    return ready;
}

/* Pumps one media session's event queue on Media Foundation worker
 * threads and posts distilled notes to the message loop. Owns its own
 * reference plus one on the session and source; MESessionClosed (the
 * handshake audioReleaseSession starts with Close) shuts the pipeline
 * down right here — Shutdown is thread-safe — and retires the pump.
 * Stale generations are filtered on the loop side, so a retired
 * session's stragglers are inert. */
struct AudioSessionEventForwarder final : public IMFAsyncCallback {
    LONG refs = 1;
    IMFMediaSession *session = nullptr;
    IMFMediaSource *source = nullptr;
    HWND hwnd = nullptr;
    uint64_t generation = 0;

    AudioSessionEventForwarder(IMFMediaSession *session_in, IMFMediaSource *source_in, HWND hwnd_in, uint64_t generation_in)
        : session(session_in), source(source_in), hwnd(hwnd_in), generation(generation_in) {
        session->AddRef();
        source->AddRef();
    }
    ~AudioSessionEventForwarder() {
        session->Release();
        source->Release();
    }
    AudioSessionEventForwarder(const AudioSessionEventForwarder &) = delete;
    AudioSessionEventForwarder &operator=(const AudioSessionEventForwarder &) = delete;

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        if (!out) return E_POINTER;
        if (riid == IID_IUnknown || riid == IID_IMFAsyncCallback) {
            *out = static_cast<IMFAsyncCallback *>(this);
            AddRef();
            return S_OK;
        }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return (ULONG)InterlockedIncrement(&refs); }
    ULONG STDMETHODCALLTYPE Release() override {
        LONG value = InterlockedDecrement(&refs);
        if (value == 0) delete this;
        return (ULONG)value;
    }
    HRESULT STDMETHODCALLTYPE GetParameters(DWORD *, DWORD *) override { return E_NOTIMPL; }

    HRESULT STDMETHODCALLTYPE Invoke(IMFAsyncResult *result) override {
        IMFMediaEvent *event = nullptr;
        if (FAILED(session->EndGetEvent(result, &event)) || !event) {
            retire();
            return S_OK;
        }
        MediaEventType type = MEUnknown;
        event->GetType(&type);
        HRESULT status = S_OK;
        event->GetStatus(&status);
        if (type == MESessionClosed) {
            event->Release();
            retire();
            return S_OK;
        }
        WPARAM note = 0;
        if (FAILED(status) || type == MEError) {
            note = kAudioNoteError;
        } else if (type == MESessionTopologyStatus) {
            UINT32 topology_status = 0;
            if (SUCCEEDED(event->GetUINT32(MF_EVENT_TOPOLOGY_STATUS, &topology_status)) && topology_status == MF_TOPOSTATUS_READY) {
                note = kAudioNoteTopologyReady;
            }
        } else if (type == MESessionStarted) {
            note = kAudioNoteStarted;
        } else if (type == MESessionEnded) {
            note = kAudioNoteEnded;
        } else if (type == MEBufferingStarted) {
            note = kAudioNoteBufferingStarted;
        } else if (type == MEBufferingStopped) {
            note = kAudioNoteBufferingStopped;
        }
        event->Release();
        /* A destroyed window makes this a harmless no-op. */
        if (note != 0) PostMessageW(hwnd, kAudioSessionMessage, note, (LPARAM)generation);
        if (FAILED(session->BeginGetEvent(this, nullptr))) retire();
        return S_OK;
    }

    void retire() {
        source->Shutdown();
        session->Shutdown();
        Release();
    }
};

/* Completes an asynchronous URL source resolution (worker thread) and
 * hands the media source to the loop thread under the host lifetime
 * mutex; a stale generation — the playback was replaced or stopped
 * mid-resolve — shuts the source down right here instead. */
struct AudioSourceResolveForwarder final : public IMFAsyncCallback {
    LONG refs = 1;
    IMFSourceResolver *resolver = nullptr;
    Host *host = nullptr;
    std::shared_ptr<HostLifetime> lifetime;
    HWND hwnd = nullptr;
    uint64_t generation = 0;

    AudioSourceResolveForwarder(IMFSourceResolver *resolver_in, Host *host_in, std::shared_ptr<HostLifetime> lifetime_in, HWND hwnd_in, uint64_t generation_in)
        : resolver(resolver_in), host(host_in), lifetime(std::move(lifetime_in)), hwnd(hwnd_in), generation(generation_in) {
        resolver->AddRef();
    }
    ~AudioSourceResolveForwarder() { resolver->Release(); }
    AudioSourceResolveForwarder(const AudioSourceResolveForwarder &) = delete;
    AudioSourceResolveForwarder &operator=(const AudioSourceResolveForwarder &) = delete;

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        if (!out) return E_POINTER;
        if (riid == IID_IUnknown || riid == IID_IMFAsyncCallback) {
            *out = static_cast<IMFAsyncCallback *>(this);
            AddRef();
            return S_OK;
        }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return (ULONG)InterlockedIncrement(&refs); }
    ULONG STDMETHODCALLTYPE Release() override {
        LONG value = InterlockedDecrement(&refs);
        if (value == 0) delete this;
        return (ULONG)value;
    }
    HRESULT STDMETHODCALLTYPE GetParameters(DWORD *, DWORD *) override { return E_NOTIMPL; }

    HRESULT STDMETHODCALLTYPE Invoke(IMFAsyncResult *result) override {
        MF_OBJECT_TYPE type = MF_OBJECT_INVALID;
        IUnknown *object = nullptr;
        HRESULT hr = resolver->EndCreateObjectFromURL(result, &type, &object);
        IMFMediaSource *source = nullptr;
        if (SUCCEEDED(hr) && object) object->QueryInterface(IID_IMFMediaSource, reinterpret_cast<void **>(&source));
        if (object) object->Release();
        std::lock_guard<std::recursive_mutex> guard(lifetime->mutex);
        const bool current = lifetime->alive && host->audio.active && host->audio.generation == generation;
        if (!current) {
            if (source) {
                source->Shutdown();
                source->Release();
            }
            return S_OK;
        }
        if (!source) {
            PostMessageW(hwnd, kAudioSessionMessage, kAudioNoteSourceFailed, (LPARAM)generation);
            return S_OK;
        }
        /* Reference transferred; the loop thread attaches or (if it
         * bumps the generation first) releases it in teardown. */
        host->audio.source = source;
        PostMessageW(hwnd, kAudioSessionMessage, kAudioNoteSourceResolved, (LPARAM)generation);
        return S_OK;
    }
};

static uint64_t audioFileSize(const std::wstring &path, bool *exists) {
    *exists = false;
    WIN32_FILE_ATTRIBUTE_DATA data = {};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &data)) return 0;
    if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) return 0;
    *exists = true;
    return ((uint64_t)data.nFileSizeHigh << 32) | (uint64_t)data.nFileSizeLow;
}

static void audioCreateParentDirectories(const std::wstring &path) {
    size_t slash = path.find_last_of(L"/\\");
    if (slash == std::wstring::npos || slash == 0) return;
    std::wstring directory = path.substr(0, slash);
    for (wchar_t &ch : directory) {
        if (ch == L'/') ch = L'\\';
    }
    SHCreateDirectoryExW(nullptr, directory.c_str(), nullptr);
}

/* One GET into the part file, cancellable between reads. Only a 200
 * installs bytes — an error page must never masquerade as a track. */
static bool audioHttpDownload(const std::string &url, const std::wstring &part_path, const std::shared_ptr<AudioDownloadCancel> &cancel) {
    std::wstring url_wide = widen(url);
    wchar_t host_name[256] = {};
    wchar_t url_path[2048] = {};
    wchar_t url_extra[1024] = {};
    URL_COMPONENTS parts = {};
    parts.dwStructSize = sizeof(parts);
    parts.lpszHostName = host_name;
    parts.dwHostNameLength = ARRAYSIZE(host_name) - 1;
    parts.lpszUrlPath = url_path;
    parts.dwUrlPathLength = ARRAYSIZE(url_path) - 1;
    parts.lpszExtraInfo = url_extra;
    parts.dwExtraInfoLength = ARRAYSIZE(url_extra) - 1;
    if (!WinHttpCrackUrl(url_wide.c_str(), (DWORD)url_wide.size(), 0, &parts)) return false;
    const bool secure = parts.nScheme == INTERNET_SCHEME_HTTPS;
    if (!secure && parts.nScheme != INTERNET_SCHEME_HTTP) return false;
    std::wstring object = std::wstring(url_path) + url_extra;
    if (object.empty()) object = L"/";

    bool ok = false;
    HINTERNET session = WinHttpOpen(L"native-sdk-audio-cache", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    HINTERNET connection = session ? WinHttpConnect(session, host_name, parts.nPort, 0) : nullptr;
    HINTERNET request = connection ? WinHttpOpenRequest(connection, L"GET", object.c_str(), nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, secure ? WINHTTP_FLAG_SECURE : 0) : nullptr;
    HANDLE file = INVALID_HANDLE_VALUE;
    do {
        if (!request) break;
        if (!WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0)) break;
        if (!WinHttpReceiveResponse(request, nullptr)) break;
        DWORD status_code = 0;
        DWORD status_size = sizeof(status_code);
        if (!WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &status_code, &status_size, WINHTTP_NO_HEADER_INDEX)) break;
        if (status_code != 200) break;
        file = CreateFileW(part_path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) break;
        std::vector<uint8_t> buffer(64 * 1024);
        for (;;) {
            if (cancel->cancelled.load()) break;
            DWORD read = 0;
            if (!WinHttpReadData(request, buffer.data(), (DWORD)buffer.size(), &read)) break;
            if (read == 0) {
                ok = true;
                break;
            }
            DWORD written = 0;
            if (!WriteFile(file, buffer.data(), read, &written, nullptr) || written != read) break;
        }
    } while (false);
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    if (request) WinHttpCloseHandle(request);
    if (connection) WinHttpCloseHandle(connection);
    if (session) WinHttpCloseHandle(session);
    return ok && !cancel->cancelled.load();
}

/* The cache fill is a PARALLEL download, not a tee off the session's own
 * network source: a partially buffered stream must never masquerade as a
 * cache entry. One extra request on a track's first (uncached) play buys
 * a stock streaming path and a cache whose entries are whole files by
 * construction: downloaded beside the final name, size-verified against
 * the manifest, and renamed into place — a same-directory rename, so a
 * partial file never occupies the cache name even across a crash.
 * Detached thread, file and network work only, never host state; a
 * failed or cancelled download simply leaves no cache entry (the next
 * play streams again). */
static void audioCacheDownloadThread(std::string url, std::wstring cache_path, uint64_t expected_bytes, std::shared_ptr<AudioDownloadCancel> cancel) {
    audioCreateParentDirectories(cache_path);
    std::wstring part_path = cache_path + L".part";
    DeleteFileW(part_path.c_str());
    if (!audioHttpDownload(url, part_path, cancel)) {
        DeleteFileW(part_path.c_str());
        return;
    }
    bool exists = false;
    const uint64_t size = audioFileSize(part_path, &exists);
    if (!exists || (expected_bytes != 0 && size != expected_bytes)) {
        /* Truncated or wrong content: never installed. */
        DeleteFileW(part_path.c_str());
        return;
    }
    DeleteFileW(cache_path.c_str());
    if (!MoveFileExW(part_path.c_str(), cache_path.c_str(), MOVEFILE_REPLACE_EXISTING)) {
        DeleteFileW(part_path.c_str());
    }
}

/* Live position off the session's presentation clock (fetched lazily —
 * the clock exists once a topology is set). 100 ns units to ms. */
static uint64_t audioPositionMs(AudioState &audio) {
    if (!audio.session) return 0;
    if (!audio.clock) {
        IMFClock *clock = nullptr;
        if (SUCCEEDED(audio.session->GetClock(&clock)) && clock) {
            clock->QueryInterface(IID_IMFPresentationClock, reinterpret_cast<void **>(&audio.clock));
            clock->Release();
        }
    }
    if (!audio.clock) return 0;
    MFTIME time = 0;
    if (FAILED(audio.clock->GetTime(&time)) || time < 0) return 0;
    return (uint64_t)time / 10000ull;
}

static void audioEmitReport(Host *host, int kind, uint64_t position_ms, uint64_t duration_ms, int playing, int buffering) {
    if (!host || !host->callback) return;
    WindowsEvent event = {};
    event.kind = kAudio;
    event.audio_kind = kind;
    event.audio_position_ms = position_ms;
    event.audio_duration_ms = duration_ms;
    event.audio_playing = playing;
    event.audio_buffering = buffering;
    event.timestamp_ns = gpuTimestampNs();
    host->callback(host->callback_context, &event);
}

static void audioEmitEvent(Host *host, int kind) {
    AudioState &audio = host->audio;
    audioEmitReport(host, kind, audioPositionMs(audio), audio.duration_ms, audio.playing ? 1 : 0, audio.buffering ? 1 : 0);
}

/* SPECTRUM report: the band snapshot plus the same live transport
 * readout a position tick carries, so a consumer can bind bars and
 * scrubber off one event. */
static void audioEmitSpectrum(Host *host, const uint8_t bands[kAudioSpectrumBandCount]) {
    if (!host || !host->callback) return;
    AudioState &audio = host->audio;
    WindowsEvent event = {};
    event.kind = kAudio;
    event.audio_kind = kAudioEventSpectrum;
    event.audio_position_ms = audioPositionMs(audio);
    event.audio_duration_ms = audio.duration_ms;
    event.audio_playing = audio.playing ? 1 : 0;
    event.audio_buffering = audio.buffering ? 1 : 0;
    event.timestamp_ns = gpuTimestampNs();
    memcpy(event.audio_bands, bands, kAudioSpectrumBandCount);
    host->callback(host->callback_context, &event);
}

static void audioStopPositionTimer(Host *host) {
    AudioState &audio = host->audio;
    if (audio.position_timer_armed && audio.timer_hwnd) KillTimer(audio.timer_hwnd, kAudioPositionTimerId);
    audio.position_timer_armed = false;
    audio.timer_hwnd = nullptr;
}

static void audioStartPositionTimer(Host *host) {
    AudioState &audio = host->audio;
    if (audio.position_timer_armed) return;
    HWND hwnd = parentWindow(host);
    if (!hwnd) return;
    if (SetTimer(hwnd, kAudioPositionTimerId, kAudioPositionIntervalMs, nullptr)) {
        audio.timer_hwnd = hwnd;
        audio.position_timer_armed = true;
    }
}

/* ------------------------------------------------------ audio spectrum
 *
 * Real band magnitudes of the audio THIS APP is producing, captured
 * through WASAPI process-scoped loopback (ActivateAudioInterfaceAsync on
 * the VAD\Process_Loopback virtual device, include-target-process-tree,
 * Windows 10 2004+). Process scope is the honesty line: a system-wide
 * loopback would fold other applications' audio into the bands, and the
 * event contract promises the app's own playback only.
 *
 * The pipeline: a detached capture thread (MTA — the activation
 * completion must not depend on a pumping STA) drains the capture
 * client, downmixes to mono, and runs a hand-rolled 2048-point radix-2
 * FFT under a Hann window — in-box on purpose, no DSP dependency enters
 * the toolkit for a bar display. Bin magnitudes fold into 32 log-spaced
 * buckets covering 50 Hz..16 kHz (peak bin per bucket), convert to dBFS
 * against 1.0 full-scale float PCM, clamp to [-60, 0], and map linearly
 * to 0..255 — the shared scale every host emits. Every ~40 ms the
 * capture thread posts kAudioSpectrumMessage (the kAudioSessionMessage
 * marshalling, same reason: host state stays loop-thread-owned); the
 * window procedure snapshots the freshest bands and emits them through
 * the same callback path as every other audio report, so band delivery
 * follows the transport: started at play, retired at pause/stop/
 * teardown, skipped while a stream is buffering-stalled. Silence while
 * playing is a row of zeros, still emitted — the cadence follows the
 * transport, the magnitudes tell the truth.
 *
 * Everything here is additive: any failure (old OS, activation denied,
 * format rejected) means NO spectrum events ever, and playback runs
 * exactly as before — no crash, no retry storm. */

constexpr size_t kAudioSpectrumFftSize = 2048;
constexpr double kAudioSpectrumSampleRate = 48000.0;
constexpr double kAudioSpectrumBandLowHz = 50.0;
constexpr double kAudioSpectrumBandHighHz = 16000.0;
constexpr double kAudioSpectrumFloorDb = -60.0;

/* Signals the activation waiter below. Agile on purpose: the OS invokes
 * the completion on one of its own worker threads, and an agile handler
 * needs no apartment marshalling to get there. */
struct AudioSpectrumActivateWaiter final : public IActivateAudioInterfaceCompletionHandler, public IAgileObject {
    LONG refs = 1;
    HANDLE done = nullptr;

    AudioSpectrumActivateWaiter() { done = CreateEventW(nullptr, TRUE, FALSE, nullptr); }
    ~AudioSpectrumActivateWaiter() {
        if (done) CloseHandle(done);
    }
    AudioSpectrumActivateWaiter(const AudioSpectrumActivateWaiter &) = delete;
    AudioSpectrumActivateWaiter &operator=(const AudioSpectrumActivateWaiter &) = delete;

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        if (!out) return E_POINTER;
        if (riid == IID_IUnknown || riid == IID_IActivateAudioInterfaceCompletionHandler) {
            *out = static_cast<IActivateAudioInterfaceCompletionHandler *>(this);
            AddRef();
            return S_OK;
        }
        if (riid == IID_IAgileObject) {
            *out = static_cast<IAgileObject *>(this);
            AddRef();
            return S_OK;
        }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return (ULONG)InterlockedIncrement(&refs); }
    ULONG STDMETHODCALLTYPE Release() override {
        LONG value = InterlockedDecrement(&refs);
        if (value == 0) delete this;
        return (ULONG)value;
    }
    HRESULT STDMETHODCALLTYPE ActivateCompleted(IActivateAudioInterfaceAsyncOperation *) override {
        if (done) SetEvent(done);
        return S_OK;
    }
};

/* Activate an IAudioClient on the process-loopback virtual device for
 * THIS process tree. ActivateAudioInterfaceAsync is resolved from
 * mmdevapi.dll at runtime (module held for the process lifetime, like
 * Media Foundation): an OS without the export answers cleanly instead
 * of failing the toolkit's load. Called from an MTA thread — the
 * completion fires on an OS worker, so a bounded wait here never
 * deadlocks the way it would on the unpumped loop thread. */
static HRESULT audioSpectrumActivateClient(IAudioClient **out_client) {
    *out_client = nullptr;
    static HMODULE mmdevapi = LoadLibraryW(L"mmdevapi.dll");
    if (!mmdevapi) return E_NOTIMPL;
    typedef HRESULT(WINAPI * ActivateAudioInterfaceAsyncFn)(const WCHAR *, REFIID, PROPVARIANT *, IActivateAudioInterfaceCompletionHandler *, IActivateAudioInterfaceAsyncOperation **);
    static ActivateAudioInterfaceAsyncFn activate = reinterpret_cast<ActivateAudioInterfaceAsyncFn>(GetProcAddress(mmdevapi, "ActivateAudioInterfaceAsync"));
    if (!activate) return E_NOTIMPL;

    AUDIOCLIENT_ACTIVATION_PARAMS params = {};
    params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    params.ProcessLoopbackParams.TargetProcessId = GetCurrentProcessId();
    params.ProcessLoopbackParams.ProcessLoopbackMode = PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
    PROPVARIANT prop = {};
    prop.vt = VT_BLOB;
    prop.blob.cbSize = sizeof(params);
    prop.blob.pBlobData = reinterpret_cast<BYTE *>(&params);

    AudioSpectrumActivateWaiter *waiter = new AudioSpectrumActivateWaiter();
    if (!waiter->done) {
        waiter->Release();
        return E_FAIL;
    }
    IActivateAudioInterfaceAsyncOperation *operation = nullptr;
    HRESULT hr = activate(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, IID_IAudioClient, &prop, waiter, &operation);
    if (SUCCEEDED(hr) && operation) {
        /* Activation completes in milliseconds when it completes at all;
         * the deadline only guards against a wedged audio service. A
         * straggling completion after timeout lands on the waiter, whose
         * refcount keeps it alive until the OS lets go. */
        if (WaitForSingleObject(waiter->done, 5000) == WAIT_OBJECT_0) {
            HRESULT activated = E_FAIL;
            IUnknown *unknown = nullptr;
            if (SUCCEEDED(operation->GetActivateResult(&activated, &unknown)) && SUCCEEDED(activated) && unknown) {
                unknown->QueryInterface(IID_IAudioClient, reinterpret_cast<void **>(out_client));
            }
            if (unknown) unknown->Release();
            hr = *out_client ? S_OK : (FAILED(activated) ? activated : E_NOINTERFACE);
        } else {
            hr = E_FAIL;
        }
    } else if (SUCCEEDED(hr)) {
        hr = E_FAIL;
    }
    if (operation) operation->Release();
    waiter->Release();
    return hr;
}

/* Process-loopback clients expose no GetMixFormat (there is no shared
 * mix on a virtual device), so the capture format is declared by us:
 * 32-bit float stereo at 48 kHz, the format the loopback engine
 * converts to on any modern box. Event-driven so the capture thread
 * sleeps between packets instead of polling. */
static HRESULT audioSpectrumInitializeClient(IAudioClient *client, HANDLE samples_ready) {
    WAVEFORMATEX format = {};
    format.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
    format.nChannels = 2;
    format.nSamplesPerSec = (DWORD)kAudioSpectrumSampleRate;
    format.wBitsPerSample = 32;
    format.nBlockAlign = (WORD)(format.nChannels * format.wBitsPerSample / 8);
    format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;
    /* 200 ms buffer (in 100 ns units): generous slack for a worker
     * thread that also spends time in the FFT. */
    HRESULT hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 2000000, 0, &format, nullptr);
    if (FAILED(hr)) return hr;
    return client->SetEventHandle(samples_ready);
}

/* The honest support probe behind
 * native_sdk_windows_audio_spectrum_supported: attempt the real
 * activation-and-initialize path once on a short-lived MTA thread and
 * cache the verdict — never a version sniff, because policy (stripped
 * SKUs, a disabled audio service) can deny what the version promises.
 * The probe stream is released immediately; nothing keeps running. */
static bool audioSpectrumSupported() {
    static std::atomic<int> cached{-1};
    const int known = cached.load(std::memory_order_relaxed);
    if (known >= 0) return known != 0;
    bool ok = false;
    std::thread probe([&ok]() {
        (void)CoInitializeEx(nullptr, COINIT_MULTITHREADED | COINIT_DISABLE_OLE1DDE);
        IAudioClient *client = nullptr;
        if (SUCCEEDED(audioSpectrumActivateClient(&client)) && client) {
            HANDLE ready = CreateEventW(nullptr, FALSE, FALSE, nullptr);
            if (ready) {
                ok = SUCCEEDED(audioSpectrumInitializeClient(client, ready));
                CloseHandle(ready);
            }
            client->Release();
        }
        CoUninitialize();
    });
    probe.join();
    cached.store(ok ? 1 : 0, std::memory_order_relaxed);
    return ok;
}

/* In-place iterative radix-2 FFT (n a power of two): bit-reversal
 * permutation, then butterfly passes with a double-precision running
 * twiddle so rounding does not accumulate across the 1024-wide stages.
 * Textbook and ~30 lines — the whole reason no DSP library is needed. */
static void audioSpectrumFft(float *re, float *im, size_t n) {
    for (size_t i = 1, j = 0; i < n; ++i) {
        size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j |= bit;
        if (i < j) {
            std::swap(re[i], re[j]);
            std::swap(im[i], im[j]);
        }
    }
    for (size_t len = 2; len <= n; len <<= 1) {
        const double angle = -2.0 * 3.14159265358979323846 / (double)len;
        const double step_re = cos(angle);
        const double step_im = sin(angle);
        for (size_t start = 0; start < n; start += len) {
            double w_re = 1.0;
            double w_im = 0.0;
            for (size_t k = 0; k < len / 2; ++k) {
                const size_t even = start + k;
                const size_t odd = start + k + len / 2;
                const double t_re = w_re * re[odd] - w_im * im[odd];
                const double t_im = w_re * im[odd] + w_im * re[odd];
                re[odd] = (float)(re[even] - t_re);
                im[odd] = (float)(im[even] - t_im);
                re[even] = (float)(re[even] + t_re);
                im[even] = (float)(im[even] + t_im);
                const double next_re = w_re * step_re - w_im * step_im;
                w_im = w_re * step_im + w_im * step_re;
                w_re = next_re;
            }
        }
    }
}

/* The 32 buckets as FFT-bin index ranges, computed once per capture:
 * log-spaced edges from 50 Hz to 16 kHz. A bucket narrower than one bin
 * (the lowest few, at 23.4 Hz/bin) folds the single bin nearest its
 * geometric center, so every bucket always reports a real magnitude. */
struct AudioSpectrumBandRange {
    size_t first = 0;
    size_t last = 0;
};

static void audioSpectrumComputeBandRanges(AudioSpectrumBandRange ranges[kAudioSpectrumBandCount]) {
    const double bin_hz = kAudioSpectrumSampleRate / (double)kAudioSpectrumFftSize;
    const double ratio = kAudioSpectrumBandHighHz / kAudioSpectrumBandLowHz;
    const size_t max_bin = kAudioSpectrumFftSize / 2 - 1;
    for (size_t band = 0; band < kAudioSpectrumBandCount; ++band) {
        const double lo = kAudioSpectrumBandLowHz * pow(ratio, (double)band / (double)kAudioSpectrumBandCount);
        const double hi = kAudioSpectrumBandLowHz * pow(ratio, (double)(band + 1) / (double)kAudioSpectrumBandCount);
        size_t first = (size_t)ceil(lo / bin_hz);
        size_t last = hi / bin_hz > 1.0 ? (size_t)ceil(hi / bin_hz) - 1 : 0;
        if (first < 1) first = 1;
        if (last > max_bin) last = max_bin;
        if (last < first) {
            size_t nearest = (size_t)lround(sqrt(lo * hi) / bin_hz);
            if (nearest < 1) nearest = 1;
            if (nearest > max_bin) nearest = max_bin;
            first = nearest;
            last = nearest;
        }
        ranges[band].first = first;
        ranges[band].last = last;
    }
}

/* One analysis pass: Hann window over the newest kAudioSpectrumFftSize
 * mono samples, FFT, then per bucket the PEAK bin magnitude converted
 * to dBFS (full scale = a 1.0-amplitude sine; the 4/N factor undoes the
 * FFT scaling and the Hann coherent gain of 0.5), clamped to [-60, 0]
 * and mapped linearly to 0..255. Silence lands at the floor: zeros. */
static void audioSpectrumAnalyze(const float *samples, const float *window, const AudioSpectrumBandRange *ranges, uint8_t out_bands[kAudioSpectrumBandCount]) {
    float re[kAudioSpectrumFftSize];
    float im[kAudioSpectrumFftSize];
    for (size_t i = 0; i < kAudioSpectrumFftSize; ++i) {
        re[i] = samples[i] * window[i];
        im[i] = 0.0f;
    }
    audioSpectrumFft(re, im, kAudioSpectrumFftSize);
    const double amplitude_scale = 4.0 / (double)kAudioSpectrumFftSize;
    for (size_t band = 0; band < kAudioSpectrumBandCount; ++band) {
        double peak = 0.0;
        for (size_t bin = ranges[band].first; bin <= ranges[band].last; ++bin) {
            const double magnitude = sqrt((double)re[bin] * re[bin] + (double)im[bin] * im[bin]);
            if (magnitude > peak) peak = magnitude;
        }
        const double amplitude = peak * amplitude_scale;
        double db = amplitude > 0.0 ? 20.0 * log10(amplitude) : kAudioSpectrumFloorDb;
        if (db < kAudioSpectrumFloorDb) db = kAudioSpectrumFloorDb;
        if (db > 0.0) db = 0.0;
        out_bands[band] = (uint8_t)lround((db - kAudioSpectrumFloorDb) / -kAudioSpectrumFloorDb * 255.0);
    }
}

/* The capture worker: bring the loopback stream up, then drain packets
 * into a mono ring, refresh the shared band snapshot roughly every half
 * FFT (~21 ms), and post one emission beat per ~40 ms until told to
 * stop. Failure at any bring-up step just returns — nothing ever posts,
 * so no spectrum events exist and playback never notices. */
static void audioSpectrumCaptureThread(std::shared_ptr<AudioSpectrumShared> shared) {
    (void)CoInitializeEx(nullptr, COINIT_MULTITHREADED | COINIT_DISABLE_OLE1DDE);
    IAudioClient *client = nullptr;
    IAudioCaptureClient *capture = nullptr;
    HANDLE ready = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    bool running = false;
    do {
        if (!ready) break;
        if (FAILED(audioSpectrumActivateClient(&client)) || !client) break;
        if (FAILED(audioSpectrumInitializeClient(client, ready))) break;
        if (FAILED(client->GetService(IID_IAudioCaptureClient, reinterpret_cast<void **>(&capture))) || !capture) break;
        if (FAILED(client->Start())) break;
        running = true;
    } while (false);

    if (running) {
        float window[kAudioSpectrumFftSize];
        for (size_t i = 0; i < kAudioSpectrumFftSize; ++i) {
            window[i] = (float)(0.5 * (1.0 - cos(2.0 * 3.14159265358979323846 * (double)i / (double)(kAudioSpectrumFftSize - 1))));
        }
        AudioSpectrumBandRange ranges[kAudioSpectrumBandCount];
        audioSpectrumComputeBandRanges(ranges);
        float ring[kAudioSpectrumFftSize] = {};
        float ordered[kAudioSpectrumFftSize];
        size_t ring_pos = 0;
        size_t fresh_samples = 0;
        ULONGLONG last_packet_tick = GetTickCount64();
        ULONGLONG last_post_tick = 0;
        bool bands_zeroed = false;

        while (!shared->stop.load(std::memory_order_relaxed)) {
            WaitForSingleObject(ready, kAudioSpectrumIntervalMs);
            UINT32 frames = 0;
            while (SUCCEEDED(capture->GetNextPacketSize(&frames)) && frames > 0) {
                BYTE *data = nullptr;
                DWORD flags = 0;
                UINT32 got = 0;
                if (FAILED(capture->GetBuffer(&data, &got, &flags, nullptr, nullptr))) break;
                const float *stereo = reinterpret_cast<const float *>(data);
                const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0 || !data;
                for (UINT32 frame = 0; frame < got; ++frame) {
                    ring[ring_pos] = silent ? 0.0f : 0.5f * (stereo[frame * 2] + stereo[frame * 2 + 1]);
                    ring_pos = (ring_pos + 1) & (kAudioSpectrumFftSize - 1);
                }
                fresh_samples += got;
                capture->ReleaseBuffer(got);
                last_packet_tick = GetTickCount64();
            }
            if (fresh_samples >= kAudioSpectrumFftSize / 2) {
                fresh_samples = 0;
                bands_zeroed = false;
                const size_t tail = kAudioSpectrumFftSize - ring_pos;
                memcpy(ordered, ring + ring_pos, tail * sizeof(float));
                memcpy(ordered + tail, ring, ring_pos * sizeof(float));
                uint8_t bands[kAudioSpectrumBandCount];
                audioSpectrumAnalyze(ordered, window, ranges, bands);
                std::lock_guard<std::mutex> guard(shared->mutex);
                memcpy(shared->bands, bands, sizeof(bands));
            } else if (!bands_zeroed && GetTickCount64() - last_packet_tick > 250) {
                /* Loopback delivers packets only while the process
                 * renders; a starved stream must read as silence, not as
                 * the last magnitudes frozen mid-note. */
                bands_zeroed = true;
                memset(ring, 0, sizeof(ring));
                std::lock_guard<std::mutex> guard(shared->mutex);
                memset(shared->bands, 0, sizeof(shared->bands));
            }
            /* One emission beat per interval; the loop-thread handler
             * gates on the live transport (paused, stalled, replaced),
             * so a beat is never more than a queue hop plus a memcpy. */
            const ULONGLONG now = GetTickCount64();
            if (now - last_post_tick >= kAudioSpectrumIntervalMs) {
                last_post_tick = now;
                PostMessageW(shared->hwnd, kAudioSpectrumMessage, (WPARAM)shared->generation, 0);
            }
        }
        client->Stop();
    }

    if (capture) capture->Release();
    if (client) client->Release();
    if (ready) CloseHandle(ready);
    CoUninitialize();
}

/* Loop thread: hand the capture thread its stop flag and bump the
 * generation so in-flight emission posts land dead; download-cancel
 * style, nothing blocks. Idempotent, so every teardown path (pause,
 * stop, replacement, failure, destroy) can call it unconditionally. */
static void audioSpectrumStopCapture(Host *host) {
    AudioSpectrumState &spectrum = host->spectrum;
    spectrum.generation += 1;
    if (spectrum.shared) {
        spectrum.shared->stop.store(true, std::memory_order_relaxed);
        spectrum.shared.reset();
    }
}

/* Loop thread, on the play path: launch the capture worker. The cached
 * support probe gates entry, so an unsupported box pays one probe ever
 * and nothing per play. */
static void audioSpectrumStartCapture(Host *host) {
    AudioSpectrumState &spectrum = host->spectrum;
    if (spectrum.shared) return;
    if (!audioSpectrumSupported()) return;
    HWND hwnd = parentWindow(host);
    if (!hwnd) return;
    spectrum.generation += 1;
    spectrum.shared = std::make_shared<AudioSpectrumShared>();
    spectrum.shared->hwnd = hwnd;
    spectrum.shared->generation = spectrum.generation;
    std::thread(audioSpectrumCaptureThread, spectrum.shared).detach();
}

/* Whether any of the host's top-level windows still reaches the glass.
 * Minimize-keyed on purpose: IsIconic is the one occlusion fact this
 * host trusts (the same decision the minimized frame heartbeat makes —
 * the covered-but-not-minimized case has no reliable cheap signal on
 * the DXGI presentation path), so covered windows keep full spectrum
 * cadence and only an all-minimized app goes quiet. Checked across the
 * whole window table because a spectrum consumer may draw its bands in
 * any of the app's windows. */
static bool audioAnyWindowReachesGlass(Host *host) {
    for (auto &entry : host->windows) {
        if (entry.second.hwnd && !IsIconic(entry.second.hwnd)) return true;
    }
    return false;
}

/* One emission beat, marshalled from the capture thread; loop thread.
 * Stale generations (a stopped or replaced capture's stragglers) drop
 * here, and the live transport gates delivery: paused and stalled
 * transports emit nothing — the bars freeze honestly — while silence on
 * a rolling transport still emits its row of zeros. The occluded-
 * emission rule gates delivery too: SPECTRUM bands describe a display,
 * so while every window is minimized no report is emitted — no event
 * wakes the runtime's update loop for glass nobody can see, and the
 * journal records the stretch as honest silence. The capture thread
 * keeps its ring fresh (it must drain the loopback client regardless,
 * and its FFT runs off the loop thread), so the first beat after a
 * restore delivers current bands — honest within one report. */
static void audioHandleSpectrumMessage(Host *host, WPARAM generation) {
    AudioState &audio = host->audio;
    AudioSpectrumState &spectrum = host->spectrum;
    if (!spectrum.shared || (uint64_t)generation != spectrum.generation) return;
    if (!audio.active || !audio.playing || audio.buffering) return;
    if (!audioAnyWindowReachesGlass(host)) return;
    uint8_t bands[kAudioSpectrumBandCount];
    {
        std::lock_guard<std::mutex> guard(spectrum.shared->mutex);
        memcpy(bands, spectrum.shared->bands, sizeof(bands));
    }
    audioEmitSpectrum(host, bands);
}

/* Release the whole pipeline. The session retires through Close(): the
 * event pump answers the MESessionClosed handshake by shutting source
 * and session down on the worker thread, so the loop never blocks. The
 * download is cancelled when the caller says so (replacement, explicit
 * stop, failure — a skipped track should not keep burning bandwidth)
 * but ORPHANED on natural completion: it is usually already done, and
 * letting a straggler finish installs the cache entry the completed
 * play earned. */
static void audioReleaseSession(Host *host, bool cancel_download) {
    std::lock_guard<std::recursive_mutex> guard(host->lifetime->mutex);
    AudioState &audio = host->audio;
    audioStopPositionTimer(host);
    audioSpectrumStopCapture(host);
    audio.generation += 1;
    if (audio.clock) {
        audio.clock->Release();
        audio.clock = nullptr;
    }
    const bool had_session = audio.session != nullptr;
    if (audio.session) {
        if (FAILED(audio.session->Close())) {
            /* Close refused (session already dead): shut down inline;
             * the pump's next callback fails and retires itself. */
            if (audio.source) audio.source->Shutdown();
            audio.session->Shutdown();
        }
        audio.session->Release();
        audio.session = nullptr;
    }
    if (audio.source) {
        /* No session pump owns a pending (resolved-but-unattached)
         * source, so it is shut down here. */
        if (!had_session) audio.source->Shutdown();
        audio.source->Release();
        audio.source = nullptr;
    }
    if (cancel_download && audio.download_cancel) audio.download_cancel->cancelled.store(true);
    const uint64_t generation = audio.generation;
    audio = AudioState{};
    audio.generation = generation;
}

/* Build the playback topology (every selected audio stream into a
 * Streaming Audio Renderer; other streams deselected) on the pending
 * source and arm the event pump. Duration comes off the presentation
 * descriptor now; LOADED waits for the topology-ready note. */
static bool audioAttachSession(Host *host) {
    AudioState &audio = host->audio;
    IMFMediaSource *source = audio.source;
    if (!source) return false;
    HWND hwnd = parentWindow(host);
    if (!hwnd) return false;
    IMFMediaSession *session = nullptr;
    if (FAILED(MFCreateMediaSession(nullptr, &session)) || !session) return false;
    IMFPresentationDescriptor *descriptor = nullptr;
    IMFTopology *topology = nullptr;
    bool ok = false;
    do {
        if (FAILED(source->CreatePresentationDescriptor(&descriptor)) || !descriptor) break;
        UINT64 duration_hns = 0;
        if (SUCCEEDED(descriptor->GetUINT64(MF_PD_DURATION, &duration_hns))) audio.duration_ms = duration_hns / 10000ull;
        if (FAILED(MFCreateTopology(&topology)) || !topology) break;
        DWORD stream_count = 0;
        if (FAILED(descriptor->GetStreamDescriptorCount(&stream_count))) break;
        DWORD audio_streams = 0;
        for (DWORD index = 0; index < stream_count; ++index) {
            BOOL selected = FALSE;
            IMFStreamDescriptor *stream = nullptr;
            if (FAILED(descriptor->GetStreamDescriptorByIndex(index, &selected, &stream)) || !stream) continue;
            GUID major = {};
            IMFMediaTypeHandler *handler = nullptr;
            if (SUCCEEDED(stream->GetMediaTypeHandler(&handler)) && handler) {
                handler->GetMajorType(&major);
                handler->Release();
            }
            if (!selected || major != MFMediaType_Audio) {
                if (selected) descriptor->DeselectStream(index);
                stream->Release();
                continue;
            }
            IMFTopologyNode *source_node = nullptr;
            IMFTopologyNode *output_node = nullptr;
            IMFActivate *renderer = nullptr;
            const bool added = SUCCEEDED(MFCreateTopologyNode(MF_TOPOLOGY_SOURCESTREAM_NODE, &source_node)) &&
                SUCCEEDED(source_node->SetUnknown(MF_TOPONODE_SOURCE, source)) &&
                SUCCEEDED(source_node->SetUnknown(MF_TOPONODE_PRESENTATION_DESCRIPTOR, descriptor)) &&
                SUCCEEDED(source_node->SetUnknown(MF_TOPONODE_STREAM_DESCRIPTOR, stream)) &&
                SUCCEEDED(MFCreateTopologyNode(MF_TOPOLOGY_OUTPUT_NODE, &output_node)) &&
                SUCCEEDED(MFCreateAudioRendererActivate(&renderer)) &&
                SUCCEEDED(output_node->SetObject(renderer)) &&
                SUCCEEDED(topology->AddNode(source_node)) &&
                SUCCEEDED(topology->AddNode(output_node)) &&
                SUCCEEDED(source_node->ConnectOutput(0, output_node, 0));
            if (renderer) renderer->Release();
            if (output_node) output_node->Release();
            if (source_node) source_node->Release();
            stream->Release();
            if (added) audio_streams += 1;
        }
        if (audio_streams == 0) break;
        if (FAILED(session->SetTopology(0, topology))) break;
        ok = true;
    } while (false);
    if (topology) topology->Release();
    if (descriptor) descriptor->Release();
    if (!ok) {
        session->Shutdown();
        session->Release();
        return false;
    }
    audio.session = session;
    /* The pump owns its refs (constructor AddRefs) and self-releases at
     * MESessionClosed or on pump failure. */
    AudioSessionEventForwarder *pump = new AudioSessionEventForwarder(session, source, hwnd, audio.generation);
    if (FAILED(session->BeginGetEvent(pump, nullptr))) {
        pump->Release();
        source->Shutdown();
        session->Shutdown();
        session->Release();
        audio.session = nullptr;
        return false;
    }
    return true;
}

/* Start (optionally at a position); a paused transport pauses again
 * immediately — the session applies the queued pair in order, landing
 * paused at the new position (the Media Foundation scrub idiom). */
static void audioStartTransport(Host *host, bool has_position, uint64_t position_ms) {
    AudioState &audio = host->audio;
    if (!audio.session) return;
    PROPVARIANT start = {};
    if (has_position) {
        start.vt = VT_I8;
        start.hVal.QuadPart = (LONGLONG)position_ms * 10000;
    } else {
        start.vt = VT_EMPTY;
    }
    audio.session->Start(&kNativeSdkAudioTimeFormat, &start);
    if (!audio.playing) audio.session->Pause();
}

/* Per-stream volume on the Streaming Audio Renderer — pipeline-local,
 * unlike the policy (per-app mixer) volume service, so the app's mixer
 * entry is never mutated. */
static void audioApplyVolume(Host *host) {
    AudioState &audio = host->audio;
    if (!audio.session) return;
    IMFAudioStreamVolume *volume = nullptr;
    if (FAILED(MFGetService(audio.session, MR_STREAM_VOLUME_SERVICE, IID_IMFAudioStreamVolume, reinterpret_cast<void **>(&volume))) || !volume) return;
    UINT32 channels = 0;
    if (SUCCEEDED(volume->GetChannelCount(&channels)) && channels > 0 && channels <= 16) {
        float levels[16];
        for (UINT32 index = 0; index < channels; ++index) levels[index] = audio.volume;
        volume->SetAllVolumes(channels, levels);
    }
    volume->Release();
}

/* Synchronous local-file load: 0 loaded (the asynchronous LOADED
 * acknowledgment follows at topology ready), 1 missing file, 2
 * undecodable — the macOS host's result contract. */
static int audioLoadPathInternal(Host *host, const std::string &path) {
    audioReleaseSession(host, true);
    std::wstring wide = widen(path);
    if (!regularFileExists(wide)) return 1;
    if (!audioEnsureMediaFoundation()) return 2;
    IMFSourceResolver *resolver = nullptr;
    if (FAILED(MFCreateSourceResolver(&resolver)) || !resolver) return 2;
    MF_OBJECT_TYPE type = MF_OBJECT_INVALID;
    IUnknown *object = nullptr;
    /* A cache entry's name is a hash, so resolution must sniff content
     * instead of trusting the extension. */
    const HRESULT hr = resolver->CreateObjectFromURL(wide.c_str(), MF_RESOLUTION_MEDIASOURCE | MF_RESOLUTION_CONTENT_DOES_NOT_HAVE_TO_MATCH_EXTENSION_OR_MIME_TYPE, nullptr, &type, &object);
    resolver->Release();
    if (FAILED(hr) || !object) return 2;
    IMFMediaSource *source = nullptr;
    object->QueryInterface(IID_IMFMediaSource, reinterpret_cast<void **>(&source));
    object->Release();
    if (!source) return 2;
    AudioState &audio = host->audio;
    audio.active = true;
    audio.source = source;
    if (!audioAttachSession(host)) {
        audioReleaseSession(host, false);
        return 2;
    }
    return 0;
}

/* URL sources: verified cache entry first (plays as a plain local file,
 * no network), then an asynchronously resolved progressive stream with
 * a parallel cache-filling download. Returns 1 for the cache hit, 0 for
 * a started stream, 2 when the URL cannot be used; everything
 * asynchronous — readiness, stalls, natural end, network death —
 * arrives as audio reports. */
static int audioLoadUrlInternal(Host *host, const std::string &url, const std::string &cache_path, uint64_t expected_bytes) {
    audioReleaseSession(host, true);
    if (url.find("://") == std::string::npos) return 2;
    if (!cache_path.empty()) {
        std::wstring cache_wide = widen(cache_path);
        bool exists = false;
        const uint64_t size = audioFileSize(cache_wide, &exists);
        if (exists) {
            if (expected_bytes == 0 || size == expected_bytes) {
                if (audioLoadPathInternal(host, cache_path) == 0) return 1;
                /* An entry with the right size that will not decode is
                 * corrupt — fall through to discard and re-stream. */
            }
            /* Partial, stale, or corrupt: a bad cache entry never
             * plays, and never survives to fool the next lookup. */
            DeleteFileW(cache_wide.c_str());
        }
    }
    if (!audioEnsureMediaFoundation()) return 2;
    HWND hwnd = parentWindow(host);
    if (!hwnd) return 2;
    IMFSourceResolver *resolver = nullptr;
    if (FAILED(MFCreateSourceResolver(&resolver)) || !resolver) return 2;
    AudioState &audio = host->audio;
    audio.active = true;
    audio.url_source = true;
    /* A fresh stream has no bytes yet: buffering starts true and drops
     * when the session actually starts rolling. */
    audio.buffering = true;
    AudioSourceResolveForwarder *forwarder = new AudioSourceResolveForwarder(resolver, host, host->lifetime, hwnd, audio.generation);
    const HRESULT hr = resolver->BeginCreateObjectFromURL(widen(url).c_str(), MF_RESOLUTION_MEDIASOURCE, nullptr, nullptr, forwarder, nullptr);
    forwarder->Release();
    resolver->Release();
    if (FAILED(hr)) {
        audioReleaseSession(host, false);
        return 2;
    }
    if (!cache_path.empty()) {
        audio.download_cancel = std::make_shared<AudioDownloadCancel>();
        std::thread(audioCacheDownloadThread, url, widen(cache_path), expected_bytes, audio.download_cancel).detach();
    }
    return 0;
}

/* Topology resolved: apply the queued transport intent (volume, seek,
 * play), THEN acknowledge with LOADED so the event carries the honest
 * playing flag — the runtime issues play immediately after load, before
 * readiness, exactly like the macOS local path. */
static void audioTopologyReady(Host *host) {
    AudioState &audio = host->audio;
    audio.ready = true;
    if (audio.volume != 1.0f) audioApplyVolume(host);
    if (audio.has_pending_seek || audio.pending_play) {
        audioStartTransport(host, audio.has_pending_seek, audio.pending_seek_ms);
    }
    audio.pending_play = false;
    audio.has_pending_seek = false;
    if (!audio.loaded_emitted) {
        audio.loaded_emitted = true;
        audioEmitEvent(host, kAudioEventLoaded);
    }
}

/* Natural end of the track. Retire-before-emit discipline (mirroring
 * the macOS host): the completion Msg routinely starts the NEXT track
 * from inside its own dispatch, and tearing down afterwards would
 * destroy the player that load just installed. The duration is captured
 * first so the event carries the honest terminal position. The cache
 * download is orphaned, not cancelled — completion is what earned the
 * cache entry. */
static void audioCompleted(Host *host) {
    const uint64_t duration_ms = host->audio.duration_ms;
    audioReleaseSession(host, false);
    audioEmitReport(host, kAudioEventCompleted, duration_ms, duration_ms, 0, 0);
}

/* A load that never became playable or a pipeline that died mid-flight:
 * one FAILED report, player retired first. The cache download dies too
 * — bytes from a failing source are not trustworthy. */
static void audioFailed(Host *host) {
    audioReleaseSession(host, true);
    audioEmitReport(host, kAudioEventFailed, 0, 0, 0, 0);
}

/* Distilled session notes, marshalled from Media Foundation worker
 * threads via PostMessage; loop thread. Stale generations (a replaced
 * or stopped playback's stragglers) are dropped here. */
static void audioHandleSessionMessage(Host *host, WPARAM note, LPARAM generation) {
    std::lock_guard<std::recursive_mutex> guard(host->lifetime->mutex);
    AudioState &audio = host->audio;
    if (!audio.active || (uint64_t)generation != audio.generation) return;
    switch (note) {
        case kAudioNoteSourceResolved:
            if (!audioAttachSession(host)) audioFailed(host);
            break;
        case kAudioNoteSourceFailed:
        case kAudioNoteError:
            audioFailed(host);
            break;
        case kAudioNoteTopologyReady:
            audioTopologyReady(host);
            break;
        case kAudioNoteStarted:
            /* The transport is rolling: a fresh stream's optimistic
             * buffering flag drops here and is emitted immediately (not
             * at the next tick), like the macOS timeControl transition. */
            if (audio.buffering) {
                audio.buffering = false;
                audioEmitEvent(host, kAudioEventPosition);
            }
            break;
        case kAudioNoteBufferingStarted:
            if (!audio.buffering) {
                audio.buffering = true;
                audioEmitEvent(host, kAudioEventPosition);
            }
            break;
        case kAudioNoteBufferingStopped:
            if (audio.buffering) {
                audio.buffering = false;
                audioEmitEvent(host, kAudioEventPosition);
            }
            break;
        case kAudioNoteEnded:
            audioCompleted(host);
            break;
        default:
            break;
    }
}

/* WM_TIMER for the audio position tick: emit one position report while
 * a playback is live; a straggler after teardown retires itself. */
static bool handleAudioTimerMessage(Host *host, WPARAM wparam) {
    if (wparam != kAudioPositionTimerId) return false;
    if (!host->audio.active) {
        audioStopPositionTimer(host);
        return true;
    }
    audioEmitEvent(host, kAudioEventPosition);
    return true;
}

static void destroyChildWebViewsForWindow(Host *host, uint64_t window_id) {
    if (!host) return;
    for (auto it = host->webviews.begin(); it != host->webviews.end();) {
        if (it->second.window_id == window_id) {
#if NATIVE_SDK_HAS_WEBVIEW2
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

#if NATIVE_SDK_HAS_WEBVIEW2
using CreateEnvironmentFn = HRESULT (STDAPICALLTYPE *)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions *, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *);

static const wchar_t *nativeSdkBridgeScript() {
    return LR"ZN((function(){
	if(window.zero&&window.zero.invoke&&window.zero.on&&window.zero._emit){return;}
	var pending=new Map();
	var listeners=new Map();
	var nextId=1;
	function post(message){
	if(window.chrome&&window.chrome.webview&&window.chrome.webview.postMessage){window.chrome.webview.postMessage(message);return;}
	throw new Error('native-sdk bridge transport is unavailable');
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
	function viewCreatePayload(options){options=options||{};validateViewSelector(options);ensureString(options.kind,'kind');var payload={label:options.label,kind:options.kind,windowId:options.windowId};var frame=optionalFramePayload(options);if(frame){payload.frame=frame;}if(options.parent!=null){payload.parent=ensureString(options.parent,'parent');}if(options.role!=null){payload.role=ensureText(options.role,'role');}if(options.accessibilityLabel!=null){payload.accessibilityLabel=ensureText(options.accessibilityLabel,'accessibilityLabel');}if(options.text!=null){payload.text=ensureText(options.text,'text');}if(options.command!=null){payload.command=ensureText(options.command,'command');}if(options.url!=null){payload.url=ensureString(options.url,'url');}if(options.layer!=null){payload.layer=ensureNumber(options.layer,'layer');}if(options.visible!=null){payload.visible=!!options.visible;}if(options.enabled!=null){payload.enabled=!!options.enabled;}if(options.transparent!=null){payload.transparent=!!options.transparent;}if(options.bridge!=null){payload.bridge=!!options.bridge;}return payload;}
	function viewPatchPayload(options){options=options||{};validateViewSelector(options);var payload={label:options.label,windowId:options.windowId};var frame=optionalFramePayload(options);if(frame){payload.frame=frame;}if(options.layer!=null){payload.layer=ensureNumber(options.layer,'layer');}if(options.visible!=null){payload.visible=!!options.visible;}if(options.enabled!=null){payload.enabled=!!options.enabled;}if(options.role!=null){payload.role=ensureText(options.role,'role');}if(options.accessibilityLabel!=null){payload.accessibilityLabel=ensureText(options.accessibilityLabel,'accessibilityLabel');}if(options.text!=null){payload.text=ensureText(options.text,'text');}if(options.command!=null){payload.command=ensureText(options.command,'command');}if(options.url!=null){payload.url=ensureString(options.url,'url');}return payload;}
	function viewFramePayload(options){options=options||{};validateViewSelector(options);var frame=options.frame||options;return {label:options.label,windowId:options.windowId,frame:{x:frame.x==null?0:ensureNumber(frame.x,'frame.x'),y:frame.y==null?0:ensureNumber(frame.y,'frame.y'),width:ensureNumber(frame.width,'frame.width'),height:ensureNumber(frame.height,'frame.height')}};}
	function viewVisiblePayload(options){options=options||{};validateViewSelector(options);if(options.visible==null){throw new TypeError('visible is required');}return {label:options.label,windowId:options.windowId,visible:!!options.visible};}
	function viewHandle(info){return Object.freeze(Object.assign({},info,{update:function(patch){return views.update(Object.assign({},patch||{},{label:info.label,windowId:info.windowId}));},setFrame:function(frame){return views.setFrame({label:info.label,windowId:info.windowId,frame:frame});},setVisible:function(visible){return views.setVisible({label:info.label,windowId:info.windowId,visible:visible});},focus:function(){return views.focus({label:info.label,windowId:info.windowId});},close:function(){return views.close({label:info.label,windowId:info.windowId});}}));}
	function on(name,callback){if(typeof callback!=='function'){throw new TypeError('callback must be a function');}var set=listeners.get(name);if(!set){set=new Set();listeners.set(name,set);}set.add(callback);return function(){off(name,callback);};}
	function off(name,callback){var set=listeners.get(name);if(set){set.delete(callback);if(set.size===0){listeners.delete(name);}}}
	function emit(name,detail){var set=listeners.get(name);if(set){Array.from(set).forEach(function(callback){callback(detail);});}window.dispatchEvent(new CustomEvent('native-sdk:'+name,{detail:detail}));}
	var commands=Object.freeze({
	invoke:function(value){return invoke('native-sdk.command.invoke',commandPayload(value));},
	list:function(){return invoke('native-sdk.command.list',{});}
	});
	var windows=Object.freeze({
	create:function(options){return invoke('native-sdk.window.create',options||{});},
	list:function(){return invoke('native-sdk.window.list',{});},
	focus:function(value){return invoke('native-sdk.window.focus',selector(value));},
	close:function(value){return invoke('native-sdk.window.close',selector(value));}
	});
	var dialogs=Object.freeze({
	openFile:function(options){return invoke('native-sdk.dialog.openFile',options||{});},
	saveFile:function(options){return invoke('native-sdk.dialog.saveFile',options||{});},
	showMessage:function(options){return invoke('native-sdk.dialog.showMessage',options||{});}
	});
	function clipboardReadPayload(value){value=value||{};return {mimeType:ensureString(value.mimeType||value.type||'text/plain','mimeType')};}
	function clipboardWritePayload(value){if(typeof value==='string'){return {mimeType:'text/plain',data:value};}value=value||{};var data=value.data!=null?value.data:(value.text!=null?value.text:value.value);return {mimeType:ensureString(value.mimeType||value.type||'text/plain','mimeType'),data:ensureText(data,'data')};}
	var clipboard=Object.freeze({
	readText:function(){return invoke('native-sdk.clipboard.readText',{});},
	writeText:function(value){var text=typeof value==='string'?value:(value||{}).text;return invoke('native-sdk.clipboard.writeText',{text:ensureText(text,'text')});},
	read:function(value){return invoke('native-sdk.clipboard.read',clipboardReadPayload(value));},
	write:function(value){return invoke('native-sdk.clipboard.write',clipboardWritePayload(value));}
	});
	var os=Object.freeze({
	openUrl:function(value){var options=typeof value==='string'?{url:value}:(value||{});return invoke('native-sdk.os.openUrl',{url:ensureString(options.url,'url')});},
	showNotification:function(value){var options=typeof value==='string'?{title:value}:(value||{});var payload={title:ensureString(options.title,'title')};if(options.subtitle!=null){payload.subtitle=ensureString(options.subtitle,'subtitle');}if(options.body!=null){payload.body=ensureString(options.body,'body');}return invoke('native-sdk.os.showNotification',payload);},
	revealPath:function(value){var options=typeof value==='string'?{path:value}:(value||{});return invoke('native-sdk.os.revealPath',{path:ensureString(options.path,'path')});},
	addRecentDocument:function(value){var options=typeof value==='string'?{path:value}:(value||{});return invoke('native-sdk.os.addRecentDocument',{path:ensureString(options.path,'path')});},
	clearRecentDocuments:function(){return invoke('native-sdk.os.clearRecentDocuments',{});}
	});
	function credentialPayload(value){value=value||{};return {service:ensureString(value.service,'service'),account:ensureString(value.account,'account')};}
	function credentialSetPayload(value){var payload=credentialPayload(value);payload.secret=ensureString(value.secret!=null?value.secret:value.value,'secret');return payload;}
	var credentials=Object.freeze({
	set:function(value){return invoke('native-sdk.credentials.set',credentialSetPayload(value));},
	get:function(value){return invoke('native-sdk.credentials.get',credentialPayload(value));},
	delete:function(value){return invoke('native-sdk.credentials.delete',credentialPayload(value));}
	});
	function platformFeaturePayload(value){if(typeof value==='string'){return {feature:ensureString(value,'feature')};}value=value||{};return {feature:ensureString(value.feature!=null?value.feature:value.name,'feature')};}
	var platform=Object.freeze({
	supports:function(value){return invoke('native-sdk.platform.supports',platformFeaturePayload(value));}
	});
	function zoomPayload(options){options=options||{};validateWebViewSelector(options);return {label:options.label,windowId:options.windowId,zoom:ensureNumber(options.zoom,'zoom')};}
	function layerPayload(options){options=options||{};validateWebViewSelector(options);return {label:options.label,windowId:options.windowId,layer:ensureNumber(options.layer,'layer')};}
	var webviews=Object.freeze({
	create:function(options){return invoke('native-sdk.webview.create',createPayload(options)).then(webviewHandle);},
	list:function(){return invoke('native-sdk.webview.list',{});},
	setFrame:function(options){return invoke('native-sdk.webview.setFrame',framePayload(options));},
	navigate:function(options){return invoke('native-sdk.webview.navigate',navigatePayload(options));},
	setZoom:function(options){return invoke('native-sdk.webview.setZoom',zoomPayload(options));},
	setLayer:function(options){return invoke('native-sdk.webview.setLayer',layerPayload(options));},
	close:function(options){return invoke('native-sdk.webview.close',closePayload(options));}
	});
	var views=Object.freeze({
	create:function(options){return invoke('native-sdk.view.create',viewCreatePayload(options)).then(viewHandle);},
	list:function(){return invoke('native-sdk.view.list',{});},
	update:function(options,patch){if(typeof options==='string'){return invoke('native-sdk.view.update',viewPatchPayload(Object.assign({},patch||{},{label:options}))).then(viewHandle);}return invoke('native-sdk.view.update',viewPatchPayload(options)).then(viewHandle);},
	setFrame:function(options){return invoke('native-sdk.view.setFrame',viewFramePayload(options)).then(viewHandle);},
	setVisible:function(options){return invoke('native-sdk.view.setVisible',viewVisiblePayload(options)).then(viewHandle);},
	focus:function(options){return invoke('native-sdk.view.focus',viewSelectorPayload(options)).then(viewHandle);},
	focusNext:function(options){options=options||{};return invoke('native-sdk.view.focusNext',{windowId:options.windowId}).then(viewHandle);},
	focusPrevious:function(options){options=options||{};return invoke('native-sdk.view.focusPrevious',{windowId:options.windowId}).then(viewHandle);},
	close:function(options){return invoke('native-sdk.view.close',viewSelectorPayload(options));}
	});
	try{Object.defineProperty(window,'zero',{value:Object.freeze({invoke:invoke,on:on,off:off,commands:commands,windows:windows,dialogs:dialogs,clipboard:clipboard,os:os,credentials:credentials,platform:platform,webviews:webviews,views:views,_complete:complete,_emit:emit}),configurable:false});}catch(error){}
	})();
	)ZN";
}

static RECT webViewRect(const ChildWebView &webview) {
    const double scale = webViewFrameScale(webview);
    RECT rect = {};
    rect.left = 0;
    rect.top = 0;
    rect.right = webViewExtent(webview.width * scale);
    rect.bottom = webViewExtent(webview.height * scale);
    return rect;
}

static void applyWebViewFrame(ChildWebView &webview) {
    if (!webview.hwnd) return;
    const double scale = webViewFrameScale(webview);
    MoveWindow(webview.hwnd, webViewCoord(webview.x * scale), webViewCoord(webview.y * scale), webViewExtent(webview.width * scale), webViewExtent(webview.height * scale), TRUE);
    if (webview.controller) {
        RECT bounds = webViewRect(webview);
        webview.controller->put_Bounds(bounds);
    }
}

static ComPtr<IStream> streamFromBytes(const std::string &bytes) {
    ComPtr<IStream> stream;
    if (bytes.empty()) {
        IStream *raw_stream = nullptr;
        if (SUCCEEDED(CreateStreamOnHGlobal(nullptr, TRUE, &raw_stream))) stream.Attach(raw_stream);
        return stream;
    }

    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
    if (!memory) return stream;
    void *ptr = GlobalLock(memory);
    if (!ptr) {
        GlobalFree(memory);
        return stream;
    }
    memcpy(ptr, bytes.data(), bytes.size());
    GlobalUnlock(memory);

    IStream *raw_stream = nullptr;
    if (FAILED(CreateStreamOnHGlobal(memory, TRUE, &raw_stream))) {
        GlobalFree(memory);
        return stream;
    }
    stream.Attach(raw_stream);
    return stream;
}

static ComPtr<ICoreWebView2WebResourceResponse> webResourceResponse(ICoreWebView2Environment *environment, int status, const wchar_t *reason, const std::string &mime_type, const std::string &bytes) {
    ComPtr<ICoreWebView2WebResourceResponse> response;
    if (!environment) return response;
    ComPtr<IStream> stream = streamFromBytes(bytes);
    if (!stream) return response;
    std::wstring headers = L"Content-Type: " + widen(mime_type) + L"\r\n";
    environment->CreateWebResourceResponse(stream.Get(), status, reason, headers.c_str(), &response);
    return response;
}

static ComPtr<ICoreWebView2WebResourceResponse> textWebResourceResponse(ICoreWebView2Environment *environment, int status, const wchar_t *reason, const char *message) {
    return webResourceResponse(environment, status, reason, "text/plain", message ? std::string(message) : std::string());
}

static ComPtr<ICoreWebView2WebResourceResponse> assetWebResourceResponse(ICoreWebView2Environment *environment, const ChildWebView &webview, const std::string &uri) {
    if (!isInternalAssetUrl(webview, uri)) return {};

    std::string relative;
    if (!assetRelativePathFromUrl(uri, webview.asset_entry, &relative)) {
        return textWebResourceResponse(environment, 400, L"Bad Request", "Unsafe asset path");
    }

    std::string served_relative = relative;
    std::wstring path = assetFilePath(webview, served_relative);
    if (!regularFileExists(path) && webview.spa_fallback) {
        served_relative = safeAssetEntryPath(webview.asset_entry);
        path = assetFilePath(webview, served_relative);
    }

    std::string bytes;
    if (!readFileBytes(path, &bytes)) {
        return textWebResourceResponse(environment, 404, L"Not Found", "Asset not found");
    }

    return webResourceResponse(environment, 200, L"OK", mimeTypeForPath(served_relative), bytes);
}

static void loadWebViewSource(ChildWebView &webview) {
    if (!webview.webview) return;
    if (webview.source_kind == 0) {
        std::wstring html = widen(webview.source);
        webview.webview->NavigateToString(html.c_str());
        return;
    }
    std::string target = webview.source_kind == 2
        ? assetEntryUrl(webview)
        : webview.url;
    if (target.empty()) target = "about:blank";
    std::wstring wide_target = widen(target);
    webview.webview->Navigate(wide_target.c_str());
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
            ComPtr<ICoreWebView2Environment> environment_ref = environment;
            return environment->CreateCoreWebView2Controller(parent, Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                [host, key, lifetime, environment_ref](HRESULT controller_result, ICoreWebView2Controller *controller) -> HRESULT {
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
                            found->second.webview->AddScriptToExecuteOnDocumentCreated(nativeSdkBridgeScript(), nullptr);
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
                                        std::string source_url = narrow(source_wide);
                                        auto source_webview = host->webviews.find(key);
                                        origin = source_webview == host->webviews.end()
                                            ? originForUrl(source_url)
                                            : bridgeOriginForWebViewUrl(source_webview->second, source_url);
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

                        found->second.webview->AddWebResourceRequestedFilter(L"https://native-sdk-app.localhost/*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
                        EventRegistrationToken asset_token = {};
                        found->second.webview->add_WebResourceRequested(Callback<ICoreWebView2WebResourceRequestedEventHandler>(
                            [host, key, environment_ref, lifetime](ICoreWebView2 *, ICoreWebView2WebResourceRequestedEventArgs *args) -> HRESULT {
                                auto token = lifetime.lock();
                                if (!token) return S_OK;
                                std::lock_guard<std::recursive_mutex> guard(token->mutex);
                                if (!token->alive || !args) return S_OK;
                                auto found = host->webviews.find(key);
                                if (found == host->webviews.end()) return S_OK;
                                ComPtr<ICoreWebView2WebResourceRequest> request;
                                if (FAILED(args->get_Request(&request)) || !request) return S_OK;
                                LPWSTR uri_bytes = nullptr;
                                if (FAILED(request->get_Uri(&uri_bytes)) || !uri_bytes) return S_OK;
                                std::wstring uri_wide(uri_bytes);
                                CoTaskMemFree(uri_bytes);
                                std::string uri = narrow(uri_wide);
                                if (!isInternalAssetUrl(found->second, uri)) return S_OK;
                                ComPtr<ICoreWebView2WebResourceResponse> response = assetWebResourceResponse(environment_ref.Get(), found->second, uri);
                                if (response) args->put_Response(response.Get());
                                return S_OK;
                            }).Get(), &asset_token);

                        EventRegistrationToken token = {};
                        found->second.webview->add_NavigationStarting(Callback<ICoreWebView2NavigationStartingEventHandler>(
                            [host, key, lifetime](ICoreWebView2 *, ICoreWebView2NavigationStartingEventArgs *args) -> HRESULT {
                                auto token = lifetime.lock();
                                if (!token) return S_OK;
                                std::lock_guard<std::recursive_mutex> guard(token->mutex);
                                if (!token->alive) return S_OK;
                                LPWSTR uri_bytes = nullptr;
                                if (!args || FAILED(args->get_Uri(&uri_bytes))) return S_OK;
                                std::wstring uri_wide = uri_bytes ? std::wstring(uri_bytes) : std::wstring();
                                if (uri_bytes) CoTaskMemFree(uri_bytes);
                                std::string uri = narrow(uri_wide);
                                auto found = host->webviews.find(key);
                                if (found != host->webviews.end() && isInternalAssetUrl(found->second, uri)) return S_OK;
                                if (uri.empty() || uri.rfind("about:", 0) == 0 || policyListMatches(host->allowed_origins, uri)) return S_OK;
                                if (host->external_link_action == 1 && policyListMatches(host->allowed_external_urls, uri)) {
                                    ShellExecuteW(nullptr, L"open", uri_wide.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
                                }
                                args->put_Cancel(TRUE);
                                return S_OK;
                            }).Get(), &token);
                        loadWebViewSource(found->second);
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

/* The user's app color preference: AppsUseLightTheme == 0 means dark.
 * Read through advapi32 dynamically (the credential store does the same)
 * so no extra import library is needed; a missing value (very old
 * builds) reads as light. */
static bool windowsAppsUseDarkTheme() {
    HMODULE advapi = LoadLibraryW(L"advapi32.dll");
    if (!advapi) return false;
    using RegGetValueWFn = LSTATUS(WINAPI *)(HKEY, LPCWSTR, LPCWSTR, DWORD, LPDWORD, PVOID, LPDWORD);
    auto reg_get_value = reinterpret_cast<RegGetValueWFn>(
        reinterpret_cast<void *>(GetProcAddress(advapi, "RegGetValueW")));
    bool dark = false;
    if (reg_get_value) {
        DWORD value = 1;
        DWORD size = sizeof(value);
        if (reg_get_value(HKEY_CURRENT_USER,
                          L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                          L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &value, &size) == ERROR_SUCCESS) {
            dark = value == 0;
        }
    }
    FreeLibrary(advapi);
    return dark;
}

/* Appearance from OS settings: the apps dark preference, disabled
 * client-area animations as the reduce-motion signal, and the high
 * contrast accessibility flag. Emitted once after START and again
 * whenever a settings broadcast changes any of the three values. */
static void emitAppearanceIfChanged(Host *host, bool force) {
    if (!host || !host->callback) return;
    const int dark = windowsAppsUseDarkTheme() ? 1 : 0;
    BOOL animations = TRUE;
    SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &animations, 0);
    const int reduce_motion = animations ? 0 : 1;
    HIGHCONTRASTW contrast = {};
    contrast.cbSize = sizeof(contrast);
    int high_contrast = 0;
    if (SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast, 0)) {
        high_contrast = (contrast.dwFlags & HCF_HIGHCONTRASTON) != 0 ? 1 : 0;
    }
    if (!force && dark == host->appearance_color_scheme && reduce_motion == host->appearance_reduce_motion && high_contrast == host->appearance_high_contrast) return;
    host->appearance_color_scheme = dark;
    host->appearance_reduce_motion = reduce_motion;
    host->appearance_high_contrast = high_contrast;
    WindowsEvent event = {};
    event.kind = kAppearance;
    event.color_scheme = dark;
    event.reduce_motion = reduce_motion;
    event.high_contrast = high_contrast;
    host->callback(host->callback_context, &event);
}

/* WM_TIMER for an id in the app-timer range: emit kTimer for the slot's
 * app timer id. A non-repeating timer frees its slot BEFORE emitting so
 * the handler may re-arm the same id (same contract as the AppKit and
 * GTK hosts). */
static bool handleAppTimerMessage(Host *host, WPARAM wparam) {
    if (!host || wparam < kAppTimerIdBase || wparam >= kAppTimerIdBase + kMaxAppTimers) return false;
    AppTimer &slot = host->app_timers[wparam - kAppTimerIdBase];
    if (!slot.in_use) return true;
    const uint64_t timer_id = slot.id;
    if (!slot.repeats) {
        if (slot.hwnd) KillTimer(slot.hwnd, wparam);
        slot.in_use = false;
        slot.hwnd = nullptr;
    }
    if (host->callback) {
        WindowsEvent event = {};
        event.kind = kTimer;
        event.timer_id = timer_id;
        event.timestamp_ns = gpuTimestampNs();
        host->callback(host->callback_context, &event);
    }
    return true;
}

static LRESULT CALLBACK windowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_NCCREATE) {
        auto *create = reinterpret_cast<CREATESTRUCTW *>(lparam);
        auto *host = reinterpret_cast<Host *>(create->lpCreateParams);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(host));
    }
    Host *host = hostFromWindow(hwnd);
    /* Hidden-titlebar (custom frame) windows first: DwmDefWindowProc
     * gets FIRST CLAIM on every message — it owns the DWM-drawn caption
     * buttons over the extended frame (hit-test, hover wash, press), and
     * the HTMAXBUTTON it answers is what makes Windows 11 pop snap
     * layouts on maximize-hover. Only when it declines does the message
     * reach the handlers below. */
    Window *chrome_window = hiddenTitlebarWindowForHwnd(host, hwnd);
    if (chrome_window) {
        const DwmApi &dwm = dwmApi();
        LRESULT dwm_result = 0;
        if (dwm.def_window_proc && dwm.def_window_proc(hwnd, message, wparam, lparam, &dwm_result)) return dwm_result;
        switch (message) {
            case WM_NCCALCSIZE:
                if (wparam) {
                    /* Reclaim ONLY the caption band: let DefWindowProc
                     * lay out the standard non-client frame, then pull
                     * the client's top edge back up so the caption band
                     * belongs to the app while the left/right/bottom
                     * resize borders keep their exact system metrics.
                     *
                     * The maximize pitfall: a maximized window's outer
                     * rect extends one frame thickness PAST the monitor
                     * on every side (the borders park offscreen). A
                     * client top restored to the outer top would put the
                     * first rows of content offscreen — clipped header,
                     * unreachable buttons — so when maximized the top is
                     * inset by the frame thickness at the window's CURRENT
                     * dpi (per-monitor correct on mixed-dpi setups). An
                     * attached menu bar keeps its strip: it lives in the
                     * band DefWindowProc reserved below the caption. */
                    NCCALCSIZE_PARAMS *params = reinterpret_cast<NCCALCSIZE_PARAMS *>(lparam);
                    const LONG original_top = params->rgrc[0].top;
                    const LRESULT def_result = DefWindowProcW(hwnd, WM_NCCALCSIZE, wparam, lparam);
                    if (def_result != 0) return def_result;
                    LONG top = original_top;
                    if (IsZoomed(hwnd)) top += hiddenFrameTopThickness(hwnd);
                    if (GetMenu(hwnd)) top += systemMetricForDpi(SM_CYMENU, dpiForWindow(hwnd));
                    params->rgrc[0].top = top;
                    return 0;
                }
                break;
            case WM_NCHITTEST: {
                /* DwmDefWindowProc above already claimed the caption
                 * buttons when the DWM draws them. DefWindowProc still
                 * owns the three REAL borders kept in WM_NCCALCSIZE
                 * (left/right/bottom and their corners) — trust any
                 * non-client answer it gives. */
                const LRESULT def_hit = DefWindowProcW(hwnd, WM_NCHITTEST, wparam, lparam);
                if (def_hit != HTCLIENT) return def_hit;
                POINT point = { (int)(short)LOWORD(lparam), (int)(short)HIWORD(lparam) };
                ScreenToClient(hwnd, &point);
                RECT client = {};
                GetClientRect(hwnd, &client);
                /* Top resize band: the caption removal moved the top
                 * frame INSIDE the client area, so hand its band back to
                 * the system — restored and resizable windows only (a
                 * maximized window does not resize, a fixed one never
                 * does). Corner slivers widen to the side borders so the
                 * diagonal grips survive at the very top. */
                if (chrome_window->resizable && !IsZoomed(hwnd) && point.y >= 0 && point.y < hiddenFrameTopThickness(hwnd)) {
                    const UINT dpi = dpiForWindow(hwnd);
                    const int corner = systemMetricForDpi(SM_CXSIZEFRAME, dpi) + systemMetricForDpi(SM_CXPADDEDBORDER, dpi);
                    if (point.x < corner) return HTTOPLEFT;
                    if (point.x >= client.right - corner) return HTTOPRIGHT;
                    return HTTOP;
                }
                /* Caption buttons when DwmDefWindowProc stayed silent
                 * (composition off, older cores): DefWindowProc still
                 * performs minimize/maximize/close for these hit codes,
                 * so the cluster keeps working even without DWM visuals.
                 * The cluster rect comes from the same DefWindowProc
                 * layout the DWM draws from, split left-to-right into
                 * min | max | close. */
                RECT cluster = {};
                if (captionButtonsClientRect(hwnd, &cluster) && PtInRect(&cluster, point)) {
                    const LONG third = (cluster.right - cluster.left) / 3;
                    if (point.x < cluster.left + third) return HTMINBUTTON;
                    if (point.x < cluster.left + 2 * third) return HTMAXBUTTON;
                    return HTCLOSE;
                }
                /* The markup's window-drag regions ARE the caption:
                 * HTCAPTION buys the system move loop, double-click
                 * maximize toggle, and the right-click system menu with
                 * zero custom gesture code. */
                if (windowDragRegionHit(host, *chrome_window, point)) return HTCAPTION;
                return HTCLIENT;
            }
            case WM_ACTIVATE:
                /* Composition restarts (session reconnect, driver reset)
                 * drop frame extensions; the DWM custom-frame pattern
                 * re-extends on activation. Falls through to
                 * DefWindowProc below. */
                applyHiddenTitlebarFrame(*chrome_window);
                break;
            default:
                break;
        }
    }
    /* Chromeless windows (WS_POPUP, no caption): DefWindowProc owns the
     * resize frame when one exists; the app's window-drag regions are
     * the only caption there is, so a client-area hit inside one
     * answers HTCAPTION — the system move loop and the right-click
     * system menu for free, exactly like the hidden-titlebar shape. */
    if (message == WM_NCHITTEST) {
        Window *chromeless_window = chromelessWindowForHwnd(host, hwnd);
        if (chromeless_window) {
            const LRESULT def_hit = DefWindowProcW(hwnd, WM_NCHITTEST, wparam, lparam);
            if (def_hit != HTCLIENT) return def_hit;
            POINT point = { (int)(short)LOWORD(lparam), (int)(short)HIWORD(lparam) };
            ScreenToClient(hwnd, &point);
            if (windowDragRegionHit(host, *chromeless_window, point)) return HTCAPTION;
            return HTCLIENT;
        }
    }
    switch (message) {
        case kWakeMessage:
            if (host) {
                WindowsEvent wake = {};
                wake.kind = kWake;
                wake.window_id = 1;
                if (host->callback) host->callback(host->callback_context, &wake);
            }
            return 0;
        case kRequestFrameMessage:
            if (host) {
                WindowsEvent frame = {};
                frame.kind = kFrame;
                frame.window_id = 1;
                if (host->callback) host->callback(host->callback_context, &frame);
            }
            return 0;
        case kAudioSessionMessage:
            if (host) audioHandleSessionMessage(host, wparam, lparam);
            return 0;
        case kAudioSpectrumMessage:
            if (host) audioHandleSpectrumMessage(host, wparam);
            return 0;
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
                    if (entry.second.hwnd == hwnd) {
#if NATIVE_SDK_HAS_WEBVIEW2
                        auto main = host->webviews.find(webViewKey(entry.first, "main"));
                        if (main != host->webviews.end() && !main->second.frame_explicit) {
                            RECT rect = {};
                            GetClientRect(hwnd, &rect);
                            main->second.x = 0;
                            main->second.y = 0;
                            main->second.width = rect.right > rect.left ? (double)(rect.right - rect.left) : entry.second.width;
                            main->second.height = rect.bottom > rect.top ? (double)(rect.bottom - rect.top) : entry.second.height;
                            applyWebViewFrame(main->second);
                        }
#endif
                        emit(host, entry.second, kResize);
                    }
                }
                /* Restore from minimize returns full cadence without
                 * dropping a beat: a heartbeat-paced emission may be
                 * parked up to a second out on a child surface's
                 * one-shot timer. SetTimer with the same id REPLACES the
                 * pending timer, so re-arming at the frame-grid delay
                 * (the last emit is at least a heartbeat old, so that
                 * delay computes to zero) is a clean supersede. */
                if (wparam != SIZE_MINIMIZED) {
                    for (auto &view_entry : host->native_views) {
                        NativeView &surface = view_entry.second;
                        if (surface.kind != kViewGpuSurface || !surface.hwnd || !surface.gpu_emission_scheduled) continue;
                        if (GetAncestor(surface.hwnd, GA_ROOT) != hwnd) continue;
                        surface.gpu_emission_scheduled = false;
                        gpuSurfaceScheduleFrameEmission(surface);
                    }
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
        case WM_DPICHANGED:
            /* The window moved to a monitor with a different DPI (or the
             * user changed display scaling). Adopt the system-suggested
             * frame — it keeps the window the same LOGICAL size on the
             * new scale — then re-derive everything DPI-dependent: the
             * hidden-titlebar band (its caption metrics scale with the
             * monitor), each native child's physical frame, every gpu
             * surface's logical-size/scale pairing so the runtime
             * re-rasterizes at the new density, and each explicit child
             * webview's physical frame. The SetWindowPos WM_SIZE
             * re-emits kResize, which now carries the new scale. Only
             * per-monitor-DPI-aware processes receive this message. */
            if (host) {
                const RECT *suggested = reinterpret_cast<const RECT *>(lparam);
                if (suggested) {
                    SetWindowPos(hwnd, nullptr, suggested->left, suggested->top, suggested->right - suggested->left, suggested->bottom - suggested->top, SWP_NOZORDER | SWP_NOACTIVATE);
                }
                for (auto &entry : host->windows) {
                    if (entry.second.hwnd == hwnd && windowUsesHiddenTitlebar(entry.second)) applyHiddenTitlebarFrame(entry.second);
                }
                for (auto &view_entry : host->native_views) {
                    NativeView &view = view_entry.second;
                    if (!view.hwnd || GetAncestor(view.hwnd, GA_ROOT) != hwnd) continue;
                    applyNativeViewFrame(host, view);
                    if (view.kind != kViewGpuSurface) continue;
                    const double surface_scale = gpuSurfaceScale(view.hwnd);
                    double width = 0;
                    double height = 0;
                    if (gpuSurfaceLogicalSize(view, view.hwnd, surface_scale, &width, &height)) {
                        (void)syncGpuSurfaceGeometry(host, view, width, height, surface_scale);
                    }
                }
#if NATIVE_SDK_HAS_WEBVIEW2
                for (auto &webview_entry : host->webviews) {
                    ChildWebView &webview = webview_entry.second;
                    /* Explicit frames are LOGICAL points scaled to
                     * physical pixels at apply time, so a monitor-scale
                     * change strands them until re-applied here. The
                     * auto-fill main webview stores PHYSICAL client-rect
                     * pixels and already re-derived them in the WM_SIZE
                     * that the SetWindowPos above dispatched, so it is
                     * skipped. */
                    if (!webview.frame_explicit) continue;
                    if (!webview.hwnd || GetAncestor(webview.hwnd, GA_ROOT) != hwnd) continue;
                    applyWebViewFrame(webview);
                }
#endif
                return 0;
            }
            break;
        case WM_TIMER:
            if (host && handleAppTimerMessage(host, wparam)) return 0;
            if (host && handleAudioTimerMessage(host, wparam)) return 0;
            if (host && wparam == kFrameTimerId) {
                for (auto &entry : host->windows) emit(host, entry.second, kFrame);
            }
            return 0;
        case WM_GETMINMAXINFO:
            if (host) {
                for (auto &entry : host->windows) {
                    Window &window = entry.second;
                    if (window.hwnd != hwnd) continue;
                    if (window.min_width <= 0 && window.min_height <= 0) break;
                    /* The declared floor is a CONTENT size in LOGICAL
                     * points; scale to physical pixels at this window's
                     * DPI, then convert to the outer track size for its
                     * current style. Hidden titlebar styles carry no top
                     * chrome (the custom WM_NCCALCSIZE hands the caption
                     * band to the client), so their conversion skips it
                     * too. */
                    const UINT dpi = dpiForWindow(hwnd);
                    const double scale = (double)dpi / 96.0;
                    const double min_content_width = window.min_width > 0 ? window.min_width * scale : 0;
                    const double min_content_height = window.min_height > 0 ? window.min_height * scale : 0;
                    RECT frame = { 0, 0, physicalContentExtent(min_content_width), physicalContentExtent(min_content_height) };
                    const DWORD style = (DWORD)GetWindowLongPtrW(hwnd, GWL_STYLE);
                    const DWORD ex_style = (DWORD)GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
                    const bool has_menu = GetMenu(hwnd) != nullptr;
                    adjustWindowRectForDpi(&frame, style, has_menu, ex_style, dpi);
                    LONG outer_width = frame.right - frame.left;
                    LONG outer_height = frame.bottom - frame.top;
                    if (windowUsesHiddenTitlebar(window)) {
                        const SIZE outer = hiddenOuterSizeForContent(style, ex_style, has_menu, min_content_width, min_content_height, dpi);
                        outer_width = outer.cx;
                        outer_height = outer.cy;
                    }
                    MINMAXINFO *info = reinterpret_cast<MINMAXINFO *>(lparam);
                    if (window.min_width > 0) info->ptMinTrackSize.x = outer_width;
                    if (window.min_height > 0) info->ptMinTrackSize.y = outer_height;
                    return 0;
                }
            }
            break;
        case WM_SETTINGCHANGE:
        case WM_THEMECHANGED:
        case WM_SYSCOLORCHANGE:
            if (host) emitAppearanceIfChanged(host, false);
            break;
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
    wc.lpszClassName = L"NativeSdkWindowsHost";
    return RegisterClassExW(&wc);
}

static bool createNativeWindow(Host *host, Window &window) {
    registerClass(host);
    std::wstring title = widen(window.title.empty() ? host->window_title : window.title);
    /* ALL titlebar styles keep the full overlapped frame. The hidden
     * styles do NOT drop to WS_POPUP: real Windows apps with custom
     * titlebars keep the system frame and the DWM caption buttons and
     * extend their own drawing into the caption band — the band itself
     * is reclaimed in WM_NCCALCSIZE, everything else stays standard. */
    DWORD style = WS_OVERLAPPEDWINDOW;
    if (!window.resizable) style &= ~(WS_THICKFRAME | WS_MAXIMIZEBOX);
    if (windowIsChromeless(window)) {
        /* Chromeless: the caption-less popup shape — no caption band,
         * no DWM caption buttons, nothing drawn. WS_SYSMENU and
         * WS_MINIMIZEBOX keep the REAL window verbs alive (taskbar
         * right-click, the host's close/minimize entrypoints) without
         * drawing anything; the resize frame stays when the window is
         * resizable. */
        style = WS_POPUP | WS_SYSMENU | WS_MINIMIZEBOX;
        if (window.resizable) style |= WS_THICKFRAME | WS_MAXIMIZEBOX;
    }
    /* The requested frame is a CONTENT size in LOGICAL points (the
     * other hosts size the content area); scale it to physical pixels
     * at the DPI the window opens at (the system DPI — WM_DPICHANGED
     * re-derives the frame if it lands on another monitor), then grow
     * it to the outer size for this style so the client rect lands at
     * the request. The menu bar is attached after creation, so account
     * for it here when menus are declared. Hidden styles use the
     * custom-calc shape (no top chrome) — plain adjustment would land
     * their client one caption band tall. */
    const bool has_menu = !host->menus.empty();
    const UINT dpi = systemDpi();
    const double scale = (double)dpi / 96.0;
    const double content_width = window.width * scale;
    const double content_height = window.height * scale;
    RECT frame = { 0, 0, physicalContentExtent(content_width), physicalContentExtent(content_height) };
    adjustWindowRectForDpi(&frame, style, has_menu ? TRUE : FALSE, 0, dpi);
    LONG outer_width = frame.right - frame.left;
    LONG outer_height = frame.bottom - frame.top;
    if (windowUsesHiddenTitlebar(window)) {
        const SIZE outer = hiddenOuterSizeForContent(style, 0, has_menu, content_width, content_height, dpi);
        outer_width = outer.cx;
        outer_height = outer.cy;
    }
    HWND hwnd = CreateWindowExW(
        0,
        L"NativeSdkWindowsHost",
        title.c_str(),
        style,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        outer_width,
        outer_height,
        nullptr,
        nullptr,
        host->instance,
        host);
    if (!hwnd) return false;
    DragAcceptFiles(hwnd, TRUE);
    window.hwnd = hwnd;
    applyMenusToWindow(host, window);
    if (windowUsesHiddenTitlebar(window)) {
        applyHiddenTitlebarFrame(window);
        /* The create-time WM_NCCALCSIZE ran before this window was
         * registered under its HWND, so the custom calc did not apply;
         * force one now that the map entry resolves. The callers keep
         * `window` referencing the stored map entry for exactly this. */
        SetWindowPos(hwnd, nullptr, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    }
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    SetTimer(hwnd, kFrameTimerId, 16, nullptr);
    return true;
}

} // namespace

extern "C" {

void native_sdk_windows_load_window_webview(Host *host, uint64_t window_id, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback);
void native_sdk_windows_bridge_respond_window(Host *host, uint64_t window_id, const char *response, size_t response_len);
void native_sdk_windows_bridge_respond_webview(Host *host, uint64_t window_id, const char *webview_label, size_t webview_label_len, const char *response, size_t response_len);
size_t native_sdk_windows_clipboard_read_data(Host *host, const char *mime_type, size_t mime_type_len, char *buffer, size_t buffer_len);
int native_sdk_windows_clipboard_write_data(Host *host, const char *mime_type, size_t mime_type_len, const char *bytes, size_t bytes_len);
void native_sdk_windows_cancel_timer(Host *host, uint64_t timer_id);

Host *native_sdk_windows_create(const char *app_name, size_t app_name_len, const char *window_title, size_t window_title_len, const char *bundle_id, size_t bundle_id_len, const char *icon_path, size_t icon_path_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame, int resizable, int titlebar_style, double min_width, double min_height) {
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
    window.resizable = resizable != 0;
    window.titlebar_style = titlebar_style;
    window.min_width = min_width;
    window.min_height = min_height;
    host->windows[window.id] = window;
    return host;
}

void native_sdk_windows_destroy(Host *host) {
    if (!host) return;
    std::shared_ptr<HostLifetime> lifetime = host->lifetime;
    std::lock_guard<std::recursive_mutex> guard(lifetime->mutex);
    lifetime->alive = false;
    /* DestroyWindow below dispatches WM_DESTROY/WM_ACTIVATEAPP
     * synchronously through windowProc; the run loop's handler state is
     * already gone by the time destroy is called, so those teardown
     * messages must not emit. */
    host->callback = nullptr;
    host->bridge_callback = nullptr;
    for (size_t index = 0; index < kMaxAppTimers; ++index) {
        AppTimer &slot = host->app_timers[index];
        if (slot.in_use && slot.hwnd) KillTimer(slot.hwnd, kAppTimerIdBase + index);
        slot.in_use = false;
        slot.hwnd = nullptr;
    }
    /* Retire the audio pipeline: the session closes asynchronously on
     * Media Foundation worker threads (the event pump owns the refs),
     * so nothing here blocks. The cache download is cancelled. */
    audioReleaseSession(host, true);
    removeNotificationIcon(host);
    destroyAllWindows(host);
    delete host;
}

void native_sdk_windows_run(Host *host, EventCallback callback, void *context) {
    if (!host) return;
    host->callback = callback;
    host->callback_context = context;
    host->running = true;
    if (!host->windows.empty()) createNativeWindow(host, host->windows.begin()->second);
    WindowsEvent start = {};
    start.kind = kStart;
    start.window_id = 1;
    callback(context, &start);
    emitAppearanceIfChanged(host, true);
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

void native_sdk_windows_stop(Host *host) {
    if (!host) return;
    host->running = false;
    PostQuitMessage(0);
}

/* Thread-safe wake: posts kWakeMessage into the message loop, which
 * emits the kWake event on the loop thread. The lifetime mutex guards
 * the window map against concurrent create/destroy. */
void native_sdk_windows_wake(Host *host) {
    if (!host) return;
    std::shared_ptr<HostLifetime> lifetime = host->lifetime;
    std::lock_guard<std::recursive_mutex> guard(lifetime->mutex);
    if (!lifetime->alive || !host->running) return;
    HWND hwnd = parentWindow(host);
    if (!hwnd) return;
    PostMessageW(hwnd, kWakeMessage, 0, 0);
}

/* Thread-safe frame request: posts kRequestFrameMessage into the message
 * loop, which emits one kFrame event on the loop thread — the automation
 * arrival watcher's wake, guarded exactly like native_sdk_windows_wake. */
void native_sdk_windows_request_frame(Host *host) {
    if (!host) return;
    std::shared_ptr<HostLifetime> lifetime = host->lifetime;
    std::lock_guard<std::recursive_mutex> guard(lifetime->mutex);
    if (!lifetime->alive || !host->running) return;
    HWND hwnd = parentWindow(host);
    if (!hwnd) return;
    PostMessageW(hwnd, kRequestFrameMessage, 0, 0);
}

/* Platform image decoder: WIC (Windows Imaging Component) handles PNG,
 * JPEG, and every other codec the OS ships — the framework bundles none.
 * Everything goes through the COM factory (format conversion included),
 * so no windowscodecs import library is needed; the CLSID/IID/pixel
 * format GUIDs are defined locally to avoid a uuid.lib dependency.
 * GUID_WICPixelFormat32bppRGBA is straight (non-premultiplied) alpha,
 * the layout the canvas image pipeline expects. */
static const GUID kNativeSdkCLSID_WICImagingFactory = {0xcacaf262, 0x9370, 0x4615, {0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a}};
static const GUID kNativeSdkIID_IWICImagingFactory = {0xec5ec8a9, 0xc395, 0x4314, {0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70}};
static const GUID kNativeSdkGUID_WICPixelFormat32bppRGBA = {0xf5c7ad2d, 0x6a8d, 0x43dd, {0xa7, 0xa8, 0xa2, 0x99, 0x35, 0x26, 0x1a, 0xe9}};

int native_sdk_windows_decode_image(const uint8_t *bytes, size_t bytes_len, uint8_t *pixels, size_t pixels_len, size_t *out_width, size_t *out_height) {
    if (out_width) *out_width = 0;
    if (out_height) *out_height = 0;
    if (!bytes || bytes_len == 0 || !pixels || bytes_len > UINT32_MAX) return 0;

    HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    bool uninitialize = SUCCEEDED(init); // S_FALSE still pairs with CoUninitialize.
    int result = 0;

    IWICImagingFactory *factory = nullptr;
    IWICStream *stream = nullptr;
    IWICBitmapDecoder *decoder = nullptr;
    IWICBitmapFrameDecode *frame = nullptr;
    IWICFormatConverter *converter = nullptr;
    do {
        if (FAILED(CoCreateInstance(kNativeSdkCLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, kNativeSdkIID_IWICImagingFactory, reinterpret_cast<void **>(&factory)))) break;
        if (FAILED(factory->CreateStream(&stream))) break;
        if (FAILED(stream->InitializeFromMemory(const_cast<BYTE *>(bytes), static_cast<DWORD>(bytes_len)))) break;
        if (FAILED(factory->CreateDecoderFromStream(stream, nullptr, WICDecodeMetadataCacheOnDemand, &decoder))) break;
        if (FAILED(decoder->GetFrame(0, &frame))) break;

        UINT frame_width = 0;
        UINT frame_height = 0;
        if (FAILED(frame->GetSize(&frame_width, &frame_height))) break;
        if (frame_width == 0 || frame_height == 0 || frame_width > 8192 || frame_height > 8192) break;
        size_t width = frame_width;
        size_t height = frame_height;
        if (out_width) *out_width = width;
        if (out_height) *out_height = height;
        size_t byte_len = width * height * 4;
        if (pixels_len < byte_len) {
            result = -1;
            break;
        }

        if (FAILED(factory->CreateFormatConverter(&converter))) break;
        if (FAILED(converter->Initialize(frame, kNativeSdkGUID_WICPixelFormat32bppRGBA, WICBitmapDitherTypeNone, nullptr, 0.0, WICBitmapPaletteTypeCustom))) break;
        if (FAILED(converter->CopyPixels(nullptr, static_cast<UINT>(width * 4), static_cast<UINT>(byte_len), pixels))) break;
        result = 1;
    } while (false);

    if (converter) converter->Release();
    if (frame) frame->Release();
    if (decoder) decoder->Release();
    if (stream) stream->Release();
    if (factory) factory->Release();
    if (uninitialize) CoUninitialize();
    return result;
}

void native_sdk_windows_load_webview(Host *host, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback) {
    native_sdk_windows_load_window_webview(host, 1, source, source_len, source_kind, asset_root, asset_root_len, asset_entry, asset_entry_len, asset_origin, asset_origin_len, spa_fallback);
}

void native_sdk_windows_load_window_webview(Host *host, uint64_t window_id, const char *source, size_t source_len, int source_kind, const char *asset_root, size_t asset_root_len, const char *asset_entry, size_t asset_entry_len, const char *asset_origin, size_t asset_origin_len, int spa_fallback) {
#if !NATIVE_SDK_HAS_WEBVIEW2
    (void)spa_fallback;
    (void)source;
    (void)source_len;
    (void)source_kind;
    (void)asset_root;
    (void)asset_root_len;
    (void)asset_entry;
    (void)asset_entry_len;
    (void)asset_origin;
    (void)asset_origin_len;
    if (!host) return;
    auto found = host->windows.find(window_id);
    if (found != host->windows.end()) emit(host, found->second, kWindowFrame);
#else
    if (!host) return;
    auto window = host->windows.find(window_id);
    if (window == host->windows.end() || !window->second.hwnd) return;

    std::string key = webViewKey(window_id, "main");
    auto found = host->webviews.find(key);
    if (found == host->webviews.end()) {
        RECT rect = {};
        GetClientRect(window->second.hwnd, &rect);
        HWND hwnd = CreateWindowExW(
            0,
            L"STATIC",
            L"",
            WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
            0,
            0,
            rect.right > rect.left ? rect.right - rect.left : webViewExtent(window->second.width),
            rect.bottom > rect.top ? rect.bottom - rect.top : webViewExtent(window->second.height),
            window->second.hwnd,
            nullptr,
            host->instance,
            nullptr);
        if (!hwnd) return;

        ChildWebView webview;
        webview.window_id = window_id;
        webview.hwnd = hwnd;
        webview.label = "main";
        webview.width = rect.right > rect.left ? (double)(rect.right - rect.left) : window->second.width;
        webview.height = rect.bottom > rect.top ? (double)(rect.bottom - rect.top) : window->second.height;
        webview.layer = 0;
        webview.creation_order = 0;
        webview.bridge_enabled = true;
        webview.frame_explicit = false;
        webview.source_kind = source_kind;
        webview.source = slice(source, source_len);
        webview.url = source_kind == 1 ? webview.source : std::string();
        webview.asset_root = slice(asset_root, asset_root_len);
        webview.asset_entry = slice(asset_entry, asset_entry_len);
        webview.asset_origin = slice(asset_origin, asset_origin_len);
        webview.spa_fallback = spa_fallback != 0;
        host->webviews[key] = webview;
        found = host->webviews.find(key);
        if (!createChildWebView(host, key)) {
            DestroyWindow(hwnd);
            host->webviews.erase(key);
            return;
        }
    }

    ChildWebView &webview = found->second;
    webview.source_kind = source_kind;
    webview.source = slice(source, source_len);
    webview.url = source_kind == 1 ? webview.source : std::string();
    webview.asset_root = slice(asset_root, asset_root_len);
    webview.asset_entry = slice(asset_entry, asset_entry_len);
    webview.asset_origin = slice(asset_origin, asset_origin_len);
    webview.spa_fallback = spa_fallback != 0;
    loadWebViewSource(webview);
    emit(host, window->second, kWindowFrame);
#endif
}

void native_sdk_windows_set_bridge_callback(Host *host, BridgeCallback callback, void *context) {
    if (!host) return;
    host->bridge_callback = callback;
    host->bridge_context = context;
}

void native_sdk_windows_bridge_respond(Host *host, const char *response, size_t response_len) {
    native_sdk_windows_bridge_respond_window(host, 1, response, response_len);
}

void native_sdk_windows_bridge_respond_window(Host *host, uint64_t window_id, const char *response, size_t response_len) {
    native_sdk_windows_bridge_respond_webview(host, window_id, "main", 4, response, response_len);
}

void native_sdk_windows_bridge_respond_webview(Host *host, uint64_t window_id, const char *webview_label, size_t webview_label_len, const char *response, size_t response_len) {
#if NATIVE_SDK_HAS_WEBVIEW2
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

void native_sdk_windows_emit_window_event(Host *host, uint64_t window_id, const char *name, size_t name_len, const char *detail_json, size_t detail_json_len) {
#if NATIVE_SDK_HAS_WEBVIEW2
    if (!host) return;
    std::string event_name = slice(name, name_len);
    if (event_name.empty()) return;
    std::string detail = detail_json && detail_json_len > 0 ? slice(detail_json, detail_json_len) : std::string("null");
    std::string script = "(function(){var name=" + jsonStringLiteral(event_name) + ";var detail=" + detail + ";if(window.zero&&window.zero._emit){window.zero._emit(name,detail);return;}window.dispatchEvent(new CustomEvent('native-sdk:'+name,{detail:detail}));})();";
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

void native_sdk_windows_set_security_policy(Host *host, const char *allowed_origins, size_t allowed_origins_len, const char *external_urls, size_t external_urls_len, int external_action) {
    if (!host) return;
    host->allowed_origins = parseNewlineList(allowed_origins, allowed_origins_len);
    host->allowed_external_urls = parseNewlineList(external_urls, external_urls_len);
    host->external_link_action = external_action;
}

void native_sdk_windows_set_menus(Host *host, const char *const *menu_titles, const size_t *menu_title_lens, size_t menu_count, const uint32_t *item_menu_indices, const char *const *item_labels, const size_t *item_label_lens, const char *const *item_commands, const size_t *item_command_lens, const char *const *item_keys, const size_t *item_key_lens, const uint32_t *item_modifiers, const int *item_separators, const int *item_enabled, const int *item_checked, size_t item_count) {
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

void native_sdk_windows_set_shortcuts(Host *host, const char *const *ids, const size_t *id_lens, const char *const *keys, const size_t *key_lens, const uint32_t *modifiers, size_t count) {
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

int native_sdk_windows_create_window(Host *host, uint64_t window_id, const char *window_title, size_t window_title_len, const char *window_label, size_t window_label_len, double x, double y, double width, double height, int restore_frame, int resizable, int titlebar_style, double min_width, double min_height) {
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
    window.resizable = resizable != 0;
    window.titlebar_style = titlebar_style;
    window.min_width = min_width;
    window.min_height = min_height;
    /* Register BEFORE creating: createNativeWindow's post-create frame
     * pass (hidden titlebar styles) resolves the window through the map
     * by HWND, so the stored entry must be the one it mutates. */
    Window &stored = host->windows[window_id];
    stored = window;
    if (!createNativeWindow(host, stored)) {
        host->windows.erase(window_id);
        return 0;
    }
    return 1;
}

void native_sdk_windows_start_timer(Host *host, uint64_t timer_id, uint64_t interval_ns, int repeats) {
    if (!host) return;
    native_sdk_windows_cancel_timer(host, timer_id);
    HWND hwnd = parentWindow(host);
    if (!hwnd) return;
    AppTimer *slot = nullptr;
    UINT_PTR win32_id = 0;
    for (size_t index = 0; index < kMaxAppTimers; ++index) {
        if (!host->app_timers[index].in_use) {
            slot = &host->app_timers[index];
            win32_id = kAppTimerIdBase + index;
            break;
        }
    }
    if (!slot) return;
    UINT interval_ms = (UINT)(interval_ns / 1000000ull);
    if (interval_ms == 0) interval_ms = 1;
    slot->id = timer_id;
    slot->hwnd = hwnd;
    slot->repeats = repeats != 0;
    slot->in_use = true;
    SetTimer(hwnd, win32_id, interval_ms, nullptr);
}

void native_sdk_windows_cancel_timer(Host *host, uint64_t timer_id) {
    if (!host) return;
    for (size_t index = 0; index < kMaxAppTimers; ++index) {
        AppTimer &slot = host->app_timers[index];
        if (slot.in_use && slot.id == timer_id) {
            if (slot.hwnd) KillTimer(slot.hwnd, kAppTimerIdBase + index);
            slot.in_use = false;
            slot.hwnd = nullptr;
        }
    }
}

int native_sdk_windows_start_window_drag(Host *host, uint64_t window_id) {
    if (!host) return 0;
    auto found = host->windows.find(window_id);
    if (found == host->windows.end() || !found->second.hwnd) return 0;
    /* An interactive move needs a live pointer press on one of the
     * window's canvas views. Without one (synthetic automation input, or
     * a drag request outside any pointer gesture) succeed as a no-op —
     * only an unknown window is an error, matching the other hosts. */
    NativeView *pressed = nullptr;
    for (auto &entry : host->native_views) {
        NativeView &view = entry.second;
        if (view.window_id == window_id && view.kind == kViewGpuSurface && view.gpu_pointer_down) {
            pressed = &view;
            break;
        }
    }
    if (!pressed) return 1;
    /* Hand the press to the system move loop: release the canvas capture
     * (its WM_CAPTURECHANGED emits pointer_cancel, closing the gesture
     * for the runtime) and post the caption-drag that begins the move.
     * Posted, not sent: the move loop is modal and must not run inside
     * this call. */
    ReleaseCapture();
    PostMessageW(found->second.hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
    return 1;
}

/* Replace a canvas view's window-drag mirror (runtime push after layout
 * installs whose regions changed). Rects arrive flat as x,y,w,h in the
 * view's logical coordinates; exclusions mark the press-claiming
 * carve-outs. WM_NCHITTEST on hidden-titlebar windows consults the
 * mirror to answer HTCAPTION. */
int native_sdk_windows_set_window_drag_regions(Host *host, uint64_t window_id, const char *label, size_t label_len, const double *rects, const int *exclusions, size_t count) {
    if (!host || label_len == 0) return 0;
    auto found = host->native_views.find(nativeViewKey(window_id, slice(label, label_len)));
    if (found == host->native_views.end() || found->second.kind != kViewGpuSurface) return 0;
    found->second.drag_regions.clear();
    if (!rects || !exclusions) return 1;
    found->second.drag_regions.reserve(count);
    for (size_t index = 0; index < count; ++index) {
        DragRegionRect rect;
        rect.x = rects[index * 4 + 0];
        rect.y = rects[index * 4 + 1];
        rect.width = rects[index * 4 + 2];
        rect.height = rects[index * 4 + 3];
        rect.exclusion = exclusions[index] != 0;
        found->second.drag_regions.push_back(rect);
    }
    return 1;
}

/* Chrome overlay geometry for hidden-titlebar windows, logical points:
 * the caption-button band's depth on top, the min/max/close cluster's
 * extent from the trailing (right) edge, and the cluster's frame in
 * content coordinates. The live rects come from WM_GETTITLEBARINFOEX —
 * the same layout the DWM draws from — so maximize (the cluster shifts
 * inward with the parked borders) and per-monitor dpi report true
 * values on every poll; the runtime re-polls on resize events, which
 * maximize/restore transitions emit. Standard-titlebar windows and
 * minimized windows (whose rects describe the taskbar miniature, not
 * content) report all zero, like macOS reports zero in fullscreen. */
int native_sdk_windows_window_chrome(Host *host, uint64_t window_id, double *top, double *left, double *bottom, double *right, double *buttons_x, double *buttons_y, double *buttons_width, double *buttons_height) {
    *top = 0;
    *left = 0;
    *bottom = 0;
    *right = 0;
    *buttons_x = 0;
    *buttons_y = 0;
    *buttons_width = 0;
    *buttons_height = 0;
    if (!host) return 0;
    auto found = host->windows.find(window_id);
    if (found == host->windows.end() || !found->second.hwnd) return 0;
    Window &window = found->second;
    if (!windowUsesHiddenTitlebar(window) || IsIconic(window.hwnd)) return 1;
    const double scale = gpuSurfaceScale(window.hwnd);
    if (scale <= 0) return 1;
    RECT cluster = {};
    if (captionButtonsClientRect(window.hwnd, &cluster)) {
        RECT client = {};
        GetClientRect(window.hwnd, &client);
        *top = (double)cluster.bottom / scale;
        *right = (double)(client.right - cluster.left) / scale;
        *buttons_x = (double)cluster.left / scale;
        *buttons_y = (double)cluster.top / scale;
        *buttons_width = (double)(cluster.right - cluster.left) / scale;
        *buttons_height = (double)(cluster.bottom - cluster.top) / scale;
    } else {
        /* No live rects yet (pre-show poll): the band metric still
         * gives the header an honest height to layout against. */
        *top = (double)hiddenCaptionBandHeight(window.hwnd) / scale;
    }
    return 1;
}

int native_sdk_windows_focus_window(Host *host, uint64_t window_id) {
    if (!host) return 0;
    auto found = host->windows.find(window_id);
    if (found == host->windows.end() || !found->second.hwnd) return 0;
    SetForegroundWindow(found->second.hwnd);
    SetFocus(found->second.hwnd);
    return 1;
}

int native_sdk_windows_close_window(Host *host, uint64_t window_id) {
    if (!host) return 0;
    auto found = host->windows.find(window_id);
    if (found == host->windows.end() || !found->second.hwnd) return 0;
    destroyNativeViewsForWindow(host, window_id);
    destroyChildWebViewsForWindow(host, window_id);
    DestroyWindow(found->second.hwnd);
    return 1;
}

/* The real OS minimize verb, for app-drawn window controls (a chromeless
 * window has no caption buttons): the window animates to the taskbar
 * exactly like the system minimize button. */
int native_sdk_windows_minimize_window(Host *host, uint64_t window_id) {
    if (!host) return 0;
    auto found = host->windows.find(window_id);
    if (found == host->windows.end() || !found->second.hwnd) return 0;
    ShowWindow(found->second.hwnd, SW_MINIMIZE);
    return 1;
}

int native_sdk_windows_create_view(Host *host, uint64_t window_id, const char *label, size_t label_len, int kind, const char *parent, size_t parent_len, double x, double y, double width, double height, int layer, int visible, int enabled, const char *role, size_t role_len, const char *accessibility_label, size_t accessibility_label_len, const char *text, size_t text_len, const char *command, size_t command_len) {
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
        case kViewListItem:
            class_name = L"BUTTON";
            style |= BS_PUSHBUTTON | BS_LEFT | BS_VCENTER | WS_TABSTOP;
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
        case kViewGpuSurface:
            class_name = gpuSurfaceClassName(host);
            style |= WS_TABSTOP;
            wide_text.clear();
            break;
        default:
            return 0;
    }
    if (view.visible) style |= WS_VISIBLE;

    const double scale = nativeViewFrameScale(host, view);
    RECT frame = nativeViewPhysicalFrame(host, view, scale);
    HWND hwnd = CreateWindowExW(
        ex_style,
        class_name.c_str(),
        wide_text.c_str(),
        style,
        frame.left,
        frame.top,
        frame.right - frame.left,
        frame.bottom - frame.top,
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
    if (kind == kViewGpuSurface) {
        /* The class WndProc resolves the host through GWLP_USERDATA; set it
         * before the placeholder pump starts ticking so the first WM_TIMER
         * can already arm frame-event emissions (the pump retires itself
         * after the first present; see the frame-scheduler comments). */
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(host));
        SetTimer(hwnd, kGpuFrameTimerId, 16, nullptr);
        SetFocus(hwnd);
    }
    return 1;
}

int native_sdk_windows_request_gpu_surface_frame(Host *host, uint64_t window_id, const char *label, size_t label_len) {
    if (!host || label_len == 0) return 0;
    auto found = host->native_views.find(nativeViewKey(window_id, slice(label, label_len)));
    if (found == host->native_views.end() || found->second.kind != kViewGpuSurface || !found->second.hwnd) return 0;
    /* A runtime frame request is a producer on the surface's single
     * frame-event scheduler: repaint retained content and arm the next
     * grid-paced emission (folding into one already in flight). */
    InvalidateRect(found->second.hwnd, nullptr, FALSE);
    gpuSurfaceScheduleFrameEmission(found->second);
    return 1;
}

/* Input was dispatched to the surface (real or automation-synthesized —
 * automation input never passes through this host's window procedures):
 * the responding frame must not wait out the minimized heartbeat. The
 * one-shot flag covers the frame request arriving during the input
 * dispatch; a parked heartbeat timer is superseded by re-arming at the
 * grid delay (SetTimer with the same id replaces the pending timer). */
int native_sdk_windows_note_gpu_surface_input(Host *host, uint64_t window_id, const char *label, size_t label_len) {
    if (!host || label_len == 0) return 0;
    auto found = host->native_views.find(nativeViewKey(window_id, slice(label, label_len)));
    if (found == host->native_views.end() || found->second.kind != kViewGpuSurface || !found->second.hwnd) return 0;
    NativeView &view = found->second;
    view.gpu_prompt_frame_pending = true;
    if (view.gpu_emission_scheduled) {
        view.gpu_emission_scheduled = false;
        gpuSurfaceScheduleFrameEmission(view);
    }
    return 1;
}

int native_sdk_windows_present_gpu_surface_pixels(Host *host, uint64_t window_id, const char *label, size_t label_len, size_t width, size_t height, double scale, int has_dirty_rect, double dirty_x, double dirty_y, double dirty_width, double dirty_height, const uint8_t *rgba8, size_t rgba8_len) {
    (void)scale;
    (void)has_dirty_rect;
    (void)dirty_x;
    (void)dirty_y;
    (void)dirty_width;
    (void)dirty_height;
    if (!host || label_len == 0) return 0;
    auto found = host->native_views.find(nativeViewKey(window_id, slice(label, label_len)));
    if (found == host->native_views.end() || found->second.kind != kViewGpuSurface || !found->second.hwnd) return 0;
    if (!rgba8 || width == 0 || height == 0) return 0;
    if (width > INT_MAX || height > INT_MAX) return 0;
    if (rgba8_len != width * height * 4) return 0;
    NativeView &view = found->second;

    /* Straight RGBA8 -> top-down BGRA rows for a BI_RGB 32bpp DIB. The
     * surface is opaque (alpha_mode "opaque"), so no premultiply is
     * needed. The fourth byte is FORCED to 255, not copied: plain GDI
     * ignores it, but on hidden-titlebar windows the DWM frame extends
     * over the top band and composites its own caption material wherever
     * the redirection surface's alpha is 0 — the app's pixels must read
     * as opaque there or the whole header band would vanish under DWM
     * chrome (only the punched button hole yields on purpose). */
    view.gpu_bgra.resize(width * height * 4);
    uint8_t *dst = view.gpu_bgra.data();
    const size_t pixel_count = width * height;
    for (size_t index = 0; index < pixel_count; index++) {
        const uint8_t *src = rgba8 + index * 4;
        dst[index * 4 + 0] = src[2];
        dst[index * 4 + 1] = src[1];
        dst[index * 4 + 2] = src[0];
        dst[index * 4 + 3] = 255;
    }
    view.gpu_buf_width = (int)width;
    view.gpu_buf_height = (int)height;

    /* Hidden-titlebar windows: keep the DWM caption material behind the
     * button cluster matched to the header the app just presented. */
    auto owner = host->windows.find(view.window_id);
    if (owner != host->windows.end()) syncHiddenCaptionColor(host, owner->second, view, rgba8, width, height);

    const size_t sample_index = ((height / 2) * width + width / 2) * 4;
    const uint8_t sr = rgba8[sample_index + 0];
    const uint8_t sg = rgba8[sample_index + 1];
    const uint8_t sb = rgba8[sample_index + 2];
    const uint8_t sa = rgba8[sample_index + 3];
    if (sr != 0 || sg != 0 || sb != 0) {
        view.gpu_nonblank = 1;
        view.gpu_sample_color = ((uint32_t)sa << 24) | ((uint32_t)sr << 16) | ((uint32_t)sg << 8) | (uint32_t)sb;
    }

    InvalidateRect(view.hwnd, nullptr, FALSE);
    /* A present is the completion producer on the surface's single
     * frame-event scheduler: the completion event it arms is what
     * drives the runtime's frame loop (an armed animation presents,
     * this echo steps it again). The first present also retires the
     * placeholder pump — from here on frames exist only on demand. Its
     * emission carries the nonblank verdict and must not wait out the
     * minimized heartbeat (a window can launch minimized); steady-state
     * presents keep the heartbeat — they ARE the spin being throttled. */
    const bool first_present = !view.gpu_presented;
    view.gpu_presented = true;
    if (first_present) view.gpu_prompt_frame_pending = true;
    gpuSurfaceScheduleFrameEmission(view);
    return 1;
}

int native_sdk_windows_update_view(Host *host, uint64_t window_id, const char *label, size_t label_len, int has_frame, double x, double y, double width, double height, int has_layer, int layer, int has_visible, int visible, int has_enabled, int enabled, int has_role, const char *role, size_t role_len, int has_accessibility_label, const char *accessibility_label, size_t accessibility_label_len, int has_text, const char *text, size_t text_len, int has_command, const char *command, size_t command_len) {
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
    if (has_visible || has_enabled || has_role || has_accessibility_label || update_text) applyNativeViewState(view, update_text, display_text);
    if (has_layer) reorderWindowChildren(host, window_id);
    return 1;
}

int native_sdk_windows_set_view_frame(Host *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height) {
    return native_sdk_windows_update_view(host, window_id, label, label_len, 1, x, y, width, height, 0, 0, 0, 1, 0, 1, 0, "", 0, 0, "", 0, 0, "", 0, 0, "", 0);
}

int native_sdk_windows_set_view_visible(Host *host, uint64_t window_id, const char *label, size_t label_len, int visible) {
    return native_sdk_windows_update_view(host, window_id, label, label_len, 0, 0, 0, 0, 0, 0, 0, 1, visible, 0, 1, 0, "", 0, 0, "", 0, 0, "", 0, 0, "", 0);
}

int native_sdk_windows_focus_view(Host *host, uint64_t window_id, const char *label, size_t label_len) {
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

int native_sdk_windows_close_view(Host *host, uint64_t window_id, const char *label, size_t label_len) {
    if (!host || label_len == 0) return 0;
    std::string label_string = slice(label, label_len);
    std::string key = nativeViewKey(window_id, label_string);
    if (host->native_views.find(key) == host->native_views.end()) return 0;
    destroyNativeViewAndChildren(host, key);
    reorderWindowChildren(host, window_id);
    return 1;
}

WindowsOpenDialogResult native_sdk_windows_show_open_dialog(Host *host, const WindowsOpenDialogOpts *opts, char *buffer, size_t buffer_len) {
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
                    bool overflow = false;
                    PWSTR path = nullptr;
                    if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)) && path) {
                        overflow = !appendPathToBuffer(buffer, buffer_len, &offset, &written_count, std::wstring(path));
                        CoTaskMemFree(path);
                    }
                    item->Release();
                    if (overflow) break;
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

size_t native_sdk_windows_show_save_dialog(Host *host, const WindowsSaveDialogOpts *opts, char *buffer, size_t buffer_len) {
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
                if (utf8_path.size() > buffer_len) {
                    written = overflowSize(buffer_len);
                } else {
                    written = utf8_path.size();
                    if (written > 0) memcpy(buffer, utf8_path.data(), written);
                }
                CoTaskMemFree(path);
            }
            item->Release();
        }
    }

    dialog->Release();
    finishCom(uninitialize);
    return written;
}

int native_sdk_windows_show_message_dialog(Host *host, const WindowsMessageDialogOpts *opts) {
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
    config.pszWindowTitle = title.empty() ? L"native-sdk" : title.c_str();
    config.pszMainInstruction = message.empty() ? config.pszWindowTitle : message.c_str();
    config.pszContent = informative.empty() ? nullptr : informative.c_str();
    config.cButtons = static_cast<UINT>(button_count);
    config.pButtons = buttons;
    config.nDefaultButton = 100;
    config.pszMainIcon = opts->style == 2 ? TD_ERROR_ICON : (opts->style == 1 ? TD_WARNING_ICON : TD_INFORMATION_ICON);

    /* TaskDialogIndirect is a comctl32 v6 export: it only resolves when
     * the process activates the v6 side-by-side assembly (application
     * manifest). A static import would abort the whole process at load
     * time with STATUS_ENTRYPOINT_NOT_FOUND on the system default v5, so
     * resolve it dynamically and fall back to MessageBoxW (fixed button
     * captions, same 0/1/2 result contract) when only v5 is available. */
    using TaskDialogIndirectFn = HRESULT(WINAPI *)(const TASKDIALOGCONFIG *, int *, int *, BOOL *);
    static TaskDialogIndirectFn task_dialog = reinterpret_cast<TaskDialogIndirectFn>(
        reinterpret_cast<void *>(GetProcAddress(GetModuleHandleW(L"comctl32.dll"), "TaskDialogIndirect")));
    if (task_dialog) {
        int pressed = 100;
        HRESULT hr = task_dialog(&config, &pressed, nullptr, nullptr);
        if (FAILED(hr)) return 0;
        if (pressed == 101) return 1;
        if (pressed == 102) return 2;
        return 0;
    }

    UINT type = MB_OK;
    if (button_count == 2) type = MB_OKCANCEL;
    if (button_count == 3) type = MB_YESNOCANCEL;
    type |= opts->style == 2 ? MB_ICONERROR : (opts->style == 1 ? MB_ICONWARNING : MB_ICONINFORMATION);
    std::wstring text = message;
    if (!informative.empty()) {
        if (!text.empty()) text += L"\n\n";
        text += informative;
    }
    const int result = MessageBoxW(parentWindow(host), text.c_str(), title.empty() ? L"native-sdk" : title.c_str(), type);
    if (button_count == 3) {
        if (result == IDNO) return 1;
        if (result == IDCANCEL) return 2;
        return 0;
    }
    if (result == IDCANCEL) return 1;
    return 0;
}

int native_sdk_windows_show_notification(Host *host, const char *title, size_t title_len, const char *subtitle, size_t subtitle_len, const char *body, size_t body_len) {
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

int native_sdk_windows_create_tray(Host *host, const char *icon_path, size_t icon_path_len, const char *tooltip, size_t tooltip_len) {
    if (!host) return 0;
    std::string icon = slice(icon_path, icon_path_len);
    std::string tip = slice(tooltip, tooltip_len);
    if (!setNotificationIcon(host, icon, tip, true)) return 0;
    host->tray_active = true;
    return 1;
}

int native_sdk_windows_update_tray_menu(Host *host, const uint32_t *item_ids, const char *const *labels, const size_t *label_lens, const int *separators, const int *enabled_flags, size_t count) {
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

void native_sdk_windows_remove_tray(Host *host) {
    if (!host) return;
    host->tray_active = false;
    host->tray_items.clear();
    removeNotificationIcon(host);
}

int native_sdk_windows_open_external_url(Host *host, const char *url, size_t url_len) {
    (void)host;
    if (!url || url_len == 0) return 0;
    std::wstring target = widen(slice(url, url_len));
    HINSTANCE result = ShellExecuteW(nullptr, L"open", target.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    return reinterpret_cast<intptr_t>(result) > 32 ? 1 : 0;
}

int native_sdk_windows_reveal_path(Host *host, const char *path, size_t path_len) {
    (void)host;
    if (!path || path_len == 0) return 0;
    std::wstring target = widen(slice(path, path_len));
    std::wstring args = L"/select,\"" + target + L"\"";
    HINSTANCE result = ShellExecuteW(nullptr, L"open", L"explorer.exe", args.c_str(), nullptr, SW_SHOWNORMAL);
    return reinterpret_cast<intptr_t>(result) > 32 ? 1 : 0;
}

int native_sdk_windows_add_recent_document(Host *host, const char *path, size_t path_len) {
    (void)host;
    if (!path || path_len == 0) return 0;
    std::wstring target = widen(slice(path, path_len));
    SHAddToRecentDocs(SHARD_PATHW, target.c_str());
    return 1;
}

int native_sdk_windows_clear_recent_documents(Host *host) {
    (void)host;
    SHAddToRecentDocs(SHARD_PIDL, nullptr);
    return 1;
}

int native_sdk_windows_set_credential(Host *host, const char *service, size_t service_len, const char *account, size_t account_len, const char *secret, size_t secret_len) {
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

size_t native_sdk_windows_get_credential(Host *host, const char *service, size_t service_len, const char *account, size_t account_len, char *buffer, size_t buffer_len) {
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

int native_sdk_windows_delete_credential(Host *host, const char *service, size_t service_len, const char *account, size_t account_len) {
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

int native_sdk_windows_create_webview(Host *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len, double x, double y, double width, double height, int layer, int transparent, int bridge_enabled) {
#if !NATIVE_SDK_HAS_WEBVIEW2
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
    /* The requested frame is in logical points (frame_explicit child
     * webviews scale like native view frames); physical placement at
     * the owning window's DPI. */
    const double frame_scale = (double)dpiForWindow(window->second.hwnd) / 96.0;
    HWND hwnd = CreateWindowExW(
        0,
        L"STATIC",
        L"",
        WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
        webViewCoord(x * frame_scale),
        webViewCoord(y * frame_scale),
        webViewExtent(width * frame_scale),
        webViewExtent(height * frame_scale),
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
    inheritAssetSourceForUrl(host, window_id, webview, url_string);
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

int native_sdk_windows_set_webview_frame(Host *host, uint64_t window_id, const char *label, size_t label_len, double x, double y, double width, double height) {
    if (!host || label_len == 0 || !validChildWebViewFrame(x, y, width, height)) return 0;
    std::string label_string = slice(label, label_len);
    auto found = host->webviews.find(webViewKey(window_id, label_string));
    if (found == host->webviews.end() || !found->second.hwnd) return 0;
    found->second.x = x;
    found->second.y = y;
    found->second.width = width;
    found->second.height = height;
    found->second.frame_explicit = true;
    const double frame_scale = webViewFrameScale(found->second);
    MoveWindow(found->second.hwnd, webViewCoord(x * frame_scale), webViewCoord(y * frame_scale), webViewExtent(width * frame_scale), webViewExtent(height * frame_scale), TRUE);
#if NATIVE_SDK_HAS_WEBVIEW2
    if (found->second.controller) {
        RECT bounds = webViewRect(found->second);
        found->second.controller->put_Bounds(bounds);
    }
#endif
    return 1;
}

int native_sdk_windows_navigate_webview(Host *host, uint64_t window_id, const char *label, size_t label_len, const char *url, size_t url_len) {
#if !NATIVE_SDK_HAS_WEBVIEW2
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
    if (!inheritAssetSourceForUrl(host, window_id, found->second, found->second.url)) {
        found->second.source_kind = 1;
    }
    if (found->second.webview) {
        std::string target = found->second.source_kind == 2 ? assetEntryUrl(found->second) : found->second.url;
        if (target.empty()) target = "about:blank";
        std::wstring wide_target = widen(target);
        found->second.webview->Navigate(wide_target.c_str());
        return 1;
    }
    // WebView2 initializes asynchronously; keep the newest URL and apply it in the creation callback.
    return 1;
#endif
}

int native_sdk_windows_set_webview_zoom(Host *host, uint64_t window_id, const char *label, size_t label_len, double zoom) {
#if !NATIVE_SDK_HAS_WEBVIEW2
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

int native_sdk_windows_set_webview_layer(Host *host, uint64_t window_id, const char *label, size_t label_len, int layer) {
    if (!host || label_len == 0) return 0;
    std::string label_string = slice(label, label_len);
    /* The window WebView participates in the same layer channel as the
     * child views (it lives in the webviews map under "main" with layer 0
     * and creation order 0, so it stays bottom-most until an app sinks it
     * under — or floats it over — sibling views). */
    auto found = host->webviews.find(webViewKey(window_id, label_string));
    if (found == host->webviews.end() || !found->second.hwnd) return 0;
    found->second.layer = layer;
    applyChildWebViewLayer(host, window_id, label_string);
    return 1;
}

int native_sdk_windows_close_webview(Host *host, uint64_t window_id, const char *label, size_t label_len) {
    if (!host || label_len == 0) return 0;
    std::string label_string = slice(label, label_len);
    if (label_string == "main") return 0;
    auto found = host->webviews.find(webViewKey(window_id, label_string));
    if (found == host->webviews.end()) return 0;
#if NATIVE_SDK_HAS_WEBVIEW2
    if (found->second.controller) found->second.controller->Close();
#endif
    if (found->second.hwnd) DestroyWindow(found->second.hwnd);
    host->webviews.erase(found);
    return 1;
}

size_t native_sdk_windows_clipboard_read(Host *host, char *buffer, size_t buffer_len) {
    return native_sdk_windows_clipboard_read_data(host, "text/plain", strlen("text/plain"), buffer, buffer_len);
}

void native_sdk_windows_clipboard_write(Host *host, const char *text, size_t text_len) {
    (void)native_sdk_windows_clipboard_write_data(host, "text/plain", strlen("text/plain"), text, text_len);
}

size_t native_sdk_windows_clipboard_read_data(Host *host, const char *mime_type, size_t mime_type_len, char *buffer, size_t buffer_len) {
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

int native_sdk_windows_clipboard_write_data(Host *host, const char *mime_type, size_t mime_type_len, const char *bytes, size_t bytes_len) {
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

/* Audio entry points (see the audio section above). All loop-thread
 * only, like every other service call: the runtime dispatches them from
 * inside the message loop's event callback. */

int native_sdk_windows_audio_load(Host *host, const char *path, size_t path_len) {
    if (!host) return 2;
    return audioLoadPathInternal(host, slice(path, path_len));
}

int native_sdk_windows_audio_load_url(Host *host, const char *url, size_t url_len, const char *cache_path, size_t cache_path_len, uint64_t expected_bytes) {
    if (!host) return 2;
    return audioLoadUrlInternal(host, slice(url, url_len), slice(cache_path, cache_path_len), expected_bytes);
}

int native_sdk_windows_audio_play(Host *host) {
    if (!host || !host->audio.active) return 0;
    AudioState &audio = host->audio;
    audio.playing = true;
    if (audio.ready) {
        audioStartTransport(host, false, 0);
    } else {
        /* Applied at topology ready; readiness and stalls report
         * through the event stream, so play always "applies" — the
         * same asynchronous-by-nature contract as a macOS stream. */
        audio.pending_play = true;
    }
    audioStartPositionTimer(host);
    /* Spectrum capture follows the transport intent: it comes up here
     * (loopback packets begin once the session actually renders) and
     * retires at pause/stop/teardown. */
    audioSpectrumStartCapture(host);
    return 1;
}

int native_sdk_windows_audio_pause(Host *host) {
    if (!host || !host->audio.active) return 0;
    AudioState &audio = host->audio;
    audio.playing = false;
    audio.pending_play = false;
    if (audio.ready && audio.session) audio.session->Pause();
    audioStopPositionTimer(host);
    audioSpectrumStopCapture(host);
    return 1;
}

int native_sdk_windows_audio_stop(Host *host) {
    if (!host) return 0;
    const int had_player = host->audio.active ? 1 : 0;
    /* Replacement or explicit stop: the cache download dies with the
     * playback (its next play streams and fills again). */
    audioReleaseSession(host, true);
    return had_player;
}

int native_sdk_windows_audio_seek(Host *host, uint64_t position_ms) {
    if (!host || !host->audio.active) return 0;
    AudioState &audio = host->audio;
    if (audio.duration_ms > 0 && position_ms > audio.duration_ms) position_ms = audio.duration_ms;
    if (audio.ready) {
        audioStartTransport(host, true, position_ms);
    } else {
        audio.has_pending_seek = true;
        audio.pending_seek_ms = position_ms;
    }
    return 1;
}

int native_sdk_windows_audio_set_volume(Host *host, double volume) {
    if (!host || !host->audio.active) return 0;
    host->audio.volume = (float)volume;
    if (host->audio.ready) audioApplyVolume(host);
    return 1;
}

/* Whether process-scoped loopback capture — the spectrum analysis feed —
 * can be activated on this OS. Answered by the cached live probe (one
 * real activation attempt, see audioSpectrumSupported), never a version
 * sniff. */
int native_sdk_windows_audio_spectrum_supported(Host *host) {
    if (!host) return 0;
    return audioSpectrumSupported() ? 1 : 0;
}

}
