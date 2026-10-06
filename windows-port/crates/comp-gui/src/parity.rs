//! The parameter parity audit: the macOS numbers as data, and the tests that hold this build to them.
//!
//! macOS keeps an adjustment's or an effect's parameters in a struct whose defaults are the document's
//! defaults and whose validation gives the range. Those two numbers decide what a document looks like
//! on both sides, so they are written here once, from the macOS sources, and the panels take their
//! slider ranges from this module: a range that drifts is then a failing test rather than a surprise.
//!
//! Sources, read line by line: Document/LayerEffects.swift (the six effects),
//! Document/ImageAdjustments.swift (exposure, Black & White, color balance, grain),
//! Document/Filters.swift (the filter settings and their defaults) and
//! Document/LayerAdjustment.swift (the adjustment kinds).

/// One parameter of an adjustment or an effect, as macOS defines it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Param {
    pub name: &'static str,
    /// The range macOS validates against, which is also the range its slider offers.
    pub min: f64,
    pub max: f64,
    /// The value macOS gives a parameter that has never been touched.
    pub default: f64,
    pub unit: &'static str,
}

const fn param(name: &'static str, min: f64, max: f64, default: f64, unit: &'static str) -> Param {
    Param { name, min, max, default, unit }
}

/// The six layer effects, from Document/LayerEffects.swift.
pub const EFFECTS: &[(&str, &[Param])] = &[
    (
        "Stroke",
        &[
            param("size", 0.0, 500.0, 4.0, "px"),
            param("opacity", 0.0, 1.0, 1.0, "0-1"),
            param("red", 0.0, 1.0, 0.0, "0-1"),
            param("green", 0.0, 1.0, 0.0, "0-1"),
            param("blue", 0.0, 1.0, 0.0, "0-1"),
        ],
    ),
    (
        "Shadow",
        &[
            param("angle", -360.0, 360.0, 90.0, "degrees"),
            param("distance", 0.0, 5000.0, 20.0, "px"),
            param("blur", 0.0, 500.0, 20.0, "px"),
            param("opacity", 0.0, 1.0, 0.5, "0-1"),
        ],
    ),
    (
        "Color Overlay",
        &[
            param("opacity", 0.0, 1.0, 1.0, "0-1"),
            param("red", 0.0, 1.0, 0.0, "0-1"),
            param("green", 0.0, 1.0, 0.0, "0-1"),
            param("blue", 0.0, 1.0, 0.0, "0-1"),
        ],
    ),
    (
        "Inner Shadow",
        &[
            param("angle", -360.0, 360.0, 90.0, "degrees"),
            param("distance", 0.0, 5000.0, 10.0, "px"),
            param("blur", 0.0, 500.0, 10.0, "px"),
            param("opacity", 0.0, 1.0, 0.5, "0-1"),
        ],
    ),
    (
        "Outer Glow",
        &[
            param("size", 0.0, 500.0, 20.0, "px"),
            param("opacity", 0.0, 1.0, 0.75, "0-1"),
        ],
    ),
    (
        "Inner Glow",
        &[
            param("size", 0.0, 500.0, 10.0, "px"),
            param("opacity", 0.0, 1.0, 0.75, "0-1"),
        ],
    ),
];

