#include "AdjustPixels.h"
#include "LensPixels.h"
#include <dispatch/dispatch.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

// Runs `body` over `count` items split into a few runs per core, each a (start, end) range, all at once.
static void in_bands(size_t count, void (^body)(size_t start, size_t end)) {
    size_t bands = count < 64 ? 1 : 32, size = (count + bands - 1) / bands;
    dispatch_apply(bands, DISPATCH_APPLY_AUTO, ^(size_t band) {
        size_t start = band * size, end = start + size < count ? start + size : count;
        if (start < end) body(start, end);
    });
}

void adjust_gradient_map(uint8_t *rgba, size_t width, size_t height, size_t stride, const uint8_t *table) {
    for (size_t y = 0; y < height; y++) {
        uint8_t *p = rgba + y * stride;
        for (size_t x = 0; x < width; x++, p += 4) {
            unsigned a = p[3];
            if (a == 0) continue;
            unsigned r = p[0], g = p[1], b = p[2];
            if (a < 255) {
                r = (r * 255u + a / 2) / a;
                g = (g * 255u + a / 2) / a;
                b = (b * 255u + a / 2) / a;
                if (r > 255) r = 255;
                if (g > 255) g = 255;
                if (b > 255) b = 255;
            }
            unsigned level = (2126u * r + 7152u * g + 722u * b + 5000u) / 10000u;
            const uint8_t *color = table + (level > 255 ? 255 : level) * 3;
            p[0] = (uint8_t)((color[0] * a + 127u) / 255u);
            p[1] = (uint8_t)((color[1] * a + 127u) / 255u);
            p[2] = (uint8_t)((color[2] * a + 127u) / 255u);
        }
    }
}

static inline uint32_t mix32(uint32_t x) {
    x ^= x >> 16;
    x *= 0x7feb352dU;
    x ^= x >> 15;
    x *= 0x846ca68bU;
    x ^= x >> 16;
    return x;
}

// A value in −1…1 for an integer lattice point, fixed by the point and the seed. Two uniform halves
// summed give a triangular spread, closer to film grain than flat noise.
static inline float lattice(int64_t ix, int64_t iy, uint32_t seed) {
    uint32_t h = mix32((uint32_t)ix * 0x9E3779B1U ^ mix32((uint32_t)iy * 0x85EBCA77U ^ seed));
    return (float)(h & 0xFFFFU) / 65535.0f + (float)(h >> 16) / 65535.0f - 1.0f;
}

// Smooth seeded noise whose features follow `scale` document pixels. Keeping both the broad and
// detailed patterns relative to the requested grain size makes Size remain visible at any Roughness.
static inline float grain_field(double u, double v, double scale, uint32_t seed) {
    double cellX = floor(u / scale), cellY = floor(v / scale);
    float tx = (float)(u / scale - cellX), ty = (float)(v / scale - cellY);
    tx = tx * tx * (3.0f - 2.0f * tx);
    ty = ty * ty * (3.0f - 2.0f * ty);
    int64_t ix = (int64_t)cellX, iy = (int64_t)cellY;
    float n00 = lattice(ix, iy, seed), n10 = lattice(ix + 1, iy, seed);
    float n01 = lattice(ix, iy + 1, seed), n11 = lattice(ix + 1, iy + 1, seed);
    float top = n00 + (n10 - n00) * tx, bottom = n01 + (n11 - n01) * tx;
    // Blending neighboring lattice values narrows the spread; restore approximately its original range.
    return (top + (bottom - top) * ty) * 1.6f;
}

static inline float clamp255(float value) { return value < 0 ? 0 : value > 255 ? 255 : value; }

void adjust_grain(uint8_t *rgba, size_t width, size_t height, size_t stride, double amount, double size,
                  double roughness, uint32_t seed, double originX, double originY, double unitsPerPixel) {
    if (!(amount > 0) || !(unitsPerPixel > 0)) return;
    if (!(size > 0)) size = 1;
    float strength = (float)(amount > 100 ? 1.0 : amount / 100.0) * 0.35f * 255.0f;
    float rough = (float)(roughness < 0 ? 0.0 : roughness > 100 ? 1.0 : roughness / 100.0);
    uint32_t fineSeed = mix32(seed ^ 0xA511E9B3U);
    // Roughness adds smaller, less regular particles, as in Photoshop, but their size remains
    // proportional to the Size control instead of collapsing to fixed one-pixel noise.
    double detailSize = fmax(0.5, size * 0.35);
    for (size_t y = 0; y < height; y++) {
        double v = originY + ((double)y + 0.5) * unitsPerPixel;
        uint8_t *p = rgba + y * stride;
        for (size_t x = 0; x < width; x++, p += 4) {
            unsigned a = p[3];
            if (a == 0) continue;
            double u = originX + ((double)x + 0.5) * unitsPerPixel;
            float smooth = grain_field(u, v, size, seed);
            float fine = grain_field(u, v, detailSize, fineSeed);
            float noise = smooth + (fine - smooth) * rough;
            float unpremultiply = a == 255 ? 1.0f : 255.0f / (float)a;
            float r = p[0] * unpremultiply, g = p[1] * unpremultiply, b = p[2] * unpremultiply;
            float level = (0.2126f * r + 0.7152f * g + 0.0722f * b) / 255.0f;
            if (level > 1) level = 1;
            // Film grain shows most in the midtones.
            float delta = noise * strength * (0.4f + 2.4f * level * (1.0f - level));
            float coverage = (float)a / 255.0f;
            p[0] = (uint8_t)(clamp255(r + delta) * coverage + 0.5f);
            p[1] = (uint8_t)(clamp255(g + delta) * coverage + 0.5f);
            p[2] = (uint8_t)(clamp255(b + delta) * coverage + 0.5f);
        }
    }
}

void rgba_clamp_premultiplied(uint8_t *rgba, size_t count) {
    for (size_t i = 0; i < count; i++, rgba += 4) {
        uint8_t a = rgba[3];
        if (rgba[0] > a) rgba[0] = a;
        if (rgba[1] > a) rgba[1] = a;
        if (rgba[2] > a) rgba[2] = a;
    }
}

/// Which of the six ranges a color's primary and secondary fall in, and how much of each it holds.
/// A color is min(r,g,b) of gray, plus (mid-min) of the secondary between its two brightest channels,
/// plus (max-mid) of the primary of its brightest — so the weights below are exactly Photoshop's.
void adjust_black_white(uint8_t *rgba, size_t width, size_t height, size_t stride, const float *weights,
                        int tint, double tintHue, double tintSaturation) {
    for (size_t y = 0; y < height; ++y) {
        uint8_t *row = rgba + y * stride;
        for (size_t x = 0; x < width; ++x) {
            uint8_t *p = row + x * 4;
            float alpha = p[3];
            if (!alpha) continue;
            float r = p[0] * 255.0f / alpha, g = p[1] * 255.0f / alpha, b = p[2] * 255.0f / alpha;
            r = fminf(255.0f, r) / 255.0f; g = fminf(255.0f, g) / 255.0f; b = fminf(255.0f, b) / 255.0f;
            float mx = fmaxf(r, fmaxf(g, b)), mn = fminf(r, fminf(g, b));
            float md = r + g + b - mx - mn;
            // weights: 0 red, 1 yellow, 2 green, 3 cyan, 4 blue, 5 magenta
            int primary, secondary;
            if (mx == r)      { primary = 0; secondary = (g >= b) ? 1 : 5; }
            else if (mx == g) { primary = 2; secondary = (r >= b) ? 1 : 3; }
            else              { primary = 4; secondary = (g >= r) ? 3 : 5; }
            float gray = mn + (md - mn) * weights[secondary] + (mx - md) * weights[primary];
            gray = fminf(1.0f, fmaxf(0.0f, gray));
            float outR = gray, outG = gray, outB = gray;
            if (tint && tintSaturation > 0) {
                // The gray becomes the lightness of a color at the chosen hue.
                double c = (1.0 - fabs(2.0 * gray - 1.0)) * tintSaturation;
                double hp = fmod(tintHue, 360.0) / 60.0;
                double xx = c * (1.0 - fabs(fmod(hp, 2.0) - 1.0));
                double r1 = 0, g1 = 0, b1 = 0;
                if (hp < 1)      { r1 = c; g1 = xx; }
                else if (hp < 2) { r1 = xx; g1 = c; }
                else if (hp < 3) { g1 = c; b1 = xx; }
                else if (hp < 4) { g1 = xx; b1 = c; }
                else if (hp < 5) { r1 = xx; b1 = c; }
                else             { r1 = c; b1 = xx; }
                double m = gray - c / 2.0;
                outR = (float)fmin(1.0, fmax(0.0, r1 + m));
                outG = (float)fmin(1.0, fmax(0.0, g1 + m));
                outB = (float)fmin(1.0, fmax(0.0, b1 + m));
            }
            p[0] = (uint8_t)fminf(alpha, fmaxf(0.0f, roundf(outR * alpha)));
            p[1] = (uint8_t)fminf(alpha, fmaxf(0.0f, roundf(outG * alpha)));
            p[2] = (uint8_t)fminf(alpha, fmaxf(0.0f, roundf(outB * alpha)));
        }
    }
}

/// How much a tone belongs to the shadows, midtones and highlights: three overlapping curves that sum
/// to about one across the range, so a shift fades in and out rather than banding at a threshold.
static void tonal_weights(float v, float *shadow, float *mid, float *highlight) {
    const float a = 0.25f, b = 0.333f, scale = 0.7f;
    float s = (v - b) / -a + 0.5f;
    float h = (v + b - 1.0f) / a + 0.5f;
    s = fminf(1.0f, fmaxf(0.0f, s));
    h = fminf(1.0f, fmaxf(0.0f, h));
    float m1 = fminf(1.0f, fmaxf(0.0f, (v - b) / a + 0.5f));
    float m2 = fminf(1.0f, fmaxf(0.0f, (v + b - 1.0f) / -a + 0.5f));
    *shadow = s * scale;
    *mid = m1 * m2 * scale;
    *highlight = h * scale;
}

void adjust_color_balance(uint8_t *rgba, size_t width, size_t height, size_t stride, const float *shadows,
                          const float *midtones, const float *highlights, int preserveLuminosity) {
    for (size_t y = 0; y < height; ++y) {
        uint8_t *row = rgba + y * stride;
        for (size_t x = 0; x < width; ++x) {
            uint8_t *p = row + x * 4;
            float alpha = p[3];
            if (!alpha) continue;
            float c[3];
            for (int i = 0; i < 3; ++i) c[i] = fminf(255.0f, p[i] * 255.0f / alpha) / 255.0f;
            float before = 0.299f * c[0] + 0.587f * c[1] + 0.114f * c[2];
            for (int i = 0; i < 3; ++i) {
                float s, m, h;
                tonal_weights(c[i], &s, &m, &h);
                c[i] += shadows[i] * s + midtones[i] * m + highlights[i] * h;
                c[i] = fminf(1.0f, fmaxf(0.0f, c[i]));
            }
            if (preserveLuminosity) {
                float after = 0.299f * c[0] + 0.587f * c[1] + 0.114f * c[2];
                if (after > 0.0001f) {
                    float ratio = before / after;
                    for (int i = 0; i < 3; ++i) c[i] = fminf(1.0f, fmaxf(0.0f, c[i] * ratio));
                }
            }
            for (int i = 0; i < 3; ++i) p[i] = (uint8_t)fminf(alpha, fmaxf(0.0f, roundf(c[i] * alpha)));
        }
    }
}

