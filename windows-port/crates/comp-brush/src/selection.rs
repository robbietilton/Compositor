//! Selections: 8-bit coverage masks plus the shape, modulation and boolean operations
//! Photoshop and the macOS app expose.
//!
//! A selection is a Gray8 mask at document resolution, white where the document is selected.
//! Unlike the macOS path-based DocumentSelection, the mask is the source of truth here: it
//! carries antialiased and feathered edges directly, clips painting and fills, and can be
//! loaded from a layer's alpha or its mask. Higher levels may keep a vector outline for
//! display, but every edit reads this raster.

use comp_core::{Affine, Bitmap8, Error, Gray8, PointF, RectF, Result, Sampling};
use rayon::prelude::*;

use crate::transform;

/// How a new selection combines with the one already in place.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SelectionOp {
    /// Throw the old selection away.
    Replace,
    /// Add the new shape to the old selection.
    Add,
    /// Remove the new shape from the old selection.
    Subtract,
    /// Keep only the overlap.
    Intersect,
}

/// Longest feather radius the macOS app accepts.
pub const MAX_FEATHER: f64 = 250.0;
/// Rows sampled per pixel row when antialiasing a shape.
const SUB_ROWS: u32 = 4;

/// Coverage of a selection, white where selected.
#[derive(Clone, PartialEq, Eq)]
pub struct Selection {
    mask: Gray8,
}

impl std::fmt::Debug for Selection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Selection")
            .field("width", &self.mask.width())
            .field("height", &self.mask.height())
            .field("bounds", &self.bounds())
            .finish()
    }
}

impl Selection {
    /// Nothing selected.
    pub fn new(width: u32, height: u32) -> Self {
        Selection { mask: Gray8::new(width, height) }
    }

    /// Everything selected.
    pub fn all(width: u32, height: u32) -> Self {
        Selection { mask: Gray8::filled(width, height, 255) }
    }

    /// Wraps an existing coverage mask (a layer mask, or the alpha channel read as gray).
    pub fn from_gray(mask: Gray8) -> Self {
        Selection { mask }
    }

    /// A layer's alpha channel as a selection: Cmd-clicking a layer thumbnail.
    pub fn from_alpha(image: &Bitmap8) -> Self {
        let mut mask = Gray8::new(image.width(), image.height());
        for y in 0..image.height() {
            let row = image.row(y);
            let out = gray_row_mut(&mut mask, y);
            for (x, value) in out.iter_mut().enumerate() {
                *value = row[x * 4 + 3];
            }
        }
        Selection { mask }
    }

    /// A mask read as a selection (a layer mask, or any other coverage buffer).
    pub fn from_mask(mask: &Gray8) -> Self {
        Selection { mask: mask.clone() }
    }

    pub fn into_gray(self) -> Gray8 {
        self.mask
    }

    pub fn as_gray(&self) -> &Gray8 {
        &self.mask
    }

    pub fn as_gray_mut(&mut self) -> &mut Gray8 {
        &mut self.mask
    }

    pub fn width(&self) -> u32 {
        self.mask.width()
    }

    pub fn height(&self) -> u32 {
        self.mask.height()
    }

    #[inline]
    pub fn coverage(&self, x: u32, y: u32) -> u8 {
        self.mask.get(x, y)
    }

    pub fn set_coverage(&mut self, x: u32, y: u32, value: u8) {
        self.mask.set(x, y, value);
    }

    /// True when nothing at all is selected. Edits must treat this as "touch nothing".
    pub fn is_empty(&self) -> bool {
        self.mask.pixels().iter().all(|v| *v == 0)
    }

    /// True when the whole canvas is selected.
    pub fn is_all(&self) -> bool {
        self.mask.pixels().iter().all(|v| *v == 255)
    }

    /// The tight bounds of the selected pixels as (x, y, width, height).
    pub fn bounds(&self) -> Option<(i64, i64, u32, u32)> {
        let mut min_x = i64::MAX;
        let mut min_y = i64::MAX;
        let mut max_x = i64::MIN;
        let mut max_y = i64::MIN;
        for y in 0..self.mask.height() {
            for x in 0..self.mask.width() {
                if self.mask.get(x, y) != 0 {
                    min_x = min_x.min(x as i64);
                    min_y = min_y.min(y as i64);
                    max_x = max_x.max(x as i64);
                    max_y = max_y.max(y as i64);
                }
            }
        }
        if max_x < min_x {
            return None;
        }
        Some((min_x, min_y, (max_x - min_x + 1) as u32, (max_y - min_y + 1) as u32))
    }

    /// Total selected area in pixel units: the sum of the coverage, so an antialiased edge
    /// counts for the fraction it covers.
    pub fn area(&self) -> f64 {
        self.mask.pixels().iter().map(|v| *v as f64 / 255.0).sum()
    }