/// The adjustments, from Document/ImageAdjustments.swift and Document/Filters.swift.
pub const ADJUSTMENTS: &[(&str, &[Param])] = &[
    (
        "Exposure",
        &[
            param("exposure", -20.0, 20.0, 0.0, "stops"),
            param("offset", -0.5, 0.5, 0.0, "0-1"),
            param("gamma", 0.01, 9.99, 1.0, "ratio"),
        ],
    ),
    (
        "Levels",
        &[
            param("black", 0.0, 255.0, 0.0, "level"),
            param("gamma", 0.01, 9.99, 1.0, "ratio"),
            param("white", 0.0, 255.0, 255.0, "level"),
            param("output black", 0.0, 255.0, 0.0, "level"),
            param("output white", 0.0, 255.0, 255.0, "level"),
        ],
    ),
    (
        "Black & White",
        &[
            param("reds", -200.0, 300.0, 40.0, "%"),
            param("yellows", -200.0, 300.0, 60.0, "%"),
            param("greens", -200.0, 300.0, 40.0, "%"),
            param("cyans", -200.0, 300.0, 60.0, "%"),
            param("blues", -200.0, 300.0, 20.0, "%"),
            param("magentas", -200.0, 300.0, 80.0, "%"),
            // The macOS sheet gives these two as sliders, 0-360 and 0-100; this build edits the same
            // numbers through a colour picker, which covers the same range.
            param("tint hue", 0.0, 360.0, 40.0, "degrees"),
            param("tint saturation", 0.0, 100.0, 20.0, "%"),
        ],
    ),
    (
        "Color Balance",
        &[param("cyan-red", -100.0, 100.0, 0.0, "%")],
    ),
    (
        "Grain",
        &[
            param("amount", 0.0, 100.0, 25.0, "%"),
            param("size", 0.5, 20.0, 1.5, "px"),
            param("roughness", 0.0, 100.0, 50.0, "%"),
        ],
    ),
    // These three are filters in macOS (Document/Filters.swift) that this build also offers as
    // adjustment layers; the ranges are the ones its filter settings document.
    (
        "Gaussian Blur",
        &[param("radius", 0.1, 250.0, 1.0, "px")],
    ),
    (
        "Motion Blur",
        &[
            param("angle", -90.0, 90.0, 0.0, "degrees"),
            param("distance", 1.0, 2000.0, 10.0, "px"),
        ],
    ),
    (
        "Add Noise",
        &[param("amount", 0.1, 400.0, 10.0, "%")],
    ),
    (
        "Hue/Saturation",
        &[
            param("hue", -180.0, 180.0, 0.0, "degrees"),
            param("saturation", -100.0, 100.0, 0.0, "%"),
            param("lightness", -100.0, 100.0, 0.0, "%"),
        ],
    ),
];

/// The filters that have sliders, from the macOS sheet (UI/FilterSheet.swift) and the settings it
/// edits (Document/Filters.swift). The ranges are the ones that sheet gives each slider, and the
/// defaults are the ones the settings struct starts with.
///
/// Dither is not here: macOS's dither sheet drives a different parameter set (glow, dots, angle,
/// diffusion, density, contrast) from this build's (a style plus pixel size, levels, amount and tone),
/// so there is no parity to record and none is claimed. Remove Background's Basic quality has nothing
/// to set; its Advanced settings are the three below.
pub const FILTERS: &[(&str, &[Param])] = &[
    ("Gaussian Blur", &[param("radius", 0.1, 250.0, 1.0, "px")]),
    (
        "Motion Blur",
        &[
            param("angle", -90.0, 90.0, 0.0, "degrees"),
            param("distance", 1.0, 2000.0, 10.0, "px"),
        ],
    ),
    ("Add Noise", &[param("amount", 0.1, 400.0, 10.0, "%")]),
    (
        "Vignette",
        &[
            param("amount", 0.0, 100.0, 35.0, "%"),
            param("midpoint", 0.0, 100.0, 50.0, "%"),
            param("roundness", -100.0, 100.0, 100.0, ""),
            param("feather", 0.0, 100.0, 60.0, "%"),
            param("highlights", 0.0, 100.0, 25.0, "%"),
        ],
    ),
    (
        "Bloom/Glow",
        &[
            param("amount", 0.0, 100.0, 40.0, "%"),
            param("radius", 1.0, 150.0, 24.0, "px"),
        ],
    ),
    (
        "Tonal Contrast",
        &[
            param("amount", 0.0, 100.0, 50.0, "%"),
            param("shadows", -100.0, 100.0, 40.0, "%"),
            param("midtones", -100.0, 100.0, 60.0, "%"),
            param("highlights", -100.0, 100.0, 30.0, "%"),
            param("radius", 1.0, 100.0, 16.0, "px"),
        ],
    ),
    ("Lens Correction", &[param("remove distortion", -100.0, 100.0, 0.0, "")]),
    (
        "Remove Background (advanced)",
        &[
            param("refine", 0.0, 40.0, 12.0, "px"),
            param("contrast", 0.0, 100.0, 25.0, "%"),
            param("shift edge", -10.0, 10.0, 0.0, "px"),
        ],
    ),
];

