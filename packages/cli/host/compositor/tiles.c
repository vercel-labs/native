// Tiling: the grid arithmetic and the least-recently-used pool.

#include <string.h>

#include "tiles.h"

static int div_floor(int a, int b) {
  int q = a / b;
  if (a % b != 0 && ((a < 0) != (b < 0))) q--;
  return q;
}

static int div_ceil(int a, int b) {
  int q = a / b;
  if (a % b != 0 && ((a < 0) == (b < 0))) q++;
  return q;
}

int comp_tile_count(CompRect bounds) {
  if (bounds.w <= 0 || bounds.h <= 0) return 0;
  int x0 = div_floor(bounds.x, COMP_TILE_SIZE), x1 = div_ceil(bounds.x + bounds.w, COMP_TILE_SIZE);
  int y0 = div_floor(bounds.y, COMP_TILE_SIZE), y1 = div_ceil(bounds.y + bounds.h, COMP_TILE_SIZE);
  return (x1 - x0) * (y1 - y0);
}

int comp_tile_at(CompRect bounds, int index, CompRect *out) {
  if (out == NULL || index < 0 || bounds.w <= 0 || bounds.h <= 0) return 0;
  int x0 = div_floor(bounds.x, COMP_TILE_SIZE), x1 = div_ceil(bounds.x + bounds.w, COMP_TILE_SIZE);
  int y0 = div_floor(bounds.y, COMP_TILE_SIZE), y1 = div_ceil(bounds.y + bounds.h, COMP_TILE_SIZE);
  int cols = x1 - x0, rows = y1 - y0;
  if (index >= cols * rows) return 0;
  out->x = (x0 + index % cols) * COMP_TILE_SIZE;
  out->y = (y0 + index / cols) * COMP_TILE_SIZE;
  out->w = COMP_TILE_SIZE;
  out->h = COMP_TILE_SIZE;
  return 1;
}

void comp_tile_pool_init(CompTilePool *p, int *layer, int *x, int *y, int *last, int capacity) {
  memset(p, 0, sizeof(*p));
  p->capacity = capacity;
  p->layer = layer;
  p->x = x;
  p->y = y;
  p->last = last;
}

int comp_tile_pool_touch(CompTilePool *p, int layer, int x, int y) {
  if (p == NULL || p->capacity <= 0) return -1;
  for (int i = 0; i < p->count; i++) {
    if (p->layer[i] == layer && p->x[i] == x && p->y[i] == y) {
      p->last[i] = ++p->tick;
      return i;
    }
  }
  int slot;
  if (p->count < p->capacity) {
    slot = p->count++;
  } else {
    // The least recently used tile gives its slot up.
    slot = 0;
    for (int i = 1; i < p->count; i++) {
      if (p->last[i] < p->last[slot]) slot = i;
    }
  }
  p->layer[slot] = layer;
  p->x[slot] = x;
  p->y[slot] = y;
  p->last[slot] = ++p->tick;
  return slot;
}
