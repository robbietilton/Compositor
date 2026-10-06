//! Photoshop file types, the conversion report, and the internal layer records.
use uuid::Uuid;

use comp_core::adjustment::Adjustment;
use comp_core::bitmap::{Bitmap8, Gray8};
use comp_core::blend::BlendMode;
use comp_core::document::Document;
use comp_core::limits;

/// The four bytes every Photoshop file starts with.
pub const PSD_MAGIC: [u8; 4] = *b"8BPS";

/// The color mode field of the file header.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PsdColorMode {
    Bitmap,
    Grayscale,
    Indexed,
    Rgb,
    Cmyk,
    Multichannel,
    Duotone,
    Lab,
    Unknown(u16),
}

impl PsdColorMode {
    pub fn from_raw(raw: u16) -> Self {
        match raw {
            0 => PsdColorMode::Bitmap,
            1 => PsdColorMode::Grayscale,
            2 => PsdColorMode::Indexed,
            3 => PsdColorMode::Rgb,
            4 => PsdColorMode::Cmyk,
            7 => PsdColorMode::Multichannel,
            8 => PsdColorMode::Duotone,
            9 => PsdColorMode::Lab,
            other => PsdColorMode::Unknown(other),
        }
    }

    pub fn raw(self) -> u16 {
        match self {
            PsdColorMode::Bitmap => 0,
            PsdColorMode::Grayscale => 1,
            PsdColorMode::Indexed => 2,
            PsdColorMode::Rgb => 3,
            PsdColorMode::Cmyk => 4,
            PsdColorMode::Multichannel => 7,
            PsdColorMode::Duotone => 8,
            PsdColorMode::Lab => 9,
            PsdColorMode::Unknown(raw) => raw,
        }
    }

    /// The name the import error uses for the mode.
    pub fn name(self) -> &'static str {
        match self {
            PsdColorMode::Bitmap => "bitmap",
            PsdColorMode::Grayscale => "grayscale",
            PsdColorMode::Indexed => "indexed color",
            PsdColorMode::Rgb => "RGB",
            PsdColorMode::Cmyk => "CMYK",
            PsdColorMode::Multichannel => "multichannel",
            PsdColorMode::Duotone => "duotone",
            PsdColorMode::Lab => "Lab",
            PsdColorMode::Unknown(_) => "an unknown color mode",
        }
    }
}

/// The 26-byte file header.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PsdHeader {
    /// 1 for PSD, 2 for PSB (large document).
    pub version: u16,
    /// Channels in the merged image, including alpha.
    pub channels: u16,
    pub width: u32,
    pub height: u32,
    /// Bits per channel; only 8 is supported.
    pub depth: u16,
    pub color_mode: PsdColorMode,
}

impl PsdHeader {
    /// PSB files store 64-bit section lengths and channel lengths.
    pub fn is_psb(&self) -> bool {
        self.version == 2
    }
}

/// What kind of layer the file's additional layer information says this is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PsdLayerKind {
    Raster,
    Group,
    Adjustment,
    Text,
    SmartObject,
    Effects,
    Vector,
    /// A layer type this build does not recognize.
    Other,
}

impl PsdLayerKind {
    pub fn as_str(self) -> &'static str {
        match self {
            PsdLayerKind::Raster => "raster",
            PsdLayerKind::Group => "group",
            PsdLayerKind::Adjustment => "adjustment",
            PsdLayerKind::Text => "text",
            PsdLayerKind::SmartObject => "smart object",
            PsdLayerKind::Effects => "effects",
            PsdLayerKind::Vector => "vector",
            PsdLayerKind::Other => "unsupported",
        }
    }
}

/// One way the import had to deviate from the file.
///
/// macOS shows these in a conversion sheet before importing; the CLI prints them. Nothing is
/// dropped without one, unless the caller asked for strict reading, in which case they error.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PsdConversion {
    pub layer_name: String,
    pub message: String,
}

impl PsdConversion {
    pub fn new(layer_name: impl Into<String>, message: impl Into<String>) -> Self {
        PsdConversion { layer_name: layer_name.into(), message: message.into() }
    }
}

impl std::fmt::Display for PsdConversion {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.layer_name, self.message)
    }
}

