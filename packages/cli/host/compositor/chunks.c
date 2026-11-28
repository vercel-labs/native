// The chunk walk: one rule, over whatever display list the host hands it.

#include <math.h>
#include <string.h>

#include <stdlib.h>
#include <stdio.h>

#include "chunks.h"
#include "layers.h"

/** The union of two rects, for a chunk's bounds as its commands join it. */
static CompRect chunk_record_union(CompRect a, CompRect b) {
  int x0 = a.x < b.x ? a.x : b.x;
  int y0 = a.y < b.y ? a.y : b.y;
  int x1 = a.x + a.w > b.x + b.w ? a.x + a.w : b.x + b.w;
  int y1 = a.y + a.h > b.y + b.h ? a.y + a.h : b.y + b.h;
  CompRect r = {x0, y0, x1 - x0, y1 - y0};
  return r;
}

/** Applies a matrix to a point. */
static void tf(const CompMatrix *m, double *x, double *y) {
  double px = *x, py = *y;
  *x = m->m[0] * px + m->m[4] * py + m->m[12];
  *y = m->m[1] * px + m->m[5] * py + m->m[13];
}

typedef struct {
  int kind; // 1 clip, 2 transform, 3 effect
  int32_t serial; // the element the state before this one belonged to, to put back on a pop
  CompMatrix m;
  int clip_count;
  float alpha;
  int transforms;
  int chunks_at;
  int at; // the command that opened this state
  // A plain clip inside a plain clip is folded into it: the clip it replaced, for the pop.
  int merged;
  CompWalkClip replaced;
} WalkState;

/** The state a list's commands are read in: what the commands before it in the paint opened. */
typedef struct {
  CompMatrix m;
  CompWalkClip clips[COMP_WALK_CLIPS];
  int clip_count;
  float alpha;
  int transforms;
  int32_t element; // the element whose state the commands being read sit under
  int effects;     // the opacity groups open around the list, which one chunk has to fill
  // The range of the list this call walks, so a mask's image and content are walked without
  // stepping outside the push, the split and the pop.
  int first, last;
  // The mask the commands being read sit in, when the walk split one, and its device box.
  int mask_role;
  int mask_id;
  CompRect mask_box;
  // The radius a blur the walk opened asks the host to apply to the chunks inside it, in page
  // pixels: a pure blur's content is rastered crisp and the pixels are blurred afterwards.
  double blur_sigma;
} WalkCtx;

/** Grows a chunk's box with one command's. */
static void grow_box(CompWalkChunk *c, const CompCmdView *v) {
  if (v->w <= 0 || v->h <= 0) return;
  double x0 = v->x, y0 = v->y, x1 = v->x + v->w, y1 = v->y + v->h;
  if (c->bw <= 0 || c->bh <= 0) {
    c->bx = x0;
    c->by = y0;
    c->bw = x1 - x0;
    c->bh = y1 - y0;
    return;
  }
  double nx0 = x0 < c->bx ? x0 : c->bx;
  double ny0 = y0 < c->by ? y0 : c->by;
  double nx1 = x1 > c->bx + c->bw ? x1 : c->bx + c->bw;
  double ny1 = y1 > c->by + c->bh ? y1 : c->by + c->bh;
  c->bx = nx0;
  c->by = ny0;
  c->bw = nx1 - nx0;
  c->bh = ny1 - ny0;
}

static void add_chunk(CompWalk *w, int list_id, int first, int count, int32_t serial,
                      const CompMatrix *m, const CompWalkClip *clips, int clip_count, float alpha,
                      int transforms) {
  if (w->count >= COMP_MAX_LAYERS) return;
  CompWalkChunk *c = &w->chunks[w->count++];
  c->list_id = list_id;
  c->serial = serial;
  c->first = first;
  c->count = count;
  c->m = *m;
  c->clip_count = clip_count;
  for (int i = 0; i < clip_count; i++) c->clips[i] = clips[i];
  c->alpha = alpha;
  c->transforms = transforms;
  c->bx = c->by = c->bw = c->bh = 0;
  c->full = 0;
  c->external = 0;
  c->mask_role = COMP_MASK_NONE;
  c->mask_id = 0;
  memset(&c->mask_box, 0, sizeof(c->mask_box));
  c->blur_sigma = 0;
}

/** Stamps a chunk just added with the mask role and the blur of the state it was walked in. */
static void stamp_mask(CompWalk *w, int at, const WalkCtx *s) {
  if (at < 0 || at >= w->count) return;
  CompWalkChunk *c = &w->chunks[at];
  if (s->blur_sigma > 0) c->blur_sigma = s->blur_sigma;
  if (s->mask_role == COMP_MASK_NONE) return;
  c->mask_role = s->mask_role;
  c->mask_id = s->mask_id;
  c->mask_box = s->mask_box;
}

/** The box of a run's commands, following the layer refs the run replays (see box_range). */
static void box_range(const CompCmdSource *src, void *ctx, int list_id, int first, int last,
                      CompWalkChunk *c, int refs);

/** The box a recorded layer's commands draw into, or `full` when a projection inside it moves them
 *  somewhere their own boxes don't say. */
static void layer_box(const CompCmdSource *src, void *ctx, int list_id, CompWalkChunk *c) {
  int n = src->count(ctx, list_id);
  if (n < 0) {
    c->full = 1;
    return;
  }
  box_range(src, ctx, list_id, 0, n, c, 0);
}

