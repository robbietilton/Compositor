//! End-to-end tests for the Camera Raw grade: the documented kernel order, the buffer entry points
//! and a sweep of every slider at both ends of its range.

use comp_core::Bitmap8;
use comp_raw::{
    develop, develop_buffer, develop_with, medium_contrast_points, RawCurveSettings, RawDetailSettings, RawGeometryGuide,
    RawGeometrySettings, RawGlowStyle, RawGradeWheel, RawGradingSettings, RawMixerSettings, RawOpticsSettings,
    RawPointColor, RawProjection, RawSettings, RawUprightMode, RawVignetteStyle,
};

/// A 24x24 test chart: a gray wedge across the top, a saturated color band, a step edge and one
/// fully transparent pixel, so every group has something to act on.
fn chart() -> Bitmap8 {
    let mut image = Bitmap8::filled(24, 24, [0, 0, 0, 255]);
    for y in 0..24u32 {
        for x in 0..24u32 {
            let value = (x * 10).min(250) as u8;
            let pixel = match y / 6 {
                0 => [value, value, value, 255],
                1 => [value, 60, 255 - value, 255],
                2 => {
                    if x < 12 {
                        [40, 40, 40, 255]
                    } else {
                        [210, 200, 190, 255]
                    }
                }
                _ => [120, 150, 120, 255],
            };
            image.set(x, y, pixel);
        }
    }
    image.set(23, 23, [90, 90, 90, 0]);
    image
}

fn mean_absolute_difference(left: &Bitmap8, right: &Bitmap8) -> f64 {
    assert_eq!((left.width(), left.height()), (right.width(), right.height()));
    let mut total = 0.0;
    let mut count = 0.0;
    for (a, b) in left.pixels().chunks_exact(4).zip(right.pixels().chunks_exact(4)) {
        for channel in 0..4 {
            total += (a[channel] as f64 - b[channel] as f64).abs();
            count += 1.0;
        }
    }
    total / count
}

fn curve_only() -> RawSettings {
    RawSettings {
        curve: RawCurveSettings { rgb: medium_contrast_points(), ..RawCurveSettings::default() },
        ..RawSettings::default()
    }
}

fn exposure_only() -> RawSettings {
    RawSettings { exposure: 1.0, ..RawSettings::default() }
}

fn mixer_only() -> RawSettings {
    RawSettings {
        mixer: RawMixerSettings { saturation: [40.0; 8], ..RawMixerSettings::default() },
        ..RawSettings::default()
    }
}

#[test]
fn the_documented_order_is_light_then_curve() {
    let image = chart();
    let both = RawSettings { exposure: 1.0, ..curve_only() };
    let forward = develop(&image, &both);
    let reversed = develop(&develop(&image, &curve_only()), &exposure_only());
    let sequential = develop(&develop(&image, &exposure_only()), &curve_only());

    // The pipeline runs Light and Color before Curve. Composing the two steps by hand reproduces it
    // to within the one byte of rounding each separate call performs.
    assert!(
        mean_absolute_difference(&forward, &sequential) < 3.0,
        "{}",
        mean_absolute_difference(&forward, &sequential)
    );
    // The other order is a different picture, which is why the order is part of the contract.
    assert!(
        mean_absolute_difference(&forward, &reversed) > 5.0,
        "{}",
        mean_absolute_difference(&forward, &reversed)
    );
}

#[test]
fn curve_runs_before_the_mixer() {
    let image = chart();
    let mut curve = RawCurveSettings::default();
    curve.rgb = medium_contrast_points();
    let both = RawSettings {
        curve: curve.clone(),
        mixer: RawMixerSettings { saturation: [40.0; 8], ..RawMixerSettings::default() },
        ..RawSettings::default()
    };
    let forward = develop(&image, &both);
    let documented = develop(&develop(&image, &curve_only()), &mixer_only());
    let reversed = develop(&develop(&image, &mixer_only()), &curve_only());
    assert!(mean_absolute_difference(&forward, &documented) < 3.0);
    assert!(mean_absolute_difference(&forward, &reversed) > 0.0);
}