/// How much of a Photoshop file to read.
#[derive(Clone, Copy, Debug)]
pub struct PsdReadOptions {
    /// Pixels this import may still add to the document.
    pub remaining_pixels: u64,
    /// Refuses any file the import would have to approximate, instead of reporting it.
    pub strict: bool,
}

impl Default for PsdReadOptions {
    fn default() -> Self {
        PsdReadOptions { remaining_pixels: limits::document_pixel_budget(), strict: false }
    }
}

/// What a Photoshop import produced, with everything it had to convert.
#[derive(Clone, Debug)]
pub struct PsdImport {
    pub document: Document,
    pub header: PsdHeader,
    pub resolution: f64,
    pub conversions: Vec<PsdConversion>,
}

impl PsdImport {
    /// The document alone; the conversion report is dropped here, so callers that care about
    /// fidelity read the report first.
    pub fn into_document(self) -> Document {
        self.document
    }

    /// One line per conversion, for a CLI or a log.
    pub fn report(&self) -> String {
        self.conversions.iter().map(|conversion| conversion.to_string()).collect::<Vec<_>>().join("\n")
    }
}

/// A layer mask patch as the file stores it: a rectangle of the document.
#[derive(Clone, Debug)]
pub(crate) struct PsdMask {
    pub pixels: Gray8,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    /// The mask's value everywhere the patch does not cover.
    pub default_value: u8,
}

/// One layer, after its channels are decoded but before it becomes a comp-core layer.
#[derive(Clone, Debug)]
pub(crate) struct PsdRecord {
    pub id: Uuid,
    pub parent: Option<Uuid>,
    pub name: String,
    pub is_group: bool,
    pub visible: bool,
    /// Opacity already multiplied by the fill opacity, and clamped to 0-1.
    pub opacity: f64,
    /// None when the file's blend key has no Compositor equivalent.
    pub blend: Option<BlendMode>,
    pub blend_key: String,
    pub clipping: bool,
    pub kind: PsdLayerKind,
    pub image: Option<Bitmap8>,
    pub mask: Option<PsdMask>,
    pub mask_enabled: bool,
    pub adjustment: Option<Adjustment>,
    /// The layer's document rectangle as (x, y, width, height).
    pub bounds: (f64, f64, f64, f64),
    /// True when the layer was cropped to the canvas to fit the memory budget.
    pub cropped: bool,
    /// True when the file stored a mask the import could not convert.
    pub mask_skipped: bool,
}

impl PsdRecord {
    pub(crate) fn new(id: Uuid, name: String) -> Self {
        PsdRecord {
            id,
            parent: None,
            name,
            is_group: false,
            visible: true,
            opacity: 1.0,
            blend: None,
            blend_key: String::new(),
            clipping: false,
            kind: PsdLayerKind::Raster,
            image: None,
            mask: None,
            mask_enabled: true,
            adjustment: None,
            bounds: (0.0, 0.0, 0.0, 0.0),
            cropped: false,
            mask_skipped: false,
        }
    }

    /// The pixel grid a layer mask is built on: the layer's image, or the canvas for a layer
    /// without pixels, exactly as PSDDocumentBuilder.maskOnLayerGrid chooses.
    pub(crate) fn mask_grid(&self, canvas: (u32, u32)) -> (u32, u32) {
        match &self.image {
            Some(image) => (image.width(), image.height()),
            None => canvas,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn color_modes_round_trip_through_their_raw_value() {
        for raw in [0u16, 1, 2, 3, 4, 7, 8, 9, 5] {
            let mode = PsdColorMode::from_raw(raw);
            assert_eq!(mode.raw(), raw);
        }
        assert_eq!(PsdColorMode::from_raw(4).name(), "CMYK");
        assert_eq!(PsdColorMode::from_raw(5), PsdColorMode::Unknown(5));
    }

    #[test]
    fn psb_is_version_two() {
        let psd = PsdHeader { version: 1, channels: 3, width: 8, height: 8, depth: 8, color_mode: PsdColorMode::Rgb };
        assert!(!psd.is_psb());
        assert!(PsdHeader { version: 2, ..psd }.is_psb());
    }

    #[test]
    fn conversions_display_with_their_layer() {
        let conversion = PsdConversion::new("Sky", "Layer effects were discarded.");
        assert_eq!(conversion.to_string(), "Sky: Layer effects were discarded.");
    }
}