/// The slider ranges the panels use, taken from the tables above so there is one source for them.
pub mod ranges {
    use std::ops::RangeInclusive;

    /// A range as RangeInclusive, the shape egui's sliders want.
    pub const fn of(pair: (f64, f64)) -> RangeInclusive<f64> {
        pair.0..=pair.1
    }

    pub const OPACITY: (f64, f64) = (0.0, 1.0);
    pub const STROKE_SIZE: (f64, f64) = (0.0, 500.0);
    pub const SHADOW_ANGLE: (f64, f64) = (-360.0, 360.0);
    pub const SHADOW_DISTANCE: (f64, f64) = (0.0, 5000.0);
    pub const SHADOW_BLUR: (f64, f64) = (0.0, 500.0);
    pub const GLOW_SIZE: (f64, f64) = (0.0, 500.0);
    pub const EXPOSURE: (f64, f64) = (-20.0, 20.0);
    pub const OFFSET: (f64, f64) = (-0.5, 0.5);
    pub const GAMMA: (f64, f64) = (0.01, 9.99);
    pub const LEVEL: (f64, f64) = (0.0, 255.0);
    pub const BLACK_WHITE_MIX: (f64, f64) = (-200.0, 300.0);
    pub const COLOR_BALANCE: (f64, f64) = (-100.0, 100.0);
    pub const GRAIN_AMOUNT: (f64, f64) = (0.0, 100.0);
    pub const GRAIN_SIZE: (f64, f64) = (0.5, 20.0);
    pub const GRAIN_ROUGHNESS: (f64, f64) = (0.0, 100.0);
    pub const HUE: (f64, f64) = (-180.0, 180.0);
    pub const PERCENT: (f64, f64) = (-100.0, 100.0);
}

/// The range a table entry records, or None when the parameter is not in the table.
pub fn range_of(table: &[(&str, &[Param])], group: &str, name: &str) -> Option<(f64, f64)> {
    let (_, params) = table.iter().find(|(title, _)| *title == group)?;
    let param = params.iter().find(|param| param.name == name)?;
    Some((param.min, param.max))
}

/// The default a table entry records, or None when the parameter is not in the table.
pub fn default_of(table: &[(&str, &[Param])], group: &str, name: &str) -> Option<f64> {
    let (_, params) = table.iter().find(|(title, _)| *title == group)?;
    params.iter().find(|param| param.name == name).map(|param| param.default)
}

#[cfg(test)]
mod tests {
    use super::*;
    use comp_core::effects::{
        ColorOverlayEffect, InnerGlowEffect, InnerShadowEffect, LayerEffects, OuterGlowEffect, ShadowEffect, StrokeEffect,
    };

    /// Asserts that a panel range is the range macOS validates against.
    fn assert_range(table: &[(&str, &[Param])], group: &str, name: &str, panel: (f64, f64)) {
        let recorded = range_of(table, group, name).unwrap_or_else(|| panic!("{group}/{name} is not in the table"));
        assert_eq!(panel, recorded, "{group}/{name}: the panel offers {panel:?}, macOS {recorded:?}");
    }

