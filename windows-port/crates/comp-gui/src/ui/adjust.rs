//! Panels for adjustment layers and layer effects.
//!
//! Each control writes one field of the layer's record through the editor, which validates it and
//! wraps a whole drag in a single undo step. The JSON-backed adjustment kinds go through the small
//! typed helpers at the bottom, which read and write the keys comp-render reads.

use std::ops::RangeInclusive;

use comp_core::adjustment::{Adjustment, AdjustmentKind, Channel, CurvePoint};
use comp_core::effects::{
    ColorOverlayEffect, InnerGlowEffect, InnerShadowEffect, LayerEffects, OuterGlowEffect, ShadowEffect, StrokeEffect,
};
use egui::RichText;
use uuid::Uuid;

use crate::app::GuiApp;
use crate::parity::ranges;

/// The nine Color Balance sliders, in the order comp-core stores them.
const COLOR_BALANCE_LABELS: [&str; 9] = [
    "Shadows cyan/red",
    "Shadows magenta/green",
    "Shadows yellow/blue",
    "Midtones cyan/red",
    "Midtones magenta/green",
    "Midtones yellow/blue",
    "Highlights cyan/red",
    "Highlights magenta/green",
    "Highlights yellow/blue",
];

/// The effects the panel lists, in the order the macOS panel does.
const EFFECTS: [EffectKind; 6] = [
    EffectKind::Stroke,
    EffectKind::Shadow,
    EffectKind::ColorOverlay,
    EffectKind::InnerShadow,
    EffectKind::OuterGlow,
    EffectKind::InnerGlow,
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum EffectKind {
    Stroke,
    Shadow,
    ColorOverlay,
    InnerShadow,
    OuterGlow,
    InnerGlow,
}

impl EffectKind {
    fn name(self) -> &'static str {
        match self {
            EffectKind::Stroke => "Stroke",
            EffectKind::Shadow => "Drop Shadow",
            EffectKind::ColorOverlay => "Color Overlay",
            EffectKind::InnerShadow => "Inner Shadow",
            EffectKind::OuterGlow => "Outer Glow",
            EffectKind::InnerGlow => "Inner Glow",
        }
    }

    fn is_enabled(self, effects: &LayerEffects) -> bool {
        match self {
            EffectKind::Stroke => effects.stroke.map(|effect| effect.is_enabled()).unwrap_or(false),
            EffectKind::Shadow => effects.shadow.map(|effect| effect.is_enabled()).unwrap_or(false),
            EffectKind::ColorOverlay => effects.color_overlay.map(|effect| effect.is_enabled()).unwrap_or(false),
            EffectKind::InnerShadow => effects.inner_shadow.map(|effect| effect.is_enabled()).unwrap_or(false),
            EffectKind::OuterGlow => effects.outer_glow.map(|effect| effect.is_enabled()).unwrap_or(false),
            EffectKind::InnerGlow => effects.inner_glow.map(|effect| effect.is_enabled()).unwrap_or(false),
        }
    }

    fn set_enabled(self, effects: &mut LayerEffects, on: bool) {
        match self {
            EffectKind::Stroke => {
                effects.stroke = match (on, effects.stroke) {
                    (true, None) => Some(StrokeEffect::default()),
                    (true, Some(mut effect)) => {
                        effect.enabled = Some(true);
                        Some(effect)
                    }
                    (false, Some(mut effect)) => {
                        effect.enabled = Some(false);
                        Some(effect)
                    }
                    (false, None) => None,
                }
            }
            EffectKind::Shadow => {
                effects.shadow = match (on, effects.shadow) {
                    (true, None) => Some(ShadowEffect::default()),
                    (true, Some(mut effect)) => {
                        effect.enabled = Some(true);
                        Some(effect)
                    }
                    (false, Some(mut effect)) => {
                        effect.enabled = Some(false);
                        Some(effect)
                    }
                    (false, None) => None,
                }
            }
            EffectKind::ColorOverlay => {
                effects.color_overlay = match (on, effects.color_overlay) {
                    (true, None) => Some(ColorOverlayEffect::default()),
                    (true, Some(mut effect)) => {
                        effect.enabled = Some(true);
                        Some(effect)
                    }
                    (false, Some(mut effect)) => {
                        effect.enabled = Some(false);
                        Some(effect)
                    }
                    (false, None) => None,
                }
            }
            EffectKind::InnerShadow => {
                effects.inner_shadow = match (on, effects.inner_shadow) {
                    (true, None) => Some(InnerShadowEffect::default()),
                    (true, Some(mut effect)) => {
                        effect.enabled = Some(true);
                        Some(effect)
                    }
                    (false, Some(mut effect)) => {
                        effect.enabled = Some(false);
                        Some(effect)
                    }
                    (false, None) => None,
                }
            }
            EffectKind::OuterGlow => {
                effects.outer_glow = match (on, effects.outer_glow) {
                    (true, None) => Some(OuterGlowEffect::default()),
                    (true, Some(mut effect)) => {
                        effect.enabled = Some(true);
                        Some(effect)
                    }
                    (false, Some(mut effect)) => {
                        effect.enabled = Some(false);
                        Some(effect)
                    }
                    (false, None) => None,
                }
            }
            EffectKind::InnerGlow => {
                effects.inner_glow = match (on, effects.inner_glow) {
                    (true, None) => Some(InnerGlowEffect::default()),
                    (true, Some(mut effect)) => {
                        effect.enabled = Some(true);
                        Some(effect)
                    }
                    (false, Some(mut effect)) => {
                        effect.enabled = Some(false);
                        Some(effect)
                    }
                    (false, None) => None,
                }
            }
        }
    }

    fn remove(self, effects: &mut LayerEffects) {
        match self {
            EffectKind::Stroke => effects.stroke = None,
            EffectKind::Shadow => effects.shadow = None,
            EffectKind::ColorOverlay => effects.color_overlay = None,
            EffectKind::InnerShadow => effects.inner_shadow = None,
            EffectKind::OuterGlow => effects.outer_glow = None,
            EffectKind::InnerGlow => effects.inner_glow = None,
        }
    }
}