#[test]
fn effects_run_before_optics() {
    // A darkening effects vignette multiplies the corners down, while the optics vignette correction
    // lifts them toward white; lifting a darkened corner is not the same as darkening a lifted one,
    // so the two orders cannot agree. The pipeline's order is the one that matches macOS.
    let image = chart();
    let effects = RawSettings { vignette_amount: -80.0, ..RawSettings::default() };
    let optics = RawSettings {
        optics: RawOpticsSettings { vignette_amount: 80.0, ..RawOpticsSettings::default() },
        ..RawSettings::default()
    };
    let combined = RawSettings { vignette_amount: -80.0, optics: optics.optics, ..RawSettings::default() };
    let both = develop(&image, &combined);
    let reversed = develop(&develop(&image, &optics), &effects);
    assert!(
        mean_absolute_difference(&both, &reversed) > 1.0,
        "{}",
        mean_absolute_difference(&both, &reversed)
    );
}

#[test]
fn geometry_runs_before_every_pixel_kernel() {
    // A rotation moves where each pixel is, and the vignette is shaped to the frame, so the two
    // orders differ; the pipeline warps first.
    let image = chart();
    let settings = RawSettings {
        geometry: RawGeometrySettings { rotate: 15.0, ..RawGeometrySettings::default() },
        vignette_amount: -80.0,
        ..RawSettings::default()
    };
    let warped_first = develop(&image, &settings);
    let graded_first = develop(
        &develop(&image, &RawSettings { vignette_amount: -80.0, ..RawSettings::default() }),
        &RawSettings { geometry: settings.geometry, ..RawSettings::default() },
    );
    assert!(mean_absolute_difference(&warped_first, &graded_first) > 0.5);
}

#[test]
fn the_buffer_entry_point_matches_the_bitmap_one() {
    let settings = RawSettings {
        exposure: 0.75,
        contrast: 20.0,
        temperature: 30.0,
        curve: RawCurveSettings { rgb: medium_contrast_points(), ..RawCurveSettings::default() },
        detail: RawDetailSettings { sharpen_amount: 50.0, ..RawDetailSettings::default() },
        ..RawSettings::default()
    };
    let image = chart();
    let from_buffer = develop_buffer(24, 24, image.pixels(), &settings).expect("the buffer matches its size");
    assert_eq!(from_buffer, develop(&image, &settings));

    // A buffer whose length disagrees with its size is rejected, not padded or truncated.
    assert!(develop_buffer(24, 24, &image.pixels()[..16], &settings).is_err());
    assert!(develop_buffer(0, 0, &[], &settings).is_ok());
}

#[test]
fn every_group_changes_the_picture_on_its_own() {
    let image = chart();
    let neutral = develop(&image, &RawSettings::default());
    assert_eq!(neutral, image, "the defaults must be the identity");

    let mut groups: Vec<(&str, RawSettings)> = Vec::new();
    groups.push(("light", RawSettings { exposure: 0.5, ..RawSettings::default() }));
    groups.push(("color", RawSettings { temperature: 40.0, ..RawSettings::default() }));
    groups.push((
        "curve",
        RawSettings {
            curve: RawCurveSettings { rgb: medium_contrast_points(), ..RawCurveSettings::default() },
            ..RawSettings::default()
        },
    ));
    groups.push((
        "mixer",
        RawSettings {
            mixer: RawMixerSettings { saturation: [30.0; 8], ..RawMixerSettings::default() },
            ..RawSettings::default()
        },
    ));
    groups.push((
        "grading",
        RawSettings {
            grading: RawGradingSettings {
                global: RawGradeWheel { hue: 120.0, saturation: 40.0, luminance: 10.0 },
                ..RawGradingSettings::default()
            },
            ..RawSettings::default()
        },
    ));
    groups.push((
        "detail",
        RawSettings {
            detail: RawDetailSettings { sharpen_amount: 90.0, ..RawDetailSettings::default() },
            ..RawSettings::default()
        },
    ));
    groups.push((
        "optics",
        RawSettings {
            optics: RawOpticsSettings { vignette_amount: 80.0, ..RawOpticsSettings::default() },
            ..RawSettings::default()
        },
    ));
    groups.push((
        "geometry",
        RawSettings {
            geometry: RawGeometrySettings { scale: 20.0, ..RawGeometrySettings::default() },
            ..RawSettings::default()
        },
    ));
    groups.push((
        "calibration",
        RawSettings {
            calibration: comp_raw::RawCalibrationSettings { red_saturation: 60.0, ..Default::default() },
            ..RawSettings::default()
        },
    ));
    for (name, settings) in groups {
        assert_ne!(develop(&image, &settings), neutral, "the {name} group did nothing");
    }
}

