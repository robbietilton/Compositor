//! Resolution metadata: reading the pixels per inch a raster file declares.
//!
//! PNG's pHYs chunk, JPEG's JFIF APP0 density, BMP's pels per meter, TIFF's IFD0 resolution tags
//! and WebP's EXIF chunk are the places these formats record a DPI. macOS hands the same numbers to
//! ImageIO when it exports, so reading them on import is what keeps a 300 dpi file at 300 dpi
//! through an import and an export.
use crate::format::RasterFormat;

/// The resolution a file declares, in pixels per inch.
pub fn read_resolution(bytes: &[u8], format: RasterFormat) -> Option<f64> {
    match format {
        RasterFormat::Png => read_png_resolution(bytes),
        RasterFormat::Jpeg => read_jpeg_resolution(bytes),
        RasterFormat::Bmp => read_bmp_resolution(bytes),
        RasterFormat::Tiff => read_tiff_resolution(bytes),
        RasterFormat::WebP => read_webp_resolution(bytes),
        // A HEIF or AVIF file carries its resolution in an Exif item, which the container reader
        // finds; a vector file has no resolution of its own.
        RasterFormat::Heic | RasterFormat::Avif => crate::isobmff::read_heif_resolution(bytes),
        RasterFormat::Svg => None,
    }
}

/// The PNG pHYs chunk as pixels per inch. A pHYs with unit 0 is an aspect ratio, not a DPI.
pub fn read_png_resolution(bytes: &[u8]) -> Option<f64> {
    if !bytes.starts_with(&crate::codec::PNG_SIGNATURE) {
        return None;
    }
    let mut offset = 8usize;
    while offset + 8 <= bytes.len() {
        let length = be_u32(&bytes[offset..offset + 4])? as usize;
        let kind = &bytes[offset + 4..offset + 8];
        let data_start = offset + 8;
        let data_end = data_start.checked_add(length)?;
        if data_end + 4 > bytes.len() {
            return None;
        }
        if kind == b"pHYs" && length >= 9 {
            let xppu = be_u32(&bytes[data_start..data_start + 4])?;
            let unit = bytes[data_start + 8];
            if unit == 1 && xppu > 0 {
                return Some(xppu as f64 * 0.0254);
            }
            return None;
        }
        if kind == b"IDAT" || kind == b"IEND" {
            return None;
        }
        offset = data_end + 4;
    }
    None
}

/// The JFIF APP0 density as pixels per inch, the field export_jpeg writes.
pub fn read_jpeg_resolution(bytes: &[u8]) -> Option<f64> {
    if !bytes.starts_with(&[0xFF, 0xD8]) {
        return None;
    }
    let mut offset = 2usize;
    while offset + 4 <= bytes.len() {
        if bytes[offset] != 0xFF {
            return None;
        }
        let marker = bytes[offset + 1];
        if marker == 0xD8 || (0xD0..=0xD7).contains(&marker) || marker == 0x01 {
            offset += 2;
            continue;
        }
        if marker == 0xDA || marker == 0xD9 {
            return None;
        }
        let length = u16::from_be_bytes([bytes[offset + 2], bytes[offset + 3]]) as usize;
        if length < 2 || offset + 2 + length > bytes.len() {
            return None;
        }
        let payload = &bytes[offset + 4..offset + 2 + length];
        if marker == 0xE0 && payload.len() >= 12 && payload.starts_with(b"JFIF\0") {
            let units = payload[7];
            let density = u16::from_be_bytes([payload[8], payload[9]]);
            return match units {
                1 => Some(density as f64),
                2 => Some(density as f64 * 2.54),
                _ => None,
            };
        }
        offset += 2 + length;
    }
    None
}

