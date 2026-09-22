#include "ESRGANPixels.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    // 3 × 2 image with padding: premultiplied, one half-transparent and one transparent pixel.
    enum { W = 3, H = 2, STRIDE = W * 4 + 4 };
    uint8_t image[H * STRIDE];
    memset(image, 99, sizeof(image));
    uint8_t pixels[H][W][4] = {{{255, 0, 0, 255}, {50, 100, 0, 128}, {0, 0, 0, 0}},
                               {{0, 0, 255, 255}, {10, 20, 30, 255}, {255, 255, 255, 255}}};
    for (int y = 0; y < H; ++y) memcpy(image + y * STRIDE, pixels[y], W * 4);
    assert(!esrgan_is_opaque(image, STRIDE, W, H));
    uint8_t solid[4] = {1, 2, 3, 255};
    assert(esrgan_is_opaque(solid, 4, 1, 1));

    // A 4 × 4 tile starting one pixel up-left of the image repeats its edges and unpremultiplies.
    float planar[3 * 16];
    esrgan_fill_tile(image, STRIDE, W, H, -1, -1, 4, planar);
    assert(planar[0] == 1 && planar[16] == 0 && planar[32] == 0);          // (-1,-1) repeats (0,0), red
    assert(fabsf(planar[1 * 4 + 2] - 50.f / 128) < 1e-6f);               // (1,0) sits at tile (2,1), unpremultiplied
    assert(planar[1 * 4 + 3] == 0 && planar[16 + 1 * 4 + 3] == 0);        // transparent pixel has no color
    assert(planar[3 * 4 + 0] == 0 && planar[32 + 3 * 4 + 0] == 1);       // (-1, 2) repeats (0, 1), blue

    // Storing a flat 4× result: 2× averages to the same value, and alpha is opaque.
    enum { SIZE = 8, ROW = 8 * 4 };                                      // output rows of 8 pixels
    float result[3 * SIZE * SIZE];
    for (int i = 0; i < 3 * SIZE * SIZE; ++i) result[i] = i < SIZE * SIZE ? .5f : i < 2 * SIZE * SIZE ? 1 : 0;
    uint8_t target[ROW * 4];
    memset(target, 7, sizeof(target));
    esrgan_store_tile(result, SIZE, 0, 2, 2, 2, target, ROW, 0, 0);
    for (int y = 0; y < 4; ++y) for (int x = 0; x < 4; ++x) {
        const uint8_t *p = target + y * ROW + x * 4;
        assert(p[0] == 128 && p[1] == 255 && p[2] == 0 && p[3] == 255);
    }
    assert(target[4 * 4] == 7 && target[3 * ROW + 7 * 4 + 3] == 7);   // beyond the kept area: untouched

    // Alpha is applied as premultiplication.
    uint8_t color[2 * 4] = {200, 100, 50, 255, 255, 255, 255, 255}, alpha[2] = {128, 0};
    esrgan_apply_alpha(color, 8, alpha, 2, 2, 1);
    assert(color[0] == 100 && color[1] == 50 && color[2] == 25 && color[3] == 128);
    assert(color[4] == 0 && color[7] == 0);
    puts("AI Upscale pixels: opacity, edge repeat, unpremultiply, 2× averaging and alpha passed.");
}
