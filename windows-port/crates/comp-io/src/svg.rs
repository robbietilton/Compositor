//! SVG import: a vector file rasterized into layer pixels.
//!
//! macOS draws an SVG once into a bitmap with its own renderer and brings it in as an ordinary
//! image layer, so nothing stays vector. resvg is the same shape of dependency here: pure Rust, no
//! C toolchain, and it renders through tiny-skia into premultiplied RGBA, which is converted to
//! straight alpha for Bitmap8.
use std::sync::{Arc, OnceLock};

use resvg::{tiny_skia, usvg};

use comp_core::bitmap::Bitmap8;

use crate::codec::check_limits;
use crate::error::{IoError, IoResult};
use crate::codec::ImportOptions;

/// How much of the file is searched for the svg element when sniffing the format.
const SNIFF_BYTES: usize = 4096;

/// The largest declared size a vector file may ask for; the pixel limits decide the rest.
const MAX_DECLARED_SIDE: f64 = 1_000_000.0;

/// True when the bytes look like an SVG document: XML whose root element is svg.
///
/// A vector file has no magic number, so this reads the head of the document rather than trusting
/// an extension. Only the first few kilobytes are searched, which is where the root element lives.
pub fn matches(bytes: &[u8]) -> bool {
    let head = &bytes[..bytes.len().min(SNIFF_BYTES)];
    let start = head.iter().position(|byte| !byte.is_ascii_whitespace()).unwrap_or(head.len());
    let head = &head[start.min(head.len())..];
    // A UTF-8 byte order mark may sit in front of the declaration.
    let head = head.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(head);
    if !head.starts_with(b"<") {
        return false;
    }
    contains_ignore_ascii_case(head, b"<svg")
}

fn contains_ignore_ascii_case(haystack: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() || haystack.len() < needle.len() {
        return false;
    }
    haystack.windows(needle.len()).any(|window| window.eq_ignore_ascii_case(needle))
}

/// A font database shared by every import: scanning the system's fonts once is what makes text in
/// an SVG render at all, and doing it per file would cost more than the rasterization.
fn system_fonts() -> Arc<usvg::fontdb::Database> {
    static FONTS: OnceLock<Arc<usvg::fontdb::Database>> = OnceLock::new();
    FONTS
        .get_or_init(|| {
            let mut database = usvg::fontdb::Database::new();
            database.load_system_fonts();
            Arc::new(database)
        })
        .clone()
}

/// The size an SVG declares, in user units: its width and height, or its viewBox.
pub fn declared_size(bytes: &[u8]) -> IoResult<(f64, f64)> {
    let tree = parse(bytes)?;
    let size = tree.size();
    Ok((f64::from(size.width()), f64::from(size.height())))
}

/// Rasterizes an SVG at the size it declares.
pub fn decode_svg(bytes: &[u8], options: &ImportOptions) -> IoResult<Bitmap8> {
    let tree = parse(bytes)?;
    let size = tree.size();
    let declared_width = f64::from(size.width());
    let declared_height = f64::from(size.height());
    if !declared_width.is_finite()
        || !declared_height.is_finite()
        || declared_width <= 0.0
        || declared_height <= 0.0
        || declared_width > MAX_DECLARED_SIDE
        || declared_height > MAX_DECLARED_SIDE
    {
        return Err(IoError::Unreadable(format!(
            "the SVG declares no usable size ({declared_width} by {declared_height})"
        )));
    }
    // macOS rounds the drawn size, with at least one pixel, and then checks the limits.
    let width = declared_width.round().max(1.0) as u32;
    let height = declared_height.round().max(1.0) as u32;
    check_limits(width, height, options.remaining_pixels)?;
    let mut pixmap = tiny_skia::Pixmap::new(width, height)
        .ok_or_else(|| IoError::TooLarge(format!("a {width}x{height} pixmap could not be allocated")))?;
    let transform = tiny_skia::Transform::from_scale(
        width as f32 / size.width(),
        height as f32 / size.height(),
    );
    // The pixmap starts fully transparent, which is what a background-less SVG means here.
    resvg::render(&tree, transform, &mut pixmap.as_mut());
    to_bitmap(&pixmap)
}