/// A slider bound to one adjustment field; the whole drag is one undo step.
fn adjustment_slider(
    app: &mut GuiApp,
    ui: &mut egui::Ui,
    id: Uuid,
    label: &str,
    value: f64,
    range: RangeInclusive<f64>,
    apply: impl Fn(&mut Adjustment, f64),
) {
    let mut local = value;
    let response = ui.add(egui::Slider::new(&mut local, range).text(label));
    let dragging = response.dragged();
    let discrete = response.changed() && !dragging;
    if response.drag_started() || discrete {
        app.editor.begin_edit(label);
    }
    if response.changed() {
        app.editor.update_adjustment(id, |adjustment| apply(adjustment, local));
    }
    if response.drag_stopped() || discrete {
        app.editor.finish_edit();
    }
}

/// A checkbox bound to one boolean adjustment field, as one undo step.
fn adjustment_toggle(
    app: &mut GuiApp,
    ui: &mut egui::Ui,
    id: Uuid,
    label: &str,
    value: bool,
    apply: impl Fn(&mut Adjustment, bool),
) {
    let mut local = value;
    if ui.checkbox(&mut local, label).changed() {
        app.editor.begin_edit(label);
        app.editor.update_adjustment(id, |adjustment| apply(adjustment, local));
        app.editor.finish_edit();
    }
}

/// A slider bound to one effect field, as one undo step.
fn effect_slider(
    app: &mut GuiApp,
    ui: &mut egui::Ui,
    id: Uuid,
    label: &str,
    value: f64,
    range: RangeInclusive<f64>,
    apply: impl Fn(&mut LayerEffects, f64),
) {
    let mut local = value;
    let response = ui.add(egui::Slider::new(&mut local, range).text(label));
    let dragging = response.dragged();
    let discrete = response.changed() && !dragging;
    if response.drag_started() || discrete {
        app.editor.begin_edit(label);
    }
    if response.changed() {
        app.editor.update_effects(id, |effects| apply(effects, local));
    }
    if response.drag_stopped() || discrete {
        app.editor.finish_edit();
    }
}

/// A colour swatch bound to one effect's RGB triple, through the shared panel, as one undo step.
///
/// The key names the control, so two effects' colours cannot open each other's popup.
fn effect_color(
    app: &mut GuiApp,
    ui: &mut egui::Ui,
    layer: Uuid,
    key: &str,
    color: [f64; 3],
    apply: impl Fn(&mut LayerEffects, [f64; 3]),
) {
    let bytes = [to_bytes(color)[0], to_bytes(color)[1], to_bytes(color)[2], 255];
    if let Some(picked) = app.color_button(ui, key, bytes) {
        let picked = [picked[0] as f64 / 255.0, picked[1] as f64 / 255.0, picked[2] as f64 / 255.0];
        app.editor.begin_edit("Effect Color");
        app.editor.update_effects(layer, |effects| apply(effects, picked));
        app.editor.finish_edit();
    }
}

impl GuiApp {
    /// Puts one channel, or every channel, back to a straight line.
    fn reset_curve(&mut self, id: Uuid, channel: usize, all: bool) {
        self.editor.begin_edit("Reset Curve");
        self.editor.update_adjustment(id, move |adjustment| {
            if all {
                adjustment.curves.channels = std::array::from_fn(|_| crate::curve::identity());
            } else {
                adjustment.curves.channels[channel.min(3)] = crate::curve::identity();
            }
        });
        self.editor.finish_edit();
    }

