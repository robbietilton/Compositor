//! The Camera Raw parameter model: nine panels of sliders with their ranges, defaults and repair rules.
//!
//! Every name, range and default is ported from the macOS sources — `CameraRaw.swift`,
//! `CameraRawColor.swift`, `CameraRawDetailOptics.swift` and
//! `CameraRawGeometryCalibration.swift` — so a settings object built here can be handed to the Swift
//! decoder unchanged. Serialized keys are camelCase with no underscores anywhere; the tests enforce
//! that, because the macOS side decodes these property names literally.

use comp_core::Bitmap8;
use serde::{Deserialize, Serialize};

use crate::curve::{self, RawCurvePoint};

/// Exposure in stops of linear light.
pub const EXPOSURE_RANGE: (f64, f64) = (-5.0, 5.0);
/// Every −100…100 slider in the filter.
pub const TONE_RANGE: (f64, f64) = (-100.0, 100.0);
/// Every 0…100 slider in the filter.
pub const UNIT_RANGE: (f64, f64) = (0.0, 100.0);

/// Share of a full warm/cool swing applied to red and blue, kept here so the eyedropper inverts
/// exactly the gains the kernel multiplies.
pub const TEMPERATURE_GAIN: f64 = 0.35;
/// Magenta/green swing shared by red and blue.
pub const TINT_RED_BLUE: f64 = 0.15;
/// Magenta/green swing on green, opposite the other two channels.
pub const TINT_GREEN: f64 = 0.30;

/// `ImageAdjustmentPixels.clamp`: a non-finite value falls back to the slider's default.
pub(crate) fn clamp_to(value: f64, range: (f64, f64), fallback: f64) -> f64 {
    if value.is_finite() {
        value.clamp(range.0, range.1)
    } else {
        fallback
    }
}

#[inline]
fn in_range(value: f64, range: (f64, f64)) -> bool {
    value >= range.0 && value <= range.1
}

/// White balance mode. Raw lighting presets are absent: temperature and tint are relative offsets.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum RawWhiteBalance {
    #[default]
    #[serde(rename = "Custom")]
    Custom,
    #[serde(rename = "Auto")]
    Auto,
}

/// Glow's three looks. Warmth tints Diffusion and Bloom from cool to warm; Halation's fringe stays red.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum RawGlowStyle {
    #[default]
    #[serde(rename = "Diffusion")]
    Diffusion,
    #[serde(rename = "Bloom")]
    Bloom,
    #[serde(rename = "Halation")]
    Halation,
}

impl RawGlowStyle {
    /// The value the effects kernel branches on.
    pub fn kernel_value(self) -> i32 {
        match self {
            RawGlowStyle::Diffusion => 0,
            RawGlowStyle::Bloom => 1,
            RawGlowStyle::Halation => 2,
        }
    }
}

/// Post-crop vignette styles. Highlight Priority protects bright pixels while the amount darkens.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum RawVignetteStyle {
    #[default]
    #[serde(rename = "Highlight Priority")]
    HighlightPriority,
    #[serde(rename = "Color Priority")]
    ColorPriority,
    #[serde(rename = "Paint Overlay")]
    PaintOverlay,
}

impl RawVignetteStyle {
    pub fn kernel_value(self) -> i32 {
        match self {
            RawVignetteStyle::HighlightPriority => 0,
            RawVignetteStyle::ColorPriority => 1,
            RawVignetteStyle::PaintOverlay => 2,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum RawUprightMode {
    #[default]
    #[serde(rename = "Off")]
    Off,
    #[serde(rename = "Guided")]
    Guided,
}

/// Perspective concentrates the correction on the vertical/horizontal axes, Rectilinear spreads it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum RawProjection {
    #[default]
    #[serde(rename = "Perspective")]
    Perspective,
    #[serde(rename = "Rectilinear")]
    Rectilinear,
}

impl RawProjection {
    /// Corner displacement is full strength in Perspective and 0.55 in Rectilinear.
    pub fn strength(self) -> f64 {
        match self {
            RawProjection::Perspective => 1.0,
            RawProjection::Rectilinear => 0.55,
        }
    }
}

/// Which process version the calibration sliders respond to.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum RawProcessVersion {
    #[serde(rename = "Version 1")]
    Version1,
    #[serde(rename = "Version 2")]
    Version2,
    #[serde(rename = "Version 3")]
    Version3,
    #[serde(rename = "Version 4")]
    Version4,
    #[serde(rename = "Version 5")]
    Version5,
    #[default]
    #[serde(rename = "Version 6")]
    Version6,
}

impl RawProcessVersion {
    pub fn kernel_value(self) -> i32 {
        match self {
            RawProcessVersion::Version1 => 1,
            RawProcessVersion::Version2 => 2,
            RawProcessVersion::Version3 => 3,
            RawProcessVersion::Version4 => 4,
            RawProcessVersion::Version5 => 5,
            RawProcessVersion::Version6 => 6,
        }
    }

    /// Older processes move the calibration sliders about half as far.
    pub fn scale(self) -> f64 {
        match self.kernel_value() {
            1 => 0.55,
            2 => 0.65,
            3 => 0.75,
            4 => 0.85,
            5 => 0.92,
            _ => 1.0,
        }
    }
}

/// Parametric regions and point curves. Amounts are −100…100; curve points use 0…1 on both axes.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RawCurveSettings {
    pub shadows: f64,
    pub darks: f64,
    pub lights: f64,
    pub highlights: f64,
    /// Dividers 0…100, kept in order; each parametric slider hands off to the next at its divider.
    pub shadow_split: f64,
    pub dark_split: f64,
    pub light_split: f64,
    pub rgb: Vec<RawCurvePoint>,
    pub red: Vec<RawCurvePoint>,
    pub green: Vec<RawCurvePoint>,
    pub blue: Vec<RawCurvePoint>,
    /// How much the composite curve also changes saturation; 0 keeps it to brightness.
    pub refine_saturation: f64,
}

impl Default for RawCurveSettings {
    fn default() -> Self {
        RawCurveSettings {
            shadows: 0.0,
            darks: 0.0,
            lights: 0.0,
            highlights: 0.0,
            shadow_split: 25.0,
            dark_split: 50.0,
            light_split: 75.0,
            rgb: curve::linear_points(),
            red: curve::linear_points(),
            green: curve::linear_points(),
            blue: curve::linear_points(),
            refine_saturation: 0.0,
        }
    }
}

impl RawCurveSettings {
    /// True when this panel would leave the image alone.
    pub fn adjusts(&self) -> bool {
        self.shadows != 0.0
            || self.darks != 0.0
            || self.lights != 0.0
            || self.highlights != 0.0
            || self.refine_saturation != 0.0
            || !curve::is_linear(&self.rgb)
            || !curve::is_linear(&self.red)
            || !curve::is_linear(&self.green)
            || !curve::is_linear(&self.blue)
    }

    pub fn normalized(&self) -> Self {
        let mut result = self.clone();
        result.shadows = clamp_to(self.shadows, TONE_RANGE, 0.0);
        result.darks = clamp_to(self.darks, TONE_RANGE, 0.0);
        result.lights = clamp_to(self.lights, TONE_RANGE, 0.0);
        result.highlights = clamp_to(self.highlights, TONE_RANGE, 0.0);
        result.refine_saturation = clamp_to(self.refine_saturation, TONE_RANGE, 0.0);
        result.shadow_split = clamp_to(self.shadow_split, (5.0, 90.0), 25.0);
        result.dark_split = clamp_to(self.dark_split, (result.shadow_split + 2.0, 95.0), 50.0);
        result.light_split = clamp_to(self.light_split, (result.dark_split + 2.0, 98.0), 75.0);
        result.rgb = curve::repair(&self.rgb);
        result.red = curve::repair(&self.red);
        result.green = curve::repair(&self.green);
        result.blue = curve::repair(&self.blue);
        result
    }
}

