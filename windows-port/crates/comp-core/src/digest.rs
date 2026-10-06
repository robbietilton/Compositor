//! A package's content digest: the manifest's bytes plus each asset's name and byte length.
//!
//! The macOS app watches for external edits by comparing this, never file timestamps, so a package
//! that was only touched keeps its digest. Assets are not read: hashing every image of a large
//! project would hold up every save. A PNG whose pixels change all but always changes length, so
//! the name and size pairs catch the rest. Rewriting an asset with the same byte length while
//! leaving the manifest alone is invisible by design, which is why docs/writing-comp-files.md
//! tells writers to change the manifest in that case.
use std::fs;
use std::path::Path;

use sha2::{Digest as _, Sha256};

use crate::error::{Error, Result};
use crate::limits;
use crate::store::{IMAGES_DIR, MANIFEST_NAME};

/// A digest of everything a reload depends on.
pub fn package_digest(path: &Path) -> Result<String> {
    // The manifest is hashed as bytes, not parsed: a package caught half written still gets a
    // digest, one that matches nothing, so a watcher waits for the next change rather than failing.
    let metadata = read_regular_file(&path.join(MANIFEST_NAME), limits::MAX_MANIFEST_BYTES)?;
    let mut hasher = Sha256::new();
    hasher.update(&metadata);
    // Assets fold in by name and length, the way the macOS watcher reads them.
    let mut entries = asset_entries(&path.join(IMAGES_DIR))?;
    entries.sort();
    for (name, length) in entries {
        hasher.update(name.as_bytes());
        hasher.update(length.to_le_bytes());
    }
    Ok(format!("{:x}", hasher.finalize()))
}

/// True when the digest changed since the previous value.
pub fn changed(path: &Path, previous: &str) -> Result<bool> {
    Ok(package_digest(path)? != previous)
}

/// The name and byte length of every regular file in the images directory.
fn asset_entries(images: &Path) -> Result<Vec<(String, u64)>> {
    let mut entries = Vec::new();
    // A package whose images directory is missing or unreadable simply has no assets yet.
    let Ok(directory) = fs::read_dir(images) else { return Ok(entries) };
    for entry in directory {
        let entry = entry?;
        // Directories and links are not assets; the macOS watcher hashes regular files only.
        if !entry.file_type()?.is_file() {
            continue;
        }
        entries.push((entry.file_name().to_string_lossy().to_string(), entry.metadata()?.len()));
    }
    Ok(entries)
}

fn read_regular_file(path: &Path, maximum: u64) -> Result<Vec<u8>> {
    let metadata = fs::symlink_metadata(path).map_err(|_| Error::MissingAsset(display(path)))?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err(Error::MissingAsset(display(path)));
    }
    if metadata.len() > maximum {
        return Err(Error::TooLarge(display(path)));
    }
    Ok(fs::read(path)?)
}

