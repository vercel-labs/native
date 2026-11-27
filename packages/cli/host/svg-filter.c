// The portable part of inline SVG filters (see svg-filter.h). Everything here works on
// premultiplied RGBA8 with alpha last, in the filter's interpolation space: the platform host
// extracts the filter region from its own bitmap, converts the pixels to this form, calls
// svg_filter_apply, and writes the result back.

#include "svg-filter.h"

#include <ctype.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define SF_MAX_OPS 64

typedef struct {
  uint8_t *px;
  int w, h;
} Buf;

// --- Parsing -----------------------------------------------------------------

/** The next comma-separated number, or 0 when the field isn't one. */
static double num(const char **pp) {
  const char *p = *pp;
  char *end = NULL;
  double v = strtod(p, &end);
  if (end == p) v = 0;
  p = end;
  while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
  if (*p == ',') p++;
  *pp = p;
  return v;
}

/** Whether the cursor is at the end of the operation. */
static void skip_to_end(const char **pp) {
  const char *p = *pp;
  while (*p && *p != ';') p++;
  *pp = p;
}

// --- Colour space ------------------------------------------------------------

static int lut_ready = 0;
static double srgb_to_linear_lut[256];
static uint8_t linear_to_srgb_lut[1024];

static void build_luts(void) {
  if (lut_ready) return;
  for (int i = 0; i < 256; i++) {
    double s = i / 255.0;
    srgb_to_linear_lut[i] = s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4);
  }
  for (int i = 0; i < 1024; i++) {
    double l = i / 1023.0;
    double s = l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1.0 / 2.4) - 0.055;
    int v = (int)(s * 255.0 + 0.5);
    linear_to_srgb_lut[i] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
  }
  lut_ready = 1;
}

/** A premultiplied sRGB pixel to a premultiplied pixel in the filter's space. */
static void to_working(uint8_t *px, int w, int h, int linear) {
  if (!linear) return;
  build_luts();
  size_t n = (size_t)w * (size_t)h;
  for (size_t i = 0; i < n; i++) {
    uint8_t *p = px + i * 4;
    unsigned a = p[3];
    if (a == 0) continue;
    for (int c = 0; c < 3; c++) {
      unsigned straight = (unsigned)p[c] * 255 / a;
      double l = srgb_to_linear_lut[straight > 255 ? 255 : straight];
      p[c] = (uint8_t)(l * a + 0.5);
    }
  }
}

/** A premultiplied filter-space pixel back to premultiplied sRGB. */
static void from_working(uint8_t *px, int w, int h, int linear) {
  if (!linear) return;
  build_luts();
  size_t n = (size_t)w * (size_t)h;
  for (size_t i = 0; i < n; i++) {
    uint8_t *p = px + i * 4;
    unsigned a = p[3];
    if (a == 0) continue;
    for (int c = 0; c < 3; c++) {
      unsigned straight = (unsigned)p[c] * 255 / a;
      double l = straight / 255.0;
      int at = (int)(l * 1023.0 + 0.5);
      unsigned s = linear_to_srgb_lut[at < 0 ? 0 : at > 1023 ? 1023 : at];
      p[c] = (uint8_t)((s * a + 127) / 255);
    }
  }
}

// --- Buffers -----------------------------------------------------------------

static Buf buf_new(int w, int h) {
  Buf b;
  b.w = w;
  b.h = h;
  b.px = (uint8_t *)calloc((size_t)w * (size_t)h * 4, 1);
  return b;
}

static void buf_free(Buf *b) {
  if (b->px) free(b->px);
  b->px = NULL;
}

