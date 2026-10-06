//! The cross-platform core of Compositor for Windows: the `.comp` project format and the document
//! model it stores.
//!
//! The pixel pipeline lives in `comp-render`, external file formats in `comp-io`, painting and
//! selection in `comp-brush`, and the Windows editor in `comp-gui`. This crate owns the format
//! contract: anything it accepts must also load in Compositor for macOS, and anything it writes
//! must round-trip there.
//!
//! Pixel buffers use straight (non-premultiplied) 8-bit RGBA, exactly like the PNGs inside a package.
pub mod adjustment;
pub mod bitmap;
pub mod blend;
pub mod digest;
pub mod document;
pub mod effects;
pub mod error;
pub mod geom;
pub mod history;
pub mod layer;
pub mod limits;
pub mod manifest;
pub mod png_io;
pub mod shape;
pub mod store;
pub mod text;
pub mod uuid_text;
pub mod validate;

pub use adjustment::{Adjustment, AdjustmentKind};
pub use bitmap::{Bitmap8, Gray8};
pub use blend::BlendMode;
pub use document::{Document, CURRENT_VERSION};
pub use error::{Error, ErrorSource, Result};
pub use geom::{Affine, Guide, GuideAxis, PointF, RectF, Sampling, SizeF, Transform};
pub use history::History;
pub use layer::{Layer, LayerKind};
pub use manifest::{LayerRecord, Manifest};
pub use store::{load, save, LoadedProject};
pub use validate::validate_manifest;

/// The version string the Windows editor reports.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
