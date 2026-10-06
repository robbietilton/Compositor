//! Rulers, the grid and guides on the canvas, and the drags that move them.

use egui::{Align2, Color32, CornerRadius, FontId, Pos2, Rect, Stroke};

use comp_core::geom::GuideAxis;

use crate::app::GuiApp;
use crate::guides::{self, GridSettings, SnapSettings};

/// How thick the ruler strips are, in points.
pub(crate) const RULER_THICKNESS: f32 = 18.0;
/// The colour macOS draws guides in.
const GUIDE_COLOR: Color32 = Color32::from_rgb(0, 255, 255);
/// What a guide is being dragged from or to.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct GuideDrag {
    pub(crate) id: uuid::Uuid,
    pub(crate) axis: GuideAxis,
    /// True while the pointer is still on the ruler, which is when the guide may still be cancelled.
    pub(crate) from_ruler: bool,
}

impl GuiApp {
    /// The ruler strips, their ticks and their numbers.
    pub(crate) fn draw_rulers(&self, painter: &egui::Painter, panel: Rect, viewport: Rect, hover: Option<Pos2>) {
        let view = self.editor.view;
        let (width, height) = self.editor.document_size();
        let origin = view.doc_to_screen(Pos2::new(0.0, 0.0));
        let background = Color32::from_gray(52);
        let line = Color32::from_gray(110);
        let labels = Color32::from_gray(200);
        painter.rect_filled(
            Rect::from_min_max(panel.min, Pos2::new(panel.max.x, viewport.min.y)),
            CornerRadius::ZERO,
            background,
        );
        painter.rect_filled(
            Rect::from_min_max(panel.min, Pos2::new(viewport.min.x, panel.max.y)),
            CornerRadius::ZERO,
            background,
        );
        let corner = Rect::from_min_max(panel.min, viewport.min);
        painter.line_segment([corner.right_top(), corner.right_bottom()], Stroke::new(1.0, line));
        painter.line_segment([corner.left_bottom(), corner.right_bottom()], Stroke::new(1.0, line));

        let step = guides::ruler_step(view.zoom as f64) as f32;
        let font = FontId::proportional(9.0);
        // The top ruler: a tick and a number every step, along the document's width.
        let mut value = 0.0f32;
        while value <= width as f32 + step {
            let x = origin.x + value * view.zoom;
            if x >= viewport.min.x - 1.0 && x <= viewport.max.x + 1.0 {
                painter.line_segment(
                    [Pos2::new(x, panel.min.y + 10.0), Pos2::new(x, panel.min.y + RULER_THICKNESS - 1.0)],
                    Stroke::new(1.0, line),
                );
                painter.text(
                    Pos2::new(x + 2.0, panel.min.y + 1.0),
                    Align2::LEFT_TOP,
                    guides::ruler_label(value as f64),
                    font.clone(),
                    labels,
                );
            }
            value += step;
        }
        // The left ruler: the same down the document's height.
        let mut value = 0.0f32;
        while value <= height as f32 + step {
            let y = origin.y + value * view.zoom;
            if y >= viewport.min.y - 1.0 && y <= viewport.max.y + 1.0 {
                painter.line_segment(
                    [Pos2::new(panel.min.x + 10.0, y), Pos2::new(panel.min.x + RULER_THICKNESS - 1.0, y)],
                    Stroke::new(1.0, line),
                );
                painter.text(
                    Pos2::new(panel.min.x + 1.0, y + 2.0),
                    Align2::LEFT_TOP,
                    guides::ruler_label(value as f64),
                    font.clone(),
                    labels,
                );
            }
            value += step;
        }
        // Where the pointer is, so the rulers read as a measuring tool rather than decoration.
        if let Some(position) = hover {
            if position.x >= viewport.min.x && position.x <= viewport.max.x {
                painter.line_segment(
                    [Pos2::new(position.x, panel.min.y), Pos2::new(position.x, viewport.min.y)],
                    Stroke::new(1.0, Color32::WHITE),
                );
            }
            if position.y >= viewport.min.y && position.y <= viewport.max.y {
                painter.line_segment(
                    [Pos2::new(panel.min.x, position.y), Pos2::new(viewport.min.x, position.y)],
                    Stroke::new(1.0, Color32::WHITE),
                );
            }
        }
    }

