//! Errors from the Camera Raw entry points.
use thiserror::Error;

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Error)]
pub enum Error {
    #[error(transparent)]
    Core(#[from] comp_core::Error),
    #[error("this file format is not a camera raw this build reads: .{0} (DNG and TIFF load through the image crate; NEF, CR2, CR3, ARW, RAF, RW2, ORF, PEF, SRW and the other formats rawloader knows go through the sensor decoder)")]
    Unsupported(String),
    #[error("this raw file could not be read: {0}")]
    Decode(String),
    /// A raw container this build recognizes but could not decode: an unknown camera, a compression
    /// the decoder does not implement, or a damaged file. The message is the decoder's own.
    #[error("this camera raw could not be decoded: {0}")]
    Vendor(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}
