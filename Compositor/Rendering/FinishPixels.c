#include "FinishPixels.h"
#include <dispatch/dispatch.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

static float clamp01(float x) { return fminf(1, fmaxf(0, x)); }
static float smooth(float a, float b, float x) {
    float t = clamp01((x - a) / (b - a));
    return t * t * (3 - 2 * t);
}
static int edge(int i, int n) { return i < 0 ? 0 : i >= n ? n - 1 : i; }

// Sliding windows keep processing linear in pixel count even on large architectural renders.
// Three box passes approximate a Gaussian, with clamped image borders. Rows run in parallel; the
// vertical pass walks strips of columns row by row, so it reads memory in order instead of striding.
enum { STRIP = 64 };
typedef struct { const float *in; float *out; int w, h, r; } BlurPass;

static void blur_row(void *context, size_t y) {
    const BlurPass *p = context;
    const float *in = p->in + y * (size_t)p->w;
    float *out = p->out + y * (size_t)p->w;
    int w = p->w, r = p->r;
    double sum = 0, scale = 1.0 / (2 * r + 1);
    for (int k = -r; k <= r; ++k) sum += in[edge(k, w)];
    for (int x = 0; x < w; ++x) {
        out[x] = (float)(sum * scale);
        sum += in[edge(x + r + 1, w)] - in[edge(x - r, w)];
    }
}

static void blur_strip(void *context, size_t strip) {
    const BlurPass *p = context;
    int w = p->w, h = p->h, r = p->r;
    int x0 = (int)strip * STRIP, n = w - x0 < STRIP ? w - x0 : STRIP;
    double sums[STRIP] = {0}, scale = 1.0 / (2 * r + 1);
    for (int k = -r; k <= r; ++k) {
        const float *row = p->in + (size_t)edge(k, h) * (size_t)w + (size_t)x0;
        for (int i = 0; i < n; ++i) sums[i] += row[i];
    }
    for (int y = 0; y < h; ++y) {
        float *out = p->out + (size_t)y * (size_t)w + (size_t)x0;
        const float *add = p->in + (size_t)edge(y + r + 1, h) * (size_t)w + (size_t)x0;
        const float *sub = p->in + (size_t)edge(y - r, h) * (size_t)w + (size_t)x0;
        for (int i = 0; i < n; ++i) {
            out[i] = (float)(sums[i] * scale);
            sums[i] += add[i] - sub[i];
        }
    }
}

static void blur(float *values, float *scratch, int w, int h, int r) {
    BlurPass across = {values, scratch, w, h, r}, down = {scratch, values, w, h, r};
    size_t strips = ((size_t)w + STRIP - 1) / STRIP;
    for (int pass = 0; pass < 3; ++pass) {
        dispatch_apply_f((size_t)h, DISPATCH_APPLY_AUTO, &across, blur_row);
        dispatch_apply_f(strips, DISPATCH_APPLY_AUTO, &down, blur_strip);
    }
}

// Unpremultiplied luminance, weighted by alpha (and for glows, by brightness above a threshold) for the
// neighbourhood blur.
typedef struct { const uint8_t *rgba; size_t stride; int w; float bright_from, bright_to; float *base, *coverage; } Fill;

static void fill_row(void *context, size_t y) {
    const Fill *f = context;
    const uint8_t *row = f->rgba + y * f->stride;
    for (int x = 0; x < f->w; ++x) {
        const uint8_t *p = row + (size_t)x * 4;
        size_t i = y * (size_t)f->w + (size_t)x;
        float a = p[3] / 255.f;
        float l = p[3] ? (.2126f * p[0] + .7152f * p[1] + .0722f * p[2]) / p[3] : 0;
        f->base[i] = (f->bright_to > 0 ? l * smooth(f->bright_from, f->bright_to, l) : l) * a;
        if (f->coverage) f->coverage[i] = a;
    }
}

// One color channel (premultiplied, 0...255) or alpha, for Lens Softness.
typedef struct { const uint8_t *rgba; size_t stride; int w, channel; float *plane; } ChannelFill;

