// Checks layerization and the tile grid: which chunks share a layer, the order the layers keep,
// the tile arithmetic around the grid's edges and negative coordinates, and the least-recently
// used tile pool. Built and run by tests/compositor-core.ts.

#include <stdio.h>
#include <string.h>

#include "layers.h"
#include "tiles.h"
#include "chunks.h"
#include "software.h"

static int failed = 0;
static void ok(const char *name, int cond, const char *detail) {
  if (!cond) failed++;
  printf("%s %s%s%s\n", cond ? "ok  " : "FAIL", name, cond || detail[0] == 0 ? "" : " — ", detail);
}

static CompChunk chunk(CompRect b, float opacity, int eligible) {
  CompChunk c;
  memset(&c, 0, sizeof(c));
  c.bounds = b;
  c.inflated = b;
  c.transform = comp_matrix_identity();
  c.opacity = opacity;
  c.eligible = eligible;
  return c;
}

static void test_layers(void) {
  {
    CompChunk c[2];
    c[0] = chunk((CompRect){0, 0, 50, 50}, 1.0f, 1);
    c[1] = chunk((CompRect){100, 0, 50, 50}, 1.0f, 1);
    int of[2];
    CompRect bounds[4];
    int n = comp_layerize(c, 2, of, bounds, 4);
    ok("disjoint chunks in one state share a layer", n == 1 && of[0] == 0 && of[1] == 0, "");
    ok("the layer's bounds are their union", bounds[0].x == 0 && bounds[0].w == 150, "");
  }
  {
    CompChunk c[2];
    c[0] = chunk((CompRect){0, 0, 50, 50}, 1.0f, 1);
    c[1] = chunk((CompRect){0, 0, 50, 50}, 0.5f, 1);
    int of[2];
    CompRect bounds[4];
    int n = comp_layerize(c, 2, of, bounds, 4);
    ok("a different opacity opens a layer", n == 2 && of[0] == 0 && of[1] == 1, "");
  }
  {
    // A chunk in the first layer's state that would paint over a newer layer opens a third
    // layer, so it stays above it.
    CompChunk c[3];
    c[0] = chunk((CompRect){0, 0, 50, 50}, 1.0f, 1);
    c[1] = chunk((CompRect){100, 0, 50, 50}, 0.5f, 1);
    c[2] = chunk((CompRect){90, 0, 50, 50}, 1.0f, 1);
    int of[3];
    CompRect bounds[4];
    int n = comp_layerize(c, 3, of, bounds, 4);
    ok("a chunk that overlaps a later layer opens one of its own", n == 3 && of[2] == 2, "");
  }
  {
    // Overlapping chunks in the same state with nothing newer above them stay in one layer.
    CompChunk c[2];
    c[0] = chunk((CompRect){0, 0, 50, 50}, 1.0f, 1);
    c[1] = chunk((CompRect){10, 0, 50, 50}, 1.0f, 1);
    int of[2];
    CompRect bounds[4];
    int n = comp_layerize(c, 2, of, bounds, 4);
    ok("overlapping chunks of one layer share it", n == 1 && of[1] == 0, "");
  }
  {
    // The budget stops the grouping rather than overrunning the caller's arrays.
    CompChunk c[3];
    c[0] = chunk((CompRect){0, 0, 50, 50}, 1.0f, 1);
    c[1] = chunk((CompRect){0, 0, 50, 50}, 0.5f, 1);
    c[2] = chunk((CompRect){0, 0, 50, 50}, 0.25f, 1);
    int of[3];
    CompRect bounds[1];
    int n = comp_layerize(c, 3, of, bounds, 1);
    ok("the layer budget caps the result", n == 1 && of[1] == -1 && of[2] == -1, "");
  }
  {
    // An inflated (animating) chunk's layer keeps the union of where it can go.
    CompChunk c[1];
    c[0] = chunk((CompRect){0, 0, 50, 50}, 1.0f, 1);
    c[0].inflated = (CompRect){0, 0, 80, 50};
    int of[1];
    CompRect bounds[1];
    comp_layerize(c, 1, of, bounds, 1);
    ok("an inflated chunk gives its layer the union", bounds[0].w == 80, "");
  }
}

static unsigned char chunk_pixels[64 * 64 * 4];

