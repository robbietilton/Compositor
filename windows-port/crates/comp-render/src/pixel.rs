//! Premultiplied 8-bit surfaces and the resampling every placement needs.
//!
//! The macOS original composites in premultiplied 8-bit buffers: its C kernels divide a channel by the
//! alpha before a lookup and multiply back afterwards, and its Core Graphics contexts are
//! premultiplied-last. This port keeps that representation, so masks and opacity stay a plain multiply
//! and the adjustment kernels port across unchanged. Straight (non-premultiplied) RGBA only exists at
//! the crate's edges, where `Bitmap8` is.

use comp_core::geom::{Sampling, Transform};
use comp_core::{Affine, Bitmap8, Gray8};
use rayon::prelude::*;

/// The most halvings `reduced` will build, as `DownsampleCache.maxLevel` in the original.
pub const MAX_DOWNSAMPLE_LEVEL: u32 = 6;

/// Which filter a placement samples with, from the layer's own sampling setting.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Filter {
    Nearest,
    Bilinear,
    Bicubic,
}

impl Filter {
    /// Smooth is Core Graphics's `.low`; High quality is `.high`.
    pub fn of(sampling: Sampling) -> Filter {
        match sampling {
            Sampling::Nearest => Filter::Nearest,
            Sampling::Smooth => Filter::Bilinear,
            Sampling::HighQuality => Filter::Bicubic,
        }
    }
}

/// Rounds the way `roundf` does, for the places a kernel's exact byte matters.
#[inline]
pub fn round_u8(value: f32) -> u8 {
    let rounded = if value >= 0.0 { value + 0.5 } else { value - 0.5 };
    rounded.clamp(0.0, 255.0) as u8
}

/// One straight-alpha texel to its premultiplied bytes.
#[inline]
pub fn premultiply(rgba: [u8; 4]) -> [u8; 4] {
    let alpha = rgba[3] as u32;
    [
        ((rgba[0] as u32 * alpha + 127) / 255) as u8,
        ((rgba[1] as u32 * alpha + 127) / 255) as u8,
        ((rgba[2] as u32 * alpha + 127) / 255) as u8,
        rgba[3],
    ]
}

/// One premultiplied texel back to straight bytes, clamped as the kernels clamp.
#[inline]
pub fn unpremultiply(premultiplied: [u8; 4]) -> [u8; 4] {
    let alpha = premultiplied[3] as u32;
    if alpha == 0 {
        return [0, 0, 0, 0];
    }
    if alpha == 255 {
        return premultiplied;
    }
    [
        ((premultiplied[0] as u32 * 255 + alpha / 2) / alpha).min(255) as u8,
        ((premultiplied[1] as u32 * 255 + alpha / 2) / alpha).min(255) as u8,
        ((premultiplied[2] as u32 * 255 + alpha / 2) / alpha).min(255) as u8,
        premultiplied[3],
    ]
}

/// A straight-alpha 8-bit image in the premultiplied form the compositor works in.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Surface {
    width: u32,
    height: u32,
    pixels: Vec<u8>,
}

impl Surface {
    /// A fully transparent surface.
    pub fn new(width: u32, height: u32) -> Self {
        Surface { width, height, pixels: vec![0; width as usize * height as usize * 4] }
    }

    /// A surface filled with one premultiplied texel.
    pub fn filled(width: u32, height: u32, texel: [u8; 4]) -> Self {
        let mut pixels = vec![0u8; width as usize * height as usize * 4];
        for chunk in pixels.chunks_exact_mut(4) {
            chunk.copy_from_slice(&texel);
        }
        Surface { width, height, pixels }
    }

    /// Straight-alpha pixels taken into premultiplied form, as drawing a `CGImage` into a premultiplied
    /// context does.
    pub fn from_bitmap(bitmap: &Bitmap8) -> Self {
        let mut surface = Surface::new(bitmap.width(), bitmap.height());
        for (chunk, texel) in surface.pixels.chunks_exact_mut(4).zip(bitmap.pixels().chunks_exact(4)) {
            chunk.copy_from_slice(&premultiply([texel[0], texel[1], texel[2], texel[3]]));
        }
        surface
    }

