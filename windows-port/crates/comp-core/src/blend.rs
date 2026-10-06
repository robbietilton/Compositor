//! The 24 Photoshop blend modes Compositor names, with their exact serialized spellings.
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum BlendMode {
    Normal,
    Darken,
    Multiply,
    #[serde(rename = "Color Burn")]
    ColorBurn,
    #[serde(rename = "Linear Burn")]
    LinearBurn,
    Lighten,
    Screen,
    #[serde(rename = "Color Dodge")]
    ColorDodge,
    #[serde(rename = "Linear Dodge (Add)")]
    LinearDodge,
    Overlay,
    #[serde(rename = "Soft Light")]
    SoftLight,
    #[serde(rename = "Hard Light")]
    HardLight,
    #[serde(rename = "Vivid Light")]
    VividLight,
    #[serde(rename = "Linear Light")]
    LinearLight,
    #[serde(rename = "Pin Light")]
    PinLight,
    #[serde(rename = "Hard Mix")]
    HardMix,
    Difference,
    Exclusion,
    Subtract,
    Divide,
    Hue,
    Saturation,
    Color,
    Luminosity,
}

impl Default for BlendMode {
    fn default() -> Self {
        BlendMode::Normal
    }
}

impl BlendMode {
    /// Every mode in menu order.
    pub const ALL: [BlendMode; 24] = [
        BlendMode::Normal,
        BlendMode::Darken,
        BlendMode::Multiply,
        BlendMode::ColorBurn,
        BlendMode::LinearBurn,
        BlendMode::Lighten,
        BlendMode::Screen,
        BlendMode::ColorDodge,
        BlendMode::LinearDodge,
        BlendMode::Overlay,
        BlendMode::SoftLight,
        BlendMode::HardLight,
        BlendMode::VividLight,
        BlendMode::LinearLight,
        BlendMode::PinLight,
        BlendMode::HardMix,
        BlendMode::Difference,
        BlendMode::Exclusion,
        BlendMode::Subtract,
        BlendMode::Divide,
        BlendMode::Hue,
        BlendMode::Saturation,
        BlendMode::Color,
        BlendMode::Luminosity,
    ];

    /// Photoshop's grouping, which the picker draws with separators.
    pub const GROUPS: [&'static [BlendMode]; 6] = [
        &[BlendMode::Normal],
        &[BlendMode::Darken, BlendMode::Multiply, BlendMode::ColorBurn, BlendMode::LinearBurn],
        &[BlendMode::Lighten, BlendMode::Screen, BlendMode::ColorDodge, BlendMode::LinearDodge],
        &[
            BlendMode::Overlay,
            BlendMode::SoftLight,
            BlendMode::HardLight,
            BlendMode::VividLight,
            BlendMode::LinearLight,
            BlendMode::PinLight,
            BlendMode::HardMix,
        ],
        &[BlendMode::Difference, BlendMode::Exclusion, BlendMode::Subtract, BlendMode::Divide],
        &[BlendMode::Hue, BlendMode::Saturation, BlendMode::Color, BlendMode::Luminosity],
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            BlendMode::Normal => "Normal",
            BlendMode::Darken => "Darken",
            BlendMode::Multiply => "Multiply",
            BlendMode::ColorBurn => "Color Burn",
            BlendMode::LinearBurn => "Linear Burn",
            BlendMode::Lighten => "Lighten",
            BlendMode::Screen => "Screen",
            BlendMode::ColorDodge => "Color Dodge",
            BlendMode::LinearDodge => "Linear Dodge (Add)",
            BlendMode::Overlay => "Overlay",
            BlendMode::SoftLight => "Soft Light",
            BlendMode::HardLight => "Hard Light",
            BlendMode::VividLight => "Vivid Light",
            BlendMode::LinearLight => "Linear Light",
            BlendMode::PinLight => "Pin Light",
            BlendMode::HardMix => "Hard Mix",
            BlendMode::Difference => "Difference",
            BlendMode::Exclusion => "Exclusion",
            BlendMode::Subtract => "Subtract",
            BlendMode::Divide => "Divide",
            BlendMode::Hue => "Hue",
            BlendMode::Saturation => "Saturation",
            BlendMode::Color => "Color",
            BlendMode::Luminosity => "Luminosity",
        }
    }

    pub fn parse(text: &str) -> Option<BlendMode> {
        BlendMode::ALL.iter().copied().find(|mode| mode.as_str() == text)
    }

    /// True for the modes that blend each channel independently.
    pub fn is_separable(self) -> bool {
        !matches!(self, BlendMode::Hue | BlendMode::Saturation | BlendMode::Color | BlendMode::Luminosity)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_mode_roundtrips_through_its_name() {
        for mode in BlendMode::ALL {
            assert_eq!(BlendMode::parse(mode.as_str()), Some(mode));
            let json = serde_json::to_string(&mode).unwrap();
            assert_eq!(json, format!("\"{}\"", mode.as_str()));
            let back: BlendMode = serde_json::from_str(&json).unwrap();
            assert_eq!(back, mode);
        }
    }

    #[test]
    fn groups_cover_every_mode_once() {
        let mut seen = Vec::new();
        for group in BlendMode::GROUPS {
            for mode in group {
                assert!(!seen.contains(mode), "duplicate {:?}", mode);
                seen.push(*mode);
            }
        }
        assert_eq!(seen.len(), BlendMode::ALL.len());
    }

    #[test]
    fn unknown_name_is_rejected() {
        assert_eq!(BlendMode::parse("Normalish"), None);
        assert!(serde_json::from_str::<BlendMode>("\"SoftLight\"").is_err());
    }
}
