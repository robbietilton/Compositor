#include "WandPixels.h"
#include <stdlib.h>
#include <string.h>

enum { EAST = 1, SOUTH = 2, WEST = 4, NORTH = 8 };
// Outlines with more pixel edges than this are refused: the path would be too slow to draw.
static const size_t wand_edge_limit = 8000000;

static inline int wand_matches(const uint8_t *p, const int reference[4], int tolerance) {
    for (int c = 0; c < 4; ++c) {
        int d = (int)p[c] - reference[c];
        if (d < -tolerance || d > tolerance) return 0;
    }
    return 1;
}

long wand_mask(const uint8_t *rgba, size_t width, size_t height, size_t stride,
               size_t seedX, size_t seedY, size_t radius, int tolerance, int contiguous, uint8_t *mask) {
    if (!width || !height) return 0;
    memset(mask, 0, width * height);
    if (seedX >= width || seedY >= height) return 0;
    size_t x0 = seedX > radius ? seedX - radius : 0, x1 = seedX + radius < width ? seedX + radius : width - 1;
    size_t y0 = seedY > radius ? seedY - radius : 0, y1 = seedY + radius < height ? seedY + radius : height - 1;
    unsigned long sums[4] = {0, 0, 0, 0}, samples = 0;
    for (size_t y = y0; y <= y1; ++y)
        for (size_t x = x0; x <= x1; ++x, ++samples)
            for (int c = 0; c < 4; ++c) sums[c] += rgba[y * stride + x * 4 + c];
    int reference[4];
    for (int c = 0; c < 4; ++c) reference[c] = (int)((sums[c] + samples / 2) / samples);

    long count = 0;
    if (!contiguous) {
        for (size_t y = 0; y < height; ++y) {
            const uint8_t *row = rgba + y * stride;
            uint8_t *out = mask + y * width;
            for (size_t x = 0; x < width; ++x)
                if (wand_matches(row + x * 4, reference, tolerance)) { out[x] = 255; ++count; }
        }
        return count;
    }

    // Scanline flood fill: each popped seed fills its whole horizontal run, then pushes one
    // seed per matching run in the rows directly above and below it.
    size_t capacity = 4096, top = 1;
    size_t *stack = malloc(capacity * 2 * sizeof(size_t));
    if (!stack) return -1;
    stack[0] = seedX;
    stack[1] = seedY;
    while (top) {
        --top;
        size_t x = stack[top * 2], y = stack[top * 2 + 1];
        const uint8_t *row = rgba + y * stride;
        uint8_t *out = mask + y * width;
        if (out[x] || !wand_matches(row + x * 4, reference, tolerance)) continue;
        size_t left = x, right = x;
        while (left > 0 && !out[left - 1] && wand_matches(row + (left - 1) * 4, reference, tolerance)) --left;
        while (right + 1 < width && !out[right + 1] && wand_matches(row + (right + 1) * 4, reference, tolerance)) ++right;
        memset(out + left, 255, right - left + 1);
        count += (long)(right - left + 1);
        for (int side = 0; side < 2; ++side) {
            if (side == 0 ? y == 0 : y + 1 >= height) continue;
            size_t ny = side == 0 ? y - 1 : y + 1;
            const uint8_t *nrow = rgba + ny * stride;
            const uint8_t *nout = mask + ny * width;
            int inRun = 0;
            for (size_t nx = left; nx <= right; ++nx) {
                int candidate = !nout[nx] && wand_matches(nrow + nx * 4, reference, tolerance);
                if (candidate && !inRun) {
                    if (top == capacity) {
                        size_t *grown = realloc(stack, capacity * 4 * sizeof(size_t));
                        if (!grown) { free(stack); return -1; }
                        stack = grown;
                        capacity *= 2;
                    }
                    stack[top * 2] = nx;
                    stack[top * 2 + 1] = ny;
                    ++top;
                }
                inRun = candidate;
            }
        }
    }
    free(stack);
    return count;
}

// Headings, clockwise on screen (y grows downward): east, south, west, north.
static inline int turn_right(int d) { return d == NORTH ? EAST : d << 1; }
static inline int turn_left(int d) { return d == EAST ? NORTH : d >> 1; }

