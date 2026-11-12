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
#include <stdlib.h>

static uint8_t brush_density_byte(float density, float cap) {
    float alpha = fminf(1 - expf(-density), cap);
    return (uint8_t)roundf(fminf(1, fmaxf(0, alpha)) * 255);
}

void brush_edge_distance(float *destination, size_t width, size_t height,
                         const float *coverage, size_t sourceWidth, size_t sourceHeight,
                         size_t offsetX, size_t offsetY) {
    if (!destination || !coverage || !width || !height || !sourceWidth || !sourceHeight) return;
    const size_t count = sourceWidth * sourceHeight;
    float *distance = malloc(count * sizeof(float));
    if (!distance) return;
    const float diagonal = 1.41421356f, infinity = (float)(sourceWidth + sourceHeight + 1);
    for (size_t i = 0; i < count; ++i) distance[i] = coverage[i] > 0.01f ? infinity : 0;
    for (size_t y = 0; y < sourceHeight; ++y) for (size_t x = 0; x < sourceWidth; ++x) {
        size_t i = y * sourceWidth + x;
        if (distance[i] == 0) continue;
        if (x) distance[i] = fminf(distance[i], distance[i - 1] + 1);
        if (y) {
            distance[i] = fminf(distance[i], distance[i - sourceWidth] + 1);
            if (x) distance[i] = fminf(distance[i], distance[i - sourceWidth - 1] + diagonal);
            if (x + 1 < sourceWidth) distance[i] = fminf(distance[i], distance[i - sourceWidth + 1] + diagonal);
        }
    }
    for (size_t y = sourceHeight; y-- > 0;) for (size_t x = sourceWidth; x-- > 0;) {
        size_t i = y * sourceWidth + x;
        if (distance[i] == 0) continue;
        if (x + 1 < sourceWidth) distance[i] = fminf(distance[i], distance[i + 1] + 1);
        if (y + 1 < sourceHeight) {
            distance[i] = fminf(distance[i], distance[i + sourceWidth] + 1);
            if (x) distance[i] = fminf(distance[i], distance[i + sourceWidth - 1] + diagonal);
            if (x + 1 < sourceWidth) distance[i] = fminf(distance[i], distance[i + sourceWidth + 1] + diagonal);
        }
    }
    for (size_t y = 0; y < height; ++y) for (size_t x = 0; x < width; ++x)
        destination[y * width + x] = distance[(y + offsetY) * sourceWidth + x + offsetX];
    free(distance);
}

static float backrun_noise(uint32_t seed, float x, float y);

static float watercolor_sample(const float *coverage, size_t width, size_t height, float x, float y) {
    x = fminf((float)width - 1.001f, fmaxf(0, x));
    y = fminf((float)height - 1.001f, fmaxf(0, y));
    size_t x0 = (size_t)x, y0 = (size_t)y;
    size_t x1 = x0 + 1 < width ? x0 + 1 : x0;
    size_t y1 = y0 + 1 < height ? y0 + 1 : y0;
    float fx = x - (float)x0, fy = y - (float)y0;
    float top = coverage[y0 * width + x0] * (1 - fx) + coverage[y0 * width + x1] * fx;
    float bottom = coverage[y1 * width + x0] * (1 - fx) + coverage[y1 * width + x1] * fx;
    return top * (1 - fy) + bottom * fy;
}

