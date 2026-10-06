//! Affine and perspective resampling for pixels and masks, plus the alignment snapping the
//! Move and Crop tools share.
//!
//! Sampling follows the macOS behavior: a transformed image fades to transparent outside its
//! source rather than smearing its edge, interpolation happens in premultiplied space so
//! transparent pixels never darken a border, and the mapping is inverted per output pixel so
//! every destination pixel is written exactly once.

use comp_core::limits;
use comp_core::{Affine, Bitmap8, Document, Error, Gray8, Guide, GuideAxis, PointF, RectF, Result, Sampling, Transform};
use rayon::prelude::*;

/// Catmull-Rom cubic kernel, the standard stand-in for Core Graphics' high-quality filter.
fn cubic(t: f64) -> f64 {
    let t = t.abs();
    if t < 1.0 {
        1.5 * t * t * t - 2.5 * t * t + 1.0
    } else if t < 2.0 {
        -0.5 * t * t * t + 2.5 * t * t - 4.0 * t + 2.0
    } else {
        0.0
    }
}

/// True when the sample point lies inside the image's own extent. Coordinates are in pixel
/// index space, so the image covers [-0.5, width - 0.5].
fn inside(width: u32, height: u32, x: f64, y: f64) -> bool {
    x >= -0.5 && y >= -0.5 && x <= width as f64 - 0.5 && y <= height as f64 - 0.5
}

/// One pixel of an RGBA raster, sampled in pixel-index space: an integer coordinate is a
/// pixel center, exactly like the coordinates inside `Bitmap8::resized_bilinear`.
///
/// A sample inside the image clamps to the edge pixel, so scaling up does not eat a
/// half-transparent border out of an opaque image. A sample outside the image is transparent,
/// so a rotated layer fades to nothing instead of smearing its edge across the canvas.
pub fn sample(image: &Bitmap8, x: f64, y: f64, sampling: Sampling) -> [u8; 4] {
    if !x.is_finite() || !y.is_finite() || image.is_empty() || !inside(image.width(), image.height(), x, y) {
        return [0, 0, 0, 0];
    }
    let cx = x.clamp(0.0, image.width() as f64 - 1.0);
    let cy = y.clamp(0.0, image.height() as f64 - 1.0);
    let width = image.width() as i64;
    let height = image.height() as i64;
    if sampling == Sampling::Nearest {
        return image.get(cx.round() as u32, cy.round() as u32);
    }
    let mut acc = [0.0f64; 4];
    let mut total_alpha = 0.0;
    let (taps_x, taps_y);
    if sampling == Sampling::HighQuality {
        let x0 = cx.floor() as i64 - 1;
        let y0 = cy.floor() as i64 - 1;
        taps_x = (0..4).map(|i| ((x0 + i).clamp(0, width - 1), cubic(cx - (x0 + i) as f64))).collect::<Vec<_>>();
        taps_y = (0..4).map(|i| ((y0 + i).clamp(0, height - 1), cubic(cy - (y0 + i) as f64))).collect::<Vec<_>>();
    } else {
        let x0 = cx.floor() as i64;
        let y0 = cy.floor() as i64;
        let wx = cx - x0 as f64;
        let wy = cy - y0 as f64;
        taps_x = vec![(x0, 1.0 - wx), ((x0 + 1).min(width - 1), wx)];
        taps_y = vec![(y0, 1.0 - wy), ((y0 + 1).min(height - 1), wy)];
    }
    for (ix, wx) in &taps_x {
        if *wx == 0.0 {
            continue;
        }
        for (iy, wy) in &taps_y {
            if *wy == 0.0 {
                continue;
            }
            let weight = wx * wy;
            let pixel = image.get(*ix as u32, *iy as u32);
            let alpha = pixel[3] as f64 / 255.0;
            for channel in 0..3 {
                acc[channel] += pixel[channel] as f64 * alpha * weight;
            }
            total_alpha += alpha * weight;
        }
    }
    if total_alpha <= 0.0 {
        return [0, 0, 0, 0];
    }
    let mut out = [0u8; 4];
    for channel in 0..3 {
        out[channel] = (acc[channel] / total_alpha).round().clamp(0.0, 255.0) as u8;
    }
    out[3] = (total_alpha * 255.0).round().clamp(0.0, 255.0) as u8;
    out
}

