//! The raw entry points: a decoded buffer, a camera raw file, or a clear error.
//!
//! Two backends sit behind them. Sensor formats (everything from NEF to CFA DNGs) go through
//! `rawloader` in `crate::vendor`, which returns the mosaic plus the camera metadata; rendered
//! DNG/TIFF containers go through the `image` crate. A `.dng` is sensor data first and a TIFF
//! second, so that extension tries the sensor decoder first and falls back; a `.tif`/`.tiff` is
//! tried the other way around.

use std::path::Path;

use comp_core::Bitmap8;

use crate::error::{Error, Result};
use crate::settings::RawSettings;
use crate::vendor::{self, RawMetadata};

/// The containers the `image` crate reads here.
pub const SUPPORTED_CONTAINERS: [&str; 3] = ["dng", "tif", "tiff"];

/// Every camera raw extension `rawloader` is asked about. The list decides only which extensions are
/// accepted at all; the decoder itself sniffs the container, so a raw file with an unexpected
/// extension still decodes when it is passed in as bytes.
pub const VENDOR_RAW_EXTENSIONS: [&str; 30] = [
    "3fr", "ari", "arw", "bay", "cr2", "cr3", "crw", "dcr", "dcs", "drf", "eip", "erf", "fff", "iiq", "k25", "kdc",
    "mdc", "mef", "mos", "mrw", "nef", "nrw", "orf", "pef", "raf", "raw", "rw2", "rwl", "srw", "x3f",
];

/// Where a decoded image came from.
#[derive(Clone, Debug, PartialEq)]
pub enum RawSource {
    /// A sensor decoder read it — rawloader, or LibRaw when the build carries it and rawloader could
    /// not — and reported what the file said about the shot. `RawMetadata::engine` says which.
    Sensor(Box<RawMetadata>),
    /// The `image` crate read a rendered DNG or TIFF, which carries no sensor metadata.
    Container,
}

/// A decoded raw frame plus where it came from.
#[derive(Clone, Debug)]
pub struct DecodedImage {
    /// Straight-alpha RGBA, sRGB-encoded, ready for `crate::develop`.
    pub image: Bitmap8,
    pub source: RawSource,
}

impl DecodedImage {
    /// The sensor metadata, when a sensor decoder produced this image.
    pub fn metadata(&self) -> Option<&RawMetadata> {
        match &self.source {
            RawSource::Sensor(metadata) => Some(metadata),
            RawSource::Container => None,
        }
    }
}

/// True for the extensions that need a demosaic engine rather than the TIFF reader.
pub fn needs_demosaic_engine(extension: &str) -> bool {
    let extension = extension.trim_start_matches('.').to_ascii_lowercase();
    VENDOR_RAW_EXTENSIONS.contains(&extension.as_str())
}