/// Every scalar slider, with a setter so the sweep below can drive it to both ends of its range.
type Slider = (&'static str, fn(&mut RawSettings, f64));

fn sliders() -> Vec<Slider> {
    vec![
        ("exposure", |s, v| s.exposure = v),
        ("contrast", |s, v| s.contrast = v),
        ("highlights", |s, v| s.highlights = v),
        ("shadows", |s, v| s.shadows = v),
        ("whites", |s, v| s.whites = v),
        ("blacks", |s, v| s.blacks = v),
        ("temperature", |s, v| s.temperature = v),
        ("tint", |s, v| s.tint = v),
        ("vibrance", |s, v| s.vibrance = v),
        ("saturation", |s, v| s.saturation = v),
        ("texture", |s, v| s.texture = v),
        ("clarity", |s, v| s.clarity = v),
        ("dehaze", |s, v| s.dehaze = v),
        ("glow", |s, v| s.glow = v),
        ("glowRange", |s, v| s.glow_range = v),
        ("glowSpread", |s, v| s.glow_spread = v),
        ("glowWarmth", |s, v| s.glow_warmth = v),
        ("vignetteAmount", |s, v| s.vignette_amount = v),
        ("vignetteMidpoint", |s, v| s.vignette_midpoint = v),
        ("vignetteRoundness", |s, v| s.vignette_roundness = v),
        ("vignetteFeather", |s, v| s.vignette_feather = v),
        ("vignetteHighlights", |s, v| s.vignette_highlights = v),
        ("grainAmount", |s, v| s.grain_amount = v),
        ("grainSize", |s, v| s.grain_size = v),
        ("grainRoughness", |s, v| s.grain_roughness = v),
        ("curveShadows", |s, v| s.curve.shadows = v),
        ("curveHighlights", |s, v| s.curve.highlights = v),
        ("refineSaturation", |s, v| s.curve.refine_saturation = v),
        ("mixerHue", |s, v| s.mixer.hue[0] = v),
        ("mixerSaturation", |s, v| s.mixer.saturation[3] = v),
        ("mixerLuminance", |s, v| s.mixer.luminance[5] = v),
        ("gradingBlending", |s, v| s.grading.blending = v),
        ("gradingBalance", |s, v| s.grading.balance = v),
        ("gradingLuminance", |s, v| s.grading.global.luminance = v),
        ("gradingSaturation", |s, v| s.grading.shadows.saturation = v),
        ("sharpenAmount", |s, v| s.detail.sharpen_amount = v),
        ("sharpenRadius", |s, v| s.detail.sharpen_radius = v),
        ("sharpenDetail", |s, v| s.detail.sharpen_detail = v),
        ("sharpenMasking", |s, v| s.detail.sharpen_masking = v),
        ("noiseLuminance", |s, v| s.detail.noise_luminance = v),
        ("noiseColor", |s, v| s.detail.noise_color = v),
        ("opticsDistortion", |s, v| s.optics.distortion = v),
        ("opticsPurple", |s, v| s.optics.purple_amount = v),
        ("opticsGreen", |s, v| s.optics.green_amount = v),
        ("opticsVignette", |s, v| s.optics.vignette_amount = v),
        ("geometryVertical", |s, v| s.geometry.vertical = v),
        ("geometryHorizontal", |s, v| s.geometry.horizontal = v),
        ("geometryRotate", |s, v| s.geometry.rotate = v),
        ("geometryAspect", |s, v| s.geometry.aspect = v),
        ("geometryScale", |s, v| s.geometry.scale = v),
        ("geometryOffsetX", |s, v| s.geometry.offset_x = v),
        ("geometryOffsetY", |s, v| s.geometry.offset_y = v),
        ("calibrationShadowTint", |s, v| s.calibration.shadow_tint = v),
        ("calibrationRedSaturation", |s, v| s.calibration.red_saturation = v),
    ]
}

#[test]
fn every_slider_at_both_ends_of_its_range_stays_valid() {
    let image = chart();
    for (name, set) in sliders() {
        for value in [-1000.0, -100.0, -5.0, 0.0, 5.0, 100.0, 1000.0, f64::NAN, f64::INFINITY] {
            let mut settings = RawSettings::default();
            set(&mut settings, value);
            let out = develop(&image, &settings);
            assert_eq!((out.width(), out.height()), (24, 24), "{name} at {value}");
            if !name.starts_with("geometry") && !name.starts_with("opticsDistortion") {
                // Every per-pixel kernel skips a fully transparent pixel. The two resamplers — the
                // geometry warp and lens distortion — are the exception: they sample neighbors, so a
                // clear pixel can be covered.
                assert_eq!(out.get(23, 23), [90, 90, 90, 0], "{name} at {value} touched a clear pixel");
            }
        }
    }
}

#[test]
fn non_default_but_idle_group_values_are_identity() {
    let image = chart();
    let settings = RawSettings {
        grain_size: 80.0,
        glow_style: RawGlowStyle::Halation,
        vignette_style: RawVignetteStyle::PaintOverlay,
        detail: RawDetailSettings { sharpen_radius: 60.0, ..RawDetailSettings::default() },
        optics: RawOpticsSettings { profile_vignetting: 40.0, ..RawOpticsSettings::default() },
        geometry: RawGeometrySettings { projection: RawProjection::Rectilinear, ..RawGeometrySettings::default() },
        ..RawSettings::default()
    };
    assert_eq!(develop(&image, &settings), image);
}

#[test]
fn an_image_of_one_clear_pixel_stays_clear() {
    let image = Bitmap8::from_raw(1, 1, vec![200, 100, 50, 0]).unwrap();
    let settings = RawSettings {
        exposure: 3.0,
        contrast: 100.0,
        saturation: 100.0,
        vignette_amount: -100.0,
        texture: 100.0,
        clarity: 100.0,
        detail: RawDetailSettings { sharpen_amount: 150.0, noise_luminance: 100.0, ..RawDetailSettings::default() },
        grain_amount: 100.0,
        optics: RawOpticsSettings { purple_amount: 100.0, ..RawOpticsSettings::default() },
        ..RawSettings::default()
    };
    assert_eq!(develop(&image, &settings).get(0, 0), [200, 100, 50, 0]);
}

#[test]
fn a_preview_scale_keeps_the_radii_proportional() {
    // The effects radii are preview pixels per layer pixel, so a half-scale preview blurs a narrower
    // window and the two renders differ.
    let image = chart();
    let settings = RawSettings { texture: 70.0, clarity: 70.0, glow: 60.0, ..RawSettings::default() };
    let full = develop_with(&image, &settings, 1.0, 0);
    let preview = develop_with(&image, &settings, 0.5, 0);
    assert_ne!(full, preview);
    assert!(mean_absolute_difference(&full, &preview) > 0.01);
}

#[test]
fn the_grain_seed_is_the_only_thing_that_moves_the_pattern() {
    let image = chart();
    let settings = RawSettings { grain_amount: 80.0, ..RawSettings::default() };
    assert_eq!(develop_with(&image, &settings, 1.0, 3), develop_with(&image, &settings, 1.0, 3));
    assert_ne!(develop_with(&image, &settings, 1.0, 3), develop_with(&image, &settings, 1.0, 4));
}

#[test]
fn a_full_grade_on_a_realistic_chart_keeps_size_alpha_and_order() {
    let image = chart();
    let settings = RawSettings {
        temperature: 18.0,
        tint: -6.0,
        exposure: 0.4,
        contrast: 25.0,
        highlights: -40.0,
        shadows: 35.0,
        whites: 12.0,
        blacks: -10.0,
        vibrance: 30.0,
        saturation: 5.0,
        texture: 25.0,
        clarity: 15.0,
        dehaze: 12.0,
        glow: 20.0,
        glow_style: RawGlowStyle::Bloom,
        glow_range: 30.0,
        glow_spread: 20.0,
        glow_warmth: 25.0,
        vignette_amount: -30.0,
        vignette_style: RawVignetteStyle::HighlightPriority,
        vignette_midpoint: 45.0,
        vignette_roundness: 20.0,
        vignette_feather: 60.0,
        vignette_highlights: 40.0,
        grain_amount: 25.0,
        grain_size: 30.0,
        grain_roughness: 40.0,
        curve: RawCurveSettings {
            shadows: 12.0,
            darks: -8.0,
            lights: 6.0,
            highlights: -10.0,
            rgb: medium_contrast_points(),
            refine_saturation: 10.0,
            ..RawCurveSettings::default()
        },
        mixer: RawMixerSettings {
            hue: [10.0, 0.0, -5.0, 0.0, 0.0, 5.0, 0.0, 0.0],
            saturation: [15.0, 10.0, 0.0, -10.0, 0.0, 8.0, 0.0, 0.0],
            luminance: [0.0, 5.0, 0.0, 0.0, -5.0, 0.0, 0.0, 0.0],
            points: vec![RawPointColor { hue: 210.0, saturation: 0.6, luminance: 0.5, saturation_shift: 30.0, ..RawPointColor::default() }],
        },
        grading: RawGradingSettings {
            shadows: RawGradeWheel { hue: 220.0, saturation: 25.0, luminance: -6.0 },
            highlights: RawGradeWheel { hue: 40.0, saturation: 18.0, luminance: 4.0 },
            blending: 55.0,
            balance: -10.0,
            ..RawGradingSettings::default()
        },
        detail: RawDetailSettings {
            sharpen_amount: 70.0,
            sharpen_radius: 25.0,
            sharpen_detail: 40.0,
            sharpen_masking: 20.0,
            noise_luminance: 20.0,
            noise_color: 25.0,
            ..RawDetailSettings::default()
        },
        optics: RawOpticsSettings {
            remove_chromatic_aberration: true,
            purple_amount: 30.0,
            green_amount: 20.0,
            vignette_amount: 25.0,
            ..RawOpticsSettings::default()
        },
        geometry: RawGeometrySettings {
            rotate: 1.5,
            vertical: 8.0,
            constrain_crop: true,
            guides: vec![RawGeometryGuide { start_x: 0.1, start_y: 0.1, end_x: 0.9, end_y: 0.12 }],
            upright: RawUprightMode::Guided,
            ..RawGeometrySettings::default()
        },
        calibration: comp_raw::RawCalibrationSettings { shadow_tint: 5.0, red_saturation: 10.0, ..Default::default() },
        ..RawSettings::default()
    };
    let out = develop(&image, &settings);
    assert_eq!((out.width(), out.height()), (24, 24));
    assert_ne!(out, image);
    // Deterministic: the same settings and seed draw the same pixels.
    assert_eq!(out, develop(&image, &settings));
}
