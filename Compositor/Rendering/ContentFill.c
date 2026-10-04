#include "ContentFill.h"
#include <dispatch/dispatch.h>
#include <float.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

// Content-Aware Fill as Wexler, Shechtman and Irani's completion (2007), with PatchMatch (Barnes et al. 2009) to
// find the matches: coarse to fine over a pyramid, each level alternating a search for every patch touching the hole
// with a vote, where each hole pixel becomes the weighted mean of what the patches covering it would put there.
//
// A source patch stands in lifted or lowered to the brightness of the patch it replaces, as Darabi et al.'s image
// melding (2012) lets patches vary in gain and bias. The hole starts, at the coarsest level, as a membrane stretched
// across from what lies around it, so the light keeps changing across the hole as it does outside, and the sources'
// own light, far off or near, doesn't darken or tint it.

enum { OUT = 0, KNOWN = 1, HOLE = 2 };
enum { RADIUS = 3, MAX_LEVELS = 16 };
// A blurred or flat source should not stand in for texture: patches also compare how busy they are, the mean
// gradient around each pixel at the level's own scale (Newson et al. 2014), at this weight against a color channel.
static const int textureWeight = 4;
// How far a source may be lifted or lowered to fit, in levels of 255: overall, and on any one channel besides. Each
// level it is moved costs a quarter of a level squared per channel, so that a source with the patch's own light is
// still preferred: lifting a plain patch to stand in for one with a bright line would otherwise cost it nothing,
// and fills would lose their lines to plain patches lifted to match.
static const int liftLimit = 40, tintLimit = 4;
// What a match costs, per pixel of its patch, for each neighbor whose match it doesn't carry on: matches hold
// together in larger pieces, which keeps a pattern's lines whole rather than broken into dashes.
static const int coherence = 80;

// The loops every core runs, left out of code coverage's counting: its counters, which all the cores would share,
// would make a fill slower on all of them than on one. What they call is left out too, or it couldn't be inlined.
#define UNCOUNTED __attribute__((no_profile_instrument_function))

typedef struct {
    int w, h;
    uint8_t *rgb;       // 4 bytes a pixel: red, green, blue and the texture measure
    uint8_t *state;     // OUT (transparent, left alone), KNOWN or HOLE
    uint8_t *valid;     // a source patch may be centered here: all of it known
    uint8_t *mean;      // 3 bytes a pixel: the mean color of the source patch centered there
    int *sources;       // the centers that are valid, in order
    int sourceCount;
    int opaque;         // no pixel is OUT, so a patch inside the level is compared whole
    int bx, by, bw, bh; // the box of patch centers that touch the hole
    int *nnf;           // per box cell: the matched source center as an index into the level, or -1 for no patch
    int *cost;
    float *weight;
    uint8_t *target;    // per box cell, 3 bytes: the mean color of the patch there as it stands
    int8_t *shift;      // per box cell, 3 bytes: what its match is lifted or lowered by in the vote
} Level;

// Runs `body` over `count` items split into runs, each a (start, end) range, all at once: 32 runs, so a few per core,
// or for fewer than 64 items two to a run, as even a few rows of patches take a while to match.
static void in_bands(size_t count, void (^body)(size_t start, size_t end)) {
    size_t bands = count < 16 ? 1 : count < 64 ? count / 2 : 32, size = (count + bands - 1) / bands;
    dispatch_apply(bands, DISPATCH_APPLY_AUTO, ^(size_t band) {
        size_t start = band * size, end = start + size < count ? start + size : count;
        if (start < end) body(start, end);
    });
}

UNCOUNTED static inline uint32_t next_random(uint32_t *s) {
    *s ^= *s << 13; *s ^= *s >> 17; *s ^= *s << 5;
    return *s;
}

static int stopped(int (^cancelled)(void)) { return cancelled && cancelled(); }

static void free_level(Level *l) {
    free(l->rgb); free(l->state); free(l->valid); free(l->mean); free(l->sources);
    free(l->nnf); free(l->cost); free(l->weight); free(l->target); free(l->shift);
    memset(l, 0, sizeof *l);
}

// A random source center.
static int random_source(const Level *l, uint32_t *seed) {
    return l->sourceCount ? l->sources[next_random(seed) % (uint32_t)l->sourceCount] : -1;
}

// What the source centered at s is moved by to stand in for the patch in `cell`: the difference of their mean
// brightness, up to a limit, and on each channel a little more toward its own mean. Light that changes across the
// image then doesn't decide which source fits, while a source of another color still won't fit. Rounded to the
// nearest level: always rounding toward zero, a fill would grow darker with every pass that lifts its sources.
UNCOUNTED static inline void bias_for(const Level *l, size_t cell, int s, int bias[3]) {
    const uint8_t *t = l->target + cell * 3, *m = l->mean + (size_t)s * 3;
    int difference = t[0] + t[1] + t[2] - m[0] - m[1] - m[2], lift = (difference + (difference < 0 ? -1 : 1)) / 3;
    lift = lift > liftLimit ? liftLimit : lift < -liftLimit ? -liftLimit : lift;
    for (int k = 0; k < 3; ++k) {
        int tint = t[k] - m[k] - lift;
        bias[k] = lift + (tint > tintLimit ? tintLimit : tint < -tintLimit ? -tintLimit : tint);
    }
}

// Squared differences between the target patch at (px, py) and the source patch centered at s, its colors moved by
// `bias`, over the target's pixels that are known or being filled; stops once past `limit`.
UNCOUNTED static int patch_cost(const Level *l, int px, int py, int s, const int bias[3], int limit) {
    int sum = 0, w = l->w;
    if (l->opaque && px >= RADIUS && py >= RADIUS && px + RADIUS < w && py + RADIUS < l->h) {
        int br = bias[0], bg = bias[1], bb = bias[2];
        for (int dy = -RADIUS; dy <= RADIUS; ++dy) {
            const uint8_t *a = l->rgb + ((size_t)(py + dy) * w + px - RADIUS) * 4;
            const uint8_t *b = l->rgb + ((size_t)s + (size_t)dy * w - RADIUS) * 4;
            for (int k = 0; k < (2 * RADIUS + 1) * 4; k += 4) {
                int dr = a[k] - b[k] - br, dg = a[k + 1] - b[k + 1] - bg, db = a[k + 2] - b[k + 2] - bb;
                int dt = a[k + 3] - b[k + 3];
                sum += dr * dr + dg * dg + db * db + textureWeight * dt * dt;
            }
            if (sum >= limit) return sum;
        }
        return sum;
    }
    for (int dy = -RADIUS; dy <= RADIUS; ++dy) {
        int ty = py + dy;
        if (ty < 0 || ty >= l->h) continue;
        const uint8_t *t = l->rgb + (size_t)ty * w * 4, *src = l->rgb + ((size_t)s + (size_t)dy * w) * 4;
        const uint8_t *state = l->state + (size_t)ty * w;
        for (int dx = -RADIUS; dx <= RADIUS; ++dx) {
            int tx = px + dx;
            if (tx < 0 || tx >= w || !state[tx]) continue;
            const uint8_t *a = t + tx * 4, *b = src + dx * 4;
            int dr = a[0] - b[0] - bias[0], dg = a[1] - b[1] - bias[1], db = a[2] - b[2] - bias[2], dt = a[3] - b[3];
            sum += dr * dr + dg * dg + db * db + textureWeight * dt * dt;
        }
        if (sum >= limit) return sum;
    }
    return sum;
}

