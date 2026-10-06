//! Where a layer's pixels land: the transform sampling the original does with Core Graphics, done here
//! pixel by pixel so the canvas is reproducible off the GPU.
//!
//! Sampling counts pixel corners, so pixel `i` covers `[i, i + 1)` and its center is `i + 0.5`. An
//! unrotated layer at one to one copies its pixels straight across, as the original's `.none`
//! interpolation quality does.

use rayon::prelude::*;

use comp_core::geom::{PointF, Transform};
use comp_core::{Affine, Bitmap8, BlendMode, Gray8, Sampling};

use crate::blend::Box;
use crate::pixel::{pixel_bounds, pixel_to_document, round_u8, Filter, Plane, Surface};

/// The integer box a placement wrote: `(x, y, width, height)` in document pixels.
pub type PlacedBox = (i64, i64, u32, u32);

/// Places `source` into `dst` through `transform`, clearing the box it covers first so a reused
/// scratch surface carries nothing over.
pub fn place_surface(dst: &mut Surface, source: &Surface, transform: &Transform) -> Option<PlacedBox> {
    if source.is_empty() || !transform.is_valid() {
        return None;
    }
    let box_ = pixel_bounds(transform, dst.width(), dst.height())?;
    dst.clear_rect(box_.0, box_.1, box_.2, box_.3);
    let affine = pixel_to_document(transform, source.width(), source.height());
    let inverse = affine.inverse()?;
    let filter = sampling_filter(transform.sampling, source.width(), source.height(), transform, &affine);
    let level = match transform.sampling {
        Sampling::Nearest => 0,
        _ => Surface::downsample_level(scale_factor(source.width(), source.height(), transform, &affine)),
    };
    let (sampled, coord_scale) = if level > 0 {
        let (reduced, applied) = source.reduced(level);
        (reduced, 1.0 / (1u32 << applied) as f32)
    } else {
        (source.clone(), 1.0)
    };
    // Pixel for pixel and upright on whole pixels: the source's own bytes, with no filter to soften them.
    if is_integral_translation(&affine) {
        copy_translated(dst, source, affine.tx, affine.ty, &box_);
        return Some(box_);
    }
    let axis_aligned = affine.b.abs() < 1e-9 && affine.c.abs() < 1e-9;
    let row_bytes = dst.width() as usize * 4;
    let canvas_width = dst.width() as i64;
    dst.pixels_mut()
        .par_chunks_mut(row_bytes)
        .enumerate()
        .for_each(|(y, row)| {
            let py = y as i64;
            if py < box_.1 || py >= box_.1 + box_.3 as i64 {
                return;
            }
            for x in 0..canvas_width {
                if x < box_.0 || x >= box_.0 + box_.2 as i64 {
                    continue;
                }
                let (sx, sy) = sample_point(&inverse, x, py);
                let coverage = if axis_aligned {
                    axis_coverage(&affine, source.width(), source.height(), x, py)
                } else {
                    rotated_coverage(&inverse, source.width(), source.height(), x, py)
                };
                if coverage <= 0.0 {
                    continue;
                }
                let sample = sampled.sample(sx * coord_scale, sy * coord_scale, filter);
                let i = x as usize * 4;
                for c in 0..4 {
                    row[i + c] = round_u8(sample[c] * coverage);
                }
            }
        });
    Some(box_)
}

/// Places a gray mask into a document-sized coverage plane, the way Core Graphics clips to a mask.
pub fn place_coverage(plane: &mut Plane, mask: &Gray8, transform: &Transform) -> Option<PlacedBox> {
    if mask.width() == 0 || mask.height() == 0 || !transform.is_valid() {
        return None;
    }
    let box_ = pixel_bounds(transform, plane.width(), plane.height())?;
    plane.fill_rect(box_.0, box_.1, box_.2, box_.3, 0);
    let affine = pixel_to_document(transform, mask.width(), mask.height());
    let inverse = affine.inverse()?;
    let filter = sampling_filter(transform.sampling, mask.width(), mask.height(), transform, &affine);
    let axis_aligned = affine.b.abs() < 1e-9 && affine.c.abs() < 1e-9;
    for y in box_.1..box_.1 + box_.3 as i64 {
        for x in box_.0..box_.0 + box_.2 as i64 {
            let coverage = if axis_aligned {
                axis_coverage(&affine, mask.width(), mask.height(), x, y)
            } else {
                rotated_coverage(&inverse, mask.width(), mask.height(), x, y)
            };
            if coverage <= 0.0 {
                continue;
            }
            let (sx, sy) = sample_point(&inverse, x, y);
            let value = sample_gray(mask, sx, sy, filter);
            plane.set(x as u32, y as u32, round_u8(value * coverage));
        }
    }
    Some(box_)
}

