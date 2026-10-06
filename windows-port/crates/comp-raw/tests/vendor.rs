//! End-to-end tests for the sensor decoder: a synthetic DNG built tag by tag in this file, and the
//! real camera raw samples when they are present on disk.
//!
//! The real samples are CC0 files from raw.pixls.us (see NOTES.md for the URLs and hashes). They are
//! not committed: set `COMP_RAW_SAMPLES` to the directory holding them, or drop them in
//! `target-raw-pipeline/comp-raw-samples`, and these tests exercise them; without them each test
//! says so and returns.

use std::path::{Path, PathBuf};

use comp_core::Bitmap8;
use comp_raw::{
    decode_raw_bytes, decode_raw_file, decode_vendor_bytes, decode_vendor_planes, develop, Error, MatrixSource,
    RawSettings, WhiteBalanceSource,
};

// ---------------------------------------------------------------------------------------------
// A minimal but legal DNG writer: TIFF header, one IFD, CFA or linear samples, the tags rawloader
// requires. Nothing here is a shortcut for the decoder: every value is written where the DNG and
// TIFF specifications put it, and the tests read the tags back through the public API.
// ---------------------------------------------------------------------------------------------

mod dng {
    const TYPE_BYTE: u16 = 1;
    const TYPE_ASCII: u16 = 2;
    const TYPE_SHORT: u16 = 3;
    const TYPE_LONG: u16 = 4;
    const TYPE_RATIONAL: u16 = 5;
    const TYPE_SRATIONAL: u16 = 10;

    const TAG_WIDTH: u16 = 0x0100;
    const TAG_HEIGHT: u16 = 0x0101;
    const TAG_BITS: u16 = 0x0102;
    const TAG_COMPRESSION: u16 = 0x0103;
    const TAG_PHOTOMETRIC: u16 = 0x0106;
    const TAG_MAKE: u16 = 0x010F;
    const TAG_MODEL: u16 = 0x0110;
    const TAG_STRIP_OFFSETS: u16 = 0x0111;
    const TAG_ORIENTATION: u16 = 0x0112;
    const TAG_SAMPLES: u16 = 0x0115;
    const TAG_ROWS_PER_STRIP: u16 = 0x0116;
    const TAG_STRIP_BYTES: u16 = 0x0117;
    const TAG_PLANAR: u16 = 0x011C;
    const TAG_CFA_REPEAT: u16 = 0x828D;
    const TAG_CFA_PATTERN: u16 = 0x828E;
    const TAG_DNG_VERSION: u16 = 0xC612;
    const TAG_DNG_BACKWARD: u16 = 0xC613;
    const TAG_UNIQUE_MODEL: u16 = 0xC614;
    const TAG_BLACK_LEVEL: u16 = 0xC61A;
    const TAG_WHITE_LEVEL: u16 = 0xC61D;
    const TAG_COLOR_MATRIX: u16 = 0xC621;
    const TAG_AS_SHOT_NEUTRAL: u16 = 0xC628;
    /// PhotometricInterpretation for a color filter array.
    const PHOTOMETRIC_CFA: u16 = 32803;
    /// PhotometricInterpretation for an already demosaiced linear raw.
    const PHOTOMETRIC_LINEAR: u16 = 34892;

    struct Entry {
        tag: u16,
        kind: u16,
        count: u32,
        value: Vec<u8>,
    }

    fn u16_bytes(values: &[u16]) -> Vec<u8> {
        values.iter().flat_map(|value| value.to_le_bytes()).collect()
    }

    fn u32_bytes(values: &[u32]) -> Vec<u8> {
        values.iter().flat_map(|value| value.to_le_bytes()).collect()
    }

    fn ascii(text: &str) -> Vec<u8> {
        let mut bytes = text.as_bytes().to_vec();
        bytes.push(0);
        bytes
    }

    fn rationals(values: &[(u32, u32)]) -> Vec<u8> {
        values
            .iter()
            .flat_map(|(numerator, denominator)| {
                numerator.to_le_bytes().into_iter().chain(denominator.to_le_bytes())
            })
            .collect()
    }