UNCOUNTED static inline int cell_cost(const Level *l, size_t cell, int s, int limit) {
    int bias[3];
    bias_for(l, cell, s, bias);
    int moved = (2 * RADIUS + 1) * (2 * RADIUS + 1) * (bias[0] * bias[0] + bias[1] * bias[1] + bias[2] * bias[2]) / 4;
    if (moved >= limit) return moved;
    return moved + patch_cost(l, l->bx + (int)(cell % l->bw), l->by + (int)(cell / l->bw), s, bias, limit - moved);
}

UNCOUNTED static inline int luma(const uint8_t *p) { return (p[0] * 77 + p[1] * 150 + p[2] * 29) >> 8; }

// Mean gradient magnitude of the luminance over the 5 × 5 around each pixel, from known pixels only, into the
// fourth byte: how busy the image is there, at this level's own scale.
UNCOUNTED static void gradient_rows(const Level *l, uint16_t *gradient, uint8_t *has, size_t start, size_t end) {
    int w = l->w, h = l->h;
    for (size_t y = start; y < end; ++y) for (int x = 1; x < w - 1; ++x) {
        size_t i = y * w + x;
        if (y < 1 || (int)y >= h - 1 || l->state[i] != KNOWN || l->state[i - 1] != KNOWN || l->state[i + 1] != KNOWN
            || l->state[i - w] != KNOWN || l->state[i + w] != KNOWN) continue;
        int gx = luma(l->rgb + (i + 1) * 4) - luma(l->rgb + (i - 1) * 4);
        int gy = luma(l->rgb + (i + w) * 4) - luma(l->rgb + (i - w) * 4);
        gradient[i] = (uint16_t)(abs(gx) + abs(gy)); has[i] = 1;
    }
}
UNCOUNTED static void texture_rows(const Level *l, const uint16_t *gradient, const uint8_t *has, uint16_t *rowSum,
                                   uint8_t *rowCount, size_t start, size_t end) {
    int w = l->w, r = 2;
    for (size_t y = start; y < end; ++y) {
        int sum = 0, count = 0;
        for (int x = -r; x < w + r; ++x) {
            if (x + r < w) { sum += gradient[y * w + x + r]; count += has[y * w + x + r]; }
            if (x - r - 1 >= 0) { sum -= gradient[y * w + x - r - 1]; count -= has[y * w + x - r - 1]; }
            if (x >= 0 && x < w) { rowSum[y * w + x] = (uint16_t)sum; rowCount[y * w + x] = (uint8_t)count; }
        }
    }
}
UNCOUNTED static void texture_columns(Level *l, const uint16_t *rowSum, const uint8_t *rowCount, size_t start,
                                      size_t end) {
    int w = l->w, h = l->h, r = 2;
    for (size_t x = start; x < end; ++x) {
        int sum = 0, count = 0;
        for (int y = -r; y < h + r; ++y) {
            size_t below = (size_t)(y + r) * w + x, above = (size_t)(y - r - 1) * w + x;
            if (y + r < h) { sum += rowSum[below]; count += rowCount[below]; }
            if (y - r - 1 >= 0) { sum -= rowSum[above]; count -= rowCount[above]; }
            if (y >= 0 && y < h) {
                l->rgb[((size_t)y * w + x) * 4 + 3] = (uint8_t)(count ? (sum / count > 255 ? 255 : sum / count) : 0);
            }
        }
    }
}
static int measure_texture(Level *l) {
    int w = l->w, h = l->h;
    uint16_t *gradient = calloc((size_t)w * h, sizeof(uint16_t)), *rowSum = calloc((size_t)w * h, sizeof(uint16_t));
    uint8_t *has = calloc((size_t)w * h, 1), *rowCount = calloc((size_t)w * h, 1);
    int made = gradient && rowSum && has && rowCount;
    if (made) {
        in_bands((size_t)h, ^(size_t start, size_t end) { gradient_rows(l, gradient, has, start, end); });
        in_bands((size_t)h, ^(size_t start, size_t end) {
            texture_rows(l, gradient, has, rowSum, rowCount, start, end);
        });
        in_bands((size_t)w, ^(size_t start, size_t end) { texture_columns(l, rowSum, rowCount, start, end); });
    }
    free(gradient); free(rowSum); free(has); free(rowCount);
    return made;
}

// The sources' mean colors: sums along rows, then down columns, over the patch.
UNCOUNTED static void mean_rows(const Level *l, uint16_t *rows, size_t start, size_t end) {
    int w = l->w;
    for (size_t y = start; y < end; ++y) {
        int sum[3] = {0, 0, 0};
        for (int x = -RADIUS; x < w; ++x) {
            if (x + RADIUS < w) for (int k = 0; k < 3; ++k) sum[k] += l->rgb[(y * w + x + RADIUS) * 4 + k];
            if (x - RADIUS - 1 >= 0) for (int k = 0; k < 3; ++k) sum[k] -= l->rgb[(y * w + x - RADIUS - 1) * 4 + k];
            if (x >= 0) for (int k = 0; k < 3; ++k) rows[(y * w + x) * 3 + k] = (uint16_t)sum[k];
        }
    }
}
UNCOUNTED static void mean_columns(Level *l, const uint16_t *rows, size_t start, size_t end) {
    int w = l->w, h = l->h, area = (2 * RADIUS + 1) * (2 * RADIUS + 1);
    for (size_t x = start; x < end; ++x) for (int y = RADIUS; y < h - RADIUS; ++y) {
        size_t i = (size_t)y * w + x;
        if (!l->valid[i]) continue;
        for (int k = 0; k < 3; ++k) {
            int sum = 0;
            for (int dy = -RADIUS; dy <= RADIUS; ++dy) sum += rows[(i + (size_t)(dy * w)) * 3 + k];
            l->mean[i * 3 + k] = (uint8_t)((sum + area / 2) / area);
        }
    }
}

