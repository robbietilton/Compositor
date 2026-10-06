//! The format's hard limits, matching `DocumentLimits` in the macOS app.
//!
//! The document pixel budget scales with physical memory there; here it is a constant budget the
//! caller may raise or lower for a specific machine.
/// Pixels allowed on one side of a canvas, an image or a mask.
pub const MAX_SIDE: u32 = 30_000;
/// Pixels allowed in one surface (image or mask).
pub const MAX_SURFACE_PIXELS: u64 = 200_000_000;
/// Image pixels allowed across a whole document.
pub const MAX_IMAGE_PIXELS: u64 = 100_000_000;
/// Mask pixels allowed across a whole document, in addition to image pixels.
pub const MAX_MASK_PIXELS: u64 = 100_000_000;
/// Layers allowed in one document.
pub const MAX_LAYERS: usize = 10_000;
/// Bytes allowed for `manifest.json`.
pub const MAX_MANIFEST_BYTES: u64 = 4 * 1024 * 1024;
/// Bytes allowed for one encoded PNG asset.
pub const MAX_ASSET_BYTES: u64 = 512 * 1024 * 1024;
/// Alignment guides allowed in one document.
pub const MAX_GUIDES: usize = 1_000;
/// UTF-16 units allowed in one text layer's content.
pub const MAX_TEXT_UTF16: usize = 100_000;
/// Ancestor depth allowed for nested groups.
pub const MAX_GROUP_DEPTH: usize = 64;
/// Nodes allowed in one live-mask (clipping) chain.
pub const MAX_LIVE_MASK_CHAIN: usize = 256;
/// Smallest paragraph box side, in layer pixels.
pub const MIN_TEXT_BOX_SIDE: f64 = 16.0;
/// The document budget in megapixels: physical memory / 4, clamped.
pub const DOCUMENT_BUDGET_MEGAPIXELS: u64 = 200;

/// The pixel budget for one document, in pixels.
pub fn document_pixel_budget() -> u64 {
    DOCUMENT_BUDGET_MEGAPIXELS * 1_000_000
}

/// True when a surface of this size fits the per-side and per-surface limits.
pub fn surface_fits(width: u32, height: u32) -> bool {
    width >= 1
        && height >= 1
        && width <= MAX_SIDE
        && height <= MAX_SIDE
        && width as u64 * height as u64 <= MAX_SURFACE_PIXELS
}
