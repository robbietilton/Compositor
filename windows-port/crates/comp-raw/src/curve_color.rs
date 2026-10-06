//! Curve, Color Mixer and Color Grading — the creative color half of the filter.
//!
//! Ported from `adjust_camera_raw_curve_color` in compositor_mac/Compositor/Rendering/AdjustPixels.c,
//! which runs the three panels in one pass over the pixels: the tone curve first, then the per-channel
//! curves, then the eight-family mixer with the picked point colors, then the four grading wheels.

use crate::math::{camera_clamp, circular_distance, hsl_to_rgb, rec709, rgb_to_hsl, scale_luminance};
use crate::raster::Raster;
use crate::settings::{RawCurveSettings, RawSettings};

/// Hue centers of the eight families, on the kernel's 0…1 hue axis.
const MIXER_CENTERS: [f64; 8] = [
    0.0,
    30.0 / 360.0,
    60.0 / 360.0,
    120.0 / 360.0,
    180.0 / 360.0,
    240.0 / 360.0,
    270.0 / 360.0,
    300.0 / 360.0,
];

/// How much a family reaches: a 40° half-width in turns, so neighbors overlap.
const MIXER_HALF_WIDTH: f64 = 40.0 / 360.0;

pub(crate) fn apply_curve_color(raster: &mut Raster, settings: &RawSettings, visualize: Option<usize>) {
    let curve = settings.curve.normalized();
    let mixer = settings.mixer.normalized();
    let grading = settings.grading.normalized();
    let tone = curve.tone_table();
    let red = RawCurveSettings::channel_table(&curve.red);
    let green = RawCurveSettings::channel_table(&curve.green);
    let blue = RawCurveSettings::channel_table(&curve.blue);
    let mixer_floats = mixer.mixer_floats();
    let point_floats = mixer.point_floats();
    let grade = grading.grade_floats();
    let refine_saturation = curve.refine_saturation / 100.0;
    let blending = grading.blending / 100.0;
    let balance = grading.balance / 100.0;
    let point_count = mixer.points.len();
    let visualize = visualize.filter(|index| *index < point_count).map(|index| index as i64).unwrap_or(-1);

    for index in 0..raster.len() {
        if raster.alpha[index] == 0 {
            continue;
        }
        let [source_r, source_g, source_b] = raster.rgb[index];
        // The tone curve works on red, green and blue alike, as Photoshop's does, so contrast brings
        // color strength with it. Refine Saturation below zero eases toward changing brightness alone
        // (−100), and above zero adds more color.
        let mut r = lut_at(&tone, source_r);
        let mut g = lut_at(&tone, source_g);
        let mut b = lut_at(&tone, source_b);
        if refine_saturation < 0.0 {
            let mut flat = [source_r, source_g, source_b];
            scale_luminance(&mut flat, lut_at(&tone, rec709(source_r, source_g, source_b)));
            let k = -refine_saturation;
            r += (flat[0] - r) * k;
            g += (flat[1] - g) * k;
            b += (flat[2] - b) * k;
        } else if refine_saturation > 0.0 {
            let lum = rec709(r, g, b);
            let factor = 1.0 + refine_saturation;
            r = camera_clamp(lum + (r - lum) * factor);
            g = camera_clamp(lum + (g - lum) * factor);
            b = camera_clamp(lum + (b - lum) * factor);
        }
        r = lut_at(&red, r);
        g = lut_at(&green, g);
        b = lut_at(&blue, b);

        let (mut h, mut s, l) = rgb_to_hsl(r, g, b);
        let source_hue = h;
        let source_saturation = s;
        let source_luminance = l;
        let mut hue_delta = 0.0;
        let mut saturation_delta = 0.0;
        let mut luminance_delta = 0.0;
        let mut weight_sum = 0.0;
        for family in 0..8 {
            let distance = circular_distance(h, MIXER_CENTERS[family]);
            let weight = 1.0 - distance / MIXER_HALF_WIDTH;
            if weight <= 0.0 {
                continue;
            }
            hue_delta += mixer_floats[family] as f64 * weight * (30.0 / 360.0);
            saturation_delta += mixer_floats[8 + family] as f64 * weight;
            luminance_delta += mixer_floats[16 + family] as f64 * weight * 0.25;
            weight_sum += weight;
        }
        // Where two families overlap, the combined shift is averaged so a hue between two namings does
        // not move twice as far as one that sits on a center.
        if weight_sum > 1.0 {
            hue_delta /= weight_sum;
            saturation_delta /= weight_sum;
            luminance_delta /= weight_sum;
        }
        h += hue_delta;
        if h < 0.0 {
            h += 1.0;
        }
        if h >= 1.0 {
            h -= 1.0;
        }
        s = camera_clamp(s * (1.0 + saturation_delta));
        let mut l = camera_clamp(l + luminance_delta);
        for point in 0..point_count {
            let floats = &point_floats[point * 9..point * 9 + 9];
            let weight = point_weight(h, s, l, floats);
            if weight <= 0.0 {
                continue;
            }
            h += floats[3] as f64 * weight * (30.0 / 360.0);
            s = camera_clamp(s * (1.0 + floats[4] as f64 * weight));
            l = camera_clamp(l + floats[5] as f64 * weight * 0.25);
        }
        if h < 0.0 {
            h += 1.0;
        }
        if h >= 1.0 {
            h -= 1.0;
        }
        let mixed = hsl_to_rgb(h, s, l);
        r = mixed[0];
        g = mixed[1];
        b = mixed[2];

        // Balance moves the crossover between the shadow and highlight wheels. Toward highlights it
        // has to move down, so more of the picture counts as highlight and the shadow wheel loses its
        // hold; the other sign strengthened the shadow tint it was meant to weaken.
        let split = 0.5 - balance * 0.2;
        let reach = 0.12 + blending * 0.38;
        let lum = rec709(r, g, b);
        let mut shadow_weight = camera_clamp((split + reach - lum) / (reach * 2.0).max(0.05));
        let mut highlight_weight = camera_clamp((lum - (split - reach)) / (reach * 2.0).max(0.05));
        let mut mid_weight = camera_clamp(1.0 - (lum - split).abs() / (0.35 + reach));
        let sum = shadow_weight + mid_weight + highlight_weight;
        if sum > 1e-4 {
            shadow_weight /= sum;
            mid_weight /= sum;
            highlight_weight /= sum;
        }
        // The global wheel always applies at full weight; the three tonal wheels share the rest.
        let weights = [shadow_weight, mid_weight, highlight_weight, 1.0];
        for wheel in 0..4 {
            let hue = grade[wheel * 3] as f64;
            let saturation = grade[wheel * 3 + 1] as f64;
            let luminance = grade[wheel * 3 + 2] as f64;
            let weight = weights[wheel];
            if weight <= 0.0 || (saturation <= 0.0 && luminance == 0.0) {
                continue;
            }
            let color = hsl_to_rgb(hue, 1.0, 0.5);
            r = camera_clamp(r + (color[0] - 0.5) * saturation * weight * 0.85);
            g = camera_clamp(g + (color[1] - 0.5) * saturation * weight * 0.85);
            b = camera_clamp(b + (color[2] - 0.5) * saturation * weight * 0.85);
            if luminance != 0.0 {
                let mut rgb = [r, g, b];
                scale_luminance(&mut rgb, camera_clamp(rec709(r, g, b) + luminance * 0.25 * weight));
                r = rgb[0];
                g = rgb[1];
                b = rgb[2];
            }
        }
        // Preview only: the point color being edited dims everything it does not reach.
        if visualize >= 0
            && point_weight(source_hue, source_saturation, source_luminance, &point_floats[visualize as usize * 9..visualize as usize * 9 + 9]) <= 0.05
        {
            r *= 0.35;
            g *= 0.35;
            b *= 0.35;
        }
        raster.rgb[index] = [r, g, b];
    }
}

