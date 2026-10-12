#include "PatchPixels.h"
#include "HealPixels.h"
#include <dispatch/dispatch.h>
#include <float.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

// Multi-scale PatchMatch fill (Wexler, Shechtman & Irani 2007; Barnes et al. 2009): what Content-Aware Fill does.
//
// Every pixel whose 7 × 7 patch touches the hole is a target. Each target keeps the source patch (one lying wholly
// on usable image) that it best resembles, found by PatchMatch: a match is passed along to the next pixel, shifted
// by one, then improved by trying patches at random, nearer and nearer. Each hole pixel then becomes the blend of
// what every target patch covering it says it should be, closer matches counting for more, and the matching runs
// again against that. Done first on a small copy, so the hole's overall structure (where an edge runs through it)
// settles before its detail, then on each copy twice the size, starting from the smaller one's matches.
//
// Patches are compared on texture as well as color (Newson et al. 2014): how much edge there is around each pixel,
// across and down. On color alone, the early blurred guess at the hole matches the plainest parts of the image, and
// a busy area is filled flat, leaving a seam where the picture ends. The hole's texture comes from the patches it
// copies, never from its blurred guess.

// Patch radius (7 × 7), and the channels a pixel carries: color (RGBA) and its texture across and down.
enum { R = 3, CH = 6 };
// How much texture counts against color.
static const float TEXTURE_WEIGHT = 6.0f;
// How strongly the last blend favors the best matches (see `vote`).
static const float SHARP_FINISH = 8.0f;

typedef struct {
    int w, h;
    float *color;      // RGBA 0–255, premultiplied; the hole holds its current estimate
    uint8_t *hole;     // to fill
    uint8_t *known;    // opaque and outside the hole: matched against and copied from
    uint8_t *source;   // a patch centered here lies wholly on known pixels
    uint8_t *target;   // a patch centered here touches the hole
    uint8_t *counts;   // per target: pixels of its patch that count (known or hole)
    int *match;        // per target: the source center its patch matches
    float *distance;   // per target: the mean squared difference to that match
    int *sources;      // every source center, for random picks
    int sourceCount;
} Level;

static void level_free(Level *L) {
    free(L->color); free(L->hole); free(L->known); free(L->source); free(L->target);
    free(L->counts); free(L->match); free(L->distance); free(L->sources);
    memset(L, 0, sizeof *L);
}

static int level_alloc(Level *L, int w, int h) {
    size_t n = (size_t)w * h;
    L->w = w; L->h = h;
    L->color = malloc(n * CH * sizeof(float));
    L->hole = calloc(n, 1); L->known = calloc(n, 1); L->source = calloc(n, 1); L->target = calloc(n, 1);
    L->counts = calloc(n, 1);
    L->match = malloc(n * sizeof(int)); L->distance = malloc(n * sizeof(float));
    L->sources = malloc(n * sizeof(int));
    return L->color && L->hole && L->known && L->source && L->target && L->counts && L->match && L->distance && L->sources;
}

// Runs `body` over rows split into bands, all at once.
static void in_row_bands(int rows, void (^body)(int band, int start, int end)) {
    int bands = rows < 32 ? 1 : 16, size = (rows + bands - 1) / bands;
    dispatch_apply((size_t)bands, DISPATCH_APPLY_AUTO, ^(size_t index) {
        int start = (int)index * size, end = start + size < rows ? start + size : rows;
        if (start < end) body((int)index, start, end);
    });
}

static inline uint32_t next_random(uint32_t *state) {
    uint32_t x = *state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return *state = x ? x : 0x9e3779b9u;
}

// Sum over the window [x0, x1) × [y0, y1) of a summed-area table with a zero first row and column.
static inline long window_sum(const long *sat, int w, int x0, int y0, int x1, int y1) {
    int stride = w + 1;
    return sat[y1 * stride + x1] - sat[y0 * stride + x1] - sat[y1 * stride + x0] + sat[y0 * stride + x0];
}

