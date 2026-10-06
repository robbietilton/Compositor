//! The compositing pipeline: what `flatten_document` and the editor's canvas both run.
//!
//! The order of operations is the macOS original's (see `LiveMaskRenderer` and `LiveLayerMask.swift`):
//! layers composite bottom to top; a group is pass-through, so it never blends on its own and its opacity
//! is multiplied into each of its children; every layer's mask, its folders' masks and its opacity all
//! land on its alpha.
//!
//! A layer that names a clipping base has its alpha multiplied by that base's coverage: the base's placed
//! pixels, times the base's raster mask, times the base's *effective* opacity (its own and every enclosing
//! folder's), and then by the coverage of whatever clips the base in turn. Visibility and color never
//! contribute - only coverage. `LiveMaskRenderer.swift` states it outright: "Coverage uses source alpha
//! including its own masks, independent of source visibility and color."

use std::collections::{HashMap, HashSet};

use uuid::Uuid;

use comp_core::adjustment::{Adjustment, AdjustmentKind};
use comp_core::geom::Transform;
use comp_core::{Bitmap8, BlendMode, Document, Layer};

use crate::effects;
use crate::blend::{composite_box, composite_surface, copy_box, Box};
use crate::pixel::{pixel_bounds, Plane, Surface};
use crate::place::{
    mask_into_grid, paint_bitmap_box, place_bitmap_box, place_coverage, place_coverage_box, place_surface_box,
};

/// The most layers the clipping walk follows before giving up on a cycle.
const MAX_CLIP_DEPTH: usize = 256;

/// A rectangle of the canvas, in document pixels: (x, y, width, height).
pub type Region = Box;

/// Composites the whole document into one straight-alpha bitmap the size of the canvas.
///
/// A document with no layers, no pixels, or every layer hidden comes back fully transparent rather than
/// failing, because the CLI, the exporter and the editor all draw through here.
pub fn flatten_document(document: &Document) -> Bitmap8 {
    flatten_region(document, (0, 0, document.width, document.height))
}

/// Composites one rectangle of the document: pixel for pixel what flatten_document would give, cropped to
/// the rectangle. A pixel of the rectangle that lies off the canvas comes back clear.
///
/// The point is cost. A dirty rectangle of a 4000 x 4000 canvas is a few hundred pixels across, and
/// nothing outside it needs to be touched - except in two places, which are handled rather than ignored:
///
/// - The blurs read their neighbours. Their reach is added to the rectangle before rendering and cropped
///   away afterwards, so a blurred adjustment layer sees every sample a whole-canvas render would have
///   given it.
/// - The seeded patterns (Grain, Add Noise) are anchored to the document, so the rectangle tells the
///   kernel where it sits; otherwise the grain would restart at the rectangle's corner.
///
/// A layer that lands on whole pixels, unrotated and unscaled, is copied row by row, and a fully opaque one
/// in Normal mode replaces what is under it, so the common case is a memcpy rather than a blend.
pub fn flatten_region(document: &Document, bounds: Region) -> Bitmap8 {
    if document.width == 0 || document.height == 0 || bounds.2 == 0 || bounds.3 == 0 {
        return Bitmap8::new(bounds.2, bounds.3);
    }
    // The rectangle the render covers: the one asked for, padded by the reach of the document's blurs.
    let halo = adjustment_reach(document);
    let padded = (
        bounds.0 - halo,
        bounds.1 - halo,
        bounds.2.saturating_add((2 * halo) as u32),
        bounds.3.saturating_add((2 * halo) as u32),
    );
    let Some(padded) = clamp_region(padded, document.width, document.height) else {
        return Bitmap8::new(bounds.2, bounds.3);
    };
    let mut renderer = Renderer::new(document, padded);
    renderer.render();
    // Crop the padded render back to the rectangle that was asked for, leaving the rest clear. The crop
    // goes through a surface and then a bitmap because the canvas holds premultiplied bytes and the answer
    // is straight alpha: copying the canvas out directly would hand back premultiplied color.
    let mut cropped = Surface::new(bounds.2, bounds.3);
    let canvas = renderer.canvas;
    for row in 0..bounds.3 as i64 {
        let y = bounds.1 + row;
        if y < padded.1 || y >= padded.1 + padded.3 as i64 {
            continue;
        }
        let first = bounds.0.max(padded.0);
        let last = (bounds.0 + bounds.2 as i64).min(padded.0 + padded.2 as i64);
        if last <= first {
            continue;
        }
        let source = ((y - padded.1) as usize * padded.2 as usize + (first - padded.0) as usize) * 4;
        let destination = (row as usize * bounds.2 as usize + (first - bounds.0) as usize) * 4;
        let bytes = (last - first) as usize * 4;
        cropped.pixels_mut()[destination..destination + bytes]
            .copy_from_slice(&canvas.pixels()[source..source + bytes]);
    }
    cropped.to_bitmap()
}

/// Composites one layer on its own, as it would appear with nothing under it: its pixels through its own
/// mask and opacity, its effects, its clipping link and its folders' masks.
pub fn flatten_layer(document: &Document, id: Uuid) -> Option<Bitmap8> {
    if document.width == 0 || document.height == 0 {
        return None;
    }
    let frame = (0, 0, document.width, document.height);
    let mut renderer = Renderer::new(document, frame);
    let layer = document.layer(id)?;
    let box_ = renderer.box_of(layer)?;
    let mut drawn = renderer.live_into(layer, box_)?;
    renderer.clip_by_folders(layer, &mut drawn, box_);
    // Through a surface and then a bitmap: the layer's pixels are premultiplied, and the answer is not.
    let mut placed = Surface::new(document.width, document.height);
    for row in 0..box_.3 as i64 {
        let y = box_.1 + row;
        if y < 0 || y >= document.height as i64 {
            continue;
        }
        let first = box_.0.max(0);
        let last = (box_.0 + box_.2 as i64).min(document.width as i64);
        if last <= first {
            continue;
        }
        let source = (row as usize * box_.2 as usize + (first - box_.0) as usize) * 4;
        let destination = (y as usize * document.width as usize + first as usize) * 4;
        let bytes = (last - first) as usize * 4;
        placed.pixels_mut()[destination..destination + bytes]
            .copy_from_slice(&drawn.image.pixels()[source..source + bytes]);
    }
    Some(placed.to_bitmap())
}

/// The intersection of a rectangle with a canvas, or nothing when they do not meet.
fn clamp_region(region: Region, width: u32, height: u32) -> Option<Region> {
    let x0 = region.0.max(0);
    let y0 = region.1.max(0);
    let x1 = region.0.saturating_add(region.2 as i64).min(width as i64);
    let y1 = region.1.saturating_add(region.3 as i64).min(height as i64);
    if x1 <= x0 || y1 <= y0 {
        return None;
    }
    Some((x0, y0, (x1 - x0) as u32, (y1 - y0) as u32))
}

/// How far past a rectangle the document's blurs read, which is how much padding an exact region render
/// needs.
///
/// Every blur adds its own reach, because they stack: the second blur's samples must see the first blur's
/// output, which itself reaches outward. Everything else in adjustment.rs is per-pixel, and the two seeded
/// patterns are told where they are instead.
fn adjustment_reach(document: &Document) -> i64 {
    let mut reach = 0i64;
    for id in document.renderable_ids() {
        let Some(layer) = document.layer(id) else { continue };
        let Some(adjustment) = layer.adjustment.as_ref() else { continue };
        // An adjustment clipped to another layer is skipped by the renderer, so it reaches nothing.
        if layer.mask_source.is_some() {
            continue;
        }
        reach += match adjustment.kind {
            AdjustmentKind::GaussianBlur => {
                let radius = adjustment.blur_radius.unwrap_or(10.0).clamp(0.1, 250.0);
                (radius * 3.0).ceil() as i64 + 1
            }
            AdjustmentKind::MotionBlur => {
                let distance = adjustment.motion_distance.unwrap_or(10.0).clamp(1.0, 2000.0);
                (distance / 2.0).ceil() as i64 + 2
            }
            _ => 0,
        };
    }
    reach
}