// Which centers are whole patches of known pixels, their mean colors, and which patches touch the hole.
static int prepare_level(Level *l) {
    int w = l->w, h = l->h, side = 2 * RADIUS + 1;
    l->valid = calloc((size_t)w * h, 1);
    l->mean = calloc((size_t)w * h, 3);
    uint8_t *run = calloc((size_t)w * h, 1);
    uint16_t *rows = malloc((size_t)w * h * 3 * sizeof(uint16_t));
    if (!l->valid || !l->mean || !run || !rows) { free(run); free(rows); return 0; }
    int x0 = w, y0 = h, x1 = -1, y1 = -1;
    l->opaque = 1;
    for (int y = 0; y < h; ++y) for (int x = 0, count = 0; x < w; ++x) {
        int state = l->state[y * w + x];
        if (state == OUT) l->opaque = 0;
        count = state == KNOWN ? count + 1 : 0;
        if (count >= side) run[y * w + x - RADIUS] = 1;
        if (state == HOLE) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
    }
    l->sourceCount = 0;
    for (int x = 0; x < w; ++x) for (int y = 0, count = 0; y < h; ++y) {
        count = run[y * w + x] ? count + 1 : 0;
        if (count >= side) { l->valid[(y - RADIUS) * w + x] = 1; ++l->sourceCount; }
    }
    free(run);
    l->sources = malloc(((size_t)l->sourceCount + 1) * sizeof(int));
    if (!l->sources) { free(rows); return 0; }
    for (int i = 0, k = 0; i < w * h; ++i) if (l->valid[i]) l->sources[k++] = i;
    in_bands((size_t)h, ^(size_t start, size_t end) { mean_rows(l, rows, start, end); });
    in_bands((size_t)w, ^(size_t start, size_t end) { mean_columns(l, rows, start, end); });
    free(rows);
    if (x1 < 0) return 1;
    l->bx = x0 - RADIUS < 0 ? 0 : x0 - RADIUS; l->by = y0 - RADIUS < 0 ? 0 : y0 - RADIUS;
    l->bw = (x1 + RADIUS >= w ? w - 1 : x1 + RADIUS) - l->bx + 1;
    l->bh = (y1 + RADIUS >= h ? h - 1 : y1 + RADIUS) - l->by + 1;
    size_t cells = (size_t)l->bw * l->bh;
    l->nnf = malloc(cells * sizeof(int)); l->cost = malloc(cells * sizeof(int));
    l->weight = malloc(cells * sizeof(float)); l->target = malloc(cells * 3); l->shift = malloc(cells * 3);
    uint8_t *near = calloc(cells, 1);
    if (!l->nnf || !l->cost || !l->weight || !l->target || !l->shift || !near) { free(near); return 0; }
    // A box cell holds a patch when it isn't transparent and a hole pixel lies within its square: rows, then columns.
    for (int y = 0; y < l->bh; ++y) for (int x = -RADIUS, last = INT_MIN / 2; x < l->bw + RADIUS; ++x) {
        int gx = l->bx + x;
        if (gx >= 0 && gx < w && l->state[(l->by + y) * w + gx] == HOLE) last = x;
        if (x - RADIUS >= 0 && x - RADIUS < l->bw && x - last <= 2 * RADIUS) near[y * l->bw + x - RADIUS] = 1;
    }
    for (int x = 0; x < l->bw; ++x) for (int y = -RADIUS, last = INT_MIN / 2; y < l->bh + RADIUS; ++y) {
        if (y >= 0 && y < l->bh && (near[y * l->bw + x] & 1)) last = y;
        if (y - RADIUS >= 0 && y - RADIUS < l->bh && y - last <= 2 * RADIUS) near[(y - RADIUS) * l->bw + x] |= 2;
    }
    for (size_t i = 0; i < cells; ++i) {
        int gx = l->bx + (int)(i % l->bw), gy = l->by + (int)(i / l->bw);
        l->nnf[i] = (near[i] & 2) && l->state[gy * w + gx] != OUT ? 0 : -1;
    }
    free(near);
    return 1;
}

// The mean color of each patch touching the hole, over the pixels it is compared on, as the hole now stands.
UNCOUNTED static void target_rows(Level *l, size_t start, size_t end) {
    int w = l->w, h = l->h, bw = l->bw;
    for (size_t y = start; y < end; ++y) for (int x = 0; x < bw; ++x) {
        size_t cell = y * bw + x;
        if (l->nnf[cell] < 0) continue;
        int px = l->bx + x, py = l->by + (int)y, sum[3] = {0, 0, 0}, count = 0;
        for (int dy = -RADIUS; dy <= RADIUS; ++dy) {
            int ty = py + dy;
            if (ty < 0 || ty >= h) continue;
            for (int dx = -RADIUS; dx <= RADIUS; ++dx) {
                int tx = px + dx;
                if (tx < 0 || tx >= w || !l->state[ty * w + tx]) continue;
                const uint8_t *p = l->rgb + ((size_t)ty * w + tx) * 4;
                sum[0] += p[0]; sum[1] += p[1]; sum[2] += p[2]; ++count;
            }
        }
        for (int k = 0; k < 3; ++k) l->target[cell * 3 + k] = (uint8_t)(count ? (sum[k] + count / 2) / count : 0);
    }
}
static void measure_targets(Level *l) {
    in_bands((size_t)l->bh, ^(size_t start, size_t end) { target_rows(l, start, end); });
}