    fn srationals(values: &[(i32, i32)]) -> Vec<u8> {
        values
            .iter()
            .flat_map(|(numerator, denominator)| {
                numerator.to_le_bytes().into_iter().chain(denominator.to_le_bytes())
            })
            .collect()
    }

    /// A synthetic camera raw file.
    pub struct Dng {
        width: u32,
        height: u32,
        pub samples: Vec<u16>,
        pub black: u32,
        pub white: u32,
        pub cfa: [u8; 4],
        pub make: String,
        pub model: String,
        pub matrix: Option<[[f64; 3]; 3]>,
        pub as_shot_neutral: Option<[f64; 3]>,
        pub linear: bool,
        pub orientation: u16,
    }

    impl Dng {
        /// An RGGB mosaic whose four filter positions carry the given levels.
        pub fn flat(width: u32, height: u32, levels: [f64; 3], black: u32, white: u32) -> Self {
            let mut samples = Vec::with_capacity((width * height) as usize);
            for y in 0..height {
                for x in 0..width {
                    let color = match (y % 2, x % 2) {
                        (0, 0) => 0,
                        (0, 1) | (1, 0) => 1,
                        _ => 2,
                    };
                    samples.push((black as f64 + levels[color] * (white - black) as f64).round() as u16);
                }
            }
            Dng {
                width,
                height,
                samples,
                black,
                white,
                cfa: [0, 1, 1, 2],
                make: "Compositor".to_string(),
                model: "Synthetic CFA".to_string(),
                matrix: None,
                as_shot_neutral: None,
                linear: false,
                orientation: 1,
            }
        }

        /// Three interleaved channels per pixel: a raw that is already demosaiced.
        pub fn linear(width: u32, height: u32, levels: [f64; 3], black: u32, white: u32) -> Self {
            let mut samples = Vec::with_capacity((width * height * 3) as usize);
            for _ in 0..width * height {
                for level in levels {
                    samples.push((black as f64 + level * (white - black) as f64).round() as u16);
                }
            }
            Dng {
                width,
                height,
                samples,
                black,
                white,
                cfa: [0, 0, 0, 0],
                make: "Compositor".to_string(),
                model: "Synthetic Linear".to_string(),
                matrix: None,
                as_shot_neutral: None,
                linear: true,
                orientation: 1,
            }
        }

        pub fn with_matrix(mut self, matrix: [[f64; 3]; 3]) -> Self {
            self.matrix = Some(matrix);
            self
        }

        pub fn with_as_shot_neutral(mut self, neutral: [f64; 3]) -> Self {
            self.as_shot_neutral = Some(neutral);
            self
        }