/// The document rectangle a layer's pixels land in, so an editor can redraw only what changed. A group
/// or a layer with no pixels reports nothing.
pub fn layer_bounds(document: &Document, id: Uuid) -> Option<(i64, i64, u32, u32)> {
    let layer = document.layer(id)?;
    if layer.is_group || layer.image.is_none() {
        return None;
    }
    let renderer = Renderer::new(document, (0, 0, document.width, document.height));
    renderer.box_of(layer)
}

/// One layer drawn into a box: its pixels, and whether they cover the box completely - which lets the
/// composite copy instead of blend.
struct Drawn {
    image: Surface,
    opaque: bool,
}

/// The compositor's state for one render: the rectangle of the canvas it covers, and the canvas for it.
struct Renderer<'a> {
    document: &'a Document,
    /// The rectangle being rendered, in document pixels.
    frame: Region,
    /// The frame's pixels, at the frame's own size.
    canvas: Surface,
    /// A frame-sized coverage plane, reused by the adjustment path.
    coverage: Plane,
    by_id: HashMap<Uuid, usize>,
    order: Vec<Uuid>,
    /// The clipping coverage walk's cycle guard.
    visiting: HashSet<Uuid>,
}

impl<'a> Renderer<'a> {
    fn new(document: &'a Document, frame: Region) -> Renderer<'a> {
        let by_id = document
            .layers
            .iter()
            .enumerate()
            .map(|(index, layer)| (layer.id, index))
            .collect();
        let order = document.renderable_ids();
        Renderer {
            document,
            frame,
            canvas: Surface::new(frame.2, frame.3),
            coverage: Plane::new(frame.2, frame.3),
            by_id,
            order,
            visiting: HashSet::new(),
        }
    }

    fn layer(&self, id: Uuid) -> Option<&'a Layer> {
        self.by_id.get(&id).map(|index| &self.document.layers[*index])
    }

    /// A document-space transform in the frame's own coordinates.
    fn local(&self, transform: &Transform) -> Transform {
        let mut local = *transform;
        local.origin.x -= self.frame.0 as f64;
        local.origin.y -= self.frame.1 as f64;
        local
    }

    /// The transform a layer's pixels are placed with, effects included: an effect grows the surface it
    /// draws on and the transform grows with it, so the layer still lands where it did.
    fn effective_transform(&self, layer: &Layer, width: u32, height: u32) -> Transform {
        let transform = self.local(&layer.transform);
        let Some(effects) = layer.effects else { return transform };
        let visible = effects::visible(&effects);
        if visible.is_empty() {
            return transform;
        }
        let inset = effects::margin(&visible);
        grown_transform(&transform, width + inset * 2, height + inset * 2, inset)
    }

    /// Where a layer lands inside the frame, or nothing when it misses the frame entirely.
    fn box_of(&self, layer: &Layer) -> Option<Region> {
        let image = layer.image.as_ref()?;
        let transform = self.effective_transform(layer, image.width(), image.height());
        pixel_bounds(&transform, self.frame.2, self.frame.3)
    }

    fn render(&mut self) {
        let order = self.order.clone();
        for id in order {
            let Some(layer) = self.layer(id) else { continue };
            if let Some(adjustment) = layer.adjustment.clone() {
                // An adjustment that names a clipping base is skipped, as the original's CPU path skips it
                // when it has a source (LiveMaskRenderer.drawComposite).
                if layer.mask_source.is_some() {
                    continue;
                }
                self.adjust(layer, &adjustment, true);
                continue;
            }
            let Some(box_) = self.box_of(layer) else { continue };
            // The common case - no mask, no clipping, no effects - is painted straight into the canvas
            // from the layer's own pixels, with no surface in between. Everything else builds the layer's
            // image first, because a mask or a clipping link has to land on it before it composites.
            if self.is_plain(layer) {
                if let Some(image) = layer.image.as_ref() {
                    let opacity = self.document.effective_opacity(layer.id) as f32;
                    let transform = self.local(&layer.transform);
                    if paint_bitmap_box(&mut self.canvas, image, &transform, layer.blend, opacity).is_some() {
                        continue;
                    }
                }
            }
            let Some(mut drawn) = self.live_into(layer, box_) else { continue };
            self.clip_by_folders(layer, &mut drawn, box_);
            // A fully opaque layer in Normal mode replaces what is under it, byte for byte.
            if drawn.opaque && layer.blend == BlendMode::Normal {
                copy_box(&mut self.canvas, &drawn.image, box_);
            } else {
                composite_box(&mut self.canvas, &drawn.image, layer.blend, box_);
            }
        }
    }

    /// Whether a layer needs no surface of its own: no effects, no raster mask, no clipping link and no
    /// folder above it with a mask. Such a layer is just its pixels, placed and blended.
    fn is_plain(&self, layer: &Layer) -> bool {
        if layer.effects.is_some() && !effects::visible(&layer.effects.unwrap()).is_empty() {
            return false;
        }
        if self.enabled_mask(layer).is_some() || layer.mask_source.is_some() {
            return false;
        }
        let mut folder = layer.parent;
        let mut depth = 0;
        while let Some(id) = folder {
            if depth >= 64 {
                break;
            }
            let Some(group) = self.layer(id) else { break };
            if self.enabled_mask(group).is_some() {
                return false;
            }
            folder = group.parent;
            depth += 1;
        }
        true
    }

    /// Everything a layer draws inside `box_`: its pixels placed densely in that box, through its mask,
    /// its effects and its opacity (which already carries every enclosing folder's).
    fn own_into(&mut self, layer: &Layer, box_: Region) -> Option<Drawn> {
        let image = layer.image.as_ref()?;
        let opacity = self.document.effective_opacity(layer.id) as f32;
        let mask = self.enabled_mask(layer);
        let visible_effects = layer.effects.map(|effects| effects::visible(&effects)).unwrap_or_default();
        // A layer that lands on whole pixels is copied straight out of its bitmap. Anything else - a
        // scale, a rotation, a flip - premultiplies the layer once and resamples it, which is the general
        // path and costs the layer's own size rather than the box's.
        let fast = if visible_effects.is_empty() {
            place_bitmap_box(image, &self.local(&layer.transform), box_)
        } else {
            None
        };
        if let Some((mut placed, placed_opaque)) = fast {
            let mut opaque = placed_opaque;
            if let Some(mask) = mask {
                let transform = self.local(&layer.effective_mask_transform().unwrap_or(layer.transform));
                if let Some(plane) = place_coverage_box(mask, &transform, box_) {
                    placed.mask_by_plane(&plane);
                    opaque = false;
                }
            }
            if opacity < 1.0 {
                opaque = false;
            }
            placed.scale_alpha(opacity);
            return Some(Drawn { image: placed, opaque });
        }
        let source = Surface::from_bitmap(image);
        if !visible_effects.is_empty() {
            // Effects follow the shape that is actually shown, so the mask goes on first, in the layer's
            // own pixel grid - the original hands `LayerEffectsRenderer` the masked pixels too.
            let shaped = match mask {
                Some(mask) => {
                    let grid = mask_into_grid(
                        mask,
                        &layer.effective_mask_transform().unwrap_or(layer.transform),
                        &layer.transform,
                        source.width(),
                        source.height(),
                    );
                    let mut shaped = source;
                    shaped.mask_by_plane(&grid);
                    shaped
                }
                None => source,
            };
            let (grown, inset) = effects::render(&shaped, &visible_effects);
            let transform = grown_transform(&self.local(&layer.transform), grown.width(), grown.height(), inset);
            let (mut placed, _) = place_surface_box(&grown, &transform, box_)?;
            placed.scale_alpha(opacity);
            // An effect usually spreads into clear pixels, so the box is not fully covered.
            return Some(Drawn { image: placed, opaque: false });
        }
        let (mut placed, placed_opaque) = place_surface_box(&source, &self.local(&layer.transform), box_)?;
        let mut opaque = placed_opaque;
        if let Some(mask) = mask {
            let transform = self.local(&layer.effective_mask_transform().unwrap_or(layer.transform));
            if let Some(plane) = place_coverage_box(mask, &transform, box_) {
                placed.mask_by_plane(&plane);
                opaque = false;
            }
        }
        if opacity < 1.0 {
            opaque = false;
        }
        placed.scale_alpha(opacity);
        Some(Drawn { image: placed, opaque })
    }

