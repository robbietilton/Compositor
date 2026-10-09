#ifndef DitherPixels_h
#define DitherPixels_h
#include <stdint.h>
#include <stddef.h>

// The dither styles, in the order the Filter panel lists them.
enum {
    DITHER_ATKINSON, DITHER_FLOYD_STEINBERG,
    DITHER_BAYER_2, DITHER_BAYER_4, DITHER_BAYER_8,
    DITHER_DOTS, DITHER_LINES, DITHER_DIAMONDS,
    DITHER_PATTERNS, DITHER_GLYPHS
};

typedef struct {
    int style;
    // Tones per channel for diffusion and ordered styles, 2–8. Two is pure 1-bit.
    int levels;
    // How much of each pixel's error diffusion passes on, 0–1.
    float diffusion;
    // −1…1: darker (more ink) or lighter, and flatter or punchier, before dithering.
    float density;
    float contrast;
    // Halftone and glyph cells, in pixels, and the halftone screen's angle in radians.
    int cell;
    float angle;
    // Halftone dots, patterns and glyphs mark the light tones on the dark color instead of the dark on the light.
    int lightOnDark;
    // 0: the result is made of `dark` and `light` (straight sRGB). 1: it keeps the image's own colors.
    int originalColors;
    uint8_t dark[3];
    uint8_t light[3];
    // Glyphs: `glyphCount` coverage maps of `glyphWidth` × `glyphHeight` bytes (255 is fully inked), from least
    // inked to most, with each map's mean coverage (0–1) in `glyphCoverage`. The image is laid out in cells that size,
    // like lines of monospaced text.
    int glyphWidth;
    int glyphHeight;
    const uint8_t *glyphs;
    const float *glyphCoverage;
    int glyphCount;
} DitherParams;

// Filter › Scanlines: the picture as a CRT draws it, in lines of light on a dark screen.
typedef struct {
    // Pixels from one line to the next.
    int spacing;
    // How much of the gap a full-bright line fills, 0–1; dimmer parts draw it thinner.
    float thickness;
    // How far each line breaks into round dots, 0–1.
    float dots;
    // Pixels a line wavers sideways, in a wave down the screen.
    float wobble;
    // Pixels a line rises where the picture under it is bright, so lines ripple into the picture's shapes.
    float displace;
    // 0–1: tones darker than this draw no line at all.
    float threshold;
    // Pixels the red and blue are moved apart, either way, for colored fringes.
    float split;
    // −1…1: darker or lighter, and flatter or punchier, before the lines are drawn.
    float density;
    float contrast;
    // 0: lines of `light` on `dark` (straight sRGB), brighter where the picture is. 1: lines in the picture's colors.
    int originalColors;
    uint8_t dark[3];
    uint8_t light[3];
} ScanlinesParams;

// Draws premultiplied RGBA pixels (4 bytes per pixel, `stride` bytes per row) as scanlines, in place. Alpha is kept and
// fully transparent pixels are left alone. Returns 0 if working memory couldn't be had.
int scanlines_apply(uint8_t *rgba, size_t width, size_t height, size_t stride, const ScanlinesParams *params);

// Dithers premultiplied RGBA pixels (4 bytes per pixel, `stride` bytes per row) in place. Alpha is kept and fully
// transparent pixels are left alone. Returns 0 if working memory couldn't be had.
int dither_apply(uint8_t *rgba, size_t width, size_t height, size_t stride, const DitherParams *params);
// Turns each `block` × `block` square of premultiplied RGBA pixels into a round dot in its own color on `gap` (straight
// sRGB), like the lit pixels of a dot-matrix screen. The dot's edge is smoothed and alpha is kept.
void dither_dots(uint8_t *rgba, size_t width, size_t height, size_t stride, int block, const uint8_t *gap);
// Adds `glow` (premultiplied RGBA, same layout) over the pixels at `amount`, never past their own alpha.
void dither_glow(uint8_t *rgba, const uint8_t *glow, size_t width, size_t height, size_t stride, float amount);
// Rounds 16-bit premultiplied RGBA (`width` × `height`, tightly packed) to 8 bits into `rgba` (`stride` bytes per
// row), adding noise of about one 8-bit step first so smooth gradients don't come out in steps. The noise is fixed per
// pixel, so the same input always gives the same output.
void dither_quantize16(const uint16_t *wide, uint8_t *rgba, size_t width, size_t height, size_t stride);
#endif
