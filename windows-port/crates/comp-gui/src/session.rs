//! The editor state: the open document, its history, the view, the tools and the layer commands.
//!
//! Every change a panel makes goes through this type, so undo granularity and the modified flag
//! have exactly one place to be right, and every command is testable without a window.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use comp_core::adjustment::{Adjustment, AdjustmentKind};
use comp_core::bitmap::{Bitmap8, Gray8};
use comp_core::blend::BlendMode;
use comp_core::effects::LayerEffects;
use comp_core::document::Document;
use comp_core::geom::PointF;
use comp_core::history::History;
use comp_core::geom::SizeF;
use comp_core::layer::Layer;
use comp_core::text::TextStyle;
use egui::{Pos2, Rect, Vec2};
use uuid::Uuid;

use crate::engine;
use crate::engine::paint::{self, Stroke as PaintStroke};
use crate::tools::{BrushSettings, Tool, ToolMachine};
use crate::view::CanvasView;

/// Rough byte counts for the status bar.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MemoryEstimate {
    /// Layer images and masks, counted the way the format's budget counts them.
    pub document_bytes: u64,
    /// What the undo stack holds beyond the live document.
    pub history_bytes: u64,
}

/// Where a stroke puts its paint.
enum StrokeTarget {
    /// The layer's own pixels.
    Image,
    /// A scratch copy of the layer's mask, converted back when the stroke ends, because comp-brush
    /// paints RGBA and a mask is gray.
    Mask { scratch: Bitmap8 },
}

impl StrokeTarget {
    fn is_mask(&self) -> bool {
        matches!(self, StrokeTarget::Mask { .. })
    }

    fn scratch_mut(&mut self) -> Option<&mut Bitmap8> {
        match self {
            StrokeTarget::Image => None,
            StrokeTarget::Mask { scratch } => Some(scratch),
        }
    }
}

/// One paint stroke in flight.
struct StrokeSession {
    layer: Uuid,
    /// The document as it was before the stroke, which is also the undo step.
    before: Document,
    stroke: PaintStroke,
    /// The marquee as a layer-sized coverage mask, built once when the stroke starts.
    clip: Option<Gray8>,
    target: StrokeTarget,
    changed: bool,
    label: &'static str,
}

/// The whole editing session: document, history, view, tools and messages.
pub struct Editor {
    pub document: Document,
    pub history: History,
    /// Where the document came from, when it has a file.
    pub path: Option<PathBuf>,
    /// Content digest taken the last time the package was read or written.
    pub digest: Option<String>,
    pub view: CanvasView,
    pub machine: ToolMachine,
    pub brush: BrushSettings,
    /// The paint color, straight RGBA.
    pub color: [u8; 4],
    /// The marquee in document coordinates, when one is active.
    pub selection: Option<Rect>,
    /// True while the brush paints the selected layer's mask instead of its pixels.
    pub mask_painting: bool,
    /// The layers the panel has selected, in document order; the active layer is one of them.
    pub selected: Vec<Uuid>,
    /// Bumped by every change that alters the rendered picture, so the canvas knows to re-render.
    pub epoch: u64,
    /// The last thing the user should know, shown in the status bar.
    pub message: String,
    /// True when the message is a failure, which the status bar colors differently.
    pub message_is_error: bool,
    stroke: Option<StrokeSession>,
    /// Canvas pixels an in-flight stroke changed since the last render request.
    dirty: Option<engine::Bounds>,
    pending: Option<(Document, String)>,
    pending_dirty: bool,
}

impl Default for Editor {
    fn default() -> Self {
        Editor::with_document(Document::with_background(1280, 800))
    }
}

impl Editor {
    pub fn with_document(document: Document) -> Self {
        let mut history = History::default();
        // A brand-new document has no edits yet, so it must not open with a modified marker.
        history.mark_saved();
        Editor {
            document,
            history,
            path: None,
            digest: None,
            view: CanvasView::default(),
            machine: ToolMachine::default(),
            brush: BrushSettings::default(),
            color: [0, 0, 0, 255],
            selection: None,
            mask_painting: false,
            selected: Vec::new(),
            epoch: 1,
            message: String::new(),
            message_is_error: false,
            stroke: None,
            dirty: None,
            pending: None,
            pending_dirty: false,
        }
    }

    /// Adopts a document built outside the format, which has no package path to save back to.
    pub fn adopt_imported(&mut self, document: Document) {
        self.history.clear();
        self.history.mark_saved();
        self.path = None;
        self.digest = None;
        self.selection = None;
        self.stroke = None;
        self.dirty = None;
        self.pending = None;
        self.selected.clear();
        self.view = CanvasView::default();
        self.epoch += 1;
        self.document = document;
    }

    /// Swaps the document for one a worker produced, as a single undo step.
    pub fn replace_document(&mut self, document: Document, label: &str) -> bool {
        if document == self.document {
            return false;
        }
        let before = std::mem::replace(&mut self.document, document);
        self.history.record(before, label);
        self.epoch += 1;
        true
    }

    pub fn document_size(&self) -> (u32, u32) {
        (self.document.width, self.document.height)
    }

    pub fn is_modified(&self) -> bool {
        self.history.is_modified()
    }

    /// The window title: file name, a modified marker and the product name.
    pub fn title(&self) -> String {
        format!("{}{} - Compositor", self.file_name(), if self.is_modified() { " *" } else { "" })
    }

    pub fn file_name(&self) -> String {
        self.path
            .as_ref()
            .and_then(|path| path.file_name())
            .map(|name| name.to_string_lossy().to_string())
            .unwrap_or_else(|| "Untitled.comp".to_string())
    }

    pub fn set_message(&mut self, text: impl Into<String>) {
        self.message = text.into();
        self.message_is_error = false;
    }

    pub fn set_error(&mut self, text: impl Into<String>) {
        self.message = text.into();
        self.message_is_error = true;
    }

    pub fn tool(&self) -> Tool {
        self.machine.tool()
    }

    pub fn set_tool(&mut self, tool: Tool) {
        self.machine.set_tool(tool);
    }

    // ---------------------------------------------------------------- edits

    /// Runs a mutation and records one undo step when it changed something.
    fn edit(
        &mut self,
        label: &str,
        render: bool,
        change: impl FnOnce(&mut Document) -> bool,
    ) -> bool {
        self.begin_edit(label);
        let changed = self.mutate(render, change);
        self.finish_edit();
        changed
    }

    /// Runs a change and records it as one undo step, unless the caller is already inside a
    /// multi-frame edit such as a slider drag: then the change joins that step.
    ///
    /// A setter that a panel calls on a click - a visibility box, a blend mode chosen from a menu, a
    /// typed name - has no drag around it, so it has to record its own step. One that a drag calls
    /// every frame must not, or a drag would leave a step per frame.
    fn change(&mut self, label: &str, render: bool, change: impl FnOnce(&mut Document) -> bool) -> bool {
        if self.pending.is_some() {
            self.mutate(render, change)
        } else {
            self.edit(label, render, change)
        }
    }

    /// Starts a multi-frame edit such as a slider drag. The first label wins, so a drag stays one
    /// step even when the pointer crosses another control.
    pub fn begin_edit(&mut self, label: &str) {
        if self.pending.is_none() {
            self.pending = Some((self.document.clone(), label.to_string()));
            self.pending_dirty = false;
        }
    }

    /// Closes a multi-frame edit, recording it only when the document really changed.
    pub fn finish_edit(&mut self) {
        if let Some((before, label)) = self.pending.take() {
            if self.pending_dirty {
                self.history.record(before, label);
            }
        }
        self.pending_dirty = false;
    }

    fn mutate(&mut self, render: bool, change: impl FnOnce(&mut Document) -> bool) -> bool {
        let changed = change(&mut self.document);
        if changed {
            self.pending_dirty = true;
            if render {
                self.epoch += 1;
            }
        }
        changed
    }

    // -------------------------------------------------------------- history

    pub fn can_undo(&self) -> bool {
        self.history.can_undo()
    }

    pub fn can_redo(&self) -> bool {
        self.history.can_redo()
    }

    pub fn undo_label(&self) -> Option<&str> {
        self.history.undo_label()
    }

    pub fn redo_label(&self) -> Option<&str> {
        self.history.redo_label()
    }

    pub fn undo(&mut self) -> bool {
        let Some(previous) = self.history.undo(&self.document) else { return false };
        self.stroke = None;
        self.dirty = None;
        self.document = previous;
        // A step may have removed layers, so the selection is trimmed to what came back.
        self.selected = crate::multiselect::prune(&self.document, &self.selected);
        self.epoch += 1;
        true
    }

    pub fn redo(&mut self) -> bool {
        let Some(next) = self.history.redo(&self.document) else { return false };
        self.stroke = None;
        self.dirty = None;
        self.document = next;
        self.selected = crate::multiselect::prune(&self.document, &self.selected);
        self.epoch += 1;
        true
    }

    // ----------------------------------------------------------------- files

    /// Reads a package and starts a clean session on it.
    pub fn load(&mut self, path: &Path) -> Result<(), String> {
        let (document, digest) = crate::worker::open_document(path).map_err(|problem| problem.summary())?;
        self.adopt(document, digest, path);
        Ok(())
    }

    /// Writes the document to a package and marks it clean.
    pub fn save_to(&mut self, path: &Path) -> Result<(), String> {
        crate::worker::save_document(&mut self.document, path)?;
        self.path = Some(path.to_path_buf());
        self.digest = comp_core::digest::package_digest(path).ok();
        self.history.mark_saved();
        Ok(())
    }

    /// Adopts a document that was read on a worker thread and starts a clean session on it.
    pub fn adopt(&mut self, document: Document, digest: Option<String>, path: &Path) {
        self.document = document;
        self.history.clear();
        self.history.mark_saved();
        self.path = Some(path.to_path_buf());
        self.digest = digest;
        self.selection = None;
        self.stroke = None;
        self.dirty = None;
        self.pending = None;
        self.selected.clear();
        self.view = CanvasView::default();
        self.epoch += 1;
    }

    // ---------------------------------------------------------------- layers

    pub fn select_layer(&mut self, id: Uuid) {
        self.document.active_layer = Some(id);
        self.selected = vec![id];
    }

    /// True when the layer row should be drawn highlighted.
    pub fn is_selected(&self, id: Uuid) -> bool {
        self.selected.contains(&id) || (self.selected.is_empty() && self.document.active_layer == Some(id))
    }

    /// Applies a click on a layer row, with the modifiers the panel read from the keyboard.
    pub fn click_layer(&mut self, clicked: Uuid, kind: crate::multiselect::ClickKind) -> bool {
        let next = crate::multiselect::apply_click(&self.document, &self.selected, self.document.active_layer, clicked, kind);
        let active = crate::multiselect::active_after_click(&self.document, &self.selected, clicked, kind);
        if next == self.selected && active == self.document.active_layer {
            return false;
        }
        self.selected = next;
        self.document.active_layer = active;
        true
    }

    /// Deletes every selected layer, as one step.
    pub fn delete_selection(&mut self) -> bool {
        let doomed = if self.selected.is_empty() {
            self.document.active_layer.into_iter().collect::<Vec<Uuid>>()
        } else {
            self.selected.clone()
        };
        if doomed.is_empty() {
            return false;
        }
        let changed = self.edit("Delete Layer", false, |document| {
            let before = document.layers.len();
            for id in &doomed {
                document.remove_layer(*id);
            }
            document.layers.len() != before
        });
        if changed {
            self.selected = crate::multiselect::prune(&self.document, &self.selected);
            // Everything selected is gone, so the topmost layer left takes over; the panels always
            // have something to edit.
            if self.selected.is_empty() {
                self.selected = self.document.layers.last().map(|layer| vec![layer.id]).unwrap_or_default();
            }
            self.document.active_layer = self.selected.last().copied();
            self.set_message(format!("Deleted {} layer(s)", doomed.len()));
        }
        changed
    }

