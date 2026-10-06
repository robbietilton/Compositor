//! The canvas widget: it draws the flattened composite and routes pointer input into the tools.

use egui::{Color32, CornerRadius, CursorIcon, Key, PointerButton, Pos2, Rect, Sense, Stroke, StrokeKind, Vec2};

use comp_core::geom::GuideAxis;

use crate::app::{CanvasDrag, GuiApp};
use crate::tools::{Tool, ToolEffect};
use crate::ui::guides::GuideDrag;
use crate::view::CanvasView;

impl GuiApp {
    pub(crate) fn canvas(&mut self, ui: &mut egui::Ui) {
        let (response, painter) = ui.allocate_painter(ui.available_size(), Sense::click_and_drag());
        let panel = response.rect;
        // The rulers take a strip off the top and the left; the canvas is what is left of the panel.
        let inset = if self.show_rulers { crate::ui::guides::RULER_THICKNESS } else { 0.0 };
        let viewport = Rect::from_min_max(panel.min + Vec2::splat(inset), panel.max);
        self.canvas_rect = Some(viewport);
        let (width, height) = self.editor.document_size();
        // Sticky placements follow the widget as the window resizes.
        self.editor.view.refresh(viewport, width as f32, height as f32);

        let painter = painter.with_clip_rect(panel);
        painter.rect_filled(panel, CornerRadius::ZERO, Color32::from_gray(38));

        self.handle_pointer(ui, &response, viewport);

        // Everything that belongs to the canvas is clipped to the canvas, not to the rulers.
        let canvas = painter.with_clip_rect(viewport);
        let document_rect = self.editor.view.doc_rect_on_screen(width as f32, height as f32);
        draw_checkerboard(&canvas, document_rect, viewport);
        if let Some(texture) = &self.texture {
            canvas.image(
                texture.id(),
                document_rect,
                Rect::from_min_max(Pos2::ZERO, Pos2::new(1.0, 1.0)),
                Color32::WHITE,
            );
        }
        // The red Quick-Mask overlay sits on top of the composite it is describing.
        if self.mask_view == crate::app::MaskView::Red {
            if let Some(overlay) = &self.mask_texture {
                canvas.image(
                    overlay.id(),
                    document_rect,
                    Rect::from_min_max(Pos2::ZERO, Pos2::new(1.0, 1.0)),
                    Color32::WHITE,
                );
            }
        }
        canvas.rect_stroke(
            document_rect,
            CornerRadius::ZERO,
            Stroke::new(1.0, Color32::from_gray(130)),
            StrokeKind::Outside,
        );
        self.draw_grid(&canvas, viewport);
        self.draw_overlays(ui, &canvas, viewport);
        self.draw_guides(&canvas, viewport);
        self.draw_guide_bubble(&canvas, viewport);
        if self.show_rulers {
            let hover = ui.input(|input| input.pointer.hover_pos());
            self.draw_rulers(&painter, panel, viewport, hover);
        }
    }

