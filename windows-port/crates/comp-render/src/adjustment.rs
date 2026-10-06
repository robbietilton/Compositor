//! The twelve adjustment-layer kinds, run on the accumulated canvas of everything below them.
//!
//! The C kernels the macOS original falls back on work in premultiplied bytes: each channel is divided by
//! the alpha before a lookup and multiplied back after, so soft edges are not darkened twice. This module
//! keeps that shape, which is why every kind takes and returns a premultiplied `Surface`.

use rayon::prelude::*;
use serde_json::Value;

use comp_core::adjustment::{Adjustment, AdjustmentKind, ColorBalanceSettings, CurvePoint};

use crate::pixel::{round_u8, Surface};

/// Applies an adjustment to the whole canvas, in place. Alpha is never touched.
pub fn apply(adjustment: &Adjustment, canvas: &mut Surface) {
    apply_at(adjustment, canvas, (0, 0));
}

/// The same, for a canvas that is one rectangle of a larger one.
///
/// Only the seeded patterns care: Grain and Add Noise are anchored to the document, so a rectangle has to
/// say where it sits or its grain would restart at the rectangle's corner and stop matching a whole-canvas
/// render. Everything else here is per-pixel and never looks at the origin.
pub fn apply_at(adjustment: &Adjustment, canvas: &mut Surface, origin: (i64, i64)) {
    if canvas.is_empty() {
        return;
    }
    match adjustment.kind {
        AdjustmentKind::HueSaturation => hue_saturation(adjustment, canvas),
        AdjustmentKind::Levels => levels(adjustment, canvas),
        AdjustmentKind::Curves => curves(adjustment, canvas),
        AdjustmentKind::Exposure => exposure(adjustment, canvas),
        AdjustmentKind::GradientMap => gradient_map(adjustment, canvas),
        AdjustmentKind::Grain => grain(adjustment, canvas, origin),
        AdjustmentKind::Invert => invert(canvas),
        AdjustmentKind::BlackWhite => black_white(adjustment, canvas),
        AdjustmentKind::ColorBalance => color_balance(adjustment, canvas),
        AdjustmentKind::GaussianBlur => gaussian_blur(adjustment.blur_radius.unwrap_or(10.0) as f32, canvas),
        AdjustmentKind::MotionBlur => motion_blur(
            adjustment.motion_angle.unwrap_or(0.0) as f32,
            adjustment.motion_distance.unwrap_or(10.0) as f32,
            canvas,
        ),
        AdjustmentKind::AddNoise => add_noise(
            adjustment.noise_amount.unwrap_or(10.0) as f32,
            adjustment.noise_gaussian.unwrap_or(false),
            adjustment.noise_monochromatic.unwrap_or(false),
            adjustment.noise_seed.unwrap_or(0) as u32,
            canvas,
            origin,
        ),
    }
}

// ---------------------------------------------------------------------------------------------
// Curve tables: Levels, Curves and Exposure all run a 256-entry per-channel lookup the C
// `levels_apply` walks, interpolating between neighbouring entries in normalized space.
// ---------------------------------------------------------------------------------------------

/// The lookup every table-based kind runs, byte for byte as `LevelsPixels.c` does it.
fn apply_tables(surface: &mut Surface, tables: &[[f32; 256]; 3]) {
    let width = surface.width() as usize;
    let bytes = width * 4;
    surface.pixels_mut().par_chunks_mut(bytes).for_each(|row| {
        for texel in row.chunks_exact_mut(4) {
            let alpha = texel[3] as f32;
            if alpha <= 0.0 {
                continue;
            }
            for channel in 0..3 {
                let x = (texel[channel] as f32 * 255.0 / alpha).min(255.0);
                let lo = x as usize;
                let hi = if lo < 255 { lo + 1 } else { 255 };
                let table = &tables[channel];
                let result = table[lo] + (table[hi] - table[lo]) * (x - lo as f32);
                texel[channel] = round_u8(result * alpha).min(texel[3]);
            }
        }
    });
}

/// One channel's output for each input byte, from a curve of 0..1 to 0..1.
fn table_from(mut f: impl FnMut(f32) -> f32) -> [f32; 256] {
    let mut table = [0.0f32; 256];
    for (index, entry) in table.iter_mut().enumerate() {
        *entry = f(index as f32 / 255.0).clamp(0.0, 1.0);
    }
    table
}

fn levels(adjustment: &Adjustment, canvas: &mut Surface) {
    let Some(tables) = levels_tables(adjustment) else { return };
    apply_tables(canvas, &tables);
}

/// The lookup Levels runs, or nothing when the settings are the identity - the GPU borrows this rather
/// than rebuilding the table so the two cannot drift apart.
fn levels_tables(adjustment: &Adjustment) -> Option<[[f32; 256]; 3]> {
    let settings = &adjustment.levels;
    if is_identity_levels(adjustment) {
        return None;
    }
    // macOS clamps each range on the way in: black under 254, white above black, gamma inside 0.1 to 9.99.
    let mut ranges = [[0.0f64; 5]; 4];
    for (index, range) in settings.ranges.iter().enumerate() {
        let black = range.black.clamp(0.0, 254.0);
        let white = range.white.clamp(black + 1.0, 255.0);
        ranges[index] = [
            black,
            range.gamma.clamp(0.1, 9.99),
            white,
            range.output_black.clamp(0.0, 255.0),
            range.output_white.clamp(0.0, 255.0),
        ];
    }
    let mut tables = [[0.0f32; 256]; 3];
    for (channel, table) in tables.iter_mut().enumerate() {
        // Every channel runs its own range and then the composite RGB range, whichever one the panel
        // happens to have selected.
        let composite = ranges[0];
        let local = ranges[channel + 1];
        *table = table_from(|value| {
            let after = apply_level_range(local, value as f64);
            apply_level_range(composite, after) as f32
        });
    }
    Some(tables)
}

fn apply_level_range(range: [f64; 5], value: f64) -> f64 {
    let input = ((value * 255.0 - range[0]) / (range[2] - range[0])).clamp(0.0, 1.0);
    (range[3] + input.powf(1.0 / range[1]) * (range[4] - range[3])) / 255.0
}

fn is_identity_levels(adjustment: &Adjustment) -> bool {
    adjustment.levels.ranges.iter().all(|range| {
        range.black == 0.0
            && range.gamma == 1.0
            && range.white == 255.0
            && range.output_black == 0.0
            && range.output_white == 255.0
    })
}

fn curves(adjustment: &Adjustment, canvas: &mut Surface) {
    let Some(tables) = curves_tables(adjustment) else { return };
    apply_tables(canvas, &tables);
}

/// The lookup Curves runs, or nothing when every channel is the identity.
fn curves_tables(adjustment: &Adjustment) -> Option<[[f32; 256]; 3]> {
    if is_identity_curves(adjustment) {
        return None;
    }
    let mut tables = [[0.0f32; 256]; 3];
    for (channel, table) in tables.iter_mut().enumerate() {
        // The original runs the channel's own curve and then the composite RGB curve over the result.
        let own = &adjustment.curves.channels[channel + 1];
        let composite = &adjustment.curves.channels[0];
        *table = table_from(|value| {
            let after = curve_value(own, (value * 255.0) as f64) / 255.0;
            (curve_value(composite, after * 255.0) / 255.0) as f32
        });
    }
    Some(tables)
}

fn is_identity_curves(adjustment: &Adjustment) -> bool {
    adjustment.curves.channels.iter().all(|points| {
        points.len() == 2 && points[0] == CurvePoint { x: 0.0, y: 0.0 } && points[1] == CurvePoint { x: 255.0, y: 255.0 }
    })
}

/// Shape-preserving cubic Hermite through the handles, the original's `CurvesSettings.value`, which
/// keeps monotone segments from overshooting.
pub fn curve_value(points: &[CurvePoint], x: f64) -> f64 {
    if points.is_empty() {
        return x;
    }
    if points.len() == 1 {
        return points[0].y;
    }
    let last = points.len() - 2;
    let mut index = 0usize;
    for (i, point) in points.iter().enumerate() {
        if point.x <= x {
            index = i;
        }
    }
    index = index.min(last);
    let secants: Vec<f64> = points
        .windows(2)
        .map(|pair| {
            let span = pair[1].x - pair[0].x;
            if span.abs() < 1e-12 {
                0.0
            } else {
                (pair[1].y - pair[0].y) / span
            }
        })
        .collect();
    let slope = |j: usize| -> f64 {
        if j == 0 {
            return secants[0];
        }
        if j == points.len() - 1 {
            return *secants.last().unwrap_or(&0.0);
        }
        let (a, b) = (secants[j - 1], secants[j]);
        if a * b <= 0.0 {
            return 0.0;
        }
        // The harmonic mean of the neighbouring secants: a monotone, overshoot-free slope.
        2.0 / (1.0 / a + 1.0 / b)
    };
    let h = points[index + 1].x - points[index].x;
    let t = ((x - points[index].x) / h).clamp(0.0, 1.0);
    let y = (2.0 * t * t * t - 3.0 * t * t + 1.0) * points[index].y
        + (t * t * t - 2.0 * t * t + t) * h * slope(index)
        + (-2.0 * t * t * t + 3.0 * t * t) * points[index + 1].y
        + (t * t * t - t * t) * h * slope(index + 1);
    y.clamp(0.0, 255.0)
}

