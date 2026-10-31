#pragma once

#include <windows.h>

#include <stddef.h>
#include <stdint.h>

#include <memory>

/*
 * The Win32 window/input host deliberately sees the canvas compositor
 * through this small interface. Direct2D/DirectWrite objects and the
 * retained binary-packet model stay in gpu_surface_renderer.cpp, while
 * webview2_host.cpp owns only one shared renderer and one surface per
 * gpu_surface HWND.
 */

struct WindowsGpuPacketPresent {
    double surface_width = 0;
    double surface_height = 0;
    double scale = 1;
    uint8_t clear_rgba[4] = {};
    bool requires_render = false;
    size_t command_count = 0;
    size_t unsupported_command_count = 0;
    bool representable = false;
    const uint8_t *packet = nullptr;
    size_t packet_len = 0;
};

constexpr size_t kWindowsGpuDirtyRectCap = 8;

struct WindowsGpuPresentInfo {
    bool did_render = false;
    bool nonblank = false;
    uint32_t sample_color = 0;
    uint64_t decode_ns = 0;
    uint64_t draw_ns = 0;
    size_t dirty_rect_count = 0;
    RECT dirty_rects[kWindowsGpuDirtyRectCap] = {};
};

class WindowsGpuSurface {
public:
    virtual ~WindowsGpuSurface() = default;

    /* 1 accepted, 0 refused (runtime resync/pixel fallback), -1 device
     * presentation failure. The packet is bounds-checked before any
     * retained state or GPU content is mutated. */
    virtual int present(const WindowsGpuPacketPresent &present, WindowsGpuPresentInfo *info) = 0;

    /* Paint the retained GPU bitmap into the exact invalid rectangles.
     * The Win32 update region may remain disjoint after several packet
     * invalidations; keeping that shape avoids turning two small patches
     * into one window-sized copy. false means the Direct2D resource domain
     * was lost and the next packet must be a full resync. */
    virtual bool paint(const RECT *paint_rects, size_t paint_rect_count) = 0;

    /* A software fallback became the glass baseline. Drop both GPU
     * content and retained packet state so a later packet must resync. */
    virtual void abandonContent() = 0;

    virtual bool hasContent() const = 0;
    /* Read the actual opaque backing pixel at a logical point. This is an
     * explicit synchronization point and is reserved for the hidden-titlebar
     * caption sample; ordinary presentation diagnostics stay on the retained
     * command heuristic below. */
    virtual bool readColorAt(double logical_x, double logical_y, uint32_t *color) = 0;
    virtual uint32_t representativeColorAt(double logical_x, double logical_y) const = 0;
};

class WindowsGpuRenderer {
public:
    virtual ~WindowsGpuRenderer() = default;

    virtual std::shared_ptr<WindowsGpuSurface> createSurface(HWND hwnd) = 0;
    virtual bool uploadImage(uint64_t id, uint32_t width, uint32_t height, const uint8_t *rgba, size_t rgba_len) = 0;
    virtual bool removeImage(uint64_t id) = 0;

    /* A token makes replacement/unregister ordering safe when multiple
     * runtimes reuse an id, matching the platform service contract. */
    virtual bool registerFont(uint64_t id, const uint8_t *ttf, size_t ttf_len, uint64_t *token) = 0;
    virtual bool unregisterFont(uint64_t id, uint64_t token) = 0;
};

std::shared_ptr<WindowsGpuRenderer> createWindowsGpuRenderer();
