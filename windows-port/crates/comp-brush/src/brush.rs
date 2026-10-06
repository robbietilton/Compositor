//! The brush engine: round tips, soft falloff, a per-stroke opacity cap and erasing.
//!
//! The stroke model follows the macOS engine (Document/BrushStroke.swift,
//! Rendering/BrushPixels.c, docs/brush-performance.md). Pointer samples are smoothed,
//! threaded through a centripetal Catmull-Rom spline and stamped as dabs at a fraction of
//! the tip diameter. Coverage for the *whole* stroke accumulates in its own buffer before
//! any color is applied; the paint is then composited once through that coverage at
//! `opacity`. Applying the color once is what keeps a self-crossing from darkening: a
//! crossing can reach full coverage, never more than the cap, because the color is never
//! laid down twice.
//!
//! Soft tips accumulate optical density and convert it with `coverage = 1 - exp(-density)`.
//! That is the closed form of source-over dabs at the deposition spacing, so paint depends
//! on the distance travelled rather than on how many pointer events arrived. Hard tips keep
//! their antialiased silhouette and take the maximum of the dabs covering a pixel.

use comp_core::{Bitmap8, Error, Gray8, PointF, Result};
use rayon::prelude::*;
use std::collections::BTreeMap;

/// Density cap from the macOS kernel. `1 - exp(-20)` rounds to full coverage.
const MAX_DENSITY: f64 = 20.0;
/// Width of a hard tip's antialiased rim, in pixels.
const EDGE_ANTIALIAS: f64 = 1.0;
/// Gaussian constant of the soft falloff, shared with BrushRaster.falloff.
const FALLOFF_K: f64 = 2.5;
/// A dab never sits closer than this to the previous one.
const MIN_SPACING_PIXELS: f64 = 0.25;
/// The options bar stops Size at 2000; strokes the app lays itself run a little wider.
pub const MAX_BRUSH_DIAMETER: f64 = 2100.0;
/// Flattest allowed zoom when converting the smoothing string to document pixels.
const MIN_ZOOM: f64 = 0.01;

/// Dab spacing as a fraction of the tip diameter. Hard tips are already solid, so they need
/// fewer dabs to look continuous than soft ones.
pub fn spacing_fraction(hardness: f64) -> f64 {
    if hardness >= 1.0 {
        0.015
    } else {
        0.025
    }
}

/// Brush settings, mirroring the macOS options bar plus `flow` and `spacing`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Brush {
    /// Tip diameter in document pixels.
    pub size: f64,
    /// 0-1: the solid core of the tip. 1 draws a hard, antialiased edge.
    pub hardness: f64,
    /// Dab spacing as a fraction of the diameter. 0 derives it from `hardness`, as macOS does.
    pub spacing: f64,
    /// 0-1: deposit strength of a single dab. Below 1, coverage builds along the stroke.
    pub flow: f64,
    /// 0-1: caps the paint the whole stroke can lay down, however often it crosses itself.
    pub opacity: f64,
    /// 0-100: length of the string the tip trails the pointer on, in screen points.
    pub smoothing: f64,
    /// Clears the layer's alpha instead of painting color.
    pub erase: bool,
}

impl Default for Brush {
    fn default() -> Self {
        Brush { size: 40.0, hardness: 1.0, spacing: 0.0, flow: 1.0, opacity: 1.0, smoothing: 0.0, erase: false }
    }
}

impl Brush {
    pub fn new(size: f64) -> Self {
        Brush { size, ..Brush::default() }
    }

    /// A soft round tip of `size` pixels and the given hardness.
    pub fn soft(size: f64, hardness: f64) -> Self {
        Brush { size, hardness, ..Brush::default() }
    }

    /// An eraser: the same tip, clearing alpha.
    pub fn eraser(size: f64) -> Self {
        Brush { size, erase: true, ..Brush::default() }
    }

    /// Distance between dabs in document pixels.
    pub fn spacing_pixels(&self) -> f64 {
        let fraction = if self.spacing > 0.0 { self.spacing } else { spacing_fraction(self.hardness) };
        (self.size * fraction.clamp(0.001, 1.0)).max(MIN_SPACING_PIXELS)
    }

    /// The smoothing string's length in document pixels. It is authored in screen points, so
    /// it feels the same however far the canvas is zoomed in.
    pub fn smoothing_pixels(&self, zoom: f64) -> f64 {
        if self.smoothing <= 0.0 {
            return 0.0;
        }
        self.smoothing / zoom.max(MIN_ZOOM)
    }

    /// Coverage of one dab at `distance` from its center: 1 inside the hardness radius,
    /// fading to 0 at the rim.
    pub fn tip_weight(&self, distance: f64) -> f64 {
        let radius = self.size / 2.0;
        if radius <= 0.0 || distance < 0.0 {
            return 0.0;
        }
        if self.hardness >= 1.0 {
            return ((radius - distance) / EDGE_ANTIALIAS + 0.5).clamp(0.0, 1.0);
        }
        let t = ((distance / radius - self.hardness) / (1.0 - self.hardness)).clamp(0.0, 1.0);
        ((-FALLOFF_K * t * t).exp() - (-FALLOFF_K).exp()) / (1.0 - (-FALLOFF_K).exp())
    }

    /// Optical density one dab adds at `distance`: the source-over coverage expressed as
    /// density, so that densities add and coverage is `1 - exp(-density)`.
    pub fn tip_density(&self, distance: f64) -> f64 {
        -(1.0 - self.tip_weight(distance)).max(0.001).ln()
    }

    /// Rejects settings the macOS app refuses, with the same limits.
    pub fn validate(&self) -> Result<()> {
        if !self.size.is_finite() || !self.hardness.is_finite() || !self.spacing.is_finite()
            || !self.flow.is_finite() || !self.opacity.is_finite() || !self.smoothing.is_finite()
        {
            return Err(Error::Invalid);
        }
        if !(1.0..=MAX_BRUSH_DIAMETER).contains(&self.size) {
            return Err(Error::TooLarge(format!("brush size {} is outside 1-{MAX_BRUSH_DIAMETER}", self.size)));
        }
        if !(0.0..=1.0).contains(&self.hardness) {
            return Err(Error::TooLarge(format!("brush hardness {} is outside 0-1", self.hardness)));
        }
        if !(0.0..=1.0).contains(&self.flow) {
            return Err(Error::TooLarge(format!("brush flow {} is outside 0-1", self.flow)));
        }
        if !(0.01..=1.0).contains(&self.opacity) {
            return Err(Error::TooLarge(format!("brush opacity {} is outside 0.01-1", self.opacity)));
        }
        if self.smoothing > 100.0 {
            return Err(Error::TooLarge(format!("brush smoothing {} is outside 0-100", self.smoothing)));
        }
        Ok(())
    }
}

/// How far a dab reaches from its center: the tip's radius plus the antialiased rim.
fn dab_reach(brush: &Brush) -> f64 {
    brush.size / 2.0 + EDGE_ANTIALIAS
}

/// The pixels a single dab at `at` can touch, as (x, y, width, height) in canvas coordinates,
/// before the canvas clip. A GUI uses this for the dirty rectangle of a click or a preview.
pub fn dab_bounds(brush: &Brush, at: PointF) -> (i64, i64, u32, u32) {
    if !brush.size.is_finite() || brush.size <= 0.0 || !at.is_finite() || at.x.abs() > 1.0e12 || at.y.abs() > 1.0e12 {
        return (0, 0, 0, 0);
    }
    let reach = dab_reach(brush);
    let min_x = (at.x - reach - 0.5).ceil();
    let min_y = (at.y - reach - 0.5).ceil();
    let max_x = (at.x + reach - 0.5).floor();
    let max_y = (at.y + reach - 0.5).floor();
    if max_x < min_x || max_y < min_y {
        return (0, 0, 0, 0);
    }
    (min_x as i64, min_y as i64, (max_x - min_x + 1.0) as u32, (max_y - min_y + 1.0) as u32)
}

/// Chord tolerance when a curve piece is flattened for deposition, in pixels. The macOS engine
/// flattens to 0.2 px for discrete dabs; a swept segment only has to stay within a fraction of a
/// pixel of the curve, and coarser chords mean fewer passes over the same pixels.
const CHORD_TOLERANCE: f64 = 0.5;

/// One straight piece of the path, the unit paint is deposited along.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Segment {
    a: PointF,
    b: PointF,
}

impl Segment {
    fn length(&self) -> f64 {
        ((self.b.x - self.a.x).powi(2) + (self.b.y - self.a.y).powi(2)).sqrt()
    }

    /// The segment's swept footprint in canvas pixels, before the canvas clip.
    fn bounds(&self, reach: f64) -> (i64, i64, i64, i64) {
        let min_x = (self.a.x.min(self.b.x) - reach - 0.5).ceil();
        let min_y = (self.a.y.min(self.b.y) - reach - 0.5).ceil();
        let max_x = (self.a.x.max(self.b.x) + reach - 0.5).floor();
        let max_y = (self.a.y.max(self.b.y) + reach - 0.5).floor();
        if !min_x.is_finite() || !min_y.is_finite() || !max_x.is_finite() || !max_y.is_finite() {
            return (0, 0, 0, 0);
        }
        (min_x as i64, min_y as i64, max_x as i64 + 1, max_y as i64 + 1)
    }
}

/// The radial profile of one brush as a lookup table over squared distance. A soft tip's optical
/// density costs a table read per sample instead of an exp; hard tips keep the exact arithmetic,
/// because their antialiased rim is one pixel wide and a table would quantize it.
struct ProfileLut {
    density: Vec<f32>,
    step: f64,
}

impl ProfileLut {
    fn new(brush: &Brush) -> ProfileLut {
        const ENTRIES: usize = 1024;
        let reach = dab_reach(brush);
        let mut density = vec![0f32; ENTRIES + 1];
        for (index, slot) in density.iter_mut().enumerate() {
            let distance = (reach * reach * index as f64 / ENTRIES as f64).sqrt();
            *slot = -(1.0 - brush.tip_weight(distance)).max(0.001).ln() as f32;
        }
        ProfileLut { density, step: reach * reach / ENTRIES as f64 }
    }

    /// Optical density at a squared distance, linearly interpolated; zero past the tip's reach.
    #[inline]
    fn density(&self, distance_squared: f64) -> f32 {
        let index = distance_squared / self.step;
        let base = index as usize;
        if base >= self.density.len() - 1 {
            return 0.0;
        }
        let low = self.density[base];
        low + (self.density[base + 1] - low) * (index - base as f64) as f32
    }
}

/// The whole path as deposition segments: every pair of samples becomes chords that stay within
/// `CHORD_TOLERANCE` of the spline. A click that never moved is one zero-length segment, which
/// deposits a single tip profile, exactly as the macOS kernel's zero-length case does.
fn stroke_segments(samples: &[PointF]) -> Vec<Segment> {
    let mut segments = Vec::new();
    if samples.is_empty() {
        return segments;
    }
    if samples.len() == 1 {
        segments.push(Segment { a: samples[0], b: samples[0] });
        return segments;
    }
    for index in 0..samples.len() - 1 {
        let start = samples[index];
        let end = samples[index + 1];
        let before = samples[index.saturating_sub(1)];
        let after = samples[(index + 2).min(samples.len() - 1)];
        piece_segments(start, end, before, after, &mut segments);
    }
    segments
}

