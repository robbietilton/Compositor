//! Clone Stamp, Spot Healing and content-aware fill.
//!
//! Clone Stamp copies pixels from a fixed source point, aligned or not, through the same
//! coverage machinery as the brush. Spot Healing and the content fill are ports of
//! `Rendering/HealPixels.c` and `Rendering/ContentFill.c`: the same search, the same solver,
//! the same blending, so a repaired spot looks like the macOS app's.

use comp_core::{Bitmap8, Error, Gray8, PointF, Result};

use crate::brush::{self, Brush, PaintSource, StrokeOutcome};

/// Which pixels Spot Healing reads to rebuild a spot.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HealMode {
    /// Find the best-matching patch anywhere nearby and blend it in.
    ContentAware,
    /// Fill from the surrounding color and add back the local grain.
    CreateTexture,
    /// Like content-aware, but strongly prefers the nearest usable patch.
    ProximityMatch,
}

/// Where Clone Stamp copies from and how that source tracks the brush between strokes.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CloneState {
    source: Option<PointF>,
    offset: Option<(f64, f64)>,
}

impl CloneState {
    pub fn new() -> Self {
        CloneState::default()
    }

    pub fn source(&self) -> Option<PointF> {
        self.source
    }

    pub fn offset(&self) -> Option<(f64, f64)> {
        self.offset
    }

    /// Option-click: where Clone Stamp copies from. A new source starts a new alignment.
    pub fn set_source(&mut self, point: PointF) {
        if !point.is_finite() {
            return;
        }
        self.source = Some(point);
        self.offset = None;
    }

    /// The whole-pixel offset a stroke starting at `point` copies with. An aligned stroke
    /// keeps the first stroke's offset; an unaligned one runs from the brush to the source
    /// every time. Nil until a source has been set.
    pub fn begin_stroke(&mut self, point: PointF, aligned: bool) -> Option<(i64, i64)> {
        let source = self.source?;
        if !point.is_finite() {
            return None;
        }
        let stored = if aligned { self.offset } else { None };
        let offset = stored.unwrap_or_else(|| ((source.x - point.x).round(), (source.y - point.y).round()));
        self.offset = Some(offset);
        Some((offset.0 as i64, offset.1 as i64))
    }

    /// Where the source sits for a brush at `point`, for the canvas's crosshair: the source
    /// itself until a stroke fixes the offset.
    pub fn sample_point(&self, point: PointF, aligned: bool, stroke_active: bool) -> Option<PointF> {
        let source = self.source?;
        match self.offset {
            Some(offset) if aligned || stroke_active => Some(PointF::new(point.x + offset.0, point.y + offset.1)),
            _ => Some(source),
        }
    }
}

/// Copies from `sample` through the brush tip. Target pixel `(x, y)` takes sample pixel
/// `(x + offset.x, y + offset.y)`; where the sample does not reach, nothing is painted.
/// `sample` must be a copy of the source pixels, never the target itself, so a stroke reads
/// the pixels that were there when it started.
pub fn clone_stamp(
    target: &mut Bitmap8,
    sample: &Bitmap8,
    brush: &Brush,
    points: &[PointF],
    offset: (i64, i64),
) -> Result<StrokeOutcome> {
    clone_stamp_clipped(target, sample, brush, points, offset, None)
}

/// Clone Stamp limited to a selection.
pub fn clone_stamp_clipped(
    target: &mut Bitmap8,
    sample: &Bitmap8,
    brush: &Brush,
    points: &[PointF],
    offset: (i64, i64),
    selection: Option<&Gray8>,
) -> Result<StrokeOutcome> {
    brush.validate()?;
    if let Some(mask) = selection {
        if mask.width() != target.width() || mask.height() != target.height() {
            return Err(Error::BufferSize {
                got: mask.byte_len(),
                expected: target.pixel_count(),
                width: target.width(),
                height: target.height(),
            });
        }
    }
    let paint = PaintSource::Sampled { image: sample, offset };
    brush::paint_stroke(target, brush, points, paint, selection, brush.smoothing_pixels(1.0))
}

const OUTSIDE: u8 = 0;
const RING: u8 = 1;
const HOLE: u8 = 2;

