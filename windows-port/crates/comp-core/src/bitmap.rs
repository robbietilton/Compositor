//! Raster buffers: 8-bit RGBA layer pixels and 8-bit grayscale masks.
//!
//! Pixels use straight (non-premultiplied) alpha, matching the PNG assets inside a `.comp`
//! package. The compositor converts to premultiplied linear-friendly floats internally.
use crate::error::{Error, Result};

/// An 8-bit RGBA raster in row-major order, 4 bytes per pixel, straight alpha.
#[derive(Clone, PartialEq, Eq)]
pub struct Bitmap8 {
    width: u32,
    height: u32,
    pixels: Vec<u8>,
}

impl std::fmt::Debug for Bitmap8 {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Bitmap8")
            .field("width", &self.width)
            .field("height", &self.height)
            .field("bytes", &self.pixels.len())
            .finish()
    }
}

impl Bitmap8 {
    /// A fully transparent raster.
    pub fn new(width: u32, height: u32) -> Self {
        Bitmap8 { width, height, pixels: vec![0; width as usize * height as usize * 4] }
    }

    /// A raster filled with one color.
    pub fn filled(width: u32, height: u32, rgba: [u8; 4]) -> Self {
        let mut pixels = vec![0u8; width as usize * height as usize * 4];
        for chunk in pixels.chunks_exact_mut(4) {
            chunk.copy_from_slice(&rgba);
        }
        Bitmap8 { width, height, pixels }
    }

    /// Wraps an existing RGBA buffer, checking its length.
    pub fn from_raw(width: u32, height: u32, pixels: Vec<u8>) -> Result<Self> {
        let expected = width as usize * height as usize * 4;
        if pixels.len() != expected {
            return Err(Error::BufferSize { got: pixels.len(), expected, width, height });
        }
        Ok(Bitmap8 { width, height, pixels })
    }

    pub fn width(&self) -> u32 {
        self.width
    }
    pub fn height(&self) -> u32 {
        self.height
    }
    pub fn pixels(&self) -> &[u8] {
        &self.pixels
    }
    pub fn pixels_mut(&mut self) -> &mut [u8] {
        &mut self.pixels
    }
    pub fn into_pixels(self) -> Vec<u8> {
        self.pixels
    }
    pub fn pixel_count(&self) -> usize {
        self.width as usize * self.height as usize
    }
    pub fn byte_len(&self) -> usize {
        self.pixels.len()
    }
    pub fn is_empty(&self) -> bool {
        self.width == 0 || self.height == 0
    }

    #[inline]
    pub fn index(&self, x: u32, y: u32) -> usize {
        (y as usize * self.width as usize + x as usize) * 4
    }

    #[inline]
    pub fn get(&self, x: u32, y: u32) -> [u8; 4] {
        let i = self.index(x, y);
        [self.pixels[i], self.pixels[i + 1], self.pixels[i + 2], self.pixels[i + 3]]
    }

    #[inline]
    pub fn set(&mut self, x: u32, y: u32, rgba: [u8; 4]) {
        let i = self.index(x, y);
        self.pixels[i..i + 4].copy_from_slice(&rgba);
    }

    #[inline]
    pub fn row(&self, y: u32) -> &[u8] {
        let start = y as usize * self.width as usize * 4;
        &self.pixels[start..start + self.width as usize * 4]
    }

    #[inline]
    pub fn row_mut(&mut self, y: u32) -> &mut [u8] {
        let start = y as usize * self.width as usize * 4;
        let width = self.width as usize * 4;
        &mut self.pixels[start..start + width]
    }

    pub fn fill(&mut self, rgba: [u8; 4]) {
        for chunk in self.pixels.chunks_exact_mut(4) {
            chunk.copy_from_slice(&rgba);
        }
    }

    pub fn clear(&mut self) {
        self.fill([0, 0, 0, 0]);
    }

    /// Fills an axis-aligned integer rectangle, clipped to the raster.
    pub fn fill_rect(&mut self, x: i64, y: i64, width: i64, height: i64, rgba: [u8; 4]) {
        let x0 = x.max(0).min(self.width as i64);
        let y0 = y.max(0).min(self.height as i64);
        let x1 = (x + width).max(0).min(self.width as i64);
        let y1 = (y + height).max(0).min(self.height as i64);
        for py in y0..y1 {
            for px in x0..x1 {
                self.set(px as u32, py as u32, rgba);
            }
        }
    }

