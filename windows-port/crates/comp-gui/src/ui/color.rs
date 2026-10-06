//! The shared colour panel: the one place a colour is picked.
//!
//! The brush, the text tool and the effect dialogs all show this panel, so a colour picked in one of
//! them is a colour the others understand. Swatches open it too, which keeps the toolbar small.

use egui::{Color32, Pos2, Rect, Sense, Stroke};

use crate::app::GuiApp;
use crate::color::{self, Color, Hsv};

impl GuiApp {
    /// The colour panel. Returns true when the colour changed this frame.
    ///
    /// While a drag is in progress the recent list is not written to, or one gesture would fill it
    /// with every shade the pointer passed over.
    pub(crate) fn color_panel(&mut self, ui: &mut egui::Ui, id: &str, color: &mut Color) -> bool {
        let mut changed = false;
        let mut hsv = color::to_hsv(*color);
        let mut interacting = false;

        // The hue strip.
        let width = ui.available_width().min(240.0).max(80.0);
        let (hue_rect, hue_response) = ui.allocate_exact_size(egui::vec2(width, 14.0), Sense::click_and_drag());
        interacting |= hue_response.dragged() || hue_response.is_pointer_button_down_on();
        if hue_response.is_pointer_button_down_on() || hue_response.dragged() {
            if let Some(position) = ui.ctx().pointer_interact_pos() {
                hsv.hue = (((position.x - hue_rect.min.x) / hue_rect.width()) as f64 * 360.0).clamp(0.0, 359.9);
                changed = true;
            }
        }
        paint_hue_strip(ui.painter(), hue_rect, hsv.hue);

        // The saturation and value square.
        let side = width.min(150.0);
        let (sv_rect, sv_response) = ui.allocate_exact_size(egui::vec2(side, side), Sense::click_and_drag());
        interacting |= sv_response.dragged() || sv_response.is_pointer_button_down_on();
        if sv_response.is_pointer_button_down_on() || sv_response.dragged() {
            if let Some(position) = ui.ctx().pointer_interact_pos() {
                hsv.saturation = (((position.x - sv_rect.min.x) / sv_rect.width()) as f64).clamp(0.0, 1.0);
                hsv.value = (1.0 - ((position.y - sv_rect.min.y) / sv_rect.height()) as f64).clamp(0.0, 1.0);
                changed = true;
            }
        }
        paint_sv_square(ui.painter(), sv_rect, hsv);
        if changed {
            *color = color::from_hsv(hsv, color[3]);
        }

        // The numbers, which are how a colour is set exactly.
        ui.horizontal(|ui| {
            ui.label("H");
            if ui.add(egui::DragValue::new(&mut hsv.hue).range(0.0..=359.9).speed(1.0)).changed() {
                changed = true;
            }
            ui.label("S");
            let mut saturation = hsv.saturation * 100.0;
            if ui.add(egui::DragValue::new(&mut saturation).range(0.0..=100.0).suffix("%").speed(1.0)).changed() {
                hsv.saturation = saturation / 100.0;
                changed = true;
            }
            ui.label("V");
            let mut value = hsv.value * 100.0;
            if ui.add(egui::DragValue::new(&mut value).range(0.0..=100.0).suffix("%").speed(1.0)).changed() {
                hsv.value = value / 100.0;
                changed = true;
            }
        });
        if changed {
            *color = color::from_hsv(hsv, color[3]);
        }

        ui.horizontal(|ui| {
            ui.label("RGB");
            for channel in 0..3 {
                if ui.add(egui::DragValue::new(&mut color[channel]).range(0..=255)).changed() {
                    changed = true;
                }
            }
            ui.label("A");
            if ui.add(egui::DragValue::new(&mut color[3]).range(0..=255)).changed() {
                changed = true;
            }
        });

        let mut hex = color::to_hex(*color);
        ui.horizontal(|ui| {
            ui.label("Hex");
            if ui.add(egui::TextEdit::singleline(&mut hex).desired_width(84.0).id_salt(id)).changed() {
                if let Some(parsed) = color::parse_hex(&hex) {
                    *color = [parsed[0], parsed[1], parsed[2], color[3]];
                    changed = true;
                }
            }
            let swatch = color::Color::from(*color);
            let (rect, _) = ui.allocate_exact_size(egui::vec2(24.0, 16.0), Sense::hover());
            ui.painter().rect_filled(rect, egui::CornerRadius::ZERO, Color32::from_rgba_unmultiplied(swatch[0], swatch[1], swatch[2], swatch[3]));
            ui.painter().rect_stroke(rect, egui::CornerRadius::ZERO, Stroke::new(1.0, Color32::from_gray(90)), egui::StrokeKind::Inside);
        });

        // Presets and the colours this session has used.
        let mut picked: Option<Color> = None;
        ui.horizontal_wrapped(|ui| {
            for preset in color::presets() {
                if swatch_button(ui, preset, id).clicked() {
                    picked = Some(preset);
                }
            }
        });
        if !self.recent_colors.is_empty() {
            ui.label(egui::RichText::new("Recent").weak().small());
            let recent = self.recent_colors.clone();
            ui.horizontal_wrapped(|ui| {
                for entry in recent {
                    if swatch_button(ui, entry, id).clicked() {
                        picked = Some(entry);
                    }
                }
            });
        }
        if let Some(picked) = picked {
            // A preset keeps the alpha the user is working with, which is what Photoshop does.
            *color = [picked[0], picked[1], picked[2], color[3]];
            changed = true;
        }

        if changed && !interacting {
            let entry = *color;
            color::push_recent(&mut self.recent_colors, entry);
        }
        changed
    }
}

