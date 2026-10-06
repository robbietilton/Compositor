//! Packages that are damaged or hostile, and the guarantees a save has to keep on disk.
mod common;

use std::fs;
use std::sync::Arc;

use common::*;
use uuid::Uuid;

use comp_core::bitmap::{Bitmap8, Gray8};
use comp_core::layer::Layer;
use comp_core::png_io;
use comp_core::store;

#[test]
fn a_package_whose_asset_is_garbage_is_refused() {
    let tree = TempTree::new("garbage");
    let package = tree.package("Bad");
    let id = Uuid::new_v4();
    let mut manifest = manifest(11, 8, 8, vec![record(id, "Base", 8.0, 8.0)]);
    manifest.active_layer_id = Some(id);
    let good = image_bytes(&Bitmap8::filled(8, 8, [1, 2, 3, 255]));
    write_package(&package, &manifest, &[(asset_name(id), good.clone())]);
    assert!(store::load(&package).is_ok());

    // Truncating the asset is the classic half-synced package: it must not load at all.
    fs::write(package.join("images").join(asset_name(id)), &good[..good.len() / 2]).unwrap();
    assert!(store::load(&package).is_err());
    // The manifest on disk is untouched, so the package is still the one the writer left.
    assert_eq!(manifest_text(&package), serde_json::to_string(&manifest).unwrap());
}

#[test]
fn a_package_naming_an_asset_that_is_not_there_is_refused() {
    let tree = TempTree::new("nodasset");
    let package = tree.package("Empty");
    let id = Uuid::new_v4();
    let manifest = manifest(11, 8, 8, vec![record(id, "Base", 8.0, 8.0)]);
    write_package(&package, &manifest, &[]);
    // Refused, and the answer names the file the manifest asked for: the bare name a caller can
    // show or look up, not the path the reader happened to have in hand.
    match store::load(&package) {
        Err(error @ comp_core::Error::MissingAsset(_)) => {
            assert_eq!(error.asset(), Some(asset_name(id).as_str()));
            assert_eq!(error.source(), comp_core::ErrorSource::Asset);
        }
        other => panic!("expected a missing asset, got {other:?}"),
    }
}

#[test]
fn a_manifest_naming_another_layer_file_is_refused() {
    let tree = TempTree::new("wrongname");
    let package = tree.package("Wrong");
    let id = Uuid::new_v4();
    let mut layer = record(id, "Base", 8.0, 8.0);
    layer.image_file = Some("SOMEONE-ELSE.png".to_string());
    let mut manifest = manifest(11, 8, 8, vec![layer]);
    manifest.active_layer_id = Some(id);
    write_package(&package, &manifest, &[("SOMEONE-ELSE.png".to_string(), image_bytes(&Bitmap8::new(8, 8)))]);
    match store::load(&package) {
        Err(comp_core::Error::DamagedManifest { field, .. }) => {
            assert_eq!(field.as_deref(), Some("layers[0].imageFile"));
        }
        other => panic!("expected the layer file name to be refused, got {other:?}"),
    }
}

#[test]
fn a_traversing_asset_name_is_refused() {
    let tree = TempTree::new("traverse");
    let package = tree.package("Escape");
    let id = Uuid::new_v4();
    let mut layer = record(id, "Base", 8.0, 8.0);
    layer.image_file = Some("../../outside.png".to_string());
    let mut manifest = manifest(11, 8, 8, vec![layer]);
    manifest.active_layer_id = Some(id);
    fs::write(tree.join("outside.png"), image_bytes(&Bitmap8::new(8, 8))).unwrap();
    write_package(&package, &manifest, &[]);
    match store::load(&package) {
        Err(comp_core::Error::DamagedManifest { field, detail, .. }) => {
            assert_eq!(field.as_deref(), Some("layers[0].imageFile"));
            assert!(detail.contains("named after its layer"), "{detail}");
        }
        other => panic!("expected the asset name to be refused, got {other:?}"),
    }
}

#[test]
fn a_manifest_over_four_mebibytes_is_refused() {
    let tree = TempTree::new("bigmanifest");
    let package = tree.package("Huge");
    let id = Uuid::new_v4();
    write_package(&package, &manifest(11, 8, 8, vec![record(id, "Base", 8.0, 8.0)]), &[]);
    fs::write(package.join("manifest.json"), vec![b'x'; 4 * 1024 * 1024 + 1]).unwrap();
    assert!(matches!(store::load(&package), Err(comp_core::Error::TooLarge(_))));
}