    /// A layer shown through the coverage of the layer it takes its mask from.
    fn live_into(&mut self, layer: &Layer, box_: Region) -> Option<Drawn> {
        let mut drawn = self.own_into(layer, box_)?;
        let Some(source_id) = layer.mask_source else { return Some(drawn) };
        let Some(source) = self.layer(source_id) else { return Some(drawn) };
        if self.visiting.contains(&source_id) || self.visiting.len() >= MAX_CLIP_DEPTH {
            return Some(drawn);
        }
        self.visiting.insert(source_id);
        let coverage = self.clip_coverage(source, box_);
        self.visiting.remove(&source_id);
        if let Some(coverage) = coverage {
            // Only the coverage's alpha clips: the base's color and blend mode play no part.
            drawn.image.mask_by_plane(&coverage.alpha_plane());
            drawn.opaque = false;
        }
        Some(drawn)
    }

    /// A layer's coverage as a clipping base: its placed pixels, its own raster mask, its effective
    /// opacity (its own times every enclosing folder's) and then whatever clips it in turn.
    ///
    /// Folder masks are deliberately left out: the clipped layer and its base normally share the same
    /// folders, and the caller already multiplies those into the clipped layer's alpha.
    fn clip_coverage(&mut self, layer: &Layer, box_: Region) -> Option<Surface> {
        let mut coverage = self.own_into(layer, box_)?.image;
        let Some(source_id) = layer.mask_source else { return Some(coverage) };
        let Some(source) = self.layer(source_id) else { return Some(coverage) };
        if self.visiting.contains(&source_id) || self.visiting.len() >= MAX_CLIP_DEPTH {
            return Some(coverage);
        }
        self.visiting.insert(source_id);
        if let Some(upstream) = self.clip_coverage(source, box_) {
            coverage.mask_by_plane(&upstream.alpha_plane());
        }
        self.visiting.remove(&source_id);
        Some(coverage)
    }

    /// Every enclosing folder's mask, multiplied into a layer's alpha.
    fn clip_by_folders(&mut self, layer: &Layer, drawn: &mut Drawn, box_: Region) {
        let mut folder = layer.parent;
        let mut depth = 0;
        while let Some(id) = folder {
            if depth >= 64 {
                break;
            }
            if let Some(group) = self.layer(id) {
                if let Some(mask) = self.enabled_mask(group) {
                    let transform = self.local(&group.effective_mask_transform().unwrap_or(group.transform));
                    if let Some(plane) = place_coverage_box(mask, &transform, box_) {
                        drawn.image.mask_by_plane(&plane);
                        drawn.opaque = false;
                    }
                }
                folder = group.parent;
            } else {
                break;
            }
            depth += 1;
        }
    }

    /// An adjustment layer's coverage: its own mask, its folders' masks and its opacity.
    fn adjust(&mut self, layer: &Layer, adjustment: &Adjustment, folders: bool) {
        let mut canvas = std::mem::replace(&mut self.canvas, Surface::new(self.frame.2, self.frame.3));
        self.adjust_into(&mut canvas, layer, adjustment, folders);
        self.canvas = canvas;
    }

    fn adjust_into(&mut self, canvas: &mut Surface, layer: &Layer, adjustment: &Adjustment, folders: bool) {
        let below = canvas.clone();
        // The seeded patterns are anchored to the document, so the frame says where it sits.
        crate::adjustment::apply_at(adjustment, canvas, (self.frame.0, self.frame.1));
        if layer.blend != BlendMode::Normal {
            // In a blend mode the adjusted colors blend with what is under them at full coverage, and
            // the original coverage comes back afterwards, so a soft edge is not thickened.
            let mut changed = canvas.clone();
            make_opaque(&mut changed);
            let mut under = below.clone();
            make_opaque(&mut under);
            composite_surface(&mut under, &changed, layer.blend);
            // Shown only where the layer below had coverage.
            scale_by_alpha(&mut under, &below);
            *canvas = under;
        }
        let mut coverage: Option<Plane> = None;
        if let Some(mask) = self.enabled_mask(layer) {
            // The original places an adjustment's mask through the layer's own transform.
            let transform = self.local(&layer.effective_mask_transform().unwrap_or(layer.transform));
            if place_coverage(&mut self.coverage, mask, &transform).is_some() {
                coverage = Some(self.coverage.clone());
            }
        }
        if folders {
            let mut folder = layer.parent;
            let mut depth = 0;
            while let Some(id) = folder {
                if depth >= 64 {
                    break;
                }
                let Some(group) = self.layer(id) else { break };
                if let Some(mask) = self.enabled_mask(group) {
                    let transform = self.local(&group.effective_mask_transform().unwrap_or(group.transform));
                    if place_coverage(&mut self.coverage, mask, &transform).is_some() {
                        match &mut coverage {
                            Some(existing) => multiply_planes(existing, &self.coverage),
                            None => coverage = Some(self.coverage.clone()),
                        }
                    }
                }
                folder = group.parent;
                depth += 1;
            }
        }
        let opacity = self.document.effective_opacity(layer.id);
        if opacity < 1.0 {
            let value = (opacity * 255.0).round().clamp(0.0, 255.0) as u8;
            match &mut coverage {
                Some(existing) => {
                    for entry in existing.values_mut() {
                        *entry = ((*entry as u32 * value as u32 + 127) / 255) as u8;
                    }
                }
                None => coverage = Some(Plane::filled(self.frame.2, self.frame.3, value)),
            }
        }
        if let Some(coverage) = coverage {
            mix_through(canvas, &below, &coverage);
        }
    }

