//! The document model: a flat, bottom-to-top layer list where groups own contiguous subtrees.
use uuid::Uuid;

use crate::bitmap::{Bitmap8, Gray8};
use crate::geom::Guide;
use crate::layer::Layer;
use std::sync::Arc;

/// The format version new saves write.
pub const CURRENT_VERSION: u32 = 11;
/// Every version this build reads.
pub const SUPPORTED_VERSIONS: std::ops::RangeInclusive<u32> = 1..=CURRENT_VERSION;

/// A Compositor document, as the editor holds it in memory.
///
/// `layers` runs bottom to top; a group's descendants follow it as one contiguous subtree.
#[derive(Clone, Debug, PartialEq)]
pub struct Document {
    pub id: Uuid,
    pub width: u32,
    pub height: u32,
    /// Pixels per inch, 1-9600. Older projects default to 72.
    pub resolution: f64,
    pub active_layer: Option<Uuid>,
    pub layers: Vec<Layer>,
    pub guides: Vec<Guide>,
    /// The format version this document was read from, or the version a save writes.
    pub version: u32,
}

impl Document {
    pub fn new(width: u32, height: u32) -> Self {
        Document {
            id: Uuid::new_v4(),
            width,
            height,
            resolution: 72.0,
            active_layer: None,
            layers: Vec::new(),
            guides: Vec::new(),
            version: CURRENT_VERSION,
        }
    }

    /// A document with one transparent layer covering the canvas, selected.
    pub fn with_background(width: u32, height: u32) -> Self {
        let mut document = Document::new(width, height);
        let mut layer = Layer::raster("Layer 1", width, height);
        layer.image = Some(Arc::new(Bitmap8::new(width, height)));
        layer.image_file = Some(layer.expected_image_file());
        document.active_layer = Some(layer.id);
        document.layers.push(layer);
        document
    }

    pub fn index_of(&self, id: Uuid) -> Option<usize> {
        self.layers.iter().position(|layer| layer.id == id)
    }

    pub fn layer(&self, id: Uuid) -> Option<&Layer> {
        self.layers.iter().find(|layer| layer.id == id)
    }

    pub fn layer_mut(&mut self, id: Uuid) -> Option<&mut Layer> {
        self.layers.iter_mut().find(|layer| layer.id == id)
    }

    pub fn active(&self) -> Option<&Layer> {
        self.active_layer.and_then(|id| self.layer(id))
    }

    /// Indices of the direct children of `parent` (`None` for root layers), bottom to top.
    pub fn child_indices(&self, parent: Option<Uuid>) -> Vec<usize> {
        self.layers
            .iter()
            .enumerate()
            .filter(|(_, layer)| layer.parent == parent)
            .map(|(index, _)| index)
            .collect()
    }

    pub fn children(&self, parent: Uuid) -> Vec<&Layer> {
        self.layers.iter().filter(|layer| layer.parent == Some(parent)).collect()
    }

    pub fn roots(&self) -> Vec<&Layer> {
        self.layers.iter().filter(|layer| layer.parent.is_none()).collect()
    }

    /// Indices covering a layer and every descendant, in document order.
    pub fn subtree_indices(&self, id: Uuid) -> Vec<usize> {
        let Some(start) = self.index_of(id) else { return Vec::new() };
        let mut indices = vec![start];
        let mut cursor = start + 1;
        while cursor < self.layers.len() {
            let mut ancestor = self.layers[cursor].parent;
            let mut inside = false;
            while let Some(parent) = ancestor {
                if parent == id {
                    inside = true;
                    break;
                }
                ancestor = self.layer(parent).and_then(|layer| layer.parent);
            }
            if !inside {
                break;
            }
            indices.push(cursor);
            cursor += 1;
        }
        indices
    }

    /// Every ancestor of `id`, nearest first.
    pub fn ancestors(&self, id: Uuid) -> Vec<Uuid> {
        let mut result = Vec::new();
        let mut cursor = self.layer(id).and_then(|layer| layer.parent);
        while let Some(parent) = cursor {
            result.push(parent);
            cursor = self.layer(parent).and_then(|layer| layer.parent);
        }
        result
    }

