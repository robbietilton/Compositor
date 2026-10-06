//! The menu bar, the shortcut table and the small modal dialogs.
//!
//! Shortcuts are read from the raw input rather than from menu widgets so that they work with the
//! menus closed, which is the only behavior users expect from an editor.

use egui::{Context, Key, RichText};

use crate::app::GuiApp;
use crate::filters::{FilterBackend, FilterKind, FilterMenu};
use crate::tools::Tool;

/// Which shortcuts fired this frame.
///
/// The chords come from `crate::shortcuts`, which is also the table the parity audit and the conflict
/// check read; this struct only says which of them fired. The match below is exhaustive on purpose:
/// a new binding cannot be added without a handler for it.
#[derive(Default)]
struct Pressed {
    new_document: bool,
    open: bool,
    import: bool,
    save: bool,
    save_as: bool,
    export: bool,
    export_jpeg: bool,
    close_tab: bool,
    camera_raw: bool,
    merge_down: bool,
    flatten: bool,
    new_layer: bool,
    duplicate_layer: bool,
    move_layer_up: bool,
    move_layer_down: bool,
    delete_layer: bool,
    curves: bool,
    levels: bool,
    hue_saturation: bool,
    invert: bool,
    cut: bool,
    copy_merged: bool,
    copy_layer: bool,
    paste: bool,
    undo: bool,
    redo: bool,
    select_all: bool,
    deselect: bool,
    zoom_in: bool,
    zoom_out: bool,
    fit: bool,
    actual: bool,
    show_grid: bool,
    show_guides: bool,
    show_rulers: bool,
    snap: bool,
    lock_guides: bool,
    exit: bool,
    larger_brush: bool,
    smaller_brush: bool,
    harder_brush: bool,
    softer_brush: bool,
    escape: bool,
    tool: Option<Tool>,
    /// A digit the user typed: the macOS opacity shortcut, one digit for the tens.
    opacity_digit: Option<u8>,
    /// Shift and the minus or equals key: the previous or next blend mode.
    blend_step: i32,
}

/// Turns the table's actions into the flags the handlers read.
///
/// Every action the table can produce has an arm here, so adding a binding without wiring it up is a
/// compile error rather than a key that does nothing.
fn press(pressed: &mut Pressed, action: crate::shortcuts::Action) {
    use crate::shortcuts::Action;
    match action {
        Action::NewDocument => pressed.new_document = true,
        Action::Open => pressed.open = true,
        Action::Import => pressed.import = true,
        Action::Save => pressed.save = true,
        Action::SaveAs => pressed.save_as = true,
        Action::ExportPng => pressed.export = true,
        Action::ExportJpeg => pressed.export_jpeg = true,
        Action::CloseTab => pressed.close_tab = true,
        Action::Undo => pressed.undo = true,
        Action::Redo => pressed.redo = true,
        Action::Cut => pressed.cut = true,
        Action::Copy => pressed.copy_layer = true,
        Action::CopyMerged => pressed.copy_merged = true,
        Action::Paste => pressed.paste = true,
        Action::SelectAll => pressed.select_all = true,
        Action::Deselect => pressed.deselect = true,
        Action::Curves => pressed.curves = true,
        Action::Levels => pressed.levels = true,
        Action::HueSaturation => pressed.hue_saturation = true,
        Action::Invert => pressed.invert = true,
        Action::NewLayer => pressed.new_layer = true,
        Action::DuplicateLayer => pressed.duplicate_layer = true,
        Action::MoveLayerUp => pressed.move_layer_up = true,
        Action::MoveLayerDown => pressed.move_layer_down = true,
        Action::MergeLayers => pressed.merge_down = true,
        Action::FlattenImage => pressed.flatten = true,
        Action::DeleteLayer => pressed.delete_layer = true,
        Action::CameraRaw => pressed.camera_raw = true,
        Action::ZoomIn => pressed.zoom_in = true,
        Action::ZoomOut => pressed.zoom_out = true,
        Action::FitWindow => pressed.fit = true,
        Action::ActualPixels => pressed.actual = true,
        Action::ShowGrid => pressed.show_grid = true,
        Action::ShowGuides => pressed.show_guides = true,
        Action::ShowRulers => pressed.show_rulers = true,
        Action::Snap => pressed.snap = true,
        Action::LockGuides => pressed.lock_guides = true,
        Action::IncreaseBrush => pressed.larger_brush = true,
        Action::DecreaseBrush => pressed.smaller_brush = true,
        Action::IncreaseBrushHardness => pressed.harder_brush = true,
        Action::DecreaseBrushHardness => pressed.softer_brush = true,
        Action::Quit => pressed.exit = true,
        Action::Escape => pressed.escape = true,
    }
}