/// Appends the deposition segments of one spline piece: the chords of its flattened curve.
fn piece_segments(start: PointF, end: PointF, before: PointF, after: PointF, out: &mut Vec<Segment>) {
    let mut polyline = Vec::with_capacity(8);
    polyline.push(start);
    subdivide_curve(start, end, before, after, CHORD_TOLERANCE, &mut polyline);
    for window in polyline.windows(2) {
        out.push(Segment { a: window[0], b: window[1] });
    }
}

/// Deposits one path segment into a stroke buffer whose top-left pixel is `(x0, y0)` on the canvas.
///
/// A soft tip integrates its optical density along the part of the segment inside the tip and
/// divides by the deposition spacing - the continuous form of the macOS kernel, so paint depends on
/// the distance travelled rather than on how the pointer happened to be sampled. A hard tip keeps
/// the swept silhouette instead, which is the same coverage as the maximum over dabs, without
/// stamping every dab: the nearest point of the segment is the nearest stamp.
///
/// Returns the pixels the segment could have touched, in canvas coordinates, or nil when it lies
/// outside the buffer.
fn deposit_segment(
    profile: &ProfileLut,
    brush: &Brush,
    soft: bool,
    values: &mut [f32],
    x0: i64,
    y0: i64,
    width: u32,
    height: u32,
    segment: Segment,
    spacing: f64,
) -> Option<(i64, i64, i64, i64)> {
    if width == 0 || height == 0 {
        return None;
    }
    let reach = dab_reach(brush);
    let reach_squared = reach * reach;
    let radius = (brush.size / 2.0).max(1e-6);
    let flow = brush.flow as f32;
    let (ax, ay) = (segment.a.x, segment.a.y);
    let abx = segment.b.x - ax;
    let aby = segment.b.y - ay;
    let length = (abx * abx + aby * aby).sqrt();
    let (bx0, by0, bx1, by1) = segment.bounds(reach);
    let min_x = bx0.max(x0);
    let min_y = by0.max(y0);
    let max_x = bx1.min(x0 + width as i64);
    let max_y = by1.min(y0 + height as i64);
    if max_x <= min_x || max_y <= min_y {
        return None;
    }
    let stride = width as usize;
    let first_row = (min_y - y0) as usize;
    let last_row = (max_y - y0) as usize;
    let (column_from, column_to) = ((min_x - x0) as usize, (max_x - x0) as usize);
    let rows = &mut values[first_row * stride..last_row * stride];
    // One row is independent of every other, so the work spreads over the cores; the value a pixel
    // ends up with depends only on the order of the segments, which stays sequential.
    if length <= 1e-12 {
        // A click that never moved: one tip's worth of paint, the kernel's zero-length case.
        rows.par_chunks_mut(stride).enumerate().for_each(|(offset, row)| {
            let py = (min_y + offset as i64) as f64 + 0.5;
            let dy = py - ay;
            for (index, slot) in row[column_from..column_to].iter_mut().enumerate() {
                let px = (min_x + index as i64) as f64 + 0.5;
                let dx = px - ax;
                let distance_squared = dx * dx + dy * dy;
                if distance_squared > reach_squared {
                    continue;
                }
                if soft {
                    *slot += profile.density(distance_squared) * flow;
                } else {
                    let weight = brush.tip_weight(distance_squared.sqrt());
                    if weight > 0.0 {
                        *slot = slot.max(flow * weight as f32);
                    }
                }
            }
        });
    } else if soft {
        // The optical density is integrated along the segment and divided by the deposition
        // spacing: how much paint this pixel gained from travelling past it. The quadrature samples
        // the segment at most a quarter of the tip's radius apart, so paint cannot step over a
        // pixel the tip swept. A fixed number of samples does not survive a long chord: a straight
        // line is one chord however long it is, and four samples over a hundred pixels step right
        // over everything a small tip would have covered.
        //
        // Each pixel only reads the samples within the tip of it, which is what the clip below
        // does; the samples outside that range would read zero from the profile table anyway, so
        // the sum is the same one, and it costs a fixed handful of reads per pixel.
        let sample_step = (0.25 * radius).max(1e-6);
        let samples = ((length / sample_step).ceil() as usize).max(1);
        let sample_spacing = length / samples as f64;
        let scale = flow * (sample_spacing / spacing) as f32;
        let (ux, uy) = (abx / length, aby / length);
        rows.par_chunks_mut(stride).enumerate().for_each(|(offset, row)| {
            let py = (min_y + offset as i64) as f64 + 0.5;
            let dy = py - ay;
            for (index, slot) in row[column_from..column_to].iter_mut().enumerate() {
                let px = (min_x + index as i64) as f64 + 0.5;
                let dx = px - ax;
                let along = dx * ux + dy * uy;
                let perpendicular_squared = dx * dx + dy * dy - along * along;
                if perpendicular_squared > reach_squared {
                    continue;
                }
                let half = (reach_squared - perpendicular_squared).max(0.0).sqrt();
                let first = ((along - half).max(0.0) / sample_spacing).floor() as usize;
                let last = (((along + half).min(length) / sample_spacing).ceil() as usize).min(samples);
                let mut sum = 0.0;
                for sample in first..last {
                    let offset = (sample as f64 + 0.5) * sample_spacing - along;
                    sum += profile.density(perpendicular_squared + offset * offset);
                }
                *slot += sum * scale;
            }
        });
    } else {
        // A hard tip keeps its antialiased silhouette: the swept coverage is the silhouette at the
        // nearest point of the segment, which is the same coverage as stamping every dab.
        let (ux, uy) = (abx / length, aby / length);
        rows.par_chunks_mut(stride).enumerate().for_each(|(offset, row)| {
            let py = (min_y + offset as i64) as f64 + 0.5;
            let dy = py - ay;
            for (index, slot) in row[column_from..column_to].iter_mut().enumerate() {
                let px = (min_x + index as i64) as f64 + 0.5;
                let dx = px - ax;
                let along = (dx * ux + dy * uy).clamp(0.0, length);
                let ex = dx - along * ux;
                let ey = dy - along * uy;
                let distance_squared = ex * ex + ey * ey;
                if distance_squared > reach_squared {
                    continue;
                }
                let weight = brush.tip_weight(distance_squared.sqrt());
                if weight > 0.0 {
                    *slot = slot.max(flow * weight as f32);
                }
            }
        });
    }
    Some((min_x, min_y, max_x - 1, max_y - 1))
}

/// What a stroke paints through its coverage.
pub(crate) enum PaintSource<'a> {
    /// One color for the whole stroke.
    Solid([u8; 4]),
    /// Pixels copied from `image` shifted by `offset`: Clone Stamp.
    Sampled { image: &'a Bitmap8, offset: (i64, i64) },
}

/// What a stroke call touched.
///
/// @bounds@ and @changed@ describe this call alone, which is what a GUI repaints from. The
/// counts are cumulative for the stroke so far: a batch call lays the whole stroke at once,
/// while a @StrokeSession@ keeps counting across its @extend@ calls.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct StrokeOutcome {
    /// The pixels this call changed, in the target's coordinates. Nil when it changed none.
    pub bounds: Option<(i64, i64, u32, u32)>,
    /// True when this call wrote at least one pixel.
    pub changed: bool,
    /// Dabs laid by the stroke so far.
    pub dab_count: usize,
    /// Path length walked by the stroke so far, in thousandths of a pixel.
    pub path_length_milli: u64,
}

impl StrokeOutcome {
    /// Total length of the stamped path, in document pixels.
    pub fn path_length(&self) -> f64 {
        self.path_length_milli as f64 / 1000.0
    }
}

/// A stroke's accumulated coverage over the part of the canvas it reached.
struct Coverage {
    x0: i64,
    y0: i64,
    width: u32,
    height: u32,
    values: Vec<f32>,
    soft: bool,
    dab_count: usize,
    path_length: f64,
}

impl Coverage {
    fn value(&self, x: i64, y: i64) -> f64 {
        let index = (y - self.y0) as usize * self.width as usize + (x - self.x0) as usize;
        combined_coverage(self.values[index], 0.0, self.soft)
    }
}

/// Paints, selects and transforms a document's pixels.
pub struct BrushEngine {
    pub brush: Brush,
    /// Paint color, straight alpha.
    pub color: [u8; 4],
    /// Canvas zoom, which scales the smoothing string into document pixels.
    pub zoom: f64,
}

impl BrushEngine {
    pub fn new(brush: Brush) -> Self {
        BrushEngine { brush, color: [0, 0, 0, 255], zoom: 1.0 }
    }

    pub fn with_color(mut self, color: [u8; 4]) -> Self {
        self.color = color;
        self
    }

    pub fn with_zoom(mut self, zoom: f64) -> Self {
        self.zoom = if zoom.is_finite() { zoom } else { 1.0 };
        self
    }

    /// Paints a stroke through `points`, in document pixels.
    pub fn stroke(&self, target: &mut Bitmap8, points: &[PointF]) -> Result<StrokeOutcome> {
        self.stroke_clipped(target, points, None)
    }

    /// Paints a stroke limited to `selection` (nil paints everywhere).
    pub fn stroke_clipped(
        &self,
        target: &mut Bitmap8,
        points: &[PointF],
        selection: Option<&Gray8>,
    ) -> Result<StrokeOutcome> {
        self.brush.validate()?;
        check_selection(target, selection)?;
        let paint = PaintSource::Solid(self.color);
        let smoothing = self.brush.smoothing_pixels(self.zoom);
        paint_stroke(target, &self.brush, points, paint, selection, smoothing)
    }

    /// The stroke's coverage as a canvas-sized mask, 0-255. Spot Healing and content-aware
    /// fills read this instead of the painted color.
    pub fn coverage_mask(&self, width: u32, height: u32, points: &[PointF]) -> Result<Gray8> {
        self.brush.validate()?;
        let smoothing = self.brush.smoothing_pixels(self.zoom);
        coverage_mask(&self.brush, width, height, points, smoothing)
    }

    /// Starts an incremental stroke: one `extend` per pointer sample, `finish` at mouse-up.
    /// The pixels end up exactly where one `stroke` of the same path would have put them.
    pub fn begin_stroke(&self, start: PointF) -> Result<StrokeSession> {
        self.brush.validate()?;
        if !start.is_finite() {
            return Err(Error::Invalid);
        }
        Ok(StrokeSession::begin(&self.brush, start).with_color(self.color).with_zoom(self.zoom))
    }
}

/// The coverage a `brush` stroke would leave over a `width` x `height` canvas.
pub fn coverage_mask(
    brush: &Brush,
    width: u32,
    height: u32,
    points: &[PointF],
    smoothing_pixels: f64,
) -> Result<Gray8> {
    let mut mask = Gray8::new(width, height);
    let Some(coverage) = build_coverage(brush, width, height, points, smoothing_pixels)? else {
        return Ok(mask);
    };
    for y in 0..coverage.height {
        for x in 0..coverage.width {
            let value = coverage.value(coverage.x0 + x as i64, coverage.y0 + y as i64);
            if value > 0.0 {
                let px = (coverage.x0 + x as i64) as u32;
                let py = (coverage.y0 + y as i64) as u32;
                mask.set(px, py, (value * 255.0).round().clamp(0.0, 255.0) as u8);
            }
        }
    }
    Ok(mask)
}

fn check_selection(target: &Bitmap8, selection: Option<&Gray8>) -> Result<()> {
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
    Ok(())
}