/// One pixel of a coverage mask, sampled in pixel-index space, with the same inside/outside
/// rule as @sample@.
pub fn sample_mask(mask: &Gray8, x: f64, y: f64, sampling: Sampling) -> u8 {
    if !x.is_finite() || !y.is_finite() || mask.is_empty() || !inside(mask.width(), mask.height(), x, y) {
        return 0;
    }
    let cx = x.clamp(0.0, mask.width() as f64 - 1.0);
    let cy = y.clamp(0.0, mask.height() as f64 - 1.0);
    let width = mask.width() as i64;
    let height = mask.height() as i64;
    if sampling == Sampling::Nearest {
        return mask.get(cx.round() as u32, cy.round() as u32);
    }
    // Coverage is a single channel, so plain bilinear over an edge-clamped background is enough.
    let x0 = cx.floor() as i64;
    let y0 = cy.floor() as i64;
    let wx = cx - x0 as f64;
    let wy = cy - y0 as f64;
    let mut total = 0.0;
    for (ix, weight_x) in [(x0, 1.0 - wx), ((x0 + 1).min(width - 1), wx)] {
        if weight_x == 0.0 {
            continue;
        }
        for (iy, weight_y) in [(y0, 1.0 - wy), ((y0 + 1).min(height - 1), wy)] {
            if weight_y == 0.0 {
                continue;
            }
            total += mask.get(ix as u32, iy as u32) as f64 * weight_x * weight_y;
        }
    }
    total.round().clamp(0.0, 255.0) as u8
}

fn output_bounds(bounds: RectF) -> Result<(f64, f64, u32, u32)> {
    if !bounds.is_finite() || bounds.width <= 0.0 || bounds.height <= 0.0 {
        return Err(Error::Invalid);
    }
    let x0 = bounds.x.floor();
    let y0 = bounds.y.floor();
    let x1 = bounds.max_x().ceil();
    let y1 = bounds.max_y().ceil();
    if x1 <= x0 || y1 <= y0 {
        return Err(Error::Invalid);
    }
    let width = (x1 - x0).round() as i64;
    let height = (y1 - y0).round() as i64;
    if width > u32::MAX as i64 || height > u32::MAX as i64 {
        return Err(Error::TooLarge("transformed image is too large".into()));
    }
    let (width, height) = (width as u32, height as u32);
    if !limits::surface_fits(width, height) {
        return Err(Error::TooLarge(format!("transformed bounds {width}x{height} exceed a supported surface")));
    }
    Ok((x0, y0, width, height))
}

/// Resamples a raster through an affine map. The result covers the mapped source's whole-pixel
/// bounds, so a rotation grows the canvas rectangle rather than clipping the corners.
pub fn transform_bitmap(image: &Bitmap8, affine: &Affine, sampling: Sampling) -> Result<Bitmap8> {
    let inverse = affine.inverse().ok_or(Error::Invalid)?;
    let bounds = affine.bounding_box(image.width() as f64, image.height() as f64);
    let (x0, y0, width, height) = output_bounds(bounds)?;
    let mut out = Bitmap8::new(width, height);
    // Output rows are independent, so a wide resample spreads across the cores.
    let row_bytes = width as usize * 4;
    out.pixels_mut()
        .par_chunks_mut(row_bytes)
        .enumerate()
        .for_each(|(oy, row)| {
            for ox in 0..width {
                let source = inverse.apply(PointF::new(x0 + ox as f64 + 0.5, y0 + oy as f64 + 0.5));
                let rgba = sample(image, source.x - 0.5, source.y - 0.5, sampling);
                let offset = ox as usize * 4;
                row[offset..offset + 4].copy_from_slice(&rgba);
            }
        });
    Ok(out)
}

/// Resamples a coverage mask through an affine map, sized like `transform_bitmap`.
pub fn transform_mask(mask: &Gray8, affine: &Affine, sampling: Sampling) -> Result<Gray8> {
    let inverse = affine.inverse().ok_or(Error::Invalid)?;
    let bounds = affine.bounding_box(mask.width() as f64, mask.height() as f64);
    let (x0, y0, width, height) = output_bounds(bounds)?;
    let mut out = Gray8::new(width, height);
    out.pixels_mut()
        .par_chunks_mut(width as usize)
        .enumerate()
        .for_each(|(oy, row)| {
            for (ox, slot) in row.iter_mut().enumerate() {
                let source = inverse.apply(PointF::new(x0 + ox as f64 + 0.5, y0 + oy as f64 + 0.5));
                *slot = sample_mask(mask, source.x - 0.5, source.y - 0.5, sampling);
            }
        });
    Ok(out)
}

/// Resamples a raster through an affine map into a fixed-size canvas: the frame a layer needs
/// when transformed pixels move but the canvas does not.
pub fn resample_bitmap(image: &Bitmap8, width: u32, height: u32, affine: &Affine, sampling: Sampling) -> Result<Bitmap8> {
    let inverse = affine.inverse().ok_or(Error::Invalid)?;
    if !limits::surface_fits(width, height) {
        return Err(Error::TooLarge(format!("resampled surface {width}x{height} is not supported")));
    }
    let mut out = Bitmap8::new(width, height);
    let row_bytes = width as usize * 4;
    out.pixels_mut()
        .par_chunks_mut(row_bytes)
        .enumerate()
        .for_each(|(oy, row)| {
            for ox in 0..width {
                let source = inverse.apply(PointF::new(ox as f64 + 0.5, oy as f64 + 0.5));
                let rgba = sample(image, source.x - 0.5, source.y - 0.5, sampling);
                let offset = ox as usize * 4;
                row[offset..offset + 4].copy_from_slice(&rgba);
            }
        });
    Ok(out)
}