// Halves a level: a pixel is in the hole if any of its four is, and otherwise the mean of those that are known.
static int downsample(const Level *f, Level *c) {
    c->w = (f->w + 1) / 2; c->h = (f->h + 1) / 2;
    c->rgb = calloc((size_t)c->w * c->h, 4); c->state = calloc((size_t)c->w * c->h, 1);
    if (!c->rgb || !c->state) return 0;
    for (int y = 0; y < c->h; ++y) for (int x = 0; x < c->w; ++x) {
        int sum[4] = {0, 0, 0, 0}, known = 0, hole = 0;
        for (int dy = 0; dy < 2; ++dy) for (int dx = 0; dx < 2; ++dx) {
            int fx = 2 * x + dx, fy = 2 * y + dy;
            if (fx >= f->w || fy >= f->h) continue;
            int state = f->state[fy * f->w + fx];
            hole += state == HOLE;
            if (state != KNOWN) continue;
            const uint8_t *p = f->rgb + ((size_t)fy * f->w + fx) * 4;
            for (int k = 0; k < 4; ++k) sum[k] += p[k];
            ++known;
        }
        uint8_t *o = c->rgb + ((size_t)y * c->w + x) * 4;
        if (known) for (int k = 0; k < 4; ++k) o[k] = (uint8_t)((sum[k] + known / 2) / known);
        c->state[y * c->w + x] = hole ? HOLE : known ? KNOWN : OUT;
    }
    return 1;
}

// A first estimate for the coarsest level: the hole filled from its edge inwards, ring by ring, each pixel the mean
// of its neighbors already set. Clear pixels are filled on the way, though nothing reads them, so that a hole with
// clear pixels between it and the layer starts from the layer's colors rather than from black.
static int fill_smoothly(Level *l) {
    int w = l->w, h = l->h;
    size_t n = (size_t)w * h, holes = 0, head = 0, tail = 0;
    uint8_t *set = malloc(n);   // 1 once set, 2 while waiting its turn
    int *queue = malloc(n * sizeof(int));
    if (!set || !queue) { free(set); free(queue); return 0; }
    for (size_t i = 0; i < n; ++i) { set[i] = l->state[i] == KNOWN; holes += l->state[i] == HOLE; }
    // Each ring: those not yet set beside one that is.
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
        if (set[y * w + x]) continue;
        for (int dy = -1, found = 0; dy <= 1 && !found; ++dy) for (int dx = -1; dx <= 1; ++dx) {
            int nx = x + dx, ny = y + dy;
            if (nx < 0 || ny < 0 || nx >= w || ny >= h || set[ny * w + nx] != 1) continue;
            set[y * w + x] = 2; queue[tail++] = y * w + x; found = 1;
            break;
        }
    }
    while (head < tail && holes) {
        size_t end = tail;
        for (size_t q = head; q < end; ++q) {
            int x = queue[q] % w, y = queue[q] / w, sum[4] = {0, 0, 0, 0}, count = 0;
            for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx) {
                int nx = x + dx, ny = y + dy;
                if (nx < 0 || ny < 0 || nx >= w || ny >= h || set[ny * w + nx] != 1) continue;
                const uint8_t *p = l->rgb + ((size_t)ny * w + nx) * 4;
                for (int k = 0; k < 4; ++k) sum[k] += p[k];
                ++count;
            }
            uint8_t *o = l->rgb + (size_t)queue[q] * 4;
            for (int k = 0; k < 4; ++k) o[k] = (uint8_t)((sum[k] + count / 2) / count);
        }
        for (size_t q = head; q < end; ++q) { set[queue[q]] = 1; holes -= l->state[queue[q]] == HOLE; }
        for (size_t q = head; q < end; ++q) {
            int x = queue[q] % w, y = queue[q] / w;
            for (int dy = -1; dy <= 1; ++dy) for (int dx = -1; dx <= 1; ++dx) {
                int nx = x + dx, ny = y + dy;
                if (nx < 0 || ny < 0 || nx >= w || ny >= h || set[ny * w + nx]) continue;
                set[ny * w + nx] = 2; queue[tail++] = ny * w + nx;
            }
        }
        head = end;
    }
    free(set); free(queue);
    return 1;
}

// Smooths the coarsest estimate into a membrane: each hole pixel the mean of its four neighbors, settled by
// over-relaxed passes, held at the edge to what lies around the hole there. That edge is read robustly: each pixel
// along it from those along it within `reach`, leaving out any far from their median (an object beside the hole),
// with a plane fitted through the rest, so light changing along the edge reads true where the edge turns.
static int smooth_membrane(Level *l, int reach) {
    int w = l->w, h = l->h, rimCount = 0, holeCount = 0, side = 2 * reach + 1;
    size_t n = (size_t)w * h;
    float *value = malloc(n * 4 * sizeof(float));
    int *rim = malloc(n * sizeof(int)), *inside = malloc(n * sizeof(int));
    int *near = malloc((size_t)side * side * sizeof(int));
    uint8_t *isRim = calloc(n, 1);
    int made = value && rim && inside && near && isRim;
    if (!made) goto done;
    for (size_t i = 0; i < n; ++i) for (int k = 0; k < 4; ++k) value[i * 4 + k] = l->rgb[i * 4 + k];
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
        int i = y * w + x;
        if (l->state[i] == HOLE) inside[holeCount++] = i;
        if (l->state[i] != KNOWN) continue;
        if ((x > 0 && l->state[i - 1] == HOLE) || (x + 1 < w && l->state[i + 1] == HOLE)
            || (y > 0 && l->state[i - w] == HOLE) || (y + 1 < h && l->state[i + w] == HOLE)) {
            rim[rimCount++] = i; isRim[i] = 1;
        }
    }
    for (int r = 0; r < rimCount; ++r) {
        int x = rim[r] % w, y = rim[r] / w, count = 0;
        for (int ny = y - reach < 0 ? 0 : y - reach; ny <= y + reach && ny < h; ++ny) {
            for (int nx = x - reach < 0 ? 0 : x - reach; nx <= x + reach && nx < w; ++nx) {
                if (isRim[ny * w + nx]) near[count++] = ny * w + nx;
            }
        }
        // Each channel's median, and how far from it half of them lie; beyond four and a half times that is an outlier.
        int median[4], limit[4];
        for (int k = 0; k < 4; ++k) {
            int histogram[256] = {0}, deviations[256] = {0}, at = 0, spread = 0;
            for (int q = 0; q < count; ++q) ++histogram[l->rgb[(size_t)near[q] * 4 + k]];
            for (int below = 0; (below += histogram[at]) * 2 < count; ++at) {}
            median[k] = at;
            for (int q = 0; q < count; ++q) ++deviations[abs(l->rgb[(size_t)near[q] * 4 + k] - at)];
            for (int below = 0; (below += deviations[spread]) * 2 < count; ++spread) {}
            limit[k] = spread * 9 / 2 > 4 ? spread * 9 / 2 : 4;
        }
        double s = 0, sx = 0, sy = 0, sxx = 0, sxy = 0, syy = 0;
        double sv[4] = {0, 0, 0, 0}, svx[4] = {0, 0, 0, 0}, svy[4] = {0, 0, 0, 0};
        for (int q = 0; q < count; ++q) {
            const uint8_t *p = l->rgb + (size_t)near[q] * 4;
            if (abs(p[0] - median[0]) > limit[0] || abs(p[1] - median[1]) > limit[1]
                || abs(p[2] - median[2]) > limit[2]) continue;
            double dx = near[q] % w - x, dy = near[q] / w - y;
            s += 1; sx += dx; sy += dy; sxx += dx * dx; sxy += dx * dy; syy += dy * dy;
            for (int k = 0; k < 4; ++k) { sv[k] += p[k]; svx[k] += p[k] * dx; svy[k] += p[k] * dy; }
        }
        if (s < 1) continue;
        // The plane's height here, from its normal equations by Cramer's rule; a little weight toward level keeps a
        // straight edge steady.
        sxx += 0.5 * s; syy += 0.5 * s;
        double minor = sxx * syy - sxy * sxy, det = s * minor - sx * (sx * syy - sxy * sy) + sy * (sx * sxy - sxx * sy);
        for (int k = 0; k < 4; ++k) {
            double a = sv[k] / s;
            if (det != 0) {
                a = (sv[k] * minor - sx * (svx[k] * syy - sxy * svy[k]) + sy * (svx[k] * sxy - sxx * svy[k])) / det;
            }
            value[(size_t)rim[r] * 4 + k] = (float)(a < 0 ? 0 : a > 255 ? 255 : a);
        }
    }
    for (int pass = 0; pass < 400; ++pass) {
        float change = 0;
        for (int q = 0; q < holeCount; ++q) {
            int i = inside[q], x = i % w, y = i / w, count = 0;
            int around[4] = { x > 0 ? i - 1 : -1, x + 1 < w ? i + 1 : -1, y > 0 ? i - w : -1, y + 1 < h ? i + w : -1 };
            float sum[4] = {0, 0, 0, 0};
            for (int a = 0; a < 4; ++a) {
                if (around[a] < 0 || l->state[around[a]] == OUT) continue;
                for (int k = 0; k < 4; ++k) sum[k] += value[(size_t)around[a] * 4 + k];
                ++count;
            }
            if (!count) continue;
            for (int k = 0; k < 4; ++k) {
                float step = 1.8f * (sum[k] / count - value[(size_t)i * 4 + k]);
                value[(size_t)i * 4 + k] += step;
                if (fabsf(step) > change) change = fabsf(step);
            }
        }
        if (change < 0.05f) break;
    }
    for (int q = 0; q < holeCount; ++q) for (int k = 0; k < 4; ++k) {
        float v = value[(size_t)inside[q] * 4 + k] + 0.5f;
        l->rgb[(size_t)inside[q] * 4 + k] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
    }
