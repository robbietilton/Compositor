#include "WandPixels.h"
#include <stdlib.h>
#include <string.h>
#include <limits.h>

enum { EAST = 1, SOUTH = 2, WEST = 4, NORTH = 8 };
// Outlines with more pixel edges than this are refused: the path would be too slow to draw.
static const size_t wand_edge_limit = 8000000;

void wand_copy_flipped_rgba(const uint8_t *source, size_t sourceStride,
                            uint8_t *destination, size_t width, size_t height) {
    for (size_t y = 0; y < height; ++y)
        memcpy(destination + y * width * 4, source + (height - 1 - y) * sourceStride, width * 4);
}

void wand_downsample_mask_any(const uint8_t *source, size_t width, size_t height,
                              uint8_t *destination, size_t sampledWidth, size_t sampledHeight,
                              double scale) {
    memset(destination, 0, sampledWidth * sampledHeight);
    for (size_t y = 0; y < height; ++y) {
        size_t dy = (size_t)((double)y * scale);
        if (dy >= sampledHeight) dy = sampledHeight - 1;
        const uint8_t *row = source + y * width;
        uint8_t *out = destination + dy * sampledWidth;
        for (size_t x = 0; x < width; ++x) {
            if (row[x]) {
                size_t dx = (size_t)((double)x * scale);
                if (dx >= sampledWidth) dx = sampledWidth - 1;
                out[dx] = 255;
            }
        }
    }
}

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

typedef struct {
    int minimum[3], maximum[3];
    uint64_t sum[3], count;
} QuickColourModel;

typedef struct {
    int score;
    size_t index, parent;
} QuickCandidate;

typedef struct {
    QuickCandidate *items;
    size_t count, capacity;
} QuickHeap;

static inline int quick_max(int a, int b) { return a > b ? a : b; }
static inline int quick_abs(int value) { return value < 0 ? -value : value; }

static void quick_observe(QuickColourModel *model, const uint8_t *pixel) {
    for (int channel = 0; channel < 3; ++channel) {
        int value = pixel[channel];
        if (value < model->minimum[channel]) model->minimum[channel] = value;
        if (value > model->maximum[channel]) model->maximum[channel] = value;
        model->sum[channel] += value;
    }
    ++model->count;
}

static int quick_model_distance(const QuickColourModel *model, const uint8_t *pixel) {
    int rangeDistance = 0, meanDistance = 0;
    for (int channel = 0; channel < 3; ++channel) {
        int value = pixel[channel];
        int range = value < model->minimum[channel] ? model->minimum[channel] - value
                  : value > model->maximum[channel] ? value - model->maximum[channel] : 0;
        rangeDistance = quick_max(rangeDistance, range);
        int mean = (int)((model->sum[channel] + model->count / 2) / model->count);
        meanDistance = quick_max(meanDistance, quick_abs(value - mean));
    }
    return quick_max(rangeDistance, meanDistance / 2);
}

static inline int quick_colour_distance(const uint8_t *a, const uint8_t *b) {
    return quick_max(quick_abs((int)a[0] - b[0]),
                     quick_max(quick_abs((int)a[1] - b[1]), quick_abs((int)a[2] - b[2])));
}

static inline int quick_luminance(const uint8_t *pixel) {
    return (54 * pixel[0] + 183 * pixel[1] + 19 * pixel[2]) / 256;
}

static inline int quick_before(QuickCandidate a, QuickCandidate b) {
    return a.score == b.score ? a.index < b.index : a.score < b.score;
}

static int quick_push(QuickHeap *heap, QuickCandidate candidate) {
    if (heap->count == heap->capacity) {
        size_t capacity = heap->capacity ? heap->capacity * 2 : 1024;
        if (capacity > SIZE_MAX / sizeof(QuickCandidate)) return 0;
        QuickCandidate *items = realloc(heap->items, capacity * sizeof(QuickCandidate));
        if (!items) return 0;
        heap->items = items;
        heap->capacity = capacity;
    }
    size_t index = heap->count++;
    while (index > 0) {
        size_t parent = (index - 1) / 2;
        if (!quick_before(candidate, heap->items[parent])) break;
        heap->items[index] = heap->items[parent];
        index = parent;
    }
    heap->items[index] = candidate;
    return 1;
}

static QuickCandidate quick_pop(QuickHeap *heap) {
    QuickCandidate first = heap->items[0];
    QuickCandidate last = heap->items[--heap->count];
    if (heap->count) {
        size_t index = 0;
        for (;;) {
            size_t left = index * 2 + 1;
            if (left >= heap->count) break;
            size_t right = left + 1;
            size_t child = right < heap->count && quick_before(heap->items[right], heap->items[left]) ? right : left;
            if (!quick_before(heap->items[child], last)) break;
            heap->items[index] = heap->items[child];
            index = child;
        }
        heap->items[index] = last;
    }
    return first;
}

static int quick_enqueue(QuickHeap *heap, int *best, uint32_t *stamp, uint32_t epoch,
                         const uint8_t *rgba, const QuickColourModel *model,
                         size_t parent, size_t index) {
    const uint8_t *from = rgba + parent * 4, *to = rgba + index * 4;
    int score = quick_colour_distance(from, to) * 3 + quick_model_distance(model, to) * 2
              + quick_abs(quick_luminance(from) - quick_luminance(to)) * 4;
    if (stamp[index] == epoch && score >= best[index]) return 1;
    stamp[index] = epoch;
    best[index] = score;
    return quick_push(heap, (QuickCandidate){score, index, parent});
}

