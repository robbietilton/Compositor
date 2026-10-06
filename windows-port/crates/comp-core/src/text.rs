//! Editable text metadata, mirroring the macOS `LayerTextStyle` record.
use crate::limits;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum TextAlignment {
    #[default]
    Left,
    Center,
    Right,
}

/// Paragraph bounds in layer pixels; the text wraps inside them.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct SizeD {
    pub width: f64,
    pub height: f64,
}

impl SizeD {
    pub const fn new(width: f64, height: f64) -> Self {
        SizeD { width, height }
    }
}

/// Letters painted in another color than the text's own, offsets in UTF-16 units.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct TextColorRun {
    pub location: usize,
    pub length: usize,
    #[serde(default)]
    pub red: f64,
    #[serde(default)]
    pub green: f64,
    #[serde(default)]
    pub blue: f64,
}

/// Letters set in another face than the text's own, offsets in UTF-16 units.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TextFontRun {
    pub location: usize,
    pub length: usize,
    /// The PostScript face name; the macOS record spells this key `fontName`.
    #[serde(rename = "fontName")]
    pub font_name: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextStyle {
    #[serde(default = "default_content")]
    pub content: String,
    #[serde(default = "default_font_name")]
    pub font_name: String,
    #[serde(default = "default_font_size")]
    pub font_size: f64,
    #[serde(default)]
    pub red: f64,
    #[serde(default)]
    pub green: f64,
    #[serde(default)]
    pub blue: f64,
    #[serde(default)]
    pub alignment: TextAlignment,
    #[serde(default)]
    pub tracking: f64,
    /// Baseline to baseline in layer pixels; 0 means auto (120% of the font size).
    #[serde(default)]
    pub leading: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub box_size: Option<SizeD>,
    /// Version 10 and up.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color_runs: Option<Vec<TextColorRun>>,
    /// Version 11 and up.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub font_runs: Option<Vec<TextFontRun>>,
}

fn default_content() -> String {
    "Text".to_string()
}
fn default_font_name() -> String {
    "Helvetica".to_string()
}
fn default_font_size() -> f64 {
    72.0
}

impl Default for TextStyle {
    fn default() -> Self {
        TextStyle {
            content: default_content(),
            font_name: default_font_name(),
            font_size: 72.0,
            red: 0.0,
            green: 0.0,
            blue: 0.0,
            alignment: TextAlignment::Left,
            tracking: 0.0,
            leading: 0.0,
            box_size: None,
            color_runs: None,
            font_runs: None,
        }
    }
}

impl TextStyle {
    /// UTF-16 length of the content, the unit every run offset uses.
    pub fn utf16_len(&self) -> usize {
        self.content.encode_utf16().count()
    }

    /// The baseline distance actually used.
    pub fn line_height(&self) -> f64 {
        if self.leading > 0.0 {
            self.leading
        } else {
            self.font_size * 1.2
        }
    }

    pub fn box_is_valid(&self) -> bool {
        match self.box_size {
            None => true,
            Some(size) => {
                size.width.is_finite()
                    && size.height.is_finite()
                    && (limits::MIN_TEXT_BOX_SIDE..=limits::MAX_SIDE as f64).contains(&size.width)
                    && (limits::MIN_TEXT_BOX_SIDE..=limits::MAX_SIDE as f64).contains(&size.height)
                    && size.width * size.height <= limits::MAX_SURFACE_PIXELS as f64
            }
        }
    }

    fn color_runs_are_valid(&self) -> bool {
        let Some(runs) = &self.color_runs else { return true };
        let mut end = 0usize;
        for run in runs {
            if run.location < end || run.length == 0 {
                return false;
            }
            if [run.red, run.green, run.blue].iter().any(|v| !v.is_finite() || !(0.0..=1.0).contains(v))
            {
                return false;
            }
            end = run.location + run.length;
        }
        !runs.is_empty() && end <= self.utf16_len()
    }

    fn font_runs_are_valid(&self) -> bool {
        let Some(runs) = &self.font_runs else { return true };
        let mut end = 0usize;
        for run in runs {
            if run.location < end || run.length == 0 {
                return false;
            }
            if run.font_name.is_empty()
                || run.font_name.chars().count() > 200
                || run.font_name.contains(['\n', '\r'])
            {
                return false;
            }
            end = run.location + run.length;
        }
        !runs.is_empty() && end <= self.utf16_len()
    }

    pub fn is_valid(&self) -> bool {
        self.utf16_len() <= limits::MAX_TEXT_UTF16
            && self.box_is_valid()
            && self.font_size.is_finite()
            && (1.0..=2000.0).contains(&self.font_size)
            && [self.red, self.green, self.blue].iter().all(|v| v.is_finite() && (0.0..=1.0).contains(v))
            && self.tracking.is_finite()
            && (-100.0..=1000.0).contains(&self.tracking)
            && self.leading.is_finite()
            && (0.0..=5000.0).contains(&self.leading)
            && self.color_runs_are_valid()
            && self.font_runs_are_valid()
    }

    /// The color of the UTF-16 unit at `index`, or the text's own color.
    pub fn color_at(&self, index: usize) -> (f64, f64, f64) {
        if let Some(runs) = &self.color_runs {
            for run in runs {
                if run.location <= index && index < run.location + run.length {
                    return (run.red, run.green, run.blue);
                }
            }
        }
        (self.red, self.green, self.blue)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_text_is_valid() {
        assert!(TextStyle::default().is_valid());
        assert_eq!(TextStyle::default().line_height(), 72.0 * 1.2);
    }

    #[test]
    fn runs_must_be_sorted_and_inside_the_content() {
        let mut style = TextStyle { content: "hello world".to_string(), ..TextStyle::default() };
        style.color_runs = Some(vec![TextColorRun {
            location: 0,
            length: 5,
            red: 1.0,
            green: 0.0,
            blue: 0.0,
        }]);
        assert!(style.is_valid());
        assert_eq!(style.color_at(2), (1.0, 0.0, 0.0));
        assert_eq!(style.color_at(7), (0.0, 0.0, 0.0));
        style.color_runs = Some(vec![
            TextColorRun { location: 5, length: 3, red: 1.0, green: 0.0, blue: 0.0 },
            TextColorRun { location: 1, length: 2, red: 0.0, green: 1.0, blue: 0.0 },
        ]);
        assert!(!style.is_valid(), "unsorted runs must be rejected");
        style.color_runs = Some(vec![TextColorRun {
            location: 6,
            length: 90,
            red: 1.0,
            green: 0.0,
            blue: 0.0,
        }]);
        assert!(!style.is_valid(), "runs past the end must be rejected");
    }

    #[test]
    fn box_and_size_limits() {
        let mut style = TextStyle::default();
        style.box_size = Some(SizeD::new(4.0, 100.0));
        assert!(!style.is_valid());
        style.box_size = Some(SizeD::new(400.0, 300.0));
        assert!(style.is_valid());
        style.font_size = 0.5;
        assert!(!style.is_valid());
    }

    #[test]
    fn json_omits_absent_runs() {
        let json = serde_json::to_string(&TextStyle::default()).unwrap();
        assert!(!json.contains("colorRuns"), "{json}");
        assert!(json.contains("fontName"), "{json}");
    }
}
