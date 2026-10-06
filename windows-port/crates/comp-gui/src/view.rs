//! Canvas view math: the mapping between document pixels and screen points.
//!
//! Nothing here touches a window or the GPU, so the transform rules can be tested headlessly and
//! reused by any future viewport (for example a touch or tablet path).

use egui::{Pos2, Rect, Vec2};

/// How the view re-derives itself when the viewport changes size.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FitMode {
    /// The user pans and zooms freely; a resize leaves the placement alone.
    Free,
    /// The whole document stays visible; recomputed on every resize.
    Fit,
    /// 100% zoom, centered.
    Actual,
}

/// Screen-space placement of the document: screen = document * zoom + offset.
///
/// The offset is stored rather than a document center because a pan drag is then a plain add and
/// cannot drift when the zoom changes.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CanvasView {
    pub zoom: f32,
    pub offset: Vec2,
    pub mode: FitMode,
}

impl Default for CanvasView {
    fn default() -> Self {
        CanvasView { zoom: 1.0, offset: Vec2::ZERO, mode: FitMode::Fit }
    }
}

impl CanvasView {
    /// 3% zoom, far enough out to inspect a whole large composition.
    pub const MIN_ZOOM: f32 = 1.0 / 32.0;
    /// 3200% zoom, the level pixel artists use to place single pixels.
    pub const MAX_ZOOM: f32 = 32.0;
    /// Screen padding kept around the document when fitting.
    pub const FIT_MARGIN: f32 = 24.0;

    pub fn clamp_zoom(zoom: f32) -> f32 {
        if zoom.is_finite() {
            zoom.clamp(Self::MIN_ZOOM, Self::MAX_ZOOM)
        } else {
            1.0
        }
    }

    pub fn doc_to_screen(&self, point: Pos2) -> Pos2 {
        (point.to_vec2() * self.zoom + self.offset).to_pos2()
    }

    pub fn screen_to_doc(&self, point: Pos2) -> Pos2 {
        (point - self.offset) / self.zoom
    }

    pub fn doc_size_on_screen(&self, width: f32, height: f32) -> Vec2 {
        Vec2::new(width, height) * self.zoom
    }

    /// The document rectangle as it appears on screen.
    pub fn doc_rect_on_screen(&self, width: f32, height: f32) -> Rect {
        Rect::from_min_size(self.offset.to_pos2(), self.doc_size_on_screen(width, height))
    }

    /// The document pixel under a screen point; may be outside the canvas.
    pub fn doc_pixel_at(&self, point: Pos2) -> (i64, i64) {
        let doc = self.screen_to_doc(point);
        (doc.x.floor() as i64, doc.y.floor() as i64)
    }

    /// The part of the document currently visible, in document coordinates.
    pub fn visible_doc_rect(&self, viewport: Rect) -> Rect {
        Rect::from_min_max(self.screen_to_doc(viewport.min), self.screen_to_doc(viewport.max))
    }

    pub fn pan_by(&mut self, delta: Vec2) {
        self.offset += delta;
        self.mode = FitMode::Free;
    }

    /// Zooms so that the document point under the anchor stays under the anchor.
    pub fn zoom_at(&mut self, factor: f32, anchor: Pos2) {
        self.set_zoom_at(self.zoom * factor, anchor);
    }

    /// Sets an absolute zoom while holding the anchor point.
    pub fn set_zoom_at(&mut self, zoom: f32, anchor: Pos2) {
        let held = self.screen_to_doc(anchor);
        self.zoom = Self::clamp_zoom(zoom);
        self.offset = anchor.to_vec2() - held.to_vec2() * self.zoom;
        self.mode = FitMode::Free;
    }

