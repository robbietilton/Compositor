#include "ESRGANPixels.h"
#include <dispatch/dispatch.h>
#include <math.h>

int esrgan_is_opaque(const uint8_t *rgba, size_t stride, size_t width, size_t height) {
    for (size_t y = 0; y < height; ++y) {
        const uint8_t *row = rgba + y * stride;
        for (size_t x = 0; x < width; ++x) if (row[x * 4 + 3] != 255) return 0;
    }
    return 1;
}

void esrgan_fill_tile(const uint8_t *rgba, size_t stride, size_t width, size_t height,
                      long left, long top, size_t tile, float *planar) {
    size_t plane = tile * tile;
    for (size_t y = 0; y < tile; ++y) {
        long sy = top + (long)y;
        sy = sy < 0 ? 0 : sy >= (long)height ? (long)height - 1 : sy;
        const uint8_t *row = rgba + (size_t)sy * stride;
        float *out = planar + y * tile;
        for (size_t x = 0; x < tile; ++x) {
            long sx = left + (long)x;
            sx = sx < 0 ? 0 : sx >= (long)width ? (long)width - 1 : sx;
            const uint8_t *p = row + (size_t)sx * 4;
            float alpha = p[3], scale = alpha > 0 ? 1 / alpha : 0;
            out[x] = (float)p[0] * scale;
            out[plane + x] = (float)p[1] * scale;
            out[2 * plane + x] = (float)p[2] * scale;
        }
    }
}

void esrgan_store_tile(const float *planar, size_t size, size_t margin, size_t keep_width, size_t keep_height,
                       size_t factor, uint8_t *rgba, size_t stride, size_t x, size_t y) {
    size_t ratio = 4 / factor, plane = size * size;
    float divisor = (float)(ratio * ratio);
    for (size_t row = 0; row < keep_height * factor; ++row) {
        uint8_t *out = rgba + (y + row) * stride + x * 4;
        for (size_t column = 0; column < keep_width * factor; ++column) {
            for (size_t c = 0; c < 3; ++c) {
                float sum = 0;
                for (size_t dy = 0; dy < ratio; ++dy) {
                    const float *source = planar + c * plane + (margin + row * ratio + dy) * size + margin + column * ratio;
                    for (size_t dx = 0; dx < ratio; ++dx) sum += source[dx];
                }
                out[column * 4 + c] = (uint8_t)fminf(255, fmaxf(0, roundf(sum / divisor * 255)));
            }
            out[column * 4 + 3] = 255;
        }
    }
}

typedef struct { uint8_t *rgba; size_t stride; const uint8_t *alpha; size_t alpha_stride, width; } AlphaRows;

static void alpha_row(void *context, size_t y) {
    const AlphaRows *a = context;
    uint8_t *row = a->rgba + y * a->stride;
    const uint8_t *coverage = a->alpha + y * a->alpha_stride;
    for (size_t x = 0; x < a->width; ++x) {
        unsigned value = coverage[x];
        for (int c = 0; c < 3; ++c) row[x * 4 + (size_t)c] = (uint8_t)((row[x * 4 + (size_t)c] * value + 127) / 255);
        row[x * 4 + 3] = (uint8_t)value;
    }
}

void esrgan_apply_alpha(uint8_t *rgba, size_t stride, const uint8_t *alpha, size_t alpha_stride,
                        size_t width, size_t height) {
    AlphaRows rows = {rgba, stride, alpha, alpha_stride, width};
    dispatch_apply_f(height, DISPATCH_APPLY_AUTO, &rows, alpha_row);
}