    fn check_size(&self, other: &Selection) -> Result<()> {
        if self.width() != other.width() || self.height() != other.height() {
            return Err(Error::BufferSize {
                got: other.mask.byte_len(),
                expected: self.mask.byte_len(),
                width: self.width(),
                height: self.height(),
            });
        }
        Ok(())
    }

    /// A rectangular marquee. Coordinates snap to whole pixels, as the macOS Marquee does
    /// with antialiasing off; with it on the edges are exact fractions of a pixel.
    pub fn rect(width: u32, height: u32, rect: RectF, antialiased: bool) -> Self {
        let corners = [
            PointF::new(rect.x, rect.y),
            PointF::new(rect.max_x(), rect.y),
            PointF::new(rect.max_x(), rect.max_y()),
            PointF::new(rect.x, rect.max_y()),
        ];
        Selection::polygon(width, height, &corners, antialiased)
    }

    /// An elliptical marquee filling `rect`.
    pub fn ellipse(width: u32, height: u32, rect: RectF, antialiased: bool) -> Self {
        let mut values = vec![0f64; width as usize * height as usize];
        if width == 0 || height == 0 || rect.width <= 0.0 || rect.height <= 0.0 {
            return Selection { mask: Gray8::new(width, height) };
        }
        let rx = rect.width / 2.0;
        let ry = rect.height / 2.0;
        let cx = rect.x + rx;
        let cy = rect.y + ry;
        let rows = if antialiased { SUB_ROWS } else { 1 };
        let y0 = (cy - ry).floor().max(0.0) as i64;
        let y1 = (cy + ry).ceil().min(height as f64) as i64;
        let weight = 1.0 / rows as f64;
        let mut spans: Vec<(f64, f64)> = Vec::with_capacity(1);
        for y in y0..y1 {
            let mut row = vec![0f64; width as usize];
            for sub in 0..rows {
                let sy = y as f64 + (sub as f64 + 0.5) / rows as f64;
                let t = (sy - cy) / ry;
                if t.abs() >= 1.0 {
                    continue;
                }
                let half = rx * (1.0 - t * t).sqrt();
                spans.clear();
                spans.push((cx - half, cx + half));
                for (x0, x1) in &spans {
                    accumulate_span(&mut row, width, *x0, *x1, weight);
                }
            }
            for (x, value) in row.iter().enumerate() {
                if *value > 0.0 {
                    values[y as usize * width as usize + x] = finalize(*value, antialiased);
                }
            }
        }
        Selection { mask: mask_from_values(width, height, &values) }
    }

    /// A closed polygon: the freehand lasso, the polygonal lasso and the marquee all rasterize
    /// through here. The fill rule is nonzero winding, as Core Graphics' `.winding`.
    pub fn polygon(width: u32, height: u32, points: &[PointF], antialiased: bool) -> Self {
        let mut values = vec![0f64; width as usize * height as usize];
        if width == 0 || height == 0 || points.len() < 3 {
            return Selection { mask: Gray8::new(width, height) };
        }
        if points.iter().any(|p| !p.is_finite()) {
            return Selection { mask: Gray8::new(width, height) };
        }
        let mut min_y = f64::INFINITY;
        let mut max_y = f64::NEG_INFINITY;
        for point in points {
            min_y = min_y.min(point.y);
            max_y = max_y.max(point.y);
        }
        let rows = if antialiased { SUB_ROWS } else { 1 };
        let weight = 1.0 / rows as f64;
        let y0 = min_y.floor().max(0.0) as i64;
        let y1 = max_y.ceil().min(height as f64) as i64;
        let mut spans: Vec<(f64, f64)> = Vec::new();
        for y in y0..y1 {
            let mut row = vec![0f64; width as usize];
            for sub in 0..rows {
                let sy = y as f64 + (sub as f64 + 0.5) / rows as f64;
                spans.clear();
                polygon_spans(points, sy, &mut spans);
                for (x0, x1) in &spans {
                    accumulate_span(&mut row, width, *x0, *x1, weight);
                }
            }
            for (x, value) in row.iter().enumerate() {
                if *value > 0.0 {
                    values[y as usize * width as usize + x] = finalize(*value, antialiased);
                }
            }
        }
        Selection { mask: mask_from_values(width, height, &values) }
    }

    /// The freehand lasso: the outline closes itself.
    pub fn lasso(width: u32, height: u32, points: &[PointF], antialiased: bool) -> Self {
        Selection::polygon(width, height, points, antialiased)
    }

    /// Everything that is not selected. A full selection inverts to an empty one, which the
    /// caller should treat as "no selection" the way Photoshop does.
    pub fn inverted(&self) -> Selection {
        let mut mask = Gray8::new(self.width(), self.height());
        for y in 0..self.height() {
            let source = self.mask.row(y);
            let out = gray_row_mut(&mut mask, y);
            for (x, value) in out.iter_mut().enumerate() {
                *value = 255 - source[x];
            }
        }
        Selection { mask }
    }

