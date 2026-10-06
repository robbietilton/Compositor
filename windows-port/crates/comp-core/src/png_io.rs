//! PNG encode and decode for layer pixels (RGBA) and masks (8-bit gray).
//!
//! The format only accepts 8-bit PNGs: layer images are RGBA, masks are grayscale without alpha.
//! Assets come from untrusted packages, so the header is measured before any pixel buffer is
//! allocated and anything the format cannot hold is refused instead of approximated.
use crate::bitmap::{Bitmap8, Gray8};
use crate::error::{Error, Result};
use crate::limits;

/// The eight bytes every PNG starts with.
const SIGNATURE: [u8; 8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
/// Bytes needed before the IHDR fields are complete: signature, chunk length and type, 13 fields.
const HEADER_BYTES: usize = 29;
/// Room the decoder's row and chunk buffers need on top of the surface it is about to expand.
const DECODER_HEADROOM_BYTES: usize = 8 * 1024 * 1024;

/// What a PNG header says, before any pixels are touched.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PngHeader {
    pub width: u32,
    pub height: u32,
    pub bit_depth: u8,
    /// The color type byte as stored: 0 gray, 2 RGB, 3 palette, 4 gray+alpha, 6 RGBA.
    pub color_type: u8,
    pub interlaced: bool,
}

impl PngHeader {
    pub fn pixel_count(&self) -> u64 {
        self.width as u64 * self.height as u64
    }

    /// True when the file stores one sample per pixel, the only shape a mask may have.
    pub fn is_gray(&self) -> bool {
        self.color_type == 0
    }
}

/// Reads the header only, so a caller can reject an oversized or malformed asset before the
/// decoder allocates a buffer for it.
pub fn probe_png(bytes: &[u8]) -> Result<PngHeader> {
    if bytes.len() < HEADER_BYTES || bytes[..8] != SIGNATURE {
        return Err(Error::Decode("not a PNG file".into()));
    }
    if bytes[8..12] != [0, 0, 0, 13] || &bytes[12..16] != b"IHDR" {
        return Err(Error::Decode("a PNG must start with a 13-byte IHDR chunk".into()));
    }
    let width = u32::from_be_bytes([bytes[16], bytes[17], bytes[18], bytes[19]]);
    let height = u32::from_be_bytes([bytes[20], bytes[21], bytes[22], bytes[23]]);
    let bit_depth = bytes[24];
    let color_type = bytes[25];
    // Compression and filter methods have exactly one legal value each; interlace has two.
    if bytes[26] != 0 || bytes[27] != 0 || bytes[28] > 1 {
        return Err(Error::Decode("unknown PNG compression, filter or interlace method".into()));
    }
    if width == 0 || height == 0 {
        return Err(Error::Decode("a PNG cannot be empty".into()));
    }
    if !matches!(bit_depth, 1 | 2 | 4 | 8 | 16) || matches!(color_type, 1 | 5) || color_type > 6 {
        return Err(Error::Decode("unknown PNG bit depth or color type".into()));
    }
    Ok(PngHeader { width, height, bit_depth, color_type, interlaced: bytes[28] == 1 })
}

/// A decoded PNG, before it is turned into a layer image or a mask.
#[derive(Clone, Debug)]
pub struct DecodedPng {
    pub width: u32,
    pub height: u32,
    pub bit_depth: u8,
    /// Straight RGBA pixels when the file had color.
    pub rgba: Option<Vec<u8>>,
    /// Grayscale samples when the file was grayscale.
    pub gray: Option<Vec<u8>>,
}

impl DecodedPng {
    pub fn is_gray(&self) -> bool {
        self.gray.is_some()
    }

    /// True when the file held a single channel with no alpha: what a mask asset must be.
    pub fn is_gray_without_alpha(&self) -> bool {
        self.gray.is_some() && self.rgba.is_none()
    }

    /// The image as layer pixels: grayscale expands to opaque gray RGBA.
    pub fn to_bitmap8(&self) -> Result<Bitmap8> {
        if let Some(rgba) = &self.rgba {
            return Bitmap8::from_raw(self.width, self.height, rgba.clone());
        }
        let Some(gray) = &self.gray else { return Err(Error::Decode("no pixel data".into())) };
        let mut pixels = Vec::with_capacity(gray.len() * 4);
        for value in gray {
            pixels.extend_from_slice(&[*value, *value, *value, 255]);
        }
        Bitmap8::from_raw(self.width, self.height, pixels)
    }