/// Resamples a mask placed by `mask_transform` into the pixel grid of a layer placed by
/// `layer_transform`, which is what a mask unlinked from its layer needs before effects run on it.
pub fn mask_into_grid(
    mask: &Gray8,
    mask_transform: &Transform,
    layer_transform: &Transform,
    width: u32,
    height: u32,
) -> Plane {
    let mut plane = Plane::new(width, height);
    if width == 0 || height == 0 || mask.width() == 0 || mask.height() == 0 {
        return plane;
    }
    if mask.width() == width && mask.height() == height && mask_transform == layer_transform {
        plane.values_mut().copy_from_slice(mask.pixels());
        return plane;
    }
    let to_document = pixel_to_document(layer_transform, width, height);
    let from_document = pixel_to_document(mask_transform, mask.width(), mask.height()).inverse();
    let filter = Filter::of(layer_transform.sampling);
    let (Some(to_document), Some(from_document)) = (Some(to_document), from_document) else {
        return plane;
    };
    for y in 0..height {
        for x in 0..width {
            let document = to_document.apply(PointF::new(x as f64 + 0.5, y as f64 + 0.5));
            let local = from_document.apply(document);
            let value = sample_gray(mask, local.x as f32, local.y as f32, filter);
            plane.set(x, y, round_u8(value));
        }
    }
    plane
}

/// Copies a source whose transform is an integer translation, a row at a time.
///
/// This is the path a dirty rectangle takes for every ordinary layer, so it copies spans rather than
/// pixels: one `copy_from_slice` per row instead of a loop with a bounds check per pixel, which is the
/// difference between a byte loop and the memory's own speed. Returns whether every pixel it copied was
/// opaque, which lets the caller skip the blend entirely (see `composite_surface_box`).
fn copy_translated(dst: &mut Surface, source: &Surface, tx: f64, ty: f64, box_: &PlacedBox) -> bool {
    let offset_x = tx.round() as i64;
    let offset_y = ty.round() as i64;
    if (tx - offset_x as f64).abs() > 1e-9 || (ty - offset_y as f64).abs() > 1e-9 {
        return false;
    }
    let mut every_pixel_opaque = true;
    for y in box_.1..box_.1 + box_.3 as i64 {
        let sy = y - offset_y;
        if sy < 0 || sy >= source.height() as i64 {
            continue;
        }
        // The columns the source actually has, intersected with the box and the destination.
        let first = box_.0.max(offset_x).max(0);
        let last = (box_.0 + box_.2 as i64).min(offset_x + source.width() as i64).min(dst.width() as i64);
        if last <= first {
            continue;
        }
        let source_row = source.row(sy as u32);
        let from = (first - offset_x) as usize * 4;
        let to = (last - offset_x) as usize * 4;
        if source_row[from..to].chunks_exact(4).any(|texel| texel[3] != 255) {
            every_pixel_opaque = false;
        }
        let dst_row = dst.row_mut(y as u32);
        dst_row[first as usize * 4..last as usize * 4].copy_from_slice(&source_row[from..to]);
    }
    every_pixel_opaque
}

/// True for an unrotated, unscaled, unflipped placement that lands on whole document pixels: the copy
/// Core Graphics makes with interpolation off.
fn is_integral_translation(affine: &Affine) -> bool {
    (affine.a - 1.0).abs() < 1e-9
        && (affine.d - 1.0).abs() < 1e-9
        && affine.b.abs() < 1e-9
        && affine.c.abs() < 1e-9
        && (affine.tx - affine.tx.round()).abs() < 1e-9
        && (affine.ty - affine.ty.round()).abs() < 1e-9
}

