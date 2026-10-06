//! The layers panel: the stack from top to bottom, the selected layer's controls and the row
//! commands.
//!
//! Every mutation is collected while the rows are drawn and applied afterwards, so the panel never
//! holds a borrow of the document across an edit.

use std::collections::HashSet;

use comp_core::blend::BlendMode;
use egui::RichText;
use uuid::Uuid;

use crate::app::GuiApp;

/// Panel state that is not part of the document.
#[derive(Default)]
pub(crate) struct LayersUi {
    /// The layer being renamed and its in-progress text.
    pub(crate) rename: Option<(Uuid, String)>,
    /// True on the first frame of a rename, when the text field still needs keyboard focus.
    pub(crate) rename_focus: bool,
    /// Groups whose children are hidden in the list.
    pub(crate) collapsed: HashSet<Uuid>,
}

/// The height of one layer row, in points: the drop strip above it plus the line itself.
///
/// The row is uniform because its tallest widget is the fixed-size thumbnail and everything else is a
/// single line, which is what lets the scroll area skip the rows that are off screen.
const ROW_HEIGHT: f32 = 34.0;

/// How close to an edge a dragged row has to be before the list scrolls, and how fast it scrolls
/// there, in points per frame.
const AUTOSCROLL_MARGIN: f32 = 24.0;
const AUTOSCROLL_MAX_STEP: f32 = 14.0;

/// A row command, applied once the list has been drawn.
enum RowAction {
    Select(Uuid, crate::multiselect::ClickKind),
    Move { id: Uuid, placement: crate::reorder::Placement },
    SetVisible(Uuid, bool),
    ToggleCollapsed(Uuid),
    BeginRename(Uuid),
    RenameFocused,
    UpdateRename(String),
    CommitRename(Uuid, String),
}