    /// Boolean combination with another selection of the same size.
    pub fn combine(&self, other: &Selection, op: SelectionOp) -> Result<Selection> {
        self.check_size(other)?;
        let mut mask = Gray8::new(self.width(), self.height());
        for y in 0..self.height() {
            let a = self.mask.row(y);
            let b = other.mask.row(y);
            let out = gray_row_mut(&mut mask, y);
            for (x, value) in out.iter_mut().enumerate() {
                let left = a[x] as u32;
                let right = b[x] as u32;
                *value = match op {
                    SelectionOp::Replace => b[x],
                    // Coverage union: max keeps a hard edge hard and a soft edge soft.
                    SelectionOp::Add => left.max(right) as u8,
                    SelectionOp::Intersect => left.min(right) as u8,
                    // Coverage difference, so a feathered edge thins out instead of cutting.
                    SelectionOp::Subtract => ((left * (255 - right) + 127) / 255) as u8,
                };
            }
        }
        Ok(Selection { mask })
    }

    pub fn union(&self, other: &Selection) -> Result<Selection> {
        self.combine(other, SelectionOp::Add)
    }

    pub fn intersection(&self, other: &Selection) -> Result<Selection> {
        self.combine(other, SelectionOp::Intersect)
    }

    pub fn difference(&self, other: &Selection) -> Result<Selection> {
        self.combine(other, SelectionOp::Subtract)
    }

    /// Softens the edge by `radius` document pixels, as Select > Modify > Feather does. The
    /// macOS app blurs with sigma = feather / 2 and lets the edge fade either side of the
    /// outline, which is what this reproduces.
    pub fn feathered(&self, radius: f64) -> Selection {
        if !radius.is_finite() || radius <= 0.0 {
            return self.clone();
        }
        Selection { mask: gaussian_blur(&self.mask, radius.clamp(0.0, MAX_FEATHER) / 2.0) }
    }

    /// Grows the selection by `amount` pixels with rounded corners, clipped to the canvas.
    pub fn expanded(&self, amount: f64) -> Selection {
        if !amount.is_finite() || amount <= 0.0 {
            return self.clone();
        }
        let width = self.width();
        let height = self.height();
        let selected: Vec<bool> = self.mask.pixels().iter().map(|v| *v != 0).collect();
        if !selected.iter().any(|v| *v) {
            return self.clone();
        }
        let outside = distance_field(&selected, width, height);
        let mut values = vec![0f64; selected.len()];
        for (index, value) in values.iter_mut().enumerate() {
            // A pixel's square reaches half a pixel past its center, hence the extra 1.0: the
            // ramp lands exactly on the dilated outline for both whole and fractional amounts.
            let ramp = (amount + 1.0 - outside[index].sqrt()).clamp(0.0, 1.0);
            let existing = self.mask.pixels()[index] as f64 / 255.0;
            // max: the stroke band never takes coverage away from the original selection.
            *value = existing.max(ramp);
        }
        Selection { mask: mask_from_values(width, height, &values) }
    }

    /// Shrinks the selection by `amount` pixels, including away from the canvas edges.
    /// Contracting past the middle leaves an empty selection, never a full one.
    pub fn contracted(&self, amount: f64) -> Selection {
        if !amount.is_finite() || amount <= 0.0 {
            return self.clone();
        }
        let width = self.width();
        let height = self.height();
        let outside: Vec<bool> = self.mask.pixels().iter().map(|v| *v == 0).collect();
        if !outside.iter().any(|v| *v) {
            // Nothing on the canvas is unselected, so the edge cannot retreat.
            return self.clone();
        }
        let inside = distance_field(&outside, width, height);
        let mut values = vec![0f64; outside.len()];
        for (index, value) in values.iter_mut().enumerate() {
            let ramp = (inside[index].sqrt() - amount).clamp(0.0, 1.0);
            let existing = self.mask.pixels()[index] as f64 / 255.0;
            // min: contracting only ever takes coverage away.
            *value = existing.min(ramp);
        }
        Selection { mask: mask_from_values(width, height, &values) }
    }

    /// Resamples the selection through an affine map, so the outline follows transformed
    /// pixels. The result keeps the same canvas size.
    pub fn transformed(&self, affine: &Affine, sampling: Sampling) -> Result<Selection> {
        let mask = transform::resample_mask(&self.mask, self.width(), self.height(), affine, sampling)?;
        Ok(Selection { mask })
    }