static double camera_clamp(double value) {
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
}

static double srgb_decode(double encoded) {
    return encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4);
}

static double srgb_encode(double linear) {
    if (linear <= 0) return 0;
    if (linear >= 1) return 1;
    return linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1.0 / 2.4) - 0.055;
}

static double rec709(double r, double g, double b) {
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

// Moves r, g, b so their Rec. 709 luminance becomes `target`, keeping the hue. Pure black cannot
// be scaled, so a lift paints neutral light of that luminance.
static void scale_luminance(double *r, double *g, double *b, double target) {
    target = camera_clamp(target);
    double y = rec709(*r, *g, *b);
    if (fabs(target - y) < 1e-8) return;
    if (y < 1e-8) {
        if (target > y) *r = *g = *b = target;
        return;
    }
    double scale = target / y;
    *r = camera_clamp(*r * scale);
    *g = camera_clamp(*g * scale);
    *b = camera_clamp(*b * scale);
}

// A measured table's color for an sRGB color (0…1), between its eight nearest entries.
static void table_lookup(const uint8_t *table, int size, const double in[3], double out[3]) {
    double f[3];
    int i[3];
    for (int c = 0; c < 3; ++c) {
        double x = camera_clamp(in[c]) * (size - 1);
        i[c] = x >= size - 1 ? size - 2 : (int)x;
        f[c] = x - i[c];
    }
    out[0] = out[1] = out[2] = 0;
    for (int corner = 0; corner < 8; ++corner) {
        int dr = corner >> 2, dg = (corner >> 1) & 1, db = corner & 1;
        double w = (dr ? f[0] : 1 - f[0]) * (dg ? f[1] : 1 - f[1]) * (db ? f[2] : 1 - f[2]);
        if (w == 0) continue;
        const uint8_t *p = table + (((size_t)(i[0] + dr) * size + (i[1] + dg)) * size + (i[2] + db)) * 3;
        out[0] += w * p[0];
        out[1] += w * p[1];
        out[2] += w * p[2];
    }
    out[0] /= 255.0;
    out[1] /= 255.0;
    out[2] /= 255.0;
}

void camera_raw_compose(float *out, int grid, const CameraRawStage *stages, int count, int size) {
    in_bands((size_t)grid, ^(size_t first, size_t last) { for (int r = (int)first; r < (int)last; ++r) {
        for (int g = 0; g < grid; ++g) {
            for (int b = 0; b < grid; ++b) {
                double color[3] = {(double)r / (grid - 1), (double)g / (grid - 1), (double)b / (grid - 1)};
                for (int s = 0; s < count; ++s) camera_raw_stage_color(&stages[s], size, color);
                float *o = out + (((size_t)r * grid + g) * grid + b) * 3;
                o[0] = (float)color[0];
                o[1] = (float)color[1];
                o[2] = (float)color[2];
            }
        }
    } });
}

void camera_raw_compose_onto(float *table, int grid, const CameraRawStage *stages, int count, int size) {
    if (count <= 0) return;
    size_t entries = (size_t)grid * grid * grid;
    in_bands(entries, ^(size_t first, size_t last) {
        for (size_t i = first; i < last; ++i) {
            double color[3] = {table[i * 3], table[i * 3 + 1], table[i * 3 + 2]};
            for (int s = 0; s < count; ++s) camera_raw_stage_color(&stages[s], size, color);
            table[i * 3] = (float)color[0];
            table[i * 3 + 1] = (float)color[1];
            table[i * 3 + 2] = (float)color[2];
        }
    });
}

void camera_raw_stage_color(const CameraRawStage *stage, int size, double *rgb) {
    double next[3] = {0, 0, 0};
    for (int t = 0; t < 8; ++t) {
        double w = stage->weight[t];
        if (w == 0) continue;
        double looked[3];
        if (stage->table[t]) table_lookup(stage->table[t], size, rgb, looked);
        else memcpy(looked, rgb, sizeof looked);
        for (int c = 0; c < 3; ++c) next[c] += w * looked[c];
    }
    for (int c = 0; c < 3; ++c) rgb[c] = camera_clamp(next[c]);
}

// A composed table's color for an sRGB color, between its eight nearest entries.
static void composed_lookup(const float *table, int grid, double *r, double *g, double *b) {
    double in[3] = {*r, *g, *b}, f[3], out[3] = {0, 0, 0};
    int i[3];
    for (int c = 0; c < 3; ++c) {
        double x = camera_clamp(in[c]) * (grid - 1);
        i[c] = x >= grid - 1 ? grid - 2 : (int)x;
        f[c] = x - i[c];
    }
    for (int corner = 0; corner < 8; ++corner) {
        int dr = corner >> 2, dg = (corner >> 1) & 1, db = corner & 1;
        double w = (dr ? f[0] : 1 - f[0]) * (dg ? f[1] : 1 - f[1]) * (db ? f[2] : 1 - f[2]);
        if (w == 0) continue;
        const float *p = table + (((size_t)(i[0] + dr) * grid + (i[1] + dg)) * grid + (i[2] + db)) * 3;
        out[0] += w * p[0];
        out[1] += w * p[1];
        out[2] += w * p[2];
    }
    *r = camera_clamp(out[0]);
    *g = camera_clamp(out[1]);
    *b = camera_clamp(out[2]);
}

static void write_premultiplied(uint8_t *p, double r, double g, double b, double alpha) {
    p[0] = (uint8_t)fmin(alpha, fmax(0.0, round(r * alpha)));
    p[1] = (uint8_t)fmin(alpha, fmax(0.0, round(g * alpha)));
    p[2] = (uint8_t)fmin(alpha, fmax(0.0, round(b * alpha)));
}

void camera_raw_statistics(const uint8_t *rgba, size_t width, size_t height, size_t stride, double *out) {
    enum { bands = 32 };
    double sums[bands][4];
    memset(sums, 0, sizeof sums);
    double decoded[256];
    for (int i = 0; i < 256; ++i) decoded[i] = srgb_decode(i / 255.0);
    double (*parts)[4] = sums;
    const double *decode = decoded;
    size_t rows = (height + bands - 1) / bands;
    dispatch_apply(bands, DISPATCH_APPLY_AUTO, ^(size_t band) {
        double brightest = 0, luminance = 0, logBrightest = 0, weight = 0;
        size_t end = (band + 1) * rows < height ? (band + 1) * rows : height;
        for (size_t y = band * rows; y < end; ++y) {
            const uint8_t *row = rgba + y * stride;
            for (size_t x = 0; x < width; ++x) {
                const uint8_t *p = row + x * 4;
                double alpha = p[3];
                if (!alpha) continue;
                double r, g, b;
                if (p[3] == 255) { r = decode[p[0]]; g = decode[p[1]]; b = decode[p[2]]; }
                else { r = srgb_decode(fmin(1.0, p[0] / alpha)); g = srgb_decode(fmin(1.0, p[1] / alpha)); b = srgb_decode(fmin(1.0, p[2] / alpha)); }
                double top = fmax(r, fmax(g, b)), w = alpha / 255.0;
                brightest += w * top;
                luminance += w * rec709(r, g, b);
                logBrightest += w * log(top + 3e-4);
                weight += w;
            }
        }
        parts[band][0] = brightest; parts[band][1] = luminance; parts[band][2] = logBrightest; parts[band][3] = weight;
    });
    double brightest = 0, luminance = 0, logBrightest = 0, weight = 0;
    for (int band = 0; band < bands; ++band) {
        brightest += sums[band][0]; luminance += sums[band][1]; logBrightest += sums[band][2]; weight += sums[band][3];
    }
    if (weight <= 0) { out[0] = out[1] = out[2] = 0.5; return; }
    out[0] = srgb_encode(brightest / weight);
    out[1] = srgb_encode(luminance / weight);
    out[2] = srgb_encode(exp(logBrightest / weight) - 3e-4);
}

void camera_raw_scope(const uint8_t *rgba, size_t width, size_t height, size_t stride, int step, double *bins, double *scope,
                      int side) {
    enum { bands = 16 };
    size_t binCount = 256 * 3, scopeCount = (size_t)side * side;
    double *parts = calloc(bands * (binCount + scopeCount), sizeof(double));
    if (!parts) return;
    size_t rows = (height + bands - 1) / bands;
    dispatch_apply(bands, DISPATCH_APPLY_AUTO, ^(size_t band) {
        double *histogram = parts + band * (binCount + scopeCount), *plot = histogram + binCount;
        size_t end = (band + 1) * rows < height ? (band + 1) * rows : height;
        for (size_t y = band * rows; y < end; y += step) {
            const uint8_t *row = rgba + y * stride;
            for (size_t x = 0; x < width; x += step) {
                const uint8_t *p = row + x * 4;
                double alpha = p[3];
                if (!alpha) continue;
                double red = fmin(1.0, p[0] / alpha), green = fmin(1.0, p[1] / alpha), blue = fmin(1.0, p[2] / alpha);
                double w = alpha / 255.0;
                histogram[(int)lround(red * 255)] += w;
                histogram[256 + (int)lround(green * 255)] += w;
                histogram[512 + (int)lround(blue * 255)] += w;
                double top = fmax(red, fmax(green, blue)), bottom = fmin(red, fmin(green, blue)), chroma = top - bottom;
                if (chroma <= 1e-4 || top <= 1e-4) continue;
                double hue = top == red ? (green - blue) / chroma : top == green ? 2 + (blue - red) / chroma : 4 + (red - green) / chroma;
                hue /= 6;
                if (hue < 0) hue += 1;
                double angle = hue * 2 * M_PI, saturation = chroma / top;
                int column = (int)((0.5 + cos(angle) * saturation * 0.48) * side), line = (int)((0.5 + sin(angle) * saturation * 0.48) * side);
                column = column < 0 ? 0 : column >= side ? side - 1 : column;
                line = line < 0 ? 0 : line >= side ? side - 1 : line;
                plot[line * side + column] += w;
            }
        }
    });
    for (int band = 0; band < bands; ++band) {
        const double *histogram = parts + band * (binCount + scopeCount);
        for (size_t i = 0; i < binCount; ++i) bins[i] += histogram[i];
        for (size_t i = 0; i < scopeCount; ++i) scope[i] += histogram[binCount + i];
    }
    free(parts);
}

void adjust_camera_raw(uint8_t *rgba, size_t width, size_t height, size_t stride, const float *table, int grid,
                       int clipping) {
    in_bands(height, ^(size_t first, size_t last) { for (size_t y = first; y < last; ++y) {
        uint8_t *row = rgba + y * stride;
        for (size_t x = 0; x < width; ++x) {
            uint8_t *p = row + x * 4;
            double alpha = p[3];
            if (!alpha) continue;
            double r = fmin(255.0, p[0] * 255.0 / alpha) / 255.0;
            double g = fmin(255.0, p[1] * 255.0 / alpha) / 255.0;
            double b = fmin(255.0, p[2] * 255.0 / alpha) / 255.0;
            if (table) composed_lookup(table, grid, &r, &g, &b);
            if (clipping == 1) {
                int rc = r >= 254.5 / 255.0, gc = g >= 254.5 / 255.0, bc = b >= 254.5 / 255.0;
                r = rc ? 1 : 0;
                g = gc ? 1 : 0;
                b = bc ? 1 : 0;
            } else if (clipping == 2) {
                int rc = r <= 0.5 / 255.0, gc = g <= 0.5 / 255.0, bc = b <= 0.5 / 255.0;
                if (rc || gc || bc) {
                    r = rc ? 0 : 1;
                    g = gc ? 0 : 1;
                    b = bc ? 0 : 1;
                } else {
                    r = g = b = 1;
                }
            }
            write_premultiplied(p, r, g, b, alpha);
        }
    } });
}

int camera_raw_lookup_is_valid(const float *table, int grid) {
    if (!table || grid != 33) return 0;
    size_t count = (size_t)grid * grid * grid * 3;
    for (size_t i = 0; i < count; ++i) {
        if (!isfinite(table[i]) || table[i] < 0 || table[i] > 1) return 0;
    }
    return 1;
}

void camera_raw_repair_lookup(uint8_t *result, const uint8_t *source, const uint8_t *uncertain,
                               size_t width, size_t height, size_t stride, const float *table, int grid) {
    in_bands(height, ^(size_t first, size_t last) { for (size_t y = first; y < last; ++y) {
        for (size_t x = 0; x < width; ++x) {
            if (!uncertain[y * width + x]) continue;
            const uint8_t *p = source + y * stride + x * 4;
            double alpha = p[3];
            if (!alpha) continue;
            double r = fmin(255.0, p[0] * 255.0 / alpha) / 255.0;
            double g = fmin(255.0, p[1] * 255.0 / alpha) / 255.0;
            double b = fmin(255.0, p[2] * 255.0 / alpha) / 255.0;
            composed_lookup(table, grid, &r, &g, &b);
            write_premultiplied(result + y * stride + x * 4, r, g, b, alpha);
        }
    } });
}

static size_t clamped_index(int index, size_t limit) {
    if (index < 0) return 0;
    if ((size_t)index >= limit) return limit - 1;
    return (size_t)index;
}

// Edge-clamped box blur. `dst` may not alias `src`. Returns 0 when the temporary row buffer cannot be allocated.
static int box_blur_plane(const float *src, float *dst, size_t width, size_t height, int radius) {
    if (radius < 1) {
        memcpy(dst, src, width * height * sizeof(float));
        return 1;
    }
    float *temp = malloc(width * height * sizeof(float));
    if (!temp) return 0;
    int window = radius * 2 + 1;
    in_bands(height, ^(size_t first, size_t last) {
        for (size_t y = first; y < last; ++y) {
            double sum = 0;
            for (int k = -radius; k <= radius; ++k) sum += src[y * width + clamped_index(k, width)];
            for (size_t x = 0; x < width; ++x) {
                temp[y * width + x] = (float)(sum / window);
                sum += src[y * width + clamped_index((int)x + radius + 1, width)];
                sum -= src[y * width + clamped_index((int)x - radius, width)];
            }
        }
    });
    in_bands(width, ^(size_t first, size_t last) {
        for (size_t x = first; x < last; ++x) {
            double sum = 0;
            for (int k = -radius; k <= radius; ++k) sum += temp[clamped_index(k, height) * width + x];
            for (size_t y = 0; y < height; ++y) {
                dst[y * width + x] = (float)(sum / window);
                sum += temp[clamped_index((int)y + radius + 1, height) * width + x];
                sum -= temp[clamped_index((int)y - radius, height) * width + x];
            }
        }
    });
    free(temp);
    return 1;
}

// An edge-aware blur (He's guided filter, the plane guiding itself): smooth within regions, stopping at edges, so
// the detail taken against it has no halos. `epsilon` is the variance an edge needs to be kept.
static int guided_filter_plane(const float *src, float *dst, size_t width, size_t height, int radius, float epsilon) {
    size_t count = width * height;
    float *mean = malloc(count * sizeof(float)), *square = malloc(count * sizeof(float));
    float *a = malloc(count * sizeof(float)), *b = malloc(count * sizeof(float));
    int ok = mean && square && a && b && box_blur_plane(src, mean, width, height, radius);
    if (ok) {
        for (size_t i = 0; i < count; ++i) a[i] = src[i] * src[i];
        ok = box_blur_plane(a, square, width, height, radius);
    }
    if (ok) {
        for (size_t i = 0; i < count; ++i) {
            float variance = square[i] - mean[i] * mean[i];
            a[i] = variance / (variance + epsilon);
            b[i] = mean[i] - a[i] * mean[i];
        }
        ok = box_blur_plane(a, mean, width, height, radius) && box_blur_plane(b, square, width, height, radius);
    }
    if (ok) for (size_t i = 0; i < count; ++i) dst[i] = mean[i] * src[i] + square[i];
    free(mean); free(square); free(a); free(b);
    return ok;
}

// The mean of each pixel's square neighborhood, `radius` either side, over the part of it inside the plane (the window
// shrinks at the edges rather than repeating them). For planes a few hundred pixels across; `dst` may not alias `src`.
static int box_mean_plane(const float *src, float *dst, size_t width, size_t height, int radius) {
    float *temp = malloc(width * height * sizeof(float));
    if (!temp) return 0;
    for (size_t y = 0; y < height; ++y) {
        const float *row = src + y * width;
        double sum = 0;
        size_t lo = 0, hi = 0;   // the window is [lo, hi)
        for (size_t x = 0; x < width; ++x) {
            size_t want_lo = x > (size_t)radius ? x - radius : 0, want_hi = x + radius + 1 < width ? x + radius + 1 : width;
            while (hi < want_hi) sum += row[hi++];
            while (lo < want_lo) sum -= row[lo++];
            temp[y * width + x] = (float)(sum / (double)(hi - lo));
        }
    }
    for (size_t x = 0; x < width; ++x) {
        double sum = 0;
        size_t lo = 0, hi = 0;
        for (size_t y = 0; y < height; ++y) {
            size_t want_lo = y > (size_t)radius ? y - radius : 0, want_hi = y + radius + 1 < height ? y + radius + 1 : height;
            while (hi < want_hi) sum += temp[hi++ * width + x];
            while (lo < want_lo) sum -= temp[lo++ * width + x];
            dst[y * width + x] = (float)(sum / (double)(hi - lo));
        }
    }
    free(temp);
    return 1;
}

// Camera Raw's Shadows, as Photoshop's Camera Raw Filter adapts it to the picture: a dark region is lifted (or, below
// zero, deepened) by how far its level sits under the picture's reference brightness, and the texture within it is
// stretched more above that level than below. The region's level is an edge-aware smoothing of log2 luminance (He's
// fast guided filter, worked on a copy about 384 pixels on its short side, so a preview and the full picture agree);
// the reference is the mean linear luminance of the pixels that differ from a neighbor, as Photoshop leaves perfectly
// flat areas out. `coefficients` are the lift Δ, the gain above and the gain below, each over K rows by x columns
// (x the region's level against the reference, K the reference, both log2), fitted to Photoshop's renders.
// Color keeps its proportions.
void adjust_camera_raw_shadows(uint8_t *rgba, size_t width, size_t height, size_t stride, const float *coefficients,
                               int xCount, float xLow, float xStep, int kCount, float kLow, float kStep) {
    if (!width || !height || xCount < 2 || kCount < 1) return;
    const double floorY = 1.0 / 8192;
    double decoded[256];
    for (int i = 0; i < 256; ++i) decoded[i] = srgb_decode(i / 255.0);
    const double *decode = decoded;
    // The reference: textured pixels, those differing from a neighbor; every pixel if none do.
    enum { bands = 32 };
    double sums[bands][4];
    memset(sums, 0, sizeof sums);
    double (*parts)[4] = sums;
    size_t rows = (height + bands - 1) / bands;
    dispatch_apply(bands, DISPATCH_APPLY_AUTO, ^(size_t band) {
        double total = 0, count = 0, all = 0, allCount = 0;
        size_t start = band * rows, end = start + rows < height ? start + rows : height;
        for (size_t y = start; y < end; ++y) {
            const uint8_t *row = rgba + y * stride;
            for (size_t x = 0; x < width; ++x) {
                const uint8_t *p = row + x * 4;
                if (!p[3]) continue;
                double alpha = p[3];
                double r = p[3] == 255 ? decode[p[0]] : srgb_decode(fmin(1.0, p[0] / alpha));
                double g = p[3] == 255 ? decode[p[1]] : srgb_decode(fmin(1.0, p[1] / alpha));
                double b = p[3] == 255 ? decode[p[2]] : srgb_decode(fmin(1.0, p[2] / alpha));
                double luminance = rec709(r, g, b);
                all += luminance; allCount += 1;
                uint8_t v = p[1];
                int textured = (x > 0 && p[-4 + 1] != v) || (x + 1 < width && p[4 + 1] != v)
                    || (y > 0 && (p - stride)[1] != v) || (y + 1 < height && (p + stride)[1] != v);
                if (textured) { total += luminance; count += 1; }
            }
        }
        parts[band][0] = total; parts[band][1] = count; parts[band][2] = all; parts[band][3] = allCount;
    });
    double total = 0, count = 0, all = 0, allCount = 0;
    for (int band = 0; band < bands; ++band) { total += sums[band][0]; count += sums[band][1]; all += sums[band][2]; allCount += sums[band][3]; }
    double key = log2(fmax(floorY, count > 0 ? total / count : allCount > 0 ? all / allCount : 0.18));

    // The smoothing's coefficients, on the small copy.
    size_t shortSide = width < height ? width : height;
    size_t scale = shortSide / 384 > 1 ? shortSide / 384 : 1;
    size_t lw = (width + scale - 1) / scale, lh = (height + scale - 1) / scale, cells = lw * lh;
    float *low = calloc(cells, sizeof(float)), *weight = calloc(cells, sizeof(float));
    float *mean = malloc(cells * sizeof(float)), *square = malloc(cells * sizeof(float));
    float *a = malloc(cells * sizeof(float)), *b = malloc(cells * sizeof(float));
    int ok = low && weight && mean && square && a && b;
    if (ok) {
        for (size_t y = 0; y < height; ++y) {
            const uint8_t *row = rgba + y * stride;
            float *lowRow = low + (y / scale) * lw, *weightRow = weight + (y / scale) * lw;
            for (size_t x = 0; x < width; ++x) {
                const uint8_t *p = row + x * 4;
                if (!p[3]) continue;
                double alpha = p[3];
                double r = p[3] == 255 ? decode[p[0]] : srgb_decode(fmin(1.0, p[0] / alpha));
                double g = p[3] == 255 ? decode[p[1]] : srgb_decode(fmin(1.0, p[1] / alpha));
                double bl = p[3] == 255 ? decode[p[2]] : srgb_decode(fmin(1.0, p[2] / alpha));
                lowRow[x / scale] += (float)log2(fmax(floorY, rec709(r, g, bl)));
                weightRow[x / scale] += 1;
            }
        }
        for (size_t i = 0; i < cells; ++i) low[i] = weight[i] > 0 ? low[i] / weight[i] : (float)key;
        size_t lowShort = lw < lh ? lw : lh;
        int radius = (int)lround(0.25 * lowShort);
        if (radius < 1) radius = 1;
        const float epsilon = 1.5f;
        ok = box_mean_plane(low, mean, lw, lh, radius);
        if (ok) {
            for (size_t i = 0; i < cells; ++i) a[i] = low[i] * low[i];
            ok = box_mean_plane(a, square, lw, lh, radius);
        }
        if (ok) {
            for (size_t i = 0; i < cells; ++i) {
                float variance = fmaxf(0, square[i] - mean[i] * mean[i]);
                a[i] = variance / (variance + epsilon);
                b[i] = mean[i] - a[i] * mean[i];
            }
            ok = box_mean_plane(a, mean, lw, lh, radius) && box_mean_plane(b, square, lw, lh, radius);
        }
    }
    if (ok) {
        const float *ma = mean, *mb = square;
        size_t plane = (size_t)xCount * (size_t)kCount;
        // The reference picks one pair of K rows for the whole picture.
        double kp = fmin(kCount - 1, fmax(0, (key - kLow) / kStep));
        int k0 = (int)kp < kCount - 1 ? (int)kp : kCount - 1, k1 = k0 + 1 < kCount ? k0 + 1 : k0;
        double kt = kp - k0;
        in_bands(height, ^(size_t first, size_t last) { for (size_t y = first; y < last; ++y) {
            double fy = fmin(lh - 1, fmax(0, (y + 0.5) / scale - 0.5));
            size_t y0 = (size_t)fy, y1 = y0 + 1 < lh ? y0 + 1 : y0;
            double ty = fy - y0;
            uint8_t *row = rgba + y * stride;
            for (size_t x = 0; x < width; ++x) {
                uint8_t *p = row + x * 4;
                double alpha = p[3];
                if (!alpha) continue;
                double r = p[3] == 255 ? decode[p[0]] : srgb_decode(fmin(1.0, p[0] / alpha));
                double g = p[3] == 255 ? decode[p[1]] : srgb_decode(fmin(1.0, p[1] / alpha));
                double bl = p[3] == 255 ? decode[p[2]] : srgb_decode(fmin(1.0, p[2] / alpha));
                double luminance = rec709(r, g, bl);
                if (luminance <= floorY) continue;
                double fx = fmin(lw - 1, fmax(0, (x + 0.5) / scale - 0.5));
                size_t x0 = (size_t)fx, x1 = x0 + 1 < lw ? x0 + 1 : x0;
                double tx = fx - x0;
                double sa = (ma[y0 * lw + x0] * (1 - tx) + ma[y0 * lw + x1] * tx) * (1 - ty) + (ma[y1 * lw + x0] * (1 - tx) + ma[y1 * lw + x1] * tx) * ty;
                double sb = (mb[y0 * lw + x0] * (1 - tx) + mb[y0 * lw + x1] * tx) * (1 - ty) + (mb[y1 * lw + x0] * (1 - tx) + mb[y1 * lw + x1] * tx) * ty;
                double level = log2(luminance), region = sa * level + sb, detail = level - region;
                double xp = fmin(xCount - 1, fmax(0, (region - key - xLow) / xStep));
                int x0c = (int)xp < xCount - 1 ? (int)xp : xCount - 2;
                double xt = xp - x0c;
                double term[3];
                for (int t = 0; t < 3; ++t) {
                    const float *c = coefficients + t * plane;
                    double row0 = c[k0 * xCount + x0c] * (1 - xt) + c[k0 * xCount + x0c + 1] * xt;
                    double row1 = c[k1 * xCount + x0c] * (1 - xt) + c[k1 * xCount + x0c + 1] * xt;
                    term[t] = row0 * (1 - kt) + row1 * kt;
                }
                double lift = term[0] + term[1] * fmax(detail, 0) + term[2] * fmin(detail, 0);
                double gain = exp2(lift);
                write_premultiplied(p, srgb_encode(r * gain), srgb_encode(g * gain), srgb_encode(bl * gain), alpha);
            }
        } });
    }
    free(low); free(weight); free(mean); free(square); free(a); free(b);
}

static int effects_radius(double base, double scale) {
    double radius = base * (scale > 0 ? scale : 1);
    if (radius < 1) radius = 1;
    if (radius > 64) radius = 64;
    return (int)lround(radius);
}

// Dehaze, after Camera Raw's: `haze` is the picture's haze color, its brightest one percent. Taking haze away
// (positive) removes it where a pixel's darkest channel, against the haze, says it lies; adding it (negative) veils the
// picture in it. Measured against Photoshop's Camera Raw Filter.
static void effects_dehaze(double *r, double *g, double *b, double amount, const double haze[3]) {
    double d = amount / 100.0, c[3] = {*r, *g, *b};
    if (d < 0) {
        double veil = 0.3 * pow(-d, 1.3);
        for (int k = 0; k < 3; ++k) c[k] = c[k] * (1 - veil) + haze[k] * veil;
    } else {
        double dark = 1;
        for (int k = 0; k < 3; ++k) dark = fmin(dark, c[k] / fmax(haze[k], 1e-3));
        double transmission = fmax(0.5, 1 - 0.7 * d * dark);
        for (int k = 0; k < 3; ++k) c[k] = (c[k] - haze[k]) / transmission + haze[k];
    }
    *r = camera_clamp(c[0]);
    *g = camera_clamp(c[1]);
    *b = camera_clamp(c[2]);
}

// The picture's haze color for Dehaze: the mean of its brightest one percent of pixels by luminance. A picture of
// one color is all haze, so Dehaze leaves it be, as Photoshop's does.
static void dehaze_haze(const uint8_t *rgba, size_t width, size_t height, size_t stride, double haze[3]) {
    double histogram[256] = {0};
    for (size_t y = 0; y < height; ++y)
        for (size_t x = 0; x < width; ++x) {
            const uint8_t *p = rgba + y * stride + x * 4;
            if (!p[3]) continue;
            int level = (int)lround(255 * rec709(fmin(1.0, (double)p[0] / p[3]), fmin(1.0, (double)p[1] / p[3]), fmin(1.0, (double)p[2] / p[3])));
            histogram[level] += p[3] / 255.0;
        }
    double total = 0;
    for (int i = 0; i < 256; ++i) total += histogram[i];
    int threshold = 255;
    for (double above = 0; threshold > 0 && above + histogram[threshold] < total * 0.01; --threshold) above += histogram[threshold];
    double sum[3] = {0, 0, 0}, weight = 0;
    for (size_t y = 0; y < height; ++y)
        for (size_t x = 0; x < width; ++x) {
            const uint8_t *p = rgba + y * stride + x * 4;
            if (!p[3]) continue;
            double c[3] = {fmin(1.0, (double)p[0] / p[3]), fmin(1.0, (double)p[1] / p[3]), fmin(1.0, (double)p[2] / p[3])};
            if (lround(255 * rec709(c[0], c[1], c[2])) < threshold) continue;
            for (int k = 0; k < 3; ++k) sum[k] += c[k] * p[3];
            weight += p[3];
        }
    for (int k = 0; k < 3; ++k) haze[k] = weight > 0 ? sum[k] / weight : 1;
}

/// The vignette's strength at a point `px`, `py` of a `width` × `height` frame (0 at its middle, 1 past its edges).
static double vignette_mask_at(double px, double py, double width, double height,
                               double midpoint, double roundness, double feather) {
    double nx = px / width * 2.0 - 1.0;
    double ny = py / height * 2.0 - 1.0;
    double square = fmax(fabs(nx), fabs(ny));
    double circle = hypot(nx, ny) / sqrt(2.0);
    double shape = (1.0 - roundness / 100.0) * 0.5;
    double dist = circle + (square - circle) * shape;
    double start = (midpoint / 100.0) * 0.85;
    double soft = feather / 100.0;
    if (soft < 0.05) soft = 0.05;
    double t = (dist - start) / soft;
    t = camera_clamp(t);
    return t * t * (3.0 - 2.0 * t);
}

static double vignette_mask(size_t x, size_t y, size_t width, size_t height,
                            double midpoint, double roundness, double feather) {
    return vignette_mask_at((double)x + 0.5, (double)y + 0.5, (double)width, (double)height, midpoint, roundness, feather);
}

static void effects_vignette(double *r, double *g, double *b, size_t x, size_t y, size_t width, size_t height,
                             double amount, double midpoint, double roundness, double feather, double highlights,
                             int style) {
    if (amount == 0 || width == 0 || height == 0) return;
    // Photoshop's is an ellipse fitted to the frame at Roundness 0, toward a rectangle below it, and starts a little
    // further out than the Midpoint alone puts it.
    double mask = vignette_mask(x, y, width, height, midpoint + 5.9, fmin(100, 100 + roundness), feather);
    double effect = (amount / 100.0) * mask;
    if (style == 0 && mask > 0) {
        // Highlight Priority, measured against Photoshop's, in linear light: darkening is a gain, to near black at
        // −100 in the corners, eased off bright pixels (and more so with Highlights); lightening blends toward white,
        // starting further out the gentler it is.
        double linear[3] = {srgb_decode(*r), srgb_decode(*g), srgb_decode(*b)};
        double bright = camera_clamp((rec709(*r, *g, *b) - 0.45) / 0.55);
        if (amount < 0) {
            double ease = (1.0 - 0.3 * bright) * (1.0 - (highlights / 100.0) * bright);
            double gain = exp(-5.8 * pow(-amount / 100.0, 1.43) * mask * ease);
            for (int k = 0; k < 3; ++k) linear[k] *= gain;
        } else {
            double a = amount / 100.0, toward = pow(a, 0.85) * pow(mask, 1 + 1.5 * (1 - a));
            for (int k = 0; k < 3; ++k) linear[k] += (1.0 - linear[k]) * toward;
        }
        *r = srgb_encode(linear[0]);
        *g = srgb_encode(linear[1]);
        *b = srgb_encode(linear[2]);
        return;
    }
    if (effect < 0) {
        double factor = 1.0 + effect;
        *r *= factor; *g *= factor; *b *= factor;
    } else if (effect > 0) {
        *r = *r + (1.0 - *r) * effect;
        *g = *g + (1.0 - *g) * effect;
        *b = *b + (1.0 - *b) * effect;
    }
    if (style == 1 && mask > 0) {
        double lum = rec709(*r, *g, *b);
        double sat = 1.0 - 0.75 * mask * fabs(amount / 100.0);
        *r = camera_clamp(lum + (*r - lum) * sat);
        *g = camera_clamp(lum + (*g - lum) * sat);
        *b = camera_clamp(lum + (*b - lum) * sat);
    }
}

void adjust_colored_vignette(uint8_t *rgba, size_t width, size_t height, size_t stride,
                             double frameX, double frameY, double frameWidth, double frameHeight, int fillsClear,
                             double amount, double midpoint, double roundness, double feather,
                             double highlights, double red, double green, double blue) {
    if (!rgba || amount <= 0 || width == 0 || height == 0 || frameWidth <= 0 || frameHeight <= 0) return;
    double strength = camera_clamp(amount / 100.0);
    red = camera_clamp(red); green = camera_clamp(green); blue = camera_clamp(blue);
    for (size_t y = 0; y < height; ++y) {
        uint8_t *row = rgba + y * stride;
        for (size_t x = 0; x < width; ++x) {
            uint8_t *p = row + x * 4;
            if (!p[3] && !fillsClear) continue;
            double mask = vignette_mask_at((double)x + 0.5 - frameX, (double)y + 0.5 - frameY, frameWidth, frameHeight,
                                           midpoint, roundness, feather);
            if (mask <= 0) continue;
            double alpha = p[3] / 255.0;
            double r = 0, g = 0, b = 0, bright = 0;
            if (p[3]) {
                r = fmin(1.0, p[0] / (double)p[3]);
                g = fmin(1.0, p[1] / (double)p[3]);
                b = fmin(1.0, p[2] / (double)p[3]);
                bright = camera_clamp((rec709(r, g, b) - 0.45) / 0.55);
            }
            double effect = strength * mask * (1.0 - (highlights / 100.0) * bright);
            if (!fillsClear) {
                // Only the pixels that are there change color; their coverage stays as it was.
                write_premultiplied(p, r + (red - r) * effect, g + (green - g) * effect, b + (blue - b) * effect, p[3]);
                continue;
            }
            // The color painted over the pixel at `effect`: an opaque pixel moves toward it, a clear one takes it on.
            double out = alpha + effect * (1.0 - alpha);
            if (out <= 0) continue;
            r = (red * effect + r * alpha * (1.0 - effect)) / out;
            g = (green * effect + g * alpha * (1.0 - effect)) / out;
            b = (blue * effect + b * alpha * (1.0 - effect)) / out;
            p[3] = (uint8_t)fmin(255.0, round(out * 255.0));
            write_premultiplied(p, r, g, b, p[3]);
        }
    }
}

void adjust_camera_raw_clip_overlay(uint8_t *rgba, size_t width, size_t height, size_t stride, int shadows, int highlights) {
    if (!shadows && !highlights) return;
    for (size_t y = 0; y < height; ++y) {
        uint8_t *row = rgba + y * stride;
        for (size_t x = 0; x < width; ++x) {
            uint8_t *p = row + x * 4;
            double alpha = p[3];
            if (!alpha) continue;
            double r = fmin(1.0, p[0] / alpha);
            double g = fmin(1.0, p[1] / alpha);
            double b = fmin(1.0, p[2] / alpha);
            if (shadows && (r <= 0.5 / 255.0 || g <= 0.5 / 255.0 || b <= 0.5 / 255.0)) {
                r *= 0.35; g *= 0.35; b = b * 0.35 + 0.65;
            }
            if (highlights && (r >= 254.5 / 255.0 || g >= 254.5 / 255.0 || b >= 254.5 / 255.0)) {
                r = r * 0.35 + 0.65; g *= 0.35; b *= 0.35;
            }
            write_premultiplied(p, r, g, b, alpha);
        }
    }
}

void adjust_camera_raw_effects(uint8_t *rgba, size_t width, size_t height, size_t stride,
                               double texture, double clarity, double dehaze,
                               double glow, int glowStyle, double glowRange, double glowSpread, double glowWarmth,
                               double vignetteAmount, double vignetteMidpoint, double vignetteRoundness,
                               double vignetteFeather, double vignetteHighlights, int vignetteStyle,
                               double scale) {
    if (width == 0 || height == 0) return;
    if (texture == 0 && clarity == 0 && dehaze == 0 && !(glow > 0) && vignetteAmount == 0) return;
    size_t count = width * height;
    float *luma = NULL, *fine = NULL, *coarse = NULL, *glowPlane = NULL;
    int glowRadius = 1;
    int failed = 0;
    if (texture != 0 || clarity != 0 || glow > 0) {
        luma = malloc(count * sizeof(float));
        if (!luma) return;
        in_bands(height, ^(size_t first, size_t last) { for (size_t y = first; y < last; ++y) {
            uint8_t *row = rgba + y * stride;
            for (size_t x = 0; x < width; ++x) {
                uint8_t *p = row + x * 4;
                double alpha = p[3];
                if (!alpha) { luma[y * width + x] = 0; continue; }
                double r = fmin(1.0, p[0] / alpha);
                double g = fmin(1.0, p[1] / alpha);
                double b = fmin(1.0, p[2] / alpha);
                luma[y * width + x] = (float)rec709(r, g, b);
            }
        } });
        // Radii in proportion to the picture, as fitted to Photoshop's on 1456-pixel-wide photos (8 and 32 there), so
        // a downscaled preview matches the full-size result.
        double side = (double)(width > height ? width : height);
        if (texture != 0) {
            fine = malloc(count * sizeof(float));
            int radius = (int)fmax(1, lround(side * 8 / 1456));
            if (!fine || !guided_filter_plane(luma, fine, width, height, radius, 0.01f)) failed = 1;
        }
        if (!failed && clarity != 0) {
            coarse = malloc(count * sizeof(float));
            int radius = (int)fmax(2, lround(side * 32 / 1456));
            if (!coarse || !guided_filter_plane(luma, coarse, width, height, radius, 0.01f)) failed = 1;
        }
        if (!failed && glow > 0) {
            double spread = glowSpread / 100.0;
            double base = glowStyle == 1 ? 2.0 : 5.0;
            double widened = base * (1.0 + spread);
            if (widened < 1) widened = 1;
            glowRadius = effects_radius(widened, scale);
            float threshold = (float)(0.55 + 0.4 * (glowRange / 100.0));
            glowPlane = malloc(count * sizeof(float));
            float *source = malloc(count * sizeof(float));
            if (!glowPlane || !source) failed = 1;
            else {
                float denom = 1.0f - threshold;
                if (denom < 0.05f) denom = 0.05f;
                for (size_t i = 0; i < count; ++i) {
                    float t = (luma[i] - threshold) / denom;
                    if (t < 0) t = 0;
                    if (t > 1) t = 1;
                    source[i] = t;
                }
                failed = !box_blur_plane(source, glowPlane, width, height, glowRadius);
            }
            free(source);
        }
    }
    if (failed) {
        free(luma); free(fine); free(coarse); free(glowPlane);
        return;
    }
    double hazeColor[3] = {1, 1, 1};
    if (dehaze != 0) dehaze_haze(rgba, width, height, stride, hazeColor);
    const double *haze = hazeColor;
    double warmth = glowWarmth / 100.0;
    double glowRed, glowGreen, glowBlue, glowGain;
    if (glowStyle == 2) {
        // Halation's fringe is red. Warmth pushes it further that way, rather than toward yellow or blue.
        glowRed = 1;
        glowGreen = 0.35 - 0.3 * warmth;
        glowBlue = 0.2 - 0.2 * warmth;
        glowGain = 1;
    } else {
        glowRed = 0.75 + 0.25 * warmth;
        glowGreen = 0.6 + 0.2 * warmth;
        glowBlue = 0.75 - 0.6 * warmth;
        glowGain = glowStyle == 1 ? 1.4 : 1;
    }
    in_bands(height, ^(size_t first, size_t last) { for (size_t y = first; y < last; ++y) {
        uint8_t *row = rgba + y * stride;
        for (size_t x = 0; x < width; ++x) {
            uint8_t *p = row + x * 4;
            double alpha = p[3];
            if (!alpha) continue;
            size_t index = y * width + x;
            double r = fmin(1.0, p[0] / alpha);
            double g = fmin(1.0, p[1] / alpha);
            double b = fmin(1.0, p[2] / alpha);
            if (fine || coarse) {
                double tone = rec709(r, g, b);
                double detail = 0;
                if (fine) detail += (texture / 100.0) * (texture > 0 ? 0.6 : 0.5) * (tone - fine[index]);
                if (coarse) detail += (clarity / 100.0) * (clarity > 0 ? 0.85 : 0.5) * (tone - coarse[index]);
                if (detail != 0) scale_luminance(&r, &g, &b, camera_clamp(tone + detail));
            }
            if (dehaze != 0) effects_dehaze(&r, &g, &b, dehaze, haze);
            if (glowPlane && glow > 0) {
                double add = glowPlane[index] * (glow / 100.0) * glowGain;
                r = camera_clamp(r + add * glowRed);
                g = camera_clamp(g + add * glowGreen);
                b = camera_clamp(b + add * glowBlue);
            }
            effects_vignette(&r, &g, &b, x, y, width, height, vignetteAmount, vignetteMidpoint, vignetteRoundness,
                             vignetteFeather, vignetteHighlights, vignetteStyle);
            write_premultiplied(p, r, g, b, alpha);
        }
    } });
    free(luma);
    free(fine);
    free(coarse);
    free(glowPlane);
}

static double tonal_smooth(double low, double high, double value) {
    double t = camera_clamp((value - low) / (high - low));
    return t * t * (3.0 - 2.0 * t);
}

void adjust_tonal_contrast(uint8_t *rgba, const uint8_t *blurred, size_t width, size_t height,
                           size_t stride, size_t blurredStride, double amount,
                           double shadows, double midtones, double highlights) {
    if (amount <= 0 || (shadows == 0 && midtones == 0 && highlights == 0)) return;
    double strength = amount / 50.0;
    for (size_t y = 0; y < height; ++y) {
        uint8_t *row = rgba + y * stride;
        const uint8_t *baseRow = blurred + y * blurredStride;
        for (size_t x = 0; x < width; ++x) {
            uint8_t *p = row + x * 4;
            const uint8_t *base = baseRow + x * 4;
            double alpha = p[3];
            if (alpha == 0 || base[3] == 0) continue;
            double r = fmin(1.0, p[0] / alpha);
            double g = fmin(1.0, p[1] / alpha);
            double b = fmin(1.0, p[2] / alpha);
            double lum = rec709(r, g, b);
            double baseLum = rec709(fmin(1.0, base[0] / (double)base[3]),
                                    fmin(1.0, base[1] / (double)base[3]),
                                    fmin(1.0, base[2] / (double)base[3]));
            double shadowWeight = 1.0 - tonal_smooth(0.15, 0.5, baseLum);
            double highlightWeight = tonal_smooth(0.5, 0.85, baseLum);
            double midtoneWeight = 1.0 - shadowWeight - highlightWeight;
            double weight = (shadows * shadowWeight + midtones * midtoneWeight +
                             highlights * highlightWeight) / 100.0;
            double detail = lum - baseLum;
            double delta = 0.18 * tanh(detail * 6.0) * weight * strength * (4.0 * lum * (1.0 - lum));
            write_premultiplied(p, camera_clamp(r + delta), camera_clamp(g + delta),
                                camera_clamp(b + delta), alpha);
        }
    }
}

static double lut_at(const float *lut, double value) {
    double scaled = camera_clamp(value) * 255.0;
    int lo = (int)scaled;
    int hi = lo < 255 ? lo + 1 : 255;
    double t = scaled - lo;
    return lut[lo] + (lut[hi] - lut[lo]) * t;
}

static void rgb_to_hsl(double r, double g, double b, double *h, double *s, double *l) {
    double maxc = fmax(r, fmax(g, b)), minc = fmin(r, fmin(g, b));
    *l = (maxc + minc) * 0.5;
    double d = maxc - minc;
    if (d < 1e-6) { *h = 0; *s = 0; return; }
    *s = d / (1.0 - fabs(2.0 * *l - 1.0));
    if (maxc == r) *h = fmod((g - b) / d, 6.0);
    else if (maxc == g) *h = (b - r) / d + 2.0;
    else *h = (r - g) / d + 4.0;
    *h /= 6.0;
    if (*h < 0) *h += 1;
}

static double hue_to_rgb(double p, double q, double t) {
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6) return p + (q - p) * 6 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3) return p + (q - p) * (2.0 / 3 - t) * 6;
    return p;
}