/// Resamples a coverage mask through an affine map into a fixed-size canvas.
pub fn resample_mask(mask: &Gray8, width: u32, height: u32, affine: &Affine, sampling: Sampling) -> Result<Gray8> {
    let inverse = affine.inverse().ok_or(Error::Invalid)?;
    if !limits::surface_fits(width, height) {
        return Err(Error::TooLarge(format!("resampled surface {width}x{height} is not supported")));
    }
    let mut out = Gray8::new(width, height);
    out.pixels_mut()
        .par_chunks_mut(width as usize)
        .enumerate()
        .for_each(|(oy, row)| {
            for (ox, slot) in row.iter_mut().enumerate() {
                let source = inverse.apply(PointF::new(ox as f64 + 0.5, oy as f64 + 0.5));
                *slot = sample_mask(mask, source.x - 0.5, source.y - 0.5, sampling);
            }
        });
    Ok(out)
}

/// The perspective map from the unit square onto a quad, in top-left, top-right,
/// bottom-right, bottom-left order: the macOS `DistortWarp.homography`.
fn homography(corners: &[PointF; 4]) -> [[f64; 3]; 3] {
    let sx = corners[0].x - corners[1].x + corners[2].x - corners[3].x;
    let sy = corners[0].y - corners[1].y + corners[2].y - corners[3].y;
    let mut g = 0.0;
    let mut h = 0.0;
    if sx.abs() > 1e-9 || sy.abs() > 1e-9 {
        let dx1 = corners[1].x - corners[2].x;
        let dx2 = corners[3].x - corners[2].x;
        let dy1 = corners[1].y - corners[2].y;
        let dy2 = corners[3].y - corners[2].y;
        let den = dx1 * dy2 - dx2 * dy1;
        if den.abs() > 1e-12 {
            g = (sx * dy2 - dx2 * sy) / den;
            h = (dx1 * sy - sx * dy1) / den;
        }
    }
    let a = corners[1].x - corners[0].x + g * corners[1].x;
    let b = corners[3].x - corners[0].x + h * corners[3].x;
    let d = corners[1].y - corners[0].y + g * corners[1].y;
    let e = corners[3].y - corners[0].y + h * corners[3].y;
    [[a, b, corners[0].x], [d, e, corners[0].y], [g, h, 1.0]]
}

fn invert3(m: [[f64; 3]; 3]) -> Option<[[f64; 3]; 3]> {
    let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
        - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
        + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    if det.abs() < 1e-12 || !det.is_finite() {
        return None;
    }
    let mut out = [[0.0f64; 3]; 3];
    out[0][0] = (m[1][1] * m[2][2] - m[1][2] * m[2][1]) / det;
    out[0][1] = (m[0][2] * m[2][1] - m[0][1] * m[2][2]) / det;
    out[0][2] = (m[0][1] * m[1][2] - m[0][2] * m[1][1]) / det;
    out[1][0] = (m[1][2] * m[2][0] - m[1][0] * m[2][2]) / det;
    out[1][1] = (m[0][0] * m[2][2] - m[0][2] * m[2][0]) / det;
    out[1][2] = (m[0][2] * m[1][0] - m[0][0] * m[1][2]) / det;
    out[2][0] = (m[1][0] * m[2][1] - m[1][1] * m[2][0]) / det;
    out[2][1] = (m[0][1] * m[2][0] - m[0][0] * m[2][1]) / det;
    out[2][2] = (m[0][0] * m[1][1] - m[0][1] * m[1][0]) / det;
    Some(out)
}

fn apply3(m: &[[f64; 3]; 3], x: f64, y: f64) -> Option<PointF> {
    let u = m[0][0] * x + m[0][1] * y + m[0][2];
    let v = m[1][0] * x + m[1][1] * y + m[1][2];
    let w = m[2][0] * x + m[2][1] * y + m[2][2];
    if w.abs() < 1e-12 {
        return None;
    }
    Some(PointF::new(u / w, v / w))
}

/// True when the quad is convex and usable: a perspective warp can take the image to it.
pub fn is_convex_quad(corners: &[PointF; 4]) -> bool {
    if corners.iter().any(|p| !p.is_finite()) {
        return false;
    }
    let mut sign = 0.0;
    for index in 0..4 {
        let a = corners[index];
        let b = corners[(index + 1) % 4];
        let c = corners[(index + 2) % 4];
        let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
        if cross.abs() <= 0.01 {
            return false;
        }
        if sign == 0.0 {
            sign = if cross < 0.0 { -1.0 } else { 1.0 };
        } else if (cross < 0.0) != (sign < 0.0) {
            return false;
        }
    }
    true
}