fn read_shortcuts(ctx: &Context, text_open: bool) -> Pressed {
    let mut pressed = Pressed::default();
    for action in ctx.input(|input| crate::shortcuts::pressed(input, text_open)) {
        press(&mut pressed, action);
    }
    ctx.input(|input| {
        let ctrl = input.modifiers.ctrl || input.modifiers.command;
        let shift = input.modifiers.shift;
        let plain = !ctrl && !input.modifiers.alt;
        // Redo has a second chord on Windows (Ctrl+Y) that macOS does not use.
        pressed.redo |= ctrl && !shift && input.key_pressed(Key::Y);
        // Ctrl and the plus key, which is what a keyboard without an equals key sends.
        pressed.zoom_in |= ctrl && input.key_pressed(Key::Plus);
        // Opacity digits and the blend mode steps, as macOS has them on the canvas.
        if plain {
            for (key, digit) in [
                (Key::Num1, 1u8),
                (Key::Num2, 2),
                (Key::Num3, 3),
                (Key::Num4, 4),
                (Key::Num5, 5),
                (Key::Num6, 6),
                (Key::Num7, 7),
                (Key::Num8, 8),
                (Key::Num9, 9),
                (Key::Num0, 0),
            ] {
                if input.key_pressed(key) {
                    pressed.opacity_digit = Some(digit);
                }
            }
        }
        if shift && !ctrl && !input.modifiers.alt {
            if input.key_pressed(Key::Minus) {
                pressed.blend_step = -1;
            }
            if input.key_pressed(Key::Equals) || input.key_pressed(Key::Plus) {
                pressed.blend_step = 1;
            }
        }
        if plain {
            for tool in Tool::ALL {
                let key = match tool {
                    Tool::Brush => Key::B,
                    Tool::Eraser => Key::E,
                    Tool::Eyedropper => Key::I,
                    Tool::RectSelect => Key::M,
                    Tool::Move => Key::V,
                    Tool::Text => Key::T,
                    Tool::Gradient => Key::G,
                };
                if input.key_pressed(key) {
                    pressed.tool = Some(tool);
                }
            }
        }
    });
    pressed
}

