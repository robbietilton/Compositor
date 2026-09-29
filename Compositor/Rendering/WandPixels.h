#ifndef WandPixels_h
#define WandPixels_h
#include <stdint.h>
#include <stddef.h>
// Magic Wand match over premultiplied RGBA (4 bytes per pixel, `stride` bytes per row, rows
// top-down). The reference color is the average over a (2 * radius + 1)² square around the
// seed, clipped to the image. A pixel matches when every channel, alpha included, is within
// `tolerance` of it. Contiguous fills 4-connected from the seed (nothing when the seed itself
// doesn't match); otherwise every matching pixel. Writes 255 for selected, 0 elsewhere, into
// `mask` (width * height bytes). Returns the number selected, or -1 when memory runs out.
long wand_mask(const uint8_t *rgba, size_t width, size_t height, size_t stride,
               size_t seedX, size_t seedY, size_t radius, int tolerance, int contiguous, uint8_t *mask);
// Select > Color Range over premultiplied RGBA (as above). A pixel matches when every color channel is within
// `fuzziness` of one of the `includeCount` colors in `include` and of none in `exclude` (straight sRGB, 3 bytes
// each). Transparent pixels never match. With `invert`, the pixels that don't match are selected instead. Writes
// 255 for selected, 0 elsewhere, into `mask`, and returns the number selected.
long color_range_mask(const uint8_t *rgba, size_t width, size_t height, size_t stride,
                      const uint8_t *include, int includeCount, const uint8_t *exclude, int excludeCount,
                      int fuzziness, int invert, uint8_t *mask);
// Outline of the nonzero pixels of `mask`, along pixel edges, as closed loops of corner points
// (x, y pairs in pixel-edge coordinates). Outer boundaries run clockwise and holes
// counterclockwise in top-left coordinates, so the winding rule fills exactly those pixels.
// `points` receives 2 * pointCount values and `loops` each loop's corner count; both are
// malloc'd and must be freed. Returns 0 on success, -1 when memory runs out, and -2 when the
// outline is too detailed to be worth drawing.
int wand_trace(const uint8_t *mask, size_t width, size_t height,
               int32_t **points, size_t *pointCount, int32_t **loops, size_t *loopCount);
#endif
