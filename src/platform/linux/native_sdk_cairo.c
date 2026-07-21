/* Cairo packet renderer — the macOS CGContext packet path's Linux twin.
 *
 * The runtime already produces a platform-agnostic "packet" (a GPU command
 * list) and serializes it; macOS decodes it into Core Graphics
 * (appkit_host.m NativeSdkPacketDrawCommand). This file is the same idea
 * with Cairo: an immediate-mode C surface driven, command by command, by the
 * Zig packet service (linux/root.zig presentGpuSurfacePacket) which owns the
 * JSON decode and the per-command clip/transform/paint logic.
 *
 * We only draw; we know nothing of GtkHost or views. The caller reads the
 * finished pixels back as straight-alpha RGBA8 and hands them to the existing
 * present path (native_sdk_gtk_present_gpu_surface_pixels). Cairo is a mature,
 * optimized 2D rasterizer (the Core Graphics analog), so this replaces the
 * naive reference rasterizer on the frames it can fully draw; anything it does
 * not yet handle makes the Zig side refuse the frame, and the runtime falls
 * back to the reference renderer — never a regression, just less speedup.
 *
 * Coordinate convention (mirrors appkit_host.m NativeSdkPacketDrawCommand):
 * per command the caller (1) saves, (2) applies the scissor + command clip
 * rects in SURFACE space (identity CTM), (3) sets the command transform,
 * (4) draws the shape in LOCAL space, (5) restores. The command transform is
 * expected to map local -> device pixels (the render plan bakes device scale
 * in, same as the reference renderer which rasterizes at device size). */

#include <cairo.h>
#include <cairo-ft.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct native_sdk_cairo_ctx {
    cairo_surface_t *surface;
    cairo_t *cr;
    int width;
    int height;
};

typedef struct native_sdk_cairo_ctx native_sdk_cairo_ctx_t;

/* Create a device-pixel ARGB32 surface and paint the (opaque) clear color. */
native_sdk_cairo_ctx_t *native_sdk_cairo_begin(int px_width, int px_height,
                                               double clear_r, double clear_g,
                                               double clear_b, double clear_a) {
    if (px_width <= 0 || px_height <= 0) return NULL;
    native_sdk_cairo_ctx_t *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, px_width, px_height);
    if (cairo_surface_status(c->surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(c->surface);
        free(c);
        return NULL;
    }
    c->cr = cairo_create(c->surface);
    c->width = px_width;
    c->height = px_height;
    /* SOURCE (not OVER) so the clear replaces whatever the surface came
     * with, alpha included — the canvas is opaque from here down. */
    cairo_set_operator(c->cr, CAIRO_OPERATOR_SOURCE);
    cairo_set_source_rgba(c->cr, clear_r, clear_g, clear_b, clear_a);
    cairo_paint(c->cr);
    cairo_set_operator(c->cr, CAIRO_OPERATOR_OVER);
    return c;
}

void native_sdk_cairo_save(native_sdk_cairo_ctx_t *c) { cairo_save(c->cr); }
void native_sdk_cairo_restore(native_sdk_cairo_ctx_t *c) { cairo_restore(c->cr); }

void native_sdk_cairo_identity_matrix(native_sdk_cairo_ctx_t *c) {
    cairo_identity_matrix(c->cr);
}

/* Affine {a,b,c,d,tx,ty} in the same column order as cairo_matrix_init. */
void native_sdk_cairo_set_matrix(native_sdk_cairo_ctx_t *c, double a, double b,
                                 double cc, double d, double tx, double ty) {
    cairo_matrix_t m;
    cairo_matrix_init(&m, a, b, cc, d, tx, ty);
    cairo_set_matrix(c->cr, &m);
}

/* Clip is applied with whatever CTM is current — the caller sets identity
 * first so the rect is surface-space (macOS parity). */