/// True when the transform turns nothing, which the original checks before dropping to no interpolation.
fn is_upright(affine: &Affine) -> bool {
    affine.b.abs() < 1e-9 && affine.c.abs() < 1e-9
}

/// The source coordinate in pixel corners for the center of destination pixel `(x, y)`.
#[inline]
fn sample_point(inverse: &Affine, x: i64, y: i64) -> (f32, f32) {
    let px = x as f64 + 0.5;
    let py = y as f64 + 0.5;
    (
        (inverse.a * px + inverse.c * py + inverse.tx) as f32,
        (inverse.b * px + inverse.d * py + inverse.ty) as f32,
    )
}

/// Destination pixels per source pixel, used to pick how far to reduce before sampling.
fn scale_factor(width: u32, height: u32, transform: &Transform, affine: &Affine) -> f32 {
    let determinant = (affine.a * affine.d - affine.b * affine.c).abs().max(1e-12);
    let factor = determinant.sqrt();
    let _ = (width, height, transform);
    factor as f32
}

/// The filter the original's `interpolation(_:finalFactor:upright:)` picks: Nearest stays nearest, a
/// reduction uses a bilinear pass over the halvings, and enlarging keeps the layer's own quality.
fn sampling_filter(sampling: Sampling, width: u32, height: u32, transform: &Transform, affine: &Affine) -> Filter {
    if sampling == Sampling::Nearest {
        return Filter::Nearest;
    }
    let factor = scale_factor(width, height, transform, affine);
    if is_upright(affine) && (factor - 1.0).abs() < 0.001 {
        return Filter::Nearest;
    }
    if factor <= 1.0 {
        return Filter::Bilinear;
    }
    match sampling {
        Sampling::Smooth => Filter::Bilinear,
        _ => Filter::Bicubic,
    }
}

/// Coverage of one destination pixel by the source rectangle when the transform has no rotation: the
/// product of the two axes' overlaps, which is exact.
fn axis_coverage(affine: &Affine, width: u32, height: u32, x: i64, y: i64) -> f32 {
    let (x0, x1) = span(affine.tx, affine.tx + affine.a * width as f64);
    let (y0, y1) = span(affine.ty, affine.ty + affine.d * height as f64);
    let cx = overlap(x as f64, x as f64 + 1.0, x0, x1);
    let cy = overlap(y as f64, y as f64 + 1.0, y0, y1);
    (cx * cy) as f32
}

#[inline]
fn span(a: f64, b: f64) -> (f64, f64) {
    if a <= b {
        (a, b)
    } else {
        (b, a)
    }
}

#[inline]
fn overlap(a0: f64, a1: f64, b0: f64, b1: f64) -> f64 {
    (a1.min(b1) - a0.max(b0)).clamp(0.0, 1.0)
}

/// Coverage when the layer is turned: the destination pixel's quad clipped against the source rectangle,
/// so a rotated edge softens over one pixel instead of stair-stepping.
fn rotated_coverage(inverse: &Affine, width: u32, height: u32, x: i64, y: i64) -> f32 {
    let corners = [
        inverse.apply(PointF::new(x as f64, y as f64)),
        inverse.apply(PointF::new(x as f64 + 1.0, y as f64)),
        inverse.apply(PointF::new(x as f64 + 1.0, y as f64 + 1.0)),
        inverse.apply(PointF::new(x as f64, y as f64 + 1.0)),
    ];
    let clipped = clip_to_box(&corners, width as f64, height as f64);
    if clipped.len() < 3 {
        return 0.0;
    }
    let mut area = 0.0;
    for i in 0..clipped.len() {
        let a = clipped[i];
        let b = clipped[(i + 1) % clipped.len()];
        area += a.x * b.y - b.x * a.y;
    }
    let area = (area / 2.0).abs();
    let unit = (inverse.a * inverse.d - inverse.b * inverse.c).abs().max(1e-12);
    (area / unit).clamp(0.0, 1.0) as f32
}

