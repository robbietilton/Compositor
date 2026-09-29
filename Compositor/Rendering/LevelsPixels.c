#include "LevelsPixels.h"
#include <math.h>
void levels_apply(uint8_t *pixels, size_t count, const float *tables) {
    for (size_t i=0; i<count; ++i) {
        uint8_t *p = pixels + i*4;
        float alpha = p[3];
        if (!alpha) continue;
        for (int channel=0; channel<3; ++channel) {
            float x = fminf(255, p[channel]*255.0f/alpha);
            int lo = (int)x, hi = lo < 255 ? lo+1 : 255;
            const float *table = tables + channel*256;
            float result = table[lo] + (table[hi]-table[lo])*(x-lo);
            p[channel] = (uint8_t)fminf(alpha, fmaxf(0, roundf(result*alpha)));
        }
    }
}
void levels_histogram(const uint8_t *pixels, const uint8_t *coverage, size_t count, double *bins) {
    for (size_t i=0; i<count; ++i) {
        const uint8_t *p = pixels+i*4;
        if (!p[3]) continue;
        double weight = p[3]/255.0 * (coverage ? coverage[i]/255.0 : 1);
        for (int channel=0; channel<3; ++channel) {
            int value = (int)fmin(255, round(p[channel]*255.0/p[3]));
            bins[(channel+1)*256+value] += weight;
            bins[value] += weight/3.0;
        }
    }
}
/// A color lookup through `cube` (`dimension`³ RGBA entries, red varying fastest), blended between the eight nearest
/// entries, on unpremultiplied colors; alpha is kept.
void cube_apply(uint8_t *pixels, size_t count, const float *cube, int dimension) {
    const float scale = (dimension - 1) / 255.0f;
    const size_t dy = dimension, dz = (size_t)dimension * dimension;
    for (size_t i=0; i<count; ++i) {
        uint8_t *p = pixels + i*4;
        float alpha = p[3];
        if (!alpha) continue;
        float position[3], fraction[3];
        int lo[3];
        for (int channel=0; channel<3; ++channel) {
            position[channel] = fminf(255, p[channel]*255.0f/alpha) * scale;
            lo[channel] = (int)position[channel];
            if (lo[channel] > dimension - 2) lo[channel] = dimension - 2;
            fraction[channel] = position[channel] - lo[channel];
        }
        const float *base = cube + ((size_t)lo[0] + lo[1]*dy + lo[2]*dz) * 4;
        const size_t sx = 4, sy = dy*4, sz = dz*4;
        for (int channel=0; channel<3; ++channel) {
            const float *c = base + channel;
            float x00 = c[0] + (c[sx] - c[0]) * fraction[0];
            float x10 = c[sy] + (c[sy+sx] - c[sy]) * fraction[0];
            float x01 = c[sz] + (c[sz+sx] - c[sz]) * fraction[0];
            float x11 = c[sz+sy] + (c[sz+sy+sx] - c[sz+sy]) * fraction[0];
            float y0 = x00 + (x10 - x00) * fraction[1];
            float y1 = x01 + (x11 - x01) * fraction[1];
            float result = y0 + (y1 - y0) * fraction[2];
            p[channel] = (uint8_t)fminf(alpha, fmaxf(0, roundf(result*alpha)));
        }
    }
}