void native_sdk_cairo_clip_rect(native_sdk_cairo_ctx_t *c, double x, double y,
                                double w, double h) {
    cairo_rectangle(c->cr, x, y, w, h);
    cairo_clip(c->cr);
}

void native_sdk_cairo_set_color(native_sdk_cairo_ctx_t *c, double r, double g,
                                double b, double a) {
    cairo_set_source_rgba(c->cr, r, g, b, a);
}

/* offsets[n], colors[n*4] (rgba 0..1). Stops already clamped/sorted by caller. */
void native_sdk_cairo_set_linear_gradient(native_sdk_cairo_ctx_t *c,
                                          double x0, double y0, double x1, double y1,
                                          int n, const double *offsets,
                                          const double *colors) {
    cairo_pattern_t *p = cairo_pattern_create_linear(x0, y0, x1, y1);
    for (int i = 0; i < n; i++) {
        cairo_pattern_add_color_stop_rgba(p, offsets[i], colors[i * 4 + 0],
                                          colors[i * 4 + 1], colors[i * 4 + 2],
                                          colors[i * 4 + 3]);
    }
    cairo_set_source(c->cr, p);
    cairo_pattern_destroy(p);
}

/* Path building (local coords; the CTM maps to device). */
void native_sdk_cairo_new_path(native_sdk_cairo_ctx_t *c) { cairo_new_path(c->cr); }
void native_sdk_cairo_move_to(native_sdk_cairo_ctx_t *c, double x, double y) { cairo_move_to(c->cr, x, y); }
void native_sdk_cairo_line_to(native_sdk_cairo_ctx_t *c, double x, double y) { cairo_line_to(c->cr, x, y); }
void native_sdk_cairo_curve_to(native_sdk_cairo_ctx_t *c, double x1, double y1,
                               double x2, double y2, double x3, double y3) {
    cairo_curve_to(c->cr, x1, y1, x2, y2, x3, y3);
}
void native_sdk_cairo_close_path(native_sdk_cairo_ctx_t *c) { cairo_close_path(c->cr); }
void native_sdk_cairo_rectangle(native_sdk_cairo_ctx_t *c, double x, double y, double w, double h) {
    cairo_rectangle(c->cr, x, y, w, h);
}

/* Append a rounded-rect subpath with four independent corner radii (the
 * NSBezierPath bezierPathWithRoundedRect analog) onto any context. Radii clamp
 * to half the shorter side; a zero radius degenerates to a square corner. */
static void rounded_rect_path(cairo_t *cr, double x, double y, double w, double h,
                              double tl, double tr, double br, double bl) {
    const double maxr = (w < h ? w : h) * 0.5;
    if (tl > maxr) tl = maxr;
    if (tr > maxr) tr = maxr;
    if (br > maxr) br = maxr;
    if (bl > maxr) bl = maxr;
    const double pi = M_PI;
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + w - tr, y + tr, tr, -pi * 0.5, 0.0);        /* top-right */
    cairo_arc(cr, x + w - br, y + h - br, br, 0.0, pi * 0.5);     /* bottom-right */
    cairo_arc(cr, x + bl, y + h - bl, bl, pi * 0.5, pi);          /* bottom-left */
    cairo_arc(cr, x + tl, y + tl, tl, pi, pi * 1.5);              /* top-left */
    cairo_close_path(cr);
}

void native_sdk_cairo_rounded_rect(native_sdk_cairo_ctx_t *c, double x, double y,
                                   double w, double h, double tl, double tr,
                                   double br, double bl) {
    rounded_rect_path(c->cr, x, y, w, h, tl, tr, br, bl);
}

static void blur_surface(cairo_surface_t *s, int r); /* defined below, near box blur */

/* Drop shadow of a rounded rect: the shape offset by `offset`, grown by
 * `spread`, filled with the shadow color. With `blur <= 0` it fills directly
 * under the current CTM (hard edge). With blur, the shape is rasterized to an
 * offscreen surface, box-blurred (the reference renderer's Gaussian falloff),
 * and composited — offscreen because the shadow sits BEHIND its element, so
 * blurring it in place would smear the backdrop it draws over. */
