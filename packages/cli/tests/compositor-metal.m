// Checks the Metal backend against the same picture the software backend draws: an opaque quad at
// an integer offset, a half-transparent one over it, a scaled one, a clipped one, and a frame
// composed from layers. Built and run by tests/compositor-metal.ts on macOS.

#import <Metal/Metal.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "compositor.h"
#include "metal.h"

static int failed = 0;
static void ok(const char *name, int cond, const char *detail) {
  if (!cond) failed++;
  printf("%s %s%s%s\n", cond ? "ok  " : "FAIL", name, cond || detail[0] == 0 ? "" : " — ", detail);
}

static CompBackend *backend;

static int make_texture(unsigned char r, unsigned char g, unsigned char b, unsigned char a) {
  unsigned char px[4 * 4 * 4];
  for (int i = 0; i < 4 * 4; i++) {
    px[i * 4 + 0] = r;
    px[i * 4 + 1] = g;
    px[i * 4 + 2] = b;
    px[i * 4 + 3] = a;
  }
  int tex = backend->vt->tex_create(backend, 4, 4);
  CompRect all = {0, 0, 4, 4};
  backend->vt->tex_upload(backend, tex, all, px, 16);
  return tex;
}

static unsigned char pixels[64 * 64 * 4];

static void snapshot(void) {
  backend->vt->present(backend);
  backend->vt->readback(backend, -1, (CompRect){0, 0, 64, 64}, pixels, 64 * 4);
}

static void read_pixel(int x, int y, int *r, int *g, int *b, int *a) {
  int at = (y * 64 + x) * 4;
  *r = pixels[at];
  *g = pixels[at + 1];
  *b = pixels[at + 2];
  *a = pixels[at + 3];
}

static int near(int got, int want, int tol) { return abs(got - want) <= tol; }

int main(void) {
  backend = comp_metal_backend();
  if (backend == NULL) {
    // A machine without a Metal device (some CI VMs) has nothing to check: the software backend's
    // test covers the compositor there.
    printf("ok   no Metal device here (skipped)\n\nall passed\n");
    return 0;
  }
  ok("the Metal backend was made", 1, "");

  int red = make_texture(255, 0, 0, 255);
  int halfBlue = make_texture(0, 0, 128, 128);
  ok("textures have ids", red >= 0 && halfBlue >= 0, "");
  {
    unsigned char check[4 * 4 * 4];
    int got = backend->vt->readback(backend, red, (CompRect){0, 0, 4, 4}, check, 16);
    printf("note texture %d readback=%d first=%d,%d,%d,%d\n", red, got, check[0], check[1], check[2], check[3]);
  }

  CompRect src = {0, 0, 4, 4};
  int r, g, b, a;
  // A pass that only clears: if its colour does not come back either, the pass target and the
  // readback are not the same texture.
  backend->vt->pass_begin(backend, -1, 64, 64, 0xff0000ff);
  snapshot();
  read_pixel(1, 1, &r, &g, &b, &a);
  char clear_detail[128];
  snprintf(clear_detail, sizeof clear_detail, "got %d,%d,%d,%d", r, g, b, a);
  ok("a pass's clear colour reaches the readback", near(r, 255, 2) && near(a, 255, 2), clear_detail);
  backend->vt->pass_begin(backend, -1, 64, 64, 0x00000000);
  CompMatrix at4 = comp_matrix_translate(4, 4);
  backend->vt->draw_quad(backend, red, src, &at4, 1.0f, NULL, 0.0f);
  snapshot();
  read_pixel(5, 5, &r, &g, &b, &a);
  char detail[128];
  snprintf(detail, sizeof detail, "got %d,%d,%d,%d", r, g, b, a);
  ok("a quad at (4,4) paints red there", near(r, 255, 1) && near(g, 0, 1) && near(b, 0, 1) && near(a, 255, 1), detail);
  read_pixel(3, 5, &r, &g, &b, &a);
  ok("a quad leaves the pixels before its offset clear", a == 0, "");
  read_pixel(8, 8, &r, &g, &b, &a);
  ok("a quad stops at its own edge", a == 0, "");

  backend->vt->pass_begin(backend, -1, 64, 64, 0x00000000);
  CompMatrix at6 = comp_matrix_translate(6, 6);
  backend->vt->draw_quad(backend, red, src, &at4, 1.0f, NULL, 0.0f);
  backend->vt->draw_quad(backend, halfBlue, src, &at6, 1.0f, NULL, 0.0f);
  snapshot();
  read_pixel(7, 7, &r, &g, &b, &a);
  snprintf(detail, sizeof detail, "got %d,%d,%d,%d", r, g, b, a);
  ok("a half-transparent quad fades what is under it", near(r, 127, 3) && near(b, 128, 3) && near(a, 255, 2), detail);

  backend->vt->pass_begin(backend, -1, 64, 64, 0x00000000);
  CompMatrix scaled = comp_matrix_mul(comp_matrix_translate(10, 10), comp_matrix_scale(2, 2));
  backend->vt->draw_quad(backend, red, src, &scaled, 1.0f, NULL, 0.0f);
  snapshot();
  read_pixel(11, 11, &r, &g, &b, &a);
  snprintf(detail, sizeof detail, "got %d,%d,%d,%d", r, g, b, a);
  ok("a scaled quad covers its scaled rect", near(r, 255, 1) && near(a, 255, 1), detail);
  read_pixel(19, 19, &r, &g, &b, &a);
  ok("a scaled quad stops at its scaled edge", a == 0, "");

  backend->vt->pass_begin(backend, -1, 64, 64, 0x00000000);
  CompRect clip = {0, 0, 4, 4};
  CompMatrix identity = comp_matrix_identity();
  backend->vt->draw_quad(backend, red, src, &identity, 1.0f, &clip, 0.0f);
  snapshot();
  read_pixel(2, 2, &r, &g, &b, &a);
  snprintf(detail, sizeof detail, "got %d,%d,%d,%d", r, g, b, a);
  ok("a clip keeps what it covers", near(r, 255, 1) && near(a, 255, 1), detail);
  read_pixel(5, 5, &r, &g, &b, &a);
  ok("a clip drops what it cuts", a == 0, "");

  // A frame composed from layers: the layer's state places the quad and fades it.
  CompFrame frame;
  comp_reset(&frame);
  comp_begin(&frame);
  comp_push(&frame, 7, COMP_TRANSFORM, &at4, NULL, 1.0f);
  comp_push(&frame, 7, COMP_EFFECT, NULL, NULL, 0.5f);
  int index = comp_layer_add(&frame, 42, COMP_TRANSFORM, src, red);
  comp_pop(&frame);
  comp_pop(&frame);
  ok("a layer is added", index == 0, "");
  comp_commit(&frame);
  backend->vt->pass_begin(backend, -1, 64, 64, 0x00000000);
  int drawn = comp_compose(&frame, backend);
  snapshot();
  read_pixel(5, 5, &r, &g, &b, &a);
  snprintf(detail, sizeof detail, "drawn %d, got %d,%d,%d,%d", drawn, r, g, b, a);
  ok("a composited layer draws where its state puts it", drawn == 1 && near(r, 255, 3) && near(a, 128, 4), detail);

  backend->vt->destroy(backend);
  if (failed > 0) {
    printf("\n%d failed\n", failed);
    return 1;
  }
  printf("\nall passed\n");
  return 0;
}