/** Why the last walk answered 0, for a host that reports it; 0 when it answered 1. */
static int g_walk_fail = 0;
static int g_walk_fail_at = -1;
static int g_walk_fail_kind = -1;

int comp_walk_failure(void) { return g_walk_fail; }
int comp_walk_failure_at(void) { return g_walk_fail_at; }
int comp_walk_failure_kind(void) { return g_walk_fail_kind; }

/** Whether a nested walk splits masks; see comp_walk_set_mask_split. -1 until it is known. */
static int g_mask_split = -1;
static int g_mask_seq = 0; // the mask ids handed out by the walk in progress

void comp_walk_set_mask_split(int on) { g_mask_split = on ? 1 : 0; }

int comp_walk_mask_split(void) {
  if (g_mask_split < 0) {
    const char *env = getenv("NATIVE_MASK_SPLIT");
    g_mask_split = env != NULL && env[0] == '1' && env[1] == 0;
  }
  return g_mask_split;
}

/** Whether the walk prints why it did or didn't split a mask: NATIVE_MASK_SPLIT_DEBUG=1. */
static int mask_split_debug(void) {
  static int on = -1;
  if (on < 0) {
    const char *env = getenv("NATIVE_MASK_SPLIT_DEBUG");
    on = env != NULL && env[0] == '1' && env[1] == 0;
  }
  return on;
}

/** The chunks the failing opacity group had gathered, for a host that reports them. */
static int g_walk_group_span = 0;
static CompWalkChunk g_walk_group[8];
int comp_walk_group_count(void) { return g_walk_group_span; }
const CompWalkChunk *comp_walk_group_chunk(int i) {
  return i >= 0 && i < g_walk_group_span && i < 8 ? &g_walk_group[i] : NULL;
}

/** Whether a command opens a state a POP (or a mask's or projection's own pop) closes. */
static int opens_state(const CompCmdView *v) {
  switch (v->kind) {
    case COMP_CMD_CLIP: case COMP_CMD_CLIP_ROUND: case COMP_CMD_CLIP_SHAPED:
    case COMP_CMD_TRANSFORM: case COMP_CMD_EFFECT:
      return 1;
    case COMP_CMD_MASK: case COMP_CMD_PERSPECTIVE:
      return v->op == 0;
    default:
      return 0;
  }
}

static int closes_state(const CompCmdView *v) {
  if (v->kind == COMP_CMD_POP) return 1;
  return (v->kind == COMP_CMD_MASK || v->kind == COMP_CMD_PERSPECTIVE) && v->op == 2;
}

/** The command that closes the state opened at `at`, or -1 when the list never closes it. */
static int group_end(const CompCmdSource *src, void *ctx, int list_id, int at, int total) {
  int depth = 0;
  for (int i = at; i < total; i++) {
    CompCmdView v;
    memset(&v, 0, sizeof(v));
    if (!src->view(ctx, list_id, i, &v)) continue;
    if (opens_state(&v)) depth++;
    else if (closes_state(&v)) {
      depth--;
      if (depth == 0) return i;
      if (depth < 0) return -1;
    }
  }
  return -1;
}

/** The command that splits the mask whose push is at `at`, or -1 when the list never splits it. */
static int mask_split_at(const CompCmdSource *src, void *ctx, int list_id, int at, int total) {
  int depth = 0;
  for (int i = at + 1; i < total; i++) {
    CompCmdView v;
    memset(&v, 0, sizeof(v));
    if (!src->view(ctx, list_id, i, &v)) continue;
    if (v.kind == COMP_CMD_MASK && v.op == 1 && depth == 0) return i;
    if (opens_state(&v)) depth++;
    else if (closes_state(&v)) {
      depth--;
      if (depth < 0) return -1;
    }
  }
  return -1;
}

/** Whether everything a split mask paints can be drawn as chunks: a backdrop filter shows the
 *  frame behind it, a canvas changes its pixels without a new command, and a mask or projection
 *  inside the span orders its own pixels against the content's. */
static int mask_span_ok(const CompCmdSource *src, void *ctx, int list_id, int first, int last) {
  for (int i = first; i < last; i++) {
    CompCmdView v;
    memset(&v, 0, sizeof(v));
    if (!src->view(ctx, list_id, i, &v)) continue;
    if (v.kind == COMP_CMD_EFFECT && v.backdrop) return 0;
    if (v.kind == COMP_CMD_DRAW && v.external) return 0;
    if ((v.kind == COMP_CMD_MASK || v.kind == COMP_CMD_PERSPECTIVE) && v.op == 0) return 0;
  }
  return 1;
}

/** Whether a run holds another blur, directly or inside a layer it paints: one chunk carries one
 *  radius, so a blur inside a blur is left to the replay. A ref past the scan's reach counts as
 *  one, conservatively. */
static int span_holds_blur(const CompCmdSource *src, void *ctx, int list_id, int first, int last,
                           int depth) {
  for (int i = first; i < last; i++) {
    CompCmdView v;
    memset(&v, 0, sizeof(v));
    if (!src->view(ctx, list_id, i, &v)) continue;
    if (v.kind == COMP_CMD_EFFECT && v.blur_sigma > 0) return 1;
    if (v.kind == COMP_CMD_LAYER_REF) {
      if (depth >= 8) return 1;
      int n = src->count(ctx, v.layer);
      if (n < 0 || span_holds_blur(src, ctx, v.layer, 0, n, depth + 1)) return 1;
    }
  }
  return 0;
}