impl GuiApp {
    pub(crate) fn layers_panel(&mut self, ui: &mut egui::Ui) {
        self.refresh_thumbnails(ui.ctx());
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            ui.heading("Layers");
            if self.editor.is_modified() {
                ui.label(RichText::new("*").strong());
            }
        });
        ui.separator();
        self.selected_layer_controls(ui);
        self.text_panel(ui);
        self.adjustment_panel(ui);
        self.effects_panel(ui);
        ui.separator();

        let rows = crate::panel::layer_rows(&self.editor.document, &self.layers_ui.collapsed);
        let mut actions: Vec<RowAction> = Vec::new();
        let active = self.editor.document.active_layer;
        let rename = self.layers_ui.rename.clone();
        let collapsed = self.layers_ui.collapsed.clone();

        // Only the rows the viewport can show are drawn. Every row is the same height - a drop
        // strip and a line with a fixed-size thumbnail - so the list can be told that and skip the
        // rest, which is what keeps a document with hundreds of layers at a frame per repaint
        // instead of a frame per hundred layers.
        egui::ScrollArea::vertical()
            .auto_shrink([false, false])
            .max_height(ui.available_height() - 40.0)
            .show_rows(ui, ROW_HEIGHT, rows.len(), |ui, range| {
                // A drag near an edge scrolls the list, so a row can be dropped past the rows the
                // viewport is showing: without this the virtualized list would be a trap.
                let dragging = ui.ctx().dragged_id().is_some();
                if dragging {
                    if let Some(pointer) = ui.ctx().pointer_latest_pos() {
                        let view = ui.clip_rect();
                        let step = crate::panel::autoscroll_step(
                            pointer.y,
                            view.top(),
                            view.bottom(),
                            AUTOSCROLL_MARGIN,
                            AUTOSCROLL_MAX_STEP,
                        );
                        if step != 0.0 {
                            ui.scroll_with_delta(egui::vec2(0.0, -step));
                        }
                    }
                }
                for row in &rows[range] {
                    let layer = &self.editor.document.layers[row.index];
                    // Every layer in the selection is highlighted; the active one is set in bold.
                    let selected = self.editor.is_selected(row.id);
                    let is_active = active == Some(row.id);
                    // The strip above a row is where a dragged layer lands; dropping on it is a move.
                    if let Some((dragged, placement)) = drop_strip(ui, &self.editor.document, Some(row.id)) {
                        actions.push(RowAction::Move { id: dragged, placement });
                    }
                    ui.dnd_drag_source(egui::Id::new(("layer-row", row.id)), row.id, |ui| {
                    ui.horizontal(|ui| {
                        let mut visible = layer.visible;
                        if ui.checkbox(&mut visible, "").on_hover_text("Visibility").changed() {
                            actions.push(RowAction::SetVisible(row.id, visible));
                        }
                        ui.add_space(row.depth as f32 * 12.0);
                        // The thumbnail keeps every row the same height, even before it is built.
                        match self.thumbs.get(&row.id) {
                            Some((_, entry)) => {
                                ui.add(egui::Image::new(egui::load::SizedTexture::new(entry.texture.id(), entry.size)));
                            }
                            None => {
                                ui.allocate_space(egui::Vec2::new(crate::thumbs::THUMBNAIL_SIDE as f32, crate::thumbs::THUMBNAIL_SIDE as f32));
                            }
                        }
                        if row.is_group {
                            let is_collapsed = collapsed.contains(&row.id);
                            let glyph = if is_collapsed { ">" } else { "v" };
                            if ui.small_button(glyph).on_hover_text("Fold this group").clicked() {
                                actions.push(RowAction::ToggleCollapsed(row.id));
                            }
                        }
                        match &rename {
                            Some((id, buffer)) if *id == row.id => {
                                let mut text = buffer.clone();
                                let response = ui.add(egui::TextEdit::singleline(&mut text).desired_width(150.0));
                                if self.layers_ui.rename_focus {
                                    response.request_focus();
                                    actions.push(RowAction::RenameFocused);
                                }
                                if response.changed() {
                                    actions.push(RowAction::UpdateRename(text.clone()));
                                }
                                // Enter and clicking away both end the rename.
                                if response.lost_focus() {
                                    actions.push(RowAction::CommitRename(row.id, text));
                                }
                            }
                            _ => {
                                let mut label = layer.name.clone();
                                if row.is_group {
                                    label = format!("[{}]", label);
                                }
                                // Within a multi-selection the active layer is the bold one.
                                let label = if is_active { RichText::new(label).strong() } else { RichText::new(label) };
                                let response = ui
                                    .selectable_label(selected, label)
                                    .on_hover_text("Click to select, Ctrl-click to add, Shift-click for a range, double-click to rename");
                                if response.clicked() {
                                    let kind = if ui.input(|input| input.modifiers.ctrl || input.modifiers.command) {
                                        crate::multiselect::ClickKind::Toggle
                                    } else if ui.input(|input| input.modifiers.shift) {
                                        crate::multiselect::ClickKind::Extend
                                    } else {
                                        crate::multiselect::ClickKind::Replace
                                    };
                                    actions.push(RowAction::Select(row.id, kind));
                                }
                                if response.double_clicked() {
                                    actions.push(RowAction::BeginRename(row.id));
                                }
                                if row.is_adjustment {
                                    ui.label(RichText::new("adjustment").weak().small());
                                }
                                if let Some(blend) = Some(layer.blend) {
                                    if blend != BlendMode::Normal {
                                        ui.label(RichText::new(short_blend(blend)).weak().small());
                                    }
                                }
                                if layer.opacity < 0.999 {
                                    ui.label(RichText::new(format!("{:.0}%", layer.opacity * 100.0)).weak().small());
                                }
                                if layer.mask.is_some() {
                                    ui.label(RichText::new(if layer.mask_enabled { "mask" } else { "mask off" }).weak().small());
                                }
                            }
                        }
                    });
                    });
                }
                if let Some((dragged, placement)) = drop_strip(ui, &self.editor.document, None) {
                    actions.push(RowAction::Move { id: dragged, placement });
                }
                if active.is_none() && self.editor.document.layers.is_empty() {
                    ui.label(RichText::new("No layers yet; use New.").weak());
                }
            });

        for action in actions {
            self.apply_row_action(action);
        }

        ui.separator();
        let has_active = self.editor.document.active_layer.is_some();
        let selection = self.editor.selected.len();
        let merge_label = self.editor.merge_label();
        let can_merge = crate::merge::merge_plan(&self.editor.document, &self.editor.selected).is_some();
        ui.horizontal(|ui| {
            if ui.button("New").on_hover_text("Add a transparent layer").clicked() {
                self.editor.add_layer();
            }
            if ui.add_enabled(has_active, egui::Button::new("Copy")).on_hover_text("Duplicate the layer").clicked() {
                self.editor.duplicate_active();
            }
            if ui
                .add_enabled(can_merge, egui::Button::new(merge_label))
                .on_hover_text(if selection > 1 {
                    "Merge the selected layers into one"
                } else {
                    "Merge down into the layer below"
                })
                .clicked()
            {
                self.editor.merge_down();
            }
            if ui
                .add_enabled(has_active, egui::Button::new("Delete"))
                .on_hover_text(if selection > 1 { "Delete the selected layers" } else { "Delete the layer" })
                .clicked()
            {
                if selection > 1 {
                    self.editor.delete_selection();
                } else {
                    self.editor.delete_active();
                }
            }
            if ui.add_enabled(has_active, egui::Button::new("Up")).clicked() {
                self.editor.move_active_layer(1);
            }
            if ui.add_enabled(has_active, egui::Button::new("Down")).clicked() {
                self.editor.move_active_layer(-1);
            }
        });
    }

    /// Opacity and blend mode for the selected layer, with one undo step per drag.
    fn selected_layer_controls(&mut self, ui: &mut egui::Ui) {
        let Some(id) = self.editor.document.active_layer else {
            ui.label(RichText::new("Select a layer to edit it.").weak());
            return;
        };
        let Some(layer) = self.editor.document.layer(id) else { return };
        let opacity = layer.opacity;
        let blend = layer.blend;
        let is_group = layer.is_group;

        ui.horizontal(|ui| {
            ui.label("Opacity");
            let mut percent = opacity * 100.0;
            let response = ui.add(egui::Slider::new(&mut percent, 0.0..=100.0).suffix("%"));
            if response.drag_started() || (response.changed() && !response.dragged()) {
                self.editor.begin_edit("Layer Opacity");
            }
            if response.changed() {
                self.editor.set_opacity(id, percent / 100.0);
            }
            if response.drag_stopped() || (response.changed() && !response.dragged()) {
                self.editor.finish_edit();
            }
        });

        self.mask_controls(ui, id);

        ui.horizontal(|ui| {
            ui.label("Blend");
            let mut chosen = blend;
            egui::ComboBox::from_id_salt("layer-blend")
                .selected_text(blend.as_str())
                .width(170.0)
                .show_ui(ui, |ui| {
                    for group in BlendMode::GROUPS {
                        for mode in group {
                            ui.selectable_value(&mut chosen, *mode, mode.as_str());
                        }
                        ui.separator();
                    }
                });
            if chosen != blend {
                self.editor.begin_edit("Blend Mode");
                self.editor.set_blend(id, chosen);
                self.editor.finish_edit();
            }
            if is_group {
                ui.label(RichText::new("groups are pass-through").weak().small());
            }
        });
    }

    /// Mask controls for the selected layer: add, switch, remove and paint.
    fn mask_controls(&mut self, ui: &mut egui::Ui, id: Uuid) {
        ui.horizontal(|ui| {
            ui.label("Mask");
            if self.editor.has_mask(id) {
                let mut enabled = self.editor.document.layer(id).map(|layer| layer.mask_enabled).unwrap_or(false);
                if ui.checkbox(&mut enabled, "on").on_hover_text("A mask that is off keeps its pixels").changed() {
                    self.editor.begin_edit("Toggle Mask");
                    self.editor.set_mask_enabled(id, enabled);
                    self.editor.finish_edit();
                }
                let mut painting = self.editor.mask_painting;
                if ui
                    .checkbox(&mut painting, "paint")
                    .on_hover_text("The brush then paints the mask instead of the pixels")
                    .changed()
                {
                    self.editor.mask_painting = painting;
                }
                if ui.small_button("remove").clicked() {
                    self.editor.remove_layer_mask(id);
                }
            } else if ui.button("Add white").clicked() {
                self.editor.add_layer_mask(id, false);
            }
            if !self.editor.has_mask(id) && ui.button("From alpha").on_hover_text("Hide where the layer is transparent").clicked() {
                self.editor.add_layer_mask(id, true);
            }
        });

        // Filling and softening a mask only makes sense once it has one.
        let has_mask = self.editor.has_mask(id);
        ui.add_enabled_ui(has_mask, |ui| {
            ui.horizontal(|ui| {
                ui.label("Gradient");
                for shape in [crate::maskfill::GradientShape::Linear, crate::maskfill::GradientShape::Radial] {
                    if ui
                        .selectable_label(self.gradient_shape == shape, shape.label())
                        .on_hover_text("Drag on the canvas with the Gradient tool to fill the mask")
                        .clicked()
                    {
                        self.gradient_shape = shape;
                    }
                }
                ui.checkbox(&mut self.gradient_invert, "invert")
                    .on_hover_text("Start the ramp white and end it black");
                for blend in crate::maskfill::GradientBlend::ALL {
                    let selected = self.gradient_blend == blend;
                    if ui
                        .selectable_label(selected, blend.label())
                        .on_hover_text(match blend {
                            crate::maskfill::GradientBlend::Replace => "The ramp replaces the mask",
                            crate::maskfill::GradientBlend::Add => "The ramp only lightens the mask",
                            crate::maskfill::GradientBlend::Subtract => "The ramp only darkens the mask",
                        })
                        .clicked()
                    {
                        self.gradient_blend = blend;
                    }
                }
            });
            ui.horizontal(|ui| {
                ui.label("Feather");
                ui.add(
                    egui::DragValue::new(&mut self.feather_radius)
                        .range(0.0..=crate::maskfill::MAX_FEATHER)
                        .speed(1.0)
                        .suffix(" px"),
                );
                if ui
                    .button("Apply")
                    .on_hover_text("Soften the whole mask by this radius")
                    .clicked()
                {
                    let radius = self.feather_radius;
                    self.editor.feather_mask(radius);
                    self.request_render(true);
                }
                // The format stores a mask as one Gray8 plane and whether it is on; density is not
                // part of it, so the control is shown disabled with what it would take.
                let mut density = 100.0;
                ui.add_enabled(
                    false,
                    egui::DragValue::new(&mut density).range(0.0..=100.0).suffix("%").prefix("density "),
                )
                .on_disabled_hover_text(
                    "A mask is its pixels and an on/off flag: the package has no density field. Adding \
                     one means a new field on the layer's mask record and a format version bump. Until \
                     then, the gradient's Subtract blend and painting the mask do the same job.",
                );
                ui.label("Show");
                for view in [crate::app::MaskView::Off, crate::app::MaskView::Red, crate::app::MaskView::Gray] {
                    if ui
                        .selectable_label(self.mask_view == view, view.label())
                        .on_hover_text(match view {
                            crate::app::MaskView::Off => "The composite, as usual",
                            crate::app::MaskView::Red => "The mask over the composite in red, like Quick Mask",
                            crate::app::MaskView::Gray => "The mask plane itself, in gray",
                        })
                        .clicked()
                    {
                        self.mask_view = view;
                        self.request_render(true);
                    }
                }
            });
        });
    }

    fn apply_row_action(&mut self, action: RowAction) {
        match action {
            RowAction::Select(id, kind) => {
                self.editor.click_layer(id, kind);
            }
            RowAction::Move { id, placement } => {
                if self.editor.move_layer_to(id, placement) {
                    self.editor.select_layer(id);
                }
            }
            RowAction::SetVisible(id, visible) => {
                self.editor.begin_edit("Toggle Visibility");
                self.editor.set_visibility(id, visible);
                self.editor.finish_edit();
            }
            RowAction::ToggleCollapsed(id) => {
                if !self.layers_ui.collapsed.remove(&id) {
                    self.layers_ui.collapsed.insert(id);
                }
            }
            RowAction::BeginRename(id) => {
                let name = self.editor.document.layer(id).map(|layer| layer.name.clone()).unwrap_or_default();
                self.layers_ui.rename = Some((id, name));
                self.layers_ui.rename_focus = true;
            }
            RowAction::RenameFocused => self.layers_ui.rename_focus = false,
            RowAction::UpdateRename(text) => {
                if let Some((_, buffer)) = self.layers_ui.rename.as_mut() {
                    *buffer = text;
                }
            }
            RowAction::CommitRename(id, name) => {
                let trimmed = name.trim().to_string();
                if !trimmed.is_empty() {
                    self.editor.begin_edit("Rename Layer");
                    self.editor.set_name(id, trimmed);
                    self.editor.finish_edit();
                }
                self.layers_ui.rename = None;
            }
        }
    }
}

