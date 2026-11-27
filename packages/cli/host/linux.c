// native Linux host: a headless host for `native wpt`. Pages lay out and paint into an offscreen
// surface, so a batch of WPT pages renders on a machine with no display. Text is shaped by
// HarfBuzz from the fonts fontconfig resolves and drawn through FreeType, and the display list
// and canvas are rasterized by Cairo, the same libraries Chrome draws through on Linux.
//
// There is no window and no event pump of its own: the window calls are stubs, and the only events
// the runtime sees are the ones assistive technology asks for on the accessibility bus (see the
// accessibility section below), delivered through host_poll. WebGL draws through an EGL context
// that needs no window of its own (see the WebGL section below).

#include <ctype.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <math.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include "svg-filter.h"
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define GL_GLEXT_PROTOTYPES 1
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/gl.h>
#include <GL/glext.h>

#include <cairo.h>
#include <fontconfig/fontconfig.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_BBOX_H
#include FT_OUTLINE_H
#include FT_TRUETYPE_TABLES_H
#include <hb.h>
#include <hb-ft.h>
#include <hb-ot.h>
#include <jpeglib.h>
#include <png.h>
#include <gif_lib.h>
#include <dbus/dbus.h>

#ifndef NATIVE_NO_FFMPEG
#include <dlfcn.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
#include <libavutil/imgutils.h>

// The FFmpeg libraries are loaded when the first video opens, not linked: an explicit
// NATIVE_FFMPEG_LIB directory, then a lib/ directory beside the executable (what a bundle ships),
// then the loader's own search path (a system FFmpeg).

typedef struct {
  __typeof__(avformat_open_input) *open_input;
  __typeof__(av_seek_frame) *seek_frame;
  __typeof__(avformat_find_stream_info) *find_stream_info;
  __typeof__(avformat_close_input) *close_input;
  __typeof__(av_find_best_stream) *find_best_stream;
  __typeof__(avcodec_find_decoder) *find_decoder;
  __typeof__(avcodec_find_decoder_by_name) *find_decoder_by_name;
  __typeof__(avcodec_version) *version;
  __typeof__(avcodec_alloc_context3) *alloc_context3;
  __typeof__(avcodec_parameters_to_context) *parameters_to_context;
  __typeof__(avcodec_open2) *open2;
  __typeof__(avcodec_free_context) *free_context;
  __typeof__(avcodec_send_packet) *send_packet;
  __typeof__(avcodec_receive_frame) *receive_frame;
  __typeof__(avcodec_flush_buffers) *flush_buffers;
  __typeof__(av_read_frame) *read_frame;
  __typeof__(av_packet_alloc) *packet_alloc;
  __typeof__(av_packet_unref) *packet_unref;
  __typeof__(av_packet_free) *packet_free;
  __typeof__(av_frame_alloc) *frame_alloc;
  __typeof__(av_frame_unref) *frame_unref;
  __typeof__(av_frame_free) *frame_free;
  __typeof__(sws_getContext) *sws_get;
  __typeof__(sws_scale) *sws_scale_now;
  __typeof__(sws_freeContext) *sws_free;
} FfmpegApi;

static FfmpegApi ff;
static int ff_state = 0;

/** The directory the executable sits in, for the lib/ directory a bundle ships beside it. */
static void exe_directory(char *out, size_t cap) {
  out[0] = '\0';
  if (cap < 2) return;
  char name[4096];
  ssize_t n = readlink("/proc/self/exe", name, sizeof(name) - 1);
  if (n <= 0) return;
  name[n] = '\0';
  char *slash = strrchr(name, '/');
  if (slash == NULL) return;
  *slash = '\0';
  snprintf(out, cap, "%s", name);
}

/** One FFmpeg library: an explicit NATIVE_FFMPEG_LIB directory first, then a bundle's lib/ beside
 *  the executable, then the loader's own search path. */
static void *ff_dl(const char *name) {
  char path[4096];
  const char *override = getenv("NATIVE_FFMPEG_LIB");
  if (override != NULL && override[0] != '\0') {
    snprintf(path, sizeof(path), "%s/%s", override, name);
    void *handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (handle != NULL) return handle;
  }
  char dir[4096];
  exe_directory(dir, sizeof(dir));
  if (dir[0] != '\0') {
    snprintf(path, sizeof(path), "%s/lib/%s", dir, name);
    void *handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (handle != NULL) return handle;
    snprintf(path, sizeof(path), "%s/%s", dir, name);
    handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (handle != NULL) return handle;
  }
  return dlopen(name, RTLD_NOW | RTLD_GLOBAL);
}

#define FF_SYM(handle, field, symbol) do {   *(void **)(&ff.field) = dlsym(handle, symbol);   if (ff.field == NULL) return 0; } while (0)

static int ff_load(void) {
  if (ff_state != 0) return ff_state > 0;
  ff_state = -1;
  void *util = ff_dl("libavutil.so.60");
  if (util == NULL) util = ff_dl("libavutil.so");
  void *scale = ff_dl("libswscale.so.9");
  if (scale == NULL) scale = ff_dl("libswscale.so");
  void *codec = ff_dl("libavcodec.so.62");
  if (codec == NULL) codec = ff_dl("libavcodec.so");
  void *format = ff_dl("libavformat.so.62");
  if (format == NULL) format = ff_dl("libavformat.so");
  if (util == NULL || scale == NULL || codec == NULL || format == NULL) return 0;
  FF_SYM(format, open_input, "avformat_open_input");
  FF_SYM(format, seek_frame, "av_seek_frame");
  FF_SYM(format, find_stream_info, "avformat_find_stream_info");
  FF_SYM(format, close_input, "avformat_close_input");
  FF_SYM(format, find_best_stream, "av_find_best_stream");
  FF_SYM(format, read_frame, "av_read_frame");
  FF_SYM(codec, find_decoder, "avcodec_find_decoder");
  FF_SYM(codec, find_decoder_by_name, "avcodec_find_decoder_by_name");
  FF_SYM(codec, version, "avcodec_version");
  // The headers this host was built against and the library that was loaded must agree on the
  // major ABI version, or the callbacks and structs are a different shape.
  if ((ff.version() >> 16) != LIBAVCODEC_VERSION_MAJOR) return 0;
  FF_SYM(codec, alloc_context3, "avcodec_alloc_context3");
  FF_SYM(codec, parameters_to_context, "avcodec_parameters_to_context");
  FF_SYM(codec, open2, "avcodec_open2");
  FF_SYM(codec, free_context, "avcodec_free_context");
  FF_SYM(codec, send_packet, "avcodec_send_packet");
  FF_SYM(codec, receive_frame, "avcodec_receive_frame");
  FF_SYM(codec, flush_buffers, "avcodec_flush_buffers");
  FF_SYM(codec, packet_alloc, "av_packet_alloc");
  FF_SYM(codec, packet_unref, "av_packet_unref");
  FF_SYM(codec, packet_free, "av_packet_free");
  FF_SYM(codec, frame_alloc, "av_frame_alloc");
  FF_SYM(codec, frame_unref, "av_frame_unref");
  FF_SYM(codec, frame_free, "av_frame_free");
  FF_SYM(scale, sws_get, "sws_getContext");
  FF_SYM(scale, sws_scale_now, "sws_scale");
  FF_SYM(scale, sws_free, "sws_freeContext");
  ff_state = 1;
  return 1;
}
#endif

#include <sqlite3.h>

// The compositor core is part of this translation unit, like the macOS host's.
#include "compositor/compositor.c"
#include "compositor/layers.c"
#include "compositor/tiles.c"
#include "compositor/chunks.c"

/** A string the runtime reads back inside a call: its bytes, which aren't NUL-terminated. */
typedef void (*str_cb)(const uint8_t *, size_t);

// ---------------------------------------------------------------------------
// Frame timings

/** Whether NATIVE_FRAME_TIMES asks for per-frame stage times, read once. */
static int frame_times(void) {
  static int on = -1;
  if (on < 0) {
    const char *env = getenv("NATIVE_FRAME_TIMES");
    on = env != NULL && env[0] != 0 && strcmp(env, "0") != 0;
  }
  return on;
}

/** The monotonic clock in milliseconds, for the stage timings. */
static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

// ---------------------------------------------------------------------------
// Fonts

// A font file's metrics, read from its tables. `weight` also carries the family id and the
// italic flag (see fontKey in runtime/style.ts): family * 10000, plus 1000 for italic, plus the
// CSS weight. A face covers the weight range its @font-face rule gave, and one style.
typedef struct {
  int loaded;
  uint8_t *data;
  size_t len;
  uint32_t upem;
  double ascent, descent, line_gap, x_height; // font units
  uint16_t num_glyphs, num_hmetrics;
  uint32_t hmtx_off, hmtx_len;
  uint32_t cmap_off, cmap_len;
  int family;          // the family id minus FF_CUSTOM (3)
  double weight_lo, weight_hi;
  int italic;
  char *path;          // the file, for FreeType to draw from
  FT_Face ft;          // opened lazily
  int ft_failed;
} Face;

// A family id at FF_CUSTOM and above is one the page's own tables declare (see props.ts); its
// face index is the id minus FF_CUSTOM.
#define FF_CUSTOM 7

#define MAX_FACES 4096
static Face g_faces[MAX_FACES];
static int g_face_count = 0;

// FreeType is opened once; a build without any text still never touches it.
static FT_Library g_ft;
static int g_ft_ready = 0;
static int g_ft_tried = 0;

static FT_Library ft_library(void) {
  if (!g_ft_tried) {
    g_ft_tried = 1;
    g_ft_ready = FT_Init_FreeType(&g_ft) == 0;
  }
  return g_ft_ready ? g_ft : NULL;
}

static uint16_t be16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static int16_t be16s(const uint8_t *p) { return (int16_t)((p[0] << 8) | p[1]); }
static uint32_t be32(const uint8_t *p) {
  return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}
static char *dup_str(const char *s) {
  size_t n = strlen(s) + 1;
  char *p = (char *)malloc(n);
  if (p) memcpy(p, s, n);
  return p;
}
static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t le32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint8_t *read_file(const uint8_t *path, size_t n, size_t *out_len) {
  char name[4096];
  if (n >= sizeof(name)) return NULL;
  memcpy(name, path, n);
  name[n] = '\0';
  FILE *f = fopen(name, "rb");
  if (!f) return NULL;
  if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
  long size = ftell(f);
  if (size <= 0) { fclose(f); return NULL; }
  rewind(f);
  uint8_t *buf = (uint8_t *)malloc((size_t)size);
  if (!buf) { fclose(f); return NULL; }
  if (fread(buf, 1, (size_t)size, f) != (size_t)size) { free(buf); fclose(f); return NULL; }
  fclose(f);
  *out_len = (size_t)size;
  return buf;
}

/** The table with this tag, or NULL. */
static const uint8_t *find_table(const Face *f, const char tag[4], uint32_t *out_len) {
  if (f->len < 12) return NULL;
  uint16_t count = be16(f->data + 4);
  for (uint16_t i = 0; i < count; i++) {
    const uint8_t *rec = f->data + 12 + (size_t)i * 16;
    if (rec + 16 > f->data + f->len) return NULL;
    if (memcmp(rec, tag, 4) != 0) continue;
    uint32_t off = be32(rec + 8), len = be32(rec + 12);
    if (off > f->len || len > f->len - off) return NULL;
    if (out_len) *out_len = len;
    return f->data + off;
  }
  return NULL;
}

/** Reads a face's metric tables through FreeType. A WOFF or WOFF2 file keeps its tables in a
 *  compressed container this walk can't see into, and FreeType hands the same tables back from
 *  it, so a face the page names from one is measured and drawn like a plain font file's. */
static void load_face_via_ft(Face *f) {
  FT_Library lib = ft_library();
  if (lib == NULL) return;
  FT_Face ft = NULL;
  if (FT_New_Memory_Face(lib, f->data, (FT_Long)f->len, 0, &ft) != 0) return;
  uint8_t head[54], hhea[36], maxp[6], os2[96];
  FT_ULong head_len = sizeof(head), hhea_len = sizeof(hhea), maxp_len = sizeof(maxp);
  FT_ULong os2_len = sizeof(os2);
  int ok = FT_Load_Sfnt_Table(ft, FT_MAKE_TAG('h', 'e', 'a', 'd'), 0, head, &head_len) == 0 &&
    FT_Load_Sfnt_Table(ft, FT_MAKE_TAG('h', 'h', 'e', 'a'), 0, hhea, &hhea_len) == 0 &&
    FT_Load_Sfnt_Table(ft, FT_MAKE_TAG('m', 'a', 'x', 'p'), 0, maxp, &maxp_len) == 0 &&
    head_len >= 20 && hhea_len >= 36 && maxp_len >= 6;
  if (ok) {
    f->upem = be16(head + 18);
    f->ascent = be16s(hhea + 4);
    f->descent = be16s(hhea + 6);
    f->line_gap = be16s(hhea + 8);
    f->num_hmetrics = be16(hhea + 34);
    f->num_glyphs = be16(maxp + 4);
    f->x_height = FT_Load_Sfnt_Table(ft, FT_MAKE_TAG('O', 'S', '/', '2'), 0, os2, &os2_len) == 0 &&
      os2_len >= 88 && be16(os2) >= 2 ? be16s(os2 + 86) : f->ascent * 0.55;
    if (f->upem != 0 && f->num_hmetrics != 0) f->loaded = 1;
  }
  FT_Done_Face(ft);
}

static void load_face(Face *f, const uint8_t *path, size_t n) {
  memset(f, 0, sizeof(*f));
  f->data = read_file(path, n, &f->len);
  if (!f->data || f->len < 12) return;
  uint32_t head_len = 0, hhea_len = 0, maxp_len = 0;
  const uint8_t *head = find_table(f, "head", &head_len);
  const uint8_t *hhea = find_table(f, "hhea", &hhea_len);
  const uint8_t *maxp = find_table(f, "maxp", &maxp_len);
  const uint8_t *hmtx = find_table(f, "hmtx", &f->hmtx_len);
  if (!head || !hhea || !maxp || !hmtx || head_len < 20 || hhea_len < 36 || maxp_len < 6) {
    load_face_via_ft(f);
    return;
  }
  f->upem = be16(head + 18);
  // These three are signed: a font's descender is negative.
  f->ascent = be16s(hhea + 4);
  f->descent = be16s(hhea + 6);
  f->line_gap = be16s(hhea + 8);
  f->num_hmetrics = be16(hhea + 34);
  f->num_glyphs = be16(maxp + 4);
  f->hmtx_off = (uint32_t)(hmtx - f->data);
  // OS/2 version 2 and later carry the font's x-height.
  uint32_t os2_len = 0;
  const uint8_t *os2 = find_table(f, "OS/2", &os2_len);
  f->x_height = os2 && os2_len >= 88 && be16(os2) >= 2 ? be16s(os2 + 86) : f->ascent * 0.55;
  if (!f->upem || !f->num_hmetrics) return;
  const uint8_t *cmap = find_table(f, "cmap", &f->cmap_len);
  if (cmap) f->cmap_off = (uint32_t)(cmap - f->data);
  f->loaded = 1;
}

// ---------------------------------------------------------------------------
// Built-in metrics for the three families the host provides without a font file (the system
// font, monospace and serif), in units of 1/1000 em. The system font's vertical metrics are
// the ones CoreText reports for San Francisco, whose 0.21125 em descent a line box's bottom
// edge depends on; its advances are Helvetica's, the closest widely known stand-in for them.

static const uint16_t SYSTEM_REGULAR[95] = {
  278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278,
  556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
  1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
  667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
  333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
  556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584,
};

static const uint16_t SYSTEM_BOLD[95] = {
  278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278,
  556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611,
  975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778,
  667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556,
  333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611,
  611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584,
};

static const uint16_t SERIF_REGULAR[95] = {
  250, 333, 408, 500, 500, 833, 778, 180, 333, 333, 500, 564, 250, 333, 250, 278,
  500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 278, 278, 564, 564, 564, 444,
  921, 722, 667, 667, 722, 611, 556, 722, 722, 333, 389, 722, 611, 889, 722, 722,
  556, 722, 667, 556, 611, 722, 722, 944, 722, 722, 611, 333, 278, 333, 469, 500,
  333, 444, 500, 444, 500, 444, 333, 500, 500, 278, 278, 500, 278, 778, 500, 500,
  500, 500, 333, 389, 278, 500, 500, 722, 500, 500, 444, 480, 200, 480, 541,
};

typedef struct {
  const uint16_t *widths;
  double ascent, descent, line_gap, x_height; // em
} Model;

// A packed font key (fontKey in runtime/style.ts) carries the feature run in its millions, the
// family in its ten-thousands, 1000 for italic and the CSS weight below that.
static void split_weight(double weight, int *family, double *w, int *italic) {
  double pack = weight - floor(weight / 10000000.0) * 10000000.0;
  double fam = floor(pack / 10000.0);
  double rest = pack - fam * 10000.0;
  *italic = rest >= 1000 ? 1 : 0;
  *w = *italic ? rest - 1000 : rest;
  *family = (int)fam;
}

static Model model_for(double weight) {
  int family = 0;
  double w = 400;
  int italic = 0;
  split_weight(weight, &family, &w, &italic);
  if (family == 1 || family == 5) return (Model){NULL, 0.955, 0.243, 0.0, 0.53};
  if (family == 2 || family == 3) return (Model){SERIF_REGULAR, 0.891, 0.216, 0.042, 0.448};
  return (Model){w >= 600 ? SYSTEM_BOLD : SYSTEM_REGULAR, 0.952, 0.21125, 0.0, 0.518};
}

// The face a family gives a weight and style, as CSS's font matching picks it: a face of the
// style the text asks for comes before any other, and among those the nearest weight range.
static Face *face_for_family(int family_id, double w, int italic) {
  int family = family_id - FF_CUSTOM; // a face's index in the page's own tables
  Face *best = NULL;
  double best_dist = 0;
  for (int i = 0; i < g_face_count; i++) {
    Face *f = &g_faces[i];
    if (f->family != family) continue;
    double dist = (f->italic == italic ? 0 : 100000) +
      (w < f->weight_lo ? f->weight_lo - w : w > f->weight_hi ? w - f->weight_hi : 0);
    if (best == NULL || dist < best_dist) { best = f; best_dist = dist; }
  }
  return best;
}

static Face *face_for(double weight) {
  int family_id = 0;
  double w = 400;
  int italic = 0;
  split_weight(weight, &family_id, &w, &italic);
  return face_for_family(family_id, w, italic);
}

// ---------------------------------------------------------------------------
// Feature runs
//
// A packed font key carries the feature run in its millions (fontKey in runtime/style.ts). A run
// is the text's OpenType features and variation axes: the host shapes every run with them, so the
// drawing and the measuring of text both see the font the page asked for.

typedef struct {
  hb_feature_t *features;
  unsigned feature_count;
  hb_variation_t *variations;
  unsigned variation_count;
  int kerning;        // -1 auto, 0 none, 1 normal
  double stretch;     // font-stretch percent, 100 when the run says nothing
  int *cascade;       // family ids after the first of a font-family list, in order
  unsigned cascade_count;
} FeatureRun;

#define MAX_FEATURE_RUNS 4096
static FeatureRun *g_feature_runs = NULL;
static int g_feature_run_count = 0;
static int g_feature_run_cap = 0;

/** The run a packed weight names, or NULL for the font's own defaults. */
static FeatureRun *run_for_weight(double weight) {
  double id = floor(weight / 10000000.0);
  if (id <= 0 || id > g_feature_run_count) return NULL;
  return &g_feature_runs[(int)id - 1];
}

static FeatureRun *new_feature_run(void) {
  if (g_feature_run_count >= MAX_FEATURE_RUNS) return NULL;
  if (g_feature_run_count >= g_feature_run_cap) {
    int cap = g_feature_run_cap ? g_feature_run_cap * 2 : 32;
    FeatureRun *grown = (FeatureRun *)realloc(g_feature_runs, (size_t)cap * sizeof(*grown));
    if (!grown) return NULL;
    g_feature_runs = grown;
    g_feature_run_cap = cap;
  }
  FeatureRun *run = &g_feature_runs[g_feature_run_count++];
  memset(run, 0, sizeof(*run));
  run->kerning = -1;
  run->stretch = 100;
  return run;
}

static void add_feature(FeatureRun *run, const char *text) {
  hb_feature_t feature;
  if (!hb_feature_from_string(text, -1, &feature)) return;
  hb_feature_t *grown = (hb_feature_t *)realloc(run->features,
    ((size_t)run->feature_count + 1) * sizeof(*grown));
  if (!grown) return;
  run->features = grown;
  run->features[run->feature_count++] = feature;
}

static void add_variation(FeatureRun *run, const char *text) {
  hb_variation_t variation;
  if (!hb_variation_from_string(text, -1, &variation)) return;
  hb_variation_t *grown = (hb_variation_t *)realloc(run->variations,
    ((size_t)run->variation_count + 1) * sizeof(*grown));
  if (!grown) return;
  run->variations = grown;
  run->variations[run->variation_count++] = variation;
}

/** Registers the feature run a packed font key names: `f:` OpenType features, `v:` variation
 *  axes, `k:` font-kerning and `t:` font-stretch, each section separated by a bar. */
double host_register_features(const uint8_t *spec, size_t spec_len) {
  FeatureRun *run = new_feature_run();
  if (!run) return 0;
  char *text = (char *)malloc(spec_len + 1);
  if (!text) return 0;
  memcpy(text, spec, spec_len);
  text[spec_len] = '\0';
  char *save = NULL;
  for (char *section = strtok_r(text, "|", &save); section != NULL;
       section = strtok_r(NULL, "|", &save)) {
    if (section[0] == '\0' || section[1] != ':') continue;
    char kind = section[0];
    const char *body = section + 2;
    if (kind == 'k') { run->kerning = atoi(body); continue; }
    if (kind == 't') { run->stretch = atof(body); continue; }
    if (kind == 'c') {
      // The families a font-family list names after the first, `family` or `family=palette`;
      // each falls to the next for a character the one before has no glyph for, and the first
      // that has a face draws the run when the first family has none.
      char *entry_save = NULL;
      for (char *entry = strtok_r((char *)body, ";", &entry_save); entry != NULL;
           entry = strtok_r(NULL, ";", &entry_save)) {
        int fam = atoi(entry);
        if (fam < 0) continue;
        int *grown = (int *)realloc(run->cascade, ((size_t)run->cascade_count + 1) * sizeof(int));
        if (!grown) break;
        run->cascade = grown;
        run->cascade[run->cascade_count++] = fam;
      }
      continue;
    }
    if (kind != 'f' && kind != 'v') continue;
    char *pair_save = NULL;
    for (char *pair = strtok_r((char *)body, ";", &pair_save); pair != NULL;
         pair = strtok_r(NULL, ";", &pair_save)) {
      if (strchr(pair, '=') == NULL) continue;
      if (kind == 'f') add_feature(run, pair);
      else add_variation(run, pair);
    }
  }
  free(text);
  // font-kerning yields to a kern or vkrn the page names in font-feature-settings, as CSS's
  // cascade orders the two properties.
  int named_kern = 0, named_vkrn = 0;
  for (unsigned i = 0; i < run->feature_count; i++) {
    if (run->features[i].tag == HB_TAG('k', 'e', 'r', 'n')) named_kern = 1;
    if (run->features[i].tag == HB_TAG('v', 'k', 'r', 'n')) named_vkrn = 1;
  }
  if (run->kerning == 0) {
    if (!named_kern) add_feature(run, "kern=0");
    if (!named_vkrn) add_feature(run, "vkrn=0");
  } else if (run->kerning == 1) {
    if (!named_kern) add_feature(run, "kern=1");
    if (!named_vkrn) add_feature(run, "vkrn=1");
  }
  return (double)g_feature_run_count;
}

// ---------------------------------------------------------------------------
// HarfBuzz fonts
//
// Shaping goes through HarfBuzz, as Chrome's does. One hb_font per FreeType face is kept for the
// life of the document; the variation axes a run asks for are set on it before each shape.

typedef struct {
  FT_Face ft;
  hb_face_t *face;
  hb_font_t *font;
} HbFace;

#define MAX_HB_FACES 256
static HbFace g_hb_faces[MAX_HB_FACES];
static int g_hb_face_count = 0;

static hb_font_t *hb_font_for(FT_Face ft) {
  if (!ft) return NULL;
  for (int i = 0; i < g_hb_face_count; i++) {
    if (g_hb_faces[i].ft == ft) return g_hb_faces[i].font;
  }
  if (g_hb_face_count >= MAX_HB_FACES) return NULL;
  hb_face_t *face = hb_ft_face_create_referenced(ft);
  if (!face) return NULL;
  hb_font_t *font = hb_font_create(face);
  if (!font) { hb_face_destroy(face); return NULL; }
  unsigned upem = hb_face_get_upem(face);
  if (upem) hb_font_set_scale(font, upem, upem);
  g_hb_faces[g_hb_face_count].ft = ft;
  g_hb_faces[g_hb_face_count].face = face;
  g_hb_faces[g_hb_face_count].font = font;
  g_hb_face_count++;
  return font;
}

static void hb_release_fonts(void) {
  for (int i = 0; i < g_hb_face_count; i++) {
    if (g_hb_faces[i].font) hb_font_destroy(g_hb_faces[i].font);
    if (g_hb_faces[i].face) hb_face_destroy(g_hb_faces[i].face);
  }
  g_hb_face_count = 0;
}

// ---------------------------------------------------------------------------
// System fonts
//
// A family the page didn't bring a file for is matched by fontconfig, which is how Chrome finds
// the system's sans, serif and monospace faces on Linux. The match is cached: a page draws its
// text with a handful of faces at most.

#define MAX_MATCHES 32
typedef struct {
  int family;
  int bold;
  int italic;
  int used;
  Face face;
} FontMatch;

static FontMatch g_matches[MAX_MATCHES];
static int g_match_count = 0;

static int css_weight_class(double w) {
  if (w < 150) return FC_WEIGHT_THIN;
  if (w < 250) return FC_WEIGHT_EXTRALIGHT;
  if (w < 350) return FC_WEIGHT_LIGHT;
  if (w < 450) return FC_WEIGHT_REGULAR;
  if (w < 550) return FC_WEIGHT_MEDIUM;
  if (w < 650) return FC_WEIGHT_DEMIBOLD;
  if (w < 750) return FC_WEIGHT_BOLD;
  if (w < 850) return FC_WEIGHT_EXTRABOLD;
  return FC_WEIGHT_BLACK;
}

/** The fontconfig family a CSS family id falls back to. */
static const char *css_family_name(int family) {
  if (family == 1 || family == 5) return "monospace";
  // Chrome's desktop default fonts, which fontconfig maps to the metric-compatible Liberation
  // faces: Arial for the sans, Times New Roman for the serif (the standard font). Its generic
  // keywords resolve to those, not to fontconfig's own defaults, so text measures and draws the
  // size Chrome draws.
  if (family == 2 || family == 3) return "Times New Roman";
  // A named family the machine has no face for falls back to the standard font, which is serif;
  // only the sans-serif keywords ask for the system sans.
  if (family >= 7) return "Times New Roman";
  return "Arial";
}

/** The face fontconfig matches for a family id, weight and style. Its metrics are read from the
 *  file the way a page's own faces are, so measuring and drawing use the same font the way Chrome
 *  does, rather than a built-in stand-in's advances. */
static Face *system_face(int family, double weight, int italic) {
  int bold = weight >= 600 ? 1 : 0;
  for (int i = 0; i < g_match_count; i++) {
    if (g_matches[i].family == family && g_matches[i].bold == bold && g_matches[i].italic == italic) {
      return g_matches[i].used ? &g_matches[i].face : NULL;
    }
  }
  if (g_match_count >= MAX_MATCHES) return NULL;
  FcPattern *pat = FcPatternCreate();
  FcPatternAddString(pat, FC_FAMILY, (const FcChar8 *)css_family_name(family));
  FcPatternAddInteger(pat, FC_WEIGHT, css_weight_class(weight));
  FcPatternAddInteger(pat, FC_SLANT, italic ? FC_SLANT_ITALIC : FC_SLANT_ROMAN);
  FcConfigSubstitute(NULL, pat, FcMatchPattern);
  FcDefaultSubstitute(pat);
  FcResult result;
  FcPattern *match = FcFontMatch(NULL, pat, &result);
  FcPatternDestroy(pat);
  FontMatch *m = &g_matches[g_match_count++];
  m->family = family;
  m->bold = bold;
  m->italic = italic;
  if (match) {
    FcChar8 *file = NULL;
    if (FcPatternGetString(match, FC_FILE, 0, &file) == FcResultMatch) {
      load_face(&m->face, file, strlen((const char *)file));
      if (m->face.loaded) {
        m->face.family = -1;
        m->face.weight_lo = 0;
        m->face.weight_hi = 1000;
        m->face.italic = italic;
        m->face.path = dup_str((const char *)file);
        m->used = 1;
      }
    }
    FcPatternDestroy(match);
  }
  return m->used ? &m->face : NULL;
}

/** The face text at this weight is measured and drawn with: a page's own face when the family
 *  has one, else the system face fontconfig matches, else NULL for the built-in metrics. */
static Face *resolve_face(double weight) {
  Face *f = face_for(weight);
  if (f != NULL && f->loaded) return f;
  int family = 0;
  double w = 400;
  int italic = 0;
  split_weight(weight, &family, &w, &italic);
  // A family with no face of its own falls to the next one the list names, in order, and only
  // the end of the list falls to the standard font.
  FeatureRun *run = run_for_weight(weight);
  if (run != NULL) {
    for (unsigned i = 0; i < run->cascade_count; i++) {
      int id = run->cascade[i];
      Face *next = id < FF_CUSTOM ? system_face(id, w, italic) : face_for_family(id, w, italic);
      if (next != NULL && next->loaded) return next;
    }
  }
  return system_face(family, w, italic);
}

static FT_Face face_ft(Face *f) {
  if (!f || !f->path) return NULL;
  if (!f->ft && !f->ft_failed) {
    FT_Library lib = ft_library();
    if (!lib || FT_New_Face(lib, f->path, 0, &f->ft) != 0) f->ft_failed = 1;
  }
  return f->ft_failed ? NULL : f->ft;
}

/** The FreeType face text at this weight is drawn with, or NULL when no font can be found. */
static FT_Face paint_face(double weight) { return face_ft(resolve_face(weight)); }

// ---------------------------------------------------------------------------
// Text

static int utf8_next(const uint8_t *s, size_t n, size_t *i, uint32_t *cp) {
  if (*i >= n) return 0;
  uint8_t b = s[(*i)++];
  if (b < 0x80) { *cp = b; return 1; }
  int extra = (b & 0xe0) == 0xc0 ? 1 : (b & 0xf0) == 0xe0 ? 2 : (b & 0xf8) == 0xf0 ? 3 : 0;
  if (extra == 0 || *i + (size_t)extra > n) { *cp = 0xfffd; return 1; }
  uint32_t v = b & (0x3f >> extra);
  for (int k = 0; k < extra; k++) v = (v << 6) | (s[(*i)++] & 0x3f);
  *cp = v;
  return 1;
}

/** The advance of one code point from the built-in families' tables: the last resort when no
 *  font file is available at all. */
static double model_advance(double weight, uint32_t cp, double size) {
  Model m = model_for(weight);
  if (cp >= 32 && cp <= 126) return (m.widths ? m.widths[cp - 32] / 1000.0 : 0.6) * size;
  return (m.widths ? 0.5 : 0.6) * size;
}

/** Whether a UTF-8 cluster at `p` is a space, the character word-spacing follows. */
static int cluster_is_space(const uint8_t *p, size_t n, unsigned at) {
  size_t i = at;
  uint32_t cp = 0;
  if (i >= n || !utf8_next(p, n, &i, &cp)) return 0;
  return cp == ' ';
}

static double ft_upem(FT_Face ft);
static FT_Face fallback_face(uint32_t cp);
static int face_is_italic(FT_Face ft, double weight);

/** The face that has a character: the run's own, the next family of its list that has it, or
 *  fontconfig's fallback for it. */
static FT_Face face_for_char(FT_Face primary, uint32_t cp, FeatureRun *run, double weight) {
  if (!primary || FT_Get_Char_Index(primary, cp) != 0) return primary;
  if (run != NULL) {
    int family_id = 0;
    double w = 400;
    int italic = 0;
    split_weight(weight, &family_id, &w, &italic);
    for (unsigned i = 0; i < run->cascade_count; i++) {
      int id = run->cascade[i];
      Face *next = id < FF_CUSTOM ? system_face(id, w, italic) : face_for_family(id, w, italic);
      if (next == NULL || !next->loaded) continue;
      FT_Face ft = face_ft(next);
      if (ft != NULL && FT_Get_Char_Index(ft, cp) != 0) return ft;
    }
  }
  FT_Face other = fallback_face(cp);
  return other ? other : primary;
}

/** Whether the run's variation axes already name an axis. */
static int has_variation(const hb_variation_t *vars, unsigned n, hb_tag_t tag) {
  for (unsigned i = 0; i < n; i++) if (vars[i].tag == tag) return 1;
  return 0;
}

/**
 * Sets the variation axes the run asks for on a font. A variable font's weight follows
 * font-weight, its optical size follows font-size (Chrome's font-optical-sizing: auto), and a
 * non-100% font-stretch follows the width axis. The run's own font-variation-settings override
 * each of these.
 */
static void shape_variations(hb_font_t *font, double size, double weight, FeatureRun *run) {
  hb_face_t *hface = hb_font_get_face(font);
  if (hb_ot_var_get_axis_count(hface) == 0) {
    hb_font_set_variations(font, NULL, 0);
    return;
  }
  hb_variation_t vars[16];
  unsigned n = 0;
  if (run) {
    for (unsigned i = 0; i < run->variation_count && n < 16; i++) vars[n++] = run->variations[i];
  }
  int family = 0, italic = 0;
  double w = 400;
  split_weight(weight, &family, &w, &italic);
  if (!has_variation(vars, n, HB_TAG('w', 'g', 'h', 't')) && n < 16) {
    vars[n].tag = HB_TAG('w', 'g', 'h', 't');
    vars[n++].value = (float)w;
  }
  if (!has_variation(vars, n, HB_TAG('o', 'p', 's', 'z')) && n < 16) {
    vars[n].tag = HB_TAG('o', 'p', 's', 'z');
    vars[n++].value = (float)size;
  }
  if (run && run->stretch != 100 && !has_variation(vars, n, HB_TAG('w', 'd', 't', 'h')) && n < 16) {
    vars[n].tag = HB_TAG('w', 'd', 't', 'h');
    vars[n++].value = (float)run->stretch;
  }
  hb_font_set_variations(font, vars, n);
}

typedef void (*shape_cb)(void *ctx, Face *face, FT_Face ft, unsigned glyph,
                         double x, double baseline_offset, double advance);

// A run's shaped glyphs are the same for the same text, face, size, features and spacing, and
// most runs a page paints were already shaped when the layout measured them. The shaped run is
// kept and replayed, with the pen moved to wherever this draw starts.
typedef struct {
  FT_Face ft;
  unsigned glyph;
  double x;          // from the run's origin, letter and word spacing included
  double y_offset;
  double advance;
} ShapedGlyph;

typedef struct {
  int used;
  char *text;
  uint32_t text_len;
  double size;
  double weight;
  double letter;
  double word;
  ShapedGlyph *glyphs;
  int glyph_count;
  double width;
} ShapedRun;

#define SHAPED_RUN_SLOTS 4096
static ShapedRun g_shaped_runs[SHAPED_RUN_SLOTS];
static int g_shaped_run_count = 0;

static void clear_shaped_runs(void) {
  for (int i = 0; i < SHAPED_RUN_SLOTS; i++) {
    free(g_shaped_runs[i].text);
    free(g_shaped_runs[i].glyphs);
    memset(&g_shaped_runs[i], 0, sizeof(g_shaped_runs[i]));
  }
  g_shaped_run_count = 0;
}

static uint64_t shaped_hash(const uint8_t *text, size_t n, double size, double weight,
                            double letter, double word) {
  uint64_t h = 1469598103934665603ull;
  for (size_t i = 0; i < n; i++) { h ^= text[i]; h *= 1099511628211ull; }
  uint64_t bits = 0;
  memcpy(&bits, &size, sizeof(bits)); h = h * 1099511628211ull ^ bits;
  memcpy(&bits, &weight, sizeof(bits)); h = h * 1099511628211ull ^ bits;
  memcpy(&bits, &letter, sizeof(bits)); h = h * 1099511628211ull ^ bits;
  memcpy(&bits, &word, sizeof(bits)); h = h * 1099511628211ull ^ bits;
  return h;
}

/** The cached run for these exact parameters, or NULL. */
static ShapedRun *shaped_run_find(const uint8_t *text, size_t n, double size, double weight,
                                  double letter, double word, uint64_t hash) {
  unsigned at = (unsigned)(hash & (SHAPED_RUN_SLOTS - 1));
  for (int probe = 0; probe < 32; probe++, at = (at + 1) & (SHAPED_RUN_SLOTS - 1)) {
    ShapedRun *run = &g_shaped_runs[at];
    if (!run->used) return NULL;
    if (run->text_len == n && run->size == size && run->weight == weight &&
        run->letter == letter && run->word == word && memcmp(run->text, text, n) == 0) {
      return run;
    }
  }
  return NULL;
}

/** Keeps a shaped run. The arrays are handed over; the caller keeps ownership only on failure. */
static ShapedRun *shaped_run_store(const uint8_t *text, size_t n, double size, double weight,
                                   double letter, double word, uint64_t hash,
                                   ShapedGlyph *glyphs, int glyph_count, double width,
                                   ShapedRun **out) {
  *out = NULL;
  if (g_shaped_run_count >= SHAPED_RUN_SLOTS) clear_shaped_runs();
  unsigned at = (unsigned)(hash & (SHAPED_RUN_SLOTS - 1));
  for (int probe = 0; probe < 32; probe++, at = (at + 1) & (SHAPED_RUN_SLOTS - 1)) {
    ShapedRun *run = &g_shaped_runs[at];
    if (run->used) continue;
    char *copy = (char *)malloc(n ? n : 1);
    if (!copy) return NULL;
    memcpy(copy, text, n);
    run->used = 1;
    run->text = copy;
    run->text_len = (uint32_t)n;
    run->size = size;
    run->weight = weight;
    run->letter = letter;
    run->word = word;
    run->glyphs = glyphs;
    run->glyph_count = glyph_count;
    run->width = width;
    g_shaped_run_count++;
    *out = run;
    return run;
  }
  return NULL;
}

/**
 * Shapes a run with HarfBuzz and walks its glyphs in logical order, calling `cb` for each at the
 * pen position it draws at, with the distance its baseline sits above the run's own. The kerning
 * and ligatures the font's default features ask for are on, as Chrome's are, and letter and word
 * spacing are inserted after each cluster the way CSS adds them. Returns the run's advance width
 * in pixels, or -1 when the text has no font to shape with.
 */
static double shape_text(const uint8_t *s, size_t n, double size, double weight, double letter,
                         double word, double origin, shape_cb cb, void *ctx) {
  uint64_t hash = shaped_hash(s, n, size, weight, letter, word);
  ShapedRun *cached = shaped_run_find(s, n, size, weight, letter, word, hash);
  if (cached) {
    Face *cached_face = resolve_face(weight);
    for (int g = 0; g < cached->glyph_count; g++) {
      ShapedGlyph *glyph = &cached->glyphs[g];
      if (cb) cb(ctx, cached_face, glyph->ft, glyph->glyph, origin + glyph->x, glyph->y_offset, glyph->advance);
    }
    return cached->width;
  }
  Face *face = resolve_face(weight);
  FT_Face ft0 = face_ft(face);
  if (!ft0) return -1;
  FeatureRun *run = run_for_weight(weight);
  int family = 0, italic = 0;
  double weight_value = 400;
  split_weight(weight, &family, &weight_value, &italic);
  double pen = origin;
  ShapedGlyph *shaped = NULL;
  int shaped_count = 0, shaped_cap = 0;
  size_t i = 0;
  while (i < n) {
    size_t start = i;
    uint32_t cp;
    if (!utf8_next(s, n, &i, &cp)) break;
    FT_Face seg = face_for_char(ft0, cp, run, weight);
    size_t end = i;
    while (end < n) {
      size_t j = end;
      uint32_t cp2;
      if (!utf8_next(s, n, &j, &cp2)) break;
      if (face_for_char(ft0, cp2, run, weight) != seg) break;
      end = j;
    }
    hb_font_t *font = hb_font_for(seg);
    if (!font) return -1;
    shape_variations(font, size, weight, run);
    hb_buffer_t *buf = hb_buffer_create();
    hb_buffer_add_utf8(buf, (const char *)s + start, (int)(end - start), 0, -1);
    hb_buffer_guess_segment_properties(buf);
    hb_shape(font, buf, run ? run->features : NULL, run ? run->feature_count : 0);
    unsigned count = 0;
    hb_glyph_info_t *info = hb_buffer_get_glyph_infos(buf, &count);
    hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(buf, &count);
    unsigned upem = hb_face_get_upem(hb_font_get_face(font));
    double scale = size / (double)(upem ? upem : 1000);
    int prev_cluster = -1;
    int prev_space = 0;
    for (unsigned g = 0; g < count; g++) {
      if (prev_cluster >= 0 && (int)info[g].cluster != prev_cluster) {
        pen += letter;
        if (prev_space) pen += word;
      }
      prev_cluster = (int)info[g].cluster;
      prev_space = cluster_is_space(s + start, end - start, (unsigned)prev_cluster);
      double adv = pos[g].x_advance * scale;
      double xoff = pos[g].x_offset * scale;
      double yoff = pos[g].y_offset * scale;
      if (shaped_count == shaped_cap) {
        int cap = shaped_cap ? shaped_cap * 2 : 16;
        ShapedGlyph *grown = (ShapedGlyph *)realloc(shaped, (size_t)cap * sizeof(*grown));
        if (grown) { shaped = grown; shaped_cap = cap; }
      }
      if (shaped_count < shaped_cap) {
        shaped[shaped_count].ft = seg;
        shaped[shaped_count].glyph = info[g].codepoint;
        shaped[shaped_count].x = pen - origin + xoff;
        shaped[shaped_count].y_offset = yoff;
        shaped[shaped_count].advance = adv;
        shaped_count++;
      }
      if (cb) cb(ctx, face, seg, info[g].codepoint, pen + xoff, yoff, adv);
      pen += adv;
    }
    if (prev_cluster >= 0) {
      pen += letter;
      if (prev_space) pen += word;
    }
    hb_buffer_destroy(buf);
    i = end;
  }
  ShapedRun *kept = NULL;
  shaped_run_store(s, n, size, weight, letter, word, hash, shaped, shaped_count, pen - origin, &kept);
  if (!kept) free(shaped);
  return pen - origin;
}

// How long shaping text has taken since the frame line last asked: the share of a layout that is
// measuring text. Only a run that asks for frame timings pays to read the clock.
static double g_text_shape_ms = 0;

/** Milliseconds spent shaping text since the last call, for the frame line. */
double host_text_shape_time(void) {
  double ms = g_text_shape_ms;
  g_text_shape_ms = 0;
  return ms;
}

double host_measure_text(const uint8_t *s, size_t n, double size, double weight, double letter, double word) {
  double started = frame_times() ? now_ms() : 0;
  double w = shape_text(s, n, size, weight, letter, word, 0, NULL, NULL);
  if (started != 0) g_text_shape_ms += now_ms() - started;
  if (w >= 0) return w;
  // No font at all: the built-in families' tables are all there is to measure with.
  w = 0;
  int chars = 0, spaces = 0;
  size_t i = 0;
  uint32_t cp;
  while (utf8_next(s, n, &i, &cp)) {
    chars++;
    if (cp == ' ') spaces++;
    w += model_advance(weight, cp, size);
  }
  return w + letter * chars + word * spaces;
}

double host_font_ascent(double size, double weight) {
  Face *face = resolve_face(weight);
  if (face) return face->ascent * size / face->upem;
  return model_for(weight).ascent * size;
}

double host_font_descent(double size, double weight) {
  Face *face = resolve_face(weight);
  if (face) return -face->descent * size / face->upem;
  return model_for(weight).descent * size;
}

// What measureText reports about a run, packed the way the runtime unpacks it (seven little-endian
// doubles: width, ink left, ink right, ink ascent, ink descent, font ascent, font descent). The ink
// box comes from the outlines of the glyphs painting draws, measured from the pen the layout puts
// them at, so it agrees with the pixels whatever the font is.
typedef void (*metrics_cb)(const uint8_t *, size_t);

typedef struct {
  FT_Face primary;
  double size;
  double shear;
  double x_min, x_max, above, below;
  int ink;
} InkBox;

static void ink_glyph(void *data, Face *face, FT_Face ft, unsigned glyph, double x,
                      double yoff, double advance) {
  (void)face;
  (void)advance;
  InkBox *ink = data;
  FT_BBox box;
  if (FT_Load_Glyph(ft, glyph, FT_LOAD_NO_SCALE | FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP) != 0) return;
  if (ft->glyph->format != FT_GLYPH_FORMAT_OUTLINE || ft->glyph->outline.n_contours == 0) return;
  if (FT_Outline_Get_BBox(&ft->glyph->outline, &box) != 0) return;
  double scale = ink->size / ft_upem(ft);
  double sl = ft == ink->primary ? ink->shear : 0;
  double glyph_min = box.xMin * scale, glyph_max = box.xMax * scale;
  double top = box.yMax * scale + yoff, bottom = box.yMin * scale + yoff;
  // A slanted glyph leans further out at the end of the stroke its shear pushes.
  double x0 = x + glyph_min + sl * (sl > 0 ? bottom : top);
  double x1 = x + glyph_max + sl * (sl > 0 ? top : bottom);
  if (!ink->ink) {
    ink->x_min = x0; ink->x_max = x1; ink->above = top; ink->below = bottom; ink->ink = 1;
  } else {
    if (x0 < ink->x_min) ink->x_min = x0;
    if (x1 > ink->x_max) ink->x_max = x1;
    if (top > ink->above) ink->above = top;
    if (bottom < ink->below) ink->below = bottom;
  }
}

void host_text_metrics(const uint8_t *s, size_t n, double size, double weight, double letter, double word, metrics_cb cb) {
  double m[7];
  m[0] = host_measure_text(s, n, size, weight, letter, word);
  m[1] = m[2] = m[3] = m[4] = 0;
  m[5] = host_font_ascent(size, weight);
  m[6] = host_font_descent(size, weight);
  Face *face = resolve_face(weight);
  FT_Face ft = face_ft(face);
  if (ft) {
    int family = 0, italic = 0;
    double weight_value = 400;
    split_weight(weight, &family, &weight_value, &italic);
    InkBox ink;
    ink.primary = ft;
    ink.size = size;
    ink.shear = italic && !face_is_italic(ft, weight) ? 0.25 : 0;
    ink.x_min = ink.x_max = ink.above = ink.below = 0;
    ink.ink = 0;
    shape_text(s, n, size, weight, letter, word, 0, ink_glyph, &ink);
    if (ink.ink) {
      m[1] = -ink.x_min;
      m[2] = ink.x_max;
      m[3] = ink.above > 0 ? ink.above : 0;
      m[4] = ink.below < 0 ? -ink.below : 0;
    }
  }
  cb((const uint8_t *)m, sizeof(m));
}

double host_font_line_gap(double size, double weight) {
  Face *face = resolve_face(weight);
  if (face) return face->line_gap * size / face->upem;
  return model_for(weight).line_gap * size;
}

double host_font_x_height(double size, double weight) {
  Face *face = resolve_face(weight);
  if (face) return face->x_height * size / face->upem;
  return model_for(weight).x_height * size;
}

// The same metrics counted in device pixels and rounded to whole ones, which is what a line box's
// height is laid out from. A headless host draws at backing scale 1, so these match the CSS-px
// numbers exactly.
double host_font_ascent_device(double size, double weight) { return round(host_font_ascent(size, weight)); }
double host_font_descent_device(double size, double weight) { return round(host_font_descent(size, weight)); }
double host_font_line_gap_device(double size, double weight) { return round(host_font_line_gap(size, weight)); }

static void add_face_path(const char *path, int family, double lo, double hi, int italic) {
  if (g_face_count >= MAX_FACES) return;
  Face *face = &g_faces[g_face_count];
  load_face(face, (const uint8_t *)path, strlen(path));
  if (!face->loaded) return;
  face->family = family;
  face->weight_lo = lo;
  face->weight_hi = hi;
  face->italic = italic != 0;
  face->path = dup_str(path);
  g_face_count++;
}

/** The file fontconfig matches for a family name at a weight and style, or NULL. */
static char *family_file(const char *name, double weight, int italic) {
  FcPattern *pat = FcPatternCreate();
  FcPatternAddString(pat, FC_FAMILY, (const FcChar8 *)name);
  FcPatternAddInteger(pat, FC_WEIGHT, css_weight_class(weight));
  FcPatternAddInteger(pat, FC_SLANT, italic ? FC_SLANT_ITALIC : FC_SLANT_ROMAN);
  FcConfigSubstitute(NULL, pat, FcMatchPattern);
  FcDefaultSubstitute(pat);
  FcResult result;
  FcPattern *match = FcFontMatch(NULL, pat, &result);
  FcPatternDestroy(pat);
  char *out = NULL;
  if (match) {
    // A weak family binding means fontconfig substituted a family the machine doesn't have:
    // browsers fall back to the standard font instead of drawing the substitute, so a font-family
    // naming an unavailable face (SF Pro, FooBar) draws in serif, not in the default sans.
    FcValue binding_value;
    FcValueBinding binding = FcValueBindingEnd;
    if (FcPatternGetWithBinding(match, FC_FAMILY, 0, &binding_value, &binding) == FcResultMatch &&
        binding == FcValueBindingWeak) {
      FcPatternDestroy(match);
      return NULL;
    }
    FcChar8 *file = NULL;
    if (FcPatternGetString(match, FC_FILE, 0, &file) == FcResultMatch) out = dup_str((const char *)file);
    FcPatternDestroy(match);
  }
  return out;
}

/** Registers a family's faces from a family name: the regular one, and the bold and italic the
 *  system has for it, each with the weight range and style it covers. */
static int add_family_faces(const char *name, int family) {
  char *regular = family_file(name, 400, 0);
  if (!regular) return 0;
  add_face_path(regular, family, 400, 400, 0);
  free(regular);
  char *bold = family_file(name, 700, 0);
  if (bold) {
    add_face_path(bold, family, 600, 900, 0);
    free(bold);
  }
  char *ital = family_file(name, 400, 1);
  if (ital) {
    add_face_path(ital, family, 400, 400, 1);
    free(ital);
  }
  char *bi = family_file(name, 700, 1);
  if (bi) {
    add_face_path(bi, family, 600, 900, 1);
    free(bi);
  }
  return 1;
}

/** Chromium's Linux stand-in for a common font the system may lack, so a page naming it draws the
 *  face Chrome draws: Chrome matches Helvetica to Liberation Sans on Linux, where fontconfig on its
 *  own would pick Nimbus Sans. */
static const char *common_font_alias(const char *name) {
  if (strcasecmp(name, "Helvetica") == 0) return "Liberation Sans";
  return NULL;
}

/** The fontconfig family a standard CSS family name stands for, or NULL for an installed name. */
static const char *local_family_name(const uint8_t *name, size_t n) {
  static const char *keys[] = {
    "ui-serif", "ui-rounded", "ui-monospace", "ui-sans-serif", "system-ui", "-apple-system",
    "blinkmacsystemfont", "sans-serif", "serif", "monospace",
  };
  static const char *names[] = {
    "Times New Roman", "Arial", "monospace", "Arial", "Arial", "Arial",
    "Arial", "Arial", "Times New Roman", "monospace",
  };
  for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
    if (strlen(keys[i]) == n && strncasecmp((const char *)name, keys[i], n) == 0) return names[i];
  }
  return NULL;
}

int32_t host_register_font_local(const uint8_t *name, size_t name_len, double family, double lo,
                                 double hi, double italic, const uint8_t *ranges, size_t ranges_len,
                                 const uint8_t *features, size_t features_len, double stretch) {
  (void)ranges;
  (void)ranges_len;
  (void)features;
  (void)features_len;
  (void)stretch;
  char key[256];
  if (name_len >= sizeof(key)) return 0;
  memcpy(key, name, name_len);
  key[name_len] = '\0';
  const char *standard = local_family_name(name, name_len);
  if (standard) return add_family_faces(standard, (int)family);
  const char *alias = common_font_alias(key);
  if (alias) return add_family_faces(alias, (int)family);
  char *file = family_file(key, 400, italic != 0);
  if (!file) return 0;
  add_face_path(file, (int)family, lo, hi, italic != 0);
  free(file);
  return 1;
}

int32_t host_register_font_named(const uint8_t *name, size_t name_len, double family) {
  char key[256];
  if (name_len >= sizeof(key)) return 0;
  memcpy(key, name, name_len);
  key[name_len] = '\0';
  const char *standard = local_family_name(name, name_len);
  if (standard) return add_family_faces(standard, (int)family);
  const char *alias = common_font_alias(key);
  return add_family_faces(alias ? alias : key, (int)family);
}

void host_register_font(const uint8_t *path, size_t path_len, double family, double lo, double hi, double italic,
                        const uint8_t *ranges, size_t ranges_len,
                        const uint8_t *features, size_t features_len, double stretch) {
  (void)ranges;
  (void)ranges_len;
  (void)features;
  (void)features_len;
  (void)stretch;
  if (g_face_count >= MAX_FACES) return;
  Face *face = &g_faces[g_face_count];
  load_face(face, path, path_len);
  face->family = (int)family;
  face->weight_lo = lo;
  face->weight_hi = hi;
  face->italic = italic != 0;
  char name[4096];
  if (path_len < sizeof(name)) {
    memcpy(name, path, path_len);
    name[path_len] = '\0';
    face->path = dup_str(name);
  }
  g_face_count++;
}

// ---------------------------------------------------------------------------
// Images: the intrinsic size a replaced element takes. Only the header is read.

typedef struct {
  char *path;
  int oriented;
  double w, h;
  unsigned char *px; // premultiplied RGBA, top row first
  size_t stride;
  int loaded;
  cairo_surface_t *surface; // made from the pixels on first draw, in the surface's channel order
} Image;
static Image *g_images = NULL;
static int g_image_count = 0, g_image_cap = 0;

/** The orientation tag of a TIFF header and its first IFD, or 1. */
static int tiff_orientation(const uint8_t *t, size_t avail) {
  if (avail < 8) return 1;
  int little = t[0] == 'I' && t[1] == 'I';
  // The offset comes from the file, so it is checked by subtraction: an offset near the top of
  // its range would wrap an addition and pass a check on the sum.
  size_t ifd = little ? (size_t)(t[4] | (t[5] << 8) | (t[6] << 16) | ((uint32_t)t[7] << 24)) : be32(t + 4);
  if (ifd > avail - 2) return 1;
  uint16_t count = little ? (uint16_t)(t[ifd] | (t[ifd + 1] << 8)) : be16(t + ifd);
  size_t at = ifd + 2;
  for (uint16_t i = 0; i < count; i++, at += 12) {
    if (avail - at < 12) break;
    uint16_t tag = little ? (uint16_t)(t[at] | (t[at + 1] << 8)) : be16(t + at);
    if (tag != 0x0112) continue;
    return little ? (t[at + 8] | (t[at + 9] << 8)) : be16(t + at + 8);
  }
  return 1;
}

/** The EXIF orientation of a JPEG, from its APP1 segment, or 1. */
static int jpeg_orientation(const uint8_t *d, size_t n) {
  size_t p = 2;
  while (p + 4 <= n) {
    if (d[p] != 0xff) break;
    uint8_t marker = d[p + 1];
    size_t len = be16(d + p + 2);
    if (marker == 0xd8 || marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) { p += 2; continue; }
    // The length counts the two length bytes, so the segment has to end inside the file before
    // anything in it is read.
    if (len < 2 || len > n - p - 2) break;
    if (marker == 0xe1 && len >= 8 && memcmp(d + p + 4, "Exif\0\0", 6) == 0) {
      return tiff_orientation(d + p + 10, len - 8);
    }
    p += 2 + len;
  }
  return 1;
}

/** The EXIF orientation of a PNG, from its eXIf chunk, or 1. */
static int png_orientation(const uint8_t *d, size_t n) {
  static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
  if (n < 16 || memcmp(d, sig, 8) != 0) return 1;
  size_t p = 8;
  while (p + 12 <= n) {
    uint32_t len = be32(d + p);
    const uint8_t *type = d + p + 4;
    if ((size_t)len > n - p - 12) break;
    if (memcmp(type, "eXIf", 4) == 0) return tiff_orientation(d + p + 8, len);
    if (memcmp(type, "IDAT", 4) == 0 || memcmp(type, "IEND", 4) == 0) break;
    p += 12 + (size_t)len;
  }
  return 1;
}

/** The EXIF orientation an image file records, or 1. */
static int image_orientation(const uint8_t *d, size_t n) {
  if (n >= 8 && d[0] == 0x89 && d[1] == 'P' && d[2] == 'N' && d[3] == 'G') return png_orientation(d, n);
  return jpeg_orientation(d, n);
}

// --- Decoders ---------------------------------------------------------------
//
// Each decoder hands back straight RGBA, top row first, which host_image_load premultiplies once
// into the layout the Cairo surface uses.

static int decode_png(const uint8_t *d, size_t n, unsigned char **out, int *ow, int *oh) {
  png_image img;
  memset(&img, 0, sizeof(img));
  img.version = PNG_IMAGE_VERSION;
  if (!png_image_begin_read_from_memory(&img, d, n)) return 0;
  img.format = PNG_FORMAT_RGBA;
  size_t size = PNG_IMAGE_SIZE(img);
  unsigned char *buf = (unsigned char *)malloc(size ? size : 1);
  if (!buf) return 0;
  if (!png_image_finish_read(&img, NULL, buf, 0, NULL)) {
    free(buf);
    png_image_free(&img);
    return 0;
  }
  *out = buf;
  *ow = (int)img.width;
  *oh = (int)img.height;
  return 1;
}

typedef struct {
  struct jpeg_error_mgr pub;
  jmp_buf jump;
} JpegError;

static void jpeg_fail(j_common_ptr info) {
  JpegError *e = (JpegError *)info->err;
  longjmp(e->jump, 1);
}

static int decode_jpeg(const uint8_t *d, size_t n, unsigned char **out, int *ow, int *oh) {
  struct jpeg_decompress_struct info;
  JpegError err;
  memset(&info, 0, sizeof(info));
  memset(&err, 0, sizeof(err));
  info.err = jpeg_std_error(&err.pub);
  err.pub.error_exit = jpeg_fail;
  if (setjmp(err.jump)) {
    jpeg_destroy_decompress(&info);
    return 0;
  }
  jpeg_create_decompress(&info);
  jpeg_mem_src(&info, d, (unsigned long)n);
  jpeg_read_header(&info, TRUE);
  info.out_color_space = JCS_RGB;
  jpeg_start_decompress(&info);
  int w = (int)info.output_width, h = (int)info.output_height;
  unsigned char *buf = (unsigned char *)malloc((size_t)w * (size_t)h * 4);
  unsigned char *row = (unsigned char *)malloc((size_t)w * 3);
  if (!buf || !row) {
    free(buf);
    free(row);
    jpeg_destroy_decompress(&info);
    return 0;
  }
  while (info.output_scanline < info.output_height) {
    JSAMPROW rp = row;
    jpeg_read_scanlines(&info, &rp, 1);
    unsigned char *o = buf + (size_t)(info.output_scanline - 1) * (size_t)w * 4;
    for (int x = 0; x < w; x++) {
      o[x * 4] = row[x * 3];
      o[x * 4 + 1] = row[x * 3 + 1];
      o[x * 4 + 2] = row[x * 3 + 2];
      o[x * 4 + 3] = 255;
    }
  }
  jpeg_finish_decompress(&info);
  jpeg_destroy_decompress(&info);
  free(row);
  *out = buf;
  *ow = w;
  *oh = h;
  return 1;
}

typedef struct {
  const uint8_t *d;
  size_t n, at;
} GifMemory;

static int gif_read(GifFileType *g, GifByteType *buf, int count) {
  GifMemory *m = (GifMemory *)g->UserData;
  if (m->at >= m->n) return 0;
  size_t k = (size_t)count < m->n - m->at ? (size_t)count : m->n - m->at;
  memcpy(buf, m->d + m->at, k);
  m->at += k;
  return (int)k;
}

static int decode_gif(const uint8_t *d, size_t n, unsigned char **out, int *ow, int *oh) {
  GifMemory mem = {d, n, 0};
  int error = 0;
  GifFileType *g = DGifOpen(&mem, gif_read, &error);
  if (!g) return 0;
  if (DGifSlurp(g) != GIF_OK) {
    DGifCloseFile(g, &error);
    return 0;
  }
  int w = g->SWidth, h = g->SHeight;
  if (w <= 0 || h <= 0) {
    DGifCloseFile(g, &error);
    return 0;
  }
  unsigned char *buf = (unsigned char *)calloc((size_t)w * (size_t)h * 4, 1);
  if (!buf) {
    DGifCloseFile(g, &error);
    return 0;
  }
  for (int f = 0; f < g->ImageCount; f++) {
    SavedImage *im = &g->SavedImages[f];
    if (!im->RasterBits) continue;
    ColorMapObject *map = im->ImageDesc.ColorMap ? im->ImageDesc.ColorMap : g->SColorMap;
    if (!map) continue;
    GraphicsControlBlock gcb;
    int transparent = -1;
    if (DGifSavedExtensionToGCB(g, f, &gcb) == GIF_OK && gcb.TransparentColor != NO_TRANSPARENT_COLOR) {
      transparent = gcb.TransparentColor;
    }
    int left = im->ImageDesc.Left, top = im->ImageDesc.Top;
    for (int y = 0; y < im->ImageDesc.Height; y++) {
      int ty = top + y;
      if (ty < 0 || ty >= h) continue;
      for (int x = 0; x < im->ImageDesc.Width; x++) {
        int tx = left + x;
        if (tx < 0 || tx >= w) continue;
        int idx = im->RasterBits[(size_t)y * (size_t)im->ImageDesc.Width + (size_t)x];
        if (idx == transparent || idx < 0 || idx >= map->ColorCount) continue;
        GifColorType c = map->Colors[idx];
        unsigned char *o = buf + ((size_t)ty * (size_t)w + (size_t)tx) * 4;
        o[0] = c.Red;
        o[1] = c.Green;
        o[2] = c.Blue;
        o[3] = 255;
      }
    }
    break; // the first frame is the image
  }
  DGifCloseFile(g, &error);
  *out = buf;
  *ow = w;
  *oh = h;
  return 1;
}

static int decode_bmp(const uint8_t *d, size_t n, unsigned char **out, int *ow, int *oh) {
  if (n < 54 || d[0] != 'B' || d[1] != 'M') return 0;
  uint32_t off = le32(d + 10);
  int32_t w = (int32_t)le32(d + 18), hraw = (int32_t)le32(d + 22);
  uint16_t bpp = le16(d + 28);
  uint32_t compression = le32(d + 30);
  if (compression != 0 && compression != 3) return 0;
  if (bpp != 24 && bpp != 32) return 0;
  int top_down = hraw < 0;
  int h = top_down ? -hraw : hraw;
  if (w <= 0 || h <= 0 || off >= n) return 0;
  size_t bytes = (size_t)bpp / 8;
  size_t stride = (size_t)(((size_t)w * bytes + 3) & ~(size_t)3);
  if (off + stride * (size_t)h > n) return 0;
  unsigned char *buf = (unsigned char *)malloc((size_t)w * (size_t)h * 4);
  if (!buf) return 0;
  for (int y = 0; y < h; y++) {
    int sy = top_down ? y : h - 1 - y;
    const unsigned char *row = d + off + (size_t)sy * stride;
    unsigned char *o = buf + (size_t)y * (size_t)w * 4;
    for (int x = 0; x < w; x++) {
      o[x * 4] = row[x * bytes + 2];
      o[x * 4 + 1] = row[x * bytes + 1];
      o[x * 4 + 2] = row[x * bytes];
      o[x * 4 + 3] = bytes == 4 ? row[x * bytes + 3] : 255;
    }
  }
  *out = buf;
  *ow = w;
  *oh = h;
  return 1;
}

/** Applies an EXIF orientation (2..8) to straight RGBA pixels, swapping the dimensions when the
 *  turn is a quarter one. */
static unsigned char *orient_pixels(unsigned char *src, int *w, int *h, int o) {
  if (o < 2 || o > 8) return src;
  int sw = *w, sh = *h;
  int swap = o >= 5;
  int dw = swap ? sh : sw, dh = swap ? sw : sh;
  unsigned char *dst = (unsigned char *)malloc((size_t)dw * (size_t)dh * 4);
  if (!dst) return src;
  for (int y = 0; y < dh; y++) {
    for (int x = 0; x < dw; x++) {
      int sx, sy;
      switch (o) {
        case 2: sx = sw - 1 - x; sy = y; break;
        case 3: sx = sw - 1 - x; sy = sh - 1 - y; break;
        case 4: sx = x; sy = sh - 1 - y; break;
        case 5: sx = y; sy = x; break;
        case 6: sx = y; sy = sh - 1 - x; break;
        case 7: sx = sw - 1 - y; sy = sh - 1 - x; break;
        default: sx = sw - 1 - y; sy = x; break;
      }
      memcpy(dst + ((size_t)y * (size_t)dw + (size_t)x) * 4,
             src + ((size_t)sy * (size_t)sw + (size_t)sx) * 4, 4);
    }
  }
  free(src);
  *w = dw;
  *h = dh;
  return dst;
}

int32_t host_image_load(const uint8_t *path, size_t path_len, int32_t oriented) {
  char name[4096];
  if (path_len >= sizeof(name)) return -1;
  memcpy(name, path, path_len);
  name[path_len] = '\0';
  for (int i = 0; i < g_image_count; i++) {
    if (g_images[i].oriented == oriented && strcmp(g_images[i].path, name) == 0) return i;
  }
  size_t len = 0;
  uint8_t *data = read_file(path, path_len, &len);
  if (!data) return -1;
  unsigned char *px = NULL;
  int w = 0, h = 0;
  int exif = oriented ? image_orientation(data, len) : 1;
  if (!decode_png(data, len, &px, &w, &h) && !decode_jpeg(data, len, &px, &w, &h) &&
      !decode_gif(data, len, &px, &w, &h) && !decode_bmp(data, len, &px, &w, &h)) {
    free(data);
    return -1;
  }
  free(data);
  if (!px || w <= 0 || h <= 0) {
    free(px);
    return -1;
  }
  if (oriented) px = orient_pixels(px, &w, &h, exif);
  // Premultiply once: the surface draws premultiplied pixels, and un-premultiplying a decoded
  // byte can only lose precision.
  size_t count = (size_t)w * (size_t)h;
  for (size_t i = 0; i < count; i++) {
    unsigned a = px[i * 4 + 3];
    if (a == 255) continue;
    px[i * 4] = (unsigned char)((px[i * 4] * a + 127) / 255);
    px[i * 4 + 1] = (unsigned char)((px[i * 4 + 1] * a + 127) / 255);
    px[i * 4 + 2] = (unsigned char)((px[i * 4 + 2] * a + 127) / 255);
  }
  if (g_image_count == g_image_cap) {
    g_image_cap = g_image_cap ? g_image_cap * 2 : 16;
    g_images = (Image *)realloc(g_images, (size_t)g_image_cap * sizeof(Image));
    // A new entry starts empty, so the first draw makes its surface.
    memset(g_images + g_image_count, 0, (size_t)(g_image_cap - g_image_count) * sizeof(Image));
  }
  Image *img = &g_images[g_image_count];
  img->path = dup_str(name);
  img->oriented = oriented;
  img->w = w;
  img->h = h;
  img->px = px;
  img->stride = (size_t)w * 4;
  img->loaded = 1;
  return g_image_count++;
}

double host_image_width(int32_t id) { return id >= 0 && id < g_image_count ? g_images[id].w : 0; }
double host_image_height(int32_t id) { return id >= 0 && id < g_image_count ? g_images[id].h : 0; }

// The headless host decodes on the thread that asks, so a load is over when host_image_load
// answers: there is never a decode to wait for.
int32_t host_image_ready(int32_t id) { (void)id; return 1; }
int32_t host_image_failed(int32_t id) { (void)id; return 0; }
void host_images_settled(void) {}

// ---------------------------------------------------------------------------
// Window, snapshot and preferences

// The accessibility tree's state lives with its own section further down; the event loop reads it
// here, so the pieces it needs are declared first.
static DBusConnection *g_ax_bus;
/** The action a client queued, which the event loop hands to the runtime next. */
static int ax_take_action(void);
/** Publishes the application on the accessibility bus, with no page under it until one is asked for. */
static void ax_connect(void);

static double g_view_w = 0, g_view_h = 0;
/** The window's own size, which its frame reports; the view fills it here. */
static double g_win_w = 0, g_win_h = 0;
/** The window's title, as document.title sets it. */
static char g_title[512] = "";
/** This window's id: a headless run starts the first one, or the id its env names. */
static int32_t g_win_id = 1;

/** The page's title, which is what the accessibility tree calls the application. */
static char g_ax_title[256] = "native";

/** The pointer position and buttons of the event being delivered, for host_event_* to read. */
static double g_ex = 0, g_ey = 0, g_dx = 0, g_dy = 0;
static int g_clicks = 0, g_mods = 0;

static void ax_set_title(const uint8_t *title, size_t title_len) {
  size_t len = title_len < sizeof(g_ax_title) - 1 ? title_len : sizeof(g_ax_title) - 1;
  if (len > 0) memcpy(g_ax_title, title, len);
  g_ax_title[len] = '\0';
}

void host_open(double width, double height, const uint8_t *title, size_t title_len) {
  if (title_len >= sizeof(g_title)) title_len = sizeof(g_title) - 1;
  memcpy(g_title, title, title_len);
  g_title[title_len] = '\0';
  const char *id = getenv("NATIVE_WINDOW_ID");
  if (id != NULL) g_win_id = (int32_t)strtol(id, NULL, 10);
  g_view_w = g_win_w = width;
  g_view_h = g_win_h = height;
  ax_set_title(title, title_len);
  // The application joins the accessibility bus now, so a client can find it before the page is
  // built; its one child, the document, arrives when a client first asks for the tree.
  ax_connect();
}

void host_set_title(const uint8_t *title, size_t title_len) {
  if (title_len >= sizeof(g_title)) title_len = sizeof(g_title) - 1;
  memcpy(g_title, title, title_len);
  g_title[title_len] = '\0';
  ax_set_title(title, title_len);
}

/** The events a host delivers, numbered as runtime/host.ts numbers them. */
enum {
  EV_NONE = 0, EV_QUIT = 1, EV_DOWN = 2, EV_UP = 3, EV_MOVE = 4, EV_RESIZE = 5, EV_LEAVE = 6,
  EV_OTHER = 7, EV_KEY = 8, EV_WHEEL = 9, EV_SETTINGS = 10, EV_AXFOCUS = 11, EV_AXSELRANGE = 12,
  EV_DROP = 13, EV_MENU = 14, EV_CONTEXT = 15, EV_WINDOWMOVE = 16, EV_FULLSCREEN = 17,
  EV_FOCUS = 18, EV_BLUR = 19, EV_VISIBILITY = 20, EV_MESSAGE = 21, EV_WINDOWCLOSED = 22,
  EV_APPQUIT = 23, EV_COMPOSE = 24,
  /** A key was released. This host has no keyboard of its own: headless steps send keyup. */
  EV_KEYUP = 25,
  /** An accessibility client acted on a node: host_ax_action() says how. */
  EV_AXACTION = 26,
};

/** The queued events host_poll hands out (see the menu and window section below). */
static int32_t take_event(void);

/** The display's refresh period in milliseconds. A headless host has no display link to ask, so
 *  it answers the rate a display would: sixty frames a second. */
double host_refresh_interval(void) { return 1000.0 / 60.0; }

/** How long until the display's next refresh in milliseconds; 0 when nothing displays. */
double host_until_refresh(void) { return 0; }

/** No display link here: the runtime's timer paces frames. */
int32_t host_gl_window(void) { return 0; }

int32_t host_poll(double timeout) {
  (void)timeout;
  // Whatever assistive clients asked for arrives on the bus: an event, or an action on a node.
  if (g_ax_bus != NULL) dbus_connection_read_write_dispatch(g_ax_bus, 0);
  // A client's action goes to the runtime first, one per poll, in the order it came.
  if (ax_take_action()) return EV_AXACTION;
  return take_event();
}
double host_view_width(void) { return g_view_w; }
double host_view_height(void) { return g_view_h; }
double host_event_x(void) { return g_ex; }
double host_event_y(void) { return g_ey; }
double host_event_dx(void) { return g_dx; }
double host_event_dy(void) { return g_dy; }
int32_t host_event_phase(void) { return 0; }
int32_t host_event_clicks(void) { return g_clicks; }
int32_t host_event_key(void) { return 13; }
int32_t host_event_mods(void) { return g_mods; }
/** No key here repeats: the host has no keyboard, and a headless step says repeat itself. */
int32_t host_event_repeat(void) { return 0; }
void host_event_text(void *receive) { (void)receive; }
/* There is no window and no input method here, so a composition never starts: a headless run
 * drives one with its compose, commit and cancelcompose steps instead. */
int32_t host_composition_phase(void) { return -1; }
void host_composition_text(void *receive) { (void)receive; }
void host_composition_rect(double x, double y, double w, double h) { (void)x; (void)y; (void)w; (void)h; }
void host_target_text(void *receive) { (void)receive; }
void host_set_cursor(int32_t cursor) { (void)cursor; }

static void clear_glyph_paths(void);
static void clear_line_breaks(void);

/** Drops the page's own faces and the system matches, as a new document does. */
void host_reset_fonts(void) {
  clear_shaped_runs();
  clear_glyph_paths();
  clear_line_breaks();
  hb_release_fonts();
  for (int i = 0; i < g_face_count; i++) {
    Face *f = &g_faces[i];
    if (f->ft) FT_Done_Face(f->ft);
    free(f->data);
    free(f->path);
  }
  g_face_count = 0;
  for (int i = 0; i < g_match_count; i++) {
    Face *f = &g_matches[i].face;
    if (f->ft) FT_Done_Face(f->ft);
    free(f->data);
    free(f->path);
    memset(&g_matches[i], 0, sizeof(g_matches[i]));
  }
  g_match_count = 0;
}

uint32_t host_selection_color(void) { return 0xb4d5feff; }

/** The keyboard focus ring colour, which is what Chrome draws for :focus-visible. */
uint32_t host_focus_ring_color(void) { return 0x0064e1ffu; }

/** The system appearance: 1 when dark mode is on. Tests pin it with NATIVE_COLOR_SCHEME. */
int32_t host_color_scheme(void) {
  const char *env = getenv("NATIVE_COLOR_SCHEME");
  return env && *env ? (strcmp(env, "dark") == 0 ? 1 : 0) : 0;
}

// The accessibility display settings media queries ask about, pinned by environment for tests.
int32_t host_increase_contrast(void) {
  const char *env = getenv("NATIVE_INCREASE_CONTRAST");
  return env && *env ? (strcmp(env, "0") != 0 ? 1 : 0) : 0;
}

int32_t host_reduce_transparency(void) {
  const char *env = getenv("NATIVE_REDUCE_TRANSPARENCY");
  return env && *env ? (strcmp(env, "0") != 0 ? 1 : 0) : 0;
}

/** The media type the page is laid out for: NATIVE_MEDIA=print asks for print media. */
int32_t host_media_type(void) {
  const char *env = getenv("NATIVE_MEDIA");
  return env != NULL && strcmp(env, "print") == 0 ? 1 : 0;
}

/** This host has no window, so nothing of it is titlebar. */
double host_titlebar_area(int32_t which) { (void)which; return 0; }
void host_window_drag(void) {}

// ---------------------------------------------------------------------------
// Menus, windows and the app's lifecycle. There is no menu bar and no desktop here, so the calls
// record what the page asked for, and the events a window would send wait in a queue for
// host_poll. A headless run's steps (`focus`, `blur`, `message`, `contextmenu`, `quit`) and the
// page's own window.open() take the same paths a real window's do.

// The events are numbered with the accessibility ones above, as runtime/host.ts numbers them.

static int32_t g_events[64];
static int g_event_head = 0, g_event_tail = 0;

static void queue_event(int32_t ev) {
  int next = (g_event_tail + 1) % 64;
  if (next == g_event_head) return; // full: the newest event is dropped
  g_events[g_event_tail] = ev;
  g_event_tail = next;
}

static int32_t take_event(void) {
  if (g_event_head == g_event_tail) return EV_NONE;
  int32_t ev = g_events[g_event_head];
  g_event_head = (g_event_head + 1) % 64;
  return ev;
}

/** The window's frame on the screen and whether it is fullscreen or hidden. Headless, a move or a
 *  resize is only what the page asked for, but the events are the ones a real window sends. */
static double g_win_x = 0, g_win_y = 0;
static int32_t g_fullscreen = 0;
static int32_t g_hidden = 0;

/** The windows this one opened, by the name a link's target or window.open gave them. */
typedef struct {
  int32_t id;
  char name[128];
  int open;
} OpenedWindow;
static OpenedWindow g_opened[32];
static int g_opened_count = 0;
static int32_t g_next_window = 2;
static int32_t g_closed_window = 0;

/** The message waiting for the page, with the window it came from. */
static int32_t g_message_from = 0;
static char *g_message_data = NULL;

static void queue_message(int32_t from, const char *data, size_t len) {
  free(g_message_data);
  g_message_data = (char *)malloc(len + 1);
  if (g_message_data == NULL) return;
  memcpy(g_message_data, data, len);
  g_message_data[len] = '\0';
  g_message_from = from;
  queue_event(EV_MESSAGE);
}

/** The menu spec the host built or showed last, for a run's `menu` step. */
static char *g_menu_last = NULL;

static void remember_menu(const uint8_t *spec, size_t n) {
  free(g_menu_last);
  g_menu_last = (char *)malloc(n + 1);
  if (g_menu_last == NULL) return;
  memcpy(g_menu_last, spec, n);
  g_menu_last[n] = '\0';
}

typedef void (*window_text_cb)(const uint8_t *, size_t);

static void copy_name(char *out, size_t cap, const uint8_t *name, size_t n) {
  if (n >= cap) n = cap - 1;
  memcpy(out, name, n);
  out[n] = '\0';
}

void host_menu_set(const uint8_t *spec, size_t n) { remember_menu(spec, n); }

/** Nobody chooses from a menu here: a headless run picks an item with a `menuclick` step, which
 *  takes the same path the native item's action does. A run that sets NATIVE_MENU_CHOICE makes
 *  every context menu choose that line, as a click on it would. */
int32_t host_menu_popup(const uint8_t *spec, size_t n, double x, double y) {
  (void)x;
  (void)y;
  remember_menu(spec, n);
  const char *choice = getenv("NATIVE_MENU_CHOICE");
  return choice != NULL && choice[0] != '\0' ? (int32_t)strtol(choice, NULL, 10) : -1;
}

int32_t host_menu_item(void) { return -1; }

void host_menu_spec(window_text_cb cb) {
  const char *spec = g_menu_last == NULL ? "" : g_menu_last;
  cb((const uint8_t *)spec, strlen(spec));
}

/** A window this one opens is recorded rather than started: there is no process to run here, so
 *  the handle reports what a browser's would (its name, that it is open) and messages to it go
 *  nowhere. A name that is already open is focused and answered with its id, as a browser reuses
 *  a named window. */
int32_t host_window_open(const uint8_t *url, size_t n, const uint8_t *name, size_t name_len,
                         const uint8_t *features, size_t features_len) {
  (void)url;
  (void)n;
  (void)features;
  (void)features_len;
  char wanted[128];
  copy_name(wanted, sizeof(wanted), name, name_len);
  if (wanted[0] != '\0') {
    for (int i = 0; i < g_opened_count; i++) {
      if (g_opened[i].open && strcmp(g_opened[i].name, wanted) == 0) return g_opened[i].id;
    }
  }
  int32_t id = g_next_window++;
  if (g_opened_count < (int)(sizeof(g_opened) / sizeof(g_opened[0]))) {
    g_opened[g_opened_count].id = id;
    copy_name(g_opened[g_opened_count].name, sizeof(g_opened[0].name), name, name_len);
    g_opened[g_opened_count].open = 1;
    g_opened_count++;
  }
  return id;
}

int32_t host_window_id(void) { return g_win_id; }

void host_window_close(int32_t id) {
  if (id <= 0) {
    // Closing this window ends the app when it is the only one, as on the desktop.
    queue_event(EV_QUIT);
    return;
  }
  for (int i = 0; i < g_opened_count; i++) {
    if (g_opened[i].id == id && g_opened[i].open) {
      g_opened[i].open = 0;
      g_closed_window = id;
      queue_event(EV_WINDOWCLOSED);
      return;
    }
  }
}

void host_window_focus(int32_t id) { (void)id; }
void host_window_blur(void) {}

int32_t host_window_closed(void) { return g_closed_window; }

void host_window_set_frame(double x, double y, double w, double h) {
  // The first report says what the window already is (a headless run's own size), not a change.
  int first = g_win_w == 0 && g_win_h == 0;
  int moved = 0, resized = 0;
  if (x >= 0 && x != g_win_x) { g_win_x = x; moved = 1; }
  if (y >= 0 && y != g_win_y) { g_win_y = y; moved = 1; }
  if (w >= 0 && w != g_win_w) { g_view_w = g_win_w = w; resized = 1; }
  if (h >= 0 && h != g_win_h) { g_view_h = g_win_h = h; resized = 1; }
  if (first) return;
  if (moved) queue_event(EV_WINDOWMOVE);
  if (resized) queue_event(EV_RESIZE);
}

double host_window_frame(int32_t which) {
  return which == 0 ? g_win_x : which == 1 ? g_win_y : which == 2 ? g_win_w : g_win_h;
}

void host_window_fullscreen(int32_t on) {
  if ((on != 0) == (g_fullscreen != 0)) return;
  g_fullscreen = on != 0;
  queue_event(EV_FULLSCREEN);
}

int32_t host_window_fullscreen_state(void) { return g_fullscreen; }
int32_t host_window_hidden(void) { return g_hidden; }

void host_window_set_hidden(int32_t hidden) {
  if ((hidden != 0) == (g_hidden != 0)) return;
  g_hidden = hidden != 0;
  queue_event(EV_VISIBILITY);
}

void host_window_minimize(void) {}
void host_window_zoom(void) {}

void host_title(window_text_cb cb) { cb((const uint8_t *)g_title, strlen(g_title)); }

/** A message to a window this one opened has no receiver here; one to the opener arrives when a
 *  run names it. A headless run delivers a window's message with a `message` step. */
void host_post_message(int32_t target, const uint8_t *data, size_t n) {
  if (target == g_win_id) queue_message(g_win_id, (const char *)data, n);
}

int32_t host_message_source(void) { return g_message_from; }

void host_message_data(window_text_cb cb) {
  const char *data = g_message_data == NULL ? "" : g_message_data;
  cb((const uint8_t *)data, strlen(data));
}

void host_app_action(const uint8_t *action, size_t n) { (void)action; (void)n; }

void host_quit(void) { queue_event(EV_QUIT); }

// ===========================================================================
// Text painting: glyphs are loaded through FreeType and filled as paths, advanced by the same
// numbers host_measure_text measures, so a run's paint lands on the layout's own pen positions.

/** The font units of the face a weight paints with, for turning them into pixels. */
static double ft_upem(FT_Face ft) { return ft->units_per_EM ? ft->units_per_EM : 1000; }

// A font for the characters the run's own font has none of: fontconfig's best match covering the
// code point, found once per character and kept.
typedef struct {
  uint32_t cp;
  FT_Face ft;
} Fallback;

#define MAX_FALLBACKS 64
static Fallback g_fallbacks[MAX_FALLBACKS];
static int g_fallback_count = 0;

static FT_Face fallback_face(uint32_t cp) {
  for (int i = 0; i < g_fallback_count; i++) {
    if (g_fallbacks[i].cp == cp) return g_fallbacks[i].ft;
  }
  if (g_fallback_count >= MAX_FALLBACKS) return NULL;
  FT_Library lib = ft_library();
  if (!lib) return NULL;
  FcPattern *pat = FcPatternCreate();
  FcCharSet *set = FcCharSetCreate();
  FcCharSetAddChar(set, cp);
  FcPatternAddCharSet(pat, FC_CHARSET, set);
  FcPatternAddString(pat, FC_FAMILY, (const FcChar8 *)"sans-serif");
  FcConfigSubstitute(NULL, pat, FcMatchPattern);
  FcDefaultSubstitute(pat);
  FcResult result;
  FcPattern *match = FcFontMatch(NULL, pat, &result);
  FcPatternDestroy(pat);
  FcCharSetDestroy(set);
  FT_Face ft = NULL;
  if (match) {
    FcChar8 *file = NULL;
    int index = 0;
    if (FcPatternGetString(match, FC_FILE, 0, &file) == FcResultMatch &&
        FcPatternGetInteger(match, FC_INDEX, 0, &index) == FcResultMatch) {
      if (FT_New_Face(lib, (const char *)file, index, &ft) != 0) ft = NULL;
      if (ft && FT_Get_Char_Index(ft, cp) == 0) {
        FT_Done_Face(ft);
        ft = NULL;
      }
    }
    FcPatternDestroy(match);
  }
  g_fallbacks[g_fallback_count].cp = cp;
  g_fallbacks[g_fallback_count].ft = ft;
  g_fallback_count++;
  return ft;
}

// Decomposing an outline straight into a Cairo path, with the font's y-up coordinates turned into
// the display list's y-down ones and scaled from font units to pixels.
typedef struct {
  cairo_t *cr;
  double ox, oy;     // the pen position, in user space
  double scale;      // font units to pixels
  double shear;      // horizontal shear per pixel above the baseline, for a synthesized italic
  double baseline;   // where the glyph sits, in user space
} OutlinePaint;

static void outline_point(const OutlinePaint *p, const FT_Vector *v, double *x, double *y) {
  double gx = v->x * p->scale, gy = v->y * p->scale;
  *x = p->ox + gx + p->shear * gy;
  *y = p->baseline - gy;
}

static int outline_move(const FT_Vector *to, void *data) {
  OutlinePaint *p = data;
  double x, y;
  outline_point(p, to, &x, &y);
  cairo_move_to(p->cr, x, y);
  return 0;
}

static int outline_line(const FT_Vector *to, void *data) {
  OutlinePaint *p = data;
  double x, y;
  outline_point(p, to, &x, &y);
  cairo_line_to(p->cr, x, y);
  return 0;
}

// A quadratic curve as the cubic a Cairo path holds.
static int outline_conic(const FT_Vector *control, const FT_Vector *to, void *data) {
  OutlinePaint *p = data;
  double x0, y0;
  cairo_get_current_point(p->cr, &x0, &y0);
  double cx, cy, x, y;
  outline_point(p, control, &cx, &cy);
  outline_point(p, to, &x, &y);
  cairo_curve_to(p->cr, x0 + (cx - x0) * 2 / 3, y0 + (cy - y0) * 2 / 3,
                 x + (cx - x) * 2 / 3, y + (cy - y) * 2 / 3, x, y);
  return 0;
}

static int outline_cubic(const FT_Vector *c1, const FT_Vector *c2, const FT_Vector *to, void *data) {
  OutlinePaint *p = data;
  double ax, ay, bx, by, x, y;
  outline_point(p, c1, &ax, &ay);
  outline_point(p, c2, &bx, &by);
  outline_point(p, to, &x, &y);
  cairo_curve_to(p->cr, ax, ay, bx, by, x, y);
  return 0;
}

static const FT_Outline_Funcs g_outline_funcs = {
  (FT_Outline_MoveToFunc)outline_move,
  (FT_Outline_LineToFunc)outline_line,
  (FT_Outline_ConicToFunc)outline_conic,
  (FT_Outline_CubicToFunc)outline_cubic,
  0, 0,
};

/** Adds one shaped glyph's outline to the current path, moved by the shaping offsets the font
 *  gave it. Returns 0 when the face has no such glyph. */
// A glyph's outline is the same at every pen for a face, size and slant, and a page draws thousands
// of glyphs from a handful of those. Each glyph's path is built once, at the origin, and appended
// translated on the next draws: a replay no longer decomposes every outline again.
typedef struct {
  FT_Face ft;
  unsigned glyph;
  double size;
  double shear;
  cairo_path_t *path;
  int used;
} GlyphPath;

#define GLYPH_PATH_SLOTS 8192
static GlyphPath g_glyph_paths[GLYPH_PATH_SLOTS];
static cairo_surface_t *g_glyph_scratch_surface = NULL;
static cairo_t *g_glyph_scratch = NULL;

static void clear_glyph_paths(void) {
  for (int i = 0; i < GLYPH_PATH_SLOTS; i++) {
    if (g_glyph_paths[i].path) cairo_path_destroy(g_glyph_paths[i].path);
    g_glyph_paths[i].path = NULL;
    g_glyph_paths[i].used = 0;
  }
}

static unsigned glyph_path_hash(FT_Face ft, unsigned glyph, double size, double shear) {
  uint64_t h = (uint64_t)(uintptr_t)ft * 31u + glyph;
  uint64_t bits = 0;
  memcpy(&bits, &size, sizeof(bits));
  h = h * 1099511628211ull ^ bits;
  memcpy(&bits, &shear, sizeof(bits));
  h = h * 1099511628211ull ^ bits;
  return (unsigned)(h & (GLYPH_PATH_SLOTS - 1));
}

/** A context with no transform, for building a glyph's path at the origin. Its surface is never
 *  drawn on: only the path copy is kept. */
static cairo_t *glyph_scratch(void) {
  if (!g_glyph_scratch) {
    g_glyph_scratch_surface = cairo_image_surface_create(CAIRO_FORMAT_A8, 1, 1);
    if (cairo_surface_status(g_glyph_scratch_surface) != CAIRO_STATUS_SUCCESS) {
      cairo_surface_destroy(g_glyph_scratch_surface);
      g_glyph_scratch_surface = NULL;
      return NULL;
    }
    g_glyph_scratch = cairo_create(g_glyph_scratch_surface);
    if (cairo_status(g_glyph_scratch) != CAIRO_STATUS_SUCCESS) {
      cairo_destroy(g_glyph_scratch);
      g_glyph_scratch = NULL;
    }
  }
  return g_glyph_scratch;
}

/** The path for one glyph at this size and slant, built once. NULL when the glyph has no outline
 *  or the table is full, in which case the caller builds it directly. */
static cairo_path_t *cached_glyph_path(FT_Face ft, unsigned glyph, double size, double shear) {
  unsigned at = glyph_path_hash(ft, glyph, size, shear);
  for (int probe = 0; probe < 32; probe++, at = (at + 1) & (GLYPH_PATH_SLOTS - 1)) {
    GlyphPath *entry = &g_glyph_paths[at];
    if (entry->used) {
      if (entry->ft == ft && entry->glyph == glyph && entry->size == size && entry->shear == shear) {
        return entry->path;
      }
      continue;
    }
    if (FT_Load_Glyph(ft, glyph, FT_LOAD_NO_SCALE | FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP) != 0) return NULL;
    if (ft->glyph->format != FT_GLYPH_FORMAT_OUTLINE) return NULL;
    cairo_t *scratch = glyph_scratch();
    if (!scratch) return NULL;
    cairo_new_path(scratch);
    OutlinePaint p;
    p.cr = scratch;
    p.ox = 0;
    p.oy = 0;
    p.scale = size / ft_upem(ft);
    p.shear = shear;
    p.baseline = 0;
    FT_Outline_Decompose(&ft->glyph->outline, &g_outline_funcs, &p);
    cairo_close_path(scratch);
    entry->path = cairo_copy_path(scratch);
    cairo_new_path(scratch);
    if (!entry->path || entry->path->status != CAIRO_STATUS_SUCCESS) {
      if (entry->path) cairo_path_destroy(entry->path);
      entry->path = NULL;
      return NULL;
    }
    entry->ft = ft;
    entry->glyph = glyph;
    entry->size = size;
    entry->shear = shear;
    entry->used = 1;
    return entry->path;
  }
  return NULL;
}

static int glyph_path(cairo_t *cr, FT_Face ft, unsigned glyph, double size, double x, double baseline,
                      double shear, double y_offset) {
  if (glyph == 0) return 0;
  cairo_path_t *path = cached_glyph_path(ft, glyph, size, shear);
  if (path) {
    cairo_save(cr);
    cairo_translate(cr, x, baseline - y_offset);
    cairo_append_path(cr, path);
    cairo_restore(cr);
    return 1;
  }
  if (FT_Load_Glyph(ft, glyph, FT_LOAD_NO_SCALE | FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP) != 0) return 0;
  if (ft->glyph->format != FT_GLYPH_FORMAT_OUTLINE) return 0;
  OutlinePaint p;
  p.cr = cr;
  p.ox = x;
  p.oy = 0;
  p.scale = size / ft_upem(ft);
  p.shear = shear;
  p.baseline = baseline - y_offset;
  FT_Outline_Decompose(&ft->glyph->outline, &g_outline_funcs, &p);
  cairo_close_path(cr);
  return 1;
}

/** Whether the face has a real italic: a synthesized one slants the upright outline instead. */
static int face_is_italic(FT_Face ft, double weight) {
  Face *f = face_for(weight);
  if (f) return f->italic;
  return (ft->style_flags & FT_STYLE_FLAG_ITALIC) != 0;
}

/** Whether the face already carries the requested weight, rather than needing a stroke. */
static int face_is_bold(FT_Face ft, double weight) {
  int family = 0;
  double w = 400;
  int italic = 0;
  split_weight(weight, &family, &w, &italic);
  Face *f = face_for(weight);
  if (f) return w < 600 || f->weight_hi >= 600;
  if (w < 600) return 1;
  return (ft->style_flags & FT_STYLE_FLAG_BOLD) != 0;
}

/** The leading a line box leaves for a size and weight: what layout uses, in CSS px. */
static double line_ascent(double size, double weight) { return host_font_ascent(size, weight); }
static double line_descent(double size, double weight) { return host_font_descent(size, weight); }

/** Where a line box's baseline sits, rounded to the device grid like the layout's own numbers. */
static double text_baseline(double size, double weight, double y, double line_height, double scale) {
  double ascent = round(line_ascent(size, weight) * scale), descent = round(line_descent(size, weight) * scale);
  return y + (ascent + floor((line_height * scale - ascent - descent) / 2)) / scale;
}

static double device_round(double v, double scale) { return round(v * scale) / scale; }

/** Where one emphasis mark's centre goes. */
typedef struct { double cx, cy; } Mark;

/** What painting one shaped run needs: its pen, its path and the marks it records. */
typedef struct {
  cairo_t *cr;
  FT_Face primary;
  double shear;
  double size;
  double weight;
  double baseline;
  double scale;
  int emphasis;
  Mark *marks;
  int count;
  int cap;
} PaintRun;

static void paint_glyph(void *data, Face *face, FT_Face ft, unsigned glyph, double x,
                        double y_offset, double advance) {
  (void)face;
  PaintRun *p = data;
  glyph_path(p->cr, ft, glyph, p->size, x, p->baseline, ft == p->primary ? p->shear : 0, y_offset);
  if (p->emphasis > 0 && advance > 0 && p->marks && p->count < p->cap) {
    int below = (p->emphasis >> 8) & 1;
    p->marks[p->count].cy = below
      ? p->baseline + (line_descent(p->size, p->weight) + p->size * 0.17)
      : p->baseline - (line_ascent(p->size, p->weight) + p->size * 0.17);
    p->marks[p->count].cx = device_round(x + advance / 2, p->scale);
    p->count++;
  }
}

/**
 * Adds a run at (x, baseline) to the current path. Letter and word spacing are the layout's:
 * every code point gets `letter`, and a space gets `word` on top of it. One emphasis mark is
 * recorded per glyph with an advance of its own; they are drawn after the glyphs so an open one
 * never covers a glyph. Returns how many marks were recorded, at most `cap`.
 */
static int paint_run(cairo_t *cr, const uint8_t *s, size_t n, double size, double weight, double letter,
                     double word, double x, double baseline, double scale, int emphasis, Mark *marks,
                     int cap) {
  FT_Face ft = paint_face(weight);
  if (!ft) return 0;
  // A run that asks for an italic the face doesn't have is slanted by the host, as a browser
  // slants it.
  int family = 0;
  double weight_value = 400;
  int italic = 0;
  split_weight(weight, &family, &weight_value, &italic);
  PaintRun p;
  p.cr = cr;
  p.primary = ft;
  p.shear = italic && !face_is_italic(ft, weight) ? 0.25 : 0;
  p.size = size;
  p.weight = weight;
  p.baseline = baseline;
  p.scale = scale;
  p.emphasis = emphasis;
  p.marks = marks;
  p.count = 0;
  p.cap = cap;
  shape_text(s, n, size, weight, letter, word, x, paint_glyph, &p);
  return p.count;
}

/** One emphasis mark, centred at (cx, cy): a filled shape for the odd styles and an open one for
 *  the even styles, as TEXTE_* numbers them. */
void draw_emphasis_mark(cairo_t *cr, int style, double cx, double cy, double size) {
  int shape = (style - 1) / 2;
  int open = (style % 2) == 0;
  cairo_new_path(cr);
  switch (shape) {
    case 0: // dot
      if (open) {
        cairo_set_line_width(cr, size * 0.03);
        cairo_arc(cr, cx, cy, size * 0.22 / 2 - size * 0.03 / 2, 0, 2 * M_PI);
        cairo_stroke(cr);
      } else {
        cairo_arc(cr, cx, cy, size * 0.125 / 2, 0, 2 * M_PI);
        cairo_fill(cr);
      }
      break;
    case 1: // circle
      if (open) {
        cairo_set_line_width(cr, size * 0.055);
        cairo_arc(cr, cx, cy, size * 0.22 / 2 - size * 0.055 / 2, 0, 2 * M_PI);
        cairo_stroke(cr);
      } else {
        cairo_arc(cr, cx, cy, size * 0.22 / 2, 0, 2 * M_PI);
        cairo_fill(cr);
      }
      break;
    case 2: { // double circle
      double ring = open ? size * 0.025 : size * 0.075;
      cairo_set_line_width(cr, ring);
      cairo_arc(cr, cx, cy, size * 0.45 / 2 - ring / 2, 0, 2 * M_PI);
      if (open) cairo_stroke(cr); else cairo_fill(cr);
      cairo_new_path(cr);
      if (open) {
        cairo_set_line_width(cr, size * 0.025);
        cairo_arc(cr, cx, cy, size * 0.2 / 2 - size * 0.025 / 2, 0, 2 * M_PI);
        cairo_stroke(cr);
      } else {
        cairo_arc(cr, cx, cy, size * 0.2 / 2, 0, 2 * M_PI);
        cairo_fill(cr);
      }
      break;
    }
    case 3: { // triangle, pointing away from the text
      double w = size * 0.225, h = size * 0.2;
      cairo_move_to(cr, cx, cy - h);
      cairo_line_to(cr, cx - w, cy + h / 2);
      cairo_line_to(cr, cx + w, cy + h / 2);
      cairo_close_path(cr);
      if (open) {
        cairo_set_line_width(cr, size * 0.03);
        cairo_stroke(cr);
      } else {
        cairo_fill(cr);
      }
      break;
    }
    default: { // sesame: a dot drawn aslant
      cairo_save(cr);
      cairo_translate(cr, cx, cy);
      cairo_rotate(cr, -M_PI / 4);
      cairo_scale(cr, 1, size * 0.2 / (size * 0.35));
      if (open) {
        cairo_set_line_width(cr, size * 0.03);
        cairo_arc(cr, 0, 0, size * 0.175 - size * 0.015, 0, 2 * M_PI);
        cairo_stroke(cr);
      } else {
        cairo_arc(cr, 0, 0, size * 0.175, 0, 2 * M_PI);
        cairo_fill(cr);
      }
      cairo_restore(cr);
      break;
    }
  }
}

// ---------------------------------------------------------------------------
// Clipboard
//
// This host has no window, so no X11 or Wayland selection it could own: the clipboard is a file
// per format under the user's runtime directory, so an app on the same machine pastes what
// another copied. NATIVE_PASTEBOARD names the text file instead, which is how tests keep their
// clipboard out of the user's. text/plain is that file, and text/html the one beside it with
// ".html" appended; there is no file inside a drag here, since nothing outside the app can
// drop one.

static char g_clip_text[4096];
static int g_clip_looked = 0;

/** The text file the clipboard lives in, or NULL when even that can't be named. */
static const char *clipboard_text_path(void) {
  if (!g_clip_looked) {
    g_clip_looked = 1;
    const char *named = getenv("NATIVE_PASTEBOARD");
    if (named != NULL && named[0] != '\0') {
      snprintf(g_clip_text, sizeof(g_clip_text), "%s", named);
    } else {
      const char *dir = getenv("XDG_RUNTIME_DIR");
      if (dir == NULL || dir[0] == '\0') dir = "/tmp";
      snprintf(g_clip_text, sizeof(g_clip_text), "%s/native-pasteboard-%ld.txt", dir, (long)getuid());
    }
  }
  return g_clip_text[0] != '\0' ? g_clip_text : NULL;
}

/** The file one format lives in: `path`, or `path` with ".html" for the markup. */
static const char *clipboard_path_for(const char *format, size_t n, char *out, size_t out_len) {
  const char *path = clipboard_text_path();
  if (path == NULL) return NULL;
  if (n == 9 && memcmp(format, "text/html", 9) == 0) {
    if (snprintf(out, out_len, "%s.html", path) >= (int)out_len) return NULL;
  } else {
    if (snprintf(out, out_len, "%s", path) >= (int)out_len) return NULL;
  }
  return out;
}

/** Reads a whole file by its name. NULL when it can't be read, or is empty. */
static uint8_t *read_named(const char *name, size_t *out_len) {
  FILE *f = fopen(name, "rb");
  if (f == NULL) return NULL;
  if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
  long size = ftell(f);
  if (size <= 0) { fclose(f); return NULL; }
  rewind(f);
  uint8_t *buf = (uint8_t *)malloc((size_t)size);
  if (buf == NULL) { fclose(f); return NULL; }
  if (fread(buf, 1, (size_t)size, f) != (size_t)size) { free(buf); fclose(f); return NULL; }
  fclose(f);
  *out_len = (size_t)size;
  return buf;
}

static void write_named(const char *name, const uint8_t *data, size_t len) {
  FILE *f = fopen(name, "wb");
  if (f == NULL) return;
  fwrite(data, 1, len, f);
  fclose(f);
}

/** Replaces the clipboard: the text, and the markup when there is any. */
static void clipboard_store(const uint8_t *text, size_t text_len, const uint8_t *html, size_t html_len) {
  char path[4200];
  if (clipboard_path_for("text/plain", 10, path, sizeof(path)) != NULL) write_named(path, text, text_len);
  if (clipboard_path_for("text/html", 9, path, sizeof(path)) == NULL) return;
  if (html_len > 0) write_named(path, html, html_len);
  else remove(path);
}

// A copy replaces the clipboard's contents, as putting a string on the pasteboard does.
void host_clipboard_write(const uint8_t *text, size_t text_len, const uint8_t *html, size_t html_len) {
  clipboard_store(text, text_len, html, html_len);
}

void host_clipboard_read(const uint8_t *format, size_t n, str_cb cb) {
  char path[4200];
  if (clipboard_path_for((const char *)format, n, path, sizeof(path)) == NULL) { cb((const uint8_t *)"", 0); return; }
  size_t len = 0;
  uint8_t *data = read_named(path, &len);
  if (data == NULL) { cb((const uint8_t *)"", 0); return; }
  cb(data, len);
  free(data);
}

int32_t host_drop_file_count(void) { return 0; }
void host_drop_file_name(int32_t index, str_cb cb) { (void)index; cb((const uint8_t *)"", 0); }
void host_drop_file_path(int32_t index, str_cb cb) { (void)index; cb((const uint8_t *)"", 0); }

void host_set_cursor_image(int32_t id, double x, double y) { (void)id; (void)x; (void)y; }
// The app's own files: fetch() resolves a page-relative URL against the build-time page directory
// and reads the bytes through these (the same shape as host/macos.m).

typedef void (*bytes_cb)(const uint8_t *, size_t);

int32_t host_file_size(const uint8_t *path, size_t n) {
  char name[4096];
  if (n >= sizeof(name)) return -1;
  memcpy(name, path, n);
  name[n] = '\0';
  struct stat st;
  if (stat(name, &st) != 0 || !S_ISREG(st.st_mode)) return -1;
  return st.st_size > 0x7fffffffLL ? -1 : (int32_t)st.st_size;
}

// ---------------------------------------------------------------------------
// SQLite
//
// The store IndexedDB keeps its records in. A database and each prepared statement are an opaque
// id the runtime holds; ids are 1-based and 0 means none. Statements are cached by the runtime,
// so the table is the only limit on how many are open.

#define SQLITE_MAX_DB 8
#define SQLITE_MAX_STMT 512

static sqlite3 *g_sqlite_db[SQLITE_MAX_DB];
static sqlite3_stmt *g_sqlite_stmt[SQLITE_MAX_STMT];

static sqlite3 *sqlite_db_at(int32_t id) {
  return id > 0 && id <= SQLITE_MAX_DB ? g_sqlite_db[id - 1] : NULL;
}

static sqlite3_stmt *sqlite_stmt_at(int32_t id) {
  return id > 0 && id <= SQLITE_MAX_STMT ? g_sqlite_stmt[id - 1] : NULL;
}

static char *sqlite_copy(const uint8_t *s, size_t n) {
  char *p = (char *)malloc(n + 1);
  if (p == NULL) return NULL;
  if (n > 0) memcpy(p, s, n);
  p[n] = '\0';
  return p;
}

int32_t host_sqlite_open(const uint8_t *path, size_t n) {
  char *p = sqlite_copy(path, n);
  if (p == NULL) return 0;
  int32_t id = 0;
  for (int i = 0; i < SQLITE_MAX_DB; i++) {
    if (g_sqlite_db[i] != NULL) continue;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(p, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
      if (db != NULL) sqlite3_close(db);
      break;
    }
    sqlite3_busy_timeout(db, 2000);
    g_sqlite_db[i] = db;
    id = i + 1;
    break;
  }
  free(p);
  return id;
}

void host_sqlite_close(int32_t id) {
  sqlite3 *db = sqlite_db_at(id);
  if (db == NULL) return;
  sqlite3_close_v2(db);
  g_sqlite_db[id - 1] = NULL;
}

int32_t host_sqlite_exec(int32_t id, const uint8_t *sql, size_t n) {
  sqlite3 *db = sqlite_db_at(id);
  if (db == NULL) return SQLITE_MISUSE;
  char *q = sqlite_copy(sql, n);
  if (q == NULL) return SQLITE_NOMEM;
  int rc = sqlite3_exec(db, q, NULL, NULL, NULL);
  free(q);
  return rc;
}

int32_t host_sqlite_prepare(int32_t id, const uint8_t *sql, size_t n) {
  sqlite3 *db = sqlite_db_at(id);
  if (db == NULL) return 0;
  char *q = sqlite_copy(sql, n);
  if (q == NULL) return 0;
  int32_t found = 0;
  for (int i = 0; i < SQLITE_MAX_STMT; i++) {
    if (g_sqlite_stmt[i] != NULL) continue;
    sqlite3_stmt *st = NULL;
    if (sqlite3_prepare_v2(db, q, -1, &st, NULL) != SQLITE_OK) break;
    g_sqlite_stmt[i] = st;
    found = i + 1;
    break;
  }
  free(q);
  return found;
}

int32_t host_sqlite_finalize(int32_t id) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  if (st == NULL) return SQLITE_MISUSE;
  int rc = sqlite3_finalize(st);
  g_sqlite_stmt[id - 1] = NULL;
  return rc;
}

int32_t host_sqlite_reset(int32_t id) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? SQLITE_MISUSE : sqlite3_reset(st);
}

int32_t host_sqlite_clear_bindings(int32_t id) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? SQLITE_MISUSE : sqlite3_clear_bindings(st);
}

int32_t host_sqlite_bind_text(int32_t id, int32_t index, const uint8_t *value, size_t n) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  if (st == NULL) return SQLITE_MISUSE;
  return sqlite3_bind_text(st, index, (const char *)value, (int)n, SQLITE_TRANSIENT);
}

int32_t host_sqlite_bind_double(int32_t id, int32_t index, double value) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? SQLITE_MISUSE : sqlite3_bind_double(st, index, value);
}

int32_t host_sqlite_bind_int(int32_t id, int32_t index, double value) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? SQLITE_MISUSE : sqlite3_bind_int64(st, index, (sqlite3_int64)value);
}

int32_t host_sqlite_bind_null(int32_t id, int32_t index) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? SQLITE_MISUSE : sqlite3_bind_null(st, index);
}

int32_t host_sqlite_bind_blob(int32_t id, int32_t index, const uint8_t *value, size_t n) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  if (st == NULL) return SQLITE_MISUSE;
  return sqlite3_bind_blob(st, index, value, (int)n, SQLITE_TRANSIENT);
}

int32_t host_sqlite_step(int32_t id) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? SQLITE_MISUSE : sqlite3_step(st);
}

int32_t host_sqlite_column_count(int32_t id) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? 0 : sqlite3_column_count(st);
}

int32_t host_sqlite_column_type(int32_t id, int32_t col) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? SQLITE_NULL : sqlite3_column_type(st, col);
}

void host_sqlite_column_text(int32_t id, int32_t col, window_text_cb cb) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  if (st == NULL) { cb((const uint8_t *)"", 0); return; }
  const unsigned char *text = sqlite3_column_text(st, col);
  int n = sqlite3_column_bytes(st, col);
  cb(text == NULL ? (const uint8_t *)"" : text, text == NULL ? 0 : (size_t)n);
}

void host_sqlite_column_blob(int32_t id, int32_t col, bytes_cb cb) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  if (st == NULL) { cb(NULL, 0); return; }
  const void *blob = sqlite3_column_blob(st, col);
  int n = sqlite3_column_bytes(st, col);
  cb(blob == NULL ? NULL : (const uint8_t *)blob, blob == NULL ? 0 : (size_t)n);
}

double host_sqlite_column_double(int32_t id, int32_t col) {
  sqlite3_stmt *st = sqlite_stmt_at(id);
  return st == NULL ? 0 : sqlite3_column_double(st, col);
}

double host_sqlite_changes(int32_t id) {
  sqlite3 *db = sqlite_db_at(id);
  return db == NULL ? 0 : (double)sqlite3_changes(db);
}

double host_sqlite_last_id(int32_t id) {
  sqlite3 *db = sqlite_db_at(id);
  return db == NULL ? 0 : (double)sqlite3_last_insert_rowid(db);
}

void host_sqlite_errmsg(int32_t id, window_text_cb cb) {
  sqlite3 *db = sqlite_db_at(id);
  const char *msg = db == NULL ? "no database" : sqlite3_errmsg(db);
  cb((const uint8_t *)msg, strlen(msg));
}

void host_file_read(const uint8_t *path, size_t n, bytes_cb cb) {
  size_t len = 0;
  uint8_t *data = read_file(path, n, &len);
  if (!data) { cb(NULL, 0); return; }
  cb(data, len);
  free(data);
}

// A bundled app's files live in `<executable>.resources` beside the executable when a build made
// one, and otherwise in the executable's own directory. The executable is found through
// /proc/self/exe, so a relative or symlinked path to it makes no difference.
typedef void (*dir_cb)(const uint8_t *, size_t);

void host_bundle_dir(dir_cb cb) {
  char exe[4096];
  ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
  if (n <= 0) return;
  exe[n] = '\0';
  char *slash = strrchr(exe, '/');
  if (slash == NULL) return;
  *slash = '\0';
  const char *name = slash + 1;
  char candidate[8192];
  struct stat st;
  snprintf(candidate, sizeof(candidate), "%s/%s.resources", exe, name);
  const char *dir = (stat(candidate, &st) == 0 && S_ISDIR(st.st_mode)) ? candidate : exe;
  cb((const uint8_t *)dir, strlen(dir));
}

double host_backing_scale(void) { return 1; }

int32_t host_reduced_motion(void) {
  const char *env = getenv("NATIVE_REDUCED_MOTION");
  return env && *env ? (strcmp(env, "0") != 0 ? 1 : 0) : 0;
}


// ---------------------------------------------------------------------------
// The display list
//
// A frame is recorded as a list of commands and painted when it is presented, which is what lets
// a headless run paint a frame nobody sees. The painting is done with Cairo: an image surface
// holds the device pixels, the user space is the display list's own (top-left origin, y down),
// so the only transform between them is the backing scale.

enum {
  CMD_FILL = 0, CMD_TEXT, CMD_CLIP, CMD_UNCLIP, CMD_RING, CMD_IMAGE,
  CMD_FILL_ROUND, CMD_RING_ROUND, CMD_CLIP_ROUND,
  CMD_GRADIENT_LINEAR, CMD_GRADIENT_RADIAL, CMD_CANVAS,
  CMD_SHADOW, CMD_SHADOW_INSET, CMD_TEXT_SHADOW, CMD_TRANSFORM,
  CMD_GRADIENT_CONIC, CMD_POLY, CMD_CLIP_POLY, CMD_LINE,
  CMD_EFFECT_PUSH, CMD_EFFECT_POP, CMD_CLIP_ELLIPSE, CMD_CLIP_SHAPE,
  CMD_MASK_PUSH, CMD_MASK_SPLIT, CMD_MASK_POP,
  CMD_PERSPECTIVE_PUSH, CMD_PERSPECTIVE_POP,
  CMD_LAYER_REF,
  CMD_VIDEO,
};

/** The property kind a scroll container's push carries (shared/props.ts's PK_SCROLL). */
#define CMD_PK_SCROLL 8


typedef struct {
  int kind;
  // The property-tree node a push opens: the element it belongs to, and its PK_* kind. Drawing
  // commands leave both zero. The replay ignores them; the layerizer reads them.
  int32_t serial;
  int32_t pkind;
  // The layer a CMD_LAYER_REF draws.
  int32_t layer;
  // A number unique within the frame, which the runtime keeps to edit this command in place.
  int32_t handle;
  int32_t image;
  double x, y, w, h, radius, line_width, line_height, size, weight;
  double sx, sy, sw, sh;
  double r[8];
  double q[8];
  double p0, p1, p2, p3;
  double dx, dy, blur, letter, word;
  int smooth;
  // An alpha a later frame may set on a composited opacity group without re-recording its spec.
  int alpha_override;
  double alpha;
  uint32_t color, shadow_color, emphasis, emphasis_color;
  char *text;
  size_t len;
} Cmd;

typedef struct {
  Cmd *cmds;
  size_t count, cap;
} CmdList;

// A layer's commands beside the top-level list. The layer's sublist is complete when its pop
// arrives, and the parent list keeps a CMD_LAYER_REF where the layer's box painted.
typedef struct {
  int32_t serial, kind;
  CmdList list;
} LayerEntry;

#define MAX_LAYERS 4096
#define MAX_LAYER_DEPTH 64

static CmdList g_root = { NULL, 0, 0 };
static LayerEntry g_layers[MAX_LAYERS];
static int g_layer_count = 0;
static CmdList *g_list = &g_root;
static CmdList *g_parents[MAX_LAYER_DEPTH];
static int32_t g_open_serial[MAX_LAYER_DEPTH];
static int32_t g_open_kind[MAX_LAYER_DEPTH];
static int32_t g_open_layer[MAX_LAYER_DEPTH];
static int g_open_depth = 0;
/** How deep the pushes skipped for want of a layer are: everything inside them paints flat. */
static int g_skip_depth = 0;
/** The list the commands go to now: -1 for the root, else the layer id. */
static int32_t g_cur_list_id = -1;
/** How many commands one list may hold; a handle packs the list id and the index. */
#define CMD_HANDLE_STRIDE 262144
static uint32_t g_background = 0xffffffff;
static int g_needs_backdrop = 0;
/** A throwaway raster (the damage verification's reference). It keeps what it filters (it is a
 *  full frame, the source a kept backdrop wants) but never reuses a kept one: it is the reference
 *  the frame drawn next is compared with. */
static int g_reference_paint = 0;
/** A damaged frame supplies its own background fills, clipped to the regions it repaints. */
static int g_skip_background = 0;
/** A compositor frame presents an already-recorded list but repaints only its moving layers. */
static int g_present_region = 0;
static int32_t g_damage_count = 0;
static double g_damage_rects[16][4];
static double g_scale = 1;
/** The index a replay stops at, for replaying a span of a list; SIZE_MAX replays to its end. */
static size_t g_replay_limit = (size_t)-1;

// Filter function kinds, numbered as shared/props.ts numbers them (FK_*).
enum {
  FK_BLUR = 0, FK_BRIGHTNESS = 1, FK_CONTRAST = 2, FK_DROP_SHADOW = 3, FK_GRAYSCALE = 4,
  FK_HUE_ROTATE = 5, FK_INVERT = 6, FK_OPACITY = 7, FK_SATURATE = 8, FK_SEPIA = 9,
};

typedef struct {
  int kind;
  double a, dx, dy, blur;
  uint32_t color;
} FilterOp;

/** One layer's blend mode, filter chain and backdrop chain, as the runtime writes them into the
 *  command. A backdrop chain filters what is painted behind the box, inside its border box. */
typedef struct {
  // The layer's own alpha, which multiplies its contents once when it composites.
  double alpha;
  int blend;
  int count;
  FilterOp ops[64];
  int bcount;
  FilterOp bops[64];
} EffectSpec;

static void effect_spec_parse(EffectSpec *s, const char *text);

static Cmd *push_cmd(void) {
  CmdList *l = g_list;
  if (l->count == l->cap) {
    l->cap = l->cap ? l->cap * 2 : 256;
    l->cmds = (Cmd *)realloc(l->cmds, l->cap * sizeof(Cmd));
  }
  size_t at = l->count++;
  Cmd *c = &l->cmds[at];
  memset(c, 0, sizeof(Cmd));
  c->handle = (g_cur_list_id + 1) * CMD_HANDLE_STRIDE + (int32_t)at;
  return c;
}

/** Frees the text a list's commands hold and empties the list. */
static void clear_list(CmdList *l) {
  for (size_t i = 0; i < l->count; i++) free(l->cmds[i].text);
  l->count = 0;
}

/** Starts a frame: every list is emptied and the page background set. */
void host_begin(uint32_t background) {
  clear_list(&g_root);
  for (int i = 0; i < g_layer_count; i++) clear_list(&g_layers[i].list);
  g_layer_count = 0;
  g_open_depth = 0;
  g_skip_depth = 0;
  g_cur_list_id = -1;
  g_list = &g_root;
  g_background = background;
  g_needs_backdrop = 0;
  g_skip_background = 0;
  g_damage_count = 0;
}

/** Reads "x,y,w,h;x,y,w,h" into the frame's damage rectangles. */
static void parse_damage_rects(const uint8_t *s, size_t n) {
  g_damage_count = 0;
  char *buf = (char *)malloc(n + 1);
  if (buf == NULL) return;
  memcpy(buf, s, n);
  buf[n] = 0;
  const char *p = buf;
  while (*p != 0 && g_damage_count < 16) {
    char *end = NULL;
    double v[4];
    int i = 0;
    for (; i < 4; i++) {
      v[i] = strtod(p, &end);
      if (end == p) break;
      p = end;
      while (*p == ',' || *p == ' ') p++;
    }
    if (i < 4) break;
    for (int k = 0; k < 4; k++) g_damage_rects[g_damage_count][k] = v[k];
    g_damage_count++;
    while (*p == ';' || *p == ' ') p++;
  }
  free(buf);
}

void host_damage_begin(uint32_t background, const uint8_t *rects, size_t n) {
  host_begin(background);
  parse_damage_rects(rects, n);
  g_skip_background = 1;
}


static void verify_capture_full(double width, double height);
static int verify_enabled(void);

/** The headless host has no window: presenting only keeps the verification's previous frame. */
void host_present(double width, double height) {
  if (verify_enabled()) verify_capture_full(width, height);
}

/** The headless host has no compositor, so damage-limited frames reach it as flat lists. */
int32_t host_compositor_on(void) { return 0; }

/** The headless host has no retained window: a composite frame's display list is only replayed
 *  into a snapshot, which replays the whole list anyway. */
void host_present_region(const uint8_t *rects, size_t n, double width, double height) {
  (void)rects;
  (void)n;
  (void)width;
  (void)height;
}

/** The headless host has no window: the damaged list is only ever replayed into a snapshot. */
void host_present_damage(const uint8_t *rects, size_t n, double width, double height) {
  (void)rects;
  (void)n;
  (void)width;
  (void)height;
}

/** The number of layers the last frame recorded. */
int32_t host_layer_count(void) { return g_layer_count; }

/**
 * Opens a layer: from here to the matching host_layer_pop the commands are the element's own
 * content, a sublist of its own so the compositor can raster it once. The parent list keeps a
 * CMD_LAYER_REF where the box painted, and replaying the ref draws the sublist where it stands,
 * so the flat output is unchanged.
 */
void host_layer_push(int32_t serial, int32_t kind) {
  // Past the depth or layer budget a box paints flat: the pushes inside it skip too, so the
  // nesting stays balanced and the frame is exactly the flat list.
  if (g_skip_depth > 0) {
    g_skip_depth++;
    return;
  }
  if (g_open_depth >= MAX_LAYER_DEPTH || g_layer_count >= MAX_LAYERS) {
    g_skip_depth = 1;
    return;
  }
  int id = g_layer_count++;
  g_layers[id].serial = serial;
  g_layers[id].kind = kind;
  g_layers[id].list.count = 0;
  g_parents[g_open_depth] = g_list;
  g_open_serial[g_open_depth] = serial;
  g_open_kind[g_open_depth] = kind;
  g_open_layer[g_open_depth] = id;
  g_open_depth++;
  g_cur_list_id = id;
  g_list = &g_layers[id].list;
}

void host_layer_pop(void) {
  if (g_skip_depth > 0) {
    g_skip_depth--;
    return;
  }
  if (g_open_depth == 0) return;
  g_open_depth--;
  g_list = g_parents[g_open_depth];
  g_cur_list_id = g_open_depth == 0 ? -1 : g_open_layer[g_open_depth - 1];
  Cmd *c = push_cmd();
  c->kind = CMD_LAYER_REF;
  c->layer = g_open_layer[g_open_depth];
  c->serial = g_open_serial[g_open_depth];
  c->pkind = g_open_kind[g_open_depth];
}

static void copy_text(Cmd *c, const uint8_t *s, size_t n) {
  c->text = (char *)malloc(n + 1);
  memcpy(c->text, s, n);
  c->text[n] = 0;
  c->len = n;
}

void host_clip_push(int32_t serial, int32_t pkind, double x, double y, double w, double h, double radius) {
  Cmd *c = push_cmd();
  c->kind = CMD_CLIP;
  c->serial = serial; c->pkind = pkind;
  c->x = x; c->y = y; c->w = w; c->h = h; c->radius = radius;
}

void host_clip_pop(void) { push_cmd()->kind = CMD_UNCLIP; }

// Restores the state a transform pushed, the same way a clip's pop does.
void host_state_pop(void) { push_cmd()->kind = CMD_UNCLIP; }

// Multiplies the user space of everything drawn until the matching pop by a matrix, for a CSS
// transform: the command saves the state the way a clip does.
static Cmd *push_transform(int32_t serial, int32_t pkind, double a, double b, double c, double d, double e, double f) {
  Cmd *cmd = push_cmd();
  cmd->kind = CMD_TRANSFORM;
  cmd->serial = serial; cmd->pkind = pkind;
  cmd->p0 = a; cmd->p1 = b; cmd->p2 = c; cmd->p3 = d;
  cmd->r[0] = e;
  cmd->r[1] = f;
  return cmd;
}

void host_transform_push(int32_t serial, int32_t pkind, double a, double b, double c, double d, double e, double f) {
  push_transform(serial, pkind, a, b, c, d, e, f);
}

/** The same, reporting the command's handle so a later frame can move its matrix in place. */
int32_t host_transform_push_indexed(int32_t serial, int32_t pkind,
                                    double a, double b, double c, double d, double e, double f) {
  return push_transform(serial, pkind, a, b, c, d, e, f)->handle;
}

void host_fill_rect(double x, double y, double w, double h, double radius, uint32_t color) {
  Cmd *c = push_cmd();
  c->kind = CMD_FILL;
  c->x = x; c->y = y; c->w = w; c->h = h; c->radius = radius; c->color = color;
}

// A text-decoration line from x0 to x1, `thickness` tall, whose top edge is `y`. `style` is a
// TDS_* value: solid, double, dotted, dashed or wavy.
void host_fill_line(double x0, double x1, double y, double thickness, uint32_t color, double style) {
  Cmd *c = push_cmd();
  c->kind = CMD_LINE;
  c->x = x0; c->w = x1 - x0; c->y = y;
  c->line_width = thickness; c->color = color; c->radius = style;
}

void host_fill_ring(double x, double y, double w, double h, double radius, double line_width, uint32_t color) {
  Cmd *c = push_cmd();
  c->kind = CMD_RING;
  c->x = x; c->y = y; c->w = w; c->h = h; c->radius = radius; c->line_width = line_width; c->color = color;
}

// A filled polygon (or several, as one path): "x,y x,y x,y" points, subpaths separated by ';'.
void host_fill_poly(const uint8_t *s, size_t n, uint32_t color) {
  Cmd *c = push_cmd();
  c->kind = CMD_POLY;
  c->color = color;
  copy_text(c, s, n);
}

void host_clip_push_poly(int32_t serial, int32_t pkind, const uint8_t *s, size_t n) {
  Cmd *c = push_cmd();
  c->kind = CMD_CLIP_POLY;
  c->serial = serial; c->pkind = pkind;
  copy_text(c, s, n);
}

void host_clip_push_ellipse(int32_t serial, int32_t pkind, double cx, double cy, double rx, double ry) {
  Cmd *c = push_cmd();
  c->kind = CMD_CLIP_ELLIPSE;
  c->serial = serial; c->pkind = pkind;
  c->p0 = cx; c->p1 = cy; c->p2 = rx; c->p3 = ry;
}

// Clips to one or more closed subpaths filled with the even-odd rule when `evenodd` is set.
void host_clip_push_shape(int32_t serial, int32_t pkind, const uint8_t *s, size_t n, double evenodd) {
  Cmd *c = push_cmd();
  c->kind = CMD_CLIP_SHAPE;
  c->serial = serial; c->pkind = pkind;
  c->p0 = evenodd;
  copy_text(c, s, n);
}

// The per-corner-radius versions: eight radii, top-left to bottom-left, horizontal then vertical.
static void set_radii(Cmd *c, double tlx, double tly, double trx, double try_, double brx, double bry, double blx, double bly) {
  c->r[0] = tlx; c->r[1] = tly; c->r[2] = trx; c->r[3] = try_;
  c->r[4] = brx; c->r[5] = bry; c->r[6] = blx; c->r[7] = bly;
}

void host_fill_round_rect(double x, double y, double w, double h,
                          double tlx, double tly, double trx, double try_, double brx, double bry, double blx, double bly,
                          uint32_t color) {
  Cmd *c = push_cmd();
  c->kind = CMD_FILL_ROUND;
  c->x = x; c->y = y; c->w = w; c->h = h; c->color = color;
  set_radii(c, tlx, tly, trx, try_, brx, bry, blx, bly);
}

void host_fill_round_ring(double x, double y, double w, double h,
                          double tlx, double tly, double trx, double try_, double brx, double bry, double blx, double bly,
                          double line_width, uint32_t color) {
  Cmd *c = push_cmd();
  c->kind = CMD_RING_ROUND;
  c->x = x; c->y = y; c->w = w; c->h = h; c->line_width = line_width; c->color = color;
  set_radii(c, tlx, tly, trx, try_, brx, bry, blx, bly);
}

void host_clip_push_round(int32_t serial, int32_t pkind, double x, double y, double w, double h,
                          double tlx, double tly, double trx, double try_, double brx, double bry, double blx, double bly) {
  Cmd *c = push_cmd();
  c->kind = CMD_CLIP_ROUND;
  c->serial = serial; c->pkind = pkind;
  c->x = x; c->y = y; c->w = w; c->h = h;
  set_radii(c, tlx, tly, trx, try_, brx, bry, blx, bly);
}

// An outer box-shadow behind the box: the border box grown by `spread`, cast with `blur`, and
// clipped away inside the border box as CSS says.
void host_shadow_outer(double x, double y, double w, double h,
                       double tlx, double tly, double trx, double try_, double brx, double bry, double blx, double bly,
                       double dx, double dy, double blur, double spread, uint32_t color) {
  Cmd *c = push_cmd();
  c->kind = CMD_SHADOW;
  c->x = x; c->y = y; c->w = w; c->h = h;
  c->dx = dx; c->dy = dy; c->blur = blur; c->line_width = spread; c->color = color;
  set_radii(c, tlx, tly, trx, try_, brx, bry, blx, bly);
}

// An inset box-shadow inside the border box: the shadow of everything outside the box shrunk by
// `spread` and moved by the offset, clipped to the box.
void host_shadow_inset(double x, double y, double w, double h,
                       double tlx, double tly, double trx, double try_, double brx, double bry, double blx, double bly,
                       double dx, double dy, double blur, double spread, uint32_t color) {
  Cmd *c = push_cmd();
  c->kind = CMD_SHADOW_INSET;
  c->x = x; c->y = y; c->w = w; c->h = h;
  c->dx = dx; c->dy = dy; c->blur = blur; c->line_width = spread; c->color = color;
  set_radii(c, tlx, tly, trx, try_, brx, bry, blx, bly);
}

void host_image_draw(int32_t id, double x, double y, double w, double h, double alpha, double smooth) {
  if (id < 0) return;
  Cmd *c = push_cmd();
  c->kind = CMD_IMAGE;
  c->image = id;
  c->x = x; c->y = y; c->w = w; c->h = h;
  c->size = alpha;
  c->smooth = smooth > 0.5;
}

void host_image_draw_part(int32_t id, double x, double y, double w, double h,
                          double sx, double sy, double sw, double sh, double alpha, double smooth) {
  if (id < 0) return;
  Cmd *c = push_cmd();
  c->kind = CMD_IMAGE;
  c->image = id;
  c->x = x; c->y = y; c->w = w; c->h = h;
  c->size = alpha;
  c->smooth = smooth > 0.5;
  c->sx = sx; c->sy = sy; c->sw = sw; c->sh = sh;
}

#ifndef NATIVE_NO_FFMPEG
// ---------------------------------------------------------------------------
// Video
//
// A <video> is decoded by the FFmpeg build in host/ffmpeg: libavformat demuxes the file and
// libavcodec decodes its video stream, and the frame at the player's current time is converted to
// BGRA and drawn into the element's box when the page paints. There is no audio path yet: the
// picture plays silently and the element's volume and mute do nothing.

#define VIDEO_MAX 8

typedef struct {
  AVFormatContext *fmt;
  AVCodecContext *dec;
  struct SwsContext *sws;
  int stream;
  int w, h;
  double duration;
  /** The clock: the media time at an anchor, and the monotonic time it was anchored at. */
  double base;
  double anchored;
  int playing;
  double rate;
  /** The frame drawn last, converted to BGRA. */
  uint8_t *rgba;
  int have_frame;
  double frame_time;
  /** A decoded frame whose time is past the playhead, kept for the next paint. */
  AVFrame *pending;
  int eof;
  /** The frame geometry the scaler was made for; a frame that differs needs a new one. */
  int sws_w, sws_h, sws_fmt;
} Video;

static Video *g_videos[VIDEO_MAX];

static double mono_seconds(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static Video *video_at(int32_t id) {
  return id > 0 && id <= VIDEO_MAX ? g_videos[id - 1] : NULL;
}

static double video_clock(Video *v) {
  return v->playing ? v->base + (mono_seconds() - v->anchored) * v->rate : v->base;
}

static void video_anchor(Video *v) {
  v->base = video_clock(v);
  v->anchored = mono_seconds();
}

int32_t host_video_open(const uint8_t *path, size_t n) {
  if (!ff_load()) return -1;
  char name[4096];
  if (n >= sizeof(name)) return -1;
  memcpy(name, path, n);
  name[n] = '\0';
  AVFormatContext *fmt = NULL;
  if (ff.open_input(&fmt, name, NULL, NULL) < 0) return -1;
  if (ff.find_stream_info(fmt, NULL) < 0) {
    ff.close_input(&fmt);
    return -1;
  }
  int stream = ff.find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
  if (stream < 0) {
    ff.close_input(&fmt);
    return -1;
  }
  AVCodecParameters *par = fmt->streams[stream]->codecpar;
  const AVCodec *codec = ff.find_decoder(par->codec_id);
  if (codec == NULL) {
    ff.close_input(&fmt);
    return -1;
  }
  AVCodecContext *dec = ff.alloc_context3(codec);
  if (dec == NULL || ff.parameters_to_context(dec, par) < 0 || ff.open2(dec, codec, NULL) < 0) {
    ff.free_context(&dec);
    ff.close_input(&fmt);
    return -1;
  }
  Video *v = (Video *)calloc(1, sizeof(Video));
  if (v == NULL) {
    ff.free_context(&dec);
    ff.close_input(&fmt);
    return -1;
  }
  v->w = dec->width > 0 ? dec->width : par->width;
  v->h = dec->height > 0 ? dec->height : par->height;
  if (v->w <= 0 || v->h <= 0) {
    free(v);
    ff.free_context(&dec);
    ff.close_input(&fmt);
    return -1;
  }
  // The scaler reads frames of one geometry and writes the element's output size. Some streams
  // change the frame size partway through, so a scaler that doesn't match the frame is remade in
  // video_advance; the first one is only made here when the header already names the format.
  if (dec->pix_fmt != AV_PIX_FMT_NONE) {
    v->sws = ff.sws_get(v->w, v->h, dec->pix_fmt, v->w, v->h, AV_PIX_FMT_BGRA, SWS_BILINEAR, NULL, NULL, NULL);
    v->sws_w = v->w;
    v->sws_h = v->h;
    v->sws_fmt = dec->pix_fmt;
  }
  v->rgba = (uint8_t *)malloc((size_t)v->w * (size_t)v->h * 4);
  if ((dec->pix_fmt != AV_PIX_FMT_NONE && v->sws == NULL) || v->rgba == NULL) {
    if (v->sws) ff.sws_free(v->sws);
    free(v->rgba);
    free(v);
    ff.free_context(&dec);
    ff.close_input(&fmt);
    return -1;
  }
  v->fmt = fmt;
  v->dec = dec;
  v->stream = stream;
  v->duration = fmt->duration > 0 ? (double)fmt->duration / (double)AV_TIME_BASE : 0;
  v->rate = 1;
  v->anchored = mono_seconds();
  for (int i = 0; i < VIDEO_MAX; i++) {
    if (g_videos[i] == NULL) {
      g_videos[i] = v;
      return i + 1;
    }
  }
  ff.sws_free(v->sws);
  free(v->rgba);
  free(v);
  ff.free_context(&dec);
  ff.close_input(&fmt);
  return -1;
}

void host_video_close(int32_t id) {
  Video *v = video_at(id);
  if (v == NULL) return;
  g_videos[id - 1] = NULL;
  ff.sws_free(v->sws);
  ff.frame_free(&v->pending);
  free(v->rgba);
  ff.free_context(&v->dec);
  ff.close_input(&v->fmt);
  free(v);
}

void host_video_play(int32_t id) {
  Video *v = video_at(id);
  if (v == NULL || v->playing) return;
  video_anchor(v);
  v->playing = 1;
}

void host_video_pause(int32_t id) {
  Video *v = video_at(id);
  if (v == NULL || !v->playing) return;
  video_anchor(v);
  v->playing = 0;
}

/** Seeks the decode to `time`, in seconds. */
static void video_seek_to(Video *v, double time) {
  AVStream *st = v->fmt->streams[v->stream];
  int64_t ts = (int64_t)(time / av_q2d(st->time_base));
  ff.seek_frame(v->fmt, v->stream, ts, AVSEEK_FLAG_BACKWARD);
  ff.flush_buffers(v->dec);
  // The frame decoded before the seek is at another time: the next paint decodes a new one.
  ff.frame_free(&v->pending);
  v->have_frame = 0;
  v->eof = 0;
}

void host_video_seek(int32_t id, double time) {
  Video *v = video_at(id);
  if (v == NULL) return;
  double target = time < 0 ? 0 : time;
  if (v->duration > 0 && target > v->duration) target = v->duration;
  video_seek_to(v, target);
  v->base = target;
  v->anchored = mono_seconds();
}

double host_video_time(int32_t id) {
  Video *v = video_at(id);
  if (v == NULL) return 0;
  double t = video_clock(v);
  if (t < 0) t = 0;
  if (v->duration > 0 && t > v->duration) t = v->duration;
  return t;
}

double host_video_duration(int32_t id) {
  Video *v = video_at(id);
  if (v == NULL) return -1;
  return v->duration > 0 ? v->duration : -1;
}

double host_video_width(int32_t id) {
  Video *v = video_at(id);
  return v == NULL ? 0 : v->w;
}

double host_video_height(int32_t id) {
  Video *v = video_at(id);
  return v == NULL ? 0 : v->h;
}

int32_t host_video_ready(int32_t id) {
  return video_at(id) == NULL ? -1 : 1;
}

void host_video_set_volume(int32_t id, double volume) { (void)id; (void)volume; }
void host_video_set_muted(int32_t id, int32_t muted) { (void)id; (void)muted; }

void host_video_set_rate(int32_t id, double rate) {
  Video *v = video_at(id);
  if (v == NULL) return;
  video_anchor(v);
  v->rate = rate > 0 ? rate : 1;
}

/** Decodes forward until the frame for `target` is the one converted into `v->rgba`. */
static void video_advance(Video *v, double target) {
  if (v->eof && v->pending == NULL) return;
  AVStream *st = v->fmt->streams[v->stream];
  double tb = av_q2d(st->time_base);
  AVPacket *packet = ff.packet_alloc();
  if (packet == NULL) return;
  for (int guard = 0; guard < 4096; guard++) {
    AVFrame *frame = v->pending;
    if (frame != NULL) {
      v->pending = NULL;
    } else {
      frame = ff.frame_alloc();
      if (frame == NULL) break;
      int ret = ff.receive_frame(v->dec, frame);
      if (ret != 0) {
        ff.frame_free(&frame);
        if (ret != AVERROR(EAGAIN)) {
          v->eof = 1;
          break;
        }
        if (ff.read_frame(v->fmt, packet) < 0) {
          v->eof = 1;
          break;
        }
        if (packet->stream_index != v->stream) {
          ff.packet_unref(packet);
          continue;
        }
        ff.send_packet(v->dec, packet);
        ff.packet_unref(packet);
        continue;
      }
    }
    double pts = frame->best_effort_timestamp >= 0 ? (double)frame->best_effort_timestamp * tb : -1;
    if (pts < 0) pts = v->have_frame ? v->frame_time : 0;
    // A frame past the playhead waits for the next paint: its own target may still be behind it,
    // and a paint that threw it away would lose every frame the decode ran ahead by.
    if (v->have_frame && pts > target) {
      v->pending = frame;
      break;
    }
    // The frame's own geometry decides how much may be read: a clip that changes resolution or
    // pixel format partway through hands over frames smaller than the stream's header says.
    int fw = frame->width > 0 ? frame->width : v->sws_w;
    int fh = frame->height > 0 ? frame->height : v->sws_h;
    int ffmt = frame->format;
    if (fw <= 0 || fh <= 0 || ffmt < 0 || frame->data[0] == NULL) {
      ff.frame_free(&frame);
      if (pts >= target) break;
      continue;
    }
    if (v->sws == NULL || fw != v->sws_w || fh != v->sws_h || ffmt != v->sws_fmt) {
      struct SwsContext *next = ff.sws_get(fw, fh, (enum AVPixelFormat)ffmt, v->w, v->h,
                                           AV_PIX_FMT_BGRA, SWS_BILINEAR, NULL, NULL, NULL);
      if (next == NULL) {
        // This frame can't be converted; showing the last one beats reading past this one's rows.
        ff.frame_free(&frame);
        if (pts >= target) break;
        continue;
      }
      if (v->sws != NULL) ff.sws_free(v->sws);
      v->sws = next;
      v->sws_w = fw;
      v->sws_h = fh;
      v->sws_fmt = ffmt;
    }
    uint8_t *dst[4] = { v->rgba, NULL, NULL, NULL };
    int dst_lines[4] = { v->w * 4, 0, 0, 0 };
    ff.sws_scale_now(v->sws, (const uint8_t * const *)frame->data, frame->linesize, 0, fh, dst, dst_lines);
    v->frame_time = pts;
    v->have_frame = 1;
    ff.frame_free(&frame);
    if (pts >= target) break;
  }
  ff.packet_free(&packet);
}

void host_video_draw(int32_t id, double x, double y, double w, double h, double alpha) {
  if (id < 0) return;
  Cmd *c = push_cmd();
  c->kind = CMD_VIDEO;
  c->image = id;
  c->x = x; c->y = y; c->w = w; c->h = h; c->size = alpha;
}

#else
int32_t host_video_open(const uint8_t *path, size_t n) { (void)path; (void)n; return -1; }
void host_video_close(int32_t id) { (void)id; }
void host_video_play(int32_t id) { (void)id; }
void host_video_pause(int32_t id) { (void)id; }
void host_video_seek(int32_t id, double time) { (void)id; (void)time; }
double host_video_time(int32_t id) { (void)id; return 0; }
double host_video_duration(int32_t id) { (void)id; return -1; }
double host_video_width(int32_t id) { (void)id; return 0; }
double host_video_height(int32_t id) { (void)id; return 0; }
int32_t host_video_ready(int32_t id) { (void)id; return -1; }
void host_video_set_volume(int32_t id, double volume) { (void)id; (void)volume; }
void host_video_set_muted(int32_t id, int32_t muted) { (void)id; (void)muted; }
void host_video_set_rate(int32_t id, double rate) { (void)id; (void)rate; }
void host_video_draw(int32_t id, double x, double y, double w, double h, double alpha) { (void)id; (void)x; (void)y; (void)w; (void)h; (void)alpha; }
#endif

/** What canPlayType answers for a type on this host: 2 probably, 1 maybe, 0 no. */
#ifndef NATIVE_NO_FFMPEG
int32_t host_video_can_play(const uint8_t *type, size_t n) {
  if (!ff_load()) return 0;
  char t[256];
  size_t at = 0;
  for (size_t i = 0; i < n && at + 1 < sizeof(t); i++) {
    unsigned char ch = type[i];
    if (ch >= 'A' && ch <= 'Z') ch = (unsigned char)(ch - 'A' + 'a');
    t[at++] = (char)ch;
  }
  t[at] = '\0';
  if (strstr(t, "webm") || strstr(t, "ogg") || strstr(t, "ogv") || strstr(t, "oga") || strstr(t, "matroska")) return 2;
  if (strstr(t, "video/mp4") || strstr(t, "video/quicktime") || strstr(t, "video/x-m4v")) {
    // H.264 and AAC play only when the libavcodec that was found has their decoders: our own
    // build never does, a system FFmpeg may.
    if (strstr(t, "avc1") || strstr(t, "h264")) return ff.find_decoder_by_name("h264") != NULL ? 2 : 0;
    if (strstr(t, "mp4a") || strstr(t, "aac")) return ff.find_decoder_by_name("aac") != NULL ? 2 : 0;
    return 1;
  }
  if (strstr(t, "audio/mpeg") || strstr(t, "audio/mp3") || strstr(t, "audio/flac") ||
      strstr(t, "audio/wav") || strstr(t, "audio/x-wav")) return 2;
  return 0;
}
#else
int32_t host_video_can_play(const uint8_t *type, size_t n) { (void)type; (void)n; return 0; }
#endif

void host_gradient_linear(double x, double y, double w, double h,
    double x0, double y0, double x1, double y1, const uint8_t *stops, size_t n, double alpha) {
  Cmd *c = push_cmd();
  c->kind = CMD_GRADIENT_LINEAR;
  c->x = x; c->y = y; c->w = w; c->h = h;
  c->p0 = x0; c->p1 = y0; c->p2 = x1; c->p3 = y1;
  c->size = alpha;
  copy_text(c, stops, n);
}

void host_gradient_radial(double x, double y, double w, double h,
    double cx, double cy, double rx, double ry, const uint8_t *stops, size_t n, double alpha) {
  Cmd *c = push_cmd();
  c->kind = CMD_GRADIENT_RADIAL;
  c->x = x; c->y = y; c->w = w; c->h = h;
  c->p0 = cx; c->p1 = cy; c->p2 = rx; c->p3 = ry;
  c->size = alpha;
  copy_text(c, stops, n);
}

void host_gradient_conic(double x, double y, double w, double h,
    double cx, double cy, double angle, const uint8_t *stops, size_t n, double alpha) {
  Cmd *c = push_cmd();
  c->kind = CMD_GRADIENT_CONIC;
  c->x = x; c->y = y; c->w = w; c->h = h;
  c->p0 = cx; c->p1 = cy; c->p2 = angle;
  c->size = alpha;
  copy_text(c, stops, n);
}

void host_text(const uint8_t *s, size_t n, double x, double y, double line_height, double size, double weight,
               uint32_t color, double letter, double word, uint32_t emphasis, uint32_t emphasis_color) {
  Cmd *c = push_cmd();
  c->kind = CMD_TEXT;
  c->x = x; c->y = y; c->line_height = line_height; c->size = size; c->weight = weight; c->color = color;
  c->letter = letter; c->word = word;
  c->emphasis = emphasis; c->emphasis_color = emphasis_color;
  copy_text(c, s, n);
}

// A text run drawn with a shadow of itself: the shadow takes `shadow_color`, offset by (dx, dy)
// and blurred by `blur`; the glyphs themselves are drawn in `color`.
void host_text_shadow(const uint8_t *s, size_t n, double x, double y, double line_height, double size, double weight,
                      uint32_t color, uint32_t shadow_color, double letter, double word,
                      double dx, double dy, double blur, uint32_t emphasis, uint32_t emphasis_color) {
  Cmd *c = push_cmd();
  c->kind = CMD_TEXT_SHADOW;
  c->x = x; c->y = y; c->line_height = line_height; c->size = size; c->weight = weight;
  c->color = color; c->shadow_color = shadow_color;
  c->letter = letter; c->word = word;
  c->dx = dx; c->dy = dy; c->blur = blur;
  c->emphasis = emphasis; c->emphasis_color = emphasis_color;
  copy_text(c, s, n);
}

void host_mask_push(int32_t serial, int32_t pkind, double x, double y, double w, double h) {
  Cmd *c = push_cmd();
  c->kind = CMD_MASK_PUSH;
  c->serial = serial; c->pkind = pkind;
  c->x = x; c->y = y; c->w = w; c->h = h;
}

void host_mask_split(void) { push_cmd()->kind = CMD_MASK_SPLIT; }
void host_mask_pop(void) { push_cmd()->kind = CMD_MASK_POP; }

static Cmd *push_effect(int32_t serial, int32_t pkind, double x, double y, double w, double h,
                        const uint8_t *spec, size_t n) {
  Cmd *c = push_cmd();
  c->kind = CMD_EFFECT_PUSH;
  c->serial = serial; c->pkind = pkind;
  c->x = x; c->y = y; c->w = w; c->h = h;
  copy_text(c, spec, n);
  // A backdrop chain needs the frame's own pixels, which a paint into a fresh layer can't give.
  EffectSpec parsed;
  effect_spec_parse(&parsed, c->text);
  if (parsed.bcount != 0) g_needs_backdrop = 1;
  return c;
}

void host_effect_push(int32_t serial, int32_t pkind, double x, double y, double w, double h,
                      const uint8_t *spec, size_t n) {
  push_effect(serial, pkind, x, y, w, h, spec, n);
}

int32_t host_effect_push_indexed(int32_t serial, int32_t pkind, double x, double y, double w, double h,
                                 const uint8_t *spec, size_t n) {
  return push_effect(serial, pkind, x, y, w, h, spec, n)->handle;
}

/** The command a handle names: its list id and index are packed into the handle. */
static Cmd *find_command(int32_t handle) {
  if (handle < 0) return NULL;
  int32_t list_id = handle / CMD_HANDLE_STRIDE - 1;
  int32_t index = handle % CMD_HANDLE_STRIDE;
  if (list_id < -1 || list_id >= g_layer_count) return NULL;
  CmdList *list = list_id < 0 ? &g_root : &g_layers[list_id].list;
  if (index < 0 || (size_t)index >= list->count) return NULL;
  Cmd *c = &list->cmds[index];
  return c->handle == handle ? c : NULL;
}

/** Moves a recorded transform to a new matrix, and a recorded opacity group to a new alpha. */
int32_t host_update_transform(int32_t handle, double a, double b, double cc, double d, double e, double f) {
  Cmd *c = find_command(handle);
  if (c == NULL || c->kind != CMD_TRANSFORM) return 0;
  c->p0 = a; c->p1 = b; c->p2 = cc; c->p3 = d;
  c->r[0] = e;
  c->r[1] = f;
  return 1;
}

int32_t host_update_opacity(int32_t handle, double alpha) {
  Cmd *c = find_command(handle);
  if (c == NULL || c->kind != CMD_EFFECT_PUSH) return 0;
  c->alpha_override = 1;
  c->alpha = alpha;
  return 1;
}

void host_effect_pop(void) { push_cmd()->kind = CMD_EFFECT_POP; }

// A box a perspective ancestor projects: the commands up to the pop paint the box (x, y, w, h)
// where the page lays it out, and the box's pixels are warped onto its quad, the four projected
// corners TL, TR, BR, BL in page space.
void host_perspective_push(int32_t serial, int32_t pkind, double x, double y, double w, double h,
                           double x0, double y0, double x1, double y1,
                           double x2, double y2, double x3, double y3) {
  Cmd *c = push_cmd();
  c->kind = CMD_PERSPECTIVE_PUSH;
  c->serial = serial; c->pkind = pkind;
  c->x = x; c->y = y; c->w = w; c->h = h;
  c->q[0] = x0; c->q[1] = y0;
  c->q[2] = x1; c->q[3] = y1;
  c->q[4] = x2; c->q[5] = y2;
  c->q[6] = x3; c->q[7] = y3;
}

void host_perspective_pop(void) { push_cmd()->kind = CMD_PERSPECTIVE_POP; }


// ---------------------------------------------------------------------------
// Geometry and paint helpers

typedef struct { double x, y, w, h; } Box;

static void set_fill(cairo_t *cr, uint32_t c) {
  cairo_set_source_rgba(cr, ((c >> 24) & 255) / 255.0, ((c >> 16) & 255) / 255.0,
                        ((c >> 8) & 255) / 255.0, (c & 255) / 255.0);
}

// Opaque axis-aligned rectangles are snapped to whole pixels of the user space, as a browser
// snaps a background: an edge that falls mid-pixel is drawn to the pixel boundary.
static Box snapped_rect(double x, double y, double w, double h) {
  double x0 = round(x), y0 = round(y), x1 = round(x + w), y1 = round(y + h);
  return (Box){x0, y0, x1 - x0, y1 - y0};
}

/** Does every corner of this shape have no radius? */
static int square_radii(const double *r) {
  for (int k = 0; k < 8; k++) if (r[k] != 0) return 0;
  return 1;
}

/**
 * How much of the box's edge a corner covers: twice the smaller share of the width and the height
 * its radii take up. A radius at least half the box in both directions covers the edge once over,
 * which is what makes a `border-radius: 50%` box stay a circle when its shadow spreads.
 */
static double shadow_coverage(double rw, double rh, double w, double h) {
  double a = 2 * rw / w, b = 2 * rh / h;
  if (isnan(a) || isnan(b)) return 0;
  return a < b ? a : b;
}

/** The corner radius a shadow spreads to, for one axis (CSS Backgrounds 3). */
static double spread_radius(double r, double spread, double coverage) {
  if (!(r > 0)) return 0;
  if (r > spread || coverage > 1) return r + spread;
  double q = 1 - r / spread;
  return r + spread * (1 - q * q * q * (1 - coverage * coverage * coverage));
}

/** The corner radius of the hole inside an inset shadow's padding box. */
static double inset_radius(double r, double spread) {
  if (!(r > 0)) return 0;
  double d = -spread;
  if (!(d > 0)) {
    double v = r + d;
    return v > 0 ? v : 0;
  }
  return spread_radius(r, d, 0);
}

/** Whether the current transform keeps axis-aligned rectangles axis-aligned. */
static int axis_aligned(const cairo_matrix_t *m) {
  int diagonal = m->xy == 0 && m->yx == 0 && m->xx != 0 && m->yy != 0;
  int anti = m->xx == 0 && m->yy == 0 && m->xy != 0 && m->yx != 0;
  return diagonal ? 1 : anti ? 2 : 0;
}

// The rectangle to fill in the current user space: without a transform it is snapped there, where
// user space and device space agree on what a pixel is; a transform that keeps the box
// axis-aligned is snapped in device space instead.
static Box snapped_for_ctm(cairo_t *cr, double x, double y, double w, double h, int transformed) {
  if (!transformed) return snapped_rect(x, y, w, h);
  cairo_matrix_t m;
  cairo_get_matrix(cr, &m);
  if (!axis_aligned(&m)) return snapped_rect(x, y, w, h);
  double px[2] = {x, x + w}, py[2] = {y, y + h};
  double dx[4], dy[4];
  for (int i = 0; i < 4; i++) {
    dx[i] = m.xx * px[i & 1] + m.xy * py[i >> 1] + m.x0;
    dy[i] = m.yx * px[i & 1] + m.yy * py[i >> 1] + m.y0;
  }
  double x0 = fmin(fmin(dx[0], dx[1]), fmin(dx[2], dx[3]));
  double x1 = fmax(fmax(dx[0], dx[1]), fmax(dx[2], dx[3]));
  double y0 = fmin(fmin(dy[0], dy[1]), fmin(dy[2], dy[3]));
  double y1 = fmax(fmax(dy[0], dy[1]), fmax(dy[2], dy[3]));
  x0 = round(x0); y0 = round(y0); x1 = round(x1); y1 = round(y1);
  cairo_matrix_t inv = m;
  cairo_matrix_invert(&inv);
  double ux[4], uy[4];
  for (int i = 0; i < 4; i++) {
    double X = (i & 1) ? x1 : x0, Y = (i >> 1) ? y1 : y0;
    cairo_matrix_transform_point(&inv, &X, &Y);
    ux[i] = X;
    uy[i] = Y;
  }
  double X0 = fmin(fmin(ux[0], ux[1]), fmin(ux[2], ux[3]));
  double X1 = fmax(fmax(ux[0], ux[1]), fmax(ux[2], ux[3]));
  double Y0 = fmin(fmin(uy[0], uy[1]), fmin(uy[2], uy[3]));
  double Y1 = fmax(fmax(uy[0], uy[1]), fmax(uy[2], uy[3]));
  return (Box){X0, Y0, X1 - X0, Y1 - Y0};
}

// One vertex of a polygon snapped to the device grid the way snapped_for_ctm snaps a rect.
static void snap_vertex(cairo_t *cr, double *px, double *py, int transformed) {
  if (!transformed) {
    *px = round(*px);
    *py = round(*py);
    return;
  }
  cairo_matrix_t m;
  cairo_get_matrix(cr, &m);
  if (!axis_aligned(&m)) return;
  double X = *px, Y = *py;
  cairo_matrix_transform_point(&m, &X, &Y);
  X = round(X);
  Y = round(Y);
  cairo_matrix_t inv = m;
  cairo_matrix_invert(&inv);
  cairo_matrix_transform_point(&inv, &X, &Y);
  *px = X;
  *py = Y;
}

// The next character of a point list that starts a number, stopping at a subpath break.
static const char *to_num(const char *q) {
  while (*q && *q != ';' && (*q < '0' || *q > '9') && *q != '-' && *q != '+' && *q != '.') q++;
  return q;
}

// A path from "x,y x,y x,y" points, one subpath per ';'. Returns 1 when it added anything.
static int poly_path(cairo_t *cr, const char *s, int transformed, int snap) {
  const char *q = s;
  int fresh = 1, added = 0;
  while (*q) {
    q = to_num(q);
    if (!*q) break;
    if (*q == ';') {
      q++;
      if (!fresh) {
        cairo_close_path(cr);
        fresh = 1;
      }
      continue;
    }
    char *end;
    double x = strtod(q, &end);
    if (end == q) break;
    q = to_num(end);
    if (!*q || *q == ';') break; // a point needs both of its coordinates
    double y = strtod(q, &end);
    if (end == q) break;
    q = end;
    if (snap) snap_vertex(cr, &x, &y, transformed);
    if (fresh) {
      cairo_move_to(cr, x, y);
      fresh = 0;
    } else {
      cairo_line_to(cr, x, y);
    }
    added = 1;
  }
  if (!fresh) cairo_close_path(cr);
  return added;
}

static void fill_box_clamped(cairo_t *cr, Box b) {
  if (b.w <= 0 || b.h <= 0) return;
  cairo_rectangle(cr, b.x, b.y, b.w, b.h);
  cairo_fill(cr);
}

static void rounded_rect_path(cairo_t *cr, double x, double y, double w, double h, double r) {
  if (w < 0) w = 0;
  if (h < 0) h = 0;
  double max = (w < h ? w : h) / 2;
  if (r > max) r = max;
  if (r < 0) r = 0;
  // A quarter arc's control points sit this far along, the circle-to-cubic constant.
  static const double k = 0.5522847498307936;
  double rx = r > 0 ? r * (1 - k) : 0;
  cairo_move_to(cr, x + r, y);
  cairo_line_to(cr, x + w - r, y);
  if (r > 0) cairo_curve_to(cr, x + w - r + rx, y, x + w, y + r - rx, x + w, y + r);
  cairo_line_to(cr, x + w, y + h - r);
  if (r > 0) cairo_curve_to(cr, x + w, y + h - r + rx, x + w - r + rx, y + h, x + w - r, y + h);
  cairo_line_to(cr, x + r, y + h);
  if (r > 0) cairo_curve_to(cr, x + r - rx, y + h, x, y + h - r + rx, x, y + h - r);
  cairo_line_to(cr, x, y + r);
  if (r > 0) cairo_curve_to(cr, x, y + r - rx, x + r - rx, y, x + r, y);
  cairo_close_path(cr);
}

// A rounded rect with a radius per corner and per axis. `r` holds the radii in Cmd's order.
static void round_path(cairo_t *cr, double x, double y, double w, double h, const double *r) {
  if (w < 0) w = 0;
  if (h < 0) h = 0;
  double tlx = r[0], tly = r[1], trx = r[2], trY = r[3], brx = r[4], bry = r[5], blx = r[6], bly = r[7];
  if (tlx < 0) tlx = 0;
  if (tly < 0) tly = 0;
  if (trx < 0) trx = 0;
  if (trY < 0) trY = 0;
  if (brx < 0) brx = 0;
  if (bry < 0) bry = 0;
  if (blx < 0) blx = 0;
  if (bly < 0) bly = 0;
  if (tlx > w) tlx = w;
  if (trx > w) trx = w;
  if (brx > w) brx = w;
  if (blx > w) blx = w;
  if (tly > h) tly = h;
  if (trY > h) trY = h;
  if (bry > h) bry = h;
  if (bly > h) bly = h;
  static const double k = 0.5522847498307936;
  cairo_move_to(cr, x + tlx, y);
  cairo_line_to(cr, x + w - trx, y);
  if (trx > 0 || trY > 0) {
    cairo_curve_to(cr, x + w - trx + k * trx, y, x + w, y + trY - k * trY, x + w, y + trY);
  }
  cairo_line_to(cr, x + w, y + h - bry);
  if (brx > 0 || bry > 0) {
    cairo_curve_to(cr, x + w, y + h - bry + k * bry, x + w - brx + k * brx, y + h, x + w - brx, y + h);
  }
  cairo_line_to(cr, x + blx, y + h);
  if (blx > 0 || bly > 0) {
    cairo_curve_to(cr, x + blx - k * blx, y + h, x, y + h - bly + k * bly, x, y + h - bly);
  }
  cairo_line_to(cr, x, y + tly);
  if (tlx > 0 || tly > 0) {
    cairo_curve_to(cr, x, y + tly - k * tly, x + tlx - k * tlx, y, x + tlx, y);
  }
  cairo_close_path(cr);
}

// The same path shrunk by `b` on every side, with each radius reduced by `b` along its axis.
static void inner_round_path(cairo_t *cr, double x, double y, double w, double h, const double *r, double b) {
  double in[8];
  for (int i = 0; i < 8; i++) {
    double v = r[i] - b;
    in[i] = v > 0 ? v : 0;
  }
  round_path(cr, x + b, y + b, w - 2 * b, h - 2 * b, in);
}

// ---------------------------------------------------------------------------
// Gradients
//
// A stop list is `<colour>,<position>` pairs joined by ";", positions 0..1 along the gradient
// line. The colour is packed 0xRRGGBBAA like every other host colour. A list longer than the cap
// keeps the stops that fit, which is as many as a page has ever asked for.

#define MAX_STOPS 4096

typedef struct {
  int n;
  double loc[MAX_STOPS];
  uint32_t col[MAX_STOPS]; // 0xRRGGBBAA, straight
} Stops;

// A CSS gradient fades its stops in premultiplied space: a stop that fades to transparent keeps
// its own colour instead of drifting towards the transparent stop's colour. Cairo interpolates the
// colour channels and the alpha apart, so each pair of stops is written as a few stops of its own,
// at the colour the premultiplied fade has there.
#define RAMP_STEPS 8
#define RAMP_LIMIT 256 // longer stop lists are drawn as they are rather than multiplied

static void add_stop_ramp(cairo_pattern_t *pat, const uint32_t *col, const double *loc, int n) {
  int steps = n <= RAMP_LIMIT ? RAMP_STEPS : 1;
  double floor_loc = 0;
  for (int i = 0; i < n; i++) {
    double at = loc[i] < 0 ? 0 : loc[i] > 1 ? 1 : loc[i];
    if (at < floor_loc) at = floor_loc;
    floor_loc = at;
    double a = (col[i] & 255) / 255.0;
    cairo_pattern_add_color_stop_rgba(pat, at, ((col[i] >> 24) & 255) / 255.0,
                                      ((col[i] >> 16) & 255) / 255.0,
                                      ((col[i] >> 8) & 255) / 255.0, a);
    if (i + 1 >= n || steps < 2) continue;
    double next = loc[i + 1] < 0 ? 0 : loc[i + 1] > 1 ? 1 : loc[i + 1];
    if (!(next > at)) continue;
    double a0 = a, a1 = (col[i + 1] & 255) / 255.0;
    double r0 = ((col[i] >> 24) & 255) / 255.0 * a0;
    double g0 = ((col[i] >> 16) & 255) / 255.0 * a0;
    double b0 = ((col[i] >> 8) & 255) / 255.0 * a0;
    double r1 = ((col[i + 1] >> 24) & 255) / 255.0 * a1;
    double g1 = ((col[i + 1] >> 16) & 255) / 255.0 * a1;
    double b1 = ((col[i + 1] >> 8) & 255) / 255.0 * a1;
    for (int s = 1; s < steps; s++) {
      double t = (double)s / steps;
      double alpha = a0 + (a1 - a0) * t;
      double r = r0 + (r1 - r0) * t, g = g0 + (g1 - g0) * t, b = b0 + (b1 - b0) * t;
      double off = at + (next - at) * t;
      if (alpha > 0) cairo_pattern_add_color_stop_rgba(pat, off, r / alpha, g / alpha, b / alpha, alpha);
      else cairo_pattern_add_color_stop_rgba(pat, off, 0, 0, 0, 0);
    }
  }
}

static int parse_stops(const char *s, Stops *out) {
  out->n = 0;
  if (!s) return 0;
  const char *p = s;
  while (*p && out->n < MAX_STOPS) {
    char *end;
    unsigned long long c = strtoull(p, &end, 10);
    if (end == p) break;
    p = end;
    if (*p == ',') p++;
    double loc = strtod(p, &end);
    if (end == p) break;
    p = end;
    out->loc[out->n] = loc;
    out->col[out->n] = (uint32_t)c;
    out->n++;
    if (*p == ';') p++;
    else break;
  }
  return out->n;
}

/** Whether every stop of a list is the same colour, which is then the colour everywhere. */
static int stops_flat(const Stops *s, uint32_t *colour) {
  if (s->n < 2) return 0;
  for (int i = 1; i < s->n; i++) if (s->col[i] != s->col[0]) return 0;
  *colour = s->col[0];
  return 1;
}

/** The colour at `t` along a gradient: the end stop's colour past either end, a straight blend
 *  between stops. Components come out straight, 0..1. */
static void stops_colour_at(const Stops *s, double t, double out[4]) {
  int i = 0;
  while (i + 1 < s->n && s->loc[i + 1] <= t) i++;
  int next = i + 1 < s->n ? i + 1 : i;
  uint32_t a = s->col[i], b = s->col[next];
  double span = s->loc[next] - s->loc[i];
  double k = span > 0 && t > s->loc[i] ? (t - s->loc[i]) / span : 0;
  if (k > 1) k = 1;
  if (k < 0) k = 0;
  double ca[4] = {((a >> 24) & 255) / 255.0, ((a >> 16) & 255) / 255.0, ((a >> 8) & 255) / 255.0, (a & 255) / 255.0};
  double cb[4] = {((b >> 24) & 255) / 255.0, ((b >> 16) & 255) / 255.0, ((b >> 8) & 255) / 255.0, (b & 255) / 255.0};
  // Stops fade in premultiplied space, as a browser fades them.
  double alpha = ca[3] + (cb[3] - ca[3]) * k;
  for (int c = 0; c < 3; c++) {
    double premultiplied = ca[c] * ca[3] + (cb[c] * cb[3] - ca[c] * ca[3]) * k;
    out[c] = alpha > 0 ? premultiplied / alpha : 0;
  }
  out[3] = alpha;
}

/** A Cairo gradient with the list's stops, extended past both ends as a CSS gradient is. */
static cairo_pattern_t *gradient_pattern(const Stops *s, int radial, double x0, double y0, double r0,
                                         double x1, double y1, double r1) {
  if (s->n < 2) return NULL;
  cairo_pattern_t *pat = radial ? cairo_pattern_create_radial(x0, y0, r0 < 0 ? 0 : r0, x1, y1, r1 < 0 ? 0 : r1)
                                : cairo_pattern_create_linear(x0, y0, x1, y1);
  if (!pat) return NULL;
  add_stop_ramp(pat, s->col, s->loc, s->n);
  cairo_pattern_set_extend(pat, CAIRO_EXTEND_PAD);
  return pat;
}

/**
 * A conic gradient as a raster of its tile: the colour at a pixel is a function of its angle
 * around the centre, which Cairo has no primitive for. The tile covers the gradient's box in
 * device pixels and is drawn as an image; a box too large to raster keeps the page as it was.
 */
static void paint_conic(cairo_t *cr, const Cmd *c, const Stops *s, double alpha) {
  double scale = g_scale;
  Box box = snapped_rect(c->x, c->y, c->w, c->h);
  int tw = (int)llround(box.w * scale), th = (int)llround(box.h * scale);
  if (tw <= 0 || th <= 0 || (double)tw * (double)th > 16.0 * 1000 * 1000) return;
  unsigned char *buf = (unsigned char *)malloc((size_t)tw * (size_t)th * 4);
  if (!buf) return;
  double cx = (c->p0 - box.x) * scale, cy = (c->p1 - box.y) * scale;
  double start = c->p2;
  double col[4];
  for (int j = 0; j < th; j++) {
    for (int i = 0; i < tw; i++) {
      double dx = (i + 0.5) - cx, dy = (j + 0.5) - cy;
      double t = atan2(dy, dx) - start;
      t = t / (2 * M_PI);
      t = t - floor(t);
      stops_colour_at(s, t, col);
      size_t o = ((size_t)j * (size_t)tw + (size_t)i) * 4;
      // Premultiplied BGRA, the order an ARGB32 surface keeps on this platform.
      buf[o + 0] = (unsigned char)lround(col[2] * col[3] * 255);
      buf[o + 1] = (unsigned char)lround(col[1] * col[3] * 255);
      buf[o + 2] = (unsigned char)lround(col[0] * col[3] * 255);
      buf[o + 3] = (unsigned char)lround(col[3] * 255);
    }
  }
  cairo_surface_t *tile = cairo_image_surface_create_for_data(buf, CAIRO_FORMAT_ARGB32, tw, th, tw * 4);
  cairo_save(cr);
  // The raster is device pixels, so it is placed at its box's device position, with no transform
  // in the way.
  cairo_identity_matrix(cr);
  cairo_set_source_surface(cr, tile, box.x * scale, box.y * scale);
  cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_NEAREST);
  cairo_paint_with_alpha(cr, alpha);
  cairo_restore(cr);
  cairo_surface_destroy(tile);
  free(buf);
}

// ---------------------------------------------------------------------------
// Images
//
// Decoded images live in the image table as premultiplied RGBA; a drawing makes a Cairo surface
// of them once, in the surface's own channel order.

static void free_pixels(void *p) { free(p); }

// The key of the pixel buffer a surface was made from, so the buffer goes with the surface.
static const cairo_user_data_key_t g_pixels_key;

static cairo_surface_t *image_surface(int32_t id) {
  if (id < 0 || id >= g_image_count) return NULL;
  Image *img = &g_images[id];
  if (img->surface) return img->surface;
  if (!img->px) return NULL;
  size_t n = (size_t)img->w * (size_t)img->h;
  uint8_t *swap = (uint8_t *)malloc(n * 4);
  if (!swap) return NULL;
  for (size_t i = 0; i < n; i++) {
    swap[i * 4 + 0] = img->px[i * 4 + 2];
    swap[i * 4 + 1] = img->px[i * 4 + 1];
    swap[i * 4 + 2] = img->px[i * 4 + 0];
    swap[i * 4 + 3] = img->px[i * 4 + 3];
  }
  cairo_surface_t *surf = cairo_image_surface_create_for_data(swap, CAIRO_FORMAT_ARGB32,
                                                              (int)img->w, (int)img->h, (int)img->w * 4);
  cairo_surface_set_user_data(surf, &g_pixels_key, swap, free_pixels);
  img->surface = surf;
  return surf;
}

/**
 * Places a surface's pixel rect (sx, sy, sw, sh) into the user-space rect (x, y, w, h), snapped
 * as a background image is. The cut is taken in the surface's own pixels, so scaling a thin
 * slice up can't pull in the colour of the slices beside it.
 */
static void draw_surface_part(cairo_t *cr, cairo_surface_t *surf, double x, double y, double w, double h,
                              double sx, double sy, double sw, double sh, double alpha, int smooth) {
  if (!surf) return;
  Box r = snapped_rect(x, y, w, h);
  if (!(r.w > 0) || !(r.h > 0) || !(sw > 0) || !(sh > 0)) return;
  double rx = r.w / sw, ry = r.h / sh;
  cairo_pattern_t *pat = cairo_pattern_create_for_surface(surf);
  cairo_matrix_t m;
  m.xx = 1 / rx; m.yy = 1 / ry; m.xy = 0; m.yx = 0;
  m.x0 = sx - r.x / rx;
  m.y0 = sy - r.y / ry;
  cairo_pattern_set_matrix(pat, &m);
  cairo_pattern_set_filter(pat, smooth ? CAIRO_FILTER_GOOD : CAIRO_FILTER_NEAREST);
  // A scaled image's filter kernel reaches past the edge texels; a browser clamps them, so the
  // last row and column keep their colour instead of fading into transparency.
  cairo_pattern_set_extend(pat, CAIRO_EXTEND_PAD);
  cairo_save(cr);
  cairo_new_path(cr);
  cairo_rectangle(cr, r.x, r.y, r.w, r.h);
  cairo_set_source(cr, pat);
  cairo_clip(cr);
  cairo_paint_with_alpha(cr, alpha);
  cairo_restore(cr);
  cairo_pattern_destroy(pat);
}


// ---------------------------------------------------------------------------
// Text

#define MAX_MARKS 4096

static void gauss_blur(unsigned char *px, size_t w, size_t h, size_t stride, double sigma);

/**
 * Draws a text run's shadow: the glyphs painted into a layer of their own, blurred and tinted
 * with the shadow colour, then laid under the run at its offset.
 */
static void paint_text_shadow(cairo_t *cr, const Cmd *c, cairo_path_t *glyphs,
                              double ux0, double uy0, double ux1, double uy1) {
  cairo_matrix_t m;
  cairo_get_matrix(cr, &m);
  double dx0 = 1e18, dy0 = 1e18, dx1 = -1e18, dy1 = -1e18;
  double xs[2] = {ux0, ux1}, ys[2] = {uy0, uy1};
  for (int i = 0; i < 2; i++) {
    for (int j = 0; j < 2; j++) {
      double X = xs[i], Y = ys[j];
      cairo_matrix_transform_point(&m, &X, &Y);
      if (X < dx0) dx0 = X;
      if (X > dx1) dx1 = X;
      if (Y < dy0) dy0 = Y;
      if (Y > dy1) dy1 = Y;
    }
  }
  double scale = sqrt(fabs(m.xx * m.yy - m.xy * m.yx));
  if (!(scale > 0)) scale = 1;
  double odx = c->dx, ody = c->dy;
  cairo_matrix_transform_distance(&m, &odx, &ody);
  double pad = c->blur * 3 * scale + 1;
  long bx = (long)floor(dx0 + fmin(0, odx) - pad);
  long by = (long)floor(dy0 + fmin(0, ody) - pad);
  long ex = (long)ceil(dx1 + fmax(0, odx) + pad);
  long ey = (long)ceil(dy1 + fmax(0, ody) + pad);
  cairo_surface_t *target = cairo_get_target(cr);
  int tw = cairo_image_surface_get_width(target), th = cairo_image_surface_get_height(target);
  if (bx < 0) bx = 0;
  if (by < 0) by = 0;
  if (ex > tw) ex = tw;
  if (ey > th) ey = th;
  long bw = ex - bx, bh = ey - by;
  if (bw <= 0 || bh <= 0) return;
  cairo_surface_t *layer = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, (int)bw, (int)bh);
  if (cairo_surface_status(layer) != CAIRO_STATUS_SUCCESS) {
    cairo_surface_destroy(layer);
    return;
  }
  cairo_t *cr2 = cairo_create(layer);
  cairo_matrix_t shift, nm;
  cairo_matrix_init_translate(&shift, -(double)bx, -(double)by);
  cairo_matrix_multiply(&nm, &m, &shift);
  cairo_set_matrix(cr2, &nm);
  cairo_append_path(cr2, glyphs);
  cairo_set_source_rgba(cr2, 1, 1, 1, 1);
  cairo_fill(cr2);
  cairo_destroy(cr2);
  cairo_surface_flush(layer);
  unsigned char *data = cairo_image_surface_get_data(layer);
  int stride = cairo_image_surface_get_stride(layer);
  if (data) {
    // A shadow's blur is a radius; the Gaussian behind it has half that as its deviation.
    if (c->blur > 0) gauss_blur(data, (size_t)bw, (size_t)bh, (size_t)stride, c->blur * scale / 2);
    double cr8 = ((c->shadow_color >> 24) & 255) / 255.0;
    double cg8 = ((c->shadow_color >> 16) & 255) / 255.0;
    double cb8 = ((c->shadow_color >> 8) & 255) / 255.0;
    double ca8 = (c->shadow_color & 255) / 255.0;
    for (long y = 0; y < bh; y++) {
      unsigned char *row = data + (size_t)y * (size_t)stride;
      for (long x = 0; x < bw; x++) {
        unsigned char *p = row + (size_t)x * 4;
        double a = p[3] / 255.0;
        p[0] = (unsigned char)lround(cb8 * ca8 * a * 255);
        p[1] = (unsigned char)lround(cg8 * ca8 * a * 255);
        p[2] = (unsigned char)lround(cr8 * ca8 * a * 255);
        p[3] = (unsigned char)lround(ca8 * a * 255);
      }
    }
    cairo_surface_mark_dirty(layer);
  }
  cairo_save(cr);
  cairo_identity_matrix(cr);
  cairo_set_source_surface(cr, layer, bx, by);
  cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_NEAREST);
  cairo_paint(cr);
  cairo_restore(cr);
  cairo_surface_destroy(layer);
}

/** Paints a text command: the glyphs in `color`, its emphasis marks in `emphasis_color`. */
static void paint_text(cairo_t *cr, const Cmd *c, int shadowed) {
  double baseline = device_round(text_baseline(c->size, c->weight, c->y, c->line_height, g_scale), g_scale);
  Mark *marks = (Mark *)malloc(sizeof(Mark) * MAX_MARKS);
  if (!marks) return;
  cairo_new_path(cr);
  int count = paint_run(cr, (const uint8_t *)c->text, c->len, c->size, c->weight, c->letter, c->word, c->x,
                        baseline, g_scale, (int)c->emphasis, marks, MAX_MARKS);
  if (shadowed) {
    cairo_path_t *glyphs = cairo_copy_path(cr);
    if (glyphs) {
      double ux0, uy0, ux1, uy1;
      cairo_path_extents(cr, &ux0, &uy0, &ux1, &uy1);
      if (ux1 > ux0 && uy1 > uy0) paint_text_shadow(cr, c, glyphs, ux0, uy0, ux1, uy1);
      cairo_path_destroy(glyphs);
    }
  }
  // A face without the weight asked for is emboldened by stroking the glyphs as they are filled,
  // a twenty-fourth of the size wide.
  FT_Face ft = paint_face(c->weight);
  if (ft && !face_is_bold(ft, c->weight)) {
    set_fill(cr, c->color);
    cairo_fill_preserve(cr);
    set_fill(cr, c->color);
    cairo_set_line_width(cr, c->size / 24.0);
    cairo_stroke(cr);
  } else {
    set_fill(cr, c->color);
    cairo_fill(cr);
  }
  if (count > 0) {
    set_fill(cr, c->emphasis_color);
    for (int i = 0; i < count; i++) {
      draw_emphasis_mark(cr, (int)(c->emphasis & 0xff), marks[i].cx, marks[i].cy, c->size);
    }
  }
  free(marks);
}

// ---------------------------------------------------------------------------
// Filters
//
// A box with a filter or a mix-blend-mode paints its subtree into a layer of its own: the layer is
// replayed into a bitmap of the page's own device pixels, the filter list is applied to it, and
// the result is composited into the page with the blend mode. Cairo has no filter pipeline, so
// the filters work on the bitmap's pixels: the colour matrices are the ones CSS defines for each
// function, and blur is a Gaussian, done as three box blurs.

/** Reads a filter list's count and functions from the spec, leaving `*end` after the last one. A
 *  negative backdrop count says the list is known to be unchanged behind the box: the host reuses
 *  the filtered result it kept instead of filtering again (see apply_backdrop). */
static int read_ops(FilterOp *ops, const char *q, char **end) {
  int count = (int)strtol(q, end, 10);
  q = *end;
  int n = count < 0 ? -count : count;
  if (n > 64) n = 64;
  for (int i = 0; i < n; i++) {
    FilterOp *op = &ops[i];
    op->kind = (int)strtol(q, end, 10);
    q = *end;
    op->a = strtod(q, end);
    q = *end;
    op->dx = strtod(q, end);
    q = *end;
    op->dy = strtod(q, end);
    q = *end;
    op->blur = strtod(q, end);
    q = *end;
    op->color = (uint32_t)strtod(q, end);
    q = *end;
  }
  return count < 0 ? -n : n;
}

static void effect_spec_parse(EffectSpec *s, const char *text) {
  s->alpha = 1;
  s->blend = 0;
  s->count = 0;
  s->bcount = 0;
  if (!text) return;
  const char *q = text;
  char *end;
  s->alpha = strtod(q, &end);
  if (end == q) return;
  q = end;
  s->blend = (int)strtol(q, &end, 10);
  if (end == q) return;
  q = end;
  s->count = read_ops(s->ops, q, &end);
  q = end;
  s->bcount = read_ops(s->bops, q, &end);
}

// The channel offsets of an ARGB32 surface's memory, which differ by platform byte order. A
// colour with a distinct value in each channel says where each one landed.
static int g_ch_r = 2, g_ch_g = 1, g_ch_b = 0, g_ch_a = 3;

static void detect_channels(void) {
  cairo_surface_t *s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
  if (cairo_surface_status(s) == CAIRO_STATUS_SUCCESS) {
    cairo_surface_flush(s);
    unsigned char *p = cairo_image_surface_get_data(s);
    if (p) {
      uint32_t *word = (uint32_t *)p;
      *word = 0xff112233u; // A = 0xff, R = 0x11, G = 0x22, B = 0x33
      for (int i = 0; i < 3; i++) {
        if (p[i] == 0x11) g_ch_r = i;
        else if (p[i] == 0x22) g_ch_g = i;
        else if (p[i] == 0x33) g_ch_b = i;
      }
      g_ch_a = 3;
    }
  }
  cairo_surface_destroy(s);
}

/** The channel offsets, worked out the first time pixels are read or written. */
static void ensure_channels(void) {
  static int done = 0;
  if (!done) {
    done = 1;
    detect_channels();
  }
}

/**
 * A box blur of `radius` pixels on each side, one direction at a time. Everything outside the
 * bitmap counts as transparent, so a shape's edge fades into nothing as a blurred edge does.
 */
static void box_blur(const unsigned char *src, unsigned char *dst, size_t w, size_t h, size_t stride,
                     int radius, int horizontal) {
  const long n = 2 * (long)radius + 1;
  if (horizontal) {
    for (size_t y = 0; y < h; y++) {
      const unsigned char *in = src + y * stride;
      unsigned char *out = dst + y * stride;
      long s0 = 0, s1 = 0, s2 = 0, s3 = 0;
      for (int k = -radius; k <= radius; k++) {
        if (k < 0 || (size_t)k >= w) continue;
        s0 += in[k * 4]; s1 += in[k * 4 + 1]; s2 += in[k * 4 + 2]; s3 += in[k * 4 + 3];
      }
      for (size_t x = 0; x < w; x++) {
        out[x * 4] = (unsigned char)((s0 + n / 2) / n);
        out[x * 4 + 1] = (unsigned char)((s1 + n / 2) / n);
        out[x * 4 + 2] = (unsigned char)((s2 + n / 2) / n);
        out[x * 4 + 3] = (unsigned char)((s3 + n / 2) / n);
        long drop = (long)x - radius, add = (long)x + radius + 1;
        if (drop >= 0 && (size_t)drop < w) {
          s0 -= in[drop * 4]; s1 -= in[drop * 4 + 1]; s2 -= in[drop * 4 + 2]; s3 -= in[drop * 4 + 3];
        }
        if (add >= 0 && (size_t)add < w) {
          s0 += in[add * 4]; s1 += in[add * 4 + 1]; s2 += in[add * 4 + 2]; s3 += in[add * 4 + 3];
        }
      }
    }
    return;
  }
  for (size_t x = 0; x < w; x++) {
    long s0 = 0, s1 = 0, s2 = 0, s3 = 0;
    for (int k = -radius; k <= radius; k++) {
      if (k < 0 || (size_t)k >= h) continue;
      const unsigned char *p = src + (size_t)k * stride + x * 4;
      s0 += p[0]; s1 += p[1]; s2 += p[2]; s3 += p[3];
    }
    for (size_t y = 0; y < h; y++) {
      unsigned char *out = dst + y * stride + x * 4;
      out[0] = (unsigned char)((s0 + n / 2) / n);
      out[1] = (unsigned char)((s1 + n / 2) / n);
      out[2] = (unsigned char)((s2 + n / 2) / n);
      out[3] = (unsigned char)((s3 + n / 2) / n);
      long drop = (long)y - radius, add = (long)y + radius + 1;
      if (drop >= 0 && (size_t)drop < h) {
        const unsigned char *p = src + (size_t)drop * stride + x * 4;
        s0 -= p[0]; s1 -= p[1]; s2 -= p[2]; s3 -= p[3];
      }
      if (add >= 0 && (size_t)add < h) {
        const unsigned char *p = src + (size_t)add * stride + x * 4;
        s0 += p[0]; s1 += p[1]; s2 += p[2]; s3 += p[3];
      }
    }
  }
}

/**
 * A Gaussian blur of standard deviation `sigma`, as three box blurs in each direction: the box
 * widths are chosen so their repeated convolution matches the Gaussian (Kutskir's sizes).
 */
static void gauss_blur(unsigned char *px, size_t w, size_t h, size_t stride, double sigma) {
  if (!(sigma > 0) || w == 0 || h == 0) return;
  double ideal = sqrt((12.0 * sigma * sigma / 3.0) + 1.0);
  int wl = (int)floor(ideal);
  if (wl % 2 == 0) wl--;
  if (wl < 1) wl = 1;
  int wu = wl + 2;
  double mIdeal = (12.0 * sigma * sigma - 3.0 * wl * wl - 12.0 * wl - 9.0) / (-4.0 * wl - 4.0);
  int m = (int)round(mIdeal);
  int sizes[3];
  for (int i = 0; i < 3; i++) sizes[i] = i < m ? wl : wu;
  unsigned char *tmp = (unsigned char *)malloc(h * stride);
  if (!tmp) return;
  for (int i = 0; i < 3; i++) {
    int radius = (sizes[i] - 1) / 2;
    if (radius < 1) continue;
    box_blur(px, tmp, w, h, stride, radius, 1);
    box_blur(tmp, px, w, h, stride, radius, 0);
  }
  free(tmp);
}

/**
 * A 5x4 colour matrix, rows R, G, B, A, with its last column an offset (both scaled to 0..255).
 * The pixels are premultiplied BGRA, so the matrix runs on straight colour read through the
 * channels' own offsets.
 */
static void color_matrix(unsigned char *px, size_t w, size_t h, size_t stride, const double *m) {
  const int R = g_ch_r, G = g_ch_g, B = g_ch_b, A = g_ch_a;
  for (size_t y = 0; y < h; y++) {
    unsigned char *row = px + y * stride;
    for (size_t x = 0; x < w; x++) {
      unsigned char *p = row + x * 4;
      double a = p[A];
      if (a <= 0) continue;
      double r = p[R] * 255.0 / a, g = p[G] * 255.0 / a, b = p[B] * 255.0 / a;
      double nr = m[0] * r + m[1] * g + m[2] * b + m[3] * a + m[4] * 255.0;
      double ng = m[5] * r + m[6] * g + m[7] * b + m[8] * a + m[9] * 255.0;
      double nb = m[10] * r + m[11] * g + m[12] * b + m[13] * a + m[14] * 255.0;
      double na = m[15] * r + m[16] * g + m[17] * b + m[18] * a + m[19] * 255.0;
      if (nr < 0) nr = 0; else if (nr > 255) nr = 255;
      if (ng < 0) ng = 0; else if (ng > 255) ng = 255;
      if (nb < 0) nb = 0; else if (nb > 255) nb = 255;
      if (na < 0) na = 0; else if (na > 255) na = 255;
      p[R] = (unsigned char)round(nr * na / 255.0);
      p[G] = (unsigned char)round(ng * na / 255.0);
      p[B] = (unsigned char)round(nb * na / 255.0);
      p[A] = (unsigned char)round(na);
    }
  }
}

static void matrix_identity(double *m) {
  for (int i = 0; i < 20; i++) m[i] = 0;
  m[0] = 1; m[6] = 1; m[12] = 1; m[18] = 1;
}

/**
 * drop-shadow(): the element's alpha, blurred, tinted with the colour and offset, drawn under the
 * element.
 */
static void drop_shadow(unsigned char *px, size_t w, size_t h, size_t stride, const FilterOp *op,
                        double scale) {
  const int R = g_ch_r, G = g_ch_g, B = g_ch_b, A = g_ch_a;
  unsigned char *sh = (unsigned char *)calloc(h, stride);
  if (!sh) return;
  for (size_t y = 0; y < h; y++) {
    const unsigned char *in = px + y * stride;
    unsigned char *out = sh + y * stride;
    for (size_t x = 0; x < w; x++) out[x * 4 + 3] = in[x * 4 + A];
  }
  if (op->blur > 0) gauss_blur(sh, w, h, stride, op->blur * scale / 2);
  // The bitmap's row 0 is the layer's top row, so a CSS offset moves the shadow down and to the
  // right by sampling the shape up and to the left of it.
  long offx = lround(op->dx * scale), offy = lround(op->dy * scale);
  double cr = ((op->color >> 24) & 0xff) * (double)(op->color & 0xff) / 255.0;
  double cg = ((op->color >> 16) & 0xff) * (double)(op->color & 0xff) / 255.0;
  double cb = ((op->color >> 8) & 0xff) * (double)(op->color & 0xff) / 255.0;
  for (size_t y = 0; y < h; y++) {
    unsigned char *row = px + y * stride;
    for (size_t x = 0; x < w; x++) {
      long sx = (long)x - offx, sy = (long)y - offy;
      if (sx < 0 || sy < 0 || (size_t)sx >= w || (size_t)sy >= h) continue;
      double sa = sh[(size_t)sy * stride + (size_t)sx * 4 + 3] / 255.0;
      if (sa <= 0) continue;
      // The element paints over the shadow: the shadow is the source under the destination.
      double da = row[x * 4 + A] / 255.0;
      double under = 1.0 - da;
      double a = da + sa * under;
      row[x * 4 + R] = (unsigned char)round(row[x * 4 + R] + cr * sa * under);
      row[x * 4 + G] = (unsigned char)round(row[x * 4 + G] + cg * sa * under);
      row[x * 4 + B] = (unsigned char)round(row[x * 4 + B] + cb * sa * under);
      row[x * 4 + A] = (unsigned char)round(a * 255.0);
    }
  }
  free(sh);
}

/** The filter chain, in order: each function takes the whole layer as its input. */
static void apply_filters(unsigned char *px, size_t w, size_t h, size_t stride, const FilterOp *ops,
                          int count, double scale) {
  for (int i = 0; i < count; i++) {
    const FilterOp *op = &ops[i];
    double m[20];
    switch (op->kind) {
      case FK_BLUR:
        gauss_blur(px, w, h, stride, op->a * scale);
        break;
      case FK_BRIGHTNESS:
        matrix_identity(m);
        m[0] = m[6] = m[12] = op->a;
        color_matrix(px, w, h, stride, m);
        break;
      case FK_CONTRAST:
        matrix_identity(m);
        m[0] = m[6] = m[12] = op->a;
        m[4] = m[9] = m[14] = 0.5 - 0.5 * op->a;
        color_matrix(px, w, h, stride, m);
        break;
      case FK_GRAYSCALE: {
        double t = 1 - op->a;
        matrix_identity(m);
        m[0] = 0.2126 + 0.7874 * t; m[1] = 0.7152 - 0.7152 * t; m[2] = 0.0722 - 0.0722 * t;
        m[5] = 0.2126 - 0.2126 * t; m[6] = 0.7152 + 0.2848 * t; m[7] = 0.0722 - 0.0722 * t;
        m[10] = 0.2126 - 0.2126 * t; m[11] = 0.7152 - 0.7152 * t; m[12] = 0.0722 + 0.9278 * t;
        color_matrix(px, w, h, stride, m);
        break;
      }
      case FK_HUE_ROTATE: {
        double c = cos(op->a), s = sin(op->a);
        matrix_identity(m);
        m[0] = 0.213 + c * 0.787 - s * 0.213; m[1] = 0.715 - c * 0.715 - s * 0.715;
        m[2] = 0.072 - c * 0.072 + s * 0.928;
        m[5] = 0.213 - c * 0.213 + s * 0.143; m[6] = 0.715 + c * 0.285 + s * 0.140;
        m[7] = 0.072 - c * 0.072 - s * 0.283;
        m[10] = 0.213 - c * 0.213 - s * 0.787; m[11] = 0.715 - c * 0.715 + s * 0.715;
        m[12] = 0.072 + c * 0.928 + s * 0.072;
        color_matrix(px, w, h, stride, m);
        break;
      }
      case FK_INVERT:
        matrix_identity(m);
        m[0] = m[6] = m[12] = 1 - 2 * op->a;
        m[4] = m[9] = m[14] = op->a;
        color_matrix(px, w, h, stride, m);
        break;
      case FK_OPACITY:
        matrix_identity(m);
        m[18] = op->a;
        color_matrix(px, w, h, stride, m);
        break;
      case FK_SATURATE: {
        double s = op->a;
        matrix_identity(m);
        m[0] = 0.213 + 0.787 * s; m[1] = 0.715 - 0.715 * s; m[2] = 0.072 - 0.072 * s;
        m[5] = 0.213 - 0.213 * s; m[6] = 0.715 + 0.285 * s; m[7] = 0.072 - 0.072 * s;
        m[10] = 0.213 - 0.213 * s; m[11] = 0.715 - 0.715 * s; m[12] = 0.072 + 0.928 * s;
        color_matrix(px, w, h, stride, m);
        break;
      }
      case FK_SEPIA: {
        double t = 1 - op->a;
        matrix_identity(m);
        m[0] = 0.393 + 0.607 * t; m[1] = 0.769 - 0.769 * t; m[2] = 0.189 - 0.189 * t;
        m[5] = 0.349 - 0.349 * t; m[6] = 0.686 + 0.314 * t; m[7] = 0.168 - 0.168 * t;
        m[10] = 0.272 - 0.272 * t; m[11] = 0.534 - 0.534 * t; m[12] = 0.131 + 0.869 * t;
        color_matrix(px, w, h, stride, m);
        break;
      }
      case FK_DROP_SHADOW:
        drop_shadow(px, w, h, stride, op, scale);
        break;
      default:
        break;
    }
  }
}

/** The Cairo blend operator for a mix-blend-mode value, in the runtime's numbering. */
static cairo_operator_t blend_operator(int mode) {
  switch (mode) {
    case 1: return CAIRO_OPERATOR_MULTIPLY;
    case 2: return CAIRO_OPERATOR_SCREEN;
    case 3: return CAIRO_OPERATOR_OVERLAY;
    case 4: return CAIRO_OPERATOR_DARKEN;
    case 5: return CAIRO_OPERATOR_LIGHTEN;
    case 6: return CAIRO_OPERATOR_COLOR_DODGE;
    case 7: return CAIRO_OPERATOR_COLOR_BURN;
    case 8: return CAIRO_OPERATOR_HARD_LIGHT;
    case 9: return CAIRO_OPERATOR_SOFT_LIGHT;
    case 10: return CAIRO_OPERATOR_DIFFERENCE;
    case 11: return CAIRO_OPERATOR_EXCLUSION;
    case 12: return CAIRO_OPERATOR_HSL_HUE;
    case 13: return CAIRO_OPERATOR_HSL_SATURATION;
    case 14: return CAIRO_OPERATOR_HSL_COLOR;
    case 15: return CAIRO_OPERATOR_HSL_LUMINOSITY;
    case 16: return CAIRO_OPERATOR_ADD;
    default: return CAIRO_OPERATOR_OVER;
  }
}

// Where a replay stands: the target it paints into, the transform from the page's user space to
// that target's device space, and the states it saved for clips and transforms.
typedef struct {
  cairo_t *cr;
  cairo_surface_t *surface;
  cairo_matrix_t base;
  int saved[1024];
  int depth;
  int transforms;
} Replay;

static size_t replay_effect(Replay *r, size_t i);
static size_t replay_mask(Replay *r, size_t i);
static size_t replay_perspective(Replay *r, size_t i);
static size_t replay_range(Replay *r, size_t i);

/** One layer's raster, for a composited snapshot: its surface and the ink box it covers. */
typedef struct {
  cairo_surface_t *surf;
  int x, y, w, h;
} LayerRaster;

static LayerRaster *g_rasters = NULL;
static int g_raster_count = 0;
static double g_raster_scale = 1;

static void draw_layer_raster(cairo_t *cr, const LayerRaster *lr);

/** Skips a layer's commands without drawing them, returning the index of its pop. */
static size_t skip_layer(size_t i) {
  int nested = 0;
  for (size_t k = i; k < g_list->count; k++) {
    if (g_list->cmds[k].kind == CMD_EFFECT_PUSH || g_list->cmds[k].kind == CMD_MASK_PUSH ||
        g_list->cmds[k].kind == CMD_PERSPECTIVE_PUSH) nested++;
    else if (g_list->cmds[k].kind == CMD_EFFECT_POP || g_list->cmds[k].kind == CMD_MASK_POP ||
             g_list->cmds[k].kind == CMD_PERSPECTIVE_POP) {
      nested--;
      if (nested == 0) return k;
    }
  }
  return g_list->count;
}

// ---------------------------------------------------------------------------
// A backdrop filter's result, kept as an image of the box it covers: its own layer.
//
// The filter samples the pixels behind the box, which a frame that repaints only part of the page
// doesn't have fresh. A frame whose damage is inside the box — an animation in a blurred header —
// leaves the backdrop alone, so the filtered result the last full paint made still stands; it is
// kept here and drawn back over the regions the frame repaints. A frame that repainted the box
// filters again and replaces it. (A negative backdrop count in the spec says the runtime knows
// nothing behind the box changed.)

#define MAX_BACKDROPS 8

typedef struct {
  int used;
  int32_t serial;
  double scale;
  long x, y, w, h;   // the device-pixel rect, as the surface's memory measures it
  unsigned char *px; // w * h premultiplied pixels, the filtered backdrop
  unsigned long stamp;
} BackdropImage;

static BackdropImage g_backdrops[MAX_BACKDROPS];
static unsigned long g_backdrop_stamp = 0;

static BackdropImage *backdrop_find(int32_t serial, long bx, long by, long bw, long bh, double scale) {
  for (int i = 0; i < MAX_BACKDROPS; i++) {
    BackdropImage *s = &g_backdrops[i];
    if (s->used && s->serial == serial && s->x == bx && s->y == by && s->w == bw && s->h == bh && s->scale == scale) return s;
  }
  return NULL;
}

/** Draws a kept filtered backdrop where it came from, clipped to what the frame repaints. */
static int backdrop_draw(Replay *r, BackdropImage *s) {
  if (s->px == NULL) return 0;
  cairo_surface_t *img = cairo_image_surface_create_for_data(s->px, CAIRO_FORMAT_ARGB32, (int)s->w,
                                                             (int)s->h, (int)s->w * 4);
  if (cairo_surface_status(img) != CAIRO_STATUS_SUCCESS) {
    cairo_surface_destroy(img);
    return 0;
  }
  cairo_save(r->cr);
  // Device pixels, so the image lands exactly where the filter cut it from whatever the page's
  // transform is; the context's clip keeps it inside the regions being repainted.
  cairo_identity_matrix(r->cr);
  // The kept pixels are a copy of the box, edge to edge: a pixel-exact replace, no antialiased
  // seam with the pixels around it.
  cairo_set_antialias(r->cr, CAIRO_ANTIALIAS_NONE);
  cairo_set_source_surface(r->cr, img, (double)s->x, (double)s->y);
  cairo_set_operator(r->cr, CAIRO_OPERATOR_SOURCE);
  cairo_rectangle(r->cr, (double)s->x, (double)s->y, (double)s->w, (double)s->h);
  cairo_fill(r->cr);
  cairo_restore(r->cr);
  cairo_surface_destroy(img);
  return 1;
}

/** Keeps the filtered backdrop just written, for the frames that repaint only part of the box. */
static void backdrop_store(const Cmd *c, const unsigned char *base, size_t stride, long bx, long by,
                           long bw, long bh, double scale) {
  // A huge box is not worth keeping: the frames that repaint part of it are rare next to its cost.
  if ((double)bw * (double)bh > 2.0 * 1024 * 1024) return;
  BackdropImage *s = backdrop_find(c->serial, bx, by, bw, bh, scale);
  if (s == NULL) {
    // Replace the least recently kept entry; a box that moved or resized is a miss until its
    // filter runs again.
    s = &g_backdrops[0];
    for (int i = 0; i < MAX_BACKDROPS; i++) {
      if (!g_backdrops[i].used) { s = &g_backdrops[i]; break; }
      if (g_backdrops[i].stamp < s->stamp) s = &g_backdrops[i];
    }
    unsigned char *px = (unsigned char *)malloc((size_t)bw * (size_t)bh * 4);
    if (px == NULL) return;
    free(s->px);
    s->px = px;
    s->used = 1;
    s->serial = c->serial;
    s->x = bx;
    s->y = by;
    s->w = bw;
    s->h = bh;
    s->scale = scale;
  }
  s->stamp = ++g_backdrop_stamp;
  for (long y = 0; y < bh; y++) {
    memcpy(s->px + (size_t)y * (size_t)bw * 4, base + (size_t)(by + y) * (size_t)stride + (size_t)bx * 4,
           (size_t)bw * 4);
  }
}

/**
 * A backdrop-filter's work: the pixels already painted in the box's border box are copied out of
 * the destination, filtered, and written back, so the box's own layer then paints over the
 * filtered result. The destination must be an image surface this replay can read.
 *
 * A reused filter — a compositor frame, or a frame the runtime marked as changing nothing behind
 * the box (a negative backdrop count) — draws the result the last real filter left instead, so a
 * frame that repaints part of a blurred panel costs nothing to filter.
 */
static void apply_backdrop(Replay *r, const Cmd *c, const EffectSpec *spec, double scale) {
  if (!r->surface || spec->bcount == 0) return;
  if (cairo_image_surface_get_format(r->surface) != CAIRO_FORMAT_ARGB32) return;
  int bcount = spec->bcount < 0 ? -spec->bcount : spec->bcount;
  int reuse = spec->bcount < 0;
  if (g_reference_paint) reuse = 0;
  cairo_surface_flush(r->surface);
  unsigned char *base = cairo_image_surface_get_data(r->surface);
  int stride = cairo_image_surface_get_stride(r->surface);
  size_t fw = (size_t)cairo_image_surface_get_width(r->surface);
  size_t fh = (size_t)cairo_image_surface_get_height(r->surface);
  if (!base) return;
  double minx = 0, miny = 0, maxx = 0, maxy = 0;
  for (int k = 0; k < 4; k++) {
    double ux = k == 0 || k == 3 ? c->x : c->x + c->w;
    double uy = k < 2 ? c->y : c->y + c->h;
    cairo_matrix_transform_point(&r->base, &ux, &uy);
    if (k == 0 || ux < minx) minx = ux;
    if (k == 0 || uy < miny) miny = uy;
    if (k == 0 || ux > maxx) maxx = ux;
    if (k == 0 || uy > maxy) maxy = uy;
  }
  long bx = (long)floor(minx), by = (long)floor(miny);
  long bw = (long)ceil(maxx) - bx, bh = (long)ceil(maxy) - by;
  if (bw <= 0 || bh <= 0) return;
  if (bx < 0) { bw += bx; bx = 0; }
  if (by < 0) { bh += by; by = 0; }
  if (bx + bw > (long)fw) bw = (long)fw - bx;
  if (by + bh > (long)fh) bh = (long)fh - by;
  if (bw <= 0 || bh <= 0) return;
  long mrow = by;
  if (mrow < 0) mrow = 0;
  // A frame that left the pixels behind the box alone draws the result the last real filter kept:
  // the repainted regions get exactly the backdrop they would have filtered to.
  if (reuse) {
    BackdropImage *kept = backdrop_find(c->serial, bx, by, bw, bh, scale);
    if (kept != NULL && backdrop_draw(r, kept)) return;
  }
  // A blur samples past the box, and the backdrop beyond it isn't the box's to filter: the copy
  // is grown by however far the chain spreads and its edge pixels repeated into that margin.
  long pad = 0;
  for (int i = 0; i < bcount; i++) {
    const FilterOp *op = &spec->bops[i];
    if (op->kind == FK_BLUR) pad += (long)ceil(op->a * scale * 3);
    else if (op->kind == FK_DROP_SHADOW) pad += (long)ceil((fabs(op->dx) + fabs(op->dy) + op->blur * 3) * scale);
  }
  if (pad > 512) pad = 512;
  long pw = bw + 2 * pad, ph2 = bh + 2 * pad;
  if ((double)pw * ph2 > 16.0 * 1024 * 1024) { pad = 0; pw = bw; ph2 = bh; }
  size_t lstride = (size_t)pw * 4;
  unsigned char *buf = (unsigned char *)malloc((size_t)ph2 * lstride);
  if (!buf) return;
  for (long y = 0; y < ph2; y++) {
    long sy = y - pad;
    if (sy < 0) sy = 0;
    if (sy >= bh) sy = bh - 1;
    const unsigned char *src = base + (size_t)(mrow + sy) * (size_t)stride + (size_t)bx * 4;
    unsigned char *dst = buf + (size_t)y * lstride;
    for (long x = 0; x < pw; x++) {
      long sx = x - pad;
      if (sx < 0) sx = 0;
      if (sx >= bw) sx = bw - 1;
      memcpy(dst + (size_t)x * 4, src + (size_t)sx * 4, 4);
    }
  }
  apply_filters(buf, (size_t)pw, (size_t)ph2, lstride, spec->bops, bcount, scale);
  for (long y = 0; y < bh; y++) {
    memcpy(base + (size_t)(mrow + y) * (size_t)stride + (size_t)bx * 4,
           buf + (size_t)(y + pad) * lstride + (size_t)pad * 4, (size_t)bw * 4);
  }
  free(buf);
  backdrop_store(c, base, stride, bx, by, bw, bh, scale);
  cairo_surface_mark_dirty(r->surface);
}

/** Replays one effect layer into a bitmap of its own, filters it, and composites the result. */
static size_t replay_effect(Replay *r, size_t i) {
  Cmd *c = &g_list->cmds[i];
  EffectSpec spec;
  effect_spec_parse(&spec, c->text);
  if (c->alpha_override) spec.alpha = c->alpha;
  // An opacity group with nothing else to it needs no bitmap: a group fades whatever the box
  // paints, however far it reaches past the box, which is what an opacity group is.
  if (spec.alpha < 1 && spec.count == 0 && spec.bcount == 0 && spec.blend == 0) {
    cairo_save(r->cr);
    cairo_push_group(r->cr);
    Replay plain = {r->cr, r->surface, r->base, {0}, 0, 0};
    size_t pop = replay_range(&plain, i + 1);
    cairo_pop_group_to_source(r->cr);
    cairo_paint_with_alpha(r->cr, spec.alpha);
    cairo_restore(r->cr);
    return pop;
  }
  // The filter region is the border box grown by 10% on every side (CSS Filter Effects), mapped
  // through the page's transform into the device pixels the layer is cut from.
  double ex = c->w * 0.1, ey = c->h * 0.1;
  double minx = 0, miny = 0, maxx = 0, maxy = 0;
  for (int k = 0; k < 4; k++) {
    double ux = k == 0 || k == 3 ? c->x - ex : c->x + c->w + ex;
    double uy = k < 2 ? c->y - ey : c->y + c->h + ey;
    cairo_matrix_transform_point(&r->base, &ux, &uy);
    if (k == 0 || ux < minx) minx = ux;
    if (k == 0 || uy < miny) miny = uy;
    if (k == 0 || ux > maxx) maxx = ux;
    if (k == 0 || uy > maxy) maxy = uy;
  }
  double dx = floor(minx), dy = floor(miny);
  double dw = ceil(maxx) - dx, dh = ceil(maxy) - dy;
  double scale = sqrt(fabs(r->base.xx * r->base.yy - r->base.xy * r->base.yx));
  if (!(scale > 0)) scale = 1;
  if (dw * dh > 16.0 * 1024 * 1024) return skip_layer(i);
  if (!(dw > 0 && dh > 0)) {
    // A box with no area has no filter region: what it holds paints plainly.
    Replay plain = {r->cr, r->surface, r->base, {0}, 0, 0};
    return replay_range(&plain, i + 1);
  }
  cairo_surface_t *layer = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, (int)dw, (int)dh);
  if (cairo_surface_status(layer) != CAIRO_STATUS_SUCCESS) {
    cairo_surface_destroy(layer);
    return skip_layer(i);
  }
  cairo_t *lcr = cairo_create(layer);
  cairo_matrix_t shift, sub_base;
  cairo_matrix_init_translate(&shift, -dx, -dy);
  cairo_matrix_multiply(&sub_base, &r->base, &shift);
  cairo_set_matrix(lcr, &sub_base);
  Replay sub = {lcr, layer, sub_base, {0}, 0, 0};
  size_t pop = replay_range(&sub, i + 1);
  cairo_surface_flush(layer);
  unsigned char *px = cairo_image_surface_get_data(layer);
  int stride = cairo_image_surface_get_stride(layer);
  if (px && spec.count > 0) {
    apply_filters(px, (size_t)dw, (size_t)dh, (size_t)stride, spec.ops, spec.count, scale);
    cairo_surface_mark_dirty(layer);
  }
  // What is behind the box is filtered in place before the layer paints over it.
  if (spec.bcount != 0) apply_backdrop(r, c, &spec, scale);
  cairo_destroy(lcr);
  cairo_save(r->cr);
  cairo_identity_matrix(r->cr);
  cairo_set_source_surface(r->cr, layer, dx, dy);
  cairo_pattern_set_filter(cairo_get_source(r->cr), CAIRO_FILTER_NEAREST);
  cairo_set_operator(r->cr, blend_operator(spec.blend));
  cairo_paint_with_alpha(r->cr, spec.alpha);
  cairo_restore(r->cr);
  cairo_surface_destroy(layer);
  return pop;
}

/**
 * Replays a mask layer. The commands from a CMD_MASK_PUSH to its CMD_MASK_SPLIT paint the mask
 * image; the ones from there to CMD_MASK_POP paint the content. Every pixel of the content keeps
 * as much of its alpha as the mask has there, and the result is composited into the page.
 */
static size_t replay_mask(Replay *r, size_t i) {
  Cmd *c = &g_list->cmds[i];
  double minx = 0, miny = 0, maxx = 0, maxy = 0;
  for (int k = 0; k < 4; k++) {
    double ux = k == 0 || k == 3 ? c->x : c->x + c->w;
    double uy = k < 2 ? c->y : c->y + c->h;
    cairo_matrix_transform_point(&r->base, &ux, &uy);
    if (k == 0 || ux < minx) minx = ux;
    if (k == 0 || uy < miny) miny = uy;
    if (k == 0 || ux > maxx) maxx = ux;
    if (k == 0 || uy > maxy) maxy = uy;
  }
  double dx = floor(minx), dy = floor(miny);
  double dw = ceil(maxx) - dx, dh = ceil(maxy) - dy;
  if (dw * dh > 16.0 * 1024 * 1024) return skip_layer(i);
  if (!(dw > 0 && dh > 0)) return skip_layer(i);
  cairo_surface_t *mask = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, (int)dw, (int)dh);
  cairo_surface_t *content = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, (int)dw, (int)dh);
  if (cairo_surface_status(mask) != CAIRO_STATUS_SUCCESS ||
      cairo_surface_status(content) != CAIRO_STATUS_SUCCESS) {
    cairo_surface_destroy(mask);
    cairo_surface_destroy(content);
    return skip_layer(i);
  }
  cairo_matrix_t shift, sub_base;
  cairo_matrix_init_translate(&shift, -dx, -dy);
  cairo_matrix_multiply(&sub_base, &r->base, &shift);
  cairo_t *mcr = cairo_create(mask);
  cairo_set_matrix(mcr, &sub_base);
  Replay mst = {mcr, mask, sub_base, {0}, 0, 0};
  size_t split = replay_range(&mst, i + 1);
  cairo_t *ccr = cairo_create(content);
  cairo_set_matrix(ccr, &sub_base);
  Replay cst = {ccr, content, sub_base, {0}, 0, 0};
  size_t pop = split < g_list->count ? replay_range(&cst, split + 1) : g_list->count;
  cairo_destroy(mcr);
  cairo_destroy(ccr);
  cairo_surface_flush(mask);
  cairo_surface_flush(content);
  unsigned char *cp = cairo_image_surface_get_data(content);
  const unsigned char *mp = cairo_image_surface_get_data(mask);
  if (cp && mp) {
    size_t stride = (size_t)cairo_image_surface_get_stride(content);
    size_t mstride = (size_t)cairo_image_surface_get_stride(mask);
    int A = g_ch_a;
    for (size_t y = 0; y < (size_t)dh; y++) {
      unsigned char *row = cp + y * stride;
      const unsigned char *mrow = mp + y * mstride;
      for (size_t x = 0; x < (size_t)dw; x++) {
        unsigned a = mrow[x * 4 + A];
        if (a == 255) continue;
        unsigned char *p = row + x * 4;
        // The content is premultiplied, so scaling every channel by the mask's coverage is the
        // same as cutting the alpha and leaving the colour alone.
        p[0] = (unsigned char)((p[0] * a + 127) / 255);
        p[1] = (unsigned char)((p[1] * a + 127) / 255);
        p[2] = (unsigned char)((p[2] * a + 127) / 255);
        p[3] = (unsigned char)((p[3] * a + 127) / 255);
      }
    }
    cairo_surface_mark_dirty(content);
  }
  cairo_save(r->cr);
  cairo_identity_matrix(r->cr);
  cairo_set_source_surface(r->cr, content, dx, dy);
  cairo_pattern_set_filter(cairo_get_source(r->cr), CAIRO_FILTER_NEAREST);
  cairo_set_operator(r->cr, CAIRO_OPERATOR_OVER);
  cairo_paint(r->cr);
  cairo_restore(r->cr);
  cairo_surface_destroy(mask);
  cairo_surface_destroy(content);
  return pop;
}

/** The scale a matrix applies to lengths: the square root of the area it maps a unit square to. */
static double matrix_scale(const cairo_matrix_t *m) {
  double s = sqrt(fabs(m->xx * m->yy - m->xy * m->yx));
  return s > 0 ? s : 1;
}

/** A layer a shape paints into before it is composited: its surface, its context and where in the
 *  page's pixels it sits. */
typedef struct {
  cairo_surface_t *surf;
  cairo_t *cr;
  cairo_matrix_t base;
  double x, y, w, h;
  int ok;
} Layer;

/**
 * Starts a layer covering `[ux0, uy0] - [ux1, uy1]` in user space plus `pad` device pixels, cut to
 * the bounds of the replay's own surface. Returns 0 when the box has no pixels to paint.
 */
static int layer_begin(Replay *r, double ux0, double uy0, double ux1, double uy1, double pad, Layer *L) {
  memset(L, 0, sizeof(*L));
  if (!r->surface) return 0;
  int tw = cairo_image_surface_get_width(r->surface), th = cairo_image_surface_get_height(r->surface);
  // A layer is composited in the target's device space, so its bounds come from the transform
  // the content is painted under, not the one the replay started with: a scroll container's
  // translation (or any other transform) moves the box the layer has to hold.
  cairo_matrix_t cur;
  cairo_get_matrix(r->cr, &cur);
  double xs[2] = {ux0, ux1}, ys[2] = {uy0, uy1};
  double x0 = 1e18, y0 = 1e18, x1 = -1e18, y1 = -1e18;
  for (int i = 0; i < 2; i++) {
    for (int j = 0; j < 2; j++) {
      double X = xs[i], Y = ys[j];
      cairo_matrix_transform_point(&cur, &X, &Y);
      if (X < x0) x0 = X;
      if (X > x1) x1 = X;
      if (Y < y0) y0 = Y;
      if (Y > y1) y1 = Y;
    }
  }
  long bx = (long)floor(x0 - pad), by = (long)floor(y0 - pad);
  long ex = (long)ceil(x1 + pad), ey = (long)ceil(y1 + pad);
  if (bx < 0) bx = 0;
  if (by < 0) by = 0;
  if (ex > tw) ex = tw;
  if (ey > th) ey = th;
  if (ex - bx <= 0 || ey - by <= 0) return 0;
  L->surf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, (int)(ex - bx), (int)(ey - by));
  if (cairo_surface_status(L->surf) != CAIRO_STATUS_SUCCESS) {
    cairo_surface_destroy(L->surf);
    L->surf = NULL;
    return 0;
  }
  L->cr = cairo_create(L->surf);
  cairo_matrix_t shift;
  cairo_matrix_init_translate(&shift, -(double)bx, -(double)by);
  // Apply the content's transform first, then the layer's own origin shift.
  cairo_matrix_multiply(&L->base, &cur, &shift);
  cairo_set_matrix(L->cr, &L->base);
  L->x = (double)bx;
  L->y = (double)by;
  L->w = (double)(ex - bx);
  L->h = (double)(ey - by);
  L->ok = 1;
  return 1;
}

/** Composites a finished layer into the replay's target. */
static void layer_end(Layer *L, Replay *r, double alpha, cairo_operator_t op) {
  if (!L->ok) return;
  cairo_surface_flush(L->surf);
  if (L->cr) {
    cairo_destroy(L->cr);
    L->cr = NULL;
  }
  cairo_save(r->cr);
  cairo_identity_matrix(r->cr);
  cairo_set_source_surface(r->cr, L->surf, L->x, L->y);
  cairo_pattern_set_filter(cairo_get_source(r->cr), CAIRO_FILTER_NEAREST);
  cairo_set_operator(r->cr, op);
  cairo_paint_with_alpha(r->cr, alpha);
  cairo_restore(r->cr);
  cairo_surface_destroy(L->surf);
  L->surf = NULL;
  L->ok = 0;
}

/** Blurs a layer's pixels by a CSS blur radius, measured in user units. */
static void layer_blur(Layer *L, double sigma) {
  if (!L->ok || !(sigma > 0)) return;
  cairo_surface_flush(L->surf);
  unsigned char *px = cairo_image_surface_get_data(L->surf);
  if (!px) return;
  gauss_blur(px, (size_t)L->w, (size_t)L->h, (size_t)cairo_image_surface_get_stride(L->surf), sigma);
  cairo_surface_mark_dirty(L->surf);
}

// A box a perspective ancestor projects. The commands up to the pop paint the box where the page
// lays it out, into a bitmap of its own, and the bitmap is warped onto the quad. A planar quad's
// projection is a homography, so every pixel inside the quad finds the point of the box that lands
// on it and samples the bitmap there.

typedef struct { double m[9]; } Homography;

/** The homography that takes the unit square's corners, (0,0), (1,0), (1,1), (0,1), to `q`. */
static int homography_unit_square_to_quad(const double q[8], Homography *h) {
  double x0 = q[0], y0 = q[1], x1 = q[2], y1 = q[3];
  double x2 = q[4], y2 = q[5], x3 = q[6], y3 = q[7];
  double dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3;
  double dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3;
  double den = dx1 * dy2 - dx2 * dy1;
  // A quad with no area, which is a plane seen edge on, has no projection to draw.
  if (fabs(den) < 1e-12) return 0;
  double a13 = (dx3 * dy2 - dx2 * dy3) / den;
  double a23 = (dx1 * dy3 - dx3 * dy1) / den;
  h->m[0] = x1 - x0 + a13 * x1;
  // The second column comes from the bottom left corner, which is where v = 1 puts the left edge.
  h->m[1] = x3 - x0 + a23 * x3;
  h->m[2] = x0;
  h->m[3] = y1 - y0 + a13 * y1;
  h->m[4] = y3 - y0 + a23 * y3;
  h->m[5] = y0;
  h->m[6] = a13;
  h->m[7] = a23;
  h->m[8] = 1;
  return 1;
}

/** The homography that undoes `h`, so a point of the quad reads back to a point of the box. */
static int homography_invert(const Homography *h, Homography *inv) {
  const double *m = h->m;
  double c0 = m[4] * m[8] - m[5] * m[7];
  double c1 = m[5] * m[6] - m[3] * m[8];
  double c2 = m[3] * m[7] - m[4] * m[6];
  double det = m[0] * c0 + m[1] * c1 + m[2] * c2;
  if (fabs(det) < 1e-12) return 0;
  double s = 1 / det;
  inv->m[0] = c0 * s;
  inv->m[1] = (m[2] * m[7] - m[1] * m[8]) * s;
  inv->m[2] = (m[1] * m[5] - m[2] * m[4]) * s;
  inv->m[3] = c1 * s;
  inv->m[4] = (m[0] * m[8] - m[2] * m[6]) * s;
  inv->m[5] = (m[2] * m[3] - m[0] * m[5]) * s;
  inv->m[6] = c2 * s;
  inv->m[7] = (m[1] * m[6] - m[0] * m[7]) * s;
  inv->m[8] = (m[0] * m[4] - m[1] * m[3]) * s;
  return 1;
}

/** A layer pixel at (x, y), interpolated between the four around it; the edges hold. */
static void sample_layer(const unsigned char *px, int stride, int w, int h, double x, double y,
                         double out[4]) {
  double fx = x - 0.5, fy = y - 0.5;
  if (fx < 0) fx = 0;
  if (fy < 0) fy = 0;
  if (fx > w - 1) fx = w - 1;
  if (fy > h - 1) fy = h - 1;
  int x0 = (int)fx, y0 = (int)fy;
  int x1 = x0 + 1 < w ? x0 + 1 : x0;
  int y1 = y0 + 1 < h ? y0 + 1 : y0;
  double wx = fx - x0, wy = fy - y0;
  const unsigned char *p00 = px + (size_t)y0 * (size_t)stride + (size_t)x0 * 4;
  const unsigned char *p10 = px + (size_t)y0 * (size_t)stride + (size_t)x1 * 4;
  const unsigned char *p01 = px + (size_t)y1 * (size_t)stride + (size_t)x0 * 4;
  const unsigned char *p11 = px + (size_t)y1 * (size_t)stride + (size_t)x1 * 4;
  for (int k = 0; k < 4; k++) {
    double top = p00[k] + (p10[k] - p00[k]) * wx;
    double bot = p01[k] + (p11[k] - p01[k]) * wx;
    out[k] = top + (bot - top) * wy;
  }
}

/** Replays a perspective layer into a bitmap and warps it onto the quad. */
static size_t replay_perspective(Replay *r, size_t i) {
  const Cmd *c = &g_list->cmds[i];
  Layer L;
  // The bitmap covers the box before projection, cut from the page's device pixels.
  if (!layer_begin(r, c->x, c->y, c->x + c->w, c->y + c->h, 0, &L)) return skip_layer(i);
  Replay sub = {L.cr, L.surf, L.base, {0}, 0, 0};
  size_t pop = replay_range(&sub, i + 1);
  // The quad in device pixels, which is the space the warp is worked out in.
  double q[8];
  for (int k = 0; k < 4; k++) {
    double X = c->q[k * 2], Y = c->q[k * 2 + 1];
    cairo_matrix_transform_point(&r->base, &X, &Y);
    q[k * 2] = X;
    q[k * 2 + 1] = Y;
  }
  Homography fwd, inv;
  if (homography_unit_square_to_quad(q, &fwd) && homography_invert(&fwd, &inv)) {
    int tw = cairo_image_surface_get_width(r->surface);
    int th = cairo_image_surface_get_height(r->surface);
    double minx = q[0], maxx = q[0], miny = q[1], maxy = q[1];
    for (int k = 1; k < 4; k++) {
      minx = fmin(minx, q[k * 2]);
      maxx = fmax(maxx, q[k * 2]);
      miny = fmin(miny, q[k * 2 + 1]);
      maxy = fmax(maxy, q[k * 2 + 1]);
    }
    // The warped pixels go into a bitmap of the quad's own, which is then composited as one.
    long bx = (long)floor(minx), by = (long)floor(miny);
    long ex = (long)ceil(maxx) + 1, ey = (long)ceil(maxy) + 1;
    if (bx < 0) bx = 0;
    if (by < 0) by = 0;
    if (ex > tw) ex = tw;
    if (ey > th) ey = th;
    long dw = ex - bx, dh = ey - by;
    if (dw > 0 && dh > 0 && (double)dw * (double)dh <= 32.0 * 1024 * 1024) {
      cairo_surface_flush(L.surf);
      const unsigned char *src = cairo_image_surface_get_data(L.surf);
      int sstride = cairo_image_surface_get_stride(L.surf);
      int sw = (int)L.w, sh = (int)L.h;
      cairo_surface_t *dest = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, (int)dw, (int)dh);
      if (src && cairo_surface_status(dest) == CAIRO_STATUS_SUCCESS) {
        cairo_surface_flush(dest);
        unsigned char *px = cairo_image_surface_get_data(dest);
        int dstride = cairo_image_surface_get_stride(dest);
        for (long py = 0; py < dh; py++) {
          unsigned char *row = px + (size_t)py * (size_t)dstride;
          for (long px_i = 0; px_i < dw; px_i++) {
            double acc[4] = {0, 0, 0, 0};
            // Four samples a pixel, so the quad's edge keeps the share of it that falls inside.
            for (int k = 0; k < 4; k++) {
              double X = (double)bx + (double)px_i + (k & 1 ? 0.75 : 0.25);
              double Y = (double)by + (double)py + (k & 2 ? 0.75 : 0.25);
              double den = inv.m[6] * X + inv.m[7] * Y + inv.m[8];
              // A point at or behind the plane the quad lies on has no box point to read.
              if (!(den > 1e-9)) continue;
              double u = (inv.m[0] * X + inv.m[1] * Y + inv.m[2]) / den;
              double v = (inv.m[3] * X + inv.m[4] * Y + inv.m[5]) / den;
              if (u < 0 || u > 1 || v < 0 || v > 1) continue;
              double XS = c->x + u * c->w, YS = c->y + v * c->h;
              cairo_matrix_transform_point(&r->base, &XS, &YS);
              double s[4];
              sample_layer(src, sstride, sw, sh, XS - L.x, YS - L.y, s);
              for (int ch = 0; ch < 4; ch++) acc[ch] += s[ch];
            }
            for (int ch = 0; ch < 4; ch++) {
              double v2 = acc[ch] * 0.25 + 0.5;
              row[(size_t)px_i * 4 + ch] = (unsigned char)(v2 > 255 ? 255 : v2);
            }
          }
        }
        cairo_surface_mark_dirty(dest);
        cairo_save(r->cr);
        cairo_identity_matrix(r->cr);
        cairo_set_source_surface(r->cr, dest, bx, by);
        cairo_pattern_set_filter(cairo_get_source(r->cr), CAIRO_FILTER_NEAREST);
        cairo_set_operator(r->cr, CAIRO_OPERATOR_OVER);
        cairo_paint(r->cr);
        cairo_restore(r->cr);
      }
      cairo_surface_destroy(dest);
    }
  }
  if (L.cr) {
    cairo_destroy(L.cr);
    L.cr = NULL;
  }
  cairo_surface_destroy(L.surf);
  L.surf = NULL;
  return pop;
}

/** The scale factor of the transform the content is painted under, for blur radii, which are in
 *  user units. */
static double current_scale(Replay *r) {
  cairo_matrix_t m;
  cairo_get_matrix(r->cr, &m);
  return sqrt(fabs(m.xx * m.yy - m.xy * m.yx));
}

/**
 * An outer box-shadow: the border box grown by the spread, moved by the offset and, when it has a
 * blur, blurred; the border box itself is then cleared back out, as an outer shadow is clipped
 * inside the box it belongs to.
 */
static void paint_outer_shadow(Replay *r, const Cmd *c) {
  double s = c->line_width;
  double grown[8];
  for (int k = 0; k < 8; k += 2) {
    double cov = shadow_coverage(c->r[k], c->r[k + 1], c->w, c->h);
    grown[k] = spread_radius(c->r[k], s, cov);
    grown[k + 1] = spread_radius(c->r[k + 1], s, cov);
  }
  const int hard = !(c->blur > 0);
  const int square = square_radii(grown);
  double sx = c->x - s + c->dx, sy = c->y - s + c->dy;
  double pad = hard ? 1 : c->blur * 3 * current_scale(r) + 1;
  Layer L;
  if (!layer_begin(r, fmin(sx, c->x), fmin(sy, c->y), fmax(sx + c->w + 2 * s, c->x + c->w),
                   fmax(sy + c->h + 2 * s, c->y + c->h), pad, &L))
    return;
  cairo_new_path(L.cr);
  if (square) {
    Box b = snapped_for_ctm(L.cr, sx, sy, c->w + 2 * s, c->h + 2 * s, r->transforms > 0);
    set_fill(L.cr, c->color);
    fill_box_clamped(L.cr, b);
  } else {
    round_path(L.cr, sx, sy, c->w + 2 * s, c->h + 2 * s, grown);
    set_fill(L.cr, c->color);
    cairo_fill(L.cr);
  }
  if (!hard) layer_blur(&L, c->blur * current_scale(r) / 2);
  // Punch the border box back out: the shadow only shows outside it.
  cairo_new_path(L.cr);
  if (square_radii(c->r)) {
    Box punch = snapped_for_ctm(L.cr, c->x, c->y, c->w, c->h, r->transforms > 0);
    if (punch.w > 0 && punch.h > 0) {
      cairo_set_operator(L.cr, CAIRO_OPERATOR_CLEAR);
      cairo_rectangle(L.cr, punch.x, punch.y, punch.w, punch.h);
      cairo_fill(L.cr);
      cairo_set_operator(L.cr, CAIRO_OPERATOR_OVER);
    }
  } else {
    round_path(L.cr, c->x, c->y, c->w, c->h, c->r);
    cairo_set_operator(L.cr, CAIRO_OPERATOR_CLEAR);
    cairo_fill(L.cr);
    cairo_set_operator(L.cr, CAIRO_OPERATOR_OVER);
  }
  layer_end(&L, r, 1, CAIRO_OPERATOR_OVER);
}

/**
 * An inset box-shadow: the padding box tinted with the colour, then everything inside the inset
 * shape cut back out of it, blurred and moved by the offset. What remains is the shadow.
 */
static void paint_inset_shadow(Replay *r, const Cmd *c) {
  double s = c->line_width;
  double in[8];
  for (int k = 0; k < 8; k++) in[k] = inset_radius(c->r[k], s);
  const int hard = !(c->blur > 0);
  double pad = hard ? 1 : c->blur * 3 * current_scale(r) + 1;
  Layer L;
  if (!layer_begin(r, c->x, c->y, c->x + c->w, c->y + c->h, pad, &L)) return;
  set_fill(L.cr, c->color);
  if (square_radii(c->r)) {
    Box b = snapped_for_ctm(L.cr, c->x, c->y, c->w, c->h, r->transforms > 0);
    fill_box_clamped(L.cr, b);
  } else {
    round_path(L.cr, c->x, c->y, c->w, c->h, c->r);
    cairo_fill(L.cr);
  }
  double hx = c->x + s + c->dx, hy = c->y + s + c->dy, hw = c->w - 2 * s, hh = c->h - 2 * s;
  if (hard) {
    cairo_set_operator(L.cr, CAIRO_OPERATOR_CLEAR);
    cairo_new_path(L.cr);
    if (square_radii(in)) {
      Box hole = snapped_for_ctm(L.cr, hx, hy, hw, hh, r->transforms > 0);
      if (hole.w > 0 && hole.h > 0) {
        cairo_rectangle(L.cr, hole.x, hole.y, hole.w, hole.h);
        cairo_fill(L.cr);
      }
    } else {
      round_path(L.cr, hx, hy, hw, hh, in);
      cairo_fill(L.cr);
    }
    cairo_set_operator(L.cr, CAIRO_OPERATOR_OVER);
  } else {
    // The shape that casts the shadow is cut out of the tint, so it is painted into a bitmap of
    // its own and blurred there, then its coverage is taken away from the tint.
    cairo_surface_t *mask = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, (int)L.w, (int)L.h);
    if (cairo_surface_status(mask) == CAIRO_STATUS_SUCCESS) {
      cairo_t *mcr = cairo_create(mask);
      if (square_radii(in)) {
        Box hm = snapped_for_ctm(mcr, hx, hy, hw, hh, r->transforms > 0);
        cairo_set_source_rgba(mcr, 1, 1, 1, 1);
        if (hm.w > 0 && hm.h > 0) {
          cairo_rectangle(mcr, hm.x, hm.y, hm.w, hm.h);
          cairo_fill(mcr);
        }
      } else {
        round_path(mcr, hx, hy, hw, hh, in);
        cairo_set_source_rgba(mcr, 1, 1, 1, 1);
        cairo_fill(mcr);
      }
      cairo_destroy(mcr);
      cairo_surface_flush(mask);
      unsigned char *mp = cairo_image_surface_get_data(mask);
      gauss_blur(mp, (size_t)L.w, (size_t)L.h, (size_t)cairo_image_surface_get_stride(mask),
                 c->blur * current_scale(r) / 2);
      cairo_surface_flush(L.surf);
      unsigned char *lp = cairo_image_surface_get_data(L.surf);
      if (mp && lp) {
        size_t lstride = (size_t)cairo_image_surface_get_stride(L.surf);
        size_t mstride = (size_t)cairo_image_surface_get_stride(mask);
        int A = g_ch_a;
        for (size_t y = 0; y < (size_t)L.h; y++) {
          unsigned char *row = lp + y * lstride;
          const unsigned char *mrow = mp + y * mstride;
          for (size_t x = 0; x < (size_t)L.w; x++) {
            unsigned a = mrow[x * 4 + A];
            if (a == 0) continue;
            unsigned char *p = row + x * 4;
            unsigned keep = 255 - a;
            p[0] = (unsigned char)((p[0] * keep + 127) / 255);
            p[1] = (unsigned char)((p[1] * keep + 127) / 255);
            p[2] = (unsigned char)((p[2] * keep + 127) / 255);
            p[3] = (unsigned char)((p[3] * keep + 127) / 255);
          }
        }
        cairo_surface_mark_dirty(L.surf);
      }
      cairo_surface_destroy(mask);
    }
  }
  layer_end(&L, r, 1, CAIRO_OPERATOR_OVER);
}

/** Sets both fill and alpha for a flat colour: a gradient command's own alpha on a flat fill. */
static void set_fill_alpha(cairo_t *cr, uint32_t c, double alpha) {
  cairo_set_source_rgba(cr, ((c >> 24) & 255) / 255.0, ((c >> 16) & 255) / 255.0,
                        ((c >> 8) & 255) / 255.0, ((c & 255) / 255.0) * alpha);
}

// The canvas's bitmap in the display list: its own pixels, scaled into the page.
static void canvas_paint(cairo_t *cr, const Cmd *c);

/**
 * Replays the list from `i` into the replay's target, stopping at the command that closes the
 * layer this range belongs to. Returns the index of that command, or the end of the list.
 */
static size_t replay_range(Replay *r, size_t i) {
  for (; i < g_list->count && i < g_replay_limit; i++) {
    Cmd *c = &g_list->cmds[i];
    cairo_t *cr = r->cr;
    if (c->kind == CMD_EFFECT_POP || c->kind == CMD_MASK_SPLIT || c->kind == CMD_MASK_POP ||
        c->kind == CMD_PERSPECTIVE_POP) return i;
    if (c->kind == CMD_EFFECT_PUSH) {
      i = replay_effect(r, i);
      continue;
    }
    if (c->kind == CMD_MASK_PUSH) {
      i = replay_mask(r, i);
      continue;
    }
    if (c->kind == CMD_PERSPECTIVE_PUSH) {
      i = replay_perspective(r, i);
      continue;
    }
    if (c->kind == CMD_LAYER_REF) {
      if (g_rasters != NULL) {
        if (c->layer >= 0 && c->layer < g_raster_count) draw_layer_raster(cr, &g_rasters[c->layer]);
        continue;
      }
      CmdList *saved = g_list;
      if (c->layer >= 0 && c->layer < g_layer_count) {
        g_list = &g_layers[c->layer].list;
        replay_range(r, 0);
      }
      g_list = saved;
      continue;
    }
    if (c->kind == CMD_FILL) {
      set_fill(cr, c->color);
      if (c->radius > 0) {
        Box b = snapped_for_ctm(cr, c->x, c->y, c->w, c->h, r->transforms > 0);
        cairo_new_path(cr);
        rounded_rect_path(cr, b.x, b.y, b.w, b.h, c->radius);
        cairo_fill(cr);
      } else {
        Box b = snapped_for_ctm(cr, c->x, c->y, c->w, c->h, r->transforms > 0);
        cairo_new_path(cr);
        fill_box_clamped(cr, b);
      }
    } else if (c->kind == CMD_FILL_ROUND) {
      set_fill(cr, c->color);
      cairo_new_path(cr);
      round_path(cr, c->x, c->y, c->w, c->h, c->r);
      cairo_fill(cr);
    } else if (c->kind == CMD_RING_ROUND) {
      set_fill(cr, c->color);
      cairo_new_path(cr);
      round_path(cr, c->x, c->y, c->w, c->h, c->r);
      inner_round_path(cr, c->x, c->y, c->w, c->h, c->r, c->line_width);
      cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD);
      cairo_fill(cr);
      cairo_set_fill_rule(cr, CAIRO_FILL_RULE_WINDING);
    } else if (c->kind == CMD_SHADOW) {
      paint_outer_shadow(r, c);
    } else if (c->kind == CMD_SHADOW_INSET) {
      paint_inset_shadow(r, c);
    } else if (c->kind == CMD_CLIP_ELLIPSE) {
      cairo_save(cr);
      if (r->depth < 1024) r->saved[r->depth++] = 0;
      cairo_new_path(cr);
      if (c->p2 > 0 && c->p3 > 0) {
        cairo_save(cr);
        cairo_translate(cr, c->p0, c->p1);
        cairo_scale(cr, c->p2, c->p3);
        cairo_arc(cr, 0, 0, 1, 0, 2 * M_PI);
        cairo_restore(cr);
        cairo_clip(cr);
      } else {
        // A circle or ellipse with no radius clips everything away.
        cairo_rectangle(cr, c->p0, c->p1, 0, 0);
        cairo_clip(cr);
      }
    } else if (c->kind == CMD_CLIP_SHAPE) {
      cairo_save(cr);
      if (r->depth < 1024) r->saved[r->depth++] = 0;
      cairo_new_path(cr);
      poly_path(cr, c->text, 0, 0);
      cairo_set_fill_rule(cr, c->p0 != 0 ? CAIRO_FILL_RULE_EVEN_ODD : CAIRO_FILL_RULE_WINDING);
      cairo_clip(cr);
      cairo_set_fill_rule(cr, CAIRO_FILL_RULE_WINDING);
    } else if (c->kind == CMD_CLIP_ROUND) {
      cairo_save(cr);
      if (r->depth < 1024) r->saved[r->depth++] = 0;
      cairo_new_path(cr);
      round_path(cr, c->x, c->y, c->w, c->h, c->r);
      cairo_clip(cr);
    } else if (c->kind == CMD_RING) {
      set_fill(cr, c->color);
      double b = c->line_width;
      cairo_new_path(cr);
      rounded_rect_path(cr, c->x, c->y, c->w, c->h, c->radius);
      rounded_rect_path(cr, c->x + b, c->y + b, c->w - 2 * b, c->h - 2 * b, c->radius - b);
      cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD);
      cairo_fill(cr);
      cairo_set_fill_rule(cr, CAIRO_FILL_RULE_WINDING);
    } else if (c->kind == CMD_LINE) {
      double x0 = c->x, span = c->w, y = c->y, t = c->line_width;
      int style = (int)c->radius;
      double x1 = x0 + span;
      if (span > 0 && t > 0) {
        if (style == 1) {
          // Double: two thirds-thick lines, a third apart.
          double part = t / 3;
          set_fill(cr, c->color);
          Box a = snapped_for_ctm(cr, x0, y, span, part, r->transforms > 0);
          Box b = snapped_for_ctm(cr, x0, y + 2 * part, span, part, r->transforms > 0);
          cairo_new_path(cr);
          fill_box_clamped(cr, a);
          cairo_new_path(cr);
          fill_box_clamped(cr, b);
        } else if (style == 2) {
          // Dotted: squares as wide as the line is thick, one square apart.
          set_fill(cr, c->color);
          for (double x = x0; x < x1; x += 2 * t) {
            double w = fmin(t, x1 - x);
            Box b = snapped_for_ctm(cr, x, y, w, t, r->transforms > 0);
            cairo_new_path(cr);
            fill_box_clamped(cr, b);
          }
        } else if (style == 3) {
          // Dashed: three thicknesses on, two off.
          set_fill(cr, c->color);
          for (double x = x0; x < x1; x += 5 * t) {
            double w = fmin(3 * t, x1 - x);
            Box b = snapped_for_ctm(cr, x, y, w, t, r->transforms > 0);
            cairo_new_path(cr);
            fill_box_clamped(cr, b);
          }
        } else if (style == 4) {
          // Wavy: a sine wave, stroked with the line's own thickness.
          double amp = t, period = fmax(8, 4 * t);
          cairo_save(cr);
          set_fill(cr, c->color);
          cairo_set_line_width(cr, t);
          cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
          cairo_new_path(cr);
          for (double x = x0;; x += 1) {
            double xx = x > x1 ? x1 : x;
            double yy = y + t / 2 + amp * sin(2 * M_PI * (xx - x0) / period);
            if (xx == x0) cairo_move_to(cr, xx, yy);
            else cairo_line_to(cr, xx, yy);
            if (xx >= x1) break;
          }
          cairo_stroke(cr);
          cairo_restore(cr);
        } else {
          set_fill(cr, c->color);
          Box b = snapped_for_ctm(cr, x0, y, span, t, r->transforms > 0);
          cairo_new_path(cr);
          fill_box_clamped(cr, b);
        }
      }
    } else if (c->kind == CMD_POLY) {
      set_fill(cr, c->color);
      cairo_new_path(cr);
      poly_path(cr, c->text, r->transforms > 0, 1);
      cairo_fill(cr);
    } else if (c->kind == CMD_CLIP_POLY) {
      cairo_save(cr);
      if (r->depth < 1024) r->saved[r->depth++] = 0;
      cairo_new_path(cr);
      poly_path(cr, c->text, r->transforms > 0, 1);
      cairo_clip(cr);
    } else if (c->kind == CMD_CLIP) {
      cairo_save(cr);
      if (r->depth < 1024) r->saved[r->depth++] = 0;
      // Clips without a radius are snapped along with the fills they contain: a clip edge that
      // falls mid-pixel would otherwise let the antialiased remainder of a rounded fill through.
      Box clip = c->radius > 0 ? (Box){c->x, c->y, c->w, c->h}
                               : snapped_for_ctm(cr, c->x, c->y, c->w, c->h, r->transforms > 0);
      cairo_new_path(cr);
      rounded_rect_path(cr, clip.x, clip.y, clip.w, clip.h, c->radius);
      cairo_clip(cr);
    } else if (c->kind == CMD_TRANSFORM) {
      cairo_save(cr);
      // A scroll container's translation is not a transform for snapping: its content snaps in
      // the page's own space, exactly where it snapped when the offset was painted into the
      // coordinates. Every other transform keeps the device-space snapping it has.
      int scroll = c->pkind == CMD_PK_SCROLL;
      if (r->depth < 1024) r->saved[r->depth++] = scroll ? 0 : 1;
      if (!scroll) r->transforms++;
      cairo_matrix_t m;
      m.xx = c->p0; m.yx = c->p1; m.xy = c->p2; m.yy = c->p3; m.x0 = c->r[0]; m.y0 = c->r[1];
      cairo_transform(cr, &m);
    } else if (c->kind == CMD_UNCLIP) {
      if (r->depth > 0 && r->saved[--r->depth]) r->transforms--;
      cairo_restore(cr);
    } else if (c->kind == CMD_IMAGE) {
      cairo_surface_t *surf = image_surface(c->image);
      if (surf && c->image >= 0 && c->image < g_image_count) {
        Image *img = &g_images[c->image];
        double sx = c->sx, sy = c->sy, sw = c->sw, sh = c->sh;
        if (!(sw > 0 && sh > 0)) {
          sx = 0;
          sy = 0;
          sw = img->w;
          sh = img->h;
        }
        draw_surface_part(cr, surf, c->x, c->y, c->w, c->h, sx, sy, sw, sh, c->size, c->smooth);
      }
    } else if (c->kind == CMD_VIDEO) {
#ifndef NATIVE_NO_FFMPEG
      Video *v = video_at(c->image);
      if (v != NULL && v->rgba != NULL) {
        video_advance(v, video_clock(v));
        if (v->have_frame) {
          cairo_surface_t *surf = cairo_image_surface_create_for_data(v->rgba, CAIRO_FORMAT_ARGB32, v->w, v->h, v->w * 4);
          if (cairo_surface_status(surf) == CAIRO_STATUS_SUCCESS) {
            cairo_save(cr);
            cairo_translate(cr, c->x, c->y);
            cairo_scale(cr, c->w / v->w, c->h / v->h);
            cairo_set_source_surface(cr, surf, 0, 0);
            cairo_paint_with_alpha(cr, c->size);
            cairo_restore(cr);
          }
          cairo_surface_destroy(surf);
        }
      }
#endif
    } else if (c->kind == CMD_CANVAS) {
      canvas_paint(cr, c);
    } else if (c->kind == CMD_GRADIENT_CONIC) {
      Stops st;
      if (parse_stops(c->text, &st) >= 2) {
        uint32_t flat;
        if (stops_flat(&st, &flat)) {
          set_fill_alpha(cr, flat, c->size);
          Box b = snapped_rect(c->x, c->y, c->w, c->h);
          cairo_new_path(cr);
          fill_box_clamped(cr, b);
        } else {
          paint_conic(cr, c, &st, c->size);
        }
      }
    } else if (c->kind == CMD_GRADIENT_LINEAR || c->kind == CMD_GRADIENT_RADIAL) {
      Stops st;
      if (parse_stops(c->text, &st) >= 2) {
        cairo_save(cr);
        cairo_new_path(cr);
        Box clip = snapped_for_ctm(cr, c->x, c->y, c->w, c->h, r->transforms > 0);
        cairo_rectangle(cr, clip.x, clip.y, clip.w, clip.h);
        cairo_clip(cr);
        cairo_pattern_t *pat;
        if (c->kind == CMD_GRADIENT_LINEAR) {
          pat = gradient_pattern(&st, 0, c->p0, c->p1, 0, c->p2, c->p3, 0);
        } else {
          // An ellipse is a circle under a non-uniform scale about the centre.
          cairo_translate(cr, c->p0, c->p1);
          double rx = c->p2 > 0 ? c->p2 : 0, ry = c->p3 > 0 ? c->p3 : 0;
          cairo_scale(cr, 1, rx > 0 ? ry / rx : 0);
          pat = gradient_pattern(&st, 1, 0, 0, 0, 0, 0, rx);
        }
        if (pat) {
          cairo_set_source(cr, pat);
          cairo_paint_with_alpha(cr, c->size);
          cairo_pattern_destroy(pat);
        }
        cairo_restore(cr);
      }
    } else if (c->kind == CMD_TEXT) {
      paint_text(cr, c, 0);
    } else if (c->kind == CMD_TEXT_SHADOW) {
      paint_text(cr, c, 1);
    }
  }
  return i;
}

/** Replays the display list into a context whose user space is top-left origin, y down. */
static void replay(Replay *r, cairo_t *cr, cairo_surface_t *surface, double width, double height) {
  // The frame is the root list; every layer hangs off a ref inside it.
  g_list = &g_root;
  ensure_channels();
  memset(r, 0, sizeof(*r));
  r->cr = cr;
  r->surface = surface;
  cairo_get_matrix(cr, &r->base);
  const int region = g_present_region && g_damage_count > 0;
  if (region) {
    cairo_save(cr);
    cairo_new_path(cr);
    for (int i = 0; i < g_damage_count; i++) {
      const double *rr = g_damage_rects[i];
      cairo_rectangle(cr, rr[0], rr[1], rr[2], rr[3]);
    }
    cairo_clip(cr);
    set_fill(cr, g_background);
    for (int i = 0; i < g_damage_count; i++) {
      const double *rr = g_damage_rects[i];
      cairo_rectangle(cr, rr[0], rr[1], rr[2], rr[3]);
      cairo_fill(cr);
    }
  } else if (!g_skip_background) {
    set_fill(cr, g_background);
    cairo_new_path(cr);
    cairo_rectangle(cr, 0, 0, width, height);
    cairo_fill(cr);
  }
  replay_range(r, 0);
  if (region) cairo_restore(cr);
}

// ---------------------------------------------------------------------------
// Damage verification (NATIVE_VERIFY_DAMAGE)
//
// The painter records a flat reference frame, then the damaged list. The damaged list is
// replayed over a copy of the reference and compared with it inside the damaged rectangles, so a
// frame that missed part of its damage shows up as differing pixels.

static unsigned char *g_verify_px = NULL;
static int g_verify_w = 0, g_verify_h = 0, g_verify_stride = 0;
/** The pixels the last presented frame left, the base a damaged frame is replayed over. */
static unsigned char *g_prev_px = NULL;
static int g_prev_w = 0, g_prev_h = 0, g_prev_stride = 0;

static cairo_surface_t *damage_raster(double width, double height);
static int verify_enabled(void) { return getenv("NATIVE_VERIFY_DAMAGE") != NULL; }

/** Rasters the list now recorded into a new ARGB32 surface at scale 1. */
static cairo_surface_t *damage_raster(double width, double height) {
  int pw = (int)ceil(width), ph = (int)ceil(height);
  if (pw <= 0 || ph <= 0 || pw > 16384 || ph > 16384) return NULL;
  cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, pw, ph);
  if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
    cairo_surface_destroy(surface);
    return NULL;
  }
  cairo_t *cr = cairo_create(surface);
  if (cairo_status(cr) != CAIRO_STATUS_SUCCESS) {
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    return NULL;
  }
  double saved = g_scale;
  // A reference or a damaged list draws its layers' commands, not a raster from an older frame.
  LayerRaster *saved_rasters = g_rasters;
  g_rasters = NULL;
  g_scale = 1;
  // A reference frame is thrown away after its comparison: it neither keeps a filtered backdrop
  // nor reuses one.
  g_reference_paint = 1;
  Replay r;
  replay(&r, cr, surface, width, height);
  g_reference_paint = 0;
  g_scale = saved;
  g_rasters = saved_rasters;
  cairo_destroy(cr);
  cairo_surface_flush(surface);
  return surface;
}

/** Keeps a full frame's pixels as the base a later damaged frame is replayed over. */
static void verify_capture_full(double width, double height) {
  cairo_surface_t *surface = damage_raster(width, height);
  if (surface == NULL) return;
  int w = cairo_image_surface_get_width(surface), h = cairo_image_surface_get_height(surface);
  int stride = cairo_image_surface_get_stride(surface);
  free(g_prev_px);
  g_prev_px = (unsigned char *)malloc((size_t)stride * (size_t)h);
  if (g_prev_px != NULL) {
    memcpy(g_prev_px, cairo_image_surface_get_data(surface), (size_t)stride * (size_t)h);
    g_prev_w = w;
    g_prev_h = h;
    g_prev_stride = stride;
  }
  cairo_surface_destroy(surface);
}

void host_damage_reference(double width, double height) {
  free(g_verify_px);
  g_verify_px = NULL;
  g_verify_w = g_verify_h = g_verify_stride = 0;
  cairo_surface_t *surface = damage_raster(width, height);
  if (surface == NULL) return;
  g_verify_w = cairo_image_surface_get_width(surface);
  g_verify_h = cairo_image_surface_get_height(surface);
  g_verify_stride = cairo_image_surface_get_stride(surface);
  size_t bytes = (size_t)g_verify_stride * (size_t)g_verify_h;
  g_verify_px = (unsigned char *)malloc(bytes);
  if (g_verify_px != NULL) memcpy(g_verify_px, cairo_image_surface_get_data(surface), bytes);
  cairo_surface_destroy(surface);
}

/** No chunked compositor on this host: a damaged frame paints fully instead of patching. */
int32_t host_damage_can_merge(const uint8_t *serials, size_t n, const uint8_t *rects, size_t m) {
  (void)serials; (void)n; (void)rects; (void)m;
  return 0;
}

int32_t host_verify_damage(const uint8_t *rects, size_t n, double width, double height) {
  parse_damage_rects(rects, n);
  if (g_verify_px == NULL) {
    fprintf(stderr, "native: damage verify no reference\n");
    return -1;
  }
  int pw = (int)ceil(width), ph = (int)ceil(height);
  cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, pw, ph);
  if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
    cairo_surface_destroy(surface);
    return -1;
  }
  int stride = cairo_image_surface_get_stride(surface);
  unsigned char *data = cairo_image_surface_get_data(surface);
  // The base is the frame the damaged list was applied to, not the new reference: a pixel the
  // damaged list forgot stays as the old frame left it and shows up against the reference.
  const unsigned char *base = g_prev_px;
  int base_w = g_prev_w, base_h = g_prev_h, base_stride = g_prev_stride;
  if (base == NULL || base_w != pw || base_h != ph) {
    base = g_verify_px;
    base_w = g_verify_w;
    base_h = g_verify_h;
    base_stride = g_verify_stride;
  }
  if (base_stride == stride) {
    memcpy(data, base, (size_t)stride * (size_t)ph);
  } else {
    for (int y = 0; y < ph; y++) memcpy(data + (size_t)y * stride, base + (size_t)(y < base_h ? y : 0) * base_stride, (size_t)(pw * 4));
  }
  cairo_surface_mark_dirty(surface);
  cairo_t *cr = cairo_create(surface);
  if (cairo_status(cr) == CAIRO_STATUS_SUCCESS) {
    double saved = g_scale;
    g_scale = 1;
    g_present_region = 1;
    Replay r;
    replay(&r, cr, surface, width, height);
    g_present_region = 0;
    g_scale = saved;
  }
  cairo_destroy(cr);
  cairo_surface_flush(surface);
  const unsigned char *now = cairo_image_surface_get_data(surface);
  int stride_now = cairo_image_surface_get_stride(surface);
  long bad = 0;
  for (int i = 0; i < g_damage_count; i++) {
    int x0 = (int)floor(g_damage_rects[i][0]), y0 = (int)floor(g_damage_rects[i][1]);
    int x1 = (int)ceil(g_damage_rects[i][0] + g_damage_rects[i][2]);
    int y1 = (int)ceil(g_damage_rects[i][1] + g_damage_rects[i][3]);
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > pw) x1 = pw;
    if (y1 > ph) y1 = ph;
    for (int y = y0; y < y1; y++) {
      if (y >= g_verify_h) break;
      for (int x = x0; x < x1; x++) {
        const unsigned char *a = now + (size_t)y * stride_now + (size_t)x * 4;
        const unsigned char *b = g_verify_px + (size_t)y * g_verify_stride + (size_t)x * 4;
        if (a[0] != b[0] || a[1] != b[1] || a[2] != b[2] || a[3] != b[3]) {
          bad++;
        }
      }
    }
  }
  // A pixel outside every rectangle is the old frame's: one that differs from the reference is
  // stale paint the damage missed (a highlight a change didn't repaint), which the count inside the
  // rectangles can't see.
  long frame = 0;
  for (int y = 0; y < ph && y < g_verify_h; y++) {
    for (int x = 0; x < pw && x < g_verify_w; x++) {
      const unsigned char *a = now + (size_t)y * stride_now + (size_t)x * 4;
      const unsigned char *b = g_verify_px + (size_t)y * g_verify_stride + (size_t)x * 4;
      if (a[0] != b[0] || a[1] != b[1] || a[2] != b[2] || a[3] != b[3]) frame++;
    }
  }
  fprintf(stderr, "native: damage verify mismatched=%ld rects=%d frame=%ld\n", bad, g_damage_count, frame);
  // The damaged frame is what the window now shows: it becomes the next frame's base.
  free(g_prev_px);
  g_prev_px = (unsigned char *)malloc((size_t)stride_now * (size_t)ph);
  if (g_prev_px != NULL) {
    memcpy(g_prev_px, now, (size_t)stride_now * (size_t)ph);
    g_prev_w = pw;
    g_prev_h = ph;
    g_prev_stride = stride_now;
  }
  cairo_surface_destroy(surface);
  free(g_verify_px);
  g_verify_px = NULL;
  return (int32_t)bad;
}

// ---------------------------------------------------------------------------
// Canvas 2D
//
// A <canvas> owns a bitmap of its own. The canvas's user space is the bitmap's own pixels, top
// left origin and y down, so the only transform between the two is the one setTransform installs.
// Operations run as they are called and paint straight into the bitmap; the bitmap is drawn into
// the display list as an image when the page paints (CMD_CANVAS), so a canvas has no commands of
// its own in the list.
//
// Paths are built in bitmap pixels: the transform in effect when a segment is added is baked into
// it, as the canvas API requires. Filling and clipping therefore paint the stored path with an
// identity transform, and a stroke sizes its pen by the transform in effect at stroke time.

#define DASH_MAX 32
#define FILTER_MAX 8

typedef struct {
  double x0, y0, r0, x1, y1, r1;
  int radial;
  int n;
  double loc[MAX_STOPS];
  uint32_t col[MAX_STOPS]; // 0xRRGGBBAA, straight
  cairo_pattern_t *pat;
} Gradient;

typedef struct Canvas {
  cairo_surface_t *surface;
  cairo_t *ctx;
  // Where the current path lives, in bitmap pixels: a context of its own with an identity
  // transform, so a point transformed in when a segment is added stays where it was put.
  cairo_t *path;
  // One segment at a time, built in canvas space before its points are carried into the path.
  cairo_t *user;
  double w, h; // bitmap pixels
  double alpha;
  int composite;
  // Styles live here rather than in the Cairo context: the runtime keeps the canvas state stack
  // and puts these back after a restore, the same way it puts back the transform and clip.
  int fillKind, strokeKind; // 0 colour, 1 gradient
  uint32_t fillColor, strokeColor;
  Gradient fillGrad, strokeGrad;
  double fontSize, fontWeight;
  double lineWidth;
  int cap, join;
  double dash[DASH_MAX];
  int dashCount;
  double dashOffset;
  // The filter chain drawing operations go through, one CSS filter function per entry.
  struct { int kind; double a, b, c, d; } filter[FILTER_MAX];
  int filterCount;
  cairo_surface_t *scratch;
  struct GlCanvas *gl; // null unless the canvas was given a "webgl2" context
  // The current point, in canvas space, which only the path itself would otherwise know.
  int has_cur;
  double cur_x, cur_y;
} Canvas;

enum {
  FILTER_BLUR = 1,
  FILTER_BRIGHTNESS,
  FILTER_CONTRAST,
  FILTER_SATURATE,
  FILTER_GRAYSCALE,
  FILTER_SEPIA,
  FILTER_HUE_ROTATE,
  FILTER_INVERT,
  FILTER_OPACITY,
};

enum { OP_FILL, OP_STROKE, OP_FILL_RECT, OP_STROKE_RECT, OP_TEXT };

typedef struct {
  int kind;
  int flag; // the fill rule for OP_FILL, and stroke rather than fill for OP_TEXT
  double x, y, w, h, maxWidth;
  const uint8_t *text;
  size_t n;
} CanvasOp;

static void canvas_op(Canvas *c, CanvasOp *op);

static Canvas **g_canvases = NULL;
static size_t g_canvas_count = 0, g_canvas_cap = 0;

static Canvas *canvas_at(int32_t id) {
  if (id < 0 || (size_t)id >= g_canvas_count) return NULL;
  return g_canvases[(size_t)id];
}

// WebGL canvases: the bitmap is filled from the GL drawing buffer instead of drawn into.
static void gl_present_canvas(Canvas *c);
static void gl_resize_canvas(int32_t id, double w, double h);

static void canvas_do(Canvas *c, CanvasOp *op);

/** A canvas coordinate kept within a range far outside any bitmap. */
static double canvas_coord(double v) { return v < -1e7 ? -1e7 : v > 1e7 ? 1e7 : v; }

/** A canvas point in the bitmap's own pixels. */
static void canvas_point(Canvas *c, double x, double y, double *ox, double *oy) {
  cairo_matrix_t m;
  cairo_get_matrix(c->ctx, &m);
  cairo_matrix_transform_point(&m, &x, &y);
  *ox = canvas_coord(x);
  *oy = canvas_coord(y);
}

// --- Gradients --------------------------------------------------------------

static void gradient_clear(Gradient *g) {
  if (g->pat) cairo_pattern_destroy(g->pat);
  g->pat = NULL;
  g->n = 0;
}

/**
 * Builds the Cairo pattern for a parsed definition. The coordinates are the definition's own, in
 * canvas space; the transform is applied to the pattern when it is used to paint.
 */
static void gradient_build(Gradient *g) {
  if (g->pat) cairo_pattern_destroy(g->pat);
  g->pat = NULL;
  if (g->n == 0) return;
  g->pat = g->radial
    ? cairo_pattern_create_radial(g->x0, g->y0, g->r0, g->x1, g->y1, g->r1)
    : cairo_pattern_create_linear(g->x0, g->y0, g->x1, g->y1);
  if (!g->pat) return;
  // A canvas gradient interpolates its stops unpremultiplied, unlike a CSS one, which cairo does
  // as it stands.
  for (int i = 0; i < g->n; i++) {
    uint32_t c = g->col[i];
    double at = g->loc[i] < 0 ? 0 : g->loc[i] > 1 ? 1 : g->loc[i];
    cairo_pattern_add_color_stop_rgba(g->pat, at, ((c >> 24) & 255) / 255.0,
                                      ((c >> 16) & 255) / 255.0,
                                      ((c >> 8) & 255) / 255.0, (c & 255) / 255.0);
  }
  cairo_pattern_set_extend(g->pat, CAIRO_EXTEND_PAD);
}

/**
 * Parses the runtime's text definition of a gradient: "l;x0,y0,x1,y1" or "r;x0,y0,r0,x1,y1,r1",
 * then one "colour,offset" per stop, colour packed 0xRRGGBBAA. The stops arrive sorted by offset.
 */
static void gradient_parse(Gradient *g, const uint8_t *def, size_t n) {
  if (g->pat) cairo_pattern_destroy(g->pat);
  g->pat = NULL;
  g->n = 0;
  char *buf = (char *)malloc(n + 1);
  if (!buf) return;
  memcpy(buf, def, n);
  buf[n] = 0;
  const char *p = buf;
  int radial = *p == 'r';
  if (*p) p++;
  if (*p == ';') p++;
  double v[6];
  int nv = 0;
  while (nv < 6) {
    char *end;
    v[nv] = strtod(p, &end);
    if (end == p) break;
    nv++;
    p = end;
    if (*p != ',') break;
    p++;
  }
  if (radial ? nv < 6 : nv < 4) {
    free(buf);
    return;
  }
  g->radial = radial;
  if (radial) {
    g->x0 = v[0]; g->y0 = v[1]; g->r0 = v[2] < 0 ? 0 : v[2];
    g->x1 = v[3]; g->y1 = v[4]; g->r1 = v[5] < 0 ? 0 : v[5];
  } else {
    g->x0 = v[0]; g->y0 = v[1]; g->x1 = v[2]; g->y1 = v[3];
  }
  while (*p == ';' && g->n < MAX_STOPS) {
    p++;
    char *end;
    unsigned long long c = strtoull(p, &end, 10);
    if (end == p) break;
    p = end;
    if (*p == ',') p++;
    double off = strtod(p, &end);
    if (end == p) break;
    p = end;
    g->loc[g->n] = off < 0 ? 0 : off > 1 ? 1 : off;
    g->col[g->n] = (uint32_t)c;
    g->n++;
  }
  free(buf);
  gradient_build(g);
}

/**
 * Makes a gradient the source, with its coordinates in canvas space carried to the pixels being
 * painted. `m` is the transform from canvas space to the bitmap, or null when the context already
 * paints in canvas space.
 */
static void canvas_gradient_source(cairo_t *cr, Gradient *g, const cairo_matrix_t *to_device) {
  if (!g->pat) {
    set_fill(cr, 0x000000ff);
    return;
  }
  cairo_matrix_t identity;
  cairo_matrix_init_identity(&identity);
  if (to_device) {
    // The gradient's coordinates are in canvas space, and painting happens in the bitmap's: a
    // pattern's matrix takes a point the other way, from the user space of the moment to the
    // pattern's own, so it is the inverse of the canvas transform.
    cairo_matrix_t inverse = *to_device;
    if (cairo_matrix_invert(&inverse) != CAIRO_STATUS_SUCCESS) inverse = identity;
    cairo_pattern_set_matrix(g->pat, &inverse);
  } else {
    cairo_pattern_set_matrix(g->pat, &identity);
  }
  cairo_set_source(cr, g->pat);
}

// --- The bitmap -------------------------------------------------------------

/** The blend operator for a canvas composite mode, in the runtime's numbering. */
static cairo_operator_t canvas_operator(int mode) {
  switch (mode) {
    case 1: return CAIRO_OPERATOR_ADD;
    case 2: return CAIRO_OPERATOR_SOURCE;
    case 3: return CAIRO_OPERATOR_DEST_OUT;
    case 4: return CAIRO_OPERATOR_MULTIPLY;
    case 5: return CAIRO_OPERATOR_SCREEN;
    case 6: return CAIRO_OPERATOR_OVERLAY;
    case 7: return CAIRO_OPERATOR_DARKEN;
    case 8: return CAIRO_OPERATOR_LIGHTEN;
    case 9: return CAIRO_OPERATOR_XOR;
    case 10: return CAIRO_OPERATOR_IN;
    case 11: return CAIRO_OPERATOR_OUT;
    case 12: return CAIRO_OPERATOR_ATOP;
    case 13: return CAIRO_OPERATOR_DEST_IN;
    case 14: return CAIRO_OPERATOR_DEST_ATOP;
    case 15: return CAIRO_OPERATOR_DEST_OVER;
    default: return CAIRO_OPERATOR_OVER;
  }
}

/** Makes the canvas's bitmap, its painting context and the space it draws in. */
static void canvas_make_context(Canvas *c) {
  c->surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, (int)c->w, (int)c->h);
  c->ctx = cairo_create(c->surface);
  cairo_set_line_width(c->ctx, c->lineWidth);
}

// Clears the canvas back to transparent and resets it, as setting width or height does.
static void canvas_reset(Canvas *c) {
  if (c->ctx) cairo_destroy(c->ctx);
  if (c->surface) cairo_surface_destroy(c->surface);
  if (c->scratch) {
    cairo_surface_destroy(c->scratch);
    c->scratch = NULL;
  }
  c->ctx = NULL;
  c->surface = NULL;
  cairo_new_path(c->path);
  cairo_new_path(c->user);
  c->has_cur = 0;
  c->alpha = 1;
  c->composite = 0;
  c->filterCount = 0;
  c->fillKind = c->strokeKind = 0;
  c->fillColor = c->strokeColor = 0x000000ff;
  gradient_clear(&c->fillGrad);
  gradient_clear(&c->strokeGrad);
  c->fontSize = 10;
  c->fontWeight = 400;
  c->lineWidth = 1;
  c->cap = c->join = 0;
  c->dashCount = 0;
  c->dashOffset = 0;
  canvas_make_context(c);
}

int32_t host_canvas_create(double w, double h) {
  Canvas *c = (Canvas *)calloc(1, sizeof(Canvas));
  if (!c) return -1;
  if (w < 1 || w > 16384) w = w < 1 ? 1 : 16384;
  if (h < 1 || h > 16384) h = h < 1 ? 1 : 16384;
  c->w = floor(w);
  c->h = floor(h);
  cairo_surface_t *scratch = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1);
  c->path = cairo_create(scratch);
  c->user = cairo_create(scratch);
  cairo_surface_destroy(scratch);
  if (g_canvas_count == g_canvas_cap) {
    g_canvas_cap = g_canvas_cap ? g_canvas_cap * 2 : 8;
    g_canvases = (Canvas **)realloc(g_canvases, g_canvas_cap * sizeof(Canvas *));
  }
  int32_t id = (int32_t)g_canvas_count;
  g_canvases[g_canvas_count++] = c;
  canvas_reset(c);
  return id;
}

void host_canvas_resize(int32_t id, double w, double h) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  if (w < 1 || w > 16384) w = w < 1 ? 1 : 16384;
  if (h < 1 || h > 16384) h = h < 1 ? 1 : 16384;
  c->w = floor(w);
  c->h = floor(h);
  canvas_reset(c);
  gl_resize_canvas(id, c->w, c->h);
}

void host_canvas_save(int32_t id) {
  Canvas *c = canvas_at(id);
  if (c) cairo_save(c->ctx);
}

void host_canvas_restore(int32_t id) {
  Canvas *c = canvas_at(id);
  if (c) cairo_restore(c->ctx);
}

void host_canvas_set_transform(int32_t id, double a, double b, double c0, double d, double e, double f) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  cairo_matrix_t m;
  m.xx = a; m.yx = b; m.xy = c0; m.yy = d; m.x0 = e; m.y0 = f;
  cairo_set_matrix(c->ctx, &m);
}

void host_canvas_set_alpha(int32_t id, double a) {
  Canvas *c = canvas_at(id);
  if (c) c->alpha = a;
}

void host_canvas_set_composite(int32_t id, int32_t mode) {
  Canvas *c = canvas_at(id);
  if (c) c->composite = mode;
}

void host_canvas_set_line_width(int32_t id, double w) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  c->lineWidth = w;
}

void host_canvas_set_line_cap(int32_t id, int32_t cap) {
  Canvas *c = canvas_at(id);
  if (c) c->cap = cap < 0 ? 0 : (cap > 2 ? 2 : cap);
}

void host_canvas_set_line_join(int32_t id, int32_t join) {
  Canvas *c = canvas_at(id);
  if (c) c->join = join < 0 ? 0 : (join > 2 ? 2 : join);
}

// The dash pattern comes as text, "<offset> <d0> <d1> ...", in canvas units. A pattern of all-zero
// lengths has no gaps to draw, so the pen stays solid.
void host_canvas_set_line_dash(int32_t id, const uint8_t *s, size_t n) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  c->dashCount = 0;
  c->dashOffset = 0;
  char *buf = (char *)malloc(n + 1);
  if (!buf) return;
  memcpy(buf, s, n);
  buf[n] = 0;
  char *p = buf;
  c->dashOffset = strtod(p, &p);
  if (!isfinite(c->dashOffset)) c->dashOffset = 0;
  int positive = 0;
  while (*p) {
    char *end = p;
    double d = strtod(p, &end);
    if (end == p) break;
    p = end;
    if (!(d > 0)) d = d < 0 || !isfinite(d) ? 0 : d;
    if (d > 0) positive = 1;
    if (c->dashCount < DASH_MAX) c->dash[c->dashCount++] = d;
  }
  if (!positive) c->dashCount = 0;
  free(buf);
}

void host_canvas_set_fill_color(int32_t id, uint32_t color) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  c->fillKind = 0;
  c->fillColor = color;
}

void host_canvas_set_stroke_color(int32_t id, uint32_t color) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  c->strokeKind = 0;
  c->strokeColor = color;
}

void host_canvas_set_fill_gradient(int32_t id, const uint8_t *def, size_t n) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  gradient_parse(&c->fillGrad, def, n);
  c->fillKind = 1;
}

void host_canvas_set_stroke_gradient(int32_t id, const uint8_t *def, size_t n) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  gradient_parse(&c->strokeGrad, def, n);
  c->strokeKind = 1;
}

void host_canvas_set_font(int32_t id, double size, double weight) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  c->fontSize = size;
  c->fontWeight = weight;
}

// The filter chain, as the runtime packed it: "kind a" per function, ';' between.
void host_canvas_set_filter(int32_t id, const uint8_t *def, size_t n) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  c->filterCount = 0;
  size_t i = 0;
  while (i < n && c->filterCount < FILTER_MAX) {
    char buf[128];
    size_t k = 0;
    while (i < n && def[i] != ';' && k < sizeof(buf) - 1) buf[k++] = (char)def[i++];
    while (i < n && def[i] != ';') i++;
    if (i < n) i++;
    buf[k] = 0;
    char *end = buf;
    int kind = (int)strtod(end, &end);
    double a = strtod(end, &end);
    if (kind < FILTER_BLUR || kind > FILTER_OPACITY) continue;
    if (!(a >= 0)) a = 0;
    if (kind == FILTER_BLUR && a > 250) a = 250;
    int at = c->filterCount++;
    c->filter[at].kind = kind;
    c->filter[at].a = a;
    c->filter[at].b = c->filter[at].c = c->filter[at].d = 0;
  }
}

// An inline SVG filter: the region's pixels are read out of the Cairo image surface, the chain
// runs over them (the portable engine in svg-filter.c), and the result replaces them. The region
// is in bitmap pixels, already clamped to the bitmap by the runtime.
void host_canvas_svg_filter(int32_t id, const uint8_t *def, size_t n, int32_t linear,
                            double x, double y, double w, double h) {
  Canvas *c = canvas_at(id);
  if (!c || !c->ctx || !c->surface || !(w > 0) || !(h > 0)) return;
  if (cairo_image_surface_get_format(c->surface) != CAIRO_FORMAT_ARGB32) return;
  ensure_channels();
  const int R = g_ch_r, G = g_ch_g, B = g_ch_b, A = g_ch_a;
  int x0 = (int)floor(x), y0 = (int)floor(y);
  int x1 = (int)ceil(x + w), y1 = (int)ceil(y + h);
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x1 > (int)c->w) x1 = (int)c->w;
  if (y1 > (int)c->h) y1 = (int)c->h;
  int iw = x1 - x0, ih = y1 - y0;
  if (iw <= 0 || ih <= 0) return;
  cairo_surface_flush(c->surface);
  uint8_t *data = cairo_image_surface_get_data(c->surface);
  if (!data) return;
  size_t stride = (size_t)cairo_image_surface_get_stride(c->surface);
  uint8_t *buf = (uint8_t *)malloc((size_t)iw * (size_t)ih * 4);
  if (!buf) return;
  // ARGB32 holds premultiplied pixels in the machine's channel order; the engine takes RGBA.
  for (int row = 0; row < ih; row++) {
    const uint8_t *src = data + (size_t)(y0 + row) * stride + (size_t)x0 * 4;
    uint8_t *dst = buf + (size_t)row * (size_t)iw * 4;
    for (int col = 0; col < iw; col++) {
      dst[col * 4 + 0] = src[col * 4 + R];
      dst[col * 4 + 1] = src[col * 4 + G];
      dst[col * 4 + 2] = src[col * 4 + B];
      dst[col * 4 + 3] = src[col * 4 + A];
    }
  }
  svg_filter_apply(buf, iw, ih, (const char *)def, n, linear != 0);
  for (int row = 0; row < ih; row++) {
    uint8_t *dst = data + (size_t)(y0 + row) * stride + (size_t)x0 * 4;
    const uint8_t *src = buf + (size_t)row * (size_t)iw * 4;
    for (int col = 0; col < iw; col++) {
      dst[col * 4 + R] = src[col * 4 + 0];
      dst[col * 4 + G] = src[col * 4 + 1];
      dst[col * 4 + B] = src[col * 4 + 2];
      dst[col * 4 + A] = src[col * 4 + 3];
    }
  }
  free(buf);
  cairo_surface_mark_dirty_rectangle(c->surface, x0, y0, iw, ih);
}

// --- Paths ------------------------------------------------------------------

/**
 * Adds a path built in canvas space to the canvas path, carrying every point through `m`. With
 * `skip_move`, the path's leading move is left out so it continues the current subpath: an arc or
 * a curve that joins a path must be closed with the chord it shares with it, not one of its own.
 */
static void path_append_transformed(cairo_t *dst, const cairo_path_t *src, const cairo_matrix_t *m,
                                    int skip_move) {
  const cairo_path_data_t *p = src->data;
  int first = 1;
  for (int i = 0; i < src->num_data;) {
    int len = p[i].header.length;
    if (len <= 0) break;
    switch (p[i].header.type) {
      case CAIRO_PATH_MOVE_TO: {
        double x = p[i + 1].point.x, y = p[i + 1].point.y;
        cairo_matrix_transform_point(m, &x, &y);
        if (!(skip_move && first)) cairo_move_to(dst, canvas_coord(x), canvas_coord(y));
        break;
      }
      case CAIRO_PATH_LINE_TO: {
        double x = p[i + 1].point.x, y = p[i + 1].point.y;
        cairo_matrix_transform_point(m, &x, &y);
        cairo_line_to(dst, canvas_coord(x), canvas_coord(y));
        break;
      }
      case CAIRO_PATH_CURVE_TO: {
        double a = p[i + 1].point.x, b = p[i + 1].point.y;
        double c0 = p[i + 2].point.x, d = p[i + 2].point.y;
        double e = p[i + 3].point.x, f = p[i + 3].point.y;
        cairo_matrix_transform_point(m, &a, &b);
        cairo_matrix_transform_point(m, &c0, &d);
        cairo_matrix_transform_point(m, &e, &f);
        cairo_curve_to(dst, canvas_coord(a), canvas_coord(b), canvas_coord(c0), canvas_coord(d),
                       canvas_coord(e), canvas_coord(f));
        break;
      }
      case CAIRO_PATH_CLOSE_PATH:
        cairo_close_path(dst);
        break;
      default:
        break;
    }
    first = 0;
    i += len;
  }
}

/** Carries the segment built in the canvas-space context onto the canvas path. */
static void canvas_append_user(Canvas *c, int skip_move) {
  cairo_path_t *p = cairo_copy_path(c->user);
  if (p) {
    cairo_matrix_t m;
    cairo_get_matrix(c->ctx, &m);
    path_append_transformed(c->path, p, &m, skip_move);
    cairo_path_destroy(p);
  }
  cairo_new_path(c->user);
}

void host_canvas_begin_path(int32_t id) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  cairo_new_path(c->path);
  c->has_cur = 0;
}

void host_canvas_move_to(int32_t id, double x, double y) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  double X, Y;
  canvas_point(c, x, y, &X, &Y);
  cairo_move_to(c->path, X, Y);
  c->cur_x = x;
  c->cur_y = y;
  c->has_cur = 1;
}

void host_canvas_line_to(int32_t id, double x, double y) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  double X, Y;
  canvas_point(c, x, y, &X, &Y);
  cairo_line_to(c->path, X, Y);
  c->cur_x = x;
  c->cur_y = y;
  c->has_cur = 1;
}

void host_canvas_quadratic_to(int32_t id, double cx, double cy, double x, double y) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  // A path with no current point starts at the control point, so the curve runs to its end as a
  // straight line from there.
  double p0x = c->has_cur ? c->cur_x : cx, p0y = c->has_cur ? c->cur_y : cy;
  cairo_new_path(c->user);
  cairo_move_to(c->user, p0x, p0y);
  cairo_curve_to(c->user, p0x + 2.0 / 3.0 * (cx - p0x), p0y + 2.0 / 3.0 * (cy - p0y),
                 x + 2.0 / 3.0 * (cx - x), y + 2.0 / 3.0 * (cy - y), x, y);
  canvas_append_user(c, c->has_cur);
  c->cur_x = x;
  c->cur_y = y;
  c->has_cur = 1;
}

void host_canvas_bezier_to(int32_t id, double c1x, double c1y, double c2x, double c2y, double x, double y) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  double p0x = c->has_cur ? c->cur_x : c1x, p0y = c->has_cur ? c->cur_y : c1y;
  cairo_new_path(c->user);
  cairo_move_to(c->user, p0x, p0y);
  cairo_curve_to(c->user, c1x, c1y, c2x, c2y, x, y);
  canvas_append_user(c, c->has_cur);
  c->cur_x = x;
  c->cur_y = y;
  c->has_cur = 1;
}

void host_canvas_close_path(int32_t id) {
  Canvas *c = canvas_at(id);
  if (c) cairo_close_path(c->path);
}

void host_canvas_arc(int32_t id, double cx, double cy, double r, double start, double end, int32_t ccw) {
  Canvas *c = canvas_at(id);
  if (!c || !(r >= 0)) return;
  cairo_new_path(c->user);
  if (c->has_cur) cairo_move_to(c->user, c->cur_x, c->cur_y);
  if (ccw) cairo_arc_negative(c->user, cx, cy, r, start, end);
  else cairo_arc(c->user, cx, cy, r, start, end);
  canvas_append_user(c, c->has_cur);
  c->cur_x = cx + r * cos(end);
  c->cur_y = cy + r * sin(end);
  c->has_cur = 1;
}

// The arc that rounds the corner at (x1, y1), between the current point and the line to (x2, y2).
// The radius is clamped to what the two segments can hold, as a browser does.
void host_canvas_arc_to(int32_t id, double x1, double y1, double x2, double y2, double r) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  if (!c->has_cur) {
    host_canvas_move_to(id, x1, y1);
    return;
  }
  double x0 = c->cur_x, y0 = c->cur_y;
  double v1x = x0 - x1, v1y = y0 - y1, v2x = x2 - x1, v2y = y2 - y1;
  double l1 = hypot(v1x, v1y), l2 = hypot(v2x, v2y);
  double cross = v1x * v2y - v1y * v2x;
  double dot = v1x * v2x + v1y * v2y;
  double theta = atan2(fabs(cross), dot);
  if (!(r > 0) || l1 == 0 || l2 == 0 || !(theta > 0) || theta >= M_PI) {
    host_canvas_line_to(id, x1, y1);
    return;
  }
  double t = r / tan(theta / 2);
  double max_t = fmin(l1, l2);
  if (t > max_t) {
    t = max_t;
    r = t * tan(theta / 2);
  }
  double t1x = x1 + v1x / l1 * t, t1y = y1 + v1y / l1 * t;
  double t2x = x1 + v2x / l2 * t, t2y = y1 + v2y / l2 * t;
  double bx = v1x / l1 + v2x / l2, by = v1y / l1 + v2y / l2;
  double bl = hypot(bx, by);
  double dist = r / sin(theta / 2);
  double ccx = x1 + bx / bl * dist, ccy = y1 + by / bl * dist;
  double a1 = atan2(t1y - ccy, t1x - ccx), a2 = atan2(t2y - ccy, t2x - ccx);
  double sweep = a2 - a1;
  while (sweep > M_PI) sweep -= 2 * M_PI;
  while (sweep < -M_PI) sweep += 2 * M_PI;
  cairo_new_path(c->user);
  cairo_move_to(c->user, x0, y0);
  cairo_line_to(c->user, t1x, t1y);
  if (sweep >= 0) cairo_arc(c->user, ccx, ccy, r, a1, a2);
  else cairo_arc_negative(c->user, ccx, ccy, r, a1, a2);
  canvas_append_user(c, 1);
  c->cur_x = t2x;
  c->cur_y = t2y;
  c->has_cur = 1;
}

void host_canvas_rect(int32_t id, double x, double y, double w, double h) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  cairo_new_path(c->user);
  cairo_rectangle(c->user, x, y, w, h);
  canvas_append_user(c, 0);
  c->cur_x = x;
  c->cur_y = y;
  c->has_cur = 1;
}

// --- Painting ---------------------------------------------------------------

/** Fills the canvas path with the current fill style, in the bitmap's own pixels. */
static void canvas_fill_path(Canvas *c, int evenodd) {
  cairo_t *cr = c->ctx;
  cairo_matrix_t m;
  cairo_get_matrix(cr, &m);
  cairo_save(cr);
  cairo_identity_matrix(cr);
  cairo_new_path(cr);
  cairo_path_t *p = cairo_copy_path(c->path);
  if (p) {
    cairo_append_path(cr, p);
    cairo_path_destroy(p);
  }
  cairo_set_fill_rule(cr, evenodd ? CAIRO_FILL_RULE_EVEN_ODD : CAIRO_FILL_RULE_WINDING);
  if (c->fillKind == 1) canvas_gradient_source(cr, &c->fillGrad, &m);
  else set_fill(cr, c->fillColor);
  cairo_fill(cr);
  cairo_set_fill_rule(cr, CAIRO_FILL_RULE_WINDING);
  cairo_restore(cr);
}

/** Sets the pen: width, ends, corners and the dash pattern, all in bitmap pixels. */
static void canvas_set_line(Canvas *c, cairo_t *cr, double width, double scale) {
  cairo_set_line_width(cr, canvas_coord(width));
  cairo_set_line_cap(cr, c->cap == 1 ? CAIRO_LINE_CAP_ROUND : c->cap == 2 ? CAIRO_LINE_CAP_SQUARE
                                                                         : CAIRO_LINE_CAP_BUTT);
  cairo_set_line_join(cr, c->join == 1 ? CAIRO_LINE_JOIN_ROUND : c->join == 2 ? CAIRO_LINE_JOIN_BEVEL
                                                                             : CAIRO_LINE_JOIN_MITER);
  if (c->dashCount > 0) {
    double dashes[DASH_MAX];
    for (int i = 0; i < c->dashCount; i++) dashes[i] = c->dash[i] * scale;
    cairo_set_dash(cr, dashes, c->dashCount, c->dashOffset * scale);
  } else {
    cairo_set_dash(cr, NULL, 0, 0);
  }
}

/** Strokes the canvas path. The pen is sized in canvas space, so it takes the transform's scale. */
static void canvas_stroke_path(Canvas *c) {
  cairo_t *cr = c->ctx;
  cairo_matrix_t m;
  cairo_get_matrix(cr, &m);
  double scale = matrix_scale(&m);
  cairo_save(cr);
  cairo_identity_matrix(cr);
  cairo_new_path(cr);
  cairo_path_t *p = cairo_copy_path(c->path);
  if (p) {
    cairo_append_path(cr, p);
    cairo_path_destroy(p);
  }
  canvas_set_line(c, cr, c->lineWidth * scale, scale);
  if (c->strokeKind == 1) canvas_gradient_source(cr, &c->strokeGrad, &m);
  else set_fill(cr, c->strokeColor);
  cairo_stroke(cr);
  cairo_restore(cr);
}

void host_canvas_fill(int32_t id, int32_t rule) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  CanvasOp op = {0};
  op.kind = OP_FILL;
  op.flag = rule;
  canvas_op(c, &op);
}

void host_canvas_stroke(int32_t id) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  CanvasOp op = {0};
  op.kind = OP_STROKE;
  canvas_op(c, &op);
}

void host_canvas_clip(int32_t id, int32_t rule) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  cairo_t *cr = c->ctx;
  cairo_matrix_t saved;
  cairo_get_matrix(cr, &saved);
  cairo_identity_matrix(cr);
  cairo_new_path(cr);
  cairo_path_t *p = cairo_copy_path(c->path);
  if (p) {
    cairo_append_path(cr, p);
    cairo_path_destroy(p);
  }
  if (rule != 0) cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD);
  cairo_clip(cr);
  cairo_set_fill_rule(cr, CAIRO_FILL_RULE_WINDING);
  cairo_set_matrix(cr, &saved);
}

void host_canvas_fill_rect(int32_t id, double x, double y, double w, double h) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  CanvasOp op = {0};
  op.kind = OP_FILL_RECT;
  op.x = x; op.y = y; op.w = w; op.h = h;
  canvas_op(c, &op);
}

void host_canvas_stroke_rect(int32_t id, double x, double y, double w, double h) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  CanvasOp op = {0};
  op.kind = OP_STROKE_RECT;
  op.x = x; op.y = y; op.w = w; op.h = h;
  canvas_op(c, &op);
}

// Clears a rect to transparent black, whatever the fill style and composite mode are.
void host_canvas_clear_rect(int32_t id, double x, double y, double w, double h) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  cairo_t *cr = c->ctx;
  cairo_save(cr);
  cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR);
  cairo_new_path(cr);
  cairo_rectangle(cr, x, y, w, h);
  cairo_fill(cr);
  cairo_restore(cr);
}

// --- Text -------------------------------------------------------------------

/** Fills or strokes a text run at the canvas pen, condensing it into `maxWidth` when needed. */
static void canvas_text(Canvas *c, const uint8_t *s, size_t n, double x, double y, double maxWidth,
                        int stroke) {
  cairo_t *cr = c->ctx;
  cairo_matrix_t m;
  cairo_get_matrix(cr, &m);
  double scale = matrix_scale(&m);
  double width = host_measure_text(s, n, c->fontSize, c->fontWeight, 0, 0);
  double sx = maxWidth > 0 && width > maxWidth ? maxWidth / width : 1;
  cairo_save(cr);
  // Condensing the run is a horizontal scale about its own pen, so the glyphs keep their place
  // along the baseline.
  cairo_translate(cr, x, y);
  cairo_scale(cr, sx, 1);
  cairo_translate(cr, -x, -y);
  cairo_new_path(cr);
  paint_run(cr, s, n, c->fontSize, c->fontWeight, 0, 0, x, y, scale, 0, NULL, 0);
  if (stroke) {
    set_fill(cr, c->strokeColor);
    canvas_set_line(c, cr, c->lineWidth, 1);
    cairo_stroke(cr);
  } else if (c->fillKind == 1) {
    canvas_gradient_source(cr, &c->fillGrad, NULL);
    cairo_fill(cr);
  } else {
    FT_Face ft = paint_face(c->fontWeight);
    if (ft && !face_is_bold(ft, c->fontWeight)) {
      set_fill(cr, c->fillColor);
      cairo_fill_preserve(cr);
      set_fill(cr, c->fillColor);
      cairo_set_line_width(cr, c->fontSize / 24.0);
      cairo_stroke(cr);
    } else {
      set_fill(cr, c->fillColor);
      cairo_fill(cr);
    }
  }
  cairo_restore(cr);
}

void host_canvas_fill_text(const uint8_t *s, size_t n, int32_t id, double x, double y, double maxWidth) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  CanvasOp op = {0};
  op.kind = OP_TEXT;
  op.x = x; op.y = y; op.maxWidth = maxWidth;
  op.text = s; op.n = n;
  canvas_op(c, &op);
}

void host_canvas_stroke_text(const uint8_t *s, size_t n, int32_t id, double x, double y, double maxWidth) {
  Canvas *c = canvas_at(id);
  if (!c) return;
  CanvasOp op = {0};
  op.kind = OP_TEXT;
  op.flag = 1;
  op.x = x; op.y = y; op.maxWidth = maxWidth;
  op.text = s; op.n = n;
  canvas_op(c, &op);
}

// --- Filters ----------------------------------------------------------------
// A canvas filter is the chain of CSS filter functions drawing operations go through. An operation
// with a filter paints into a scratch bitmap of the canvas's size, the chain runs over those
// pixels, and the result is composited into the canvas with the alpha, blend mode and clip in
// force.

typedef struct { double r, g, b, a; } FPixel;

static double filter_clamp(double v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

static double filter_luma(double r, double g, double b) { return 0.2126 * r + 0.7152 * g + 0.0722 * b; }

/**
 * A Gaussian blur of straight-alpha pixels in place: CSS's blur() is a Gaussian whose standard
 * deviation is its length. Both passes clamp at the bitmap's edges.
 */
static void filter_blur(FPixel *px, int w, int h, double sigma) {
  if (!(sigma > 0) || w <= 0 || h <= 0) return;
  int r = (int)ceil(sigma * 3);
  if (r < 1) r = 1;
  if (r > 64) r = 64;
  double k[129];
  double sum = 0;
  for (int i = -r; i <= r; i++) {
    double v = exp(-(double)(i * i) / (2 * sigma * sigma));
    k[i + r] = v;
    sum += v;
  }
  for (int i = 0; i <= 2 * r; i++) k[i] /= sum;
  size_t n = (size_t)w * (size_t)h;
  FPixel *a = (FPixel *)malloc(n * sizeof(FPixel));
  FPixel *b = (FPixel *)malloc(n * sizeof(FPixel));
  if (!a || !b) {
    free(a);
    free(b);
    return;
  }
  for (size_t i = 0; i < n; i++) {
    a[i].r = px[i].r * px[i].a;
    a[i].g = px[i].g * px[i].a;
    a[i].b = px[i].b * px[i].a;
    a[i].a = px[i].a;
  }
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      FPixel acc = {0, 0, 0, 0};
      for (int i = -r; i <= r; i++) {
        int sx = x + i;
        if (sx < 0) sx = 0;
        if (sx >= w) sx = w - 1;
        const FPixel *s = &a[(size_t)y * (size_t)w + (size_t)sx];
        double kv = k[i + r];
        acc.r += s->r * kv; acc.g += s->g * kv; acc.b += s->b * kv; acc.a += s->a * kv;
      }
      b[(size_t)y * (size_t)w + (size_t)x] = acc;
    }
  }
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      FPixel acc = {0, 0, 0, 0};
      for (int i = -r; i <= r; i++) {
        int sy = y + i;
        if (sy < 0) sy = 0;
        if (sy >= h) sy = h - 1;
        const FPixel *s = &b[(size_t)sy * (size_t)w + (size_t)x];
        double kv = k[i + r];
        acc.r += s->r * kv; acc.g += s->g * kv; acc.b += s->b * kv; acc.a += s->a * kv;
      }
      a[(size_t)y * (size_t)w + (size_t)x] = acc;
    }
  }
  for (size_t i = 0; i < n; i++) {
    double al = a[i].a;
    if (al > 0) {
      px[i].r = filter_clamp(a[i].r / al);
      px[i].g = filter_clamp(a[i].g / al);
      px[i].b = filter_clamp(a[i].b / al);
    } else {
      px[i].r = px[i].g = px[i].b = 0;
    }
    px[i].a = filter_clamp(al);
  }
  free(a);
  free(b);
}

/** One colour filter over every pixel: the CSS function's definition, applied in sRGB. */
static void filter_colour(FPixel *px, size_t n, int kind, double a) {
  double cosv = 0, sinv = 0;
  if (kind == FILTER_HUE_ROTATE) {
    double rad = a * M_PI / 180.0;
    cosv = cos(rad);
    sinv = sin(rad);
  }
  for (size_t i = 0; i < n; i++) {
    FPixel *p = &px[i];
    double r = p->r, g = p->g, b = p->b, al = p->a;
    switch (kind) {
      case FILTER_BRIGHTNESS:
        r *= a; g *= a; b *= a;
        break;
      case FILTER_CONTRAST:
        r = (r - 0.5) * a + 0.5;
        g = (g - 0.5) * a + 0.5;
        b = (b - 0.5) * a + 0.5;
        break;
      case FILTER_SATURATE: {
        double l = filter_luma(r, g, b);
        r = l + (r - l) * a;
        g = l + (g - l) * a;
        b = l + (b - l) * a;
        break;
      }
      case FILTER_GRAYSCALE: {
        double l = filter_luma(r, g, b);
        double k = 1 - a;
        r = l + (r - l) * k;
        g = l + (g - l) * k;
        b = l + (b - l) * k;
        break;
      }
      case FILTER_SEPIA: {
        double sr = 0.393 * r + 0.769 * g + 0.189 * b;
        double sg = 0.349 * r + 0.686 * g + 0.168 * b;
        double sb = 0.272 * r + 0.534 * g + 0.131 * b;
        r += (sr - r) * a;
        g += (sg - g) * a;
        b += (sb - b) * a;
        break;
      }
      case FILTER_HUE_ROTATE: {
        double nr = (0.213 + cosv * 0.787 - sinv * 0.213) * r + (0.715 - cosv * 0.715 - sinv * 0.715) * g
                  + (0.072 - cosv * 0.072 + sinv * 0.928) * b;
        double ng = (0.213 - cosv * 0.213 + sinv * 0.143) * r + (0.715 + cosv * 0.285 + sinv * 0.140) * g
                  + (0.072 - cosv * 0.072 - sinv * 0.283) * b;
        double nb = (0.213 - cosv * 0.213 - sinv * 0.787) * r + (0.715 - cosv * 0.715 + sinv * 0.715) * g
                  + (0.072 + cosv * 0.928 + sinv * 0.072) * b;
        r = nr; g = ng; b = nb;
        break;
      }
      case FILTER_INVERT:
        r += (1 - 2 * r) * a;
        g += (1 - 2 * g) * a;
        b += (1 - 2 * b) * a;
        break;
      case FILTER_OPACITY:
        al *= a;
        break;
      default:
        break;
    }
    p->r = filter_clamp(r);
    p->g = filter_clamp(g);
    p->b = filter_clamp(b);
    p->a = filter_clamp(al);
  }
}

/** The scratch bitmap painting goes into first, the canvas's size and format. */
static cairo_surface_t *canvas_scratch(Canvas *c) {
  if (c->scratch && (size_t)c->w == (size_t)cairo_image_surface_get_width(c->scratch) &&
      (size_t)c->h == (size_t)cairo_image_surface_get_height(c->scratch)) {
    return c->scratch;
  }
  if (c->scratch) cairo_surface_destroy(c->scratch);
  c->scratch = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, (int)c->w, (int)c->h);
  return c->scratch;
}

/** Runs the chain over the scratch bitmap and composites it into the canvas. */
static void canvas_apply_filter(Canvas *c, cairo_surface_t *scratch) {
  ensure_channels();
  int w = (int)c->w, h = (int)c->h;
  size_t n = (size_t)w * (size_t)h;
  cairo_surface_flush(scratch);
  unsigned char *data = n ? cairo_image_surface_get_data(scratch) : NULL;
  if (!data) return;
  size_t stride = (size_t)cairo_image_surface_get_stride(scratch);
  const int R = g_ch_r, G = g_ch_g, B = g_ch_b, A = g_ch_a;
  FPixel *px = (FPixel *)malloc(n * sizeof(FPixel));
  if (!px) return;
  for (int y = 0; y < h; y++) {
    const unsigned char *row = data + (size_t)y * stride;
    for (int x = 0; x < w; x++) {
      const unsigned char *s = row + (size_t)x * 4;
      FPixel *p = &px[(size_t)y * (size_t)w + (size_t)x];
      unsigned al = s[A];
      if (al == 0) {
        p->r = p->g = p->b = p->a = 0;
      } else {
        // Premultiplied to straight, the way getImageData reads a pixel.
        p->r = (double)s[R] / al;
        p->g = (double)s[G] / al;
        p->b = (double)s[B] / al;
        p->a = (double)al / 255.0;
      }
    }
  }
  for (int i = 0; i < c->filterCount; i++) {
    int kind = c->filter[i].kind;
    if (kind == FILTER_BLUR) filter_blur(px, w, h, c->filter[i].a);
    else filter_colour(px, n, kind, c->filter[i].a);
  }
  for (int y = 0; y < h; y++) {
    unsigned char *row = data + (size_t)y * stride;
    for (int x = 0; x < w; x++) {
      const FPixel *p = &px[(size_t)y * (size_t)w + (size_t)x];
      unsigned char *d = row + (size_t)x * 4;
      unsigned al = (unsigned)(p->a * 255 + 0.5);
      if (al > 255) al = 255;
      // Straight back to premultiplied, never above the alpha the pixel can carry.
      double v[3] = {p->r * al + 0.5, p->g * al + 0.5, p->b * al + 0.5};
      unsigned char *out[3] = {&d[R], &d[G], &d[B]};
      for (int ch = 0; ch < 3; ch++) {
        double val = v[ch];
        if (val < 0) val = 0;
        if (val > al) val = al;
        *out[ch] = (unsigned char)val;
      }
      d[A] = (unsigned char)al;
    }
  }
  cairo_surface_mark_dirty(scratch);
  free(px);
  cairo_save(c->ctx);
  cairo_identity_matrix(c->ctx);
  cairo_set_source_surface(c->ctx, scratch, 0, 0);
  cairo_pattern_set_filter(cairo_get_source(c->ctx), CAIRO_FILTER_NEAREST);
  cairo_set_operator(c->ctx, canvas_operator(c->composite));
  cairo_paint_with_alpha(c->ctx, c->alpha);
  cairo_restore(c->ctx);
}

/**
 * Paints an operation into the scratch bitmap, runs the filter chain over it, and composites the
 * result. The scratch carries the canvas's transform; the clip is the canvas's own, and is
 * applied when the result is composited.
 */
static void canvas_filtered(Canvas *c, CanvasOp *op) {
  cairo_surface_t *scratch = canvas_scratch(c);
  if (!scratch) {
    canvas_do(c, op);
    return;
  }
  cairo_t *scratch_ctx = cairo_create(scratch);
  cairo_set_operator(scratch_ctx, CAIRO_OPERATOR_CLEAR);
  cairo_paint(scratch_ctx);
  cairo_set_operator(scratch_ctx, CAIRO_OPERATOR_OVER);
  cairo_t *main_ctx = c->ctx;
  cairo_matrix_t m;
  cairo_get_matrix(main_ctx, &m);
  cairo_set_matrix(scratch_ctx, &m);
  c->ctx = scratch_ctx;
  canvas_do(c, op);
  c->ctx = main_ctx;
  cairo_destroy(scratch_ctx);
  canvas_apply_filter(c, scratch);
}

static void canvas_do(Canvas *c, CanvasOp *op) {
  switch (op->kind) {
    case OP_FILL:
      canvas_fill_path(c, op->flag != 0);
      break;
    case OP_STROKE:
      canvas_stroke_path(c);
      break;
    case OP_FILL_RECT: {
      cairo_t *cr = c->ctx;
      cairo_new_path(cr);
      cairo_rectangle(cr, op->x, op->y, op->w, op->h);
      if (c->fillKind == 1) canvas_gradient_source(cr, &c->fillGrad, NULL);
      else set_fill(cr, c->fillColor);
      cairo_fill(cr);
      break;
    }
    case OP_STROKE_RECT: {
      cairo_t *cr = c->ctx;
      cairo_new_path(cr);
      cairo_rectangle(cr, op->x, op->y, op->w, op->h);
      canvas_set_line(c, cr, c->lineWidth, 1);
      if (c->strokeKind == 1) canvas_gradient_source(cr, &c->strokeGrad, NULL);
      else set_fill(cr, c->strokeColor);
      cairo_stroke(cr);
      break;
    }
    case OP_TEXT:
      canvas_text(c, op->text, op->n, op->x, op->y, op->maxWidth, op->flag);
      break;
  }
}

/**
 * Runs one drawing operation. A translucent or blended operation is painted into a group of its
 * own first, so its alpha and composite mode apply to the operation as a whole, the way a canvas
 * composites a drawing rather than each pixel of it.
 */
static void canvas_op(Canvas *c, CanvasOp *op) {
  int group = c->alpha < 1 || c->composite != 0;
  if (c->filterCount > 0) {
    canvas_filtered(c, op);
    return;
  }
  cairo_save(c->ctx);
  if (group) cairo_push_group(c->ctx);
  canvas_do(c, op);
  if (group) {
    cairo_pop_group_to_source(c->ctx);
    cairo_set_operator(c->ctx, canvas_operator(c->composite));
    cairo_paint_with_alpha(c->ctx, c->alpha);
  }
  cairo_restore(c->ctx);
}

// Places the part of a canvas bitmap within a source rect, in bitmap pixels, into a rect in the
// current (y down) user space.
void host_canvas_draw_part(int32_t id, double x, double y, double w, double h,
                           double sx, double sy, double sw, double sh, double alpha, double smooth) {
  Canvas *c = canvas_at(id);
  if (!c || !c->ctx) return;
  gl_present_canvas(c);
  Cmd *cmd = push_cmd();
  cmd->kind = CMD_CANVAS;
  cmd->image = id;
  cmd->x = x; cmd->y = y; cmd->w = w; cmd->h = h; cmd->size = alpha;
  cmd->smooth = smooth > 0.5;
  cmd->sx = sx; cmd->sy = sy; cmd->sw = sw; cmd->sh = sh;
}

// Places a canvas bitmap in the display list, scaled to a rect in the current (y down) user space.
void host_canvas_draw(int32_t id, double x, double y, double w, double h, double alpha, double smooth) {
  Canvas *c = canvas_at(id);
  if (!c || !c->ctx) return;
  gl_present_canvas(c);
  Cmd *cmd = push_cmd();
  cmd->kind = CMD_CANVAS;
  cmd->image = id;
  cmd->x = x; cmd->y = y; cmd->w = w; cmd->h = h; cmd->size = alpha;
  cmd->smooth = smooth > 0.5;
}

/** Draws a canvas bitmap into a replay's target, in the rect the display list recorded. */
static void canvas_paint(cairo_t *cr, const Cmd *c) {
  Canvas *cv = canvas_at(c->image);
  if (!cv || !cv->surface) return;
  double x = c->x, y = c->y, w = c->w, h = c->h;
  if (!(w > 0) || !(h > 0)) return;
  double sx = c->sx, sy = c->sy, sw = c->sw, sh = c->sh;
  if (!(sw > 0 && sh > 0)) {
    sx = 0;
    sy = 0;
    sw = cv->w;
    sh = cv->h;
  }
  cairo_surface_flush(cv->surface);
  double rx = w / sw, ry = h / sh;
  cairo_pattern_t *pat = cairo_pattern_create_for_surface(cv->surface);
  cairo_matrix_t m;
  m.xx = 1 / rx; m.xy = 0; m.yx = 0; m.yy = 1 / ry;
  m.x0 = sx - x / rx;
  m.y0 = sy - y / ry;
  cairo_pattern_set_matrix(pat, &m);
  cairo_pattern_set_filter(pat, c->smooth ? CAIRO_FILTER_GOOD : CAIRO_FILTER_NEAREST);
  cairo_save(cr);
  cairo_new_path(cr);
  cairo_rectangle(cr, x, y, w, h);
  cairo_set_source(cr, pat);
  cairo_clip(cr);
  cairo_paint_with_alpha(cr, c->size);
  cairo_restore(cr);
  cairo_pattern_destroy(pat);
}

// --- Pixels ------------------------------------------------------------------

// The bitmap's own pixels, the way getImageData hands them over: RGBA with every channel straight,
// rows top down. A pixel the rect asks for outside the bitmap reads as transparent black.
typedef void (*pixels_cb)(const uint8_t *, size_t);

/** A premultiplied channel as the straight one it stands for. */
static uint8_t straight_channel(uint8_t v, unsigned a) {
  unsigned s = ((unsigned)v * 255 + a / 2) / a;
  return (uint8_t)(s > 255 ? 255 : s);
}

void host_canvas_get_image_data(int32_t id, double sx, double sy, double sw, double sh, pixels_cb cb) {
  ensure_channels();
  int w = (int)sw, h = (int)sh;
  if (w < 0) w = 0;
  if (h < 0) h = 0;
  size_t n = (size_t)w * (size_t)h * 4;
  uint8_t *out = n ? (uint8_t *)calloc(n, 1) : NULL;
  Canvas *c = canvas_at(id);
  if (c && c->ctx && n) {
    cairo_surface_flush(c->surface);
    const uint8_t *data = cairo_image_surface_get_data(c->surface);
    size_t stride = (size_t)cairo_image_surface_get_stride(c->surface);
    long long x0 = (long long)floor(sx), y0 = (long long)floor(sy);
    const int R = g_ch_r, G = g_ch_g, B = g_ch_b, A = g_ch_a;
    for (int y = 0; y < h; y++) {
      long long ty = y0 + y;
      if (ty < 0 || ty >= (long long)c->h) continue;
      for (int x = 0; x < w; x++) {
        long long tx = x0 + x;
        if (tx < 0 || tx >= (long long)c->w) continue;
        const uint8_t *p = data + (size_t)ty * stride + (size_t)tx * 4;
        uint8_t *o = out + ((size_t)y * (size_t)w + (size_t)x) * 4;
        unsigned a = p[A];
        if (a == 0) continue; // transparent black, which calloc already left there
        o[0] = straight_channel(p[R], a);
        o[1] = straight_channel(p[G], a);
        o[2] = straight_channel(p[B], a);
        o[3] = (uint8_t)a;
      }
    }
  }
  cb(out, n);
  free(out);
}

static int b64_value(uint8_t ch) {
  if (ch >= 'A' && ch <= 'Z') return ch - 'A';
  if (ch >= 'a' && ch <= 'z') return ch - 'a' + 26;
  if (ch >= '0' && ch <= '9') return ch - '0' + 52;
  if (ch == '+') return 62;
  if (ch == '/') return 63;
  return -1;
}

// Straight RGBA bytes, base64 in as many bytes as `n * 3 / 4`: pixels written at an integer offset
// in the bitmap's own space, replacing what is there, whatever the transform, clip and alpha are.
// Draws a decoded image into a canvas bitmap: the source rect (image pixels) into the dest rect,
// with the canvas's globalAlpha and composite mode applied to the whole operation.
void host_canvas_draw_image(int32_t id, int32_t imageId, double dx, double dy, double dw, double dh,
                            double sx, double sy, double sw, double sh, double smooth) {
  Canvas *c = canvas_at(id);
  if (!c || !c->ctx) return;
  if (!(dw > 0) || !(dh > 0) || !(sw > 0) || !(sh > 0)) return;
  cairo_surface_t *surf = image_surface(imageId);
  if (!surf) return;
  cairo_surface_flush(surf);
  int group = c->alpha < 1 || c->composite != 0;
  cairo_save(c->ctx);
  if (group) cairo_push_group(c->ctx);
  cairo_rectangle(c->ctx, dx, dy, dw, dh);
  cairo_clip(c->ctx);
  cairo_translate(c->ctx, dx - sx * (dw / sw), dy - sy * (dh / sh));
  cairo_scale(c->ctx, dw / sw, dh / sh);
  cairo_set_source_surface(c->ctx, surf, 0, 0);
  // Filtering samples past the source rect's edge at the outermost rows and columns; pad with the
  // edge pixels there, as a browser does, rather than letting the transparent outside darken them.
  cairo_pattern_set_extend(cairo_get_source(c->ctx), CAIRO_EXTEND_PAD);
  cairo_pattern_set_filter(cairo_get_source(c->ctx),
                           smooth > 0.5 ? CAIRO_FILTER_BILINEAR : CAIRO_FILTER_NEAREST);
  cairo_paint(c->ctx);
  if (group) {
    cairo_pop_group_to_source(c->ctx);
    cairo_set_operator(c->ctx, canvas_operator(c->composite));
    cairo_paint_with_alpha(c->ctx, c->alpha);
  }
  cairo_restore(c->ctx);
  cairo_surface_mark_dirty(c->surface);
}

// Draws a canvas's bitmap into a canvas: the source rect (bitmap pixels) into the dest rect,
// under the destination's transform, with its globalAlpha and composite mode applied to the
// whole operation. A canvas drawn into itself reads the pixels it had before the draw.
void host_canvas_draw_canvas(int32_t id, int32_t sourceId, double dx, double dy, double dw, double dh,
                             double sx, double sy, double sw, double sh, double smooth) {
  Canvas *c = canvas_at(id);
  Canvas *src = canvas_at(sourceId);
  if (!c || !c->ctx || !src || !src->surface) return;
  if (!(dw > 0) || !(dh > 0) || !(sw > 0) || !(sh > 0)) return;
  cairo_surface_t *surf = src->surface;
  cairo_surface_t *snapshot = NULL;
  if (src == c) {
    snapshot = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, (int)src->w, (int)src->h);
    cairo_t *copy = cairo_create(snapshot);
    cairo_set_source_surface(copy, src->surface, 0, 0);
    cairo_paint(copy);
    cairo_destroy(copy);
    surf = snapshot;
  }
  cairo_surface_flush(surf);
  int group = c->alpha < 1 || c->composite != 0;
  cairo_save(c->ctx);
  if (group) cairo_push_group(c->ctx);
  cairo_rectangle(c->ctx, dx, dy, dw, dh);
  cairo_clip(c->ctx);
  cairo_translate(c->ctx, dx - sx * (dw / sw), dy - sy * (dh / sh));
  cairo_scale(c->ctx, dw / sw, dh / sh);
  cairo_set_source_surface(c->ctx, surf, 0, 0);
  cairo_pattern_set_extend(cairo_get_source(c->ctx), CAIRO_EXTEND_PAD);
  cairo_pattern_set_filter(cairo_get_source(c->ctx),
                           smooth > 0.5 ? CAIRO_FILTER_BILINEAR : CAIRO_FILTER_NEAREST);
  cairo_paint(c->ctx);
  if (group) {
    cairo_pop_group_to_source(c->ctx);
    cairo_set_operator(c->ctx, canvas_operator(c->composite));
    cairo_paint_with_alpha(c->ctx, c->alpha);
  }
  cairo_restore(c->ctx);
  if (snapshot) cairo_surface_destroy(snapshot);
  cairo_surface_mark_dirty(c->surface);
}

void host_canvas_put_image_data(int32_t id, double dx, double dy, double w, double h, const uint8_t *b64b, size_t n) {
  ensure_channels();
  Canvas *c = canvas_at(id);
  if (!c || !c->ctx) return;
  int iw = (int)w, ih = (int)h;
  if (iw <= 0 || ih <= 0) return;
  size_t want = (size_t)iw * (size_t)ih * 4;
  uint8_t *px = (uint8_t *)malloc(want);
  if (!px) return;
  size_t at = 0;
  int acc = 0, bits = 0;
  for (size_t i = 0; i < n && at < want; i++) {
    int v = b64_value(b64b[i]);
    if (v < 0) continue;
    acc = (acc << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      px[at++] = (uint8_t)((acc >> bits) & 0xff);
    }
  }
  cairo_surface_flush(c->surface);
  uint8_t *data = cairo_image_surface_get_data(c->surface);
  size_t stride = (size_t)cairo_image_surface_get_stride(c->surface);
  const int R = g_ch_r, G = g_ch_g, B = g_ch_b, A = g_ch_a;
  long long x0 = (long long)floor(dx), y0 = (long long)floor(dy);
  for (int y = 0; y < ih; y++) {
    long long ty = y0 + y;
    if (ty < 0 || ty >= (long long)c->h) continue;
    for (int x = 0; x < iw; x++) {
      long long tx = x0 + x;
      if (tx < 0 || tx >= (long long)c->w) continue;
      size_t i = ((size_t)y * (size_t)iw + (size_t)x) * 4;
      unsigned a = px[i + 3];
      uint8_t *p = data + (size_t)ty * stride + (size_t)tx * 4;
      if (a == 0) {
        p[0] = p[1] = p[2] = p[3] = 0;
      } else {
        // Straight to premultiplied, the way the bitmap stores a pixel.
        p[R] = (uint8_t)((px[i] * a + 127) / 255);
        p[G] = (uint8_t)((px[i + 1] * a + 127) / 255);
        p[B] = (uint8_t)((px[i + 2] * a + 127) / 255);
        p[A] = (uint8_t)a;
      }
    }
  }
  cairo_surface_mark_dirty(c->surface);
  free(px);
}

// ---------------------------------------------------------------------------
// Snapshots
//
// The headless host has no window, so the only picture it makes is the one a snapshot asks for:
// the display list replayed into a bitmap of its own at the snapshot's scale, written as a PNG or,
// for pixel tests, as raw premultiplied RGBA top row first.

/** Writes the bitmap as premultiplied RGBA, the four channels of a pixel in that order. */
static int snapshot_write_rgba(const char *name, cairo_surface_t *surface) {
  int w = cairo_image_surface_get_width(surface), h = cairo_image_surface_get_height(surface);
  size_t stride = (size_t)cairo_image_surface_get_stride(surface);
  const unsigned char *data = cairo_image_surface_get_data(surface);
  if (!data) return 0;
  FILE *f = fopen(name, "wb");
  if (!f) return 0;
  unsigned char *row = (unsigned char *)malloc((size_t)w * 4);
  if (!row) {
    fclose(f);
    return 0;
  }
  const int R = g_ch_r, G = g_ch_g, B = g_ch_b, A = g_ch_a;
  int ok = 1;
  for (int y = 0; y < h && ok; y++) {
    const unsigned char *src = data + (size_t)y * stride;
    for (int x = 0; x < w; x++) {
      const unsigned char *p = src + (size_t)x * 4;
      unsigned char *o = row + (size_t)x * 4;
      o[0] = p[R];
      o[1] = p[G];
      o[2] = p[B];
      o[3] = p[A];
    }
    if (fwrite(row, 4, (size_t)w, f) != (size_t)w) ok = 0;
  }
  free(row);
  if (fclose(f) != 0) ok = 0;
  return ok;
}

/** Writes the bitmap as a PNG: straight RGBA, the colour type every snapshot reader takes. */
static int snapshot_write_png(const char *name, cairo_surface_t *surface) {
  int w = cairo_image_surface_get_width(surface), h = cairo_image_surface_get_height(surface);
  size_t stride = (size_t)cairo_image_surface_get_stride(surface);
  const unsigned char *data = cairo_image_surface_get_data(surface);
  if (!data || w <= 0 || h <= 0) return 0;
  FILE *f = fopen(name, "wb");
  if (!f) return 0;
  png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
  png_infop info = png ? png_create_info_struct(png) : NULL;
  unsigned char *row = NULL;
  int ok = 0;
  if (png && info && setjmp(png_jmpbuf(png)) == 0) {
    png_init_io(png, f);
    png_set_IHDR(png, info, (png_uint_32)w, (png_uint_32)h, 8, PNG_COLOR_TYPE_RGB_ALPHA,
                 PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
    png_write_info(png, info);
    row = (unsigned char *)malloc((size_t)w * 4);
    if (row) {
      const int R = g_ch_r, G = g_ch_g, B = g_ch_b, A = g_ch_a;
      for (int y = 0; y < h; y++) {
        const unsigned char *src = data + (size_t)y * stride;
        for (int x = 0; x < w; x++) {
          const unsigned char *p = src + (size_t)x * 4;
          unsigned char *o = row + (size_t)x * 4;
          unsigned a = p[A];
          if (a == 0) {
            o[0] = o[1] = o[2] = o[3] = 0;
          } else {
            // Premultiplied to straight, the way a PNG holds a pixel.
            o[0] = straight_channel(p[R], a);
            o[1] = straight_channel(p[G], a);
            o[2] = straight_channel(p[B], a);
            o[3] = (unsigned char)a;
          }
        }
        png_write_row(png, row);
      }
      png_write_end(png, NULL);
      ok = 1;
    }
  }
  free(row);
  if (png) png_destroy_write_struct(&png, info ? &info : NULL);
  if (fclose(f) != 0) ok = 0;
  return ok;
}

// Paints the display list at the snapshot's scale and writes it. Returns 1 on success.
// ---------------------------------------------------------------------------
// Composited snapshots (NATIVE_SNAPSHOT_COMPOSITED)
//
// The flat replay draws every command where it stands. A composited render rasters each layer's
// sublist once, then replays the root list drawing every layer ref from its raster: the same
// picture, built from the pieces a compositor keeps. A layer with no transform composites one
// pixel for one pixel and must match the flat replay exactly; a transformed layer is rastered and
// then moved, as a browser does, and differs the way any raster-then-transform does.

static void free_rasters(void) {
  for (int i = 0; i < g_raster_count; i++) {
    if (g_rasters[i].surf != NULL) cairo_surface_destroy(g_rasters[i].surf);
  }
  free(g_rasters);
  g_rasters = NULL;
  g_raster_count = 0;
}

/** The ink box of an image surface: the pixels whose alpha isn't zero, or 0 when it is empty. */
static int ink_box(cairo_surface_t *surface, int vw, int vh, int *x, int *y, int *w, int *h) {
  cairo_surface_flush(surface);
  const unsigned char *data = cairo_image_surface_get_data(surface);
  int stride = cairo_image_surface_get_stride(surface);
  int minx = vw, miny = vh, maxx = -1, maxy = -1;
  for (int row = 0; row < vh; row++) {
    const unsigned char *line = data + (size_t)row * (size_t)stride;
    for (int col = 0; col < vw; col++) {
      if (line[col * 4 + 3] == 0) continue;
      if (col < minx) minx = col;
      if (col > maxx) maxx = col;
      if (row < miny) miny = row;
      if (row > maxy) maxy = row;
    }
  }
  if (maxx < 0 || maxy < 0) return 0;
  *x = minx;
  *y = miny;
  *w = maxx - minx + 1;
  *h = maxy - miny + 1;
  return 1;
}

/** Rasters one layer's sublist into page space at `scale`, cropped to its ink. */
static void raster_layer(int id, double scale, int vw, int vh, LayerRaster *out) {
  out->surf = NULL;
  if (id < 0 || id >= g_layer_count) return;
  cairo_surface_t *full = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, vw, vh);
  if (cairo_surface_status(full) != CAIRO_STATUS_SUCCESS) {
    cairo_surface_destroy(full);
    return;
  }
  cairo_t *cr = cairo_create(full);
  if (cairo_status(cr) != CAIRO_STATUS_SUCCESS) {
    cairo_destroy(cr);
    cairo_surface_destroy(full);
    return;
  }
  // Nothing behind the layer's own commands: the page it paints over is composited separately.
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
  cairo_set_source_rgba(cr, 0, 0, 0, 0);
  cairo_paint(cr);
  cairo_set_operator(cr, CAIRO_OPERATOR_OVER);
  cairo_scale(cr, scale, scale);
  double saved_scale = g_scale;
  g_scale = scale;
  CmdList *saved = g_list;
  g_list = &g_layers[id].list;
  // A nested layer paints its own commands inside this raster, as the flat replay would.
  LayerRaster *saved_rasters = g_rasters;
  g_rasters = NULL;
  Replay r;
  memset(&r, 0, sizeof(r));
  r.cr = cr;
  r.surface = full;
  cairo_get_matrix(cr, &r.base);
  ensure_channels();
  replay_range(&r, 0);
  g_rasters = saved_rasters;
  g_list = saved;
  g_scale = saved_scale;
  cairo_destroy(cr);
  int x = 0, y = 0, w = 0, h = 0;
  if (ink_box(full, vw, vh, &x, &y, &w, &h)) {
    cairo_surface_t *crop = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    if (cairo_surface_status(crop) == CAIRO_STATUS_SUCCESS) {
      cairo_t *ccr = cairo_create(crop);
      if (cairo_status(ccr) == CAIRO_STATUS_SUCCESS) {
        cairo_set_operator(ccr, CAIRO_OPERATOR_SOURCE);
        cairo_set_source_surface(ccr, full, -x, -y);
        cairo_paint(ccr);
      }
      cairo_destroy(ccr);
      out->surf = crop;
      out->x = x;
      out->y = y;
      out->w = w;
      out->h = h;
    } else {
      cairo_surface_destroy(crop);
    }
  }
  cairo_surface_destroy(full);
}

static void draw_layer_raster(cairo_t *cr, const LayerRaster *lr) {
  if (lr == NULL || lr->surf == NULL || lr->w <= 0 || lr->h <= 0) return;
  cairo_pattern_t *pat = cairo_pattern_create_for_surface(lr->surf);
  if (cairo_pattern_status(pat) != CAIRO_STATUS_SUCCESS) {
    cairo_pattern_destroy(pat);
    return;
  }
  // The raster is page space at the snapshot's scale: user space is page pixels, the pattern is
  // the raster's own, so the matrix scales and moves it to where its ink box sits.
  cairo_matrix_t m;
  cairo_matrix_init_scale(&m, g_raster_scale, g_raster_scale);
  cairo_matrix_translate(&m, -(double)lr->x / g_raster_scale, -(double)lr->y / g_raster_scale);
  cairo_pattern_set_matrix(pat, &m);
  cairo_save(cr);
  cairo_rectangle(cr, (double)lr->x / g_raster_scale, (double)lr->y / g_raster_scale,
                  (double)lr->w / g_raster_scale, (double)lr->h / g_raster_scale);
  cairo_clip(cr);
  cairo_set_source(cr, pat);
  cairo_paint(cr);
  cairo_restore(cr);
  cairo_pattern_destroy(pat);
}

// ---------------------------------------------------------------------------
// Chunk-based compositing
//
// The walk lives in compositor/chunks.c so both hosts share the rule; this file maps the
// display list to its command view and rasters what the walk produces.

static int chunk_cmd_count(void *ctx, int list_id) {
  (void)ctx;
  if (list_id < 0) return (int)g_root.count;
  if (list_id >= g_layer_count) return -1;
  return (int)g_layers[list_id].list.count;
}

static int chunk_cmd_view(void *ctx, int list_id, int index, CompCmdView *out) {
  (void)ctx;
  CmdList *l = list_id < 0 ? &g_root : &g_layers[list_id].list;
  if (index < 0 || (size_t)index >= l->count) return 0;
  Cmd *c = &l->cmds[index];
  memset(out, 0, sizeof(*out));
  out->serial = c->serial;
  switch (c->kind) {
    case CMD_TRANSFORM:
      out->kind = COMP_CMD_TRANSFORM;
      out->matrix.m[0] = (float)c->p0;
      out->matrix.m[1] = (float)c->p1;
      out->matrix.m[4] = (float)c->p2;
      out->matrix.m[5] = (float)c->p3;
      out->matrix.m[10] = 1.0f;
      out->matrix.m[12] = (float)c->r[0];
      out->matrix.m[13] = (float)c->r[1];
      out->matrix.m[15] = 1.0f;
      return 1;
    case CMD_CLIP:
      out->kind = COMP_CMD_CLIP;
      out->x = c->x; out->y = c->y; out->w = c->w; out->h = c->h;
      return 1;
    case CMD_CLIP_ROUND: {
      out->kind = COMP_CMD_CLIP_ROUND;
      out->x = c->x; out->y = c->y; out->w = c->w; out->h = c->h;
      double r = 0;
      for (int k = 0; k < 8; k++) if (c->r[k] > r) r = c->r[k];
      out->radius = r;
      return 1;
    }
    case CMD_CLIP_POLY:
    case CMD_CLIP_ELLIPSE:
    case CMD_CLIP_SHAPE:
      out->kind = COMP_CMD_CLIP_SHAPED;
      return 1;
    case CMD_EFFECT_PUSH: {
      EffectSpec spec;
      effect_spec_parse(&spec, c->text);
      out->kind = COMP_CMD_EFFECT;
      out->alpha = (float)spec.alpha;
      out->simple = spec.count == 0 && spec.bcount == 0 && spec.blend == 0;
      return 1;
    }
    case CMD_UNCLIP:
    case CMD_EFFECT_POP:
      out->kind = COMP_CMD_POP;
      return 1;
    case CMD_LAYER_REF:
      out->kind = COMP_CMD_LAYER_REF;
      out->layer = c->layer;
      return 1;
    case CMD_MASK_PUSH:
    case CMD_MASK_SPLIT:
    case CMD_MASK_POP:
      out->kind = COMP_CMD_MASK;
      return 1;
    case CMD_PERSPECTIVE_PUSH:
    case CMD_PERSPECTIVE_POP:
      out->kind = COMP_CMD_PERSPECTIVE;
      return 1;
    default:
      out->kind = COMP_CMD_DRAW;
      return 1;
  }
}

static const CompCmdSource CHUNK_SOURCE = { chunk_cmd_count, chunk_cmd_view };

/** The ink box of an image surface, or 0 when it paints nothing. */
static int surface_ink(cairo_surface_t *surface, int pw, int ph, int *x, int *y, int *w, int *h) {
  cairo_surface_flush(surface);
  const unsigned char *data = cairo_image_surface_get_data(surface);
  int stride = cairo_image_surface_get_stride(surface);
  int minx = pw, miny = ph, maxx = -1, maxy = -1;
  if (data == NULL) return 0;
  for (int row = 0; row < ph; row++) {
    const unsigned char *line = data + (size_t)row * (size_t)stride;
    for (int col = 0; col < pw; col++) {
      if (line[col * 4 + 3] == 0) continue;
      if (col < minx) minx = col;
      if (col > maxx) maxx = col;
      if (row < miny) miny = row;
      if (row > maxy) maxy = row;
    }
  }
  if (maxx < minx || maxy < miny) return 0;
  *x = minx; *y = miny; *w = maxx - minx + 1; *h = maxy - miny + 1;
  return 1;
}

typedef struct {
  cairo_surface_t *surf;
  int x, y, w, h;
} ChunkInk;

/** Renders the walk's chunks over the page background into `target` (device pixels). */
static int render_walk(CompWalk *w, double scale, int pw, int ph, cairo_surface_t *target) {
  int n = w->count;
  ChunkInk *inks = (ChunkInk *)calloc((size_t)(n > 0 ? n : 1), sizeof(ChunkInk));
  CompChunk *cc = (CompChunk *)calloc((size_t)(n > 0 ? n : 1), sizeof(CompChunk));
  int *layer_of = (int *)calloc((size_t)(n > 0 ? n : 1), sizeof(int));
  CompRect *layer_bounds = (CompRect *)calloc((size_t)(n > 0 ? n : 1), sizeof(CompRect));
  if (inks == NULL || cc == NULL || layer_of == NULL || layer_bounds == NULL) {
    free(inks); free(cc); free(layer_of); free(layer_bounds);
    return 0;
  }
  for (int i = 0; i < n; i++) {
    CompWalkChunk *c = &w->chunks[i];
    if (c->count <= 0) continue;
    cairo_matrix_t cm;
    cm.xx = c->m.m[0]; cm.yx = c->m.m[1]; cm.xy = c->m.m[4]; cm.yy = c->m.m[5];
    cm.x0 = c->m.m[12]; cm.y0 = c->m.m[13];
    cairo_surface_t *full = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, pw, ph);
    if (cairo_surface_status(full) != CAIRO_STATUS_SUCCESS) {
      cairo_surface_destroy(full);
      continue;
    }
    cairo_t *cr = cairo_create(full);
    if (cairo_status(cr) == CAIRO_STATUS_SUCCESS) {
      cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
      cairo_set_source_rgba(cr, 0, 0, 0, 0);
      cairo_paint(cr);
      cairo_set_operator(cr, CAIRO_OPERATOR_OVER);
      cairo_set_matrix(cr, &cm);
      double saved_scale = g_scale;
      g_scale = fabs(cm.xx) > 0 ? fabs(cm.xx) : scale;
      CmdList *ll = c->list_id < 0 ? &g_root : &g_layers[c->list_id].list;
      CmdList *saved_list = g_list;
      g_list = ll;
      size_t saved_limit = g_replay_limit;
      g_replay_limit = (size_t)(c->first + c->count);
      Replay r;
      memset(&r, 0, sizeof(r));
      r.cr = cr;
      r.surface = full;
      r.base = cm;
      r.transforms = c->transforms;
      ensure_channels();
      replay_range(&r, (size_t)c->first);
      g_replay_limit = saved_limit;
      g_list = saved_list;
      g_scale = saved_scale;
    }
    cairo_destroy(cr);
    int ix = 0, iy = 0, iw = 0, ih = 0;
    if (surface_ink(full, pw, ph, &ix, &iy, &iw, &ih)) {
      cairo_surface_t *crop = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, iw, ih);
      if (cairo_surface_status(crop) == CAIRO_STATUS_SUCCESS) {
        cairo_t *ccr = cairo_create(crop);
        if (cairo_status(ccr) == CAIRO_STATUS_SUCCESS) {
          cairo_set_operator(ccr, CAIRO_OPERATOR_SOURCE);
          cairo_set_source_surface(ccr, full, -ix, -iy);
          cairo_paint(ccr);
        }
        cairo_destroy(ccr);
        inks[i].surf = crop;
        inks[i].x = ix; inks[i].y = iy; inks[i].w = iw; inks[i].h = ih;
      } else {
        cairo_surface_destroy(crop);
      }
    }
    cairo_surface_destroy(full);
    cc[i].serial = 0;
    cc[i].first = c->first;
    cc[i].count = c->count;
    cc[i].bounds = (CompRect){inks[i].x, inks[i].y, inks[i].w, inks[i].h};
    cc[i].inflated = cc[i].bounds;
    cc[i].transform = comp_matrix_identity();
    cc[i].has_clip = 0;
    cc[i].opacity = c->alpha;
    cc[i].eligible = 1;
    cc[i].layer = -1;
  }
  int layers = comp_layerize(cc, n, layer_of, layer_bounds, n > 0 ? n : 1);

  cairo_t *dst = cairo_create(target);
  if (cairo_status(dst) != CAIRO_STATUS_SUCCESS) {
    cairo_destroy(dst);
    for (int i = 0; i < n; i++) if (inks[i].surf) cairo_surface_destroy(inks[i].surf);
    free(inks); free(cc); free(layer_of); free(layer_bounds);
    return 0;
  }
  cairo_set_operator(dst, CAIRO_OPERATOR_SOURCE);
  set_fill(dst, g_background);
  cairo_paint(dst);
  cairo_set_operator(dst, CAIRO_OPERATOR_OVER);

  #define HOST_TILE_SLOTS 8
  int pool_layer[HOST_TILE_SLOTS], pool_x[HOST_TILE_SLOTS], pool_y[HOST_TILE_SLOTS], pool_last[HOST_TILE_SLOTS];
  cairo_surface_t *pool_surf[HOST_TILE_SLOTS];
  for (int i = 0; i < HOST_TILE_SLOTS; i++) pool_surf[i] = NULL;
  CompTilePool pool;
  comp_tile_pool_init(&pool, pool_layer, pool_x, pool_y, pool_last, HOST_TILE_SLOTS);

  for (int l = 0; l < layers; l++) {
    float alpha = 1.0f;
    int tiles = comp_tile_count(layer_bounds[l]);
    for (int t = 0; t < tiles; t++) {
      CompRect tile;
      if (!comp_tile_at(layer_bounds[l], t, &tile)) break;
      int slot = comp_tile_pool_touch(&pool, l, tile.x, tile.y);
      if (slot < 0) break;
      if (pool_surf[slot] == NULL) {
        pool_surf[slot] = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, COMP_TILE_SIZE, COMP_TILE_SIZE);
        if (cairo_surface_status(pool_surf[slot]) != CAIRO_STATUS_SUCCESS) {
          cairo_surface_destroy(pool_surf[slot]);
          pool_surf[slot] = NULL;
          break;
        }
      }
      cairo_t *tcr = cairo_create(pool_surf[slot]);
      if (cairo_status(tcr) != CAIRO_STATUS_SUCCESS) {
        cairo_destroy(tcr);
        break;
      }
      cairo_set_operator(tcr, CAIRO_OPERATOR_SOURCE);
      cairo_set_source_rgba(tcr, 0, 0, 0, 0);
      cairo_paint(tcr);
      cairo_set_operator(tcr, CAIRO_OPERATOR_OVER);
      cairo_translate(tcr, -(double)tile.x, -(double)tile.y);
      for (int i = 0; i < n; i++) {
        if (layer_of[i] != l || inks[i].surf == NULL) continue;
        CompWalkChunk *c = &w->chunks[i];
        alpha = c->alpha;
        cairo_save(tcr);
        for (int k = 0; k < c->clip_count; k++) {
          const CompWalkClip *cl = &c->clips[k];
          cairo_new_path(tcr);
          if (cl->r > 0) rounded_rect_path(tcr, cl->x, cl->y, cl->w, cl->h, cl->r);
          else cairo_rectangle(tcr, cl->x, cl->y, cl->w, cl->h);
          cairo_clip(tcr);
        }
        cairo_set_source_surface(tcr, inks[i].surf, (double)inks[i].x, (double)inks[i].y);
        cairo_rectangle(tcr, (double)inks[i].x, (double)inks[i].y, (double)inks[i].w, (double)inks[i].h);
        cairo_clip(tcr);
        cairo_paint(tcr);
        cairo_restore(tcr);
      }
      cairo_destroy(tcr);
      cairo_save(dst);
      cairo_set_source_surface(dst, pool_surf[slot], (double)tile.x, (double)tile.y);
      cairo_rectangle(dst, (double)tile.x, (double)tile.y, (double)COMP_TILE_SIZE, (double)COMP_TILE_SIZE);
      cairo_clip(dst);
      cairo_paint_with_alpha(dst, alpha);
      cairo_restore(dst);
    }
  }
  for (int i = 0; i < HOST_TILE_SLOTS; i++) if (pool_surf[i] != NULL) cairo_surface_destroy(pool_surf[i]);
  cairo_destroy(dst);
  for (int i = 0; i < n; i++) if (inks[i].surf) cairo_surface_destroy(inks[i].surf);
  free(inks); free(cc); free(layer_of); free(layer_bounds);
  return 1;
}

/** Writes a surface to the named path, as PNG or raw RGBA by its extension. */
static int snapshot_write_named(const uint8_t *path, size_t path_len, cairo_surface_t *surface) {
  char name[4096];
  memcpy(name, path, path_len);
  name[path_len] = '\0';
  if (path_len >= 5 && memcmp(name + path_len - 5, ".rgba", 5) == 0) {
    return snapshot_write_rgba(name, surface);
  }
  return snapshot_write_png(name, surface);
}

int32_t host_snapshot_composited(const uint8_t *path, size_t path_len, double width, double height, double scale) {
  if (path_len == 0 || path_len >= 4096) return 0;
  if (!(width > 0) || !(height > 0)) return 0;
  if (!(scale > 0)) scale = 1;
  double fw = width * scale, fh = height * scale;
  if (fw > 16384 || fh > 16384) return 0;
  int pw = (int)fw, ph = (int)fh;
  if (pw <= 0 || ph <= 0) return 0;
  cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, pw, ph);
  if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
    cairo_surface_destroy(surface);
    return 0;
  }
  // A frame whose state the chunks can express is rendered through them. One that needs a mask,
  // a projection, a filter group over several chunks or a rotated clip falls back to the replay,
  // which draws the same picture from the flat list with the layers drawn from their rasters.
  CompWalk *walk = (CompWalk *)malloc(sizeof(CompWalk));
  int chunked = 0;
  if (walk != NULL) {
    if (comp_walk(&CHUNK_SOURCE, NULL, scale, walk)) {
      chunked = render_walk(walk, scale, pw, ph, surface);
      if (getenv("NATIVE_CHUNKS_DEBUG") != NULL) fprintf(stderr, "native: chunks %d\n", walk->count);
    }
    free(walk);
  }
  if (!chunked) {
    cairo_t *cr = cairo_create(surface);
    if (cairo_status(cr) != CAIRO_STATUS_SUCCESS) {
      cairo_destroy(cr);
      cairo_surface_destroy(surface);
      return 0;
    }
    // Raster every layer first, so the composite pass only draws.
    free_rasters();
    g_rasters = (LayerRaster *)calloc(g_layer_count > 0 ? (size_t)g_layer_count : 1, sizeof(LayerRaster));
    if (g_rasters == NULL) {
      cairo_destroy(cr);
      cairo_surface_destroy(surface);
      return 0;
    }
    g_raster_count = g_layer_count;
    g_raster_scale = scale;
    for (int i = 0; i < g_layer_count; i++) raster_layer(i, scale, pw, ph, &g_rasters[i]);
    cairo_scale(cr, scale, scale);
    double saved_scale = g_scale;
    g_scale = scale;
    Replay r;
    replay(&r, cr, surface, width, height);
    g_scale = saved_scale;
    cairo_destroy(cr);
  }
  cairo_surface_flush(surface);
  int ok = snapshot_write_named(path, path_len, surface);
  cairo_surface_destroy(surface);
  free_rasters();
  return ok ? 1 : 0;
}

int32_t host_snapshot(const uint8_t *path, size_t path_len, double width, double height, double scale) {
  if (path_len == 0 || path_len >= 4096) return 0;
  if (!(width > 0) || !(height > 0)) return 0;
  if (!(scale > 0)) scale = 1;
  double fw = width * scale, fh = height * scale;
  if (fw > 16384 || fh > 16384) return 0;
  int pw = (int)fw, ph = (int)fh;
  if (pw <= 0 || ph <= 0) return 0;
  cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, pw, ph);
  if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
    cairo_surface_destroy(surface);
    return 0;
  }
  cairo_t *cr = cairo_create(surface);
  if (cairo_status(cr) == CAIRO_STATUS_SUCCESS) {
    cairo_scale(cr, scale, scale);
    // The replay rounds text baselines and raster tiles to the bitmap's pixels, so it needs the
    // scale the bitmap is drawn at.
    double saved = g_scale;
    g_scale = scale;
    double started = frame_times() ? now_ms() : 0;
    Replay r;
    replay(&r, cr, surface, width, height);
    if (frame_times()) fprintf(stderr, "native: replay %g ms\n", now_ms() - started);
    g_scale = saved;
  }
  cairo_destroy(cr);
  cairo_surface_flush(surface);
  char name[4096];
  memcpy(name, path, path_len);
  name[path_len] = '\0';
  int ok;
  if (path_len >= 5 && memcmp(name + path_len - 5, ".rgba", 5) == 0) {
    ok = snapshot_write_rgba(name, surface);
  } else {
    ok = snapshot_write_png(name, surface);
  }
  cairo_surface_destroy(surface);
  return ok ? 1 : 0;
}

// ---------------------------------------------------------------------------
// localStorage
//
// One JSON object per app, held in memory and written back on every change. The file lives under
// the XDG data directory, or wherever NATIVE_STORAGE points, which is what the tests use.

typedef struct {
  char *key;
  char *value;
} StorageRow;

static StorageRow *g_storage = NULL;
static size_t g_storage_count = 0, g_storage_cap = 0;
static char *g_storage_path = NULL;

/** The row holding a key, or null. */
static StorageRow *storage_find(const char *key, size_t n) {
  for (size_t i = 0; i < g_storage_count; i++) {
    if (strlen(g_storage[i].key) == n && memcmp(g_storage[i].key, key, n) == 0) return &g_storage[i];
  }
  return NULL;
}

/** Holds a key and a value, replacing the value the key had. */
static void storage_put(const char *key, size_t kn, const char *value, size_t vn) {
  StorageRow *row = storage_find(key, kn);
  if (row) {
    char *v = (char *)malloc(vn + 1);
    if (!v) return;
    memcpy(v, value, vn);
    v[vn] = '\0';
    free(row->value);
    row->value = v;
    return;
  }
  if (g_storage_count == g_storage_cap) {
    size_t cap = g_storage_cap ? g_storage_cap * 2 : 16;
    StorageRow *rows = (StorageRow *)realloc(g_storage, cap * sizeof(StorageRow));
    if (!rows) return;
    g_storage = rows;
    g_storage_cap = cap;
  }
  char *k = (char *)malloc(kn + 1);
  char *v = (char *)malloc(vn + 1);
  if (!k || !v) {
    free(k);
    free(v);
    return;
  }
  memcpy(k, key, kn);
  k[kn] = '\0';
  memcpy(v, value, vn);
  v[vn] = '\0';
  g_storage[g_storage_count].key = k;
  g_storage[g_storage_count].value = v;
  g_storage_count++;
}

static void storage_drop(size_t at) {
  free(g_storage[at].key);
  free(g_storage[at].value);
  memmove(&g_storage[at], &g_storage[at + 1], (g_storage_count - at - 1) * sizeof(StorageRow));
  g_storage_count--;
}

// --- JSON, as much of it as one object of strings needs ---------------------

static void json_write_string(FILE *f, const char *s) {
  fputc('"', f);
  for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
    switch (*p) {
      case '"': fputs("\\\"", f); break;
      case '\\': fputs("\\\\", f); break;
      case '\n': fputs("\\n", f); break;
      case '\r': fputs("\\r", f); break;
      case '\t': fputs("\\t", f); break;
      case '\b': fputs("\\b", f); break;
      case '\f': fputs("\\f", f); break;
      default:
        if (*p < 0x20) fprintf(f, "\\u%04x", *p);
        else fputc(*p, f);
    }
  }
  fputc('"', f);
}

static int hex_digit(int c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

/** Appends a code point to a UTF-8 buffer, returning its length. */
static size_t utf8_put(unsigned cp, char *out) {
  if (cp < 0x80) {
    out[0] = (char)cp;
    return 1;
  }
  if (cp < 0x800) {
    out[0] = (char)(0xc0 | (cp >> 6));
    out[1] = (char)(0x80 | (cp & 0x3f));
    return 2;
  }
  if (cp < 0x10000) {
    out[0] = (char)(0xe0 | (cp >> 12));
    out[1] = (char)(0x80 | ((cp >> 6) & 0x3f));
    out[2] = (char)(0x80 | (cp & 0x3f));
    return 3;
  }
  out[0] = (char)(0xf0 | (cp >> 18));
  out[1] = (char)(0x80 | ((cp >> 12) & 0x3f));
  out[2] = (char)(0x80 | ((cp >> 6) & 0x3f));
  out[3] = (char)(0x80 | (cp & 0x3f));
  return 4;
}

static const char *json_skip_space(const char *p) {
  while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
  return p;
}

/** Reads a JSON string at `p`, in place, and returns where it ends. The buffer shrinks. */
static const char *json_read_string(const char *p, char **out, size_t *len) {
  *out = NULL;
  *len = 0;
  if (*p != '"') return p;
  p++;
  size_t cap = strlen(p) + 1, at = 0;
  char *buf = (char *)malloc(cap);
  if (!buf) return p;
  while (*p && *p != '"') {
    if (*p == '\\') {
      p++;
      switch (*p) {
        case 'n': buf[at++] = '\n'; p++; break;
        case 'r': buf[at++] = '\r'; p++; break;
        case 't': buf[at++] = '\t'; p++; break;
        case 'b': buf[at++] = '\b'; p++; break;
        case 'f': buf[at++] = '\f'; p++; break;
        case 'u': {
          unsigned cp = 0;
          int ok = 1;
          for (int i = 0; i < 4; i++) {
            int d = hex_digit((unsigned char)p[1 + i]);
            if (d < 0) {
              ok = 0;
              break;
            }
            cp = cp * 16 + (unsigned)d;
          }
          if (!ok) break;
          p += 5;
          if (cp >= 0xd800 && cp < 0xdc00 && p[0] == '\\' && p[1] == 'u') {
            unsigned lo = 0;
            int lok = 1;
            for (int i = 0; i < 4; i++) {
              int d = hex_digit((unsigned char)p[2 + i]);
              if (d < 0) {
                lok = 0;
                break;
              }
              lo = lo * 16 + (unsigned)d;
            }
            if (lok && lo >= 0xdc00 && lo < 0xe000) {
              cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
              p += 6;
            }
          }
          at += utf8_put(cp, buf + at);
          break;
        }
        default: buf[at++] = *p; p++; break;
      }
    } else {
      buf[at++] = *p++;
    }
    if (at + 4 >= cap) {
      cap *= 2;
      char *grown = (char *)realloc(buf, cap);
      if (!grown) break;
      buf = grown;
    }
  }
  if (*p == '"') p++;
  buf[at] = '\0';
  *out = buf;
  *len = at;
  return p;
}

/** Skips one JSON value, whatever it is. */
static const char *json_skip_value(const char *p) {
  p = json_skip_space(p);
  if (*p == '"') {
    char *s = NULL;
    size_t n = 0;
    p = json_read_string(p, &s, &n);
    free(s);
    return p;
  }
  if (*p == '{' || *p == '[') {
    char close = *p == '{' ? '}' : ']';
    int depth = 0;
    while (*p) {
      if (*p == '"') {
        char *s = NULL;
        size_t n = 0;
        p = json_read_string(p, &s, &n);
        free(s);
        continue;
      }
      if (*p == '{' || *p == '[') depth++;
      else if (*p == '}' || *p == ']') {
        depth--;
        if (depth == 0) {
          p++;
          break;
        }
      }
      p++;
    }
    (void)close;
    return p;
  }
  while (*p && *p != ',' && *p != '}' && *p != ']') p++;
  return p;
}

/** Loads the object in `text` into the table, keeping the string values it holds. */
static void storage_load(const char *text) {
  const char *p = json_skip_space(text);
  if (*p != '{') return;
  p++;
  for (;;) {
    p = json_skip_space(p);
    if (*p != '"') break;
    char *key = NULL;
    size_t kn = 0;
    p = json_read_string(p, &key, &kn);
    p = json_skip_space(p);
    if (*p == ':') p++;
    p = json_skip_space(p);
    if (*p == '"') {
      char *value = NULL;
      size_t vn = 0;
      p = json_read_string(p, &value, &vn);
      if (key && value) storage_put(key, kn, value, vn);
      free(value);
    } else {
      p = json_skip_value(p);
    }
    free(key);
    p = json_skip_space(p);
    if (*p == ',') {
      p++;
      continue;
    }
    break;
  }
}

static void storage_save(void) {
  if (!g_storage_path) return;
  size_t cap = strlen(g_storage_path) + 5;
  char *tmp = (char *)malloc(cap);
  if (!tmp) return;
  snprintf(tmp, cap, "%s.tmp", g_storage_path);
  // The app's state belongs to the user running it: the file is made 0600 and the directories
  // that hold it 0700, whatever the process umask would otherwise allow.
  int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (fd < 0) {
    free(tmp);
    return;
  }
  // A temp file left from an earlier write keeps the mode it was made with, so narrow it too.
  fchmod(fd, 0600);
  FILE *f = fdopen(fd, "wb");
  if (!f) {
    close(fd);
    free(tmp);
    return;
  }
  fputc('{', f);
  for (size_t i = 0; i < g_storage_count; i++) {
    if (i > 0) fputc(',', f);
    json_write_string(f, g_storage[i].key);
    fputc(':', f);
    json_write_string(f, g_storage[i].value);
  }
  fputc('}', f);
  if (fclose(f) == 0) rename(tmp, g_storage_path);
  else remove(tmp);
  free(tmp);
}

/** Makes every directory on the way to `path`, which ends in a file name. */
static void make_dirs(const char *path) {
  char buf[4096];
  size_t n = strlen(path);
  if (n >= sizeof(buf)) return;
  memcpy(buf, path, n + 1);
  for (size_t i = 1; i < n; i++) {
    if (buf[i] != '/') continue;
    buf[i] = '\0';
    mkdir(buf, 0700);
    buf[i] = '/';
  }
}

void host_storage_dir(window_text_cb cb) {
  const char *path = g_storage_path;
  if (path == NULL) { cb((const uint8_t *)"", 0); return; }
  const char *slash = strrchr(path, '/');
  if (slash == NULL) { cb((const uint8_t *)"", 0); return; }
  cb((const uint8_t *)path, (size_t)(slash - path));
}

void host_storage_open(const uint8_t *name, size_t n) {
  if (g_storage_path) return;
  const char *env = getenv("NATIVE_STORAGE");
  char dir[4096];
  if (env && *env) {
    size_t len = strlen(env);
    if (len >= sizeof(dir)) return;
    memcpy(dir, env, len + 1);
    make_dirs(dir);
  } else {
    const char *base = getenv("XDG_DATA_HOME");
    char fallback[4096];
    if (!base || !*base) {
      const char *home = getenv("HOME");
      if (home && *home) {
        snprintf(fallback, sizeof(fallback), "%s/.local/share", home);
        base = fallback;
      } else {
        const char *tmpdir = getenv("TMPDIR");
        snprintf(fallback, sizeof(fallback), "%s", tmpdir && *tmpdir ? tmpdir : "/tmp");
        base = fallback;
      }
    }
    // The app's name, with anything a path doesn't want replaced.
    char safe[65];
    size_t at = 0;
    for (size_t i = 0; i < n && at < 64; i++) {
      unsigned char ch = name[i];
      int keep = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') ||
                 ch == '-' || ch == '_';
      safe[at++] = keep ? (char)ch : '-';
    }
    safe[at] = '\0';
    if (at == 0) {
      memcpy(safe, "app", 4);
    }
    // base + "/native/" + safe + "/localStorage.json", refused rather than cut short.
    size_t blen = strlen(base), slen = strlen(safe);
    static const char mid[] = "/native/";
    static const char tail[] = "/localStorage.json";
    if (blen + slen + sizeof(mid) + sizeof(tail) > sizeof(dir)) return;
    memcpy(dir, base, blen);
    memcpy(dir + blen, mid, sizeof(mid) - 1);
    memcpy(dir + blen + sizeof(mid) - 1, safe, slen);
    memcpy(dir + blen + sizeof(mid) - 1 + slen, tail, sizeof(tail));
    make_dirs(dir);
  }
  size_t len = strlen(dir);
  g_storage_path = (char *)malloc(len + 1);
  if (!g_storage_path) return;
  memcpy(g_storage_path, dir, len + 1);
  FILE *f = fopen(g_storage_path, "rb");
  if (!f) return;
  fseek(f, 0, SEEK_END);
  long size = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (size <= 0 || size > 16 * 1024 * 1024) {
    fclose(f);
    return;
  }
  char *text = (char *)malloc((size_t)size + 1);
  if (!text) {
    fclose(f);
    return;
  }
  size_t got = fread(text, 1, (size_t)size, f);
  fclose(f);
  text[got] = '\0';
  storage_load(text);
  free(text);
}

int32_t host_storage_has(const uint8_t *key, size_t n) {
  if (!g_storage_path) return 0;
  return storage_find((const char *)key, n) ? 1 : 0;
}

void host_storage_get(const uint8_t *key, size_t n, str_cb cb) {
  StorageRow *row = g_storage_path ? storage_find((const char *)key, n) : NULL;
  if (row) cb((const uint8_t *)row->value, strlen(row->value));
  else cb((const uint8_t *)"", 0);
}

void host_storage_set(const uint8_t *key, size_t kn, const uint8_t *value, size_t vn) {
  if (!g_storage_path) return;
  storage_put((const char *)key, kn, (const char *)value, vn);
  storage_save();
}

void host_storage_remove(const uint8_t *key, size_t n) {
  if (!g_storage_path) return;
  for (size_t i = 0; i < g_storage_count; i++) {
    if (strlen(g_storage[i].key) == n && memcmp(g_storage[i].key, key, n) == 0) {
      storage_drop(i);
      storage_save();
      return;
    }
  }
}

void host_storage_clear(void) {
  if (!g_storage_path) return;
  while (g_storage_count > 0) storage_drop(g_storage_count - 1);
  storage_save();
}

int32_t host_storage_length(void) { return g_storage_path ? (int32_t)g_storage_count : 0; }

void host_storage_key(int32_t index, str_cb cb) {
  if (g_storage_path && index >= 0 && (size_t)index < g_storage_count) {
    const char *key = g_storage[index].key;
    cb((const uint8_t *)key, strlen(key));
    return;
  }
  cb((const uint8_t *)"", 0);
}

// ---------------------------------------------------------------------------
// Accessibility, line breaking and select menus
//
// The runtime publishes the page's accessibility tree after every layout (runtime/ax-tree.ts):
// each node's role, name, value, states and frame, as JSON. Here it is republished on Linux's
// accessibility bus — the AT-SPI one screen readers and inspection tools talk to — so assistive
// technology sees the page itself rather than a stand-in. A press, a focus request or a caret move
// from a client comes back through the event queue as ordinary input, so the page's own handlers
// see it, the way they see a pointer on macOS.
//
// A run with no session bus, or no accessibility bus on it, simply has no assistive technology
// attached: the tree is still built and NATIVE_AX_DUMP prints it, and nothing is published. Line
// breaking wants a segmenter, which this host doesn't have yet; a run with no break opportunities
// is laid out as one segment.

/** The accessible root object every application publishes, and where a node's references point. */
static const char AX_ROOT[] = "/org/a11y/atspi/accessible/root";
static const char AX_NULL_REF[] = "/org/a11y/atspi/null";
static const char AX_PREFIX[] = "/org/a11y/atspi/accessible/";
static const char AX_EVENT_OBJECT[] = "org.a11y.atspi.Event.Object";

/** One node of the tree the runtime published. `id` is its place in the flat list and `parent`
 *  names another node's id; `uid` is the stable id of the DOM element behind it, which an object's
 *  path is made of, so a reference a client holds outlives a tree that changed shape. */
typedef struct {
  int id;
  int parent;
  int uid;
  char *role;
  char *label;
  char *value;
  char *dom_id;
  char *description;
  char *placeholder;
  char *url;
  char *role_description;
  double x, y, w, h;
  int focusable;
  int focused;
  int disabled;
  int checked;
  int level;
  int expanded, selected, pressed, mixed, required, readonly, multiline, actions;
  int has_now, has_min, has_max;
  double range_now, range_min, range_max;
  int sel_start, sel_end, sel_line;
} AxNode;

/** The tree the bus and the dump read: the nodes of the last JSON the runtime published. */
static AxNode *g_ax_nodes = NULL;
static int g_ax_node_count = 0;

/** The accessibility bus this app published itself on; NULL when there is none. */
static DBusConnection *g_ax_bus = NULL;
static int g_ax_bus_tried = 0;
/** The Id the registry handed back when this application registered. */
static int g_ax_app_id = 0;

/** The title the application last published, so a rename is reported once. */
static char g_ax_published_title[256] = "";

/** Whether a client has asked for the tree; the runtime builds none until one does. */
static volatile int g_ax_active = 0;
/** Set once the first tree has arrived, so a client that asked before it existed hears it. */
static int g_ax_has_tree = 0;

/** What a client asked for, waiting for the event loop to hand it to the page: the kind (an
 *  AX_* action), the uid of the node it names, the text a value write carries, and a text
 *  range's location and length in x and y. */
typedef struct {
  int kind, uid;
  char *text;
  double x, y;
} AxAction;

#define AX_ACTIONS 64
static AxAction g_ax_actions[AX_ACTIONS];
static int g_ax_action_read = 0, g_ax_action_write = 0;
/** The action EV_AXACTION carries now. */
static AxAction g_ax_action = {0, 0, NULL, 0, 0};

static void ax_queue(int kind, int uid, char *text, double x, double y) {
  int next = (g_ax_action_write + 1) % AX_ACTIONS;
  if (next == g_ax_action_read) {
    free(text);
    return;
  }
  AxAction *a = &g_ax_actions[g_ax_action_write];
  a->kind = kind;
  a->uid = uid;
  a->text = text;
  a->x = x;
  a->y = y;
  g_ax_action_write = next;
}

/** Takes the oldest queued action into g_ax_action; false when there is none. */
static int ax_take_action(void) {
  if (g_ax_action_read == g_ax_action_write) return 0;
  free(g_ax_action.text);
  g_ax_action = g_ax_actions[g_ax_action_read];
  g_ax_actions[g_ax_action_read].text = NULL;
  g_ax_action_read = (g_ax_action_read + 1) % AX_ACTIONS;
  g_ex = g_ax_action.x;
  g_ey = g_ax_action.y;
  return 1;
}

/** Interfaces a role's object carries beyond Accessible and Component. */
enum {
  AX_IF_ACTION = 1,
  AX_IF_TEXT = 2,
  AX_IF_VALUE = 4,
  AX_IF_SELECT = 8,
  AX_IF_TABLE = 16,
  AX_IF_CELL = 32,
  AX_IF_EDITABLE = 64,
  AX_IF_HYPERLINK = 128,
};

/** The actions a node takes, as the runtime's AxNode.actions carries them. */
enum {
  AXA_PRESS = 1, AXA_FOCUS = 2, AXA_SET_VALUE = 4, AXA_INSERT_TEXT = 8, AXA_INCREMENT = 16,
  AXA_SHOW_MENU = 32,
};
/** The action kinds EV_AXACTION carries, as runtime/host.ts has them. */
enum {
  AX_PRESS = 1, AX_FOCUS = 2, AX_SET_VALUE = 3, AX_INSERT_TEXT = 4, AX_SELECT_RANGE = 5,
  AX_INCREMENT = 6, AX_DECREMENT = 7, AX_SHOW_MENU = 8, AX_SCROLL_INTO_VIEW = 9,
};
/** Roles from atspi-constants.h the host names itself. */
enum {
  AX_ROLE_APPLICATION = 75,
  AX_ROLE_CHECK_BOX = 7,
  AX_ROLE_DOCUMENT_WEB = 95,
  AX_ROLE_ENTRY = 79,
  AX_ROLE_LANDMARK = 110,
  AX_ROLE_SECTION = 85,
};

/** Roles from atspi-constants.h, for the roles this host publishes. */
typedef struct {
  const char *dom;
  uint32_t role;
  uint32_t ifaces;
} AxRoleRow;

static const AxRoleRow AX_ROLES[] = {
  { "button", 43, AX_IF_ACTION },
  { "link", 88, AX_IF_ACTION },
  { "checkbox", 7, AX_IF_ACTION },
  { "radio", 44, AX_IF_ACTION },
  { "switch", 130, AX_IF_ACTION },
  { "menuitem", 35, AX_IF_ACTION },
  { "menuitemcheckbox", 8, AX_IF_ACTION },
  { "menuitemradio", 45, AX_IF_ACTION },
  { "tab", 37, AX_IF_ACTION },
  { "treeitem", 91, AX_IF_ACTION },
  { "option", 32, AX_IF_ACTION },
  { "combobox", 11, AX_IF_ACTION },
  { "textbox", 79, AX_IF_TEXT },
  { "searchbox", 79, AX_IF_TEXT },
  { "textarea", 61, AX_IF_TEXT },
  { "spinbutton", 52, AX_IF_TEXT | AX_IF_VALUE },
  { "listbox", 98, AX_IF_SELECT },
  { "list", 31, AX_IF_SELECT },
  { "listitem", 32, 0 },
  { "table", 55, AX_IF_TABLE | AX_IF_SELECT },
  { "grid", 55, AX_IF_TABLE | AX_IF_SELECT },
  { "treegrid", 66, AX_IF_TABLE | AX_IF_SELECT },
  { "row", 90, 0 },
  { "cell", 56, AX_IF_CELL },
  { "gridcell", 56, AX_IF_CELL },
  { "columnheader", 57, AX_IF_CELL },
  { "rowheader", 58, AX_IF_CELL },
  { "heading", 83, 0 },
  { "img", 27, 0 },
  { "image", 27, 0 },
  { "paragraph", 73, 0 },
  { "dialog", 16, 0 },
  { "alertdialog", 16, 0 },
  { "alert", 2, 0 },
  { "status", 54, 0 },
  { "log", 111, 0 },
  { "progressbar", 42, AX_IF_VALUE },
  { "meter", 103, AX_IF_VALUE },
  { "slider", 51, AX_IF_ACTION | AX_IF_VALUE },
  { "separator", 50, 0 },
  { "tablist", 38, AX_IF_SELECT },
  { "tree", 65, AX_IF_SELECT },
  { "toolbar", 63, 0 },
  { "menu", 33, 0 },
  { "menubar", 34, 0 },
  { "navigation", 110, 0 },
  { "main", 110, 0 },
  { "banner", 110, 0 },
  { "contentinfo", 110, 0 },
  { "complementary", 110, 0 },
  { "search", 110, 0 },
  { "region", 110, 0 },
  { "form", 110, 0 },
  { "article", 109, 0 },
  { "figure", 99, 0 },
  { "caption", 81, 0 },
  { "blockquote", 105, 0 },
  { "definition", 108, 0 },
  { "term", 122, 0 },
  { "group", 99, 0 },
  { "section", 85, 0 },
  // A plain box has no role of its own: it reads as a section, as a browser's generic does.
  { "generic", 85, 0 },
  { "staticText", 116, AX_IF_TEXT },
};

/** Whether a node is the page's document, the object the application holds the page under. */
static int ax_is_document(const AxNode *n);

static const AxRoleRow *ax_role_row(const char *role) {
  for (size_t i = 0; i < sizeof(AX_ROLES) / sizeof(AX_ROLES[0]); i++) {
    if (strcmp(AX_ROLES[i].dom, role) == 0) return &AX_ROLES[i];
  }
  return NULL;
}

/** The role an object plays, as the bus numbers roles (a section when nothing else fits). */
static uint32_t ax_role_of(const AxNode *n) {
  if (ax_is_document(n)) return AX_ROLE_DOCUMENT_WEB;
  const AxRoleRow *row = ax_role_row(n->role);
  return row != NULL ? row->role : AX_ROLE_SECTION;
}

static int ax_is(const char *a, const char *b) { return strcmp(a, b) == 0; }

/** Whether the node is a text field, which takes a value and text as an entry does. */
static int ax_is_field(const AxNode *n) {
  return (n->actions & AXA_INSERT_TEXT) != 0 || ax_is(n->role, "textbox") ||
    ax_is(n->role, "searchbox");
}

/** Whether the node toggles: a checkbox or switch, or a button with aria-pressed. */
static int ax_toggles(const AxNode *n) {
  return ax_is(n->role, "checkbox") || ax_is(n->role, "switch") ||
    ax_is(n->role, "menuitemcheckbox") || (ax_is(n->role, "button") && n->pressed >= 0);
}

/** Whether the node is an item a container selects: a radio, tab, option, tree item or row. */
static int ax_selectable(const AxNode *n) {
  return ax_is(n->role, "radio") || ax_is(n->role, "tab") || ax_is(n->role, "option") ||
    ax_is(n->role, "menuitemradio") ||
    ((ax_is(n->role, "treeitem") || ax_is(n->role, "row") || ax_is(n->role, "gridcell")) &&
     n->selected >= 0);
}

static int ax_has_range(const AxNode *n) { return n->has_now != 0; }

/** Whether the node opens and closes: aria-expanded, or a select with a picker of its own. */
static int ax_expands(const AxNode *n) {
  return n->expanded >= 0 || (ax_is(n->role, "combobox") && (n->actions & AXA_INSERT_TEXT) == 0);
}

/** Whether the node is on: aria-pressed first, as a toggle button reports, then its checkedness. */
static int ax_toggle_on(const AxNode *n) {
  if (n->pressed >= 0) return n->pressed == 1;
  return n->checked == 1;
}

/** Whether the node is selected: aria-selected, a chosen option, or a checked radio. */
static int ax_is_selected(const AxNode *n) {
  return n->selected == 1 ||
    ((ax_is(n->role, "radio") || ax_is(n->role, "menuitemradio")) && n->checked == 1);
}

/** Whether the node is a range control, whose Value interface carries a number. */
static int ax_valued(const AxNode *n) {
  return ax_has_range(n) || ax_is(n->role, "spinbutton") || ax_is(n->role, "progressbar") ||
    ax_is(n->role, "meter") || ax_is(n->role, "slider") || ax_is(n->role, "scrollbar");
}

/** The interfaces an object carries beyond Accessible and Component: Action and the rest follow
 *  the actions the runtime says the node takes, as Core-AAM maps them to ATK. */
static uint32_t ax_ifaces(const AxNode *n) {
  if (ax_is_document(n)) return 0;
  const AxRoleRow *row = ax_role_row(n->role);
  uint32_t ifaces = row != NULL ? row->ifaces & ~AX_IF_ACTION : 0;
  if (n->actions & (AXA_PRESS | AXA_SHOW_MENU | AXA_INCREMENT)) ifaces |= AX_IF_ACTION;
  if (ax_valued(n)) ifaces |= AX_IF_VALUE;
  if (ax_is_field(n)) ifaces |= AX_IF_TEXT | AX_IF_EDITABLE;
  if (ax_is(n->role, "link")) ifaces |= AX_IF_HYPERLINK;
  return ifaces;
}

/** The role's name, as an assistive client prints it. */
static const char *ax_role_name(uint32_t role) {
  switch (role) {
    case 2: return "alert";
    case 7: return "check box";
    case 8: return "check menu item";
    case 11: return "combo box";
    case 16: return "dialog";
    case 27: return "image";
    case 31: return "list";
    case 32: return "list item";
    case 33: return "menu";
    case 34: return "menu bar";
    case 35: return "menu item";
    case 37: return "page tab";
    case 38: return "page tab list";
    case 42: return "progress bar";
    case 43: return "button";
    case 44: return "radio button";
    case 45: return "radio menu item";
    case 50: return "separator";
    case 51: return "slider";
    case 52: return "spin button";
    case 54: return "status bar";
    case 55: return "table";
    case 56: return "table cell";
    case 57: return "table column header";
    case 58: return "table row header";
    case 61: return "text";
    case 63: return "tool bar";
    case 65: return "tree";
    case 66: return "tree table";
    case 73: return "paragraph";
    case 75: return "application";
    case 79: return "entry";
    case 81: return "caption";
    case 83: return "heading";
    case 85: return "section";
    case 87: return "form";
    case 88: return "link";
    case 90: return "table row";
    case 91: return "tree item";
    case 95: return "document web";
    case 98: return "list box";
    case 99: return "grouping";
    case 103: return "level bar";
    case 105: return "block quote";
    case 108: return "definition";
    case 109: return "article";
    case 110: return "landmark";
    case 111: return "log";
    case 116: return "static";
    case 122: return "definition term";
    case 130: return "switch";
    default: return "panel";
  }
}

/** The page's document: the application object's one child, the node the page's own nodes hang
 *  under, as a browser publishes a page under a Document. */
static AxNode g_ax_document;
static const char AX_DOCUMENT[] = "/org/a11y/atspi/accessible/document";
/** A text run's path prefix, apart from the elements' so the two can't collide: a text run's uid
 *  is its owner's, negated. */
static const char AX_TEXT_PREFIX[] = "/org/a11y/atspi/accessible/text";

static int ax_is_document(const AxNode *n) { return n == &g_ax_document; }

/** The parent id a node's children name: the document's are the page's top-level nodes (parent 0
 *  in the runtime's list), and every other node's are the nodes whose parent is its id. */
static int ax_children_of(const AxNode *n) { return ax_is_document(n) ? 0 : n->id; }

static int ax_child_count(const AxNode *n) {
  if (n == NULL) return g_ax_has_tree ? 1 : 0;  // the document, once the page is built
  int parent = ax_children_of(n);
  int count = 0;
  for (int i = 0; i < g_ax_node_count; i++) {
    if (g_ax_nodes[i].parent == parent) count++;
  }
  return count;
}

/** The `index`th child of a node, or NULL. */
static AxNode *ax_child(const AxNode *n, int index) {
  if (n == NULL) return index == 0 && g_ax_has_tree ? &g_ax_document : NULL;
  int parent = ax_children_of(n);
  for (int i = 0; i < g_ax_node_count; i++) {
    if (g_ax_nodes[i].parent != parent) continue;
    if (index-- == 0) return &g_ax_nodes[i];
  }
  return NULL;
}

/** Where a node sits among its parent's children, or -1. */
static int ax_index_in_parent(const AxNode *n) {
  if (ax_is_document(n)) return 0;
  int index = 0;
  for (int i = 0; i < g_ax_node_count; i++) {
    if (g_ax_nodes[i].parent != n->parent) continue;
    if (&g_ax_nodes[i] == n) return index;
    index++;
  }
  return -1;
}

static AxNode *ax_node_by_id(int id) {
  for (int i = 0; i < g_ax_node_count; i++) {
    if (g_ax_nodes[i].id == id) return &g_ax_nodes[i];
  }
  return NULL;
}

static AxNode *ax_node_by_uid(int uid) {
  for (int i = 0; i < g_ax_node_count; i++) {
    if (g_ax_nodes[i].uid == uid) return &g_ax_nodes[i];
  }
  return NULL;
}

/** A node's parent object: its ancestor element, or the page's document. */
static AxNode *ax_parent_of(const AxNode *n) {
  if (n == NULL || ax_is_document(n)) return NULL;
  AxNode *parent = n->parent > 0 ? ax_node_by_id(n->parent) : NULL;
  return parent != NULL ? parent : &g_ax_document;
}

/** The node a message's object path names, setting `is_root` for the application object. A path
 *  is made of the element's uid, so it names the same element after the tree changed shape. */
static AxNode *ax_node_at(const char *path, int *is_root) {
  *is_root = 0;
  if (path == NULL) return NULL;
  if (strcmp(path, AX_ROOT) == 0) {
    *is_root = 1;
    return NULL;
  }
  if (strcmp(path, AX_DOCUMENT) == 0) return &g_ax_document;
  size_t tlen = strlen(AX_TEXT_PREFIX);
  if (strncmp(path, AX_TEXT_PREFIX, tlen) == 0) {
    const char *num = path + tlen;
    if (*num < '0' || *num > '9') return NULL;
    for (const char *p = num; *p != '\0'; p++) {
      if (*p < '0' || *p > '9') return NULL;
    }
    return ax_node_by_uid(-atoi(num));
  }
  size_t plen = strlen(AX_PREFIX);
  if (strncmp(path, AX_PREFIX, plen) != 0) return NULL;
  const char *num = path + plen;
  if (*num < '0' || *num > '9') return NULL;
  for (const char *p = num; *p != '\0'; p++) {
    if (*p < '0' || *p > '9') return NULL;
  }
  return ax_node_by_uid(atoi(num));
}

/** The text an object carries: a field's value, or the words a static text holds. */
static const char *ax_text(const AxNode *n) {
  if (n == NULL || ax_is_document(n)) return "";
  if (n->value != NULL && n->value[0] != '\0') return n->value;
  return n->label != NULL ? n->label : "";
}

/** An object's frame in the coordinates a client asked for: 0 screen, 1 window, 2 parent. */
static void ax_extents(const AxNode *n, uint32_t coord, double out[4]) {
  if (n == NULL || ax_is_document(n)) {
    out[0] = 0;
    out[1] = 0;
    out[2] = g_view_w;
    out[3] = g_view_h;
    return;
  }
  out[0] = n->x;
  out[1] = n->y;
  out[2] = n->w;
  out[3] = n->h;
  if (coord == 2 && n->parent != 0) {
    AxNode *parent = ax_node_by_id(n->parent);
    if (parent != NULL) {
      out[0] -= parent->x;
      out[1] -= parent->y;
    }
  }
}

// --- The tree on the bus ----------------------------------------------------

/** The path an object is published at. */
static void ax_path(const AxNode *n, char *buf, size_t size) {
  if (n == NULL) snprintf(buf, size, "%s", AX_ROOT);
  else if (ax_is_document(n)) snprintf(buf, size, "%s", AX_DOCUMENT);
  else if (n->uid < 0) snprintf(buf, size, "%s%d", AX_TEXT_PREFIX, -n->uid);
  else snprintf(buf, size, "%s%d", AX_PREFIX, n->uid);
}

/** Appends a reference to a node (the application object for NULL). */
static void ax_append_ref(DBusMessageIter *iter, const AxNode *n) {
  DBusMessageIter st;
  char path[64];
  const char *name = g_ax_bus != NULL ? dbus_bus_get_unique_name(g_ax_bus) : NULL;
  const char *owner = name == NULL ? "" : name;
  ax_path(n, path, sizeof path);
  dbus_message_iter_open_container(iter, DBUS_TYPE_STRUCT, NULL, &st);
  dbus_message_iter_append_basic(&st, DBUS_TYPE_STRING, &owner);
  const char *p = path;
  dbus_message_iter_append_basic(&st, DBUS_TYPE_OBJECT_PATH, &p);
  dbus_message_iter_close_container(iter, &st);
}

/** Appends the empty reference clients read as "no object". */
static void ax_append_null_ref(DBusMessageIter *iter) {
  DBusMessageIter st;
  const char *name = "";
  const char *path = AX_NULL_REF;
  dbus_message_iter_open_container(iter, DBUS_TYPE_STRUCT, NULL, &st);
  dbus_message_iter_append_basic(&st, DBUS_TYPE_STRING, &name);
  dbus_message_iter_append_basic(&st, DBUS_TYPE_OBJECT_PATH, &path);
  dbus_message_iter_close_container(iter, &st);
}

enum { AX_EV_INT = 0, AX_EV_STRING, AX_EV_DOUBLE, AX_EV_REF };

/** Emits one AT-SPI event: its detail string, two numbers, then the value as a variant. */
static void ax_event(const char *path, const char *member, const char *minor, int d1, int d2,
                     int kind, const char *text, double number, const AxNode *ref) {
  if (g_ax_bus == NULL) return;
  DBusMessage *sig = dbus_message_new_signal(path, AX_EVENT_OBJECT, member);
  if (sig == NULL) return;
  DBusMessageIter iter, variant, dict;
  dbus_message_iter_init_append(sig, &iter);
  const char *minor_arg = minor;
  dbus_int32_t first = d1, second = d2;
  dbus_int32_t zero = 0;
  dbus_message_iter_append_basic(&iter, DBUS_TYPE_STRING, &minor_arg);
  dbus_message_iter_append_basic(&iter, DBUS_TYPE_INT32, &first);
  dbus_message_iter_append_basic(&iter, DBUS_TYPE_INT32, &second);
  if (kind == AX_EV_STRING) {
    const char *value = text == NULL ? "" : text;
    dbus_message_iter_open_container(&iter, DBUS_TYPE_VARIANT, "s", &variant);
    dbus_message_iter_append_basic(&variant, DBUS_TYPE_STRING, &value);
    dbus_message_iter_close_container(&iter, &variant);
  } else if (kind == AX_EV_DOUBLE) {
    dbus_message_iter_open_container(&iter, DBUS_TYPE_VARIANT, "d", &variant);
    dbus_message_iter_append_basic(&variant, DBUS_TYPE_DOUBLE, &number);
    dbus_message_iter_close_container(&iter, &variant);
  } else if (kind == AX_EV_REF) {
    dbus_message_iter_open_container(&iter, DBUS_TYPE_VARIANT, "(so)", &variant);
    if (ref != NULL) ax_append_ref(&variant, ref);
    else ax_append_null_ref(&variant);
    dbus_message_iter_close_container(&iter, &variant);
  } else {
    dbus_message_iter_open_container(&iter, DBUS_TYPE_VARIANT, "i", &variant);
    dbus_message_iter_append_basic(&variant, DBUS_TYPE_INT32, &zero);
    dbus_message_iter_close_container(&iter, &variant);
  }
  dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "{sv}", &dict);
  dbus_message_iter_close_container(&iter, &dict);
  dbus_connection_send(g_ax_bus, sig, NULL);
  dbus_message_unref(sig);
}

/** Emits an event from a node, or from the application object when `n` is NULL. */
static void ax_node_event(const AxNode *n, const char *member, const char *minor, int d1, int d2,
                          int kind, const char *text, double number, const AxNode *ref) {
  char path[64];
  ax_path(n, path, sizeof path);
  ax_event(path, member, minor, d1, d2, kind, text, number, ref);
}

/** Emits the state-changed event for one of a node's states. */
static void ax_state_changed(const AxNode *n, const char *state, int on) {
  ax_node_event(n, "StateChanged", state, on ? 1 : 0, 0, AX_EV_INT, NULL, 0, NULL);
}

/** The address of the accessibility bus, asked of the session bus; NULL when there is no bus. */
static char *ax_bus_address(void) {
  DBusError err;
  dbus_error_init(&err);
  DBusConnection *session = dbus_bus_get_private(DBUS_BUS_SESSION, &err);
  if (session == NULL) {
    dbus_error_free(&err);
    return NULL;
  }
  char *address = NULL;
  DBusMessage *call = dbus_message_new_method_call("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus",
                                                   "GetAddress");
  if (call != NULL) {
    DBusMessage *reply = dbus_connection_send_with_reply_and_block(session, call, 2000, &err);
    if (reply != NULL) {
      const char *value = NULL;
      if (dbus_message_get_args(reply, &err, DBUS_TYPE_STRING, &value, DBUS_TYPE_INVALID) &&
          value != NULL && value[0] != '\0') {
        address = dup_str(value);
      }
      dbus_message_unref(reply);
    }
    dbus_message_unref(call);
  }
  dbus_error_free(&err);
  dbus_connection_close(session);
  dbus_connection_unref(session);
  return address;
}

static DBusHandlerResult ax_message(DBusConnection *conn, DBusMessage *msg, void *data);

/** Connects to the accessibility bus once, registering this application with its registry. */
static void ax_connect(void) {
  if (g_ax_bus != NULL || g_ax_bus_tried) return;
  g_ax_bus_tried = 1;
  char *address = ax_bus_address();
  if (address == NULL) return;
  DBusError err;
  dbus_error_init(&err);
  DBusConnection *bus = dbus_connection_open_private(address, &err);
  free(address);
  if (bus == NULL) {
    dbus_error_free(&err);
    return;
  }
  if (!dbus_bus_register(bus, &err)) {
    dbus_error_free(&err);
    dbus_connection_close(bus);
    dbus_connection_unref(bus);
    return;
  }
  dbus_error_free(&err);
  dbus_connection_set_exit_on_disconnect(bus, FALSE);
  static const DBusObjectPathVTable vtable = { NULL, ax_message, NULL, NULL, NULL, NULL };
  // One fallback vtable serves the application object and every node below it; the path names
  // which object a call is about.
  if (!dbus_connection_register_fallback(bus, "/org/a11y/atspi", &vtable, NULL)) {
    dbus_connection_close(bus);
    dbus_connection_unref(bus);
    return;
  }
  g_ax_bus = bus;
  // The registry keeps the desktop's list of applications: it learns of this one by an Embed
  // call, and answers with the Id it assigned.
  const char *name = dbus_bus_get_unique_name(bus);
  DBusMessage *embed = dbus_message_new_method_call("org.a11y.atspi.Registry", AX_ROOT,
                                                    "org.a11y.atspi.Socket", "Embed");
  if (embed != NULL) {
    DBusMessageIter iter, st;
    const char *app = name == NULL ? "" : name;
    const char *root = AX_ROOT;
    dbus_message_iter_init_append(embed, &iter);
    dbus_message_iter_open_container(&iter, DBUS_TYPE_STRUCT, NULL, &st);
    dbus_message_iter_append_basic(&st, DBUS_TYPE_STRING, &app);
    dbus_message_iter_append_basic(&st, DBUS_TYPE_OBJECT_PATH, &root);
    dbus_message_iter_close_container(&iter, &st);
    dbus_connection_send(bus, embed, NULL);
    dbus_message_unref(embed);
    dbus_connection_flush(bus);
  }
}

/** Drops the bus after it went away, so the next tree published starts a new connection. */
static void ax_keep_bus(void) {
  if (g_ax_bus != NULL && !dbus_connection_get_is_connected(g_ax_bus)) {
    dbus_connection_unref(g_ax_bus);
    g_ax_bus = NULL;
    g_ax_bus_tried = 0;
  }
}

// --- The runtime's JSON -----------------------------------------------------

static void ax_free_tree(AxNode *nodes, int count) {
  for (int i = 0; i < count; i++) {
    free(nodes[i].role);
    free(nodes[i].label);
    free(nodes[i].value);
    free(nodes[i].dom_id);
    free(nodes[i].description);
    free(nodes[i].placeholder);
    free(nodes[i].url);
    free(nodes[i].role_description);
  }
  free(nodes);
}

/** Reads a JSON number, leaving `out` alone and skipping the value for anything else. */
static const char *ax_json_number(const char *p, double *out) {
  p = json_skip_space(p);
  if (!(*p == '-' || (*p >= '0' && *p <= '9'))) return json_skip_value(p);
  char *end = NULL;
  double value = strtod(p, &end);
  if (end == p) return json_skip_value(p);
  *out = value;
  return end;
}

/** Reads a JSON true or false, leaving `out` alone for anything else. */
static const char *ax_json_flag(const char *p, int *out) {
  p = json_skip_space(p);
  if (strncmp(p, "true", 4) == 0) {
    *out = 1;
    return p + 4;
  }
  if (strncmp(p, "false", 5) == 0) {
    *out = 0;
    return p + 5;
  }
  return json_skip_value(p);
}

/** Parses the array of nodes the runtime sends; 0 when the text isn't an array. */
static int ax_parse(const char *text, AxNode **out, int *out_count) {
  AxNode *nodes = NULL;
  int count = 0, cap = 0;
  const char *p = json_skip_space(text);
  if (*p != '[') return 0;
  p++;
  for (;;) {
    p = json_skip_space(p);
    if (*p != '{') break;
    if (count == cap) {
      int grown_cap = cap == 0 ? 32 : cap * 2;
      AxNode *grown = (AxNode *)realloc(nodes, (size_t)grown_cap * sizeof(AxNode));
      if (grown == NULL) break;
      nodes = grown;
      cap = grown_cap;
    }
    AxNode *n = &nodes[count];
    memset(n, 0, sizeof(*n));
    n->label = dup_str("");
    n->value = dup_str("");
    n->role = dup_str("");
    n->sel_start = -1;
    n->sel_end = -1;
    n->sel_line = -1;
    n->expanded = -1;
    n->selected = -1;
    n->pressed = -1;
    if (n->label == NULL || n->value == NULL || n->role == NULL) break;
    p++;
    for (;;) {
      p = json_skip_space(p);
      if (*p != '"') break;
      char *key = NULL;
      size_t key_len = 0;
      p = json_read_string(p, &key, &key_len);
      p = json_skip_space(p);
      if (*p == ':') p++;
      p = json_skip_space(p);
      if (key != NULL && (strcmp(key, "role") == 0 || strcmp(key, "label") == 0 ||
                          strcmp(key, "value") == 0 || strcmp(key, "domId") == 0 ||
                          strcmp(key, "description") == 0 || strcmp(key, "placeholder") == 0 ||
                          strcmp(key, "url") == 0 || strcmp(key, "roleDescription") == 0)) {
        if (*p == '"') {
          char *text = NULL;
          size_t len = 0;
          p = json_read_string(p, &text, &len);
          if (text != NULL) {
            char **slot = strcmp(key, "role") == 0 ? &n->role
                        : strcmp(key, "label") == 0 ? &n->label
                        : strcmp(key, "value") == 0 ? &n->value
                        : strcmp(key, "domId") == 0 ? &n->dom_id
                        : strcmp(key, "description") == 0 ? &n->description
                        : strcmp(key, "placeholder") == 0 ? &n->placeholder
                        : strcmp(key, "url") == 0 ? &n->url : &n->role_description;
            free(*slot);
            *slot = text;
          }
        } else {
          p = json_skip_value(p);
        }
      } else if (key != NULL && (strcmp(key, "id") == 0 || strcmp(key, "parent") == 0 ||
                                 strcmp(key, "uid") == 0 || strcmp(key, "checked") == 0 ||
                                 strcmp(key, "level") == 0 || strcmp(key, "expanded") == 0 ||
                                 strcmp(key, "selected") == 0 || strcmp(key, "pressed") == 0 ||
                                 strcmp(key, "actions") == 0 || strcmp(key, "selStart") == 0 ||
                                 strcmp(key, "selEnd") == 0 || strcmp(key, "selLine") == 0)) {
        double value = 0;
        p = ax_json_number(p, &value);
        if (strcmp(key, "id") == 0) n->id = (int)value;
        else if (strcmp(key, "parent") == 0) n->parent = (int)value;
        else if (strcmp(key, "uid") == 0) n->uid = (int)value;
        else if (strcmp(key, "checked") == 0) n->checked = (int)value;
        else if (strcmp(key, "level") == 0) n->level = (int)value;
        else if (strcmp(key, "expanded") == 0) n->expanded = (int)value;
        else if (strcmp(key, "selected") == 0) n->selected = (int)value;
        else if (strcmp(key, "pressed") == 0) n->pressed = (int)value;
        else if (strcmp(key, "actions") == 0) n->actions = (int)value;
        else if (strcmp(key, "selStart") == 0) n->sel_start = (int)value;
        else if (strcmp(key, "selEnd") == 0) n->sel_end = (int)value;
        else n->sel_line = (int)value;
      } else if (key != NULL && (strcmp(key, "x") == 0 || strcmp(key, "y") == 0 ||
                                 strcmp(key, "w") == 0 || strcmp(key, "h") == 0)) {
        double value = 0;
        p = ax_json_number(p, &value);
        if (strcmp(key, "x") == 0) n->x = value;
        else if (strcmp(key, "y") == 0) n->y = value;
        else if (strcmp(key, "w") == 0) n->w = value;
        else n->h = value;
      } else if (key != NULL && (strcmp(key, "valueNow") == 0 || strcmp(key, "valueMin") == 0 ||
                                 strcmp(key, "valueMax") == 0)) {
        double value = 0;
        int has_one = *p == '-' || (*p >= '0' && *p <= '9');
        p = ax_json_number(p, &value);
        if (strcmp(key, "valueNow") == 0) { n->range_now = value; n->has_now = has_one; }
        else if (strcmp(key, "valueMin") == 0) { n->range_min = value; n->has_min = has_one; }
        else { n->range_max = value; n->has_max = has_one; }
      } else if (key != NULL && (strcmp(key, "focusable") == 0 || strcmp(key, "focused") == 0 ||
                                 strcmp(key, "disabled") == 0 || strcmp(key, "mixed") == 0 ||
                                 strcmp(key, "required") == 0 || strcmp(key, "readonly") == 0 ||
                                 strcmp(key, "multiline") == 0)) {
        int value = 0;
        p = ax_json_flag(p, &value);
        if (strcmp(key, "focusable") == 0) n->focusable = value;
        else if (strcmp(key, "focused") == 0) n->focused = value;
        else if (strcmp(key, "disabled") == 0) n->disabled = value;
        else if (strcmp(key, "mixed") == 0) n->mixed = value;
        else if (strcmp(key, "required") == 0) n->required = value;
        else if (strcmp(key, "readonly") == 0) n->readonly = value;
        else n->multiline = value;
      } else {
        p = json_skip_value(p);
      }
      free(key);
      p = json_skip_space(p);
      if (*p == ',') p++;
      else break;
    }
    if (*p == '}') p++;
    count++;
    p = json_skip_space(p);
    if (*p == ',') p++;
  }
  *out = nodes;
  *out_count = count;
  return 1;
}

/** The states a node is in, as the bus's bitset. */
enum {
  AX_ST_ACTIVE = 1, AX_ST_CHECKED = 4, AX_ST_COLLAPSED = 5, AX_ST_EDITABLE = 7,
  AX_ST_ENABLED = 8, AX_ST_EXPANDABLE = 9, AX_ST_EXPANDED = 10, AX_ST_FOCUSABLE = 11,
  AX_ST_FOCUSED = 12, AX_ST_MULTI_LINE = 17, AX_ST_PRESSED = 20, AX_ST_SELECTABLE = 22,
  AX_ST_SELECTED = 23, AX_ST_SENSITIVE = 24, AX_ST_SHOWING = 25, AX_ST_SINGLE_LINE = 26,
  AX_ST_VISIBLE = 30, AX_ST_INDETERMINATE = 32, AX_ST_REQUIRED = 33, AX_ST_CHECKABLE = 41,
  AX_ST_READ_ONLY = 43,
};

/** The states an object is in: AT-SPI's 64-bit set, sent as its two 32-bit words. */
static uint64_t ax_states(const AxNode *n) {
  uint64_t s = (1ull << AX_ST_ENABLED) | (1ull << AX_ST_SENSITIVE) | (1ull << AX_ST_SHOWING) |
               (1ull << AX_ST_VISIBLE);
  if (ax_is_document(n)) return s;
  if (n->disabled) s &= ~((1ull << AX_ST_ENABLED) | (1ull << AX_ST_SENSITIVE));
  if (n->focusable) s |= 1ull << AX_ST_FOCUSABLE;
  if (n->focused) s |= (1ull << AX_ST_FOCUSED) | (1ull << AX_ST_ACTIVE);
  if (ax_toggles(n)) {
    s |= 1ull << AX_ST_CHECKABLE;
    if (n->mixed || n->pressed == 2) s |= 1ull << AX_ST_INDETERMINATE;
    else if (ax_toggle_on(n)) s |= 1ull << AX_ST_CHECKED;
  } else if (n->pressed >= 0) {
    if (n->pressed == 1) s |= 1ull << AX_ST_PRESSED;
    else if (n->pressed == 2) s |= 1ull << AX_ST_INDETERMINATE;
  }
  if (ax_expands(n)) {
    s |= 1ull << AX_ST_EXPANDABLE;
    s |= 1ull << (n->expanded == 1 ? AX_ST_EXPANDED : AX_ST_COLLAPSED);
  }
  if (ax_selectable(n)) s |= 1ull << AX_ST_SELECTABLE;
  if (ax_is_selected(n)) s |= 1ull << AX_ST_SELECTED;
  if (n->required) s |= 1ull << AX_ST_REQUIRED;
  if (ax_is_field(n)) {
    if (n->readonly || (n->actions & AXA_SET_VALUE) == 0) s |= 1ull << AX_ST_READ_ONLY;
    else s |= 1ull << AX_ST_EDITABLE;
    s |= 1ull << (n->multiline ? AX_ST_MULTI_LINE : AX_ST_SINGLE_LINE);
  } else if (n->readonly) {
    s |= 1ull << AX_ST_READ_ONLY;
  }
  return s;
}

/** The deepest node whose frame holds a point in view coordinates. */
static const AxNode *ax_deepest_at(double x, double y) {
  const AxNode *found = NULL;
  for (int i = 0; i < g_ax_node_count; i++) {
    const AxNode *n = &g_ax_nodes[i];
    if (x >= n->x && y >= n->y && x < n->x + n->w && y < n->y + n->h) found = n;
  }
  return found;
}

/** The UTF-8 byte offset of UTF-16 index `unit`, as AT-SPI counts text offsets. */
static size_t ax_byte_offset(const char *s, int unit) {
  size_t bytes = 0;
  int units = 0;
  while (s[bytes] != '\0' && units < unit) {
    unsigned char c = (unsigned char)s[bytes];
    size_t len = c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : (c >> 3) == 30 ? 4 : 1;
    bytes += len;
    units += len == 4 ? 2 : 1;
  }
  return bytes;
}

/** The UTF-16 index of UTF-8 byte offset `byte`. */
static int ax_unit_offset(const char *s, size_t byte) {
  size_t at = 0;
  int units = 0;
  while (s[at] != '\0' && at < byte) {
    unsigned char c = (unsigned char)s[at];
    size_t len = c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : (c >> 3) == 30 ? 4 : 1;
    if (at + len > byte) break;
    at += len;
    units += len == 4 ? 2 : 1;
  }
  return units;
}

/** A field's caret as a byte offset. */
static int ax_caret(const AxNode *n) {
  if (n->sel_start < 0) return 0;
  return (int)ax_byte_offset(ax_text(n), n->sel_start);
}

/** A copy of the part of `s` between two byte offsets. */
static char *ax_substr(const char *s, int start, int end) {
  size_t len = strlen(s);
  if (start < 0) start = 0;
  if (end < 0 || (size_t)end > len) end = (int)len;
  if (start > end) start = end;
  size_t n = (size_t)(end - start);
  char *out = (char *)malloc(n + 1);
  if (out == NULL) return NULL;
  memcpy(out, s + start, n);
  out[n] = '\0';
  return out;
}

/** The part of the text one granularity names around `offset` (see AtspiTextBoundaryType). */
static void ax_granularity(const char *text, int offset, uint32_t type, int *start, int *end) {
  int len = (int)strlen(text);
  if (offset < 0) offset = 0;
  if (offset > len) offset = len;
  int s = offset, e = offset;
  if (type == 0) {  // a character
    e = offset < len ? offset + 1 : len;
  } else if (type == 1 || type == 2) {  // a word
    while (s > 0 && text[s - 1] != ' ' && text[s - 1] != '\n' && text[s - 1] != '\t') s--;
    while (e < len && text[e] != ' ' && text[e] != '\n' && text[e] != '\t') e++;
  } else if (type == 5 || type == 6) {  // a line
    while (s > 0 && text[s - 1] != '\n') s--;
    while (e < len && text[e] != '\n') e++;
  } else {  // a sentence, an attribute run, or anything else: the whole text
    s = 0;
    e = len;
  }
  *start = s;
  *end = e;
}

// --- Replies -----------------------------------------------------------------

static void ax_send(DBusConnection *conn, DBusMessage *reply) {
  if (reply == NULL) return;
  dbus_connection_send(conn, reply, NULL);
  dbus_message_unref(reply);
}

static void ax_send_error(DBusConnection *conn, DBusMessage *msg, const char *text) {
  ax_send(conn, dbus_message_new_error(msg, "org.freedesktop.DBus.Error.UnknownMethod", text));
}

static void ax_send_bool(DBusConnection *conn, DBusMessage *msg, int value) {
  DBusMessage *reply = dbus_message_new_method_return(msg);
  dbus_bool_t yes = value ? TRUE : FALSE;
  if (reply != NULL) dbus_message_append_args(reply, DBUS_TYPE_BOOLEAN, &yes, DBUS_TYPE_INVALID);
  ax_send(conn, reply);
}

static void ax_send_int(DBusConnection *conn, DBusMessage *msg, int32_t value) {
  DBusMessage *reply = dbus_message_new_method_return(msg);
  if (reply != NULL) dbus_message_append_args(reply, DBUS_TYPE_INT32, &value, DBUS_TYPE_INVALID);
  ax_send(conn, reply);
}

static void ax_send_string(DBusConnection *conn, DBusMessage *msg, const char *value) {
  DBusMessage *reply = dbus_message_new_method_return(msg);
  const char *text = value == NULL ? "" : value;
  if (reply != NULL) dbus_message_append_args(reply, DBUS_TYPE_STRING, &text, DBUS_TYPE_INVALID);
  ax_send(conn, reply);
}

/** Replies with a node reference (the application object when `n` is NULL). */
static void ax_send_ref(DBusConnection *conn, DBusMessage *msg, const AxNode *n) {
  DBusMessage *reply = dbus_message_new_method_return(msg);
  if (reply == NULL) return;
  DBusMessageIter iter;
  dbus_message_iter_init_append(reply, &iter);
  ax_append_ref(&iter, n);
  ax_send(conn, reply);
}

/** Replies with a piece of text and the byte offsets it covers; it takes ownership of the slice. */
static void ax_send_range(DBusConnection *conn, DBusMessage *msg, const char *text, int start, int end) {
  DBusMessage *reply = dbus_message_new_method_return(msg);
  const char *value = text == NULL ? "" : text;
  int32_t first = start, second = end;
  if (reply != NULL) {
    dbus_message_append_args(reply, DBUS_TYPE_STRING, &value, DBUS_TYPE_INT32, &first,
                             DBUS_TYPE_INT32, &second, DBUS_TYPE_INVALID);
  }
  free((void *)text);
  ax_send(conn, reply);
}

// --- Properties --------------------------------------------------------------

/** The interfaces an object carries, as names for GetInterfaces and the introspection XML. */
static int ax_interface_names(uint32_t role, uint32_t ifaces, const char *out[12]) {
  int count = 0;
  out[count++] = "org.a11y.atspi.Accessible";
  out[count++] = "org.a11y.atspi.Component";
  if (ifaces & AX_IF_ACTION) out[count++] = "org.a11y.atspi.Action";
  if (ifaces & AX_IF_TEXT) out[count++] = "org.a11y.atspi.Text";
  if (ifaces & AX_IF_EDITABLE) out[count++] = "org.a11y.atspi.EditableText";
  if (ifaces & AX_IF_HYPERLINK) out[count++] = "org.a11y.atspi.Hyperlink";
  if (ifaces & AX_IF_VALUE) out[count++] = "org.a11y.atspi.Value";
  if (ifaces & AX_IF_SELECT) out[count++] = "org.a11y.atspi.Selection";
  if (ifaces & AX_IF_TABLE) out[count++] = "org.a11y.atspi.Table";
  if (ifaces & AX_IF_CELL) out[count++] = "org.a11y.atspi.TableCell";
  if (role == 75) {
    out[count++] = "org.a11y.atspi.Application";
    out[count++] = "org.a11y.atspi.Socket";
  }
  return count;
}

/** The properties of each interface, for GetAll. */
static const char *ax_property_at(const char *iface, int index, int *count) {
  static const char *accessible[] = { "version", "Name", "Description", "Parent", "ChildCount",
                                      "Locale", "AccessibleId", "HelpText" };
  static const char *component[] = { "version" };
  static const char *action[] = { "version", "NActions" };
  static const char *text[] = { "version", "CharacterCount", "CaretOffset" };
  static const char *editable[] = { "version" };
  static const char *hyperlink[] = { "version", "StartIndex", "EndIndex", "NAnchors" };
  static const char *value[] = { "version", "MinimumValue", "MaximumValue", "MinimumIncrement",
                                 "CurrentValue", "Text" };
  static const char *selection[] = { "version", "NSelectedChildren" };
  static const char *table[] = { "version", "NRows", "NColumns", "Caption", "Summary",
                                 "NSelectedRows", "NSelectedColumns" };
  static const char *cell[] = { "version", "ColumnSpan", "Position", "RowSpan", "Table" };
  static const char *application[] = { "ToolkitName", "Version", "ToolkitVersion", "AtspiVersion",
                                       "InterfaceVersion", "Id" };
  static const char *socket[] = { "version" };
  const char *const *names = NULL;
  int n = 0;
  if (strcmp(iface, "org.a11y.atspi.Accessible") == 0) { names = accessible; n = 8; }
  else if (strcmp(iface, "org.a11y.atspi.Component") == 0) { names = component; n = 1; }
  else if (strcmp(iface, "org.a11y.atspi.Action") == 0) { names = action; n = 2; }
  else if (strcmp(iface, "org.a11y.atspi.Text") == 0) { names = text; n = 3; }
  else if (strcmp(iface, "org.a11y.atspi.EditableText") == 0) { names = editable; n = 1; }
  else if (strcmp(iface, "org.a11y.atspi.Hyperlink") == 0) { names = hyperlink; n = 4; }
  else if (strcmp(iface, "org.a11y.atspi.Value") == 0) { names = value; n = 6; }
  else if (strcmp(iface, "org.a11y.atspi.Selection") == 0) { names = selection; n = 2; }
  else if (strcmp(iface, "org.a11y.atspi.Table") == 0) { names = table; n = 7; }
  else if (strcmp(iface, "org.a11y.atspi.TableCell") == 0) { names = cell; n = 5; }
  else if (strcmp(iface, "org.a11y.atspi.Application") == 0) { names = application; n = 6; }
  else if (strcmp(iface, "org.a11y.atspi.Socket") == 0) { names = socket; n = 1; }
  *count = n;
  if (names == NULL || index < 0 || index >= n) return NULL;
  return names[index];
}

/** The row children of a table, and the cell children of a row. */
static int ax_is_row(const AxNode *n) { return n != NULL && ax_role_of(n) == 90; }
static int ax_is_cell(const AxNode *n) {
  uint32_t role = ax_role_of(n);
  return role == 56 || role == 57 || role == 58;
}

static int ax_row_count(const AxNode *table) {
  int count = 0;
  for (int i = 0; i < ax_child_count(table); i++) {
    if (ax_is_row(ax_child(table, i))) count++;
  }
  return count;
}

static AxNode *ax_row_at(const AxNode *table, int index) {
  int seen = 0;
  for (int i = 0; i < ax_child_count(table); i++) {
    AxNode *child = ax_child(table, i);
    if (!ax_is_row(child)) continue;
    if (seen++ == index) return child;
  }
  return NULL;
}

static int ax_column_count(const AxNode *table) {
  int columns = 0;
  for (int i = 0; i < ax_row_count(table); i++) {
    AxNode *row = ax_row_at(table, i);
    int cells = 0;
    for (int j = 0; j < ax_child_count(row); j++) {
      if (ax_is_cell(ax_child(row, j))) cells++;
    }
    if (cells > columns) columns = cells;
  }
  return columns;
}

static AxNode *ax_cell_at(const AxNode *table, int row, int column) {
  AxNode *line = ax_row_at(table, row);
  if (line == NULL) return NULL;
  int seen = 0;
  for (int i = 0; i < ax_child_count(line); i++) {
    AxNode *cell = ax_child(line, i);
    if (!ax_is_cell(cell)) continue;
    if (seen++ == column) return cell;
  }
  return NULL;
}

/** The locale the session runs in, which a screen reader uses to pick a voice. */
static const char *ax_locale(void) {
  const char *value = getenv("LC_ALL");
  if (value == NULL || value[0] == '\0') value = getenv("LC_MESSAGES");
  if (value == NULL || value[0] == '\0') value = getenv("LANG");
  if (value == NULL || value[0] == '\0') return "";
  return value;
}

/** The actions a node offers, from the actions the runtime says it takes: a press is the click a
 *  browser's Action has, a range's step is increment and decrement, and a menu's is showMenu. */
static int ax_action_count(const AxNode *n) {
  if (n == NULL || ax_is_document(n)) return 0;
  int count = 0;
  if (n->actions & AXA_PRESS) count++;
  if (n->actions & AXA_INCREMENT) count += 2;
  if (n->actions & AXA_SHOW_MENU) count++;
  return count;
}

static const char *ax_action_name(const AxNode *n, int index) {
  if (n == NULL || ax_is_document(n) || index < 0) return NULL;
  int at = 0;
  if (n->actions & AXA_PRESS) {
    if (at++ == index) return "click";
  }
  if (n->actions & AXA_INCREMENT) {
    if (at++ == index) return "increment";
    if (at++ == index) return "decrement";
  }
  if (n->actions & AXA_SHOW_MENU) {
    if (at++ == index) return "showMenu";
  }
  return NULL;
}

/** A cell's row, column and table, which its position and the table's answer need. */
static AxNode *ax_cell_table(const AxNode *cell, int *row, int *column);

/** Appends one property's value as a variant; 1 when the object has that property. */
static int ax_append_property(DBusMessageIter *iter, const AxNode *n, const char *iface,
                              const char *property) {
  DBusMessageIter variant;
  uint32_t version = 1;
  const char *empty = "";
  dbus_int32_t number = 0;
  double real = 0;
  int is_root = n == NULL;
  if (strcmp(iface, "org.a11y.atspi.Accessible") == 0) {
    if (strcmp(property, "version") == 0) {
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "u", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_UINT32, &version);
    } else if (strcmp(property, "Name") == 0) {
      // The application and the page's document are both announced by the page's title.
      const char *name = is_root || ax_is_document(n) ? g_ax_title
                       : (n->label[0] != '\0' ? n->label : n->value);
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "s", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_STRING, &name);
    } else if (strcmp(property, "Description") == 0 || strcmp(property, "HelpText") == 0 ||
               strcmp(property, "AccessibleId") == 0) {
      const char *text = empty;
      if (!is_root && !ax_is_document(n)) {
        if (strcmp(property, "AccessibleId") == 0) text = n->dom_id != NULL ? n->dom_id : empty;
        else text = n->description != NULL ? n->description : empty;
      }
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "s", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_STRING, &text);
    } else if (strcmp(property, "Parent") == 0) {
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "(so)", &variant);
      if (is_root) ax_append_null_ref(&variant);
      else ax_append_ref(&variant, ax_parent_of(n));
    } else if (strcmp(property, "ChildCount") == 0) {
      number = ax_child_count(n);
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "i", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_INT32, &number);
    } else if (strcmp(property, "Locale") == 0) {
      const char *locale = ax_locale();
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "s", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_STRING, &locale);
    } else {
      return 0;
    }
    dbus_message_iter_close_container(iter, &variant);
    return 1;
  }
  if (strcmp(iface, "org.a11y.atspi.Component") == 0 && strcmp(property, "version") == 0) {
    dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "u", &variant);
    dbus_message_iter_append_basic(&variant, DBUS_TYPE_UINT32, &version);
    dbus_message_iter_close_container(iter, &variant);
    return 1;
  }
  if (strcmp(iface, "org.a11y.atspi.Action") == 0) {
    if (strcmp(property, "version") == 0) {
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "u", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_UINT32, &version);
    } else if (strcmp(property, "NActions") == 0) {
      number = is_root ? 0 : ax_action_count(n);
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "i", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_INT32, &number);
    } else {
      return 0;
    }
    dbus_message_iter_close_container(iter, &variant);
    return 1;
  }
  if (strcmp(iface, "org.a11y.atspi.Text") == 0) {
    if (strcmp(property, "version") == 0) {
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "u", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_UINT32, &version);
    } else if (strcmp(property, "CharacterCount") == 0) {
      number = is_root ? 0 : (dbus_int32_t)ax_unit_offset(ax_text(n), strlen(ax_text(n)));
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "i", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_INT32, &number);
    } else if (strcmp(property, "CaretOffset") == 0) {
      number = is_root ? 0 : ax_caret(n);
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "i", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_INT32, &number);
    } else {
      return 0;
    }
    dbus_message_iter_close_container(iter, &variant);
    return 1;
  }
  if (strcmp(iface, "org.a11y.atspi.EditableText") == 0) {
    if (strcmp(property, "version") != 0) return 0;
    dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "u", &variant);
    dbus_message_iter_append_basic(&variant, DBUS_TYPE_UINT32, &version);
    dbus_message_iter_close_container(iter, &variant);
    return 1;
  }
  if (strcmp(iface, "org.a11y.atspi.Hyperlink") == 0) {
    if (strcmp(property, "version") == 0) {
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "u", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_UINT32, &version);
      dbus_message_iter_close_container(iter, &variant);
      return 1;
    }
    if (strcmp(property, "NAnchors") == 0) {
      // One anchor per link: the element itself.
      dbus_int16_t anchors = is_root || ax_is_document(n) ? 0 : 1;
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "n", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_INT16, &anchors);
      dbus_message_iter_close_container(iter, &variant);
      return 1;
    }
    if (strcmp(property, "StartIndex") == 0 || strcmp(property, "EndIndex") == 0) {
      number = strcmp(property, "StartIndex") == 0 || is_root || ax_is_document(n)
        ? 0 : (dbus_int32_t)strlen(ax_text(n));
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "i", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_INT32, &number);
      dbus_message_iter_close_container(iter, &variant);
      return 1;
    }
    return 0;
  }
  if (strcmp(iface, "org.a11y.atspi.Value") == 0) {
    if (strcmp(property, "version") == 0) {
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "u", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_UINT32, &version);
    } else if (strcmp(property, "MinimumValue") == 0 || strcmp(property, "MaximumValue") == 0 ||
               strcmp(property, "MinimumIncrement") == 0 || strcmp(property, "CurrentValue") == 0) {
      if (!is_root) {
        if (strcmp(property, "MinimumValue") == 0) real = n->has_min ? n->range_min : 0;
        else if (strcmp(property, "MaximumValue") == 0) real = n->has_max ? n->range_max : 100;
        else if (strcmp(property, "MinimumIncrement") == 0) real = 1;
        else if (n->has_now) real = n->range_now;
        else real = strtod(n->value != NULL ? n->value : "", NULL);
      }
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "d", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_DOUBLE, &real);
    } else if (strcmp(property, "Text") == 0) {
      const char *text = is_root ? "" : n->value;
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "s", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_STRING, &text);
    } else {
      return 0;
    }
    dbus_message_iter_close_container(iter, &variant);
    return 1;
  }
  if (strcmp(iface, "org.a11y.atspi.Selection") == 0) {
    if (strcmp(property, "version") == 0) {
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "u", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_UINT32, &version);
    } else if (strcmp(property, "NSelectedChildren") == 0) {
      int selected = 0;
      for (int i = 0; n != NULL && i < ax_child_count(n); i++) {
        AxNode *child = ax_child(n, i);
        if (child != NULL && ax_is_selected(child)) selected++;
      }
      number = selected;
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "i", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_INT32, &number);
    } else {
      return 0;
    }
    dbus_message_iter_close_container(iter, &variant);
    return 1;
  }
  if (strcmp(iface, "org.a11y.atspi.Table") == 0) {
    if (strcmp(property, "version") == 0) {
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "u", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_UINT32, &version);
    } else if (strcmp(property, "NRows") == 0 || strcmp(property, "NColumns") == 0 ||
               strcmp(property, "NSelectedRows") == 0 || strcmp(property, "NSelectedColumns") == 0) {
      if (is_root) number = 0;
      else if (strcmp(property, "NRows") == 0) number = ax_row_count(n);
      else if (strcmp(property, "NColumns") == 0) number = ax_column_count(n);
      else number = 0;
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "i", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_INT32, &number);
    } else if (strcmp(property, "Caption") == 0 || strcmp(property, "Summary") == 0) {
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "(so)", &variant);
      ax_append_null_ref(&variant);
    } else {
      return 0;
    }
    dbus_message_iter_close_container(iter, &variant);
    return 1;
  }
  if (strcmp(iface, "org.a11y.atspi.TableCell") == 0) {
    if (strcmp(property, "version") == 0) {
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "u", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_UINT32, &version);
    } else if (strcmp(property, "RowSpan") == 0 || strcmp(property, "ColumnSpan") == 0) {
      number = 1;
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "i", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_INT32, &number);
    } else if (strcmp(property, "Position") == 0) {
      int row = 0, column = 0;
      ax_cell_table(is_root ? NULL : n, &row, &column);
      dbus_int32_t first = row, second = column;
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "(ii)", &variant);
      DBusMessageIter pair;
      dbus_message_iter_open_container(&variant, DBUS_TYPE_STRUCT, NULL, &pair);
      dbus_message_iter_append_basic(&pair, DBUS_TYPE_INT32, &first);
      dbus_message_iter_append_basic(&pair, DBUS_TYPE_INT32, &second);
      dbus_message_iter_close_container(&variant, &pair);
    } else if (strcmp(property, "Table") == 0) {
      AxNode *line = !is_root && n->parent != 0 ? ax_node_by_id(n->parent) : NULL;
      AxNode *table = line != NULL && line->parent != 0 ? ax_node_by_id(line->parent) : NULL;
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "(so)", &variant);
      if (table != NULL) ax_append_ref(&variant, table);
      else ax_append_null_ref(&variant);
    } else {
      return 0;
    }
    dbus_message_iter_close_container(iter, &variant);
    return 1;
  }
  if (strcmp(iface, "org.a11y.atspi.Application") == 0) {
    if (strcmp(property, "ToolkitName") == 0) {
      const char *toolkit = "native-sdk";
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "s", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_STRING, &toolkit);
    } else if (strcmp(property, "Version") == 0 || strcmp(property, "ToolkitVersion") == 0) {
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "s", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_STRING, &empty);
    } else if (strcmp(property, "AtspiVersion") == 0) {
      const char *atspi = "2.1";
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "s", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_STRING, &atspi);
    } else if (strcmp(property, "InterfaceVersion") == 0) {
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "u", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_UINT32, &version);
    } else if (strcmp(property, "Id") == 0) {
      number = g_ax_app_id;
      dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "i", &variant);
      dbus_message_iter_append_basic(&variant, DBUS_TYPE_INT32, &number);
    } else {
      return 0;
    }
    dbus_message_iter_close_container(iter, &variant);
    return 1;
  }
  if (strcmp(iface, "org.a11y.atspi.Socket") == 0 && strcmp(property, "version") == 0) {
    dbus_message_iter_open_container(iter, DBUS_TYPE_VARIANT, "u", &variant);
    dbus_message_iter_append_basic(&variant, DBUS_TYPE_UINT32, &version);
    dbus_message_iter_close_container(iter, &variant);
    return 1;
  }
  return 0;
}

// --- Caching the tree ---------------------------------------------------------

/** The path the accessibility cache lives at. */
static const char AX_CACHE[] = "/org/a11y/atspi/cache";

/** Appends the fields of one cache entry into an open struct: the object, its application and
 *  parent, its place, interfaces, name, role, description and states. */
static void ax_append_cache_fields(DBusMessageIter *entry, const AxNode *n) {
  DBusMessageIter interfaces, states;
  ax_append_ref(entry, n);
  ax_append_ref(entry, NULL);
  if (n == NULL) ax_append_null_ref(entry);
  else ax_append_ref(entry, ax_parent_of(n));
  dbus_int32_t index = n == NULL ? -1 : ax_index_in_parent(n);
  dbus_int32_t children = ax_child_count(n);
  uint32_t role = n == NULL ? 75 : ax_role_of(n);
  const char *names[12];
  int count = ax_interface_names(role, n == NULL ? 0 : ax_ifaces(n), names);
  const char *name = n == NULL || ax_is_document(n) ? g_ax_title
    : (n->label != NULL && n->label[0] != '\0' ? n->label : (n->value != NULL ? n->value : ""));
  uint32_t number = role;
  const char *description = "";
  uint64_t set = n == NULL ? 0 : ax_states(n);
  dbus_uint32_t bits[2] = { (dbus_uint32_t)(set & 0xffffffffu), (dbus_uint32_t)(set >> 32) };
  dbus_message_iter_append_basic(entry, DBUS_TYPE_INT32, &index);
  dbus_message_iter_append_basic(entry, DBUS_TYPE_INT32, &children);
  dbus_message_iter_open_container(entry, DBUS_TYPE_ARRAY, "s", &interfaces);
  for (int i = 0; i < count; i++) {
    dbus_message_iter_append_basic(&interfaces, DBUS_TYPE_STRING, &names[i]);
  }
  dbus_message_iter_close_container(entry, &interfaces);
  dbus_message_iter_append_basic(entry, DBUS_TYPE_STRING, &name);
  dbus_message_iter_append_basic(entry, DBUS_TYPE_UINT32, &number);
  dbus_message_iter_append_basic(entry, DBUS_TYPE_STRING, &description);
  dbus_message_iter_open_container(entry, DBUS_TYPE_ARRAY, "u", &states);
  dbus_message_iter_append_basic(&states, DBUS_TYPE_UINT32, &bits[0]);
  dbus_message_iter_append_basic(&states, DBUS_TYPE_UINT32, &bits[1]);
  dbus_message_iter_close_container(entry, &states);
}

/** Appends one entry of GetItems' array: the fields above inside a struct. */
static void ax_append_cache_entry(DBusMessageIter *array, const AxNode *n) {
  DBusMessageIter entry;
  dbus_message_iter_open_container(array, DBUS_TYPE_STRUCT, NULL, &entry);
  ax_append_cache_fields(&entry, n);
  dbus_message_iter_close_container(array, &entry);
}

/** The cache answers with its whole snapshot; the tree is small enough to send at once. */
static DBusHandlerResult ax_cache_message(DBusConnection *conn, DBusMessage *msg, const char *iface,
                                          const char *member) {
  if (strcmp(iface, "org.a11y.atspi.Cache") == 0 && strcmp(member, "GetItems") == 0) {
    DBusMessage *reply = dbus_message_new_method_return(msg);
    if (reply == NULL) return DBUS_HANDLER_RESULT_HANDLED;
    DBusMessageIter iter, array;
    dbus_message_iter_init_append(reply, &iter);
    dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "((so)(so)(so)iiassusau)", &array);
    ax_append_cache_entry(&array, NULL);
    if (g_ax_has_tree) ax_append_cache_entry(&array, &g_ax_document);
    for (int i = 0; i < g_ax_node_count; i++) ax_append_cache_entry(&array, &g_ax_nodes[i]);
    dbus_message_iter_close_container(&iter, &array);
    ax_send(conn, reply);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (strcmp(iface, "org.freedesktop.DBus.Properties") == 0 &&
      strcmp(member, "Get") == 0) {
    DBusMessage *reply = dbus_message_new_method_return(msg);
    if (reply == NULL) return DBUS_HANDLER_RESULT_HANDLED;
    DBusMessageIter iter, variant;
    dbus_uint32_t version = 1;
    dbus_message_iter_init_append(reply, &iter);
    dbus_message_iter_open_container(&iter, DBUS_TYPE_VARIANT, "u", &variant);
    dbus_message_iter_append_basic(&variant, DBUS_TYPE_UINT32, &version);
    dbus_message_iter_close_container(&iter, &variant);
    ax_send(conn, reply);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (strcmp(iface, "org.freedesktop.DBus.Properties") == 0 &&
      strcmp(member, "GetAll") == 0) {
    DBusMessage *reply = dbus_message_new_method_return(msg);
    if (reply == NULL) return DBUS_HANDLER_RESULT_HANDLED;
    DBusMessageIter iter, dict, entry, variant;
    const char *key = "version";
    dbus_uint32_t version = 1;
    dbus_message_iter_init_append(reply, &iter);
    dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "{sv}", &dict);
    dbus_message_iter_open_container(&dict, DBUS_TYPE_DICT_ENTRY, NULL, &entry);
    dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &key);
    dbus_message_iter_open_container(&entry, DBUS_TYPE_VARIANT, "u", &variant);
    dbus_message_iter_append_basic(&variant, DBUS_TYPE_UINT32, &version);
    dbus_message_iter_close_container(&entry, &variant);
    dbus_message_iter_close_container(&dict, &entry);
    dbus_message_iter_close_container(&iter, &dict);
    ax_send(conn, reply);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (strcmp(iface, "org.freedesktop.DBus.Introspectable") == 0 &&
      strcmp(member, "Introspect") == 0) {
    ax_send_string(conn, msg,
                   "<node><interface name=\"org.a11y.atspi.Cache\">"
                   "<property name=\"version\" type=\"u\" access=\"read\"/>"
                   "<method name=\"GetItems\">"
                   "<arg direction=\"out\" type=\"a((so)(so)(so)iiassusau)\"/>"
                   "</method></interface></node>");
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  ax_send_error(conn, msg, "The cache doesn't answer that call");
  return DBUS_HANDLER_RESULT_HANDLED;
}

// --- Method calls -----------------------------------------------------------

static void ax_send_uint(DBusConnection *conn, DBusMessage *msg, uint32_t value) {
  DBusMessage *reply = dbus_message_new_method_return(msg);
  if (reply != NULL) dbus_message_append_args(reply, DBUS_TYPE_UINT32, &value, DBUS_TYPE_INVALID);
  ax_send(conn, reply);
}

static void ax_send_double(DBusConnection *conn, DBusMessage *msg, double value) {
  DBusMessage *reply = dbus_message_new_method_return(msg);
  if (reply != NULL) dbus_message_append_args(reply, DBUS_TYPE_DOUBLE, &value, DBUS_TYPE_INVALID);
  ax_send(conn, reply);
}

/** Replies with the empty reference, for a question whose answer is no object. */
static void ax_send_null_ref(DBusConnection *conn, DBusMessage *msg) {
  DBusMessage *reply = dbus_message_new_method_return(msg);
  if (reply == NULL) return;
  DBusMessageIter iter;
  dbus_message_iter_init_append(reply, &iter);
  ax_append_null_ref(&iter);
  ax_send(conn, reply);
}

/** Replies with an empty array of `signature`, for an answer with nothing in it. */
static void ax_send_empty_array(DBusConnection *conn, DBusMessage *msg, const char *signature) {
  DBusMessage *reply = dbus_message_new_method_return(msg);
  if (reply == NULL) return;
  DBusMessageIter iter, array;
  dbus_message_iter_init_append(reply, &iter);
  dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, signature, &array);
  dbus_message_iter_close_container(&iter, &array);
  ax_send(conn, reply);
}

/** Replies with four separate numbers: a rectangle's x, y, width and height. */
static void ax_send_four(DBusConnection *conn, DBusMessage *msg, const double box[4]) {
  DBusMessage *reply = dbus_message_new_method_return(msg);
  if (reply == NULL) return;
  DBusMessageIter iter;
  dbus_int32_t values[4];
  for (int i = 0; i < 4; i++) values[i] = (dbus_int32_t)lround(box[i]);
  dbus_message_iter_init_append(reply, &iter);
  for (int i = 0; i < 4; i++) dbus_message_iter_append_basic(&iter, DBUS_TYPE_INT32, &values[i]);
  ax_send(conn, reply);
}

/** Replies with a rectangle struct, as GetExtents returns it. */
static void ax_send_rect(DBusConnection *conn, DBusMessage *msg, const double box[4]) {
  DBusMessage *reply = dbus_message_new_method_return(msg);
  if (reply == NULL) return;
  DBusMessageIter iter, st;
  dbus_int32_t values[4];
  for (int i = 0; i < 4; i++) values[i] = (dbus_int32_t)lround(box[i]);
  dbus_message_iter_init_append(reply, &iter);
  dbus_message_iter_open_container(&iter, DBUS_TYPE_STRUCT, NULL, &st);
  for (int i = 0; i < 4; i++) dbus_message_iter_append_basic(&st, DBUS_TYPE_INT32, &values[i]);
  dbus_message_iter_close_container(&iter, &st);
  ax_send(conn, reply);
}

/** Replies to Properties.Get, Properties.GetAll and Properties.Set. */
static DBusHandlerResult ax_properties(DBusConnection *conn, DBusMessage *msg, const char *member,
                                       AxNode *n) {
  if (strcmp(member, "Get") == 0) {
    const char *iface = NULL, *property = NULL;
    if (!dbus_message_get_args(msg, NULL, DBUS_TYPE_STRING, &iface, DBUS_TYPE_STRING, &property,
                               DBUS_TYPE_INVALID)) {
      ax_send_error(conn, msg, "Properties.Get takes an interface and a property");
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    DBusMessage *reply = dbus_message_new_method_return(msg);
    if (reply == NULL) return DBUS_HANDLER_RESULT_HANDLED;
    DBusMessageIter iter;
    dbus_message_iter_init_append(reply, &iter);
    if (!ax_append_property(&iter, n, iface, property)) {
      dbus_message_unref(reply);
      ax_send(conn, dbus_message_new_error(msg, "org.freedesktop.DBus.Error.InvalidArgs",
                                           "No such property"));
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    ax_send(conn, reply);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (strcmp(member, "GetAll") == 0) {
    const char *iface = NULL;
    if (!dbus_message_get_args(msg, NULL, DBUS_TYPE_STRING, &iface, DBUS_TYPE_INVALID)) {
      ax_send_error(conn, msg, "Properties.GetAll takes an interface name");
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    DBusMessage *reply = dbus_message_new_method_return(msg);
    if (reply == NULL) return DBUS_HANDLER_RESULT_HANDLED;
    DBusMessageIter iter, dict;
    dbus_message_iter_init_append(reply, &iter);
    dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "{sv}", &dict);
    for (int i = 0;; i++) {
      int count = 0;
      const char *property = ax_property_at(iface, i, &count);
      if (property == NULL) break;
      DBusMessageIter entry;
      dbus_message_iter_open_container(&dict, DBUS_TYPE_DICT_ENTRY, NULL, &entry);
      dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &property);
      if (!ax_append_property(&entry, n, iface, property)) {
        // A name the table lists but the object doesn't answer would marshal a broken entry.
        dbus_message_iter_abandon_container(&dict, &entry);
        continue;
      }
      dbus_message_iter_close_container(&dict, &entry);
    }
    dbus_message_iter_close_container(&iter, &dict);
    ax_send(conn, reply);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (strcmp(member, "Set") == 0) {
    // The registry assigns the application its Id this way; everything else a client asks to set
    // is state the page owns, and an empty reply says it was accepted without moving the page.
    const char *iface = NULL, *property = NULL;
    DBusMessageIter iter, variant;
    if (dbus_message_iter_init(msg, &iter) &&
        dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_STRING) {
      dbus_message_iter_get_basic(&iter, &iface);
      if (dbus_message_iter_next(&iter) &&
          dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_STRING) {
        dbus_message_iter_get_basic(&iter, &property);
        if (dbus_message_iter_next(&iter) &&
            dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_VARIANT) {
          dbus_message_iter_recurse(&iter, &variant);
          if (iface != NULL && property != NULL &&
              strcmp(iface, "org.a11y.atspi.Application") == 0 &&
              strcmp(property, "Id") == 0 &&
              dbus_message_iter_get_arg_type(&variant) == DBUS_TYPE_INT32) {
            dbus_int32_t id = 0;
            dbus_message_iter_get_basic(&variant, &id);
            g_ax_app_id = id;
          } else if (iface != NULL && property != NULL && n != NULL &&
                     strcmp(iface, "org.a11y.atspi.Value") == 0 &&
                     strcmp(property, "CurrentValue") == 0 &&
                     dbus_message_iter_get_arg_type(&variant) == DBUS_TYPE_DOUBLE) {
            // A client writes a range's position through the property as through the method.
            double value = 0;
            dbus_message_iter_get_basic(&variant, &value);
            if ((n->actions & AXA_SET_VALUE) != 0) {
              char text[64];
              snprintf(text, sizeof text, "%.17g", value);
              ax_queue(AX_SET_VALUE, n->uid, dup_str(text), 0, 0);
            }
          }
        }
      }
    }
    ax_send(conn, dbus_message_new_method_return(msg));
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  ax_send_error(conn, msg, "No such property call");
  return DBUS_HANDLER_RESULT_HANDLED;
}

// --- Introspection ------------------------------------------------------------

/** The XML an object answers with: the interfaces it carries, as the bus describes them. */
static const char *ax_introspect_iface(const char *iface) {
  static const char accessible[] =
    "<interface name=\"org.a11y.atspi.Accessible\">"
    "<property name=\"version\" type=\"u\" access=\"read\"/>"
    "<property name=\"Name\" type=\"s\" access=\"read\"/>"
    "<property name=\"Description\" type=\"s\" access=\"read\"/>"
    "<property name=\"Parent\" type=\"(so)\" access=\"read\"/>"
    "<property name=\"ChildCount\" type=\"i\" access=\"read\"/>"
    "<property name=\"Locale\" type=\"s\" access=\"read\"/>"
    "<property name=\"AccessibleId\" type=\"s\" access=\"read\"/>"
    "<property name=\"HelpText\" type=\"s\" access=\"read\"/>"
    "<method name=\"GetChildAtIndex\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"(so)\"/></method>"
    "<method name=\"GetChildren\"><arg direction=\"out\" type=\"a(so)\"/></method>"
    "<method name=\"GetIndexInParent\"><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"GetRelationSet\"><arg direction=\"out\" type=\"a(ua(so))\"/></method>"
    "<method name=\"GetRole\"><arg direction=\"out\" type=\"u\"/></method>"
    "<method name=\"GetRoleName\"><arg direction=\"out\" type=\"s\"/></method>"
    "<method name=\"GetLocalizedRoleName\"><arg direction=\"out\" type=\"s\"/></method>"
    "<method name=\"GetState\"><arg direction=\"out\" type=\"au\"/></method>"
    "<method name=\"GetAttributes\"><arg direction=\"out\" type=\"a{ss}\"/></method>"
    "<method name=\"GetApplication\"><arg direction=\"out\" type=\"(so)\"/></method>"
    "<method name=\"GetInterfaces\"><arg direction=\"out\" type=\"as\"/></method>"
    "</interface>";
  static const char component[] =
    "<interface name=\"org.a11y.atspi.Component\">"
    "<property name=\"version\" type=\"u\" access=\"read\"/>"
    "<method name=\"Contains\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"u\"/><arg direction=\"out\" type=\"b\"/></method>"
    "<method name=\"GetAccessibleAtPoint\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"u\"/><arg direction=\"out\" type=\"(so)\"/></method>"
    "<method name=\"GetExtents\"><arg direction=\"in\" type=\"u\"/><arg direction=\"out\" type=\"(iiii)\"/></method>"
    "<method name=\"GetPosition\"><arg direction=\"in\" type=\"u\"/><arg direction=\"out\" type=\"i\"/><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"GetSize\"><arg direction=\"out\" type=\"i\"/><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"GetLayer\"><arg direction=\"out\" type=\"u\"/></method>"
    "<method name=\"GetMDIZOrder\"><arg direction=\"out\" type=\"n\"/></method>"
    "<method name=\"GrabFocus\"><arg direction=\"out\" type=\"b\"/></method>"
    "<method name=\"ScrollTo\"><arg direction=\"in\" type=\"u\"/><arg direction=\"out\" type=\"b\"/></method>"
    "<method name=\"ScrollToPoint\"><arg direction=\"in\" type=\"u\"/><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"b\"/></method>"
    "<method name=\"GetAlpha\"><arg direction=\"out\" type=\"d\"/></method>"
    "</interface>";
  static const char action[] =
    "<interface name=\"org.a11y.atspi.Action\">"
    "<property name=\"version\" type=\"u\" access=\"read\"/>"
    "<property name=\"NActions\" type=\"i\" access=\"read\"/>"
    "<method name=\"GetName\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"s\"/></method>"
    "<method name=\"GetDescription\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"s\"/></method>"
    "<method name=\"GetLocalizedName\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"s\"/></method>"
    "<method name=\"GetKeyBinding\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"s\"/></method>"
    "<method name=\"GetActions\"><arg direction=\"out\" type=\"a(sss)\"/></method>"
    "<method name=\"DoAction\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"b\"/></method>"
    "</interface>";
  static const char text[] =
    "<interface name=\"org.a11y.atspi.Text\">"
    "<property name=\"version\" type=\"u\" access=\"read\"/>"
    "<property name=\"CharacterCount\" type=\"i\" access=\"read\"/>"
    "<property name=\"CaretOffset\" type=\"i\" access=\"read\"/>"
    "<method name=\"GetText\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"s\"/></method>"
    "<method name=\"GetStringAtOffset\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"u\"/><arg direction=\"out\" type=\"s\"/><arg direction=\"out\" type=\"i\"/><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"GetTextAtOffset\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"u\"/><arg direction=\"out\" type=\"s\"/><arg direction=\"out\" type=\"i\"/><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"GetTextBeforeOffset\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"u\"/><arg direction=\"out\" type=\"s\"/><arg direction=\"out\" type=\"i\"/><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"GetTextAfterOffset\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"u\"/><arg direction=\"out\" type=\"s\"/><arg direction=\"out\" type=\"i\"/><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"GetCharacterAtOffset\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"GetAttributeValue\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"s\"/><arg direction=\"out\" type=\"s\"/></method>"
    "<method name=\"GetAttributes\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"a{ss}\"/><arg direction=\"out\" type=\"i\"/><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"GetDefaultAttributes\"><arg direction=\"out\" type=\"a{ss}\"/></method>"
    "<method name=\"GetCharacterExtents\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"u\"/><arg direction=\"out\" type=\"i\"/><arg direction=\"out\" type=\"i\"/><arg direction=\"out\" type=\"i\"/><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"GetRangeExtents\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"u\"/><arg direction=\"out\" type=\"i\"/><arg direction=\"out\" type=\"i\"/><arg direction=\"out\" type=\"i\"/><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"GetOffsetAtPoint\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"u\"/><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"GetNSelections\"><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"GetSelection\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"i\"/><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"AddSelection\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"b\"/></method>"
    "<method name=\"RemoveSelection\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"b\"/></method>"
    "<method name=\"SetSelection\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"b\"/></method>"
    "<method name=\"SetCaretOffset\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"b\"/></method>"
    "</interface>";
  static const char editable[] =
    "<interface name=\"org.a11y.atspi.EditableText\">"
    "<property name=\"version\" type=\"u\" access=\"read\"/>"
    "<method name=\"SetTextContents\"><arg direction=\"in\" type=\"s\"/><arg direction=\"out\" type=\"b\"/></method>"
    "<method name=\"InsertText\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"s\"/><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"b\"/></method>"
    "<method name=\"DeleteText\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"b\"/></method>"
    "<method name=\"CopyText\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"b\"/></method>"
    "<method name=\"CutText\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"b\"/></method>"
    "<method name=\"PasteText\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"b\"/></method>"
    "</interface>";
  static const char hyperlink[] =
    "<interface name=\"org.a11y.atspi.Hyperlink\">"
    "<property name=\"version\" type=\"u\" access=\"read\"/>"
    "<property name=\"StartIndex\" type=\"i\" access=\"read\"/>"
    "<property name=\"EndIndex\" type=\"i\" access=\"read\"/>"
    "<property name=\"NAnchors\" type=\"n\" access=\"read\"/>"
    "<method name=\"GetObject\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"(so)\"/></method>"
    "<method name=\"GetURI\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"s\"/></method>"
    "<method name=\"IsValid\"><arg direction=\"out\" type=\"b\"/></method>"
    "</interface>";
  static const char value[] =
    "<interface name=\"org.a11y.atspi.Value\">"
    "<property name=\"version\" type=\"u\" access=\"read\"/>"
    "<property name=\"MinimumValue\" type=\"d\" access=\"read\"/>"
    "<property name=\"MaximumValue\" type=\"d\" access=\"read\"/>"
    "<property name=\"MinimumIncrement\" type=\"d\" access=\"read\"/>"
    "<property name=\"CurrentValue\" type=\"d\" access=\"readwrite\"/>"
    "<property name=\"Text\" type=\"s\" access=\"read\"/>"
    "<method name=\"GetCurrentValue\"><arg direction=\"out\" type=\"d\"/></method>"
    "<method name=\"GetMinimumValue\"><arg direction=\"out\" type=\"d\"/></method>"
    "<method name=\"GetMaximumValue\"><arg direction=\"out\" type=\"d\"/></method>"
    "<method name=\"GetMinimumIncrement\"><arg direction=\"out\" type=\"d\"/></method>"
    "<method name=\"SetCurrentValue\"><arg direction=\"in\" type=\"d\"/><arg direction=\"out\" type=\"b\"/></method>"
    "</interface>";
  static const char selection[] =
    "<interface name=\"org.a11y.atspi.Selection\">"
    "<property name=\"version\" type=\"u\" access=\"read\"/>"
    "<property name=\"NSelectedChildren\" type=\"i\" access=\"read\"/>"
    "<method name=\"GetSelectedChild\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"(so)\"/></method>"
    "<method name=\"SelectChild\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"b\"/></method>"
    "<method name=\"DeselectSelectedChild\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"b\"/></method>"
    "<method name=\"IsChildSelected\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"b\"/></method>"
    "<method name=\"SelectAll\"><arg direction=\"out\" type=\"b\"/></method>"
    "<method name=\"ClearSelection\"><arg direction=\"out\" type=\"b\"/></method>"
    "<method name=\"DeselectChild\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"b\"/></method>"
    "</interface>";
  static const char table[] =
    "<interface name=\"org.a11y.atspi.Table\">"
    "<property name=\"version\" type=\"u\" access=\"read\"/>"
    "<property name=\"NRows\" type=\"i\" access=\"read\"/>"
    "<property name=\"NColumns\" type=\"i\" access=\"read\"/>"
    "<property name=\"Caption\" type=\"(so)\" access=\"read\"/>"
    "<property name=\"Summary\" type=\"(so)\" access=\"read\"/>"
    "<property name=\"NSelectedRows\" type=\"i\" access=\"read\"/>"
    "<property name=\"NSelectedColumns\" type=\"i\" access=\"read\"/>"
    "<method name=\"GetAccessibleAt\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"(so)\"/></method>"
    "<method name=\"GetIndexAt\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"GetRowAtIndex\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"GetColumnAtIndex\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"GetRowExtentAt\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"GetColumnExtentAt\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"GetRowDescription\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"s\"/></method>"
    "<method name=\"GetColumnDescription\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"s\"/></method>"
    "<method name=\"GetRowHeader\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"(so)\"/></method>"
    "<method name=\"GetColumnHeader\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"(so)\"/></method>"
    "<method name=\"GetSelectedRows\"><arg direction=\"out\" type=\"ai\"/></method>"
    "<method name=\"GetSelectedColumns\"><arg direction=\"out\" type=\"ai\"/></method>"
    "<method name=\"IsRowSelected\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"b\"/></method>"
    "<method name=\"IsColumnSelected\"><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"b\"/></method>"
    "<method name=\"IsSelected\"><arg direction=\"in\" type=\"i\"/><arg direction=\"in\" type=\"i\"/><arg direction=\"out\" type=\"b\"/></method>"
    "<method name=\"GetCaption\"><arg direction=\"out\" type=\"(so)\"/></method>"
    "<method name=\"GetSummary\"><arg direction=\"out\" type=\"(so)\"/></method>"
    "<method name=\"GetNRows\"><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"GetNColumns\"><arg direction=\"out\" type=\"i\"/></method>"
    "</interface>";
  static const char cell[] =
    "<interface name=\"org.a11y.atspi.TableCell\">"
    "<property name=\"version\" type=\"u\" access=\"read\"/>"
    "<property name=\"ColumnSpan\" type=\"i\" access=\"read\"/>"
    "<property name=\"Position\" type=\"(ii)\" access=\"read\"/>"
    "<property name=\"RowSpan\" type=\"i\" access=\"read\"/>"
    "<property name=\"Table\" type=\"(so)\" access=\"read\"/>"
    "<method name=\"GetRowColumnSpan\"><arg direction=\"out\" type=\"i\"/><arg direction=\"out\" type=\"i\"/><arg direction=\"out\" type=\"i\"/><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"GetColumnHeaderCells\"><arg direction=\"out\" type=\"a(so)\"/></method>"
    "<method name=\"GetRowHeaderCells\"><arg direction=\"out\" type=\"a(so)\"/></method>"
    "<method name=\"GetTable\"><arg direction=\"out\" type=\"(so)\"/></method>"
    "<method name=\"GetRowSpan\"><arg direction=\"out\" type=\"i\"/></method>"
    "<method name=\"GetColumnSpan\"><arg direction=\"out\" type=\"i\"/></method>"
    "</interface>";
  static const char application[] =
    "<interface name=\"org.a11y.atspi.Application\">"
    "<property name=\"ToolkitName\" type=\"s\" access=\"read\"/>"
    "<property name=\"Version\" type=\"s\" access=\"read\"/>"
    "<property name=\"ToolkitVersion\" type=\"s\" access=\"read\"/>"
    "<property name=\"AtspiVersion\" type=\"s\" access=\"read\"/>"
    "<property name=\"InterfaceVersion\" type=\"u\" access=\"read\"/>"
    "<property name=\"Id\" type=\"i\" access=\"readwrite\"/>"
    "<method name=\"GetLocale\"><arg direction=\"in\" type=\"u\"/><arg direction=\"out\" type=\"s\"/></method>"
    "<method name=\"GetApplicationBusAddress\"><arg direction=\"out\" type=\"s\"/></method>"
    "</interface>";
  static const char socket[] =
    "<interface name=\"org.a11y.atspi.Socket\">"
    "<property name=\"version\" type=\"u\" access=\"read\"/>"
    "<method name=\"Embed\"><arg direction=\"in\" type=\"(so)\"/><arg direction=\"out\" type=\"(so)\"/></method>"
    "<method name=\"Embedded\"><arg direction=\"in\" type=\"s\"/></method>"
    "<method name=\"Unembed\"><arg direction=\"in\" type=\"(so)\"/></method>"
    "</interface>";
  if (strcmp(iface, "org.a11y.atspi.Accessible") == 0) return accessible;
  if (strcmp(iface, "org.a11y.atspi.Component") == 0) return component;
  if (strcmp(iface, "org.a11y.atspi.Action") == 0) return action;
  if (strcmp(iface, "org.a11y.atspi.Text") == 0) return text;
  if (strcmp(iface, "org.a11y.atspi.EditableText") == 0) return editable;
  if (strcmp(iface, "org.a11y.atspi.Hyperlink") == 0) return hyperlink;
  if (strcmp(iface, "org.a11y.atspi.Value") == 0) return value;
  if (strcmp(iface, "org.a11y.atspi.Selection") == 0) return selection;
  if (strcmp(iface, "org.a11y.atspi.Table") == 0) return table;
  if (strcmp(iface, "org.a11y.atspi.TableCell") == 0) return cell;
  if (strcmp(iface, "org.a11y.atspi.Application") == 0) return application;
  if (strcmp(iface, "org.a11y.atspi.Socket") == 0) return socket;
  return NULL;
}

/** The XML for the object at a path: every interface it carries, with its members. */
static char *ax_introspect(const AxNode *n, int is_root) {
  const char *names[12];
  int count = ax_interface_names(is_root ? 75 : ax_role_of(n), is_root ? 0 : ax_ifaces(n), names);
  size_t cap = 512, len = 0;
  char *xml = (char *)malloc(cap);
  if (xml == NULL) return NULL;
  const char *head = "<node name=\"";
  char path[64];
  ax_path(n, path, sizeof path);
  const char *parts[] = { head, path, "\">", NULL };
  for (int i = 0; parts[i] != NULL; i++) {
    size_t need = strlen(parts[i]);
    while (len + need + 1 > cap) {
      cap *= 2;
      char *grown = (char *)realloc(xml, cap);
      if (grown == NULL) {
        free(xml);
        return NULL;
      }
      xml = grown;
    }
    memcpy(xml + len, parts[i], need);
    len += need;
  }
  for (int i = 0; i < count; i++) {
    const char *fragment = ax_introspect_iface(names[i]);
    if (fragment == NULL) continue;
    size_t need = strlen(fragment);
    while (len + need + 1 > cap) {
      cap *= 2;
      char *grown = (char *)realloc(xml, cap);
      if (grown == NULL) {
        free(xml);
        return NULL;
      }
      xml = grown;
    }
    memcpy(xml + len, fragment, need);
    len += need;
  }
  const char *tail = "</node>";
  size_t need = strlen(tail);
  while (len + need + 1 > cap) {
    cap *= 2;
    char *grown = (char *)realloc(xml, cap);
    if (grown == NULL) {
      free(xml);
      return NULL;
    }
    xml = grown;
  }
  memcpy(xml + len, tail, need + 1);
  return xml;
}

// --- The application's objects -----------------------------------------------

/** Queues an action on a node for the runtime, which runs it on the element itself, so the page
 *  hears the events a user's own input would send. */
static int ax_action_queue(const AxNode *n, int kind) {
  if (n == NULL || ax_is_document(n)) return 0;
  ax_queue(kind, n->uid, NULL, 0, 0);
  return 1;
}

static const char *ax_action_description(const char *name) {
  if (strcmp(name, "click") == 0) return "Clicks the element";
  if (strcmp(name, "increment") == 0) return "Increases the value";
  if (strcmp(name, "decrement") == 0) return "Decreases the value";
  if (strcmp(name, "showMenu") == 0) return "Shows the element's menu";
  return "";
}

/** The node an object's parent is, for a cell: its row, and the row's table. */
static AxNode *ax_cell_table(const AxNode *cell, int *row, int *column) {
  *row = 0;
  *column = 0;
  if (cell == NULL || cell->parent == 0) return NULL;
  AxNode *line = ax_node_by_id(cell->parent);
  if (line == NULL || line->parent == 0) return NULL;
  AxNode *table = ax_node_by_id(line->parent);
  if (table == NULL) return NULL;
  for (int i = 0; i < ax_row_count(table); i++) {
    if (ax_row_at(table, i) == line) {
      *row = i;
      break;
    }
  }
  int seen = 0;
  for (int i = 0; i < ax_child_count(line); i++) {
    AxNode *child = ax_child(line, i);
    if (!ax_is_cell(child)) continue;
    if (child == cell) break;
    seen++;
  }
  *column = seen;
  return table;
}

/** Appends one string attribute to the dict a GetAttributes reply is built from. */
static void ax_attr(DBusMessageIter *dict, const char *key, const char *value) {
  if (value == NULL || value[0] == '\0') return;
  DBusMessageIter entry;
  const char *k = key, *v = value;
  dbus_message_iter_open_container(dict, DBUS_TYPE_DICT_ENTRY, NULL, &entry);
  dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &k);
  dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &v);
  dbus_message_iter_close_container(dict, &entry);
}

/** The method calls the objects answer. */
static DBusHandlerResult ax_message(DBusConnection *conn, DBusMessage *msg, void *data) {
  (void)data;
  if (dbus_message_get_type(msg) != DBUS_MESSAGE_TYPE_METHOD_CALL) {
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
  }
  const char *iface = dbus_message_get_interface(msg);
  const char *member = dbus_message_get_member(msg);
  if (iface == NULL || member == NULL) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
  // What a client asks for, under NATIVE_AX_TRACE: enough to tell a walk from a name read.
  if (getenv("NATIVE_AX_TRACE") != NULL) {
    fprintf(stderr, "native: ax %s %s path=%s\n", iface, member,
            dbus_message_get_path(msg) != NULL ? dbus_message_get_path(msg) : "");
  }
  if (dbus_message_get_path(msg) != NULL &&
      strcmp(dbus_message_get_path(msg), AX_CACHE) == 0) {
    return ax_cache_message(conn, msg, iface, member);
  }
  int is_root = 0;
  AxNode *n = ax_node_at(dbus_message_get_path(msg), &is_root);
  if (n == NULL && !is_root) {
    ax_send(conn, dbus_message_new_error(msg, "org.freedesktop.DBus.Error.UnknownObject",
                                         "No such accessible object"));
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  // A client asking for anything below the application, or for the application's children, is
  // using the tree: from the next frame the runtime builds it, if it hasn't yet. This call is
  // answered from what is there now, so the first walk of an unbuilt page finds the application
  // alone and hears the page arrive as children-changed. Reading the application's name or role,
  // or asking what version an interface is, builds nothing.
  // A property read of the application's own name is how a client finds it, and needs no page.
  int name_property = 0;
  if (is_root && strcmp(iface, "org.freedesktop.DBus.Properties") == 0 &&
      strcmp(member, "Get") == 0) {
    DBusMessageIter it;
    const char *want_iface = NULL, *want_prop = NULL;
    if (dbus_message_iter_init(msg, &it) &&
        dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_STRING) {
      dbus_message_iter_get_basic(&it, &want_iface);
      if (dbus_message_iter_next(&it) &&
          dbus_message_iter_get_arg_type(&it) == DBUS_TYPE_STRING) {
        dbus_message_iter_get_basic(&it, &want_prop);
        name_property = want_prop != NULL && strcmp(want_prop, "Name") == 0;
      }
    }
  }
  int reading_identity = is_root &&
    (name_property ||
     strcmp(member, "GetRole") == 0 || strcmp(member, "GetRoleName") == 0 ||
     strcmp(member, "GetLocalizedRoleName") == 0 ||
     strcmp(member, "GetLocale") == 0 || strcmp(member, "GetApplicationBusAddress") == 0 ||
     strcmp(member, "Introspect") == 0 ||
     // The registry's handshake with the application, and the Id it assigns, are not a client
     // using the page.
     strcmp(iface, "org.a11y.atspi.Socket") == 0 ||
     strcmp(iface, "org.freedesktop.DBus.Peer") == 0 ||
     (strcmp(iface, "org.freedesktop.DBus.Properties") == 0 && strcmp(member, "Set") == 0));
  if (!reading_identity) {
    if (!g_ax_active && getenv("NATIVE_AX_TRACE") != NULL) {
      fprintf(stderr, "native: ax activate from %s %s\n", iface, member);
    }
    g_ax_active = 1;
  }
  uint32_t role = is_root ? 75 : ax_role_of(n);
  uint32_t ifaces = is_root ? 0 : ax_ifaces(n);

  if (strcmp(iface, "org.freedesktop.DBus.Properties") == 0) {
    return ax_properties(conn, msg, member, n);
  }
  if (strcmp(iface, "org.freedesktop.DBus.Introspectable") == 0 &&
      strcmp(member, "Introspect") == 0) {
    char *xml = ax_introspect(n, is_root);
    ax_send_string(conn, msg, xml == NULL ? "" : xml);
    free(xml);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (strcmp(iface, "org.freedesktop.DBus.Peer") == 0 && strcmp(member, "Ping") == 0) {
    ax_send(conn, dbus_message_new_method_return(msg));
    return DBUS_HANDLER_RESULT_HANDLED;
  }

  if (strcmp(iface, "org.a11y.atspi.Accessible") == 0) {
    if (strcmp(member, "GetChildAtIndex") == 0) {
      dbus_int32_t index = -1;
      dbus_message_get_args(msg, NULL, DBUS_TYPE_INT32, &index, DBUS_TYPE_INVALID);
      AxNode *child = index >= 0 ? ax_child(n, index) : NULL;
      if (child == NULL) ax_send_null_ref(conn, msg);
      else ax_send_ref(conn, msg, child);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetChildren") == 0) {
      DBusMessage *reply = dbus_message_new_method_return(msg);
      if (reply == NULL) return DBUS_HANDLER_RESULT_HANDLED;
      DBusMessageIter iter, array;
      dbus_message_iter_init_append(reply, &iter);
      dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "(so)", &array);
      for (int i = 0; i < ax_child_count(n); i++) ax_append_ref(&array, ax_child(n, i));
      dbus_message_iter_close_container(&iter, &array);
      ax_send(conn, reply);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetIndexInParent") == 0) {
      ax_send_int(conn, msg, is_root ? -1 : ax_index_in_parent(n));
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetRelationSet") == 0) {
      ax_send_empty_array(conn, msg, "(ua(so))");
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetRole") == 0) {
      ax_send_uint(conn, msg, role);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetRoleName") == 0 || strcmp(member, "GetLocalizedRoleName") == 0) {
      ax_send_string(conn, msg, ax_role_name(role));
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetState") == 0) {
      DBusMessage *reply = dbus_message_new_method_return(msg);
      if (reply == NULL) return DBUS_HANDLER_RESULT_HANDLED;
      DBusMessageIter iter, array;
      // The bitset is two words: the states clients know, and the ones a newer implementation
      // may add. A client reads both.
      uint64_t set = is_root ? 0 : ax_states(n);
      dbus_uint32_t bits[2] = { (dbus_uint32_t)(set & 0xffffffffu), (dbus_uint32_t)(set >> 32) };
      dbus_message_iter_init_append(reply, &iter);
      dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "u", &array);
      dbus_message_iter_append_basic(&array, DBUS_TYPE_UINT32, &bits[0]);
      dbus_message_iter_append_basic(&array, DBUS_TYPE_UINT32, &bits[1]);
      dbus_message_iter_close_container(&iter, &array);
      ax_send(conn, reply);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetAttributes") == 0) {
      DBusMessage *reply = dbus_message_new_method_return(msg);
      if (reply == NULL) return DBUS_HANDLER_RESULT_HANDLED;
      DBusMessageIter iter, dict;
      dbus_message_iter_init_append(reply, &iter);
      dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "{ss}", &dict);
      // The attributes Core-AAM gives ATK: the element's id, the ARIA role of a landmark, a
      // field's placeholder, a heading's level, a role description, and the toolkit.
      ax_attr(&dict, "toolkit", "Native");
      if (!is_root && !ax_is_document(n)) {
        ax_attr(&dict, "id", n->dom_id);
        ax_attr(&dict, "placeholder-text", n->placeholder);
        ax_attr(&dict, "roledescription", n->role_description);
        if (ax_role_of(n) == AX_ROLE_LANDMARK) ax_attr(&dict, "xml-roles", n->role);
        if (n->level > 0) {
          char level[16];
          snprintf(level, sizeof level, "%d", n->level);
          ax_attr(&dict, "level", level);
        }
      }
      dbus_message_iter_close_container(&iter, &dict);
      ax_send(conn, reply);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetApplication") == 0) {
      ax_send_ref(conn, msg, NULL);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetInterfaces") == 0) {
      const char *names[12];
      int count = ax_interface_names(role, ifaces, names);
      DBusMessage *reply = dbus_message_new_method_return(msg);
      if (reply == NULL) return DBUS_HANDLER_RESULT_HANDLED;
      DBusMessageIter iter, array;
      dbus_message_iter_init_append(reply, &iter);
      dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "s", &array);
      for (int i = 0; i < count; i++) {
        dbus_message_iter_append_basic(&array, DBUS_TYPE_STRING, &names[i]);
      }
      dbus_message_iter_close_container(&iter, &array);
      ax_send(conn, reply);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
  }

  if (strcmp(iface, "org.a11y.atspi.Component") == 0) {
    if (strcmp(member, "GetExtents") == 0 || strcmp(member, "GetPosition") == 0 ||
        strcmp(member, "GetSize") == 0) {
      dbus_uint32_t coord = 0;
      dbus_message_get_args(msg, NULL, DBUS_TYPE_UINT32, &coord, DBUS_TYPE_INVALID);
      double box[4];
      ax_extents(n, coord, box);
      if (strcmp(member, "GetExtents") == 0) {
        ax_send_rect(conn, msg, box);
      } else if (strcmp(member, "GetPosition") == 0) {
        DBusMessage *reply = dbus_message_new_method_return(msg);
        dbus_int32_t x = (dbus_int32_t)lround(box[0]), y = (dbus_int32_t)lround(box[1]);
        if (reply != NULL) {
          dbus_message_append_args(reply, DBUS_TYPE_INT32, &x, DBUS_TYPE_INT32, &y,
                                   DBUS_TYPE_INVALID);
        }
        ax_send(conn, reply);
      } else {
        DBusMessage *reply = dbus_message_new_method_return(msg);
        dbus_int32_t w = (dbus_int32_t)lround(box[2]), h = (dbus_int32_t)lround(box[3]);
        if (reply != NULL) {
          dbus_message_append_args(reply, DBUS_TYPE_INT32, &w, DBUS_TYPE_INT32, &h,
                                   DBUS_TYPE_INVALID);
        }
        ax_send(conn, reply);
      }
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "Contains") == 0 || strcmp(member, "GetAccessibleAtPoint") == 0) {
      dbus_int32_t x = 0, y = 0;
      dbus_uint32_t coord = 0;
      dbus_message_get_args(msg, NULL, DBUS_TYPE_INT32, &x, DBUS_TYPE_INT32, &y,
                            DBUS_TYPE_UINT32, &coord, DBUS_TYPE_INVALID);
      double box[4];
      ax_extents(n, coord, box);
      int inside = x >= box[0] && y >= box[1] && x < box[0] + box[2] && y < box[1] + box[3];
      if (strcmp(member, "Contains") == 0) {
        ax_send_bool(conn, msg, inside);
      } else {
        const AxNode *found = inside && !is_root ? ax_deepest_at(x, y) : NULL;
        if (found == NULL) ax_send_null_ref(conn, msg);
        else ax_send_ref(conn, msg, found);
      }
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetLayer") == 0) {
      ax_send_uint(conn, msg, 3);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetMDIZOrder") == 0) {
      DBusMessage *reply = dbus_message_new_method_return(msg);
      dbus_int16_t order = -1;
      if (reply != NULL) dbus_message_append_args(reply, DBUS_TYPE_INT16, &order, DBUS_TYPE_INVALID);
      ax_send(conn, reply);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GrabFocus") == 0) {
      int ok = !is_root && !ax_is_document(n) && (n->actions & AXA_FOCUS);
      if (ok) ax_action_queue(n, AX_FOCUS);
      ax_send_bool(conn, msg, ok);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "ScrollTo") == 0 || strcmp(member, "ScrollToPoint") == 0) {
      // The page scrolls the element's own box into view, which is what a client asks for either way.
      int ok = !is_root && !ax_is_document(n);
      if (ok) ax_action_queue(n, AX_SCROLL_INTO_VIEW);
      ax_send_bool(conn, msg, ok);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetAlpha") == 0) {
      ax_send_double(conn, msg, 1);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
  }

  if (strcmp(iface, "org.a11y.atspi.Action") == 0) {
    if (strcmp(member, "GetName") == 0 || strcmp(member, "GetLocalizedName") == 0) {
      dbus_int32_t index = -1;
      dbus_message_get_args(msg, NULL, DBUS_TYPE_INT32, &index, DBUS_TYPE_INVALID);
      const char *name = ax_action_name(n, index);
      ax_send_string(conn, msg, name == NULL ? "" : name);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetDescription") == 0) {
      dbus_int32_t index = -1;
      dbus_message_get_args(msg, NULL, DBUS_TYPE_INT32, &index, DBUS_TYPE_INVALID);
      const char *name = ax_action_name(n, index);
      ax_send_string(conn, msg, name == NULL ? "" : ax_action_description(name));
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetKeyBinding") == 0) {
      ax_send_string(conn, msg, "");
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetActions") == 0) {
      DBusMessage *reply = dbus_message_new_method_return(msg);
      if (reply == NULL) return DBUS_HANDLER_RESULT_HANDLED;
      DBusMessageIter iter, array, entry;
      dbus_message_iter_init_append(reply, &iter);
      dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "(sss)", &array);
      for (int i = 0; i < ax_action_count(n); i++) {
        const char *name = ax_action_name(n, i);
        const char *description = ax_action_description(name);
        const char *keys = "";
        dbus_message_iter_open_container(&array, DBUS_TYPE_STRUCT, NULL, &entry);
        dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &name);
        dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &description);
        dbus_message_iter_append_basic(&entry, DBUS_TYPE_STRING, &keys);
        dbus_message_iter_close_container(&array, &entry);
      }
      dbus_message_iter_close_container(&iter, &array);
      ax_send(conn, reply);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "DoAction") == 0) {
      dbus_int32_t index = -1;
      dbus_message_get_args(msg, NULL, DBUS_TYPE_INT32, &index, DBUS_TYPE_INVALID);
      const char *name = ax_action_name(n, index);
      int kind = 0;
      if (name != NULL && strcmp(name, "click") == 0) kind = AX_PRESS;
      else if (name != NULL && strcmp(name, "increment") == 0) kind = AX_INCREMENT;
      else if (name != NULL && strcmp(name, "decrement") == 0) kind = AX_DECREMENT;
      else if (name != NULL && strcmp(name, "showMenu") == 0) kind = AX_SHOW_MENU;
      ax_send_bool(conn, msg, kind != 0 && ax_action_queue(n, kind));
      return DBUS_HANDLER_RESULT_HANDLED;
    }
  }

  if (strcmp(iface, "org.a11y.atspi.EditableText") == 0) {
    int editable = !is_root && !ax_is_document(n) && (ifaces & AX_IF_EDITABLE) &&
      (n->actions & AXA_SET_VALUE);
    const char *field = is_root || ax_is_document(n) ? "" : ax_text(n);
    if (strcmp(member, "SetTextContents") == 0) {
      const char *value = NULL;
      if (!dbus_message_get_args(msg, NULL, DBUS_TYPE_STRING, &value, DBUS_TYPE_INVALID)) value = NULL;
      int ran = editable && value != NULL;
      if (ran) ax_queue(AX_SET_VALUE, n->uid, dup_str(value), 0, 0);
      ax_send_bool(conn, msg, ran);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "InsertText") == 0) {
      dbus_int32_t position = 0, length = 0;
      const char *value = NULL;
      if (!dbus_message_get_args(msg, NULL, DBUS_TYPE_INT32, &position, DBUS_TYPE_STRING, &value,
                                 DBUS_TYPE_INT32, &length, DBUS_TYPE_INVALID)) {
        value = NULL;
      }
      int ran = editable && value != NULL && (n->actions & AXA_INSERT_TEXT);
      if (ran) {
        // The caret goes to the spot first, then the text is inserted there, as typing does.
        int at = ax_unit_offset(field, (size_t)(position < 0 ? 0 : position));
        ax_queue(AX_SELECT_RANGE, n->uid, NULL, at, 0);
        ax_queue(AX_INSERT_TEXT, n->uid, dup_str(value), 0, 0);
      }
      ax_send_bool(conn, msg, ran);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "DeleteText") == 0) {
      dbus_int32_t start = 0, end = 0;
      dbus_message_get_args(msg, NULL, DBUS_TYPE_INT32, &start, DBUS_TYPE_INT32, &end,
                            DBUS_TYPE_INVALID);
      int ran = editable && (n->actions & AXA_INSERT_TEXT);
      if (ran) {
        int at = ax_unit_offset(field, (size_t)(start < 0 ? 0 : start));
        int to = ax_unit_offset(field, (size_t)(end < start ? start : end));
        ax_queue(AX_SELECT_RANGE, n->uid, NULL, at, to - at);
        ax_queue(AX_INSERT_TEXT, n->uid, dup_str(""), 0, 0);
      }
      ax_send_bool(conn, msg, ran);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "CopyText") == 0 || strcmp(member, "CutText") == 0 ||
        strcmp(member, "PasteText") == 0) {
      // The page's own clipboard is a separate surface; a client editing text uses the methods above.
      ax_send_bool(conn, msg, 0);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
  }

  if (strcmp(iface, "org.a11y.atspi.Hyperlink") == 0) {
    if (strcmp(member, "GetURI") == 0) {
      ax_send_string(conn, msg, !is_root && !ax_is_document(n) && n->url != NULL ? n->url : "");
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetObject") == 0) {
      if (is_root || ax_is_document(n)) ax_send_null_ref(conn, msg);
      else ax_send_ref(conn, msg, n);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "IsValid") == 0) {
      ax_send_bool(conn, msg, !is_root && !ax_is_document(n) && n->url != NULL && n->url[0] != '\0');
      return DBUS_HANDLER_RESULT_HANDLED;
    }
  }

  if (strcmp(iface, "org.a11y.atspi.Text") == 0) {
    const char *text = is_root ? "" : ax_text(n);
    int len = (int)strlen(text);
    if (strcmp(member, "GetText") == 0) {
      dbus_int32_t start = 0, end = 0;
      dbus_message_get_args(msg, NULL, DBUS_TYPE_INT32, &start, DBUS_TYPE_INT32, &end,
                            DBUS_TYPE_INVALID);
      char *slice = ax_substr(text, start, end);
      ax_send_string(conn, msg, slice == NULL ? "" : slice);
      free(slice);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetStringAtOffset") == 0 || strcmp(member, "GetTextAtOffset") == 0 ||
        strcmp(member, "GetTextBeforeOffset") == 0 || strcmp(member, "GetTextAfterOffset") == 0) {
      dbus_int32_t offset = 0;
      dbus_uint32_t type = 0;
      dbus_message_get_args(msg, NULL, DBUS_TYPE_INT32, &offset, DBUS_TYPE_UINT32, &type,
                            DBUS_TYPE_INVALID);
      int start = 0, end = 0;
      ax_granularity(text, offset, type, &start, &end);
      if (strcmp(member, "GetTextBeforeOffset") == 0) {
        int s2 = 0, e2 = 0;
        ax_granularity(text, start > 0 ? start - 1 : 0, type, &s2, &e2);
        start = s2;
        end = e2;
      } else if (strcmp(member, "GetTextAfterOffset") == 0) {
        int s2 = 0, e2 = 0;
        ax_granularity(text, end < len ? end + 1 : len, type, &s2, &e2);
        start = s2;
        end = e2;
      }
      ax_send_range(conn, msg, ax_substr(text, start, end), start, end);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetCharacterAtOffset") == 0) {
      dbus_int32_t offset = 0;
      dbus_message_get_args(msg, NULL, DBUS_TYPE_INT32, &offset, DBUS_TYPE_INVALID);
      int32_t cp = -1;
      if (offset >= 0 && offset < len) {
        const unsigned char *p = (const unsigned char *)text + offset;
        if (*p < 0x80) cp = *p;
        else if ((*p >> 5) == 6 && offset + 1 < len) cp = ((p[0] & 0x1f) << 6) | (p[1] & 0x3f);
        else if ((*p >> 4) == 14 && offset + 2 < len) {
          cp = ((p[0] & 0x0f) << 12) | ((p[1] & 0x3f) << 6) | (p[2] & 0x3f);
        } else if ((*p >> 3) == 30 && offset + 3 < len) {
          cp = ((p[0] & 0x07) << 18) | ((p[1] & 0x3f) << 12) | ((p[2] & 0x3f) << 6) | (p[3] & 0x3f);
        }
      }
      ax_send_int(conn, msg, cp);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetAttributeValue") == 0) {
      ax_send_string(conn, msg, "");
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetAttributes") == 0) {
      DBusMessage *reply = dbus_message_new_method_return(msg);
      if (reply == NULL) return DBUS_HANDLER_RESULT_HANDLED;
      DBusMessageIter iter, dict;
      dbus_int32_t start = 0, end = len;
      dbus_message_iter_init_append(reply, &iter);
      dbus_message_iter_open_container(&iter, DBUS_TYPE_ARRAY, "{ss}", &dict);
      dbus_message_iter_close_container(&iter, &dict);
      dbus_message_iter_append_basic(&iter, DBUS_TYPE_INT32, &start);
      dbus_message_iter_append_basic(&iter, DBUS_TYPE_INT32, &end);
      ax_send(conn, reply);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetDefaultAttributes") == 0) {
      ax_send_empty_array(conn, msg, "{ss}");
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetCharacterExtents") == 0 || strcmp(member, "GetRangeExtents") == 0) {
      // The runtime lays out text runs rather than single characters, so a character answers with
      // the frame of the object it sits in.
      double box[4];
      ax_extents(n, 0, box);
      ax_send_four(conn, msg, box);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetOffsetAtPoint") == 0) {
      ax_send_int(conn, msg, -1);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetNSelections") == 0) {
      int selections = (!is_root && n->sel_start >= 0) ? 1 : 0;
      ax_send_int(conn, msg, selections);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetSelection") == 0) {
      if (is_root || n->sel_start < 0) {
        DBusMessage *reply = dbus_message_new_method_return(msg);
        dbus_int32_t start = 0, end = 0;
        if (reply != NULL) {
          dbus_message_append_args(reply, DBUS_TYPE_INT32, &start, DBUS_TYPE_INT32, &end,
                                   DBUS_TYPE_INVALID);
        }
        ax_send(conn, reply);
        return DBUS_HANDLER_RESULT_HANDLED;
      }
      dbus_int32_t start = (dbus_int32_t)ax_byte_offset(text, n->sel_start);
      dbus_int32_t end = (dbus_int32_t)ax_byte_offset(text, n->sel_end > n->sel_start ? n->sel_end : n->sel_start);
      DBusMessage *reply = dbus_message_new_method_return(msg);
      if (reply != NULL) {
        dbus_message_append_args(reply, DBUS_TYPE_INT32, &start, DBUS_TYPE_INT32, &end,
                                 DBUS_TYPE_INVALID);
      }
      ax_send(conn, reply);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "SetCaretOffset") == 0 || strcmp(member, "SetSelection") == 0) {
      dbus_int32_t offset = 0, end = 0;
      if (strcmp(member, "SetSelection") == 0) {
        dbus_int32_t selection = 0;
        dbus_message_get_args(msg, NULL, DBUS_TYPE_INT32, &selection, DBUS_TYPE_INT32, &offset,
                              DBUS_TYPE_INT32, &end, DBUS_TYPE_INVALID);
      } else {
        dbus_message_get_args(msg, NULL, DBUS_TYPE_INT32, &offset, DBUS_TYPE_INVALID);
        end = offset;
      }
      // The range goes to the runtime as a selection, which focuses the field and sets the range
      // on the element, as a client's caret move does.
      if (!is_root && !ax_is_document(n)) {
        int start = ax_unit_offset(text, (size_t)(offset < 0 ? 0 : offset));
        int finish = ax_unit_offset(text, (size_t)(end < offset ? offset : end));
        ax_queue(AX_SELECT_RANGE, n->uid, NULL, start, finish - start);
      }
      ax_send_bool(conn, msg, !is_root && !ax_is_document(n));
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "AddSelection") == 0 || strcmp(member, "RemoveSelection") == 0) {
      ax_send_bool(conn, msg, 0);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
  }

  if (strcmp(iface, "org.a11y.atspi.Value") == 0) {
    int none = is_root || ax_is_document(n);
    double real = none ? 0 : (n->has_now ? n->range_now : strtod(n->value != NULL ? n->value : "", NULL));
    if (strcmp(member, "GetCurrentValue") == 0) {
      ax_send_double(conn, msg, real);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetMinimumValue") == 0) {
      ax_send_double(conn, msg, none ? 0 : (n->has_min ? n->range_min : 0));
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetMaximumValue") == 0) {
      ax_send_double(conn, msg, none ? 0 : (n->has_max ? n->range_max : 100));
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetMinimumIncrement") == 0) {
      ax_send_double(conn, msg, 1);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "SetCurrentValue") == 0) {
      double value = 0;
      dbus_message_get_args(msg, NULL, DBUS_TYPE_DOUBLE, &value, DBUS_TYPE_INVALID);
      int ran = 0;
      if (!is_root && !ax_is_document(n) && (n->actions & AXA_SET_VALUE)) {
        char text[64];
        snprintf(text, sizeof text, "%.17g", value);
        ax_queue(AX_SET_VALUE, n->uid, dup_str(text), 0, 0);
        ran = 1;
      }
      ax_send_bool(conn, msg, ran);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
  }

  if (strcmp(iface, "org.a11y.atspi.Selection") == 0) {
    int children = is_root ? 0 : ax_child_count(n);
    if (strcmp(member, "GetNSelectedChildren") == 0) {
      int selected = 0;
      for (int i = 0; i < children; i++) {
        AxNode *child = ax_child(n, i);
        if (child != NULL && ax_is_selected(child)) selected++;
      }
      ax_send_int(conn, msg, selected);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetSelectedChild") == 0) {
      dbus_int32_t index = 0;
      dbus_message_get_args(msg, NULL, DBUS_TYPE_INT32, &index, DBUS_TYPE_INVALID);
      AxNode *found = NULL;
      int seen = 0;
      for (int i = 0; i < children && found == NULL; i++) {
        AxNode *child = ax_child(n, i);
        if (child == NULL || !ax_is_selected(child)) continue;
        if (seen++ == index) found = child;
      }
      if (found == NULL) ax_send_null_ref(conn, msg);
      else ax_send_ref(conn, msg, found);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "IsChildSelected") == 0) {
      dbus_int32_t index = 0;
      dbus_message_get_args(msg, NULL, DBUS_TYPE_INT32, &index, DBUS_TYPE_INVALID);
      AxNode *child = index >= 0 && index < children ? ax_child(n, index) : NULL;
      ax_send_bool(conn, msg, child != NULL && ax_is_selected(child));
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "SelectChild") == 0 || strcmp(member, "DeselectChild") == 0) {
      // Choosing a child is the click a user's pick sends.
      dbus_int32_t index = 0;
      dbus_message_get_args(msg, NULL, DBUS_TYPE_INT32, &index, DBUS_TYPE_INVALID);
      AxNode *child = index >= 0 && index < children ? ax_child(n, index) : NULL;
      int ok = child != NULL && ax_selectable(child) && ax_action_queue(child, AX_PRESS);
      ax_send_bool(conn, msg, ok);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "SelectAll") == 0 || strcmp(member, "ClearSelection") == 0 ||
        strcmp(member, "DeselectSelectedChild") == 0) {
      ax_send_bool(conn, msg, 0);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
  }

  if (strcmp(iface, "org.a11y.atspi.Table") == 0) {
    if (strcmp(member, "GetAccessibleAt") == 0) {
      dbus_int32_t row = 0, column = 0;
      dbus_message_get_args(msg, NULL, DBUS_TYPE_INT32, &row, DBUS_TYPE_INT32, &column,
                            DBUS_TYPE_INVALID);
      AxNode *cell = is_root ? NULL : ax_cell_at(n, row, column);
      if (cell == NULL) ax_send_null_ref(conn, msg);
      else ax_send_ref(conn, msg, cell);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetIndexAt") == 0) {
      dbus_int32_t row = 0, column = 0;
      dbus_message_get_args(msg, NULL, DBUS_TYPE_INT32, &row, DBUS_TYPE_INT32, &column,
                            DBUS_TYPE_INVALID);
      int columns = is_root ? 0 : ax_column_count(n);
      ax_send_int(conn, msg, columns > 0 ? row * columns + column : 0);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetRowAtIndex") == 0 || strcmp(member, "GetColumnAtIndex") == 0) {
      dbus_int32_t index = 0;
      dbus_message_get_args(msg, NULL, DBUS_TYPE_INT32, &index, DBUS_TYPE_INVALID);
      int columns = is_root ? 0 : ax_column_count(n);
      if (columns <= 0) index = 0;
      int32_t value = columns <= 0 ? 0 : (strcmp(member, "GetRowAtIndex") == 0 ? index / columns
                                                                              : index % columns);
      ax_send_int(conn, msg, value);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetRowExtentAt") == 0 || strcmp(member, "GetColumnExtentAt") == 0) {
      ax_send_int(conn, msg, 1);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetRowDescription") == 0 || strcmp(member, "GetColumnDescription") == 0) {
      ax_send_string(conn, msg, "");
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetRowHeader") == 0 || strcmp(member, "GetColumnHeader") == 0 ||
        strcmp(member, "GetCaption") == 0 || strcmp(member, "GetSummary") == 0) {
      ax_send_null_ref(conn, msg);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetSelectedRows") == 0 || strcmp(member, "GetSelectedColumns") == 0) {
      ax_send_empty_array(conn, msg, "i");
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "IsRowSelected") == 0 || strcmp(member, "IsColumnSelected") == 0 ||
        strcmp(member, "IsSelected") == 0) {
      ax_send_bool(conn, msg, 0);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetNRows") == 0) {
      ax_send_int(conn, msg, is_root ? 0 : ax_row_count(n));
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetNColumns") == 0) {
      ax_send_int(conn, msg, is_root ? 0 : ax_column_count(n));
      return DBUS_HANDLER_RESULT_HANDLED;
    }
  }

  if (strcmp(iface, "org.a11y.atspi.TableCell") == 0) {
    if (strcmp(member, "GetRowColumnSpan") == 0 || strcmp(member, "GetRowSpan") == 0 ||
        strcmp(member, "GetColumnSpan") == 0) {
      int row = 0, column = 0;
      ax_cell_table(is_root ? NULL : n, &row, &column);
      DBusMessage *reply = dbus_message_new_method_return(msg);
      if (reply == NULL) return DBUS_HANDLER_RESULT_HANDLED;
      DBusMessageIter iter;
      dbus_message_iter_init_append(reply, &iter);
      if (strcmp(member, "GetRowColumnSpan") == 0) {
        // Four numbers, not the leading boolean the interface file still lists: that is what the
        // adaptors send and what at-spi's clients read.
        dbus_int32_t r = row, c = column, row_span = 1, col_span = 1;
        dbus_message_iter_append_basic(&iter, DBUS_TYPE_INT32, &r);
        dbus_message_iter_append_basic(&iter, DBUS_TYPE_INT32, &c);
        dbus_message_iter_append_basic(&iter, DBUS_TYPE_INT32, &row_span);
        dbus_message_iter_append_basic(&iter, DBUS_TYPE_INT32, &col_span);
      } else {
        dbus_int32_t span = 1;
        dbus_message_iter_append_basic(&iter, DBUS_TYPE_INT32, &span);
      }
      ax_send(conn, reply);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetColumnHeaderCells") == 0 || strcmp(member, "GetRowHeaderCells") == 0) {
      ax_send_empty_array(conn, msg, "(so)");
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetTable") == 0) {
      int row = 0, column = 0;
      AxNode *table = ax_cell_table(is_root ? NULL : n, &row, &column);
      if (table == NULL) ax_send_null_ref(conn, msg);
      else ax_send_ref(conn, msg, table);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
  }

  if (strcmp(iface, "org.a11y.atspi.Application") == 0) {
    if (strcmp(member, "GetLocale") == 0) {
      dbus_uint32_t type = 0;
      dbus_message_get_args(msg, NULL, DBUS_TYPE_UINT32, &type, DBUS_TYPE_INVALID);
      (void)type;
      ax_send_string(conn, msg, ax_locale());
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "GetApplicationBusAddress") == 0) {
      ax_send_string(conn, msg, "");
      return DBUS_HANDLER_RESULT_HANDLED;
    }
  }

  if (strcmp(iface, "org.a11y.atspi.Socket") == 0) {
    if (strcmp(member, "Embed") == 0) {
      ax_send_ref(conn, msg, NULL);
      return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (strcmp(member, "Embedded") == 0 || strcmp(member, "Unembed") == 0) {
      ax_send(conn, dbus_message_new_method_return(msg));
      return DBUS_HANDLER_RESULT_HANDLED;
    }
  }

  ax_send_error(conn, msg, "The object doesn't answer that call");
  return DBUS_HANDLER_RESULT_HANDLED;
}

// --- Reporting what changed ---------------------------------------------------

/** A fingerprint of an object's children, by uid, so a change in the set is noticed. */
static int ax_children_signature(const AxNode *n, const AxNode *nodes, int count) {
  int parent = n == NULL ? 0 : n->id;
  unsigned hash = 2166136261u;
  int kids = 0;
  for (int i = 0; i < count; i++) {
    if (nodes[i].parent != parent) continue;
    kids++;
    hash = (hash ^ (unsigned)nodes[i].uid) * 16777619u;
  }
  return (int)((hash ^ (unsigned)kids) & 0x7fffffff);
}

/** The node in a list with a uid: the element a reference names, across a changed tree. */
static const AxNode *ax_find_uid(const AxNode *nodes, int count, int uid) {
  for (int i = 0; i < count; i++) {
    if (nodes[i].uid == uid) return &nodes[i];
  }
  return NULL;
}

static int ax_child_count_in(const AxNode *nodes, int count, int parent) {
  int kids = 0;
  for (int i = 0; i < count; i++) {
    if (nodes[i].parent == parent) kids++;
  }
  return kids;
}

static const AxNode *ax_find_in(const AxNode *nodes, int count, int id) {
  for (int i = 0; i < count; i++) {
    if (nodes[i].id == id) return &nodes[i];
  }
  return NULL;
}

/** Emits the cache's AddAccessible for an object that appeared. */
static void ax_cache_added(const AxNode *n) {
  if (g_ax_bus == NULL) return;
  DBusMessage *sig = dbus_message_new_signal(AX_CACHE, "org.a11y.atspi.Cache", "AddAccessible");
  if (sig == NULL) return;
  DBusMessageIter iter, entry;
  dbus_message_iter_init_append(sig, &iter);
  dbus_message_iter_open_container(&iter, DBUS_TYPE_STRUCT, NULL, &entry);
  ax_append_cache_fields(&entry, n);
  dbus_message_iter_close_container(&iter, &entry);
  dbus_connection_send(g_ax_bus, sig, NULL);
  dbus_message_unref(sig);
}

/** Emits the cache's RemoveAccessible for an object that went away. */
static void ax_cache_removed(const AxNode *n) {
  if (g_ax_bus == NULL) return;
  DBusMessage *sig = dbus_message_new_signal(AX_CACHE, "org.a11y.atspi.Cache", "RemoveAccessible");
  if (sig == NULL) return;
  DBusMessageIter iter;
  dbus_message_iter_init_append(sig, &iter);
  ax_append_ref(&iter, n);
  dbus_connection_send(g_ax_bus, sig, NULL);
  dbus_message_unref(sig);
}

/** Ids whose value the runtime reported as moved since the last tree. */
static int32_t g_ax_value_pending[128];
static int g_ax_value_pending_count = 0;

/** Tells clients what the new tree changed: objects that came or went, children, focus, states
 *  and values. */
static void ax_report(const AxNode *old_nodes, int old_count) {
  if (g_ax_bus == NULL) return;
  if (old_nodes != NULL) {
    // Objects that went first, then the ones that came, so a path a uid now names is the new
    // object and not a stale removal, then the objects a client's child lists name.
    for (int i = 0; i < old_count; i++) {
      if (ax_find_uid(g_ax_nodes, g_ax_node_count, old_nodes[i].uid) == NULL) ax_cache_removed(&old_nodes[i]);
    }
    for (int i = 0; i < g_ax_node_count; i++) {
      if (ax_find_uid(old_nodes, old_count, g_ax_nodes[i].uid) == NULL) ax_cache_added(&g_ax_nodes[i]);
    }
    // The document's children, and every object's whose own children changed. The tree is
    // republished as a whole, so an index is worth less than the uids the children keep: the event
    // carries a position no list has (-1), which a client takes as "ask again".
    if (ax_children_signature(NULL, g_ax_nodes, g_ax_node_count) !=
        ax_children_signature(NULL, old_nodes, old_count)) {
      ax_node_event(&g_ax_document, "ChildrenChanged", "add", -1, 0, AX_EV_REF, NULL, 0,
                    ax_child(&g_ax_document, 0));
    }
    for (int i = 0; i < g_ax_node_count; i++) {
      AxNode *n = &g_ax_nodes[i];
      const AxNode *was = ax_find_uid(old_nodes, old_count, n->uid);
      if (was == NULL) continue;
      int children = ax_child_count(n);
      int before = ax_child_count_in(old_nodes, old_count, was->id);
      if (children == before &&
          ax_children_signature(n, g_ax_nodes, g_ax_node_count) ==
            ax_children_signature(was, old_nodes, old_count)) {
        continue;
      }
      ax_node_event(n, "ChildrenChanged", "add", -1, 0, AX_EV_REF, NULL, 0,
                    children > 0 ? ax_child(n, 0) : n);
    }
  }
  for (int i = 0; i < g_ax_node_count; i++) {
    const AxNode *n = &g_ax_nodes[i];
    const AxNode *was = old_nodes == NULL ? NULL : ax_find_uid(old_nodes, old_count, n->uid);
    int was_focused = was != NULL && was->focused;
    if (n->focused != was_focused) ax_state_changed(n, "focused", n->focused);
    if (was == NULL) continue;
    if (ax_toggles(n) && (ax_toggle_on(was) != ax_toggle_on(n) || was->mixed != n->mixed)) {
      ax_state_changed(n, "checked", ax_toggle_on(n));
    }
    if (n->pressed >= 0 && was->pressed != n->pressed) ax_state_changed(n, "pressed", n->pressed == 1);
    if (ax_expands(n) && was->expanded != n->expanded) {
      ax_state_changed(n, "expanded", n->expanded == 1);
    }
    if (ax_selectable(n) && ax_is_selected(was) != ax_is_selected(n)) {
      ax_state_changed(n, "selected", ax_is_selected(n));
    }
    if (was->disabled != n->disabled) {
      ax_state_changed(n, "enabled", !n->disabled);
      ax_state_changed(n, "sensitive", !n->disabled);
    }
    if (strcmp(was->label, n->label) != 0 && n->label[0] != '\0') {
      ax_node_event(n, "PropertyChange", "accessible-name", 0, 0, AX_EV_STRING, n->label, 0, NULL);
    }
    if (strcmp(was->value, n->value) != 0) {
      if (ax_is_field(n)) {
        ax_node_event(n, "TextChanged", "system", 0, (int)strlen(n->value), AX_EV_STRING, n->value,
                      0, NULL);
      } else {
        double now = n->has_now ? n->range_now : strtod(n->value != NULL ? n->value : "", NULL);
        ax_node_event(n, "PropertyChange", "accessible-value", 0, 0, AX_EV_DOUBLE, NULL, now, NULL);
      }
    }
    if (ax_is_field(n) && was->sel_start != n->sel_start) {
      ax_node_event(n, "TextCaretMoved", "", ax_caret(n), 0, AX_EV_INT, NULL, 0, NULL);
    }
  }
  for (int i = 0; i < g_ax_value_pending_count; i++) {
    const AxNode *n = ax_find_in(g_ax_nodes, g_ax_node_count, g_ax_value_pending[i]);
    if (n == NULL || (ax_ifaces(n) & AX_IF_TEXT)) continue;
    // A field's or a control's new value is already told by the comparison above.
    const AxNode *was = old_nodes == NULL ? NULL : ax_find_in(old_nodes, old_count, n->id);
    if (was != NULL && strcmp(was->value, n->value) != 0) continue;
    ax_node_event(n, "PropertyChange", "accessible-value", 0, 0, AX_EV_DOUBLE, NULL, n->range_now,
                  NULL);
  }
  g_ax_value_pending_count = 0;
}

/** The value a dump shows: a check box's state, as macOS reports it too, or the node's value. */
static const char *ax_shown_value(const AxNode *n) {
  uint32_t role = ax_role_of(n);
  if (role == 7 || role == 44 || role == 130) return n->checked == 1 ? "1" : "0";
  return n->value;
}

/** Prints the tree the way an assistive client sees it, for a test without the bus. */
static void ax_dump_children(int parent, int depth) {
  if (depth > 100) return;
  for (int i = 0; i < g_ax_node_count; i++) {
    AxNode *n = &g_ax_nodes[i];
    if (n->parent != parent) continue;
    char pad[208];
    int length = depth * 2;
    if (length > 200) length = 200;
    memset(pad, ' ', (size_t)length);
    pad[length] = '\0';
    // A field's caret, selection and line, as a screen reader's text navigation reads them.
    uint32_t role = ax_role_of(n);
    char selection[64] = "";
    if (role == AX_ROLE_ENTRY || role == 61 || role == 52) {
      int length = n->sel_end > n->sel_start ? n->sel_end - n->sel_start : 0;
      snprintf(selection, sizeof selection, " sel=%d,%d line=%d", n->sel_start < 0 ? 0 : n->sel_start,
               length, n->sel_line < 0 ? 0 : n->sel_line);
    }
    printf("%s%s %d,%d %dx%d label=[%s] value=[%s]%s%s\n", pad, ax_role_name(role),
           (int)lround(n->x), (int)lround(n->y), (int)lround(n->w), (int)lround(n->h),
           n->label == NULL ? "" : n->label,
           n->value == NULL ? "" : ax_shown_value(n), selection, n->focused ? " focused" : "");
    ax_dump_children(n->id, depth + 1);
  }
}

// --- The host's accessibility entry points ------------------------------------

/** This host's focus and text-range requests go to the runtime as EV_AXACTION; the older events
 *  carry nothing here. */
int32_t host_ax_focus(void) { return 0; }
int32_t host_ax_selection(void) { return 0; }

/** Whether a run prints the tree it publishes, which builds it with no client asking. */
static int ax_dump_on(void) {
  static int on = -1;
  if (on < 0) on = getenv("NATIVE_AX_DUMP") != NULL;
  return on;
}

/** Whether a client has asked for the tree (or a run prints every one). */
int32_t host_ax_active(void) { return g_ax_active || ax_dump_on() ? 1 : 0; }
/** The action EV_AXACTION carries: its kind, its node's uid, and its text. */
int32_t host_ax_action(void) { return g_ax_action.kind; }
int32_t host_ax_action_target(void) { return g_ax_action.uid; }
void host_ax_action_text(window_text_cb cb) {
  const char *t = g_ax_action.text ? g_ax_action.text : "";
  cb((const uint8_t *)t, strlen(t));
}

void host_ax_announce(const uint8_t *text, size_t n, int32_t priority) {
  char *spoken = (char *)malloc(n + 1);
  if (spoken == NULL) return;
  memcpy(spoken, text, n);
  spoken[n] = '\0';
  if (getenv("NATIVE_AX_DUMP") != NULL) {
    fprintf(stdout, "AX ANNOUNCE %d [%s]\n", priority, spoken);
    fflush(stdout);
  }
  if (g_ax_bus != NULL && spoken[0] != '\0') {
    ax_event(AX_ROOT, "Announcement", "", priority == 1 ? 2 : 1, 0, AX_EV_STRING, spoken, 0, NULL);
  }
  free(spoken);
}

void host_ax_value_changed(int32_t id) {
  if (id <= 0) return;
  if (g_ax_value_pending_count < (int)(sizeof g_ax_value_pending / sizeof g_ax_value_pending[0])) {
    g_ax_value_pending[g_ax_value_pending_count++] = id;
  }
  if (getenv("NATIVE_AX_DUMP") != NULL) {
    fprintf(stdout, "AX VALUE %d\n", id);
    fflush(stdout);
  }
}

/** Republishes the page's accessibility tree: on the bus when there is one, and in a dump when a
 *  test asked for it. */
void host_ax_tree(const uint8_t *json, size_t n) {
  char *text = (char *)malloc(n + 1);
  if (text == NULL) return;
  if (n > 0) memcpy(text, json, n);
  text[n] = '\0';
  AxNode *next = NULL;
  int next_count = 0;
  int parsed = ax_parse(text, &next, &next_count);
  free(text);
  if (!parsed) {
    ax_free_tree(next, next_count);
    return;
  }
  AxNode *old = g_ax_nodes;
  int old_count = g_ax_node_count;
  g_ax_nodes = next;
  g_ax_node_count = next_count;
  ax_keep_bus();
  ax_connect();
  int first_tree = !g_ax_has_tree;
  g_ax_has_tree = 1;
  ax_report(old, old_count);
  if (first_tree) {
    // A client that asked before the page was built hears the document arrive, and walks again.
    ax_event(AX_ROOT, "ChildrenChanged", "add", 0, 0, AX_EV_REF, NULL, 0, &g_ax_document);
  }
  ax_free_tree(old, old_count);
  // A page that renamed itself renames the application a screen reader announces.
  if (g_ax_bus != NULL && strcmp(g_ax_published_title, g_ax_title) != 0) {
    snprintf(g_ax_published_title, sizeof g_ax_published_title, "%s", g_ax_title);
    ax_event(AX_ROOT, "PropertyChange", "accessible-name", 0, 0, AX_EV_STRING, g_ax_title, 0, NULL);
  }
  if (getenv("NATIVE_AX_DUMP") != NULL) {
    fprintf(stdout, "AX TREE\n");
    ax_dump_children(0, 0);
    fprintf(stdout, "AX END\n");
    fflush(stdout);
  }
}

// Line break opportunities come from the system's ICU — the same UAX #14 implementation a
// browser uses — so a run breaks where Chrome's does. The locale carries the line-break value as
// ICU's `lb` keyword (strict, normal, loose); the positions are registered once per run of text,
// language and value, and read back by index, which keeps the FFI to plain numbers. ICU is
// opened by name rather than linked, so a system without it only loses the extra opportunities.
typedef uint16_t UChar;
typedef struct UBreakIterator UBreakIterator;

static UBreakIterator *(*p_ubrk_open)(int32_t, const char *, const UChar *, int32_t, int32_t *);
static int32_t (*p_u_getIntPropertyValue)(int32_t, int32_t);
static int32_t (*p_ubrk_first)(UBreakIterator *);
static int32_t (*p_ubrk_next)(UBreakIterator *);
static void (*p_ubrk_close)(UBreakIterator *);

/** A symbol from ICU, whose entry points carry the library's version as a suffix on Linux
 *  (ubrk_open_78); the plain name is there when the build exports it unversioned. */
static void *icu_symbol(void *lib, const char *stem) {
  char name[48];
  for (int v = 79; v >= 60; v--) {
    snprintf(name, sizeof(name), "%s_%d", stem, v);
    void *p = dlsym(lib, name);
    if (p != NULL) return p;
  }
  return dlsym(lib, stem);
}

static int load_icu(void) {
  static int state = 0;  // 0 unknown, 1 loaded, 2 missing
  if (state == 0) {
    // The unversioned name is there with the development package; the others are the sonames of
    // the runtime packages, newest first.
    static const char *names[] = {
      "libicuuc.so", "libicuuc.so.79", "libicuuc.so.78", "libicuuc.so.77", "libicuuc.so.76",
      "libicuuc.so.75", "libicuuc.so.74", "libicuuc.so.73", "libicuuc.so.72", "libicuuc.so.71",
      "libicuuc.so.70", "libicuuc.so.69", "libicuuc.so.68", "libicuuc.so.67", "libicuuc.so.66",
      NULL,
    };
    void *lib = NULL;
    for (int i = 0; names[i] != NULL && lib == NULL; i++) lib = dlopen(names[i], RTLD_LAZY);
    if (lib != NULL) {
      p_ubrk_open = icu_symbol(lib, "ubrk_open");
      p_ubrk_first = icu_symbol(lib, "ubrk_first");
      p_ubrk_next = icu_symbol(lib, "ubrk_next");
      p_ubrk_close = icu_symbol(lib, "ubrk_close");
      p_u_getIntPropertyValue = icu_symbol(lib, "u_getIntPropertyValue");
    }
    state = (p_ubrk_open && p_ubrk_first && p_ubrk_next && p_ubrk_close) ? 1 : 2;
  }
  return state == 1;
}

/** The text as the UTF-16 code units ICU (and a browser's line breaking) measures in. */
static UChar *utf8_to_utf16(const uint8_t *s, size_t n, int32_t *out_len) {
  UChar *out = (UChar *)malloc(sizeof(UChar) * (n > 0 ? n : 1));
  if (out == NULL) return NULL;
  int32_t k = 0;
  for (size_t i = 0; i < n;) {
    uint32_t c = s[i++];
    if (c >= 0xF0 && i + 2 < n) {
      c = ((c & 0x07u) << 18) | ((uint32_t)(s[i] & 0x3Fu) << 12) | ((uint32_t)(s[i + 1] & 0x3Fu) << 6) |
        (uint32_t)(s[i + 2] & 0x3Fu);
      i += 3;
    } else if (c >= 0xE0 && i + 1 < n) {
      c = ((c & 0x0Fu) << 12) | ((uint32_t)(s[i] & 0x3Fu) << 6) | (uint32_t)(s[i + 1] & 0x3Fu);
      i += 2;
    } else if (c >= 0xC0 && i < n) {
      c = ((c & 0x1Fu) << 6) | (uint32_t)(s[i] & 0x3Fu);
      i += 1;
    }
    if (c > 0xFFFF) {
      c -= 0x10000;
      out[k++] = (UChar)(0xD800 + (c >> 10));
      out[k++] = (UChar)(0xDC00 + (c & 0x3FF));
    } else {
      out[k++] = (UChar)c;
    }
  }
  *out_len = k;
  return out;
}

/** The prefix characters CSS keeps off the start of a line (UAX #14 class PR). */
static int css_prefix_char(uint32_t c) {
  return c == 0x00B1 || c == 0x20AC || c == 0x2116 || c == 0xFE69 || c == 0xFF04 || c == 0xFFE1 ||
    c == 0xFFE5 || c == 0xFFE6;
}

/** Whether the text is in a language whose typography the line-break values tailor: the prefix
 *  rule is CJK's, and a German or unknown-language run keeps the default UAX #14 behavior. */
static int css_cjk_locale(const char *lang, size_t len) {
  if (len < 2) return 0;
  char a = (char)tolower((unsigned char)lang[0]);
  char b = (char)tolower((unsigned char)lang[1]);
  return (a == 'j' && b == 'a') || (a == 'z' && b == 'h') || (a == 'k' && b == 'o');
}

static int css_inseparable_char(uint32_t c) {
  return c == 0x2024 || c == 0x2025 || c == 0x2026 || c == 0x22EF || c == 0xFE19;
}

/** One run's break positions, kept until the next document. */
typedef struct {
  int32_t lb;
  char *lang;
  UChar *text;
  int32_t len;
  int32_t *offs;
  int32_t count;
} LineBreakList;

static LineBreakList *g_line_breaks = NULL;
static int32_t g_line_break_count = 0;
static int32_t g_line_break_cap = 0;

static void clear_line_breaks(void) {
  for (int32_t i = 0; i < g_line_break_count; i++) {
    free(g_line_breaks[i].lang);
    free(g_line_breaks[i].text);
    free(g_line_breaks[i].offs);
  }
  free(g_line_breaks);
  g_line_breaks = NULL;
  g_line_break_count = 0;
  g_line_break_cap = 0;
}

static void sort_offsets(int32_t *offs, int32_t n) {
  for (int32_t i = 1; i < n; i++) {
    int32_t v = offs[i];
    int32_t j = i - 1;
    while (j >= 0 && offs[j] > v) {
      offs[j + 1] = offs[j];
      j--;
    }
    offs[j + 1] = v;
  }
}

int32_t host_register_line_breaks(const uint8_t *text, size_t n, const uint8_t *lang, size_t lang_len,
                                  int32_t lb) {
  // A run that is only letters, digits and spaces breaks where the space handling breaks it, and
  // a huge one would only fill the cache.
  if (n == 0 || n > 8192 || !load_icu()) return 0;
  int32_t len = 0;
  UChar *buf = utf8_to_utf16(text, n, &len);
  if (buf == NULL) return 0;
  for (int32_t i = 0; i < g_line_break_count; i++) {
    LineBreakList *l = &g_line_breaks[i];
    if (l->lb == lb && l->len == len && l->lang != NULL && strlen(l->lang) == lang_len &&
      memcmp(l->lang, lang, lang_len) == 0 && memcmp(l->text, buf, sizeof(UChar) * (size_t)len) == 0) {
      free(buf);
      return i + 1;
    }
  }
  char locale[160];
  int base_len = lang_len > 0 ? (int)lang_len : 2;
  const char *base = lang_len > 0 ? (const char *)lang : "en";
  const char *kw = lb == 3 ? "@lb=strict" : lb == 2 ? "@lb=normal" : lb == 1 ? "@lb=loose" : "";
  if (base_len > 120) base_len = 120;
  snprintf(locale, sizeof(locale), "%.*s%s", base_len, base, kw);
  int32_t status = 0;
  UBreakIterator *bi = p_ubrk_open(2 /* UBRK_LINE */, locale, buf, len, &status);
  if (bi == NULL) {
    free(buf);
    return 0;
  }
  int32_t cap = 8, count = 0;
  int32_t *offs = (int32_t *)malloc(sizeof(int32_t) * (size_t)cap);
  if (offs == NULL) {
    p_ubrk_close(bi);
    free(buf);
    return 0;
  }
  for (int32_t p = p_ubrk_first(bi); p != -1 /* UBRK_DONE */; p = p_ubrk_next(bi)) {
    if (p <= 0 || p >= len) continue;
    if (count == cap) {
      int32_t *grown = (int32_t *)realloc(offs, sizeof(int32_t) * (size_t)(cap * 2));
      if (grown == NULL) break;
      offs = grown;
      cap *= 2;
    }
    offs[count++] = p;
  }
  p_ubrk_close(bi);
  // CSS's line-break values go past UAX #14 in two places a browser settles itself: a prefix
  // character (PR: ± € № ﹩ ＄ ￡ ￥ ￦) does not start a line under `strict` or `normal`, and an
  // inseparable character (IN: … ‥ ⋯ ︙) may under `loose`.
  if ((lb == 2 || lb == 3) && css_cjk_locale(base, (size_t)base_len)) {
    int32_t kept = 0;
    for (int32_t i = 0; i < count; i++) {
      int32_t at = offs[i];
      uint32_t c = at < len ? buf[at] : 0;
      if (!css_prefix_char(c)) offs[kept++] = offs[i];
    }
    count = kept;
  } else if (lb == 1) {
    for (int32_t i = 1; i < len; i++) {
      if (!css_inseparable_char(buf[i])) continue;
      int seen = 0;
      for (int32_t k = 0; k < count; k++) if (offs[k] == i) { seen = 1; break; }
      if (seen) continue;
      if (count == cap) {
        int32_t *grown = (int32_t *)realloc(offs, sizeof(int32_t) * (size_t)(cap * 2));
        if (grown == NULL) break;
        offs = grown;
        cap *= 2;
      }
      offs[count++] = i;
    }
    sort_offsets(offs, count);
  }
  if (g_line_break_count == g_line_break_cap) {
    int32_t next = g_line_break_cap == 0 ? 8 : g_line_break_cap * 2;
    LineBreakList *grown = (LineBreakList *)realloc(g_line_breaks, sizeof(LineBreakList) * (size_t)next);
    if (grown == NULL) {
      free(offs);
      free(buf);
      return 0;
    }
    g_line_breaks = grown;
    g_line_break_cap = next;
  }
  LineBreakList *entry = &g_line_breaks[g_line_break_count];
  entry->lb = lb;
  entry->lang = (char *)malloc(lang_len + 1);
  if (entry->lang == NULL) {
    free(offs);
    free(buf);
    return 0;
  }
  if (lang_len > 0) memcpy(entry->lang, lang, lang_len);
  entry->lang[lang_len] = '\0';
  entry->text = buf;
  entry->len = len;
  entry->offs = offs;
  entry->count = count;
  g_line_break_count++;
  return g_line_break_count;
}

int32_t host_line_break_count(int32_t id) {
  if (id <= 0 || id > g_line_break_count) return 0;
  return g_line_breaks[id - 1].count;
}

int32_t host_line_break_at(int32_t id, int32_t i) {
  if (id <= 0 || id > g_line_break_count) return -1;
  LineBreakList *l = &g_line_breaks[id - 1];
  if (i < 0 || i >= l->count) return -1;
  return l->offs[i];
}

/**
 * Whether a soft wrap opportunity next to an atomic inline is suppressed by the character on the
 * other side. CSS adds the opportunity itself, past what UAX #14 would give (a no-break space, a
 * colon or other punctuation still lets the atomic box wrap), except for the characters whose own
 * line-break class glues them to what follows or precedes: GL, CM, WJ and ZWJ. U+00A0 is the one
 * glue that leaves the opportunity in place, as CSS Text asks.
 */
int32_t host_atomic_break_forbidden(int32_t cp) {
  if (cp <= 0 || cp > 0x10FFFF) return 0;
  if (cp == 0x00A0) return 0;
  if (!load_icu() || p_u_getIntPropertyValue == NULL) return 0;
  int32_t cls = p_u_getIntPropertyValue(cp, 0x1008 /* UCHAR_LINE_BREAK */);
  return cls == 9 /* CM */ || cls == 12 /* GL */ || cls == 30 /* WJ */ || cls == 42 /* ZWJ */;
}

// ---------------------------------------------------------------------------
// WebGL2
//
// A <canvas> with a "webgl2" context owns an EGL context and a framebuffer object that stands in
// for the browser's default framebuffer, and the canvas bitmap the display list draws (CMD_CANVAS)
// is a readback of it. Commands execute as they are called, as with the 2D canvas, and every call
// names the canvas it belongs to, so several WebGL canvases keep separate GL state.
//
// EGL's surfaceless platform makes the context without a window or a native surface, which suits a
// host that renders offscreen and reads the result back; Mesa's llvmpipe needs nothing else.
// Programs arrive as GLSL ES 3.00 and are compiled as desktop GLSL 4.10, the version a macOS core
// context takes: three.js's programs need only the version line changed, and their `precision`
// declarations are accepted as they are.

typedef struct GlCanvas {
  EGLContext ctx;
  // The stand-in for the default framebuffer: a resolved RGBA8 texture the canvas bitmap is read
  // from, and, when the context asks for antialiasing, a multisampled pair drawn into and blitted
  // into the resolved one when the canvas is painted.
  GLuint fbo, color;
  GLuint msaa_fbo, msaa_color, msaa_depth;
  GLuint depth; // the resolved framebuffer's depth/stencil renderbuffer
  GLuint default_vao; // core profile has no vertex array object 0, so the page's 0 names this one
  double w, h;
  int depth_bits, stencil_bits, samples, alpha;
} GlCanvas;

static GlCanvas *gl_at(int32_t id) {
  Canvas *c = canvas_at(id);
  return c ? c->gl : NULL;
}

// The display every canvas's context comes from, opened once. A machine with no GPU still has
// llvmpipe, so the surfaceless platform answers even where there is no X server or Wayland one.
static EGLDisplay g_egl_display = EGL_NO_DISPLAY;
static EGLConfig g_egl_config = NULL;
static int g_egl_started = 0;

static EGLDisplay egl_display(void) {
  if (g_egl_started) return g_egl_display;
  g_egl_started = 1;
  PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display =
    (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
#ifdef EGL_PLATFORM_SURFACELESS_MESA
  if (get_platform_display)
    g_egl_display = get_platform_display(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
#endif
  if (g_egl_display == EGL_NO_DISPLAY) g_egl_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (g_egl_display == EGL_NO_DISPLAY) return g_egl_display;
  EGLint major = 0, minor = 0;
  if (!eglInitialize(g_egl_display, &major, &minor)) {
    g_egl_display = EGL_NO_DISPLAY;
    return g_egl_display;
  }
  // A desktop OpenGL context, which is what the shader translation targets.
  if (!eglBindAPI(EGL_OPENGL_API)) {
    g_egl_display = EGL_NO_DISPLAY;
    return g_egl_display;
  }
  // The context renders to a framebuffer object of its own, so its config only has to exist; the
  // colour, depth and stencil sizes it asks for are the ones a browser's drawing buffer has.
  EGLint attrs[] = {
    EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
    EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
    EGL_COLOR_BUFFER_TYPE, EGL_RGB_BUFFER,
    EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
    EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
    EGL_NONE,
  };
  EGLint count = 0;
  if (!eglChooseConfig(g_egl_display, attrs, &g_egl_config, 1, &count) || count < 1)
    g_egl_display = EGL_NO_DISPLAY;
  return g_egl_display;
}

// A core-profile context at the newest version the driver offers, which is 4.5 on llvmpipe and
// 4.1 on a Mac; every entry point here is common to both.
static EGLContext gl_make_context(EGLDisplay dpy) {
  static const EGLint versions[][2] = {{4, 5}, {4, 1}};
  for (size_t i = 0; i < sizeof versions / sizeof versions[0]; i++) {
    EGLint attrs[] = {
      EGL_CONTEXT_MAJOR_VERSION, versions[i][0],
      EGL_CONTEXT_MINOR_VERSION, versions[i][1],
      EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
      EGL_NONE,
    };
    EGLContext ctx = eglCreateContext(dpy, g_egl_config, EGL_NO_CONTEXT, attrs);
    if (ctx != EGL_NO_CONTEXT) return ctx;
  }
  return EGL_NO_CONTEXT;
}

// Makes the canvas's context current. False when the canvas has no WebGL context.
static int gl_ready(GlCanvas *g) {
  if (!g || g->ctx == EGL_NO_CONTEXT) return 0;
  EGLDisplay dpy = egl_display();
  if (dpy == EGL_NO_DISPLAY) return 0;
  if (eglGetCurrentContext() != g->ctx &&
      !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, g->ctx))
    return 0;
  return 1;
}

// The renderbuffer format for the depth/stencil attachment: 0 when the context asked for neither.
// A framebuffer without a depth attachment passes the depth test, as a browser's does.
static GLenum gl_depth_format(const GlCanvas *g) {
  if (g->depth_bits && g->stencil_bits) return GL_DEPTH24_STENCIL8;
  if (g->depth_bits) return GL_DEPTH_COMPONENT24;
  if (g->stencil_bits) return GL_STENCIL_INDEX8;
  return 0;
}

// `g->fbo` for a context without antialiasing, else the multisampled one; framebuffer object 0
// from the page binds this.
static GLuint gl_draw_fbo(const GlCanvas *g) {
  return g->samples ? g->msaa_fbo : g->fbo;
}

static void gl_alloc(GlCanvas *g, double w, double h) {
  if (w < 1) w = 1;
  if (h < 1) h = 1;
  g->w = floor(w);
  g->h = floor(h);
  GLsizei gw = (GLsizei)g->w, gh = (GLsizei)g->h;

  glBindFramebuffer(GL_FRAMEBUFFER, g->fbo);
  glBindTexture(GL_TEXTURE_2D, g->color);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, gw, gh, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, g->color, 0);

  GLenum dfmt = gl_depth_format(g);
  if (dfmt) {
    glBindRenderbuffer(GL_RENDERBUFFER, g->depth);
    glRenderbufferStorage(GL_RENDERBUFFER, dfmt, gw, gh);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, g->stencil_bits ? GL_DEPTH_STENCIL_ATTACHMENT : GL_DEPTH_ATTACHMENT,
                              GL_RENDERBUFFER, g->depth);
  }

  if (g->samples) {
    glBindFramebuffer(GL_FRAMEBUFFER, g->msaa_fbo);
    glBindRenderbuffer(GL_RENDERBUFFER, g->msaa_color);
    glRenderbufferStorageMultisample(GL_RENDERBUFFER, g->samples, GL_RGBA8, gw, gh);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, g->msaa_color);
    if (dfmt) {
      glBindRenderbuffer(GL_RENDERBUFFER, g->msaa_depth);
      glRenderbufferStorageMultisample(GL_RENDERBUFFER, g->samples, dfmt, gw, gh);
      glFramebufferRenderbuffer(GL_FRAMEBUFFER, g->stencil_bits ? GL_DEPTH_STENCIL_ATTACHMENT : GL_DEPTH_ATTACHMENT,
                                GL_RENDERBUFFER, g->msaa_depth);
    }
  }

  glBindFramebuffer(GL_FRAMEBUFFER, gl_draw_fbo(g));
  glViewport(0, 0, gw, gh);
  // A browser's drawing buffer starts cleared to transparent black.
  glClearColor(0, 0, 0, 0);
  glClearDepth(1);
  glClearStencil(0);
  glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
  glBindTexture(GL_TEXTURE_2D, 0);
}

// Creates the canvas's GL context and drawing buffer, or resizes the buffer it has. The first
// call fixes the context attributes the drawing buffer honours.
int32_t host_gl_attach(int32_t id, double w, double h, double depth, double stencil, double antialias) {
  Canvas *c = canvas_at(id);
  if (!c) return 0;
  GlCanvas *g = c->gl;
  if (!g) {
    g = (GlCanvas *)calloc(1, sizeof(GlCanvas));
    if (!g) return 0;
    c->gl = g;
  }
  if (g->ctx == EGL_NO_CONTEXT) {
    g->depth_bits = depth != 0;
    g->stencil_bits = stencil != 0;
    g->samples = antialias != 0 ? 4 : 0;
    g->alpha = 1;
    EGLDisplay dpy = egl_display();
    if (dpy == EGL_NO_DISPLAY) return 0;
    g->ctx = gl_make_context(dpy);
    if (g->ctx == EGL_NO_CONTEXT) return 0;
    if (!gl_ready(g)) {
      eglDestroyContext(dpy, g->ctx);
      g->ctx = EGL_NO_CONTEXT;
      return 0;
    }
    // WebGL always takes a point's size from gl_PointSize; a core GL context only does with this on.
    glEnable(GL_PROGRAM_POINT_SIZE);
    glGenFramebuffers(1, &g->fbo);
    glGenTextures(1, &g->color);
    glGenRenderbuffers(1, &g->depth);
    glGenVertexArrays(1, &g->default_vao);
    glBindVertexArray(g->default_vao);
    if (g->samples) {
      glGenFramebuffers(1, &g->msaa_fbo);
      glGenRenderbuffers(1, &g->msaa_color);
      glGenRenderbuffers(1, &g->msaa_depth);
      GLint max_samples = 0;
      glGetIntegerv(GL_MAX_SAMPLES, &max_samples);
      if (g->samples > max_samples) g->samples = max_samples;
      if (g->samples < 1) g->samples = 0;
    }
  }
  if (!gl_ready(g)) return 0;
  gl_alloc(g, w, h);
  return 1;
}

// Whether the drawing buffer keeps its alpha (WebGL's `alpha` context attribute).
void host_gl_set_alpha(int32_t id, double alpha) {
  GlCanvas *g = gl_at(id);
  if (g) g->alpha = alpha != 0;
}

// Copies the drawing buffer into the canvas bitmap for the display list: GL's rows run bottom to
// top and its colours are straight, the bitmap's run top to bottom and are premultiplied (in the
// byte order this machine's Cairo surface uses).
static void gl_present_canvas(Canvas *c) {
  GlCanvas *g = c->gl;
  if (!gl_ready(g) || !c->surface) return;
  int w = (int)g->w, h = (int)g->h;
  int cw = (int)c->w, ch = (int)c->h;
  if (w < 1 || h < 1) return;
  uint8_t *px = (uint8_t *)malloc((size_t)w * h * 4);
  if (!px) return;
  // The page draws between presents, so the framebuffer it left bound has to come back.
  GLint prev_read = 0, prev_draw = 0, prev_align = 4;
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prev_read);
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prev_draw);
  glGetIntegerv(GL_PACK_ALIGNMENT, &prev_align);
  if (g->samples) {
    glBindFramebuffer(GL_READ_FRAMEBUFFER, g->msaa_fbo);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g->fbo);
    glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
  }
  glBindFramebuffer(GL_FRAMEBUFFER, g->fbo);
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)prev_read);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)prev_draw);
  glPixelStorei(GL_PACK_ALIGNMENT, prev_align);
  ensure_channels();
  cairo_surface_flush(c->surface);
  unsigned char *dst = cairo_image_surface_get_data(c->surface);
  size_t stride = (size_t)cairo_image_surface_get_stride(c->surface);
  const int R = g_ch_r, G = g_ch_g, B = g_ch_b, A = g_ch_a;
  if (dst) {
    int rows = ch < h ? ch : h;
    int cols = cw < w ? cw : w;
    for (int y = 0; y < rows; y++) {
      const uint8_t *src = px + (size_t)(h - 1 - y) * w * 4;
      uint8_t *row = dst + (size_t)y * stride;
      for (int x = 0; x < cols; x++) {
        unsigned a = g->alpha ? src[x * 4 + 3] : 255u;
        row[x * 4 + R] = (uint8_t)((src[x * 4 + 0] * a + 127) / 255);
        row[x * 4 + G] = (uint8_t)((src[x * 4 + 1] * a + 127) / 255);
        row[x * 4 + B] = (uint8_t)((src[x * 4 + 2] * a + 127) / 255);
        row[x * 4 + A] = (uint8_t)a;
      }
    }
    cairo_surface_mark_dirty(c->surface);
  }
  free(px);
}

// Objects. Each GL name is only unique within its context, and every call names its canvas.
int32_t host_gl_create_buffer(int32_t id) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLuint b = 0;
  glGenBuffers(1, &b);
  return (int32_t)b;
}

int32_t host_gl_create_texture(int32_t id) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLuint t = 0;
  glGenTextures(1, &t);
  return (int32_t)t;
}

int32_t host_gl_create_framebuffer(int32_t id) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLuint f = 0;
  glGenFramebuffers(1, &f);
  return (int32_t)f;
}

int32_t host_gl_create_renderbuffer(int32_t id) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLuint r = 0;
  glGenRenderbuffers(1, &r);
  return (int32_t)r;
}

int32_t host_gl_create_program(int32_t id) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  return (int32_t)glCreateProgram();
}

int32_t host_gl_create_shader(int32_t id, double type) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  return (int32_t)glCreateShader((GLenum)type);
}

int32_t host_gl_create_vertex_array(int32_t id) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLuint v = 0;
  glGenVertexArrays(1, &v);
  return (int32_t)v;
}

// kind: 0 buffer, 1 texture, 2 framebuffer, 3 renderbuffer, 4 program, 5 shader, 6 vertex array.
void host_gl_delete_object(int32_t id, double kind, double obj) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  GLuint o = (GLuint)obj;
  switch ((int)kind) {
    case 0: glDeleteBuffers(1, &o); break;
    case 1: glDeleteTextures(1, &o); break;
    case 2: glDeleteFramebuffers(1, &o); break;
    case 3: glDeleteRenderbuffers(1, &o); break;
    case 4: glDeleteProgram(o); break;
    case 5: glDeleteShader(o); break;
    case 6: glDeleteVertexArrays(1, &o); break;
  }
}

// Buffers
void host_gl_bind_buffer(int32_t id, double target, double buffer) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBindBuffer((GLenum)target, (GLuint)buffer);
}

void host_gl_buffer_data(int32_t id, double target, double usage, const uint8_t *data, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBufferData((GLenum)target, (GLsizeiptr)n, data, (GLenum)usage);
}

void host_gl_buffer_data_size(int32_t id, double target, double size, double usage) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBufferData((GLenum)target, (GLsizeiptr)size, NULL, (GLenum)usage);
}

void host_gl_buffer_sub_data(int32_t id, double target, double offset, const uint8_t *data, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBufferSubData((GLenum)target, (GLintptr)offset, (GLsizeiptr)n, data);
}

// Textures
void host_gl_active_texture(int32_t id, double unit) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glActiveTexture((GLenum)unit);
}

void host_gl_bind_texture(int32_t id, double target, double texture) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBindTexture((GLenum)target, (GLuint)texture);
}

void host_gl_tex_image_2d(int32_t id, double target, double level, double internal, double w, double h,
                          double border, double format, double type, const uint8_t *data, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexImage2D((GLenum)target, (GLint)level, (GLint)internal, (GLsizei)w, (GLsizei)h, (GLint)border,
               (GLenum)format, (GLenum)type, n ? data : NULL);
}

void host_gl_tex_image_2d_null(int32_t id, double target, double level, double internal, double w, double h,
                               double border, double format, double type) {
  host_gl_tex_image_2d(id, target, level, internal, w, h, border, format, type, NULL, 0);
}

void host_gl_tex_image_3d(int32_t id, double target, double level, double internal, double w, double h, double depth,
                          double border, double format, double type, const uint8_t *data, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexImage3D((GLenum)target, (GLint)level, (GLint)internal, (GLsizei)w, (GLsizei)h, (GLsizei)depth,
               (GLint)border, (GLenum)format, (GLenum)type, n ? data : NULL);
}

void host_gl_tex_sub_image_2d(int32_t id, double target, double level, double x, double y, double w, double h,
                              double format, double type, const uint8_t *data, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexSubImage2D((GLenum)target, (GLint)level, (GLint)x, (GLint)y, (GLsizei)w, (GLsizei)h, (GLenum)format,
                  (GLenum)type, n ? data : NULL);
}

void host_gl_tex_storage_2d(int32_t id, double target, double levels, double internal, double w, double h) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glTexStorage2D((GLenum)target, (GLsizei)levels, (GLenum)internal, (GLsizei)w, (GLsizei)h);
}

// An image texture upload. The host has already decoded the file, into premultiplied RGBA rows
// with the top row first, and hands those to GL; WebGL's unpack options are the runtime's, so the
// two that change the data (flip and premultiply) are applied here as the runtime passes them in.
static uint8_t *image_rgba(const int32_t image, const int flip, const int premultiply,
                           GLsizei *out_w, GLsizei *out_h) {
  if (image < 0 || image >= g_image_count) return NULL;
  const Image *img = &g_images[image];
  if (!img->loaded || !img->px || img->w <= 0 || img->h <= 0) return NULL;
  size_t w = (size_t)img->w, h = (size_t)img->h;
  uint8_t *data = (uint8_t *)malloc(w * h * 4);
  if (!data) return NULL;
  for (size_t y = 0; y < h; y++) memcpy(data + y * w * 4, img->px + y * img->stride, w * 4);
  size_t count = w * h;
  // The decoded pixels are premultiplied; UNPACK_PREMULTIPLY_ALPHA_WEBGL=false asks for the
  // file's own straight values, so undo the multiplication.
  if (!premultiply) {
    for (size_t i = 0; i < count; i++) {
      uint8_t *p = data + i * 4;
      unsigned a = p[3];
      if (a != 0 && a != 255) {
        p[0] = (uint8_t)((p[0] * 255u + a / 2) / a);
        p[1] = (uint8_t)((p[1] * 255u + a / 2) / a);
        p[2] = (uint8_t)((p[2] * 255u + a / 2) / a);
      }
    }
  }
  // GL takes the first row as texture row 0, which is the image's bottom row; flipping the
  // rows is what UNPACK_FLIP_Y_WEBGL does.
  if (flip && h > 1) {
    uint8_t *tmp = (uint8_t *)malloc(w * 4);
    if (tmp) {
      for (size_t y = 0; y < h / 2; y++) {
        uint8_t *top = data + y * w * 4;
        uint8_t *bottom = data + (h - 1 - y) * w * 4;
        memcpy(tmp, top, w * 4);
        memcpy(top, bottom, w * 4);
        memcpy(bottom, tmp, w * 4);
      }
      free(tmp);
    }
  }
  *out_w = (GLsizei)w;
  *out_h = (GLsizei)h;
  return data;
}

void host_gl_tex_image_2d_from_image(int32_t id, double target, double level, double internal,
                                     int32_t image, int32_t flip, int32_t premultiply) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  GLsizei w = 0, h = 0;
  uint8_t *data = image_rgba(image, flip != 0, premultiply != 0, &w, &h);
  if (!data) return;
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexImage2D((GLenum)target, (GLint)level, (GLint)internal, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, data);
  free(data);
}

void host_gl_tex_sub_image_2d_from_image(int32_t id, double target, double level, double x, double y,
                                         int32_t image, int32_t flip, int32_t premultiply) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  GLsizei w = 0, h = 0;
  uint8_t *data = image_rgba(image, flip != 0, premultiply != 0, &w, &h);
  if (!data) return;
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexSubImage2D((GLenum)target, (GLint)level, (GLint)x, (GLint)y, w, h, GL_RGBA, GL_UNSIGNED_BYTE, data);
  free(data);
}

void host_gl_tex_parameter_i(int32_t id, double target, double pname, double param) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glTexParameteri((GLenum)target, (GLenum)pname, (GLint)param);
}

void host_gl_tex_parameter_f(int32_t id, double target, double pname, double param) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glTexParameterf((GLenum)target, (GLenum)pname, (GLfloat)param);
}

void host_gl_generate_mipmap(int32_t id, double target) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glGenerateMipmap((GLenum)target);
}

void host_gl_pixel_storei(int32_t id, double pname, double param) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glPixelStorei((GLenum)pname, (GLint)param);
}

// Shaders and programs
void host_gl_shader_source(int32_t id, double shader, const char *src) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  size_t n = strlen(src);
  const char *s = src;
  char *translated = NULL;
  const char *version = "#version 300 es";
  const char *at = strstr(s, version);
  if (at) {
    const char *desktop = "#version 410 core";
    size_t head = (size_t)(at - s);
    size_t rest = n - head - strlen(version);
    translated = malloc(head + strlen(desktop) + rest + 1);
    if (translated) {
      memcpy(translated, s, head);
      memcpy(translated + head, desktop, strlen(desktop));
      memcpy(translated + head + strlen(desktop), at + strlen(version), rest);
      translated[head + strlen(desktop) + rest] = 0;
      s = translated;
    }
  }
  glShaderSource((GLuint)shader, 1, &s, NULL);
  free(translated);
}

void host_gl_compile_shader(int32_t id, double shader) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glCompileShader((GLuint)shader);
}

double host_gl_get_shader_parameter(int32_t id, double shader, double pname) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLint v = 0;
  glGetShaderiv((GLuint)shader, (GLenum)pname, &v);
  return v;
}

void host_gl_get_shader_info_log(int32_t id, double shader, str_cb cb) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  char log[8192];
  GLsizei n = 0;
  glGetShaderInfoLog((GLuint)shader, sizeof log, &n, log);
  cb((const uint8_t *)log, (size_t)n);
}

void host_gl_attach_shader(int32_t id, double program, double shader) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glAttachShader((GLuint)program, (GLuint)shader);
}

void host_gl_detach_shader(int32_t id, double program, double shader) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDetachShader((GLuint)program, (GLuint)shader);
}

void host_gl_bind_attrib_location(int32_t id, double program, double index, const char *name) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBindAttribLocation((GLuint)program, (GLuint)index, name);
}

void host_gl_link_program(int32_t id, double program) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glLinkProgram((GLuint)program);
}

void host_gl_use_program(int32_t id, double program) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glUseProgram((GLuint)program);
}

double host_gl_get_program_parameter(int32_t id, double program, double pname) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLint v = 0;
  glGetProgramiv((GLuint)program, (GLenum)pname, &v);
  return v;
}

void host_gl_get_program_info_log(int32_t id, double program, str_cb cb) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  char log[8192];
  GLsizei n = 0;
  glGetProgramInfoLog((GLuint)program, sizeof log, &n, log);
  cb((const uint8_t *)log, (size_t)n);
}

double host_gl_get_attrib_location(int32_t id, double program, const char *name) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return -1;
  return glGetAttribLocation((GLuint)program, name);
}

double host_gl_get_uniform_location(int32_t id, double program, const char *name) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return -1;
  return glGetUniformLocation((GLuint)program, name);
}

double host_gl_get_uniform_block_index(int32_t id, double program, const char *name) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return -1;
  return glGetUniformBlockIndex((GLuint)program, name);
}

// The active uniform and attribute tables, read one entry at a time: the name through a callback,
// the type and size as numbers.
void host_gl_active_uniform_name(int32_t id, double program, double index, str_cb name) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  char buf[512];
  GLsizei len = 0;
  GLint size = 0;
  GLenum type = 0;
  glGetActiveUniform((GLuint)program, (GLuint)index, sizeof buf, &len, &size, &type, buf);
  name((const uint8_t *)buf, (size_t)len);
}

double host_gl_active_uniform_type(int32_t id, double program, double index) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  char buf[1];
  GLsizei len = 0;
  GLint size = 0;
  GLenum type = 0;
  glGetActiveUniform((GLuint)program, (GLuint)index, 0, &len, &size, &type, buf);
  return type;
}

double host_gl_active_uniform_size(int32_t id, double program, double index) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  char buf[1];
  GLsizei len = 0;
  GLint size = 0;
  GLenum type = 0;
  glGetActiveUniform((GLuint)program, (GLuint)index, 0, &len, &size, &type, buf);
  return size;
}

void host_gl_active_attrib_name(int32_t id, double program, double index, str_cb name) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  char buf[512];
  GLsizei len = 0;
  GLint size = 0;
  GLenum type = 0;
  glGetActiveAttrib((GLuint)program, (GLuint)index, sizeof buf, &len, &size, &type, buf);
  name((const uint8_t *)buf, (size_t)len);
}

double host_gl_active_attrib_type(int32_t id, double program, double index) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  char buf[1];
  GLsizei len = 0;
  GLint size = 0;
  GLenum type = 0;
  glGetActiveAttrib((GLuint)program, (GLuint)index, 0, &len, &size, &type, buf);
  return type;
}

double host_gl_active_attrib_size(int32_t id, double program, double index) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  char buf[1];
  GLsizei len = 0;
  GLint size = 0;
  GLenum type = 0;
  glGetActiveAttrib((GLuint)program, (GLuint)index, 0, &len, &size, &type, buf);
  return size;
}

// Uniforms. One call covers every vector shape: `kind` names it (1..4 float, 5..8 int, 9..12
// unsigned), and the count follows from the byte length.
void host_gl_uniform1f(int32_t id, double location, double x) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glUniform1f((GLint)location, (GLfloat)x);
}

void host_gl_uniform1i(int32_t id, double location, double x) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glUniform1i((GLint)location, (GLint)x);
}

void host_gl_uniform(int32_t id, double location, double kind, const uint8_t *data, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  int k = (int)kind;
  int comps = ((k - 1) % 4) + 1;
  int count = (int)(n / (4 * comps));
  const GLfloat *f = (const GLfloat *)data;
  const GLint *i = (const GLint *)data;
  const GLuint *u = (const GLuint *)data;
  switch (k) {
    case 1: glUniform1fv((GLint)location, count, f); break;
    case 2: glUniform2fv((GLint)location, count, f); break;
    case 3: glUniform3fv((GLint)location, count, f); break;
    case 4: glUniform4fv((GLint)location, count, f); break;
    case 5: glUniform1iv((GLint)location, count, i); break;
    case 6: glUniform2iv((GLint)location, count, i); break;
    case 7: glUniform3iv((GLint)location, count, i); break;
    case 8: glUniform4iv((GLint)location, count, i); break;
    case 9: glUniform1uiv((GLint)location, count, u); break;
    case 10: glUniform2uiv((GLint)location, count, u); break;
    case 11: glUniform3uiv((GLint)location, count, u); break;
    case 12: glUniform4uiv((GLint)location, count, u); break;
  }
}

// `dims` is 2, 3 or 4 for the square matrix shape.
void host_gl_uniform_matrix(int32_t id, double location, double dims, double transpose, const uint8_t *data, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  int d = (int)dims;
  int count = (int)(n / (4 * d * d));
  const GLfloat *m = (const GLfloat *)data;
  switch (d) {
    case 2: glUniformMatrix2fv((GLint)location, count, (GLboolean)transpose, m); break;
    case 3: glUniformMatrix3fv((GLint)location, count, (GLboolean)transpose, m); break;
    case 4: glUniformMatrix4fv((GLint)location, count, (GLboolean)transpose, m); break;
  }
}

// Vertex attributes
void host_gl_bind_vertex_array(int32_t id, double array) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBindVertexArray((GLuint)array == 0 ? g->default_vao : (GLuint)array);
}

void host_gl_enable_vertex_attrib_array(int32_t id, double index) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glEnableVertexAttribArray((GLuint)index);
}

void host_gl_disable_vertex_attrib_array(int32_t id, double index) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDisableVertexAttribArray((GLuint)index);
}

void host_gl_vertex_attrib_pointer(int32_t id, double index, double size, double type, double normalized,
                                   double stride, double offset) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glVertexAttribPointer((GLuint)index, (GLint)size, (GLenum)type, (GLboolean)normalized, (GLsizei)stride,
                        (const void *)(GLintptr)offset);
}

void host_gl_vertex_attrib_i_pointer(int32_t id, double index, double size, double type, double stride, double offset) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glVertexAttribIPointer((GLuint)index, (GLint)size, (GLenum)type, (GLsizei)stride, (const void *)(GLintptr)offset);
}

void host_gl_vertex_attrib_divisor(int32_t id, double index, double divisor) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glVertexAttribDivisor((GLuint)index, (GLuint)divisor);
}

// A constant value for an attribute no buffer feeds: `kind` is the float vector length, 1 to 4.
void host_gl_vertex_attrib(int32_t id, double index, double kind, const uint8_t *data, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  const GLfloat *v = (const GLfloat *)data;
  switch ((int)kind) {
    case 1: glVertexAttrib1fv((GLuint)index, v); break;
    case 2: glVertexAttrib2fv((GLuint)index, v); break;
    case 3: glVertexAttrib3fv((GLuint)index, v); break;
    case 4: glVertexAttrib4fv((GLuint)index, v); break;
  }
}

// Framebuffers. Binding 0 means the canvas's drawing buffer, as in a browser.
void host_gl_bind_framebuffer(int32_t id, double target, double framebuffer) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBindFramebuffer((GLenum)target, (GLuint)framebuffer == 0 ? gl_draw_fbo(g) : (GLuint)framebuffer);
}

void host_gl_bind_renderbuffer(int32_t id, double target, double renderbuffer) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBindRenderbuffer((GLenum)target, (GLuint)renderbuffer);
}

void host_gl_framebuffer_texture_2d(int32_t id, double target, double attachment, double tex_target,
                                    double texture, double level) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glFramebufferTexture2D((GLenum)target, (GLenum)attachment, (GLenum)tex_target, (GLuint)texture, (GLint)level);
}

void host_gl_framebuffer_renderbuffer(int32_t id, double target, double attachment, double rb_target,
                                      double renderbuffer) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glFramebufferRenderbuffer((GLenum)target, (GLenum)attachment, (GLenum)rb_target, (GLuint)renderbuffer);
}

void host_gl_renderbuffer_storage(int32_t id, double target, double format, double w, double h) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glRenderbufferStorage((GLenum)target, (GLenum)format, (GLsizei)w, (GLsizei)h);
}

double host_gl_check_framebuffer_status(int32_t id, double target) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  return glCheckFramebufferStatus((GLenum)target);
}

// The list arrives as 32-bit ids in a byte view, which is how an array crosses the FFI.
void host_gl_draw_buffers(int32_t id, double count, const uint8_t *buffers, size_t bytes) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  int n = (int)count;
  if (n < 0) n = 0;
  if (n > 32) n = 32;
  if (bytes < (size_t)n * 4) n = (int)(bytes / 4);
  GLenum list[32];
  const uint32_t *ids = (const uint32_t *)buffers;
  for (int i = 0; i < n; i++) {
    // The canvas's default framebuffer is a texture-backed FBO here, so WebGL's BACK is its
    // one colour attachment rather than a real back buffer.
    list[i] = (GLenum)ids[i] == GL_BACK ? GL_COLOR_ATTACHMENT0 : (GLenum)ids[i];
  }
  glDrawBuffers(n, list);
}

// Drawing
void host_gl_draw_arrays(int32_t id, double mode, double first, double count) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDrawArrays((GLenum)mode, (GLint)first, (GLsizei)count);
}

void host_gl_draw_elements(int32_t id, double mode, double count, double type, double offset) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDrawElements((GLenum)mode, (GLsizei)count, (GLenum)type, (const void *)(GLintptr)offset);
}

void host_gl_draw_arrays_instanced(int32_t id, double mode, double first, double count, double instances) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDrawArraysInstanced((GLenum)mode, (GLint)first, (GLsizei)count, (GLsizei)instances);
}

void host_gl_draw_elements_instanced(int32_t id, double mode, double count, double type, double offset, double instances) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDrawElementsInstanced((GLenum)mode, (GLsizei)count, (GLenum)type, (const void *)(GLintptr)offset, (GLsizei)instances);
}

// Fixed-function state. Each call sets one piece, as the WebGL method does.
void host_gl_enable(int32_t id, double cap) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glEnable((GLenum)cap);
}

void host_gl_disable(int32_t id, double cap) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDisable((GLenum)cap);
}

void host_gl_clear(int32_t id, double mask) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glClear((GLbitfield)mask);
}

void host_gl_clear_color(int32_t id, double r, double g_, double b, double a) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glClearColor((GLfloat)r, (GLfloat)g_, (GLfloat)b, (GLfloat)a);
}

void host_gl_clear_depth(int32_t id, double depth) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glClearDepth(depth);
}

void host_gl_clear_stencil(int32_t id, double s) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glClearStencil((GLint)s);
}

void host_gl_color_mask(int32_t id, double r, double g_, double b, double a) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glColorMask(r != 0, g_ != 0, b != 0, a != 0);
}

void host_gl_depth_mask(int32_t id, double flag) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDepthMask(flag != 0);
}

void host_gl_stencil_mask(int32_t id, double mask) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glStencilMask((GLuint)mask);
}

void host_gl_cull_face(int32_t id, double mode) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glCullFace((GLenum)mode);
}

void host_gl_front_face(int32_t id, double mode) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glFrontFace((GLenum)mode);
}

void host_gl_depth_func(int32_t id, double func) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDepthFunc((GLenum)func);
}

void host_gl_depth_range(int32_t id, double near, double far) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glDepthRange(near, far);
}

void host_gl_blend_func(int32_t id, double src, double dst) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBlendFunc((GLenum)src, (GLenum)dst);
}

void host_gl_blend_func_separate(int32_t id, double src_rgb, double dst_rgb, double src_alpha, double dst_alpha) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBlendFuncSeparate((GLenum)src_rgb, (GLenum)dst_rgb, (GLenum)src_alpha, (GLenum)dst_alpha);
}

void host_gl_blend_equation(int32_t id, double mode) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBlendEquation((GLenum)mode);
}

void host_gl_blend_equation_separate(int32_t id, double rgb, double alpha) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBlendEquationSeparate((GLenum)rgb, (GLenum)alpha);
}

void host_gl_blend_color(int32_t id, double r, double g_, double b, double a) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glBlendColor((GLfloat)r, (GLfloat)g_, (GLfloat)b, (GLfloat)a);
}

void host_gl_polygon_offset(int32_t id, double factor, double units) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glPolygonOffset((GLfloat)factor, (GLfloat)units);
}

void host_gl_stencil_func(int32_t id, double func, double ref, double mask) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glStencilFunc((GLenum)func, (GLint)ref, (GLuint)mask);
}

void host_gl_stencil_op(int32_t id, double fail, double zfail, double zpass) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glStencilOp((GLenum)fail, (GLenum)zfail, (GLenum)zpass);
}

void host_gl_viewport(int32_t id, double x, double y, double w, double h) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glViewport((GLint)x, (GLint)y, (GLsizei)w, (GLsizei)h);
}

void host_gl_scissor(int32_t id, double x, double y, double w, double h) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glScissor((GLint)x, (GLint)y, (GLsizei)w, (GLsizei)h);
}

void host_gl_line_width(int32_t id, double width) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glLineWidth((GLfloat)width);
}

void host_gl_finish(int32_t id) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glFinish();
}

void host_gl_flush(int32_t id) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  glFlush();
}

// Queries
double host_gl_get_parameter_int(int32_t id, double pname) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLint v = 0;
  glGetIntegerv((GLenum)pname, &v);
  return v;
}

double host_gl_get_parameter_float(int32_t id, double pname) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLfloat v = 0;
  glGetFloatv((GLenum)pname, &v);
  return v;
}

void host_gl_get_parameter_ints(int32_t id, double pname, uint8_t *out, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g) || n < 4) return;
  glGetIntegerv((GLenum)pname, (GLint *)out);
}

void host_gl_get_parameter_floats(int32_t id, double pname, uint8_t *out, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g) || n < 4) return;
  glGetFloatv((GLenum)pname, (GLfloat *)out);
}

void host_gl_get_parameter_string(int32_t id, double pname, str_cb cb) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  const GLubyte *s = glGetString((GLenum)pname);
  if (s) cb(s, strlen((const char *)s));
}

// A core context has no GL_EXTENSIONS string: the list is counted and fetched by index.
int32_t host_gl_extension_count(int32_t id) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  GLint count = 0;
  glGetIntegerv(GL_NUM_EXTENSIONS, &count);
  return count;
}

void host_gl_extension_string(int32_t id, double index, str_cb cb) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  const GLubyte *s = glGetStringi(GL_EXTENSIONS, (GLuint)index);
  if (s) cb(s, strlen((const char *)s));
}

double host_gl_get_error(int32_t id) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return 0;
  return glGetError();
}

void host_gl_read_pixels(int32_t id, double x, double y, double w, double h, uint8_t *out, size_t n) {
  GlCanvas *g = gl_at(id);
  if (!gl_ready(g)) return;
  GLint prev_read = 0, prev_draw = 0, prev_align = 4;
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prev_read);
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prev_draw);
  glGetIntegerv(GL_PACK_ALIGNMENT, &prev_align);
  // Reading the default framebuffer reads what the page has drawn so far, so the multisampled
  // buffer behind it is resolved first.
  if (g->samples && (GLuint)prev_read == g->msaa_fbo) {
    glBindFramebuffer(GL_READ_FRAMEBUFFER, g->msaa_fbo);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, g->fbo);
    glBlitFramebuffer(0, 0, (GLsizei)g->w, (GLsizei)g->h, 0, 0, (GLsizei)g->w, (GLsizei)g->h,
                      GL_COLOR_BUFFER_BIT, GL_NEAREST);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, g->fbo);
  }
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glReadPixels((GLint)x, (GLint)y, (GLsizei)w, (GLsizei)h, GL_RGBA, GL_UNSIGNED_BYTE, out);
  glBindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)prev_read);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, (GLuint)prev_draw);
  glPixelStorei(GL_PACK_ALIGNMENT, prev_align);
}

static void gl_resize_canvas(int32_t id, double w, double h) {
  Canvas *c = canvas_at(id);
  if (c && c->gl) host_gl_attach(id, w, h, c->gl->depth_bits, c->gl->stencil_bits, c->gl->samples);
}