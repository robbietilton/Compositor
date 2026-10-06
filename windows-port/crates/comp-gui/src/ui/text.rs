//! The text panel: content, face, size, color and alignment for the layer being edited.

use comp_core::text::TextAlignment;
use egui::RichText;

use crate::app::GuiApp;

/// How many faces the picker lists at once; the list is searchable, so this is a budget, not a cap.
const FACE_PREVIEW: usize = 40;

impl GuiApp {
    pub(crate) fn text_panel(&mut self, ui: &mut egui::Ui) {
        let Some((layer, draft)) = self.text_edit.as_ref().map(|session| (session.layer, session.draft.clone())) else {
            self.offer_text_edit(ui);
            return;
        };
        let mut draft = draft;
        let mut changed = false;
        let mut draw = false;
        let mut done = false;
        let uncommitted = self.text_edit.as_ref().map(|session| session.uncommitted).unwrap_or(false);

        ui.separator();
        ui.horizontal(|ui| {
            ui.heading("Text");
            if uncommitted {
                ui.label(RichText::new("pixels out of date").color(egui::Color32::from_rgb(220, 180, 90)).small());
            }
        });

        let output = egui::TextEdit::multiline(&mut draft.content)
            .desired_rows(3)
            .desired_width(f32::INFINITY)
            .show(ui);
        changed |= output.response.changed();
        // The selection is in characters; run offsets count UTF-16 units, so it is converted below.
        let selected = output
            .cursor_range
            .map(|range| {
                // egui reports character indices; run offsets count UTF-16 units.
                let first: usize = range.primary.index.into();
                let second: usize = range.secondary.index.into();
                (first.min(second), first.max(second))
            })
            .filter(|(start, end)| start != end);

        ui.horizontal(|ui| {
            let ready = selected.is_some();
            let length = draft.content.encode_utf16().count();
            if ui
                .add_enabled(ready, egui::Button::new("Color selection"))
                .on_hover_text("Set the selected characters to the text color")
                .clicked()
            {
                if let Some((start, end)) = selected {
                    let (start, end) = crate::runs::utf16_range(&draft.content, start..end);
                    let mut list = draft.color_runs.clone().unwrap_or_default();
                    crate::runs::set_color(&mut list, start, end, [draft.red, draft.green, draft.blue], length);
                    draft.color_runs = (!list.is_empty()).then_some(list);
                    changed = true;
                }
            }
            if ui
                .add_enabled(ready, egui::Button::new("Face selection"))
                .on_hover_text("Set the selected characters to the face above")
                .clicked()
            {
                if let Some((start, end)) = selected {
                    let (start, end) = crate::runs::utf16_range(&draft.content, start..end);
                    let mut list = draft.font_runs.clone().unwrap_or_default();
                    crate::runs::set_font(&mut list, start, end, &draft.font_name, length);
                    draft.font_runs = (!list.is_empty()).then_some(list);
                    changed = true;
                }
            }
            if ui
                .add_enabled(draft.color_runs.is_some(), egui::Button::new("Clear color"))
                .on_hover_text("Take every color run off the selection")
                .clicked()
            {
                let (start, end) = match selected {
                    Some((start, end)) => crate::runs::utf16_range(&draft.content, start..end),
                    None => (0, length),
                };
                let mut list = draft.color_runs.clone().unwrap_or_default();
                crate::runs::clear_color(&mut list, start, end, length);
                draft.color_runs = (!list.is_empty()).then_some(list);
                changed = true;
            }
            if ui
                .add_enabled(draft.font_runs.is_some(), egui::Button::new("Clear face"))
                .on_hover_text("Take every font run off the selection")
                .clicked()
            {
                let (start, end) = match selected {
                    Some((start, end)) => crate::runs::utf16_range(&draft.content, start..end),
                    None => (0, length),
                };
                let mut list = draft.font_runs.clone().unwrap_or_default();
                crate::runs::clear_font(&mut list, start, end, length);
                draft.font_runs = (!list.is_empty()).then_some(list);
                changed = true;
            }
        });
        ui.label(
            RichText::new(match selected {
                Some((start, end)) => format!("{} character(s) selected", end - start),
                None => "Select text in the field above to give it its own color or face.".to_string(),
            })
            .weak()
            .small(),
        );

        ui.horizontal(|ui| {
            let mut boxed = draft.box_size.is_some();
            if ui
                .checkbox(&mut boxed, "Paragraph box")
                .on_hover_text("Wrap the text inside a fixed box instead of a single run of lines")
                .changed()
            {
                draft.box_size = boxed.then(|| comp_core::text::SizeD::new(400.0, 200.0));
                changed = true;
            }
            if let Some(size) = draft.box_size.as_mut() {
                let min = comp_core::limits::MIN_TEXT_BOX_SIDE;
                let max = 8000.0;
                changed |= ui
                    .add(egui::DragValue::new(&mut size.width).range(min..=max).speed(1.0).prefix("w "))
                    .changed();
                changed |= ui
                    .add(egui::DragValue::new(&mut size.height).range(min..=max).speed(1.0).prefix("h "))
                    .changed();
                let (runs_color, runs_font) = (draft.color_runs.as_ref().map(Vec::len), draft.font_runs.as_ref().map(Vec::len));
                ui.label(
                    RichText::new(format!(
                        "{} color run(s), {} font run(s)",
                        runs_color.unwrap_or(0),
                        runs_font.unwrap_or(0)
                    ))
                    .weak()
                    .small(),
                );
            }
        });

        ui.horizontal(|ui| {
            ui.label("Size");
            changed |= ui.add(egui::DragValue::new(&mut draft.font_size).range(1.0..=2000.0).speed(0.5)).changed();
            ui.label("Tracking");
            changed |= ui.add(egui::DragValue::new(&mut draft.tracking).range(-100.0..=1000.0).speed(0.2)).changed();
            ui.label("Leading");
            changed |= ui.add(egui::DragValue::new(&mut draft.leading).range(0.0..=5000.0).speed(0.2)).changed();
        });

        ui.horizontal(|ui| {
            ui.label("Align");
            for (alignment, label) in [
                (TextAlignment::Left, "Left"),
                (TextAlignment::Center, "Center"),
                (TextAlignment::Right, "Right"),
            ] {
                if ui.selectable_label(draft.alignment == alignment, label).clicked() {
                    draft.alignment = alignment;
                    changed = true;
                }
            }
        });

        // The text colour comes from the shared panel, so it matches the brush and the effects.
        ui.collapsing("Color", |ui| {
            let mut color = [
                (draft.red * 255.0).round().clamp(0.0, 255.0) as u8,
                (draft.green * 255.0).round().clamp(0.0, 255.0) as u8,
                (draft.blue * 255.0).round().clamp(0.0, 255.0) as u8,
                255,
            ];
            if self.color_panel(ui, "text-color", &mut color) {
                draft.red = color[0] as f64 / 255.0;
                draft.green = color[1] as f64 / 255.0;
                draft.blue = color[2] as f64 / 255.0;
                changed = true;
            }
        });

        ui.horizontal(|ui| {
            ui.label("Face");
            changed |= ui.add(egui::TextEdit::singleline(&mut draft.font_name).desired_width(170.0)).changed();
        });

        let mut filter = self.font_filter.clone();
        ui.collapsing("Installed faces", |ui| {
            ui.add(egui::TextEdit::singleline(&mut filter).hint_text("search").desired_width(f32::INFINITY));
            let needle = filter.to_lowercase();
            let names = self.with_fonts(|library, _| {
                library
                    .faces()
                    .iter()
                    .map(|face| face.full_name.clone())
                    .filter(|name| needle.is_empty() || name.to_lowercase().contains(&needle))
                    .take(FACE_PREVIEW)
                    .collect::<Vec<String>>()
            });
            for name in names {
                if ui.selectable_label(false, &name).clicked() {
                    draft.font_name = name;
                    changed = true;
                }
            }
        });
        self.font_filter = filter;

        ui.horizontal(|ui| {
            if ui.button("Draw").on_hover_text("Rasterize the text into the layer").clicked() {
                draw = true;
            }
            if ui.button("Done").on_hover_text("Draw and close the text panel").clicked() {
                draw = true;
                done = true;
            }
            if ui.button("Revert").on_hover_text("Throw the draft away").clicked() {
                self.text_edit = None;
            }
        });

        if changed {
            self.apply_text_draft(layer, draft);
        }
        if draw {
            self.commit_text_session();
        }
        if done {
            self.text_edit = None;
        }
    }

    /// The panel's idle state: an offer to edit the selected layer when it holds text.
    fn offer_text_edit(&mut self, ui: &mut egui::Ui) {
        let Some(id) = self.editor.document.active_layer else { return };
        if self.editor.text_style(id).is_none() {
            return;
        }
        ui.separator();
        ui.horizontal(|ui| {
            ui.label(RichText::new("Text layer").weak());
            if ui.button("Edit text").clicked() {
                self.begin_text_session(id);
            }
        });
    }
}