/// A thin drop target above a row, or at the bottom of the list when no row is given.
///
/// Returns the layer being dragged and where it should land when the pointer was released here.
fn drop_strip(ui: &mut egui::Ui, document: &crate::core::Document, above: Option<Uuid>) -> Option<(Uuid, crate::reorder::Placement)> {
    let (_, payload) = ui.dnd_drop_zone::<Uuid, _>(egui::Frame::default(), |ui| {
        ui.allocate_space(egui::Vec2::new(ui.available_width(), 6.0));
    });
    let dragged = *payload?;
    let placement = match above {
        Some(row) => crate::reorder::placement_above(document, dragged, row)?,
        None => crate::reorder::placement_bottom(),
    };
    Some((dragged, placement))
}

/// A blend mode name short enough for a layer row.
fn short_blend(blend: BlendMode) -> &'static str {
    match blend {
        BlendMode::LinearDodge => "Add",
        BlendMode::ColorBurn => "Burn",
        BlendMode::ColorDodge => "Dodge",
        BlendMode::LinearBurn => "Linear Burn",
        BlendMode::LinearLight => "Linear Light",
        BlendMode::VividLight => "Vivid Light",
        BlendMode::PinLight => "Pin Light",
        BlendMode::HardMix => "Hard Mix",
        BlendMode::SoftLight => "Soft Light",
        BlendMode::HardLight => "Hard Light",
        other => other.as_str(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::panel::LayerRow;

    #[test]
    fn short_blend_names_stay_short_and_are_never_empty() {
        for mode in BlendMode::ALL {
            let name = short_blend(mode);
            assert!(!name.is_empty());
            assert!(name.len() <= 12, "{name} is too long for a layer row");
        }
        assert_eq!(short_blend(BlendMode::LinearDodge), "Add");
        assert_eq!(short_blend(BlendMode::Normal), "Normal");
    }

    #[test]
    fn rows_are_kept_consistent_with_the_panel_order() {
        // The panel draws whatever the pure layout helper returns, top of the stack first.
        let mut document = comp_core::document::Document::new(8, 8);
        document.add_layer(comp_core::layer::Layer::raster("Bottom", 8, 8), None);
        document.add_layer(comp_core::layer::Layer::raster("Top", 8, 8), None);
        let rows: Vec<LayerRow> = crate::panel::layer_rows(&document, &HashSet::new());
        assert_eq!(document.layers[rows[0].index].name, "Top");
    }
}
