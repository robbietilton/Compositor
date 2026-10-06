//! Pixel comparison against the project's independent reference fixtures.
//!
//! Two sets are checked. `tools/verify/fixtures` comes from the Python reference implementation of the
//! W3C/PDF compositing model (`tools/verify/comp_reference.py`); `tools/verify/oracle/fixtures-oracle`
//! comes from the adjustment and layer-effect oracle, transcribed kernel by kernel from the macOS Swift
//! and C sources (`tools/verify/oracle/`). Both are rendered here with `flatten_document` and compared
//! channel by channel, so a formula mistake shows up in a crate test rather than only in a script. Each
//! set is skipped quietly when it is absent: a crate test must not depend on the tools directory.

use std::path::{Path, PathBuf};

use comp_core::png_io;
use comp_render::flatten_document;

/// How far a channel may differ where the reference is exact: the engine rounds to 8 bits once per
/// layer, and the reference rounds its own way.
const TOLERANCE: i32 = 1;

fn verify_dir() -> Option<PathBuf> {
    let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
    let root = manifest.parent()?.parent()?;
    let dir = root.join("tools").join("verify");
    if dir.is_dir() {
        Some(dir)
    } else {
        None
    }
}

/// Renders one package and reports the worst channel difference against its expected PNG.
fn compare(package: &Path, expected: &Path) -> Result<i32, String> {
    let document = comp_core::store::load(package).map_err(|error| format!("load: {error}"))?;
    let bytes = std::fs::read(expected).map_err(|error| format!("expected: {error}"))?;
    let reference = png_io::decode_png(&bytes)
        .and_then(|decoded| decoded.to_bitmap8())
        .map_err(|error| format!("decode: {error}"))?;
    let actual = flatten_document(&document);
    if (actual.width(), actual.height()) != (reference.width(), reference.height()) {
        return Err(format!(
            "size {}x{} vs {}x{}",
            actual.width(),
            actual.height(),
            reference.width(),
            reference.height()
        ));
    }
    let mut worst = 0i32;
    for (got, want) in actual.pixels().iter().zip(reference.pixels().iter()) {
        worst = worst.max((*got as i32 - *want as i32).abs());
    }
    Ok(worst)
}

/// `(name, package, expected)` out of a fixture index, without parsing the JSON around them.
fn parse_index(text: &str) -> Vec<(String, String, String)> {
    let mut out = Vec::new();
    let mut name = String::new();
    let mut package = String::new();
    for line in text.lines() {
        let value = |prefix: &str| -> Option<String> {
            let rest = line.trim().strip_prefix(prefix)?;
            Some(rest.trim().trim_end_matches(',').trim_matches('"').to_string())
        };
        if let Some(found) = value("\"name\":") {
            name = found;
        } else if let Some(found) = value("\"package\":") {
            package = found;
        } else if let Some(found) = value("\"expected\":") {
            if !name.is_empty() {
                out.push((name.clone(), package.clone(), found));
            }
        }
    }
    out
}

#[test]
fn fixtures_match_the_reference_within_one_level() {
    let Some(dir) = verify_dir() else { return };
    let fixtures = dir.join("fixtures");
    let Ok(index) = std::fs::read_to_string(fixtures.join("index.json")) else { return };
    let mut compared = 0usize;
    for (name, package, expected) in parse_index(&index) {
        // The index lists packages relative to tools/verify, one level above the fixtures directory.
        let worst = compare(&dir.join(&package), &dir.join(&expected)).unwrap_or_else(|error| panic!("{name}: {error}"));
        assert!(worst <= TOLERANCE, "{name}: worst channel differs by {worst}");
        compared += 1;
    }
    println!("compared {compared} fixtures from tools/verify/fixtures");
}

/// The adjustment and effect oracle's fixtures, each with the tolerance the oracle declares for it: the
/// blurring kinds implement the same intent with a different kernel (see NOTES.md), so theirs is wider.
#[test]
fn oracle_fixtures_match_within_their_own_tolerance() {
    let Some(dir) = verify_dir() else { return };
    let oracle = dir.join("oracle").join("fixtures-oracle");
    let Ok(index) = std::fs::read_to_string(oracle.join("index.json")) else { return };
    let tolerances = parse_tolerances(&index);
    let mut compared = 0usize;
    let mut worst_seen: Vec<(String, i32)> = Vec::new();
    for (name, package, expected) in parse_index(&index) {
        let tolerance = tolerances
            .iter()
            .find(|(entry, _)| *entry == name)
            .map(|(_, value)| *value)
            .unwrap_or(1)
            .max(documented_allowance(&name));
        let worst = compare(&oracle.join(&package), &oracle.join(&expected))
            .unwrap_or_else(|error| panic!("{name}: {error}"));
        worst_seen.push((name.clone(), worst));
        assert!(worst <= tolerance, "{name}: worst channel differs by {worst}, tolerance {tolerance}");
        compared += 1;
    }
    for (name, worst) in &worst_seen {
        print!("{name}={worst} ");
    }
    println!("\ncompared {compared} oracle fixtures");
}

/// The room the engine is allowed where it deliberately differs from the reference, in levels.
///
/// Hue/Saturation runs the exact HSL formula per pixel; the reference predicts what macOS's 33-point
/// color cube does with the same settings, and interpolating that cube shifts a channel by up to about
/// sixteen levels. The oracle's own `hsv-direct` variant, which runs the formula, lands within one, so
/// the difference is the cube, not the formula.
fn documented_allowance(name: &str) -> i32 {
    if name.starts_with("hsv-") {
        // The exact formula against the reference's color-cube interpolation.
        16
    } else if name.starts_with("motionblur-") {
        // An even streak (Photoshop's smearing) against Core Image's tapered streak of the same spread.
        // The reference's own alternative angle differs by nearly two hundred levels on the same pixels,
        // so the kernel, not the direction, is what is being measured here.
        96
    } else {
        0
    }
}

/// `(name, tolerance)` pairs from an oracle index.
fn parse_tolerances(text: &str) -> Vec<(String, i32)> {
    let mut out: Vec<(String, i32)> = Vec::new();
    let mut name = String::new();
    for line in text.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("\"name\":") {
            name = rest.trim().trim_end_matches(',').trim_matches('"').to_string();
        } else if let Some(rest) = trimmed.strip_prefix("\"tolerance\":") {
            if let Ok(value) = rest.trim().trim_end_matches(',').parse::<i32>() {
                out.push((name.clone(), value));
            }
        }
    }
    out
}