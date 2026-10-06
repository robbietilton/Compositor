//! Which packages open, and which are refused - and now, what each refusal says.
//!
//! Refining the *kind* of a refusal (task-49) must not move a single package from one side of the
//! acceptance line to the other. `the_rejection_set_is_unchanged` states that line on its own: it
//! asks only whether a load succeeded, never which error came back, so it read the same before the
//! fine-grained kinds landed and reads the same after. It is the regression test for that promise.
//!
//! `a_refusal_says_what_is_wrong` then pins the finer answer: which field, which asset, which path,
//! which stage. Both tests walk the same table, so a new hostile shape is added once.
mod common;

use std::fs;
use std::path::{Path, PathBuf};

use common::*;
use uuid::Uuid;

use comp_core::bitmap::Bitmap8;
use comp_core::{png_io, store, Error, ErrorSource};

/// What the loader must answer for one damaged package.
#[derive(Clone, Copy)]
enum Expected {
    /// Not a package at all: the path, the layout or the manifest header is wrong.
    NotAProject,
    /// Damaged metadata, at a known field.
    ManifestField(&'static str),
    /// Damaged metadata the parser refused, with a position but no field.
    ManifestPosition,
    /// A path that cannot be used.
    IllegalPath,
    /// An asset the manifest names that is not in the package.
    MissingAsset,
    /// An asset that is there and cannot become pixels.
    DamagedAsset,
    /// Past a limit this build supports.
    OverLimit,
    /// A format version this build does not read.
    UnsupportedVersion(u32),
}

/// A mutation that turns a good package into one that must not open, and what it must say.
type Damage = (&'static str, fn(&Path, Uuid), Expected);

/// A package this build opens, ready to be damaged in one specific way.
fn good_package(tree: &TempTree, name: &str) -> (PathBuf, Uuid) {
    let package = tree.package(name);
    let id = Uuid::new_v4();
    let mut manifest = manifest(11, 8, 8, vec![record(id, "Base", 8.0, 8.0)]);
    manifest.active_layer_id = Some(id);
    let pixels = image_bytes(&Bitmap8::filled(8, 8, [9, 8, 7, 255]));
    write_package(&package, &manifest, &[(asset_name(id), pixels)]);
    assert!(store::load(&package).is_ok(), "{name} must open before it is damaged");
    (package, id)
}

/// Changes one field of the manifest on disk, so a case cannot silently do nothing.
fn amend_manifest(package: &Path, field: &str, value: serde_json::Value) {
    let mut manifest = manifest_value(package);
    manifest[field] = value;
    fs::write(package.join("manifest.json"), serde_json::to_string(&manifest).unwrap()).unwrap();
}

/// Changes one field of the first layer record.
fn amend_layer(package: &Path, field: &str, value: serde_json::Value) {
    let mut manifest = manifest_value(package);
    manifest["layers"][0][field] = value;
    fs::write(package.join("manifest.json"), serde_json::to_string(&manifest).unwrap()).unwrap();
}

/// Every way a package can be damaged, each of which the loader has always refused. This list is
/// the acceptance rule of the format layer.
const DAMAGE: &[Damage] = &[
    ("a manifest that is not there", |package, _| {
        fs::remove_file(package.join("manifest.json")).unwrap();
    }, Expected::NotAProject),
    ("a manifest that is not JSON", |package, _| {
        fs::write(package.join("manifest.json"), b"this is not JSON at all").unwrap();
    }, Expected::NotAProject),
    ("a manifest that is JSON but not a manifest", |package, _| {
        fs::write(package.join("manifest.json"), b"{}").unwrap();
    }, Expected::NotAProject),
    ("a manifest naming another format", |package, _| {
        amend_manifest(package, "format", serde_json::json!("something-else"));
    }, Expected::NotAProject),
    ("a manifest from a version this build does not read", |package, _| {
        amend_manifest(package, "version", serde_json::json!(99));
    }, Expected::UnsupportedVersion(99)),
    ("a manifest that says it is not JSON at all but carries a header", |package, _| {
        let text = manifest_text(package);
        let broken = text.replacen('{', "{\"layers\":\"not a list\",", 1);
        fs::write(package.join("manifest.json"), broken).unwrap();
    }, Expected::ManifestPosition),
    ("a document with no pixels", |package, _| {
        amend_manifest(package, "width", serde_json::json!(0));
    }, Expected::OverLimit),
    ("an asset the manifest names that is not in the package", |package, id| {
        fs::remove_file(package.join("images").join(asset_name(id))).unwrap();
    }, Expected::MissingAsset),
    ("an asset truncated in half", |package, id| {
        let bytes = fs::read(package.join("images").join(asset_name(id))).unwrap();
        fs::write(package.join("images").join(asset_name(id)), &bytes[..bytes.len() / 2]).unwrap();
    }, Expected::DamagedAsset),
    ("an asset that is not an image", |package, id| {
        fs::write(package.join("images").join(asset_name(id)), b"not a PNG, not at all").unwrap();
    }, Expected::DamagedAsset),
    ("an asset name that climbs out of the package", |package, _| {
        amend_layer(package, "imageFile", serde_json::json!("../../outside.png"));
    }, Expected::ManifestField("layers[0].imageFile")),
    ("a layer pointing at someone else's file", |package, _| {
        amend_layer(package, "imageFile", serde_json::json!("SOMEONE-ELSE.png"));
    }, Expected::ManifestField("layers[0].imageFile")),
    ("a layer with a transform that is not usable", |package, _| {
        amend_layer(package, "transform", serde_json::json!({
            "flipX": false,
            "flipY": false,
            "origin": [0.0, 0.0],
            "rotation": 0.0,
            "sampling": "High quality",
            "size": [0.0, 8.0],
        }));
    }, Expected::ManifestField("layers[0].transform")),
    ("a layer with no name", |package, _| {
        amend_layer(package, "name", serde_json::json!(""));
    }, Expected::ManifestField("layers[0].name")),
    ("a layer with an id that does not match its asset", |package, _| {
        amend_layer(package, "id", serde_json::json!("00000000-0000-0000-C0FF-EE0000000009"));
    }, Expected::ManifestField("layers[0].imageFile")),
    ("a manifest over its size limit", |package, _| {
        fs::write(package.join("manifest.json"), vec![b'x'; 4 * 1024 * 1024 + 1]).unwrap();
    }, Expected::OverLimit),
    ("a PNG promising a surface beyond the budget", |package, id| {
        let mut header = png_io::encode_rgba8(&Bitmap8::new(1, 1)).unwrap();
        // IHDR width and height are big-endian u32 at offsets 16 and 20.
        header[16..20].copy_from_slice(&100_000u32.to_be_bytes());
        header[20..24].copy_from_slice(&100_000u32.to_be_bytes());
        fs::write(package.join("images").join(asset_name(id)), header).unwrap();
        // The header is read before any pixels are decoded, so a bomb is refused as "over a limit"
        // rather than as damage - which is exactly what the budget is for.
    }, Expected::OverLimit),
    ("a path that is not there", |_, _| {}, Expected::IllegalPath),
];

#[test]
fn the_rejection_set_is_unchanged() {
    let tree = TempTree::new("parity");
    for (index, (label, damage, _)) in DAMAGE.iter().enumerate() {
        // The last case damages the path itself rather than the package.
        let (package, id) = if index + 1 == DAMAGE.len() {
            (tree.join("Gone.comp"), Uuid::new_v4())
        } else {
            good_package(&tree, &format!("case{index}"))
        };
        damage(&package, id);
        assert!(store::load(&package).is_err(), "{label} must be refused, and was not ({index})");
    }
    // The same package with no damage at all still opens, so the mutations above are what is being
    // measured and not the harness.
    let (intact, _) = good_package(&tree, "intact");
    assert!(store::load(&intact).is_ok(), "an undamaged package must open");
}

#[test]
fn a_refusal_says_what_is_wrong() {
    let tree = TempTree::new("kinds");
    for (index, (label, damage, expected)) in DAMAGE.iter().enumerate() {
        let (package, id) = if index + 1 == DAMAGE.len() {
            (tree.join("Gone.comp"), Uuid::new_v4())
        } else {
            good_package(&tree, &format!("kind{index}"))
        };
        damage(&package, id);
        let error = store::load(&package).expect_err(label);
        match expected {
            Expected::NotAProject => assert!(matches!(error, Error::NotAProject { .. }), "{label}: {error:?}"),
            Expected::ManifestField(field) => {
                assert_eq!(error.field(), Some(*field), "{label}: {error:?}");
                assert_eq!(error.source(), ErrorSource::Manifest, "{label}");
            }
            Expected::ManifestPosition => {
                assert!(matches!(error, Error::DamagedManifest { .. }), "{label}: {error:?}");
                assert!(error.line().is_some(), "{label} must say where the parser stopped");
                assert!(error.field().is_none(), "{label} cannot name a field it never parsed");
            }
            Expected::IllegalPath => {
                assert!(matches!(error, Error::IllegalPath { .. }), "{label}: {error:?}");
                assert!(error.path().is_some(), "{label} must name the path");
                assert_eq!(error.source(), ErrorSource::Io, "{label}");
            }
            Expected::MissingAsset => {
                assert!(matches!(error, Error::MissingAsset(_)), "{label}: {error:?}");
                // The name reaches a caller whole, whatever the producer held when it raised this.
                let name = error.asset().unwrap_or_else(|| panic!("{label} must name the asset"));
                assert!(!name.contains('\\') && !name.contains('/'), "{label}: {name} is a path, not a name");
                assert!(name.ends_with(".png"), "{label}: {name} is not an asset file");
                assert_eq!(error.source(), ErrorSource::Asset, "{label}");
            }
            Expected::DamagedAsset => {
                assert!(matches!(error, Error::DamagedAsset { .. }), "{label}: {error:?}");
                assert!(error.asset().is_some(), "{label} must name the asset");
                assert_eq!(error.source(), ErrorSource::Asset, "{label}");
            }
            Expected::OverLimit => assert!(matches!(error, Error::TooLarge(_)), "{label}: {error:?}"),
            Expected::UnsupportedVersion(version) => {
                assert!(matches!(error, Error::UnsupportedVersion(found) if found == *version), "{label}: {error:?}");
            }
        }
    }
}

#[test]
fn every_golden_fixture_still_opens() {
    let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures");
    let mut checked = 0;
    for entry in fs::read_dir(&fixtures).expect("the fixture directory") {
        let path = entry.expect("a fixture").path();
        if path.extension().map(|kind| kind == "comp").unwrap_or(false) {
            store::load(&path).unwrap_or_else(|error| panic!("{} must open: {error}", path.display()));
            checked += 1;
        }
    }
    assert!(checked >= 3, "expected the golden packages to be there, found {checked}");
}