void brush_watercolor_wash(uint8_t *rgba, size_t stride, size_t width, size_t height,
                           const float *coverage, size_t sourceWidth, size_t sourceHeight,
                           size_t offsetX, size_t offsetY, uint32_t seed, float wetness,
                           float red, float green, float blue, float originX, float originY) {
    if (!rgba || !coverage || width == 0 || height == 0 || sourceWidth == 0 || sourceHeight == 0 || wetness <= 0) return;
    const float pigment[] = {fminf(1, fmaxf(0, red)), fminf(1, fmaxf(0, green)), fminf(1, fmaxf(0, blue))};
    for (size_t y = 0; y < height; ++y) {
        uint8_t *row = rgba + y * stride;
        for (size_t x = 0; x < width; ++x) {
            float sx = (float)(x + offsetX), sy = (float)(y + offsetY);
            float center = watercolor_sample(coverage, sourceWidth, sourceHeight, sx, sy);
            float gx = watercolor_sample(coverage, sourceWidth, sourceHeight, sx + 2, sy)
                - watercolor_sample(coverage, sourceWidth, sourceHeight, sx - 2, sy);
            float gy = watercolor_sample(coverage, sourceWidth, sourceHeight, sx, sy + 2)
                - watercolor_sample(coverage, sourceWidth, sourceHeight, sx, sy - 2);
            float outwardX = -gx, outwardY = -gy;
            float normalLength = sqrtf(outwardX * outwardX + outwardY * outwardY);
            if (normalLength > 1e-5f) { outwardX /= normalLength; outwardY /= normalLength; }

            float worldX = originX + (float)x, worldY = originY + (float)y;
            float epsilon = 2.0f;
            uint32_t flowSeed = seed ^ 0x4f1bbcdcu;
            float up = backrun_noise(flowSeed, worldX * 0.018f, (worldY + epsilon) * 0.018f);
            float down = backrun_noise(flowSeed, worldX * 0.018f, (worldY - epsilon) * 0.018f);
            float right = backrun_noise(flowSeed, (worldX + epsilon) * 0.018f, worldY * 0.018f);
            float left = backrun_noise(flowSeed, (worldX - epsilon) * 0.018f, worldY * 0.018f);
            float curlX = up - down, curlY = left - right;
            float curlLength = sqrtf(curlX * curlX + curlY * curlY);
            if (curlLength > 1e-5f) { curlX /= curlLength; curlY /= curlLength; }
            float flowX = outwardX * 0.68f + curlX * 0.24f;
            float flowY = outwardY * 0.68f + curlY * 0.24f + 0.12f;
            float flowLength = sqrtf(flowX * flowX + flowY * flowY);
            if (flowLength > 1e-5f) { flowX /= flowLength; flowY /= flowLength; }

            const float distances[] = {2, 5, 9, 14, 20};
            const float weights[] = {1, 0.88f, 0.68f, 0.46f, 0.28f};
            float transported = 0, totalWeight = 0;
            for (int sample = 0; sample < 5; ++sample) {
                float distance = distances[sample];
                transported += watercolor_sample(coverage, sourceWidth, sourceHeight,
                    sx - flowX * distance, sy - flowY * distance) * weights[sample];
                totalWeight += weights[sample];
            }
            transported /= totalWeight;
            float washAmount = center > 0.5f
                ? fmaxf(0, transported - center * 0.88f) * 0.42f + center * 0.035f
                : transported * 0.56f;
            float alpha = fminf(0.30f, wetness * washAmount * 2.4f);
            if (alpha <= 0.0005f) continue;
            for (int channel = 0; channel < 3; ++channel) {
                float lightened = pigment[channel] * 0.42f + 0.58f;
                row[x * 4 + channel] = (uint8_t)roundf(lightened * alpha * 255);
            }
            row[x * 4 + 3] = (uint8_t)roundf(alpha * 255);
        }
    }
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
                    float spread = 0.36f * wet;
                    // A normalized five-tap cross preserves the softened watercolor edge
                    // without the four extra diagonal samples used by the old filter.
                    float blurred = t * 4;
                    blurred += combined_sample(tipMask, side, second, secondSide, scale, classic, su + spread, sv, filter, hardness, ux, uy, vx, vy)
                        + combined_sample(tipMask, side, second, secondSide, scale, classic, su - spread, sv, filter, hardness, ux, uy, vx, vy)
                        + combined_sample(tipMask, side, second, secondSide, scale, classic, su, sv + spread, filter, hardness, ux, uy, vx, vy)
                        + combined_sample(tipMask, side, second, secondSide, scale, classic, su, sv - spread, filter, hardness, ux, uy, vx, vy);
                    t = t * (1 - wet) + blurred * (wet / 8);
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
            if (edges) edges[i] = fminf(32, edges[i] + flow * 7 * tip * (1 - tip));
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

static uint32_t backrun_hash(int32_t x, int32_t y, uint32_t seed) {
    uint32_t value = seed ^ (uint32_t)x * 0x9e3779b9u ^ (uint32_t)y * 0x85ebca6bu;
    value ^= value >> 16; value *= 0x7feb352du;
    value ^= value >> 15; value *= 0x846ca68bu;
    return value ^ (value >> 16);
}

static float backrun_random(uint32_t value) {
    return (float)(value & 0x00ffffffu) / 16777215.0f;
}

static float backrun_smooth(float a, float b, float value) {
    float t = fminf(1, fmaxf(0, (value - a) / (b - a)));
    return t * t * (3 - 2 * t);
}

static float backrun_noise(uint32_t seed, float x, float y) {
    int32_t ix = (int32_t)floorf(x), iy = (int32_t)floorf(y);
    float fx = x - floorf(x), fy = y - floorf(y);
    fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy);
    float a = backrun_random(backrun_hash(ix, iy, seed));
    float b = backrun_random(backrun_hash(ix + 1, iy, seed));
    float c = backrun_random(backrun_hash(ix, iy + 1, seed));
    float d = backrun_random(backrun_hash(ix + 1, iy + 1, seed));
    return (1 - fy) * ((1 - fx) * a + fx * b) + fy * ((1 - fx) * c + fx * d);
}

