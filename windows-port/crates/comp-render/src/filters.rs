//! The Filter menu: the seventeen kinds macOS lists, their settings, and the five kernels that were
//! still missing.
//!
//! Ten of the kinds already exist as adjustment layers (Curves, Exposure, Gradient Map, Grain, Black &
//! White, Color Balance, Gaussian Blur, Motion Blur, Add Noise) or as layer effects, so the dispatch here
//! is thin: it builds the matching `comp_core::Adjustment` and runs the kernel that already backs it.
//! Camera Raw lives in `comp-raw`, Content-Aware Fill in `comp-brush`, and Remove Background needs a
//! model, so those three report a typed error rather than pretending to work.
//!
//! The five new kernels are ports. Dither is `DitherPixels.c`, Lens Correction is `LensPixels.c`,
//! Vignette is `adjust_colored_vignette` and Tonal Contrast is `adjust_tonal_contrast` in
//! `AdjustPixels.c` - all four byte for byte, on the premultiplied surface those kernels expect. Bloom /
//! Glow is the exception: macOS runs Core Image's `CIBloom`, whose kernel Apple does not document, so
//! this is a stated approximation (see NOTES.md).

use rayon::prelude::*;
use serde::{Deserialize, Serialize};

use comp_core::adjustment::{Adjustment, AdjustmentKind, ColorBalanceSettings, CurvesSettings};
use comp_core::effects::EffectColor;
use comp_core::Bitmap8;

use crate::adjustment::gaussian_blur;
use crate::pixel::{round_u8, Surface};

/// The Filter menu, in the order macOS lists it, with its exact spelling.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum FilterKind {
    #[default]
    #[serde(rename = "Gaussian Blur")]
    GaussianBlur,
    #[serde(rename = "Motion Blur")]
    MotionBlur,
    #[serde(rename = "Add Noise")]
    AddNoise,
    Vignette,
    #[serde(rename = "Bloom / Glow")]
    BloomGlow,
    Dither,
    #[serde(rename = "Tonal Contrast")]
    TonalContrast,
    #[serde(rename = "Lens Correction")]
    LensCorrection,
    #[serde(rename = "Camera Raw Filter")]
    CameraRaw,
    #[serde(rename = "Remove Background")]
    RemoveBackground,
    #[serde(rename = "Content-Aware Fill")]
    ContentAwareFill,
    Curves,
    Exposure,
    #[serde(rename = "Gradient Map")]
    GradientMap,
    Grain,
    #[serde(rename = "Black & White")]
    BlackWhite,
    #[serde(rename = "Color Balance")]
    ColorBalance,
}

impl FilterKind {
    /// Every kind in menu order.
    pub const ALL: [FilterKind; 17] = [
        FilterKind::GaussianBlur,
        FilterKind::MotionBlur,
        FilterKind::AddNoise,
        FilterKind::Vignette,
        FilterKind::BloomGlow,
        FilterKind::Dither,
        FilterKind::TonalContrast,
        FilterKind::LensCorrection,
        FilterKind::CameraRaw,
        FilterKind::RemoveBackground,
        FilterKind::ContentAwareFill,
        FilterKind::Curves,
        FilterKind::Exposure,
        FilterKind::GradientMap,
        FilterKind::Grain,
        FilterKind::BlackWhite,
        FilterKind::ColorBalance,
    ];

    /// The menu's grouping, which the picker draws with separators.
    pub const GROUPS: [&'static [FilterKind]; 4] = [
        &[FilterKind::GaussianBlur, FilterKind::MotionBlur, FilterKind::AddNoise],
        &[FilterKind::Vignette, FilterKind::BloomGlow, FilterKind::Dither],
        &[FilterKind::TonalContrast, FilterKind::LensCorrection],
        &[
            FilterKind::CameraRaw,
            FilterKind::RemoveBackground,
            FilterKind::ContentAwareFill,
            FilterKind::Curves,
            FilterKind::Exposure,
            FilterKind::GradientMap,
            FilterKind::Grain,
            FilterKind::BlackWhite,
            FilterKind::ColorBalance,
        ],
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            FilterKind::GaussianBlur => "Gaussian Blur",
            FilterKind::MotionBlur => "Motion Blur",
            FilterKind::AddNoise => "Add Noise",
            FilterKind::Vignette => "Vignette",
            FilterKind::BloomGlow => "Bloom / Glow",
            FilterKind::Dither => "Dither",
            FilterKind::TonalContrast => "Tonal Contrast",
            FilterKind::LensCorrection => "Lens Correction",
            FilterKind::CameraRaw => "Camera Raw Filter",
            FilterKind::RemoveBackground => "Remove Background",
            FilterKind::ContentAwareFill => "Content-Aware Fill",
            FilterKind::Curves => "Curves",
            FilterKind::Exposure => "Exposure",
            FilterKind::GradientMap => "Gradient Map",
            FilterKind::Grain => "Grain",
            FilterKind::BlackWhite => "Black & White",
            FilterKind::ColorBalance => "Color Balance",
        }
    }

    pub fn parse(text: &str) -> Option<FilterKind> {
        FilterKind::ALL.into_iter().find(|kind| kind.as_str() == text)
    }

    /// True when this crate has the kernel. The three that live elsewhere report
    /// `FilterError::Unsupported` instead.
    pub fn is_supported(self) -> bool {
        !matches!(
            self,
            FilterKind::CameraRaw | FilterKind::RemoveBackground | FilterKind::ContentAwareFill
        )
    }

    /// True when the kernel reads neighbouring pixels, so a caller has to pad the layer first
    /// (`FilterEdit.blurMargin`).
    pub fn samples_neighbors(self) -> bool {
        matches!(
            self,
            FilterKind::GaussianBlur | FilterKind::MotionBlur | FilterKind::BloomGlow | FilterKind::TonalContrast
        )
    }

    /// True when the kind runs through an `Adjustment` kernel this crate already has.
    pub fn is_adjustment_backed(self) -> bool {
        matches!(
            self,
            FilterKind::GaussianBlur
                | FilterKind::MotionBlur
                | FilterKind::AddNoise
                | FilterKind::Curves
                | FilterKind::Exposure
                | FilterKind::GradientMap
                | FilterKind::Grain
                | FilterKind::BlackWhite
                | FilterKind::ColorBalance
        )
    }
}

/// How a dithered pixel is drawn: a solid square, or a round dot of the dark color.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum DitherPixelShape {
    #[default]
    Square,
    Dot,
}

/// Which two colors a dither draws with.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum DitherColors {
    #[default]
    #[serde(rename = "Black & White")]
    BlackWhite,
    #[serde(rename = "Two Colors")]
    TwoColors,
    Original,
}

/// Dither's looks, in the order `DitherPixels.h` numbers them.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum DitherStyle {
    #[default]
    #[serde(rename = "Atkinson (Classic Mac)")]
    Atkinson,
    #[serde(rename = "Floyd\u{2013}Steinberg")]
    FloydSteinberg,
    #[serde(rename = "Bayer 2 \u{d7} 2")]
    Bayer2,
    #[serde(rename = "Bayer 4 \u{d7} 4")]
    Bayer4,
    #[serde(rename = "Bayer 8 \u{d7} 8")]
    Bayer8,
    #[serde(rename = "Halftone Dots")]
    Dots,
    #[serde(rename = "Halftone Lines")]
    Lines,
    #[serde(rename = "Halftone Diamonds")]
    Diamonds,
    #[serde(rename = "Mac Patterns")]
    Patterns,
    Ascii,
    #[serde(rename = "Scanlines (CRT)")]
    Scanlines,
}

impl DitherStyle {
    /// The variants are declared in `DitherPixels.h` order, which is the order the C kernel switches on.
    fn diffuses(self) -> bool {
        matches!(self, DitherStyle::Atkinson | DitherStyle::FloydSteinberg)
    }

    fn has_tones(self) -> bool {
        matches!(
            self,
            DitherStyle::Atkinson
                | DitherStyle::FloydSteinberg
                | DitherStyle::Bayer2
                | DitherStyle::Bayer4
                | DitherStyle::Bayer8
        )
    }

    /// ASCII's characters and a CRT's lines are drawn at full resolution, not in chunky pixels.
    fn uses_pixel_size(self) -> bool {
        !matches!(self, DitherStyle::Ascii | DitherStyle::Scanlines)
    }
}

const DITHER_PATTERN_COUNT: usize = 17;