    fn enabled_mask(&self, layer: &'a Layer) -> Option<&'a comp_core::Gray8> {
        if !layer.mask_enabled {
            return None;
        }
        layer.mask.as_deref()
    }
}

/// Forces every pixel opaque without touching its color, as the original's `opaque()` does before a
/// clipping stack and an adjustment's blend.
fn make_opaque(surface: &mut Surface) {
    for texel in surface.pixels_mut().chunks_exact_mut(4) {
        texel[3] = 255;
    }
}

/// Scales every channel by the alpha of a matching image: `CIBlendWithAlphaMask` against nothing.
fn scale_by_alpha(target: &mut Surface, coverage: &Surface) {
    for (texel, reference) in target.pixels_mut().chunks_exact_mut(4).zip(coverage.pixels().chunks_exact(4)) {
        let alpha = reference[3] as u32;
        if alpha == 255 {
            continue;
        }
        for entry in texel.iter_mut() {
            *entry = ((*entry as u32 * alpha + 127) / 255) as u8;
        }
    }
}

/// `changed * coverage + below * (1 - coverage)`, the original's `CIBlendWithRedMask` mix.
fn mix_through(changed: &mut Surface, below: &Surface, coverage: &Plane) {
    for (index, texel) in changed.pixels_mut().chunks_exact_mut(4).enumerate() {
        let mix = coverage.values()[index] as u32;
        if mix == 255 {
            continue;
        }
        if mix == 0 {
            texel.copy_from_slice(&below.pixels()[index * 4..index * 4 + 4]);
            continue;
        }
        for (channel, entry) in texel.iter_mut().enumerate() {
            let under = below.pixels()[index * 4 + channel] as u32;
            *entry = ((*entry as u32 * mix + under * (255 - mix) + 127) / 255) as u8;
        }
    }
}

/// Multiplies two coverage planes together, in the first.
fn multiply_planes(target: &mut Plane, other: &Plane) {
    for (value, factor) in target.values_mut().iter_mut().zip(other.values().iter()) {
        *value = ((*value as u32 * *factor as u32 + 127) / 255) as u8;
    }
}

/// The transform an effects image lands in: the original grows the layer's transform by the margin the
/// effects added, so the padded surface covers the layer's pixels plus that margin one-to-one
/// (`LayerEffectsRenderer.placed(_:image:inset:)`).
///
/// Both arguments are the *padded* image's size, which is what the original measures: each axis divides
/// by the size the margin took away from it, not by the layer's own size. Passing the layer's size would
/// scale the surface by `w / (w - 2 * inset)` instead of `(w + 2 * inset) / w`, moving and resizing
/// every effect; sharing one ratio between the axes would stretch a layer that is not square.
pub fn grown_transform(transform: &Transform, grown_width: u32, grown_height: u32, inset: u32) -> Transform {
    let mut grown = *transform;
    let (width, height) = (grown_width as f64, grown_height as f64);
    let inset = inset as f64;
    if inset <= 0.0 || width <= inset * 2.0 || height <= inset * 2.0 {
        return grown;
    }
    grown.size.width *= width / (width - inset * 2.0);
    grown.size.height *= height / (height - inset * 2.0);
    let center_x = transform.origin.x + transform.size.width / 2.0;
    let center_y = transform.origin.y + transform.size.height / 2.0;
    grown.origin.x = center_x - grown.size.width / 2.0;
    grown.origin.y = center_y - grown.size.height / 2.0;
    grown
}

#[cfg(test)]
mod tests {
    use super::*;
    use comp_core::adjustment::{Adjustment, AdjustmentKind};
    use comp_core::geom::{PointF, Sampling, SizeF};
    use comp_core::{Bitmap8, Gray8};
    use std::sync::Arc;

    fn layer_with(name: &str, width: u32, height: u32, texel: [u8; 4]) -> Layer {
        let mut layer = Layer::with_image(name, Bitmap8::filled(width, height, texel));
        layer.image_file = None;
        layer
    }

    fn canvas_document(width: u32, height: u32) -> Document {
        Document::new(width, height)
    }

    #[test]
    fn an_empty_document_flattens_to_transparent() {
        let document = canvas_document(4, 3);
        let out = flatten_document(&document);
        assert_eq!((out.width(), out.height()), (4, 3));
        assert!(out.pixels().iter().all(|byte| *byte == 0));
    }

    #[test]
    fn a_single_layer_fills_the_canvas() {
        let mut document = canvas_document(4, 4);
        document.add_layer(layer_with("Base", 4, 4, [10, 20, 30, 255]), None);
        let out = flatten_document(&document);
        assert_eq!(out.get(0, 0), [10, 20, 30, 255]);
        assert_eq!(out.get(3, 3), [10, 20, 30, 255]);
    }

    #[test]
    fn a_hidden_layer_draws_nothing() {
        let mut document = canvas_document(4, 4);
        let mut layer = layer_with("Hidden", 4, 4, [255, 0, 0, 255]);
        layer.visible = false;
        document.add_layer(layer, None);
        let out = flatten_document(&document);
        assert!(out.pixels().iter().all(|byte| *byte == 0));
    }

    #[test]
    fn a_layer_without_pixels_draws_nothing() {
        let mut document = canvas_document(4, 4);
        document.add_layer(Layer::raster("Empty", 4, 4), None);
        let out = flatten_document(&document);
        assert!(out.pixels().iter().all(|byte| *byte == 0));
    }

    #[test]
    fn layers_composite_bottom_to_top() {
        let mut document = canvas_document(4, 4);
        document.add_layer(layer_with("Bottom", 4, 4, [255, 0, 0, 255]), None);
        document.add_layer(layer_with("Top", 2, 2, [0, 0, 255, 255]), None);
        let out = flatten_document(&document);
        assert_eq!(out.get(0, 0), [0, 0, 255, 255], "the top layer is at the origin");
        assert_eq!(out.get(3, 3), [255, 0, 0, 255], "and the bottom shows elsewhere");
    }

    #[test]
    fn opacity_and_blend_modes_reach_the_canvas() {
        let mut document = canvas_document(2, 2);
        document.add_layer(layer_with("Bottom", 2, 2, [200, 200, 200, 255]), None);
        let mut top = layer_with("Top", 2, 2, [100, 100, 100, 255]);
        top.opacity = 0.5;
        document.add_layer(top, None);
        let out = flatten_document(&document);
        assert!((out.get(0, 0)[0] as i32 - 150).abs() <= 1, "half opacity: {:?}", out.get(0, 0));

        let mut document = canvas_document(2, 2);
        document.add_layer(layer_with("Bottom", 2, 2, [255, 128, 0, 255]), None);
        let mut top = layer_with("Top", 2, 2, [128, 128, 128, 255]);
        top.blend = BlendMode::Multiply;
        document.add_layer(top, None);
        let out = flatten_document(&document);
        assert_eq!(out.get(0, 0), [128, 64, 0, 255]);
    }

    #[test]
    fn a_layer_mask_scales_the_layer() {
        let mut document = canvas_document(4, 1);
        let mut layer = layer_with("Masked", 4, 1, [255, 255, 255, 255]);
        let mask = Gray8::from_raw(4, 1, vec![0, 64, 128, 255]).unwrap();
        layer.mask = Some(Arc::new(mask));
        document.add_layer(layer, None);
        let out = flatten_document(&document);
        assert_eq!(out.get(0, 0)[3], 0, "a zero mask hides the pixel");
        assert_eq!(out.get(1, 0)[3], 64);
        assert_eq!(out.get(2, 0)[3], 128);
        assert_eq!(out.get(3, 0)[3], 255);
        // The color stays the layer's own, whatever the coverage.
        assert_eq!(out.get(2, 0)[0], 255);
    }

    #[test]
    fn a_disabled_mask_does_not_composite() {
        let mut document = canvas_document(2, 1);
        let mut layer = layer_with("Masked", 2, 1, [255, 0, 0, 255]);
        layer.mask = Some(Arc::new(Gray8::filled(2, 1, 0)));
        layer.mask_enabled = false;
        document.add_layer(layer, None);
        let out = flatten_document(&document);
        assert_eq!(out.get(0, 0), [255, 0, 0, 255]);
    }

    #[test]
    fn opacity_inside_a_folder_multiplies_into_its_children() {
        let mut document = canvas_document(2, 2);
        let mut group = Layer::group("Folder", 2, 2);
        group.opacity = 0.5;
        let group_id = group.id;
        document.add_layer(group, None);
        document.add_layer(layer_with("Inner", 2, 2, [0, 0, 0, 255]), Some(group_id));
        let out = flatten_document(&document);
        assert_eq!(out.get(0, 0)[3], 128, "half of the folder's opacity: {:?}", out.get(0, 0));
    }

    #[test]
    fn a_folder_mask_clips_what_is_inside_it() {
        let mut document = canvas_document(2, 1);
        let mut group = Layer::group("Folder", 2, 1);
        group.mask = Some(Arc::new(Gray8::from_raw(2, 1, vec![255, 0]).unwrap()));
        let group_id = group.id;
        document.add_layer(group, None);
        document.add_layer(layer_with("Inner", 2, 1, [255, 255, 255, 255]), Some(group_id));
        let out = flatten_document(&document);
        assert_eq!(out.get(0, 0)[3], 255);
        assert_eq!(out.get(1, 0)[3], 0);
    }