/** Whether every clip open around a mask is a plain device rect, which a host can scissor by. */
static int plain_clips_only(const WalkCtx *s) {
  for (int k = 0; k < s->clip_count; k++) {
    const CompWalkClip *c = &s->clips[k];
    if (c->r > 0) return 0;
    if (c->x != (double)(int)c->x || c->y != (double)(int)c->y ||
        c->w != (double)(int)c->w || c->h != (double)(int)c->h) {
      return 0;
    }
  }
  return 1;
}

/** The device box a mask's push covers, out to whole pixels as the flat replay takes it. */
static CompRect mask_device_box(const CompCmdView *c, const CompMatrix *m) {
  double minx = 0, miny = 0, maxx = 0, maxy = 0;
  for (int k = 0; k < 4; k++) {
    double x = k == 0 || k == 3 ? c->x : c->x + c->w;
    double y = k < 2 ? c->y : c->y + c->h;
    tf(m, &x, &y);
    if (k == 0 || x < minx) minx = x;
    if (k == 0 || y < miny) miny = y;
    if (k == 0 || x > maxx) maxx = x;
    if (k == 0 || y > maxy) maxy = y;
  }
  double dx = floor(minx), dy = floor(miny);
  CompRect r = {(int)dx, (int)dy, (int)(ceil(maxx) - dx), (int)(ceil(maxy) - dy)};
  return r;
}

static int walk_list(const CompCmdSource *src, void *ctx, int list_id, double scale, CompWalk *w,
                     WalkCtx *s, int nested, int grouped);

/** Whether a layer's commands move things its boxes don't say or paint a layer of their own:
 *  what makes its chunk rastered over the whole frame, and keyless with a ref inside. */
static int layer_is_full(const CompCmdSource *src, void *ctx, int list_id, int blur) {
  int n = src->count(ctx, list_id);
  for (int i = 0; i < n; i++) {
    CompCmdView v;
    memset(&v, 0, sizeof(v));
    if (!src->view(ctx, list_id, i, &v)) continue;
    if (v.kind == COMP_CMD_TRANSFORM || v.kind == COMP_CMD_LAYER_REF) return 1;
    // Inside a mask's content, a pure blur is a chunk of its own that the host blurs, so the
    // layer is walked for it rather than kept whole.
    if (blur && v.kind == COMP_CMD_EFFECT && v.blur_sigma > 0) return 1;
  }
  return 0;
}

/** Paints a layer ref. A layer whose commands nest layers or transforms of their own is walked
 *  as if its commands stood in the parent, so each run inside it is a chunk of its own — keyed by
 *  its commands, rastered from its own box — instead of one chunk over the whole frame that holds
 *  every nested layer and has to be rastered again whenever any of them moves. A layer that can't
 *  be walked that way (an opacity group around it, which one chunk has to fill, or a state inside
 *  it the walk can't express) is one chunk, as before. */
static void walk_layer_ref(const CompCmdSource *src, void *ctx, const CompCmdView *c, double scale,
                           CompWalk *w, WalkCtx *s, int nested, int grouped) {
  int n = src->count(ctx, c->layer);
  if (n < 0) return;
  if (nested && s->effects == 0 &&
      layer_is_full(src, ctx, c->layer, s->mask_role == COMP_MASK_CONTENT)) {
    int at = w->count;
    int fail = g_walk_fail, fail_at = g_walk_fail_at, fail_kind = g_walk_fail_kind;
    int span = g_walk_group_span;
    WalkCtx inner = *s;
    inner.first = 0;
    inner.last = -1; // the layer's own list, not the range the ref sits in
    if (c->serial != 0) inner.element = c->serial;
    int before = w->count;
    if (walk_list(src, ctx, c->layer, scale, w, &inner, nested, grouped)) {
      if (mask_split_debug()) {
        fprintf(stderr, "native: layer %d nested ok chunks=%d\n", c->layer, w->count - before);
      }
      return;
    }
    if (mask_split_debug()) {
      fprintf(stderr, "native: layer %d nested failed fail=%d kind=%d\n", c->layer, g_walk_fail,
              g_walk_fail_kind);
    }
    // Back to the one chunk the layer was before the walk tried it.
    w->count = at;
    g_walk_fail = fail;
    g_walk_fail_at = fail_at;
    g_walk_fail_kind = fail_kind;
    g_walk_group_span = span;
  }
  int at = w->count;
  add_chunk(w, c->layer, 0, n, c->serial, &s->m, s->clips, s->clip_count, s->alpha, s->transforms);
  if (w->count > at) {
    layer_box(src, ctx, c->layer, &w->chunks[at]);
    stamp_mask(w, at, s);
  }
}

/** Opens a state on the walk's stack, saving what the pop puts back. */
static int walk_open(WalkState *st, int *depth, int kind, const WalkCtx *s, int chunks_at, int at) {
  if (*depth >= COMP_WALK_STATES) return 0;
  WalkState *o = &st[(*depth)++];
  o->kind = kind;
  o->m = s->m;
  o->clip_count = s->clip_count;
  o->alpha = s->alpha;
  o->transforms = s->transforms;
  o->chunks_at = chunks_at;
  o->at = at;
  o->serial = s->element;
  o->merged = 0;
  return 1;
}