static int chunk_texture(CompBackend *b, unsigned char r, unsigned char g, unsigned char bl, unsigned char a) {
  unsigned char px[4 * 4 * 4];
  for (int i = 0; i < 4 * 4; i++) {
    px[i * 4 + 0] = r;
    px[i * 4 + 1] = g;
    px[i * 4 + 2] = bl;
    px[i * 4 + 3] = a;
  }
  int tex = b->vt->tex_create(b, 4, 4);
  b->vt->tex_upload(b, tex, (CompRect){0, 0, 4, 4}, px, 16);
  return tex;
}

static void test_chunks(void) {
  CompBackend *b = comp_software_backend();
  ok("a backend for the chunk draws", b != NULL, "");
  if (b == NULL) return;
  int red = chunk_texture(b, 255, 0, 0, 255);
  int blue = chunk_texture(b, 0, 0, 255, 255);
  b->vt->pass_begin(b, -1, 64, 64, 0x00000000);
  CompChunk first = chunk((CompRect){0, 0, 4, 4}, 1.0f, 1);
  first.transform = comp_matrix_translate(10, 10);
  comp_compose_chunk(b, &first, red);
  CompChunk second = chunk((CompRect){0, 0, 4, 4}, 1.0f, 1);
  second.transform = comp_matrix_translate(12, 12);
  comp_compose_chunk(b, &second, blue);
  b->vt->present(b);
  b->vt->readback(b, -1, (CompRect){0, 0, 64, 64}, chunk_pixels, 64 * 4);
  int at = (11 * 64 + 11) * 4;
  ok("a chunk draws where its transform puts it",
     chunk_pixels[at] == 255 && chunk_pixels[at + 2] == 0 && chunk_pixels[at + 3] == 255, "");
  int over = (13 * 64 + 13) * 4;
  ok("a later chunk draws over an earlier one",
     chunk_pixels[over] == 0 && chunk_pixels[over + 2] == 255 && chunk_pixels[over + 3] == 255, "");

  b->vt->pass_begin(b, -1, 64, 64, 0x00000000);
  CompChunk faded = chunk((CompRect){0, 0, 4, 4}, 0.5f, 1);
  comp_compose_chunk(b, &faded, red);
  b->vt->present(b);
  b->vt->readback(b, -1, (CompRect){0, 0, 64, 64}, chunk_pixels, 64 * 4);
  ok("a chunk's opacity fades it", chunk_pixels[3] == 128 || chunk_pixels[3] == 127, "");
  b->vt->destroy(b);
}

static void test_updates(void) {
  CompBackend *b = comp_software_backend();
  ok("a backend for the frame updates", b != NULL, "");
  if (b == NULL) return;
  int red = chunk_texture(b, 255, 0, 0, 255);
  CompFrame f;
  comp_reset(&f);
  comp_begin(&f);
  CompMatrix at10 = comp_matrix_translate(10, 10);
  comp_push(&f, 42, COMP_TRANSFORM, &at10, NULL, 1.0f);
  comp_layer_add(&f, 42, COMP_TRANSFORM, (CompRect){0, 0, 4, 4}, red);
  comp_pop(&f);
  comp_commit(&f);
  b->vt->pass_begin(b, -1, 64, 64, 0x00000000);
  comp_compose(&f, b);
  b->vt->present(b);
  b->vt->readback(b, -1, (CompRect){0, 0, 64, 64}, chunk_pixels, 64 * 4);
  int first = (11 * 64 + 11) * 4;
  ok("a layer draws at its first transform", chunk_pixels[first] == 255 && chunk_pixels[first + 3] == 255, "");

  CompMatrix at20 = comp_matrix_translate(20, 10);
  ok("an update by serial finds the layer", comp_update_transform(&f, 42, at20) == 1, "");
  b->vt->pass_begin(b, -1, 64, 64, 0x00000000);
  comp_compose(&f, b);
  b->vt->present(b);
  b->vt->readback(b, -1, (CompRect){0, 0, 64, 64}, chunk_pixels, 64 * 4);
  int moved = (11 * 64 + 21) * 4;
  ok("the next composite draws it at the new transform",
     chunk_pixels[moved] == 255 && chunk_pixels[moved + 3] == 255, "");
  ok("its old place is clear", chunk_pixels[first + 3] == 0, "");

  ok("an opacity update finds the layer", comp_update_opacity(&f, 42, 0.5f) == 1, "");
  b->vt->pass_begin(b, -1, 64, 64, 0x00000000);
  comp_compose(&f, b);
  b->vt->present(b);
  b->vt->readback(b, -1, (CompRect){0, 0, 64, 64}, chunk_pixels, 64 * 4);
  ok("the layer fades with it", chunk_pixels[moved + 3] == 128 || chunk_pixels[moved + 3] == 127, "");
  ok("an element with no layer falls back", comp_update_transform(&f, 99, at10) == 0, "");
  b->vt->destroy(b);
}