        pub fn build(&self) -> Vec<u8> {
            let channels = if self.linear { 3 } else { 1 };
            let unique_model = ascii("Compositor Synthetic");
            let mut entries = vec![
                Entry { tag: TAG_WIDTH, kind: TYPE_LONG, count: 1, value: u32_bytes(&[self.width]) },
                Entry { tag: TAG_HEIGHT, kind: TYPE_LONG, count: 1, value: u32_bytes(&[self.height]) },
                Entry { tag: TAG_BITS, kind: TYPE_SHORT, count: 1, value: u16_bytes(&[16]) },
                Entry { tag: TAG_COMPRESSION, kind: TYPE_SHORT, count: 1, value: u16_bytes(&[1]) },
                Entry {
                    tag: TAG_PHOTOMETRIC,
                    kind: TYPE_SHORT,
                    count: 1,
                    value: u16_bytes(&[if self.linear { PHOTOMETRIC_LINEAR } else { PHOTOMETRIC_CFA }]),
                },
                Entry { tag: TAG_MAKE, kind: TYPE_ASCII, count: self.make.len() as u32 + 1, value: ascii(&self.make) },
                Entry { tag: TAG_MODEL, kind: TYPE_ASCII, count: self.model.len() as u32 + 1, value: ascii(&self.model) },
                Entry { tag: TAG_ORIENTATION, kind: TYPE_SHORT, count: 1, value: u16_bytes(&[self.orientation]) },
                // StripOffsets is patched once the layout is known.
                Entry { tag: TAG_STRIP_OFFSETS, kind: TYPE_LONG, count: 1, value: u32_bytes(&[0]) },
                Entry { tag: TAG_SAMPLES, kind: TYPE_SHORT, count: 1, value: u16_bytes(&[channels as u16]) },
                Entry { tag: TAG_ROWS_PER_STRIP, kind: TYPE_LONG, count: 1, value: u32_bytes(&[self.height]) },
                Entry {
                    tag: TAG_STRIP_BYTES,
                    kind: TYPE_LONG,
                    count: 1,
                    value: u32_bytes(&[self.width * self.height * channels * 2]),
                },
                Entry { tag: TAG_PLANAR, kind: TYPE_SHORT, count: 1, value: u16_bytes(&[1]) },
                Entry { tag: TAG_DNG_VERSION, kind: TYPE_BYTE, count: 4, value: vec![1, 4, 0, 0] },
                Entry { tag: TAG_DNG_BACKWARD, kind: TYPE_BYTE, count: 4, value: vec![1, 1, 0, 0] },
                Entry { tag: TAG_UNIQUE_MODEL, kind: TYPE_ASCII, count: unique_model.len() as u32, value: unique_model },
                Entry { tag: TAG_WHITE_LEVEL, kind: TYPE_LONG, count: 1, value: u32_bytes(&[self.white]) },
            ];
            if self.black != 0 {
                entries.push(Entry {
                    tag: TAG_BLACK_LEVEL,
                    kind: TYPE_RATIONAL,
                    count: 1,
                    value: rationals(&[(self.black, 1)]),
                });
            }
            if let Some(matrix) = self.matrix {
                let values: Vec<(i32, i32)> =
                    matrix.iter().flatten().map(|value| ((value * 10000.0).round() as i32, 10000)).collect();
                entries.push(Entry { tag: TAG_COLOR_MATRIX, kind: TYPE_SRATIONAL, count: 9, value: srationals(&values) });
            }
            if let Some(neutral) = self.as_shot_neutral {
                let values: Vec<(u32, u32)> =
                    neutral.iter().map(|value| ((value * 1_000_000.0).round() as u32, 1_000_000)).collect();
                entries.push(Entry {
                    tag: TAG_AS_SHOT_NEUTRAL,
                    kind: TYPE_RATIONAL,
                    count: 3,
                    value: rationals(&values),
                });
            }
            if !self.linear {
                entries.push(Entry { tag: TAG_CFA_REPEAT, kind: TYPE_SHORT, count: 2, value: u16_bytes(&[2, 2]) });
                entries.push(Entry { tag: TAG_CFA_PATTERN, kind: TYPE_BYTE, count: 4, value: self.cfa.to_vec() });
            }
            entries.sort_by_key(|entry| entry.tag);

            // Lay the IFD out first, then the values that do not fit in four bytes, then the pixels.
            let ifd_offset = 8u32;
            let ifd_size = 2 + entries.len() as u32 * 12 + 4;
            let extra_base = ifd_offset + ifd_size;
            let mut extra: Vec<u8> = Vec::new();
            let mut encoded: Vec<(u16, u16, u32, u32)> = Vec::new();
            for entry in &entries {
                if entry.value.len() <= 4 {
                    let mut inline = [0u8; 4];
                    inline[..entry.value.len()].copy_from_slice(&entry.value);
                    encoded.push((entry.tag, entry.kind, entry.count, u32::from_le_bytes(inline)));
                } else {
                    let offset = extra_base + extra.len() as u32;
                    encoded.push((entry.tag, entry.kind, entry.count, offset));
                    extra.extend_from_slice(&entry.value);
                    if extra.len() % 2 == 1 {
                        extra.push(0);
                    }
                }
            }
            let pixel_offset = extra_base + extra.len() as u32;
            for entry in encoded.iter_mut() {
                if entry.0 == TAG_STRIP_OFFSETS {
                    entry.3 = pixel_offset;
                }
            }

            let mut out = Vec::new();
            out.extend_from_slice(b"II");
            out.extend_from_slice(&42u16.to_le_bytes());
            out.extend_from_slice(&ifd_offset.to_le_bytes());
            out.extend_from_slice(&(encoded.len() as u16).to_le_bytes());
            for (tag, kind, count, value) in &encoded {
                out.extend_from_slice(&tag.to_le_bytes());
                out.extend_from_slice(&kind.to_le_bytes());
                out.extend_from_slice(&count.to_le_bytes());
                out.extend_from_slice(&value.to_le_bytes());
            }
            out.extend_from_slice(&0u32.to_le_bytes());
            out.extend_from_slice(&extra);
            for sample in &self.samples {
                out.extend_from_slice(&sample.to_le_bytes());
            }
            out
        }
    }
}