static void channel_row(void *context, size_t y) {
    const ChannelFill *f = context;
    const uint8_t *row = f->rgba + y * f->stride;
    float *out = f->plane + y * (size_t)f->w;
    for (int x = 0; x < f->w; ++x) out[x] = row[(size_t)x * 4 + (size_t)f->channel];
}

// Grain: smoothly interpolated lattice noise in whole-image pixels, so a crop and the whole image agree.
static uint32_t mix32(uint32_t x) {
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
    return x;
}
static float lattice(int64_t i, int64_t j, uint32_t seed) {
    uint32_t h = mix32((uint32_t)i * 0x9e3779b1u ^ mix32((uint32_t)j + seed * 0x85ebca6bu));
    return (float)(h >> 8) * (2.f / 16777216.f) - 1;
}
static float grain_noise(float x, float y, float cell, uint32_t seed) {
    float u = (x + .5f) / cell - .5f, v = (y + .5f) / cell - .5f;
    float fu = floorf(u), fv = floorf(v), a = u - fu, b = v - fv;
    int64_t i = (int64_t)fu, j = (int64_t)fv;
    a = a * a * (3 - 2 * a); b = b * b * (3 - 2 * b);
    float top = lattice(i, j, seed) + (lattice(i + 1, j, seed) - lattice(i, j, seed)) * a;
    float bottom = lattice(i, j + 1, seed) + (lattice(i + 1, j + 1, seed) - lattice(i, j + 1, seed)) * a;
    return top + (bottom - top) * b;
}

// Original duotone palettes, not Nik's proprietary color sets.
static const float inks[6][6] = {
    {.055f,.065f,.085f, .96f,.95f,.91f}, // carbon
    {.11f,.055f,.025f, 1,.93f,.78f},     // sepia
    {.025f,.10f,.20f, .89f,.96f,1},      // cyanotype
    {.11f,.065f,.14f, .99f,.91f,.84f},   // warm violet
    {.025f,.13f,.12f, .92f,.98f,.88f},   // teal
    {.16f,.045f,.035f, 1,.94f,.86f}      // copper
};
static const float gains[5] = {1, 1.25f, .85f, .85f, 1.65f};
static const float halation_tint[3] = {1, .42f, .22f};

typedef struct {
    uint8_t *rgba; size_t stride; int w, kind, palette, contrast_type;
    // Blurred luminance; divided by blurred coverage unless the image is opaque (coverage NULL).
    const float *base, *coverage;
    float amount, shadows, midtones, highlights, saturation, protect_shadows, protect_highlights;
    float full_w, full_h, offset_x, offset_y;
    // Sensor Grain: its cell in processed pixels, and how much of it survives a preview smaller than the grain.
    float grain_cell, grain_gain;
    uint32_t seed;
} Finish;