/// Eight color families, each with hue, saturation and luminance shifts of −100…100.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RawMixerSettings {
    pub hue: [f64; 8],
    pub saturation: [f64; 8],
    pub luminance: [f64; 8],
    pub points: Vec<RawPointColor>,
}

impl Default for RawMixerSettings {
    fn default() -> Self {
        RawMixerSettings {
            hue: [0.0; 8],
            saturation: [0.0; 8],
            luminance: [0.0; 8],
            points: Vec::new(),
        }
    }
}

impl RawMixerSettings {
    /// The eight families, in the order the kernel indexes them.
    pub const NAMES: [&'static str; 8] =
        ["Reds", "Oranges", "Yellows", "Greens", "Aquas", "Blues", "Purples", "Magentas"];
    /// Hue centers in degrees, matching the kernel's `mixer_centers`.
    pub const CENTERS: [f64; 8] = [0.0, 30.0, 60.0, 120.0, 180.0, 240.0, 270.0, 300.0];

    pub fn adjusts(&self) -> bool {
        self.hue.iter().any(|v| *v != 0.0)
            || self.saturation.iter().any(|v| *v != 0.0)
            || self.luminance.iter().any(|v| *v != 0.0)
            || self
                .points
                .iter()
                .any(|p| p.hue_shift != 0.0 || p.saturation_shift != 0.0 || p.luminance_shift != 0.0)
    }

    /// How much each family shares a hue, in degrees. Neighbors overlap over a 40° half-width.
    pub fn weights(for_hue_degrees: f64) -> [f64; 8] {
        let mut weights = [0.0; 8];
        for (index, center) in Self::CENTERS.iter().enumerate() {
            let mut distance = (for_hue_degrees - center).abs();
            if distance > 180.0 {
                distance = 360.0 - distance;
            }
            weights[index] = (1.0 - distance / 40.0).max(0.0);
        }
        weights
    }

    /// 24 floats — hue, saturation, luminance for each family — scaled to −1…1.
    pub fn mixer_floats(&self) -> Vec<f32> {
        self.hue
            .iter()
            .chain(self.saturation.iter())
            .chain(self.luminance.iter())
            .map(|value| (*value / 100.0) as f32)
            .collect()
    }

    /// Nine floats per point color, in the kernel's order.
    pub fn point_floats(&self) -> Vec<f32> {
        let mut floats = Vec::with_capacity(self.points.len() * 9);
        for point in &self.points {
            for value in [
                point.hue / 360.0,
                point.saturation,
                point.luminance,
                point.hue_shift / 100.0,
                point.saturation_shift / 100.0,
                point.luminance_shift / 100.0,
                point.hue_range / 360.0,
                point.saturation_range,
                point.luminance_range,
            ] {
                floats.push(value as f32);
            }
        }
        floats
    }

    pub fn normalized(&self) -> Self {
        let mut result = self.clone();
        for index in 0..8 {
            result.hue[index] = clamp_to(self.hue[index], TONE_RANGE, 0.0);
            result.saturation[index] = clamp_to(self.saturation[index], TONE_RANGE, 0.0);
            result.luminance[index] = clamp_to(self.luminance[index], TONE_RANGE, 0.0);
        }
        result.points = self.points.iter().take(8).map(RawPointColor::normalized).collect();
        result
    }
}

/// One picked color and how far its adjustment reaches.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RawPointColor {
    pub hue: f64,
    pub saturation: f64,
    pub luminance: f64,
    pub hue_shift: f64,
    pub saturation_shift: f64,
    pub luminance_shift: f64,
    pub hue_range: f64,
    pub saturation_range: f64,
    pub luminance_range: f64,
    pub visualize: bool,
}

impl Default for RawPointColor {
    fn default() -> Self {
        RawPointColor {
            hue: 0.0,
            saturation: 0.0,
            luminance: 0.0,
            hue_shift: 0.0,
            saturation_shift: 0.0,
            luminance_shift: 0.0,
            hue_range: 30.0,
            saturation_range: 0.4,
            luminance_range: 0.4,
            visualize: false,
        }
    }
}

impl RawPointColor {
    pub fn normalized(&self) -> Self {
        RawPointColor {
            hue: clamp_to(self.hue, (0.0, 360.0), 0.0),
            saturation: clamp_to(self.saturation, (0.0, 1.0), 0.0),
            luminance: clamp_to(self.luminance, (0.0, 1.0), 0.0),
            hue_shift: clamp_to(self.hue_shift, TONE_RANGE, 0.0),
            saturation_shift: clamp_to(self.saturation_shift, TONE_RANGE, 0.0),
            luminance_shift: clamp_to(self.luminance_shift, TONE_RANGE, 0.0),
            hue_range: clamp_to(self.hue_range, (5.0, 180.0), 30.0),
            saturation_range: clamp_to(self.saturation_range, (0.05, 1.0), 0.4),
            luminance_range: clamp_to(self.luminance_range, (0.05, 1.0), 0.4),
            visualize: self.visualize,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RawGradeWheel {
    /// Degrees on the wheel, 0…360.
    pub hue: f64,
    /// 0…100.
    pub saturation: f64,
    /// −100…100.
    pub luminance: f64,
}

impl RawGradeWheel {
    pub fn normalized(self) -> Self {
        RawGradeWheel {
            hue: clamp_to(self.hue, (0.0, 360.0), 0.0),
            saturation: clamp_to(self.saturation, UNIT_RANGE, 0.0),
            luminance: clamp_to(self.luminance, TONE_RANGE, 0.0),
        }
    }
}

/// Four color wheels plus how the three tonal wheels overlap and which end they favor.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RawGradingSettings {
    pub shadows: RawGradeWheel,
    pub midtones: RawGradeWheel,
    pub highlights: RawGradeWheel,
    pub global: RawGradeWheel,
    /// 0…100; higher values let the three tonal wheels overlap more.
    pub blending: f64,
    /// −100…100; negative favors shadows, positive favors highlights.
    pub balance: f64,
}

impl Default for RawGradingSettings {
    fn default() -> Self {
        RawGradingSettings {
            shadows: RawGradeWheel::default(),
            midtones: RawGradeWheel::default(),
            highlights: RawGradeWheel::default(),
            global: RawGradeWheel::default(),
            blending: 50.0,
            balance: 0.0,
        }
    }
}

impl RawGradingSettings {
    pub fn wheels(&self) -> [RawGradeWheel; 4] {
        [self.shadows, self.midtones, self.highlights, self.global]
    }

    pub fn adjusts(&self) -> bool {
        self.wheels().iter().any(|wheel| wheel.saturation != 0.0 || wheel.luminance != 0.0)
    }

    /// Twelve floats: hue turns, saturation 0…1 and luminance −1…1 for the four wheels.
    pub fn grade_floats(&self) -> Vec<f32> {
        self.wheels()
            .iter()
            .flat_map(|wheel| [wheel.hue / 360.0, wheel.saturation / 100.0, wheel.luminance / 100.0])
            .map(|value| value as f32)
            .collect()
    }

    pub fn normalized(&self) -> Self {
        RawGradingSettings {
            shadows: self.shadows.normalized(),
            midtones: self.midtones.normalized(),
            highlights: self.highlights.normalized(),
            global: self.global.normalized(),
            blending: clamp_to(self.blending, UNIT_RANGE, 50.0),
            balance: clamp_to(self.balance, TONE_RANGE, 0.0),
        }
    }
}

/// Sharpening and manual noise reduction. Amount is 0…150; the rest use Camera Raw's 0…100 ranges.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RawDetailSettings {
    pub sharpen_amount: f64,
    pub sharpen_radius: f64,
    pub sharpen_detail: f64,
    pub sharpen_masking: f64,
    pub noise_luminance: f64,
    pub noise_luminance_detail: f64,
    pub noise_luminance_contrast: f64,
    pub noise_color: f64,
    pub noise_color_detail: f64,
    pub noise_color_smoothness: f64,
}

impl Default for RawDetailSettings {
    fn default() -> Self {
        RawDetailSettings {
            sharpen_amount: 0.0,
            sharpen_radius: 10.0,
            sharpen_detail: 25.0,
            sharpen_masking: 0.0,
            noise_luminance: 0.0,
            noise_luminance_detail: 50.0,
            noise_luminance_contrast: 0.0,
            noise_color: 0.0,
            noise_color_detail: 50.0,
            noise_color_smoothness: 50.0,
        }
    }
}

impl RawDetailSettings {
    pub const SHARPEN_AMOUNT_RANGE: (f64, f64) = (0.0, 150.0);