    /// The selected adjustment layer's parameters, one set per kind.
    pub(crate) fn adjustment_panel(&mut self, ui: &mut egui::Ui) {
        let Some(id) = self.editor.document.active_layer else { return };
        let Some(kind) = self.editor.adjustment_kind(id) else { return };
        let Some(adjustment) = self.editor.document.layer(id).and_then(|layer| layer.adjustment.clone()) else { return };

        ui.separator();
        ui.heading(kind.as_str());
        match kind {
            AdjustmentKind::HueSaturation => {
                adjustment_slider(self, ui, id, "Hue", adjustment.hue, ranges::of(ranges::HUE), |a, v| a.hue = v);
                adjustment_slider(self, ui, id, "Saturation", adjustment.saturation, ranges::of(ranges::PERCENT), |a, v| a.saturation = v);
                adjustment_slider(self, ui, id, "Lightness", adjustment.lightness, ranges::of(ranges::PERCENT), |a, v| a.lightness = v);
                adjustment_toggle(self, ui, id, "Colorize", adjustment.colorize, |a, v| a.colorize = v);
            }
            AdjustmentKind::Levels => {
                channel_picker(self, ui);
                let index = self.levels_channel.min(3);
                let range = adjustment.levels.ranges[index];
                let key = |name: &'static str| name;
                adjustment_slider(self, ui, id, key("Black"), range.black, ranges::of(ranges::LEVEL), move |a, v| {
                    a.levels.ranges[index].black = v
                });
                adjustment_slider(self, ui, id, key("Gamma"), range.gamma, 0.1..=9.99, move |a, v| {
                    a.levels.ranges[index].gamma = v
                });
                adjustment_slider(self, ui, id, key("White"), range.white, ranges::of(ranges::LEVEL), move |a, v| {
                    a.levels.ranges[index].white = v
                });
                adjustment_slider(self, ui, id, key("Output black"), range.output_black, ranges::of(ranges::LEVEL), move |a, v| {
                    a.levels.ranges[index].output_black = v
                });
                adjustment_slider(self, ui, id, key("Output white"), range.output_white, ranges::of(ranges::LEVEL), move |a, v| {
                    a.levels.ranges[index].output_white = v
                });
            }
            AdjustmentKind::Curves => {
                channel_picker(self, ui);
                let index = self.levels_channel.min(3);
                let points = adjustment.curves.channels[index].clone();
                if let Some(updated) = curve_editor(self, ui, &points) {
                    self.editor.update_adjustment(id, move |a| {
                        a.curves.channels[index] = updated;
                        // The record notes which channel was last edited, as macOS does.
                        a.curves.channel = channel_of(index);
                    });
                }
                ui.label(
                    RichText::new("Click adds a point, drag moves it, right-click removes it.")
                        .weak()
                        .small(),
                );
                ui.horizontal(|ui| {
                    if ui.button("Reset channel").clicked() {
                        self.reset_curve(id, index, false);
                    }
                    if ui.button("Reset all").on_hover_text("Every channel back to linear").clicked() {
                        self.reset_curve(id, index, true);
                    }
                });
            }
            AdjustmentKind::Exposure => {
                let (exposure, offset, gamma) = exposure_values(&adjustment);
                adjustment_slider(self, ui, id, "Exposure", exposure, ranges::of(ranges::EXPOSURE), |a, v| set_exposure(a, v, offset, gamma));
                adjustment_slider(self, ui, id, "Offset", offset, ranges::of(ranges::OFFSET), |a, v| set_exposure(a, exposure, v, gamma));
                adjustment_slider(self, ui, id, "Gamma", gamma, ranges::of(ranges::GAMMA), |a, v| set_exposure(a, exposure, offset, v));
            }
            AdjustmentKind::GradientMap => {
                let (shadows, highlights, reversed) = gradient_map_values(&adjustment);
                // Both ends come from the shared colour panel, like every other colour in the app.
                ui.collapsing("Colors", |ui| {
                    ui.label("Shadows");
                    let shadow_bytes = to_bytes(shadows);
                    let mut bytes = [shadow_bytes[0], shadow_bytes[1], shadow_bytes[2], 255];
                    if self.color_panel(ui, "gradient-shadows", &mut bytes) {
                        let picked = [bytes[0], bytes[1], bytes[2]];
                        self.editor.begin_edit("Gradient Map");
                        self.editor.update_adjustment(id, move |a| set_gradient_map(a, from_bytes(picked), highlights, reversed));
                        self.editor.finish_edit();
                    }
                    ui.separator();
                    ui.label("Highlights");
                    let highlight_bytes = to_bytes(highlights);
                    let mut bytes = [highlight_bytes[0], highlight_bytes[1], highlight_bytes[2], 255];
                    if self.color_panel(ui, "gradient-highlights", &mut bytes) {
                        let picked = [bytes[0], bytes[1], bytes[2]];
                        self.editor.begin_edit("Gradient Map");
                        self.editor.update_adjustment(id, move |a| set_gradient_map(a, shadows, from_bytes(picked), reversed));
                        self.editor.finish_edit();
                    }
                });
                adjustment_toggle(self, ui, id, "Reversed", reversed, |a, v| {
                    set_gradient_map(a, shadows, highlights, v)
                });
            }
            AdjustmentKind::Grain => {
                let (amount, size, roughness, seed) = grain_values(&adjustment);
                adjustment_slider(self, ui, id, "Amount", amount, ranges::of(ranges::GRAIN_AMOUNT), |a, v| set_grain(a, v, size, roughness, seed));
                adjustment_slider(self, ui, id, "Size", size, ranges::of(ranges::GRAIN_SIZE), |a, v| set_grain(a, amount, v, roughness, seed));
                adjustment_slider(self, ui, id, "Roughness", roughness, ranges::of(ranges::GRAIN_ROUGHNESS), |a, v| set_grain(a, amount, size, v, seed));
                let mut local = seed as f64;
                if ui.add(egui::DragValue::new(&mut local).range(0.0..=u32::MAX as f64).prefix("seed ")).changed() {
                    self.editor.begin_edit("Grain Seed");
                    self.editor.update_adjustment(id, move |a| set_grain(a, amount, size, roughness, local as u64));
                    self.editor.finish_edit();
                }
            }
            AdjustmentKind::Invert => {
                ui.label(RichText::new("Invert has no parameters.").weak());
            }
            AdjustmentKind::BlackWhite => {
                // The six mixes comp-render reads: how much of each colour family survives as gray.
                let weights = black_white_values(&adjustment);
                let (tint, tint_hue, tint_saturation) = black_white_tint(&adjustment);
                for (index, name) in ["Reds", "Yellows", "Greens", "Cyans", "Blues", "Magentas"].iter().enumerate() {
                    adjustment_slider(self, ui, id, name, weights[index], ranges::of(ranges::BLACK_WHITE_MIX), |a, v| {
                        let mut next = weights;
                        next[index] = v;
                        set_black_white(a, next, tint, tint_hue, tint_saturation);
                    });
                }
                adjustment_toggle(self, ui, id, "Tint", tint, |a, v| {
                    set_black_white(a, weights, v, tint_hue, tint_saturation)
                });
                ui.add_enabled_ui(tint, |ui| {
                    ui.collapsing("Tint Color", |ui| {
                        let mut bytes = tint_bytes(tint_hue, tint_saturation);
                        if self.color_panel(ui, "black-white-tint", &mut bytes) {
                            let hsv = crate::color::to_hsv(bytes);
                            self.editor.begin_edit("Black & White Tint");
                            self.editor.update_adjustment(id, move |a| {
                                set_black_white(a, weights, true, hsv.hue, hsv.saturation * 100.0)
                            });
                            self.editor.finish_edit();
                        }
                        ui.label(
                            RichText::new(format!("Hue {:.0}, saturation {:.0}%", tint_hue, tint_saturation))
                                .weak()
                                .small(),
                        );
                    });
                });
            }
            AdjustmentKind::ColorBalance => {
                let settings = adjustment.color_balance_settings.unwrap_or_default();
                let mut preserve = settings.preserve_luminosity;
                let mut values = [
                    settings.shadow_cyan_red,
                    settings.shadow_magenta_green,
                    settings.shadow_yellow_blue,
                    settings.mid_cyan_red,
                    settings.mid_magenta_green,
                    settings.mid_yellow_blue,
                    settings.highlight_cyan_red,
                    settings.highlight_magenta_green,
                    settings.highlight_yellow_blue,
                ];
                // The nine sliders write the whole record, because comp-core stores one struct.
                for index in 0..values.len() {
                    let mut local = values[index];
                    let response = ui.add(egui::Slider::new(&mut local, ranges::of(ranges::COLOR_BALANCE)).text(COLOR_BALANCE_LABELS[index]));
                    let dragging = response.dragged();
                    let discrete = response.changed() && !dragging;
                    if response.drag_started() || discrete {
                        self.editor.begin_edit(COLOR_BALANCE_LABELS[index]);
                    }
                    if response.changed() {
                        values[index] = local;
                        let updated = values;
                        self.editor.update_adjustment(id, move |a| {
                            a.color_balance_settings = Some(comp_core::adjustment::ColorBalanceSettings {
                                shadow_cyan_red: updated[0],
                                shadow_magenta_green: updated[1],
                                shadow_yellow_blue: updated[2],
                                mid_cyan_red: updated[3],
                                mid_magenta_green: updated[4],
                                mid_yellow_blue: updated[5],
                                highlight_cyan_red: updated[6],
                                highlight_magenta_green: updated[7],
                                highlight_yellow_blue: updated[8],
                                preserve_luminosity: preserve,
                            });
                        });
                    }
                    if response.drag_stopped() || discrete {
                        self.editor.finish_edit();
                    }
                }
                if ui.checkbox(&mut preserve, "Preserve luminosity").changed() {
                    let updated = values;
                    self.editor.begin_edit("Preserve Luminosity");
                    self.editor.update_adjustment(id, move |a| {
                        a.color_balance_settings = Some(comp_core::adjustment::ColorBalanceSettings {
                            shadow_cyan_red: updated[0],
                            shadow_magenta_green: updated[1],
                            shadow_yellow_blue: updated[2],
                            mid_cyan_red: updated[3],
                            mid_magenta_green: updated[4],
                            mid_yellow_blue: updated[5],
                            highlight_cyan_red: updated[6],
                            highlight_magenta_green: updated[7],
                            highlight_yellow_blue: updated[8],
                            preserve_luminosity: preserve,
                        });
                    });
                    self.editor.finish_edit();
                }
            }
            AdjustmentKind::GaussianBlur => {
                let radius = adjustment.blur_radius.unwrap_or(4.0);
                adjustment_slider(self, ui, id, "Radius", radius, crate::filters::range(crate::filters::RADIUS_RANGE), |a, v| a.blur_radius = Some(v));
            }
            AdjustmentKind::MotionBlur => {
                let angle = adjustment.motion_angle.unwrap_or(0.0);
                let distance = adjustment.motion_distance.unwrap_or(10.0);
                adjustment_slider(self, ui, id, "Angle", angle, crate::filters::range(crate::filters::ANGLE_RANGE), move |a, v| {
                    a.motion_angle = Some(v);
                    a.motion_distance = Some(distance);
                });
                adjustment_slider(self, ui, id, "Distance", distance, crate::filters::range(crate::filters::DISTANCE_RANGE), move |a, v| {
                    a.motion_angle = Some(angle);
                    a.motion_distance = Some(v);
                });
            }
            AdjustmentKind::AddNoise => {
                let amount = adjustment.noise_amount.unwrap_or(10.0);
                adjustment_slider(self, ui, id, "Amount", amount, crate::filters::range(crate::filters::AMOUNT_RANGE), |a, v| a.noise_amount = Some(v));
                adjustment_toggle(self, ui, id, "Gaussian", adjustment.noise_gaussian.unwrap_or(false), |a, v| {
                    a.noise_gaussian = Some(v)
                });
                adjustment_toggle(self, ui, id, "Monochromatic", adjustment.noise_monochromatic.unwrap_or(true), |a, v| {
                    a.noise_monochromatic = Some(v)
                });
            }
        }
    }