static void hsl_to_rgb(double h, double s, double l, double *r, double *g, double *b) {
    if (s <= 1e-6) { *r = *g = *b = l; return; }
    double q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    double p = 2 * l - q;
    *r = hue_to_rgb(p, q, h + 1.0 / 3);
    *g = hue_to_rgb(p, q, h);
    *b = hue_to_rgb(p, q, h - 1.0 / 3);
}

static double circular_distance(double a, double b) {
    double d = fabs(a - b);
    return d > 0.5 ? 1 - d : d;
}

static const double mixer_centers[8] = {0, 30.0 / 360, 60.0 / 360, 120.0 / 360, 180.0 / 360, 240.0 / 360, 270.0 / 360, 300.0 / 360};

static double point_weight(double h, double s, double l, const float *point) {
    double hueHalf = point[6] > 0.01f ? point[6] : 0.01f;
    double satHalf = point[7] > 0.01f ? point[7] : 0.01f;
    double lumHalf = point[8] > 0.01f ? point[8] : 0.01f;
    double hueW = 1 - circular_distance(h, point[0]) / hueHalf;
    double satW = 1 - fabs(s - point[1]) / satHalf;
    double lumW = 1 - fabs(l - point[2]) / lumHalf;
    if (hueW < 0 || satW < 0 || lumW < 0) return 0;
    return hueW * satW * lumW;
}

