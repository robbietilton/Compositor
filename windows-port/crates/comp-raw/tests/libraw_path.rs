//! Tests for the supplementary LibRaw decoder.
//!
//! What this proves, in the order the routing promises it:
//!
//! 1. rawloader still answers first for every file it can read, so the supplementary decoder is never
//!    reached when it is not needed;
//! 2. the files rawloader refuses — a CR3 container, a DNG whose sensor data is lossy JPEG, a linear
//!    DNG that trips its decoder, and a camera body missing from its database — decode through LibRaw;
//! 3. the metadata says which engine answered, which decoder LibRaw used, and why the first choice
//!    did not;
//! 4. damaged input comes back as an error rather than a crash.
//!
//! The samples are CC0 files from raw.pixls.us; `tools/fetch-samples.ps1` downloads them with pinned
//! checksums. Each test that needs one prints a note and returns when it is absent.
#![cfg(feature = "libraw")]

use std::path::{Path, PathBuf};

use comp_core::Bitmap8;
use comp_raw::{
    decode_raw_bytes, decode_raw_file, develop, develop_file, libraw_available, libraw_version, Error, MatrixSource,
    RawSettings, SensorEngine, WhiteBalanceSource,
};

fn samples_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("COMP_RAW_SAMPLES") {
        let path = PathBuf::from(dir);
        if path.is_dir() {
            return Some(path);
        }
    }
    let fallback = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target-raw-pipeline/comp-raw-samples");
    if fallback.is_dir() {
        Some(fallback)
    } else {
        None
    }
}

fn sample(name: &str) -> Option<PathBuf> {
    let path = samples_dir().map(|dir| dir.join(name))?;
    if path.is_file() {
        Some(path)
    } else {
        println!("(skipped: {name} is not in the sample directory; run tools/fetch-samples.ps1)");
        None
    }
}

fn statistics(image: &Bitmap8) -> (f64, f64) {
    let mut sum = 0.0;
    let mut square = 0.0;
    let mut count = 0.0;
    for pixel in image.pixels().chunks_exact(4) {
        for channel in 0..3 {
            let value = pixel[channel] as f64;
            sum += value;
            square += value * value;
            count += 1.0;
        }
    }
    let mean = sum / count;
    (mean, (square / count - mean * mean).max(0.0).sqrt())
}

fn decoded(path: &Path) -> (Bitmap8, comp_raw::RawMetadata) {
    let decoded = decode_raw_file(path).expect("the file decodes");
    let metadata = decoded.metadata().expect("a sensor decoder answered").clone();
    (decoded.image, metadata)
}

#[test]
fn the_supplementary_decoder_reports_its_version() {
    assert!(libraw_available(), "this test only builds with the libraw feature");
    let version = libraw_version();
    assert!(version.starts_with("0.21"), "unexpected LibRaw version {version:?}");
}

#[test]
fn rawloader_still_answers_first_for_the_files_it_can_read() {
    // The whole point of the routing: the pure-Rust decoder keeps its files, and the supplementary one
    // is never reached for them.
    for (name, make) in [("nikon-1j2.DSC_0451.NEF", "Nikon"), ("kodak-dcs760c.DCR", "Kodak")] {
        let Some(path) = sample(name) else {
            continue;
        };
        let (image, metadata) = decoded(&path);
        assert_eq!(metadata.engine, SensorEngine::Rawloader, "{name}");
        assert!(metadata.fallback_reason.is_none(), "{name} should not have needed a fallback");
        assert!(metadata.decoder.is_empty(), "rawloader does not name its decoder");
        assert_eq!(metadata.clean_make, make);
        assert!(image.width() > 1000 && image.height() > 1000);
    }
}

#[test]
fn the_cr3_container_decodes_with_libraw() {
    let Some(path) = sample("canon-eos-r6-craw.CR3") else {
        return;
    };
    let (image, metadata) = decoded(&path);
    assert_eq!(metadata.engine, SensorEngine::LibRaw);
    assert_eq!(metadata.clean_make, "Canon");
    assert!(metadata.decoder.to_lowercase().contains("crx"), "decoder was {:?}", metadata.decoder);
    let reason = metadata.fallback_reason.expect("the pure-Rust decoder refused it");
    assert!(
        reason.contains("Couldn't find a decoder") || reason.contains("decoder for this file"),
        "{reason}"
    );
    assert!(image.width() > 2000 && image.height() > 1000, "{}x{}", image.width(), image.height());
    let (mean, deviation) = statistics(&image);
    assert!(mean > 10.0 && mean < 245.0, "mean {mean}");
    assert!(deviation > 10.0, "deviation {deviation}");
}

#[test]
fn the_lossy_dng_decodes_with_libraw() {
    let Some(path) = sample("canon-5d3-compressed-lossy.DNG") else {
        return;
    };
    let (image, metadata) = decoded(&path);
    assert_eq!(metadata.engine, SensorEngine::LibRaw);
    assert!(metadata.decoder.contains("lossy_dng"), "decoder was {:?}", metadata.decoder);
    let reason = metadata.fallback_reason.expect("rawloader refuses lossy DNG");
    assert!(reason.contains("34892"), "{reason}");
    assert_eq!(metadata.white_balance_source, WhiteBalanceSource::Camera);
    assert_eq!(metadata.matrix_source, MatrixSource::File);
    assert_eq!(metadata.channels, 3, "LibRaw hands back a developed image");
    assert!(image.width() > 3000, "{}x{}", image.width(), image.height());
}