    #[test]
    fn the_panel_ranges_are_the_ranges_macos_validates_against() {
        assert_range(EFFECTS, "Stroke", "size", ranges::STROKE_SIZE);
        assert_range(EFFECTS, "Shadow", "angle", ranges::SHADOW_ANGLE);
        assert_range(EFFECTS, "Shadow", "distance", ranges::SHADOW_DISTANCE);
        assert_range(EFFECTS, "Shadow", "blur", ranges::SHADOW_BLUR);
        assert_range(EFFECTS, "Inner Shadow", "angle", ranges::SHADOW_ANGLE);
        assert_range(EFFECTS, "Inner Shadow", "distance", ranges::SHADOW_DISTANCE);
        assert_range(EFFECTS, "Inner Shadow", "blur", ranges::SHADOW_BLUR);
        assert_range(EFFECTS, "Outer Glow", "size", ranges::GLOW_SIZE);
        assert_range(EFFECTS, "Inner Glow", "size", ranges::GLOW_SIZE);
        assert_range(EFFECTS, "Stroke", "opacity", ranges::OPACITY);
        assert_range(EFFECTS, "Outer Glow", "opacity", ranges::OPACITY);

        assert_range(ADJUSTMENTS, "Exposure", "exposure", ranges::EXPOSURE);
        assert_range(ADJUSTMENTS, "Exposure", "offset", ranges::OFFSET);
        assert_range(ADJUSTMENTS, "Exposure", "gamma", ranges::GAMMA);
        assert_range(ADJUSTMENTS, "Levels", "black", ranges::LEVEL);
        assert_range(ADJUSTMENTS, "Levels", "white", ranges::LEVEL);
        assert_range(ADJUSTMENTS, "Levels", "output black", ranges::LEVEL);
        assert_range(ADJUSTMENTS, "Levels", "output white", ranges::LEVEL);
        assert_range(ADJUSTMENTS, "Black & White", "reds", ranges::BLACK_WHITE_MIX);
        assert_range(ADJUSTMENTS, "Color Balance", "cyan-red", ranges::COLOR_BALANCE);
        assert_range(ADJUSTMENTS, "Grain", "amount", ranges::GRAIN_AMOUNT);
        assert_range(ADJUSTMENTS, "Grain", "size", ranges::GRAIN_SIZE);
        assert_range(ADJUSTMENTS, "Grain", "roughness", ranges::GRAIN_ROUGHNESS);
        // The blur and noise adjustments take their ranges from the filter module, and the filter
        // module's own test holds those to what the engine clamps to.
        assert_eq!(crate::filters::RADIUS_RANGE, range_of(ADJUSTMENTS, "Gaussian Blur", "radius").expect("recorded"));
        assert_eq!(crate::filters::ANGLE_RANGE, range_of(ADJUSTMENTS, "Motion Blur", "angle").expect("recorded"));
        assert_eq!(
            crate::filters::DISTANCE_RANGE,
            range_of(ADJUSTMENTS, "Motion Blur", "distance").expect("recorded")
        );
        assert_eq!(crate::filters::AMOUNT_RANGE, range_of(ADJUSTMENTS, "Add Noise", "amount").expect("recorded"));
        assert_range(ADJUSTMENTS, "Hue/Saturation", "hue", ranges::HUE);
        assert_range(ADJUSTMENTS, "Hue/Saturation", "saturation", ranges::PERCENT);
        assert_range(ADJUSTMENTS, "Hue/Saturation", "lightness", ranges::PERCENT);
    }

