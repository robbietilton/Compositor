//! Release versions: `0.1.0`, `1.4.5`, and pre-releases such as `0.2.0-beta.1`.
//!
//! Semantic versioning is used rather than the macOS app's `CFBundleVersion` integer because a
//! Windows build ships several binaries that must move together, and a channel suffix keeps a beta
//! from looking newer than the release it precedes.
pub use semver::Version;

use crate::UpdateError;

impl From<semver::Error> for UpdateError {
    fn from(error: semver::Error) -> Self {
        UpdateError::InvalidVersion(error.to_string())
    }
}

/// True when `candidate` is a later release than `current`.
///
/// A pre-release is older than the release with the same numbers, so `0.2.0-beta.1` never replaces
/// `0.2.0`, and build metadata is ignored, as semantic versioning requires.
pub fn is_newer(candidate: &str, current: &str) -> Result<bool, UpdateError> {
    let mut candidate = Version::parse(candidate)?;
    let mut current = Version::parse(current)?;
    // The semver crate's ordering includes build metadata; the specification gives it no precedence,
    // so drop it before comparing.
    candidate.build = semver::BuildMetadata::EMPTY;
    current.build = semver::BuildMetadata::EMPTY;
    Ok(candidate > current)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn newer_versions_are_newer() {
        assert!(is_newer("0.1.1", "0.1.0").unwrap());
        assert!(is_newer("0.2.0", "0.1.9").unwrap());
        assert!(is_newer("1.0.0", "0.9.9").unwrap());
    }

    #[test]
    fn the_same_version_is_not_newer() {
        assert!(!is_newer("0.1.0", "0.1.0").unwrap());
        assert!(!is_newer("0.1.0", "0.1.1").unwrap());
    }

    #[test]
    fn a_prerelease_does_not_replace_its_release() {
        assert!(!is_newer("0.2.0-beta.1", "0.2.0").unwrap());
        assert!(is_newer("0.2.0", "0.2.0-beta.1").unwrap());
        assert!(is_newer("0.2.0-beta.2", "0.2.0-beta.1").unwrap());
    }

    #[test]
    fn build_metadata_is_ignored() {
        assert!(!is_newer("0.1.0+build7", "0.1.0").unwrap());
    }

    #[test]
    fn nonsense_is_an_error_not_a_guess() {
        assert!(matches!(is_newer("next", "0.1.0"), Err(UpdateError::InvalidVersion(_))));
        assert!(matches!(is_newer("0.1.0", "1.0"), Err(UpdateError::InvalidVersion(_))));
    }
}