void native_sdk_cairo_shadow(native_sdk_cairo_ctx_t *c, double x, double y,
                             double w, double h, double tl, double tr, double br,
                             double bl, double dx, double dy, double blur,
                             double spread, double r, double g, double b, double a) {
    const double sx = x + dx - spread;
    const double sy = y + dy - spread;
    const double sw = w + 2.0 * spread;
    const double sh = h + 2.0 * spread;
    if (sw <= 0 || sh <= 0) return;
    const double rtl = tl + spread, rtr = tr + spread, rbr = br + spread, rbl = bl + spread;

    if (blur <= 0) {
        rounded_rect_path(c->cr, sx, sy, sw, sh, rtl, rtr, rbr, rbl);
        cairo_set_source_rgba(c->cr, r, g, b, a);
        cairo_fill(c->cr);
        return;
    }

    /* Device-space bbox of the shape + the blur apron (assumes an axis-aligned
     * CTM, as UI transforms and the reference renderer both do). */
    double x0 = sx, y0 = sy, x1 = sx + sw, y1 = sy + sh;
    cairo_user_to_device(c->cr, &x0, &y0);
    cairo_user_to_device(c->cr, &x1, &y1);
    double ux = 1, uy = 0;
    cairo_user_to_device_distance(c->cr, &ux, &uy);
    const double scale = sqrt(ux * ux + uy * uy);
    int br_px = (int)ceil(blur * scale);
    if (br_px < 1) br_px = 1;
    if (br_px > 128) br_px = 128;

    const double dbx = x0 < x1 ? x0 : x1, dby = y0 < y1 ? y0 : y1;
    const double dbw = fabs(x1 - x0), dbh = fabs(y1 - y0);
    const int apron = br_px + 1;
    const int tw = (int)ceil(dbw) + 2 * apron;
    const int th = (int)ceil(dbh) + 2 * apron;
    if (tw <= 0 || th <= 0) return;

    cairo_surface_t *tmp = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, tw, th);
    if (cairo_surface_status(tmp) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(tmp);
        return;
    }
    cairo_t *tcr = cairo_create(tmp);
    /* Draw the shape in device pixels at (apron, apron), radii scaled to device. */
    rounded_rect_path(tcr, apron, apron, dbw, dbh, rtl * scale, rtr * scale, rbr * scale, rbl * scale);
    cairo_set_source_rgba(tcr, r, g, b, a);
    cairo_fill(tcr);
    cairo_destroy(tcr);

    blur_surface(tmp, br_px);

    /* Composite the blurred shadow at its device position. Identity CTM so the
     * offset is device-space; the command's surface-space clip still applies. */
    cairo_save(c->cr);
    cairo_identity_matrix(c->cr);
    cairo_set_source_surface(c->cr, tmp, dbx - apron, dby - apron);
    cairo_paint(c->cr);
    cairo_restore(c->cr);
    cairo_surface_destroy(tmp);
}

static int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }

/* One separable box pass (horizontal then vertical) over a premultiplied
 * RGBA8 buffer, edge-clamped. `tmp` is scratch of the same size. Averaging
 * premultiplied channels (alpha included) is linear, so this is correct. */