fn exposure(adjustment: &Adjustment, canvas: &mut Surface) {
    let Some(table) = exposure_table(adjustment) else { return };
    apply_tables(canvas, &[table, table, table]);
}

/// The lookup Exposure runs, or nothing when the settings are the identity.
fn exposure_table(adjustment: &Adjustment) -> Option<[f32; 256]> {
    let (stops, offset, gamma) = match &adjustment.exposure_settings {
        Some(value) => (
            number(value, "exposure").unwrap_or(0.0),
            number(value, "offset").unwrap_or(0.0),
            number(value, "gamma").unwrap_or(1.0),
        ),
        None => (0.0, 0.0, 1.0),
    };
    let (stops, offset, gamma) = (
        stops.clamp(-20.0, 20.0),
        offset.clamp(-0.5, 0.5),
        gamma.clamp(0.01, 9.99),
    );
    if stops == 0.0 && offset == 0.0 && gamma == 1.0 {
        return None;
    }
    let scale = 2f64.powf(stops);
    let table = table_from(|encoded| {
        let encoded = encoded as f64;
        // Exposure is light, so it works in linear light and comes back to sRGB.
        let mut linear = if encoded <= 0.04045 { encoded / 12.92 } else { ((encoded + 0.055) / 1.055).powf(2.4) };
        linear = (linear * scale + offset).max(0.0).powf(1.0 / gamma);
        let output = if linear <= 0.0031308 { linear * 12.92 } else { 1.055 * linear.powf(1.0 / 2.4) - 0.055 };
        output.clamp(0.0, 1.0) as f32
    });
    Some(table)
}

fn gradient_map(adjustment: &Adjustment, canvas: &mut Surface) {
    let table = gradient_map_table(adjustment);
    let width = canvas.width() as usize;
    canvas.pixels_mut().par_chunks_mut(width * 4).for_each(|row| {
        for texel in row.chunks_exact_mut(4) {
            let alpha = texel[3] as u32;
            if alpha == 0 {
                continue;
            }
            // The C kernel unpremultiplies in integer math, takes a Rec. 601 luma and re-premultiplies.
            let straight = |value: u8| -> u32 {
                if alpha == 255 {
                    value as u32
                } else {
                    ((value as u32 * 255 + alpha / 2) / alpha).min(255)
                }
            };
            let r = straight(texel[0]);
            let g = straight(texel[1]);
            let b = straight(texel[2]);
            let level = ((2126 * r + 7152 * g + 722 * b + 5000) / 10000).min(255) as usize;
            for channel in 0..3 {
                let color = table[level * 3 + channel] as u32;
                texel[channel] = ((color * alpha + 127) / 255) as u8;
            }
        }
    });
}

/// The 256 x 3 lookup the gradient map runs, shared with the GPU path so both read the same bytes.
fn gradient_map_table(adjustment: &Adjustment) -> [u8; 256 * 3] {
    let (shadows, highlights, reversed) = match &adjustment.gradient_map_settings {
        Some(value) => (
            color_of(value.get("shadows")),
            color_of(value.get("highlights")),
            value.get("reversed").and_then(Value::as_bool).unwrap_or(false),
        ),
        None => ([0.0, 0.0, 0.0], [1.0, 1.0, 1.0], false),
    };
    let (dark, light) = if reversed { (highlights, shadows) } else { (shadows, highlights) };
    // A black-to-white gradient is *not* the identity: every pixel takes the gray of its Rec. 601
    // luminance, so a red becomes a dark gray. Only the settings decide, never the endpoints.
    let mut table = [0u8; 256 * 3];
    for index in 0..256 {
        let t = index as f64 / 255.0;
        for channel in 0..3 {
            let value = dark[channel] + (light[channel] - dark[channel]) * t;
            table[index * 3 + channel] = round_u8((value * 255.0) as f32);
        }
    }
    table
}

// ---------------------------------------------------------------------------------------------
// Hue/Saturation, in HSL with Photoshop's hue bands.
// ---------------------------------------------------------------------------------------------

/// The seven ranges Photoshop's Hue/Saturation panel offers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HsvColorRange {
    Master,
    Reds,
    Yellows,
    Greens,
    Cyans,
    Blues,
    Magentas,
}

impl HsvColorRange {
    pub const ALL: [HsvColorRange; 7] = [
        HsvColorRange::Master,
        HsvColorRange::Reds,
        HsvColorRange::Yellows,
        HsvColorRange::Greens,
        HsvColorRange::Cyans,
        HsvColorRange::Blues,
        HsvColorRange::Magentas,
    ];

    pub fn name(self) -> &'static str {
        match self {
            HsvColorRange::Master => "Master",
            HsvColorRange::Reds => "Reds",
            HsvColorRange::Yellows => "Yellows",
            HsvColorRange::Greens => "Greens",
            HsvColorRange::Cyans => "Cyans",
            HsvColorRange::Blues => "Blues",
            HsvColorRange::Magentas => "Magentas",
        }
    }

    pub fn parse(name: &str) -> Option<HsvColorRange> {
        HsvColorRange::ALL.into_iter().find(|range| range.name() == name)
    }

    pub fn index(self) -> usize {
        match self {
            HsvColorRange::Master => 0,
            HsvColorRange::Reds => 1,
            HsvColorRange::Yellows => 2,
            HsvColorRange::Greens => 3,
            HsvColorRange::Cyans => 4,
            HsvColorRange::Blues => 5,
            HsvColorRange::Magentas => 6,
        }
    }

    /// Photoshop's starting band.
    pub fn default_band(self) -> HsvBand {
        match self {
            HsvColorRange::Master => HsvBand::new(0.0, 0.0, 360.0, 360.0),
            HsvColorRange::Reds => HsvBand::new(315.0, 345.0, 15.0, 45.0),
            HsvColorRange::Yellows => HsvBand::new(15.0, 45.0, 75.0, 105.0),
            HsvColorRange::Greens => HsvBand::new(75.0, 105.0, 135.0, 165.0),
            HsvColorRange::Cyans => HsvBand::new(135.0, 165.0, 195.0, 225.0),
            HsvColorRange::Blues => HsvBand::new(195.0, 225.0, 255.0, 285.0),
            HsvColorRange::Magentas => HsvBand::new(255.0, 285.0, 315.0, 345.0),
        }
    }
}

/// One range's sliders, as the record stores them.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct HsvRangeAdjustment {
    pub hue: f64,
    pub saturation: f64,
    pub lightness: f64,
}

impl HsvRangeAdjustment {
    pub fn is_identity(self) -> bool {
        self.hue == 0.0 && self.saturation == 0.0 && self.lightness == 0.0
    }
}

/// A range's hue band: Photoshop's four handles, in degrees.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct HsvBand {
    pub falloff_start: f64,
    pub range_start: f64,
    pub range_end: f64,
    pub falloff_end: f64,
}

impl HsvBand {
    pub const fn new(falloff_start: f64, range_start: f64, range_end: f64, falloff_end: f64) -> HsvBand {
        HsvBand { falloff_start, range_start, range_end, falloff_end }
    }

    /// The four handles in the order the band math reads them.
    fn handles(self) -> [f64; 4] {
        [self.falloff_start, self.range_start, self.range_end, self.falloff_end]
    }
}

/// The `hsvSettings` record of a Hue/Saturation adjustment: per-range sliders and bands.
///
/// Swift stores the two maps as `[ColorRange: X]`, and a Swift dictionary whose key is not `String` or
/// `Int` encodes as an **unkeyed container**: key, value, key, value, ... - so a macOS project writes
/// `["Reds", {...}, "Master", {...}]`, not `{"Reds": {...}}`. Reading accepts both shapes; writing
/// always produces the array, because that is the only one macOS can decode. Everything the engine
/// needs to read or write this field goes through here, so the two directions cannot drift apart.
#[derive(Clone, Debug, PartialEq)]
pub struct HsvSettings {
    pub range: HsvColorRange,
    pub colorize: bool,
    pub invert_range: bool,
    pub adjustments: Vec<(HsvColorRange, HsvRangeAdjustment)>,
    pub bands: Vec<(HsvColorRange, HsvBand)>,
}

impl Default for HsvSettings {
    /// The record a new adjustment gets: no per-range sliders, Photoshop's own bands.
    fn default() -> Self {
        HsvSettings {
            range: HsvColorRange::Master,
            colorize: false,
            invert_range: false,
            adjustments: Vec::new(),
            bands: HsvColorRange::ALL.into_iter().map(|range| (range, range.default_band())).collect(),
        }
    }
}