/// Sutherland-Hodgman against the rectangle `0,0,width,height`.
fn clip_to_box(points: &[PointF; 4], width: f64, height: f64) -> Vec<PointF> {
    let mut polygon: Vec<PointF> = points.to_vec();
    // Each edge is the half plane @@a x + b y - c >= 0@@: inside the rectangle, the left and top borders
    // included.
    let edges: [(f64, f64, f64); 4] = [
        (1.0, 0.0, 0.0),
        (-1.0, 0.0, -width),
        (0.0, 1.0, 0.0),
        (0.0, -1.0, -height),
    ];
    for (a, b, c) in edges {
        if polygon.is_empty() {
            break;
        }
        let input = std::mem::take(&mut polygon);
        let inside = |p: &PointF| a * p.x + b * p.y - c >= 0.0;
        for i in 0..input.len() {
            let current = input[i];
            let previous = input[(i + input.len() - 1) % input.len()];
            let current_inside = inside(&current);
            let previous_inside = inside(&previous);
            if current_inside {
                if !previous_inside {
                    if let Some(point) = intersect(previous, current, a, b, c) {
                        polygon.push(point);
                    }
                }
                polygon.push(current);
            } else if previous_inside {
                if let Some(point) = intersect(previous, current, a, b, c) {
                    polygon.push(point);
                }
            }
        }
    }
    polygon
}

fn intersect(from: PointF, to: PointF, a: f64, b: f64, c: f64) -> Option<PointF> {
    let d0 = a * from.x + b * from.y - c;
    let d1 = a * to.x + b * to.y - c;
    let denominator = d0 - d1;
    if denominator.abs() < 1e-12 {
        return None;
    }
    let t = (d0 / denominator).clamp(0.0, 1.0);
    Some(PointF::new(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t))
}

/// One mask value at a fractional pixel-corner coordinate, clamped at the edges.
fn sample_gray(mask: &Gray8, x: f32, y: f32, filter: Filter) -> f32 {
    let width = mask.width() as i64;
    let height = mask.height() as i64;
    let texel = |x: i64, y: i64| -> f32 {
        mask.get(x.clamp(0, width - 1) as u32, y.clamp(0, height - 1) as u32) as f32
    };
    match filter {
        Filter::Nearest => texel(x.floor() as i64, y.floor() as i64),
        Filter::Bilinear => {
            let fx = x - 0.5;
            let fy = y - 0.5;
            let x0 = fx.floor();
            let y0 = fy.floor();
            let wx = fx - x0;
            let wy = fy - y0;
            let (x0, y0) = (x0 as i64, y0 as i64);
            let top = texel(x0, y0) * (1.0 - wx) + texel(x0 + 1, y0) * wx;
            let bottom = texel(x0, y0 + 1) * (1.0 - wx) + texel(x0 + 1, y0 + 1) * wx;
            top * (1.0 - wy) + bottom * wy
        }
        Filter::Bicubic => {
            // Catmull-Rom, the same cubic placements use for color.
            let fx = x - 0.5;
            let fy = y - 0.5;
            let x0 = fx.floor();
            let y0 = fy.floor();
            let tx = fx - x0;
            let ty = fy - y0;
            let (x0, y0) = (x0 as i64, y0 as i64);
            let weights = |t: f32| {
                let t2 = t * t;
                let t3 = t2 * t;
                [
                    -0.5 * t3 + t2 - 0.5 * t,
                    1.5 * t3 - 2.5 * t2 + 1.0,
                    -1.5 * t3 + 2.0 * t2 + 0.5 * t,
                    0.5 * t3 - 0.5 * t2,
                ]
            };
            let wx = weights(tx);
            let wy = weights(ty);
            let mut sum = 0.0;
            for (j, weight_y) in wy.iter().enumerate() {
                for (i, weight_x) in wx.iter().enumerate() {
                    sum += texel(x0 + i as i64 - 1, y0 + j as i64 - 1) * weight_x * weight_y;
                }
            }
            sum
        }
    }
}


