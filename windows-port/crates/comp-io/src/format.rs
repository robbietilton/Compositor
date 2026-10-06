//! The raster formats this crate reads and writes outside the `.comp` package.

use std::path::Path;

/// A file format the importer recognizes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum RasterFormat {
    Png,
    Jpeg,
    Tiff,
    Bmp,
    WebP,
    /// HEIC and HEIF: an HEVC-coded still picture in an ISO base media container. Read through the
    /// Windows Imaging Component; see the heic module.
    Heic,
    /// AVIF: the same container coded with AV1, which the same system decoder reads.
    Avif,
    /// A vector document, rasterized on import; there is no SVG export.
    Svg,
}

impl RasterFormat {
    pub const ALL: [RasterFormat; 8] = [
        RasterFormat::Png,
        RasterFormat::Jpeg,
        RasterFormat::Tiff,
        RasterFormat::Bmp,
        RasterFormat::WebP,
        RasterFormat::Heic,
        RasterFormat::Avif,
        RasterFormat::Svg,
    ];

    /// The name the macOS importer's error message uses.
    pub fn as_str(self) -> &'static str {
        match self {
            RasterFormat::Png => "PNG",
            RasterFormat::Jpeg => "JPEG",
            RasterFormat::Tiff => "TIFF",
            RasterFormat::Bmp => "BMP",
            RasterFormat::WebP => "WebP",
            RasterFormat::Heic => "HEIC",
            RasterFormat::Avif => "AVIF",
            RasterFormat::Svg => "SVG",
        }
    }

    pub fn mime(self) -> &'static str {
        match self {
            RasterFormat::Png => "image/png",
            RasterFormat::Jpeg => "image/jpeg",
            RasterFormat::Tiff => "image/tiff",
            RasterFormat::Bmp => "image/bmp",
            RasterFormat::WebP => "image/webp",
            RasterFormat::Heic => "image/heic",
            RasterFormat::Avif => "image/avif",
            RasterFormat::Svg => "image/svg+xml",
        }
    }

    /// Every extension the importer accepts for this format, lowercase.
    pub fn extensions(self) -> &'static [&'static str] {
        match self {
            RasterFormat::Png => &["png"],
            RasterFormat::Jpeg => &["jpg", "jpeg", "jpe"],
            RasterFormat::Tiff => &["tif", "tiff"],
            RasterFormat::Bmp => &["bmp", "dib"],
            RasterFormat::WebP => &["webp"],
            RasterFormat::Heic => &["heic", "heif", "hif"],
            RasterFormat::Avif => &["avif", "avifs"],
            RasterFormat::Svg => &["svg"],
        }
    }

    pub fn from_extension(extension: &str) -> Option<Self> {
        let lowered = extension.trim_start_matches('.').to_ascii_lowercase();
        RasterFormat::ALL
            .into_iter()
            .find(|format| format.extensions().contains(&lowered.as_str()))
    }

    pub fn from_path(path: impl AsRef<Path>) -> Option<Self> {
        path.as_ref().extension().and_then(|e| e.to_str()).and_then(RasterFormat::from_extension)
    }

    /// Sniffs the format from the leading bytes. Extensions lie; signatures do not.
    pub fn from_bytes(bytes: &[u8]) -> Option<Self> {
        if bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
            return Some(RasterFormat::Png);
        }
        if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
            return Some(RasterFormat::Jpeg);
        }
        if bytes.starts_with(b"II\x2A\x00") || bytes.starts_with(b"MM\x00\x2A") {
            return Some(RasterFormat::Tiff);
        }
        if bytes.starts_with(b"BM") {
            return Some(RasterFormat::Bmp);
        }
        if bytes.len() >= 12 && bytes.starts_with(b"RIFF") && &bytes[8..12] == b"WEBP" {
            return Some(RasterFormat::WebP);
        }
        if let Some(brand) = iso_major_brand(bytes) {
            if is_heif_brand(brand) {
                return Some(RasterFormat::Heic);
            }
            if is_avif_brand(brand) {
                return Some(RasterFormat::Avif);
            }
        }
        // A vector file has no signature, so this is the one format the first bytes are read for
        // as text; the check stays last so no binary format can be mistaken for it.
        if crate::svg::matches(bytes) {
            return Some(RasterFormat::Svg);
        }
        None
    }
}

/// The major brand of an ISO base media file, which starts with an ftyp box.
///
/// HEIC, HEIF and AVIF all share this container, so the brand is what tells them apart: only the
/// HEVC-coded brands and the generic HEIF ones are accepted here.
fn iso_major_brand(bytes: &[u8]) -> Option<[u8; 4]> {
    if bytes.len() < 12 || &bytes[4..8] != b"ftyp" {
        return None;
    }
    Some([bytes[8], bytes[9], bytes[10], bytes[11]])
}

fn is_heif_brand(brand: [u8; 4]) -> bool {
    matches!(&brand, b"heic" | b"heix" | b"hevc" | b"hevx" | b"heim" | b"heis" | b"hevm" | b"hevs" | b"mif1" | b"msf1")
}