    /// The layer pixels restricted to the selection: coverage multiplies alpha, so a feathered
    /// edge fades the pixels out instead of cutting them.
    pub fn clipped_bitmap(&self, image: &Bitmap8) -> Result<Bitmap8> {
        self.check_bitmap(image)?;
        let mut out = image.clone();
        for y in 0..image.height() {
            let mask = self.mask.row(y);
            let row = out.row_mut(y);
            for x in 0..image.width() as usize {
                let coverage = mask[x] as u32;
                let alpha = row[x * 4 + 3] as u32;
                row[x * 4 + 3] = ((alpha * coverage + 127) / 255) as u8;
            }
        }
        Ok(out)
    }

    /// The selected pixels alone, cropped to the selection's bounds: what a copy or a
    /// selection-scoped filter works on. Returns the pixels and the region's origin.
    pub fn cropped_bitmap(&self, image: &Bitmap8) -> Result<Option<(Bitmap8, (i64, i64))>> {
        self.check_bitmap(image)?;
        let Some((x, y, width, height)) = self.bounds() else {
            return Ok(None);
        };
        let clipped = self.clipped_bitmap(image)?;
        Ok(Some((clipped.subimage(x, y, width, height), (x, y))))
    }

    /// Fills the selected pixels with a color, honoring partial coverage.
    pub fn fill_bitmap(&self, image: &mut Bitmap8, rgba: [u8; 4]) -> Result<()> {
        self.check_bitmap(image)?;
        for y in 0..image.height() {
            let mask = self.mask.row(y);
            for x in 0..image.width() {
                let coverage = mask[x as usize];
                if coverage == 0 {
                    continue;
                }
                let alpha = rgba[3] as f64 / 255.0 * coverage as f64 / 255.0;
                let blended = crate::brush::source_over(rgba, image.get(x, y), alpha);
                image.set(x, y, blended);
            }
        }
        Ok(())
    }

    /// Clears the selected pixels to transparency, honoring partial coverage.
    pub fn clear_bitmap(&self, image: &mut Bitmap8) -> Result<()> {
        self.check_bitmap(image)?;
        let width = image.width() as usize;
        for y in 0..image.height() {
            let mask = self.mask.row(y);
            let row = image.row_mut(y);
            for x in 0..width {
                let coverage = mask[x] as u32;
                if coverage == 0 {
                    continue;
                }
                let alpha = row[x * 4 + 3] as u32;
                row[x * 4 + 3] = ((alpha * (255 - coverage) + 127) / 255) as u8;
            }
        }
        Ok(())
    }

    fn check_bitmap(&self, image: &Bitmap8) -> Result<()> {
        if image.width() != self.width() || image.height() != self.height() {
            return Err(Error::BufferSize {
                got: image.byte_len(),
                expected: self.mask.byte_len() * 4,
                width: self.width(),
                height: self.height(),
            });
        }
        Ok(())
    }
}

/// Gray8 has no mutable row accessor, so addressing a row goes through the byte slice.
fn gray_row_mut(mask: &mut Gray8, y: u32) -> &mut [u8] {
    let width = mask.width() as usize;
    let start = y as usize * width;
    &mut mask.pixels_mut()[start..start + width]
}

/// Two feathered edges together spread a little less than their sum, as blurs do.
pub fn stacked_feather(current: f64, amount: f64) -> f64 {
    if !current.is_finite() || current <= 0.0 {
        return amount.clamp(0.0, MAX_FEATHER);
    }
    if !amount.is_finite() || amount <= 0.0 {
        return current.clamp(0.0, MAX_FEATHER);
    }
    (current * current + amount * amount).sqrt().clamp(0.0, MAX_FEATHER)
}

/// Adds the horizontal coverage of `[x0, x1)` to one row of a shape, scaled by `weight`.
fn accumulate_span(row: &mut [f64], width: u32, x0: f64, x1: f64, weight: f64) {
    let x0 = x0.max(0.0);
    let x1 = x1.min(width as f64);
    if x1 <= x0 {
        return;
    }
    let first = x0.floor() as usize;
    let last = (x1.ceil() as usize).min(width as usize);
    for (x, value) in row.iter_mut().enumerate().take(last).skip(first) {
        let left = (x as f64).max(x0);
        let right = ((x + 1) as f64).min(x1);
        if right > left {
            *value += (right - left) * weight;
        }
    }
}

/// Spans of a closed polygon at scan line `sy`, by nonzero winding.
fn polygon_spans(points: &[PointF], sy: f64, out: &mut Vec<(f64, f64)>) {
    let mut crossings: Vec<(f64, i32)> = Vec::with_capacity(points.len());
    for index in 0..points.len() {
        let a = points[index];
        let b = points[(index + 1) % points.len()];
        let upward = b.y > a.y;
        let crosses = if upward { a.y <= sy && b.y > sy } else { b.y <= sy && a.y > sy };
        if !crosses {
            continue;
        }
        let t = (sy - a.y) / (b.y - a.y);
        crossings.push((a.x + t * (b.x - a.x), if upward { 1 } else { -1 }));
    }
    crossings.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
    let mut winding = 0;
    let mut start = 0.0;
    for (x, direction) in crossings {
        let before = winding;
        winding += direction;
        if before == 0 && winding != 0 {
            start = x;
        } else if before != 0 && winding == 0 {
            out.push((start, x));
        }
    }
}