static float backrun_fbm(uint32_t seed, float x, float y) {
    return backrun_noise(seed, x, y) * 0.7f
        + backrun_noise(seed ^ 0x68bc21ebu, x * 2.03f, y * 2.03f) * 0.3f;
}

static float backrun_alpha_at(const float *density, const float *cap, float opacity, size_t index) {
    return fminf(1 - expf(-density[index]), cap ? cap[index] : 1) * opacity;
}

static float backrun_edge_distance(const float *density, const float *cap, float opacity,
                                   size_t width, size_t height, size_t index, float center,
                                   float cellSize, float *outX, float *outY) {
    if (!density || !width || !height || center <= 0.015f) return -1;
    static const float directions[8][2] = {
        {1,0}, {-1,0}, {0,1}, {0,-1}, {0.70710678f,0.70710678f},
        {-0.70710678f,0.70710678f}, {0.70710678f,-0.70710678f}, {-0.70710678f,-0.70710678f}
    };
    static const float radii[3] = {0.5f, 1.5f, 3.0f};
    float best = 0.5f * cellSize;
    int found = 0;
    int32_t px = (int32_t)(index % width), py = (int32_t)(index / width);
    float cutoff = fmaxf(0.012f, center * 0.42f);
    for (int direction = 0; direction < 8; ++direction) {
        for (int step = 0; step < 3; ++step) {
            float radius = radii[step] * cellSize;
            int32_t sx = px + (int32_t)roundf(directions[direction][0] * radius);
            int32_t sy = py + (int32_t)roundf(directions[direction][1] * radius);
            if (sx < 0 || sy < 0 || sx >= (int32_t)width || sy >= (int32_t)height) continue;
            float sample = backrun_alpha_at(density, cap, opacity, (size_t)sy * width + (size_t)sx);
            if (sample <= cutoff && (!found || radius < best)) {
                best = radius;
                *outX = directions[direction][0]; *outY = directions[direction][1];
                found = 1;
                break;
            }
        }
    }
    return found ? best : -1;
}

static void backrun_field(uint32_t seed, float cellSize, int32_t x, int32_t y, float edgeDistance,
                          float outX, float outY, float *core, float *rim) {
    float tangentX = -outY, tangentY = outX;
    float px = (float)x, py = (float)y;
    float epsilon = fmaxf(1, cellSize * 0.18f);
    uint32_t flowSeed = seed ^ 0x4f1bbcdcu;
    float potentialUp = backrun_noise(flowSeed, px / cellSize, (py + epsilon) / cellSize);
    float potentialDown = backrun_noise(flowSeed, px / cellSize, (py - epsilon) / cellSize);
    float potentialRight = backrun_noise(flowSeed, (px + epsilon) / cellSize, py / cellSize);
    float potentialLeft = backrun_noise(flowSeed, (px - epsilon) / cellSize, py / cellSize);
    float curlX = potentialUp - potentialDown;
    float curlY = potentialLeft - potentialRight;
    float curlLength = sqrtf(curlX * curlX + curlY * curlY);
    if (curlLength > 1e-5f) { curlX /= curlLength; curlY /= curlLength; }
    float flowX = outX * 0.72f + curlX * 0.24f;
    float flowY = outY * 0.72f + curlY * 0.24f + 0.12f;
    float flowLength = sqrtf(flowX * flowX + flowY * flowY);
    if (flowLength > 1e-5f) { flowX /= flowLength; flowY /= flowLength; }

    // Backtrace the bloom pattern along the coherent paper/wash field. The
    // nearest-edge distance remains fixed so branches stay rooted to pigment.
    float travel = cellSize * 0.62f;
    float sourceX = px - flowX * travel;
    float sourceY = py - flowY * travel;
    float u = (sourceX * tangentX + sourceY * tangentY) / cellSize;
    float v = edgeDistance / cellSize;
    float warpX = (backrun_noise(seed ^ 0x9e3779b9u, u * 0.22f, v * 0.22f) - 0.5f) * 1.2f;
    float warpY = (backrun_noise(seed ^ 0x85ebca6bu, u * 0.22f + 17.3f, v * 0.22f - 9.1f) - 0.5f) * 1.0f;
    float field = backrun_fbm(seed, u * 0.52f + warpX, v * 0.64f + warpY) * 0.68f
        + backrun_noise(seed ^ 0x51ed270bu, u * 1.35f + warpX, v * 1.6f + warpY) * 0.22f
        + backrun_noise(seed ^ 0x68bc21ebu, u * 2.8f + warpX, v * 3.1f + warpY) * 0.10f;
    float ridge = 1 - fabsf(2 * field - 1);
    float interiorFade = expf(-edgeDistance / (cellSize * 2.2f));
    float pooledFade = expf(-edgeDistance / (cellSize * 0.48f));
    *core = backrun_smooth(0.56f, 0.84f, ridge) * interiorFade;
    *rim = backrun_smooth(0.66f, 0.92f, ridge) * pooledFade;
}