    /// The image as a mask: color converts with Rec. 601 luma.
    pub fn to_gray8(&self) -> Result<Gray8> {
        if let Some(gray) = &self.gray {
            return Gray8::from_raw(self.width, self.height, gray.clone());
        }
        let Some(rgba) = &self.rgba else { return Err(Error::Decode("no pixel data".into())) };
        let pixels: Vec<u8> = rgba
            .chunks_exact(4)
            .map(|p| ((p[0] as u32 * 299 + p[1] as u32 * 587 + p[2] as u32 * 114) / 1000) as u8)
            .collect();
        Gray8::from_raw(self.width, self.height, pixels)
    }
}

/// Decodes a PNG of any 8-bit color type. Palette and low-bit-depth files are expanded.
pub fn decode_png(bytes: &[u8]) -> Result<DecodedPng> {
    let header = probe_png(bytes)?;
    // A decompression bomb is tiny on disk and enormous once expanded, and the format allows only
    // surfaces up to 200 megapixels, so the header decides before anything is allocated for it.
    if !limits::surface_fits(header.width, header.height) {
        return Err(Error::TooLarge(format!("PNG {}x{}", header.width, header.height)));
    }
    // The png crate budgets 64 MiB for its own buffers by default, which a legal surface can pass.
    let budget = decoder_budget(&header, bytes.len());
    let mut decoder = png::Decoder::new_with_limits(bytes, png::Limits { bytes: budget });
    // EXPAND turns palette entries, transparency chunks and sub-byte samples into plain samples.
    decoder.set_transformations(png::Transformations::EXPAND);
    let mut reader = decoder.read_info().map_err(|e| Error::Decode(e.to_string()))?;
    // One asset holds one frame; the macOS app asks ImageIO how many frames a file has and refuses
    // anything but one, so an animation must not be read as its first frame.
    let frames = reader
        .info()
        .animation_control
        .as_ref()
        .map(|control| control.num_frames)
        .unwrap_or(1);
    if frames > 1 {
        return Err(Error::Decode(format!("an animated PNG with {frames} frames is not supported")));
    }
    let mut buffer = vec![0u8; reader.output_buffer_size()];
    let frame = reader.next_frame(&mut buffer).map_err(|e| Error::Decode(e.to_string()))?;
    let width = frame.width;
    let height = frame.height;
    let bit_depth = frame.bit_depth as u8;
    // The frame reports the transformed color type, which is what the buffer actually holds.
    if bit_depth > 8 {
        return Err(Error::Decode(format!("{bit_depth}-bit PNG is not supported")));
    }
    let data = &buffer[..frame.buffer_size()];
    let pixel_count = width as usize * height as usize;
    let mut decoded = DecodedPng { width, height, bit_depth, rgba: None, gray: None };
    match frame.color_type {
        png::ColorType::Rgba => {
            if data.len() != pixel_count * 4 {
                return Err(Error::Decode("unexpected RGBA length".into()));
            }
            decoded.rgba = Some(data.to_vec());
        }
        png::ColorType::Rgb => {
            if data.len() != pixel_count * 3 {
                return Err(Error::Decode("unexpected RGB length".into()));
            }
            let mut rgba = Vec::with_capacity(pixel_count * 4);
            for chunk in data.chunks_exact(3) {
                rgba.extend_from_slice(&[chunk[0], chunk[1], chunk[2], 255]);
            }
            decoded.rgba = Some(rgba);
        }
        png::ColorType::Grayscale => {
            if data.len() != pixel_count {
                return Err(Error::Decode("unexpected grayscale length".into()));
            }
            decoded.gray = Some(data.to_vec());
        }
        png::ColorType::GrayscaleAlpha => {
            if data.len() != pixel_count * 2 {
                return Err(Error::Decode("unexpected gray+alpha length".into()));
            }
            let mut gray = Vec::with_capacity(pixel_count);
            let mut rgba = Vec::with_capacity(pixel_count * 4);
            for chunk in data.chunks_exact(2) {
                gray.push(chunk[0]);
                rgba.extend_from_slice(&[chunk[0], chunk[0], chunk[0], chunk[1]]);
            }
            decoded.gray = Some(gray);
            decoded.rgba = Some(rgba);
        }
        other => {
            return Err(Error::Decode(format!("unsupported PNG color type {other:?}")));
        }
    }
    Ok(decoded)
}