    fn handle_pointer(&mut self, ui: &mut egui::Ui, response: &egui::Response, viewport: Rect) {
        struct Pointer {
            hover: Option<Pos2>,
            primary_pressed: bool,
            primary_down: bool,
            primary_released: bool,
            secondary_clicked: bool,
            middle_pressed: bool,
            middle_down: bool,
            space: bool,
            delta: Vec2,
            scroll: Vec2,
            zoom_delta: f32,
            ctrl: bool,
        }
        let input = ui.input(|i| Pointer {
            hover: i.pointer.hover_pos(),
            primary_pressed: i.pointer.primary_pressed(),
            primary_down: i.pointer.primary_down(),
            primary_released: i.pointer.primary_released(),
            secondary_clicked: i.pointer.secondary_clicked(),
            middle_pressed: i.pointer.button_pressed(PointerButton::Middle),
            middle_down: i.pointer.middle_down(),
            space: i.key_down(Key::Space),
            delta: i.pointer.delta(),
            scroll: i.smooth_scroll_delta,
            zoom_delta: i.zoom_delta(),
            ctrl: i.modifiers.ctrl || i.modifiers.command,
        });

        // The wheel zooms around the cursor; with Ctrl held egui reports a pinch-style factor.
        if response.hovered() {
            if let Some(anchor) = input.hover {
                let factor = if input.ctrl {
                    input.zoom_delta
                } else if input.scroll.y != 0.0 {
                    (input.scroll.y / 300.0).exp()
                } else {
                    1.0
                };
                if (factor - 1.0).abs() > 1e-4 {
                    self.editor.view.zoom_at(factor, anchor);
                }
            }
        }

        // A double click takes the word under the pointer and a triple click its paragraph, both
        // through comp-text's own idea of where a word and a paragraph begin.
        if self.editor.tool() == Tool::Text && self.text_edit.is_some() && response.hovered() {
            if let Some(screen) = input.hover {
                let document = self.editor.view.screen_to_doc(screen);
                if response.triple_clicked() {
                    self.text_select_paragraph(document);
                } else if response.double_clicked() {
                    self.text_select_word(document);
                }
            }
        }

        // A guide gesture comes first: pulling one off a ruler, or picking one up, must not paint.
        if input.primary_pressed && response.hovered() {
            if let Some(position) = input.hover {
                // Clicking away from every guide puts the selection back on the document.
                if !self.guides_locked && self.guide_at(position).is_none() {
                    self.selected_guide = None;
                }
                if self.begin_guide_drag(viewport, position) {
                    self.drag = Some(CanvasDrag::Guide);
                }
            }
        }
        if input.secondary_clicked && response.hovered() && !self.guides_locked {
            if let Some(position) = input.hover {
                if let Some(id) = self.guide_at(position) {
                    self.editor.remove_guide(id);
                }
            }
        }

        if self.drag.is_none() {
            if input.middle_pressed && response.hovered() {
                self.drag = Some(CanvasDrag::Pan);
            } else if input.primary_pressed && response.hovered() {
                if input.space {
                    self.drag = Some(CanvasDrag::Pan);
                } else {
                    self.drag = Some(CanvasDrag::Tool);
                    self.tool_press(input.hover);
                }
            }
        }

        match self.drag {
            Some(CanvasDrag::Guide) => {
                if input.primary_down {
                    if let Some(position) = input.hover {
                        self.update_guide_drag(position);
                    }
                } else {
                    self.end_guide_drag(input.hover);
                    self.drag = None;
                }
            }
            Some(CanvasDrag::Pan) => {
                if input.primary_down || input.middle_down {
                    self.editor.view.pan_by(input.delta);
                    ui.ctx().set_cursor_icon(CursorIcon::Grabbing);
                } else {
                    self.drag = None;
                }
            }
            Some(CanvasDrag::Tool) => {
                if input.primary_down {
                    self.tool_drag(input.hover);
                } else {
                    self.tool_release(input.hover);
                    self.drag = None;
                }
            }
            None => {
                if input.space && viewport.contains(input.hover.unwrap_or(Pos2::ZERO)) {
                    ui.ctx().set_cursor_icon(CursorIcon::Grab);
                }
            }
        }

        if input.primary_released && matches!(self.drag, Some(CanvasDrag::Pan)) {
            self.drag = None;
        }
    }

    fn tool_press(&mut self, hover: Option<Pos2>) {
        let Some(screen) = hover else { return };
        let document = self.editor.view.screen_to_doc(screen);
        // With a text draft open, a click on it puts the caret where the pointer landed.
        if self.editor.tool() == Tool::Text && self.text_edit.is_some() && self.text_place_caret(document) {
            self.text_selecting = true;
            self.editor.machine.cancel();
            return;
        }
        if self.editor.tool() == Tool::Move {
            // A drag of the move tool is one undo step, however many frames it lasts.
            self.editor.begin_edit("Move Layer");
        }
        let effect = self.editor.machine.press(document);
        self.apply_effect(effect);
    }

    fn tool_drag(&mut self, hover: Option<Pos2>) {
        let Some(screen) = hover else { return };
        let document = self.editor.view.screen_to_doc(screen);
        // Dragging from the caret stretches the selection, the way a text editor behaves.
        if self.text_selecting {
            self.text_extend_selection(document);
            return;
        }
        let effect = self.editor.machine.drag(document);
        self.apply_effect(effect);
    }

    fn tool_release(&mut self, hover: Option<Pos2>) {
        if self.text_selecting {
            self.text_selecting = false;
            if let Some(screen) = hover {
                self.text_extend_selection(self.editor.view.screen_to_doc(screen));
            }
            return;
        }
        match hover {
            Some(screen) => {
                let document = self.editor.view.screen_to_doc(screen);
                let effect = self.editor.machine.release(document);
                self.apply_effect(effect);
            }
            None => self.editor.machine.cancel(),
        }
        // The editor names the finished stroke in the status bar, so nothing is reported twice.
        if self.editor.is_stroking() {
            self.editor.end_stroke();
        }
        self.editor.finish_edit();
        self.request_render(true);
    }