#[test]
fn a_png_bomb_is_refused_without_being_decoded() {
    let tree = TempTree::new("bomb");
    let package = tree.package("Bomb");
    let id = Uuid::new_v4();
    let mut manifest = manifest(11, 8, 8, vec![record(id, "Base", 8.0, 8.0)]);
    manifest.active_layer_id = Some(id);
    // A header claiming 25,000 x 25,000 pixels: 2.5 GB of RGBA from forty bytes of file.
    let mut bomb = vec![0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    bomb.extend_from_slice(&13u32.to_be_bytes());
    bomb.extend_from_slice(b"IHDR");
    bomb.extend_from_slice(&25_000u32.to_be_bytes());
    bomb.extend_from_slice(&25_000u32.to_be_bytes());
    bomb.extend_from_slice(&[8, 6, 0, 0, 0]);
    bomb.extend_from_slice(&[0u8; 4]);
    write_package(&package, &manifest, &[(asset_name(id), bomb)]);
    assert!(matches!(store::load(&package), Err(comp_core::Error::TooLarge(_))));
}

#[test]
fn a_sixteen_bit_mask_is_refused() {
    let tree = TempTree::new("mask16");
    let package = tree.package("Deep");
    let id = Uuid::new_v4();
    let mut layer = record(id, "Base", 8.0, 8.0);
    layer.mask_file = Some(mask_name(id));
    layer.mask_enabled = Some(true);
    let mut manifest = manifest(11, 8, 8, vec![layer]);
    manifest.active_layer_id = Some(id);
    let samples: Vec<u8> = (0..64u16).flat_map(|v| (v * 1000).to_be_bytes()).collect();
    let mask = {
        let mut out = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut out, 8, 8);
            encoder.set_color(png::ColorType::Grayscale);
            encoder.set_depth(png::BitDepth::Sixteen);
            let mut writer = encoder.write_header().unwrap();
            writer.write_image_data(&samples).unwrap();
        }
        out
    };
    let assets = vec![(asset_name(id), image_bytes(&Bitmap8::new(8, 8))), (mask_name(id), mask)];
    write_package(&package, &manifest, &assets);
    // The mask is there and cannot be read: damage to that named asset, not a missing one.
    match store::load(&package) {
        Err(comp_core::Error::DamagedAsset { name, .. }) => assert_eq!(name, mask_name(id)),
        other => panic!("expected a damaged asset, got {other:?}"),
    }
}

#[test]
fn a_mask_saved_as_color_is_refused() {
    let tree = TempTree::new("maskcolor");
    let package = tree.package("ColorMask");
    let id = Uuid::new_v4();
    let mut layer = record(id, "Base", 8.0, 8.0);
    layer.mask_file = Some(mask_name(id));
    layer.mask_enabled = Some(true);
    let mut manifest = manifest(11, 8, 8, vec![layer]);
    manifest.active_layer_id = Some(id);
    let assets = vec![
        (asset_name(id), image_bytes(&Bitmap8::new(8, 8))),
        (mask_name(id), image_bytes(&Bitmap8::filled(8, 8, [255, 255, 255, 255]))),
    ];
    write_package(&package, &manifest, &assets);
    match store::load(&package) {
        Err(comp_core::Error::DamagedAsset { name, detail }) => {
            assert_eq!(name, mask_name(id));
            assert!(detail.contains("grayscale"), "{detail}");
        }
        other => panic!("expected a damaged asset, got {other:?}"),
    }
}

#[test]
fn the_quicklook_directory_is_ignored() {
    let tree = TempTree::new("quicklook");
    let package = tree.package("Preview");
    let id = Uuid::new_v4();
    let pixels = Bitmap8::filled(8, 8, [11, 22, 33, 255]);
    write_package(&package, &manifest(11, 8, 8, vec![record(id, "Base", 8.0, 8.0)]), &[(asset_name(id), image_bytes(&pixels))]);
    fs::create_dir_all(package.join("QuickLook")).unwrap();
    fs::write(package.join("QuickLook").join("Preview.jpg"), b"\xFF\xD8\xFF garbage").unwrap();
    fs::write(package.join("images").join("leftover.png"), b"not a png at all").unwrap();
    fs::write(package.join("README.txt"), b"ignore me").unwrap();

    let document = store::load(&package).unwrap();
    assert_eq!(document.layers[0].image.as_deref(), Some(&pixels));
}

#[test]
fn an_empty_directory_and_a_plain_file_are_not_packages() {
    let tree = TempTree::new("notpackage");
    let empty = tree.join("Empty.comp");
    fs::create_dir_all(&empty).unwrap();
    // A folder with nothing in it is not a project, and neither is a file: both say so, and they
    // are no longer the same error.
    assert!(matches!(store::load(&empty), Err(comp_core::Error::NotAProject { .. })));
    let file = tree.join("NotAPackage.comp");
    fs::write(&file, b"just a file").unwrap();
    assert!(matches!(store::load(&file), Err(comp_core::Error::NotAProject { .. })));
    // A path that is not there at all is a different failure again: nothing to open.
    let missing = tree.join("Gone.comp");
    match store::load(&missing) {
        Err(error @ comp_core::Error::IllegalPath { .. }) => assert_eq!(error.source(), comp_core::ErrorSource::Io),
        other => panic!("expected an illegal path, got {other:?}"),
    }
}

