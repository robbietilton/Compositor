#include "BrushPixels.h"

void brush_alpha_bounds(const uint8_t *bytes, size_t width, size_t height, size_t stride, size_t bounds[4]) {
    size_t left = width, right = 0, top = height, bottom = 0;
    for (size_t y = 0; y < height; ++y) {
        const uint8_t *row = bytes + y * stride;
        size_t first = 0;
        while (first < width && row[first * 4 + 3] == 0) ++first;
        if (first == width) continue;
        size_t last = width;
        while (last > first && row[(last - 1) * 4 + 3] == 0) --last;
        if (first < left) left = first;
        if (last > right) right = last;
        if (y < top) top = y;
        bottom = y + 1;
    }
    bounds[0] = right ? left : 0;
    bounds[1] = right ? top : 0;
    bounds[2] = right;
    bounds[3] = bottom;
}

void layer_unpremultiply_opaque(uint8_t *rgba, size_t stride, size_t width, size_t height) {
    for (size_t y = 0; y < height; ++y) {
        uint8_t *p = rgba + y * stride;
        for (size_t x = 0; x < width; ++x, p += 4) {
            unsigned a = p[3];
            for (int c = 0; c < 3; ++c) {
                unsigned v = a ? (p[c] * 255u + a / 2) / a : 0;
                p[c] = v > 255 ? 255 : v;
            }
            p[3] = 255;
        }
    }
}
void layer_restore_alpha(uint8_t *rgba, size_t stride, const uint8_t *alpha, size_t alphaStride, size_t width, size_t height) {
    for (size_t y = 0; y < height; ++y) {
        uint8_t *p = rgba + y * stride;
        for (size_t x = 0; x < width; ++x, p += 4) {
            unsigned a = alpha[y * alphaStride + x];
            for (int c = 0; c < 3; ++c) p[c] = (p[c] * a + 127) / 255;
            p[3] = a;
        }
    }
}
void layer_extract_alpha(const uint8_t *rgba, size_t rgbaStride, uint8_t *gray, size_t grayStride, size_t width, size_t height) {
    for (size_t y = 0; y < height; ++y)
        for (size_t x = 0; x < width; ++x)
            gray[y * grayStride + x] = rgba[y * rgbaStride + x * 4 + 3];
}

void brush_tone(uint8_t *rgba, size_t width, size_t height, size_t stride, int lightens, int range, double strength) {
    if (strength <= 0) return;
    // The move for each brightness, in 65536ths: the weight falls off gradually, so the range leaves no edge.
    int32_t gain[256];
    for (int level = 0; level < 256; ++level) {
        double l = level / 255.0;
        // Shadows fade out by middle gray and highlights fade in from it; midtones peak there and ease off both ways.
        double dark = l >= 0.5 ? 0 : 1 - l / 0.5, light = l <= 0.5 ? 0 : (l - 0.5) / 0.5, middle = 4 * l * (1 - l);
        double weight = range == 0 ? dark * dark * (3 - 2 * dark) : range == 2 ? light * light * (3 - 2 * light) : middle * middle;
        gain[level] = (int32_t)(strength * weight * 65536 + 0.5);
    }
    for (size_t y = 0; y < height; ++y) {
        uint8_t *p = rgba + y * stride;
        for (size_t x = 0; x < width; ++x, p += 4) {
            unsigned alpha = p[3];
            if (alpha == 0) continue;
            int color[3];
            for (int c = 0; c < 3; ++c) {
                unsigned value = alpha == 255 ? p[c] : (p[c] * 255u + alpha / 2) / alpha;
                color[c] = value > 255 ? 255 : (int)value;
            }
            int32_t g = gain[(54 * color[0] + 183 * color[1] + 19 * color[2] + 128) >> 8];
            if (g == 0) continue;
            for (int c = 0; c < 3; ++c) {
                int toward = lightens ? 255 - color[c] : -color[c];
                int moved = color[c] + (int)(((int64_t)g * toward + 32768) >> 16);
                if (moved < 0) moved = 0;
                if (moved > 255) moved = 255;
                p[c] = alpha == 255 ? (uint8_t)moved : (uint8_t)((moved * alpha + 127u) / 255u);
            }
        }
    }
}