    /// Applies a tool effect to the document. Painting is throttled because a full composite of a
    /// large canvas is expensive and only the newest state is worth drawing.
    pub(crate) fn apply_effect(&mut self, effect: ToolEffect) {
        match effect {
            ToolEffect::Paint { from, to } => {
                // The press starts the stroke; the first pointer sample, or the release of a click,
                // is what lays paint.
                if self.editor.is_stroking() {
                    if self.editor.stroke_to(to) {
                        self.flush_stroke_dirty();
                    }
                } else {
                    self.editor.begin_stroke(from);
                }
            }
            ToolEffect::Selection { rect } => self.editor.set_selection(rect),
            ToolEffect::TextClick { at } => self.text_click(at),
            ToolEffect::Gradient { from, to } => {
                let (shape, invert, blend) = (self.gradient_shape, self.gradient_invert, self.gradient_blend);
                let from = comp_core::PointF::new(from.x as f64, from.y as f64);
                let to = comp_core::PointF::new(to.x as f64, to.y as f64);
                if self.editor.fill_mask_gradient(shape, from, to, invert, blend) {
                    self.request_render(true);
                }
            }
            ToolEffect::Move { delta } => {
                if let Some(id) = self.editor.document.active_layer {
                    // A move snaps to the guides, the grid, the canvas and other layers' edges.
                    let delta = self.snapped_move(id, delta);
                    self.editor.translate_layer(id, delta);
                }
            }
            ToolEffect::Pick { at } => {
                let flattened = self.flattened.clone();
                match flattened.and_then(|bitmap| self.editor.pick_color(&bitmap, at)) {
                    Some(pixel) => {
                        self.editor.color = [pixel[0], pixel[1], pixel[2], 255];
                        self.editor.set_message(format!("Picked #{:02X}{:02X}{:02X}", pixel[0], pixel[1], pixel[2]));
                    }
                    None => self.editor.set_error("The eyedropper is outside the canvas"),
                }
            }
            ToolEffect::None => {}
        }
    }

    /// Pulls a guide out of a ruler, or picks up the guide under the pointer.
    ///
    /// Returns true when the gesture belongs to a guide, so the tools stay out of it.
    pub(crate) fn begin_guide_drag(&mut self, viewport: Rect, position: Pos2) -> bool {
        let ruler = crate::ui::guides::RULER_THICKNESS;
        if self.show_rulers && position.x >= viewport.min.x - ruler {
            if position.y < viewport.min.y {
                let at = self.snapped_guide_position(GuideAxis::Horizontal, position);
                self.editor.begin_edit("Add Guide");
                if let Some(id) = self.editor.add_guide(GuideAxis::Horizontal, at) {
                    self.guide_drag = Some(GuideDrag { id, axis: GuideAxis::Horizontal, from_ruler: true });
                    return true;
                }
                self.editor.finish_edit();
                return false;
            }
            if position.y >= viewport.min.y - ruler && position.x < viewport.min.x {
                let at = self.snapped_guide_position(GuideAxis::Vertical, position);
                self.editor.begin_edit("Add Guide");
                if let Some(id) = self.editor.add_guide(GuideAxis::Vertical, at) {
                    self.guide_drag = Some(GuideDrag { id, axis: GuideAxis::Vertical, from_ruler: true });
                    return true;
                }
                self.editor.finish_edit();
                return false;
            }
        }
        let Some(id) = self.guide_at(position) else { return false };
        let Some(axis) = self.editor.guides().iter().find(|guide| guide.id == id).map(|guide| guide.axis) else {
            return false;
        };
        // Grabbing a guide selects it, which is what the arrow keys and the readout work on.
        self.selected_guide = Some(id);
        self.editor.begin_edit("Move Guide");
        self.guide_drag = Some(GuideDrag { id, axis, from_ruler: false });
        true
    }

    /// Drags the guide to a position, snapped by the settings.
    pub(crate) fn update_guide_drag(&mut self, position: Pos2) {
        let Some(drag) = self.guide_drag else { return };
        let at = self.snapped_guide_position(drag.axis, position);
        self.editor.move_guide(drag.id, at);
    }

    /// Ends a guide gesture, closing its undo step.
    fn end_guide_drag(&mut self, position: Option<Pos2>) {
        if let Some(position) = position {
            self.update_guide_drag(position);
        }
        if let Some(drag) = self.guide_drag.take() {
            // Dropping a guide back on a ruler deletes it, whether it was just pulled out or moved.
            if self.show_rulers {
                if let (Some(position), Some(canvas)) = (position, self.canvas_rect) {
                    let dropped_on_ruler = match drag.axis {
                        GuideAxis::Vertical => position.x < canvas.min.x,
                        GuideAxis::Horizontal => position.y < canvas.min.y,
                    };
                    if dropped_on_ruler {
                        self.editor.remove_guide(drag.id);
                    }
                }
            }
        }
        self.editor.finish_edit();
    }

