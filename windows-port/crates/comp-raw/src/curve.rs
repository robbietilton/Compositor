//! Camera Raw's curve panel: the parametric curve's four regions and the four point curves.
//!
//! Ported from `CameraRawCurveSettings` in compositor_mac/Compositor/Document/CameraRawColor.swift; the
//! point interpolation itself is Photoshop's shape-preserving cubic Hermite, taken from
//! compositor_mac/Compositor/Document/Curves.swift so a Raw curve and an Image > Curves adjustment with
//! the same points draw the same line.

use serde::{Deserialize, Serialize};

use crate::settings::RawCurveSettings;

/// One handle of a point curve. Both axes are 0…1, as Camera Raw stores them.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RawCurvePoint {
    pub x: f64,
    pub y: f64,
}

impl RawCurvePoint {
    pub fn new(x: f64, y: f64) -> Self {
        RawCurvePoint { x, y }
    }

    /// Converts a `comp_core` curve handle (0…255 on both axes) into this panel's 0…1 form.
    pub fn from_core(point: comp_core::adjustment::CurvePoint) -> Self {
        RawCurvePoint { x: point.x / 255.0, y: point.y / 255.0 }
    }

    /// The reverse conversion, for handing a Raw curve to the shared Curves adjustment.
    pub fn to_core(self) -> comp_core::adjustment::CurvePoint {
        comp_core::adjustment::CurvePoint { x: self.x * 255.0, y: self.y * 255.0 }
    }
}

/// The untouched curve: a straight line from black to white.
pub fn linear_points() -> Vec<RawCurvePoint> {
    vec![RawCurvePoint::new(0.0, 0.0), RawCurvePoint::new(1.0, 1.0)]
}

/// Camera Raw's Medium Contrast preset.
pub fn medium_contrast_points() -> Vec<RawCurvePoint> {
    vec![
        RawCurvePoint::new(0.0, 0.0),
        RawCurvePoint::new(0.25, 0.18),
        RawCurvePoint::new(0.75, 0.82),
        RawCurvePoint::new(1.0, 1.0),
    ]
}

/// Camera Raw's Strong Contrast preset.
pub fn strong_contrast_points() -> Vec<RawCurvePoint> {
    vec![
        RawCurvePoint::new(0.0, 0.0),
        RawCurvePoint::new(0.25, 0.10),
        RawCurvePoint::new(0.75, 0.90),
        RawCurvePoint::new(1.0, 1.0),
    ]
}

/// True for the identity line, which is how the panel decides it has nothing to do.
pub fn is_linear(points: &[RawCurvePoint]) -> bool {
    points.len() == 2
        && points[0].x == 0.0
        && points[0].y == 0.0
        && points[1].x == 1.0
        && points[1].y == 1.0
}

/// The parametric panel's four regions, in tone order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RawCurveRegion {
    Shadows,
    Darks,
    Lights,
    Highlights,
}

/// The point-curve channels, in the order the UI lists them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RawPointChannel {
    Rgb,
    Red,
    Green,
    Blue,
}

/// Sorts, clamps and thins a handle list until it is a usable curve: endpoints pinned to 0 and 1,
/// interior handles inside 0.01…0.99 and at least 0.01 apart. Falls back to the identity line when
/// fewer than two handles survive.
pub fn repair(points: &[RawCurvePoint]) -> Vec<RawCurvePoint> {
    let mut sorted: Vec<RawCurvePoint> = points
        .iter()
        .copied()
        .filter(|point| point.x.is_finite() && point.y.is_finite())
        .collect();
    sorted.sort_by(|a, b| a.x.partial_cmp(&b.x).unwrap_or(std::cmp::Ordering::Equal));
    if sorted.len() < 2 {
        return linear_points();
    }
    let first = RawCurvePoint::new(0.0, sorted[0].y.clamp(0.0, 1.0));
    let last = RawCurvePoint::new(1.0, sorted[sorted.len() - 1].y.clamp(0.0, 1.0));
    let mut kept = vec![first];
    for point in sorted.iter().skip(1).take(sorted.len().saturating_sub(2)) {
        let x = point.x.clamp(0.01, 0.99);
        let previous = kept[kept.len() - 1].x;
        if x <= previous + 0.01 {
            continue;
        }
        kept.push(RawCurvePoint::new(x, point.y.clamp(0.0, 1.0)));
    }
    kept.push(last);
    kept
}