done:
    free(value); free(rim); free(inside); free(near); free(isRim);
    return made;
}

// Every source for every patch, or every `step`th across and down and then the nearest around the best: affordable
// at the coarsest level, where it finds the best layout outright rather than settling near a first guess. The passes
// that follow look around each match further.
UNCOUNTED static void search_cells_everywhere(Level *l, int step, size_t start, size_t end) {
    int w = l->w, h = l->h;
    for (size_t i = start; i < end; ++i) {
        if (l->nnf[i] < 0) continue;
        int best = l->nnf[i], cost = cell_cost(l, i, best, INT_MAX);
        for (int sy = step / 2; sy < h; sy += step) for (int sx = step / 2; sx < w; sx += step) {
            int s = sy * w + sx;
            if (!l->valid[s]) continue;
            int c = cell_cost(l, i, s, cost);
            if (c < cost) { cost = c; best = s; }
        }
        int bx = best % w, by = best / w, reach = step - 1 < 2 ? step - 1 : 2;
        for (int dy = -reach; dy <= reach; ++dy) for (int dx = -reach; dx <= reach; ++dx) {
            int sx = bx + dx, sy = by + dy;
            if ((!dx && !dy) || sx < 0 || sy < 0 || sx >= w || sy >= h || !l->valid[sy * w + sx]) continue;
            int c = cell_cost(l, i, sy * w + sx, cost);
            if (c < cost) { cost = c; best = sy * w + sx; }
        }
        l->nnf[i] = best; l->cost[i] = cost;
    }
}
static void search_everywhere(Level *l) {
    size_t cells = (size_t)l->bw * l->bh;
    int step = 1;
    while ((double)l->sourceCount / ((double)step * step) * cells > 8e6) ++step;
    in_bands(cells, ^(size_t start, size_t end) { search_cells_everywhere(l, step, start, end); });
}

// What a candidate is charged for the neighbors' matches it doesn't carry on.
UNCOUNTED static inline int disagreement(const int around[4], int s, int charge) {
    return charge * (4 - (around[0] == s) - (around[1] == s) - (around[2] == s) - (around[3] == s));
}
// Takes the source centered at s for `cell` if it costs less, charge included, than the best so far.
UNCOUNTED static inline void consider(const Level *l, size_t cell, const int around[4], int charge, int s, int *best,
                                      int *cost) {
    int c = disagreement(around, s, charge);
    if (c >= *cost) return;
    c += cell_cost(l, cell, s, *cost - c);
    if (c < *cost) { *cost = c; *best = s; }
}