    #[test]
    fn the_effects_this_build_creates_carry_the_macos_defaults() {
        // A default that differs renders the same document differently on the two sides.
        // A layer starts with no effects at all; what matters is what an effect looks like the moment
        // it is switched on, which is its own Default.
        let effects = LayerEffects::default();
        assert!(effects.stroke.is_none() && effects.shadow.is_none(), "a layer starts with no effects");
        let stroke = StrokeEffect::default();
        assert_eq!(stroke.size, default_of(EFFECTS, "Stroke", "size").expect("recorded"));
        assert_eq!(stroke.opacity, default_of(EFFECTS, "Stroke", "opacity").expect("recorded"));
        assert_eq!((stroke.red, stroke.green, stroke.blue), (0.0, 0.0, 0.0));

        let shadow = ShadowEffect::default();
        assert_eq!(shadow.angle, default_of(EFFECTS, "Shadow", "angle").expect("recorded"));
        assert_eq!(shadow.distance, default_of(EFFECTS, "Shadow", "distance").expect("recorded"));
        assert_eq!(shadow.blur, default_of(EFFECTS, "Shadow", "blur").expect("recorded"));
        assert_eq!(shadow.opacity, default_of(EFFECTS, "Shadow", "opacity").expect("recorded"));

        let inner = InnerShadowEffect::default();
        assert_eq!(inner.angle, default_of(EFFECTS, "Inner Shadow", "angle").expect("recorded"));
        assert_eq!(inner.distance, default_of(EFFECTS, "Inner Shadow", "distance").expect("recorded"));
        assert_eq!(inner.blur, default_of(EFFECTS, "Inner Shadow", "blur").expect("recorded"));
        assert_eq!(inner.opacity, default_of(EFFECTS, "Inner Shadow", "opacity").expect("recorded"));

        let overlay = ColorOverlayEffect::default();
        assert_eq!(overlay.opacity, default_of(EFFECTS, "Color Overlay", "opacity").expect("recorded"));
        assert_eq!((overlay.red, overlay.green, overlay.blue), (0.0, 0.0, 0.0));

        let outer = OuterGlowEffect::default();
        assert_eq!(outer.size, default_of(EFFECTS, "Outer Glow", "size").expect("recorded"));
        assert_eq!(outer.opacity, default_of(EFFECTS, "Outer Glow", "opacity").expect("recorded"));
        assert_eq!((outer.red, outer.green, outer.blue), (1.0, 1.0, 1.0), "macOS glows start white");

        let glow = InnerGlowEffect::default();
        assert_eq!(glow.size, default_of(EFFECTS, "Inner Glow", "size").expect("recorded"));
        assert_eq!(glow.opacity, default_of(EFFECTS, "Inner Glow", "opacity").expect("recorded"));
        assert_eq!((glow.red, glow.green, glow.blue), (1.0, 1.0, 1.0));
    }

    #[test]
    fn the_adjustments_this_build_creates_carry_the_macos_defaults() {
        use comp_core::adjustment::{Adjustment, AdjustmentKind, LevelRange, LevelsSettings};

        let hsv = Adjustment::new(AdjustmentKind::HueSaturation);
        assert_eq!(hsv.hue, default_of(ADJUSTMENTS, "Hue/Saturation", "hue").expect("recorded"));
        assert_eq!(hsv.saturation, default_of(ADJUSTMENTS, "Hue/Saturation", "saturation").expect("recorded"));
        assert_eq!(hsv.lightness, default_of(ADJUSTMENTS, "Hue/Saturation", "lightness").expect("recorded"));

        // Levels starts as the identity, and every number in it is the recorded default.
        let levels = LevelsSettings::default();
        let identity = LevelRange::default();
        assert_eq!(identity.black, default_of(ADJUSTMENTS, "Levels", "black").expect("recorded"));
        assert_eq!(identity.white, default_of(ADJUSTMENTS, "Levels", "white").expect("recorded"));
        assert_eq!(identity.gamma, default_of(ADJUSTMENTS, "Levels", "gamma").expect("recorded"));
        assert_eq!(identity.output_black, default_of(ADJUSTMENTS, "Levels", "output black").expect("recorded"));
        assert_eq!(identity.output_white, default_of(ADJUSTMENTS, "Levels", "output white").expect("recorded"));
        assert_eq!(levels.ranges.len(), 4, "a range per channel and the composite");

        let balance = comp_core::adjustment::ColorBalanceSettings::default();
        assert_eq!(balance.shadow_cyan_red, default_of(ADJUSTMENTS, "Color Balance", "cyan-red").expect("recorded"));
        assert_eq!(balance.mid_magenta_green, 0.0);
        assert_eq!(balance.highlight_yellow_blue, 0.0);
    }