    /// The label the merge command should show for the current selection.
    pub fn merge_label(&self) -> &'static str {
        match crate::merge::merge_plan(&self.document, &self.selected) {
            Some(plan) => plan.label,
            None if self.selected.len() > 1 => "Merge Layers",
            None => "Merge Down",
        }
    }

    // -------------------------------------------------------------- clipboard

    /// Puts the selected layer's pixels on the clipboard.
    pub fn copy_layer_to_clipboard(&mut self, clipboard: &mut dyn crate::clipboard::Clipboard) -> Result<(), String> {
        let Some(id) = self.paintable_layer() else {
            return Err("Select a raster layer to copy".to_string());
        };
        let Some(image) = self.document.layer(id).and_then(|layer| layer.image.as_deref()) else {
            return Err("The selected layer has no pixels".to_string());
        };
        clipboard.set_image(image)?;
        self.set_message("Copied the layer to the clipboard");
        Ok(())
    }

    /// Puts the composite on the clipboard, which is what Copy Merged means.
    pub fn copy_merged_to_clipboard(&mut self, clipboard: &mut dyn crate::clipboard::Clipboard) -> Result<(), String> {
        let Some(flat) = crate::merge::flatten(&self.document) else {
            return Err("There is nothing to copy".to_string());
        };
        clipboard.set_image(&flat)?;
        self.set_message("Copied the composite to the clipboard");
        Ok(())
    }

    /// Pastes the clipboard's picture as a new layer, centered on the canvas.
    pub fn paste_from_clipboard(&mut self, clipboard: &mut dyn crate::clipboard::Clipboard) -> Result<(), String> {
        let image = clipboard.get_image()?;
        if image.is_empty() {
            return Err(crate::clipboard::NO_IMAGE.to_string());
        }
        let (width, height) = (image.width() as f64, image.height() as f64);
        let width = width.min(self.document.width as f64);
        let height = height.min(self.document.height as f64);
        let origin = comp_core::geom::PointF::new(
            ((self.document.width as f64 - width) / 2.0).floor(),
            ((self.document.height as f64 - height) / 2.0).floor(),
        );
        let changed = self.edit("Paste", true, |document| {
            let mut layer = Layer::with_image("Pasted", image.clone());
            layer.transform.origin = origin;
            layer.transform.size = comp_core::geom::SizeF::new(width, height);
            document.add_layer(layer, None);
            true
        });
        if changed {
            if let Some(id) = self.document.active_layer {
                self.selected = vec![id];
            }
            self.set_message("Pasted the clipboard as a new layer");
        }
        Ok(())
    }

    pub fn add_layer(&mut self) -> bool {
        let width = self.document.width;
        let height = self.document.height;
        let parent = self
            .document
            .active_layer
            .and_then(|id| self.document.layer(id))
            .filter(|layer| layer.is_group)
            .map(|layer| layer.id);
        let name = format!("Layer {}", self.document.layers.len() + 1);
        self.edit("New Layer", false, |document| {
            let mut layer = Layer::raster(name, width, height);
            layer.image = Some(Arc::new(Bitmap8::new(width, height)));
            layer.image_file = Some(layer.expected_image_file());
            document.add_layer(layer, parent);
            true
        })
    }

    /// Copies the selected layer, or a whole group with its children, directly above the original.
    pub fn duplicate_active(&mut self) -> bool {
        let Some(root) = self.document.active_layer else { return false };
        let mut duplicated = None;
        let changed = self.edit("Duplicate Layer", false, |document| {
            let indices = document.subtree_indices(root);
            if indices.is_empty() {
                return false;
            }
            let mut remapped: HashMap<Uuid, Uuid> = HashMap::new();
            let mut copies = Vec::with_capacity(indices.len());
            for index in &indices {
                let source = document.layers[*index].clone();
                let mut copy = source.clone();
                let new_id = Uuid::new_v4();
                remapped.insert(source.id, new_id);
                copy.id = new_id;
                // A descendant's parent is always earlier in the subtree, so the map already has it;
                // the root keeps its original parent, which is outside the copy.
                copy.parent = source.parent.map(|parent| remapped.get(&parent).copied().unwrap_or(parent));
                if source.id == root {
                    copy.name = format!("{} copy", source.name);
                    duplicated = Some(new_id);
                }
                if copy.image.is_some() {
                    copy.image_file = Some(copy.expected_image_file());
                }
                if copy.mask.is_some() {
                    copy.mask_file = Some(copy.expected_mask_file());
                }
                copies.push(copy);
            }
            let insert_at = indices[indices.len() - 1] + 1;
            document.layers.splice(insert_at..insert_at, copies);
            document.active_layer = duplicated;
            true
        });
        changed
    }

    pub fn delete_active(&mut self) -> bool {
        let Some(id) = self.document.active_layer else { return false };
        let changed = self.edit("Delete Layer", false, |document| !document.remove_layer(id).is_empty());
        if changed {
            self.set_message("Layer deleted");
        }
        changed
    }

    // ------------------------------------------------------------ mask filling

    /// Fills the selected layer's mask with a gradient, as one step.
    ///
    /// The drag arrives in document pixels and is mapped into the mask's own grid, so a gradient
    /// lands under the pointer whatever the layer's placement.
    pub fn fill_mask_gradient(
        &mut self,
        shape: crate::maskfill::GradientShape,
        from: comp_core::PointF,
        to: comp_core::PointF,
        invert: bool,
        blend: crate::maskfill::GradientBlend,
    ) -> bool {
        let Some(id) = self.mask_layer() else {
            self.set_error("Select a layer with a mask to fill");
            return false;
        };
        let Some((image_width, image_height)) = self.layer_image_size(id) else {
            self.set_error("The layer has no pixels to place a mask against");
            return false;
        };
        let (Some(from), Some(to)) = (
            self.grid_pixels(id, true, egui::Pos2::new(from.x as f32, from.y as f32)),
            self.grid_pixels(id, true, egui::Pos2::new(to.x as f32, to.y as f32)),
        ) else {
            self.set_error("The gradient does not map onto this layer");
            return false;
        };
        let drag = crate::maskfill::GradientDrag {
            shape,
            from: (from.0 as f64, from.1 as f64),
            to: (to.0 as f64, to.1 as f64),
            invert,
        };
        let ramp = crate::maskfill::gradient(image_width, image_height, &drag);
        // Adding or subtracting meets the mask that is there; replacing throws it away.
        let filled = match self.document.layer(id).and_then(|layer| layer.mask.as_deref()) {
            Some(existing) => crate::maskfill::apply_gradient(existing, &ramp, blend),
            None => ramp,
        };
        self.replace_mask(id, filled, shape.label())
    }

    /// Softens the selected layer's mask by this radius, as one step.
    pub fn feather_mask(&mut self, radius: f64) -> bool {
        let Some(id) = self.mask_layer() else {
            self.set_error("Select a layer with a mask to feather");
            return false;
        };
        let Some(source) = self.document.layer(id).and_then(|layer| layer.mask.as_deref()).cloned() else {
            self.set_error("The layer has no mask");
            return false;
        };
        if !radius.is_finite() || radius <= 0.0 {
            self.set_error("A feather needs a radius above zero");
            return false;
        }
        let softened = crate::maskfill::feather(&source, radius);
        self.replace_mask(id, softened, "Feather Mask")
    }

    /// Writes a mask without recording a step, for tests that need a starting shape.
    #[cfg(test)]
    fn replace_mask_for_test(&mut self, id: Uuid, mask: Gray8) -> bool {
        match self.document.layer_mut(id) {
            Some(layer) => {
                layer.mask = Some(Arc::new(mask));
                true
            }
            None => false,
        }
    }

    /// The layer whose mask the tools are allowed to write.
    fn mask_layer(&self) -> Option<Uuid> {
        let id = self.paintable_layer()?;
        let layer = self.document.layer(id)?;
        (layer.mask.is_some() && layer.mask_enabled).then_some(id)
    }

    /// Writes a whole mask back, as one step.
    fn replace_mask(&mut self, id: Uuid, mask: Gray8, label: &str) -> bool {
        let changed = self.edit(label, true, |document| match document.layer_mut(id) {
            Some(layer) if layer.mask.as_deref() != Some(&mask) => {
                layer.mask = Some(Arc::new(mask));
                true
            }
            _ => false,
        });
        if changed {
            self.set_message(format!("{label} applied to the mask"));
        }
        changed
    }

    // ----------------------------------------------------------------- guides

    /// The document's alignment guides.
    pub fn guides(&self) -> &[comp_core::geom::Guide] {
        &self.document.guides
    }

    /// Adds an alignment guide, as one step. None when the document holds as many as it may.
    pub fn add_guide(&mut self, axis: comp_core::geom::GuideAxis, position: f64) -> Option<Uuid> {
        if !position.is_finite() {
            self.set_error("A guide needs a position");
            return None;
        }
        let guide = comp_core::geom::Guide { id: Uuid::new_v4(), axis, position };
        let added = self.edit("Add Guide", false, |document| {
            if document.guides.len() >= comp_core::limits::MAX_GUIDES {
                return false;
            }
            document.guides.push(guide);
            true
        });
        if added {
            self.set_message(format!("Guide at {:.0}", position.round()));
            Some(guide.id)
        } else {
            self.set_error(format!("A document holds at most {} guides", comp_core::limits::MAX_GUIDES));
            None
        }
    }

    /// Moves a guide while it is being dragged; the caller owns the undo step.
    pub fn move_guide(&mut self, id: Uuid, position: f64) -> bool {
        if !position.is_finite() {
            return false;
        }
        self.change("Move Guide", false, |document| match document.guides.iter_mut().find(|guide| guide.id == id) {
            Some(guide) if guide.position != position => {
                guide.position = position;
                true
            }
            _ => false,
        })
    }

    /// Removes one guide, as one step.
    pub fn remove_guide(&mut self, id: Uuid) -> bool {
        self.edit("Delete Guide", false, |document| {
            let before = document.guides.len();
            document.guides.retain(|guide| guide.id != id);
            document.guides.len() != before
        })
    }

    /// Removes every guide, as one step.
    pub fn clear_guides(&mut self) -> bool {
        let cleared = self.edit("Clear Guides", false, |document| {
            if document.guides.is_empty() {
                return false;
            }
            document.guides.clear();
            true
        });
        if cleared {
            self.set_message("Guides cleared");
        }
        cleared
    }

    // --------------------------------------------------------------- commands

    /// Merges the active layer with the one below it, or a folder with its contents.
    ///
    /// The plan and the compositing come from the merge module, so the pixels are the canvas's own.
    pub fn merge_down(&mut self) -> bool {
        let Some(plan) = crate::merge::merge_plan(&self.document, &self.selected) else {
            self.set_error("Nothing to merge: pick a layer with a sibling below it that is not a folder");
            return false;
        };
        let label = plan.label;
        if self.edit(label, true, |document| crate::merge::apply_plan(document, &plan)) {
            if let Some(id) = self.document.active_layer {
                self.selected = vec![id];
            }
            self.set_message(label);
            true
        } else {
            self.set_error("Nothing to merge: the result would be empty");
            false
        }
    }

    /// Composites the whole document into one background layer.
    pub fn flatten_image(&mut self) -> bool {
        let changed = self.edit("Flatten Image", true, |document| {
            let Some(pixels) = crate::merge::flatten(document) else { return false };
            let mut layer = Layer::with_image("Background", pixels);
            layer.transform = comp_core::geom::Transform::full_canvas(document.width, document.height);
            let id = layer.id;
            document.layers = vec![layer];
            document.active_layer = Some(id);
            true
        });
        if changed {
            self.set_message("Flattened to one layer");
        } else {
            self.set_error("There is nothing to flatten");
        }
        changed
    }

    /// Adds a layer holding the composite, on top of the stack.
    pub fn copy_merged(&mut self) -> bool {
        let changed = self.edit("Copy Merged", true, |document| {
            let Some(pixels) = crate::merge::flatten(document) else { return false };
            let mut layer = Layer::with_image("Merged", pixels);
            layer.transform = comp_core::geom::Transform::full_canvas(document.width, document.height);
            document.add_layer(layer, None);
            true
        });
        if changed {
            self.set_message("Copied the composite into a new layer");
        }
        changed
    }

    // ---------------------------------------------------------------- filters

    /// Runs a filter from the Filter menu. Destructive filters rewrite the active layer's pixels.
    pub fn apply_filter(
        &mut self,
        kind: crate::filters::FilterKind,
        settings: crate::filters::FilterSettings,
    ) -> Result<(), String> {
        use crate::filters::{FilterBackend, FilterMenu};
        match kind.backend() {
            // The six macOS lists as image adjustments are adjustment layers here, edited by the
            // panel that already exists rather than by a second copy of it.
            FilterBackend::AdjustmentLayer(adjustment_kind) => {
                if self.add_adjustment_layer(adjustment_kind) {
                    self.set_message(format!("{} adjustment layer added", kind.name()));
                    Ok(())
                } else {
                    Err("The adjustment layer could not be added".to_string())
                }
            }
            FilterBackend::Pixels => {
                let source = self.filter_source()?;
                let filtered = crate::filters::run(&source, kind, &settings)?;
                if self.replace_active_pixels(filtered, kind.name()) {
                    self.set_message(format!("{} applied", kind.name()));
                    Ok(())
                } else {
                    Err(format!("{} could not be applied", kind.name()))
                }
            }
            FilterBackend::ContentAwareFill => {
                let source = self.filter_source()?;
                let Some(selection) = self.selection else {
                    return Err("Select the area to fill first".to_string());
                };
                let id = self.paintable_layer().ok_or("Select a raster layer to fill")?;
                let Some((image_width, image_height)) = self.layer_image_size(id) else {
                    return Err("The layer has no pixels to fill".to_string());
                };
                let min = self.grid_pixels(id, false, selection.min);
                let max = self.grid_pixels(id, false, selection.max);
                let (Some(min), Some(max)) = (min, max) else {
                    return Err("The selection does not map onto this layer".to_string());
                };
                let Some(mask) = crate::engine::paint::selection_mask(image_width, image_height, min, max) else {
                    return Err("The selection is empty on this layer".to_string());
                };
                let mut pixels = source;
                let filled = comp_brush::content_fill(&mut pixels, &mask).map_err(|error| error.to_string())?;
                if !filled {
                    return Err("Content-aware fill found nothing to copy from".to_string());
                }
                if self.replace_active_pixels(pixels, "Content-Aware Fill") {
                    self.set_message("Content-aware fill applied");
                    Ok(())
                } else {
                    Err("The fill could not be written back".to_string())
                }
            }
            FilterBackend::Subject => {
                Err("Remove Background runs from the Filter menu, which holds the model".to_string())
            }
            FilterBackend::CameraRaw => Err("Camera Raw has its own window".to_string()),
            FilterBackend::Unsupported(reason) => {
                Err(format!("{} is not available in this build: it needs {reason}", kind.name()))
            }
        }
    }

    // ------------------------------------------------------------------ subject

    /// Keeps a subject matte as this layer's mask, as one undo step.
    ///
    /// Which extractor produced the matte is the window's business, not this one's: the window runs
    /// the classical extractor and the model (in the background) and reports who answered. This only
    /// puts an answer on the layer, so that a run and its replacement are two separate steps.
    pub fn apply_subject_matte(&mut self, id: Uuid, matte: &Gray8, label: &str) -> Result<f64, String> {
        if self.document.layer(id).is_none() {
            return Err("The layer went away".to_string());
        }
        let coverage = crate::subject::coverage(matte);
        if coverage <= 0.0 {
            return Err("The extractor found no subject in this layer".to_string());
        }
        if !self.edit(label, true, |document| {
            document.set_layer_mask(id, matte.clone());
            true
        }) {
            return Err("The matte could not be kept as a mask".to_string());
        }
        self.set_message(format!("Subject matte covers {:.0}% of the layer", coverage * 100.0));
        Ok(coverage)
    }

    /// Cuts the background away from a layer's pixels with this matte, as one undo step.
    pub fn apply_background_cut(
        &mut self,
        id: Uuid,
        image: &Bitmap8,
        matte: &Gray8,
        label: &str,
    ) -> Result<f64, String> {
        if self.document.layer(id).is_none() {
            return Err("The layer went away".to_string());
        }
        let coverage = crate::subject::coverage(matte);
        if coverage <= 0.0 {
            return Err("The extractor found no subject in this layer".to_string());
        }
        let cut = comp_brush::remove_background(image, matte).map_err(|error| error.to_string())?;
        if !self.edit(label, true, |document| match document.layer_mut(id) {
            Some(layer) => {
                layer.image = Some(Arc::new(cut));
                true
            }
            None => false,
        }) {
            return Err("The cut-out could not be written back".to_string());
        }
        self.set_message(format!("Background removed ({:.0}% kept)", coverage * 100.0));
        Ok(coverage)
    }

    /// The active layer's pixels, for a filter to read.
    fn filter_source(&self) -> Result<Bitmap8, String> {
        let Some(id) = self.paintable_layer() else {
            return Err("Select a raster layer to filter".to_string());
        };
        match self.document.layer(id).and_then(|layer| layer.image.as_deref()) {
            Some(image) => Ok(image.clone()),
            None => Err("The selected layer has no pixels".to_string()),
        }
    }

    /// Writes pixels back to the active layer as one undo step.
    fn replace_active_pixels(&mut self, pixels: Bitmap8, label: &str) -> bool {
        let Some(id) = self.paintable_layer() else { return false };
        self.edit(label, true, |document| match document.layer_mut(id) {
            Some(layer) if !layer.is_group && layer.adjustment.is_none() => {
                layer.image = Some(Arc::new(pixels));
                layer.image_file = Some(layer.expected_image_file());
                true
            }
            _ => false,
        })
    }

    /// Moves a layer to a drop placement, as one undo step; its subtree travels with it.
    pub fn move_layer_to(&mut self, id: Uuid, placement: crate::reorder::Placement) -> bool {
        self.edit("Move Layer", true, |document| crate::reorder::move_to(document, id, placement))
    }

    /// Moves the selected layer one slot up or down among its siblings; its subtree travels with it.
    pub fn move_active_layer(&mut self, direction: i32) -> bool {
        let Some(id) = self.document.active_layer else { return false };
        let label = if direction > 0 { "Move Layer Up" } else { "Move Layer Down" };
        self.edit(label, false, |document| {
            let Some(layer) = document.layer(id) else { return false };
            let siblings = document.child_indices(layer.parent);
            let Some(position) = siblings.iter().position(|index| document.layers[*index].id == id) else {
                return false;
            };
            let target = if direction > 0 {
                if position + 1 >= siblings.len() {
                    return false;
                }
                let next = document.layers[siblings[position + 1]].id;
                siblings[position + 1] + document.subtree_indices(next).len()
            } else {
                if position == 0 {
                    return false;
                }
                siblings[position - 1]
            };
            document.move_layer(id, target)
        })
    }

    pub fn set_visibility(&mut self, id: Uuid, visible: bool) -> bool {
        self.change("Layer Visibility", true, |document| match document.layer_mut(id) {
            Some(layer) if layer.visible != visible => {
                layer.visible = visible;
                true
            }
            _ => false,
        })
    }

    pub fn set_opacity(&mut self, id: Uuid, opacity: f64) -> bool {
        let value = opacity.clamp(0.0, 1.0);
        self.change("Layer Opacity", true, |document| match document.layer_mut(id) {
            Some(layer) if (layer.opacity - value).abs() > f64::EPSILON => {
                layer.opacity = value;
                true
            }
            _ => false,
        })
    }

    /// Steps the active layer through the blend modes, which is what Shift and the minus or equals
    /// key do on the canvas. Answers the new mode's name for the status bar.
    pub fn cycle_blend_mode(&mut self, id: Uuid, step: i32) -> Option<&'static str> {
        let current = self.document.layer(id)?.blend;
        let modes = BlendMode::ALL;
        let index = modes.iter().position(|mode| *mode == current).unwrap_or(0) as i32;
        let next = (index + step).rem_euclid(modes.len() as i32) as usize;
        let blend = modes[next];
        self.set_blend(id, blend);
        Some(blend.as_str())
    }

    /// The opacity one digit of the keyboard asks for: 5 is 50%, 0 is 100%.
    pub fn opacity_for_digit(digit: u8) -> f64 {
        if digit == 0 {
            1.0
        } else {
            digit.min(9) as f64 / 10.0
        }
    }

    pub fn set_blend(&mut self, id: Uuid, blend: BlendMode) -> bool {
        self.change("Layer Blend Mode", true, |document| match document.layer_mut(id) {
            Some(layer) if layer.blend != blend => {
                layer.blend = blend;
                true
            }
            _ => false,
        })
    }

    pub fn set_name(&mut self, id: Uuid, name: String) -> bool {
        self.change("Rename Layer", false, |document| match document.layer_mut(id) {
            Some(layer) if layer.name != name => {
                layer.name = name;
                true
            }
            _ => false,
        })
    }

    /// Moves a layer by a document-space delta, used by the move tool.
    pub fn translate_layer(&mut self, id: Uuid, delta: Vec2) -> bool {
        self.change("Move Layer", true, |document| match document.layer_mut(id) {
            Some(layer) => {
                layer.transform.origin.x += delta.x as f64;
                layer.transform.origin.y += delta.y as f64;
                true
            }
            None => false,
        })
    }

    // ------------------------------------------------------------------ text

    /// The topmost text layer whose box contains a document point.
    pub fn text_layer_at(&self, at: Pos2) -> Option<Uuid> {
        let point = PointF::new(at.x as f64, at.y as f64);
        self.document
            .layers
            .iter()
            .rev()
            .find(|layer| layer.text.is_some() && layer.transform.document_bounds().contains(point))
            .map(|layer| layer.id)
    }

    /// Creates a text layer whose box starts at a document point, rasterizes it and records the
    /// whole thing as one step. The box is sized from the layout, so the pixels fill it one to one.
    pub fn add_text_layer(
        &mut self,
        at: Pos2,
        style: TextStyle,
        library: &mut comp_text::FontLibrary,
    ) -> Result<Uuid, String> {
        let (width, height) = comp_text::text_bounds(&style, library);
        if width == 0 || height == 0 {
            return Err("the text is too small to draw".to_string());
        }
        let mut layer = Layer::raster("Text", width, height);
        layer.text = Some(style);
        layer.transform.origin = PointF::new(at.x as f64, at.y as f64);
        layer.transform.size = SizeF::new(width as f64, height as f64);
        let mut created = None;
        let mut failure = None;
        let changed = self.edit("Add Text Layer", true, |document| {
            let id = document.add_layer(layer.clone(), None);
            match comp_text::commit_text_layer(document, id, library) {
                Ok((width, height)) => {
                    if let Some(layer) = document.layer_mut(id) {
                        layer.transform.size = SizeF::new(width as f64, height as f64);
                    }
                    created = Some(id);
                    true
                }
                Err(error) => {
                    // A text layer with no pixels would render as nothing, so it is not kept.
                    document.remove_layer(id);
                    failure = Some(error.to_string());
                    false
                }
            }
        });
        let _ = changed;
        match (created, failure) {
            (Some(id), _) => Ok(id),
            (None, Some(message)) => Err(message),
            (None, None) => Err("the text layer could not be created".to_string()),
        }
    }

    /// Replaces a text layer's metadata. The pixels follow when the draft is committed.
    pub fn set_text_style(&mut self, id: Uuid, style: TextStyle) -> bool {
        self.change("Edit Text", false, |document| match document.layer_mut(id) {
            Some(layer) if layer.text.as_ref() != Some(&style) => {
                layer.text = Some(style);
                true
            }
            _ => false,
        })
    }

    /// The text style of a layer, for the panel to edit.
    pub fn text_style(&self, id: Uuid) -> Option<TextStyle> {
        self.document.layer(id)?.text.clone()
    }

    /// Redraws a text layer's pixels through comp-text and sizes its box to the result.
    ///
    /// Returns the raster size, or the engine's reason for refusing.
    pub fn commit_text(&mut self, id: Uuid, library: &mut comp_text::FontLibrary) -> Result<(u32, u32), String> {
        let mut outcome: Result<(u32, u32), String> = Err("the text could not be drawn".to_string());
        self.change("Text Pixels", true, |document| match comp_text::commit_text_layer(document, id, library) {
            Ok((width, height)) => {
                if let Some(layer) = document.layer_mut(id) {
                    layer.transform.size = SizeF::new(width as f64, height as f64);
                }
                outcome = Ok((width, height));
                true
            }
            Err(error) => {
                outcome = Err(error.to_string());
                false
            }
        });
        outcome
    }

    // ------------------------------------------------------------- adjustments

    /// Adds an adjustment layer on top of the stack, as one step.
    pub fn add_adjustment_layer(&mut self, kind: AdjustmentKind) -> bool {
        let (width, height) = (self.document.width, self.document.height);
        let layer = Layer::adjustment(kind.as_str(), Adjustment::new(kind), width, height);
        self.edit("New Adjustment Layer", true, |document| {
            document.add_layer(layer.clone(), None);
            true
        })
    }

    /// The kind of the selected layer's adjustment, when the layer is an adjustment layer.
    pub fn adjustment_kind(&self, id: Uuid) -> Option<AdjustmentKind> {
        self.document.layer(id)?.adjustment.as_ref().map(|adjustment| adjustment.kind)
    }

    /// Edits an adjustment layer's settings, refusing anything the format would not accept.
    ///
    /// A slider can pass through a value the format forbids mid-drag, so a refused change leaves the
    /// stored one alone instead of writing something a save would reject.
    pub fn update_adjustment(&mut self, id: Uuid, change: impl FnOnce(&mut Adjustment)) -> bool {
        self.change("Adjustment", true, |document| {
            let Some(adjustment) = document.layer_mut(id).and_then(|layer| layer.adjustment.as_mut()) else {
                return false;
            };
            let before = adjustment.clone();
            change(adjustment);
            if !adjustment.is_valid() {
                *adjustment = before;
                return false;
            }
            *adjustment != before
        })
    }

    /// Edits a layer's effects, creating the record the first time one is enabled.
    pub fn update_effects(&mut self, id: Uuid, change: impl FnOnce(&mut LayerEffects)) -> bool {
        self.change("Layer Effect", true, |document| {
            let Some(layer) = document.layer_mut(id) else { return false };
            let mut effects = layer.effects.unwrap_or_default();
            let before = effects;
            change(&mut effects);
            if effects == before || !effects.is_valid() {
                return false;
            }
            layer.effects = Some(effects);
            true
        })
    }

    /// Replaces a raster layer's pixels, keeping its placement; used by the filters.
    pub fn replace_layer_pixels(&mut self, id: Uuid, image: Bitmap8) -> bool {
        self.change("Replace Pixels", true, |document| match document.layer_mut(id) {
            Some(layer) if !layer.is_group && layer.adjustment.is_none() => {
                layer.image = Some(Arc::new(image));
                layer.image_file = Some(layer.expected_image_file());
                true
            }
            _ => false,
        })
    }

    /// Drops every effect from a layer.
    pub fn clear_effects(&mut self, id: Uuid) -> bool {
        self.change("Remove Effects", true, |document| match document.layer_mut(id) {
            Some(layer) if layer.effects.is_some() => {
                layer.effects = None;
                true
            }
            _ => false,
        })
    }

    /// The layer painting may target: the selected layer when it is a plain raster layer.
    pub fn paintable_layer(&self) -> Option<Uuid> {
        let id = self.document.active_layer?;
        let layer = self.document.layer(id)?;
        if layer.is_group || layer.adjustment.is_some() {
            None
        } else {
            Some(id)
        }
    }

    // ------------------------------------------------------------------ masks

    /// Adds a mask to a layer: white, or copied from the layer's own alpha.
    pub fn add_layer_mask(&mut self, id: Uuid, from_alpha: bool) -> bool {
        let Some((width, height)) = self.layer_image_size(id) else {
            self.set_error("The layer has no pixels to build a mask from");
            return false;
        };
        let mask = if from_alpha {
            let Some(image) = self.document.layer(id).and_then(|layer| layer.image.clone()) else { return false };
            let mut mask = Gray8::new(width, height);
            let stride = width as usize;
            for row in 0..height as usize {
                let source = image.row(row as u32);
                let target = &mut mask.pixels_mut()[row * stride..(row + 1) * stride];
                for (index, value) in target.iter_mut().enumerate() {
                    *value = source[index * 4 + 3];
                }
            }
            mask
        } else {
            Gray8::filled(width, height, 255)
        };
        let label = if from_alpha { "Mask From Alpha" } else { "Add Layer Mask" };
        self.edit(label, true, |document| {
            document.set_layer_mask(id, mask.clone());
            true
        })
    }

    /// Removes a layer's mask and any clip that pointed at it.
    pub fn remove_layer_mask(&mut self, id: Uuid) -> bool {
        self.edit("Remove Layer Mask", true, |document| match document.layer_mut(id) {
            Some(layer) if layer.mask.is_some() || layer.mask_file.is_some() => {
                layer.mask = None;
                layer.mask_file = None;
                layer.mask_source = None;
                true
            }
            _ => false,
        })
    }

    /// Turns a layer's mask on or off, keeping the mask itself.
    pub fn set_mask_enabled(&mut self, id: Uuid, enabled: bool) -> bool {
        self.change("Toggle Mask", true, |document| match document.layer_mut(id) {
            Some(layer) if layer.mask_enabled != enabled => {
                layer.mask_enabled = enabled;
                true
            }
            _ => false,
        })
    }

    /// True when the layer carries a mask that compositing will use.
    pub fn has_mask(&self, id: Uuid) -> bool {
        self.document
            .layer(id)
            .map(|layer| layer.mask.is_some() || layer.mask_file.is_some())
            .unwrap_or(false)
    }

    // -------------------------------------------------------------- painting

    fn stroke_settings(&self) -> paint::StrokeSettings {
        let brush = self.brush.clamped();
        let eraser = self.tool() == Tool::Eraser;
        // A mask is painted in gray: the brush lays down the color's luminance and the eraser hides,
        // so neither of them punches a hole in the buffer the way an alpha erase would.
        let color = if self.mask_painting {
            let gray = if eraser { 0 } else { paint::mask_gray(self.color) };
            [gray, gray, gray, 255]
        } else {
            self.color
        };
        paint::StrokeSettings {
            size: brush.size,
            hardness: brush.hardness,
            opacity: brush.opacity,
            color,
            erase: eraser && !self.mask_painting,
        }
    }

    /// The placement and pixel grid a stroke paints into: the layer's own, or its mask's.
    fn stroke_grid(&self, layer_id: Uuid, mask: bool) -> Option<(comp_core::geom::Transform, (u32, u32))> {
        let layer = self.document.layer(layer_id)?;
        if mask {
            let mask = layer.mask.as_deref()?;
            if !layer.mask_enabled {
                return None;
            }
            let transform = layer.effective_mask_transform().unwrap_or(layer.transform);
            Some((transform, (mask.width(), mask.height())))
        } else {
            let image = layer.image.as_deref()?;
            Some((layer.transform, (image.width(), image.height())))
        }
    }

    /// Maps a document point onto the pixel grid a stroke paints into.
    fn grid_pixels(&self, layer_id: Uuid, mask: bool, point: Pos2) -> Option<(f32, f32)> {
        let (transform, dims) = self.stroke_grid(layer_id, mask)?;
        let inverse = transform.affine().inverse()?;
        let layer_box = (transform.size.width as f32, transform.size.height as f32);
        if layer_box.0 <= 0.0 || layer_box.1 <= 0.0 || dims.0 == 0 || dims.1 == 0 {
            return None;
        }
        Some(to_layer_pixels(
            PointF::new(point.x as f64, point.y as f64),
            inverse,
            layer_box,
            dims.0 as f32,
            dims.1 as f32,
        ))
    }

    /// The pixel size of a layer's own bitmap.
    fn layer_image_size(&self, layer_id: Uuid) -> Option<(u32, u32)> {
        let image = self.document.layer(layer_id)?.image.as_deref()?;
        Some((image.width(), image.height()))
    }

    /// Starts a stroke on the selected layer at a document point. A raster layer with no pixels yet
    /// gets a canvas-sized image so that a new layer can be painted on straight away.
    ///
    /// The brush is validated here, so a refused setting is reported once instead of on every
    /// pointer sample.
    pub fn begin_stroke(&mut self, start: Pos2) -> bool {
        let Some(layer_id) = self.paintable_layer() else {
            self.set_error("Select a raster layer to paint on");
            return false;
        };
        let (width, height) = (self.document.width, self.document.height);
        let before = self.document.clone();
        let paint_mask = self.mask_painting;
        if !paint_mask {
            // A raster layer with no pixels yet gets a canvas-sized image so it can be painted.
            let needs_image = self.document.layer(layer_id).map(|layer| layer.image.is_none()).unwrap_or(false);
            if needs_image {
                if let Some(layer) = self.document.layer_mut(layer_id) {
                    layer.image = Some(Arc::new(Bitmap8::new(width, height)));
                    layer.image_file = Some(layer.expected_image_file());
                }
            }
        }
        let target = if paint_mask {
            match self.document.layer(layer_id) {
                Some(layer) if layer.mask.is_some() && !layer.mask_enabled => {
                    self.set_error("The layer's mask is off; turn it on to paint it");
                    return false;
                }
                Some(layer) => match layer.mask.as_deref() {
                    Some(mask) => StrokeTarget::Mask { scratch: paint::mask_to_scratch(mask) },
                    None => {
                        self.set_error("This layer has no mask to paint; add one first");
                        return false;
                    }
                },
                None => return false,
            }
        } else {
            StrokeTarget::Image
        };
        let Some((_transform, dims)) = self.stroke_grid(layer_id, paint_mask) else {
            self.set_error("The selected layer has no pixel buffer");
            return false;
        };
        let Some(start_pixels) = self.grid_pixels(layer_id, paint_mask, start) else {
            self.set_error("The selected layer has no usable transform");
            return false;
        };
        let clip = self.selection.and_then(|selection| {
            let min = self.grid_pixels(layer_id, paint_mask, selection.min)?;
            let max = self.grid_pixels(layer_id, paint_mask, selection.max)?;
            paint::selection_mask(dims.0, dims.1, min, max)
        });
        let settings = self.stroke_settings();
        let engine = match settings.engine(self.view.zoom) {
            Ok(engine) => engine,
            Err(message) => {
                self.set_error(message);
                return false;
            }
        };
        let stroke = match paint::Stroke::begin(&engine, PointF::new(start_pixels.0 as f64, start_pixels.1 as f64)) {
            Ok(stroke) => stroke,
            Err(message) => {
                self.set_error(message);
                return false;
            }
        };
        self.stroke = Some(StrokeSession {
            layer: layer_id,
            before,
            stroke,
            clip,
            target,
            changed: false,
            label: if paint_mask { "Paint Mask" } else if settings.erase { "Erase" } else { "Brush Stroke" },
        });
        true
    }

    /// Appends a pointer sample in document space and paints what it added.
    pub fn stroke_to(&mut self, to: Pos2) -> bool {
        let Some((layer_id, painting_mask)) =
            self.stroke.as_ref().map(|session| (session.layer, session.target.is_mask()))
        else {
            return false;
        };
        let Some(pixels) = self.grid_pixels(layer_id, painting_mask, to) else { return false };
        let (painted, error, dirty) = {
            let Some(session) = self.stroke.as_mut() else { return false };
            let StrokeSession { stroke, clip, changed, target, .. } = session;
            let buffer = match target {
                StrokeTarget::Mask { scratch } => scratch,
                StrokeTarget::Image => match self
                    .document
                    .layer_mut(layer_id)
                    .and_then(|layer| layer.image.as_mut())
                    .map(Arc::make_mut)
                {
                    Some(image) => image,
                    None => return false,
                },
            };
            let progress = stroke.extend(buffer, PointF::new(pixels.0 as f64, pixels.1 as f64), clip.as_ref());
            if progress.changed {
                *changed = true;
            }
            (progress.changed, stroke.error(), progress.bounds)
        };
        if let Some(message) = error {
            self.set_error(message);
        }
        if painted {
            self.epoch += 1;
            if let Some(bounds) = dirty.and_then(|bounds| self.layer_rect_to_document(layer_id, painting_mask, bounds)) {
                self.dirty = engine::union_bounds(self.dirty, bounds);
            }
        }
        painted
    }

    /// The canvas rectangle an in-flight stroke changed since the last render request.
    ///
    /// Taking it clears it, so one repaint request covers everything painted since the last one.
    pub fn take_dirty(&mut self) -> Option<engine::Bounds> {
        self.dirty.take()
    }

    /// Maps a rectangle of a layer's own bitmap into canvas pixels.
    ///
    /// A rotated or flipped placement is boxed by its corners, so the result is a superset of the
    /// pixels the rectangle covers, which is all a dirty rectangle has to be.
    fn layer_rect_to_document(&self, layer_id: Uuid, mask: bool, bounds: engine::Bounds) -> Option<engine::Bounds> {
        let (transform, dims) = self.stroke_grid(layer_id, mask)?;
        let (image_width, image_height) = (dims.0 as f64, dims.1 as f64);
        let (box_width, box_height) = (transform.size.width, transform.size.height);
        if image_width <= 0.0 || image_height <= 0.0 || box_width <= 0.0 || box_height <= 0.0 {
            return None;
        }
        let affine = transform.affine();
        let right = bounds.0 + bounds.2 as i64;
        let bottom = bounds.1 + bounds.3 as i64;
        let mut min_x = f64::INFINITY;
        let mut min_y = f64::INFINITY;
        let mut max_x = f64::NEG_INFINITY;
        let mut max_y = f64::NEG_INFINITY;
        for (x, y) in [(bounds.0, bounds.1), (right, bounds.1), (bounds.0, bottom), (right, bottom)] {
            let local = PointF::new(x as f64 / image_width * box_width, y as f64 / image_height * box_height);
            let point = affine.apply(local);
            min_x = min_x.min(point.x);
            min_y = min_y.min(point.y);
            max_x = max_x.max(point.x);
            max_y = max_y.max(point.y);
        }
        if !min_x.is_finite() || !min_y.is_finite() || !max_x.is_finite() || !max_y.is_finite() {
            return None;
        }
        // One pixel of slack covers the antialiased edge the engine reports inclusively.
        let x0 = min_x.floor() as i64 - 1;
        let y0 = min_y.floor() as i64 - 1;
        let x1 = max_x.ceil() as i64 + 1;
        let y1 = max_y.ceil() as i64 + 1;
        Some((x0, y0, (x1 - x0).max(1) as u32, (y1 - y0).max(1) as u32))
    }

    /// Ends the stroke and records it as one undo step.
    ///
    /// The engine needs the target even when nothing has been painted yet, because a click that
    /// never moved still has its single dab to lay.
    pub fn end_stroke(&mut self) -> bool {
        self.dirty = None;
        let Some(session) = self.stroke.take() else { return false };
        let StrokeSession { layer, before, stroke, clip, changed, mut target, label } = session;
        let mut painted = changed;
        let mut dabs = stroke.dabs();
        if let Some(scratch) = target.scratch_mut() {
            // A mask stroke lands back in the document as a mask, and keeps its id and file name.
            let progress = stroke.finish(scratch, clip.as_ref());
            painted |= progress.changed;
            dabs = progress.dabs;
            self.document.set_layer_mask(layer, paint::scratch_to_mask(scratch));
        } else if let Some(image) = self
            .document
            .layer_mut(layer)
            .and_then(|layer| layer.image.as_mut())
            .map(Arc::make_mut)
        {
            let progress = stroke.finish(image, clip.as_ref());
            painted |= progress.changed;
            dabs = progress.dabs;
        }
        if !painted {
            return false;
        }
        // The pre-stroke document may have had no image on the layer at all, which the undo must
        // restore, so the snapshot is recorded verbatim.
        self.history.record(before, label);
        self.epoch += 1;
        self.set_message(format!("{label}: {dabs} dab(s)"));
        true
    }

    /// Throws the stroke away, for Escape or a lost pointer.
    pub fn cancel_stroke(&mut self) -> bool {
        self.dirty = None;
        let Some(session) = self.stroke.take() else { return false };
        if session.changed {
            self.document = session.before;
            self.epoch += 1;
        }
        true
    }

    pub fn is_stroking(&self) -> bool {
        self.stroke.is_some()
    }

    /// Samples the flattened composite, which is what the eyedropper shows on screen.
    pub fn pick_color(&self, flattened: &Bitmap8, at: Pos2) -> Option<[u8; 4]> {
        let (x, y) = (at.x.floor(), at.y.floor());
        if x < 0.0 || y < 0.0 || x >= flattened.width() as f32 || y >= flattened.height() as f32 {
            return None;
        }
        Some(flattened.get(x as u32, y as u32))
    }

    // -------------------------------------------------------------- selection

    pub fn set_selection(&mut self, rect: Rect) {
        let bounds = Rect::from_min_max(Pos2::ZERO, Pos2::new(self.document.width as f32, self.document.height as f32));
        let clipped = rect.intersect(bounds);
        // A click with the marquee selects nothing rather than a zero-area region.
        self.selection = if clipped.width() < 1.0 || clipped.height() < 1.0 { None } else { Some(clipped) };
    }

    pub fn select_all(&mut self) {
        self.selection = Some(Rect::from_min_max(
            Pos2::ZERO,
            Pos2::new(self.document.width as f32, self.document.height as f32),
        ));
    }

    pub fn deselect(&mut self) {
        self.selection = None;
    }

    // ----------------------------------------------------------------- status

    pub fn memory_estimate(&self) -> MemoryEstimate {
        let (images, masks) = self.document.pixel_counts();
        MemoryEstimate {
            document_bytes: images * 4 + masks,
            history_bytes: self.history.history_bytes() as u64,
        }
    }

    /// Flattens the document with the shared compositor, as the canvas shows it.
    pub fn flattened(&self) -> Bitmap8 {
        engine::flatten_document(&self.document)
    }
}

