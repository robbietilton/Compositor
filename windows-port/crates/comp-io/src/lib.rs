//! Import and export outside the .comp format: JPEG, TIFF, BMP, WebP, PNG, HEIC, SVG and Photoshop.
//!
//! This crate owns everything about a document that is not the package itself:
//!
//! - [codec] reads and writes raster files, with the resolution in PNG pHYs and JPEG JFIF fields.
//! - [metadata] reads the DPI every format records somewhere else: BMP's pels per meter, TIFF's
//!   IFD0 tags and WebP's EXIF chunk.
//! - [svg] rasterizes vector art with resvg, the way macOS draws an SVG once into pixels.
//! - [image_ops] resamples, crops and trims a single raster.
//! - [document_ops] resizes, crops and extends a whole document, moving layers and masks with it.
//! - [psd] reads Photoshop PSD and PSB files into the document model, with a conversion report.
//!
//! Pixels are straight 8-bit RGBA in comp_core::Bitmap8 and 8-bit gray in comp_core::Gray8, so
//! every format here converts at the boundary and never premultiplies what the compositor will
//! premultiply itself.
pub mod codec;
pub mod document_ops;
pub mod error;
pub mod format;
pub mod heic;
mod isobmff;
pub mod image_ops;
pub mod metadata;
pub mod psd;
pub mod svg;

pub use codec::{
    decode_raster, encode_jpeg, encode_png, export_jpeg, export_png, flatten_over_background,
    import_document, import_document_with, import_image, import_raster, place_imported,
    read_jpeg_resolution, read_png_resolution, ImportOptions, ImportedRaster, JpegOptions,
};
pub use document_ops::{
    canvas_extension_layer_id, canvas_resize, crop_document, resize_document, trim_document,
    CanvasSizeOptions, ImageSizeOptions,
};
pub use error::{IoError, IoResult};
/// True when a HEIF or AVIF file carries an auxiliary alpha image, which the system decoder does
/// not apply: a caller can use this to say that transparency was dropped.
pub use isobmff::has_auxiliary_alpha;
pub use format::RasterFormat;
pub use metadata::{read_bmp_resolution, read_tiff_resolution, read_webp_resolution};
pub use svg::decode_svg;
pub use image_ops::{
    crop_image, resize_image, trim_image, trim_rect, TrimBasedOn, TrimOptions, TrimRect,
};
pub use psd::{
    read_psd, read_psd_with_options, read_psd_with_report, PsdColorMode, PsdConversion, PsdHeader,
    PsdImport, PsdLayerKind, PsdReadOptions,
};

pub use comp_core as core;