    pub fn adjusts_sharpening(&self) -> bool {
        self.sharpen_amount != 0.0
    }

    pub fn adjusts_noise(&self) -> bool {
        self.noise_luminance != 0.0 || self.noise_color != 0.0
    }

    pub fn adjusts(&self) -> bool {
        self.adjusts_sharpening() || self.adjusts_noise()
    }

    pub fn normalized(&self) -> Self {
        RawDetailSettings {
            sharpen_amount: clamp_to(self.sharpen_amount, Self::SHARPEN_AMOUNT_RANGE, 0.0),
            sharpen_radius: clamp_to(self.sharpen_radius, UNIT_RANGE, 10.0),
            sharpen_detail: clamp_to(self.sharpen_detail, UNIT_RANGE, 25.0),
            sharpen_masking: clamp_to(self.sharpen_masking, UNIT_RANGE, 0.0),
            noise_luminance: clamp_to(self.noise_luminance, UNIT_RANGE, 0.0),
            noise_luminance_detail: clamp_to(self.noise_luminance_detail, UNIT_RANGE, 50.0),
            noise_luminance_contrast: clamp_to(self.noise_luminance_contrast, UNIT_RANGE, 0.0),
            noise_color: clamp_to(self.noise_color, UNIT_RANGE, 0.0),
            noise_color_detail: clamp_to(self.noise_color_detail, UNIT_RANGE, 50.0),
            noise_color_smoothness: clamp_to(self.noise_color_smoothness, UNIT_RANGE, 50.0),
        }
    }
}

/// Lens profile toggles, manual distortion, defringe and lens-vignetting correction.
///
/// Profile metadata is not available on a rendered layer, so the profile sliders only scale generic
/// correction strength, exactly as the macOS filter does.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RawOpticsSettings {
    pub remove_chromatic_aberration: bool,
    pub enable_lens_profile: bool,
    pub profile_distortion: f64,
    pub profile_vignetting: f64,
    pub distortion: f64,
    pub purple_amount: f64,
    pub purple_hue_low: f64,
    pub purple_hue_high: f64,
    pub green_amount: f64,
    pub green_hue_low: f64,
    pub green_hue_high: f64,
    pub vignette_amount: f64,
    pub vignette_midpoint: f64,
}

impl Default for RawOpticsSettings {
    fn default() -> Self {
        RawOpticsSettings {
            remove_chromatic_aberration: false,
            enable_lens_profile: false,
            profile_distortion: 100.0,
            profile_vignetting: 100.0,
            distortion: 0.0,
            purple_amount: 0.0,
            purple_hue_low: 270.0,
            purple_hue_high: 310.0,
            green_amount: 0.0,
            green_hue_low: 60.0,
            green_hue_high: 120.0,
            vignette_amount: 0.0,
            vignette_midpoint: 50.0,
        }
    }
}

impl RawOpticsSettings {
    /// The Lens Correction filter's own strength, which scales manual and profile distortion.
    pub const PROFILE_STRENGTH: f64 = 0.35;

    pub fn adjusts(&self) -> bool {
        self.remove_chromatic_aberration
            || self.enable_lens_profile
            || self.distortion != 0.0
            || self.purple_amount != 0.0
            || self.green_amount != 0.0
            || self.vignette_amount != 0.0
    }

    pub fn normalized(&self) -> Self {
        let mut result = RawOpticsSettings {
            remove_chromatic_aberration: self.remove_chromatic_aberration,
            enable_lens_profile: self.enable_lens_profile,
            profile_distortion: clamp_to(self.profile_distortion, UNIT_RANGE, 100.0),
            profile_vignetting: clamp_to(self.profile_vignetting, UNIT_RANGE, 100.0),
            distortion: clamp_to(self.distortion, TONE_RANGE, 0.0),
            purple_amount: clamp_to(self.purple_amount, UNIT_RANGE, 0.0),
            purple_hue_low: clamp_to(self.purple_hue_low, (0.0, 360.0), 270.0),
            purple_hue_high: clamp_to(self.purple_hue_high, (0.0, 360.0), 310.0),
            green_amount: clamp_to(self.green_amount, UNIT_RANGE, 0.0),
            green_hue_low: clamp_to(self.green_hue_low, (0.0, 360.0), 60.0),
            green_hue_high: clamp_to(self.green_hue_high, (0.0, 360.0), 120.0),
            vignette_amount: clamp_to(self.vignette_amount, TONE_RANGE, 0.0),
            vignette_midpoint: clamp_to(self.vignette_midpoint, UNIT_RANGE, 50.0),
        };
        if result.purple_hue_low > result.purple_hue_high {
            std::mem::swap(&mut result.purple_hue_low, &mut result.purple_hue_high);
        }
        if result.green_hue_low > result.green_hue_high {
            std::mem::swap(&mut result.green_hue_low, &mut result.green_hue_high);
        }
        result
    }

    /// Combined radial distortion passed to the lens warp.
    pub fn distortion_k(&self) -> f64 {
        let manual = self.distortion / 100.0 * Self::PROFILE_STRENGTH;
        let profile = if self.enable_lens_profile {
            self.profile_distortion / 100.0 * Self::PROFILE_STRENGTH
        } else {
            0.0
        };
        manual + profile
    }
}

/// A guide line in normalized image coordinates, 0…1 from the top-left of the pixel grid.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RawGeometryGuide {
    pub start_x: f64,
    pub start_y: f64,
    pub end_x: f64,
    pub end_y: f64,
}

impl RawGeometryGuide {
    pub fn length(&self) -> f64 {
        ((self.end_x - self.start_x).powi(2) + (self.end_y - self.start_y).powi(2)).sqrt()
    }
}

/// Rotation, perspective, zoom and crop.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RawGeometrySettings {
    pub upright: RawUprightMode,
    pub projection: RawProjection,
    pub vertical: f64,
    pub horizontal: f64,
    pub rotate: f64,
    pub aspect: f64,
    pub scale: f64,
    pub offset_x: f64,
    pub offset_y: f64,
    pub constrain_crop: bool,
    pub guides: Vec<RawGeometryGuide>,
}