    /// How many groups enclose `id`.
    pub fn depth(&self, id: Uuid) -> usize {
        self.ancestors(id).len()
    }

    pub fn is_descendant(&self, ancestor: Uuid, node: Uuid) -> bool {
        self.ancestors(node).contains(&ancestor)
    }

    /// The opacity a layer composites with: its own times every enclosing group's.
    pub fn effective_opacity(&self, id: Uuid) -> f64 {
        let Some(layer) = self.layer(id) else { return 1.0 };
        let mut opacity = layer.opacity;
        for ancestor in self.ancestors(id) {
            if let Some(group) = self.layer(ancestor) {
                opacity *= group.opacity;
            }
        }
        opacity
    }

    /// True when the layer and every group above it are visible.
    pub fn effective_visibility(&self, id: Uuid) -> bool {
        let Some(layer) = self.layer(id) else { return false };
        if !layer.visible {
            return false;
        }
        self.ancestors(id).iter().all(|ancestor| self.layer(*ancestor).map(|l| l.visible).unwrap_or(false))
    }

    /// Adds a layer at the top of the stack, inside `parent` when given.
    pub fn add_layer(&mut self, mut layer: Layer, parent: Option<Uuid>) -> Uuid {
        layer.parent = parent;
        let id = layer.id;
        match parent {
            None => self.layers.push(layer),
            Some(parent_id) => {
                let insert_at = match self.subtree_indices(parent_id).last() {
                    Some(last) => last + 1,
                    None => self.layers.len(),
                };
                self.layers.insert(insert_at, layer);
            }
        }
        self.active_layer = Some(id);
        id
    }

    /// Removes a layer and everything inside it.
    pub fn remove_layer(&mut self, id: Uuid) -> Vec<Layer> {
        let indices = self.subtree_indices(id);
        if indices.is_empty() {
            return Vec::new();
        }
        let removed: Vec<Layer> = indices.iter().map(|index| self.layers[*index].clone()).collect();
        for index in indices.iter().rev() {
            self.layers.remove(*index);
        }
        if self.active_layer.map(|active| removed.iter().any(|layer| layer.id == active)).unwrap_or(false) {
            self.active_layer = self.layers.last().map(|layer| layer.id);
        }
        removed
    }

    /// Moves a layer and its subtree so it sits at `target_root_index` among its siblings.
    pub fn move_layer(&mut self, id: Uuid, target: usize) -> bool {
        let Some(index) = self.index_of(id) else { return false };
        let count = self.subtree_indices(id).len();
        if target >= index && target < index + count {
            return false;
        }
        let mut moved: Vec<Layer> = self.layers.drain(index..index + count).collect();
        let insert_at = if target > index { target - count } else { target };
        let insert_at = insert_at.min(self.layers.len());
        for (offset, layer) in moved.drain(..).enumerate() {
            self.layers.insert(insert_at + offset, layer);
        }
        true
    }

    /// Every layer that actually contributes pixels when composited, bottom to top.
    pub fn renderable_ids(&self) -> Vec<Uuid> {
        let mut result = Vec::new();
        let mut hidden_groups: Vec<Uuid> = Vec::new();
        for layer in &self.layers {
            if layer.is_group {
                if !layer.visible || layer.opacity == 0.0 {
                    hidden_groups.push(layer.id);
                } else {
                    hidden_groups.retain(|id| *id != layer.id);
                }
                continue;
            }
            if !layer.visible {
                continue;
            }
            let hidden = self.ancestors(layer.id).iter().any(|ancestor| {
                let group = self.layer(*ancestor);
                match group {
                    Some(group) => !group.visible || group.opacity == 0.0,
                    None => true,
                }
            });
            if !hidden {
                result.push(layer.id);
            }
        }
        let _ = hidden_groups;
        result
    }

    /// Total pixels held by every layer image and mask, as the format's budget counts them.
    pub fn pixel_counts(&self) -> (u64, u64) {
        let mut images = 0u64;
        let mut masks = 0u64;
        for layer in &self.layers {
            if let Some(image) = &layer.image {
                images += image.pixel_count() as u64;
            }
            if let Some(mask) = &layer.mask {
                masks += mask.width() as u64 * mask.height() as u64;
            }
        }
        (images, masks)
    }