    /// The layout grid, drawn under the guides.
    pub(crate) fn draw_grid(&self, painter: &egui::Painter, viewport: Rect) {
        if !self.grid.visible {
            return;
        }
        let view = self.editor.view;
        let (width, height) = self.editor.document_size();
        let origin = view.doc_to_screen(Pos2::new(0.0, 0.0));
        let minor = Color32::from_rgba_unmultiplied(200, 200, 200, 40);
        let major = Color32::from_rgba_unmultiplied(200, 200, 200, 90);
        for x in self.grid.lines(width as f64) {
            let screen = origin.x + x as f32 * view.zoom;
            if screen < viewport.min.x || screen > viewport.max.x {
                continue;
            }
            let color = if self.grid.is_major(x) { major } else { minor };
            painter.line_segment([Pos2::new(screen, viewport.min.y), Pos2::new(screen, viewport.max.y)], Stroke::new(1.0, color));
        }
        for y in self.grid.lines(height as f64) {
            let screen = origin.y + y as f32 * view.zoom;
            if screen < viewport.min.y || screen > viewport.max.y {
                continue;
            }
            let color = if self.grid.is_major(y) { major } else { minor };
            painter.line_segment([Pos2::new(viewport.min.x, screen), Pos2::new(viewport.max.x, screen)], Stroke::new(1.0, color));
        }
    }

    /// The document's guides, with the one being dragged drawn brighter.
    pub(crate) fn draw_guides(&self, painter: &egui::Painter, viewport: Rect) {
        if !self.show_guides {
            return;
        }
        let view = self.editor.view;
        let dragged = self.guide_drag.map(|drag| drag.id);
        for guide in self.editor.guides() {
            if self.hidden_guides.contains(&guide.id) {
                continue;
            }
            let color = if Some(guide.id) == dragged {
                Color32::WHITE
            } else {
                GUIDE_COLOR
            };
            let stroke = Stroke::new(1.0, color);
            match guide.axis {
                GuideAxis::Vertical => {
                    let x = view.doc_to_screen(Pos2::new(guide.position as f32, 0.0)).x;
                    if x >= viewport.min.x && x <= viewport.max.x {
                        painter.line_segment([Pos2::new(x, viewport.min.y), Pos2::new(x, viewport.max.y)], stroke);
                    }
                }
                GuideAxis::Horizontal => {
                    let y = view.doc_to_screen(Pos2::new(0.0, guide.position as f32)).y;
                    if y >= viewport.min.y && y <= viewport.max.y {
                        painter.line_segment([Pos2::new(viewport.min.x, y), Pos2::new(viewport.max.x, y)], stroke);
                    }
                }
            }
        }
    }

    /// The guide under a screen position, within the macOS five-point distance.
    pub(crate) fn guide_at(&self, position: Pos2) -> Option<uuid::Uuid> {
        // A hidden guide cannot be grabbed, and a locked one can be neither grabbed nor deleted.
        if !self.show_guides || self.guides_locked {
            return None;
        }
        let view = self.editor.view;
        let tolerance = guides::SNAP_POINTS as f32;
        let mut best: Option<(f32, uuid::Uuid)> = None;
        for guide in self.editor.guides() {
            if self.hidden_guides.contains(&guide.id) {
                continue;
            }
            let distance = match guide.axis {
                GuideAxis::Vertical => {
                    let x = view.doc_to_screen(Pos2::new(guide.position as f32, 0.0)).x;
                    if position.y < view.doc_to_screen(Pos2::new(0.0, 0.0)).y - tolerance {
                        continue;
                    }
                    (position.x - x).abs()
                }
                GuideAxis::Horizontal => {
                    let y = view.doc_to_screen(Pos2::new(0.0, guide.position as f32)).y;
                    (position.y - y).abs()
                }
            };
            if distance <= tolerance && best.map(|(current, _)| distance < current).unwrap_or(true) {
                best = Some((distance, guide.id));
            }
        }
        best.map(|(_, id)| id)
    }

