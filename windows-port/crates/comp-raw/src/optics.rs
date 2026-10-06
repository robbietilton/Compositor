//! The Optics panel: chromatic aberration, lens distortion, defringe and lens-vignetting correction.
//!
//! Ported from `adjust_camera_raw_optics` and `lens_distort` (compositor_mac/Compositor/Rendering/
//! LensPixels.c). Distortion runs first, then the color split, then the per-pixel defringe and
//! vignette correction.

use crate::math::{camera_clamp, pixel_hue_degrees, rec709};
use crate::raster::Raster;
use crate::settings::RawOpticsSettings;

pub(crate) fn apply_optics(raster: &mut Raster, optics: &RawOpticsSettings) {
    if raster.width == 0 || raster.height == 0 {
        return;
    }
    let profile_vignette = if optics.enable_lens_profile { optics.profile_vignetting / 100.0 } else { 0.0 };
    // A lens profile has no metadata to read on a rendered layer, so its Vignetting slider scales a
    // generic correction: full strength is worth 35 units of the manual slider.
    let vignette = optics.vignette_amount + profile_vignette * 35.0;
    if optics.distortion_k() != 0.0 {
        lens_distort(raster, optics.distortion_k());
    }
    if optics.remove_chromatic_aberration {
        remove_chromatic_aberration(raster);
    }
    if optics.purple_amount == 0.0 && optics.green_amount == 0.0 && vignette == 0.0 {
        return;
    }
    for index in 0..raster.len() {
        if raster.alpha[index] == 0 {
            continue;
        }
        let mut color = raster.rgb[index];
        defringe(
            &mut color,
            optics.purple_amount,
            optics.purple_hue_low,
            optics.purple_hue_high,
            optics.green_amount,
            optics.green_hue_low,
            optics.green_hue_high,
        );
        vignette_correct(&mut color, index, raster, vignette, optics.vignette_midpoint);
        raster.rgb[index] = color;
    }
}

/// The radial warp the Lens Correction filter uses: pixel centers move along the radius, sampled
/// bilinearly with the border clamped, keeping each pixel's own coverage.
fn lens_distort(raster: &mut Raster, k: f64) {
    let width = raster.width;
    let height = raster.height;
    let source = raster.clone();
    let cx = width as f64 * 0.5;
    let cy = height as f64 * 0.5;
    let half_diagonal_squared = cx * cx + cy * cy;
    if half_diagonal_squared <= 0.0 {
        return;
    }
    for y in 0..height {
        let dy = y as f64 + 0.5 - cy;
        for x in 0..width {
            let dx = x as f64 + 0.5 - cx;
            let scale = 1.0 - k * (dx * dx + dy * dy) / half_diagonal_squared;
            // Source position in pixel-center coordinates, sampled bilinearly; a sample that falls
            // outside the frame keeps only the neighbors that exist, so the border thins out.
            let (rgb, alpha) = source.sample_premultiplied_skipped(cx + dx * scale - 0.5, cy + dy * scale - 0.5);
            let index = raster.index(x, y);
            raster.rgb[index] = rgb;
            raster.alpha[index] = crate::raster::quantize(alpha);
        }
    }
}

/// `optics_chromatic`: splits red and blue horizontally by an amount that grows with the square of the
/// distance from the center, pulling them back onto green.
fn remove_chromatic_aberration(raster: &mut Raster) {
    let width = raster.width;
    let height = raster.height;
    if width == 0 || height == 0 {
        return;
    }
    let source = raster.clone();
    let strength = 0.45;
    let cx = width as f64 * 0.5;
    let cy = height as f64 * 0.5;
    let max_radius = (cx * cx + cy * cy).sqrt();
    if max_radius <= 0.0 {
        return;
    }
    for y in 0..height {
        let dy = y as f64 + 0.5 - cy;
        for x in 0..width {
            let index = raster.index(x, y);
            if raster.alpha[index] == 0 {
                continue;
            }
            let dx = x as f64 + 0.5 - cx;
            let radial = (dx * dx + dy * dy).sqrt() / max_radius;
            let shift = strength * radial * radial * 2.5;
            let red_x = (x as f64 - shift).round() as i64;
            let blue_x = (x as f64 + shift).round() as i64;
            let red = sample_column(&source, red_x, y, 0);
            let blue = sample_column(&source, blue_x, y, 2);
            let green = raster.rgb[index][1];
            raster.rgb[index] = [red, green, blue];
        }
    }
}

