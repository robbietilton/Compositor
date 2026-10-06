//! Image-level size operations: resampling, cropping and trimming transparent edges.
//!
//! These mirror the pixel halves of the macOS ImageResizer and ImageTrim helpers. Documents use
//! the same rules through document_ops; this module is for a single raster, such as a layer's
//! pixels or a rendered canvas.
use comp_core::bitmap::Bitmap8;
use comp_core::geom::Sampling;
use comp_core::limits;

use crate::error::{IoError, IoResult};

/// Resamples an image to a new size.
///
/// macOS draws through Core Graphics, where High quality and Smooth both use the high
/// interpolation setting and Nearest disables interpolation; the mapping here is the same.
pub fn resize_image(image: &Bitmap8, width: u32, height: u32, sampling: Sampling) -> IoResult<Bitmap8> {
    if image.is_empty() {
        return Err(IoError::Invalid("an image with no pixels cannot be resized".into()));
    }
    if width == 0 || height == 0 {
        return Err(IoError::Invalid(format!("a resized image must have pixels; got {width}x{height}")));
    }
    if !limits::surface_fits(width, height) {
        return Err(IoError::TooLarge(format!(
            "{width}x{height} exceeds {} pixels per side or {} pixels in one surface",
            limits::MAX_SIDE,
            limits::MAX_SURFACE_PIXELS
        )));
    }
    Ok(match sampling {
        Sampling::Nearest => image.resized_nearest(width, height),
        Sampling::HighQuality | Sampling::Smooth => image.resized_bilinear(width, height),
    })
}

/// Copies a rectangle out of an image.
///
/// The rectangle must lie inside the image: a crop that reaches past the edge is a canvas
/// operation (crop_document), where the layers move instead of the pixels being padded.
pub fn crop_image(image: &Bitmap8, x: i64, y: i64, width: u32, height: u32) -> IoResult<Bitmap8> {
    if width == 0 || height == 0 {
        return Err(IoError::Invalid(format!("a crop must have pixels; got {width}x{height}")));
    }
    if x < 0 || y < 0 || x + width as i64 > image.width() as i64 || y + height as i64 > image.height() as i64 {
        return Err(IoError::Invalid(format!(
            "the crop {width}x{height} at ({x}, {y}) is not inside the {}x{} image",
            image.width(),
            image.height()
        )));
    }
    Ok(image.subimage(x, y, width, height))
}

/// What a trim measures its border against.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrimBasedOn {
    /// Fully transparent pixels.
    TransparentPixels,
    /// The color of the pixel at (0, 0).
    TopLeftPixelColor,
    /// The color of the pixel at (width - 1, height - 1).
    BottomRightPixelColor,
}

/// Which edges a trim may remove, and how far a pixel may differ from the sample.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TrimOptions {
    pub based_on: TrimBasedOn,
    pub top: bool,
    pub bottom: bool,
    pub left: bool,
    pub right: bool,
    /// Per-channel tolerance, 0 through 255.
    pub tolerance: u8,
}

impl Default for TrimOptions {
    fn default() -> Self {
        // Photoshop's Trim defaults: every edge, no tolerance, based on transparent pixels.
        TrimOptions {
            based_on: TrimBasedOn::TransparentPixels,
            top: true,
            bottom: true,
            left: true,
            right: true,
            tolerance: 0,
        }
    }
}

impl TrimOptions {
    pub fn trims_any(&self) -> bool {
        self.top || self.bottom || self.left || self.right
    }
}

/// The rectangle a trim keeps, in image coordinates.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TrimRect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

/// The area a trim would keep, or None when the whole image is border.
pub fn trim_rect(image: &Bitmap8, options: &TrimOptions) -> Option<TrimRect> {
    if !options.trims_any() || image.is_empty() {
        return None;
    }
    let width = image.width() as i64;
    let height = image.height() as i64;
    let (left, top, right, bottom) = match options.based_on {
        TrimBasedOn::TransparentPixels => transparent_bounds(image)?,
        TrimBasedOn::TopLeftPixelColor => color_bounds(image, (0, 0), options.tolerance)?,
        TrimBasedOn::BottomRightPixelColor => {
            color_bounds(image, (width - 1, height - 1), options.tolerance)?
        }
    };
    // An edge the caller keeps stays at the image's own edge, like Photoshop's Trim checkboxes.
    let min_x = if options.left { left } else { 0 };
    let min_y = if options.top { top } else { 0 };
    let max_x = if options.right { right } else { width };
    let max_y = if options.bottom { bottom } else { height };
    if max_x <= min_x || max_y <= min_y {
        return None;
    }
    Some(TrimRect {
        x: min_x as u32,
        y: min_y as u32,
        width: (max_x - min_x) as u32,
        height: (max_y - min_y) as u32,
    })
}