    #[test]
    fn a_clipping_layer_takes_the_coverage_of_the_layer_below_it() {
        let mut document = canvas_document(4, 1);
        // The base is opaque on the left half only.
        let mut base = layer_with("Base", 4, 1, [255, 0, 0, 255]);
        base.mask = Some(Arc::new(Gray8::from_raw(4, 1, vec![255, 255, 0, 0]).unwrap()));
        let base_id = base.id;
        document.add_layer(base, None);
        let mut clipped = layer_with("Clipped", 4, 1, [0, 0, 255, 255]);
        clipped.mask_source = Some(base_id);
        document.add_layer(clipped, None);
        let out = flatten_document(&document);
        // Inside the base's coverage the clipped blue shows; outside, nothing does.
        assert_eq!(out.get(0, 0), [0, 0, 255, 255]);
        assert_eq!(out.get(1, 0), [0, 0, 255, 255]);
        assert_eq!(out.get(2, 0)[3], 0, "past the base's mask the stack is hidden");
        assert_eq!(out.get(3, 0)[3], 0);
    }

    #[test]
    fn a_clipping_layer_follows_a_soft_base_edge() {
        let mut document = canvas_document(2, 1);
        let mut base = layer_with("Base", 2, 1, [255, 0, 0, 255]);
        base.mask = Some(Arc::new(Gray8::from_raw(2, 1, vec![255, 128]).unwrap()));
        let base_id = base.id;
        document.add_layer(base, None);
        let mut clipped = layer_with("Clipped", 2, 1, [0, 0, 255, 255]);
        clipped.mask_source = Some(base_id);
        document.add_layer(clipped, None);
        let out = flatten_document(&document);
        assert_eq!(out.get(0, 0), [0, 0, 255, 255], "a fully covered column is the clipped layer");
        // The half-covered column is the blue clipped layer at half alpha over the red base at half
        // alpha: 0.5 + 0.5 * 0.5 of alpha, and the two colors mixed underneath it.
        let half = out.get(1, 0);
        assert_eq!(half[3], 192, "the clip follows the soft edge: {half:?}");
        assert!(half[2] > 150 && half[0] < 110, "blue over red: {half:?}");
    }

    /// A backdrop both cases composite onto, so the clipped layer's own alpha shows in the mix.
    fn black_backdrop(document: &mut Document) {
        document.add_layer(layer_with("Backdrop", 1, 1, [0, 0, 0, 255]), None);
    }

    #[test]
    fn a_clipped_layer_inherits_the_base_opacity() {
        // Backdrop black, base white at half opacity, clipped red opaque.
        // Base over backdrop: 0.5 white -> (128, 128, 128). Clip coverage: the base's pixels (1) times
        // its effective opacity (0.5) = 0.5, so the clipped layer lands at alpha 0.5:
        // red = 0.5 * 255 + 0.5 * 128 = 192, green and blue = 0.5 * 128 = 64.
        let mut document = canvas_document(1, 1);
        black_backdrop(&mut document);
        let mut base = layer_with("Half Base", 1, 1, [255, 255, 255, 255]);
        base.opacity = 0.5;
        let base_id = base.id;
        document.add_layer(base, None);
        let mut clipped = layer_with("Clipped", 1, 1, [255, 0, 0, 255]);
        clipped.mask_source = Some(base_id);
        document.add_layer(clipped, None);
        let out = flatten_document(&document);
        assert_eq!(out.get(0, 0), [192, 64, 64, 255], "the base's opacity limits the clip");
    }

    #[test]
    fn a_clipped_layer_inherits_the_base_raster_mask() {
        // The same shape with a mask of 64 instead of an opacity: 0.251 of coverage.
        // Base over backdrop: (64, 64, 64). Clipped red at 0.251:
        // red = 64 + 64 * 0.749 = 112, green and blue = 64 * 0.749 = 48.
        let mut document = canvas_document(1, 1);
        black_backdrop(&mut document);
        let mut base = layer_with("Masked Base", 1, 1, [255, 255, 255, 255]);
        base.mask = Some(Arc::new(Gray8::filled(1, 1, 64)));
        let base_id = base.id;
        document.add_layer(base, None);
        let mut clipped = layer_with("Clipped", 1, 1, [255, 0, 0, 255]);
        clipped.mask_source = Some(base_id);
        document.add_layer(clipped, None);
        let out = flatten_document(&document);
        assert_eq!(out.get(0, 0), [112, 48, 48, 255], "the base's mask limits the clip");
    }

    #[test]
    fn a_clipped_layer_inherits_a_folder_opacity_through_its_base() {
        // Base and clipped layer inside a folder at half opacity: the base's coverage is half, and the
        // clipped layer's own opacity is half too, so it lands at 0.25.
        // Base over backdrop: 0.5 white -> (128, 128, 128).
        // Clipped red at 0.25: red = 64 + 128 * 0.75 = 160, green and blue = 128 * 0.75 = 96.
        let mut document = canvas_document(1, 1);
        black_backdrop(&mut document);
        let mut folder = Layer::group("Folder", 1, 1);
        folder.opacity = 0.5;
        let folder_id = folder.id;
        document.add_layer(folder, None);
        let mut base = layer_with("Base", 1, 1, [255, 255, 255, 255]);
        base.parent = Some(folder_id);
        let base_id = base.id;
        document.add_layer(base, Some(folder_id));
        let mut clipped = layer_with("Clipped", 1, 1, [255, 0, 0, 255]);
        clipped.mask_source = Some(base_id);
        document.add_layer(clipped, Some(folder_id));
        let out = flatten_document(&document);
        assert_eq!(out.get(0, 0), [160, 96, 96, 255], "the folder's opacity reaches the clip");
    }

    #[test]
    fn a_clipping_chain_multiplies_every_coverage_along_it() {
        // A base at half opacity carrying a mask of 128 (0.251 of coverage), then two layers clipped in
        // turn. Every link multiplies: the first clipped layer lands at 0.251, the second at
        // 1 * 0.251 as well, because a clipped layer's own coverage is its pixels times its opacity.
        // Base over backdrop: (64, 64, 64).
        // Green clipped at 0.251: (48, 112, 48).
        // Red clipped at 0.251 over that: (100, 84, 36).
        let mut document = canvas_document(1, 1);
        black_backdrop(&mut document);
        let mut base = layer_with("Base", 1, 1, [255, 255, 255, 255]);
        base.opacity = 0.5;
        base.mask = Some(Arc::new(Gray8::filled(1, 1, 128)));
        let base_id = base.id;
        document.add_layer(base, None);
        let mut middle = layer_with("Middle", 1, 1, [0, 255, 0, 255]);
        middle.mask_source = Some(base_id);
        let middle_id = middle.id;
        document.add_layer(middle, None);
        let mut top = layer_with("Top", 1, 1, [255, 0, 0, 255]);
        top.mask_source = Some(middle_id);
        document.add_layer(top, None);
        let out = flatten_document(&document);
        assert_eq!(out.get(0, 0), [100, 84, 36, 255], "the chain multiplies both coverages");
    }

    #[test]
    fn a_clipping_base_without_pixels_does_not_clip() {
        // A base with no pixels has no coverage to give, as the original treats a layer that drew
        // nothing: the clipped layer shows in full.
        let mut document = canvas_document(1, 1);
        let base = Layer::raster("Empty base", 1, 1);
        let base_id = base.id;
        document.add_layer(base, None);
        let mut clipped = layer_with("Clipped", 1, 1, [255, 0, 0, 255]);
        clipped.mask_source = Some(base_id);
        document.add_layer(clipped, None);
        let out = flatten_document(&document);
        assert_eq!(out.get(0, 0), [255, 0, 0, 255]);
    }

    #[test]
    fn a_clipping_base_ignores_its_own_visibility() {
        // Coverage is coverage: a hidden base still shapes what is clipped to it, as
        // LiveMaskRenderer's class comment says.
        let mut document = canvas_document(1, 1);
        let mut base = layer_with("Hidden base", 1, 1, [255, 255, 255, 255]);
        base.visible = false;
        base.opacity = 0.5;
        let base_id = base.id;
        document.add_layer(base, None);
        let mut clipped = layer_with("Clipped", 1, 1, [255, 0, 0, 255]);
        clipped.mask_source = Some(base_id);
        document.add_layer(clipped, None);
        let out = flatten_document(&document);
        // The base itself contributes nothing, and the clipped layer is limited to half alpha: straight
        // red at 128, which is fully saturated red covering half the pixel.
        assert_eq!(out.get(0, 0), [255, 0, 0, 128]);
    }