static void finish_row(void *context, size_t y) {
    // A copy, not the caller's struct: stores through the byte pointer could alias its fields and force reloads.
    const Finish settings = *(const Finish *)context, *f = &settings;
    const float *base = settings.base, *coverage = settings.coverage;
    const int w = settings.w;
    uint8_t *row = settings.rgba + y * settings.stride;
    for (int x = 0; x < w; ++x) {
        uint8_t *p = row + (size_t)x * 4;
        if (!p[3]) continue;
        size_t i = y * (size_t)w + (size_t)x;
        float low = !base ? 0 : !coverage ? base[i] : coverage[i] > 1e-6f ? base[i] / coverage[i] : 0;
        float rgb[3] = {p[0] / (float)p[3], p[1] / (float)p[3], p[2] / (float)p[3]};
        float l = .2126f * rgb[0] + .7152f * rgb[1] + .0722f * rgb[2];
        float out[3] = {rgb[0], rgb[1], rgb[2]};
        if (f->kind == 0 || f->kind == 3) {
            float sw = 1 - smooth(.15f,.5f,low), hw = smooth(.5f,.85f,low);
            float weight = f->kind == 0 ? f->shadows * sw + f->highlights * hw + f->midtones * (1 - sw - hw) : 1;
            // Bounded detail gain avoids hard clipping; highlight/shadow protection fades at endpoints.
            float detail = l - low;
            float response = f->kind == 0 && f->contrast_type == 1
                ? fmaxf(-.24f, fminf(.24f, detail * 1.5f)) : .18f * tanhf(detail * 6);
            float delta = response * weight * (4 * l * (1 - l));
            if (f->kind == 0) delta *= gains[f->contrast_type];
            if (f->kind == 3) delta += (.5f - low) * .18f * (4 * l * (1 - l));
            for (int c = 0; c < 3; ++c) out[c] += delta;
        } else if (f->kind == 1) {
            float tone = smooth(0, 1, l);
            for (int c = 0; c < 3; ++c) out[c] = inks[f->palette][c] * (1-tone) + inks[f->palette][c+3] * tone;
        } else if (f->kind == 2) {
            float target = l + .65f * (l - .5f) * l * (1-l);
            for (int c = 0; c < 3; ++c) out[c] += target - l;
        } else if (f->kind == 4) {
            float light = low * .8f;
            for (int c = 0; c < 3; ++c) out[c] = 1 - (1 - rgb[c]) * (1 - light);
        } else if (f->kind == 7) {
            // Film-like: strongest in the midtones, fainter toward black and white, the same on every channel.
            float grain = grain_noise((float)x + f->offset_x, (float)y + f->offset_y, f->grain_cell, f->seed);
            float d = grain * f->grain_gain * .09f * (.3f + 2.8f * l * (1 - l));
            for (int c = 0; c < 3; ++c) out[c] += d;
        } else if (f->kind == 8) {
            // Only the finest scale; a small threshold leaves flat areas (and their noise) alone, and the
            // boost is bounded so edges don't halo.
            float d = l - low, magnitude = fmaxf(fabsf(d) - .004f, 0);
            float boost = copysignf(fminf(magnitude * 2.4f, .12f), d) * fminf(1, 5 * l * (1 - l));
            for (int c = 0; c < 3; ++c) out[c] += boost;
        } else if (f->kind == 9) {
            // A shoulder above the knee (slope 1 there, white eased down), with highlights losing color as
            // they near white the way a sensor does, then a warm halation around the brightest areas.
            const float knee = .62f;
            float u = clamp01((l - knee) / (1 - knee));
            if (u > 0) {
                float target = knee + (1 - knee) * (u - .25f * u * u), scale = target / l, desaturate = .5f * u * u;
                for (int c = 0; c < 3; ++c) {
                    float v = rgb[c] * scale;
                    out[c] = v + (target - v) * desaturate;
                }
            }
            float glow = low * fmaxf(0, f->highlights) * .6f;
            for (int c = 0; c < 3; ++c) out[c] = 1 - (1 - out[c]) * (1 - glow * halation_tint[c]);
        } else if (f->kind == 5) {
            float warmth = f->shadows; // signed temperature; Strength then mixes the result like every effect
            out[0] += warmth * .15f * (1 - rgb[0]);
            out[1] += warmth * .025f * (1 - rgb[1]);
            out[2] -= warmth * .15f * rgb[2];
        } else {
            float nx = 2 * ((float)x + f->offset_x + .5f) / f->full_w - 1;
            float ny = 2 * ((float)y + f->offset_y + .5f) / f->full_h - 1;
            float falloff = smooth(.25f, 1.4f, sqrtf(nx*nx + ny*ny));
            for (int c = 0; c < 3; ++c) out[c] *= 1 - .8f * falloff;
        }
        if (f->kind == 0) {
            // Recover tone gently within each range and suppress contrast that pushes toward clipping.
            float sw = 1 - smooth(.15f, .5f, l), hw = smooth(.5f, .85f, l);
            for (int c = 0; c < 3; ++c) {
                float delta = out[c] - rgb[c];
                delta *= 1 - clamp01(delta < 0 ? f->protect_shadows * sw : f->protect_highlights * hw);
                out[c] = rgb[c] + delta + .25f * (f->protect_shadows * sw * (1-l) - f->protect_highlights * hw * l);
            }
        }
        float lum = .2126f*out[0] + .7152f*out[1] + .0722f*out[2];
        for (int c = 0; c < 3; ++c) {
            float value = clamp01(lum + (out[c] - lum) * (1 + f->saturation));
            p[c] = (uint8_t)lroundf(clamp01(rgb[c] + f->amount * (value - rgb[c])) * p[3]);
        }
    }
}