/// Old Mac fill patterns, 8 x 8, one byte per row with the leftmost pixel in the top bit.
const DITHER_PATTERNS: [[u8; 8]; DITHER_PATTERN_COUNT] = [
    [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
    [0x80, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00],
    [0x88, 0x00, 0x22, 0x00, 0x88, 0x00, 0x22, 0x00],
    [0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01],
    [0x88, 0x22, 0x88, 0x22, 0x88, 0x22, 0x88, 0x22],
    [0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00],
    [0x11, 0x22, 0x44, 0x88, 0x11, 0x22, 0x44, 0x88],
    [0xAA, 0x00, 0xAA, 0x00, 0xAA, 0x00, 0xAA, 0x00],
    [0x88, 0x55, 0x22, 0x55, 0x88, 0x55, 0x22, 0x55],
    [0xFF, 0x80, 0x80, 0x80, 0xFF, 0x08, 0x08, 0x08],
    [0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55],
    [0x81, 0x42, 0x24, 0x18, 0x18, 0x24, 0x42, 0x81],
    [0x77, 0xAA, 0xDD, 0xAA, 0x77, 0xAA, 0xDD, 0xAA],
    [0xEE, 0xDD, 0xBB, 0x77, 0xEE, 0xDD, 0xBB, 0x77],
    [0x77, 0xFF, 0xDD, 0xFF, 0x77, 0xFF, 0xDD, 0xFF],
    [0x7F, 0xFF, 0xFF, 0xFF, 0xF7, 0xFF, 0xFF, 0xFF],
    [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
];

/// The 8 x 8 ordered matrix the smaller Bayer screens are the corners of.
const BAYER8: [u8; 64] = [
    0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26, 12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30,
    54, 22, 3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25, 15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23,
    61, 29, 53, 21,
];

/// Dither's settings, as the panel stores them.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DitherSettings {
    pub style: DitherStyle,
    /// Each dithered pixel covers this many layer pixels on a side.
    pub pixel_size: f64,
    pub pixel_shape: DitherPixelShape,
    /// Halftone screen and character cells, in dithered pixels.
    pub cell_size: f64,
    /// ASCII's line height in layer pixels; the characters are about six tenths as wide.
    pub text_size: f64,
    /// Scanlines: how far apart the lines are, in layer pixels.
    pub line_spacing: f64,
    /// Scanlines, 0-100%: light blooming around the lines, how far the lines break into round dots, and
    /// (in pixels) how far they waver sideways.
    pub glow: f64,
    pub dots: f64,
    pub wobble: f64,
    /// Halftone screen angle in degrees.
    pub angle: f64,
    /// Tones per channel for diffusion and ordered styles; 2 is 1-bit.
    pub levels: f64,
    /// How much of the error diffusion passes on, 0-100%.
    pub diffusion: f64,
    /// -100 to 100: more ink (darker) or less, and flatter or punchier, before dithering.
    pub density: f64,
    pub contrast: f64,
    pub colors: DitherColors,
    pub dark: EffectColor,
    pub light: EffectColor,
    /// Marks stand for the light tones, drawn in the light color on the dark.
    pub light_on_dark: bool,
    /// ASCII's characters, any order: they are sorted by how much ink each one has.
    pub characters: String,
}

impl Default for DitherSettings {
    fn default() -> Self {
        DitherSettings {
            style: DitherStyle::Atkinson,
            pixel_size: 2.0,
            pixel_shape: DitherPixelShape::Square,
            cell_size: 8.0,
            text_size: 14.0,
            line_spacing: 4.0,
            glow: 35.0,
            dots: 0.0,
            wobble: 0.0,
            angle: 45.0,
            levels: 2.0,
            diffusion: 100.0,
            density: 0.0,
            contrast: 0.0,
            colors: DitherColors::BlackWhite,
            dark: EffectColor::BLACK,
            light: EffectColor::WHITE,
            light_on_dark: true,
            characters: " .:-=+*#%@".to_string(),
        }
    }
}

impl DitherSettings {
    /// Every value inside the range the panel allows, as `DitherSettings.normalized` clamps them.
    pub fn normalized(&self) -> DitherSettings {
        let clamp = |value: f64, low: f64, high: f64, fallback: f64| {
            if value.is_finite() {
                value.clamp(low, high)
            } else {
                fallback
            }
        };
        DitherSettings {
            pixel_size: clamp(self.pixel_size, 1.0, 32.0, 2.0).round(),
            cell_size: clamp(self.cell_size, 4.0, 64.0, 8.0).round(),
            text_size: clamp(self.text_size, 6.0, 64.0, 14.0).round(),
            line_spacing: clamp(self.line_spacing, 2.0, 32.0, 4.0).round(),
            glow: clamp(self.glow, 0.0, 100.0, 35.0),
            dots: clamp(self.dots, 0.0, 100.0, 0.0),
            wobble: clamp(self.wobble, 0.0, 64.0, 0.0),
            angle: clamp(self.angle, -90.0, 90.0, 45.0),
            levels: clamp(self.levels, 2.0, 8.0, 2.0).round(),
            diffusion: clamp(self.diffusion, 0.0, 100.0, 100.0),
            density: clamp(self.density, -100.0, 100.0, 0.0),
            contrast: clamp(self.contrast, -100.0, 100.0, 0.0),
            dark: clamped_color(self.dark),
            light: clamped_color(self.light),
            characters: self.characters.chars().filter(|c| *c != '\n' && *c != '\r').take(64).collect(),
            ..self.clone()
        }
    }
}

fn clamped_color(color: EffectColor) -> EffectColor {
    let clamp = |value: f64| if value.is_finite() { value.clamp(0.0, 1.0) } else { 0.0 };
    EffectColor { red: clamp(color.red), green: clamp(color.green), blue: clamp(color.blue) }
}

/// Every filter's settings on one record, as macOS stores them. Each filter reads only its own.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct FilterSettings {
    /// Gaussian Blur radius in layer pixels (the blur's standard deviation), 0.1-250.
    pub radius: f64,
    /// Motion Blur direction in degrees, counterclockwise from horizontal, -90 to 90.
    pub angle: f64,
    /// Motion Blur streak length in layer pixels, 1-2000.
    pub distance: f64,
    /// Add Noise strength as Photoshop's percentage, 0.1-400.
    pub amount: f64,
    /// Add Noise distribution: Gaussian instead of Uniform.
    pub gaussian: bool,
    /// Add Noise changes brightness only, the same amount on every channel.
    pub monochromatic: bool,
    /// Add Noise's pattern: the same seed gives the same grain, so a preview does not reshuffle it.
    pub noise_seed: u64,
    /// Vignette: edge color, strength, and the shape of its falloff.
    pub vignette_amount: f64,
    pub vignette_color: EffectColor,
    pub vignette_midpoint: f64,
    pub vignette_roundness: f64,
    pub vignette_feather: f64,
    pub vignette_highlights: f64,
    /// Bloom / Glow: strength and blur radius in layer pixels.
    pub bloom_amount: f64,
    pub bloom_radius: f64,
    /// Tonal Contrast: one local-detail radius and separate tonal strengths.
    pub tonal_amount: f64,
    pub tonal_radius: f64,
    pub tonal_shadows: f64,
    pub tonal_midtones: f64,
    pub tonal_highlights: f64,
    /// Lens Correction's Remove Distortion, -100 to 100.
    pub distortion: f64,
    /// Remove Background: how far the mask is pulled onto the image's own edges.
    pub refine_edges: f64,
    pub matte_contrast: f64,
    pub shift_edge: f64,
    /// The kinds that are also adjustment layers keep their settings here, in the shape the adjustment
    /// stores them, so one record serves both paths.
    pub curves: CurvesSettings,
    pub color_balance: ColorBalanceSettings,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exposure: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gradient_map: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub grain: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub black_white: Option<serde_json::Value>,
    pub dither: DitherSettings,
}

impl Default for FilterSettings {
    fn default() -> Self {
        FilterSettings {
            radius: 1.0,
            angle: 0.0,
            distance: 10.0,
            amount: 10.0,
            gaussian: false,
            monochromatic: false,
            noise_seed: 0,
            vignette_amount: 35.0,
            vignette_color: EffectColor::BLACK,
            vignette_midpoint: 50.0,
            vignette_roundness: 100.0,
            vignette_feather: 60.0,
            vignette_highlights: 25.0,
            bloom_amount: 40.0,
            bloom_radius: 24.0,
            tonal_amount: 50.0,
            tonal_radius: 16.0,
            tonal_shadows: 40.0,
            tonal_midtones: 60.0,
            tonal_highlights: 30.0,
            distortion: 0.0,
            refine_edges: 12.0,
            matte_contrast: 25.0,
            shift_edge: 0.0,
            curves: CurvesSettings::default(),
            color_balance: ColorBalanceSettings::default(),
            exposure: None,
            gradient_map: None,
            grain: None,
            black_white: None,
            dither: DitherSettings::default(),
        }
    }
}

impl FilterSettings {
    /// The ranges the panel offers, clamped as `FilterSettings.normalized` does. Out-of-range values
    /// never reach a kernel.
    pub fn normalized(&self) -> FilterSettings {
        let clamp = |value: f64, low: f64, high: f64, fallback: f64| {
            if value.is_finite() {
                value.clamp(low, high)
            } else {
                fallback
            }
        };
        FilterSettings {
            radius: clamp(self.radius, 0.1, 250.0, 1.0),
            angle: clamp(self.angle, -90.0, 90.0, 0.0),
            distance: clamp(self.distance, 1.0, 2000.0, 10.0),
            amount: clamp(self.amount, 0.1, 400.0, 10.0),
            vignette_amount: clamp(self.vignette_amount, 0.0, 100.0, 35.0),
            vignette_color: clamped_color(self.vignette_color),
            vignette_midpoint: clamp(self.vignette_midpoint, 0.0, 100.0, 50.0),
            vignette_roundness: clamp(self.vignette_roundness, -100.0, 100.0, 100.0),
            vignette_feather: clamp(self.vignette_feather, 0.0, 100.0, 60.0),
            vignette_highlights: clamp(self.vignette_highlights, 0.0, 100.0, 25.0),
            bloom_amount: clamp(self.bloom_amount, 0.0, 100.0, 40.0),
            bloom_radius: clamp(self.bloom_radius, 1.0, 150.0, 24.0),
            tonal_amount: clamp(self.tonal_amount, 0.0, 100.0, 50.0),
            tonal_radius: clamp(self.tonal_radius, 1.0, 100.0, 16.0),
            tonal_shadows: clamp(self.tonal_shadows, -100.0, 100.0, 40.0),
            tonal_midtones: clamp(self.tonal_midtones, -100.0, 100.0, 60.0),
            tonal_highlights: clamp(self.tonal_highlights, -100.0, 100.0, 30.0),
            distortion: clamp(self.distortion, -100.0, 100.0, 0.0),
            refine_edges: clamp(self.refine_edges, 0.0, 40.0, 12.0),
            matte_contrast: clamp(self.matte_contrast, 0.0, 100.0, 25.0),
            shift_edge: clamp(self.shift_edge, -10.0, 10.0, 0.0),
            dither: self.dither.normalized(),
            ..self.clone()
        }
    }

    /// The adjustment record a kind that is also an adjustment layer runs through.
    fn adjustment(&self, kind: AdjustmentKind) -> Adjustment {
        let settings = self.normalized();
        let mut adjustment = Adjustment::new(kind);
        match kind {
            AdjustmentKind::GaussianBlur => adjustment.blur_radius = Some(settings.radius),
            AdjustmentKind::MotionBlur => {
                adjustment.motion_angle = Some(settings.angle);
                adjustment.motion_distance = Some(settings.distance);
            }
            AdjustmentKind::AddNoise => {
                adjustment.noise_amount = Some(settings.amount);
                adjustment.noise_gaussian = Some(settings.gaussian);
                adjustment.noise_monochromatic = Some(settings.monochromatic);
                adjustment.noise_seed = Some(self.noise_seed);
            }
            AdjustmentKind::Curves => adjustment.curves = settings.curves.clone(),
            AdjustmentKind::ColorBalance => adjustment.color_balance_settings = Some(settings.color_balance),
            AdjustmentKind::Exposure => adjustment.exposure_settings = settings.exposure.clone(),
            AdjustmentKind::GradientMap => adjustment.gradient_map_settings = settings.gradient_map.clone(),
            AdjustmentKind::Grain => adjustment.grain_settings = settings.grain.clone(),
            AdjustmentKind::BlackWhite => adjustment.black_white_settings = settings.black_white.clone(),
            _ => {}
        }
        adjustment
    }
}

/// What a filter can fail with. Out-of-scope kinds report `Unsupported` rather than a wrong result.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FilterError {
    /// The kernel lives in another crate, or needs a model this build does not ship.
    Unsupported(&'static str),
    /// The image is too large for the filter's working buffers.
    TooLarge,
}

impl std::fmt::Display for FilterError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FilterError::Unsupported(what) => write!(formatter, "this filter is not available here: {what}"),
            FilterError::TooLarge => write!(formatter, "the image is too large for this filter"),
        }
    }
}

impl std::error::Error for FilterError {}

/// How far a filter reaches past the layer's own pixels, in layer pixels, so a caller can pad it first
/// (`FilterEdit.blurMargin`).
pub fn blur_margin(kind: FilterKind, settings: &FilterSettings) -> f64 {
    let settings = settings.normalized();
    match kind {
        FilterKind::GaussianBlur => settings.radius * 3.0 + 2.0,
        FilterKind::MotionBlur => settings.distance / 2.0 + 2.0,
        FilterKind::BloomGlow => settings.bloom_radius * 3.0 + 2.0,
        // Tonal Contrast blurs by its radius to find the local tone, so it reaches the same way.
        FilterKind::TonalContrast => settings.tonal_radius * 3.0 + 2.0,
        _ => 0.0,
    }
}

/// Applies a filter to a straight-alpha image, the way the panel applies it to a layer's pixels.
pub fn apply_filter(
    image: &Bitmap8,
    kind: FilterKind,
    settings: &FilterSettings,
) -> Result<Bitmap8, FilterError> {
    let mut canvas = Surface::from_bitmap(image);
    apply_filter_surface(&mut canvas, kind, settings)?;
    Ok(canvas.to_bitmap())
}