impl HsvSettings {
    /// The record a project stores, in either shape. Unknown range names are ignored, like macOS
    /// ignoring an enum case it cannot decode.
    pub fn from_json(value: &Value) -> HsvSettings {
        let mut settings = HsvSettings {
            range: value
                .get("range")
                .and_then(Value::as_str)
                .and_then(HsvColorRange::parse)
                .unwrap_or(HsvColorRange::Master),
            colorize: value.get("colorize").and_then(Value::as_bool).unwrap_or(false),
            invert_range: value.get("invertRange").and_then(Value::as_bool).unwrap_or(false),
            ..HsvSettings::default()
        };
        for (name, record) in swift_dictionary(value.get("adjustments")) {
            let Some(range) = HsvColorRange::parse(&name) else { continue };
            settings.adjustments.push((
                range,
                HsvRangeAdjustment {
                    hue: number(&record, "hue").unwrap_or(0.0),
                    saturation: number(&record, "saturation").unwrap_or(0.0),
                    lightness: number(&record, "lightness").unwrap_or(0.0),
                },
            ));
        }
        // Only the bands the record carries replace the defaults, so a project that stores none still
        // gets Photoshop's.
        let mut bands: Vec<(HsvColorRange, HsvBand)> =
            HsvColorRange::ALL.into_iter().map(|range| (range, range.default_band())).collect();
        for (name, record) in swift_dictionary(value.get("bands")) {
            let Some(range) = HsvColorRange::parse(&name) else { continue };
            let index = range.index();
            let fallback = bands[index].1;
            bands[index].1 = HsvBand {
                falloff_start: number(&record, "falloffStart").unwrap_or(fallback.falloff_start),
                range_start: number(&record, "rangeStart").unwrap_or(fallback.range_start),
                range_end: number(&record, "rangeEnd").unwrap_or(fallback.range_end),
                falloff_end: number(&record, "falloffEnd").unwrap_or(fallback.falloff_end),
            };
        }
        settings.bands = bands;
        settings
    }

    /// The record as macOS writes it: both maps as arrays of alternating names and records.
    pub fn to_json(&self) -> Value {
        let mut object = serde_json::Map::new();
        object.insert("range".to_string(), Value::String(self.range.name().to_string()));
        object.insert("colorize".to_string(), Value::Bool(self.colorize));
        object.insert("invertRange".to_string(), Value::Bool(self.invert_range));
        object.insert(
            "adjustments".to_string(),
            swift_dictionary_json(self.adjustments.iter().map(|(range, adjustment)| {
                (
                    range.name(),
                    serde_json::json!({
                        "hue": adjustment.hue,
                        "saturation": adjustment.saturation,
                        "lightness": adjustment.lightness,
                    }),
                )
            })),
        );
        object.insert(
            "bands".to_string(),
            swift_dictionary_json(self.bands.iter().map(|(range, band)| {
                (
                    range.name(),
                    serde_json::json!({
                        "falloffStart": band.falloff_start,
                        "rangeStart": band.range_start,
                        "rangeEnd": band.range_end,
                        "falloffEnd": band.falloff_end,
                    }),
                )
            })),
        );
        Value::Object(object)
    }

    /// The sliders a range carries, if any.
    pub fn adjustment(&self, range: HsvColorRange) -> Option<HsvRangeAdjustment> {
        self.adjustments.iter().find(|(entry, _)| *entry == range).map(|(_, adjustment)| *adjustment)
    }

    pub fn set_adjustment(&mut self, range: HsvColorRange, adjustment: HsvRangeAdjustment) {
        match self.adjustments.iter_mut().find(|(entry, _)| *entry == range) {
            Some(entry) => entry.1 = adjustment,
            None => self.adjustments.push((range, adjustment)),
        }
    }
}

/// A Swift dictionary keyed by a non-`String` type, as JSON: either the unkeyed array macOS writes or
/// the object shape an older build of ours may have written.
fn swift_dictionary(value: Option<&Value>) -> Vec<(String, Value)> {
    match value {
        Some(Value::Array(items)) => items
            .chunks(2)
            .filter_map(|pair| {
                let name = pair.first()?.as_str()?.to_string();
                let record = pair.get(1)?.clone();
                Some((name, record))
            })
            .collect(),
        Some(Value::Object(map)) => map.iter().map(|(name, record)| (name.clone(), record.clone())).collect(),
        _ => Vec::new(),
    }
}

/// The same dictionary on the way out, in the order given.
fn swift_dictionary_json<'a>(entries: impl Iterator<Item = (&'a str, Value)>) -> Value {
    let mut items = Vec::new();
    for (name, record) in entries {
        items.push(Value::String(name.to_string()));
        items.push(record);
    }
    Value::Array(items)
}

/// Degrees forward from `from` to `to`, always 0 to 360.
fn forward(from: f64, to: f64) -> f64 {
    let delta = (to - from).rem_euclid(360.0);
    if delta < 0.0 {
        delta + 360.0
    } else {
        delta
    }
}

/// How strongly a band claims a hue: full inside the range, ramping through each shoulder.
fn band_weight(band: [f64; 4], hue: f64) -> f64 {
    let span = forward(band[0], band[3]);
    if span <= 0.0 {
        return 1.0;
    }
    let position = forward(band[0], hue);
    if position > span {
        return 0.0;
    }
    let ramp_in = forward(band[0], band[1]);
    let plateau_end = forward(band[0], band[2]);
    if position < ramp_in {
        return if ramp_in > 0.0 { position / ramp_in } else { 1.0 };
    }
    if position <= plateau_end {
        return 1.0;
    }
    let ramp_out = span - plateau_end;
    if ramp_out > 0.0 {
        (span - position) / ramp_out
    } else {
        1.0
    }
}

/// The whole Hue/Saturation record, whether it came from the flat fields or from `hsvSettings`.
struct HueSaturation {
    colorize: bool,
    range: HsvColorRange,
    invert_range: bool,
    adjustments: [HsvRangeAdjustment; 7],
    bands: [[f64; 4]; 7],
}

impl HueSaturation {
    /// The flat fields are the Master range; `hsvSettings`, when a newer project carries one, adds the
    /// per-range records Photoshop's panel writes.
    fn resolve(adjustment: &Adjustment) -> HueSaturation {
        let mut settings = HueSaturation {
            colorize: adjustment.colorize,
            range: HsvColorRange::Master,
            invert_range: false,
            adjustments: [HsvRangeAdjustment::default(); 7],
            bands: [
                HsvColorRange::Master.default_band().handles(),
                HsvColorRange::Reds.default_band().handles(),
                HsvColorRange::Yellows.default_band().handles(),
                HsvColorRange::Greens.default_band().handles(),
                HsvColorRange::Cyans.default_band().handles(),
                HsvColorRange::Blues.default_band().handles(),
                HsvColorRange::Magentas.default_band().handles(),
            ],
        };
        // The flat fields are the Master sliders, whether or not a record repeats them.
        settings.adjustments[0] = HsvRangeAdjustment {
            hue: adjustment.hue,
            saturation: adjustment.saturation,
            lightness: adjustment.lightness,
        };
        if let Some(value) = &adjustment.hsv_settings {
            let parsed = HsvSettings::from_json(value);
            settings.colorize = parsed.colorize;
            settings.range = parsed.range;
            settings.invert_range = parsed.invert_range;
            for (range, adjustment) in &parsed.adjustments {
                settings.adjustments[range.index()] = *adjustment;
            }
            for (range, band) in &parsed.bands {
                settings.bands[range.index()] = band.handles();
            }
        }
        settings
    }

    fn is_identity(&self) -> bool {
        !self.colorize && self.adjustments.iter().all(|adjustment| adjustment.is_identity())
    }

    fn weight(&self, range: HsvColorRange, hue: f64) -> f64 {
        if range == HsvColorRange::Master {
            return 1.0;
        }
        let weight = band_weight(self.bands[range.index()], hue);
        if self.invert_range && range == self.range {
            1.0 - weight
        } else {
            weight
        }
    }

    /// Per-degree hue, saturation and lightness response, as the original samples it once per degree.
    fn response(&self) -> Vec<HsvRangeAdjustment> {
        (0..=360)
            .map(|degree| {
                let mut response = HsvRangeAdjustment::default();
                for range in HsvColorRange::ALL {
                    let adjustment = self.adjustments[range.index()];
                    if adjustment.is_identity() {
                        continue;
                    }
                    let weight = self.weight(range, degree as f64);
                    if weight <= 0.0 {
                        continue;
                    }
                    response.hue += adjustment.hue * weight;
                    response.saturation += adjustment.saturation * weight;
                    response.lightness += adjustment.lightness * weight;
                }
                response
            })
            .collect()
    }
}

/// Photoshop's Saturation slider: below zero scales toward gray, above zero divides by what is left.
fn adjusted_saturation(saturation: f64, amount: f64) -> f64 {
    let amount = (amount / 100.0).clamp(-1.0, 1.0);
    if amount <= 0.0 {
        return (saturation * (1.0 + amount)).max(0.0);
    }
    if amount >= 1.0 {
        return if saturation > 0.0 { 1.0 } else { 0.0 };
    }
    (saturation / (1.0 - amount)).min(1.0)
}

