// The interface a compositor backend draws through. A backend owns textures (rastered layers and
// tiles), passes that draw into a target, and the quad draws that composite a layer into one. The
// software backend draws with Cairo; a Metal or EGL backend implements the same table.

#ifndef NATIVE_COMPOSITOR_BACKEND_H
#define NATIVE_COMPOSITOR_BACKEND_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** A device-pixel rectangle: x, y, width and height, with the origin at the target's top left. */
typedef struct {
  int x, y, w, h;
} CompRect;

/** A 4x4 matrix in column-major order, mapping texture pixels to the target's device pixels. */
typedef struct {
  float m[16];
} CompMatrix;

/** The matrix that draws a texture pixel for device pixel: the identity. */
CompMatrix comp_matrix_identity(void);
/** The matrix that moves every point by (x, y). */
CompMatrix comp_matrix_translate(float x, float y);
/** The matrix that scales about the origin. */
CompMatrix comp_matrix_scale(float x, float y);
/** The matrix that applies `a` and then `b` (so b·a, as column vectors multiply). */
CompMatrix comp_matrix_mul(CompMatrix b, CompMatrix a);

typedef struct CompBackend CompBackend;

typedef struct {
  /** Creates a texture of `w` by `h` device pixels and returns its id, or -1. */
  int (*tex_create)(CompBackend *b, int w, int h);
  /** Replaces `dst` of the texture with premultiplied RGBA pixels, rows top down, `stride` apart. */
  void (*tex_upload)(CompBackend *b, int tex, CompRect dst, const unsigned char *pixels, int stride);
  void (*tex_destroy)(CompBackend *b, int tex);

  /**
   * Starts a pass drawing into `target`: a texture id, or -1 for the backend's own drawable.
   * The target is cleared to `background` (0xRRGGBBAA, straight alpha).
   */
  void (*pass_begin)(CompBackend *b, int target, int w, int h, uint32_t background);

  /**
   * Draws `tex`'s `src` rectangle as a quad: its texture pixels are mapped by `matrix` into the
   * pass's device space, then the quad's alpha is multiplied by `opacity` and it is clipped to
   * `clip` (device pixels; NULL for the whole pass). A positive `radius` rounds the quad's corners
   * by that many device pixels, as a rounded layer does.
   */
  void (*draw_quad)(CompBackend *b, int tex, CompRect src, const CompMatrix *matrix, float opacity,
                    const CompRect *clip, float radius);
  /** Fills a device-space rect with a straight-alpha 0xRRGGBBAA colour. */
  void (*fill_rect)(CompBackend *b, CompRect rect, uint32_t color);

  /**
   * Reads `rect` of `target` back as straight RGBA8, rows top down, `stride` bytes apart. A pixel
   * outside the target reads as transparent black. Returns 1 on success.
   */
  int (*readback)(CompBackend *b, int target, CompRect rect, unsigned char *out, int stride);

  /** Ends the pass: commits the work and, for a drawable target, presents it. */
  void (*present)(CompBackend *b);

  /** Releases everything the backend holds. */
  void (*destroy)(CompBackend *b);
} CompBackendVTable;

struct CompBackend {
  const CompBackendVTable *vt;
  /** The backend's own state. */
  void *impl;
};

#ifdef __cplusplus
}
#endif

#endif