impl RawGeometrySettings {
    pub const ROTATE_RANGE: (f64, f64) = (-45.0, 45.0);
    /// A guide shorter than this cannot be read, so Guided must not warp the picture.
    pub const MIN_GUIDE_LENGTH: f64 = 0.01;

    pub fn adjusts(&self) -> bool {
        self.uses_guides()
            || self.vertical != 0.0
            || self.horizontal != 0.0
            || self.rotate != 0.0
            || self.aspect != 0.0
            || self.scale != 0.0
            || self.offset_x != 0.0
            || self.offset_y != 0.0
    }

    fn uses_guides(&self) -> bool {
        self.upright == RawUprightMode::Guided
            && self.guides.iter().any(|guide| guide.length() > Self::MIN_GUIDE_LENGTH)
    }

    pub fn normalized(&self) -> Self {
        RawGeometrySettings {
            upright: self.upright,
            projection: self.projection,
            vertical: clamp_to(self.vertical, TONE_RANGE, 0.0),
            horizontal: clamp_to(self.horizontal, TONE_RANGE, 0.0),
            rotate: clamp_to(self.rotate, Self::ROTATE_RANGE, 0.0),
            aspect: clamp_to(self.aspect, TONE_RANGE, 0.0),
            scale: clamp_to(self.scale, TONE_RANGE, 0.0),
            offset_x: clamp_to(self.offset_x, TONE_RANGE, 0.0),
            offset_y: clamp_to(self.offset_y, TONE_RANGE, 0.0),
            constrain_crop: self.constrain_crop,
            guides: self
                .guides
                .iter()
                .copied()
                .filter(|guide| guide.length() > Self::MIN_GUIDE_LENGTH)
                .collect(),
        }
    }

    /// The vertical/horizontal/rotate corrections after Guided mode folds in its first two lines.
    pub fn effective_corrections(&self) -> (f64, f64, f64) {
        match self.upright {
            RawUprightMode::Off => (self.vertical, self.horizontal, self.rotate),
            RawUprightMode::Guided => {
                let (vertical, horizontal, rotate) = guided_corrections(&self.guides);
                (self.vertical + vertical, self.horizontal + horizontal, self.rotate + rotate)
            }
        }
    }
}

/// Guided mode reads at most two lines: the first sets rotation, the second picks the axis to fix.
pub fn guided_corrections(guides: &[RawGeometryGuide]) -> (f64, f64, f64) {
    let Some(first) = guides.first() else {
        return (0.0, 0.0, 0.0);
    };
    let dx = first.end_x - first.start_x;
    let dy = first.end_y - first.start_y;
    if (dx * dx + dy * dy).sqrt() <= 1e-4 {
        return (0.0, 0.0, 0.0);
    }
    let angle = dy.atan2(dx).to_degrees();
    let mut rotate = -angle;
    if rotate > 45.0 {
        rotate -= 90.0;
    } else if rotate < -45.0 {
        rotate += 90.0;
    }
    let mut vertical = 0.0;
    let mut horizontal = 0.0;
    if let Some(second) = guides.get(1) {
        let sx = second.end_x - second.start_x;
        let sy = second.end_y - second.start_y;
        if (sx * sx + sy * sy).sqrt() > 1e-4 {
            let second_angle = sy.atan2(sx).to_degrees();
            if second_angle.abs() > 45.0 {
                vertical = if second_angle > 0.0 { 25.0 } else { -25.0 };
            } else {
                horizontal = if second_angle > 0.0 { 25.0 } else { -25.0 };
            }
        }
    }
    (vertical, horizontal, rotate)
}

/// Camera calibration, applied before the main grade.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RawCalibrationSettings {
    pub process: RawProcessVersion,
    pub shadow_tint: f64,
    pub red_hue: f64,
    pub red_saturation: f64,
    pub green_hue: f64,
    pub green_saturation: f64,
    pub blue_hue: f64,
    pub blue_saturation: f64,
}

impl RawCalibrationSettings {
    pub fn adjusts(&self) -> bool {
        self.shadow_tint != 0.0
            || self.red_hue != 0.0
            || self.red_saturation != 0.0
            || self.green_hue != 0.0
            || self.green_saturation != 0.0
            || self.blue_hue != 0.0
            || self.blue_saturation != 0.0
    }

    pub fn normalized(&self) -> Self {
        RawCalibrationSettings {
            process: self.process,
            shadow_tint: clamp_to(self.shadow_tint, TONE_RANGE, 0.0),
            red_hue: clamp_to(self.red_hue, TONE_RANGE, 0.0),
            red_saturation: clamp_to(self.red_saturation, TONE_RANGE, 0.0),
            green_hue: clamp_to(self.green_hue, TONE_RANGE, 0.0),
            green_saturation: clamp_to(self.green_saturation, TONE_RANGE, 0.0),
            blue_hue: clamp_to(self.blue_hue, TONE_RANGE, 0.0),
            blue_saturation: clamp_to(self.blue_saturation, TONE_RANGE, 0.0),
        }
    }
}

/// Temporary clipping view while Option is held on a Light slider. Never written into the layer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RawClipping {
    /// Clipped channels lit on black. Exposure, Highlights and Whites.
    Highlights,
    /// Clipped channels dark on white. Shadows and Blacks.
    Shadows,
}

impl RawClipping {
    /// The value the light and color kernel branches on.
    pub fn kernel_value(self) -> i32 {
        match self {
            RawClipping::Highlights => 1,
            RawClipping::Shadows => 2,
        }
    }
}

/// The panel eye toggles: a hidden group contributes nothing to the render.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RawGroupVisibility {
    pub light: bool,
    pub color: bool,
    pub effects: bool,
    pub curve: bool,
    pub mixer: bool,
    pub grading: bool,
    pub detail: bool,
    pub optics: bool,
    pub geometry: bool,
    pub calibration: bool,
}

impl Default for RawGroupVisibility {
    fn default() -> Self {
        RawGroupVisibility {
            light: true,
            color: true,
            effects: true,
            curve: true,
            mixer: true,
            grading: true,
            detail: true,
            optics: true,
            geometry: true,
            calibration: true,
        }
    }
}

/// Camera Raw settings. Defaults leave the image unchanged.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RawSettings {
    pub white_balance: RawWhiteBalance,
    /// Relative cool-to-warm, −100…100. Positive is warmer.
    pub temperature: f64,
    /// Green-to-magenta, −100…100. Positive is magenta.
    pub tint: f64,
    /// Stops of linear light, −5…5.
    pub exposure: f64,
    pub contrast: f64,
    pub highlights: f64,
    pub shadows: f64,
    pub whites: f64,
    pub blacks: f64,
    pub vibrance: f64,
    pub saturation: f64,
    /// Local contrast, −100…100. Texture is the finer band, Clarity the broader one.
    pub texture: f64,
    pub clarity: f64,
    /// −100…100. Positive deepens contrast and saturation; negative lifts shadows and fades color.
    pub dehaze: f64,
    /// 0…100. Range, spread and warmth are idle while this stays at zero.
    pub glow: f64,
    pub glow_style: RawGlowStyle,
    pub glow_range: f64,
    pub glow_spread: f64,
    pub glow_warmth: f64,
    /// −100…100. Negative darkens the edges, positive lightens them. The center is left alone.
    pub vignette_amount: f64,
    pub vignette_style: RawVignetteStyle,
    pub vignette_midpoint: f64,
    pub vignette_roundness: f64,
    pub vignette_feather: f64,
    /// Used only while `vignette_amount` darkens, and only for Highlight Priority.
    pub vignette_highlights: f64,
    /// 0…100. Zero adds no grain.
    pub grain_amount: f64,
    pub grain_size: f64,
    pub grain_roughness: f64,
    pub curve: RawCurveSettings,
    pub mixer: RawMixerSettings,
    pub grading: RawGradingSettings,
    pub detail: RawDetailSettings,
    pub optics: RawOpticsSettings,
    pub geometry: RawGeometrySettings,
    pub calibration: RawCalibrationSettings,
}

