#include "spectrum_bins.h"

#include <stdio.h>

#define CHECK(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); \
        return 0; \
    } \
} while (0)

static int check_band_ranges(double sample_rate, int expected_present) {
    const int fft_size = 2048;
    const int band_count = 32;
    const double low_hz = 50.0;
    const double ratio = 16000.0 / low_hz;
    int present = 0;
    for (int band = 0; band < band_count; band += 1) {
        const double band_low = low_hz * pow(ratio, (double)band / band_count);
        const double band_high = low_hz * pow(ratio, (double)(band + 1) / band_count);
        native_sdk_spectrum_bin_range_t bins = { .first = -1, .last = -1 };
        const int has_bins = native_sdk_spectrum_bin_range(band_low, band_high, sample_rate, fft_size, &bins);
        CHECK(has_bins == (band_low < sample_rate / 2.0));
        if (has_bins) {
            CHECK(bins.first >= 1);
            CHECK(bins.first <= bins.last);
            CHECK(bins.last < fft_size / 2);
            present += 1;
        } else {
            CHECK(bins.first == -1 && bins.last == -1);
        }
    }
    CHECK(present == expected_present);
    return 1;
}

int main(void) {
    native_sdk_spectrum_bin_range_t bins;

    /* A band starting at Nyquist must not fold onto the final FFT bin. */
    CHECK(!native_sdk_spectrum_bin_range(8000, 9000, 16000, 2048, &bins));
    CHECK(native_sdk_spectrum_bin_range(7999, 9000, 16000, 2048, &bins));
    CHECK(bins.first == 1023 && bins.last == 1023);

    CHECK(native_sdk_spectrum_bin_range(50, 60, 16000, 2048, &bins));
    CHECK(bins.first == 6 && bins.last == 8);
    CHECK(native_sdk_spectrum_bin_range(15000, 16000, 48000, 2048, &bins));
    CHECK(bins.first == 640 && bins.last == 683);

    CHECK(check_band_ranges(8000, 25));
    CHECK(check_band_ranges(16000, 29));
    CHECK(check_band_ranges(32000, 32));
    CHECK(check_band_ranges(48000, 32));
    CHECK(check_band_ranges(1, 0));
    return 0;
}