fn parse(bytes: &[u8]) -> IoResult<usvg::Tree> {
    let mut options = usvg::Options::default();
    // Scanning every installed font costs far more than rasterizing an icon, so the database is
    // only loaded for a document that could draw text at all.
    if text_is_possible(bytes) {
        options.fontdb = system_fonts();
    }
    usvg::Tree::from_data(bytes, &options)
        .map_err(|error| IoError::Unreadable(format!("the SVG could not be read: {error}")))
}

/// How much of a document is searched for a text element or a way to set a font.
const TEXT_SEARCH_BYTES: usize = 4 * 1024 * 1024;

fn text_is_possible(bytes: &[u8]) -> bool {
    let haystack = &bytes[..bytes.len().min(TEXT_SEARCH_BYTES)];
    [
        b"<text".as_slice(),
        b"<tspan",
        b"<textPath",
        b"<style",
        b"font-family",
        b"font=",
        b"font-size",
    ]
    .iter()
    .any(|needle| contains_ignore_ascii_case(haystack, needle))
}

/// tiny-skia's pixmap is premultiplied; Bitmap8 is straight alpha, so each pixel is divided back.
fn to_bitmap(pixmap: &tiny_skia::Pixmap) -> IoResult<Bitmap8> {
    let mut pixels = vec![0u8; pixmap.width() as usize * pixmap.height() as usize * 4];
    for (index, pixel) in pixmap.pixels().iter().enumerate() {
        let straight = pixel.demultiply();
        pixels[index * 4] = straight.red();
        pixels[index * 4 + 1] = straight.green();
        pixels[index * 4 + 2] = straight.blue();
        pixels[index * 4 + 3] = straight.alpha();
    }
    Bitmap8::from_raw(pixmap.width(), pixmap.height(), pixels).map_err(IoError::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn render(markup: &str) -> Bitmap8 {
        decode_svg(markup.as_bytes(), &ImportOptions::default()).expect("the SVG should render")
    }

    #[test]
    fn matches_an_xml_document_whose_root_is_svg() {
        assert!(matches(br##"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"/>"##));
        assert!(matches(b"\xef\xbb\xbf<svg/>"));
        assert!(matches(b"\n\t <SVG width='2' height='2'/>"));
        assert!(!matches(b"<html><body/></html>"));
        assert!(!matches(b"not xml at all"));
        assert!(!matches(&[]));
    }

    #[test]
    fn a_rect_fills_the_declared_size() {
        let image = render(
            r##"<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10">
                 <rect width="20" height="10" fill="#ff0000"/>
               </svg>"##,
        );
        assert_eq!((image.width(), image.height()), (20, 10));
        for (x, y) in [(0, 0), (19, 0), (0, 9), (19, 9), (10, 5)] {
            assert_eq!(image.get(x, y), [255, 0, 0, 255], "at ({x}, {y})");
        }
    }

    #[test]
    fn a_viewbox_scales_to_the_declared_size() {
        let image = render(
            r##"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40" viewBox="0 0 10 10">
                 <rect width="10" height="10" fill="#0000ff"/>
               </svg>"##,
        );
        assert_eq!((image.width(), image.height()), (40, 40));
        assert_eq!(image.get(0, 0), [0, 0, 255, 255]);
        assert_eq!(image.get(39, 39), [0, 0, 255, 255]);
    }

    #[test]
    fn the_geometry_is_where_the_markup_puts_it() {
        let image = render(
            r##"<svg xmlns="http://www.w3.org/2000/svg" width="12" height="8">
                 <rect width="12" height="8" fill="#ffffff"/>
                 <rect x="4" y="2" width="4" height="4" fill="#00ff00"/>
               </svg>"##,
        );
        assert_eq!(image.get(5, 3), [0, 255, 0, 255], "inside the green square");
        assert_eq!(image.get(3, 3), [255, 255, 255, 255], "left of it");
        assert_eq!(image.get(8, 3), [255, 255, 255, 255], "right of it");
        assert_eq!(image.get(5, 1), [255, 255, 255, 255], "above it");
        assert_eq!(image.get(5, 6), [255, 255, 255, 255], "below it");
    }

    #[test]
    fn alpha_survives_as_straight_coverage() {
        let image = render(
            r##"<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">
                 <rect width="8" height="8" fill="#ff0000" fill-opacity="0.5"/>
               </svg>"##,
        );
        let pixel = image.get(4, 4);
        // A premultiplied buffer would have halved the color as well; Bitmap8 is straight alpha.
        assert_eq!(pixel[0], 255, "{pixel:?}");
        assert!((pixel[3] as i32 - 128).abs() <= 1, "{pixel:?}");
        // Whatever the file leaves unpainted stays transparent.
        let empty = render(
            r##"<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">
                 <rect x="0" y="0" width="4" height="8" fill="#ffffff"/>
               </svg>"##,
        );
        assert_eq!(empty.get(6, 4), [0, 0, 0, 0]);
        assert_eq!(empty.get(1, 4), [255, 255, 255, 255]);
    }

    #[test]
    fn a_document_without_a_size_takes_the_size_of_its_content() {
        // No width, height or viewBox: the parser sizes the document from what it draws, rather
        // than refusing the file, and the render then covers that content exactly.
        let image = render(
            r##"<svg xmlns="http://www.w3.org/2000/svg"><rect width="10" height="10" fill="#123456"/></svg>"##,
        );
        assert_eq!((image.width(), image.height()), (10, 10));
        assert_eq!(image.get(5, 5), [0x12, 0x34, 0x56, 255]);
    }

    #[test]
    fn a_declared_size_of_zero_is_refused() {
        // The parser rejects a zero size itself, which reaches the caller as a read error.
        let zero = r##"<svg xmlns="http://www.w3.org/2000/svg" width="0" height="0"/>"##;
        assert!(matches!(decode_svg(zero.as_bytes(), &ImportOptions::default()), Err(IoError::Unreadable(_))));
        // An absurd one parses, and the importer refuses it by name before allocating.
        let absurd = r##"<svg xmlns="http://www.w3.org/2000/svg" width="10000001" height="10"/>"##;
        match decode_svg(absurd.as_bytes(), &ImportOptions::default()) {
            Err(IoError::Unreadable(message)) => assert!(message.contains("no usable size"), "{message}"),
            other => panic!("expected a size error, got {other:?}"),
        }
    }

    #[test]
    fn a_size_past_the_limits_is_refused_before_anything_is_drawn() {
        let markup = format!(
            r##"<svg xmlns="http://www.w3.org/2000/svg" width="{}" height="10">
                 <rect width="10" height="10" fill="#ff0000"/>
               </svg>"##,
            comp_core::limits::MAX_SIDE + 1
        );
        assert!(matches!(decode_svg(markup.as_bytes(), &ImportOptions::default()), Err(IoError::TooLarge(_))));
        let budget = ImportOptions { remaining_pixels: 100, ..ImportOptions::default() };
        let small = r##"<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"/>"##;
        assert!(matches!(decode_svg(small.as_bytes(), &budget), Err(IoError::TooLarge(_))));
    }

    #[test]
    fn damaged_markup_is_refused_with_a_message() {
        for markup in ["<svg", "<svg><rect", "", "<!DOCTYPE svg>", "<svg><unknown-element/></svg>"] {
            let outcome = decode_svg(markup.as_bytes(), &ImportOptions::default());
            assert!(outcome.is_err(), "{markup:?} should not render");
        }
        let outcome = decode_svg(b"<svg><rect", &ImportOptions::default()).unwrap_err();
        assert!(matches!(outcome, IoError::Unreadable(_)), "{outcome:?}");
    }

    #[test]
    fn the_declared_size_matches_what_is_rendered() {
        let markup = br##"<svg xmlns="http://www.w3.org/2000/svg" width="17" height="9" viewBox="0 0 34 18"/>"##;
        let (width, height) = declared_size(markup).unwrap();
        assert_eq!((width, height), (17.0, 9.0));
        let image = decode_svg(markup, &ImportOptions::default()).unwrap();
        assert_eq!((image.width(), image.height()), (17, 9));
    }

    #[test]
    fn a_document_with_text_still_rasterizes() {
        // Text needs a font database; the import must not fail when the machine has one, and must
        // not fail when the shapes are what carry the picture either.
        let markup = br##"<svg xmlns="http://www.w3.org/2000/svg" width="64" height="32">
                <rect width="64" height="32" fill="#ffffff"/>
                <text x="4" y="20" font-family="Arial" font-size="14" fill="#000000">Hi</text>
            </svg>"##;
        let image = decode_svg(markup, &ImportOptions::default()).unwrap();
        assert_eq!((image.width(), image.height()), (64, 32));
        assert_eq!(image.get(0, 0), [255, 255, 255, 255]);
    }
}