/// The AV1 brands of the same container. The system HEIF decoder reads these too, so once the
/// signature says which codec the file holds the import is the same path.
fn is_avif_brand(brand: [u8; 4]) -> bool {
    matches!(&brand, b"avif" | b"avis")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signatures_win_over_extensions() {
        assert_eq!(RasterFormat::from_bytes(&[0x89, b'P', b'N', b'G', 13, 10, 26, 10]), Some(RasterFormat::Png));
        assert_eq!(RasterFormat::from_bytes(&[0xFF, 0xD8, 0xFF, 0xE0]), Some(RasterFormat::Jpeg));
        assert_eq!(RasterFormat::from_bytes(b"II*\0rest"), Some(RasterFormat::Tiff));
        assert_eq!(RasterFormat::from_bytes(b"MM\0*rest"), Some(RasterFormat::Tiff));
        assert_eq!(RasterFormat::from_bytes(b"BM~~~~"), Some(RasterFormat::Bmp));
        let mut webp = b"RIFF\x00\x00\x00\x00WEBP".to_vec();
        assert_eq!(RasterFormat::from_bytes(&webp), Some(RasterFormat::WebP));
        webp[0] = b'X';
        assert_eq!(RasterFormat::from_bytes(&webp), None);
        assert_eq!(RasterFormat::from_bytes(b"not an image"), None);
    }

    #[test]
    fn heic_brands_are_recognized_and_avif_is_not() {
        for brand in [b"heic", b"heix", b"hevc", b"hevx", b"mif1", b"msf1"] {
            let mut file = vec![0u8, 0, 0, 24];
            file.extend_from_slice(b"ftyp");
            file.extend_from_slice(brand);
            file.extend_from_slice(&[0, 0, 0, 0]);
            file.extend_from_slice(b"mif1heic");
            assert_eq!(RasterFormat::from_bytes(&file), Some(RasterFormat::Heic), "{brand:?}");
        }
        // AVIF shares the container but codes with AV1, so it is its own format.
        for brand in [b"avif", b"avis"] {
            let mut avif = vec![0u8, 0, 0, 20];
            avif.extend_from_slice(b"ftyp");
            avif.extend_from_slice(brand);
            avif.extend_from_slice(&[0, 0, 0, 0]);
            assert_eq!(RasterFormat::from_bytes(&avif), Some(RasterFormat::Avif), "{brand:?}");
        }
        // A brand that is neither HEVC nor AV1 coded is not one of these.
        let mut other = vec![0u8, 0, 0, 20];
        other.extend_from_slice(b"ftypmp42");
        other.extend_from_slice(&[0, 0, 0, 0]);
        assert_eq!(RasterFormat::from_bytes(&other), None);
        // The box type has to be ftyp, and the file has to be long enough to hold one.
        assert_eq!(RasterFormat::from_bytes(b"\x00\x00\x00\x18ftyqheic"), None);
        assert_eq!(RasterFormat::from_bytes(b"\x00\x00\x00\x18ftyXheic"), None);
        assert_eq!(RasterFormat::from_bytes(b"ftypheic"), None);
        // A complete box is one, whatever else follows it.
        assert_eq!(RasterFormat::from_bytes(b"\x00\x00\x00\x18ftypheic"), Some(RasterFormat::Heic));
    }

    #[test]
    fn heic_names_are_known() {
        assert_eq!(RasterFormat::from_extension("HEIC"), Some(RasterFormat::Heic));
        assert_eq!(RasterFormat::from_extension(".heif"), Some(RasterFormat::Heic));
        assert_eq!(RasterFormat::from_extension("hif"), Some(RasterFormat::Heic));
        assert_eq!(RasterFormat::from_path("photo.HEIC"), Some(RasterFormat::Heic));
        assert_eq!(RasterFormat::Heic.as_str(), "HEIC");
        assert_eq!(RasterFormat::Heic.mime(), "image/heic");
        assert!(RasterFormat::ALL.contains(&RasterFormat::Heic));
        assert_eq!(RasterFormat::from_extension("AVIF"), Some(RasterFormat::Avif));
        assert_eq!(RasterFormat::from_extension(".avifs"), Some(RasterFormat::Avif));
        assert_eq!(RasterFormat::Avif.as_str(), "AVIF");
        assert_eq!(RasterFormat::Avif.mime(), "image/avif");
        assert!(RasterFormat::ALL.contains(&RasterFormat::Avif));
    }

    #[test]
    fn extensions_are_case_insensitive() {
        assert_eq!(RasterFormat::from_extension("JPG"), Some(RasterFormat::Jpeg));
        assert_eq!(RasterFormat::from_extension(".Tif"), Some(RasterFormat::Tiff));
        assert_eq!(RasterFormat::from_extension("gif"), None);
        assert_eq!(RasterFormat::from_extension("SVG"), Some(RasterFormat::Svg));
    }

    #[test]
    fn svg_is_sniffed_from_its_root_element() {
        assert_eq!(
            RasterFormat::from_bytes(br#"<?xml version="1.0"?><svg width="4" height="4"/>"#),
            Some(RasterFormat::Svg)
        );
        assert_eq!(RasterFormat::from_bytes(b"   
<svg xmlns='http://www.w3.org/2000/svg'/>"),
                   Some(RasterFormat::Svg));
        assert_eq!(RasterFormat::from_bytes(b"<html><body/></html>"), None);
        assert_eq!(RasterFormat::from_bytes(b"not xml at all"), None);
        // A binary file that happens to contain the letters must not be taken for vector art.
        assert_eq!(RasterFormat::from_bytes(&[0x89, b'P', b'N', b'G', 13, 10, 26, 10, b'<', b's', b'v', b'g']),
                   Some(RasterFormat::Png));
    }
}