/// Stamps a brush along `points` and composites `paint` through the accumulated coverage.
pub(crate) fn paint_stroke(
    target: &mut Bitmap8,
    brush: &Brush,
    points: &[PointF],
    paint: PaintSource<'_>,
    selection: Option<&Gray8>,
    smoothing_pixels: f64,
) -> Result<StrokeOutcome> {
    let Some(coverage) = build_coverage(brush, target.width(), target.height(), points, smoothing_pixels)? else {
        return Ok(StrokeOutcome::default());
    };
    let mut outcome = StrokeOutcome {
        bounds: None,
        changed: false,
        dab_count: coverage.dab_count,
        path_length_milli: (coverage.path_length * 1000.0) as u64,
    };
    let mut min_x = i64::MAX;
    let mut min_y = i64::MAX;
    let mut max_x = i64::MIN;
    let mut max_y = i64::MIN;
    for y in 0..coverage.height as i64 {
        for x in 0..coverage.width as i64 {
            let cx = coverage.x0 + x;
            let cy = coverage.y0 + y;
            let value = coverage.value(cx, cy);
            if value <= 0.0 {
                continue;
            }
            let mut alpha = value * brush.opacity;
            if let Some(mask) = selection {
                alpha *= mask.get(cx as u32, cy as u32) as f64 / 255.0;
            }
            if alpha <= 0.0 {
                continue;
            }
            let px = cx as u32;
            let py = cy as u32;
            let dst = target.get(px, py);
            let blended = if brush.erase {
                composite_pixel(dst, dst, alpha, true)
            } else {
                let Some(source) = paint.at(cx, cy) else { continue };
                composite_pixel(dst, source, alpha, false)
            };
            target.set(px, py, blended);
            min_x = min_x.min(cx);
            min_y = min_y.min(cy);
            max_x = max_x.max(cx);
            max_y = max_y.max(cy);
        }
    }
    if max_x >= min_x {
        outcome.bounds = Some((min_x, min_y, (max_x - min_x + 1) as u32, (max_y - min_y + 1) as u32));
        outcome.changed = true;
    }
    Ok(outcome)
}

/// Resolution of the density-to-coverage table, and its span.
const COVERAGE_ENTRIES: usize = 4096;
const COVERAGE_SCALE: f64 = COVERAGE_ENTRIES as f64 / MAX_DENSITY;

/// Density to coverage, @1 - exp(-min(density, 20))@, as a table. The composite needs this per
/// pixel, and an exp there would dominate a large stroke; both the batch and the session read the
/// same table, so they cannot disagree.
fn coverage_table() -> &'static [f32; COVERAGE_ENTRIES + 1] {
    static TABLE: std::sync::OnceLock<[f32; COVERAGE_ENTRIES + 1]> = std::sync::OnceLock::new();
    TABLE.get_or_init(|| {
        let mut table = [0f32; COVERAGE_ENTRIES + 1];
        for (index, slot) in table.iter_mut().enumerate() {
            let density = index as f64 / COVERAGE_SCALE;
            *slot = (1.0 - (-density).exp()) as f32;
        }
        table
    })
}

/// Coverage from accumulated optical density: the closed form of source-over dabs, interpolated
/// out of the table.
#[inline]
fn coverage_from_density(density: f64) -> f64 {
    if density <= 0.0 {
        return 0.0;
    }
    let table = coverage_table();
    let index = density * COVERAGE_SCALE;
    let base = index as usize;
    if base >= COVERAGE_ENTRIES {
        return table[COVERAGE_ENTRIES] as f64;
    }
    let low = table[base] as f64;
    low + (table[base + 1] as f64 - low) * (index - base as f64)
}

/// A pixel's coverage from the stroke's two buffers: soft tips add densities, hard tips keep
/// the strongest silhouette.
fn combined_coverage(committed: f32, tail: f32, soft: bool) -> f64 {
    if soft {
        coverage_from_density(committed as f64 + tail as f64)
    } else {
        committed.max(tail).clamp(0.0, 1.0) as f64
    }
}

/// One pixel of paint through coverage. The batch stroke and the incremental session share this
/// so their pixels cannot drift apart.
fn composite_pixel(base: [u8; 4], source: [u8; 4], alpha: f64, erase: bool) -> [u8; 4] {
    if alpha <= 0.0 {
        return base;
    }
    if erase {
        // Erasing takes coverage out of the alpha; the straight color stays, so a later edit
        // restores the pixel's color instead of a black fringe.
        let remaining = base[3] as f64 / 255.0 * (1.0 - alpha);
        [base[0], base[1], base[2], (remaining * 255.0).round().clamp(0.0, 255.0) as u8]
    } else if source[3] == 255 && base[3] == 255 {
        // Opaque paint over an opaque pixel: the composite keeps full alpha, so the general
        // source-over reduces to a lerp and the division drops out. The arithmetic is the same
        // one, so the pixels do not depend on which branch ran.
        let keep = 1.0 - alpha;
        [
            (source[0] as f64 * alpha + base[0] as f64 * keep).round().clamp(0.0, 255.0) as u8,
            (source[1] as f64 * alpha + base[1] as f64 * keep).round().clamp(0.0, 255.0) as u8,
            (source[2] as f64 * alpha + base[2] as f64 * keep).round().clamp(0.0, 255.0) as u8,
            255,
        ]
    } else {
        source_over(source, base, alpha)
    }
}

impl PaintSource<'_> {
    /// The source pixel for a target pixel, or nil where the sample does not reach.
    fn at(&self, x: i64, y: i64) -> Option<[u8; 4]> {
        match self {
            PaintSource::Solid(rgba) => Some(*rgba),
            PaintSource::Sampled { image, offset } => {
                let sx = x + offset.0;
                let sy = y + offset.1;
                if sx < 0 || sy < 0 || sx >= image.width() as i64 || sy >= image.height() as i64 {
                    None
                } else {
                    Some(image.get(sx as u32, sy as u32))
                }
            }
        }
    }
}

/// Source-over with straight alpha: what the compositor does, restricted to one pixel.
pub(crate) fn source_over(src: [u8; 4], dst: [u8; 4], alpha: f64) -> [u8; 4] {
    let sa = src[3] as f64 / 255.0 * alpha;
    let da = dst[3] as f64 / 255.0;
    let out_a = sa + da * (1.0 - sa);
    if out_a <= 0.0 {
        return [0, 0, 0, 0];
    }
    let mut out = [0u8; 4];
    for channel in 0..3 {
        let value = (src[channel] as f64 * sa + dst[channel] as f64 * da * (1.0 - sa)) / out_a;
        out[channel] = value.round().clamp(0.0, 255.0) as u8;
    }
    out[3] = (out_a * 255.0).round().clamp(0.0, 255.0) as u8;
    out
}

/// Follows the pointer on a string `radius` pixels long: the tip only moves once the pointer
/// pulls the string taut. Slack movement is dropped, which is the point of the setting.
pub fn smooth_path(points: &[PointF], radius: f64) -> Vec<PointF> {
    if points.is_empty() {
        return Vec::new();
    }
    if radius <= 0.0 {
        return points.to_vec();
    }
    let mut result = Vec::with_capacity(points.len());
    let mut anchor = points[0];
    result.push(anchor);
    for point in &points[1..] {
        if !point.is_finite() {
            continue;
        }
        let dx = point.x - anchor.x;
        let dy = point.y - anchor.y;
        let distance = (dx * dx + dy * dy).sqrt();
        if distance <= radius {
            continue;
        }
        let step = (distance - radius) / distance;
        anchor = PointF::new(anchor.x + dx * step, anchor.y + dy * step);
        result.push(anchor);
    }
    // Smoothing leaves the tip short of the pointer; the stroke still ends where the hand did.
    if let Some(last) = points.last() {
        if last.is_finite() && result.last() != Some(last) {
            result.push(*last);
        }
    }
    result
}

/// The centripetal Catmull-Rom through `samples`, flattened to within 0.2 pixels of the curve.
pub fn spline_path(samples: &[PointF]) -> Vec<PointF> {
    if samples.len() < 2 {
        return samples.to_vec();
    }
    let mut path = Vec::with_capacity(samples.len() * 4);
    path.push(samples[0]);
    for index in 0..samples.len() - 1 {
        let start = samples[index];
        let end = samples[index + 1];
        let before = samples[index.saturating_sub(1)];
        let after = samples[(index + 2).min(samples.len() - 1)];
        subdivide_curve(start, end, before, after, SPLINE_TOLERANCE, &mut path);
    }
    path
}

fn knot(t: f64, a: PointF, b: PointF) -> f64 {
    t + ((b.x - a.x).powi(2) + (b.y - a.y).powi(2)).sqrt().max(0.0001)
}

fn mix(a: PointF, b: PointF, ta: f64, tb: f64, t: f64) -> PointF {
    let wa = (tb - t) / (tb - ta);
    let wb = (t - ta) / (tb - ta);
    PointF::new(a.x * wa + b.x * wb, a.y * wa + b.y * wb)
}

/// Appends the spline from `start` (already in `out`) to `end`, subdivided so the polyline
/// never strays more than `tolerance` pixels from the curve.
fn subdivide_curve(start: PointF, end: PointF, before: PointF, after: PointF, tolerance: f64, out: &mut Vec<PointF>) {
    let t0 = 0.0;
    let t1 = knot(t0, before, start);
    let t2 = knot(t1, start, end);
    let t3 = knot(t2, end, after);
    let point = |u: f64| -> PointF {
        if u <= 0.0 {
            return start;
        }
        if u >= 1.0 {
            return end;
        }
        let t = t1 + (t2 - t1) * u;
        let a = mix(before, start, t0, t1, t);
        let b = mix(start, end, t1, t2, t);
        let c = mix(end, after, t2, t3, t);
        mix(mix(a, b, t0, t2, t), mix(b, c, t1, t3, t), t1, t2, t)
    };
    fn step(
        from: PointF,
        to: PointF,
        lo: f64,
        hi: f64,
        depth: u32,
        tolerance: f64,
        point: &impl Fn(f64) -> PointF,
        out: &mut Vec<PointF>,
    ) {
        let dx = to.x - from.x;
        let dy = to.y - from.y;
        let length_squared = dx * dx + dy * dy;
        let error = |p: PointF| -> f64 {
            let t = if length_squared > 0.0 {
                (((p.x - from.x) * dx + (p.y - from.y) * dy) / length_squared).clamp(0.0, 1.0)
            } else {
                0.0
            };
            let ex = p.x - from.x - t * dx;
            let ey = p.y - from.y - t * dy;
            (ex * ex + ey * ey).sqrt()
        };
        let mid = (lo + hi) / 2.0;
        let middle = point(mid);
        let deviation = error(middle).max(error(point((lo + mid) / 2.0))).max(error(point((mid + hi) / 2.0)));
        if deviation <= tolerance || depth >= 10 {
            out.push(to);
            return;
        }
        step(from, middle, lo, mid, depth + 1, tolerance, point, out);
        step(middle, to, mid, hi, depth + 1, tolerance, point, out);
    }
    step(start, end, 0.0, 1.0, 0, tolerance, &point, out);
}

/// The tolerance `spline_path` flattens to: a fifth of a pixel, the macOS engine's own figure.
const SPLINE_TOLERANCE: f64 = 0.2;

/// Dab centers along a polyline, `spacing` pixels apart, carrying the leftover distance across
/// segment boundaries so the spacing does not restart at every corner.
pub fn place_dabs(path: &[PointF], spacing: f64) -> Vec<PointF> {
    let spacing = spacing.max(MIN_SPACING_PIXELS);
    let mut dabs = Vec::new();
    let mut previous: Option<PointF> = None;
    let mut distance_to_next = 0.0;
    for point in path {
        match previous {
            None => {
                dabs.push(*point);
                distance_to_next = spacing;
            }
            Some(prev) => {
                let dx = point.x - prev.x;
                let dy = point.y - prev.y;
                let length = (dx * dx + dy * dy).sqrt();
                if length > 0.0 {
                    let mut distance = distance_to_next;
                    while distance <= length {
                        dabs.push(PointF::new(prev.x + dx * distance / length, prev.y + dy * distance / length));
                        distance += spacing;
                    }
                    distance_to_next = distance - length;
                }
            }
        }
        previous = Some(*point);
    }
    dabs
}

