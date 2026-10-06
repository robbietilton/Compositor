//! Imports files a second implementation wrote and compares the pixels with its own decode.
//!
//! The fixtures come from Pillow (see make_codec_fixtures.py), so a failure here means this crate
//! disagrees with an unrelated implementation of the same format, not with itself. The 16-bit PNG
//! is checked exactly, because the scaling is prescribed; the JPEGs are checked within a few levels,
//! because two decoders never agree bit for bit on a lossy file.
use std::fs;
use std::path::PathBuf;

use serde_json::Value;

use comp_io::codec::{decode_raster, ImportOptions};

struct Case {
    name: String,
    file: PathBuf,
    expected: Vec<u8>,
    width: u32,
    height: u32,
    tolerance: i32,
    note: String,
}

fn fixtures_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests").join("fixtures")
}

fn cases() -> Vec<Case> {
    let root = fixtures_root();
    let text = fs::read_to_string(root.join("index.json"))
        .unwrap_or_else(|_| panic!("missing {}; run tests/make_codec_fixtures.py", root.display()));
    let index: Value = serde_json::from_str(&text).expect("a fixture index");
    index["cases"]
        .as_array()
        .expect("a case list")
        .iter()
        .map(|case| Case {
            name: case["name"].as_str().unwrap().to_string(),
            file: root.join(case["file"].as_str().unwrap()),
            expected: fs::read(root.join(case["expected"].as_str().unwrap())).expect("the expected pixels"),
            width: case["width"].as_u64().unwrap() as u32,
            height: case["height"].as_u64().unwrap() as u32,
            tolerance: case["tolerance"].as_i64().unwrap() as i32,
            note: case["note"].as_str().unwrap().to_string(),
        })
        .collect()
}

/// The worst per-channel difference between the import and the reference decode.
fn worst_difference(case: &Case) -> i32 {
    let bytes = fs::read(&case.file).unwrap_or_else(|error| panic!("{}: {error}", case.file.display()));
    let raster = decode_raster(&bytes, &ImportOptions::default())
        .unwrap_or_else(|error| panic!("{} was refused: {error}", case.name));
    assert_eq!(
        (raster.image.width(), raster.image.height()),
        (case.width, case.height),
        "{} has the wrong size",
        case.name
    );
    assert_eq!(
        raster.image.pixels().len(),
        case.expected.len(),
        "{} has the wrong channel count",
        case.name
    );
    raster
        .image
        .pixels()
        .iter()
        .zip(case.expected.iter())
        .map(|(actual, expected)| (*actual as i32 - *expected as i32).abs())
        .max()
        .expect("pixels")
}

#[test]
fn every_reference_file_imports_within_its_tolerance() {
    let cases = cases();
    assert!(cases.len() >= 7, "the fixture set shrank to {} files", cases.len());
    for case in &cases {
        let worst = worst_difference(case);
        println!("{:<10} worst {worst:>3} levels  ({})", case.name, case.note);
        assert!(
            worst <= case.tolerance,
            "{} differs from Pillow by {worst} levels, tolerance {}",
            case.name,
            case.tolerance
        );
    }
}

#[test]
fn a_sixteen_bit_png_scales_exactly_as_pillow_does() {
    let case = cases().into_iter().find(|case| case.name == "png-gray16").expect("the 16-bit case");
    assert_eq!(case.tolerance, 0, "the 16-bit scale is prescribed, so it must be exact");
    assert_eq!(worst_difference(&case), 0);
}

#[test]
fn a_four_two_zero_jpeg_is_within_four_levels_of_pillow() {
    let case = cases().into_iter().find(|case| case.name == "jpeg-420").expect("the 4:2:0 case");
    let worst = worst_difference(&case);
    println!("4:2:0 chroma upsampling differs from Pillow by {worst} levels");
    assert!(worst <= 4, "4:2:0 chroma upsampling differs from Pillow by {worst} levels");
}

#[test]
fn the_other_chroma_samplings_do_not_regress() {
    for name in ["jpeg-444", "jpeg-422", "jpeg-gray"] {
        let case = cases().into_iter().find(|case| case.name == name).expect(name);
        let worst = worst_difference(&case);
        println!("{name} differs from Pillow by {worst} levels");
        assert!(worst <= case.tolerance, "{name} differs from Pillow by {worst} levels");
    }
}
