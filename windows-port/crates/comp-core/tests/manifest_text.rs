//! The manifest spellings the macOS app compares as strings: UUIDs and asset file names.
//!
//! A lowercase UUID is a different string than the one uuidString produces, and the macOS
//! validator compares imageFile against it byte for byte, so every id this crate writes has to be
//! uppercase and every asset name has to be built from that same uppercase text.
mod common;

use common::*;
use uuid::Uuid;

use comp_core::bitmap::{Bitmap8, Gray8};
use comp_core::geom::{Guide, GuideAxis, Transform};
use comp_core::layer::Layer;
use comp_core::store;

/// Ids with letters in every group, so a lowercase spelling would be visible in the text.
const DOCUMENT: &str = "0c5e7a91-3b2d-4f6a-8e1c-9d0b7a6f5e4d";
const BASE: &str = "6f1d3c2a-0b7e-4e8a-9c4d-2a1b3c4d5e6f";
const FOLDER: &str = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d";
const CLIPPED: &str = "b2c3d4e5-f6a7-4b8c-9d0e-1f2a3b4c5d6e";
const GUIDE: &str = "c3d4e5f6-a7b8-4c9d-8e1f-2a3b4c5d6e7f";

fn id(text: &str) -> Uuid {
    Uuid::parse_str(text).unwrap()
}

fn uppercase(text: &str) -> String {
    text.to_uppercase()
}

fn lowercase(text: &str) -> String {
    text.to_lowercase()
}

/// Fails with the field name when a UUID field is not the uppercase spelling.
fn assert_uppercase_uuid(value: &serde_json::Value, field: &str) {
    let text = value.as_str().unwrap_or_else(|| panic!("{field} is not a string: {value}"));
    assert_eq!(text, text.to_uppercase(), "{field} must be uppercase: {text}");
    assert!(text.chars().any(|c| c.is_ascii_alphabetic()), "{field} has no hex letters to check: {text}");
    assert_eq!(text.len(), 36, "{field} is not a UUID: {text}");
}

/// A document that uses every UUID field the format stores.
fn decorated_document() -> comp_core::Document {
    let mut document = comp_core::Document::new(32, 32);
    document.id = id(DOCUMENT);
    document.resolution = 72.0;

    let mut base = Layer::with_image("Base", Bitmap8::filled(32, 32, [1, 2, 3, 255]));
    base.id = id(BASE);
    let base_id = document.add_layer(base, None);

    let mut folder = Layer::group("Folder", 32, 32);
    folder.id = id(FOLDER);
    folder.mask = Some(std::sync::Arc::new(Gray8::filled(32, 32, 128)));
    let folder_id = document.add_layer(folder, None);

    let mut clipped = Layer::with_image("Clipped", Bitmap8::filled(32, 32, [4, 5, 6, 255]));
    clipped.id = id(CLIPPED);
    clipped.mask_source = Some(base_id);
    let clipped_id = document.add_layer(clipped, Some(folder_id));

    document.guides = vec![Guide { id: id(GUIDE), axis: GuideAxis::Vertical, position: 12.5 }];
    document.active_layer = Some(clipped_id);
    document.refresh_asset_names();
    document
}

