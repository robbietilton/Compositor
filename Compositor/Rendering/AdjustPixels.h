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
// One step of Camera Raw: up to eight measured color tables (`size`³ sRGB colors, red slowest, 3 bytes each) blended
// by weight, for settings between the ones measured. A null table is no change.
typedef struct {
    const uint8_t *table[8];
    float weight[8];
} CameraRawStage;
// Runs `count` stages in order over a `grid`³ lattice of sRGB colors into `out` (3 floats per color, 0…1, red
// slowest), so a whole run of stages costs a pixel one lookup.
void camera_raw_compose(float *out, int grid, const CameraRawStage *stages, int count, int size);
// Runs `count` stages over every entry of a composed table already made (3 floats a color), in place.
void camera_raw_compose_onto(float *table, int grid, const CameraRawStage *stages, int count, int size);
// Runs a composed table's colors through a tone curve, then each channel's curve (256 entries each), in place.
void camera_raw_table_curves(float *table, int grid, const float *toneLut, const float *redLut, const float *greenLut,
                             const float *blueLut);
// Camera Raw's histogram (256 bins each of red, green and blue, added into `bins`) and vectorscope (`side`² cells,
// added into `scope`) from every `step`th pixel each way, opaque ones counting by their alpha.
void camera_raw_scope(const uint8_t *rgba, size_t width, size_t height, size_t stride, int step, double *bins, double *scope,
                      int side);
// One stage on one sRGB color (0…1), in place.
void camera_raw_stage_color(const CameraRawStage *stage, int size, double *rgb);
// What Camera Raw's adaptive sliders read from an image, as sRGB levels (0…1), opaque pixels counting by their
// alpha: the mean of each pixel's brightest channel in linear light (Contrast), the mean linear luminance (Shadows),
// and the log-average of the brightest channel (Highlights).
void camera_raw_statistics(const uint8_t *rgba, size_t width, size_t height, size_t stride, double *out);
// Camera Raw's Light and Color groups on premultiplied RGBA pixels, through one composed table (null for none).
// `clipping` 0 renders the grade; 1 replaces it with a highlight-clip view (clipped channels lit on black); 2 replaces
// it with a shadow-clip view (clipped channels dark on white). Alpha is kept.
void adjust_camera_raw(uint8_t *rgba, size_t width, size_t height, size_t stride, const float *table, int grid,
                       int clipping);
// The Metal lookup's supported table domain. The original CPU path handles other tables.
int camera_raw_lookup_is_valid(const float *table, int grid);
// Resolve GPU pixels near a rounding boundary with the original double-precision composed lookup.
void camera_raw_repair_lookup(uint8_t *result, const uint8_t *source, const uint8_t *uncertain,
                               size_t width, size_t height, size_t stride, const float *table, int grid);
// Camera Raw Effects after Light and Color. Texture is a fine local contrast, Clarity a broader one.
// Dehaze raises contrast and saturation when positive and lifts the shadows when negative. Glow, its
// range, spread and warmth do nothing until `glow` is above zero: styles are 0 diffusion, 1 bloom,
// 2 halation. Vignette styles are 0 highlight priority, 1 color priority, 2 paint overlay; Highlights
// protects bright pixels only while the amount darkens. `scale` is preview pixels per layer pixel, so
// the radii match a full-size render. Grain is applied separately. Alpha is kept.
// Blue over clipped shadows and red over clipped highlights, on top of the grade. Preview only.
// Camera Raw's Shadows, adapting to the picture region by region as Photoshop's does. `coefficients` are three planes
// (lift, gain above, gain below) of `kCount` rows by `xCount` columns; see AdjustPixels.c.
void adjust_camera_raw_shadows(uint8_t *rgba, size_t width, size_t height, size_t stride, const float *coefficients,
                               int xCount, float xLow, float xStep, int kCount, float kLow, float kStep);
void adjust_camera_raw_clip_overlay(uint8_t *rgba, size_t width, size_t height, size_t stride, int shadows, int highlights);
// Curve, Color Mixer, and Color Grading after the basic grade. `toneLut` and the channel LUTs are 256
// entries. `mixer` is 24 floats: hue, saturation, luminance for eight families, −1…1. Each point color is
// 9 floats (hue, saturation, luminance, three shifts −1…1, three range half-widths). `grade` is four wheels
// of hue turns, saturation 0…1, and luminance −1…1. `visualize` darkens pixels outside that point color.
// `mixerTable` and `gradeTable` (null for none) are the Color Mixer's and Color Grading's composed tables, `grid`³
// colors, run after the curve and before the grading formula.
void adjust_camera_raw_curve_color(uint8_t *rgba, size_t width, size_t height, size_t stride,
                                   const float *toneLut, const float *redLut, const float *greenLut, const float *blueLut,
                                   double refineSaturation, const float *mixer, int pointCount, const float *points,
                                   const float *grade, double blending, double balance, int visualize,
                                   const float *mixerTable, const float *gradeTable, int grid);
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
// Set by the app to run Luminance noise reduction's non-local means on the GPU (MetalNonlocalMeans): `luma` and
// `coverage` in, `out` the smoothed brightness, all width × height. Returns 0 to have it worked out here instead.
extern int (*adjust_nonlocal_means_gpu)(const float *luma, const float *coverage, float *out, size_t width, size_t height,
                                        int search, int patch, double h, double sigma);
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
                              double vignetteAmount, double vignetteMidpoint, double scale,
                              const uint8_t *exposureTables, int tableSize);
// Camera calibration before the main grade. Primary hue and saturation shifts are −100…100; shadow tint is green/magenta.
void adjust_camera_raw_calibration(uint8_t *rgba, size_t width, size_t height, size_t stride,
                                   double shadowTint, double redHue, double redSaturation,
                                   double greenHue, double greenSaturation, double blueHue, double blueSaturation,
                                   int processVersion);
#endif