/// `lut_at`: linear interpolation into a 256-entry table.
fn lut_at(lut: &[f32; 256], value: f64) -> f64 {
    let scaled = camera_clamp(value) * 255.0;
    let low = scaled as usize;
    let low = low.min(255);
    let high = if low < 255 { low + 1 } else { 255 };
    let t = scaled - low as f64;
    lut[low] as f64 + (lut[high] as f64 - lut[low] as f64) * t
}

/// `point_weight`: how much a pixel falls inside one picked color's ranges.
fn point_weight(h: f64, s: f64, l: f64, point: &[f32]) -> f64 {
    let hue_half = if point[6] > 0.01 { point[6] as f64 } else { 0.01 };
    let saturation_half = if point[7] > 0.01 { point[7] as f64 } else { 0.01 };
    let luminance_half = if point[8] > 0.01 { point[8] as f64 } else { 0.01 };
    let hue_weight = 1.0 - circular_distance(h, point[0] as f64) / hue_half;
    let saturation_weight = 1.0 - (s - point[1] as f64).abs() / saturation_half;
    let luminance_weight = 1.0 - (l - point[2] as f64).abs() / luminance_half;
    if hue_weight < 0.0 || saturation_weight < 0.0 || luminance_weight < 0.0 {
        return 0.0;
    }
    hue_weight * saturation_weight * luminance_weight
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::math::pixel_hue_degrees;
    use crate::settings::{RawCurveSettings, RawPointColor, RawSettings};
    use comp_core::Bitmap8;

    fn color_patch(r: u8, g: u8, b: u8) -> Bitmap8 {
        Bitmap8::from_raw(1, 1, vec![r, g, b, 255]).unwrap()
    }

    fn graded(image: &Bitmap8, settings: &RawSettings) -> [f64; 3] {
        let out = crate::develop(image, settings);
        let pixel = out.get(0, 0);
        [pixel[0] as f64, pixel[1] as f64, pixel[2] as f64]
    }

    fn hue_of(pixel: [f64; 3]) -> f64 {
        pixel_hue_degrees(pixel[0] / 255.0, pixel[1] / 255.0, pixel[2] / 255.0)
    }

    /// The numbers below were produced by `tools/oracle.py`, an independent implementation of
    /// `adjust_camera_raw_curve_color` written from the C source, for one pixel per case.
    #[test]
    fn graded_pixels_match_the_python_oracle() {
        let medium = crate::curve::medium_contrast_points();
        let cases: [(RawSettings, [u8; 3], [u8; 3]); 5] = [
            (
                RawSettings {
                    curve: RawCurveSettings { rgb: medium.clone(), ..RawCurveSettings::default() },
                    ..RawSettings::default()
                },
                [64, 64, 64],
                [46, 46, 46],
            ),
            (
                RawSettings {
                    mixer: crate::settings::RawMixerSettings {
                        hue: [40.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
                        saturation: [30.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
                        ..Default::default()
                    },
                    ..RawSettings::default()
                },
                [200, 60, 60],
                [217, 71, 43],
            ),
            (
                RawSettings {
                    grading: crate::settings::RawGradingSettings {
                        global: crate::settings::RawGradeWheel { hue: 240.0, saturation: 100.0, luminance: 0.0 },
                        ..Default::default()
                    },
                    ..RawSettings::default()
                },
                [128, 128, 128],
                [20, 20, 236],
            ),
            (
                RawSettings {
                    grading: crate::settings::RawGradingSettings {
                        shadows: crate::settings::RawGradeWheel { hue: 30.0, saturation: 100.0, luminance: -50.0 },
                        ..Default::default()
                    },
                    ..RawSettings::default()
                },
                [40, 40, 40],
                [67, 24, 0],
            ),
            (
                RawSettings {
                    curve: RawCurveSettings { refine_saturation: 80.0, ..RawCurveSettings::default() },
                    ..RawSettings::default()
                },
                [180, 120, 90],
                [220, 112, 58],
            ),
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
        // The RGB point curve is a three-point case of the same table.
        let settings = RawSettings {
            curve: RawCurveSettings { rgb: medium, ..RawCurveSettings::default() },
            ..RawSettings::default()
        };
        for (input, expected) in [(128u8, 128u8), (192, 210)] {
            let image = Bitmap8::from_raw(1, 1, vec![input, input, input, 255]).unwrap();
            assert_eq!(crate::develop(&image, &settings).get(0, 0)[0], expected, "tone {input}");
        }
    }

    #[test]
    fn an_idle_panel_leaves_pixels_alone() {
        let image = color_patch(180, 120, 60);
        let mut raster = Raster::from_bitmap(&image);
        apply_curve_color(&mut raster, &RawSettings::default(), None);
        assert_eq!(raster.to_bitmap(), image);
    }

    #[test]
    fn a_medium_contrast_rgb_curve_darkens_the_quarter_tone() {
        let image = color_patch(64, 64, 64);
        let settings = RawSettings {
            curve: RawCurveSettings {
                rgb: crate::curve::medium_contrast_points(),
                ..RawCurveSettings::default()
            },
            ..RawSettings::default()
        };
        assert!(graded(&image, &settings)[0] < 64.0);
    }

    #[test]
    fn a_red_channel_curve_moves_only_red() {
        let image = color_patch(128, 128, 128);
        let mut curve = RawCurveSettings::default();
        curve.red = vec![crate::curve::RawCurvePoint::new(0.0, 0.0), crate::curve::RawCurvePoint::new(1.0, 0.5)];
        let settings = RawSettings { curve, ..RawSettings::default() };
        let out = graded(&image, &settings);
        assert!(out[0] < 128.0);
        assert_eq!(out[1], 128.0);
        assert_eq!(out[2], 128.0);
    }

    #[test]
    fn refine_saturation_above_zero_adds_color() {
        let image = color_patch(180, 120, 90);
        let mut curve = RawCurveSettings::default();
        curve.refine_saturation = 80.0;
        let settings = RawSettings { curve, ..RawSettings::default() };
        let out = graded(&image, &settings);
        let before = image.get(0, 0);
        let chroma = |pixel: [f64; 3]| pixel[0] - pixel[2];
        assert!(chroma(out) > chroma([before[0] as f64, before[1] as f64, before[2] as f64]));
    }

    #[test]
    fn the_mixer_shifts_the_family_a_hue_belongs_to() {
        let image = color_patch(200, 60, 60);
        let settings = RawSettings {
            mixer: crate::settings::RawMixerSettings { hue: [40.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], ..Default::default() },
            ..RawSettings::default()
        };
        let out = graded(&image, &settings);
        let before = [200.0, 60.0, 60.0];
        assert!(hue_of(out) > hue_of(before), "reds must turn toward orange");
    }

    #[test]
    fn the_mixer_stays_local_to_its_family() {
        // Only Yellows moves. A yellow pixel is at that family's center and takes the shift; a blue
        // one is 180° away, far past the 40° half-width, so it cannot be reached.
        let settings = RawSettings {
            mixer: crate::settings::RawMixerSettings { luminance: [0.0, 0.0, 50.0, 0.0, 0.0, 0.0, 0.0, 0.0], ..Default::default() },
            ..RawSettings::default()
        };
        let yellow = graded(&color_patch(200, 200, 60), &settings);
        assert!(yellow[0] > 200.0 && yellow[1] > 200.0, "yellows brighten");
        assert_eq!(graded(&color_patch(60, 60, 200), &settings), [60.0, 60.0, 200.0]);
    }

    #[test]
    fn a_point_color_reaches_only_the_color_it_was_picked_from() {
        let point = RawPointColor {
            hue: 0.0,
            saturation: 1.0,
            luminance: 0.5,
            saturation_shift: -100.0,
            hue_range: 30.0,
            ..RawPointColor::default()
        };
        let settings = RawSettings {
            mixer: crate::settings::RawMixerSettings { points: vec![point], ..Default::default() },
            ..RawSettings::default()
        };
        let red = graded(&color_patch(200, 40, 40), &settings);
        assert!(red[0] < 200.0 || red[1] > 40.0, "the picked red loses saturation");
        let green = graded(&color_patch(40, 200, 40), &settings);
        assert_eq!(green, [40.0, 200.0, 40.0], "a green pixel is out of reach");
    }

    #[test]
    fn visualizing_a_point_color_dims_everything_else() {
        let point = RawPointColor { hue: 0.0, saturation: 1.0, luminance: 0.5, ..RawPointColor::default() };
        let settings = RawSettings {
            mixer: crate::settings::RawMixerSettings { points: vec![point], ..Default::default() },
            ..RawSettings::default()
        };
        let neutral = color_patch(128, 128, 128);
        let mut raster = Raster::from_bitmap(&neutral);
        apply_curve_color(&mut raster, &settings, Some(0));
        let pixel = raster.rgb[0];
        assert!(pixel[0] < 128.0 / 255.0, "an out-of-range pixel is dimmed to 35%");
    }

    #[test]
    fn grading_wheels_tint_their_own_tones() {
        let wheel = crate::settings::RawGradeWheel { hue: 240.0, saturation: 100.0, luminance: 0.0 };
        let settings = RawSettings {
            grading: crate::settings::RawGradingSettings { shadows: wheel, ..Default::default() },
            ..RawSettings::default()
        };
        let dark = graded(&color_patch(40, 40, 40), &settings);
        assert!(dark[2] > dark[0], "a blue shadow wheel cools the shadows");

        let settings = RawSettings {
            grading: crate::settings::RawGradingSettings { highlights: wheel, ..Default::default() },
            ..RawSettings::default()
        };
        let bright = graded(&color_patch(215, 215, 215), &settings);
        assert!(bright[2] > bright[0], "the same wheel warms nothing at the bottom");
        let dark = graded(&color_patch(40, 40, 40), &settings);
        assert!(dark[2] >= dark[0], "and stays out of the shadows");
        assert!(bright[2] as i32 - bright[0] as i32 > dark[2] as i32 - dark[0] as i32);
    }

    #[test]
    fn the_global_wheel_grades_the_whole_range() {
        let settings = RawSettings {
            grading: crate::settings::RawGradingSettings {
                global: crate::settings::RawGradeWheel { hue: 120.0, saturation: 60.0, luminance: 0.0 },
                ..Default::default()
            },
            ..RawSettings::default()
        };
        let dark = graded(&color_patch(40, 40, 40), &settings);
        let bright = graded(&color_patch(215, 215, 215), &settings);
        assert!(dark[1] > dark[0] && bright[1] > bright[0], "green reaches both ends");
    }

    #[test]
    fn grading_luminance_moves_brightness() {
        let settings = RawSettings {
            grading: crate::settings::RawGradingSettings {
                global: crate::settings::RawGradeWheel { hue: 0.0, saturation: 0.0, luminance: -100.0 },
                ..Default::default()
            },
            ..RawSettings::default()
        };
        assert!(graded(&color_patch(128, 128, 128), &settings)[0] < 128.0);
    }

    #[test]
    fn balancing_toward_highlights_weakens_the_shadow_wheel() {
        let wheel = crate::settings::RawGradeWheel { hue: 240.0, saturation: 100.0, luminance: 0.0 };
        let shadows = crate::settings::RawGradingSettings { shadows: wheel, ..Default::default() };
        let neutral = RawSettings { grading: shadows, ..RawSettings::default() };
        let balanced = RawSettings {
            grading: crate::settings::RawGradingSettings { balance: 100.0, ..shadows },
            ..RawSettings::default()
        };
        let image = color_patch(60, 60, 60);
        let plain = graded(&image, &neutral);
        let shifted = graded(&image, &balanced);
        assert!(shifted[2] - shifted[0] < plain[2] - plain[0], "the shadow tint must fade");
    }
}
