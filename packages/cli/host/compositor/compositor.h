// A compositor's frame: the layers a paint recorded, the property pushes that surround them, and
// the damage each one carries. The host records a frame (property pushes, then layers whose
// rasters it made), commits it, and composes it through a backend.
//
// The frame is double-buffered: a recording builds the pending frame while the active one keeps
// compositing, and a commit swaps them. The flat replay stays the reference for pixels; a layer
// drawn by itself at the same device offset must match it bit for bit.

#ifndef NATIVE_COMPOSITOR_H
#define NATIVE_COMPOSITOR_H

#include <stdint.h>

#include "backend.h"

#ifdef __cplusplus
extern "C" {
#endif

/** A property push's node, as the display list records it (the host's PK_* kinds). */
typedef enum {
  COMP_TRANSFORM = 0,
  COMP_PERSPECTIVE = 1,
  COMP_CLIP_RECT = 2,
  COMP_CLIP_POLY = 3,
  COMP_CLIP_ELLIPSE = 4,
  COMP_CLIP_SHAPE = 5,
  COMP_EFFECT = 6,
  COMP_MASK = 7,
} CompKind;

/** One run of a paint's commands, as the compositor sees it. */
typedef struct {
  /** The element the run belongs to, and the host's first command and count for it. */
  int32_t serial;
  int first;
  int count;
  /** Where the run paints, in device pixels, and the union it can move over. */
  CompRect bounds;
  CompRect inflated;
  /** The property state the run sits in. */
  CompMatrix transform;
  CompRect clip;
  int has_clip;
  float opacity;
  /** Whether its element paints through a group of its own, so it may own a layer at all. */
  int eligible;
  /** The layer it was grouped into, once the chunks are layerized. */
  int layer;
} CompChunk;

/** One layer of a frame. */
typedef struct {
  /** The element the layer belongs to, and the kind of push that opened it. */
  int32_t serial;
  int32_t kind;
  /** The layer's content box in device pixels: the space its texture covers. */
  CompRect bounds;
  /** The backend texture holding the layer's raster; -1 until one is made. */
  int tex;
  /**
   * The aggregate state of the property pushes that surrounded the layer: its transform into the
   * page, the clip it sits inside, and the opacity of its effect groups.
   */
  CompMatrix transform;
  CompRect clip;
  int has_clip;
  float opacity;
  /** The part of the layer that changed since the last composed frame, in device pixels. */
  CompRect damage;
  int has_damage;
  /** How many of the frame's property pushes the layer sat inside when it was added. */
  int depth;
} CompLayer;

#define COMP_MAX_LAYERS 4096
#define COMP_MAX_DEPTH 128

typedef struct CompFrame CompFrame;

/** A property push: its kind and the element it belongs to. */
typedef struct {
  int32_t serial;
  int kind;
  CompMatrix transform;
  CompRect clip;
  int has_clip;
  float opacity;
} CompProperty;

struct CompFrame {
  /** The committed layers the next compose draws, and the recording's own. */
  CompLayer active[COMP_MAX_LAYERS];
  int active_count;
  CompLayer pending[COMP_MAX_LAYERS];
  int pending_count;
  int recording;

  /** The property pushes open while recording, and the state they aggregate to. */
  CompProperty stack[COMP_MAX_DEPTH];
  int depth;
  CompMatrix transform;
  CompRect clip;
  int has_clip;
  float opacity;

  CompRect damage;
  int has_damage;

  /** The chunks the host recorded for this frame, and the one still open. */
  CompChunk chunks[COMP_MAX_LAYERS];
  int chunk_count;
  int chunk_open;
};

/** Empties a frame: nothing committed, nothing recording. */
void comp_reset(CompFrame *f);

/** Starts recording a frame's layers. What is committed keeps composing until comp_commit. */
void comp_begin(CompFrame *f);

/**
 * Opens a property push; its state aggregates with the pushes around it. A transform push carries
 * the matrix that maps the box's own pixels into the page (the identity for a perspective layer,
 * whose warp is the backend's); a clip push carries the rect it clips to in the current space; an
 * effect push carries the alpha its group paints with.
 */
void comp_push(CompFrame *f, int32_t serial, int kind, const CompMatrix *matrix,
               const CompRect *clip, float opacity);
/** Closes the innermost push. A pop with nothing open does nothing. */
void comp_pop(CompFrame *f);

/**
 * Adds a layer inside the pushes that are open now. `bounds` is the layer's content box in device
 * pixels; `tex` is its raster, or -1 for a layer that has none yet. Returns its index, or -1 when
 * the frame is full or not recording.
 */
int comp_layer_add(CompFrame *f, int32_t serial, int kind, CompRect bounds, int tex);

/** The layer at `index` of the recording, or NULL. */
CompLayer *comp_layer_at(CompFrame *f, int index);

/** How many layers the recording has added. */
int comp_layer_count(const CompFrame *f);

/** Marks a layer's damaged rect; the frame keeps their union. */
void comp_layer_damage(CompFrame *f, int index, CompRect rect);

/** Ends the recording: the pending layers become the active ones for the next compose. */
void comp_commit(CompFrame *f);

/**
 * Composites the active layers through `b`, in the order they were recorded: each layer's texture
 * is drawn as a quad with its transform, clip and opacity. Returns the number of layers drawn.
 */
int comp_compose(CompFrame *f, CompBackend *b);

/**
 * Moves the active layers of element `serial` to `matrix`, which maps the element's own pixels
 * into the page as a paint would; every layer of that element moves. Returns how many layers it
 * moved, or 0 when the frame holds none for that element and the caller must paint instead.
 */
int comp_update_transform(CompFrame *f, int32_t serial, CompMatrix matrix);

/**
 * Sets the alpha of the active layers of element `serial`, as their opacity group would; returns
 * how many layers it changed, 0 when there are none.
 */
int comp_update_opacity(CompFrame *f, int32_t serial, float opacity);

/** The device rect the frame changed since the last comp_take_damage, or an empty rect. */
CompRect comp_take_damage(CompFrame *f);

#ifdef __cplusplus
}
#endif

#endif
