//! The golden packages in fixtures/, written by Pillow and read back here pixel for pixel.
//!
//! The expected pixels are raw RGBA or grayscale dumps the generator took from the PNGs Pillow
//! wrote, so a mismatch means one of the two decoders disagrees, not that this crate disagrees with
//! itself. Regenerate the packages with: python fixtures/make_fixtures.py
mod common;

use std::fs;
use std::path::PathBuf;

use common::*;
use serde_json::Value;
use uuid::Uuid;

use comp_core::store;

fn fixtures_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures")
}

fn expectations(name: &str) -> Value {
    let path = fixtures_root().join("expected").join(format!("{name}.json"));
    let text = fs::read_to_string(&path)
        .unwrap_or_else(|_| panic!("missing {}; run fixtures/make_fixtures.py", path.display()));
    serde_json::from_str(&text).expect("a fixture index")
}

/// Loads one golden package and checks every layer and every asset against the generator.
fn verify(name: &str) -> comp_core::Document {
    let root = fixtures_root();
    let package = root.join(name);
    assert!(package.is_dir(), "{} is missing; run fixtures/make_fixtures.py", package.display());
    let index = expectations(name);
    let document = store::load(&package).unwrap_or_else(|error| panic!("{name} did not load: {error}"));

    assert_eq!(document.version, index["version"].as_u64().unwrap() as u32, "{name}");
    assert_eq!(document.width, index["width"].as_u64().unwrap() as u32, "{name}");
    assert_eq!(document.height, index["height"].as_u64().unwrap() as u32, "{name}");
    assert_eq!(document.resolution, index["resolution"].as_f64().unwrap(), "{name}");

    let layers = index["layers"].as_array().unwrap();
    assert_eq!(document.layers.len(), layers.len(), "{name} layer count");
    assert_eq!(document.layers.len(), index["layerCount"].as_u64().unwrap() as usize);

    for (layer, expected) in document.layers.iter().zip(layers.iter()) {
        let id = Uuid::parse_str(expected["id"].as_str().unwrap()).unwrap();
        assert_eq!(layer.id, id, "{name} layer order");
        assert_eq!(layer.name, expected["name"].as_str().unwrap(), "{name} layer name");
        assert_eq!(layer.opacity, expected["opacity"].as_f64().unwrap(), "{name} {id} opacity");
        assert_eq!(layer.blend.as_str(), expected["blendMode"].as_str().unwrap(), "{name} {id} blend");
        assert_eq!(layer.is_group, expected["kind"].as_str().unwrap() == "group", "{name} {id} group");
        assert_eq!(
            layer.parent.map(|parent| parent.to_string().to_uppercase()),
            expected["parentID"].as_str().map(|text| text.to_string()),
            "{name} {id} parent"
        );
        assert_eq!(layer.image.is_some(), expected["hasImage"].as_bool().unwrap(), "{name} {id} image");
        assert_eq!(layer.mask.is_some(), expected["hasMask"].as_bool().unwrap(), "{name} {id} mask");
        assert_eq!(layer.mask_enabled, expected["maskEnabled"].as_bool().unwrap_or(true), "{name} {id} mask enabled");
        assert_eq!(layer.mask_linked, expected["maskLinked"].as_bool().unwrap_or(true), "{name} {id} mask linked");
        let adjustment = layer.adjustment.as_ref().map(|adjustment| adjustment.kind.as_str());
        assert_eq!(adjustment, expected["adjustmentKind"].as_str(), "{name} {id} adjustment");
        let color_runs = layer.text.as_ref().and_then(|text| text.color_runs.as_ref()).map(Vec::len).unwrap_or(0);
        let font_runs = layer.text.as_ref().and_then(|text| text.font_runs.as_ref()).map(Vec::len).unwrap_or(0);
        assert_eq!(color_runs, expected["colorRuns"].as_u64().unwrap() as usize, "{name} {id} color runs");
        assert_eq!(font_runs, expected["fontRuns"].as_u64().unwrap() as usize, "{name} {id} font runs");
        let shape = layer.shape.map(|shape| shape.kind.as_str());
        assert_eq!(shape, expected["shapeKind"].as_str(), "{name} {id} shape");
    }

    let assets = index["assets"].as_array().unwrap();
    assert!(!assets.is_empty(), "{name} lists no assets");
    for asset in assets {
        let id = Uuid::parse_str(asset["id"].as_str().unwrap()).unwrap();
        let layer = document.layer(id).unwrap_or_else(|| panic!("{name} has no layer {id}"));
        let path = root.join("expected").join(asset["file"].as_str().unwrap());
        let expected = fs::read(&path).unwrap_or_else(|_| panic!("missing sidecar {}", path.display()));
        let width = asset["width"].as_u64().unwrap() as u32;
        let height = asset["height"].as_u64().unwrap() as u32;
        match asset["kind"].as_str().unwrap() {
            "image" => {
                let image = layer.image.as_ref().unwrap_or_else(|| panic!("{name} {id} has no pixels"));
                assert_eq!((image.width(), image.height()), (width, height), "{name} {id} image size");
                assert_eq!(image.pixels(), expected.as_slice(), "{name} {id} image pixels");
            }
            "mask" => {
                let mask = layer.mask.as_ref().unwrap_or_else(|| panic!("{name} {id} has no mask"));
                assert_eq!((mask.width(), mask.height()), (width, height), "{name} {id} mask size");
                assert_eq!(mask.pixels(), expected.as_slice(), "{name} {id} mask samples");
            }
            other => panic!("{name} has an unknown asset kind {other}"),
        }
    }
    document
}