/** Grows a run's box with a box drawn under `m`, a matrix relative to the run's own space. */
static void grow_box_through(CompWalkChunk *c, const CompCmdView *v, const CompMatrix *m) {
  if (v->w <= 0 || v->h <= 0) return;
  double xs[4] = {v->x, v->x + v->w, v->x + v->w, v->x};
  double ys[4] = {v->y, v->y, v->y + v->h, v->y + v->h};
  double x0 = 0, y0 = 0, x1 = 0, y1 = 0;
  for (int k = 0; k < 4; k++) {
    double x = xs[k], y = ys[k];
    tf(m, &x, &y);
    if (k == 0 || x < x0) x0 = x;
    if (k == 0 || y < y0) y0 = y;
    if (k == 0 || x > x1) x1 = x;
    if (k == 0 || y > y1) y1 = y;
  }
  CompCmdView b = *v;
  b.x = x0;
  b.y = y0;
  b.w = x1 - x0;
  b.h = y1 - y0;
  grow_box(c, &b);
}

/** How many nested layer refs a box may follow before the walk gives up on the run's box. */
#define COMP_WALK_REFS 6

/** The box of a run's commands in the chunk's own space: a layer ref is followed into the layer it
 *  paints, since the run's raster replays the ref and so holds what that layer draws. `full` when
 *  a projection, or a layer nested deeper than the walk follows, moves the pixels somewhere the
 *  boxes can't say. */
static void box_range(const CompCmdSource *src, void *ctx, int list_id, int first, int last,
                      CompWalkChunk *c, int refs) {
  CompMatrix stack[COMP_WALK_STATES];
  int depth = 0;
  CompMatrix rel = comp_matrix_scale(1.0f, 1.0f);
  c->bx = c->by = c->bw = c->bh = 0;
  for (int i = first; i < last; i++) {
    CompCmdView v;
    memset(&v, 0, sizeof(v));
    if (!src->view(ctx, list_id, i, &v)) continue;
    if (v.kind == COMP_CMD_PERSPECTIVE) {
      c->full = 1;
      return;
    }
    if (v.kind == COMP_CMD_LAYER_REF) {
      int n = src->count(ctx, v.layer);
      CompWalkChunk inner;
      memset(&inner, 0, sizeof(inner));
      if (n < 0 || refs >= COMP_WALK_REFS) {
        c->full = 1;
        return;
      }
      box_range(src, ctx, v.layer, 0, n, &inner, refs + 1);
      if (inner.full) {
        c->full = 1;
        return;
      }
      if (inner.bw > 0 && inner.bh > 0) {
        // The layer's box is in its own space; the state open here moves it into the run's.
        CompCmdView b;
        memset(&b, 0, sizeof(b));
        b.x = inner.bx;
        b.y = inner.by;
        b.w = inner.bw;
        b.h = inner.bh;
        grow_box_through(c, &b, &rel);
      }
      continue;
    }
    if (opens_state(&v)) {
      if (depth >= COMP_WALK_STATES) {
        c->full = 1;
        return;
      }
      stack[depth++] = rel;
      if (v.kind == COMP_CMD_TRANSFORM) rel = comp_matrix_mul(rel, v.matrix);
      // A filter paints its region, which reaches past what the commands inside it draw.
      if (v.kind == COMP_CMD_EFFECT && v.boxed) grow_box_through(c, &v, &rel);
    } else if (closes_state(&v)) {
      if (depth > 0) rel = stack[--depth];
    } else if (v.kind == COMP_CMD_DRAW && !v.empty) {
      grow_box_through(c, &v, &rel);
    }
  }
}

/** The box of the commands in [first, last), in the space the chunk's own transform maps from;
 *  `full` when the walk can't bound them (see box_range). */
static void group_box(const CompCmdSource *src, void *ctx, int list_id, int first, int last,
                      CompWalkChunk *c) {
  box_range(src, ctx, list_id, first, last, c, 0);
}

/**
 * Inside a layer the nested walk splits, a state the layer opens that holds no layer of its own
 * (a clip and what it clips, say) stays in the run it sits in: the layer's own drawing is one
 * picture between its nested layers, rastered together, so the antialiased edges of a clipped
 * background and the shadow around it meet in one raster as they do in the flat replay, rather
 * than in two rasters that a scaled layer resamples apart. Answers the index of the state's pop,
 * with the box of what it draws grown into `run` (or `full` set when an effect inside may draw
 * past its boxes), or -1 when the state holds a layer ref or something the walk can't match.
 */
static int absorb_state(const CompCmdSource *src, void *ctx, int list_id, int at, int total,
                        CompWalkChunk *run) {
  CompMatrix stack[COMP_WALK_STATES];
  int depth = 0;
  CompMatrix m = comp_matrix_identity();
  CompWalkChunk box = *run;
  for (int i = at; i < total; i++) {
    CompCmdView v;
    memset(&v, 0, sizeof(v));
    if (!src->view(ctx, list_id, i, &v)) continue;
    switch (v.kind) {
      case COMP_CMD_CLIP:
      case COMP_CMD_CLIP_ROUND:
      case COMP_CMD_CLIP_SHAPED:
      case COMP_CMD_TRANSFORM:
      case COMP_CMD_EFFECT:
        if (depth >= COMP_WALK_STATES) return -1;
        stack[depth++] = m;
        if (v.kind == COMP_CMD_TRANSFORM) m = comp_matrix_mul(m, v.matrix);
        if (v.kind == COMP_CMD_EFFECT && !v.simple) box.full = 1; // a filter draws past the boxes
        break;
      case COMP_CMD_POP:
        if (depth <= 0) return -1;
        m = stack[--depth];
        if (depth == 0) {
          *run = box;
          return i;
        }
        break;
      case COMP_CMD_DRAW:
        if (v.external) return -1; // a chunk of its own, wherever it stands
        grow_box_through(&box, &v, &m);
        break;
      default: // a layer ref, or a mask or projection, whose push the view doesn't tell from its pop
        return -1;
    }
  }
  return -1;
}

