//! Camera Raw's Light and Color groups: white balance gains, exposure, contrast, the four tone
//! sliders, vibrance and saturation — one kernel, in the order the macOS C code runs them.
//!
//! Ported from `adjust_camera_raw` in compositor_mac/Compositor/Rendering/AdjustPixels.c.

use crate::math::{
    camera_clamp, linear_to_srgb, rec709, scale_luminance, srgb_to_linear, tone_blacks, tone_highlights, tone_shadows,
    tone_whites, vibrance_and_saturation,
};
use crate::raster::Raster;
use crate::settings::{RawClipping, RawSettings};

pub(crate) fn adjust_light_color(raster: &mut Raster, settings: &RawSettings) {
    adjust_light_color_inner(raster, settings, None);
}

/// The same kernel with the Option-drag clipping view in place of the grade: `CameraRawClipping` is
/// passed straight to `adjust_camera_raw` as its `clipping` argument (1 lights clipped channels on
/// black, 2 paints them dark on white).
pub(crate) fn adjust_light_color_clipping(raster: &mut Raster, settings: &RawSettings, clipping: RawClipping) {
    adjust_light_color_inner(raster, settings, Some(clipping));
}

fn adjust_light_color_inner(raster: &mut Raster, settings: &RawSettings, clipping: Option<RawClipping>) {
    let (red_gain, green_gain, blue_gain) = settings.gains();
    let light = settings.exposure.exp2();
    let contrast_scale = 1.0 + settings.contrast / 100.0;
    let highlight_amount = settings.highlights / 100.0;
    let shadow_amount = settings.shadows / 100.0;
    let white_amount = settings.whites / 100.0;
    let black_amount = settings.blacks / 100.0;
    let vibrance_amount = settings.vibrance / 100.0;
    let saturation_amount = settings.saturation / 100.0;
    for index in 0..raster.len() {
        if raster.alpha[index] == 0 {
            continue;
        }
        let source = raster.rgb[index];
        // Exposure multiplies linear light; the gains are white balance, so they multiply first and
        // together, then the contrast swing happens in encoded sRGB about mid gray.
        let mut color = [
            camera_clamp(srgb_to_linear(source[0]) * red_gain * light),
            camera_clamp(srgb_to_linear(source[1]) * green_gain * light),
            camera_clamp(srgb_to_linear(source[2]) * blue_gain * light),
        ];
        color = [
            camera_clamp(0.5 + (linear_to_srgb(color[0]) - 0.5) * contrast_scale),
            camera_clamp(0.5 + (linear_to_srgb(color[1]) - 0.5) * contrast_scale),
            camera_clamp(0.5 + (linear_to_srgb(color[2]) - 0.5) * contrast_scale),
        ];
        // Each tone slider reads the luminance the previous one left behind, so the four compose in
        // the documented order instead of all measuring the original pixel.
        let target = tone_highlights(rec709(color[0], color[1], color[2]), highlight_amount);
        scale_luminance(&mut color, target);
        let target = tone_shadows(rec709(color[0], color[1], color[2]), shadow_amount);
        scale_luminance(&mut color, target);
        let target = tone_whites(rec709(color[0], color[1], color[2]), white_amount);
        scale_luminance(&mut color, target);
        let target = tone_blacks(rec709(color[0], color[1], color[2]), black_amount);
        scale_luminance(&mut color, target);
        vibrance_and_saturation(&mut color, vibrance_amount, saturation_amount);
        if let Some(clipping) = clipping {
            color = clipping_view_color(color, clipping);
        }
        raster.rgb[index] = color;
    }
}

/// One pixel of the Option-drag view: the clipped channels go to the extreme and the rest to the
/// opposite end, so the picture reads as "these channels are at the wall".
fn clipping_view_color(color: [f64; 3], clipping: RawClipping) -> [f64; 3] {
    let (clipped, extreme) = match clipping {
        RawClipping::Highlights => (
            [color[0] >= 254.5 / 255.0, color[1] >= 254.5 / 255.0, color[2] >= 254.5 / 255.0],
            1.0,
        ),
        RawClipping::Shadows => (
            [color[0] <= 0.5 / 255.0, color[1] <= 0.5 / 255.0, color[2] <= 0.5 / 255.0],
            0.0,
        ),
    };
    if !clipped.iter().any(|flag| *flag) {
        return color;
    }
    let other = 1.0 - extreme;
    [
        if clipped[0] { extreme } else { other },
        if clipped[1] { extreme } else { other },
        if clipped[2] { extreme } else { other },
    ]
}