// Sources, targets and the pixel counts behind each target's distance, from `hole` and `known`.
static int level_classify(Level *L) {
    int w = L->w, h = L->h, stride = w + 1;
    long *knownSAT = calloc((size_t)stride * (h + 1), sizeof(long));
    long *holeSAT = calloc((size_t)stride * (h + 1), sizeof(long));
    if (!knownSAT || !holeSAT) { free(knownSAT); free(holeSAT); return 0; }
    for (int y = 0; y < h; ++y) {
        long knownRow = 0, holeRow = 0;
        for (int x = 0; x < w; ++x) {
            knownRow += L->known[y * w + x]; holeRow += L->hole[y * w + x];
            knownSAT[(y + 1) * stride + x + 1] = knownSAT[y * stride + x + 1] + knownRow;
            holeSAT[(y + 1) * stride + x + 1] = holeSAT[y * stride + x + 1] + holeRow;
        }
    }
    L->sourceCount = 0;
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            int p = y * w + x;
            int x0 = x - R < 0 ? 0 : x - R, y0 = y - R < 0 ? 0 : y - R;
            int x1 = x + R + 1 > w ? w : x + R + 1, y1 = y + R + 1 > h ? h : y + R + 1;
            long holes = window_sum(holeSAT, w, x0, y0, x1, y1);
            L->target[p] = holes > 0;
            L->counts[p] = (uint8_t)(holes + window_sum(knownSAT, w, x0, y0, x1, y1));
            int inside = x >= R && y >= R && x + R < w && y + R < h;
            L->source[p] = inside && window_sum(knownSAT, w, x - R, y - R, x + R + 1, y + R + 1) == (2 * R + 1) * (2 * R + 1);
            if (L->source[p]) L->sources[L->sourceCount++] = p;
        }
    }
    free(knownSAT); free(holeSAT);
    return 1;
}

// Mean squared difference between the target patch at p and the source patch at q, over the target's pixels that
// count. Gives up, returning FLT_MAX, once it can't beat `best`.
static float patch_distance(const Level *L, int p, int q, float best) {
    int w = L->w, h = L->h, px = p % w, py = p / w, qx = q % w, qy = q / w;
    float limit = best == FLT_MAX ? FLT_MAX : best * L->counts[p], sum = 0;
    for (int dy = -R; dy <= R; ++dy) {
        int y = py + dy;
        if (y < 0 || y >= h) continue;
        const float *row = L->color + (size_t)(qy + dy) * w * CH;
        for (int dx = -R; dx <= R; ++dx) {
            int x = px + dx, a = y * w + x;
            if (x < 0 || x >= w || !(L->hole[a] || L->known[a])) continue;
            const float *t = L->color + (size_t)a * CH, *s = row + (size_t)(qx + dx) * CH;
            for (int c = 0; c < CH; ++c) { float d = t[c] - s[c]; sum += d * d; }
        }
        if (sum >= limit) return FLT_MAX;
    }
    return L->counts[p] ? sum / L->counts[p] : FLT_MAX;
}

// One PatchMatch sweep over every target, forward or backward. Each band of rows works on its own; a neighbor in
// another band is read from where the sweep started, so no two bands touch the same match.
static void patchmatch_pass(Level *L, int forward, uint32_t seed, const int *before) {
    int w = L->w, h = L->h, step = forward ? 1 : -1, reach = w > h ? w : h;
    in_row_bands(h, ^(int band, int start, int end) {
        uint32_t state = seed ^ (uint32_t)(band * 0x9e3779b9u) ^ 0x85ebca6bu;
        for (int i = 0; i < end - start; ++i) {
            int y = forward ? start + i : end - 1 - i;
            for (int j = 0; j < w; ++j) {
                int x = forward ? j : w - 1 - j, p = y * w + x;
                if (!L->target[p]) continue;
                int best = L->match[p];
                float bestDistance = L->distance[p];
                // What the previous pixel along the row and the previous row matched, moved along by one.
                int nx = x - step, ny = y - step;
                if (nx >= 0 && nx < w && L->target[y * w + nx]) {
                    int m = L->match[y * w + nx], c = m + step;
                    if (m % w + step >= 0 && m % w + step < w && L->source[c] && c != best) {
                        float d = patch_distance(L, p, c, bestDistance);
                        if (d < bestDistance) { best = c; bestDistance = d; }
                    }
                }
                if (ny >= 0 && ny < h && L->target[ny * w + x]) {
                    int m = ny >= start && ny < end ? L->match[ny * w + x] : before[ny * w + x], c = m + step * w;
                    if (m / w + step >= 0 && m / w + step < h && L->source[c] && c != best) {
                        float d = patch_distance(L, p, c, bestDistance);
                        if (d < bestDistance) { best = c; bestDistance = d; }
                    }
                }
                // Then patches at random around the best so far, nearer each time.
                for (int r = reach; r >= 1; r /= 2) {
                    int bx = best % w, by = best / w;
                    int cx = bx + (int)(next_random(&state) % (uint32_t)(2 * r + 1)) - r;
                    int cy = by + (int)(next_random(&state) % (uint32_t)(2 * r + 1)) - r;
                    if (cx < 0 || cy < 0 || cx >= w || cy >= h) continue;
                    int c = cy * w + cx;
                    if (!L->source[c] || c == best) continue;
                    float d = patch_distance(L, p, c, bestDistance);
                    if (d < bestDistance) { best = c; bestDistance = d; }
                }
                L->match[p] = best;
                L->distance[p] = bestDistance;
            }
        }
    });
}