/// One channel of a neighbor column, straight; a transparent neighbor contributes black, exactly as
/// dividing a premultiplied byte by its clamped alpha does in the kernel.
fn sample_column(raster: &Raster, x: i64, y: usize, channel: usize) -> f64 {
    let width = raster.width as i64;
    if width == 0 {
        return 0.0;
    }
    let x = x.clamp(0, width - 1) as usize;
    let index = raster.index(x, y);
    if raster.alpha[index] == 0 {
        0.0
    } else {
        raster.rgb[index][channel]
    }
}

/// Pulls chroma out of purple or green fringes without touching their brightness.
#[allow(clippy::too_many_arguments)]
fn defringe(
    color: &mut [f64; 3],
    purple_amount: f64,
    purple_low: f64,
    purple_high: f64,
    green_amount: f64,
    green_low: f64,
    green_high: f64,
) {
    let hue = pixel_hue_degrees(color[0], color[1], color[2]);
    let maxc = color[0].max(color[1]).max(color[2]);
    let minc = color[0].min(color[1]).min(color[2]);
    let chroma = maxc - minc;
    if chroma < 1e-6 {
        return;
    }
    let saturation = chroma / maxc;
    let mut reduce: f64 = 0.0;
    if purple_amount > 0.0 && hue_in_range(hue, purple_low, purple_high) {
        reduce = reduce.max(purple_amount / 100.0);
    }
    if green_amount > 0.0 && hue_in_range(hue, green_low, green_high) {
        reduce = reduce.max(green_amount / 100.0);
    }
    if reduce <= 0.0 {
        return;
    }
    let lum = rec709(color[0], color[1], color[2]);
    let factor = 1.0 - reduce * saturation;
    color[0] = camera_clamp(lum + (color[0] - lum) * factor);
    color[1] = camera_clamp(lum + (color[1] - lum) * factor);
    color[2] = camera_clamp(lum + (color[2] - lum) * factor);
}

/// `hue_in_range`: a range whose low handle sits above its high one wraps through 0°.
fn hue_in_range(hue: f64, low: f64, high: f64) -> bool {
    if low <= high {
        hue >= low && hue <= high
    } else {
        hue >= low || hue <= high
    }
}

