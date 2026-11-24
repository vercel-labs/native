// The compositor core: matrices, the frame's layer list, its property stack, damage and the
// composite pass. The backend does the drawing; this file decides what to draw and where.

#include <math.h>
#include <string.h>

#include "compositor.h"

// ---------------------------------------------------------------------------
// Matrices

CompMatrix comp_matrix_identity(void) {
  CompMatrix m;
  memset(&m, 0, sizeof(m));
  m.m[0] = 1.0f;
  m.m[5] = 1.0f;
  m.m[10] = 1.0f;
  m.m[15] = 1.0f;
  return m;
}

CompMatrix comp_matrix_translate(float x, float y) {
  CompMatrix m = comp_matrix_identity();
  m.m[12] = x;
  m.m[13] = y;
  return m;
}

CompMatrix comp_matrix_scale(float x, float y) {
  CompMatrix m = comp_matrix_identity();
  m.m[0] = x;
  m.m[5] = y;
  return m;
}

CompMatrix comp_matrix_mul(CompMatrix b, CompMatrix a) {
  CompMatrix out;
  memset(&out, 0, sizeof(out));
  for (int col = 0; col < 4; col++) {
    for (int row = 0; row < 4; row++) {
      float sum = 0.0f;
      for (int k = 0; k < 4; k++) sum += b.m[k * 4 + row] * a.m[col * 4 + k];
      out.m[col * 4 + row] = sum;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Rects

static int rect_empty(CompRect r) {
  return r.w <= 0 || r.h <= 0;
}

static CompRect rect_union(CompRect a, CompRect b) {
  if (rect_empty(a)) return b;
  if (rect_empty(b)) return a;
  int x0 = a.x < b.x ? a.x : b.x;
  int y0 = a.y < b.y ? a.y : b.y;
  int x1 = a.x + a.w > b.x + b.w ? a.x + a.w : b.x + b.w;
  int y1 = a.y + a.h > b.y + b.h ? a.y + a.h : b.y + b.h;
  CompRect r = {x0, y0, x1 - x0, y1 - y0};
  return r;
}

/** The overlap of two rects; empty when they don't meet. */
static CompRect rect_intersect(CompRect a, CompRect b) {
  if (rect_empty(a) || rect_empty(b)) {
    CompRect none = {0, 0, 0, 0};
    return none;
  }
  int x0 = a.x > b.x ? a.x : b.x;
  int y0 = a.y > b.y ? a.y : b.y;
  int x1 = a.x + a.w < b.x + b.w ? a.x + a.w : b.x + b.w;
  int y1 = a.y + a.h < b.y + b.h ? a.y + a.h : b.y + b.h;
  if (x1 <= x0 || y1 <= y0) {
    CompRect none = {0, 0, 0, 0};
    return none;
  }
  CompRect r = {x0, y0, x1 - x0, y1 - y0};
  return r;
}

// ---------------------------------------------------------------------------
// Frames

void comp_reset(CompFrame *f) {
  memset(f, 0, sizeof(*f));
  f->transform = comp_matrix_identity();
  f->opacity = 1.0f;
  f->recording = 0;
  f->chunk_count = 0;
  f->chunk_open = -1;
}

void comp_begin(CompFrame *f) {
  f->pending_count = 0;
  f->chunk_count = 0;
  f->chunk_open = -1;
  f->recording = 1;
  f->depth = 0;
  f->transform = comp_matrix_identity();
  f->clip = (CompRect){0, 0, 0, 0};
  f->has_clip = 0;
  f->opacity = 1.0f;
}

void comp_push(CompFrame *f, int32_t serial, int kind, const CompMatrix *matrix,
               const CompRect *clip, float opacity) {
  if (f->depth >= COMP_MAX_DEPTH) return;
  CompProperty *p = &f->stack[f->depth];
  p->serial = serial;
  p->kind = kind;
  p->transform = f->transform;
  p->clip = f->clip;
  p->has_clip = f->has_clip;
  p->opacity = f->opacity;
  if ((kind == COMP_TRANSFORM || kind == COMP_PERSPECTIVE) && matrix != NULL) {
    // The matrix is the box's own, so the pushes already open apply after it.
    f->transform = comp_matrix_mul(f->transform, *matrix);
  } else if (kind >= COMP_CLIP_RECT && kind <= COMP_CLIP_SHAPE && clip != NULL) {
    f->clip = f->has_clip ? rect_intersect(f->clip, *clip) : *clip;
    f->has_clip = 1;
  } else if (kind == COMP_EFFECT) {
    f->opacity *= opacity;
  }
  f->depth++;
}

void comp_pop(CompFrame *f) {
  if (f->depth <= 0) return;
  f->depth--;
  CompProperty *p = &f->stack[f->depth];
  f->transform = p->transform;
  f->clip = p->clip;
  f->has_clip = p->has_clip;
  f->opacity = p->opacity;
}

int comp_layer_add(CompFrame *f, int32_t serial, int kind, CompRect bounds, int tex) {
  if (!f->recording || f->pending_count >= COMP_MAX_LAYERS) return -1;
  if (rect_empty(bounds)) return -1;
  CompLayer *l = &f->pending[f->pending_count];
  l->serial = serial;
  l->kind = kind;
  l->bounds = bounds;
  l->tex = tex;
  // The layer's texture is its own box, so its pixels reach the page through the pushes' state
  // first moving them to where the box is.
  l->transform = comp_matrix_mul(f->transform, comp_matrix_translate((float)bounds.x, (float)bounds.y));
  l->clip = f->clip;
  l->has_clip = f->has_clip;
  l->opacity = f->opacity;
  l->damage = (CompRect){0, 0, 0, 0};
  l->has_damage = 0;
  l->depth = f->depth;
  return f->pending_count++;
}

CompLayer *comp_layer_at(CompFrame *f, int index) {
  if (index < 0 || index >= f->pending_count) return NULL;
  return &f->pending[index];
}

int comp_layer_count(const CompFrame *f) {
  return f->pending_count;
}

void comp_layer_damage(CompFrame *f, int index, CompRect rect) {
  if (index < 0 || index >= f->pending_count) return;
  CompLayer *l = &f->pending[index];
  l->damage = rect_union(l->damage, rect);
  l->has_damage = 1;
  f->damage = rect_union(f->damage, rect);
  f->has_damage = 1;
}

void comp_commit(CompFrame *f) {
  if (!f->recording) return;
  memcpy(f->active, f->pending, sizeof(CompLayer) * (size_t)f->pending_count);
  f->active_count = f->pending_count;
  f->recording = 0;
  f->depth = 0;
  f->transform = comp_matrix_identity();
  f->clip = (CompRect){0, 0, 0, 0};
  f->has_clip = 0;
  f->opacity = 1.0f;
}

int comp_compose(CompFrame *f, CompBackend *b) {
  if (b == NULL || b->vt == NULL) return 0;
  int drawn = 0;
  for (int i = 0; i < f->active_count; i++) {
    CompLayer *l = &f->active[i];
    if (l->tex < 0) continue;
    CompRect src = {0, 0, l->bounds.w, l->bounds.h};
    const CompRect *clip = l->has_clip ? &l->clip : NULL;
    b->vt->draw_quad(b, l->tex, src, &l->transform, l->opacity, clip, 0.0f);
    drawn++;
  }
  return drawn;
}

/** The device box a layer covers under a matrix: its four corners' bounding box. */
static CompRect matrix_bounds(CompMatrix m, int w, int h) {
  float xs[4] = {0, (float)w, 0, (float)w};
  float ys[4] = {0, 0, (float)h, (float)h};
  float minx = 0, miny = 0, maxx = 0, maxy = 0;
  for (int i = 0; i < 4; i++) {
    float x = m.m[0] * xs[i] + m.m[4] * ys[i] + m.m[12];
    float y = m.m[1] * xs[i] + m.m[5] * ys[i] + m.m[13];
    if (i == 0 || x < minx) minx = x;
    if (i == 0 || y < miny) miny = y;
    if (i == 0 || x > maxx) maxx = x;
    if (i == 0 || y > maxy) maxy = y;
  }
  CompRect r = {(int)floorf(minx), (int)floorf(miny),
                (int)ceilf(maxx) - (int)floorf(minx), (int)ceilf(maxy) - (int)floorf(miny)};
  return r;
}

int comp_update_transform(CompFrame *f, int32_t serial, CompMatrix matrix) {
  int moved = 0;
  for (int i = 0; i < f->active_count; i++) {
    CompLayer *l = &f->active[i];
    if (l->serial != serial) continue;
    CompRect before = matrix_bounds(l->transform, l->bounds.w, l->bounds.h);
    l->transform = comp_matrix_mul(matrix, comp_matrix_translate((float)l->bounds.x, (float)l->bounds.y));
    CompRect after = matrix_bounds(l->transform, l->bounds.w, l->bounds.h);
    f->damage = rect_union(rect_union(f->damage, before), after);
    f->has_damage = 1;
    moved++;
  }
  return moved;
}

int comp_update_opacity(CompFrame *f, int32_t serial, float opacity) {
  int changed = 0;
  for (int i = 0; i < f->active_count; i++) {
    CompLayer *l = &f->active[i];
    if (l->serial != serial) continue;
    if (l->opacity != opacity) {
      f->damage = rect_union(f->damage, matrix_bounds(l->transform, l->bounds.w, l->bounds.h));
      f->has_damage = 1;
    }
    l->opacity = opacity;
    changed++;
  }
  return changed;
}

CompRect comp_take_damage(CompFrame *f) {
  CompRect r = f->damage;
  f->damage = (CompRect){0, 0, 0, 0};
  f->has_damage = 0;
  return r;
}
