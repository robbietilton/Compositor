//! The brush adapter: the editor's sliders and the shared stroke engine.
//!
//! comp-brush paints. This module is the only place that knows how the editor's brush settings, the
//! paint color and the marquee become a Brush, a BrushEngine and a Selection, so no panel carries
//! brush internals and a change of engine is a change here.

use comp_brush::{Brush, BrushEngine, StrokeSession, MAX_BRUSH_DIAMETER};
use comp_core::bitmap::{Bitmap8, Gray8};
use comp_core::geom::{PointF, RectF};

/// Brush shape, color and mode for one stroke.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StrokeSettings {
    /// Diameter in layer pixels.
    pub size: f32,
    /// 0 is fully feathered, 1 is a hard edge with antialiasing left.
    pub hardness: f32,
    /// Caps what the whole stroke lays down; crossing the stroke cannot deepen it.
    pub opacity: f32,
    /// Straight RGBA paint color; the alpha is the paint alpha.
    pub color: [u8; 4],
    /// True for the eraser, which clears alpha instead of painting color.
    pub erase: bool,
}

impl Default for StrokeSettings {
    fn default() -> Self {
        StrokeSettings { size: 24.0, hardness: 0.85, opacity: 1.0, color: [0, 0, 0, 255], erase: false }
    }
}

impl StrokeSettings {
    /// The comp-brush brush these settings describe.
    ///
    /// Flow stays at 1 and spacing stays automatic: the options bar offers size, hardness and
    /// opacity, and comp-brush derives spacing from hardness exactly as the macOS app does.
    /// Settings outside the engine's ranges are clamped rather than refused, so a slider can never
    /// leave the brush in a state that paints nothing.
    pub fn to_brush(&self) -> Brush {
        Brush {
            size: (self.size as f64).clamp(1.0, MAX_BRUSH_DIAMETER),
            hardness: (self.hardness as f64).clamp(0.0, 1.0),
            spacing: 0.0,
            flow: 1.0,
            opacity: (self.opacity as f64).clamp(0.01, 1.0),
            smoothing: 0.0,
            erase: self.erase,
        }
    }

    /// A validated engine for these settings at the current canvas zoom.
    ///
    /// The zoom only matters for the smoothing string, which the options bar does not expose yet;
    /// it is passed anyway so the engine agrees with the canvas if a smoothing control appears.
    pub fn engine(&self, zoom: f32) -> Result<BrushEngine, String> {
        let brush = self.to_brush();
        brush.validate().map_err(|error| error.to_string())?;
        Ok(BrushEngine::new(brush).with_color(self.color).with_zoom(zoom as f64))
    }
}

/// What one stroke call changed, in layer pixels.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct StrokeProgress {
    /// The pixels this call changed; nil when it changed none.
    pub bounds: Option<(i64, i64, u32, u32)>,
    pub changed: bool,
    /// Dabs laid by the stroke so far.
    pub dabs: usize,
}

/// One stroke in flight, in the pixel coordinates of the layer bitmap it paints.
///
/// The session owns the coverage accumulated so far, so a pointer sample only writes the pixels it
/// actually adds. That is what keeps live painting pixel-identical to painting one batch of samples.
pub struct Stroke {
    session: StrokeSession,
}

impl Stroke {
    /// Starts a stroke. The engine validates the brush, so a bad setting is reported here.
    pub fn begin(engine: &BrushEngine, start: PointF) -> Result<Stroke, String> {
        let session = engine.begin_stroke(start).map_err(|error| error.to_string())?;
        Ok(Stroke { session })
    }

    /// Nil unless the engine refused the brush or the selection while the stroke ran.
    pub fn error(&self) -> Option<String> {
        self.session.error().map(|error| error.to_string())
    }

    /// Every pixel the whole stroke has changed so far, which is the dirty rectangle.
    pub fn bounds(&self) -> Option<(i64, i64, u32, u32)> {
        self.session.bounds()
    }

    pub fn dabs(&self) -> usize {
        self.session.dab_count()
    }

