#ifndef FinishPixels_h
#define FinishPixels_h
#include <stdint.h>
#include <stddef.h>
// In-place, premultiplied RGBA8. Alpha and padding are preserved. Returns 0 on invalid input or allocation failure.
// kind: tonal contrast, ink, pro contrast, detail extractor, bloom, warmth, vignette, then the photo realism
// effects: sensor grain, micro texture, highlight rolloff (highlights = halation), chromatic aberration,
// lens softness. amount and tone weights: 0...1; saturation and warmth: -1...1; radius: pixels (grain size,
// texture scale, halation radius, fringe width at the corners, softness radius). seed: the grain pattern.
typedef struct {
    int kind;
    float amount, shadows, midtones, highlights, radius, saturation;
    int palette, contrast_type;
    float protect_shadows, protect_highlights;
    uint32_t seed;
} FinishEffectSettings;

// Several effects in order, sharing one set of working planes. The pixels are a crop starting at
// (offset_x, offset_y) inside a full_width × full_height image, so position-dependent effects
// (Vignette) match the whole image; pass the pixels' own size and zero offsets otherwise.
int finish_apply_stack(uint8_t *rgba, size_t width, size_t height, size_t stride,
                       size_t full_width, size_t full_height, size_t offset_x, size_t offset_y,
                       const FinishEffectSettings *effects, size_t count);
int finish_apply(uint8_t *rgba, size_t width, size_t height, size_t stride,
                 int kind, float amount, float shadows, float midtones, float highlights,
                 float radius, float saturation, int palette, int contrast_type,
                 float protect_shadows, float protect_highlights);
int finish_apply_region(uint8_t *rgba, size_t width, size_t height, size_t stride,
                        size_t full_width, size_t full_height, size_t offset_x, size_t offset_y,
                        int kind, float amount, float shadows, float midtones, float highlights,
                        float radius, float saturation, int palette, int contrast_type,
                        float protect_shadows, float protect_highlights);
#endif
