#include "AdjustPixels.h"
#include "LensPixels.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

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

static double srgb_to_linear(double encoded) {
    if (encoded <= 0.04045) return encoded / 12.92;
    return pow((encoded + 0.055) / 1.055, 2.4);
}

static double linear_to_srgb(double linear) {
    if (linear <= 0) return 0;
    if (linear >= 1) return 1;
    if (linear <= 0.0031308) return linear * 12.92;
    return 1.055 * pow(linear, 1.0 / 2.4) - 0.055;
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

static double tone_highlights(double y, double amount) {
    double t = camera_clamp((y - 0.5) / 0.5);
    double weight = t * t;
    if (amount >= 0) return camera_clamp(y + amount * weight * (1.0 - y));
    return camera_clamp(y + amount * weight * (y - 0.5));
}

static double tone_shadows(double y, double amount) {
    double t = camera_clamp((0.5 - y) / 0.5);
    double weight = t * t;
    if (amount >= 0) return camera_clamp(y + amount * weight * (0.5 - y));
    return camera_clamp(y + amount * weight * y);
}

// The top quarter is the white point: +1 maps 0.875 to 1, −1 pulls everything above 0.75 down to 0.75.
static double tone_whites(double y, double amount) {
    if (y <= 0.75) return y;
    return camera_clamp(0.75 + (y - 0.75) * (1.0 + amount));
}

// The bottom quarter is the black point. Negative amounts crush toward 0; positive ones lift toward 0.25.
static double tone_blacks(double y, double amount) {
    if (y >= 0.25) return y;
    return camera_clamp(0.25 + (y - 0.25) * (1.0 - amount));
}

static void vibrance_and_saturation(double *r, double *g, double *b, double vibrance, double saturation) {
    double lum = rec709(*r, *g, *b);
    double maxc = fmax(*r, fmax(*g, *b));
    double minc = fmin(*r, fmin(*g, *b));
    double chroma = maxc - minc;
    double sat = maxc <= 1e-8 ? 0 : chroma / maxc;
    double hue = 0;
    if (chroma > 1e-8) {
        if (*r >= *g && *r >= *b) hue = 60.0 * fmod((*g - *b) / chroma, 6.0);
        else if (*g >= *r && *g >= *b) hue = 60.0 * ((*b - *r) / chroma + 2.0);
        else hue = 60.0 * ((*r - *g) / chroma + 4.0);
        if (hue < 0) hue += 360.0;
    }
    double skin = 0;
    if (hue >= 10.0 && hue <= 50.0) {
        skin = hue <= 30.0 ? (hue - 10.0) / 20.0 : (50.0 - hue) / 20.0;
        skin *= camera_clamp((sat - 0.15) / 0.35);
    }
    double amount = vibrance * (1.0 - sat);
    if (vibrance > 0) amount *= 1.0 - 0.7 * skin;
    double factor = 1.0 + amount;
    *r = camera_clamp(lum + (*r - lum) * factor);
    *g = camera_clamp(lum + (*g - lum) * factor);
    *b = camera_clamp(lum + (*b - lum) * factor);
    lum = rec709(*r, *g, *b);
    factor = 1.0 + saturation;
    *r = camera_clamp(lum + (*r - lum) * factor);
    *g = camera_clamp(lum + (*g - lum) * factor);
    *b = camera_clamp(lum + (*b - lum) * factor);
}

static void write_premultiplied(uint8_t *p, double r, double g, double b, double alpha) {
    p[0] = (uint8_t)fmin(alpha, fmax(0.0, round(r * alpha)));
    p[1] = (uint8_t)fmin(alpha, fmax(0.0, round(g * alpha)));
    p[2] = (uint8_t)fmin(alpha, fmax(0.0, round(b * alpha)));
}

void adjust_camera_raw(uint8_t *rgba, size_t width, size_t height, size_t stride,
                       double redGain, double greenGain, double blueGain, double exposure, double contrast,
                       double highlights, double shadows, double whites, double blacks,
                       double vibrance, double saturation, int clipping) {
    double light = exp2(exposure);
    double contrastScale = 1.0 + contrast / 100.0;
    double highlightAmount = highlights / 100.0;
    double shadowAmount = shadows / 100.0;
    double whiteAmount = whites / 100.0;
    double blackAmount = blacks / 100.0;
    double vibranceAmount = vibrance / 100.0;
    double saturationAmount = saturation / 100.0;
    for (size_t y = 0; y < height; ++y) {
        uint8_t *row = rgba + y * stride;
        for (size_t x = 0; x < width; ++x) {
            uint8_t *p = row + x * 4;
            double alpha = p[3];
            if (!alpha) continue;
            double r = fmin(255.0, p[0] * 255.0 / alpha) / 255.0;
            double g = fmin(255.0, p[1] * 255.0 / alpha) / 255.0;
            double b = fmin(255.0, p[2] * 255.0 / alpha) / 255.0;
            r = camera_clamp(srgb_to_linear(r) * redGain * light);
            g = camera_clamp(srgb_to_linear(g) * greenGain * light);
            b = camera_clamp(srgb_to_linear(b) * blueGain * light);
            r = camera_clamp(0.5 + (linear_to_srgb(r) - 0.5) * contrastScale);
            g = camera_clamp(0.5 + (linear_to_srgb(g) - 0.5) * contrastScale);
            b = camera_clamp(0.5 + (linear_to_srgb(b) - 0.5) * contrastScale);
            scale_luminance(&r, &g, &b, tone_highlights(rec709(r, g, b), highlightAmount));
            scale_luminance(&r, &g, &b, tone_shadows(rec709(r, g, b), shadowAmount));
            scale_luminance(&r, &g, &b, tone_whites(rec709(r, g, b), whiteAmount));
            scale_luminance(&r, &g, &b, tone_blacks(rec709(r, g, b), blackAmount));
            vibrance_and_saturation(&r, &g, &b, vibranceAmount, saturationAmount);
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
    }
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
    for (size_t y = 0; y < height; ++y) {
        double sum = 0;
        for (int k = -radius; k <= radius; ++k) sum += src[y * width + clamped_index(k, width)];
        for (size_t x = 0; x < width; ++x) {
            temp[y * width + x] = (float)(sum / window);
            sum += src[y * width + clamped_index((int)x + radius + 1, width)];
            sum -= src[y * width + clamped_index((int)x - radius, width)];
        }
    }
    for (size_t x = 0; x < width; ++x) {
        double sum = 0;
        for (int k = -radius; k <= radius; ++k) sum += temp[clamped_index(k, height) * width + x];
        for (size_t y = 0; y < height; ++y) {
            dst[y * width + x] = (float)(sum / window);
            sum += temp[clamped_index((int)y + radius + 1, height) * width + x];
            sum -= temp[clamped_index((int)y - radius, height) * width + x];
        }
    }
    free(temp);
    return 1;
}

static int effects_radius(double base, double scale) {
    double radius = base * (scale > 0 ? scale : 1);
    if (radius < 1) radius = 1;
    if (radius > 64) radius = 64;
    return (int)lround(radius);
}

static void effects_dehaze(double *r, double *g, double *b, double amount) {
    double d = amount / 100.0;
    double y = rec709(*r, *g, *b);
    double contrast = 1.0 + 0.8 * d;
    double pivot = 0.45 - 0.1 * (d > 0 ? d : 0);
    double y2 = camera_clamp(pivot + (y - 0.45) * contrast);
    if (d < 0) y2 = camera_clamp(y2 + (-d) * (1.0 - y2) * 0.45);
    else y2 = camera_clamp(y2 - d * fmax(0.0, 0.4 - y2));
    scale_luminance(r, g, b, y2);
    y2 = rec709(*r, *g, *b);
    double sat = 1.0 + 0.7 * d;
    *r = camera_clamp(y2 + (*r - y2) * sat);
    *g = camera_clamp(y2 + (*g - y2) * sat);
    *b = camera_clamp(y2 + (*b - y2) * sat);
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
    double mask = vignette_mask(x, y, width, height, midpoint, roundness, feather);
    double effect = (amount / 100.0) * mask;
    // Highlight Priority eases a darkening vignette off bright pixels. The other styles do not.
    if (effect < 0 && style == 0) {
        double bright = camera_clamp((rec709(*r, *g, *b) - 0.45) / 0.55);
        effect *= 1.0 - (highlights / 100.0) * bright;
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
        for (size_t y = 0; y < height; ++y) {
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
        }
        if (texture != 0) {
            fine = malloc(count * sizeof(float));
            if (!fine || !box_blur_plane(luma, fine, width, height, effects_radius(1, scale))) failed = 1;
        }
        if (!failed && clarity != 0) {
            coarse = malloc(count * sizeof(float));
            if (!coarse || !box_blur_plane(luma, coarse, width, height, effects_radius(4, scale))) failed = 1;
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
    for (size_t y = 0; y < height; ++y) {
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
                if (fine) detail += (texture / 100.0) * (tone - fine[index]);
                if (coarse) detail += (clarity / 100.0) * (tone - coarse[index]);
                if (detail != 0) scale_luminance(&r, &g, &b, camera_clamp(tone + detail));
            }
            if (dehaze != 0) effects_dehaze(&r, &g, &b, dehaze);
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
    }
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
                                   const float *lumaLut, const float *redLut, const float *greenLut, const float *blueLut,
                                   double refineSaturation, const float *mixer, int pointCount, const float *points,
                                   const float *grade, double blending, double balance, int visualize) {
    for (size_t y = 0; y < height; ++y) {
        uint8_t *row = rgba + y * stride;
        for (size_t x = 0; x < width; ++x) {
            uint8_t *p = row + x * 4;
            double alpha = p[3];
            if (!alpha) continue;
            double r = fmin(1.0, p[0] / alpha), g = fmin(1.0, p[1] / alpha), b = fmin(1.0, p[2] / alpha);
            double tone = rec709(r, g, b);
            double mapped = lut_at(lumaLut, tone);
            scale_luminance(&r, &g, &b, mapped);
            if (refineSaturation != 0 && tone > 1e-4) {
                double factor = 1 + refineSaturation * (mapped / tone - 1);
                double lum = rec709(r, g, b);
                r = camera_clamp(lum + (r - lum) * factor);
                g = camera_clamp(lum + (g - lum) * factor);
                b = camera_clamp(lum + (b - lum) * factor);
            }
            r = lut_at(redLut, r); g = lut_at(greenLut, g); b = lut_at(blueLut, b);
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
    if (noiseLuminance > 0) {
        int radius = effects_radius(1.0 + noiseLuminance / 50.0, scale);
        if (!box_blur_plane(luma, work, width, height, radius)) { free(luma); free(work); return; }
        double strength = noiseLuminance / 100.0;
        double preserve = noiseLuminanceDetail / 100.0;
        double contrast = noiseLuminanceContrast / 100.0;
        for (size_t y = 0; y < height; ++y) {
            uint8_t *row = rgba + y * stride;
            for (size_t x = 0; x < width; ++x) {
                uint8_t *p = row + x * 4;
                double alpha = p[3];
                if (!alpha) continue;
                size_t index = y * width + x;
                float edge = sharpen_edge_at(luma, width, height, x, y, 1);
                double local = strength * (1.0 - preserve * fmin(1.0, edge * 6.0));
                float blurred = work[index];
                float target = (float)(luma[index] * (1.0 - local) + blurred * local);
                if (contrast != 0) target = (float)(target + contrast * 0.25 * (luma[index] - blurred));
                luma[index] = target;
                double r = fmin(1.0, p[0] / alpha), g = fmin(1.0, p[1] / alpha), b = fmin(1.0, p[2] / alpha);
                scale_luminance(&r, &g, &b, target);
                write_premultiplied(p, r, g, b, alpha);
            }
        }
    }
    if (noiseColor > 0) {
        int radius = effects_radius(1.0 + noiseColorSmoothness / 40.0, scale);
        float *chroma = malloc(count * sizeof(float));
        float *chromaBlur = malloc(count * sizeof(float));
        if (!chroma || !chromaBlur) { free(chroma); free(chromaBlur); free(luma); free(work); return; }
        for (size_t y = 0; y < height; ++y) {
            uint8_t *row = rgba + y * stride;
            for (size_t x = 0; x < width; ++x) {
                uint8_t *p = row + x * 4;
                double alpha = p[3];
                if (!alpha) continue;
                double r = fmin(1.0, p[0] / alpha), g = fmin(1.0, p[1] / alpha), b = fmin(1.0, p[2] / alpha);
                double h, s, l;
                rgb_to_hsl(r, g, b, &h, &s, &l);
                chroma[y * width + x] = (float)s;
            }
        }
        if (!box_blur_plane(chroma, chromaBlur, width, height, radius)) {
            free(chroma); free(chromaBlur); free(luma); free(work); return;
        }
        double strength = noiseColor / 100.0;
        double preserve = noiseColorDetail / 100.0;
        for (size_t y = 0; y < height; ++y) {
            uint8_t *row = rgba + y * stride;
            for (size_t x = 0; x < width; ++x) {
                uint8_t *p = row + x * 4;
                double alpha = p[3];
                if (!alpha) continue;
                size_t index = y * width + x;
                float edge = fabsf(chroma[index] - chromaBlur[index]);
                double local = strength * (1.0 - preserve * fmin(1.0, edge * 4.0));
                float sat = chroma[index] * (float)(1.0 - local) + chromaBlur[index] * (float)local;
                double r = fmin(1.0, p[0] / alpha), g = fmin(1.0, p[1] / alpha), b = fmin(1.0, p[2] / alpha);
                double h, s, l;
                rgb_to_hsl(r, g, b, &h, &s, &l);
                s = sat;
                hsl_to_rgb(h, s, l, &r, &g, &b);
                write_premultiplied(p, r, g, b, alpha);
            }
        }
        free(chroma);
        free(chromaBlur);
    }
    if (sharpenAmount > 0) {
        for (size_t y = 0; y < height; ++y) {
            uint8_t *row = rgba + y * stride;
            for (size_t x = 0; x < width; ++x) {
                uint8_t *p = row + x * 4;
                double alpha = p[3];
                if (!alpha) continue;
                double r = fmin(1.0, p[0] / alpha), g = fmin(1.0, p[1] / alpha), b = fmin(1.0, p[2] / alpha);
                luma[y * width + x] = (float)rec709(r, g, b);
            }
        }
        int radius = effects_radius(detail_radius(sharpenRadius, scale), 1);
        if (!box_blur_plane(luma, work, width, height, radius)) { free(luma); free(work); return; }
        double amount = sharpenAmount / 100.0;
        double detailMix = sharpenDetail / 100.0;
        double threshold = (sharpenMasking / 100.0) * 0.35;
        for (size_t y = 0; y < height; ++y) {
            uint8_t *row = rgba + y * stride;
            for (size_t x = 0; x < width; ++x) {
                uint8_t *p = row + x * 4;
                double alpha = p[3];
                if (!alpha) continue;
                size_t index = y * width + x;
                float edge = sharpen_edge_at(luma, width, height, x, y, radius);
                double mask = camera_clamp((edge * (0.5 + detailMix) - threshold) / fmax(0.04, 0.35 - threshold * 0.5));
                double high = luma[index] - work[index];
                double sharpened = camera_clamp(luma[index] + high * amount * mask * (0.5 + detailMix));
                double r = fmin(1.0, p[0] / alpha), g = fmin(1.0, p[1] / alpha), b = fmin(1.0, p[2] / alpha);
                scale_luminance(&r, &g, &b, sharpened);
                write_premultiplied(p, r, g, b, alpha);
            }
        }
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

static void optics_vignette_correct(double *r, double *g, double *b, size_t x, size_t y, size_t width, size_t height,
                                    double amount, double midpoint) {
    if (amount == 0 || width == 0 || height == 0) return;
    double nx = ((double)x + 0.5) / (double)width * 2.0 - 1.0;
    double ny = ((double)y + 0.5) / (double)height * 2.0 - 1.0;
    double dist = hypot(nx, ny) / sqrt(2.0);
    double start = (midpoint / 100.0) * 0.85;
    double t = camera_clamp((dist - start) / 0.35);
    double mask = t * t * (3.0 - 2.0 * t);
    double lift = (amount / 100.0) * mask;
    if (lift > 0) {
        *r = camera_clamp(*r + (1.0 - *r) * lift);
        *g = camera_clamp(*g + (1.0 - *g) * lift);
        *b = camera_clamp(*b + (1.0 - *b) * lift);
    } else {
        double factor = 1.0 + lift;
        *r *= factor; *g *= factor; *b *= factor;
    }
}

void adjust_camera_raw_optics(uint8_t *rgba, size_t width, size_t height, size_t stride,
                              int removeChromatic, int lensProfile, double profileDistortion, double profileVignetting,
                              double distortionK, double purpleAmount, double purpleHueLow, double purpleHueHigh,
                              double greenAmount, double greenHueLow, double greenHueHigh,
                              double vignetteAmount, double vignetteMidpoint, double scale) {
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
    for (size_t y = 0; y < height; ++y) {
        uint8_t *row = rgba + y * stride;
        for (size_t x = 0; x < width; ++x) {
            uint8_t *p = row + x * 4;
            double alpha = p[3];
            if (!alpha) continue;
            double r = fmin(1.0, p[0] / alpha), g = fmin(1.0, p[1] / alpha), b = fmin(1.0, p[2] / alpha);
            optics_defringe(&r, &g, &b, purpleAmount, purpleHueLow, purpleHueHigh, greenAmount, greenHueLow, greenHueHigh);
            optics_vignette_correct(&r, &g, &b, x, y, width, height, vignette, vignetteMidpoint);
            write_premultiplied(p, r, g, b, alpha);
        }
    }
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
    for (size_t y = 0; y < height; ++y) {
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
    }
}
