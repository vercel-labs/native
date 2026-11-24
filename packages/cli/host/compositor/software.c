// The software backend: Cairo image surfaces as textures, drawn into a Cairo image surface. It is
// the compositor's reference path (Linux CI has no GPU) and the oracle a GPU backend is checked
// against: a quad drawn at an integer offset must land on the same pixels as the flat replay.

#include <cairo.h>
#include <stdlib.h>
#include <string.h>

#include "backend.h"

#define SOFT_MAX_TEX 8192

typedef struct {
  cairo_surface_t *surf;
  int w, h;
  int used;
} SoftTex;

typedef struct {
  SoftTex tex[SOFT_MAX_TEX];
  int tex_count;
  cairo_surface_t *target;
  cairo_t *cr;
  int target_w, target_h;
  int target_owned;
} SoftBackend;

static int soft_tex_create(CompBackend *b, int w, int h) {
  SoftBackend *s = (SoftBackend *)b->impl;
  if (w <= 0 || h <= 0 || s->tex_count >= SOFT_MAX_TEX) return -1;
  cairo_surface_t *surf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
  if (cairo_surface_status(surf) != CAIRO_STATUS_SUCCESS) {
    cairo_surface_destroy(surf);
    return -1;
  }
  int id = s->tex_count++;
  s->tex[id].surf = surf;
  s->tex[id].w = w;
  s->tex[id].h = h;
  s->tex[id].used = 1;
  return id;
}

static void soft_tex_upload(CompBackend *b, int tex, CompRect dst, const unsigned char *pixels, int stride) {
  SoftBackend *s = (SoftBackend *)b->impl;
  if (tex < 0 || tex >= s->tex_count || pixels == NULL) return;
  SoftTex *t = &s->tex[tex];
  cairo_surface_flush(t->surf);
  unsigned char *data = cairo_image_surface_get_data(t->surf);
  int tstride = cairo_image_surface_get_stride(t->surf);
  int x0 = dst.x < 0 ? 0 : dst.x;
  int y0 = dst.y < 0 ? 0 : dst.y;
  int x1 = dst.x + dst.w > t->w ? t->w : dst.x + dst.w;
  int y1 = dst.y + dst.h > t->h ? t->h : dst.y + dst.h;
  for (int y = y0; y < y1; y++) {
    const unsigned char *src = pixels + (size_t)(y - dst.y) * (size_t)stride + (size_t)(x0 - dst.x) * 4;
    unsigned char *out = data + (size_t)y * (size_t)tstride + (size_t)x0 * 4;
    for (int x = x0; x < x1; x++) {
      // The core and the runtime hold premultiplied RGBA; Cairo's ARGB32 is BGRA in memory on a
      // little-endian machine.
      out[0] = src[2];
      out[1] = src[1];
      out[2] = src[0];
      out[3] = src[3];
      src += 4;
      out += 4;
    }
  }
  cairo_surface_mark_dirty(t->surf);
}

static void soft_tex_destroy(CompBackend *b, int tex) {
  SoftBackend *s = (SoftBackend *)b->impl;
  if (tex < 0 || tex >= s->tex_count) return;
  if (s->tex[tex].surf != NULL) {
    if (s->target == s->tex[tex].surf) {
      // The pass drew into this texture: let go of it before its surface goes.
      if (s->cr != NULL) cairo_destroy(s->cr);
      s->cr = NULL;
      s->target = NULL;
    }
    cairo_surface_destroy(s->tex[tex].surf);
    s->tex[tex].surf = NULL;
  }
  s->tex[tex].used = 0;
}

static void soft_release_target(SoftBackend *s) {
  if (s->cr != NULL) {
    cairo_destroy(s->cr);
    s->cr = NULL;
  }
  if (s->target_owned && s->target != NULL) cairo_surface_destroy(s->target);
  s->target = NULL;
  s->target_owned = 0;
}

