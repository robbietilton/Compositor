//! The Camera Raw filter window.

use comp_raw::RawSettings;
use comp_core::effects::EffectColor;
use comp_render::filters::DitherStyle;
use egui::{Context, RichText};

use crate::app::GuiApp;
use crate::filters::{FilterKind, FilterMenu};

/// The dither styles the combo offers, in the order the macOS panel lists them.
const DITHER_STYLES: [DitherStyle; 11] = [
    DitherStyle::Atkinson,
    DitherStyle::FloydSteinberg,
    DitherStyle::Bayer2,
    DitherStyle::Bayer4,
    DitherStyle::Bayer8,
    DitherStyle::Dots,
    DitherStyle::Lines,
    DitherStyle::Diamonds,
    DitherStyle::Patterns,
    DitherStyle::Ascii,
    DitherStyle::Scanlines,
];

fn dither_style_name(style: DitherStyle) -> &'static str {
    match style {
        DitherStyle::Atkinson => "Atkinson",
        DitherStyle::FloydSteinberg => "Floyd-Steinberg",
        DitherStyle::Bayer2 => "Bayer 2x2",
        DitherStyle::Bayer4 => "Bayer 4x4",
        DitherStyle::Bayer8 => "Bayer 8x8",
        DitherStyle::Dots => "Dots",
        DitherStyle::Lines => "Lines",
        DitherStyle::Diamonds => "Diamonds",
        DitherStyle::Patterns => "Patterns",
        DitherStyle::Ascii => "ASCII",
        DitherStyle::Scanlines => "Scanlines",
    }
}

/// A labelled slider, drawn only when the filter that owns it is the one being edited.
fn slider(ui: &mut egui::Ui, value: &mut f64, range: (f64, f64), label: &str, shown: bool) {
    if shown {
        ui.add(egui::Slider::new(value, range.0..=range.1).text(label));
    }
}



/// One slider: the label, the settings field, and the range the engine documents.
struct RawSlider {
    label: &'static str,
    pick: fn(&mut RawSettings) -> &mut f64,
    range: (f64, f64),
}

const SLIDERS: [RawSlider; 7] = [
    RawSlider { label: "Exposure", pick: |settings| &mut settings.exposure, range: comp_raw::EXPOSURE_RANGE },
    RawSlider { label: "Contrast", pick: |settings| &mut settings.contrast, range: comp_raw::TONE_RANGE },
    RawSlider { label: "Highlights", pick: |settings| &mut settings.highlights, range: comp_raw::TONE_RANGE },
    RawSlider { label: "Shadows", pick: |settings| &mut settings.shadows, range: comp_raw::TONE_RANGE },
    RawSlider { label: "Temperature", pick: |settings| &mut settings.temperature, range: comp_raw::UNIT_RANGE },
    RawSlider { label: "Saturation", pick: |settings| &mut settings.saturation, range: comp_raw::TONE_RANGE },
    RawSlider { label: "Vibrance", pick: |settings| &mut settings.vibrance, range: comp_raw::TONE_RANGE },
];

