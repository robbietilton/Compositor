//! Layer effects, mirroring the macOS `LayerEffects` record (format version 12+ additive fields).
//!
//! Every effect carries its own `enabled` flag; a missing flag means visible. A record that omits an
//! effect means the layer does not have it.
use serde::{Deserialize, Serialize};

/// A linear RGB color, the way every effect stores it.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct EffectColor {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
}

impl Default for EffectColor {
    fn default() -> Self {
        EffectColor { red: 0.0, green: 0.0, blue: 0.0 }
    }
}

impl EffectColor {
    pub const fn new(red: f64, green: f64, blue: f64) -> Self {
        EffectColor { red, green, blue }
    }
    pub const WHITE: EffectColor = EffectColor { red: 1.0, green: 1.0, blue: 1.0 };
    pub const BLACK: EffectColor = EffectColor { red: 0.0, green: 0.0, blue: 0.0 };
    pub fn is_valid(self) -> bool {
        [self.red, self.green, self.blue].iter().all(|v| v.is_finite() && (0.0..=1.0).contains(v))
    }
    pub fn to_rgba8(self) -> [u8; 4] {
        [
            (self.red.clamp(0.0, 1.0) * 255.0).round() as u8,
            (self.green.clamp(0.0, 1.0) * 255.0).round() as u8,
            (self.blue.clamp(0.0, 1.0) * 255.0).round() as u8,
            255,
        ]
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct StrokeEffect {
    /// Missing in older projects means visible.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    #[serde(default = "default_stroke_size")]
    pub size: f64,
    #[serde(default)]
    pub red: f64,
    #[serde(default)]
    pub green: f64,
    #[serde(default)]
    pub blue: f64,
    #[serde(default = "default_opacity")]
    pub opacity: f64,
    /// Which side of the edge the stroke sits on.
    #[serde(default)]
    pub inside: bool,
}

fn default_stroke_size() -> f64 {
    4.0
}
fn default_opacity() -> f64 {
    1.0
}
fn default_shadow_opacity() -> f64 {
    0.5
}
fn default_glow_opacity() -> f64 {
    0.75
}

impl Default for StrokeEffect {
    fn default() -> Self {
        StrokeEffect {
            enabled: None,
            size: 4.0,
            red: 0.0,
            green: 0.0,
            blue: 0.0,
            opacity: 1.0,
            inside: false,
        }
    }
}

impl StrokeEffect {
    pub fn is_enabled(&self) -> bool {
        self.enabled.unwrap_or(true)
    }
    pub fn color(&self) -> EffectColor {
        EffectColor::new(self.red, self.green, self.blue)
    }
    pub fn is_valid(&self) -> bool {
        self.size.is_finite()
            && (0.0..=500.0).contains(&self.size)
            && self.color().is_valid()
            && self.opacity.is_finite()
            && (0.0..=1.0).contains(&self.opacity)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct ShadowEffect {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    #[serde(default = "default_angle")]
    pub angle: f64,
    #[serde(default = "default_distance")]
    pub distance: f64,
    #[serde(default = "default_blur")]
    pub blur: f64,
    #[serde(default)]
    pub red: f64,
    #[serde(default)]
    pub green: f64,
    #[serde(default)]
    pub blue: f64,
    #[serde(default = "default_shadow_opacity")]
    pub opacity: f64,
}

fn default_angle() -> f64 {
    90.0
}
fn default_distance() -> f64 {
    20.0
}
fn default_blur() -> f64 {
    20.0
}

impl Default for ShadowEffect {
    fn default() -> Self {
        ShadowEffect {
            enabled: None,
            angle: 90.0,
            distance: 20.0,
            blur: 20.0,
            red: 0.0,
            green: 0.0,
            blue: 0.0,
            opacity: 0.5,
        }
    }
}

impl ShadowEffect {
    pub fn is_enabled(&self) -> bool {
        self.enabled.unwrap_or(true)
    }
    pub fn color(&self) -> EffectColor {
        EffectColor::new(self.red, self.green, self.blue)
    }
    /// The shadow offset in document pixels; 90 degrees points down.
    pub fn offset(&self) -> (f64, f64) {
        let radians = self.angle.to_radians();
        (self.distance * radians.cos(), self.distance * radians.sin())
    }
    pub fn is_valid(&self) -> bool {
        [self.angle, self.distance, self.blur].iter().all(|v| v.is_finite())
            && (0.0..=500.0).contains(&self.blur)
            && (0.0..=500.0).contains(&self.distance)
            && self.color().is_valid()
            && self.opacity.is_finite()
            && (0.0..=1.0).contains(&self.opacity)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct ColorOverlayEffect {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    #[serde(default)]
    pub red: f64,
    #[serde(default)]
    pub green: f64,
    #[serde(default)]
    pub blue: f64,
    #[serde(default = "default_opacity")]
    pub opacity: f64,
}

impl Default for ColorOverlayEffect {
    fn default() -> Self {
        ColorOverlayEffect { enabled: None, red: 0.0, green: 0.0, blue: 0.0, opacity: 1.0 }
    }
}

impl ColorOverlayEffect {
    pub fn is_enabled(&self) -> bool {
        self.enabled.unwrap_or(true)
    }
    pub fn color(&self) -> EffectColor {
        EffectColor::new(self.red, self.green, self.blue)
    }
    pub fn is_valid(&self) -> bool {
        self.color().is_valid() && self.opacity.is_finite() && (0.0..=1.0).contains(&self.opacity)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct InnerShadowEffect {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    #[serde(default = "default_angle")]
    pub angle: f64,
    #[serde(default = "default_inner_distance")]
    pub distance: f64,
    #[serde(default = "default_inner_blur")]
    pub blur: f64,
    #[serde(default)]
    pub red: f64,
    #[serde(default)]
    pub green: f64,
    #[serde(default)]
    pub blue: f64,
    #[serde(default = "default_shadow_opacity")]
    pub opacity: f64,
}

fn default_inner_distance() -> f64 {
    10.0
}
fn default_inner_blur() -> f64 {
    10.0
}

impl Default for InnerShadowEffect {
    fn default() -> Self {
        InnerShadowEffect {
            enabled: None,
            angle: 90.0,
            distance: 10.0,
            blur: 10.0,
            red: 0.0,
            green: 0.0,
            blue: 0.0,
            opacity: 0.5,
        }
    }
}

impl InnerShadowEffect {
    pub fn is_enabled(&self) -> bool {
        self.enabled.unwrap_or(true)
    }
    pub fn color(&self) -> EffectColor {
        EffectColor::new(self.red, self.green, self.blue)
    }
    pub fn offset(&self) -> (f64, f64) {
        let radians = self.angle.to_radians();
        (self.distance * radians.cos(), self.distance * radians.sin())
    }
    pub fn is_valid(&self) -> bool {
        [self.angle, self.distance, self.blur].iter().all(|v| v.is_finite())
            && (0.0..=500.0).contains(&self.blur)
            && (0.0..=500.0).contains(&self.distance)
            && self.color().is_valid()
            && self.opacity.is_finite()
            && (0.0..=1.0).contains(&self.opacity)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct OuterGlowEffect {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    #[serde(default = "default_glow_size")]
    pub size: f64,
    #[serde(default = "white_channel")]
    pub red: f64,
    #[serde(default = "white_channel")]
    pub green: f64,
    #[serde(default = "white_channel")]
    pub blue: f64,
    #[serde(default = "default_glow_opacity")]
    pub opacity: f64,
}

fn default_glow_size() -> f64 {
    20.0
}
fn default_inner_glow_size() -> f64 {
    10.0
}
fn white_channel() -> f64 {
    1.0
}

impl Default for OuterGlowEffect {
    fn default() -> Self {
        OuterGlowEffect {
            enabled: None,
            size: 20.0,
            red: 1.0,
            green: 1.0,
            blue: 1.0,
            opacity: 0.75,
        }
    }
}

impl OuterGlowEffect {
    pub fn is_enabled(&self) -> bool {
        self.enabled.unwrap_or(true)
    }
    pub fn color(&self) -> EffectColor {
        EffectColor::new(self.red, self.green, self.blue)
    }
    pub fn is_valid(&self) -> bool {
        self.size.is_finite()
            && (0.0..=500.0).contains(&self.size)
            && self.color().is_valid()
            && self.opacity.is_finite()
            && (0.0..=1.0).contains(&self.opacity)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct InnerGlowEffect {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    #[serde(default = "default_inner_glow_size")]
    pub size: f64,
    #[serde(default = "white_channel")]
    pub red: f64,
    #[serde(default = "white_channel")]
    pub green: f64,
    #[serde(default = "white_channel")]
    pub blue: f64,
    #[serde(default = "default_glow_opacity")]
    pub opacity: f64,
}

impl Default for InnerGlowEffect {
    fn default() -> Self {
        InnerGlowEffect {
            enabled: None,
            size: 10.0,
            red: 1.0,
            green: 1.0,
            blue: 1.0,
            opacity: 0.75,
        }
    }
}

impl InnerGlowEffect {
    pub fn is_enabled(&self) -> bool {
        self.enabled.unwrap_or(true)
    }
    pub fn color(&self) -> EffectColor {
        EffectColor::new(self.red, self.green, self.blue)
    }
    pub fn is_valid(&self) -> bool {
        self.size.is_finite()
            && (0.0..=500.0).contains(&self.size)
            && self.color().is_valid()
            && self.opacity.is_finite()
            && (0.0..=1.0).contains(&self.opacity)
    }
}

/// The six effects a layer may carry. Missing means the layer does not have that effect.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LayerEffects {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stroke: Option<StrokeEffect>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shadow: Option<ShadowEffect>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color_overlay: Option<ColorOverlayEffect>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inner_shadow: Option<InnerShadowEffect>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outer_glow: Option<OuterGlowEffect>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inner_glow: Option<InnerGlowEffect>,
}

impl LayerEffects {
    pub fn is_empty(&self) -> bool {
        self.stroke.is_none()
            && self.shadow.is_none()
            && self.color_overlay.is_none()
            && self.inner_shadow.is_none()
            && self.outer_glow.is_none()
            && self.inner_glow.is_none()
    }

    pub fn is_valid(&self) -> bool {
        self.stroke.map(|e| e.is_valid()).unwrap_or(true)
            && self.shadow.map(|e| e.is_valid()).unwrap_or(true)
            && self.color_overlay.map(|e| e.is_valid()).unwrap_or(true)
            && self.inner_shadow.map(|e| e.is_valid()).unwrap_or(true)
            && self.outer_glow.map(|e| e.is_valid()).unwrap_or(true)
            && self.inner_glow.map(|e| e.is_valid()).unwrap_or(true)
    }

    /// True when at least one effect exists and is visible; the renderer can skip the rest.
    pub fn has_visible_effect(&self) -> bool {
        self.stroke.map(|e| e.is_enabled()).unwrap_or(false)
            || self.shadow.map(|e| e.is_enabled()).unwrap_or(false)
            || self.color_overlay.map(|e| e.is_enabled()).unwrap_or(false)
            || self.inner_shadow.map(|e| e.is_enabled()).unwrap_or(false)
            || self.outer_glow.map(|e| e.is_enabled()).unwrap_or(false)
            || self.inner_glow.map(|e| e.is_enabled()).unwrap_or(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_valid() {
        assert!(LayerEffects::default().is_valid());
        assert!(LayerEffects::default().is_empty());
        assert!(StrokeEffect::default().is_valid());
        assert!(ShadowEffect::default().is_valid());
        assert!(OuterGlowEffect::default().is_valid());
    }

    #[test]
    fn missing_enabled_means_visible() {
        let effects = LayerEffects {
            stroke: Some(StrokeEffect { enabled: None, ..StrokeEffect::default() }),
            ..LayerEffects::default()
        };
        assert!(effects.has_visible_effect());
        let hidden = LayerEffects {
            stroke: Some(StrokeEffect { enabled: Some(false), ..StrokeEffect::default() }),
            ..LayerEffects::default()
        };
        assert!(!hidden.has_visible_effect());
    }

    #[test]
    fn json_uses_camel_case_and_omits_disabled_flag() {
        let effects = LayerEffects {
            color_overlay: Some(ColorOverlayEffect {
                enabled: None,
                red: 1.0,
                green: 0.5,
                blue: 0.0,
                opacity: 1.0,
            }),
            ..LayerEffects::default()
        };
        let json = serde_json::to_string(&effects).unwrap();
        assert!(json.contains("colorOverlay"), "{json}");
        assert!(!json.contains("stroke"), "{json}");
        assert!(!json.contains("enabled"), "{json}");
    }

    #[test]
    fn shadow_offset_points_down_at_ninety_degrees() {
        let shadow = ShadowEffect { angle: 90.0, distance: 10.0, ..ShadowEffect::default() };
        let (dx, dy) = shadow.offset();
        assert!(dx.abs() < 1e-9);
        assert!((dy - 10.0).abs() < 1e-9);
    }

    #[test]
    fn out_of_range_effects_are_rejected() {
        let effects = LayerEffects {
            outer_glow: Some(OuterGlowEffect { size: 501.0, ..OuterGlowEffect::default() }),
            ..LayerEffects::default()
        };
        assert!(!effects.is_valid());
    }
}