void adjust_camera_raw_curve_color(uint8_t *rgba, size_t width, size_t height, size_t stride,
                                   const float *toneLut, const float *redLut, const float *greenLut, const float *blueLut,
                                   double refineSaturation, const float *mixer, int pointCount, const float *points,
                                   const float *grade, double blending, double balance, int visualize,
                                   const float *mixerTable, const float *gradeTable, int grid) {
    in_bands(height, ^(size_t first, size_t last) { for (size_t y = first; y < last; ++y) {
        uint8_t *row = rgba + y * stride;
        for (size_t x = 0; x < width; ++x) {
            uint8_t *p = row + x * 4;
            double alpha = p[3];
            if (!alpha) continue;
            double r = fmin(1.0, p[0] / alpha), g = fmin(1.0, p[1] / alpha), b = fmin(1.0, p[2] / alpha);
            // The tone curve works on red, green and blue alike, as Photoshop's does, so contrast brings color strength
            // with it. Refine Saturation below zero eases toward changing brightness alone (−100), and above zero adds
            // more color.
            double curvedR = lut_at(toneLut, r), curvedG = lut_at(toneLut, g), curvedB = lut_at(toneLut, b);
            if (refineSaturation < 0) {
                double br = r, bg = g, bb = b;
                scale_luminance(&br, &bg, &bb, lut_at(toneLut, rec709(r, g, b)));
                double k = -refineSaturation;
                curvedR += (br - curvedR) * k; curvedG += (bg - curvedG) * k; curvedB += (bb - curvedB) * k;
            } else if (refineSaturation > 0) {
                double lum = rec709(curvedR, curvedG, curvedB), factor = 1 + refineSaturation;
                curvedR = camera_clamp(lum + (curvedR - lum) * factor);
                curvedG = camera_clamp(lum + (curvedG - lum) * factor);
                curvedB = camera_clamp(lum + (curvedB - lum) * factor);
            }
            r = curvedR; g = curvedG; b = curvedB;
            r = lut_at(redLut, r); g = lut_at(greenLut, g); b = lut_at(blueLut, b);
            if (mixerTable) composed_lookup(mixerTable, grid, &r, &g, &b);
            double h, s, l;
            rgb_to_hsl(r, g, b, &h, &s, &l);
            double sourceHue = h, sourceSat = s, sourceLum = l;
            double hueDelta = 0, satDelta = 0, lumDelta = 0, weightSum = 0;
            for (int i = 0; i < 8; ++i) {
                double dist = circular_distance(h, mixer_centers[i]);
                double w = 1 - dist / (40.0 / 360);
                if (w <= 0) continue;
                hueDelta += mixer[i] * w * (30.0 / 360);
                satDelta += mixer[8 + i] * w;
                lumDelta += mixer[16 + i] * w * 0.25;
                weightSum += w;
            }
            if (weightSum > 1) { hueDelta /= weightSum; satDelta /= weightSum; lumDelta /= weightSum; }
            h += hueDelta; if (h < 0) h += 1; if (h >= 1) h -= 1;
            s = camera_clamp(s * (1 + satDelta));
            l = camera_clamp(l + lumDelta);
            for (int i = 0; i < pointCount; ++i) {
                const float *point = points + i * 9;
                double w = point_weight(h, s, l, point);
                if (w <= 0) continue;
                h += point[3] * w * (30.0 / 360);
                s = camera_clamp(s * (1 + point[4] * w));
                l = camera_clamp(l + point[5] * w * 0.25);
            }
            if (h < 0) h += 1; if (h >= 1) h -= 1;
            hsl_to_rgb(h, s, l, &r, &g, &b);
            if (gradeTable) composed_lookup(gradeTable, grid, &r, &g, &b);
            // Balance moves the crossover between the shadow and highlight wheels. Toward highlights
            // it has to move down, so more of the picture counts as highlight and the shadow wheel
            // loses its hold; the other sign strengthened the shadow tint it was meant to weaken.
            double split = 0.5 - balance * 0.2;
            double reach = 0.12 + blending * 0.38;
            double shadowW = camera_clamp((split + reach - rec709(r, g, b)) / fmax(0.05, reach * 2));
            double highlightW = camera_clamp((rec709(r, g, b) - (split - reach)) / fmax(0.05, reach * 2));
            double midW = camera_clamp(1 - fabs(rec709(r, g, b) - split) / (0.35 + reach));
            double sum = shadowW + midW + highlightW;
            if (sum > 1e-4) { shadowW /= sum; midW /= sum; highlightW /= sum; }
            double weights[4] = {shadowW, midW, highlightW, 1};
            for (int wheel = 0; wheel < 4; ++wheel) {
                double wh = grade[wheel * 3], ws = grade[wheel * 3 + 1], wl = grade[wheel * 3 + 2];
                double w = weights[wheel];
                if (w <= 0 || (ws <= 0 && wl == 0)) continue;
                double cr, cg, cb;
                hsl_to_rgb(wh, 1, 0.5, &cr, &cg, &cb);
                r = camera_clamp(r + (cr - 0.5) * ws * w * 0.85);
                g = camera_clamp(g + (cg - 0.5) * ws * w * 0.85);
                b = camera_clamp(b + (cb - 0.5) * ws * w * 0.85);
                if (wl != 0) scale_luminance(&r, &g, &b, camera_clamp(rec709(r, g, b) + wl * 0.25 * w));
            }
            if (visualize >= 0 && visualize < pointCount && point_weight(sourceHue, sourceSat, sourceLum, points + visualize * 9) <= 0.05) {
                r *= 0.35; g *= 0.35; b *= 0.35;
            }
            write_premultiplied(p, r, g, b, alpha);
        }
    } });
}