// One PatchMatch pass over rows `start` to `end`: each patch tries its neighbors' matches moved over by one, then
// random ones around its best in shrinking windows. A neighbor in another band is read as it was before the pass.
UNCOUNTED static void search_rows(Level *l, const int *before, int dir, int radius, uint32_t seed, size_t start,
                                  size_t end) {
    int bw = l->bw, w = l->w, h = l->h, charge = coherence * (2 * RADIUS + 1) * (2 * RADIUS + 1);
    uint32_t state = (seed ^ (uint32_t)(start * 2654435761u)) | 1;
    for (size_t k = 0; k < end - start; ++k) {
        int y = dir > 0 ? (int)(start + k) : (int)(end - 1 - k);
        for (int j = 0; j < bw; ++j) {
            int x = dir > 0 ? j : bw - 1 - j;
            size_t i = (size_t)y * bw + x;
            if (l->nnf[i] < 0) continue;
            // The four neighbors' matches, each moved over to this cell: a candidate is charged for each it doesn't
            // agree with.
            int around[4] = {-1, -1, -1, -1};
            if (x > 0 && l->nnf[i - 1] >= 0) around[0] = l->nnf[i - 1] + 1;
            if (x + 1 < bw && l->nnf[i + 1] >= 0) around[1] = l->nnf[i + 1] - 1;
            if (y > 0) {
                int n = y - 1 >= (int)start ? l->nnf[i - bw] : before[i - bw];
                if (n >= 0) around[2] = n + w;
            }
            if (y + 1 < l->bh) {
                int n = y + 1 < (int)end ? l->nnf[i + bw] : before[i + bw];
                if (n >= 0) around[3] = n - w;
            }
            int best = l->nnf[i], cost = cell_cost(l, i, best, INT_MAX) + disagreement(around, best, charge);
            if (x - dir >= 0 && x - dir < bw) {
                int n = l->nnf[(size_t)y * bw + x - dir], s = n + dir;
                if (n >= 0 && s % w - n % w == dir && l->valid[s]) consider(l, i, around, charge, s, &best, &cost);
            }
            if (y - dir >= 0 && y - dir < l->bh) {
                size_t cell = (size_t)(y - dir) * bw + x;
                int n = y - dir >= (int)start && y - dir < (int)end ? l->nnf[cell] : before[cell], s = n + dir * w;
                if (n >= 0 && s >= 0 && s < w * h && l->valid[s]) consider(l, i, around, charge, s, &best, &cost);
            }
            for (int r = radius; r >= 1; r /= 2) {
                int sx = best % w + (int)(next_random(&state) % (uint32_t)(2 * r + 1)) - r;
                int sy = best / w + (int)(next_random(&state) % (uint32_t)(2 * r + 1)) - r;
                if (sx < 0 || sy < 0 || sx >= w || sy >= h || !l->valid[sy * w + sx]) continue;
                consider(l, i, around, charge, sy * w + sx, &best, &cost);
            }
            l->nnf[i] = best;
            l->cost[i] = cost - disagreement(around, best, charge);
        }
    }
}
// One PatchMatch pass, bands of rows at once.
static int search(Level *l, int dir, int radius, uint32_t seed) {
    size_t cells = (size_t)l->bw * l->bh;
    int *before = malloc(cells * sizeof(int));
    if (!before) return 0;
    memcpy(before, l->nnf, cells * sizeof(int));
    in_bands((size_t)l->bh, ^(size_t start, size_t end) { search_rows(l, before, dir, radius, seed, start, end); });
    free(before);
    return 1;
}

static void select_kth(float *a, size_t n, size_t k) {
    size_t lo = 0, hi = n - 1;
    while (lo < hi) {
        float pivot = a[(lo + hi) / 2];
        size_t i = lo, j = hi;
        while (i <= j) {
            while (a[i] < pivot) ++i;
            while (a[j] > pivot) --j;
            if (i <= j) { float t = a[i]; a[i] = a[j]; a[j] = t; ++i; if (j == 0) break; --j; }
        }
        if (k <= j) hi = j; else if (k >= i) lo = i; else return;
    }
}

// How much each patch counts in the vote. Matches count by how well they fit, exp(−d / 2σ²) with σ² the 75th
// percentile of the patches' mean squared differences, as Wexler et al. weigh them; `even` counts all the same.
static int weigh(Level *l, int even) {
    size_t cells = (size_t)l->bw * l->bh, n = 0;
    float area = (float)((2 * RADIUS + 1) * (2 * RADIUS + 1) * 3), sigma2 = 1;
    if (!even) {
        float *sample = malloc(sizeof(float) * (cells / 8 + 1));
        if (!sample) return 0;
        for (size_t i = 0; i < cells; i += 8) if (l->nnf[i] >= 0) sample[n++] = l->cost[i] / area;
        if (n) { select_kth(sample, n, n * 3 / 4); sigma2 = sample[n * 3 / 4] < 1 ? 1 : sample[n * 3 / 4]; }
        free(sample);
    }
    for (size_t i = 0; i < cells; ++i) {
        l->weight[i] = l->nnf[i] < 0 ? 0 : even ? 1 : expf(-(l->cost[i] / area) / (2 * sigma2)) + 1e-6f;
    }
    return 1;
}

UNCOUNTED static void shift_rows(Level *l, size_t start, size_t end) {
    for (size_t c = start * l->bw; c < end * l->bw; ++c) {
        if (l->nnf[c] < 0) continue;
        int bias[3];
        bias_for(l, c, l->nnf[c], bias);
        for (int k = 0; k < 3; ++k) l->shift[c * 3 + k] = (int8_t)bias[k];
    }
}
UNCOUNTED static void vote_rows(Level *l, size_t start, size_t end) {
    int w = l->w, bw = l->bw;
    for (size_t y = start; y < end; ++y) for (int x = 0; x < bw; ++x) {
        int gx = l->bx + x, gy = l->by + (int)y;
        if (l->state[gy * w + gx] != HOLE) continue;
        float sum[4] = {0, 0, 0, 0}, total = 0;
        for (int dy = -RADIUS; dy <= RADIUS; ++dy) {
            int cy = (int)y - dy;
            if (cy < 0 || cy >= l->bh) continue;
            for (int dx = -RADIUS; dx <= RADIUS; ++dx) {
                int cx = x - dx;
                if (cx < 0 || cx >= bw) continue;
                size_t c = (size_t)cy * bw + cx;
                if (l->nnf[c] < 0) continue;
                const uint8_t *p = l->rgb + ((size_t)l->nnf[c] + (size_t)dy * w + dx) * 4;
                const int8_t *shift = l->shift + c * 3;
                float weight = l->weight[c];
                for (int k = 0; k < 3; ++k) sum[k] += weight * (p[k] + shift[k]);
                sum[3] += weight * p[3];
                total += weight;
            }
        }
        if (total <= 0) continue;
        uint8_t *o = l->rgb + ((size_t)gy * w + gx) * 4;
        for (int k = 0; k < 4; ++k) {
            float v = sum[k] / total + 0.5f;
            o[k] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
        }
    }
}
// Each hole pixel becomes the weighted mean of the source pixels that the patches covering it put there, each lifted
// or lowered as its patch's match is; then the patches' means are measured again from the result.
static void vote(Level *l) {
    in_bands((size_t)l->bh, ^(size_t start, size_t end) { shift_rows(l, start, end); });
    in_bands((size_t)l->bh, ^(size_t start, size_t end) { vote_rows(l, start, end); });
    measure_targets(l);
}

