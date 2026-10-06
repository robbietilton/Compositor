//! Turning decoded Photoshop records into a comp-core document.
//!
//! The document model keeps a group and its descendants contiguous, bottom to top, so the reader
//! hands the records over in that order and this module only has to place them. Everything the
//! file said that Compositor cannot honor becomes a conversion note, never a silent change.
use std::collections::HashMap;
use std::sync::Arc;

use uuid::Uuid;

use comp_core::bitmap::Gray8;
use comp_core::blend::BlendMode;
use comp_core::document::Document;
use comp_core::geom::{PointF, SizeF, Transform};
use comp_core::layer::Layer;

use crate::error::{IoError, IoResult};
use crate::psd::types::{
    PsdConversion, PsdHeader, PsdImport, PsdLayerKind, PsdMask, PsdReadOptions, PsdRecord,
};

/// Builds the document, the conversion report and the strict-mode check.
pub(crate) fn build(
    header: PsdHeader,
    resolution: f64,
    records: Vec<PsdRecord>,
    mut conversions: Vec<PsdConversion>,
    options: &PsdReadOptions,
) -> IoResult<PsdImport> {
    let canvas = (header.width, header.height);
    let mut document = Document::new(header.width, header.height);
    document.resolution = resolution;
    let clipping = clipping_bases(&records, &mut conversions);

    for record in &records {
        if record.kind == PsdLayerKind::Adjustment && record.adjustment.is_none() {
            conversions.push(PsdConversion::new(
                record.name.clone(),
                "This adjustment type is not supported, so the layer was skipped.",
            ));
            continue;
        }
        let mut layer = build_layer(record, canvas, &mut conversions);
        if let Some(base) = clipping.get(&record.id) {
            layer.mask_source = Some(*base);
        }
        document.add_layer(layer, record.parent);
    }
    // macOS selects the topmost root layer of an imported file, falling back to the last layer.
    document.active_layer = document
        .layers
        .iter()
        .rev()
        .find(|layer| layer.parent.is_none())
        .or_else(|| document.layers.last())
        .map(|layer| layer.id);

    if options.strict && !conversions.is_empty() {
        let report = conversions.iter().map(|conversion| conversion.to_string()).collect::<Vec<_>>().join("; ");
        return Err(IoError::UnsupportedFeature(format!(
            "strict reading refuses this file: {report}"
        )));
    }
    Ok(PsdImport { document, header, resolution, conversions })
}

/// One layer for one record.
fn build_layer(record: &PsdRecord, canvas: (u32, u32), conversions: &mut Vec<PsdConversion>) -> Layer {
    let mut layer = if record.is_group {
        Layer::group(record.name.clone(), canvas.0, canvas.1)
    } else if let Some(adjustment) = &record.adjustment {
        Layer::adjustment(record.name.clone(), adjustment.clone(), canvas.0, canvas.1)
    } else if let Some(image) = &record.image {
        let mut layer = Layer::with_image(record.name.clone(), image.clone());
        let (x, y, width, height) = record.bounds;
        // An empty rectangle with pixels still has a grid: Photoshop writes zero bounds for a
        // layer whose content it could not measure.
        let size = if width > 0.0 && height > 0.0 {
            SizeF::new(width, height)
        } else {
            SizeF::new(f64::from(image.width()), f64::from(image.height()))
        };
        layer.transform = Transform::new(PointF::new(x, y), size);
        layer
    } else {
        Layer::raster(record.name.clone(), canvas.0, canvas.1)
    };
    // The record's id is the document's: a clipping link or a group's parent id refers to it.
    layer.id = record.id;
    layer.image_file = if layer.image.is_some() { Some(layer.expected_image_file()) } else { None };
    layer.visible = record.visible;
    layer.opacity = record.opacity;
    layer.blend = if record.is_group { BlendMode::Normal } else { record.blend.unwrap_or(BlendMode::Normal) };

    if let Some(mask) = &record.mask {
        let (grid_width, grid_height) = record.mask_grid(canvas);
        match mask_on_layer_grid(mask, &layer.transform, grid_width, grid_height) {
            Some(pixels) => {
                layer.mask = Some(Arc::new(pixels));
                layer.mask_file = Some(layer.expected_mask_file());
                layer.mask_enabled = record.mask_enabled;
                // The mask buffer is on the layer's own grid, so it is linked by definition: it
                // already carries the file's mask placement as pixels.
                layer.mask_linked = true;
                layer.mask_placement = None;
            }
            None => conversions.push(PsdConversion::new(
                record.name.clone(),
                "The layer mask could not be built at the layer's size and was skipped.",
            )),
        }
    } else if record.mask_skipped {
        conversions.push(PsdConversion::new(
            record.name.clone(),
            "The layer mask could not be converted to 8-bit grayscale and was skipped.",
        ));
    }

    report_kind(record, &mut *conversions);
    if record.cropped {
        conversions.push(PsdConversion::new(
            record.name.clone(),
            "Cropped to the canvas so the file fits in memory. Pixels outside the canvas were not imported.",
        ));
    }
    if record.is_group {
        let key = record.blend_key.as_str();
        if !key.is_empty() && key != "pass" && key != "norm" {
            conversions.push(PsdConversion::new(
                record.name.clone(),
                format!("Folder blend mode \"{key}\" is not supported. The folder will be pass-through."),
            ));
        }
    } else if record.blend.is_none() {
        let key = record.blend_key.as_str();
        if !key.is_empty() && key != "pass" {
            conversions.push(PsdConversion::new(
                record.name.clone(),
                format!("Blend mode \"{key}\" is not supported and will be applied as Normal."),
            ));
        }
    }
    if record.adjustment.is_some() {
        conversions.push(PsdConversion::new(
            record.name.clone(),
            "Adjustment parameters may not match Photoshop exactly.",
        ));
    }
    layer
}