/// Rebinds a Spot Healing stroke's coverage to nearby texture. `coverage` is the stroke's
/// coverage mask over the same canvas (see `BrushEngine::coverage_mask`); only its nonzero
/// pixels are rebuilt.
pub fn spot_heal(image: &mut Bitmap8, coverage: &Gray8, mode: HealMode, opacity: f64, seed: u32) -> Result<()> {
    if image.width() != coverage.width() || image.height() != coverage.height() {
        return Err(Error::BufferSize {
            got: coverage.byte_len(),
            expected: image.pixel_count(),
            width: image.width(),
            height: image.height(),
        });
    }
    let width = image.width() as i64;
    let height = image.height() as i64;
    if width == 0 || height == 0 {
        return Ok(());
    }
    let opacity = opacity.clamp(0.0, 1.0);

    // Bounds of the painted area.
    let mut bounds = (width, height, 0i64, 0i64);
    for y in 0..height {
        for x in 0..width {
            if coverage.get(x as u32, y as u32) == 0 {
                continue;
            }
            bounds.0 = bounds.0.min(x);
            bounds.1 = bounds.1.min(y);
            bounds.2 = bounds.2.max(x + 1);
            bounds.3 = bounds.3.max(y + 1);
        }
    }
    if bounds.2 <= bounds.0 || bounds.3 <= bounds.1 {
        return Ok(());
    }
    let box_width = bounds.2 - bounds.0;
    let box_height = bounds.3 - bounds.1;
    let size = box_width.max(box_height);
    let ring = (size / 8).clamp(2, 16);
    let wx0 = (bounds.0 - ring).max(0);
    let wy0 = (bounds.1 - ring).max(0);
    let wx1 = (bounds.2 + ring).min(width);
    let wy1 = (bounds.3 + ring).min(height);
    let ww = wx1 - wx0;
    let wh = wy1 - wy0;
    let wn = (ww * wh) as usize;

    let mut role = vec![OUTSIDE; wn];
    for y in 0..wh {
        for x in 0..ww {
            if coverage.get((wx0 + x) as u32, (wy0 + y) as u32) != 0 {
                role[(y * ww + x) as usize] = HOLE;
            }
        }
    }
    // The ring: pixels within `ring` of the spot, a square dilation done as a row pass and
    // then a column pass with running sums.
    let span = ww.max(wh) as usize + 1;
    let mut prefix = vec![0i64; span];
    let mut near = vec![false; wn];
    for y in 0..wh {
        prefix[0] = 0;
        for x in 0..ww {
            prefix[(x + 1) as usize] = prefix[x as usize] + i64::from(role[(y * ww + x) as usize] == HOLE);
        }
        for x in 0..ww {
            let lo = (x - ring).max(0);
            let hi = (x + ring + 1).min(ww);
            near[(y * ww + x) as usize] = prefix[hi as usize] - prefix[lo as usize] > 0;
        }
    }
    for x in 0..ww {
        prefix[0] = 0;
        for y in 0..wh {
            prefix[(y + 1) as usize] = prefix[y as usize] + i64::from(near[(y * ww + x) as usize]);
        }
        for y in 0..wh {
            let lo = (y - ring).max(0);
            let hi = (y + ring + 1).min(wh);
            if role[(y * ww + x) as usize] == OUTSIDE && prefix[hi as usize] - prefix[lo as usize] > 0 {
                role[(y * ww + x) as usize] = RING;
            }
        }
    }
    let ring_count = role.iter().filter(|value| **value == RING).count() as f64;
    if ring_count == 0.0 {
        return Ok(());
    }

    // Source patch for Content-Aware and Proximity Match.
    let mut source_offset = (0i64, 0i64);
    let mut have_source = false;
    if mode != HealMode::CreateTexture {
        const FACTORS: [f64; 5] = [1.05, 1.35, 1.75, 2.25, 2.8];
        let count = if mode == HealMode::ProximityMatch { 2 } else { 5 };
        let mut best = f64::INFINITY;
        for (level, factor) in FACTORS.iter().enumerate().take(count) {
            for angle_index in 0..24 {
                let angle = angle_index as f64 * std::f64::consts::PI / 12.0;
                let dx = (angle.cos() * factor * ww as f64).round() as i64;
                let dy = (angle.sin() * factor * wh as f64).round() as i64;
                let Some(score) = heal_score(image, &role, (wx0, wy0, ww, wh), (dx, dy), width, height) else {
                    continue;
                };
                let score = score
                    * if mode == HealMode::ProximityMatch { 1.0 + 0.6 * level as f64 } else { 1.0 + 0.1 * level as f64 };
                if score < best {
                    best = score;
                    source_offset = (dx, dy);
                }
            }
        }
        if best.is_finite() {
            // Fine-tune the alignment so repeating texture lines up.
            let current = source_offset;
            let mut refined =
                heal_score(image, &role, (wx0, wy0, ww, wh), current, width, height).unwrap_or(f64::INFINITY);
            for j in -3..=3 {
                for i in -3..=3 {
                    let candidate = (current.0 + i, current.1 + j);
                    if let Some(score) = heal_score(image, &role, (wx0, wy0, ww, wh), candidate, width, height) {
                        if score < refined {
                            refined = score;
                            source_offset = candidate;
                        }
                    }
                }
            }
            have_source = true;
        }
    }

    // Membrane: the edge difference between the original and the patch (or the original
    // itself for a smooth fill), spread across the spot.
    let mut mean = [0f64; 4];
    let mut detail = [0f64; 3];
    let mut value = vec![0f32; wn * 4];
    for y in 0..wh {
        for x in 0..ww {
            let index = (y * ww + x) as usize;
            if role[index] != RING {
                continue;
            }
            let ix = wx0 + x;
            let iy = wy0 + y;
            let target = image.get(ix as u32, iy as u32);
            let source = if have_source {
                Some(image.get((ix + source_offset.0) as u32, (iy + source_offset.1) as u32))
            } else {
                None
            };
            for channel in 0..4 {
                let delta = target[channel] as f64 - source.map(|p| p[channel] as f64).unwrap_or(0.0);
                value[index * 4 + channel] = delta as f32;
                mean[channel] += delta;
            }
            if !have_source {
                // Fine detail around the spot: each pixel against the average of its neighbors.
                for channel in 0..3 {
                    let mut around = 0.0;
                    let mut count = 0;
                    for (dx, dy) in [(-1i64, 0i64), (1, 0), (0, -1), (0, 1)] {
                        let nx = ix + dx;
                        let ny = iy + dy;
                        if nx < 0 || ny < 0 || nx >= width || ny >= height {
                            continue;
                        }
                        around += image.get(nx as u32, ny as u32)[channel] as f64;
                        count += 1;
                    }
                    if count > 0 {
                        let difference = target[channel] as f64 - around / count as f64;
                        detail[channel] += difference * difference;
                    }
                }
            }
        }
    }
    for channel in 0..4 {
        mean[channel] /= ring_count;
    }
    for index in 0..wn {
        if role[index] == HOLE {
            for channel in 0..4 {
                value[index * 4 + channel] = mean[channel] as f32;
            }
        }
    }
    heal_solve(&mut value, &role, ww as usize, wh as usize, 0);
    for channel in 0..3 {
        detail[channel] = (detail[channel] / ring_count).sqrt() * 0.9;
    }

    for y in 0..wh {
        for x in 0..ww {
            let index = (y * ww + x) as usize;
            if role[index] != HOLE {
                continue;
            }
            let ix = wx0 + x;
            let iy = wy0 + y;
            let amount = coverage.get(ix as u32, iy as u32) as f64 / 255.0 * opacity;
            let mut grain = 0.0;
            if !have_source {
                let key = heal_hash(seed ^ heal_hash((iy * width + ix) as u32));
                let u1 = heal_unit(key);
                let u2 = heal_unit(key ^ 0x68e3_1da4);
                grain = (-2.0 * (1.0 - u1).ln()).sqrt() * (2.0 * std::f64::consts::PI * u2).cos();
            }
            let target = image.get(ix as u32, iy as u32);
            let source = if have_source {
                Some(image.get((ix + source_offset.0) as u32, (iy + source_offset.1) as u32))
            } else {
                None
            };
            let mut healed = [0f64; 4];
            for channel in 0..4 {
                let base = source.map(|p| p[channel] as f64).unwrap_or(0.0);
                let extra = value[index * 4 + channel] as f64 + if channel < 3 { grain * detail[channel] } else { 0.0 };
                healed[channel] = target[channel] as f64 + (base + extra - target[channel] as f64) * amount;
            }
            // Straight alpha: color is independent of coverage, so it clamps to 0-255 rather
            // than to the alpha a premultiplied macOS buffer would have used.
            let mut out = [0u8; 4];
            out[3] = healed[3].round().clamp(0.0, 255.0) as u8;
            for channel in 0..3 {
                out[channel] = healed[channel].round().clamp(0.0, 255.0) as u8;
            }
            image.set(ix as u32, iy as u32, out);
        }
    }
    Ok(())
}

