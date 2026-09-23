#include "hdr_cache_pixels.h"
#include <libkern/OSByteOrder.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

bool hdr_cache_validate_rgba32f_le(const void *bytes, size_t byte_count) {
    if (!bytes || !byte_count || byte_count % 16) return false;
    const unsigned char *source = bytes;
    for (size_t offset = 0; offset < byte_count; offset += 4) {
        uint32_t bits;
        memcpy(&bits, source + offset, sizeof(bits));
        bits = OSSwapLittleToHostInt32(bits);
        if ((bits & UINT32_C(0x7f800000)) == UINT32_C(0x7f800000)) return false;
        if (offset % 16 == 12) {
            float alpha;
            memcpy(&alpha, &bits, sizeof(alpha));
            if (alpha < 0 || alpha > 1) return false;
        }
    }
    return true;
}

bool hdr_cache_validate_rgba16f(const void *bytes, size_t width, size_t height,
                               size_t row_bytes) {
    if (!bytes || !width || !height || width > SIZE_MAX / 8 ||
        row_bytes < width * 8 || height > SIZE_MAX / row_bytes) return false;
    const unsigned char *source = bytes;
    for (size_t y = 0; y < height; ++y) {
        for (size_t x = 0; x < width * 4; ++x) {
            uint16_t bits;
            memcpy(&bits, source + y * row_bytes + x * 2, sizeof(bits));
            // All IEEE binary16 NaNs and infinities have exponent 31.
            if ((bits & UINT16_C(0x7c00)) == UINT16_C(0x7c00)) return false;
        }
    }
    return true;
}

bool hdr_cache_accumulate_rgba16f_error(hdr_cache_error_histogram *histogram,
                                        const void *reference, size_t reference_row_bytes,
                                        const void *candidate, size_t candidate_row_bytes,
                                        size_t width, size_t height) {
    if (!histogram || !histogram->bins || !histogram->bin_count || !(histogram->bin_width > 0) ||
        !reference || !candidate || !width || !height || width > SIZE_MAX / 8 ||
        reference_row_bytes < width * 8 || candidate_row_bytes < width * 8) return false;
    for (size_t y = 0; y < height; ++y) {
        const unsigned char *reference_row = (const unsigned char *)reference + y * reference_row_bytes;
        const unsigned char *candidate_row = (const unsigned char *)candidate + y * candidate_row_bytes;
        for (size_t x = 0; x < width; ++x) {
            _Float16 expected[4], actual[4];
            memcpy(expected, reference_row + x * 8, sizeof(expected));
            memcpy(actual, candidate_row + x * 8, sizeof(actual));
            for (size_t channel = 0; channel < 3; ++channel) {
                double peak = (double)expected[channel];
                double error = fabs((double)actual[channel] - peak);
                if (!isfinite(error)) return false;
                size_t bin = (size_t)(error / histogram->bin_width);
                histogram->bins[bin < histogram->bin_count ? bin : histogram->bin_count - 1] += 1;
                histogram->count += 1;
                histogram->sum += error;
                if (error > histogram->max) histogram->max = error;
                if (peak > histogram->reference_peak) histogram->reference_peak = peak;
            }
            if (memcmp(&expected[3], &actual[3], sizeof(_Float16)) != 0) histogram->alpha_mismatches += 1;
        }
    }
    return true;
}