/** Empties the pixels outside a primitive's subregion, in region-relative pixels. */
static void clip_subregion(Buf *b, double x, double y, double w, double h) {
  if (!b->px) return;
  if (!(w > 0) || !(h > 0)) {
    memset(b->px, 0, (size_t)b->w * (size_t)b->h * 4);
    return;
  }
  int ix0 = (int)floor(x), iy0 = (int)floor(y);
  int ix1 = (int)ceil(x + w), iy1 = (int)ceil(y + h);
  if (ix0 < 0) ix0 = 0;
  if (iy0 < 0) iy0 = 0;
  if (ix1 > b->w) ix1 = b->w;
  if (iy1 > b->h) iy1 = b->h;
  for (int yy = 0; yy < b->h; yy++) {
    uint8_t *row = b->px + (size_t)yy * (size_t)b->w * 4;
    if (yy < iy0 || yy >= iy1) {
      memset(row, 0, (size_t)b->w * 4);
      continue;
    }
    if (ix0 > 0) memset(row, 0, (size_t)ix0 * 4);
    if (ix1 < b->w) memset(row + (size_t)ix1 * 4, 0, (size_t)(b->w - ix1) * 4);
  }
}

// --- Blur --------------------------------------------------------------------

/** One box pass along a row (horizontal) or column, with the outside counting as transparent. */
static void box_pass(const uint8_t *src, uint8_t *dst, int w, int h, int radius, int horizontal) {
  int n = radius * 2 + 1;
  if (horizontal) {
    for (int y = 0; y < h; y++) {
      const uint8_t *in = src + (size_t)y * (size_t)w * 4;
      uint8_t *out = dst + (size_t)y * (size_t)w * 4;
      int s0 = 0, s1 = 0, s2 = 0, s3 = 0;
      for (int k = 0; k <= radius && k < w; k++) {
        s0 += in[k * 4]; s1 += in[k * 4 + 1]; s2 += in[k * 4 + 2]; s3 += in[k * 4 + 3];
      }
      for (int x = 0; x < w; x++) {
        out[x * 4] = (uint8_t)((s0 + n / 2) / n);
        out[x * 4 + 1] = (uint8_t)((s1 + n / 2) / n);
        out[x * 4 + 2] = (uint8_t)((s2 + n / 2) / n);
        out[x * 4 + 3] = (uint8_t)((s3 + n / 2) / n);
        int drop = x - radius, add = x + radius + 1;
        if (drop >= 0 && drop < w) {
          s0 -= in[drop * 4]; s1 -= in[drop * 4 + 1]; s2 -= in[drop * 4 + 2]; s3 -= in[drop * 4 + 3];
        }
        if (add >= 0 && add < w) {
          s0 += in[add * 4]; s1 += in[add * 4 + 1]; s2 += in[add * 4 + 2]; s3 += in[add * 4 + 3];
        }
      }
    }
    return;
  }
  size_t stride = (size_t)w * 4;
  for (int x = 0; x < w; x++) {
    int s0 = 0, s1 = 0, s2 = 0, s3 = 0;
    for (int k = 0; k <= radius && k < h; k++) {
      const uint8_t *p = src + (size_t)k * stride + (size_t)x * 4;
      s0 += p[0]; s1 += p[1]; s2 += p[2]; s3 += p[3];
    }
    for (int y = 0; y < h; y++) {
      uint8_t *out = dst + (size_t)y * stride + (size_t)x * 4;
      out[0] = (uint8_t)((s0 + n / 2) / n);
      out[1] = (uint8_t)((s1 + n / 2) / n);
      out[2] = (uint8_t)((s2 + n / 2) / n);
      out[3] = (uint8_t)((s3 + n / 2) / n);
      int drop = y - radius, add = y + radius + 1;
      if (drop >= 0 && drop < h) {
        const uint8_t *p = src + (size_t)drop * stride + (size_t)x * 4;
        s0 -= p[0]; s1 -= p[1]; s2 -= p[2]; s3 -= p[3];
      }
      if (add >= 0 && add < h) {
        const uint8_t *p = src + (size_t)add * stride + (size_t)x * 4;
        s0 += p[0]; s1 += p[1]; s2 += p[2]; s3 += p[3];
      }
    }
  }
}

/**
 * Three box passes along one axis, with the widths whose repeated convolution comes out at the
 * Gaussian's deviation (the same sizes the CSS blur uses), so an SVG blur matches Chrome's.
 */