impl Default for RawSettings {
    fn default() -> Self {
        RawSettings {
            white_balance: RawWhiteBalance::Custom,
            temperature: 0.0,
            tint: 0.0,
            exposure: 0.0,
            contrast: 0.0,
            highlights: 0.0,
            shadows: 0.0,
            whites: 0.0,
            blacks: 0.0,
            vibrance: 0.0,
            saturation: 0.0,
            texture: 0.0,
            clarity: 0.0,
            dehaze: 0.0,
            glow: 0.0,
            glow_style: RawGlowStyle::Diffusion,
            glow_range: 0.0,
            glow_spread: 0.0,
            glow_warmth: 0.0,
            vignette_amount: 0.0,
            vignette_style: RawVignetteStyle::HighlightPriority,
            vignette_midpoint: 50.0,
            vignette_roundness: 0.0,
            vignette_feather: 50.0,
            vignette_highlights: 0.0,
            grain_amount: 0.0,
            grain_size: 25.0,
            grain_roughness: 50.0,
            curve: RawCurveSettings::default(),
            mixer: RawMixerSettings::default(),
            grading: RawGradingSettings::default(),
            detail: RawDetailSettings::default(),
            optics: RawOpticsSettings::default(),
            geometry: RawGeometrySettings::default(),
            calibration: RawCalibrationSettings::default(),
        }
    }
}

impl RawSettings {
    pub fn adjusts_light(&self) -> bool {
        self.exposure != 0.0
            || self.contrast != 0.0
            || self.highlights != 0.0
            || self.shadows != 0.0
            || self.whites != 0.0
            || self.blacks != 0.0
    }

    pub fn adjusts_color(&self) -> bool {
        self.temperature != 0.0 || self.tint != 0.0 || self.vibrance != 0.0 || self.saturation != 0.0
    }

    pub fn adjusts_effects(&self) -> bool {
        self.texture != 0.0
            || self.clarity != 0.0
            || self.dehaze != 0.0
            || self.glow != 0.0
            || self.vignette_amount != 0.0
            || self.grain_amount != 0.0
    }

    pub fn adjusts_curve(&self) -> bool {
        self.curve.adjusts()
    }
    pub fn adjusts_mixer(&self) -> bool {
        self.mixer.adjusts()
    }
    pub fn adjusts_grading(&self) -> bool {
        self.grading.adjusts()
    }
    pub fn adjusts_detail(&self) -> bool {
        self.detail.adjusts()
    }
    pub fn adjusts_optics(&self) -> bool {
        self.optics.adjusts()
    }
    pub fn adjusts_geometry(&self) -> bool {
        self.geometry.adjusts()
    }
    pub fn adjusts_calibration(&self) -> bool {
        self.calibration.adjusts()
    }

    /// True when the grade would leave the image alone and the pipeline can return a copy.
    pub fn is_identity(&self) -> bool {
        !self.adjusts_light()
            && !self.adjusts_color()
            && !self.adjusts_effects()
            && !self.adjusts_curve()
            && !self.adjusts_mixer()
            && !self.adjusts_grading()
            && !self.adjusts_detail()
            && !self.adjusts_optics()
            && !self.adjusts_geometry()
            && !self.adjusts_calibration()
    }

    /// The macOS range check. `normalized` runs first in the pipeline, so a false result means a
    /// caller supplied an out-of-range value directly.
    pub fn is_valid(&self) -> bool {
        self.exposure.is_finite()
            && in_range(self.exposure, EXPOSURE_RANGE)
            && [
                self.contrast,
                self.highlights,
                self.shadows,
                self.whites,
                self.blacks,
                self.temperature,
                self.tint,
                self.vibrance,
                self.saturation,
                self.texture,
                self.clarity,
                self.dehaze,
                self.glow_range,
                self.glow_spread,
                self.glow_warmth,
                self.vignette_amount,
                self.vignette_roundness,
            ]
            .iter()
            .all(|value| value.is_finite() && in_range(*value, TONE_RANGE))
            && [
                self.glow,
                self.vignette_midpoint,
                self.vignette_feather,
                self.vignette_highlights,
                self.grain_amount,
                self.grain_size,
                self.grain_roughness,
            ]
            .iter()
            .all(|value| value.is_finite() && in_range(*value, UNIT_RANGE))
    }

    /// Clamps every slider into its range and repairs the group settings; the pipeline always runs
    /// this first, exactly as `CameraRawSettings.normalized` does on macOS.
    pub fn normalized(&self) -> Self {
        let mut result = self.clone();
        result.exposure = clamp_to(self.exposure, EXPOSURE_RANGE, 0.0);
        result.contrast = clamp_to(self.contrast, TONE_RANGE, 0.0);
        result.highlights = clamp_to(self.highlights, TONE_RANGE, 0.0);
        result.shadows = clamp_to(self.shadows, TONE_RANGE, 0.0);
        result.whites = clamp_to(self.whites, TONE_RANGE, 0.0);
        result.blacks = clamp_to(self.blacks, TONE_RANGE, 0.0);
        result.temperature = clamp_to(self.temperature, TONE_RANGE, 0.0);
        result.tint = clamp_to(self.tint, TONE_RANGE, 0.0);
        result.vibrance = clamp_to(self.vibrance, TONE_RANGE, 0.0);
        result.saturation = clamp_to(self.saturation, TONE_RANGE, 0.0);
        result.texture = clamp_to(self.texture, TONE_RANGE, 0.0);
        result.clarity = clamp_to(self.clarity, TONE_RANGE, 0.0);
        result.dehaze = clamp_to(self.dehaze, TONE_RANGE, 0.0);
        result.glow = clamp_to(self.glow, UNIT_RANGE, 0.0);
        result.glow_range = clamp_to(self.glow_range, TONE_RANGE, 0.0);
        result.glow_spread = clamp_to(self.glow_spread, TONE_RANGE, 0.0);
        result.glow_warmth = clamp_to(self.glow_warmth, TONE_RANGE, 0.0);
        result.vignette_amount = clamp_to(self.vignette_amount, TONE_RANGE, 0.0);
        result.vignette_midpoint = clamp_to(self.vignette_midpoint, UNIT_RANGE, 50.0);
        result.vignette_roundness = clamp_to(self.vignette_roundness, TONE_RANGE, 0.0);
        result.vignette_feather = clamp_to(self.vignette_feather, UNIT_RANGE, 50.0);
        result.vignette_highlights = clamp_to(self.vignette_highlights, UNIT_RANGE, 0.0);
        result.grain_amount = clamp_to(self.grain_amount, UNIT_RANGE, 0.0);
        result.grain_size = clamp_to(self.grain_size, UNIT_RANGE, 25.0);
        result.grain_roughness = clamp_to(self.grain_roughness, UNIT_RANGE, 50.0);
        result.curve = self.curve.normalized();
        result.mixer = self.mixer.normalized();
        result.grading = self.grading.normalized();
        result.detail = self.detail.normalized();
        result.optics = self.optics.normalized();
        result.geometry = self.geometry.normalized();
        result.calibration = self.calibration.normalized();
        result
    }