/// Paints a straight-alpha bitmap straight into a premultiplied canvas at a whole-pixel placement.
///
/// This is the dirty rectangle's common case and it takes no intermediate surface at all: the source is
/// premultiplied as it is read and blended where it lands. A row whose pixels are all opaque is copied
/// rather than premultiplied, because at full alpha the two are the same bytes. Returns nothing when the
/// placement needs resampling, which is the caller's cue to take the general path.
pub fn paint_bitmap_box(
    canvas: &mut Surface,
    image: &Bitmap8,
    transform: &Transform,
    mode: BlendMode,
    opacity: f32,
) -> Option<()> {
    if image.is_empty() || !transform.is_valid() || canvas.is_empty() {
        return None;
    }
    // The transform arrives in the canvas's own coordinates, so the placement is clipped to the canvas
    // and written at the same coordinates rather than at an offset.
    let affine = pixel_to_document(transform, image.width(), image.height());
    if !is_integral_translation(&affine) {
        return None;
    }
    let destination = pixel_bounds(transform, canvas.width(), canvas.height())?;
    let offset_x = affine.tx.round() as i64;
    let offset_y = affine.ty.round() as i64;
    let plain_copy = mode == BlendMode::Normal && opacity >= 1.0;
    let canvas_width = canvas.width();
    let row_bytes = canvas_width as usize * 4;
    // Row by row across the cores: a dirty rectangle is small, but the per-pixel branch - an opacity, a
    // blend mode the copy cannot take - is the whole cost of it when it happens.
    canvas
        .pixels_mut()
        .par_chunks_mut(row_bytes)
        .enumerate()
        .for_each(|(y, row)| {
            let y = y as i64;
            if y < destination.1 || y >= destination.1 + destination.3 as i64 {
                return;
            }
            let sy = y - offset_y;
            if sy < 0 || sy >= image.height() as i64 {
                return;
            }
            let first = destination.0.max(offset_x).max(0);
            let last = (destination.0 + destination.2 as i64)
                .min(offset_x + image.width() as i64)
                .min(canvas_width as i64);
            if last <= first {
                return;
            }
            let source_row = image.row(sy as u32);
            let span = &source_row[(first - offset_x) as usize * 4..(last - offset_x) as usize * 4];
            let start = first as usize * 4;
            let target = &mut row[start..start + span.len()];
            if plain_copy && span.chunks_exact(4).all(|texel| texel[3] == 255) {
                target.copy_from_slice(span);
                return;
            }
            for (under, texel) in target.chunks_exact_mut(4).zip(span.chunks_exact(4)) {
                let top = premultiplied_with_opacity(texel, opacity);
                if top[3] == 0 {
                    continue;
                }
                let backdrop = [under[0], under[1], under[2], under[3]];
                let blended = crate::blend::composite_texel_mode(mode, backdrop, top);
                under.copy_from_slice(&blended);
            }
        });
    Some(())
}

/// A straight texel as the premultiplied texel a surface would hold for it, with the opacity folded in
/// exactly as Surface::scale_alpha folds it: the alpha is rounded first, and the colors follow it.
fn premultiplied_with_opacity(texel: &[u8], opacity: f32) -> [u8; 4] {
    let alpha_byte = texel[3] as u32;
    if alpha_byte == 0 {
        return [0, 0, 0, 0];
    }
    let mut premultiplied = [
        ((texel[0] as u32 * alpha_byte + 127) / 255) as u8,
        ((texel[1] as u32 * alpha_byte + 127) / 255) as u8,
        ((texel[2] as u32 * alpha_byte + 127) / 255) as u8,
        texel[3],
    ];
    if opacity >= 1.0 {
        return premultiplied;
    }
    let alpha = round_u8(texel[3] as f32 * opacity.max(0.0));
    if alpha == texel[3] {
        return premultiplied;
    }
    if alpha == 0 {
        return [0, 0, 0, 0];
    }
    let ratio = alpha as f32 / texel[3] as f32;
    for channel in premultiplied.iter_mut().take(3) {
        *channel = round_u8(*channel as f32 * ratio);
    }
    premultiplied[3] = alpha;
    premultiplied
}