// Chromatic Aberration: red sampled farther from the whole image's center, blue nearer, green in place.
typedef struct {
    uint8_t *rgba; const uint8_t *source; size_t stride; int w, h, opaque;
    float cx, cy, k, offset_x, offset_y;
} Aberration;

static float sample_channel(const Aberration *s, float x, float y, int channel, float alpha, float fallback) {
    x = fminf(fmaxf(x, 0), (float)(s->w - 1)); y = fminf(fmaxf(y, 0), (float)(s->h - 1));
    int x0 = (int)x, y0 = (int)y, x1 = x0 + 1 < s->w ? x0 + 1 : x0, y1 = y0 + 1 < s->h ? y0 + 1 : y0;
    float a = x - (float)x0, b = y - (float)y0;
    const uint8_t *row0 = s->source + (size_t)y0 * s->stride, *row1 = s->source + (size_t)y1 * s->stride;
    float top = row0[(size_t)x0 * 4 + (size_t)channel] * (1 - a) + row0[(size_t)x1 * 4 + (size_t)channel] * a;
    float bottom = row1[(size_t)x0 * 4 + (size_t)channel] * (1 - a) + row1[(size_t)x1 * 4 + (size_t)channel] * a;
    float value = top * (1 - b) + bottom * b;
    if (s->opaque) return value;
    float top_alpha = row0[(size_t)x0 * 4 + 3] * (1 - a) + row0[(size_t)x1 * 4 + 3] * a;
    float bottom_alpha = row1[(size_t)x0 * 4 + 3] * (1 - a) + row1[(size_t)x1 * 4 + 3] * a;
    float coverage = top_alpha * (1 - b) + bottom_alpha * b;
    // Preserve the destination's alpha: sampling premultiplied color directly would turn an
    // opacity boundary into a dark colored fringe. A fully transparent sample has no color.
    return coverage > 1e-6f ? value / coverage * alpha : fallback;
}

static void aberration_row(void *context, size_t y) {
    const Aberration settings = *(const Aberration *)context, *s = &settings;
    uint8_t *row = s->rgba + y * s->stride;
    for (int x = 0; x < s->w; ++x) {
        uint8_t *p = row + (size_t)x * 4;
        if (!p[3]) continue;
        // From the whole image's center, in its pixels; back to this crop's sample positions.
        float dx = (float)x + s->offset_x + .5f - s->cx, dy = (float)y + s->offset_y + .5f - s->cy;
        float red = sample_channel(s, s->cx + dx * (1 + s->k) - s->offset_x - .5f, s->cy + dy * (1 + s->k) - s->offset_y - .5f, 0, p[3], p[0]);
        float blue = sample_channel(s, s->cx + dx * (1 - s->k) - s->offset_x - .5f, s->cy + dy * (1 - s->k) - s->offset_y - .5f, 2, p[3], p[2]);
        p[0] = (uint8_t)lroundf(fminf(red, p[3]));
        p[2] = (uint8_t)lroundf(fminf(blue, p[3]));
    }
}

// Lens Softness: each channel mixed toward its blur, more toward the corners of the whole image. With
// transparency, the blurred color is divided by blurred alpha so edges don't darken.
typedef struct {
    uint8_t *rgba; size_t stride; int w, channel;
    const float *blurred, *coverage;
    float amount, full_w, full_h, offset_x, offset_y;
} Soften;

static void soften_row(void *context, size_t y) {
    const Soften settings = *(const Soften *)context, *s = &settings;
    uint8_t *row = s->rgba + y * s->stride;
    for (int x = 0; x < s->w; ++x) {
        uint8_t *p = row + (size_t)x * 4;
        if (!p[3]) continue;
        size_t i = y * (size_t)s->w + (size_t)x;
        float nx = 2 * ((float)x + s->offset_x + .5f) / s->full_w - 1;
        float ny = 2 * ((float)y + s->offset_y + .5f) / s->full_h - 1;
        float weight = s->amount * smooth(.3f, 1.25f, sqrtf(nx * nx + ny * ny));
        float blurred = s->blurred[i];
        if (s->coverage) blurred = s->coverage[i] > .5f ? blurred / s->coverage[i] * p[3] : p[s->channel];
        float value = p[s->channel] + weight * (blurred - p[s->channel]);
        p[s->channel] = (uint8_t)lroundf(fminf(fmaxf(value, 0), p[3]));
    }
}