    /// The position a guide at a screen coordinate would take, snapped by the settings.
    pub(crate) fn snapped_guide_position(&self, axis: GuideAxis, position: Pos2) -> f64 {
        let document = self.editor.view.screen_to_doc(position);
        let value = match axis {
            GuideAxis::Vertical => document.x as f64,
            GuideAxis::Horizontal => document.y as f64,
        };
        if !self.snap.enabled {
            return value;
        }
        let (width, height) = self.editor.document_size();
        let targets = guides::targets(
            axis,
            (width as f64, height as f64),
            self.editor.guides(),
            &self.grid,
            &self.snap,
            &[],
        );
        guides::snap(value, &targets, guides::snap_distance(self.editor.view.zoom as f64))
    }

    /// The bubble a guide drag shows: where the guide is, in document pixels.
    pub(crate) fn draw_guide_bubble(&self, painter: &egui::Painter, viewport: Rect) {
        let Some(drag) = self.guide_drag else { return };
        let Some(guide) = self.editor.guides().iter().find(|guide| guide.id == drag.id) else { return };
        let view = self.editor.view;
        let text = match drag.axis {
            GuideAxis::Vertical => format!("x {}", guide.position.round()),
            GuideAxis::Horizontal => format!("y {}", guide.position.round()),
        };
        let anchor = match drag.axis {
            GuideAxis::Vertical => view.doc_to_screen(Pos2::new(guide.position as f32, 0.0)),
            GuideAxis::Horizontal => view.doc_to_screen(Pos2::new(0.0, guide.position as f32)),
        };
        let at = match drag.axis {
            GuideAxis::Vertical => Pos2::new(anchor.x + 8.0, viewport.min.y + 8.0),
            GuideAxis::Horizontal => Pos2::new(viewport.min.x + 8.0, anchor.y + 8.0),
        };
        let font = FontId::proportional(11.0);
        let galley = painter.layout_no_wrap(text, font, Color32::BLACK);
        let bubble = Rect::from_min_size(at, galley.size() + egui::vec2(8.0, 4.0)).intersect(viewport);
        painter.rect_filled(bubble, CornerRadius::ZERO, Color32::from_rgba_unmultiplied(255, 255, 255, 230));
        painter.galley(bubble.min + egui::vec2(4.0, 2.0), galley, Color32::BLACK);
    }

    /// The settings window behind View > Grid Settings.
    pub(crate) fn grid_window(&mut self, ctx: &egui::Context) {
        if !self.show_grid_dialog {
            return;
        }
        let mut open = true;
        let mut settings: GridSettings = self.grid;
        let mut snap: SnapSettings = self.snap;
        egui::Window::new("Grid and Snapping")
            .collapsible(false)
            .resizable(false)
            .open(&mut open)
            .show(ctx, |ui| {
                ui.checkbox(&mut settings.visible, "Show the grid");
                ui.horizontal(|ui| {
                    ui.label("Line every");
                    ui.add(egui::DragValue::new(&mut settings.spacing).range(guides::GRID_SPACING_RANGE.0..=guides::GRID_SPACING_RANGE.1));
                    ui.label("px, cut into");
                    ui.add(egui::DragValue::new(&mut settings.subdivisions).range(guides::GRID_SUBDIVISION_RANGE.0..=guides::GRID_SUBDIVISION_RANGE.1));
                });
                ui.label(
                    egui::RichText::new(format!("A line every {} px", settings.normalized().step()))
                        .weak()
                        .small(),
                );
                ui.separator();
                ui.checkbox(&mut snap.enabled, "Snap");
                ui.add_enabled_ui(snap.enabled, |ui| {
                    ui.checkbox(&mut snap.guides, "To guides");
                    ui.checkbox(&mut snap.grid, "To the grid");
                    ui.checkbox(&mut snap.document, "To the canvas edges and center");
                    ui.checkbox(&mut snap.layers, "To other layers' edges");
                });
                ui.label(egui::RichText::new("The pull is five screen points wide.").weak().small());
            });
        self.grid = settings.normalized();
        self.snap = snap;
        self.show_grid_dialog = open;
    }
}
