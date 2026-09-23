#ifndef HDR_CACHE_PIXELS_H
#define HDR_CACHE_PIXELS_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Internal CPU pixel helpers for FrameEngine; these are not session ABI entry points.
// Byte input may be unaligned. RGB is finite linear light, including negative values;
// alpha is straight and must be in [0, 1]. No luminance clipping is performed.
bool hdr_cache_validate_rgba32f_le(const void *bytes, size_t byte_count);

// Validate only active row components, leaving row padding out of the image.
bool hdr_cache_validate_rgba16f(const void *bytes, size_t width, size_t height,
                               size_t row_bytes);

// Error statistics between two RGBA16F images, for cache tolerance measurements. RGB absolute
// differences are counted into bins of bin_width nits; the last bin also takes larger errors.
typedef struct {
    unsigned long long *bins;
    size_t bin_count;
    double bin_width;
    unsigned long long count;
    double sum;
    double max;
    double reference_peak;
    unsigned long long alpha_mismatches;
} hdr_cache_error_histogram;

// Returns false for invalid geometry or a non-finite channel in either image.
bool hdr_cache_accumulate_rgba16f_error(hdr_cache_error_histogram *histogram,
                                        const void *reference, size_t reference_row_bytes,
                                        const void *candidate, size_t candidate_row_bytes,
                                        size_t width, size_t height);

#ifdef __cplusplus
}
#endif

#endif