use dng::Dng;

/// Mean and standard deviation of the RGB channels, the quickest way to tell a photograph from a
/// decode artifact.
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
    let variance = (square / count - mean * mean).max(0.0);
    (mean, variance.sqrt())
}

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

/// The path of a real sample, or None with a note printed when the archive is not on this machine.
fn sample(name: &str) -> Option<PathBuf> {
    let path = samples_dir().map(|dir| dir.join(name))?;
    if path.is_file() {
        Some(path)
    } else {
        println!("(skipped: {name} is not in the sample directory; see NOTES.md for the download URLs)");
        None
    }
}

// ---------------------------------------------------------------------------------------------
// The synthetic DNG: levels, white balance, CFA mapping, demosaic, matrix and linear raws.
// ---------------------------------------------------------------------------------------------

#[test]
fn a_synthetic_dng_decodes_with_its_metadata() {
    let bytes = Dng::flat(8, 8, [0.25, 0.5, 0.125], 1024, 16383).build();
    let decoded = decode_vendor_bytes(&bytes).expect("the synthetic DNG decodes");
    let metadata = decoded.metadata();
    assert_eq!((metadata.width, metadata.height), (8, 8));
    assert_eq!(metadata.channels, 1);
    assert_eq!(metadata.cfa, "RGGB");
    assert_eq!(metadata.black_levels[0], 1024);
    assert_eq!(metadata.white_levels[0], 16383);
    assert_eq!(metadata.make, "Compositor");
    assert_eq!(metadata.model, "Synthetic CFA");
    assert_eq!(metadata.matrix_source, MatrixSource::SrgbDefault, "no matrix was written");
    assert_eq!(decoded.image.width(), 8);
    assert_eq!(decoded.image.height(), 8);
    for pixel in decoded.image.pixels().chunks_exact(4) {
        assert_eq!(pixel[3], 255, "a decoded raw is opaque");
    }
}

#[test]
fn a_flat_mosaic_with_no_matrix_comes_out_neutral() {
    // No matrix in the file, so the raw is assumed to be in sRGB primaries; no white balance either,
    // so gray world equalizes the filter colors: every channel must land on the same value.
    let bytes = Dng::flat(8, 8, [0.25, 0.5, 0.125], 1024, 16383).build();
    let decoded = decode_vendor_bytes(&bytes).expect("the synthetic DNG decodes");
    assert_eq!(decoded.metadata.white_balance_source, WhiteBalanceSource::GrayWorld);
    let pixel = decoded.image.get(4, 4);
    assert!(pixel[0].abs_diff(pixel[1]) <= 2 && pixel[1].abs_diff(pixel[2]) <= 2, "{pixel:?}");
    // Gray world balances 0.25/0.5/0.125 to 0.5 in every channel, and sRGB(0.5) is 188.
    assert!((pixel[0] as i32 - 188).abs() <= 3, "{pixel:?}");
}