    /// Copies the overlapping region of `src` onto this raster at `(x, y)`, replacing pixels.
    pub fn blit(&mut self, src: &Bitmap8, x: i64, y: i64) {
        self.blit_region(src, 0, 0, src.width, src.height, x, y);
    }

    /// Copies a source region onto this raster at `(x, y)`, replacing destination pixels.
    pub fn blit_region(&mut self, src: &Bitmap8, sx: i64, sy: i64, sw: u32, sh: u32, x: i64, y: i64) {
        let dst_x0 = x.max(0);
        let dst_y0 = y.max(0);
        let dst_x1 = (x + sw as i64).min(self.width as i64);
        let dst_y1 = (y + sh as i64).min(self.height as i64);
        if dst_x1 <= dst_x0 || dst_y1 <= dst_y0 {
            return;
        }
        for py in dst_y0..dst_y1 {
            let src_y = sy + (py - y);
            if src_y < 0 || src_y >= src.height as i64 {
                continue;
            }
            for px in dst_x0..dst_x1 {
                let src_x = sx + (px - x);
                if src_x < 0 || src_x >= src.width as i64 {
                    continue;
                }
                let rgba = src.get(src_x as u32, src_y as u32);
                self.set(px as u32, py as u32, rgba);
            }
        }
    }

    /// A copy of a sub-rectangle; pixels outside the source become transparent.
    pub fn subimage(&self, x: i64, y: i64, width: u32, height: u32) -> Bitmap8 {
        let mut out = Bitmap8::new(width, height);
        out.blit_region(self, x, y, width, height, 0, 0);
        out
    }

    /// Nearest-neighbor resampling to a new size.
    pub fn resized_nearest(&self, width: u32, height: u32) -> Bitmap8 {
        let mut out = Bitmap8::new(width, height);
        if self.is_empty() || out.is_empty() {
            return out;
        }
        for y in 0..height {
            let sy = (y as u64 * self.height as u64 / height as u64) as u32;
            for x in 0..width {
                let sx = (x as u64 * self.width as u64 / width as u64) as u32;
                out.set(x, y, self.get(sx.min(self.width - 1), sy.min(self.height - 1)));
            }
        }
        out
    }

    /// Bilinear resampling to a new size.
    pub fn resized_bilinear(&self, width: u32, height: u32) -> Bitmap8 {
        let mut out = Bitmap8::new(width, height);
        if self.is_empty() || out.is_empty() {
            return out;
        }
        let sx_scale = self.width as f64 / width as f64;
        let sy_scale = self.height as f64 / height as f64;
        for y in 0..height {
            let fy = ((y as f64 + 0.5) * sy_scale - 0.5).max(0.0);
            let y0 = fy.floor() as u32;
            let y1 = (y0 + 1).min(self.height - 1);
            let wy = fy - y0 as f64;
            for x in 0..width {
                let fx = ((x as f64 + 0.5) * sx_scale - 0.5).max(0.0);
                let x0 = fx.floor() as u32;
                let x1 = (x0 + 1).min(self.width - 1);
                let wx = fx - x0 as f64;
                let p00 = self.get(x0.min(self.width - 1), y0);
                let p10 = self.get(x1, y0);
                let p01 = self.get(x0.min(self.width - 1), y1);
                let p11 = self.get(x1, y1);
                let mut rgba = [0u8; 4];
                // Interpolate premultiplied so transparent pixels do not darken edges.
                let mut acc = [0.0f64; 4];
                let weights = [
                    (p00, (1.0 - wx) * (1.0 - wy)),
                    (p10, wx * (1.0 - wy)),
                    (p01, (1.0 - wx) * wy),
                    (p11, wx * wy),
                ];
                for (p, w) in weights {
                    let a = p[3] as f64 / 255.0;
                    acc[0] += p[0] as f64 * a * w;
                    acc[1] += p[1] as f64 * a * w;
                    acc[2] += p[2] as f64 * a * w;
                    acc[3] += p[3] as f64 * w;
                }
                let alpha = acc[3];
                if alpha > 0.0 {
                    let scale = 255.0 / alpha;
                    rgba[0] = (acc[0] * scale).round().clamp(0.0, 255.0) as u8;
                    rgba[1] = (acc[1] * scale).round().clamp(0.0, 255.0) as u8;
                    rgba[2] = (acc[2] * scale).round().clamp(0.0, 255.0) as u8;
                }
                rgba[3] = alpha.round().clamp(0.0, 255.0) as u8;
                out.set(x, y, rgba);
            }
        }
        out
    }

