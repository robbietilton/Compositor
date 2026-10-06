//! Camera calibration: shadow tint plus per-primary hue and saturation shifts, run before the
//! creative grade.
//!
//! Ported from `adjust_camera_raw_calibration` in AdjustPixels.c.

use crate::math::{camera_clamp, hsl_to_rgb, rgb_to_hsl};
use crate::raster::Raster;
use crate::settings::RawCalibrationSettings;

pub(crate) fn apply_calibration(raster: &mut Raster, calibration: &RawCalibrationSettings) {
    if !calibration.adjusts() {
        return;
    }
    let version_scale = calibration.process.scale();
    let tint = calibration.shadow_tint / 100.0 * version_scale;
    let red_hue = calibration.red_hue / 100.0 * (15.0 / 360.0) * version_scale;
    let red_saturation = calibration.red_saturation / 100.0 * 0.45 * version_scale;
    let green_hue = calibration.green_hue / 100.0 * (15.0 / 360.0) * version_scale;
    let green_saturation = calibration.green_saturation / 100.0 * 0.45 * version_scale;
    let blue_hue = calibration.blue_hue / 100.0 * (15.0 / 360.0) * version_scale;
    let blue_saturation = calibration.blue_saturation / 100.0 * 0.45 * version_scale;
    for index in 0..raster.len() {
        if raster.alpha[index] == 0 {
            continue;
        }
        let [r, g, b] = raster.rgb[index];
        let (mut h, mut s, l) = rgb_to_hsl(r, g, b);
        // Shadow tint only reaches the darkest third of the range.
        if l < 0.35 && tint != 0.0 {
            h += tint * 0.06;
        }
        let maxc = r.max(g).max(b);
        let minc = r.min(g).min(b);
        if maxc - minc > 1e-5 {
            // The shift belongs to the primary a pixel leans toward, so a red patch moves with the
            // red sliders and a cyan one with green and blue together.
            if r >= g && r >= b {
                h += red_hue;
                s = camera_clamp(s * (1.0 + red_saturation));
            } else if g >= r && g >= b {
                h += green_hue;
                s = camera_clamp(s * (1.0 + green_saturation));
            } else {
                h += blue_hue;
                s = camera_clamp(s * (1.0 + blue_saturation));
            }
        }
        if h < 0.0 {
            h += 1.0;
        }
        if h >= 1.0 {
            h -= 1.0;
        }
        raster.rgb[index] = hsl_to_rgb(h, s, l);
    }
}

#[cfg(test)]
mod tests {
    use crate::math::pixel_hue_degrees;
    use crate::settings::{RawCalibrationSettings, RawProcessVersion, RawSettings};
    use comp_core::Bitmap8;

    fn red_pixel() -> Bitmap8 {
        Bitmap8::from_raw(1, 1, vec![200, 60, 60, 255]).unwrap()
    }

    fn developed(calibration: RawCalibrationSettings) -> Bitmap8 {
        let settings = RawSettings { calibration, ..RawSettings::default() };
        crate::develop(&red_pixel(), &settings)
    }

    #[test]
    fn neutral_calibration_is_identity() {
        assert_eq!(developed(RawCalibrationSettings::default()), red_pixel());
    }

    #[test]
    fn a_red_hue_shift_turns_red_toward_orange() {
        let shifted = developed(RawCalibrationSettings { red_hue: 100.0, ..RawCalibrationSettings::default() });
        let before = pixel_hue_degrees(200.0 / 255.0, 60.0 / 255.0, 60.0 / 255.0);
        let pixel = shifted.get(0, 0);
        let after = pixel_hue_degrees(pixel[0] as f64 / 255.0, pixel[1] as f64 / 255.0, pixel[2] as f64 / 255.0);
        assert!(after > before, "{after} should sit past {before}");
    }

    #[test]
    fn red_saturation_lifts_chroma() {
        let lifted = developed(RawCalibrationSettings { red_saturation: 100.0, ..RawCalibrationSettings::default() });
        let pixel = lifted.get(0, 0);
        let before = red_pixel().get(0, 0);
        assert!(pixel[0] as i32 - pixel[1] as i32 > before[0] as i32 - before[1] as i32);
    }

    #[test]
    fn shadow_tint_touches_only_dark_pixels() {
        let dark = Bitmap8::from_raw(1, 1, vec![40, 30, 25, 255]).unwrap();
        let settings = RawSettings {
            calibration: RawCalibrationSettings { shadow_tint: 100.0, ..RawCalibrationSettings::default() },
            ..RawSettings::default()
        };
        assert_ne!(crate::develop(&dark, &settings), dark, "a dark pixel takes the tint");

        let bright = Bitmap8::from_raw(1, 1, vec![220, 210, 205, 255]).unwrap();
        assert_eq!(crate::develop(&bright, &settings), bright, "a bright pixel ignores it");
    }

    #[test]
    fn older_process_versions_scale_the_sliders_down() {
        let calibration = RawCalibrationSettings { red_saturation: 100.0, ..RawCalibrationSettings::default() };
        let modern = developed(calibration);
        let legacy = developed(RawCalibrationSettings { process: RawProcessVersion::Version1, ..calibration });
        let spread = |image: &Bitmap8| {
            let pixel = image.get(0, 0);
            pixel[0] as i32 - pixel[1] as i32
        };
        assert!(spread(&legacy) < spread(&modern), "Version 1 must be the gentler response");
    }
}