// Each hole pixel becomes the blend of what every target patch covering it says it is, a closer match counting
// for more, by `sharpness`: 1 while the matches settle; more for the last blend, where the best matches all but
// decide alone, as averaging patches that disagree (in busy texture, broken glass) smears it.
// Sources lie wholly outside the hole, so the hole can be rewritten as it's read.
static void vote(Level *L, float sharpness) {
    int w = L->w, h = L->h;
    double total = 0;
    long count = 0;
    for (int p = 0; p < w * h; ++p) if (L->target[p] && L->distance[p] < FLT_MAX) { total += L->distance[p]; ++count; }
    float spread = (2.0f * (float)(count ? total / count : 1) + 1.0f) / sharpness;
    in_row_bands(h, ^(int band, int start, int end) {
        for (int y = start; y < end; ++y) {
            for (int x = 0; x < w; ++x) {
                int a = y * w + x;
                if (!L->hole[a]) continue;
                float sum[CH] = {0}, weights = 0;
                for (int dy = -R; dy <= R; ++dy) {
                    int py = y - dy;
                    if (py < 0 || py >= h) continue;
                    for (int dx = -R; dx <= R; ++dx) {
                        int px = x - dx, p = py * w + px;
                        if (px < 0 || px >= w || !L->target[p] || L->distance[p] == FLT_MAX) continue;
                        int q = L->match[p];
                        const float *s = L->color + ((size_t)(q / w + dy) * w + (size_t)(q % w + dx)) * CH;
                        float weight = expf(-L->distance[p] / spread);
                        for (int c = 0; c < CH; ++c) sum[c] += s[c] * weight;
                        weights += weight;
                    }
                }
                if (weights > 0) for (int c = 0; c < CH; ++c) L->color[(size_t)a * CH + c] = sum[c] / weights;
            }
        }
    });
}

// What the matches say the pixel at (x, y) should be, blended as `vote` blends them.
static int predict(const Level *L, int x, int y, float spread, float out[4]) {
    int w = L->w, h = L->h;
    float sum[4] = {0, 0, 0, 0}, weights = 0;
    for (int dy = -R; dy <= R; ++dy) {
        int py = y - dy;
        if (py < 0 || py >= h) continue;
        for (int dx = -R; dx <= R; ++dx) {
            int px = x - dx, p = py * w + px;
            if (px < 0 || px >= w || !L->target[p] || L->distance[p] == FLT_MAX) continue;
            int q = L->match[p];
            const float *s = L->color + ((size_t)(q / w + dy) * w + (size_t)(q % w + dx)) * CH;
            float weight = expf(-L->distance[p] / spread);
            for (int c = 0; c < 4; ++c) sum[c] += s[c] * weight;
            weights += weight;
        }
    }
    if (weights <= 0) return 0;
    for (int c = 0; c < 4; ++c) out[c] = sum[c] / weights;
    return 1;
}