/// Places a straight-alpha bitmap into a dense box-sized surface, premultiplying only what lands in the
/// box.
///
/// Converting the whole layer and then placing it is what made a dirty rectangle cost as much as a whole
/// render: a 4000 x 4000 layer is sixteen million pixels to premultiply for an 800 x 800 rectangle. Only
/// the pixels inside the box are touched here, and a layer on whole pixels whose pixels are all opaque
/// needs no arithmetic at all - premultiplied bytes and straight bytes are the same bytes at full alpha,
/// so it is a row copy.
///
/// Returns nothing when the placement is not an integer translation, which is the caller's cue to take the
/// general resampling path.
pub fn place_bitmap_box(image: &Bitmap8, transform: &Transform, box_: Box) -> Option<(Surface, bool)> {
    if image.is_empty() || !transform.is_valid() || box_.2 == 0 || box_.3 == 0 {
        return None;
    }
    let mut local = *transform;
    local.origin.x -= box_.0 as f64;
    local.origin.y -= box_.1 as f64;
    let affine = pixel_to_document(&local, image.width(), image.height());
    if !is_integral_translation(&affine) {
        return None;
    }
    let destination = pixel_bounds(&local, box_.2, box_.3)?;
    let offset_x = affine.tx.round() as i64;
    let offset_y = affine.ty.round() as i64;
    let mut out = Surface::new(box_.2, box_.3);
    let mut every_pixel_opaque = true;
    for row in 0..destination.3 as i64 {
        let y = destination.1 + row;
        let sy = y - offset_y;
        if sy < 0 || sy >= image.height() as i64 {
            continue;
        }
        let first = destination.0.max(offset_x).max(0);
        let last = (destination.0 + destination.2 as i64)
            .min(offset_x + image.width() as i64)
            .min(box_.2 as i64);
        if last <= first {
            continue;
        }
        let source_row = image.row(sy as u32);
        let span = &source_row[(first - offset_x) as usize * 4..(last - offset_x) as usize * 4];
        let start = first as usize * 4;
        let target = &mut out.row_mut(y as u32)[start..start + span.len()];
        if span.chunks_exact(4).all(|texel| texel[3] == 255) {
            target.copy_from_slice(span);
            continue;
        }
        every_pixel_opaque = false;
        for (destination_texel, texel) in target.chunks_exact_mut(4).zip(span.chunks_exact(4)) {
            // The color channels scale by the alpha; the alpha itself does not (premultiplying it by
            // itself would square it, which is how a half-transparent layer lost half its transparency).
            let alpha = texel[3] as u32;
            for channel in 0..3 {
                destination_texel[channel] = ((texel[channel] as u32 * alpha + 127) / 255) as u8;
            }
            destination_texel[3] = texel[3];
        }
    }
    Some((out, every_pixel_opaque))
}

/// What the GPU needs to place a layer itself: the same affine the CPU samples through, its inverse, the
/// filter the CPU would pick, and the destination box.
///
/// The shader reproduces `place_surface` with these: the inverse maps a canvas pixel's center back into the
/// layer's pixels, and the coverage that softens a scaled or turned edge is computed from the affine, so
/// the sampling is the CPU's own rule and not an approximation of it.
#[derive(Clone, Copy, Debug)]
pub struct Placement {
    /// The rounded-out rectangle of the canvas the layer covers.
    pub box_: PlacedBox,
    pub affine: Affine,
    pub inverse: Affine,
    /// 0 nearest, 1 bilinear, 2 bicubic, matching the shader's own numbering.
    pub filter: u32,
    /// True when the transform turns nothing, which selects the axis-aligned coverage.
    pub axis_aligned: bool,
    /// How many times the CPU halves the layer before sampling it.
    pub level: u32,
    /// The scale a sample coordinate is multiplied by when the layer was reduced: 1 / 2^level applied.
    pub coord_scale: f32,
}

/// The layer's own pixels reduced the way the CPU's `DownsampleCache` reduces them, for a placement that
/// needs a level: each step averages 2 x 2 blocks, so a large reduction stays sharp instead of aliasing.
///
/// Returns the reduced image as straight-alpha bytes - what the shader samples - and the scale its
/// coordinates take.
pub fn reduced_for_gpu(image: &Bitmap8, level: u32) -> Option<(Bitmap8, f32)> {
    if image.is_empty() {
        return None;
    }
    let source = Surface::from_bitmap(image);
    let (reduced, applied) = source.reduced(level);
    let bitmap = reduced.to_bitmap();
    Some((bitmap, 1.0 / (1u32 << applied) as f32))
}