#[test]
fn the_linear_dng_that_trips_rawloader_decodes_with_libraw() {
    let Some(path) = sample("blackmagic-micro-linear.dng") else {
        return;
    };
    let (image, metadata) = decoded(&path);
    assert_eq!(metadata.engine, SensorEngine::LibRaw);
    assert!(metadata.decoder.contains("dng"), "decoder was {:?}", metadata.decoder);
    let reason = metadata.fallback_reason.expect("rawloader panics on this one");
    assert!(reason.contains("panic") || reason.contains("Panic"), "{reason}");
    assert!(image.width() > 500 && image.height() > 500, "{}x{}", image.width(), image.height());
}

#[test]
fn the_camera_rawloader_does_not_know_decodes_with_libraw() {
    let Some(path) = sample("RAW_KODAK_DC50.KDC") else {
        return;
    };
    let (image, metadata) = decoded(&path);
    assert_eq!(metadata.engine, SensorEngine::LibRaw);
    assert!(metadata.decoder.contains("kodak"), "decoder was {:?}", metadata.decoder);
    let reason = metadata.fallback_reason.expect("rawloader does not know this body");
    assert!(reason.contains("Couldn't find camera"), "{reason}");
    assert_eq!(metadata.clean_make, "Kodak");
    assert!(image.width() >= 512, "{}x{}", image.width(), image.height());
}

#[test]
fn the_metadata_says_who_decoded_and_why() {
    let Some(path) = sample("canon-5d3-compressed-lossy.DNG") else {
        return;
    };
    let (_, metadata) = decoded(&path);
    // Everything the caller needs to explain a surprising develop: who, with what, and what the first
    // choice said.
    assert_eq!(metadata.engine, SensorEngine::LibRaw);
    assert!(!metadata.decoder.is_empty());
    assert!(metadata.fallback_reason.is_some());
    assert!(metadata.width > 0 && metadata.height > 0);
    assert!(metadata.white_balance.iter().take(3).all(|value| value.is_finite() && *value > 0.0));
}

#[test]
fn a_libraw_image_runs_through_the_grade() {
    let Some(path) = sample("canon-5d3-compressed-lossy.DNG") else {
        return;
    };
    let (image, _) = decoded(&path);
    let (before, _) = statistics(&image);
    let settings = RawSettings { exposure: 1.0, contrast: 15.0, ..RawSettings::default() };
    let graded = develop(&image, &settings);
    assert_eq!((graded.width(), graded.height()), (image.width(), image.height()));
    let (after, _) = statistics(&graded);
    assert!(after > before, "one stop brightened it: {after} vs {before}");
}

#[test]
fn develop_file_handles_a_cr3_end_to_end() {
    let Some(path) = sample("canon-eos-r6-craw.CR3") else {
        return;
    };
    let settings = RawSettings { exposure: 0.5, ..RawSettings::default() };
    let via_file = develop_file(&path, &settings).expect("the CR3 develops");
    let (image, _) = decoded(&path);
    assert_eq!(via_file, develop(&image, &settings), "both entry points agree");
    assert!(via_file.width() > 2000);
}

#[test]
fn decoding_the_same_file_twice_gives_the_same_bytes() {
    // The front end turns LibRaw's automatic brightness off on purpose, so a decode depends only on the
    // file and not on the picture's own histogram.
    let Some(path) = sample("canon-5d3-compressed-lossy.DNG") else {
        return;
    };
    let first = decode_raw_file(&path).expect("decodes").image;
    let second = decode_raw_file(&path).expect("decodes").image;
    assert_eq!(first, second);
}

#[test]
fn the_buffer_entry_point_reads_the_same_file() {
    // Callers that only have bytes (a download, a stream) get the same picture through LibRaw's buffer
    // datastream; the file entry point is preferred because it is LibRaw's native path.
    let Some(path) = sample("canon-5d3-compressed-lossy.DNG") else {
        return;
    };
    let bytes = std::fs::read(&path).expect("readable");
    let from_bytes = decode_raw_bytes(&bytes, "dng").expect("the buffer decodes");
    let from_file = decode_raw_file(&path).expect("the file decodes");
    assert_eq!(from_bytes.image, from_file.image);
    assert_eq!(from_bytes.metadata().expect("metadata").engine, SensorEngine::LibRaw);
}

#[test]
fn damaged_input_comes_back_as_an_error() {
    let Some(path) = sample("canon-5d3-compressed-lossy.DNG") else {
        return;
    };
    let bytes = std::fs::read(&path).expect("readable");
    for cut in [64usize, 4096, 200_000] {
        let truncated = &bytes[..cut.min(bytes.len())];
        match decode_raw_bytes(truncated, "dng") {
            Err(Error::Vendor(message)) => assert!(!message.is_empty(), "cut at {cut}"),
            Err(other) => panic!("cut at {cut}: expected a vendor error, got {other:?}"),
            Ok(_) => panic!("cut at {cut}: a truncated file must not decode"),
        }
    }
}