    /// Repaints just the pixels the stroke samples changed, instead of the whole canvas.
    pub(crate) fn flush_stroke_dirty(&mut self) {
        if let Some(bounds) = self.editor.take_dirty() {
            self.request_region(bounds);
        }
    }

    /// The frame, the selection and the caret of the text draft.
    ///
    /// The boxes come from comp-text's own geometry, so the caret sits between the characters the
    /// layout actually drew and the highlight covers what a selection would.
    fn draw_text_frame(&self, painter: &egui::Painter) {
        let Some(session) = self.text_edit.as_ref() else { return };
        let (layer, bounds) = (session.layer, session.bounds);
        let Some(entry) = self.editor.document.layer(layer) else { return };
        if bounds.0 == 0 || bounds.1 == 0 {
            return;
        }
        let view = self.editor.view;
        let size = (bounds.0, bounds.1);
        let to_screen = |rect: comp_core::RectF| {
            let rect = crate::textedit::layout_to_canvas(entry, size, rect);
            Rect::from_min_max(
                view.doc_to_screen(Pos2::new(rect.x as f32, rect.y as f32)),
                view.doc_to_screen(Pos2::new(rect.max_x() as f32, rect.max_y() as f32)),
            )
        };
        let origin = view.doc_to_screen(Pos2::new(entry.transform.origin.x as f32, entry.transform.origin.y as f32));
        let rect = Rect::from_min_size(origin, Vec2::new(bounds.0 as f32, bounds.1 as f32) * view.zoom);
        let accent = Color32::from_rgb(120, 190, 255);
        painter.rect_stroke(rect, CornerRadius::ZERO, Stroke::new(1.0, accent), StrokeKind::Middle);

        let Some(layout) = session.layout.as_ref() else { return };
        if let Some(selection) = session.caret.selection() {
            for box_rect in comp_text::selection_rects(layout, selection) {
                painter.rect_filled(to_screen(box_rect), CornerRadius::ZERO, Color32::from_rgba_unmultiplied(120, 190, 255, 70));
            }
        }
        let caret_box = comp_text::caret_rect(layout, session.caret.index).map(to_screen);
        if let Some(rect) = caret_box {
            painter.rect_filled(
                Rect::from_min_size(rect.min, Vec2::new(2.0, rect.height().max(2.0))),
                CornerRadius::ZERO,
                accent,
            );
        }
        // The input method's pre-edit, clause by clause: it is not in the text yet, so it is drawn
        // over it, with the clause being worked on highlighted and its caret where the IME says.
        let Some(render) = self.preedit_render.as_ref() else { return };
        let to_box = |rect: comp_core::RectF| {
            let rect = crate::textedit::layout_to_canvas(entry, size, rect);
            Rect::from_min_max(
                view.doc_to_screen(Pos2::new(rect.x as f32, rect.y as f32)),
                view.doc_to_screen(Pos2::new(rect.max_x() as f32, rect.max_y() as f32)),
            )
        };
        // The highlight goes under the text so the characters stay readable.
        for (style, rect) in &render.clauses {
            if style.highlight {
                painter.rect_filled(to_box(*rect), CornerRadius::ZERO, Color32::from_rgba_unmultiplied(120, 190, 255, 60));
            }
        }
        let bounds = to_box(render.bounds);
        let font = (session.draft.font_size as f32 * view.zoom).clamp(1.0, 512.0);
        painter.text(
            bounds.left_top(),
            egui::Align2::LEFT_TOP,
            self.composition.preedit_text(),
            egui::FontId::proportional(font),
            Color32::WHITE,
        );
        for (style, rect) in &render.clauses {
            let box_rect = to_box(*rect);
            if style.underline {
                painter.line_segment([box_rect.left_bottom(), box_rect.right_bottom()], Stroke::new(1.5, accent));
            }
            if style.bold {
                // The default face has no bold, so the active clause is drawn a second time a hair
                // to the side, which reads as heavier without needing another font.
                painter.text(
                    box_rect.left_top() + Vec2::new(0.6, 0.0),
                    egui::Align2::LEFT_TOP,
                    self.composition.preedit_text(),
                    egui::FontId::proportional(font),
                    Color32::WHITE,
                );
                painter.rect_stroke(box_rect, CornerRadius::ZERO, Stroke::new(1.0, accent), StrokeKind::Inside);
            }
        }
        // The caret comes from the pre-edit, not from the end of the string.
        let caret = to_box(render.caret);
        painter.rect_filled(
            Rect::from_min_size(caret.min, Vec2::new(2.0, caret.height().max(2.0))),
            CornerRadius::ZERO,
            accent,
        );
        // A tick showing where the candidate list is being pointed at, and which way it opens. The
        // platform draws the list itself; this is what makes the anchor visible when it does not.
        if let Some(anchor) = render.anchor {
            let box_rect = to_box(anchor.rect);
            let mark = match anchor.direction {
                comp_text::AnchorDirection::Down => box_rect.left_bottom() + Vec2::new(0.0, 5.0),
                comp_text::AnchorDirection::Up => box_rect.left_top() - Vec2::new(0.0, 5.0),
            };
            painter.circle_filled(mark, 2.5, accent);
        }
    }