/// Photoshop's curve through `points`, evaluated at `x` (both 0…1). The macOS version works in
/// 0…255; the interpolation is scale-invariant, so the two agree exactly.
pub fn evaluate(points: &[RawCurvePoint], x: f64) -> f64 {
    if points.len() < 2 {
        return x;
    }
    let count = points.len();
    let last_start = points
        .iter()
        .rposition(|point| point.x <= x)
        .unwrap_or(0)
        .min(count - 2);
    let slopes: Vec<f64> = points
        .windows(2)
        .map(|pair| (pair[1].y - pair[0].y) / (pair[1].x - pair[0].x))
        .collect();
    let slope = |index: usize| -> f64 {
        if index == 0 {
            return slopes[0];
        }
        if index == count - 1 {
            return slopes[count - 2];
        }
        if slopes[index - 1] * slopes[index] <= 0.0 {
            return 0.0;
        }
        2.0 / (1.0 / slopes[index - 1] + 1.0 / slopes[index])
    };
    let h = points[last_start + 1].x - points[last_start].x;
    if h <= 0.0 {
        return points[last_start].y.clamp(0.0, 1.0);
    }
    let t = ((x - points[last_start].x) / h).clamp(0.0, 1.0);
    let y = (2.0 * t * t * t - 3.0 * t * t + 1.0) * points[last_start].y
        + (t * t * t - 2.0 * t * t + t) * h * slope(last_start)
        + (-2.0 * t * t * t + 3.0 * t * t) * points[last_start + 1].y
        + (t * t * t - t * t) * h * slope(last_start + 1);
    y.clamp(0.0, 1.0)
}

impl RawCurveSettings {
    /// Camera Raw's parametric curve, matched to Photoshop's: Darks bends the whole range below the
    /// middle divider and Lights the whole range above it, while Shadows and Highlights bend only the
    /// ranges past the outer dividers. Each bend is a gamma curve across its range, so the curve keeps
    /// rising however far the sliders go, and the 33 sample anchors are run through the same smooth
    /// curve as Image > Curves so the halves meet without a corner.
    pub fn parametric(&self, tone: f64) -> f64 {
        if self.shadows == 0.0 && self.darks == 0.0 && self.lights == 0.0 && self.highlights == 0.0 {
            return tone;
        }
        let anchors: Vec<RawCurvePoint> = (0..=32)
            .map(|index| {
                let x = index as f64 / 32.0;
                let inner = bend(x, self.shadow_split / 100.0, self.shadows, self.light_split / 100.0, self.highlights);
                let y = bend(inner, self.dark_split / 100.0, self.darks, self.dark_split / 100.0, self.lights);
                RawCurvePoint::new(x, y)
            })
            .collect();
        evaluate(&anchors, tone)
    }

    /// The 256-entry composite table: the parametric curve first, then the RGB point curve.
    pub fn tone_table(&self) -> [f32; 256] {
        let mut table = [0f32; 256];
        for (index, slot) in table.iter_mut().enumerate() {
            let tone = index as f64 / 255.0;
            *slot = evaluate(&self.rgb, self.parametric(tone)) as f32;
        }
        table
    }

    /// A 256-entry table for one per-channel curve.
    pub fn channel_table(points: &[RawCurvePoint]) -> [f32; 256] {
        let mut table = [0f32; 256];
        for (index, slot) in table.iter_mut().enumerate() {
            *slot = evaluate(points, index as f64 / 255.0) as f32;
        }
        table
    }