/// Coverage in 0-255: rounded when antialiased, thresholded at half a pixel when not.
fn finalize(value: f64, antialiased: bool) -> f64 {
    if antialiased {
        (value * 255.0).round().clamp(0.0, 255.0) / 255.0
    } else if value >= 0.5 {
        1.0
    } else {
        0.0
    }
}

fn mask_from_values(width: u32, height: u32, values: &[f64]) -> Gray8 {
    let mut bytes = vec![0u8; values.len()];
    for (index, value) in values.iter().enumerate() {
        bytes[index] = (value * 255.0).round().clamp(0.0, 255.0) as u8;
    }
    Gray8::from_raw(width, height, bytes).expect("values match the mask size")
}

/// Separable Gaussian with a normalized kernel and clamped edges: a uniform field stays
/// exactly uniform, which is what keeps feathering energy-preserving.
fn gaussian_blur(mask: &Gray8, sigma: f64) -> Gray8 {
    let width = mask.width();
    let height = mask.height();
    if width == 0 || height == 0 || sigma <= 0.0 {
        return mask.clone();
    }
    let radius = (sigma * 3.0).ceil().max(1.0) as i64;
    let mut kernel = Vec::with_capacity((radius * 2 + 1) as usize);
    let mut sum = 0.0;
    for offset in -radius..=radius {
        let value = (-(offset as f64).powi(2) / (2.0 * sigma * sigma)).exp();
        kernel.push(value);
        sum += value;
    }
    for value in kernel.iter_mut() {
        *value /= sum;
    }
    // Both passes touch one row at a time and read only the other buffer, so they parallelize
    // without any accumulation order to preserve.
    let mut horizontal = vec![0f64; width as usize * height as usize];
    horizontal
        .par_chunks_mut(width as usize)
        .enumerate()
        .for_each(|(y, row)| {
            let source = mask.row(y as u32);
            for (x, slot) in row.iter_mut().enumerate() {
                let mut total = 0.0;
                for (index, weight) in kernel.iter().enumerate() {
                    let sx = (x as i64 + index as i64 - radius).clamp(0, width as i64 - 1) as usize;
                    total += source[sx] as f64 * weight;
                }
                *slot = total;
            }
        });
    let mut bytes = vec![0u8; width as usize * height as usize];
    bytes
        .par_chunks_mut(width as usize)
        .enumerate()
        .for_each(|(y, row)| {
            for (x, slot) in row.iter_mut().enumerate() {
                let mut total = 0.0;
                for (index, weight) in kernel.iter().enumerate() {
                    let sy = (y as i64 + index as i64 - radius).clamp(0, height as i64 - 1) as usize;
                    total += horizontal[sy * width as usize + x] * weight;
                }
                *slot = total.round().clamp(0.0, 255.0) as u8;
            }
        });
    Gray8::from_raw(width, height, bytes).expect("blur keeps the mask size")
}

/// Distance from every pixel to the nearest `true` pixel, by the exact Euclidean transform of
/// Felzenszwalb and Huttenlocher: a squared distance along rows, then along columns.
fn distance_field(sites: &[bool], width: u32, height: u32) -> Vec<f64> {
    const FAR: f64 = 1.0e12;
    let w = width as usize;
    let h = height as usize;
    let mut grid = vec![0f64; w * h];
    for y in 0..h {
        let mut row = vec![FAR; w];
        for x in 0..w {
            if sites[y * w + x] {
                row[x] = 0.0;
            }
        }
        let mut transformed = vec![0f64; w];
        transform_line(&row, &mut transformed);
        grid[y * w..y * w + w].copy_from_slice(&transformed);
    }
    let mut result = vec![0f64; w * h];
    let mut column = vec![0f64; h];
    let mut transformed = vec![0f64; h];
    for x in 0..w {
        for y in 0..h {
            column[y] = grid[y * w + x];
        }
        transform_line(&column, &mut transformed);
        for y in 0..h {
            result[y * w + x] = transformed[y];
        }
    }
    result
}

