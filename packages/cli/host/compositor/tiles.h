// Tiling: the fixed grid a large layer's raster is cut into, and the pool of slots those tiles
// live in. A layer bigger than one tile is rastered tile by tile, and the pool keeps the most
// recently used ones under a budget.

#ifndef NATIVE_COMPOSITOR_TILES_H
#define NATIVE_COMPOSITOR_TILES_H

#include "compositor.h"

#ifdef __cplusplus
extern "C" {
#endif

#define COMP_TILE_SIZE 256

/** How many tiles cover `bounds`: the 256-pixel grid cells it touches, edges included. */
int comp_tile_count(CompRect bounds);

/** The `index`th tile of `bounds`, aligned to the grid; 1 when the index is in range. */
int comp_tile_at(CompRect bounds, int index, CompRect *out);

/** Slots a layer's tiles occupy: the caller owns the arrays, one entry per slot. */
typedef struct {
  int capacity;
  int count;
  int tick;
  int *layer;
  int *x;
  int *y;
  int *last;
} CompTilePool;

/** Binds a pool to `capacity` slots, each with the four arrays the caller supplies. */
void comp_tile_pool_init(CompTilePool *p, int *layer, int *x, int *y, int *last, int capacity);

/**
 * The slot holding layer `layer`'s tile at (x, y), making one when there is room or evicting the
 * least recently used tile. Returns the slot, or -1 for an empty pool.
 */
int comp_tile_pool_touch(CompTilePool *p, int layer, int x, int y);

#ifdef __cplusplus
}
#endif

#endif
