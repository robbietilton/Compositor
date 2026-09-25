#ifndef NoisePixels_h
#define NoisePixels_h
#include <stdint.h>
#include <stddef.h>
// Adds noise to the color of premultiplied RGBA pixels (4 bytes per pixel, `stride` bytes per
// row), leaving alpha untouched and fully transparent pixels alone. `amount` is Photoshop's
// percentage: uniform noise spans ±amount% of half the range, Gaussian noise has a standard
// deviation of two thirds of that. Monochromatic adds the same value to all three channels.
// Each pixel's noise depends only on its position and `seed`, so the same seed gives the same grain.
void noise_add(uint8_t *rgba, size_t width, size_t height, size_t stride,
               float amount, int gaussian, int monochromatic, uint32_t seed);
void noise_add_at(uint8_t *rgba, size_t width, size_t height, size_t stride,
                  float amount, int gaussian, int monochromatic, uint32_t seed,
                  int64_t origin_x, int64_t origin_y);
#endif