fn heal_hash(x: u32) -> u32 {
    let mut value = x;
    value ^= value >> 16;
    value = value.wrapping_mul(0x7feb_352d);
    value ^= value >> 15;
    value = value.wrapping_mul(0x846c_a68b);
    value ^= value >> 16;
    value
}

fn heal_unit(key: u32) -> f64 {
    (heal_hash(key) >> 8) as f64 / 16_777_216.0
}

/// Mean squared difference between the ring around the spot and the ring around the patch
/// offset by `offset`. Nil when the patch would overlap the spot or leave the image.
fn heal_score(
    image: &Bitmap8,
    role: &[u8],
    window: (i64, i64, i64, i64),
    offset: (i64, i64),
    width: i64,
    height: i64,
) -> Option<f64> {
    let (wx0, wy0, ww, wh) = window;
    if offset.0.abs() < ww && offset.1.abs() < wh {
        return None;
    }
    if wx0 + offset.0 < 0 || wy0 + offset.1 < 0 || wx0 + ww + offset.0 > width || wy0 + wh + offset.1 > height {
        return None;
    }
    let mut sum = 0.0;
    let mut count = 0i64;
    for y in 0..wh {
        for x in 0..ww {
            if role[(y * ww + x) as usize] != RING {
                continue;
            }
            let target = image.get((wx0 + x) as u32, (wy0 + y) as u32);
            let source = image.get((wx0 + x + offset.0) as u32, (wy0 + y + offset.1) as u32);
            for channel in 0..4 {
                let difference = target[channel] as f64 - source[channel] as f64;
                sum += difference * difference;
            }
            count += 1;
        }
    }
    if count == 0 {
        None
    } else {
        Some(sum / count as f64)
    }
}