/// What importing this kind of layer costs in fidelity.
fn report_kind(record: &PsdRecord, conversions: &mut Vec<PsdConversion>) {
    match record.kind {
        PsdLayerKind::Text => {
            if record.image.is_some() {
                conversions.push(PsdConversion::new(
                    record.name.clone(),
                    "The text layer was imported as pixels; its text cannot be edited.",
                ));
            } else {
                conversions.push(PsdConversion::new(
                    record.name.clone(),
                    "The text layer has no pixel data, so it was imported empty.",
                ));
            }
        }
        PsdLayerKind::Vector => conversions.push(PsdConversion::new(
            record.name.clone(),
            "Vector shape was rasterized to pixels.",
        )),
        PsdLayerKind::SmartObject => conversions.push(PsdConversion::new(
            record.name.clone(),
            "The smart object was rasterized; linked contents cannot be edited.",
        )),
        PsdLayerKind::Effects => conversions.push(PsdConversion::new(
            record.name.clone(),
            "Layer effects were discarded, so the appearance may differ.",
        )),
        PsdLayerKind::Other => conversions.push(PsdConversion::new(
            record.name.clone(),
            "This Photoshop layer type is not supported and was imported as pixels.",
        )),
        PsdLayerKind::Raster | PsdLayerKind::Group | PsdLayerKind::Adjustment => {}
    }
}

/// Which layer each clipping layer is clipped to, as PSDDocumentBuilder resolves maskSourceID.
fn clipping_bases(records: &[PsdRecord], conversions: &mut Vec<PsdConversion>) -> HashMap<Uuid, Uuid> {
    let mut bases: HashMap<Option<Uuid>, Uuid> = HashMap::new();
    let mut result = HashMap::new();
    for record in records {
        if record.clipping {
            match bases.get(&record.parent) {
                Some(base) => {
                    let supported = records
                        .iter()
                        .find(|other| other.id == *base)
                        .map(|other| !other.is_group && other.adjustment.is_none())
                        .unwrap_or(false);
                    if supported {
                        result.insert(record.id, *base);
                    } else {
                        conversions.push(PsdConversion::new(
                            record.name.clone(),
                            "This clipping mask's base is not supported, so clipping was skipped.",
                        ));
                    }
                }
                None => conversions.push(PsdConversion::new(
                    record.name.clone(),
                    "This clipping mask's base is not supported, so clipping was skipped.",
                )),
            }
        } else if !record.is_group && record.adjustment.is_none() {
            bases.insert(record.parent, record.id);
        } else {
            bases.insert(record.parent, Uuid::nil());
        }
    }
    result
}