typedef struct { const uint8_t *rgba; size_t stride, width; atomic_int opaque; } OpaqueScan;

static void scan_row(void *context, size_t y) {
    OpaqueScan *scan = context;
    if (!atomic_load_explicit(&scan->opaque, memory_order_relaxed)) return;
    const uint8_t *row = scan->rgba + y * scan->stride;
    for (size_t x = 0; x < scan->width; ++x)
        if (row[x * 4 + 3] != 255) { atomic_store_explicit(&scan->opaque, 0, memory_order_relaxed); return; }
}

// Effects that blur a luminance plane (normalized by blurred coverage) before the per-pixel pass.
static int is_spatial(const FinishEffectSettings *effect) {
    switch (effect->kind) {
        case 0: return effect->shadows != 0 || effect->midtones != 0 || effect->highlights != 0;
        case 9: return effect->highlights > 0; // Highlight rolloff itself is a per-pixel tone curve.
        case 3: case 4: case 8: return 1;
        default: return 0;
    }
}

static int valid_effect(const FinishEffectSettings *e) {
    return e->kind >= 0 && e->kind <= 11 && isfinite(e->amount) && isfinite(e->radius) && isfinite(e->saturation)
        && isfinite(e->protect_shadows) && isfinite(e->protect_highlights)
        && isfinite(e->shadows) && isfinite(e->midtones) && isfinite(e->highlights);
}