/** Whether a chunk's own commands turn or scale what it draws, which its matrix does not always
 *  say: a layer the walk keeps whole replays the transform at the head of its list into the
 *  raster, and the host would then blur pixels the transform already turned. */
static int chunk_holds_turn(const CompCmdSource *src, void *ctx, const CompWalkChunk *c) {
  for (int i = 0; i < c->count; i++) {
    CompCmdView v;
    memset(&v, 0, sizeof(v));
    if (!src->view(ctx, c->list_id, c->first + i, &v)) continue;
    if (v.kind != COMP_CMD_TRANSFORM) continue;
    double a = v.matrix.m[0], b = v.matrix.m[1], e = v.matrix.m[4], d = v.matrix.m[5];
    if (fabs(a - 1.0) > 1e-4 || fabs(d - 1.0) > 1e-4 || fabs(b) > 1e-6 || fabs(e) > 1e-6) return 1;
  }
  return 0;
}

/** Whether a blur's pixels are walked into a chunk the frame draws where they are, without
 *  scaling or turning them: the host blurs such a chunk's picture as it stands, and a chunk the
 *  frame resamples is one the replay has to blur instead. */
static int blur_chunk_plain(const CompCmdSource *src, void *ctx, const CompWalk *w, int at,
                            double scale) {
  if (at < 0 || at >= w->count) return 1;
  const CompWalkChunk *chunk = &w->chunks[at];
  double sx = chunk->m.m[0] / scale, sy = chunk->m.m[5] / scale;
  if (fabs(sx - 1.0) > 1e-4 || fabs(sy - 1.0) > 1e-4 || fabs(chunk->m.m[1]) > 1e-6 ||
      fabs(chunk->m.m[4]) > 1e-6) {
    return 0;
  }
  return !chunk_holds_turn(src, ctx, chunk);
}

#define WALK_FAIL(code, where, what) \
  do { g_walk_fail = (code); g_walk_fail_at = (where); g_walk_fail_kind = (what); return 0; } while (0)