/// The lower envelope of the parabolas `(q - v)^2 + f[v]`: the exact 1D squared distance.
fn transform_line(f: &[f64], out: &mut [f64]) {
    let n = f.len();
    if n == 0 {
        return;
    }
    let mut v = vec![0usize; n];
    let mut z = vec![0f64; n + 1];
    let mut k = 0usize;
    v[0] = 0;
    z[0] = f64::NEG_INFINITY;
    z[1] = f64::INFINITY;
    for q in 1..n {
        let mut s = ((f[q] + (q * q) as f64) - (f[v[k]] + (v[k] * v[k]) as f64)) / (2.0 * q as f64 - 2.0 * v[k] as f64);
        while s <= z[k] {
            k -= 1;
            s = ((f[q] + (q * q) as f64) - (f[v[k]] + (v[k] * v[k]) as f64)) / (2.0 * q as f64 - 2.0 * v[k] as f64);
        }
        k += 1;
        v[k] = q;
        z[k] = s;
        z[k + 1] = f64::INFINITY;
    }
    let mut k = 0usize;
    for q in 0..n {
        while z[k + 1] < q as f64 {
            k += 1;
        }
        let distance = (q as f64 - v[k] as f64).abs();
        out[q] = distance * distance + f[v[k]];
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn point(x: f64, y: f64) -> PointF {
        PointF::new(x, y)
    }

    fn rect(x: f64, y: f64, width: f64, height: f64) -> RectF {
        RectF::new(x, y, width, height)
    }

    #[test]
    fn a_rectangle_selects_exactly_its_area() {
        let selection = Selection::rect(32, 32, rect(2.0, 3.0, 10.0, 4.0), true);
        assert_eq!(selection.bounds(), Some((2, 3, 10, 4)));
        assert!((selection.area() - 40.0).abs() < 1e-9);
        assert_eq!(selection.coverage(2, 3), 255);
        assert_eq!(selection.coverage(11, 6), 255);
        assert_eq!(selection.coverage(12, 6), 0);
        assert_eq!(selection.coverage(1, 3), 0);
        assert!(!selection.is_empty() && !selection.is_all());
        // A shape that runs off the canvas is clipped to it.
        let clipped = Selection::rect(8, 8, rect(4.0, 4.0, 20.0, 20.0), true);
        assert_eq!(clipped.bounds(), Some((4, 4, 4, 4)));
        assert!((clipped.area() - 16.0).abs() < 1e-9);
    }

    #[test]
    fn a_non_antialiased_shape_snaps_to_whole_pixels() {
        for antialiased in [true, false] {
            let selection = Selection::rect(8, 8, rect(1.0, 2.0, 3.0, 4.0), antialiased);
            for y in 0..8 {
                for x in 0..8 {
                    let expected = (1..4).contains(&x) && (2..6).contains(&y);
                    assert_eq!(selection.coverage(x, y), if expected { 255 } else { 0 }, "at {x},{y}");
                }
            }
        }
    }

    #[test]
    fn an_ellipse_covers_pi_ab() {
        let selection = Selection::ellipse(64, 64, rect(2.0, 2.0, 40.0, 20.0), true);
        let expected = std::f64::consts::PI * 20.0 * 10.0;
        assert!((selection.area() - expected).abs() / expected < 0.02, "area {}", selection.area());
        assert_eq!(selection.coverage(22, 12), 255);
        assert_eq!(selection.coverage(1, 1), 0);
        assert_eq!(selection.coverage(22, 1), 0);
        assert!(!selection.is_empty());
    }

    #[test]
    fn a_lasso_closes_its_outline() {
        let triangle = [point(2.0, 2.0), point(12.0, 2.0), point(7.0, 12.0)];
        let selection = Selection::lasso(16, 16, &triangle, true);
        assert!((selection.area() - 50.0).abs() < 2.0, "area {}", selection.area());
        assert_eq!(selection.coverage(7, 4), 255);
        assert_eq!(selection.coverage(0, 0), 0);
        assert_eq!(selection.coverage(15, 15), 0);
        // A self-intersecting outline fills by nonzero winding, never everything.
        let bowtie = [point(1.0, 1.0), point(10.0, 10.0), point(10.0, 1.0), point(1.0, 10.0)];
        let wound = Selection::lasso(16, 16, &bowtie, true);
        assert!(wound.area() > 0.0 && wound.area() < 16.0 * 16.0 / 2.0);
        // Fewer than three points enclose nothing.
        assert!(Selection::lasso(16, 16, &[point(1.0, 1.0), point(5.0, 5.0)], true).is_empty());
    }

    #[test]
    fn boolean_operations_follow_the_coverage_boundaries() {
        let a = Selection::rect(16, 16, rect(0.0, 0.0, 8.0, 8.0), false);
        let b = Selection::rect(16, 16, rect(4.0, 4.0, 8.0, 8.0), false);
        let union = a.union(&b).expect("union");
        assert_eq!(union.area(), 112.0);
        assert_eq!(union.coverage(0, 0), 255);
        assert_eq!(union.coverage(11, 11), 255);
        assert_eq!(union.coverage(12, 12), 0);
        assert_eq!(union.coverage(7, 0), 255);
        assert_eq!(union.coverage(8, 0), 0);
        assert_eq!(union.coverage(4, 4), 255);
        let intersection = a.intersection(&b).expect("intersection");
        assert_eq!(intersection.area(), 16.0);
        assert_eq!(intersection.bounds(), Some((4, 4, 4, 4)));
        assert_eq!(intersection.coverage(4, 4), 255);
        assert_eq!(intersection.coverage(3, 3), 0);
        let difference = a.difference(&b).expect("difference");
        assert_eq!(difference.area(), 48.0);
        assert_eq!(difference.coverage(1, 1), 255);
        assert_eq!(difference.coverage(5, 5), 0);
        assert_eq!(difference.coverage(11, 11), 0);
        // Subtracting everything from a selection leaves nothing.
        assert!(a.difference(&Selection::all(16, 16)).expect("empty").is_empty());
        // A soft edge survives a union with a shape it already covers, and subtracting the
        // hard shape leaves only the feathered fringe.
        let soft = a.feathered(3.0);
        let grown = soft.union(&a).expect("union");
        assert!(grown.area() >= soft.area() && grown.area() >= a.area());
        let reduced = soft.difference(&a).expect("difference");
        assert!(reduced.area() < soft.area());
        assert!(reduced.area() > 0.0, "the feathered fringe outside the hard shape remains");
    }

    #[test]
    fn boolean_operations_reject_a_size_mismatch() {
        let a = Selection::all(8, 8);
        let b = Selection::all(4, 4);
        assert!(a.union(&b).is_err());
        assert!(a.intersection(&b).is_err());
        assert!(a.difference(&b).is_err());
        assert!(a.clipped_bitmap(&Bitmap8::new(4, 4)).is_err());
    }

    #[test]
    fn inverting_swaps_selected_and_unselected() {
        let selection = Selection::rect(4, 4, rect(1.0, 1.0, 2.0, 2.0), false);
        let inverted = selection.inverted();
        assert_eq!(inverted.coverage(1, 1), 0);
        assert_eq!(inverted.coverage(0, 0), 255);
        assert_eq!(inverted.area(), 16.0 - selection.area());
        assert!(Selection::all(4, 4).inverted().is_empty());
        assert!(Selection::new(4, 4).inverted().is_all());
    }

    #[test]
    fn feathering_is_symmetric_about_the_edge() {
        // A bar straddling the middle of a wide canvas: its feathered profile mirrors about
        // the bar's center, pixel for pixel.
        let bar = Selection::rect(64, 16, rect(30.0, 0.0, 4.0, 16.0), false);
        let soft_bar = bar.feathered(6.0);
        for offset in 0..4 {
            assert_eq!(
                soft_bar.coverage(30 + offset, 8),
                soft_bar.coverage(33 - offset, 8),
                "bar mirror at offset {offset}"
            );
        }
        assert!(soft_bar.coverage(31, 8) > soft_bar.coverage(28, 8));
        // A step edge is antisymmetric instead: the two sides of the ramp sum to full coverage.
        let step = Selection::rect(64, 16, rect(0.0, 0.0, 32.0, 16.0), false);
        let soft_step = step.feathered(6.0);
        for offset in 1..9 {
            let left = soft_step.coverage(31 - offset, 8) as i32;
            let right = soft_step.coverage(32 + offset, 8) as i32;
            assert!((left + right - 255).abs() <= 2, "offset {offset}: {left} + {right}");
        }
        // And the ramp is monotonic across the step.
        let mut previous = 255u8;
        for x in 24..40 {
            let value = soft_step.coverage(x, 8);
            assert!(value <= previous, "not monotonic at {x}");
            previous = value;
        }
    }

    #[test]
    fn feathering_conserves_total_coverage() {
        let selection = Selection::rect(64, 16, rect(0.0, 0.0, 32.0, 16.0), false);
        let soft = selection.feathered(6.0);
        assert!((soft.area() - selection.area()).abs() < 1.0, "areas {} vs {}", soft.area(), selection.area());
        // A uniform field stays exactly uniform: the kernel is normalized and the edges clamp.
        assert!(Selection::all(16, 16).feathered(4.0).is_all());
        assert!(Selection::new(16, 16).feathered(4.0).is_empty());
        // Feathering does not move the bounds of a full-canvas selection.
        assert_eq!(Selection::all(16, 16).feathered(4.0).bounds(), Some((0, 0, 16, 16)));
    }

    #[test]
    fn expand_and_contract_move_the_edges_evenly() {
        let selection = Selection::rect(32, 32, rect(8.0, 8.0, 8.0, 8.0), false);
        assert!((selection.area() - 64.0).abs() < 1e-9);
        let grown = selection.expanded(3.0);
        assert_eq!(grown.bounds(), Some((5, 5, 14, 14)));
        assert!(grown.area() > selection.area());
        // Growing reaches into the rounded corners rather than squaring them off.
        assert_eq!(grown.coverage(5, 5), 0);
        assert!(grown.coverage(5, 10) > 0);
        let shrunk = selection.contracted(2.0);
        assert_eq!(shrunk.bounds(), Some((10, 10, 4, 4)));
        assert!(shrunk.area() < selection.area());
        // A grow then a shrink of the same size comes back to where it started.
        let round_trip = grown.contracted(3.0);
        assert_eq!(round_trip.bounds(), Some((8, 8, 8, 8)));
        // Expanding the whole canvas cannot overflow it.
        assert!(Selection::all(8, 8).expanded(4.0).is_all());
        // A zero or negative amount changes nothing.
        assert_eq!(selection.expanded(0.0), selection);
        assert_eq!(selection.contracted(-1.0), selection);
    }

    #[test]
    fn contracting_past_the_middle_leaves_nothing() {
        let selection = Selection::rect(32, 32, rect(8.0, 8.0, 8.0, 8.0), false);
        assert!(selection.contracted(64.0).is_empty());
        assert!(selection.contracted(4.0).is_empty() || selection.contracted(4.0).area() < 16.0);
        // An empty selection stays empty and cannot grow into one.
        assert!(Selection::new(16, 16).expanded(6.0).is_empty());
        assert!(Selection::new(16, 16).contracted(6.0).is_empty());
    }

    #[test]
    fn a_selection_loads_from_alpha_or_a_mask() {
        let mut image = Bitmap8::new(4, 4);
        image.set(1, 1, [9, 8, 7, 200]);
        image.set(2, 2, [9, 8, 7, 0]);
        let selection = Selection::from_alpha(&image);
        assert_eq!(selection.coverage(1, 1), 200);
        assert_eq!(selection.coverage(2, 2), 0);
        assert_eq!(selection.bounds(), Some((1, 1, 1, 1)));
        let mask = Gray8::filled(4, 4, 77);
        let loaded = Selection::from_mask(&mask);
        assert_eq!(loaded.coverage(3, 3), 77);
        assert_eq!(loaded.as_gray(), &mask);
        assert_eq!(Selection::from_gray(mask.clone()).into_gray(), mask);
    }

    #[test]
    fn clipping_cropping_filling_and_clearing_follow_the_coverage() {
        let image = Bitmap8::filled(8, 8, [10, 20, 30, 255]);
        let selection = Selection::rect(8, 8, rect(2.0, 3.0, 4.0, 2.0), false);
        let clipped = selection.clipped_bitmap(&image).expect("clip");
        assert_eq!(clipped.get(3, 3), [10, 20, 30, 255]);
        assert_eq!(clipped.get(0, 0)[3], 0);
        assert_eq!(clipped.get(7, 7)[3], 0);

        let (cropped, origin) = selection.cropped_bitmap(&image).expect("crop").expect("some");
        assert_eq!(origin, (2, 3));
        assert_eq!((cropped.width(), cropped.height()), (4, 2));
        assert_eq!(cropped.get(0, 0), [10, 20, 30, 255]);
        assert!(Selection::new(8, 8).cropped_bitmap(&image).expect("crop").is_none());

        let mut cleared = image.clone();
        selection.clear_bitmap(&mut cleared).expect("clear");
        assert_eq!(cleared.get(3, 3)[3], 0);
        assert_eq!(cleared.get(0, 0)[3], 255);

        let mut filled = image.clone();
        selection.fill_bitmap(&mut filled, [255, 0, 0, 255]).expect("fill");
        assert_eq!(filled.get(3, 3), [255, 0, 0, 255]);
        assert_eq!(filled.get(0, 0), [10, 20, 30, 255]);

        // A half-covered pixel takes half the fill.
        let mut half = Gray8::new(4, 4);
        half.set(1, 1, 128);
        let mut target = Bitmap8::new(4, 4);
        Selection::from_mask(&half).fill_bitmap(&mut target, [255, 255, 255, 255]).expect("fill");
        assert_eq!(target.get(1, 1)[3], 128);
        assert_eq!(target.get(0, 0)[3], 0);
    }

    #[test]
    fn stacked_feathering_adds_in_quadrature_and_caps() {
        assert!((stacked_feather(3.0, 4.0) - 5.0).abs() < 1e-9);
        assert_eq!(stacked_feather(0.0, 4.0), 4.0);
        assert_eq!(stacked_feather(4.0, 0.0), 4.0);
        assert_eq!(stacked_feather(200.0, 200.0), MAX_FEATHER);
        assert_eq!(stacked_feather(f64::NAN, 7.0), 7.0);
    }

    #[test]
    fn a_transformed_selection_follows_its_pixels() {
        let selection = Selection::rect(16, 16, rect(2.0, 2.0, 4.0, 4.0), false);
        let moved = selection.transformed(&Affine::translation(4.0, 0.0), Sampling::Nearest).expect("transform");
        assert_eq!(moved.bounds(), Some((6, 2, 4, 4)));
    }
}