// Matches its surroundings' tone, as the healing brush does: copied texture can come from somewhere a little
// lighter or darker (further along a sky's gradient, say), which leaves a visible rim. Along the hole's edge, the
// difference between the image and what the matches predict there is spread smoothly across the hole and added.
static int adapt_color(Level *L) {
    int w = L->w, h = L->h, n = w * h;
    double total = 0;
    long count = 0;
    for (int p = 0; p < n; ++p) if (L->target[p] && L->distance[p] < FLT_MAX) { total += L->distance[p]; ++count; }
    float spread = 2.0f * (float)(count ? total / count : 1) + 1.0f;
    // 0 elsewhere, 1 on the edge (fixed), 2 in the hole (solved).
    uint8_t *role = calloc((size_t)n, 1);
    float *offset = calloc((size_t)n * 4, sizeof(float));
    if (!role || !offset) { free(role); free(offset); return 0; }
    double mean[4] = {0, 0, 0, 0};
    long edges = 0;
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
        int p = y * w + x;
        if (L->hole[p]) { role[p] = 2; continue; }
        if (!L->known[p]) continue;
        int touches = 0;
        for (int j = -1; j <= 1 && !touches; ++j) for (int i = -1; i <= 1; ++i) {
            int qx = x + i, qy = y + j;
            if (qx >= 0 && qy >= 0 && qx < w && qy < h && L->hole[qy * w + qx]) { touches = 1; break; }
        }
        float predicted[4];
        if (!touches || !predict(L, x, y, spread, predicted)) continue;
        role[p] = 1;
        for (int c = 0; c < 4; ++c) {
            offset[(size_t)p * 4 + c] = L->color[(size_t)p * CH + c] - predicted[c];
            mean[c] += offset[(size_t)p * 4 + c];
        }
        ++edges;
    }
    if (edges) {
        for (int p = 0; p < n; ++p)
            if (role[p] == 2) for (int c = 0; c < 4; ++c) offset[(size_t)p * 4 + c] = (float)(mean[c] / edges);
        heal_membrane(offset, role, w, h, 0);
        for (int p = 0; p < n; ++p)
            if (role[p] == 2) for (int c = 0; c < 4; ++c) L->color[(size_t)p * CH + c] += offset[(size_t)p * 4 + c];
    }
    free(role); free(offset);
    return 1;
}

// Distances for every target's current match.
static void measure(Level *L) {
    int w = L->w;
    in_row_bands(L->h, ^(int band, int start, int end) {
        for (int p = start * w; p < end * w; ++p)
            if (L->target[p]) L->distance[p] = patch_distance(L, p, L->match[p], FLT_MAX);
    });
}

// The matching and blending, `iterations` times over.
static int settle(Level *L, int iterations, uint32_t seed) {
    int *before = malloc((size_t)L->w * L->h * sizeof(int));
    if (!before) return 0;
    for (int i = 0; i < iterations; ++i) {
        memcpy(before, L->match, (size_t)L->w * L->h * sizeof(int));
        patchmatch_pass(L, i % 2 == 0, seed + (uint32_t)i * 0x632be5abu, before);
        vote(L, 1);
        measure(L);
    }
    free(before);
    return 1;
}

// Each known pixel's texture: how sharply its brightness changes across and down, averaged over the 5 × 5 around it,
// in the two channels after its color. Hole pixels get theirs from what they copy.
static void measure_texture(Level *L) {
    int w = L->w, h = L->h, stride = w + 1;
    float *edge = calloc((size_t)w * h * 2, sizeof(float));
    double *sat = calloc((size_t)stride * (h + 1) * 3, sizeof(double));
    if (!edge || !sat) { free(edge); free(sat); return; }
    #define LUMA(q) ((L->color[(size_t)(q) * CH] + L->color[(size_t)(q) * CH + 1] + L->color[(size_t)(q) * CH + 2]) / 3)
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
        int p = y * w + x;
        if (!L->known[p]) continue;
        if (x > 0 && x + 1 < w && L->known[p - 1] && L->known[p + 1]) edge[p * 2] = fabsf(LUMA(p + 1) - LUMA(p - 1)) / 2;
        if (y > 0 && y + 1 < h && L->known[p - w] && L->known[p + w]) edge[p * 2 + 1] = fabsf(LUMA(p + w) - LUMA(p - w)) / 2;
    }
    #undef LUMA
    // Summed tables of the two edges and of how many known pixels there are, for 5 × 5 averages over known pixels.
    for (int y = 0; y < h; ++y) {
        double row[3] = {0, 0, 0};
        for (int x = 0; x < w; ++x) {
            int p = y * w + x;
            row[0] += edge[p * 2]; row[1] += edge[p * 2 + 1]; row[2] += L->known[p];
            for (int k = 0; k < 3; ++k)
                sat[((size_t)(y + 1) * stride + x + 1) * 3 + k] = sat[((size_t)y * stride + x + 1) * 3 + k] + row[k];
        }
    }
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
        int p = y * w + x;
        if (!L->known[p]) continue;
        int x0 = x - 2 < 0 ? 0 : x - 2, y0 = y - 2 < 0 ? 0 : y - 2, x1 = x + 3 > w ? w : x + 3, y1 = y + 3 > h ? h : y + 3;
        double v[3];
        for (int k = 0; k < 3; ++k)
            v[k] = sat[((size_t)y1 * stride + x1) * 3 + k] - sat[((size_t)y0 * stride + x1) * 3 + k]
                 - sat[((size_t)y1 * stride + x0) * 3 + k] + sat[((size_t)y0 * stride + x0) * 3 + k];
        L->color[(size_t)p * CH + 4] = (float)(v[0] / v[2]) * TEXTURE_WEIGHT;
        L->color[(size_t)p * CH + 5] = (float)(v[1] / v[2]) * TEXTURE_WEIGHT;
    }
    free(edge); free(sat);
}

