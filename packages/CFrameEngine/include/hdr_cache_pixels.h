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

#ifdef __cplusplus
}
#endif

#endif