static void cairo_box_pass(uint8_t *buf, int W, int H, int r, uint8_t *tmp) {
    const int win = 2 * r + 1;
    /* horizontal: buf -> tmp */
    for (int y = 0; y < H; y++) {
        uint8_t *row = buf + (size_t)y * W * 4;
        uint8_t *out = tmp + (size_t)y * W * 4;
        int acc[4] = {0, 0, 0, 0};
        for (int k = -r; k <= r; k++) {
            const int xi = k < 0 ? 0 : (k >= W ? W - 1 : k);
            for (int ch = 0; ch < 4; ch++) acc[ch] += row[xi * 4 + ch];
        }
        for (int x = 0; x < W; x++) {
            for (int ch = 0; ch < 4; ch++) out[x * 4 + ch] = (uint8_t)(acc[ch] / win);
            const int add = x + r + 1, sub = x - r;
            const int ai = add >= W ? W - 1 : add;
            const int si = sub < 0 ? 0 : sub;
            for (int ch = 0; ch < 4; ch++) acc[ch] += row[ai * 4 + ch] - row[si * 4 + ch];
        }
    }
    /* vertical: tmp -> buf */
    for (int x = 0; x < W; x++) {
        int acc[4] = {0, 0, 0, 0};
        for (int k = -r; k <= r; k++) {
            const int yi = k < 0 ? 0 : (k >= H ? H - 1 : k);
            for (int ch = 0; ch < 4; ch++) acc[ch] += tmp[((size_t)yi * W + x) * 4 + ch];
        }
        for (int y = 0; y < H; y++) {
            uint8_t *o = buf + ((size_t)y * W + x) * 4;
            for (int ch = 0; ch < 4; ch++) o[ch] = (uint8_t)(acc[ch] / win);
            const int add = y + r + 1, sub = y - r;
            const int ai = add >= H ? H - 1 : add;
            const int si = sub < 0 ? 0 : sub;
            for (int ch = 0; ch < 4; ch++)
                acc[ch] += tmp[((size_t)ai * W + x) * 4 + ch] - tmp[((size_t)si * W + x) * 4 + ch];
        }
    }
}

/* 3 box passes ≈ Gaussian, in place on a premultiplied RGBA8 buffer. */
static void blur_buffer(uint8_t *buf, int W, int H, int r) {
    if (r < 1) return;
    uint8_t *tmp = malloc((size_t)W * H * 4);
    if (!tmp) return;
    for (int i = 0; i < 3; i++) cairo_box_pass(buf, W, H, r, tmp);
    free(tmp);
}

/* Blur an entire image surface in place. Used for the offscreen shadow mask;
 * rows copy raw (ARGB32 stride is always width*4, channels blur uniformly). */
static void blur_surface(cairo_surface_t *s, int r) {
    if (r < 1) return;
    cairo_surface_flush(s);
    unsigned char *data = cairo_image_surface_get_data(s);
    if (!data) return;
    const int W = cairo_image_surface_get_width(s);
    const int H = cairo_image_surface_get_height(s);
    const int stride = cairo_image_surface_get_stride(s);
    uint8_t *buf = malloc((size_t)W * H * 4);
    if (!buf) return;
    for (int y = 0; y < H; y++) memcpy(buf + (size_t)y * W * 4, data + (size_t)y * stride, (size_t)W * 4);
    blur_buffer(buf, W, H, r);
    for (int y = 0; y < H; y++) memcpy(data + (size_t)y * stride, buf + (size_t)y * W * 4, (size_t)W * 4);
    free(buf);
    cairo_surface_mark_dirty(s);
}

/* Backdrop blur of a LOCAL-space rect: read the surface region under it,
 * blur it, and lerp back over the original by `opacity` (referenceMixRgba8
 * parity). `radius` is local; the current CTM maps it to device pixels.
 * ponytail: box×3 ≈ Gaussian; raise the pass count if the falloff reads flat. */