fn display(path: &Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| path.display().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    use crate::bitmap::Bitmap8;
    use crate::document::Document;
    use crate::layer::Layer;
    use crate::store;

    /// A manifest with a fixed shape, so only the edits a test makes can move the digest.
    fn manifest_bytes(name: &str) -> Vec<u8> {
        format!("{{\n  \"format\": \"com.compositor.project\",\n  \"version\": 11,\n  \"name\": \"{name}\"\n}}\n")
            .into_bytes()
    }

    fn temp_package(tag: &str) -> (PathBuf, PathBuf) {
        let root = std::env::temp_dir().join(format!("compdigest-{tag}-{}", uuid::Uuid::new_v4()));
        let package = root.join("Doc.comp");
        fs::create_dir_all(package.join(IMAGES_DIR)).unwrap();
        fs::write(package.join(MANIFEST_NAME), manifest_bytes("A")).unwrap();
        (root, package)
    }

    #[test]
    fn the_manifest_and_the_asset_lengths_drive_the_digest() {
        let (root, package) = temp_package("basic");
        fs::write(package.join(IMAGES_DIR).join("A.png"), vec![1u8; 64]).unwrap();
        let first = package_digest(&package).unwrap();
        assert!(!changed(&package, &first).unwrap());
        // Writing the same bytes again is not a change.
        fs::write(package.join(IMAGES_DIR).join("A.png"), vec![1u8; 64]).unwrap();
        assert!(!changed(&package, &first).unwrap());
        // A different length is.
        fs::write(package.join(IMAGES_DIR).join("A.png"), vec![1u8; 65]).unwrap();
        assert!(changed(&package, &first).unwrap());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn pixels_of_the_same_length_are_invisible_without_a_manifest_change() {
        let (root, package) = temp_package("samesize");
        let asset = package.join(IMAGES_DIR).join("A.png");
        fs::write(&asset, vec![7u8; 128]).unwrap();
        let first = package_digest(&package).unwrap();
        // The documented boundary: a script that swaps in different pixels of exactly the same
        // byte size is not noticed, because assets are never read.
        fs::write(&asset, vec![200u8; 128]).unwrap();
        assert!(!changed(&package, &first).unwrap());
        assert_eq!(package_digest(&package).unwrap(), first);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_manifest_change_is_what_reveals_a_same_length_swap() {
        let (root, package) = temp_package("manifestedit");
        let asset = package.join(IMAGES_DIR).join("A.png");
        fs::write(&asset, vec![7u8; 128]).unwrap();
        let first = package_digest(&package).unwrap();
        fs::write(&asset, vec![200u8; 128]).unwrap();
        assert!(!changed(&package, &first).unwrap());
        // Renaming the layer rewrites the manifest, which is what the format asks writers to do.
        fs::write(package.join(MANIFEST_NAME), manifest_bytes("B")).unwrap();
        assert!(changed(&package, &first).unwrap());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn adding_and_removing_assets_changes_the_digest() {
        let (root, package) = temp_package("addremove");
        let images = package.join(IMAGES_DIR);
        fs::write(images.join("A.png"), vec![1u8; 16]).unwrap();
        let first = package_digest(&package).unwrap();
        fs::write(images.join("B.png"), vec![2u8; 16]).unwrap();
        assert!(changed(&package, &first).unwrap());
        let with_two = package_digest(&package).unwrap();
        fs::remove_file(images.join("B.png")).unwrap();
        assert_eq!(package_digest(&package).unwrap(), first);
        assert_ne!(with_two, first);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn entries_that_are_not_regular_files_are_ignored() {
        let (root, package) = temp_package("nonfiles");
        let images = package.join(IMAGES_DIR);
        fs::write(images.join("A.png"), vec![1u8; 16]).unwrap();
        let first = package_digest(&package).unwrap();
        // A Finder or sync client leftover must not read as a content change.
        fs::create_dir_all(images.join("thumbs")).unwrap();
        fs::write(images.join("thumbs").join("A.png"), vec![9u8; 512]).unwrap();
        assert_eq!(package_digest(&package).unwrap(), first);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_missing_manifest_is_an_error() {
        let (root, package) = temp_package("missing");
        fs::remove_file(package.join(MANIFEST_NAME)).unwrap();
        assert!(matches!(package_digest(&package), Err(Error::MissingAsset(_))));
        assert!(changed(&package, "whatever").is_err());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn an_oversized_manifest_is_refused() {
        let (root, package) = temp_package("oversized");
        let oversized = vec![b' '; limits::MAX_MANIFEST_BYTES as usize + 1];
        fs::write(package.join(MANIFEST_NAME), oversized).unwrap();
        assert!(matches!(package_digest(&package), Err(Error::TooLarge(_))));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_half_written_manifest_still_has_a_digest() {
        let (root, package) = temp_package("halfwritten");
        fs::write(package.join(MANIFEST_NAME), b"{ \"format\": \"com.compos").unwrap();
        let digest = package_digest(&package).unwrap();
        // Reading it back is what fails; the watcher compares this digest and waits for more.
        assert!(crate::store::load(&package).is_err());
        assert!(!changed(&package, &digest).unwrap());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn saving_the_same_document_twice_keeps_the_digest() {
        let root = std::env::temp_dir().join(format!("compdigest-save-{}", uuid::Uuid::new_v4()));
        let package = root.join("Doc.comp");
        let document = store::solid_document(16, 16, [1, 2, 3, 255]);
        store::save(&document, &package).unwrap();
        let first = package_digest(&package).unwrap();
        store::save(&document, &package).unwrap();
        assert_eq!(package_digest(&package).unwrap(), first);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn digest_changes_when_an_asset_grows() {
        let dir = std::env::temp_dir().join(format!("compdigest-{}", uuid::Uuid::new_v4()));
        let package = dir.join("Doc.comp");
        let mut document = Document::new(16, 16);
        let mut layer = Layer::raster("L", 16, 16);
        layer.image = Some(std::sync::Arc::new(Bitmap8::filled(16, 16, [1, 2, 3, 255])));
        document.add_layer(layer, None);
        store::save(&document, &package).unwrap();
        let first = package_digest(&package).unwrap();
        assert!(!changed(&package, &first).unwrap());

        let mut bigger = document.clone();
        let layer_id = bigger.layers[0].id;
        bigger.set_layer_image(layer_id, Bitmap8::filled(32, 32, [1, 2, 3, 255]));
        let mut layer = bigger.layers[0].clone();
        layer.transform = crate::geom::Transform::with_size(32.0, 32.0);
        bigger.layers[0] = layer;
        store::save(&bigger, &package).unwrap();
        assert!(changed(&package, &first).unwrap());
        let _ = fs::remove_dir_all(&dir);
    }
}
