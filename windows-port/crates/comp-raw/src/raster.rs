//! The floating-point working image the pipeline runs on.
//!
//! The macOS kernels edit a premultiplied 8-bit buffer in place; the Windows pipeline keeps straight
//! alpha in `comp_core::Bitmap8`, so the kernels here run on straight 0…1 floats and quantize once,
//! at the end. Fully transparent pixels are skipped by every kernel, exactly as they are on macOS.

use comp_core::Bitmap8;

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Raster {
    pub width: usize,
    pub height: usize,
    /// Straight RGB in 0…1, row-major, one entry per pixel.
    pub rgb: Vec<[f64; 3]>,
    pub alpha: Vec<u8>,
}

impl Raster {
    pub fn from_bitmap(image: &Bitmap8) -> Self {
        let width = image.width() as usize;
        let height = image.height() as usize;
        let mut rgb = Vec::with_capacity(width * height);
        let mut alpha = Vec::with_capacity(width * height);
        for pixel in image.pixels().chunks_exact(4) {
            rgb.push([
                pixel[0] as f64 / 255.0,
                pixel[1] as f64 / 255.0,
                pixel[2] as f64 / 255.0,
            ]);
            alpha.push(pixel[3]);
        }
        Raster { width, height, rgb, alpha }
    }

    pub fn to_bitmap(&self) -> Bitmap8 {
        let mut bytes = Vec::with_capacity(self.rgb.len() * 4);
        for (color, alpha) in self.rgb.iter().zip(self.alpha.iter()) {
            bytes.push(quantize(color[0]));
            bytes.push(quantize(color[1]));
            bytes.push(quantize(color[2]));
            bytes.push(*alpha);
        }
        Bitmap8::from_raw(self.width as u32, self.height as u32, bytes)
            .expect("the raster keeps exactly four bytes per pixel")
    }

    #[inline]
    pub fn len(&self) -> usize {
        self.rgb.len()
    }

    #[inline]
    pub fn index(&self, x: usize, y: usize) -> usize {
        y * self.width + x
    }

    /// The luminance plane the blur-based effects read, as `f32` to match the kernel's planes.
    pub fn luma_plane(&self) -> Vec<f32> {
        self.rgb
            .iter()
            .zip(self.alpha.iter())
            .map(|(color, alpha)| {
                if *alpha == 0 {
                    0.0
                } else {
                    crate::math::rec709(color[0], color[1], color[2]) as f32
                }
            })
            .collect()
    }

    /// Bilinear sample that treats the raster as premultiplied and skips — rather than clamps or
    /// wraps — neighbors outside it, which is what `lens_distort` and the geometry warp do. Returns
    /// straight RGB plus the accumulated coverage; a sample that hangs off the edge keeps a partial
    /// alpha, so a warp leaves the transparent border that Constrain Crop trims.
    pub fn sample_premultiplied_skipped(&self, x: f64, y: f64) -> ([f64; 3], f64) {
        if self.width == 0 || self.height == 0 {
            return ([0.0, 0.0, 0.0], 0.0);
        }
        let x0 = x.floor();
        let y0 = y.floor();
        let fx = x - x0;
        let fy = y - y0;
        let (x0, y0) = (x0 as i64, y0 as i64);
        let mut sums = [0.0f64; 4];
        for (j, wy) in [(0i64, 1.0 - fy), (1, fy)] {
            if wy == 0.0 {
                continue;
            }
            let row = y0 + j;
            if row < 0 || row >= self.height as i64 {
                continue;
            }
            for (i, wx) in [(0i64, 1.0 - fx), (1, fx)] {
                if wx == 0.0 {
                    continue;
                }
                let column = x0 + i;
                if column < 0 || column >= self.width as i64 {
                    continue;
                }
                let index = row as usize * self.width + column as usize;
                let weight = wx * wy;
                let a = self.alpha[index] as f64 / 255.0;
                sums[0] += weight * self.rgb[index][0] * a;
                sums[1] += weight * self.rgb[index][1] * a;
                sums[2] += weight * self.rgb[index][2] * a;
                sums[3] += weight * a;
            }
        }
        let alpha = sums[3].min(1.0);
        if sums[3] <= 1e-12 {
            return ([0.0, 0.0, 0.0], alpha);
        }
        ([sums[0] / sums[3], sums[1] / sums[3], sums[2] / sums[3]], alpha)
    }

    /// The bounding box of the pixels that carry any alpha, as [left, top, right, bottom] with the
    /// right and bottom edges exclusive. Ported from `brush_alpha_bounds`.
    pub fn alpha_bounds(&self) -> Option<(usize, usize, usize, usize)> {
        let mut left = self.width;
        let mut right = 0usize;
        let mut top = self.height;
        let mut bottom = 0usize;
        for y in 0..self.height {
            let mut first = 0usize;
            while first < self.width && self.alpha[y * self.width + first] == 0 {
                first += 1;
            }
            if first == self.width {
                continue;
            }
            let mut last = self.width;
            while last > first && self.alpha[y * self.width + last - 1] == 0 {
                last -= 1;
            }
            left = left.min(first);
            right = right.max(last);
            top = top.min(y);
            bottom = y + 1;
        }
        if right == 0 {
            None
        } else {
            Some((left, top, right, bottom))
        }
    }
}

/// `write_premultiplied` rounds to the nearest byte and pins the range.
#[inline]
pub(crate) fn quantize(value: f64) -> u8 {
    (value * 255.0).round().clamp(0.0, 255.0) as u8
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raster_round_trips_an_opaque_bitmap() {
        let image = Bitmap8::from_raw(2, 1, vec![0, 64, 128, 255, 255, 255, 255, 255]).unwrap();
        let raster = Raster::from_bitmap(&image);
        assert_eq!(raster.len(), 2);
        assert!((raster.rgb[0][1] - 64.0 / 255.0).abs() < 1e-12);
        assert_eq!(raster.to_bitmap(), image);
    }

    #[test]
    fn transparent_pixels_report_a_zero_luma() {
        let image = Bitmap8::from_raw(1, 1, vec![255, 255, 255, 0]).unwrap();
        let raster = Raster::from_bitmap(&image);
        assert_eq!(raster.luma_plane(), vec![0.0f32]);
    }

    #[test]
    fn premultiplied_samples_blend_coverage() {
        let image = Bitmap8::from_raw(2, 1, vec![255, 0, 0, 255, 0, 0, 255, 0]).unwrap();
        let raster = Raster::from_bitmap(&image);
        let (rgb, alpha) = raster.sample_premultiplied_skipped(0.5, 0.0);
        assert!((alpha - 0.5).abs() < 1e-9);
        assert!((rgb[0] - 1.0).abs() < 1e-9, "the covered half keeps its color");
        // A sample that hangs off the edge keeps only the coverage of the neighbors that exist.
        let (_, partial) = raster.sample_premultiplied_skipped(-0.5, 0.0);
        assert!((partial - 0.5).abs() < 1e-9, "{partial}");
    }

    #[test]
    fn alpha_bounds_report_the_covered_rectangle() {
        let mut image = Bitmap8::new(4, 4);
        image.set(1, 2, [10, 20, 30, 255]);
        image.set(3, 3, [10, 20, 30, 128]);
        let raster = Raster::from_bitmap(&image);
        assert_eq!(raster.alpha_bounds(), Some((1, 2, 4, 4)));
        assert_eq!(Raster::from_bitmap(&Bitmap8::new(2, 2)).alpha_bounds(), None);
    }
}