    /// Appends a pointer sample in layer pixels and paints what it added.
    pub fn extend(&mut self, target: &mut Bitmap8, to: PointF, clip: Option<&Gray8>) -> StrokeProgress {
        let outcome = self.session.extend_clipped(target, to, clip);
        StrokeProgress { bounds: outcome.bounds, changed: outcome.changed, dabs: outcome.dab_count }
    }

    /// Ends the stroke. The target is needed because a click that never moved still has its single
    /// dab to lay.
    pub fn finish(self, target: &mut Bitmap8, clip: Option<&Gray8>) -> StrokeProgress {
        let outcome = self.session.finish_clipped(target, clip);
        StrokeProgress { bounds: outcome.bounds, changed: outcome.changed, dabs: outcome.dab_count }
    }
}

/// A mask as a paintable RGBA buffer: the gray value in every channel, alpha opaque.
///
/// comp-brush paints RGBA, so a mask is painted through this scratch buffer and converted back on
/// commit. Opaque alpha is what makes a dab blend toward the paint color instead of punching a hole
/// in the mask.
pub fn mask_to_scratch(mask: &Gray8) -> Bitmap8 {
    let mut scratch = Bitmap8::new(mask.width(), mask.height());
    for row in 0..mask.height() {
        let source = mask.row(row);
        let target = scratch.row_mut(row);
        for (index, value) in source.iter().enumerate() {
            let offset = index * 4;
            target[offset] = *value;
            target[offset + 1] = *value;
            target[offset + 2] = *value;
            target[offset + 3] = 255;
        }
    }
    scratch
}

/// The gray values a mask scratch holds, back in the form the document stores.
pub fn scratch_to_mask(scratch: &Bitmap8) -> Gray8 {
    let mut mask = Gray8::new(scratch.width(), scratch.height());
    let stride = scratch.width() as usize;
    for row in 0..scratch.height() as usize {
        let source = scratch.row(row as u32);
        let target = &mut mask.pixels_mut()[row * stride..(row + 1) * stride];
        for (index, value) in target.iter_mut().enumerate() {
            *value = source[index * 4];
        }
    }
    mask
}

/// The gray a paint color stands for on a mask, with the same weights the compositor uses.
pub fn mask_gray(color: [u8; 4]) -> u8 {
    (0.3 * color[0] as f64 + 0.59 * color[1] as f64 + 0.11 * color[2] as f64).round().clamp(0.0, 255.0) as u8
}