    #[test]
    fn the_table_records_the_numbers_the_macos_sources_give() {
        // The table is data, so it can be checked against the sources it was read from: these are the
        // numbers written there, and a change to the table has to come with a change to this list.
        let recorded = [
            (EFFECTS, "Stroke", "size", 0.0, 500.0, 4.0),
            (EFFECTS, "Shadow", "angle", -360.0, 360.0, 90.0),
            (EFFECTS, "Shadow", "distance", 0.0, 5000.0, 20.0),
            (EFFECTS, "Shadow", "blur", 0.0, 500.0, 20.0),
            (EFFECTS, "Inner Shadow", "distance", 0.0, 5000.0, 10.0),
            (EFFECTS, "Outer Glow", "size", 0.0, 500.0, 20.0),
            (EFFECTS, "Inner Glow", "size", 0.0, 500.0, 10.0),
            (ADJUSTMENTS, "Exposure", "exposure", -20.0, 20.0, 0.0),
            (ADJUSTMENTS, "Exposure", "offset", -0.5, 0.5, 0.0),
            (ADJUSTMENTS, "Exposure", "gamma", 0.01, 9.99, 1.0),
            (ADJUSTMENTS, "Black & White", "reds", -200.0, 300.0, 40.0),
            (ADJUSTMENTS, "Black & White", "magentas", -200.0, 300.0, 80.0),
            (ADJUSTMENTS, "Black & White", "tint saturation", 0.0, 100.0, 20.0),
            (ADJUSTMENTS, "Color Balance", "cyan-red", -100.0, 100.0, 0.0),
            (ADJUSTMENTS, "Grain", "amount", 0.0, 100.0, 25.0),
            (ADJUSTMENTS, "Grain", "size", 0.5, 20.0, 1.5),
            (ADJUSTMENTS, "Grain", "roughness", 0.0, 100.0, 50.0),
        ];
        for (table, group, name, min, max, default) in recorded {
            let (_, params) = table.iter().find(|(title, _)| *title == group).expect("a group");
            let param = params.iter().find(|param| param.name == name).expect("a parameter");
            assert_eq!(
                (param.min, param.max, param.default),
                (min, max, default),
                "{group}/{name} drifted from the macOS source"
            );
            assert!(!param.unit.is_empty(), "{group}/{name} has no unit");
        }
    }

    #[test]
    fn every_recorded_parameter_has_a_usable_range_and_a_default_inside_it() {
        for (group, params) in EFFECTS.iter().chain(ADJUSTMENTS.iter()).chain(FILTERS.iter()) {
            assert!(!params.is_empty(), "{group} records no parameters");
            for param in *params {
                assert!(param.min < param.max, "{group}/{}: empty range", param.name);
                assert!(
                    (param.min..=param.max).contains(&param.default),
                    "{group}/{}: default {} is outside {:?}",
                    param.name,
                    param.default,
                    (param.min, param.max)
                );
            }
        }
    }
}

#[cfg(test)]
mod filter_tests {
    use super::*;

    /// Asserts that a dialog range is the range the macOS sheet offers for that slider.
    fn assert_filter_range(group: &str, name: &str, panel: (f64, f64)) {
        let recorded = range_of(FILTERS, group, name).unwrap_or_else(|| panic!("{group}/{name} is not recorded"));
        assert_eq!(panel, recorded, "{group}/{name}: the dialog offers {panel:?}, macOS {recorded:?}");
    }

    #[test]
    fn the_filter_dialogs_offer_the_ranges_the_macos_sheet_offers() {
        assert_filter_range("Gaussian Blur", "radius", crate::filters::RADIUS_RANGE);
        assert_filter_range("Motion Blur", "angle", crate::filters::ANGLE_RANGE);
        assert_filter_range("Motion Blur", "distance", crate::filters::DISTANCE_RANGE);
        assert_filter_range("Add Noise", "amount", crate::filters::AMOUNT_RANGE);
        assert_filter_range("Vignette", "amount", crate::filters::VIGNETTE_AMOUNT_RANGE);
        assert_filter_range("Vignette", "midpoint", crate::filters::VIGNETTE_MIDPOINT_RANGE);
        assert_filter_range("Vignette", "roundness", crate::filters::VIGNETTE_ROUNDNESS_RANGE);
        assert_filter_range("Vignette", "feather", crate::filters::VIGNETTE_FEATHER_RANGE);
        assert_filter_range("Vignette", "highlights", crate::filters::VIGNETTE_HIGHLIGHTS_RANGE);
        assert_filter_range("Bloom/Glow", "amount", crate::filters::BLOOM_AMOUNT_RANGE);
        assert_filter_range("Bloom/Glow", "radius", crate::filters::BLOOM_RADIUS_RANGE);
        assert_filter_range("Tonal Contrast", "amount", crate::filters::TONAL_AMOUNT_RANGE);
        assert_filter_range("Tonal Contrast", "radius", crate::filters::TONAL_RADIUS_RANGE);
        assert_filter_range("Tonal Contrast", "shadows", crate::filters::TONAL_STRENGTH_RANGE);
        assert_filter_range("Tonal Contrast", "midtones", crate::filters::TONAL_STRENGTH_RANGE);
        assert_filter_range("Tonal Contrast", "highlights", crate::filters::TONAL_STRENGTH_RANGE);
        assert_filter_range("Lens Correction", "remove distortion", crate::filters::DISTORTION_RANGE);
    }