void native_sdk_cairo_blur(native_sdk_cairo_ctx_t *c, double x, double y,
                           double w, double h, double radius, double opacity) {
    if (radius <= 0 || w <= 0 || h <= 0) return;

    /* Local rect + radius -> device pixels via the current CTM. */
    double x0 = x, y0 = y, x1 = x + w, y1 = y + h;
    cairo_user_to_device(c->cr, &x0, &y0);
    cairo_user_to_device(c->cr, &x1, &y1);
    double ux = radius, uy = 0.0;
    cairo_user_to_device_distance(c->cr, &ux, &uy);
    const int r = clampi((int)ceil(sqrt(ux * ux + uy * uy)), 1, 128);

    /* Region of interest, and the apron the box filter reads around it. */
    const int rx0 = clampi((int)floor(fmin(x0, x1)), 0, c->width);
    const int ry0 = clampi((int)floor(fmin(y0, y1)), 0, c->height);
    const int rx1 = clampi((int)ceil(fmax(x0, x1)), 0, c->width);
    const int ry1 = clampi((int)ceil(fmax(y0, y1)), 0, c->height);
    if (rx1 <= rx0 || ry1 <= ry0) return;
    const int ax0 = clampi(rx0 - r, 0, c->width), ay0 = clampi(ry0 - r, 0, c->height);
    const int ax1 = clampi(rx1 + r, 0, c->width), ay1 = clampi(ry1 + r, 0, c->height);
    const int W = ax1 - ax0, H = ay1 - ay0;
    if (W <= 0 || H <= 0) return;

    cairo_surface_flush(c->surface);
    unsigned char *data = cairo_image_surface_get_data(c->surface);
    if (!data) return;
    const int stride = cairo_image_surface_get_stride(c->surface);

    uint8_t *buf = malloc((size_t)W * H * 4);
    if (!buf) return;
    for (int yy = 0; yy < H; yy++)
        memcpy(buf + (size_t)yy * W * 4, data + (size_t)(ay0 + yy) * stride + (size_t)ax0 * 4, (size_t)W * 4);
    blur_buffer(buf, W, H, r);

    /* Lerp the blurred apron back over the ROI, per byte (endian-agnostic). */
    const double op = opacity < 0 ? 0 : (opacity > 1 ? 1 : opacity);
    for (int yy = ry0; yy < ry1; yy++) {
        uint8_t *drow = data + (size_t)yy * stride;
        const uint8_t *brow = buf + ((size_t)(yy - ay0) * W + (rx0 - ax0)) * 4;
        for (int xx = 0; xx < rx1 - rx0; xx++) {
            uint8_t *o = drow + (size_t)(rx0 + xx) * 4;
            const uint8_t *s = brow + (size_t)xx * 4;
            for (int ch = 0; ch < 4; ch++) o[ch] = (uint8_t)(o[ch] + (s[ch] - o[ch]) * op + 0.5);
        }
    }
    free(buf);
    cairo_surface_mark_dirty_rectangle(c->surface, rx0, ry0, rx1 - rx0, ry1 - ry0);
}

void native_sdk_cairo_fill(native_sdk_cairo_ctx_t *c) { cairo_fill(c->cr); }

/* cap: 0 butt, 1 round. Joins always round (engine parity for path strokes). */
void native_sdk_cairo_stroke(native_sdk_cairo_ctx_t *c, double width, int cap) {
    cairo_set_line_width(c->cr, width);
    cairo_set_line_cap(c->cr, cap == 1 ? CAIRO_LINE_CAP_ROUND : CAIRO_LINE_CAP_BUTT);
    cairo_set_line_join(c->cr, CAIRO_LINE_JOIN_ROUND);
    cairo_stroke(c->cr);
}

/* ── Text ──────────────────────────────────────────────────────────────────
 * The bundled Geist faces (the same TTFs the reference renderer inks with),
 * loaded once via FreeType. The caller hands us CODEPOINTS and per-glyph
 * positions the runtime already laid out, so layout matches the reference
 * renderer exactly; we only map codepoint -> face glyph index and stamp. */

static FT_Library g_ft;
static FT_Face g_regular_ft;
static FT_Face g_mono_ft;
static cairo_font_face_t *g_regular;
static cairo_font_face_t *g_mono;

/* Register once (idempotent). Bytes are the embedded Geist TTFs, owned by the
 * caller for the process lifetime. Returns 1 once the regular face is up. */
