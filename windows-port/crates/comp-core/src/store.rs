//! Reading and writing .comp packages.
//!
//! A package is a directory holding manifest.json and images/<layer id>.png. Saving stages a
//! complete sibling package and swaps it in, so a failure never replaces the live document.
//! Packages arrive from other machines and scripts and are treated as untrusted input: every asset
//! name, link and surface is checked against the format's limits before its pixels are allocated.
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::sync::Mutex;

use uuid::Uuid;

use crate::bitmap::{Bitmap8, Gray8};
use crate::digest;
use crate::document::{Document, SUPPORTED_VERSIONS};
use crate::error::{Error, Result};
use crate::limits;
use crate::manifest::{Manifest, FORMAT_ID};
use crate::png_io::{self, DecodedPng};
use crate::validate::validate_manifest;

pub const MANIFEST_NAME: &str = "manifest.json";
pub const IMAGES_DIR: &str = "images";
pub const QUICKLOOK_DIR: &str = "QuickLook";

/// What a load produced, including anything the caller should know about.
#[derive(Debug)]
pub struct LoadedProject {
    pub document: Document,
    /// The content digest taken while loading, for change watching.
    pub digest: String,
}

/// Which surface an asset supplies, for the two separate pixel budgets.
#[derive(Clone, Copy, PartialEq, Eq)]
enum SurfaceKind {
    Image,
    Mask,
}

impl SurfaceKind {
    fn name(self) -> &'static str {
        match self {
            SurfaceKind::Image => "image",
            SurfaceKind::Mask => "mask",
        }
    }
}

/// Loads a package into a document with its pixels attached.
pub fn load(path: &Path) -> Result<Document> {
    Ok(load_project(path)?.document)
}

/// Loads a package and reports its digest.
pub fn load_project(path: &Path) -> Result<LoadedProject> {
    let package = path.to_path_buf();
    // A symbolic link to a package directory is fine; anything that is not a directory is not. The
    // three ways this fails are told apart, because a caller has a different thing to say about
    // each: a path that is not there, a path that is not a folder, and a folder that holds no
    // project.
    if !package.is_dir() {
        return Err(match fs::metadata(&package) {
            Ok(metadata) if !metadata.is_dir() => {
                Error::not_a_project(format!("{} is a file, not a package folder", package.display()))
            }
            Ok(_) => Error::illegal_path(package.display().to_string(), "the folder could not be opened"),
            Err(error) => Error::illegal_path(package.display().to_string(), error.to_string()),
        });
    }
    let metadata = read_file(&package.join(MANIFEST_NAME), &package, limits::MAX_MANIFEST_BYTES)
        .map_err(|error| match error {
            // A folder with no readable manifest.json is not a project at all. An asset missing
            // later on is a different matter, and keeps its own kind.
            Error::MissingAsset(_) => Error::not_a_project("it holds no manifest.json"),
            other => other,
        })?;
    let header = Manifest::parse_header(&metadata)?;
    if header.format != FORMAT_ID {
        return Err(Error::not_a_project(format!("its manifest names the format {}", header.format)));
    }
    if !SUPPORTED_VERSIONS.contains(&header.version) {
        return Err(Error::UnsupportedVersion(header.version));
    }
    // The parser knows where it stopped; the field is unknown, because the text never became a
    // document.
    let manifest: Manifest = serde_json::from_slice(&metadata).map_err(|error| Error::manifest_json(&error))?;
    validate_manifest(&manifest)?;

    let mut document = manifest.clone().into_document();
    let mut image_pixels = 0u64;
    let mut mask_pixels = 0u64;
    for layer in &mut document.layers {
        if let Some(file) = layer.image_file.clone() {
            let decoded = read_asset(&package, &file, &mut image_pixels, SurfaceKind::Image)?;
            layer.image = Some(std::sync::Arc::new(decoded.to_bitmap8()?));
        }
        if let Some(file) = layer.mask_file.clone() {
            let decoded = read_asset(&package, &file, &mut mask_pixels, SurfaceKind::Mask)?;
            layer.mask = Some(std::sync::Arc::new(decoded.to_gray8()?));
        }
    }
    let digest = digest::package_digest(&package)?;
    Ok(LoadedProject { document, digest })
}

/// Reads one asset, checks the surface budgets and decodes it.
///
/// The header is measured before the decode so an asset promising a surface beyond the limits is
/// refused without a buffer being allocated for it; a small file can name a huge bitmap.
fn read_asset(package: &Path, file: &str, used: &mut u64, kind: SurfaceKind) -> Result<DecodedPng> {
    let path = package.join(IMAGES_DIR).join(file);
    // The reader reports the path it looked at; a caller wants the asset's own name.
    let bytes = read_file(&path, package, limits::MAX_ASSET_BYTES)
        .map_err(|error| match error {
            Error::MissingAsset(_) => Error::MissingAsset(file.to_string()),
            other => other,
        })?;
    let header = png_io::probe_png(&bytes).map_err(|error| asset_damage(file, error))?;
    check_surface(header.width, header.height, used, kind.name())?;
    let decoded = png_io::decode_png(&bytes).map_err(|error| asset_damage(file, error))?;
    if decoded.width != header.width || decoded.height != header.height {
        return Err(Error::damaged_asset(
            file,
            format!("it declares {}x{} but holds {}x{}", header.width, header.height, decoded.width, decoded.height),
        ));
    }
    // A mask is coverage, never color: the macOS app accepts only 8-bit grayscale without alpha,
    // and a color mask would silently mean something different than its author intended.
    if kind == SurfaceKind::Mask && (!header.is_gray() || !decoded.is_gray_without_alpha()) {
        return Err(Error::damaged_asset(file, "a mask must be 8-bit grayscale without alpha"));
    }
    Ok(decoded)
}