impl GuiApp {
    /// The dialog a filter with settings opens before it runs.
    pub(crate) fn filter_window(&mut self, ctx: &Context) {
        // The settings are not Copy, so the dialog works on its own copy and writes it back.
        let Some((kind, mut parameters)) = self.filter_dialog.clone() else { return };
        let mut open = true;
        let mut run = false;
        let mut cancel = false;
        egui::Window::new(kind.name())
            .collapsible(false)
            .resizable(false)
            .open(&mut open)
            .show(ctx, |ui| {
                ui.label(RichText::new("Runs on the selected layer's pixels, as one undo step.").weak().small());
                slider(ui, &mut parameters.radius, crate::filters::RADIUS_RANGE, "Radius", kind == FilterKind::GaussianBlur);
                if kind == FilterKind::MotionBlur {
                    slider(ui, &mut parameters.angle, crate::filters::ANGLE_RANGE, "Angle", true);
                    slider(ui, &mut parameters.distance, crate::filters::DISTANCE_RANGE, "Distance", true);
                }
                if kind == FilterKind::AddNoise {
                    slider(ui, &mut parameters.amount, crate::filters::AMOUNT_RANGE, "Amount", true);
                    ui.checkbox(&mut parameters.gaussian, "Gaussian");
                    ui.checkbox(&mut parameters.monochromatic, "Monochromatic");
                }
                if kind == FilterKind::Vignette {
                    slider(ui, &mut parameters.vignette_amount, crate::filters::VIGNETTE_AMOUNT_RANGE, "Amount", true);
                    slider(ui, &mut parameters.vignette_midpoint, crate::filters::VIGNETTE_MIDPOINT_RANGE, "Midpoint", true);
                    slider(ui, &mut parameters.vignette_roundness, crate::filters::VIGNETTE_ROUNDNESS_RANGE, "Roundness", true);
                    slider(ui, &mut parameters.vignette_feather, crate::filters::VIGNETTE_FEATHER_RANGE, "Feather", true);
                    slider(ui, &mut parameters.vignette_highlights, crate::filters::VIGNETTE_HIGHLIGHTS_RANGE, "Highlights", true);
                    // The edge colour comes from the shared panel, like every other colour here.
                    let mut bytes = [
                        (parameters.vignette_color.red * 255.0).round().clamp(0.0, 255.0) as u8,
                        (parameters.vignette_color.green * 255.0).round().clamp(0.0, 255.0) as u8,
                        (parameters.vignette_color.blue * 255.0).round().clamp(0.0, 255.0) as u8,
                        255,
                    ];
                    if self.color_panel(ui, "vignette-color", &mut bytes) {
                        parameters.vignette_color = EffectColor {
                            red: bytes[0] as f64 / 255.0,
                            green: bytes[1] as f64 / 255.0,
                            blue: bytes[2] as f64 / 255.0,
                        };
                    }
                }
                if kind == FilterKind::BloomGlow {
                    slider(ui, &mut parameters.bloom_amount, crate::filters::BLOOM_AMOUNT_RANGE, "Amount", true);
                    slider(ui, &mut parameters.bloom_radius, crate::filters::BLOOM_RADIUS_RANGE, "Radius", true);
                }
                if kind == FilterKind::TonalContrast {
                    slider(ui, &mut parameters.tonal_amount, crate::filters::TONAL_AMOUNT_RANGE, "Amount", true);
                    slider(ui, &mut parameters.tonal_radius, crate::filters::TONAL_RADIUS_RANGE, "Radius", true);
                    slider(ui, &mut parameters.tonal_shadows, crate::filters::TONAL_STRENGTH_RANGE, "Shadows", true);
                    slider(ui, &mut parameters.tonal_midtones, crate::filters::TONAL_STRENGTH_RANGE, "Midtones", true);
                    slider(ui, &mut parameters.tonal_highlights, crate::filters::TONAL_STRENGTH_RANGE, "Highlights", true);
                }
                if kind == FilterKind::LensCorrection {
                    slider(ui, &mut parameters.distortion, crate::filters::DISTORTION_RANGE, "Remove distortion", true);
                }
                if kind == FilterKind::Dither {
                    ui.horizontal(|ui| {
                        ui.label("Style");
                        let mut style = parameters.dither.style;
                        egui::ComboBox::from_id_salt("dither-style")
                            .selected_text(dither_style_name(style))
                            .show_ui(ui, |ui| {
                                for option in DITHER_STYLES {
                                    ui.selectable_value(&mut style, option, dither_style_name(option));
                                }
                            });
                        parameters.dither.style = style;
                    });
                    // The two dither colours, from the same panel every other colour comes from.
                    let dark = [
                        (parameters.dither.dark.red * 255.0).round().clamp(0.0, 255.0) as u8,
                        (parameters.dither.dark.green * 255.0).round().clamp(0.0, 255.0) as u8,
                        (parameters.dither.dark.blue * 255.0).round().clamp(0.0, 255.0) as u8,
                        255,
                    ];
                    ui.horizontal(|ui| {
                        ui.label("Dark");
                        if let Some(picked) = self.color_button(ui, "dither-dark", dark) {
                            parameters.dither.dark = EffectColor {
                                red: picked[0] as f64 / 255.0,
                                green: picked[1] as f64 / 255.0,
                                blue: picked[2] as f64 / 255.0,
                            };
                        }
                    });
                    let light = [
                        (parameters.dither.light.red * 255.0).round().clamp(0.0, 255.0) as u8,
                        (parameters.dither.light.green * 255.0).round().clamp(0.0, 255.0) as u8,
                        (parameters.dither.light.blue * 255.0).round().clamp(0.0, 255.0) as u8,
                        255,
                    ];
                    ui.horizontal(|ui| {
                        ui.label("Light");
                        if let Some(picked) = self.color_button(ui, "dither-light", light) {
                            parameters.dither.light = EffectColor {
                                red: picked[0] as f64 / 255.0,
                                green: picked[1] as f64 / 255.0,
                                blue: picked[2] as f64 / 255.0,
                            };
                        }
                    });
                    slider(ui, &mut parameters.dither.pixel_size, crate::filters::DITHER_PIXEL_RANGE, "Pixel size", true);
                    slider(ui, &mut parameters.dither.levels, crate::filters::DITHER_LEVELS_RANGE, "Levels", true);
                    slider(ui, &mut parameters.dither.diffusion, crate::filters::DITHER_PERCENT_RANGE, "Diffusion", true);
                    slider(ui, &mut parameters.dither.density, crate::filters::DITHER_TONE_RANGE, "Density", true);
                    slider(ui, &mut parameters.dither.contrast, crate::filters::DITHER_TONE_RANGE, "Contrast", true);
                }
                ui.horizontal(|ui| {
                    if ui.button("Apply").clicked() {
                        run = true;
                    }
                    if ui.button("Cancel").clicked() {
                        cancel = true;
                    }
                });
            });
        if let Some((_, current)) = self.filter_dialog.as_mut() {
            *current = parameters.clone();
        }
        if run {
            self.filter_dialog = None;
            self.apply_filter(kind, parameters);
        } else if cancel || !open {
            self.filter_dialog = None;
        }
    }

