//! Layer thumbnails: what a cached picture was built from, and which rows need a new one.
//!
//! The policy lives here rather than in the panel so the invalidation rules can be tested without a
//! window: a thumbnail is rebuilt when the layer's buffers change, when its mask changes, or when
//! the document revision moves on, and at most a couple per frame so a large document cannot stall.

use std::collections::HashMap;

use comp_core::bitmap::{Bitmap8, Gray8};
use comp_core::document::Document;
use comp_core::layer::Layer;
use uuid::Uuid;

/// The longest side of a row thumbnail, in pixels.
pub const THUMBNAIL_SIDE: u32 = 28;
/// The gap between the picture and its mask in a packed thumbnail.
pub const THUMBNAIL_GAP: u32 = 2;
/// How many thumbnails may be built in one frame.
pub const PER_FRAME: usize = 2;

/// What a cached thumbnail was built from.
///
/// The buffer addresses catch a replaced image or mask; the revision catches pixels edited in place,
/// which is what a brush stroke does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ThumbKey {
    pub image: usize,
    pub mask: usize,
    pub mask_enabled: bool,
    pub epoch: u64,
}

/// The key a layer's thumbnail would have now.
pub fn thumb_key(layer: &Layer, epoch: u64) -> ThumbKey {
    ThumbKey {
        image: layer.image.as_deref().map(|image| image.pixels().as_ptr() as usize).unwrap_or(0),
        mask: layer.mask.as_deref().map(|mask| mask.pixels().as_ptr() as usize).unwrap_or(0),
        mask_enabled: layer.mask_enabled,
        epoch,
    }
}

/// The layers whose cached picture is out of date, at most the budget allows, top of the stack
/// first so the rows the user is looking at refresh before the ones below them.
pub fn stale_layers(
    layers: &[Layer],
    epoch: u64,
    cached: &HashMap<Uuid, ThumbKey>,
    budget: usize,
) -> Vec<Uuid> {
    let mut stale = Vec::new();
    for layer in layers.iter().rev() {
        if stale.len() >= budget {
            break;
        }
        if !is_thumbnailable(layer) {
            continue;
        }
        if cached.get(&layer.id) != Some(&thumb_key(layer, epoch)) {
            stale.push(layer.id);
        }
    }
    stale
}

/// The picture a row shows: the layer, and beside it its mask when it has one.
pub fn thumbnail_for(layer: &Layer) -> Option<Bitmap8> {
    let image = layer.image.as_deref()?;
    let picture = image.thumbnail(THUMBNAIL_SIDE);
    let mask = layer.mask.as_deref().filter(|_| layer.mask_enabled).map(mask_thumbnail);
    Some(pack(&picture, mask.as_ref()))
}

/// A mask small enough for a row, as opaque gray so the panel can draw it like any other picture.
pub fn mask_thumbnail(mask: &Gray8) -> Bitmap8 {
    if mask.is_empty() {
        return Bitmap8::new(0, 0);
    }
    let scale = THUMBNAIL_SIDE as f64 / mask.width().max(mask.height()) as f64;
    let width = ((mask.width() as f64 * scale).round() as u32).clamp(1, THUMBNAIL_SIDE);
    let height = ((mask.height() as f64 * scale).round() as u32).clamp(1, THUMBNAIL_SIDE);
    let small = mask.resized_bilinear(width, height);
    crate::engine::paint::mask_to_scratch(&small)
}

/// Puts the picture and its mask side by side in a row-height tile, centered vertically so a wide
/// layer and a tall one still line up with each other in the list.
pub fn pack(picture: &Bitmap8, mask: Option<&Bitmap8>) -> Bitmap8 {
    let width = match mask {
        Some(mask) => picture.width() + THUMBNAIL_GAP + mask.width(),
        None => picture.width(),
    };
    let mut packed = Bitmap8::new(width.max(1), THUMBNAIL_SIDE);
    let top = (THUMBNAIL_SIDE.saturating_sub(picture.height())) / 2;
    for y in 0..picture.height().min(THUMBNAIL_SIDE - top) {
        for x in 0..picture.width().min(packed.width()) {
            packed.set(x, top + y, picture.get(x, y));
        }
    }
    if let Some(mask) = mask {
        let offset = picture.width() + THUMBNAIL_GAP;
        let mask_top = (THUMBNAIL_SIDE.saturating_sub(mask.height())) / 2;
        for y in 0..mask.height().min(THUMBNAIL_SIDE - mask_top) {
            for x in 0..mask.width() {
                let target = offset + x;
                if target < packed.width() {
                    packed.set(target, mask_top + y, mask.get(x, y));
                }
            }
        }
    }
    packed
}

/// True when a layer has anything worth showing in a row.
pub fn is_thumbnailable(layer: &Layer) -> bool {
    !layer.is_group && layer.adjustment.is_none() && layer.image.is_some()
}