#[test]
fn a_saved_manifest_spells_every_uuid_and_asset_name_in_uppercase() {
    let tree = TempTree::new("uuids");
    let package = tree.package("First");
    store::save(&decorated_document(), &package).unwrap();

    let manifest = manifest_value(&package);
    assert_uppercase_uuid(&manifest["documentID"], "documentID");
    assert_eq!(manifest["documentID"].as_str().unwrap(), uppercase(DOCUMENT));
    assert_uppercase_uuid(&manifest["activeLayerID"], "activeLayerID");
    assert_eq!(manifest["activeLayerID"].as_str().unwrap(), uppercase(CLIPPED));

    let layers = manifest["layers"].as_array().unwrap();
    assert_eq!(layers.len(), 3);
    for layer in layers {
        let text = layer["id"].as_str().unwrap().to_string();
        assert_uppercase_uuid(&layer["id"], "layers[].id");
        if let Some(parent) = layer.get("parentID").and_then(|value| value.as_str()) {
            assert_uppercase_uuid(&layer["parentID"], "layers[].parentID");
            assert_eq!(parent, uppercase(FOLDER));
        }
        if let Some(source) = layer.get("maskSourceID").and_then(|value| value.as_str()) {
            assert_uppercase_uuid(&layer["maskSourceID"], "layers[].maskSourceID");
            assert_eq!(source, uppercase(BASE));
        }
        if let Some(file) = layer.get("imageFile").and_then(|value| value.as_str()) {
            assert_eq!(file, format!("{text}.png"), "the asset name must be the uppercase id");
        }
        if let Some(file) = layer.get("maskFile").and_then(|value| value.as_str()) {
            assert_eq!(file, format!("{text}.mask.png"), "the mask name must be the uppercase id");
        }
    }
    let guide = &manifest["guides"][0];
    assert_uppercase_uuid(&guide["id"], "guides[].id");
    assert_eq!(guide["id"].as_str().unwrap(), uppercase(GUIDE));
}

#[test]
fn saving_reading_and_saving_again_keeps_the_manifest_text() {
    let tree = TempTree::new("stable");
    let first = tree.package("First");
    let second = tree.package("Second");
    store::save(&decorated_document(), &first).unwrap();
    let reloaded = store::load(&first).unwrap();
    assert_eq!(reloaded.id, id(DOCUMENT));
    assert_eq!(reloaded.active_layer, Some(id(CLIPPED)));
    store::save(&reloaded, &second).unwrap();

    // The round trip rewrites the same bytes, which is also what keeps the digest stable.
    assert_eq!(manifest_text(&first), manifest_text(&second));
}

/// A manifest as an older or third-party tool might have written it: lowercase UUIDs, uppercase
/// asset names, which is exactly what the macOS validator accepts.
const LOWERCASE_MANIFEST: &str = r#"{
  "format": "com.compositor.project",
  "version": 11,
  "colorSpace": "sRGB",
  "resolution": 72,
  "documentID": "0c5e7a91-3b2d-4f6a-8e1c-9d0b7a6f5e4d",
  "width": 32,
  "height": 32,
  "activeLayerID": "b2c3d4e5-f6a7-4b8c-9d0e-1f2a3b4c5d6e",
  "layers": [
    {
      "id": "6f1d3c2a-0b7e-4e8a-9c4d-2a1b3c4d5e6f",
      "name": "Base",
      "isVisible": true,
      "isGroup": false,
      "opacity": 1,
      "blendMode": "Normal",
      "imageFile": "6F1D3C2A-0B7E-4E8A-9C4D-2A1B3C4D5E6F.png",
      "transform": { "origin": [0, 0], "size": [32, 32], "rotation": 0, "flipX": false, "flipY": false, "sampling": "High quality" }
    },
    {
      "id": "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
      "name": "Folder",
      "isVisible": true,
      "isGroup": true,
      "opacity": 1,
      "blendMode": "Normal",
      "maskFile": "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D.mask.png",
      "maskEnabled": true,
      "transform": { "origin": [0, 0], "size": [32, 32], "rotation": 0, "flipX": false, "flipY": false, "sampling": "High quality" }
    },
    {
      "id": "b2c3d4e5-f6a7-4b8c-9d0e-1f2a3b4c5d6e",
      "name": "Clipped",
      "isVisible": true,
      "isGroup": false,
      "parentID": "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
      "opacity": 0.5,
      "blendMode": "Multiply",
      "maskSourceID": "6f1d3c2a-0b7e-4e8a-9c4d-2a1b3c4d5e6f",
      "imageFile": "B2C3D4E5-F6A7-4B8C-9D0E-1F2A3B4C5D6E.png",
      "transform": { "origin": [4, 4], "size": [16, 16], "rotation": 0, "flipX": false, "flipY": false, "sampling": "Smooth" }
    }
  ],
  "guides": [
    { "id": "c3d4e5f6-a7b8-4c9d-8e1f-2a3b4c5d6e7f", "axis": "vertical", "position": 12.5 }
  ]
}"#;