/// The same on the premultiplied surface the kernels work in, in place.
pub fn apply_filter_surface(
    canvas: &mut Surface,
    kind: FilterKind,
    settings: &FilterSettings,
) -> Result<(), FilterError> {
    if canvas.is_empty() {
        return Ok(());
    }
    let settings = settings.normalized();
    match kind {
        // The kinds that already exist as adjustment layers run through their kernel.
        FilterKind::GaussianBlur => {
            let adjustment = settings.adjustment(AdjustmentKind::GaussianBlur);
            crate::adjustment::apply(&adjustment, canvas);
        }
        FilterKind::MotionBlur => {
            let adjustment = settings.adjustment(AdjustmentKind::MotionBlur);
            crate::adjustment::apply(&adjustment, canvas);
        }
        FilterKind::AddNoise => {
            let adjustment = settings.adjustment(AdjustmentKind::AddNoise);
            crate::adjustment::apply(&adjustment, canvas);
        }
        FilterKind::Curves => {
            let adjustment = settings.adjustment(AdjustmentKind::Curves);
            crate::adjustment::apply(&adjustment, canvas);
        }
        FilterKind::ColorBalance => {
            let adjustment = settings.adjustment(AdjustmentKind::ColorBalance);
            crate::adjustment::apply(&adjustment, canvas);
        }
        FilterKind::Exposure => {
            let adjustment = settings.adjustment(AdjustmentKind::Exposure);
            crate::adjustment::apply(&adjustment, canvas);
        }
        FilterKind::GradientMap => {
            let adjustment = settings.adjustment(AdjustmentKind::GradientMap);
            crate::adjustment::apply(&adjustment, canvas);
        }
        FilterKind::Grain => {
            let adjustment = settings.adjustment(AdjustmentKind::Grain);
            crate::adjustment::apply(&adjustment, canvas);
        }
        FilterKind::BlackWhite => {
            let adjustment = settings.adjustment(AdjustmentKind::BlackWhite);
            crate::adjustment::apply(&adjustment, canvas);
        }
        FilterKind::Vignette => vignette(canvas, &settings, None),
        FilterKind::BloomGlow => bloom(canvas, &settings),
        FilterKind::Dither => dither(canvas, &settings.dither)?,
        FilterKind::TonalContrast => tonal_contrast(canvas, &settings),
        FilterKind::LensCorrection => lens_correction(canvas, settings.distortion / 100.0 * LENS_STRENGTH),
        FilterKind::CameraRaw => {
            return Err(FilterError::Unsupported("Camera Raw lives in the comp-raw crate"))
        }
        FilterKind::RemoveBackground => {
            return Err(FilterError::Unsupported("Remove Background needs a subject-detection model"))
        }
        FilterKind::ContentAwareFill => {
            return Err(FilterError::Unsupported("Content-Aware Fill lives in the comp-brush crate"))
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// Dither: DitherPixels.c, kernel for kernel.
// ---------------------------------------------------------------------------------------------

/// `adjust_tone`: density darkens (positive) or lightens as a gamma, so black and white stay put;
/// contrast pivots on mid gray.
#[inline]
fn dither_tone(value: f32, gamma: f32, contrast: f32) -> f32 {
    let value = value.clamp(0.0, 1.0).powf(gamma);
    ((value - 0.5) * contrast + 0.5).clamp(0.0, 1.0)
}

/// One error-diffusion tap: a neighbour's offset and its weight over the kernel's divisor.
type DitherTap = (i64, i64, f32);

/// Atkinson passes on only six eighths of the error, which is what gives the crisp, contrasty look.
const ATKINSON: [DitherTap; 6] = [
    (1, 0, 1.0),
    (2, 0, 1.0),
    (-1, 1, 1.0),
    (0, 1, 1.0),
    (1, 1, 1.0),
    (0, 2, 1.0),
];
const FLOYD: [DitherTap; 4] = [(1, 0, 7.0), (-1, 1, 3.0), (0, 1, 5.0), (1, 1, 1.0)];

#[inline]
fn dither_quantize(value: f32, levels: i32) -> f32 {
    let steps = (levels - 1) as f32;
    (value.clamp(0.0, 1.0) * steps).round() / steps
}

/// Diffuses each plane in serpentine order, so the error's drift does not streak to one side.
fn dither_diffuse(plane: &mut [f32], alpha: &[u8], width: usize, height: usize, style: DitherStyle, diffusion: f32, levels: i32) {
    let (taps, divisor): (&[DitherTap], f32) = if style == DitherStyle::Atkinson {
        (&ATKINSON, 8.0)
    } else {
        (&FLOYD, 16.0)
    };
    for y in 0..height {
        let reverse = y & 1 == 1;
        for i in 0..width {
            let x = if reverse { width - 1 - i } else { i };
            let at = y * width + x;
            if alpha[at] == 0 {
                continue;
            }
            let old = plane[at];
            let quantized = dither_quantize(old, levels);
            plane[at] = quantized;
            let error = (old - quantized) * diffusion / divisor;
            for (dx, dy, weight) in taps {
                let nx = x as i64 + if reverse { -dx } else { *dx };
                let ny = y as i64 + dy;
                if nx < 0 || nx >= width as i64 || ny >= height as i64 {
                    continue;
                }
                plane[ny as usize * width + nx as usize] += error * weight;
            }
        }
    }
}

/// The ordered threshold for a pixel, in `[0, 1)`. Smaller Bayer matrices are the top-left corners of
/// the 8 x 8 one, rescaled, which is how the recursive construction nests them.
#[inline]
fn ordered_threshold(style: DitherStyle, x: usize, y: usize) -> f32 {
    match style {
        DitherStyle::Bayer2 => {
            const MATRIX: [u8; 4] = [0, 2, 3, 1];
            (MATRIX[(y & 1) * 2 + (x & 1)] as f32 + 0.5) / 4.0
        }
        DitherStyle::Bayer4 => {
            const MATRIX: [u8; 16] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5];
            (MATRIX[(y & 3) * 4 + (x & 3)] as f32 + 0.5) / 16.0
        }
        _ => (BAYER8[(y & 7) * 8 + (x & 7)] as f32 + 0.5) / 64.0,
    }
}

#[inline]
fn ordered_dither(value: f32, threshold: f32, levels: i32) -> f32 {
    let steps = (levels - 1) as f32;
    let quantized = (value.clamp(0.0, 1.0) * steps + threshold).floor();
    let quantized = if quantized > steps { steps } else { quantized };
    quantized / steps
}

/// How much of a halftone cell a point must be covered by before it is marked, for each screen shape.
/// `u` and `v` run from -0.5 to 0.5 across the cell; the shapes grow from its middle as coverage
/// rises.
#[inline]
fn spot(style: DitherStyle, u: f32, v: f32) -> f32 {
    let (au, av) = (u.abs(), v.abs());
    match style {
        DitherStyle::Dots => std::f32::consts::PI * (u * u + v * v),
        DitherStyle::Lines => av * 2.0,
        _ => au + av,
    }
}

/// The 5 x 7 bitmap this crate draws ASCII's characters with.
///
/// macOS lays the characters out with CoreText and reads their ink coverage back; this is the same idea
/// with a font that ships with the code, so a build has no text stack to depend on. The shapes are
/// approximations of the real glyphs, which NOTES.md records.
mod ascii_font {
    /// One glyph's rows, top to bottom, five bits each with the leftmost pixel in bit 4.
    pub const GLYPHS: [(char, [u8; 7]); 10] = [
        (' ', [0, 0, 0, 0, 0, 0, 0]),
        ('.', [0, 0, 0, 0, 0, 0b00100, 0]),
        (':', [0, 0b00100, 0, 0, 0b00100, 0, 0]),
        ('-', [0, 0, 0, 0b01110, 0, 0, 0]),
        ('=', [0, 0, 0b01110, 0, 0b01110, 0, 0]),
        ('+', [0, 0, 0b00100, 0b01110, 0b00100, 0, 0]),
        ('*', [0, 0b01010, 0b00100, 0b01010, 0b00100, 0, 0]),
        ('#', [0b01010, 0b11111, 0b01010, 0b11111, 0b01010, 0, 0]),
        ('%', [0b11001, 0b11010, 0b00100, 0b01011, 0b10011, 0, 0]),
        ('@', [0b01110, 0b10001, 0b10111, 0b10101, 0b01110, 0, 0]),
    ];

    /// The glyph for a character, or the densest one when the font has none.
    pub fn glyph(character: char) -> [u8; 7] {
        GLYPHS
            .iter()
            .find(|(candidate, _)| *candidate == character)
            .map(|(_, rows)| *rows)
            .unwrap_or(GLYPHS[GLYPHS.len() - 1].1)
    }
}

/// ASCII's character maps: each character drawn into a cell `width` x `height`, with its mean
/// coverage, least ink first - the order the picker steps through.
fn ascii_glyphs(characters: &str, line_height: usize) -> (Vec<u8>, Vec<f32>, usize, usize) {
    let height = line_height.max(1);
    let width = ((line_height as f64 * 0.6).round() as usize).max(1);
    let mut seen: Vec<char> = Vec::new();
    for character in characters.chars() {
        if !seen.contains(&character) {
            seen.push(character);
        }
    }
    if seen.is_empty() {
        seen.push(' ');
    }
    let mut drawn: Vec<([u8; 7], char)> = seen.into_iter().map(|character| (ascii_font::glyph(character), character)).collect();
    let mut maps = Vec::with_capacity(drawn.len() * width * height);
    let mut coverage = Vec::with_capacity(drawn.len());
    // Least ink first, so a darker cell picks a denser character.
    let ink = |rows: &[u8; 7]| rows.iter().map(|row| row.count_ones()).sum::<u32>();
    drawn.sort_by_key(|(rows, _)| ink(rows));
    for (rows, _) in &drawn {
        let mut sum = 0u32;
        for y in 0..height {
            let source_row = rows[(y * 7 / height).min(6)];
            for x in 0..width {
                let bit = (x * 5 / width).min(4);
                let on = (source_row >> (4 - bit)) & 1 == 1;
                maps.push(if on { 255 } else { 0 });
                sum += on as u32;
            }
        }
        coverage.push(sum as f32 / (width * height) as f32);
    }
    (maps, coverage, width, height)
}

/// Writes one pixel back as premultiplied bytes, the way `write_pixel` does.
#[inline]
fn dither_write(pixel: &mut [u8], red: f32, green: f32, blue: f32) {
    let alpha = pixel[3] as f32 / 255.0;
    pixel[0] = round_u8(red.clamp(0.0, 1.0) * alpha * 255.0);
    pixel[1] = round_u8(green.clamp(0.0, 1.0) * alpha * 255.0);
    pixel[2] = round_u8(blue.clamp(0.0, 1.0) * alpha * 255.0);
}

/// `dither_apply`: the eleven looks, on premultiplied pixels, with alpha kept and fully transparent
/// pixels left alone.
pub fn dither(canvas: &mut Surface, raw_settings: &DitherSettings) -> Result<(), FilterError> {
    let settings = raw_settings.normalized();
    // ASCII turns each cell into the character whose ink comes closest to the tone it stands for.
    let style = settings.style;
    let block = if style.uses_pixel_size() { settings.pixel_size as usize } else { 1 };
    let mut working = if block > 1 {
        Some(average_down(canvas, block)?)
    } else {
        None
    };
    let target = working.as_mut().unwrap_or(canvas);
    dither_planes(target, &settings)?;
    if style == DitherStyle::Scanlines && settings.glow > 0.0 {
        crt_glow(target, &settings)?;
    }
    let Some(averaged) = working else {
        return Ok(());
    };
    // Chunky pixels: the dithered copy blown back up without smoothing, then optionally rounded into
    // dots of the dark color.
    let mut full = Surface::new(canvas.width(), canvas.height());
    for y in 0..canvas.height() {
        let source_y = (y / block as u32).min(averaged.height().saturating_sub(1));
        for x in 0..canvas.width() {
            let source_x = (x / block as u32).min(averaged.width().saturating_sub(1));
            full.set(x, y, averaged.get(source_x, source_y));
        }
    }
    if settings.pixel_shape == DitherPixelShape::Dot {
        let gap = if settings.colors == DitherColors::TwoColors {
            color_bytes(settings.dark)
        } else {
            [0, 0, 0]
        };
        dither_dots(&mut full, block, gap);
    }
    *canvas = full;
    Ok(())
}

/// The image averaged down by `block`, the grid a chunky dither works in.
fn average_down(canvas: &Surface, block: usize) -> Result<Surface, FilterError> {
    let width = (canvas.width() as usize).div_ceil(block);
    let height = (canvas.height() as usize).div_ceil(block);
    if width == 0 || height == 0 {
        return Err(FilterError::TooLarge);
    }
    let mut out = Surface::new(width as u32, height as u32);
    for y in 0..height {
        for x in 0..width {
            let mut sums = [0u32; 4];
            let mut count = 0u32;
            for dy in 0..block {
                for dx in 0..block {
                    let sx = x * block + dx;
                    let sy = y * block + dy;
                    if sx >= canvas.width() as usize || sy >= canvas.height() as usize {
                        continue;
                    }
                    let texel = canvas.get(sx as u32, sy as u32);
                    for channel in 0..4 {
                        sums[channel] += texel[channel] as u32;
                    }
                    count += 1;
                }
            }
            let mut texel = [0u8; 4];
            for channel in 0..4 {
                texel[channel] = ((sums[channel] + count / 2) / count) as u8;
            }
            out.set(x as u32, y as u32, texel);
        }
    }
    Ok(out)
}

/// The body of `dither_apply`, on a grid already averaged to the chunky pixel size.
fn dither_planes(canvas: &mut Surface, settings: &DitherSettings) -> Result<(), FilterError> {
    let width = canvas.width() as usize;
    let height = canvas.height() as usize;
    let count = width * height;
    let original_colors = settings.colors == DitherColors::Original;
    let planes = if original_colors { 3 } else { 1 };
    if count == 0 {
        return Ok(());
    }
    let gamma = 2f32.powf((settings.density / 100.0) as f32 * 1.5);
    let contrast_setting = (settings.contrast / 100.0) as f32;
    let contrast = if contrast_setting >= 0.0 {
        1.0 / (1.0 - 0.95 * contrast_setting)
    } else {
        1.0 + contrast_setting
    };
    let mut tone = vec![0.0f32; count * planes];
    let mut alpha = vec![0u8; count];
    let mut source = if original_colors { vec![0.0f32; count * 3] } else { Vec::new() };
    // The tone planes, read from the premultiplied bytes the C kernel reads.
    for y in 0..height {
        for x in 0..width {
            let at = y * width + x;
            let texel = canvas.get(x as u32, y as u32);
            alpha[at] = texel[3];
            let (mut red, mut green, mut blue) = (0.0f32, 0.0f32, 0.0f32);
            if texel[3] != 0 {
                let scale = 1.0 / texel[3] as f32;
                red = texel[0] as f32 * scale;
                green = texel[1] as f32 * scale;
                blue = texel[2] as f32 * scale;
            }
            if original_colors {
                tone[at] = dither_tone(red, gamma, contrast);
                tone[count + at] = dither_tone(green, gamma, contrast);
                tone[2 * count + at] = dither_tone(blue, gamma, contrast);
                source[at * 3] = red;
                source[at * 3 + 1] = green;
                source[at * 3 + 2] = blue;
            } else {
                tone[at] = dither_tone(0.2126 * red + 0.7152 * green + 0.0722 * blue, gamma, contrast);
            }
        }
    }
    let dark = byte_color(settings.dark);
    let light = byte_color(settings.light);
    let levels = (settings.levels as i32).clamp(2, 16);
    if style_is_tone(settings.style) {
        if settings.style.diffuses() {
            let diffusion = (settings.diffusion / 100.0) as f32;
            for plane in 0..planes {
                let start = plane * count;
                dither_diffuse(&mut tone[start..start + count], &alpha, width, height, settings.style, diffusion, levels);
            }
        } else {
            for plane in 0..planes {
                let start = plane * count;
                for y in 0..height {
                    for x in 0..width {
                        let at = y * width + x;
                        if alpha[at] == 0 {
                            continue;
                        }
                        let threshold = ordered_threshold(settings.style, x, y);
                        tone[start + at] = ordered_dither(tone[start + at], threshold, levels);
                    }
                }
            }
        }
        for y in 0..height {
            for x in 0..width {
                let at = y * width + x;
                if alpha[at] == 0 {
                    continue;
                }
                let mut texel = canvas.get(x as u32, y as u32);
                if original_colors {
                    dither_write(&mut texel, tone[at], tone[count + at], tone[2 * count + at]);
                } else {
                    let value = tone[at];
                    dither_write(
                        &mut texel,
                        dark[0] + (light[0] - dark[0]) * value,
                        dark[1] + (light[1] - dark[1]) * value,
                        dark[2] + (light[2] - dark[2]) * value,
                    );
                }
                canvas.set(x as u32, y as u32, texel);
            }
        }
        return Ok(());
    }
    if settings.style == DitherStyle::Scanlines {
        return scanlines(canvas, settings, &tone, &alpha, &source, planes, count, width, height);
    }
    // Marks: halftone shapes, patterns and characters cover as much of each spot as the tone calls for.
    let mut marks = if original_colors { vec![0.0f32; count] } else { tone.clone() };
    if original_colors {
        for at in 0..count {
            marks[at] = 0.2126 * tone[at] + 0.7152 * tone[count + at] + 0.0722 * tone[2 * count + at];
        }
    }
    let cell = (settings.cell_size as i32).max(2) as f32;
    let radians = (settings.angle as f32).to_radians();
    let (cos_a, sin_a) = (radians.cos(), radians.sin());
    let (ink, paper) = if settings.light_on_dark { (light, dark) } else { (dark, light) };
    let glyph_width = (settings.text_size * 0.6).round().max(1.0) as usize;
    let glyph_height = settings.text_size.max(1.0) as usize;
    let columns = (width).div_ceil(glyph_width.max(1));
    let cell_rows = (height).div_ceil(glyph_height.max(1));
    let (glyph_maps, glyph_coverage, _, _) = if settings.style == DitherStyle::Ascii {
        ascii_glyphs(&settings.characters, glyph_height)
    } else {
        (Vec::new(), Vec::new(), 1, 1)
    };
    let mut picked = vec![0usize; columns * cell_rows];
    if settings.style == DitherStyle::Ascii && !glyph_coverage.is_empty() {
        for row in 0..cell_rows {
            for column in 0..columns {
                let mut sum = 0.0f32;
                let mut used = 0usize;
                for yy in row * glyph_height..((row + 1) * glyph_height).min(height) {
                    for xx in column * glyph_width..((column + 1) * glyph_width).min(width) {
                        let at = yy * width + xx;
                        if alpha[at] != 0 {
                            sum += marks[at];
                            used += 1;
                        }
                    }
                }
                let tone_value = if used > 0 { sum / used as f32 } else { 1.0 };
                let wanted = if settings.light_on_dark { tone_value } else { 1.0 - tone_value }
                    * glyph_coverage[glyph_coverage.len() - 1];
                let mut best = 0usize;
                let mut best_distance = 2.0f32;
                for (index, coverage) in glyph_coverage.iter().enumerate() {
                    let distance = (coverage - wanted).abs();
                    if distance < best_distance {
                        best_distance = distance;
                        best = index;
                    }
                }
                picked[row * columns + column] = best;
            }
        }
    }
    let paper_original = if settings.light_on_dark { 0.0f32 } else { 1.0f32 };
    let glyph_cell_width = glyph_width.max(1);
    let glyph_cell_height = glyph_height.max(1);
    for y in 0..height {
        for x in 0..width {
            let at = y * width + x;
            if alpha[at] == 0 {
                continue;
            }
            let amount = if settings.style == DitherStyle::Ascii && !glyph_coverage.is_empty() {
                let glyph = picked[(y / glyph_cell_height) * columns + x / glyph_cell_width];
                let index = glyph * glyph_cell_width * glyph_cell_height
                    + (y % glyph_cell_height) * glyph_cell_width
                    + (x % glyph_cell_width);
                glyph_maps.get(index).copied().unwrap_or(0) as f32 / 255.0
            } else if settings.style == DitherStyle::Patterns {
                let value = marks[at];
                let coverage = if settings.light_on_dark { value } else { 1.0 - value };
                let index = (coverage * (DITHER_PATTERN_COUNT - 1) as f32).round() as usize;
                let index = index.min(DITHER_PATTERN_COUNT - 1);
                ((DITHER_PATTERNS[index][y & 7] >> (7 - (x & 7))) & 1) as f32
            } else {
                let fx = x as f32 + 0.5;
                let fy = y as f32 + 0.5;
                let mut u = (fx * cos_a + fy * sin_a) / cell;
                let mut v = (-fx * sin_a + fy * cos_a) / cell;
                u -= u.floor() + 0.5;
                v -= v.floor() + 0.5;
                let value = marks[at];
                let covered = if settings.light_on_dark { value } else { 1.0 - value };
                if covered > spot(settings.style, u, v) {
                    1.0
                } else {
                    0.0
                }
            };
            let mut texel = canvas.get(x as u32, y as u32);
            if original_colors {
                let straight = &source[at * 3..at * 3 + 3];
                dither_write(
                    &mut texel,
                    paper_original + (straight[0] - paper_original) * amount,
                    paper_original + (straight[1] - paper_original) * amount,
                    paper_original + (straight[2] - paper_original) * amount,
                );
            } else {
                dither_write(
                    &mut texel,
                    paper[0] + (ink[0] - paper[0]) * amount,
                    paper[1] + (ink[1] - paper[1]) * amount,
                    paper[2] + (ink[2] - paper[2]) * amount,
                );
            }
            canvas.set(x as u32, y as u32, texel);
        }
    }
    Ok(())
}

/// The kinds that quantize to a number of tones rather than drawing marks.
fn style_is_tone(style: DitherStyle) -> bool {
    style.has_tones()
}

/// `DITHER_SCANLINES`: each line scans the image, its tone the average of the rows it covers.
#[allow(clippy::too_many_arguments)]
fn scanlines(
    canvas: &mut Surface,
    settings: &DitherSettings,
    tone: &[f32],
    alpha: &[u8],
    source: &[f32],
    planes: usize,
    count: usize,
    width: usize,
    height: usize,
) -> Result<(), FilterError> {
    let spacing = (settings.line_spacing as usize).max(2);
    let middle = spacing as f32 / 2.0;
    let dots = (settings.dots / 100.0) as f32;
    let lines = height.div_ceil(spacing);
    let dark = byte_color(settings.dark);
    let light = byte_color(settings.light);
    let (screen, phosphor) = (dark, light);
    for line in 0..lines {
        let top = line * spacing;
        let bottom = (top + spacing).min(height);
        // Wobble: each line is pushed sideways, a slow wave down the screen with a quicker one over it.
        let wave = (line as f32 * 0.45).sin() * 0.7 + (line as f32 * 1.7 + 1.3).sin() * 0.3;
        let shift = (settings.wobble as f32 * wave).round() as i64;
        let mut scan = vec![0.0f32; width * planes];
        for x in 0..width {
            let mut sum = [0.0f32; 3];
            let mut used = 0usize;
            let sx = x as i64 - shift;
            if sx >= 0 && sx < width as i64 {
                for y in top..bottom {
                    let at = y * width + sx as usize;
                    if alpha[at] == 0 {
                        continue;
                    }
                    for plane in 0..planes {
                        sum[plane] += tone[plane * count + at];
                    }
                    used += 1;
                }
            }
            for plane in 0..planes {
                scan[plane * width + x] = if used > 0 { sum[plane] / used as f32 } else { 0.0 };
            }
        }
        for y in top..bottom {
            let offset = ((y - top) as f32 + 0.5 - middle).abs();
            for x in 0..width {
                if alpha[y * width + x] == 0 {
                    continue;
                }
                // Dots: the line breaks into beads, one every line spacing.
                let along = ((x as f32 + 0.5) % spacing as f32) - middle;
                let centered = (x as f32 - along * dots).round() as i64;
                let at = centered.clamp(0, width as i64 - 1) as usize;
                let (mut red, mut green, mut blue, tone_value);
                if settings.colors == DitherColors::Original {
                    red = scan[at];
                    green = scan[width + at];
                    blue = scan[2 * width + at];
                    tone_value = 0.2126 * red + 0.7152 * green + 0.0722 * blue;
                } else {
                    tone_value = scan[at];
                    red = screen[0] + (phosphor[0] - screen[0]) * tone_value;
                    green = screen[1] + (phosphor[1] - screen[1]) * tone_value;
                    blue = screen[2] + (phosphor[2] - screen[2]) * tone_value;
                }
                // The beam is driven brighter than the picture, making up for the dark screen between lines.
                red *= 1.35;
                green *= 1.35;
                blue *= 1.35;
                let beam = middle * (0.2 + 0.5 * tone_value.clamp(0.0, 1.0).sqrt());
                let across = along * dots;
                let distance = (offset * offset + across * across).sqrt();
                let cover = (beam - distance + 0.5).clamp(0.0, 1.0);
                let (br, bg, bb) = if settings.colors == DitherColors::Original {
                    (0.0, 0.0, 0.0)
                } else {
                    (screen[0], screen[1], screen[2])
                };
                let mut texel = canvas.get(x as u32, y as u32);
                dither_write(&mut texel, br + (red - br) * cover, bg + (green - bg) * cover, bb + (blue - bb) * cover);
                canvas.set(x as u32, y as u32, texel);
            }
        }
        let _ = source;
    }
    Ok(())
}

/// `dither_dots`: each `block` x `block` square becomes a round dot in its own color on `gap`.
fn dither_dots(canvas: &mut Surface, block: usize, gap: [u8; 3]) {
    if block < 2 {
        return;
    }
    let radius = block as f32 * 0.42;
    let middle = block as f32 / 2.0;
    for y in 0..canvas.height() {
        let dy = (y as usize % block) as f32 + 0.5 - middle;
        for x in 0..canvas.width() {
            let mut texel = canvas.get(x, y);
            if texel[3] == 0 {
                continue;
            }
            let dx = (x as usize % block) as f32 + 0.5 - middle;
            let cover = (radius - (dx * dx + dy * dy).sqrt() + 0.5).clamp(0.0, 1.0);
            if cover >= 1.0 {
                continue;
            }
            for channel in 0..3 {
                let value = texel[channel] as f32 * cover
                    + gap[channel] as f32 * texel[3] as f32 / 255.0 * (1.0 - cover);
                texel[channel] = round_u8(value);
            }
            canvas.set(x, y, texel);
        }
    }
}

/// `dither_glow`: adds a blurred copy over the pixels, never past their own alpha.
fn dither_glow(canvas: &mut Surface, glow: &Surface, amount: f32) {
    for y in 0..canvas.height() {
        for x in 0..canvas.width() {
            let mut texel = canvas.get(x, y);
            let light = glow.get(x, y);
            let alpha = texel[3] as f32;
            for channel in 0..3 {
                let value = texel[channel] as f32 + light[channel] as f32 * amount * alpha / 255.0;
                texel[channel] = round_u8(value.min(alpha));
            }
            canvas.set(x, y, texel);
        }
    }
}

/// The lines' light, blurred across a few line spacings and added back over them, as a CRT's phosphors
/// bloom.
fn crt_glow(canvas: &mut Surface, settings: &DitherSettings) -> Result<(), FilterError> {
    let sigma = settings.line_spacing * 3.0 + 3.0;
    let mut bloom = canvas.clone();
    gaussian_blur(sigma as f32 / 2.0, &mut bloom);
    dither_glow(canvas, &bloom, (settings.glow / 100.0 * 2.5) as f32);
    Ok(())
}

/// The same ramp the dither paints through, for the GPU path to carry in its program.
pub(crate) fn byte_color_for_gpu(color: EffectColor) -> [f32; 3] {
    byte_color(color)
}

fn byte_color(color: EffectColor) -> [f32; 3] {
    let bytes = color_bytes(color);
    [bytes[0] as f32 / 255.0, bytes[1] as f32 / 255.0, bytes[2] as f32 / 255.0]
}

fn color_bytes(color: EffectColor) -> [u8; 3] {
    [
        round_u8((color.red.clamp(0.0, 1.0) * 255.0) as f32),
        round_u8((color.green.clamp(0.0, 1.0) * 255.0) as f32),
        round_u8((color.blue.clamp(0.0, 1.0) * 255.0) as f32),
    ]
}

// ---------------------------------------------------------------------------------------------
// Lens Correction: LensPixels.c, kernel for kernel.
// ---------------------------------------------------------------------------------------------

/// Remove Distortion at +-100 moves the image's corners by this share of their distance from the center.
pub const LENS_STRENGTH: f64 = 0.35;

/// `lens_distort`: each destination pixel samples the source along the radial scale
/// `1 - k * r^2 / halfDiagonal^2`, bilinearly, with everything outside the image contributing nothing -
/// which is what darkens the corners when the warp pulls them in.
pub fn lens_correction(canvas: &mut Surface, k: f64) {
    let width = canvas.width() as usize;
    let height = canvas.height() as usize;
    if width == 0 || height == 0 || k == 0.0 {
        return;
    }
    let source = canvas.clone();
    let (cx, cy) = (width as f64 * 0.5, height as f64 * 0.5);
    let half_diagonal = cx * cx + cy * cy;
    let pixels = source.pixels();
    canvas.pixels_mut().par_chunks_mut(width * 4).enumerate().for_each(|(y, row)| {
        let dy = y as f64 + 0.5 - cy;
        for x in 0..width {
            let dx = x as f64 + 0.5 - cx;
            let scale = 1.0 - k * (dx * dx + dy * dy) / half_diagonal;
            // Source position in pixel-center coordinates.
            let sx = cx + dx * scale - 0.5;
            let sy = cy + dy * scale - 0.5;
            let (fx0, fy0) = (sx.floor(), sy.floor());
            let (fx, fy) = (sx - fx0, sy - fy0);
            let (x0, y0) = (fx0 as i64, fy0 as i64);
            let mut sums = [0.0f64; 4];
            for j in 0..2i64 {
                let sample_y = y0 + j;
                if sample_y < 0 || sample_y >= height as i64 {
                    continue;
                }
                let wy = if j == 1 { fy } else { 1.0 - fy };
                if wy == 0.0 {
                    continue;
                }
                for i in 0..2i64 {
                    let sample_x = x0 + i;
                    if sample_x < 0 || sample_x >= width as i64 {
                        continue;
                    }
                    let weight = wy * if i == 1 { fx } else { 1.0 - fx };
                    if weight == 0.0 {
                        continue;
                    }
                    let at = (sample_y as usize * width + sample_x as usize) * 4;
                    for channel in 0..4 {
                        sums[channel] += weight * pixels[at + channel] as f64;
                    }
                }
            }
            for channel in 0..4 {
                row[x * 4 + channel] = sums[channel].round().clamp(0.0, 255.0) as u8;
            }
        }
    });
}

// ---------------------------------------------------------------------------------------------
// Vignette: adjust_colored_vignette in AdjustPixels.c, kernel for kernel.
// ---------------------------------------------------------------------------------------------

/// The rectangle a vignette frames, in the surface's own pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VignetteFrame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    /// True when the color also fills pixels that were clear - what the filter does on an empty layer,
    /// where the vignette frames the canvas rather than the layer's own pixels.
    pub fills_clear: bool,
}

/// `vignette_mask_at`: the vignette's strength at a point of the frame (0 at its middle, 1 past its
/// edges).
pub(crate) fn vignette_mask_at(px: f64, py: f64, width: f64, height: f64, midpoint: f64, roundness: f64, feather: f64) -> f64 {
    let nx = px / width * 2.0 - 1.0;
    let ny = py / height * 2.0 - 1.0;
    let square = nx.abs().max(ny.abs());
    let circle = (nx * nx + ny * ny).sqrt() / std::f64::consts::SQRT_2;
    let shape = (1.0 - roundness / 100.0) * 0.5;
    let distance = circle + (square - circle) * shape;
    let start = (midpoint / 100.0) * 0.85;
    let mut soft = feather / 100.0;
    if soft < 0.05 {
        soft = 0.05;
    }
    let t = ((distance - start) / soft).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// `adjust_colored_vignette`: the edges take the chosen color at the settings' strength, with bright
/// pixels protected by Highlights when the vignette darkens them.
pub fn vignette(canvas: &mut Surface, settings: &FilterSettings, frame: Option<VignetteFrame>) {
    let settings = settings.normalized();
    if settings.vignette_amount <= 0.0 || canvas.is_empty() {
        return;
    }
    let frame = frame.unwrap_or(VignetteFrame {
        x: 0.0,
        y: 0.0,
        width: canvas.width() as f64,
        height: canvas.height() as f64,
        fills_clear: false,
    });
    if frame.width <= 0.0 || frame.height <= 0.0 {
        return;
    }
    let strength = (settings.vignette_amount / 100.0).clamp(0.0, 1.0);
    let color = [
        settings.vignette_color.red.clamp(0.0, 1.0),
        settings.vignette_color.green.clamp(0.0, 1.0),
        settings.vignette_color.blue.clamp(0.0, 1.0),
    ];
    let width = canvas.width() as usize;
    let pixels = canvas.pixels_mut();
    pixels.par_chunks_mut(width * 4).enumerate().for_each(|(y, row)| {
        for x in 0..width {
            let texel = &mut row[x * 4..x * 4 + 4];
            if texel[3] == 0 && !frame.fills_clear {
                continue;
            }
            let mask = vignette_mask_at(
                x as f64 + 0.5 - frame.x,
                y as f64 + 0.5 - frame.y,
                frame.width,
                frame.height,
                settings.vignette_midpoint,
                settings.vignette_roundness,
                settings.vignette_feather,
            );
            if mask <= 0.0 {
                continue;
            }
            let alpha = texel[3] as f64 / 255.0;
            let mut straight = [0.0f64; 3];
            let mut bright = 0.0;
            if texel[3] != 0 {
                for channel in 0..3 {
                    straight[channel] = (texel[channel] as f64 / texel[3] as f64).min(1.0);
                }
                let luminance = rec709(straight);
                bright = ((luminance - 0.45) / 0.55).clamp(0.0, 1.0);
            }
            let effect = strength * mask * (1.0 - settings.vignette_highlights / 100.0 * bright);
            if !frame.fills_clear {
                // Only the pixels that are there change color; their coverage stays as it was.
                for channel in 0..3 {
                    let value = straight[channel] + (color[channel] - straight[channel]) * effect;
                    texel[channel] = write_premultiplied(value, texel[3] as f64);
                }
                continue;
            }
            // The color painted over the pixel at `effect`: an opaque pixel moves toward it, a clear one
            // takes it on.
            let out = alpha + effect * (1.0 - alpha);
            if out <= 0.0 {
                continue;
            }
            let alpha_out = (out * 255.0).min(255.0).round() as u8;
            for channel in 0..3 {
                let value = (color[channel] * effect + straight[channel] * alpha * (1.0 - effect)) / out;
                texel[channel] = write_premultiplied(value, alpha_out as f64);
            }
            texel[3] = alpha_out;
        }
    });
}

/// `write_premultiplied`: `min(alpha, max(0, round(value * alpha)))`.
#[inline]
fn write_premultiplied(value: f64, alpha: f64) -> u8 {
    (value * alpha).clamp(0.0, alpha).round() as u8
}

#[inline]
fn rec709(color: [f64; 3]) -> f64 {
    0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2]
}

// ---------------------------------------------------------------------------------------------
// Bloom / Glow: an approximation of CIBloom, which Apple does not document.
// ---------------------------------------------------------------------------------------------

/// Where the bloom starts to see a highlight: below this luminance a pixel contributes nothing.
pub(crate) const BLOOM_KNEE: f32 = 0.6;

/// A highlights-only bloom: the bright parts of the image are blurred and added back, which is what
/// `CIBloom(radius:intensity:)` does to the eye. The kernel itself is not documented, so this is a
/// stated approximation rather than a port (NOTES.md).
pub fn bloom(canvas: &mut Surface, settings: &FilterSettings) {
    let settings = settings.normalized();
    let intensity = (settings.bloom_amount / 50.0) as f32;
    if intensity <= 0.0 || settings.bloom_radius <= 0.0 || canvas.is_empty() {
        return;
    }
    let mut highlights = canvas.clone();
    for texel in highlights.pixels_mut().chunks_exact_mut(4) {
        if texel[3] == 0 {
            continue;
        }
        let alpha = texel[3] as f32;
        let straight = [texel[0] as f32 / alpha, texel[1] as f32 / alpha, texel[2] as f32 / alpha];
        let luminance = 0.2126 * straight[0] + 0.7152 * straight[1] + 0.0722 * straight[2];
        let weight = ((luminance - BLOOM_KNEE) / (1.0 - BLOOM_KNEE)).clamp(0.0, 1.0);
        for entry in texel[..3].iter_mut() {
            *entry = round_u8(*entry as f32 * weight);
        }
    }
    gaussian_blur((settings.bloom_radius / 2.0) as f32, &mut highlights);
    for (texel, glow) in canvas.pixels_mut().chunks_exact_mut(4).zip(highlights.pixels().chunks_exact(4)) {
        let alpha = texel[3] as f32;
        for (entry, light) in texel[..3].iter_mut().zip(glow.iter()) {
            *entry = round_u8((*entry as f32 + *light as f32 * intensity).min(alpha));
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Tonal Contrast: adjust_tonal_contrast in AdjustPixels.c, kernel for kernel.
// ---------------------------------------------------------------------------------------------

/// `tonal_smooth`: an S-curve between two tones.
fn tonal_smooth(low: f64, high: f64, value: f64) -> f64 {
    let t = ((value - low) / (high - low)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// `adjust_tonal_contrast`: local detail, taken from a blurred copy, is added back with a weight that
/// depends on how dark the local tone is.
pub fn tonal_contrast(canvas: &mut Surface, settings: &FilterSettings) {
    let settings = settings.normalized();
    let strength = settings.tonal_amount / 50.0;
    if settings.tonal_amount <= 0.0
        || (settings.tonal_shadows == 0.0 && settings.tonal_midtones == 0.0 && settings.tonal_highlights == 0.0)
    {
        return;
    }
    let mut base = canvas.clone();
    gaussian_blur(settings.tonal_radius as f32, &mut base);
    let width = canvas.width() as usize;
    let base_pixels = base.pixels();
    canvas.pixels_mut().par_chunks_mut(width * 4).enumerate().for_each(|(y, row)| {
        for x in 0..width {
            let texel = &mut row[x * 4..x * 4 + 4];
            let at = (y * width + x) * 4;
            let base_alpha = base_pixels[at + 3];
            if texel[3] == 0 || base_alpha == 0 {
                continue;
            }
            let mut straight = [0.0f64; 3];
            let mut base_straight = [0.0f64; 3];
            for channel in 0..3 {
                straight[channel] = (texel[channel] as f64 / texel[3] as f64).min(1.0);
                base_straight[channel] = (base_pixels[at + channel] as f64 / base_alpha as f64).min(1.0);
            }
            let luminance = rec709(straight);
            let base_luminance = rec709(base_straight);
            let shadow_weight = 1.0 - tonal_smooth(0.15, 0.5, base_luminance);
            let highlight_weight = tonal_smooth(0.5, 0.85, base_luminance);
            let midtone_weight = 1.0 - shadow_weight - highlight_weight;
            let weight = (settings.tonal_shadows * shadow_weight
                + settings.tonal_midtones * midtone_weight
                + settings.tonal_highlights * highlight_weight)
                / 100.0;
            let detail = luminance - base_luminance;
            let delta = 0.18 * (detail * 6.0).tanh() * weight * strength * (4.0 * luminance * (1.0 - luminance));
            for channel in 0..3 {
                texel[channel] = write_premultiplied(straight[channel] + delta, texel[3] as f64);
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn solid(width: u32, height: u32, rgba: [u8; 4]) -> Bitmap8 {
        Bitmap8::filled(width, height, rgba)
    }

    /// A horizontal ramp from black to white, with an opaque alpha.
    fn ramp(width: u32, height: u32) -> Bitmap8 {
        let mut bitmap = Bitmap8::new(width, height);
        for y in 0..height {
            for x in 0..width {
                let value = round_u8(x as f32 * 255.0 / (width.max(2) - 1) as f32);
                bitmap.set(x, y, [value, value, value, 255]);
            }
        }
        bitmap
    }

    fn run(bitmap: &Bitmap8, kind: FilterKind, settings: &FilterSettings) -> Bitmap8 {
        apply_filter(bitmap, kind, settings).expect("filter runs")
    }

    /// Rec. 709 luminance of a straight-alpha pixel, 0-255.
    fn luma(texel: [u8; 4]) -> f32 {
        if texel[3] == 0 {
            return 0.0;
        }
        0.2126 * texel[0] as f32 + 0.7152 * texel[1] as f32 + 0.0722 * texel[2] as f32
    }

    fn mean_luma(bitmap: &Bitmap8) -> f32 {
        let sum: f32 = bitmap.pixels().chunks_exact(4).map(|texel| luma([texel[0], texel[1], texel[2], texel[3]])).sum();
        sum / bitmap.pixel_count() as f32
    }

    /// The centroid of the bright pixels, for measuring where a warp moved the image.
    fn bright_centroid(bitmap: &Bitmap8) -> f64 {
        let mut sum = 0.0;
        let mut weight = 0.0;
        for y in 0..bitmap.height() {
            for x in 0..bitmap.width() {
                if luma(bitmap.get(x, y)) > 128.0 {
                    sum += x as f64;
                    weight += 1.0;
                }
            }
        }
        if weight == 0.0 {
            0.0
        } else {
            sum / weight
        }
    }

    #[test]
    fn every_kind_roundtrips_through_its_name() {
        assert_eq!(FilterKind::ALL.len(), 17);
        for kind in FilterKind::ALL {
            assert_eq!(FilterKind::parse(kind.as_str()), Some(kind));
            let json = serde_json::to_string(&kind).unwrap();
            assert_eq!(json, format!("\"{}\"", kind.as_str()));
            let back: FilterKind = serde_json::from_str(&json).unwrap();
            assert_eq!(back, kind);
        }
        assert_eq!(serde_json::to_string(&FilterKind::BloomGlow).unwrap(), "\"Bloom / Glow\"");
        assert_eq!(FilterKind::parse("bloom"), None);
    }

    #[test]
    fn groups_cover_every_kind_once() {
        let mut seen = Vec::new();
        for group in FilterKind::GROUPS {
            for kind in group {
                assert!(!seen.contains(kind), "duplicate {kind:?}");
                seen.push(*kind);
            }
        }
        assert_eq!(seen.len(), FilterKind::ALL.len());
    }

    #[test]
    fn settings_clamp_to_the_ranges_the_panel_offers() {
        let wild = FilterSettings {
            radius: 1000.0,
            angle: -400.0,
            distance: 0.0,
            amount: f64::NAN,
            vignette_amount: 500.0,
            vignette_midpoint: -20.0,
            bloom_radius: 900.0,
            tonal_radius: 0.0,
            distortion: -500.0,
            dither: DitherSettings { levels: 99.0, angle: 200.0, pixel_size: 0.0, ..DitherSettings::default() },
            ..FilterSettings::default()
        };
        let normalized = wild.normalized();
        assert_eq!(normalized.radius, 250.0);
        assert_eq!(normalized.angle, -90.0);
        assert_eq!(normalized.distance, 1.0);
        assert_eq!(normalized.amount, 10.0, "a NaN takes the default");
        assert_eq!(normalized.vignette_amount, 100.0);
        assert_eq!(normalized.vignette_midpoint, 0.0);
        assert_eq!(normalized.bloom_radius, 150.0);
        assert_eq!(normalized.tonal_radius, 1.0);
        assert_eq!(normalized.distortion, -100.0);
        assert_eq!(normalized.dither.levels, 8.0);
        assert_eq!(normalized.dither.angle, 90.0);
        assert_eq!(normalized.dither.pixel_size, 1.0);
    }

    #[test]
    fn settings_use_camel_case_json() {
        let settings = FilterSettings { vignette_midpoint: 42.0, bloom_radius: 7.0, ..FilterSettings::default() };
        let json = serde_json::to_string(&settings).unwrap();
        assert!(json.contains("\"vignetteMidpoint\":42.0"), "{json}");
        assert!(json.contains("\"bloomRadius\":7.0"), "{json}");
        assert!(json.contains("\"pixelSize\":2.0"), "{json}");
        assert!(json.contains("\"lightOnDark\":true"), "{json}");
        let back: FilterSettings = serde_json::from_str(&json).unwrap();
        assert_eq!(back.vignette_midpoint, 42.0);
        assert_eq!(back.dither.style, DitherStyle::Atkinson);
        let empty: FilterSettings = serde_json::from_str("{}").unwrap();
        assert_eq!(empty.radius, 1.0);
        assert_eq!(empty.dither.cell_size, 8.0);
    }

    #[test]
    fn blur_margin_matches_the_panel() {
        let settings =
            FilterSettings { radius: 4.0, distance: 12.0, bloom_radius: 6.0, tonal_radius: 3.0, ..FilterSettings::default() };
        assert_eq!(blur_margin(FilterKind::GaussianBlur, &settings), 14.0);
        assert_eq!(blur_margin(FilterKind::MotionBlur, &settings), 8.0);
        assert_eq!(blur_margin(FilterKind::BloomGlow, &settings), 20.0);
        assert_eq!(blur_margin(FilterKind::TonalContrast, &settings), 11.0);
        for kind in [FilterKind::Vignette, FilterKind::Dither, FilterKind::LensCorrection, FilterKind::AddNoise] {
            assert_eq!(blur_margin(kind, &settings), 0.0, "{kind:?}");
        }
    }

    #[test]
    fn unsupported_kinds_report_a_typed_error() {
        let image = solid(4, 4, [10, 20, 30, 255]);
        for kind in [FilterKind::CameraRaw, FilterKind::RemoveBackground, FilterKind::ContentAwareFill] {
            assert!(!kind.is_supported());
            match apply_filter(&image, kind, &FilterSettings::default()) {
                Err(FilterError::Unsupported(_)) => {}
                other => panic!("{kind:?} should be unsupported: {other:?}"),
            }
        }
        assert!(FilterKind::Dither.is_supported());
    }

    #[test]
    fn every_kind_survives_tiny_and_odd_images() {
        let settings = FilterSettings::default();
        for kind in FilterKind::ALL {
            for image in [solid(1, 1, [0, 0, 0, 0]), solid(1, 1, [255, 255, 255, 255]), solid(3, 5, [120, 40, 200, 128]), ramp(2, 2)] {
                match apply_filter(&image, kind, &settings) {
                    Ok(result) => assert_eq!((result.width(), result.height()), (image.width(), image.height())),
                    Err(FilterError::Unsupported(_)) => {}
                    Err(other) => panic!("{kind:?} failed on a tiny image: {other}"),
                }
            }
        }
    }

    // ---- Lens Correction ------------------------------------------------------------------

    #[test]
    fn lens_correction_with_no_distortion_is_the_identity() {
        let image = ramp(16, 9);
        assert_eq!(run(&image, FilterKind::LensCorrection, &FilterSettings::default()), image);
    }

    #[test]
    fn lens_correction_keeps_the_center_pixel() {
        let image = ramp(17, 11);
        let center = image.get(8, 5);
        for distortion in [-100.0, -35.0, 35.0, 100.0] {
            let out = run(&image, FilterKind::LensCorrection, &FilterSettings { distortion, ..FilterSettings::default() });
            assert_eq!(out.get(8, 5), center, "distortion {distortion}");
        }
    }

    #[test]
    fn lens_correction_moves_a_bright_edge_the_way_its_sign_says() {
        let mut image = solid(24, 12, [0, 0, 0, 255]);
        for y in 0..12 {
            for x in 2..7 {
                image.set(x, y, [255, 255, 255, 255]);
            }
        }
        // The scale is `1 - k * r^2`, so a positive setting magnifies: a block left of the center moves
        // further left. A negative one shrinks the image toward the middle.
        let middle = bright_centroid(&image);
        let outward = bright_centroid(&run(&image, FilterKind::LensCorrection, &FilterSettings { distortion: 60.0, ..FilterSettings::default() }));
        let inward = bright_centroid(&run(&image, FilterKind::LensCorrection, &FilterSettings { distortion: -60.0, ..FilterSettings::default() }));
        assert!(outward < middle, "positive distortion magnifies: {outward} vs {middle}");
        assert!(inward > middle, "negative distortion shrinks: {inward} vs {middle}");
        let small = bright_centroid(&run(&image, FilterKind::LensCorrection, &FilterSettings { distortion: 20.0, ..FilterSettings::default() }));
        assert!(small <= middle && small >= outward, "20 moves less than 60: {small} {middle} {outward}");
    }

    #[test]
    fn lens_correction_keeps_the_middle_row_opaque_and_darkens_the_corners() {
        let image = solid(32, 32, [128, 128, 128, 255]);
        // Magnifying samples inward, so everything stays covered.
        let big = run(&image, FilterKind::LensCorrection, &FilterSettings { distortion: 80.0, ..FilterSettings::default() });
        assert_eq!(big.get(16, 16)[3], 255, "the middle stays opaque");
        assert_eq!(big.get(0, 0)[3], 255, "and so does a corner it enlarged");
        // Shrinking samples past the edges, which the kernel treats as nothing at all.
        let small = run(&image, FilterKind::LensCorrection, &FilterSettings { distortion: -80.0, ..FilterSettings::default() });
        assert_eq!(small.get(16, 16)[3], 255, "the middle is still covered");
        assert!(small.get(0, 0)[3] < 255, "the corner fades where the source ran out: {:?}", small.get(0, 0));
        assert!(small.get(16, 0)[3] < 255, "and so does the middle of an edge: {:?}", small.get(16, 0));
    }

    // ---- Vignette -------------------------------------------------------------------------

    #[test]
    fn vignette_with_no_amount_is_the_identity() {
        let image = ramp(16, 16);
        let settings = FilterSettings { vignette_amount: 0.0, ..FilterSettings::default() };
        assert_eq!(run(&image, FilterKind::Vignette, &settings), image);
    }

    #[test]
    fn vignette_keeps_the_center_and_darkens_the_corner() {
        let image = solid(32, 32, [200, 200, 200, 255]);
        let settings = FilterSettings {
            vignette_amount: 80.0,
            vignette_color: EffectColor::BLACK,
            vignette_midpoint: 40.0,
            ..FilterSettings::default()
        };
        let out = run(&image, FilterKind::Vignette, &settings);
        assert_eq!(out.get(16, 16), [200, 200, 200, 255], "the middle is untouched");
        let corner = out.get(0, 0);
        assert!(corner[0] < 80, "the corner takes the edge color: {corner:?}");
        assert!(corner[0] < out.get(28, 16)[0], "and a corner is darker than a side: {:?} vs {:?}", corner, out.get(28, 16));
        let mut previous = 255;
        for x in 16..32 {
            let value = out.get(x, 16)[0];
            assert!(value <= previous, "the vignette only darkens outwards: {value} after {previous}");
            previous = value;
        }
    }

    #[test]
    fn vignette_highlights_protect_bright_pixels() {
        let dark = solid(32, 32, [60, 60, 60, 255]);
        let bright = solid(32, 32, [250, 250, 250, 255]);
        let base = FilterSettings { vignette_amount: 80.0, vignette_midpoint: 30.0, ..FilterSettings::default() };
        let protecting = FilterSettings { vignette_highlights: 100.0, ..base.clone() };
        let corner = |image: &Bitmap8, mode: &FilterSettings| run(image, FilterKind::Vignette, mode).get(0, 0)[0] as f64;
        assert!(250.0 - corner(&bright, &protecting) < 250.0 - corner(&bright, &base), "bright pixels are spared");
        assert!(60.0 - corner(&dark, &protecting) > 250.0 - corner(&bright, &protecting), "and dark ones are not");
    }

    #[test]
    fn vignette_midpoint_controls_how_much_is_darkened() {
        let image = solid(40, 40, [200, 200, 200, 255]);
        let changed = |midpoint: f64| {
            let settings = FilterSettings { vignette_amount: 60.0, vignette_midpoint: midpoint, ..FilterSettings::default() };
            let out = run(&image, FilterKind::Vignette, &settings);
            let mut count = 0;
            for y in 0..40 {
                for x in 0..40 {
                    if out.get(x, y)[0] < 200 {
                        count += 1;
                    }
                }
            }
            count
        };
        // The midpoint is where the vignette starts: further out means fewer pixels are touched.
        assert!(changed(20.0) > changed(80.0), "a smaller midpoint reaches further in");
    }

    #[test]
    fn vignette_keeps_alpha_and_can_fill_clear_pixels() {
        let image = solid(16, 16, [200, 100, 50, 128]);
        let settings = FilterSettings { vignette_amount: 100.0, vignette_midpoint: 0.0, ..FilterSettings::default() };
        let out = run(&image, FilterKind::Vignette, &settings);
        for texel in out.pixels().chunks_exact(4) {
            assert_eq!(texel[3], 128, "recoloring never changes coverage");
        }
        let mut canvas = Surface::new(16, 16);
        canvas.set(15, 15, [200, 100, 50, 128]);
        vignette(&mut canvas, &settings, Some(VignetteFrame { x: 0.0, y: 0.0, width: 16.0, height: 16.0, fills_clear: true }));
        assert!(canvas.get(0, 0)[3] > 0, "a clear corner takes the edge color: {:?}", canvas.get(0, 0));
        assert!(canvas.get(8, 8)[3] < 16, "the middle of the frame stays nearly clear: {:?}", canvas.get(8, 8));
        // A pixel that was there gains coverage where the color is painted over it, as the kernel says.
        assert!(canvas.get(15, 15)[3] >= 128, "and it moves toward the edge color: {:?}", canvas.get(15, 15));
    }

    // ---- Bloom / Glow ---------------------------------------------------------------------

    #[test]
    fn bloom_with_no_amount_is_the_identity() {
        let image = ramp(8, 8);
        let settings = FilterSettings { bloom_amount: 0.0, ..FilterSettings::default() };
        assert_eq!(run(&image, FilterKind::BloomGlow, &settings), image);
    }

    #[test]
    fn bloom_only_takes_highlights() {
        let black = solid(9, 9, [0, 0, 0, 255]);
        assert_eq!(run(&black, FilterKind::BloomGlow, &FilterSettings::default()), black, "black has no highlights");
        let middle = solid(9, 9, [110, 110, 110, 255]);
        assert_eq!(run(&middle, FilterKind::BloomGlow, &FilterSettings::default()), middle, "a mid gray is below the knee");
    }

    #[test]
    fn bloom_spreads_a_highlight_and_stays_in_range() {
        let mut image = solid(21, 21, [0, 0, 0, 255]);
        image.set(10, 10, [255, 255, 255, 255]);
        let settings = FilterSettings { bloom_amount: 80.0, bloom_radius: 6.0, ..FilterSettings::default() };
        let out = run(&image, FilterKind::BloomGlow, &settings);
        assert!(out.get(7, 10)[0] > 0, "the glow reaches a neighbour: {:?}", out.get(7, 10));
        assert!(out.get(7, 10)[0] < out.get(10, 10)[0], "and fades with distance");
        assert_eq!(out.get(10, 10), [255, 255, 255, 255], "the highlight itself stays white");
        assert_eq!(out.get(0, 0)[0], 0, "far away nothing changes");
        for texel in out.pixels().chunks_exact(4) {
            assert!(texel[0] <= texel[3] && texel[1] <= texel[3] && texel[2] <= texel[3], "never past the alpha");
            assert_eq!(texel[3], 255);
        }
    }

    #[test]
    fn bloom_leaves_clear_pixels_clear() {
        let mut surface = Surface::new(9, 9);
        surface.set(4, 4, [255, 255, 255, 255]);
        let settings = FilterSettings { bloom_amount: 100.0, bloom_radius: 4.0, ..FilterSettings::default() };
        bloom(&mut surface, &settings);
        for (index, texel) in surface.pixels().chunks_exact(4).enumerate() {
            if index != 4 * 9 + 4 {
                assert_eq!(texel[3], 0, "an empty pixel gains no coverage");
            }
        }
    }

    // ---- Dither ---------------------------------------------------------------------------

    fn dither_settings(style: DitherStyle) -> FilterSettings {
        FilterSettings { dither: DitherSettings { style, ..DitherSettings::default() }, ..FilterSettings::default() }
    }

    #[test]
    fn dither_is_deterministic() {
        let image = ramp(24, 16);
        for style in [DitherStyle::Atkinson, DitherStyle::FloydSteinberg, DitherStyle::Bayer4, DitherStyle::Dots] {
            let settings = dither_settings(style);
            let first = run(&image, FilterKind::Dither, &settings);
            assert_eq!(first, run(&image, FilterKind::Dither, &settings), "{style:?} depends only on its input");
        }
    }

    #[test]
    fn dither_in_black_and_white_uses_only_the_two_colors() {
        let image = ramp(24, 16);
        let mut settings = dither_settings(DitherStyle::Atkinson);
        settings.dither.levels = 2.0;
        let out = run(&image, FilterKind::Dither, &settings);
        for texel in out.pixels().chunks_exact(4) {
            assert_eq!(texel[3], 255);
            let black = texel[0] == 0 && texel[1] == 0 && texel[2] == 0;
            let white = texel[0] == 255 && texel[1] == 255 && texel[2] == 255;
            assert!(black || white, "a one-bit dither is black or white: {texel:?}");
        }
    }

    #[test]
    fn dither_levels_quantize_to_the_tones_they_name() {
        let image = ramp(32, 8);
        for levels in [2.0, 4.0, 6.0] {
            let mut settings = dither_settings(DitherStyle::Bayer8);
            settings.dither.levels = levels;
            let out = run(&image, FilterKind::Dither, &settings);
            let mut values: Vec<u8> = out.pixels().chunks_exact(4).map(|texel| texel[0]).collect();
            values.sort_unstable();
            values.dedup();
            assert!(values.len() <= levels as usize, "{levels} tones, saw {}: {values:?}", values.len());
        }
    }

    #[test]
    fn the_ordered_screens_differ_from_each_other() {
        let image = ramp(16, 16);
        let two = run(&image, FilterKind::Dither, &dither_settings(DitherStyle::Bayer2));
        let four = run(&image, FilterKind::Dither, &dither_settings(DitherStyle::Bayer4));
        let eight = run(&image, FilterKind::Dither, &dither_settings(DitherStyle::Bayer8));
        assert_ne!(two, four);
        assert_ne!(four, eight);
        assert_ne!(two, eight);
    }

    #[test]
    fn dither_follows_the_tone_of_its_input() {
        let image = solid(32, 32, [128, 128, 128, 255]);
        for style in [DitherStyle::Atkinson, DitherStyle::FloydSteinberg] {
            let out = run(&image, FilterKind::Dither, &dither_settings(style));
            let black = out.pixels().chunks_exact(4).filter(|texel| texel[0] == 0).count();
            let white = out.pixels().chunks_exact(4).filter(|texel| texel[0] == 255).count();
            assert_eq!(black + white, out.pixel_count(), "{style:?} is one bit");
            assert!(black > 0 && white > 0, "{style:?} mixes both tones");
            let fraction = white as f64 / out.pixel_count() as f64;
            assert!((fraction - 0.5).abs() < 0.08, "{style:?} keeps mid gray near half: {fraction}");
        }
        let dark = solid(32, 32, [64, 64, 64, 255]);
        let dark_white = run(&dark, FilterKind::Dither, &dither_settings(DitherStyle::FloydSteinberg))
            .pixels()
            .chunks_exact(4)
            .filter(|texel| texel[0] == 255)
            .count();
        let mid_white = run(&image, FilterKind::Dither, &dither_settings(DitherStyle::FloydSteinberg))
            .pixels()
            .chunks_exact(4)
            .filter(|texel| texel[0] == 255)
            .count();
        assert!(dark_white < mid_white, "a darker patch is darker after dithering too");
    }

    #[test]
    fn dither_keeps_alpha_and_leaves_clear_pixels_alone() {
        let mut image = ramp(8, 8);
        image.set(0, 0, [200, 100, 50, 0]);
        image.set(1, 1, [200, 100, 50, 90]);
        let mut settings = dither_settings(DitherStyle::Atkinson);
        settings.dither.pixel_size = 1.0;
        let out = run(&image, FilterKind::Dither, &settings);
        // Premultiplied pixels carry no color where they are clear, and the kernel leaves them alone.
        assert_eq!(out.get(0, 0)[3], 0, "a clear pixel stays clear");
        assert_eq!(out.get(1, 1)[3], 90, "a partly covered pixel keeps its coverage");
        for (before, after) in image.pixels().chunks_exact(4).zip(out.pixels().chunks_exact(4)) {
            assert_eq!(before[3], after[3], "dither never invents coverage");
        }
    }

    #[test]
    fn halftone_marks_cover_more_of_a_dark_area() {
        let mut image = Bitmap8::new(32, 16);
        for y in 0..16 {
            for x in 0..32 {
                let value = if x < 16 { 40 } else { 220 };
                image.set(x, y, [value, value, value, 255]);
            }
        }
        let mut settings = dither_settings(DitherStyle::Dots);
        settings.dither.light_on_dark = false;
        settings.dither.cell_size = 4.0;
        let out = run(&image, FilterKind::Dither, &settings);
        let ink = |from: u32, to: u32| {
            let mut count = 0;
            for y in 0..16 {
                for x in from..to {
                    if out.get(x, y)[0] < 128 {
                        count += 1;
                    }
                }
            }
            count
        };
        assert!(ink(0, 16) > ink(16, 32), "the dark half carries more marks");
    }

    #[test]
    fn mac_patterns_use_only_the_two_colors() {
        let image = ramp(24, 16);
        let out = run(&image, FilterKind::Dither, &dither_settings(DitherStyle::Patterns));
        for texel in out.pixels().chunks_exact(4) {
            let black = texel[0] == 0 && texel[1] == 0 && texel[2] == 0;
            let white = texel[0] == 255 && texel[1] == 255 && texel[2] == 255;
            assert!(black || white, "patterns are one bit: {texel:?}");
        }
    }

    #[test]
    fn ascii_picks_denser_characters_for_brighter_cells() {
        let mut image = Bitmap8::new(48, 28);
        for y in 0..28 {
            for x in 0..48 {
                let value = if x < 24 { 20 } else { 235 };
                image.set(x, y, [value, value, value, 255]);
            }
        }
        let mut settings = dither_settings(DitherStyle::Ascii);
        settings.dither.light_on_dark = true;
        let out = run(&image, FilterKind::Dither, &settings);
        let sum = |from: u32, to: u32| {
            let mut total = 0.0;
            for y in 0..28 {
                for x in from..to {
                    total += luma(out.get(x, y));
                }
            }
            total
        };
        assert!(sum(24, 48) > sum(0, 24), "the bright half takes the denser characters");
    }

    #[test]
    fn scanlines_run_and_keep_their_coverage() {
        let image = ramp(32, 24);
        let mut settings = dither_settings(DitherStyle::Scanlines);
        settings.dither.line_spacing = 4.0;
        settings.dither.glow = 0.0;
        let out = run(&image, FilterKind::Dither, &settings);
        for texel in out.pixels().chunks_exact(4) {
            assert_eq!(texel[3], 255);
        }
        // With four-pixel spacing the beam sits on rows 1 and 2, and rows 0 and 3 are the screen.
        let lit: u32 = (0..32).map(|x| out.get(x, 1)[0] as u32).sum();
        let screen: u32 = (0..32).map(|x| out.get(x, 0)[0] as u32).sum();
        assert!(lit > screen, "a lit line is brighter than the screen beside it: {lit} vs {screen}");
    }

    #[test]
    fn chunky_pixels_dither_in_blocks() {
        let image = ramp(16, 16);
        let mut settings = dither_settings(DitherStyle::Bayer8);
        settings.dither.pixel_size = 4.0;
        settings.dither.pixel_shape = DitherPixelShape::Square;
        let out = run(&image, FilterKind::Dither, &settings);
        for block_y in 0..4 {
            for block_x in 0..4 {
                let first = out.get(block_x * 4, block_y * 4);
                for y in 0..4 {
                    for x in 0..4 {
                        assert_eq!(out.get(block_x * 4 + x, block_y * 4 + y), first, "a chunky pixel is one block");
                    }
                }
            }
        }
    }

    #[test]
    fn dither_two_colors_and_original_modes_are_available() {
        let image = ramp(16, 16);
        let mut two = dither_settings(DitherStyle::FloydSteinberg);
        two.dither.colors = DitherColors::TwoColors;
        two.dither.dark = EffectColor::new(0.0, 0.0, 1.0);
        two.dither.light = EffectColor::new(1.0, 1.0, 0.0);
        let out = run(&image, FilterKind::Dither, &two);
        for texel in out.pixels().chunks_exact(4) {
            let blue = texel[2] == 255 && texel[0] == 0;
            let yellow = texel[0] == 255 && texel[2] == 0;
            assert!(blue || yellow, "the two chosen colors: {texel:?}");
        }
        // Original dithers each channel of the image's own color instead of two chosen ones, so a
        // saturated pixel survives the one-bit quantization.
        let mut original = ramp(8, 8);
        original.set(4, 4, [255, 0, 0, 255]);
        let mut settings = dither_settings(DitherStyle::Bayer8);
        settings.dither.pixel_size = 1.0;
        settings.dither.colors = DitherColors::Original;
        let out = run(&original, FilterKind::Dither, &settings);
        assert_eq!(out.get(4, 4), [255, 0, 0, 255], "Original keeps the image's own colors");
    }

    // ---- Tonal Contrast -------------------------------------------------------------------

    #[test]
    fn tonal_contrast_with_no_amount_is_the_identity() {
        let image = ramp(16, 16);
        assert_eq!(run(&image, FilterKind::TonalContrast, &FilterSettings { tonal_amount: 0.0, ..FilterSettings::default() }), image);
        let flat = FilterSettings { tonal_shadows: 0.0, tonal_midtones: 0.0, tonal_highlights: 0.0, ..FilterSettings::default() };
        assert_eq!(run(&image, FilterKind::TonalContrast, &flat), image);
    }

    #[test]
    fn tonal_contrast_leaves_a_flat_image_alone_in_the_middle() {
        let image = solid(24, 24, [90, 90, 90, 255]);
        let settings = FilterSettings { tonal_radius: 1.0, ..FilterSettings::default() };
        let out = run(&image, FilterKind::TonalContrast, &settings);
        assert_eq!(out, image, "a flat image has no local detail to lift, wherever it is measured");
        // With a wide blur the outside of the layer pulls the local tone down, so a border does change.
        let wide = run(&image, FilterKind::TonalContrast, &FilterSettings::default());
        assert_ne!(wide.get(0, 0), image.get(0, 0));
        assert_eq!(wide.get(12, 12), image.get(12, 12), "the middle of a flat image stays flat");
    }

    #[test]
    fn tonal_contrast_favours_the_tones_it_is_given() {
        let mut image = Bitmap8::new(32, 32);
        for y in 0..32 {
            for x in 0..32 {
                let base = if x < 16 { 60 } else { 210 };
                let value = if y % 8 < 4 { base } else { base + 20 };
                image.set(x, y, [value, value, value, 255]);
            }
        }
        // The two halves' cores, clear of the boundary band the blur mixes across.
        let change = |settings: &FilterSettings| {
            let out = run(&image, FilterKind::TonalContrast, settings);
            let (mut dark, mut bright) = (0i32, 0i32);
            for y in 0..32 {
                for x in 0..32 {
                    let difference = (out.get(x, y)[0] as i32 - image.get(x, y)[0] as i32).abs();
                    if x < 12 {
                        dark += difference;
                    } else if x >= 20 {
                        bright += difference;
                    }
                }
            }
            (dark, bright)
        };
        let shadows = FilterSettings { tonal_shadows: 100.0, tonal_midtones: 0.0, tonal_highlights: 0.0, ..FilterSettings::default() };
        let highlights = FilterSettings { tonal_shadows: 0.0, tonal_midtones: 0.0, tonal_highlights: 100.0, ..FilterSettings::default() };
        let (dark_shadows, bright_shadows) = change(&shadows);
        let (dark_highlights, bright_highlights) = change(&highlights);
        assert!(dark_shadows > bright_shadows, "Shadows works on the dark half: {dark_shadows} vs {bright_shadows}");
        assert!(bright_highlights > dark_highlights, "Highlights works on the bright half");
        assert!(dark_shadows > dark_highlights, "and each half answers its own slider");
    }

    #[test]
    fn tonal_contrast_keeps_alpha() {
        let image = solid(16, 16, [90, 120, 60, 200]);
        for settings in [
            FilterSettings::default(),
            FilterSettings { tonal_shadows: 100.0, ..FilterSettings::default() },
            FilterSettings { tonal_highlights: -100.0, ..FilterSettings::default() },
        ] {
            let out = run(&image, FilterKind::TonalContrast, &settings);
            for texel in out.pixels().chunks_exact(4) {
                assert_eq!(texel[3], 200);
            }
        }
    }

    // ---- The kinds that reuse an adjustment kernel ----------------------------------------

    #[test]
    fn gaussian_blur_filter_matches_the_adjustment_kernel() {
        let image = ramp(24, 24);
        let settings = FilterSettings { radius: 3.0, ..FilterSettings::default() };
        let through_filter = run(&image, FilterKind::GaussianBlur, &settings);
        let mut adjustment = Adjustment::new(AdjustmentKind::GaussianBlur);
        adjustment.blur_radius = Some(3.0);
        let mut canvas = Surface::from_bitmap(&image);
        crate::adjustment::apply(&adjustment, &mut canvas);
        assert_eq!(through_filter, canvas.to_bitmap(), "one kernel, two doors");
    }

    #[test]
    fn add_noise_filter_is_seeded() {
        let image = ramp(16, 16);
        let settings = FilterSettings { amount: 60.0, noise_seed: 4242, gaussian: true, monochromatic: true, ..FilterSettings::default() };
        let first = run(&image, FilterKind::AddNoise, &settings);
        assert_eq!(first, run(&image, FilterKind::AddNoise, &settings));
        assert_ne!(first, run(&image, FilterKind::AddNoise, &FilterSettings { noise_seed: 7, ..settings.clone() }));
    }

    #[test]
    fn adjustment_backed_kinds_reach_their_kernels() {
        let image = ramp(8, 8);
        let reds = FilterSettings {
            black_white: Some(serde_json::json!({ "reds": 100.0, "yellows": 0.0, "greens": 0.0, "cyans": 0.0, "blues": 0.0, "magentas": 0.0 })),
            ..FilterSettings::default()
        };
        let colored = solid(4, 4, [200, 60, 30, 255]);
        assert_ne!(run(&colored, FilterKind::BlackWhite, &reds), colored, "Black & White through the filter menu");
        let gradient = FilterSettings {
            gradient_map: Some(serde_json::json!({
                "shadows": { "red": 1.0, "green": 0.0, "blue": 0.0 },
                "highlights": { "red": 0.0, "green": 0.0, "blue": 1.0 }
            })),
            ..FilterSettings::default()
        };
        let out = run(&image, FilterKind::GradientMap, &gradient);
        assert_eq!(out.get(0, 0), [255, 0, 0, 255], "black takes the shadows end");
        assert_eq!(out.get(7, 0), [0, 0, 255, 255], "white takes the highlights end");
        let warmed = FilterSettings {
            color_balance: ColorBalanceSettings { mid_cyan_red: 60.0, ..ColorBalanceSettings::default() },
            ..FilterSettings::default()
        };
        assert!(run(&image, FilterKind::ColorBalance, &warmed).get(4, 0)[0] >= image.get(4, 0)[0]);
        let grain = FilterSettings {
            grain: Some(serde_json::json!({ "amount": 60.0, "size": 1.5, "roughness": 50.0, "seed": 9 })),
            ..FilterSettings::default()
        };
        assert_eq!(run(&image, FilterKind::Grain, &grain), run(&image, FilterKind::Grain, &grain));
    }

    #[test]
    fn curves_and_exposure_filters_run_through_their_settings() {
        use comp_core::adjustment::CurvePoint;
        let image = ramp(8, 8);
        let identity: Vec<CurvePoint> = vec![CurvePoint { x: 0.0, y: 0.0 }, CurvePoint { x: 255.0, y: 255.0 }];
        let curves = FilterSettings {
            curves: CurvesSettings { channels: [identity.clone(), identity.clone(), identity.clone(), identity], ..CurvesSettings::default() },
            ..FilterSettings::default()
        };
        assert_eq!(run(&image, FilterKind::Curves, &curves), image, "an identity curve changes nothing");
        let exposure = FilterSettings {
            exposure: Some(serde_json::json!({ "exposure": 1.0, "offset": 0.0, "gamma": 1.0 })),
            ..FilterSettings::default()
        };
        assert!(mean_luma(&run(&image, FilterKind::Exposure, &exposure)) > mean_luma(&image), "a stop of light brightens");
    }

    #[test]
    fn filters_report_the_neighborhood_they_need() {
        assert!(FilterKind::GaussianBlur.samples_neighbors());
        assert!(FilterKind::BloomGlow.samples_neighbors());
        assert!(FilterKind::TonalContrast.samples_neighbors());
        assert!(!FilterKind::Vignette.samples_neighbors());
        assert!(!FilterKind::Dither.samples_neighbors());
        assert!(FilterKind::Curves.is_adjustment_backed());
        assert!(!FilterKind::Dither.is_adjustment_backed());
    }
}
