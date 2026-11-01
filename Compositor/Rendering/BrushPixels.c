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

#include <math.h>

static uint8_t brush_density_byte(float density, float cap) {
    float alpha = fminf(1 - expf(-density), cap);
    return (uint8_t)roundf(fminf(1, fmaxf(0, alpha)) * 255);
}
double brush_tip_falloff(double u) {
    const double edge = exp(-2.5);
    return fmax(0, (exp(-2.5 * u * u) - edge) / (1 - edge));
}
void brush_density_bytes(uint8_t *gray, size_t stride, const float *density, const float *cap, size_t width, size_t height) {
    for (size_t y = 0; y < height; ++y)
        for (size_t x = 0; x < width; ++x) {
            size_t i = y * width + x;
            gray[y * stride + x] = brush_density_byte(density[i], cap ? cap[i] : 1);
        }
}
static float shape_pixel(const uint8_t *tip, size_t side, int x, int y) {
    return x < 0 || y < 0 || x >= (int)side || y >= (int)side ? 0 : tip[y * side + x] / 255.0f;
}
static float shape_sample(const uint8_t *tip, size_t side, float u, float v, int filtering,
                          float hardness, float ux, float uy, float vx, float vy) {
    if (!isfinite(u) || !isfinite(v)) return 0;
    if (tip) {
        if (!side || fabsf(u) > 1 + 2.0f / side || fabsf(v) > 1 + 2.0f / side) return 0;
        float x = (u + 1) * side / 2 - 0.5f, y = (v + 1) * side / 2 - 0.5f;
        if (!filtering) return shape_pixel(tip, side, (int)floorf(x + 0.5f), (int)floorf(y + 0.5f));
        int ix = (int)floorf(x), iy = (int)floorf(y);
        float fx = x - ix, fy = y - iy;
        return (1 - fy) * ((1 - fx) * shape_pixel(tip, side, ix, iy) + fx * shape_pixel(tip, side, ix + 1, iy))
            + fy * ((1 - fx) * shape_pixel(tip, side, ix, iy + 1) + fx * shape_pixel(tip, side, ix + 1, iy + 1));
    }
    float r = sqrtf(u * u + v * v);
    if (hardness < 1) {
        float t = fmaxf(0, (r - hardness) / (1 - hardness));
        return t < 1 ? (float)brush_tip_falloff(t) : 0;
    }
    if (!filtering) return r <= 1 ? 1 : 0;
    float aa = fmaxf(0.000001f, (fabsf(u * ux + v * vx) + fabsf(u * uy + v * vy)) / fmaxf(r, 0.000001f));
    return fminf(1, fmaxf(0, (1 - r) / aa + 0.5f));
}
static float combined_sample(const uint8_t *tip, size_t side, const uint8_t *second, size_t secondSide,
                             float scale, int classic, float u, float v, int filtering, float hardness,
                             float ux, float uy, float vx, float vy) {
    float a = shape_sample(tip, side, u, v, filtering, hardness, ux, uy, vx, vy);
    if (!second) return a;
    float b = shape_sample(second, secondSide, u / scale, v / scale, filtering, 1, ux / scale, uy / scale, vx / scale, vy / scale);
    return classic ? a + b - a * b : a * b;
}
static float grain_pixel(const uint8_t *grain, size_t side, int x, int y) {
    int n = (int)side;
    return grain[((y % n + n) % n) * n + (x % n + n) % n] / 255.0f;
}
static float grain_sample(const uint8_t *grain, size_t side, double u, double v, int filtering) {
    double x = (u - floor(u)) * side, y = (v - floor(v)) * side;
    int ix = (int)floor(x), iy = (int)floor(y);
    if (!filtering) return grain_pixel(grain, side, ix, iy);
    double fx = x - ix, fy = y - iy;
    return (1-fy) * ((1-fx)*grain_pixel(grain,side,ix,iy)+fx*grain_pixel(grain,side,ix+1,iy))
        + fy * ((1-fx)*grain_pixel(grain,side,ix,iy+1)+fx*grain_pixel(grain,side,ix+1,iy+1));
}
void brush_render_stamp(float *density, float *cap, float *pigment, float *edges, size_t width,
                       size_t x0, size_t y0, size_t x1, size_t y1,
                       float u0, float v0, float ux, float uy, float vx, float vy,
                       float hardness, float flow, float strength, const uint8_t *tipMask, size_t side, int filtering,
                       int mode, float wet, float red, float green, float blue, const uint8_t *second, size_t secondSide, float scale, int classic, const uint8_t *grain, size_t grainSide, const double *g) {
    const float color[] = {red, green, blue};
    const float gains[] = {1, 0.35f, 0.5f, 1.5f, 3, 1, 2};
    float gain = gains[mode >= 0 && mode <= 6 ? mode : 0];
    for (size_t y = y0; y < y1; ++y) {
        for (size_t x = x0; x < x1; ++x) {
            size_t i = y * width + x;
            if (!pigment && (!edges || edges[i] >= 32) && density[i] >= 32 && (!cap || cap[i] >= strength)) continue;
            float u = u0 + (float)x * ux + (float)y * uy;
            float v = v0 + (float)x * vx + (float)y * vy;
            float tip = 0;
            int samples = filtering == 2 ? 4 : 1;
            for (int k = 0; k < samples; ++k) {
                float su = u, sv = v;
                if (samples == 4) {
                    int sx = (k & 1) ? 1 : -1, sy = (k & 2) ? 1 : -1;
                    su += 0.25f * (sx * ux + sy * uy); sv += 0.25f * (sx * vx + sy * vy);
                }
                int filter = filtering ? 1 : 0;
                float t = combined_sample(tipMask, side, second, secondSide, scale, classic, su, sv, filter, hardness, ux, uy, vx, vy);
                if (wet > 0) {
                    float spread = 0.2f * wet;
                    float blurred = t;
                    blurred += combined_sample(tipMask, side, second, secondSide, scale, classic, su + spread, sv, filter, hardness, ux, uy, vx, vy);
                    blurred += combined_sample(tipMask, side, second, secondSide, scale, classic, su - spread, sv, filter, hardness, ux, uy, vx, vy);
                    blurred += combined_sample(tipMask, side, second, secondSide, scale, classic, su, sv + spread, filter, hardness, ux, uy, vx, vy);
                    blurred += combined_sample(tipMask, side, second, secondSide, scale, classic, su, sv - spread, filter, hardness, ux, uy, vx, vy);
                    t = t * (1 - wet) + blurred * (wet / 5);
                }
                tip += t / samples;
            }
            if (tip <= 0) continue;
            float pixelStrength = strength;
            if (grain && grainSide && g) {
                double gu = g[0] + x*g[2] + y*g[3], gv = g[1] + x*g[4] + y*g[5];
                float texture = grain_sample(grain, grainSide, gu, gv, (int)g[10]);
                if (g[10] == 2) {
                    texture = 0;
                    for (int k=0;k<4;++k) texture += 0.25f * grain_sample(grain,grainSide,
                        gu + 0.25f*((k&1?1:-1)*g[2]+(k&2?1:-1)*g[3]),
                        gv + 0.25f*((k&1?1:-1)*g[4]+(k&2?1:-1)*g[5]),1);
                }
                texture = fminf(1,fmaxf(0,(texture-0.5f)*(g[8] >= 0 ? 1+3*g[8] : 1+g[8])+0.5f+g[7]));
                float factor = g[9] == 1 ? (1+texture)*0.5f : g[9] == 2 ? fminf(1,2*texture) : g[9] == 3 ? 1-texture : texture;
                float coverage = 1-g[6]+g[6]*factor;
                tip *= coverage;
                if (g[11] == 1) pixelStrength *= coverage;
            }
            float ink = -log1pf(-fminf(0.999999f, flow * tip)) * gain;
            float before = density[i];
            density[i] = fminf(32, mode == 1 ? fmaxf(before, ink) : before + ink);
            if (pigment && before + ink > 0) {
                float total = before + ink;
                for (int c = 0; c < 3; ++c) pigment[3 * i + c] = (pigment[3 * i + c] + ink * color[c]) * density[i] / total;
            }
            if (edges) edges[i] = fminf(32, edges[i] + flow * 4 * tip * (1 - tip));
            if (cap) cap[i] = fmaxf(cap[i], pixelStrength);
        }
    }
}
void brush_round_stamp(float *density, float *cap, size_t width,
                       size_t x0, size_t y0, size_t x1, size_t y1,
                       float u0, float v0, float ux, float uy, float vx, float vy,
                       float hardness, float flow, float strength, const uint8_t *tipMask, size_t side, int filtering) {
    brush_render_stamp(density, cap, NULL, NULL, width, x0, y0, x1, y1, u0, v0, ux, uy, vx, vy,
                       hardness, flow, strength, tipMask, side, filtering, 0, 0, 0, 0, 0, NULL, 0, 1, 0, NULL, 0, NULL);
}