    /// The region a tone belongs to, for the targeted adjustment tool.
    pub fn region(&self, tone: f64) -> RawCurveRegion {
        if tone < self.shadow_split / 100.0 {
            RawCurveRegion::Shadows
        } else if tone < self.dark_split / 100.0 {
            RawCurveRegion::Darks
        } else if tone < self.light_split / 100.0 {
            RawCurveRegion::Lights
        } else {
            RawCurveRegion::Highlights
        }
    }

    /// The mutable amount behind a region, so a drag can add to it.
    pub fn region_amount_mut(&mut self, region: RawCurveRegion) -> &mut f64 {
        match region {
            RawCurveRegion::Shadows => &mut self.shadows,
            RawCurveRegion::Darks => &mut self.darks,
            RawCurveRegion::Lights => &mut self.lights,
            RawCurveRegion::Highlights => &mut self.highlights,
        }
    }

    /// Moves the handle nearest `tone` on one channel by `delta`, clamped to the panel's range.
    pub fn nudged(&self, channel: RawPointChannel, near: f64, by: f64) -> Self {
        let mut result = self.clone();
        let points = match channel {
            RawPointChannel::Rgb => &mut result.rgb,
            RawPointChannel::Red => &mut result.red,
            RawPointChannel::Green => &mut result.green,
            RawPointChannel::Blue => &mut result.blue,
        };
        let Some((index, _)) = points
            .iter()
            .enumerate()
            .map(|(index, point)| (index, (point.x - near).abs()))
            .fold(None, |best: Option<(usize, f64)>, candidate| match best {
                Some(current) if current.1 <= candidate.1 => Some(current),
                _ => Some(candidate),
            })
        else {
            return result;
        };
        points[index].y = (points[index].y + by).clamp(0.0, 1.0);
        result
    }
}