/// The placement of a layer's pixels on a canvas, or nothing when the transform does not land on it.
pub fn placement_for(
    transform: &Transform,
    source_width: u32,
    source_height: u32,
    canvas_width: u32,
    canvas_height: u32,
) -> Option<Placement> {
    if source_width == 0 || source_height == 0 || !transform.is_valid() {
        return None;
    }
    let box_ = pixel_bounds(transform, canvas_width, canvas_height)?;
    let affine = pixel_to_document(transform, source_width, source_height);
    let inverse = affine.inverse()?;
    let filter = match sampling_filter(transform.sampling, source_width, source_height, transform, &affine) {
        Filter::Nearest => 0,
        Filter::Bilinear => 1,
        Filter::Bicubic => 2,
    };
    let level = match transform.sampling {
        Sampling::Nearest => 0,
        _ => Surface::downsample_level(scale_factor(source_width, source_height, transform, &affine)),
    };
    // The CPU reduces in a loop that stops early when a further halving would do nothing, so the scale is
    // one over two to the levels it actually applied, not the levels asked for.
    let mut coord_scale = 1.0f32;
    if level > 0 {
        let mut applied = 0u32;
        let (mut width, mut height) = (source_width, source_height);
        while applied < level && (width > 1 || height > 1) {
            width = width.div_ceil(2);
            height = height.div_ceil(2);
            applied += 1;
        }
        coord_scale = 1.0 / (1u32 << applied) as f32;
    }
    Some(Placement {
        box_,
        affine,
        inverse,
        filter,
        axis_aligned: affine.b.abs() < 1e-9 && affine.c.abs() < 1e-9,
        level,
        coord_scale,
    })
}

/// Places a source into a dense box-sized surface: the frame-local `box_`, and the surface holds exactly
/// that rectangle.
///
/// This is what a dirty rectangle uses for every layer. The placement math is the ordinary one with the
/// box's corner taken out of the transform, so a layer that lands on whole pixels is still a copy and
/// anything else is still resampled exactly as it would be on the whole canvas. The flag reports whether
/// the box came out fully opaque, which lets the caller copy instead of blending.
pub fn place_surface_box(source: &Surface, transform: &Transform, box_: Box) -> Option<(Surface, bool)> {
    if source.is_empty() || !transform.is_valid() || box_.2 == 0 || box_.3 == 0 {
        return None;
    }
    let mut local = *transform;
    local.origin.x -= box_.0 as f64;
    local.origin.y -= box_.1 as f64;
    let affine = pixel_to_document(&local, source.width(), source.height());
    let mut dst = Surface::new(box_.2, box_.3);
    // Whole pixels, unrotated and unscaled: the source's own bytes.
    if is_integral_translation(&affine) {
        let destination = pixel_bounds(&local, box_.2, box_.3);
        if let Some(destination) = destination {
            let opaque = copy_translated(&mut dst, source, affine.tx, affine.ty, &destination);
            return Some((dst, opaque));
        }
        return Some((dst, false));
    }
    place_surface(&mut dst, source, &local)?;
    Some((dst, false))
}

/// Places a mask into a dense box-sized coverage plane, the counterpart of `place_surface_box`.
pub fn place_coverage_box(mask: &Gray8, transform: &Transform, box_: Box) -> Option<Plane> {
    if mask.width() == 0 || mask.height() == 0 || !transform.is_valid() || box_.2 == 0 || box_.3 == 0 {
        return None;
    }
    let mut local = *transform;
    local.origin.x -= box_.0 as f64;
    local.origin.y -= box_.1 as f64;
    let mut plane = Plane::new(box_.2, box_.3);
    place_coverage(&mut plane, mask, &local)?;
    Some(plane)
}

#[cfg(test)]
mod tests {
    use super::*;
    use comp_core::geom::{SizeF, Sampling};
    use comp_core::Bitmap8;

    fn canvas(width: u32, height: u32) -> Surface {
        Surface::new(width, height)
    }

    fn solid(width: u32, height: u32, texel: [u8; 4]) -> Surface {
        Surface::filled(width, height, texel)
    }