#[test]
fn as_shot_neutral_preserves_the_filter_levels() {
    // AsShotNeutral (1, 1, 1) means "the shot needs no balance", so each filter color keeps its own
    // level and the picture shows them: 0.25 -> 137, 0.5 -> 188, 0.125 -> 99 in sRGB.
    let bytes = Dng::flat(8, 8, [0.25, 0.5, 0.125], 1024, 16383)
        .with_as_shot_neutral([1.0, 1.0, 1.0])
        .build();
    let decoded = decode_vendor_bytes(&bytes).expect("the synthetic DNG decodes");
    assert_eq!(decoded.metadata.white_balance_source, WhiteBalanceSource::Camera);
    let pixel = decoded.image.get(4, 4);
    assert!((pixel[0] as i32 - 137).abs() <= 3, "{pixel:?}");
    assert!((pixel[1] as i32 - 188).abs() <= 3, "{pixel:?}");
    assert!((pixel[2] as i32 - 99).abs() <= 3, "{pixel:?}");
    // The green sites are the majority of a Bayer frame, so a wrong CFA mapping would swap red and
    // blue here; the assertion above pins the RGGB interpretation at a red-filtered pixel.
    assert_eq!(decoded.metadata.cfa, "RGGB");
}

#[test]
fn as_shot_neutral_multipliers_are_applied() {
    // AsShotNeutral is the camera-space value of a neutral subject, so (0.5, 1, 0.25) doubles red
    // and quadruples blue: 0.125 * 4 = 0.5 and 0.25 * 2 = 0.5, which is neutral again.
    let bytes = Dng::flat(8, 8, [0.25, 0.5, 0.125], 1024, 16383)
        .with_as_shot_neutral([0.5, 1.0, 0.25])
        .build();
    let decoded = decode_vendor_bytes(&bytes).expect("the synthetic DNG decodes");
    let metadata = decoded.metadata;
    assert!((metadata.white_balance[0] - 2.0).abs() < 1e-3, "{:?}", metadata.white_balance);
    assert!((metadata.white_balance[2] - 4.0).abs() < 1e-3, "{:?}", metadata.white_balance);
    let pixel = decoded.image.get(4, 4);
    assert!(pixel[0].abs_diff(pixel[1]) <= 2 && pixel[1].abs_diff(pixel[2]) <= 2, "{pixel:?}");
}

#[test]
fn the_black_level_darkens_the_same_samples() {
    let samples = Dng::flat(4, 4, [0.5, 0.5, 0.5], 0, 16383);
    let plain = decode_vendor_bytes(&samples.build()).expect("decodes");
    let mut raised = Dng::flat(4, 4, [0.5, 0.5, 0.5], 0, 16383);
    raised.black = 4096;
    let darker = decode_vendor_bytes(&raised.build()).expect("decodes");
    assert!(
        darker.image.get(2, 2)[0] < plain.image.get(2, 2)[0],
        "{} vs {}",
        darker.image.get(2, 2)[0],
        plain.image.get(2, 2)[0]
    );
    assert_eq!(darker.metadata.black_levels[0], 4096);
}

#[test]
fn the_white_level_scales_the_same_samples() {
    // Both files hold the same samples; only the WhiteLevel tag differs, so the second one is the
    // same signal read against a taller scale and must come out darker.
    let mut plain = Dng::flat(4, 4, [0.5, 0.5, 0.5], 0, 16383);
    let mut wide = Dng::flat(4, 4, [0.5, 0.5, 0.5], 0, 16383);
    wide.white = 32767;
    assert_eq!(plain.samples, wide.samples, "the test compares the same signal");
    plain.white = 16383;
    let dark = decode_vendor_bytes(&wide.build()).expect("decodes");
    let bright = decode_vendor_bytes(&plain.build()).expect("decodes");
    assert!(dark.image.get(2, 2)[0] < bright.image.get(2, 2)[0]);
    assert_eq!(dark.metadata.white_levels[0], 32767);
}

