// The Metal backend, for the window host on macOS.

#ifndef NATIVE_COMPOSITOR_METAL_H
#define NATIVE_COMPOSITOR_METAL_H

#include "backend.h"

/**
 * Creates a Metal backend on the system's default device; destroy it through its vtable. Answers
 * NULL when the machine has no Metal device, or a pipeline fails to build.
 */
CompBackend *comp_metal_backend(void);

/** The same, drawing into `layer`'s drawable when a pass names no target. Takes a CAMetalLayer. */
CompBackend *comp_metal_backend_for_layer(void *layer);

/**
 * Whether the backend can composite a mask the walk split (see comp_walk_mask_split): it has the
 * pipeline that draws a content texture through a mask image's alpha.
 */
int mt_mask_composite_available(CompBackend *backend);

/** mt_tex_blur over texture ids, for a host that keeps its surfaces by slot. */
int mt_tex_blur_slots(CompBackend *backend, int src, int tmp, int dst, double sigma, int taps);

/** Starts a pass into surface `target`, cleared to transparent black, that the host draws a
 *  mask's image and content into with mt_surface_draw and commits with mt_surface_end. */
void mt_surface_begin(CompBackend *backend, int target, int w, int h);
/** Draws `tex`'s `src` rectangle into the open surface, as a quad is drawn into a frame. */
void mt_surface_draw(CompBackend *backend, int tex, CompRect src, const CompMatrix *matrix,
                     float opacity, const CompRect *clip);
/** Draws the content through the mask's alpha into the open surface, rounding the product to the
 *  surface's eight bits before the frame blends it. */
int mt_surface_draw_masked(CompBackend *backend, int content, int mask, CompRect src,
                           const CompMatrix *matrix, float opacity);
/** Ends the open surface pass and commits it. */
void mt_surface_end(CompBackend *backend);

/**
 * Draws texture `content`'s `src` rectangle multiplied by texture `mask`'s alpha, the two sampled
 * over the same rectangle, then composited as a plain quad is. Answers 0 when the backend has no
 * mask pipeline or either texture is missing.
 */
int mt_draw_quad_masked(CompBackend *backend, int content, int mask, CompRect src,
                        const CompMatrix *matrix, float opacity, const CompRect *clip);

#ifdef __OBJC__
@class MTLTexture;
/**
 * Blurs `src` into `dst` with a separable Gaussian: the horizontal pass writes `tmp`, the vertical
 * one `dst`. `sigma` is in texels, `taps` how far each side of a texel the kernel reaches.
 * Answers 0 when the backend has no blur pipeline or a texture is missing.
 */
int mt_tex_blur(CompBackend *backend, id<MTLTexture> src, id<MTLTexture> tmp, id<MTLTexture> dst,
                double sigma, int taps);
#endif

#endif