static void blur_axis(uint8_t *px, int w, int h, double sigma, int horizontal) {
  if (!(sigma > 0.3) || w < 1 || h < 1) return;
  double ideal = sqrt((12.0 * sigma * sigma / 3.0) + 1.0);
  int wl = (int)floor(ideal);
  if (wl % 2 == 0) wl--;
  if (wl < 1) wl = 1;
  int wu = wl + 2;
  double mIdeal = (12.0 * sigma * sigma - 3.0 * wl * wl - 12.0 * wl - 9.0) / (-4.0 * wl - 4.0);
  int m = (int)round(mIdeal);
  int sizes[3];
  for (int i = 0; i < 3; i++) sizes[i] = i < m ? wl : wu;
  size_t n = (size_t)w * (size_t)h * 4;
  uint8_t *tmp = (uint8_t *)malloc(n);
  if (!tmp) return;
  for (int pass = 0; pass < 3; pass++) {
    int radius = (sizes[pass] - 1) / 2;
    if (radius < 1) continue;
    if (radius > 128) radius = 128;
    box_pass(px, tmp, w, h, radius, horizontal);
    memcpy(px, tmp, n);
  }
  free(tmp);
}

static void blur_buf(Buf *b, double sigmaX, double sigmaY) {
  if (!b->px) return;
  blur_axis(b->px, b->w, b->h, sigmaX, 1);
  blur_axis(b->px, b->w, b->h, sigmaY, 0);
}

// --- Colour matrix -----------------------------------------------------------

static uint8_t clamp_byte(double v) {
  if (!(v > 0)) return 0;
  if (v > 255) return 255;
  return (uint8_t)(v + 0.5);
}

static void colour_matrix(Buf *b, const double *m) {
  if (!b->px) return;
  size_t n = (size_t)b->w * (size_t)b->h;
  for (size_t i = 0; i < n; i++) {
    uint8_t *p = b->px + i * 4;
    double a = p[3] / 255.0;
    if (a <= 0) continue;
    // The matrix is defined on straight colour in the filter's space.
    double r = p[0] / 255.0 / a, g = p[1] / 255.0 / a, bl = p[2] / 255.0 / a;
    double nr = m[0] * r + m[1] * g + m[2] * bl + m[3] * a + m[4];
    double ng = m[5] * r + m[6] * g + m[7] * bl + m[8] * a + m[9];
    double nb = m[10] * r + m[11] * g + m[12] * bl + m[13] * a + m[14];
    double na = m[15] * r + m[16] * g + m[17] * bl + m[18] * a + m[19];
    if (nr < 0) nr = 0; else if (nr > 1) nr = 1;
    if (ng < 0) ng = 0; else if (ng > 1) ng = 1;
    if (nb < 0) nb = 0; else if (nb > 1) nb = 1;
    if (na < 0) na = 0; else if (na > 1) na = 1;
    p[0] = (uint8_t)(nr * na * 255 + 0.5);
    p[1] = (uint8_t)(ng * na * 255 + 0.5);
    p[2] = (uint8_t)(nb * na * 255 + 0.5);
    p[3] = (uint8_t)(na * 255 + 0.5);
  }
}

// --- Compositing -------------------------------------------------------------

static void offset_buf(const Buf *in, Buf *out, double dx, double dy) {
  int ix = (int)lround(dx), iy = (int)lround(dy);
  if (!in->px || !out->px) return;
  for (int y = 0; y < out->h; y++) {
    int sy = y - iy;
    if (sy < 0 || sy >= in->h) continue;
    uint8_t *dst = out->px + (size_t)y * (size_t)out->w * 4;
    const uint8_t *src = in->px + (size_t)sy * (size_t)in->w * 4;
    for (int x = 0; x < out->w; x++) {
      int sx = x - ix;
      if (sx < 0 || sx >= in->w) continue;
      memcpy(dst + (size_t)x * 4, src + (size_t)sx * 4, 4);
    }
  }
}

/** Source drawn over destination, both premultiplied. */
static void over_pixel(const uint8_t *s, const uint8_t *d, uint8_t *o) {
  unsigned inv = 255 - s[3];
  for (int c = 0; c < 4; c++) {
    unsigned v = s[c] + (unsigned)((d[c] * inv + 127) / 255);
    o[c] = (uint8_t)(v > 255 ? 255 : v);
  }
}