#[test]
fn golden_layers_matches_the_pixels_pillow_wrote() {
    let document = verify("golden_layers.comp");
    assert_eq!(document.version, 11);
    // The masked layer's image is a palette PNG with a transparency table, and its mask is a
    // grayscale PNG; both come back as the pixels Pillow reads from the same files.
    let masked = document.layers.iter().find(|layer| layer.name == "Masked").expect("the masked layer");
    assert!(masked.image.is_some() && masked.mask.is_some());
    let tiny = document.layers.iter().find(|layer| layer.name == "Tiny Mask").expect("the tiny mask layer");
    let mask = tiny.mask.as_ref().unwrap();
    assert_eq!((mask.width(), mask.height()), (1, 1));
    assert_eq!(mask.get(0, 0), 90);
    assert_eq!(document.layers.iter().filter(|layer| layer.image.is_some()).count(), 4);
}

#[test]
fn golden_group_matches_the_pixels_pillow_wrote() {
    let document = verify("golden_group.comp");
    let folder = document.layers.iter().find(|layer| layer.is_group).expect("the folder");
    assert_eq!(folder.opacity, 0.6);
    assert!(folder.mask.is_some(), "the folder keeps its mask");
    let base = document.layers.iter().find(|layer| layer.name == "Base").expect("the base layer");
    let clipped = document.layers.iter().find(|layer| layer.name == "Clipped").expect("the clipped layer");
    assert_eq!(clipped.mask_source, Some(base.id), "the clipping link survives");
    assert_eq!(clipped.parent, Some(folder.id));
    let caption = document.layers.iter().find(|layer| layer.name == "Caption").expect("the caption");
    let text = caption.text.as_ref().expect("text metadata");
    assert_eq!(text.content, "Golden");
    assert_eq!(text.font_runs.as_ref().unwrap()[0].font_name, "Georgia-Bold");
    assert_eq!(text.box_size.unwrap().width, 40.0);
    let arrow = document.layers.iter().find(|layer| layer.name == "Arrow").expect("the shape layer");
    assert_eq!(arrow.shape.unwrap().line_width, Some(3.0));
    assert_eq!(document.guides.len(), 2);
    assert_eq!(document.guides[0].position, 12.0);
    assert_eq!(document.guides[1].position, 30.5);
}

#[test]
fn golden_adjustment_matches_the_pixels_pillow_wrote() {
    let document = verify("golden_adjustment.comp");
    let kinds: Vec<_> = document
        .layers
        .iter()
        .filter_map(|layer| layer.adjustment.as_ref().map(|adjustment| adjustment.kind.as_str()))
        .collect();
    assert_eq!(kinds, vec!["Curves", "Gaussian Blur", "Color Balance"]);
    let curves = document.layers.iter().find(|layer| layer.name == "Warm Grade").unwrap();
    let settings = curves.adjustment.as_ref().unwrap();
    assert_eq!(settings.curves.channels[1][1].y, 147.0);
    let loose = document.layers.iter().find(|layer| layer.name == "Loose Mask").unwrap();
    assert!(!loose.mask_linked, "an unlinked mask stays unlinked");
    assert!(loose.mask_placement.is_some(), "an unlinked mask keeps its placement");
    assert_eq!(loose.mask_placement.unwrap().origin.x, 10.5);
}

#[test]
fn every_golden_package_reloads_after_a_save() {
    let tree = TempTree::new("golden-save");
    for name in ["golden_layers.comp", "golden_group.comp", "golden_adjustment.comp"] {
        let document = verify(name);
        let saved = tree.join(&format!("{name}-saved"));
        store::save(&document, &saved).unwrap();
        let reloaded = store::load(&saved).unwrap();
        assert_eq!(reloaded.width, document.width, "{name}");
        assert_eq!(reloaded.layers.len(), document.layers.len(), "{name}");
        for (before, after) in document.layers.iter().zip(reloaded.layers.iter()) {
            assert_eq!(before.id, after.id, "{name} layer order");
            assert_eq!(before.name, after.name, "{name} layer name");
            assert_eq!(before.opacity, after.opacity, "{name} opacity");
            assert_eq!(before.blend, after.blend, "{name} blend");
            assert_eq!(before.parent, after.parent, "{name} parent");
            assert_eq!(before.adjustment, after.adjustment, "{name} adjustment");
            assert_eq!(before.text, after.text, "{name} text");
            assert_eq!(before.shape, after.shape, "{name} shape");
            assert_eq!(before.effects, after.effects, "{name} effects");
            assert_eq!(before.mask_source, after.mask_source, "{name} clipping");
            assert_eq!(before.mask_placement, after.mask_placement, "{name} mask placement");
            assert_eq!(
                before.image.as_ref().map(|image| image.pixels()),
                after.image.as_ref().map(|image| image.pixels()),
                "{name} pixels"
            );
            assert_eq!(
                before.mask.as_ref().map(|mask| mask.pixels()),
                after.mask.as_ref().map(|mask| mask.pixels()),
                "{name} mask"
            );
        }
        assert_eq!(reloaded.guides, document.guides, "{name} guides");
    }
}
