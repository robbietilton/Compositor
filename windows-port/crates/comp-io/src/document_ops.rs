//! Document-level size operations: image size, canvas size, crop and trim.
//!
//! These are the Rust side of macOS's ImageResizer and CanvasResizer actors. Both work on the
//! document's layer list, never on a flattened bitmap: pixels are re-sampled only where a layer's
//! own pixel grid has to change, so a hidden layer keeps its content and a mask follows it.
use std::sync::Arc;

use rayon::prelude::*;
use uuid::Uuid;

use comp_core::bitmap::{Bitmap8, Gray8};
use comp_core::document::Document;
use comp_core::geom::{GuideAxis, PointF, RectF, Sampling, SizeF, Transform};
use comp_core::layer::Layer;
use comp_core::limits;

use crate::error::{IoError, IoResult};
use crate::image_ops::{trim_rect, TrimOptions};

/// The largest canvas translation the format allows, matching CanvasSizeOptions validation.
const MAX_CANVAS_OFFSET: f64 = 1_000_000.0;

/// The settings of "Image Size": a new pixel size, a resolution, and how to resample.
#[derive(Clone, Copy, Debug)]
pub struct ImageSizeOptions {
    pub width: u32,
    pub height: u32,
    /// Pixels per inch, 1 through 9600.
    pub resolution: f64,
    pub sampling: Sampling,
}

impl Default for ImageSizeOptions {
    fn default() -> Self {
        ImageSizeOptions { width: 1, height: 1, resolution: 72.0, sampling: Sampling::HighQuality }
    }
}

/// The settings of "Canvas Size": a new pixel size, an anchor, and an optional extension color.
#[derive(Clone, Copy, Debug)]
pub struct CanvasSizeOptions {
    pub width: u32,
    pub height: u32,
    /// Row-major anchor, 0 (top left) through 8 (bottom right). 4 centers the content.
    pub anchor: u8,
    /// Extends the canvas with this color, as a new bottom layer. None leaves it transparent.
    pub fill: Option<[u8; 3]>,
    /// An explicit document-space translation. Crop and trim supply it instead of an anchor.
    pub content_offset: Option<(f64, f64)>,
}

impl Default for CanvasSizeOptions {
    fn default() -> Self {
        CanvasSizeOptions { width: 1, height: 1, anchor: 4, fill: None, content_offset: None }
    }
}

impl CanvasSizeOptions {
    /// The translation the anchor asks for.
    ///
    /// Flooring puts the extra pixel on the right and bottom when growing, and takes it from the
    /// left and top when shrinking around the center, exactly as CanvasSizeOptions.offset does.
    pub fn offset(&self, from_width: u32, from_height: u32) -> (f64, f64) {
        if let Some(offset) = self.content_offset {
            return offset;
        }
        let x = ((self.width as f64 - from_width as f64) * f64::from(self.anchor % 3) / 2.0).floor();
        let y = ((self.height as f64 - from_height as f64) * f64::from(self.anchor / 3) / 2.0).floor();
        (x, y)
    }
}

