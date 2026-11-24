// native Windows host: a Win32 window and its message pump, pages painted through Direct2D with
// text shaped and drawn by DirectWrite, on a Direct3D 11 swap chain (WARP when there is no GPU).
// Offscreen runs need no window: a snapshot replays the display list into a bitmap of its own and
// writes it as a PNG, which is how the examples gate runs an app on a build machine.
//
// This file is the Windows counterpart of host/macos.m and host/linux.c and implements the same
// FFI manifest (host/ffi.json): the runtime records a frame as a display list through the host_*
// paint calls, and presents it once. What the other hosts draw through Core Graphics and Cairo is
// drawn here through Direct2D, so the geometry, the clip stack and the paint order are the same.
//
// The host draws the whole page display list — fills, borders, rounded corners, clips, gradients,
// images, text, box shadows and a box's filter chain — and canvas 2D into a bitmap of the
// canvas's own, and draws WebGL 2 through ANGLE when its libraries are beside the app. It
// publishes the page's accessibility tree through UI Automation, has no IME composition, and does
// not apply backdrop filters or mix-blend-mode. A call that reaches one of those answers the way
// a platform without the feature does: a page that asks for a WebGL 2 context gets null where
// ANGLE is missing, so what a page can detect matches what it gets.

// The host calls the classic CRT functions on purpose; their MSVC deprecation warnings are noise.
#if defined(_MSC_VER) && !defined(_CRT_SECURE_NO_WARNINGS)
#define _CRT_SECURE_NO_WARNINGS
#endif

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <windowsx.h>
#include <imm.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <d2d1_1.h>
#include <d2d1_1helper.h>
#include <dwrite.h>
#include <dwrite_1.h>
#include <dwrite_2.h>
#include <wincodec.h>
#include <objbase.h>
#include <oleauto.h>
#include <ocidl.h>
#include <propidl.h>
#include <propvarutil.h>
#include <shlobj.h>
#include <shellapi.h>
#include <uiautomation.h>
#include <uiautomationcoreapi.h>
#include "windows_gl.h"
// SQLite: the Windows host calls the system's winsqlite3.dll, the SQLite Windows 10 and later
// ship, through the import library a build makes from vendor/winsqlite3.def. The API is declared
// here rather than included, since winsqlite3 brings no header and the host uses only these calls.
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
typedef long long sqlite3_int64;
typedef void (*sqlite3_destructor_type)(void *);
#define SQLITE_OK 0
#define SQLITE_NULL 5
#define SQLITE_NOMEM 7
#define SQLITE_MISUSE 21
#define SQLITE_OPEN_READWRITE 0x00000002
#define SQLITE_OPEN_CREATE 0x00000004
#define SQLITE_OPEN_FULLMUTEX 0x00010000
#define SQLITE_TRANSIENT ((sqlite3_destructor_type)(size_t)-1)
extern "C" {
__declspec(dllimport) int sqlite3_open(const char *path, sqlite3 **db);
__declspec(dllimport) int sqlite3_open_v2(const char *path, sqlite3 **db, int flags, const char *vfs);
__declspec(dllimport) int sqlite3_close(sqlite3 *db);
__declspec(dllimport) int sqlite3_close_v2(sqlite3 *db);
__declspec(dllimport) int sqlite3_busy_timeout(sqlite3 *db, int ms);
__declspec(dllimport) int sqlite3_exec(sqlite3 *db, const char *sql, int (*cb)(void *, int, char **, char **), void *arg, char **err);
__declspec(dllimport) const char *sqlite3_errmsg(sqlite3 *db);
__declspec(dllimport) int sqlite3_prepare_v2(sqlite3 *db, const char *sql, int n, sqlite3_stmt **stmt, const char **tail);
__declspec(dllimport) int sqlite3_finalize(sqlite3_stmt *stmt);
__declspec(dllimport) int sqlite3_reset(sqlite3_stmt *stmt);
__declspec(dllimport) int sqlite3_clear_bindings(sqlite3_stmt *stmt);
__declspec(dllimport) int sqlite3_bind_text(sqlite3_stmt *stmt, int index, const char *text, int n, sqlite3_destructor_type done);
__declspec(dllimport) int sqlite3_bind_double(sqlite3_stmt *stmt, int index, double value);
__declspec(dllimport) int sqlite3_bind_int64(sqlite3_stmt *stmt, int index, sqlite3_int64 value);
__declspec(dllimport) int sqlite3_bind_null(sqlite3_stmt *stmt, int index);
__declspec(dllimport) int sqlite3_bind_blob(sqlite3_stmt *stmt, int index, const void *value, int n, sqlite3_destructor_type done);
__declspec(dllimport) int sqlite3_step(sqlite3_stmt *stmt);
__declspec(dllimport) int sqlite3_column_count(sqlite3_stmt *stmt);
__declspec(dllimport) int sqlite3_column_type(sqlite3_stmt *stmt, int col);
__declspec(dllimport) const unsigned char *sqlite3_column_text(sqlite3_stmt *stmt, int col);
__declspec(dllimport) const void *sqlite3_column_blob(sqlite3_stmt *stmt, int col);
__declspec(dllimport) int sqlite3_column_bytes(sqlite3_stmt *stmt, int col);
__declspec(dllimport) double sqlite3_column_double(sqlite3_stmt *stmt, int col);
__declspec(dllimport) int sqlite3_changes(sqlite3 *db);
__declspec(dllimport) sqlite3_int64 sqlite3_last_insert_rowid(sqlite3 *db);
}

// The compositor's shared core (the chunk walk and its frame types) and the D3D11 backend. The
// core's .c files are compiled as their own objects for a Windows target; the window's compositing
// below is this file's half of the same design macOS's Metal path follows.
#include "compositor/backend.h"
#include "compositor/chunks.h"
#include "compositor/d3d11_backend.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>

// The host is linked without a C++ runtime on every platform — scriptc links the C runtime and its
// own objects, not libstdc++/libc++/the MSVC C++ library — so the allocation operators a class with
// virtual functions needs are defined here, over the C heap. Replacing them is what the program
// may do, and it is what lets `new AxProvider` resolve with no C++ library at all.
void *operator new(size_t n) { return malloc(n); }
void *operator new[](size_t n) { return malloc(n); }
void operator delete(void *p) noexcept { free(p); }
void operator delete[](void *p) noexcept { free(p); }
void operator delete(void *p, size_t) noexcept { free(p); }
void operator delete[](void *p, size_t) noexcept { free(p); }

#if !defined(_MSC_VER)
// The interfaces the provider answers are C++ classes, so their vtables name RTTI descriptors.
// -fno-rtti keeps the descriptors' contents out of the object, leaving their vtables to the link:
// these are those symbols, as data nothing here reads.
extern "C" {
void *ax_type_info_vtable[4] __asm__("_ZTVN10__cxxabiv117__class_type_infoE") = {0, 0, 0, 0};
void *ax_si_type_info_vtable[4] __asm__("_ZTVN10__cxxabiv120__si_class_type_infoE") = {0, 0, 0, 0};
void *ax_vmi_type_info_vtable[4] __asm__("_ZTVN10__cxxabiv121__vmi_class_type_infoE") = {0, 0, 0, 0};
}
#endif  // !_MSC_VER

/** A string the runtime reads back inside a call: its bytes, which aren't NUL-terminated. */
typedef void (*str_cb)(const uint8_t *, size_t);
typedef void (*bytes_cb)(const uint8_t *, size_t);
typedef void (*dir_cb)(const uint8_t *, size_t);
typedef void (*window_text_cb)(const uint8_t *, size_t);
typedef void (*metrics_cb)(const uint8_t *, size_t);
typedef void (*cb_t)(const uint8_t *, size_t);

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// ---------------------------------------------------------------------------
// Small helpers

static double now_ms(void) {
  static LARGE_INTEGER freq;
  static int ready = 0;
  if (!ready) {
    QueryPerformanceFrequency(&freq);
    ready = 1;
  }
  LARGE_INTEGER at;
  QueryPerformanceCounter(&at);
  return (double)at.QuadPart * 1000.0 / (double)freq.QuadPart;
}

/** Whether NATIVE_FRAME_TIMES asks for per-frame stage times, read once. */
static int frame_times(void) {
  static int on = -1;
  if (on < 0) {
    const char *env = getenv("NATIVE_FRAME_TIMES");
    on = env != NULL && env[0] != 0 && strcmp(env, "0") != 0;
  }
  return on;
}

static char *dup_str(const char *s) {
  size_t n = strlen(s) + 1;
  char *p = (char *)malloc(n);
  if (p) memcpy(p, s, n);
  return p;
}

/** The next code point of a UTF-8 run. */
static int utf8_next(const uint8_t *s, size_t n, size_t *i, uint32_t *cp) {
  if (*i >= n) return 0;
  uint8_t b = s[(*i)++];
  if (b < 0x80) {
    *cp = b;
    return 1;
  }
  int extra = (b & 0xe0) == 0xc0 ? 1 : (b & 0xf0) == 0xe0 ? 2 : (b & 0xf8) == 0xf0 ? 3 : 0;
  if (extra == 0 || *i + (size_t)extra > n) {
    *cp = 0xfffd;
    return 1;
  }
  uint32_t v = b & (0x3f >> extra);
  for (int k = 0; k < extra; k++) v = (v << 6) | (s[(*i)++] & 0x3f);
  *cp = v;
  return 1;
}

/** Appends a code point to a UTF-8 buffer, returning its length. */
static size_t utf8_put(uint32_t cp, char *out) {
  if (cp < 0x80) {
    out[0] = (char)cp;
    return 1;
  }
  if (cp < 0x800) {
    out[0] = (char)(0xc0 | (cp >> 6));
    out[1] = (char)(0x80 | (cp & 0x3f));
    return 2;
  }
  if (cp < 0x10000) {
    out[0] = (char)(0xe0 | (cp >> 12));
    out[1] = (char)(0x80 | ((cp >> 6) & 0x3f));
    out[2] = (char)(0x80 | (cp & 0x3f));
    return 3;
  }
  out[0] = (char)(0xf0 | (cp >> 18));
  out[1] = (char)(0x80 | ((cp >> 12) & 0x3f));
  out[2] = (char)(0x80 | ((cp >> 6) & 0x3f));
  out[3] = (char)(0x80 | (cp & 0x3f));
  return 4;
}

/** A run of UTF-8 bytes as UTF-16, which is what the Windows text APIs take. */
static wchar_t *utf8_to_utf16(const uint8_t *s, size_t n, size_t *out_len) {
  // Any code point needs at most two UTF-16 code units, so two per input byte is enough.
  wchar_t *out = (wchar_t *)malloc((n * 2 + 1) * sizeof(wchar_t));
  if (!out) return NULL;
  size_t at = 0, i = 0;
  uint32_t cp;
  while (utf8_next(s, n, &i, &cp)) {
    if (cp >= 0x10000) {
      cp -= 0x10000;
      out[at++] = (wchar_t)(0xd800 + (cp >> 10));
      out[at++] = (wchar_t)(0xdc00 + (cp & 0x3ff));
    } else {
      out[at++] = (wchar_t)cp;
    }
  }
  out[at] = 0;
  if (out_len) *out_len = at;
  return out;
}

/** Copies a C string into a buffer, refusing rather than cutting a name short. */
static int copy_name_bytes(char *out, size_t cap, const uint8_t *s, size_t n) {
  if (n >= cap) return 0;
  memcpy(out, s, n);
  out[n] = '\0';
  return 1;
}

static uint8_t *read_file_bytes(const char *name, size_t *out_len) {
  // The file's name arrives in UTF-8; Windows opens files by UTF-16, so a path with any character
  // outside the ANSI code page still names the same file.
  size_t wide_len = 0;
  wchar_t *wide = utf8_to_utf16((const uint8_t *)name, strlen(name), &wide_len);
  FILE *f = wide ? _wfopen(wide, L"rb") : NULL;
  free(wide);
  if (!f) return NULL;
  if (fseek(f, 0, SEEK_END) != 0) {
    fclose(f);
    return NULL;
  }
  long size = ftell(f);
  if (size <= 0) {
    fclose(f);
    return NULL;
  }
  rewind(f);
  uint8_t *buf = (uint8_t *)malloc((size_t)size);
  if (!buf) {
    fclose(f);
    return NULL;
  }
  if (fread(buf, 1, (size_t)size, f) != (size_t)size) {
    free(buf);
    fclose(f);
    return NULL;
  }
  fclose(f);
  *out_len = (size_t)size;
  return buf;
}

// ---------------------------------------------------------------------------
// Direct3D, Direct2D and the window

static ID3D11Device *g_d3d = NULL;
static IDXGIFactory2 *g_dxgi_factory = NULL;
static ID2D1Factory1 *g_d2d_factory = NULL;
static ID2D1Device *g_d2d_device = NULL;
static ID2D1DeviceContext *g_d2d = NULL;
/** The bitmap the frame paints into: a swap chain buffer in a window, a plain bitmap offscreen. */
static ID2D1Bitmap1 *g_target = NULL;
static IDXGISwapChain1 *g_swap = NULL;
/** The display the swap chain was made for: Present goes through that output until the chain is
 *  made again, whatever display the window has moved to. */
static HMONITOR g_swap_monitor = NULL;
static int g_device_failed = 0;
static char g_adapter_name[256] = "";


static HWND g_hwnd = NULL;
static wchar_t g_char_high = 0;
static HCURSOR g_cursor = NULL;
static IRawElementProviderSimple *g_ax_host = NULL;
static IRawElementProviderFragmentRoot *g_ax_root = NULL;
static IUnknown *g_ax_marshaler = NULL;
extern "C" {
static void ax_ensure(void);
static void ax_activate(void);
static int ax_take_action(void);
}
static int g_window_class = 0;
static double g_scale = 1;         // device pixels per CSS pixel
static double g_view_w = 0, g_view_h = 0;  // the view in CSS px
static double g_win_w = 0, g_win_h = 0;
static int g_window_shown = 0;

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam);
static void paint_frame(void);
extern "C" {
static void present_now(void);
}

/** The window timer the compositor settles a page that stopped moving on (see composite_into). */
#define COMP_SETTLE_TIMER 0x4e43

/** Composites a recorded frame on the window's D3D11 backend; defined with the compositor below. */
static int window_composite(void);

/**
 * Tells Windows the process draws its own pixels at the display's scale, before any window
 * exists: without this the system bitmap-stretches the app on a scaled display and the window's
 * DPI never changes, so the backing scale and the frame's resizing would never be exercised.
 * Per-monitor v2 is Windows 10 1703's; an older system gets system DPI awareness instead.
 */
static void enable_dpi_awareness(void) {
  static int asked = 0;
  if (asked) return;
  asked = 1;
  HMODULE user32 = GetModuleHandleW(L"user32.dll");
  if (!user32) return;
  typedef BOOL(WINAPI * set_context_fn)(HANDLE);
  set_context_fn set_context =
      (set_context_fn)(void *)GetProcAddress(user32, "SetProcessDpiAwarenessContext");
  if (set_context != NULL && set_context((HANDLE)-4)) return;  // PER_MONITOR_AWARE_V2
  typedef BOOL(WINAPI * set_aware_fn)(void);
  set_aware_fn set_aware = (set_aware_fn)(void *)GetProcAddress(user32, "SetProcessDPIAware");
  if (set_aware != NULL) set_aware();
}

/** The class the app's window belongs to, registered once. */
static const wchar_t *window_class_name(void) {
  if (!g_window_class) {
    WNDCLASSEXW wc = {0};
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = window_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.lpszClassName = L"native";
    RegisterClassExW(&wc);
    g_window_class = 1;
  }
  return L"native";
}

/** The DPI the window is drawn at, in device pixels per CSS pixel. */
static double window_scale(HWND hwnd) {
  if (!hwnd) return 1;
  // GetDpiForWindow is Windows 10 1607 and later; older systems start at 96.
  typedef UINT(WINAPI * get_dpi_for_window_fn)(HWND);
  static get_dpi_for_window_fn get_dpi = NULL;
  static int looked = 0;
  if (!looked) {
    HMODULE user32 = GetModuleHandleW(L"user32.dll");
    if (user32) get_dpi = (get_dpi_for_window_fn)(void *)GetProcAddress(user32, "GetDpiForWindow");
    looked = 1;
  }
  UINT dpi = 96;
  if (get_dpi) dpi = get_dpi(hwnd);
  else {
    HDC dc = GetDC(hwnd);
    if (dc) {
      dpi = (UINT)GetDeviceCaps(dc, LOGPIXELSX);
      ReleaseDC(hwnd, dc);
    }
  }
  if (dpi < 48) dpi = 48;
  return (double)dpi / 96.0;
}

/** The client area in CSS pixels, which is the page's view. */
static void update_view_size(void) {
  if (!g_hwnd) return;
  RECT rc;
  if (!GetClientRect(g_hwnd, &rc)) return;
  g_view_w = g_win_w = (double)(rc.right - rc.left) / g_scale;
  g_view_h = g_win_h = (double)(rc.bottom - rc.top) / g_scale;
}

static void release_target(void) {
  if (g_d2d) g_d2d->SetTarget(NULL);
  if (g_target) {
    g_target->Release();
    g_target = NULL;
  }
}

/** The device and the Direct2D context every frame paints through, made on first use. */
static int ensure_device(void) {
  if (g_d2d) return 1;
  if (g_device_failed) return 0;
  HRESULT hr;
  if (!g_d2d_factory) {
    hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &g_d2d_factory);
    if (FAILED(hr)) {
      g_device_failed = 1;
      return 0;
    }
  }
  if (!g_d3d) {
    D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
                                  D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0};
    D3D_FEATURE_LEVEL got;
    const char *driver = "hardware";
    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    // The default adapter can be the software Basic Render Driver even on a machine with a GPU
    // (a virtual display driver, a headless instance), so the first adapter that is not software
    // is chosen by hand; WARP below is still the fallback when no such adapter exists.
    IDXGIAdapter1 *chosen = NULL;
    IDXGIFactory1 *adapter_factory = NULL;
    if (SUCCEEDED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), (void **)&adapter_factory)) && adapter_factory) {
      IDXGIAdapter1 *adapter = NULL;
      for (UINT i = 0; adapter_factory->EnumAdapters1(i, &adapter) == S_OK; i++) {
        DXGI_ADAPTER_DESC1 desc;
        adapter->GetDesc1(&desc);
        int software = (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0 ||
                       wcscmp(desc.Description, L"Microsoft Basic Render Driver") == 0;
        if (!software) {
          chosen = adapter;
          break;
        }
        adapter->Release();
        adapter = NULL;
      }
      adapter_factory->Release();
    }
    hr = D3D11CreateDevice(chosen, chosen ? D3D_DRIVER_TYPE_UNKNOWN : D3D_DRIVER_TYPE_HARDWARE, NULL,
                           flags, levels, 4, D3D11_SDK_VERSION, &g_d3d, &got, NULL);
    if (chosen) chosen->Release();
    if (FAILED(hr)) {
      driver = "warp";
      // A machine without a usable GPU, such as a build runner, still paints: WARP is Direct3D's
      // own software rasterizer, so the page's frame is the same picture.
      hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_WARP, NULL, flags, levels, 4,
                             D3D11_SDK_VERSION, &g_d3d, &got, NULL);
    }
    if (FAILED(hr)) {
      g_device_failed = 1;
      return 0;
    }
    // The swap chain needs the factory of the adapter the device runs on.
    IDXGIDevice *dxgi_device = NULL;
    if (SUCCEEDED(g_d3d->QueryInterface(__uuidof(IDXGIDevice), (void **)&dxgi_device))) {
      IDXGIAdapter *adapter = NULL;
      if (SUCCEEDED(dxgi_device->GetAdapter(&adapter)) && adapter) {
        // Which adapter answered, not just which driver type was asked for: a "hardware" device on
        // a machine with no vendor driver is the Basic Render Driver, and the line should say so.
        DXGI_ADAPTER_DESC desc;
        if (SUCCEEDED(adapter->GetDesc(&desc)))
          WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1, g_adapter_name, sizeof g_adapter_name, NULL, NULL);
        adapter->GetParent(__uuidof(IDXGIFactory2), (void **)&g_dxgi_factory);
        adapter->Release();
      }
      hr = g_d2d_factory->CreateDevice(dxgi_device, &g_d2d_device);
      dxgi_device->Release();
    } else {
      hr = E_FAIL;
    }
    if (!g_dxgi_factory) {
      // No factory from the adapter: the system's own, which every adapter can present to.
      IDXGIFactory1 *factory1 = NULL;
      if (SUCCEEDED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), (void **)&factory1)) && factory1) {
        factory1->QueryInterface(__uuidof(IDXGIFactory2), (void **)&g_dxgi_factory);
        factory1->Release();
      }
    }
    if (FAILED(hr)) {
      g_device_failed = 1;
      return 0;
    }
    if (frame_times())
      fprintf(stderr, "native: direct3d %s, feature level %04x, adapter %s\n", driver, (unsigned)got,
              g_adapter_name[0] ? g_adapter_name : "unknown");
  }
  if (!g_d2d) {
    hr = g_d2d_device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &g_d2d);
    if (FAILED(hr)) {
      g_device_failed = 1;
      return 0;
    }
  }
  return 1;
}

/** Makes the swap chain's back buffer the frame's target, at the window's scale. */
static int ensure_window_target(void) {
  if (!ensure_device() || !g_hwnd) return 0;
  if (g_swap && g_target) return 1;
  if (!g_dxgi_factory) return 0;
  RECT rc;
  GetClientRect(g_hwnd, &rc);
  int w = rc.right - rc.left, h = rc.bottom - rc.top;
  if (w <= 0 || h <= 0) return 0;
  if (!g_swap) {
    DXGI_SWAP_CHAIN_DESC1 desc = {0};
    desc.Width = (UINT)w;
    desc.Height = (UINT)h;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
    HRESULT hr = g_dxgi_factory->CreateSwapChainForHwnd(g_d3d, g_hwnd, &desc, NULL, NULL, &g_swap);
    if (FAILED(hr)) {
      // Flip-model presentation needs Windows 8's compositor; the older blit model is what a
      // driver or an older system answers with, and it shows the same frame.
      DXGI_SWAP_CHAIN_DESC1 blit = desc;
      blit.BufferCount = 1;
      blit.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
      hr = g_dxgi_factory->CreateSwapChainForHwnd(g_d3d, g_hwnd, &blit, NULL, NULL, &g_swap);
      if (FAILED(hr)) {
        if (frame_times()) fprintf(stderr, "native: no swap chain for the window (%08lx)\n", (unsigned long)hr);
        return 0;
      }
    }
    g_dxgi_factory->MakeWindowAssociation(g_hwnd, DXGI_MWA_NO_ALT_ENTER);
    g_swap_monitor = MonitorFromWindow(g_hwnd, MONITOR_DEFAULTTONEAREST);
  }
  IDXGISurface *surface = NULL;
  HRESULT got_buffer = g_swap->GetBuffer(0, __uuidof(IDXGISurface), (void **)&surface);
  if (FAILED(got_buffer)) {
    if (frame_times()) fprintf(stderr, "native: the swap chain has no surface (%08lx)\n", (unsigned long)got_buffer);
    return 0;
  }
  D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
      D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
      96.0f * (float)g_scale, 96.0f * (float)g_scale);
  HRESULT hr = g_d2d->CreateBitmapFromDxgiSurface(surface, &props, &g_target);
  surface->Release();
  if (FAILED(hr)) {
    if (frame_times()) fprintf(stderr, "native: the surface is no target (%08lx)\n", (unsigned long)hr);
    return 0;
  }
  g_d2d->SetTarget(g_target);
  g_d2d->SetDpi(96.0f * (float)g_scale, 96.0f * (float)g_scale);
  g_d2d->SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
  g_d2d->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  return 1;
}

/** Resizes the swap chain's buffers to the window's client area. */
static void resize_window_target(void) {
  if (!g_d2d || !g_swap) return;
  release_target();
  RECT rc;
  GetClientRect(g_hwnd, &rc);
  int w = rc.right - rc.left, h = rc.bottom - rc.top;
  if (w <= 0 || h <= 0) return;
  g_swap->ResizeBuffers(0, (UINT)w, (UINT)h, DXGI_FORMAT_UNKNOWN, 0);
  ensure_window_target();
}

/** Makes the swap chain for the display the window is on, if it has moved to another one. A
 *  window's chain presents through the output it was created for: moved to a display of another
 *  adapter, it keeps presenting through the first, and on that path Present waits tens of
 *  milliseconds a frame. Nothing moves the chain, so it is made again for the new display. */
static void retarget_window_monitor(void) {
  if (!g_swap || !g_hwnd) return;
  HMONITOR monitor = MonitorFromWindow(g_hwnd, MONITOR_DEFAULTTONEAREST);
  if (monitor == NULL || monitor == g_swap_monitor) return;
  release_target();
  g_swap->Release();
  g_swap = NULL;
  g_swap_monitor = monitor;
  ensure_window_target();
}

// ---------------------------------------------------------------------------
// Events
//
// The messages a window sends become the runtime's events, numbered as runtime/host.ts numbers
// them. A headless run has no window and its steps drive the runtime directly, so the queue is
// the only path either way.

enum {
  EV_NONE = 0, EV_QUIT = 1, EV_DOWN = 2, EV_UP = 3, EV_MOVE = 4, EV_RESIZE = 5, EV_LEAVE = 6,
  EV_OTHER = 7, EV_KEY = 8, EV_WHEEL = 9, EV_SETTINGS = 10, EV_AXFOCUS = 11, EV_AXSELRANGE = 12,
  EV_DROP = 13, EV_MENU = 14, EV_CONTEXT = 15, EV_WINDOWMOVE = 16, EV_FULLSCREEN = 17,
  EV_FOCUS = 18, EV_BLUR = 19, EV_VISIBILITY = 20, EV_MESSAGE = 21, EV_WINDOWCLOSED = 22,
  EV_APPQUIT = 23,
  /** An input method's composition changed: host_composition_phase() says how. */
  EV_COMPOSE = 24,
  /** A key was released: the page gets keyup. */
  EV_KEYUP = 25,
  /** An accessibility client acted on a node: host_ax_action() says how. */
  EV_AXACTION = 26,
};

/** The runtime's key codes (runtime/host.ts KEY_*). */
enum {
  KEY_TEXT = 0, KEY_BACKSPACE = 1, KEY_ENTER = 2, KEY_LEFT = 3, KEY_RIGHT = 4, KEY_UP = 5,
  KEY_DOWN = 6, KEY_HOME = 7, KEY_END = 8, KEY_ESCAPE = 9, KEY_TAB = 10, KEY_DELETE = 11,
  KEY_SELECT_ALL = 12, KEY_OTHER = 13, KEY_COPY = 14, KEY_CUT = 15, KEY_PASTE = 16,
};

/** The runtime's modifier bits (runtime/host.ts MOD_*). */
enum { HOST_MOD_META = 1, HOST_MOD_SHIFT = 2, HOST_MOD_ALT = 4, HOST_MOD_CTRL = 8 };

/** One queued event: its number and the coordinates, deltas and keys it carries. */
typedef struct {
  int32_t kind;
  double x, y, dx, dy;
  int32_t clicks;
  int32_t key;
  int32_t mods;
  /** 1 when a keydown is the system's auto-repeat of a key that is already held. */
  int32_t repeat;
  char text[64];
  /** A message's body, owned by the event until host_poll hands it out. */
  char *payload;
} HostEvent;

#define EVENT_QUEUE 256
static HostEvent g_events[EVENT_QUEUE];
static int g_event_read = 0, g_event_write = 0;

/** The event host_event_* report on, which is the one host_poll handed out last. */
static HostEvent g_event = {0};

static void queue_event(HostEvent ev) {
  int next = (g_event_write + 1) % EVENT_QUEUE;
  if (next == g_event_read) {
    free(ev.payload);  // full: the newest event is dropped
    return;
  }
  g_events[g_event_write] = ev;
  g_event_write = next;
}

static void queue_kind(int32_t kind) {
  HostEvent ev = {0};
  ev.kind = kind;
  queue_event(ev);
}

/** The phase of the input method's composition the runtime last heard (see runtime/host.ts). */
static int32_t g_compose_phase = -1;
/** The composition string that phase carried, as UTF-8: the marked text, or the committed one. */
static char g_compose_text[4096];
static size_t g_compose_len = 0;
/** Where the caret is, in the page's CSS pixels: the input method's windows open there. */
static double g_caret_x = 0, g_caret_y = 0, g_caret_w = 1, g_caret_h = 16;
static int g_ime_composing = 0;

/** Moves the input method's composition and candidate windows to the caret. */
static void ime_place(HWND hwnd) {
  HIMC imc = ImmGetContext(hwnd);
  if (!imc) return;
  COMPOSITIONFORM window = {0};
  window.dwStyle = CFS_POINT;
  // Client coordinates in device pixels: the caret is a CSS-pixel rectangle.
  window.ptCurrentPos.x = (LONG)(g_caret_x * g_scale);
  window.ptCurrentPos.y = (LONG)((g_caret_y + g_caret_h) * g_scale);
  ImmSetCompositionWindow(imc, &window);
  CANDIDATEFORM candidate = {0};
  candidate.dwIndex = 0;
  candidate.dwStyle = CFS_CANDIDATEPOS;
  candidate.ptCurrentPos = window.ptCurrentPos;
  ImmSetCandidateWindow(imc, &candidate);
  ImmReleaseContext(hwnd, imc);
}

/** Queues one composition event: its phase and the text that phase carries, as UTF-8. */
static void queue_composition(int32_t phase, const wchar_t *text, int chars) {
  g_compose_phase = phase;
  size_t wide_len = chars > 0 ? (size_t)chars : 0;
  size_t at = 0;
  for (size_t i = 0; i < wide_len && at + 4 < sizeof g_compose_text; i++) {
    uint32_t cp = (uint32_t)text[i];
    if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < wide_len) {
      uint32_t low = (uint32_t)text[i + 1];
      if (low >= 0xdc00 && low <= 0xdfff) {
        cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
        i++;
      }
    }
    at += utf8_put(cp, g_compose_text + at);
  }
  g_compose_text[at] = '\0';
  g_compose_len = at;
  queue_kind(EV_COMPOSE);
}

static int32_t g_menu_chosen = -1;

/** The files an OS drag last dropped on the window, as UTF-8 paths. */
#define MAX_DROPS 64
static char *g_drop_paths[MAX_DROPS];
static int g_drop_count = 0;

static void clear_drops(void) {
  for (int i = 0; i < g_drop_count; i++) free(g_drop_paths[i]);
  g_drop_count = 0;
}

static void add_drop(wchar_t *path) {
  if (g_drop_count >= MAX_DROPS) return;
  size_t len = wcslen(path);
  char *utf8 = (char *)malloc(len * 4 + 1);
  if (!utf8) return;
  size_t at = 0;
  for (size_t i = 0; i < len; i++) at += utf8_put((uint32_t)path[i], utf8 + at);
  utf8[at] = '\0';
  g_drop_paths[g_drop_count++] = utf8;
}

static int32_t take_event(void) {
  if (g_event_read == g_event_write) return EV_NONE;
  free(g_event.payload);
  g_event = g_events[g_event_read];
  g_event_read = (g_event_read + 1) % EVENT_QUEUE;
  if (g_event.kind == EV_MENU) g_menu_chosen = g_event.key;
  return g_event.kind;
}

/** The message a test posts to compose: wparam 0 sets the preview, 1 commits it. */
static UINT ime_test_message(void) {
  static UINT registered = 0;
  if (registered == 0) registered = RegisterWindowMessageW(L"native-ime-test");
  return registered;
}

/** Composes into the window's own IME context and posts the messages an input method would: the
 *  preview, then the commit. Only NATIVE_IME_TEST runs it. */
static void ime_test_step(HWND hwnd, int commit) {
  HIMC imc = ImmGetContext(hwnd);
  if (!imc) return;
  const wchar_t *text = commit ? L"\u65e5\u672c" : L"\u306b\u307b\u3093";
  DWORD bytes = (DWORD)(wcslen(text) * sizeof(wchar_t));
  ImmSetCompositionStringW(imc, SCS_SETSTR, (LPVOID)text, bytes, NULL, 0);
  if (!commit) {
    SendMessageW(hwnd, WM_IME_STARTCOMPOSITION, 0, 0);
    SendMessageW(hwnd, WM_IME_COMPOSITION, 0, GCS_COMPSTR);
  } else {
    // A machine with no input method has a default context that keeps no result string, so the
    // test commits the text it chose directly: what a real input method commits arrives through
    // WM_IME_COMPOSITION and GCS_RESULTSTR, which is the branch above.
    g_ime_composing = 0;
    queue_composition(2, L"\u65e5\u672c", 2);
  }
  ImmReleaseContext(hwnd, imc);
}

/** The modifier bits of a message: Ctrl, Shift, Alt, and the Windows key as meta. */
static int32_t mods_of(void) {
  int32_t mods = 0;
  if (GetKeyState(VK_CONTROL) & 0x8000) mods |= HOST_MOD_CTRL;
  if (GetKeyState(VK_SHIFT) & 0x8000) mods |= HOST_MOD_SHIFT;
  if (GetKeyState(VK_MENU) & 0x8000) mods |= HOST_MOD_ALT;
  if ((GetKeyState(VK_LWIN) | GetKeyState(VK_RWIN)) & 0x8000) mods |= HOST_MOD_META;
  return mods;
}

/** Where a message's client coordinates are in the page's own CSS pixels. */
static void client_point(LPARAM lparam, double *x, double *y) {
  *x = (double)GET_X_LPARAM(lparam) / g_scale;
  *y = (double)GET_Y_LPARAM(lparam) / g_scale;
}

/** The key each virtual key last reported, and the text it typed, so the keyup that follows
 *  names the same key: a letter's text arrives in WM_CHAR, not in WM_KEYUP. */
static int32_t g_key_code_by_vk[256];
static char g_key_text_by_vk[256][8];
static WPARAM g_last_key_vk = 0;
/** The repeat flag of the keydown whose text WM_CHAR is about to deliver: a held letter types
 *  again, so its text event is a repeat too. */
static int32_t g_last_key_repeat = 0;

/** The runtime's key code for a virtual key, or -1 for a key that carries no code of its own. */
static int32_t key_code(WPARAM vk) {
  switch (vk) {
    case VK_BACK: return KEY_BACKSPACE;
    case VK_RETURN: return KEY_ENTER;
    case VK_LEFT: return KEY_LEFT;
    case VK_RIGHT: return KEY_RIGHT;
    case VK_UP: return KEY_UP;
    case VK_DOWN: return KEY_DOWN;
    case VK_HOME: return KEY_HOME;
    case VK_END: return KEY_END;
    case VK_ESCAPE: return KEY_ESCAPE;
    case VK_TAB: return KEY_TAB;
    case VK_DELETE: return KEY_DELETE;
    default: return KEY_OTHER;
  }
}

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
  if (msg == ime_test_message() && getenv("NATIVE_IME_TEST") != NULL) {
    // A test drives the composition itself, one step per message, so the run has no timing in it.
    ime_test_step(hwnd, wparam != 0);
    return 0;
  }
  switch (msg) {
    case WM_GETOBJECT:
      if ((LONG)lparam == (LONG)UiaRootObjectId && g_ax_root) {
        // A UI Automation client asked for the window's tree: from the next frame on, it is built.
        ax_activate();
        // The provider is handed over as its simple interface, the one WM_GETOBJECT expects.
        IRawElementProviderSimple *simple = NULL;
        if (SUCCEEDED(g_ax_root->QueryInterface(__uuidof(IRawElementProviderSimple), (void **)&simple)) &&
            simple) {
          LRESULT result = (LRESULT)UiaReturnRawElementProvider(hwnd, wparam, lparam, simple);
          simple->Release();
          return result;
        }
      }
      break;
    case WM_DROPFILES: {
      HDROP drop = (HDROP)wparam;
      UINT count = DragQueryFileW(drop, 0xFFFFFFFFu, NULL, 0);
      clear_drops();
      for (UINT i = 0; i < count; i++) {
        UINT len = DragQueryFileW(drop, i, NULL, 0);
        wchar_t *name = (wchar_t *)malloc(((size_t)len + 1) * sizeof(wchar_t));
        if (!name) continue;
        if (DragQueryFileW(drop, i, name, len + 1) == len) add_drop(name);
        free(name);
      }
      DragFinish(drop);
      HostEvent ev = {0};
      ev.kind = EV_DROP;
      ev.clicks = g_drop_count;
      queue_event(ev);
      return 0;
    }
    case WM_CLOSE:
      queue_kind(EV_QUIT);
      DestroyWindow(hwnd);
      return 0;
    case WM_DESTROY:
      g_hwnd = NULL;
      if (g_ax_root) {
        g_ax_root->Release();
        g_ax_root = NULL;
      }
      if (g_ax_host) {
        g_ax_host->Release();
        g_ax_host = NULL;
      }
      PostQuitMessage(0);
      return 0;
    case WM_PAINT: {
      // The frame the page last painted is what the window shows, so an uncovered or resized
      // window is repainted from the display list rather than left as the system clears it.
      PAINTSTRUCT ps;
      BeginPaint(hwnd, &ps);
      EndPaint(hwnd, &ps);
      present_now();
      return 0;
    }
    case WM_ERASEBKGND:
      return 1;  // the frame paints every pixel
    case WM_TIMER:
      if (wparam == COMP_SETTLE_TIMER) {
        // The compositor's second look at a page that stopped moving (see composite_into).
        KillTimer(hwnd, COMP_SETTLE_TIMER);
        present_now();
        return 0;
      }
      break;
    case WM_SIZE: {
      if (wparam != SIZE_MINIMIZED) {
        update_view_size();
        resize_window_target();
        queue_kind(EV_RESIZE);
      }
      return 0;
    }
    case WM_MOVE:
      queue_kind(EV_WINDOWMOVE);
      return 0;
    case WM_SETFOCUS:
      queue_kind(EV_FOCUS);
      return 0;
    case WM_KILLFOCUS:
      queue_kind(EV_BLUR);
      return 0;
    case WM_DPICHANGED: {
      RECT *suggested = (RECT *)lparam;
      SetWindowPos(hwnd, NULL, suggested->left, suggested->top, suggested->right - suggested->left,
                   suggested->bottom - suggested->top, SWP_NOZORDER | SWP_NOACTIVATE);
      g_scale = window_scale(hwnd);
      release_target();
      if (g_swap) {
        g_swap->Release();
        g_swap = NULL;
      }
      ensure_window_target();
      update_view_size();
      queue_kind(EV_RESIZE);
      return 0;
    }
    case WM_MOUSEMOVE: {
      HostEvent ev = {0};
      ev.kind = EV_MOVE;
      client_point(lparam, &ev.x, &ev.y);
      ev.mods = mods_of();
      queue_event(ev);
      if (!g_window_shown) {
        // The first move over the client area is the pointer entering the page.
        TRACKMOUSEEVENT track = {0};
        track.cbSize = sizeof(track);
        track.dwFlags = TME_LEAVE;
        track.hwndTrack = hwnd;
        TrackMouseEvent(&track);
        g_window_shown = 1;
      }
      return 0;
    }
    case WM_MOUSELEAVE:
      g_window_shown = 0;
      queue_kind(EV_LEAVE);
      return 0;
    case WM_MOUSEWHEEL: {
      HostEvent ev = {0};
      ev.kind = EV_WHEEL;
      POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ScreenToClient(hwnd, &pt);
      ev.x = (double)pt.x / g_scale;
      ev.y = (double)pt.y / g_scale;
      ev.dy = -(double)GET_WHEEL_DELTA_WPARAM(wparam) / (double)WHEEL_DELTA * 40.0;
      ev.dx = 0;
      ev.mods = mods_of();
      queue_event(ev);
      return 0;
    }
    case WM_LBUTTONDOWN:
    case WM_LBUTTONDBLCLK: {
      HostEvent ev = {0};
      ev.kind = EV_DOWN;
      client_point(lparam, &ev.x, &ev.y);
      ev.clicks = msg == WM_LBUTTONDBLCLK ? 2 : 1;
      ev.mods = mods_of();
      queue_event(ev);
      SetCapture(hwnd);
      return 0;
    }
    case WM_LBUTTONUP: {
      HostEvent ev = {0};
      ev.kind = EV_UP;
      client_point(lparam, &ev.x, &ev.y);
      ev.clicks = 1;
      ev.mods = mods_of();
      queue_event(ev);
      ReleaseCapture();
      return 0;
    }
    case WM_RBUTTONUP: {
      HostEvent ev = {0};
      ev.kind = EV_CONTEXT;
      client_point(lparam, &ev.x, &ev.y);
      ev.mods = mods_of();
      queue_event(ev);
      return 0;
    }
    case WM_MBUTTONDOWN: {
      HostEvent ev = {0};
      ev.kind = EV_DOWN;
      client_point(lparam, &ev.x, &ev.y);
      ev.clicks = 1;
      ev.mods = mods_of() | HOST_MOD_ALT;
      queue_event(ev);
      return 0;
    }
    case WM_KEYDOWN: {
      HostEvent ev = {0};
      ev.kind = EV_KEY;
      ev.mods = mods_of();
      // Bit 30 of lParam is set when the key was already down: the system's auto-repeat.
      ev.repeat = (lparam & 0x40000000) ? 1 : 0;
      int32_t code = key_code(wparam);
      if (wparam == 'A' && (GetKeyState(VK_CONTROL) & 0x8000)) code = KEY_SELECT_ALL;
      else if (wparam == 'C' && (GetKeyState(VK_CONTROL) & 0x8000)) code = KEY_COPY;
      else if (wparam == 'X' && (GetKeyState(VK_CONTROL) & 0x8000)) code = KEY_CUT;
      else if (wparam == 'V' && (GetKeyState(VK_CONTROL) & 0x8000)) code = KEY_PASTE;
      ev.key = code;
      if (wparam < 256) {
        g_key_code_by_vk[wparam] = code;
        g_key_text_by_vk[wparam][0] = '\0';
        g_last_key_vk = wparam;
        g_last_key_repeat = ev.repeat;
      }
      queue_event(ev);
      return 0;
    }
    case WM_SYSKEYDOWN: {
      // A system key still has a key event, and DefWindowProc gets it too so a menu mnemonic
      // (Alt+N) and the window's own system commands keep working.
      HostEvent ev = {0};
      ev.kind = EV_KEY;
      ev.mods = mods_of();
      ev.repeat = (lparam & 0x40000000) ? 1 : 0;
      ev.key = key_code(wparam);
      if (wparam < 256) {
        g_key_code_by_vk[wparam] = ev.key;
        g_key_text_by_vk[wparam][0] = '\0';
        g_last_key_vk = wparam;
        g_last_key_repeat = ev.repeat;
      }
      queue_event(ev);
      return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    case WM_KEYUP:
    case WM_SYSKEYUP: {
      // A release names the key its press named. A letter's text arrived in WM_CHAR, so the
      // stored text is what makes its keyup a text key as well.
      HostEvent ev = {0};
      ev.kind = EV_KEYUP;
      ev.mods = mods_of();
      const char *text = wparam < 256 ? g_key_text_by_vk[wparam] : "";
      int32_t code = text[0] != '\0' ? KEY_TEXT
        : wparam < 256 && g_key_code_by_vk[wparam] != 0 ? g_key_code_by_vk[wparam]
        : key_code(wparam);
      ev.key = code;
      if (code == KEY_TEXT) snprintf(ev.text, sizeof(ev.text), "%s", text);
      queue_event(ev);
      return msg == WM_SYSKEYUP ? DefWindowProcW(hwnd, msg, wparam, lparam) : 0;
    }
    case WM_CHAR: {
      // Typed text arrives here, which is the path an input method commits through and the one
      // dead keys and AltGr take; a key's own code arrives above.
      wchar_t ch = (wchar_t)wparam;
      if (ch < 32) return 0;  // control keys are key events, not text
      uint32_t cp = (uint32_t)ch;
      if (ch >= 0xd800 && ch <= 0xdbff) {
        // Half of a surrogate pair: the other half is the next character.
        g_char_high = ch;
        return 0;
      }
      if (ch >= 0xdc00 && ch <= 0xdfff && g_char_high != 0) {
        cp = 0x10000 + (((uint32_t)g_char_high - 0xd800) << 10) + ((uint32_t)ch - 0xdc00);
        g_char_high = 0;
      }
      char utf8[8];
      size_t len = utf8_put(cp, utf8);
      utf8[len] = '\0';
      // The keyup that ends this press names the key the same way.
      if (g_last_key_vk < 256) snprintf(g_key_text_by_vk[g_last_key_vk], sizeof(g_key_text_by_vk[g_last_key_vk]), "%s", utf8);
      HostEvent ev = {0};
      ev.kind = EV_KEY;
      ev.key = KEY_TEXT;
      ev.mods = mods_of();
      // The keydown that typed this text was a repeat when the key is held.
      ev.repeat = g_last_key_repeat;
      g_last_key_repeat = 0;
      snprintf(ev.text, sizeof(ev.text), "%s", utf8);
      queue_event(ev);
      return 0;
    }
    case WM_IME_SETCONTEXT:
      // The composing text is drawn in the page's own field, so the system's composition window
      // stays hidden; the candidate list, which the input method draws, is still shown.
      lparam &= ~(LPARAM)ISC_SHOWUICOMPOSITIONWINDOW;
      return DefWindowProcW(hwnd, msg, wparam, lparam);
    case WM_IME_STARTCOMPOSITION:
      g_ime_composing = 1;
      ime_place(hwnd);
      queue_composition(0, L"", 0);
      break;
    case WM_IME_COMPOSITION: {
      HIMC imc = ImmGetContext(hwnd);
      if (!imc) break;
      if ((lparam & GCS_RESULTSTR) != 0) {
        // The commit: what the input method decided the user typed. An input method that leaves
        // the result string empty has committed the composition it was showing.
        LONG size = ImmGetCompositionStringW(imc, GCS_RESULTSTR, NULL, 0);
        LONG from = GCS_RESULTSTR;
        if (size <= 0) {
          size = ImmGetCompositionStringW(imc, GCS_COMPSTR, NULL, 0);
          from = GCS_COMPSTR;
        }
        wchar_t *text = size > 0 ? (wchar_t *)malloc((size_t)size) : NULL;
        LONG got = text ? ImmGetCompositionStringW(imc, from, text, size) : 0;
        queue_composition(2, text ? text : L"", got > 0 ? (int)(got / 2) : 0);
        free(text);
        g_ime_composing = 0;
      }
      if ((lparam & GCS_COMPSTR) != 0) {
        // The preview, rebuilt on every keystroke while the input method converts.
        LONG size = ImmGetCompositionStringW(imc, GCS_COMPSTR, NULL, 0);
        wchar_t *text = size > 0 ? (wchar_t *)malloc((size_t)size) : NULL;
        LONG got = text ? ImmGetCompositionStringW(imc, GCS_COMPSTR, text, size) : 0;
        queue_composition(1, text ? text : L"", got > 0 ? (int)(got / 2) : 0);
        free(text);
        g_ime_composing = 1;
      }
      ImmReleaseContext(hwnd, imc);
      return 0;
    }
    case WM_IME_ENDCOMPOSITION:
      if (g_ime_composing) {
        // Abandoned, not committed: the field keeps what it had.
        queue_composition(3, L"", 0);
        g_ime_composing = 0;
      }
      break;
    case WM_COMMAND: {
      // A menu item reports the line of the spec it came from, as a click on its element would.
      int32_t line = (int32_t)LOWORD(wparam);
      if (line > 0) {
        HostEvent ev = {0};
        ev.kind = EV_MENU;
        ev.key = line - 1;
        queue_event(ev);
        return 0;
      }
      break;
    }
    case WM_SETCURSOR:
      if (LOWORD(lparam) == HTCLIENT) {
        SetCursor(g_cursor ? g_cursor : LoadCursor(NULL, IDC_ARROW));
        return TRUE;
      }
      break;
  }
  return DefWindowProcW(hwnd, msg, wparam, lparam);
}

// ---------------------------------------------------------------------------
// Frame timings

static void frame_time(const char *stage, double since) {
  if (!frame_times()) return;
  // `at` is when the stage ended on the host's own clock, from the first one: the runtime's
  // `t=` comes from a timer that ticks every 15.6 ms on Windows, too coarse to tell frames apart.
  static double first = 0;
  double now = now_ms();
  if (first == 0) first = now;
  fprintf(stderr, "native: %s %g ms at=%.2f\n", stage, now - since, now - first);
}

/** Where a frame's replay spends its time, by kind of work, printed with the frame's stages. */
static double g_prof_effect = 0, g_prof_shadow = 0, g_prof_text = 0, g_prof_canvas = 0;
static double g_prof_replay = 0, g_prof_enddraw = 0, g_prof_present = 0, g_prof_clear = 0, g_prof_target = 0, g_prof_begin = 0;

// ---------------------------------------------------------------------------
// The display list
//
// A frame is recorded as a list of commands and painted when it is presented, as on the other
// hosts, which is what lets a headless run take a snapshot of a frame nobody sees. The commands
// are the ones runtime/paint.ts writes: the page's user space is top-left origin, y down, and the
// only transform between it and the target's device pixels is the backing scale.

enum {
  CMD_FILL = 0, CMD_TEXT, CMD_CLIP, CMD_UNCLIP, CMD_RING, CMD_IMAGE,
  CMD_FILL_ROUND, CMD_RING_ROUND, CMD_CLIP_ROUND,
  CMD_GRADIENT_LINEAR, CMD_GRADIENT_RADIAL, CMD_CANVAS,
  CMD_SHADOW, CMD_SHADOW_INSET, CMD_TEXT_SHADOW, CMD_TRANSFORM,
  CMD_GRADIENT_CONIC, CMD_POLY, CMD_CLIP_POLY, CMD_LINE,
  CMD_EFFECT_PUSH, CMD_EFFECT_POP, CMD_CLIP_ELLIPSE, CMD_CLIP_SHAPE,
  CMD_MASK_PUSH, CMD_MASK_SPLIT, CMD_MASK_POP,
  CMD_PERSPECTIVE_PUSH, CMD_PERSPECTIVE_POP,
  CMD_VIDEO,
};

typedef struct {
  int kind;
  int32_t image;
  double x, y, w, h, radius, line_width, line_height, size, weight;
  double sx, sy, sw, sh;
  double r[8];
  double q[8];
  double p0, p1, p2, p3;
  double dx, dy, blur, letter, word;
  int smooth;
  uint32_t color, shadow_color, emphasis, emphasis_color;
  char *text;
  size_t len;
  /** The handle an update by index answers to: this command's place in the list, plus one. */
  int32_t handle;
  /** A new opacity for an effect group, set after it was recorded: 0 keeps the spec's own. */
  int alpha_override;
  double alpha;
} Cmd;

static Cmd *g_cmds = NULL;
static size_t g_count = 0, g_cap = 0;
static uint32_t g_background = 0xffffffff;

static Cmd *push_cmd(void) {
  if (g_count == g_cap) {
    size_t cap = g_cap ? g_cap * 2 : 256;
    Cmd *grown = (Cmd *)realloc(g_cmds, cap * sizeof(Cmd));
    if (!grown) return &g_cmds[g_count - 1];
    g_cmds = grown;
    g_cap = cap;
  }
  Cmd *c = &g_cmds[g_count++];
  memset(c, 0, sizeof(Cmd));
  return c;
}

static void copy_text(Cmd *c, const uint8_t *s, size_t n) {
  c->text = (char *)malloc(n + 1);
  if (!c->text) {
    c->len = 0;
    return;
  }
  memcpy(c->text, s, n);
  c->text[n] = 0;
  c->len = n;
}

static void set_radii(Cmd *c, double tlx, double tly, double trx, double try_, double brx,
                      double bry, double blx, double bly) {
  c->r[0] = tlx;
  c->r[1] = tly;
  c->r[2] = trx;
  c->r[3] = try_;
  c->r[4] = brx;
  c->r[5] = bry;
  c->r[6] = blx;
  c->r[7] = bly;
}

extern "C" {

/** Starts a frame: the list is emptied and the page background set. */
void host_begin(uint32_t background) {
  for (size_t i = 0; i < g_count; i++) free(g_cmds[i].text);
  g_count = 0;
  g_background = background;
}

void host_clip_push(int32_t serial, int32_t pkind, double x, double y, double w, double h, double radius) {
  (void)serial;
  (void)pkind;
  Cmd *c = push_cmd();
  c->kind = CMD_CLIP;
  c->x = x;
  c->y = y;
  c->w = w;
  c->h = h;
  c->radius = radius;
}

void host_clip_pop(void) { push_cmd()->kind = CMD_UNCLIP; }

/** Restores the state a transform pushed, the same way a clip's pop does. */
void host_state_pop(void) { push_cmd()->kind = CMD_UNCLIP; }

/** Multiplies the user space of everything drawn until the matching pop by a CSS transform. */
void host_transform_push(int32_t serial, int32_t pkind, double a, double b, double c, double d, double e, double f) {
  (void)serial;
  (void)pkind;
  Cmd *cmd = push_cmd();
  cmd->kind = CMD_TRANSFORM;
  cmd->p0 = a;
  cmd->p1 = b;
  cmd->p2 = c;
  cmd->p3 = d;
  cmd->r[0] = e;
  cmd->r[1] = f;
}

/** The handle a recorded command answers to: its place in the frame's list, plus one. */
static int32_t command_handle(const Cmd *c) { return (int32_t)(c - g_cmds) + 1; }

/**
 * The same transform, returning the handle an animation moves by: this host draws every frame from
 * its list and has no retained layers, so a handle is the command's place in that list.
 */
int32_t host_transform_push_indexed(int32_t serial, int32_t pkind, double a, double b, double c, double d,
                                    double e, double f) {
  host_transform_push(serial, pkind, a, b, c, d, e, f);
  Cmd *cmd = &g_cmds[g_count - 1];
  cmd->handle = command_handle(cmd);
  return cmd->handle;
}

/** The command a handle names, or NULL when the frame the handle came from is gone. */
static Cmd *command_at(int32_t handle) {
  if (handle <= 0 || (size_t)handle > g_count) return NULL;
  Cmd *c = &g_cmds[handle - 1];
  return c->handle == handle ? c : NULL;
}

/** Moves a recorded transform to a new matrix, and a recorded opacity group to a new alpha. */
int32_t host_update_transform(int32_t handle, double a, double b, double c, double d, double e, double f) {
  Cmd *cmd = command_at(handle);
  if (cmd == NULL || cmd->kind != CMD_TRANSFORM) return 0;
  cmd->p0 = a;
  cmd->p1 = b;
  cmd->p2 = c;
  cmd->p3 = d;
  cmd->r[0] = e;
  cmd->r[1] = f;
  return 1;
}

int32_t host_update_opacity(int32_t handle, double alpha) {
  Cmd *cmd = command_at(handle);
  if (cmd == NULL || cmd->kind != CMD_EFFECT_PUSH) return 0;
  cmd->alpha_override = 1;
  cmd->alpha = alpha;
  return 1;
}

/** A layer group: this host has no compositor, so the frame stays one flat list and a layer holds
 *  nothing of its own. The runtime asks how many there are, and gets none. */
void host_layer_push(int32_t serial, int32_t kind) {
  (void)serial;
  (void)kind;
}

void host_layer_pop(void) {}

int32_t host_layer_count(void) { return 0; }

void host_fill_rect(double x, double y, double w, double h, double radius, uint32_t color) {
  Cmd *c = push_cmd();
  c->kind = CMD_FILL;
  c->x = x;
  c->y = y;
  c->w = w;
  c->h = h;
  c->radius = radius;
  c->color = color;
}

/** A text-decoration line from x0 to x1, `thickness` tall, whose top edge is `y`. */
void host_fill_line(double x0, double x1, double y, double thickness, uint32_t color, double style) {
  Cmd *c = push_cmd();
  c->kind = CMD_LINE;
  c->x = x0;
  c->w = x1 - x0;
  c->y = y;
  c->line_width = thickness;
  c->color = color;
  c->radius = style;
}

void host_fill_ring(double x, double y, double w, double h, double radius, double line_width,
                    uint32_t color) {
  Cmd *c = push_cmd();
  c->kind = CMD_RING;
  c->x = x;
  c->y = y;
  c->w = w;
  c->h = h;
  c->radius = radius;
  c->line_width = line_width;
  c->color = color;
}

/** A filled polygon (or several, as one path): "x,y x,y x,y" points, subpaths separated by ';'. */
void host_fill_poly(const uint8_t *s, size_t n, uint32_t color) {
  Cmd *c = push_cmd();
  c->kind = CMD_POLY;
  c->color = color;
  copy_text(c, s, n);
}

void host_clip_push_poly(int32_t serial, int32_t pkind, const uint8_t *s, size_t n) {
  (void)serial;
  (void)pkind;
  Cmd *c = push_cmd();
  c->kind = CMD_CLIP_POLY;
  copy_text(c, s, n);
}

void host_clip_push_ellipse(int32_t serial, int32_t pkind, double cx, double cy, double rx, double ry) {
  (void)serial;
  (void)pkind;
  Cmd *c = push_cmd();
  c->kind = CMD_CLIP_ELLIPSE;
  c->p0 = cx;
  c->p1 = cy;
  c->p2 = rx;
  c->p3 = ry;
}

/** Clips to one or more closed subpaths, even-odd when `evenodd` is set. */
void host_clip_push_shape(int32_t serial, int32_t pkind, const uint8_t *s, size_t n, double evenodd) {
  (void)serial;
  (void)pkind;
  Cmd *c = push_cmd();
  c->kind = CMD_CLIP_SHAPE;
  c->p0 = evenodd;
  copy_text(c, s, n);
}

void host_fill_round_rect(double x, double y, double w, double h, double tlx, double tly,
                          double trx, double try_, double brx, double bry, double blx, double bly,
                          uint32_t color) {
  Cmd *c = push_cmd();
  c->kind = CMD_FILL_ROUND;
  c->x = x;
  c->y = y;
  c->w = w;
  c->h = h;
  c->color = color;
  set_radii(c, tlx, tly, trx, try_, brx, bry, blx, bly);
}

void host_fill_round_ring(double x, double y, double w, double h, double tlx, double tly,
                          double trx, double try_, double brx, double bry, double blx, double bly,
                          double line_width, uint32_t color) {
  Cmd *c = push_cmd();
  c->kind = CMD_RING_ROUND;
  c->x = x;
  c->y = y;
  c->w = w;
  c->h = h;
  c->line_width = line_width;
  c->color = color;
  set_radii(c, tlx, tly, trx, try_, brx, bry, blx, bly);
}

void host_clip_push_round(int32_t serial, int32_t pkind, double x, double y, double w, double h,
                          double tlx, double tly,
                          double trx, double try_, double brx, double bry, double blx, double bly) {
  Cmd *c = push_cmd();
  c->kind = CMD_CLIP_ROUND;
  c->x = x;
  c->y = y;
  c->w = w;
  c->h = h;
  set_radii(c, tlx, tly, trx, try_, brx, bry, blx, bly);
}

void host_shadow_outer(double x, double y, double w, double h, double tlx, double tly, double trx,
                       double try_, double brx, double bry, double blx, double bly, double dx,
                       double dy, double blur, double spread, uint32_t color) {
  Cmd *c = push_cmd();
  c->kind = CMD_SHADOW;
  c->x = x;
  c->y = y;
  c->w = w;
  c->h = h;
  c->dx = dx;
  c->dy = dy;
  c->blur = blur;
  c->line_width = spread;
  c->color = color;
  set_radii(c, tlx, tly, trx, try_, brx, bry, blx, bly);
}

void host_shadow_inset(double x, double y, double w, double h, double tlx, double tly, double trx,
                       double try_, double brx, double bry, double blx, double bly, double dx,
                       double dy, double blur, double spread, uint32_t color) {
  Cmd *c = push_cmd();
  c->kind = CMD_SHADOW_INSET;
  c->x = x;
  c->y = y;
  c->w = w;
  c->h = h;
  c->dx = dx;
  c->dy = dy;
  c->blur = blur;
  c->line_width = spread;
  c->color = color;
  set_radii(c, tlx, tly, trx, try_, brx, bry, blx, bly);
}

// Video: this host has no decoder yet, so a <video> has no player and the runtime reports the
// element as unsupported. The macOS host in host/macos.m is the implementation.
int32_t host_video_open(const uint8_t *path, size_t n) { (void)path; (void)n; return -1; }
void host_video_close(int32_t id) { (void)id; }
void host_video_play(int32_t id) { (void)id; }
void host_video_pause(int32_t id) { (void)id; }
void host_video_seek(int32_t id, double time) { (void)id; (void)time; }
double host_video_time(int32_t id) { (void)id; return 0; }
double host_video_duration(int32_t id) { (void)id; return -1; }
double host_video_width(int32_t id) { (void)id; return 0; }
double host_video_height(int32_t id) { (void)id; return 0; }
int32_t host_video_ready(int32_t id) { (void)id; return -1; }
void host_video_set_volume(int32_t id, double volume) { (void)id; (void)volume; }
void host_video_set_muted(int32_t id, int32_t muted) { (void)id; (void)muted; }
void host_video_set_rate(int32_t id, double rate) { (void)id; (void)rate; }
int32_t host_video_can_play(const uint8_t *type, size_t n) { (void)type; (void)n; return 0; }
void host_video_draw(int32_t id, double x, double y, double w, double h, double alpha) {
  (void)id; (void)x; (void)y; (void)w; (void)h; (void)alpha;
}

void host_image_draw(int32_t id, double x, double y, double w, double h, double alpha, double smooth) {
  if (id < 0) return;
  Cmd *c = push_cmd();
  c->kind = CMD_IMAGE;
  c->image = id;
  c->x = x;
  c->y = y;
  c->w = w;
  c->h = h;
  c->size = alpha;
  c->smooth = smooth > 0.5;
}

void host_image_draw_part(int32_t id, double x, double y, double w, double h, double sx, double sy,
                          double sw, double sh, double alpha, double smooth) {
  if (id < 0) return;
  Cmd *c = push_cmd();
  c->kind = CMD_IMAGE;
  c->image = id;
  c->x = x;
  c->y = y;
  c->w = w;
  c->h = h;
  c->size = alpha;
  c->smooth = smooth > 0.5;
  c->sx = sx;
  c->sy = sy;
  c->sw = sw;
  c->sh = sh;
}

void host_gradient_linear(double x, double y, double w, double h, double x0, double y0, double x1,
                          double y1, const uint8_t *stops, size_t n, double alpha) {
  Cmd *c = push_cmd();
  c->kind = CMD_GRADIENT_LINEAR;
  c->x = x;
  c->y = y;
  c->w = w;
  c->h = h;
  c->p0 = x0;
  c->p1 = y0;
  c->p2 = x1;
  c->p3 = y1;
  c->size = alpha;
  copy_text(c, stops, n);
}

void host_gradient_radial(double x, double y, double w, double h, double cx, double cy, double rx,
                          double ry, const uint8_t *stops, size_t n, double alpha) {
  Cmd *c = push_cmd();
  c->kind = CMD_GRADIENT_RADIAL;
  c->x = x;
  c->y = y;
  c->w = w;
  c->h = h;
  c->p0 = cx;
  c->p1 = cy;
  c->p2 = rx;
  c->p3 = ry;
  c->size = alpha;
  copy_text(c, stops, n);
}

void host_gradient_conic(double x, double y, double w, double h, double cx, double cy, double angle,
                         const uint8_t *stops, size_t n, double alpha) {
  Cmd *c = push_cmd();
  c->kind = CMD_GRADIENT_CONIC;
  c->x = x;
  c->y = y;
  c->w = w;
  c->h = h;
  c->p0 = cx;
  c->p1 = cy;
  c->p2 = angle;
  c->size = alpha;
  copy_text(c, stops, n);
}

void host_text(const uint8_t *s, size_t n, double x, double y, double line_height, double size,
               double weight, uint32_t color, double letter, double word, uint32_t emphasis,
               uint32_t emphasis_color) {
  Cmd *c = push_cmd();
  c->kind = CMD_TEXT;
  c->x = x;
  c->y = y;
  c->line_height = line_height;
  c->size = size;
  c->weight = weight;
  c->color = color;
  c->letter = letter;
  c->word = word;
  c->emphasis = emphasis;
  c->emphasis_color = emphasis_color;
  copy_text(c, s, n);
}

void host_text_shadow(const uint8_t *s, size_t n, double x, double y, double line_height,
                      double size, double weight, uint32_t color, uint32_t shadow_color,
                      double letter, double word, double dx, double dy, double blur,
                      uint32_t emphasis, uint32_t emphasis_color) {
  Cmd *c = push_cmd();
  c->kind = CMD_TEXT_SHADOW;
  c->x = x;
  c->y = y;
  c->line_height = line_height;
  c->size = size;
  c->weight = weight;
  c->color = color;
  c->shadow_color = shadow_color;
  c->letter = letter;
  c->word = word;
  c->dx = dx;
  c->dy = dy;
  c->blur = blur;
  c->emphasis = emphasis;
  c->emphasis_color = emphasis_color;
  copy_text(c, s, n);
}

void host_mask_push(int32_t serial, int32_t pkind, double x, double y, double w, double h) {
  (void)serial;
  (void)pkind;
  Cmd *c = push_cmd();
  c->kind = CMD_MASK_PUSH;
  c->x = x;
  c->y = y;
  c->w = w;
  c->h = h;
}

void host_mask_split(void) { push_cmd()->kind = CMD_MASK_SPLIT; }
void host_mask_pop(void) { push_cmd()->kind = CMD_MASK_POP; }

void host_effect_push(int32_t serial, int32_t pkind, double x, double y, double w, double h, const uint8_t *spec,
                      size_t n) {
  (void)serial;
  (void)pkind;
  Cmd *c = push_cmd();
  c->kind = CMD_EFFECT_PUSH;
  c->x = x;
  c->y = y;
  c->w = w;
  c->h = h;
  copy_text(c, spec, n);
}

void host_effect_pop(void) { push_cmd()->kind = CMD_EFFECT_POP; }

/** The same effect group, returning the handle an animation moves by. */
int32_t host_effect_push_indexed(int32_t serial, int32_t pkind, double x, double y, double w, double h,
                                 const uint8_t *spec, size_t n) {
  host_effect_push(serial, pkind, x, y, w, h, spec, n);
  Cmd *cmd = &g_cmds[g_count - 1];
  cmd->handle = command_handle(cmd);
  return cmd->handle;
}

void host_perspective_push(int32_t serial, int32_t pkind, double x, double y, double w, double h, double x0,
                           double y0, double x1, double y1, double x2, double y2, double x3, double y3) {
  (void)serial;
  (void)pkind;
  Cmd *c = push_cmd();
  c->kind = CMD_PERSPECTIVE_PUSH;
  c->x = x;
  c->y = y;
  c->w = w;
  c->h = h;
  c->q[0] = x0;
  c->q[1] = y0;
  c->q[2] = x1;
  c->q[3] = y1;
  c->q[4] = x2;
  c->q[5] = y2;
  c->q[6] = x3;
  c->q[7] = y3;
}

void host_perspective_pop(void) { push_cmd()->kind = CMD_PERSPECTIVE_POP; }

}  // extern "C"

// ---------------------------------------------------------------------------
// Fonts
//
// A packed font key (fontKey in runtime/style.ts) carries the feature run in its millions, the
// family in its ten-thousands, 1000 for italic and the CSS weight below that. The families the
// page doesn't bring a file for are the system's own, by the names Windows gives those roles.

#define FF_CUSTOM 7

/** The face of one @font-face: the file it came from, the family id and the range it covers. */
typedef struct {
  int loaded;
  int family;  // the family id minus FF_CUSTOM
  double lo, hi;
  int italic;
  IDWriteFontFace *face;
  DWRITE_FONT_METRICS metrics;
  char *path;
} Face;

#define MAX_FACES 256
static Face g_faces[MAX_FACES];
static int g_face_count = 0;

/** A system family name the page asked for by role, mapped to a custom family id. */
typedef struct {
  int family;
  wchar_t name[128];
} NamedFamily;
static NamedFamily g_named[64];
static int g_named_count = 0;

static IDWriteFactory *g_dw = NULL;
static IDWriteFontCollection *g_system_fonts = NULL;

static int ensure_text(void) {
  if (!g_dw) {
    if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                   (IUnknown **)&g_dw)))
      return 0;
  }
  if (!g_system_fonts) {
    if (FAILED(g_dw->GetSystemFontCollection(&g_system_fonts, FALSE))) return 0;
  }
  return 1;
}

/** The Windows family behind each of the CSS generic families. */
static const wchar_t *system_family_name(int family) {
  switch (family) {
    case 1: return L"Consolas";
    case 2: return L"Times New Roman";
    case 3: return L"Cambria";
    case 4: return L"Segoe UI";
    case 5: return L"Consolas";
    // `sans-serif`: Chrome's Windows standard sans, not the system UI face.
    case 6: return L"Arial";
    default: return L"Segoe UI";
  }
}

static void split_weight(double weight, int *family, double *w, int *italic) {
  double pack = weight - floor(weight / 10000000.0) * 10000000.0;
  double fam = floor(pack / 10000.0);
  double rest = pack - fam * 10000.0;
  *italic = rest >= 1000 ? 1 : 0;
  *w = *italic ? rest - 1000 : rest;
  *family = (int)fam;
}

static DWRITE_FONT_WEIGHT dw_weight(double w) {
  int nearest = 400;
  if (w <= 100) nearest = 100;
  else if (w <= 200) nearest = 200;
  else if (w <= 300) nearest = 300;
  else if (w <= 400) nearest = 400;
  else if (w <= 500) nearest = 500;
  else if (w <= 600) nearest = 600;
  else if (w <= 700) nearest = 700;
  else if (w <= 800) nearest = 800;
  else nearest = 900;
  return (DWRITE_FONT_WEIGHT)nearest;
}

/** The file-backed face a family gives a weight and style, as CSS's font matching picks it. */
static Face *face_for(double weight) {
  int family_id = 0;
  double w = 400;
  int italic = 0;
  split_weight(weight, &family_id, &w, &italic);
  int family = family_id - FF_CUSTOM;
  Face *best = NULL;
  double best_dist = 0;
  for (int i = 0; i < g_face_count; i++) {
    Face *f = &g_faces[i];
    if (!f->loaded || f->family != family) continue;
    double dist = (f->italic == italic ? 0 : 100000) +
                  (w < f->lo ? f->lo - w : w > f->hi ? w - f->hi : 0);
    if (!best || dist < best_dist) {
      best = f;
      best_dist = dist;
    }
  }
  return best;
}

/** One face picked to draw a run: the DirectWrite face and its metrics. */
typedef struct {
  IDWriteFontFace *face;
  DWRITE_FONT_METRICS metrics;
} FontPick;

/** A system face kept once it was found, so a run of one family asks the system once. */
typedef struct {
  wchar_t name[128];
  int weight;
  int italic;
  IDWriteFontFace *face;
  DWRITE_FONT_METRICS metrics;
} CachedFace;
static CachedFace g_cache[64];
static int g_cache_count = 0;

/** The system family name to draw a family id with: the standard one, or the page's alias. */
static const wchar_t *family_name(int family_id) {
  if (family_id >= FF_CUSTOM) {
    for (int i = 0; i < g_named_count; i++) {
      if (g_named[i].family == family_id) return g_named[i].name;
    }
  }
  return system_family_name(family_id);
}

static FontPick pick_font(double weight) {
  FontPick pick = {NULL, {0}};
  int family_id = 0;
  double w = 400;
  int italic = 0;
  split_weight(weight, &family_id, &w, &italic);
  Face *face = family_id >= FF_CUSTOM ? face_for(weight) : NULL;
  if (face) {
    pick.face = face->face;
    pick.metrics = face->metrics;
    return pick;
  }
  if (!ensure_text()) return pick;
  const wchar_t *name = family_name(family_id);
  int bucket = (int)dw_weight(w);
  for (int i = 0; i < g_cache_count; i++) {
    CachedFace *c = &g_cache[i];
    if (c->weight == bucket && c->italic == italic && wcscmp(c->name, name) == 0) {
      pick.face = c->face;
      pick.metrics = c->metrics;
      return pick;
    }
  }
  UINT32 index = 0;
  BOOL found = FALSE;
  if (FAILED(g_system_fonts->FindFamilyName(name, &index, &found)) || !found) {
    // A family this system doesn't have: the nearest one it does, in the order a browser tries.
    static const wchar_t *fallbacks[] = {L"Segoe UI", L"Arial", L"Tahoma", L"Liberation Sans",
                                         L"DejaVu Sans"};
    found = FALSE;
    for (const wchar_t *candidate : fallbacks) {
      if (SUCCEEDED(g_system_fonts->FindFamilyName(candidate, &index, &found)) && found) {
        name = candidate;
        break;
      }
    }
    if (!found) {
      // Nothing by name at all: the collection's first family is still a face to draw with.
      index = 0;
      if (g_system_fonts->GetFontFamilyCount() == 0) return pick;
    }
  }
  IDWriteFontFamily *family = NULL;
  if (FAILED(g_system_fonts->GetFontFamily(index, &family)) || !family) return pick;
  IDWriteFont *font = NULL;
  HRESULT hr = family->GetFirstMatchingFont(
      dw_weight(w), DWRITE_FONT_STRETCH_NORMAL,
      italic ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL, &font);
  IDWriteFontFace *dwface = NULL;
  DWRITE_FONT_METRICS metrics = {0};
  if (SUCCEEDED(hr) && font) {
    font->CreateFontFace(&dwface);
    font->GetMetrics(&metrics);
    font->Release();
  }
  family->Release();
  if (!dwface) return pick;
  if (g_cache_count < (int)(sizeof(g_cache) / sizeof(g_cache[0]))) {
    CachedFace *c = &g_cache[g_cache_count++];
    wcsncpy(c->name, name, 127);
    c->name[127] = 0;
    c->weight = bucket;
    c->italic = italic;
    c->face = dwface;
    c->metrics = metrics;
  }
  pick.face = dwface;
  pick.metrics = metrics;
  return pick;
}

static double em_of(const DWRITE_FONT_METRICS *m) {
  return m->designUnitsPerEm > 0 ? (double)m->designUnitsPerEm : 1000.0;
}

/** A code point's glyph in a face, or 0 when the face has none. */
static UINT16 glyph_of(IDWriteFontFace *face, uint32_t cp) {
  if (!face || cp > 0x10ffff) return 0;
  if (cp >= 0x10000) {
    // Beyond the BMP a glyph is asked for by its surrogate pair; the first unit carries it.
    uint32_t units[2];
    units[0] = 0xd800 + ((cp - 0x10000) >> 10);
    units[1] = 0xdc00 + ((cp - 0x10000) & 0x3ff);
    UINT16 glyphs[2] = {0, 0};
    face->GetGlyphIndices(units, 2, glyphs);
    return glyphs[0];
  }
  UINT16 glyph = 0;
  face->GetGlyphIndices(&cp, 1, &glyph);
  return glyph;
}

/** How far a code point moves the pen at this size, from the face's own design advances. */
static double glyph_advance(IDWriteFontFace *face, const DWRITE_FONT_METRICS *m, uint32_t cp, double size) {
  if (!face) return size * 0.5;
  UINT16 glyph = glyph_of(face, cp);
  DWRITE_GLYPH_METRICS gm = {0};
  face->GetDesignGlyphMetrics(&glyph, 1, &gm, FALSE);
  double scale = size / em_of(m);
  return (double)gm.advanceWidth * scale;
}

/** A face by family name, found once and kept: the faces a run falls back to. */
static IDWriteFontFace *named_face(const wchar_t *name) {
  static wchar_t cache_names[16][64];
  static IDWriteFontFace *cache_faces[16];
  static int cache_count = 0;
  for (int i = 0; i < cache_count; i++) {
    if (wcscmp(cache_names[i], name) == 0) return cache_faces[i];
  }
  if (!ensure_text()) return NULL;
  UINT32 index = 0;
  BOOL found = FALSE;
  if (FAILED(g_system_fonts->FindFamilyName(name, &index, &found)) || !found) return NULL;
  IDWriteFontFamily *family = NULL;
  if (FAILED(g_system_fonts->GetFontFamily(index, &family)) || !family) return NULL;
  IDWriteFont *font = NULL;
  IDWriteFontFace *face = NULL;
  if (SUCCEEDED(family->GetFirstMatchingFont(DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                                            DWRITE_FONT_STYLE_NORMAL, &font)) &&
      font) {
    font->CreateFontFace(&face);
    font->Release();
  }
  family->Release();
  if (face && cache_count < 16) {
    wcsncpy(cache_names[cache_count], name, 63);
    cache_names[cache_count][63] = 0;
    cache_faces[cache_count] = face;
    cache_count++;
  }
  return face;
}

/**
 * The face to draw a character the run's own face has none of. Windows puts characters outside a
 * family's coverage in its symbol and CJK faces, which is the fallback the platform's own text
 * stack asks for; a character none of them has is left undrawn, though the pen still advances by
 * the layout's measure of it.
 */
static IDWriteFontFace *fallback_face(uint32_t cp) {
  static const wchar_t *families[] = {
      L"Segoe UI Emoji", L"Segoe UI Symbol", L"Microsoft YaHei", L"Yu Gothic",
      L"Malgun Gothic", L"Arial Unicode MS", L"Segoe UI",
  };
  for (const wchar_t *name : families) {
    IDWriteFontFace *face = named_face(name);
    if (face && glyph_of(face, cp) != 0) return face;
  }
  return NULL;
}

extern "C" {

// How long shaping text has taken since the frame line last asked: the share of a layout that is
// measuring text. Only a run that asks for frame timings pays to read the clock.
static double g_text_shape_ms = 0;

/** Milliseconds spent shaping text since the last call, for the frame line. */
double host_text_shape_time(void) {
  double ms = g_text_shape_ms;
  g_text_shape_ms = 0;
  return ms;
}

double host_measure_text(const uint8_t *s, size_t n, double size, double weight, double letter, double word) {
  double started = frame_times() ? now_ms() : 0;
  FontPick pick = pick_font(weight);
  double w = 0;
  int chars = 0, spaces = 0;
  size_t i = 0;
  uint32_t cp;
  while (utf8_next(s, n, &i, &cp)) {
    chars++;
    if (cp == ' ') spaces++;
    w += glyph_advance(pick.face, &pick.metrics, cp, size);
  }
  if (started != 0) g_text_shape_ms += now_ms() - started;
  return w + letter * chars + word * spaces;
}

double host_font_ascent(double size, double weight) {
  FontPick pick = pick_font(weight);
  if (!pick.face) return size * 0.9;
  return (double)pick.metrics.ascent * size / em_of(&pick.metrics);
}

double host_font_descent(double size, double weight) {
  FontPick pick = pick_font(weight);
  if (!pick.face) return size * 0.21;
  return (double)pick.metrics.descent * size / em_of(&pick.metrics);
}

double host_font_line_gap(double size, double weight) {
  FontPick pick = pick_font(weight);
  if (!pick.face) return 0;
  return (double)pick.metrics.lineGap * size / em_of(&pick.metrics);
}

double host_font_x_height(double size, double weight) {
  FontPick pick = pick_font(weight);
  if (!pick.face) return size * 0.5;
  IDWriteFontFace1 *face1 = NULL;
  DWRITE_FONT_METRICS1 m1 = {};
  if (SUCCEEDED(pick.face->QueryInterface(__uuidof(IDWriteFontFace1), (void **)&face1)) && face1) {
    face1->GetMetrics(&m1);
    face1->Release();
    if (m1.designUnitsPerEm > 0) return (double)m1.xHeight * size / (double)m1.designUnitsPerEm;
  }
  return size * 0.5;
}

double host_font_ascent_device(double size, double weight) { return round(host_font_ascent(size, weight)); }
double host_font_descent_device(double size, double weight) { return round(host_font_descent(size, weight)); }
double host_font_line_gap_device(double size, double weight) { return round(host_font_line_gap(size, weight)); }

void host_text_metrics(const uint8_t *s, size_t n, double size, double weight, double letter, double word,
                       metrics_cb cb) {
  FontPick pick = pick_font(weight);
  double m[7];
  m[0] = host_measure_text(s, n, size, weight, letter, word);
  m[1] = m[2] = m[3] = m[4] = 0;
  m[5] = host_font_ascent(size, weight);
  m[6] = host_font_descent(size, weight);
  if (pick.face) {
    double pen = 0, x_min = 0, x_max = 0, above = 0, below = 0;
    int ink = 0;
    double scale = size / em_of(&pick.metrics);
    size_t i = 0;
    uint32_t cp;
    while (utf8_next(s, n, &i, &cp)) {
      UINT16 glyph = glyph_of(pick.face, cp);
      DWRITE_GLYPH_METRICS gm = {0};
      pick.face->GetDesignGlyphMetrics(&glyph, 1, &gm, FALSE);
      double left = pen + (double)gm.leftSideBearing * scale;
      double right = pen + (double)(gm.advanceWidth - gm.rightSideBearing) * scale;
      if (!ink) {
        x_min = left;
        x_max = right;
        ink = 1;
      } else {
        if (left < x_min) x_min = left;
        if (right > x_max) x_max = right;
      }
      pen += glyph_advance(pick.face, &pick.metrics, cp, size) + letter;
      if (cp == ' ') pen += word;
    }
    if (ink) {
      m[1] = -x_min;
      m[2] = x_max;
      m[3] = above > 0 ? above : m[5];
      m[4] = below < 0 ? -below : m[6];
    }
  }
  cb((const uint8_t *)m, sizeof(m));
}

/** Drops the page's own faces and the system matches, as a new document does. */
void host_reset_fonts(void) {
  for (int i = 0; i < g_face_count; i++) {
    if (g_faces[i].face) g_faces[i].face->Release();
    free(g_faces[i].path);
    g_faces[i].loaded = 0;
  }
  g_face_count = 0;
  for (int i = 0; i < g_cache_count; i++) {
    if (g_cache[i].face) g_cache[i].face->Release();
  }
  g_cache_count = 0;
}

/** A face from a file the page brought, for the family the @font-face rule named. */
void host_register_font(const uint8_t *path, size_t path_len, double family, double lo, double hi,
                        double italic, const uint8_t *ranges, size_t ranges_len,
                        const uint8_t *features, size_t features_len, double stretch) {
  (void)ranges;
  (void)ranges_len;
  (void)features;
  (void)features_len;
  (void)stretch;
  if (g_face_count >= MAX_FACES || !ensure_text()) return;
  char name[4096];
  if (!copy_name_bytes(name, sizeof(name), path, path_len)) return;
  size_t wide_len = 0;
  wchar_t *wide = utf8_to_utf16((const uint8_t *)name, strlen(name), &wide_len);
  if (!wide) return;
  IDWriteFontFile *file = NULL;
  HRESULT hr = g_dw->CreateFontFileReference(wide, NULL, &file);
  free(wide);
  IDWriteFontFace *face = NULL;
  if (SUCCEEDED(hr) && file) {
    BOOL supported = FALSE;
    DWRITE_FONT_FILE_TYPE type;
    DWRITE_FONT_FACE_TYPE face_type;
    UINT32 faces = 0;
    if (SUCCEEDED(file->Analyze(&supported, &type, &face_type, &faces)) && supported) {
      hr = g_dw->CreateFontFace(face_type, 1, &file, 0, DWRITE_FONT_SIMULATIONS_NONE, &face);
    }
    file->Release();
  }
  if (!face) return;
  Face *f = &g_faces[g_face_count++];
  memset(f, 0, sizeof(*f));
  f->loaded = 1;
  f->family = (int)family - FF_CUSTOM;
  f->lo = lo;
  f->hi = hi;
  f->italic = italic != 0;
  f->face = face;
  face->GetMetrics(&f->metrics);
  f->path = dup_str(name);
}

/** A face the system already has, found by the family name the @font-face src named. */
int32_t host_register_font_local(const uint8_t *name, size_t name_len, double family, double lo,
                                 double hi, double italic, const uint8_t *ranges, size_t ranges_len,
                                 const uint8_t *features, size_t features_len, double stretch) {
  (void)ranges;
  (void)ranges_len;
  (void)features;
  (void)features_len;
  (void)stretch;
  if (g_face_count >= MAX_FACES || !ensure_text()) return 0;
  size_t wide_len = 0;
  wchar_t *wide = utf8_to_utf16(name, name_len, &wide_len);
  if (!wide) return 0;
  UINT32 index = 0;
  BOOL found = FALSE;
  if (FAILED(g_system_fonts->FindFamilyName(wide, &index, &found)) || !found) {
    free(wide);
    return 0;
  }
  IDWriteFontFamily *font_family = NULL;
  IDWriteFontFace *face = NULL;
  DWRITE_FONT_METRICS metrics = {0};
  if (SUCCEEDED(g_system_fonts->GetFontFamily(index, &font_family)) && font_family) {
    IDWriteFont *font = NULL;
    if (SUCCEEDED(font_family->GetFirstMatchingFont(
            dw_weight((lo + hi) / 2), DWRITE_FONT_STRETCH_NORMAL,
            italic != 0 ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL, &font)) &&
        font) {
      font->CreateFontFace(&face);
      font->GetMetrics(&metrics);
      font->Release();
    }
    font_family->Release();
  }
  free(wide);
  if (!face) return 0;
  Face *f = &g_faces[g_face_count++];
  memset(f, 0, sizeof(*f));
  f->loaded = 1;
  f->family = (int)family - FF_CUSTOM;
  f->lo = lo;
  f->hi = hi;
  f->italic = italic != 0;
  f->face = face;
  f->metrics = metrics;
  return 1;
}

/** A family the page names maps to one the system has, as font-family: ui-serif would. */
int32_t host_register_font_named(const uint8_t *name, size_t name_len, double family) {
  if (g_named_count >= (int)(sizeof(g_named) / sizeof(g_named[0]))) return 0;
  size_t wide_len = 0;
  wchar_t *wide = utf8_to_utf16(name, name_len, &wide_len);
  if (!wide) return 0;
  NamedFamily *n = &g_named[g_named_count++];
  n->family = (int)family;
  wcsncpy(n->name, wide, 127);
  n->name[127] = 0;
  free(wide);
  return 1;
}

/** OpenType feature settings a family asks for: the glyph run applies none, so none are recorded. */
double host_register_features(const uint8_t *spec, size_t spec_len) {
  (void)spec;
  (void)spec_len;
  return 0;
}

}  // extern "C"

// ---------------------------------------------------------------------------
// Geometry

/** A geometry being built: one path and the sink filling it, until finish_geometry. */
typedef struct {
  ID2D1PathGeometry *path;
  ID2D1GeometrySink *sink;
} Geo;

static void geo_begin(Geo *g, D2D1_FILL_MODE fill) {
  g->path = NULL;
  g->sink = NULL;
  if (!ensure_device()) return;
  if (FAILED(g_d2d_factory->CreatePathGeometry(&g->path)) || !g->path) return;
  if (FAILED(g->path->Open(&g->sink)) || !g->sink) {
    g->path->Release();
    g->path = NULL;
    return;
  }
  g->sink->SetFillMode(fill);
}

static ID2D1PathGeometry *geo_end(Geo *g) {
  if (!g->path || !g->sink) return NULL;
  g->sink->Close();
  g->sink->Release();
  g->sink = NULL;
  ID2D1PathGeometry *path = g->path;
  g->path = NULL;
  return path;
}

static void geo_ellipse(Geo *g, double cx, double cy, double rx, double ry) {
  if (!g->sink) return;
  g->sink->BeginFigure(D2D1::Point2F((float)(cx + rx), (float)cy), D2D1_FIGURE_BEGIN_FILLED);
  g->sink->AddArc(D2D1::ArcSegment(D2D1::Point2F((float)(cx - rx), (float)cy),
                                  D2D1::SizeF((float)rx, (float)ry), 0.0f,
                                  D2D1_SWEEP_DIRECTION_CLOCKWISE, D2D1_ARC_SIZE_LARGE));
  g->sink->AddArc(D2D1::ArcSegment(D2D1::Point2F((float)(cx + rx), (float)cy),
                                  D2D1::SizeF((float)rx, (float)ry), 0.0f,
                                  D2D1_SWEEP_DIRECTION_CLOCKWISE, D2D1_ARC_SIZE_LARGE));
  g->sink->EndFigure(D2D1_FIGURE_END_CLOSED);
}

/** A rounded rect whose corners may differ: r holds the radii top-left to bottom-left, x then y. */
static void geo_round_rect(Geo *g, double x, double y, double w, double h, const double r[8]) {
  if (!g->sink) return;
  if (w < 0) {
    x += w;
    w = -w;
  }
  if (h < 0) {
    y += h;
    h = -h;
  }
  double tlx = r[0] < 0 ? 0 : r[0], tly = r[1] < 0 ? 0 : r[1];
  double trx = r[2] < 0 ? 0 : r[2], try_ = r[3] < 0 ? 0 : r[3];
  double brx = r[4] < 0 ? 0 : r[4], bry = r[5] < 0 ? 0 : r[5];
  double blx = r[6] < 0 ? 0 : r[6], bly = r[7] < 0 ? 0 : r[7];
  double max_x = w / 2, max_y = h / 2;
  if (tlx > max_x) tlx = max_x;
  if (trx > max_x) trx = max_x;
  if (brx > max_x) brx = max_x;
  if (blx > max_x) blx = max_x;
  if (tly > max_y) tly = max_y;
  if (try_ > max_y) try_ = max_y;
  if (bry > max_y) bry = max_y;
  if (bly > max_y) bly = max_y;
  g->sink->BeginFigure(D2D1::Point2F((float)(x + tlx), (float)y), D2D1_FIGURE_BEGIN_FILLED);
  g->sink->AddLine(D2D1::Point2F((float)(x + w - trx), (float)y));
  if (trx > 0 || try_ > 0)
    g->sink->AddArc(D2D1::ArcSegment(D2D1::Point2F((float)(x + w), (float)(y + try_)),
                                    D2D1::SizeF((float)trx, (float)try_), 0.0f,
                                    D2D1_SWEEP_DIRECTION_CLOCKWISE, D2D1_ARC_SIZE_SMALL));
  g->sink->AddLine(D2D1::Point2F((float)(x + w), (float)(y + h - bry)));
  if (brx > 0 || bry > 0)
    g->sink->AddArc(D2D1::ArcSegment(D2D1::Point2F((float)(x + w - brx), (float)(y + h)),
                                    D2D1::SizeF((float)brx, (float)bry), 0.0f,
                                    D2D1_SWEEP_DIRECTION_CLOCKWISE, D2D1_ARC_SIZE_SMALL));
  g->sink->AddLine(D2D1::Point2F((float)(x + blx), (float)(y + h)));
  if (blx > 0 || bly > 0)
    g->sink->AddArc(D2D1::ArcSegment(D2D1::Point2F((float)x, (float)(y + h - bly)),
                                    D2D1::SizeF((float)blx, (float)bly), 0.0f,
                                    D2D1_SWEEP_DIRECTION_CLOCKWISE, D2D1_ARC_SIZE_SMALL));
  g->sink->AddLine(D2D1::Point2F((float)x, (float)(y + tly)));
  if (tlx > 0 || tly > 0)
    g->sink->AddArc(D2D1::ArcSegment(D2D1::Point2F((float)(x + tlx), (float)y),
                                    D2D1::SizeF((float)tlx, (float)tly), 0.0f,
                                    D2D1_SWEEP_DIRECTION_CLOCKWISE, D2D1_ARC_SIZE_SMALL));
  g->sink->EndFigure(D2D1_FIGURE_END_CLOSED);
}

/** The one radius the four corners share, or 0 when they differ. */
static double radii_uniform(const double r[8]) {
  double radius = r[0];
  if (r[1] != radius || r[2] != radius || r[3] != radius || r[4] != radius || r[5] != radius ||
      r[6] != radius || r[7] != radius)
    return 0;
  return radius > 0 ? radius : 0;
}

static void geo_uniform_round(Geo *g, double x, double y, double w, double h, double radius) {
  double r[8] = {radius, radius, radius, radius, radius, radius, radius, radius};
  geo_round_rect(g, x, y, w, h, r);
}

/** The next number of a point list, skipping to where one starts. */
static int next_point_number(const char *s, size_t n, size_t *at, double *out) {
  while (*at < n) {
    char ch = s[*at];
    if (ch == ' ' || ch == ',' || ch == '\t' || ch == '\n' || ch == '\r' || ch == ';') (*at)++;
    else break;
  }
  if (*at >= n) return 0;
  char *end = NULL;
  double v = strtod(s + *at, &end);
  if (end == s + *at) return 0;
  *at = (size_t)(end - s);
  *out = v;
  return 1;
}

/** Adds "x,y x,y x,y" points to a geometry, one closed figure per ';'-separated subpath. */
static void geo_points(Geo *g, const char *s, size_t n) {
  size_t at = 0;
  int open = 0;
  while (at < n) {
    double x = 0, y = 0;
    int have_x = next_point_number(s, n, &at, &x);
    if (!have_x) {
      at++;
      continue;
    }
    if (!next_point_number(s, n, &at, &y)) break;
    if (!open) {
      g->sink->BeginFigure(D2D1::Point2F((float)x, (float)y), D2D1_FIGURE_BEGIN_FILLED);
      open = 1;
    } else {
      g->sink->AddLine(D2D1::Point2F((float)x, (float)y));
    }
    // A ';' before the next point starts a new subpath.
    size_t look = at;
    while (look < n && (s[look] == ' ' || s[look] == '\t')) look++;
    if (look < n && s[look] == ';') {
      g->sink->EndFigure(D2D1_FIGURE_END_CLOSED);
      open = 0;
      at = look + 1;
    }
  }
  if (open) g->sink->EndFigure(D2D1_FIGURE_END_CLOSED);
}

// ---------------------------------------------------------------------------
// Filters
//
// A box with a filter paints its subtree into a layer of its own, the filter chain is applied to
// the layer's pixels, and the result is composited into the page. The chain is the one
// shared/props.ts numbers: blur, brightness, contrast, drop-shadow, grayscale, hue-rotate,
// invert, opacity, saturate and sepia. A backdrop chain filters what is painted behind the box,
// which this host does not do: the box's own layer draws unfiltered backdrop.

enum {
  FK_BLUR = 0, FK_BRIGHTNESS = 1, FK_CONTRAST = 2, FK_DROP_SHADOW = 3, FK_GRAYSCALE = 4,
  FK_HUE_ROTATE = 5, FK_INVERT = 6, FK_OPACITY = 7, FK_SATURATE = 8, FK_SEPIA = 9,
};

typedef struct {
  int kind;
  double a, dx, dy, blur;
  uint32_t color;
} FilterOp;

typedef struct {
  double alpha;
  int blend;
  int count;
  FilterOp ops[64];
  int bcount;
  FilterOp bops[64];
} EffectSpec;

static int read_filter_ops(FilterOp *ops, const char *q, char **end) {
  int count = (int)strtol(q, end, 10);
  q = *end;
  if (count < 0) count = 0;
  if (count > 64) count = 64;
  for (int i = 0; i < count; i++) {
    FilterOp *op = &ops[i];
    op->kind = (int)strtol(q, end, 10);
    q = *end;
    op->a = strtod(q, end);
    q = *end;
    op->dx = strtod(q, end);
    q = *end;
    op->dy = strtod(q, end);
    q = *end;
    op->blur = strtod(q, end);
    q = *end;
    op->color = (uint32_t)strtod(q, end);
    q = *end;
  }
  return count;
}

static void effect_spec_parse(EffectSpec *s, const char *text) {
  memset(s, 0, sizeof(*s));
  s->alpha = 1;
  if (!text) return;
  const char *q = text;
  char *end;
  s->alpha = strtod(q, &end);
  if (end == q) return;
  q = end;
  s->blend = (int)strtol(q, &end, 10);
  if (end == q) return;
  q = end;
  s->count = read_filter_ops(s->ops, q, &end);
  q = end;
  s->bcount = read_filter_ops(s->bops, q, &end);
}

/** One pixel of a filter layer: premultiplied, in floating point, 0..1. */
typedef struct {
  double r, g, b, a;
} FilterPixel;

/** A colour matrix in the order CSS filter functions write them (rows are the output's R, G, B). */
static void apply_colour_matrix(FilterPixel *px, size_t count, const double m[9]) {
  for (size_t i = 0; i < count; i++) {
    FilterPixel *p = &px[i];
    if (p->a <= 0) continue;
    double r = p->r / p->a, g = p->g / p->a, b = p->b / p->a;
    double nr = m[0] * r + m[1] * g + m[2] * b;
    double ng = m[3] * r + m[4] * g + m[5] * b;
    double nb = m[6] * r + m[7] * g + m[8] * b;
    nr = nr < 0 ? 0 : nr > 1 ? 1 : nr;
    ng = ng < 0 ? 0 : ng > 1 ? 1 : ng;
    nb = nb < 0 ? 0 : nb > 1 ? 1 : nb;
    p->r = nr * p->a;
    p->g = ng * p->a;
    p->b = nb * p->a;
  }
}

/** A box blur of every channel at once, three passes per axis. */
static void blur_pixels(FilterPixel *px, int w, int h, double sigma) {
  if (!(sigma > 0.3) || w < 1 || h < 1) return;
  int radius = (int)floor(sqrt(4.0 * sigma * sigma / 3.0 + 0.25) - 0.5);
  if (radius < 1) radius = 1;
  if (radius > 128) radius = 128;
  size_t n = (size_t)w * (size_t)h;
  FilterPixel *temp = (FilterPixel *)malloc(n * sizeof(FilterPixel));
  if (!temp) return;
  for (int pass = 0; pass < 3; pass++) {
    for (int y = 0; y < h; y++) {
      FilterPixel *row = px + (size_t)y * (size_t)w;
      FilterPixel *out = temp + (size_t)y * (size_t)w;
      for (int x = 0; x < w; x++) {
        FilterPixel sum = {0, 0, 0, 0};
        for (int k = -radius; k <= radius; k++) {
          int sx = x + k;
          if (sx < 0) sx = 0;
          if (sx >= w) sx = w - 1;
          sum.r += row[sx].r;
          sum.g += row[sx].g;
          sum.b += row[sx].b;
          sum.a += row[sx].a;
        }
        int size = radius * 2 + 1;
        out[x].r = sum.r / size;
        out[x].g = sum.g / size;
        out[x].b = sum.b / size;
        out[x].a = sum.a / size;
      }
    }
    memcpy(px, temp, n * sizeof(FilterPixel));
    for (int x = 0; x < w; x++) {
      for (int y = 0; y < h; y++) {
        FilterPixel sum = {0, 0, 0, 0};
        for (int k = -radius; k <= radius; k++) {
          int sy = y + k;
          if (sy < 0) sy = 0;
          if (sy >= h) sy = h - 1;
          const FilterPixel *src = px + (size_t)sy * (size_t)w + (size_t)x;
          sum.r += src->r;
          sum.g += src->g;
          sum.b += src->b;
          sum.a += src->a;
        }
        int size = radius * 2 + 1;
        temp[(size_t)y * (size_t)w + (size_t)x].r = sum.r / size;
        temp[(size_t)y * (size_t)w + (size_t)x].g = sum.g / size;
        temp[(size_t)y * (size_t)w + (size_t)x].b = sum.b / size;
        temp[(size_t)y * (size_t)w + (size_t)x].a = sum.a / size;
      }
    }
    memcpy(px, temp, n * sizeof(FilterPixel));
  }
  free(temp);
}

/** Composites a drop shadow of `px` under it: the box's own alpha, blurred, offset and tinted. */
static void filter_drop_shadow(FilterPixel *px, int w, int h, const FilterOp *op, double scale) {
  size_t n = (size_t)w * (size_t)h;
  FilterPixel *shadow = (FilterPixel *)calloc(n, sizeof(FilterPixel));
  if (!shadow) return;
  for (size_t i = 0; i < n; i++) shadow[i].a = px[i].a;
  blur_pixels(shadow, w, h, op->blur * scale / 2);
  int dx = (int)lround(op->dx * scale), dy = (int)lround(op->dy * scale);
  double sr = ((op->color >> 24) & 255) / 255.0;
  double sg = ((op->color >> 16) & 255) / 255.0;
  double sb = ((op->color >> 8) & 255) / 255.0;
  double sa = (op->color & 255) / 255.0;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      int sx = x - dx, sy = y - dy;
      double a = 0;
      if (sx >= 0 && sy >= 0 && sx < w && sy < h) a = shadow[(size_t)sy * (size_t)w + (size_t)sx].a * sa;
      FilterPixel *p = &px[(size_t)y * (size_t)w + (size_t)x];
      double under = 1 - p->a;
      p->r = p->r + sr * a * under;
      p->g = p->g + sg * a * under;
      p->b = p->b + sb * a * under;
      p->a = p->a + a * under;
    }
  }
  free(shadow);
}

/** Runs a filter chain over a layer's pixels. */
static void apply_filters(FilterPixel *px, int w, int h, const FilterOp *ops, int count, double scale) {
  for (int i = 0; i < count; i++) {
    const FilterOp *op = &ops[i];
    size_t n = (size_t)w * (size_t)h;
    switch (op->kind) {
      case FK_BLUR:
        blur_pixels(px, w, h, op->a * scale / 2);
        break;
      case FK_BRIGHTNESS: {
        double m[9] = {op->a, 0, 0, 0, op->a, 0, 0, 0, op->a};
        apply_colour_matrix(px, n, m);
        break;
      }
      case FK_CONTRAST: {
        double slope = op->a, off = -(0.5 * op->a) + 0.5;
        for (size_t k = 0; k < n; k++) {
          if (px[k].a <= 0) continue;
          double r = px[k].r / px[k].a, g = px[k].g / px[k].a, b = px[k].b / px[k].a;
          r = fmin(1, fmax(0, r * slope + off));
          g = fmin(1, fmax(0, g * slope + off));
          b = fmin(1, fmax(0, b * slope + off));
          px[k].r = r * px[k].a;
          px[k].g = g * px[k].a;
          px[k].b = b * px[k].a;
        }
        break;
      }
      case FK_GRAYSCALE: {
        double a = op->a;
        double m[9] = {0.2126 + 0.7874 * (1 - a), 0.7152 - 0.7152 * (1 - a), 0.0722 - 0.0722 * (1 - a),
                       0.2126 - 0.2126 * (1 - a), 0.7152 + 0.2848 * (1 - a), 0.0722 - 0.0722 * (1 - a),
                       0.2126 - 0.2126 * (1 - a), 0.7152 - 0.7152 * (1 - a), 0.0722 + 0.9278 * (1 - a)};
        apply_colour_matrix(px, n, m);
        break;
      }
      case FK_SEPIA: {
        double a = op->a;
        double m[9] = {0.393 + 0.607 * (1 - a), 0.769 - 0.769 * (1 - a), 0.189 - 0.189 * (1 - a),
                       0.349 - 0.349 * (1 - a), 0.686 + 0.314 * (1 - a), 0.168 - 0.168 * (1 - a),
                       0.272 - 0.272 * (1 - a), 0.534 - 0.534 * (1 - a), 0.131 + 0.869 * (1 - a)};
        apply_colour_matrix(px, n, m);
        break;
      }
      case FK_SATURATE: {
        double a = op->a;
        double m[9] = {0.213 + 0.787 * a, 0.715 - 0.715 * a, 0.072 - 0.072 * a,
                       0.213 - 0.213 * a, 0.715 + 0.285 * a, 0.072 - 0.072 * a,
                       0.213 - 0.213 * a, 0.715 - 0.715 * a, 0.072 + 0.928 * a};
        apply_colour_matrix(px, n, m);
        break;
      }
      case FK_HUE_ROTATE: {
        double angle = op->a * M_PI / 180.0;
        double c = cos(angle), s = sin(angle);
        double m[9] = {0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715,
                       0.072 - c * 0.072 + s * 0.928,
                       0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140,
                       0.072 - c * 0.072 - s * 0.283,
                       0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715,
                       0.072 + c * 0.928 + s * 0.072};
        apply_colour_matrix(px, n, m);
        break;
      }
      case FK_INVERT:
        for (size_t k = 0; k < n; k++) {
          if (px[k].a <= 0) continue;
          double r = px[k].r / px[k].a, g = px[k].g / px[k].a, b = px[k].b / px[k].a;
          double a = op->a;
          r = r * (1 - a) + (1 - r) * a;
          g = g * (1 - a) + (1 - g) * a;
          b = b * (1 - a) + (1 - b) * a;
          px[k].r = r * px[k].a;
          px[k].g = g * px[k].a;
          px[k].b = b * px[k].a;
        }
        break;
      case FK_OPACITY:
        for (size_t k = 0; k < n; k++) {
          double a = op->a;
          px[k].r *= a;
          px[k].g *= a;
          px[k].b *= a;
          px[k].a *= a;
        }
        break;
      case FK_DROP_SHADOW:
        filter_drop_shadow(px, w, h, op, scale);
        break;
      default:
        break;
    }
  }
}

/** How far, in DIPs, a composited chunk's raster is translated from the page's own space. */


/** The surfaces effect layers render into, one per nesting depth. */
typedef struct {
  ID2D1DeviceContext *dc;
  ID2D1Bitmap1 *bitmap;
  int w, h;
} LayerSurface;
static LayerSurface g_layer_surfaces[8];
static int g_layer_depth = 0;

static LayerSurface *layer_surface(int depth, int w, int h) {
  if (!ensure_device() || !g_d2d_device || depth < 0 || depth >= 8 || w < 1 || h < 1) return NULL;
  LayerSurface *s = &g_layer_surfaces[depth];
  int cap_w = 1, cap_h = 1;
  while (cap_w < w && cap_w < 8192) cap_w *= 2;
  while (cap_h < h && cap_h < 8192) cap_h *= 2;
  if (cap_w < w) cap_w = w;
  if (cap_h < h) cap_h = h;
  if (s->dc && s->bitmap && s->w >= w && s->h >= h) return s;
  if (s->dc) {
    s->dc->SetTarget(NULL);
    s->dc->Release();
    s->dc = NULL;
  }
  if (s->bitmap) {
    s->bitmap->Release();
    s->bitmap = NULL;
  }
  D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
      D2D1_BITMAP_OPTIONS_TARGET,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
      96.0f * (float)g_scale, 96.0f * (float)g_scale);
  if (FAILED(g_d2d->CreateBitmap(D2D1::SizeU((UINT32)cap_w, (UINT32)cap_h), NULL, 0, &props, &s->bitmap)) ||
      !s->bitmap)
    return NULL;
  if (FAILED(g_d2d_device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &s->dc)) || !s->dc)
    return NULL;
  s->dc->SetTarget(s->bitmap);
  s->dc->SetDpi(96.0f * (float)g_scale, 96.0f * (float)g_scale);
  s->dc->SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
  s->dc->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  s->w = cap_w;
  s->h = cap_h;
  return s;
}

// ---------------------------------------------------------------------------
// Replay

/** The bitmap a canvas paints into, for the page's replay; NULL when it has none. */
static ID2D1Bitmap1 *canvas_bitmap(int32_t id);
static void gl_present_canvas_for(int32_t id);
static void gl_resize_canvas(int32_t id, double w, double h);

static D2D1_COLOR_F colour_of(uint32_t c, double alpha_mul) {
  D2D1_COLOR_F out;
  out.r = (FLOAT)(((c >> 24) & 255) / 255.0);
  out.g = (FLOAT)(((c >> 16) & 255) / 255.0);
  out.b = (FLOAT)(((c >> 8) & 255) / 255.0);
  out.a = (FLOAT)(((c & 255) / 255.0) * alpha_mul);
  return out;
}

/** Where a replay stands: the transform it saved and the clip or layer each push opened. */
typedef struct {
  D2D1_MATRIX_3X2_F matrix;
  int kind;  // 0 a saved transform, 1 an axis-aligned clip, 2 a layer
  ID2D1Layer *layer;
  int transforms;
} RState;

#define STATE_MAX 512
typedef struct {
  RState states[STATE_MAX];
  int depth;
  int transforms;
  double width, height;
} Replay;

static ID2D1SolidColorBrush *solid_brush_on(ID2D1DeviceContext *dc, uint32_t color, double alpha) {
  ID2D1SolidColorBrush *brush = NULL;
  if (!dc) return NULL;
  if (FAILED(dc->CreateSolidColorBrush(colour_of(color, alpha), &brush))) return NULL;
  return brush;
}

static ID2D1SolidColorBrush *solid_brush(uint32_t color, double alpha) {
  return solid_brush_on(g_d2d, color, alpha);
}

static void fill_geometry(ID2D1Geometry *geo, uint32_t color, double alpha) {
  ID2D1SolidColorBrush *brush = solid_brush(color, alpha);
  if (!brush) return;
  g_d2d->FillGeometry(geo, brush);
  brush->Release();
}

static void snap_box(const Replay *r, double *x, double *y, double *w, double *h) {
  if (r->transforms > 0) return;
  double x0 = round(*x), y0 = round(*y), x1 = round(*x + *w), y1 = round(*y + *h);
  *x = x0;
  *y = y0;
  *w = x1 - x0;
  *h = y1 - y0;
}

static double text_baseline(double size, double weight, double y, double line_height, double scale) {
  double ascent = round(host_font_ascent(size, weight) * scale);
  double descent = round(host_font_descent(size, weight) * scale);
  return y + (ascent + floor((line_height * scale - ascent - descent) / 2)) / scale;
}

static double device_round(double v, double scale) { return round(v * scale) / scale; }

/** The product of two matrices: `a` applied first, then `b`. */
static D2D1_MATRIX_3X2_F matrix_product(const D2D1_MATRIX_3X2_F &a, const D2D1_MATRIX_3X2_F &b) {
  return *D2D1::Matrix3x2F::ReinterpretBaseType(&a) * *D2D1::Matrix3x2F::ReinterpretBaseType(&b);
}

static double g_comp_origin_x, g_comp_origin_y;

/**
 * `saved` followed by `m`, as the replay composes a transform onto the one in effect, for the
 * context the replay draws into. A composited chunk rasters with its region's corner moved to the
 * origin, a translation that comes after everything the page applies (g_comp_origin, which
 * rect_bounds takes back off the same way): so `m` goes in before that translation, not after it.
 * Composed after it, a rotation or a scale turned the region's offset too, and the chunk's
 * pixels landed outside its own texture.
 */
static D2D1_MATRIX_3X2_F replay_compose(const D2D1_MATRIX_3X2_F &saved, const D2D1_MATRIX_3X2_F &m) {
  if (g_comp_origin_x == 0 && g_comp_origin_y == 0) return matrix_product(saved, m);
  D2D1_MATRIX_3X2_F page = matrix_product(
      saved, D2D1::Matrix3x2F::Translation((FLOAT)g_comp_origin_x, (FLOAT)g_comp_origin_y));
  return matrix_product(matrix_product(page, m),
                        D2D1::Matrix3x2F::Translation((FLOAT)-g_comp_origin_x, (FLOAT)-g_comp_origin_y));
}

/** A glyph run's baseline and pen: the run starts at `pen` and sits on `baseline`. */
static void draw_glyphs(ID2D1DeviceContext *dc, const uint8_t *s, size_t n, double pen, double baseline,
                        double size, double weight, double letter, double word, ID2D1Brush *brush) {
  if (!brush || !s) return;
  FontPick pick = pick_font(weight);
  if (!pick.face) return;
  size_t i = 0;
  uint32_t cp;
  while (utf8_next(s, n, &i, &cp)) {
    IDWriteFontFace *face = pick.face;
    UINT16 glyph = glyph_of(face, cp);
    if (glyph == 0) {
      IDWriteFontFace *other = fallback_face(cp);
      if (other) {
        face = other;
        glyph = glyph_of(face, cp);
      }
    }
    double advance = glyph_advance(pick.face, &pick.metrics, cp, size);
    if (glyph != 0) {
      DWRITE_GLYPH_METRICS gm = {0};
      face->GetDesignGlyphMetrics(&glyph, 1, &gm, FALSE);
      DWRITE_GLYPH_RUN run = {0};
      run.fontFace = face;
      run.fontEmSize = (FLOAT)size;
      run.glyphCount = 1;
      run.glyphIndices = &glyph;
      DWRITE_FONT_METRICS face_metrics = pick.metrics;
      if (face != pick.face) face->GetMetrics(&face_metrics);
      FLOAT adv = (FLOAT)((double)gm.advanceWidth *
                          (size / (face_metrics.designUnitsPerEm > 0 ? (double)face_metrics.designUnitsPerEm : 1000.0)));
      run.glyphAdvances = &adv;
      DWRITE_GLYPH_OFFSET offset = {0, 0};
      run.glyphOffsets = &offset;
      run.isSideways = FALSE;
      run.bidiLevel = 0;
      dc->DrawGlyphRun(D2D1::Point2F((FLOAT)pen, (FLOAT)baseline), &run,
                          (const DWRITE_GLYPH_RUN_DESCRIPTION *)NULL, brush,
                          DWRITE_MEASURING_MODE_NATURAL);
    }
    pen += advance + letter;
    if (cp == ' ') pen += word;
  }
}

/**
 * A run's glyphs as one geometry in text space: the pen starts at x = 0 and sits on the baseline
 * y = 0, with letter and word spacing the layout measured, so the outline lands where the run does.
 */
static ID2D1PathGeometry *glyph_outline(const uint8_t *text, size_t n, double size, double weight,
                                        double letter, double word) {
  FontPick pick = pick_font(weight);
  if (!pick.face) return NULL;
  int count = 0;
  for (size_t i = 0; i < n; i++) {
    unsigned char b = text[i];
    if (b < 0x80 || (b & 0xc0) != 0x80) count++;
  }
  if (count == 0) return NULL;
  UINT16 *glyphs = (UINT16 *)malloc((size_t)count * sizeof(UINT16));
  FLOAT *advances = (FLOAT *)malloc((size_t)count * sizeof(FLOAT));
  DWRITE_GLYPH_OFFSET *offsets = (DWRITE_GLYPH_OFFSET *)calloc((size_t)count, sizeof(DWRITE_GLYPH_OFFSET));
  if (!glyphs || !advances || !offsets) {
    free(glyphs);
    free(advances);
    free(offsets);
    return NULL;
  }
  size_t i = 0;
  int at = 0;
  uint32_t cp;
  while (at < count && utf8_next(text, n, &i, &cp)) {
    UINT16 glyph = glyph_of(pick.face, cp);
    DWRITE_GLYPH_METRICS gm;
    pick.face->GetDesignGlyphMetrics(&glyph, 1, &gm, FALSE);
    glyphs[at] = glyph;
    double advance = glyph_advance(pick.face, &pick.metrics, cp, size) + letter + (cp == ' ' ? word : 0);
    advances[at] = (FLOAT)advance;
    at++;
  }
  Geo g;
  geo_begin(&g, D2D1_FILL_MODE_WINDING);
  ID2D1PathGeometry *path = NULL;
  if (g.sink) {
    pick.face->GetGlyphRunOutline((FLOAT)size, glyphs, advances, offsets, (UINT32)at, FALSE, FALSE,
                                  (IDWriteGeometrySink *)g.sink);
    path = geo_end(&g);
  }
  free(glyphs);
  free(advances);
  free(offsets);
  return path;
}

static void paint_text_run(const Cmd *c, double dx, double dy, uint32_t color) {
  double baseline = device_round(text_baseline(c->size, c->weight, c->y, c->line_height, g_scale), g_scale);
  ID2D1SolidColorBrush *brush = solid_brush(color, 1);
  if (!brush) return;
  draw_glyphs(g_d2d, (const uint8_t *)c->text, c->len, c->x + dx, baseline + dy, c->size, c->weight,
              c->letter, c->word, brush);
  brush->Release();
}

// --- Images -----------------------------------------------------------------

typedef struct {
  ID2D1Bitmap *bitmap;
  // The decoded pixels, premultiplied BGRA rows top to bottom. A WebGL texture upload needs them,
  // and a device-side bitmap does not always hand them back.
  uint8_t *px;
  int stride;
  int w, h;
} Image;

#define MAX_IMAGES 512
static Image g_images[MAX_IMAGES];
static int g_image_count = 0;

static IWICImagingFactory *wic_factory(void) {
  static IWICImagingFactory *factory = NULL;
  static int tried = 0;
  if (!tried) {
    tried = 1;
    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER,
                                __uuidof(IWICImagingFactory), (void **)&factory)))
      factory = NULL;
  }
  return factory;
}

/** The 16-bit value at `p` in a TIFF's byte order. */
static uint16_t tiff16(const uint8_t *p, int big) {
  return big ? (uint16_t)((p[0] << 8) | p[1]) : (uint16_t)((p[1] << 8) | p[0]);
}

static uint32_t tiff32(const uint8_t *p, int big) {
  return big ? ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]
             : ((uint32_t)p[3] << 24) | ((uint32_t)p[2] << 16) | ((uint32_t)p[1] << 8) | p[0];
}

/** The orientation tag in a TIFF block, or 1 when it has none. */
static int tiff_orientation(const uint8_t *tiff, size_t len) {
  if (len < 8) return 1;
  int big = 0;
  if (tiff[0] == 'I' && tiff[1] == 'I') big = 0;
  else if (tiff[0] == 'M' && tiff[1] == 'M') big = 1;
  else return 1;
  if (tiff16(tiff + 2, big) != 42) return 1;
  uint32_t ifd = tiff32(tiff + 4, big);
  if (ifd + 2 > len) return 1;
  uint16_t count = tiff16(tiff + ifd, big);
  for (uint16_t i = 0; i < count; i++) {
    size_t at = (size_t)ifd + 2 + (size_t)i * 12;
    if (at + 12 > len) return 1;
    if (tiff16(tiff + at, big) != 0x0112) continue;
    uint16_t type = tiff16(tiff + at + 2, big);
    uint32_t n = tiff32(tiff + at + 4, big);
    if (type != 3 || n < 1) return 1;
    int orientation = (int)tiff16(tiff + at + 8, big);
    return orientation >= 1 && orientation <= 8 ? orientation : 1;
  }
  return 1;
}

/**
 * The EXIF orientation a file asks to be shown at, or 1 for none. The file is read rather than
 * asked of the decoder: the orientation is a few bytes in the first APP1 segment of a JPEG (or a
 * TIFF header), and reading them keeps the answer the same whatever decodes the pixels.
 */
static int exif_orientation(const char *name) {
  FILE *f = fopen(name, "rb");
  if (!f) return 1;
  uint8_t head[131072];
  size_t got = fread(head, 1, sizeof(head), f);
  fclose(f);
  if (got < 4) return 1;
  if (head[0] == 'I' || head[0] == 'M') return tiff_orientation(head, got);
  if (head[0] != 0xff || head[1] != 0xd8) return 1;
  size_t at = 2;
  while (at + 4 <= got) {
    if (head[at] != 0xff) {
      at++;
      continue;
    }
    uint8_t marker = head[at + 1];
    if (marker == 0xd8 || marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      at += 2;
      continue;
    }
    if (marker == 0xd9 || marker == 0xda) break;  // end of image, or the start of the scan
    size_t len = ((size_t)head[at + 2] << 8) | head[at + 3];
    if (len < 2 || at + 2 + len > got) break;
    if (marker == 0xe1 && len >= 8 && memcmp(head + at + 4, "Exif\0\0", 6) == 0)
      return tiff_orientation(head + at + 10, len - 8);
    at += 2 + len;
  }
  return 1;
}

/** The EXIF orientation the decoder reports, for a format the file header does not name. */
static int wic_orientation(IWICBitmapFrameDecode *frame) {
  if (!frame) return 1;
  IWICMetadataQueryReader *reader = NULL;
  if (FAILED(frame->GetMetadataQueryReader(&reader)) || !reader) return 1;
  PROPVARIANT value;
  PropVariantInit(&value);
  int orientation = 1;
  if (SUCCEEDED(reader->GetMetadataByName(L"/app1/ifd/{ushort=274}", &value)) &&
      value.vt == VT_UI2 && value.uiVal >= 1 && value.uiVal <= 8) {
    orientation = (int)value.uiVal;
  }
  PropVariantClear(&value);
  reader->Release();
  return orientation;
}

/** Turns decoded pixels the way their EXIF orientation says to show them. */
static IWICBitmapSource *orient_source(IWICBitmapSource *source, int orientation) {
  if (orientation <= 1 || orientation > 8) return NULL;
  static const WICBitmapTransformOptions options[9] = {
      WICBitmapTransformRotate0,
      WICBitmapTransformRotate0,
      WICBitmapTransformFlipHorizontal,
      WICBitmapTransformRotate180,
      WICBitmapTransformFlipVertical,
      (WICBitmapTransformOptions)(WICBitmapTransformRotate90 | WICBitmapTransformFlipHorizontal),
      WICBitmapTransformRotate90,
      (WICBitmapTransformOptions)(WICBitmapTransformRotate270 | WICBitmapTransformFlipHorizontal),
      WICBitmapTransformRotate270,
  };
  IWICImagingFactory *wic = wic_factory();
  if (!wic) return NULL;
  IWICBitmapFlipRotator *rotator = NULL;
  if (FAILED(wic->CreateBitmapFlipRotator(&rotator)) || !rotator) return NULL;
  if (FAILED(rotator->Initialize(source, options[orientation]))) {
    rotator->Release();
    return NULL;
  }
  return (IWICBitmapSource *)rotator;
}

extern "C" {

/** A source's pixels as the bitmap the page draws: premultiplied BGRA, made on the device once. */
static ID2D1Bitmap *image_bitmap(IWICBitmapSource *source, UINT *w, UINT *h, uint8_t **px, int *stride) {
  IWICImagingFactory *wic = wic_factory();
  if (!wic || !source || !g_d2d) return NULL;
  IWICFormatConverter *converter = NULL;
  if (FAILED(wic->CreateFormatConverter(&converter)) || !converter) return NULL;
  ID2D1Bitmap *bitmap = NULL;
  HRESULT hr = converter->Initialize(source, GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone,
                                     NULL, 0.0, WICBitmapPaletteTypeCustom);
  if (SUCCEEDED(hr)) hr = converter->GetSize(w, h);
  if (SUCCEEDED(hr) && *w > 0 && *h > 0)
    hr = g_d2d->CreateBitmapFromWicBitmap((IWICBitmapSource *)converter, NULL, &bitmap);
  // The same pixels, kept for a texture upload: the decoded picture, not the device's copy.
  if (SUCCEEDED(hr) && px != NULL) {
    UINT row = *w * 4u;
    uint8_t *pixels = (uint8_t *)malloc((size_t)row * *h);
    if (pixels != NULL && SUCCEEDED(converter->CopyPixels(NULL, row, row * *h, pixels))) {
      *px = pixels;
      *stride = (int)row;
    } else {
      free(pixels);
    }
  }
  converter->Release();
  return SUCCEEDED(hr) ? bitmap : NULL;
}

int32_t host_image_load(const uint8_t *path, size_t path_len, int32_t oriented) {
  if (!ensure_device()) return -1;
  IWICImagingFactory *wic = wic_factory();
  if (!wic) return -1;
  char name[4096];
  if (!copy_name_bytes(name, sizeof(name), path, path_len)) return -1;
  size_t wide_len = 0;
  wchar_t *wide = utf8_to_utf16((const uint8_t *)name, strlen(name), &wide_len);
  if (!wide) return -1;
  IWICBitmapDecoder *decoder = NULL;
  IWICBitmapFrameDecode *frame = NULL;
  HRESULT hr = wic->CreateDecoderFromFilename(wide, NULL, GENERIC_READ, WICDecodeMetadataCacheOnDemand,
                                              &decoder);
  free(wide);
  if (FAILED(hr) || !decoder) return -1;
  int orientation = 1;
  hr = decoder->GetFrame(0, &frame);
  if (SUCCEEDED(hr) && oriented) {
    orientation = exif_orientation(name);
    if (orientation <= 1) orientation = wic_orientation(frame);
  }
  IWICBitmapSource *source = (IWICBitmapSource *)frame;
  IWICBitmapSource *rotated = NULL;
  if (SUCCEEDED(hr) && orientation > 1) {
    rotated = orient_source(source, orientation);
    if (rotated) source = rotated;
  }
  UINT w = 0, h = 0;
  uint8_t *px = NULL;
  int stride = 0;
  ID2D1Bitmap *bitmap = image_bitmap(source, &w, &h, &px, &stride);
  if (!bitmap && rotated) {
    // A rotator that cannot hand back pixels still leaves the picture as it is stored.
    bitmap = image_bitmap((IWICBitmapSource *)frame, &w, &h, &px, &stride);
  }
  if (rotated) rotated->Release();
  if (frame) frame->Release();
  decoder->Release();
  if (!bitmap) {
    free(px);
    return -1;
  }
  if (g_image_count >= MAX_IMAGES) {
    bitmap->Release();
    free(px);
    return -1;
  }
  int id = g_image_count++;
  g_images[id].bitmap = bitmap;
  g_images[id].px = px;
  g_images[id].stride = stride;
  g_images[id].w = (int)w;
  g_images[id].h = (int)h;
  return id;
}

double host_image_width(int32_t id) {
  return id >= 0 && id < g_image_count ? g_images[id].w : 0;
}

double host_image_height(int32_t id) {
  return id >= 0 && id < g_image_count ? g_images[id].h : 0;
}

// WIC decodes on the thread that asks, so a load is over when host_image_load answers: there is
// never a decode to wait for.
int32_t host_image_ready(int32_t id) { (void)id; return 1; }
int32_t host_image_failed(int32_t id) { (void)id; return 0; }
void host_images_settled(void) {}

}  // extern "C"

// --- Gradients --------------------------------------------------------------

#define MAX_STOPS 256

typedef struct {
  int n;
  double loc[MAX_STOPS];
  uint32_t col[MAX_STOPS];
} Stops;

static int parse_stops(const char *s, Stops *out) {
  out->n = 0;
  if (!s) return 0;
  const char *p = s;
  while (*p && out->n < MAX_STOPS) {
    char *end;
    unsigned long long c = strtoull(p, &end, 10);
    if (end == p) break;
    p = end;
    if (*p == ',') p++;
    double loc = strtod(p, &end);
    if (end == p) break;
    p = end;
    out->loc[out->n] = loc;
    out->col[out->n] = (uint32_t)c;
    out->n++;
    if (*p == ';') p++;
    else break;
  }
  return out->n;
}

static ID2D1GradientStopCollection *make_stops(const Stops *s, ID2D1DeviceContext *dc) {
  if (!dc || s->n < 2) return NULL;
  D2D1_GRADIENT_STOP stops[MAX_STOPS];
  for (int i = 0; i < s->n; i++) {
    double at = s->loc[i] < 0 ? 0 : s->loc[i] > 1 ? 1 : s->loc[i];
    if (i > 0 && at < stops[i - 1].position) at = stops[i - 1].position;
    stops[i].position = (FLOAT)at;
    stops[i].color = colour_of(s->col[i], 1);
  }
  ID2D1GradientStopCollection *out = NULL;
  if (FAILED(dc->CreateGradientStopCollection(stops, (UINT32)s->n, D2D1_GAMMA_2_2,
                                              D2D1_EXTEND_MODE_CLAMP, &out)))
    return NULL;
  return out;
}

/** The colour at `t` along a gradient: straight components, 0..1, blending between stops. */
static void stops_colour_at(const Stops *st, double t, double out[4]) {
  int i = 0;
  while (i + 1 < st->n && st->loc[i + 1] <= t) i++;
  int next = i + 1 < st->n ? i + 1 : i;
  uint32_t a = st->col[i], b = st->col[next];
  double span = st->loc[next] - st->loc[i];
  double k = span > 0 && t > st->loc[i] ? (t - st->loc[i]) / span : 0;
  if (k > 1) k = 1;
  if (k < 0) k = 0;
  double a0 = (a & 255) / 255.0, a1 = (b & 255) / 255.0;
  double alpha = a0 + (a1 - a0) * k;
  if (alpha <= 0) {
    out[0] = out[1] = out[2] = out[3] = 0;
    return;
  }
  double r0 = ((a >> 24) & 255) / 255.0 * a0, g0 = ((a >> 16) & 255) / 255.0 * a0,
         b0 = ((a >> 8) & 255) / 255.0 * a0;
  double r1 = ((b >> 24) & 255) / 255.0 * a1, g1 = ((b >> 16) & 255) / 255.0 * a1,
         b1 = ((b >> 8) & 255) / 255.0 * a1;
  out[0] = (r0 + (r1 - r0) * k) / alpha;
  out[1] = (g0 + (g1 - g0) * k) / alpha;
  out[2] = (b0 + (b1 - b0) * k) / alpha;
  out[3] = alpha;
}

// --- The replay -------------------------------------------------------------

static Replay g_replay;

// The compositor's chunk replay: commands in [first, last) draw, and the state commands before
// them are replayed so a chunk rasters under exactly the transform and clips the flat replay
// would have given it. Effect groups are skipped (the chunk's alpha is applied when it
// composites), and `clips` 0 skips the clips too, for a chunk whose clip the backend applies to
// the quad at draw. A skipped push still saves its state, so its pop restores the same thing.
static int g_chunk_mode = 0;
static size_t g_chunk_first = 0, g_chunk_last = 0;
static int g_chunk_clips = 1;

static void replay_state_restore(Replay *r) {
  if (r->depth <= 0) return;
  RState st = r->states[--r->depth];
  if (st.kind == 2 && st.layer) {
    g_d2d->PopLayer();
    st.layer->Release();
  } else if (st.kind == 1) {
    g_d2d->PopAxisAlignedClip();
  }
  g_d2d->SetTransform(st.matrix);
  r->transforms = st.transforms;
}

static void replay_state_save(Replay *r, int kind, ID2D1Layer *layer) {
  if (r->depth >= STATE_MAX) {
    if (kind == 2 && layer) {
      g_d2d->PopLayer();
      layer->Release();
    }
    return;
  }
  RState *st = &r->states[r->depth++];
  g_d2d->GetTransform(&st->matrix);
  st->kind = kind;
  st->layer = layer;
  st->transforms = r->transforms;
}

/** Prints a clip's shape when NATIVE_DEBUG_CLIPS asks, for a frame whose content went missing. */
static void debug_clip(const char *what, ID2D1Geometry *mask, double x, double y, double w, double h) {
  if (getenv("NATIVE_DEBUG_CLIPS") == NULL) return;
  if (mask != NULL) {
    D2D1_MATRIX_3X2_F m;
    D2D1_RECT_F b = {0, 0, 0, 0};
    g_d2d->GetTransform(&m);
    mask->GetBounds(&m, &b);
    fprintf(stderr, "native: clip %s mask %.1f,%.1f %.1fx%.1f\n", what, b.left, b.top, b.right - b.left,
            b.bottom - b.top);
  } else {
    fprintf(stderr, "native: clip %s rect %.1f,%.1f %.1fx%.1f\n", what, x, y, w, h);
  }
}

/** Pushes a layer whose mask is `mask` (or the whole frame when it is null). */
static void push_clip_layer(Replay *r, ID2D1Geometry *mask) {
  ID2D1Layer *layer = NULL;
  if (!g_d2d || FAILED(g_d2d->CreateLayer(&layer)) || !layer) {
    replay_state_save(r, 0, NULL);
    return;
  }
  D2D1_LAYER_PARAMETERS1 params = D2D1::LayerParameters1(
      D2D1::InfiniteRect(), mask, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE, D2D1::IdentityMatrix(), 1.0f,
      NULL, D2D1_LAYER_OPTIONS1_NONE);
  g_d2d->PushLayer(&params, layer);
  debug_clip("layer", mask, 0, 0, 0, 0);
  replay_state_save(r, 2, layer);
}

/** Pushes a layer that fades what it holds, which is what an opacity group is. */
static void push_opacity_layer(Replay *r, double alpha) {
  ID2D1Layer *layer = NULL;
  if (!g_d2d || FAILED(g_d2d->CreateLayer(&layer)) || !layer) {
    replay_state_save(r, 0, NULL);
    return;
  }
  D2D1_LAYER_PARAMETERS1 params = D2D1::LayerParameters1(
      D2D1::InfiniteRect(), NULL, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE, D2D1::IdentityMatrix(),
      (FLOAT)(alpha < 0 ? 0 : alpha > 1 ? 1 : alpha), NULL, D2D1_LAYER_OPTIONS1_NONE);
  g_d2d->PushLayer(&params, layer);
  replay_state_save(r, 2, layer);
}

// --- Box shadows -------------------------------------------------------------

/** The offscreen surface shadows are cast on, kept between paints and grown as needed. */
static ID2D1DeviceContext *g_shadow_dc = NULL;
static ID2D1Bitmap1 *g_shadow_bitmap = NULL;
static int g_shadow_w = 0, g_shadow_h = 0;

static ID2D1DeviceContext *shadow_surface(int w, int h) {
  if (!ensure_device() || !g_d2d_device || w < 1 || h < 1) return NULL;
  if (g_shadow_dc && g_shadow_bitmap && g_shadow_w >= w && g_shadow_h >= h) return g_shadow_dc;
  if (g_shadow_dc) {
    g_shadow_dc->SetTarget(NULL);
    g_shadow_dc->Release();
    g_shadow_dc = NULL;
  }
  if (g_shadow_bitmap) {
    g_shadow_bitmap->Release();
    g_shadow_bitmap = NULL;
  }
  int cap_w = 64, cap_h = 64;
  while (cap_w < w && cap_w < 8192) cap_w *= 2;
  while (cap_h < h && cap_h < 8192) cap_h *= 2;
  if (cap_w < w) cap_w = w;
  if (cap_h < h) cap_h = h;
  D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
      D2D1_BITMAP_OPTIONS_TARGET,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
      96.0f * (float)g_scale, 96.0f * (float)g_scale);
  if (FAILED(g_d2d->CreateBitmap(D2D1::SizeU((UINT32)cap_w, (UINT32)cap_h), NULL, 0, &props,
                                 &g_shadow_bitmap)) ||
      !g_shadow_bitmap)
    return NULL;
  if (FAILED(g_d2d_device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &g_shadow_dc)) ||
      !g_shadow_dc)
    return NULL;
  g_shadow_dc->SetTarget(g_shadow_bitmap);
  g_shadow_dc->SetDpi(96.0f * (float)g_scale, 96.0f * (float)g_scale);
  g_shadow_dc->SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
  g_shadow_w = cap_w;
  g_shadow_h = cap_h;
  return g_shadow_dc;
}

static void dfill_round(ID2D1DeviceContext *dc, double x, double y, double w, double h,
                        const double r[8], ID2D1Brush *brush);

/** The device-space box a shadow of `c` covers, in DIPS, clamped to the frame. */
static int shadow_bounds(const Cmd *c, double pad, D2D1_RECT_F *out) {
  D2D1_MATRIX_3X2_F m;
  g_d2d->GetTransform(&m);
  double xs[2] = {c->x - pad, c->x + c->w + pad};
  double ys[2] = {c->y - pad, c->y + c->h + pad};
  double x0 = 1e18, y0 = 1e18, x1 = -1e18, y1 = -1e18;
  for (int i = 0; i < 2; i++) {
    for (int j = 0; j < 2; j++) {
      double X = xs[i] * m._11 + ys[j] * m._21 + m._31;
      double Y = xs[i] * m._12 + ys[j] * m._22 + m._32;
      if (X < x0) x0 = X;
      if (X > x1) x1 = X;
      if (Y < y0) y0 = Y;
      if (Y > y1) y1 = Y;
    }
  }
  // Cut to the view. A composited chunk's raster is moved by g_comp_origin (see rect_bounds), so
  // the view sits that far up and left in these coordinates.
  double vx0 = -g_comp_origin_x, vy0 = -g_comp_origin_y;
  double vx1 = g_view_w - g_comp_origin_x, vy1 = g_view_h - g_comp_origin_y;
  if (x0 < vx0) x0 = vx0;
  if (y0 < vy0) y0 = vy0;
  if (x1 > vx1) x1 = vx1;
  if (y1 > vy1) y1 = vy1;
  if (!(x1 > x0) || !(y1 > y0)) return 0;
  out->left = (FLOAT)x0;
  out->top = (FLOAT)y0;
  out->right = (FLOAT)x1;
  out->bottom = (FLOAT)y1;
  return 1;
}

/** One box blur of a channel plane along one axis, with the edges holding. */
static void box_blur_line(uint8_t *src, double *dst, int count, int stride, int radius) {
  int size = radius * 2 + 1;
  double sum = 0;
  for (int i = -radius; i <= radius; i++) {
    int at = i < 0 ? 0 : i >= count ? count - 1 : i;
    sum += src[(size_t)at * (size_t)stride];
  }
  for (int i = 0; i < count; i++) {
    dst[(size_t)i * (size_t)stride] = sum / size;
    int out = i - radius;
    int in = i + radius + 1;
    if (out < 0) out = 0;
    if (in >= count) in = count - 1;
    sum += (double)src[(size_t)in * (size_t)stride] - (double)src[(size_t)out * (size_t)stride];
  }
}

/** Three box blurs, which is a Gaussian to any eye that sees the shadow, in one pass per axis. */
static void blur_plane(uint8_t *plane, int w, int h, double sigma) {
  if (!(sigma > 0.3) || w < 1 || h < 1) return;
  // The box width whose three passes come out at this deviation.
  int radius = (int)floor(sqrt(4.0 * sigma * sigma / 3.0 + 0.25) - 0.5);
  if (radius < 1) radius = 1;
  if (radius > 128) radius = 128;
  double *temp = (double *)malloc((size_t)w * (size_t)h * sizeof(double));
  if (!temp) return;
  for (int pass = 0; pass < 3; pass++) {
    for (int y = 0; y < h; y++)
      box_blur_line(plane + (size_t)y * (size_t)w, temp + (size_t)y * (size_t)w, w, 1, radius);
    for (int y = 0; y < h; y++)
      for (int x = 0; x < w; x++)
        plane[(size_t)y * (size_t)w + (size_t)x] = (uint8_t)(temp[(size_t)y * (size_t)w + (size_t)x] + 0.5);
    for (int x = 0; x < w; x++) box_blur_line(plane + (size_t)x, temp + (size_t)x, h, w, radius);
    for (int y = 0; y < h; y++)
      for (int x = 0; x < w; x++)
        plane[(size_t)y * (size_t)w + (size_t)x] = (uint8_t)(temp[(size_t)y * (size_t)w + (size_t)x] + 0.5);
  }
  free(temp);
}

/** The device-space box of a rectangle under the current transform, clamped to the frame. */
static int rect_bounds(D2D1_RECT_F box, D2D1_RECT_F *out) {
  D2D1_MATRIX_3X2_F m;
  g_d2d->GetTransform(&m);
  double xs[2] = {box.left, box.right}, ys[2] = {box.top, box.bottom};
  double x0 = 1e18, y0 = 1e18, x1 = -1e18, y1 = -1e18;
  for (int i = 0; i < 2; i++) {
    for (int j = 0; j < 2; j++) {
      double X = xs[i] * m._11 + ys[j] * m._21 + m._31;
      double Y = xs[i] * m._12 + ys[j] * m._22 + m._32;
      if (X < x0) x0 = X;
      if (X > x1) x1 = X;
      if (Y < y0) y0 = Y;
      if (Y > y1) y1 = Y;
    }
  }
  // A composited chunk rasters through a translation of its own. The shadow paths above use these
  // bounds as a place in the page's own space and draw them under the current transform, so the
  // translation is taken back off here: the shadow lands where the flat replay puts it, and the
  // raster's own offset moves the pixels into the chunk.
  x0 += g_comp_origin_x;
  x1 += g_comp_origin_x;
  y0 += g_comp_origin_y;
  y1 += g_comp_origin_y;
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x1 > g_view_w) x1 = g_view_w;
  if (y1 > g_view_h) y1 = g_view_h;
  if (!(x1 > x0) || !(y1 > y0)) return 0;
  out->left = (FLOAT)x0;
  out->top = (FLOAT)y0;
  out->right = (FLOAT)x1;
  out->bottom = (FLOAT)y1;
  return 1;
}

/**
 * Blurs the coverage drawn into the shadow surface, tints it with `color`, and lays it at `bounds`,
 * clipped to `clip` when one is given. Both shadows and blurred text shadows end here.
 */
static void draw_shadow_bitmap(ID2D1Bitmap1 *shadow, D2D1_RECT_F bounds, ID2D1Geometry *clip);

// Direct2D's shadow effect (d2d1effects.h): a Gaussian blur of its input's alpha, tinted.
static const GUID NATIVE_CLSID_D2D1Shadow = {0xC67EA361, 0x1863, 0x4e69, {0x89, 0xDB, 0x69, 0x5D, 0x3E, 0x9A, 0x5B, 0x6B}};
enum { NATIVE_SHADOW_PROP_STDDEV = 0, NATIVE_SHADOW_PROP_COLOR = 1 };

/**
 * The blur on the device: the coverage in the shadow surface goes through Direct2D's shadow
 * effect into a bitmap of its own, which is drawn and kept. Nothing is read back, so the frame's
 * GPU work never has to finish first, which a readback waits for: on a GPU that is a stall of
 * the whole queue per shadow. Answers NULL when the effect isn't there, and the CPU blur runs.
 */
static ID2D1Bitmap1 *blur_on_device(int pw, int ph, double blur, uint32_t color, D2D1_RECT_F bounds,
                                    ID2D1Geometry *clip) {
  static int off = -1;
  if (off < 0) {
    const char *env = getenv("NATIVE_CPU_BLUR");
    off = env != NULL && env[0] != 0 && strcmp(env, "0") != 0;
  }
  if (off || g_shadow_dc == NULL || g_shadow_bitmap == NULL) return NULL;
  ID2D1Effect *fx = NULL;
  if (FAILED(g_shadow_dc->CreateEffect(NATIVE_CLSID_D2D1Shadow, &fx)) || fx == NULL) return NULL;
  // The CSS blur radius is twice the Gaussian's deviation; the effect takes it in DIPs, which is
  // what the shadow surface's DPI makes CSS pixels.
  FLOAT sigma = (FLOAT)(blur / 2.0);
  if (sigma < 0) sigma = 0;
  D2D1_VECTOR_4F tint = {((color >> 24) & 255) / 255.0f, ((color >> 16) & 255) / 255.0f,
                         ((color >> 8) & 255) / 255.0f, (color & 255) / 255.0f};
  fx->SetInput(0, g_shadow_bitmap);
  HRESULT hr = fx->SetValue(NATIVE_SHADOW_PROP_STDDEV, D2D1_PROPERTY_TYPE_FLOAT, (const BYTE *)&sigma, sizeof(sigma));
  if (SUCCEEDED(hr))
    hr = fx->SetValue(NATIVE_SHADOW_PROP_COLOR, D2D1_PROPERTY_TYPE_VECTOR4, (const BYTE *)&tint, sizeof(tint));
  ID2D1Bitmap1 *out = NULL;
  if (SUCCEEDED(hr)) {
    D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_TARGET,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
        96.0f * (float)g_scale, 96.0f * (float)g_scale);
    hr = g_shadow_dc->CreateBitmap(D2D1::SizeU((UINT32)pw, (UINT32)ph), NULL, 0, &props, &out);
  }
  if (SUCCEEDED(hr) && out != NULL) {
    ID2D1Image *output = NULL;
    fx->GetOutput(&output);
    g_shadow_dc->SetTarget(out);
    g_shadow_dc->BeginDraw();
    g_shadow_dc->SetTransform(D2D1::IdentityMatrix());
    g_shadow_dc->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.0f));
    if (output != NULL) g_shadow_dc->DrawImage(output, D2D1_INTERPOLATION_MODE_LINEAR, D2D1_COMPOSITE_MODE_SOURCE_COPY);
    hr = g_shadow_dc->EndDraw();
    g_shadow_dc->SetTarget(g_shadow_bitmap);
    if (output != NULL) output->Release();
    if (FAILED(hr)) {
      out->Release();
      out = NULL;
    }
  } else if (out != NULL) {
    out->Release();
    out = NULL;
  }
  fx->Release();
  if (out != NULL) draw_shadow_bitmap(out, bounds, clip);
  return out;
}

static ID2D1Bitmap1 *composite_blurred(int pw, int ph, double blur, uint32_t color, D2D1_RECT_F bounds,
                                      ID2D1Geometry *clip) {
  if (!g_d2d || pw < 1 || ph < 1) return NULL;
  ID2D1Bitmap1 *on_device = blur_on_device(pw, ph, blur, color, bounds, clip);
  if (on_device != NULL) return on_device;
  ID2D1Bitmap1 *shadow = NULL;
  D2D1_BITMAP_PROPERTIES1 cpu_props = D2D1::BitmapProperties1(
      (D2D1_BITMAP_OPTIONS)(D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW),
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
      96.0f * (float)g_scale, 96.0f * (float)g_scale);
  ID2D1Bitmap1 *cpu = NULL;
  if (FAILED(g_shadow_dc->CreateBitmap(D2D1::SizeU((UINT32)pw, (UINT32)ph), NULL, 0, &cpu_props, &cpu)) ||
      !cpu)
    return NULL;
  D2D1_MAPPED_RECT mapped = {0};
  if (SUCCEEDED(cpu->CopyFromBitmap(NULL, g_shadow_bitmap, NULL)) &&
      SUCCEEDED(cpu->Map(D2D1_MAP_OPTIONS_READ, &mapped))) {
    uint8_t *coverage = (uint8_t *)malloc((size_t)pw * (size_t)ph);
    if (coverage) {
      for (int y = 0; y < ph; y++) {
        const uint8_t *row = mapped.bits + (size_t)y * (size_t)mapped.pitch;
        for (int x = 0; x < pw; x++) coverage[(size_t)y * (size_t)pw + (size_t)x] = row[x * 4 + 3];
      }
      cpu->Unmap();
      blur_plane(coverage, pw, ph, blur * g_scale / 2);
      double sa = (color & 255) / 255.0;
      double sr = ((color >> 24) & 255) / 255.0;
      double sg = ((color >> 16) & 255) / 255.0;
      double sb = ((color >> 8) & 255) / 255.0;
      uint8_t *pixels = (uint8_t *)malloc((size_t)pw * (size_t)ph * 4);
      if (pixels) {
        for (size_t i = 0; i < (size_t)pw * (size_t)ph; i++) {
          double a = coverage[i] / 255.0 * sa;
          uint8_t *p = pixels + i * 4;
          p[0] = (uint8_t)(sb * a * 255.0 + 0.5);
          p[1] = (uint8_t)(sg * a * 255.0 + 0.5);
          p[2] = (uint8_t)(sr * a * 255.0 + 0.5);
          p[3] = (uint8_t)(a * 255.0 + 0.5);
        }
        D2D1_BITMAP_PROPERTIES1 bitmap_props = D2D1::BitmapProperties1(
            D2D1_BITMAP_OPTIONS_NONE,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
            96.0f * (float)g_scale, 96.0f * (float)g_scale);
        if (SUCCEEDED(g_d2d->CreateBitmap(D2D1::SizeU((UINT32)pw, (UINT32)ph), pixels, (UINT32)pw * 4,
                                          &bitmap_props, &shadow)) &&
            shadow) {
          D2D1_RECT_F dest = bounds;
          ID2D1Layer *layer = NULL;
          int pushed = 0;
          if (clip && SUCCEEDED(g_d2d->CreateLayer(&layer)) && layer) {
            D2D1_LAYER_PARAMETERS1 params = D2D1::LayerParameters1(
                D2D1::InfiniteRect(), clip, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE,
                D2D1::IdentityMatrix(), 1.0f, NULL, D2D1_LAYER_OPTIONS1_NONE);
            g_d2d->PushLayer(&params, layer);
            pushed = 1;
          }
          g_d2d->DrawBitmap(shadow, &dest, 1.0f, D2D1_INTERPOLATION_MODE_LINEAR, NULL);
          if (pushed) {
            g_d2d->PopLayer();
            layer->Release();
          }
        }
        free(pixels);
      }
      free(coverage);
    } else {
      cpu->Unmap();
    }
  }
  cpu->Release();
  return shadow;
}

/** Draws a finished shadow bitmap where it belongs, clipped to the box for an inset shadow. */
static void draw_shadow_bitmap(ID2D1Bitmap1 *shadow, D2D1_RECT_F bounds, ID2D1Geometry *clip) {
  if (!g_d2d || !shadow) return;
  ID2D1Layer *layer = NULL;
  int pushed = 0;
  if (clip && SUCCEEDED(g_d2d->CreateLayer(&layer)) && layer) {
    D2D1_LAYER_PARAMETERS1 params = D2D1::LayerParameters1(
        D2D1::InfiniteRect(), clip, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE,
        D2D1::IdentityMatrix(), 1.0f, NULL, D2D1_LAYER_OPTIONS1_NONE);
    g_d2d->PushLayer(&params, layer);
    pushed = 1;
  }
  D2D1_RECT_F dest = bounds;
  g_d2d->DrawBitmap(shadow, &dest, 1.0f, D2D1_INTERPOLATION_MODE_LINEAR, NULL);
  if (pushed) {
    g_d2d->PopLayer();
    layer->Release();
  }
}

/**
 * The transform a shadow's silhouette is drawn with into the shadow surface, whose corner is
 * `bounds` in the page (rect_bounds): the one in effect, without a composited chunk's own move of
 * the page into its texture (g_comp_origin). The finished shadow is laid at `bounds` under the
 * transform in effect, which moves it into the chunk once; with the move in the silhouette as
 * well, a chunk away from the frame's corner drew its shadows twice as far from it.
 */
static D2D1_MATRIX_3X2_F shadow_page_transform(void) {
  D2D1_MATRIX_3X2_F m;
  g_d2d->GetTransform(&m);
  return matrix_product(m, D2D1::Matrix3x2F::Translation((FLOAT)g_comp_origin_x, (FLOAT)g_comp_origin_y));
}

/**
 * Blurred shadows kept between frames. A page whose animation moves elements other than the one
 * that casts a shadow re-records the same shadow every frame; rastering and blurring it again each
 * time is most of a frame's paint, so a finished shadow stays here until its shape, blur, colour or
 * size changes — the bitmap is laid down relative to its own bounds, so a box that only moves still
 * hits.
 */
typedef struct {
  int used;
  uint64_t key;
  ID2D1Bitmap1 *bitmap;
} ShadowCacheEntry;
#define SHADOW_CACHE_ENTRIES 24
static ShadowCacheEntry g_shadow_cache[SHADOW_CACHE_ENTRIES];
static int g_shadow_cache_next = 0;

static uint64_t shadow_key(const Cmd *c, int inset, int pw, int ph, D2D1_RECT_F bounds) {
  uint64_t h = 1469598103934665603ull;
#define SHADOW_MIX(v) do { h ^= (uint64_t)(v); h *= 1099511628211ull; } while (0)
  SHADOW_MIX((uint64_t)pw);
  SHADOW_MIX((uint64_t)ph);
  // The silhouette is drawn through the current transform, relative to the bounds' corner: a
  // turned or scaled box casts another picture, and so does one the frame's edge cut the bounds
  // of, whose box sits elsewhere in them.
  D2D1_MATRIX_3X2_F m;
  g_d2d->GetTransform(&m);
  SHADOW_MIX((uint64_t)(long long)llround(m._11 * 4096));
  SHADOW_MIX((uint64_t)(long long)llround(m._12 * 4096));
  SHADOW_MIX((uint64_t)(long long)llround(m._21 * 4096));
  SHADOW_MIX((uint64_t)(long long)llround(m._22 * 4096));
  double ox = c->x * m._11 + c->y * m._21 + m._31 + g_comp_origin_x - bounds.left;
  double oy = c->x * m._12 + c->y * m._22 + m._32 + g_comp_origin_y - bounds.top;
  SHADOW_MIX((uint64_t)(long long)llround(ox * 64));
  SHADOW_MIX((uint64_t)(long long)llround(oy * 64));
  SHADOW_MIX((uint64_t)inset);
  SHADOW_MIX((uint64_t)(long long)(c->w * 64));
  SHADOW_MIX((uint64_t)(long long)(c->h * 64));
  SHADOW_MIX((uint64_t)(long long)(c->line_width * 64));
  SHADOW_MIX((uint64_t)(long long)(c->dx * 64));
  SHADOW_MIX((uint64_t)(long long)(c->dy * 64));
  SHADOW_MIX((uint64_t)(long long)(c->blur * 64));
  SHADOW_MIX((uint64_t)c->color);
  for (int k = 0; k < 8; k++) SHADOW_MIX((uint64_t)(long long)(c->r[k] * 64));
#undef SHADOW_MIX
  return h;
}

/**
 * Paints a box-shadow: its silhouette rendered into the shadow surface, blurred, tinted with the
 * shadow colour, and laid under (or inside) the box.
 */
static void paint_shadow(const Cmd *c, int inset) {
  if (!g_d2d || !(c->w > 0) || !(c->h > 0)) return;
  double spread = c->line_width;
  double pad = fabs(c->dx) + fabs(c->dy) + c->blur * 3 + fabs(spread) + 2;
  // The box the shadow covers, in the page's own space, cut to the page. A shadow is the same
  // picture wherever its element sits and however it is turned, so it is rastered and blurred
  // here and laid down under the transform in effect: a shadow that moves or turns keeps the
  // bitmap it was made with, and a turned one draws that silhouette turned.
  D2D1_RECT_F bounds = D2D1::RectF((FLOAT)(c->x - pad), (FLOAT)(c->y - pad),
                                   (FLOAT)(c->x + c->w + pad), (FLOAT)(c->y + c->h + pad));
  if (bounds.left < 0) bounds.left = 0;
  if (bounds.top < 0) bounds.top = 0;
  if (bounds.right > (FLOAT)g_view_w) bounds.right = (FLOAT)g_view_w;
  if (bounds.bottom > (FLOAT)g_view_h) bounds.bottom = (FLOAT)g_view_h;
  if (!(bounds.right > bounds.left) || !(bounds.bottom > bounds.top)) return;
  int pw = (int)ceil((bounds.right - bounds.left) * g_scale);
  int ph = (int)ceil((bounds.bottom - bounds.top) * g_scale);
  if (pw < 1 || ph < 1 || (double)pw * ph > 64.0 * 1024 * 1024) return;
  ID2D1PathGeometry *clip = NULL;
  if (inset) {
    Geo g;
    geo_begin(&g, D2D1_FILL_MODE_WINDING);
    geo_round_rect(&g, c->x, c->y, c->w, c->h, c->r);
    clip = geo_end(&g);
  }
  const uint64_t key = shadow_key(c, inset, pw, ph, bounds);
  for (int k = 0; k < SHADOW_CACHE_ENTRIES; k++) {
    if (g_shadow_cache[k].used && g_shadow_cache[k].key == key) {
      draw_shadow_bitmap(g_shadow_cache[k].bitmap, bounds, clip);
      if (clip) clip->Release();
      return;
    }
  }
  ID2D1DeviceContext *dc = shadow_surface(pw, ph);
  if (!dc) {
    if (clip) clip->Release();
    return;
  }
  // The silhouette: the border box grown by the spread for an outer shadow, and the ring the
  // offset leaves inside the box for an inset one.
  dc->BeginDraw();
  dc->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.0f));
  dc->SetTransform(D2D1::Matrix3x2F::Translation(-bounds.left, -bounds.top));
  ID2D1SolidColorBrush *white = solid_brush_on(dc, 0xffffffffu, 1);
  if (white) {
    if (!inset) {
      double outer[8];
      for (int k = 0; k < 8; k++) outer[k] = c->r[k] + spread;
      dfill_round(dc, c->x + c->dx - spread, c->y + c->dy - spread, c->w + 2 * spread,
                  c->h + 2 * spread, outer, white);
    } else {
      double inner[8];
      for (int k = 0; k < 8; k++) inner[k] = c->r[k] - spread;
      Geo g;
      geo_begin(&g, D2D1_FILL_MODE_ALTERNATE);
      geo_round_rect(&g, c->x, c->y, c->w, c->h, c->r);
      geo_round_rect(&g, c->x + spread + c->dx, c->y + spread + c->dy, c->w - 2 * spread,
                     c->h - 2 * spread, inner);
      ID2D1PathGeometry *ring = geo_end(&g);
      if (ring) {
        dc->FillGeometry(ring, white);
        ring->Release();
      }
    }
    white->Release();
  }
  dc->EndDraw();
  dc->SetTransform(D2D1::IdentityMatrix());
  ID2D1Bitmap1 *made = composite_blurred(pw, ph, c->blur, c->color, bounds, clip);
  if (clip) clip->Release();
  if (made != NULL) {
    int slot = g_shadow_cache_next;
    g_shadow_cache_next = (g_shadow_cache_next + 1) % SHADOW_CACHE_ENTRIES;
    if (g_shadow_cache[slot].used && g_shadow_cache[slot].bitmap) g_shadow_cache[slot].bitmap->Release();
    g_shadow_cache[slot].used = 1;
    g_shadow_cache[slot].key = key;
    g_shadow_cache[slot].bitmap = made;
  }
}

/** A text run's shadow: its glyphs outlined, blurred and tinted, laid under the run. */
static void paint_text_shadow(const Cmd *c) {
  double baseline =
      device_round(text_baseline(c->size, c->weight, c->y, c->line_height, g_scale), g_scale);
  ID2D1PathGeometry *glyphs = glyph_outline((const uint8_t *)c->text, c->len, c->size, c->weight,
                                            c->letter, c->word);
  if (!g_d2d || !glyphs) {
    if (glyphs) glyphs->Release();
    paint_text_run(c, c->dx, c->dy, c->shadow_color);
    paint_text_run(c, 0, 0, c->color);
    return;
  }
  // As the page has it, without a composited chunk's move into its texture (see
  // shadow_page_transform): rect_bounds and the shadow's placement each apply that move once.
  D2D1_MATRIX_3X2_F m = shadow_page_transform();
  D2D1_MATRIX_3X2_F world = matrix_product(
      m, D2D1::Matrix3x2F::Translation((FLOAT)(c->x + c->dx), (FLOAT)(baseline + c->dy)));
  D2D1_RECT_F text_box = {0, 0, 0, 0};
  glyphs->GetBounds(&world, &text_box);
  double pad = c->blur * 3 + 2;
  D2D1_RECT_F bounds;
  if (!rect_bounds(D2D1::RectF(text_box.left - (FLOAT)pad, text_box.top - (FLOAT)pad,
                               text_box.right + (FLOAT)pad, text_box.bottom + (FLOAT)pad),
                   &bounds)) {
    glyphs->Release();
    paint_text_run(c, c->dx, c->dy, c->shadow_color);
    paint_text_run(c, 0, 0, c->color);
    return;
  }
  int pw = (int)ceil((bounds.right - bounds.left) * g_scale);
  int ph = (int)ceil((bounds.bottom - bounds.top) * g_scale);
  ID2D1DeviceContext *dc = shadow_surface(pw, ph);
  if (dc && pw > 0 && ph > 0) {
    dc->BeginDraw();
    dc->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.0f));
    D2D1::Matrix3x2F place = D2D1::Matrix3x2F::Translation((FLOAT)(c->x + c->dx), (FLOAT)(baseline + c->dy));
    dc->SetTransform(matrix_product(
        D2D1::Matrix3x2F::Translation(-bounds.left, -bounds.top), matrix_product(m, place)));
    ID2D1SolidColorBrush *white = solid_brush_on(dc, 0xffffffffu, 1);
    if (white) {
      dc->FillGeometry(glyphs, white);
      white->Release();
    }
    dc->EndDraw();
    dc->SetTransform(D2D1::IdentityMatrix());
    ID2D1Bitmap1 *made = composite_blurred(pw, ph, c->blur, c->shadow_color, bounds, NULL);
    if (made) made->Release();
  }
  glyphs->Release();
  paint_text_run(c, 0, 0, c->color);
}

/** Fills a rounded rect with per-corner radii into a given context. */
static void dfill_round(ID2D1DeviceContext *dc, double x, double y, double w, double h,
                        const double r[8], ID2D1Brush *brush) {
  if (w <= 0 || h <= 0) return;
  Geo g;
  geo_begin(&g, D2D1_FILL_MODE_WINDING);
  geo_round_rect(&g, x, y, w, h, r);
  ID2D1PathGeometry *path = geo_end(&g);
  if (path) {
    dc->FillGeometry(path, brush);
    path->Release();
  }
}

static void paint_outer_shadow(const Cmd *c) { paint_shadow(c, 0); }
static void paint_inset_shadow(const Cmd *c) { paint_shadow(c, 1); }

static void paint_image(const Cmd *c) {
  if (c->image < 0 || c->image >= g_image_count) return;
  Image *img = &g_images[c->image];
  D2D1_RECT_F dest = D2D1::RectF((FLOAT)c->x, (FLOAT)c->y, (FLOAT)(c->x + c->w), (FLOAT)(c->y + c->h));
  D2D1_RECT_F src;
  int has_src = c->sw > 0 && c->sh > 0;
  if (has_src)
    src = D2D1::RectF((FLOAT)c->sx, (FLOAT)c->sy, (FLOAT)(c->sx + c->sw), (FLOAT)(c->sy + c->sh));
  D2D1_INTERPOLATION_MODE mode = c->smooth ? D2D1_INTERPOLATION_MODE_LINEAR : D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR;
  if (has_src) {
    // A source rect the bitmap doesn't cover would read outside it; keep it inside.
    if (src.left < 0) src.left = 0;
    if (src.top < 0) src.top = 0;
    if (src.right > img->w) src.right = (FLOAT)img->w;
    if (src.bottom > img->h) src.bottom = (FLOAT)img->h;
    if (src.right <= src.left || src.bottom <= src.top) return;
  }
  g_d2d->DrawBitmap(img->bitmap, &dest, (FLOAT)(c->size < 0 ? 0 : c->size > 1 ? 1 : c->size), mode,
                    has_src ? &src : NULL);
}

static void paint_gradient(const Cmd *c) {
  Stops st;
  if (parse_stops(c->text, &st) < 2) return;
  ID2D1GradientStopCollection *stops = make_stops(&st, g_d2d);
  if (!stops) return;
  if (c->kind == CMD_GRADIENT_LINEAR) {
    D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES props = D2D1::LinearGradientBrushProperties(
        D2D1::Point2F((FLOAT)c->p0, (FLOAT)c->p1), D2D1::Point2F((FLOAT)c->p2, (FLOAT)c->p3));
    ID2D1LinearGradientBrush *brush = NULL;
    if (SUCCEEDED(g_d2d->CreateLinearGradientBrush(&props, NULL, stops, &brush)) && brush) {
      brush->SetOpacity((FLOAT)(c->size < 0 ? 0 : c->size > 1 ? 1 : c->size));
      g_d2d->FillRectangle(
          D2D1::RectF((FLOAT)c->x, (FLOAT)c->y, (FLOAT)(c->x + c->w), (FLOAT)(c->y + c->h)), brush);
      brush->Release();
    }
  } else if (c->kind == CMD_GRADIENT_RADIAL) {
    double rx = c->p2 > 0 ? c->p2 : 0, ry = c->p3 > 0 ? c->p3 : 0;
    if (rx <= 0 || ry <= 0) {
      stops->Release();
      return;
    }
    // An elliptical gradient is a circular one under a non-uniform scale about its centre: the
    // brush and the rect the fill covers are both expressed in that scaled space.
    D2D1_MATRIX_3X2_F saved;
    g_d2d->GetTransform(&saved);
    double k = ry / rx;
    D2D1_MATRIX_3X2_F squash = D2D1::Matrix3x2F::Translation((FLOAT)c->p0, (FLOAT)c->p1) *
                              D2D1::Matrix3x2F::Scale(1.0f, (FLOAT)k) *
                              D2D1::Matrix3x2F::Translation((FLOAT)-c->p0, (FLOAT)-c->p1);
    g_d2d->SetTransform(replay_compose(saved, squash));
    D2D1_RADIAL_GRADIENT_BRUSH_PROPERTIES props = D2D1::RadialGradientBrushProperties(
        D2D1::Point2F((FLOAT)c->p0, (FLOAT)c->p1), D2D1::Point2F(0, 0), (FLOAT)rx, (FLOAT)rx);
    ID2D1RadialGradientBrush *brush = NULL;
    if (SUCCEEDED(g_d2d->CreateRadialGradientBrush(&props, NULL, stops, &brush)) && brush) {
      brush->SetOpacity((FLOAT)(c->size < 0 ? 0 : c->size > 1 ? 1 : c->size));
      double y0 = c->p1 + (c->y - c->p1) / k, y1 = c->p1 + (c->y + c->h - c->p1) / k;
      D2D1_RECT_F rect = D2D1::RectF((FLOAT)c->x, (FLOAT)y0, (FLOAT)(c->x + c->w), (FLOAT)y1);
      g_d2d->FillRectangle(rect, brush);
      brush->Release();
    }
    g_d2d->SetTransform(saved);
  } else {
    // A conic gradient has no brush of its own in Direct2D, so it is rasterized: one pixel per
    // device pixel of the box, each taking the stops' colour at its angle around the centre.
    double scale = g_scale;
    double x = round(c->x), y = round(c->y), w = round(c->x + c->w) - x, h = round(c->y + c->h) - y;
    int tw = (int)llround(w * scale), th = (int)llround(h * scale);
    if (tw > 0 && th > 0 && (double)tw * (double)th <= 16.0 * 1000 * 1000) {
      uint8_t *buf = (uint8_t *)malloc((size_t)tw * (size_t)th * 4);
      if (buf) {
        double cx = (c->p0 - x) * scale, cy = (c->p1 - y) * scale, start = c->p2;
        for (int j = 0; j < th; j++) {
          for (int i = 0; i < tw; i++) {
            double t = atan2((j + 0.5) - cy, (i + 0.5) - cx) - start;
            t = t / (2 * M_PI);
            t = t - floor(t);
            double col[4];
            stops_colour_at(&st, t, col);
            uint8_t *p = buf + ((size_t)j * (size_t)tw + (size_t)i) * 4;
            p[0] = (uint8_t)lround(col[2] * col[3] * 255);
            p[1] = (uint8_t)lround(col[1] * col[3] * 255);
            p[2] = (uint8_t)lround(col[0] * col[3] * 255);
            p[3] = (uint8_t)lround(col[3] * 255);
          }
        }
        D2D1_BITMAP_PROPERTIES1 tile_props = D2D1::BitmapProperties1(
            D2D1_BITMAP_OPTIONS_NONE,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
            96.0f * (float)g_scale, 96.0f * (float)g_scale);
        ID2D1Bitmap1 *tile = NULL;
        if (SUCCEEDED(g_d2d->CreateBitmap(D2D1::SizeU((UINT32)tw, (UINT32)th), buf, (UINT32)tw * 4,
                                          &tile_props, &tile)) &&
            tile) {
          // The tile is the box in the box's own space, so it is drawn under the transform in
          // effect: a turned or moved box turns or moves its conic gradient with it (drawn under
          // the identity it stood still in the page, and a composited chunk's raster, whose
          // transform moves the page into its texture, lost it altogether).
          D2D1_RECT_F dest = D2D1::RectF((FLOAT)x, (FLOAT)y, (FLOAT)(x + w), (FLOAT)(y + h));
          g_d2d->DrawBitmap(tile, &dest, (FLOAT)(c->size < 0 ? 0 : c->size > 1 ? 1 : c->size),
                            D2D1_INTERPOLATION_MODE_LINEAR, NULL);
          tile->Release();
        }
        free(buf);
      }
    }
  }
  stops->Release();
}

static size_t replay_range(Replay *r, size_t i);

/** The index of the pop that closes the layer opened at `i`, without drawing anything. */
static size_t layer_pop_index(size_t i) {
  int nested = 0;
  for (size_t k = i; k < g_count; k++) {
    int kind = g_cmds[k].kind;
    if (kind == CMD_EFFECT_PUSH || kind == CMD_MASK_PUSH || kind == CMD_PERSPECTIVE_PUSH) nested++;
    else if (kind == CMD_EFFECT_POP || kind == CMD_MASK_POP || kind == CMD_PERSPECTIVE_POP) {
      nested--;
      if (nested == 0) return k;
    }
  }
  return g_count;
}

/** Paints a box's layer: its subtree filtered, then composited into the page. */
static size_t replay_effect(Replay *r, size_t i) {
  Cmd *c = &g_cmds[i];
  EffectSpec spec;
  effect_spec_parse(&spec, c->text);
  if (c->alpha_override) spec.alpha = (float)c->alpha;
  if (spec.count == 0 || !g_d2d) {
    // An opacity group with no filter chain to it needs no bitmap: a layer fades what the box
    // paints, however far it reaches past the box.
    size_t pop;
    if (spec.alpha < 1) {
      push_opacity_layer(r, spec.alpha);
      pop = replay_range(r, i + 1);
      replay_state_restore(r);
    } else {
      // Nothing to fade and nothing to filter: the box paints in place.
      pop = replay_range(r, i + 1);
    }
    return pop;
  }
  size_t pop = layer_pop_index(i);
  // The filter region is the border box grown by 10% on every side (CSS Filter Effects), mapped
  // through the page's transform into the device pixels the layer is cut from.
  double pad = fmax(c->w, c->h) * 0.1 + 1;
  D2D1_RECT_F bounds;
  if (!shadow_bounds(c, pad, &bounds)) return pop;
  int pw = (int)ceil((bounds.right - bounds.left) * g_scale);
  int ph = (int)ceil((bounds.bottom - bounds.top) * g_scale);
  if (pw < 1 || ph < 1 || (double)pw * ph > 64.0 * 1024 * 1024) return pop;
  LayerSurface *surface = layer_surface(g_layer_depth, pw, ph);
  if (!surface) return pop;
  D2D1_MATRIX_3X2_F m;
  g_d2d->GetTransform(&m);
  g_layer_depth++;
  surface->dc->BeginDraw();
  surface->dc->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.0f));
  surface->dc->SetTransform(
      matrix_product(D2D1::Matrix3x2F::Translation(-bounds.left, -bounds.top), m));
  ID2D1DeviceContext *page = g_d2d;
  g_d2d = surface->dc;
  size_t drawn = replay_range(r, i + 1);
  (void)drawn;
  g_d2d = page;
  surface->dc->EndDraw();
  surface->dc->SetTransform(D2D1::IdentityMatrix());
  g_layer_depth--;

  // The layer's pixels, filtered, then drawn where the box sits.
  D2D1_BITMAP_PROPERTIES1 cpu_props = D2D1::BitmapProperties1(
      (D2D1_BITMAP_OPTIONS)(D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW),
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
      96.0f * (float)g_scale, 96.0f * (float)g_scale);
  ID2D1Bitmap1 *cpu = NULL;
  if (FAILED(surface->dc->CreateBitmap(D2D1::SizeU((UINT32)pw, (UINT32)ph), NULL, 0, &cpu_props, &cpu)) ||
      !cpu)
    return pop;
  D2D1_MAPPED_RECT mapped = {0};
  if (SUCCEEDED(cpu->CopyFromBitmap(NULL, surface->bitmap, NULL)) &&
      SUCCEEDED(cpu->Map(D2D1_MAP_OPTIONS_READ, &mapped))) {
    size_t count = (size_t)pw * (size_t)ph;
    FilterPixel *pixels = (FilterPixel *)malloc(count * sizeof(FilterPixel));
    if (pixels) {
      for (int y = 0; y < ph; y++) {
        const uint8_t *row = mapped.bits + (size_t)y * (size_t)mapped.pitch;
        for (int x = 0; x < pw; x++) {
          const uint8_t *p = row + x * 4;
          FilterPixel *out = &pixels[(size_t)y * (size_t)pw + (size_t)x];
          out->b = p[0] / 255.0;
          out->g = p[1] / 255.0;
          out->r = p[2] / 255.0;
          out->a = p[3] / 255.0;
        }
      }
      cpu->Unmap();
      apply_filters(pixels, pw, ph, spec.ops, spec.count, g_scale);
      uint8_t *bytes = (uint8_t *)malloc(count * 4);
      if (bytes) {
        for (size_t k = 0; k < count; k++) {
          uint8_t *p = bytes + k * 4;
          p[0] = (uint8_t)(fmin(1, fmax(0, pixels[k].b)) * 255.0 + 0.5);
          p[1] = (uint8_t)(fmin(1, fmax(0, pixels[k].g)) * 255.0 + 0.5);
          p[2] = (uint8_t)(fmin(1, fmax(0, pixels[k].r)) * 255.0 + 0.5);
          p[3] = (uint8_t)(fmin(1, fmax(0, pixels[k].a)) * 255.0 + 0.5);
        }
        D2D1_BITMAP_PROPERTIES1 layer_props = D2D1::BitmapProperties1(
            D2D1_BITMAP_OPTIONS_NONE,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
            96.0f * (float)g_scale, 96.0f * (float)g_scale);
        ID2D1Bitmap1 *layer = NULL;
        if (SUCCEEDED(g_d2d->CreateBitmap(D2D1::SizeU((UINT32)pw, (UINT32)ph), bytes, (UINT32)pw * 4,
                                          &layer_props, &layer)) &&
            layer) {
          D2D1_RECT_F dest = bounds;
          double alpha = spec.alpha < 0 ? 0 : spec.alpha > 1 ? 1 : spec.alpha;
          g_d2d->DrawBitmap(layer, &dest, (FLOAT)alpha, D2D1_INTERPOLATION_MODE_LINEAR, NULL);
          layer->Release();
        }
        free(bytes);
      }
      free(pixels);
    } else {
      cpu->Unmap();
    }
  }
  cpu->Release();
  return pop;
}

/** Whether a square clip, under the current transform, holds the whole view in it. */
static int clip_covers_view(const Cmd *c) {
  D2D1_MATRIX_3X2_F m;
  g_d2d->GetTransform(&m);
  if (m._12 != 0 || m._21 != 0) return 0;
  double x0 = c->x * m._11 + m._31 + g_comp_origin_x, x1 = (c->x + c->w) * m._11 + m._31 + g_comp_origin_x;
  double y0 = c->y * m._22 + m._32 + g_comp_origin_y, y1 = (c->y + c->h) * m._22 + m._32 + g_comp_origin_y;
  return fmin(x0, x1) <= 0 && fmin(y0, y1) <= 0 && fmax(x0, x1) >= g_view_w && fmax(y0, y1) >= g_view_h;
}

static size_t replay_range(Replay *r, size_t i) {
  for (; i < g_count; i++) {
    Cmd *c = &g_cmds[i];
    if (g_chunk_mode) {
      if (i >= g_chunk_last) break;
      if (i < g_chunk_first) {
        if (c->kind == CMD_EFFECT_PUSH) {
          replay_state_save(r, 4, NULL); // skipped, but the pop must restore the same state
          continue;
        }
        if (c->kind == CMD_EFFECT_POP) {
          replay_state_restore(r);
          continue;
        }
        if (c->kind == CMD_MASK_PUSH || c->kind == CMD_MASK_SPLIT || c->kind == CMD_MASK_POP ||
            c->kind == CMD_PERSPECTIVE_PUSH || c->kind == CMD_PERSPECTIVE_POP) {
          // A frame with a mask or a projection is one the walk hands to the flat replay.
          continue;
        }
        if (!g_chunk_clips && (c->kind == CMD_CLIP || c->kind == CMD_CLIP_ROUND ||
                               c->kind == CMD_CLIP_POLY || c->kind == CMD_CLIP_SHAPE ||
                               c->kind == CMD_CLIP_ELLIPSE)) {
          replay_state_save(r, 4, NULL);
          continue;
        }
        if (c->kind == CMD_CLIP && !(c->radius > 0) && clip_covers_view(c)) {
          // A square clip around the whole view cuts nothing the window shows. Left out of a
          // chunk's raster, it leaves the chunk whole past the view's edge, so the chunk can move.
          replay_state_save(r, 4, NULL);
          continue;
        }
        if (c->kind != CMD_TRANSFORM && c->kind != CMD_UNCLIP && c->kind != CMD_CLIP &&
            c->kind != CMD_CLIP_ROUND && c->kind != CMD_CLIP_POLY && c->kind != CMD_CLIP_SHAPE &&
            c->kind != CMD_CLIP_ELLIPSE) {
          continue; // a draw before the chunk: state only
        }
      }
    }
    if (c->kind == CMD_EFFECT_POP || c->kind == CMD_MASK_SPLIT || c->kind == CMD_MASK_POP ||
        c->kind == CMD_PERSPECTIVE_POP) {
      return i;
    }
    if (c->kind == CMD_EFFECT_PUSH) {
      double prof = now_ms();
      i = replay_effect(r, i);
      g_prof_effect += now_ms() - prof;
      continue;
    }
    if (c->kind == CMD_MASK_PUSH) {
      // The commands before the split are the mask shape itself, and the mask isn't applied yet:
      // what the box paints is the part after the split, which is replayed inside a plain layer.
      size_t split = i + 1, pop = g_count;
      int nested = 0;
      for (size_t k = i + 1; k < g_count; k++) {
        int kind = g_cmds[k].kind;
        if (kind == CMD_MASK_PUSH) nested++;
        else if (kind == CMD_MASK_POP) {
          if (nested == 0) {
            pop = k;
            break;
          }
          nested--;
        } else if (kind == CMD_MASK_SPLIT && nested == 0) {
          split = k;
        }
      }
      push_clip_layer(r, NULL);
      if (split + 1 <= pop) replay_range(r, split + 1);
      replay_state_restore(r);
      i = pop;
      continue;
    }
    if (c->kind == CMD_PERSPECTIVE_PUSH) {
      // The box paints where the page laid it out; the quad's projection is not applied.
      replay_state_save(r, 0, NULL);
      size_t pop = replay_range(r, i + 1);
      replay_state_restore(r);
      i = pop;
      continue;
    }
    if (c->kind == CMD_FILL) {
      double x = c->x, y = c->y, w = c->w, h = c->h;
      snap_box(r, &x, &y, &w, &h);
      if (c->radius > 0) {
        ID2D1SolidColorBrush *brush = solid_brush(c->color, 1);
        if (brush) {
          D2D1_ROUNDED_RECT round = D2D1::RoundedRect(
              D2D1::RectF((FLOAT)x, (FLOAT)y, (FLOAT)(x + w), (FLOAT)(y + h)), (FLOAT)c->radius,
              (FLOAT)c->radius);
          g_d2d->FillRoundedRectangle(round, brush);
          brush->Release();
        }
      } else {
        ID2D1SolidColorBrush *brush = solid_brush(c->color, 1);
        if (brush) {
          g_d2d->FillRectangle(D2D1::RectF((FLOAT)x, (FLOAT)y, (FLOAT)(x + w), (FLOAT)(y + h)), brush);
          brush->Release();
        }
      }
    } else if (c->kind == CMD_FILL_ROUND) {
      double radius = radii_uniform(c->r);
      if (radius > 0) {
        ID2D1SolidColorBrush *brush = solid_brush(c->color, 1);
        if (brush) {
          D2D1_ROUNDED_RECT round = D2D1::RoundedRect(
              D2D1::RectF((FLOAT)c->x, (FLOAT)c->y, (FLOAT)(c->x + c->w), (FLOAT)(c->y + c->h)),
              (FLOAT)radius, (FLOAT)radius);
          g_d2d->FillRoundedRectangle(round, brush);
          brush->Release();
        }
      } else {
        Geo g;
        geo_begin(&g, D2D1_FILL_MODE_WINDING);
        geo_round_rect(&g, c->x, c->y, c->w, c->h, c->r);
        ID2D1PathGeometry *path = geo_end(&g);
        if (path) {
          fill_geometry(path, c->color, 1);
          path->Release();
        }
      }
    } else if (c->kind == CMD_RING) {
      double b = c->line_width;
      if (b <= 0 || c->w - 2 * b <= 0 || c->h - 2 * b <= 0) continue;
      double radius = c->radius > b ? c->radius - b / 2 : 0;
      double half = b / 2;
      ID2D1SolidColorBrush *brush = solid_brush(c->color, 1);
      if (brush) {
        D2D1_ROUNDED_RECT round = D2D1::RoundedRect(
            D2D1::RectF((FLOAT)(c->x + half), (FLOAT)(c->y + half), (FLOAT)(c->x + c->w - half),
                        (FLOAT)(c->y + c->h - half)),
            (FLOAT)radius, (FLOAT)radius);
        g_d2d->DrawRoundedRectangle(round, brush, (FLOAT)b, NULL);
        brush->Release();
      }
    } else if (c->kind == CMD_RING_ROUND) {
      double b = c->line_width;
      if (b <= 0) continue;
      double radius = radii_uniform(c->r);
      if (radius > 0 && c->w > 2 * b && c->h > 2 * b) {
        // A border whose corners share a radius is a stroked rounded rect down its middle: the
        // pen is the border's own width, and the path sits half of that inside the border box.
        double half = b / 2;
        ID2D1SolidColorBrush *brush = solid_brush(c->color, 1);
        if (brush) {
          D2D1_ROUNDED_RECT round = D2D1::RoundedRect(
              D2D1::RectF((FLOAT)(c->x + half), (FLOAT)(c->y + half), (FLOAT)(c->x + c->w - half),
                          (FLOAT)(c->y + c->h - half)),
              (FLOAT)(radius - half > 0 ? radius - half : 0), (FLOAT)(radius - half > 0 ? radius - half : 0));
          g_d2d->DrawRoundedRectangle(round, brush, (FLOAT)b, NULL);
          brush->Release();
        }
      } else {
        double inner[8];
        for (int k = 0; k < 8; k++) inner[k] = c->r[k] - b;
        Geo g;
        geo_begin(&g, D2D1_FILL_MODE_ALTERNATE);
        geo_round_rect(&g, c->x, c->y, c->w, c->h, c->r);
        geo_round_rect(&g, c->x + b, c->y + b, c->w - 2 * b, c->h - 2 * b, inner);
        ID2D1PathGeometry *path = geo_end(&g);
        if (path) {
          fill_geometry(path, c->color, 1);
          path->Release();
        }
      }
    } else if (c->kind == CMD_LINE) {
      double x0 = c->x, span = c->w, y = c->y, t = c->line_width;
      int style = (int)c->radius;
      double x1 = x0 + span;
      if (span > 0 && t > 0) {
        if (style == 1) {
          double part = t / 3;
          ID2D1SolidColorBrush *brush = solid_brush(c->color, 1);
          if (brush) {
            g_d2d->FillRectangle(D2D1::RectF((FLOAT)x0, (FLOAT)y, (FLOAT)x1, (FLOAT)(y + part)), brush);
            g_d2d->FillRectangle(D2D1::RectF((FLOAT)x0, (FLOAT)(y + 2 * part), (FLOAT)x1, (FLOAT)(y + 3 * part)), brush);
            brush->Release();
          }
        } else if (style == 2) {
          ID2D1SolidColorBrush *brush = solid_brush(c->color, 1);
          if (brush) {
            for (double x = x0; x < x1; x += 2 * t) {
              double w = fmin(t, x1 - x);
              g_d2d->FillRectangle(D2D1::RectF((FLOAT)x, (FLOAT)y, (FLOAT)(x + w), (FLOAT)(y + t)), brush);
            }
            brush->Release();
          }
        } else if (style == 3) {
          ID2D1SolidColorBrush *brush = solid_brush(c->color, 1);
          if (brush) {
            for (double x = x0; x < x1; x += 5 * t) {
              double w = fmin(3 * t, x1 - x);
              g_d2d->FillRectangle(D2D1::RectF((FLOAT)x, (FLOAT)y, (FLOAT)(x + w), (FLOAT)(y + t)), brush);
            }
            brush->Release();
          }
        } else if (style == 4) {
          double amp = t, period = fmax(8, 4 * t);
          Geo g;
          geo_begin(&g, D2D1_FILL_MODE_WINDING);
          if (g.sink) {
            int first = 1;
            for (double x = x0;; x += 1) {
              double xx = x > x1 ? x1 : x;
              double yy = y + t / 2 + amp * sin(2 * M_PI * (xx - x0) / period);
              if (first) {
                g.sink->BeginFigure(D2D1::Point2F((FLOAT)xx, (FLOAT)yy), D2D1_FIGURE_BEGIN_HOLLOW);
                first = 0;
              } else {
                g.sink->AddLine(D2D1::Point2F((FLOAT)xx, (FLOAT)yy));
              }
              if (xx >= x1) break;
            }
            g.sink->EndFigure(D2D1_FIGURE_END_OPEN);
          }
          ID2D1PathGeometry *path = geo_end(&g);
          ID2D1SolidColorBrush *brush = solid_brush(c->color, 1);
          if (path && brush) {
            g_d2d->DrawGeometry(path, brush, (FLOAT)t, NULL);
          }
          if (brush) brush->Release();
          if (path) path->Release();
        } else {
          double x = x0, w = span;
          snap_box(r, &x, &y, &w, &t);
          ID2D1SolidColorBrush *brush = solid_brush(c->color, 1);
          if (brush) {
            g_d2d->FillRectangle(D2D1::RectF((FLOAT)x, (FLOAT)y, (FLOAT)(x + w), (FLOAT)(y + t)), brush);
            brush->Release();
          }
        }
      }
    } else if (c->kind == CMD_POLY) {
      Geo g;
      geo_begin(&g, D2D1_FILL_MODE_WINDING);
      if (g.sink) geo_points(&g, c->text, c->len);
      ID2D1PathGeometry *path = geo_end(&g);
      if (path) {
        fill_geometry(path, c->color, 1);
        path->Release();
      }
    } else if (c->kind == CMD_CLIP) {
      if (c->radius > 0) {
        Geo g;
        geo_begin(&g, D2D1_FILL_MODE_WINDING);
        geo_uniform_round(&g, c->x, c->y, c->w, c->h, c->radius);
        ID2D1PathGeometry *path = geo_end(&g);
        push_clip_layer(r, path);
        if (path) path->Release();
      } else {
        double x = c->x, y = c->y, w = c->w, h = c->h;
        snap_box(r, &x, &y, &w, &h);
        D2D1_RECT_F rect = D2D1::RectF((FLOAT)x, (FLOAT)y, (FLOAT)(x + w), (FLOAT)(y + h));
        g_d2d->PushAxisAlignedClip(rect, D2D1_ANTIALIAS_MODE_ALIASED);
        debug_clip("axis", NULL, x, y, w, h);
        replay_state_save(r, 1, NULL);
      }
    } else if (c->kind == CMD_CLIP_ROUND) {
      Geo g;
      geo_begin(&g, D2D1_FILL_MODE_WINDING);
      geo_round_rect(&g, c->x, c->y, c->w, c->h, c->r);
      ID2D1PathGeometry *path = geo_end(&g);
      push_clip_layer(r, path);
      if (path) path->Release();
    } else if (c->kind == CMD_CLIP_POLY || c->kind == CMD_CLIP_SHAPE) {
      Geo g;
      geo_begin(&g, c->kind == CMD_CLIP_SHAPE && c->p0 != 0 ? D2D1_FILL_MODE_ALTERNATE
                                                            : D2D1_FILL_MODE_WINDING);
      if (g.sink) geo_points(&g, c->text, c->len);
      ID2D1PathGeometry *path = geo_end(&g);
      push_clip_layer(r, path);
      if (path) path->Release();
    } else if (c->kind == CMD_CLIP_ELLIPSE) {
      if (c->p2 > 0 && c->p3 > 0) {
        Geo g;
        geo_begin(&g, D2D1_FILL_MODE_WINDING);
        geo_ellipse(&g, c->p0, c->p1, c->p2, c->p3);
        ID2D1PathGeometry *path = geo_end(&g);
        push_clip_layer(r, path);
        if (path) path->Release();
      } else {
        D2D1_RECT_F empty = D2D1::RectF((FLOAT)c->p0, (FLOAT)c->p1, (FLOAT)c->p0, (FLOAT)c->p1);
        g_d2d->PushAxisAlignedClip(empty, D2D1_ANTIALIAS_MODE_ALIASED);
        replay_state_save(r, 1, NULL);
      }
    } else if (c->kind == CMD_TRANSFORM) {
      D2D1_MATRIX_3X2_F saved;
      g_d2d->GetTransform(&saved);
      D2D1_MATRIX_3X2_F m = D2D1::Matrix3x2F((FLOAT)c->p0, (FLOAT)c->p1, (FLOAT)c->p2, (FLOAT)c->p3,
                                             (FLOAT)c->r[0], (FLOAT)c->r[1]);
      replay_state_save(r, 0, NULL);
      g_d2d->SetTransform(replay_compose(saved, m));
      r->transforms++;
    } else if (c->kind == CMD_UNCLIP) {
      replay_state_restore(r);
    } else if (c->kind == CMD_CANVAS) {
      double prof = now_ms();
      gl_present_canvas_for(c->image);
      ID2D1Bitmap1 *bitmap = canvas_bitmap(c->image);
      if (bitmap) {
        D2D1_RECT_F dest =
            D2D1::RectF((FLOAT)c->x, (FLOAT)c->y, (FLOAT)(c->x + c->w), (FLOAT)(c->y + c->h));
        D2D1_RECT_F src;
        int has_src = c->sw > 0 && c->sh > 0;
        if (has_src)
          src = D2D1::RectF((FLOAT)c->sx, (FLOAT)c->sy, (FLOAT)(c->sx + c->sw), (FLOAT)(c->sy + c->sh));
        g_d2d->DrawBitmap(bitmap, &dest, (FLOAT)(c->size < 0 ? 0 : c->size > 1 ? 1 : c->size),
                          c->smooth ? D2D1_INTERPOLATION_MODE_LINEAR
                                    : D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR,
                          has_src ? &src : NULL);
      }
      g_prof_canvas += now_ms() - prof;
    } else if (c->kind == CMD_IMAGE) {
      paint_image(c);
    } else if (c->kind == CMD_GRADIENT_LINEAR || c->kind == CMD_GRADIENT_RADIAL ||
               c->kind == CMD_GRADIENT_CONIC) {
      paint_gradient(c);
    } else if (c->kind == CMD_TEXT) {
      double prof = now_ms();
      paint_text_run(c, 0, 0, c->color);
      g_prof_text += now_ms() - prof;
    } else if (c->kind == CMD_TEXT_SHADOW) {
      double prof = now_ms();
      paint_text_shadow(c);
      g_prof_text += now_ms() - prof;
    } else if (c->kind == CMD_SHADOW) {
      double prof = now_ms();
      paint_outer_shadow(c);
      g_prof_shadow += now_ms() - prof;
    } else if (c->kind == CMD_SHADOW_INSET) {
      double prof = now_ms();
      paint_inset_shadow(c);
      g_prof_shadow += now_ms() - prof;
    }
  }
  return i;
}

// ---------------------------------------------------------------------------
// The frame and the window

/** Prints the frame's command list when NATIVE_DEBUG_LIST asks, for a frame that came out empty. */
static void debug_list(void) {
  if (getenv("NATIVE_DEBUG_LIST") == NULL) return;
  int counts[64] = {0};
  for (size_t k = 0; k < g_count; k++) counts[g_cmds[k].kind]++;
  fprintf(stderr, "native: cmds=%zu", g_count);
  for (int k = 0; k < 64; k++)
    if (counts[k] != 0) fprintf(stderr, " %d=%d", k, counts[k]);
  fprintf(stderr, "\n");
  for (size_t k = 0; k < g_count && k < 60; k++) {
    Cmd *c = &g_cmds[k];
    fprintf(stderr, "native: cmd %zu kind=%d %.1f,%.1f %.1fx%.1f size=%.1f\n", k, c->kind, c->x, c->y,
            c->w, c->h, c->size);
  }
}

/** Paints the recorded frame into the current target: the page background, then the commands. */
static void paint_frame(void) {
  g_d2d->SetTransform(D2D1::IdentityMatrix());
  double prof_clear = now_ms();
  g_d2d->Clear(colour_of(g_background, 1));
  g_prof_clear += now_ms() - prof_clear;
  double prof = now_ms();
  Replay *r = &g_replay;
  r->depth = 0;
  r->transforms = 0;
  r->width = g_view_w;
  r->height = g_view_h;
  replay_range(r, 0);
  // A command list can end with pushes still open (a frame cut short); unwind them so the next
  // frame starts with no clip and no transform.
  while (r->depth > 0) replay_state_restore(r);
  g_prof_replay += now_ms() - prof;
  debug_list();
}

static char g_title[512] = "";
static int32_t g_win_id = 1;
static double g_win_x = 0, g_win_y = 0;
static int32_t g_fullscreen = 0;
static int32_t g_hidden = 0;

// The window's menu bar, rebuilt from the spec the page asked for.
static HMENU g_menu_bar = NULL;

/**
 * A menu label with its access key marked the way Windows underlines it: the letter the page's
 * accesskey names, or the label's first letter for a menu of the bar. The caller frees the result.
 */
static wchar_t *menu_label_with_key(const char *label, const char *keys, int bar_menu) {
  size_t label_len = strlen(label);
  int mark = -1;
  if (keys[0] != '\0' && keys[1] == '\0' && isalpha((unsigned char)keys[0])) {
    for (size_t i = 0; i < label_len; i++) {
      if (tolower((unsigned char)label[i]) == tolower((unsigned char)keys[0])) {
        mark = (int)i;
        break;
      }
    }
  } else if (bar_menu) {
    for (size_t i = 0; i < label_len; i++) {
      if (isalpha((unsigned char)label[i])) {
        mark = (int)i;
        break;
      }
    }
  }
  wchar_t *out = NULL;
  if (mark >= 0) {
    char marked[512];
    if (label_len + 1 >= sizeof(marked)) return NULL;
    memcpy(marked, label, (size_t)mark);
    marked[mark] = '&';
    memcpy(marked + mark + 1, label + mark, label_len - (size_t)mark + 1);
    out = utf8_to_utf16((const uint8_t *)marked, strlen(marked), NULL);
  } else {
    out = utf8_to_utf16((const uint8_t *)label, label_len, NULL);
  }
  return out;
}

/**
 * Rebuilds the window's menu bar from a menu spec (see runtime/menus.ts for the format): one line
 * per item, `label 	 keys 	 disabled`, two spaces of indent per level. A top-level line with no
 * label is the app's own menu, and an item whose next line is deeper is a submenu.
 */
static void build_menu_bar(const char *spec) {
  if (g_menu_bar) {
    if (g_hwnd) SetMenu(g_hwnd, NULL);
    DestroyMenu(g_menu_bar);
    g_menu_bar = NULL;
  }
  if (!spec || spec[0] == '\0') return;
  HMENU bar = CreateMenu();
  if (!bar) return;
  char *text = dup_str(spec);
  if (!text) {
    DestroyMenu(bar);
    return;
  }
  // The lines of the spec, and how deep each one sits.
  char **lines = NULL;
  int *depths = NULL;
  size_t count = 0, cap = 0;
  // The first line may be empty — the app's own menu has no label — so the walk starts at the
  // buffer itself rather than at its first character.
  for (char *line = text; line != NULL;) {
    char *next = strchr(line, '\n');
    if (next) *next = '\0';
    int depth = 0;
    while (line[0] == ' ' && line[1] == ' ') {
      depth++;
      line += 2;
    }
    if ((size_t)depth >= cap) {
      size_t grown = depth + 16;
      char **new_lines = (char **)realloc(lines, grown * sizeof(char *));
      int *new_depths = (int *)realloc(depths, grown * sizeof(int));
      if (!new_lines || !new_depths) {
        free(new_lines ? new_lines : lines);
        free(new_depths ? new_depths : depths);
        free(text);
        DestroyMenu(bar);
        return;
      }
      lines = new_lines;
      depths = new_depths;
      cap = grown;
    }
    lines[count] = line;
    depths[count] = depth;
    count++;
    line = next ? next + 1 : NULL;
  }
  // menus[d] holds the menu the lines of depth `d` are appended to: a popup a depth-0 line made.
  HMENU menus[16];
  for (int i = 0; i < 16; i++) menus[i] = NULL;
  for (size_t i = 0; i < count; i++) {
    int depth = depths[i] < 15 ? depths[i] : 15;
    char *label = lines[i];
    char *keys = (char *)"";
    char *disabled = (char *)"0";
    char *tab = strchr(label, '\t');
    if (tab) {
      *tab = '\0';
      keys = tab + 1;
      char *tab2 = strchr(keys, '\t');
      if (tab2) {
        *tab2 = '\0';
        disabled = tab2 + 1;
      }
    }
    (void)keys;
    UINT flags = disabled[0] == '1' ? MF_GRAYED : 0;
    if (depth == 0) {
      // A bar menu: the line's label heads a popup this spec fills, or, with no label, the app's
      // own menu, which Windows names after the application.
      HMENU menu = CreatePopupMenu();
      if (!menu) continue;
      wchar_t *wide = label[0] ? menu_label_with_key(label, "", 1) : NULL;
      if (AppendMenuW(bar, MF_POPUP | flags, (UINT_PTR)menu, wide ? wide : L"App")) {
        menus[1] = menu;
      } else {
        DestroyMenu(menu);
      }
      free(wide);
      continue;
    }
    HMENU parent = menus[depth] ? menus[depth] : bar;
    if (label[0] == '\0' || (label[0] == '-' && label[1] == '\0')) {
      AppendMenuW(parent, MF_SEPARATOR, 0, NULL);
      continue;
    }
    wchar_t *wide = menu_label_with_key(label, keys, 0);
    if (!wide) continue;
    if (i + 1 < count && depths[i + 1] > depth) {
      HMENU sub = CreatePopupMenu();
      if (sub && AppendMenuW(parent, MF_POPUP | flags, (UINT_PTR)sub, wide)) {
        menus[depth + 1] = sub;
      } else if (sub) {
        DestroyMenu(sub);
      }
    } else {
      // A leaf reports its line in the spec on WM_COMMAND, one past its index so zero stays "none".
      AppendMenuW(parent, MF_STRING | flags, (UINT_PTR)(i + 1), wide);
    }
    free(wide);
  }
  free(lines);
  free(depths);
  free(text);
  g_menu_bar = bar;
  if (g_hwnd) {
    // Attaching a menu to a window that is already open adds a row above the page, so the window
    // grows by it rather than the page losing that row.
    RECT client;
    if (GetClientRect(g_hwnd, &client)) {
      int cw = client.right - client.left, ch = client.bottom - client.top;
      SetMenu(g_hwnd, g_menu_bar);
      DrawMenuBar(g_hwnd);
      RECT want = {0, 0, cw, ch};
      AdjustWindowRectEx(&want, WS_OVERLAPPEDWINDOW, g_menu_bar != NULL, 0);
      SetWindowPos(g_hwnd, NULL, 0, 0, want.right - want.left, want.bottom - want.top,
                   SWP_NOMOVE | SWP_NOZORDER | SWP_FRAMECHANGED);
    }
  }
}

extern "C" {

void host_open(double width, double height, const uint8_t *title, size_t title_len,
               const uint8_t *options, size_t options_len) {
  (void)options;
  (void)options_len;
  if (title_len >= sizeof(g_title)) title_len = sizeof(g_title) - 1;
  memcpy(g_title, title, title_len);
  g_title[title_len] = '\0';
  const char *id = getenv("NATIVE_WINDOW_ID");
  if (id != NULL) g_win_id = (int32_t)strtol(id, NULL, 10);
  if (!ensure_device()) return;
  enable_dpi_awareness();
  size_t wide_len = 0;
  wchar_t *wide = utf8_to_utf16((const uint8_t *)g_title, strlen(g_title), &wide_len);
  g_hwnd = CreateWindowExW(0, window_class_name(), wide ? wide : L"", WS_OVERLAPPEDWINDOW,
                           CW_USEDEFAULT, CW_USEDEFAULT, 400, 300, NULL, g_menu_bar,
                           GetModuleHandleW(NULL), NULL);
  free(wide);
  if (!g_hwnd) return;
  // A machine with no input method installed gives a window no IME context, which leaves nothing
  // for a test to drive; NATIVE_IME_TEST gives the window a default one.
  if (getenv("NATIVE_IME_TEST") != NULL) {
    HIMC context = ImmCreateContext();
    if (context) ImmAssociateContext(g_hwnd, context);
  }
  DragAcceptFiles(g_hwnd, TRUE);
  ax_ensure();
  g_scale = window_scale(g_hwnd);
  // The client area is the page's own size, whatever the frame around it costs.
  RECT want = {0, 0, (LONG)ceil(width * g_scale), (LONG)ceil(height * g_scale)};
  AdjustWindowRectEx(&want, WS_OVERLAPPEDWINDOW, g_menu_bar != NULL, 0);
  SetWindowPos(g_hwnd, NULL, 0, 0, want.right - want.left, want.bottom - want.top,
               SWP_NOMOVE | SWP_NOZORDER);
  update_view_size();
  ensure_window_target();
  ShowWindow(g_hwnd, SW_SHOW);
  UpdateWindow(g_hwnd);
}

/** Paints the recorded frame into the window and shows it. */
static void present_now(void) {
  if (!g_hwnd) return;
  // A window dragged to another display presents through that display's output.
  retarget_window_monitor();
  double prof_target = now_ms();
  if (!ensure_window_target()) return;
  g_prof_target += now_ms() - prof_target;
  double started = frame_times() ? now_ms() : 0;
  // The window's compositor draws the frame from the chunk textures it keeps, presenting on the
  // swap chain at the display's pace; a frame its walk can't express is the replay's below.
  if (window_composite()) {
    frame_time("present", started);
    return;
  }
  double prof_begin = now_ms();
  g_d2d->BeginDraw();
  g_prof_begin += now_ms() - prof_begin;
  paint_frame();
  double prof_draw = now_ms();
  HRESULT hr = g_d2d->EndDraw();
  g_prof_enddraw += now_ms() - prof_draw;
  if (hr == D2DERR_RECREATE_TARGET) {
    release_target();
    if (g_swap) {
      g_swap->Release();
      g_swap = NULL;
    }
    ensure_window_target();
  } else if (g_swap) {
    double prof_present = now_ms();
    g_swap->Present(0, 0);
    g_prof_present += now_ms() - prof_present;
  }
  frame_time("present", started);
  if (frame_times()) {
    // Where the replay spent its time, in the same units as the frame's stages.
    fprintf(stderr, "native: replay total=%.1f effect=%.1f shadow=%.1f text=%.1f canvas=%.1f enddraw=%.1f present=%.1f\n",
            g_prof_replay, g_prof_effect, g_prof_shadow, g_prof_text, g_prof_canvas, g_prof_enddraw, g_prof_present);
    fprintf(stderr, "native: replay clear=%.1f target=%.1f begin=%.1f\n", g_prof_clear, g_prof_target, g_prof_begin);
    g_prof_clear = g_prof_target = g_prof_begin = 0;
    g_prof_effect = g_prof_shadow = g_prof_text = g_prof_canvas = 0;
    g_prof_replay = g_prof_enddraw = g_prof_present = 0;
  }
}

void host_present(double width, double height) {
  (void)width;
  (void)height;
  present_now();
}

// The Windows host has no damage-limited display list yet: every frame records the whole page.
// These keep the API the runtime expects, and host_compositor_on says so, which asks the painter
// for a full frame. A composited frame walks the whole list either way — it only rasters the
// chunks that changed — so a moved scroll (which hands this host the rectangles it touched) is
// presented from the retained textures rather than the page being painted again.

void host_damage_begin(uint32_t background, const uint8_t *rects, size_t n) {
  (void)rects;
  (void)n;
  host_begin(background);
}

void host_present_damage(const uint8_t *rects, size_t n, double width, double height) {
  (void)rects;
  (void)n;
  host_present(width, height);
}

void host_present_region(const uint8_t *rects, size_t n, double width, double height) {
  (void)rects;
  (void)n;
  host_present(width, height);
}

int32_t host_compositor_on(void) { return 1; }

void host_damage_reference(double width, double height) {
  (void)width;
  (void)height;
}

/** No chunked compositor on this host: a damaged frame paints fully instead of patching. */
int32_t host_damage_can_merge(const uint8_t *serials, size_t n, const uint8_t *rects, size_t m) {
  (void)serials; (void)n; (void)rects; (void)m;
  return 0;
}

int32_t host_verify_damage(const uint8_t *rects, size_t n, double width, double height) {
  (void)rects;
  (void)n;
  (void)width;
  (void)height;
  return 0;
}


// ---------------------------------------------------------------------------
// The window's compositor
//
// The window draws its frame from the chunks the paint's commands make up, the way macOS's
// Metal path does. A chunk is a run of drawing commands with the transform and clips it sat in;
// the chunk walker (compositor/chunks.c) cuts the list, and each chunk is rastered once through
// the same Direct2D paint code the replay uses, into a BGRA texture on the hardware device.
// The textures stay: a frame that changed nothing (or moved a transform by whole device pixels)
// draws the textures it already has, and only a chunk whose commands changed is rastered again.
// A chunk whose transform changes from frame to frame — an animated translate, scale or rotate —
// is drawn from the texture it already has through the new transform, sampled, and is rastered
// again where it stands once it comes to rest. The quads composite on the D3D11 backend and
// present on the flip-model swap chain.
//
// The walk is the grouped one (comp_walk_grouped): what it can't split into chunks — a filter, a
// mask, a projection, a rotated or shaped clip — is one chunk rastered with its state in it, and
// an opacity group over several chunks is one chunk faded at draw. A frame the walk can't express
// at all (pushes and pops that don't balance) is left to the flat replay above.
//
// It is on by default; NATIVE_COMPOSITOR=0 leaves the window to the flat replay.
// NATIVE_COMPOSITOR_STATS=1 prints what each frame kept, rastered and resampled, and =2 every
// chunk it rastered.

/** How many bytes of chunk textures the cache may hold; past it a chunk is drawn for one frame. */
#define COMP_TEX_BUDGET (96u * 1024u * 1024u)

typedef struct {
  // What the texture is a picture of: the chunk's commands, the linear part of its transform, the
  // clip the quad applies, and the raster's size (see chunk_key). The translation is not part of
  // it: a chunk moved by whole device pixels draws the same texture at its new place.
  uint64_t key;
  int tex;
  int w, h, ox, oy; // the texture's device size and where its top left sat
  int baked;        // the clips are in the raster (rounded or fractional), so it may not move
  int transient;    // drawn this frame only: the budget was full, so it is dropped after present
  CompRect clip;    // the device-space clip the quad is cut to, when the raster holds none
  int has_clip;
  float alpha;
  // What the texture is a picture of whatever transform draws it: the chunk's commands and its
  // plain clip, without the transform (see chunk_motion_key); 0 for a chunk only its own
  // transform may draw (a clip in its raster, a region the frame's edge cut).
  uint64_t mkey;
  CompMatrix rm;    // the chunk's transform when it was rastered, and the region's top left then
  int rx, ry;
  CompMatrix lm;    // the transform the last frame drew the chunk at
  int resampled;    // this frame draws the texture through `draw`, sampled, not at whole pixels
  CompMatrix draw;
} CompChunkTex;

static CompBackend *g_comp = NULL;
static int g_comp_state = -1; // -1 not asked yet, 0 the replay draws the window, 1 the compositor
static int g_comp_stats = -1;
static ID2D1DeviceContext *g_comp_dc = NULL; // the context chunks raster through, of their own
static CompChunkTex g_comp_cur[COMP_MAX_LAYERS];
static CompChunkTex g_comp_prev[COMP_MAX_LAYERS];
static unsigned char g_comp_prev_used[COMP_MAX_LAYERS];
static int g_comp_count = 0;
static size_t g_comp_bytes = 0;
static CompWalk g_comp_walk;
#define COMP_KEY_SLOTS 8192 // a power of two above COMP_MAX_LAYERS
static int g_comp_slot[COMP_KEY_SLOTS];
static int g_comp_mslot[COMP_KEY_SLOTS];
// A composited snapshot is the frame's exact pixels: no chunk is drawn from a picture another
// transform rastered.
static int g_comp_exact = 0;
// How many chunks the last window frame drew resampled; the window composites once more when it
// has been still a moment, so a page at rest shows every chunk rastered where it stands.
static int g_comp_resampled = 0;
#define COMP_SETTLE_MS 250

/** Whether the compositor prints each step it takes, for a crash or a frame that comes out empty. */
static int comp_debug(void) {
  static int on = -1;
  if (on < 0) {
    const char *env = getenv("NATIVE_D3D11_DEBUG");
    on = env != NULL && env[0] != 0;
  }
  return on;
}

#define COMP_LOG(...) do { if (comp_debug()) { fprintf(stderr, __VA_ARGS__); fflush(stderr); } } while (0)

/** Whether the window composites its frames: on unless `NATIVE_COMPOSITOR=0`, which keeps the
 *  flat replay (the opt-out, for a driver the compositor misdraws on). */
static int compositor_enabled(void) {
  const char *env = getenv("NATIVE_COMPOSITOR");
  return !(env != NULL && strcmp(env, "0") == 0);
}

/** Reads NATIVE_COMPOSITOR_STATS once. */
static void comp_stats_init(void) {
  if (g_comp_stats >= 0) return;
  const char *s = getenv("NATIVE_COMPOSITOR_STATS");
  // 2 also prints every chunk the frame rastered, with what it held and how long it took.
  g_comp_stats = s != NULL && s[0] != 0 && strcmp(s, "0") != 0 ? (strcmp(s, "2") == 0 ? 2 : 1) : 0;
}

/** The box a polygon's points cover, as "x,y x,y" pairs with subpaths split by ';'. */
static int comp_poly_box(const char *s, double *x, double *y, double *w, double *h) {
  double minx = 0, miny = 0, maxx = 0, maxy = 0;
  int any = 0;
  const char *q = s;
  while (q != NULL && *q != 0) {
    char *end = NULL;
    double px = strtod(q, &end);
    if (end == q) { q++; continue; }
    q = end;
    while (*q == ' ' || *q == ',') q++;
    double py = strtod(q, &end);
    if (end == q) break;
    q = end;
    if (!any) {
      minx = maxx = px;
      miny = maxy = py;
      any = 1;
    } else {
      if (px < minx) minx = px;
      if (px > maxx) maxx = px;
      if (py < miny) miny = py;
      if (py > maxy) maxy = py;
    }
  }
  if (!any) return 0;
  *x = minx;
  *y = miny;
  *w = maxx - minx;
  *h = maxy - miny;
  return 1;
}

static int comp_cmd_count(void *ctx, int list_id) {
  (void)ctx;
  return list_id < 0 ? (int)g_count : -1;
}

static int comp_cmd_view(void *ctx, int list_id, int index, CompCmdView *out) {
  (void)ctx;
  if (list_id >= 0 || index < 0 || (size_t)index >= g_count) return 0;
  Cmd *c = &g_cmds[index];
  memset(out, 0, sizeof(*out));
  switch (c->kind) {
    case CMD_TRANSFORM:
      out->kind = COMP_CMD_TRANSFORM;
      out->matrix.m[0] = (float)c->p0;
      out->matrix.m[1] = (float)c->p1;
      out->matrix.m[4] = (float)c->p2;
      out->matrix.m[5] = (float)c->p3;
      out->matrix.m[10] = 1.0f;
      out->matrix.m[12] = (float)c->r[0];
      out->matrix.m[13] = (float)c->r[1];
      out->matrix.m[15] = 1.0f;
      return 1;
    case CMD_CLIP:
      // The replay draws one with a radius as a rounded clip (one radius for every corner), so
      // the walk must not take it for a square one it can cut the quad to.
      out->kind = c->radius > 0 ? COMP_CMD_CLIP_ROUND : COMP_CMD_CLIP;
      out->x = c->x;
      out->y = c->y;
      out->w = c->w;
      out->h = c->h;
      out->radius = c->radius > 0 ? c->radius : 0;
      return 1;
    case CMD_CLIP_ROUND: {
      out->kind = COMP_CMD_CLIP_ROUND;
      out->x = c->x;
      out->y = c->y;
      out->w = c->w;
      out->h = c->h;
      double r = 0;
      for (int k = 0; k < 8; k++) if (c->r[k] > r) r = c->r[k];
      out->radius = r;
      return 1;
    }
    case CMD_CLIP_POLY:
    case CMD_CLIP_ELLIPSE:
    case CMD_CLIP_SHAPE:
      out->kind = COMP_CMD_CLIP_SHAPED;
      return 1;
    case CMD_EFFECT_PUSH: {
      EffectSpec spec;
      effect_spec_parse(&spec, c->text);
      if (c->alpha_override) spec.alpha = (float)c->alpha;
      out->kind = COMP_CMD_EFFECT;
      out->alpha = (float)spec.alpha;
      out->simple = spec.count == 0 && spec.bcount == 0 && spec.blend == 0;
      if (spec.count > 0) {
        // The region replay_effect filters: the border box grown by 10% on every side, plus the
        // antialiased edge, since a blur or a drop shadow paints past what the box's subtree draws.
        double pad = fmax(c->w, c->h) * 0.1 + 1 + 2;
        out->x = c->x - pad;
        out->y = c->y - pad;
        out->w = c->w + 2 * pad;
        out->h = c->h + 2 * pad;
        out->boxed = 1;
      }
      return 1;
    }
    case CMD_UNCLIP:
    case CMD_EFFECT_POP:
      out->kind = COMP_CMD_POP;
      return 1;
    case CMD_MASK_PUSH:
    case CMD_MASK_SPLIT:
    case CMD_MASK_POP:
      out->kind = COMP_CMD_MASK;
      out->op = c->kind == CMD_MASK_PUSH ? 0 : c->kind == CMD_MASK_SPLIT ? 1 : 2;
      return 1;
    case CMD_PERSPECTIVE_PUSH:
    case CMD_PERSPECTIVE_POP:
      out->kind = COMP_CMD_PERSPECTIVE;
      out->op = c->kind == CMD_PERSPECTIVE_PUSH ? 0 : 2;
      return 1;
    default: {
      out->kind = COMP_CMD_DRAW;
      // The box the command paints into, padded for the antialiased edge and, for a shadow, the
      // ground it covers, so a chunk rastered from its box never cuts its own drawing off.
      double pad = 2;
      if (c->kind == CMD_SHADOW || c->kind == CMD_SHADOW_INSET || c->kind == CMD_TEXT_SHADOW) {
        // As far as paint_shadow reaches: both offsets, the spread, and three deviations of the
        // blur (its deviation is half the radius, so that is one and a half radii; three radii
        // is what paint_shadow pads its own surface by).
        pad += fabs(c->dx) + fabs(c->dy) + 3 * fabs(c->blur) + fabs(c->line_width);
      }
      if (c->emphasis != 0) pad += 12;
      double x = c->x, y = c->y, w = c->w, h = c->h;
      if (c->kind == CMD_TEXT || c->kind == CMD_TEXT_SHADOW) {
        // A run records where its line starts, not the advance the host measured when it shaped
        // the text, so its box is worked out from the size: an em and the spacing for each
        // character, a line box and the font's own height. The estimate only has to be generous —
        // extra pixels cost a little raster, while a box short of the run would cut the glyphs out
        // of the chunk's raster.
        w = (double)c->len * (c->size + fabs(c->letter) + fabs(c->word));
        h = (c->line_height > c->size * 1.4 ? c->line_height : c->size * 1.4) + c->size * 0.5;
        pad += c->size * 0.25;
        out->empty = c->len == 0;
      } else if (c->kind == CMD_POLY) {
        out->empty = !comp_poly_box(c->text, &x, &y, &w, &h);
        if (out->empty) return 1;
      } else {
        out->empty = c->w <= 0 && c->h <= 0;
      }
      out->x = x - pad;
      out->y = y - pad;
      out->w = w + 2 * pad;
      out->h = h + 2 * pad;
      out->boxed = 1;
      return 1;
    }
  }
}

static const CompCmdSource WIN_CHUNK_SOURCE = {comp_cmd_count, comp_cmd_view};

static inline uint64_t comp_mix(uint64_t h, uint64_t v) {
  h ^= v * 0x9e3779b97f4a7c15ull;
  h = (h << 31) | (h >> 33);
  return h * 0xbf58476d1ce4e5b9ull;
}

static inline uint64_t comp_hash_double(uint64_t h, double d) {
  uint64_t v;
  memcpy(&v, &d, sizeof(v));
  return comp_mix(h, v);
}

static uint64_t comp_hash_cmd(uint64_t h, const Cmd *c) {
  // `handle` is the command's index within the frame, so it changes with every command before
  // it, and says nothing about the pixels.
  h = comp_mix(h, (uint64_t)(uint32_t)c->kind | ((uint64_t)(uint32_t)c->image << 32));
  const double d[] = {c->x, c->y, c->w, c->h, c->radius, c->line_width, c->line_height, c->size,
                      c->weight, c->sx, c->sy, c->sw, c->sh, c->p0, c->p1, c->p2, c->p3, c->dx,
                      c->dy, c->blur, c->letter, c->word, c->alpha};
  for (size_t i = 0; i < sizeof(d) / sizeof(d[0]); i++) h = comp_hash_double(h, d[i]);
  for (int i = 0; i < 8; i++) h = comp_hash_double(h, c->r[i]);
  for (int i = 0; i < 8; i++) h = comp_hash_double(h, c->q[i]);
  h = comp_mix(h, (uint64_t)c->color | ((uint64_t)c->shadow_color << 32));
  h = comp_mix(h, (uint64_t)c->emphasis | ((uint64_t)c->emphasis_color << 32));
  h = comp_mix(h, (uint64_t)(uint32_t)c->smooth | ((uint64_t)(uint32_t)c->alpha_override << 32));
  h = comp_mix(h, (uint64_t)c->len);
  if (c->text != NULL) {
    size_t i = 0;
    for (; i + 8 <= c->len; i += 8) {
      uint64_t v;
      memcpy(&v, c->text + i, 8);
      h = comp_mix(h, v);
    }
    uint64_t tail = 0;
    memcpy(&tail, c->text + i, c->len - i);
    h = comp_mix(h, tail);
  }
  return h;
}

/** How many times the page's own GL calls have changed a canvas's drawing buffer (see CanvasGl). */
static int32_t canvas_content_generation(int32_t id);

/**
 * The key of a chunk rastered at `region`, with the quad's plain clip `clip` applied at draw
 * (never NULL when `has_clip`). A canvas draws pixels its script changes without a new command,
 * so the key carries how often its GL buffer has been drawn into: until the page draws again the
 * picture is the one the last frame rastered.
 */
static uint64_t chunk_key(const CompWalkChunk *c, int plain, CompRect region, const CompRect *clip,
                          int has_clip) {
  if (c->count <= 0) return 0;
  if ((size_t)(c->first + c->count) > g_count) return 0;
  uint64_t h = 0x243f6a8885a308d3ull;
  h = comp_mix(h, (uint64_t)(c->full != 0));
  h = comp_mix(h, (uint64_t)(c->transforms));
  h = comp_mix(h, (uint64_t)(uint32_t)region.w | ((uint64_t)(uint32_t)region.h << 32));
  if (!plain) {
    // A chunk whose clips are in its raster may not move: the clip sits at fixed device pixels.
    h = comp_mix(h, (uint64_t)(uint32_t)region.x | ((uint64_t)(uint32_t)region.y << 32));
  } else {
    // Where the raster sits relative to the transform. It is the same wherever whole pixels move
    // the chunk to, and differs when the frame's edge clamped the region: a chunk taller than
    // the frame keeps its size while its transform moves, so its pixels must not be reused.
    h = comp_hash_double(h, (double)region.x - (double)c->m.m[12]);
    h = comp_hash_double(h, (double)region.y - (double)c->m.m[13]);
  }
  // The transform's linear part, and its translation's fraction: whole pixels are the raster's
  // place, a fraction is the subpixel phase the antialiasing was done at.
  const double lin[6] = {c->m.m[0], c->m.m[1], c->m.m[4], c->m.m[5],
                         c->m.m[12] - floor(c->m.m[12]), c->m.m[13] - floor(c->m.m[13])};
  for (int i = 0; i < 6; i++) h = comp_hash_double(h, lin[i]);
  if (!plain) {
    h = comp_mix(h, (uint64_t)c->clip_count);
    for (int k = 0; k < c->clip_count; k++) {
      h = comp_hash_double(h, c->clips[k].x);
      h = comp_hash_double(h, c->clips[k].y);
      h = comp_hash_double(h, c->clips[k].w);
      h = comp_hash_double(h, c->clips[k].h);
      h = comp_hash_double(h, c->clips[k].r);
    }
  } else if (has_clip) {
    h = comp_hash_double(h, clip->x);
    h = comp_hash_double(h, clip->y);
    h = comp_hash_double(h, clip->w);
    h = comp_hash_double(h, clip->h);
  }
  for (int i = 0; i < c->count; i++) {
    const Cmd *cmd = &g_cmds[c->first + i];
    if (cmd->kind == CMD_CANVAS) {
      // The canvas's pixels are what its script drew into the buffer last, which no command in
      // the list records: the host's count of those draws stands in for them. A 2D canvas draws
      // through its own context, with no GL calls to count, so it stays keyless and is rastered
      // every frame as before.
      int32_t generation = canvas_content_generation(cmd->image);
      if (generation < 0) return 0;
      h = comp_mix(h, (uint64_t)(uint32_t)generation);
      continue;
    }
    h = comp_hash_cmd(h, cmd);
  }
  return h == 0 ? 1 : h;
}

/**
 * The key of a chunk's picture wherever its transform puts it: its commands and the device clip
 * its quad is cut to, and not the transform. A texture with this key can be drawn through another
 * frame's transform, sampled, which is what a moving element is: the same commands under a
 * transform that changes every frame. 0 for a chunk that can't move that way — a clip baked into
 * its raster, a raster of the whole frame, a canvas.
 */
static int comp_matrix_inverse(const CompMatrix *a, CompMatrix *out);

static uint64_t chunk_motion_key(const CompWalkChunk *c, int plain, CompRect region, const CompRect *clip,
                                 int has_clip, int pw, int ph) {
  if (c->full || c->count <= 0) return 0;
  if ((size_t)(c->first + c->count) > g_count) return 0;
  uint64_t h = 0x13198a2e03707344ull;
  h = comp_mix(h, (uint64_t)(has_clip != 0));
  if (plain && has_clip) {
    h = comp_mix(h, (uint64_t)(uint32_t)clip->x | ((uint64_t)(uint32_t)clip->y << 32));
    h = comp_mix(h, (uint64_t)(uint32_t)clip->w | ((uint64_t)(uint32_t)clip->h << 32));
  } else if (!plain) {
    // The clips are in the raster. One pushed under the chunk's own transform moves with what it
    // clips, so it is part of the picture: it goes into the key in that transform's space. One
    // from further out stays where it is while the chunk moves, so the picture holds only while
    // it cuts nothing: a square clip the chunk sits wholly inside.
    CompMatrix inv;
    if (!comp_matrix_inverse(&c->m, &inv)) return 0;
    for (int k = 0; k < c->clip_count; k++) {
      const CompWalkClip *cl = &c->clips[k];
      if (cl->transforms == c->transforms) {
        double x0 = cl->x, y0 = cl->y, x1 = cl->x + cl->w, y1 = cl->y + cl->h;
        double lx0 = inv.m[0] * x0 + inv.m[4] * y0 + inv.m[12], ly0 = inv.m[1] * x0 + inv.m[5] * y0 + inv.m[13];
        double lx1 = inv.m[0] * x1 + inv.m[4] * y1 + inv.m[12], ly1 = inv.m[1] * x1 + inv.m[5] * y1 + inv.m[13];
        // To a 64th of a pixel: the round trip through the transform leaves float noise.
        const double q[5] = {lx0, ly0, lx1, ly1, cl->r};
        for (int e = 0; e < 5; e++) h = comp_mix(h, (uint64_t)(int64_t)llround(q[e] * 64.0));
      } else {
        if (cl->r > 0) return 0;
        // One around the whole frame is left out of the raster (see clip_covers_view).
        if (cl->x <= 0 && cl->y <= 0 && cl->x + cl->w >= pw && cl->y + cl->h >= ph) continue;
        if ((double)region.x + 1 < cl->x || (double)region.y + 1 < cl->y ||
            (double)(region.x + region.w - 1) > cl->x + cl->w ||
            (double)(region.y + region.h - 1) > cl->y + cl->h)
          return 0;
      }
    }
  }
  for (int i = 0; i < c->count; i++) {
    const Cmd *cmd = &g_cmds[c->first + i];
    if (cmd->kind == CMD_CANVAS || cmd->kind == CMD_VIDEO) return 0;
    h = comp_hash_cmd(h, cmd);
  }
  return h == 0 ? 1 : h;
}

static int comp_matrix_same(const CompMatrix *a, const CompMatrix *b) {
  return a->m[0] == b->m[0] && a->m[1] == b->m[1] && a->m[4] == b->m[4] && a->m[5] == b->m[5] &&
         a->m[12] == b->m[12] && a->m[13] == b->m[13];
}

/** The 2D affine inverse of a chunk transform; 0 when it has none. */
static int comp_matrix_inverse(const CompMatrix *a, CompMatrix *out) {
  double m0 = a->m[0], m1 = a->m[1], m4 = a->m[4], m5 = a->m[5], tx = a->m[12], ty = a->m[13];
  double det = m0 * m5 - m4 * m1;
  if (!(fabs(det) > 1e-9)) return 0;
  CompMatrix r = comp_matrix_scale(1.0f, 1.0f);
  r.m[0] = (float)(m5 / det);
  r.m[1] = (float)(-m1 / det);
  r.m[4] = (float)(-m4 / det);
  r.m[5] = (float)(m0 / det);
  r.m[12] = (float)(-(r.m[0] * tx + r.m[4] * ty));
  r.m[13] = (float)(-(r.m[1] * tx + r.m[5] * ty));
  *out = r;
  return 1;
}

/**
 * The matrix that draws a texture rastered under `rm` at device (rx, ry) where the chunk's
 * transform `m` puts it now: device pixel <- m . rm^-1 . the texture's own offset. Answers 0
 * when the texture would be drawn at more than twice or under a quarter of the scale it was
 * rastered at, which a fresh raster draws better.
 */
static int comp_resample_matrix(const CompMatrix *m, const CompMatrix *rm, int rx, int ry, CompMatrix *out) {
  CompMatrix inv;
  if (!comp_matrix_inverse(rm, &inv)) return 0;
  CompMatrix d = comp_matrix_mul(*m, comp_matrix_mul(inv, comp_matrix_translate((float)rx, (float)ry)));
  double det = fabs((double)d.m[0] * d.m[5] - (double)d.m[4] * d.m[1]);
  if (!(det <= 4.0 && det >= 1.0 / 16.0)) return 0;
  *out = d;
  return 1;
}

/** The device-space clip a chunk sits inside, as the one rect every plain clip agrees on; answers
 *  0 for a rounded or fractional clip, which is baked into the raster instead. */
static int chunk_plain_clip(const CompWalkChunk *c, double scale, CompRect *out) {
  int have = 0;
  for (int k = 0; k < c->clip_count; k++) {
    const CompWalkClip *cl = &c->clips[k];
    if (cl->r > 0) return 0;
    if (cl->x != (double)(int)cl->x || cl->y != (double)(int)cl->y) return 0;
    if (cl->w != (double)(int)cl->w || cl->h != (double)(int)cl->h) return 0;
    if (c->transforms == 0 && scale > 0) {
      // With no transform pushed, the replay snaps the clip's CSS box to whole pixels before
      // Direct2D maps it to the target. The walker's rect came from the unsnapped box, so the
      // two agree only when the box already lands on whole CSS pixels.
      const double edges[4] = {cl->x, cl->y, cl->x + cl->w, cl->y + cl->h};
      for (int e = 0; e < 4; e++) {
        double css = edges[e] / scale;
        if (css != (double)(int)css) return 0;
      }
    }
    CompRect r = {(int)cl->x, (int)cl->y, (int)cl->w, (int)cl->h};
    if (!have) {
      *out = r;
      have = 1;
      continue;
    }
    int x0 = r.x > out->x ? r.x : out->x;
    int y0 = r.y > out->y ? r.y : out->y;
    int x1 = r.x + r.w < out->x + out->w ? r.x + r.w : out->x + out->w;
    int y1 = r.y + r.h < out->y + out->h ? r.y + r.h : out->y + out->h;
    out->x = x0;
    out->y = y0;
    out->w = x1 - x0 > 0 ? x1 - x0 : 0;
    out->h = y1 - y0 > 0 ? y1 - y0 : 0;
  }
  return 1;
}

/** The device-space region a chunk's raster covers: its commands' box through its transform, cut
 *  to the frame, so a layer pays for a surface the size of what it draws rather than the window's. */
/** Whether a chunk's commands all draw what their own boxes say wherever the chunk sits: no
 *  shadow or filter (their surfaces are cut to the view), no canvas or video. */
static int chunk_drawn_whole(const CompWalkChunk *c) {
  for (int i = 0; i < c->count; i++) {
    switch (g_cmds[c->first + i].kind) {
      case CMD_SHADOW: case CMD_SHADOW_INSET: case CMD_TEXT_SHADOW: case CMD_EFFECT_PUSH:
      case CMD_CANVAS: case CMD_VIDEO: case CMD_MASK_PUSH: case CMD_PERSPECTIVE_PUSH:
        return 0;
      default:
        break;
    }
  }
  return 1;
}

static CompRect chunk_region(const CompWalkChunk *c, int pw, int ph, int *cut = NULL) {
  if (cut != NULL) *cut = 1;
  if (c->full || c->bw <= 0 || c->bh <= 0) {
    CompRect all = {0, 0, pw, ph};
    return all;
  }
  double bx = c->bx, by = c->by, ex = c->bx + c->bw, ey = c->by + c->bh;
  const double px[4] = {bx, ex, ex, bx}, py[4] = {by, by, ey, ey};
  double minx = 0, miny = 0, maxx = 0, maxy = 0;
  for (int i = 0; i < 4; i++) {
    double x = c->m.m[0] * px[i] + c->m.m[4] * py[i] + c->m.m[12];
    double y = c->m.m[1] * px[i] + c->m.m[5] * py[i] + c->m.m[13];
    if (i == 0) {
      minx = maxx = x;
      miny = maxy = y;
    } else {
      if (x < minx) minx = x;
      if (x > maxx) maxx = x;
      if (y < miny) miny = y;
      if (y > maxy) maxy = y;
    }
  }
  int x0 = (int)floor(minx) - 1, y0 = (int)floor(miny) - 1;
  int x1 = (int)ceil(maxx) + 1, y1 = (int)ceil(maxy) + 1;
  if (cut != NULL) {
    *cut = x0 < 0 || y0 < 0 || x1 > pw || y1 > ph;
    // A chunk that hangs over the frame's edge is rastered whole when that is at most a frame and
    // a half of surface, so it can move without a raster: the texture already holds what moving
    // brings into view. One far bigger than that is cut, and so is one with a shadow or a filter,
    // whose surfaces the paint cuts to the view.
    double whole = ((double)x1 - x0) * ((double)y1 - y0);
    if (*cut && x1 > 0 && y1 > 0 && x0 < pw && y0 < ph && whole <= 1.5 * (double)pw * (double)ph &&
        x1 - x0 <= 8192 && y1 - y0 <= 8192 && chunk_drawn_whole(c)) {
      *cut = 0;
      CompRect r = {x0, y0, x1 - x0, y1 - y0};
      return r;
    }
  }
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x1 > pw) x1 = pw;
  if (y1 > ph) y1 = ph;
  if (x1 <= x0 || y1 <= y0) {
    CompRect empty = {0, 0, 0, 0};
    return empty;
  }
  CompRect r = {x0, y0, x1 - x0, y1 - y0};
  return r;
}

/** A Direct2D target over a chunk's texture, so the paint code can raster straight into it. */
static ID2D1Bitmap1 *comp_bitmap_for(int tex) {
  ID3D11Texture2D *t = (ID3D11Texture2D *)comp_d3d11_texture(g_comp, tex);
  if (t == NULL || g_d2d == NULL) return NULL;
  IDXGISurface *surface = NULL;
  if (FAILED(t->QueryInterface(__uuidof(IDXGISurface), (void **)&surface)) || surface == NULL) return NULL;
  D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
      (D2D1_BITMAP_OPTIONS)(D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW),
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
      (FLOAT)(96.0 * g_scale), (FLOAT)(96.0 * g_scale));
  ID2D1Bitmap1 *bitmap = NULL;
  HRESULT hr = g_d2d->CreateBitmapFromDxgiSurface(surface, &props, &bitmap);
  surface->Release();
  return SUCCEEDED(hr) ? bitmap : NULL;
}

/** Rasters one chunk's commands into `tex`, at the device `region` its box covers. */
static int comp_raster_chunk(const CompWalkChunk *c, CompRect region, int tex, int plain) {
  ID2D1Bitmap1 *bitmap = comp_bitmap_for(tex);
  if (bitmap == NULL) return 0;
  double s = g_scale > 0 ? g_scale : 1;
  g_comp_dc->SetTarget(bitmap);
  g_comp_dc->SetDpi((FLOAT)(96.0 * s), (FLOAT)(96.0 * s));
  g_comp_dc->SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
  g_comp_dc->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  g_comp_dc->SetTransform(D2D1::IdentityMatrix());
  g_comp_dc->BeginDraw();
  g_comp_dc->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.0f));
  // The raster's own pixels are the region, so the page is moved to its corner.
  g_comp_dc->SetTransform(
      D2D1::Matrix3x2F::Translation((FLOAT)(-(double)region.x / s), (FLOAT)(-(double)region.y / s)));
  ID2D1DeviceContext *page = g_d2d;
  g_d2d = g_comp_dc;
  Replay r;
  memset(&r, 0, sizeof(r));
  r.width = g_view_w;
  r.height = g_view_h;
  g_comp_origin_x = (double)region.x / s;
  g_comp_origin_y = (double)region.y / s;
  g_chunk_mode = 1;
  g_chunk_first = (size_t)c->first;
  g_chunk_last = (size_t)(c->first + c->count);
  g_chunk_clips = plain ? 0 : 1;
  replay_range(&r, 0);
  while (r.depth > 0) replay_state_restore(&r);
  g_chunk_mode = 0;
  g_comp_origin_x = g_comp_origin_y = 0;
  g_d2d = page;
  HRESULT hr = g_comp_dc->EndDraw();
  g_comp_dc->SetTarget(NULL);
  bitmap->Release();
  return SUCCEEDED(hr);
}

// Textures a chunk drew from for one frame only (a canvas, whose pixels no key pins down, or a
// chunk past the budget), kept for the next frame's: such a chunk is rastered again every frame,
// and a texture made and freed per frame costs the device an allocation each time.
#define COMP_SPARES 4
static struct { int tex, w, h; } g_comp_spare[COMP_SPARES];
static int g_comp_spares = 0;

static int comp_tex_take(int w, int h) {
  for (int k = 0; k < g_comp_spares; k++) {
    if (g_comp_spare[k].w == w && g_comp_spare[k].h == h) {
      int tex = g_comp_spare[k].tex;
      g_comp_spare[k] = g_comp_spare[--g_comp_spares];
      return tex;
    }
  }
  return g_comp->vt->tex_create(g_comp, w, h);
}

static void comp_tex_give(int tex, int w, int h) {
  if (tex < 0) return;
  if (g_comp_spares == COMP_SPARES) {
    g_comp->vt->tex_destroy(g_comp, g_comp_spare[0].tex);
    g_comp_spare[0] = g_comp_spare[--g_comp_spares];
  }
  g_comp_spare[g_comp_spares].tex = tex;
  g_comp_spare[g_comp_spares].w = w;
  g_comp_spare[g_comp_spares].h = h;
  g_comp_spares++;
}

/** Drops every retained chunk texture. */
static void comp_drop_all(void) {
  for (int k = 0; k < g_comp_spares; k++)
    if (g_comp != NULL) g_comp->vt->tex_destroy(g_comp, g_comp_spare[k].tex);
  g_comp_spares = 0;
  for (int i = 0; i < g_comp_count; i++) {
    CompChunkTex *e = &g_comp_cur[i];
    if (e->tex >= 0 && g_comp != NULL) g_comp->vt->tex_destroy(g_comp, e->tex);
    e->tex = -1;
    e->key = 0;
  }
  g_comp_count = 0;
  g_comp_bytes = 0;
}

/**
 * Composites the recorded frame into `target` (-1 for the window's swap chain), reusing the
 * chunk textures the last frame left. Answers 1 when the target was drawn and 0 when the walk
 * can't express the frame, which the replay then draws.
 */
static int composite_into(int target, double scale, int pw, int ph) {
  if (g_comp == NULL || g_d2d_device == NULL) return 0;
  if (g_comp_dc == NULL) {
    if (FAILED(g_d2d_device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &g_comp_dc)) ||
        g_comp_dc == NULL)
      return 0;
  }
  comp_stats_init();
  double composite_started = now_ms();
  if (!comp_walk_grouped(&WIN_CHUNK_SOURCE, NULL, scale, &g_comp_walk)) {
    if (g_comp_stats)
      fprintf(stderr, "native: composite flat=1 fail=%d@%d info=%d\n", comp_walk_failure(),
              comp_walk_failure_at(), comp_walk_failure_kind());
    return 0;
  }
  CompWalk *walk = &g_comp_walk;
  int n = walk->count;
  COMP_LOG("native: comp walk chunks=%d target=%d %dx%d scale=%g\n", n, target, pw, ph, scale);
  int prev_count = g_comp_count;
  memcpy(g_comp_prev, g_comp_cur, (size_t)prev_count * sizeof(CompChunkTex));
  memset(g_comp_prev_used, 0, (size_t)prev_count);
  for (int k = 0; k < COMP_KEY_SLOTS; k++) g_comp_slot[k] = g_comp_mslot[k] = -1;
  for (int j = 0; j < prev_count; j++) {
    if (g_comp_prev[j].tex < 0) continue;
    if (g_comp_prev[j].key != 0) {
      unsigned slot = (unsigned)(g_comp_prev[j].key & (COMP_KEY_SLOTS - 1));
      while (g_comp_slot[slot] >= 0) slot = (slot + 1) & (COMP_KEY_SLOTS - 1);
      g_comp_slot[slot] = j;
    }
    if (g_comp_prev[j].mkey != 0) {
      unsigned slot = (unsigned)(g_comp_prev[j].mkey & (COMP_KEY_SLOTS - 1));
      while (g_comp_mslot[slot] >= 0) slot = (slot + 1) & (COMP_KEY_SLOTS - 1);
      g_comp_mslot[slot] = j;
    }
  }
  g_comp_bytes = 0;
  int kept = 0, rastered = 0, keyless = 0, full_chunks = 0, resampled = 0;
  double raster_started = now_ms();
  for (int i = 0; i < n; i++) {
    const CompWalkChunk *c = &walk->chunks[i];
    CompChunkTex *e = &g_comp_cur[i];
    memset(e, 0, sizeof(*e));
    e->tex = -1;
    e->alpha = c->alpha;
    if (c->full) full_chunks++;
    if (c->count <= 0) continue; // nothing to draw, nothing to raster
    CompRect clip;
    memset(&clip, 0, sizeof(clip));
    int plain = chunk_plain_clip(c, scale, &clip);
    int cut = 1;
    CompRect region = chunk_region(c, pw, ph, &cut);
    int usable = region.w > 0 && region.h > 0;
    uint64_t key = usable ? chunk_key(c, plain, region, &clip, plain && c->clip_count > 0) : 0;
    uint64_t mkey = usable ? chunk_motion_key(c, plain, region, &clip, plain && c->clip_count > 0, pw, ph) : 0;
    if (key == 0) keyless++;
    int from = -1;
    int resample = 0;
    CompMatrix resample_m;
    if (key != 0) {
      if (i < prev_count && !g_comp_prev_used[i] && g_comp_prev[i].key == key && g_comp_prev[i].tex >= 0) {
        from = i; // the same picture anywhere in the last frame, the entry at this index first
      } else {
        unsigned slot = (unsigned)(key & (COMP_KEY_SLOTS - 1));
        while (g_comp_slot[slot] >= 0) {
          int j = g_comp_slot[slot];
          if (!g_comp_prev_used[j] && g_comp_prev[j].key == key && g_comp_prev[j].tex >= 0) {
            from = j;
            break;
          }
          slot = (slot + 1) & (COMP_KEY_SLOTS - 1);
        }
      }
    }
    if (from < 0 && mkey != 0 && !g_comp_exact) {
      // The same commands under another transform: a moving element. Its picture is drawn
      // through the new transform while it moves; once a frame finds it where the last one drew
      // it, it is at rest, and is rastered again where it stands.
      unsigned slot = (unsigned)(mkey & (COMP_KEY_SLOTS - 1));
      while (g_comp_mslot[slot] >= 0) {
        int j = g_comp_mslot[slot];
        const CompChunkTex *p = &g_comp_prev[j];
        if (!g_comp_prev_used[j] && p->mkey == mkey && p->tex >= 0) {
          if (!comp_matrix_same(&c->m, &p->lm) &&
              comp_resample_matrix(&c->m, &p->rm, p->rx, p->ry, &resample_m)) {
            from = j;
            resample = 1;
          }
          break;
        }
        slot = (slot + 1) & (COMP_KEY_SLOTS - 1);
      }
    }
    if (from >= 0) {
      *e = g_comp_prev[from];
      g_comp_prev_used[from] = 1;
      e->ox = region.x;
      e->oy = region.y;
      e->lm = c->m;
      e->resampled = resample;
      if (resample) {
        e->draw = resample_m;
        resampled++;
      }
      e->alpha = c->alpha;
      e->has_clip = plain && c->clip_count > 0;
      e->clip = clip;
      kept++;
      if (!e->transient) g_comp_bytes += (size_t)e->w * 4u * (size_t)e->h;
      continue;
    }
    if (!usable) continue;
    int tex = comp_tex_take(region.w, region.h);
    if (tex < 0) continue;
    COMP_LOG("native: comp raster %d tex=%d region=%d,%d %dx%d plain=%d\n", i, tex, region.x, region.y,
             region.w, region.h, plain);
    double chunk_started = g_comp_stats > 1 ? now_ms() : 0;
    int rastered_ok = comp_raster_chunk(c, region, tex, plain);
    if (g_comp_stats > 1) {
      char kinds[64];
      int at = 0;
      for (int k = 0; k < c->count && k < 12 && at < (int)sizeof(kinds) - 4; k++)
        at += snprintf(kinds + at, sizeof(kinds) - (size_t)at, k ? ",%d" : "%d", g_cmds[c->first + k].kind);
      kinds[at] = 0;
      fprintf(stderr, "native: composite raster chunk=%d cmds=%d+%d kinds=%s region=%d,%d %dx%d cut=%d motion=%d plain=%d full=%d clips=%d",
              i, c->first, c->count, kinds, region.x, region.y, region.w, region.h, cut, mkey != 0, plain,
              c->full, c->clip_count);
      for (int k = 0; k < c->clip_count; k++)
        fprintf(stderr, " [%g,%g %gx%g r%g]", c->clips[k].x, c->clips[k].y, c->clips[k].w, c->clips[k].h, c->clips[k].r);
      fprintf(stderr, " ms=%.2f\n", now_ms() - chunk_started);
    }
    if (!rastered_ok) {
      // A chunk the device can't raster (a target format it refuses, a fragment of memory it has
      // not) leaves the whole frame to the replay: half a frame is worse than its full cost.
      g_comp->vt->tex_destroy(g_comp, tex);
      for (int j = 0; j < i; j++) {
        if (g_comp_cur[j].transient && g_comp_cur[j].tex >= 0) {
          comp_tex_give(g_comp_cur[j].tex, g_comp_cur[j].w, g_comp_cur[j].h);
          g_comp_cur[j].tex = -1;
        }
      }
      return 0;
    }
    e->key = key;
    // Only a raster that holds the whole chunk may be drawn elsewhere: one the frame's edge cut
    // is missing what another transform would bring into view.
    e->mkey = cut ? 0 : mkey;
    e->rm = c->m;
    e->lm = c->m;
    e->rx = region.x;
    e->ry = region.y;
    e->resampled = 0;
    e->tex = tex;
    e->w = region.w;
    e->h = region.h;
    e->ox = region.x;
    e->oy = region.y;
    e->baked = !plain;
    e->has_clip = plain && c->clip_count > 0;
    e->clip = clip;
    e->alpha = c->alpha;
    size_t bytes = (size_t)region.w * 4u * (size_t)region.h;
    e->transient = key == 0 || g_comp_bytes + bytes > COMP_TEX_BUDGET;
    if (!e->transient) g_comp_bytes += bytes;
    rastered++;
    COMP_LOG("native: comp raster %d done tex=%d\n", i, tex);
  }
  double raster_ms = now_ms() - raster_started;
  // The last frame's pictures that no chunk of this one is: their textures go back to the spare
  // pool, so a chunk whose picture changes every frame (a canvas its page draws into every frame)
  // reuses a texture rather than making one each time.
  for (int j = 0; j < prev_count; j++) {
    if (!g_comp_prev_used[j] && g_comp_prev[j].tex >= 0)
      comp_tex_give(g_comp_prev[j].tex, g_comp_prev[j].w, g_comp_prev[j].h);
  }
  g_comp_count = n;
  COMP_LOG("native: comp pass begin target=%d\n", target);
  double draw_started = now_ms();
  g_comp->vt->pass_begin(g_comp, target, pw, ph, g_background);
  if (!comp_d3d11_has_target(g_comp)) {
    // The drawable or the texture could not be targeted this frame: the replay draws it.
    for (int i = 0; i < n; i++) {
      CompChunkTex *e = &g_comp_cur[i];
      if (e->transient && e->tex >= 0) {
        comp_tex_give(e->tex, e->w, e->h);
        e->tex = -1;
        e->key = 0;
      }
    }
    return 0;
  }
  for (int i = 0; i < n; i++) {
    CompChunkTex *e = &g_comp_cur[i];
    if (e->tex < 0 || e->alpha <= 0.0f) continue;
    CompRect src = {0, 0, e->w, e->h};
    CompMatrix m = e->resampled ? e->draw : comp_matrix_translate((float)e->ox, (float)e->oy);
    const CompRect *clip = e->has_clip ? &e->clip : NULL;
    g_comp->vt->draw_quad(g_comp, e->tex, src, &m, e->alpha, clip, 0.0f);
  }
  COMP_LOG("native: comp draws done, present\n");
  double present_started = now_ms();
  double draw_ms = present_started - draw_started;
  g_comp->vt->present(g_comp);
  double present_ms = now_ms() - present_started;
  COMP_LOG("native: comp presented\n");
  if (target < 0) {
    g_comp_resampled = resampled;
    // A frame that drew moving chunks from pictures rastered elsewhere is composited again once
    // the page has been still a moment: then they are where the last frame drew them, at rest,
    // and are rastered where they stand. A new frame before that moves the timer on.
    if (g_hwnd) {
      if (resampled > 0) SetTimer(g_hwnd, COMP_SETTLE_TIMER, COMP_SETTLE_MS, NULL);
      else KillTimer(g_hwnd, COMP_SETTLE_TIMER);
    }
  }
  // A chunk drawn for its frame only gives its texture back now that the frame is on the queue.
  for (int i = 0; i < n; i++) {
    CompChunkTex *e = &g_comp_cur[i];
    if (e->transient && e->tex >= 0) {
      comp_tex_give(e->tex, e->w, e->h);
      e->tex = -1;
      e->key = 0;
    }
  }
  if (g_comp_stats) {
    fprintf(stderr,
            "native: composite chunks=%d tiles=%d kept=%d rastered=%d keyless=%d rasterms=%g "
            "flat=0 fail=0@-1 info=-1 full=%d resampled=%d walkms=%.2f drawms=%.2f presentms=%.2f ms=%g\n",
            n, kept + rastered, kept, rastered, keyless, raster_ms, full_chunks, resampled,
            raster_started - composite_started, draw_ms, present_ms, now_ms() - composite_started);
  }
  return 1;
}

/** The window's compositor, made on first use; answers 1 when it took the frame. */
static int window_composite(void) {
  if (g_comp_state < 0) g_comp_state = compositor_enabled() ? 1 : 0;
  if (g_comp_state == 0) return 0;
  if (!g_hwnd || !ensure_window_target()) {
    g_comp_state = 0;
    return 0;
  }
  comp_stats_init();
  if (g_comp == NULL) {
    g_comp = comp_d3d11_backend(g_d3d);
    if (g_comp == NULL) {
      g_comp_state = 0;
      return 0;
    }
    if (frame_times()) fprintf(stderr, "native: compositor on the d3d11 device\n");
  }
  if (comp_d3d11_device_lost(g_comp)) {
    comp_drop_all();
    g_comp->vt->destroy(g_comp);
    g_comp = NULL;
    g_comp_state = 0;
    return 0;
  }
  comp_d3d11_set_swap_chain(g_comp, g_swap);
  RECT rc;
  if (!GetClientRect(g_hwnd, &rc)) return 0;
  int pw = rc.right - rc.left, ph = rc.bottom - rc.top;
  if (pw <= 0 || ph <= 0) return 0;
  return composite_into(-1, g_scale, pw, ph);
}

/** The display's refresh period in milliseconds, from the primary monitor's current mode. A
 *  frequency of 0 or 1 is the driver saying "hardware default", which is sixty. */
double host_refresh_interval(void) {
  DEVMODEW mode;
  ZeroMemory(&mode, sizeof(mode));
  mode.dmSize = sizeof(mode);
  if (EnumDisplaySettingsW(nullptr, ENUM_CURRENT_SETTINGS, &mode) && mode.dmDisplayFrequency > 1) {
    return 1000.0 / (double)mode.dmDisplayFrequency;
  }
  return 1000.0 / 60.0;
}

/** How long until the display's next refresh in milliseconds: this host has no composition clock
 *  to read, so the loop paces itself by the period alone. */
double host_until_refresh(void) { return 0; }


#ifndef CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
#define CREATE_WAITABLE_TIMER_HIGH_RESOLUTION 0x00000002
#endif

/** The timer a poll waits on for its deadline. A wait's own timeout is counted in ticks of the
 *  system timer, 15.6 ms unless some process raised the resolution, so a 5 ms wait for the next
 *  frame slept 15.6 and the loop's frames landed 15.6 or 31.2 ms apart instead of one display
 *  period. A high-resolution waitable timer (Windows 10 1803 and later) keeps the deadline to the
 *  millisecond without raising the resolution for the whole system; NULL where there is none. */
static HANDLE poll_timer(void) {
  static HANDLE timer = NULL;
  static bool tried = false;
  if (!tried) {
    tried = true;
    timer = CreateWaitableTimerExW(NULL, NULL, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
  }
  return timer;
}

/** Waits up to `ms` for a message to arrive for the window. */
static void wait_for_message(double ms) {
  HANDLE timer = ms >= 1 ? poll_timer() : NULL;
  LARGE_INTEGER due;
  due.QuadPart = -(LONGLONG)(ms * 10000.0);  // relative, in 100 ns units
  if (timer != NULL && SetWaitableTimer(timer, &due, 0, NULL, NULL, FALSE)) {
    // The timeout is only a backstop: the timer ends the wait on time.
    MsgWaitForMultipleObjectsEx(1, &timer, (DWORD)ms + 5, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    CancelWaitableTimer(timer);
    return;
  }
  MsgWaitForMultipleObjectsEx(0, NULL, (DWORD)ms, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
}

/** Drains the window's messages into the event queue, waiting up to `timeout` seconds for one. */
int32_t host_poll(double timeout) {
  // A client's accessibility action goes to the runtime first, one per poll, in the order it came.
  if (ax_take_action()) return EV_AXACTION;
  int32_t queued = take_event();
  if (queued != EV_NONE) return queued;
  if (g_hwnd) {
    double ms = timeout > 0 ? timeout * 1000.0 : 0;
    if (ms > 50) ms = 50;
    wait_for_message(ms);
    MSG msg;
    while (PeekMessageW(&msg, g_hwnd, 0, 0, PM_REMOVE)) {
      TranslateMessage(&msg);
      DispatchMessageW(&msg);
      int32_t ev = take_event();
      if (ev != EV_NONE) return ev;
    }
  }
  return take_event();
}

double host_view_width(void) { return g_view_w; }
double host_view_height(void) { return g_view_h; }
double host_event_x(void) { return g_event.x; }
double host_event_y(void) { return g_event.y; }
double host_event_dx(void) { return g_event.dx; }
double host_event_dy(void) { return g_event.dy; }
int32_t host_event_phase(void) { return 0; }
int32_t host_event_clicks(void) { return g_event.clicks; }
int32_t host_event_key(void) { return g_event.key; }
int32_t host_event_mods(void) { return g_event.mods; }
int32_t host_event_repeat(void) { return g_event.repeat; }

void host_event_text(str_cb receive) {
  receive((const uint8_t *)g_event.text, strlen(g_event.text));
}

void host_target_text(str_cb receive) { receive((const uint8_t *)"", 0); }

/** The phase of the input method's composition that the EV_COMPOSE being handled reports. */
int32_t host_composition_phase(void) { return g_compose_phase; }

/** The text that phase carries: the marked text while composing, the committed one at the end. */
void host_composition_text(str_cb receive) { receive((const uint8_t *)g_compose_text, g_compose_len); }

/** Where the caret of the focused field is, in the page's CSS pixels. */
void host_composition_rect(double x, double y, double w, double h) {
  g_caret_x = x;
  g_caret_y = y;
  g_caret_w = w > 0 ? w : 1;
  g_caret_h = h > 0 ? h : 16;
  if (g_ime_composing && g_hwnd) ime_place(g_hwnd);
}

void host_set_title(const uint8_t *title, size_t title_len) {
  if (title_len >= sizeof(g_title)) title_len = sizeof(g_title) - 1;
  memcpy(g_title, title, title_len);
  g_title[title_len] = '\0';
  if (g_hwnd) {
    size_t wide_len = 0;
    wchar_t *wide = utf8_to_utf16((const uint8_t *)g_title, strlen(g_title), &wide_len);
    if (wide) {
      SetWindowTextW(g_hwnd, wide);
      free(wide);
    }
  }
}

/** A host preference pinned by environment for tests, as on the other hosts. */
static int32_t env_toggle(const char *name) {
  const char *env = getenv(name);
  return env && *env ? (strcmp(env, "0") != 0 ? 1 : 0) : 0;
}

int32_t host_color_scheme(void) {
  const char *env = getenv("NATIVE_COLOR_SCHEME");
  if (env && *env) return strcmp(env, "dark") == 0 ? 1 : 0;
  // Apps use the mode the system is in: AppsUseLightTheme is 0 in dark mode.
  DWORD value = 1, size = sizeof(value);
  HKEY key;
  if (RegOpenKeyExW(HKEY_CURRENT_USER,
                    L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize", 0,
                    KEY_QUERY_VALUE, &key) == ERROR_SUCCESS) {
    RegQueryValueExW(key, L"AppsUseLightTheme", NULL, NULL, (LPBYTE)&value, &size);
    RegCloseKey(key);
  }
  return value == 0 ? 1 : 0;
}

int32_t host_increase_contrast(void) { return env_toggle("NATIVE_INCREASE_CONTRAST"); }
int32_t host_reduce_transparency(void) { return env_toggle("NATIVE_REDUCE_TRANSPARENCY"); }
int32_t host_reduced_motion(void) { return env_toggle("NATIVE_REDUCED_MOTION"); }

int32_t host_media_type(void) {
  const char *env = getenv("NATIVE_MEDIA");
  return env != NULL && strcmp(env, "print") == 0 ? 1 : 0;
}

uint32_t host_selection_color(void) { return 0xb4d5feff; }
uint32_t host_focus_ring_color(void) { return 0x0064e1ffu; }

/** The frame's caption is the window's own, so nothing of it is inside the page's view. */
double host_titlebar_area(int32_t which) {
  (void)which;
  return 0;
}

void host_window_drag(void) {
  if (!g_hwnd) return;
  ReleaseCapture();
  SendMessageW(g_hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
}

/** This window's id and the frame it reports, in screen coordinates. */
int32_t host_window_id(void) { return g_win_id; }

void host_window_set_frame(double x, double y, double w, double h) {
  int first = g_win_w == 0 && g_win_h == 0;
  double old_w = g_view_w, old_h = g_view_h;
  if (x >= 0) g_win_x = x;
  if (y >= 0) g_win_y = y;
  if (w >= 0) g_win_w = w;
  if (h >= 0) g_win_h = h;
  if (g_hwnd && !first) {
    RECT want = {0, 0, (LONG)ceil(g_win_w * g_scale), (LONG)ceil(g_win_h * g_scale)};
    AdjustWindowRectEx(&want, WS_OVERLAPPEDWINDOW, g_menu_bar != NULL, 0);
    SetWindowPos(g_hwnd, NULL, (int)g_win_x, (int)g_win_y, want.right - want.left,
                 want.bottom - want.top, SWP_NOZORDER | SWP_NOACTIVATE);
    update_view_size();
  }
  if (!g_hwnd) {
    // A run with no window lays the page out at the size it asked for.
    g_view_w = g_win_w;
    g_view_h = g_win_h;
  }
  if (first) return;
  if (g_view_w != old_w || g_view_h != old_h) queue_kind(EV_RESIZE);
  queue_kind(EV_WINDOWMOVE);
}

double host_window_frame(int32_t which) {
  if (g_hwnd) {
    RECT rc;
    if (which == 2 || which == 3) {
      if (GetClientRect(g_hwnd, &rc))
        return (which == 2 ? (double)(rc.right - rc.left) : (double)(rc.bottom - rc.top)) / g_scale;
    }
  }
  return which == 0 ? g_win_x : which == 1 ? g_win_y : which == 2 ? g_win_w : g_win_h;
}

void host_window_fullscreen(int32_t on) {
  if ((on != 0) == (g_fullscreen != 0)) return;
  g_fullscreen = on != 0;
  if (g_hwnd) {
    if (g_fullscreen) {
      MONITORINFO info = {0};
      info.cbSize = sizeof(info);
      HMONITOR monitor = MonitorFromWindow(g_hwnd, MONITOR_DEFAULTTONEAREST);
      if (GetMonitorInfoW(monitor, &info))
        SetWindowLongW(g_hwnd, GWL_STYLE, WS_POPUP | WS_VISIBLE);
      if (GetMonitorInfoW(monitor, &info))
        SetWindowPos(g_hwnd, HWND_TOP, info.rcMonitor.left, info.rcMonitor.top,
                     info.rcMonitor.right - info.rcMonitor.left,
                     info.rcMonitor.bottom - info.rcMonitor.top, SWP_FRAMECHANGED);
    } else {
      SetWindowLongW(g_hwnd, GWL_STYLE, WS_OVERLAPPEDWINDOW | WS_VISIBLE);
      SetWindowPos(g_hwnd, NULL, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
    }
    release_target();
    if (g_swap) {
      g_swap->Release();
      g_swap = NULL;
    }
    ensure_window_target();
    update_view_size();
  }
  queue_kind(EV_FULLSCREEN);
}

int32_t host_window_fullscreen_state(void) { return g_fullscreen; }
int32_t host_window_hidden(void) { return g_hidden; }

void host_window_set_hidden(int32_t hidden) {
  if ((hidden != 0) == (g_hidden != 0)) return;
  g_hidden = hidden != 0;
  if (g_hwnd) ShowWindow(g_hwnd, g_hidden ? SW_HIDE : SW_SHOW);
  queue_kind(EV_VISIBILITY);
}

void host_window_minimize(void) {
  if (g_hwnd) ShowWindow(g_hwnd, SW_MINIMIZE);
  queue_kind(EV_VISIBILITY);
}

void host_window_zoom(void) {
  if (!g_hwnd) return;
  ShowWindow(g_hwnd, IsZoomed(g_hwnd) ? SW_RESTORE : SW_MAXIMIZE);
}

void host_title(window_text_cb cb) { cb((const uint8_t *)g_title, strlen(g_title)); }

/** A window this one opened is recorded rather than started: what reports it is its handle. */
typedef struct {
  int32_t id;
  char name[128];
  int open;
} OpenedWindow;
static OpenedWindow g_opened[32];
static int g_opened_count = 0;
static int32_t g_next_window = 2;
static int32_t g_closed_window = 0;

int32_t host_window_open(const uint8_t *url, size_t n, const uint8_t *name, size_t name_len,
                         const uint8_t *features, size_t features_len) {
  (void)url;
  (void)n;
  (void)features;
  (void)features_len;
  char wanted[128];
  if (!copy_name_bytes(wanted, sizeof(wanted), name, name_len)) wanted[0] = '\0';
  if (wanted[0] != '\0') {
    for (int i = 0; i < g_opened_count; i++) {
      if (g_opened[i].open && strcmp(g_opened[i].name, wanted) == 0) return g_opened[i].id;
    }
  }
  int32_t id = g_next_window++;
  if (g_opened_count < (int)(sizeof(g_opened) / sizeof(g_opened[0]))) {
    g_opened[g_opened_count].id = id;
    snprintf(g_opened[g_opened_count].name, sizeof(g_opened[0].name), "%s", wanted);
    g_opened[g_opened_count].open = 1;
    g_opened_count++;
  }
  return id;
}

void host_window_close(int32_t id) {
  if (id <= 0) {
    queue_kind(EV_QUIT);
    if (g_hwnd) PostMessageW(g_hwnd, WM_CLOSE, 0, 0);
    return;
  }
  for (int i = 0; i < g_opened_count; i++) {
    if (g_opened[i].id == id && g_opened[i].open) {
      g_opened[i].open = 0;
      g_closed_window = id;
      queue_kind(EV_WINDOWCLOSED);
      return;
    }
  }
}

void host_window_focus(int32_t id) {
  (void)id;
  if (g_hwnd) SetForegroundWindow(g_hwnd);
}

void host_window_blur(void) {
  if (g_hwnd) PostMessageW(g_hwnd, WM_KILLFOCUS, 0, 0);
}

int32_t host_window_closed(void) { return g_closed_window; }

void host_post_message(int32_t target, const uint8_t *data, size_t n) {
  if (target != g_win_id) return;
  HostEvent ev = {0};
  ev.kind = EV_MESSAGE;
  ev.payload = (char *)malloc(n + 1);
  if (!ev.payload) return;
  memcpy(ev.payload, data, n);
  ev.payload[n] = '\0';
  queue_event(ev);
}

int32_t host_message_source(void) { return g_win_id; }
void host_message_data(window_text_cb cb) {
  const char *data = g_event.payload ? g_event.payload : "";
  cb((const uint8_t *)data, strlen(data));
}

void host_quit(void) {
  queue_kind(EV_QUIT);
  if (g_hwnd) PostMessageW(g_hwnd, WM_CLOSE, 0, 0);
}

void host_app_action(const uint8_t *action, size_t n) {
  char name[64];
  if (!copy_name_bytes(name, sizeof(name), action, n)) return;
  if (strcmp(name, "--minimize") == 0) host_window_minimize();
  else if (strcmp(name, "--zoom") == 0) host_window_zoom();
  else if (strcmp(name, "--close") == 0) host_window_close(0);
  else if (strcmp(name, "--toggle-fullscreen") == 0) host_window_fullscreen(!g_fullscreen);
  else if (strcmp(name, "--quit") == 0) host_quit();
}

}  // extern "C"

// ---------------------------------------------------------------------------
// Menus

static char *g_menu_last = NULL;

static void remember_menu(const uint8_t *spec, size_t n) {
  free(g_menu_last);
  g_menu_last = (char *)malloc(n + 1);
  if (!g_menu_last) return;
  memcpy(g_menu_last, spec, n);
  g_menu_last[n] = '\0';
}

extern "C" {

void host_menu_set(const uint8_t *spec, size_t n) {
  char text[8192];
  if (!copy_name_bytes(text, sizeof(text), spec, n)) return;
  remember_menu(spec, n);
  build_menu_bar(text);
}

/** Shows a context menu at (x, y) and answers the line of the item chosen, or -1. */
int32_t host_menu_popup(const uint8_t *spec, size_t n, double x, double y) {
  remember_menu(spec, n);
  const char *choice = getenv("NATIVE_MENU_CHOICE");
  if (choice != NULL && choice[0] != '\0') return (int32_t)strtol(choice, NULL, 10);
  if (!g_hwnd) return -1;
  // The spec's own lines become a popup menu of this window's.
  char text[8192];
  if (!copy_name_bytes(text, sizeof(text), spec, n)) return -1;
  HMENU menu = CreatePopupMenu();
  if (!menu) return -1;
  long long line = 0;
  char *item = text;
  while (item && *item) {
    char *next = strchr(item, '\n');
    if (next) *next = '\0';
    char *label = item;
    while (label[0] == ' ' && label[1] == ' ') label += 2;
    char *tab = strchr(label, '\t');
    if (tab) *tab = '\0';
    if (label[0] == '\0') {
      AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
    } else {
      size_t wide_len = 0;
      wchar_t *wide = utf8_to_utf16((const uint8_t *)label, strlen(label), &wide_len);
      if (wide) {
        AppendMenuW(menu, MF_STRING, (UINT_PTR)(line + 1), wide);
        free(wide);
      }
    }
    line++;
    item = next ? next + 1 : NULL;
  }
  POINT pt = {(LONG)(x * g_scale), (LONG)(y * g_scale)};
  ClientToScreen(g_hwnd, &pt);
  int32_t chosen = -1;
  UINT command = (UINT)TrackPopupMenu(menu, TPM_RETURNCMD | TPM_LEFTALIGN | TPM_TOPALIGN,
                                      pt.x, pt.y, 0, g_hwnd, NULL);
  if (command > 0) chosen = (int32_t)command - 1;
  DestroyMenu(menu);
  return chosen;
}

int32_t host_menu_item(void) { return g_menu_chosen; }

void host_menu_spec(window_text_cb cb) {
  const char *spec = g_menu_last == NULL ? "" : g_menu_last;
  cb((const uint8_t *)spec, strlen(spec));
}

}  // extern "C"

// ---------------------------------------------------------------------------
// Snapshots
//
// A headless run has no window: the frame is replayed into a bitmap of its own at the snapshot's
// scale and written as a PNG, the picture the gate checks.

/** Turns premultiplied BGRA pixels into the straight RGBA a PNG holds. */
static void straight_rgba(const uint8_t *bgra, uint8_t *rgba, int w, int h, int pitch, size_t out_pitch) {
  for (int y = 0; y < h; y++) {
    const uint8_t *src = bgra + (size_t)y * (size_t)pitch;
    uint8_t *dst = rgba + (size_t)y * out_pitch;
    for (int x = 0; x < w; x++) {
      unsigned a = src[x * 4 + 3];
      if (a == 0) {
        dst[x * 4 + 0] = dst[x * 4 + 1] = dst[x * 4 + 2] = dst[x * 4 + 3] = 0;
      } else {
        dst[x * 4 + 0] = (uint8_t)(src[x * 4 + 2] * 255 / a);
        dst[x * 4 + 1] = (uint8_t)(src[x * 4 + 1] * 255 / a);
        dst[x * 4 + 2] = (uint8_t)(src[x * 4 + 0] * 255 / a);
        dst[x * 4 + 3] = (uint8_t)a;
      }
    }
  }
}

static int write_png(const char *name, const uint8_t *rgba, int w, int h) {
  IWICImagingFactory *wic = wic_factory();
  if (!wic) return 0;
  size_t wide_len = 0;
  wchar_t *wide = utf8_to_utf16((const uint8_t *)name, strlen(name), &wide_len);
  if (!wide) return 0;
  IWICStream *stream = NULL;
  IWICBitmapEncoder *encoder = NULL;
  IWICBitmapFrameEncode *frame = NULL;
  IPropertyBag2 *options = NULL;
  IWICBitmap *bitmap = NULL;
  int ok = 0;
  HRESULT hr = wic->CreateStream(&stream);
  if (SUCCEEDED(hr)) hr = stream->InitializeFromFilename(wide, GENERIC_WRITE);
  if (SUCCEEDED(hr)) hr = wic->CreateEncoder(GUID_ContainerFormatPng, NULL, &encoder);
  if (SUCCEEDED(hr)) hr = encoder->Initialize((IStream *)stream, WICBitmapEncoderNoCache);
  if (SUCCEEDED(hr)) hr = encoder->CreateNewFrame(&frame, &options);
  if (SUCCEEDED(hr)) hr = frame->Initialize(options);
  if (SUCCEEDED(hr))
    hr = wic->CreateBitmapFromMemory((UINT)w, (UINT)h, GUID_WICPixelFormat32bppRGBA, (UINT)w * 4,
                                     (UINT)((size_t)w * (size_t)h * 4), (BYTE *)rgba, &bitmap);
  if (SUCCEEDED(hr)) {
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppRGBA;
    hr = frame->SetPixelFormat(&format);
    if (SUCCEEDED(hr)) hr = frame->WriteSource((IWICBitmapSource *)bitmap, NULL);
  }
  if (SUCCEEDED(hr)) hr = frame->Commit();
  if (SUCCEEDED(hr)) hr = encoder->Commit();
  ok = SUCCEEDED(hr);
  if (bitmap) bitmap->Release();
  if (options) options->Release();
  if (frame) frame->Release();
  if (encoder) encoder->Release();
  if (stream) stream->Release();
  free(wide);
  return ok;
}

extern "C" {

/** The composited snapshot walks the frame's layers; this host's frame is one flat list, so the
 *  snapshot it writes is the same picture. */
int32_t host_snapshot_composited(const uint8_t *path, size_t path_len, double width, double height,
                                 double scale);

int32_t host_snapshot(const uint8_t *path, size_t path_len, double width, double height, double scale) {
  if (path_len == 0 || path_len >= 4000) return 0;
  if (!(width > 0) || !(height > 0)) return 0;
  if (!(scale > 0)) scale = 1;
  if (width * scale > 16384 || height * scale > 16384) return 0;
  if (!ensure_device()) return 0;
  int pw = (int)(width * scale), ph = (int)(height * scale);
  if (pw <= 0 || ph <= 0) return 0;
  D2D1_BITMAP_PROPERTIES1 target_props = D2D1::BitmapProperties1(
      D2D1_BITMAP_OPTIONS_TARGET, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                                                    D2D1_ALPHA_MODE_PREMULTIPLIED),
      96.0f, 96.0f);
  ID2D1Bitmap1 *target = NULL;
  if (FAILED(g_d2d->CreateBitmap(D2D1::SizeU((UINT32)pw, (UINT32)ph), NULL, 0, &target_props, &target)) ||
      !target)
    return 0;
  g_d2d->SetTarget(target);
  g_d2d->SetDpi((FLOAT)(96.0 * scale), (FLOAT)(96.0 * scale));
  g_d2d->SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
  g_d2d->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  double saved_scale = g_scale;
  double saved_w = g_view_w, saved_h = g_view_h;
  g_scale = scale;
  // The frame is the page's size, which a shadow and a clip bound themselves by.
  g_view_w = width;
  g_view_h = height;
  int ok = 0;
  g_d2d->BeginDraw();
  {
    double started = frame_times() ? now_ms() : 0;
    paint_frame();
    HRESULT hr = g_d2d->EndDraw();
    frame_time("replay", started);
    if (SUCCEEDED(hr)) {
      D2D1_BITMAP_PROPERTIES1 cpu_props = D2D1::BitmapProperties1(
          (D2D1_BITMAP_OPTIONS)(D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW),
          D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96.0f, 96.0f);
      ID2D1Bitmap1 *cpu = NULL;
      if (SUCCEEDED(g_d2d->CreateBitmap(D2D1::SizeU((UINT32)pw, (UINT32)ph), NULL, 0, &cpu_props, &cpu)) &&
          cpu) {
        D2D1_MAPPED_RECT mapped = {0};
        if (SUCCEEDED(cpu->CopyFromBitmap(NULL, target, NULL)) &&
            SUCCEEDED(cpu->Map(D2D1_MAP_OPTIONS_READ, &mapped))) {
          char name[4000];
          memcpy(name, path, path_len);
          name[path_len] = '\0';
          int raw = path_len >= 5 && memcmp(name + path_len - 5, ".rgba", 5) == 0;
          if (raw) {
            size_t pitch = (size_t)pw * 4;
            uint8_t *rgba = (uint8_t *)malloc(pitch * (size_t)ph);
            if (rgba) {
              straight_rgba(mapped.bits, rgba, pw, ph, (int)mapped.pitch, pitch);
              // Raw snapshots keep premultiplied alpha, the way the other hosts write them.
              for (size_t k = 0; k < pitch * (size_t)ph; k += 4) {
                unsigned a = rgba[k + 3];
                for (int ch = 0; ch < 3; ch++)
                  rgba[k + ch] = (uint8_t)((unsigned)rgba[k + ch] * a / 255u);
              }
              FILE *f = fopen(name, "wb");
              if (f) {
                ok = fwrite(rgba, 1, pitch * (size_t)ph, f) == pitch * (size_t)ph;
                if (fclose(f) != 0) ok = 0;
              }
              free(rgba);
            }
          } else {
            size_t pitch = (size_t)pw * 4;
            uint8_t *rgba = (uint8_t *)malloc(pitch * (size_t)ph);
            if (rgba) {
              straight_rgba(mapped.bits, rgba, pw, ph, (int)mapped.pitch, pitch);
              ok = write_png(name, rgba, pw, ph);
              free(rgba);
            }
          }
          cpu->Unmap();
        }
        cpu->Release();
      }
    }
  }
  g_scale = saved_scale;
  g_view_w = saved_w;
  g_view_h = saved_h;
  g_d2d->SetTarget(NULL);
  target->Release();
  return ok ? 1 : 0;
}

/**
 * The composited snapshot: the frame is composited from its chunks into an offscreen texture of
 * the backend's and read back, which is the picture the window draws with the compositor on.
 * With the compositor off — or a frame its walk can't express — it is the plain snapshot.
 */
int32_t host_snapshot_composited(const uint8_t *path, size_t path_len, double width, double height,
                                 double scale) {
  if (path_len == 0 || path_len >= 4000) return 0;
  if (!ensure_device()) return host_snapshot(path, path_len, width, height, scale);
  if (!(scale > 0)) scale = 1;
  COMP_LOG("native: comp snapshot %gx%g at %g\n", width, height, scale);
  int pw = (int)(width * scale), ph = (int)(height * scale);
  if (pw <= 0 || ph <= 0 || width * scale > 16384 || height * scale > 16384)
    return host_snapshot(path, path_len, width, height, scale);
  if (g_comp == NULL) g_comp = comp_d3d11_backend(g_d3d);
  if (g_comp == NULL) return host_snapshot(path, path_len, width, height, scale);
  COMP_LOG("native: comp snapshot backend ready\n");
  double saved_scale = g_scale;
  double saved_w = g_view_w, saved_h = g_view_h;
  g_scale = scale;
  g_view_w = width;
  g_view_h = height;
  int done = 0;
  int tex = g_comp->vt->tex_create(g_comp, pw, ph);
  COMP_LOG("native: comp snapshot target tex=%d %dx%d\n", tex, pw, ph);
  if (tex >= 0) {
    g_comp_exact = 1;
    done = composite_into(tex, scale, pw, ph);
    g_comp_exact = 0;
    if (done) {
      unsigned char *rgba = (unsigned char *)malloc((size_t)pw * 4u * (size_t)ph);
      if (rgba != NULL) {
        CompRect all = {0, 0, pw, ph};
        COMP_LOG("native: comp snapshot readback\n");
        if (g_comp->vt->readback(g_comp, tex, all, rgba, pw * 4)) {
          char name[4000];
          memcpy(name, path, path_len);
          name[path_len] = '\0';
          int raw = path_len >= 5 && memcmp(name + path_len - 5, ".rgba", 5) == 0;
          if (raw) {
            // Raw snapshots keep premultiplied alpha, the way the other hosts write them.
            for (size_t k = 0; k + 3 < (size_t)pw * 4u * (size_t)ph; k += 4) {
              unsigned a = rgba[k + 3];
              for (int ch = 0; ch < 3; ch++) rgba[k + ch] = (uint8_t)((unsigned)rgba[k + ch] * a / 255u);
            }
            FILE *f = fopen(name, "wb");
            if (f != NULL) {
              int ok = fwrite(rgba, 1, (size_t)pw * 4u * (size_t)ph, f) == (size_t)pw * 4u * (size_t)ph;
              if (fclose(f) != 0) ok = 0;
              if (ok) done = 2;
            }
          } else if (write_png(name, rgba, pw, ph)) {
            done = 2;
          }
        }
        free(rgba);
      }
    }
    g_comp->vt->tex_destroy(g_comp, tex);
  }
  comp_drop_all();
  g_scale = saved_scale;
  g_view_w = saved_w;
  g_view_h = saved_h;
  if (done == 2) return 1;
  return host_snapshot(path, path_len, width, height, scale);
}

double host_backing_scale(void) { return g_scale; }

}  // extern "C"

// ---------------------------------------------------------------------------
// localStorage
//
// One JSON object per app, held in memory and written back on every change. The file lives under
// the user's local app data, or wherever NATIVE_STORAGE points, which is what the tests use.

typedef struct {
  char *key;
  char *value;
} StorageRow;

static StorageRow *g_storage = NULL;
static size_t g_storage_count = 0, g_storage_cap = 0;
static char *g_storage_path = NULL;

static StorageRow *storage_find(const char *key, size_t n) {
  for (size_t i = 0; i < g_storage_count; i++) {
    if (strlen(g_storage[i].key) == n && memcmp(g_storage[i].key, key, n) == 0) return &g_storage[i];
  }
  return NULL;
}

static void storage_put(const char *key, size_t kn, const char *value, size_t vn) {
  StorageRow *row = storage_find(key, kn);
  char *v = (char *)malloc(vn + 1);
  if (!v) return;
  memcpy(v, value, vn);
  v[vn] = '\0';
  if (row) {
    free(row->value);
    row->value = v;
    return;
  }
  if (g_storage_count == g_storage_cap) {
    size_t cap = g_storage_cap ? g_storage_cap * 2 : 16;
    StorageRow *rows = (StorageRow *)realloc(g_storage, cap * sizeof(StorageRow));
    if (!rows) {
      free(v);
      return;
    }
    g_storage = rows;
    g_storage_cap = cap;
  }
  char *k = (char *)malloc(kn + 1);
  if (!k) {
    free(v);
    return;
  }
  memcpy(k, key, kn);
  k[kn] = '\0';
  g_storage[g_storage_count].key = k;
  g_storage[g_storage_count].value = v;
  g_storage_count++;
}

static void storage_drop(size_t at) {
  free(g_storage[at].key);
  free(g_storage[at].value);
  memmove(&g_storage[at], &g_storage[at + 1], (g_storage_count - at - 1) * sizeof(StorageRow));
  g_storage_count--;
}

static void save_text(const char *text, size_t len) {
  if (!g_storage_path) return;
  FILE *f = fopen(g_storage_path, "wb");
  if (!f) return;
  fwrite(text, 1, len, f);
  fclose(f);
}

static void storage_save(void) {
  if (!g_storage_path) return;
  size_t cap = 64;
  char *text = (char *)malloc(cap);
  size_t at = 0;
  if (!text) return;
  text[at++] = '{';
  for (size_t i = 0; i < g_storage_count; i++) {
    const char *key = g_storage[i].key;
    const char *value = g_storage[i].value;
    size_t need = at + strlen(key) * 6 + strlen(value) * 6 + 32;
    if (need > cap) {
      while (need > cap) cap *= 2;
      char *grown = (char *)realloc(text, cap);
      if (!grown) {
        free(text);
        return;
      }
      text = grown;
    }
    if (i > 0) text[at++] = ',';
    text[at++] = '"';
    for (const unsigned char *p = (const unsigned char *)key; *p; p++) {
      if (*p == '"' || *p == '\\') {
        text[at++] = '\\';
        text[at++] = (char)*p;
      } else {
        text[at++] = (char)*p;
      }
    }
    text[at++] = '"';
    text[at++] = ':';
    text[at++] = '"';
    for (const unsigned char *p = (const unsigned char *)value; *p; p++) {
      switch (*p) {
        case '"': text[at++] = '\\'; text[at++] = '"'; break;
        case '\\': text[at++] = '\\'; text[at++] = '\\'; break;
        case '\n': text[at++] = '\\'; text[at++] = 'n'; break;
        case '\r': text[at++] = '\\'; text[at++] = 'r'; break;
        case '\t': text[at++] = '\\'; text[at++] = 't'; break;
        default:
          if (*p < 0x20) {
            static const char hex[] = "0123456789abcdef";
            text[at++] = '\\';
            text[at++] = 'u';
            text[at++] = '0';
            text[at++] = '0';
            text[at++] = hex[(*p >> 4) & 0xf];
            text[at++] = hex[*p & 0xf];
          } else {
            text[at++] = (char)*p;
          }
      }
    }
    text[at++] = '"';
  }
  text[at++] = '}';
  save_text(text, at);
  free(text);
}

static int hex_digit(int c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

/** Reads a JSON string at `p` and returns where it ends. */
static const char *json_read_string(const char *p, char **out, size_t *len) {
  *out = NULL;
  *len = 0;
  if (*p != '"') return p;
  p++;
  size_t cap = strlen(p) + 1, at = 0;
  char *buf = (char *)malloc(cap);
  if (!buf) return p;
  while (*p && *p != '"') {
    if (*p == '\\') {
      p++;
      switch (*p) {
        case 'n': buf[at++] = '\n'; p++; break;
        case 'r': buf[at++] = '\r'; p++; break;
        case 't': buf[at++] = '\t'; p++; break;
        case 'b': buf[at++] = '\b'; p++; break;
        case 'f': buf[at++] = '\f'; p++; break;
        case 'u': {
          unsigned cp = 0;
          int ok = 1;
          for (int i = 0; i < 4; i++) {
            int d = hex_digit((unsigned char)p[1 + i]);
            if (d < 0) {
              ok = 0;
              break;
            }
            cp = cp * 16 + (unsigned)d;
          }
          if (!ok) break;
          p += 5;
          at += utf8_put(cp, buf + at);
          break;
        }
        default: buf[at++] = *p; p++; break;
      }
    } else {
      buf[at++] = *p++;
    }
    if (at + 5 >= cap) {
      cap *= 2;
      char *grown = (char *)realloc(buf, cap);
      if (!grown) break;
      buf = grown;
    }
  }
  if (*p == '"') p++;
  buf[at] = '\0';
  *out = buf;
  *len = at;
  return p;
}

static const char *json_skip_space(const char *p) {
  while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
  return p;
}

static void storage_load(const char *text) {
  const char *p = json_skip_space(text);
  if (*p != '{') return;
  p++;
  for (;;) {
    p = json_skip_space(p);
    if (*p != '"') break;
    char *key = NULL;
    size_t kn = 0;
    p = json_read_string(p, &key, &kn);
    p = json_skip_space(p);
    if (*p == ':') p++;
    p = json_skip_space(p);
    if (*p == '"') {
      char *value = NULL;
      size_t vn = 0;
      p = json_read_string(p, &value, &vn);
      if (key && value) storage_put(key, kn, value, vn);
      free(value);
    }
    free(key);
    p = json_skip_space(p);
    if (*p == ',') {
      p++;
      continue;
    }
    break;
  }
}

static void make_dirs(const char *path) {
  char buf[4096];
  size_t len = strlen(path);
  if (len >= sizeof(buf)) return;
  memcpy(buf, path, len + 1);
  for (size_t i = 1; i < len; i++) {
    if (buf[i] == '\\' || buf[i] == '/') {
      char ch = buf[i];
      buf[i] = '\0';
      CreateDirectoryA(buf, NULL);
      buf[i] = ch;
    }
  }
}

extern "C" {

void host_storage_open(const uint8_t *name, size_t n) {
  if (g_storage_path) return;
  char path[4096];
  const char *env = getenv("NATIVE_STORAGE");
  if (env && *env) {
    if (strlen(env) >= sizeof(path)) return;
    memcpy(path, env, strlen(env) + 1);
    make_dirs(path);
  } else {
    const char *local = getenv("LOCALAPPDATA");
    if (!local || !*local) local = getenv("APPDATA");
    if (!local || !*local) local = ".";
    // The app's name, with anything a path doesn't want replaced.
    char safe[65];
    size_t at = 0;
    for (size_t i = 0; i < n && at < 64; i++) {
      unsigned char ch = name[i];
      int keep = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') ||
                 ch == '-' || ch == '_';
      safe[at++] = keep ? (char)ch : '-';
    }
    safe[at] = '\0';
    if (at == 0) memcpy(safe, "app", 4);
    snprintf(path, sizeof(path), "%s\\native\\%s", local, safe);
    make_dirs(path);
    size_t len = strlen(path);
    snprintf(path + len, sizeof(path) - len, "\\localStorage.json");
  }
  g_storage_path = dup_str(path);
  if (!g_storage_path) return;
  size_t len = 0;
  uint8_t *data = read_file_bytes(g_storage_path, &len);
  if (data) {
    char *text = (char *)malloc(len + 1);
    if (text) {
      memcpy(text, data, len);
      text[len] = '\0';
      storage_load(text);
      free(text);
    }
    free(data);
  }
}

/** The directory the storage file is in, which is where the page's own data lives: IndexedDB
 *  keeps its databases beside it. */
void host_storage_dir(window_text_cb cb) {
  if (!g_storage_path) {
    cb((const uint8_t *)"", 0);
    return;
  }
  const char *slash = strrchr(g_storage_path, '\\');
  if (slash == NULL) slash = strrchr(g_storage_path, '/');
  if (slash == NULL) {
    cb((const uint8_t *)"", 0);
    return;
  }
  cb((const uint8_t *)g_storage_path, (size_t)(slash - g_storage_path));
}

int32_t host_storage_has(const uint8_t *key, size_t n) {
  if (!g_storage_path) return 0;
  return storage_find((const char *)key, n) ? 1 : 0;
}

void host_storage_get(const uint8_t *key, size_t n, str_cb cb) {
  StorageRow *row = g_storage_path ? storage_find((const char *)key, n) : NULL;
  if (row) cb((const uint8_t *)row->value, strlen(row->value));
  else cb((const uint8_t *)"", 0);
}

void host_storage_set(const uint8_t *key, size_t kn, const uint8_t *value, size_t vn) {
  if (!g_storage_path) return;
  storage_put((const char *)key, kn, (const char *)value, vn);
  storage_save();
}

void host_storage_remove(const uint8_t *key, size_t n) {
  if (!g_storage_path) return;
  for (size_t i = 0; i < g_storage_count; i++) {
    if (strlen(g_storage[i].key) == n && memcmp(g_storage[i].key, key, n) == 0) {
      storage_drop(i);
      storage_save();
      return;
    }
  }
}

void host_storage_clear(void) {
  if (!g_storage_path) return;
  while (g_storage_count > 0) storage_drop(g_storage_count - 1);
  storage_save();
}

int32_t host_storage_length(void) { return g_storage_path ? (int32_t)g_storage_count : 0; }

void host_storage_key(int32_t index, str_cb cb) {
  if (g_storage_path && index >= 0 && (size_t)index < g_storage_count) {
    const char *key = g_storage[index].key;
    cb((const uint8_t *)key, strlen(key));
    return;
  }
  cb((const uint8_t *)"", 0);
}

}  // extern "C"

// ---------------------------------------------------------------------------
// Clipboard, files and drops

/** One clipboard format as UTF-8, by the name the runtime passes. */
static const char *CLIP_HTML = "HTML Format";

extern "C" {

void host_clipboard_write(const uint8_t *text, size_t text_len, const uint8_t *html, size_t html_len) {
  if (!OpenClipboard(g_hwnd)) return;
  EmptyClipboard();
  size_t wide_len = 0;
  wchar_t *wide = utf8_to_utf16(text, text_len, &wide_len);
  if (wide) {
    HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, (wide_len + 1) * sizeof(wchar_t));
    if (mem) {
      void *dst = GlobalLock(mem);
      memcpy(dst, wide, (wide_len + 1) * sizeof(wchar_t));
      GlobalUnlock(mem);
      SetClipboardData(CF_UNICODETEXT, mem);
    }
    free(wide);
  }
  if (html_len > 0) {
    // CF_HTML carries a header with byte offsets into the same buffer, as browsers write it.
    char header[128];
    // The header is a fixed width (every offset is ten digits), so its own length is the offset
    // the fragment starts at: StartHTML and StartFragment both name it.
    int header_len = snprintf(header, sizeof(header),
                              "Version:0.9\r\nStartHTML:0000000000\r\nEndHTML:0000000000\r\n"
                              "StartFragment:0000000000\r\nEndFragment:0000000000\r\n");
    size_t total = (size_t)header_len + html_len;
    snprintf(header, sizeof(header),
             "Version:0.9\r\nStartHTML:%010zu\r\nEndHTML:%010zu\r\nStartFragment:%010zu\r\n"
             "EndFragment:%010zu\r\n",
             (size_t)header_len, total, (size_t)header_len, total);
    header_len = (int)strlen(header);
    // The fixed header length matters: the offsets above are written in it.
    char buf[4096];
    if (html_len < sizeof(buf) / 2) {
      int at = snprintf(buf, sizeof(buf), "%s", header);
      memcpy(buf + at, html, html_len);
      HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, (size_t)at + html_len + 1);
      if (mem) {
        void *dst = GlobalLock(mem);
        memcpy(dst, buf, (size_t)at + html_len);
        ((char *)dst)[at + html_len] = 0;
        GlobalUnlock(mem);
        UINT format = RegisterClipboardFormatA(CLIP_HTML);
        if (format) SetClipboardData(format, mem);
        else GlobalFree(mem);
      }
    }
  }
  CloseClipboard();
}

void host_clipboard_read(const uint8_t *format, size_t n, str_cb cb) {
  char wanted[32];
  if (!copy_name_bytes(wanted, sizeof(wanted), format, n)) {
    cb((const uint8_t *)"", 0);
    return;
  }
  if (!OpenClipboard(g_hwnd)) {
    cb((const uint8_t *)"", 0);
    return;
  }
  if (strcmp(wanted, "text/html") == 0) {
    UINT html_format = RegisterClipboardFormatA(CLIP_HTML);
    HANDLE handle = html_format ? GetClipboardData(html_format) : NULL;
    if (handle) {
      char *data = (char *)GlobalLock(handle);
      if (data) {
        const char *start = strstr(data, "StartFragment:");
        size_t offset = 0;
        if (start) offset = (size_t)strtoul(start + 14, NULL, 10);
        if (offset > 0 && offset < GlobalSize(handle)) {
          const char *fragment = data + offset;
          const char *end = strstr(data, "<!--EndFragment-->");
          size_t len = end && (const char *)end > fragment ? (size_t)(end - fragment) : strlen(fragment);
          cb((const uint8_t *)fragment, len);
          GlobalUnlock(handle);
          CloseClipboard();
          return;
        }
        GlobalUnlock(handle);
      }
    }
    CloseClipboard();
    cb((const uint8_t *)"", 0);
    return;
  }
  HANDLE handle = GetClipboardData(CF_UNICODETEXT);
  if (handle) {
    wchar_t *wide = (wchar_t *)GlobalLock(handle);
    if (wide) {
      size_t len = wcslen(wide);
      char *utf8 = (char *)malloc(len * 4 + 1);
      if (utf8) {
        size_t at = 0;
        for (size_t i = 0; i < len; i++) at += utf8_put((uint32_t)wide[i], utf8 + at);
        utf8[at] = '\0';
        cb((const uint8_t *)utf8, at);
        free(utf8);
      }
      GlobalUnlock(handle);
    }
    CloseClipboard();
    return;
  }
  CloseClipboard();
  cb((const uint8_t *)"", 0);
}

/** The app's own files: fetch() resolves a page-relative URL against the bundle and reads these. */
int32_t host_file_size(const uint8_t *path, size_t n) {
  char name[4000];
  if (!copy_name_bytes(name, sizeof(name), path, n)) return -1;
  size_t wide_len = 0;
  wchar_t *wide = utf8_to_utf16((const uint8_t *)name, strlen(name), &wide_len);
  if (!wide) return -1;
  WIN32_FILE_ATTRIBUTE_DATA info;
  int32_t size = -1;
  if (GetFileAttributesExW(wide, GetFileExInfoStandard, &info) &&
      (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 && info.nFileSizeHigh == 0)
    size = (int32_t)info.nFileSizeLow;
  free(wide);
  return size;
}


// ---------------------------------------------------------------------------
// SQLite
//
// The store IndexedDB keeps its records in. A database and each prepared statement are an opaque
// id the runtime holds; ids are 1-based and 0 means none. Statements are cached by the runtime,
// so the table is the only limit on how many are open.

#define SQLITE_MAX_DB 8
#define SQLITE_MAX_STMT 512

static sqlite3 *g_sqlite_db[SQLITE_MAX_DB];
static sqlite3_stmt *g_sqlite_stmt[SQLITE_MAX_STMT];

static sqlite3 *sqlite_db_at(int32_t id) {
  return id > 0 && id <= SQLITE_MAX_DB ? g_sqlite_db[id - 1] : NULL;
}

static sqlite3_stmt *sqlite_stmt_at(int32_t id) {
  return id > 0 && id <= SQLITE_MAX_STMT ? g_sqlite_stmt[id - 1] : NULL;
}

static char *sqlite_copy(const uint8_t *s, size_t n) {
  char *p = (char *)malloc(n + 1);
  if (p == NULL) return NULL;
  if (n > 0) memcpy(p, s, n);
  p[n] = '\0';
  return p;
}

int32_t host_sqlite_open(const uint8_t *path, size_t n) {
  char *p = sqlite_copy(path, n);
  if (p == NULL) return 0;
  int32_t id = 0;
  for (int i = 0; i < SQLITE_MAX_DB; i++) {
    if (g_sqlite_db[i] != NULL) continue;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(p, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
      if (db != NULL) sqlite3_close(db);
      break;
    }
    sqlite3_busy_timeout(db, 2000);
    g_sqlite_db[i] = db;
    id = i + 1;
    break;
  }
  free(p);
  return id;
}

void host_sqlite_close(int32_t id) {
  sqlite3 *db = sqlite_db_at(id);
  if (db == NULL) return;
  sqlite3_close_v2(db);
  g_sqlite_db[id - 1] = NULL;
}

int32_t host_sqlite_exec(int32_t id, const uint8_t *sql, size_t n) {
  sqlite3 *db = sqlite_db_at(id);
  if (db == NULL) return SQLITE_MISUSE;
  char *q = sqlite_copy(sql, n);
  if (q == NULL) return SQLITE_NOMEM;
  int rc = sqlite3_exec(db, q, NULL, NULL, NULL);
  free(q);
  return rc;
}

int32_t host_sqlite_prepare(int32_t id, const uint8_t *sql, size_t n) {
  sqlite3 *db = sqlite_db_at(id);
  if (db == NULL) return 0;
  char *q = sqlite_copy(sql, n);
  if (q == NULL) return 0;
  int32_t found = 0;
  for (int i = 0; i < SQLITE_MAX_STMT; i++) {
    if (g_sqlite_stmt[i] != NULL) continue;
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, q, -1, &st, NULL) != SQLITE_OK) break;
    g_sqlite_stmt[i] = st;
    found = i + 1;
    break;
  }
  free(q);
  return found;
}

int32_t host_sqlite_finalize(int32_t id) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  if (st == NULL) return SQLITE_MISUSE;
  int rc = sqlite3_finalize(st);
  g_sqlite_stmt[id - 1] = NULL;
  return rc;
}

int32_t host_sqlite_reset(int32_t id) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? SQLITE_MISUSE : sqlite3_reset(st);
}

int32_t host_sqlite_clear_bindings(int32_t id) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? SQLITE_MISUSE : sqlite3_clear_bindings(st);
}

int32_t host_sqlite_bind_text(int32_t id, int32_t index, const uint8_t *value, size_t n) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  if (st == NULL) return SQLITE_MISUSE;
  return sqlite3_bind_text(st, index, (const char *)value, (int)n, SQLITE_TRANSIENT);
}

int32_t host_sqlite_bind_double(int32_t id, int32_t index, double value) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? SQLITE_MISUSE : sqlite3_bind_double(st, index, value);
}

int32_t host_sqlite_bind_int(int32_t id, int32_t index, double value) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? SQLITE_MISUSE : sqlite3_bind_int64(st, index, (sqlite3_int64)value);
}

int32_t host_sqlite_bind_null(int32_t id, int32_t index) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? SQLITE_MISUSE : sqlite3_bind_null(st, index);
}

int32_t host_sqlite_bind_blob(int32_t id, int32_t index, const uint8_t *value, size_t n) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  if (st == NULL) return SQLITE_MISUSE;
  return sqlite3_bind_blob(st, index, value, (int)n, SQLITE_TRANSIENT);
}

int32_t host_sqlite_step(int32_t id) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? SQLITE_MISUSE : sqlite3_step(st);
}

int32_t host_sqlite_column_count(int32_t id) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? 0 : sqlite3_column_count(st);
}

int32_t host_sqlite_column_type(int32_t id, int32_t col) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? SQLITE_NULL : sqlite3_column_type(st, col);
}

void host_sqlite_column_text(int32_t id, int32_t col, window_text_cb cb) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  if (st == NULL) { cb((const uint8_t *)"", 0); return; }
  const unsigned char *text = sqlite3_column_text(st, col);
  int n = sqlite3_column_bytes(st, col);
  cb(text == NULL ? (const uint8_t *)"" : text, text == NULL ? 0 : (size_t)n);
}

void host_sqlite_column_blob(int32_t id, int32_t col, bytes_cb cb) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  if (st == NULL) { cb(NULL, 0); return; }
  const void *blob = sqlite3_column_blob(st, col);
  int n = sqlite3_column_bytes(st, col);
  cb(blob == NULL ? NULL : (const uint8_t *)blob, blob == NULL ? 0 : (size_t)n);
}

double host_sqlite_column_double(int32_t id, int32_t col) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? 0 : sqlite3_column_double(st, col);
}

double host_sqlite_changes(int32_t id) {
  sqlite3 *db = sqlite_db_at(id);
  return db == NULL ? 0 : (double)sqlite3_changes(db);
}

double host_sqlite_last_id(int32_t id) {
  sqlite3 *db = sqlite_db_at(id);
  return db == NULL ? 0 : (double)sqlite3_last_insert_rowid(db);
}

void host_sqlite_errmsg(int32_t id, window_text_cb cb) {
  sqlite3 *db = sqlite_db_at(id);
  const char *msg = db == NULL ? "no database" : sqlite3_errmsg(db);
  cb((const uint8_t *)msg, strlen(msg));
}

void host_file_read(const uint8_t *path, size_t n, bytes_cb cb) {
  char name[4000];
  if (!copy_name_bytes(name, sizeof(name), path, n)) {
    cb(NULL, 0);
    return;
  }
  size_t wide_len = 0;
  wchar_t *wide = utf8_to_utf16((const uint8_t *)name, strlen(name), &wide_len);
  if (!wide) {
    cb(NULL, 0);
    return;
  }
  FILE *f = _wfopen(wide, L"rb");
  free(wide);
  if (!f) {
    cb(NULL, 0);
    return;
  }
  fseek(f, 0, SEEK_END);
  long size = ftell(f);
  rewind(f);
  if (size <= 0) {
    fclose(f);
    cb(NULL, 0);
    return;
  }
  uint8_t *buf = (uint8_t *)malloc((size_t)size);
  if (!buf) {
    fclose(f);
    cb(NULL, 0);
    return;
  }
  size_t got = fread(buf, 1, (size_t)size, f);
  fclose(f);
  if (got == 0) {
    free(buf);
    cb(NULL, 0);
    return;
  }
  cb(buf, got);
  free(buf);
}

/** A bundled app's files live in `<executable>.resources` beside it, else beside the executable. */
void host_bundle_dir(dir_cb cb) {
  wchar_t exe[4000];
  DWORD len = GetModuleFileNameW(NULL, exe, 4000);
  if (len == 0 || len >= 4000) return;
  wchar_t *slash = wcsrchr(exe, L'\\');
  if (!slash) return;
  *slash = L'\0';
  const wchar_t *name = slash + 1;
  wchar_t candidate[8000];
  _snwprintf(candidate, 8000, L"%s\\%s.resources", exe, name);
  const wchar_t *dir = exe;
  DWORD attrs = GetFileAttributesW(candidate);
  if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY)) dir = candidate;
  size_t wide_len = wcslen(dir);
  char *utf8 = (char *)malloc(wide_len * 4 + 1);
  if (!utf8) return;
  size_t at = 0;
  for (size_t i = 0; i < wide_len; i++) at += utf8_put((uint32_t)dir[i], utf8 + at);
  utf8[at] = '\0';
  cb((const uint8_t *)utf8, at);
  free(utf8);
}

int32_t host_drop_file_count(void) { return g_drop_count; }

/** One dropped file's name: the last segment of its path. */
void host_drop_file_name(int32_t index, str_cb cb) {
  if (index < 0 || index >= g_drop_count) {
    cb((const uint8_t *)"", 0);
    return;
  }
  const char *path = g_drop_paths[index];
  const char *slash = strrchr(path, '\\');
  const char *name = slash ? slash + 1 : path;
  cb((const uint8_t *)name, strlen(name));
}

void host_drop_file_path(int32_t index, str_cb cb) {
  if (index < 0 || index >= g_drop_count) {
    cb((const uint8_t *)"", 0);
    return;
  }
  cb((const uint8_t *)g_drop_paths[index], strlen(g_drop_paths[index]));
}

/** The page's cursors: the system's own arrow, hand, text beam and the rest. */
void host_set_cursor(int32_t cursor) {
  if (!g_hwnd) return;
  LPCSTR name = IDC_ARROW;
  switch (cursor) {
    case 1: name = IDC_HAND; break;
    case 2: name = IDC_IBEAM; break;
    case 3: name = IDC_CROSS; break;
    case 4: name = IDC_SIZEWE; break;
    case 5: name = IDC_SIZENS; break;
    case 6: name = IDC_SIZENWSE; break;
    case 7: name = IDC_SIZENESW; break;
    case 8: name = IDC_SIZEALL; break;
    case 9: name = IDC_NO; break;
    case 10: name = IDC_WAIT; break;
    default: name = IDC_ARROW; break;
  }
  g_cursor = LoadCursorA(NULL, name);
  SetCursor(g_cursor);
}

void host_set_cursor_image(int32_t id, double x, double y) {
  (void)id;
  (void)x;
  (void)y;
}

}  // extern "C"

// ---------------------------------------------------------------------------
// Canvas 2D
//
// A <canvas> owns a bitmap of its own. The canvas's user space is the bitmap's own pixels, top
// left origin and y down, so the only transform between the two is the one setTransform installs.
// Operations run as they are called and paint straight into the bitmap; the bitmap is drawn into
// the page as an image when the page paints (CMD_CANVAS), so a canvas has no commands of its own
// in the display list.
//
// Paths are built in bitmap pixels: the transform in effect when a segment is added is baked into
// it, as the canvas API requires. Filling and stroking therefore paint the stored path with an
// identity transform, and a stroke sizes its pen by the transform in effect at stroke time.

#define CANVAS_MAX_CLIPS 16
#define CANVAS_MAX_STACK 64
#define CANVAS_MAX_DASH 32

enum { CSEG_MOVE = 0, CSEG_LINE, CSEG_CUBIC };

/** One segment of the current path, its points already in bitmap pixels. */
typedef struct {
  int kind;
  double x[6];  // line: x, y; cubic: c1x, c1y, c2x, c2y, x, y
} CanvasSeg;

typedef struct {
  ID2D1Bitmap1 *bitmap;
  ID2D1DeviceContext *dc;
  double w, h;
  int drawing;
  D2D1_MATRIX_3X2_F m;
  CanvasSeg *segs;
  int seg_count, seg_cap;
  double cur_x, cur_y;
  int has_cur;
  // styles
  uint32_t fill, stroke;
  int fill_kind, stroke_kind;  // 0 a colour, 1 a gradient
  char *fill_def, *stroke_def;
  double alpha, line_width, dash_offset;
  FLOAT dashes[CANVAS_MAX_DASH];
  int dash_count;
  int cap, join, composite;
  double font_size, font_weight;
  // The clip stack: geometries in bitmap pixels, intersected by the host's layers.
  ID2D1Geometry *clips[CANVAS_MAX_CLIPS];
  int clip_count;
  ID2D1Layer *layers[CANVAS_MAX_CLIPS];
  int layer_count;
  struct {
    D2D1_MATRIX_3X2_F m;
    int clip_count;
  } stack[CANVAS_MAX_STACK];
  int stack_depth;
  // A canvas with a WebGL context paints from a readback of it instead of from these.
  struct CanvasGl *gl;
  // What a fill or stroke paints with, kept between calls: a script that fills a thousand rects
  // a frame made a thousand brushes, and a gradient's stops were parsed and built again for
  // every shape it filled. The solid brush is recoloured per call; the stops are kept for the
  // last gradient definition seen.
  ID2D1SolidColorBrush *solid;
  char *stops_def;
  ID2D1GradientStopCollection *stops;
} Canvas;

#define MAX_CANVASES 64
static Canvas *g_canvases[MAX_CANVASES];
static int g_canvas_count = 0;

static Canvas *canvas_at(int32_t id) {
  if (id < 0 || id >= g_canvas_count) return NULL;
  return g_canvases[id];
}

/** The bitmap a canvas paints into, for the page's replay. */
static ID2D1Bitmap1 *canvas_bitmap(int32_t id) {
  Canvas *c = canvas_at(id);
  return c ? c->bitmap : NULL;
}

/** A canvas coordinate kept within a range far outside any bitmap. */
static double canvas_coord(double v) { return v < -1e7 ? -1e7 : v > 1e7 ? 1e7 : v; }

/** A point of canvas user space in the bitmap's own pixels. */
static void canvas_point(Canvas *c, double x, double y, double *ox, double *oy) {
  const D2D1_MATRIX_3X2_F *m = &c->m;
  *ox = canvas_coord(x * m->_11 + y * m->_21 + m->_31);
  *oy = canvas_coord(x * m->_12 + y * m->_22 + m->_32);
}

/** How much the current transform scales one user unit, for a stroke's pen and a gradient's radii. */
static double canvas_scale(const Canvas *c) {
  double det = fabs(c->m._11 * c->m._22 - c->m._12 * c->m._21);
  double scale = sqrt(det);
  return scale > 0 ? scale : 1;
}

static void canvas_reset_state(Canvas *c) {
  c->m = D2D1::IdentityMatrix();
  c->seg_count = 0;
  c->has_cur = 0;
  c->cur_x = c->cur_y = 0;
  c->clip_count = 0;
  c->stack_depth = 0;
  c->alpha = 1;
  c->line_width = 1;
  c->cap = 0;
  c->join = 0;
  c->composite = 0;
  c->dash_count = 0;
  c->dash_offset = 0;
  c->font_size = 10;
  c->font_weight = 400;
}

/** The device context every canvas paints through, in a BeginDraw held until the canvas is read. */
static ID2D1DeviceContext *canvas_begin(Canvas *c) {
  if (!c || !c->dc) return NULL;
  if (!c->drawing) {
    c->dc->BeginDraw();
    c->drawing = 1;
  }
  return c->dc;
}

/** Ends the canvas's draw so its pixels are settled and can be read or shown. */
static void canvas_flush(Canvas *c) {
  if (!c || !c->dc || !c->drawing) return;
  c->dc->EndDraw();
  c->drawing = 0;
}

static void canvas_release_bitmap(Canvas *c) {
  canvas_flush(c);
  // The kept brush and stops belong to the context going away.
  if (c->solid) {
    c->solid->Release();
    c->solid = NULL;
  }
  if (c->stops) {
    c->stops->Release();
    c->stops = NULL;
  }
  free(c->stops_def);
  c->stops_def = NULL;
  if (c->dc) {
    c->dc->SetTarget(NULL);
    c->dc->Release();
    c->dc = NULL;
  }
  if (c->bitmap) {
    c->bitmap->Release();
    c->bitmap = NULL;
  }
}

static int canvas_make_bitmap(Canvas *c, double w, double h) {
  canvas_release_bitmap(c);
  if (!ensure_device() || !g_d2d_device) return 0;
  c->w = w > 0 ? floor(w) : 0;
  c->h = h > 0 ? floor(h) : 0;
  if (c->w < 1 || c->h < 1) return 0;
  D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
      D2D1_BITMAP_OPTIONS_TARGET,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96.0f, 96.0f);
  if (FAILED(g_d2d->CreateBitmap(D2D1::SizeU((UINT32)c->w, (UINT32)c->h), NULL, 0, &props, &c->bitmap)) ||
      !c->bitmap)
    return 0;
  if (FAILED(g_d2d_device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &c->dc)) || !c->dc) return 0;
  c->dc->SetTarget(c->bitmap);
  c->dc->SetDpi(96.0f, 96.0f);
  c->dc->SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
  c->dc->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
  c->dc->BeginDraw();
  c->drawing = 1;
  c->dc->Clear(D2D1::ColorF(0.0f, 0.0f, 0.0f, 0.0f));
  canvas_reset_state(c);
  return 1;
}

/** Adds a point to the current path, in the transform in effect. */
static void canvas_move(Canvas *c, double x, double y) {
  double px, py;
  canvas_point(c, x, y, &px, &py);
  if (c->seg_count == c->seg_cap) {
    int cap = c->seg_cap ? c->seg_cap * 2 : 64;
    CanvasSeg *grown = (CanvasSeg *)realloc(c->segs, (size_t)cap * sizeof(CanvasSeg));
    if (!grown) return;
    c->segs = grown;
    c->seg_cap = cap;
  }
  CanvasSeg *seg = &c->segs[c->seg_count++];
  memset(seg, 0, sizeof(*seg));
  seg->kind = CSEG_MOVE;
  seg->x[0] = px;
  seg->x[1] = py;
  c->cur_x = px;
  c->cur_y = py;
  c->has_cur = 1;
}

static void canvas_line(Canvas *c, double x, double y) {
  double px, py;
  canvas_point(c, x, y, &px, &py);
  if (!c->has_cur) canvas_move(c, x, y);
  if (c->seg_count == c->seg_cap) {
    int cap = c->seg_cap ? c->seg_cap * 2 : 64;
    CanvasSeg *grown = (CanvasSeg *)realloc(c->segs, (size_t)cap * sizeof(CanvasSeg));
    if (!grown) return;
    c->segs = grown;
    c->seg_cap = cap;
  }
  CanvasSeg *seg = &c->segs[c->seg_count++];
  memset(seg, 0, sizeof(*seg));
  seg->kind = CSEG_LINE;
  seg->x[0] = px;
  seg->x[1] = py;
  c->cur_x = px;
  c->cur_y = py;
}

static void canvas_cubic(Canvas *c, double c1x, double c1y, double c2x, double c2y, double x, double y) {
  double px1, py1, px2, py2, px, py;
  canvas_point(c, c1x, c1y, &px1, &py1);
  canvas_point(c, c2x, c2y, &px2, &py2);
  canvas_point(c, x, y, &px, &py);
  if (!c->has_cur) canvas_move(c, x, y);
  if (c->seg_count == c->seg_cap) {
    int cap = c->seg_cap ? c->seg_cap * 2 : 64;
    CanvasSeg *grown = (CanvasSeg *)realloc(c->segs, (size_t)cap * sizeof(CanvasSeg));
    if (!grown) return;
    c->segs = grown;
    c->seg_cap = cap;
  }
  CanvasSeg *seg = &c->segs[c->seg_count++];
  memset(seg, 0, sizeof(*seg));
  seg->kind = CSEG_CUBIC;
  seg->x[0] = px1;
  seg->x[1] = py1;
  seg->x[2] = px2;
  seg->x[3] = py2;
  seg->x[4] = px;
  seg->x[5] = py;
  c->cur_x = px;
  c->cur_y = py;
}

/** A cubic to a point already in bitmap pixels. */
static void canvas_cubic_in_place(Canvas *c, double c1x, double c1y, double c2x, double c2y, double x, double y) {
  if (c->seg_count == c->seg_cap) {
    int cap = c->seg_cap ? c->seg_cap * 2 : 64;
    CanvasSeg *grown = (CanvasSeg *)realloc(c->segs, (size_t)cap * sizeof(CanvasSeg));
    if (!grown) return;
    c->segs = grown;
    c->seg_cap = cap;
  }
  CanvasSeg *seg = &c->segs[c->seg_count++];
  memset(seg, 0, sizeof(*seg));
  seg->kind = CSEG_CUBIC;
  seg->x[0] = canvas_coord(c1x);
  seg->x[1] = canvas_coord(c1y);
  seg->x[2] = canvas_coord(c2x);
  seg->x[3] = canvas_coord(c2y);
  seg->x[4] = canvas_coord(x);
  seg->x[5] = canvas_coord(y);
  c->cur_x = seg->x[4];
  c->cur_y = seg->x[5];
}

/** The path as a geometry in bitmap pixels; the caller releases it. */
static ID2D1PathGeometry *canvas_geometry(Canvas *c, D2D1_FILL_MODE fill) {
  Geo g;
  geo_begin(&g, fill);
  if (!g.sink) return NULL;
  for (int i = 0; i < c->seg_count; i++) {
    CanvasSeg *seg = &c->segs[i];
    if (seg->kind == CSEG_MOVE) {
      // A move closes whatever figure was open before it.
      if (i > 0) g.sink->EndFigure(D2D1_FIGURE_END_OPEN);
      g.sink->BeginFigure(D2D1::Point2F((FLOAT)seg->x[0], (FLOAT)seg->x[1]), D2D1_FIGURE_BEGIN_FILLED);
    } else if (seg->kind == CSEG_LINE) {
      g.sink->AddLine(D2D1::Point2F((FLOAT)seg->x[0], (FLOAT)seg->x[1]));
    } else {
      g.sink->AddBezier(D2D1::BezierSegment(D2D1::Point2F((FLOAT)seg->x[0], (FLOAT)seg->x[1]),
                                            D2D1::Point2F((FLOAT)seg->x[2], (FLOAT)seg->x[3]),
                                            D2D1::Point2F((FLOAT)seg->x[4], (FLOAT)seg->x[5])));
    }
  }
  // A figure the path never closed still fills as if it were closed, as canvas fill does.
  if (c->seg_count > 0) g.sink->EndFigure(D2D1_FIGURE_END_OPEN);
  return geo_end(&g);
}

/** The paint a canvas fill or stroke draws with: a colour, or the gradient it was given. */
/** The canvas's solid brush in `color` at the canvas alpha, a new reference for the caller. */
static ID2D1Brush *canvas_solid(Canvas *c, uint32_t color) {
  if (!c->dc) return NULL;
  if (!c->solid) {
    c->solid = solid_brush_on(c->dc, color, c->alpha);
    if (!c->solid) return NULL;
  } else {
    c->solid->SetColor(colour_of(color, c->alpha));
    c->solid->SetOpacity(1.0f);
  }
  c->solid->AddRef();
  return c->solid;
}

static ID2D1Brush *canvas_brush(Canvas *c, int gradient, uint32_t color, const char *def) {
  ID2D1DeviceContext *dc = c->dc;
  if (!gradient || !def) return canvas_solid(c, color);
  // "l;x0,y0,x1,y1" or "r;x0,y0,r0,x1,y1,r1", then ";colour,offset" per stop.
  Stops st;
  double line[6] = {0, 0, 0, 0, 0, 0};
  int count = 0;
  const char *p = def;
  int kind = *p == 'r' ? 1 : 0;
  if (*p) p++;
  if (*p == ';') p++;
  while (*p && *p != ';' && count < 6) {
    char *end;
    double v = strtod(p, &end);
    if (end == p) break;
    line[count++] = v;
    p = end;
    if (*p == ',') p++;
  }
  if (*p == ';') p++;
  st.n = 0;
  while (*p && st.n < MAX_STOPS) {
    char *end;
    unsigned long long col = strtoull(p, &end, 10);
    if (end == p) break;
    p = end;
    if (*p == ',') p++;
    double at = strtod(p, &end);
    if (end == p) break;
    p = end;
    st.col[st.n] = (uint32_t)col;
    st.loc[st.n] = at;
    st.n++;
    if (*p == ';') p++;
    else break;
  }
  if (st.n < 2) return canvas_solid(c, color);
  ID2D1GradientStopCollection *stops = NULL;
  if (c->stops && c->stops_def && strcmp(c->stops_def, def) == 0) {
    stops = c->stops;
    stops->AddRef();
  } else {
    stops = make_stops(&st, dc);
    if (stops) {
      if (c->stops) c->stops->Release();
      free(c->stops_def);
      c->stops = stops;
      c->stops->AddRef();
      c->stops_def = dup_str(def);
    }
  }
  if (!stops) return canvas_solid(c, color);
  double scale = canvas_scale(c);
  ID2D1Brush *brush = NULL;
  if (kind == 0 && count >= 4) {
    double x0 = line[0] * c->m._11 + line[1] * c->m._21 + c->m._31;
    double y0 = line[0] * c->m._12 + line[1] * c->m._22 + c->m._32;
    double x1 = line[2] * c->m._11 + line[3] * c->m._21 + c->m._31;
    double y1 = line[2] * c->m._12 + line[3] * c->m._22 + c->m._32;
    D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES props = D2D1::LinearGradientBrushProperties(
        D2D1::Point2F((FLOAT)x0, (FLOAT)y0), D2D1::Point2F((FLOAT)x1, (FLOAT)y1));
    ID2D1LinearGradientBrush *linear = NULL;
    if (dc && SUCCEEDED(dc->CreateLinearGradientBrush(&props, NULL, stops, &linear)) && linear)
      brush = linear;
  } else if (count >= 6) {
    double x0 = line[0] * c->m._11 + line[1] * c->m._21 + c->m._31;
    double y0 = line[0] * c->m._12 + line[1] * c->m._22 + c->m._32;
    double x1 = line[3] * c->m._11 + line[4] * c->m._21 + c->m._31;
    double y1 = line[3] * c->m._12 + line[4] * c->m._22 + c->m._32;
    double r1 = fabs(line[5]) * scale;
    D2D1_RADIAL_GRADIENT_BRUSH_PROPERTIES props = D2D1::RadialGradientBrushProperties(
        D2D1::Point2F((FLOAT)x1, (FLOAT)y1), D2D1::Point2F((FLOAT)(x0 - x1), (FLOAT)(y0 - y1)),
        (FLOAT)r1, (FLOAT)r1);
    ID2D1RadialGradientBrush *radial = NULL;
    if (dc && SUCCEEDED(dc->CreateRadialGradientBrush(&props, NULL, stops, &radial)) && radial)
      brush = radial;
  }
  stops->Release();
  if (brush) brush->SetOpacity((FLOAT)c->alpha);
  else brush = canvas_solid(c, color);
  return brush;
}

/**
 * The paint for a shape drawn with the canvas's transform on the context (a fill or stroke of a
 * rectangle): canvas_brush places a gradient in bitmap pixels, where a path's points are, so the
 * context's transform would move it a second time. The brush takes that transform back off.
 */
static ID2D1Brush *canvas_brush_under_transform(Canvas *c, int gradient, uint32_t color, const char *def) {
  ID2D1Brush *brush = canvas_brush(c, gradient, color, def);
  if (brush && gradient && def) {
    D2D1::Matrix3x2F inv(c->m._11, c->m._12, c->m._21, c->m._22, c->m._31, c->m._32);
    if (inv.Invert()) brush->SetTransform(inv);
  }
  return brush;
}

/** The context blend a canvas composite mode asks for. `lighter` adds the source to what is
 *  under it, the one mode beyond the default that a Direct2D primitive blend expresses; `copy`
 *  replaces what it covers. The modes that read the destination through the shape's coverage
 *  (source-in, destination-atop and the rest of that family) need a layer of their own, and
 *  paint the way source-over does until one is built for them. */
static D2D1_PRIMITIVE_BLEND canvas_blend(int mode) {
  switch (mode) {
    case 1: return D2D1_PRIMITIVE_BLEND_ADD;   // "lighter"
    case 2: return D2D1_PRIMITIVE_BLEND_COPY;  // "copy"
    default: return D2D1_PRIMITIVE_BLEND_SOURCE_OVER;
  }
}

/** Pushes the canvas's clips as layers, so what is drawn after stays inside them. */
static int canvas_enter(Canvas *c) {
  ID2D1DeviceContext *dc = canvas_begin(c);
  if (!dc) return 0;
  dc->SetPrimitiveBlend(canvas_blend(c->composite));
  int pushed = 0;
  c->layer_count = 0;
  for (int i = 0; i < c->clip_count; i++) {
    ID2D1Layer *layer = NULL;
    if (FAILED(dc->CreateLayer(&layer)) || !layer) break;
    D2D1_LAYER_PARAMETERS1 params = D2D1::LayerParameters1(
        D2D1::InfiniteRect(), c->clips[i], D2D1_ANTIALIAS_MODE_PER_PRIMITIVE,
        D2D1::IdentityMatrix(), 1.0f, NULL, D2D1_LAYER_OPTIONS1_NONE);
    dc->PushLayer(&params, layer);
    // The layer is held for the pop; its address is enough to release it there.
    c->layers[pushed++] = layer;
  }
  c->layer_count = pushed;
  return pushed;
}

/** Pops the layers canvas_enter pushed. */
static void canvas_leave(Canvas *c) {
  if (!c->dc) return;
  for (int i = c->layer_count - 1; i >= 0; i--) c->dc->PopLayer();
  for (int i = 0; i < c->layer_count; i++) c->layers[i]->Release();
  c->layer_count = 0;
  c->dc->SetPrimitiveBlend(D2D1_PRIMITIVE_BLEND_SOURCE_OVER);
}

/** Sets a canvas stroke's pen: its width, caps, joins and dashes. */
static ID2D1StrokeStyle *canvas_stroke_style(Canvas *c) {
  D2D1_CAP_STYLE cap = c->cap == 1 ? D2D1_CAP_STYLE_ROUND
                        : c->cap == 2 ? D2D1_CAP_STYLE_SQUARE
                                      : D2D1_CAP_STYLE_FLAT;
  D2D1_LINE_JOIN join = c->join == 1 ? D2D1_LINE_JOIN_ROUND
                         : c->join == 2 ? D2D1_LINE_JOIN_BEVEL
                                        : D2D1_LINE_JOIN_MITER;
  D2D1_DASH_STYLE dash = c->dash_count > 0 ? D2D1_DASH_STYLE_CUSTOM : D2D1_DASH_STYLE_SOLID;
  D2D1_STROKE_STYLE_PROPERTIES props = D2D1::StrokeStyleProperties(cap, cap, cap, join, 10.0f, dash, 0.0f);
  // An undashed pen is one of nine, made once each: it belongs to the factory, not a context.
  static ID2D1StrokeStyle *plain[3][3];
  if (c->dash_count == 0 && c->cap >= 0 && c->cap < 3 && c->join >= 0 && c->join < 3) {
    ID2D1StrokeStyle **kept = &plain[c->cap][c->join];
    if (*kept == NULL) g_d2d_factory->CreateStrokeStyle(props, NULL, 0, kept);
    if (*kept != NULL) (*kept)->AddRef();
    return *kept;
  }
  ID2D1StrokeStyle *style = NULL;
  g_d2d_factory->CreateStrokeStyle(props, c->dash_count > 0 ? c->dashes : NULL, (UINT32)c->dash_count, &style);
  return style;
}

static void canvas_line_in_place(Canvas *c, double x, double y);
static void canvas_cubic_in_place(Canvas *c, double c1x, double c1y, double c2x, double c2y, double x, double y);

/** Appends the arc around (cx, cy) from `start` to `end` radians to the current path. */
static void canvas_arc_points(Canvas *c, double cx, double cy, double rx, double ry, double start, double end,
                              int ccw) {
  double sweep = end - start;
  // An arc that turns a whole circle or more is the whole circle (HTML canvas, "ellipse method
  // steps"); only a shorter one is brought into one turn. Folding 2π itself down to 0 left every
  // full circle with no segments, so `arc(x, y, r, 0, Math.PI * 2)` drew nothing.
  if (!ccw && sweep >= 2 * M_PI) {
    sweep = 2 * M_PI;
  } else if (ccw && sweep <= -2 * M_PI) {
    sweep = -2 * M_PI;
  } else if (ccw) {
    while (sweep > 0) sweep -= 2 * M_PI;
    while (sweep <= -2 * M_PI) sweep += 2 * M_PI;
  } else {
    while (sweep < 0) sweep += 2 * M_PI;
    while (sweep >= 2 * M_PI) sweep -= 2 * M_PI;
  }
  // A segment per couple of pixels of arc, so a large radius keeps its curve instead of turning
  // into a polygon.
  double radius = fmax(rx, ry);
  int steps = (int)ceil(fabs(sweep) * radius / 2.0);
  if (steps < 1) steps = 1;
  if (steps > 512) steps = 512;
  for (int i = 1; i <= steps; i++) {
    double t = start + sweep * ((double)i / steps);
    canvas_line(c, cx + rx * cos(t), cy + ry * sin(t));
  }
}

/** Adds the arc a canvas arcTo draws: the corner of the two tangents, rounded by `r`. */
static void canvas_arc_to_points(Canvas *c, double x1, double y1, double x2, double y2, double r) {
  if (!c->has_cur || !(r > 0)) {
    canvas_line(c, x1, y1);
    return;
  }
  double px, py;
  canvas_point(c, c->cur_x, c->cur_y, &px, &py);
  // The corner is where the two tangent lines meet; the arc's ends sit `t` back along each.
  double v1x = px - x1, v1y = py - y1, v2x = x2 - x1, v2y = y2 - y1;
  double l1 = sqrt(v1x * v1x + v1y * v1y), l2 = sqrt(v2x * v2x + v2y * v2y);
  if (l1 <= 0 || l2 <= 0) {
    canvas_line(c, x1, y1);
    return;
  }
  v1x /= l1;
  v1y /= l1;
  v2x /= l2;
  v2y /= l2;
  double cos_theta = v1x * v2x + v1y * v2y;
  if (cos_theta > 0.9999 || cos_theta < -0.9999) {
    canvas_line(c, x1, y1);
    return;
  }
  double theta = acos(cos_theta);
  double t = r / tan(theta / 2);
  if (t > l1) t = l1;
  if (t > l2) t = l2;
  double t1x = x1 + v1x * t, t1y = y1 + v1y * t;
  double t2x = x1 + v2x * t, t2y = y1 + v2y * t;
  canvas_line_in_place(c, t1x, t1y);
  double bx = v1x + v2x, by = v1y + v2y;
  double bl = sqrt(bx * bx + by * by);
  if (bl <= 0) {
    canvas_line_in_place(c, t2x, t2y);
    return;
  }
  double center_dist = r / sin(theta / 2);
  double cx = x1 + (bx / bl) * center_dist, cy = y1 + (by / bl) * center_dist;
  double a0 = atan2(t1y - cy, t1x - cx), a1 = atan2(t2y - cy, t2x - cx);
  int ccw = (v1x * v2y - v1y * v2x) > 0 ? 0 : 1;
  canvas_arc_points(c, cx, cy, r, r, a0, a1, ccw);
}

/** A line to a point already in bitmap pixels. */
static void canvas_line_in_place(Canvas *c, double x, double y) {
  if (c->seg_count == c->seg_cap) {
    int cap = c->seg_cap ? c->seg_cap * 2 : 64;
    CanvasSeg *grown = (CanvasSeg *)realloc(c->segs, (size_t)cap * sizeof(CanvasSeg));
    if (!grown) return;
    c->segs = grown;
    c->seg_cap = cap;
  }
  CanvasSeg *seg = &c->segs[c->seg_count++];
  memset(seg, 0, sizeof(*seg));
  seg->kind = CSEG_LINE;
  seg->x[0] = canvas_coord(x);
  seg->x[1] = canvas_coord(y);
  c->cur_x = seg->x[0];
  c->cur_y = seg->x[1];
}

/** Draws a text run into the canvas at (x, baseline) in canvas user space. */
static void canvas_draw_run(Canvas *c, const uint8_t *text, size_t n, double x, double baseline,
                            double max_width, int stroke) {
  ID2D1DeviceContext *dc = canvas_begin(c);
  if (!dc) return;
  double width = host_measure_text(text, n, c->font_size, c->font_weight, 0, 0);
  double scale_x = max_width > 0 && width > max_width ? max_width / width : 1;
  D2D1_MATRIX_3X2_F m = c->m;
  if (scale_x != 1) {
    D2D1::Matrix3x2F squash = D2D1::Matrix3x2F::Translation((FLOAT)x, 0) *
                              D2D1::Matrix3x2F::Scale((FLOAT)scale_x, 1.0f) *
                              D2D1::Matrix3x2F::Translation((FLOAT)-x, 0);
    m = matrix_product(m, squash);
  }
  int pushed = canvas_enter(c);
  dc->SetTransform(m);
  ID2D1Brush *brush = canvas_brush_under_transform(c, stroke ? c->stroke_kind : c->fill_kind,
                                                   stroke ? c->stroke : c->fill,
                                                   stroke ? c->stroke_def : c->fill_def);
  if (brush) {
    if (stroke) {
      // A stroked run is its outlines: the glyphs are turned into one geometry, at the origin,
      // and drawn where the run sits.
      FontPick pick = pick_font(c->font_weight);
      int count = 0;
      for (size_t i = 0; i < n; i++) {
        unsigned char b = text[i];
        if (b < 0x80 || (b & 0xc0) != 0x80) count++;
      }
      if (pick.face && count > 0) {
        UINT16 *glyphs = (UINT16 *)malloc((size_t)count * sizeof(UINT16));
        FLOAT *advances = (FLOAT *)malloc((size_t)count * sizeof(FLOAT));
        DWRITE_GLYPH_OFFSET *offsets =
            (DWRITE_GLYPH_OFFSET *)calloc((size_t)count, sizeof(DWRITE_GLYPH_OFFSET));
        if (glyphs && advances && offsets) {
          size_t i = 0;
          int at = 0;
          uint32_t cp;
          while (at < count && utf8_next(text, n, &i, &cp)) {
            UINT16 glyph = glyph_of(pick.face, cp);
            DWRITE_GLYPH_METRICS gm;
            pick.face->GetDesignGlyphMetrics(&glyph, 1, &gm, FALSE);
            glyphs[at] = glyph;
            advances[at] =
                (FLOAT)((double)gm.advanceWidth * (c->font_size / em_of(&pick.metrics)));
            at++;
          }
          Geo g;
          geo_begin(&g, D2D1_FILL_MODE_WINDING);
          if (g.sink)
            pick.face->GetGlyphRunOutline((FLOAT)c->font_size, glyphs, advances, offsets, (UINT32)at,
                                          FALSE, FALSE, (IDWriteGeometrySink *)g.sink);
          ID2D1PathGeometry *path = geo_end(&g);
          if (path) {
            // The outlines are at the origin; `place` moves them to the run. A gradient's
            // definition is in bitmap pixels, so its brush takes the whole transform off, the
            // move included: taking off only the canvas's transform left the gradient a run's
            // worth of pixels away from the glyphs it painted.
            D2D1::Matrix3x2F place = D2D1::Matrix3x2F::Translation((FLOAT)x, (FLOAT)baseline);
            D2D1_MATRIX_3X2_F full = matrix_product(m, place);
            dc->SetTransform(full);
            if (brush && c->stroke_kind == 1) {
              D2D1::Matrix3x2F inv(full._11, full._12, full._21, full._22, full._31, full._32);
              if (inv.Invert()) brush->SetTransform(inv);
            }
            dc->DrawGeometry(path, brush, (FLOAT)c->line_width, canvas_stroke_style(c));
            path->Release();
          }
        }
        free(glyphs);
        free(advances);
        free(offsets);
      }
    } else {
      draw_glyphs(dc, text, n, x, baseline, c->font_size, c->font_weight, 0, 0, brush);
    }
    brush->Release();
  }
  canvas_leave(c);
  dc->SetTransform(D2D1::IdentityMatrix());
  (void)pushed;
}

extern "C" {

int32_t host_canvas_create(double w, double h) {
  if (g_canvas_count >= MAX_CANVASES || !ensure_device()) return -1;
  Canvas *c = (Canvas *)calloc(1, sizeof(Canvas));
  if (!c) return -1;
  int id = g_canvas_count;
  g_canvases[id] = c;
  g_canvas_count++;
  if (!canvas_make_bitmap(c, w, h)) {
    // A bitmap that can't be made is still a canvas the page can draw into: it stays empty.
    c->w = w > 0 ? w : 0;
    c->h = h > 0 ? h : 0;
    canvas_reset_state(c);
  }
  return id;
}

void host_canvas_resize(int32_t id, double w, double h) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  if (c->gl) {
    // The drawing buffer follows the element, and the bitmap follows the buffer.
    gl_resize_canvas(id, w, h);
    return;
  }
  for (int i = 0; i < c->clip_count; i++) {
    if (c->clips[i]) c->clips[i]->Release();
    c->clips[i] = NULL;
  }
  c->clip_count = 0;
  canvas_make_bitmap(c, w, h);
}

void host_canvas_save(int32_t id) {
  Canvas *c = canvas_at(id);
  if (!c || c->stack_depth >= CANVAS_MAX_STACK) return;
  c->stack[c->stack_depth].m = c->m;
  c->stack[c->stack_depth].clip_count = c->clip_count;
  c->stack_depth++;
}

void host_canvas_restore(int32_t id) {
  Canvas *c = canvas_at(id);
  if (!c || c->stack_depth <= 0) return;
  c->stack_depth--;
  c->m = c->stack[c->stack_depth].m;
  int keep = c->stack[c->stack_depth].clip_count;
  for (int i = keep; i < c->clip_count; i++) {
    if (c->clips[i]) c->clips[i]->Release();
    c->clips[i] = NULL;
  }
  c->clip_count = keep < c->clip_count ? keep : c->clip_count;
}

void host_canvas_set_transform(int32_t id, double a, double b, double cc, double d, double e, double f) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  c->m = D2D1::Matrix3x2F((FLOAT)a, (FLOAT)b, (FLOAT)cc, (FLOAT)d, (FLOAT)e, (FLOAT)f);
}

void host_canvas_set_alpha(int32_t id, double alpha) {
  Canvas *c = canvas_at(id);
  if (c) c->alpha = alpha < 0 ? 0 : alpha > 1 ? 1 : alpha;
}

void host_canvas_set_composite(int32_t id, int32_t mode) {
  Canvas *c = canvas_at(id);
  if (c) c->composite = mode;
}

void host_canvas_set_line_width(int32_t id, double width) {
  Canvas *c = canvas_at(id);
  if (c) c->line_width = width;
}

void host_canvas_set_line_cap(int32_t id, int32_t cap) {
  Canvas *c = canvas_at(id);
  if (c) c->cap = cap;
}

void host_canvas_set_line_join(int32_t id, int32_t join) {
  Canvas *c = canvas_at(id);
  if (c) c->join = join;
}

void host_canvas_set_fill_color(int32_t id, uint32_t color) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  c->fill = color;
  c->fill_kind = 0;
}

void host_canvas_set_stroke_color(int32_t id, uint32_t color) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  c->stroke = color;
  c->stroke_kind = 0;
}

void host_canvas_set_fill_gradient(int32_t id, const uint8_t *def, size_t n) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  free(c->fill_def);
  c->fill_def = (char *)malloc(n + 1);
  if (!c->fill_def) return;
  memcpy(c->fill_def, def, n);
  c->fill_def[n] = '\0';
  c->fill_kind = 1;
}

void host_canvas_set_stroke_gradient(int32_t id, const uint8_t *def, size_t n) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  free(c->stroke_def);
  c->stroke_def = (char *)malloc(n + 1);
  if (!c->stroke_def) return;
  memcpy(c->stroke_def, def, n);
  c->stroke_def[n] = '\0';
  c->stroke_kind = 1;
}

/** The dash pattern comes as text, "<offset> <d0> <d1> ...", in canvas units. */
void host_canvas_set_line_dash(int32_t id, const uint8_t *dashes, size_t n) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  char text[512];
  if (!copy_name_bytes(text, sizeof(text), dashes, n)) return;
  char *p = text;
  char *end = NULL;
  c->dash_offset = strtod(p, &end);
  p = end;
  c->dash_count = 0;
  while (*p && c->dash_count < CANVAS_MAX_DASH) {
    double v = strtod(p, &end);
    if (end == p) break;
    c->dashes[c->dash_count++] = (FLOAT)v;
    p = end;
  }
}

void host_canvas_set_font(int32_t id, double size, double weight) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  c->font_size = size > 0 ? size : 10;
  c->font_weight = weight;
}

/** A canvas filter chain is kept in the runtime; this host draws the operations unfiltered. */
void host_canvas_set_filter(int32_t id, const uint8_t *def, size_t n) {
  (void)id;
  (void)def;
  (void)n;
}

void host_canvas_begin_path(int32_t id) {
  Canvas *c = canvas_at(id);
  if (c) {
    c->seg_count = 0;
    c->has_cur = 0;
  }
}

void host_canvas_move_to(int32_t id, double x, double y) {
  Canvas *c = canvas_at(id);
  if (c) canvas_move(c, x, y);
}

void host_canvas_line_to(int32_t id, double x, double y) {
  Canvas *c = canvas_at(id);
  if (c) canvas_line(c, x, y);
}

void host_canvas_quadratic_to(int32_t id, double cx, double cy, double x, double y) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  double px, py, qx, qy, ex, ey;
  if (!c->has_cur) canvas_move(c, cx, cy);
  canvas_point(c, c->cur_x, c->cur_y, &px, &py);
  canvas_point(c, cx, cy, &qx, &qy);
  canvas_point(c, x, y, &ex, &ey);
  // A quadratic as the cubic it is equal to, in bitmap pixels.
  canvas_cubic_in_place(c, px + (qx - px) * 2.0 / 3.0, py + (qy - py) * 2.0 / 3.0,
                        ex + (qx - ex) * 2.0 / 3.0, ey + (qy - ey) * 2.0 / 3.0, ex, ey);
}

void host_canvas_bezier_to(int32_t id, double c1x, double c1y, double c2x, double c2y, double x, double y) {
  Canvas *c = canvas_at(id);
  if (c) canvas_cubic(c, c1x, c1y, c2x, c2y, x, y);
}

void host_canvas_close_path(int32_t id) {
  Canvas *c = canvas_at(id);
  if (!c || !c->has_cur) return;
  canvas_line_in_place(c, c->segs[0].x[0], c->segs[0].x[1]);
}

void host_canvas_arc(int32_t id, double cx, double cy, double r, double start, double end, int32_t ccw) {
  Canvas *c = canvas_at(id);
  if (!c || !(r > 0)) return;
  canvas_line(c, cx + r * cos(start), cy + r * sin(start));
  canvas_arc_points(c, cx, cy, r, r, start, end, ccw);
}

void host_canvas_arc_to(int32_t id, double x1, double y1, double x2, double y2, double r) {
  Canvas *c = canvas_at(id);
  if (c) canvas_arc_to_points(c, x1, y1, x2, y2, r);
}

void host_canvas_rect(int32_t id, double x, double y, double w, double h) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  canvas_move(c, x, y);
  canvas_line(c, x + w, y);
  canvas_line(c, x + w, y + h);
  canvas_line(c, x, y + h);
  canvas_line(c, x, y);
}

void host_canvas_fill(int32_t id, int32_t rule) {
  Canvas *c = canvas_at(id);
  if (!c || c->seg_count == 0) return;
  ID2D1DeviceContext *dc = canvas_begin(c);
  if (!dc) return;
  ID2D1PathGeometry *path = canvas_geometry(c, rule != 0 ? D2D1_FILL_MODE_ALTERNATE : D2D1_FILL_MODE_WINDING);
  if (!path) return;
  canvas_enter(c);
  ID2D1Brush *brush = canvas_brush(c, c->fill_kind, c->fill, c->fill_def);
  if (brush) {
    dc->FillGeometry(path, brush);
    brush->Release();
  }
  canvas_leave(c);
  path->Release();
}

void host_canvas_stroke(int32_t id) {
  Canvas *c = canvas_at(id);
  if (!c || c->seg_count == 0) return;
  ID2D1DeviceContext *dc = canvas_begin(c);
  if (!dc) return;
  ID2D1PathGeometry *path = canvas_geometry(c, D2D1_FILL_MODE_WINDING);
  if (!path) return;
  canvas_enter(c);
  ID2D1Brush *brush = canvas_brush(c, c->stroke_kind, c->stroke, c->stroke_def);
  ID2D1StrokeStyle *style = canvas_stroke_style(c);
  if (brush) {
    dc->DrawGeometry(path, brush, (FLOAT)(c->line_width * canvas_scale(c)), style);
    brush->Release();
  }
  if (style) style->Release();
  canvas_leave(c);
  path->Release();
}

void host_canvas_clip(int32_t id, int32_t rule) {
  Canvas *c = canvas_at(id);
  if (!c || c->seg_count == 0 || c->clip_count >= CANVAS_MAX_CLIPS) return;
  ID2D1PathGeometry *path =
      canvas_geometry(c, rule != 0 ? D2D1_FILL_MODE_ALTERNATE : D2D1_FILL_MODE_WINDING);
  if (!path) return;
  c->clips[c->clip_count++] = path;
}

void host_canvas_fill_rect(int32_t id, double x, double y, double w, double h) {
  Canvas *c = canvas_at(id);
  ID2D1DeviceContext *dc = c ? canvas_begin(c) : NULL;
  if (!dc) return;
  canvas_enter(c);
  dc->SetTransform(c->m);
  ID2D1Brush *brush = canvas_brush_under_transform(c, c->fill_kind, c->fill, c->fill_def);
  if (brush) {
    dc->FillRectangle(D2D1::RectF((FLOAT)x, (FLOAT)y, (FLOAT)(x + w), (FLOAT)(y + h)), brush);
    brush->Release();
  }
  dc->SetTransform(D2D1::IdentityMatrix());
  canvas_leave(c);
}

void host_canvas_stroke_rect(int32_t id, double x, double y, double w, double h) {
  Canvas *c = canvas_at(id);
  ID2D1DeviceContext *dc = c ? canvas_begin(c) : NULL;
  if (!dc) return;
  canvas_enter(c);
  dc->SetTransform(c->m);
  ID2D1Brush *brush = canvas_brush_under_transform(c, c->stroke_kind, c->stroke, c->stroke_def);
  ID2D1StrokeStyle *style = canvas_stroke_style(c);
  if (brush) {
    dc->DrawRectangle(D2D1::RectF((FLOAT)x, (FLOAT)y, (FLOAT)(x + w), (FLOAT)(y + h)), brush,
                      (FLOAT)c->line_width, style);
    brush->Release();
  }
  if (style) style->Release();
  dc->SetTransform(D2D1::IdentityMatrix());
  canvas_leave(c);
}

/** Clears a rect back to transparent black, whatever the fill style and alpha are. */
void host_canvas_clear_rect(int32_t id, double x, double y, double w, double h) {
  Canvas *c = canvas_at(id);
  ID2D1DeviceContext *dc = c ? canvas_begin(c) : NULL;
  if (!dc) return;
  canvas_enter(c);
  dc->SetTransform(c->m);
  dc->SetPrimitiveBlend(D2D1_PRIMITIVE_BLEND_COPY);
  ID2D1SolidColorBrush *clear = solid_brush_on(dc, 0x00000000u, 1);
  if (clear) {
    dc->FillRectangle(D2D1::RectF((FLOAT)x, (FLOAT)y, (FLOAT)(x + w), (FLOAT)(y + h)), clear);
    clear->Release();
  }
  // A clear always replaces its pixels; the canvas's own mode is back for the next operation.
  dc->SetPrimitiveBlend(canvas_blend(c->composite));
  dc->SetTransform(D2D1::IdentityMatrix());
  canvas_leave(c);
}

void host_canvas_fill_text(const uint8_t *text, size_t n, int32_t id, double x, double y, double max_width) {
  Canvas *c = canvas_at(id);
  if (c) canvas_draw_run(c, text, n, x, y, max_width, 0);
}

void host_canvas_stroke_text(const uint8_t *text, size_t n, int32_t id, double x, double y, double max_width) {
  Canvas *c = canvas_at(id);
  if (c) canvas_draw_run(c, text, n, x, y, max_width, 1);
}

/** A canvas in the page, as a display-list command painted when the frame is presented. */
void host_canvas_draw(int32_t id, double x, double y, double w, double h, double alpha, double smooth) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  canvas_flush(c);
  Cmd *cmd = push_cmd();
  cmd->kind = CMD_CANVAS;
  cmd->image = id;
  cmd->x = x;
  cmd->y = y;
  cmd->w = w;
  cmd->h = h;
  cmd->size = alpha;
  cmd->smooth = smooth > 0.5;
}

void host_canvas_draw_part(int32_t id, double x, double y, double w, double h, double sx, double sy,
                           double sw, double sh, double alpha, double smooth) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  canvas_flush(c);
  Cmd *cmd = push_cmd();
  cmd->kind = CMD_CANVAS;
  cmd->image = id;
  cmd->x = x;
  cmd->y = y;
  cmd->w = w;
  cmd->h = h;
  cmd->sx = sx;
  cmd->sy = sy;
  cmd->sw = sw;
  cmd->sh = sh;
  cmd->size = alpha;
  cmd->smooth = smooth > 0.5;
}

/** The canvas's own pixels, straight RGBA, as getImageData hands them over. */
void host_canvas_get_image_data(int32_t id, double sx, double sy, double sw, double sh, cb_t cb) {
  Canvas *c = canvas_at(id);
  if (!c || !c->bitmap || !(sw > 0) || !(sh > 0)) {
    cb(NULL, 0);
    return;
  }
  canvas_flush(c);
  int x0 = (int)floor(sx), y0 = (int)floor(sy);
  int w = (int)ceil(sw), h = (int)ceil(sh);
  if (x0 < 0) {
    w += x0;
    x0 = 0;
  }
  if (y0 < 0) {
    h += y0;
    y0 = 0;
  }
  if (x0 + w > (int)c->w) w = (int)c->w - x0;
  if (y0 + h > (int)c->h) h = (int)c->h - y0;
  if (w <= 0 || h <= 0) {
    cb(NULL, 0);
    return;
  }
  D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
      (D2D1_BITMAP_OPTIONS)(D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW),
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96.0f, 96.0f);
  ID2D1Bitmap1 *cpu = NULL;
  if (FAILED(c->dc->CreateBitmap(D2D1::SizeU((UINT32)c->w, (UINT32)c->h), NULL, 0, &props, &cpu)) || !cpu) {
    cb(NULL, 0);
    return;
  }
  D2D1_RECT_U region = {(UINT32)x0, (UINT32)y0, (UINT32)(x0 + w), (UINT32)(y0 + h)};
  D2D1_MAPPED_RECT mapped = {0};
  uint8_t *rgba = NULL;
  if (SUCCEEDED(cpu->CopyFromBitmap(NULL, c->bitmap, &region)) &&
      SUCCEEDED(cpu->Map(D2D1_MAP_OPTIONS_READ, &mapped))) {
    rgba = (uint8_t *)malloc((size_t)w * (size_t)h * 4);
    if (rgba) {
      for (int y = 0; y < h; y++) {
        const uint8_t *src = mapped.bits + (size_t)y * (size_t)mapped.pitch;
        uint8_t *dst = rgba + (size_t)y * (size_t)w * 4;
        for (int x = 0; x < w; x++) {
          unsigned a = src[x * 4 + 3];
          dst[x * 4 + 0] = a ? (uint8_t)(src[x * 4 + 2] * 255 / a) : 0;
          dst[x * 4 + 1] = a ? (uint8_t)(src[x * 4 + 1] * 255 / a) : 0;
          dst[x * 4 + 2] = a ? (uint8_t)(src[x * 4 + 0] * 255 / a) : 0;
          dst[x * 4 + 3] = (uint8_t)a;
        }
      }
    }
    cpu->Unmap();
  }
  cpu->Release();
  if (!rgba) {
    cb(NULL, 0);
    return;
  }
  cb(rgba, (size_t)w * (size_t)h * 4);
  free(rgba);
}

static int base64_value(int ch) {
  if (ch >= 'A' && ch <= 'Z') return ch - 'A';
  if (ch >= 'a' && ch <= 'z') return ch - 'a' + 26;
  if (ch >= '0' && ch <= '9') return ch - '0' + 52;
  if (ch == '+') return 62;
  if (ch == '/') return 63;
  return -1;
}

/** Draws a decoded image into a canvas bitmap: the source rect (image pixels) into the dest rect,
 *  under the canvas's transform, globalAlpha and composite mode. */
void host_canvas_draw_image(int32_t id, int32_t imageId, double dx, double dy, double dw, double dh,
                            double sx, double sy, double sw, double sh, double smooth) {
  Canvas *c = canvas_at(id);
  if (!c || !(dw > 0) || !(dh > 0) || !(sw > 0) || !(sh > 0)) return;
  if (imageId < 0 || imageId >= g_image_count || !g_images[imageId].bitmap) return;
  ID2D1DeviceContext *dc = canvas_begin(c);
  if (!dc) return;
  canvas_enter(c);
  dc->SetTransform(c->m);
  D2D1_RECT_F dest = D2D1::RectF((FLOAT)dx, (FLOAT)dy, (FLOAT)(dx + dw), (FLOAT)(dy + dh));
  D2D1_RECT_F src = D2D1::RectF((FLOAT)sx, (FLOAT)sy, (FLOAT)(sx + sw), (FLOAT)(sy + sh));
  dc->DrawBitmap(g_images[imageId].bitmap, &dest, (FLOAT)c->alpha,
                 smooth > 0.5 ? D2D1_INTERPOLATION_MODE_LINEAR : D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR,
                 &src);
  dc->SetTransform(D2D1::IdentityMatrix());
  canvas_leave(c);
}

/** Draws a canvas's bitmap into a canvas: the source rect (bitmap pixels) into the dest rect,
 *  under the destination's transform, globalAlpha and composite mode. */
void host_canvas_draw_canvas(int32_t id, int32_t sourceId, double dx, double dy, double dw, double dh,
                             double sx, double sy, double sw, double sh, double smooth) {
  Canvas *c = canvas_at(id);
  Canvas *src = canvas_at(sourceId);
  if (!c || !src || !src->bitmap) return;
  if (!(dw > 0) || !(dh > 0) || !(sw > 0) || !(sh > 0)) return;
  // Pixels still being drawn into the source are settled first, so the blit reads them.
  canvas_flush(src);
  ID2D1DeviceContext *dc = canvas_begin(c);
  if (!dc) return;
  ID2D1Bitmap *source = src->bitmap;
  ID2D1Bitmap1 *copy = NULL;
  if (src == c) {
    // A canvas drawn into itself reads the bitmap it had before the draw.
    D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
        D2D1_BITMAP_OPTIONS_NONE,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96.0f, 96.0f);
    if (SUCCEEDED(dc->CreateBitmap(D2D1::SizeU((UINT32)src->w, (UINT32)src->h), NULL, 0, &props, &copy)) &&
        copy && SUCCEEDED(copy->CopyFromBitmap(NULL, src->bitmap, NULL))) {
      source = copy;
    } else {
      if (copy) copy->Release();
      return;
    }
  }
  canvas_enter(c);
  dc->SetTransform(c->m);
  D2D1_RECT_F dest = D2D1::RectF((FLOAT)dx, (FLOAT)dy, (FLOAT)(dx + dw), (FLOAT)(dy + dh));
  D2D1_RECT_F srcRect = D2D1::RectF((FLOAT)sx, (FLOAT)sy, (FLOAT)(sx + sw), (FLOAT)(sy + sh));
  dc->DrawBitmap(source, &dest, (FLOAT)c->alpha,
                 smooth > 0.5 ? D2D1_INTERPOLATION_MODE_LINEAR : D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR,
                 &srcRect);
  dc->SetTransform(D2D1::IdentityMatrix());
  canvas_leave(c);
  if (copy) copy->Release();
}

/** Straight RGBA pixels written at a canvas offset, with every channel as given. */
void host_canvas_put_image_data(int32_t id, double dx, double dy, double w, double h,
                                const uint8_t *pixels, size_t n) {
  Canvas *c = canvas_at(id);
  if (!c || !c->bitmap || !(w > 0) || !(h > 0)) return;
  int pw = (int)w, ph = (int)h;
  // The bytes arrive base64'd, because an FFI call carries text.
  size_t bytes = (n / 4) * 3;
  uint8_t *raw = (uint8_t *)malloc(bytes ? bytes : 1);
  if (!raw) return;
  size_t at = 0;
  uint32_t acc = 0;
  int bits = 0;
  for (size_t i = 0; i < n && at < bytes; i++) {
    int v = base64_value(pixels[i]);
    if (v < 0) continue;
    acc = (acc << 6) | (uint32_t)v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      raw[at++] = (uint8_t)((acc >> bits) & 0xff);
    }
  }
  if (at < (size_t)pw * (size_t)ph * 4) {
    free(raw);
    return;
  }
  // Direct2D takes premultiplied BGRA; canvas pixels are straight RGBA.
  uint8_t *bgra = (uint8_t *)malloc((size_t)pw * (size_t)ph * 4);
  if (!bgra) {
    free(raw);
    return;
  }
  for (int y = 0; y < ph; y++) {
    for (int x = 0; x < pw; x++) {
      const uint8_t *p = raw + ((size_t)y * (size_t)pw + (size_t)x) * 4;
      uint8_t *o = bgra + ((size_t)y * (size_t)pw + (size_t)x) * 4;
      unsigned a = p[3];
      o[0] = (uint8_t)(p[2] * a / 255);
      o[1] = (uint8_t)(p[1] * a / 255);
      o[2] = (uint8_t)(p[0] * a / 255);
      o[3] = (uint8_t)a;
    }
  }
  free(raw);
  D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
      D2D1_BITMAP_OPTIONS_NONE,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96.0f, 96.0f);
  ID2D1Bitmap1 *src = NULL;
  ID2D1DeviceContext *dc = canvas_begin(c);
  if (dc &&
      SUCCEEDED(dc->CreateBitmap(D2D1::SizeU((UINT32)pw, (UINT32)ph), bgra, (UINT32)pw * 4, &props, &src)) &&
      src) {
    dc->SetTransform(D2D1::IdentityMatrix());
    dc->SetPrimitiveBlend(D2D1_PRIMITIVE_BLEND_COPY);
    // putImageData is unaffected by the transform, alpha or composite in effect.
    D2D1_RECT_F dest = D2D1::RectF((FLOAT)dx, (FLOAT)dy, (FLOAT)(dx + pw), (FLOAT)(dy + ph));
    dc->DrawBitmap(src, &dest, 1.0f, D2D1_INTERPOLATION_MODE_NEAREST_NEIGHBOR, NULL);
    dc->SetPrimitiveBlend(D2D1_PRIMITIVE_BLEND_SOURCE_OVER);
    src->Release();
  }
  free(bgra);
}

// ---------------------------------------------------------------------------
// Accessibility
//
// The runtime computes the page's accessibility tree from the DOM (runtime/a11y.ts and
// runtime/ax-tree.ts): each node's role as HTML-AAM and ARIA give it, the name accname computes,
// its value, states, frame and the actions it takes, as JSON. Here that tree becomes a UI
// Automation provider the window hands out on WM_GETOBJECT, with the control types, properties and
// patterns Core-AAM gives UIA, the way a browser's page reads to Narrator or to a client such as
// agent-desktop.
//
// Nothing is built until a client asks: the first WM_GETOBJECT for the UIA root marks the tree
// wanted, and the runtime builds it from the next frame on. UIA calls the provider on its own
// threads, so a client's first walk waits there, briefly, for that first tree, instead of finding
// an empty window.
//
// A provider names its node by the node's uid, which the same DOM element keeps from one tree to the
// next, so an element a client holds stays live while the page changes. A client's action — invoke,
// toggle, a value written, a selection — is queued for the runtime, which runs it on the element
// itself (EV_AXACTION) and the page hears the events a user's input would send.

/** The actions a node takes, as AxNode.actions carries them (runtime/ax-tree.ts). */
enum {
  AXA_PRESS = 1, AXA_FOCUS = 2, AXA_SET_VALUE = 4, AXA_INSERT_TEXT = 8, AXA_INCREMENT = 16,
  AXA_SHOW_MENU = 32,
};
/** The action kinds EV_AXACTION carries, as runtime/host.ts has them. */
enum {
  AX_PRESS = 1, AX_FOCUS = 2, AX_SET_VALUE = 3, AX_INSERT_TEXT = 4, AX_SELECT_RANGE = 5,
  AX_INCREMENT = 6, AX_DECREMENT = 7, AX_SHOW_MENU = 8, AX_SCROLL_INTO_VIEW = 9,
};

/** The uid the document node answers to: the page itself, the window's one child. */
static const int AX_DOCUMENT = 0;
/** The uid the window's own provider answers to. */
static const int AX_WINDOW = INT32_MIN;

typedef struct {
  int id, parent, uid;
  char role[40];
  char *label, *value, *dom_id, *description, *placeholder, *url, *role_description;
  double x, y, w, h;
  int focusable, focused, disabled, checked, level;
  int expanded, selected, pressed, mixed, required, readonly, multiline, actions;
  double value_now, value_min, value_max;
  int has_now, has_min, has_max;
  int sel_start, sel_end;
} AxNode;

static AxNode *g_ax_nodes = NULL;
static int g_ax_count = 0;
static CRITICAL_SECTION g_ax_lock;
static int g_ax_lock_ready = 0;
static wchar_t g_ax_title[256] = L"native";
/** Whether a client has asked for the tree; the runtime builds none until one does. */
static volatile LONG g_ax_active = 0;
/** Set once the first tree has arrived, so a client's first walk can wait for it. */
static HANDLE g_ax_ready = NULL;
static volatile LONG g_ax_has_tree = 0;
/** The UI thread, which must never wait for the tree: it is the thread that builds it. */
static DWORD g_ax_ui_thread = 0;

/** One line per provider entry under NATIVE_DEBUG_NAV: what a client asked before it stopped. */
static void ax_trace(const char *what, int node, int arg) {
  if (getenv("NATIVE_DEBUG_NAV") == NULL) return;
  fprintf(stderr, "native: uia %s node=%d arg=%d\n", what, node, arg);
}

static void ax_lock(void) {
  if (g_ax_lock_ready) EnterCriticalSection(&g_ax_lock);
}

static void ax_unlock(void) {
  if (g_ax_lock_ready) LeaveCriticalSection(&g_ax_lock);
}

/** Marks the tree wanted: from the next frame on, the runtime builds it and keeps it current. */
static void ax_activate(void) {
  if (InterlockedExchange(&g_ax_active, 1) == 0 && g_hwnd) PostMessageW(g_hwnd, WM_NULL, 0, 0);
}

/** On a UIA thread, waits a little for the first tree once a client has asked for it; the UI
 *  thread, which builds it, never waits. */
static void ax_wait_for_tree(void) {
  ax_activate();
  if (g_ax_has_tree || !g_ax_ready || GetCurrentThreadId() == g_ax_ui_thread) return;
  WaitForSingleObject(g_ax_ready, 2000);
}

// --- The action queue: filled on UIA's threads, emptied by host_poll on the UI thread.

typedef struct {
  int kind, uid;
  char *text;
  double x, y;
} AxAction;

#define AX_ACTIONS 64
static AxAction g_ax_actions[AX_ACTIONS];
static int g_ax_action_read = 0, g_ax_action_write = 0;
/** The action EV_AXACTION carries now. */
static AxAction g_ax_action = {0, 0, NULL, 0, 0};

static void ax_queue(int kind, int uid, const char *text, double x, double y) {
  ax_lock();
  int next = (g_ax_action_write + 1) % AX_ACTIONS;
  if (next != g_ax_action_read) {
    AxAction *a = &g_ax_actions[g_ax_action_write];
    a->kind = kind;
    a->uid = uid;
    a->text = text ? dup_str(text) : NULL;
    a->x = x;
    a->y = y;
    g_ax_action_write = next;
  }
  ax_unlock();
  if (g_hwnd) PostMessageW(g_hwnd, WM_NULL, 0, 0);
}

/** Takes the oldest queued action into g_ax_action; false when there is none. */
static int ax_take_action(void) {
  int took = 0;
  ax_lock();
  if (g_ax_action_read != g_ax_action_write) {
    free(g_ax_action.text);
    g_ax_action = g_ax_actions[g_ax_action_read];
    g_ax_actions[g_ax_action_read].text = NULL;
    g_ax_action_read = (g_ax_action_read + 1) % AX_ACTIONS;
    // A text range's location and length ride in the event's x and y.
    g_event.x = g_ax_action.x;
    g_event.y = g_ax_action.y;
    took = 1;
  }
  ax_unlock();
  return took;
}

// --- The tree the runtime hands over.

/** The JSON values the tree is written with: strings, numbers and the true/false states. */
static const char *ax_json_string(const char *p, char **out) {
  size_t len = 0;
  p = json_read_string(p, out, &len);
  return p;
}

static const char *ax_json_number(const char *p, double *out) {
  char *end = NULL;
  *out = strtod(p, &end);
  return end == p ? p : end;
}

static void ax_free_node(AxNode *n) {
  free(n->label);
  free(n->value);
  free(n->dom_id);
  free(n->description);
  free(n->placeholder);
  free(n->url);
  free(n->role_description);
}

/** Reads the flat list of nodes the runtime hands over. */
static AxNode *ax_parse(const char *text, int *out_count) {
  AxNode *nodes = NULL;
  int count = 0, cap = 0;
  *out_count = 0;
  const char *p = json_skip_space(text);
  if (*p != '[') return NULL;
  p++;
  for (;;) {
    p = json_skip_space(p);
    if (*p != '{') break;
    p++;
    AxNode node;
    memset(&node, 0, sizeof(node));
    node.parent = -1;
    node.expanded = node.selected = node.pressed = -1;
    node.sel_start = node.sel_end = -1;
    for (;;) {
      p = json_skip_space(p);
      if (*p != '"') break;
      char *key = NULL;
      size_t key_len = 0;
      p = json_read_string(p, &key, &key_len);
      p = json_skip_space(p);
      if (*p == ':') p++;
      p = json_skip_space(p);
      if (key == NULL) break;
      if (*p == '"') {
        char *value = NULL;
        p = ax_json_string(p, &value);
        if (value) {
          char **slot = NULL;
          if (strcmp(key, "role") == 0) snprintf(node.role, sizeof(node.role), "%s", value);
          else if (strcmp(key, "label") == 0) slot = &node.label;
          else if (strcmp(key, "value") == 0) slot = &node.value;
          else if (strcmp(key, "domId") == 0) slot = &node.dom_id;
          else if (strcmp(key, "description") == 0) slot = &node.description;
          else if (strcmp(key, "placeholder") == 0) slot = &node.placeholder;
          else if (strcmp(key, "url") == 0) slot = &node.url;
          else if (strcmp(key, "roleDescription") == 0) slot = &node.role_description;
          if (slot != NULL && *slot == NULL && value[0] != 0) {
            *slot = value;
            value = NULL;
          }
          free(value);
        }
      } else if (strncmp(p, "null", 4) == 0) {
        // A number with no value (NaN) is null in the tree; the node keeps its default.
        p += 4;
      } else if (strncmp(p, "true", 4) == 0 || strncmp(p, "false", 5) == 0) {
        int truth = *p == 't';
        if (strcmp(key, "focusable") == 0) node.focusable = truth;
        else if (strcmp(key, "focused") == 0) node.focused = truth;
        else if (strcmp(key, "disabled") == 0) node.disabled = truth;
        else if (strcmp(key, "mixed") == 0) node.mixed = truth;
        else if (strcmp(key, "required") == 0) node.required = truth;
        else if (strcmp(key, "readonly") == 0) node.readonly = truth;
        else if (strcmp(key, "multiline") == 0) node.multiline = truth;
        p += truth ? 4 : 5;
      } else {
        double number = 0;
        p = ax_json_number(p, &number);
        if (strcmp(key, "id") == 0) node.id = (int)number;
        else if (strcmp(key, "parent") == 0) node.parent = (int)number;
        else if (strcmp(key, "uid") == 0) node.uid = (int)number;
        else if (strcmp(key, "x") == 0) node.x = number;
        else if (strcmp(key, "y") == 0) node.y = number;
        else if (strcmp(key, "w") == 0) node.w = number;
        else if (strcmp(key, "h") == 0) node.h = number;
        else if (strcmp(key, "checked") == 0) node.checked = (int)number;
        else if (strcmp(key, "level") == 0) node.level = (int)number;
        else if (strcmp(key, "expanded") == 0) node.expanded = (int)number;
        else if (strcmp(key, "selected") == 0) node.selected = (int)number;
        else if (strcmp(key, "pressed") == 0) node.pressed = (int)number;
        else if (strcmp(key, "actions") == 0) node.actions = (int)number;
        else if (strcmp(key, "valueNow") == 0) { node.value_now = number; node.has_now = 1; }
        else if (strcmp(key, "valueMin") == 0) { node.value_min = number; node.has_min = 1; }
        else if (strcmp(key, "valueMax") == 0) { node.value_max = number; node.has_max = 1; }
        else if (strcmp(key, "selStart") == 0) node.sel_start = (int)number;
        else if (strcmp(key, "selEnd") == 0) node.sel_end = (int)number;
        // A value the parser can't read skips to the next field rather than stopping the walk.
        while (*p && *p != ',' && *p != '}') p++;
      }
      free(key);
      p = json_skip_space(p);
      if (*p == ',') {
        p++;
        continue;
      }
      break;
    }
    p = json_skip_space(p);
    if (*p == '}') p++;
    if (count == cap) {
      int grown = cap ? cap * 2 : 64;
      AxNode *next = (AxNode *)realloc(nodes, (size_t)grown * sizeof(AxNode));
      if (!next) {
        ax_free_node(&node);
        break;
      }
      nodes = next;
      cap = grown;
    }
    nodes[count++] = node;
    p = json_skip_space(p);
    if (*p == ',') {
      p++;
      continue;
    }
    break;
  }
  *out_count = count;
  return nodes;
}

/** The index of the node with a uid in the current table, or -1; the caller holds the lock. */
static int ax_index_of(int uid) {
  for (int i = 0; i < g_ax_count; i++) if (g_ax_nodes[i].uid == uid) return i;
  return -1;
}

/** A node's text fields, copied out with it so the caller never holds the table. */
typedef struct {
  AxNode n;
  char label[1024], value[2048], dom_id[128], description[512], placeholder[256], url[1024],
    role_description[128];
  /** The role of the nearest ancestor that contains a selectable item, and its uid. */
  char container_role[40];
  int container_uid;
} AxCopy;

static void ax_copy_text(char *out, size_t cap, const char *s) { snprintf(out, cap, "%s", s ? s : ""); }

/** One node, copied out under the lock; false when the page no longer has it. */
static int ax_node_copy(int uid, AxCopy *out) {
  int found = 0;
  ax_lock();
  int i = ax_index_of(uid);
  if (i >= 0) {
    AxNode *n = &g_ax_nodes[i];
    out->n = *n;
    ax_copy_text(out->label, sizeof out->label, n->label);
    ax_copy_text(out->value, sizeof out->value, n->value);
    ax_copy_text(out->dom_id, sizeof out->dom_id, n->dom_id);
    ax_copy_text(out->description, sizeof out->description, n->description);
    ax_copy_text(out->placeholder, sizeof out->placeholder, n->placeholder);
    ax_copy_text(out->url, sizeof out->url, n->url);
    ax_copy_text(out->role_description, sizeof out->role_description, n->role_description);
    out->container_role[0] = 0;
    out->container_uid = AX_DOCUMENT;
    for (int p = n->parent; p > 0 && p <= g_ax_count;) {
      AxNode *up = &g_ax_nodes[p - 1];
      const char *r = up->role;
      if (strcmp(r, "radiogroup") == 0 || strcmp(r, "tablist") == 0 || strcmp(r, "listbox") == 0 ||
          strcmp(r, "tree") == 0 || strcmp(r, "grid") == 0 || strcmp(r, "treegrid") == 0 ||
          strcmp(r, "combobox") == 0 || strcmp(r, "menu") == 0) {
        snprintf(out->container_role, sizeof out->container_role, "%s", r);
        out->container_uid = up->uid;
        break;
      }
      p = up->parent;
    }
    found = 1;
  }
  ax_unlock();
  return found;
}

/** A BSTR of UTF-8 text. */
static BSTR ax_bstr(const char *s) {
  size_t len = 0;
  wchar_t *wide = utf8_to_utf16((const uint8_t *)s, strlen(s), &len);
  BSTR out = SysAllocStringLen(wide ? wide : L"", (UINT)len);
  free(wide);
  return out;
}

/** UTF-16 text back to UTF-8, for an action's text. */
static char *ax_utf8(const wchar_t *s) {
  if (!s) return dup_str("");
  int n = WideCharToMultiByte(CP_UTF8, 0, s, -1, NULL, 0, NULL, NULL);
  char *out = (char *)malloc(n > 0 ? (size_t)n : 1);
  if (!out) return NULL;
  if (n <= 0) out[0] = 0;
  else WideCharToMultiByte(CP_UTF8, 0, s, -1, out, n, NULL, NULL);
  return out;
}

static int ax_is(const char *role, const char *a) { return strcmp(role, a) == 0; }

/** The UIA control type a page role answers with, as Core-AAM maps it. */
static CONTROLTYPEID ax_control_type(const AxNode *n) {
  const char *role = n->role;
  if (ax_is(role, "button")) return UIA_ButtonControlTypeId;
  if (ax_is(role, "switch")) return UIA_ButtonControlTypeId;
  if (ax_is(role, "link")) return UIA_HyperlinkControlTypeId;
  if (ax_is(role, "textbox") || ax_is(role, "searchbox")) return UIA_EditControlTypeId;
  if (ax_is(role, "checkbox")) return UIA_CheckBoxControlTypeId;
  if (ax_is(role, "radio")) return UIA_RadioButtonControlTypeId;
  if (ax_is(role, "combobox")) return UIA_ComboBoxControlTypeId;
  if (ax_is(role, "listbox") || ax_is(role, "list")) return UIA_ListControlTypeId;
  if (ax_is(role, "listitem") || ax_is(role, "option")) return UIA_ListItemControlTypeId;
  if (ax_is(role, "heading")) return UIA_TextControlTypeId;
  if (ax_is(role, "staticText")) return UIA_TextControlTypeId;
  if (ax_is(role, "img") || ax_is(role, "image")) return UIA_ImageControlTypeId;
  if (ax_is(role, "table")) return UIA_TableControlTypeId;
  if (ax_is(role, "grid") || ax_is(role, "treegrid")) return UIA_DataGridControlTypeId;
  if (ax_is(role, "row")) return UIA_DataItemControlTypeId;
  if (ax_is(role, "cell") || ax_is(role, "gridcell")) return UIA_DataItemControlTypeId;
  if (ax_is(role, "columnheader") || ax_is(role, "rowheader")) return UIA_HeaderItemControlTypeId;
  if (ax_is(role, "slider")) return UIA_SliderControlTypeId;
  if (ax_is(role, "spinbutton")) return UIA_SpinnerControlTypeId;
  if (ax_is(role, "progressbar") || ax_is(role, "meter")) return UIA_ProgressBarControlTypeId;
  if (ax_is(role, "scrollbar")) return UIA_ScrollBarControlTypeId;
  if (ax_is(role, "separator")) return UIA_SeparatorControlTypeId;
  if (ax_is(role, "menubar")) return UIA_MenuBarControlTypeId;
  if (ax_is(role, "menu")) return UIA_MenuControlTypeId;
  if (ax_is(role, "menuitem") || ax_is(role, "menuitemcheckbox") || ax_is(role, "menuitemradio"))
    return UIA_MenuItemControlTypeId;
  if (ax_is(role, "tablist")) return UIA_TabControlTypeId;
  if (ax_is(role, "tab")) return UIA_TabItemControlTypeId;
  if (ax_is(role, "tabpanel")) return UIA_PaneControlTypeId;
  if (ax_is(role, "toolbar")) return UIA_ToolBarControlTypeId;
  if (ax_is(role, "tooltip")) return UIA_ToolTipControlTypeId;
  if (ax_is(role, "tree")) return UIA_TreeControlTypeId;
  if (ax_is(role, "treeitem")) return UIA_TreeItemControlTypeId;
  if (ax_is(role, "radiogroup")) return UIA_GroupControlTypeId;
  if (ax_is(role, "dialog") || ax_is(role, "alertdialog")) return UIA_PaneControlTypeId;
  if (ax_is(role, "document") || ax_is(role, "article")) return UIA_DocumentControlTypeId;
  if (ax_is(role, "term") || ax_is(role, "definition") || ax_is(role, "status") ||
      ax_is(role, "alert") || ax_is(role, "timer") || ax_is(role, "marquee") || ax_is(role, "log"))
    return ax_is(role, "status") || ax_is(role, "alert") || ax_is(role, "log") || ax_is(role, "timer") ||
      ax_is(role, "marquee") ? UIA_GroupControlTypeId : UIA_TextControlTypeId;
  // Landmarks, regions, figures and generic boxes are groups; a landmark says which it is.
  return UIA_GroupControlTypeId;
}

/** The landmark type a landmark role reports, or 0. */
static int ax_landmark(const char *role) {
  if (ax_is(role, "main")) return UIA_MainLandmarkTypeId;
  if (ax_is(role, "navigation")) return UIA_NavigationLandmarkTypeId;
  if (ax_is(role, "form")) return UIA_FormLandmarkTypeId;
  if (ax_is(role, "search")) return UIA_SearchLandmarkTypeId;
  if (ax_is(role, "banner") || ax_is(role, "contentinfo") || ax_is(role, "complementary") ||
      ax_is(role, "region")) return UIA_CustomLandmarkTypeId;
  return 0;
}

/** The words a landmark without a UIA type of its own is called by, as a browser localizes them. */
static const char *ax_landmark_name(const char *role) {
  if (ax_is(role, "banner")) return "banner";
  if (ax_is(role, "contentinfo")) return "content information";
  if (ax_is(role, "complementary")) return "complementary";
  if (ax_is(role, "region")) return "region";
  return "";
}

/** Whether the node is a text field: Value and Text patterns, its caret and selection. */
static int ax_is_field(const AxNode *n) {
  return (n->actions & AXA_INSERT_TEXT) != 0 || ax_is(n->role, "textbox") || ax_is(n->role, "searchbox");
}

/** Whether the node toggles: a checkbox or switch, or a button with aria-pressed. */
static int ax_toggles(const AxNode *n) {
  return ax_is(n->role, "checkbox") || ax_is(n->role, "switch") || ax_is(n->role, "menuitemcheckbox") ||
    (ax_is(n->role, "button") && n->pressed >= 0);
}

/** Whether the node is an item a container selects: a radio, tab, option, tree item or row. */
static int ax_selectable(const AxNode *n) {
  return ax_is(n->role, "radio") || ax_is(n->role, "tab") || ax_is(n->role, "option") ||
    ax_is(n->role, "menuitemradio") ||
    ((ax_is(n->role, "treeitem") || ax_is(n->role, "row") || ax_is(n->role, "gridcell")) && n->selected >= 0);
}

static int ax_has_range(const AxNode *n) {
  return n->has_now && (ax_is(n->role, "slider") || ax_is(n->role, "spinbutton") ||
    ax_is(n->role, "progressbar") || ax_is(n->role, "meter") || ax_is(n->role, "scrollbar"));
}

static int ax_expands(const AxNode *n) {
  return n->expanded >= 0 || (ax_is(n->role, "combobox") && (n->actions & AXA_INSERT_TEXT) == 0);
}

/** The node's ToggleState. */
static ToggleState ax_toggle_state(const AxNode *n) {
  if (n->mixed || n->pressed == 2) return ToggleState_Indeterminate;
  if (n->pressed >= 0) return n->pressed == 1 ? ToggleState_On : ToggleState_Off;
  return n->checked == 1 ? ToggleState_On : ToggleState_Off;
}

/** Whether the node is selected: aria-selected, a chosen option, or a checked radio. */
static int ax_is_selected(const AxNode *n) {
  return n->selected == 1 || ((ax_is(n->role, "radio") || ax_is(n->role, "menuitemradio")) && n->checked == 1);
}

/** The ARIA properties a client reads from AriaProperties, as "name=value;..." (UIA's form). */
static void ax_aria_properties(const AxNode *n, char *out, size_t cap) {
  out[0] = 0;
  size_t at = 0;
  #define AX_PROP(...) do { int k = snprintf(out + at, at < cap ? cap - at : 0, __VA_ARGS__); if (k > 0) at += (size_t)k; } while (0)
  if (ax_toggles(n) && n->pressed < 0) AX_PROP("checked=%s;", n->mixed ? "mixed" : n->checked == 1 ? "true" : "false");
  if (n->pressed >= 0) AX_PROP("pressed=%s;", n->pressed == 2 ? "mixed" : n->pressed == 1 ? "true" : "false");
  if (n->expanded >= 0) AX_PROP("expanded=%s;", n->expanded == 1 ? "true" : "false");
  if (n->selected >= 0) AX_PROP("selected=%s;", n->selected == 1 ? "true" : "false");
  if (n->level > 0) AX_PROP("level=%d;", n->level);
  if (n->required) AX_PROP("required=true;");
  if (n->readonly) AX_PROP("readonly=true;");
  if (n->disabled) AX_PROP("disabled=true;");
  if (n->multiline) AX_PROP("multiline=true;");
  if (n->has_now) AX_PROP("valuenow=%g;", n->value_now);
  if (n->has_min) AX_PROP("valuemin=%g;", n->value_min);
  if (n->has_max) AX_PROP("valuemax=%g;", n->value_max);
  #undef AX_PROP
  if (at > 0 && at <= cap) out[at - 1] = 0;  // the last separator
}

/** A node's frame on the screen, in physical pixels. */
static UiaRect ax_screen_rect(double x, double y, double w, double h) {
  UiaRect r = {0, 0, 0, 0};
  if (!g_hwnd) return r;
  POINT origin = {0, 0};
  ClientToScreen(g_hwnd, &origin);
  // UIA speaks physical screen pixels; the tree's frames are CSS pixels of the view.
  r.left = origin.x + x * g_scale;
  r.top = origin.y + y * g_scale;
  r.width = w * g_scale;
  r.height = h * g_scale;
  return r;
}

class AxProvider;
static AxProvider *ax_provider(int uid);
static IRawElementProviderSimple *ax_simple(int uid);

// --- Text: a field's text as a UIA text range, by character offsets into its value.

class AxTextRange : public ITextRangeProvider {
 public:
  AxTextRange(int uid, int start, int end) : refs_(1), uid_(uid), start_(start), end_(end) {}
  virtual ~AxTextRange() {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
    if (!out) return E_POINTER;
    if (IsEqualIID(iid, __uuidof(IMarshal)) && g_ax_marshaler) return g_ax_marshaler->QueryInterface(iid, out);
    if (IsEqualIID(iid, __uuidof(IUnknown)) || IsEqualIID(iid, __uuidof(ITextRangeProvider))) {
      *out = static_cast<ITextRangeProvider *>(this);
      AddRef();
      return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return (ULONG)InterlockedIncrement(&refs_); }
  ULONG STDMETHODCALLTYPE Release() override {
    LONG left = InterlockedDecrement(&refs_);
    if (left == 0) delete this;
    return (ULONG)left;
  }

  /** The field's text as UTF-16, which is what offsets count. */
  wchar_t *text(int *len) {
    AxCopy c;
    *len = 0;
    if (!ax_node_copy(uid_, &c)) return NULL;
    size_t n = 0;
    wchar_t *w = utf8_to_utf16((const uint8_t *)c.value, strlen(c.value), &n);
    *len = (int)n;
    return w;
  }
  void clamp(int len) {
    if (start_ < 0) start_ = 0;
    if (start_ > len) start_ = len;
    if (end_ < start_) end_ = start_;
    if (end_ > len) end_ = len;
  }

  HRESULT STDMETHODCALLTYPE Clone(ITextRangeProvider **out) override {
    if (!out) return E_POINTER;
    *out = new AxTextRange(uid_, start_, end_);
    return *out ? S_OK : E_OUTOFMEMORY;
  }
  HRESULT STDMETHODCALLTYPE Compare(ITextRangeProvider *other, BOOL *out) override {
    if (!out || !other) return E_INVALIDARG;
    AxTextRange *o = static_cast<AxTextRange *>(other);
    *out = o->uid_ == uid_ && o->start_ == start_ && o->end_ == end_;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE CompareEndpoints(TextPatternRangeEndpoint end, ITextRangeProvider *other,
                                             TextPatternRangeEndpoint target, int *out) override {
    if (!out || !other) return E_INVALIDARG;
    AxTextRange *o = static_cast<AxTextRange *>(other);
    int a = end == TextPatternRangeEndpoint_Start ? start_ : end_;
    int b = target == TextPatternRangeEndpoint_Start ? o->start_ : o->end_;
    *out = a - b;
    return S_OK;
  }
  /** The unit boundaries around an offset: a character, a word, a line, or the whole text. */
  static void unit_at(const wchar_t *s, int len, int at, TextUnit unit, int *from, int *to) {
    if (unit == TextUnit_Character || unit == TextUnit_Format) {
      *from = at < len ? at : len;
      *to = at < len ? at + 1 : len;
      return;
    }
    if (unit == TextUnit_Word) {
      int a = at, b = at;
      while (a > 0 && !iswspace(s[a - 1])) a--;
      while (b < len && !iswspace(s[b])) b++;
      while (b < len && iswspace(s[b])) b++;
      *from = a;
      *to = b;
      return;
    }
    if (unit == TextUnit_Line || unit == TextUnit_Paragraph) {
      int a = at, b = at;
      while (a > 0 && s[a - 1] != L'\n') a--;
      while (b < len && s[b] != L'\n') b++;
      if (b < len) b++;
      *from = a;
      *to = b;
      return;
    }
    *from = 0;
    *to = len;
  }
  HRESULT STDMETHODCALLTYPE ExpandToEnclosingUnit(TextUnit unit) override {
    int len = 0;
    wchar_t *s = text(&len);
    clamp(len);
    int from = 0, to = len;
    unit_at(s ? s : L"", len, start_, unit, &from, &to);
    start_ = from;
    if (unit == TextUnit_Character || unit == TextUnit_Format) end_ = to;
    else if (end_ <= to) end_ = to;
    else {
      int f2 = 0, t2 = len;
      unit_at(s ? s : L"", len, end_ > start_ ? end_ - 1 : end_, unit, &f2, &t2);
      end_ = t2;
    }
    free(s);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE FindAttribute(TEXTATTRIBUTEID, VARIANT, BOOL, ITextRangeProvider **out) override {
    if (!out) return E_POINTER;
    *out = NULL;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE FindText(BSTR want, BOOL backward, BOOL ignore_case, ITextRangeProvider **out) override {
    if (!out) return E_POINTER;
    *out = NULL;
    int len = 0;
    wchar_t *s = text(&len);
    if (!s || !want) {
      free(s);
      return S_OK;
    }
    clamp(len);
    int n = (int)SysStringLen(want);
    int first = start_, last = end_ - n;
    for (int k = 0; k <= last - first; k++) {
      int at = backward ? last - k : first + k;
      int same = 1;
      for (int j = 0; j < n && same; j++) {
        wchar_t a = s[at + j], b = want[j];
        if (ignore_case) { a = towlower(a); b = towlower(b); }
        same = a == b;
      }
      if (same) {
        *out = new AxTextRange(uid_, at, at + n);
        break;
      }
    }
    free(s);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetAttributeValue(TEXTATTRIBUTEID id, VARIANT *out) override {
    if (!out) return E_POINTER;
    VariantInit(out);
    if (id == UIA_IsReadOnlyAttributeId) {
      AxCopy c;
      out->vt = VT_BOOL;
      out->boolVal = ax_node_copy(uid_, &c) && (c.n.actions & AXA_SET_VALUE) ? VARIANT_FALSE : VARIANT_TRUE;
      return S_OK;
    }
    IUnknown *unsupported = NULL;
    UiaGetReservedNotSupportedValue(&unsupported);
    out->vt = VT_UNKNOWN;
    out->punkVal = unsupported;
    return S_OK;
  }
  /** The field's box: the text is measured by the runtime, so a range reports the field's frame. */
  HRESULT STDMETHODCALLTYPE GetBoundingRectangles(SAFEARRAY **out) override {
    if (!out) return E_POINTER;
    AxCopy c;
    *out = SafeArrayCreateVector(VT_R8, 0, 4);
    if (!*out) return E_OUTOFMEMORY;
    if (!ax_node_copy(uid_, &c)) return S_OK;
    UiaRect r = ax_screen_rect(c.n.x, c.n.y, c.n.w, c.n.h);
    double v[4] = {r.left, r.top, r.width, r.height};
    for (LONG i = 0; i < 4; i++) SafeArrayPutElement(*out, &i, &v[i]);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetEnclosingElement(IRawElementProviderSimple **out) override {
    if (!out) return E_POINTER;
    *out = ax_simple(uid_);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetText(int max, BSTR *out) override {
    if (!out) return E_POINTER;
    int len = 0;
    wchar_t *s = text(&len);
    clamp(len);
    int n = end_ - start_;
    if (max >= 0 && n > max) n = max;
    *out = SysAllocStringLen(s ? s + start_ : L"", (UINT)(s ? n : 0));
    free(s);
    return S_OK;
  }
  /** Moves one endpoint by `count` units, returning how many it moved. */
  int move_endpoint(const wchar_t *s, int len, int *at, TextUnit unit, int count) {
    int moved = 0;
    while (count > 0 && *at < len) {
      int from = 0, to = len;
      unit_at(s, len, *at, unit, &from, &to);
      *at = to > *at ? to : *at + 1;
      count--;
      moved++;
    }
    while (count < 0 && *at > 0) {
      int from = 0, to = len;
      unit_at(s, len, *at - 1, unit, &from, &to);
      *at = from < *at ? from : *at - 1;
      count++;
      moved--;
    }
    return moved;
  }
  HRESULT STDMETHODCALLTYPE Move(TextUnit unit, int count, int *out) override {
    int len = 0;
    wchar_t *s = text(&len);
    clamp(len);
    bool degenerate = start_ == end_;
    int moved = move_endpoint(s ? s : L"", len, &start_, unit, count);
    if (degenerate) end_ = start_;
    else {
      int from = 0, to = len;
      unit_at(s ? s : L"", len, start_, unit, &from, &to);
      end_ = to;
    }
    free(s);
    if (out) *out = moved;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE MoveEndpointByUnit(TextPatternRangeEndpoint end, TextUnit unit, int count, int *out) override {
    int len = 0;
    wchar_t *s = text(&len);
    clamp(len);
    int *at = end == TextPatternRangeEndpoint_Start ? &start_ : &end_;
    int moved = move_endpoint(s ? s : L"", len, at, unit, count);
    if (start_ > end_) {
      if (end == TextPatternRangeEndpoint_Start) end_ = start_;
      else start_ = end_;
    }
    free(s);
    if (out) *out = moved;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE MoveEndpointByRange(TextPatternRangeEndpoint end, ITextRangeProvider *other,
                                                TextPatternRangeEndpoint target) override {
    if (!other) return E_INVALIDARG;
    AxTextRange *o = static_cast<AxTextRange *>(other);
    int to = target == TextPatternRangeEndpoint_Start ? o->start_ : o->end_;
    if (end == TextPatternRangeEndpoint_Start) {
      start_ = to;
      if (end_ < start_) end_ = start_;
    } else {
      end_ = to;
      if (start_ > end_) start_ = end_;
    }
    return S_OK;
  }
  /** Puts the field's selection on the range, as a client's caret move does. */
  HRESULT STDMETHODCALLTYPE Select() override {
    ax_queue(AX_SELECT_RANGE, uid_, NULL, start_, end_ - start_);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE AddToSelection() override { return UIA_E_INVALIDOPERATION; }
  HRESULT STDMETHODCALLTYPE RemoveFromSelection() override { return UIA_E_INVALIDOPERATION; }
  HRESULT STDMETHODCALLTYPE ScrollIntoView(BOOL) override {
    ax_queue(AX_SCROLL_INTO_VIEW, uid_, NULL, 0, 0);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetChildren(SAFEARRAY **out) override {
    if (!out) return E_POINTER;
    *out = SafeArrayCreateVector(VT_UNKNOWN, 0, 0);
    return S_OK;
  }

 private:
  LONG refs_;
  int uid_;
  int start_, end_;
};

/** The provider for one node of the tree, for the page's document node (uid 0), or for the window
 *  (AX_WINDOW), which is the fragment root. Every pattern is the provider itself, answered only
 *  where the node has it. */
class AxProvider : public IRawElementProviderSimple,
                   public IRawElementProviderFragment,
                   public IRawElementProviderFragmentRoot,
                   public IInvokeProvider,
                   public IToggleProvider,
                   public IValueProvider,
                   public IRangeValueProvider,
                   public IExpandCollapseProvider,
                   public ISelectionItemProvider,
                   public IScrollItemProvider,
                   public ITextProvider {
 public:
  explicit AxProvider(int uid) : refs_(1), uid_(uid) {}
  virtual ~AxProvider() {}
  int uid() const { return uid_; }
  bool window() const { return uid_ == AX_WINDOW; }
  bool document() const { return uid_ == AX_DOCUMENT; }

  /** Whether the node has a pattern, as Core-AAM gives the role its patterns. */
  bool has_pattern(PATTERNID id, const AxNode *n) {
    switch (id) {
      case UIA_InvokePatternId:
        return (n->actions & AXA_PRESS) && !ax_toggles(n) && !ax_selectable(n) && !ax_expands(n);
      case UIA_TogglePatternId: return ax_toggles(n);
      case UIA_ValuePatternId:
        return ax_is_field(n) || ax_is(n->role, "link") || ax_is(n->role, "combobox") ||
          ((ax_is(n->role, "slider") || ax_is(n->role, "spinbutton")) && n->value != NULL);
      case UIA_RangeValuePatternId: return ax_has_range(n);
      case UIA_ExpandCollapsePatternId: return ax_expands(n);
      case UIA_SelectionItemPatternId: return ax_selectable(n);
      case UIA_ScrollItemPatternId: return true;
      case UIA_TextPatternId: return ax_is_field(n);
      default: return false;
    }
  }

  // IUnknown
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
    if (!out) return E_POINTER;
    *out = NULL;
    if (IsEqualIID(iid, __uuidof(IMarshal)) && g_ax_marshaler) return g_ax_marshaler->QueryInterface(iid, out);
    if (IsEqualIID(iid, __uuidof(IUnknown)) || IsEqualIID(iid, __uuidof(IRawElementProviderSimple)))
      *out = static_cast<IRawElementProviderSimple *>(this);
    else if (IsEqualIID(iid, __uuidof(IRawElementProviderFragment)))
      *out = static_cast<IRawElementProviderFragment *>(this);
    else if (IsEqualIID(iid, __uuidof(IRawElementProviderFragmentRoot)) && window())
      *out = static_cast<IRawElementProviderFragmentRoot *>(this);
    else if (!window() && !document()) {
      AxCopy c;
      if (!ax_node_copy(uid_, &c)) return E_NOINTERFACE;
      if (IsEqualIID(iid, __uuidof(IInvokeProvider)) && has_pattern(UIA_InvokePatternId, &c.n))
        *out = static_cast<IInvokeProvider *>(this);
      else if (IsEqualIID(iid, __uuidof(IToggleProvider)) && has_pattern(UIA_TogglePatternId, &c.n))
        *out = static_cast<IToggleProvider *>(this);
      else if (IsEqualIID(iid, __uuidof(IValueProvider)) && has_pattern(UIA_ValuePatternId, &c.n))
        *out = static_cast<IValueProvider *>(this);
      else if (IsEqualIID(iid, __uuidof(IRangeValueProvider)) && has_pattern(UIA_RangeValuePatternId, &c.n))
        *out = static_cast<IRangeValueProvider *>(this);
      else if (IsEqualIID(iid, __uuidof(IExpandCollapseProvider)) && has_pattern(UIA_ExpandCollapsePatternId, &c.n))
        *out = static_cast<IExpandCollapseProvider *>(this);
      else if (IsEqualIID(iid, __uuidof(ISelectionItemProvider)) && has_pattern(UIA_SelectionItemPatternId, &c.n))
        *out = static_cast<ISelectionItemProvider *>(this);
      else if (IsEqualIID(iid, __uuidof(IScrollItemProvider)))
        *out = static_cast<IScrollItemProvider *>(this);
      else if (IsEqualIID(iid, __uuidof(ITextProvider)) && has_pattern(UIA_TextPatternId, &c.n))
        *out = static_cast<ITextProvider *>(this);
    }
    if (*out == NULL) return E_NOINTERFACE;
    AddRef();
    return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return (ULONG)InterlockedIncrement(&refs_); }
  ULONG STDMETHODCALLTYPE Release() override {
    LONG left = InterlockedDecrement(&refs_);
    if (left == 0) delete this;
    return (ULONG)left;
  }

  // IRawElementProviderSimple
  HRESULT STDMETHODCALLTYPE get_ProviderOptions(ProviderOptions *out) override {
    if (!out) return E_POINTER;
    *out = (ProviderOptions)ProviderOptions_ServerSideProvider;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID id, IUnknown **out) override {
    ax_trace("pattern", uid_, (int)id);
    if (!out) return E_POINTER;
    *out = NULL;
    if (window() || document()) return S_OK;
    AxCopy c;
    if (!ax_node_copy(uid_, &c) || !has_pattern(id, &c.n)) return S_OK;
    IUnknown *pattern = NULL;
    switch (id) {
      case UIA_InvokePatternId: pattern = static_cast<IInvokeProvider *>(this); break;
      case UIA_TogglePatternId: pattern = static_cast<IToggleProvider *>(this); break;
      case UIA_ValuePatternId: pattern = static_cast<IValueProvider *>(this); break;
      case UIA_RangeValuePatternId: pattern = static_cast<IRangeValueProvider *>(this); break;
      case UIA_ExpandCollapsePatternId: pattern = static_cast<IExpandCollapseProvider *>(this); break;
      case UIA_SelectionItemPatternId: pattern = static_cast<ISelectionItemProvider *>(this); break;
      case UIA_ScrollItemPatternId: pattern = static_cast<IScrollItemProvider *>(this); break;
      case UIA_TextPatternId: pattern = static_cast<ITextProvider *>(this); break;
      default: break;
    }
    if (pattern) {
      pattern->AddRef();
      *out = pattern;
    }
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID id, VARIANT *out) override {
    ax_trace("property", uid_, (int)id);
    if (!out) return E_POINTER;
    VariantInit(out);
    if (id == UIA_ProcessIdPropertyId) {
      out->vt = VT_I4;
      out->lVal = (LONG)GetCurrentProcessId();
      return S_OK;
    }
    if (id == UIA_FrameworkIdPropertyId) {
      out->vt = VT_BSTR;
      out->bstrVal = SysAllocString(L"Native");
      return S_OK;
    }
    if (window() || document()) {
      if (id == UIA_NamePropertyId) {
        // The window's own title, which the host keeps current as the page's title changes: a
        // screen reader names the application and the page with it.
        wchar_t title[256];
        out->vt = VT_BSTR;
        out->bstrVal = SysAllocString(g_hwnd && GetWindowTextW(g_hwnd, title, 256) > 0 ? title : g_ax_title);
      } else if (id == UIA_ControlTypePropertyId) {
        out->vt = VT_I4;
        out->lVal = window() ? UIA_WindowControlTypeId : UIA_DocumentControlTypeId;
      } else if (id == UIA_IsKeyboardFocusablePropertyId) {
        out->vt = VT_BOOL;
        out->boolVal = VARIANT_TRUE;
      } else if (id == UIA_HasKeyboardFocusPropertyId && document()) {
        int any = 0;
        ax_lock();
        for (int i = 0; i < g_ax_count && !any; i++) any = g_ax_nodes[i].focused;
        ax_unlock();
        out->vt = VT_BOOL;
        out->boolVal = any || !g_hwnd || GetForegroundWindow() != g_hwnd ? VARIANT_FALSE : VARIANT_TRUE;
      } else if (id == UIA_IsEnabledPropertyId) {
        // The window and the page are there to be used, as a browser's document is.
        out->vt = VT_BOOL;
        out->boolVal = VARIANT_TRUE;
      } else if (id == UIA_IsOffscreenPropertyId) {
        out->vt = VT_BOOL;
        out->boolVal = VARIANT_FALSE;
      } else if (id == UIA_IsControlElementPropertyId || id == UIA_IsContentElementPropertyId) {
        out->vt = VT_BOOL;
        out->boolVal = VARIANT_TRUE;
      }
      return S_OK;
    }
    AxCopy c;
    if (!ax_node_copy(uid_, &c)) return S_OK;
    const AxNode *n = &c.n;
    switch (id) {
      case UIA_NamePropertyId:
        // A static text's words are its name, as a browser's text node reads.
        out->vt = VT_BSTR;
        out->bstrVal = ax_bstr(c.label);
        break;
      case UIA_ControlTypePropertyId:
        out->vt = VT_I4;
        out->lVal = (LONG)ax_control_type(n);
        break;
      case UIA_LocalizedControlTypePropertyId:
        if (c.role_description[0]) {
          out->vt = VT_BSTR;
          out->bstrVal = ax_bstr(c.role_description);
        } else if (ax_is(n->role, "heading")) {
          out->vt = VT_BSTR;
          out->bstrVal = SysAllocString(L"heading");
        } else if (ax_landmark(n->role) == UIA_CustomLandmarkTypeId) {
          out->vt = VT_BSTR;
          out->bstrVal = SysAllocString(L"landmark");
        }
        break;
      case UIA_AutomationIdPropertyId:
        // The element's id, as a browser's page reports it; an element without one has none.
        if (c.dom_id[0]) {
          out->vt = VT_BSTR;
          out->bstrVal = ax_bstr(c.dom_id);
        }
        break;
      case UIA_AriaRolePropertyId:
        out->vt = VT_BSTR;
        out->bstrVal = ax_bstr(ax_is(n->role, "staticText") ? "" : n->role);
        break;
      case UIA_AriaPropertiesPropertyId: {
        char props[512];
        ax_aria_properties(n, props, sizeof props);
        out->vt = VT_BSTR;
        out->bstrVal = ax_bstr(props);
        break;
      }
      case UIA_FullDescriptionPropertyId:
      case UIA_HelpTextPropertyId:
        if (c.description[0]) {
          out->vt = VT_BSTR;
          out->bstrVal = ax_bstr(c.description);
        }
        break;
      case UIA_LandmarkTypePropertyId:
        if (ax_landmark(n->role)) {
          out->vt = VT_I4;
          out->lVal = ax_landmark(n->role);
        }
        break;
      case UIA_LocalizedLandmarkTypePropertyId:
        if (ax_landmark(n->role) == UIA_CustomLandmarkTypeId) {
          out->vt = VT_BSTR;
          out->bstrVal = ax_bstr(ax_landmark_name(n->role));
        }
        break;
      case UIA_IsEnabledPropertyId:
        out->vt = VT_BOOL;
        out->boolVal = n->disabled ? VARIANT_FALSE : VARIANT_TRUE;
        break;
      case UIA_IsKeyboardFocusablePropertyId:
        out->vt = VT_BOOL;
        out->boolVal = n->focusable && !n->disabled ? VARIANT_TRUE : VARIANT_FALSE;
        break;
      case UIA_HasKeyboardFocusPropertyId:
        out->vt = VT_BOOL;
        out->boolVal = n->focused ? VARIANT_TRUE : VARIANT_FALSE;
        break;
      case UIA_IsRequiredForFormPropertyId:
        out->vt = VT_BOOL;
        out->boolVal = n->required ? VARIANT_TRUE : VARIANT_FALSE;
        break;
      case UIA_IsOffscreenPropertyId: {
        // Out of the view's box, or with no box at all.
        bool off = n->w <= 0 || n->h <= 0 || n->x + n->w <= 0 || n->y + n->h <= 0 ||
          (g_view_w > 0 && n->x >= g_view_w) || (g_view_h > 0 && n->y >= g_view_h);
        out->vt = VT_BOOL;
        out->boolVal = off ? VARIANT_TRUE : VARIANT_FALSE;
        break;
      }
      case UIA_IsControlElementPropertyId:
      case UIA_IsContentElementPropertyId:
        out->vt = VT_BOOL;
        out->boolVal = VARIANT_TRUE;
        break;
      case UIA_HeadingLevelPropertyId:
        if (ax_is(n->role, "heading") && n->level > 0 && n->level <= 9) {
          out->vt = VT_I4;
          out->lVal = 80051 + (n->level - 1);  // HeadingLevel1 is 80051
        }
        break;
      case UIA_LevelPropertyId:
        if (n->level > 0) {
          out->vt = VT_I4;
          out->lVal = n->level;
        }
        break;
      case UIA_ClassNamePropertyId:
        break;
      default:
        break;
    }
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(IRawElementProviderSimple **out) override {
    if (!out) return E_POINTER;
    *out = NULL;
    if (window() && g_ax_host) {
      g_ax_host->AddRef();
      *out = g_ax_host;
    }
    return S_OK;
  }

  // IRawElementProviderFragment
  HRESULT STDMETHODCALLTYPE Navigate(NavigateDirection direction, IRawElementProviderFragment **out) override {
    ax_trace("navigate", uid_, (int)direction);
    if (!out) return E_POINTER;
    *out = NULL;
    if (window()) {
      // The window holds the page, its document; a client's first walk is where the tree is wanted.
      if (direction == NavigateDirection_FirstChild || direction == NavigateDirection_LastChild) {
        ax_wait_for_tree();
        *out = static_cast<IRawElementProviderFragment *>(ax_provider(AX_DOCUMENT));
      }
      return S_OK;
    }
    int target = INT32_MIN + 1;  // none
    ax_lock();
    if (document()) {
      if (direction == NavigateDirection_Parent) target = AX_WINDOW;
      else if (direction == NavigateDirection_FirstChild || direction == NavigateDirection_LastChild) {
        for (int i = 0; i < g_ax_count; i++) {
          if (g_ax_nodes[i].parent > 0) continue;
          if (direction == NavigateDirection_FirstChild) { target = g_ax_nodes[i].uid; break; }
          target = g_ax_nodes[i].uid;
        }
      }
    } else {
      int index = ax_index_of(uid_);
      if (index >= 0) {
        int parent = g_ax_nodes[index].parent;
        int self_id = g_ax_nodes[index].id;
        if (direction == NavigateDirection_Parent) {
          target = parent > 0 && parent <= g_ax_count ? g_ax_nodes[parent - 1].uid : AX_DOCUMENT;
        } else if (direction == NavigateDirection_FirstChild || direction == NavigateDirection_LastChild) {
          for (int i = index + 1; i < g_ax_count; i++) {
            if (g_ax_nodes[i].parent != self_id) continue;
            if (direction == NavigateDirection_FirstChild) { target = g_ax_nodes[i].uid; break; }
            target = g_ax_nodes[i].uid;
          }
        } else {
          int step = direction == NavigateDirection_NextSibling ? 1 : -1;
          for (int i = index + step; i >= 0 && i < g_ax_count; i += step) {
            if (g_ax_nodes[i].parent == parent) {
              target = g_ax_nodes[i].uid;
              break;
            }
          }
        }
      }
    }
    ax_unlock();
    if (target == INT32_MIN + 1) return S_OK;
    *out = static_cast<IRawElementProviderFragment *>(ax_provider(target));
    return *out ? S_OK : E_OUTOFMEMORY;
  }

  HRESULT STDMETHODCALLTYPE GetRuntimeId(SAFEARRAY **out) override {
    if (!out) return E_POINTER;
    *out = NULL;
    // A node's runtime id is its uid after the append marker: the window is 0, the document 1, an
    // element its uid plus one, and a text run (whose uid is its owner's, negated) is set apart by
    // a high bit.
    SAFEARRAY *array = SafeArrayCreateVector(VT_I4, 0, 2);
    if (!array) return E_OUTOFMEMORY;
    LONG at = 0;
    int first = UiaAppendRuntimeId;
    int second = window() ? 0 : uid_ >= 0 ? uid_ + 1 : 0x40000000 | (-uid_);
    SafeArrayPutElement(array, &at, &first);
    at = 1;
    SafeArrayPutElement(array, &at, &second);
    *out = array;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE get_BoundingRectangle(UiaRect *out) override {
    if (!out) return E_POINTER;
    out->left = out->top = out->width = out->height = 0;
    if (window()) return S_OK;  // the host's window supplies its own
    if (document()) {
      *out = ax_screen_rect(0, 0, g_view_w, g_view_h);
      return S_OK;
    }
    AxCopy c;
    if (ax_node_copy(uid_, &c)) *out = ax_screen_rect(c.n.x, c.n.y, c.n.w, c.n.h);
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetEmbeddedFragmentRoots(SAFEARRAY **out) override {
    if (!out) return E_POINTER;
    *out = NULL;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE SetFocus() override {
    if (window() || document()) return S_OK;
    AxCopy c;
    if (!ax_node_copy(uid_, &c)) return UIA_E_ELEMENTNOTAVAILABLE;
    if (!(c.n.actions & AXA_FOCUS)) return UIA_E_INVALIDOPERATION;
    ax_queue(AX_FOCUS, uid_, NULL, 0, 0);
    // The node takes the focus now, so a client that reads the focused element back at once sees
    // the one it focused; the next tree confirms it.
    ax_lock();
    for (int i = 0; i < g_ax_count; i++) g_ax_nodes[i].focused = g_ax_nodes[i].uid == uid_;
    ax_unlock();
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE get_FragmentRoot(IRawElementProviderFragmentRoot **out) override {
    if (!out) return E_POINTER;
    *out = NULL;
    if (g_ax_root) {
      g_ax_root->AddRef();
      *out = g_ax_root;
    }
    return S_OK;
  }

  // IRawElementProviderFragmentRoot
  HRESULT STDMETHODCALLTYPE ElementProviderFromPoint(double x, double y, IRawElementProviderFragment **out) override {
    if (!out) return E_POINTER;
    *out = NULL;
    ax_wait_for_tree();
    POINT origin = {0, 0};
    if (g_hwnd) ClientToScreen(g_hwnd, &origin);
    double cx = (x - origin.x) / g_scale, cy = (y - origin.y) / g_scale;
    // The deepest node that holds the point; among siblings, the last, which paints on top.
    int best = AX_DOCUMENT;
    ax_lock();
    for (int i = 0; i < g_ax_count; i++) {
      AxNode *n = &g_ax_nodes[i];
      if (cx < n->x || cy < n->y || cx >= n->x + n->w || cy >= n->y + n->h) continue;
      best = n->uid;
    }
    ax_unlock();
    *out = static_cast<IRawElementProviderFragment *>(ax_provider(best));
    return *out ? S_OK : E_OUTOFMEMORY;
  }

  HRESULT STDMETHODCALLTYPE GetFocus(IRawElementProviderFragment **out) override {
    if (!out) return E_POINTER;
    *out = NULL;
    ax_wait_for_tree();
    int focused = AX_DOCUMENT;
    ax_lock();
    for (int i = 0; i < g_ax_count; i++) {
      if (g_ax_nodes[i].focused) {
        focused = g_ax_nodes[i].uid;
        break;
      }
    }
    ax_unlock();
    *out = static_cast<IRawElementProviderFragment *>(ax_provider(focused));
    return *out ? S_OK : E_OUTOFMEMORY;
  }

  // IInvokeProvider
  HRESULT STDMETHODCALLTYPE Invoke() override { return press(); }

  /** A press, which the runtime runs as the element's click. */
  HRESULT press() {
    AxCopy c;
    if (!ax_node_copy(uid_, &c)) return UIA_E_ELEMENTNOTAVAILABLE;
    if (c.n.disabled) return UIA_E_ELEMENTNOTENABLED;
    ax_queue(AX_PRESS, uid_, NULL, 0, 0);
    return S_OK;
  }

  // IToggleProvider
  HRESULT STDMETHODCALLTYPE Toggle() override { return press(); }
  HRESULT STDMETHODCALLTYPE get_ToggleState(ToggleState *out) override {
    if (!out) return E_POINTER;
    AxCopy c;
    if (!ax_node_copy(uid_, &c)) return UIA_E_ELEMENTNOTAVAILABLE;
    *out = ax_toggle_state(&c.n);
    return S_OK;
  }

  // IValueProvider. A field's text, a link's address, a combobox's or range's value.
  HRESULT STDMETHODCALLTYPE SetValue(LPCWSTR value) override {
    AxCopy c;
    if (!ax_node_copy(uid_, &c)) return UIA_E_ELEMENTNOTAVAILABLE;
    if (c.n.disabled) return UIA_E_ELEMENTNOTENABLED;
    if (!(c.n.actions & AXA_SET_VALUE)) return UIA_E_INVALIDOPERATION;
    char *text = ax_utf8(value);
    if (!text) return E_OUTOFMEMORY;
    ax_queue(AX_SET_VALUE, uid_, text, 0, 0);
    // The node takes the value now, so a client that reads it back sees what it wrote.
    ax_lock();
    int i = ax_index_of(uid_);
    if (i >= 0) {
      free(g_ax_nodes[i].value);
      g_ax_nodes[i].value = dup_str(text);
    }
    ax_unlock();
    free(text);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_Value(BSTR *out) override {
    if (!out) return E_POINTER;
    AxCopy c;
    if (!ax_node_copy(uid_, &c)) return UIA_E_ELEMENTNOTAVAILABLE;
    *out = ax_bstr(ax_is(c.n.role, "link") ? c.url : c.value);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_IsReadOnly(BOOL *out) override {
    if (!out) return E_POINTER;
    AxCopy c;
    if (!ax_node_copy(uid_, &c)) return UIA_E_ELEMENTNOTAVAILABLE;
    *out = (c.n.actions & AXA_SET_VALUE) == 0;
    return S_OK;
  }

  // IRangeValueProvider
  HRESULT STDMETHODCALLTYPE SetValue(double value) override {
    AxCopy c;
    if (!ax_node_copy(uid_, &c)) return UIA_E_ELEMENTNOTAVAILABLE;
    if (!(c.n.actions & AXA_SET_VALUE)) return UIA_E_INVALIDOPERATION;
    if ((c.n.has_min && value < c.n.value_min) || (c.n.has_max && value > c.n.value_max)) return E_INVALIDARG;
    char text[64];
    snprintf(text, sizeof text, "%.17g", value);
    ax_queue(AX_SET_VALUE, uid_, text, 0, 0);
    ax_lock();
    int i = ax_index_of(uid_);
    if (i >= 0) g_ax_nodes[i].value_now = value;
    ax_unlock();
    return S_OK;
  }
  HRESULT range(double *out, int which) {
    if (!out) return E_POINTER;
    AxCopy c;
    if (!ax_node_copy(uid_, &c)) return UIA_E_ELEMENTNOTAVAILABLE;
    double span = (c.n.has_max ? c.n.value_max : 100) - (c.n.has_min ? c.n.value_min : 0);
    if (which == 0) *out = c.n.value_now;
    else if (which == 1) *out = c.n.has_min ? c.n.value_min : 0;
    else if (which == 2) *out = c.n.has_max ? c.n.value_max : 100;
    else if (which == 3) *out = span > 0 ? span / 10 : 1;
    else *out = 1;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_Value(double *out) override { return range(out, 0); }
  HRESULT STDMETHODCALLTYPE get_Minimum(double *out) override { return range(out, 1); }
  HRESULT STDMETHODCALLTYPE get_Maximum(double *out) override { return range(out, 2); }
  HRESULT STDMETHODCALLTYPE get_LargeChange(double *out) override { return range(out, 3); }
  HRESULT STDMETHODCALLTYPE get_SmallChange(double *out) override { return range(out, 4); }

  // IExpandCollapseProvider: aria-expanded's toggle, or a select's picker, is a press.
  HRESULT STDMETHODCALLTYPE Expand() override { return expand(1); }
  HRESULT STDMETHODCALLTYPE Collapse() override { return expand(0); }
  HRESULT expand(int want) {
    AxCopy c;
    if (!ax_node_copy(uid_, &c)) return UIA_E_ELEMENTNOTAVAILABLE;
    if (c.n.expanded == want) return S_OK;
    return press();
  }
  HRESULT STDMETHODCALLTYPE get_ExpandCollapseState(ExpandCollapseState *out) override {
    if (!out) return E_POINTER;
    AxCopy c;
    if (!ax_node_copy(uid_, &c)) return UIA_E_ELEMENTNOTAVAILABLE;
    *out = c.n.expanded == 1 ? ExpandCollapseState_Expanded : ExpandCollapseState_Collapsed;
    return S_OK;
  }

  // ISelectionItemProvider: choosing an item is its click, as a user's.
  HRESULT STDMETHODCALLTYPE Select() override {
    AxCopy c;
    if (!ax_node_copy(uid_, &c)) return UIA_E_ELEMENTNOTAVAILABLE;
    return ax_is_selected(&c.n) ? S_OK : press();
  }
  HRESULT STDMETHODCALLTYPE AddToSelection() override { return Select(); }
  HRESULT STDMETHODCALLTYPE RemoveFromSelection() override {
    AxCopy c;
    if (!ax_node_copy(uid_, &c)) return UIA_E_ELEMENTNOTAVAILABLE;
    return ax_is_selected(&c.n) && ax_is(c.n.role, "option") ? press() : S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_IsSelected(BOOL *out) override {
    if (!out) return E_POINTER;
    AxCopy c;
    if (!ax_node_copy(uid_, &c)) return UIA_E_ELEMENTNOTAVAILABLE;
    *out = ax_is_selected(&c.n);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_SelectionContainer(IRawElementProviderSimple **out) override {
    if (!out) return E_POINTER;
    *out = NULL;
    AxCopy c;
    if (!ax_node_copy(uid_, &c)) return UIA_E_ELEMENTNOTAVAILABLE;
    if (c.container_role[0]) *out = ax_simple(c.container_uid);
    return S_OK;
  }

  // IScrollItemProvider
  HRESULT STDMETHODCALLTYPE ScrollIntoView() override {
    ax_queue(AX_SCROLL_INTO_VIEW, uid_, NULL, 0, 0);
    return S_OK;
  }

  // ITextProvider: a field's text, its selection and its caret.
  HRESULT STDMETHODCALLTYPE GetSelection(SAFEARRAY **out) override {
    if (!out) return E_POINTER;
    AxCopy c;
    if (!ax_node_copy(uid_, &c)) return UIA_E_ELEMENTNOTAVAILABLE;
    // Offsets are in UTF-16 units of the value; the tree's are in its string's units, the same.
    int s = c.n.sel_start >= 0 ? c.n.sel_start : 0, e = c.n.sel_end >= s ? c.n.sel_end : s;
    return one_range(new AxTextRange(uid_, s, e), out);
  }
  HRESULT STDMETHODCALLTYPE GetVisibleRanges(SAFEARRAY **out) override {
    if (!out) return E_POINTER;
    return one_range(new AxTextRange(uid_, 0, INT32_MAX), out);
  }
  HRESULT STDMETHODCALLTYPE RangeFromChild(IRawElementProviderSimple *, ITextRangeProvider **out) override {
    if (!out) return E_POINTER;
    *out = NULL;
    return E_INVALIDARG;
  }
  HRESULT STDMETHODCALLTYPE RangeFromPoint(UiaPoint, ITextRangeProvider **out) override {
    if (!out) return E_POINTER;
    // Where in the text a point lands is the runtime's layout to say: the caret is the answer here.
    AxCopy c;
    int at = ax_node_copy(uid_, &c) && c.n.sel_end >= 0 ? c.n.sel_end : 0;
    *out = new AxTextRange(uid_, at, at);
    return *out ? S_OK : E_OUTOFMEMORY;
  }
  HRESULT STDMETHODCALLTYPE get_DocumentRange(ITextRangeProvider **out) override {
    if (!out) return E_POINTER;
    *out = new AxTextRange(uid_, 0, INT32_MAX);
    return *out ? S_OK : E_OUTOFMEMORY;
  }
  HRESULT STDMETHODCALLTYPE get_SupportedTextSelection(SupportedTextSelection *out) override {
    if (!out) return E_POINTER;
    *out = SupportedTextSelection_Single;
    return S_OK;
  }

 private:
  static HRESULT one_range(AxTextRange *range, SAFEARRAY **out) {
    *out = NULL;
    if (!range) return E_OUTOFMEMORY;
    SAFEARRAY *array = SafeArrayCreateVector(VT_UNKNOWN, 0, 1);
    if (!array) {
      range->Release();
      return E_OUTOFMEMORY;
    }
    LONG at = 0;
    SafeArrayPutElement(array, &at, static_cast<IUnknown *>(range));
    range->Release();
    *out = array;
    return S_OK;
  }

  LONG refs_;
  int uid_;
};

static AxProvider *ax_provider(int uid) { return new AxProvider(uid); }

static IRawElementProviderSimple *ax_simple(int uid) {
  AxProvider *p = new AxProvider(uid);
  return p ? static_cast<IRawElementProviderSimple *>(p) : NULL;
}

// --- Events: what changed between two trees, as UIA's events say it.

static void ax_raise_property(int uid, PROPERTYID id, VARIANT before, VARIANT after) {
  IRawElementProviderSimple *simple = ax_simple(uid);
  if (!simple) return;
  UiaRaiseAutomationPropertyChangedEvent(simple, id, before, after);
  simple->Release();
}

static void ax_raise_bool(int uid, PROPERTYID id, int before, int after) {
  VARIANT a, b;
  a.vt = b.vt = VT_BOOL;
  a.boolVal = before ? VARIANT_TRUE : VARIANT_FALSE;
  b.boolVal = after ? VARIANT_TRUE : VARIANT_FALSE;
  ax_raise_property(uid, id, a, b);
}

static void ax_raise_i4(int uid, PROPERTYID id, int before, int after) {
  VARIANT a, b;
  a.vt = b.vt = VT_I4;
  a.lVal = before;
  b.lVal = after;
  ax_raise_property(uid, id, a, b);
}

static void ax_raise_text(int uid, PROPERTYID id, const char *before, const char *after) {
  VARIANT a, b;
  a.vt = b.vt = VT_BSTR;
  a.bstrVal = ax_bstr(before ? before : "");
  b.bstrVal = ax_bstr(after ? after : "");
  ax_raise_property(uid, id, a, b);
  SysFreeString(a.bstrVal);
  SysFreeString(b.bstrVal);
}

static void ax_raise_event(int uid, EVENTID id) {
  IRawElementProviderSimple *simple = ax_simple(uid);
  if (!simple) return;
  UiaRaiseAutomationEvent(simple, id);
  simple->Release();
}

static int ax_same(const char *a, const char *b) { return strcmp(a ? a : "", b ? b : "") == 0; }

/** Raises, for each node in both trees, the events its changes call for; and a structure change
 *  when the tree's shape moved. */
static void ax_raise_changes(const AxNode *was, int was_count, const AxNode *now, int now_count) {
  if (!UiaClientsAreListening()) return;
  bool shape = was_count != now_count;
  for (int i = 0; i < now_count; i++) {
    const AxNode *n = &now[i];
    const AxNode *o = NULL;
    if (i < was_count && was[i].uid == n->uid) o = &was[i];
    else for (int k = 0; k < was_count; k++) if (was[k].uid == n->uid) { o = &was[k]; break; }
    if (o == NULL || o->parent != n->parent || (i < was_count && was[i].uid != n->uid)) shape = true;
    if (o == NULL) continue;
    if (!ax_same(o->label, n->label)) ax_raise_text(n->uid, UIA_NamePropertyId, o->label, n->label);
    if (!ax_same(o->value, n->value)) {
      ax_raise_text(n->uid, UIA_ValueValuePropertyId, o->value, n->value);
      if (ax_is_field(n)) ax_raise_event(n->uid, UIA_Text_TextChangedEventId);
    }
    if (ax_is_field(n) && n->focused && (o->sel_start != n->sel_start || o->sel_end != n->sel_end))
      ax_raise_event(n->uid, UIA_Text_TextSelectionChangedEventId);
    if (ax_toggles(n) && ax_toggle_state(o) != ax_toggle_state(n))
      ax_raise_i4(n->uid, UIA_ToggleToggleStatePropertyId, ax_toggle_state(o), ax_toggle_state(n));
    if (ax_expands(n) && o->expanded != n->expanded)
      ax_raise_i4(n->uid, UIA_ExpandCollapseExpandCollapseStatePropertyId,
        o->expanded == 1 ? ExpandCollapseState_Expanded : ExpandCollapseState_Collapsed,
        n->expanded == 1 ? ExpandCollapseState_Expanded : ExpandCollapseState_Collapsed);
    if (ax_selectable(n) && ax_is_selected(o) != ax_is_selected(n)) {
      ax_raise_bool(n->uid, UIA_SelectionItemIsSelectedPropertyId, ax_is_selected(o), ax_is_selected(n));
      if (ax_is_selected(n)) ax_raise_event(n->uid, UIA_SelectionItem_ElementSelectedEventId);
    }
    if (ax_has_range(n) && o->value_now != n->value_now) {
      VARIANT a, b;
      a.vt = b.vt = VT_R8;
      a.dblVal = o->value_now;
      b.dblVal = n->value_now;
      ax_raise_property(n->uid, UIA_RangeValueValuePropertyId, a, b);
    }
    if (o->disabled != n->disabled) ax_raise_bool(n->uid, UIA_IsEnabledPropertyId, !o->disabled, !n->disabled);
  }
  if (shape) {
    IRawElementProviderSimple *document = ax_simple(AX_DOCUMENT);
    if (document) {
      // The Document's own runtime id, which is where the change happened.
      int id[2] = {UiaAppendRuntimeId, AX_DOCUMENT + 1};
      UiaRaiseStructureChangedEvent(document, StructureChangeType_ChildrenInvalidated, id, 2);
      document->Release();
    }
  }
}

/** Raised for the focused node, when focus moves. */
static void ax_raise_focus(int uid) {
  ax_raise_event(uid, UIA_AutomationFocusChangedEventId);
}

/** Prepares the provider the window hands out; made with the window. */
static void ax_ensure(void) {
  if (!g_ax_lock_ready) {
    InitializeCriticalSection(&g_ax_lock);
    g_ax_lock_ready = 1;
  }
  if (!g_ax_ready) g_ax_ready = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!g_ax_ui_thread) g_ax_ui_thread = GetCurrentThreadId();
  if (!g_ax_root) {
    AxProvider *root = new AxProvider(AX_WINDOW);
    if (root) g_ax_root = static_cast<IRawElementProviderFragmentRoot *>(root);
  }
  if (!g_ax_host && g_hwnd) UiaHostProviderFromHwnd(g_hwnd, &g_ax_host);
  // UIA calls a server-side provider from its own threads; a free-threaded marshaler is what
  // lets those calls reach the provider objects.
  if (!g_ax_marshaler) CoCreateFreeThreadedMarshaler(NULL, &g_ax_marshaler);
}

static int g_ax_last_focus = INT32_MIN;

/** Whether a run prints the tree it publishes, which builds it with no client asking. */
static int ax_dump_on(void) {
  static int on = -1;
  if (on < 0) on = getenv("NATIVE_AX_DUMP") != NULL || getenv("NATIVE_AX_SELFTEST") != NULL;
  return on;
}

/** Walks the provider the way a client walks it, and prints what it found. */
static void ax_selftest(void) {
  struct Counts {
    int nodes, buttons, named, name_chars;
  };
  class Walk {
   public:
    static void node(IRawElementProviderFragment *fragment, int depth, Counts *counts) {
      if (!fragment || depth > 12) return;
      counts->nodes++;
      IRawElementProviderSimple *simple = NULL;
      fragment->QueryInterface(__uuidof(IRawElementProviderSimple), (void **)&simple);
      if (simple) {
        VARIANT v;
        VariantInit(&v);
        if (SUCCEEDED(simple->GetPropertyValue(UIA_ControlTypePropertyId, &v)) && v.vt == VT_I4 &&
            v.lVal == (LONG)UIA_ButtonControlTypeId)
          counts->buttons++;
        VariantClear(&v);
        VariantInit(&v);
        if (SUCCEEDED(simple->GetPropertyValue(UIA_NamePropertyId, &v)) && v.vt == VT_BSTR && v.bstrVal != NULL) {
          UINT len = SysStringLen(v.bstrVal);
          if (len > 0) counts->named++;
          counts->name_chars += (int)len;
        }
        VariantClear(&v);
        simple->Release();
      }
      IRawElementProviderFragment *child = NULL;
      fragment->Navigate(NavigateDirection_FirstChild, &child);
      while (child) {
        node(child, depth + 1, counts);
        IRawElementProviderFragment *next = NULL;
        child->Navigate(NavigateDirection_NextSibling, &next);
        child->Release();
        child = next;
      }
    }
  };
  Counts counts = {0, 0, 0, 0};
  AxProvider *root = new AxProvider(AX_WINDOW);
  if (!root) return;
  Walk::node(root, 0, &counts);
  root->Release();
  fprintf(stderr, "native: ax selftest nodes=%d buttons=%d named=%d name chars=%d\n", counts.nodes,
          counts.buttons, counts.named, counts.name_chars);
}

/** Prints the tree the way a UIA client sees it: control type, AutomationId, name, value and
 *  patterns, for a test that runs without a client. */
static void ax_dump(void) {
  static const struct { PATTERNID id; const char *name; } patterns[] = {
    {UIA_InvokePatternId, "Invoke"}, {UIA_TogglePatternId, "Toggle"}, {UIA_ValuePatternId, "Value"},
    {UIA_RangeValuePatternId, "RangeValue"}, {UIA_ExpandCollapsePatternId, "ExpandCollapse"},
    {UIA_SelectionItemPatternId, "SelectionItem"}, {UIA_TextPatternId, "Text"},
  };
  fprintf(stdout, "AX TREE\n");
  ax_lock();
  for (int i = 0; i < g_ax_count; i++) {
    AxNode *n = &g_ax_nodes[i];
    int depth = 0;
    for (int p = n->parent; p > 0 && p <= g_ax_count; p = g_ax_nodes[p - 1].parent) depth++;
    AxProvider probe(n->uid);
    char pats[160] = "";
    for (size_t k = 0; k < sizeof patterns / sizeof patterns[0]; k++) {
      if (!probe.has_pattern(patterns[k].id, n)) continue;
      strncat(pats, pats[0] ? "," : " patterns=", sizeof pats - strlen(pats) - 1);
      strncat(pats, patterns[k].name, sizeof pats - strlen(pats) - 1);
    }
    fprintf(stdout, "%*s%s %.0f,%.0f %.0fx%.0f label=[%s] value=[%s]%s%s%s%s\n", depth * 2, "", n->role,
            n->x, n->y, n->w, n->h, n->label ? n->label : "", n->value ? n->value : "",
            n->dom_id ? " id=" : "", n->dom_id ? n->dom_id : "", pats, n->focused ? " focused" : "");
  }
  ax_unlock();
  fprintf(stdout, "AX END\n");
  fflush(stdout);
}

void host_ax_tree(const uint8_t *spec, size_t n) {
  ax_ensure();
  char *text = (char *)malloc(n + 1);
  if (!text) return;
  memcpy(text, spec, n);
  text[n] = '\0';
  int count = 0;
  AxNode *nodes = ax_parse(text, &count);
  free(text);
  ax_lock();
  AxNode *previous = g_ax_nodes;
  int previous_count = g_ax_count;
  g_ax_nodes = nodes;
  g_ax_count = count;
  ax_unlock();
  // A client's first walk may be waiting on a UIA thread for this tree.
  if (!g_ax_has_tree) {
    InterlockedExchange(&g_ax_has_tree, 1);
    if (g_ax_ready) SetEvent(g_ax_ready);
  }
  if (g_hwnd) ax_raise_changes(previous, previous_count, nodes, count);
  for (int i = 0; i < previous_count; i++) ax_free_node(&previous[i]);
  free(previous);
  int focused = AX_DOCUMENT;
  ax_lock();
  for (int i = 0; i < g_ax_count; i++) {
    if (g_ax_nodes[i].focused) {
      focused = g_ax_nodes[i].uid;
      break;
    }
  }
  ax_unlock();
  if (focused != g_ax_last_focus) {
    g_ax_last_focus = focused;
    if (g_hwnd && UiaClientsAreListening()) ax_raise_focus(focused);
  }
  if (getenv("NATIVE_AX_DUMP") != NULL) ax_dump();
  if (getenv("NATIVE_AX_SELFTEST") != NULL) ax_selftest();
}

/** This host's focus and text-range requests go to the runtime as EV_AXACTION; the older events
 *  carry nothing here. */
int32_t host_ax_focus(void) { return 0; }
int32_t host_ax_selection(void) { return 0; }

/** Whether a client has asked for the tree (or a run prints every one). */
int32_t host_ax_active(void) { return g_ax_active || ax_dump_on() ? 1 : 0; }
/** The action EV_AXACTION carries: its kind, its node's uid, and its text. */
int32_t host_ax_action(void) { return g_ax_action.kind; }
int32_t host_ax_action_target(void) { return g_ax_action.uid; }
void host_ax_action_text(window_text_cb cb) {
  const char *t = g_ax_action.text ? g_ax_action.text : "";
  cb((const uint8_t *)t, strlen(t));
}

/** A live region's new text, raised as UIA's notification so Narrator reads it as a browser's
 *  live region; a client that isn't listening costs nothing. */
void host_ax_announce(const uint8_t *text, size_t n, int32_t priority) {
  if (!g_ax_root || !UiaClientsAreListening()) return;
  IRawElementProviderSimple *document = ax_simple(AX_DOCUMENT);
  if (!document) return;
  char *copy = (char *)malloc(n + 1);
  if (copy) {
    memcpy(copy, text, n);
    copy[n] = 0;
    BSTR spoken = ax_bstr(copy);
    BSTR activity = SysAllocString(L"live-region");
    UiaRaiseNotificationEvent(document, NotificationKind_Other,
      priority == 1 ? NotificationProcessing_ImportantMostRecent : NotificationProcessing_MostRecent,
      spoken, activity);
    SysFreeString(spoken);
    SysFreeString(activity);
    free(copy);
  }
  document->Release();
}

/** The runtime's own value-changed report; the tree comparison already raised the property event. */
void host_ax_value_changed(int32_t node) { (void)node; }

/** A run asks the system's line breaker for the points it may break at and gets none. */
int32_t host_register_line_breaks(const uint8_t *text, size_t n, const uint8_t *lang, size_t lang_len,
                                  int32_t line_break) {
  (void)text; (void)n; (void)lang; (void)lang_len; (void)line_break;
  return 0;
}
int32_t host_line_break_count(int32_t id) { (void)id; return 0; }
int32_t host_line_break_at(int32_t id, int32_t i) { (void)id; (void)i; return 0; }
/** The line breaker here is a stub, so no character suppresses an atomic inline's opportunity. */
int32_t host_atomic_break_forbidden(int32_t cp) { (void)cp; return 0; }

}  // extern "C"

extern "C" {

// ---------------------------------------------------------------------------
// WebGL 2
//
// A <canvas> with a "webgl2" context owns an OpenGL ES context made through ANGLE, whose libraries
// the host loads at run time: the copy shipped beside the app (`<executable>.resources`) first,
// then the directory NATIVE_ANGLE_DIR names, then the loader's own search. A page that asks for
// WebGL 2 where those libraries are missing gets null, as it would from a browser without WebGL.
//
// ANGLE is EGL and OpenGL ES over Direct3D 11, which makes this the same backend the Linux host
// runs on EGL: commands execute as the calls arrive, each canvas keeps its own context and
// drawing buffer, and the canvas bitmap the display list draws (CMD_CANVAS) is a readback of that
// buffer. Programs arrive as GLSL ES 3.00 and are compiled as such.

typedef struct CanvasGl {
  EGLContext ctx;
  // The stand-in for the default framebuffer: a resolved RGBA8 texture the canvas bitmap is read
  // from, and, when the context asks for antialiasing, a multisampled pair drawn into and blitted
  // into the resolved one when the canvas is painted.
  GLuint fbo, color;
  GLuint msaa_fbo, msaa_color, msaa_depth;
  GLuint depth;
  GLuint default_vao;  // core-style binding: the page's vertex array 0 names this one
  EGLSurface surface;  // a 1x1 pbuffer, only so the context has one to be current with
  // A canvas the page draws straight from: the drawing buffer is a texture this host shares with
  // ANGLE (EGL_ANGLE_d3d_texture_client_buffer) and the canvas bitmap wraps it, so a frame is
  // copied on the GPU instead of read back. NULL when the extension or the texture is not there.
  ID3D11Texture2D *shared;
  ID3D11Texture2D *ours;  // the same texture opened on this host's device, for the bitmap
  EGLSurface client;
  EGLSurface pbuffer;  // the 1x1 surface the context is current with when it has no shared texture
  int external;
  double w, h;
  int depth_bits, stencil_bits, samples, alpha;
  // Bumped whenever the page's own GL calls can change the drawing buffer (a draw, a clear, and
  // the clear a resize does). The compositor keys a canvas chunk on it, so a canvas that has not
  // drawn since the last frame keeps the texture it has and is neither rastered nor read back.
  int32_t generation;
} CanvasGl;

static HMODULE g_egl_module = NULL;
static HMODULE g_gles_module = NULL;
static int g_angle_state = 0;  // 0 not tried yet, 1 loaded, -1 not available
static char g_angle_why[512];

/** One line about the WebGL 2 backend, printed when NATIVE_FRAME_TIMES asks for the frame's costs. */
static void angle_note(const char *why) {
  if (getenv("NATIVE_FRAME_TIMES") == NULL) return;
  fprintf(stderr, "native: webgl2 %s\n", why);
}

static const struct {
  const char *name;
  void **slot;
} kAngleFns[] = {
  {"eglGetDisplay", (void **)&eglGetDisplay},
  {"eglGetPlatformDisplayEXT", (void **)&eglGetPlatformDisplayEXT},
  {"eglInitialize", (void **)&eglInitialize},
  {"eglChooseConfig", (void **)&eglChooseConfig},
  {"eglCreateContext", (void **)&eglCreateContext},
  {"eglDestroyContext", (void **)&eglDestroyContext},
  {"eglMakeCurrent", (void **)&eglMakeCurrent},
  {"eglGetCurrentContext", (void **)&eglGetCurrentContext},
  {"eglBindAPI", (void **)&eglBindAPI},
  {"eglCreatePbufferSurface", (void **)&eglCreatePbufferSurface},
  {"eglDestroySurface", (void **)&eglDestroySurface},
  {"eglQueryString", (void **)&eglQueryString},
  {"eglGetError", (void **)&eglGetError},
  {"eglQueryDisplayAttribANGLE", (void **)&eglQueryDisplayAttribANGLE},
  {"eglQueryDeviceAttribEXT", (void **)&eglQueryDeviceAttribEXT},
  {"eglCreatePbufferFromClientBuffer", (void **)&eglCreatePbufferFromClientBuffer},
  {"eglGetProcAddress", (void **)&eglGetProcAddress},
  {"glGetError", (void **)&glGetError},
  {"glGetString", (void **)&glGetString},
  {"glGetStringi", (void **)&glGetStringi},
  {"glGetIntegerv", (void **)&glGetIntegerv},
  {"glGetFloatv", (void **)&glGetFloatv},
  {"glFinish", (void **)&glFinish},
  {"glFlush", (void **)&glFlush},
  {"glReadPixels", (void **)&glReadPixels},
  {"glPixelStorei", (void **)&glPixelStorei},
  {"glViewport", (void **)&glViewport},
  {"glScissor", (void **)&glScissor},
  {"glEnable", (void **)&glEnable},
  {"glDisable", (void **)&glDisable},
  {"glClear", (void **)&glClear},
  {"glClearColor", (void **)&glClearColor},
  {"glClearDepthf", (void **)&glClearDepthf},
  {"glClearStencil", (void **)&glClearStencil},
  {"glColorMask", (void **)&glColorMask},
  {"glDepthMask", (void **)&glDepthMask},
  {"glStencilMask", (void **)&glStencilMask},
  {"glCullFace", (void **)&glCullFace},
  {"glFrontFace", (void **)&glFrontFace},
  {"glDepthFunc", (void **)&glDepthFunc},
  {"glDepthRangef", (void **)&glDepthRangef},
  {"glBlendFunc", (void **)&glBlendFunc},
  {"glBlendFuncSeparate", (void **)&glBlendFuncSeparate},
  {"glBlendEquation", (void **)&glBlendEquation},
  {"glBlendEquationSeparate", (void **)&glBlendEquationSeparate},
  {"glBlendColor", (void **)&glBlendColor},
  {"glPolygonOffset", (void **)&glPolygonOffset},
  {"glStencilFunc", (void **)&glStencilFunc},
  {"glStencilOp", (void **)&glStencilOp},
  {"glLineWidth", (void **)&glLineWidth},
  {"glBindFramebuffer", (void **)&glBindFramebuffer},
  {"glBindRenderbuffer", (void **)&glBindRenderbuffer},
  {"glFramebufferTexture2D", (void **)&glFramebufferTexture2D},
  {"glFramebufferRenderbuffer", (void **)&glFramebufferRenderbuffer},
  {"glRenderbufferStorage", (void **)&glRenderbufferStorage},
  {"glRenderbufferStorageMultisample", (void **)&glRenderbufferStorageMultisample},
  {"glCheckFramebufferStatus", (void **)&glCheckFramebufferStatus},
  {"glBlitFramebuffer", (void **)&glBlitFramebuffer},
  {"glDrawBuffers", (void **)&glDrawBuffers},
  {"glGenFramebuffers", (void **)&glGenFramebuffers},
  {"glDeleteFramebuffers", (void **)&glDeleteFramebuffers},
  {"glGenRenderbuffers", (void **)&glGenRenderbuffers},
  {"glDeleteRenderbuffers", (void **)&glDeleteRenderbuffers},
  {"glGenTextures", (void **)&glGenTextures},
  {"glDeleteTextures", (void **)&glDeleteTextures},
  {"glBindTexture", (void **)&glBindTexture},
  {"glActiveTexture", (void **)&glActiveTexture},
  {"glTexImage2D", (void **)&glTexImage2D},
  {"glTexImage3D", (void **)&glTexImage3D},
  {"glTexSubImage2D", (void **)&glTexSubImage2D},
  {"glTexStorage2D", (void **)&glTexStorage2D},
  {"glTexParameteri", (void **)&glTexParameteri},
  {"glTexParameterf", (void **)&glTexParameterf},
  {"glGenerateMipmap", (void **)&glGenerateMipmap},
  {"glGenBuffers", (void **)&glGenBuffers},
  {"glDeleteBuffers", (void **)&glDeleteBuffers},
  {"glBindBuffer", (void **)&glBindBuffer},
  {"glBufferData", (void **)&glBufferData},
  {"glBufferSubData", (void **)&glBufferSubData},
  {"glCreateShader", (void **)&glCreateShader},
  {"glDeleteShader", (void **)&glDeleteShader},
  {"glShaderSource", (void **)&glShaderSource},
  {"glCompileShader", (void **)&glCompileShader},
  {"glGetShaderiv", (void **)&glGetShaderiv},
  {"glGetShaderInfoLog", (void **)&glGetShaderInfoLog},
  {"glAttachShader", (void **)&glAttachShader},
  {"glDetachShader", (void **)&glDetachShader},
  {"glBindAttribLocation", (void **)&glBindAttribLocation},
  {"glCreateProgram", (void **)&glCreateProgram},
  {"glDeleteProgram", (void **)&glDeleteProgram},
  {"glLinkProgram", (void **)&glLinkProgram},
  {"glUseProgram", (void **)&glUseProgram},
  {"glGetProgramiv", (void **)&glGetProgramiv},
  {"glGetProgramInfoLog", (void **)&glGetProgramInfoLog},
  {"glGetAttribLocation", (void **)&glGetAttribLocation},
  {"glGetUniformLocation", (void **)&glGetUniformLocation},
  {"glGetUniformBlockIndex", (void **)&glGetUniformBlockIndex},
  {"glGetActiveUniform", (void **)&glGetActiveUniform},
  {"glGetActiveAttrib", (void **)&glGetActiveAttrib},
  {"glUniform1f", (void **)&glUniform1f},
  {"glUniform1fv", (void **)&glUniform1fv},
  {"glUniform2fv", (void **)&glUniform2fv},
  {"glUniform3fv", (void **)&glUniform3fv},
  {"glUniform4fv", (void **)&glUniform4fv},
  {"glUniform1i", (void **)&glUniform1i},
  {"glUniform1iv", (void **)&glUniform1iv},
  {"glUniform2iv", (void **)&glUniform2iv},
  {"glUniform3iv", (void **)&glUniform3iv},
  {"glUniform4iv", (void **)&glUniform4iv},
  {"glUniform1uiv", (void **)&glUniform1uiv},
  {"glUniform2uiv", (void **)&glUniform2uiv},
  {"glUniform3uiv", (void **)&glUniform3uiv},
  {"glUniform4uiv", (void **)&glUniform4uiv},
  {"glUniformMatrix2fv", (void **)&glUniformMatrix2fv},
  {"glUniformMatrix3fv", (void **)&glUniformMatrix3fv},
  {"glUniformMatrix4fv", (void **)&glUniformMatrix4fv},
  {"glGenVertexArrays", (void **)&glGenVertexArrays},
  {"glDeleteVertexArrays", (void **)&glDeleteVertexArrays},
  {"glBindVertexArray", (void **)&glBindVertexArray},
  {"glEnableVertexAttribArray", (void **)&glEnableVertexAttribArray},
  {"glDisableVertexAttribArray", (void **)&glDisableVertexAttribArray},
  {"glVertexAttribPointer", (void **)&glVertexAttribPointer},
  {"glVertexAttribIPointer", (void **)&glVertexAttribIPointer},
  {"glVertexAttribDivisor", (void **)&glVertexAttribDivisor},
  {"glVertexAttrib1fv", (void **)&glVertexAttrib1fv},
  {"glVertexAttrib2fv", (void **)&glVertexAttrib2fv},
  {"glVertexAttrib3fv", (void **)&glVertexAttrib3fv},
  {"glVertexAttrib4fv", (void **)&glVertexAttrib4fv},
  {"glDrawArrays", (void **)&glDrawArrays},
  {"glDrawElements", (void **)&glDrawElements},
  {"glDrawArraysInstanced", (void **)&glDrawArraysInstanced},
  {"glDrawElementsInstanced", (void **)&glDrawElementsInstanced},
};

/** A DLL by name, from the app's own resources first, then NATIVE_ANGLE_DIR, then the loader. */
static HMODULE angle_open(const char *name) {
  wchar_t wide_name[260];
  size_t wide_len = 0;
  wchar_t *converted = utf8_to_utf16((const uint8_t *)name, strlen(name), &wide_len);
  if (!converted) return NULL;
  wcsncpy(wide_name, converted, 259);
  wide_name[259] = L'\0';
  free(converted);
  wchar_t exe[4000];
  DWORD len = GetModuleFileNameW(NULL, exe, 4000);
  if (len > 0 && len < 4000) {
    wchar_t *slash = wcsrchr(exe, L'\\');
    if (slash) {
      *slash = L'\0';
      const wchar_t *base = slash + 1;
      wchar_t path[8000];
      _snwprintf(path, 8000, L"%s\\%s.resources\\%s", exe, base, wide_name);
      if (GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES) {
        HMODULE module = LoadLibraryExW(path, NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!module) module = LoadLibraryW(path);
        if (module) return module;
      }
    }
  }
  const char *dir = getenv("NATIVE_ANGLE_DIR");
  if (dir != NULL && dir[0] != '\0') {
    wchar_t wide_dir[4000];
    size_t dir_len = 0;
    wchar_t *folder = utf8_to_utf16((const uint8_t *)dir, strlen(dir), &dir_len);
    if (folder && dir_len < 3990) {
      wcsncpy(wide_dir, folder, 3999);
      wide_dir[3999] = L'\0';
      wchar_t path[8000];
      _snwprintf(path, 8000, L"%s\\%s", wide_dir, wide_name);
      if (GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES) {
        HMODULE module = LoadLibraryExW(path, NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!module) module = LoadLibraryW(path);
        if (module) {
          free(folder);
          return module;
        }
      }
    }
    free(folder);
  }
  return LoadLibraryW(wide_name);
}

/** The address of one EGL or GL entry point, from whichever loaded library exports it. */
static void *angle_symbol(const char *name) {
  void *found = NULL;
  if (g_gles_module) found = (void *)GetProcAddress(g_gles_module, name);
  if (!found && g_egl_module) found = (void *)GetProcAddress(g_egl_module, name);
  if (!found && eglGetProcAddress) found = (void *)eglGetProcAddress(name);
  return found;
}

/** Loads ANGLE and resolves every entry point the backend uses: false when it is not there. */
static int angle_start(void) {
  if (g_angle_state != 0) return g_angle_state > 0;
  g_angle_state = -1;
  g_egl_module = angle_open("libEGL.dll");
  if (!g_egl_module) {
    snprintf(g_angle_why, sizeof g_angle_why, "unavailable: libEGL.dll not found");
    angle_note(g_angle_why);
    return 0;
  }
  g_gles_module = angle_open("libGLESv2.dll");
  if (!g_gles_module) {
    snprintf(g_angle_why, sizeof g_angle_why, "unavailable: libGLESv2.dll not found");
    angle_note(g_angle_why);
    return 0;
  }
  eglGetProcAddress = (void *(*)(const char *))GetProcAddress(g_egl_module, "eglGetProcAddress");
  // Every entry point the backend calls has to be there. The one exception is the platform
  // display chooser an old ANGLE may not export: the default display then picks the backend, which
  // is Direct3D 11 on Windows anyway.
  int missing = 0;
  const char *first_missing = NULL;
  for (size_t i = 0; i < sizeof kAngleFns / sizeof kAngleFns[0]; i++) {
    void *found = angle_symbol(kAngleFns[i].name);
    *kAngleFns[i].slot = found;
    if (!found) {
      missing++;
      if (first_missing == NULL) first_missing = kAngleFns[i].name;
    }
  }
  if (missing > (eglGetPlatformDisplayEXT ? 0 : 1)) {
    snprintf(g_angle_why, sizeof g_angle_why, "unavailable: %s missing", first_missing ? first_missing : "entry point");
    angle_note(g_angle_why);
    return 0;
  }
  g_angle_state = 1;
  return 1;
}

static EGLDisplay g_egl_display = EGL_NO_DISPLAY;
static EGLConfig g_egl_config = NULL;
static int g_egl_started = 0;

/** The display every WebGL canvas's context comes from, opened once. */
static EGLDisplay egl_display(void) {
  if (g_egl_started) return g_egl_display;
  g_egl_started = 1;
  if (!angle_start()) return g_egl_display;
  // Direct3D 11 in hardware where there is a device for it, then ANGLE's software device, then
  // whatever the default display resolves to. A machine with no GPU driver still draws, slowly.
  const EGLint hardware[] = {
    EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE,
    EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_DEVICE_TYPE_HARDWARE_ANGLE,
    EGL_NONE,
  };
  const EGLint software[] = {
    EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE,
    EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_DEVICE_TYPE_D3D_WARP_ANGLE,
    EGL_NONE,
  };
  if (eglGetPlatformDisplayEXT) {
    g_egl_display = eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, hardware);
    if (g_egl_display == EGL_NO_DISPLAY)
      g_egl_display = eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, software);
  }
  if (g_egl_display == EGL_NO_DISPLAY) g_egl_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (g_egl_display == EGL_NO_DISPLAY) {
    snprintf(g_angle_why, sizeof g_angle_why, "unavailable: no EGL display");
    angle_note(g_angle_why);
    return g_egl_display;
  }
  EGLint major = 0, minor = 0;
  if (!eglInitialize(g_egl_display, &major, &minor)) {
    g_egl_display = EGL_NO_DISPLAY;
    snprintf(g_angle_why, sizeof g_angle_why, "unavailable: eglInitialize failed");
    angle_note(g_angle_why);
    return g_egl_display;
  }
  if (!eglBindAPI(EGL_OPENGL_ES_API)) {
    g_egl_display = EGL_NO_DISPLAY;
    snprintf(g_angle_why, sizeof g_angle_why, "unavailable: eglBindAPI failed");
    angle_note(g_angle_why);
    return g_egl_display;
  }
  // The context renders to a framebuffer object of its own, so its config only has to exist; the
  // sizes it asks for are the ones a browser's drawing buffer has.
  EGLint attrs[] = {
    EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
    EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
    EGL_COLOR_BUFFER_TYPE, EGL_RGB_BUFFER,
    EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
    EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
    EGL_NONE,
  };
  EGLint count = 0;
  if (!eglChooseConfig(g_egl_display, attrs, &g_egl_config, 1, &count) || count < 1) {
    g_egl_display = EGL_NO_DISPLAY;
    snprintf(g_angle_why, sizeof g_angle_why, "unavailable: no ES 3 config");
    angle_note(g_angle_why);
    return g_egl_display;
  }
  return g_egl_display;
}

/** The renderer behind a canvas's context, for the diagnostics line. */
static void angle_renderer(char *out, size_t cap) {
  const char *renderer = (const char *)glGetString(GL_RENDERER);
  snprintf(out, cap, "%s", renderer ? renderer : "unknown");
}

// An ES 3.0 context, which is what WebGL 2 is defined as.
static EGLContext gl_make_context(EGLDisplay dpy) {
  static const EGLint versions[][2] = {{3, 0}};
  for (size_t i = 0; i < sizeof versions / sizeof versions[0]; i++) {
    EGLint attrs[] = {
      EGL_CONTEXT_MAJOR_VERSION, versions[i][0],
      EGL_CONTEXT_MINOR_VERSION, versions[i][1],
      EGL_NONE,
    };
    EGLContext ctx = eglCreateContext(dpy, g_egl_config, EGL_NO_CONTEXT, attrs);
    if (ctx != EGL_NO_CONTEXT) return ctx;
  }
  return EGL_NO_CONTEXT;
}

static CanvasGl *gl_at(int32_t id) {
  Canvas *c = canvas_at(id);
  return c ? c->gl : NULL;
}

static int32_t canvas_content_generation(int32_t id) {
  CanvasGl *g = gl_at(id);
  return g ? g->generation : -1;
}

// Makes the canvas's context current. False when the canvas has no WebGL context.
static int gl_ready(CanvasGl *g) {
  if (!g || g->ctx == EGL_NO_CONTEXT) return 0;
  EGLDisplay dpy = egl_display();
  if (dpy == EGL_NO_DISPLAY) return 0;
  if (eglGetCurrentContext() != g->ctx &&
      !eglMakeCurrent(dpy, g->surface, g->surface, g->ctx))
    return 0;
  return 1;
}

// The renderbuffer format for the depth/stencil attachment: 0 when the context asked for neither.
// A framebuffer without a depth attachment passes the depth test, as a browser's does.
static GLenum gl_depth_format(const CanvasGl *g) {
  if (g->depth_bits && g->stencil_bits) return GL_DEPTH24_STENCIL8;
  if (g->depth_bits) return GL_DEPTH_COMPONENT24;
  if (g->stencil_bits) return GL_STENCIL_INDEX8;
  return 0;
}

// `g->fbo` for a context without antialiasing, else the multisampled one; framebuffer object 0
// from the page binds this.
static GLuint gl_draw_fbo(const CanvasGl *g) {
  return g->samples ? g->msaa_fbo : g->fbo;
}

static void gl_alloc(CanvasGl *g, double w, double h) {
  if (w < 1) w = 1;
  if (h < 1) h = 1;
  g->w = floor(w);
  g->h = floor(h);
  GLsizei gw = (GLsizei)g->w, gh = (GLsizei)g->h;

  glBindFramebuffer(GL_FRAMEBUFFER, g->fbo);
  glBindTexture(GL_TEXTURE_2D, g->color);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, gw, gh, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, g->color, 0);

  GLenum dfmt = gl_depth_format(g);
  if (dfmt) {
    glBindRenderbuffer(GL_RENDERBUFFER, g->depth);
    glRenderbufferStorage(GL_RENDERBUFFER, dfmt, gw, gh);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER,
                              g->stencil_bits ? GL_DEPTH_STENCIL_ATTACHMENT : GL_DEPTH_ATTACHMENT,
                              GL_RENDERBUFFER, g->depth);
  }

  if (g->samples) {
    glBindFramebuffer(GL_FRAMEBUFFER, g->msaa_fbo);
    glBindRenderbuffer(GL_RENDERBUFFER, g->msaa_color);
    glRenderbufferStorageMultisample(GL_RENDERBUFFER, g->samples, GL_RGBA8, gw, gh);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, g->msaa_color);
    if (dfmt) {
      glBindRenderbuffer(GL_RENDERBUFFER, g->msaa_depth);
      glRenderbufferStorageMultisample(GL_RENDERBUFFER, g->samples, dfmt, gw, gh);
      glFramebufferRenderbuffer(GL_FRAMEBUFFER,
                                g->stencil_bits ? GL_DEPTH_STENCIL_ATTACHMENT : GL_DEPTH_ATTACHMENT,
                                GL_RENDERBUFFER, g->msaa_depth);
    }
  }

  glBindFramebuffer(GL_FRAMEBUFFER, gl_draw_fbo(g));
  glViewport(0, 0, gw, gh);
  // A browser's drawing buffer starts cleared to transparent black.
  glClearColor(0, 0, 0, 0);
  glClearDepthf(1.0f);
  glClearStencil(0);
  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
  g->generation++; // a resized buffer starts empty: the compositor must read it again
  glBindTexture(GL_TEXTURE_2D, 0);
}


#define EGL_D3D_TEXTURE_ANGLE 0x33A3u

/**
 * Makes the canvas's drawing buffer a texture this host and ANGLE share: ANGLE renders into a
 * texture made on its own D3D11 device and this host opens the same shared texture for the canvas
 * bitmap, so a frame crosses from GL to the page as a GPU copy instead of a readback. The canvas
 * keeps its alpha as GL left it; a context without alpha is drawn opaque, as the readback made it.
 * Off unless `NATIVE_GL_TEXTURE` turns it on: a prototype until the resize and alpha behaviour of
 * every WebGL canvas has been checked against the readback. A display that can't share the texture
 * keeps the readback.
 */
static int gl_try_external(CanvasGl *g, double w, double h) {
  const char *env = getenv("NATIVE_GL_TEXTURE");
  if (env == NULL || env[0] == 0 || strcmp(env, "0") == 0) return 0;
  if (!g || eglCreatePbufferFromClientBuffer == NULL) return 0;
  if (!ensure_device() || !g_d3d) return 0;
  EGLDisplay dpy = egl_display();
  if (dpy == EGL_NO_DISPLAY) return 0;
  UINT tw = (UINT)(w > 0 ? w : 1), th = (UINT)(h > 0 ? h : 1);
  if (g->external && g->shared) {
    D3D11_TEXTURE2D_DESC now = {0};
    g->shared->GetDesc(&now);
    if (now.Width == tw && now.Height == th) return 1;
    // A canvas that changed size needs a texture of the new size.
    if (g->client != EGL_NO_SURFACE && g->client != NULL) eglDestroySurface(dpy, g->client);
    g->client = EGL_NO_SURFACE;
    if (g->ours) {
      g->ours->Release();
      g->ours = NULL;
    }
    g->shared->Release();
    g->shared = NULL;
    g->external = 0;
    g->surface = g->pbuffer;
    gl_ready(g);
  }
  D3D11_TEXTURE2D_DESC desc = {0};
  desc.Width = tw;
  desc.Height = th;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM; // the display's own visual, which ANGLE requires
  desc.SampleDesc.Count = 1;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
  // A client-buffer texture has to be made by ANGLE's own D3D11 device (EGL_ANGLE_device_d3d):
  // ask the display for it, and make the texture there.
  ID3D11Device *maker = g_d3d;
  EGLDeviceEXT angle_device = NULL;
  if (eglQueryDisplayAttribANGLE && eglQueryDeviceAttribEXT &&
      eglQueryDisplayAttribANGLE(dpy, 0x322C /* EGL_DEVICE_EXT */, (EGLAttrib *)&angle_device) &&
      angle_device != NULL) {
    EGLAttrib value = 0;
    if (eglQueryDeviceAttribEXT(angle_device, 0x33A1 /* EGL_D3D11_DEVICE_ANGLE */, &value) &&
        value != 0)
      maker = (ID3D11Device *)(INT_PTR)value;
  }
  ID3D11Texture2D *tex = NULL;
  HRESULT made = maker->CreateTexture2D(&desc, NULL, &tex);
  if (FAILED(made) || tex == NULL) {
    g->surface = g->pbuffer;
    gl_ready(g);
    return 0;
  }
  EGLSurface client = eglCreatePbufferFromClientBuffer(dpy, (EGLenum)EGL_D3D_TEXTURE_ANGLE, tex,
                                                       g_egl_config, NULL);
  if (client == EGL_NO_SURFACE) {
    tex->Release();
    g->surface = g->pbuffer;
    gl_ready(g);
    return 0;
  }
  IDXGIResource *resource = NULL;
  HANDLE handle = NULL;
  if (SUCCEEDED(tex->QueryInterface(__uuidof(IDXGIResource), (void **)&resource)) && resource) {
    resource->GetSharedHandle(&handle);
    resource->Release();
  }
  ID3D11Texture2D *ours = NULL;
  if (handle != NULL && (FAILED(g_d3d->OpenSharedResource(handle, __uuidof(ID3D11Texture2D),
                                                         (void **)&ours)) ||
                         ours == NULL)) {
    eglDestroySurface(dpy, client);
    tex->Release();
    g->surface = g->pbuffer;
    gl_ready(g);
    return 0;
  }
  if (g->client != EGL_NO_SURFACE && g->client != NULL) eglDestroySurface(dpy, g->client);
  if (g->ours) g->ours->Release();
  if (g->shared) g->shared->Release();
  g->shared = tex;
  g->ours = ours;
  g->client = client;
  g->surface = client;
  g->external = 1;
  gl_ready(g);
  return 1;
}

/** The canvas bitmap a WebGL canvas paints into: pixels written by a readback, never a draw target. */
static int gl_make_canvas_bitmap(Canvas *c, double w, double h) {
  canvas_release_bitmap(c);
  c->w = w > 0 ? floor(w) : 0;
  c->h = h > 0 ? floor(h) : 0;
  if (c->w < 1 || c->h < 1) return 0;
  if (!ensure_device() || !g_d2d) return 0;
  if (c->gl && c->gl->external && c->gl->ours) {
    IDXGISurface *surface = NULL;
    if (SUCCEEDED(c->gl->ours->QueryInterface(__uuidof(IDXGISurface), (void **)&surface)) &&
        surface != NULL) {
      // A context without alpha draws an opaque canvas, as the readback's 255 made it; with
      // alpha, the drawing buffer is premultiplied, as WebGL's is.
      D2D1_ALPHA_MODE mode = c->gl->alpha ? D2D1_ALPHA_MODE_PREMULTIPLIED : D2D1_ALPHA_MODE_IGNORE;
      D2D1_BITMAP_PROPERTIES1 shared_props = D2D1::BitmapProperties1(
          D2D1_BITMAP_OPTIONS_NONE, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, mode), 96.0f, 96.0f);
      HRESULT made = g_d2d->CreateBitmapFromDxgiSurface(surface, &shared_props, &c->bitmap);
      surface->Release();
      if (SUCCEEDED(made) && c->bitmap) return 1;
    }
    // A bitmap that can't wrap the shared texture falls back to the readback below.
    c->gl->external = 0;
  }
  D2D1_BITMAP_PROPERTIES1 props = D2D1::BitmapProperties1(
      D2D1_BITMAP_OPTIONS_NONE,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED), 96.0f, 96.0f);
  return SUCCEEDED(g_d2d->CreateBitmap(D2D1::SizeU((UINT32)c->w, (UINT32)c->h), NULL, 0, &props, &c->bitmap))
             ? 1
             : 0;
}

// Creates the canvas's GL context and drawing buffer, or resizes the buffer it has. The first
// call fixes the context attributes the drawing buffer honours. False when ANGLE is not there or
// the context could not be made, which makes getContext("webgl2") answer null.
int32_t host_gl_attach(int32_t id, double w, double h, double depth, double stencil, double antialias) {
  Canvas *c = canvas_at(id);
  if (!c) return 0;
  CanvasGl *g = c->gl;
  if (!g) {
    g = (CanvasGl *)calloc(1, sizeof(CanvasGl));
    if (!g) return 0;
    c->gl = g;
  }
  if (g->ctx == EGL_NO_CONTEXT) {
    g->depth_bits = depth != 0;
    g->stencil_bits = stencil != 0;
    g->samples = antialias != 0 ? 4 : 0;
    g->alpha = 1;
    EGLDisplay dpy = egl_display();
    if (dpy == EGL_NO_DISPLAY) return 0;
    // A context has to be current with some surface; this one is never drawn to.
    const EGLint pb[] = {0x3057 /* EGL_WIDTH */, 1, 0x3056 /* EGL_HEIGHT */, 1, EGL_NONE};
    g->surface = eglCreatePbufferSurface(dpy, g_egl_config, pb);
    g->pbuffer = g->surface;
    if (g->surface == EGL_NO_SURFACE) {
      snprintf(g_angle_why, sizeof g_angle_why, "unavailable: no pbuffer surface");
      angle_note(g_angle_why);
      return 0;
    }
    g->ctx = gl_make_context(dpy);
    if (g->ctx == EGL_NO_CONTEXT) {
      snprintf(g_angle_why, sizeof g_angle_why, "unavailable: no ES 3 context");
      angle_note(g_angle_why);
      return 0;
    }
    if (!gl_ready(g)) {
      eglDestroyContext(dpy, g->ctx);
      g->ctx = EGL_NO_CONTEXT;
      return 0;
    }
    glGenFramebuffers(1, &g->fbo);
    glGenTextures(1, &g->color);
    glGenRenderbuffers(1, &g->depth);
    glGenVertexArrays(1, &g->default_vao);
    glBindVertexArray(g->default_vao);
    if (g->samples) {
      glGenFramebuffers(1, &g->msaa_fbo);
      glGenRenderbuffers(1, &g->msaa_color);
      glGenRenderbuffers(1, &g->msaa_depth);
      GLint max_samples = 0;
      glGetIntegerv(GL_MAX_SAMPLES, &max_samples);
      if (g->samples > max_samples) g->samples = max_samples;
      if (g->samples < 1) g->samples = 0;
    }
    char renderer[256];
    angle_renderer(renderer, sizeof renderer);
    if (getenv("NATIVE_FRAME_TIMES") != NULL) fprintf(stderr, "native: webgl2 %s\n", renderer);
  }
  if (!gl_ready(g)) return 0;
  gl_alloc(g, w, h);
  gl_try_external(g, g->w, g->h);
  if (!gl_make_canvas_bitmap(c, w, h)) return 0;
  return 1;
}

// Whether the drawing buffer keeps its alpha (WebGL's `alpha` context attribute).
void host_gl_set_alpha(int32_t id, double alpha) {
  CanvasGl *g = gl_at(id);
  if (g) g->alpha = alpha != 0;
}

// Copies the drawing buffer into the canvas bitmap for the display list: GL's rows run bottom to
// top and its colours are straight, the bitmap's run top to bottom and are premultiplied BGRA.
static void gl_present_canvas(Canvas *c) {
  CanvasGl *g = c->gl;
  if (!gl_ready(g) || !c->bitmap) return;
  int w = (int)g->w, h = (int)g->h;
  if (w < 1 || h < 1) return;
  if (g->external) {
    // Resolve antialiasing into the colour texture, then copy that into the shared texture the
    // canvas bitmap wraps: two GPU copies in place of a readback, a flip and a re-upload.
    if (g->samples) {
      glBindFramebuffer(GL_READ_FRAMEBUFFER, g->msaa_fbo);
      glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g->fbo);
      glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    }
    glBindFramebuffer(GL_READ_FRAMEBUFFER, g->fbo);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
    glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    glBindFramebuffer(GL_FRAMEBUFFER, gl_draw_fbo(g));
    // The page draws the texture next: hand ANGLE's commands to the GPU first.
    glFlush();
    return;
  }
  uint8_t *px = (uint8_t *)malloc((size_t)w * h * 4);
  uint8_t *bgra = (uint8_t *)malloc((size_t)w * h * 4);
  if (!px || !bgra) {
    free(px);
    free(bgra);
    return;
  }
  // The page draws between presents, so the framebuffer it left bound has to come back.
  GLint prev_read = 0, prev_draw = 0, prev_align = 4;
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prev_read);
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prev_draw);
  glGetIntegerv(GL_PACK_ALIGNMENT, &prev_align);
  if (g->samples) {
    glBindFramebuffer(GL_READ_FRAMEBUFFER, g->msaa_fbo);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g->fbo);
    glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
  }
  glBindFramebuffer(GL_FRAMEBUFFER, g->fbo);
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)prev_read);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)prev_draw);
  glPixelStorei(GL_PACK_ALIGNMENT, prev_align);
  for (int y = 0; y < h; y++) {
    const uint8_t *src = px + (size_t)(h - 1 - y) * w * 4;
    uint8_t *row = bgra + (size_t)y * w * 4;
    for (int x = 0; x < w; x++) {
      unsigned a = g->alpha ? src[x * 4 + 3] : 255u;
      row[x * 4 + 0] = (uint8_t)((src[x * 4 + 2] * a + 127) / 255);
      row[x * 4 + 1] = (uint8_t)((src[x * 4 + 1] * a + 127) / 255);
      row[x * 4 + 2] = (uint8_t)((src[x * 4 + 0] * a + 127) / 255);
      row[x * 4 + 3] = (uint8_t)a;
    }
  }
  D2D1_RECT_U rect = D2D1::RectU(0, 0, (UINT32)w, (UINT32)h);
  c->bitmap->CopyFromMemory(&rect, bgra, (UINT32)w * 4);
  free(px);
  free(bgra);
}

/** The replay's hook: a canvas with a WebGL context shows a readback of its drawing buffer. */
static void gl_present_canvas_for(int32_t id) {
  Canvas *c = canvas_at(id);
  if (c && c->gl) gl_present_canvas(c);
}

static void gl_resize_canvas(int32_t id, double w, double h) {
  Canvas *c = canvas_at(id);
  if (c && c->gl) host_gl_attach(id, w, h, c->gl->depth_bits, c->gl->stencil_bits, c->gl->samples);
}

// A decoded image as RGBA rows for a texture upload: the host keeps it as a premultiplied BGRA
// bitmap, and WebGL's unpack options decide what the texture gets.
static uint8_t *image_rgba(const int32_t image, const int flip, const int premultiply,
                           GLsizei *out_w, GLsizei *out_h) {
  if (image < 0 || image >= g_image_count) return NULL;
  Image *img = &g_images[image];
  if (!img->px || img->w <= 0 || img->h <= 0) return NULL;
  size_t w = (size_t)img->w, h = (size_t)img->h;
  uint8_t *data = (uint8_t *)malloc(w * h * 4);
  if (!data) return NULL;
  for (size_t y = 0; y < h; y++) memcpy(data + y * w * 4, img->px + y * (size_t)img->stride, w * 4);
  size_t count = w * h;
  for (size_t i = 0; i < count; i++) {
    uint8_t *p = data + i * 4;
    unsigned a = p[3];
    unsigned b = p[0], g_ = p[1], r = p[2];
    // The bitmap's pixels are premultiplied; UNPACK_PREMULTIPLY_ALPHA_WEBGL=false asks for the
    // file's own straight values, so undo the multiplication.
    if (!premultiply && a != 0 && a != 255) {
      r = (unsigned)((r * 255u + a / 2) / a);
      g_ = (unsigned)((g_ * 255u + a / 2) / a);
      b = (unsigned)((b * 255u + a / 2) / a);
      if (r > 255) r = 255;
      if (g_ > 255) g_ = 255;
      if (b > 255) b = 255;
    }
    p[0] = (uint8_t)r;
    p[1] = (uint8_t)g_;
    p[2] = (uint8_t)b;
  }
  // GL takes the first row as texture row 0, which is the image's bottom row; flipping the rows is
  // what UNPACK_FLIP_Y_WEBGL does.
  if (flip && h > 1) {
    uint8_t *tmp = (uint8_t *)malloc(w * 4);
    if (tmp) {
      for (size_t y = 0; y < h / 2; y++) {
        uint8_t *top = data + y * w * 4;
        uint8_t *bottom = data + (h - 1 - y) * w * 4;
        memcpy(tmp, top, w * 4);
        memcpy(top, bottom, w * 4);
        memcpy(bottom, tmp, w * 4);
      }
      free(tmp);
    }
  }
  *out_w = (GLsizei)w;
  *out_h = (GLsizei)h;
  return data;
}

void host_gl_tex_image_2d_from_image(int32_t id, double target, double level, double internal,
                                     int32_t image, int32_t flip, int32_t premultiply) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  GLsizei w = 0, h = 0;
  uint8_t *data = image_rgba(image, flip != 0, premultiply != 0, &w, &h);
  if (!data) return;
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexImage2D((GLenum)target, (GLint)level, (GLint)internal, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, data);
  free(data);
}

void host_gl_tex_sub_image_2d_from_image(int32_t id, double target, double level, double x, double y,
                                         int32_t image, int32_t flip, int32_t premultiply) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  GLsizei w = 0, h = 0;
  uint8_t *data = image_rgba(image, flip != 0, premultiply != 0, &w, &h);
  if (!data) return;
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexSubImage2D((GLenum)target, (GLint)level, (GLint)x, (GLint)y, w, h, GL_RGBA, GL_UNSIGNED_BYTE, data);
  free(data);
}

// The page's programs are GLSL ES 3.00 already, which is the language of the context.
void host_gl_shader_source(int32_t id, double shader, const char *src) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glShaderSource((GLuint)shader, 1, &src, NULL);
}

int32_t host_gl_create_buffer(int32_t id) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLuint b = 0;
  glGenBuffers(1, &b);
  return (int32_t)b;
}

int32_t host_gl_create_texture(int32_t id) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLuint t = 0;
  glGenTextures(1, &t);
  return (int32_t)t;
}

int32_t host_gl_create_framebuffer(int32_t id) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLuint f = 0;
  glGenFramebuffers(1, &f);
  return (int32_t)f;
}

int32_t host_gl_create_renderbuffer(int32_t id) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLuint r = 0;
  glGenRenderbuffers(1, &r);
  return (int32_t)r;
}

int32_t host_gl_create_program(int32_t id) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  return (int32_t)glCreateProgram();
}

int32_t host_gl_create_shader(int32_t id, double type) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  return (int32_t)glCreateShader((GLenum)type);
}

int32_t host_gl_create_vertex_array(int32_t id) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLuint v = 0;
  glGenVertexArrays(1, &v);
  return (int32_t)v;
}

// kind: 0 buffer, 1 texture, 2 framebuffer, 3 renderbuffer, 4 program, 5 shader, 6 vertex array.

void host_gl_delete_object(int32_t id, double kind, double obj) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  GLuint o = (GLuint)obj;
  switch ((int)kind) {
    case 0: glDeleteBuffers(1, &o); break;
    case 1: glDeleteTextures(1, &o); break;
    case 2: glDeleteFramebuffers(1, &o); break;
    case 3: glDeleteRenderbuffers(1, &o); break;
    case 4: glDeleteProgram(o); break;
    case 5: glDeleteShader(o); break;
    case 6: glDeleteVertexArrays(1, &o); break;
  }
}

// Buffers

void host_gl_bind_buffer(int32_t id, double target, double buffer) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBindBuffer((GLenum)target, (GLuint)buffer);
}

void host_gl_buffer_data(int32_t id, double target, double usage, const uint8_t *data, size_t n) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBufferData((GLenum)target, (GLsizeiptr)n, data, (GLenum)usage);
}

void host_gl_buffer_data_size(int32_t id, double target, double size, double usage) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBufferData((GLenum)target, (GLsizeiptr)size, NULL, (GLenum)usage);
}

void host_gl_buffer_sub_data(int32_t id, double target, double offset, const uint8_t *data, size_t n) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBufferSubData((GLenum)target, (GLintptr)offset, (GLsizeiptr)n, data);
}

// Textures

void host_gl_active_texture(int32_t id, double unit) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glActiveTexture((GLenum)unit);
}

void host_gl_bind_texture(int32_t id, double target, double texture) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBindTexture((GLenum)target, (GLuint)texture);
}

void host_gl_tex_image_2d(int32_t id, double target, double level, double internal, double w, double h,
                          double border, double format, double type, const uint8_t *data, size_t n) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexImage2D((GLenum)target, (GLint)level, (GLint)internal, (GLsizei)w, (GLsizei)h, (GLint)border,
               (GLenum)format, (GLenum)type, n ? data : NULL);
}

void host_gl_tex_image_2d_null(int32_t id, double target, double level, double internal, double w, double h,
                               double border, double format, double type) {
  host_gl_tex_image_2d(id, target, level, internal, w, h, border, format, type, NULL, 0);
}

void host_gl_tex_image_3d(int32_t id, double target, double level, double internal, double w, double h, double depth,
                          double border, double format, double type, const uint8_t *data, size_t n) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexImage3D((GLenum)target, (GLint)level, (GLint)internal, (GLsizei)w, (GLsizei)h, (GLsizei)depth,
               (GLint)border, (GLenum)format, (GLenum)type, n ? data : NULL);
}

void host_gl_tex_sub_image_2d(int32_t id, double target, double level, double x, double y, double w, double h,
                              double format, double type, const uint8_t *data, size_t n) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexSubImage2D((GLenum)target, (GLint)level, (GLint)x, (GLint)y, (GLsizei)w, (GLsizei)h, (GLenum)format,
                  (GLenum)type, n ? data : NULL);
}

void host_gl_tex_storage_2d(int32_t id, double target, double levels, double internal, double w, double h) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glTexStorage2D((GLenum)target, (GLsizei)levels, (GLenum)internal, (GLsizei)w, (GLsizei)h);
}

void host_gl_tex_parameter_i(int32_t id, double target, double pname, double param) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glTexParameteri((GLenum)target, (GLenum)pname, (GLint)param);
}

void host_gl_tex_parameter_f(int32_t id, double target, double pname, double param) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glTexParameterf((GLenum)target, (GLenum)pname, (GLfloat)param);
}

void host_gl_generate_mipmap(int32_t id, double target) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glGenerateMipmap((GLenum)target);
}

void host_gl_pixel_storei(int32_t id, double pname, double param) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glPixelStorei((GLenum)pname, (GLint)param);
}

// Shaders and programs

void host_gl_compile_shader(int32_t id, double shader) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glCompileShader((GLuint)shader);
}

double host_gl_get_shader_parameter(int32_t id, double shader, double pname) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLint v = 0;
  glGetShaderiv((GLuint)shader, (GLenum)pname, &v);
  return v;
}

void host_gl_get_shader_info_log(int32_t id, double shader, cb_t cb) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  char log[8192];
  GLsizei n = 0;
  glGetShaderInfoLog((GLuint)shader, sizeof log, &n, log);
  cb((const uint8_t *)log, (size_t)n);
}

void host_gl_attach_shader(int32_t id, double program, double shader) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glAttachShader((GLuint)program, (GLuint)shader);
}

void host_gl_detach_shader(int32_t id, double program, double shader) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDetachShader((GLuint)program, (GLuint)shader);
}

void host_gl_bind_attrib_location(int32_t id, double program, double index, const char *name) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBindAttribLocation((GLuint)program, (GLuint)index, name);
}

void host_gl_link_program(int32_t id, double program) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glLinkProgram((GLuint)program);
}

void host_gl_use_program(int32_t id, double program) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glUseProgram((GLuint)program);
}

double host_gl_get_program_parameter(int32_t id, double program, double pname) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLint v = 0;
  glGetProgramiv((GLuint)program, (GLenum)pname, &v);
  return v;
}

void host_gl_get_program_info_log(int32_t id, double program, cb_t cb) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  char log[8192];
  GLsizei n = 0;
  glGetProgramInfoLog((GLuint)program, sizeof log, &n, log);
  cb((const uint8_t *)log, (size_t)n);
}

double host_gl_get_attrib_location(int32_t id, double program, const char *name) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return -1;
  return glGetAttribLocation((GLuint)program, name);
}

double host_gl_get_uniform_location(int32_t id, double program, const char *name) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return -1;
  return glGetUniformLocation((GLuint)program, name);
}

double host_gl_get_uniform_block_index(int32_t id, double program, const char *name) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return -1;
  return glGetUniformBlockIndex((GLuint)program, name);
}

// The active uniform and attribute tables, read one entry at a time: the name through a callback,
// the type and size as numbers.

void host_gl_active_uniform_name(int32_t id, double program, double index, cb_t name) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  char buf[512];
  GLsizei len = 0;
  GLint size = 0;
  GLenum type = 0;
  glGetActiveUniform((GLuint)program, (GLuint)index, sizeof buf, &len, &size, &type, buf);
  name((const uint8_t *)buf, (size_t)len);
}

double host_gl_active_uniform_type(int32_t id, double program, double index) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  char buf[1];
  GLsizei len = 0;
  GLint size = 0;
  GLenum type = 0;
  glGetActiveUniform((GLuint)program, (GLuint)index, 0, &len, &size, &type, buf);
  return type;
}

double host_gl_active_uniform_size(int32_t id, double program, double index) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  char buf[1];
  GLsizei len = 0;
  GLint size = 0;
  GLenum type = 0;
  glGetActiveUniform((GLuint)program, (GLuint)index, 0, &len, &size, &type, buf);
  return size;
}

void host_gl_active_attrib_name(int32_t id, double program, double index, cb_t name) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  char buf[512];
  GLsizei len = 0;
  GLint size = 0;
  GLenum type = 0;
  glGetActiveAttrib((GLuint)program, (GLuint)index, sizeof buf, &len, &size, &type, buf);
  name((const uint8_t *)buf, (size_t)len);
}

double host_gl_active_attrib_type(int32_t id, double program, double index) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  char buf[1];
  GLsizei len = 0;
  GLint size = 0;
  GLenum type = 0;
  glGetActiveAttrib((GLuint)program, (GLuint)index, 0, &len, &size, &type, buf);
  return type;
}

double host_gl_active_attrib_size(int32_t id, double program, double index) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  char buf[1];
  GLsizei len = 0;
  GLint size = 0;
  GLenum type = 0;
  glGetActiveAttrib((GLuint)program, (GLuint)index, 0, &len, &size, &type, buf);
  return size;
}

// Uniforms. One call covers every vector shape: `kind` names it (1..4 float, 5..8 int, 9..12
// unsigned), and the count follows from the byte length.

void host_gl_uniform1f(int32_t id, double location, double x) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glUniform1f((GLint)location, (GLfloat)x);
}

void host_gl_uniform1i(int32_t id, double location, double x) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glUniform1i((GLint)location, (GLint)x);
}

void host_gl_uniform(int32_t id, double location, double kind, const uint8_t *data, size_t n) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  int k = (int)kind;
  int comps = ((k - 1) % 4) + 1;
  int count = (int)(n / (4 * comps));
  const GLfloat *f = (const GLfloat *)data;
  const GLint *i = (const GLint *)data;
  const GLuint *u = (const GLuint *)data;
  switch (k) {
    case 1: glUniform1fv((GLint)location, count, f); break;
    case 2: glUniform2fv((GLint)location, count, f); break;
    case 3: glUniform3fv((GLint)location, count, f); break;
    case 4: glUniform4fv((GLint)location, count, f); break;
    case 5: glUniform1iv((GLint)location, count, i); break;
    case 6: glUniform2iv((GLint)location, count, i); break;
    case 7: glUniform3iv((GLint)location, count, i); break;
    case 8: glUniform4iv((GLint)location, count, i); break;
    case 9: glUniform1uiv((GLint)location, count, u); break;
    case 10: glUniform2uiv((GLint)location, count, u); break;
    case 11: glUniform3uiv((GLint)location, count, u); break;
    case 12: glUniform4uiv((GLint)location, count, u); break;
  }
}

// `dims` is 2, 3 or 4 for the square matrix shape.

void host_gl_uniform_matrix(int32_t id, double location, double dims, double transpose, const uint8_t *data, size_t n) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  int d = (int)dims;
  int count = (int)(n / (4 * d * d));
  const GLfloat *m = (const GLfloat *)data;
  switch (d) {
    case 2: glUniformMatrix2fv((GLint)location, count, (GLboolean)transpose, m); break;
    case 3: glUniformMatrix3fv((GLint)location, count, (GLboolean)transpose, m); break;
    case 4: glUniformMatrix4fv((GLint)location, count, (GLboolean)transpose, m); break;
  }
}

// Vertex attributes

void host_gl_bind_vertex_array(int32_t id, double array) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBindVertexArray((GLuint)array == 0 ? g->default_vao : (GLuint)array);
}

void host_gl_enable_vertex_attrib_array(int32_t id, double index) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glEnableVertexAttribArray((GLuint)index);
}

void host_gl_disable_vertex_attrib_array(int32_t id, double index) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDisableVertexAttribArray((GLuint)index);
}

void host_gl_vertex_attrib_pointer(int32_t id, double index, double size, double type, double normalized,
                                   double stride, double offset) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glVertexAttribPointer((GLuint)index, (GLint)size, (GLenum)type, (GLboolean)normalized, (GLsizei)stride,
                        (const void *)(GLintptr)offset);
}

void host_gl_vertex_attrib_i_pointer(int32_t id, double index, double size, double type, double stride, double offset) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glVertexAttribIPointer((GLuint)index, (GLint)size, (GLenum)type, (GLsizei)stride, (const void *)(GLintptr)offset);
}

void host_gl_vertex_attrib_divisor(int32_t id, double index, double divisor) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glVertexAttribDivisor((GLuint)index, (GLuint)divisor);
}

// A constant value for an attribute no buffer feeds: `kind` is the float vector length, 1 to 4.

void host_gl_vertex_attrib(int32_t id, double index, double kind, const uint8_t *data, size_t n) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  const GLfloat *v = (const GLfloat *)data;
  switch ((int)kind) {
    case 1: glVertexAttrib1fv((GLuint)index, v); break;
    case 2: glVertexAttrib2fv((GLuint)index, v); break;
    case 3: glVertexAttrib3fv((GLuint)index, v); break;
    case 4: glVertexAttrib4fv((GLuint)index, v); break;
  }
}

// Framebuffers. Binding 0 means the canvas's drawing buffer, as in a browser.

void host_gl_bind_framebuffer(int32_t id, double target, double framebuffer) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBindFramebuffer((GLenum)target, (GLuint)framebuffer == 0 ? gl_draw_fbo(g) : (GLuint)framebuffer);
}

void host_gl_bind_renderbuffer(int32_t id, double target, double renderbuffer) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBindRenderbuffer((GLenum)target, (GLuint)renderbuffer);
}

void host_gl_framebuffer_texture_2d(int32_t id, double target, double attachment, double tex_target,
                                    double texture, double level) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glFramebufferTexture2D((GLenum)target, (GLenum)attachment, (GLenum)tex_target, (GLuint)texture, (GLint)level);
}

void host_gl_framebuffer_renderbuffer(int32_t id, double target, double attachment, double rb_target,
                                      double renderbuffer) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glFramebufferRenderbuffer((GLenum)target, (GLenum)attachment, (GLenum)rb_target, (GLuint)renderbuffer);
}

void host_gl_renderbuffer_storage(int32_t id, double target, double format, double w, double h) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glRenderbufferStorage((GLenum)target, (GLenum)format, (GLsizei)w, (GLsizei)h);
}

double host_gl_check_framebuffer_status(int32_t id, double target) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  return glCheckFramebufferStatus((GLenum)target);
}

// The list arrives as 32-bit ids in a byte view, which is how an array crosses the FFI.

void host_gl_draw_buffers(int32_t id, double count, const uint8_t *buffers, size_t bytes) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  int n = (int)count;
  if (n < 0) n = 0;
  if (n > 32) n = 32;
  if (bytes < (size_t)n * 4) n = (int)(bytes / 4);
  GLenum list[32];
  const uint32_t *ids = (const uint32_t *)buffers;
  for (int i = 0; i < n; i++) {
    // The canvas's default framebuffer is a texture-backed FBO here, so WebGL's BACK is its
    // one colour attachment rather than a real back buffer.
    list[i] = (GLenum)ids[i] == GL_BACK ? GL_COLOR_ATTACHMENT0 : (GLenum)ids[i];
  }
  glDrawBuffers(n, list);
}

// Drawing

void host_gl_draw_arrays(int32_t id, double mode, double first, double count) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDrawArrays((GLenum)mode, (GLint)first, (GLsizei)count);
  g->generation++;
}

void host_gl_draw_elements(int32_t id, double mode, double count, double type, double offset) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDrawElements((GLenum)mode, (GLsizei)count, (GLenum)type, (const void *)(GLintptr)offset);
  g->generation++;
}

void host_gl_draw_arrays_instanced(int32_t id, double mode, double first, double count, double instances) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDrawArraysInstanced((GLenum)mode, (GLint)first, (GLsizei)count, (GLsizei)instances);
  g->generation++;
}

void host_gl_draw_elements_instanced(int32_t id, double mode, double count, double type, double offset, double instances) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDrawElementsInstanced((GLenum)mode, (GLsizei)count, (GLenum)type, (const void *)(GLintptr)offset, (GLsizei)instances);
  g->generation++;
}

// Fixed-function state. Each call sets one piece, as the WebGL method does.

void host_gl_enable(int32_t id, double cap) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glEnable((GLenum)cap);
}

void host_gl_disable(int32_t id, double cap) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDisable((GLenum)cap);
}

void host_gl_clear(int32_t id, double mask) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glClear((GLbitfield)mask);
  if (mask != 0) g->generation++;
}

void host_gl_clear_color(int32_t id, double r, double g_, double b, double a) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glClearColor((GLfloat)r, (GLfloat)g_, (GLfloat)b, (GLfloat)a);
}

void host_gl_clear_depth(int32_t id, double depth) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glClearDepthf((GLfloat)depth);
}

void host_gl_clear_stencil(int32_t id, double s) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glClearStencil((GLint)s);
}

void host_gl_color_mask(int32_t id, double r, double g_, double b, double a) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glColorMask(r != 0, g_ != 0, b != 0, a != 0);
}

void host_gl_depth_mask(int32_t id, double flag) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDepthMask(flag != 0);
}

void host_gl_stencil_mask(int32_t id, double mask) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glStencilMask((GLuint)mask);
}

void host_gl_cull_face(int32_t id, double mode) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glCullFace((GLenum)mode);
}

void host_gl_front_face(int32_t id, double mode) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glFrontFace((GLenum)mode);
}

void host_gl_depth_func(int32_t id, double func) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDepthFunc((GLenum)func);
}

void host_gl_depth_range(int32_t id, double z_near, double z_far) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDepthRangef((GLfloat)z_near, (GLfloat)z_far);
}

void host_gl_blend_func(int32_t id, double src, double dst) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBlendFunc((GLenum)src, (GLenum)dst);
}

void host_gl_blend_func_separate(int32_t id, double src_rgb, double dst_rgb, double src_alpha, double dst_alpha) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBlendFuncSeparate((GLenum)src_rgb, (GLenum)dst_rgb, (GLenum)src_alpha, (GLenum)dst_alpha);
}

void host_gl_blend_equation(int32_t id, double mode) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBlendEquation((GLenum)mode);
}

void host_gl_blend_equation_separate(int32_t id, double rgb, double alpha) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBlendEquationSeparate((GLenum)rgb, (GLenum)alpha);
}

void host_gl_blend_color(int32_t id, double r, double g_, double b, double a) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBlendColor((GLfloat)r, (GLfloat)g_, (GLfloat)b, (GLfloat)a);
}

void host_gl_polygon_offset(int32_t id, double factor, double units) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glPolygonOffset((GLfloat)factor, (GLfloat)units);
}

void host_gl_stencil_func(int32_t id, double func, double ref, double mask) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glStencilFunc((GLenum)func, (GLint)ref, (GLuint)mask);
}

void host_gl_stencil_op(int32_t id, double fail, double zfail, double zpass) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glStencilOp((GLenum)fail, (GLenum)zfail, (GLenum)zpass);
}

void host_gl_viewport(int32_t id, double x, double y, double w, double h) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glViewport((GLint)x, (GLint)y, (GLsizei)w, (GLsizei)h);
}

void host_gl_scissor(int32_t id, double x, double y, double w, double h) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glScissor((GLint)x, (GLint)y, (GLsizei)w, (GLsizei)h);
}

void host_gl_line_width(int32_t id, double width) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glLineWidth((GLfloat)width);
}

void host_gl_finish(int32_t id) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glFinish();
}

void host_gl_flush(int32_t id) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  glFlush();
}

// Queries

double host_gl_get_parameter_int(int32_t id, double pname) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLint v = 0;
  glGetIntegerv((GLenum)pname, &v);
  return v;
}

double host_gl_get_parameter_float(int32_t id, double pname) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLfloat v = 0;
  glGetFloatv((GLenum)pname, &v);
  return v;
}

void host_gl_get_parameter_ints(int32_t id, double pname, uint8_t *out, size_t n) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g) || n < 4) return;
  glGetIntegerv((GLenum)pname, (GLint *)out);
}

void host_gl_get_parameter_floats(int32_t id, double pname, uint8_t *out, size_t n) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g) || n < 4) return;
  glGetFloatv((GLenum)pname, (GLfloat *)out);
}

void host_gl_get_parameter_string(int32_t id, double pname, cb_t cb) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  const GLubyte *s = glGetString((GLenum)pname);
  if (s) cb(s, strlen((const char *)s));
}

// A core context has no GL_EXTENSIONS string: the list is counted and fetched by index.

int32_t host_gl_extension_count(int32_t id) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLint count = 0;
  glGetIntegerv(GL_NUM_EXTENSIONS, &count);
  return count;
}

void host_gl_extension_string(int32_t id, double index, cb_t cb) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  const GLubyte *s = glGetStringi(GL_EXTENSIONS, (GLuint)index);
  if (s) cb(s, strlen((const char *)s));
}

double host_gl_get_error(int32_t id) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  return glGetError();
}

void host_gl_read_pixels(int32_t id, double x, double y, double w, double h, uint8_t *out, size_t n) {
  CanvasGl *g = gl_at(id);
  if (!gl_ready(g)) return;
  GLint prev_read = 0, prev_draw = 0, prev_align = 4;
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prev_read);
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prev_draw);
  glGetIntegerv(GL_PACK_ALIGNMENT, &prev_align);
  // Reading the default framebuffer reads what the page has drawn so far, so the multisampled
  // buffer behind it is resolved first.
  if (g->samples && (GLuint)prev_read == g->msaa_fbo) {
    glBindFramebuffer(GL_READ_FRAMEBUFFER, g->msaa_fbo);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g->fbo);
    glBlitFramebuffer(0, 0, (GLsizei)g->w, (GLsizei)g->h, 0, 0, (GLsizei)g->w, (GLsizei)g->h,
                      GL_COLOR_BUFFER_BIT, GL_NEAREST);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, g->fbo);
  }
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glReadPixels((GLint)x, (GLint)y, (GLsizei)w, (GLsizei)h, GL_RGBA, GL_UNSIGNED_BYTE, out);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)prev_read);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)prev_draw);
  glPixelStorei(GL_PACK_ALIGNMENT, prev_align);
}

}  // extern "C"