/// Reads a raw file and decodes it.
pub fn decode_raw_file(path: &Path) -> Result<DecodedImage> {
    let extension = path
        .extension()
        .map(|value| value.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();
    let bytes = std::fs::read(path)?;
    decode_with_path(&bytes, &extension, Some(path))
}

/// Decodes raw bytes whose extension the caller knows.
pub fn decode_raw_bytes(bytes: &[u8], extension: &str) -> Result<DecodedImage> {
    decode_with_path(bytes, extension, None)
}

/// The shared routing. `path` is carried down for the supplementary decoder, which prefers its own
/// file datastream when a file exists on disk.
fn decode_with_path(bytes: &[u8], extension: &str, path: Option<&Path>) -> Result<DecodedImage> {
    let extension = extension.trim_start_matches('.').to_ascii_lowercase();
    let container = SUPPORTED_CONTAINERS.contains(&extension.as_str());
    if !container && !needs_demosaic_engine(&extension) {
        return Err(Error::Unsupported(extension));
    }
    // A DNG usually holds sensor data, so the sensor decoder goes first; a TIFF is usually a
    // rendered image, so the container reader goes first. Both fall back to the other.
    if container && extension != "dng" {
        return match decode_container(bytes, &extension) {
            Ok(image) => Ok(DecodedImage { image, source: RawSource::Container }),
            Err(container_error) => match decode_sensor_chain(bytes, path) {
                Ok(decoded) => Ok(decoded),
                Err(sensor_error) => Err(Error::Vendor(format!(
                    "{}; {}",
                    detail(&container_error),
                    detail(&sensor_error)
                ))),
            },
        };
    }
    match decode_sensor_chain(bytes, path) {
        Ok(decoded) => Ok(decoded),
        Err(sensor_error) => {
            if !container {
                return Err(sensor_error);
            }
            match decode_container(bytes, &extension) {
                Ok(image) => Ok(DecodedImage { image, source: RawSource::Container }),
                Err(container_error) => Err(Error::Vendor(format!(
                    "{}; the DNG/TIFF reader also failed: {}",
                    detail(&sensor_error),
                    detail(&container_error)
                ))),
            }
        }
    }
}

/// The sensor decoders in order. The pure-Rust decoder always runs first: it is the one with no
/// distribution cost, and when it succeeds nothing else is tried. LibRaw only gets the files it
/// cannot read (CR3, DNG lossy JPEG, camera bodies missing from its database), and the metadata
/// records both which engine answered and what the first one said.
fn decode_sensor_chain(bytes: &[u8], path: Option<&Path>) -> Result<DecodedImage> {
    // The path is only used by the supplementary decoder.
    #[cfg(not(feature = "libraw"))]
    let _ = path;
    let rawloader_error = match vendor::decode_vendor_bytes(bytes) {
        Ok(decoded) => return Ok(sensor_image(decoded)),
        Err(error) => error,
    };
    #[cfg(feature = "libraw")]
    {
        // LibRaw's own file datastream is preferred when the caller had a path: it is the path its
        // own tools take, and its CR3 decoder needs it (see NOTES.md).
        let libraw = match path {
            Some(path) => crate::libraw_backend::decode_libraw_file(path, Some(detail(&rawloader_error))),
            None => crate::libraw_backend::decode_libraw_bytes(bytes, Some(detail(&rawloader_error))),
        };
        match libraw {
            Ok(decoded) => Ok(sensor_image(decoded)),
            Err(libraw_error) => Err(Error::Vendor(format!(
                "{}; LibRaw also failed: {}",
                detail(&rawloader_error),
                detail(&libraw_error)
            ))),
        }
    }
    #[cfg(not(feature = "libraw"))]
    Err(rawloader_error)
}

fn sensor_image(decoded: vendor::VendorImage) -> DecodedImage {
    DecodedImage { image: decoded.image, source: RawSource::Sensor(Box::new(decoded.metadata)) }
}

/// The message inside an error, without its own wrapper, so combining two failures stays readable.
fn detail(error: &Error) -> String {
    match error {
        Error::Vendor(message) | Error::Decode(message) | Error::Unsupported(message) => message.clone(),
        other => other.to_string(),
    }
}

fn decode_container(bytes: &[u8], extension: &str) -> Result<Bitmap8> {
    let decoded = image::load_from_memory(bytes).map_err(|error| Error::Decode(container_message(extension, &error)))?;
    let rgba = decoded.to_rgba8();
    let (width, height) = (rgba.width(), rgba.height());
    Bitmap8::from_raw(width, height, rgba.into_raw()).map_err(Error::Core)
}

fn container_message(extension: &str, error: &image::ImageError) -> String {
    format!(".{extension} could not be decoded by the built-in TIFF reader ({error})")
}

/// Reads a raw file and decodes it into straight-alpha RGBA, discarding the metadata.
pub fn decode_file(path: &Path) -> Result<Bitmap8> {
    Ok(decode_raw_file(path)?.image)
}

/// Decodes in-memory raw bytes, discarding the metadata.
pub fn decode_bytes(bytes: &[u8], extension: &str) -> Result<Bitmap8> {
    Ok(decode_raw_bytes(bytes, extension)?.image)
}

/// Reads a raw file and runs the Camera Raw grade over it.
pub fn develop_file(path: &Path, settings: &RawSettings) -> Result<Bitmap8> {
    let decoded = decode_raw_file(path)?;
    Ok(crate::develop(&decoded.image, settings))
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::ImageEncoder;

    fn tiff_bytes() -> Vec<u8> {
        let rgba = vec![10u8, 20, 30, 255, 200, 100, 50, 128];
        let mut bytes = Vec::new();
        let mut cursor = std::io::Cursor::new(&mut bytes);
        image::codecs::tiff::TiffEncoder::new(&mut cursor)
            .write_image(&rgba, 2, 1, image::ExtendedColorType::Rgba8)
            .expect("the test image encodes");
        bytes
    }

    #[test]
    fn a_tiff_round_trips_through_the_decoder() {
        let image = decode_bytes(&tiff_bytes(), "tiff").expect("a written TIFF decodes");
        assert_eq!(image.width(), 2);
        assert_eq!(image.height(), 1);
        assert_eq!(image.get(0, 0), [10, 20, 30, 255]);
        assert_eq!(image.get(1, 0), [200, 100, 50, 128]);
    }

    #[test]
    fn a_rendered_dng_still_goes_through_the_container_reader() {
        // A plain TIFF renamed .dng has no sensor data, so the sensor decoder fails and the container
        // reader takes over. The result must be the same pixels.
        let decoded = decode_raw_bytes(&tiff_bytes(), "dng").expect("the fallback reads it");
        assert_eq!(decoded.image.get(0, 0), [10, 20, 30, 255]);
        assert_eq!(decoded.source, RawSource::Container);
        assert!(decoded.metadata().is_none(), "a container has no sensor metadata");
    }

    #[test]
    fn vendor_extensions_reach_the_sensor_decoder() {
        // Four bytes of nothing is not a raw file, but the extension is one this build accepts, so
        // the failure comes from the decoder and names itself rather than claiming the format is
        // unsupported.
        for extension in ["nef", "cr2", "arw", "raf", "rw2", "orf", "cr3"] {
            match decode_bytes(&[0u8; 4], extension) {
                Err(Error::Vendor(message)) => assert!(!message.is_empty(), "{extension}"),
                other => panic!("{extension} must fail inside the decoder, got {other:?}"),
            }
        }
        // Even a well-formed TIFF is handed to the sensor decoder when the extension says camera raw.
        assert!(matches!(decode_bytes(&tiff_bytes(), "cr3"), Err(Error::Vendor(_))));
    }

    #[test]
    fn needs_demosaic_engine_knows_the_vendor_list() {
        assert!(needs_demosaic_engine("nef"));
        assert!(needs_demosaic_engine(".CR3"));
        assert!(!needs_demosaic_engine("dng"), "dng is a container, not a vendor extension");
        assert!(!needs_demosaic_engine("png"));
        for extension in VENDOR_RAW_EXTENSIONS {
            assert!(needs_demosaic_engine(extension), "{extension} must be listed");
        }
    }

    #[test]
    fn an_unknown_extension_is_unsupported_too() {
        match decode_bytes(&tiff_bytes(), "png") {
            Err(Error::Unsupported(name)) => assert_eq!(name, "png"),
            other => panic!("png is not a raw container here, got {other:?}"),
        }
        assert!(matches!(decode_bytes(&tiff_bytes(), ""), Err(Error::Unsupported(_))));
    }

    #[test]
    fn damaged_bytes_report_a_readable_failure() {
        let mut damaged = tiff_bytes();
        damaged.truncate(8);
        match decode_raw_bytes(&damaged, "tif") {
            // Both backends are tried for tif, and both messages are reported.
            Err(Error::Vendor(message)) => assert!(message.len() > 10, "{message}"),
            other => panic!("expected a vendor error, got {other:?}"),
        }
    }

    #[test]
    fn a_missing_file_reports_an_io_error() {
        let missing = std::path::Path::new("this-raw-file-does-not-exist.dng");
        assert!(matches!(decode_file(missing), Err(Error::Io(_))));
        // A vendor extension is accepted on sight now, so a missing .nef is an IO problem too.
        let missing = std::path::Path::new("this-raw-file-does-not-exist.nef");
        assert!(matches!(decode_file(missing), Err(Error::Io(_))));
    }

    #[test]
    fn a_decoded_buffer_runs_the_grade() {
        let settings = RawSettings { exposure: 1.0, ..RawSettings::default() };
        let buffer = [10u8, 20, 30, 255, 200, 100, 50, 255];
        let image = crate::develop_buffer(2, 1, &buffer, &settings).expect("the buffer matches its size");
        assert_eq!(image.width(), 2);
        assert!(image.get(0, 0)[0] > 10, "exposure brightened the pixel");
        assert!(crate::develop_buffer(2, 1, &buffer[..4], &settings).is_err());
    }

    #[test]
    fn a_file_develops_end_to_end() {
        let directory = std::env::temp_dir();
        let path = directory.join("comp-raw-decode-test.tif");
        std::fs::write(&path, tiff_bytes()).expect("the temporary file is writable");
        let settings = RawSettings { exposure: 1.0, ..RawSettings::default() };
        let image = develop_file(&path, &settings).expect("the written TIFF develops");
        assert_eq!((image.width(), image.height()), (2, 1));
        assert!(image.get(1, 0)[3] == 128, "the decoded alpha survives the grade");
        std::fs::remove_file(&path).expect("the temporary file is removable");
    }
}