fn build_coverage(
    brush: &Brush,
    target_width: u32,
    target_height: u32,
    points: &[PointF],
    smoothing_pixels: f64,
) -> Result<Option<Coverage>> {
    brush.validate()?;
    if target_width == 0 || target_height == 0 {
        return Ok(None);
    }
    let finite: Vec<PointF> = points.iter().copied().filter(|p| p.is_finite()).collect();
    if finite.is_empty() {
        return Ok(None);
    }
    let smoothed = smooth_path(&finite, smoothing_pixels);
    let segments = stroke_segments(&smoothed);
    if segments.is_empty() {
        return Ok(None);
    }
    let path_length: f64 = segments.iter().map(|segment| segment.length()).sum();
    let reach = dab_reach(brush);
    let mut min_x = f64::INFINITY;
    let mut min_y = f64::INFINITY;
    let mut max_x = f64::NEG_INFINITY;
    let mut max_y = f64::NEG_INFINITY;
    for segment in &segments {
        min_x = min_x.min(segment.a.x.min(segment.b.x) - reach);
        min_y = min_y.min(segment.a.y.min(segment.b.y) - reach);
        max_x = max_x.max(segment.a.x.max(segment.b.x) + reach);
        max_y = max_y.max(segment.a.y.max(segment.b.y) + reach);
    }
    let x0 = min_x.floor().max(0.0);
    let y0 = min_y.floor().max(0.0);
    let x1 = max_x.ceil().min(target_width as f64);
    let y1 = max_y.ceil().min(target_height as f64);
    if x1 <= x0 || y1 <= y0 {
        // The whole stroke lies off the canvas; nothing to accumulate.
        return Ok(None);
    }
    let x0 = x0 as i64;
    let y0 = y0 as i64;
    let width = (x1 as i64 - x0) as u32;
    let height = (y1 as i64 - y0) as u32;
    let soft = brush.hardness < 1.0;
    let profile = ProfileLut::new(brush);
    let spacing = brush.spacing_pixels();
    let mut values = vec![0f32; width as usize * height as usize];
    for segment in &segments {
        deposit_segment(&profile, brush, soft, &mut values, x0, y0, width, height, *segment, spacing);
    }
    Ok(Some(Coverage { x0, y0, width, height, values, soft, dab_count: segments.len(), path_length }))
}

/// Where a session's time went, in nanoseconds, over its whole life. Diagnostics: the counters
/// cost a couple of clock reads per pointer sample, far less than the pixels they measure.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct StrokeTiming {
    /// Walking the new path segments and accumulating their coverage.
    pub deposit_ns: u64,
    /// Rebuilding the changed pixels from the base and the coverage.
    pub composite_ns: u64,
    /// Growing the stroke's own buffer (inside the deposit phase).
    pub reserve_ns: u64,
    /// Pointer samples and finish calls counted.
    pub calls: u64,
}

/// A dirty rectangle in canvas pixel coordinates, inclusive.
type DirtyRect = (i64, i64, i64, i64);

/// Tile edge of a session's own buffers, in canvas pixels. Tiles are allocated the first time
/// paint reaches them and never move, so a stroke's cost follows the area it actually sweeps:
/// growing the stroke never copies a bigger buffer, and memory follows the painted area too.
/// 256 px is the same tile the macOS engine snapshots; small canvases use smaller tiles so a dab
/// does not allocate a quarter of a megabyte it will never fill.
fn tile_edge(target: &Bitmap8, brush: &Brush) -> i64 {
    let shorter = target.width().min(target.height()) as i64;
    // At least the tip's own width, so a wide brush does not sweep dozens of tiles per segment and
    // pay a parallel dispatch for each; never so coarse that a thin stroke reserves megabytes.
    let cover = (dab_reach(brush) * 2.0) as i64;
    (shorter / 8).max(cover).clamp(64, 512)
}

/// One tile of a stroke's buffers: the permanent density or silhouette, the provisional tail, and
/// the pixels the target held when the stroke began.
struct StrokeTile {
    values: Vec<f32>,
    tail: Vec<f32>,
    base: Vec<[u8; 4]>,
    width: usize,
    height: usize,
}

fn union_dirty(current: Option<DirtyRect>, other: DirtyRect) -> DirtyRect {
    match current {
        Some((x0, y0, x1, y1)) => (x0.min(other.0), y0.min(other.1), x1.max(other.2), y1.max(other.3)),
        None => other,
    }
}

fn merge_dirty(current: &mut Option<DirtyRect>, other: Option<DirtyRect>) {
    if let Some(rect) = other {
        *current = Some(union_dirty(*current, rect));
    }
}

fn rect_bounds(rect: Option<DirtyRect>) -> Option<(i64, i64, u32, u32)> {
    rect.map(|(x0, y0, x1, y1)| (x0, y0, (x1 - x0 + 1) as u32, (y1 - y0 + 1) as u32))
}

/// A stroke in progress, fed one pointer sample at a time.
///
/// A session keeps the stroke's own coverage instead of re-stamping the path, so `extend` only
/// adds coverage that is not there yet and never composites a pixel twice: crossing a stroke
/// with itself cannot deepen it, exactly as with one batch `BrushEngine::stroke`. Feeding a
/// path through a session and painting it in one call produce identical pixels, which is what
/// lets the GUI paint live and still agree with the batch result the rest of the app uses.
///
/// Only segments whose spline control points are all known are folded into the permanent
/// coverage. The newest segment sits in a second buffer as a provisional tail - the same split
/// the macOS engine makes between `permanent` and `preview` - because its curve changes when the
/// next sample arrives. `finish` promotes that tail, and the tail a finished stroke holds is
/// already the curve the batch version draws, so the last sample never needs repainting.
pub struct StrokeSession {
    brush: Brush,
    color: [u8; 4],
    smoothing_pixels: f64,
    soft: bool,
    spacing: f64,
    /// Set when the brush or a selection is unusable; the session then paints nothing.
    error: Option<Error>,
    /// The smoothing string's end, and the pointer path it has been pulled along.
    anchor: PointF,
    chain: Vec<PointF>,
    /// The newest pointer sample, which the finished path ends with.
    pending_raw: Option<PointF>,
    /// Pieces folded into the permanent coverage.
    committed: usize,
    /// The brush's radial profile, so a soft tip's density is a table read.
    profile: ProfileLut,
    /// Where the provisional tail starts, so it can be dropped and redrawn exactly.
    has_tail: bool,
    tail_dabs: usize,
    tail_length: f64,
    tail_touched: Option<DirtyRect>,
    /// The stroke's own coverage, in tiles allocated as the paint reaches them.
    tiles: BTreeMap<(i64, i64), StrokeTile>,
    /// Tile edge for this stroke, taken from the first target it paints into.
    tile: i64,
    dabs: usize,
    length: f64,
    touched: Option<DirtyRect>,
    timing: StrokeTiming,
}

impl StrokeSession {
    /// Starts a stroke at `start`.
    ///
    /// An out-of-range brush is recorded and reported by `error`; `BrushEngine::begin_stroke`
    /// refuses it up front for callers that would rather handle the error where it happens.
    pub fn begin(brush: &Brush, start: PointF) -> Self {
        StrokeSession {
            brush: *brush,
            color: [0, 0, 0, 255],
            smoothing_pixels: brush.smoothing_pixels(1.0),
            soft: brush.hardness < 1.0,
            spacing: brush.spacing_pixels(),
            error: brush.validate().err(),
            anchor: start,
            chain: vec![start],
            pending_raw: None,
            committed: 0,
            profile: ProfileLut::new(brush),
            has_tail: false,
            tail_dabs: 0,
            tail_length: 0.0,
            tail_touched: None,
            tiles: BTreeMap::new(),
            tile: 0,
            dabs: 0,
            length: 0.0,
            touched: None,
            timing: StrokeTiming::default(),
        }
    }

    /// Where this session's time has gone so far, for a benchmark or a diagnostics overlay.
    pub fn timing(&self) -> StrokeTiming {
        self.timing
    }

    pub fn with_color(mut self, color: [u8; 4]) -> Self {
        self.color = color;
        self
    }

    /// The canvas zoom, which turns the smoothing string from screen points into pixels. Set it
    /// before the first `extend`: it shapes the path the samples are threaded through.
    pub fn with_zoom(mut self, zoom: f64) -> Self {
        self.smoothing_pixels = self.brush.smoothing_pixels(if zoom.is_finite() { zoom } else { 1.0 });
        self
    }

    pub fn brush(&self) -> &Brush {
        &self.brush
    }

    /// Nil unless the brush or a selection was refused; the session paints nothing then.
    pub fn error(&self) -> Option<&Error> {
        self.error.as_ref()
    }

    /// Dabs laid so far.
    pub fn dab_count(&self) -> usize {
        self.dabs + self.tail_dabs
    }

    /// Path length walked so far, in document pixels.
    pub fn path_length(&self) -> f64 {
        self.length + self.tail_length
    }

    /// Every pixel the stroke has changed since it began.
    pub fn bounds(&self) -> Option<(i64, i64, u32, u32)> {
        rect_bounds(self.touched)
    }

    /// Appends a pointer sample and paints whatever that added. Returns only the pixels this
    /// call changed.
    pub fn extend(&mut self, target: &mut Bitmap8, to: PointF) -> StrokeOutcome {
        self.extend_clipped(target, to, None)
    }

    /// `extend` limited to a selection: coverage outside it is never painted.
    pub fn extend_clipped(&mut self, target: &mut Bitmap8, to: PointF, selection: Option<&Gray8>) -> StrokeOutcome {
        if self.error.is_some() {
            return self.outcome(None);
        }
        if let Err(error) = check_selection(target, selection) {
            self.error = Some(error);
            return self.outcome(None);
        }
        if !to.is_finite() {
            return self.outcome(None);
        }
        if self.tile <= 0 {
            self.tile = tile_edge(target, &self.brush);
        }
        let started = std::time::Instant::now();
        // The provisional tail is redrawn from scratch, so its pixels become dirty again.
        let mut touched = self.drop_tail();
        if self.smoothing_pixels > 0.0 {
            let dx = to.x - self.anchor.x;
            let dy = to.y - self.anchor.y;
            let distance = (dx * dx + dy * dy).sqrt();
            if distance > self.smoothing_pixels {
                let step = (distance - self.smoothing_pixels) / distance;
                self.anchor = PointF::new(self.anchor.x + dx * step, self.anchor.y + dy * step);
                self.chain.push(self.anchor);
            }
            // A finished path ends with the raw pointer sample; until then it is the tail's end.
            self.pending_raw = if self.chain.last() == Some(&to) { None } else { Some(to) };
        } else {
            self.chain.push(to);
            self.pending_raw = None;
        }
        // A segment's curve needs the sample after its end. While that sample is still the
        // newest pointer position it can move on, so the segment stays in the tail; a sample in
        // the string-model chain never moves, so committing against one is final.
        while self.committed + 2 < self.chain.len() {
            let index = self.committed;
            self.commit_segment(target, index, &mut touched);
            self.committed += 1;
        }
        self.draw_tail(target, &mut touched);
        self.timing.deposit_ns += started.elapsed().as_nanos() as u64;
        let started = std::time::Instant::now();
        let bounds = self.composite(target, selection, touched);
        self.timing.composite_ns += started.elapsed().as_nanos() as u64;
        self.timing.calls += 1;
        self.outcome(bounds)
    }