/// Draws the mask patch where it sits on the layer's own pixel grid.
///
/// macOS's maskOnLayerGrid puts the patch on the layer's grid with Photoshop's default value
/// everywhere else; stretching the patch alone over the layer would put the mask in the wrong
/// place. Nearest sampling matches the no-interpolation draw macOS uses.
fn mask_on_layer_grid(mask: &PsdMask, transform: &Transform, grid_width: u32, grid_height: u32) -> Option<Gray8> {
    if grid_width < 1
        || grid_height < 1
        || transform.size.width <= 0.0
        || transform.size.height <= 0.0
        || mask.width <= 0.0
        || mask.height <= 0.0
        || mask.pixels.width() < 1
        || mask.pixels.height() < 1
    {
        return None;
    }
    let scale_x = f64::from(grid_width) / transform.size.width;
    let scale_y = f64::from(grid_height) / transform.size.height;
    let rect = (
        (mask.x - transform.origin.x) * scale_x,
        (mask.y - transform.origin.y) * scale_y,
        mask.width * scale_x,
        mask.height * scale_y,
    );
    // Already the layer's grid: nothing to place.
    if rect.0 == 0.0
        && rect.1 == 0.0
        && rect.2 == f64::from(grid_width)
        && rect.3 == f64::from(grid_height)
        && mask.pixels.width() == grid_width
        && mask.pixels.height() == grid_height
    {
        return Some(mask.pixels.clone());
    }
    let mut out = Gray8::filled(grid_width, grid_height, mask.default_value);
    let x_start = rect.0.floor().max(0.0) as i64;
    let y_start = rect.1.floor().max(0.0) as i64;
    let x_end = ((rect.0 + rect.2).ceil() as i64).clamp(0, i64::from(grid_width));
    let y_end = ((rect.1 + rect.3).ceil() as i64).clamp(0, i64::from(grid_height));
    let source_width = mask.pixels.width();
    let source_height = mask.pixels.height();
    for y in y_start..y_end {
        let v = (y as f64 + 0.5 - rect.1) / rect.3;
        if !(0.0..1.0).contains(&v) {
            continue;
        }
        let source_y = ((v * f64::from(source_height)) as u32).min(source_height - 1);
        for x in x_start..x_end {
            let u = (x as f64 + 0.5 - rect.0) / rect.2;
            if !(0.0..1.0).contains(&u) {
                continue;
            }
            let source_x = ((u * f64::from(source_width)) as u32).min(source_width - 1);
            out.set(x as u32, y as u32, mask.pixels.get(source_x, source_y));
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::psd::types::PsdColorMode;

    fn header() -> PsdHeader {
        PsdHeader { version: 1, channels: 3, width: 8, height: 8, depth: 8, color_mode: PsdColorMode::Rgb }
    }

    #[test]
    fn a_mask_patch_lands_on_the_layer_grid_with_the_default_around_it() {
        let mut patch = Gray8::filled(2, 2, 0);
        patch.set(0, 0, 200);
        let mask = PsdMask { pixels: patch, x: 2.0, y: 2.0, width: 2.0, height: 2.0, default_value: 255 };
        let transform = Transform::with_size(8.0, 8.0);
        let built = mask_on_layer_grid(&mask, &transform, 8, 8).unwrap();
        assert_eq!((built.width(), built.height()), (8, 8));
        assert_eq!(built.get(2, 2), 200);
        assert_eq!(built.get(0, 0), 255);
        assert_eq!(built.get(3, 3), 0);
    }

    #[test]
    fn a_mask_that_already_covers_the_grid_is_kept_as_is() {
        let patch = Gray8::filled(4, 4, 128);
        let mask = PsdMask { pixels: patch, x: 0.0, y: 0.0, width: 4.0, height: 4.0, default_value: 255 };
        let transform = Transform::with_size(4.0, 4.0);
        let built = mask_on_layer_grid(&mask, &transform, 4, 4).unwrap();
        assert_eq!(built.get(1, 1), 128);
        assert!(built.is_uniform());
    }

    #[test]
    fn a_mask_is_scaled_onto_a_layer_with_a_different_grid() {
        let patch = Gray8::filled(2, 2, 0);
        let mask = PsdMask { pixels: patch, x: 4.0, y: 4.0, width: 4.0, height: 4.0, default_value: 255 };
        // The layer's transform is twice the size of its pixel grid, so the patch halves.
        let transform = Transform::with_size(16.0, 16.0);
        let built = mask_on_layer_grid(&mask, &transform, 8, 8).unwrap();
        assert_eq!((built.width(), built.height()), (8, 8));
        assert_eq!(built.get(2, 2), 0);
        assert_eq!(built.get(1, 1), 255);
    }

    #[test]
    fn unsupported_blend_keys_become_notes() {
        let record = PsdRecord {
            blend_key: "diss".into(),
            ..PsdRecord::new(Uuid::new_v4(), "Sparkle".into())
        };
        let mut conversions = Vec::new();
        let layer = build_layer(&record, (8, 8), &mut conversions);
        assert_eq!(layer.blend, BlendMode::Normal);
        assert!(conversions.iter().any(|conversion| conversion.message.contains("diss")));
    }

    #[test]
    fn strict_reading_refuses_a_file_the_import_would_approximate() {
        let records = vec![PsdRecord {
            blend_key: "diss".into(),
            ..PsdRecord::new(Uuid::new_v4(), "Sparkle".into())
        }];
        let strict = PsdReadOptions { strict: true, ..PsdReadOptions::default() };
        let error = build(header(), 72.0, records.clone(), Vec::new(), &strict).unwrap_err();
        assert!(matches!(error, IoError::UnsupportedFeature(_)), "{error:?}");

        let lenient = PsdReadOptions::default();
        let import = build(header(), 72.0, records, Vec::new(), &lenient).unwrap();
        assert_eq!(import.conversions.len(), 1);
        assert!(import.report().contains("Sparkle"));
    }
}