/// Maps a document point onto the pixel grid of a layer's own bitmap.
fn to_layer_pixels(
    point: PointF,
    inverse: comp_core::geom::Affine,
    layer_box: (f32, f32),
    image_width: f32,
    image_height: f32,
) -> (f32, f32) {
    let local = inverse.apply(point);
    (
        local.x as f32 / layer_box.0 * image_width,
        local.y as f32 / layer_box.1 * image_height,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use comp_core::bitmap::Gray8;

    fn editor_with(width: u32, height: u32) -> Editor {
        Editor::with_document(Document::with_background(width, height))
    }

    fn active_layer(editor: &Editor) -> Uuid {
        editor.document.active_layer.expect("a layer should be selected")
    }

    /// What the history must do about one entry that changes the document.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    enum Coverage {
        /// The call records exactly one step on its own.
        OneStep,
        /// The call joins the gesture around it: many calls inside one begin_edit are one step.
        JoinsGesture,
        /// Nothing is recorded, and this is the reason.
        NoHistory(&'static str),
    }

    /// One way of changing the document: its name, what the history should do, the state it needs and
    /// the change itself.
    type Entry = (&'static str, Coverage, fn(&mut Editor), fn(&mut Editor));

    /// Every entry point that changes the document, as data.
    ///
    /// The audit this table exists for: an entry that forgets to record a step, or that records one
    /// while a drag is still running, fails here rather than in a user's hands. A new entry point
    /// belongs in this list.
    fn document_entries() -> Vec<Entry> {
        use comp_core::adjustment::AdjustmentKind;
        use comp_core::geom::GuideAxis;

        // Setups: each leaves the document in a state where its entry has something to do.
        fn one_layer(editor: &mut Editor) {
            let _ = editor.add_layer();
        }
        fn two_layers(editor: &mut Editor) {
            let _ = editor.add_layer();
            let _ = editor.add_layer();
            editor.select_layer(editor.document.active_layer.expect("a layer"));
        }
        fn painted_layer(editor: &mut Editor) {
            let _ = editor.add_layer();
            let id = editor.document.active_layer.expect("a layer");
            let _ = editor.replace_layer_pixels(id, Bitmap8::filled(16, 16, [200, 120, 40, 255]));
        }
        fn masked_layer(editor: &mut Editor) {
            painted_layer(editor);
            let id = editor.document.active_layer.expect("a layer");
            let _ = editor.add_layer_mask(id, false);
            // A mask with an edge in it, so that feathering it has something to soften.
            let _ = editor.fill_mask_gradient(
                crate::maskfill::GradientShape::Linear,
                comp_core::PointF::new(0.0, 0.0),
                comp_core::PointF::new(16.0, 16.0),
                false,
                crate::maskfill::GradientBlend::Replace,
            );
        }
        fn adjustment_layer(editor: &mut Editor) {
            let _ = editor.add_adjustment_layer(AdjustmentKind::HueSaturation);
        }
        fn effect_layer(editor: &mut Editor) {
            let _ = editor.add_layer();
            let id = editor.document.active_layer.expect("a layer");
            let _ = editor.update_effects(id, |effects| {
                effects.shadow = Some(Default::default());
            });
        }
        fn guide(editor: &mut Editor) {
            let _ = editor.add_guide(GuideAxis::Vertical, 8.0);
        }
        fn text_layer(editor: &mut Editor) {
            let mut library = comp_text::FontLibrary::from_faces(Vec::new(), Vec::new());
            let style = comp_core::text::TextStyle { content: "hi".to_string(), font_size: 12.0, ..Default::default() };
            let _ = editor.add_text_layer(Pos2::new(1.0, 1.0), style, &mut library);
        }

        vec![
            // Layers.
            ("add_layer", Coverage::OneStep, one_layer, |editor| assert!(editor.add_layer())),
            ("duplicate_active", Coverage::OneStep, painted_layer, |editor| {
                assert!(editor.duplicate_active())
            }),
            ("delete_active", Coverage::OneStep, two_layers, |editor| assert!(editor.delete_active())),
            ("merge_down", Coverage::OneStep, painted_layer, |editor| assert!(editor.merge_down())),
            ("flatten_image", Coverage::OneStep, painted_layer, |editor| assert!(editor.flatten_image())),
            ("move_active_layer", Coverage::OneStep, two_layers, |editor| {
                assert!(editor.move_active_layer(-1))
            }),
            ("move_layer_to", Coverage::OneStep, two_layers, |editor| {
                let id = editor.document.active_layer.expect("a layer");
                let destination = editor.document.layers[0].id;
                let _ = destination;
                assert!(editor.move_layer_to(id, crate::reorder::placement_bottom()))
            }),
            // Layer properties.
            ("set_opacity", Coverage::OneStep, painted_layer, |editor| {
                let id = editor.document.active_layer.expect("a layer");
                assert!(editor.set_opacity(id, 0.4))
            }),
            ("set_blend", Coverage::OneStep, painted_layer, |editor| {
                let id = editor.document.active_layer.expect("a layer");
                assert!(editor.set_blend(id, BlendMode::Multiply))
            }),
            ("set_visibility", Coverage::OneStep, painted_layer, |editor| {
                let id = editor.document.active_layer.expect("a layer");
                assert!(editor.set_visibility(id, false))
            }),
            ("set_name", Coverage::OneStep, painted_layer, |editor| {
                let id = editor.document.active_layer.expect("a layer");
                assert!(editor.set_name(id, "Renamed".to_string()))
            }),
            ("translate_layer", Coverage::OneStep, painted_layer, |editor| {
                let id = editor.document.active_layer.expect("a layer");
                assert!(editor.translate_layer(id, Vec2::new(2.0, 3.0)))
            }),
            ("replace_layer_pixels", Coverage::OneStep, painted_layer, |editor| {
                let id = editor.document.active_layer.expect("a layer");
                assert!(editor.replace_layer_pixels(id, Bitmap8::filled(16, 16, [40, 90, 160, 255])))
            }),
            // Adjustment layers and effects.
            ("add_adjustment_layer", Coverage::OneStep, one_layer, |editor| {
                assert!(editor.add_adjustment_layer(AdjustmentKind::Grain))
            }),
            ("update_adjustment", Coverage::OneStep, adjustment_layer, |editor| {
                let id = editor.document.active_layer.expect("a layer");
                assert!(editor.update_adjustment(id, |adjustment| adjustment.hue = 30.0))
            }),
            ("update_effects", Coverage::OneStep, effect_layer, |editor| {
                let id = editor.document.active_layer.expect("a layer");
                assert!(editor.update_effects(id, |effects| {
                    if let Some(shadow) = effects.shadow.as_mut() {
                        shadow.opacity = 0.2;
                    }
                }))
            }),
            ("clear_effects", Coverage::OneStep, effect_layer, |editor| {
                let id = editor.document.active_layer.expect("a layer");
                assert!(editor.clear_effects(id))
            }),
            // Masks.
            ("add_layer_mask", Coverage::OneStep, painted_layer, |editor| {
                let id = editor.document.active_layer.expect("a layer");
                assert!(editor.add_layer_mask(id, false))
            }),
            ("remove_layer_mask", Coverage::OneStep, masked_layer, |editor| {
                let id = editor.document.active_layer.expect("a layer");
                assert!(editor.remove_layer_mask(id))
            }),
            ("set_mask_enabled", Coverage::OneStep, masked_layer, |editor| {
                let id = editor.document.active_layer.expect("a layer");
                assert!(editor.set_mask_enabled(id, false))
            }),
            ("fill_mask_gradient", Coverage::OneStep, masked_layer, |editor| {
                // A different gradient from the one the setup laid down, so this really changes it.
                assert!(editor.fill_mask_gradient(
                    crate::maskfill::GradientShape::Radial,
                    comp_core::PointF::new(8.0, 8.0),
                    comp_core::PointF::new(16.0, 8.0),
                    true,
                    crate::maskfill::GradientBlend::Subtract,
                ))
            }),
            ("feather_mask", Coverage::OneStep, masked_layer, |editor| {
                assert!(editor.feather_mask(2.0))
            }),
            // The subject commands take a matte and put it on the layer; which extractor produced the
            // matte is the window's business, and it is the window that reports who answered.
            ("apply_subject_matte", Coverage::OneStep, painted_layer, |editor| {
                let id = editor.document.active_layer.expect("a layer");
                let matte = Gray8::filled(16, 16, 200);
                assert!(editor.apply_subject_matte(id, &matte, "Select Subject").is_ok())
            }),
            ("apply_background_cut", Coverage::OneStep, painted_layer, |editor| {
                let id = editor.document.active_layer.expect("a layer");
                let image = editor.document.layer(id).and_then(|layer| layer.image.clone()).expect("pixels");
                let matte = Gray8::filled(16, 16, 200);
                assert!(editor.apply_background_cut(id, &image, &matte, "Remove Background").is_ok())
            }),
            // Guides.
            ("add_guide", Coverage::OneStep, one_layer, |editor| {
                assert!(editor.add_guide(GuideAxis::Horizontal, 4.0).is_some())
            }),
            ("move_guide", Coverage::OneStep, guide, |editor| {
                let id = editor.guides()[0].id;
                assert!(editor.move_guide(id, 11.0))
            }),
            ("remove_guide", Coverage::OneStep, guide, |editor| {
                let id = editor.guides()[0].id;
                assert!(editor.remove_guide(id))
            }),
            ("clear_guides", Coverage::OneStep, guide, |editor| assert!(editor.clear_guides())),
            // Text.
            ("add_text_layer", Coverage::OneStep, one_layer, |editor| {
                let mut library = comp_text::FontLibrary::from_faces(Vec::new(), Vec::new());
                let style = comp_core::text::TextStyle { content: "hi".to_string(), font_size: 12.0, ..Default::default() };
                assert!(editor.add_text_layer(Pos2::new(1.0, 1.0), style, &mut library).is_ok())
            }),
            ("set_text_style", Coverage::OneStep, text_layer, |editor| {
                let id = editor.document.active_layer.expect("a layer");
                let mut style = editor.text_style(id).expect("a style");
                style.font_size += 2.0;
                assert!(editor.set_text_style(id, style))
            }),
            ("commit_text", Coverage::OneStep, text_layer, |editor| {
                let id = editor.document.active_layer.expect("a layer");
                let mut library = comp_text::FontLibrary::from_faces(Vec::new(), Vec::new());
                assert!(editor.commit_text(id, &mut library).is_ok())
            }),
            // Gestures: these are called once per frame, so the panel wraps them and the whole drag is
            // one step. The same table drives a stroke, which records its own step at the end.
            ("stroke", Coverage::OneStep, painted_layer, |editor| {
                editor.brush = BrushSettings { size: 5.0, hardness: 1.0, opacity: 1.0 }.clamped();
                assert!(editor.begin_stroke(Pos2::new(2.0, 2.0)));
                assert!(editor.stroke_to(Pos2::new(9.0, 9.0)));
                assert!(editor.end_stroke());
            }),
            ("move_guide in a drag", Coverage::JoinsGesture, guide, |editor| {
                let id = editor.guides()[0].id;
                assert!(editor.move_guide(id, 12.0));
                assert!(editor.move_guide(id, 13.0));
                assert!(editor.move_guide(id, 14.0));
            }),
            ("set_opacity in a drag", Coverage::JoinsGesture, painted_layer, |editor| {
                let id = editor.document.active_layer.expect("a layer");
                assert!(editor.set_opacity(id, 0.7));
                assert!(editor.set_opacity(id, 0.6));
                assert!(editor.set_opacity(id, 0.5));
            }),
            ("update_adjustment in a drag", Coverage::JoinsGesture, adjustment_layer, |editor| {
                let id = editor.document.active_layer.expect("a layer");
                assert!(editor.update_adjustment(id, |adjustment| adjustment.hue = 10.0));
                assert!(editor.update_adjustment(id, |adjustment| adjustment.hue = 20.0));
                assert!(editor.update_adjustment(id, |adjustment| adjustment.hue = 30.0));
            }),
            ("update_effects in a drag", Coverage::JoinsGesture, effect_layer, |editor| {
                let id = editor.document.active_layer.expect("a layer");
                for opacity in [0.6, 0.4, 0.2] {
                    assert!(editor.update_effects(id, |effects| {
                        if let Some(shadow) = effects.shadow.as_mut() {
                            shadow.opacity = opacity;
                        }
                    }));
                }
            }),
            // View state: not the document, so not in the history, and the reason says why.
            (
                "set_tool",
                Coverage::NoHistory("the tool is a view setting, not part of the document"),
                one_layer,
                |editor| editor.set_tool(crate::tools::Tool::Eraser),
            ),
            (
                "select_all",
                Coverage::NoHistory("the selection is not saved in the package"),
                one_layer,
                |editor| editor.select_all(),
            ),
            (
                "deselect",
                Coverage::NoHistory("the selection is not saved in the package"),
                one_layer,
                |editor| editor.deselect(),
            ),
            (
                "set_selection",
                Coverage::NoHistory("the selection is not saved in the package"),
                one_layer,
                |editor| editor.set_selection(egui::Rect::from_min_size(Pos2::ZERO, Vec2::new(4.0, 4.0))),
            ),
            (
                "set_message",
                Coverage::NoHistory("the status line is not part of the document"),
                one_layer,
                |editor| editor.set_message("a note"),
            ),
        ]
    }

    fn steps(editor: &Editor) -> usize {
        editor.can_undo() as usize + 0
    }

    #[test]
    fn every_entry_that_changes_the_document_records_history() {
        for (name, coverage, setup, run) in document_entries() {
            let mut editor = editor_with(16, 16);
            setup(&mut editor);
            let before = editor.history.depth().0;
            match coverage {
                Coverage::OneStep => {
                    run(&mut editor);
                    assert_eq!(
                        editor.history.depth().0,
                        before + 1,
                        "{name}: an entry has to record exactly one step"
                    );
                }
                Coverage::JoinsGesture => {
                    // What a panel does: wrap the frames of a drag, then close it once.
                    editor.begin_edit("Gesture");
                    run(&mut editor);
                    editor.finish_edit();
                    assert_eq!(
                        editor.history.depth().0,
                        before + 1,
                        "{name}: a gesture has to be one step, however many frames it ran for"
                    );
                }
                Coverage::NoHistory(reason) => {
                    run(&mut editor);
                    assert_eq!(
                        editor.history.depth().0,
                        before,
                        "{name}: this records nothing because {reason}"
                    );
                }
            }
            // Whatever the entry was, the document it left behind has to undo back to the start.
            let undone = editor.undo();
            assert_eq!(
                undone,
                coverage != Coverage::NoHistory(""),
                "{name}: undo should {} be possible",
                if coverage == Coverage::NoHistory("") { "not" } else { "" }
            );
            assert_eq!(editor.history.depth().1, undone as usize, "{name}: redo follows undo");
        }
        assert_eq!(steps(&editor_with(8, 8)), 0, "a fresh document has nothing to undo");
    }

    #[test]
    fn an_edit_after_an_undo_clears_the_redo_stack() {
        let mut editor = editor_with(8, 8);
        assert!(editor.add_layer());
        assert!(editor.add_layer());
        assert!(editor.undo(), "the second layer can be undone");
        assert!(editor.can_redo(), "and redone while nothing else has happened");
        assert_eq!(editor.history.depth().1, 1);
        // A new edit after an undo throws the redo away: the timeline has moved on.
        let id = editor.document.active_layer.expect("a layer");
        assert!(editor.set_opacity(id, 0.5));
        assert!(!editor.can_redo(), "a new edit must clear the redo stack");
        assert_eq!(editor.history.depth().1, 0, "and leave nothing to redo");
        assert_eq!(editor.undo_label(), Some("Layer Opacity"));
    }

    #[test]
    fn the_opacity_digit_is_the_tens_of_a_percentage() {
        assert_eq!(Editor::opacity_for_digit(5), 0.5);
        assert_eq!(Editor::opacity_for_digit(9), 0.9);
        assert_eq!(Editor::opacity_for_digit(0), 1.0, "zero is a full hundred");
        assert_eq!(Editor::opacity_for_digit(42), 0.9, "nothing above nine is reachable, but it is clamped");
    }

    #[test]
    fn stepping_the_blend_mode_walks_the_list_and_wraps() {
        let mut editor = editor_with(8, 8);
        let id = active_layer(&editor);
        let first = editor.document.layer(id).expect("a layer").blend;
        let second = BlendMode::ALL[1];
        assert_eq!(editor.cycle_blend_mode(id, 1), Some(second.as_str()));
        assert_eq!(editor.document.layer(id).expect("a layer").blend, second);
        // A full turn comes back to where it started, in both directions.
        for _ in 1..BlendMode::ALL.len() {
            editor.cycle_blend_mode(id, 1);
        }
        assert_eq!(editor.document.layer(id).expect("a layer").blend, first);
        assert_eq!(editor.cycle_blend_mode(id, -1), Some(BlendMode::ALL[BlendMode::ALL.len() - 1].as_str()));
    }

    #[test]
    fn a_new_session_starts_unmodified_and_turns_modified_after_an_edit() {
        let mut editor = editor_with(8, 8);
        assert!(!editor.is_modified());
        assert_eq!(editor.title(), "Untitled.comp - Compositor");
        editor.add_layer();
        assert!(editor.is_modified());
        assert!(editor.title().starts_with("Untitled.comp *"));
    }

    #[test]
    fn undo_and_redo_move_the_document_and_the_dirty_flag() {
        let mut editor = editor_with(8, 8);
        let before = editor.document.layers.len();
        editor.add_layer();
        assert_eq!(editor.document.layers.len(), before + 1);
        assert_eq!(editor.undo_label(), Some("New Layer"));
        assert!(editor.undo());
        assert_eq!(editor.document.layers.len(), before);
        assert!(!editor.can_undo());
        assert!(editor.can_redo());
        // Undoing back to the save point is a clean document again.
        assert!(!editor.is_modified());
        assert_eq!(editor.redo_label(), Some("New Layer"));
        assert!(editor.redo());
        assert_eq!(editor.document.layers.len(), before + 1);
        assert!(editor.is_modified());
    }

    #[test]
    fn every_layer_command_records_exactly_one_step() {
        let mut editor = editor_with(16, 16);
        editor.add_layer();
        let id = active_layer(&editor);
        editor.select_layer(id);

        editor.begin_edit("Layer Opacity");
        for step in 0..10 {
            editor.set_opacity(id, step as f64 / 10.0);
        }
        editor.finish_edit();
        assert_eq!(editor.undo_label(), Some("Layer Opacity"));
        let (undo_depth, _) = editor.history.depth();
        assert_eq!(undo_depth, 2, "a slider drag must be a single step");
        assert!((editor.document.layer(id).unwrap().opacity - 0.9).abs() < 1e-9);

        editor.select_layer(id);
        assert!(editor.duplicate_active());
        assert_eq!(editor.undo_label(), Some("Duplicate Layer"));
        assert!(editor.delete_active());
        assert_eq!(editor.undo_label(), Some("Delete Layer"));
    }

    #[test]
    fn a_layer_edit_that_changes_nothing_records_no_step() {
        let mut editor = editor_with(8, 8);
        let id = active_layer(&editor);
        let depth = editor.history.depth().0;
        assert!(!editor.set_opacity(id, 1.0));
        assert!(!editor.set_visibility(id, true));
        assert!(!editor.set_blend(id, BlendMode::Normal));
        assert!(!editor.set_name(id, editor.document.layer(id).unwrap().name.clone()));
        editor.finish_edit();
        assert_eq!(editor.history.depth().0, depth);
    }

    #[test]
    fn moving_a_layer_swaps_it_with_its_sibling() {
        let mut editor = editor_with(8, 8);
        let bottom = active_layer(&editor);
        editor.add_layer();
        let middle = active_layer(&editor);
        editor.add_layer();
        let top = active_layer(&editor);
        let order = |editor: &Editor| -> Vec<Uuid> { editor.document.roots().iter().map(|layer| layer.id).collect() };
        assert_eq!(order(&editor), vec![bottom, middle, top]);

        editor.select_layer(middle);
        assert!(editor.move_active_layer(-1));
        assert_eq!(order(&editor), vec![middle, bottom, top]);
        assert!(!editor.move_active_layer(-1), "it is already at the bottom");
        assert!(editor.move_active_layer(1));
        assert_eq!(order(&editor), vec![bottom, middle, top]);

        editor.select_layer(top);
        assert!(!editor.move_active_layer(1), "the top layer cannot move up");
        // A refused move records no step, so the label still names the last real one.
        assert_eq!(editor.undo_label(), Some("Move Layer Up"));
    }

    #[test]
    fn a_group_moves_together_with_its_children() {
        let mut editor = editor_with(8, 8);
        let bottom = active_layer(&editor);
        let group = Layer::group("Folder", 8, 8);
        let group_id = group.id;
        editor.document.add_layer(group, None);
        let child = editor.document.add_layer(Layer::raster("Child", 8, 8), Some(group_id));
        editor.select_layer(group_id);

        assert!(editor.move_active_layer(-1));
        let roots: Vec<Uuid> = editor.document.roots().iter().map(|layer| layer.id).collect();
        assert_eq!(roots, vec![group_id, bottom]);
        assert_eq!(editor.document.layers.len(), 3);
        assert_eq!(editor.document.index_of(child), Some(editor.document.index_of(group_id).unwrap() + 1));
        assert!(!editor.move_active_layer(-1), "the folder is already at the bottom");
    }

    #[test]
    fn duplicating_a_group_copies_its_children_with_fresh_ids() {
        let mut editor = editor_with(8, 8);
        let group = Layer::group("Folder", 8, 8);
        let group_id = group.id;
        editor.document.add_layer(group, None);
        editor.document.add_layer(Layer::raster("Child", 8, 8), Some(group_id));
        editor.select_layer(group_id);
        assert!(editor.duplicate_active());
        let copies: Vec<&Layer> = editor.document.layers.iter().filter(|layer| layer.name == "Folder copy").collect();
        assert_eq!(copies.len(), 1);
        let copy_id = copies[0].id;
        assert_ne!(copy_id, group_id);
        assert_eq!(editor.document.child_indices(Some(copy_id)).len(), 1);
        let child_ids: Vec<Uuid> = editor.document.child_indices(Some(copy_id)).iter().map(|i| editor.document.layers[*i].id).collect();
        assert_ne!(child_ids[0], editor.document.layers[1].id);
        assert_eq!(editor.document.subtree_indices(copy_id).len(), 2);
    }

    #[test]
    fn a_stroke_is_one_undo_step_and_undo_restores_the_pixels() {
        let mut editor = editor_with(32, 32);
        let id = active_layer(&editor);
        editor.brush.size = 10.0;
        editor.color = [255, 0, 0, 255];
        assert!(editor.begin_stroke(Pos2::new(8.0, 8.0)));
        assert!(editor.stroke_to(Pos2::new(24.0, 8.0)));
        assert!(editor.is_stroking());
        assert!(editor.end_stroke());
        assert_eq!(editor.undo_label(), Some("Brush Stroke"));
        assert_eq!(editor.document.layer(id).unwrap().image.as_ref().unwrap().get(16, 8), [255, 0, 0, 255]);
        assert!(editor.undo());
        assert_eq!(editor.document.layer(id).unwrap().image.as_ref().unwrap().get(16, 8), [0, 0, 0, 0]);
        assert!(editor.redo());
        assert_eq!(editor.document.layer(id).unwrap().image.as_ref().unwrap().get(16, 8), [255, 0, 0, 255]);
    }

    #[test]
    fn adopting_an_imported_document_forgets_the_package_path() {
        let mut editor = editor_with(8, 8);
        editor.path = Some(std::path::PathBuf::from("somewhere/Old.comp"));
        editor.adopt_imported(comp_core::store::solid_document(5, 5, [1, 2, 3, 255]));
        assert_eq!(editor.document_size(), (5, 5));
        assert!(editor.path.is_none(), "an import has no package to save back to");
        assert!(!editor.is_modified());
    }

    #[test]
    fn replacing_the_document_is_one_undo_step() {
        let mut editor = editor_with(8, 8);
        let mut imported = editor.document.clone();
        imported.add_layer(Layer::with_image("Imported", Bitmap8::filled(4, 4, [9, 9, 9, 255])), None);
        assert!(editor.replace_document(imported, "Import Layer"));
        assert_eq!(editor.document.layers.len(), 2);
        assert_eq!(editor.undo_label(), Some("Import Layer"));
        assert!(editor.undo());
        assert_eq!(editor.document.layers.len(), 1);
        assert!(!editor.replace_document(editor.document.clone(), "Import Layer"), "no change, no step");
    }

    #[test]
    fn a_gradient_fills_the_mask_and_undoes_in_one_step() {
        use comp_core::PointF;
        use crate::maskfill::{GradientBlend, GradientShape};
        let mut editor = editor_with(16, 16);
        let id = active_layer(&editor);
        assert!(editor.add_layer_mask(id, false), "the layer takes a mask");

        assert!(editor.fill_mask_gradient(GradientShape::Linear, PointF::new(0.0, 0.0), PointF::new(16.0, 0.0), false, GradientBlend::Replace));
        let mask = editor.document.layer(id).unwrap().mask.clone().unwrap();
        assert_eq!((mask.width(), mask.height()), (16, 16), "the fill covers the whole mask");
        assert!(mask.get(0, 8) < 40, "the start of the drag is black: {}", mask.get(0, 8));
        assert!(mask.get(15, 8) > 215, "the end is white: {}", mask.get(15, 8));
        assert!(mask.get(8, 8) > mask.get(4, 8), "and it ramps in between");

        assert_eq!(editor.undo_label(), Some("Linear"));
        assert!(editor.undo());
        let restored = editor.document.layer(id).unwrap().mask.clone().unwrap();
        assert_eq!(restored.get(0, 8), 255, "the white mask is back");

        // A gradient that changes nothing records nothing: the mask is already this ramp.
        assert!(
            !editor.fill_mask_gradient(
                GradientShape::Linear,
                PointF::new(0.0, 0.0),
                PointF::new(16.0, 0.0),
                false,
                GradientBlend::Add,
            ),
            "adding a ramp the mask already covers is not a change"
        );

        // Adding lightens only: on a flat mid-gray mask the dark half of the ramp cannot darken it.
        assert!(editor.replace_mask_for_test(id, Gray8::filled(16, 16, 128)));
        assert!(editor.fill_mask_gradient(
            GradientShape::Linear,
            PointF::new(16.0, 0.0),
            PointF::new(0.0, 0.0),
            false,
            GradientBlend::Add,
        ));
        // The drag runs from x=16 to x=0, so its white end is at the left.
        let added = editor.document.layer(id).unwrap().mask.clone().unwrap();
        assert_eq!(added.get(15, 8), 128, "the ramp is black there, so the mask keeps its gray");
        assert!(added.get(0, 8) > 240, "and where the ramp is white the mask lightens: {}", added.get(0, 8));

        // Subtracting darkens only, which is the same picture the other way round.
        assert!(editor.replace_mask_for_test(id, Gray8::filled(16, 16, 128)));
        assert!(editor.fill_mask_gradient(
            GradientShape::Linear,
            PointF::new(0.0, 0.0),
            PointF::new(16.0, 0.0),
            false,
            GradientBlend::Subtract,
        ));
        let subtracted = editor.document.layer(id).unwrap().mask.clone().unwrap();
        assert_eq!(subtracted.get(15, 8), 128, "the ramp is white there, so the mask keeps its gray");
        assert!(
            subtracted.get(0, 8) < 20,
            "and where the ramp is black the mask darkens: {}",
            subtracted.get(0, 8)
        );

        // Radial and inverted are the same command with different settings.
        assert!(editor.fill_mask_gradient(GradientShape::Radial, PointF::new(8.0, 8.0), PointF::new(16.0, 8.0), true, GradientBlend::Replace));
        let radial = editor.document.layer(id).unwrap().mask.clone().unwrap();
        assert!(radial.get(8, 8) > 215, "inverted, the centre is white");
        assert!(radial.get(0, 8) < 40, "and the far side is black");
    }

    #[test]
    fn the_mask_tools_refuse_a_layer_without_one() {
        use comp_core::PointF;
        use crate::maskfill::{GradientBlend, GradientShape};
        let mut editor = editor_with(8, 8);
        assert!(
            !editor.fill_mask_gradient(GradientShape::Linear, PointF::new(0.0, 0.0), PointF::new(8.0, 0.0), false, GradientBlend::Replace),
            "a layer with no mask cannot be filled"
        );
        assert!(editor.message_is_error);
        assert!(!editor.feather_mask(4.0), "and cannot be feathered");
        assert!(!editor.feather_mask(0.0), "a feather of zero is not a feather");
    }

    #[test]
    fn feathering_softens_the_mask_edge_in_one_step() {
        let mut editor = editor_with(32, 8);
        let id = active_layer(&editor);
        editor.add_layer_mask(id, false);
        let mut hard = Gray8::new(32, 8);
        for y in 0..8 {
            for x in 0..32 {
                hard.set(x, y, if x < 16 { 0 } else { 255 });
            }
        }
        assert!(editor.replace_mask_for_test(id, hard));
        assert!(editor.feather_mask(9.0));
        let softened = editor.document.layer(id).unwrap().mask.clone().unwrap();
        assert!(softened.get(16, 4) > 0 && softened.get(16, 4) < 255, "the edge is a ramp now");
        assert_eq!(softened.get(0, 4), 0, "the far side is untouched");
        assert_eq!(softened.get(31, 4), 255);
        assert_eq!(editor.undo_label(), Some("Feather Mask"));
        assert!(editor.undo());
        assert_eq!(editor.document.layer(id).unwrap().mask.as_ref().unwrap().get(16, 4), 255, "the hard edge is back");
    }

    #[test]
    fn guides_are_added_moved_removed_and_undone() {
        use comp_core::geom::GuideAxis;
        let mut editor = editor_with(64, 48);
        assert!(editor.guides().is_empty());

        let vertical = editor.add_guide(GuideAxis::Vertical, 20.0).expect("a guide");
        let horizontal = editor.add_guide(GuideAxis::Horizontal, 30.0).expect("a guide");
        assert_eq!(editor.guides().len(), 2);
        assert_eq!(editor.undo_label(), Some("Add Guide"));

        // A drag is one step: the caller opens it, the moves piggyback, the caller closes it.
        editor.begin_edit("Move Guide");
        assert!(editor.move_guide(vertical, 22.5));
        assert!(editor.move_guide(vertical, 24.0));
        editor.finish_edit();
        let moved = editor.guides().iter().find(|guide| guide.id == vertical).unwrap();
        assert_eq!(moved.position, 24.0);
        assert!(editor.undo(), "one step undoes the whole drag");
        assert_eq!(editor.guides().iter().find(|guide| guide.id == vertical).unwrap().position, 20.0);

        assert!(editor.remove_guide(horizontal));
        assert_eq!(editor.guides().len(), 1);
        assert!(editor.undo());
        assert_eq!(editor.guides().len(), 2, "the removed guide comes back");

        assert!(editor.clear_guides());
        assert!(editor.guides().is_empty());
        assert!(editor.undo());
        assert_eq!(editor.guides().len(), 2);
    }

    #[test]
    fn a_guide_needs_a_real_position_and_a_move_that_changes_nothing_records_nothing() {
        use comp_core::geom::GuideAxis;
        let mut editor = editor_with(32, 32);
        assert!(editor.add_guide(GuideAxis::Vertical, f64::NAN).is_none());
        assert!(editor.guides().is_empty());

        let id = editor.add_guide(GuideAxis::Vertical, 10.0).unwrap();
        let label = editor.undo_label().map(str::to_string);
        assert!(!editor.move_guide(id, 10.0), "a move to where it already is changes nothing");
        assert!(!editor.move_guide(id, f64::INFINITY));
        assert_eq!(editor.guides()[0].position, 10.0);
        assert_eq!(editor.undo_label().map(str::to_string), label);
        assert!(editor.clear_guides(), "clearing guides that exist is a change");
        assert!(!editor.clear_guides(), "clearing none is not");
    }

    #[test]
    fn clicking_layer_rows_builds_a_selection() {
        use crate::multiselect::ClickKind;
        let mut editor = editor_with(8, 8);
        let bottom = active_layer(&editor);
        editor.add_layer();
        let middle = active_layer(&editor);
        editor.add_layer();
        let top = active_layer(&editor);

        editor.select_layer(bottom);
        assert_eq!(editor.selected, vec![bottom]);
        assert!(editor.is_selected(bottom) && !editor.is_selected(top));

        editor.click_layer(top, ClickKind::Toggle);
        assert_eq!(editor.selected, vec![bottom, top], "control adds without dropping the rest");
        assert_eq!(editor.document.active_layer, Some(top));

        editor.click_layer(bottom, ClickKind::Toggle);
        assert_eq!(editor.selected, vec![top], "control takes a layer back out");
        assert_eq!(editor.document.active_layer, Some(top), "the topmost left stays active");

        editor.click_layer(middle, ClickKind::Extend);
        assert_eq!(editor.selected, vec![middle, top], "shift takes the rows in between");

        editor.click_layer(middle, ClickKind::Replace);
        assert_eq!(editor.selected, vec![middle], "a plain click is one layer again");
    }

    #[test]
    fn deleting_a_selection_removes_every_layer_in_it() {
        let mut editor = editor_with(8, 8);
        let bottom = active_layer(&editor);
        editor.add_layer();
        let middle = active_layer(&editor);
        editor.add_layer();
        let top = active_layer(&editor);
        assert_eq!(editor.document.layers.len(), 3);

        editor.selected = vec![bottom, middle];
        assert!(editor.delete_selection());
        assert_eq!(editor.document.layers.len(), 1);
        assert_eq!(editor.document.layers[0].id, top);
        assert_eq!(editor.selected, vec![top], "the selection falls back to what is left");
        assert!(editor.undo());
        assert_eq!(editor.document.layers.len(), 3, "one step brings them all back");
    }

    #[test]
    fn merging_several_selected_layers_reports_the_right_label() {
        let mut editor = editor_with(8, 8);
        let bottom = active_layer(&editor);
        editor.document.set_layer_image(bottom, Bitmap8::filled(8, 8, [40, 80, 120, 255]));
        editor.add_layer();
        let top = active_layer(&editor);
        editor.document.set_layer_image(top, Bitmap8::filled(8, 8, [10, 10, 10, 128]));
        editor.select_layer(top);
        assert_eq!(editor.merge_label(), "Merge Down");

        editor.selected = vec![bottom, top];
        assert_eq!(editor.merge_label(), "Merge Layers");
        assert!(editor.merge_down());
        assert_eq!(editor.document.layers.len(), 1);
        assert_eq!(editor.undo_label(), Some("Merge Layers"));
        assert_eq!(editor.selected.len(), 1, "the result becomes the selection");
    }

    #[test]
    fn the_clipboard_carries_the_layer_and_the_composite() {
        use crate::clipboard::{Clipboard, MemoryClipboard};
        let mut editor = editor_with(8, 8);
        let id = active_layer(&editor);
        editor.document.set_layer_image(id, Bitmap8::filled(8, 8, [12, 34, 56, 255]));
        let mut clipboard = MemoryClipboard::new();

        editor.copy_layer_to_clipboard(&mut clipboard).expect("the layer copies");
        assert_eq!(clipboard.get_image().unwrap().get(0, 0), [12, 34, 56, 255]);

        editor.copy_merged_to_clipboard(&mut clipboard).expect("the composite copies");
        assert_eq!(clipboard.get_image().unwrap().get(7, 7), [12, 34, 56, 255]);
    }

    #[test]
    fn pasting_puts_the_clipboard_on_the_canvas_as_a_layer() {
        use crate::clipboard::{Clipboard, MemoryClipboard};
        let mut editor = editor_with(16, 16);
        let mut clipboard = MemoryClipboard::new();
        assert!(editor.paste_from_clipboard(&mut clipboard).is_err(), "an empty clipboard says so");

        clipboard.set_image(&Bitmap8::filled(4, 6, [200, 100, 50, 255])).unwrap();
        editor.paste_from_clipboard(&mut clipboard).expect("a paste");
        assert_eq!(editor.document.layers.len(), 2);
        let pasted = editor.document.layers.last().unwrap();
        assert_eq!(pasted.name, "Pasted");
        assert_eq!((pasted.transform.origin.x, pasted.transform.origin.y), (6.0, 5.0), "centered");
        assert_eq!((pasted.transform.size.width, pasted.transform.size.height), (4.0, 6.0));
        assert_eq!(editor.undo_label(), Some("Paste"));
        assert!(editor.undo());
        assert_eq!(editor.document.layers.len(), 1);
    }

    #[test]
    fn copying_a_layer_that_has_no_pixels_is_refused() {
        use crate::clipboard::MemoryClipboard;
        let mut editor = editor_with(8, 8);
        let mut clipboard = MemoryClipboard::new();
        let group = Layer::group("Folder", 8, 8);
        let group_id = group.id;
        editor.document.add_layer(group, None);
        editor.select_layer(group_id);
        let message = editor.copy_layer_to_clipboard(&mut clipboard).unwrap_err();
        assert!(message.contains("raster"), "{message}");
    }

    #[test]
    fn merging_down_is_one_step_and_keeps_what_the_canvas_showed() {
        let mut editor = editor_with(8, 8);
        let bottom = active_layer(&editor);
        editor.document.set_layer_image(bottom, Bitmap8::filled(8, 8, [200, 0, 0, 255]));
        editor.add_layer();
        let top = active_layer(&editor);
        editor.document.set_layer_image(top, Bitmap8::filled(8, 8, [0, 0, 200, 255]));
        let before = editor.flattened();
        assert_eq!(editor.document.layers.len(), 2);

        assert!(editor.merge_down());
        assert_eq!(editor.document.layers.len(), 1, "two layers became one");
        assert_eq!(editor.undo_label(), Some("Merge Down"));
        assert_eq!(
            editor.flattened().pixels(),
            before.pixels(),
            "the merge keeps exactly the pixels the canvas showed"
        );
        assert_eq!(editor.document.layers[0].name, "Layer 1", "the merged layer takes the lower name");

        assert!(editor.undo());
        assert_eq!(editor.document.layers.len(), 2, "one step brings both layers back");
    }

    #[test]
    fn flattening_leaves_a_single_background_layer() {
        let mut editor = editor_with(8, 8);
        let bottom = active_layer(&editor);
        editor.document.set_layer_image(bottom, Bitmap8::filled(8, 8, [30, 60, 90, 255]));
        editor.add_layer();
        let top = active_layer(&editor);
        editor.document.set_layer_image(top, Bitmap8::filled(8, 8, [0, 0, 0, 0]));
        let before = editor.flattened();

        assert!(editor.flatten_image());
        assert_eq!(editor.document.layers.len(), 1);
        assert_eq!(editor.document.layers[0].name, "Background");
        assert_eq!(editor.document.layers[0].transform.size.width, 8.0);
        assert_eq!(editor.flattened().pixels(), before.pixels());
        assert_eq!(editor.undo_label(), Some("Flatten Image"));
        assert!(editor.undo());
        assert_eq!(editor.document.layers.len(), 2);
    }

    #[test]
    fn copy_merged_adds_a_layer_holding_the_composite() {
        let mut editor = editor_with(8, 8);
        let bottom = active_layer(&editor);
        editor.document.set_layer_image(bottom, Bitmap8::filled(8, 8, [10, 20, 30, 255]));
        editor.add_layer();
        let top = active_layer(&editor);
        editor.document.set_layer_image(top, Bitmap8::filled(4, 4, [200, 0, 0, 255]));
        let composite = editor.flattened();

        assert!(editor.copy_merged());
        assert_eq!(editor.document.layers.len(), 3);
        let copy = editor.document.layers.last().unwrap();
        assert_eq!(copy.name, "Merged");
        assert_eq!(copy.transform.size.width, 8.0, "the copy covers the canvas");
        assert_eq!(copy.image.as_ref().unwrap().pixels(), composite.pixels());
        assert_eq!(editor.undo_label(), Some("Copy Merged"));
        assert_eq!(editor.flattened().pixels(), composite.pixels(), "the canvas is unchanged");
        assert!(editor.undo());
        assert_eq!(editor.document.layers.len(), 2);
    }

    #[test]
    fn a_filter_runs_on_the_layer_and_undoes_in_one_step() {
        let mut editor = editor_with(16, 16);
        let id = active_layer(&editor);
        let mut gradient = Bitmap8::new(16, 16);
        for y in 0..16 {
            for x in 0..16 {
                let value = if x < 8 { 0 } else { 255 };
                gradient.set(x, y, [value, value, value, 255]);
            }
        }
        editor.document.set_layer_image(id, gradient);
        let before = editor.document.layer(id).unwrap().image.clone().unwrap();

        let settings = crate::filters::FilterSettings { radius: 4.0, ..Default::default() };
        editor.apply_filter(crate::filters::FilterKind::GaussianBlur, settings).expect("the blur runs");
        let after = editor.document.layer(id).unwrap().image.clone().unwrap();
        assert_ne!(after.pixels(), before.pixels(), "a blur changes the edge");
        assert_eq!(editor.undo_label(), Some("Gaussian Blur"));
        assert!(editor.undo());
        assert_eq!(editor.document.layer(id).unwrap().image.clone().unwrap().pixels(), before.pixels());
    }

    #[test]
    fn a_filter_that_runs_somewhere_else_says_where() {
        let mut editor = editor_with(8, 8);
        let settings = crate::filters::FilterSettings::default();
        // Remove Background is no longer waiting for a model: it runs from the menu, which holds the
        // model and reports which extractor answered, so going through the filter path says so.
        let elsewhere = editor
            .apply_filter(crate::filters::FilterKind::RemoveBackground, settings.clone())
            .unwrap_err();
        assert!(elsewhere.contains("Remove Background"), "{elsewhere}");
        assert!(elsewhere.contains("Filter menu"), "{elsewhere}");
        assert!(elsewhere.contains("model"), "{elsewhere}");
        assert!(
            editor.apply_filter(crate::filters::FilterKind::CameraRaw, settings).is_err(),
            "camera raw opens its own window"
        );
        assert!(!editor.can_undo(), "a refused filter changes nothing");
    }

    #[test]
    fn a_subject_matte_becomes_the_layer_mask_and_undoes_in_one_step() {
        let mut editor = editor_with(8, 8);
        assert!(editor.add_layer());
        let id = editor.document.active_layer.expect("a layer");
        assert!(editor.replace_layer_pixels(id, Bitmap8::filled(8, 8, [120, 60, 30, 255])));
        let mut matte = Gray8::new(8, 8);
        for value in matte.pixels_mut().iter_mut().take(32) {
            *value = 255;
        }
        let before = editor.history.depth().0;

        let coverage = editor.apply_subject_matte(id, &matte, "Select Subject").expect("the matte lands");
        assert!((coverage - 0.5).abs() < 1e-9, "{coverage}");
        assert!(editor.has_mask(id), "the matte is kept as the layer's mask");
        assert_eq!(editor.history.depth().0, before + 1, "one step");
        assert_eq!(editor.undo_label(), Some("Select Subject"));
        assert!(editor.undo(), "and it undoes");
        assert!(!editor.has_mask(id), "the mask goes with the step");

        // A matte with no subject is refused rather than written as an empty mask.
        let empty = Gray8::new(8, 8);
        assert!(editor.apply_subject_matte(id, &empty, "Select Subject").is_err());
        assert!(!editor.has_mask(id));
        assert_eq!(editor.history.depth().0, before, "a refusal records nothing");
    }

    #[test]
    fn removing_the_background_keeps_the_subject_pixels_and_undoes_in_one_step() {
        let mut editor = editor_with(8, 8);
        assert!(editor.add_layer());
        let id = editor.document.active_layer.expect("a layer");
        assert!(editor.replace_layer_pixels(id, Bitmap8::filled(8, 8, [120, 60, 30, 255])));
        let image = editor.document.layer(id).and_then(|layer| layer.image.clone()).expect("pixels");
        // The left half is subject, the right half is background.
        let mut matte = Gray8::new(8, 8);
        for y in 0..8 {
            for x in 0..4 {
                matte.set(x, y, 255);
            }
        }
        let before_history = editor.history.depth().0;

        let coverage = editor
            .apply_background_cut(id, &image, &matte, "Remove Background")
            .expect("the cut lands");
        assert!((coverage - 0.5).abs() < 1e-9, "{coverage}");
        let cut = editor.document.layer(id).and_then(|layer| layer.image.clone()).expect("pixels");
        assert_eq!(cut.get(1, 1)[3], 255, "the subject stays opaque");
        assert_eq!(cut.get(6, 1)[3], 0, "the background is cleared");
        assert_eq!(editor.history.depth().0, before_history + 1, "one step");
        assert!(editor.undo(), "and it undoes");
        let restored = editor.document.layer(id).and_then(|layer| layer.image.clone()).expect("pixels");
        assert_eq!(restored.pixels(), image.pixels(), "the pixels come back");
    }

    #[test]
    fn the_engine_backed_filters_all_run_on_a_layer() {
        use crate::filters::FilterMenu;
        let mut editor = editor_with(16, 16);
        let id = active_layer(&editor);
        let mut ramp = Bitmap8::new(16, 16);
        for y in 0..16 {
            for x in 0..16 {
                ramp.set(x, y, [(x * 16) as u8, (y * 16) as u8, 128, 255]);
            }
        }
        editor.document.set_layer_image(id, ramp);
        let settings = crate::filters::FilterSettings::default();
        let mut applied = 0;
        for kind in crate::filters::MENU {
            if !kind.is_destructive() {
                continue;
            }
            editor
                .apply_filter(kind, settings.clone())
                .unwrap_or_else(|error| panic!("{} could not run: {error}", kind.name()));
            applied += 1;
        }
        assert_eq!(applied, 8, "the eight filters the engine runs on pixels");
        assert!(editor.can_undo(), "each filter is an undo step");
    }

    #[test]
    fn an_adjustment_filter_adds_a_layer_instead_of_editing_pixels() {
        let mut editor = editor_with(8, 8);
        let pixels_before = editor.document.layers[0].image.clone().unwrap();
        editor
            .apply_filter(crate::filters::FilterKind::Curves, crate::filters::FilterSettings::default())
            .expect("curves becomes an adjustment layer");
        let id = editor.document.active_layer.unwrap();
        assert_eq!(editor.adjustment_kind(id), Some(AdjustmentKind::Curves));
        assert_eq!(editor.document.layers.len(), 2);
        assert_eq!(
            editor.document.layers[0].image.clone().unwrap().pixels(),
            pixels_before.pixels(),
            "the layer's own pixels are untouched"
        );
    }

    #[test]
    fn content_aware_fill_asks_for_a_selection_first() {
        let mut editor = editor_with(16, 16);
        let settings = crate::filters::FilterSettings::default();
        let message = editor
            .apply_filter(crate::filters::FilterKind::ContentAwareFill, settings)
            .unwrap_err();
        assert!(message.contains("Select"), "{message}");
        // The editor reports the refusal to the caller; the app puts it in the status bar.
        assert!(!editor.can_undo(), "a refused fill changes nothing");
    }

    #[test]
    fn a_layer_mask_is_added_toggled_and_removed() {
        let mut editor = editor_with(16, 12);
        let id = active_layer(&editor);
        assert!(!editor.has_mask(id));
        assert!(editor.add_layer_mask(id, false));
        assert!(editor.has_mask(id));
        assert!(editor.document.layer(id).unwrap().mask.as_ref().unwrap().is_uniform());
        assert_eq!(editor.document.layer(id).unwrap().mask.as_ref().unwrap().get(0, 0), 255);
        assert_eq!(editor.undo_label(), Some("Add Layer Mask"));

        assert!(editor.set_mask_enabled(id, false));
        assert!(!editor.document.layer(id).unwrap().mask_enabled);
        assert!(editor.has_mask(id), "switching a mask off keeps it");

        assert!(editor.remove_layer_mask(id));
        assert!(!editor.has_mask(id));
        assert!(editor.undo(), "removal is one step");
        assert!(editor.has_mask(id), "undo brings the mask back");
    }

    #[test]
    fn a_mask_built_from_alpha_follows_the_layers_transparency() {
        let mut editor = editor_with(8, 4);
        let id = active_layer(&editor);
        let mut image = Bitmap8::new(8, 4);
        image.set(0, 0, [10, 20, 30, 255]);
        image.set(7, 3, [10, 20, 30, 64]);
        editor.document.set_layer_image(id, image.clone());
        assert!(editor.add_layer_mask(id, true));
        let mask = editor.document.layer(id).unwrap().mask.as_ref().unwrap();
        assert_eq!(mask.get(0, 0), 255);
        assert_eq!(mask.get(7, 3), 64);
        assert_eq!(mask.get(4, 2), 0, "a transparent pixel hides");
    }

    #[test]
    fn painting_a_mask_writes_gray_and_undo_restores_it() {
        let mut editor = editor_with(32, 32);
        let id = active_layer(&editor);
        assert!(editor.add_layer_mask(id, false));
        editor.mask_painting = true;
        editor.color = [0, 0, 0, 255];
        editor.brush.size = 10.0;

        assert!(editor.begin_stroke(Pos2::new(16.0, 16.0)));
        assert!(editor.stroke_to(Pos2::new(16.0, 16.0)));
        assert!(editor.end_stroke());
        let mask = editor.document.layer(id).unwrap().mask.as_ref().unwrap();
        assert!(mask.get(16, 16) < 40, "black paint should hide the mask, got {}", mask.get(16, 16));
        assert_eq!(mask.get(1, 1), 255, "the untouched mask stays white");
        assert_eq!(editor.undo_label(), Some("Paint Mask"));

        assert!(editor.undo());
        assert_eq!(editor.document.layer(id).unwrap().mask.as_ref().unwrap().get(16, 16), 255);
    }

    #[test]
    fn mask_painting_is_refused_without_an_enabled_mask() {
        let mut editor = editor_with(16, 16);
        let id = active_layer(&editor);
        editor.mask_painting = true;
        assert!(!editor.begin_stroke(Pos2::new(4.0, 4.0)), "no mask yet");
        assert!(editor.message_is_error);

        assert!(editor.add_layer_mask(id, false));
        assert!(editor.set_mask_enabled(id, false));
        assert!(!editor.begin_stroke(Pos2::new(4.0, 4.0)), "a mask that is off is not paintable");
        assert!(editor.message_is_error);

        assert!(editor.set_mask_enabled(id, true));
        assert!(editor.begin_stroke(Pos2::new(4.0, 4.0)));
        assert!(editor.cancel_stroke());
    }

    #[test]
    fn an_adjustment_layer_is_added_and_edited_with_validation() {
        let mut editor = editor_with(32, 32);
        assert!(editor.add_adjustment_layer(AdjustmentKind::GaussianBlur));
        let id = editor.document.active_layer.unwrap();
        assert_eq!(editor.adjustment_kind(id), Some(AdjustmentKind::GaussianBlur));
        assert!(editor.update_adjustment(id, |adjustment| adjustment.blur_radius = Some(12.0)));
        assert_eq!(editor.document.layer(id).unwrap().adjustment.as_ref().unwrap().blur_radius, Some(12.0));

        // A value the format refuses leaves the stored one alone.
        assert!(!editor.update_adjustment(id, |adjustment| adjustment.hue = 10_000.0));
        assert_eq!(editor.document.layer(id).unwrap().adjustment.as_ref().unwrap().hue, 0.0);
        // The refused change recorded nothing, so the last step is still the accepted one: an
        // adjustment edit is its own step now, which is what the undo-coverage audit set out to fix.
        assert_eq!(editor.undo_label(), Some("Adjustment"));
        assert!(editor.undo(), "the accepted edit undoes");
        assert_eq!(editor.undo_label(), Some("New Adjustment Layer"), "and then the layer itself");
    }

    #[test]
    fn an_invert_adjustment_layer_changes_the_composite() {
        let mut editor = editor_with(4, 4);
        let id = active_layer(&editor);
        editor.document.set_layer_image(id, Bitmap8::filled(4, 4, [10, 20, 30, 255]));
        let before = editor.flattened().get(1, 1);
        assert!(editor.add_adjustment_layer(AdjustmentKind::Invert));
        let after = editor.flattened().get(1, 1);
        assert_ne!(before, after, "the adjustment layer should rework the pixels below it");
    }

    #[test]
    fn effects_are_added_edited_and_cleared() {
        let mut editor = editor_with(32, 32);
        let id = active_layer(&editor);
        assert!(editor.update_effects(id, |effects| {
            effects.stroke = Some(comp_core::effects::StrokeEffect::default())
        }));
        assert!(editor.document.layer(id).unwrap().effects.is_some());

        assert!(editor.update_effects(id, |effects| {
            if let Some(stroke) = effects.stroke.as_mut() {
                stroke.size = 7.0;
            }
        }));
        assert_eq!(editor.document.layer(id).unwrap().effects.unwrap().stroke.unwrap().size, 7.0);

        assert!(
            !editor.update_effects(id, |effects| {
                if let Some(stroke) = effects.stroke.as_mut() {
                    stroke.size = 7.0;
                }
            }),
            "an edit that changes nothing records nothing"
        );
        assert!(editor.clear_effects(id));
        assert!(editor.document.layer(id).unwrap().effects.is_none());
    }

    #[test]
    fn a_text_layer_is_created_with_pixels_and_a_matching_box() {
        let mut editor = editor_with(400, 200);
        let mut library = comp_text::FontLibrary::new();
        let style = TextStyle { content: "Hi".to_string(), font_size: 48.0, ..TextStyle::default() };
        let id = editor.add_text_layer(Pos2::new(10.0, 20.0), style, &mut library).expect("the text should draw");
        let layer = editor.document.layer(id).unwrap();
        assert!(layer.text.is_some());
        let image = layer.image.as_ref().expect("drawn pixels");
        assert!(!image.is_fully_transparent(), "the glyphs should have been drawn");
        assert_eq!(layer.transform.origin, PointF::new(10.0, 20.0));
        assert_eq!(layer.transform.size, SizeF::new(image.width() as f64, image.height() as f64));
        assert_eq!(editor.undo_label(), Some("Add Text Layer"));

        assert!(editor.undo());
        assert!(editor.document.layer(id).is_none(), "one step removes the whole layer");
    }

    #[test]
    fn committing_a_larger_text_size_redraws_the_pixels() {
        let mut editor = editor_with(600, 300);
        let mut library = comp_text::FontLibrary::new();
        let style = TextStyle { content: "A".to_string(), font_size: 32.0, ..TextStyle::default() };
        let id = editor.add_text_layer(Pos2::new(0.0, 0.0), style, &mut library).unwrap();
        let first = editor.document.layer(id).unwrap().image.as_ref().unwrap().width();

        let mut bigger = editor.text_style(id).unwrap();
        bigger.font_size = 96.0;
        assert!(editor.set_text_style(id, bigger));
        let (width, height) = editor.commit_text(id, &mut library).unwrap();
        assert!(width > first, "a larger size should produce a wider raster");
        let layer = editor.document.layer(id).unwrap();
        assert_eq!(layer.transform.size, SizeF::new(width as f64, height as f64));
    }

    #[test]
    fn an_invalid_text_style_is_refused_without_touching_the_pixels() {
        let mut editor = editor_with(200, 100);
        let mut library = comp_text::FontLibrary::new();
        let style = TextStyle { content: "ok".to_string(), font_size: 24.0, ..TextStyle::default() };
        let id = editor.add_text_layer(Pos2::new(0.0, 0.0), style, &mut library).unwrap();
        let before = editor.document.layer(id).unwrap().image.clone();

        let mut broken = editor.text_style(id).unwrap();
        broken.font_size = 0.0;
        editor.set_text_style(id, broken);
        assert!(editor.commit_text(id, &mut library).is_err());
        let after = editor.document.layer(id).unwrap().image.clone();
        assert_eq!(before.unwrap().pixels(), after.unwrap().pixels());
    }

    #[test]
    fn the_text_tool_finds_the_layer_under_the_pointer() {
        let mut editor = editor_with(400, 200);
        let mut library = comp_text::FontLibrary::new();
        let style = TextStyle { content: "Hit".to_string(), font_size: 48.0, ..TextStyle::default() };
        let id = editor.add_text_layer(Pos2::new(50.0, 60.0), style, &mut library).unwrap();
        let size = editor.document.layer(id).unwrap().image.as_ref().unwrap();
        let (width, height) = (size.width() as f32, size.height() as f32);
        assert_eq!(editor.text_layer_at(Pos2::new(52.0, 62.0)), Some(id));
        assert_eq!(editor.text_layer_at(Pos2::new(50.0 + width + 5.0, 60.0 + height + 5.0)), None);
        assert_eq!(editor.text_layer_at(Pos2::new(-10.0, -10.0)), None);
    }

    #[test]
    fn a_stroke_reports_the_canvas_rectangle_it_dirtied() {
        let mut editor = editor_with(64, 64);
        editor.brush.size = 8.0;
        assert!(editor.begin_stroke(Pos2::new(20.0, 20.0)));
        assert!(editor.take_dirty().is_none(), "starting a stroke paints nothing yet");
        assert!(editor.stroke_to(Pos2::new(30.0, 20.0)));
        let dirty = editor.take_dirty().expect("a painted sample dirties a rectangle");
        // The dab is 8 wide along y=20, so the repaint must cover it with a pixel of slack.
        assert!(dirty.0 <= 19 && dirty.1 <= 15, "{dirty:?}");
        assert!(dirty.0 + dirty.2 as i64 >= 31, "{dirty:?}");
        assert!(dirty.1 + dirty.3 as i64 >= 25, "{dirty:?}");
        assert!(editor.take_dirty().is_none(), "taking the rectangle clears it");
        editor.end_stroke();
    }

    #[test]
    fn a_transformed_layer_reports_its_dirty_rectangle_in_canvas_pixels() {
        let mut editor = editor_with(64, 64);
        let mut layer = Layer::raster("Patch", 16, 16);
        layer.image = Some(Arc::new(Bitmap8::new(16, 16)));
        layer.transform.origin = PointF::new(32.0, 32.0);
        let id = editor.document.add_layer(layer, None);
        editor.select_layer(id);
        editor.brush.size = 4.0;
        assert!(editor.begin_stroke(Pos2::new(36.0, 36.0)));
        assert!(editor.stroke_to(Pos2::new(38.0, 36.0)));
        let dirty = editor.take_dirty().expect("the layer pixels changed");
        // The layer sits at 32,32, so the repaint follows it there instead of the canvas origin.
        assert!(dirty.0 >= 30 && dirty.1 >= 30, "{dirty:?}");
        assert!(dirty.0 + dirty.2 as i64 <= 50, "{dirty:?}");
        assert!(dirty.1 + dirty.3 as i64 <= 50, "{dirty:?}");
        editor.end_stroke();
    }

    #[test]
    fn a_stroke_dirties_a_small_fraction_of_a_large_canvas() {
        // Pointer samples arrive a few pixels apart, which is what keeps each repaint small; one
        // very long sample would legitimately dirty the whole segment.
        let mut editor = editor_with(1024, 1024);
        editor.brush.size = 32.0;
        let canvas = 1024.0 * 1024.0;
        let mut largest = 0.0f64;
        assert!(editor.begin_stroke(Pos2::new(200.0, 200.0)));
        for step in 0..20 {
            let x = 200.0 + step as f32 * 10.0;
            assert!(editor.stroke_to(Pos2::new(x, 220.0)));
            if let Some(dirty) = editor.take_dirty() {
                largest = largest.max(dirty.2 as f64 * dirty.3 as f64);
            }
        }
        assert!(
            largest / canvas < 0.02,
            "a sample's repaint should cover a fraction of the canvas, got {:.2}%",
            largest / canvas * 100.0
        );
        editor.end_stroke();
    }

    #[test]
    fn a_canvas_style_stroke_reaches_the_composite() {
        let mut editor = editor_with(64, 64);
        editor.color = [255, 0, 0, 255];
        // The canvas drives the editor exactly like this: press, pointer samples, release.
        assert!(editor.begin_stroke(Pos2::new(10.0, 10.0)));
        for step in 0..9 {
            let x = 10.0 + step as f32 * 5.0;
            assert!(editor.stroke_to(Pos2::new(x, 32.0)));
        }
        assert!(editor.end_stroke());
        assert_eq!(editor.undo_label(), Some("Brush Stroke"));

        let flattened = editor.flattened();
        assert_eq!(flattened.get(10, 32), [255, 0, 0, 255]);
        assert_eq!(flattened.get(50, 32), [255, 0, 0, 255]);
        assert_eq!(flattened.get(60, 4), [0, 0, 0, 0]);

        assert!(editor.undo());
        assert_eq!(editor.flattened().get(10, 32), [0, 0, 0, 0]);
    }

    #[test]
    fn a_stroke_that_paints_nothing_records_no_step() {
        let mut editor = editor_with(32, 32);
        // A press outside the canvas still starts a stroke; it simply has nothing to paint.
        assert!(editor.begin_stroke(Pos2::new(-400.0, -400.0)));
        assert!(!editor.stroke_to(Pos2::new(-380.0, -400.0)));
        assert!(!editor.end_stroke());
        assert!(!editor.can_undo());
    }

    #[test]
    fn cancelling_a_stroke_puts_the_pixels_back() {
        let mut editor = editor_with(32, 32);
        let id = active_layer(&editor);
        let snapshot = editor.document.clone();
        editor.brush.size = 12.0;
        assert!(editor.begin_stroke(Pos2::new(10.0, 10.0)));
        assert!(editor.stroke_to(Pos2::new(20.0, 10.0)));
        assert!(editor.cancel_stroke());
        assert_eq!(editor.document.layer(id).unwrap().image.as_ref().unwrap().get(15, 10), [0, 0, 0, 0]);
        assert_eq!(editor.document.layers.len(), snapshot.layers.len());
        assert!(!editor.can_undo());
    }

    #[test]
    fn the_eraser_removes_pixels_from_a_filled_layer() {
        let mut editor = editor_with(32, 32);
        let id = active_layer(&editor);
        editor.document.set_layer_image(id, Bitmap8::filled(32, 32, [0, 0, 0, 255]));
        editor.set_tool(Tool::Eraser);
        editor.brush.size = 12.0;
        assert!(editor.begin_stroke(Pos2::new(16.0, 16.0)));
        assert!(editor.stroke_to(Pos2::new(16.0, 16.0)));
        assert!(editor.end_stroke());
        assert_eq!(editor.document.layer(id).unwrap().image.as_ref().unwrap().get(16, 16)[3], 0);
        assert_eq!(editor.document.layer(id).unwrap().image.as_ref().unwrap().get(1, 1)[3], 255);
    }

    #[test]
    fn a_selection_clips_the_stroke() {
        let mut editor = editor_with(32, 32);
        let id = active_layer(&editor);
        editor.brush.size = 16.0;
        editor.set_selection(Rect::from_min_max(Pos2::new(0.0, 0.0), Pos2::new(16.0, 32.0)));
        assert!(editor.begin_stroke(Pos2::new(8.0, 16.0)));
        assert!(editor.stroke_to(Pos2::new(28.0, 16.0)));
        assert!(editor.end_stroke());
        let image = editor.document.layer(id).unwrap().image.as_ref().unwrap();
        assert!(image.get(8, 16)[3] > 0);
        assert_eq!(image.get(26, 16)[3], 0);
    }

    #[test]
    fn painting_lands_where_the_layer_transform_puts_the_cursor() {
        let mut editor = editor_with(64, 64);
        let mut layer = Layer::raster("Patch", 16, 16);
        layer.image = Some(Arc::new(Bitmap8::new(16, 16)));
        layer.image_file = Some(layer.expected_image_file());
        layer.transform.origin = PointF::new(32.0, 32.0);
        let id = editor.document.add_layer(layer, None);
        editor.select_layer(id);
        editor.brush.size = 4.0;
        editor.color = [255, 0, 0, 255];
        assert!(editor.begin_stroke(Pos2::new(40.5, 40.5)));
        // The document pixel under (40.5, 40.5) is layer-local (8.5, 8.5), so bitmap pixel 8, 8.
        assert!(editor.stroke_to(Pos2::new(40.5, 40.5)));
        assert!(editor.end_stroke());
        let image = editor.document.layer(id).unwrap().image.as_ref().unwrap();
        assert!(image.get(8, 8)[3] > 0, "the dab missed the pixel under the cursor");
        assert_eq!(image.get(0, 0)[3], 0);
    }

    #[test]
    fn a_scaled_layer_maps_the_cursor_through_its_box() {
        let mut editor = editor_with(64, 64);
        let mut layer = Layer::raster("Half", 16, 16);
        layer.image = Some(Arc::new(Bitmap8::new(16, 16)));
        // The 16x16 bitmap fills a 32x32 box, so one bitmap pixel covers two document pixels.
        layer.transform.size = comp_core::geom::SizeF::new(32.0, 32.0);
        let id = editor.document.add_layer(layer, None);
        editor.select_layer(id);
        editor.brush.size = 2.0;
        assert!(editor.begin_stroke(Pos2::new(16.5, 16.5)));
        assert!(editor.stroke_to(Pos2::new(16.5, 16.5)));
        assert!(editor.end_stroke());
        let image = editor.document.layer(id).unwrap().image.as_ref().unwrap();
        assert!(image.get(8, 8)[3] > 0, "the scaled box did not map the cursor back to the bitmap");
    }

    #[test]
    fn a_stroke_on_a_group_reports_an_error_instead_of_painting() {
        let mut editor = editor_with(16, 16);
        let group = Layer::group("Folder", 16, 16);
        let group_id = group.id;
        editor.document.add_layer(group, None);
        editor.select_layer(group_id);
        assert!(!editor.begin_stroke(Pos2::new(8.0, 8.0)));
        assert!(editor.message_is_error);
        assert!(!editor.is_stroking());
    }

    #[test]
    fn a_layer_without_pixels_is_created_on_the_first_stroke_and_undo_removes_it() {
        let mut editor = editor_with(16, 16);
        let mut layer = Layer::raster("Empty", 16, 16);
        layer.image = None;
        let id = editor.document.add_layer(layer, None);
        editor.select_layer(id);
        editor.brush.size = 6.0;
        assert!(editor.begin_stroke(Pos2::new(8.0, 8.0)));
        assert!(editor.stroke_to(Pos2::new(8.0, 8.0)));
        assert!(editor.end_stroke());
        assert!(editor.document.layer(id).unwrap().image.is_some());
        assert!(editor.undo());
        assert!(editor.document.layer(id).unwrap().image.is_none());
    }

    #[test]
    fn the_marquee_never_selects_less_than_one_pixel_and_clips_to_the_canvas() {
        let mut editor = editor_with(16, 16);
        editor.set_selection(Rect::from_min_max(Pos2::new(4.0, 4.0), Pos2::new(4.2, 4.2)));
        assert!(editor.selection.is_none());
        editor.set_selection(Rect::from_min_max(Pos2::new(-5.0, -5.0), Pos2::new(40.0, 40.0)));
        let selection = editor.selection.unwrap();
        assert_eq!(selection.min, Pos2::ZERO);
        assert_eq!(selection.max, Pos2::new(16.0, 16.0));
        editor.select_all();
        assert_eq!(editor.selection.unwrap().width(), 16.0);
        editor.deselect();
        assert!(editor.selection.is_none());
    }

    #[test]
    fn the_eyedropper_reads_the_flattened_composite() {
        let mut editor = editor_with(16, 16);
        let id = active_layer(&editor);
        editor.document.set_layer_image(id, Bitmap8::filled(16, 16, [12, 34, 56, 255]));
        let flattened = editor.flattened();
        assert_eq!(editor.pick_color(&flattened, Pos2::new(4.0, 4.0)), Some([12, 34, 56, 255]));
        assert_eq!(editor.pick_color(&flattened, Pos2::new(99.0, 4.0)), None);
    }

    #[test]
    fn the_memory_estimate_counts_pixels_and_history() {
        let mut editor = editor_with(64, 64);
        let id = active_layer(&editor);
        editor.document.set_layer_mask(id, Gray8::filled(64, 64, 255));
        let estimate = editor.memory_estimate();
        assert_eq!(estimate.document_bytes, 64 * 64 * 4 + 64 * 64);
        assert!(estimate.history_bytes < 64 * 64 * 4, "sharing keeps the history cheap");
    }

    #[test]
    fn saving_and_reopening_round_trips_and_clears_the_modified_flag() {
        let root = std::env::temp_dir().join(format!("comp-gui-session-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let package = root.join("Round.comp");
        let mut editor = editor_with(16, 12);
        let id = active_layer(&editor);
        editor.set_name(id, "Painted".to_string());
        editor.document.set_layer_image(id, Bitmap8::filled(16, 12, [7, 8, 9, 255]));
        editor.save_to(&package).unwrap();
        assert!(!editor.is_modified());
        assert_eq!(editor.file_name(), "Round.comp");

        let mut reopened = editor_with(4, 4);
        reopened.load(&package).unwrap();
        assert_eq!(reopened.document_size(), (16, 12));
        assert_eq!(reopened.document.layers[0].name, "Painted");
        assert_eq!(reopened.document.layers[0].image.as_ref().unwrap().get(3, 3), [7, 8, 9, 255]);
        assert!(!reopened.is_modified());
        assert!(reopened.digest.is_some());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn loading_a_missing_package_reports_an_error() {
        let mut editor = editor_with(4, 4);
        let missing = std::env::temp_dir().join(format!("comp-gui-missing-{}", Uuid::new_v4()));
        assert!(editor.load(&missing).is_err());
        assert_eq!(editor.document_size(), (4, 4));
    }
}
