//! The tool strip: tool selection, brush settings and the paint color.

use crate::app::GuiApp;
use crate::tools::Tool;

impl GuiApp {
    pub(crate) fn tool_bar(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            for tool in Tool::ALL {
                let selected = self.editor.tool() == tool;
                let response = ui
                    .selectable_label(selected, tool.name())
                    .on_hover_text(format!("{} ({})", tool.name(), tool.key()));
                if response.clicked() {
                    self.choose_tool(tool);
                }
            }

            ui.separator();

            if self.editor.tool().paints() {
                ui.label("Size");
                let mut size = self.editor.brush.size;
                if ui.add(egui::Slider::new(&mut size, 1.0..=500.0).suffix(" px")).changed() {
                    self.editor.brush.size = size;
                }
                ui.label("Hardness");
                let mut hardness = self.editor.brush.hardness * 100.0;
                if ui.add(egui::Slider::new(&mut hardness, 0.0..=100.0).suffix("%")).changed() {
                    self.editor.brush.hardness = (hardness / 100.0).clamp(0.0, 1.0);
                }
                ui.label("Opacity");
                let mut opacity = self.editor.brush.opacity * 100.0;
                if ui.add(egui::Slider::new(&mut opacity, 1.0..=100.0).suffix("%")).changed() {
                    self.editor.brush.opacity = (opacity / 100.0).clamp(0.01, 1.0);
                }
                if let Some(id) = self.editor.document.active_layer {
                    if self.editor.has_mask(id) {
                        let mut painting = self.editor.mask_painting;
                        if ui
                            .checkbox(&mut painting, "Paint mask")
                            .on_hover_text("Paint the layer's mask instead of its pixels")
                            .changed()
                        {
                            self.editor.mask_painting = painting;
                        }
                    }
                }
                ui.separator();
            }

            ui.label("Color");
            // The swatch shows the paint colour and opens the shared panel, where it is picked.
            let swatch = self.editor.color;
            let button = ui.add(
                egui::Button::new(egui::RichText::new("  ").background_color(egui::Color32::from_rgba_unmultiplied(
                    swatch[0],
                    swatch[1],
                    swatch[2],
                    swatch[3],
                )))
                .min_size(egui::vec2(28.0, 18.0)),
            );
            if button.on_hover_text("Paint color; the eyedropper sets it too").clicked() {
                self.show_color_panel = true;
            }
            ui.label(
                egui::RichText::new(format!("#{:02X}{:02X}{:02X}", swatch[0], swatch[1], swatch[2]))
                    .monospace()
                    .weak(),
            );

            if self.editor.selection.is_some() {
                ui.separator();
                ui.label(egui::RichText::new(selection_label(self.editor.selection)).weak());
                if ui.button("Deselect").clicked() {
                    self.editor.deselect();
                }
            }

            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if self.editor.is_modified() {
                    ui.label(egui::RichText::new("Unsaved changes").weak());
                }
                ui.separator();
                let can_grade = self
                    .editor
                    .document
                    .active_layer
                    .and_then(|id| self.editor.document.layer(id))
                    .map(|layer| layer.image.is_some() && !layer.is_group && layer.adjustment.is_none())
                    .unwrap_or(false);
                if ui
                    .add_enabled(can_grade, egui::Button::new("Camera Raw"))
                    .on_hover_text("Grade the selected layer's pixels")
                    .clicked()
                {
                    self.begin_raw_panel();
                }
            });
        });
    }
}

/// A short description of the marquee, in document pixels.
fn selection_label(selection: Option<egui::Rect>) -> String {
    match selection {
        Some(rect) => format!(
            "Selection {:.0} x {:.0} at {:.0}, {:.0}",
            rect.width(),
            rect.height(),
            rect.min.x,
            rect.min.y
        ),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_selection_label_reports_the_pixel_rectangle() {
        let rect = egui::Rect::from_min_size(egui::Pos2::new(4.0, 6.0), egui::Vec2::new(32.4, 12.6));
        assert_eq!(selection_label(Some(rect)), "Selection 32 x 13 at 4, 6");
        assert_eq!(selection_label(None), "");
    }
}