/// A small colour square that can be clicked.
fn swatch_button(ui: &mut egui::Ui, color: Color, id: &str) -> egui::Response {
    let (rect, response) = ui.allocate_exact_size(egui::vec2(18.0, 18.0), Sense::click());
    let fill = Color32::from_rgba_unmultiplied(color[0], color[1], color[2], color[3]);
    ui.painter().rect_filled(rect, egui::CornerRadius::ZERO, fill);
    let stroke = if response.hovered() {
        Stroke::new(1.5, Color32::WHITE)
    } else {
        Stroke::new(1.0, Color32::from_gray(90))
    };
    ui.painter().rect_stroke(rect, egui::CornerRadius::ZERO, stroke, egui::StrokeKind::Inside);
    response.on_hover_text(format!("{} {}", color::to_hex(color), id))
}

/// The hue strip: every hue at full saturation and value, with a mark at the current one.
fn paint_hue_strip(painter: &egui::Painter, rect: Rect, hue: f64) {
    const STEPS: usize = 36;
    let mut mesh = egui::Mesh::default();
    for index in 0..=STEPS {
        let t = index as f32 / STEPS as f32;
        let color = color::from_hsv(Hsv { hue: (t as f64) * 360.0, saturation: 1.0, value: 1.0 }, 255);
        let fill = Color32::from_rgb(color[0], color[1], color[2]);
        let x = rect.min.x + rect.width() * t;
        mesh.colored_vertex(Pos2::new(x, rect.min.y), fill);
        mesh.colored_vertex(Pos2::new(x, rect.max.y), fill);
        if index > 0 {
            let base = index as u32 * 2;
            mesh.add_triangle(base - 2, base - 1, base);
            mesh.add_triangle(base - 1, base, base + 1);
        }
    }
    painter.add(mesh);
    let x = rect.min.x + rect.width() * (hue as f32 / 360.0);
    painter.line_segment([Pos2::new(x, rect.min.y), Pos2::new(x, rect.max.y)], Stroke::new(1.5, Color32::WHITE));
}