static int quick_neighbours(QuickHeap *heap, int *best, uint32_t *stamp, uint32_t epoch,
                            const uint8_t *rgba, const QuickColourModel *model,
                            size_t width, size_t height, size_t index) {
    size_t x = index % width, y = index / width;
    if (x && !quick_enqueue(heap, best, stamp, epoch, rgba, model, index, index - 1)) return 0;
    if (x + 1 < width && !quick_enqueue(heap, best, stamp, epoch, rgba, model, index, index + 1)) return 0;
    if (y && !quick_enqueue(heap, best, stamp, epoch, rgba, model, index, index - width)) return 0;
    if (y + 1 < height && !quick_enqueue(heap, best, stamp, epoch, rgba, model, index, index + width)) return 0;
    return 1;
}

long quick_selection_mask(const uint8_t *rgba, size_t width, size_t height,
                          const int32_t *points, size_t pointCount, int diameter,
                          int tolerance, int edgeSensitivity, const uint8_t *previous,
                          uint8_t *mask) {
    if (!rgba || !mask || !points || !width || !height || width > SIZE_MAX / height ||
        pointCount >= UINT32_MAX) return -1;
    size_t pixels = width * height;
    if (pixels > SIZE_MAX / sizeof(int) || pixels > SIZE_MAX / sizeof(uint32_t)) return -1;
    if (previous) memcpy(mask, previous, pixels);
    else memset(mask, 0, pixels);
    int *best = malloc(pixels * sizeof(int));
    uint32_t *stamp = calloc(pixels, sizeof(uint32_t));
    if (!best || !stamp) { free(best); free(stamp); return -1; }
    QuickHeap heap = {0};
    long selected = 0;
    if (previous) {
        for (size_t i = 0; i < pixels; ++i) selected += previous[i] != 0;
    }
    int radius = quick_max(1, diameter / 2);
    for (size_t point = 0; point < pointCount; ++point) {
        int64_t x = points[point * 2], y = points[point * 2 + 1];
        if (x < 0 || y < 0 || (uint64_t)x >= width || (uint64_t)y >= height) continue;
        uint32_t epoch = (uint32_t)point + 1;
        QuickColourModel model = {.minimum = {255, 255, 255}};
        const uint8_t *brushColour = rgba + ((size_t)y * width + (size_t)x) * 4;
        size_t left = (size_t)x > (size_t)radius ? (size_t)x - radius : 0;
        size_t top = (size_t)y > (size_t)radius ? (size_t)y - radius : 0;
        size_t right = (size_t)x + radius < width ? (size_t)x + radius : width - 1;
        size_t bottom = (size_t)y + radius < height ? (size_t)y + radius : height - 1;
        for (size_t row = top; row <= bottom; ++row) {
            for (size_t col = left; col <= right; ++col) {
                int64_t dx = (int64_t)col - x, dy = (int64_t)row - y;
                if (dx * dx + dy * dy > (int64_t)radius * radius) continue;
                size_t index = row * width + col;
                if (!mask[index]) { mask[index] = 255; ++selected; }
                stamp[index] = epoch;
                best[index] = 0;
                quick_observe(&model, rgba + index * 4);
            }
        }
        for (size_t row = top; row <= bottom; ++row) {
            for (size_t col = left; col <= right; ++col) {
                size_t index = row * width + col;
                if (stamp[index] == epoch && best[index] == 0 &&
                    !quick_neighbours(&heap, best, stamp, epoch, rgba, &model, width, height, index))
                    goto memory_failure;
            }
        }
        while (heap.count) {
            QuickCandidate candidate = quick_pop(&heap);
            if (mask[candidate.index] || stamp[candidate.index] != epoch ||
                candidate.score != best[candidate.index]) continue;
            const uint8_t *from = rgba + candidate.parent * 4, *to = rgba + candidate.index * 4;
            int local = quick_colour_distance(from, to), distance = quick_model_distance(&model, to);
            int edge = quick_abs(quick_luminance(from) - quick_luminance(to));
            int localLimit = quick_max(8, tolerance * 3 / 2), modelLimit = quick_max(12, tolerance * 6);
            if (local > localLimit || distance > modelLimit) continue;
            int shiftedChannels = 0, anchorLimit = quick_max(24, tolerance * 2);
            for (int channel = 0; channel < 3; ++channel)
                shiftedChannels += quick_abs((int)to[channel] - brushColour[channel]) > anchorLimit;
            if (shiftedChannels > 1) continue;
            if (edge > edgeSensitivity && (edge > edgeSensitivity * 2 || distance > tolerance)) continue;
            mask[candidate.index] = 255;
            quick_observe(&model, to);
            ++selected;
            if (!quick_neighbours(&heap, best, stamp, epoch, rgba, &model,
                                  width, height, candidate.index)) goto memory_failure;
        }
    }
    free(best);
    free(stamp);
    free(heap.items);
    return selected;
memory_failure:
    free(best);
    free(stamp);
    free(heap.items);
    return -1;
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