#[test]
fn a_failed_save_leaves_the_live_package_exactly_as_it_was() {
    let tree = TempTree::new("atomic");
    let package = tree.package("Live");
    let mut document = comp_core::Document::new(16, 16);
    document.add_layer(Layer::with_image("Base", Bitmap8::filled(16, 16, [1, 2, 3, 255])), None);
    store::save(&document, &package).unwrap();
    let before = manifest_text(&package);
    let bytes_before = fs::read(package.join("images").join(asset_name(document.layers[0].id))).unwrap();

    // A group holding pixels fails validation, so the save stops before it stages anything.
    let mut broken = document.clone();
    broken.layers[0].is_group = true;
    assert!(store::save(&broken, &package).is_err());
    // An image beyond the document budget fails later, while the surfaces are measured.
    let mut oversized = document.clone();
    let big = Arc::new(Bitmap8::filled(20_000, 20_000, [0, 0, 0, 0]));
    oversized.layers[0].image = Some(big);
    assert!(store::save(&oversized, &package).is_err());

    assert_eq!(manifest_text(&package), before);
    assert_eq!(fs::read(package.join("images").join(asset_name(document.layers[0].id))).unwrap(), bytes_before);
    assert!(tree.debris().is_empty(), "leftover staging or backup directories: {:?}", tree.debris());
    let reloaded = store::load(&package).unwrap();
    assert_eq!(reloaded.layers[0].image.as_ref().unwrap().get(3, 3), [1, 2, 3, 255]);
}

#[test]
fn a_save_never_leaves_a_staging_directory_behind() {
    let tree = TempTree::new("staging");
    let package = tree.package("Tidy");
    let mut document = comp_core::Document::new(32, 32);
    document.add_layer(Layer::with_image("Base", noisy(32, 32, 3)), None);
    for round in 0..3 {
        let mut next = document.clone();
        next.layers[0].opacity = 0.5 + round as f64 * 0.1;
        store::save(&next, &package).unwrap();
    }
    assert!(tree.debris().is_empty(), "leftover staging or backup directories: {:?}", tree.debris());
    assert!(store::load(&package).is_ok());
}

#[test]
fn concurrent_saves_never_leave_a_half_written_package() {
    let tree = TempTree::new("concurrent");
    let package = tree.package("Shared");
    let mut threads = Vec::new();
    for index in 0..6u8 {
        let package = package.clone();
        threads.push(std::thread::spawn(move || {
            let mut document = comp_core::Document::new(24, 24);
            let mut layer = Layer::with_image("Base", Bitmap8::filled(24, 24, [index, index, index, 255]));
            layer.mask = Some(Arc::new(Gray8::filled(24, 24, index * 10)));
            document.add_layer(layer, None);
            store::save(&document, &package).is_ok()
        }));
    }
    let successes = threads.into_iter().map(|thread| thread.join().unwrap_or(false)).filter(|ok| *ok).count();
    assert!(successes >= 1, "no save finished");

    // Whatever the interleaving, the package that survives is complete and readable.
    let document = store::load(&package).expect("the surviving package loads");
    assert_eq!(document.layers.len(), 1);
    assert_eq!(document.layers[0].image.as_ref().unwrap().get(0, 0)[3], 255);
    assert!(document.layers[0].mask.is_some());
    // Serialized swaps mean every writer either completes or cleans up after itself.
    assert!(tree.debris().is_empty(), "a save left debris behind: {:?}", tree.debris());
}

#[test]
fn a_package_that_cannot_be_read_does_not_replace_the_open_document() {
    let tree = TempTree::new("keependoc");
    let package = tree.package("Watch");
    let good = comp_core::Document::new(16, 16);
    let mut document = good.clone();
    document.add_layer(Layer::with_image("Base", Bitmap8::filled(16, 16, [5, 6, 7, 255])), None);
    store::save(&document, &package).unwrap();
    let open = store::load(&package).unwrap();

    // A writer that replaces the asset with something unreadable: the load fails, and the caller
    // keeps the document it already had, exactly as the macOS reload does.
    let image_path = package.join("images").join(asset_name(document.layers[0].id));
    fs::write(&image_path, b"not a png").unwrap();
    assert!(store::load(&package).is_err());
    assert_eq!(open.layers[0].image.as_ref().unwrap().get(0, 0), [5, 6, 7, 255]);
}

#[test]
fn a_package_written_by_this_crate_reloads_after_a_second_save() {
    let tree = TempTree::new("twice");
    let package = tree.package("Twice");
    let mut document = comp_core::Document::new(12, 12);
    let pixels = noisy(12, 12, 99);
    document.add_layer(Layer::with_image("Base", pixels.clone()), None);
    store::save(&document, &package).unwrap();
    let first = store::load(&package).unwrap();
    store::save(&first, &package).unwrap();
    let second = store::load(&package).unwrap();
    assert_eq!(second.layers[0].image.as_deref(), Some(&pixels));
    assert_eq!(second.id, first.id);
    let decoded = png_io::decode_png(&fs::read(package.join("images").join(asset_name(second.layers[0].id))).unwrap()).unwrap();
    assert_eq!(decoded.to_bitmap8().unwrap(), pixels);
}