/// What a decoder said about a named asset. A decoder failure is damage to that image; a limit
/// stays a limit, and a path that escapes the package stays an illegal path, so a caller can still
/// tell "this file is broken" from "this file is too big to open" from "this file is not ours".
fn asset_damage(file: &str, error: Error) -> Error {
    match error {
        Error::Decode(detail) => Error::damaged_asset(file, detail),
        other => other,
    }
}

/// Writes a document as a package, replacing any package already at the path.
pub fn save(document: &Document, path: &Path) -> Result<()> {
    let manifest = Manifest::from_document(document);
    validate_manifest(&manifest)?;
    check_document_surfaces(document)?;
    let metadata = manifest.to_json()?;
    if metadata.len() as u64 > limits::MAX_MANIFEST_BYTES {
        return Err(Error::TooLarge(MANIFEST_NAME.into()));
    }

    let parent = path
        .parent()
        .ok_or_else(|| Error::illegal_path(path.display().to_string(), "the path has no folder"))?;
    let name = path
        .file_name()
        .ok_or_else(|| Error::illegal_path(path.display().to_string(), "the path has no file name"))?
        .to_string_lossy()
        .to_string();
    fs::create_dir_all(parent)?;
    let staging = parent.join(format!(".{name}.staging-{}", Uuid::new_v4()));
    stage_and_swap(document, &metadata, &staging, path)
}

/// Every surface the document is about to store, measured against the budgets and against the
/// assets the manifest will name. A layer whose file name outlives its pixels would otherwise
/// write a package that cannot be read back, which the macOS app refuses for the same reason.
fn check_document_surfaces(document: &Document) -> Result<()> {
    let mut image_pixels = 0u64;
    let mut mask_pixels = 0u64;
    for (index, layer) in document.layers.iter().enumerate() {
        match (&layer.image, &layer.image_file) {
            (Some(image), _) => check_surface(image.width(), image.height(), &mut image_pixels, "image")?,
            (None, Some(file)) => {
                return Err(Error::manifest(
                    format!("layers[{index}].imageFile"),
                    format!("the layer names {file} but carries no pixels"),
                ))
            }
            (None, None) => {}
        }
        match (&layer.mask, &layer.mask_file) {
            (Some(mask), _) => check_surface(mask.width(), mask.height(), &mut mask_pixels, "mask")?,
            (None, Some(file)) => {
                return Err(Error::manifest(
                    format!("layers[{index}].maskFile"),
                    format!("the layer names {file} but carries no mask"),
                ))
            }
            (None, None) => {}
        }
    }
    Ok(())
}

/// Writes the staged package and swaps it in, removing the staged copy when anything fails.
fn stage_and_swap(document: &Document, metadata: &str, staging: &Path, target: &Path) -> Result<()> {
    if let Err(error) = write_package(document, staging, metadata) {
        discard(staging);
        return Err(error);
    }
    swap_into_place(staging, target)
}

fn write_package(document: &Document, staging: &Path, metadata: &str) -> Result<()> {
    fs::create_dir_all(staging.join(IMAGES_DIR))?;
    for layer in &document.layers {
        let stem = layer.id.to_string().to_uppercase();
        if let Some(image) = &layer.image {
            let name = format!("{stem}.png");
            let bytes = png_io::encode_rgba8(image)
                .map_err(|error| Error::encode_failed(Some(&name), error.detail()))?;
            fs::write(staging.join(IMAGES_DIR).join(&name), bytes)?;
        }
        if let Some(mask) = &layer.mask {
            let name = format!("{stem}.mask.png");
            let bytes = png_io::encode_gray8(mask)
                .map_err(|error| Error::encode_failed(Some(&name), error.detail()))?;
            fs::write(staging.join(IMAGES_DIR).join(&name), bytes)?;
        }
    }
    // The manifest goes last: a reader that sees it sees every asset it names.
    fs::write(staging.join(MANIFEST_NAME), metadata)?;
    Ok(())
}

/// Removes a staged or backed-up directory, or a stray file that took its place.
fn discard(path: &Path) {
    if fs::remove_dir_all(path).is_err() {
        let _ = fs::remove_file(path);
    }
}