    /// Replaces a layer's pixels, keeping its file name in step.
    pub fn set_layer_image(&mut self, id: Uuid, image: Bitmap8) -> Option<Arc<Bitmap8>> {
        let layer = self.layer_mut(id)?;
        layer.image_file = Some(layer.expected_image_file());
        let previous = layer.image.replace(Arc::new(image));
        previous
    }

    /// Replaces a layer's mask.
    pub fn set_layer_mask(&mut self, id: Uuid, mask: Gray8) -> Option<Arc<Gray8>> {
        let layer = self.layer_mut(id)?;
        layer.mask_file = Some(layer.expected_mask_file());
        layer.mask_enabled = true;
        layer.mask.replace(Arc::new(mask))
    }

    /// Recomputes every layer's file names from its id, as a save does.
    pub fn refresh_asset_names(&mut self) {
        for layer in &mut self.layers {
            if layer.image.is_some() {
                layer.image_file = Some(layer.expected_image_file());
            }
            if layer.mask.is_some() {
                layer.mask_file = Some(layer.expected_mask_file());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adjustment::{Adjustment, AdjustmentKind};

    fn sample() -> Document {
        let mut document = Document::new(64, 48);
        let base = document.add_layer(Layer::raster("Base", 64, 48), None);
        let group = Layer::group("Folder", 64, 48);
        let group_id = group.id;
        document.add_layer(group, None);
        document.add_layer(Layer::raster("Inner", 64, 48), Some(group_id));
        document.add_layer(
            Layer::adjustment("Levels", Adjustment::new(AdjustmentKind::Levels), 64, 48),
            None,
        );
        document.active_layer = Some(base);
        document
    }

    #[test]
    fn subtree_stays_contiguous() {
        let mut document = sample();
        let group = document.layers.iter().find(|l| l.is_group).unwrap().id;
        document.add_layer(Layer::raster("Inner 2", 8, 8), Some(group));
        let indices = document.subtree_indices(group);
        assert_eq!(indices.len(), 3);
        assert_eq!(indices, (indices[0]..indices[0] + 3).collect::<Vec<_>>());
    }

    #[test]
    fn removing_a_group_removes_its_children() {
        let mut document = sample();
        let group = document.layers.iter().find(|l| l.is_group).unwrap().id;
        let removed = document.remove_layer(group);
        assert_eq!(removed.len(), 2);
        assert!(document.layers.iter().all(|l| l.parent != Some(group)));
    }

    #[test]
    fn effective_opacity_multiplies_through_groups() {
        let mut document = sample();
        let group = document.layers.iter().find(|l| l.is_group).unwrap().id;
        document.layer_mut(group).unwrap().opacity = 0.5;
        let inner = document.layers.iter().find(|l| l.name == "Inner").unwrap().id;
        document.layer_mut(inner).unwrap().opacity = 0.5;
        assert!((document.effective_opacity(inner) - 0.25).abs() < 1e-12);
    }

    #[test]
    fn hidden_group_hides_renderable_children() {
        let mut document = sample();
        let group = document.layers.iter().find(|l| l.is_group).unwrap().id;
        let inner = document.layers.iter().find(|l| l.name == "Inner").unwrap().id;
        assert!(document.renderable_ids().contains(&inner));
        document.layer_mut(group).unwrap().visible = false;
        assert!(!document.renderable_ids().contains(&inner));
    }

    #[test]
    fn move_layer_keeps_subtree_together() {
        let mut document = sample();
        let group = document.layers.iter().find(|l| l.is_group).unwrap().id;
        let count_before = document.layers.len();
        assert!(document.move_layer(group, 0));
        assert_eq!(document.layers.len(), count_before);
        assert_eq!(document.layers[0].id, group);
        assert_eq!(document.layers[1].parent, Some(group));
    }

    #[test]
    fn pixel_counts_add_up() {
        let mut document = Document::new(10, 10);
        let mut layer = Layer::raster("L", 10, 10);
        layer.image = Some(Arc::new(Bitmap8::new(10, 10)));
        layer.mask = Some(Arc::new(Gray8::filled(10, 10, 255)));
        document.add_layer(layer, None);
        assert_eq!(document.pixel_counts(), (100, 100));
    }
}
