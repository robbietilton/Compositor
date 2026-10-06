//! Writing a redrawn text or shape layer back into a document.
//!
//! This is the step the macOS app takes when a text or shape edit is committed: the metadata stays
//! editable and the pixels it produced replace the layer's image, so the PNG inside the `.comp`
//! package remains the source of truth for display and export.

use crate::layout::layout_text;
use crate::library::FontLibrary;
use crate::raster::rasterize_layout;
use crate::shape::rasterize_shape;
use comp_core::limits;
use comp_core::Document;
use uuid::Uuid;

/// Why a layer could not be redrawn.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CommitError {
    #[error("no layer with id {0}")]
    UnknownLayer(Uuid),
    #[error("layer {0} has no text style to draw")]
    MissingTextStyle(Uuid),
    #[error("layer {0} has no shape style to draw")]
    MissingShapeStyle(Uuid),
    #[error("the layer's style is not valid, so drawing it would be a guess")]
    InvalidStyle,
    #[error("the redrawn layer would be {width} by {height} pixels, past the format's limits")]
    TooLarge { width: u32, height: u32 },
}

/// Redraws a text layer's letters at its own style and stores them on the layer.
///
/// Returns the size of the raster written. The layer's transform is left alone: a caller that wants
/// the layer box to follow the new pixels can size it from `text_bounds` and place it itself.
pub fn commit_text_layer(
    document: &mut Document,
    layer_id: Uuid,
    library: &mut FontLibrary,
) -> Result<(u32, u32), CommitError> {
    let style = {
        let layer = document.layer(layer_id).ok_or(CommitError::UnknownLayer(layer_id))?;
        layer.text.clone().ok_or(CommitError::MissingTextStyle(layer_id))?
    };
    if !style.is_valid() {
        return Err(CommitError::InvalidStyle);
    }
    let layout = layout_text(&style, library);
    if !layout.fits_limits() {
        return Err(CommitError::TooLarge { width: layout.width, height: layout.height });
    }
    let size = (layout.width, layout.height);
    let bitmap = rasterize_layout(&layout);
    // The layer was found above and nothing removes it here, so the pixels it replaces (none the
    // first time) are not an error signal.
    document.set_layer_image(layer_id, bitmap);
    Ok(size)
}

/// Redraws a shape layer at the size its transform currently asks for, so a scaled rounded corner
/// keeps its radius instead of stretching.
pub fn commit_shape_layer(document: &mut Document, layer_id: Uuid) -> Result<(u32, u32), CommitError> {
    let (style, width, height) = {
        let layer = document.layer(layer_id).ok_or(CommitError::UnknownLayer(layer_id))?;
        let style = *layer.shape.as_ref().ok_or(CommitError::MissingShapeStyle(layer_id))?;
        (style, layer.transform.size.width, layer.transform.size.height)
    };
    if !style.is_valid() {
        return Err(CommitError::InvalidStyle);
    }
    let (width, height) = (layer_side(width), layer_side(height));
    if !limits::surface_fits(width, height) {
        return Err(CommitError::TooLarge { width, height });
    }
    let bitmap = rasterize_shape(&style, width, height);
    document.set_layer_image(layer_id, bitmap);
    Ok((width, height))
}

/// A layer's side as whole pixels: a degenerate transform still draws one pixel rather than nothing.
fn layer_side(value: f64) -> u32 {
    let rounded = if value.is_finite() { value.round() } else { 1.0 };
    rounded.clamp(1.0, limits::MAX_SIDE as f64) as u32
}

#[cfg(test)]
mod tests {
    use super::*;
    use comp_core::shape::{ShapeKind, ShapeStyle};
    use comp_core::text::{SizeD, TextStyle};
    use comp_core::{Bitmap8, Layer};

    fn bare_library() -> FontLibrary {
        FontLibrary::from_faces(Vec::new(), Vec::new())
    }

    fn document_with_text(style: TextStyle, width: u32, height: u32) -> (Document, Uuid) {
        let mut document = Document::new(width, height);
        let mut layer = Layer::raster("Text", width, height);
        layer.text = Some(style);
        let id = document.add_layer(layer, None);
        (document, id)
    }