/// Resizes the document: the canvas, every layer's placement, and every layer's pixel grid.
///
/// The new boxes and the pixel budget are worked out before anything changes, so a resize that
/// cannot be afforded leaves the document exactly as it was.
pub fn resize_document(document: &mut Document, options: &ImageSizeOptions) -> IoResult<()> {
    validate_size(options.width, options.height)?;
    let resolution = validate_resolution(options.resolution)?;
    let old_width = document.width;
    let old_height = document.height;
    if old_width == 0 || old_height == 0 {
        return Err(IoError::Invalid("the document has no pixels to resize".into()));
    }
    if old_width == options.width && old_height == options.height {
        document.resolution = resolution;
        return Ok(());
    }
    let sx = options.width as f64 / old_width as f64;
    let sy = options.height as f64 / old_height as f64;
    let budget = limits::document_pixel_budget();
    let mut boxes = Vec::with_capacity(document.layers.len());
    let mut used_image_pixels = 0u64;
    let mut used_mask_pixels = 0u64;
    for layer in &document.layers {
        let scaled = scaled_box(&layer.transform, sx, sy)?;
        let pixels = u64::from(scaled.2) * u64::from(scaled.3);
        if layer.image.is_some() {
            if pixels > budget.saturating_sub(used_image_pixels) {
                return Err(IoError::TooLarge(format!(
                    "resizing to {}x{} would need more layer pixels than the document budget allows",
                    options.width, options.height
                )));
            }
            used_image_pixels += pixels;
        }
        // A uniform mask is resolution independent, and an unlinked one keeps its own pixels:
        // neither needs a new buffer, so neither spends mask budget.
        let unlinked = !layer.mask_linked && layer.mask_placement.is_some();
        if let Some(mask) = &layer.mask {
            if !unlinked && (mask.width() > 1 || mask.height() > 1) {
                if pixels > budget.saturating_sub(used_mask_pixels) {
                    return Err(IoError::TooLarge(format!(
                        "resizing to {}x{} would need more mask pixels than the document budget allows",
                        options.width, options.height
                    )));
                }
                used_mask_pixels += pixels;
            }
        }
        boxes.push(scaled);
    }

    for guide in &mut document.guides {
        match guide.axis {
            GuideAxis::Horizontal => guide.position *= sy,
            GuideAxis::Vertical => guide.position *= sx,
        }
    }
    document.resolution = resolution;
    document.width = options.width;
    document.height = options.height;
    let layers = std::mem::take(&mut document.layers);
    let mut resized = Vec::with_capacity(layers.len());
    for (mut layer, (left, top, width, height)) in layers.into_iter().zip(boxes) {
        if let Some(image) = layer.image.clone() {
            let rasterized =
                rasterize_bitmap(&image, &layer.transform, left, top, width, height, sx, sy, options.sampling);
            layer.image = Some(Arc::new(rasterized));
        }
        if let Some(mask) = layer.mask.clone() {
            let unlinked = !layer.mask_linked && layer.mask_placement.is_some();
            if unlinked {
                if let Some(placement) = layer.mask_placement.as_mut() {
                    placement.origin.x *= sx;
                    placement.origin.y *= sy;
                    placement.size.width *= sx;
                    placement.size.height *= sy;
                }
            } else if mask.width() > 1 || mask.height() > 1 {
                let rasterized =
                    rasterize_mask(&mask, &layer.transform, left, top, width, height, sx, sy, options.sampling);
                layer.mask = Some(Arc::new(rasterized));
            }
        }
        // The new transform carries no rotation or flips: the rasterized pixels already do.
        layer.transform = Transform {
            origin: PointF::new(left, top),
            size: SizeF::new(width as f64, height as f64),
            rotation: 0.0,
            flip_x: false,
            flip_y: false,
            sampling: options.sampling,
        };
        resized.push(layer);
    }
    document.layers = resized;
    // A resize leaves every layer in place, so the selection is preserved by id.
    if let Some(active) = document.active_layer {
        if document.index_of(active).is_none() {
            document.active_layer = document.layers.last().map(|layer| layer.id);
        }
    }
    Ok(())
}

/// Changes the canvas size, moving every layer and guide by the anchor's offset.
///
/// Every layer is checked and the extension layer's budget is reserved before the document moves,
/// so a canvas size the format cannot hold leaves the document untouched.
pub fn canvas_resize(document: &mut Document, options: &CanvasSizeOptions) -> IoResult<()> {
    validate_size(options.width, options.height)?;
    if options.anchor > 8 {
        return Err(IoError::Invalid(format!("canvas anchor {} is outside 0-8", options.anchor)));
    }
    let old_width = document.width;
    let old_height = document.height;
    let (dx, dy) = options.offset(old_width, old_height);
    if !dx.is_finite() || !dy.is_finite() || dx.abs() > MAX_CANVAS_OFFSET || dy.abs() > MAX_CANVAS_OFFSET {
        return Err(IoError::Invalid(format!("the canvas offset ({dx}, {dy}) is not usable")));
    }
    if options.width == old_width && options.height == old_height && dx == 0.0 && dy == 0.0 {
        return Ok(());
    }
    for layer in &document.layers {
        let mut moved = layer.transform;
        moved.origin.x += dx;
        moved.origin.y += dy;
        if !moved.is_valid() {
            return Err(IoError::TooLarge(format!(
                "layer \"{}\" would sit outside the canvas the format can represent",
                layer.name
            )));
        }
    }
    // Growing with a color adds a bottom layer, so it has to fit the budget and the layer limit.
    let grows = options.width > old_width || options.height > old_height;
    let extend = options.fill.filter(|_| grows);
    if extend.is_some() {
        let used_pixels = document.pixel_counts().0;
        let wanted = u64::from(options.width) * u64::from(options.height);
        if wanted > limits::document_pixel_budget().saturating_sub(used_pixels) {
            return Err(IoError::TooLarge(
                "the canvas extension would exceed the document's pixel budget".into(),
            ));
        }
        if document.layers.len() >= limits::MAX_LAYERS {
            return Err(IoError::TooLarge(format!(
                "a document holds at most {} layers",
                limits::MAX_LAYERS
            )));
        }
    }

    for guide in &mut document.guides {
        match guide.axis {
            GuideAxis::Horizontal => guide.position += dy,
            GuideAxis::Vertical => guide.position += dx,
        }
    }
    for layer in &mut document.layers {
        layer.transform.origin.x += dx;
        layer.transform.origin.y += dy;
        if let Some(placement) = layer.mask_placement.as_mut() {
            placement.origin.x += dx;
            placement.origin.y += dy;
        }
    }
    document.width = options.width;
    document.height = options.height;
    if let Some(fill) = extend {
        add_canvas_extension(document, fill, dx, dy, old_width, old_height);
    }
    Ok(())
}

