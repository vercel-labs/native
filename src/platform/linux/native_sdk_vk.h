/* Vulkan GPU-surface presenter for the Linux host.
 *
 * The macOS host owns a Metal renderer that presents the canvas texture to a
 * CAMetalLayer via a full-screen textured quad (appkit_host.m,
 * ensureCanvasPresenter). This is the Linux analog: an SDK-owned Vulkan
 * renderer that presents the canvas image to a swapchain via the same
 * full-screen-quad pipeline — skipping GSK entirely, exactly like Metal skips
 * AppKit's own drawing.
 *
 * The swapchain rides a native surface the compositor scans out directly:
 *   - Wayland: a wl_subsurface for the canvas rect (VK_KHR_wayland_surface)
 *   - X11:     a child InputOutput window     (VK_KHR_xlib_surface)
 * These are the two platform surface backends the GpuSurfaceBackend enum names
 * `.wayland` / `.x11`. Both drive the identical renderer; only surface creation
 * differs. When neither is available (no Vulkan, headless, unknown backend),
 * every entry point below returns failure and the host keeps its GSK path.
 *
 * Rasterization stays where Metal keeps it: the runtime's reference renderer
 * hands straight-alpha RGBA8 (the pixel present path), which we upload into the
 * canvas VkImage and blit. GPU compositing of individual packet commands (the
 * Metal composite pipeline) is deliberately not reimplemented here — the
 * presenter is fed pixels, matching Metal's raw-pixel drawable mode. */

#ifndef NATIVE_SDK_VK_H
#define NATIVE_SDK_VK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct _GdkSurface GdkSurface;

/* Host-global Vulkan objects (instance, device, queue, pipeline). Created once,
 * lazily, on the first gpu_surface view. Returns NULL when Vulkan is
 * unavailable — the caller then keeps the GSK path for every view. */
typedef struct native_sdk_vk_context native_sdk_vk_context_t;
native_sdk_vk_context_t *native_sdk_vk_context_create(void);
void native_sdk_vk_context_destroy(native_sdk_vk_context_t *ctx);

/* Which surface backend a view ended up on — mirrors GpuSurfaceBackend so the
 * frame event can report the truthful active path. */
typedef enum {
    NATIVE_SDK_VK_BACKEND_NONE = 0,
    NATIVE_SDK_VK_BACKEND_WAYLAND = 1,
    NATIVE_SDK_VK_BACKEND_X11 = 2,
} native_sdk_vk_backend_t;

/* A per-gpu_surface-view renderer: owns the native child surface, its
 * VkSurfaceKHR + swapchain, the canvas image, and per-frame sync. `gdk_surface`
 * is the toplevel window's surface (from gtk_native_get_surface); x/y/w/h are
 * the canvas widget's rect in surface-local logical coordinates; scale is the
 * device pixel ratio. Returns NULL if no Vulkan surface backend applies — the
 * caller keeps GSK for this view. */
typedef struct native_sdk_vk_view native_sdk_vk_view_t;
native_sdk_vk_view_t *native_sdk_vk_view_create(native_sdk_vk_context_t *ctx, GdkSurface *gdk_surface, int x, int y, int width, int height, double scale);
void native_sdk_vk_view_destroy(native_sdk_vk_view_t *view);

/* Reposition/resize the child surface + swapchain to a new widget rect/scale
 * (from size-allocate). Safe to call every allocation; a no-op when unchanged. */
void native_sdk_vk_view_set_geometry(native_sdk_vk_view_t *view, int x, int y, int width, int height, double scale);

/* Present one frame of straight-alpha RGBA8 (width*height*4 bytes, row-major)
 * to the swapchain via the full-screen presenter. Returns 1 on present, 0 on a
 * recoverable miss (swapchain out of date — recreated for next frame). */
int native_sdk_vk_view_present_pixels(native_sdk_vk_view_t *view, const uint8_t *rgba8, uint32_t width, uint32_t height);

native_sdk_vk_backend_t native_sdk_vk_view_backend(const native_sdk_vk_view_t *view);

#ifdef __cplusplus
}
#endif

#endif /* NATIVE_SDK_VK_H */