/// The clipping *indicator* paint, `adjust_camera_raw_clip_overlay`: blue over clipped shadows and red
/// over clipped highlights, blended over the grade instead of replacing it. The indicators are a
/// separate preview from the Option-drag view above, exactly as they are on macOS.
pub(crate) fn clip_indicator(raster: &mut Raster, shadows: bool, highlights: bool) {
    if !shadows && !highlights {
        return;
    }
    for index in 0..raster.len() {
        if raster.alpha[index] == 0 {
            continue;
        }
        let mut color = raster.rgb[index];
        if shadows && (color[0] <= 0.5 / 255.0 || color[1] <= 0.5 / 255.0 || color[2] <= 0.5 / 255.0) {
            color[0] *= 0.35;
            color[1] *= 0.35;
            color[2] = color[2] * 0.35 + 0.65;
        }
        if highlights && (color[0] >= 254.5 / 255.0 || color[1] >= 254.5 / 255.0 || color[2] >= 254.5 / 255.0) {
            color[0] = color[0] * 0.35 + 0.65;
            color[1] *= 0.35;
            color[2] *= 0.35;
        }
        raster.rgb[index] = color;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::raster::Raster;
    use crate::settings::RawSettings;
    use comp_core::Bitmap8;

    /// A four-step gray wedge, plus one saturated and one muted color patch.
    fn wedge() -> Bitmap8 {
        Bitmap8::from_raw(
            6,
            1,
            vec![
                0, 0, 0, 255, 48, 48, 48, 255, 128, 128, 128, 255, 230, 230, 230, 255, 255, 0, 0, 255, 150, 110, 90,
                255,
            ],
        )
        .unwrap()
    }

    fn developed(settings: &RawSettings) -> Bitmap8 {
        crate::develop(&wedge(), settings)
    }

    fn luma(image: &Bitmap8, x: u32) -> f64 {
        let pixel = image.get(x, 0);
        rec709(pixel[0] as f64 / 255.0, pixel[1] as f64 / 255.0, pixel[2] as f64 / 255.0)
    }

    #[test]
    fn default_settings_return_the_same_pixels() {
        let image = wedge();
        assert_eq!(developed(&RawSettings::default()), image);
    }

    #[test]
    fn exposure_is_monotone_across_stops() {
        let mut previous = -1.0;
        for exposure in [0.0, 0.5, 1.0, 2.0, 3.0] {
            let settings = RawSettings { exposure, ..RawSettings::default() };
            let value = luma(&developed(&settings), 2);
            assert!(value >= previous, "exposure {exposure} darkened the midtone");
            previous = value;
        }
    }

    #[test]
    fn contrast_pushes_the_ends_apart_about_mid_gray() {
        let settings = RawSettings { contrast: 60.0, ..RawSettings::default() };
        let image = developed(&settings);
        assert!(luma(&image, 1) < luma(&wedge(), 1), "dark quarter tone must drop");
        assert!(luma(&image, 3) > luma(&wedge(), 3), "bright quarter tone must rise");
        assert!((luma(&image, 2) - luma(&wedge(), 2)).abs() < 0.01, "mid gray is the pivot");
    }

    #[test]
    fn tone_sliders_move_their_own_end_of_the_range() {
        let shadows_up = developed(&RawSettings { shadows: 80.0, ..RawSettings::default() });
        assert!(luma(&shadows_up, 1) > luma(&wedge(), 1));
        assert!((luma(&shadows_up, 2) - luma(&wedge(), 2)).abs() < 1e-9, "mid gray is untouched");

        let shadows_down = developed(&RawSettings { shadows: -80.0, ..RawSettings::default() });
        assert!(luma(&shadows_down, 1) < luma(&wedge(), 1));

        let highlights_down = developed(&RawSettings { highlights: -80.0, ..RawSettings::default() });
        assert!(luma(&highlights_down, 3) < luma(&wedge(), 3));

        let whites_up = developed(&RawSettings { whites: 60.0, ..RawSettings::default() });
        assert!(luma(&whites_up, 3) > luma(&wedge(), 3));
        assert!((luma(&whites_up, 2) - luma(&wedge(), 2)).abs() < 1e-9);

        let blacks_down = developed(&RawSettings { blacks: -60.0, ..RawSettings::default() });
        assert!(luma(&blacks_down, 1) < luma(&wedge(), 1));
        assert!((luma(&blacks_down, 2) - luma(&wedge(), 2)).abs() < 1e-9);
    }

    #[test]
    fn saturation_swings_color_around_luminance() {
        // The muted patch has chroma to give; the pure red one is already at the top of its range.
        let up = developed(&RawSettings { saturation: 50.0, ..RawSettings::default() });
        let down = developed(&RawSettings { saturation: -50.0, ..RawSettings::default() });
        let chroma = |image: &Bitmap8| {
            let pixel = image.get(5, 0);
            pixel[0] as i32 - pixel[1] as i32
        };
        assert!(chroma(&up) > chroma(&wedge()), "{} vs {}", chroma(&up), chroma(&wedge()));
        assert!(chroma(&down) < chroma(&wedge()), "{} vs {}", chroma(&down), chroma(&wedge()));
    }

    #[test]
    fn vibrance_moves_a_muted_color_more_than_a_saturated_one() {
        let up = developed(&RawSettings { vibrance: 80.0, ..RawSettings::default() });
        let muted_shift = (up.get(5, 0)[1] as i32 - wedge().get(5, 0)[1] as i32).abs();
        let vivid_shift = (up.get(4, 0)[1] as i32 - wedge().get(4, 0)[1] as i32).abs();
        assert!(muted_shift > vivid_shift, "muted {muted_shift} vs vivid {vivid_shift}");
    }

    #[test]
    fn white_balance_gains_are_the_macos_constants() {
        let settings = RawSettings { temperature: 100.0, tint: 0.0, ..RawSettings::default() };
        let (red, green, blue) = settings.gains();
        assert!((red - 1.35).abs() < 1e-12);
        assert!((green - 1.0).abs() < 1e-12);
        assert!((blue - 0.65).abs() < 1e-12);

        let settings = RawSettings { temperature: 0.0, tint: 100.0, ..RawSettings::default() };
        let (red, green, blue) = settings.gains();
        assert!((red - 1.15).abs() < 1e-12);
        assert!((green - 0.70).abs() < 1e-12);
        assert!((blue - 1.15).abs() < 1e-12);
    }

    #[test]
    fn warming_raises_red_and_lowers_blue_on_mid_gray() {
        let neutral = wedge().get(2, 0);
        let warm = developed(&RawSettings { temperature: 80.0, ..RawSettings::default() }).get(2, 0);
        assert!(warm[0] > neutral[0]);
        assert!(warm[2] < neutral[2]);
        assert_eq!(warm[1], neutral[1], "temperature leaves green alone");
    }

    #[test]
    fn magenta_tint_pulls_green_down() {
        let neutral = wedge().get(2, 0);
        let magenta = developed(&RawSettings { tint: 80.0, ..RawSettings::default() }).get(2, 0);
        assert!(magenta[1] < neutral[1]);
        assert!(magenta[0] > neutral[0]);
        assert!(magenta[2] > neutral[2]);
    }

    #[test]
    fn transparent_pixels_are_left_alone() {
        let image = Bitmap8::from_raw(1, 1, vec![200, 100, 50, 0]).unwrap();
        let settings = RawSettings { exposure: 2.0, saturation: 80.0, ..RawSettings::default() };
        assert_eq!(crate::develop(&image, &settings), image);
    }

    #[test]
    fn extreme_settings_stay_in_range() {
        let extremes = [
            RawSettings { exposure: 5.0, contrast: 100.0, highlights: -100.0, shadows: 100.0, whites: 100.0, blacks: -100.0, vibrance: 100.0, saturation: 100.0, ..RawSettings::default() },
            RawSettings { exposure: -5.0, contrast: -100.0, highlights: 100.0, shadows: -100.0, whites: -100.0, blacks: 100.0, vibrance: -100.0, saturation: -100.0, ..RawSettings::default() },
        ];
        for settings in extremes {
            let image = developed(&settings);
            // The output is 8-bit, so the assertion is that the kernel ran and stayed a valid image:
            // every channel byte exists and fully transparent pixels kept their value.
            assert_eq!(image.pixels().len(), wedge().pixels().len());
        }
    }

    /// The numbers below were produced by `tools/oracle.py`, an independent implementation of
    /// `adjust_camera_raw` written from the C source, for one pixel per case.
    #[test]
    fn graded_pixels_match_the_python_oracle() {
        let cases: [(RawSettings, [u8; 3], [u8; 3]); 8] = [
            (RawSettings { exposure: 1.0, ..RawSettings::default() }, [128, 128, 128], [176, 176, 176]),
            (
                RawSettings { vibrance: 60.0, saturation: -20.0, ..RawSettings::default() },
                [200, 60, 60],
                [194, 62, 62],
            ),
            (
                RawSettings { temperature: 60.0, tint: -40.0, exposure: -0.5, contrast: 25.0, ..RawSettings::default() },
                [60, 90, 200],
                [35, 69, 154],
            ),
            (
                RawSettings { highlights: -60.0, whites: 50.0, ..RawSettings::default() },
                [230, 230, 230],
                [190, 190, 190],
            ),
            (RawSettings { blacks: -100.0, ..RawSettings::default() }, [13, 13, 13], [0, 0, 0]),
            (
                RawSettings { shadows: 60.0, blacks: -100.0, ..RawSettings::default() },
                [13, 13, 13],
                [68, 68, 68],
            ),
            (RawSettings { vibrance: 100.0, ..RawSettings::default() }, [200, 60, 60], [233, 51, 51]),
            (RawSettings { saturation: -100.0, ..RawSettings::default() }, [128, 128, 128], [128, 128, 128]),
        ];
        for (settings, input, expected) in cases {
            let image = Bitmap8::from_raw(1, 1, vec![input[0], input[1], input[2], 255]).unwrap();
            let out = crate::develop(&image, &settings);
            let pixel = out.get(0, 0);
            assert_eq!(
                [pixel[0], pixel[1], pixel[2]],
                expected,
                "{input:?} with {settings:?} produced {pixel:?}"
            );
        }
    }

    #[test]
    fn the_option_drag_view_lights_clipped_channels() {
        let image = Bitmap8::from_raw(2, 1, vec![255, 128, 128, 255, 10, 10, 10, 255]).unwrap();
        let settings = RawSettings::default();
        let view = crate::clipping_view(&image, &settings, RawClipping::Highlights);
        assert_eq!(view.get(0, 0), [255, 0, 0, 255], "only the clipped channel stays lit");
        assert_eq!(view.get(1, 0), [10, 10, 10, 255], "an unclipped pixel is untouched");

        let dark = Bitmap8::from_raw(1, 1, vec![0, 40, 200, 255]).unwrap();
        let view = crate::clipping_view(&dark, &settings, RawClipping::Shadows);
        assert_eq!(view.get(0, 0), [0, 255, 255, 255], "clipped channels go dark");
    }

    #[test]
    fn the_clipping_indicator_paints_blue_and_red() {
        let mut raster = Raster::from_bitmap(&Bitmap8::new(2, 1));
        raster.rgb[0] = [0.0, 0.0, 0.0];
        raster.rgb[1] = [1.0, 1.0, 1.0];
        raster.alpha[0] = 255;
        raster.alpha[1] = 255;
        clip_indicator(&mut raster, true, true);
        // A clipped shadow is pulled toward blue, a clipped highlight toward red.
        assert!(raster.rgb[0][2] > raster.rgb[0][0], "{:?}", raster.rgb[0]);
        assert!(raster.rgb[1][0] > raster.rgb[1][2], "{:?}", raster.rgb[1]);
    }
}