    /// The grade with a panel's eye turned off: that group's amounts become zero and the rest stay.
    pub fn applying(&self, shows: &RawGroupVisibility) -> Self {
        let mut result = self.clone();
        if !shows.light {
            result.exposure = 0.0;
            result.contrast = 0.0;
            result.highlights = 0.0;
            result.shadows = 0.0;
            result.whites = 0.0;
            result.blacks = 0.0;
        }
        if !shows.color {
            result.temperature = 0.0;
            result.tint = 0.0;
            result.vibrance = 0.0;
            result.saturation = 0.0;
        }
        if !shows.effects {
            result.texture = 0.0;
            result.clarity = 0.0;
            result.dehaze = 0.0;
            result.glow = 0.0;
            result.vignette_amount = 0.0;
            result.grain_amount = 0.0;
        }
        if !shows.curve {
            result.curve = RawCurveSettings::default();
        }
        if !shows.mixer {
            result.mixer = RawMixerSettings::default();
        }
        if !shows.grading {
            result.grading = RawGradingSettings::default();
        }
        if !shows.detail {
            result.detail = RawDetailSettings::default();
        }
        if !shows.optics {
            result.optics = RawOpticsSettings::default();
        }
        if !shows.geometry {
            result.geometry = RawGeometrySettings::default();
        }
        if !shows.calibration {
            result.calibration = RawCalibrationSettings::default();
        }
        result
    }

    /// Camera Raw's 0…100 grain size, in the pixel scale the grain kernel uses.
    pub fn grain_kernel_size(&self) -> f64 {
        0.5 + (self.grain_size / 100.0) * 19.5
    }

    /// Channel multipliers for temperature and tint. Neutral is (1, 1, 1).
    pub fn gains(&self) -> (f64, f64, f64) {
        let warm = self.temperature / 100.0;
        let magenta = self.tint / 100.0;
        (
            1.0 + TEMPERATURE_GAIN * warm + TINT_RED_BLUE * magenta,
            1.0 - TINT_GREEN * magenta,
            1.0 - TEMPERATURE_GAIN * warm + TINT_RED_BLUE * magenta,
        )
    }

    /// Temperature and tint that bring one straight sRGB pixel to neutral, using the same gains the
    /// kernel multiplies. None when a channel is missing or the cast cannot be expressed on those axes.
    pub fn neutralize_straight(red: f64, green: f64, blue: f64) -> Option<(f64, f64)> {
        Self::neutralize_linear(
            crate::math::srgb_to_linear(red),
            crate::math::srgb_to_linear(green),
            crate::math::srgb_to_linear(blue),
        )
    }

    /// The same solve in linear light, which is what the Auto white balance scans.
    pub fn neutralize_linear(red: f64, green: f64, blue: f64) -> Option<(f64, f64)> {
        if !(red > 1e-4 && green > 1e-4 && blue > 1e-4) {
            return None;
        }
        let a1 = TEMPERATURE_GAIN * red;
        let b1 = TINT_RED_BLUE * red + TINT_GREEN * green;
        let c1 = green - red;
        let a2 = -TEMPERATURE_GAIN * blue;
        let b2 = TINT_RED_BLUE * blue + TINT_GREEN * green;
        let c2 = green - blue;
        let determinant = a1 * b2 - a2 * b1;
        if determinant.abs() <= 1e-8 {
            return None;
        }
        let warm = (c1 * b2 - c2 * b1) / determinant;
        let magenta = (a1 * c2 - a2 * c1) / determinant;
        if !warm.is_finite() || !magenta.is_finite() {
            return None;
        }
        Some((warm * 100.0, magenta * 100.0))
    }
}