#[test]
fn a_manifest_with_lowercase_ids_loads_and_is_rewritten_uppercase() {
    let tree = TempTree::new("lowercase");
    let package = tree.package("Legacy");
    let base_pixels = Bitmap8::filled(32, 32, [9, 9, 9, 255]);
    let clipped_pixels = Bitmap8::filled(16, 16, [3, 4, 5, 255]);
    let assets = vec![
        (uppercase(BASE) + ".png", image_bytes(&base_pixels)),
        (uppercase(CLIPPED) + ".png", image_bytes(&clipped_pixels)),
        (uppercase(FOLDER) + ".mask.png", mask_bytes(&Gray8::filled(32, 32, 64))),
    ];
    write_raw(&package, LOWERCASE_MANIFEST, &assets);

    // Reading must not care about the case of an id, exactly as UUID(uuidString:) does not.
    let document = store::load(&package).unwrap();
    assert_eq!(document.id, id(DOCUMENT));
    assert_eq!(document.active_layer, Some(id(CLIPPED)));
    assert_eq!(document.layers[0].id, id(BASE));
    assert_eq!(document.layers[2].parent, Some(id(FOLDER)));
    assert_eq!(document.layers[2].mask_source, Some(id(BASE)));
    assert_eq!(document.layers[2].opacity, 0.5);
    assert_eq!(document.layers[2].transform.origin.x, 4.0);
    assert_eq!(document.guides[0].id, id(GUIDE));
    assert_eq!(document.layers[0].image.as_deref(), Some(&base_pixels));
    assert_eq!(document.layers[2].image.as_deref(), Some(&clipped_pixels));

    // Saving writes it back the way the macOS app spells it.
    let saved = tree.package("Saved");
    store::save(&document, &saved).unwrap();
    let text = manifest_text(&saved);
    assert!(!text.contains(&lowercase(DOCUMENT)), "a lowercase id survived a save");
    assert!(!text.contains(&lowercase(FOLDER)), "a lowercase id survived a save");
    let manifest = manifest_value(&saved);
    assert_uppercase_uuid(&manifest["documentID"], "documentID");
    assert_uppercase_uuid(&manifest["activeLayerID"], "activeLayerID");
    for layer in manifest["layers"].as_array().unwrap() {
        let text = layer["id"].as_str().unwrap().to_string();
        assert_uppercase_uuid(&layer["id"], "layers[].id");
        if layer.get("imageFile").is_some() {
            assert_eq!(layer["imageFile"].as_str().unwrap(), format!("{text}.png"));
        }
        if layer.get("maskFile").is_some() {
            assert_eq!(layer["maskFile"].as_str().unwrap(), format!("{text}.mask.png"));
        }
    }
    assert_uppercase_uuid(&manifest["guides"][0]["id"], "guides[].id");

    let reloaded = store::load(&saved).unwrap();
    assert_eq!(reloaded.layers[0].image.as_deref(), Some(&base_pixels));
    assert_eq!(reloaded.layers[2].mask_source, Some(id(BASE)));
}

#[test]
fn an_asset_named_in_lowercase_is_refused_like_the_mac_app_refuses_it() {
    let tree = TempTree::new("lowername");
    let package = tree.package("LowerCaseName");
    let pixels = Bitmap8::filled(8, 8, [1, 2, 3, 255]);
    let mut layer = record(id(BASE), "Base", 8.0, 8.0);
    // The manifest names the file in lowercase while the id spells it uppercase: the macOS
    // validator compares these as strings and refuses the package.
    layer.image_file = Some(lowercase(BASE) + ".png");
    let mut manifest = manifest(11, 8, 8, vec![layer]);
    manifest.active_layer_id = Some(id(BASE));
    write_package(&package, &manifest, &[(lowercase(BASE) + ".png", image_bytes(&pixels))]);
    // Still refused, now with the field that spells it wrong.
    match store::load(&package) {
        Err(comp_core::Error::DamagedManifest { field, .. }) => {
            assert_eq!(field.as_deref(), Some("layers[0].imageFile"));
        }
        other => panic!("expected the asset name to be refused, got {other:?}"),
    }
}

