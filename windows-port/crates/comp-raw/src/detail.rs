//! Manual noise reduction and sharpening, the Detail panel.
//!
//! Ported from `adjust_camera_raw_detail` and `sharpen_edge_at` in AdjustPixels.c. The order inside the
//! kernel matters: luminance noise reduction, then color noise reduction, then sharpening.

use crate::blur::{box_blur_plane, detail_radius, effects_radius};
use crate::math::{camera_clamp, hsl_to_rgb, rgb_to_hsl, scale_luminance};
use crate::raster::Raster;
use crate::settings::RawDetailSettings;

pub(crate) fn apply_detail(raster: &mut Raster, detail: &RawDetailSettings, scale: f64) {
    let width = raster.width;
    let height = raster.height;
    if width == 0 || height == 0 {
        return;
    }
    if detail.sharpen_amount == 0.0 && detail.noise_luminance == 0.0 && detail.noise_color == 0.0 {
        return;
    }
    let count = raster.len();
    let mut luma = raster.luma_plane();
    let mut work = vec![0f32; count];
    if detail.noise_luminance > 0.0 {
        let radius = effects_radius(1.0 + detail.noise_luminance / 50.0, scale);
        box_blur_plane(&luma, &mut work, width, height, radius);
        let strength = detail.noise_luminance / 100.0;
        let preserve = detail.noise_luminance_detail / 100.0;
        let contrast = detail.noise_luminance_contrast / 100.0;
        for y in 0..height {
            for x in 0..width {
                let index = raster.index(x, y);
                if raster.alpha[index] == 0 {
                    continue;
                }
                let edge = sharpen_edge_at(&luma, width, height, x, y, 1);
                // Detail preserves edges: the more contrast a pixel sits on, the less it is smoothed.
                let local = strength * (1.0 - preserve * (edge as f64 * 6.0).min(1.0));
                let blurred = work[index];
                let mut target = luma[index] * (1.0 - local as f32) + blurred * local as f32;
                if contrast != 0.0 {
                    target += (contrast * 0.25 * (luma[index] - blurred) as f64) as f32;
                }
                luma[index] = target;
                let mut color = raster.rgb[index];
                scale_luminance(&mut color, target as f64);
                raster.rgb[index] = color;
            }
        }
    }
    if detail.noise_color > 0.0 {
        let radius = effects_radius(1.0 + detail.noise_color_smoothness / 40.0, scale);
        let mut chroma = vec![0f32; count];
        for (index, color) in raster.rgb.iter().enumerate() {
            if raster.alpha[index] == 0 {
                continue;
            }
            let (_, saturation, _) = rgb_to_hsl(color[0], color[1], color[2]);
            chroma[index] = saturation as f32;
        }
        let mut blurred = vec![0f32; count];
        box_blur_plane(&chroma, &mut blurred, width, height, radius);
        let strength = detail.noise_color / 100.0;
        let preserve = detail.noise_color_detail / 100.0;
        for y in 0..height {
            for x in 0..width {
                let index = raster.index(x, y);
                if raster.alpha[index] == 0 {
                    continue;
                }
                let edge = (chroma[index] - blurred[index]).abs() as f64;
                let local = strength * (1.0 - preserve * (edge * 4.0).min(1.0));
                let saturation = chroma[index] as f64 * (1.0 - local) + blurred[index] as f64 * local;
                let color = raster.rgb[index];
                let (hue, _, lightness) = rgb_to_hsl(color[0], color[1], color[2]);
                raster.rgb[index] = hsl_to_rgb(hue, saturation, lightness);
            }
        }
    }
    if detail.sharpen_amount > 0.0 {
        // Sharpening reads the image as it stands now, so it sharpens what the noise pass left.
        luma = raster.luma_plane();
        let radius = effects_radius(detail_radius(detail.sharpen_radius, scale), 1.0);
        box_blur_plane(&luma, &mut work, width, height, radius);
        let amount = detail.sharpen_amount / 100.0;
        let detail_mix = detail.sharpen_detail / 100.0;
        let threshold = (detail.sharpen_masking / 100.0) * 0.35;
        let softness = (0.35 - threshold * 0.5).max(0.04);
        for y in 0..height {
            for x in 0..width {
                let index = raster.index(x, y);
                if raster.alpha[index] == 0 {
                    continue;
                }
                let edge = sharpen_edge_at(&luma, width, height, x, y, radius) as f64;
                let mask = camera_clamp((edge * (0.5 + detail_mix) - threshold) / softness);
                let high = luma[index] as f64 - work[index] as f64;
                let sharpened = camera_clamp(luma[index] as f64 + high * amount * mask * (0.5 + detail_mix));
                let mut color = raster.rgb[index];
                scale_luminance(&mut color, sharpened);
                raster.rgb[index] = color;
            }
        }
    }
}