static void soft_pass_begin(CompBackend *b, int target, int w, int h, uint32_t background) {
  SoftBackend *s = (SoftBackend *)b->impl;
  soft_release_target(s);
  if (w <= 0 || h <= 0) return;
  cairo_surface_t *surf = NULL;
  if (target >= 0 && target < s->tex_count && s->tex[target].surf != NULL) {
    surf = s->tex[target].surf;
    s->target_owned = 0;
  } else {
    surf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    if (cairo_surface_status(surf) != CAIRO_STATUS_SUCCESS) {
      cairo_surface_destroy(surf);
      return;
    }
    s->target_owned = 1;
  }
  s->target = surf;
  s->target_w = w;
  s->target_h = h;
  s->cr = cairo_create(surf);
  if (cairo_status(s->cr) != CAIRO_STATUS_SUCCESS) {
    soft_release_target(s);
    return;
  }
  // Straight 0xRRGGBBAA to Cairo's straight RGBA.
  double a = (double)(background & 255) / 255.0;
  double r = (double)((background >> 24) & 255) / 255.0;
  double g = (double)((background >> 16) & 255) / 255.0;
  double bl = (double)((background >> 8) & 255) / 255.0;
  cairo_set_source_rgba(s->cr, r, g, bl, a);
  cairo_set_operator(s->cr, CAIRO_OPERATOR_SOURCE);
  cairo_paint(s->cr);
  cairo_set_operator(s->cr, CAIRO_OPERATOR_OVER);
}

static void soft_draw_quad(CompBackend *b, int tex, CompRect src, const CompMatrix *matrix,
                           float opacity, const CompRect *clip, float radius) {
  SoftBackend *s = (SoftBackend *)b->impl;
  if (s->cr == NULL || tex < 0 || tex >= s->tex_count || s->tex[tex].surf == NULL) return;
  if (opacity <= 0.0f || src.w <= 0 || src.h <= 0) return;
  cairo_save(s->cr);
  if (clip != NULL && clip->w > 0 && clip->h > 0) {
    cairo_rectangle(s->cr, clip->x, clip->y, clip->w, clip->h);
    cairo_clip(s->cr);
  }
  cairo_set_source_surface(s->cr, s->tex[tex].surf, 0, 0);
  cairo_pattern_t *pat = cairo_get_source(s->cr);
  if (matrix != NULL) {
    cairo_matrix_t cm;
    cm.xx = matrix->m[0];
    cm.yx = matrix->m[1];
    cm.xy = matrix->m[4];
    cm.yy = matrix->m[5];
    cm.x0 = matrix->m[12];
    cm.y0 = matrix->m[13];
    // The pattern matrix maps user space to texture space, the inverse of the quad's own.
    if (cairo_matrix_invert(&cm) == CAIRO_STATUS_SUCCESS) cairo_pattern_set_matrix(pat, &cm);
  }
  if (radius > 0.0f) {
    // The source rect's corners in device space bound the rounded clip.
    double x0 = 0, y0 = 0, x1 = src.w, y1 = src.h;
    if (matrix != NULL) {
      cairo_matrix_t cm;
      cm.xx = matrix->m[0]; cm.yx = matrix->m[1]; cm.xy = matrix->m[4];
      cm.yy = matrix->m[5]; cm.x0 = matrix->m[12]; cm.y0 = matrix->m[13];
      cairo_matrix_transform_point(&cm, &x0, &y0);
      cairo_matrix_transform_point(&cm, &x1, &y1);
    }
    double bx = x0 < x1 ? x0 : x1, by = y0 < y1 ? y0 : y1;
    double bw = (x0 < x1 ? x1 : x0) - bx, bh = (y0 < y1 ? y1 : y0) - by;
    double r = radius;
    if (r > bw / 2) r = bw / 2;
    if (r > bh / 2) r = bh / 2;
    cairo_new_path(s->cr);
    cairo_arc(s->cr, bx + r, by + r, r, 3.14159265358979323846, 1.5 * 3.14159265358979323846);
    cairo_arc(s->cr, bx + bw - r, by + r, r, 1.5 * 3.14159265358979323846, 2.0 * 3.14159265358979323846);
    cairo_arc(s->cr, bx + bw - r, by + bh - r, r, 0, 0.5 * 3.14159265358979323846);
    cairo_arc(s->cr, bx + r, by + bh - r, r, 0.5 * 3.14159265358979323846, 3.14159265358979323846);
    cairo_close_path(s->cr);
    cairo_clip(s->cr);
  }
  cairo_paint_with_alpha(s->cr, (double)opacity);
  cairo_restore(s->cr);
}