    fn transform_at(x: f64, y: f64, width: f64, height: f64) -> Transform {
        Transform {
            origin: PointF::new(x, y),
            size: SizeF::new(width, height),
            rotation: 0.0,
            flip_x: false,
            flip_y: false,
            sampling: Sampling::Nearest,
        }
    }

    #[test]
    fn an_unrotated_layer_at_one_to_one_copies_exactly() {
        let source = Surface::from_bitmap(
            &Bitmap8::from_raw(2, 2, vec![10, 20, 30, 255, 0, 0, 0, 0, 40, 50, 60, 128, 7, 8, 9, 255]).unwrap(),
        );
        let mut destination = canvas(4, 4);
        let box_ = place_surface(&mut destination, &source, &transform_at(1.0, 2.0, 2.0, 2.0)).unwrap();
        assert_eq!(box_, (1, 2, 2, 2));
        assert_eq!(destination.get(1, 2), [10, 20, 30, 255]);
        assert_eq!(destination.get(2, 2), [0, 0, 0, 0]);
        assert_eq!(destination.get(1, 3)[3], 128);
        assert_eq!(destination.get(0, 0), [0, 0, 0, 0]);
    }

    #[test]
    fn a_half_covered_edge_blends_with_the_backdrop() {
        let source = solid(2, 2, [255, 0, 0, 255]);
        let mut destination = canvas(4, 4);
        // Landed on a half pixel: the first column is covered halfway, the second fully.
        place_surface(&mut destination, &source, &transform_at(0.5, 0.0, 2.0, 2.0)).unwrap();
        assert_eq!(destination.get(0, 0)[3], 128);
        assert_eq!(destination.get(1, 0)[3], 255);
        assert_eq!(destination.get(2, 0)[3], 128);
        // A half-covered edge also scales the premultiplied color with it.
        assert_eq!(destination.get(0, 0)[0], 128);
    }

    #[test]
    fn scaling_uses_the_whole_source() {
        let mut source = Surface::new(4, 4);
        for y in 0..4 {
            for x in 0..4 {
                source.set(x, y, [255, 255, 255, 255]);
            }
        }
        let mut destination = canvas(2, 2);
        place_surface(&mut destination, &source, &transform_at(0.0, 0.0, 2.0, 2.0)).unwrap();
        for y in 0..2 {
            for x in 0..2 {
                assert_eq!(destination.get(x, y)[3], 255, "({x},{y})");
            }
        }
    }

    #[test]
    fn a_mask_lands_where_its_transform_says() {
        let mask = Gray8::from_raw(2, 2, vec![0, 64, 128, 255]).unwrap();
        let mut plane = Plane::new(4, 4);
        place_coverage(&mut plane, &mask, &transform_at(1.0, 1.0, 2.0, 2.0)).unwrap();
        assert_eq!(plane.get(1, 1), 0);
        assert_eq!(plane.get(2, 1), 64);
        assert_eq!(plane.get(1, 2), 128);
        assert_eq!(plane.get(2, 2), 255);
        assert_eq!(plane.get(0, 0), 0);
    }

    #[test]
    fn mask_into_grid_is_a_copy_when_nothing_moves() {
        let mask = Gray8::from_raw(2, 1, vec![9, 200]).unwrap();
        let transform = transform_at(0.0, 0.0, 2.0, 1.0);
        let plane = mask_into_grid(&mask, &transform, &transform, 2, 1);
        assert_eq!(plane.values(), &[9, 200]);
    }

    #[test]
    fn a_rotated_square_covers_its_center() {
        let source = solid(4, 4, [255, 255, 255, 255]);
        let mut destination = canvas(16, 16);
        let transform = Transform {
            origin: PointF::new(0.0, 0.0),
            size: SizeF::new(4.0, 4.0),
            rotation: 45.0,
            flip_x: false,
            flip_y: false,
            sampling: Sampling::Smooth,
        };
        place_surface(&mut destination, &source, &transform).unwrap();
        // Rotating about the box center keeps the center opaque and softens the corners.
        assert_eq!(destination.get(2, 2)[3], 255);
        let corner = destination.get(0, 0)[3];
        assert!(corner < 255, "a rotated corner should not be fully covered: {corner}");
    }
}