/// Solves for smooth values over HOLE pixels, fixed to the RING values around them. A coarser
/// copy is solved first and used as the starting point, so large spots settle in few passes.
fn heal_solve(value: &mut [f32], role: &[u8], w: usize, h: usize, depth: u32) {
    let mut iterations = 300;
    if w > 32 && h > 32 && depth < 16 {
        let cw = w.div_ceil(2);
        let ch = h.div_ceil(2);
        let mut coarse = vec![0f32; cw * ch * 4];
        let mut coarse_role = vec![OUTSIDE; cw * ch];
        let mut usable = false;
        for y in 0..ch {
            for x in 0..cw {
                let mut known = 0;
                let mut hole = 0;
                let mut known_sum = [0f32; 4];
                let mut hole_sum = [0f32; 4];
                for j in 0..2 {
                    for i in 0..2 {
                        let fx = x * 2 + i;
                        let fy = y * 2 + j;
                        if fx >= w || fy >= h {
                            continue;
                        }
                        let p = fy * w + fx;
                        if role[p] == RING {
                            known += 1;
                            for channel in 0..4 {
                                known_sum[channel] += value[p * 4 + channel];
                            }
                        } else if role[p] == HOLE {
                            hole += 1;
                            for channel in 0..4 {
                                hole_sum[channel] += value[p * 4 + channel];
                            }
                        }
                    }
                }
                let q = y * cw + x;
                if known > 0 {
                    coarse_role[q] = RING;
                    for channel in 0..4 {
                        coarse[q * 4 + channel] = known_sum[channel] / known as f32;
                    }
                } else if hole > 0 {
                    coarse_role[q] = HOLE;
                    for channel in 0..4 {
                        coarse[q * 4 + channel] = hole_sum[channel] / hole as f32;
                    }
                }
                usable = true;
            }
        }
        if usable {
            heal_solve(&mut coarse, &coarse_role, cw, ch, depth + 1);
            for y in 0..h {
                for x in 0..w {
                    let p = y * w + x;
                    let q = (y / 2) * cw + x / 2;
                    if role[p] == HOLE && coarse_role[q] == HOLE {
                        for channel in 0..4 {
                            value[p * 4 + channel] = coarse[q * 4 + channel];
                        }
                    }
                }
            }
            iterations = 40;
        }
    }
    const OMEGA: f32 = 1.8;
    for _ in 0..iterations {
        for y in 0..h {
            for x in 0..w {
                let p = y * w + x;
                if role[p] != HOLE {
                    continue;
                }
                let mut sum = [0f32; 4];
                let mut count = 0;
                let neighbors = [
                    (x as i64 - 1, y as i64),
                    (x as i64 + 1, y as i64),
                    (x as i64, y as i64 - 1),
                    (x as i64, y as i64 + 1),
                ];
                for (nx, ny) in neighbors {
                    if nx < 0 || ny < 0 || nx >= w as i64 || ny >= h as i64 {
                        continue;
                    }
                    let q = ny as usize * w + nx as usize;
                    if role[q] == OUTSIDE {
                        continue;
                    }
                    for channel in 0..4 {
                        sum[channel] += value[q * 4 + channel];
                    }
                    count += 1;
                }
                if count == 0 {
                    continue;
                }
                for channel in 0..4 {
                    value[p * 4 + channel] += OMEGA * (sum[channel] / count as f32 - value[p * 4 + channel]);
                }
            }
        }
    }
}