// A copy half the size: a pixel is hole if any of its four is, known if all of them are.
static int downsample(const Level *F, Level *C) {
    int w = (F->w + 1) / 2, h = (F->h + 1) / 2;
    if (!level_alloc(C, w, h)) return 0;
    for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
            int present = 0, known = 0, hole = 0;
            float all[CH] = {0}, sure[CH] = {0};
            for (int j = 0; j < 2; ++j) for (int i = 0; i < 2; ++i) {
                int fx = 2 * x + i, fy = 2 * y + j;
                if (fx >= F->w || fy >= F->h) continue;
                int f = fy * F->w + fx;
                ++present; known += F->known[f]; hole |= F->hole[f];
                for (int c = 0; c < CH; ++c) {
                    all[c] += F->color[(size_t)f * CH + c];
                    if (F->known[f]) sure[c] += F->color[(size_t)f * CH + c];
                }
            }
            int p = y * w + x;
            C->hole[p] = (uint8_t)hole;
            C->known[p] = !hole && known == present;
            for (int c = 0; c < CH; ++c) C->color[(size_t)p * CH + c] = known ? sure[c] / known : all[c] / present;
        }
    }
    // Texture stays as measured at full size, averaged down, rather than measured again here: shrunk, busy texture
    // blurs to a plain mid-tone, which would match the plainest parts of the image and fill the hole flat.
    return level_classify(C);
}

// The coarsest hole's first guess: filled in from its edge inward, each pixel the average of the filled
// neighbors around it, and whatever no edge reaches the average of the known image.
static void fill_inward(Level *L) {
    int w = L->w, h = L->h, n = w * h;
    uint8_t *done = calloc((size_t)n, 1), *next = calloc((size_t)n, 1);
    if (!done || !next) { free(done); free(next); return; }
    double mean[CH] = {0};
    long known = 0;
    for (int p = 0; p < n; ++p) {
        done[p] = L->known[p];
        if (L->known[p]) { ++known; for (int c = 0; c < CH; ++c) mean[c] += L->color[(size_t)p * CH + c]; }
    }
    for (int changed = 1; changed;) {
        changed = 0;
        memcpy(next, done, (size_t)n);
        for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
            int p = y * w + x;
            if (!L->hole[p] || done[p]) continue;
            float sum[CH] = {0};
            int around = 0;
            for (int j = -1; j <= 1; ++j) for (int i = -1; i <= 1; ++i) {
                int qx = x + i, qy = y + j;
                if ((i || j) && qx >= 0 && qy >= 0 && qx < w && qy < h && done[qy * w + qx]) {
                    for (int c = 0; c < CH; ++c) sum[c] += L->color[(size_t)(qy * w + qx) * CH + c];
                    ++around;
                }
            }
            if (!around) continue;
            for (int c = 0; c < CH; ++c) L->color[(size_t)p * CH + c] = sum[c] / around;
            next[p] = 1; changed = 1;
        }
        memcpy(done, next, (size_t)n);
    }
    for (int p = 0; p < n; ++p)
        if (L->hole[p] && !done[p]) for (int c = 0; c < CH; ++c) L->color[(size_t)p * CH + c] = known ? (float)(mean[c] / known) : 0;
    free(done); free(next);
}

static void match_randomly(Level *L, uint32_t seed) {
    uint32_t state = seed | 1;
    for (int p = 0; p < L->w * L->h; ++p)
        if (L->target[p]) L->match[p] = L->sources[next_random(&state) % (uint32_t)L->sourceCount];
}

// The finer copy starts where the coarser one finished: its hole from the coarser estimate, each target's match
// from the coarser match, scaled up.
static void upsample(const Level *C, Level *F, uint32_t seed) {
    int w = F->w;
    uint32_t state = seed | 1;
    for (int y = 0; y < F->h; ++y) {
        for (int x = 0; x < w; ++x) {
            int p = y * w + x, c = (y / 2) * C->w + x / 2;
            if (F->hole[p]) memcpy(F->color + (size_t)p * CH, C->color + (size_t)c * CH, CH * sizeof(float));
            if (!F->target[p]) continue;
            int candidate = -1;
            if (C->target[c]) {
                int m = C->match[c], mx = 2 * (m % C->w) + (x & 1), my = 2 * (m / C->w) + (y & 1);
                if (mx < w && my < F->h && F->source[my * w + mx]) candidate = my * w + mx;
            }
            F->match[p] = candidate >= 0 ? candidate : F->sources[next_random(&state) % (uint32_t)F->sourceCount];
        }
    }
}