static void composite_op(int op, const Buf *in1, const Buf *in2, const Buf *out,
                         double k1, double k2, double k3, double k4) {
  size_t n = (size_t)out->w * (size_t)out->h;
  for (size_t i = 0; i < n; i++) {
    const uint8_t *s = in1->px + i * 4;
    const uint8_t *d = in2->px + i * 4;
    uint8_t *o = out->px + i * 4;
    double as = s[3] / 255.0, ad = d[3] / 255.0;
    if (op == 0) {
      over_pixel(s, d, o);
    } else if (op == 1) { // in
      for (int c = 0; c < 4; c++) o[c] = clamp_byte(s[c] * ad);
    } else if (op == 2) { // out
      for (int c = 0; c < 4; c++) o[c] = clamp_byte(s[c] * (1 - ad));
    } else if (op == 3) { // atop
      for (int c = 0; c < 4; c++) o[c] = clamp_byte(s[c] * ad + d[c] * (1 - as));
    } else if (op == 4) { // xor
      for (int c = 0; c < 4; c++) o[c] = clamp_byte(s[c] * (1 - ad) + d[c] * (1 - as));
    } else { // arithmetic
      for (int c = 0; c < 4; c++) {
        double v = k1 * (s[c] / 255.0) * (d[c] / 255.0) + k2 * (s[c] / 255.0) +
                   k3 * (d[c] / 255.0) + k4;
        o[c] = clamp_byte(v * 255.0);
      }
    }
  }
}

static double blend_channel(int mode, double cb, double cs) {
  switch (mode) {
    case 1: return cb * cs;                        // multiply
    case 2: return cb + cs - cb * cs;              // screen
    case 3: return cb < cs ? cb : cs;              // darken
    case 4: return cb > cs ? cb : cs;              // lighten
    case 5:                                        // overlay
      return cb <= 0.5 ? 2 * cb * cs : 1 - 2 * (1 - cb) * (1 - cs);
    case 6:                                        // color-dodge
      if (cb <= 0) return 0;
      if (cs >= 1) return 1;
      return 1.0 < cb / (1 - cs) ? 1.0 : cb / (1 - cs);
    case 7: {                                      // color-burn
      if (cb >= 1) return 1;
      if (cs <= 0) return 0;
      double v = 1 - (1 - cb) / cs;
      return v < 0 ? 0 : v;
    }
    case 8:                                        // hard-light
      return cs <= 0.5 ? 2 * cs * cb : 1 - 2 * (1 - cs) * (1 - cb);
    case 9: {                                      // soft-light
      if (cs <= 0.5) return cb - (1 - 2 * cs) * cb * (1 - cb);
      double d = cb <= 0.25 ? ((16 * cb - 12) * cb + 4) * cb : sqrt(cb);
      return cb + (2 * cs - 1) * (d - cb);
    }
    case 10: return fabs(cb - cs);                 // difference
    case 11: return cb + cs - 2 * cb * cs;         // exclusion
    default: return cs;                            // normal
  }
}

static void blend_buf(int mode, const Buf *in1, const Buf *in2, Buf *out) {
  size_t n = (size_t)out->w * (size_t)out->h;
  for (size_t i = 0; i < n; i++) {
    const uint8_t *s = in1->px + i * 4;
    const uint8_t *d = in2->px + i * 4;
    uint8_t *o = out->px + i * 4;
    double as = s[3] / 255.0, ad = d[3] / 255.0;
    double cs[3], cd[3], co[3];
    for (int c = 0; c < 3; c++) {
      cs[c] = as > 0 ? s[c] / 255.0 / as : 0;
      cd[c] = ad > 0 ? d[c] / 255.0 / ad : 0;
      double b = blend_channel(mode, cd[c], cs[c]);
      co[c] = as * (1 - ad) * cs[c] + as * ad * b + (1 - as) * ad * cd[c];
      o[c] = clamp_byte(co[c] * 255.0);
    }
    o[3] = clamp_byte((as + ad * (1 - as)) * 255.0);
  }
}

