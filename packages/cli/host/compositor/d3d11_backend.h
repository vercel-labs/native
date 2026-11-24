// The D3D11 backend, for the window host on Windows. The name keeps clear of the platform's own
// <d3d11.h>, so both can be included by one file.

#ifndef NATIVE_COMPOSITOR_D3D11_H
#define NATIVE_COMPOSITOR_D3D11_H

#include "backend.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Creates a backend on `device`, an ID3D11Device the host already made (its hardware device, or
 * WARP). Textures are BGRA8 textures on that device, so a chunk the host rasters through
 * Direct2D into a texture's surface composites without a copy. Destroy it through its vtable.
 * Answers NULL when the device is missing or a pipeline fails to build.
 */
CompBackend *comp_d3d11_backend(void *device);

/**
 * The swap chain a pass into the backend's own drawable presents: `swap`, an IDXGISwapChain1 the
 * host made for its window. A pass with target -1 draws the swap chain's back buffer, and
 * `present` shows it paced to the display.
 */
void comp_d3d11_set_swap_chain(CompBackend *b, void *swap);

/** The D3D11 texture behind a texture id, borrowed; NULL for an id the backend doesn't hold. */
void *comp_d3d11_texture(CompBackend *b, int tex);

/** Whether the device's work was lost since the backend was made, so the host must rebuild. */
int comp_d3d11_device_lost(CompBackend *b);

/** Whether the last pass bound a target it could draw into. */
int comp_d3d11_has_target(CompBackend *b);

#ifdef __cplusplus
}
#endif

#endif