int patch_fill(uint8_t *rgba, size_t stride, const uint8_t *hole, size_t holeStride, int width, int height, uint32_t seed) {
    // Work on the hole and the image around it: room to find texture, without a whole large layer at every size.
    int x0 = width, y0 = height, x1 = 0, y1 = 0;
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
        if (!hole[(size_t)y * holeStride + x]) continue;
        if (x < x0) x0 = x;
        if (x + 1 > x1) x1 = x + 1;
        if (y < y0) y0 = y;
        if (y + 1 > y1) y1 = y + 1;
    }
    if (x1 <= x0) return 1;
    int size = x1 - x0 > y1 - y0 ? x1 - x0 : y1 - y0, margin = size < 64 ? 64 : size;
    int bx0 = x0 - margin < 0 ? 0 : x0 - margin, by0 = y0 - margin < 0 ? 0 : y0 - margin;
    int bx1 = x1 + margin > width ? width : x1 + margin, by1 = y1 + margin > height ? height : y1 + margin;

    enum { MAX_LEVELS = 12 };
    Level levels[MAX_LEVELS];
    memset(levels, 0, sizeof levels);
    int count = 0, status = -1;
    Level *fine = &levels[0];
    if (!level_alloc(fine, bx1 - bx0, by1 - by0)) goto done;
    for (int y = 0; y < fine->h; ++y) {
        for (int x = 0; x < fine->w; ++x) {
            const uint8_t *s = rgba + (size_t)(by0 + y) * stride + (size_t)(bx0 + x) * 4;
            int p = y * fine->w + x;
            fine->hole[p] = hole[(size_t)(by0 + y) * holeStride + bx0 + x] != 0;
            fine->known[p] = !fine->hole[p] && s[3] == 255;
            fine->color[(size_t)p * CH + 4] = fine->color[(size_t)p * CH + 5] = 0;
            for (int c = 0; c < 4; ++c) fine->color[(size_t)p * CH + c] = s[c];
        }
    }
    if (!level_classify(fine)) goto done;
    measure_texture(fine);
    count = 1;
    if (!fine->sourceCount) { status = 0; goto done; }
    // Halved until the hole is a couple of patches across, or the image too small to hold sources.
    for (int span = size; span > 4 * (2 * R + 1) && count < MAX_LEVELS; span /= 2) {
        Level *F = &levels[count - 1];
        if (F->w < 8 * (2 * R + 1) || F->h < 8 * (2 * R + 1)) break;
        if (!downsample(F, &levels[count])) goto done;
        if (!levels[count].sourceCount) { level_free(&levels[count]); break; }
        ++count;
    }
    Level *coarsest = &levels[count - 1];
    fill_inward(coarsest);
    match_randomly(coarsest, seed);
    measure(coarsest);
    if (!settle(coarsest, 12, seed)) goto done;
    for (int i = count - 2; i >= 0; --i) {
        upsample(&levels[i + 1], &levels[i], seed + (uint32_t)i);
        measure(&levels[i]);
        vote(&levels[i], 1);
        measure(&levels[i]);
        if (!settle(&levels[i], i == 0 ? 4 : 6, seed + 0x1000u * (uint32_t)(i + 1))) goto done;
    }
    vote(fine, SHARP_FINISH);
    if (!adapt_color(fine)) goto done;
    for (int y = 0; y < fine->h; ++y) {
        for (int x = 0; x < fine->w; ++x) {
            int p = y * fine->w + x;
            if (!fine->hole[p]) continue;
            uint8_t *t = rgba + (size_t)(by0 + y) * stride + (size_t)(bx0 + x) * 4;
            const float *v = fine->color + (size_t)p * CH;
            float alpha = v[3] < 0 ? 0 : v[3] > 255 ? 255 : v[3];
            t[3] = (uint8_t)lrintf(alpha);
            for (int c = 0; c < 3; ++c) t[c] = (uint8_t)lrintf(v[c] < 0 ? 0 : v[c] > t[3] ? t[3] : v[c]);
        }
    }
    status = 1;
done:
    for (int i = 0; i < MAX_LEVELS; ++i) level_free(&levels[i]);
    return status;
}