static void test_chunk_record(void) {
  CompBackend *b = comp_software_backend();
  ok("a backend for the recorded chunks", b != NULL, "");
  if (b == NULL) return;
  int red = chunk_texture(b, 255, 0, 0, 255);
  int blue = chunk_texture(b, 0, 0, 255, 255);
  CompFrame f;
  comp_reset(&f);
  comp_begin(&f);
  CompMatrix at10 = comp_matrix_translate(10, 10);
  comp_push(&f, 1, COMP_TRANSFORM, &at10, NULL, 1.0f);
  ok("a chunk starts in the state around it",
     comp_chunk_start(&f, 1, 0, (CompRect){0, 0, 4, 4}, 1) == 0, "");
  comp_chunk_finish(&f);
  comp_pop(&f);
  comp_push(&f, 2, COMP_EFFECT, NULL, NULL, 0.5f);
  ok("the second chunk starts in its own state",
     comp_chunk_start(&f, 2, 4, (CompRect){6, 0, 4, 4}, 1) == 1, "");
  comp_chunk_grow(&f, (CompRect){6, 0, 8, 4});
  comp_chunk_finish(&f);
  comp_pop(&f);
  ok("the chunks recorded", f.chunk_count == 2, "");
  ok("a grown chunk keeps the union", f.chunks[1].bounds.w == 8, "");
  int layered = comp_chunk_layerize(&f);
  ok("different states make different layers", layered == 2 && f.chunks[0].layer == 0 && f.chunks[1].layer == 1, "");
  int tex[2] = {red, blue};
  b->vt->pass_begin(b, -1, 64, 64, 0x00000000);
  int drawn = comp_compose_chunks(&f, b, tex);
  b->vt->present(b);
  b->vt->readback(b, -1, (CompRect){0, 0, 64, 64}, chunk_pixels, 64 * 4);
  int first = (11 * 64 + 11) * 4;
  int second = (1 * 64 + 7) * 4;
  ok("the recorded chunks draw in order", drawn == 2 && chunk_pixels[first] == 255 &&
     chunk_pixels[first + 3] == 255, "");
  ok("the second chunk keeps its opacity",
     (chunk_pixels[second + 3] == 128 || chunk_pixels[second + 3] == 127) && chunk_pixels[second + 2] > 0, "");
  comp_begin(&f);
  ok("a new frame starts with no chunks", f.chunk_count == 0, "");
  b->vt->destroy(b);
}

/* A synthetic display list for the walker: the root plus one layer. */
static CompCmdView walk_cmds[8];
static int walk_root_len = 0;
static CompCmdView walk_layer_cmds[2];

static int walk_count(void *ctx, int list_id) {
  (void)ctx;
  if (list_id < 0) return walk_root_len;
  if (list_id == 3) return 2;
  return -1;
}
static int walk_view(void *ctx, int list_id, int index, CompCmdView *out) {
  (void)ctx;
  if (list_id < 0) {
    if (index < 0 || index >= walk_root_len) return 0;
    *out = walk_cmds[index];
    return 1;
  }
  if (list_id != 3 || index < 0 || index >= 2) return 0;
  *out = walk_layer_cmds[index];
  return 1;
}
static const CompCmdSource WALK_SOURCE = { walk_count, walk_view };