/// The decoder accounts for the row and chunk buffers it allocates, never for the output buffer
/// this module allocates, so its ceiling follows the surface the header promises.
fn decoder_budget(header: &PngHeader, encoded_len: usize) -> usize {
    let expanded = header.pixel_count().min(limits::MAX_SURFACE_PIXELS) as usize * 8;
    expanded
        .saturating_add(encoded_len.saturating_mul(4))
        .saturating_add(DECODER_HEADROOM_BYTES)
}

/// Encodes layer pixels as an 8-bit RGBA PNG.
pub fn encode_rgba8(bitmap: &Bitmap8) -> Result<Vec<u8>> {
    if bitmap.is_empty() {
        return Err(Error::encode_failed(None, "an image with no pixels cannot be saved"));
    }
    let mut out = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut out, bitmap.width(), bitmap.height());
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        // The caller knows which layer this is; the encoder only knows what went wrong.
        let mut writer = encoder
            .write_header()
            .map_err(|error| Error::encode_failed(None, error.to_string()))?;
        writer
            .write_image_data(bitmap.pixels())
            .map_err(|error| Error::encode_failed(None, error.to_string()))?;
    }
    Ok(out)
}

/// Encodes a mask as an 8-bit grayscale PNG.
pub fn encode_gray8(mask: &Gray8) -> Result<Vec<u8>> {
    if mask.is_empty() {
        return Err(Error::encode_failed(None, "a mask with no pixels cannot be saved"));
    }
    let mut out = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut out, mask.width(), mask.height());
        encoder.set_color(png::ColorType::Grayscale);
        encoder.set_depth(png::BitDepth::Eight);
        // The caller knows which layer this is; the encoder only knows what went wrong.
        let mut writer = encoder
            .write_header()
            .map_err(|error| Error::encode_failed(None, error.to_string()))?;
        writer
            .write_image_data(mask.pixels())
            .map_err(|error| Error::encode_failed(None, error.to_string()))?;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Builds a PNG with the png crate directly, for shapes the encoder helpers never write.
    fn encode_custom(
        width: u32,
        height: u32,
        color: png::ColorType,
        depth: png::BitDepth,
        data: &[u8],
        palette: Option<(Vec<u8>, Option<Vec<u8>>)>,
    ) -> Vec<u8> {
        let mut out = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut out, width, height);
            encoder.set_color(color);
            encoder.set_depth(depth);
            if let Some((colors, transparency)) = palette {
                encoder.set_palette(colors);
                if let Some(alpha) = transparency {
                    encoder.set_trns(alpha);
                }
            }
            let mut writer = encoder.write_header().unwrap();
            writer.write_image_data(data).unwrap();
        }
        out
    }

    /// One PNG chunk with the CRC the format requires, so hand-built files are accepted.
    fn chunk(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&(data.len() as u32).to_be_bytes());
        out.extend_from_slice(kind);
        out.extend_from_slice(data);
        let mut crc_input = Vec::from(&kind[..]);
        crc_input.extend_from_slice(data);
        out.extend_from_slice(&crc32(&crc_input).to_be_bytes());
        out
    }

    fn crc32(bytes: &[u8]) -> u32 {
        let mut crc = 0xFFFF_FFFFu32;
        for byte in bytes {
            crc ^= *byte as u32;
            for _ in 0..8 {
                let mask = (crc & 1).wrapping_neg();
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
            }
        }
        !crc
    }

    #[test]
    fn rgba_roundtrips_through_png() {
        let mut bitmap = Bitmap8::new(8, 4);
        bitmap.set(3, 2, [10, 20, 30, 200]);
        let bytes = encode_rgba8(&bitmap).unwrap();
        let decoded = decode_png(&bytes).unwrap();
        assert_eq!((decoded.width, decoded.height), (8, 4));
        assert_eq!(decoded.to_bitmap8().unwrap(), bitmap);
    }

    #[test]
    fn gray_mask_roundtrips_and_stays_gray() {
        let mut mask = Gray8::filled(5, 5, 255);
        mask.set(1, 1, 0);
        let bytes = encode_gray8(&mask).unwrap();
        let decoded = decode_png(&bytes).unwrap();
        assert!(decoded.is_gray());
        assert!(decoded.is_gray_without_alpha());
        assert_eq!(decoded.to_gray8().unwrap(), mask);
        let as_image = decoded.to_bitmap8().unwrap();
        assert_eq!(as_image.get(1, 1), [0, 0, 0, 255]);
        assert_eq!(as_image.get(0, 0), [255, 255, 255, 255]);
    }

    #[test]
    fn color_png_becomes_a_luma_mask() {
        let bitmap = Bitmap8::filled(2, 2, [255, 0, 0, 255]);
        let bytes = encode_rgba8(&bitmap).unwrap();
        let decoded = decode_png(&bytes).unwrap();
        assert!(!decoded.is_gray_without_alpha());
        let mask = decoded.to_gray8().unwrap();
        assert_eq!(mask.get(0, 0), 76);
    }

    #[test]
    fn garbage_is_rejected() {
        assert!(decode_png(b"not a png").is_err());
    }

    #[test]
    fn the_header_is_read_without_decoding_pixels() {
        let bitmap = Bitmap8::filled(7, 3, [1, 2, 3, 255]);
        let bytes = encode_rgba8(&bitmap).unwrap();
        let header = probe_png(&bytes).unwrap();
        assert_eq!((header.width, header.height), (7, 3));
        assert_eq!((header.bit_depth, header.color_type), (8, 6));
        assert!(!header.interlaced);
        assert!(header.is_gray() == false);
        // The header alone is enough, so an asset can be measured from a partial read.
        assert!(probe_png(&bytes[..HEADER_BYTES]).is_ok());
        assert!(probe_png(&bytes[..HEADER_BYTES - 1]).is_err());
        assert!(probe_png(b"\x89PNG\r\n\x1a\n").is_err());
    }

    #[test]
    fn a_palette_png_with_transparency_expands_to_rgba() {
        let palette = vec![255, 0, 0, 0, 255, 0, 0, 0, 255];
        let transparency = vec![0, 128, 255];
        let bytes = encode_custom(
            2,
            1,
            png::ColorType::Indexed,
            png::BitDepth::Eight,
            &[0, 1],
            Some((palette, Some(transparency))),
        );
        let decoded = decode_png(&bytes).unwrap();
        assert_eq!((decoded.width, decoded.height), (2, 1));
        assert_eq!(decoded.bit_depth, 8);
        assert_eq!(decoded.to_bitmap8().unwrap().get(0, 0), [255, 0, 0, 0]);
        assert_eq!(decoded.to_bitmap8().unwrap().get(1, 0), [0, 255, 0, 128]);
    }

    #[test]
    fn a_palette_png_without_transparency_expands_to_opaque_pixels() {
        let palette = vec![10, 20, 30, 40, 50, 60];
        let bytes = encode_custom(
            2,
            1,
            png::ColorType::Indexed,
            png::BitDepth::Four,
            &[0x01],
            Some((palette, None)),
        );
        let decoded = decode_png(&bytes).unwrap();
        assert_eq!(decoded.to_bitmap8().unwrap().get(0, 0), [10, 20, 30, 255]);
        assert_eq!(decoded.to_bitmap8().unwrap().get(1, 0), [40, 50, 60, 255]);
    }

    #[test]
    fn sub_byte_grayscale_expands_to_eight_bits() {
        // A 1-bit 8x8 checkerboard, one packed byte per row.
        let bytes = encode_custom(
            8,
            8,
            png::ColorType::Grayscale,
            png::BitDepth::One,
            &[0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55],
            None,
        );
        let decoded = decode_png(&bytes).unwrap();
        assert_eq!(decoded.bit_depth, 8);
        let mask = decoded.to_gray8().unwrap();
        assert_eq!(mask.get(0, 0), 255);
        assert_eq!(mask.get(1, 0), 0);
        assert_eq!(mask.get(0, 1), 0);
    }

    #[test]
    fn sixteen_bit_pngs_are_rejected() {
        let samples: Vec<u8> = (0..4u16).flat_map(|v| (v * 1000).to_be_bytes()).collect();
        let bytes = encode_custom(2, 2, png::ColorType::Grayscale, png::BitDepth::Sixteen, &samples, None);
        match decode_png(&bytes) {
            Err(Error::Decode(message)) => assert!(message.contains("16-bit"), "{message}"),
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn a_header_beyond_the_surface_limit_is_refused_before_decoding() {
        // Only the header is real: the pixels are never read, because the surface is too large.
        let mut bytes = Vec::from(SIGNATURE);
        let mut ihdr = Vec::new();
        ihdr.extend_from_slice(&20_000u32.to_be_bytes());
        ihdr.extend_from_slice(&20_000u32.to_be_bytes());
        ihdr.extend_from_slice(&[8, 6, 0, 0, 0]);
        bytes.extend_from_slice(&chunk(b"IHDR", &ihdr));
        assert_eq!(probe_png(&bytes).unwrap().pixel_count(), 400_000_000);
        match decode_png(&bytes) {
            Err(Error::TooLarge(message)) => assert!(message.contains("20000x20000"), "{message}"),
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn an_animated_png_is_rejected() {
        let bitmap = Bitmap8::filled(4, 4, [9, 8, 7, 255]);
        let plain = encode_rgba8(&bitmap).unwrap();
        // The animation control chunk is what makes ImageIO report more than one frame.
        let mut frames = Vec::new();
        frames.extend_from_slice(&2u32.to_be_bytes());
        frames.extend_from_slice(&0u32.to_be_bytes());
        let mut animated = plain[..33].to_vec();
        animated.extend_from_slice(&chunk(b"acTL", &frames));
        animated.extend_from_slice(&plain[33..]);
        match decode_png(&animated) {
            Err(Error::Decode(message)) => assert!(message.contains("animated"), "{message}"),
            other => panic!("unexpected {other:?}"),
        }
        assert!(decode_png(&plain).is_ok());
    }

    #[test]
    fn a_truncated_png_is_rejected() {
        let bitmap = Bitmap8::filled(16, 16, [4, 5, 6, 255]);
        let bytes = encode_rgba8(&bitmap).unwrap();
        assert!(decode_png(&bytes[..bytes.len() / 2]).is_err());
    }

    #[test]
    fn one_by_one_surfaces_roundtrip() {
        let pixel = Bitmap8::filled(1, 1, [12, 34, 56, 78]);
        let decoded = decode_png(&encode_rgba8(&pixel).unwrap()).unwrap();
        assert_eq!(decoded.to_bitmap8().unwrap(), pixel);

        let mask = Gray8::filled(1, 1, 200);
        let decoded = decode_png(&encode_gray8(&mask).unwrap()).unwrap();
        assert!(decoded.is_gray_without_alpha());
        assert_eq!(decoded.to_gray8().unwrap(), mask);
    }

    #[test]
    fn empty_surfaces_are_refused_by_the_encoder() {
        assert!(matches!(encode_rgba8(&Bitmap8::new(0, 0)), Err(Error::EncodeFailed { .. })));
        assert!(matches!(encode_gray8(&Gray8::new(4, 0)), Err(Error::EncodeFailed { .. })));
    }

    #[test]
    fn a_large_surface_still_decodes_past_the_decoder_default_budget() {
        // 4200x4100 RGBA is 68 MiB of pixels, over the png crate default of 64 MiB: without a limit
        // that follows the header this file would be refused although the format allows it.
        let bitmap = Bitmap8::filled(4200, 4100, [7, 7, 7, 255]);
        let bytes = encode_rgba8(&bitmap).unwrap();
        let decoded = decode_png(&bytes).unwrap();
        assert_eq!((decoded.width, decoded.height), (4200, 4100));
        assert_eq!(decoded.to_bitmap8().unwrap().get(4199, 4099), [7, 7, 7, 255]);
    }
}