#[test]
fn a_transform_keeps_the_field_spellings_the_format_documents() {
    let tree = TempTree::new("transform");
    let package = tree.package("Placed");
    let managed = Transform::with_size(32.0, 32.0);
    let mut layer = record(id(BASE), "Base", 32.0, 32.0);
    layer.transform = managed;
    write_package(
        &package,
        &manifest(11, 32, 32, vec![layer]),
        &[(uppercase(BASE) + ".png", image_bytes(&Bitmap8::new(32, 32)))],
    );
    let text = manifest_text(&package);
    for field in ["\"origin\"", "\"size\"", "\"rotation\"", "\"flipX\"", "\"flipY\"", "\"sampling\""] {
        assert!(text.contains(field), "the transform is missing {field}: {text}");
    }
    assert!(text.contains("\"High quality\""), "{text}");
    assert_eq!(store::load(&package).unwrap().layers[0].transform, managed);
}

#[test]
fn shape_and_font_run_fields_use_the_names_the_format_documents() {
    let tree = TempTree::new("spellings");
    let package = tree.package("Spellings");
    let text_id = id(BASE);
    let shape_id = id(CLIPPED);

    let mut caption = record(text_id, "Caption", 32.0, 32.0);
    caption.text = Some(comp_core::text::TextStyle {
        content: "Hello".to_string(),
        color_runs: Some(vec![comp_core::text::TextColorRun { location: 0, length: 1, red: 1.0, green: 0.0, blue: 0.0 }]),
        font_runs: Some(vec![comp_core::text::TextFontRun { location: 1, length: 2, font_name: "Georgia".to_string() }]),
        ..comp_core::text::TextStyle::default()
    });

    let mut line = record(shape_id, "Line", 32.0, 32.0);
    line.shape = Some(comp_core::shape::ShapeStyle {
        kind: comp_core::shape::ShapeKind::Line,
        red: 0.5,
        green: 0.5,
        blue: 0.5,
        corner_radius: 4.0,
        line_width: Some(2.0),
        start: Some([0.0, 0.0]),
        end: Some([1.0, 1.0]),
    });

    let assets = vec![
        (uppercase(BASE) + ".png", image_bytes(&Bitmap8::new(32, 32))),
        (uppercase(CLIPPED) + ".png", image_bytes(&Bitmap8::new(32, 32))),
    ];
    write_package(&package, &manifest(11, 32, 32, vec![caption, line]), &assets);

    // The macOS records are named fontName, cornerRadius and lineWidth, and Codable compares those
    // keys as written: a snake_case key makes the whole manifest unreadable there.
    let value = manifest_value(&package);
    let text = &value["layers"][0]["text"];
    assert!(text["fontRuns"][0].get("fontName").is_some(), "font runs must spell the face fontName: {text}");
    assert!(text["fontRuns"][0].get("font_name").is_none(), "a snake_case run key survived: {text}");
    let shape = &value["layers"][1]["shape"];
    assert!(shape.get("cornerRadius").is_some(), "a shape must spell its radius cornerRadius: {shape}");
    assert!(shape.get("lineWidth").is_some(), "a line must spell its width lineWidth: {shape}");
    assert!(shape.get("corner_radius").is_none() && shape.get("line_width").is_none(), "snake_case shape keys survived: {shape}");

    let reloaded = store::load(&package).unwrap();
    assert_eq!(reloaded.layers[0].text.as_ref().unwrap().font_runs.as_ref().unwrap()[0].font_name, "Georgia");
    assert_eq!(reloaded.layers[1].shape.unwrap().corner_radius, 4.0);
    assert_eq!(reloaded.layers[1].shape.unwrap().line_width, Some(2.0));
}