    /// The layer effect switches and parameters.
    pub(crate) fn effects_panel(&mut self, ui: &mut egui::Ui) {
        let Some(id) = self.editor.document.active_layer else { return };
        let Some(layer) = self.editor.document.layer(id) else { return };
        let effects = layer.effects.unwrap_or_default();

        ui.separator();
        ui.horizontal(|ui| {
            ui.heading("Effects");
            if effects.is_empty() {
                ui.label(RichText::new("none").weak());
            }
        });

        // Photoshop gives every effect its own knockout and blend mode. The package format does not:
        // each effect struct in comp-core carries only its own parameters, so this is a note rather
        // than a control - inventing the field here would write a file nothing else can read.
        let mut unavailable = false;
        ui.add_enabled(false, egui::Checkbox::new(&mut unavailable, "Blending options"))
            .on_disabled_hover_text(
                "The format's effects carry colour, opacity, size, blur, angle and inside/outside, and \
                 nothing else. A per-effect blend mode and knockout would need new fields on the effect \
                 records in comp-core and a format version bump.",
            );

        for kind in EFFECTS {
            let enabled = kind.is_enabled(&effects);
            let mut on = enabled;
            ui.horizontal(|ui| {
                if ui.checkbox(&mut on, kind.name()).changed() {
                    self.editor.begin_edit(kind.name());
                    self.editor.update_effects(id, |effects| kind.set_enabled(effects, on));
                    self.editor.finish_edit();
                }
                let present = match kind {
                    EffectKind::Stroke => effects.stroke.is_some(),
                    EffectKind::Shadow => effects.shadow.is_some(),
                    EffectKind::ColorOverlay => effects.color_overlay.is_some(),
                    EffectKind::InnerShadow => effects.inner_shadow.is_some(),
                    EffectKind::OuterGlow => effects.outer_glow.is_some(),
                    EffectKind::InnerGlow => effects.inner_glow.is_some(),
                };
                if present && ui.small_button("remove").clicked() {
                    self.editor.begin_edit(kind.name());
                    self.editor.update_effects(id, |effects| kind.remove(effects));
                    self.editor.finish_edit();
                }
            });
            if !enabled {
                continue;
            }
            match kind {
                EffectKind::Stroke => {
                    if let Some(effect) = effects.stroke {
                        effect_slider(self, ui, id, "Size", effect.size, ranges::of(ranges::STROKE_SIZE), |e, v| {
                            if let Some(stroke) = e.stroke.as_mut() {
                                stroke.size = v;
                            }
                        });
                        effect_slider(self, ui, id, "Opacity", effect.opacity, ranges::of(ranges::OPACITY), |e, v| {
                            if let Some(stroke) = e.stroke.as_mut() {
                                stroke.opacity = v;
                            }
                        });
                        effect_color(self, ui, id, "stroke-color", [effect.red, effect.green, effect.blue], |e, rgb| {
                            if let Some(stroke) = e.stroke.as_mut() {
                                stroke.red = rgb[0];
                                stroke.green = rgb[1];
                                stroke.blue = rgb[2];
                            }
                        });
                        let mut inside = effect.inside;
                        if ui.checkbox(&mut inside, "Inside").changed() {
                            self.editor.begin_edit("Stroke Inside");
                            self.editor.update_effects(id, move |e| {
                                if let Some(stroke) = e.stroke.as_mut() {
                                    stroke.inside = inside;
                                }
                            });
                            self.editor.finish_edit();
                        }
                    }
                }
                EffectKind::Shadow | EffectKind::InnerShadow => {
                    let (angle, distance, blur, opacity, color) = match kind {
                        EffectKind::Shadow => effects.shadow.map(|effect| (effect.angle, effect.distance, effect.blur, effect.opacity, [effect.red, effect.green, effect.blue])),
                        _ => effects.inner_shadow.map(|effect| (effect.angle, effect.distance, effect.blur, effect.opacity, [effect.red, effect.green, effect.blue])),
                    }
                    .unwrap_or((120.0, 5.0, 5.0, 0.75, [0.0, 0.0, 0.0]));
                    let inner = kind == EffectKind::InnerShadow;
                    effect_slider(self, ui, id, "Angle", angle, ranges::of(ranges::SHADOW_ANGLE), move |e, v| {
                        if inner {
                            if let Some(shadow) = e.inner_shadow.as_mut() {
                                shadow.angle = v;
                            }
                        } else if let Some(shadow) = e.shadow.as_mut() {
                            shadow.angle = v;
                        }
                    });
                    effect_slider(self, ui, id, "Distance", distance, ranges::of(ranges::SHADOW_DISTANCE), move |e, v| {
                        if inner {
                            if let Some(shadow) = e.inner_shadow.as_mut() {
                                shadow.distance = v;
                            }
                        } else if let Some(shadow) = e.shadow.as_mut() {
                            shadow.distance = v;
                        }
                    });
                    effect_slider(self, ui, id, "Blur", blur, ranges::of(ranges::SHADOW_BLUR), move |e, v| {
                        if inner {
                            if let Some(shadow) = e.inner_shadow.as_mut() {
                                shadow.blur = v;
                            }
                        } else if let Some(shadow) = e.shadow.as_mut() {
                            shadow.blur = v;
                        }
                    });
                    effect_slider(self, ui, id, "Opacity", opacity, ranges::of(ranges::OPACITY), move |e, v| {
                        if inner {
                            if let Some(shadow) = e.inner_shadow.as_mut() {
                                shadow.opacity = v;
                            }
                        } else if let Some(shadow) = e.shadow.as_mut() {
                            shadow.opacity = v;
                        }
                    });
                    let key = if inner { "inner-shadow-color" } else { "shadow-color" };
                    effect_color(self, ui, id, key, color, move |e, rgb| {
                        if inner {
                            if let Some(shadow) = e.inner_shadow.as_mut() {
                                shadow.red = rgb[0];
                                shadow.green = rgb[1];
                                shadow.blue = rgb[2];
                            }
                        } else if let Some(shadow) = e.shadow.as_mut() {
                            shadow.red = rgb[0];
                            shadow.green = rgb[1];
                            shadow.blue = rgb[2];
                        }
                    });
                }
                EffectKind::ColorOverlay => {
                    if let Some(effect) = effects.color_overlay {
                        effect_slider(self, ui, id, "Opacity", effect.opacity, ranges::of(ranges::OPACITY), |e, v| {
                            if let Some(overlay) = e.color_overlay.as_mut() {
                                overlay.opacity = v;
                            }
                        });
                        effect_color(self, ui, id, "overlay-color", [effect.red, effect.green, effect.blue], |e, rgb| {
                            if let Some(overlay) = e.color_overlay.as_mut() {
                                overlay.red = rgb[0];
                                overlay.green = rgb[1];
                                overlay.blue = rgb[2];
                            }
                        });
                    }
                }
                EffectKind::OuterGlow | EffectKind::InnerGlow => {
                    let outer = kind == EffectKind::OuterGlow;
                    let (size, opacity, color) = match kind {
                        EffectKind::OuterGlow => effects.outer_glow.map(|effect| (effect.size, effect.opacity, [effect.red, effect.green, effect.blue])),
                        _ => effects.inner_glow.map(|effect| (effect.size, effect.opacity, [effect.red, effect.green, effect.blue])),
                    }
                    .unwrap_or((8.0, 0.75, [1.0, 1.0, 0.6]));
                    effect_slider(self, ui, id, "Size", size, ranges::of(ranges::GLOW_SIZE), move |e, v| {
                        if outer {
                            if let Some(glow) = e.outer_glow.as_mut() {
                                glow.size = v;
                            }
                        } else if let Some(glow) = e.inner_glow.as_mut() {
                            glow.size = v;
                        }
                    });
                    effect_slider(self, ui, id, "Opacity", opacity, ranges::of(ranges::OPACITY), move |e, v| {
                        if outer {
                            if let Some(glow) = e.outer_glow.as_mut() {
                                glow.opacity = v;
                            }
                        } else if let Some(glow) = e.inner_glow.as_mut() {
                            glow.opacity = v;
                        }
                    });
                    let key = if outer { "outer-glow-color" } else { "inner-glow-color" };
                    effect_color(self, ui, id, key, color, move |e, rgb| {
                        if outer {
                            if let Some(glow) = e.outer_glow.as_mut() {
                                glow.red = rgb[0];
                                glow.green = rgb[1];
                                glow.blue = rgb[2];
                            }
                        } else if let Some(glow) = e.inner_glow.as_mut() {
                            glow.red = rgb[0];
                            glow.green = rgb[1];
                            glow.blue = rgb[2];
                        }
                    });
                }
            }
        }
    }
}


