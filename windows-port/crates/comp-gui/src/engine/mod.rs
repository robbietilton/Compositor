//! The adapter between the editor and the pixel engines.
//!
//! Compositing goes through comp-render, export through comp-io and painting through comp-brush, so
//! the canvas shows exactly what the CLI renders and the verification fixtures compare. Every panel
//! talks to the engines through this module.

pub mod paint;

pub use paint::{selection_mask, Stroke, StrokeProgress, StrokeSettings};

use comp_core::bitmap::Bitmap8;
use comp_core::document::Document;

/// A dirty rectangle in canvas pixels: origin, width, height.
pub type Bounds = (i64, i64, u32, u32);

/// Flattens a document for display.
///
/// Every call site goes through here, so a change of compositor is a change of one function body.
pub fn flatten_document(document: &Document) -> Bitmap8 {
    comp_render::flatten_document(document)
}

/// What this machine and this document allow the compositor to do.
pub fn availability(document: &Document) -> crate::backend::Availability {
    crate::backend::Availability {
        description: comp_render::gpu::describe(),
        reason: comp_render::gpu::unavailability().map(str::to_string),
        refused: comp_render::gpu::gpu_accepts(document).err(),
    }
}

/// Flattens the whole canvas with the backend the policy picks, and says which one ran.
///
/// The GPU path takes a document only when every layer maps onto what its shader does; when it
/// refuses, or when the device fails partway, the whole image goes to the CPU rather than mixing two
/// compositors in one picture. A stroke repaint never comes through here.
pub fn flatten_full(
    document: &Document,
    preference: crate::backend::Preference,
) -> (Bitmap8, crate::backend::Backend) {
    use crate::backend::{choose, Backend};
    let availability = availability(document);
    if choose(preference, false, &availability) == Backend::Cpu {
        return (flatten_document(document), Backend::Cpu);
    }
    match comp_render::gpu::flatten_document_gpu(document) {
        Some(bitmap) => (bitmap, Backend::Gpu),
        None => (flatten_document(document), Backend::Cpu),
    }
}

/// Flattens one region of a document, for a dirty-rectangle repaint.
///
/// comp-render does the work. Its region render pads the rectangle by the reach of the document's
/// blurs, keeps the seeded patterns (Grain, Add Noise) anchored to the document, and answers pixel
/// for pixel what cropping a whole-canvas render gives. All this adds is the clip to the canvas.
///
/// The translation this module used to do is gone: it cropped each layer to the rectangle first, so
/// a blur lost the halo it needed from outside and a seeded pattern restarted at the rectangle's
/// corner. The legacy module below keeps that code as the record of why, and the equivalence tests
/// use it to show the difference.
///
/// Returns None when the region misses the canvas entirely.
pub fn flatten_region(document: &Document, bounds: Bounds) -> Option<Bitmap8> {
    let region = clamp_bounds(bounds, document.width, document.height)?;
    Some(comp_render::flatten_region(document, region))
}

/// The region repaint this module used to do, kept as the record of why it was replaced.
///
/// It translated the document so that the region became the canvas and composited the whole thing,
/// cropped each layer to the rectangle first, then shifted everything onto the region's origin. That
/// is exact only while nothing reaches across the rectangle's edge and nothing is anchored to the
/// document's own pixels; the equivalence tests below show both halves of that.
#[cfg(test)]
mod legacy {
    use super::*;
    use comp_core::bitmap::Gray8;
    use comp_core::geom::{PointF, SizeF};
    use comp_core::layer::Layer;
    use std::collections::HashSet;
    use std::sync::Arc;
    use uuid::Uuid;

