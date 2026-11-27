// The bounds of the portable inline-SVG filter engine: a primitive's subregion may sit wholly or
// partly outside the filter region, and every result must stay inside the heap buffer. Built with
// the address and undefined-behaviour sanitizers by tests/svg-filter-core.ts, so a write before
// or after the allocation, or an index derived from an overflowing length, fails the run.

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "svg-filter.h"

#define W 8
#define H 8
#define N (W * H * 4)

static int failed = 0;

static void check(const char *name, int ok, const char *detail) {
  if (!ok) failed++;
  printf("%s %s%s\n", ok ? "ok  " : "FAIL", name, ok || detail[0] == '\0' ? "" : " — ");
  if (!ok && detail[0] != '\0') printf("      %s\n", detail);
}

/** An opaque red buffer, so a kept pixel and a cleared one are told apart by its alpha. */
static void fill(uint8_t *px) {
  for (int i = 0; i < W * H; i++) {
    px[i * 4 + 0] = 255;
    px[i * 4 + 1] = 0;
    px[i * 4 + 2] = 0;
    px[i * 4 + 3] = 255;
  }
}

static int all_zero(const uint8_t *px) {
  for (int i = 0; i < N; i++) if (px[i] != 0) return 0;
  return 1;
}

static unsigned alpha_at(const uint8_t *px, int x, int y) {
  return px[((size_t)y * W + (size_t)x) * 4 + 3];
}

static void run(const char *name, const char *def, int want) {
  uint8_t px[N];
  fill(px);
  svg_filter_apply(px, W, H, def, strlen(def), 0);
  char detail[64] = "";
  int ok = 1;
  if (want == 2) ok = 1; // only the sanitizers judge this one
  else if (want == 0 && !all_zero(px)) {
    ok = 0;
    snprintf(detail, sizeof(detail), "expected an empty result");
  } else if (want == 1 && all_zero(px)) {
    ok = 0;
    snprintf(detail, sizeof(detail), "expected pixels to survive");
  }
  check(name, ok, detail);
}

int main(void) {
  // A primitive wholly outside the region on each side paints nothing, and touches nothing.
  run("a subregion left of the region paints nothing", "t,-1,-100,0,4,8", 0);
  run("a subregion right of the region paints nothing", "t,-1,100,0,4,8", 0);
  run("a subregion above the region paints nothing", "t,-1,0,-100,8,4", 0);
  run("a subregion below the region paints nothing", "t,-1,0,100,8,4", 0);

  // A far edge that overflows the double range, and non-finite operands, are empty too.
  run("a subregion whose far edge overflows paints nothing", "t,-1,1e300,1e300,1e300,1e300", 0);
  run("a subregion with non-finite operands paints nothing", "t,-1,inf,inf,inf,inf", 0);
  run("a NaN operand parses as zero", "t,-1,nan,0,4,4", 1);

  // Partly outside: only the intersection with the buffer is kept.
  {
    uint8_t px[N];
    fill(px);
    const char *def = "t,-1,-4,0,8,8";
    svg_filter_apply(px, W, H, def, strlen(def), 0);
    check("a subregion straddling the left edge keeps its inside part",
      alpha_at(px, 0, 0) == 255 && alpha_at(px, 3, 0) == 255 && alpha_at(px, 4, 0) == 0,
      "the left four columns survive, the rest is cleared");
    fill(px);
    def = "t,-1,4,4,8,8";
    svg_filter_apply(px, W, H, def, strlen(def), 0);
    check("a subregion straddling the far edges keeps its inside part",
      alpha_at(px, 4, 4) == 255 && alpha_at(px, 7, 7) == 255 && alpha_at(px, 2, 2) == 0,
      "the lower right four by four survives, the rest is cleared");
  }

  // Lengths and numbers that could drive an index are finite after parsing.
  run("a huge blur deviation stays in bounds", "b,1e300,1e300,-1,0,0,8,8", 2);
  run("an offset past the buffer rounds within range", "o,1e300,1e300,-1,0,0,8,8", 0);
  run("an offset of non-finite values becomes zero", "o,inf,inf,-1,0,0,8,8", 1);
  run("a negative overflow offset draws nothing", "o,-1e300,-1e300,-1,0,0,8,8", 0);
  run("a colour matrix of huge values clamps",
    "m,-1,1e308,1e308,1e308,1e308,1e308,1e308,1e308,1e308,1e308,1e308,1e308,1e308,1e308,1e308,"
    "1e308,1e308,1e308,1e308,1e308,1e308,0,0,8,8", 1);
  run("an arithmetic composite of huge factors clamps",
    "f,255,0,0,255,0,0,8,8;c,5,1e308,1e308,1e308,1e308,0,0,0,0,8,8", 1);
  run("a subregion of huge size with a finite start paints",
    "t,-1,0,0,1e308,1e308", 1);

  if (failed > 0) {
    printf("\n%d check%s failed\n", failed, failed == 1 ? "" : "s");
    return 1;
  }
  printf("\nall svg filter bounds checks passed\n");
  return 0;
}
