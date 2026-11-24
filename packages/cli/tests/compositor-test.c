// Checks the compositor core and its software backend: textures, quads with a matrix, opacity and
// a clip, the property stack's aggregation, and the pending/active commit. Built and run by
// tests/compositor.ts.

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "compositor.h"
#include "software.h"

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

static unsigned char frame_pixels[64 * 64 * 4];

static void read_pixel(int x, int y, int *r, int *g, int *b, int *a) {
  int at = (y * 64 + x) * 4;
  *r = frame_pixels[at];
  *g = frame_pixels[at + 1];
  *b = frame_pixels[at + 2];
  *a = frame_pixels[at + 3];
}

static int near(int got, int want, int tol) { return abs(got - want) <= tol; }

int main(void) {
  backend = comp_software_backend();
  if (backend == NULL) {
    printf("FAIL the software backend was made\n");
    return 1;
  }
  ok("the software backend was made", 1, "");

  int red = make_texture(255, 0, 0, 255);
  int halfBlue = make_texture(0, 0, 128, 128);
  ok("textures have ids", red >= 0 && halfBlue >= 0, "");

  // An opaque quad at an integer offset lands on those pixels and nowhere else.
  backend->vt->pass_begin(backend, -1, 64, 64, 0x00000000);
  CompMatrix at4 = comp_matrix_translate(4, 4);
  CompRect src = {0, 0, 4, 4};
  backend->vt->draw_quad(backend, red, src, &at4, 1.0f, NULL, 0.0f);
  backend->vt->readback(backend, -1, (CompRect){0, 0, 64, 64}, frame_pixels, 64 * 4);
  int r, g, b, a;
  read_pixel(5, 5, &r, &g, &b, &a);
  ok("a quad at (4,4) paints red there", near(r, 255, 1) && near(g, 0, 1) && near(b, 0, 1) && near(a, 255, 1), "");
  read_pixel(3, 5, &r, &g, &b, &a);
  ok("a quad leaves the pixels before its offset clear", a == 0, "");
  read_pixel(8, 8, &r, &g, &b, &a);
  ok("a quad stops at its own edge", a == 0, "");

  // A half-transparent quad composites over what is under it.
  CompMatrix at6 = comp_matrix_translate(6, 6);
  backend->vt->draw_quad(backend, halfBlue, src, &at6, 1.0f, NULL, 0.0f);
  backend->vt->readback(backend, -1, (CompRect){0, 0, 64, 64}, frame_pixels, 64 * 4);
  read_pixel(7, 7, &r, &g, &b, &a);
  ok("a half-transparent quad fades what is under it", near(r, 127, 3) && near(b, 128, 3) && near(a, 255, 2), "");

  // A quad scaled about a point covers the scaled rectangle.
  backend->vt->pass_begin(backend, -1, 64, 64, 0x00000000);
  CompMatrix scaled = comp_matrix_mul(comp_matrix_translate(10, 10), comp_matrix_scale(2, 2));
  backend->vt->draw_quad(backend, red, src, &scaled, 1.0f, NULL, 0.0f);
  backend->vt->readback(backend, -1, (CompRect){0, 0, 64, 64}, frame_pixels, 64 * 4);
  read_pixel(11, 11, &r, &g, &b, &a);
  ok("a scaled quad covers its scaled rect", near(r, 255, 1) && near(a, 255, 1), "");
  read_pixel(19, 19, &r, &g, &b, &a);
  ok("a scaled quad stops at its scaled edge", a == 0, "");

  // A clip cuts the quad in device space.
  backend->vt->pass_begin(backend, -1, 64, 64, 0x00000000);
  CompRect clip = {0, 0, 4, 4};
  CompMatrix identity = comp_matrix_identity();
  backend->vt->draw_quad(backend, red, src, &identity, 1.0f, &clip, 0.0f);
  backend->vt->readback(backend, -1, (CompRect){0, 0, 64, 64}, frame_pixels, 64 * 4);
  read_pixel(2, 2, &r, &g, &b, &a);
  ok("a clip keeps what it covers", near(r, 255, 1) && near(a, 255, 1), "");
  read_pixel(5, 5, &r, &g, &b, &a);
  ok("a clip drops what it cuts", a == 0, "");

  // The property stack aggregates the pushes around a layer, and pops restore them.
  CompFrame frame;
  comp_reset(&frame);
  comp_begin(&frame);
  comp_push(&frame, 7, COMP_TRANSFORM, &at4, NULL, 1.0f);
  comp_push(&frame, 7, COMP_EFFECT, NULL, NULL, 0.5f);
  CompMatrix state = frame.transform;
  ok("a transform push moves the state", state.m[12] == 4.0f && state.m[13] == 4.0f, "");
  ok("an effect push multiplies the alpha", fabsf(frame.opacity - 0.5f) < 1e-6f, "");
  int index = comp_layer_add(&frame, 42, COMP_TRANSFORM, src, red);
  ok("a layer is added inside the pushes", index == 0, "");
  comp_pop(&frame);
  ok("a pop restores the alpha", fabsf(frame.opacity - 1.0f) < 1e-6f, "");
  comp_pop(&frame);
  ok("a pop restores the transform", frame.transform.m[12] == 0.0f && frame.transform.m[13] == 0.0f, "");

  CompLayer *layer = comp_layer_at(&frame, 0);
  ok("the layer keeps the state it was added in",
     layer != NULL && fabsf(layer->opacity - 0.5f) < 1e-6f && layer->transform.m[12] == 4.0f, "");

  comp_layer_damage(&frame, 0, (CompRect){4, 4, 4, 4});
  CompRect damage = comp_take_damage(&frame);
  ok("damage is the damaged rect", damage.x == 4 && damage.y == 4 && damage.w == 4 && damage.h == 4, "");

  comp_commit(&frame);
  backend->vt->pass_begin(backend, -1, 64, 64, 0x00000000);
  int drawn = comp_compose(&frame, backend);
  ok("a committed frame composes its layers", drawn == 1, "");
  backend->vt->readback(backend, -1, (CompRect){0, 0, 64, 64}, frame_pixels, 64 * 4);
  read_pixel(5, 5, &r, &g, &b, &a);
  ok("a composite draws the layer where its state puts it", near(r, 255, 3) && near(a, 128, 4), "");

  // A recording that has not committed leaves the active frame alone.
  comp_begin(&frame);
  comp_layer_add(&frame, 43, COMP_TRANSFORM, src, red);
  backend->vt->pass_begin(backend, -1, 64, 64, 0x00000000);
  drawn = comp_compose(&frame, backend);
  backend->vt->readback(backend, -1, (CompRect){0, 0, 64, 64}, frame_pixels, 64 * 4);
  read_pixel(5, 5, &r, &g, &b, &a);
  ok("an uncommitted recording doesn't change what composes", drawn == 1 && near(a, 128, 4), "");

  backend->vt->destroy(backend);
  if (failed > 0) {
    printf("\n%d failed\n", failed);
    return 1;
  }
  printf("\nall passed\n");
  return 0;
}
