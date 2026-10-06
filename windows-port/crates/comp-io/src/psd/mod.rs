//! Reading Photoshop documents: PSD and PSB.
//!
//! The reader covers the header and color mode, image resources, layer and mask information with
//! raw, PackBits and ZIP channels, groups, clipping masks, layer masks, opacity and blend modes.
//! Text and vector layers come in as their stored pixels; everything else the file declares is
//! reported as a conversion instead of being dropped quietly.
pub mod builder;
pub mod channel;
pub mod cursor;
pub mod reader;
pub mod types;

#[cfg(test)]
pub(crate) mod test_support;

pub use reader::{read_psd, read_psd_with_options, read_psd_with_report};
pub use types::{
    PsdColorMode, PsdConversion, PsdHeader, PsdImport, PsdLayerKind, PsdReadOptions, PSD_MAGIC,
};

use comp_core::document::Document;

use crate::error::IoResult;

/// Reads a Photoshop file and reports every conversion it needed.
pub fn read(bytes: &[u8]) -> IoResult<PsdImport> {
    read_psd_with_report(bytes)
}

/// True when the buffer starts with the Photoshop signature, as PSDReader.matches does.
pub fn matches(bytes: &[u8]) -> bool {
    bytes.starts_with(&PSD_MAGIC)
}

/// Reads a Photoshop file into a document.
pub fn read_document(bytes: &[u8]) -> IoResult<Document> {
    read_psd(bytes)
}