static void test_walk(void) {
  memset(walk_cmds, 0, sizeof(walk_cmds));
  walk_cmds[0].kind = COMP_CMD_DRAW;
  walk_cmds[1].kind = COMP_CMD_TRANSFORM;
  walk_cmds[1].matrix = comp_matrix_translate(10, 10);
  walk_cmds[2].kind = COMP_CMD_DRAW;
  walk_cmds[3].kind = COMP_CMD_POP;
  walk_cmds[4].kind = COMP_CMD_EFFECT;
  walk_cmds[4].alpha = 0.5f;
  walk_cmds[4].simple = 1;
  walk_cmds[5].kind = COMP_CMD_LAYER_REF;
  walk_cmds[5].layer = 3;
  walk_cmds[6].kind = COMP_CMD_POP;
  walk_root_len = 7;
  walk_layer_cmds[0].kind = COMP_CMD_DRAW;
  walk_layer_cmds[1].kind = COMP_CMD_DRAW;

  static CompWalk walk; // a walk holds room for a whole frame's chunks: too big for the stack
  ok("the walk takes a simple paint", comp_walk(&WALK_SOURCE, NULL, 2.0, &walk) == 1, "");
  ok("it records a chunk per run and per ref", walk.count == 3, "");
  if (walk.count == 3) {
    ok("the first chunk sits at the device scale", walk.chunks[0].m.m[0] == 2.0f, "");
    ok("a transform chunk carries the page transform then the scale",
       walk.chunks[1].m.m[12] == 20.0f && walk.chunks[1].transforms == 1, "");
    ok("a ref chunk carries its layer, its count and the group alpha",
       walk.chunks[2].list_id == 3 && walk.chunks[2].count == 2 && walk.chunks[2].alpha == 0.5f, "");
    ok("the clip list is empty", walk.chunks[2].clip_count == 0, "");
  }

  walk_cmds[1].kind = COMP_CMD_CLIP_SHAPED;
  static CompWalk shaped; // a walk holds room for a whole frame's chunks: too big for the stack
  ok("a shaped clip falls back", comp_walk(&WALK_SOURCE, NULL, 2.0, &shaped) == 0, "");
  walk_cmds[1].kind = COMP_CMD_TRANSFORM;

  walk_cmds[4].simple = 0;
  static CompWalk filtered; // a walk holds room for a whole frame's chunks: too big for the stack
  ok("a filter group falls back", comp_walk(&WALK_SOURCE, NULL, 2.0, &filtered) == 0, "");
  walk_cmds[4].simple = 1;

  /* A host that measures its commands hands the walk a box for each: the chunk carries what its
     run draws, in its own space, and a ref carries its sublist's. */
  walk_cmds[0].boxed = 1;
  walk_cmds[0].x = 0; walk_cmds[0].y = 0; walk_cmds[0].w = 10; walk_cmds[0].h = 10;
  walk_cmds[2].boxed = 1;
  walk_cmds[2].x = 20; walk_cmds[2].y = 4; walk_cmds[2].w = 10; walk_cmds[2].h = 6;
  walk_layer_cmds[0].boxed = 1;
  walk_layer_cmds[0].x = 1; walk_layer_cmds[0].y = 2; walk_layer_cmds[0].w = 4; walk_layer_cmds[0].h = 4;
  walk_layer_cmds[1].boxed = 1;
  walk_layer_cmds[1].x = 8; walk_layer_cmds[1].y = 2; walk_layer_cmds[1].w = 4; walk_layer_cmds[1].h = 4;
  // One walk at a time: the struct holds room for every chunk of a frame.
  static CompWalk more; // a walk holds room for a whole frame's chunks: too big for the stack
  ok("the walk takes a measured paint", comp_walk(&WALK_SOURCE, NULL, 2.0, &more) == 1, "");
  if (more.count == 3) {
    ok("a run's box is the union of its commands'",
       more.chunks[0].bx == 0 && more.chunks[0].bw == 10 && more.chunks[1].bx == 20 &&
       more.chunks[1].bh == 6, "");
    ok("a ref's box is its sublist's", more.chunks[2].bx == 1 && more.chunks[2].bw == 11, "");
  }

  /* A command with no area paints nothing, so it opens no run of its own. */
  walk_cmds[2].w = 0;
  walk_cmds[2].h = 0;
  walk_cmds[2].empty = 1;
  ok("a command with no area opens no chunk", comp_walk(&WALK_SOURCE, NULL, 2.0, &more) == 1 &&
     more.count == 2, "");
  walk_cmds[2].w = 10;
  walk_cmds[2].h = 6;
  walk_cmds[2].empty = 0;

  /* An opacity group that gathers more than one run can't be composited as alpha: it falls back,
     and the walk names it. */
  walk_cmds[0].kind = COMP_CMD_EFFECT;
  walk_cmds[0].alpha = 0.5f;
  walk_cmds[0].simple = 1;
  walk_cmds[1].kind = COMP_CMD_DRAW;
  walk_cmds[1].boxed = 1;
  walk_cmds[1].x = 1; walk_cmds[1].y = 1; walk_cmds[1].w = 4; walk_cmds[1].h = 4;
  walk_cmds[2].kind = COMP_CMD_TRANSFORM;
  walk_cmds[2].matrix = comp_matrix_translate(4, 0);
  walk_cmds[3].kind = COMP_CMD_DRAW;
  walk_cmds[3].boxed = 1;
  walk_cmds[3].x = 2; walk_cmds[3].y = 2; walk_cmds[3].w = 4; walk_cmds[3].h = 4;
  walk_cmds[4].kind = COMP_CMD_POP;
  walk_cmds[5].kind = COMP_CMD_POP;
  walk_root_len = 6;
  ok("an opacity group over two runs falls back", comp_walk(&WALK_SOURCE, NULL, 2.0, &more) == 0 &&
     comp_walk_failure() == 7, "");

  /* The grouped walk, for a host that rasters a chunk with the states in it, makes that group one
     chunk of what it holds instead, faded at draw. Its box is both runs, the second through the
     transform inside the group. */
  ok("the grouped walk takes an opacity group over two runs",
     comp_walk_grouped(&WALK_SOURCE, NULL, 2.0, &more) == 1 && more.count == 1, "");
  if (more.count == 1) {
    ok("the group's chunk is what it holds, without its own push and pop",
       more.chunks[0].first == 1 && more.chunks[0].count == 4, "");
    ok("the group's alpha is the chunk's", more.chunks[0].alpha == 0.5f, "");
    ok("the group's box reaches through its transform",
       more.chunks[0].bx == 1 && more.chunks[0].by == 1 && more.chunks[0].bw == 9 && more.chunks[0].bh == 5, "");
    ok("the group's chunk sits under the state outside it", more.chunks[0].transforms == 0, "");
  }

  /* A filter group is one chunk with its push and pop in it, and its box is the region the filter
     paints. */
  walk_cmds[0].simple = 0;
  walk_cmds[0].boxed = 1;
  walk_cmds[0].x = -2; walk_cmds[0].y = -2; walk_cmds[0].w = 12; walk_cmds[0].h = 12;
  ok("the grouped walk takes a filter group", comp_walk_grouped(&WALK_SOURCE, NULL, 2.0, &more) == 1 &&
     more.count == 1, "");
  if (more.count == 1) {
    ok("the filter's chunk holds the whole group", more.chunks[0].first == 0 && more.chunks[0].count == 6 &&
       more.chunks[0].alpha == 1.0f, "");
    ok("the filter's chunk covers the region it paints",
       more.chunks[0].bx == -2 && more.chunks[0].bw == 12 && more.chunks[0].bh == 12, "");
  }
  ok("the plain walk still hands a filter group to the replay",
     comp_walk(&WALK_SOURCE, NULL, 2.0, &more) == 0 && comp_walk_failure() == 5, "");

  /* A shaped clip between two runs is a chunk of its own between theirs. */
  memset(walk_cmds, 0, sizeof(walk_cmds));
  for (int k = 0; k < 5; k++) {
    walk_cmds[k].kind = COMP_CMD_DRAW;
    walk_cmds[k].boxed = 1;
    walk_cmds[k].x = k; walk_cmds[k].y = 0; walk_cmds[k].w = 2; walk_cmds[k].h = 2;
  }
  walk_cmds[1].kind = COMP_CMD_CLIP_SHAPED;
  walk_cmds[3].kind = COMP_CMD_POP;
  walk_root_len = 5;
  ok("the grouped walk takes a shaped clip", comp_walk_grouped(&WALK_SOURCE, NULL, 1.0, &more) == 1 &&
     more.count == 3, "");
  if (more.count == 3) {
    ok("the clip's chunk runs from its push to its pop", more.chunks[1].first == 1 && more.chunks[1].count == 3, "");
    ok("the runs around it keep their own chunks", more.chunks[0].count == 1 && more.chunks[2].first == 4, "");
  }

  /* A clip under a rotation is grouped from the clip, with the rotation on the chunk. */
  walk_cmds[1].kind = COMP_CMD_TRANSFORM;
  walk_cmds[1].matrix = comp_matrix_scale(1, 1);
  walk_cmds[1].matrix.m[0] = 0.0f; walk_cmds[1].matrix.m[1] = 1.0f;
  walk_cmds[1].matrix.m[4] = -1.0f; walk_cmds[1].matrix.m[5] = 0.0f;
  walk_cmds[2].kind = COMP_CMD_CLIP;
  walk_cmds[3].kind = COMP_CMD_DRAW;
  walk_cmds[4].kind = COMP_CMD_POP;
  walk_cmds[5].kind = COMP_CMD_POP;
  walk_root_len = 6;
  ok("the plain walk hands a rotated clip to the replay",
     comp_walk(&WALK_SOURCE, NULL, 1.0, &more) == 0 && comp_walk_failure() == 1, "");
  ok("the grouped walk takes a rotated clip", comp_walk_grouped(&WALK_SOURCE, NULL, 1.0, &more) == 1 &&
     more.count == 2, "");
  if (more.count == 2) {
    ok("the rotated clip's chunk is the clip and what it holds",
       more.chunks[1].first == 2 && more.chunks[1].count == 3 && more.chunks[1].m.m[1] == 1.0f, "");
  }

  /* A mask is grouped from its push to its own pop, past its split. */
  memset(walk_cmds, 0, sizeof(walk_cmds));
  for (int k = 0; k < 5; k++) {
    walk_cmds[k].kind = COMP_CMD_DRAW;
    walk_cmds[k].boxed = 1;
    walk_cmds[k].x = 0; walk_cmds[k].y = 0; walk_cmds[k].w = 2; walk_cmds[k].h = 2;
  }
  walk_cmds[0].kind = COMP_CMD_MASK; walk_cmds[0].op = 0;
  walk_cmds[2].kind = COMP_CMD_MASK; walk_cmds[2].op = 1;
  walk_cmds[4].kind = COMP_CMD_MASK; walk_cmds[4].op = 2;
  walk_root_len = 5;
  ok("the grouped walk takes a mask as one chunk", comp_walk_grouped(&WALK_SOURCE, NULL, 1.0, &more) == 1 &&
     more.count == 1 && more.chunks[0].first == 0 && more.chunks[0].count == 5, "");
  walk_root_len = 4;
  ok("a mask that never pops still falls back", comp_walk_grouped(&WALK_SOURCE, NULL, 1.0, &more) == 0, "");
  walk_root_len = 5;
  ok("the nested walk takes a mask as one chunk", comp_walk_nested(&WALK_SOURCE, NULL, 1.0, &more) == 1 &&
     more.count == 1 && more.chunks[0].first == 0 && more.chunks[0].count == 5, "");
}