/** Splits one list into chunks in the state `s`; answers 0 when it needs the flat replay. */
static int walk_list(const CompCmdSource *src, void *ctx, int list_id, double scale, CompWalk *w,
                     WalkCtx *s, int nested, int grouped) {
  WalkState st[COMP_WALK_STATES];
  int depth = 0;
  int open = -1;
  int total = src->count(ctx, list_id);
  // A mask's image and content are walked as the ranges around its split, so the list's ends are
  // the range's unless the caller asked for the whole list.
  int first = s->first > 0 ? s->first : 0;
  int last = s->last >= 0 ? s->last : total;
  for (int i = first; i < last; i++) {
    CompCmdView c;
    memset(&c, 0, sizeof(c));
    if (!src->view(ctx, list_id, i, &c)) continue;
    if (nested && list_id >= 0 &&
        (c.kind == COMP_CMD_CLIP || c.kind == COMP_CMD_CLIP_ROUND || c.kind == COMP_CMD_CLIP_SHAPED ||
         c.kind == COMP_CMD_TRANSFORM || c.kind == COMP_CMD_EFFECT)) {
      // A state with no layer inside it joins the layer's run (see absorb_state).
      CompWalkChunk run;
      if (open >= 0) {
        run = w->chunks[open];
      } else {
        memset(&run, 0, sizeof(run));
        run.list_id = list_id;
        run.serial = s->element;
        run.first = i;
        run.m = s->m;
        run.clip_count = s->clip_count;
        for (int k = 0; k < s->clip_count; k++) run.clips[k] = s->clips[k];
        run.alpha = s->alpha;
        run.transforms = s->transforms;
        run.mask_role = s->mask_role;
        run.mask_id = s->mask_id;
        run.mask_box = s->mask_box;
        run.blur_sigma = s->blur_sigma;
      }
      int end = absorb_state(src, ctx, list_id, i, total, &run);
      if (end >= 0 && (open >= 0 || w->count < COMP_MAX_LAYERS)) {
        run.count += end - i + 1;
        if (open >= 0) {
          w->chunks[open] = run;
        } else {
          w->chunks[w->count] = run;
          open = w->count++;
        }
        i = end;
        continue;
      }
    }
    if (!grouped && c.kind == COMP_CMD_EFFECT && c.blur_sigma > 0 &&
        s->mask_role == COMP_MASK_CONTENT) {
      // A pure blur inside a mask's content: the interior is walked as chunks of its own, drawn
      // crisp, and the chunk carries the radius for the host to blur the pixels by.
      int end = group_end(src, ctx, list_id, i, total);
      // A blur inside the blur's own content cannot be one radius on one chunk: the replay keeps
      // both.
      int nested_blur = span_holds_blur(src, ctx, list_id, i + 1, end, 0);
      if (end > i && !nested_blur) {
        int at = w->count;
        int fail = g_walk_fail, fail_at = g_walk_fail_at, fail_kind = g_walk_fail_kind;
        int span = g_walk_group_span;
        WalkCtx inner = *s;
        inner.first = i + 1;
        inner.last = end;
        inner.alpha *= (float)c.alpha;
        inner.blur_sigma = c.blur_sigma;
        int ok = walk_list(src, ctx, list_id, scale, w, &inner, nested, grouped);
        if (mask_split_debug()) {
          fprintf(stderr, "native: blur %d inner ok=%d chunks=%d fail=%d kind=%d\n", i, ok,
                  w->count - at, g_walk_fail, g_walk_fail_kind);
        }
        // Several chunks inside the filter are one unblurred chunk of its content carrying the
        // radius, since the host blurs the chunk's pixels as a whole.
        if (ok && w->count - at != 1) {
          w->count = at;
          add_chunk(w, list_id, i + 1, end - (i + 1), s->element, &inner.m, inner.clips,
                    inner.clip_count, inner.alpha, inner.transforms);
          if (w->count > at) {
            group_box(src, ctx, list_id, i + 1, end, &w->chunks[at]);
            stamp_mask(w, at, &inner);
          }
          ok = w->count - at == 1;
        }
        // Whatever the filter's pixels were walked into, one the frame rescales or turns keeps the
        // replay (see blur_chunk_plain): the filter's interior, the grouped chunk it may become,
        // and an empty interior alike.
        if (ok && !blur_chunk_plain(src, ctx, w, at, scale)) ok = 0;
        if (ok) {
          open = -1;
          i = end;
          continue;
        }
        w->count = at;
        g_walk_fail = fail;
        g_walk_fail_at = fail_at;
        g_walk_fail_kind = fail_kind;
        g_walk_group_span = span;
      }
    }
    if (!grouped && c.kind == COMP_CMD_MASK && c.op == 0 && comp_walk_mask_split()) {
      int plain = plain_clips_only(s);
      int axis = fabs(s->m.m[1]) < 1e-6 && fabs(s->m.m[4]) < 1e-6;
      // An opacity group above the mask fades the composed picture, which the chunks' own alphas
      // would fade before the mask instead: that mask stays whole.
      int opaque = s->alpha == 1.0f;
      if (mask_split_debug()) {
        fprintf(stderr, "native: mask push %d list=%d depth=%d clips=%d plain=%d axis=%d\n", i,
                list_id, depth, s->clip_count, plain, axis);
      }
      if (plain && axis && opaque) {
        // A mask whose image and content are walked apart: the host composites the content through
        // the image on surfaces of its own, so the image is rastered once and the content's chunks
        // are kept and rastered on their own. A span the chunks can't carry, or a range the walk
        // refuses, leaves the mask whole as before.
        int end = group_end(src, ctx, list_id, i, total);
        int split = end > i ? mask_split_at(src, ctx, list_id, i, end) : -1;
        int span_ok = split > i && mask_span_ok(src, ctx, list_id, i + 1, end);
        if (mask_split_debug()) {
          fprintf(stderr, "native: mask push %d end=%d split=%d span=%d\n", i, end, split, span_ok);
        }
        if (span_ok) {
          int at = w->count;
          int fail = g_walk_fail, fail_at = g_walk_fail_at, fail_kind = g_walk_fail_kind;
          int span = g_walk_group_span;
          int id = ++g_mask_seq;
          WalkCtx alpha = *s;
          alpha.first = i + 1;
          alpha.last = split;
          alpha.mask_role = COMP_MASK_ALPHA;
          alpha.mask_id = id;
          alpha.mask_box = mask_device_box(&c, &s->m);
          int ok = walk_list(src, ctx, list_id, scale, w, &alpha, nested, grouped);
          if (ok) {
            WalkCtx content = *s;
            content.first = split + 1;
            content.last = end;
            content.mask_role = COMP_MASK_CONTENT;
            content.mask_id = id;
            content.mask_box = alpha.mask_box;
            ok = walk_list(src, ctx, list_id, scale, w, &content, nested, grouped);
          }
          // Every chunk of the group has to know it is one: a chunk the ranged walk kept whole
          // without being stamped would draw outside the mask, so it falls back with the rest.
          for (int k = at; ok && k < w->count; k++) {
            if (w->chunks[k].mask_role == COMP_MASK_NONE) ok = 0;
          }
          if (mask_split_debug()) {
            fprintf(stderr, "native: mask push %d walked ok=%d chunks=%d fail=%d@%d kind=%d\n", i, ok,
                    w->count - at, g_walk_fail, g_walk_fail_at, g_walk_fail_kind);
          }
          if (ok) {
            open = -1;
            i = end;
            continue;
          }
          w->count = at;
          g_walk_fail = fail;
          g_walk_fail_at = fail_at;
          g_walk_fail_kind = fail_kind;
          g_walk_group_span = span;
        }
      }
    }
    int boundary = c.kind != COMP_CMD_DRAW;
    if (boundary) open = -1;
    if ((grouped || c.kind == COMP_CMD_MASK || c.kind == COMP_CMD_PERSPECTIVE) && opens_state(&c)) {
      // A state the chunks can't carry across their quads: it and all it holds is one chunk,
      // rastered with the state in it, under the state the walk has around it.
      int unsplittable =
          ((c.kind == COMP_CMD_CLIP || c.kind == COMP_CMD_CLIP_ROUND) &&
           (fabs(s->m.m[1]) > 1e-6 || fabs(s->m.m[4]) > 1e-6)) ||
          c.kind == COMP_CMD_CLIP_SHAPED || (c.kind == COMP_CMD_EFFECT && !c.simple) ||
          c.kind == COMP_CMD_MASK || c.kind == COMP_CMD_PERSPECTIVE ||
          // Past the walk's budgets the state is the chunk's own to replay, too.
          ((c.kind == COMP_CMD_CLIP || c.kind == COMP_CMD_CLIP_ROUND) &&
           s->clip_count >= COMP_WALK_CLIPS) ||
          depth >= COMP_WALK_STATES;
      if (unsplittable) {
        int end = group_end(src, ctx, list_id, i, total);
        if (end < 0) WALK_FAIL(9, i, (int)c.kind);
        int at = w->count;
        add_chunk(w, list_id, i, end + 1 - i, c.serial != 0 ? c.serial : s->element, &s->m, s->clips,
                  s->clip_count, s->alpha, s->transforms);
        if (w->count > at) {
          group_box(src, ctx, list_id, i, end + 1, &w->chunks[at]);
          stamp_mask(w, at, s);
        }
        i = end;
        continue;
      }
    }
    if (c.kind == COMP_CMD_CLIP || c.kind == COMP_CMD_CLIP_ROUND) {
      if (fabs(s->m.m[1]) > 1e-6 || fabs(s->m.m[4]) > 1e-6) WALK_FAIL(1, i, (int)c.kind); // rotated clip
      if (!walk_open(st, &depth, 1, s, w->count, i)) WALK_FAIL(3, i, (int)c.kind);
      if (c.serial != 0) s->element = c.serial;
      double x0 = c.x, y0 = c.y, x1 = c.x + c.w, y1 = c.y + c.h;
      tf(&s->m, &x0, &y0);
      tf(&s->m, &x1, &y1);
      CompWalkClip cl;
      cl.x = fmin(x0, x1);
      cl.y = fmin(y0, y1);
      cl.w = fabs(x1 - x0);
      cl.h = fabs(y1 - y0);
      cl.r = c.kind == COMP_CMD_CLIP_ROUND ? c.radius * scale : 0;
      cl.transforms = s->transforms; // how many transforms were open when the clip was pushed
      CompWalkClip *top = s->clip_count > 0 ? &s->clips[s->clip_count - 1] : NULL;
      if (nested && cl.r <= 0 && top != NULL && top->r <= 0) {
        // Two device-space rects clip to their intersection: one clip, so a page that nests
        // overflow boxes inside a layer doesn't run out of the budget.
        WalkState *o = &st[depth - 1];
        o->merged = 1;
        o->replaced = *top;
        double x0 = fmax(cl.x, top->x), y0 = fmax(cl.y, top->y);
        double x1 = fmin(cl.x + cl.w, top->x + top->w), y1 = fmin(cl.y + cl.h, top->y + top->h);
        top->x = x0;
        top->y = y0;
        top->w = x1 > x0 ? x1 - x0 : 0;
        top->h = y1 > y0 ? y1 - y0 : 0;
      } else {
        if (s->clip_count >= COMP_WALK_CLIPS) WALK_FAIL(2, i, (int)c.kind); // clip budget
        s->clips[s->clip_count++] = cl;
      }
    } else if (c.kind == COMP_CMD_CLIP_SHAPED) {
      WALK_FAIL(4, i, (int)c.kind);
    } else if (c.kind == COMP_CMD_TRANSFORM) {
      if (!walk_open(st, &depth, 2, s, w->count, i)) WALK_FAIL(3, i, (int)c.kind);
      if (c.serial != 0) s->element = c.serial;
      // The page's own transform applies to a point first, then the device scale: m = S . t.
      s->m = comp_matrix_mul(s->m, c.matrix);
      s->transforms++;
    } else if (c.kind == COMP_CMD_EFFECT) {
      if (!c.simple) {
        if (mask_split_debug()) {
          fprintf(stderr, "native: fail5 at %d blur=%g role=%d nested=%d grouped=%d\n", i,
                  c.blur_sigma, s->mask_role, nested, grouped);
        }
        WALK_FAIL(5, i, (int)c.kind);
      }
      if (!walk_open(st, &depth, 3, s, w->count, i)) WALK_FAIL(3, i, (int)c.kind);
      if (c.serial != 0) s->element = c.serial;
      s->alpha *= c.alpha;
      s->effects++;
    } else if (c.kind == COMP_CMD_POP) {
      if (depth <= 0) WALK_FAIL(6, i, (int)c.kind);
      depth--;
      if (grouped && st[depth].kind == 3 && w->count - st[depth].chunks_at > 1) {
        // An opacity group over several chunks is one chunk of what it holds, faded at draw: the
        // group's own push stays out of the range, so the raster is the contents at full alpha.
        int first = st[depth].at + 1;
        w->count = st[depth].chunks_at;
        add_chunk(w, list_id, first, i - first, s->element, &st[depth].m, s->clips,
                  st[depth].clip_count, s->alpha, st[depth].transforms);
        if (w->count > st[depth].chunks_at)
          group_box(src, ctx, list_id, first, i, &w->chunks[w->count - 1]);
      } else if (st[depth].kind == 3 && w->count - st[depth].chunks_at > 1) {
        // An opacity group that spans several chunks: name the group's opening command.
        g_walk_fail = 7;
        g_walk_fail_at = st[depth].at;
        g_walk_group_span = w->count - st[depth].chunks_at;
        g_walk_fail_kind = g_walk_group_span;
        int keep = g_walk_group_span < 8 ? g_walk_group_span : 8;
        for (int k = 0; k < keep; k++) g_walk_group[k] = w->chunks[st[depth].chunks_at + k];
        return 0;
      }
      if (st[depth].kind == 3) s->effects--;
      s->m = st[depth].m;
      s->clip_count = st[depth].clip_count;
      if (st[depth].merged && s->clip_count > 0) s->clips[s->clip_count - 1] = st[depth].replaced;
      s->alpha = st[depth].alpha;
      s->transforms = st[depth].transforms;
      s->element = st[depth].serial;
    } else if (c.kind == COMP_CMD_LAYER_REF) {
      walk_layer_ref(src, ctx, &c, scale, w, s, nested, grouped);
    } else if (c.kind == COMP_CMD_MASK || c.kind == COMP_CMD_PERSPECTIVE) {
      WALK_FAIL(8, i, (int)c.kind);
    } else {
      // A command the host measured with no area paints nothing; a chunk for it would split an
      // opacity group that holds only one thing worth drawing. It ends the run either way: a
      // chunk is replayed as the commands from `first` to `first + count`, so a run that stepped
      // over one would raster the commands it skipped in another's place.
      if (c.empty) {
        open = -1;
        continue;
      }
      if (c.external) {
        // A texture the host draws itself: a chunk of one command, with the runs on either side
        // of it rastered and kept on their own.
        int at = w->count;
        add_chunk(w, list_id, i, 1, s->element, &s->m, s->clips, s->clip_count, s->alpha,
                  s->transforms);
        if (w->count > at) {
          w->chunks[at].external = 1;
          grow_box(&w->chunks[at], &c);
          stamp_mask(w, at, s);
        }
        open = -1;
        continue;
      }
      if (open < 0) {
        int at = w->count;
        add_chunk(w, list_id, i, 0, s->element, &s->m, s->clips, s->clip_count, s->alpha,
                  s->transforms);
        open = w->count - 1;
        stamp_mask(w, at, s);
      }
      if (open >= 0) {
        w->chunks[open].count++;
        grow_box(&w->chunks[open], &c);
      }
    }
  }
  if (depth != 0) WALK_FAIL(9, last, -1); // an unclosed state
  return 1;
}

