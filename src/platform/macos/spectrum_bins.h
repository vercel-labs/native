#ifndef NATIVE_SDK_SPECTRUM_BINS_H
#define NATIVE_SDK_SPECTRUM_BINS_H

#include <math.h>

typedef struct native_sdk_spectrum_bin_range {
    int first;
    int last;
} native_sdk_spectrum_bin_range_t;

/* FFT power has fft_size / 2 entries; bin 0 is DC and the Nyquist bin
 * is not present. Return 0 for a band wholly beyond that range. */
static inline int native_sdk_spectrum_bin_range(
    double low_hz,
    double high_hz,
    double sample_rate,
    int fft_size,
    native_sdk_spectrum_bin_range_t *range
) {
    const double nyquist_hz = sample_rate / 2.0;
    if (low_hz >= nyquist_hz) return 0;

    const int max_bin = fft_size / 2 - 1;
    const double hz_per_bin = sample_rate / (double)fft_size;
    int first = (int)(low_hz / hz_per_bin);
    int last = high_hz >= nyquist_hz ? max_bin : (int)ceil(high_hz / hz_per_bin);
    if (first < 1) first = 1;
    if (last > max_bin) last = max_bin;
    if (last < first) last = first;
    *range = (native_sdk_spectrum_bin_range_t){ .first = first, .last = last };
    return 1;
}

#endif