void brush_render_pixels(uint8_t *rgba, uint8_t *rim, uint8_t *gray, size_t count,
                         const float *density, const float *cap, const float *pigment, const float *edges,
                         float red, float green, float blue, float opacity, float burnt, float threshold) {
    const float foreground[] = {red, green, blue};
    for (size_t i = 0; i < count; ++i) {
        float a = fminf(1 - expf(-density[i]), cap ? cap[i] : 1) * opacity;
        if (threshold >= 0) a = a > 0 && a >= threshold ? 1 : 0;
        uint8_t alpha = (uint8_t)roundf(fminf(1, fmaxf(0, a)) * 255);
        if (gray) gray[i] = alpha;
        if (!rgba) continue;
        float edgeAlpha = edges ? burnt * (1 - expf(-edges[i])) * a : 0;
        for (int c = 0; c < 3; ++c) {
            float color = pigment && density[i] > 0 ? pigment[3 * i + c] / density[i] : foreground[c];
            color = fminf(1, fmaxf(0, color));
            rgba[4 * i + c] = (uint8_t)roundf(color * a * 255);
            if (rim) rim[4 * i + c] = (uint8_t)roundf(color * 0.5f * edgeAlpha * 255);
        }
        rgba[4 * i + 3] = alpha;
        if (rim) rim[4 * i + 3] = (uint8_t)roundf(edgeAlpha * 255);
    }
}