static void test_tiles(void) {
  ok("a small box is one tile", comp_tile_count((CompRect){0, 0, 100, 100}) == 1, "");
  ok("a box past a grid line is two tiles", comp_tile_count((CompRect){0, 0, 300, 100}) == 2, "");
  ok("a box exactly on the grid is one tile", comp_tile_count((CompRect){0, 0, 256, 256}) == 1, "");
  ok("a box one pixel past the grid is two", comp_tile_count((CompRect){0, 0, 257, 1}) == 2, "");
  ok("a box across the origin touches four tiles", comp_tile_count((CompRect){-10, -10, 20, 20}) == 4, "");
  CompRect t;
  ok("the first tile is aligned to the grid",
     comp_tile_at((CompRect){10, 10, 10, 10}, 0, &t) && t.x == 0 && t.y == 0 && t.w == COMP_TILE_SIZE, "");
  ok("the second tile of a row is the next cell",
     comp_tile_at((CompRect){0, 0, 300, 100}, 1, &t) && t.x == COMP_TILE_SIZE && t.y == 0, "");
  ok("an index past the grid is refused", comp_tile_at((CompRect){0, 0, 10, 10}, 1, &t) == 0, "");

  int layer[2], x[2], y[2], last[2];
  CompTilePool pool;
  comp_tile_pool_init(&pool, layer, x, y, last, 2);
  int a = comp_tile_pool_touch(&pool, 1, 0, 0);
  int b = comp_tile_pool_touch(&pool, 1, 256, 0);
  ok("a pool hands out slots", a == 0 && b == 1, "");
  int again = comp_tile_pool_touch(&pool, 1, 0, 0);
  ok("a tile already held returns its slot", again == a, "");
  int c = comp_tile_pool_touch(&pool, 2, 0, 0);
  ok("a full pool evicts the least recently used tile", c == b && pool.layer[b] == 2, "");
}

int main(void) {
  test_layers();
  test_chunks();
  test_updates();
  test_chunk_record();
  test_walk();
  test_tiles();
  if (failed > 0) {
    printf("\n%d failed\n", failed);
    return 1;
  }
  printf("\nall passed\n");
  return 0;
}