    /// What narrowing a layer to a region did.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    enum Narrowing {
        /// The layer cannot paint inside the region, so it is left out of the repaint entirely.
        Outside,
        /// The layer's source was cropped to the region.
        Cropped,
        /// The layer has to be placed whole; it stays correct but costs its full size.
        Whole,
    }

    /// The old entry point: translate the document onto the region and composite it whole.
    pub(super) fn flatten_region(document: &Document, bounds: Bounds) -> Option<Bitmap8> {
        let region = clamp_bounds(bounds, document.width, document.height)?;
        if region == (0, 0, document.width, document.height) {
            return Some(flatten_document(document));
        }
        // A layer another layer clips to must stay present, or the clip loses its base.
        let referenced: HashSet<Uuid> = document.layers.iter().filter_map(|layer| layer.mask_source).collect();
        let parents: HashSet<Uuid> = document.layers.iter().filter_map(|layer| layer.parent).collect();

        let mut shifted = document.clone();
        shifted.width = region.2;
        shifted.height = region.3;
        let mut narrowed = Vec::with_capacity(shifted.layers.len());
        for mut layer in shifted.layers.drain(..) {
            let protected = referenced.contains(&layer.id) || parents.contains(&layer.id);
            // Narrowing reads the layer's placement in document coordinates, so it runs before the
            // clone is shifted onto the region's origin.
            if narrow_layer(&mut layer, region, protected) == Narrowing::Outside {
                continue;
            }
            layer.transform.origin.x -= region.0 as f64;
            layer.transform.origin.y -= region.1 as f64;
            // An unlinked mask carries its own placement, which has to move with the layer.
            if let Some(placement) = layer.mask_placement.as_mut() {
                placement.origin.x -= region.0 as f64;
                placement.origin.y -= region.1 as f64;
            }
            narrowed.push(layer);
        }
        shifted.layers = narrowed;
        Some(flatten_document(&shifted))
    }

    /// Crops a layer's source down to the pixels the region can sample.
    fn narrow_layer(layer: &mut Layer, region: Bounds, protected: bool) -> Narrowing {
        if layer.is_group || layer.adjustment.is_some() || layer.effects.is_some() {
            return Narrowing::Whole;
        }
        let Some(image) = layer.image.as_deref() else { return Narrowing::Whole };
        let transform = layer.transform;
        let affine = transform.affine();
        let unit = 1e-9;
        if (affine.a - 1.0).abs() > unit
            || (affine.d - 1.0).abs() > unit
            || affine.b.abs() > unit
            || affine.c.abs() > unit
            || affine.tx.fract().abs() > unit
            || affine.ty.fract().abs() > unit
        {
            return Narrowing::Whole;
        }
        if (transform.size.width - image.width() as f64).abs() > unit
            || (transform.size.height - image.height() as f64).abs() > unit
        {
            return Narrowing::Whole;
        }
        let origin_x = affine.tx.round() as i64;
        let origin_y = affine.ty.round() as i64;
        let left = origin_x.max(region.0);
        let top = origin_y.max(region.1);
        let right = (origin_x + image.width() as i64).min(region.0 + region.2 as i64);
        let bottom = (origin_y + image.height() as i64).min(region.1 + region.3 as i64);
        if right <= left || bottom <= top {
            return if protected { Narrowing::Whole } else { Narrowing::Outside };
        }
        let source_x = (left - origin_x) as u32;
        let source_y = (top - origin_y) as u32;
        let width = (right - left) as u32;
        let height = (bottom - top) as u32;
        if width == image.width() && height == image.height() {
            return Narrowing::Whole;
        }
        let cropped_mask = match layer.mask.as_deref() {
            None => None,
            Some(mask) => {
                let follows_layer = !(layer.mask_placement.is_some() && !layer.mask_linked);
                if !layer.mask_enabled || !follows_layer {
                    return Narrowing::Whole;
                }
                if mask.width() != image.width() || mask.height() != image.height() {
                    return Narrowing::Whole;
                }
                Some(crop_gray(mask, source_x, source_y, width, height))
            }
        };
        layer.image = Some(Arc::new(image.subimage(source_x as i64, source_y as i64, width, height)));
        if let Some(mask) = cropped_mask {
            layer.mask = Some(Arc::new(mask));
        }
        layer.transform.origin = PointF::new(left as f64, top as f64);
        layer.transform.size = SizeF::new(width as f64, height as f64);
        Narrowing::Cropped
    }

    /// Copies a sub-rectangle of a mask; the caller guarantees the rectangle is inside it.
    fn crop_gray(mask: &Gray8, x: u32, y: u32, width: u32, height: u32) -> Gray8 {
        let mut cropped = Gray8::new(width, height);
        let source_stride = mask.width() as usize;
        let target_stride = width as usize;
        for row in 0..height as usize {
            let source_start = (y as usize + row) * source_stride + x as usize;
            let target_start = row * target_stride;
            cropped.pixels_mut()[target_start..target_start + target_stride]
                .copy_from_slice(&mask.pixels()[source_start..source_start + target_stride]);
        }
        cropped
    }
}