/// The marquee as a layer-sized coverage mask, which is what the stroke engine clips against.
///
/// A rectangle that misses the layer still yields an all-zero mask, so the caller keeps one code
/// path: the stroke simply paints nothing.
pub fn selection_mask(width: u32, height: u32, min: (f32, f32), max: (f32, f32)) -> Option<Gray8> {
    if width == 0
        || height == 0
        || !min.0.is_finite()
        || !min.1.is_finite()
        || !max.0.is_finite()
        || !max.1.is_finite()
    {
        return None;
    }
    let rect = RectF::new(
        min.0.min(max.0) as f64,
        min.1.min(max.1) as f64,
        (max.0 - min.0).abs() as f64,
        (max.1 - min.1).abs() as f64,
    );
    Some(comp_brush::Selection::rect(width, height, rect, true).into_gray())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings(size: f32, opacity: f32, color: [u8; 4]) -> StrokeSettings {
        StrokeSettings { size, hardness: 1.0, opacity, color, erase: false }
    }

    /// Paints one stroke through a path and returns the target.
    fn painted(settings: StrokeSettings, side: u32, path: &[(f32, f32)], clip: Option<&Gray8>) -> Bitmap8 {
        let mut target = Bitmap8::new(side, side);
        let engine = settings.engine(1.0).expect("a valid engine");
        let mut stroke = Stroke::begin(&engine, PointF::new(path[0].0 as f64, path[0].1 as f64)).expect("a stroke");
        for point in &path[1..] {
            stroke.extend(&mut target, PointF::new(point.0 as f64, point.1 as f64), clip);
        }
        stroke.finish(&mut target, clip);
        target
    }

    #[test]
    fn settings_map_onto_a_valid_brush_and_clamp_out_of_range_values() {
        let brush = settings(20.0, 0.5, [1, 2, 3, 255]).to_brush();
        assert_eq!(brush.size, 20.0);
        assert_eq!(brush.opacity, 0.5);
        assert!(!brush.erase);
        // The options bar owns size, hardness and opacity; the engine derives the rest.
        assert_eq!(brush.spacing, 0.0);
        assert_eq!(brush.flow, 1.0);
        brush.validate().expect("the mapped brush must be valid");

        let wild = StrokeSettings { size: 0.0, hardness: 4.0, opacity: 0.0, color: [0; 4], erase: true }.to_brush();
        assert_eq!(wild.size, 1.0);
        assert_eq!(wild.hardness, 1.0);
        assert_eq!(wild.opacity, 0.01);
        assert!(wild.erase);
        wild.validate().expect("clamping must keep the brush valid");

        let huge = StrokeSettings { size: 1.0e9, ..StrokeSettings::default() }.to_brush();
        assert_eq!(huge.size, MAX_BRUSH_DIAMETER);
        assert!(StrokeSettings { size: 5.0, ..StrokeSettings::default() }.engine(2.0).is_ok());
    }

    #[test]
    fn a_click_lays_its_dab_when_the_stroke_finishes() {
        let mut target = Bitmap8::new(32, 32);
        let engine = settings(8.0, 1.0, [255, 0, 0, 255]).engine(1.0).unwrap();
        let stroke = Stroke::begin(&engine, PointF::new(16.0, 16.0)).unwrap();
        let progress = stroke.finish(&mut target, None);
        assert!(progress.changed);
        assert!(progress.dabs >= 1);
        assert_eq!(target.get(16, 16), [255, 0, 0, 255]);
        assert_eq!(target.get(0, 0), [0, 0, 0, 0]);
    }

    #[test]
    fn dragging_paints_the_pixels_between_the_samples() {
        let target = painted(settings(6.0, 1.0, [0, 255, 0, 255]), 32, &[(8.0, 8.0), (24.0, 8.0)], None);
        for x in [10u32, 14, 18, 22] {
            assert!(target.get(x, 8)[3] > 0, "gap at x={x}");
        }
        assert_eq!(target.get(8, 24)[3], 0);
    }

    #[test]
    fn opacity_caps_the_stroke_instead_of_accumulating_per_dab() {
        let target = painted(
            settings(12.0, 0.5, [0, 0, 255, 255]),
            32,
            &[(10.0, 16.0), (22.0, 16.0), (10.0, 16.0), (22.0, 16.0)],
            None,
        );
        let alpha = target.get(16, 16)[3];
        assert!((120..=136).contains(&alpha), "half opacity should stay near 128, got {alpha}");
    }

    #[test]
    fn the_eraser_clears_alpha_where_it_passes() {
        let mut target = Bitmap8::filled(32, 32, [10, 200, 30, 255]);
        let mut brush = settings(10.0, 1.0, [0, 0, 0, 255]);
        brush.erase = true;
        let engine = brush.engine(1.0).unwrap();
        let mut stroke = Stroke::begin(&engine, PointF::new(16.0, 16.0)).unwrap();
        stroke.extend(&mut target, PointF::new(16.0, 16.0), None);
        stroke.finish(&mut target, None);
        assert_eq!(target.get(16, 16)[3], 0);
        assert_eq!(target.get(1, 1), [10, 200, 30, 255]);
    }

    #[test]
    fn a_selection_mask_clips_the_stroke() {
        let mask = selection_mask(32, 32, (0.0, 0.0), (16.0, 32.0)).expect("a mask");
        let target = painted(settings(16.0, 1.0, [255, 255, 255, 255]), 32, &[(8.0, 16.0), (28.0, 16.0)], Some(&mask));
        assert!(target.get(8, 16)[3] > 0);
        assert_eq!(target.get(26, 16)[3], 0);
        assert_eq!(target.get(20, 16)[3], 0);
    }

    #[test]
    fn a_mask_that_misses_the_layer_paints_nothing() {
        let mask = selection_mask(32, 32, (100.0, 100.0), (140.0, 140.0)).expect("a mask");
        let target = painted(settings(16.0, 1.0, [255, 255, 255, 255]), 32, &[(8.0, 16.0), (24.0, 16.0)], Some(&mask));
        assert!(target.is_fully_transparent());
    }

    #[test]
    fn a_stroke_far_outside_the_bitmap_changes_nothing_and_does_not_panic() {
        let mut target = Bitmap8::new(32, 32);
        let engine = settings(10.0, 1.0, [255, 0, 0, 255]).engine(1.0).unwrap();
        let mut stroke = Stroke::begin(&engine, PointF::new(-500.0, -500.0)).unwrap();
        let extended = stroke.extend(&mut target, PointF::new(-460.0, -500.0), None);
        let error = stroke.error();
        let finished = stroke.finish(&mut target, None);
        assert!(!extended.changed && !finished.changed);
        assert!(error.is_none(), "an off-canvas sample is not an engine error");
        assert!(target.is_fully_transparent());
    }

    #[test]
    fn the_stroke_bounds_cover_what_it_painted() {
        let mut target = Bitmap8::new(64, 64);
        let engine = settings(8.0, 1.0, [0, 0, 0, 255]).engine(1.0).unwrap();
        let mut stroke = Stroke::begin(&engine, PointF::new(10.0, 10.0)).unwrap();
        stroke.extend(&mut target, PointF::new(40.0, 10.0), None);
        let bounds = stroke.bounds().expect("a painted stroke reports bounds");
        assert!(bounds.0 <= 6, "bounds start at {}", bounds.0);
        assert!(bounds.0 + bounds.2 as i64 >= 43, "bounds end at {}", bounds.0 + bounds.2 as i64);
        assert!(bounds.1 <= 6 && bounds.1 + bounds.3 as i64 >= 13);
        assert!(bounds.2 > 20, "the stroke is a horizontal run, not a square");
        stroke.finish(&mut target, None);
    }

    #[test]
    fn a_mask_scratch_round_trips_its_gray_values() {
        let mut mask = Gray8::new(4, 3);
        for y in 0..3 {
            for x in 0..4 {
                mask.set(x, y, (x * 20 + y * 7) as u8);
            }
        }
        let scratch = mask_to_scratch(&mask);
        assert_eq!(scratch.width(), 4);
        assert_eq!(scratch.height(), 3);
        assert_eq!(scratch.get(2, 1), [mask.get(2, 1), mask.get(2, 1), mask.get(2, 1), 255]);
        let restored = scratch_to_mask(&scratch);
        assert_eq!(restored.pixels(), mask.pixels());
    }

    #[test]
    fn a_paint_color_becomes_the_gray_it_stands_for_on_a_mask() {
        assert_eq!(mask_gray([255, 255, 255, 255]), 255);
        assert_eq!(mask_gray([0, 0, 0, 255]), 0);
        // A pure green is the 0.59 weight of the compositor's luminosity.
        assert_eq!(mask_gray([0, 255, 0, 255]), 150);
        assert_eq!(mask_gray([128, 128, 128, 255]), 128);
    }

    #[test]
    fn painting_a_scratch_leaves_the_mask_blended_toward_the_paint_color() {
        let mask = Gray8::filled(32, 32, 255);
        let mut scratch = mask_to_scratch(&mask);
        let mut brush = settings(12.0, 1.0, [0, 0, 0, 255]);
        brush.size = 12.0;
        let engine = brush.engine(1.0).unwrap();
        let stroke = Stroke::begin(&engine, PointF::new(16.0, 16.0)).unwrap();
        stroke.finish(&mut scratch, None);
        let restored = scratch_to_mask(&scratch);
        assert_eq!(restored.get(16, 16), 0, "an opaque black dab hides the mask");
        assert_eq!(restored.get(1, 1), 255, "far from the dab the mask stays");
    }

    #[test]
    fn the_selection_mask_reports_nothing_for_a_degenerate_request() {
        assert!(selection_mask(0, 10, (0.0, 0.0), (1.0, 1.0)).is_none());
        assert!(selection_mask(10, 10, (f32::NAN, 0.0), (1.0, 1.0)).is_none());
        let full = selection_mask(8, 8, (0.0, 0.0), (8.0, 8.0)).unwrap();
        assert_eq!(full.get(4, 4), 255);
        assert_eq!(full.get(0, 0), 255);
    }
}