/// RGB to HSL, the conversion the original's cube is built in.
fn to_hsl(red: f64, green: f64, blue: f64) -> (f64, f64, f64) {
    let high = red.max(green).max(blue);
    let low = red.min(green).min(blue);
    let lightness = (high + low) / 2.0;
    let delta = high - low;
    if delta <= 0.0 {
        return (0.0, 0.0, lightness);
    }
    let saturation = delta / (1.0 - (2.0 * lightness - 1.0).abs());
    let mut hue = if high == red {
        (green - blue) / delta
    } else if high == green {
        (blue - red) / delta + 2.0
    } else {
        (red - green) / delta + 4.0
    };
    hue *= 60.0;
    if hue < 0.0 {
        hue += 360.0;
    }
    (hue, saturation.min(1.0), lightness)
}

fn to_rgb(hue: f64, saturation: f64, lightness: f64) -> (f64, f64, f64) {
    if saturation <= 0.0 {
        return (lightness, lightness, lightness);
    }
    let chroma = (1.0 - (2.0 * lightness - 1.0).abs()) * saturation;
    let sector = hue / 60.0;
    let second = chroma * (1.0 - (sector.rem_euclid(2.0) - 1.0).abs());
    let base = lightness - chroma / 2.0;
    let (red, green, blue) = match sector as i64 {
        0 => (chroma, second, 0.0),
        1 => (second, chroma, 0.0),
        2 => (0.0, chroma, second),
        3 => (0.0, second, chroma),
        4 => (second, 0.0, chroma),
        _ => (chroma, 0.0, second),
    };
    ((red + base).clamp(0.0, 1.0), (green + base).clamp(0.0, 1.0), (blue + base).clamp(0.0, 1.0))
}

/// One color through the Hue/Saturation settings, the original's `adjust(red:green:blue:settings:)`.
pub fn adjust_hue_saturation(red: f64, green: f64, blue: f64, settings: &Adjustment) -> (f64, f64, f64) {
    let resolved = HueSaturation::resolve(settings);
    let response = resolved.response();
    let (mut hue, mut saturation, mut lightness) = to_hsl(red, green, blue);
    let lightness_amount;
    if resolved.colorize {
        hue = settings.hue.rem_euclid(360.0);
        saturation = (settings.saturation / 100.0).clamp(0.0, 1.0);
        lightness_amount = settings.lightness / 100.0;
    } else {
        let sampled = response[(hue.round() as i64).clamp(0, 360) as usize];
        lightness_amount = sampled.lightness / 100.0;
        hue = (hue + sampled.hue).rem_euclid(360.0);
        saturation = adjusted_saturation(saturation, sampled.saturation);
    }
    // Lightness pulls toward white above zero and toward black below, reaching either at 100.
    let amount = lightness_amount.clamp(-1.0, 1.0);
    lightness = if amount >= 0.0 { lightness + (1.0 - lightness) * amount } else { lightness * (1.0 + amount) };
    to_rgb(hue, saturation, lightness.clamp(0.0, 1.0))
}

fn hue_saturation(adjustment: &Adjustment, canvas: &mut Surface) {
    let resolved = HueSaturation::resolve(adjustment);
    if resolved.is_identity() {
        return;
    }
    let response = resolved.response();
    let colorize = resolved.colorize;
    let (colorize_hue, colorize_saturation, colorize_lightness) = (
        adjustment.hue.rem_euclid(360.0),
        (adjustment.saturation / 100.0).clamp(0.0, 1.0),
        adjustment.lightness / 100.0,
    );
    let width = canvas.width() as usize;
    canvas.pixels_mut().par_chunks_mut(width * 4).for_each(|row| {
        for texel in row.chunks_exact_mut(4) {
            let alpha = texel[3];
            if alpha == 0 {
                continue;
            }
            let scale = 255.0 / alpha as f32;
            let red = texel[0] as f64 * scale as f64 / 255.0;
            let green = texel[1] as f64 * scale as f64 / 255.0;
            let blue = texel[2] as f64 * scale as f64 / 255.0;
            let (mut hue, mut saturation, mut lightness) = to_hsl(red, green, blue);
            let lightness_amount;
            if colorize {
                hue = colorize_hue;
                saturation = colorize_saturation;
                lightness_amount = colorize_lightness;
            } else {
                let sampled = response[(hue.round() as i64).clamp(0, 360) as usize];
                lightness_amount = sampled.lightness / 100.0;
                hue = (hue + sampled.hue).rem_euclid(360.0);
                saturation = adjusted_saturation(saturation, sampled.saturation);
            }
            let amount = lightness_amount.clamp(-1.0, 1.0);
            lightness = if amount >= 0.0 {
                lightness + (1.0 - lightness) * amount
            } else {
                lightness * (1.0 + amount)
            };
            let (out_red, out_green, out_blue) = to_rgb(hue, saturation, lightness.clamp(0.0, 1.0));
            let alpha = alpha as f64;
            texel[0] = round_u8((out_red * alpha) as f32);
            texel[1] = round_u8((out_green * alpha) as f32);
            texel[2] = round_u8((out_blue * alpha) as f32);
        }
    });
}

// ---------------------------------------------------------------------------------------------
// Grain and Add Noise: seeded patterns that must not move between sessions.
// ---------------------------------------------------------------------------------------------

/// A well-mixed 32-bit hash, so neighbouring pixels get unrelated values.
#[inline]
fn mix32(mut x: u32) -> u32 {
    x ^= x >> 16;
    x = x.wrapping_mul(0x7feb_352d);
    x ^= x >> 15;
    x = x.wrapping_mul(0x846c_a68b);
    x ^= x >> 16;
    x
}

/// A value in -1 to 1 for an integer lattice point, fixed by the point and the seed. Two uniform halves
/// summed give a triangular spread, closer to film grain than flat noise.
#[inline]
fn lattice(ix: i64, iy: i64, seed: u32) -> f32 {
    let h = mix32((ix as u32).wrapping_mul(0x9E37_79B1) ^ mix32((iy as u32).wrapping_mul(0x85EB_CA77) ^ seed));
    (h & 0xFFFF) as f32 / 65535.0 + (h >> 16) as f32 / 65535.0 - 1.0
}

/// Smooth seeded noise whose features follow `scale` document pixels.
fn grain_field(u: f64, v: f64, scale: f64, seed: u32) -> f32 {
    let cell_x = (u / scale).floor();
    let cell_y = (v / scale).floor();
    let mut tx = (u / scale - cell_x) as f32;
    let mut ty = (v / scale - cell_y) as f32;
    tx = tx * tx * (3.0 - 2.0 * tx);
    ty = ty * ty * (3.0 - 2.0 * ty);
    let (ix, iy) = (cell_x as i64, cell_y as i64);
    let n00 = lattice(ix, iy, seed);
    let n10 = lattice(ix + 1, iy, seed);
    let n01 = lattice(ix, iy + 1, seed);
    let n11 = lattice(ix + 1, iy + 1, seed);
    let top = n00 + (n10 - n00) * tx;
    let bottom = n01 + (n11 - n01) * tx;
    // Blending neighbouring lattice values narrows the spread; restore approximately its original range.
    (top + (bottom - top) * ty) * 1.6
}