    /// Ends the stroke and flushes any coverage the target has not seen. The target is required
    /// because a click that never moved has its single dab still to lay.
    pub fn finish(self, target: &mut Bitmap8) -> StrokeOutcome {
        self.finish_clipped(target, None)
    }

    /// `finish` limited to a selection.
    pub fn finish_clipped(mut self, target: &mut Bitmap8, selection: Option<&Gray8>) -> StrokeOutcome {
        if self.error.is_some() {
            return self.outcome(None);
        }
        if let Err(error) = check_selection(target, selection) {
            self.error = Some(error);
            return self.outcome(None);
        }
        if self.tile <= 0 {
            self.tile = tile_edge(target, &self.brush);
        }
        let started = std::time::Instant::now();
        let mut touched = None;
        if !self.has_tail {
            // A click that never moved: the path is one point and its dab is the whole stroke.
            self.draw_tail(target, &mut touched);
        }
        // The finished tail is the curve the batch version draws for the last segment, so
        // promoting it moves coverage between the buffers without changing any pixel.
        if let Some(rect) = self.promote_tail() {
            merge_dirty(&mut touched, Some(rect));
        }
        self.timing.deposit_ns += started.elapsed().as_nanos() as u64;
        let started = std::time::Instant::now();
        let bounds = self.composite(target, selection, touched);
        self.timing.composite_ns += started.elapsed().as_nanos() as u64;
        self.timing.calls += 1;
        self.outcome(bounds)
    }

    /// Runs @body@ over the part of every tile that a canvas rectangle covers, with the tile's
    /// local column and row range. Tiles the stroke never reached are skipped.
    fn for_each_tile_rect<F>(&mut self, rect: DirtyRect, mut body: F)
    where
        F: FnMut(&mut StrokeTile, i64, i64, usize, usize, usize, usize),
    {
        let (x0, y0, x1, y1) = rect;
        if x1 < x0 || y1 < y0 {
            return;
        }
        let tile = self.tile.max(1);
        let (tx0, ty0) = (x0.div_euclid(tile), y0.div_euclid(tile));
        let (tx1, ty1) = (x1.div_euclid(tile), y1.div_euclid(tile));
        for ty in ty0..=ty1 {
            for tx in tx0..=tx1 {
                let tile_x0 = tx * tile;
                let tile_y0 = ty * tile;
                let Some(tile_buffer) = self.tiles.get_mut(&(tx, ty)) else { continue };
                let lx0 = (x0 - tile_x0).clamp(0, tile_buffer.width as i64) as usize;
                let lx1 = (x1 + 1 - tile_x0).clamp(0, tile_buffer.width as i64) as usize;
                let ly0 = (y0 - tile_y0).clamp(0, tile_buffer.height as i64) as usize;
                let ly1 = (y1 + 1 - tile_y0).clamp(0, tile_buffer.height as i64) as usize;
                if lx1 <= lx0 || ly1 <= ly0 {
                    continue;
                }
                body(tile_buffer, tile_x0, tile_y0, lx0, ly0, lx1, ly1);
            }
        }
    }

    fn outcome(&self, bounds: Option<(i64, i64, u32, u32)>) -> StrokeOutcome {
        StrokeOutcome {
            bounds,
            changed: bounds.is_some(),
            dab_count: self.dab_count(),
            path_length_milli: (self.path_length() * 1000.0) as u64,
        }
    }

    /// Samples in the path so far: the string-model chain, then the newest pointer sample.
    fn path_len(&self) -> usize {
        self.chain.len() + if self.pending_raw.is_some() { 1 } else { 0 }
    }

    fn path_get(&self, index: usize) -> PointF {
        if index < self.chain.len() {
            self.chain[index]
        } else {
            self.pending_raw.unwrap_or_else(|| *self.chain.last().expect("a path always has a start"))
        }
    }

    /// Folds segment `index` into the permanent coverage: the same curve, and the same dabs in
    /// the same order, as `spline_path` plus `place_dabs` over the whole path.
    fn commit_segment(&mut self, target: &Bitmap8, index: usize, touched: &mut Option<DirtyRect>) {
        let start = self.path_get(index);
        let end = self.path_get(index + 1);
        let before = self.path_get(index.saturating_sub(1));
        let after = self.path_get((index + 2).min(self.path_len() - 1));
        let mut segments = Vec::with_capacity(4);
        piece_segments(start, end, before, after, &mut segments);
        for segment in &segments {
            self.length += segment.length();
            self.deposit(target, *segment, false, touched);
        }
    }

    /// Lays the newest segment as a provisional tail, remembering where it started so the next
    /// sample can replace it exactly.
    fn draw_tail(&mut self, target: &Bitmap8, touched: &mut Option<DirtyRect>) {
        self.tail_dabs = 0;
        self.tail_length = 0.0;
        let mut rect = None;
        let len = self.path_len();
        if len == 0 {
            self.has_tail = false;
            self.tail_touched = None;
            return;
        }
        let mut segments = Vec::with_capacity(4);
        if len == 1 {
            segments.push(Segment { a: self.path_get(0), b: self.path_get(0) });
        } else {
            // Every piece from the last permanent one to the end is provisional; the last one
            // clamps its "after" control point to its own end, exactly as stroke_segments does for
            // a finished path.
            for index in self.committed..=(len - 2) {
                let start = self.path_get(index);
                let end = self.path_get(index + 1);
                let before = self.path_get(index.saturating_sub(1));
                let after = self.path_get((index + 2).min(len - 1));
                piece_segments(start, end, before, after, &mut segments);
            }
        }
        for segment in &segments {
            self.tail_length += segment.length();
            self.deposit(target, *segment, true, &mut rect);
        }
        self.tail_touched = rect;
        self.has_tail = true;
        merge_dirty(touched, rect);
    }

    /// Drops the provisional tail: its coverage, its counts, and the dab placement state it
    /// started from. Returns the pixels that must be recomposited.
    fn drop_tail(&mut self) -> Option<DirtyRect> {
        if !self.has_tail {
            return None;
        }
        let rect = self.tail_touched.take();
        if let Some(rect) = rect {
            self.for_each_tile_rect(rect, |tile, _tile_x0, _tile_y0, lx0, ly0, lx1, ly1| {
                for y in ly0..ly1 {
                    let row = y * tile.width;
                    for x in lx0..lx1 {
                        tile.tail[row + x] = 0.0;
                    }
                }
            });
        }
        self.tail_dabs = 0;
        self.tail_length = 0.0;
        self.has_tail = false;
        rect
    }

    /// Moves the tail into the permanent buffer. The pixel's total coverage is unchanged, which
    /// is why a finished stroke needs no repaint.
    fn promote_tail(&mut self) -> Option<DirtyRect> {
        let rect = self.tail_touched.take()?;
        let soft = self.soft;
        self.for_each_tile_rect(rect, |tile, _tile_x0, _tile_y0, lx0, ly0, lx1, ly1| {
            for y in ly0..ly1 {
                let row = y * tile.width;
                for x in lx0..lx1 {
                    let index = row + x;
                    let (committed, tail) = (tile.values[index], tile.tail[index]);
                    // Densities add; silhouettes keep the strongest. A pixel's total is the same
                    // before and after, which is why finishing changes no pixel.
                    tile.values[index] = if soft { committed + tail } else { committed.max(tail) };
                    tile.tail[index] = 0.0;
                }
            }
        });
        self.dabs += self.tail_dabs;
        self.length += self.tail_length;
        self.tail_dabs = 0;
        self.tail_length = 0.0;
        self.has_tail = false;
        Some(rect)
    }

    /// Deposits one swept segment into the stroke's tiles, allocating the tiles the segment
    /// reaches. The cost is the swept area of this segment alone - a stroke never pays for the
    /// bounding box it has grown to, and never copies a buffer when it grows.
    fn deposit(&mut self, target: &Bitmap8, segment: Segment, tail: bool, touched: &mut Option<DirtyRect>) {
        let (bx0, by0, bx1, by1) = segment.bounds(dab_reach(&self.brush));
        if bx1 <= bx0 || by1 <= by0 {
            return;
        }
        let x0 = bx0.max(0);
        let y0 = by0.max(0);
        let x1 = bx1.min(target.width() as i64);
        let y1 = by1.min(target.height() as i64);
        if x1 <= x0 || y1 <= y0 {
            return;
        }
        let tile = self.tile.max(1);
        let (tx0, ty0) = (x0.div_euclid(tile), y0.div_euclid(tile));
        let (tx1, ty1) = ((x1 - 1).div_euclid(tile), (y1 - 1).div_euclid(tile));
        let mut painted = false;
        for ty in ty0..=ty1 {
            for tx in tx0..=tx1 {
                if !self.ensure_tile(target, (tx, ty)) {
                    continue;
                }
                let tile_x0 = tx * tile;
                let tile_y0 = ty * tile;
                let soft = self.soft;
                let brush = self.brush;
                let spacing = self.spacing;
                let profile = &self.profile;
                let Some(buffer) = self.tiles.get_mut(&(tx, ty)) else { continue };
                let (width, height) = (buffer.width, buffer.height);
                let destination = if tail { &mut buffer.tail } else { &mut buffer.values };
                deposit_segment(profile, &brush, soft, destination, tile_x0, tile_y0, width as u32, height as u32, segment, spacing);
                painted = true;
            }
        }
        if !painted {
            return;
        }
        if tail {
            self.tail_dabs += 1;
        } else {
            self.dabs += 1;
        }
        merge_dirty(touched, Some((x0, y0, x1 - 1, y1 - 1)));
    }

    /// Allocates one tile, reading the pixels the target holds now as the base to composite from.
    /// A tile is only ever created for an area no paint has reached, so those pixels are still the
    /// ones the stroke started with. Returns false when the tile lies outside the target.
    fn ensure_tile(&mut self, target: &Bitmap8, key: (i64, i64)) -> bool {
        if self.tiles.contains_key(&key) {
            return true;
        }
        let tile = self.tile.max(1);
        let tile_x0 = key.0 * tile;
        let tile_y0 = key.1 * tile;
        let x1 = (tile_x0 + tile).min(target.width() as i64);
        let y1 = (tile_y0 + tile).min(target.height() as i64);
        if x1 <= tile_x0 || y1 <= tile_y0 {
            return false;
        }
        let started = std::time::Instant::now();
        let width = (x1 - tile_x0) as usize;
        let height = (y1 - tile_y0) as usize;
        let mut base = vec![[0u8; 4]; width * height];
        for row in 0..height {
            let y = (tile_y0 as usize + row) as u32;
            let target_row = target.row(y);
            let tile_row = &mut base[row * width..(row + 1) * width];
            for (column, slot) in tile_row.iter_mut().enumerate() {
                let pixel = (tile_x0 as usize + column) * 4;
                *slot = [target_row[pixel], target_row[pixel + 1], target_row[pixel + 2], target_row[pixel + 3]];
            }
        }
        self.timing.reserve_ns += started.elapsed().as_nanos() as u64;
        self.tiles.insert(
            key,
            StrokeTile { values: vec![0f32; width * height], tail: vec![0f32; width * height], base, width, height },
        );
        true
    }