    #[test]
    fn an_adjustment_layer_changes_only_what_is_below_it() {
        let mut document = canvas_document(2, 1);
        document.add_layer(layer_with("Bottom", 2, 1, [10, 20, 30, 255]), None);
        let mut adjustment = Adjustment::new(AdjustmentKind::Invert);
        adjustment.kind = AdjustmentKind::Invert;
        document.add_layer(Layer::adjustment("Invert", adjustment, 2, 1), None);
        let out = flatten_document(&document);
        assert_eq!(out.get(0, 0), [245, 235, 225, 255]);
    }

    #[test]
    fn an_adjustment_layer_above_nothing_leaves_nothing() {
        let mut document = canvas_document(2, 1);
        document.add_layer(
            Layer::adjustment("Invert", Adjustment::new(AdjustmentKind::Invert), 2, 1),
            None,
        );
        let out = flatten_document(&document);
        assert!(out.pixels().iter().all(|byte| *byte == 0));
    }

    #[test]
    fn an_adjustment_inside_a_folder_only_reaches_its_siblings_below() {
        let mut document = canvas_document(2, 1);
        document.add_layer(layer_with("Outside", 2, 1, [10, 20, 30, 255]), None);
        let group = Layer::group("Folder", 2, 1);
        let group_id = group.id;
        document.add_layer(group, None);
        document.add_layer(layer_with("Inner", 2, 1, [10, 20, 30, 255]), Some(group_id));
        document.add_layer(
            Layer::adjustment("Invert", Adjustment::new(AdjustmentKind::Invert), 2, 1),
            Some(group_id),
        );
        let out = flatten_document(&document);
        // The folder's own content is inverted, and the folder composites normally over the layer below it.
        assert_eq!(out.get(0, 0), [245, 235, 225, 255]);
    }

    #[test]
    fn an_adjustment_with_opacity_mixes_with_what_is_below() {
        let mut document = canvas_document(1, 1);
        document.add_layer(layer_with("Bottom", 1, 1, [0, 0, 0, 255]), None);
        let mut adjustment = Layer::adjustment("Invert", Adjustment::new(AdjustmentKind::Invert), 1, 1);
        adjustment.opacity = 0.5;
        document.add_layer(adjustment, None);
        let out = flatten_document(&document);
        assert!((out.get(0, 0)[0] as i32 - 128).abs() <= 1, "half an invert: {:?}", out.get(0, 0));
    }

    #[test]
    fn a_transformed_layer_lands_where_its_transform_says() {
        let mut document = canvas_document(8, 8);
        let mut layer = layer_with("Moved", 2, 2, [255, 0, 0, 255]);
        layer.transform = Transform {
            origin: PointF::new(4.0, 4.0),
            size: SizeF::new(2.0, 2.0),
            rotation: 0.0,
            flip_x: false,
            flip_y: false,
            sampling: Sampling::Nearest,
        };
        document.add_layer(layer, None);
        let out = flatten_document(&document);
        assert_eq!(out.get(4, 4), [255, 0, 0, 255]);
        assert_eq!(out.get(5, 5), [255, 0, 0, 255]);
        assert_eq!(out.get(3, 3)[3], 0);
        assert_eq!(out.get(6, 6)[3], 0);
    }

    #[test]
    fn a_scaled_layer_keeps_its_color_to_the_edges() {
        let mut document = canvas_document(4, 4);
        let mut layer = layer_with("Scaled", 2, 2, [0, 255, 0, 255]);
        layer.transform = Transform {
            origin: PointF::new(0.0, 0.0),
            size: SizeF::new(4.0, 4.0),
            rotation: 0.0,
            flip_x: false,
            flip_y: false,
            sampling: Sampling::HighQuality,
        };
        document.add_layer(layer, None);
        let out = flatten_document(&document);
        for y in 0..4 {
            for x in 0..4 {
                assert_eq!(out.get(x, y)[3], 255, "({x},{y}) stays opaque");
                assert!(out.get(x, y)[1] > 250, "({x},{y}) stays green");
            }
        }
    }

    #[test]
    fn a_padded_effect_surface_keeps_the_layer_where_it_was() {
        // A shadow reaches ten pixels, so the effects surface is padded by twelve on every side. The
        // layer's own pixels must still land exactly where its transform puts them, and the shadow must
        // sit ten rows below them: growing the surface must not scale the layer.
        let mut document = canvas_document(40, 40);
        let mut layer = layer_with("Box", 8, 8, [255, 255, 255, 255]);
        layer.transform = Transform {
            origin: PointF::new(10.0, 10.0),
            size: SizeF::new(8.0, 8.0),
            rotation: 0.0,
            flip_x: false,
            flip_y: false,
            sampling: Sampling::Nearest,
        };
        layer.effects = Some(comp_core::effects::LayerEffects {
            shadow: Some(comp_core::effects::ShadowEffect {
                enabled: None,
                angle: 90.0,
                distance: 10.0,
                blur: 0.0,
                red: 0.0,
                green: 0.0,
                blue: 0.0,
                opacity: 1.0,
            }),
            ..Default::default()
        });
        document.add_layer(layer, None);
        let out = flatten_document(&document);
        assert_eq!(out.get(10, 10), [255, 255, 255, 255], "the box's first pixel");
        assert_eq!(out.get(17, 17), [255, 255, 255, 255], "the box's last pixel");
        assert_eq!(out.get(18, 18)[3], 0, "and nothing past it");
        assert_eq!(out.get(9, 9)[3], 0);
        // The shadow is the same box moved down ten rows.
        let shadow = out.get(14, 21);
        assert_eq!(shadow[3], 255, "an opaque shadow ten rows down: {shadow:?}");
        assert!(shadow[0] < 10, "and black: {shadow:?}");
        assert_eq!(out.get(14, 19)[3], 0, "nothing between the box and the shadow");
    }

    #[test]
    fn a_fractional_shadow_offset_lands_on_a_whole_pixel() {
        // 45 degrees at distance 6 is (-4.243, +4.243): Core Graphics puts the moved shape on the nearest
        // pixel, so the shadow sits four columns left and four rows down, not smeared across two.
        let mut document = canvas_document(40, 40);
        let mut layer = layer_with("Box", 8, 8, [255, 255, 255, 255]);
        layer.transform = Transform {
            origin: PointF::new(16.0, 16.0),
            size: SizeF::new(8.0, 8.0),
            rotation: 0.0,
            flip_x: false,
            flip_y: false,
            sampling: Sampling::Nearest,
        };
        layer.effects = Some(comp_core::effects::LayerEffects {
            shadow: Some(comp_core::effects::ShadowEffect {
                enabled: None,
                angle: 45.0,
                distance: 6.0,
                blur: 0.0,
                red: 0.0,
                green: 0.0,
                blue: 0.0,
                opacity: 1.0,
            }),
            ..Default::default()
        });
        document.add_layer(layer, None);
        let out = flatten_document(&document);
        // The box moved by (-4, +4) covers columns 12..19 and rows 20..27.
        let inside = out.get(13, 21);
        assert_eq!(inside[3], 255, "the shadow's edge is on a whole pixel: {inside:?}");
        assert_eq!(out.get(12, 20)[3], 255);
        let outside = out.get(11, 19);
        assert_eq!(outside[3], 0, "and it does not smear one pixel further: {outside:?}");
    }