/// The mean absolute difference between one pixel and its neighbors `radius` away: how much of an
/// edge the pixel sits on. Ported from `sharpen_edge_at`.
pub(crate) fn sharpen_edge_at(luma: &[f32], width: usize, height: usize, x: usize, y: usize, radius: i64) -> f32 {
    let radius = radius.max(1);
    let center = luma[y * width + x];
    let mut sum = 0.0f32;
    let mut count = 0i32;
    for dy in [-radius, 0, radius] {
        for dx in [-radius, 0, radius] {
            if dx == 0 && dy == 0 {
                continue;
            }
            let sx = x as i64 + dx;
            let sy = y as i64 + dy;
            if sx < 0 || sy < 0 || sx as usize >= width || sy as usize >= height {
                continue;
            }
            sum += (luma[sy as usize * width + sx as usize] - center).abs();
            count += 1;
        }
    }
    if count > 0 {
        sum / count as f32
    } else {
        0.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{RawDetailSettings, RawSettings};
    use comp_core::Bitmap8;

    /// A step edge down the middle plus one noisy patch, for sharpening and noise reduction.
    fn edge_image() -> Bitmap8 {
        let mut image = Bitmap8::filled(8, 8, [40, 40, 40, 255]);
        for y in 0..8 {
            for x in 4..8 {
                image.set(x, y, [210, 210, 210, 255]);
            }
        }
        image
    }

    fn noisy_image() -> Bitmap8 {
        let mut image = Bitmap8::filled(8, 8, [128, 128, 128, 255]);
        for y in 0..8 {
            for x in 0..8 {
                let offset = if (x + y) % 2 == 0 { 40 } else { 0 };
                image.set(x, y, [128 + offset, 128 + offset, 128 + offset, 255]);
            }
        }
        image
    }

    fn developed(image: &Bitmap8, detail: RawDetailSettings) -> Bitmap8 {
        let settings = RawSettings { detail, ..RawSettings::default() };
        crate::develop(image, &settings)
    }

    fn spread(image: &Bitmap8) -> f64 {
        let mut low = 255.0f64;
        let mut high = 0.0f64;
        for pixel in image.pixels().chunks_exact(4) {
            let value = pixel[0] as f64;
            low = low.min(value);
            high = high.max(value);
        }
        high - low
    }

    #[test]
    fn neutral_detail_is_identity() {
        assert_eq!(developed(&edge_image(), RawDetailSettings::default()), edge_image());
    }

    #[test]
    fn sharpening_widens_the_step_edge() {
        let sharpened = developed(&edge_image(), RawDetailSettings { sharpen_amount: 120.0, ..RawDetailSettings::default() });
        assert_ne!(sharpened, edge_image());
        // The dark side of the edge gets darker and the bright side brighter.
        assert!(sharpened.get(3, 3)[0] <= edge_image().get(3, 3)[0]);
        assert!(sharpened.get(4, 3)[0] >= edge_image().get(4, 3)[0]);
    }

    #[test]
    fn masking_protects_flat_areas() {
        let unmasked = developed(&edge_image(), RawDetailSettings { sharpen_amount: 120.0, ..RawDetailSettings::default() });
        let masked = developed(
            &edge_image(),
            RawDetailSettings { sharpen_amount: 120.0, sharpen_masking: 100.0, ..RawDetailSettings::default() },
        );
        // A flat corner is barely touched with masking, and the edge itself is still worked on.
        let flat_plain = (unmasked.get(0, 0)[0] as i32 - 40).abs();
        let flat_masked = (masked.get(0, 0)[0] as i32 - 40).abs();
        assert!(flat_masked <= flat_plain, "masking must not add work in flat areas");
    }

    #[test]
    fn luminance_noise_reduction_flattens_the_checkerboard() {
        let noisy = noisy_image();
        let reduced = developed(&noisy, RawDetailSettings { noise_luminance: 100.0, ..RawDetailSettings::default() });
        assert!(spread(&reduced) < spread(&noisy), "{} vs {}", spread(&reduced), spread(&noisy));
    }

    #[test]
    fn color_noise_reduction_pulls_chroma_out() {
        let mut image = Bitmap8::filled(6, 6, [130, 120, 110, 255]);
        for y in 0..6 {
            for x in 0..6 {
                if (x + y) % 2 == 0 {
                    image.set(x, y, [180, 90, 60, 255]);
                }
            }
        }
        let reduced = developed(&image, RawDetailSettings { noise_color: 100.0, ..RawDetailSettings::default() });
        // Blending saturation toward its local blur keeps the average but shrinks the spread, so the
        // measurement is the standard deviation of saturation, not the total chroma.
        let spread = |image: &Bitmap8| {
            let saturations: Vec<f64> = image
                .pixels()
                .chunks_exact(4)
                .map(|pixel| {
                    let (r, g, b) = (pixel[0] as f64, pixel[1] as f64, pixel[2] as f64);
                    let maxc = r.max(g).max(b);
                    let minc = r.min(g).min(b);
                    if maxc == 0.0 {
                        0.0
                    } else {
                        (maxc - minc) / maxc
                    }
                })
                .collect();
            let mean = saturations.iter().sum::<f64>() / saturations.len() as f64;
            (saturations.iter().map(|value| (value - mean).powi(2)).sum::<f64>() / saturations.len() as f64).sqrt()
        };
        assert!(spread(&reduced) < spread(&image), "{} vs {}", spread(&reduced), spread(&image));
    }

    #[test]
    fn edge_detection_is_zero_on_a_flat_plane() {
        let plane = vec![0.5f32; 16];
        assert_eq!(sharpen_edge_at(&plane, 4, 4, 1, 1, 1), 0.0);
        let mut stepped = vec![0.0f32; 16];
        for y in 0..4 {
            for x in 2..4 {
                stepped[y * 4 + x] = 1.0;
            }
        }
        // Column 1 touches the step at column 2; column 0 does not.
        assert!(sharpen_edge_at(&stepped, 4, 4, 1, 0, 1) > 0.0);
        assert_eq!(sharpen_edge_at(&stepped, 4, 4, 0, 0, 1), 0.0);
    }

    #[test]
    fn transparent_pixels_survive_every_detail_stage() {
        let mut image = edge_image();
        image.set(0, 0, [7, 8, 9, 0]);
        let detail = RawDetailSettings {
            sharpen_amount: 150.0,
            noise_luminance: 80.0,
            noise_color: 80.0,
            ..RawDetailSettings::default()
        };
        assert_eq!(developed(&image, detail).get(0, 0), [7, 8, 9, 0]);
    }

    #[test]
    fn extreme_detail_settings_stay_bounded() {
        let image = developed(
            &edge_image(),
            RawDetailSettings {
                sharpen_amount: 150.0,
                sharpen_radius: 100.0,
                sharpen_detail: 100.0,
                sharpen_masking: 100.0,
                noise_luminance: 100.0,
                noise_luminance_detail: 100.0,
                noise_luminance_contrast: 100.0,
                noise_color: 100.0,
                noise_color_detail: 100.0,
                noise_color_smoothness: 100.0,
            },
        );
        assert_eq!(image.pixels().len(), edge_image().pixels().len());
    }
}