/// One gamma bend of the parametric curve: tones below `lower` follow `low`, tones above `upper`
/// follow `high`, and black, white and the dividers stay put.
fn bend(tone: f64, lower: f64, low: f64, upper: f64, high: f64) -> f64 {
    let strength = 1.66;
    if tone < lower && lower > 0.0 {
        return lower * (tone / lower).powf(2f64.powf(-low / 100.0 * strength));
    }
    if tone > upper && upper < 1.0 {
        let rest = 1.0 - upper;
        return 1.0 - rest * ((1.0 - tone) / rest).powf(2f64.powf(high / 100.0 * strength));
    }
    tone
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_identity_line_is_recognized() {
        assert!(is_linear(&linear_points()));
        assert!(!is_linear(&medium_contrast_points()));
        assert!(!is_linear(&[]));
        assert!(!is_linear(&[RawCurvePoint::new(0.0, 0.0)]));
    }

    #[test]
    fn a_linear_curve_passes_tones_through() {
        for step in 0..=32 {
            let x = step as f64 / 32.0;
            assert!((evaluate(&linear_points(), x) - x).abs() < 1e-9, "{x}");
        }
    }

    #[test]
    fn curve_endpoints_are_pinned() {
        for points in [linear_points(), medium_contrast_points(), strong_contrast_points()] {
            assert!(evaluate(&points, 0.0).abs() < 1e-12);
            assert!((evaluate(&points, 1.0) - 1.0).abs() < 1e-12);
        }
    }

    #[test]
    fn contrast_curves_stay_monotone_and_bend_the_midtones() {
        for points in [medium_contrast_points(), strong_contrast_points()] {
            let mut previous = -1.0;
            for step in 0..=64 {
                let x = step as f64 / 64.0;
                let y = evaluate(&points, x);
                assert!(y >= previous - 1e-12, "not monotone at {x}: {y} after {previous}");
                previous = y;
            }
            // An S-curve pulls the quarter tone down and pushes the three-quarter tone up.
            assert!(evaluate(&points, 0.25) < 0.25);
            assert!(evaluate(&points, 0.75) > 0.75);
        }
    }

    #[test]
    fn repair_pins_the_ends_and_drops_crowded_handles() {
        let messy = vec![
            RawCurvePoint::new(0.5, 0.9),
            RawCurvePoint::new(0.2, 0.1),
            RawCurvePoint::new(0.205, 0.2),
            RawCurvePoint::new(0.9, f64::NAN),
            RawCurvePoint::new(0.8, 0.95),
        ];
        let fixed = repair(&messy);
        assert_eq!(fixed[0], RawCurvePoint::new(0.0, 0.1));
        assert_eq!(fixed[fixed.len() - 1], RawCurvePoint::new(1.0, 0.95));
        for pair in fixed.windows(2) {
            assert!(pair[1].x > pair[0].x, "handles must stay ordered");
        }
        assert!(fixed.iter().all(|point| (0.0..=1.0).contains(&point.y)));
        // Fewer than two usable handles falls back to the identity line.
        assert_eq!(repair(&[RawCurvePoint::new(0.0, 0.5)]), linear_points());
        assert_eq!(repair(&[RawCurvePoint::new(f64::NAN, 0.5)]), linear_points());
    }

    #[test]
    fn parametric_defaults_are_idle_and_black_white_stay_put() {
        let settings = RawCurveSettings::default();
        for step in 0..=32 {
            let x = step as f64 / 32.0;
            assert!((settings.parametric(x) - x).abs() < 1e-12);
        }
        let mut active = RawCurveSettings::default();
        active.shadows = 60.0;
        active.highlights = -40.0;
        assert!(active.parametric(0.0).abs() < 1e-12);
        assert!((active.parametric(1.0) - 1.0).abs() < 1e-12);
        // Lifting Shadows raises a dark tone; recovering Highlights lowers a bright one.
        assert!(active.parametric(0.1) > settings.parametric(0.1));
        assert!(active.parametric(0.9) < settings.parametric(0.9));
    }

    #[test]
    fn parametric_regions_follow_the_dividers() {
        let settings = RawCurveSettings::default();
        assert_eq!(settings.region(0.1), RawCurveRegion::Shadows);
        assert_eq!(settings.region(0.4), RawCurveRegion::Darks);
        assert_eq!(settings.region(0.6), RawCurveRegion::Lights);
        assert_eq!(settings.region(0.9), RawCurveRegion::Highlights);

        let mut moved = settings.clone();
        *moved.region_amount_mut(RawCurveRegion::Darks) = 25.0;
        assert_eq!(moved.darks, 25.0);
    }

    #[test]
    fn nudged_moves_the_nearest_handle_only() {
        let mut settings = RawCurveSettings::default();
        settings.rgb = medium_contrast_points();
        let moved = settings.nudged(RawPointChannel::Rgb, 0.26, 0.1);
        assert!((moved.rgb[1].y - 0.28).abs() < 1e-12, "{:?}", moved.rgb);
        assert_eq!(moved.rgb[0].y, 0.0);
        assert_eq!(moved.rgb[3].y, 1.0);
        // Handles cannot leave 0…1.
        let clamped = settings.nudged(RawPointChannel::Green, 0.0, -0.5);
        assert_eq!(clamped.green[0].y, 0.0);
    }

    #[test]
    fn tables_are_256_entries_and_follow_the_curve() {
        let settings = RawCurveSettings::default();
        let table = settings.tone_table();
        assert_eq!(table.len(), 256);
        assert!(table[0].abs() < 1e-12);
        assert!((table[255] - 1.0).abs() < 1e-6);
        let channel = RawCurveSettings::channel_table(&medium_contrast_points());
        assert!(channel[64] < 64.0 / 255.0);
        assert!(channel[192] > 192.0 / 255.0);
    }

    #[test]
    fn core_curve_points_convert_between_scales() {
        let point = RawCurvePoint::new(0.25, 0.5);
        let core = point.to_core();
        assert!((core.x - 63.75).abs() < 1e-12);
        assert_eq!(RawCurvePoint::from_core(core), point);
    }
}