/// The trimmed image, or NothingToTrim when no content remains.
pub fn trim_image(image: &Bitmap8, options: &TrimOptions) -> IoResult<Bitmap8> {
    let rect = trim_rect(image, options).ok_or(IoError::NothingToTrim)?;
    crop_image(image, rect.x as i64, rect.y as i64, rect.width, rect.height)
}

/// The tight box of non-transparent pixels, as (left, top, right, bottom) with exclusive edges.
fn transparent_bounds(image: &Bitmap8) -> Option<(i64, i64, i64, i64)> {
    // opaque_bounds already walks the alpha channel and returns an inclusive box.
    let (x, y, width, height) = image.opaque_bounds()?;
    Some((x as i64, y as i64, (x + width) as i64, (y + height) as i64))
}

/// The tight box of pixels that differ from one sample color.
fn color_bounds(image: &Bitmap8, sample: (i64, i64), tolerance: u8) -> Option<(i64, i64, i64, i64)> {
    let target = image.get(sample.0 as u32, sample.1 as u32);
    let tolerance = tolerance as i32;
    let matches = |x: u32, y: u32| -> bool {
        let pixel = image.get(x, y);
        (0..4).all(|c| (pixel[c] as i32 - target[c] as i32).abs() <= tolerance)
    };
    let width = image.width() as i64;
    let height = image.height() as i64;
    let mut left = width;
    let mut right = 0i64;
    let mut top = height;
    let mut bottom = 0i64;
    for y in 0..height {
        let mut first = 0i64;
        while first < width && matches(first as u32, y as u32) {
            first += 1;
        }
        if first == width {
            continue;
        }
        let mut last = width;
        while last > first && matches((last - 1) as u32, y as u32) {
            last -= 1;
        }
        left = left.min(first);
        right = right.max(last);
        top = top.min(y);
        bottom = y + 1;
    }
    if right <= 0 {
        // Every pixel matched the sample: there is no content to keep.
        return None;
    }
    Some((left, top, right, bottom))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A 10x8 image with a 4x3 opaque block at (3, 2).
    fn bordered() -> Bitmap8 {
        let mut image = Bitmap8::new(10, 8);
        for y in 2..5 {
            for x in 3..7 {
                image.set(x, y, [200, 100, 50, 255]);
            }
        }
        image
    }

    #[test]
    fn resize_keeps_a_solid_color_and_changes_the_size() {
        let image = Bitmap8::filled(4, 4, [11, 22, 33, 255]);
        let resized = resize_image(&image, 9, 3, Sampling::HighQuality).unwrap();
        assert_eq!((resized.width(), resized.height()), (9, 3));
        assert_eq!(resized.get(4, 1), [11, 22, 33, 255]);
    }

    #[test]
    fn nearest_sampling_picks_source_pixels_exactly() {
        let mut image = Bitmap8::new(2, 1);
        image.set(0, 0, [0, 0, 0, 255]);
        image.set(1, 0, [255, 255, 255, 255]);
        let doubled = resize_image(&image, 4, 1, Sampling::Nearest).unwrap();
        assert_eq!(doubled.get(0, 0), [0, 0, 0, 255]);
        assert_eq!(doubled.get(3, 0), [255, 255, 255, 255]);
        // Bilinear spreads the edge, so the third pixel is neither source color.
        let smooth = resize_image(&image, 4, 1, Sampling::Smooth).unwrap();
        let third = smooth.get(2, 0);
        assert!(third[0] > 0 && third[0] < 255, "{third:?}");
    }

    #[test]
    fn resize_rejects_sizes_outside_the_limits() {
        let image = Bitmap8::filled(4, 4, [0, 0, 0, 255]);
        assert!(matches!(resize_image(&image, 0, 4, Sampling::Nearest), Err(IoError::Invalid(_))));
        assert!(matches!(
            resize_image(&image, limits::MAX_SIDE + 1, 1, Sampling::Nearest),
            Err(IoError::TooLarge(_))
        ));
        assert!(matches!(resize_image(&Bitmap8::new(0, 0), 4, 4, Sampling::Nearest), Err(IoError::Invalid(_))));
    }

    #[test]
    fn crop_takes_the_requested_rectangle_and_refuses_the_outside() {
        let image = bordered();
        let cropped = crop_image(&image, 3, 2, 4, 3).unwrap();
        assert_eq!((cropped.width(), cropped.height()), (4, 3));
        assert!(cropped.pixels().chunks_exact(4).all(|p| p[3] == 255));
        assert!(matches!(crop_image(&image, 8, 0, 4, 4), Err(IoError::Invalid(_))));
        assert!(matches!(crop_image(&image, -1, 0, 4, 4), Err(IoError::Invalid(_))));
        assert!(matches!(crop_image(&image, 0, 0, 0, 4), Err(IoError::Invalid(_))));
    }

    #[test]
    fn transparent_trim_finds_the_block() {
        let image = bordered();
        let rect = trim_rect(&image, &TrimOptions::default()).unwrap();
        assert_eq!(rect, TrimRect { x: 3, y: 2, width: 4, height: 3 });
        let trimmed = trim_image(&image, &TrimOptions::default()).unwrap();
        assert_eq!((trimmed.width(), trimmed.height()), (4, 3));
        assert_eq!(trimmed.get(0, 0), [200, 100, 50, 255]);
    }

    #[test]
    fn trim_only_touches_the_edges_it_is_given() {
        let image = bordered();
        let options = TrimOptions { left: false, top: false, ..TrimOptions::default() };
        let rect = trim_rect(&image, &options).unwrap();
        // The image's own left and top edges stay.
        assert_eq!(rect, TrimRect { x: 0, y: 0, width: 7, height: 5 });
        let none = TrimOptions { top: false, bottom: false, left: false, right: false, ..TrimOptions::default() };
        assert_eq!(trim_rect(&image, &none), None);
    }

    #[test]
    fn trim_reports_nothing_left_for_a_blank_or_solid_image() {
        assert!(matches!(
            trim_image(&Bitmap8::new(4, 4), &TrimOptions::default()),
            Err(IoError::NothingToTrim)
        ));
        // A solid opaque image has no transparent border, so trimming keeps all of it; only the
        // color modes can find nothing to keep.
        let solid = Bitmap8::filled(4, 4, [10, 20, 30, 255]);
        assert_eq!(trim_image(&solid, &TrimOptions::default()).unwrap(), solid);
        let by_color = TrimOptions { based_on: TrimBasedOn::TopLeftPixelColor, ..TrimOptions::default() };
        assert_eq!(trim_rect(&solid, &by_color), None);
        assert!(matches!(trim_image(&solid, &by_color), Err(IoError::NothingToTrim)));
    }

    #[test]
    fn color_trim_uses_the_sampled_corner_and_tolerance() {
        let mut image = Bitmap8::filled(6, 6, [255, 255, 255, 255]);
        // A white border around a slightly-off-white block: no tolerance still trims it.
        for y in 2..4 {
            for x in 1..5 {
                image.set(x, y, [250, 250, 250, 255]);
            }
        }
        let strict = TrimOptions { based_on: TrimBasedOn::TopLeftPixelColor, ..TrimOptions::default() };
        assert_eq!(trim_rect(&image, &strict).unwrap(), TrimRect { x: 1, y: 2, width: 4, height: 2 });
        let tolerant = TrimOptions { tolerance: 8, ..strict };
        assert_eq!(trim_rect(&image, &tolerant), None, "every pixel is within tolerance");
    }

    #[test]
    fn bottom_right_color_trim_uses_that_corner() {
        let mut image = Bitmap8::filled(5, 5, [0, 0, 0, 255]);
        image.set(0, 0, [255, 0, 0, 255]);
        let options = TrimOptions { based_on: TrimBasedOn::BottomRightPixelColor, ..TrimOptions::default() };
        let rect = trim_rect(&image, &options).unwrap();
        assert_eq!(rect, TrimRect { x: 0, y: 0, width: 1, height: 1 });
    }
}