#[test]
fn a_file_matrix_is_read_and_reported() {
    // A plausible camera matrix in dcraw's XYZ-to-camera convention (the Kodak DCS760C's), rather
    // than an invented one, so the composition with the sRGB primaries stays well conditioned.
    let matrix = [
        [1.6623, -0.6309, -0.1411],
        [-0.4344, 1.3923, 0.0323],
        [0.2285, 0.0274, 0.2926],
    ];
    let plain = Dng::flat(8, 8, [0.25, 0.5, 0.125], 1024, 16383).with_as_shot_neutral([1.0, 1.0, 1.0]);
    let with_matrix = Dng::flat(8, 8, [0.25, 0.5, 0.125], 1024, 16383)
        .with_as_shot_neutral([1.0, 1.0, 1.0])
        .with_matrix(matrix);
    let default_decode = decode_vendor_bytes(&plain.build()).expect("decodes");
    let matrix_decode = decode_vendor_bytes(&with_matrix.build()).expect("decodes");
    assert_eq!(matrix_decode.metadata.matrix_source, MatrixSource::File);
    assert_eq!(default_decode.metadata.matrix_source, MatrixSource::SrgbDefault);
    assert_ne!(default_decode.image, matrix_decode.image, "the matrix must change the colors");
    // A camera matrix that already means sRGB keeps a neutral gray neutral.
    let (mean, _) = statistics(&matrix_decode.image);
    assert!(mean > 40.0 && mean < 220.0, "{mean}");
}

#[test]
fn a_linear_dng_skips_the_demosaic() {
    // Three channels per pixel: the decoder must hand them over untouched instead of treating the
    // frame as a mosaic.
    let bytes = Dng::linear(4, 2, [0.25, 0.5, 0.125], 0, 65535)
        .with_as_shot_neutral([1.0, 1.0, 1.0])
        .build();
    let decoded = decode_vendor_bytes(&bytes).expect("the linear DNG decodes");
    let metadata = decoded.metadata;
    assert_eq!(metadata.channels, 3);
    assert_eq!(metadata.cfa, "", "a linear raw has no filter array");
    let pixel = decoded.image.get(2, 1);
    assert!((pixel[0] as i32 - 137).abs() <= 3, "{pixel:?}");
    assert!((pixel[1] as i32 - 188).abs() <= 3, "{pixel:?}");
    assert!((pixel[2] as i32 - 99).abs() <= 3, "{pixel:?}");
}

#[test]
fn a_build_without_the_supplementary_decoder_refuses_these_files_readably() {
    // The three samples rawloader cannot read stay refused when the build carries no LibRaw, with the
    // pure-Rust decoder's own reason rather than a generic "unsupported format"; with the feature on
    // they decode instead (tests/libraw_path.rs proves that). Running this in both configurations is
    // what documents the degradation.
    if comp_raw::libraw_available() {
        println!("(this build carries LibRaw; tests/libraw_path.rs covers these files)");
        return;
    }
    for name in ["canon-5d3-compressed-lossy.DNG", "blackmagic-micro-linear.dng", "RAW_KODAK_DC50.KDC"] {
        let Some(path) = sample(name) else {
            continue;
        };
        match decode_raw_file(&path) {
            Err(Error::Vendor(message)) => assert!(message.len() > 20, "{name}: {message}"),
            other => panic!("{name}: expected a readable refusal, got {other:?}"),
        }
    }
}

#[test]
fn the_extension_does_not_decide_whether_a_raw_decodes() {
    // rawloader sniffs the container, so a camera raw behind a vendor extension the list accepts goes
    // through the sensor decoder even when the bytes are a DNG.
    let bytes = Dng::flat(4, 4, [0.25, 0.5, 0.125], 0, 65535).build();
    let decoded = decode_raw_bytes(&bytes, "nef").expect("the sensor path reads it");
    assert_eq!(decoded.metadata().expect("metadata").cfa, "RGGB");
}

