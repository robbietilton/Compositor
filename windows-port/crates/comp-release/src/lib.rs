//! Updates for Compositor for Windows.
//!
//! The macOS app ships Sparkle: an appcast the app polls, an EdDSA signature on each release, and a
//! staged replacement. This crate is the Windows counterpart's data layer — no HTTP client, no
//! installer, no registry — so the behaviour that matters can be tested without a network:
//!
//! * the update manifest and its per-file hashes ([\`UpdateManifest\`]),
//! * whether a newer build is available ([\`UpdateManifest::check\`]),
//! * verifying a downloaded file against the manifest ([\`verify_file\`]),
//! * swapping a staged build into place without ever leaving a half-installed editor
//!   ([\`stage_and_swap\`], [\`cleanup_previous\`]).
//!
//! The fetcher is deliberately the caller's job: the GUI and the CLI bring their own HTTP client and
//! hand this crate bytes or paths.
//!
//! The crate is called `comp-release` rather than `comp-update` on purpose: Windows' installer
//! detection treats an executable whose name contains "update", "install" or "setup" as an installer
//! and demands elevation, which made the test binary fail with error 740 before it could run.
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};

pub mod version;

pub use version::{is_newer, Version};

/// One file inside a release.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpdateFile {
    pub name: String,
    /// Lowercase hex SHA-256 of the file's bytes.
    pub sha256: String,
    pub size: u64,
}

/// What a release publishes: which build it is, and what the payload contains.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateManifest {
    pub name: String,
    pub version: String,
    #[serde(default = "default_channel")]
    pub channel: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub published_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
    /// Where the payload can be fetched, when the manifest is not sitting next to it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    pub files: Vec<UpdateFile>,
}

fn default_channel() -> String {
    "portable".to_string()
}

/// What a check decided.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decision {
    /// The running build is the same or newer.
    UpToDate { current: Version, offered: Version },
    /// A newer build is published.
    Available { current: Version, offered: Version },
    /// The manifest is newer but on another channel; the caller decides whether to offer it.
    OtherChannel { channel: String },
}

#[derive(Debug, thiserror::Error)]
pub enum UpdateError {
    #[error("the update manifest is not valid JSON: {0}")]
    InvalidManifest(#[from] serde_json::Error),
    #[error("{0} is not a version this build understands")]
    InvalidVersion(String),
    #[error("{name} is missing, or is not a regular file")]
    MissingFile { name: String },
    #[error("{name} is {actual} bytes, the manifest says {expected}")]
    SizeMismatch { name: String, expected: u64, actual: u64 },
    #[error("{name} has hash {actual}, the manifest says {expected}")]
    HashMismatch { name: String, expected: String, actual: String },
    #[error("the manifest lists no files")]
    EmptyRelease,
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

impl UpdateManifest {
    /// Reads a manifest from a file.
    pub fn load(path: &Path) -> Result<Self, UpdateError> {
        let bytes = fs::read(path)?;
        Ok(serde_json::from_slice(&bytes)?)
    }

    pub fn to_json(&self) -> Result<String, UpdateError> {
        Ok(serde_json::to_string_pretty(self)?)
    }

    /// Compares the running version against this release.
    pub fn check(&self, current: &str, channel: &str) -> Result<Decision, UpdateError> {
        let current_version = Version::parse(current)?;
        let offered = Version::parse(&self.version)?;
        if self.channel != channel {
            return Ok(Decision::OtherChannel { channel: self.channel.clone() });
        }
        if offered > current_version {
            Ok(Decision::Available { current: current_version, offered })
        } else {
            Ok(Decision::UpToDate { current: current_version, offered })
        }
    }

    /// Every file a release must carry, in the order the manifest lists them.
    pub fn names(&self) -> Vec<&str> {
        self.files.iter().map(|file| file.name.as_str()).collect()
    }

    /// Checks a directory against the manifest, so a partial download is caught before it is applied.
    pub fn verify_directory(&self, directory: &Path) -> Result<(), UpdateError> {
        if self.files.is_empty() {
            return Err(UpdateError::EmptyRelease);
        }
        for file in &self.files {
            verify_file(&directory.join(&file.name), file)?;
        }
        Ok(())
    }

    /// Hashes a directory and returns the manifest that would describe it.
    pub fn describe_directory(
        name: &str,
        version: &str,
        channel: &str,
        directory: &Path,
    ) -> Result<Self, UpdateError> {
        let mut files = Vec::new();
        let mut entries: Vec<PathBuf> = fs::read_dir(directory)?
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.path())
            .filter(|path| path.is_file())
            .collect();
        entries.sort();
        for path in entries {
            let bytes = fs::read(&path)?;
            files.push(UpdateFile {
                name: path
                    .file_name()
                    .map(|name| name.to_string_lossy().to_string())
                    .unwrap_or_default(),
                sha256: sha256_hex(&bytes),
                size: bytes.len() as u64,
            });
        }
        Ok(UpdateManifest {
            name: name.to_string(),
            version: version.to_string(),
            channel: channel.to_string(),
            published_at: None,
            notes: None,
            url: None,
            files,
        })
    }
}

/// The lowercase hex SHA-256 of some bytes.
pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

/// Checks one file against a manifest entry: it must exist, be the right size, and hash the same.
pub fn verify_file(path: &Path, expected: &UpdateFile) -> Result<(), UpdateError> {
    let metadata = fs::symlink_metadata(path).map_err(|_| UpdateError::MissingFile {
        name: expected.name.clone(),
    })?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err(UpdateError::MissingFile { name: expected.name.clone() });
    }
    let bytes = fs::read(path)?;
    if bytes.len() as u64 != expected.size {
        return Err(UpdateError::SizeMismatch {
            name: expected.name.clone(),
            expected: expected.size,
            actual: bytes.len() as u64,
        });
    }
    let actual = sha256_hex(&bytes);
    if actual != expected.sha256.to_lowercase() {
        return Err(UpdateError::HashMismatch {
            name: expected.name.clone(),
            expected: expected.sha256.clone(),
            actual,
        });
    }
    Ok(())
}