    fn draw_overlays(&self, ui: &egui::Ui, painter: &egui::Painter, viewport: Rect) {
        let view = self.editor.view;
        if let Some(selection) = self.editor.selection {
            let rect = Rect::from_min_max(view.doc_to_screen(selection.min), view.doc_to_screen(selection.max));
            painter.rect_stroke(rect, CornerRadius::ZERO, Stroke::new(1.0, Color32::WHITE), StrokeKind::Middle);
            painter.rect_stroke(
                rect.expand(1.0),
                CornerRadius::ZERO,
                Stroke::new(1.0, Color32::from_black_alpha(160)),
                StrokeKind::Middle,
            );
        }
        self.draw_text_frame(painter);
        let Some(position) = ui.input(|i| i.pointer.hover_pos()) else { return };
        if !viewport.contains(position) {
            return;
        }
        match self.editor.tool() {
            Tool::Brush | Tool::Eraser => {
                let radius = (self.editor.brush.size * 0.5 * view.zoom).clamp(1.5, 2000.0);
                painter.circle_stroke(position, radius, Stroke::new(1.0, Color32::from_gray(240)));
                painter.circle_stroke(position, radius + 1.0, Stroke::new(1.0, Color32::from_black_alpha(140)));
            }
            Tool::Eyedropper => {
                let stroke = Stroke::new(1.0, Color32::from_gray(240));
                painter.line_segment([position - Vec2::new(10.0, 0.0), position + Vec2::new(10.0, 0.0)], stroke);
                painter.line_segment([position - Vec2::new(0.0, 10.0), position + Vec2::new(0.0, 10.0)], stroke);
            }
            Tool::Text => {
                let stroke = Stroke::new(1.0, Color32::from_gray(240));
                painter.line_segment([position, position + Vec2::new(9.0, 0.0)], stroke);
                painter.line_segment([position, position + Vec2::new(0.0, 9.0)], stroke);
            }
            _ => {}
        }
    }
}

/// Draws the transparency checkerboard inside the document rectangle.
fn draw_checkerboard(painter: &egui::Painter, document_rect: Rect, viewport: Rect) {
    let visible = document_rect.intersect(viewport);
    if !visible.is_positive() {
        return;
    }
    let cell = CanvasView::checker_cell(visible.size(), 8.0, 4000.0);
    painter.rect_filled(visible, CornerRadius::ZERO, Color32::from_gray(64));
    let first_column = ((visible.min.x - document_rect.min.x) / cell).floor() as i64;
    let first_row = ((visible.min.y - document_rect.min.y) / cell).floor() as i64;
    let columns = ((visible.width() / cell).ceil() as i64).max(1);
    let rows = ((visible.height() / cell).ceil() as i64).max(1);
    let light = Color32::from_gray(88);
    for row in 0..rows {
        for column in 0..columns {
            if (first_row + row + first_column + column) % 2 != 0 {
                continue;
            }
            let min = visible.min
                + Vec2::new(
                    (first_column + column) as f32 * cell,
                    (first_row + row) as f32 * cell,
                );
            let square = Rect::from_min_size(min, Vec2::splat(cell)).intersect(visible);
            if square.is_positive() {
                painter.rect_filled(square, CornerRadius::ZERO, light);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_checkerboard_stays_within_its_shape_budget() {
        // The drawing loop relies on the pure helper to bound its shape count.
        let cell = CanvasView::checker_cell(Vec2::new(4000.0, 3000.0), 8.0, 4000.0);
        assert!((4000.0 / cell).ceil() * (3000.0 / cell).ceil() <= 4000.0);
    }
}