static int walk_root(const CompCmdSource *src, void *ctx, double scale, CompWalk *w, int nested,
                     int grouped) {
  w->count = 0;
  g_mask_seq = 0;
  g_walk_fail = 0;
  g_walk_fail_at = -1;
  g_walk_fail_kind = -1;
  WalkCtx s;
  memset(&s, 0, sizeof(s));
  s.m = comp_matrix_scale((float)scale, (float)scale);
  s.alpha = 1.0f;
  s.last = -1; // the whole root list
  return walk_list(src, ctx, -1, scale, w, &s, nested, grouped);
}

int comp_walk(const CompCmdSource *src, void *ctx, double scale, CompWalk *w) {
  return walk_root(src, ctx, scale, w, 0, 0);
}

int comp_walk_nested(const CompCmdSource *src, void *ctx, double scale, CompWalk *w) {
  return walk_root(src, ctx, scale, w, 1, 0);
}

int comp_walk_grouped(const CompCmdSource *src, void *ctx, double scale, CompWalk *w) {
  return walk_root(src, ctx, scale, w, 0, 1);
}

int comp_chunk_start(CompFrame *f, int32_t serial, int first, CompRect bounds, int eligible) {
  if (f->chunk_count >= COMP_MAX_LAYERS) return -1;
  CompChunk *c = &f->chunks[f->chunk_count];
  memset(c, 0, sizeof(*c));
  c->serial = serial;
  c->first = first;
  c->bounds = bounds;
  c->inflated = bounds;
  c->transform = f->transform;
  c->clip = f->clip;
  c->has_clip = f->has_clip;
  c->opacity = f->opacity;
  c->eligible = eligible;
  c->layer = -1;
  f->chunk_open = f->chunk_count;
  return f->chunk_count++;
}

void comp_chunk_grow(CompFrame *f, CompRect bounds) {
  if (f->chunk_open < 0 || f->chunk_open >= f->chunk_count) return;
  CompChunk *c = &f->chunks[f->chunk_open];
  c->bounds = chunk_record_union(c->bounds, bounds);
  c->inflated = chunk_record_union(c->inflated, bounds);
}

void comp_chunk_finish(CompFrame *f) { f->chunk_open = -1; }

int comp_chunk_layerize(CompFrame *f) {
  if (f->chunk_count <= 0) return 0;
  int layer_of[COMP_MAX_LAYERS];
  CompRect bounds[COMP_MAX_LAYERS];
  int layers = comp_layerize(f->chunks, f->chunk_count, layer_of, bounds, COMP_MAX_LAYERS);
  for (int i = 0; i < f->chunk_count; i++) f->chunks[i].layer = layer_of[i];
  return layers;
}

int comp_compose_chunks(CompFrame *f, CompBackend *b, const int *tex) {
  if (tex == NULL) return 0;
  int drawn = 0;
  for (int i = 0; i < f->chunk_count; i++) {
    if (tex[i] < 0) continue;
    comp_compose_chunk(b, &f->chunks[i], tex[i]);
    drawn++;
  }
  return drawn;
}

