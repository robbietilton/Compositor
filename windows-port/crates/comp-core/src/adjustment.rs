//! Adjustment-layer settings, mirroring the macOS `LayerAdjustment` record.
//!
//! Every kind carries the settings of every other kind; missing ones mean identity. Field names
//! and ranges must match \`docs/project-format.md\` version 7 and 9 exactly.
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum AdjustmentKind {
    #[serde(rename = "Hue/Saturation")]
    HueSaturation,
    Levels,
    Curves,
    Exposure,
    #[serde(rename = "Gradient Map")]
    GradientMap,
    Grain,
    Invert,
    #[serde(rename = "Black & White")]
    BlackWhite,
    #[serde(rename = "Color Balance")]
    ColorBalance,
    #[serde(rename = "Gaussian Blur")]
    GaussianBlur,
    #[serde(rename = "Motion Blur")]
    MotionBlur,
    #[serde(rename = "Add Noise")]
    AddNoise,
}

impl AdjustmentKind {
    pub const ALL: [AdjustmentKind; 12] = [
        AdjustmentKind::HueSaturation,
        AdjustmentKind::Levels,
        AdjustmentKind::Curves,
        AdjustmentKind::Exposure,
        AdjustmentKind::GradientMap,
        AdjustmentKind::Grain,
        AdjustmentKind::Invert,
        AdjustmentKind::BlackWhite,
        AdjustmentKind::ColorBalance,
        AdjustmentKind::GaussianBlur,
        AdjustmentKind::MotionBlur,
        AdjustmentKind::AddNoise,
    ];

    /// The kinds that sample neighboring pixels; version 9 and up only.
    pub fn samples_neighbors(self) -> bool {
        matches!(self, AdjustmentKind::GaussianBlur | AdjustmentKind::MotionBlur | AdjustmentKind::AddNoise)
    }

    pub fn as_str(self) -> &'static str {
        match self {
            AdjustmentKind::HueSaturation => "Hue/Saturation",
            AdjustmentKind::Levels => "Levels",
            AdjustmentKind::Curves => "Curves",
            AdjustmentKind::Exposure => "Exposure",
            AdjustmentKind::GradientMap => "Gradient Map",
            AdjustmentKind::Grain => "Grain",
            AdjustmentKind::Invert => "Invert",
            AdjustmentKind::BlackWhite => "Black & White",
            AdjustmentKind::ColorBalance => "Color Balance",
            AdjustmentKind::GaussianBlur => "Gaussian Blur",
            AdjustmentKind::MotionBlur => "Motion Blur",
            AdjustmentKind::AddNoise => "Add Noise",
        }
    }
}

/// RGB plus the three primaries, the order `ranges` and `channels` use.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Channel {
    RGB,
    Red,
    Green,
    Blue,
}