static void soft_fill_rect(CompBackend *b, CompRect rect, uint32_t color) {
  SoftBackend *s = (SoftBackend *)b->impl;
  if (s->cr == NULL || rect.w <= 0 || rect.h <= 0) return;
  double a = (double)(color & 255) / 255.0;
  double r = (double)((color >> 24) & 255) / 255.0;
  double g = (double)((color >> 16) & 255) / 255.0;
  double bl = (double)((color >> 8) & 255) / 255.0;
  cairo_save(s->cr);
  cairo_rectangle(s->cr, rect.x, rect.y, rect.w, rect.h);
  cairo_clip(s->cr);
  cairo_set_source_rgba(s->cr, r, g, bl, a);
  cairo_paint(s->cr);
  cairo_restore(s->cr);
}

static int soft_readback(CompBackend *b, int target, CompRect rect, unsigned char *out, int stride) {
  SoftBackend *s = (SoftBackend *)b->impl;
  if (out == NULL) return 0;
  cairo_surface_t *surf = NULL;
  if (target >= 0 && target < s->tex_count && s->tex[target].surf != NULL) surf = s->tex[target].surf;
  else surf = s->target;
  if (surf == NULL) return 0;
  cairo_surface_flush(surf);
  const unsigned char *data = cairo_image_surface_get_data(surf);
  int tstride = cairo_image_surface_get_stride(surf);
  for (int y = 0; y < rect.h; y++) {
    unsigned char *o = out + (size_t)y * (size_t)stride;
    for (int x = 0; x < rect.w; x++) {
      int sx = rect.x + x, sy = rect.y + y;
      if (sx < 0 || sy < 0 || sx >= s->target_w || sy >= s->target_h) {
        o[0] = o[1] = o[2] = o[3] = 0;
      } else {
        const unsigned char *p = data + (size_t)sy * (size_t)tstride + (size_t)sx * 4;
        unsigned a = p[3];
        if (a == 0) {
          o[0] = o[1] = o[2] = o[3] = 0;
        } else {
          // Cairo keeps premultiplied BGRA; the readback is straight RGBA.
          o[0] = (unsigned char)((p[2] * 255u + a / 2u) / a);
          o[1] = (unsigned char)((p[1] * 255u + a / 2u) / a);
          o[2] = (unsigned char)((p[0] * 255u + a / 2u) / a);
          o[3] = (unsigned char)a;
        }
      }
      o += 4;
    }
  }
  return 1;
}

/** The work is already in the target surface, so there is nothing left to do. */
static void soft_present(CompBackend *b) { (void)b; }

static void soft_destroy(CompBackend *b) {
  SoftBackend *s = (SoftBackend *)b->impl;
  if (s == NULL) return;
  soft_release_target(s);
  for (int i = 0; i < s->tex_count; i++) {
    if (s->tex[i].surf != NULL) cairo_surface_destroy(s->tex[i].surf);
  }
  free(s);
  b->impl = NULL;
  free(b);
}

static const CompBackendVTable SOFT_VT = {
  soft_tex_create, soft_tex_upload, soft_tex_destroy, soft_pass_begin,
  soft_draw_quad, soft_fill_rect, soft_readback, soft_present, soft_destroy,
};

/** Creates a software backend; the caller owns it and destroys it through the vtable. */
CompBackend *comp_software_backend(void) {
  SoftBackend *s = (SoftBackend *)calloc(1, sizeof(SoftBackend));
  if (s == NULL) return NULL;
  CompBackend *b = (CompBackend *)calloc(1, sizeof(CompBackend));
  if (b == NULL) {
    free(s);
    return NULL;
  }
  b->vt = &SOFT_VT;
  b->impl = s;
  return b;
}