/// The saturation and value square for the current hue, with a ring at the current colour.
fn paint_sv_square(painter: &egui::Painter, rect: Rect, hsv: Hsv) {
    let pure = color::from_hsv(Hsv { hue: hsv.hue, saturation: 1.0, value: 1.0 }, 255);
    let hue = Color32::from_rgb(pure[0], pure[1], pure[2]);
    let mut mesh = egui::Mesh::default();
    mesh.colored_vertex(rect.left_top(), Color32::WHITE);
    mesh.colored_vertex(rect.right_top(), hue);
    mesh.colored_vertex(rect.left_bottom(), Color32::BLACK);
    mesh.colored_vertex(rect.right_bottom(), Color32::BLACK);
    mesh.add_triangle(0, 1, 2);
    mesh.add_triangle(1, 2, 3);
    painter.add(mesh);
    let at = Pos2::new(
        rect.min.x + rect.width() * hsv.saturation as f32,
        rect.min.y + rect.height() * (1.0 - hsv.value as f32),
    );
    painter.circle_stroke(at, 4.0, Stroke::new(1.5, Color32::WHITE));
}

impl GuiApp {
    /// A colour swatch that opens the shared panel in a popup of our own.
    ///
    /// The picked colour comes back on the frame after the popup changed it: the control draws
    /// before the popup does, so there is nowhere else for it to arrive from. The caller applies it
    /// then, which keeps every write going through the same edit step.
    pub(crate) fn color_button(&mut self, ui: &mut egui::Ui, id: &str, color: Color) -> Option<Color> {
        let (rect, response) = ui.allocate_exact_size(egui::vec2(30.0, 18.0), Sense::click());
        let fill = Color32::from_rgba_unmultiplied(color[0], color[1], color[2], color[3]);
        ui.painter().rect_filled(rect, egui::CornerRadius::ZERO, fill);
        let stroke = if response.hovered() {
            Stroke::new(1.5, Color32::WHITE)
        } else {
            Stroke::new(1.0, Color32::from_gray(90))
        };
        ui.painter()
            .rect_stroke(rect, egui::CornerRadius::ZERO, stroke, egui::StrokeKind::Inside);
        if response.clicked() {
            self.open_color = Some((id.to_string(), rect));
            self.open_color_value = color;
            self.open_color_changed = false;
        }
        let open = self.open_color.as_ref().map(|(open, _)| open == id).unwrap_or(false);
        if open && self.open_color_changed {
            self.open_color_changed = false;
            let picked = self.open_color_value;
            return Some(picked);
        }
        None
    }

    /// The popup the open colour button asked for, drawn once a frame after every panel.
    pub(crate) fn color_popup(&mut self, ctx: &egui::Context) {
        let Some((id, anchor)) = self.open_color.clone() else { return };
        let mut value = self.open_color_value;
        let area = egui::Area::new(egui::Id::new(("color-popup", id.clone())))
            .order(egui::Order::Foreground)
            .fixed_pos(egui::pos2(anchor.left(), anchor.bottom() + 2.0))
            .show(ctx, |ui| {
                egui::Frame::popup(ui.style()).show(ui, |ui| {
                    ui.set_min_width(260.0);
                    if self.color_panel(ui, &id, &mut value) {
                        self.open_color_changed = true;
                    }
                    ui.horizontal(|ui| {
                        if ui.button("Close").clicked() {
                            self.open_color = None;
                        }
                    });
                });
            });
        self.open_color_value = value;
        // A click away from the popup, or Escape, closes it.
        let clicked_outside = ctx.input(|input| {
            input.pointer.any_click()
                && !input
                    .pointer
                    .interact_pos()
                    .map(|position| area.response.rect.contains(position))
                    .unwrap_or(false)
        });
        if clicked_outside || ctx.input(|input| input.key_pressed(egui::Key::Escape)) {
            self.open_color = None;
            self.open_color_changed = false;
        }
    }
}

/// The window a colour swatch opens, so the toolbar can stay a row of buttons.
impl GuiApp {
    pub(crate) fn color_window(&mut self, ctx: &egui::Context) {
        if !self.show_color_panel {
            return;
        }
        let mut open = true;
        let mut color = self.editor.color;
        egui::Window::new("Color")
            .collapsible(false)
            .resizable(false)
            .open(&mut open)
            .show(ctx, |ui| {
                if self.color_panel(ui, "swatch-color", &mut color) {
                    self.editor.color = color;
                }
            });
        self.show_color_panel = open;
    }
}