// Mean squared difference between the square around p and the one around q, over the pixels known around p.
static double pixel_match(const uint8_t *rgba, const uint8_t *known, int w, int h, int p, int q, int radius) {
    int px = p % w, py = p / w, qx = q % w, qy = q / w, count = 0;
    double sum = 0;
    for (int dy = -radius; dy <= radius; ++dy) for (int dx = -radius; dx <= radius; ++dx) {
        int x = px + dx, y = py + dy, sx = qx + dx, sy = qy + dy;
        if (x < 0 || y < 0 || x >= w || y >= h || sx < 0 || sy < 0 || sx >= w || sy >= h || !known[y * w + x]) continue;
        const uint8_t *a = rgba + ((size_t)y * w + x) * 4, *b = rgba + ((size_t)sy * w + sx) * 4;
        for (int c = 0; c < 4; ++c) { int d = a[c] - b[c]; sum += d * d; }
        ++count;
    }
    return count ? sum / count : DBL_MAX;
}

// The fill for a layer with no whole patch known anywhere, as thin as a strip or with only a narrow border around the
// selection: pixel by pixel from the edge inwards, each copied from the source whose 5 × 5 square (on a layer
// narrower than that, the pixel alone) best matches what is known around it, found among its neighbors' sources moved
// over and at random, then near the best. Made on a copy, so a fill that is cancelled leaves the layer as it was.
static int fill_pixel_by_pixel(uint8_t *pixels, size_t stride, const uint8_t *mask, size_t ms, int w, int h,
                               int (^cancelled)(void)) {
    size_t n = (size_t)w * h, sourceCount = 0, head = 0, tail = 0, scan = 0;
    uint8_t *rgba = malloc(n * 4), *known = calloc(n, 1), *target = calloc(n, 1), *valid = calloc(n, 1);
    uint8_t *queued = calloc(n, 1);
    int *sources = malloc(n * sizeof(int)), *queue = malloc(n * sizeof(int)), *chosen = malloc(n * sizeof(int));
    int result = -1, radius = w >= 5 && h >= 5 ? 2 : 0;
    if (!rgba || !known || !target || !valid || !queued || !sources || !queue || !chosen) goto done;
    // Selected pixels are filled; unselected opaque ones are what is matched and copied from; unselected clear ones
    // are neither, and are left as they are.
    for (int y = 0; y < h; ++y) {
        memcpy(rgba + (size_t)y * w * 4, pixels + (size_t)y * stride, (size_t)w * 4);
        for (int x = 0; x < w; ++x) {
            int p = y * w + x;
            target[p] = mask[(size_t)y * ms + x] != 0;
            known[p] = !target[p] && rgba[(size_t)p * 4 + 3] == 255;
            chosen[p] = -1;
        }
    }
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
        int p = y * w + x, whole = known[p];
        for (int dy = -radius; dy <= radius && whole; ++dy) for (int dx = -radius; dx <= radius; ++dx) {
            int sx = x + dx, sy = y + dy;
            if (sx < 0 || sy < 0 || sx >= w || sy >= h || !known[sy * w + sx]) { whole = 0; break; }
        }
        if (whole) { valid[p] = 1; sources[sourceCount++] = p; }
    }
    result = 0;
    if (!sourceCount) goto done;
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
        int p = y * w + x;
        if (target[p] && ((x && known[p - 1]) || (x + 1 < w && known[p + 1]) || (y && known[p - w])
                          || (y + 1 < h && known[p + w]))) { queue[tail++] = p; queued[p] = 1; }
    }
    uint32_t seed = 0x6d2b79f5;
    for (;;) {
        while (head < tail) {
            if (head % 4096 == 0 && stopped(cancelled)) { result = -2; goto done; }
            int p = queue[head++], x = p % w, y = p / w, best = -1;
            double score = DBL_MAX;
            int around[4] = { x ? p - 1 : -1, x + 1 < w ? p + 1 : -1, y ? p - w : -1, y + 1 < h ? p + w : -1 };
            // The neighbors' sources moved over, and a few at random; then random ones near the best.
            for (int k = 0; k < 28; ++k) {
                int q = -1;
                if (k < 4) {
                    int t = around[k];
                    if (t >= 0) q = (chosen[t] >= 0 ? chosen[t] : t) + (p - t);
                } else q = sources[next_random(&seed) % sourceCount];
                if (q < 0 || (size_t)q >= n || !valid[q]) continue;
                double s = pixel_match(rgba, known, w, h, p, q, radius);
                if (best < 0 || s < score) { score = s; best = q; }
            }
            if (best < 0) best = sources[0];
            for (int r = 64; r >= 1; r /= 2) {
                int qx = best % w + (int)(next_random(&seed) % (uint32_t)(2 * r + 1)) - r;
                int qy = best / w + (int)(next_random(&seed) % (uint32_t)(2 * r + 1)) - r;
                if (qx < 0 || qy < 0 || qx >= w || qy >= h || !valid[qy * w + qx]) continue;
                double s = pixel_match(rgba, known, w, h, p, qy * w + qx, radius);
                if (s < score) { score = s; best = qy * w + qx; }
            }
            memcpy(rgba + (size_t)p * 4, rgba + (size_t)best * 4, 4);
            known[p] = 1; chosen[p] = best;
            for (int k = 0; k < 4; ++k) {
                int q = around[k];
                if (q >= 0 && target[q] && !known[q] && !queued[q]) { queued[q] = 1; queue[tail++] = q; }
            }
        }
        // A selected area that only clear pixels touch starts from the best of a few random sources, then spreads.
        while (scan < n && (!target[scan] || known[scan])) ++scan;
        if (scan >= n) break;
        queue[tail++] = (int)scan; queued[scan] = 1;
    }
    for (size_t p = 0; p < n; ++p) if (target[p]) memcpy(pixels + p / w * stride + p % w * 4, rgba + p * 4, 4);
    result = 1;
done:
    free(rgba); free(known); free(target); free(valid); free(queued); free(sources); free(queue); free(chosen);
    return result;
}