/// Crops the canvas to an arbitrary rectangle, moving the layers instead of cutting them.
pub fn crop_document(document: &mut Document, rect: RectF) -> IoResult<()> {
    if !rect.is_finite() {
        return Err(IoError::Invalid("the crop rectangle is not finite".into()));
    }
    // macOS's CropGeometry.snapped: round the origin and keep at least one pixel.
    let x = rect.x.round();
    let y = rect.y.round();
    let width = (rect.max_x().round() - x).max(1.0);
    let height = (rect.max_y().round() - y).max(1.0);
    if x.abs() > MAX_CANVAS_OFFSET || y.abs() > MAX_CANVAS_OFFSET {
        return Err(IoError::Invalid(format!("the crop origin ({x}, {y}) is not usable")));
    }
    if width > limits::MAX_SIDE as f64 || height > limits::MAX_SIDE as f64 {
        return Err(IoError::TooLarge(format!("the crop {width}x{height} exceeds the side limit")));
    }
    canvas_resize(
        document,
        &CanvasSizeOptions {
            width: width as u32,
            height: height as u32,
            anchor: 4,
            fill: None,
            content_offset: Some((-x, -y)),
        },
    )
}

/// Trims the canvas to the content of a rendered canvas bitmap.
///
/// The caller renders the canvas (comp-render owns compositing); this shrinks the document to the
/// trim rectangle exactly as macOS's ImageTrim does through CanvasResizer. Returns false when the
/// trim rectangle already is the whole canvas.
pub fn trim_document(document: &mut Document, canvas: &Bitmap8, options: &TrimOptions) -> IoResult<bool> {
    if canvas.width() != document.width || canvas.height() != document.height {
        return Err(IoError::Invalid(format!(
            "the rendered canvas is {}x{} but the document is {}x{}",
            canvas.width(),
            canvas.height(),
            document.width,
            document.height
        )));
    }
    let rect = trim_rect(canvas, options).ok_or(IoError::NothingToTrim)?;
    if rect.x == 0 && rect.y == 0 && rect.width == document.width && rect.height == document.height {
        return Ok(false);
    }
    crop_document(
        document,
        RectF::new(rect.x as f64, rect.y as f64, rect.width as f64, rect.height as f64),
    )?;
    Ok(true)
}

/// Paints a new bottom layer with the extension color, leaving the old canvas transparent.
///
/// macOS fills the whole new canvas and then clears the old canvas rectangle, so a hole in the
/// existing artwork stays a hole instead of being filled in. canvas_resize reserves the budget
/// before calling this, so there is nothing left to fail on.
fn add_canvas_extension(document: &mut Document, fill: [u8; 3], dx: f64, dy: f64, old_width: u32, old_height: u32) {
    let mut image = Bitmap8::filled(document.width, document.height, [fill[0], fill[1], fill[2], 255]);
    image.fill_rect(dx as i64, dy as i64, old_width as i64, old_height as i64, [0, 0, 0, 0]);
    let extension = Layer::with_image("Canvas Extension", image);
    // Bottom of the stack, above nothing: the old artwork draws over the cleared rectangle.
    document.layers.insert(0, extension);
}

/// The document-space box a layer covers after the canvas is scaled.
fn scaled_box(transform: &Transform, sx: f64, sy: f64) -> IoResult<(f64, f64, u32, u32)> {
    let affine = transform.affine();
    let mut min_x = f64::INFINITY;
    let mut min_y = f64::INFINITY;
    let mut max_x = f64::NEG_INFINITY;
    let mut max_y = f64::NEG_INFINITY;
    for (u, v) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
        let corner = affine.apply(PointF::new(u * transform.size.width, v * transform.size.height));
        let x = corner.x * sx;
        let y = corner.y * sy;
        min_x = min_x.min(x);
        min_y = min_y.min(y);
        max_x = max_x.max(x);
        max_y = max_y.max(y);
    }
    if !min_x.is_finite() || !min_y.is_finite() || !max_x.is_finite() || !max_y.is_finite() {
        return Err(IoError::Invalid("a layer transform is not finite".into()));
    }
    let left = min_x.floor();
    let top = min_y.floor();
    let width = max_x.ceil() - left;
    let height = max_y.ceil() - top;
    if width < 1.0 || height < 1.0 {
        return Err(IoError::Invalid("a layer would end up with no pixels".into()));
    }
    if width > limits::MAX_SIDE as f64 || height > limits::MAX_SIDE as f64 {
        return Err(IoError::TooLarge(format!(
            "a layer would become {width}x{height} pixels, past the {} pixel side limit",
            limits::MAX_SIDE
        )));
    }
    Ok((left, top, width as u32, height as u32))
}

