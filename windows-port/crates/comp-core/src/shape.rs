//! A shape layer's style, kept so the shape can be drawn again at a new size.
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum ShapeKind {
    #[default]
    Rectangle,
    Ellipse,
    Line,
}

impl ShapeKind {
    pub fn as_str(self) -> &'static str {
        match self {
            ShapeKind::Rectangle => "Rectangle",
            ShapeKind::Ellipse => "Ellipse",
            ShapeKind::Line => "Line",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShapeStyle {
    pub kind: ShapeKind,
    pub red: f64,
    pub green: f64,
    pub blue: f64,
    /// Document pixels, whatever size the shape is scaled to.
    pub corner_radius: f64,
    /// A line's thickness.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line_width: Option<f64>,
    /// A line's ends as fractions of the layer box.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start: Option<[f64; 2]>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub end: Option<[f64; 2]>,
}

impl Default for ShapeStyle {
    fn default() -> Self {
        ShapeStyle {
            kind: ShapeKind::Rectangle,
            red: 0.0,
            green: 0.0,
            blue: 0.0,
            corner_radius: 0.0,
            line_width: None,
            start: None,
            end: None,
        }
    }
}

impl ShapeStyle {
    pub fn is_valid(&self) -> bool {
        [self.red, self.green, self.blue].iter().all(|v| v.is_finite() && (0.0..=1.0).contains(v))
            && self.corner_radius.is_finite()
            && self.corner_radius >= 0.0
            && self.line_width.map(|v| v.is_finite() && v > 0.0).unwrap_or(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_shape_is_valid() {
        assert!(ShapeStyle::default().is_valid());
    }

    #[test]
    fn kinds_serialize_with_their_names() {
        for kind in [ShapeKind::Rectangle, ShapeKind::Ellipse, ShapeKind::Line] {
            let json = serde_json::to_string(&kind).unwrap();
            assert_eq!(json, format!("\"{}\"", kind.as_str()));
        }
    }
}