    /// The premultiplied pixels back to straight alpha, the form `Bitmap8` and PNG use.
    pub fn to_bitmap(&self) -> Bitmap8 {
        let mut pixels = vec![0u8; self.pixels.len()];
        if self.width == 0 || self.height == 0 {
            return Bitmap8::from_raw(self.width, self.height, pixels).expect("surface pixels match its size");
        }
        let row_bytes = self.width as usize * 4;
        // Row by row in parallel: the write back is a pass over the whole canvas, and a 4000x4000 one is
        // 61 MiB, which is worth spreading.
        pixels
            .par_chunks_mut(row_bytes)
            .zip(self.pixels.par_chunks(row_bytes))
            .for_each(|(out_row, row)| {
                for (chunk, texel) in out_row.chunks_exact_mut(4).zip(row.chunks_exact(4)) {
                    chunk.copy_from_slice(&unpremultiply([texel[0], texel[1], texel[2], texel[3]]));
                }
            });
        Bitmap8::from_raw(self.width, self.height, pixels).expect("surface pixels match its size")
    }

    /// A gray mask as coverage: white at the mask's value, with that value as its alpha.
    pub fn from_mask(mask: &Gray8) -> Self {
        let mut surface = Surface::new(mask.width(), mask.height());
        for (chunk, value) in surface.pixels.chunks_exact_mut(4).zip(mask.pixels().iter()) {
            chunk.copy_from_slice(&[*value, *value, *value, *value]);
        }
        surface
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
    pub fn is_empty(&self) -> bool {
        self.width == 0 || self.height == 0
    }
    pub fn pixel_count(&self) -> usize {
        self.width as usize * self.height as usize
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
    pub fn set(&mut self, x: u32, y: u32, texel: [u8; 4]) {
        let i = self.index(x, y);
        self.pixels[i..i + 4].copy_from_slice(&texel);
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

    pub fn clear(&mut self) {
        self.pixels.fill(0);
    }

    /// Clears an integer rectangle, clipped to the surface. A placement clears only the box it will
    /// write, so a reused scratch surface never pays for a full-canvas wipe.
    pub fn clear_rect(&mut self, x: i64, y: i64, width: u32, height: u32) {
        let x0 = x.max(0).min(self.width as i64);
        let y0 = y.max(0).min(self.height as i64);
        let x1 = (x + width as i64).max(0).min(self.width as i64);
        let y1 = (y + height as i64).max(0).min(self.height as i64);
        for py in y0..y1 {
            let row = self.row_mut(py as u32);
            row[(x0 as usize) * 4..(x1 as usize) * 4].fill(0);
        }
    }

    /// Multiplies every alpha by `factor`, leaving the premultiplied colors alone - how Core Graphics
    /// applies `setAlpha` to a premultiplied image.
    pub fn scale_alpha(&mut self, factor: f32) {
        if factor >= 1.0 {
            return;
        }
        let factor = factor.max(0.0);
        for texel in self.pixels.chunks_exact_mut(4) {
            if texel[3] == 0 {
                continue;
            }
            let alpha = round_u8(texel[3] as f32 * factor);
            if alpha == texel[3] {
                continue;
            }
            if alpha == 0 {
                texel.copy_from_slice(&[0, 0, 0, 0]);
                continue;
            }
            // Keep the color straight by scaling the premultiplied channels with the alpha.
            let ratio = alpha as f32 / texel[3] as f32;
            texel[0] = round_u8(texel[0] as f32 * ratio);
            texel[1] = round_u8(texel[1] as f32 * ratio);
            texel[2] = round_u8(texel[2] as f32 * ratio);
            texel[3] = alpha;
        }
    }

    /// Multiplies every alpha by a coverage plane, the way a Core Graphics clip to a mask does.
    pub fn mask_by_plane(&mut self, plane: &Plane) {
        debug_assert_eq!((self.width, self.height), (plane.width, plane.height));
        for (texel, coverage) in self.pixels.chunks_exact_mut(4).zip(plane.values.iter()) {
            let value = *coverage as u32;
            if value == 255 {
                continue;
            }
            if value == 0 || texel[3] == 0 {
                texel.copy_from_slice(&[0, 0, 0, 0]);
                continue;
            }
            let alpha = (texel[3] as u32 * value + 127) / 255;
            let ratio = alpha as f32 / texel[3] as f32;
            texel[0] = round_u8(texel[0] as f32 * ratio);
            texel[1] = round_u8(texel[1] as f32 * ratio);
            texel[2] = round_u8(texel[2] as f32 * ratio);
            texel[3] = alpha as u8;
        }
    }

    /// The alpha channel as its own coverage plane.
    pub fn alpha_plane(&self) -> Plane {
        let mut plane = Plane::new(self.width, self.height);
        for (value, texel) in plane.values.iter_mut().zip(self.pixels.chunks_exact(4)) {
            *value = texel[3];
        }
        plane
    }

    /// One texel at a fractional pixel-corner coordinate, clamped at the edges. Coordinates count pixel
    /// corners, so pixel `i` covers `[i, i + 1)` and its center sits at `i + 0.5`.
    #[inline]
    pub fn sample(&self, x: f32, y: f32, filter: Filter) -> [f32; 4] {
        if self.is_empty() {
            return [0.0; 4];
        }
        match filter {
            Filter::Nearest => {
                let xi = (x.floor() as i64).clamp(0, self.width as i64 - 1) as u32;
                let yi = (y.floor() as i64).clamp(0, self.height as i64 - 1) as u32;
                let texel = self.get(xi, yi);
                [texel[0] as f32, texel[1] as f32, texel[2] as f32, texel[3] as f32]
            }
            Filter::Bilinear => self.sample_bilinear(x, y),
            Filter::Bicubic => self.sample_bicubic(x, y),
        }
    }

    #[inline]
    fn texel_f32(&self, x: i64, y: i64) -> [f32; 4] {
        let xi = x.clamp(0, self.width as i64 - 1) as usize;
        let yi = y.clamp(0, self.height as i64 - 1) as usize;
        let i = (yi * self.width as usize + xi) * 4;
        [
            self.pixels[i] as f32,
            self.pixels[i + 1] as f32,
            self.pixels[i + 2] as f32,
            self.pixels[i + 3] as f32,
        ]
    }

    fn sample_bilinear(&self, x: f32, y: f32) -> [f32; 4] {
        let fx = x - 0.5;
        let fy = y - 0.5;
        let x0 = fx.floor();
        let y0 = fy.floor();
        let wx = fx - x0;
        let wy = fy - y0;
        let (x0, y0) = (x0 as i64, y0 as i64);
        let mut out = [0.0f32; 4];
        for (dy, wy) in [(0i64, 1.0 - wy), (1, wy)] {
            for (dx, wx) in [(0i64, 1.0 - wx), (1, wx)] {
                let weight = wx * wy;
                if weight == 0.0 {
                    continue;
                }
                let texel = self.texel_f32(x0 + dx, y0 + dy);
                for c in 0..4 {
                    out[c] += texel[c] * weight;
                }
            }
        }
        out
    }

    /// Catmull-Rom, the cubic Core Graphics calls high quality when it enlarges.
    fn sample_bicubic(&self, x: f32, y: f32) -> [f32; 4] {
        let fx = x - 0.5;
        let fy = y - 0.5;
        let x0 = fx.floor();
        let y0 = fy.floor();
        let tx = fx - x0;
        let ty = fy - y0;
        let (x0, y0) = (x0 as i64, y0 as i64);
        let wx = cubic_weights(tx);
        let wy = cubic_weights(ty);
        let mut out = [0.0f32; 4];
        for (j, wy) in wy.iter().enumerate() {
            if *wy == 0.0 {
                continue;
            }
            for (i, wx) in wx.iter().enumerate() {
                let weight = wx * wy;
                if weight == 0.0 {
                    continue;
                }
                let texel = self.texel_f32(x0 + i as i64 - 1, y0 + j as i64 - 1);
                for c in 0..4 {
                    out[c] += texel[c] * weight;
                }
            }
        }
        out
    }

    /// Half the size, rounded up, averaging each 2x2 block: the sharp halving the original keeps so a
    /// large reduction never comes out of one wide filter pass.
    pub fn halve(&self) -> Surface {
        let width = self.width.div_ceil(2);
        let height = self.height.div_ceil(2);
        let mut out = Surface::new(width, height);
        for y in 0..height {
            for x in 0..width {
                let mut sums = [0u32; 4];
                let mut count = 0u32;
                for dy in 0..2u32 {
                    for dx in 0..2u32 {
                        let sx = x * 2 + dx;
                        let sy = y * 2 + dy;
                        if sx >= self.width || sy >= self.height {
                            continue;
                        }
                        let texel = self.get(sx, sy);
                        for c in 0..4 {
                            sums[c] += texel[c] as u32;
                        }
                        count += 1;
                    }
                }
                let mut texel = [0u8; 4];
                for c in 0..4 {
                    texel[c] = ((sums[c] + count / 2) / count) as u8;
                }
                out.set(x, y, texel);
            }
        }
        out
    }

    /// This surface halved `level` times, stopping early when a further halving would do nothing.
    pub fn reduced(&self, level: u32) -> (Surface, u32) {
        if level == 0 {
            return (self.clone(), 0);
        }
        let mut current = self.clone();
        let mut applied = 0;
        while applied < level && (current.width > 1 || current.height > 1) {
            current = current.halve();
            applied += 1;
        }
        (current, applied)
    }

    /// How many halvings a placement at `factor` output pixels per source pixel should draw from: the
    /// most that still leaves the copy at least that large.
    pub fn downsample_level(factor: f32) -> u32 {
        if !factor.is_finite() || factor <= 0.0 || factor >= 0.5 {
            return 0;
        }
        let level = (1.0 / factor as f64).log2().floor() as i64;
        level.clamp(0, MAX_DOWNSAMPLE_LEVEL as i64) as u32
    }
}

/// Catmull-Rom weights for the four taps around `t`.
fn cubic_weights(t: f32) -> [f32; 4] {
    let t2 = t * t;
    let t3 = t2 * t;
    [
        -0.5 * t3 + t2 - 0.5 * t,
        1.5 * t3 - 2.5 * t2 + 1.0,
        -1.5 * t3 + 2.0 * t2 + 0.5 * t,
        0.5 * t3 - 0.5 * t2,
    ]
}

/// An 8-bit coverage plane: a placed mask, or a shape the effect renderer works on.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Plane {
    width: u32,
    height: u32,
    values: Vec<u8>,
}

impl Plane {
    pub fn new(width: u32, height: u32) -> Self {
        Plane { width, height, values: vec![0; width as usize * height as usize] }
    }

    pub fn filled(width: u32, height: u32, value: u8) -> Self {
        Plane { width, height, values: vec![value; width as usize * height as usize] }
    }

    /// Wraps a gray buffer that is already width * height long.
    pub fn from_values(width: u32, height: u32, values: Vec<u8>) -> Self {
        debug_assert_eq!(values.len(), width as usize * height as usize);
        Plane { width, height, values }
    }

    pub fn width(&self) -> u32 {
        self.width
    }
    pub fn height(&self) -> u32 {
        self.height
    }
    pub fn values(&self) -> &[u8] {
        &self.values
    }
    pub fn values_mut(&mut self) -> &mut [u8] {
        &mut self.values
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
        self.values[self.index(x, y)]
    }

    #[inline]
    pub fn set(&mut self, x: u32, y: u32, value: u8) {
        let i = self.index(x, y);
        self.values[i] = value;
    }

    pub fn clear(&mut self) {
        self.values.fill(0);
    }

    /// Fills a rectangle with the value, clipped to the plane.
    pub fn fill_rect(&mut self, x: i64, y: i64, width: u32, height: u32, value: u8) {
        let x0 = x.max(0).min(self.width as i64);
        let y0 = y.max(0).min(self.height as i64);
        let x1 = (x + width as i64).max(0).min(self.width as i64);
        let y1 = (y + height as i64).max(0).min(self.height as i64);
        for py in y0..y1 {
            let row = &mut self.values[py as usize * self.width as usize..][..self.width as usize];
            row[x0 as usize..x1 as usize].fill(value);
        }
    }

    /// The plane as coverage: white at the value, alpha at the value.
    pub fn to_surface(&self) -> Surface {
        let mut surface = Surface::new(self.width, self.height);
        for (chunk, value) in surface.pixels.chunks_exact_mut(4).zip(self.values.iter()) {
            chunk.copy_from_slice(&[*value, *value, *value, *value]);
        }
        surface
    }
}

/// The integer rectangle a placement touches, clamped to a canvas: `(x, y, width, height)`.
pub fn pixel_bounds(
    transform: &Transform,
    canvas_width: u32,
    canvas_height: u32,
) -> Option<(i64, i64, u32, u32)> {
    transform.document_bounds().pixel_bounds(canvas_width, canvas_height)
}

/// The document-space center of a transform, the point its rotation and scaling keep.
pub fn transform_center(transform: &Transform) -> (f64, f64) {
    (
        transform.origin.x + transform.size.width / 2.0,
        transform.origin.y + transform.size.height / 2.0,
    )
}

/// The affine that takes a `width` by `height` pixel grid into the document through `transform`.
pub fn pixel_to_document(transform: &Transform, width: u32, height: u32) -> Affine {
    let scale_x = if width == 0 { 1.0 } else { transform.size.width / width as f64 };
    let scale_y = if height == 0 { 1.0 } else { transform.size.height / height as f64 };
    Affine::scale(scale_x, scale_y).then(transform.affine())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn premultiply_roundtrips_straight_pixels() {
        for texel in [[0u8, 0, 0, 0], [255, 128, 0, 255], [200, 100, 50, 128], [10, 20, 30, 32]] {
            let back = unpremultiply(premultiply(texel));
            if texel[3] == 0 {
                assert_eq!(back, [0, 0, 0, 0]);
                continue;
            }
            // Premultiplied bytes hold a color to within one step of the alpha they are stored with.
            let tolerance = (255 / texel[3] as i32) + 1;
            for c in 0..3 {
                assert!(
                    (back[c] as i32 - texel[c] as i32).abs() <= tolerance,
                    "{texel:?} -> {back:?} drifted past {tolerance}"
                );
            }
            assert_eq!(back[3], texel[3]);
        }
    }

    #[test]
    fn bitmap_roundtrips_through_a_surface() {
        let bitmap = Bitmap8::from_raw(2, 1, vec![10, 20, 30, 255, 40, 50, 60, 128]).unwrap();
        let surface = Surface::from_bitmap(&bitmap);
        assert_eq!(surface.get(0, 0), [10, 20, 30, 255]);
        assert_eq!(surface.get(1, 0)[3], 128);
        let back = surface.to_bitmap();
        assert_eq!(back.get(0, 0), [10, 20, 30, 255]);
        assert!((back.get(1, 0)[0] as i32 - 40).abs() <= 1);
    }

    #[test]
    fn halving_averages_two_by_two_blocks() {
        let mut surface = Surface::new(3, 2);
        for x in 0..3 {
            surface.set(x, 0, [255, 255, 255, 255]);
        }
        let half = surface.halve();
        assert_eq!((half.width(), half.height()), (2, 1));
        // Each column holds one opaque pixel of the top row and one transparent one below it.
        assert_eq!(half.get(0, 0)[3], 128);
        assert_eq!(half.get(1, 0)[3], 128);
    }

    #[test]
    fn downsample_level_matches_the_original_thresholds() {
        assert_eq!(Surface::downsample_level(1.0), 0);
        assert_eq!(Surface::downsample_level(0.5), 0);
        assert_eq!(Surface::downsample_level(0.49), 1);
        assert_eq!(Surface::downsample_level(0.25), 2);
        assert_eq!(Surface::downsample_level(0.26), 1);
        assert_eq!(Surface::downsample_level(0.0001), MAX_DOWNSAMPLE_LEVEL);
        assert_eq!(Surface::downsample_level(0.0), 0);
    }

    #[test]
    fn bilinear_sampling_keeps_edges() {
        let mut surface = Surface::new(2, 2);
        surface.set(0, 0, [255, 0, 0, 255]);
        let sample = surface.sample(0.5, 0.5, Filter::Bilinear);
        assert_eq!(sample, [255.0, 0.0, 0.0, 255.0]);
        let edge = surface.sample(-3.0, 0.5, Filter::Bilinear);
        assert_eq!(edge, [255.0, 0.0, 0.0, 255.0]);
    }

    #[test]
    fn mask_plane_multiplies_alpha() {
        let mut surface = Surface::filled(2, 1, [255, 255, 255, 255]);
        let plane = Plane::from_values(2, 1, vec![0, 128]);
        surface.mask_by_plane(&plane);
        assert_eq!(surface.get(0, 0)[3], 0);
        assert_eq!(surface.get(1, 0)[3], 128);
    }
}