/// Serializes the replacement of a package.
///
/// Windows cannot rename a directory over another one, so a save moves the old package aside and
/// renames the staged one into its place. Two writers interleaving those two steps would each see
/// a free path, one of them would fail, and the loser would leave its staged or backed-up package
/// behind. Saves of different packages only wait for the handful of renames this covers.
static SWAP_LOCK: Mutex<()> = Mutex::new(());

/// Replaces the target with the staged package.
///
/// The old package is moved aside first and removed once the new one is in place. A crash between
/// the two renames leaves the old package under the backup name, never a partial package; the next
/// successful save of the same path leaves nothing behind. If even restoring the backup fails, its
/// path is reported rather than swallowed.
fn swap_into_place(staging: &Path, target: &Path) -> Result<()> {
    let _guard = SWAP_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if !target.exists() {
        return match fs::rename(staging, target) {
            Ok(()) => Ok(()),
            Err(error) => {
                discard(staging);
                Err(error.into())
            }
        };
    }
    let backup = target.with_file_name(format!(
        ".{}.backup-{}",
        target.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(),
        Uuid::new_v4()
    ));
    if let Err(error) = fs::rename(target, &backup) {
        // The old package never moved, so the staged one is dead weight.
        discard(staging);
        return Err(error.into());
    }
    match fs::rename(staging, target) {
        Ok(()) => {
            discard(&backup);
            Ok(())
        }
        Err(error) => {
            // The staged copy always goes: a package that failed to take its place must not be
            // left where a watcher could read it. The original is put back rather than lost.
            discard(staging);
            if fs::rename(&backup, target).is_err() {
                return Err(std::io::Error::new(
                    error.kind(),
                    format!("{error}; the previous package was left at {}", backup.display()),
                )
                .into());
            }
            Err(error.into())
        }
    }
}

/// Reads a file inside the package, rejecting links, oversized files and paths that escape.
fn read_file(file: &Path, package: &Path, maximum: u64) -> Result<Vec<u8>> {
    // The lexical check refuses traversal before the file system is touched.
    if !inside_package(file, package) {
        return Err(Error::illegal_path(
            display_name(file, package),
            "the name points outside the package",
        ));
    }
    let name = display_name(file, package);
    let metadata = fs::symlink_metadata(file).map_err(|_| Error::MissingAsset(name.clone()))?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err(Error::MissingAsset(name));
    }
    if metadata.len() > maximum {
        return Err(Error::TooLarge(name));
    }
    // A link in an intermediate directory passes the lexical check, so the resolved path, which is
    // what the read actually opens, has to stay inside the resolved package as well.
    let root = fs::canonicalize(package)
        .map_err(|error| Error::illegal_path(package.display().to_string(), error.to_string()))?;
    let resolved = fs::canonicalize(file).map_err(|_| Error::MissingAsset(name.clone()))?;
    if !resolved.starts_with(&root) {
        return Err(Error::illegal_path(name, "a link takes it outside the package"));
    }
    Ok(fs::read(file)?)
}

/// True when every component of the path stays inside the package.
pub fn inside_package(file: &Path, package: &Path) -> bool {
    let Ok(relative) = file.strip_prefix(package) else { return false };
    let mut depth = 0i32;
    for component in relative.components() {
        match component {
            Component::Normal(_) => depth += 1,
            Component::CurDir => {}
            Component::ParentDir => {
                depth -= 1;
                if depth < 0 {
                    return false;
                }
            }
            Component::RootDir | Component::Prefix(_) => return false,
        }
    }
    depth >= 1
}

/// Safe file names only: no separators, no traversal, no absolute paths.
pub fn is_safe_asset_name(name: &str) -> bool {
    !name.is_empty()
        && !name.contains(['/', '\\'])
        && !name.contains("..")
        && !name.starts_with('.')
        && name.len() <= 512
}

/// Checks one image or mask against the per-side and per-document pixel budgets.
pub fn check_surface(width: u32, height: u32, used: &mut u64, kind: &str) -> Result<()> {
    if !limits::surface_fits(width, height) {
        return Err(Error::TooLarge(format!("{kind} {width}x{height}")));
    }
    let pixels = width as u64 * height as u64;
    let budget = match kind {
        "mask" => limits::MAX_MASK_PIXELS,
        _ => limits::MAX_IMAGE_PIXELS,
    };
    if *used + pixels > budget {
        return Err(Error::TooLarge(format!("{kind} budget of {budget} pixels")));
    }
    *used += pixels;
    Ok(())
}

/// Writes a document to any directory that does not exist yet, for tests and the CLI.
pub fn create_fresh(document: &Document, path: &Path) -> Result<()> {
    if path.exists() {
        // Not a manifest field: this is about the path the caller chose.
        return Err(Error::illegal_path(
            path.display().to_string(),
            "it already exists, and this writes only to a path that does not",
        ));
    }
    save(document, path)
}

/// A document whose layers carry a solid color, handy for fixtures.
pub fn solid_document(width: u32, height: u32, rgba: [u8; 4]) -> Document {
    let mut document = Document::new(width, height);
    let mut layer = crate::layer::Layer::raster("Background", width, height);
    layer.image = Some(std::sync::Arc::new(Bitmap8::filled(width, height, rgba)));
    layer.image_file = Some(layer.expected_image_file());
    document.active_layer = Some(layer.id);
    document.layers.push(layer);
    document
}