impl GuiApp {
    pub(crate) fn menu_bar(&mut self, ui: &mut egui::Ui) {
        egui::MenuBar::new().ui(ui, |ui| {
            ui.menu_button("File", |ui| {
                if ui.add(egui::Button::new("New...").shortcut_text("Ctrl+N")).clicked() {
                    ui.close();
                    self.show_new_dialog = true;
                }
                if ui.add(egui::Button::new("Open...").shortcut_text("Ctrl+O")).clicked() {
                    ui.close();
                    self.open_dialog();
                }
                if ui.add(egui::Button::new("Import as Layer...").shortcut_text("Ctrl+Shift+I")).clicked() {
                    ui.close();
                    self.import_dialog(true);
                }
                if ui.add(egui::Button::new("Import as Document...")).clicked() {
                    ui.close();
                    self.import_dialog(false);
                }
                ui.separator();
                let modified = self.editor.is_modified();
                if ui.add(egui::Button::new("Save").shortcut_text("Ctrl+S")).clicked() {
                    ui.close();
                    self.save();
                }
                if ui.add(egui::Button::new("Save As...").shortcut_text("Ctrl+Shift+S")).clicked() {
                    ui.close();
                    self.save_as_dialog();
                }
                ui.separator();
                if ui.add(egui::Button::new("Export JPEG...").shortcut_text("Ctrl+Shift+J")).clicked() {
                    ui.close();
                    self.export_jpeg_dialog();
                }
                if ui.add(egui::Button::new("Export PNG...").shortcut_text("Ctrl+Shift+E")).clicked() {
                    ui.close();
                    self.export_dialog();
                }
                ui.separator();
                if ui.add(egui::Button::new("Exit").shortcut_text("Ctrl+Q")).clicked() {
                    ui.close();
                    ui.ctx().send_viewport_cmd(egui::ViewportCommand::Close);
                }
                let _ = modified;
            });

            ui.menu_button("Edit", |ui| {
                let undo_label = match self.editor.undo_label() {
                    Some(label) => format!("Undo {label}"),
                    None => "Undo".to_string(),
                };
                if ui
                    .add_enabled(self.editor.can_undo(), egui::Button::new(undo_label).shortcut_text("Ctrl+Z"))
                    .clicked()
                {
                    ui.close();
                    self.editor.undo();
                }
                let redo_label = match self.editor.redo_label() {
                    Some(label) => format!("Redo {label}"),
                    None => "Redo".to_string(),
                };
                if ui
                    .add_enabled(self.editor.can_redo(), egui::Button::new(redo_label).shortcut_text("Ctrl+Shift+Z"))
                    .clicked()
                {
                    ui.close();
                    self.editor.redo();
                }
                ui.separator();
                if ui
                    .add(egui::Button::new("Cut").shortcut_text("Ctrl+X"))
                    .on_hover_text("Copy the selected layer's pixels, then remove the layer")
                    .clicked()
                {
                    ui.close();
                    self.copy_layer();
                    if self.editor.selected.len() > 1 {
                        self.editor.delete_selection();
                    } else {
                        self.editor.delete_active();
                    }
                }
                if ui.add(egui::Button::new("Copy").shortcut_text("Ctrl+C")).on_hover_text("Copy the selected layer's pixels").clicked() {
                    ui.close();
                    self.copy_layer();
                }
                if ui
                    .add(egui::Button::new("Copy Merged").shortcut_text("Ctrl+Shift+C"))
                    .on_hover_text("Copy everything the canvas shows")
                    .clicked()
                {
                    ui.close();
                    self.copy_merged();
                }
                if ui.add(egui::Button::new("Paste").shortcut_text("Ctrl+V")).on_hover_text("Paste the clipboard as a new layer").clicked() {
                    ui.close();
                    self.paste();
                }
                ui.separator();
                // The subject extractors: which one answers is decided by whether a model file is
                // there, so the entry says so before it runs.
                let can_subject = self.editor.paintable_layer().is_some();
                let subject_hover = match crate::subject::hint(&self.subject_backend) {
                    Some(advice) => format!("Take a subject matte from the active layer as its mask\n\n{advice}"),
                    None => "Take a subject matte from the active layer as its mask (the model answers)".to_string(),
                };
                if ui
                    .add_enabled(can_subject, egui::Button::new("Select Subject"))
                    .on_hover_text(subject_hover)
                    .on_disabled_hover_text("Select a raster layer to take a subject from")
                    .clicked()
                {
                    ui.close();
                    self.run_select_subject();
                }
                if ui.add(egui::Button::new("Select All").shortcut_text("Ctrl+A")).clicked() {
                    ui.close();
                    self.editor.select_all();
                }
                if ui
                    .add_enabled(self.editor.selection.is_some(), egui::Button::new("Deselect").shortcut_text("Ctrl+D"))
                    .clicked()
                {
                    ui.close();
                    self.editor.deselect();
                }
            });

            ui.menu_button("View", |ui| {
                if ui.add(egui::Button::new("Zoom In").shortcut_text("Ctrl++")).clicked() {
                    ui.close();
                    self.zoom_by(1.25);
                }
                if ui.add(egui::Button::new("Zoom Out").shortcut_text("Ctrl+-")).clicked() {
                    ui.close();
                    self.zoom_by(0.8);
                }
                ui.separator();
                if ui.add(egui::Button::new("Fit to Window").shortcut_text("Ctrl+0")).clicked() {
                    ui.close();
                    self.fit_to_window();
                }
                if ui.add(egui::Button::new("Actual Pixels").shortcut_text("Ctrl+1")).clicked() {
                    ui.close();
                    self.actual_pixels();
                }
                ui.separator();
                // The chord is spelled out beside each toggle, the way the macOS menus do it.
                ui.checkbox(&mut self.show_rulers, "Rulers")
                    .on_hover_text("Rulers, and guides pulled from them (Ctrl+R)");
                ui.checkbox(&mut self.show_guides, "Guides").on_hover_text("Ctrl+;");
                ui.checkbox(&mut self.grid.visible, "Grid").on_hover_text("Ctrl+'");
                ui.checkbox(&mut self.snap.enabled, "Snap")
                    .on_hover_text("Ctrl+Shift+; - snap a guide or a move to the targets below");
                ui.checkbox(&mut self.guides_locked, "Lock Guides").on_hover_text("Ctrl+Alt+;");
                ui.add_enabled_ui(self.snap.enabled, |ui| {
                    ui.indent("snap-targets", |ui| {
                        ui.checkbox(&mut self.snap.guides, "Guides");
                        ui.checkbox(&mut self.snap.grid, "Grid");
                        ui.checkbox(&mut self.snap.document, "Canvas edges and center");
                        ui.checkbox(&mut self.snap.layers, "Other layers");
                    });
                });
                if ui.button("Grid Settings...").clicked() {
                    ui.close();
                    self.show_grid_dialog = true;
                }
                ui.add_enabled(
                    !self.editor.guides().is_empty(),
                    egui::Checkbox::new(&mut self.guides_locked, "Lock Guides"),
                )
                .on_hover_text("A locked guide cannot be dragged or deleted");
                let guides: Vec<(uuid::Uuid, String)> = self
                    .editor
                    .guides()
                    .iter()
                    .map(|guide| {
                        let axis = match guide.axis {
                            comp_core::geom::GuideAxis::Vertical => "Vertical",
                            comp_core::geom::GuideAxis::Horizontal => "Horizontal",
                        };
                        (guide.id, format!("{axis} {}", guide.position.round()))
                    })
                    .collect();
                if !guides.is_empty() {
                    ui.menu_button("Show Guides", |ui| {
                        for (id, label) in guides {
                            let mut visible = !self.hidden_guides.contains(&id);
                            if ui.checkbox(&mut visible, label).changed() {
                                if visible {
                                    self.hidden_guides.remove(&id);
                                } else {
                                    self.hidden_guides.insert(id);
                                }
                            }
                        }
                        if ui.button("Show All").clicked() {
                            self.hidden_guides.clear();
                            ui.close();
                        }
                    });
                }
                if ui
                    .add_enabled(!self.editor.guides().is_empty(), egui::Button::new("Clear Guides"))
                    .clicked()
                {
                    ui.close();
                    self.editor.clear_guides();
                }
            });

            ui.menu_button("Layer", |ui| {
                if ui.add(egui::Button::new("New Layer")).clicked() {
                    ui.close();
                    self.editor.add_layer();
                }
                if ui
                    .add_enabled(self.editor.document.active_layer.is_some(), egui::Button::new("Duplicate Layer"))
                    .clicked()
                {
                    ui.close();
                    self.editor.duplicate_active();
                }
                if ui
                    .add_enabled(self.editor.document.active_layer.is_some(), egui::Button::new("Delete Layer").shortcut_text("Delete"))
                    .clicked()
                {
                    ui.close();
                    self.editor.delete_active();
                }
                ui.separator();
                if ui.add(egui::Button::new("New Blank Layer").shortcut_text("Ctrl+Shift+N")).clicked() {
                    ui.close();
                    self.editor.add_layer();
                }
                if ui
                    .add_enabled(self.editor.document.active_layer.is_some(), egui::Button::new("Duplicate Layer").shortcut_text("Ctrl+J"))
                    .clicked()
                {
                    ui.close();
                    self.editor.duplicate_active();
                }
                if ui
                    .add_enabled(self.editor.document.active_layer.is_some(), egui::Button::new("Move Layer Up").shortcut_text("Ctrl+]"))
                    .clicked()
                {
                    ui.close();
                    self.editor.move_active_layer(1);
                }
                if ui
                    .add_enabled(self.editor.document.active_layer.is_some(), egui::Button::new("Move Layer Down").shortcut_text("Ctrl+["))
                    .clicked()
                {
                    ui.close();
                    self.editor.move_active_layer(-1);
                }
                ui.separator();
                let merge_label = self.editor.merge_label();
                if ui
                    .add(egui::Button::new(merge_label).shortcut_text("Ctrl+E"))
                    .on_hover_text(if self.editor.selected.len() > 1 {
                        "Merge the selected layers into one"
                    } else {
                        "Merge down into the layer below"
                    })
                    .clicked()
                {
                    ui.close();
                    self.editor.merge_down();
                }
                if ui.add(egui::Button::new("Flatten Image").shortcut_text("Ctrl+Shift+F")).clicked() {
                    ui.close();
                    self.editor.flatten_image();
                }
                if ui
                    .add(egui::Button::new("Composite to Layer"))
                    .on_hover_text("Add the composite as a new layer, instead of copying it")
                    .clicked()
                {
                    ui.close();
                    self.editor.copy_merged();
                }
                ui.separator();
                ui.menu_button("New Adjustment Layer", |ui| {
                    for kind in comp_core::adjustment::AdjustmentKind::ALL {
                        if ui.button(kind.as_str()).clicked() {
                            ui.close();
                            self.editor.add_adjustment_layer(kind);
                        }
                    }
                });
                if ui
                    .add_enabled(
                        self.editor.document.active_layer.and_then(|id| self.editor.document.layer(id)).map(|layer| layer.effects.is_some()).unwrap_or(false),
                        egui::Button::new("Remove Effects"),
                    )
                    .clicked()
                {
                    ui.close();
                    if let Some(id) = self.editor.document.active_layer {
                        self.editor.begin_edit("Remove Effects");
                        self.editor.clear_effects(id);
                        self.editor.finish_edit();
                    }
                }
            });

            ui.menu_button("Filter", |ui| {
                let can_filter = self
                    .editor
                    .document
                    .active_layer
                    .and_then(|id| self.editor.document.layer(id))
                    .map(|layer| layer.image.is_some() && !layer.is_group && layer.adjustment.is_none())
                    .unwrap_or(false);
                for kind in crate::filters::MENU {
                    match kind.backend() {
                        // The four with their own home are offered further down.
                        FilterBackend::AdjustmentLayer(_)
                        | FilterBackend::CameraRaw
                        | FilterBackend::Subject
                        | FilterBackend::ContentAwareFill => continue,
                        FilterBackend::Unsupported(reason) => {
                            ui.add_enabled(false, egui::Button::new(kind.name()))
                                .on_disabled_hover_text(format!("Waiting for {reason}"));
                            continue;
                        }
                        FilterBackend::Pixels => {}
                    }
                    let label = if kind.has_parameters() {
                        format!("{}...", kind.name())
                    } else {
                        kind.name().to_string()
                    };
                    if ui
                        .add_enabled(can_filter, egui::Button::new(label))
                        .on_hover_text("Runs on the selected layer's pixels")
                        .clicked()
                    {
                        ui.close();
                        self.run_filter(kind);
                    }
                }
                ui.separator();
                let has_selection = self.editor.selection.is_some();
                if ui
                    .add_enabled(can_filter && has_selection, egui::Button::new(FilterKind::ContentAwareFill.name()))
                    .on_hover_text("Repaints the selection from the rest of the layer; select an area first")
                    .clicked()
                {
                    ui.close();
                    self.run_filter(FilterKind::ContentAwareFill);
                }
                let subject_hover = match crate::subject::hint(&self.subject_backend) {
                    Some(advice) => format!("Cut the background away from the active layer\n\n{advice}"),
                    None => "Cut the background away from the active layer (the model answers)".to_string(),
                };
                if ui
                    .add_enabled(can_filter, egui::Button::new("Remove Background"))
                    .on_hover_text(subject_hover)
                    .clicked()
                {
                    ui.close();
                    self.run_remove_background();
                }
                if ui
                    .add_enabled(can_filter, egui::Button::new("Camera Raw...").shortcut_text("Ctrl+Shift+R"))
                    .clicked()
                {
                    ui.close();
                    self.begin_raw_panel();
                }
                ui.separator();
                ui.menu_button("Adjustment Filters", |ui| {
                    for kind in crate::filters::MENU.into_iter().filter(|kind| matches!(kind.backend(), FilterBackend::AdjustmentLayer(_))) {
                        if ui
                            .button(kind.name())
                            .on_hover_text("Adds an adjustment layer, edited in the Layers panel")
                            .clicked()
                        {
                            ui.close();
                            self.run_filter(kind);
                        }
                    }
                });
            });

            ui.menu_button("Help", |ui| {
                if ui.add(egui::Button::new("About Compositor")).clicked() {
                    ui.close();
                    self.show_about = true;
                }
            });

            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let modified = self.editor.is_modified();
                ui.label(RichText::new(self.editor.file_name()).weak());
                if modified {
                    ui.label(RichText::new("*").strong());
                }
            });
        });
    }

    pub(crate) fn shortcuts(&mut self, ctx: &Context) {
        // While a name field has focus the keys belong to the text edit.
        if ctx.egui_wants_keyboard_input() {
            return;
        }
        // The arrow keys nudge the selected guide, a pixel at a time, and the curve editor owns
        // them whenever one of its points is selected.
        if self.selected_guide.is_some() && self.curve_selected.is_none() && !self.guides_locked {
            let step = if ctx.input(|input| input.modifiers.shift) { 10.0 } else { 1.0 };
            let mut nudge = 0.0;
            for (key, delta) in [
                (egui::Key::ArrowLeft, -step),
                (egui::Key::ArrowRight, step),
                (egui::Key::ArrowUp, step),
                (egui::Key::ArrowDown, -step),
            ] {
                if ctx.input(|input| input.key_pressed(key)) {
                    nudge += delta;
                }
            }
            if nudge != 0.0 {
                if let Some(id) = self.selected_guide {
                    if let Some(guide) = self.editor.guides().iter().find(|guide| guide.id == id) {
                        let position = match guide.axis {
                            comp_core::geom::GuideAxis::Vertical => guide.position + nudge,
                            // A horizontal guide moves the other way round: down is a bigger y.
                            comp_core::geom::GuideAxis::Horizontal => guide.position - nudge,
                        };
                        self.editor.begin_edit("Move Guide");
                        self.editor.move_guide(id, position);
                        self.editor.finish_edit();
                    }
                }
            }
        }
        // The arrow keys belong to whoever is in front: the text session, a selected guide, a curve
        // point, and only then the layer the canvas would nudge.
        let arrow = crate::shortcuts::arrow_target(
            self.text_edit.is_some(),
            self.selected_guide.is_some(),
            self.curve_selected.is_some(),
            self.editor.document.active_layer.is_some(),
        );
        if arrow == crate::shortcuts::ArrowTarget::Layer {
            let step = if ctx.input(|input| input.modifiers.shift) { 10.0 } else { 1.0 };
            let mut delta = egui::Vec2::ZERO;
            for (key, offset) in [
                (Key::ArrowLeft, (-step, 0.0f32)),
                (Key::ArrowRight, (step, 0.0)),
                (Key::ArrowUp, (0.0, -step)),
                (Key::ArrowDown, (0.0, step)),
            ] {
                if ctx.input(|input| input.key_pressed(key)) {
                    delta.x += offset.0;
                    delta.y += offset.1;
                }
            }
            if delta != egui::Vec2::ZERO {
                if let Some(id) = self.editor.document.active_layer {
                    self.editor.begin_edit("Nudge Layer");
                    self.editor.translate_layer(id, delta);
                    self.editor.finish_edit();
                    self.request_render(true);
                }
            }
        }
        let pressed = read_shortcuts(ctx, self.text_edit.is_some());
        if pressed.escape {
            if self.editor.is_stroking() {
                self.editor.cancel_stroke();
            }
            self.editor.machine.cancel();
            self.editor.deselect();
        }
        if pressed.new_document {
            self.show_new_dialog = true;
        }
        if pressed.open {
            self.open_dialog();
        }
        if pressed.import {
            self.import_dialog(true);
        }
        if pressed.save_as {
            self.save_as_dialog();
        } else if pressed.save {
            self.save();
        }
        if pressed.export {
            self.export_dialog();
        }
        if pressed.export_jpeg {
            self.export_jpeg_dialog();
        }
        if pressed.close_tab {
            let active = self.active_tab;
            self.close_tab(active);
        }
        if pressed.new_layer {
            self.editor.add_layer();
        }
        if pressed.duplicate_layer {
            self.editor.duplicate_active();
        }
        if pressed.move_layer_up {
            self.editor.move_active_layer(1);
        }
        if pressed.move_layer_down {
            self.editor.move_active_layer(-1);
        }
        if pressed.delete_layer {
            if self.editor.selected.len() > 1 {
                self.editor.delete_selection();
            } else if self.editor.selection.is_some() {
                self.editor.deselect();
            } else {
                self.editor.delete_active();
            }
        }
        // The adjustments macOS offers from the keyboard become adjustment layers here.
        for (fired, kind) in [
            (pressed.curves, comp_core::adjustment::AdjustmentKind::Curves),
            (pressed.levels, comp_core::adjustment::AdjustmentKind::Levels),
            (pressed.hue_saturation, comp_core::adjustment::AdjustmentKind::HueSaturation),
            (pressed.invert, comp_core::adjustment::AdjustmentKind::Invert),
        ] {
            if fired {
                self.editor.add_adjustment_layer(kind);
                self.request_render(true);
            }
        }
        if pressed.cut {
            // Cut is copy-then-delete on the layer, which is what this editor cuts.
            self.copy_layer();
            if self.editor.selected.len() > 1 {
                self.editor.delete_selection();
            } else {
                self.editor.delete_active();
            }
        }
        if pressed.show_grid {
            self.grid.visible = !self.grid.visible;
        }
        if pressed.show_guides {
            self.show_guides = !self.show_guides;
        }
        if pressed.show_rulers {
            self.show_rulers = !self.show_rulers;
        }
        if pressed.snap {
            self.snap.enabled = !self.snap.enabled;
        }
        if pressed.lock_guides {
            self.guides_locked = !self.guides_locked;
        }
        if let Some(digit) = pressed.opacity_digit {
            // macOS reads one digit as the tens of a percentage: 5 is 50%, 0 is 100%.
            if let Some(id) = self.editor.document.active_layer {
                let opacity = crate::session::Editor::opacity_for_digit(digit);
                self.editor.set_opacity(id, opacity);
                self.editor.set_message(format!("Opacity {:.0}%", opacity * 100.0));
            }
        }
        if pressed.blend_step != 0 {
            if let Some(id) = self.editor.document.active_layer {
                if let Some(blend) = self.editor.cycle_blend_mode(id, pressed.blend_step) {
                    self.editor.set_message(format!("Blend mode {blend}"));
                }
            }
        }
        if pressed.harder_brush || pressed.softer_brush {
            let step = if pressed.harder_brush { 0.1 } else { -0.1 };
            self.editor.brush.hardness = (self.editor.brush.hardness + step).clamp(0.0, 1.0);
            self.editor
                .set_message(format!("Brush hardness {:.0}%", self.editor.brush.hardness * 100.0));
        }
        if pressed.camera_raw {
            self.begin_raw_panel();
        }
        if pressed.merge_down {
            self.editor.merge_down();
        }
        if pressed.flatten {
            self.editor.flatten_image();
        }
        if pressed.copy_merged {
            self.copy_merged();
        }
        if pressed.copy_layer {
            self.copy_layer();
        }
        if pressed.paste {
            self.paste();
        }
        if pressed.undo {
            self.editor.undo();
        }
        if pressed.redo {
            self.editor.redo();
        }
        if pressed.select_all {
            self.editor.select_all();
        }
        if pressed.deselect {
            self.editor.deselect();
        }
        if pressed.zoom_in {
            self.zoom_by(1.25);
        }
        if pressed.zoom_out {
            self.zoom_by(0.8);
        }
        if pressed.fit {
            self.fit_to_window();
        }
        if pressed.actual {
            self.actual_pixels();
        }
        if pressed.larger_brush {
            self.editor.brush.size = (self.editor.brush.size * 1.25).min(2100.0);
        }
        if pressed.smaller_brush {
            self.editor.brush.size = (self.editor.brush.size / 1.25).max(1.0);
        }
        if let Some(tool) = pressed.tool {
            self.choose_tool(tool);
        }
        if pressed.exit {
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
        }
    }

    /// The New Document dialog.
    pub(crate) fn new_document_window(&mut self, ctx: &Context) {
        if !self.show_new_dialog {
            return;
        }
        let mut open = true;
        let mut create = false;
        egui::Window::new("New document")
            .collapsible(false)
            .resizable(false)
            .open(&mut open)
            .show(ctx, |ui| {
                ui.horizontal(|ui| {
                    ui.label("Width");
                    ui.add(egui::DragValue::new(&mut self.new_size.0).range(1..=32768).suffix(" px"));
                    ui.label("Height");
                    ui.add(egui::DragValue::new(&mut self.new_size.1).range(1..=32768).suffix(" px"));
                });
                ui.horizontal(|ui| {
                    if ui.button("Create").clicked() {
                        create = true;
                    }
                    if ui.button("Cancel").clicked() {
                        self.show_new_dialog = false;
                    }
                });
            });
        if create {
            self.new_document(self.new_size.0.max(1), self.new_size.1.max(1));
            self.show_new_dialog = false;
        } else if !open {
            self.show_new_dialog = false;
        }
    }

    pub(crate) fn about_window(&mut self, ctx: &Context) {
        if !self.show_about {
            return;
        }
        let mut open = true;
        egui::Window::new("About Compositor")
            .collapsible(false)
            .resizable(false)
            .open(&mut open)
            .show(ctx, |ui| {
                ui.label(format!("Compositor for Windows {}", comp_core::VERSION));
                ui.label("A Rust rewrite of Compositor for macOS.");
                ui.label("Canvas, layers, brush and .comp packages; see NOTES.md for the shortcut table.");
            });
        if !open {
            self.show_about = false;
        }
    }
}