void camera_raw_table_curves(float *table, int grid, const float *toneLut, const float *redLut, const float *greenLut,
                             const float *blueLut) {
    size_t entries = (size_t)grid * grid * grid;
    for (size_t i = 0; i < entries; ++i) {
        float *c = table + i * 3;
        c[0] = (float)lut_at(redLut, lut_at(toneLut, c[0]));
        c[1] = (float)lut_at(greenLut, lut_at(toneLut, c[1]));
        c[2] = (float)lut_at(blueLut, lut_at(toneLut, c[2]));
    }
}

static double detail_radius(double slider, double scale) {
    double base = 0.5 + (slider / 100.0) * 2.5;
    double radius = base * (scale > 0 ? scale : 1);
    if (radius < 0.5) radius = 0.5;
    if (radius > 64) radius = 64;
    return radius;
}

static double pixel_hue_deg(double r, double g, double b) {
    double maxc = fmax(r, fmax(g, b)), minc = fmin(r, fmin(g, b));
    double chroma = maxc - minc;
    if (chroma < 1e-6) return 0;
    double hue;
    if (maxc == r) hue = fmod((g - b) / chroma, 6.0);
    else if (maxc == g) hue = (b - r) / chroma + 2.0;
    else hue = (r - g) / chroma + 4.0;
    hue = hue * 60.0;
    if (hue < 0) hue += 360.0;
    return hue;
}