    #[test]
    fn flatten_layer_ignores_what_is_below() {
        let mut document = canvas_document(2, 2);
        document.add_layer(layer_with("Bottom", 2, 2, [255, 0, 0, 255]), None);
        let top = layer_with("Top", 2, 2, [0, 0, 255, 128]);
        let top_id = top.id;
        document.add_layer(top, None);
        let out = flatten_layer(&document, top_id).unwrap();
        assert_eq!(out.get(0, 0), [0, 0, 255, 128]);
    }

    #[test]
    fn a_deep_clipping_cycle_does_not_hang() {
        let mut document = canvas_document(2, 2);
        let mut first = layer_with("First", 2, 2, [255, 0, 0, 255]);
        let second = layer_with("Second", 2, 2, [0, 0, 255, 255]);
        first.mask_source = Some(second.id);
        let mut second = second;
        second.mask_source = Some(first.id);
        document.add_layer(first, None);
        document.add_layer(second, None);
        let out = flatten_document(&document);
        assert_eq!(out.width(), 2);
    }

    #[test]
    fn a_group_with_no_children_draws_nothing() {
        let mut document = canvas_document(4, 4);
        document.add_layer(Layer::group("Empty folder", 4, 4), None);
        let out = flatten_document(&document);
        assert!(out.pixels().iter().all(|byte| *byte == 0));
    }

    // ---------------------------------------------------------------------------------------------
    // Region rendering: flatten_region must be flatten_document cropped, pixel for pixel.
    // ---------------------------------------------------------------------------------------------

    /// The whole render cropped to a rectangle, clear where the rectangle lies off the canvas.
    fn full_render_cropped(document: &Document, bounds: (i64, i64, u32, u32)) -> Bitmap8 {
        let full = flatten_document(document);
        let mut out = Bitmap8::new(bounds.2, bounds.3);
        for row in 0..bounds.3 as i64 {
            let y = bounds.1 + row;
            if y < 0 || y >= full.height() as i64 {
                continue;
            }
            for column in 0..bounds.2 as i64 {
                let x = bounds.0 + column;
                if x < 0 || x >= full.width() as i64 {
                    continue;
                }
                out.set(column as u32, row as u32, full.get(x as u32, y as u32));
            }
        }
        out
    }

    /// Asserts one rectangle of a document matches the whole render cropped to it.
    fn assert_region_matches(document: &Document, bounds: (i64, i64, u32, u32)) {
        let region = flatten_region(document, bounds);
        assert_eq!((region.width(), region.height()), (bounds.2, bounds.3), "region size");
        let cropped = full_render_cropped(document, bounds);
        assert!(
            region.pixels() == cropped.pixels(),
            "region {bounds:?} is not the whole render cropped:\n left {:?}\nright {:?}",
            region.pixels(),
            cropped.pixels()
        );
    }

    fn moved_layer(name: &str, width: u32, height: u32, texel: [u8; 4], transform: Transform) -> Layer {
        let mut layer = layer_with(name, width, height, texel);
        layer.transform = transform;
        layer
    }

    fn placed(origin_x: f64, origin_y: f64, size: f64) -> Transform {
        Transform {
            origin: PointF::new(origin_x, origin_y),
            size: SizeF::new(size, size),
            rotation: 0.0,
            flip_x: false,
            flip_y: false,
            sampling: Sampling::Nearest,
        }
    }

    /// A document with a bit of everything that is placed on whole pixels.
    fn plain_document() -> Document {
        let mut document = canvas_document(64, 48);
        document.add_layer(layer_with("Base", 64, 48, [40, 60, 90, 255]), None);
        let mut multiplied = moved_layer("Multiplied", 16, 16, [200, 180, 160, 255], placed(8.0, 6.0, 16.0));
        multiplied.blend = BlendMode::Multiply;
        document.add_layer(multiplied, None);
        let mut soft = moved_layer("Soft", 20, 20, [30, 120, 200, 128], placed(30.0, 20.0, 20.0));
        soft.opacity = 0.6;
        document.add_layer(soft, None);
        document
    }

    #[test]
    fn a_region_of_plain_layers_matches_the_whole_render() {
        let document = plain_document();
        for bounds in [(0, 0, 64, 48), (0, 0, 8, 8), (7, 5, 20, 20), (30, 19, 21, 22), (56, 40, 8, 8)] {
            assert_region_matches(&document, bounds);
        }
    }

    #[test]
    fn every_blend_mode_matches_in_a_region() {
        for mode in BlendMode::ALL {
            let mut document = canvas_document(24, 24);
            document.add_layer(layer_with("Base", 24, 24, [90, 140, 200, 255]), None);
            let mut top = moved_layer("Top", 12, 12, [220, 110, 40, 200], placed(4.0, 5.0, 12.0));
            top.blend = mode;
            top.opacity = 0.75;
            document.add_layer(top, None);
            assert_region_matches(&document, (3, 4, 16, 15));
        }
    }

    #[test]
    fn a_scaled_and_rotated_layer_matches_in_a_region() {
        let mut document = canvas_document(40, 40);
        document.add_layer(layer_with("Base", 40, 40, [20, 30, 40, 255]), None);
        let mut spun = moved_layer("Spun", 12, 12, [240, 90, 30, 220], placed(6.5, 7.25, 18.0));
        spun.transform.rotation = 32.0;
        spun.transform.sampling = Sampling::HighQuality;
        document.add_layer(spun, None);
        assert_region_matches(&document, (4, 4, 20, 20));
    }

    #[test]
    fn a_masked_layer_matches_in_a_region() {
        let mut document = canvas_document(20, 20);
        document.add_layer(layer_with("Base", 20, 20, [10, 10, 10, 255]), None);
        let mut layer = layer_with("Masked", 20, 20, [255, 80, 0, 255]);
        let mut values = Vec::new();
        for y in 0..20 {
            for x in 0..20 {
                values.push(((x * 11 + y * 7) % 256) as u8);
            }
        }
        layer.mask = Some(Arc::new(Gray8::from_raw(20, 20, values).unwrap()));
        document.add_layer(layer, None);
        assert_region_matches(&document, (5, 5, 10, 10));
    }

    #[test]
    fn a_masked_folder_matches_in_a_region() {
        let mut document = canvas_document(20, 20);
        document.add_layer(layer_with("Base", 20, 20, [200, 200, 200, 255]), None);
        let mut folder = Layer::group("Folder", 20, 20);
        folder.mask = Some(Arc::new(Gray8::filled(20, 20, 128)));
        folder.opacity = 0.8;
        let folder_id = folder.id;
        document.add_layer(folder, None);
        let mut child = moved_layer("Child", 12, 12, [255, 0, 0, 255], placed(4.0, 4.0, 12.0));
        child.blend = BlendMode::Screen;
        document.add_layer(child, Some(folder_id));
        assert_region_matches(&document, (2, 2, 16, 16));
    }

    #[test]
    fn a_clipped_layer_matches_in_a_region() {
        let mut document = canvas_document(24, 24);
        let base = moved_layer("Base", 14, 14, [0, 200, 255, 255], placed(4.0, 6.0, 14.0));
        let base_id = base.id;
        document.add_layer(base, None);
        let mut clipped = moved_layer("Clipped", 24, 24, [255, 40, 40, 255], placed(0.0, 0.0, 24.0));
        clipped.mask_source = Some(base_id);
        document.add_layer(clipped, None);
        assert_region_matches(&document, (0, 0, 24, 24));
        assert_region_matches(&document, (5, 7, 12, 12));
        assert_region_matches(&document, (17, 19, 6, 5));
    }

    #[test]
    fn an_off_canvas_layer_matches_in_a_region() {
        let mut document = canvas_document(16, 16);
        document.add_layer(layer_with("Base", 16, 16, [70, 70, 70, 255]), None);
        // Half off the right edge, and one entirely past it.
        document.add_layer(moved_layer("Half", 8, 8, [255, 200, 0, 255], placed(12.0, 4.0, 8.0)), None);
        document.add_layer(moved_layer("Past", 8, 8, [0, 255, 0, 255], placed(30.0, 30.0, 8.0)), None);
        assert_region_matches(&document, (0, 0, 16, 16));
        assert_region_matches(&document, (11, 3, 5, 10));
        assert_region_matches(&document, (20, 20, 4, 4));
    }

