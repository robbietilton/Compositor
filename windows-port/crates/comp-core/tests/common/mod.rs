//! Shared helpers for the comp-core integration tests.
//!
//! Packages here are written by hand instead of through save, so a test can shape the manifests
//! older app versions wrote and keep every asset byte under its own control.
#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};

use uuid::Uuid;

use comp_core::bitmap::{Bitmap8, Gray8};
use comp_core::geom::{Guide, GuideAxis, PointF, SizeF, Transform};
use comp_core::manifest::{LayerRecord, Manifest, COLOR_SPACE, FORMAT_ID};
use comp_core::png_io;

/// A temporary directory that removes itself, so a failing test leaves nothing behind.
pub struct TempTree {
    path: PathBuf,
}

impl TempTree {
    pub fn new(tag: &str) -> TempTree {
        let path = std::env::temp_dir().join(format!("compit-{tag}-{}", Uuid::new_v4()));
        fs::create_dir_all(&path).expect("a temp directory");
        TempTree { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn join(&self, name: &str) -> PathBuf {
        self.path.join(name)
    }

    /// A package path inside the tree; the package itself is not created.
    pub fn package(&self, name: &str) -> PathBuf {
        self.path.join(format!("{name}.comp"))
    }

    /// The names of everything in the tree, for leftover checks after a save.
    pub fn entries(&self) -> Vec<String> {
        fs::read_dir(&self.path)
            .expect("a temp directory")
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name().to_string_lossy().to_string())
            .collect()
    }

    /// Everything a save may leave behind if it is interrupted.
    pub fn debris(&self) -> Vec<String> {
        self.entries()
            .into_iter()
            .filter(|name| name.contains(".staging-") || name.contains(".backup-"))
            .collect()
    }
}

impl Drop for TempTree {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

/// The asset file name a layer id must use, in the uppercase the format stores.
pub fn asset_name(id: Uuid) -> String {
    format!("{}.png", id.to_string().to_uppercase())
}

pub fn mask_name(id: Uuid) -> String {
    format!("{}.mask.png", id.to_string().to_uppercase())
}

pub fn image_bytes(bitmap: &Bitmap8) -> Vec<u8> {
    png_io::encode_rgba8(bitmap).expect("a PNG")
}

pub fn mask_bytes(mask: &Gray8) -> Vec<u8> {
    png_io::encode_gray8(mask).expect("a PNG")
}

/// A layer record carrying only what every format version understands.
pub fn record(id: Uuid, name: &str, width: f64, height: f64) -> LayerRecord {
    LayerRecord {
        id,
        name: name.to_string(),
        is_visible: true,
        transform: Transform::new(PointF::new(0.0, 0.0), SizeF::new(width, height)),
        image_file: Some(asset_name(id)),
        parent_id: None,
        is_group: None,
        opacity: None,
        blend_mode: None,
        mask_file: None,
        mask_enabled: None,
        mask_source_id: None,
        adjustment: None,
        mask_placement: None,
        mask_linked: None,
        shape: None,
        effects: None,
        text: None,
    }
}

/// A group record: a folder has no pixels and no asset of its own.
pub fn group_record(id: Uuid, name: &str, width: f64, height: f64) -> LayerRecord {
    let mut layer = record(id, name, width, height);
    layer.image_file = None;
    layer.is_group = Some(true);
    layer
}

/// A manifest around a layer list, with the document fields the tests do not vary.
pub fn manifest(version: u32, width: u32, height: u32, layers: Vec<LayerRecord>) -> Manifest {
    Manifest {
        format: FORMAT_ID.to_string(),
        version,
        color_space: COLOR_SPACE.to_string(),
        resolution: Some(72.0),
        document_id: Uuid::new_v4(),
        width,
        height,
        active_layer_id: layers.first().map(|layer| layer.id),
        layers,
        guides: None,
    }
}

/// Writes a package directory exactly as given: manifest text plus the named assets.
pub fn write_raw(package: &Path, manifest_json: &str, assets: &[(String, Vec<u8>)]) {
    fs::create_dir_all(package.join("images")).expect("a package directory");
    fs::write(package.join("manifest.json"), manifest_json).expect("a manifest");
    for (name, bytes) in assets {
        fs::write(package.join("images").join(name), bytes).expect("an asset");
    }
}

/// Writes a package from a manifest record.
pub fn write_package(package: &Path, manifest: &Manifest, assets: &[(String, Vec<u8>)]) {
    write_raw(package, &serde_json::to_string(&manifest).expect("JSON"), assets);
}

/// The bytes of a package manifest on disk.
pub fn manifest_text(package: &Path) -> String {
    fs::read_to_string(package.join("manifest.json")).expect("a manifest")
}

/// The parsed manifest of a package on disk, for field-level assertions.
pub fn manifest_value(package: &Path) -> serde_json::Value {
    serde_json::from_str(&manifest_text(package)).expect("valid JSON")
}

pub fn guide(axis: GuideAxis, position: f64) -> Guide {
    Guide { id: Uuid::new_v4(), axis, position }
}

/// Pixels that compress badly and differ in every byte, so a lossy step cannot pass unnoticed.
pub fn noisy(width: u32, height: u32, seed: u32) -> Bitmap8 {
    let mut bitmap = Bitmap8::new(width, height);
    let mut state = seed;
    for y in 0..height {
        for x in 0..width {
            state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            let bytes = state.to_le_bytes();
            bitmap.set(x, y, [bytes[0], bytes[1], bytes[2], bytes[3]]);
        }
    }
    bitmap
}

/// A mask with one value per pixel, so every sample is checked after a round trip.
pub fn ramp(width: u32, height: u32) -> Gray8 {
    let mut mask = Gray8::new(width, height);
    for y in 0..height {
        for x in 0..width {
            mask.set(x, y, ((x * 7 + y * 13) % 256) as u8);
        }
    }
    mask
}
