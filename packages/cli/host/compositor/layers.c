// Layerization: the grouping rule and the geometry it needs.

#include <string.h>

#include "layers.h"

#include "backend.h"

static int chunk_rect_empty(CompRect r) { return r.w <= 0 || r.h <= 0; }

static int chunk_overlaps(CompRect a, CompRect b) {
  if (chunk_rect_empty(a) || chunk_rect_empty(b)) return 0;
  return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
}

static CompRect chunk_rect_union(CompRect a, CompRect b) {
  if (chunk_rect_empty(a)) return b;
  if (chunk_rect_empty(b)) return a;
  int x0 = a.x < b.x ? a.x : b.x;
  int y0 = a.y < b.y ? a.y : b.y;
  int x1 = a.x + a.w > b.x + b.w ? a.x + a.w : b.x + b.w;
  int y1 = a.y + a.h > b.y + b.h ? a.y + a.h : b.y + b.h;
  CompRect r = {x0, y0, x1 - x0, y1 - y0};
  return r;
}

/** The same matrix, to the precision a paint records it at. */
static int same_matrix(const CompMatrix *a, const CompMatrix *b) {
  for (int i = 0; i < 16; i++) {
    float d = a->m[i] - b->m[i];
    if (d < 0) d = -d;
    if (d > 0.00001f) return 0;
  }
  return 1;
}

int comp_same_state(const CompChunk *a, const CompChunk *b) {
  if (a->has_clip != b->has_clip) return 0;
  if (a->has_clip && (a->clip.x != b->clip.x || a->clip.y != b->clip.y ||
                      a->clip.w != b->clip.w || a->clip.h != b->clip.h)) {
    return 0;
  }
  if (!same_matrix(&a->transform, &b->transform)) return 0;
  return a->opacity == b->opacity;
}

int comp_layerize(const CompChunk *chunks, int count, int *layer_of, CompRect *layer_bounds, int max) {
  int layers = 0;
  // The first chunk of each layer: its property state is the layer's.
  int samples[COMP_MAX_LAYERS];
  if (layer_of != NULL) {
    for (int i = 0; i < count; i++) layer_of[i] = -1;
  }
  for (int i = 0; i < count; i++) {
    int target = -1;
    for (int j = layers - 1; j >= 0; j--) {
      // The most recent layer in the same state decides: merge into it unless a layer opened
      // after it would be painted over by this chunk.
      if (!comp_same_state(&chunks[samples[j]], &chunks[i])) continue;
      int blocked = 0;
      for (int k = j + 1; k < layers; k++) {
        if (chunk_overlaps(chunks[i].inflated, layer_bounds[k])) {
          blocked = 1;
          break;
        }
      }
      if (!blocked) target = j;
      break;
    }
    if (target < 0) {
      if (layers >= max || layers >= COMP_MAX_LAYERS) break;
      target = layers;
      samples[layers] = i;
      layer_bounds[layers] = chunks[i].inflated;
      layers++;
    } else {
      layer_bounds[target] = chunk_rect_union(layer_bounds[target], chunks[i].inflated);
    }
    if (layer_of != NULL) layer_of[i] = target;
  }
  return layers;
}

void comp_compose_chunk(CompBackend *b, const CompChunk *chunk, int tex) {
  if (b == NULL || b->vt == NULL || chunk == NULL || tex < 0) return;
  CompRect src = {0, 0, chunk->bounds.w, chunk->bounds.h};
  CompMatrix matrix = comp_matrix_mul(chunk->transform,
                                      comp_matrix_translate((float)chunk->bounds.x, (float)chunk->bounds.y));
  const CompRect *clip = chunk->has_clip ? &chunk->clip : NULL;
  b->vt->draw_quad(b, tex, src, &matrix, chunk->opacity, clip, 0.0f);
}