    #[test]
    fn committing_text_writes_the_layer_image() {
        let style = TextStyle {
            content: "committed".into(),
            font_size: 12.0,
            box_size: Some(SizeD::new(120.0, 60.0)),
            ..TextStyle::default()
        };
        let (mut document, id) = document_with_text(style, 200, 200);
        let mut library = bare_library();
        let size = commit_text_layer(&mut document, id, &mut library).unwrap();
        assert_eq!(size, (120, 60));
        let layer = document.layer(id).unwrap();
        let image = layer.image.as_ref().expect("committing has to store pixels");
        assert_eq!((image.width(), image.height()), (120, 60));
        assert_eq!(layer.image_file.as_deref(), Some(layer.expected_image_file().as_str()));
    }

    #[test]
    fn committing_text_leaves_the_transform_alone() {
        let style = TextStyle { content: "kept".into(), font_size: 24.0, ..TextStyle::default() };
        let (mut document, id) = document_with_text(style, 200, 200);
        let before = document.layer(id).unwrap().transform;
        let mut library = bare_library();
        commit_text_layer(&mut document, id, &mut library).unwrap();
        assert_eq!(document.layer(id).unwrap().transform, before);
    }

    #[test]
    fn text_metadata_survives_committing() {
        let style = TextStyle { content: "round trip".into(), font_size: 18.0, ..TextStyle::default() };
        let (mut document, id) = document_with_text(style.clone(), 200, 200);
        let mut library = bare_library();
        commit_text_layer(&mut document, id, &mut library).unwrap();
        assert_eq!(document.layer(id).unwrap().text.as_ref(), Some(&style));
    }

    #[test]
    fn a_layer_without_text_is_refused() {
        let mut document = Document::new(20, 20);
        let id = document.add_layer(Layer::raster("plain", 20, 20), None);
        let mut library = bare_library();
        assert_eq!(
            commit_text_layer(&mut document, id, &mut library),
            Err(CommitError::MissingTextStyle(id))
        );
    }

    #[test]
    fn an_unknown_layer_is_refused() {
        let mut document = Document::new(20, 20);
        let mut library = bare_library();
        let stranger = Uuid::new_v4();
        assert_eq!(
            commit_text_layer(&mut document, stranger, &mut library),
            Err(CommitError::UnknownLayer(stranger))
        );
        assert_eq!(commit_shape_layer(&mut document, stranger), Err(CommitError::UnknownLayer(stranger)));
    }

    #[test]
    fn an_invalid_text_style_is_refused() {
        let style = TextStyle { content: "bad".into(), font_size: 0.5, ..TextStyle::default() };
        let (mut document, id) = document_with_text(style, 100, 100);
        let mut library = bare_library();
        assert_eq!(commit_text_layer(&mut document, id, &mut library), Err(CommitError::InvalidStyle));
    }