/// The suffix a replaced binary is parked under until the next successful start.
pub const PREVIOUS_SUFFIX: &str = ".previous";

/// Replaces \`target\` with \`staged\`.
///
/// Windows cannot rename over a running image, so the old file moves aside first: a crash between the
/// two renames leaves the previous build beside the target, never a missing executable. The caller
/// relaunches and calls [\`cleanup_previous\`]; a start that finds a \`.previous\` file knows the last
/// update did not finish.
pub fn stage_and_swap(staged: &Path, target: &Path) -> Result<(), UpdateError> {
    if !staged.is_file() {
        return Err(UpdateError::MissingFile {
            name: staged.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(),
        });
    }
    let previous = previous_path(target);
    if target.exists() {
        if previous.exists() {
            fs::remove_file(&previous)?;
        }
        fs::rename(target, &previous)?;
        if let Err(error) = fs::rename(staged, target) {
            // Put the working build back rather than leave nothing to run.
            let _ = fs::rename(&previous, target);
            return Err(error.into());
        }
        Ok(())
    } else {
        fs::rename(staged, target)?;
        Ok(())
    }
}

/// Where a replaced binary is parked.
pub fn previous_path(target: &Path) -> PathBuf {
    let mut name = target.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    name.push_str(PREVIOUS_SUFFIX);
    target.with_file_name(name)
}

/// True when the last update left a previous build behind, which means it did not finish cleanly.
pub fn update_was_interrupted(target: &Path) -> bool {
    previous_path(target).exists()
}

