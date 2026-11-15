#ifndef BrushPixels_h
#define BrushPixels_h
#include <stdint.h>
#include <stddef.h>
// Half-open bounds of nonzero alpha in premultiplied RGBA. Empty returns all zero.
void brush_alpha_bounds(const uint8_t *bytes, size_t width, size_t height, size_t stride, size_t bounds[4]);
void layer_extract_alpha(const uint8_t *rgba, size_t rgbaStride, uint8_t *gray, size_t grayStride, size_t width, size_t height);
void layer_unpremultiply_opaque(uint8_t *rgba, size_t stride, size_t width, size_t height);
void layer_restore_alpha(uint8_t *rgba, size_t stride, const uint8_t *alpha, size_t alphaStride, size_t width, size_t height);
void brush_density_bytes(uint8_t *gray, size_t stride, const float *density, const float *cap, size_t width, size_t height);
double brush_tip_falloff(double u);
void brush_round_stamp(float *density, float *cap, size_t width,
                       size_t x0, size_t y0, size_t x1, size_t y1,
                       float u0, float v0, float ux, float uy, float vx, float vy,
                       float hardness, float flow, float strength, const uint8_t *tipMask, size_t side, int filtering);
void brush_render_stamp(float *density, float *cap, float *pigment, float *edges, size_t width,
                       size_t x0, size_t y0, size_t x1, size_t y1,
                       float u0, float v0, float ux, float uy, float vx, float vy,
                       float hardness, float flow, float strength, const uint8_t *tipMask, size_t side, int filtering,
                       int mode, float wet, float red, float green, float blue, const uint8_t *second, size_t secondSide, float scale, int classic, const uint8_t *grain, size_t grainSide, const double *g);
void brush_render_pixels(uint8_t *rgba, uint8_t *rim, uint8_t *gray, size_t count,
                         const float *density, const float *cap, const float *pigment, const float *edges,
                         float red, float green, float blue, float opacity, float burnt, float backruns,
                         int multiplyEdgeTint,
                         uint32_t seed, float cellSize, float originX, float originY,
                         float pixelXX, float pixelXY, float pixelYX, float pixelYY,
                         size_t width, float threshold, const float *edgeDistance);
void brush_edge_distance(float *destination, size_t width, size_t height,
                         const float *coverage, size_t sourceWidth, size_t sourceHeight,
                         size_t offsetX, size_t offsetY);
void brush_watercolor_wash(uint8_t *rgba, size_t stride, size_t width, size_t height,
                           const float *coverage, size_t sourceWidth, size_t sourceHeight,
                           size_t offsetX, size_t offsetY, uint32_t seed, float wetness,
                           float red, float green, float blue, float originX, float originY);
#endif