/// The document's layers that a panel would show a thumbnail for.
pub fn thumbnailable(document: &Document) -> Vec<Uuid> {
    document.layers.iter().filter(|layer| is_thumbnailable(layer)).map(|layer| layer.id).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    fn layer_with(image: Bitmap8) -> Layer {
        Layer::with_image("Row", image)
    }

    #[test]
    fn the_key_changes_when_the_pixels_the_mask_or_the_revision_change() {
        let mut layer = layer_with(Bitmap8::filled(8, 8, [1, 2, 3, 255]));
        let first = thumb_key(&layer, 1);
        assert_eq!(first, thumb_key(&layer, 1));
        assert_ne!(first, thumb_key(&layer, 2), "a new revision is a new key");

        layer.image = Some(Arc::new(Bitmap8::filled(8, 8, [9, 9, 9, 255])));
        let replaced = thumb_key(&layer, 1);
        assert_ne!(first, replaced, "a replaced buffer is a new address");

        layer.mask = Some(Arc::new(Gray8::filled(8, 8, 255)));
        let masked = thumb_key(&layer, 1);
        assert_ne!(replaced, masked, "a mask changes the picture");
        layer.mask_enabled = false;
        assert_ne!(masked, thumb_key(&layer, 1), "switching the mask off changes the picture again");
    }

    #[test]
    fn stale_layers_are_reported_top_first_and_within_the_budget() {
        let mut document = Document::new(16, 16);
        document.add_layer(Layer::with_image("Bottom", Bitmap8::filled(16, 16, [1, 1, 1, 255])), None);
        document.add_layer(Layer::group("Folder", 16, 16), None);
        document.add_layer(Layer::with_image("Top", Bitmap8::filled(16, 16, [2, 2, 2, 255])), None);
        let mut cached = HashMap::new();

        let stale = stale_layers(&document.layers, 1, &cached, 8);
        assert_eq!(stale.len(), 2, "the group has no pixels to show");
        assert_eq!(stale[0], document.layers[2].id, "the top row refreshes first");
        assert_eq!(stale[1], document.layers[0].id);

        let budgeted = stale_layers(&document.layers, 1, &cached, 1);
        assert_eq!(budgeted.len(), 1);
        assert_eq!(budgeted[0], document.layers[2].id);

        for id in &stale {
            let layer = document.layer(*id).unwrap();
            cached.insert(*id, thumb_key(layer, 1));
        }
        assert!(stale_layers(&document.layers, 1, &cached, 8).is_empty(), "everything is cached");
        assert_eq!(stale_layers(&document.layers, 2, &cached, 8).len(), 2, "a new revision invalidates");
    }

    #[test]
    fn a_thumbnail_keeps_the_picture_small_enough_for_a_row() {
        let layer = layer_with(Bitmap8::filled(400, 200, [10, 20, 30, 255]));
        let picture = thumbnail_for(&layer).expect("a picture");
        assert!(picture.width() <= THUMBNAIL_SIDE);
        assert_eq!(picture.height(), THUMBNAIL_SIDE, "the tile is row height");
        assert!(picture.width() > 0);
        // A 2:1 layer is centered, so the picture sits in the middle band of the tile.
        let top = (THUMBNAIL_SIDE - 14) / 2;
        assert_eq!(picture.get(2, top + 2), [10, 20, 30, 255]);
        assert_eq!(picture.get(2, 0), [0, 0, 0, 0]);
    }

    #[test]
    fn packing_puts_the_mask_beside_the_picture() {
        let picture = Bitmap8::filled(10, 6, [200, 100, 50, 255]);
        let mask = Bitmap8::filled(4, 6, [255, 255, 255, 255]);
        let packed = pack(&picture, Some(&mask));
        assert_eq!(packed.width(), 10 + THUMBNAIL_GAP + 4);
        assert_eq!(packed.height(), THUMBNAIL_SIDE, "every row is the same height");
        // A six-pixel-tall picture is centered in the tile.
        let top = (THUMBNAIL_SIDE - 6) / 2;
        assert_eq!(packed.get(0, top), [200, 100, 50, 255], "the picture stays on the left");
        assert_eq!(packed.get(0, 0), [0, 0, 0, 0], "above it the tile is empty");
        assert_eq!(packed.get(10, top), [0, 0, 0, 0], "the gap is transparent");
        assert_eq!(packed.get(12, top), [255, 255, 255, 255], "the mask follows the gap");
        assert_eq!(packed.get(13, top + 5), [255, 255, 255, 255]);

        let alone = pack(&picture, None);
        assert_eq!(alone.width(), 10);
        assert_eq!(alone.get(9, top + 5), [200, 100, 50, 255]);
    }

    #[test]
    fn a_mask_thumbnail_is_opaque_gray_and_fits_a_row() {
        let mut mask = Gray8::new(64, 32);
        for y in 0..32 {
            for x in 0..64 {
                mask.set(x, y, if x < 32 { 0 } else { 255 });
            }
        }
        let thumb = mask_thumbnail(&mask);
        assert!(thumb.width() <= THUMBNAIL_SIDE && thumb.height() <= THUMBNAIL_SIDE);
        assert_eq!(thumb.get(0, 0), [0, 0, 0, 255], "a hidden area reads black");
        let right = thumb.width() - 1;
        assert_eq!(thumb.get(right, 0), [255, 255, 255, 255], "a shown area reads white");
    }

    #[test]
    fn empty_masks_and_pixel_free_layers_have_nothing_to_show() {
        assert!(mask_thumbnail(&Gray8::new(0, 0)).is_empty());
        let mut layer = Layer::raster("Empty", 8, 8);
        layer.image = None;
        assert!(thumbnail_for(&layer).is_none());
        assert!(!is_thumbnailable(&layer));
        assert!(is_thumbnailable(&layer_with(Bitmap8::filled(4, 4, [0, 0, 0, 255]))));
    }

    #[test]
    fn only_layers_with_pixels_are_listed_for_thumbnails() {
        let mut document = Document::new(8, 8);
        document.add_layer(Layer::with_image("Pixels", Bitmap8::filled(8, 8, [1, 1, 1, 255])), None);
        document.add_layer(Layer::group("Folder", 8, 8), None);
        document.add_layer(Layer::raster("Empty", 8, 8), None);
        let listed = thumbnailable(&document);
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0], document.layers[0].id);
    }
}
