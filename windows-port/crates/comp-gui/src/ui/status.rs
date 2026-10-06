//! The status bar: canvas size, zoom, tool, memory and the render report.

use egui::{Color32, RichText};

use crate::app::GuiApp;
use crate::ui::{format_bytes, format_zoom};

impl GuiApp {
    /// The guide the keyboard is working on, with somewhere to type its position.
    fn guide_readout(&mut self, ui: &mut egui::Ui) {
        let Some(id) = self.selected_guide else { return };
        let Some(guide) = self.editor.guides().iter().find(|guide| guide.id == id).copied() else {
            self.selected_guide = None;
            return;
        };
        let axis = match guide.axis {
            comp_core::geom::GuideAxis::Vertical => "x",
            comp_core::geom::GuideAxis::Horizontal => "y",
        };
        ui.label(RichText::new("Guide").weak());
        ui.label(RichText::new(axis).monospace());
        let mut position = guide.position;
        let response = ui.add_enabled(
            !self.guides_locked,
            egui::DragValue::new(&mut position).speed(1.0).range(0.0..=100_000.0),
        );
        if response.drag_started() {
            self.editor.begin_edit("Move Guide");
        }
        if response.changed() {
            self.editor.move_guide(id, position);
        }
        if response.drag_stopped() {
            self.editor.finish_edit();
        }
        if self.guides_locked {
            ui.label(RichText::new("locked").weak().small());
        }
        if ui
            .small_button("x")
            .on_hover_text("Delete this guide")
            .clicked()
            && !self.guides_locked
        {
            self.editor.remove_guide(id);
            self.selected_guide = None;
        }
        ui.separator();
    }

    /// Which subject extractor answers, and what the last run reported.
    ///
    /// The line is always there, before anything is run, so the answer to "did I get the model or the
    /// fallback" is never hidden behind an action: a classical backend also carries the three places a
    /// model file is looked for.
    fn subject_control(&mut self, ui: &mut egui::Ui) {
        let line = crate::subject::status_line(&self.subject_backend);
        let by_model = matches!(self.subject_backend, crate::subject::Backend::Model { .. });
        let text = RichText::new(line).small();
        let text = if by_model { text.color(Color32::from_rgb(140, 220, 150)) } else { text.weak() };
        let mut response = ui.label(text);
        if let Some(advice) = crate::subject::hint(&self.subject_backend) {
            response = response.on_hover_text(advice);
        } else if let crate::subject::Backend::Model { description, .. } = &self.subject_backend {
            if !description.is_empty() {
                response = response.on_hover_text(description.clone());
            }
        }
        let _ = response;
        if let Some(last) = &self.last_subject {
            ui.separator();
            ui.label(RichText::new(last).small().weak())
                .on_hover_text("Who answered the last Select Subject or Remove Background, and how long it took");
        }
        ui.separator();
    }

    /// The compositor the canvas is drawn with, its device, and the switch that overrules it.
    fn backend_control(&mut self, ui: &mut egui::Ui) {
        let availability = crate::engine::availability(&self.editor.document);
        let line = crate::backend::status_line(self.backend_preference, self.last_backend, &availability);
        let used_gpu = self.last_backend == Some(crate::backend::Backend::Gpu);
        let text = RichText::new(line).small();
        let text = if used_gpu { text.color(Color32::from_rgb(140, 220, 150)) } else { text.weak() };
        ui.label(text).on_hover_text(
            "A whole-canvas render and an export use the GPU when it can take the document; a stroke \
             repaints a small rectangle, which stays on the CPU.",
        );
        let switch = if self.backend_preference == crate::backend::Preference::PreferGpu {
            "Force CPU"
        } else {
            "Prefer GPU"
        };
        if ui
            .small_button(switch)
            .on_hover_text("Switch the compositor for the next render")
            .clicked()
        {
            self.backend_preference = self.backend_preference.flipped();
            self.last_backend = None;
            // The picture on screen has to be the one the new setting produces.
            self.request_render(true);
        }
    }

    pub(crate) fn status_bar(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            if self.io.is_busy() || self.render.is_busy() {
                ui.spinner();
            }
            if !self.editor.message.is_empty() {
                let color = if self.editor.message_is_error {
                    Color32::from_rgb(235, 130, 120)
                } else {
                    ui.visuals().weak_text_color()
                };
                ui.label(RichText::new(&self.editor.message).color(color));
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                self.guide_readout(ui);
                self.subject_control(ui);
                self.backend_control(ui);
                ui.separator();
                let memory = self.editor.memory_estimate();
                ui.label(
                    RichText::new(format!(
                        "Doc {} / History {}",
                        format_bytes(memory.document_bytes),
                        format_bytes(memory.history_bytes)
                    ))
                    .weak(),
                );
                ui.separator();
                ui.label(RichText::new(format!("{} ms", self.render_millis)).weak());
                ui.separator();
                if self.editor.mask_painting {
                    ui.label(RichText::new("Mask").color(Color32::from_rgb(120, 190, 255)));
                }
                ui.label(RichText::new(self.editor.tool().name()).strong());
                ui.separator();
                if ui.small_button("1:1").on_hover_text("Actual pixels (Ctrl+1)").clicked() {
                    self.actual_pixels();
                }
                if ui.small_button("Fit").on_hover_text("Fit to window (Ctrl+0)").clicked() {
                    self.fit_to_window();
                }
                ui.label(RichText::new(format_zoom(self.editor.view.zoom)).strong());
                ui.separator();
                let (width, height) = self.editor.document_size();
                ui.label(RichText::new(format!("{width} x {height}")).strong());
            });
        });
    }
}