int native_sdk_cairo_register_fonts(const uint8_t *reg, size_t reg_len,
                                    const uint8_t *mono, size_t mono_len) {
    if (g_regular) return 1;
    if (FT_Init_FreeType(&g_ft) != 0) return 0;
    if (FT_New_Memory_Face(g_ft, reg, (FT_Long)reg_len, 0, &g_regular_ft) != 0) return 0;
    g_regular = cairo_ft_font_face_create_for_ft_face(g_regular_ft, 0);
    if (mono && mono_len > 0 &&
        FT_New_Memory_Face(g_ft, mono, (FT_Long)mono_len, 0, &g_mono_ft) == 0) {
        g_mono = cairo_ft_font_face_create_for_ft_face(g_mono_ft, 0);
    }
    return g_regular ? 1 : 0;
}

/* Draw one already-laid-out run: the string `text` (not NUL-terminated,
 * `text_len` bytes) with its baseline at (x, y). The runtime carries the
 * engine-measured line breaks and pen positions, so — like the macOS host,
 * which redraws the string via CoreText — we let Cairo shape the bytes with
 * the bundled face rather than replay a glyph array. font_id 2 is the SDK's
 * default_mono_font_id; everything else inks sans (referenceFaceForFontId). */
void native_sdk_cairo_show_string(native_sdk_cairo_ctx_t *c, uint64_t font_id,
                                  double size, double x, double y,
                                  const char *text, size_t text_len, double r,
                                  double g, double b, double a) {
    if (!g_regular || text_len == 0) return;
    cairo_set_font_face(c->cr, (font_id == 2 && g_mono) ? g_mono : g_regular);
    cairo_set_font_size(c->cr, size);
    cairo_set_source_rgba(c->cr, r, g, b, a);
    char stackbuf[512];
    char *s = (text_len < sizeof(stackbuf)) ? stackbuf : malloc(text_len + 1);
    if (!s) return;
    memcpy(s, text, text_len);
    s[text_len] = 0;
    cairo_move_to(c->cr, x, y);
    cairo_show_text(c->cr, s);
    if (s != stackbuf) free(s);
}

/* ── Images ──────────────────────────────────────────────────────────────────
 * The runtime uploads registered image pixels through the binary side-channel
 * (root.zig uploadGpuSurfaceImage) BEFORE presenting a packet that draws them,
 * keyed by id host-wide (the macOS appkit_host image cache analog). We hold a
 * premultiplied ARGB32 cairo surface per id and blit it for draw_image.
 * ponytail: linear scan over a flat array — image count is a handful (avatars,
 * icons); swap for a hash map only if a UI ever registers hundreds. */

struct cairo_image_entry {
    uint64_t id;
    cairo_surface_t *surface;
};
static struct cairo_image_entry *g_images;
static size_t g_image_count;
static size_t g_image_cap;

static struct cairo_image_entry *cairo_image_find(uint64_t id) {
    for (size_t i = 0; i < g_image_count; i++)
        if (g_images[i].id == id) return &g_images[i];
    return NULL;
}

/* Store (or replace) an image by id. Input is straight RGBA8; we premultiply
 * into a native-endian ARGB32 surface. Returns 1 on success. */