/// The channel a curve index stands for.
fn channel_of(index: usize) -> Channel {
    match index {
        1 => Channel::Red,
        2 => Channel::Green,
        3 => Channel::Blue,
        _ => Channel::RGB,
    }
}

/// How large the curve widget is, and how close the pointer has to be to grab a point.
const CURVE_SIDE: f32 = 190.0;
const CURVE_GRAB: f64 = 12.0;

/// The curve widget: click to add a point, drag to move one, right-click to remove one.
///
/// Returns the new points when the edit changed them. The caller stores them, so the document stays
/// the single source of truth and one gesture stays one undo step.
fn curve_editor(app: &mut GuiApp, ui: &mut egui::Ui, points: &[CurvePoint]) -> Option<Vec<CurvePoint>> {
    let (rect, response) = ui.allocate_exact_size(egui::Vec2::splat(CURVE_SIDE), egui::Sense::click_and_drag());
    let painter = ui.painter_at(rect);
    let mut edited = points.to_vec();
    let mut changed = false;

    let accent = egui::Color32::from_rgb(120, 190, 255);
    painter.rect_filled(rect, egui::CornerRadius::ZERO, egui::Color32::from_gray(26));
    for step in 1..4 {
        let fraction = step as f32 / 4.0;
        let x = rect.left() + rect.width() * fraction;
        let y = rect.top() + rect.height() * fraction;
        let grid = egui::Stroke::new(1.0, egui::Color32::from_gray(48));
        painter.line_segment([egui::Pos2::new(x, rect.top()), egui::Pos2::new(x, rect.bottom())], grid);
        painter.line_segment([egui::Pos2::new(rect.left(), y), egui::Pos2::new(rect.right(), y)], grid);
    }
    painter.line_segment(
        [
            crate::curve::to_screen(rect, (0.0, 0.0)),
            crate::curve::to_screen(rect, (crate::curve::CURVE_MAX, crate::curve::CURVE_MAX)),
        ],
        egui::Stroke::new(1.0, egui::Color32::from_gray(70)),
    );

    // The drawn curve comes from comp-render's own interpolation, so it matches the render.
    let sampled = crate::curve::sample(&edited, 256);
    let line: Vec<egui::Pos2> = sampled.iter().map(|point| crate::curve::to_screen(rect, *point)).collect();
    painter.add(egui::Shape::line(line, egui::Stroke::new(1.5, accent)));

    let pointer = response.interact_pointer_pos().map(|position| crate::curve::to_curve(rect, position));
    let grabbed = pointer.and_then(|(x, y)| crate::curve::nearest_point(&edited, x, y, CURVE_GRAB));

    if response.drag_started() {
        app.editor.begin_edit("Curves");
        app.curve_selected = grabbed;
        app.curve_drag = match (grabbed, pointer) {
            // A drag that starts on a point moves it.
            (Some(index), _) => Some(index),
            // A drag that starts on empty space adds one and moves that.
            (None, Some((x, y))) => crate::curve::add_point(&mut edited, x, y).inspect(|_| changed = true),
            (None, None) => None,
        };
    }
    if response.dragged() {
        if let (Some(index), Some((x, y))) = (app.curve_drag, pointer) {
            if crate::curve::move_point(&mut edited, index, x, y) {
                changed = true;
            }
        }
    }
    if response.drag_stopped() {
        app.curve_drag = None;
        // The step was opened when the drag started; a drag that changed nothing records nothing.
        app.editor.finish_edit();
    }

    if response.clicked() {
        if let Some(index) = grabbed {
            app.curve_selected = Some(index);
        }
    }
    // A click that never became a drag still adds a point.
    if response.clicked() && grabbed.is_none() {
        if let Some((x, y)) = pointer {
            if crate::curve::add_point(&mut edited, x, y).is_some() {
                app.editor.begin_edit("Curves");
                app.editor.finish_edit();
                changed = true;
            }
        }
    }
    if response.secondary_clicked() {
        if let Some(index) = grabbed {
            if crate::curve::remove_point(&mut edited, index) {
                app.editor.begin_edit("Curves");
                app.editor.finish_edit();
                changed = true;
            }
        }
    }

    for (index, point) in edited.iter().enumerate() {
        let position = crate::curve::to_screen(rect, (point.x, point.y));
        let endpoint = index == 0 || index + 1 == edited.len();
        let selected = Some(index) == app.curve_selected;
        let radius = if Some(index) == app.curve_drag || selected { 6.0 } else { 4.5 };
        painter.circle_filled(position, radius, if endpoint { egui::Color32::WHITE } else { accent });
        painter.circle_stroke(position, radius, egui::Stroke::new(1.0, egui::Color32::from_gray(20)));
        if selected {
            painter.circle_stroke(position, radius + 3.0, egui::Stroke::new(1.0, egui::Color32::WHITE));
        }
    }

    // The selected point's numbers, and the arrow keys, which are how a curve is set exactly.
    if app.curve_selected.map(|index| index >= edited.len()).unwrap_or(false) {
        app.curve_selected = None;
    }
    if let Some(index) = app.curve_selected {
        let (mut input, mut output) = (edited[index].x, edited[index].y);
        let mut typed = None;
        ui.horizontal(|ui| {
            ui.label("Input");
            if ui
                .add(egui::DragValue::new(&mut input).range(0.0..=crate::curve::CURVE_MAX).speed(1.0))
                .changed()
            {
                typed = Some((input, output));
            }
            ui.label("Output");
            if ui
                .add(egui::DragValue::new(&mut output).range(0.0..=crate::curve::CURVE_MAX).speed(1.0))
                .changed()
            {
                typed = Some((input, output));
            }
        });
        if let Some((x, y)) = typed {
            app.editor.begin_edit("Curves");
            if crate::curve::move_point(&mut edited, index, x, y) {
                changed = true;
            }
            app.editor.finish_edit();
        }
        // Arrow keys move the point by one, or by ten with Shift held.
        let step = if ui.input(|input| input.modifiers.shift) { 10.0 } else { 1.0 };
        let mut nudge = (0.0, 0.0);
        for (key, delta) in [
            (egui::Key::ArrowLeft, (-step, 0.0)),
            (egui::Key::ArrowRight, (step, 0.0)),
            (egui::Key::ArrowUp, (0.0, step)),
            (egui::Key::ArrowDown, (0.0, -step)),
        ] {
            if ui.input(|input| input.key_pressed(key)) {
                nudge.0 += delta.0;
                nudge.1 += delta.1;
            }
        }
        if nudge != (0.0, 0.0) {
            app.editor.begin_edit("Curves");
            if crate::curve::move_point(&mut edited, index, input + nudge.0, output + nudge.1) {
                changed = true;
            }
            app.editor.finish_edit();
        }
        ui.label(
            RichText::new("Arrow keys move the point; Shift moves it ten at a time.")
                .weak()
                .small(),
        );
    } else {
        ui.label(RichText::new("Click a point on the curve to read and type its value.").weak().small());
    }

    changed.then_some(edited)
}