/// Removes the parked build after a successful start.
pub fn cleanup_previous(target: &Path) -> Result<(), UpdateError> {
    let previous = previous_path(target);
    if previous.exists() {
        fs::remove_file(previous)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("compupdate-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn manifest_for(dir: &Path, version: &str) -> UpdateManifest {
        UpdateManifest::describe_directory("compositor-windows", version, "portable", dir).unwrap()
    }

    #[test]
    fn a_newer_manifest_is_an_update() {
        let dir = temp_dir("newer");
        fs::write(dir.join("compc.exe"), b"binary").unwrap();
        let manifest = manifest_for(&dir, "0.2.0");
        match manifest.check("0.1.0", "portable").unwrap() {
            Decision::Available { offered, .. } => assert_eq!(offered.to_string(), "0.2.0"),
            other => panic!("unexpected {other:?}"),
        }
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_same_or_older_manifest_is_not_an_update() {
        let dir = temp_dir("same");
        fs::write(dir.join("compc.exe"), b"binary").unwrap();
        let manifest = manifest_for(&dir, "0.1.0");
        assert!(matches!(
            manifest.check("0.1.0", "portable").unwrap(),
            Decision::UpToDate { .. }
        ));
        assert!(matches!(
            manifest.check("0.2.0", "portable").unwrap(),
            Decision::UpToDate { .. }
        ));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn another_channel_is_reported_separately() {
        let dir = temp_dir("channel");
        fs::write(dir.join("compc.exe"), b"binary").unwrap();
        let mut manifest = manifest_for(&dir, "0.2.0");
        manifest.channel = "beta".to_string();
        assert!(matches!(
            manifest.check("0.1.0", "portable").unwrap(),
            Decision::OtherChannel { .. }
        ));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_tampered_file_is_rejected() {
        let dir = temp_dir("tamper");
        fs::write(dir.join("compc.exe"), b"binary").unwrap();
        let manifest = manifest_for(&dir, "0.2.0");
        assert!(manifest.verify_directory(&dir).is_ok());

        fs::write(dir.join("compc.exe"), b"binary!").unwrap();
        match manifest.verify_directory(&dir) {
            Err(UpdateError::SizeMismatch { name, .. }) => assert_eq!(name, "compc.exe"),
            other => panic!("unexpected {other:?}"),
        }

        // Same length, different bytes: only the hash catches it.
        fs::write(dir.join("compc.exe"), b"binarv").unwrap();
        match manifest.verify_directory(&dir) {
            Err(UpdateError::HashMismatch { name, .. }) => assert_eq!(name, "compc.exe"),
            other => panic!("unexpected {other:?}"),
        }
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_missing_file_is_rejected() {
        let dir = temp_dir("missing");
        fs::write(dir.join("compc.exe"), b"binary").unwrap();
        let manifest = manifest_for(&dir, "0.2.0");
        fs::remove_file(dir.join("compc.exe")).unwrap();
        assert!(matches!(
            manifest.verify_directory(&dir),
            Err(UpdateError::MissingFile { .. })
        ));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_empty_release_is_rejected() {
        let dir = temp_dir("empty");
        let manifest = manifest_for(&dir, "0.2.0");
        assert!(matches!(manifest.verify_directory(&dir), Err(UpdateError::EmptyRelease)));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn swapping_parks_the_old_build_and_can_clean_up() {
        let dir = temp_dir("swap");
        let target = dir.join("compositor.exe");
        let staged = dir.join("staged.exe");
        fs::write(&target, b"old").unwrap();
        fs::write(&staged, b"new").unwrap();

        stage_and_swap(&staged, &target).unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"new");
        assert!(update_was_interrupted(&target), "the previous build should be parked");
        assert_eq!(fs::read(previous_path(&target)).unwrap(), b"old");

        cleanup_previous(&target).unwrap();
        assert!(!update_was_interrupted(&target));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn swapping_without_a_previous_build_just_places_the_file() {
        let dir = temp_dir("fresh");
        let target = dir.join("compositor.exe");
        let staged = dir.join("staged.exe");
        fs::write(&staged, b"new").unwrap();
        stage_and_swap(&staged, &target).unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"new");
        assert!(!update_was_interrupted(&target));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_manifest_round_trips_through_json_with_camel_case() {
        let dir = temp_dir("json");
        fs::write(dir.join("compc.exe"), b"binary").unwrap();
        let mut manifest = manifest_for(&dir, "0.2.0");
        manifest.published_at = Some("2026-10-04T00:00:00Z".to_string());
        let json = manifest.to_json().unwrap();
        assert!(json.contains("publishedAt"), "{json}");
        let back: UpdateManifest = serde_json::from_str(&json).unwrap();
        assert_eq!(back, manifest);
        let _ = fs::remove_dir_all(&dir);
    }
}