int wand_trace(const uint8_t *mask, size_t width, size_t height,
               int32_t **points, size_t *pointCount, int32_t **loops, size_t *loopCount) {
    *points = NULL;
    *loops = NULL;
    *pointCount = 0;
    *loopCount = 0;
    if (!width || !height) return 0;
    if (width >= INT32_MAX || height >= INT32_MAX) return -1;
    // Each vertex of the (width + 1) × (height + 1) grid records the directed boundary edges
    // leaving it: a selected pixel's unselected sides, walked clockwise around the pixel.
    size_t stride = width + 1, vertices = stride * (height + 1), edges = 0;
    uint8_t *out = calloc(vertices, 1);
    if (!out) return -1;
    for (size_t y = 0; y < height; ++y) {
        const uint8_t *row = mask + y * width;
        for (size_t x = 0; x < width; ++x) {
            if (!row[x]) continue;
            if (y == 0 || !mask[(y - 1) * width + x]) { out[y * stride + x] |= EAST; ++edges; }
            if (x + 1 == width || !row[x + 1]) { out[y * stride + x + 1] |= SOUTH; ++edges; }
            if (y + 1 == height || !mask[(y + 1) * width + x]) { out[(y + 1) * stride + x + 1] |= WEST; ++edges; }
            if (x == 0 || !row[x - 1]) { out[(y + 1) * stride + x] |= NORTH; ++edges; }
        }
        if (edges > wand_edge_limit) { free(out); return -2; }
    }

    size_t pointCapacity = 1024, loopCapacity = 256, np = 0, nl = 0;
    int32_t *pts = malloc(pointCapacity * 2 * sizeof(int32_t));
    int32_t *lens = malloc(loopCapacity * sizeof(int32_t));
    if (!pts || !lens) goto fail;
    for (size_t start = 0; start < vertices; ++start) {
        while (out[start]) {
            size_t first = np, v = start;
            int heading = 0, initial = 0;
            do {
                int bits = out[v], d;
                // Where two loops meet at a corner, turning right keeps them apart.
                if (!heading) d = bits & -bits;
                else if (bits & turn_right(heading)) d = turn_right(heading);
                else if (bits & heading) d = heading;
                else if (bits & turn_left(heading)) d = turn_left(heading);
                else d = bits & -bits;
                if (!d) break;
                out[v] &= (uint8_t)~d;
                if (d != heading) {
                    if (np == pointCapacity) {
                        int32_t *grown = realloc(pts, pointCapacity * 4 * sizeof(int32_t));
                        if (!grown) goto fail;
                        pts = grown;
                        pointCapacity *= 2;
                    }
                    pts[np * 2] = (int32_t)(v % stride);
                    pts[np * 2 + 1] = (int32_t)(v / stride);
                    ++np;
                }
                if (!heading) initial = d;
                heading = d;
                v = d == EAST ? v + 1 : d == WEST ? v - 1 : d == SOUTH ? v + stride : v - stride;
            } while (v != start);
            // The start is a corner unless the loop arrives on the heading it left with.
            if (heading == initial && np > first) {
                memmove(pts + first * 2, pts + (first + 1) * 2, (np - first - 1) * 2 * sizeof(int32_t));
                --np;
            }
            if (nl == loopCapacity) {
                int32_t *grown = realloc(lens, loopCapacity * 2 * sizeof(int32_t));
                if (!grown) goto fail;
                lens = grown;
                loopCapacity *= 2;
            }
            lens[nl++] = (int32_t)(np - first);
        }
    }
    free(out);
    *points = pts;
    *loops = lens;
    *pointCount = np;
    *loopCount = nl;
    return 0;
fail:
    free(out);
    free(pts);
    free(lens);
    return -1;
}

static inline int color_near(const int *rgb, const uint8_t *colors, int count, int fuzziness) {
    for (int i = 0; i < count; ++i) {
        const uint8_t *c = colors + i * 3;
        if (abs(rgb[0] - c[0]) <= fuzziness && abs(rgb[1] - c[1]) <= fuzziness && abs(rgb[2] - c[2]) <= fuzziness) return 1;
    }
    return 0;
}

long color_range_mask(const uint8_t *rgba, size_t width, size_t height, size_t stride,
                      const uint8_t *include, int includeCount, const uint8_t *exclude, int excludeCount,
                      int fuzziness, int invert, uint8_t *mask) {
    long count = 0;
    for (size_t y = 0; y < height; ++y) {
        const uint8_t *row = rgba + y * stride;
        uint8_t *out = mask + y * width;
        for (size_t x = 0; x < width; ++x) {
            const uint8_t *px = row + x * 4;
            int matches = 0;
            if (px[3]) {
                int rgb[3];
                for (int c = 0; c < 3; ++c) rgb[c] = (px[c] * 255 + px[3] / 2) / px[3];
                matches = color_near(rgb, include, includeCount, fuzziness) && !color_near(rgb, exclude, excludeCount, fuzziness);
            }
            if (invert) matches = !matches;
            out[x] = matches ? 255 : 0;
            count += matches;
        }
    }
    return count;
}