    #[test]
    fn a_text_past_the_limits_is_refused() {
        // A point text whose lines are wider and taller than the format allows: a valid style, but
        // there are no pixels to be had for it.
        let content = format!("{}
{}", "a".repeat(60), "a
".repeat(2_000));
        let style = TextStyle { content, font_size: 2_000.0, ..TextStyle::default() };
        assert!(style.is_valid(), "the style itself has to be acceptable");
        let (mut document, id) = document_with_text(style, 100, 100);
        let mut library = bare_library();
        assert_eq!(
            commit_text_layer(&mut document, id, &mut library),
            Err(CommitError::TooLarge { width: 30_000, height: 30_000 })
        );
        assert!(document.layer(id).unwrap().image.is_none(), "a refused commit must not touch pixels");
    }

    #[test]
    fn a_text_box_past_the_limits_is_refused_as_an_invalid_style() {
        let style = TextStyle {
            content: "huge".into(),
            box_size: Some(SizeD::new(30_000.0, 30_000.0)),
            ..TextStyle::default()
        };
        assert!(!style.is_valid(), "a box past the surface limit is not a usable style");
        let (mut document, id) = document_with_text(style, 100, 100);
        let mut library = bare_library();
        assert_eq!(commit_text_layer(&mut document, id, &mut library), Err(CommitError::InvalidStyle));
    }

    fn document_with_shape(style: ShapeStyle, width: u32, height: u32, scale: f64) -> (Document, Uuid) {
        let mut document = Document::new(400, 400);
        let mut layer = Layer::raster("Rectangle", 10, 10);
        layer.shape = Some(style);
        layer.transform = comp_core::Transform::with_size(
            width as f64 * scale,
            height as f64 * scale,
        );
        let id = document.add_layer(layer, None);
        (document, id)
    }

    #[test]
    fn committing_a_shape_draws_it_at_the_layer_size() {
        let (mut document, id) = document_with_shape(ShapeStyle::default(), 40, 20, 1.0);
        let size = commit_shape_layer(&mut document, id).unwrap();
        assert_eq!(size, (40, 20));
        let layer = document.layer(id).unwrap();
        let image = layer.image.as_ref().expect("the shape's pixels are stored");
        assert_eq!((image.width(), image.height()), (40, 20));
        assert_eq!(image.get(20, 10), [0, 0, 0, 255]);
        assert_eq!(layer.image_file.as_deref(), Some(layer.expected_image_file().as_str()));
    }

    #[test]
    fn a_rescaled_shape_keeps_its_metadata() {
        let style = ShapeStyle { kind: ShapeKind::Ellipse, corner_radius: 0.0, ..ShapeStyle::default() };
        let (mut document, id) = document_with_shape(style, 30, 30, 2.0);
        let size = commit_shape_layer(&mut document, id).unwrap();
        assert_eq!(size, (60, 60));
        assert_eq!(document.layer(id).unwrap().shape, Some(style));
        let image = document.layer(id).unwrap().image.clone().unwrap();
        assert_eq!(image.get(0, 0)[3], 0, "the corners of a circle stay empty");
        assert!(image.get(30, 30)[3] > 0, "the middle of the circle is drawn");
    }

    #[test]
    fn a_shape_layer_without_a_style_is_refused() {
        let mut document = Document::new(20, 20);
        let id = document.add_layer(Layer::raster("plain", 20, 20), None);
        assert_eq!(commit_shape_layer(&mut document, id), Err(CommitError::MissingShapeStyle(id)));
    }

    #[test]
    fn an_invalid_shape_style_is_refused() {
        let style = ShapeStyle { red: f64::NAN, ..ShapeStyle::default() };
        let (mut document, id) = document_with_shape(style, 10, 10, 1.0);
        assert_eq!(commit_shape_layer(&mut document, id), Err(CommitError::InvalidStyle));
    }

    #[test]
    fn a_degenerate_transform_still_draws_one_pixel() {
        let (mut document, id) = document_with_shape(ShapeStyle::default(), 0, 0, 1.0);
        assert_eq!(commit_shape_layer(&mut document, id).unwrap(), (1, 1));
        let image = document.layer(id).unwrap().image.clone().unwrap();
        assert_eq!(image.byte_len(), 4);
        assert_eq!(image.get(0, 0), [0, 0, 0, 255]);
    }

    #[test]
    fn a_shape_past_the_limits_is_refused() {
        let (mut document, id) = document_with_shape(ShapeStyle::default(), 30_000, 30_000, 1.0);
        assert!(matches!(
            commit_shape_layer(&mut document, id),
            Err(CommitError::TooLarge { .. })
        ));
        assert!(document.layer(id).unwrap().image.is_none());
    }

    #[test]
    fn committing_twice_replaces_the_pixels() {
        let style = TextStyle { content: "twice".into(), font_size: 20.0, ..TextStyle::default() };
        let (mut document, id) = document_with_text(style, 100, 100);
        let mut library = bare_library();
        commit_text_layer(&mut document, id, &mut library).unwrap();
        let first = document.layer(id).unwrap().image.clone().unwrap();
        commit_text_layer(&mut document, id, &mut library).unwrap();
        let second = document.layer(id).unwrap().image.clone().unwrap();
        assert_eq!(first, second);
        assert_eq!(document.layer(id).unwrap().image_file.as_deref(), Some(document.layer(id).unwrap().expected_image_file().as_str()));
    }

    #[test]
    fn an_empty_text_still_commits_a_transparent_raster() {
        let style = TextStyle { content: String::new(), ..TextStyle::default() };
        let (mut document, id) = document_with_text(style, 40, 40);
        let mut library = bare_library();
        let size = commit_text_layer(&mut document, id, &mut library).unwrap();
        assert_eq!(size, (32, 111), "point text is its padding plus a caret's worth of width");
        let image: std::sync::Arc<Bitmap8> = document.layer(id).unwrap().image.clone().unwrap();
        assert!(image.is_fully_transparent());
    }
}