/// Clips a dirty rectangle to a canvas of this size; None when nothing of it is left.
pub fn clamp_bounds(bounds: Bounds, width: u32, height: u32) -> Option<Bounds> {
    if width == 0 || height == 0 || bounds.2 == 0 || bounds.3 == 0 {
        return None;
    }
    let x0 = bounds.0.max(0);
    let y0 = bounds.1.max(0);
    let x1 = (bounds.0.saturating_add(bounds.2 as i64)).min(width as i64);
    let y1 = (bounds.1.saturating_add(bounds.3 as i64)).min(height as i64);
    if x1 <= x0 || y1 <= y0 {
        return None;
    }
    Some((x0, y0, (x1 - x0) as u32, (y1 - y0) as u32))
}

/// The smallest rectangle covering both, for accumulating a frame's dirty areas.
pub fn union_bounds(current: Option<Bounds>, other: Bounds) -> Option<Bounds> {
    if other.2 == 0 || other.3 == 0 {
        return current;
    }
    match current {
        None => Some(other),
        Some((x, y, w, h)) => {
            let x0 = x.min(other.0);
            let y0 = y.min(other.1);
            let x1 = (x + w as i64).max(other.0 + other.2 as i64);
            let y1 = (y + h as i64).max(other.1 + other.3 as i64);
            Some((x0, y0, (x1 - x0) as u32, (y1 - y0) as u32))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use comp_core::bitmap::Gray8;
    use comp_core::blend::BlendMode;
    use comp_core::geom::{PointF, Sampling, SizeF};
    use comp_core::layer::Layer;
    use std::time::Instant;

    #[test]
    fn the_adapter_returns_a_canvas_sized_composite() {
        let document = comp_core::store::solid_document(9, 5, [7, 8, 9, 255]);
        let bitmap = flatten_document(&document);
        assert_eq!((bitmap.width(), bitmap.height()), (9, 5));
        assert_eq!(bitmap.get(4, 2), [7, 8, 9, 255]);
    }

    #[test]
    fn the_adapter_uses_the_shared_compositor_for_layer_order() {
        let mut document = comp_core::store::solid_document(4, 4, [255, 0, 0, 255]);
        document.add_layer(Layer::with_image("Top", Bitmap8::filled(4, 4, [0, 0, 255, 255])), None);
        assert_eq!(flatten_document(&document).get(1, 1), [0, 0, 255, 255]);
    }

    /// Reports where two composites differ without dumping megabytes of pixels.
    fn assert_same_pixels(label: &str, expected: &Bitmap8, actual: &Bitmap8) {
        assert_eq!(
            (actual.width(), actual.height()),
            (expected.width(), expected.height()),
            "{label}: size"
        );
        let mut differences = 0usize;
        let mut first: Option<(u32, u32, [u8; 4], [u8; 4])> = None;
        for y in 0..expected.height() {
            for x in 0..expected.width() {
                let want = expected.get(x, y);
                let got = actual.get(x, y);
                if want != got {
                    differences += 1;
                    if first.is_none() {
                        first = Some((x, y, want, got));
                    }
                }
            }
        }
        assert!(differences == 0, "{label}: {differences} pixel(s) differ, first at {first:?}");
    }

    /// A document with everything a region repaint could get wrong: whole-pixel layers (croppable),
    /// a scaled and rotated layer (not croppable), a mask, a blend mode, a clipping mask, a group
    /// with its own opacity, and a layer parked outside the canvas.
    fn varied_document() -> Document {
        let mut document = Document::new(64, 48);
        let mut base = Bitmap8::new(64, 48);
        for y in 0..48 {
            for x in 0..64 {
                base.set(x, y, [(x * 4) as u8, (y * 5) as u8, ((x + y) * 2) as u8, 255]);
            }
        }
        let base_id = document.add_layer(Layer::with_image("Base", base), None);

        let mut patch = Layer::with_image("Patch", Bitmap8::filled(16, 16, [200, 40, 40, 200]));
        patch.transform.origin = PointF::new(6.5, 9.25);
        patch.transform.size = SizeF::new(19.0, 13.0);
        patch.transform.rotation = 23.0;
        patch.transform.sampling = Sampling::HighQuality;
        patch.blend = BlendMode::Multiply;
        let patch_id = patch.id;
        document.add_layer(patch, None);
        document.set_layer_mask(patch_id, Gray8::filled(16, 16, 160));

        // A whole-pixel layer with a mask, which the region repaint crops.
        let mut masked = Layer::with_image("Masked", Bitmap8::filled(24, 24, [90, 30, 220, 255]));
        masked.transform.origin = PointF::new(30.0, 12.0);
        let masked_id = masked.id;
        document.add_layer(masked, None);
        let mut mask = Gray8::new(24, 24);
        for y in 0..24 {
            for x in 0..24 {
                mask.set(x, y, ((x * 10 + y * 3) % 256) as u8);
            }
        }
        document.set_layer_mask(masked_id, mask);

        // A layer clipped to the base layer's alpha.
        let mut clipped = Layer::with_image("Clipped", Bitmap8::filled(20, 20, [0, 200, 255, 180]));
        clipped.mask_source = Some(base_id);
        document.add_layer(clipped, None);

        let group = Layer::group("Folder", 64, 48);
        let group_id = group.id;
        document.add_layer(group, None);
        document.layer_mut(group_id).unwrap().opacity = 0.5;
        let mut inner = Layer::with_image("Inner", Bitmap8::filled(32, 32, [10, 220, 90, 255]));
        inner.transform.origin = PointF::new(20.0, 4.0);
        document.add_layer(inner, Some(group_id));

        // Entirely off-canvas: a region repaint may drop it, a full flatten never sees it.
        let mut outside = Layer::with_image("Outside", Bitmap8::filled(8, 8, [255, 255, 0, 255]));
        outside.transform.origin = PointF::new(200.0, 200.0);
        document.add_layer(outside, None);
        document
    }

    /// A document whose layers use the things a rectangle crop cannot see: a blur that reads past
    /// the rectangle, seeded patterns anchored to the document, a masked folder, a clip chain, a
    /// rotated and scaled layer, and a layer parked off the canvas.
    fn effect_document(kind: EffectCase) -> Document {
        use comp_core::adjustment::{Adjustment, AdjustmentKind};
        use comp_core::effects::LayerEffects;

        let mut document = Document::new(64, 48);
        let mut base = Bitmap8::new(64, 48);
        for y in 0..48 {
            for x in 0..64 {
                base.set(x, y, [(x * 4) as u8, (y * 5) as u8, ((x * 3 + y) % 251) as u8, 255]);
            }
        }
        let base_id = document.add_layer(Layer::with_image("Base", base), None);

        match kind {
            // A layer with an outer glow: the glow reaches past the layer's own pixels, so the
            // rectangle's edge has to sample it from outside.
            EffectCase::BlurEffect => {
                use comp_core::effects::OuterGlowEffect;
                let mut glowing = Layer::with_image("Glowing", Bitmap8::filled(24, 24, [220, 200, 40, 255]));
                glowing.transform.origin = PointF::new(18.0, 12.0);
                glowing.effects = Some(LayerEffects {
                    outer_glow: Some(OuterGlowEffect { enabled: Some(true), size: 14.0, ..Default::default() }),
                    ..Default::default()
                });
                document.add_layer(glowing, None);
            }
            // A gaussian blur adjustment: everything under it is blurred, so the rectangle's edge
            // samples have to come from outside the rectangle.
            EffectCase::BlurAdjustment => {
                let mut blur = Adjustment::new(AdjustmentKind::GaussianBlur);
                blur.blur_radius = Some(8.0);
                document.add_layer(Layer::adjustment("Blur", blur, 64, 48), None);
            }
            // Seeded patterns: the same document pixel must get the same grain in both renders.
            EffectCase::Grain => {
                let mut grain = Adjustment::new(AdjustmentKind::Grain);
                grain.grain_settings = Some(serde_json::json!({
                    "amount": 80.0,
                    "size": 1.5,
                    "roughness": 50.0,
                    "seed": 42
                }));
                document.add_layer(Layer::adjustment("Grain", grain, 64, 48), None);
            }
            EffectCase::Noise => {
                let mut noise = Adjustment::new(AdjustmentKind::AddNoise);
                noise.noise_amount = Some(90.0);
                noise.noise_gaussian = Some(false);
                noise.noise_seed = Some(7);
                document.add_layer(Layer::adjustment("Noise", noise, 64, 48), None);
            }
            // A folder with a mask, holding a layer that hangs over the rectangle's edge.
            EffectCase::MaskedFolder => {
                let folder = Layer::group("Folder", 64, 48);
                let folder_id = folder.id;
                document.add_layer(folder, None);
                let mut inner = Layer::with_image("Inner", Bitmap8::filled(40, 30, [10, 200, 120, 255]));
                inner.transform.origin = PointF::new(12.0, 8.0);
                document.add_layer(inner, Some(folder_id));
                let mut mask = Gray8::new(64, 48);
                for y in 0..48 {
                    for x in 0..64 {
                        mask.set(x, y, ((x * 7 + y * 5) % 256) as u8);
                    }
                }
                document.set_layer_mask(folder_id, mask);
            }
            // A chain: the base, a layer clipped to it, and a layer clipped to that one.
            EffectCase::ClipChain => {
                let mut clipped = Layer::with_image("Clipped", Bitmap8::filled(40, 40, [0, 180, 255, 220]));
                clipped.transform.origin = PointF::new(24.0, 6.0);
                clipped.mask_source = Some(base_id);
                let clipped_id = document.add_layer(clipped, None);
                let mut over = Layer::with_image("Over", Bitmap8::filled(30, 30, [255, 60, 60, 200]));
                over.transform.origin = PointF::new(30.0, 16.0);
                over.mask_source = Some(clipped_id);
                document.add_layer(over, None);
            }
            // Rotated and scaled: no whole-pixel crop is possible at all.
            EffectCase::Rotated => {
                let mut turned = Layer::with_image("Turned", Bitmap8::filled(30, 20, [140, 90, 240, 230]));
                turned.transform.origin = PointF::new(20.0, 10.0);
                turned.transform.size = SizeF::new(46.0, 31.0);
                turned.transform.rotation = 27.0;
                document.add_layer(turned, None);
            }
            // Off the canvas: a full render never sees it, a rectangle repaint must not either.
            EffectCase::OffCanvas => {
                let mut outside = Layer::with_image("Outside", Bitmap8::filled(12, 12, [255, 255, 0, 255]));
                outside.transform.origin = PointF::new(-30.0, 60.0);
                document.add_layer(outside, None);
                let mut grazing = Layer::with_image("Grazing", Bitmap8::filled(20, 20, [0, 255, 255, 128]));
                grazing.transform.origin = PointF::new(58.0, 40.0);
                document.add_layer(grazing, None);
            }
        }
        document
    }

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    enum EffectCase {
        BlurEffect,
        BlurAdjustment,
        Grain,
        Noise,
        MaskedFolder,
        ClipChain,
        Rotated,
        OffCanvas,
    }

    const CASES: [EffectCase; 8] = [
        EffectCase::BlurEffect,
        EffectCase::BlurAdjustment,
        EffectCase::Grain,
        EffectCase::Noise,
        EffectCase::MaskedFolder,
        EffectCase::ClipChain,
        EffectCase::Rotated,
        EffectCase::OffCanvas,
    ];

    /// A rectangle that sits inside the canvas but away from its edges, so every case crosses it.
    const REGION: (i64, i64, u32, u32) = (18, 14, 26, 20);

    #[test]
    fn a_region_repaint_is_exactly_the_cropped_full_render_for_every_hard_case() {
        for case in CASES {
            let document = effect_document(case);
            let full = flatten_document(&document);
            let cropped = full.subimage(REGION.0, REGION.1, REGION.2, REGION.3);
            let region = flatten_region(&document, REGION).expect("a region inside the canvas");
            assert_same_pixels(&format!("{case:?}"), &cropped, &region);
        }
    }

    #[test]
    fn a_region_repaint_is_exact_for_several_rectangles_at_once() {
        let document = effect_document(EffectCase::BlurAdjustment);
        let full = flatten_document(&document);
        for region in [(0, 0, 8, 6), (17, 13, 27, 21), (30, 25, 34, 23), (56, 40, 8, 8)] {
            let cropped = full.subimage(region.0, region.1, region.2, region.3);
            let repainted = flatten_region(&document, region).expect("a region inside the canvas");
            assert_same_pixels(&format!("blur adjustment {region:?}"), &cropped, &repainted);
        }
    }

    #[test]
    fn the_translate_and_composite_region_was_wrong_where_the_engine_reaches_across() {
        // The evidence for the rewrite: the old repaint cropped each layer to the rectangle and
        // composited a document whose canvas was the rectangle, so a blur lost the samples outside it
        // and a seeded pattern restarted at the rectangle's corner.
        for case in [EffectCase::BlurAdjustment, EffectCase::Grain, EffectCase::Noise] {
            let document = effect_document(case);
            let cropped = flatten_document(&document).subimage(REGION.0, REGION.1, REGION.2, REGION.3);
            let old = legacy::flatten_region(&document, REGION).expect("a region inside the canvas");
            let new = flatten_region(&document, REGION).expect("a region inside the canvas");
            // How wrong it was, in bytes, so the report has a number and a failure explains itself.
            let wrong = old
                .pixels()
                .iter()
                .zip(cropped.pixels())
                .filter(|(old, expected)| old != expected)
                .count();
            eprintln!(
                "{case:?}: the old repaint differed from the crop in {wrong} of {} bytes",
                cropped.pixels().len()
            );
            assert!(
                wrong > 0,
                "{case:?}: the old repaint was expected to disagree with the cropped full render"
            );
            assert_same_pixels(&format!("{case:?} with the region render"), &cropped, &new);
        }
    }

    #[test]
    fn the_old_region_repaint_agrees_only_while_nothing_reaches_across_the_edge() {
        // The same rectangle, on a document of plain whole-pixel layers: this is why the old code
        // looked right. It is the cases above that it could not do.
        let mut document = Document::new(64, 48);
        document.add_layer(Layer::with_image("A", Bitmap8::filled(64, 48, [30, 40, 50, 255])), None);
        let mut patch = Layer::with_image("B", Bitmap8::filled(20, 20, [200, 30, 30, 200]));
        patch.transform.origin = PointF::new(12.0, 12.0);
        document.add_layer(patch, None);
        let cropped = flatten_document(&document).subimage(REGION.0, REGION.1, REGION.2, REGION.3);
        let old = legacy::flatten_region(&document, REGION).expect("a region inside the canvas");
        assert_same_pixels("plain layers with the old repaint", &cropped, &old);
    }

    /// A document the GPU can take on its own: canvas-sized raster layers, a blend mode, a mask, a
    /// clip chain and a masked folder, with no transform, effect or adjustment.
    fn gpu_plain_document() -> Document {
        let mut document = Document::new(48, 32);
        let mut base = Bitmap8::new(48, 32);
        for y in 0..32 {
            for x in 0..48 {
                base.set(x, y, [(x * 5) as u8, (y * 7) as u8, ((x + y) * 3) as u8, 255]);
            }
        }
        let base_id = document.add_layer(Layer::with_image("Base", base), None);

        let mut top = Layer::with_image("Top", Bitmap8::filled(48, 32, [200, 60, 40, 180]));
        top.blend = BlendMode::Multiply;
        let top_id = document.add_layer(top, None);
        document.set_layer_mask(top_id, Gray8::filled(48, 32, 200));

        let mut clipped = Layer::with_image("Clipped", Bitmap8::filled(48, 32, [0, 180, 255, 220]));
        clipped.mask_source = Some(base_id);
        document.add_layer(clipped, None);

        let folder = Layer::group("Folder", 48, 32);
        let folder_id = folder.id;
        document.add_layer(folder, None);
        document.add_layer(
            Layer::with_image("Inner", Bitmap8::filled(48, 32, [10, 220, 120, 140])),
            Some(folder_id),
        );
        document.set_layer_mask(folder_id, Gray8::filled(48, 32, 180));
        document
    }

    /// The largest channel difference between two images of the same size.
    fn channel_difference(left: &Bitmap8, right: &Bitmap8) -> u8 {
        assert_eq!((left.width(), left.height()), (right.width(), right.height()), "size");
        left.pixels()
            .iter()
            .zip(right.pixels())
            .map(|(a, b)| a.abs_diff(*b))
            .max()
            .unwrap_or(0)
    }

    #[test]
    fn the_full_render_uses_the_backend_the_policy_picks() {
        let document = gpu_plain_document();
        let (_, forced) = flatten_full(&document, crate::backend::Preference::ForceCpu);
        assert_eq!(forced, crate::backend::Backend::Cpu, "forcing the CPU is obeyed");
        let (cpu, _) = flatten_full(&document, crate::backend::Preference::ForceCpu);
        assert_same_pixels("forced CPU against the plain compiler", &flatten_document(&document), &cpu);

        // Whatever the machine has, the preferred path answers with a canvas-sized image.
        let (preferred, backend) = flatten_full(&document, crate::backend::Preference::PreferGpu);
        assert_eq!((preferred.width(), preferred.height()), (48, 32));
        if !comp_render::gpu::available() {
            eprintln!("no GPU backend here; the preferred render fell back to the CPU");
            assert_eq!(backend, crate::backend::Backend::Cpu);
        }
    }

    #[test]
    fn a_gpu_render_matches_the_cpu_render_within_one_level() {
        let document = gpu_plain_document();
        let cpu = flatten_document(&document);
        let Some(gpu) = comp_render::gpu::flatten_document_gpu(&document) else {
            eprintln!("no GPU backend here; the GPU half of the consistency test is skipped");
            return;
        };
        let difference = channel_difference(&cpu, &gpu);
        assert!(difference <= 1, "the two compositors differ by {difference} levels, expected at most 1");
        assert!(
            comp_render::gpu::gpu_accepts(&document).is_ok(),
            "a document the GPU drew must be one it accepts"
        );
    }

    #[test]
    fn the_region_repaint_cross_checks_both_full_renders() {
        // A stroke repaints a rectangle on the CPU; a structural edit repaints everything, on the GPU
        // when there is one. Both have to describe the same picture.
        let document = gpu_plain_document();
        let region = (11, 7, 20, 14);
        let (cpu_full, _) = flatten_full(&document, crate::backend::Preference::ForceCpu);
        let repainted = flatten_region(&document, region).expect("a region inside the canvas");
        assert_same_pixels(
            "the rectangle against the cropped full render",
            &cpu_full.subimage(region.0, region.1, region.2, region.3),
            &repainted,
        );

        let Some(gpu_full) = comp_render::gpu::flatten_document_gpu(&document) else {
            eprintln!("no GPU backend here; the cross-check against the GPU is skipped");
            return;
        };
        let difference = channel_difference(
            &gpu_full.subimage(region.0, region.1, region.2, region.3),
            &repainted,
        );
        assert!(
            difference <= 1,
            "the stroke repaint and a GPU full render differ by {difference} levels"
        );
    }

    #[test]
    fn a_region_flatten_matches_the_cropped_full_flatten() {
        let document = varied_document();
        let full = flatten_document(&document);
        let regions: [(i64, i64, u32, u32); 8] = [
            (0, 0, 12, 9),
            (13, 7, 16, 9),
            (40, 30, 24, 18),
            (1, 1, 62, 46),
            (0, 0, 64, 48),
            (31, 23, 7, 5),
            (28, 10, 20, 20),
            (50, 40, 14, 8),
        ];
        for region in regions {
            let cropped = full.subimage(region.0, region.1, region.2, region.3);
            let flattened = flatten_region(&document, region).expect("a region inside the canvas");
            assert_eq!(
                (flattened.width(), flattened.height()),
                (region.2, region.3),
                "region {region:?} came back the wrong size"
            );
            assert_same_pixels(&format!("region {region:?}"), &cropped, &flattened);
        }
    }

    #[test]
    fn a_region_outside_the_canvas_is_clipped_or_skipped() {
        let document = varied_document();
        assert!(flatten_region(&document, (100, 100, 10, 10)).is_none());
        assert!(flatten_region(&document, (-40, 10, 30, 10)).is_none());
        assert!(flatten_region(&document, (0, 0, 0, 0)).is_none());
        let clipped = flatten_region(&document, (60, 44, 20, 20)).expect("the corner overlaps");
        assert_eq!((clipped.width(), clipped.height()), (4, 4));
        let full = flatten_document(&document);
        assert_same_pixels("corner", &full.subimage(60, 44, 4, 4), &clipped);
    }

    #[test]
    fn clamping_and_union_keep_dirty_rectangles_inside_the_canvas() {
        assert_eq!(clamp_bounds((-5, -5, 20, 20), 64, 48), Some((0, 0, 15, 15)));
        assert_eq!(clamp_bounds((10, 10, 100, 100), 64, 48), Some((10, 10, 54, 38)));
        assert_eq!(clamp_bounds((i64::MAX - 2, 0, 10, 10), 64, 48), None);
        assert_eq!(union_bounds(None, (4, 5, 6, 7)), Some((4, 5, 6, 7)));
        assert_eq!(union_bounds(Some((4, 5, 6, 7)), (0, 0, 0, 0)), Some((4, 5, 6, 7)));
        assert_eq!(union_bounds(Some((4, 5, 6, 7)), (8, 9, 4, 2)), Some((4, 5, 8, 7)));
    }

    #[test]
    fn a_region_repaint_costs_far_less_than_a_full_composite() {
        // A 128x128 dab region in a 2048x2048 canvas is 1/256 of the pixels; the margin below is
        // deliberately loose so a loaded machine still passes.
        let mut document = comp_core::store::solid_document(2048, 2048, [30, 40, 60, 255]);
        let mut top = Bitmap8::new(2048, 2048);
        for y in 0..2048 {
            for x in 0..2048 {
                top.set(x, y, [(x % 256) as u8, (y % 256) as u8, 128, 255]);
            }
        }
        document.add_layer(Layer::with_image("Top", top), None);

        let full_started = Instant::now();
        let full = flatten_document(&document);
        let full_micros = full_started.elapsed().as_micros().max(1);

        let region_started = Instant::now();
        let region = flatten_region(&document, (900, 900, 128, 128)).expect("a region");
        let region_micros = region_started.elapsed().as_micros().max(1);

        assert_same_pixels("benchmark region", &full.subimage(900, 900, 128, 128), &region);
        println!(
            "full 2048x2048: {full_micros} us, region 128x128: {region_micros} us, {:.1}x faster",
            full_micros as f64 / region_micros as f64
        );
        assert!(
            region_micros * 4 < full_micros,
            "a region repaint should be much cheaper: {region_micros} us vs {full_micros} us"
        );
    }
}