int content_fill(uint8_t *pixels, size_t stride, const uint8_t *mask, size_t ms, int w, int h, int (^cancelled)(void)) {
    int x0 = w, y0 = h, x1 = -1, y1 = -1;
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) if (mask[y * ms + x]) {
        if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y;
    }
    if (x1 < 0) return 1;
    // Sources come from a band around the hole a quarter as wide as the hole is big, where the light and the
    // distance from the camera are most like the hole's; the whole layer when that band holds too few.
    int extent = (x1 - x0 > y1 - y0 ? x1 - x0 : y1 - y0) + 1, margin = extent / 4 < 64 ? 64 : extent / 4;
    Level levels[MAX_LEVELS];
    memset(levels, 0, sizeof levels);
    int rx0 = 0, ry0 = 0, count = 0, result = -1;
    for (int whole = 0; whole < 2; ++whole) {
        rx0 = whole || x0 < margin ? 0 : x0 - margin; ry0 = whole || y0 < margin ? 0 : y0 - margin;
        int rx1 = whole || x1 + margin >= w ? w - 1 : x1 + margin;
        int ry1 = whole || y1 + margin >= h ? h - 1 : y1 + margin;
        Level *l = &levels[0];
        free_level(l);
        l->w = rx1 - rx0 + 1; l->h = ry1 - ry0 + 1;
        l->rgb = malloc((size_t)l->w * l->h * 4); l->state = malloc((size_t)l->w * l->h);
        if (!l->rgb || !l->state) goto done;
        size_t holes = 0;
        for (int y = 0; y < l->h; ++y) for (int x = 0; x < l->w; ++x) {
            const uint8_t *p = pixels + (size_t)(y + ry0) * stride + (size_t)(x + rx0) * 4;
            memcpy(l->rgb + ((size_t)y * l->w + x) * 4, p, 4);
            uint8_t state = mask[(size_t)(y + ry0) * ms + x + rx0] ? HOLE : p[3] == 255 ? KNOWN : OUT;
            l->state[y * l->w + x] = state;
            holes += state == HOLE;
        }
        if (stopped(cancelled)) { result = -2; goto done; }
        if (!prepare_level(l) || !measure_texture(l)) goto done;
        int everything = rx0 == 0 && ry0 == 0 && rx1 == w - 1 && ry1 == h - 1;
        if ((size_t)l->sourceCount >= (holes < 4096 ? 4096 : holes) || everything) break;
    }
    // No whole patch anywhere on the layer: it is too thin, or the border around the selection too narrow.
    if (!levels[0].sourceCount) { result = fill_pixel_by_pixel(pixels, stride, mask, ms, w, h, cancelled); goto done; }
    // Halved until the hole is a few patches across: there the layout of larger structure is settled, which a
    // patch at full size is too small to see.
    for (count = 1; count < MAX_LEVELS; ++count) {
        Level *f = &levels[count - 1], *c = &levels[count];
        if ((f->w < f->h ? f->w : f->h) / 2 < 4 * (2 * RADIUS + 1) || (extent >> count) < 4 * (2 * RADIUS + 1)) break;
        if (!downsample(f, c) || !prepare_level(c) || !measure_texture(c)) goto done;
        if (c->sourceCount < 64) { free_level(c); break; }
    }
    uint32_t seed = 0x6d2b79f5;
    for (int k = count - 1; k >= 0; --k) {
        if (stopped(cancelled)) { result = -2; goto done; }
        Level *l = &levels[k];
        size_t cells = (size_t)l->bw * l->bh;
        int coarsest = k == count - 1;
        if (coarsest) {
            // A membrane over the hole, its edge read a third as far as the hole is wide, as it is at this level when
            // the pyramid goes all the way: no farther, where a thin layer stops it short. Then random matches.
            int reach = (extent >> k) / 3 < 2 ? 2 : (extent >> k) / 3 > 18 ? 18 : (extent >> k) / 3;
            if (!fill_smoothly(l) || !smooth_membrane(l, reach)) goto done;
            for (size_t i = 0; i < cells; ++i) if (l->nnf[i] >= 0) l->nnf[i] = random_source(l, &seed);
            measure_targets(l);
        } else {
            // The coarser level's estimate, enlarged, is where this one starts; the coarser matches, doubled, then
            // vote in its detail.
            Level *c = &levels[k + 1];
            for (int y = 0; y < l->h; ++y) for (int x = 0; x < l->w; ++x) {
                if (l->state[y * l->w + x] != HOLE) continue;
                memcpy(l->rgb + ((size_t)y * l->w + x) * 4, c->rgb + ((size_t)(y / 2) * c->w + x / 2) * 4, 4);
            }
            for (size_t i = 0; i < cells; ++i) {
                if (l->nnf[i] < 0) continue;
                int gx = l->bx + (int)(i % l->bw), gy = l->by + (int)(i / l->bw);
                int cx = gx / 2 - c->bx, cy = gy / 2 - c->by;
                int s = cx >= 0 && cy >= 0 && cx < c->bw && cy < c->bh ? c->nnf[(size_t)cy * c->bw + cx] : -1;
                int sx = s < 0 ? -1 : 2 * (s % c->w) + (gx & 1), sy = s < 0 ? -1 : 2 * (s / c->w) + (gy & 1);
                int inside = sx >= 0 && sx < l->w && sy < l->h && l->valid[sy * l->w + sx];
                l->nnf[i] = inside ? sy * l->w + sx : random_source(l, &seed);
            }
            measure_targets(l);
            weigh(l, 1);
            vote(l);
        }
        // Most passes where they are cheap and the layout is decided; at the two finest levels, where the matches
        // only need settling into place, one or two near where they already are.
        int iterations = coarsest || k >= 4 ? 10 : k >= 2 ? 6 : k == 1 ? 2 : 1;
        int longest = l->w > l->h ? l->w : l->h;
        int radius = k >= 2 || coarsest || longest < 64 ? longest : k == 1 ? 64 : 8;
        for (int it = 0; it < iterations; ++it) {
            if (coarsest && it == 0) search_everywhere(l);
            else if (!search(l, it % 2 ? -1 : 1, radius, seed + (uint32_t)(k * 131 + it) * 7919u)) goto done;
            if (!weigh(l, 0)) goto done;
            vote(l);
            if (stopped(cancelled)) { result = -2; goto done; }
        }
    }
    for (int y = 0; y < levels[0].h; ++y) for (int x = 0; x < levels[0].w; ++x) {
        if (levels[0].state[y * levels[0].w + x] != HOLE) continue;
        uint8_t *o = pixels + (size_t)(y + ry0) * stride + (size_t)(x + rx0) * 4;
        memcpy(o, levels[0].rgb + ((size_t)y * levels[0].w + x) * 4, 3);
        o[3] = 255;
    }
    result = 1;
done:
    for (int i = 0; i < MAX_LEVELS; ++i) free_level(&levels[i]);
    return result;
}