/// BMP's two pels-per-meter fields, which every Windows header from BITMAPINFOHEADER on carries.
pub fn read_bmp_resolution(bytes: &[u8]) -> Option<f64> {
    if !bytes.starts_with(b"BM") {
        return None;
    }
    let header = bytes.get(14..)?;
    let header_size = u32::from_le_bytes(header.get(0..4)?.try_into().ok()?) as usize;
    // BITMAPCOREHEADER (12 bytes) is the only header without the resolution fields.
    if header_size < 40 {
        return None;
    }
    // biXPelsPerMeter and biYPelsPerMeter sit at 24 and 28 in every header from
    // BITMAPINFOHEADER through BITMAPV5HEADER; the core header that lacks them is refused above.
    let x = u32::from_le_bytes(header.get(24..28)?.try_into().ok()?);
    let y = u32::from_le_bytes(header.get(28..32)?.try_into().ok()?);
    pixels_per_meter_to_dpi(if x > 0 { x } else { y })
}

/// TIFF's IFD0: XResolution (282), YResolution (283) and ResolutionUnit (296).
pub fn read_tiff_resolution(bytes: &[u8]) -> Option<f64> {
    tiff_ifd_resolution(bytes, 0)
}

/// WebP's resolution, which lives in its EXIF chunk, the only place the format can carry a DPI.
pub fn read_webp_resolution(bytes: &[u8]) -> Option<f64> {
    if bytes.len() < 12 || !bytes.starts_with(b"RIFF") || &bytes[8..12] != b"WEBP" {
        return None;
    }
    let mut offset = 12usize;
    while offset + 8 <= bytes.len() {
        let kind = &bytes[offset..offset + 4];
        let size = u32::from_le_bytes(bytes[offset + 4..offset + 8].try_into().ok()?) as usize;
        let start = offset + 8;
        let end = start.checked_add(size)?;
        let payload = bytes.get(start..end)?;
        if kind == b"EXIF" {
            // The specification stores the EXIF payload; some writers keep the six-byte marker.
            let base = if payload.starts_with(b"Exif\0\0") { 6 } else { 0 };
            if let Some(dpi) = tiff_ifd_resolution(payload, base) {
                return Some(dpi);
            }
        }
        // RIFF chunks are padded to an even length.
        offset = end + (size & 1);
    }
    None
}

/// The resolution in a TIFF structure that starts at `base`, which is also how WebP's EXIF chunk
/// stores it.
fn tiff_ifd_resolution(bytes: &[u8], base: usize) -> Option<f64> {
    let order = match bytes.get(base..base + 2)? {
        b"II" => Endian::Little,
        b"MM" => Endian::Big,
        _ => return None,
    };
    // 42 is classic TIFF; BigTIFF's 43 uses 64-bit offsets this reader does not walk.
    if order.u16(bytes, base + 2)? != 42 {
        return None;
    }
    let ifd = base.checked_add(order.u32(bytes, base + 4)? as usize)?;
    let count = order.u16(bytes, ifd)? as usize;
    if count > 4096 {
        return None;
    }
    let mut x = None;
    let mut y = None;
    let mut unit = 2u16; // Every writer that stores a resolution means inches unless it says otherwise.
    for index in 0..count {
        let entry = ifd + 2 + index * 12;
        let tag = order.u16(bytes, entry)?;
        match tag {
            282 | 283 => {
                let kind = order.u16(bytes, entry + 2)?;
                let values = order.u32(bytes, entry + 4)?;
                if values != 1 {
                    continue;
                }
                let value = match kind {
                    // RATIONAL and its signed twin point at an 8-byte numerator and denominator.
                    5 | 10 => {
                        let at = base.checked_add(order.u32(bytes, entry + 8)? as usize)?;
                        let numerator = order.u32(bytes, at)? as f64;
                        let denominator = order.u32(bytes, at + 4)? as f64;
                        if denominator == 0.0 {
                            continue;
                        }
                        numerator / denominator
                    }
                    // A malformed file may inline a float instead; read it rather than give up.
                    11 => f32::from_bits(order.u32(bytes, entry + 8)?) as f64,
                    _ => continue,
                };
                if tag == 282 {
                    x = Some(value);
                } else {
                    y = Some(value);
                }
            }
            296 => unit = order.u16(bytes, entry + 8)?,
            _ => {}
        }
    }
    let value = x.or(y)?;
    if !value.is_finite() || value <= 0.0 {
        return None;
    }
    match unit {
        2 => Some(value),
        3 => Some(value * 2.54),
        // 1 means no absolute unit, so the number is an aspect ratio and not a DPI.
        _ => None,
    }
}