/// A helper used by tests: a mask filled with one value.
pub fn solid_mask(width: u32, height: u32, value: u8) -> Gray8 {
    Gray8::filled(width, height, value)
}

/// The path of a layer's image inside a package.
pub fn image_path(package: &Path, layer_id: Uuid) -> PathBuf {
    package.join(IMAGES_DIR).join(format!("{}.png", layer_id.to_string().to_uppercase()))
}

/// The name an error message should use: the path relative to the package.
fn display_name(file: &Path, package: &Path) -> String {
    file.strip_prefix(package).unwrap_or(file).display().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geom::Transform;
    use std::sync::Arc;

    fn temp_package(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("compstore-{tag}-{}", Uuid::new_v4()));
        dir.join("Doc.comp")
    }

    /// Writes a package with the given manifest text and assets, bypassing save.
    fn write_raw_package(package: &Path, manifest: &str, assets: &[(&str, Vec<u8>)]) {
        fs::create_dir_all(package.join(IMAGES_DIR)).unwrap();
        fs::write(package.join(MANIFEST_NAME), manifest).unwrap();
        for (name, bytes) in assets {
            fs::write(package.join(IMAGES_DIR).join(name), bytes).unwrap();
        }
    }

    /// A valid manifest whose one layer is this id, so its asset name matches the file written.
    fn manifest_json(id: Uuid, version: u32) -> String {
        let mut document = solid_document(4, 4, [1, 2, 3, 255]);
        document.id = id;
        document.active_layer = Some(id);
        document.layers[0].id = id;
        let file = document.layers[0].expected_image_file();
        document.layers[0].image_file = Some(file);
        let mut manifest = Manifest::from_document(&document);
        manifest.version = version;
        serde_json::to_string(&manifest).unwrap()
    }

    fn temp_root(tag: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("compstore-{tag}-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        root
    }

    #[test]
    fn save_then_load_roundtrips_pixels_and_metadata() {
        let package = temp_package("roundtrip");
        let mut document = solid_document(32, 24, [10, 20, 30, 255]);
        let layer_id = document.layers[0].id;
        document.layers[0].name = "Background".to_string();
        document.layers[0].opacity = 0.75;
        document.layers[0].blend = crate::blend::BlendMode::Multiply;
        document.set_layer_mask(layer_id, solid_mask(32, 24, 128));
        save(&document, &package).unwrap();

        let loaded = load(&package).unwrap();
        assert_eq!(loaded.width, 32);
        assert_eq!(loaded.height, 24);
        assert_eq!(loaded.layers.len(), 1);
        assert_eq!(loaded.layers[0].name, "Background");
        assert_eq!(loaded.layers[0].opacity, 0.75);
        assert_eq!(loaded.layers[0].blend, crate::blend::BlendMode::Multiply);
        assert_eq!(loaded.layers[0].image.as_ref().unwrap().get(5, 5), [10, 20, 30, 255]);
        assert_eq!(loaded.layers[0].mask.as_ref().unwrap().get(5, 5), 128);
        assert_eq!(loaded.layers[0].transform, Transform::with_size(32.0, 24.0));
        let _ = fs::remove_dir_all(package.parent().unwrap());
    }

    #[test]
    fn saving_twice_replaces_the_package_and_leaves_no_backup() {
        let package = temp_package("replace");
        let document = solid_document(8, 8, [1, 2, 3, 255]);
        save(&document, &package).unwrap();
        let mut changed = document.clone();
        let layer_id = changed.layers[0].id;
        changed.set_layer_image(layer_id, Bitmap8::filled(8, 8, [9, 9, 9, 255]));
        save(&changed, &package).unwrap();
        let loaded = load(&package).unwrap();
        assert_eq!(loaded.layers[0].image.as_ref().unwrap().get(1, 1), [9, 9, 9, 255]);
        let leftovers: Vec<_> = fs::read_dir(package.parent().unwrap())
            .unwrap()
            .filter_map(|entry| entry.ok())
            .filter(|entry| entry.file_name().to_string_lossy().contains("backup"))
            .collect();
        assert!(leftovers.is_empty(), "a backup directory was left behind");
        let _ = fs::remove_dir_all(package.parent().unwrap());
    }

    #[test]
    fn a_missing_asset_fails_the_load() {
        let package = temp_package("missing");
        let document = solid_document(8, 8, [1, 2, 3, 255]);
        save(&document, &package).unwrap();
        fs::remove_file(image_path(&package, document.layers[0].id)).unwrap();
        assert!(matches!(load(&package), Err(Error::MissingAsset(_))));
        let _ = fs::remove_dir_all(package.parent().unwrap());
    }

    #[test]
    fn a_damaged_manifest_fails_the_load() {
        let package = temp_package("damaged");
        let document = solid_document(8, 8, [1, 2, 3, 255]);
        save(&document, &package).unwrap();
        // Text that is not a manifest at all: not a project, rather than a damaged one.
        fs::write(package.join(MANIFEST_NAME), b"{ not json").unwrap();
        match load(&package) {
            Err(Error::NotAProject { detail }) => assert!(detail.contains("format"), "{detail}"),
            other => panic!("expected a path that is not a project, got {other:?}"),
        }
        // JSON that says which format it is, but does not describe a document: damage, and the
        // parser knows where it stopped. The field stays unknown, because the text never became a
        // document to walk.
        fs::write(
            package.join(MANIFEST_NAME),
            br#"{"format":"com.compositor.project","version":11,"layers":"not a list"}"#,
        )
        .unwrap();
        match load(&package) {
            Err(Error::DamagedManifest { field, line, column, detail }) => {
                assert!(field.is_none(), "a parse failure cannot name a field");
                assert!(line.is_some() && column.is_some(), "the parser knows where it stopped: {detail}");
            }
            other => panic!("expected a damaged manifest, got {other:?}"),
        }
        let _ = fs::remove_dir_all(package.parent().unwrap());
    }

    #[test]
    fn an_unsupported_version_reports_itself() {
        let package = temp_package("version");
        let document = solid_document(8, 8, [1, 2, 3, 255]);
        save(&document, &package).unwrap();
        let text = fs::read_to_string(package.join(MANIFEST_NAME)).unwrap();
        fs::write(package.join(MANIFEST_NAME), text.replace("\"version\": 11", "\"version\": 99")).unwrap();
        assert!(matches!(load(&package), Err(Error::UnsupportedVersion(99))));
        let _ = fs::remove_dir_all(package.parent().unwrap());
    }

    #[test]
    fn path_safety_rules_hold() {
        assert!(is_safe_asset_name("6F1D3C2A-0B7E-4E8A-9C4D-2A1B3C4D5E6F.png"));
        assert!(!is_safe_asset_name("../secret.png"));
        assert!(!is_safe_asset_name("images/x.png"));
        assert!(!is_safe_asset_name("..\\x.png"));
        assert!(!is_safe_asset_name(".hidden.png"));
        assert!(!is_safe_asset_name(""));
        let package = Path::new("C:/docs/Doc.comp");
        assert!(inside_package(&package.join("images/a.png"), package));
        assert!(!inside_package(&package.join("../a.png"), package));
        assert!(!inside_package(&package.join("images/../../a.png"), package));
        assert!(inside_package(&package.join("images/./nested/a.png"), package));
    }

    #[test]
    fn mask_only_layers_roundtrip() {
        let package = temp_package("mask");
        let mut document = Document::new(16, 16);
        let mut layer = crate::layer::Layer::raster("Empty", 16, 16);
        layer.image = Some(Arc::new(Bitmap8::new(16, 16)));
        layer.mask = Some(Arc::new(Gray8::filled(16, 16, 200)));
        layer.mask_enabled = false;
        document.add_layer(layer, None);
        save(&document, &package).unwrap();
        let loaded = load(&package).unwrap();
        assert_eq!(loaded.layers[0].mask.as_ref().unwrap().get(0, 0), 200);
        assert!(!loaded.layers[0].mask_enabled);
        let _ = fs::remove_dir_all(package.parent().unwrap());
    }

    #[test]
    fn an_oversized_manifest_is_rejected() {
        let package = temp_package("bigmanifest");
        let document = solid_document(8, 8, [1, 2, 3, 255]);
        save(&document, &package).unwrap();
        let oversized = vec![b' '; limits::MAX_MANIFEST_BYTES as usize + 1];
        fs::write(package.join(MANIFEST_NAME), oversized).unwrap();
        assert!(matches!(load(&package), Err(Error::TooLarge(_))));
        let _ = fs::remove_dir_all(package.parent().unwrap());
    }

    #[test]
    fn an_asset_over_the_file_limit_is_rejected_before_it_is_read() {
        let root = temp_root("bigasset");
        let package = root.join("Doc.comp");
        let id = Uuid::new_v4();
        write_raw_package(&package, &manifest_json(id, 11), &[]);
        // A sparse file of the right length: the loader must refuse it on size alone.
        let asset = package.join(IMAGES_DIR).join(format!("{}.png", id.to_string().to_uppercase()));
        let file = fs::File::create(&asset).unwrap();
        file.set_len(limits::MAX_ASSET_BYTES + 1).unwrap();
        drop(file);
        assert!(matches!(load(&package), Err(Error::TooLarge(_))));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_png_promising_a_huge_surface_is_refused_from_its_header() {
        let root = temp_root("bomb");
        let package = root.join("Doc.comp");
        let id = Uuid::new_v4();
        let name = format!("{}.png", id.to_string().to_uppercase());
        // Only a header, claiming 20000x20000: decoding would need 1.6 GB, so it must not be tried.
        let mut bomb = vec![0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
        bomb.extend_from_slice(&13u32.to_be_bytes());
        bomb.extend_from_slice(b"IHDR");
        bomb.extend_from_slice(&20_000u32.to_be_bytes());
        bomb.extend_from_slice(&20_000u32.to_be_bytes());
        bomb.extend_from_slice(&[8, 6, 0, 0, 0]);
        bomb.extend_from_slice(&[0u8; 4]);
        write_raw_package(&package, &manifest_json(id, 11), &[(&name, bomb)]);
        assert!(matches!(load(&package), Err(Error::TooLarge(_))));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_non_png_asset_is_rejected() {
        let root = temp_root("notpng");
        let package = root.join("Doc.comp");
        let id = Uuid::new_v4();
        let name = format!("{}.png", id.to_string().to_uppercase());
        let jpeg = vec![0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, b'J', b'F', b'I', b'F', 0x00];
        write_raw_package(&package, &manifest_json(id, 11), &[(&name, jpeg)]);
        // The asset is present and is not a PNG: damage to that file, and it is named.
        match load(&package) {
            Err(Error::DamagedAsset { name: reported, detail }) => {
                assert_eq!(reported, name);
                assert!(!detail.is_empty(), "the decoder's reason is carried");
            }
            other => panic!("expected a damaged asset, got {other:?}"),
        }
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_sixteen_bit_asset_is_rejected() {
        let root = temp_root("sixteen");
        let package = root.join("Doc.comp");
        let id = Uuid::new_v4();
        let name = format!("{}.png", id.to_string().to_uppercase());
        let samples: Vec<u8> = (0..16u16).flat_map(|v| (v * 4000).to_be_bytes()).collect();
        let bytes = {
            let mut out = Vec::new();
            {
                let mut encoder = png::Encoder::new(&mut out, 4, 4);
                encoder.set_color(png::ColorType::Grayscale);
                encoder.set_depth(png::BitDepth::Sixteen);
                let mut writer = encoder.write_header().unwrap();
                writer.write_image_data(&samples).unwrap();
            }
            out
        };
        write_raw_package(&package, &manifest_json(id, 11), &[(&name, bytes)]);
        assert!(matches!(load(&package), Err(Error::DamagedAsset { .. })), "16-bit samples are damage to the asset");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_palette_asset_is_expanded_on_load() {
        let root = temp_root("palette");
        let package = root.join("Doc.comp");
        let id = Uuid::new_v4();
        let name = format!("{}.png", id.to_string().to_uppercase());
        let bytes = {
            let mut out = Vec::new();
            {
                let mut encoder = png::Encoder::new(&mut out, 2, 1);
                encoder.set_color(png::ColorType::Indexed);
                encoder.set_depth(png::BitDepth::Eight);
                encoder.set_palette(vec![255, 0, 0, 0, 255, 0]);
                encoder.set_trns(vec![0, 255]);
                let mut writer = encoder.write_header().unwrap();
                writer.write_image_data(&[0, 1]).unwrap();
            }
            out
        };
        write_raw_package(&package, &manifest_json(id, 11), &[(&name, bytes)]);
        let document = load(&package).unwrap();
        let image = document.layers[0].image.as_ref().unwrap();
        assert_eq!(image.get(0, 0), [255, 0, 0, 0]);
        assert_eq!(image.get(1, 0), [0, 255, 0, 255]);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_color_mask_asset_is_rejected() {
        let root = temp_root("colormask");
        let package = root.join("Doc.comp");
        let id = Uuid::new_v4();
        let mut manifest = Manifest::from_document(&solid_document(4, 4, [1, 2, 3, 255]));
        manifest.layers[0].mask_file = Some(format!("{}.mask.png", id.to_string().to_uppercase()));
        manifest.layers[0].mask_enabled = Some(true);
        manifest.layers[0].id = id;
        manifest.layers[0].image_file = Some(format!("{}.png", id.to_string().to_uppercase()));
        manifest.active_layer_id = Some(id);
        let json = serde_json::to_string(&manifest).unwrap();
        let mask_name = format!("{}.mask.png", id.to_string().to_uppercase());
        let image_name = format!("{}.png", id.to_string().to_uppercase());
        let image = png_io::encode_rgba8(&Bitmap8::filled(4, 4, [1, 2, 3, 255])).unwrap();
        // A mask must be coverage: an RGBA file is refused rather than reduced to luma.
        let mask = png_io::encode_rgba8(&Bitmap8::filled(4, 4, [255, 0, 0, 255])).unwrap();
        write_raw_package(&package, &json, &[(&image_name, image), (&mask_name, mask)]);
        match load(&package) {
            Err(Error::DamagedAsset { name: reported, detail }) => {
                assert_eq!(reported, mask_name);
                assert!(detail.contains("grayscale"), "{detail}");
            }
            other => panic!("expected a damaged asset, got {other:?}"),
        }
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_one_by_one_mask_roundtrips() {
        let package = temp_package("tiny-mask");
        let mut document = Document::new(32, 32);
        let mut layer = crate::layer::Layer::raster("Painted", 32, 32);
        layer.image = Some(Arc::new(Bitmap8::filled(32, 32, [4, 5, 6, 255])));
        // A uniform mask is stored as a single pixel instead of a full-resolution buffer.
        layer.mask = Some(Arc::new(Gray8::filled(1, 1, 0)));
        document.add_layer(layer, None);
        save(&document, &package).unwrap();
        let loaded = load(&package).unwrap();
        let mask = loaded.layers[0].mask.as_ref().unwrap();
        assert_eq!((mask.width(), mask.height()), (1, 1));
        assert_eq!(mask.get(0, 0), 0);
        let _ = fs::remove_dir_all(package.parent().unwrap());
    }

    #[test]
    fn the_quicklook_folder_and_unreferenced_assets_are_ignored() {
        let package = temp_package("quicklook");
        let document = solid_document(8, 8, [1, 2, 3, 255]);
        save(&document, &package).unwrap();
        fs::create_dir_all(package.join(QUICKLOOK_DIR)).unwrap();
        fs::write(package.join(QUICKLOOK_DIR).join("Preview.jpg"), b"not even an image").unwrap();
        fs::write(package.join(IMAGES_DIR).join("stray.txt"), b"hello").unwrap();
        fs::write(package.join("notes.md"), b"notes").unwrap();
        let loaded = load(&package).unwrap();
        assert_eq!(loaded.layers.len(), 1);
        assert_eq!(loaded.layers[0].image.as_ref().unwrap().get(0, 0), [1, 2, 3, 255]);
        let _ = fs::remove_dir_all(package.parent().unwrap());
    }

    #[test]
    fn a_manifest_that_escapes_the_package_is_rejected() {
        let root = temp_root("traversal");
        let package = root.join("Doc.comp");
        let id = Uuid::new_v4();
        fs::write(root.join("escape.png"), b"stolen").unwrap();
        let json = manifest_json(id, 11).replace(
            &format!("{}.png", id.to_string().to_uppercase()),
            "../../escape.png",
        );
        write_raw_package(&package, &json, &[]);
        // The traversal is caught where the name is checked, and the field at fault is named.
        match load(&package) {
            Err(Error::DamagedManifest { field, detail, .. }) => {
                assert_eq!(field.as_deref(), Some("layers[0].imageFile"));
                assert!(detail.contains("named after its layer"), "{detail}");
            }
            other => panic!("expected the asset name to be refused, got {other:?}"),
        }
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn read_file_refuses_paths_outside_the_package() {
        let root = temp_root("outside");
        let package = root.join("Doc.comp");
        fs::create_dir_all(&package).unwrap();
        let outside = root.join("outside.png");
        fs::write(&outside, b"secret").unwrap();
        assert!(matches!(read_file(&outside, &package, 1024), Err(Error::IllegalPath { .. })));
        // A path that only looks relative is refused before the file system is consulted.
        assert!(matches!(
            read_file(&package.join("..").join("outside.png"), &package, 1024),
            Err(Error::IllegalPath { .. })
        ));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn an_asset_that_resolves_outside_the_package_is_refused() {
        let root = temp_root("resolve");
        let package = root.join("Doc.comp");
        let elsewhere = root.join("elsewhere");
        let id = Uuid::new_v4();
        let name = format!("{}.png", id.to_string().to_uppercase());
        let image = png_io::encode_rgba8(&Bitmap8::filled(4, 4, [9, 9, 9, 255])).unwrap();
        write_raw_package(&package, &manifest_json(id, 11), &[(&name, image.clone())]);
        assert!(load(&package).is_ok());

        // An images directory that is a link to another tree would otherwise be read as if it
        // were inside the package. Junctions need no privilege, symlinks do, so try both.
        fs::create_dir_all(&elsewhere).unwrap();
        fs::write(elsewhere.join(&name), &image).unwrap();
        fs::remove_dir_all(package.join(IMAGES_DIR)).unwrap();
        let linked = std::process::Command::new("cmd")
            .args(["/C", "mklink", "/J"])
            .arg(package.join(IMAGES_DIR))
            .arg(&elsewhere)
            .output();
        match linked {
            Ok(output) if output.status.success() => {
                assert!(matches!(load(&package), Err(Error::IllegalPath { .. })));
            }
            _ => eprintln!("skipping the junction case: this machine refuses to make one"),
        }

        // A symlinked asset file is refused where the system allows one to be made at all.
        fs::remove_dir_all(package.join(IMAGES_DIR)).unwrap();
        write_raw_package(&package, &manifest_json(id, 11), &[]);
        let target = package.join(IMAGES_DIR).join(&name);
        match std::os::windows::fs::symlink_file(elsewhere.join(&name), &target) {
            Ok(()) => {
                assert!(matches!(load(&package), Err(Error::MissingAsset(_))));
            }
            Err(_) => eprintln!("skipping the symlink case: making one needs developer mode"),
        }
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_failed_swap_restores_the_original_package() {
        let root = temp_root("rollback");
        let package = root.join("Doc.comp");
        let original = solid_document(8, 8, [1, 2, 3, 255]);
        save(&original, &package).unwrap();

        // A staged package that vanished between the two renames: the swap fails, and the old
        // package must come back from the backup rather than being left aside.
        let staging = root.join(".Doc.comp.staging-vanished");
        let error = swap_into_place(&staging, &package);
        assert!(error.is_err());
        let loaded = load(&package).unwrap();
        assert_eq!(loaded.layers[0].image.as_ref().unwrap().get(0, 0), [1, 2, 3, 255]);
        let leftovers: Vec<_> = fs::read_dir(&root)
            .unwrap()
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name().to_string_lossy().to_string())
            .filter(|name| name.contains("backup") || name.contains("staging"))
            .collect();
        assert!(leftovers.is_empty(), "left behind: {leftovers:?}");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_failed_staging_write_leaves_no_debris() {
        let root = temp_root("debris");
        let package = root.join("Doc.comp");
        let document = solid_document(8, 8, [1, 2, 3, 255]);
        save(&document, &package).unwrap();

        // A staged path already taken by a file makes the package write fail; the staged copy is
        // removed and the live package is untouched.
        let staging = root.join(".Doc.comp.staging-blocked");
        fs::write(&staging, b"in the way").unwrap();
        let metadata = Manifest::from_document(&document).to_json().unwrap();
        assert!(stage_and_swap(&document, &metadata, &staging, &package).is_err());
        assert!(!staging.exists(), "the staged path was left behind");
        let loaded = load(&package).unwrap();
        assert_eq!(loaded.layers[0].image.as_ref().unwrap().get(0, 0), [1, 2, 3, 255]);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_save_whose_target_cannot_be_created_is_an_error() {
        let root = temp_root("unwritable");
        // The parent of the package is a file, so no staging directory can be made inside it.
        let blocker = root.join("blocker");
        fs::write(&blocker, b"file").unwrap();
        let document = solid_document(8, 8, [1, 2, 3, 255]);
        assert!(matches!(save(&document, &blocker.join("Doc.comp")), Err(Error::Io(_))));
        assert_eq!(fs::read(&blocker).unwrap(), b"file");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_layer_named_without_its_pixels_is_refused_by_save() {
        let root = temp_root("stale");
        let package = root.join("Doc.comp");
        let mut document = solid_document(8, 8, [1, 2, 3, 255]);
        document.layers[0].image = None;
        let error = save(&document, &package);
        // The field at fault is named, rather than blamed on a missing asset.
        match error {
            Err(Error::DamagedManifest { field, .. }) => {
                assert_eq!(field.as_deref(), Some("layers[0].imageFile"));
            }
            other => panic!("expected the layer field to be named, got {other:?}"),
        }
        assert!(!package.exists(), "a package was written for a document that cannot round-trip");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_rejected_document_never_replaces_the_live_package() {
        let root = temp_root("reject");
        let package = root.join("Doc.comp");
        let original = solid_document(8, 8, [1, 2, 3, 255]);
        save(&original, &package).unwrap();

        // A group carrying pixels fails validation, so the save stops before it stages anything.
        let mut broken = solid_document(8, 8, [9, 9, 9, 255]);
        broken.layers[0].is_group = true;
        assert!(save(&broken, &package).is_err());
        let loaded = load(&package).unwrap();
        assert_eq!(loaded.layers[0].image.as_ref().unwrap().get(0, 0), [1, 2, 3, 255]);
        let leftovers: Vec<_> = fs::read_dir(&root)
            .unwrap()
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name().to_string_lossy().to_string())
            .filter(|name| name.contains("staging") || name.contains("backup"))
            .collect();
        assert!(leftovers.is_empty(), "left behind: {leftovers:?}");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn read_file_enforces_the_byte_limit() {
        let root = temp_root("limit");
        let package = root.join("Doc.comp");
        fs::create_dir_all(package.join(IMAGES_DIR)).unwrap();
        fs::write(package.join(MANIFEST_NAME), vec![b'x'; 2048]).unwrap();
        let manifest = package.join(MANIFEST_NAME);
        assert!(read_file(&manifest, &package, 4096).is_ok());
        assert!(matches!(read_file(&manifest, &package, 1024), Err(Error::TooLarge(_))));
        // A directory where a file belongs is missing, not readable.
        assert!(matches!(read_file(&package.join(IMAGES_DIR), &package, 4096), Err(Error::MissingAsset(_))));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn saving_a_document_with_two_layers_keeps_their_order_and_ids() {
        let package = temp_package("layers");
        let mut document = Document::new(8, 8);
        let bottom = crate::layer::Layer::with_image("Bottom", Bitmap8::filled(8, 8, [1, 1, 1, 255]));
        let bottom_id = bottom.id;
        document.add_layer(bottom, None);
        let top = crate::layer::Layer::with_image("Top", Bitmap8::filled(8, 8, [2, 2, 2, 255]));
        let top_id = top.id;
        document.add_layer(top, None);
        save(&document, &package).unwrap();
        let loaded = load(&package).unwrap();
        assert_eq!(loaded.layers.iter().map(|layer| layer.id).collect::<Vec<_>>(), vec![bottom_id, top_id]);
        assert_eq!(loaded.layers[1].name, "Top");
        let _ = fs::remove_dir_all(package.parent().unwrap());
    }
}
