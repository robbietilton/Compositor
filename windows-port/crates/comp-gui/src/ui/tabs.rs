//! The tab bar: one tab per open package, with a way to add and close them.

use egui::RichText;

use crate::app::GuiApp;

impl GuiApp {
    /// The strip of tabs above the canvas.
    pub(crate) fn tab_bar(&mut self, ui: &mut egui::Ui) {
        let titles: Vec<(String, bool)> = (0..self.tabs.len())
            .map(|index| (self.project_title(index), self.project_modified(index)))
            .collect();
        let mut switch = None;
        let mut close = None;
        let mut add = false;
        ui.horizontal(|ui| {
            for (index, (title, modified)) in titles.iter().enumerate() {
                let active = index == self.active_tab;
                let label = if *modified { format!("*{title}") } else { title.clone() };
                let response = ui
                    .selectable_label(active, RichText::new(label))
                    .on_hover_text(if *modified {
                        "This tab has unsaved edits"
                    } else {
                        "Show this project"
                    });
                if response.clicked() {
                    switch = Some(index);
                }
                // The close button belongs to the tab it sits on, so it is drawn right after it.
                if ui
                    .small_button("x")
                    .on_hover_text("Close this tab")
                    .clicked()
                {
                    close = Some(index);
                }
                ui.separator();
            }
            if ui.small_button("+").on_hover_text("New document in a new tab").clicked() {
                add = true;
            }
            if self.tabs.len() > 1 {
                ui.label(
                    RichText::new(format!("{} open", self.tabs.len()))
                        .weak()
                        .small(),
                );
            }
        });
        if let Some(index) = switch {
            self.switch_tab(index);
        }
        if let Some(index) = close {
            self.close_tab(index);
        }
        if add {
            self.new_tab();
        }
    }

    /// A new document of its own in a new tab.
    pub(crate) fn new_tab(&mut self) {
        self.add_tab(crate::session::Editor::with_document(comp_core::Document::with_background(1024, 768)));
        self.editor.set_message("New document in a new tab");
    }

    /// The question a close raises when the tab has unsaved edits.
    pub(crate) fn close_tab_window(&mut self, ctx: &egui::Context) {
        let Some(index) = self.closing_tab else { return };
        if index >= self.tabs.len() {
            self.closing_tab = None;
            return;
        }
        let title = self.project_title(index);
        let mut save = false;
        let mut discard = false;
        let mut cancel = false;
        egui::Window::new("Close this tab?")
            .collapsible(false)
            .resizable(false)
            .show(ctx, |ui| {
                ui.label(format!("{title} has unsaved edits."));
                ui.label(
                    RichText::new("Saving writes the package; discarding closes without writing it.")
                        .weak()
                        .small(),
                );
                ui.horizontal(|ui| {
                    if ui.button("Save").clicked() {
                        save = true;
                    }
                    if ui
                        .button("Discard")
                        .on_hover_text("Close the tab and lose these edits")
                        .clicked()
                    {
                        discard = true;
                    }
                    if ui.button("Cancel").clicked() {
                        cancel = true;
                    }
                });
            });
        if save {
            // The save has to finish before the tab can go, so the close waits for it.
            self.closing_tab = None;
            if index == self.active_tab && self.editor.path.is_some() {
                self.save();
                self.pending_close = Some(index);
            } else {
                self.editor.set_error("Save this tab before closing it: switch to it and save");
            }
        } else if discard {
            self.closing_tab = None;
            // Forgetting the edits is what lets the close go through without asking again.
            if index == self.active_tab {
                self.editor.history.mark_saved();
            } else if let Some(project) = self.tabs.get_mut(index) {
                project.editor.history.mark_saved();
            }
            self.close_tab(index);
        } else if cancel {
            self.closing_tab = None;
        }
    }
}