static int hue_in_range(double hue, double low, double high) {
    if (low <= high) return hue >= low && hue <= high;
    return hue >= low || hue <= high;
}

static float sharpen_edge_at(const float *luma, size_t width, size_t height, size_t x, size_t y, int radius) {
    if (radius < 1) radius = 1;
    float center = luma[y * width + x];
    float sum = 0;
    int count = 0;
    for (int dy = -radius; dy <= radius; dy += radius) {
        for (int dx = -radius; dx <= radius; dx += radius) {
            if (dx == 0 && dy == 0) continue;
            long sx = (long)x + dx, sy = (long)y + dy;
            if (sx < 0 || sy < 0 || (size_t)sx >= width || (size_t)sy >= height) continue;
            sum += fabsf(luma[sy * width + sx] - center);
            count++;
        }
    }
    return count ? sum / count : 0;
}

void adjust_camera_raw_sharpen_mask_overlay(uint8_t *rgba, size_t width, size_t height, size_t stride,
                                            double sharpenRadius, double sharpenDetail, double sharpenMasking, double scale) {
    if (width == 0 || height == 0) return;
    size_t count = width * height;
    float *luma = malloc(count * sizeof(float));
    if (!luma) return;
    for (size_t y = 0; y < height; ++y) {
        uint8_t *row = rgba + y * stride;
        for (size_t x = 0; x < width; ++x) {
            uint8_t *p = row + x * 4;
            double alpha = p[3];
            if (!alpha) { luma[y * width + x] = 0; continue; }
            double r = fmin(1.0, p[0] / alpha), g = fmin(1.0, p[1] / alpha), b = fmin(1.0, p[2] / alpha);
            luma[y * width + x] = (float)rec709(r, g, b);
        }
    }
    int radius = effects_radius(detail_radius(sharpenRadius, scale), 1);
    double threshold = (sharpenMasking / 100.0) * 0.35;
    double detailBoost = 0.5 + sharpenDetail / 100.0;
    for (size_t y = 0; y < height; ++y) {
        uint8_t *row = rgba + y * stride;
        for (size_t x = 0; x < width; ++x) {
            uint8_t *p = row + x * 4;
            double alpha = p[3];
            if (!alpha) continue;
            float edge = sharpen_edge_at(luma, width, height, x, y, radius);
            double mask = camera_clamp((edge * detailBoost - threshold) / fmax(0.04, 0.35 - threshold * 0.5));
            uint8_t gray = (uint8_t)lround(mask * alpha);
            p[0] = p[1] = p[2] = gray;
        }
    }
    free(luma);
}

// How much noise `luma` carries, as its standard deviation (0–1): Immerkær's estimate, from how far each pixel strays
// from what its eight neighbors predict, over the pixels that are there. Texture adds a little; flat grain is what counts.
static double noise_sigma(const float *luma, const float *coverage, size_t width, size_t height) {
    if (width < 3 || height < 3) return 0;
    double sum = 0;
    size_t count = 0;
    for (size_t y = 1; y + 1 < height; ++y) {
        const float *up = luma + (y - 1) * width, *row = luma + y * width, *down = luma + (y + 1) * width;
        for (size_t x = 1; x + 1 < width; ++x) {
            if (coverage[y * width + x] < 0.5f) continue;
            double laplacian = up[x - 1] - 2 * up[x] + up[x + 1] - 2 * row[x - 1] + 4 * row[x] - 2 * row[x + 1]
                + down[x - 1] - 2 * down[x] + down[x + 1];
            sum += fabs(laplacian);
            count++;
        }
    }
    return count ? sqrt(M_PI / 2) * sum / (6.0 * count) : 0;
}

int (*adjust_nonlocal_means_gpu)(const float *, const float *, float *, size_t, size_t, int, int, double, double) = NULL;