    /// Fits the whole document inside the viewport, centered, with a small margin.
    pub fn fit(&mut self, viewport: Rect, width: f32, height: f32) {
        if width <= 0.0 || height <= 0.0 || viewport.width() <= 0.0 || viewport.height() <= 0.0 {
            return;
        }
        let available = Vec2::new(
            (viewport.width() - 2.0 * Self::FIT_MARGIN).max(1.0),
            (viewport.height() - 2.0 * Self::FIT_MARGIN).max(1.0),
        );
        self.zoom = Self::clamp_zoom((available.x / width).min(available.y / height));
        self.center(viewport, width, height);
        self.mode = FitMode::Fit;
    }

    /// 100% zoom, centered, as the Actual pixels command does.
    pub fn actual_size(&mut self, viewport: Rect, width: f32, height: f32) {
        self.zoom = 1.0;
        self.center(viewport, width, height);
        self.mode = FitMode::Actual;
    }

    fn center(&mut self, viewport: Rect, width: f32, height: f32) {
        self.offset = viewport.center().to_vec2() - Vec2::new(width, height) * 0.5 * self.zoom;
    }

    /// Re-applies the sticky placement after the viewport changed.
    ///
    /// Doubling the cell keeps the checkerboard behind a transparent canvas within a shape budget:
    /// an unbounded 8-point grid over a large viewport would cost tens of thousands of rectangles.
    pub fn checker_cell(visible: Vec2, base: f32, limit: f32) -> f32 {
        let mut cell = base.max(1.0);
        while (visible.x / cell).ceil() * (visible.y / cell).ceil() > limit {
            cell *= 2.0;
        }
        cell
    }