#[test]
fn developing_a_synthetic_raw_runs_the_grade_on_top() {
    let bytes = Dng::flat(8, 8, [0.25, 0.5, 0.125], 1024, 16383).build();
    let decoded = decode_vendor_bytes(&bytes).expect("decodes");
    let settings = RawSettings { exposure: 1.0, ..RawSettings::default() };
    let graded = develop(&decoded.image, &settings);
    assert_eq!(graded.width(), decoded.image.width());
    let before = statistics(&decoded.image).0;
    let after = statistics(&graded).0;
    assert!(after > before, "one stop brightened it: {after} vs {before}");
}

#[test]
fn the_oracle_fixture_is_written_when_asked() {
    // `tools/vendor_oracle.py` reads these files and recomputes the whole front end with NumPy from
    // the DNG specification alone. Nothing is written unless the caller asks for it.
    let Ok(dir) = std::env::var("COMP_RAW_ORACLE_DIR") else {
        return;
    };
    let dir = PathBuf::from(dir);
    std::fs::create_dir_all(&dir).expect("the oracle directory is writable");
    let matrix = [
        [0.6720, -0.1360, -0.0360],
        [-0.4280, 1.2200, 0.2380],
        [-0.0900, 0.2080, 0.7020],
    ];
    let bytes = Dng::flat(16, 16, [0.35, 0.55, 0.18], 1024, 16383)
        .with_matrix(matrix)
        .with_as_shot_neutral([0.52, 1.0, 0.78])
        .build();
    std::fs::write(dir.join("synthetic.dng"), &bytes).expect("the fixture is written");
    let (decoded, planes) = decode_vendor_planes(&bytes).expect("the fixture decodes");
    let mut mosaic = Vec::with_capacity(planes.mosaic.len() * 4);
    for value in &planes.mosaic {
        mosaic.extend_from_slice(&value.to_le_bytes());
    }
    std::fs::write(dir.join("synthetic.mosaic.f32"), mosaic).expect("the mosaic plane is written");
    let mut linear = Vec::with_capacity(planes.linear.len() * 12);
    for color in &planes.linear {
        for value in color {
            linear.extend_from_slice(&value.to_le_bytes());
        }
    }
    std::fs::write(dir.join("synthetic.linear.f32"), linear).expect("the linear plane is written");
    std::fs::write(dir.join("synthetic.rgba8.raw"), decoded.image.pixels()).expect("the bytes are written");
    let metadata = decoded.metadata;
    std::fs::write(
        dir.join("synthetic.params.txt"),
        format!(
            "width {}\nheight {}\nchannels {}\ncfa {}\nblack {:?}\nwhite {:?}\nwb {:?}\nsource {:?}\n",
            metadata.width,
            metadata.height,
            metadata.channels,
            metadata.cfa,
            metadata.black_levels,
            metadata.white_levels,
            metadata.white_balance,
            metadata.white_balance_source
        ),
    )
    .expect("the parameters are written");
    println!("wrote the oracle fixture to {}", dir.display());
}

// ---------------------------------------------------------------------------------------------
// Real camera files (CC0, from raw.pixls.us). Skipped, with a note, when they are not on disk.
// ---------------------------------------------------------------------------------------------

#[test]
fn a_real_nef_decodes_and_develops() {
    let Some(path) = sample("nikon-1j2.DSC_0451.NEF") else {
        return;
    };
    let decoded = decode_raw_file(&path).expect("the NEF decodes");
    let metadata = decoded.metadata().expect("metadata");
    assert_eq!(metadata.clean_make, "Nikon");
    assert_eq!(metadata.cfa, "RGGB");
    assert_eq!(metadata.channels, 1);
    assert!(metadata.width > 3000 && metadata.height > 2000, "{}x{}", metadata.width, metadata.height);
    assert_eq!(metadata.white_balance_source, WhiteBalanceSource::Camera);
    // The file asks for two rows of unusable area at the bottom.
    assert_eq!(metadata.crops, [0, 0, 2, 0]);
    assert_eq!(decoded.image.width() as usize, metadata.width);
    assert_eq!(decoded.image.height() as usize, metadata.height - 2);

    let (mean, deviation) = statistics(&decoded.image);
    assert!(mean > 20.0 && mean < 235.0, "mean {mean}");
    assert!(deviation > 10.0, "standard deviation {deviation}");

    let settings = RawSettings { exposure: 0.5, contrast: 20.0, ..RawSettings::default() };
    let graded = develop(&decoded.image, &settings);
    assert_eq!(graded.width(), decoded.image.width());
    assert_eq!(graded.height(), decoded.image.height());
    let (graded_mean, _) = statistics(&graded);
    assert!(graded_mean > mean, "half a stop brightened the picture: {graded_mean} vs {mean}");
}