    #[test]
    fn the_filter_settings_this_build_starts_with_are_the_macos_defaults() {
        // comp-render owns these numbers; the audit checks them and reports a difference rather than
        // reaching into another crate to change one.
        let settings = comp_render::filters::FilterSettings::default();
        let recorded = [
            ("Gaussian Blur", "radius", settings.radius),
            ("Motion Blur", "angle", settings.angle),
            ("Motion Blur", "distance", settings.distance),
            ("Add Noise", "amount", settings.amount),
            ("Vignette", "amount", settings.vignette_amount),
            ("Vignette", "midpoint", settings.vignette_midpoint),
            ("Vignette", "roundness", settings.vignette_roundness),
            ("Vignette", "feather", settings.vignette_feather),
            ("Vignette", "highlights", settings.vignette_highlights),
            ("Bloom/Glow", "amount", settings.bloom_amount),
            ("Bloom/Glow", "radius", settings.bloom_radius),
            ("Tonal Contrast", "amount", settings.tonal_amount),
            ("Tonal Contrast", "shadows", settings.tonal_shadows),
            ("Tonal Contrast", "midtones", settings.tonal_midtones),
            ("Tonal Contrast", "highlights", settings.tonal_highlights),
            ("Tonal Contrast", "radius", settings.tonal_radius),
            ("Lens Correction", "remove distortion", settings.distortion),
        ];
        for (group, name, value) in recorded {
            let expected = default_of(FILTERS, group, name).expect("recorded");
            assert_eq!(value, expected, "{group}/{name}: comp-render starts at {value}, macOS at {expected}");
        }
    }

    #[test]
    fn the_dither_parameters_are_this_builds_own_and_are_not_claimed_as_macos_ones() {
        // macOS dithers with glow, dots, angle, diffusion, density and contrast; this build dithers
        // with a style and four numbers. Recording that honestly means claiming no parity for it.
        assert!(FILTERS.iter().all(|(title, _)| *title != "Dither"), "Dither has no macOS parity to claim");
        assert!(crate::filters::DITHER_PIXEL_RANGE.0 < crate::filters::DITHER_PIXEL_RANGE.1);
        assert!(crate::filters::DITHER_LEVELS_RANGE.0 < crate::filters::DITHER_LEVELS_RANGE.1);
        assert!(crate::filters::DITHER_PERCENT_RANGE.0 < crate::filters::DITHER_PERCENT_RANGE.1);
        assert!(crate::filters::DITHER_TONE_RANGE.0 < crate::filters::DITHER_TONE_RANGE.1);
    }

    #[test]
    fn the_remove_background_settings_are_the_advanced_ones_the_sheet_shows() {
        // Basic has no settings at all, which is why the dialog only offers these when Advanced is on.
        for (name, range) in [("refine", (0.0, 40.0)), ("contrast", (0.0, 100.0)), ("shift edge", (-10.0, 10.0))] {
            assert_eq!(range_of(FILTERS, "Remove Background (advanced)", name), Some(range), "{name}");
        }
    }
}