void brush_render_pixels(uint8_t *rgba, uint8_t *rim, uint8_t *gray, size_t count,
                         const float *density, const float *cap, const float *pigment, const float *edges,
                         float red, float green, float blue, float opacity, float burnt, float backruns,
                         int multiplyEdgeTint,
                         uint32_t seed, float cellSize, float originX, float originY,
                         float pixelXX, float pixelXY, float pixelYX, float pixelYY,
                         size_t width, float threshold, const float *edgeDistance) {
    const float foreground[] = {red, green, blue};
    for (size_t i = 0; i < count; ++i) {
        float a = fminf(1 - expf(-density[i]), cap ? cap[i] : 1) * opacity;
        float px = originX + (float)(i % width) * pixelXX + (float)(i / width) * pixelYX;
        float py = originY + (float)(i % width) * pixelXY + (float)(i / width) * pixelYY;
        float bloomRim = 0;
        if (backruns > 0 && cellSize > 0 && width > 0 && a > 0) {
            float outX = 0, outY = 0;
            size_t height = count / width;
            float distance = backrun_edge_distance(density, cap, opacity, width, height, i, a, cellSize, &outX, &outY);
            if (distance >= 0) {
                float core;
                backrun_field(seed, cellSize, (int32_t)px, (int32_t)py,
                              distance, outX, outY, &core, &bloomRim);
                // Preserve the wash body; blooms should perturb pigment, not punch holes in it.
                a *= 1 - fminf(0.28f, backruns * 0.24f * core);
            }
        }
        if (threshold >= 0) a = a > 0 && a >= threshold ? 1 : 0;
        uint8_t alpha = (uint8_t)roundf(fminf(1, fmaxf(0, a)) * 255);
        if (gray) gray[i] = alpha;
        if (!rgba) continue;
        float edgeAlpha = edges ? burnt * (1 - expf(-edges[i])) * a : 0;
        float settledEdgeAlpha = 0;
        if (burnt > 0 && edgeDistance && a > 0) {
            float d = edgeDistance[i];
            float worldX = px * 0.071f;
            float worldY = py * 0.071f;
            float spikeNoise = 0.5f + (backrun_fbm(seed ^ 0xA77E31u, worldX, worldY) - 0.5f) * 1.7f;
            spikeNoise = fminf(1, fmaxf(0, spikeNoise));
            float reach = 2.5f + fminf(20, fmaxf(4, d * 0.38f)) * powf(spikeNoise, 2.8f);
            float t = fminf(1, fmaxf(0, (reach - d) / 5.5f));
            t = t * t * (3 - 2 * t);
            float maxReach = fminf(20, fmaxf(4, d * 0.38f));
            float falloff = expf(-d / (2.8f + maxReach * 0.3f));
            float pool = fminf(1, fmaxf(0, 0.54f * expf(-fmaxf(0, d - 1) / 2.8f)
                + t * falloff * (0.35f + 0.55f * powf(spikeNoise, 1.5f)) * 0.8f));
            float accumulated = edges ? 0.45f + 0.55f * (1 - expf(-edges[i])) : 1;
            settledEdgeAlpha = burnt * pool * accumulated * 0.9f;
            if (!multiplyEdgeTint) edgeAlpha = fmaxf(edgeAlpha, settledEdgeAlpha);
        }
        edgeAlpha = fminf(1, edgeAlpha + backruns * bloomRim * 0.78f * a);
        float outputAlpha = a;
        for (int c = 0; c < 3; ++c) {
            float color = pigment && density[i] > 0 ? pigment[3 * i + c] / density[i] : foreground[c];
            color = fminf(1, fmaxf(0, color));
            float pooledColor = color * (1 - backruns * bloomRim * 0.56f);
            if (multiplyEdgeTint && outputAlpha > 0) {
                float edgeMix = fminf(1, settledEdgeAlpha / fmaxf(outputAlpha, 0.01f));
                pooledColor *= 1 - 0.95f * edgeMix;
            }
            rgba[4 * i + c] = (uint8_t)roundf(pooledColor * outputAlpha * 255);
            if (rim) rim[4 * i + c] = (uint8_t)roundf(color * 0.4f * edgeAlpha * 255);
        }
        rgba[4 * i + 3] = (uint8_t)roundf(fminf(1, outputAlpha) * 255);
        if (rim) rim[4 * i + 3] = (uint8_t)roundf(edgeAlpha * 255);
    }
}