/// Draws a layer image into the grid it occupies after the scale.
///
/// The layer's own affine is inverted per destination pixel, so rotation, flips and a transform
/// size that differs from the pixel size all come out right; this is the Rust equivalent of
/// macOS drawing the source layer through a scaled Core Graphics context.
#[allow(clippy::too_many_arguments)]
fn rasterize_bitmap(
    source: &Bitmap8,
    transform: &Transform,
    left: f64,
    top: f64,
    width: u32,
    height: u32,
    sx: f64,
    sy: f64,
    sampling: Sampling,
) -> Bitmap8 {
    let mut pixels = vec![0u8; width as usize * height as usize * 4];
    let Some(inverse) = transform.affine().inverse() else {
        return Bitmap8::new(width, height);
    };
    let source_pixels = sample_plan(source.width(), source.height(), transform);
    pixels.par_chunks_mut(width as usize * 4).enumerate().for_each(|(y, row)| {
        for x in 0..width as usize {
            let document = PointF::new((left + x as f64 + 0.5) / sx, (top + y as f64 + 0.5) / sy);
            let local = inverse.apply(document);
            let pixel = match sampling {
                Sampling::Nearest => sample_nearest(source, &source_pixels, local.x, local.y),
                Sampling::HighQuality | Sampling::Smooth => {
                    sample_bilinear(source, &source_pixels, local.x, local.y)
                }
            };
            row[x * 4..x * 4 + 4].copy_from_slice(&pixel);
        }
    });
    Bitmap8::from_raw(width, height, pixels).unwrap_or_else(|_| Bitmap8::new(width, height))
}

/// The same inverse mapping for an 8-bit mask, which has no alpha to weigh.
#[allow(clippy::too_many_arguments)]
fn rasterize_mask(
    source: &Gray8,
    transform: &Transform,
    left: f64,
    top: f64,
    width: u32,
    height: u32,
    sx: f64,
    sy: f64,
    sampling: Sampling,
) -> Gray8 {
    let Some(inverse) = transform.affine().inverse() else {
        return Gray8::new(width, height);
    };
    let mut pixels = vec![0u8; width as usize * height as usize];
    let source_width = source.width() as f64;
    let source_height = source.height() as f64;
    let scale_u = source_width / transform.size.width;
    let scale_v = source_height / transform.size.height;
    pixels.par_chunks_mut(width as usize).enumerate().for_each(|(y, row)| {
        for (x, cell) in row.iter_mut().enumerate() {
            let document = PointF::new((left + x as f64 + 0.5) / sx, (top + y as f64 + 0.5) / sy);
            let local = inverse.apply(document);
            let u = local.x * scale_u;
            let v = local.y * scale_v;
            *cell = match sampling {
                Sampling::Nearest => {
                    if u < 0.0 || v < 0.0 || u >= source_width || v >= source_height {
                        0
                    } else {
                        source.get(u.floor() as u32, v.floor() as u32)
                    }
                }
                Sampling::HighQuality | Sampling::Smooth => {
                    let (x0, y0, wx, wy) = bilinear_weights(u, v);
                    let mut acc = 0.0;
                    for (dx, dy, weight) in [
                        (x0, y0, (1.0 - wx) * (1.0 - wy)),
                        (x0 + 1, y0, wx * (1.0 - wy)),
                        (x0, y0 + 1, (1.0 - wx) * wy),
                        (x0 + 1, y0 + 1, wx * wy),
                    ] {
                        if dx < 0 || dy < 0 || dx >= source.width() as i64 || dy >= source.height() as i64 {
                            continue;
                        }
                        acc += source.get(dx as u32, dy as u32) as f64 * weight;
                    }
                    acc.round().clamp(0.0, 255.0) as u8
                }
            };
        }
    });
    Gray8::from_raw(width, height, pixels).unwrap_or_else(|_| Gray8::new(width, height))
}

/// How a source pixel grid maps onto a transform box.
struct SamplePlan {
    scale_u: f64,
    scale_v: f64,
}