/// Content-aware fill: repaints the selected pixels from the rest of the image, growing
/// outward from the selection's edge and copying the best-matching patch it can find.
/// Returns false when the image has no usable source pixels at all.
pub fn content_fill(image: &mut Bitmap8, selection: &Gray8) -> Result<bool> {
    if image.width() != selection.width() || image.height() != selection.height() {
        return Err(Error::BufferSize {
            got: selection.byte_len(),
            expected: image.pixel_count(),
            width: image.width(),
            height: image.height(),
        });
    }
    let w = image.width() as usize;
    let h = image.height() as usize;
    if w == 0 || h == 0 {
        return Ok(false);
    }
    let n = w * h;
    let mut known = vec![false; n];
    let mut target = vec![false; n];
    let mut valid = vec![false; n];
    let mut queued = vec![false; n];
    let mut donors: Vec<usize> = Vec::new();
    let mut queue: Vec<usize> = Vec::new();
    let mut chosen: Vec<i64> = vec![-1; n];
    let radius = if w >= 5 && h >= 5 { 2i64 } else { 0 };
    let mut missing = 0usize;
    // Selected pixels are filled. Unselected opaque pixels are the image to match and copy
    // from; unselected transparent ones are neither, and are left alone.
    for y in 0..h {
        for x in 0..w {
            let p = y * w + x;
            target[p] = selection.get(x as u32, y as u32) != 0;
            known[p] = !target[p] && image.get(x as u32, y as u32)[3] == 255;
            if target[p] {
                missing += 1;
            }
        }
    }
    if missing == 0 {
        return Ok(true);
    }
    for y in 0..h {
        for x in 0..w {
            let p = y * w + x;
            if !known[p] {
                continue;
            }
            let mut usable = true;
            for dy in -radius..=radius {
                for dx in -radius..=radius {
                    let sx = x as i64 + dx;
                    let sy = y as i64 + dy;
                    if sx < 0 || sy < 0 || sx >= w as i64 || sy >= h as i64 || !known[sy as usize * w + sx as usize] {
                        usable = false;
                        break;
                    }
                }
                if !usable {
                    break;
                }
            }
            if usable {
                valid[p] = true;
                donors.push(p);
            }
        }
    }
    if donors.is_empty() {
        return Ok(false);
    }
    for y in 0..h {
        for x in 0..w {
            let p = y * w + x;
            if !target[p] {
                continue;
            }
            let touches_known = (x > 0 && known[p - 1])
                || (x + 1 < w && known[p + 1])
                || (y > 0 && known[p - w])
                || (y + 1 < h && known[p + w]);
            if touches_known {
                queue.push(p);
                queued[p] = true;
            }
        }
    }
    let mut random = 0x6d2b_79f5u32;
    // The head carries across the restart below, as it does in the C kernel: already filled
    // pixels are never revisited with a second donor.
    let mut head = 0usize;
    loop {
        while head < queue.len() {
            let p = queue[head];
            head += 1;
            let x = p % w;
            let y = p / w;
            let mut best: i64 = -1;
            let mut score = f64::MAX;
            let neighbors = [
                if x > 0 { Some(p - 1) } else { None },
                if x + 1 < w { Some(p + 1) } else { None },
                if y > 0 { Some(p - w) } else { None },
                if y + 1 < h { Some(p + w) } else { None },
            ];
            // Propagate coherent source offsets, then refine with a randomized patch search.
            for attempt in 0..28 {
                let candidate: i64 = if attempt < 4 {
                    match neighbors[attempt] {
                        Some(neighbor) => {
                            let base = if chosen[neighbor] >= 0 { chosen[neighbor] } else { neighbor as i64 };
                            base + (p as i64 - neighbor as i64)
                        }
                        None => -1,
                    }
                } else {
                    donors[(next_random(&mut random) as usize) % donors.len()] as i64
                };
                if candidate < 0 || candidate as usize >= n || !valid[candidate as usize] {
                    continue;
                }
                let candidate = candidate as usize;
                let Some(found) = patch_match(image, &known, w, h, p, candidate, radius) else {
                    continue;
                };
                if best < 0 || found < score {
                    score = found;
                    best = candidate as i64;
                }
            }
            if best < 0 {
                best = donors[0] as i64;
            }
            let mut scale = 64i64;
            while scale >= 1 {
                let offset_x = (next_random(&mut random) % (2 * scale + 1) as u32) as i64 - scale;
                let offset_y = (next_random(&mut random) % (2 * scale + 1) as u32) as i64 - scale;
                let qx = best % w as i64 + offset_x;
                let qy = best / w as i64 + offset_y;
                if qx >= 0 && qy >= 0 && qx < w as i64 && qy < h as i64 && valid[qy as usize * w + qx as usize] {
                    let candidate = qy as usize * w + qx as usize;
                    if let Some(found) = patch_match(image, &known, w, h, p, candidate, radius) {
                        if found < score {
                            score = found;
                            best = candidate as i64;
                        }
                    }
                }
                scale /= 2;
            }
            let source = best as usize;
            let source_pixel = image.get((source % w) as u32, (source / w) as u32);
            image.set(x as u32, y as u32, source_pixel);
            known[p] = true;
            chosen[p] = best;
            for neighbor in neighbors.into_iter().flatten() {
                if target[neighbor] && !known[neighbor] && !queued[neighbor] {
                    queued[neighbor] = true;
                    queue.push(neighbor);
                }
            }
        }
        // A selected area that only transparency touches starts from a donor and spreads.
        let mut scan = 0usize;
        while scan < n && (!target[scan] || known[scan]) {
            scan += 1;
        }
        if scan >= n {
            break;
        }
        if !queued[scan] {
            queued[scan] = true;
            queue.push(scan);
        }
    }
    Ok(true)
}

