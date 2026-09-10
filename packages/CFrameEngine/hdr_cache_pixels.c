#include "hdr_cache_pixels.h"
#include <libkern/OSByteOrder.h>
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