/// The channel the Levels and Curves panels edit.
fn channel_picker(app: &mut GuiApp, ui: &mut egui::Ui) {
    ui.horizontal(|ui| {
        for (index, name) in ["RGB", "Red", "Green", "Blue"].iter().enumerate() {
            if ui.selectable_label(app.levels_channel == index, *name).clicked() {
                app.levels_channel = index;
            }
        }
    });
}

fn to_bytes(color: [f64; 3]) -> [u8; 3] {
    [
        (color[0] * 255.0).round().clamp(0.0, 255.0) as u8,
        (color[1] * 255.0).round().clamp(0.0, 255.0) as u8,
        (color[2] * 255.0).round().clamp(0.0, 255.0) as u8,
    ]
}

fn from_bytes(bytes: [u8; 3]) -> [f64; 3] {
    [bytes[0] as f64 / 255.0, bytes[1] as f64 / 255.0, bytes[2] as f64 / 255.0]
}

/// The six mix amounts, in the order comp-render reads them.
fn black_white_values(adjustment: &Adjustment) -> [f64; 6] {
    const KEYS: [&str; 6] = ["reds", "yellows", "greens", "cyans", "blues", "magentas"];
    const DEFAULTS: [f64; 6] = [40.0, 60.0, 40.0, 60.0, 20.0, 80.0];
    std::array::from_fn(|index| json_number(&adjustment.black_white_settings, KEYS[index], DEFAULTS[index]))
}