fn next_random(state: &mut u32) -> u32 {
    *state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
    *state
}

/// Mean squared difference between the neighborhoods of two pixels, over the pixels that are
/// already known.
fn patch_match(image: &Bitmap8, known: &[bool], w: usize, h: usize, p: usize, q: usize, radius: i64) -> Option<f64> {
    let px = (p % w) as i64;
    let py = (p / w) as i64;
    let qx = (q % w) as i64;
    let qy = (q / w) as i64;
    let mut sum = 0.0;
    let mut count = 0i64;
    for dy in -radius..=radius {
        for dx in -radius..=radius {
            let x = px + dx;
            let y = py + dy;
            let sx = qx + dx;
            let sy = qy + dy;
            if x < 0 || y < 0 || x >= w as i64 || y >= h as i64 {
                continue;
            }
            if sx < 0 || sy < 0 || sx >= w as i64 || sy >= h as i64 {
                continue;
            }
            if !known[y as usize * w + x as usize] {
                continue;
            }
            let a = image.get(x as u32, y as u32);
            let b = image.get(sx as u32, sy as u32);
            for channel in 0..4 {
                let difference = a[channel] as f64 - b[channel] as f64;
                sum += difference * difference;
            }
            count += 1;
        }
    }
    if count == 0 {
        None
    } else {
        Some(sum / count as f64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn point(x: f64, y: f64) -> PointF {
        PointF::new(x, y)
    }

    fn textured(size: u32) -> Bitmap8 {
        let mut image = Bitmap8::new(size, size);
        for y in 0..size {
            for x in 0..size {
                let value = if (x / 2 + y / 2) % 2 == 0 { [200, 200, 200, 255] } else { [60, 60, 60, 255] };
                image.set(x, y, value);
            }
        }
        image
    }

    #[test]
    fn a_clone_stroke_copies_the_offset_region() {
        let mut source = Bitmap8::new(32, 32);
        for y in 12..16 {
            for x in 16..20 {
                source.set(x, y, [255, 0, 0, 255]);
            }
        }
        let mut target = Bitmap8::new(32, 32);
        let outcome = clone_stamp(&mut target, &source, &Brush::new(4.0), &[point(4.5, 12.5)], (12, 0)).expect("clone");
        assert_eq!(target.get(4, 12), [255, 0, 0, 255]);
        assert_eq!(target.get(5, 12), [255, 0, 0, 255]);
        assert_eq!(target.get(3, 12)[3], 0, "the sample does not reach that far left");
        assert_eq!(target.get(0, 0)[3], 0);
        assert!(outcome.bounds.is_some());
        // A sample that does not reach the target leaves it alone.
        let mut untouched = Bitmap8::new(32, 32);
        clone_stamp(&mut untouched, &source, &Brush::new(4.0), &[point(4.5, 12.5)], (-40, 0)).expect("clone");
        assert_eq!(untouched.get(4, 12)[3], 0);
        // Clone Stamp obeys a selection like any other stroke.
        let mut selection = Gray8::new(32, 32);
        for y in 0..32 {
            for x in 0..5 {
                selection.set(x, y, 255);
            }
        }
        let mut clipped = Bitmap8::new(32, 32);
        clone_stamp_clipped(&mut clipped, &source, &Brush::new(4.0), &[point(4.5, 12.5)], (12, 0), Some(&selection))
            .expect("clone");
        assert_eq!(clipped.get(4, 12), [255, 0, 0, 255], "inside the selection");
        assert_eq!(clipped.get(5, 12)[3], 0, "outside the selection");
    }

    #[test]
    fn aligned_strokes_keep_the_first_offset_and_unaligned_ones_do_not() {
        let mut state = CloneState::new();
        assert_eq!(state.begin_stroke(point(10.0, 10.0), true), None);
        state.set_source(point(100.0, 50.0));
        assert_eq!(state.source(), Some(point(100.0, 50.0)));
        assert_eq!(state.begin_stroke(point(40.0, 50.0), true), Some((60, 0)));
        assert_eq!(state.sample_point(point(40.0, 50.0), true, true), Some(point(100.0, 50.0)));
        // A second aligned stroke keeps the first stroke's offset, wherever it starts.
        assert_eq!(state.begin_stroke(point(45.0, 50.0), true), Some((60, 0)));
        // Until a stroke fixes the offset, the crosshair sits on the source itself.
        let mut fresh = CloneState::new();
        fresh.set_source(point(12.0, 34.0));
        assert_eq!(fresh.sample_point(point(5.0, 5.0), true, false), Some(point(12.0, 34.0)));
        // Unaligned strokes run from the brush to the source every time.
        assert_eq!(fresh.begin_stroke(point(5.0, 5.0), false), Some((7, 29)));
        assert_eq!(fresh.begin_stroke(point(20.0, 5.0), false), Some((-8, 29)));
        // A new source starts a new alignment.
        fresh.set_source(point(7.0, 8.0));
        assert_eq!(fresh.offset(), None);
        // Half pixels round away from zero, as CGSize.rounded() does on macOS.
        assert_eq!(fresh.begin_stroke(point(7.5, 8.5), true), Some((-1, -1)));
        // A non-finite option-click is ignored.
        let mut guarded = CloneState::new();
        guarded.set_source(point(f64::NAN, 0.0));
        assert_eq!(guarded.source(), None);
    }

    #[test]
    fn spot_healing_rebuilds_a_spot_from_its_surroundings() {
        let mut image = textured(32);
        for y in 14..19 {
            for x in 14..19 {
                image.set(x, y, [0, 0, 0, 255]);
            }
        }
        let mut coverage = Gray8::new(32, 32);
        for y in 14..19 {
            for x in 14..19 {
                coverage.set(x, y, 255);
            }
        }
        spot_heal(&mut image, &coverage, HealMode::ContentAware, 1.0, 7).expect("heal");
        let healed = image.get(16, 16);
        assert_eq!(healed[3], 255);
        assert!(healed[0] > 60, "the blemish is gone, got {healed:?}");
        // The pixels around the spot keep their values.
        assert_eq!(image.get(10, 16), [60, 60, 60, 255]);
    }

    #[test]
    fn spot_healing_respects_its_coverage_and_opacity() {
        let mut untouched = textured(24);
        untouched.set(12, 12, [0, 0, 0, 255]);
        let before = untouched.clone();
        spot_heal(&mut untouched, &Gray8::new(24, 24), HealMode::CreateTexture, 1.0, 3).expect("heal");
        assert_eq!(untouched, before, "an empty coverage heals nothing");

        let heal_with = |amount: u8, opacity: f64| {
            let mut image = textured(24);
            image.set(12, 12, [0, 0, 0, 255]);
            let mut coverage = Gray8::new(24, 24);
            coverage.set(12, 12, amount);
            spot_heal(&mut image, &coverage, HealMode::CreateTexture, opacity, 3).expect("heal");
            image.get(12, 12)[0] as i32
        };
        let full = heal_with(255, 1.0);
        let half = heal_with(255, 0.5);
        let partial = heal_with(128, 1.0);
        // The blemish starts at black, so half the opacity heals half the distance.
        assert!((full - 2 * half).abs() <= 2, "full {full} vs half {half}");
        assert!(partial > 0 && partial < full, "a half-covered pixel heals half way: {partial} vs {full}");
        // A mismatched coverage is refused.
        assert!(spot_heal(&mut Bitmap8::new(8, 8), &Gray8::new(4, 4), HealMode::ContentAware, 1.0, 1).is_err());
    }

    #[test]
    fn content_fill_replaces_the_selection_from_the_rest_of_the_image() {
        let mut image = textured(16);
        for y in 6..10 {
            for x in 6..10 {
                image.set(x, y, [255, 0, 0, 255]);
            }
        }
        let mut selection = Gray8::new(16, 16);
        for y in 6..10 {
            for x in 6..10 {
                selection.set(x, y, 255);
            }
        }
        assert!(content_fill(&mut image, &selection).expect("fill"));
        for y in 6..10 {
            for x in 6..10 {
                let pixel = image.get(x, y);
                assert!(
                    pixel == [200, 200, 200, 255] || pixel == [60, 60, 60, 255],
                    "the block took its texture back at {x},{y}: {pixel:?}"
                );
            }
        }
        // The texture outside the block is untouched.
        assert_eq!(image.get(0, 0), [200, 200, 200, 255]);
    }

    #[test]
    fn content_fill_reports_when_there_is_nothing_to_copy_from() {
        // Everything outside the selection is transparent, so there are no donors.
        let mut image = Bitmap8::new(8, 8);
        for y in 2..6 {
            for x in 2..6 {
                image.set(x, y, [10, 20, 30, 255]);
            }
        }
        let mut selection = Gray8::new(8, 8);
        for y in 2..6 {
            for x in 2..6 {
                selection.set(x, y, 255);
            }
        }
        assert!(!content_fill(&mut image, &selection).expect("fill"));
        // Nothing selected is a no-op that reports success.
        let before = image.clone();
        assert!(content_fill(&mut image, &Gray8::new(8, 8)).expect("fill"));
        assert_eq!(image, before);
        assert!(content_fill(&mut Bitmap8::new(8, 8), &Gray8::new(4, 4)).is_err());
    }

    #[test]
    fn a_clone_stroke_reads_the_pixels_it_started_with() {
        let mut layer = Bitmap8::filled(24, 24, [30, 60, 90, 255]);
        let sample = layer.clone();
        clone_stamp(&mut layer, &sample, &Brush::new(6.0), &[point(6.5, 6.5)], (12, 0)).expect("clone");
        assert_eq!(layer.get(6, 6), [30, 60, 90, 255]);
        assert_eq!(layer.get(0, 0), [30, 60, 90, 255]);
    }
}