fn sample_plan(source_width: u32, source_height: u32, transform: &Transform) -> SamplePlan {
    SamplePlan {
        scale_u: source_width as f64 / transform.size.width,
        scale_v: source_height as f64 / transform.size.height,
    }
}

/// Straight RGBA at a local coordinate, or transparent outside the source.
fn sample_nearest(source: &Bitmap8, plan: &SamplePlan, local_x: f64, local_y: f64) -> [u8; 4] {
    let u = local_x * plan.scale_u;
    let v = local_y * plan.scale_v;
    if u < 0.0 || v < 0.0 || u >= source.width() as f64 || v >= source.height() as f64 {
        return [0, 0, 0, 0];
    }
    source.get(u.floor() as u32, v.floor() as u32)
}

/// Bilinear RGBA at a local coordinate, interpolated premultiplied so edges keep their color.
fn sample_bilinear(source: &Bitmap8, plan: &SamplePlan, local_x: f64, local_y: f64) -> [u8; 4] {
    let u = local_x * plan.scale_u;
    let v = local_y * plan.scale_v;
    let (x0, y0, wx, wy) = bilinear_weights(u, v);
    let mut acc = [0.0f64; 4];
    for (x, y, weight) in [
        (x0, y0, (1.0 - wx) * (1.0 - wy)),
        (x0 + 1, y0, wx * (1.0 - wy)),
        (x0, y0 + 1, (1.0 - wx) * wy),
        (x0 + 1, y0 + 1, wx * wy),
    ] {
        if weight == 0.0 || x < 0 || y < 0 || x >= source.width() as i64 || y >= source.height() as i64 {
            continue;
        }
        let pixel = source.get(x as u32, y as u32);
        let alpha = pixel[3] as f64 / 255.0;
        acc[0] += pixel[0] as f64 * alpha * weight;
        acc[1] += pixel[1] as f64 * alpha * weight;
        acc[2] += pixel[2] as f64 * alpha * weight;
        acc[3] += pixel[3] as f64 * weight;
    }
    let alpha = acc[3];
    let mut out = [0u8; 4];
    if alpha > 0.0 {
        let scale = 255.0 / alpha;
        out[0] = (acc[0] * scale).round().clamp(0.0, 255.0) as u8;
        out[1] = (acc[1] * scale).round().clamp(0.0, 255.0) as u8;
        out[2] = (acc[2] * scale).round().clamp(0.0, 255.0) as u8;
    }
    out[3] = alpha.round().clamp(0.0, 255.0) as u8;
    out
}

/// The four weights around a sample point, using pixel centers as Core Graphics does.
fn bilinear_weights(u: f64, v: f64) -> (i64, i64, f64, f64) {
    let fx = u - 0.5;
    let fy = v - 0.5;
    let x0 = fx.floor();
    let y0 = fy.floor();
    (x0 as i64, y0 as i64, fx - x0, fy - y0)
}

fn validate_size(width: u32, height: u32) -> IoResult<()> {
    if width == 0 || height == 0 {
        return Err(IoError::Invalid(format!("a document must have pixels; got {width}x{height}")));
    }
    if width > limits::MAX_SIDE || height > limits::MAX_SIDE {
        return Err(IoError::TooLarge(format!(
            "{width}x{height} exceeds the {} pixel side limit",
            limits::MAX_SIDE
        )));
    }
    if width as u64 * height as u64 > limits::MAX_SURFACE_PIXELS {
        return Err(IoError::TooLarge(format!(
            "{width}x{height} exceeds the {} pixel surface limit",
            limits::MAX_SURFACE_PIXELS
        )));
    }
    Ok(())
}

fn validate_resolution(resolution: f64) -> IoResult<f64> {
    if !resolution.is_finite() || !(1.0..=9600.0).contains(&resolution) {
        return Err(IoError::Invalid(format!(
            "resolution {resolution} is outside the 1-9600 pixels per inch the format allows"
        )));
    }
    Ok(resolution)
}

