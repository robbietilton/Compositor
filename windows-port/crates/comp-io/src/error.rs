//! Errors the importers, exporters and size operations report.
//!
//! The messages are user-facing: the GUI shows them verbatim, so they name the file's problem
//! rather than an internal step. Every feature this crate cannot honor has a variant here;
//! nothing is dropped without either an error or a conversion note in the import report.
use thiserror::Error;

pub type IoResult<T> = std::result::Result<T, IoError>;

#[derive(Debug, Error)]
pub enum IoError {
    /// The bytes are not a decodable image: damaged, truncated, or not an image at all.
    #[error("the image could not be read: {0}")]
    Unreadable(String),
    /// A format this build does not handle.
    #[error("choose a JPEG, PNG, TIFF, BMP, or WebP file: {0}")]
    UnsupportedFormat(String),
    /// The image is larger than the format's limits allow.
    #[error("this image exceeds the supported limits: {0}")]
    TooLarge(String),
    /// Bit depth other than 8. Bitmap8 is 8-bit RGBA, and macOS's importer has the same rule.
    #[error("only 8-bit images can be imported; this file is {0}")]
    UnsupportedDepth(String),
    /// A Photoshop color mode this build cannot convert.
    #[error("only 8-bit RGB Photoshop files can be imported; this file is {0}")]
    UnsupportedColorMode(String),
    #[error("this Photoshop file uses format version {0}, which this build cannot read")]
    UnsupportedVersion(u16),
    #[error("the Photoshop file is damaged or incomplete: {0}")]
    Truncated(String),
    #[error("this Photoshop file uses layer compression {0}, which is not supported")]
    UnsupportedCompression(u16),
    /// A feature outside this pass's scope, refused instead of silently approximated.
    #[error("{0}")]
    UnsupportedFeature(String),
    /// A caller-supplied size, rect or parameter that cannot be honored.
    #[error("{0}")]
    Invalid(String),
    #[error("no content remained after trimming")]
    NothingToTrim,
    #[error(transparent)]
    Core(#[from] comp_core::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

impl IoError {
    /// The message the macOS app would show for the same failure.
    pub fn user_message(&self) -> String {
        self.to_string()
    }
}