    /// A thumbnail whose largest side is at most `max_side`, never upscaling.
    pub fn thumbnail(&self, max_side: u32) -> Bitmap8 {
        if self.is_empty() {
            return self.clone();
        }
        let longest = self.width.max(self.height);
        if longest <= max_side {
            return self.clone();
        }
        let scale = max_side as f64 / longest as f64;
        let width = ((self.width as f64 * scale).round() as u32).max(1);
        let height = ((self.height as f64 * scale).round() as u32).max(1);
        self.resized_bilinear(width, height)
    }

    pub fn flipped_horizontally(&self) -> Bitmap8 {
        let mut out = Bitmap8::new(self.width, self.height);
        for y in 0..self.height {
            for x in 0..self.width {
                out.set(self.width - 1 - x, y, self.get(x, y));
            }
        }
        out
    }

    pub fn flipped_vertically(&self) -> Bitmap8 {
        let mut out = Bitmap8::new(self.width, self.height);
        for y in 0..self.height {
            for x in 0..self.width {
                out.set(x, self.height - 1 - y, self.get(x, y));
            }
        }
        out
    }

    pub fn rotated_180(&self) -> Bitmap8 {
        let mut out = Bitmap8::new(self.width, self.height);
        for y in 0..self.height {
            for x in 0..self.width {
                out.set(self.width - 1 - x, self.height - 1 - y, self.get(x, y));
            }
        }
        out
    }

    /// True when every pixel is fully transparent.
    pub fn is_fully_transparent(&self) -> bool {
        self.pixels.chunks_exact(4).all(|p| p[3] == 0)
    }

    /// The tight bounding box of non-transparent pixels as (x, y, width, height).
    pub fn opaque_bounds(&self) -> Option<(u32, u32, u32, u32)> {
        let mut min_x = u32::MAX;
        let mut min_y = u32::MAX;
        let mut max_x = 0u32;
        let mut max_y = 0u32;
        let mut found = false;
        for y in 0..self.height {
            for x in 0..self.width {
                if self.get(x, y)[3] != 0 {
                    found = true;
                    min_x = min_x.min(x);
                    min_y = min_y.min(y);
                    max_x = max_x.max(x);
                    max_y = max_y.max(y);
                }
            }
        }
        if !found {
            return None;
        }
        Some((min_x, min_y, max_x - min_x + 1, max_y - min_y + 1))
    }
}

/// An 8-bit grayscale raster, used for layer and folder masks.
#[derive(Clone, PartialEq, Eq)]
pub struct Gray8 {
    width: u32,
    height: u32,
    pixels: Vec<u8>,
}

impl std::fmt::Debug for Gray8 {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Gray8")
            .field("width", &self.width)
            .field("height", &self.height)
            .field("bytes", &self.pixels.len())
            .finish()
    }
}

impl Gray8 {
    pub fn new(width: u32, height: u32) -> Self {
        Gray8 { width, height, pixels: vec![0; width as usize * height as usize] }
    }

    pub fn filled(width: u32, height: u32, value: u8) -> Self {
        Gray8 { width, height, pixels: vec![value; width as usize * height as usize] }
    }

    pub fn from_raw(width: u32, height: u32, pixels: Vec<u8>) -> Result<Self> {
        let expected = width as usize * height as usize;
        if pixels.len() != expected {
            return Err(Error::BufferSize { got: pixels.len(), expected, width, height });
        }
        Ok(Gray8 { width, height, pixels })
    }

    pub fn width(&self) -> u32 {
        self.width
    }
    pub fn height(&self) -> u32 {
        self.height
    }
    pub fn pixels(&self) -> &[u8] {
        &self.pixels
    }
    pub fn pixels_mut(&mut self) -> &mut [u8] {
        &mut self.pixels
    }
    pub fn into_pixels(self) -> Vec<u8> {
        self.pixels
    }
    pub fn byte_len(&self) -> usize {
        self.pixels.len()
    }
    pub fn is_empty(&self) -> bool {
        self.width == 0 || self.height == 0
    }