/// Barycentric weights of `p` against the triangle `a, b, c`, or nil for a degenerate triangle.
fn barycentric(p: PointF, a: PointF, b: PointF, c: PointF) -> Option<(f64, f64, f64)> {
    let denom = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y);
    if denom.abs() < 1e-12 {
        return None;
    }
    let w0 = ((b.y - c.y) * (p.x - c.x) + (c.x - b.x) * (p.y - c.y)) / denom;
    let w1 = ((c.y - a.y) * (p.x - c.x) + (a.x - c.x) * (p.y - c.y)) / denom;
    Some((w0, w1, 1.0 - w0 - w1))
}

/// Free distortion (Cmd-drag a transform handle): the image's four corners move
/// independently. A convex shape is warped in perspective; a folded one is taken to its shape
/// as two triangles along its diagonal, which no single perspective can express.
pub fn warp_perspective(image: &Bitmap8, corners: &[PointF; 4], sampling: Sampling) -> Result<Bitmap8> {
    if image.is_empty() {
        return Err(Error::Invalid);
    }
    let xs = corners.iter().map(|p| p.x);
    let ys = corners.iter().map(|p| p.y);
    let bounds = RectF::new(
        xs.clone().fold(f64::INFINITY, f64::min),
        ys.clone().fold(f64::INFINITY, f64::min),
        0.0,
        0.0,
    );
    let max_x = xs.fold(f64::NEG_INFINITY, f64::max);
    let max_y = ys.fold(f64::NEG_INFINITY, f64::max);
    let bounds = RectF::new(bounds.x, bounds.y, max_x - bounds.x, max_y - bounds.y);
    let (x0, y0, width, height) = output_bounds(bounds)?;
    let source_width = image.width() as f64;
    let source_height = image.height() as f64;
    let mut out = Bitmap8::new(width, height);
    let perspective = if is_convex_quad(corners) { invert3(homography(corners)) } else { None };
    // Unit-square corners of the two halves, matching the destination triangles.
    let halves = [
        ([PointF::new(0.0, 0.0), PointF::new(1.0, 0.0), PointF::new(1.0, 1.0)], [corners[0], corners[1], corners[2]]),
        ([PointF::new(0.0, 0.0), PointF::new(1.0, 1.0), PointF::new(0.0, 1.0)], [corners[0], corners[2], corners[3]]),
    ];
    for oy in 0..height {
        for ox in 0..width {
            let target = PointF::new(x0 + ox as f64 + 0.5, y0 + oy as f64 + 0.5);
            let unit = match &perspective {
                Some(matrix) => match apply3(matrix, target.x, target.y) {
                    Some(unit) => Some(unit),
                    None => continue,
                },
                None => {
                    let mut found = None;
                    for (unit_corners, target_corners) in &halves {
                        let Some((w0, w1, w2)) = barycentric(target, target_corners[0], target_corners[1], target_corners[2])
                        else {
                            continue;
                        };
                        if w0 < -1e-9 || w1 < -1e-9 || w2 < -1e-9 {
                            continue;
                        }
                        found = Some(PointF::new(
                            w0 * unit_corners[0].x + w1 * unit_corners[1].x + w2 * unit_corners[2].x,
                            w0 * unit_corners[0].y + w1 * unit_corners[1].y + w2 * unit_corners[2].y,
                        ));
                        break;
                    }
                    found
                }
            };
            let Some(unit) = unit else { continue };
            // Outside the unit square the sample is transparent anyway; the sampler handles it.
            let rgba = sample(image, unit.x * source_width - 0.5, unit.y * source_height - 0.5, sampling);
            if rgba[3] != 0 {
                out.set(ox, oy, rgba);
            }
        }
    }
    Ok(out)
}

/// A non-printing layout grid: a major line every `spacing` pixels, split into `subdivisions`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LayoutGrid {
    pub spacing: u32,
    pub subdivisions: u32,
}

impl Default for LayoutGrid {
    fn default() -> Self {
        LayoutGrid { spacing: 64, subdivisions: 8 }
    }
}

impl LayoutGrid {
    pub fn new(spacing: u32, subdivisions: u32) -> Self {
        let spacing = spacing.clamp(2, 4096);
        LayoutGrid { spacing, subdivisions: subdivisions.clamp(1, 64).min(spacing) }
    }

    pub fn step(&self) -> f64 {
        self.spacing as f64 / self.subdivisions as f64
    }

    /// Every grid line along one document edge, in whole pixels. Counted from the origin
    /// rather than accumulated, so an uneven step never drifts off the majors.
    pub fn lines(&self, along: f64) -> Vec<f64> {
        if !(along >= 0.0) {
            return vec![0.0];
        }
        let count = (along / self.step() + 0.001).floor();
        if count < 0.0 || count > 1_000_000.0 {
            return vec![0.0];
        }
        (0..=count as u64).map(|index| (index as f64 * self.step()).round()).collect()
    }

    pub fn is_major(&self, value: f64) -> bool {
        (value.round() % self.spacing as f64).abs() < 0.001
    }
}

/// Document lines a move or a transform snaps to.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SnapTargets {
    pub xs: Vec<f64>,
    pub ys: Vec<f64>,
}

impl SnapTargets {
    pub fn new() -> Self {
        SnapTargets::default()
    }