// Non-local means: each pixel averaged with the others within `search` pixels whose `patch`-wide surroundings look like
// its own, so grain, random from patch to patch, averages away, while an edge or a texture, matched only by patches
// along it, is kept. `h` is how alike (in brightness, 0–1) patches must be to count, and `sigma` the noise, whose share
// of every distance is taken off first. Clear pixels lend nothing. Worked one band of rows at a time, an offset at a
// time: each offset's squared differences summed over the patch with running sums. On the GPU when the app has set
// `adjust_nonlocal_means_gpu`.
static int nonlocal_means(const float *luma, const float *coverage, float *out, size_t width, size_t height,
                          int search, int patch, double h, double sigma) {
    if (adjust_nonlocal_means_gpu && adjust_nonlocal_means_gpu(luma, coverage, out, width, height, search, patch, h, sigma)) return 1;
    // exp(-d) for d from 0 to 6 in 1024 steps; past 6 a match counts for nothing.
    enum { steps = 1024 };
    static float table[steps + 1];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ for (int i = 0; i <= steps; ++i) table[i] = (float)exp(-6.0 * i / steps); });
    float allowance = (float)(2 * sigma * sigma), toStep = (float)(steps / (6.0 * h * h));
    float area = (float)((2 * patch + 1) * (2 * patch + 1));
    __block int failed = 0;
    in_bands(height, ^(size_t first, size_t last) {
        size_t rows = last - first, span = rows + 2 * patch;
        float *difference = malloc(span * width * sizeof(float));
        float *column = malloc(width * sizeof(float));
        float *total = calloc(rows * width, sizeof(float)), *weights = calloc(rows * width, sizeof(float));
        float *strongest = calloc(rows * width, sizeof(float));
        if (!difference || !column || !total || !weights || !strongest) {
            failed = 1;
            free(difference); free(column); free(total); free(weights); free(strongest);
            return;
        }
        for (int dy = -search; dy <= search; ++dy) {
            for (int dx = -search; dx <= search; ++dx) {
                if (dx == 0 && dy == 0) continue;
                // Squared differences from this offset, over the band and a patch's height either side.
                for (size_t i = 0; i < span; ++i) {
                    size_t y = clamped_index((int)(first + i) - patch, height), shifted = clamped_index((int)y + dy, height);
                    const float *row = luma + y * width, *other = luma + shifted * width;
                    float *into = difference + i * width;
                    for (size_t x = 0; x < width; ++x) {
                        float d = row[x] - other[clamped_index((int)x + dx, width)];
                        into[x] = d * d;
                    }
                }
                memset(column, 0, width * sizeof(float));
                for (int i = 0; i < 2 * patch; ++i) {
                    for (size_t x = 0; x < width; ++x) column[x] += difference[i * width + x];
                }
                for (size_t i = 0; i < rows; ++i) {
                    // The column sums down the patch, then across it.
                    const float *entering = difference + (i + 2 * patch) * width;
                    for (size_t x = 0; x < width; ++x) column[x] += entering[x];
                    size_t y = first + i, shifted = clamped_index((int)y + dy, height);
                    float across = 0;
                    for (int k = -patch; k < patch; ++k) across += column[clamped_index(k, width)];
                    for (size_t x = 0; x < width; ++x) {
                        across += column[clamped_index((int)x + patch, width)];
                        float distance = across / area - allowance;
                        across -= column[clamped_index((int)x - patch, width)];
                        int step = distance <= 0 ? 0 : (int)(distance * toStep);
                        if (step >= steps) continue;
                        size_t neighbor = shifted * width + clamped_index((int)x + dx, width);
                        float weight = table[step] * coverage[neighbor];
                        size_t index = i * width + x;
                        total[index] += weight * luma[neighbor];
                        weights[index] += weight;
                        if (weight > strongest[index]) strongest[index] = weight;
                    }
                    const float *leaving = difference + i * width;
                    for (size_t x = 0; x < width; ++x) column[x] -= leaving[x];
                }
            }
        }
        // The pixel itself counts as much as its best match: as itself it would always count fully, and keep its grain.
        for (size_t i = 0; i < rows; ++i) {
            for (size_t x = 0; x < width; ++x) {
                size_t index = i * width + x, pixel = (first + i) * width + x;
                float own = strongest[index] > 0 ? strongest[index] : 1;
                out[pixel] = (total[index] + own * luma[pixel]) / (weights[index] + own);
            }
        }
        free(difference); free(column); free(total); free(weights); free(strongest);
    });
    return !failed;
}

void adjust_camera_raw_detail(uint8_t *rgba, size_t width, size_t height, size_t stride,
                              double sharpenAmount, double sharpenRadius, double sharpenDetail, double sharpenMasking,
                              double noiseLuminance, double noiseLuminanceDetail, double noiseLuminanceContrast,
                              double noiseColor, double noiseColorDetail, double noiseColorSmoothness, double scale) {
    if (width == 0 || height == 0) return;
    if (sharpenAmount == 0 && noiseLuminance == 0 && noiseColor == 0) return;
    size_t count = width * height;
    float *luma = malloc(count * sizeof(float));
    float *work = malloc(count * sizeof(float));
    if (!luma || !work) { free(luma); free(work); return; }
    in_bands(height, ^(size_t first, size_t last) { for (size_t y = first; y < last; ++y) {
        uint8_t *row = rgba + y * stride;
        for (size_t x = 0; x < width; ++x) {
            uint8_t *p = row + x * 4;
            double alpha = p[3];
            if (!alpha) { luma[y * width + x] = 0; continue; }
            double r = fmin(1.0, p[0] / alpha), g = fmin(1.0, p[1] / alpha), b = fmin(1.0, p[2] / alpha);
            luma[y * width + x] = (float)rec709(r, g, b);
        }
    } });
    if (noiseLuminance > 0) {
        // Non-local means on the brightness (see `nonlocal_means`), as strong as the noise measured in it: a clean
        // photo is left nearly alone. Detail asks patches to be more alike before they count, so less texture goes
        // with the grain. Smaller previews look nearer and finer, the noise already thinned by their scaling.
        double strength = noiseLuminance / 100.0;
        double preserve = noiseLuminanceDetail / 100.0;
        double contrast = noiseLuminanceContrast / 100.0;
        float *coverage = malloc(count * sizeof(float));
        if (!coverage) { free(luma); free(work); return; }
        for (size_t y = 0; y < height; ++y) {
            for (size_t x = 0; x < width; ++x) coverage[y * width + x] = rgba[y * stride + x * 4 + 3] / 255.0f;
        }
        double sigma = fmax(0.5 / 255.0, noise_sigma(luma, coverage, width, height));
        double h = sigma * (0.2 + 1.1 * strength) * (1.3 - 0.6 * preserve);
        int search = (int)lround(fmin(7, fmax(3, 7 * (scale > 0 ? scale : 1)))), patch = scale < 0.5 ? 1 : 2;
        int done = nonlocal_means(luma, coverage, work, width, height, search, patch, h, sigma * (0.4 + 0.6 * (1 - preserve)));
        free(coverage);
        if (!done) { free(luma); free(work); return; }
        // Contrast puts back some of the local contrast smoothing took, measured on the smoothed brightness, not the grain.
        float *local = contrast != 0 ? malloc(count * sizeof(float)) : NULL;
        if (local && !box_blur_plane(work, local, width, height, effects_radius(2, scale))) { free(local); local = NULL; }
        for (size_t y = 0; y < height; ++y) {
            uint8_t *row = rgba + y * stride;
            for (size_t x = 0; x < width; ++x) {
                uint8_t *p = row + x * 4;
                double alpha = p[3];
                if (!alpha) continue;
                size_t index = y * width + x;
                float target = work[index];
                if (local) target = (float)(target + contrast * 0.5 * (work[index] - local[index]));
                luma[index] = target;
                double r = fmin(1.0, p[0] / alpha), g = fmin(1.0, p[1] / alpha), b = fmin(1.0, p[2] / alpha);
                scale_luminance(&r, &g, &b, target);
                write_premultiplied(p, r, g, b, alpha);
            }
        }
        free(local);
    }
    if (noiseColor > 0) {
        // Color noise is speckle of random hue over the picture's own color, in blotches a few pixels wide. Each pixel
        // keeps its brightness and takes the color of the area around it: its two color differences from its
        // brightness, red and blue, are blurred and put back over the brightness unchanged. Blurring saturation
        // alone kept every speck's own hue, so the speckle stayed.
        double strength = noiseColor / 100.0;
        int radius = effects_radius(1.5 + strength * 4.0 * (0.5 + noiseColorSmoothness / 100.0), scale);
        float *planes = malloc(count * sizeof(float) * 6);
        if (!planes) { free(luma); free(work); return; }
        // Red and blue differences and coverage, then the same blurred. Each pixel counts by its alpha, so clear
        // pixels add no color of their own and don't pull the colors beside them toward gray.
        float *red = planes, *blue = planes + count, *weight = planes + 2 * count;
        float *redBlur = planes + 3 * count, *blueBlur = planes + 4 * count, *weightBlur = planes + 5 * count;
        for (size_t y = 0; y < height; ++y) {
            uint8_t *row = rgba + y * stride;
            for (size_t x = 0; x < width; ++x) {
                uint8_t *p = row + x * 4;
                size_t index = y * width + x;
                double alpha = p[3];
                if (!alpha) { red[index] = 0; blue[index] = 0; weight[index] = 0; continue; }
                double r = fmin(1.0, p[0] / alpha), g = fmin(1.0, p[1] / alpha), b = fmin(1.0, p[2] / alpha);
                double luminance = rec709(r, g, b), coverage = alpha / 255.0;
                red[index] = (float)((r - luminance) * coverage);
                blue[index] = (float)((b - luminance) * coverage);
                weight[index] = (float)coverage;
            }
        }
        if (!box_blur_plane(red, redBlur, width, height, radius) || !box_blur_plane(blue, blueBlur, width, height, radius)
            || !box_blur_plane(weight, weightBlur, width, height, radius)) {
            free(planes); free(luma); free(work); return;
        }
        for (size_t i = 0; i < count; ++i) {
            if (weightBlur[i] > 1e-6f) { redBlur[i] /= weightBlur[i]; blueBlur[i] /= weightBlur[i]; }
        }
        // Color Detail keeps real color edges: where the smoothed color itself changes across a blur's width. Grain
        // doesn't count, as it did when each pixel was compared with its own blur.
        double preserve = noiseColorDetail / 100.0;
        size_t reach = (size_t)radius;
        for (size_t y = 0; y < height; ++y) {
            uint8_t *row = rgba + y * stride;
            size_t up = y >= reach ? y - reach : 0, down = y + reach < height ? y + reach : height - 1;
            for (size_t x = 0; x < width; ++x) {
                uint8_t *p = row + x * 4;
                double alpha = p[3];
                if (!alpha) continue;
                size_t index = y * width + x;
                size_t left = x >= reach ? x - reach : 0, right = x + reach < width ? x + reach : width - 1;
                double dx = fabs(redBlur[y * width + right] - redBlur[y * width + left]) + fabs(blueBlur[y * width + right] - blueBlur[y * width + left]);
                double dy = fabs(redBlur[down * width + x] - redBlur[up * width + x]) + fabs(blueBlur[down * width + x] - blueBlur[up * width + x]);
                double local = strength * (1.0 - preserve * fmin(1.0, (dx + dy) * 3.0));
                double r = fmin(1.0, p[0] / alpha), g = fmin(1.0, p[1] / alpha), b = fmin(1.0, p[2] / alpha);
                double luminance = rec709(r, g, b);
                double redDiff = (r - luminance) + (redBlur[index] - (r - luminance)) * local;
                double blueDiff = (b - luminance) + (blueBlur[index] - (b - luminance)) * local;
                r = luminance + redDiff;
                b = luminance + blueDiff;
                // Green follows from the brightness kept and the new red and blue.
                g = (luminance - 0.2126 * r - 0.0722 * b) / 0.7152;
                write_premultiplied(p, fmin(1.0, fmax(0.0, r)), fmin(1.0, fmax(0.0, g)), fmin(1.0, fmax(0.0, b)), alpha);
            }
        }
        free(planes);
    }
    if (sharpenAmount > 0) {
        in_bands(height, ^(size_t first, size_t last) { for (size_t y = first; y < last; ++y) {
            uint8_t *row = rgba + y * stride;
            for (size_t x = 0; x < width; ++x) {
                uint8_t *p = row + x * 4;
                double alpha = p[3];
                if (!alpha) continue;
                double r = fmin(1.0, p[0] / alpha), g = fmin(1.0, p[1] / alpha), b = fmin(1.0, p[2] / alpha);
                luma[y * width + x] = (float)rec709(r, g, b);
            }
        } });
        int radius = effects_radius(detail_radius(sharpenRadius, scale), 1);
        if (!box_blur_plane(luma, work, width, height, radius)) { free(luma); free(work); return; }
        double amount = sharpenAmount / 100.0;
        double detailMix = sharpenDetail / 100.0;
        double threshold = (sharpenMasking / 100.0) * 0.35;
        in_bands(height, ^(size_t first, size_t last) { for (size_t y = first; y < last; ++y) {
            uint8_t *row = rgba + y * stride;
            for (size_t x = 0; x < width; ++x) {
                uint8_t *p = row + x * 4;
                double alpha = p[3];
                if (!alpha) continue;
                size_t index = y * width + x;
                float edge = sharpen_edge_at(luma, width, height, x, y, radius);
                // Masking at 0 sharpens everywhere, as in Photoshop; raising it keeps the sharpening to edges.
                double mask = threshold > 0 ? camera_clamp((edge * (0.5 + detailMix) - threshold) / fmax(0.04, 0.35 - threshold * 0.5)) : 1;
                double high = luma[index] - work[index];
                // 1.9 × (0.5 + Detail) is Photoshop's strength: 1.4 at its default Detail of 25, measured on photos.
                double sharpened = camera_clamp(luma[index] + high * amount * mask * 1.9 * (0.5 + detailMix));
                double r = fmin(1.0, p[0] / alpha), g = fmin(1.0, p[1] / alpha), b = fmin(1.0, p[2] / alpha);
                scale_luminance(&r, &g, &b, sharpened);
                write_premultiplied(p, r, g, b, alpha);
            }
        } });
    }
    free(luma);
    free(work);
}

