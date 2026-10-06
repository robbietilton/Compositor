//! End-to-end checks against the fonts installed on this machine.
//!
//! Every test here skips itself when the machine has no fonts, so the suite stays meaningful on a
//! stripped-down build agent while still proving the alias table on a real Windows font set.

use comp_core::shape::{ShapeKind, ShapeStyle};
use comp_core::text::{SizeD, TextStyle};
use comp_core::{Document, Layer};
use comp_text::{commit_shape_layer, commit_text_layer, rasterize_shape, rasterize_text, text_bounds, FontLibrary};

fn library() -> Option<FontLibrary> {
    let library = FontLibrary::new();
    (!library.is_empty()).then_some(library)
}

fn inked(bitmap: &comp_core::Bitmap8) -> usize {
    let mut count = 0;
    for y in 0..bitmap.height() {
        for x in 0..bitmap.width() {
            if bitmap.get(x, y)[3] > 0 {
                count += 1;
            }
        }
    }
    count
}

#[test]
fn macos_face_names_reach_windows_faces() {
    let Some(mut library) = library() else { return };
    let helvetica = library.resolved_name("Helvetica").expect("Helvetica has to reach a face");
    assert!(helvetica.contains("Arial"), "Helvetica should land on Arial, not {helvetica}");
    assert!(!helvetica.contains("Narrow"), "and not on the narrow cut of it");
    let bold = library.resolved_name("Helvetica-Bold").expect("a bold Helvetica has to resolve");
    assert!(bold.contains("Arial") && bold.contains("Bold"), "Helvetica-Bold landed on {bold}");
    let italic = library.resolved_name("Helvetica-Oblique").expect("an oblique Helvetica has to resolve");
    assert!(italic.contains("Italic") || italic.contains("Oblique"), "landed on {italic}");
    assert_eq!(library.resolved_name("SFProText").as_deref(), Some("Segoe UI"));
    assert_eq!(library.resolved_name("Menlo").as_deref(), Some("Consolas"));
    let times = library.resolved_name("Times-Roman").expect("Times has to resolve");
    assert!(times.starts_with("Times New Roman"), "Times landed on {times}");
    assert!(library.font_for("HelveticaNeue").is_some());
}

#[test]
fn a_face_this_machine_does_not_have_is_recorded() {
    let Some(mut library) = library() else { return };
    assert!(library.resolved_name("NoSuchFaceAtAll").is_none());
    let font = library.font_for("NoSuchFaceAtAll").expect("the system default stands in");
    assert!(font.units_per_em() > 0.0);
    let recorded = library.fallbacks().iter().any(|fallback| fallback.requested == "NoSuchFaceAtAll");
    assert!(recorded, "a caller has to be able to tell the user: {:?}", library.fallbacks());
}

#[test]
fn a_text_layer_draws_and_commits() {
    let Some(mut library) = library() else { return };
    let style = TextStyle {
        content: "Compositor".into(),
        font_name: "Helvetica".into(),
        font_size: 64.0,
        box_size: Some(SizeD::new(420.0, 120.0)),
        ..TextStyle::default()
    };
    let bitmap = rasterize_text(&style, &mut library);
    assert_eq!((bitmap.width(), bitmap.height()), text_bounds(&style, &mut library));
    assert_eq!((bitmap.width(), bitmap.height()), (420, 120));
    assert!(inked(&bitmap) > 1_000, "a 64 pixel word has plenty of ink: {}", inked(&bitmap));

    let mut document = Document::new(420, 120);
    let mut layer = Layer::raster("Text", 420, 120);
    layer.text = Some(style.clone());
    let id = document.add_layer(layer, None);
    let size = commit_text_layer(&mut document, id, &mut library).unwrap();
    assert_eq!(size, (420, 120));
    let stored = document.layer(id).unwrap();
    assert_eq!(stored.text.as_ref(), Some(&style), "the text stays editable");
    let image = stored.image.clone().unwrap();
    assert!(inked(&image) > 1_000, "the committed pixels are the drawn ones");
    assert_eq!(stored.image_file.as_deref(), Some(stored.expected_image_file().as_str()));
}

#[test]
fn another_script_still_draws() {
    let Some(mut library) = library() else { return };
    let arial = library.font_for("Arial").unwrap();
    if library.glyph_font(Some(&arial), '你').is_none() {
        return;
    }
    let style = TextStyle { content: "你好".into(), font_size: 48.0, ..TextStyle::default() };
    let bitmap = rasterize_text(&style, &mut library);
    assert!(inked(&bitmap) > 100, "linked faces have to put ink on the raster");
}

#[test]
fn a_shape_layer_draws_and_commits() {
    let style = ShapeStyle {
        kind: ShapeKind::Rectangle,
        red: 0.2,
        green: 0.4,
        blue: 0.9,
        corner_radius: 8.0,
        ..ShapeStyle::default()
    };
    let bitmap = rasterize_shape(&style, 64, 32);
    assert_eq!(bitmap.get(32, 16), [51, 102, 230, 255]);
    assert_eq!(bitmap.get(0, 0)[3], 0, "the rounded corner is empty");

    let mut document = Document::new(64, 32);
    let mut layer = Layer::raster("Rectangle", 64, 32);
    layer.shape = Some(style);
    layer.transform = comp_core::Transform::with_size(128.0, 64.0);
    let id = document.add_layer(layer, None);
    assert_eq!(commit_shape_layer(&mut document, id).unwrap(), (128, 64));
    let image = document.layer(id).unwrap().image.clone().unwrap();
    assert_eq!((image.width(), image.height()), (128, 64));
    assert!(inked(&image) > 6_000, "a rounded rectangle covers most of its box");
}