fn pixels_per_meter_to_dpi(pixels_per_meter: u32) -> Option<f64> {
    if pixels_per_meter == 0 {
        return None;
    }
    Some(f64::from(pixels_per_meter) * 0.0254)
}

#[derive(Clone, Copy)]
enum Endian {
    Little,
    Big,
}

impl Endian {
    fn u16(self, bytes: &[u8], offset: usize) -> Option<u16> {
        let pair: [u8; 2] = bytes.get(offset..offset + 2)?.try_into().ok()?;
        Some(match self {
            Endian::Little => u16::from_le_bytes(pair),
            Endian::Big => u16::from_be_bytes(pair),
        })
    }

    fn u32(self, bytes: &[u8], offset: usize) -> Option<u32> {
        let quad: [u8; 4] = bytes.get(offset..offset + 4)?.try_into().ok()?;
        Some(match self {
            Endian::Little => u32::from_le_bytes(quad),
            Endian::Big => u32::from_be_bytes(quad),
        })
    }
}

fn be_u32(bytes: &[u8]) -> Option<u32> {
    Some(u32::from_be_bytes([*bytes.first()?, *bytes.get(1)?, *bytes.get(2)?, *bytes.get(3)?]))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A little-endian uncompressed RGB TIFF with the tags a camera writes, resolution included.
    fn tiff_with_resolution(width: u32, height: u32, x: (u32, u32), y: (u32, u32), unit: u16) -> Vec<u8> {
        let pixels: Vec<u8> = (0..width * height)
            .flat_map(|index| [(index * 40) as u8, 255 - (index * 40) as u8, 128])
            .collect();
        // tag, type, count, value (inline, or an offset patched below)
        let mut entries: Vec<(u16, u16, u32, u32)> = vec![
            (256, 3, 1, width),
            (257, 3, 1, height),
            (258, 3, 3, 0),
            (259, 3, 1, 1),
            (262, 3, 1, 2),
            (273, 4, 1, 0),
            (277, 3, 1, 3),
            (278, 3, 1, height),
            (279, 4, 1, width * height * 3),
            (282, 5, 1, 0),
            (283, 5, 1, 0),
            (296, 3, 1, u32::from(unit)),
        ];
        let ifd_offset = 8u32;
        let ifd_size = 2 + 12 * entries.len() as u32 + 4;
        let bits_offset = ifd_offset + ifd_size;
        let x_offset = bits_offset + 6; // three shorts, already even
        let y_offset = x_offset + 8;
        let pixels_offset = y_offset + 8;
        entries[2].3 = bits_offset;
        entries[5].3 = pixels_offset;
        entries[9].3 = x_offset;
        entries[10].3 = y_offset;

        let mut out = Vec::new();
        out.extend_from_slice(b"II");
        out.extend_from_slice(&42u16.to_le_bytes());
        out.extend_from_slice(&ifd_offset.to_le_bytes());
        out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
        for (tag, kind, count, value) in &entries {
            out.extend_from_slice(&tag.to_le_bytes());
            out.extend_from_slice(&kind.to_le_bytes());
            out.extend_from_slice(&count.to_le_bytes());
            if *kind == 3 && *count == 1 {
                // A SHORT value lives in the first two bytes of the value field.
                out.extend_from_slice(&(*value as u16).to_le_bytes());
                out.extend_from_slice(&0u16.to_le_bytes());
            } else {
                out.extend_from_slice(&value.to_le_bytes());
            }
        }
        out.extend_from_slice(&0u32.to_le_bytes());
        out.extend_from_slice(&[8u16.to_le_bytes(), 8u16.to_le_bytes(), 8u16.to_le_bytes()].concat());
        out.extend_from_slice(&x.0.to_le_bytes());
        out.extend_from_slice(&x.1.to_le_bytes());
        out.extend_from_slice(&y.0.to_le_bytes());
        out.extend_from_slice(&y.1.to_le_bytes());
        out.extend_from_slice(&pixels);
        out
    }

    /// A 24-bit bottom-up BMP with the two pels-per-meter fields a Windows header carries.
    fn bmp_with_resolution(width: u32, height: u32, x: u32, y: u32, rgb: [u8; 3]) -> Vec<u8> {
        let row = (width * 3 + 3) & !3;
        let data = row * height;
        let mut out = Vec::new();
        out.extend_from_slice(b"BM");
        out.extend_from_slice(&(54 + data).to_le_bytes());
        out.extend_from_slice(&[0, 0, 0, 0]);
        out.extend_from_slice(&54u32.to_le_bytes());
        out.extend_from_slice(&40u32.to_le_bytes());
        out.extend_from_slice(&(width as i32).to_le_bytes());
        out.extend_from_slice(&(height as i32).to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&24u16.to_le_bytes());
        out.extend_from_slice(&0u32.to_le_bytes());
        out.extend_from_slice(&data.to_le_bytes());
        out.extend_from_slice(&x.to_le_bytes());
        out.extend_from_slice(&y.to_le_bytes());
        out.extend_from_slice(&0u32.to_le_bytes());
        out.extend_from_slice(&0u32.to_le_bytes());
        for _ in 0..height {
            for _ in 0..width {
                out.extend_from_slice(&[rgb[2], rgb[1], rgb[0]]);
            }
            out.extend(std::iter::repeat_n(0u8, (row - width * 3) as usize));
        }
        out
    }

    /// A RIFF container holding one EXIF chunk and nothing else, which is all a DPI needs.
    fn webp_with_exif(payload: &[u8]) -> Vec<u8> {
        let mut chunk = Vec::new();
        chunk.extend_from_slice(b"EXIF");
        chunk.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        chunk.extend_from_slice(payload);
        if payload.len() % 2 == 1 {
            chunk.push(0);
        }
        let mut out = Vec::new();
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&((4 + chunk.len()) as u32).to_le_bytes());
        out.extend_from_slice(b"WEBP");
        out.extend_from_slice(&chunk);
        out
    }

    fn close(value: f64, expected: f64) -> bool {
        (value - expected).abs() < 0.05
    }

    #[test]
    fn png_and_jpeg_resolution_still_read_through_the_dispatcher() {
        let image = comp_core::bitmap::Bitmap8::filled(4, 4, [10, 20, 30, 255]);
        let png = crate::codec::encode_png(&image, 300.0).unwrap();
        assert!(close(read_resolution(&png, RasterFormat::Png).unwrap(), 300.0));
        let jpeg = crate::codec::encode_jpeg(
            &image,
            &crate::codec::JpegOptions { quality: 80, resolution: 150.0, ..Default::default() },
        )
        .unwrap();
        assert!(close(read_resolution(&jpeg, RasterFormat::Jpeg).unwrap(), 150.0));
    }

    #[test]
    fn bmp_resolution_comes_from_pels_per_meter() {
        let bmp = bmp_with_resolution(4, 2, 11_811, 11_811, [200, 30, 30]);
        assert!(close(read_bmp_resolution(&bmp).unwrap(), 300.0), "{:?}", read_bmp_resolution(&bmp));
        assert!(read_bmp_resolution(&bmp_with_resolution(4, 2, 0, 0, [0, 0, 0])).is_none());
        // A fallback to the vertical field keeps files that only fill one usable.
        let half = bmp_with_resolution(4, 2, 0, 11_811, [0, 0, 0]);
        assert!(close(read_bmp_resolution(&half).unwrap(), 300.0));
        assert!(read_bmp_resolution(b"not a bmp").is_none());
    }

    #[test]
    fn tiff_resolution_reads_inches_centimeters_and_no_unit() {
        let inches = tiff_with_resolution(2, 2, (300, 1), (300, 1), 2);
        assert!(close(read_tiff_resolution(&inches).unwrap(), 300.0));
        let centimeters = tiff_with_resolution(2, 2, (118, 1), (118, 1), 3);
        let value = read_tiff_resolution(&centimeters).unwrap();
        assert!(close(value, 299.72), "{value}");
        // Unit 1 says the number has no absolute meaning, so it is not a DPI.
        assert!(read_tiff_resolution(&tiff_with_resolution(2, 2, (300, 1), (300, 1), 1)).is_none());
        // A zero denominator is a damaged file, not a division by zero; the other axis still
        // answers when only one of the two is unusable.
        assert!(read_tiff_resolution(&tiff_with_resolution(2, 2, (300, 0), (300, 0), 2)).is_none());
        assert!(close(
            read_tiff_resolution(&tiff_with_resolution(2, 2, (300, 0), (150, 1), 2)).unwrap(),
            150.0
        ));
    }

    #[test]
    fn a_big_endian_tiff_and_damaged_headers_are_handled() {
        let mut tiff = tiff_with_resolution(2, 2, (300, 1), (300, 1), 2);
        assert!(read_tiff_resolution(&tiff).is_some());
        // Truncating must not panic: every read is bounds checked.
        for cut in [0usize, 4, 8, 16, 40, 100] {
            let _ = read_tiff_resolution(&tiff[..tiff.len().min(cut)]);
        }
        tiff[2] = 43; // a BigTIFF magic, which this reader does not walk
        assert!(read_tiff_resolution(&tiff).is_none());
        assert!(read_tiff_resolution(b"MM\0*").is_none());
    }

    #[test]
    fn webp_resolution_comes_from_its_exif_chunk() {
        let tiff = tiff_with_resolution(2, 2, (300, 1), (300, 1), 2);
        let bare = webp_with_exif(&tiff);
        assert!(close(read_webp_resolution(&bare).unwrap(), 300.0));
        // Writers disagree about keeping the six-byte EXIF marker inside the chunk.
        let mut marked = b"Exif\0\0".to_vec();
        marked.extend_from_slice(&tiff);
        assert!(close(read_webp_resolution(&webp_with_exif(&marked)).unwrap(), 300.0));
        assert!(close(read_resolution(&bare, RasterFormat::WebP).unwrap(), 300.0));
    }

    #[test]
    fn webp_without_exif_has_no_resolution() {
        let image = comp_core::bitmap::Bitmap8::filled(4, 4, [1, 2, 3, 255]);
        let mut webp = std::io::Cursor::new(Vec::new());
        use image::codecs::webp::WebPEncoder;
        use image::{ExtendedColorType, ImageEncoder};
        WebPEncoder::new_lossless(&mut webp)
            .write_image(image.pixels(), 4, 4, ExtendedColorType::Rgba8)
            .unwrap();
        let bytes = webp.into_inner();
        assert!(bytes.starts_with(b"RIFF"));
        assert!(read_webp_resolution(&bytes).is_none());
        assert!(read_webp_resolution(b"RIFF\0\0\0\0WEBP").is_none());
    }

    #[test]
    fn a_tiff_imports_with_its_resolution_and_pixels() {
        let tiff = tiff_with_resolution(2, 2, (300, 1), (300, 1), 2);
        let directory = std::env::temp_dir().join(format!("comp-io-dpi-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("resolved.tiff");
        std::fs::write(&path, &tiff).unwrap();
        let raster = crate::codec::import_raster(&path, &crate::codec::ImportOptions::default()).unwrap();
        assert_eq!((raster.image.width(), raster.image.height()), (2, 2));
        assert_eq!(raster.image.get(0, 0), [0, 255, 128, 255]);
        assert_eq!(raster.format, RasterFormat::Tiff);
        let resolution = raster.resolution.unwrap();
        assert!(close(resolution, 300.0), "{resolution}");
        // The same number reaches the document, which is what an export writes back out.
        let document = raster.into_document(&crate::codec::ImportOptions::default());
        assert!(close(document.resolution, 300.0));
        std::fs::remove_dir_all(&directory).ok();
    }
}

