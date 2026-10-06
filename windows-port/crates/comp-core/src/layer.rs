//! The layer record: a raster (or group, or adjustment) with its transform, mask and metadata.
use std::sync::Arc;

use uuid::Uuid;

use crate::adjustment::Adjustment;
use crate::bitmap::{Bitmap8, Gray8};
use crate::blend::BlendMode;
use crate::effects::LayerEffects;
use crate::geom::Transform;
use crate::shape::ShapeStyle;
use crate::text::TextStyle;

/// What a layer holds. Groups and adjustment layers have no pixels of their own.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LayerKind {
    /// Pixels, possibly with text or shape metadata.
    Raster,
    Group,
    Adjustment,
}

/// One layer, in the document's bottom-to-top order.
///
/// Pixels are shared through `Arc` so snapshots for undo never copy them.
#[derive(Clone, Debug)]
pub struct Layer {
    pub id: Uuid,
    pub name: String,
    pub visible: bool,
    /// The group this layer sits in; root layers have none.
    pub parent: Option<Uuid>,
    pub is_group: bool,
    /// 0 to 1. A folder's opacity multiplies into everything inside it.
    pub opacity: f64,
    /// Folders are pass-through, so their blend mode stays Normal.
    pub blend: BlendMode,
    pub transform: Transform,
    /// Layer pixels. Groups and adjustment layers have none.
    pub image: Option<Arc<Bitmap8>>,
    /// The image's file name inside `images/`, always `<id>.png`.
    pub image_file: Option<String>,
    /// The layer's own raster mask.
    pub mask: Option<Arc<Gray8>>,
    /// Always `<id>.mask.png`.
    pub mask_file: Option<String>,
    /// A disabled mask stays embedded and editable but does not composite.
    pub mask_enabled: bool,
    /// The layer whose live alpha clips this one (a clipping mask).
    pub mask_source: Option<Uuid>,
    /// Where an unlinked mask sits; `None` means the mask follows the layer.
    pub mask_placement: Option<Transform>,
    /// Missing means linked.
    pub mask_linked: bool,
    pub adjustment: Option<Adjustment>,
    pub effects: Option<LayerEffects>,
    pub text: Option<TextStyle>,
    pub shape: Option<ShapeStyle>,
}

impl Layer {
    /// A transparent raster layer covering the whole canvas.
    pub fn raster(name: impl Into<String>, width: u32, height: u32) -> Self {
        Layer {
            id: Uuid::new_v4(),
            name: name.into(),
            visible: true,
            parent: None,
            is_group: false,
            opacity: 1.0,
            blend: BlendMode::Normal,
            transform: Transform::full_canvas(width, height),
            image: None,
            image_file: None,
            mask: None,
            mask_file: None,
            mask_enabled: true,
            mask_source: None,
            mask_placement: None,
            mask_linked: true,
            adjustment: None,
            effects: None,
            text: None,
            shape: None,
        }
    }

    /// A raster layer holding these pixels, placed at the origin.
    pub fn with_image(name: impl Into<String>, image: Bitmap8) -> Self {
        let mut layer = Layer::raster(name, image.width(), image.height());
        layer.image_file = Some(format!("{}.png", layer.id.to_string().to_uppercase()));
        layer.image = Some(Arc::new(image));
        layer
    }

    pub fn group(name: impl Into<String>, width: u32, height: u32) -> Self {
        let mut layer = Layer::raster(name, width, height);
        layer.is_group = true;
        layer.image_file = None;
        layer
    }

    pub fn adjustment(name: impl Into<String>, adjustment: Adjustment, width: u32, height: u32) -> Self {
        let mut layer = Layer::raster(name, width, height);
        layer.adjustment = Some(adjustment);
        layer.image_file = None;
        layer
    }

    pub fn kind(&self) -> LayerKind {
        if self.is_group {
            LayerKind::Group
        } else if self.adjustment.is_some() {
            LayerKind::Adjustment
        } else {
            LayerKind::Raster
        }
    }

    /// The mask's placement: its own when unlinked, the layer's when linked.
    pub fn effective_mask_transform(&self) -> Option<Transform> {
        if self.mask.is_none() && self.mask_file.is_none() {
            return None;
        }
        match self.mask_placement {
            Some(placement) if !self.mask_linked => Some(placement),
            _ => Some(self.transform),
        }
    }

    /// The file name a save would use for this layer's pixels.
    pub fn expected_image_file(&self) -> String {
        format!("{}.png", self.id.to_string().to_uppercase())
    }

    /// The file name a save would use for this layer's mask.
    pub fn expected_mask_file(&self) -> String {
        format!("{}.mask.png", self.id.to_string().to_uppercase())
    }

    /// True when the layer keeps text metadata that a save must round-trip.
    pub fn has_text(&self) -> bool {
        self.text.is_some()
    }

    /// True when this layer contributes pixels that a compositor must draw.
    pub fn has_pixels(&self) -> bool {
        self.image.is_some()
    }
}

impl PartialEq for Layer {
    /// Identity and metadata; pixel buffers compare by pointer for speed.
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
            && self.name == other.name
            && self.visible == other.visible
            && self.parent == other.parent
            && self.is_group == other.is_group
            && self.opacity == other.opacity
            && self.blend == other.blend
            && self.transform == other.transform
            && self.image_file == other.image_file
            && self.mask_file == other.mask_file
            && self.mask_enabled == other.mask_enabled
            && self.mask_source == other.mask_source
            && self.mask_linked == other.mask_linked
            && self.adjustment == other.adjustment
            && self.effects == other.effects
            && self.text == other.text
            && self.shape == other.shape
            && match (&self.image, &other.image) {
                (None, None) => true,
                (Some(a), Some(b)) => Arc::ptr_eq(a, b) || a == b,
                _ => false,
            }
            && match (&self.mask, &other.mask) {
                (None, None) => true,
                (Some(a), Some(b)) => Arc::ptr_eq(a, b) || a == b,
                _ => false,
            }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raster_layer_has_expected_file_names() {
        let layer = Layer::raster("Background", 100, 50);
        assert_eq!(layer.expected_image_file(), format!("{}.png", layer.id.to_string().to_uppercase()));
        assert_eq!(
            layer.expected_mask_file(),
            format!("{}.mask.png", layer.id.to_string().to_uppercase())
        );
        assert!(!layer.has_pixels());
        assert_eq!(layer.kind(), LayerKind::Raster);
    }

    #[test]
    fn group_and_adjustment_report_their_kind() {
        let group = Layer::group("Folder", 10, 10);
        assert_eq!(group.kind(), LayerKind::Group);
        let adjustment = Layer::adjustment(
            "Levels",
            Adjustment::new(crate::adjustment::AdjustmentKind::Levels),
            10,
            10,
        );
        assert_eq!(adjustment.kind(), LayerKind::Adjustment);
    }

    #[test]
    fn unlinked_mask_keeps_its_own_placement() {
        let mut layer = Layer::raster("L", 100, 100);
        layer.mask = Some(Arc::new(Gray8::filled(100, 100, 255)));
        let mut placement = Transform::with_size(50.0, 50.0);
        placement.origin = crate::geom::PointF::new(25.0, 25.0);
        layer.mask_placement = Some(placement);
        layer.mask_linked = false;
        assert_eq!(layer.effective_mask_transform(), Some(placement));
        layer.mask_linked = true;
        assert_eq!(layer.effective_mask_transform(), Some(layer.transform));
    }
}