    /// Rebuilds the touched pixels from the base plus the stroke's coverage. Rebuilding rather
    /// than accumulating is what keeps an incremental stroke identical to a batch one. Only the
    /// tiles the new segment reached are visited, so a stroke never re-reads its whole bounding
    /// box.
    fn composite(
        &mut self,
        target: &mut Bitmap8,
        selection: Option<&Gray8>,
        touched: Option<DirtyRect>,
    ) -> Option<(i64, i64, u32, u32)> {
        let Some((min_x, min_y, max_x, max_y)) = touched else {
            return None;
        };
        let clip_x0 = min_x.max(0);
        let clip_y0 = min_y.max(0);
        let clip_x1 = (max_x + 1).min(target.width() as i64);
        let clip_y1 = (max_y + 1).min(target.height() as i64);
        if clip_x1 <= clip_x0 || clip_y1 <= clip_y0 {
            return None;
        }
        let opacity = self.brush.opacity;
        let erase = self.brush.erase;
        let color = self.color;
        let soft = self.soft;
        let row_bytes = target.width() as usize * 4;
        let tile = self.tile.max(1);
        let (tx0, ty0) = (clip_x0.div_euclid(tile), clip_y0.div_euclid(tile));
        let (tx1, ty1) = ((clip_x1 - 1).div_euclid(tile), (clip_y1 - 1).div_euclid(tile));
        let mut changed: Option<DirtyRect> = None;
        // One tile at a time, rows in parallel inside it: the rows of the target are independent,
        // and the changed rectangle comes back as a min/max reduction, which does not care about
        // the order rows finish in.
        for ty in ty0..=ty1 {
            for tx in tx0..=tx1 {
                let tile_x0 = tx * tile;
                let tile_y0 = ty * tile;
                let Some(buffer) = self.tiles.get(&(tx, ty)) else { continue };
                let lx0 = (clip_x0 - tile_x0).clamp(0, buffer.width as i64) as usize;
                let lx1 = (clip_x1 - tile_x0).clamp(0, buffer.width as i64) as usize;
                let ly0 = (clip_y0 - tile_y0).clamp(0, buffer.height as i64) as usize;
                let ly1 = (clip_y1 - tile_y0).clamp(0, buffer.height as i64) as usize;
                if lx1 <= lx0 || ly1 <= ly0 {
                    continue;
                }
                let width = buffer.width;
                let (values, tail, base) = (&buffer.values, &buffer.tail, &buffer.base);
                let first_row = tile_y0 as usize + ly0;
                let last_row = tile_y0 as usize + ly1;
                let rows = &mut target.pixels_mut()[first_row * row_bytes..last_row * row_bytes];
                let tile_changed = rows
                    .par_chunks_mut(row_bytes)
                    .enumerate()
                    .map(|(offset, row)| -> Option<DirtyRect> {
                        let y = first_row as i64 + offset as i64;
                        let row_start = (offset + ly0) * width;
                        let mut first: Option<i64> = None;
                        let mut last_changed: Option<i64> = None;
                        for column in lx0..lx1 {
                            let index = row_start + column;
                            let coverage = combined_coverage(values[index], tail[index], soft);
                            let mut alpha = coverage * opacity;
                            if let Some(mask) = selection {
                                alpha *= mask.get((tile_x0 as usize + column) as u32, y as u32) as f64 / 255.0;
                            }
                            let painted = composite_pixel(base[index], color, alpha, erase);
                            let pixel = (tile_x0 as usize + column) * 4;
                            if painted != row[pixel..pixel + 4] {
                                row[pixel..pixel + 4].copy_from_slice(&painted);
                                let x = tile_x0 + column as i64;
                                first = Some(first.map_or(x, |current: i64| current.min(x)));
                                last_changed = Some(last_changed.map_or(x, |current: i64| current.max(x)));
                            }
                        }
                        first.zip(last_changed).map(|(left, right)| (left, y, right, y))
                    })
                    .reduce(
                        || None::<DirtyRect>,
                        |a, b| match (a, b) {
                            (Some(a), Some(b)) => Some((a.0.min(b.0), a.1.min(b.1), a.2.max(b.2), a.3.max(b.3))),
                            (Some(a), None) => Some(a),
                            (None, b) => b,
                        },
                    );
                if let Some(rect) = tile_changed {
                    changed = Some(changed.map_or(rect, |current| union_dirty(Some(current), rect)));
                }
            }
        }
        if let Some(rect) = changed {
            self.touched = Some(union_dirty(self.touched, rect));
        }
        rect_bounds(changed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn point(x: f64, y: f64) -> PointF {
        PointF::new(x, y)
    }

    fn alpha(image: &Bitmap8, x: u32, y: u32) -> u8 {
        image.get(x, y)[3]
    }

    fn paint(brush: Brush, size: u32, points: &[PointF]) -> Bitmap8 {
        let mut image = Bitmap8::new(size, size);
        BrushEngine::new(brush).stroke(&mut image, points).expect("stroke");
        image
    }

    #[test]
    fn tip_falloff_is_full_inside_the_hardness_radius_and_zero_at_the_rim() {
        let brush = Brush::soft(20.0, 0.5);
        assert!((brush.tip_weight(0.0) - 1.0).abs() < 1e-9);
        assert!((brush.tip_weight(4.0) - 1.0).abs() < 1e-9);
        assert!(brush.tip_weight(10.0).abs() < 1e-9);
        assert!(brush.tip_weight(12.0).abs() < 1e-9);
        let middle = brush.tip_weight(7.5);
        assert!(middle > 0.0 && middle < 1.0);
        // Monotonic from the core to the rim, and the rim itself is a hard cut, not a smear.
        assert!(brush.tip_weight(6.0) > brush.tip_weight(8.0));
        assert!(brush.tip_weight(8.0) > brush.tip_weight(9.5));
        // A hard tip is solid inside with a one-pixel antialiased silhouette.
        let hard = Brush::new(20.0);
        assert_eq!(hard.tip_weight(9.0), 1.0);
        assert!((hard.tip_weight(10.0) - 0.5).abs() < 1e-9);
        assert_eq!(hard.tip_weight(11.0), 0.0);
    }

    #[test]
    fn a_soft_tip_paints_a_radially_symmetric_dab() {
        let image = paint(Brush::soft(16.0, 0.3), 32, &[point(16.0, 16.0)]);
        for y in 0..32 {
            for x in 0..32 {
                assert_eq!(
                    alpha(&image, x, y),
                    alpha(&image, 31 - x, y),
                    "horizontal symmetry at {x},{y}"
                );
                assert_eq!(alpha(&image, x, y), alpha(&image, x, 31 - y), "vertical symmetry at {x},{y}");
            }
        }
        assert_eq!(alpha(&image, 15, 16), 255);
        assert_eq!(alpha(&image, 16, 16), 255);
        let edge = alpha(&image, 15, 8);
        assert!(edge > 0 && edge < 255, "the soft rim is partial, got {edge}");
        assert_eq!(alpha(&image, 0, 0), 0);
    }

    #[test]
    fn opacity_caps_the_whole_stroke() {
        for opacity in [0.25, 0.5, 0.9, 1.0] {
            let brush = Brush { opacity, ..Brush::new(24.0) };
            // Three passes over the same pixels inside a single stroke.
            let image = paint(brush, 64, &[point(20.0, 32.0), point(44.0, 32.0), point(20.0, 32.0), point(44.0, 32.0)]);
            let expected = (opacity * 255.0).round() as u8;
            assert_eq!(alpha(&image, 32, 32), expected, "opacity {opacity}");
            assert_eq!(alpha(&image, 30, 32), expected, "opacity {opacity}");
        }
    }

    #[test]
    fn a_self_crossing_does_not_darken_a_hard_tip_stroke() {
        let brush = Brush { opacity: 0.5, ..Brush::new(20.0) };
        // A vertical arm, back down it, then a horizontal arm straight through the middle.
        let image = paint(brush, 80, &[point(40.0, 10.0), point(40.0, 70.0), point(40.0, 40.0), point(10.0, 40.0), point(70.0, 40.0)]);
        let crossing = alpha(&image, 40, 40);
        let horizontal_arm = alpha(&image, 20, 40);
        let vertical_arm = alpha(&image, 40, 20);
        assert_eq!(crossing, 128);
        assert_eq!(horizontal_arm, 128);
        assert_eq!(vertical_arm, 128);
        assert!(crossing <= (brush.opacity * 255.0).round() as u8);
    }

    #[test]
    fn a_soft_self_crossing_matches_source_over_of_its_arms() {
        let brush = Brush { opacity: 0.6, ..Brush::soft(30.0, 0.2) };
        let image = paint(brush, 80, &[point(40.0, 10.0), point(40.0, 70.0), point(40.0, 40.0), point(10.0, 40.0), point(70.0, 40.0)]);
        let crossing = alpha(&image, 40, 40) as f64 / 255.0;
        let arm = alpha(&image, 20, 40) as f64 / 255.0;
        // Densities add, so coverage is exactly source-over of the two arms - never more.
        let screen = 1.0 - (1.0 - arm) * (1.0 - arm);
        assert!(crossing <= screen + 0.01, "crossing {crossing} exceeds source-over {screen}");
        assert!(crossing >= arm - 0.01);
        assert!(crossing <= brush.opacity + 0.01);
    }

    #[test]
    fn repeated_dabs_inside_one_stroke_stop_at_the_cap() {
        let brush = Brush { opacity: 0.5, ..Brush::new(16.0) };
        let once = paint(brush, 64, &[point(20.0, 32.0), point(44.0, 32.0)]);
        let many = paint(brush, 64, &[point(20.0, 32.0), point(44.0, 32.0), point(20.0, 32.0)]);
        assert_eq!(alpha(&once, 32, 32), 128);
        assert_eq!(alpha(&many, 32, 32), 128);
    }

    #[test]
    fn erasing_takes_alpha_away_and_leaves_the_color() {
        let mut image = Bitmap8::filled(64, 64, [10, 200, 30, 255]);
        BrushEngine::new(Brush::eraser(20.0)).stroke(&mut image, &[point(32.0, 32.0)]).expect("erase");
        let pixel = image.get(32, 32);
        assert_eq!(pixel[3], 0);
        assert_eq!(&pixel[0..3], &[10, 200, 30]);
        assert_eq!(image.get(0, 0)[3], 255);
    }

    #[test]
    fn erasing_never_adds_alpha() {
        let mut image = Bitmap8::filled(64, 64, [0, 0, 0, 128]);
        let before: Vec<u8> = (0..64).flat_map(|y| (0..64).map(move |x| (x, y))).map(|(x, y)| image.get(x, y)[3]).collect();
        BrushEngine::new(Brush::eraser(24.0)).stroke(&mut image, &[point(32.0, 32.0)]).expect("erase");
        assert_eq!(image.get(32, 32)[3], 0);
        for y in 0..64 {
            for x in 0..64 {
                assert!(image.get(x, y)[3] <= 128, "alpha grew at {x},{y}");
            }
        }
        assert_eq!(before.len(), 64 * 64);
    }

    #[test]
    fn spacing_derives_from_hardness_and_can_be_overridden() {
        assert_eq!(Brush::new(100.0).spacing_pixels(), 1.5);
        assert_eq!(Brush::soft(100.0, 0.5).spacing_pixels(), 2.5);
        assert_eq!(Brush { spacing: 0.5, ..Brush::new(100.0) }.spacing_pixels(), 50.0);
        assert_eq!(Brush { size: 4.0, spacing: 0.01, ..Brush::new(4.0) }.spacing_pixels(), 0.25);
        assert_eq!(spacing_fraction(1.0), 0.015);
        assert_eq!(spacing_fraction(0.99), 0.025);
    }

    #[test]
    fn smoothing_trails_the_pointer_on_a_string() {
        // Jitter shorter than the string never reaches the stroke.
        let smoothed = smooth_path(&[point(0.0, 0.0), point(2.0, 0.0), point(4.0, 0.0), point(6.0, 0.0)], 10.0);
        assert_eq!(smoothed.first(), Some(&point(0.0, 0.0)));
        assert_eq!(smoothed.len(), 2, "only the start and the final pull: {smoothed:?}");
        assert_eq!(smoothed.last(), Some(&point(6.0, 0.0)));
        // A long pull moves the tip the string's length short of the pointer.
        let pulled = smooth_path(&[point(0.0, 0.0), point(30.0, 0.0)], 10.0);
        assert_eq!(pulled[1].x, 20.0);
        // No smoothing follows the pointer exactly.
        assert_eq!(smooth_path(&[point(0.0, 0.0), point(3.0, 0.0)], 0.0).len(), 2);
        // The string length is in screen points, so zooming in shortens it in document pixels.
        let brush = Brush { smoothing: 40.0, ..Brush::default() };
        assert_eq!(brush.smoothing_pixels(2.0), 20.0);
        assert_eq!(brush.smoothing_pixels(0.0), 4000.0);
    }

    #[test]
    fn the_spline_passes_through_every_sample() {
        let samples = [point(0.0, 0.0), point(10.0, 20.0), point(30.0, 25.0), point(40.0, 0.0)];
        let path = spline_path(&samples);
        assert_eq!(path.first(), Some(&samples[0]));
        assert_eq!(path.last(), Some(&samples[3]));
        for sample in samples {
            assert!(path.iter().any(|q| (q.x - sample.x).abs() < 1e-6 && (q.y - sample.y).abs() < 1e-6), "missing {sample:?}");
        }
        // A curve between widely spaced samples is flattened, not drawn as one chord.
        assert!(path.len() > samples.len());
        assert_eq!(spline_path(&[point(1.0, 1.0)]), vec![point(1.0, 1.0)]);
    }

    #[test]
    fn dabs_keep_their_spacing_across_a_corner() {
        let dabs = place_dabs(&[point(0.0, 0.0), point(10.0, 0.0), point(10.0, 10.0)], 4.0);
        assert_eq!(dabs.len(), 6);
        assert_eq!(dabs[0], point(0.0, 0.0));
        assert!((dabs[1].x - 4.0).abs() < 1e-9);
        assert!((dabs[2].x - 8.0).abs() < 1e-9);
        // The leftover 2 pixels carry into the second leg instead of restarting the spacing.
        assert!((dabs[3].x - 10.0).abs() < 1e-9 && (dabs[3].y - 2.0).abs() < 1e-9);
        assert!((dabs[5].y - 10.0).abs() < 1e-9);
    }

    #[test]
    fn a_single_click_paints_one_dab() {
        let mut image = Bitmap8::new(32, 32);
        let outcome = BrushEngine::new(Brush::new(10.0)).stroke(&mut image, &[point(16.5, 16.5)]).expect("dot");
        assert_eq!(outcome.dab_count, 1);
        assert_eq!(outcome.path_length(), 0.0);
        assert_eq!(alpha(&image, 16, 16), 255);
        assert_eq!(alpha(&image, 14, 17), 255, "the solid tip covers the whole radius");
        assert_eq!(alpha(&image, 5, 5), 0, "well outside the tip nothing is painted");
    }

    #[test]
    fn an_empty_or_offscreen_stroke_changes_nothing() {
        let mut image = Bitmap8::filled(8, 8, [1, 2, 3, 255]);
        let before = image.clone();
        let engine = BrushEngine::new(Brush::new(4.0));
        assert_eq!(engine.stroke(&mut image, &[]).expect("empty").bounds, None);
        assert_eq!(engine.stroke(&mut image, &[point(-100.0, -100.0)]).expect("offscreen").bounds, None);
        assert_eq!(engine.stroke(&mut image, &[point(f64::NAN, 0.0)]).expect("not finite").bounds, None);
        assert_eq!(image, before);
    }

    #[test]
    fn the_reported_bounds_cover_every_changed_pixel() {
        let brush = Brush::new(8.0);
        let mut image = Bitmap8::new(64, 64);
        let outcome = BrushEngine::new(brush).stroke(&mut image, &[point(20.5, 20.5), point(40.5, 20.5)]).expect("line");
        let (x, y, width, height) = outcome.bounds.expect("dirty bounds");
        assert_eq!((x, y, width, height), (16, 16, 29, 9));
        for py in 0..64u32 {
            for px in 0..64u32 {
                let inside = (px as i64) >= x
                    && (px as i64) < x + width as i64
                    && (py as i64) >= y
                    && (py as i64) < y + height as i64;
                if !inside {
                    assert_eq!(alpha(&image, px, py), 0, "changed pixel outside the bounds at {px},{py}");
                }
            }
        }
        assert_eq!(alpha(&image, 20, 20), 255);
    }

    #[test]
    fn a_selection_clips_the_stroke() {
        let mut mask = Gray8::new(64, 64);
        for y in 0..64 {
            for x in 0..32 {
                mask.set(x, y, 255);
            }
        }
        let mut image = Bitmap8::new(64, 64);
        BrushEngine::new(Brush::new(16.0))
            .stroke_clipped(&mut image, &[point(30.5, 32.5)], Some(&mask))
            .expect("clipped stroke");
        assert_eq!(alpha(&image, 28, 32), 255);
        assert_eq!(alpha(&image, 34, 32), 0, "outside the selection nothing is painted");
        // Half-covered edge pixels fade instead of switching on.
        let mut soft = Gray8::new(64, 64);
        for y in 0..64 {
            for x in 0..32 {
                soft.set(x, y, 128);
            }
        }
        let mut faded = Bitmap8::new(64, 64);
        BrushEngine::new(Brush::new(16.0))
            .stroke_clipped(&mut faded, &[point(30.5, 32.5)], Some(&soft))
            .expect("faded stroke");
        assert_eq!(alpha(&faded, 28, 32), 128);
    }

    #[test]
    fn a_selection_of_the_wrong_size_is_refused() {
        let mut image = Bitmap8::new(16, 16);
        let mask = Gray8::new(8, 8);
        assert!(BrushEngine::new(Brush::default()).stroke_clipped(&mut image, &[point(8.0, 8.0)], Some(&mask)).is_err());
    }

    #[test]
    fn flow_below_one_builds_up_without_passing_the_cap() {
        let brush = Brush { flow: 0.4, opacity: 0.8, ..Brush::soft(20.0, 0.0) };
        let single = paint(brush, 48, &[point(24.0, 24.0)]);
        let first = alpha(&single, 24, 24);
        assert!(first > 0 && first < 204, "a 40% dab is partial, got {first}");
        let built = paint(brush, 48, &[point(24.0, 24.0), point(24.0, 28.0), point(24.0, 24.0)]);
        assert!(alpha(&built, 24, 24) > first);
        assert!(alpha(&built, 24, 24) <= 204, "the stroke cap still holds");
    }

    #[test]
    fn brush_settings_outside_the_options_bar_are_rejected() {
        assert!(Brush::default().validate().is_ok());
        assert!(Brush { size: 0.5, ..Brush::default() }.validate().is_err());
        assert!(Brush { size: MAX_BRUSH_DIAMETER + 1.0, ..Brush::default() }.validate().is_err());
        assert!(Brush { size: f64::NAN, ..Brush::default() }.validate().is_err());
        assert!(Brush { hardness: 1.5, ..Brush::default() }.validate().is_err());
        assert!(Brush { hardness: -0.1, ..Brush::default() }.validate().is_err());
        assert!(Brush { flow: 1.5, ..Brush::default() }.validate().is_err());
        assert!(Brush { opacity: 0.0, ..Brush::default() }.validate().is_err());
        assert!(Brush { opacity: 1.2, ..Brush::default() }.validate().is_err());
        assert!(Brush { smoothing: 101.0, ..Brush::default() }.validate().is_err());
        assert!(Brush { spacing: f64::INFINITY, ..Brush::default() }.validate().is_err());
    }

    /// The path the Lead asked for: a straight run, a sharp corner and a self-crossing.
    fn mixed_path() -> Vec<PointF> {
        vec![
            point(8.0, 12.0),
            point(28.0, 12.0),
            point(48.0, 12.0),
            point(48.0, 40.0),
            point(20.0, 40.0),
            point(20.0, 20.0),
            point(60.0, 20.0),
            point(60.0, 52.0),
            point(12.0, 52.0),
            point(12.0, 12.0),
        ]
    }

    /// Feeds a path through a session one sample at a time and returns the pixels, whether any
    /// call repainted, and the outcome of the final call.
    fn session_stroke(
        brush: Brush,
        path: &[PointF],
        selection: Option<&Gray8>,
        background: [u8; 4],
    ) -> (Bitmap8, bool, StrokeOutcome) {
        let mut image = Bitmap8::filled(72, 64, background);
        let mut session = BrushEngine::new(brush).begin_stroke(path[0]).expect("begin");
        let mut repainted = false;
        for point in &path[1..] {
            repainted |= session.extend_clipped(&mut image, *point, selection).changed;
        }
        let outcome = session.finish_clipped(&mut image, selection);
        (image, repainted, outcome)
    }

    /// Many short moves, the way a hand actually jitters, to keep the tail being replaced.
    fn jitter_path() -> Vec<PointF> {
        let mut path = Vec::new();
        for step in 0..30 {
            let t = step as f64;
            path.push(point(36.0 + (t * 0.9).sin() * 14.0, 32.0 + (t * 1.7).cos() * 9.0));
        }
        path
    }

    #[test]
    fn an_incremental_stroke_matches_a_batch_stroke_exactly() {
        let brushes = [
            Brush::new(12.0),
            Brush { opacity: 0.5, ..Brush::new(12.0) },
            Brush { flow: 0.4, ..Brush::soft(18.0, 0.25) },
            Brush { spacing: 0.4, ..Brush::new(12.0) },
            Brush::eraser(14.0),
        ];
        for brush in brushes {
            for smoothing in [0.0, 9.0] {
                for path in [mixed_path(), jitter_path()] {
                    let brush = Brush { smoothing, ..brush };
                    let mut batch = Bitmap8::filled(72, 64, [30, 90, 150, 255]);
                    let batch_outcome = BrushEngine::new(brush).stroke(&mut batch, &path).expect("batch");
                    let (incremental, repainted, outcome) = session_stroke(brush, &path, None, [30, 90, 150, 255]);
                    assert_eq!(incremental, batch, "{brush:?} smoothing {smoothing} over {} points", path.len());
                    assert!(repainted, "the session painted something");
                    assert_eq!(outcome.dab_count, batch_outcome.dab_count, "dab count {brush:?}");
                    assert_eq!(outcome.path_length_milli, batch_outcome.path_length_milli, "path length {brush:?}");
                }
            }
        }
    }

    #[test]
    fn an_incremental_stroke_matches_a_batch_stroke_with_a_selection() {
        let mut selection = Gray8::new(72, 64);
        for y in 0..64 {
            for x in 0..36 {
                selection.set(x, y, 200);
            }
        }
        for brush in [Brush { opacity: 0.7, ..Brush::new(16.0) }, Brush::soft(14.0, 0.4)] {
            let path = mixed_path();
            let mut batch = Bitmap8::filled(72, 64, [30, 90, 150, 255]);
            BrushEngine::new(brush).stroke_clipped(&mut batch, &path, Some(&selection)).expect("batch");
            let (incremental, repainted, _) = session_stroke(brush, &path, Some(&selection), [30, 90, 150, 255]);
            assert_eq!(incremental, batch, "{brush:?}");
            assert!(repainted);
        }
        // A selection of the wrong size stops the session instead of painting the whole canvas.
        let mut image = Bitmap8::filled(8, 8, [0, 0, 0, 255]);
        let mut session = BrushEngine::new(Brush::new(4.0)).begin_stroke(point(4.0, 4.0)).expect("begin");
        let outcome = session.extend_clipped(&mut image, point(5.0, 4.0), Some(&Gray8::new(4, 4)));
        assert!(!outcome.changed);
        assert!(session.error().is_some());
        assert_eq!(session.finish(&mut image).changed, false);
    }

    #[test]
    fn every_extend_reports_the_pixels_it_changed() {
        let brush = Brush::soft(16.0, 0.3);
        let path = mixed_path();
        let mut image = Bitmap8::filled(72, 64, [30, 90, 150, 255]);
        let mut session = BrushEngine::new(brush).begin_stroke(path[0]).expect("begin");
        let mut painted = 0;
        for point in &path[1..] {
            let before = image.clone();
            let outcome = session.extend(&mut image, *point);
            assert_eq!(outcome.changed, before != image, "changed flag at {point:?}");
            match outcome.bounds {
                Some((x, y, width, height)) => {
                    assert!(outcome.changed);
                    for py in 0..64u32 {
                        for px in 0..72u32 {
                            if before.get(px, py) != image.get(px, py) {
                                let inside = (px as i64) >= x
                                    && (px as i64) < x + width as i64
                                    && (py as i64) >= y
                                    && (py as i64) < y + height as i64;
                                assert!(inside, "changed pixel {px},{py} outside {outcome:?}");
                            }
                        }
                    }
                    painted += 1;
                }
                None => assert!(!outcome.changed),
            }
        }
        assert!(painted > 4, "the path produced several repaints");
        // The stroke's own bounds cover everything it changed.
        let (x, y, width, height) = session.bounds().expect("stroke bounds");
        let finished = session.finish(&mut image);
        assert!(!finished.changed || finished.bounds.is_some());
        for py in 0..64u32 {
            for px in 0..72u32 {
                if image.get(px, py) != [30, 90, 150, 255] {
                    let inside = (px as i64) >= x
                        && (px as i64) < x + width as i64
                        && (py as i64) >= y
                        && (py as i64) < y + height as i64;
                    assert!(inside, "painted pixel {px},{py} outside the stroke bounds");
                }
            }
        }
    }

    #[test]
    fn a_session_never_paints_the_same_coverage_twice() {
        let brush = Brush { opacity: 0.5, ..Brush::new(14.0) };
        // Out and back along the same line, then across it: the crossing cannot darken.
        let path = [
            point(10.0, 32.0),
            point(60.0, 32.0),
            point(10.0, 32.0),
            point(35.0, 10.0),
            point(35.0, 54.0),
        ];
        let mut batch = Bitmap8::new(72, 64);
        BrushEngine::new(brush).stroke(&mut batch, &path).expect("batch");
        let (incremental, repainted, outcome) = session_stroke(brush, &path, None, [0, 0, 0, 0]);
        assert_eq!(incremental, batch);
        assert!(repainted);
        assert_eq!(incremental.get(35, 32)[3], 128, "the crossing holds the cap");
        assert_eq!(incremental.get(20, 32)[3], 128);
        assert_eq!(outcome.dab_count, BrushEngine::new(brush).stroke(&mut Bitmap8::new(72, 64), &path).expect("batch").dab_count);
    }

    #[test]
    fn a_session_click_without_a_drag_paints_one_dab() {
        let brush = Brush::new(10.0);
        let mut batch = Bitmap8::new(32, 32);
        BrushEngine::new(brush).stroke(&mut batch, &[point(16.5, 16.5)]).expect("batch");
        let mut image = Bitmap8::new(32, 32);
        let session = BrushEngine::new(brush).begin_stroke(point(16.5, 16.5)).expect("begin");
        let outcome = session.finish(&mut image);
        assert_eq!(image, batch);
        assert!(outcome.changed);
        assert_eq!(outcome.dab_count, 1);
        // The dab's box, not just the pixels that came out opaque: the rim carries half coverage.
        assert_eq!(outcome.bounds, Some((11, 11, 11, 11)));
        // A brush the options bar would refuse is reported instead of painting a wrong size.
        let refused = Brush { size: 0.0, ..Brush::new(1.0) };
        assert!(BrushEngine::new(refused).begin_stroke(point(4.0, 4.0)).is_err());
        let mut session = StrokeSession::begin(&refused, point(4.0, 4.0));
        assert!(session.error().is_some());
        assert!(!session.extend(&mut Bitmap8::new(8, 8), point(5.0, 5.0)).changed);
    }

    #[test]
    fn dab_bounds_covers_every_pixel_a_single_dab_touches() {
        let brush = Brush::new(9.0);
        let at = point(16.5, 17.5);
        let (x, y, width, height) = dab_bounds(&brush, at);
        assert_eq!((x, y, width, height), (11, 12, 11, 11));
        let mut image = Bitmap8::new(48, 48);
        BrushEngine::new(brush).stroke(&mut image, &[at]).expect("dab");
        let (px, py, pw, ph) = image.opaque_bounds().expect("painted");
        assert!((x as i64) <= px as i64 && (y as i64) <= py as i64);
        assert!((x as i64) + width as i64 >= px as i64 + pw as i64);
        assert!((y as i64) + height as i64 >= py as i64 + ph as i64);
        // A soft tip reaches the same pixels, and nonsense is refused.
        assert_eq!(dab_bounds(&Brush::soft(9.0, 0.0), at), (11, 12, 11, 11));
        assert_eq!(dab_bounds(&brush, point(f64::NAN, 0.0)), (0, 0, 0, 0));
        assert_eq!(dab_bounds(&Brush { size: 0.0, ..Brush::new(1.0) }, at), (0, 0, 0, 0));
    }

    /// Timing benchmark for the incremental stroke: the number a painter feels, the same shape
    /// compc bench prints. Run it with
    /// `cargo test --release -p comp-brush -- --ignored --nocapture`.
    #[test]
    #[ignore = "timing benchmark"]
    fn bench_incremental_stroke() {
        use std::time::Instant;
        for (canvas, brush_size, samples) in [(2000u32, 400.0f64, 60usize), (4000, 800.0, 40)] {
            let mut image = Bitmap8::filled(canvas, canvas, [30, 90, 150, 255]);
            let brush = Brush { size: brush_size, hardness: 0.6, opacity: 1.0, ..Brush::default() };
            let step = canvas as f64 * 0.6 / samples as f64;
            let mut session = BrushEngine::new(brush)
                .begin_stroke(PointF::new(canvas as f64 * 0.2, canvas as f64 * 0.2))
                .expect("begin");
            let mut times = Vec::with_capacity(samples);
            let mut swept = 0u64;
            for index in 1..=samples {
                let point = PointF::new(
                    canvas as f64 * 0.2 + step * index as f64,
                    canvas as f64 * 0.2 + step * index as f64 * 0.6,
                );
                let started = Instant::now();
                let outcome = session.extend(&mut image, point);
                times.push(started.elapsed().as_secs_f64() * 1000.0);
                if let Some((_, _, width, height)) = outcome.bounds {
                    swept += width as u64 * height as u64;
                }
            }
            let timing = session.timing();
            let _ = session.finish(&mut image);
            times.sort_by(|a, b| a.partial_cmp(b).unwrap());
            let at = |fraction: f64| times[((times.len() - 1) as f64 * fraction) as usize];
            let calls = timing.calls.max(1) as f64;
            println!(
                "canvas {canvas} brush {brush_size}: median {:.2} ms  p95 {:.2} ms  max {:.2} ms | deposit {:.2} ms/sample (buffer growth {:.0}%)  composite {:.2} ms/sample  swept {:.1} Mpx over {:.0} calls",
                at(0.5),
                at(0.95),
                times[times.len() - 1],
                timing.deposit_ns as f64 / 1e6 / calls,
                100.0 * timing.reserve_ns as f64 / timing.deposit_ns.max(1) as f64,
                timing.composite_ns as f64 / 1e6 / calls,
                swept as f64 / 1e6,
                calls,
            );
        }
    }

    /// A straight line is one chord however long it is, so the quadrature has to follow the tip's
    /// radius rather than take a fixed number of samples. With four samples over a long chord, the
    /// engine stepped over everything a small tip had swept and painted an empty or dotted line.
    #[test]
    fn a_long_chord_paints_every_pixel_the_tip_swept() {
        let mut image = Bitmap8::filled(160, 24, [255, 255, 255, 255]);
        let brush = Brush { size: 8.0, hardness: 0.5, ..Brush::default() };
        let engine = BrushEngine::new(brush).with_color([0, 0, 0, 255]);
        let outcome = engine
            .stroke(&mut image, &[PointF::new(8.0, 12.0), PointF::new(152.0, 12.0)])
            .expect("a stroke");
        assert!(outcome.changed, "the stroke painted nothing at all");
        for x in 9..151 {
            let pixel = image.get(x, 12);
            assert!(pixel[0] < 200, "x = {x} was stepped over: {pixel:?}");
        }
    }

    /// The same chord, drawn as many short chords, has to land on the same pixels: the model is a
    /// path integral, so how the path was sampled for deposition cannot show in the paint.
    #[test]
    fn a_long_chord_matches_the_same_path_in_small_steps() {
        let brush = Brush { size: 8.0, hardness: 0.5, ..Brush::default() };
        let engine = BrushEngine::new(brush).with_color([0, 0, 0, 255]);
        let mut one_chord = Bitmap8::filled(160, 24, [255, 255, 255, 255]);
        engine
            .stroke(&mut one_chord, &[PointF::new(8.0, 12.0), PointF::new(152.0, 12.0)])
            .expect("a stroke");
        let mut many_chords = Bitmap8::filled(160, 24, [255, 255, 255, 255]);
        let steps: Vec<PointF> = (0..=18).map(|index| PointF::new(8.0 + index as f64 * 8.0, 12.0)).collect();
        engine.stroke(&mut many_chords, &steps).expect("a stroke");
        // The two are not identical - the spline through a densely sampled line is still a line, but
        // the chords differ - so this compares the coverage rather than demanding equality.
        let mut worst = 0i32;
        for y in 0..24 {
            for x in 0..160 {
                let a = one_chord.get(x, y)[0] as i32;
                let b = many_chords.get(x, y)[0] as i32;
                worst = worst.max((a - b).abs());
            }
        }
        assert!(worst <= 8, "one chord and nineteen differ by {worst}");
    }

    #[test]
    fn a_coverage_mask_matches_the_painted_alpha() {
        let brush = Brush { opacity: 0.5, ..Brush::soft(20.0, 0.4) };
        let engine = BrushEngine::new(brush);
        let points = [point(20.0, 20.0), point(40.0, 30.0)];
        let mask = engine.coverage_mask(64, 64, &points).expect("coverage");
        let mut image = Bitmap8::new(64, 64);
        engine.stroke(&mut image, &points).expect("stroke");
        for y in 0..64 {
            for x in 0..64 {
                let expected = (mask.get(x, y) as f64 * brush.opacity).round();
                assert!((alpha(&image, x, y) as f64 - expected).abs() <= 1.0, "mismatch at {x},{y}");
            }
        }
    }
}