    /// The canvas edges, and its center when the tool snaps to centers.
    pub fn canvas(width: u32, height: u32, include_centers: bool) -> Self {
        let mut targets = SnapTargets::new();
        targets.xs.extend([0.0, width as f64]);
        targets.ys.extend([0.0, height as f64]);
        if include_centers {
            targets.xs.push(width as f64 / 2.0);
            targets.ys.push(height as f64 / 2.0);
        }
        targets
    }

    /// Canvas edges, guides and every layer's bounds: what View > Snap may pull against.
    pub fn from_document(document: &Document, include_centers: bool) -> Self {
        let mut targets = SnapTargets::canvas(document.width, document.height, include_centers);
        for guide in &document.guides {
            targets.push_guide(guide);
        }
        for layer in &document.layers {
            if layer.has_pixels() {
                targets.push_rect(layer.transform.document_bounds(), include_centers);
            }
        }
        targets
    }

    pub fn push_guide(&mut self, guide: &Guide) {
        match guide.axis {
            GuideAxis::Vertical => self.xs.push(guide.position),
            GuideAxis::Horizontal => self.ys.push(guide.position),
        }
    }

    pub fn push_rect(&mut self, bounds: RectF, include_centers: bool) {
        if !bounds.is_finite() {
            return;
        }
        if include_centers {
            self.xs.push(bounds.x.round());
            self.xs.push((bounds.x + bounds.width / 2.0).round());
            self.xs.push(bounds.max_x().round());
            self.ys.push(bounds.y.round());
            self.ys.push((bounds.y + bounds.height / 2.0).round());
            self.ys.push(bounds.max_y().round());
        } else {
            self.xs.push(bounds.x.round());
            self.xs.push(bounds.max_x().round());
            self.ys.push(bounds.y.round());
            self.ys.push(bounds.max_y().round());
        }
    }

    pub fn push_layer(&mut self, transform: &Transform, include_centers: bool) {
        self.push_rect(transform.document_bounds(), include_centers);
    }

    pub fn push_grid(&mut self, grid: &LayoutGrid, width: u32, height: u32) {
        self.xs.extend(grid.lines(width as f64));
        self.ys.extend(grid.lines(height as f64));
    }
}

/// What a snap moved, and the targets it landed on, so the UI can draw the alignment lines.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct SnapResult {
    pub offset: PointF,
    pub x: Option<f64>,
    pub y: Option<f64>,
}

/// The nearest target within `tolerance`, or nil. Ties keep the earlier target, as the macOS
/// `TransformSnap.shift` does.
pub fn snap_value(value: f64, targets: &[f64], tolerance: f64) -> Option<f64> {
    let mut best: Option<f64> = None;
    for target in targets {
        if !target.is_finite() {
            continue;
        }
        let move_distance = (target - value).abs();
        if move_distance > tolerance {
            continue;
        }
        if let Some(current) = best {
            if (current - value).abs() <= move_distance {
                continue;
            }
        }
        best = Some(*target);
    }
    best
}

/// Moves `point` onto the nearest target on each axis, independently.
pub fn snap_point(point: PointF, targets: &SnapTargets, tolerance: f64) -> (PointF, Option<f64>, Option<f64>) {
    if tolerance <= 0.0 || !tolerance.is_finite() {
        return (point, None, None);
    }
    let x = snap_value(point.x, &targets.xs, tolerance);
    let y = snap_value(point.y, &targets.ys, tolerance);
    (PointF::new(x.unwrap_or(point.x), y.unwrap_or(point.y)), x, y)
}

/// Moves `box` so that whichever of its left, center or right edges lands nearest an x target
/// does, and the same vertically: each axis on its own, and only within `tolerance`.
pub fn snap_offset(box_: RectF, targets: &SnapTargets, tolerance: f64) -> SnapResult {
    if tolerance <= 0.0 || !tolerance.is_finite() || !box_.is_finite() {
        return SnapResult::default();
    }
    let horizontal = shift_axis(&[box_.x, box_.x + box_.width / 2.0, box_.max_x()], &targets.xs, tolerance);
    let vertical = shift_axis(&[box_.y, box_.y + box_.height / 2.0, box_.max_y()], &targets.ys, tolerance);
    SnapResult { offset: PointF::new(horizontal.0, vertical.0), x: horizontal.1, y: vertical.1 }
}