static void optics_defringe(double *r, double *g, double *b, double purpleAmount, double purpleLow, double purpleHigh,
                            double greenAmount, double greenLow, double greenHigh) {
    double hue = pixel_hue_deg(*r, *g, *b);
    double maxc = fmax(*r, fmax(*g, *b)), minc = fmin(*r, fmin(*g, *b));
    double chroma = maxc - minc;
    if (chroma < 1e-6) return;
    double sat = chroma / maxc;
    double reduce = 0;
    if (purpleAmount > 0 && hue_in_range(hue, purpleLow, purpleHigh)) reduce = fmax(reduce, purpleAmount / 100.0);
    if (greenAmount > 0 && hue_in_range(hue, greenLow, greenHigh)) reduce = fmax(reduce, greenAmount / 100.0);
    if (reduce <= 0) return;
    double lum = rec709(*r, *g, *b);
    double factor = 1.0 - reduce * sat;
    *r = camera_clamp(lum + (*r - lum) * factor);
    *g = camera_clamp(lum + (*g - lum) * factor);
    *b = camera_clamp(lum + (*b - lum) * factor);
}

static void optics_chromatic(uint8_t *rgba, size_t width, size_t height, size_t stride, double strength) {
    if (strength <= 0) return;
    uint8_t *copy = malloc(height * stride);
    if (!copy) return;
    for (size_t y = 0; y < height; ++y) memcpy(copy + y * stride, rgba + y * stride, width * 4);
    double cx = width * 0.5, cy = height * 0.5;
    double maxR = hypot(cx, cy);
    for (size_t y = 0; y < height; ++y) {
        uint8_t *row = rgba + y * stride;
        const uint8_t *srcRow = copy + y * stride;
        for (size_t x = 0; x < width; ++x) {
            uint8_t *p = row + x * 4;
            double alpha = p[3];
            if (!alpha) continue;
            double dx = x + 0.5 - cx, dy = y + 0.5 - cy;
            double radial = hypot(dx, dy) / maxR;
            double shift = strength * radial * radial * 2.5;
            int rx = (int)lround(x - shift), bx = (int)lround(x + shift);
            const uint8_t *pr = srcRow + clamped_index(rx, width) * 4;
            const uint8_t *pb = srcRow + clamped_index(bx, width) * 4;
            double g = fmin(1.0, srcRow[x * 4 + 1] / alpha);
            double r = fmin(1.0, pr[0] / fmax(1.0, pr[3]));
            double b = fmin(1.0, pb[2] / fmax(1.0, pb[3]));
            write_premultiplied(p, r, g, b, alpha);
        }
    }
    free(copy);
}

// Lens vignette correction, as Photoshop's: Exposure, through its measured tables (`exposure`, 21 of them −5…5 by
// 0.5, `size`³ each), by an amount that grows with the distance from the middle (1 at the corners): two stops times
// that distance to the 4.3 at ±100, less as the amount falls, and reaching further in as Midpoint does.
static void optics_vignette_correct(double *r, double *g, double *b, size_t x, size_t y, size_t width, size_t height,
                                    double amount, double midpoint, const uint8_t *exposure, int size) {
    if (amount == 0 || width == 0 || height == 0 || !exposure) return;
    double dx = (double)x + 0.5 - width / 2.0, dy = (double)y + 0.5 - height / 2.0;
    double distance = hypot(dx, dy) / hypot(width / 2.0, height / 2.0) * (1 + (50 - midpoint) / 100);
    double stops = (amount > 0 ? 1 : -1) * pow(fabs(amount) / 100, 1.15) * 1.98 * pow(distance, 4.3);
    double position = fmin(20, fmax(0, (stops + 5) / 0.5));
    int index = position >= 20 ? 19 : (int)position;
    double fraction = position - index, color[3] = {*r, *g, *b}, low[3], high[3];
    size_t entries = (size_t)size * size * size * 3;
    table_lookup(exposure + index * entries, size, color, low);
    table_lookup(exposure + (index + 1) * entries, size, color, high);
    *r = camera_clamp(low[0] + (high[0] - low[0]) * fraction);
    *g = camera_clamp(low[1] + (high[1] - low[1]) * fraction);
    *b = camera_clamp(low[2] + (high[2] - low[2]) * fraction);
}

void adjust_camera_raw_optics(uint8_t *rgba, size_t width, size_t height, size_t stride,
                              int removeChromatic, int lensProfile, double profileDistortion, double profileVignetting,
                              double distortionK, double purpleAmount, double purpleHueLow, double purpleHueHigh,
                              double greenAmount, double greenHueLow, double greenHueHigh,
                              double vignetteAmount, double vignetteMidpoint, double scale,
                              const uint8_t *exposureTables, int tableSize) {
    if (width == 0 || height == 0) return;
    double profileVignette = lensProfile ? profileVignetting / 100.0 : 0;
    double vignette = vignetteAmount + profileVignette * 35.0;
    if (distortionK != 0) {
        size_t bytes = height * stride;
        uint8_t *copy = malloc(bytes);
        if (!copy) return;
        memcpy(copy, rgba, bytes);
        lens_distort(copy, rgba, width, height, stride, distortionK);
        free(copy);
    }
    if (removeChromatic) optics_chromatic(rgba, width, height, stride, 0.45);
    if (purpleAmount == 0 && greenAmount == 0 && vignette == 0) return;
    in_bands(height, ^(size_t first, size_t last) { for (size_t y = first; y < last; ++y) {
        uint8_t *row = rgba + y * stride;
        for (size_t x = 0; x < width; ++x) {
            uint8_t *p = row + x * 4;
            double alpha = p[3];
            if (!alpha) continue;
            double r = fmin(1.0, p[0] / alpha), g = fmin(1.0, p[1] / alpha), b = fmin(1.0, p[2] / alpha);
            optics_defringe(&r, &g, &b, purpleAmount, purpleHueLow, purpleHueHigh, greenAmount, greenHueLow, greenHueHigh);
            optics_vignette_correct(&r, &g, &b, x, y, width, height, vignette, vignetteMidpoint, exposureTables, tableSize);
            write_premultiplied(p, r, g, b, alpha);
        }
    } });
}

void adjust_camera_raw_calibration(uint8_t *rgba, size_t width, size_t height, size_t stride,
                                   double shadowTint, double redHue, double redSaturation,
                                   double greenHue, double greenSaturation, double blueHue, double blueSaturation,
                                   int processVersion) {
    if (width == 0 || height == 0) return;
    double versionScale = processVersion <= 1 ? 0.55 : processVersion == 2 ? 0.65 : processVersion == 3 ? 0.75
        : processVersion == 4 ? 0.85 : processVersion == 5 ? 0.92 : 1.0;
    double tint = shadowTint / 100.0 * versionScale;
    double rh = redHue / 100.0 * (15.0 / 360.0) * versionScale;
    double rs = redSaturation / 100.0 * 0.45 * versionScale;
    double gh = greenHue / 100.0 * (15.0 / 360.0) * versionScale;
    double gs = greenSaturation / 100.0 * 0.45 * versionScale;
    double bh = blueHue / 100.0 * (15.0 / 360.0) * versionScale;
    double bs = blueSaturation / 100.0 * 0.45 * versionScale;
    in_bands(height, ^(size_t first, size_t last) { for (size_t y = first; y < last; ++y) {
        uint8_t *row = rgba + y * stride;
        for (size_t x = 0; x < width; ++x) {
            uint8_t *p = row + x * 4;
            double alpha = p[3];
            if (!alpha) continue;
            double r = fmin(1.0, p[0] / alpha), g = fmin(1.0, p[1] / alpha), b = fmin(1.0, p[2] / alpha);
            double h, s, l;
            rgb_to_hsl(r, g, b, &h, &s, &l);
            if (l < 0.35 && tint != 0) {
                h += tint * 0.06;
                if (h < 0) h += 1;
                if (h >= 1) h -= 1;
            }
            double maxc = fmax(r, fmax(g, b)), minc = fmin(r, fmin(g, b));
            if (maxc - minc > 1e-5) {
                if (r >= g && r >= b) { h += rh; s = camera_clamp(s * (1 + rs)); }
                else if (g >= r && g >= b) { h += gh; s = camera_clamp(s * (1 + gs)); }
                else { h += bh; s = camera_clamp(s * (1 + bs)); }
                if (h < 0) h += 1;
                if (h >= 1) h -= 1;
            }
            hsl_to_rgb(h, s, l, &r, &g, &b);
            write_premultiplied(p, r, g, b, alpha);
        }
    } });
}