int finish_apply_stack(uint8_t *rgba, size_t width, size_t height, size_t stride,
                       size_t full_width, size_t full_height, size_t offset_x, size_t offset_y,
                       const FinishEffectSettings *effects, size_t count) {
    if (!rgba || !width || !height || width > INT_MAX / 2 || height > INT_MAX / 2
        || width > SIZE_MAX / 4 || stride < width * 4 || height > SIZE_MAX / stride
        || width > SIZE_MAX / height / sizeof(float)
        || full_width > INT_MAX || full_height > INT_MAX
        || offset_x > full_width || width > full_width - offset_x
        || offset_y > full_height || height > full_height - offset_y || (!effects && count)) return 0;
    int spatial = 0, copies = 0;
    for (size_t e = 0; e < count; ++e) {
        if (!valid_effect(&effects[e])) return 0;
        int active = clamp01(effects[e].amount) > 0;
        spatial |= (is_spatial(&effects[e]) || effects[e].kind == 11) && active;
        copies |= effects[e].kind == 10 && active;
    }
    int w = (int)width, h = (int)height;
    // Working planes are shared by every spatial effect in the stack, so they are allocated (and first
    // touched) once. Renders are usually opaque: then blurred coverage is 1 everywhere and needs no plane.
    float *base = NULL, *coverage = NULL, *scratch = NULL;
    uint8_t *source = NULL;
    if (copies && !(source = malloc(height * stride))) return 0;
    int opaque = 1;
    if (spatial || copies) {
        OpaqueScan scan = {rgba, stride, width, 1};
        dispatch_apply_f(height, DISPATCH_APPLY_AUTO, &scan, scan_row);
        opaque = atomic_load(&scan.opaque);
    }
    if (spatial) {
        size_t bytes = width * height * sizeof(float);
        base = malloc(bytes);
        scratch = malloc(bytes);
        if (!opaque) coverage = malloc(bytes);
        if (!base || !scratch || (!opaque && !coverage)) { free(base); free(coverage); free(scratch); free(source); return 0; }
    }
    static const float radii[5] = {1, .5f, .25f, 1.5f, 2};
    for (size_t e = 0; e < count; ++e) {
        FinishEffectSettings effect = effects[e];
        float amount = clamp01(effect.amount);
        if (amount == 0) continue;
        int kind = effect.kind;
        int uses_base = is_spatial(&effect);
        int contrast_type = effect.contrast_type < 0 || effect.contrast_type > 4 ? 0 : effect.contrast_type;
        if (kind == 10) {
            // Fringe width at the corners, in processed pixels; Strength scales the shift rather than mixing.
            float cx = (float)full_width / 2, cy = (float)full_height / 2;
            float shift = fminf(200, fmaxf(0, effect.radius)) * amount;
            memcpy(source, rgba, height * stride);
            Aberration aberration = {rgba, source, stride, w, h, opaque, cx, cy, shift / fmaxf(1, sqrtf(cx * cx + cy * cy)),
                                     (float)offset_x, (float)offset_y};
            dispatch_apply_f(height, DISPATCH_APPLY_AUTO, &aberration, aberration_row);
            continue;
        }
        if (kind == 11) {
            int r = (int)fmaxf(1, fminf(500, roundf(effect.radius)));
            if (coverage) {
                ChannelFill alpha = {rgba, stride, w, 3, coverage};
                dispatch_apply_f(height, DISPATCH_APPLY_AUTO, &alpha, channel_row);
                blur(coverage, scratch, w, h, r);
            }
            for (int channel = 0; channel < 3; ++channel) {
                ChannelFill fill = {rgba, stride, w, channel, base};
                dispatch_apply_f(height, DISPATCH_APPLY_AUTO, &fill, channel_row);
                blur(base, scratch, w, h, r);
                Soften soften = {rgba, stride, w, channel, base, coverage, amount,
                                 (float)full_width, (float)full_height, (float)offset_x, (float)offset_y};
                dispatch_apply_f(height, DISPATCH_APPLY_AUTO, &soften, soften_row);
            }
            continue;
        }
        if (uses_base) {
            float radius = kind == 0 ? effect.radius * radii[contrast_type] : effect.radius;
            Fill fill = {rgba, stride, w, kind == 4 ? .55f : .72f, kind == 4 || kind == 9 ? (kind == 4 ? .95f : 1) : 0,
                         base, coverage};
            dispatch_apply_f(height, DISPATCH_APPLY_AUTO, &fill, fill_row);
            int r = (int)fmaxf(1, fminf(500, roundf(radius)));
            blur(base, scratch, w, h, r);
            if (coverage) blur(coverage, scratch, w, h, r);
        }
        Finish finish = {
            rgba, stride, w, kind, effect.palette < 0 ? 0 : effect.palette > 5 ? 5 : effect.palette, contrast_type,
            uses_base ? base : NULL, uses_base ? coverage : NULL,
            amount, effect.shadows, effect.midtones, effect.highlights, effect.saturation,
            effect.protect_shadows, effect.protect_highlights,
            (float)full_width, (float)full_height, (float)offset_x, (float)offset_y,
            fmaxf(.05f, effect.radius), fminf(1, fmaxf(.05f, effect.radius)), effect.seed
        };
        dispatch_apply_f(height, DISPATCH_APPLY_AUTO, &finish, finish_row);
    }
    free(base); free(coverage); free(scratch); free(source);
    return 1;
}

int finish_apply_region(uint8_t *rgba, size_t width, size_t height, size_t stride,
                        size_t full_width, size_t full_height, size_t offset_x, size_t offset_y,
                        int kind, float amount, float shadows, float midtones, float highlights,
                        float radius, float saturation, int palette, int contrast_type,
                        float protect_shadows, float protect_highlights) {
    FinishEffectSettings effect = {kind, amount, shadows, midtones, highlights, radius, saturation,
                                   palette, contrast_type, protect_shadows, protect_highlights, 0};
    return finish_apply_stack(rgba, width, height, stride, full_width, full_height, offset_x, offset_y, &effect, 1);
}

int finish_apply(uint8_t *rgba, size_t width, size_t height, size_t stride,
                 int kind, float amount, float shadows, float midtones, float highlights,
                 float radius, float saturation, int palette, int contrast_type,
                 float protect_shadows, float protect_highlights) {
    return finish_apply_region(rgba, width, height, stride, width, height, 0, 0, kind, amount, shadows, midtones,
                               highlights, radius, saturation, palette, contrast_type, protect_shadows, protect_highlights);
}