/// Brightens the corners to counter lens falloff; a negative amount darkens them instead.
fn vignette_correct(color: &mut [f64; 3], index: usize, raster: &Raster, amount: f64, midpoint: f64) {
    if amount == 0.0 || raster.width == 0 || raster.height == 0 {
        return;
    }
    let x = index % raster.width;
    let y = index / raster.width;
    let nx = (x as f64 + 0.5) / raster.width as f64 * 2.0 - 1.0;
    let ny = (y as f64 + 0.5) / raster.height as f64 * 2.0 - 1.0;
    let dist = (nx * nx + ny * ny).sqrt() / std::f64::consts::SQRT_2;
    let start = (midpoint / 100.0) * 0.85;
    let t = camera_clamp((dist - start) / 0.35);
    let mask = t * t * (3.0 - 2.0 * t);
    let lift = (amount / 100.0) * mask;
    if lift > 0.0 {
        for channel in color.iter_mut() {
            *channel = camera_clamp(*channel + (1.0 - *channel) * lift);
        }
    } else {
        let factor = 1.0 + lift;
        for channel in color.iter_mut() {
            *channel *= factor;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{RawOpticsSettings, RawSettings};
    use comp_core::Bitmap8;

    fn purple_fringe() -> Bitmap8 {
        // A saturated purple patch surrounded by gray, which is what a defringe slider targets.
        let mut image = Bitmap8::filled(5, 5, [120, 120, 120, 255]);
        image.set(2, 2, [190, 60, 200, 255]);
        image
    }

    fn green_fringe() -> Bitmap8 {
        let mut image = Bitmap8::filled(5, 5, [120, 120, 120, 255]);
        // Hue 111 degrees, inside the default green defringe range of 60…120.
        image.set(2, 2, [60, 200, 40, 255]);
        image
    }

    fn developed(image: &Bitmap8, optics: RawOpticsSettings) -> Bitmap8 {
        let settings = RawSettings { optics, ..RawSettings::default() };
        crate::develop(image, &settings)
    }

    #[test]
    fn neutral_optics_is_identity() {
        assert_eq!(developed(&purple_fringe(), RawOpticsSettings::default()), purple_fringe());
    }

    #[test]
    fn purple_defringe_pulls_the_fringe_toward_gray() {
        let optics = RawOpticsSettings { purple_amount: 100.0, ..RawOpticsSettings::default() };
        let fixed = developed(&purple_fringe(), optics);
        let before = purple_fringe().get(2, 2);
        let after = fixed.get(2, 2);
        let chroma = |pixel: [u8; 4]| pixel[0].abs_diff(pixel[1]) as i32 + pixel[2].abs_diff(pixel[1]) as i32;
        assert!(chroma(after) < chroma(before), "{after:?} vs {before:?}");
    }

    #[test]
    fn the_green_range_only_reaches_green_fringes() {
        let optics = RawOpticsSettings { green_amount: 100.0, ..RawOpticsSettings::default() };
        assert_ne!(developed(&green_fringe(), optics).get(2, 2), green_fringe().get(2, 2));
        assert_eq!(developed(&purple_fringe(), optics).get(2, 2), purple_fringe().get(2, 2));
    }

    #[test]
    fn defringe_ranges_wrap_through_zero() {
        assert!(hue_in_range(350.0, 340.0, 20.0));
        assert!(hue_in_range(10.0, 340.0, 20.0));
        assert!(!hue_in_range(180.0, 340.0, 20.0));
        assert!(hue_in_range(180.0, 90.0, 270.0));
    }

    #[test]
    fn lens_vignetting_correction_brightens_the_corners() {
        let flat = Bitmap8::filled(9, 9, [120, 120, 120, 255]);
        let optics = RawOpticsSettings { vignette_amount: 100.0, ..RawOpticsSettings::default() };
        let fixed = developed(&flat, optics);
        assert!(fixed.get(0, 0)[0] > flat.get(0, 0)[0]);
        assert_eq!(fixed.get(4, 4)[0], flat.get(4, 4)[0], "the center is untouched");
    }

    #[test]
    fn a_lens_profile_scales_the_generic_correction() {
        let flat = Bitmap8::filled(9, 9, [120, 120, 120, 255]);
        let optics = RawOpticsSettings {
            enable_lens_profile: true,
            profile_vignetting: 100.0,
            ..RawOpticsSettings::default()
        };
        assert!(developed(&flat, optics).get(0, 0)[0] > flat.get(0, 0)[0]);
    }

    #[test]
    fn distortion_moves_pixels_and_keeps_the_frame() {
        let mut image = Bitmap8::filled(9, 9, [120, 120, 120, 255]);
        image.set(4, 4, [250, 250, 250, 255]);
        let optics = RawOpticsSettings { distortion: 100.0, ..RawOpticsSettings::default() };
        let warped = developed(&image, optics);
        assert_ne!(warped, image);
        assert_eq!((warped.width(), warped.height()), (9, 9));
        // A strong barrel warp still leaves the center of the frame covered.
        assert!(warped.get(4, 4)[3] > 0);
    }

    #[test]
    fn chromatic_aberration_correction_fuses_an_rgb_split() {
        let mut image = Bitmap8::filled(9, 9, [128, 128, 128, 255]);
        // A red and a blue edge, the shape a lateral chromatic aberration leaves behind.
        for y in 0..9 {
            image.set(2, y, [200, 128, 128, 255]);
            image.set(6, y, [128, 128, 200, 255]);
        }
        let optics = RawOpticsSettings { remove_chromatic_aberration: true, ..RawOpticsSettings::default() };
        let fixed = developed(&image, optics);
        assert_ne!(fixed, image);
        assert_eq!(fixed.get(0, 0)[3], 255);
    }

    #[test]
    fn transparent_pixels_are_skipped() {
        let mut image = purple_fringe();
        image.set(0, 0, [10, 20, 30, 0]);
        let optics = RawOpticsSettings {
            purple_amount: 100.0,
            vignette_amount: -100.0,
            remove_chromatic_aberration: true,
            ..RawOpticsSettings::default()
        };
        assert_eq!(developed(&image, optics).get(0, 0), [10, 20, 30, 0]);
    }

    #[test]
    fn extreme_optics_stay_bounded() {
        let optics = RawOpticsSettings {
            remove_chromatic_aberration: true,
            enable_lens_profile: true,
            profile_distortion: 100.0,
            profile_vignetting: 100.0,
            distortion: 100.0,
            purple_amount: 100.0,
            purple_hue_low: 360.0,
            purple_hue_high: 0.0,
            green_amount: 100.0,
            green_hue_low: 300.0,
            green_hue_high: 60.0,
            vignette_amount: -100.0,
            vignette_midpoint: 0.0,
        };
        let image = developed(&purple_fringe(), optics);
        assert_eq!((image.width(), image.height()), (5, 5));
    }
}
