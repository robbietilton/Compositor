#ifndef BrushPixels_h
#define BrushPixels_h
#include <stdint.h>
#include <stddef.h>
// Half-open bounds of nonzero alpha in premultiplied RGBA. Empty returns all zero.
void brush_alpha_bounds(const uint8_t *bytes, size_t width, size_t height, size_t stride, size_t bounds[4]);
void layer_extract_alpha(const uint8_t *rgba, size_t rgbaStride, uint8_t *gray, size_t grayStride, size_t width, size_t height);
void layer_unpremultiply_opaque(uint8_t *rgba, size_t stride, size_t width, size_t height);
void layer_restore_alpha(uint8_t *rgba, size_t stride, const uint8_t *alpha, size_t alphaStride, size_t width, size_t height);
// Dodge (lightens) or Burn: each pixel's straight color moved toward white or black by `strength` (0–1) times a
// smooth weight for its brightness in `range` (0 shadows, 1 midtones, 2 highlights). Alpha is left as it is, so
// transparent pixels stay transparent. Premultiplied RGBA, in place.
void brush_tone(uint8_t *rgba, size_t width, size_t height, size_t stride, int lightens, int range, double strength);
#endif