int native_sdk_cairo_upload_image(uint64_t id, int width, int height,
                                  const uint8_t *rgba8, size_t rgba8_len) {
    if (id == 0 || width <= 0 || height <= 0) return 0;
    if ((size_t)width * (size_t)height * 4 > rgba8_len) return 0;
    cairo_surface_t *surf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    if (cairo_surface_status(surf) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surf);
        return 0;
    }
    unsigned char *data = cairo_image_surface_get_data(surf);
    const int stride = cairo_image_surface_get_stride(surf);
    for (int y = 0; y < height; y++) {
        uint32_t *row = (uint32_t *)(data + (size_t)y * stride);
        const uint8_t *src = rgba8 + (size_t)y * width * 4;
        for (int x = 0; x < width; x++) {
            const uint32_t r = src[x * 4 + 0], g = src[x * 4 + 1];
            const uint32_t b = src[x * 4 + 2], a = src[x * 4 + 3];
            /* premultiply (round-to-nearest) */
            const uint32_t pr = (r * a + 127) / 255;
            const uint32_t pg = (g * a + 127) / 255;
            const uint32_t pb = (b * a + 127) / 255;
            row[x] = (a << 24) | (pr << 16) | (pg << 8) | pb;
        }
    }
    cairo_surface_mark_dirty(surf);

    struct cairo_image_entry *e = cairo_image_find(id);
    if (e) {
        cairo_surface_destroy(e->surface);
        e->surface = surf;
        return 1;
    }
    if (g_image_count == g_image_cap) {
        const size_t cap = g_image_cap ? g_image_cap * 2 : 8;
        struct cairo_image_entry *grown = realloc(g_images, cap * sizeof(*grown));
        if (!grown) { cairo_surface_destroy(surf); return 0; }
        g_images = grown;
        g_image_cap = cap;
    }
    g_images[g_image_count].id = id;
    g_images[g_image_count].surface = surf;
    g_image_count++;
    return 1;
}

void native_sdk_cairo_remove_image(uint64_t id) {
    for (size_t i = 0; i < g_image_count; i++) {
        if (g_images[i].id != id) continue;
        cairo_surface_destroy(g_images[i].surface);
        g_images[i] = g_images[--g_image_count];
        return;
    }
}

/* Fit a src crop into dst preserving aspect (referenceImageDestinationRect
 * parity): 0 stretch, 1 contain, 2 cover. Writes the fitted rect to out[4]. */
static void cairo_image_fit(double dx, double dy, double dw, double dh,
                            double sw, double sh, int fit, double *out) {
    if (fit == 0 || sw <= 0 || sh <= 0) {
        out[0] = dx; out[1] = dy; out[2] = dw; out[3] = dh;
        return;
    }
    const double src_aspect = sw / sh;
    const double dst_aspect = dw / dh;
    double w = dw, h = dh;
    if (fit == 1) { /* contain */
        if (dst_aspect > src_aspect) { h = dh; w = h * src_aspect; }
        else { w = dw; h = w / src_aspect; }
    } else { /* cover */
        if (dst_aspect > src_aspect) { w = dw; h = w / src_aspect; }
        else { h = dh; w = h * src_aspect; }
    }
    out[0] = dx + (dw - w) * 0.5;
    out[1] = dy + (dh - h) * 0.5;
    out[2] = w;
    out[3] = h;
}

/* Blit a cached image into `dst` (local coords; the CTM maps to device),
 * cropped to `src` (has_src==0 => whole image), aspect-fitted per `fit`,
 * masked by the rounded-rect over the REQUESTED dst, at `opacity`.
 * Absent id => no-op (a transient the reference renderer skips too). */
