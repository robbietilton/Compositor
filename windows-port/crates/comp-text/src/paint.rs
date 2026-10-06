//! Pixel helpers shared by the text and shape rasterizers.
//!
//! Bitmaps hold straight (non-premultiplied) alpha, so compositing converts to premultiplied
//! weights on the way through and writes straight values back, as the compositor's contract asks.

use comp_core::Bitmap8;

/// A style channel in the 0-1 range as an 8-bit value. Anything damaged reads as its limit rather
/// than wrapping around.
pub fn channel(value: f64) -> u8 {
    if !value.is_finite() {
        return 0;
    }
    (value.clamp(0.0, 1.0) * 255.0).round() as u8
}

/// A color at a given opacity.
pub fn with_alpha(color: [u8; 3], alpha: u8) -> [u8; 4] {
    [color[0], color[1], color[2], alpha]
}

/// Writes one pixel, ignoring anything outside the raster so callers need no clipping of their own.
pub fn put_pixel(bitmap: &mut Bitmap8, x: i64, y: i64, rgba: [u8; 4]) {
    if x < 0 || y < 0 || x >= bitmap.width() as i64 || y >= bitmap.height() as i64 {
        return;
    }
    bitmap.set(x as u32, y as u32, rgba);
}

/// Composites one anti-aliased sample of `color` over the raster.
///
/// A glyph's coverage is its alpha, so two overlapping glyphs accumulate the way ink does instead of
/// the later one punching a hole in the earlier one.
pub fn blend_pixel(bitmap: &mut Bitmap8, x: i64, y: i64, color: [u8; 3], coverage: u8) {
    if coverage == 0 || x < 0 || y < 0 || x >= bitmap.width() as i64 || y >= bitmap.height() as i64 {
        return;
    }
    let (x, y) = (x as u32, y as u32);
    let destination = bitmap.get(x, y);
    if destination[3] == 0 {
        bitmap.set(x, y, with_alpha(color, coverage));
        return;
    }
    if coverage == 255 && destination[3] == 255 {
        bitmap.set(x, y, with_alpha(color, 255));
        return;
    }
    let source = coverage as f64 / 255.0;
    let destination_alpha = destination[3] as f64 / 255.0;
    let alpha = source + destination_alpha * (1.0 - source);
    if alpha <= 0.0 {
        return;
    }
    let mut rgba = [0u8; 4];
    for index in 0..3 {
        let value = (color[index] as f64 * source
            + destination[index] as f64 * destination_alpha * (1.0 - source))
            / alpha;
        rgba[index] = value.round().clamp(0.0, 255.0) as u8;
    }
    rgba[3] = (alpha * 255.0).round().clamp(0.0, 255.0) as u8;
    bitmap.set(x, y, rgba);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn channels_round_and_clamp() {
        assert_eq!(channel(0.0), 0);
        assert_eq!(channel(1.0), 255);
        assert_eq!(channel(0.5), 128);
        assert_eq!(channel(-3.0), 0);
        assert_eq!(channel(9.0), 255);
        assert_eq!(channel(f64::NAN), 0);
        assert_eq!(channel(f64::INFINITY), 0);
    }

    #[test]
    fn pixels_outside_the_raster_are_ignored() {
        let mut bitmap = Bitmap8::new(2, 2);
        put_pixel(&mut bitmap, -1, 0, [1, 2, 3, 255]);
        put_pixel(&mut bitmap, 2, 0, [1, 2, 3, 255]);
        put_pixel(&mut bitmap, 0, 5, [1, 2, 3, 255]);
        assert!(bitmap.is_fully_transparent());
        put_pixel(&mut bitmap, 1, 1, [1, 2, 3, 255]);
        assert_eq!(bitmap.get(1, 1), [1, 2, 3, 255]);
    }

    #[test]
    fn coverage_over_nothing_becomes_alpha() {
        let mut bitmap = Bitmap8::new(2, 1);
        blend_pixel(&mut bitmap, 0, 0, [10, 20, 30], 128);
        assert_eq!(bitmap.get(0, 0), [10, 20, 30, 128]);
        blend_pixel(&mut bitmap, 1, 0, [10, 20, 30], 0);
        assert_eq!(bitmap.get(1, 0), [0, 0, 0, 0]);
    }

    #[test]
    fn overlapping_samples_keep_the_ink_straight() {
        let mut bitmap = Bitmap8::new(1, 1);
        // Black over white at half coverage is mid gray, not black with half alpha.
        bitmap.set(0, 0, [255, 255, 255, 255]);
        blend_pixel(&mut bitmap, 0, 0, [0, 0, 0], 128);
        let pixel = bitmap.get(0, 0);
        assert_eq!(pixel[3], 255);
        assert!((120..=136).contains(&pixel[0]), "{pixel:?}");
    }

    #[test]
    fn a_second_coat_darkens_towards_the_color() {
        let mut bitmap = Bitmap8::new(1, 1);
        blend_pixel(&mut bitmap, 0, 0, [0, 0, 0], 64);
        let first = bitmap.get(0, 0);
        blend_pixel(&mut bitmap, 0, 0, [0, 0, 0], 64);
        let second = bitmap.get(0, 0);
        assert!(second[3] > first[3]);
        assert_eq!(second[0], 0);
    }

    #[test]
    fn full_coverage_replaces_an_opaque_pixel() {
        let mut bitmap = Bitmap8::filled(1, 1, [255, 255, 255, 255]);
        blend_pixel(&mut bitmap, 0, 0, [1, 2, 3], 255);
        assert_eq!(bitmap.get(0, 0), [1, 2, 3, 255]);
    }
}