impl Default for Channel {
    fn default() -> Self {
        Channel::RGB
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LevelRange {
    pub black: f64,
    pub gamma: f64,
    pub white: f64,
    pub output_black: f64,
    pub output_white: f64,
}

impl Default for LevelRange {
    fn default() -> Self {
        LevelRange { black: 0.0, gamma: 1.0, white: 255.0, output_black: 0.0, output_white: 255.0 }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LevelsSettings {
    #[serde(default)]
    pub channel: Channel,
    #[serde(default = "identity_ranges")]
    pub ranges: [LevelRange; 4],
}

fn identity_ranges() -> [LevelRange; 4] {
    [LevelRange::default(); 4]
}

impl Default for LevelsSettings {
    fn default() -> Self {
        LevelsSettings { channel: Channel::RGB, ranges: identity_ranges() }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct CurvePoint {
    pub x: f64,
    pub y: f64,
}

impl Default for CurvePoint {
    fn default() -> Self {
        CurvePoint { x: 0.0, y: 0.0 }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CurvesSettings {
    #[serde(default)]
    pub channel: Channel,
    #[serde(default = "identity_curves")]
    pub channels: [Vec<CurvePoint>; 4],
}

fn identity_curves() -> [Vec<CurvePoint>; 4] {
    [
        vec![CurvePoint { x: 0.0, y: 0.0 }, CurvePoint { x: 255.0, y: 255.0 }],
        vec![CurvePoint { x: 0.0, y: 0.0 }, CurvePoint { x: 255.0, y: 255.0 }],
        vec![CurvePoint { x: 0.0, y: 0.0 }, CurvePoint { x: 255.0, y: 255.0 }],
        vec![CurvePoint { x: 0.0, y: 0.0 }, CurvePoint { x: 255.0, y: 255.0 }],
    ]
}

impl Default for CurvesSettings {
    fn default() -> Self {
        CurvesSettings { channel: Channel::RGB, channels: identity_curves() }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ColorBalanceSettings {
    pub shadow_cyan_red: f64,
    pub shadow_magenta_green: f64,
    pub shadow_yellow_blue: f64,
    pub mid_cyan_red: f64,
    pub mid_magenta_green: f64,
    pub mid_yellow_blue: f64,
    pub highlight_cyan_red: f64,
    pub highlight_magenta_green: f64,
    pub highlight_yellow_blue: f64,
    pub preserve_luminosity: bool,
}

impl Default for ColorBalanceSettings {
    fn default() -> Self {
        ColorBalanceSettings {
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
        }
    }
}

/// Every kind's settings on one record, as macOS stores them.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Adjustment {
    pub kind: AdjustmentKind,
    #[serde(default)]
    pub hue: f64,
    #[serde(default)]
    pub saturation: f64,
    #[serde(default)]
    pub lightness: f64,
    #[serde(default)]
    pub colorize: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hsv_settings: Option<serde_json::Value>,
    #[serde(default)]
    pub levels: LevelsSettings,
    #[serde(default)]
    pub curves: CurvesSettings,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exposure_settings: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gradient_map_settings: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grain_settings: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub black_white_settings: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color_balance_settings: Option<ColorBalanceSettings>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blur_radius: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub motion_angle: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub motion_distance: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub noise_amount: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub noise_gaussian: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub noise_monochromatic: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub noise_seed: Option<u64>,
}

impl Adjustment {
    pub fn new(kind: AdjustmentKind) -> Self {
        Adjustment {
            kind,
            hue: 0.0,
            saturation: 0.0,
            lightness: 0.0,
            colorize: false,
            hsv_settings: None,
            levels: LevelsSettings::default(),
            curves: CurvesSettings::default(),
            exposure_settings: None,
            gradient_map_settings: None,
            grain_settings: None,
            black_white_settings: None,
            color_balance_settings: None,
            blur_radius: None,
            motion_angle: None,
            motion_distance: None,
            noise_amount: None,
            noise_gaussian: None,
            noise_monochromatic: None,
            noise_seed: None,
        }
    }

    /// True when every stored value sits inside the range the format allows.
    pub fn is_valid(&self) -> bool {
        let finite = |v: f64| v.is_finite();
        if !finite(self.hue) || self.hue.abs() > 360.0 {
            return false;
        }
        if !finite(self.saturation) || self.saturation.abs() > 100.0 {
            return false;
        }
        if !finite(self.lightness) || self.lightness.abs() > 100.0 {
            return false;
        }
        for range in &self.levels.ranges {
            if !finite(range.black)
                || !finite(range.gamma)
                || !finite(range.white)
                || !finite(range.output_black)
                || !finite(range.output_white)
                || range.gamma <= 0.0
                || range.black < 0.0
                || range.white > 255.0
                || range.black >= range.white
            {
                return false;
            }
        }
        for points in &self.curves.channels {
            if points.iter().any(|p| !finite(p.x) || !finite(p.y) || p.x < 0.0 || p.x > 255.0) {
                return false;
            }
            if points.windows(2).any(|w| w[1].x < w[0].x) {
                return false;
            }
        }
        if let Some(radius) = self.blur_radius {
            if !finite(radius) || !(0.1..=250.0).contains(&radius) {
                return false;
            }
        }
        if let Some(angle) = self.motion_angle {
            if !finite(angle) || !(-90.0..=90.0).contains(&angle) {
                return false;
            }
        }
        if let Some(distance) = self.motion_distance {
            if !finite(distance) || !(1.0..=2000.0).contains(&distance) {
                return false;
            }
        }
        if let Some(amount) = self.noise_amount {
            if !finite(amount) || !(0.1..=400.0).contains(&amount) {
                return false;
            }
        }
        if let Some(balance) = &self.color_balance_settings {
            let values = [
                balance.shadow_cyan_red,
                balance.shadow_magenta_green,
                balance.shadow_yellow_blue,
                balance.mid_cyan_red,
                balance.mid_magenta_green,
                balance.mid_yellow_blue,
                balance.highlight_cyan_red,
                balance.highlight_magenta_green,
                balance.highlight_yellow_blue,
            ];
            if values.iter().any(|v| !v.is_finite() || v.abs() > 100.0) {
                return false;
            }
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_adjustment_is_valid() {
        for kind in AdjustmentKind::ALL {
            let adjustment = Adjustment::new(kind);
            assert!(adjustment.is_valid(), "{kind:?}");
        }
    }

    #[test]
    fn out_of_range_values_are_rejected() {
        let mut adjustment = Adjustment::new(AdjustmentKind::HueSaturation);
        adjustment.hue = 361.0;
        assert!(!adjustment.is_valid());
        adjustment.hue = 0.0;
        adjustment.blur_radius = Some(0.0);
        assert!(!adjustment.is_valid());
        adjustment.blur_radius = Some(5.0);
        adjustment.noise_amount = Some(f64::NAN);
        assert!(!adjustment.is_valid());
    }

    #[test]
    fn kind_names_match_the_format() {
        for kind in AdjustmentKind::ALL {
            let json = serde_json::to_string(&kind).unwrap();
            assert_eq!(json, format!("\"{}\"", kind.as_str()));
            let back: AdjustmentKind = serde_json::from_str(&json).unwrap();
            assert_eq!(back, kind);
        }
        assert_eq!(
            serde_json::to_string(&AdjustmentKind::BlackWhite).unwrap(),
            "\"Black & White\""
        );
    }
}