/// The smallest move that puts one of `edges` on one of `targets`, and the target it met.
fn shift_axis(edges: &[f64], targets: &[f64], tolerance: f64) -> (f64, Option<f64>) {
    let mut best: Option<(f64, f64)> = None;
    for edge in edges {
        for target in targets {
            if !edge.is_finite() || !target.is_finite() {
                continue;
            }
            let movement = target - edge;
            if movement.abs() > tolerance {
                continue;
            }
            if let Some(current) = best {
                if current.0.abs() <= movement.abs() {
                    continue;
                }
            }
            best = Some((movement, *target));
        }
    }
    match best {
        Some((movement, target)) => (movement, Some(target)),
        None => (0.0, None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use comp_core::Layer;
    use uuid::Uuid;

    fn point(x: f64, y: f64) -> PointF {
        PointF::new(x, y)
    }

    fn dot() -> Bitmap8 {
        let mut image = Bitmap8::new(6, 6);
        image.set(1, 1, [10, 20, 30, 255]);
        image
    }

    #[test]
    fn a_translation_lands_pixel_exact() {
        for sampling in [Sampling::Nearest, Sampling::Smooth, Sampling::HighQuality] {
            let moved = transform_bitmap(&dot(), &Affine::translation(2.0, 3.0), sampling).expect("translate");
            // The result is the mapped image in its own frame: the frame origin moved by
            // (2, 3), so the dot still sits at pixel (1, 1) inside it.
            assert_eq!((moved.width(), moved.height()), (6, 6));
            assert_eq!(moved.get(1, 1), [10, 20, 30, 255], "{sampling:?}");
            assert_eq!(moved.get(0, 0)[3], 0);
            assert_eq!(moved.get(3, 4)[3], 0);
        }
    }

    #[test]
    fn a_quarter_turn_moves_pixels_exactly() {
        let turned = transform_bitmap(&dot(), &Affine::rotation(90.0), Sampling::Nearest).expect("rotate");
        // Rotation about the origin puts the source's left column at the bottom of a 6x6 box.
        assert_eq!((turned.width(), turned.height()), (6, 6));
        assert_eq!(turned.get(4, 1), [10, 20, 30, 255]);
        assert_eq!(turned.get(1, 1)[3], 0);
    }

    #[test]
    fn an_affine_round_trip_restores_the_interior() {
        let mut image = Bitmap8::new(40, 40);
        for y in 6..34 {
            for x in 6..34 {
                image.set(x, y, [200, 120, 60, 255]);
            }
        }
        let forward = Affine::rotation(30.0);
        let bounds = forward.bounding_box(40.0, 40.0);
        let rotated = transform_bitmap(&image, &forward, Sampling::Smooth).expect("rotate");
        let width = (bounds.max_x().ceil() - bounds.x.floor()) as u32;
        let height = (bounds.max_y().ceil() - bounds.y.floor()) as u32;
        assert_eq!((rotated.width(), rotated.height()), (width, height));
        // The rotated frame starts at the floored corner of the source's bounding box, so
        // placing it back there (and undoing the rotation) restores the original frame.
        let to_frame = Affine::translation(bounds.x.floor(), bounds.y.floor())
            .then(forward.inverse().expect("inverse"));
        let restored = resample_bitmap(&rotated, 40, 40, &to_frame, Sampling::Smooth).expect("rotate back");
        assert_eq!((restored.width(), restored.height()), (40, 40));
        let mut worst = 0i32;
        for y in 12..28 {
            for x in 12..28 {
                let original = image.get(x, y);
                let round_tripped = restored.get(x, y);
                assert_eq!(round_tripped[3], 255, "alpha at {x},{y}");
                for channel in 0..3 {
                    worst = worst.max((original[channel] as i32 - round_tripped[channel] as i32).abs());
                }
            }
        }
        assert!(worst <= 3, "worst channel error {worst}");
    }

    #[test]
    fn scaling_keeps_the_border_and_the_colors() {
        let image = Bitmap8::filled(4, 4, [40, 80, 120, 255]);
        let up = transform_bitmap(&image, &Affine::scale(2.0, 2.0), Sampling::Smooth).expect("upscale");
        assert_eq!((up.width(), up.height()), (8, 8));
        for y in 0..8 {
            for x in 0..8 {
                assert_eq!(up.get(x, y), [40, 80, 120, 255], "at {x},{y}");
            }
        }
        let down = transform_bitmap(&image, &Affine::scale(0.5, 0.5), Sampling::Smooth).expect("downscale");
        assert_eq!((down.width(), down.height()), (2, 2));
        assert_eq!(down.get(0, 0), [40, 80, 120, 255]);
    }

    #[test]
    fn bilinear_sampling_interpolates_and_fades_outside() {
        let mut image = Bitmap8::new(2, 1);
        image.set(0, 0, [0, 0, 0, 255]);
        image.set(1, 0, [255, 255, 255, 255]);
        let middle = sample(&image, 0.5, 0.0, Sampling::Smooth);
        assert_eq!(middle[0], 128);
        assert_eq!(middle[3], 255);
        assert_eq!(sample(&image, 0.0, 0.0, Sampling::Smooth), [0, 0, 0, 255]);
        assert_eq!(sample(&image, 1.0, 0.0, Sampling::Nearest), [255, 255, 255, 255]);
        // Just inside the edge clamps to the edge pixel; outside is transparent.
        assert_eq!(sample(&image, -0.4, 0.0, Sampling::Smooth), [0, 0, 0, 255]);
        assert_eq!(sample(&image, -0.6, 0.0, Sampling::Smooth), [0, 0, 0, 0]);
        assert_eq!(sample(&image, 5.0, 0.0, Sampling::Smooth), [0, 0, 0, 0]);
        assert_eq!(sample(&image, f64::NAN, 0.0, Sampling::Smooth), [0, 0, 0, 0]);
        // A mask samples the same way.
        let mask = Gray8::filled(2, 1, 200);
        assert_eq!(sample_mask(&mask, 0.5, 0.0, Sampling::Smooth), 200);
        assert_eq!(sample_mask(&mask, 9.0, 0.0, Sampling::Smooth), 0);
    }

    #[test]
    fn a_transformed_mask_lands_where_the_pixels_do() {
        let mut mask = Gray8::new(6, 6);
        mask.set(1, 1, 200);
        // A quarter turn moves the output frame's origin, which the mask must follow too.
        let turned = transform_mask(&mask, &Affine::rotation(90.0), Sampling::Nearest).expect("mask");
        assert_eq!((turned.width(), turned.height()), (6, 6));
        assert_eq!(turned.get(4, 1), 200);
        assert_eq!(turned.get(1, 1), 0);
        let same = transform_mask(&mask, &Affine::IDENTITY, Sampling::Nearest).expect("mask");
        assert_eq!(same, mask);
        assert_eq!(resample_mask(&mask, 6, 6, &Affine::IDENTITY, Sampling::Nearest).expect("mask"), mask);
    }

    #[test]
    fn an_identity_quad_keeps_the_image() {
        let corners = [point(0.0, 0.0), point(6.0, 0.0), point(6.0, 6.0), point(0.0, 6.0)];
        assert!(is_convex_quad(&corners));
        let warped = warp_perspective(&dot(), &corners, Sampling::Nearest).expect("warp");
        assert_eq!((warped.width(), warped.height()), (6, 6));
        assert_eq!(warped.get(1, 1), [10, 20, 30, 255]);
        assert_eq!(warped.get(4, 4)[3], 0);
    }

    #[test]
    fn a_perspective_quad_maps_its_corners() {
        let mut image = Bitmap8::new(8, 8);
        for y in 0..8 {
            for x in 0..8 {
                image.set(x, y, [(x * 30) as u8, (y * 30) as u8, 0, 255]);
            }
        }
        // A trapezoid whose top edge is half the width of its bottom edge.
        let corners = [point(2.0, 0.0), point(6.0, 0.0), point(8.0, 8.0), point(0.0, 8.0)];
        assert!(is_convex_quad(&corners));
        let warped = warp_perspective(&image, &corners, Sampling::Nearest).expect("warp");
        assert_eq!((warped.width(), warped.height()), (8, 8));
        assert_eq!(warped.get(0, 7), image.get(0, 7));
        assert_eq!(warped.get(7, 7), image.get(7, 7));
        assert_eq!(warped.get(4, 0), image.get(4, 0), "the top midpoint stays put");
        assert_eq!(warped.get(0, 0)[3], 0, "outside the quad stays transparent");
        assert_eq!(warped.get(7, 0)[3], 0);
    }

    #[test]
    fn a_folded_quad_still_paints() {
        let mut image = Bitmap8::filled(8, 8, [90, 40, 10, 255]);
        image.set(0, 0, [10, 20, 30, 255]);
        // A bowtie: the corners cross over, so no perspective can express the shape.
        let corners = [point(0.0, 0.0), point(8.0, 0.0), point(0.0, 8.0), point(8.0, 8.0)];
        assert!(!is_convex_quad(&corners));
        let warped = warp_perspective(&image, &corners, Sampling::Nearest).expect("warp");
        assert!(warped.pixels().chunks_exact(4).any(|pixel| pixel[3] != 0));
        assert!(warped.pixels().chunks_exact(4).any(|pixel| pixel[3] == 0));
    }

    #[test]
    fn degenerate_transforms_are_refused() {
        assert!(transform_bitmap(&dot(), &Affine::scale(0.0, 1.0), Sampling::Nearest).is_err());
        assert!(transform_bitmap(&dot(), &Affine::scale(1.0e6, 1.0e6), Sampling::Nearest).is_err());
        assert!(transform_bitmap(&Bitmap8::new(0, 0), &Affine::IDENTITY, Sampling::Nearest).is_err());
        assert!(transform_mask(&Gray8::new(2, 2), &Affine::scale(0.0, 0.0), Sampling::Nearest).is_err());
        assert!(warp_perspective(&dot(), &[point(0.0, 0.0), point(1.0, 0.0), point(0.0, 1.0), point(1.0, 1.0)], Sampling::Nearest).is_ok());
    }

    #[test]
    fn snapping_pulls_the_nearest_edge_or_center() {
        let mut targets = SnapTargets::canvas(200, 100, true);
        targets.push_guide(&Guide { id: Uuid::nil(), axis: GuideAxis::Vertical, position: 150.0 });
        // The nearest of the box's left, center and right edges wins.
        let result = snap_offset(RectF::new(145.0, 20.0, 6.0, 6.0), &targets, 4.0);
        assert_eq!(result.offset.x, -1.0);
        assert_eq!(result.x, Some(150.0));
        assert_eq!(result.offset.y, 0.0);
        assert_eq!(result.y, None);
        // A box centered on the canvas center does not move at all.
        let centered = snap_offset(RectF::new(97.0, 47.0, 6.0, 6.0), &targets, 4.0);
        assert_eq!(centered.offset.x, 0.0);
        assert_eq!(centered.x, Some(100.0));
        assert_eq!(centered.y, Some(50.0));
        // Each axis snaps on its own: the box's middle lands on the canvas center and only
        // its left edge is within reach of the canvas edge.
        let corner = snap_offset(RectF::new(-1.0, 98.0, 4.0, 4.0), &targets, 4.0);
        assert_eq!(corner.offset.x, 1.0);
        assert_eq!(corner.x, Some(0.0));
        assert_eq!(corner.offset.y, 0.0);
        assert_eq!(corner.y, Some(100.0));
        // A box whose edges all miss the targets stays where it is.
        let free = snap_offset(RectF::new(60.0, 20.0, 6.0, 6.0), &targets, 4.0);
        assert_eq!(free.offset, point(0.0, 0.0));
        assert_eq!(free.x, None);
        assert_eq!(free.y, None);
    }

    #[test]
    fn snapping_stays_within_its_tolerance() {
        let targets = SnapTargets::canvas(200, 100, true);
        let far = snap_offset(RectF::new(60.0, 20.0, 6.0, 6.0), &targets, 4.0);
        assert_eq!(far.offset, point(0.0, 0.0));
        assert_eq!(far.x, None);
        assert_eq!(far.y, None);
        assert_eq!(snap_offset(RectF::new(99.0, 20.0, 6.0, 6.0), &targets, 0.0).x, None);
        assert_eq!(snap_value(100.0, &[100.0], 0.0), Some(100.0));
        assert_eq!(snap_value(100.0, &[], 10.0), None);
        assert_eq!(snap_value(100.0, &[104.0], 4.0), Some(104.0));
        assert_eq!(snap_value(100.0, &[96.0, 104.0], 4.0), Some(96.0), "ties keep the earlier target");
        let (moved, x, y) = snap_point(point(100.0, 97.0), &targets, 4.0);
        assert_eq!(moved, point(100.0, 100.0));
        assert_eq!(x, Some(100.0));
        assert_eq!(y, Some(100.0));
        // A point far enough from every target on both axes stays put.
        let (still, x, y) = snap_point(point(20.0, 20.0), &targets, 4.0);
        assert_eq!(still, point(20.0, 20.0));
        assert_eq!(x, None);
        assert_eq!(y, None);
        assert_eq!(snap_point(point(20.0, 20.0), &targets, -1.0).0, point(20.0, 20.0));
    }

    #[test]
    fn grid_lines_count_from_the_origin() {
        let grid = LayoutGrid::new(64, 8);
        assert_eq!(grid.step(), 8.0);
        let lines = grid.lines(70.0);
        assert_eq!(lines.len(), 9);
        assert_eq!(lines[0], 0.0);
        assert_eq!(lines[8], 64.0);
        assert!(grid.is_major(64.0));
        assert!(!grid.is_major(8.0));
        assert_eq!(LayoutGrid::new(1, 0).spacing, 2);
        assert_eq!(LayoutGrid::new(64, 200).subdivisions, 64);
        let mut targets = SnapTargets::new();
        targets.push_grid(&grid, 70, 70);
        assert!(targets.xs.contains(&64.0));
        assert_eq!(snap_value(66.0, &targets.xs, 2.0), Some(64.0));
    }

    #[test]
    fn document_targets_include_guides_and_layer_bounds() {
        let mut document = Document::new(100, 100);
        document.guides.push(Guide { id: Uuid::nil(), axis: GuideAxis::Horizontal, position: 25.0 });
        document.guides.push(Guide { id: Uuid::new_v4(), axis: GuideAxis::Vertical, position: 40.0 });
        let mut layer = Layer::with_image("Layer", Bitmap8::new(20, 20));
        layer.transform.origin = point(30.0, 40.0);
        document.add_layer(layer, None);
        let targets = SnapTargets::from_document(&document, false);
        assert!(targets.xs.contains(&40.0), "the vertical guide");
        assert!(targets.ys.contains(&25.0), "the horizontal guide");
        assert!(targets.xs.contains(&30.0) && targets.xs.contains(&50.0));
        assert!(targets.ys.contains(&40.0) && targets.ys.contains(&60.0));
        assert!(targets.xs.contains(&0.0) && targets.xs.contains(&100.0));
        assert!(!targets.ys.contains(&50.0), "canvas centers are opt-in");
        let with_centers = SnapTargets::from_document(&document, true);
        assert!(with_centers.xs.contains(&50.0) && with_centers.ys.contains(&50.0));
    }
}
