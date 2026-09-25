#ifndef AdjustPixels_h
#define AdjustPixels_h
#include <stdint.h>
#include <stddef.h>
// Gradient Map on premultiplied RGBA pixels (4 bytes per pixel, `stride` bytes per row): each pixel's
// luminance picks a color from `table` (256 × 3 straight sRGB bytes, darkest first). Alpha is kept and
// fully transparent pixels are left alone.
void adjust_gradient_map(uint8_t *rgba, size_t width, size_t height, size_t stride, const uint8_t *table);
// Film grain on premultiplied RGBA pixels: the same brightness change on all three channels, strongest
// in the midtones. `amount` is 0–100, `size` the grain's scale in document units, and `roughness`
// (0–100) adds smaller irregular particles whose scale remains relative to `size`. Pixel (x, y) sits at (originX + (x + 0.5) × unitsPerPixel,
// originY + (y + 0.5) × unitsPerPixel), and its grain depends only on that position and `seed`, so a
// piece of an image gets the same grain as that part of the whole.
void adjust_grain(uint8_t *rgba, size_t width, size_t height, size_t stride, double amount, double size,
                  double roughness, uint32_t seed, double originX, double originY, double unitsPerPixel);
// Black & White on premultiplied RGBA pixels, the way Photoshop's is: a color is split into the gray
// it contains, the secondary (cyan/magenta/yellow) between its two brightest channels, and the primary
// (red/green/blue) of its brightest, and each of those six ranges has its own weight. `weights` is six
// floats in the order red, yellow, green, cyan, blue, magenta, as fractions (Photoshop's 40% is 0.4).
// Pure red at the default 40% comes out 40% gray, as it does there. With `tint`, the result is colored
// at `tintHue` degrees and `tintSaturation` (0–1) while keeping that gray as its lightness.
void adjust_black_white(uint8_t *rgba, size_t width, size_t height, size_t stride, const float *weights,
                        int tint, double tintHue, double tintSaturation);
// Color Balance on premultiplied RGBA pixels. `shadows`, `midtones` and `highlights` are each three
// floats — cyan/red, magenta/green, yellow/blue — from -1 to 1 (Photoshop's -100 to 100). Each pixel is
// shifted by however much it belongs to each tonal range, and with `preserveLuminosity` its original
// brightness is put back afterwards, so only the color moves.
void adjust_color_balance(uint8_t *rgba, size_t width, size_t height, size_t stride, const float *shadows,
                          const float *midtones, const float *highlights, int preserveLuminosity);
// After resampling with a filter that rings (Lanczos), premultiplied RGBA colors can exceed their alpha;
// this clamps each channel back to its pixel's alpha. `count` is the number of pixels.
void rgba_clamp_premultiplied(uint8_t *rgba, size_t count);
// Camera Raw's Light and Color groups on premultiplied RGBA pixels, in this order: white balance
// (the three channel gains), exposure in stops of linear light, contrast about mid gray, highlights,
// shadows, whites, blacks, vibrance, then saturation. Temperature and tint are relative, so the gains
// are computed by the caller. Amounts are Camera Raw's own ranges (exposure −5…5, the rest −100…100).
// `clipping` 0 renders the grade; 1 replaces it with a highlight-clip view (clipped channels lit on
// black); 2 replaces it with a shadow-clip view (clipped channels dark on white). Alpha is kept.
void adjust_camera_raw(uint8_t *rgba, size_t width, size_t height, size_t stride,
                       double redGain, double greenGain, double blueGain, double exposure, double contrast,
                       double highlights, double shadows, double whites, double blacks,
                       double vibrance, double saturation, int clipping);
