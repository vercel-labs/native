// Inline SVG filters: the portable pixel engine every host shares. The runtime compiles a
// <filter> subtree into the definition below and calls the host with the bitmap rect the filter
// region covers; the host converts that rect to premultiplied RGBA (alpha last), runs the chain,
// and writes the result back in the bitmap's own format. See runtime/svg-filters.ts for the
// definition grammar and the primitives.
#ifndef NATIVE_SVG_FILTER_H
#define NATIVE_SVG_FILTER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Runs the filter definition over `rgba`: `w` by `h` premultiplied RGBA8 pixels, alpha last,
 * tightly packed, in sRGB. `linear` is non-zero when the chain interpolates in linear RGB (the
 * SVG default). The pixels are replaced by the filter's output.
 */
void svg_filter_apply(uint8_t *rgba, int w, int h, const char *def, size_t n, int linear);

#ifdef __cplusplus
}
#endif

#endif