/// The id a canvas extension layer gets; exposed so callers can find it after a resize.
pub fn canvas_extension_layer_id(document: &Document) -> Option<Uuid> {
    document.layers.iter().find(|layer| layer.name == "Canvas Extension").map(|layer| layer.id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use comp_core::geom::Guide;

    fn document_with_dot(width: u32, height: u32) -> Document {
        let mut document = Document::new(width, height);
        let mut image = Bitmap8::new(width, height);
        for y in 0..height {
            for x in 0..width {
                image.set(x, y, [10, 20, 30, 255]);
            }
        }
        document.add_layer(Layer::with_image("Art", image), None);
        document
    }

    #[test]
    fn image_size_scales_the_layer_and_keeps_the_resolution_rule() {
        let mut document = document_with_dot(8, 4);
        document.resolution = 300.0;
        resize_document(
            &mut document,
            &ImageSizeOptions { width: 16, height: 8, resolution: 300.0, sampling: Sampling::HighQuality },
        )
        .unwrap();
        assert_eq!((document.width, document.height), (16, 8));
        assert_eq!(document.resolution, 300.0);
        let layer = &document.layers[0];
        assert_eq!(layer.transform.origin, PointF::new(0.0, 0.0));
        assert_eq!(layer.transform.size, SizeF::new(16.0, 8.0));
        let image = layer.image.as_ref().unwrap();
        assert_eq!((image.width(), image.height()), (16, 8));
        assert_eq!(image.get(8, 4), [10, 20, 30, 255]);
    }

    #[test]
    fn image_size_with_the_same_pixels_only_sets_the_resolution() {
        let mut document = document_with_dot(6, 6);
        let before = document.layers[0].image.clone();
        resize_document(
            &mut document,
            &ImageSizeOptions { width: 6, height: 6, resolution: 150.0, sampling: Sampling::Nearest },
        )
        .unwrap();
        assert_eq!(document.resolution, 150.0);
        assert!(Arc::ptr_eq(&before.unwrap(), document.layers[0].image.as_ref().unwrap()));
    }

    #[test]
    fn image_size_scales_guides_and_rejects_bad_settings() {
        let mut document = document_with_dot(10, 10);
        document.guides.push(Guide {
            id: Uuid::new_v4(),
            axis: GuideAxis::Vertical,
            position: 4.0,
        });
        document.guides.push(Guide { id: Uuid::new_v4(), axis: GuideAxis::Horizontal, position: 2.0 });
        resize_document(
            &mut document,
            &ImageSizeOptions { width: 20, height: 30, resolution: 72.0, sampling: Sampling::Smooth },
        )
        .unwrap();
        assert_eq!(document.guides[0].position, 8.0);
        assert_eq!(document.guides[1].position, 6.0);

        assert!(matches!(
            resize_document(
                &mut document,
                &ImageSizeOptions { width: 0, height: 10, resolution: 72.0, sampling: Sampling::Smooth }
            ),
            Err(IoError::Invalid(_))
        ));
        assert!(matches!(
            resize_document(
                &mut document,
                &ImageSizeOptions { width: 10, height: 10, resolution: 0.0, sampling: Sampling::Smooth }
            ),
            Err(IoError::Invalid(_))
        ));
        assert!(matches!(
            resize_document(
                &mut document,
                &ImageSizeOptions {
                    width: limits::MAX_SIDE + 1,
                    height: 1,
                    resolution: 72.0,
                    sampling: Sampling::Smooth
                }
            ),
            Err(IoError::TooLarge(_))
        ));
    }

    #[test]
    fn image_size_rasterizes_a_rotated_layer_into_an_axis_aligned_box() {
        let mut document = Document::new(20, 20);
        let image = Bitmap8::filled(4, 4, [255, 0, 0, 255]);
        let mut layer = Layer::with_image("Rotated", image);
        layer.transform = Transform {
            origin: PointF::new(8.0, 8.0),
            size: SizeF::new(4.0, 4.0),
            rotation: 45.0,
            flip_x: false,
            flip_y: false,
            sampling: Sampling::HighQuality,
        };
        document.add_layer(layer, None);
        resize_document(
            &mut document,
            &ImageSizeOptions { width: 40, height: 40, resolution: 72.0, sampling: Sampling::HighQuality },
        )
        .unwrap();
        let layer = &document.layers[0];
        assert_eq!(layer.transform.rotation, 0.0);
        // A 4x4 box at (8, 8) turned 45 degrees spans 7.17-12.83; doubled and floored that is 14.
        assert_eq!(layer.transform.origin, PointF::new(14.0, 14.0));
        assert_eq!((layer.transform.size.width, layer.transform.size.height), (12.0, 12.0));
        let resized = layer.image.as_ref().unwrap();
        assert_eq!((resized.width(), resized.height()), (12, 12));
        // A 45-degree square covers the middle of its box and leaves the corners empty.
        assert!(resized.get(6, 6)[3] > 200);
        assert_eq!(resized.get(0, 0)[3], 0);
    }

    #[test]
    fn masks_follow_the_layer_through_an_image_size() {
        let mut document = document_with_dot(8, 8);
        let mut mask = Gray8::filled(8, 8, 255);
        mask.set(0, 0, 0);
        document.layers[0].mask = Some(Arc::new(mask));
        document.layers[0].mask_file = Some("x.mask.png".into());
        resize_document(
            &mut document,
            &ImageSizeOptions { width: 4, height: 4, resolution: 72.0, sampling: Sampling::HighQuality },
        )
        .unwrap();
        let mask = document.layers[0].mask.as_ref().unwrap();
        assert_eq!((mask.width(), mask.height()), (4, 4));
        assert!(mask.get(3, 3) > 200);
    }

    #[test]
    fn a_uniform_mask_stays_one_pixel() {
        let mut document = document_with_dot(8, 8);
        document.layers[0].mask = Some(Arc::new(Gray8::filled(1, 1, 128)));
        document.layers[0].mask_file = Some("x.mask.png".into());
        resize_document(
            &mut document,
            &ImageSizeOptions { width: 32, height: 32, resolution: 72.0, sampling: Sampling::HighQuality },
        )
        .unwrap();
        let mask = document.layers[0].mask.as_ref().unwrap();
        assert_eq!((mask.width(), mask.height()), (1, 1));
        assert_eq!(mask.get(0, 0), 128);
    }

    #[test]
    fn an_unlinked_mask_placement_scales_with_the_canvas() {
        let mut document = document_with_dot(10, 10);
        let mut placement = Transform::with_size(4.0, 4.0);
        placement.origin = PointF::new(2.0, 3.0);
        document.layers[0].mask = Some(Arc::new(Gray8::filled(4, 4, 255)));
        document.layers[0].mask_placement = Some(placement);
        document.layers[0].mask_linked = false;
        resize_document(
            &mut document,
            &ImageSizeOptions { width: 20, height: 10, resolution: 72.0, sampling: Sampling::HighQuality },
        )
        .unwrap();
        let placement = document.layers[0].mask_placement.unwrap();
        assert_eq!(placement.origin, PointF::new(4.0, 3.0));
        assert_eq!((placement.size.width, placement.size.height), (8.0, 4.0));
        // The unlinked mask keeps its own pixels.
        assert_eq!(document.layers[0].mask.as_ref().unwrap().width(), 4);
    }

    #[test]
    fn canvas_size_anchors_center_and_edge_content() {
        let mut document = document_with_dot(10, 10);
        canvas_resize(
            &mut document,
            &CanvasSizeOptions { width: 20, height: 20, anchor: 4, ..CanvasSizeOptions::default() },
        )
        .unwrap();
        assert_eq!((document.width, document.height), (20, 20));
        assert_eq!(document.layers.len(), 1);
        assert_eq!(document.layers[0].transform.origin, PointF::new(5.0, 5.0));

        let mut document = document_with_dot(10, 10);
        canvas_resize(
            &mut document,
            &CanvasSizeOptions { width: 20, height: 20, anchor: 0, ..CanvasSizeOptions::default() },
        )
        .unwrap();
        assert_eq!(document.layers[0].transform.origin, PointF::new(0.0, 0.0));

        let mut document = document_with_dot(11, 11);
        canvas_resize(
            &mut document,
            &CanvasSizeOptions { width: 10, height: 10, anchor: 4, ..CanvasSizeOptions::default() },
        )
        .unwrap();
        // Shrinking around the center takes the odd pixel from the left and top.
        assert_eq!(document.layers[0].transform.origin, PointF::new(-1.0, -1.0));
    }

    #[test]
    fn canvas_size_extends_with_a_colored_bottom_layer() {
        let mut document = document_with_dot(4, 4);
        canvas_resize(
            &mut document,
            &CanvasSizeOptions {
                width: 8,
                height: 8,
                anchor: 4,
                fill: Some([255, 255, 255]),
                content_offset: None,
            },
        )
        .unwrap();
        assert_eq!(document.layers.len(), 2);
        let extension = &document.layers[0];
        assert_eq!(extension.name, "Canvas Extension");
        let image = extension.image.as_ref().unwrap();
        assert_eq!((image.width(), image.height()), (8, 8));
        assert_eq!(image.get(0, 0), [255, 255, 255, 255]);
        // The old canvas rectangle is a hole, so existing artwork shows through.
        assert_eq!(image.get(4, 4), [0, 0, 0, 0]);
        assert_eq!(canvas_extension_layer_id(&document), Some(extension.id));
    }

    #[test]
    fn shrinking_never_adds_an_extension_layer() {
        let mut document = document_with_dot(8, 8);
        canvas_resize(
            &mut document,
            &CanvasSizeOptions {
                width: 4,
                height: 4,
                anchor: 4,
                fill: Some([1, 2, 3]),
                content_offset: None,
            },
        )
        .unwrap();
        assert_eq!(document.layers.len(), 1);
        assert_eq!(document.layers[0].transform.origin, PointF::new(-2.0, -2.0));
    }

    #[test]
    fn canvas_size_validates_its_arguments_and_keeps_no_op_resizes_alone() {
        let mut document = document_with_dot(4, 4);
        assert!(canvas_resize(
            &mut document,
            &CanvasSizeOptions { width: 4, height: 4, anchor: 4, ..CanvasSizeOptions::default() }
        )
        .is_ok());
        assert_eq!(document.layers[0].transform.origin, PointF::new(0.0, 0.0));
        assert!(matches!(
            canvas_resize(
                &mut document,
                &CanvasSizeOptions { width: 4, height: 4, anchor: 9, ..CanvasSizeOptions::default() }
            ),
            Err(IoError::Invalid(_))
        ));
        assert!(matches!(
            canvas_resize(
                &mut document,
                &CanvasSizeOptions { width: 0, height: 4, anchor: 4, ..CanvasSizeOptions::default() }
            ),
            Err(IoError::Invalid(_))
        ));
        assert!(matches!(
            canvas_resize(
                &mut document,
                &CanvasSizeOptions {
                    width: 4,
                    height: 4,
                    anchor: 4,
                    content_offset: Some((f64::NAN, 0.0)),
                    ..CanvasSizeOptions::default()
                }
            ),
            Err(IoError::Invalid(_))
        ));
    }

    #[test]
    fn a_refused_resize_leaves_the_document_untouched() {
        let mut document = document_with_dot(8, 8);
        document.add_layer(Layer::with_image("Second", Bitmap8::filled(8, 8, [1, 2, 3, 255])), None);
        let before = document.clone();
        // Each layer would become 14400x13800 pixels: one fits the budget, two do not.
        let options = ImageSizeOptions {
            width: 14_400,
            height: 13_800,
            resolution: 72.0,
            sampling: Sampling::HighQuality,
        };
        assert!(matches!(resize_document(&mut document, &options), Err(IoError::TooLarge(_))));
        assert_eq!(document, before);
    }

    #[test]
    fn a_refused_canvas_size_leaves_the_document_untouched() {
        let mut document = document_with_dot(4, 4);
        let before = document.clone();
        assert!(matches!(
            canvas_resize(
                &mut document,
                &CanvasSizeOptions { width: 4, height: 4, anchor: 9, ..CanvasSizeOptions::default() }
            ),
            Err(IoError::Invalid(_))
        ));
        assert_eq!(document, before);
    }

    #[test]
    fn crop_snaps_the_rectangle_and_moves_the_layers() {
        let mut document = document_with_dot(10, 10);
        crop_document(&mut document, RectF::new(2.4, 3.6, 5.2, 4.1)).unwrap();
        // 2.4 rounds to 2 and 7.6 rounds to 8, so the crop is six pixels wide.
        assert_eq!((document.width, document.height), (6, 4));
        assert_eq!(document.layers[0].transform.origin, PointF::new(-2.0, -4.0));
        assert_eq!((document.layers[0].transform.size.width, document.layers[0].transform.size.height), (10.0, 10.0));

        let mut document = document_with_dot(10, 10);
        assert!(matches!(
            crop_document(&mut document, RectF::new(f64::NAN, 0.0, 4.0, 4.0)),
            Err(IoError::Invalid(_))
        ));
    }

    #[test]
    fn trim_shrinks_the_canvas_to_the_rendered_content() {
        let mut document = document_with_dot(10, 10);
        let mut canvas = Bitmap8::new(10, 10);
        for y in 2..6 {
            for x in 3..8 {
                canvas.set(x, y, [0, 0, 0, 255]);
            }
        }
        assert!(trim_document(&mut document, &canvas, &TrimOptions::default()).unwrap());
        assert_eq!((document.width, document.height), (5, 4));
        assert_eq!(document.layers[0].transform.origin, PointF::new(-3.0, -2.0));

        // A canvas that is already tight reports that nothing changed.
        let mut document = document_with_dot(10, 10);
        let full = Bitmap8::filled(10, 10, [0, 0, 0, 255]);
        assert!(!trim_document(&mut document, &full, &TrimOptions::default()).unwrap());
        let blank = Bitmap8::new(10, 10);
        assert!(matches!(
            trim_document(&mut document, &blank, &TrimOptions::default()),
            Err(IoError::NothingToTrim)
        ));
        let small = Bitmap8::new(4, 4);
        assert!(matches!(
            trim_document(&mut document, &small, &TrimOptions::default()),
            Err(IoError::Invalid(_))
        ));
    }
}