// Camera Raw Effects after Light and Color. Texture is a fine local contrast, Clarity a broader one.
// Dehaze raises contrast and saturation when positive and lifts the shadows when negative. Glow, its
// range, spread and warmth do nothing until `glow` is above zero: styles are 0 diffusion, 1 bloom,
// 2 halation. Vignette styles are 0 highlight priority, 1 color priority, 2 paint overlay; Highlights
// protects bright pixels only while the amount darkens. `scale` is preview pixels per layer pixel, so
// the radii match a full-size render. Grain is applied separately. Alpha is kept.
// Blue over clipped shadows and red over clipped highlights, on top of the grade. Preview only.
void adjust_camera_raw_clip_overlay(uint8_t *rgba, size_t width, size_t height, size_t stride, int shadows, int highlights);
// Curve, Color Mixer, and Color Grading after the basic grade. `lumaLut` and the channel LUTs are 256
// entries. `mixer` is 24 floats: hue, saturation, luminance for eight families, −1…1. Each point color is
// 9 floats (hue, saturation, luminance, three shifts −1…1, three range half-widths). `grade` is four wheels
// of hue turns, saturation 0…1, and luminance −1…1. `visualize` darkens pixels outside that point color.
void adjust_camera_raw_curve_color(uint8_t *rgba, size_t width, size_t height, size_t stride,
                                   const float *lumaLut, const float *redLut, const float *greenLut, const float *blueLut,
                                   double refineSaturation, const float *mixer, int pointCount, const float *points,
                                   const float *grade, double blending, double balance, int visualize);
void adjust_camera_raw_effects(uint8_t *rgba, size_t width, size_t height, size_t stride,
                               double texture, double clarity, double dehaze,
                               double glow, int glowStyle, double glowRange, double glowSpread, double glowWarmth,
                               double vignetteAmount, double vignetteMidpoint, double vignetteRoundness,
                               double vignetteFeather, double vignetteHighlights, int vignetteStyle,
                               double scale);
// Standalone Vignette: blends straight sRGB toward the selected edge color using Camera Raw's
// falloff shape and Highlight Priority. Preserves the source alpha and premultiplied storage.
// The vignette is shaped to the frame (in the image's pixels). With fillsClear it paints transparent pixels too;
// without, it recolors only the pixels that are there.
void adjust_colored_vignette(uint8_t *rgba, size_t width, size_t height, size_t stride,
                             double frameX, double frameY, double frameWidth, double frameHeight, int fillsClear,
                             double amount, double midpoint, double roundness, double feather,
                             double highlights, double red, double green, double blue);
// Local luminance contrast with independent shadow, midtone, and highlight gains.
// `blurred` is the same premultiplied RGBA image blurred at the chosen detail radius.
void adjust_tonal_contrast(uint8_t *rgba, const uint8_t *blurred, size_t width, size_t height,
                           size_t stride, size_t blurredStride, double amount,
                           double shadows, double midtones, double highlights);
// Manual noise reduction, then sharpening. `scale` maps radius to preview pixels. Applied after the creative grade.
void adjust_camera_raw_detail(uint8_t *rgba, size_t width, size_t height, size_t stride,
                              double sharpenAmount, double sharpenRadius, double sharpenDetail, double sharpenMasking,
                              double noiseLuminance, double noiseLuminanceDetail, double noiseLuminanceContrast,
                              double noiseColor, double noiseColorDetail, double noiseColorSmoothness, double scale);
// Preview only: white where sharpening would land, black where masking protects. Uses the current sharpen sliders.
void adjust_camera_raw_sharpen_mask_overlay(uint8_t *rgba, size_t width, size_t height, size_t stride,
                                            double sharpenRadius, double sharpenDetail, double sharpenMasking, double scale);
// Chromatic aberration, lens distortion, defringe, and lens-vignetting correction. `distortionK` matches `lens_distort`.
void adjust_camera_raw_optics(uint8_t *rgba, size_t width, size_t height, size_t stride,
                              int removeChromatic, int lensProfile, double profileDistortion, double profileVignetting,
                              double distortionK, double purpleAmount, double purpleHueLow, double purpleHueHigh,
                              double greenAmount, double greenHueLow, double greenHueHigh,
                              double vignetteAmount, double vignetteMidpoint, double scale);
// Camera calibration before the main grade. Primary hue and saturation shifts are −100…100; shadow tint is green/magenta.
void adjust_camera_raw_calibration(uint8_t *rgba, size_t width, size_t height, size_t stride,
                                   double shadowTint, double redHue, double redSaturation,
                                   double greenHue, double greenSaturation, double blueHue, double blueSaturation,
                                   int processVersion);
#endif