void native_sdk_cairo_draw_image(native_sdk_cairo_ctx_t *c, uint64_t id,
                                 int has_src, double sx, double sy, double sw, double sh,
                                 double dx, double dy, double dw, double dh,
                                 double tl, double tr, double br, double bl,
                                 int fit, int sampling, double opacity) {
    struct cairo_image_entry *e = cairo_image_find(id);
    if (!e) return;
    const int iw = cairo_image_surface_get_width(e->surface);
    const int ih = cairo_image_surface_get_height(e->surface);
    if (iw <= 0 || ih <= 0 || dw <= 0 || dh <= 0) return;
    if (!has_src) { sx = 0; sy = 0; sw = iw; sh = ih; }
    /* clip src to the image bounds */
    if (sx < 0) { sw += sx; sx = 0; }
    if (sy < 0) { sh += sy; sy = 0; }
    if (sx + sw > iw) sw = iw - sx;
    if (sy + sh > ih) sh = ih - sy;
    if (sw <= 0 || sh <= 0) return;

    double fitted[4];
    cairo_image_fit(dx, dy, dw, dh, sw, sh, fit, fitted);

    cairo_save(c->cr);
    /* Mask to the requested dst (rounded), clipping cover overflow. */
    native_sdk_cairo_rounded_rect(c, dx, dy, dw, dh, tl, tr, br, bl);
    cairo_clip(c->cr);
    /* Also clip to the fitted rect so a `contain` letterbox stays transparent
     * rather than painted with EXTEND_PAD edge pixels. */
    cairo_rectangle(c->cr, fitted[0], fitted[1], fitted[2], fitted[3]);
    cairo_clip(c->cr);

    cairo_pattern_t *p = cairo_pattern_create_for_surface(e->surface);
    /* Pattern matrix maps user (fitted dst) space -> image (src) space. */
    cairo_matrix_t m;
    cairo_matrix_init_identity(&m);
    cairo_matrix_translate(&m, sx, sy);
    cairo_matrix_scale(&m, sw / fitted[2], sh / fitted[3]);
    cairo_matrix_translate(&m, -fitted[0], -fitted[1]);
    cairo_pattern_set_matrix(p, &m);
    cairo_pattern_set_filter(p, sampling == 0 ? CAIRO_FILTER_NEAREST : CAIRO_FILTER_GOOD);
    /* Clamp instead of tiling at the fitted edges. */
    cairo_pattern_set_extend(p, CAIRO_EXTEND_PAD);
    cairo_set_source(c->cr, p);
    cairo_paint_with_alpha(c->cr, opacity < 0 ? 0 : (opacity > 1 ? 1 : opacity));
    cairo_pattern_destroy(p);
    cairo_restore(c->cr);
}

/* Convert the opaque premultiplied ARGB32 surface to straight RGBA8.
 * Cairo stores each pixel as a native-endian u32 0xAARRGGBB, so the byte
 * extraction below is endianness-independent. Returns 0 if `out` is short. */
int native_sdk_cairo_read_rgba8(native_sdk_cairo_ctx_t *c, uint8_t *out, size_t out_len) {
    if ((size_t)c->width * (size_t)c->height * 4 > out_len) return 0;
    cairo_surface_flush(c->surface);
    const unsigned char *data = cairo_image_surface_get_data(c->surface);
    if (!data) return 0;
    const int stride = cairo_image_surface_get_stride(c->surface);
    for (int y = 0; y < c->height; y++) {
        const uint32_t *row = (const uint32_t *)(data + (size_t)y * (size_t)stride);
        uint8_t *dst = out + (size_t)y * (size_t)c->width * 4;
        for (int x = 0; x < c->width; x++) {
            const uint32_t px = row[x];
            uint32_t a = (px >> 24) & 0xff;
            uint32_t r = (px >> 16) & 0xff;
            uint32_t g = (px >> 8) & 0xff;
            uint32_t b = px & 0xff;
            if (a != 0 && a != 255) { /* un-premultiply */
                r = (r * 255 + a / 2) / a; if (r > 255) r = 255;
                g = (g * 255 + a / 2) / a; if (g > 255) g = 255;
                b = (b * 255 + a / 2) / a; if (b > 255) b = 255;
            }
            dst[x * 4 + 0] = (uint8_t)r;
            dst[x * 4 + 1] = (uint8_t)g;
            dst[x * 4 + 2] = (uint8_t)b;
            dst[x * 4 + 3] = (uint8_t)a;
        }
    }
    return 1;
}

void native_sdk_cairo_free(native_sdk_cairo_ctx_t *c) {
    if (!c) return;
    if (c->cr) cairo_destroy(c->cr);
    if (c->surface) cairo_surface_destroy(c->surface);
    free(c);
}
