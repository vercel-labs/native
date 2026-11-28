// Splitting a paint into chunks, portably: the host maps its display list to a command view and
// this module walks it, tracking the property state so every run of commands carries the state it
// sat in. Both hosts share the rule; only the rastering stays per host.

#ifndef NATIVE_COMPOSITOR_CHUNKS_H
#define NATIVE_COMPOSITOR_CHUNKS_H

#include <stdint.h>

#include "compositor.h"
#include "backend.h"

#ifdef __cplusplus
extern "C" {
#endif

/** What a command means to the walk. */
typedef enum {
  COMP_CMD_DRAW = 0,   // paints something; the run it belongs to grows
  COMP_CMD_TRANSFORM,  // opens a transform
  COMP_CMD_CLIP,       // opens a rectangular clip
  COMP_CMD_CLIP_ROUND, // opens a rounded clip
  COMP_CMD_CLIP_SHAPED,// opens a clip a rect and a radius can't express
  COMP_CMD_EFFECT,     // opens an opacity group, or one that is more than alpha
  COMP_CMD_POP,        // closes the innermost open state
  COMP_CMD_LAYER_REF,  // paints a recorded layer
  COMP_CMD_MASK,       // opens a mask, or splits or pops one
  COMP_CMD_PERSPECTIVE,// opens a projection, or pops one
} CompCmdKind;

/** One command, as the walker reads it. */
typedef struct {
  CompCmdKind kind;
  // The element the command belongs to: the property-tree node the runtime pushed it for, and 0
  // for a drawing command, which carries none.
  int32_t serial;
  double x, y, w, h, radius; // a clip's or a draw's geometry, in page pixels
  CompMatrix matrix;         // the page-space matrix a transform opens
  float alpha;               // an effect group's alpha
  int simple;                // an effect whose only work is that alpha
  int32_t layer;             // the layer a ref paints
  int boxed;                 // the host reported a drawing box for this command
  int empty;                 // the command's own box has no area, so it paints nothing
  // For COMP_CMD_MASK and COMP_CMD_PERSPECTIVE: 0 opens the group, 1 is a mask's split, 2 closes
  // it. Only comp_walk_grouped reads it, to find where a group ends.
  int op;
  // The command draws a texture the host keeps up to date itself (a canvas's buffer): it is a
  // chunk of its own, which the host draws from that texture instead of rastering.
  int external;
  // An effect whose filter shows the pixels behind it (a backdrop filter): what it draws depends
  // on the frame around it, so a mask that holds one is not split.
  int backdrop;
} CompCmdView;

/** How the walker reads a host's display list: the root is list -1, a layer its id. */
typedef struct {
  int (*count)(void *ctx, int list_id);
  int (*view)(void *ctx, int list_id, int index, CompCmdView *out);
} CompCmdSource;

#define COMP_WALK_CLIPS 8
#define COMP_WALK_STATES 128

/** What a chunk is to a mask the walk split: its image, the content it masks, or neither. */
typedef enum {
  COMP_MASK_NONE = 0,   // not part of a mask
  COMP_MASK_ALPHA = 1,  // paints the mask's image
  COMP_MASK_CONTENT = 2,// the content the image masks
} CompMaskRole;

/** A clip a chunk sits inside: a device-space rect, rounded when `r` is above zero. */
typedef struct {
  double x, y, w, h, r;
  int transforms; // how many transforms were open when the clip was pushed
} CompWalkClip;

/** One run of a paint with the state it sat in. */
typedef struct {
  int list_id;
  // The element the command that opened the run's state belongs to — the clip, transform, effect
  // or layer ref the run sits under — or 0 when the run is under none. Drawing commands carry no
  // serial of their own, so this is the element whose paint the run belongs to.
  int32_t serial;
  int first;
  int count;
  CompMatrix m; // page -> device
  int clip_count;
  CompWalkClip clips[COMP_WALK_CLIPS];
  float alpha;
  int transforms;
  // The box the run's commands draw into, in the run's own space before `m`: what a host rasters
  // instead of a whole surface, so a page with many layers doesn't pay for a surface each.
  double bx, by, bw, bh;
  int full; // a run whose commands move things the boxes don't describe: raster the whole frame
  int external; // one command the view marked external, which the host draws from its texture
  // A chunk of a mask the walk split (comp_walk_mask_split): the role it plays in the mask, the
  // mask's identity (the index of its push command in the list) and its device box, carried on
  // every chunk of the group so a host can tell a group from its neighbour and size its surfaces.
  int mask_role;
  int mask_id;
  CompRect mask_box;
} CompWalkChunk;

typedef struct {
  CompWalkChunk chunks[COMP_MAX_LAYERS];
  int count;
} CompWalk;

/**
 * Splits the root list into chunks. Answers 0 when the frame needs the flat replay: a mask, a
 * projection, a filter or blend group, a shaped or rotated clip, an opacity group over several
 * chunks, or a pop with nothing open.
 */
int comp_walk(const CompCmdSource *src, void *ctx, double scale, CompWalk *walk);

/** comp_walk, with a layer whose commands nest layers or transforms of their own walked as if its
 *  commands stood where its ref does: every run inside it is a chunk of its own, keyed and boxed
 *  by its own commands, so an unchanged nested layer is kept while a sibling moves. A layer the
 *  walk can't express that way is one chunk, as comp_walk makes it. */
int comp_walk_nested(const CompCmdSource *src, void *ctx, double scale, CompWalk *walk);

/**
 * Whether a nested walk splits a mask into the chunks that paint its image and the chunks that
 * paint the content it masks, instead of collapsing the whole mask into one chunk (see
 * CompMaskRole and CompWalkChunk's mask fields). Off by default, since a host that hasn't the
 * means to composite the two groups itself must keep the mask whole; a host whose backend can
 * draws the content onto a surface of the mask's box and composites it through the image. The
 * environment's `NATIVE_MASK_SPLIT=1` turns it on, `NATIVE_MASK_SPLIT=0` off, and a host that
 * knows its own backend sets it with comp_walk_set_mask_split.
 */
void comp_walk_set_mask_split(int on);
int comp_walk_mask_split(void);

/** How many masks one walk may split: past it a mask stays one chunk, which a host whose group
 *  table is smaller can still draw. 8 by default. */
void comp_walk_set_mask_max(int n);

/**
 * The same walk, for a host that rasters a chunk by replaying its range of commands with every
 * state in it: where comp_walk would hand the whole frame to the flat replay, the state that
 * can't be split — a filter or blend group, a rotated or shaped clip, a mask, a projection — and
 * everything inside it up to its pop becomes one chunk, and an opacity group over several chunks
 * becomes one chunk of its contents with the group's alpha on the chunk, so the compositor fades
 * it at draw. A chunk made this way may hold state commands; its box is every command inside it
 * mapped through the transforms inside it, and an effect's view reports the region its filter
 * paints (boxed). A clip past the clip budget, or any state past the state budget, is grouped the
 * same way. Answers 0 only for a list whose pushes and pops don't balance.
 */
int comp_walk_grouped(const CompCmdSource *src, void *ctx, double scale, CompWalk *walk);

/** Why the last walk answered 0: 1 a rotated clip, 2 the clip budget, 3 the state budget, 4 a
 *  shaped clip, 5 a filter or blend group, 6 a pop with nothing open, 7 an opacity group over
 *  several chunks, 8 a mask or projection, 9 an unclosed state; 0 when the walk succeeded. */
int comp_walk_failure(void);

/** Where the failing walk stopped — the command that opened the group for the opacity-group
 *  failure, the command it read otherwise — and what it found there: the command's kind, or for
 *  an opacity group over several chunks, how many chunks it had gathered. */
int comp_walk_failure_at(void);
int comp_walk_failure_kind(void);

// Recording chunks into a frame, for a host that composites them with the core's frame type.

/** Starts a chunk in the state the pushes around it have made; `first` is the host's first
 *  command and `bounds` where it paints. Answers its index, or -1 when the frame is full. */
int comp_chunk_start(CompFrame *f, int32_t serial, int first, CompRect bounds, int eligible);
/** Widens the open chunk's bounds, as more commands join it. */
void comp_chunk_grow(CompFrame *f, CompRect bounds);
/** Closes the open chunk. */
void comp_chunk_finish(CompFrame *f);
/** Groups the recorded chunks into layers. Returns the layer count. */
int comp_chunk_layerize(CompFrame *f);
/** Draws every recorded chunk's texture in order with the state it was recorded in. */
int comp_compose_chunks(CompFrame *f, CompBackend *b, const int *tex);

#ifdef __cplusplus
}
#endif

#endif