/// Gray-world balance of the opaque pixels: the average of the layer in linear light, solved back to
/// the two white-balance axes. None when the image has no coverage or no solution.
pub fn auto_balance(image: &Bitmap8) -> Option<(f64, f64)> {
    if image.width() == 0 || image.height() == 0 {
        return None;
    }
    let mut red = 0.0;
    let mut green = 0.0;
    let mut blue = 0.0;
    let mut count = 0.0;
    for pixel in image.pixels().chunks_exact(4) {
        if pixel[3] == 0 {
            continue;
        }
        red += crate::math::srgb_to_linear(pixel[0] as f64 / 255.0);
        green += crate::math::srgb_to_linear(pixel[1] as f64 / 255.0);
        blue += crate::math::srgb_to_linear(pixel[2] as f64 / 255.0);
        count += 1.0;
    }
    if count <= 0.0 {
        return None;
    }
    RawSettings::neutralize_linear(red / count, green / count, blue / count)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::curve::RawCurvePoint;

    /// A settings object with every field moved off its default, so a serialization test sees every
    /// key the model can write.
    fn populated() -> RawSettings {
        RawSettings {
            white_balance: RawWhiteBalance::Auto,
            temperature: 12.0,
            tint: -8.0,
            exposure: 1.5,
            contrast: 22.0,
            highlights: -31.0,
            shadows: 17.0,
            whites: 44.0,
            blacks: -19.0,
            vibrance: 26.0,
            saturation: -12.0,
            texture: 14.0,
            clarity: -7.0,
            dehaze: 9.0,
            glow: 33.0,
            glow_style: RawGlowStyle::Halation,
            glow_range: 21.0,
            glow_spread: -3.0,
            glow_warmth: 12.0,
            vignette_amount: -24.0,
            vignette_style: RawVignetteStyle::PaintOverlay,
            vignette_midpoint: 44.0,
            vignette_roundness: -6.0,
            vignette_feather: 61.0,
            vignette_highlights: 18.0,
            grain_amount: 27.0,
            grain_size: 39.0,
            grain_roughness: 55.0,
            curve: RawCurveSettings {
                shadows: 5.0,
                darks: -6.0,
                lights: 7.0,
                highlights: -8.0,
                shadow_split: 22.0,
                dark_split: 48.0,
                light_split: 71.0,
                rgb: crate::curve::medium_contrast_points(),
                red: vec![RawCurvePoint::new(0.0, 0.0), RawCurvePoint::new(0.5, 0.6), RawCurvePoint::new(1.0, 1.0)],
                green: crate::curve::linear_points(),
                blue: crate::curve::linear_points(),
                refine_saturation: 15.0,
            },
            mixer: RawMixerSettings {
                hue: [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0],
                saturation: [-1.0, -2.0, -3.0, -4.0, -5.0, -6.0, -7.0, -8.0],
                luminance: [9.0, 8.0, 7.0, 6.0, 5.0, 4.0, 3.0, 2.0],
                points: vec![RawPointColor {
                    hue: 21.0,
                    saturation: 0.5,
                    luminance: 0.6,
                    hue_shift: 4.0,
                    saturation_shift: -5.0,
                    luminance_shift: 6.0,
                    hue_range: 42.0,
                    saturation_range: 0.6,
                    luminance_range: 0.7,
                    visualize: true,
                }],
            },
            grading: RawGradingSettings {
                shadows: RawGradeWheel { hue: 210.0, saturation: 22.0, luminance: -11.0 },
                midtones: RawGradeWheel { hue: 30.0, saturation: 12.0, luminance: 5.0 },
                highlights: RawGradeWheel { hue: 60.0, saturation: 8.0, luminance: 3.0 },
                global: RawGradeWheel { hue: 180.0, saturation: 6.0, luminance: -2.0 },
                blending: 63.0,
                balance: -21.0,
            },
            detail: RawDetailSettings {
                sharpen_amount: 64.0,
                sharpen_radius: 33.0,
                sharpen_detail: 41.0,
                sharpen_masking: 12.0,
                noise_luminance: 28.0,
                noise_luminance_detail: 61.0,
                noise_luminance_contrast: 13.0,
                noise_color: 34.0,
                noise_color_detail: 57.0,
                noise_color_smoothness: 44.0,
            },
            optics: RawOpticsSettings {
                remove_chromatic_aberration: true,
                enable_lens_profile: true,
                profile_distortion: 71.0,
                profile_vignetting: 66.0,
                distortion: -23.0,
                purple_amount: 42.0,
                purple_hue_low: 268.0,
                purple_hue_high: 315.0,
                green_amount: 37.0,
                green_hue_low: 55.0,
                green_hue_high: 133.0,
                vignette_amount: 29.0,
                vignette_midpoint: 58.0,
            },
            geometry: RawGeometrySettings {
                upright: RawUprightMode::Guided,
                projection: RawProjection::Rectilinear,
                vertical: 11.0,
                horizontal: -13.0,
                rotate: 4.5,
                aspect: 9.0,
                scale: 17.0,
                offset_x: -12.0,
                offset_y: 14.0,
                constrain_crop: true,
                guides: vec![RawGeometryGuide { start_x: 0.1, start_y: 0.2, end_x: 0.9, end_y: 0.4 }],
            },
            calibration: RawCalibrationSettings {
                process: RawProcessVersion::Version4,
                shadow_tint: 12.0,
                red_hue: -9.0,
                red_saturation: 18.0,
                green_hue: 7.0,
                green_saturation: -11.0,
                blue_hue: 5.0,
                blue_saturation: 13.0,
            },
        }
    }

    #[test]
    fn defaults_are_neutral_and_valid() {
        let settings = RawSettings::default();
        assert!(settings.is_identity());
        assert!(settings.is_valid());
        assert_eq!(settings.normalized(), settings);
        // Group defaults are the Camera Raw ones, not plain zeros.
        assert_eq!(settings.curve.shadow_split, 25.0);
        assert_eq!(settings.curve.dark_split, 50.0);
        assert_eq!(settings.curve.light_split, 75.0);
        assert_eq!(settings.vignette_midpoint, 50.0);
        assert_eq!(settings.grain_size, 25.0);
        assert_eq!(settings.grain_roughness, 50.0);
        assert_eq!(settings.detail.sharpen_radius, 10.0);
        assert_eq!(settings.detail.sharpen_detail, 25.0);
        assert_eq!(settings.detail.noise_luminance_detail, 50.0);
        assert_eq!(settings.detail.noise_color_smoothness, 50.0);
        assert_eq!(settings.optics.profile_distortion, 100.0);
        assert_eq!(settings.optics.purple_hue_low, 270.0);
        assert_eq!(settings.optics.green_hue_low, 60.0);
        assert_eq!(settings.grading.blending, 50.0);
        assert_eq!(settings.calibration.process, RawProcessVersion::Version6);
    }

    #[test]
    fn serialized_keys_are_camel_case_without_underscores() {
        let json = serde_json::to_string(&populated()).expect("settings serialize");
        assert!(!json.contains('_'), "a macOS decoder would reject an underscored key: {json}");
        // Spot-check the compound names that would otherwise be snake_case.
        for key in [
            "\"shadowSplit\"",
            "\"lightSplit\"",
            "\"refineSaturation\"",
            "\"vignetteMidpoint\"",
            "\"vignetteHighlights\"",
            "\"grainRoughness\"",
            "\"sharpenAmount\"",
            "\"sharpenMasking\"",
            "\"noiseLuminanceDetail\"",
            "\"noiseColorSmoothness\"",
            "\"removeChromaticAberration\"",
            "\"purpleHueLow\"",
            "\"offsetX\"",
            "\"constrainCrop\"",
            "\"startX\"",
            "\"shadowTint\"",
        ] {
            assert!(json.contains(key), "missing {key}");
        }
    }

    #[test]
    fn enum_spellings_match_the_macos_raw_values() {
        let cases = [
            (serde_json::to_value(RawWhiteBalance::Auto).unwrap(), "Auto"),
            (serde_json::to_value(RawWhiteBalance::Custom).unwrap(), "Custom"),
            (serde_json::to_value(RawGlowStyle::Diffusion).unwrap(), "Diffusion"),
            (serde_json::to_value(RawGlowStyle::Bloom).unwrap(), "Bloom"),
            (serde_json::to_value(RawGlowStyle::Halation).unwrap(), "Halation"),
            (serde_json::to_value(RawVignetteStyle::HighlightPriority).unwrap(), "Highlight Priority"),
            (serde_json::to_value(RawVignetteStyle::ColorPriority).unwrap(), "Color Priority"),
            (serde_json::to_value(RawVignetteStyle::PaintOverlay).unwrap(), "Paint Overlay"),
            (serde_json::to_value(RawUprightMode::Guided).unwrap(), "Guided"),
            (serde_json::to_value(RawProjection::Rectilinear).unwrap(), "Rectilinear"),
            (serde_json::to_value(RawProcessVersion::Version1).unwrap(), "Version 1"),
            (serde_json::to_value(RawProcessVersion::Version6).unwrap(), "Version 6"),
        ];
        for (value, expected) in cases {
            assert_eq!(value.as_str(), Some(expected));
        }
    }

    #[test]
    fn settings_round_trip_through_json() {
        let settings = populated();
        let json = serde_json::to_string(&settings).expect("settings serialize");
        let restored: RawSettings = serde_json::from_str(&json).expect("settings deserialize");
        assert_eq!(restored, settings);
    }

    #[test]
    fn a_partial_json_object_fills_in_the_defaults() {
        let settings: RawSettings = serde_json::from_str("{\"exposure\":2.0,\"curve\":{\"shadows\":30.0}}")
            .expect("a partial object decodes");
        assert_eq!(settings.exposure, 2.0);
        assert_eq!(settings.curve.shadows, 30.0);
        assert_eq!(settings.curve.dark_split, 50.0, "untouched groups keep their defaults");
        assert_eq!(settings.detail.sharpen_radius, 10.0);
    }

    #[test]
    fn normalized_clamps_every_range() {
        let wild = RawSettings {
            exposure: 40.0,
            contrast: 400.0,
            texture: -700.0,
            glow: 900.0,
            glow_range: -220.0,
            vignette_midpoint: -30.0,
            grain_size: 1000.0,
            ..RawSettings::default()
        };
        let fixed = wild.normalized();
        assert_eq!(fixed.exposure, 5.0);
        assert_eq!(fixed.contrast, 100.0);
        assert_eq!(fixed.texture, -100.0);
        assert_eq!(fixed.glow, 100.0);
        assert_eq!(fixed.glow_range, -100.0);
        assert_eq!(fixed.vignette_midpoint, 0.0);
        assert_eq!(fixed.grain_size, 100.0);
        assert!(fixed.is_valid());
        assert!(!wild.is_valid());
    }

    #[test]
    fn normalized_repairs_non_finite_values_with_the_slider_defaults() {
        let broken = RawSettings {
            exposure: f64::NAN,
            contrast: f64::INFINITY,
            vignette_midpoint: f64::NEG_INFINITY,
            ..RawSettings::default()
        };
        let fixed = broken.normalized();
        assert_eq!(fixed.exposure, 0.0);
        assert_eq!(fixed.contrast, 0.0);
        assert_eq!(fixed.vignette_midpoint, 50.0, "the fallback is the slider default");
        assert!(fixed.is_valid());
        assert!(!broken.is_valid());
    }

    #[test]
    fn normalized_repairs_the_curve_dividers_and_handles() {
        let broken = RawCurveSettings {
            shadow_split: 95.0,
            dark_split: 10.0,
            light_split: -20.0,
            rgb: vec![RawCurvePoint::new(0.5, 2.0), RawCurvePoint::new(0.2, -1.0)],
            ..RawCurveSettings::default()
        };
        let fixed = broken.normalized();
        assert_eq!(fixed.shadow_split, 90.0);
        assert!(fixed.dark_split >= fixed.shadow_split + 2.0);
        assert!(fixed.light_split >= fixed.dark_split + 2.0);
        assert_eq!(fixed.rgb[0].x, 0.0);
        assert_eq!(fixed.rgb[fixed.rgb.len() - 1].x, 1.0);
        assert!(fixed.rgb.iter().all(|point| (0.0..=1.0).contains(&point.y)));
    }

    #[test]
    fn normalized_keeps_the_optics_hue_handles_ordered() {
        let broken = RawOpticsSettings { purple_hue_low: 340.0, purple_hue_high: 20.0, ..RawOpticsSettings::default() };
        let fixed = broken.normalized();
        assert!(fixed.purple_hue_low <= fixed.purple_hue_high);
        assert_eq!(fixed.purple_hue_low, 20.0);
        assert_eq!(fixed.purple_hue_high, 340.0);
    }

    #[test]
    fn the_mixer_normalizes_eight_families_and_at_most_eight_points() {
        let mut mixer = RawMixerSettings { hue: [500.0; 8], ..RawMixerSettings::default() };
        mixer.points = (0..10)
            .map(|index| RawPointColor { hue: index as f64 * 100.0, luminance_range: 9.0, ..RawPointColor::default() })
            .collect();
        let fixed = mixer.normalized();
        assert!(fixed.hue.iter().all(|value| *value == 100.0));
        assert_eq!(fixed.points.len(), 8);
        assert!(fixed.points.iter().all(|point| point.hue <= 360.0 && point.luminance_range == 1.0));
    }

    #[test]
    fn group_visibility_zeroes_only_the_hidden_groups() {
        let settings = populated();
        let hidden = RawGroupVisibility { color: false, detail: false, ..RawGroupVisibility::default() };
        let shown = settings.applying(&hidden);
        assert_eq!(shown.temperature, 0.0);
        assert_eq!(shown.tint, 0.0);
        assert_eq!(shown.vibrance, 0.0);
        assert_eq!(shown.saturation, 0.0);
        assert_eq!(shown.detail, RawDetailSettings::default());
        assert_eq!(shown.exposure, settings.exposure, "the light panel stays as it was");
        assert_eq!(shown.curve, settings.curve);
        assert_eq!(shown.geometry, settings.geometry);
    }

    #[test]
    fn auto_white_balance_neutralizes_a_cast() {
        // A gray-world image with a blue cast: the average has more blue than red.
        let mut image = Bitmap8::filled(4, 4, [150, 150, 190, 255]);
        image.set(3, 3, [150, 150, 190, 0]);
        let (temperature, tint) = auto_balance(&image).expect("a cast can be solved");
        assert!(temperature > 0.0, "the cast is cool, so the fix is warm: {temperature}");
        let settings = RawSettings { temperature, tint, ..RawSettings::default() };
        let balanced = crate::develop(&image, &settings);
        let pixel = balanced.get(0, 0);
        let spread = (pixel[0] as i32 - pixel[2] as i32).abs();
        assert!(spread <= 2, "the cast is gone: {pixel:?}");
    }

    #[test]
    fn auto_white_balance_needs_a_solvable_average() {
        assert!(auto_balance(&Bitmap8::new(2, 2)).is_none(), "no coverage, no solution");
        // A pure blue image has no red or green channel to solve against.
        assert!(auto_balance(&Bitmap8::filled(2, 2, [0, 0, 255, 255])).is_none());
    }

    #[test]
    fn the_eyedropper_solve_matches_the_gains_it_inverts() {
        let encoded = [0.62, 0.5, 0.38];
        let (temperature, tint) =
            RawSettings::neutralize_straight(encoded[0], encoded[1], encoded[2]).expect("solvable");
        let settings = RawSettings { temperature, tint, ..RawSettings::default() };
        let (red_gain, green_gain, blue_gain) = settings.gains();
        // The kernel applies the gains to linear light, so the pixel has to be decoded first.
        let red = crate::math::srgb_to_linear(encoded[0]) * red_gain;
        let green = crate::math::srgb_to_linear(encoded[1]) * green_gain;
        let blue = crate::math::srgb_to_linear(encoded[2]) * blue_gain;
        assert!((red - green).abs() < 1e-9, "{red} vs {green}");
        assert!((green - blue).abs() < 1e-9, "{green} vs {blue}");

        // The same solve in linear light agrees, which is what the Auto white balance scans.
        let linear = RawSettings::neutralize_linear(
            crate::math::srgb_to_linear(encoded[0]),
            crate::math::srgb_to_linear(encoded[1]),
            crate::math::srgb_to_linear(encoded[2]),
        )
        .expect("solvable");
        assert!((linear.0 - temperature).abs() < 1e-9 && (linear.1 - tint).abs() < 1e-9);
    }

    #[test]
    fn the_eyedropper_refuses_a_black_or_degenerate_pixel() {
        assert!(RawSettings::neutralize_straight(0.0, 0.5, 0.5).is_none());
        assert!(RawSettings::neutralize_straight(0.5, 0.0, 0.5).is_none());
        assert!(RawSettings::neutralize_straight(0.5, 0.5, 0.0).is_none());
    }

    #[test]
    fn the_grain_kernel_size_follows_the_macos_mapping() {
        assert_eq!(RawSettings::default().grain_kernel_size(), 0.5 + 0.25 * 19.5);
        let largest = RawSettings { grain_size: 100.0, ..RawSettings::default() };
        assert_eq!(largest.grain_kernel_size(), 20.0);
    }

    #[test]
    fn the_group_predicates_track_the_sliders() {
        let settings = populated();
        assert!(settings.adjusts_light());
        assert!(settings.adjusts_color());
        assert!(settings.adjusts_effects());
        assert!(settings.adjusts_curve());
        assert!(settings.adjusts_mixer());
        assert!(settings.adjusts_grading());
        assert!(settings.adjusts_detail());
        assert!(settings.adjusts_optics());
        assert!(settings.adjusts_geometry());
        assert!(settings.adjusts_calibration());
        assert!(!settings.is_identity());

        // A stored-but-idle value stays out of the predicates, as it does on macOS.
        let idle = RawSettings { grain_size: 90.0, white_balance: RawWhiteBalance::Auto, ..RawSettings::default() };
        assert!(!idle.adjusts_effects());
        assert!(!idle.adjusts_color());
        assert!(idle.is_identity());
    }
}