    pub fn refresh(&mut self, viewport: Rect, width: f32, height: f32) {
        match self.mode {
            FitMode::Fit => self.fit(viewport, width, height),
            FitMode::Actual => self.actual_size(viewport, width, height),
            FitMode::Free => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn viewport() -> Rect {
        Rect::from_min_size(Pos2::new(0.0, 20.0), Vec2::new(800.0, 600.0))
    }

    fn assert_close(left: f32, right: f32) {
        assert!((left - right).abs() < 1e-3, "{left} != {right}");
    }

    #[test]
    fn screen_and_document_coordinates_round_trip() {
        let mut view = CanvasView::default();
        view.zoom = 2.5;
        view.offset = Vec2::new(120.0, -40.0);
        let doc = Pos2::new(37.25, 91.5);
        let screen = view.doc_to_screen(doc);
        let back = view.screen_to_doc(screen);
        assert_close(back.x, doc.x);
        assert_close(back.y, doc.y);
    }

    #[test]
    fn zooming_holds_the_point_under_the_cursor() {
        let mut view = CanvasView::default();
        view.zoom = 1.0;
        view.offset = Vec2::new(10.0, 10.0);
        let anchor = Pos2::new(300.0, 200.0);
        let before = view.screen_to_doc(anchor);
        view.zoom_at(1.75, anchor);
        let after = view.screen_to_doc(anchor);
        assert_close(before.x, after.x);
        assert_close(before.y, after.y);
        assert_close(view.zoom, 1.75);
        assert_eq!(view.mode, FitMode::Free);
    }

    #[test]
    fn zoom_is_clamped_to_the_supported_range() {
        assert_eq!(CanvasView::clamp_zoom(1000.0), CanvasView::MAX_ZOOM);
        assert_eq!(CanvasView::clamp_zoom(0.0001), CanvasView::MIN_ZOOM);
        assert_eq!(CanvasView::clamp_zoom(f32::NAN), 1.0);
        let mut view = CanvasView::default();
        view.zoom_at(1_000_000.0, Pos2::ZERO);
        assert_close(view.zoom, CanvasView::MAX_ZOOM);
    }

    #[test]
    fn fit_centers_the_document_and_keeps_the_margin() {
        let mut view = CanvasView::default();
        let area = viewport();
        view.fit(area, 400.0, 300.0);
        // The 600-point-tall viewport, minus its margins, is the tighter axis.
        assert_close(view.zoom, (600.0 - 48.0) / 300.0);
        let rect = view.doc_rect_on_screen(400.0, 300.0);
        assert_close(rect.center().x, area.center().x);
        assert_close(rect.center().y, area.center().y);
        assert!(rect.width() <= area.width() && rect.height() <= area.height());
        assert_eq!(view.mode, FitMode::Fit);
    }

    #[test]
    fn fit_uses_the_tighter_axis() {
        let mut view = CanvasView::default();
        view.fit(viewport(), 4000.0, 100.0);
        assert_close(view.zoom, (800.0 - 48.0) / 4000.0);
    }

    #[test]
    fn actual_size_is_one_to_one_and_centered() {
        let mut view = CanvasView::default();
        let area = viewport();
        view.actual_size(area, 1000.0, 700.0);
        assert_close(view.zoom, 1.0);
        let rect = view.doc_rect_on_screen(1000.0, 700.0);
        assert_close(rect.center().x, area.center().x);
        assert_close(rect.center().y, area.center().y);
        assert_eq!(view.mode, FitMode::Actual);
    }

    #[test]
    fn refresh_reapplies_the_sticky_mode() {
        let mut view = CanvasView::default();
        let area = viewport();
        view.fit(area, 200.0, 200.0);
        let zoomed = view.zoom;
        let wider = Rect::from_min_size(Pos2::ZERO, Vec2::new(1600.0, 1200.0));
        view.refresh(wider, 200.0, 200.0);
        assert!(view.zoom > zoomed, "a wider viewport fits the document larger");
        view.actual_size(area, 200.0, 200.0);
        view.refresh(Rect::from_min_size(Pos2::ZERO, Vec2::new(400.0, 400.0)), 200.0, 200.0);
        assert_close(view.zoom, 1.0);
        view.mode = FitMode::Free;
        let offset = view.offset;
        view.refresh(Rect::from_min_size(Pos2::ZERO, Vec2::new(99.0, 99.0)), 200.0, 200.0);
        assert_eq!(view.offset, offset);
    }

    #[test]
    fn document_pixels_floor_toward_the_origin() {
        let mut view = CanvasView::default();
        view.zoom = 2.0;
        view.offset = Vec2::ZERO;
        assert_eq!(view.doc_pixel_at(Pos2::new(4.0, 6.0)), (2, 3));
        assert_eq!(view.doc_pixel_at(Pos2::new(-0.5, 0.5)), (-1, 0));
    }

    #[test]
    fn the_checkerboard_cell_grows_until_it_fits_the_shape_budget() {
        assert_eq!(CanvasView::checker_cell(Vec2::new(80.0, 40.0), 8.0, 4000.0), 8.0);
        let enlarged = CanvasView::checker_cell(Vec2::new(4000.0, 3000.0), 8.0, 4000.0);
        assert!(enlarged > 8.0);
        assert!((4000.0 / enlarged).ceil() * (3000.0 / enlarged).ceil() <= 4000.0);
    }

    #[test]
    fn panning_moves_the_view_and_marks_it_free() {
        let mut view = CanvasView::default();
        view.mode = FitMode::Fit;
        view.pan_by(Vec2::new(15.0, -5.0));
        assert_eq!(view.offset, Vec2::new(15.0, -5.0));
        assert_eq!(view.mode, FitMode::Free);
    }

    #[test]
    fn the_visible_rectangle_matches_the_viewport_corners() {
        let mut view = CanvasView::default();
        view.zoom = 4.0;
        view.offset = Vec2::new(-8.0, -8.0);
        let area = Rect::from_min_size(Pos2::new(0.0, 0.0), Vec2::new(80.0, 40.0));
        let visible = view.visible_doc_rect(area);
        assert_close(visible.min.x, 2.0);
        assert_close(visible.min.y, 2.0);
        assert_close(visible.max.x, 22.0);
        assert_close(visible.max.y, 12.0);
    }
}