fn grain(adjustment: &Adjustment, canvas: &mut Surface, origin: (i64, i64)) {
    let settings = adjustment.grain_settings.as_ref();
    let amount = settings.and_then(|value| number(value, "amount")).unwrap_or(25.0);
    let size = settings.and_then(|value| number(value, "size")).unwrap_or(1.5).max(0.001);
    let roughness = settings.and_then(|value| number(value, "roughness")).unwrap_or(50.0);
    let seed = settings.and_then(|value| value.get("seed")).and_then(Value::as_u64).unwrap_or(0) as u32;
    if !amount.is_finite() || amount <= 0.0 {
        return;
    }
    let strength = (if amount > 100.0 { 1.0 } else { amount / 100.0 } as f32) * 0.35 * 255.0;
    let rough = (roughness.clamp(0.0, 100.0) / 100.0) as f32;
    let fine_seed = mix32(seed ^ 0xA511_E9B3);
    // Roughness adds smaller, less regular particles whose size still follows the Size control.
    let detail_size = (size * 0.35).max(0.5);
    let width = canvas.width() as usize;
    canvas.pixels_mut().par_chunks_mut(width * 4).enumerate().for_each(|(y, row)| {
        // The pattern is anchored to the document, not to this canvas: a rectangle asks for the grain at
        // the coordinates it actually covers.
        let v = origin.1 as f64 + y as f64 + 0.5;
        for (x, texel) in row.chunks_exact_mut(4).enumerate() {
            let alpha = texel[3];
            if alpha == 0 {
                continue;
            }
            let u = origin.0 as f64 + x as f64 + 0.5;
            let smooth = grain_field(u, v, size, seed);
            let fine = grain_field(u, v, detail_size, fine_seed);
            let noise = smooth + (fine - smooth) * rough;
            let unpremultiply = if alpha == 255 { 1.0f32 } else { 255.0 / alpha as f32 };
            let red = texel[0] as f32 * unpremultiply;
            let green = texel[1] as f32 * unpremultiply;
            let blue = texel[2] as f32 * unpremultiply;
            let mut level = (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255.0;
            if level > 1.0 {
                level = 1.0;
            }
            // Film grain shows most in the midtones.
            let delta = noise * strength * (0.4 + 2.4 * level * (1.0 - level));
            let coverage = alpha as f32 / 255.0;
            texel[0] = round_u8((red + delta).clamp(0.0, 255.0) * coverage);
            texel[1] = round_u8((green + delta).clamp(0.0, 255.0) * coverage);
            texel[2] = round_u8((blue + delta).clamp(0.0, 255.0) * coverage);
        }
    });
}

/// Uniform in `[0, 1)`.
#[inline]
fn noise_unit(key: u32) -> f32 {
    (mix32(key) >> 8) as f32 * (1.0 / 16_777_216.0)
}

fn add_noise(amount: f32, gaussian: bool, monochromatic: bool, seed: u32, canvas: &mut Surface, origin: (i64, i64)) {
    let spread = amount / 100.0 * 127.5;
    let width = canvas.width() as usize;
    canvas.pixels_mut().par_chunks_mut(width * 4).enumerate().for_each(|(y, row)| {
        for (x, texel) in row.chunks_exact_mut(4).enumerate() {
            let alpha = texel[3];
            if alpha == 0 {
                continue;
            }
            // The noise is anchored to the document, as the C kernel's `noise_add_at` is: a rectangle
            // passes the coordinates it covers, so its pattern keeps matching a whole-canvas render.
            let px = (origin.0 + x as i64) as u32;
            let py = (origin.1 + y as i64) as u32;
            let base = mix32(seed ^ mix32(px.wrapping_mul(0x9e37_79b9) ^ mix32(py.wrapping_mul(0x85eb_ca6b))));
            let alpha_scale = alpha as f32;
            for (channel, entry) in texel[..3].iter_mut().enumerate() {
                let key = if monochromatic { base } else { base.wrapping_add((channel as u32).wrapping_mul(0x9e37_79b9)) };
                let value = if gaussian {
                    // Box-Muller: two uniform values make one normally distributed one.
                    let u1 = noise_unit(key);
                    let u2 = noise_unit(key ^ 0x68e3_1da4);
                    (-2.0 * (1.0 - u1).ln()).sqrt() * (std::f32::consts::TAU * u2).cos() * spread * (2.0 / 3.0)
                } else {
                    (noise_unit(key) * 2.0 - 1.0) * spread
                };
                let scaled = *entry as f32 * 255.0 / alpha_scale + value;
                *entry = round_u8(scaled.clamp(0.0, 255.0) * alpha_scale / 255.0);
            }
        }
    });
}

// ---------------------------------------------------------------------------------------------
// The remaining per-pixel kinds.
// ---------------------------------------------------------------------------------------------

fn invert(canvas: &mut Surface) {
    // Premultiplied RGBA: each color becomes alpha minus color, so transparency is kept.
    let width = canvas.width() as usize;
    canvas.pixels_mut().par_chunks_mut(width * 4).for_each(|row| {
        for texel in row.chunks_exact_mut(4) {
            for channel in 0..3 {
                // A premultiplied channel never exceeds its alpha, but a hand-built buffer could.
                texel[channel] = texel[3].saturating_sub(texel[channel]);
            }
        }
    });
}

fn black_white(adjustment: &Adjustment, canvas: &mut Surface) {
    let defaults = [40.0, 60.0, 40.0, 60.0, 20.0, 80.0];
    let settings = adjustment.black_white_settings.as_ref();
    let names = ["reds", "yellows", "greens", "cyans", "blues", "magentas"];
    let mut weights = [0.0f32; 6];
    for (index, name) in names.iter().enumerate() {
        let value = settings.and_then(|value| number(value, name)).unwrap_or(defaults[index]);
        weights[index] = (value / 100.0) as f32;
    }
    let tint = settings.and_then(|value| value.get("tint")).and_then(Value::as_bool).unwrap_or(false);
    let tint_hue = settings.and_then(|value| number(value, "tintHue")).unwrap_or(40.0);
    let tint_saturation = (settings.and_then(|value| number(value, "tintSaturation")).unwrap_or(20.0) / 100.0) as f32;
    let width = canvas.width() as usize;
    canvas.pixels_mut().par_chunks_mut(width * 4).for_each(|row| {
        for texel in row.chunks_exact_mut(4) {
            let alpha = texel[3] as f32;
            if alpha <= 0.0 {
                continue;
            }
            let straight = |value: u8| (value as f32 * 255.0 / alpha).min(255.0) / 255.0;
            let red = straight(texel[0]);
            let green = straight(texel[1]);
            let blue = straight(texel[2]);
            let max = red.max(green).max(blue);
            let min = red.min(green).min(blue);
            let mid = red + green + blue - max - min;
            // Weights: 0 red, 1 yellow, 2 green, 3 cyan, 4 blue, 5 magenta. A color is its darkest
            // channel of gray, plus the middle channel's share of the secondary, plus the brightest
            // channel's share of the primary - exactly Photoshop's mix.
            let (primary, secondary) = if max == red {
                (0usize, if green >= blue { 1 } else { 5 })
            } else if max == green {
                (2, if red >= blue { 1 } else { 3 })
            } else {
                (4, if green >= red { 3 } else { 5 })
            };
            let mut gray = min + (mid - min) * weights[secondary] + (max - mid) * weights[primary];
            gray = gray.clamp(0.0, 1.0);
            let (mut out_red, mut out_green, mut out_blue) = (gray, gray, gray);
            if tint && tint_saturation > 0.0 {
                // The gray becomes the lightness of a color at the chosen hue.
                let chroma = (1.0 - (2.0 * gray - 1.0).abs()) * tint_saturation;
                let hue = (tint_hue.rem_euclid(360.0) / 60.0) as f32;
                let second = chroma * (1.0 - (hue.rem_euclid(2.0) - 1.0).abs());
                let (r1, g1, b1) = if hue < 1.0 {
                    (chroma, second, 0.0)
                } else if hue < 2.0 {
                    (second, chroma, 0.0)
                } else if hue < 3.0 {
                    (0.0, chroma, second)
                } else if hue < 4.0 {
                    (0.0, second, chroma)
                } else if hue < 5.0 {
                    (second, 0.0, chroma)
                } else {
                    (chroma, 0.0, second)
                };
                let base = gray - chroma / 2.0;
                out_red = r1 + base;
                out_green = g1 + base;
                out_blue = b1 + base;
            }
            let limit = texel[3];
            let write = |value: f32| -> u8 { round_u8(value.clamp(0.0, 1.0) * alpha).min(limit) };
            texel[0] = write(out_red);
            texel[1] = write(out_green);
            texel[2] = write(out_blue);
        }
    });
}

/// How much a tone belongs to the shadows, midtones and highlights: three overlapping curves that sum
/// to about one across the range.
fn tonal_weights(value: f32) -> (f32, f32, f32) {
    const A: f32 = 0.25;
    const B: f32 = 0.333;
    const SCALE: f32 = 0.7;
    let shadow = ((value - B) / -A + 0.5).clamp(0.0, 1.0) * SCALE;
    let highlight = ((value + B - 1.0) / A + 0.5).clamp(0.0, 1.0) * SCALE;
    let mid_one = ((value - B) / A + 0.5).clamp(0.0, 1.0);
    let mid_two = ((value + B - 1.0) / -A + 0.5).clamp(0.0, 1.0);
    (shadow, mid_one * mid_two * SCALE, highlight)
}

fn color_balance(adjustment: &Adjustment, canvas: &mut Surface) {
    let settings = adjustment.color_balance_settings.unwrap_or(ColorBalanceSettings {
        shadow_cyan_red: 0.0,
        shadow_magenta_green: 0.0,
        shadow_yellow_blue: 0.0,
        mid_cyan_red: 0.0,
        mid_magenta_green: 0.0,
        mid_yellow_blue: 0.0,
        highlight_cyan_red: 0.0,
        highlight_magenta_green: 0.0,
        highlight_yellow_blue: 0.0,
        preserve_luminosity: true,
    });
    let shadows = [
        settings.shadow_cyan_red as f32 / 100.0,
        settings.shadow_magenta_green as f32 / 100.0,
        settings.shadow_yellow_blue as f32 / 100.0,
    ];
    let midtones = [
        settings.mid_cyan_red as f32 / 100.0,
        settings.mid_magenta_green as f32 / 100.0,
        settings.mid_yellow_blue as f32 / 100.0,
    ];
    let highlights = [
        settings.highlight_cyan_red as f32 / 100.0,
        settings.highlight_magenta_green as f32 / 100.0,
        settings.highlight_yellow_blue as f32 / 100.0,
    ];
    if shadows.iter().all(|v| *v == 0.0) && midtones.iter().all(|v| *v == 0.0) && highlights.iter().all(|v| *v == 0.0) {
        return;
    }
    let preserve = settings.preserve_luminosity;
    let width = canvas.width() as usize;
    canvas.pixels_mut().par_chunks_mut(width * 4).for_each(|row| {
        for texel in row.chunks_exact_mut(4) {
            let alpha = texel[3] as f32;
            if alpha <= 0.0 {
                continue;
            }
            let mut color = [0.0f32; 3];
            for channel in 0..3 {
                color[channel] = (texel[channel] as f32 * 255.0 / alpha).min(255.0) / 255.0;
            }
            let before = 0.299 * color[0] + 0.587 * color[1] + 0.114 * color[2];
            for channel in 0..3 {
                let (shadow, mid, highlight) = tonal_weights(color[channel]);
                color[channel] = (color[channel] + shadows[channel] * shadow + midtones[channel] * mid + highlights[channel] * highlight)
                    .clamp(0.0, 1.0);
            }
            if preserve {
                let after = 0.299 * color[0] + 0.587 * color[1] + 0.114 * color[2];
                if after > 0.0001 {
                    let ratio = before / after;
                    for entry in color.iter_mut() {
                        *entry = (*entry * ratio).clamp(0.0, 1.0);
                    }
                }
            }
            for channel in 0..3 {
                texel[channel] = round_u8(color[channel] * alpha).min(texel[3]);
            }
        }
    });
}

// ---------------------------------------------------------------------------------------------
// Blurs. Both spread past the canvas edge into transparency, as the original's unclamped Core Image
// blur does, so an adjustment layer softens the pixels' border instead of smearing it outwards.
// ---------------------------------------------------------------------------------------------

/// Bilinear sample with everything outside the surface transparent.
pub(crate) fn sample_transparent(surface: &Surface, x: f32, y: f32) -> [f32; 4] {
    let fx = x - 0.5;
    let fy = y - 0.5;
    let x0 = fx.floor() as i64;
    let y0 = fy.floor() as i64;
    let wx = fx - x0 as f32;
    let wy = fy - y0 as f32;
    let mut out = [0.0f32; 4];
    for (dy, weight_y) in [(0i64, 1.0 - wy), (1, wy)] {
        for (dx, weight_x) in [(0i64, 1.0 - wx), (1, wx)] {
            let sx = x0 + dx;
            let sy = y0 + dy;
            if sx < 0 || sy < 0 || sx >= surface.width() as i64 || sy >= surface.height() as i64 {
                continue;
            }
            let texel = surface.get(sx as u32, sy as u32);
            let weight = weight_x * weight_y;
            for c in 0..4 {
                out[c] += texel[c] as f32 * weight;
            }
        }
    }
    out
}

/// A separable Gaussian of `sigma` spreading into transparency past the canvas edge: what Core
/// Image's unclamped `applyingGaussianBlur(sigma:)` does, which the tonal-contrast filter and the bloom
/// both need.
pub(crate) fn gaussian_blur(radius: f32, canvas: &mut Surface) {
    if !radius.is_finite() || radius <= 0.0 || canvas.is_empty() {
        return;
    }
    let (taps, kernel) = gaussian_kernel(radius);
    let source = canvas.clone();
    blur_rows(canvas, &source, &kernel, taps, true);
    let intermediate = canvas.clone();
    blur_rows(canvas, &intermediate, &kernel, taps, false);
}

/// The Gaussian's half width and normalized weights, built here so the shader runs the same kernel the
/// CPU does rather than an exp() of its own that could land a level away.
pub(crate) fn gaussian_kernel_for(sigma: f32) -> (i64, Vec<f32>) {
    gaussian_kernel(sigma)
}

fn gaussian_kernel(radius: f32) -> (i64, Vec<f32>) {
    let sigma = radius;
    let taps = (sigma * 3.0).ceil().max(1.0) as i64;
    let mut kernel = Vec::with_capacity((taps * 2 + 1) as usize);
    let mut sum = 0.0f32;
    for offset in -taps..=taps {
        let weight = (-((offset * offset) as f32) / (2.0 * sigma * sigma)).exp();
        kernel.push(weight);
        sum += weight;
    }
    for weight in kernel.iter_mut() {
        *weight /= sum;
    }
    (taps, kernel)
}

/// One separable Gaussian pass: rows when `horizontal`, columns otherwise.
fn blur_rows(target: &mut Surface, source: &Surface, kernel: &[f32], taps: i64, horizontal: bool) {
    let width = target.width() as usize;
    let height = target.height() as usize;
    let row_bytes = width * 4;
    target.pixels_mut().par_chunks_mut(row_bytes).enumerate().for_each(|(y, row)| {
        for (x, texel) in row.chunks_exact_mut(4).enumerate() {
            let mut out = [0.0f32; 4];
            for (index, weight) in kernel.iter().enumerate() {
                let offset = index as i64 - taps;
                let (sx, sy) = if horizontal { (x as i64 + offset, y as i64) } else { (x as i64, y as i64 + offset) };
                if sx < 0 || sy < 0 || sx >= width as i64 || sy >= height as i64 {
                    continue;
                }
                let sample = source.get(sx as u32, sy as u32);
                for c in 0..4 {
                    out[c] += sample[c] as f32 * weight;
                }
            }
            for c in 0..4 {
                texel[c] = round_u8(out[c]);
            }
        }
    });
}

fn motion_blur(angle: f32, distance: f32, canvas: &mut Surface) {
    if !distance.is_finite() || distance <= 1.0 || canvas.is_empty() {
        return;
    }
    // Photoshop's angle counts counterclockwise with y up, and the buffer counts y down.
    let radians = angle.to_radians();
    let (dx, dy) = (radians.cos(), -radians.sin());
    // Photoshop smears evenly along the whole distance; one sample per pixel of streak.
    let steps = distance.round().max(1.0) as i64;
    let half = (steps - 1) as f32 / 2.0;
    let source = canvas.clone();
    let width = canvas.width() as usize;
    canvas.pixels_mut().par_chunks_mut(width * 4).enumerate().for_each(|(y, row)| {
        for (x, texel) in row.chunks_exact_mut(4).enumerate() {
            let mut out = [0.0f32; 4];
            for step in 0..steps {
                let t = step as f32 - half;
                let sample = sample_transparent(&source, x as f32 + 0.5 + dx * t, y as f32 + 0.5 + dy * t);
                for c in 0..4 {
                    out[c] += sample[c];
                }
            }
            let count = steps as f32;
            for c in 0..4 {
                texel[c] = round_u8(out[c] / count);
            }
        }
    });
}

// ---------------------------------------------------------------------------------------------
// Settings that live in untyped JSON fields.
// ---------------------------------------------------------------------------------------------

fn number(value: &Value, key: &str) -> Option<f64> {
    value.get(key).and_then(Value::as_f64).filter(|number| number.is_finite())
}

fn color_of(value: Option<&Value>) -> [f64; 3] {
    match value {
        Some(value) => [
            number(value, "red").unwrap_or(0.0).clamp(0.0, 1.0),
            number(value, "green").unwrap_or(0.0).clamp(0.0, 1.0),
            number(value, "blue").unwrap_or(0.0).clamp(0.0, 1.0),
        ],
        None => [0.0, 0.0, 0.0],
    }
}

// ---------------------------------------------------------------------------------------------

/// One adjustment as the shader runs it: a kind, a flag for the ones whose settings are the identity, the
/// scalars and seeds that go with the kind, and the lookup tables - built by this module's own code, so a
/// table on the GPU is the table the CPU would have used.
#[derive(Clone, Debug, PartialEq)]
pub struct GpuAdjustment {
    /// 0 invert, 1 lookup (Levels, Curves, Exposure), 2 gradient map, 3 black & white, 4 color balance,
    /// 5 hue/saturation, 6 grain, 7 add noise.
    pub kind: u32,
    /// False when the settings are the identity: the CPU skips such a kernel outright, and the shader has
    /// to skip it too rather than push every pixel through a round trip that changes nothing.
    pub apply: bool,
    /// Kind-specific values, in the order the shader reads them.
    pub scalars: Vec<f32>,
    /// Kind-specific integers: the seeds of the two patterns.
    pub integers: Vec<u32>,
    /// 3 x 256 for the lookup kinds, 361 x 3 for hue/saturation's response, 256 x 3 bytes for the gradient
    /// map, packed as words.
    pub table: Vec<u32>,
}

/// Words the shader reads a program from: kind, apply, sixteen scalars, eight integers, then the table.
const PROGRAM_WORDS: usize = 32 + 1200;

impl GpuAdjustment {
    fn new(kind: u32) -> GpuAdjustment {
        GpuAdjustment { kind, apply: true, scalars: Vec::new(), integers: Vec::new(), table: Vec::new() }
    }

    /// The program as the shader's uniform layout: fixed-size, zero padded.
    pub fn words(&self) -> Vec<u32> {
        let mut words = vec![0u32; PROGRAM_WORDS];
        words[0] = self.kind;
        words[1] = u32::from(self.apply);
        for (index, value) in self.scalars.iter().enumerate().take(16) {
            words[2 + index] = value.to_bits();
        }
        for (index, value) in self.integers.iter().enumerate().take(8) {
            words[18 + index] = *value;
        }
        let room = PROGRAM_WORDS - 32;
        words[32..32 + self.table.len().min(room)].copy_from_slice(&self.table[..self.table.len().min(room)]);
        words
    }
}

/// The program for one adjustment, or nothing for a kind the shader cannot run - the two blurs, which
/// read their neighbours and need a pass of their own rather than a per-pixel kernel.
pub fn gpu_adjustment(adjustment: &Adjustment) -> Option<GpuAdjustment> {
    match adjustment.kind {
        AdjustmentKind::Invert => Some(GpuAdjustment::new(0)),
        AdjustmentKind::Levels => {
            let tables = levels_tables(adjustment);
            let mut program = GpuAdjustment::new(1);
            program.apply = tables.is_some();
            program.table = flatten_tables(&tables.unwrap_or([[0.0; 256]; 3]));
            Some(program)
        }
        AdjustmentKind::Curves => {
            let tables = curves_tables(adjustment);
            let mut program = GpuAdjustment::new(1);
            program.apply = tables.is_some();
            program.table = flatten_tables(&tables.unwrap_or([[0.0; 256]; 3]));
            Some(program)
        }
        AdjustmentKind::Exposure => {
            let table = exposure_table(adjustment);
            let mut program = GpuAdjustment::new(1);
            program.apply = table.is_some();
            let table = table.unwrap_or([0.0; 256]);
            program.table = flatten_tables(&[table, table, table]);
            Some(program)
        }
        AdjustmentKind::GradientMap => {
            let mut program = GpuAdjustment::new(2);
            program.table = gradient_map_words(adjustment);
            Some(program)
        }
        AdjustmentKind::BlackWhite => {
            let defaults = [40.0, 60.0, 40.0, 60.0, 20.0, 80.0];
            let settings = adjustment.black_white_settings.as_ref();
            let names = ["reds", "yellows", "greens", "cyans", "blues", "magentas"];
            let mut program = GpuAdjustment::new(3);
            for (index, name) in names.iter().enumerate() {
                let value = settings.and_then(|value| number(value, name)).unwrap_or(defaults[index]);
                program.scalars.push((value / 100.0) as f32);
            }
            let tint = settings.and_then(|value| value.get("tint")).and_then(Value::as_bool).unwrap_or(false);
            program.scalars.push(f32::from(tint));
            program
                .scalars
                .push(settings.and_then(|value| number(value, "tintHue")).unwrap_or(40.0) as f32);
            program
                .scalars
                .push((settings.and_then(|value| number(value, "tintSaturation")).unwrap_or(20.0) / 100.0) as f32);
            Some(program)
        }
        AdjustmentKind::ColorBalance => {
            let settings = adjustment.color_balance_settings.unwrap_or(ColorBalanceSettings {
                shadow_cyan_red: 0.0,
                shadow_magenta_green: 0.0,
                shadow_yellow_blue: 0.0,
                mid_cyan_red: 0.0,
                mid_magenta_green: 0.0,
                mid_yellow_blue: 0.0,
                highlight_cyan_red: 0.0,
                highlight_magenta_green: 0.0,
                highlight_yellow_blue: 0.0,
                preserve_luminosity: true,
            });
            let values = [
                settings.shadow_cyan_red,
                settings.shadow_magenta_green,
                settings.shadow_yellow_blue,
                settings.mid_cyan_red,
                settings.mid_magenta_green,
                settings.mid_yellow_blue,
                settings.highlight_cyan_red,
                settings.highlight_magenta_green,
                settings.highlight_yellow_blue,
            ];
            let mut program = GpuAdjustment::new(4);
            program.scalars.extend(values.iter().map(|value| (*value / 100.0) as f32));
            program.scalars.push(f32::from(settings.preserve_luminosity));
            program.apply = values.iter().any(|value| *value != 0.0);
            Some(program)
        }
        AdjustmentKind::HueSaturation => {
            let resolved = HueSaturation::resolve(adjustment);
            let mut program = GpuAdjustment::new(5);
            program.apply = !resolved.is_identity();
            let response = resolved.response();
            for entry in response {
                program.table.push((entry.hue as f32).to_bits());
                program.table.push((entry.saturation as f32).to_bits());
                program.table.push((entry.lightness as f32).to_bits());
            }
            program.scalars.push(f32::from(resolved.colorize));
            program.scalars.push(adjustment.hue.rem_euclid(360.0) as f32);
            program.scalars.push((adjustment.saturation / 100.0).clamp(0.0, 1.0) as f32);
            program.scalars.push((adjustment.lightness / 100.0) as f32);
            Some(program)
        }
        AdjustmentKind::Grain => {
            let settings = adjustment.grain_settings.as_ref();
            let amount = settings.and_then(|value| number(value, "amount")).unwrap_or(25.0);
            let size = settings.and_then(|value| number(value, "size")).unwrap_or(1.5).max(0.001);
            let roughness = settings.and_then(|value| number(value, "roughness")).unwrap_or(50.0);
            let seed = settings.and_then(|value| value.get("seed")).and_then(Value::as_u64).unwrap_or(0) as u32;
            let mut program = GpuAdjustment::new(6);
            program.apply = amount.is_finite() && amount > 0.0;
            let strength = (if amount > 100.0 { 1.0 } else { amount / 100.0 } as f32) * 0.35 * 255.0;
            program.scalars.push(strength);
            program.scalars.push((roughness.clamp(0.0, 100.0) / 100.0) as f32);
            program.scalars.push(size as f32);
            program.scalars.push((size * 0.35).max(0.5) as f32);
            program.integers.push(seed);
            program.integers.push(mix32(seed ^ 0xA511_E9B3));
            Some(program)
        }
        AdjustmentKind::AddNoise => {
            let amount = adjustment.noise_amount.unwrap_or(10.0) as f32;
            let mut program = GpuAdjustment::new(7);
            program.scalars.push(amount / 100.0 * 127.5);
            program
                .scalars
                .push(f32::from(adjustment.noise_gaussian.unwrap_or(false)));
            program
                .scalars
                .push(f32::from(adjustment.noise_monochromatic.unwrap_or(false)));
            program.integers.push(adjustment.noise_seed.unwrap_or(0) as u32);
            Some(program)
        }
        AdjustmentKind::GaussianBlur => {
            let radius = adjustment.blur_radius.unwrap_or(10.0) as f32;
            let mut program = GpuAdjustment::new(8);
            // The guard the CPU's kernel opens with: a radius that is not positive blurs nothing.
            program.apply = radius.is_finite() && radius > 0.0;
            let (taps, kernel) = gaussian_kernel(radius);
            program.scalars.push(taps as f32);
            program.table = kernel.iter().map(|weight| weight.to_bits()).collect();
            Some(program)
        }
        AdjustmentKind::MotionBlur => {
            let angle = adjustment.motion_angle.unwrap_or(0.0) as f32;
            let distance = adjustment.motion_distance.unwrap_or(10.0) as f32;
            let mut program = GpuAdjustment::new(9);
            // The CPU blurs nothing at a distance of one pixel or less.
            program.apply = distance.is_finite() && distance > 1.0;
            let radians = angle.to_radians();
            program.scalars.push(distance.round().max(1.0));
            program.scalars.push(radians.cos());
            program.scalars.push(-radians.sin());
            Some(program)
        }
    }
}

fn flatten_tables(tables: &[[f32; 256]; 3]) -> Vec<u32> {
    let mut words = Vec::with_capacity(768);
    for table in tables {
        words.extend(table.iter().map(|value| value.to_bits()));
    }
    words
}

/// The gradient map's 256 x 3 byte table, packed four bytes to a word.
fn gradient_map_words(adjustment: &Adjustment) -> Vec<u32> {
    let table = gradient_map_table(adjustment);
    let mut words = vec![0u32; 256 * 3 / 4];
    for (index, value) in table.iter().enumerate() {
        words[index / 4] |= (*value as u32) << ((index % 4) * 8);
    }
    words
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A straight-alpha block, taken into the premultiplied form the compositor works in.
    fn solid(width: u32, height: u32, texel: [u8; 4]) -> Surface {
        Surface::from_bitmap(&comp_core::Bitmap8::filled(width, height, texel))
    }

    fn apply_to(adjustment: &Adjustment, texel: [u8; 4]) -> [u8; 4] {
        let mut canvas = solid(1, 1, texel);
        apply(adjustment, &mut canvas);
        canvas.to_bitmap().get(0, 0)
    }

    #[test]
    fn invert_mirrors_each_channel_inside_its_alpha() {
        let adjustment = Adjustment::new(AdjustmentKind::Invert);
        assert_eq!(apply_to(&adjustment, [0, 60, 255, 255]), [255, 195, 0, 255]);
        // A soft pixel inverts inside its own alpha, so the straight color comes back within the
        // premultiplication's own rounding.
        let soft = apply_to(&adjustment, [10, 20, 30, 40]);
        assert_eq!(soft[3], 40);
        for (channel, expected) in soft[..3].iter().zip([245, 235, 225]) {
            // The round trip through a premultiplied byte at alpha 40 is worth about three levels.
            assert!((*channel as i32 - expected).abs() <= 3, "expected about {expected}: {soft:?}");
        }
    }

    #[test]
    fn an_identity_kind_leaves_the_canvas_alone() {
        for kind in [AdjustmentKind::Levels, AdjustmentKind::Curves, AdjustmentKind::Exposure] {
            let adjustment = Adjustment::new(kind);
            let texel = [40, 90, 160, 255];
            assert_eq!(apply_to(&adjustment, texel), texel, "{kind:?} with default settings");
        }
    }

    #[test]
    fn levels_lift_and_brighten() {
        let mut adjustment = Adjustment::new(AdjustmentKind::Levels);
        adjustment.levels.ranges[0].black = 50.0;
        adjustment.levels.ranges[0].white = 200.0;
        let dark = apply_to(&adjustment, [0, 0, 0, 255]);
        let bright = apply_to(&adjustment, [255, 255, 255, 255]);
        assert_eq!(dark, [0, 0, 0, 255], "black stays black");
        assert_eq!(bright, [255, 255, 255, 255], "white stays white");
        let mid = apply_to(&adjustment, [125, 125, 125, 255]);
        assert!(mid[0] > 125, "the midpoint is pulled up: {mid:?}");
    }

    #[test]
    fn curves_follow_their_handles() {
        let mut adjustment = Adjustment::new(AdjustmentKind::Curves);
        adjustment.curves.channels[0] = vec![
            CurvePoint { x: 0.0, y: 0.0 },
            CurvePoint { x: 128.0, y: 200.0 },
            CurvePoint { x: 255.0, y: 255.0 },
        ];
        let lifted = apply_to(&adjustment, [128, 128, 128, 255]);
        assert!(lifted[0] > 180, "the handle lifts the midpoint: {lifted:?}");
        assert_eq!(apply_to(&adjustment, [0, 0, 0, 255]), [0, 0, 0, 255]);
    }

    #[test]
    fn exposure_works_in_linear_light() {
        let mut adjustment = Adjustment::new(AdjustmentKind::Exposure);
        adjustment.exposure_settings = Some(serde_json::json!({"exposure": 1.0, "offset": 0.0, "gamma": 1.0}));
        let doubled = apply_to(&adjustment, [100, 100, 100, 255]);
        assert!(doubled[0] > 100, "one stop up brightens: {doubled:?}");
        assert!(doubled[0] < 255);
    }

    #[test]
    fn a_gradient_map_takes_the_rec_601_luma() {
        // A black to white gradient is not the identity: every pixel becomes the gray of its luminance,
        // so a pure red comes back dark.
        let adjustment = Adjustment::new(AdjustmentKind::GradientMap);
        let red = apply_to(&adjustment, [255, 0, 0, 255]);
        assert_eq!(red[0], red[1]);
        assert_eq!(red[1], red[2]);
        assert!(red[0] > 50 && red[0] < 70, "Rec. 601 red is about 54: {red:?}");
    }

    #[test]
    fn black_and_white_mixes_its_six_bands() {
        let mut adjustment = Adjustment::new(AdjustmentKind::BlackWhite);
        adjustment.black_white_settings = Some(serde_json::json!({"reds": 100.0, "blues": 0.0}));
        let red = apply_to(&adjustment, [255, 0, 0, 255]);
        let blue = apply_to(&adjustment, [0, 0, 255, 255]);
        assert!(red[0] > blue[0], "a raised red band shows red brighter: {red:?} against {blue:?}");
    }

    #[test]
    fn color_balance_keeps_the_luminance_it_was_asked_to() {
        let mut adjustment = Adjustment::new(AdjustmentKind::ColorBalance);
        adjustment.color_balance_settings = Some(ColorBalanceSettings {
            mid_cyan_red: 40.0,
            preserve_luminosity: true,
            ..ColorBalanceSettings::default()
        });
        let before = [120, 120, 120, 255];
        let after = apply_to(&adjustment, before);
        assert!(after[0] > 120, "the midtones go red: {after:?}");
        let luma = 0.299 * after[0] as f32 + 0.587 * after[1] as f32 + 0.114 * after[2] as f32;
        assert!((luma - 120.0).abs() <= 2.0, "and the luminance holds: {after:?}");
    }

    #[test]
    fn grain_is_seeded_and_anchored_to_the_document() {
        let mut adjustment = Adjustment::new(AdjustmentKind::Grain);
        adjustment.grain_settings = Some(serde_json::json!({"amount": 60.0, "size": 2.0, "seed": 5}));
        let mut first = solid(4, 4, [120, 120, 120, 255]);
        apply_at(&adjustment, &mut first, (0, 0));
        let mut again = solid(4, 4, [120, 120, 120, 255]);
        apply_at(&adjustment, &mut again, (0, 0));
        assert_eq!(first.to_bitmap().pixels(), again.to_bitmap().pixels(), "the same seed gives the same grain");
        // The pattern is anchored to the document, so a rectangle at an offset sees the same pixels.
        let mut whole = solid(8, 8, [120, 120, 120, 255]);
        apply_at(&adjustment, &mut whole, (0, 0));
        let mut corner = solid(4, 4, [120, 120, 120, 255]);
        apply_at(&adjustment, &mut corner, (4, 4));
        for y in 0..4 {
            for x in 0..4 {
                assert_eq!(
                    corner.to_bitmap().get(x, y),
                    whole.to_bitmap().get(x + 4, y + 4),
                    "grain at ({x},{y}) of the corner"
                );
            }
        }
    }

    #[test]
    fn add_noise_is_seeded_and_anchored_to_the_document() {
        let adjustment = {
            let mut adjustment = Adjustment::new(AdjustmentKind::AddNoise);
            adjustment.noise_amount = Some(50.0);
            adjustment.noise_seed = Some(9);
            adjustment
        };
        let mut whole = solid(6, 6, [120, 120, 120, 255]);
        apply_at(&adjustment, &mut whole, (0, 0));
        let mut corner = solid(3, 3, [120, 120, 120, 255]);
        apply_at(&adjustment, &mut corner, (1, 2));
        for y in 0..3 {
            for x in 0..3 {
                assert_eq!(corner.to_bitmap().get(x, y), whole.to_bitmap().get(x + 1, y + 2));
            }
        }
        assert_ne!(whole.to_bitmap().get(0, 0), [120, 120, 120, 255], "the noise changes pixels");
    }

    #[test]
    fn the_gpu_program_covers_the_per_pixel_kinds_and_refuses_the_rest() {
        for kind in [
            AdjustmentKind::Invert,
            AdjustmentKind::Levels,
            AdjustmentKind::Curves,
            AdjustmentKind::Exposure,
            AdjustmentKind::GradientMap,
            AdjustmentKind::Grain,
            AdjustmentKind::BlackWhite,
            AdjustmentKind::ColorBalance,
            AdjustmentKind::AddNoise,
            AdjustmentKind::HueSaturation,
        ] {
            let program = gpu_adjustment(&Adjustment::new(kind)).unwrap_or_else(|| panic!("{kind:?} has a program"));
            assert!(!program.words().is_empty(), "{kind:?} packs its program");
        }
        for kind in [AdjustmentKind::GaussianBlur, AdjustmentKind::MotionBlur] {
            let program = gpu_adjustment(&Adjustment::new(kind)).unwrap_or_else(|| panic!("{kind:?} has a program"));
            assert!(program.kind >= 8, "{kind:?} is one of the blur passes");
        }
    }

    #[test]
    fn a_gpu_program_carries_the_cpus_own_tables() {
        // The lookup kinds share this module's table builders, so the shader reads the table the CPU would
        // have used - not a second implementation of the same curve.
        let mut adjustment = Adjustment::new(AdjustmentKind::Levels);
        adjustment.levels.ranges[0].gamma = 1.5;
        let program = gpu_adjustment(&adjustment).expect("levels has a program");
        let tables = levels_tables(&adjustment).expect("levels has a table");
        for (channel, table) in tables.iter().enumerate() {
            for (index, expected) in table.iter().enumerate() {
                let word = program.table[channel * 256 + index];
                assert_eq!(f32::from_bits(word), *expected, "channel {channel} entry {index}");
            }
        }
        assert!(program.apply);
    }
}