    #[inline]
    pub fn index(&self, x: u32, y: u32) -> usize {
        y as usize * self.width as usize + x as usize
    }

    #[inline]
    pub fn get(&self, x: u32, y: u32) -> u8 {
        self.pixels[self.index(x, y)]
    }

    #[inline]
    pub fn set(&mut self, x: u32, y: u32, value: u8) {
        let i = self.index(x, y);
        self.pixels[i] = value;
    }

    pub fn fill(&mut self, value: u8) {
        self.pixels.fill(value);
    }

    pub fn row(&self, y: u32) -> &[u8] {
        let start = y as usize * self.width as usize;
        &self.pixels[start..start + self.width as usize]
    }

    pub fn resized_bilinear(&self, width: u32, height: u32) -> Gray8 {
        let mut out = Gray8::new(width, height);
        if self.is_empty() || out.is_empty() {
            return out;
        }
        let sx_scale = self.width as f64 / width as f64;
        let sy_scale = self.height as f64 / height as f64;
        for y in 0..height {
            let fy = ((y as f64 + 0.5) * sy_scale - 0.5).max(0.0);
            let y0 = fy.floor() as u32;
            let y1 = (y0 + 1).min(self.height - 1);
            let wy = fy - y0 as f64;
            for x in 0..width {
                let fx = ((x as f64 + 0.5) * sx_scale - 0.5).max(0.0);
                let x0 = fx.floor() as u32;
                let x1 = (x0 + 1).min(self.width - 1);
                let wx = fx - x0 as f64;
                let top = self.get(x0.min(self.width - 1), y0) as f64 * (1.0 - wx)
                    + self.get(x1, y0) as f64 * wx;
                let bottom = self.get(x0.min(self.width - 1), y1) as f64 * (1.0 - wx)
                    + self.get(x1, y1) as f64 * wx;
                let value = top * (1.0 - wy) + bottom * wy;
                out.set(x, y, value.round().clamp(0.0, 255.0) as u8);
            }
        }
        out
    }

    /// A uniform 1x1 mask saves allocation before any painting, matching the macOS app.
    pub fn is_uniform(&self) -> bool {
        match self.pixels.first() {
            None => true,
            Some(first) => self.pixels.iter().all(|p| p == first),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn index_and_accessors_roundtrip() {
        let mut bmp = Bitmap8::new(4, 3);
        bmp.set(2, 1, [10, 20, 30, 40]);
        assert_eq!(bmp.get(2, 1), [10, 20, 30, 40]);
        assert_eq!(bmp.index(2, 1), (1 * 4 + 2) * 4);
        assert_eq!(bmp.byte_len(), 4 * 3 * 4);
    }

    #[test]
    fn from_raw_rejects_wrong_length() {
        let err = Bitmap8::from_raw(2, 2, vec![0; 15]).unwrap_err();
        assert!(matches!(err, Error::BufferSize { .. }));
    }

    #[test]
    fn blit_clips_to_destination() {
        let src = Bitmap8::filled(2, 2, [255, 0, 0, 255]);
        let mut dst = Bitmap8::new(3, 3);
        dst.blit(&src, 2, 2);
        assert_eq!(dst.get(2, 2), [255, 0, 0, 255]);
        assert_eq!(dst.get(0, 0), [0, 0, 0, 0]);
    }

    #[test]
    fn thumbnail_never_upscales() {
        let bmp = Bitmap8::filled(10, 20, [1, 2, 3, 255]);
        assert_eq!(bmp.thumbnail(96).width(), 10);
        let small = bmp.thumbnail(10);
        assert_eq!((small.width(), small.height()), (5, 10));
    }

    #[test]
    fn opaque_bounds_finds_content() {
        let mut bmp = Bitmap8::new(8, 8);
        bmp.set(3, 4, [0, 0, 0, 255]);
        bmp.set(5, 6, [0, 0, 0, 255]);
        assert_eq!(bmp.opaque_bounds(), Some((3, 4, 3, 3)));
        assert_eq!(Bitmap8::new(4, 4).opaque_bounds(), None);
    }

    #[test]
    fn gray_mask_uniform_detection() {
        assert!(Gray8::filled(4, 4, 255).is_uniform());
        let mut mask = Gray8::filled(4, 4, 255);
        mask.set(1, 1, 0);
        assert!(!mask.is_uniform());
    }
}