fn set_black_white(adjustment: &mut Adjustment, weights: [f64; 6], tint: bool, hue: f64, saturation: f64) {
    adjustment.black_white_settings = Some(serde_json::json!({
        "reds": weights[0],
        "yellows": weights[1],
        "greens": weights[2],
        "cyans": weights[3],
        "blues": weights[4],
        "magentas": weights[5],
        "tint": tint,
        "tintHue": hue,
        "tintSaturation": saturation,
    }));
}

fn black_white_tint(adjustment: &Adjustment) -> (bool, f64, f64) {
    let settings = &adjustment.black_white_settings;
    (
        settings
            .as_ref()
            .and_then(|value| value.get("tint"))
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false),
        json_number(settings, "tintHue", 40.0),
        json_number(settings, "tintSaturation", 20.0),
    )
}

/// The colour that stands for a tint: its hue and saturation at full value.
fn tint_bytes(hue: f64, saturation: f64) -> [u8; 4] {
    crate::color::from_hsv(
        crate::color::Hsv { hue, saturation: (saturation / 100.0).clamp(0.0, 1.0), value: 1.0 },
        255,
    )
}

/// The number a JSON-backed adjustment stores under a key.
fn json_number(settings: &Option<serde_json::Value>, key: &str, fallback: f64) -> f64 {
    settings
        .as_ref()
        .and_then(|value| value.get(key))
        .and_then(serde_json::Value::as_f64)
        .unwrap_or(fallback)
}