    /// The prompt a package changed outside the editor raises.
    pub(crate) fn watch_window(&mut self, ctx: &Context) {
        let Some(missing) = self.watch_prompt else { return };
        let modified = self.editor.is_modified();
        let path = self
            .watch_state
            .path()
            .map(|path| path.display().to_string())
            .unwrap_or_else(|| "The project".to_string());
        let mut reload = false;
        let mut keep = false;
        let mut save = false;
        egui::Window::new("Project changed on disk")
            .collapsible(false)
            .resizable(false)
            .show(ctx, |ui| {
                ui.label(if missing {
                    format!("{path} cannot be read any more.")
                } else {
                    format!("{path} was changed by another program.")
                });
                if modified {
                    ui.label(
                        RichText::new("This document has unsaved edits: reloading would discard them.")
                            .color(egui::Color32::from_rgb(220, 180, 90)),
                    );
                }
                ui.horizontal(|ui| {
                    if ui.button("Reload from disk").clicked() {
                        reload = true;
                    }
                    if ui.button("Keep my edits").on_hover_text("Leave the file alone and work on").clicked() {
                        keep = true;
                    }
                    if modified && ui.button("Save mine over it").clicked() {
                        save = true;
                    }
                });
            });
        if reload {
            self.reload_from_disk();
        } else if keep {
            self.keep_my_edits();
        } else if save {
            self.watch_prompt = None;
            self.save();
        }
    }

    pub(crate) fn raw_window(&mut self, ctx: &Context) {
        if self.raw.is_none() {
            return;
        }
        let mut open = true;
        let mut reset = false;
        let mut apply = false;
        let mut cancel = false;
        egui::Window::new("Camera Raw")
            .collapsible(false)
            .resizable(false)
            .open(&mut open)
            .show(ctx, |ui| {
                ui.label(RichText::new("A grade of the layer's pixels, as one undo step.").weak().small());
                let Some(edit) = self.raw.as_mut() else { return };
                let mut touched = false;
                for slider in SLIDERS.iter() {
                    let value = *(slider.pick)(edit.settings_mut());
                    let mut local = value;
                    let response = ui.add(
                        egui::Slider::new(&mut local, slider.range.0..=slider.range.1).text(slider.label),
                    );
                    if response.changed() {
                        *(slider.pick)(edit.settings_mut()) = local;
                        touched = true;
                    }
                }
                if touched {
                    self.refresh_raw_preview();
                }
                ui.horizontal(|ui| {
                    if ui.button("Reset").clicked() {
                        reset = true;
                    }
                    if ui.button("Apply").clicked() {
                        apply = true;
                    }
                    if ui.button("Cancel").clicked() {
                        cancel = true;
                    }
                });
            });
        if reset {
            if let Some(edit) = self.raw.as_mut() {
                edit.reset();
            }
            self.refresh_raw_preview();
        }
        if apply {
            self.close_raw_panel(true);
        } else if cancel || !open {
            self.close_raw_panel(false);
        }
    }
}