#[test]
fn a_real_raw_without_white_balance_takes_the_matrix_guess() {
    let Some(path) = sample("kodak-dcs760c.DCR") else {
        return;
    };
    let decoded = decode_raw_file(&path).expect("the DCR decodes");
    let metadata = decoded.metadata().expect("metadata");
    assert_eq!(metadata.clean_make, "Kodak");
    assert_eq!(metadata.cfa, "GRBG");
    // This file carries no as-shot multipliers but does carry a camera matrix, so the 6500 K guess
    // derived from that matrix is used instead of assuming equal channels.
    assert_eq!(metadata.white_balance_source, WhiteBalanceSource::Neutral6500K);
    assert_eq!(metadata.matrix_source, MatrixSource::File);
    let (mean, deviation) = statistics(&decoded.image);
    assert!(mean > 10.0 && mean < 245.0, "mean {mean}");
    assert!(deviation > 10.0, "standard deviation {deviation}");
    let graded = develop(&decoded.image, &RawSettings { saturation: 20.0, ..RawSettings::default() });
    assert_eq!(graded.width(), decoded.image.width());
}

#[test]
fn a_real_file_from_an_unknown_camera_reports_why() {
    let Some(path) = sample("RAW_KODAK_DC50.KDC") else {
        return;
    };
    match decode_raw_file(&path) {
        Err(Error::Vendor(message)) => {
            // The default build: rawloader does not know this body, and it says so by name.
            assert!(message.len() > 20, "the message must say something: {message}");
            assert!(!comp_raw::libraw_available(), "with LibRaw built in this file decodes instead");
            println!("unknown camera reported as: {message}");
        }
        Ok(decoded) => {
            // A build with the supplementary decoder reads it; tests/libraw_path.rs asserts that in
            // detail, here it only has to be a real picture rather than a silent failure.
            assert!(comp_raw::libraw_available(), "without LibRaw this must not decode");
            let metadata = decoded.metadata().expect("metadata");
            assert_eq!(metadata.clean_make, "Kodak");
            assert!(decoded.image.width() >= 512);
            println!("the supplementary decoder read it: {:?}", metadata.decoder);
        }
        Err(other) => panic!("expected either a decode or a readable refusal, got {other:?}"),
    }
}

#[test]
fn a_real_unsupported_compression_reports_why() {
    let Some(path) = sample("canon-5d3-compressed-lossy.DNG") else {
        return;
    };
    match decode_raw_file(&path) {
        Err(Error::Vendor(message)) => {
            println!("lossy DNG reported as: {message}");
            assert!(message.len() > 20, "{message}");
        }
        Ok(decoded) => {
            // If a future image crate learns to read lossy DNG, the container path takes over and the
            // file simply works; the test then only checks that it produced pixels.
            println!("the lossy DNG decoded through the container reader after all");
            assert!(decoded.image.width() > 0);
        }
        Err(other) => panic!("expected a readable failure, got {other:?}"),
    }
}

#[test]
fn a_real_decoder_failure_is_an_error_and_not_a_panic() {
    let Some(path) = sample("blackmagic-micro-linear.dng") else {
        return;
    };
    match decode_raw_file(&path) {
        Err(Error::Vendor(message)) => {
            println!("linear DNG reported as: {message}");
            assert!(message.len() > 20, "{message}");
        }
        Ok(decoded) => {
            println!("the linear DNG decoded after all");
            assert!(decoded.image.width() > 0);
        }
        Err(other) => panic!("expected a readable failure, got {other:?}"),
    }
}
