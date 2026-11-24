// Layerization: which runs of a paint share a layer, and in what order they composite.
//
// The paint stays the single source of painting order: a chunk is a run of its commands with the
// property state it sat in, and a layer is only a group of chunks that can be rastered and drawn
// together. This module decides that grouping. A chunk merges into the most recent layer with the
// same state that it doesn't overlap; one that would overlap a layer opened after that one starts
// a layer of its own, so the picture keeps its order.

#ifndef NATIVE_COMPOSITOR_LAYERS_H
#define NATIVE_COMPOSITOR_LAYERS_H

#include <stdint.h>

#include "compositor.h"

#ifdef __cplusplus
extern "C" {
#endif


/** Whether two chunks sit in the same property state: transform, clip and opacity all equal. */
int comp_same_state(const CompChunk *a, const CompChunk *b);

/**
 * Groups `count` chunks, in paint order, into at most `max` layers: `layer_of[i]` is the layer
 * chunk `i` belongs to, and `layer_bounds[l]` the union of its chunks' inflated bounds. Layers
 * composite in increasing id order. Returns the number of layers used.
 */
int comp_layerize(const CompChunk *chunks, int count, int *layer_of, CompRect *layer_bounds, int max);

/**
 * Draws one chunk's raster through `b`: the texture is the chunk's own bounds, moved by the
 * chunk's transform, cut by its clip and faded by its opacity. A host composes a frame by
 * drawing its chunks in paint order.
 */
void comp_compose_chunk(CompBackend *b, const CompChunk *chunk, int tex);

#ifdef __cplusplus
}
#endif

#endif