static void merge_buf(const Buf *const *ins, int count, Buf *out) {
  size_t n = (size_t)out->w * (size_t)out->h;
  memset(out->px, 0, n * 4);
  for (int k = 0; k < count; k++) {
    const Buf *in = ins[k];
    if (!in || !in->px) continue;
    for (size_t i = 0; i < n; i++) {
      over_pixel(in->px + i * 4, out->px + i * 4, out->px + i * 4);
    }
  }
}

/** feDropShadow: the input's alpha, blurred and offset, tinted, drawn under the input. */
static void drop_shadow(const Buf *in, Buf *out, double dx, double dy, double sx, double sy,
                        const double *rgba) {
  int w = out->w, h = out->h;
  Buf shadow = buf_new(w, h);
  if (!shadow.px) return;
  size_t n = (size_t)w * (size_t)h;
  for (size_t i = 0; i < n; i++) shadow.px[i * 4 + 3] = in->px[i * 4 + 3];
  blur_buf(&shadow, sx, sy);
  Buf moved = buf_new(w, h);
  if (!moved.px) {
    buf_free(&shadow);
    return;
  }
  offset_buf(&shadow, &moved, dx, dy);
  // Tint with the shadow colour, whose alpha scales the blurred alpha.
  double cr = rgba[0], cg = rgba[1], cb = rgba[2], ca = rgba[3] / 255.0;
  for (size_t i = 0; i < n; i++) {
    uint8_t *sp = moved.px + i * 4;
    double a = sp[3] / 255.0 * ca;
    sp[0] = clamp_byte(cr * a);
    sp[1] = clamp_byte(cg * a);
    sp[2] = clamp_byte(cb * a);
    sp[3] = clamp_byte(a * 255.0);
  }
  memcpy(out->px, in->px, n * 4);
  for (size_t i = 0; i < n; i++) {
    over_pixel(in->px + i * 4, moved.px + i * 4, out->px + i * 4);
  }
  buf_free(&shadow);
  buf_free(&moved);
}

// --- The chain ---------------------------------------------------------------