    #[test]
    fn a_moved_layer_matches_in_a_region() {
        let mut document = canvas_document(32, 32);
        document.add_layer(layer_with("Base", 32, 32, [12, 24, 36, 255]), None);
        let mut layer = moved_layer("Moved", 10, 6, [250, 250, 10, 255], placed(21.0, 19.0, 10.0));
        layer.transform.size = SizeF::new(10.0, 6.0);
        document.add_layer(layer, None);
        assert_region_matches(&document, (20, 18, 8, 8));
    }

    #[test]
    fn a_mask_placement_matches_in_a_region() {
        let mut document = canvas_document(24, 24);
        let mut layer = layer_with("Shifted mask", 24, 24, [255, 255, 255, 255]);
        let mut values = Vec::new();
        for index in 0..24 * 24 {
            values.push((index % 256) as u8);
        }
        layer.mask = Some(Arc::new(Gray8::from_raw(24, 24, values).unwrap()));
        layer.mask_placement = Some(placed(3.0, 2.0, 24.0));
        document.add_layer(layer, None);
        assert_region_matches(&document, (0, 0, 24, 24));
        assert_region_matches(&document, (4, 3, 9, 9));
    }

    #[test]
    fn layer_effects_match_in_a_region() {
        let mut document = canvas_document(40, 40);
        document.add_layer(layer_with("Base", 40, 40, [30, 30, 30, 255]), None);
        let mut layer = moved_layer("Box", 8, 8, [255, 255, 255, 255], placed(16.0, 14.0, 8.0));
        layer.effects = Some(comp_core::effects::LayerEffects {
            shadow: Some(comp_core::effects::ShadowEffect {
                enabled: None,
                angle: 45.0,
                distance: 6.0,
                blur: 4.0,
                red: 0.0,
                green: 0.0,
                blue: 0.0,
                opacity: 1.0,
            }),
            ..Default::default()
        });
        document.add_layer(layer, None);
        assert_region_matches(&document, (8, 4, 24, 26));
        assert_region_matches(&document, (16, 14, 8, 8));
    }

    #[test]
    fn a_gaussian_blur_adjustment_matches_in_a_region() {
        let mut document = canvas_document(48, 48);
        document.add_layer(layer_with("Base", 48, 48, [0, 0, 0, 255]), None);
        // A white block that stops outside the region: only the blur's reach brings it in.
        document.add_layer(moved_layer("Block", 8, 8, [255, 255, 255, 255], placed(20.0, 8.0, 8.0)), None);
        let mut adjustment = Adjustment::new(AdjustmentKind::GaussianBlur);
        adjustment.blur_radius = Some(6.0);
        document.add_layer(Layer::adjustment("Blur", adjustment, 48, 48), None);
        assert_region_matches(&document, (16, 16, 12, 12));
        assert_region_matches(&document, (0, 0, 48, 48));
        assert_region_matches(&document, (26, 14, 10, 10));
    }

    #[test]
    fn a_motion_blur_adjustment_matches_in_a_region() {
        let mut document = canvas_document(40, 40);
        document.add_layer(layer_with("Base", 40, 40, [0, 0, 0, 255]), None);
        document.add_layer(moved_layer("Dot", 3, 3, [255, 255, 255, 255], placed(10.0, 18.0, 3.0)), None);
        let mut adjustment = Adjustment::new(AdjustmentKind::MotionBlur);
        adjustment.motion_angle = Some(0.0);
        adjustment.motion_distance = Some(12.0);
        document.add_layer(Layer::adjustment("Streak", adjustment, 40, 40), None);
        assert_region_matches(&document, (16, 17, 10, 6));
    }

    #[test]
    fn seeded_patterns_match_in_a_region() {
        // Grain and noise are anchored to the document, so a region has to ask for the pattern at the
        // coordinates it covers rather than restarting it at its own corner.
        let mut document = canvas_document(40, 32);
        document.add_layer(layer_with("Base", 40, 32, [90, 90, 90, 255]), None);
        let mut grain = Adjustment::new(AdjustmentKind::Grain);
        grain.grain_settings = Some(serde_json::json!({"amount": 40.0, "size": 2.5}));
        document.add_layer(Layer::adjustment("Grain", grain, 40, 32), None);
        assert_region_matches(&document, (17, 13, 9, 7));

        let mut document = canvas_document(40, 32);
        document.add_layer(layer_with("Base", 40, 32, [90, 90, 90, 255]), None);
        let mut noise = Adjustment::new(AdjustmentKind::AddNoise);
        noise.noise_amount = Some(60.0);
        noise.noise_seed = Some(9);
        document.add_layer(Layer::adjustment("Noise", noise, 40, 32), None);
        assert_region_matches(&document, (23, 5, 11, 13));
    }

    #[test]
    fn an_adjustment_mask_matches_in_a_region() {
        let mut document = canvas_document(24, 24);
        document.add_layer(layer_with("Base", 24, 24, [200, 120, 40, 255]), None);
        let mut adjustment = Layer::adjustment("Invert", Adjustment::new(AdjustmentKind::Invert), 24, 24);
        let mut values = Vec::new();
        for index in 0..24 * 24 {
            values.push((255 - (index % 256)) as u8);
        }
        adjustment.mask = Some(Arc::new(Gray8::from_raw(24, 24, values).unwrap()));
        adjustment.opacity = 0.5;
        document.add_layer(adjustment, None);
        assert_region_matches(&document, (6, 7, 12, 10));
    }

    #[test]
    fn a_single_pixel_region_matches() {
        let document = plain_document();
        assert_region_matches(&document, (31, 21, 1, 1));
        assert_region_matches(&document, (0, 0, 1, 1));
        assert_region_matches(&document, (63, 47, 1, 1));
    }

    #[test]
    fn a_region_the_size_of_the_canvas_is_the_whole_render() {
        let document = plain_document();
        assert_eq!(flatten_region(&document, (0, 0, 64, 48)), flatten_document(&document));
    }

    #[test]
    fn a_region_off_the_canvas_comes_back_clear() {
        let document = plain_document();
        let region = flatten_region(&document, (100, 100, 4, 4));
        assert_eq!((region.width(), region.height()), (4, 4));
        assert!(region.pixels().iter().all(|byte| *byte == 0));
        // A region that only reaches part way onto the canvas keeps the canvas's own pixels and is clear
        // for the rest.
        let region = flatten_region(&document, (60, 44, 8, 8));
        let full = flatten_document(&document);
        assert_eq!(region.get(0, 0), full.get(60, 44));
        assert_eq!(region.get(3, 3), full.get(63, 47));
        assert!(region.get(4, 0).iter().all(|byte| *byte == 0));
        assert!(region.get(0, 4).iter().all(|byte| *byte == 0));
    }

    #[test]
    fn a_zero_sized_region_is_empty() {
        let document = plain_document();
        assert_eq!(flatten_region(&document, (4, 4, 0, 0)).pixels().len(), 0);
        assert_eq!(flatten_region(&document, (4, 4, 0, 8)).pixels().len(), 0);
    }

    #[test]
    fn a_region_of_an_empty_document_is_clear() {
        let document = canvas_document(16, 16);
        assert_region_matches(&document, (4, 4, 8, 8));
        assert!(flatten_region(&document, (4, 4, 8, 8)).pixels().iter().all(|byte| *byte == 0));
    }

    #[test]
    fn a_region_of_a_hidden_layer_is_clear() {
        let mut document = canvas_document(16, 16);
        let mut layer = layer_with("Hidden", 16, 16, [255, 0, 0, 255]);
        layer.visible = false;
        document.add_layer(layer, None);
        assert_region_matches(&document, (0, 0, 16, 16));
    }

}