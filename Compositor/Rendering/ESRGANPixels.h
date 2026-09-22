#ifndef ESRGANPixels_h
#define ESRGANPixels_h
#include <stdint.h>
#include <stddef.h>
// Pixel packing around AI Upscale's network tiles, kept in C so it stays fast in unoptimized builds.
// RGBA8 buffers are premultiplied; planar buffers hold R, G then B planes of floats in 0...1.

// Whether every pixel's alpha is 255.
int esrgan_is_opaque(const uint8_t *rgba, size_t stride, size_t width, size_t height);
// The tile × tile window whose top-left is (left, top) — which may lie outside the image — with edge pixels
// repeated, as unpremultiplied planar RGB.
void esrgan_fill_tile(const uint8_t *rgba, size_t stride, size_t width, size_t height,
                      long left, long top, size_t tile, float *planar);
// Writes the kept middle of a 4× result (planar, size × size) as opaque pixels at (x, y) of the output:
// keep_width × keep_height source pixels become factor × factor pixels each, starting `margin` result pixels
// in; for factor 2 each 2 × 2 block of the result is averaged.
void esrgan_store_tile(const float *planar, size_t size, size_t margin, size_t keep_width, size_t keep_height,
                       size_t factor, uint8_t *rgba, size_t stride, size_t x, size_t y);
// Premultiplies each pixel's color by `alpha` (one byte per pixel) and makes that its alpha.
void esrgan_apply_alpha(uint8_t *rgba, size_t stride, const uint8_t *alpha, size_t alpha_stride,
                        size_t width, size_t height);
#endif