void svg_filter_apply(uint8_t *rgba, int w, int h, const char *def, size_t n, int linear) {
  if (!rgba || w <= 0 || h <= 0) return;
  char *text = (char *)malloc(n + 1);
  if (!text) return;
  memcpy(text, def, n);
  text[n] = 0;

  Buf source = {rgba, w, h};
  Buf alpha = buf_new(w, h);
  size_t px = (size_t)w * (size_t)h;
  if (!alpha.px) {
    free(text);
    return;
  }
  Buf clear = buf_new(w, h);
  if (!clear.px) {
    buf_free(&alpha);
    free(text);
    return;
  }
  // Convert only once every buffer is in hand: the source pixels are left untouched if the
  // chain can't run at all.
  to_working(rgba, w, h, linear);
  for (size_t i = 0; i < px; i++) alpha.px[i * 4 + 3] = rgba[i * 4 + 3];

  Buf results[SF_MAX_OPS];
  int count = 0;
  const char *p = text;

  while (*p && count < SF_MAX_OPS) {
    while (*p && (*p == ';' || isspace((unsigned char)*p))) p++;
    if (!*p) break;
    char kind = *p++;
    if (*p == ',') p++;
    Buf out = buf_new(w, h);
    Buf *in1 = NULL, *in2 = NULL;
    int ok = out.px != NULL;
    if (!ok) break;

    if (kind == 't') { // pass-through
      int idx = (int)num(&p);
      in1 = idx == -1 ? &source : idx == -2 ? &alpha : idx == -3 ? &clear
        : (idx >= 0 && idx < count ? &results[idx] : &clear);
      memcpy(out.px, in1->px, (size_t)w * (size_t)h * 4);
    } else if (kind == 'b') {
      double sx = num(&p), sy = num(&p);
      int idx = (int)num(&p);
      in1 = idx == -1 ? &source : idx == -2 ? &alpha : idx == -3 ? &clear
        : (idx >= 0 && idx < count ? &results[idx] : &clear);
      memcpy(out.px, in1->px, (size_t)w * (size_t)h * 4);
      blur_buf(&out, sx, sy);
    } else if (kind == 'o') {
      double dx = num(&p), dy = num(&p);
      int idx = (int)num(&p);
      in1 = idx == -1 ? &source : idx == -2 ? &alpha : idx == -3 ? &clear
        : (idx >= 0 && idx < count ? &results[idx] : &clear);
      offset_buf(in1, &out, dx, dy);
    } else if (kind == 'm') {
      int idx = (int)num(&p);
      in1 = idx == -1 ? &source : idx == -2 ? &alpha : idx == -3 ? &clear
        : (idx >= 0 && idx < count ? &results[idx] : &clear);
      memcpy(out.px, in1->px, (size_t)w * (size_t)h * 4);
      double m[20];
      for (int i = 0; i < 20; i++) m[i] = num(&p);
      colour_matrix(&out, m);
    } else if (kind == 'l') {
      int mode = (int)num(&p);
      int i1 = (int)num(&p), i2 = (int)num(&p);
      in1 = i1 == -1 ? &source : i1 == -2 ? &alpha : i1 == -3 ? &clear
        : (i1 >= 0 && i1 < count ? &results[i1] : &clear);
      in2 = i2 == -1 ? &source : i2 == -2 ? &alpha : i2 == -3 ? &clear
        : (i2 >= 0 && i2 < count ? &results[i2] : &clear);
      blend_buf(mode, in1, in2, &out);
    } else if (kind == 'e') {
      int m = (int)num(&p);
      if (m > SF_MAX_OPS) m = SF_MAX_OPS;
      const Buf *ins[SF_MAX_OPS];
      for (int i = 0; i < m; i++) {
        int idx = (int)num(&p);
        ins[i] = idx == -1 ? &source : idx == -2 ? &alpha : idx == -3 ? &clear
          : (idx >= 0 && idx < count ? &results[idx] : &clear);
      }
      merge_buf(ins, m, &out);
    } else if (kind == 'f') {
      double r = num(&p), g = num(&p), b = num(&p), a = num(&p);
      for (size_t i = 0; i < px; i++) {
        uint8_t *o = out.px + i * 4;
        o[0] = clamp_byte(r * a / 255.0);
        o[1] = clamp_byte(g * a / 255.0);
        o[2] = clamp_byte(b * a / 255.0);
        o[3] = clamp_byte(a);
      }
    } else if (kind == 'c') {
      int op = (int)num(&p);
      double k1 = num(&p), k2 = num(&p), k3 = num(&p), k4 = num(&p);
      int i1 = (int)num(&p), i2 = (int)num(&p);
      in1 = i1 == -1 ? &source : i1 == -2 ? &alpha : i1 == -3 ? &clear
        : (i1 >= 0 && i1 < count ? &results[i1] : &clear);
      in2 = i2 == -1 ? &source : i2 == -2 ? &alpha : i2 == -3 ? &clear
        : (i2 >= 0 && i2 < count ? &results[i2] : &clear);
      composite_op(op, in1, in2, &out, k1, k2, k3, k4);
    } else if (kind == 'd') {
      double dx = num(&p), dy = num(&p), sx = num(&p), sy = num(&p);
      double c[4] = {num(&p), num(&p), num(&p), num(&p)};
      int idx = (int)num(&p);
      in1 = idx == -1 ? &source : idx == -2 ? &alpha : idx == -3 ? &clear
        : (idx >= 0 && idx < count ? &results[idx] : &clear);
      drop_shadow(in1, &out, dx, dy, sx, sy, c);
    } else {
      // An operation this build doesn't know: leave the pixels transparent.
      skip_to_end(&p);
    }

    // The primitive's subregion, in region-relative pixels, clips its output.
    double sx = num(&p), sy = num(&p), sw = num(&p), sh = num(&p);
    clip_subregion(&out, sx, sy, sw, sh);
    skip_to_end(&p);

    results[count] = out;
    count++;
  }

  // The last primitive's output is the filter's result.
  if (count > 0 && results[count - 1].px) {
    memcpy(rgba, results[count - 1].px, (size_t)w * (size_t)h * 4);
  }
  for (int i = 0; i < count; i++) buf_free(&results[i]);
  buf_free(&alpha);
  buf_free(&clear);
  from_working(rgba, w, h, linear);
  free(text);
}