fn exposure_values(adjustment: &Adjustment) -> (f64, f64, f64) {
    (
        json_number(&adjustment.exposure_settings, "exposure", 0.0),
        json_number(&adjustment.exposure_settings, "offset", 0.0),
        json_number(&adjustment.exposure_settings, "gamma", 1.0),
    )
}

fn set_exposure(adjustment: &mut Adjustment, exposure: f64, offset: f64, gamma: f64) {
    adjustment.exposure_settings = Some(serde_json::json!({
        "exposure": exposure,
        "offset": offset,
        "gamma": gamma,
    }));
}

fn gradient_map_values(adjustment: &Adjustment) -> ([f64; 3], [f64; 3], bool) {
    let settings = &adjustment.gradient_map_settings;
    let color = |key: &str, fallback: [f64; 3]| {
        let Some(value) = settings.as_ref().and_then(|value| value.get(key)) else { return fallback };
        [
            json_number(&Some(value.clone()), "red", fallback[0]),
            json_number(&Some(value.clone()), "green", fallback[1]),
            json_number(&Some(value.clone()), "blue", fallback[2]),
        ]
    };
    (
        color("shadows", [0.0, 0.0, 0.0]),
        color("highlights", [1.0, 1.0, 1.0]),
        settings.as_ref().and_then(|value| value.get("reversed")).and_then(serde_json::Value::as_bool).unwrap_or(false),
    )
}

fn set_gradient_map(adjustment: &mut Adjustment, shadows: [f64; 3], highlights: [f64; 3], reversed: bool) {
    adjustment.gradient_map_settings = Some(serde_json::json!({
        "shadows": { "red": shadows[0], "green": shadows[1], "blue": shadows[2] },
        "highlights": { "red": highlights[0], "green": highlights[1], "blue": highlights[2] },
        "reversed": reversed,
    }));
}

fn grain_values(adjustment: &Adjustment) -> (f64, f64, f64, u64) {
    (
        json_number(&adjustment.grain_settings, "amount", 25.0),
        json_number(&adjustment.grain_settings, "size", 1.5),
        json_number(&adjustment.grain_settings, "roughness", 50.0),
        adjustment
            .grain_settings
            .as_ref()
            .and_then(|value| value.get("seed"))
            .and_then(serde_json::Value::as_u64)
            .unwrap_or(0),
    )
}

fn set_grain(adjustment: &mut Adjustment, amount: f64, size: f64, roughness: f64, seed: u64) {
    adjustment.grain_settings = Some(serde_json::json!({
        "amount": amount,
        "size": size,
        "roughness": roughness,
        "seed": seed,
    }));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_json_helpers_round_trip_what_comp_render_reads() {
        let mut adjustment = Adjustment::new(AdjustmentKind::Exposure);
        assert_eq!(exposure_values(&adjustment), (0.0, 0.0, 1.0));
        set_exposure(&mut adjustment, 1.5, -0.25, 2.2);
        assert_eq!(exposure_values(&adjustment), (1.5, -0.25, 2.2));
        assert!(adjustment.exposure_settings.as_ref().unwrap().get("exposure").is_some());

        let mut grain = Adjustment::new(AdjustmentKind::Grain);
        assert_eq!(grain_values(&grain), (25.0, 1.5, 50.0, 0));
        set_grain(&mut grain, 60.0, 2.0, 30.0, 42);
        assert_eq!(grain_values(&grain), (60.0, 2.0, 30.0, 42));
    }

    #[test]
    fn the_gradient_map_helper_keeps_both_stops_and_the_reverse_flag() {
        let mut adjustment = Adjustment::new(AdjustmentKind::GradientMap);
        assert_eq!(gradient_map_values(&adjustment), ([0.0, 0.0, 0.0], [1.0, 1.0, 1.0], false));
        set_gradient_map(&mut adjustment, [1.0, 0.0, 0.0], [0.0, 0.0, 1.0], true);
        let (shadows, highlights, reversed) = gradient_map_values(&adjustment);
        assert_eq!(shadows, [1.0, 0.0, 0.0]);
        assert_eq!(highlights, [0.0, 0.0, 1.0]);
        assert!(reversed);
    }

    #[test]
    fn colors_convert_between_bytes_and_the_records_unit_range() {
        let bytes = to_bytes([1.0, 0.5, 0.0]);
        assert_eq!(bytes, [255, 128, 0]);
        let color = from_bytes(bytes);
        assert!((color[0] - 1.0).abs() < 1e-9);
        assert!((color[1] - 0.5019607843137255).abs() < 1e-9);
        assert_eq!(color[2], 0.0);
    }

    #[test]
    fn every_effect_kind_has_a_name_and_round_trips_its_switch() {
        let mut effects = LayerEffects::default();
        for kind in EFFECTS {
            assert!(!kind.name().is_empty());
            assert!(!kind.is_enabled(&effects));
            kind.set_enabled(&mut effects, true);
            assert!(kind.is_enabled(&effects), "{} did not turn on", kind.name());
            kind.set_enabled(&mut effects, false);
            assert!(!kind.is_enabled(&effects));
            kind.remove(&mut effects);
            assert!(effects.is_empty(), "{} outlived its removal", kind.name());
        }
    }

    #[test]
    fn enabling_an_effect_creates_it_with_valid_defaults() {
        for kind in EFFECTS {
            let mut effects = LayerEffects::default();
            kind.set_enabled(&mut effects, true);
            assert!(effects.is_valid(), "{} defaults are not valid", kind.name());
        }
    }

    #[test]
    fn the_color_balance_labels_cover_every_stored_field() {
        assert_eq!(COLOR_BALANCE_LABELS.len(), 9);
        let settings = comp_core::adjustment::ColorBalanceSettings::default();
        assert!(settings.shadow_cyan_red == 0.0 && settings.highlight_yellow_blue == 0.0);
        // comp-core turns preserve-luminosity on by default, as Photoshop does.
        assert!(settings.preserve_luminosity);
    }
}
