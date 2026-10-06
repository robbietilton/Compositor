//! Importing and exporting raster files other than PNG assets inside a package.
//!
//! PNG goes through comp_core::png_io so a decoded asset and an imported PNG cannot disagree;
//! JPEG, TIFF, BMP and WebP go through the 'image' crate, and an SVG is rasterized by resvg, as the
//! macOS app rasterizes one with its own renderer. Everything lands in a Bitmap8 (straight 8-bit
//! RGBA). Files wider than 8 bits are scaled rather than truncated, because ImageIO reads them
//! natively on macOS and a layer cannot hold them; float rasters have no such mapping and are
//! refused. See NOTES.md for the scaling choice.
use std::io::Cursor;
use std::path::Path;

use image::metadata::Orientation;
use image::{DynamicImage, ImageDecoder, ImageReader, RgbImage};
use zune_jpeg::zune_core::bytestream::ZCursor;
use zune_jpeg::zune_core::colorspace::ColorSpace;
use zune_jpeg::zune_core::options::DecoderOptions;
use zune_jpeg::{JpegDecoder, SampleRatios};

use comp_core::bitmap::Bitmap8;
use comp_core::document::Document;
use comp_core::geom::{PointF, Transform};
use comp_core::layer::Layer;
use comp_core::limits;
use comp_core::png_io;

use crate::error::{IoError, IoResult};
use crate::format::RasterFormat;
use crate::heic;
use crate::psd;
use crate::svg;

// The resolution readers live in a module of their own; they are re-exported here so a caller that
// already imports the codec keeps one path to them.
pub use crate::metadata::{
    read_bmp_resolution, read_jpeg_resolution, read_png_resolution, read_resolution,
    read_tiff_resolution, read_webp_resolution,
};

/// The PNG file signature.
pub const PNG_SIGNATURE: [u8; 8] = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
/// The byte offset just past the IHDR chunk of any well-formed PNG.
const PNG_IHDR_END: usize = 8 + 4 + 4 + 13 + 4;

/// What an import is allowed to spend, and where its resolution comes from.
#[derive(Clone, Debug)]
pub struct ImportOptions {
    /// Forces the document resolution. None keeps the file's own DPI, or 72 when it has none.
    pub resolution: Option<f64>,
    /// Applies the EXIF orientation, as the macOS importer does. Off is for callers that want
    /// the stored pixel grid, such as a batch converter.
    pub apply_orientation: bool,
    /// Pixels this import may still add to the document.
    pub remaining_pixels: u64,
}

impl Default for ImportOptions {
    fn default() -> Self {
        ImportOptions {
            resolution: None,
            apply_orientation: true,
            remaining_pixels: limits::document_pixel_budget(),
        }
    }
}

/// A decoded file, before it becomes a layer.
#[derive(Clone, Debug)]
pub struct ImportedRaster {
    pub image: Bitmap8,
    pub format: RasterFormat,
    /// Pixels per inch the file declares, when it declares one.
    pub resolution: Option<f64>,
    /// The file's stem, which names the layer macOS creates.
    pub name: String,
    /// True when EXIF orientation was applied to the pixels.
    pub orientation_applied: bool,
}

impl ImportedRaster {
    /// A document the size of the image holding it as its only layer.
    ///
    /// This mirrors macOS's EditorSession.insert: the first imported file sizes the canvas, and
    /// the layer covers it exactly.
    pub fn into_document(self, options: &ImportOptions) -> Document {
        let width = self.image.width();
        let height = self.image.height();
        let mut document = Document::new(width, height);
        document.resolution = document_resolution(options, self.resolution);
        let name = if self.name.is_empty() { "Layer".to_string() } else { self.name.clone() };
        document.add_layer(Layer::with_image(name, self.image), None);
        document
    }
}

/// Reads a file into layer pixels.
pub fn import_raster(path: impl AsRef<Path>, options: &ImportOptions) -> IoResult<ImportedRaster> {
    let path = path.as_ref();
    let bytes = std::fs::read(path)?;
    let mut raster = decode_raster(&bytes, options)?;
    // macOS names the layer after the file, not after any embedded title.
    raster.name = path
        .file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .filter(|stem| !stem.is_empty())
        .unwrap_or_else(|| "Layer".to_string());
    Ok(raster)
}

/// Reads a file into a document.
///
/// A raster file becomes a one-layer document the size of the image. A Photoshop file goes through
/// the Photoshop reader instead, keeping its layers, groups and masks; call
/// psd::read_psd_with_report when the conversion report matters.
pub fn import_document(path: impl AsRef<Path>) -> IoResult<Document> {
    import_document_with(path, &ImportOptions::default())
}

/// Reads a file into a document with explicit options.
pub fn import_document_with(path: impl AsRef<Path>, options: &ImportOptions) -> IoResult<Document> {
    let path = path.as_ref();
    let bytes = std::fs::read(path)?;
    if psd::matches(&bytes) {
        let read_options =
            psd::PsdReadOptions { remaining_pixels: options.remaining_pixels, strict: false };
        let mut import = psd::read_psd_with_options(&bytes, &read_options)?;
        if let Some(resolution) = options.resolution {
            import.document.resolution = resolution.clamp(1.0, 9600.0);
        }
        return Ok(import.document);
    }
    let mut raster = decode_raster(&bytes, options)?;
    raster.name = path
        .file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .filter(|stem| !stem.is_empty())
        .unwrap_or_else(|| "Layer".to_string());
    Ok(raster.into_document(options))
}

/// Reads a file into layer pixels only.
pub fn import_image(path: impl AsRef<Path>) -> IoResult<Bitmap8> {
    Ok(import_raster(path, &ImportOptions::default())?.image)
}

/// Adds an imported image to an existing document the way EditorSession.insert does: centered
/// on the canvas unless a drop point is given, inside the active group when one is active.
pub fn place_imported(
    document: &mut Document,
    raster: ImportedRaster,
    centered_at: Option<PointF>,
) -> IoResult<uuid::Uuid> {
    let (used_images, _) = document.pixel_counts();
    let added = raster.image.pixel_count() as u64;
    if used_images + added > limits::document_pixel_budget() {
        return Err(IoError::TooLarge(format!(
            "the document already holds {used_images} image pixels and this import adds {added}"
        )));
    }
    if document.layers.len() >= limits::MAX_LAYERS {
        return Err(IoError::TooLarge(format!(
            "a document holds at most {} layers",
            limits::MAX_LAYERS
        )));
    }
    let width = raster.image.width() as f64;
    let height = raster.image.height() as f64;
    let center = centered_at
        .unwrap_or_else(|| PointF::new(document.width as f64 / 2.0, document.height as f64 / 2.0));
    let name = if raster.name.is_empty() { "Layer".to_string() } else { raster.name.clone() };
    let mut layer = Layer::with_image(name, raster.image);
    layer.transform = Transform::new(
        PointF::new((center.x - width / 2.0).floor(), (center.y - height / 2.0).floor()),
        comp_core::geom::SizeF::new(width, height),
    );
    // A drop inside a group lands in that group; otherwise the layer joins the active sibling
    // level, which is what the macOS insert does.
    let parent = match document.active_layer.and_then(|id| document.layer(id)) {
        Some(active) if active.is_group => document.active_layer,
        Some(active) => active.parent,
        None => None,
    };
    Ok(document.add_layer(layer, parent))
}

/// Decodes raster bytes, sniffing the format from the signature.
pub fn decode_raster(bytes: &[u8], options: &ImportOptions) -> IoResult<ImportedRaster> {
    let format = RasterFormat::from_bytes(bytes)
        .ok_or_else(|| IoError::UnsupportedFormat("the file signature is not a supported image".into()))?;
    let (image, orientation_applied) = match format {
        RasterFormat::Png => {
            // The core codec owns 8-bit PNG: it expands palette and sub-8-bit files. The header is
            // measured first so an oversized file is refused before any buffer is allocated.
            let (width, height, bit_depth) = png_header(bytes)?;
            check_limits(width, height, options.remaining_pixels)?;
            if bit_depth > 8 {
                // 16-bit PNGs are native to ImageIO, so a gap here is a parity gap, not a limit of
                // the format. The samples are scaled to the 8 bits a layer holds.
                let wide = decode_sixteen_bit_png(bytes)?;
                check_limits(wide.width(), wide.height(), options.remaining_pixels)?;
                (wide_image_to_bitmap8(&wide)?, false)
            } else {
                let decoded = png_io::decode_png(bytes)?;
                check_limits(decoded.width, decoded.height, options.remaining_pixels)?;
                (decoded.to_bitmap8()?, false)
            }
        }
        // JPEG chroma planes are read directly, because the last column of a subsampled image has
        // to be rebuilt the way libjpeg (and so ImageIO) builds it. Files this path does not read
        // itself fall through to the image crate.
        RasterFormat::Jpeg => match decode_jpeg_planes(bytes, options)? {
            Some(decoded) => decoded,
            None => decode_with_image(bytes, options)?,
        },
        // HEIC, HEIF and AVIF have no pure-Rust decoder; the system's HEIF codec reads all three,
        // which is the Windows counterpart of the ImageIO path macOS uses. AVIF shares the container
        // and only differs in the codec inside it.
        RasterFormat::Heic | RasterFormat::Avif => heic::decode_heic(bytes, options)?,
        // Vector art is drawn once into pixels, exactly as macOS's SVG path does: nothing stays
        // vector, and the layer holds what the renderer produced.
        RasterFormat::Svg => (svg::decode_svg(bytes, options)?, false),
        _ => decode_with_image(bytes, options)?,
    };
    Ok(ImportedRaster {
        image,
        format,
        resolution: read_resolution(bytes, format),
        name: String::new(),
        orientation_applied,
    })
}

/// Decodes a JPEG whose sample planes can be read directly, so the chroma of the last column can
/// be rebuilt the way libjpeg does it.
///
/// Returns None for anything this path does not handle (CMYK and RGB-coded JPEGs, damaged files),
/// which then goes through the image crate and reports its errors as before.
fn decode_jpeg_planes(bytes: &[u8], options: &ImportOptions) -> IoResult<Option<(Bitmap8, bool)>> {
    let settings = || {
        DecoderOptions::default()
            .set_strict_mode(false)
            .set_max_width(limits::MAX_SIDE as usize)
            .set_max_height(limits::MAX_SIDE as usize)
    };
    let mut decoder = JpegDecoder::new_with_options(ZCursor::new(bytes), settings());
    if decoder.decode_headers().is_err() {
        return Ok(None);
    }
    let Some(width) = decoder.dimensions().map(|size| size.0) else { return Ok(None) };
    let height = decoder.dimensions().map(|size| size.1).unwrap_or(0);
    check_limits(width as u32, height as u32, options.remaining_pixels)?;
    let Some(input) = decoder.input_colorspace() else { return Ok(None) };
    // Only the two layouts whose planes this module converts itself.
    let target = match input {
        ColorSpace::YCbCr => ColorSpace::YCbCr,
        ColorSpace::Luma => ColorSpace::Luma,
        _ => return Ok(None),
    };
    decoder.set_options(settings().jpeg_set_out_colorspace(target));
    let mut planes = match decoder.decode() {
        Ok(planes) => planes,
        Err(_) => return Ok(None),
    };
    let pixels = width * height;
    let channels = if input == ColorSpace::YCbCr { 3 } else { 1 };
    if planes.len() != pixels * channels {
        return Ok(None);
    }
    let ratio = decoder.info().map(|info| info.sample_ratio).unwrap_or(SampleRatios::None);
    if input == ColorSpace::YCbCr {
        // An even width leaves the final output column without a neighbour on its right, and
        // libjpeg repeats the last chroma sample into it; zune-jpeg blends in a sample from the
        // padded MCU row instead, which no viewer of the file ever sees.
        if width % 2 == 0 && horizontally_subsampled(ratio) {
            repeat_last_chroma_column(&mut planes, width);
        }
        let mut rgb = vec![0u8; pixels * 3];
        for (index, pixel) in rgb.chunks_exact_mut(3).enumerate() {
            let start = index * 3;
            let converted = ycbcr_to_rgb(planes[start], planes[start + 1], planes[start + 2]);
            pixel.copy_from_slice(&converted);
        }
        planes = rgb;
    }
    let orientation = if options.apply_orientation {
        decoder
            .exif()
            .and_then(|exif| Orientation::from_exif_chunk(exif))
            .unwrap_or(Orientation::NoTransforms)
    } else {
        Orientation::NoTransforms
    };
    let mut dynamic = if input == ColorSpace::YCbCr {
        match RgbImage::from_raw(width as u32, height as u32, planes) {
            Some(buffer) => DynamicImage::ImageRgb8(buffer),
            None => return Ok(None),
        }
    } else {
        match image::GrayImage::from_raw(width as u32, height as u32, planes) {
            Some(buffer) => DynamicImage::ImageLuma8(buffer),
            None => return Ok(None),
        }
    };
    dynamic.apply_orientation(orientation);
    let rgba = dynamic.to_rgba8();
    let image = Bitmap8::from_raw(rgba.width(), rgba.height(), rgba.into_raw())?;
    Ok(Some((image, orientation != Orientation::NoTransforms)))
}

/// True when the chroma samples are half as wide as the luma samples.
///
/// The ratio describes the whole file: with horizontal subsampling the chroma plane is narrower
/// than the picture, which is the case the last column has to be corrected for.
fn horizontally_subsampled(ratio: SampleRatios) -> bool {
    match ratio {
        SampleRatios::H | SampleRatios::HV => true,
        SampleRatios::Generic(horizontal, _) => horizontal > 1,
        _ => false,
    }
}

/// Repeats the last chroma sample into the final column, the way libjpeg's fancy upsampling does.
///
/// Only the chroma channels move; luma is stored per pixel and never subsampled.
fn repeat_last_chroma_column(planes: &mut [u8], width: usize) {
    if width < 4 {
        return;
    }
    for row in planes.chunks_exact_mut(width * 3) {
        for channel in 1..3 {
            let before = row[(width - 3) * 3 + channel] as i32;
            let previous = row[(width - 2) * 3 + channel] as i32;
            if let Some(sample) = last_chroma_sample(previous, before) {
                row[(width - 1) * 3 + channel] = sample;
            }
        }
    }
}

/// The chroma sample the last two columns were filtered from.
///
/// libjpeg computes out[2k] = (3 * i + j + 1) >> 2 and out[2k-1] = (3 * j + i + 2) >> 2 for the
/// last sample i and its left neighbour j, so i follows from those two values. The candidates
/// around the algebraic answer are put back through both filters, so the integer rounding cannot
/// select a wrong one. Two neighbouring samples can share both filtered values, in which case the
/// answer is one level out, which is the resolution the file itself has left.
fn last_chroma_sample(out_even: i32, out_odd: i32) -> Option<u8> {
    let estimate = (3 * (4 * out_even - 1) - (4 * out_odd - 2)) as f64 / 8.0;
    let center = estimate.round() as i32;
    for sample in (center - 2)..=(center + 2) {
        if !(0..=255).contains(&sample) {
            continue;
        }
        for slack in 0..=3 {
            let neighbour = 4 * out_even - 1 + slack - 3 * sample;
            if !(0..=255).contains(&neighbour) {
                continue;
            }
            if (3 * sample + neighbour + 1) >> 2 == out_even && (3 * neighbour + sample + 2) >> 2 == out_odd {
                return Some(sample as u8);
            }
        }
    }
    None
}

/// YCbCr to straight RGB with libjpeg's fixed-point constants and rounding.
///
/// Both ImageIO and Pillow decode through libjpeg, so matching its arithmetic is what keeps the
/// pixels the same; the tables libjpeg builds are these products shifted right by 16 with one half
/// added for rounding.
fn ycbcr_to_rgb(y: u8, cb: u8, cr: u8) -> [u8; 3] {
    let y = y as i32;
    let cb = cb as i32 - 128;
    let cr = cr as i32 - 128;
    const ONE_HALF: i32 = 1 << 15;
    let red = y + ((91_881 * cr + ONE_HALF) >> 16);
    let green = y + ((-(22_554 * cb + 46_802 * cr) + ONE_HALF) >> 16);
    let blue = y + ((116_130 * cb + ONE_HALF) >> 16);
    [clamp_channel(red), clamp_channel(green), clamp_channel(blue)]
}

fn clamp_channel(value: i32) -> u8 {
    value.clamp(0, 255) as u8
}

/// JPEG, TIFF, BMP and WebP, through the image crate.
fn decode_with_image(bytes: &[u8], options: &ImportOptions) -> IoResult<(Bitmap8, bool)> {
    let (width, height) = open(bytes)?.into_dimensions().map_err(unreadable)?;
    check_limits(width, height, options.remaining_pixels)?;
    let mut decoder = open(bytes)?.into_decoder().map_err(unreadable)?;
    // A malformed EXIF block must not fail the import: macOS falls back to orientation 1.
    let orientation = if options.apply_orientation {
        decoder.orientation().unwrap_or(Orientation::NoTransforms)
    } else {
        Orientation::NoTransforms
    };
    let mut dynamic = DynamicImage::from_decoder(decoder).map_err(unreadable)?;
    dynamic.apply_orientation(orientation);
    let image = if is_sixteen_bit(&dynamic) {
        // A 16-bit TIFF or PNG from a scanner is a normal file to open on macOS, so it is scaled
        // rather than refused; the pixels are what a layer can hold.
        wide_image_to_bitmap8(&dynamic)?
    } else {
        if let Some(depth) = unsupported_depth(&dynamic) {
            return Err(IoError::UnsupportedDepth(format!(
                "{depth}, {}x{}",
                dynamic.width(),
                dynamic.height()
            )));
        }
        let rgba = dynamic.to_rgba8();
        Bitmap8::from_raw(rgba.width(), rgba.height(), rgba.into_raw())?
    };
    check_limits(image.width(), image.height(), options.remaining_pixels)?;
    Ok((image, orientation != Orientation::NoTransforms))
}

/// Decodes a 16-bit PNG through the image crate, which keeps the samples at full width.
///
/// comp_core::png_io deliberately refuses anything wider than 8 bits, because a package asset may
/// not be one; an imported file may.
fn decode_sixteen_bit_png(bytes: &[u8]) -> IoResult<DynamicImage> {
    let decoder = image::codecs::png::PngDecoder::new(Cursor::new(bytes)).map_err(unreadable)?;
    DynamicImage::from_decoder(decoder).map_err(unreadable)
}

/// True for the images whose samples are 16 bits wide.
fn is_sixteen_bit(image: &DynamicImage) -> bool {
    matches!(
        image,
        DynamicImage::ImageLuma16(_)
            | DynamicImage::ImageLumaA16(_)
            | DynamicImage::ImageRgb16(_)
            | DynamicImage::ImageRgba16(_)
    )
}

/// Scales a 16-bit image down to the 8-bit straight RGBA a layer holds.
///
/// macOS renders these through ImageIO into the same 8-bit layer pixels, so this is a conversion,
/// not a refusal. Alpha stays straight, exactly as the file stores it.
fn wide_image_to_bitmap8(image: &DynamicImage) -> IoResult<Bitmap8> {
    let (width, height) = (image.width(), image.height());
    let mut pixels = Vec::with_capacity(width as usize * height as usize * 4);
    match image {
        DynamicImage::ImageLuma16(buffer) => {
            for &value in buffer.as_raw() {
                let gray = scale_sixteen_bit(value);
                pixels.extend_from_slice(&[gray, gray, gray, 255]);
            }
        }
        DynamicImage::ImageLumaA16(buffer) => {
            for chunk in buffer.as_raw().chunks_exact(2) {
                let gray = scale_sixteen_bit(chunk[0]);
                pixels.extend_from_slice(&[gray, gray, gray, scale_sixteen_bit(chunk[1])]);
            }
        }
        DynamicImage::ImageRgb16(buffer) => {
            for chunk in buffer.as_raw().chunks_exact(3) {
                pixels.extend_from_slice(&[
                    scale_sixteen_bit(chunk[0]),
                    scale_sixteen_bit(chunk[1]),
                    scale_sixteen_bit(chunk[2]),
                    255,
                ]);
            }
        }
        DynamicImage::ImageRgba16(buffer) => {
            for chunk in buffer.as_raw().chunks_exact(4) {
                pixels.extend_from_slice(&[
                    scale_sixteen_bit(chunk[0]),
                    scale_sixteen_bit(chunk[1]),
                    scale_sixteen_bit(chunk[2]),
                    scale_sixteen_bit(chunk[3]),
                ]);
            }
        }
        other => {
            return Err(IoError::UnsupportedDepth(format!(
                "{}, {}x{}",
                unsupported_depth(other).unwrap_or("an unsupported depth"),
                width,
                height
            )));
        }
    }
    Ok(Bitmap8::from_raw(width, height, pixels)?)
}

/// One 16-bit sample as 8 bits, rounded to the nearest level.
///
/// The exact scale is v * 255 / 65535, which is v / 257: 65535 maps to 255 and 0 to 0, and the
/// rounding keeps every one of the 256 levels reachable. Taking the high byte instead would floor
/// the value (1 through 256 would all become 0) and is not the curve ImageIO and Pillow use.
fn scale_sixteen_bit(value: u16) -> u8 {
    ((value as u32 * 255 + 32_767) / 65_535) as u8
}

fn open(bytes: &[u8]) -> IoResult<ImageReader<Cursor<&[u8]>>> {
    let reader = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .map_err(|error| IoError::Unreadable(error.to_string()))?;
    if reader.format().is_none() {
        return Err(IoError::UnsupportedFormat("the file signature is not a supported image".into()));
    }
    Ok(reader)
}

fn unreadable(error: image::ImageError) -> IoError {
    IoError::Unreadable(error.to_string())
}

/// The depth name of a DynamicImage this crate cannot store, if any.
///
/// 16-bit images are scaled, not refused; a float raster has no 8-bit mapping that would not
/// invent a tone curve, so it stays an explicit error.
fn unsupported_depth(image: &DynamicImage) -> Option<&'static str> {
    match image {
        DynamicImage::ImageRgb32F(_) | DynamicImage::ImageRgba32F(_) => Some("32-bit float"),
        _ => None,
    }
}

/// Applies the format's size limits, which match DocumentLimits in the macOS app.
pub fn check_limits(width: u32, height: u32, remaining_pixels: u64) -> IoResult<()> {
    if width == 0 || height == 0 {
        return Err(IoError::Unreadable(format!("the image is {width}x{height}")));
    }
    if !limits::surface_fits(width, height) {
        return Err(IoError::TooLarge(format!(
            "{width}x{height} exceeds {} pixels per side or {} pixels in one surface",
            limits::MAX_SIDE,
            limits::MAX_SURFACE_PIXELS
        )));
    }
    let pixels = width as u64 * height as u64;
    if pixels > remaining_pixels {
        return Err(IoError::TooLarge(format!(
            "the document has room for {remaining_pixels} more pixels; this image needs {pixels}"
        )));
    }
    Ok(())
}

/// The width, height and bit depth from a PNG's IHDR, before any pixel buffer is allocated.
fn png_header(bytes: &[u8]) -> IoResult<(u32, u32, u8)> {
    if !bytes.starts_with(&PNG_SIGNATURE) {
        return Err(IoError::Unreadable("the file does not start with a PNG signature".into()));
    }
    if bytes.len() < PNG_IHDR_END || &bytes[12..16] != b"IHDR" {
        return Err(IoError::Unreadable("the PNG header is damaged".into()));
    }
    let width = be_u32(&bytes[16..20]).unwrap_or(0);
    let height = be_u32(&bytes[20..24]).unwrap_or(0);
    Ok((width, height, bytes[24]))
}

/// Encodes layer pixels as an 8-bit RGBA PNG carrying the resolution in a pHYs chunk.
pub fn encode_png(image: &Bitmap8, resolution: f64) -> IoResult<Vec<u8>> {
    if image.is_empty() {
        return Err(IoError::Invalid("an image with no pixels cannot be exported".into()));
    }
    check_limits(image.width(), image.height(), u64::MAX)?;
    let pixels_per_meter = pixels_per_meter(resolution)?;
    let png = png_io::encode_rgba8(image)?;
    insert_phys_chunk(&png, pixels_per_meter)
}

/// Writes layer pixels to a PNG file.
pub fn export_png(image: &Bitmap8, path: impl AsRef<Path>, resolution: f64) -> IoResult<()> {
    let bytes = encode_png(image, resolution)?;
    std::fs::write(path, bytes)?;
    Ok(())
}

/// How export_jpeg flattens and compresses.
#[derive(Clone, Copy, Debug)]
pub struct JpegOptions {
    /// 0 through 100. JPEG always loses something; 0 is the most lossy setting the encoder has.
    pub quality: u8,
    /// Pixels per inch, written to the JFIF header.
    pub resolution: f64,
    /// JPEG has no alpha, so transparent pixels take this color. macOS fills white.
    pub background: [u8; 3],
}

impl Default for JpegOptions {
    fn default() -> Self {
        // macOS's JPEGOptions default is 0.85 over white.
        JpegOptions { quality: 85, resolution: 72.0, background: [255, 255, 255] }
    }
}

/// Encodes layer pixels as a JPEG, flattening alpha over the background color.
pub fn encode_jpeg(image: &Bitmap8, options: &JpegOptions) -> IoResult<Vec<u8>> {
    if image.is_empty() {
        return Err(IoError::Invalid("an image with no pixels cannot be exported".into()));
    }
    if options.quality > 100 {
        return Err(IoError::Invalid(format!("JPEG quality {} is outside 0-100", options.quality)));
    }
    // JPEG's frame header stores the size in 16 bits.
    if image.width() > u16::MAX as u32 || image.height() > u16::MAX as u32 {
        return Err(IoError::TooLarge(format!(
            "JPEG supports at most {} pixels per side; this image is {}x{}",
            u16::MAX,
            image.width(),
            image.height()
        )));
    }
    check_limits(image.width(), image.height(), u64::MAX)?;
    let dpi = {
        pixels_per_meter(options.resolution)?;
        (options.resolution.round() as u32).min(u16::MAX as u32) as u16
    };
    let flattened = flatten_over_background(image, options.background);
    let mut out = Vec::new();
    let mut encoder = jpeg_encoder::Encoder::new(&mut out, options.quality);
    encoder.set_density(jpeg_encoder::Density::Inch { x: dpi, y: dpi });
    encoder
        .encode(&flattened, image.width() as u16, image.height() as u16, jpeg_encoder::ColorType::Rgb)
        .map_err(|error| IoError::Unreadable(format!("the JPEG could not be encoded: {error}")))?;
    Ok(out)
}

/// Writes layer pixels to a JPEG file over a white background.
pub fn export_jpeg(image: &Bitmap8, path: impl AsRef<Path>, quality: u8, resolution: f64) -> IoResult<()> {
    let bytes = encode_jpeg(image, &JpegOptions { quality, resolution, ..JpegOptions::default() })?;
    std::fs::write(path, bytes)?;
    Ok(())
}

/// Straight RGBA over an opaque color, the same composite macOS's JPEG export draws.
pub fn flatten_over_background(image: &Bitmap8, background: [u8; 3]) -> Vec<u8> {
    let mut out = Vec::with_capacity(image.pixel_count() * 3);
    for pixel in image.pixels().chunks_exact(4) {
        let alpha = pixel[3] as u32;
        let inverse = 255 - alpha;
        for channel in 0..3 {
            let blended = (pixel[channel] as u32 * alpha + background[channel] as u32 * inverse + 127) / 255;
            out.push(blended.min(255) as u8);
        }
    }
    out
}

/// The document resolution an import uses: an explicit override, the file's own DPI, or 72.
fn document_resolution(options: &ImportOptions, file_resolution: Option<f64>) -> f64 {
    options
        .resolution
        .or(file_resolution)
        .filter(|value| value.is_finite())
        .unwrap_or(72.0)
        .clamp(1.0, 9600.0)
}

/// Pixels per inch to the PNG pHYs unit, rejecting resolutions the format forbids.
fn pixels_per_meter(resolution: f64) -> IoResult<u32> {
    if !resolution.is_finite() || !(1.0..=9600.0).contains(&resolution) {
        return Err(IoError::Invalid(format!(
            "resolution {resolution} is outside the 1-9600 pixels per inch the format allows"
        )));
    }
    Ok(((resolution / 0.0254).round() as u32).max(1))
}

/// Inserts a pHYs chunk directly after IHDR.
///
/// comp_core::png_io owns pixel encoding but writes no metadata, so the chunk is spliced in
/// rather than re-encoding the image through a second PNG writer.
fn insert_phys_chunk(png: &[u8], pixels_per_meter: u32) -> IoResult<Vec<u8>> {
    if !png.starts_with(&PNG_SIGNATURE) {
        return Err(IoError::Unreadable("the encoded PNG has no signature".into()));
    }
    if png.len() < PNG_IHDR_END || &png[12..16] != b"IHDR" {
        return Err(IoError::Unreadable("the encoded PNG has no IHDR".into()));
    }
    let mut body = Vec::with_capacity(13);
    body.extend_from_slice(b"pHYs");
    body.extend_from_slice(&pixels_per_meter.to_be_bytes());
    body.extend_from_slice(&pixels_per_meter.to_be_bytes());
    body.push(1); // Unit 1: pixels per metre, the only absolute unit pHYs defines.
    let crc = crc32(&body);

    let mut out = Vec::with_capacity(png.len() + 21);
    out.extend_from_slice(&png[..PNG_IHDR_END]);
    out.extend_from_slice(&9u32.to_be_bytes());
    out.extend_from_slice(&body);
    out.extend_from_slice(&crc.to_be_bytes());
    out.extend_from_slice(&png[PNG_IHDR_END..]);
    Ok(out)
}

/// The CRC-32 every PNG chunk carries.
///
/// The png crate is not a direct dependency of this crate, and one checksum does not justify
/// adding one.
fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for &byte in bytes {
        crc ^= byte as u32;
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    !crc
}

fn be_u32(bytes: &[u8]) -> Option<u32> {
    Some(u32::from_be_bytes([*bytes.first()?, *bytes.get(1)?, *bytes.get(2)?, *bytes.get(3)?]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::codecs::bmp::BmpEncoder;
    use image::codecs::jpeg::JpegEncoder;
    use image::codecs::tiff::TiffEncoder;
    use image::codecs::webp::WebPEncoder;
    use image::{ExtendedColorType, ImageEncoder};

    /// A small image with every alpha level, so flattening and round trips are visible.
    fn sample(width: u32, height: u32) -> Bitmap8 {
        let mut image = Bitmap8::new(width, height);
        for y in 0..height {
            for x in 0..width {
                image.set(
                    x,
                    y,
                    [(x * 7 % 256) as u8, (y * 11 % 256) as u8, ((x + y) * 5 % 256) as u8, (x * 64 % 256) as u8],
                );
            }
        }
        image
    }

    fn encode_with<E: FnOnce(&mut Vec<u8>)>(encoder: E) -> Vec<u8> {
        let mut out = Vec::new();
        encoder(&mut out);
        out
    }

    /// The TIFF encoder needs to seek back to patch its directory, so it writes through a cursor.
    fn tiff_bytes(image: &Bitmap8) -> Vec<u8> {
        let mut cursor = Cursor::new(Vec::new());
        TiffEncoder::new(&mut cursor)
            .write_image(image.pixels(), image.width(), image.height(), ExtendedColorType::Rgba8)
            .unwrap();
        cursor.into_inner()
    }

    fn round_trip(bytes: &[u8]) -> ImportedRaster {
        decode_raster(bytes, &ImportOptions::default()).expect("decode")
    }

    #[test]
    fn bmp_round_trips_through_the_importer() {
        let image = Bitmap8::filled(6, 4, [10, 200, 30, 255]);
        let bytes = encode_with(|out| {
            BmpEncoder::new(out)
                .write_image(image.pixels(), image.width(), image.height(), ExtendedColorType::Rgba8)
                .unwrap();
        });
        let raster = round_trip(&bytes);
        assert_eq!(raster.format, RasterFormat::Bmp);
        assert_eq!((raster.image.width(), raster.image.height()), (6, 4));
        assert_eq!(raster.image.get(3, 2), [10, 200, 30, 255]);
    }

    #[test]
    fn tiff_round_trips_through_the_importer() {
        let image = sample(5, 3);
        let bytes = tiff_bytes(&image);
        let raster = round_trip(&bytes);
        assert_eq!(raster.format, RasterFormat::Tiff);
        assert_eq!(raster.image, image);
    }

    #[test]
    fn webp_round_trips_through_the_importer() {
        let image = sample(4, 4);
        let bytes = encode_with(|out| {
            WebPEncoder::new_lossless(out)
                .write_image(image.pixels(), image.width(), image.height(), ExtendedColorType::Rgba8)
                .unwrap();
        });
        let raster = round_trip(&bytes);
        assert_eq!(raster.format, RasterFormat::WebP);
        assert_eq!(raster.image, image);
    }

    #[test]
    fn jpeg_round_trip_keeps_the_picture_close() {
        let image = Bitmap8::filled(16, 16, [200, 40, 40, 255]);
        let bytes = encode_jpeg(&image, &JpegOptions { quality: 92, ..JpegOptions::default() }).unwrap();
        let raster = round_trip(&bytes);
        assert_eq!(raster.format, RasterFormat::Jpeg);
        assert_eq!((raster.image.width(), raster.image.height()), (16, 16));
        let center = raster.image.get(8, 8);
        assert!(center[0] > 185 && center[0] < 215, "{center:?}");
        assert!(center[1] < 60 && center[2] < 60, "{center:?}");
    }

    #[test]
    fn jpeg_flattens_alpha_over_white() {
        let image = Bitmap8::filled(4, 4, [0, 0, 0, 0]);
        let bytes = encode_jpeg(&image, &JpegOptions { quality: 100, ..JpegOptions::default() }).unwrap();
        let raster = round_trip(&bytes);
        let pixel = raster.image.get(1, 1);
        assert!(pixel[0] > 240 && pixel[1] > 240 && pixel[2] > 240, "{pixel:?}");
    }

    #[test]
    fn quality_zero_is_allowed_and_lossier_than_one_hundred() {
        let image = sample(32, 32);
        let low = encode_jpeg(&image, &JpegOptions { quality: 0, ..JpegOptions::default() }).unwrap();
        let high = encode_jpeg(&image, &JpegOptions { quality: 100, ..JpegOptions::default() }).unwrap();
        assert!(low.len() < high.len());
        assert!(decode_raster(&low, &ImportOptions::default()).is_ok());
    }

    #[test]
    fn garbage_and_truncated_files_are_rejected() {
        assert!(matches!(
            decode_raster(b"not an image at all", &ImportOptions::default()),
            Err(IoError::UnsupportedFormat(_))
        ));
        let image = Bitmap8::filled(8, 8, [1, 2, 3, 255]);
        let png = encode_png(&image, 72.0).unwrap();
        let cut = &png[..png.len() / 2];
        assert!(decode_raster(cut, &ImportOptions::default()).is_err());
    }

    /// A 16-bit PNG built with the png crate, for the samples a test wants to check.
    fn sixteen_bit_png(width: u32, height: u32, color: png::ColorType, samples: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        {
            let mut encoder = png::Encoder::new(&mut out, width, height);
            encoder.set_color(color);
            encoder.set_depth(png::BitDepth::Sixteen);
            let mut writer = encoder.write_header().unwrap();
            writer.write_image_data(samples).unwrap();
        }
        out
    }

    fn wide_bytes(values: &[u16]) -> Vec<u8> {
        values.iter().flat_map(|value| value.to_be_bytes()).collect()
    }

    #[test]
    fn sixteen_bit_gray_png_scales_with_rounding() {
        // Every value is one the high-byte shortcut would get wrong, plus both ends of the range.
        let values: [u16; 8] = [0, 1, 128, 129, 32_768, 25_829, 65_407, 65_535];
        let bytes = sixteen_bit_png(8, 1, png::ColorType::Grayscale, &wide_bytes(&values));
        let raster = round_trip(&bytes);
        assert_eq!(raster.format, RasterFormat::Png);
        let expected = [0u8, 0, 0, 1, 128, 101, 255, 255];
        for (x, level) in expected.iter().enumerate() {
            assert_eq!(raster.image.get(x as u32, 0), [*level, *level, *level, 255], "sample {x}");
        }
    }

    #[test]
    fn the_sixteen_bit_scale_rounds_rather_than_truncating() {
        assert_eq!(scale_sixteen_bit(0), 0);
        assert_eq!(scale_sixteen_bit(1), 0);
        assert_eq!(scale_sixteen_bit(128), 0);
        assert_eq!(scale_sixteen_bit(129), 1);
        assert_eq!(scale_sixteen_bit(257), 1);
        assert_eq!(scale_sixteen_bit(32_768), 128);
        assert_eq!(scale_sixteen_bit(32_896), 128);
        assert_eq!(scale_sixteen_bit(32_897), 128);
        assert_eq!(scale_sixteen_bit(33_025), 129);
        assert_eq!(scale_sixteen_bit(65_407), 255);
        assert_eq!(scale_sixteen_bit(65_535), 255);
        // The high byte alone would send a value of 255 to black.
        assert_ne!(scale_sixteen_bit(255), (255u16 >> 8) as u8);
    }

    #[test]
    fn sixteen_bit_rgba_png_keeps_straight_alpha_and_color() {
        let samples = wide_bytes(&[
            65_535, 0, 0, 65_535,
            0, 65_535, 0, 32_768,
            0, 0, 65_535, 0,
            32_768, 32_768, 32_768, 129,
        ]);
        let bytes = sixteen_bit_png(4, 1, png::ColorType::Rgba, &samples);
        let image = round_trip(&bytes).image;
        assert_eq!(image.get(0, 0), [255, 0, 0, 255]);
        assert_eq!(image.get(1, 0), [0, 255, 0, 128]);
        assert_eq!(image.get(2, 0), [0, 0, 255, 0]);
        assert_eq!(image.get(3, 0), [128, 128, 128, 1]);
    }

    #[test]
    fn sixteen_bit_gray_alpha_png_scales_both_channels() {
        let samples = wide_bytes(&[65_535, 0, 0, 65_535, 32_768, 32_768, 1, 129]);
        let bytes = sixteen_bit_png(4, 1, png::ColorType::GrayscaleAlpha, &samples);
        let image = round_trip(&bytes).image;
        assert_eq!(image.get(0, 0), [255, 255, 255, 0]);
        assert_eq!(image.get(1, 0), [0, 0, 0, 255]);
        assert_eq!(image.get(2, 0), [128, 128, 128, 128]);
        assert_eq!(image.get(3, 0), [0, 0, 0, 1]);
    }

    #[test]
    fn a_sixteen_bit_png_sizes_the_document_like_any_other() {
        let samples = wide_bytes(&[1_000, 2_000, 3_000, 4_000, 5_000, 6_000]);
        let bytes = sixteen_bit_png(3, 2, png::ColorType::Grayscale, &samples);
        let options = ImportOptions::default();
        let document = decode_raster(&bytes, &options).unwrap().into_document(&options);
        assert_eq!((document.width, document.height), (3, 2));
        assert_eq!(document.layers.len(), 1);
        assert_eq!(document.layers[0].image.as_ref().unwrap().get(2, 1), [23, 23, 23, 255]);
    }

    #[test]
    fn a_sixteen_bit_png_beyond_the_budget_is_refused_before_decoding() {
        let samples = wide_bytes(&[0; 16]);
        let bytes = sixteen_bit_png(4, 4, png::ColorType::Grayscale, &samples);
        let options = ImportOptions { remaining_pixels: 8, ..ImportOptions::default() };
        assert!(matches!(decode_raster(&bytes, &options), Err(IoError::TooLarge(_))));
    }

    #[test]
    fn a_damaged_sixteen_bit_png_is_refused() {
        let samples = wide_bytes(&[12_345; 16]);
        let bytes = sixteen_bit_png(4, 4, png::ColorType::Grayscale, &samples);
        let cut = &bytes[..bytes.len() / 2];
        assert!(matches!(decode_raster(cut, &ImportOptions::default()), Err(IoError::Unreadable(_))));
    }

    #[test]
    fn sixteen_bit_tiff_is_scaled_too() {
        let samples: Vec<u16> = (0..16u16).map(|value| value * 4_000).collect();
        // TIFF stores samples in the machine's byte order, not the network order PNG uses.
        let bytes: Vec<u8> = samples.iter().flat_map(|value| value.to_le_bytes()).collect();
        let mut cursor = Cursor::new(Vec::new());
        TiffEncoder::new(&mut cursor)
            .write_image(&bytes, 2, 2, ExtendedColorType::Rgba16)
            .unwrap();
        let raster = round_trip(&cursor.into_inner());
        assert_eq!(raster.format, RasterFormat::Tiff);
        // 0, 4000, 8000, 12000 scaled by round(value * 255 / 65535).
        assert_eq!(raster.image.get(0, 0), [0, 16, 31, 47]);
        assert_eq!(raster.image.get(1, 0), [62, 78, 93, 109]);
    }

    #[test]
    fn a_float_raster_is_still_refused() {
        let float = DynamicImage::ImageRgba32F(image::ImageBuffer::new(1, 1));
        assert_eq!(unsupported_depth(&float), Some("32-bit float"));
        assert!(!is_sixteen_bit(&float));
        assert!(matches!(
            wide_image_to_bitmap8(&float),
            Err(IoError::UnsupportedDepth(_))
        ));
    }

    #[test]
    fn the_ycbcr_conversion_matches_libjpeg() {
        assert_eq!(ycbcr_to_rgb(128, 128, 128), [128, 128, 128]);
        assert_eq!(ycbcr_to_rgb(0, 128, 128), [0, 0, 0]);
        assert_eq!(ycbcr_to_rgb(255, 128, 128), [255, 255, 255]);
        // The standard full-range conversion, within the one level its rounding can move.
        for (y, cb, cr) in [(76u8, 85u8, 255u8), (150, 44, 21), (29, 255, 107)] {
            let [red, green, blue] = ycbcr_to_rgb(y, cb, cr);
            let yf = y as f64;
            let cbf = cb as f64 - 128.0;
            let crf = cr as f64 - 128.0;
            let expected = [
                yf + 1.402 * crf,
                yf - 0.344_136 * cbf - 0.714_136 * crf,
                yf + 1.772 * cbf,
            ];
            for (actual, wanted) in [red, green, blue].iter().zip(expected.iter()) {
                assert!(
                    (*actual as f64 - wanted.clamp(0.0, 255.0)).abs() <= 1.0,
                    "{actual} is not {wanted}"
                );
            }
        }
        // Inputs outside the range clamp rather than wrap around.
        assert_eq!(ycbcr_to_rgb(0, 0, 0), [0, 135, 0]);
        assert_eq!(ycbcr_to_rgb(255, 255, 255), [255, 121, 255]);
    }

    #[test]
    fn the_last_chroma_sample_follows_from_the_two_columns_before_it() {
        for sample in [0u8, 1, 37, 128, 200, 254, 255] {
            for neighbour in [0u8, 12, 128, 255] {
                let (sample, neighbour) = (sample as i32, neighbour as i32);
                // What libjpeg writes for the last even column and the odd one before it.
                let out_even = (3 * sample + neighbour + 1) >> 2;
                let out_odd = (3 * neighbour + sample + 2) >> 2;
                let recovered = last_chroma_sample(out_even, out_odd).expect("a sample");
                // Two neighbouring samples can share both filtered values, so the answer may be
                // one level out; what matters is that the column ends up within one level.
                assert!(
                    (recovered as i32 - sample).abs() <= 1,
                    "sample {sample} neighbour {neighbour} came back as {recovered}"
                );
            }
        }
    }

    #[test]
    fn the_last_chroma_column_repeats_that_sample() {
        // Four pixels wide: two chroma samples, the last covering the final column. A decoder that
        // upsamples the padded row leaves a sample from outside the picture there.
        let (first, last) = (60i32, 200i32);
        let mut planes = vec![0u8; 4 * 3];
        for (x, sample) in [(0usize, first), (1, (3 * first + last + 2) >> 2), (2, (3 * last + first + 1) >> 2), (3, 30)] {
            planes[x * 3 + 1] = sample as u8;
            planes[x * 3 + 2] = sample as u8;
        }
        repeat_last_chroma_column(&mut planes, 4);
        assert_eq!(planes[3 * 3 + 1], 200);
        assert_eq!(planes[3 * 3 + 2], 200);
        // The columns that were already right are untouched.
        assert_eq!(planes[1 * 3 + 1], 95);
        assert_eq!(planes[2 * 3 + 1], 165);
    }

    /// A little-endian Exif APP1 segment carrying only an orientation tag, for a JPEG splice.
    fn exif_orientation_segment(orientation: u16) -> Vec<u8> {
        let mut tiff = Vec::new();
        tiff.extend_from_slice(b"II\x2a\x00");
        tiff.extend_from_slice(&8u32.to_le_bytes());
        tiff.extend_from_slice(&1u16.to_le_bytes());
        tiff.extend_from_slice(&0x0112u16.to_le_bytes());
        tiff.extend_from_slice(&3u16.to_le_bytes());
        tiff.extend_from_slice(&1u32.to_le_bytes());
        tiff.extend_from_slice(&orientation.to_le_bytes());
        tiff.extend_from_slice(&0u16.to_le_bytes());
        tiff.extend_from_slice(&0u32.to_le_bytes());
        let mut payload = Vec::from(b"Exif\x00\x00".as_slice());
        payload.extend_from_slice(&tiff);
        let mut segment = vec![0xFF, 0xE1];
        segment.extend_from_slice(&((payload.len() + 2) as u16).to_be_bytes());
        segment.extend_from_slice(&payload);
        segment
    }

    #[test]
    fn a_jpeg_with_an_exif_orientation_is_still_rotated_on_import() {
        // The top-left quarter is red, so a clockwise quarter turn puts it top right.
        let mut source = Bitmap8::new(4, 4);
        for y in 0..4 {
            for x in 0..4 {
                let color = if x < 2 && y < 2 { [255, 0, 0, 255] } else { [0, 0, 0, 255] };
                source.set(x, y, color);
            }
        }
        let jpeg = encode_jpeg(&source, &JpegOptions { quality: 100, ..JpegOptions::default() }).unwrap();
        let mut tagged = jpeg[..2].to_vec();
        tagged.extend_from_slice(&exif_orientation_segment(6));
        tagged.extend_from_slice(&jpeg[2..]);

        let rotated = round_trip(&tagged);
        assert!(rotated.orientation_applied);
        assert_eq!((rotated.image.width(), rotated.image.height()), (4, 4));
        let red = rotated.image.get(3, 0);
        let dark = rotated.image.get(0, 3);
        assert!(red[0] > 180 && red[1] < 80, "the red quarter should be top right: {red:?}");
        assert!(dark[0] < 80, "the rest should stay dark: {dark:?}");

        // A caller that wants the stored grid keeps it, and the flag says so.
        let options = ImportOptions { apply_orientation: false, ..ImportOptions::default() };
        let stored = decode_raster(&tagged, &options).unwrap();
        assert!(!stored.orientation_applied);
        assert!(stored.image.get(0, 0)[0] > 180, "the stored grid keeps red top left");
    }

    #[test]
    fn only_horizontally_subsampled_layouts_are_corrected() {
        assert!(horizontally_subsampled(SampleRatios::H));
        assert!(horizontally_subsampled(SampleRatios::HV));
        assert!(horizontally_subsampled(SampleRatios::Generic(2, 4)));
        assert!(!horizontally_subsampled(SampleRatios::None));
        assert!(!horizontally_subsampled(SampleRatios::V));
        assert!(!horizontally_subsampled(SampleRatios::Generic(1, 2)));
    }


    #[test]
    fn limits_reject_oversized_images_before_decoding() {
        assert!(matches!(check_limits(0, 10, u64::MAX), Err(IoError::Unreadable(_))));
        assert!(matches!(check_limits(limits::MAX_SIDE + 1, 1, u64::MAX), Err(IoError::TooLarge(_))));
        assert!(matches!(check_limits(1000, 1000, 1000), Err(IoError::TooLarge(_))));
        assert!(check_limits(1000, 1000, 1_000_000).is_ok());
    }

    #[test]
    fn png_carries_the_resolution_in_phys() {
        let image = Bitmap8::filled(3, 2, [9, 8, 7, 255]);
        let bytes = encode_png(&image, 300.0).unwrap();
        let pixel_dims = {
            let decoder = png::Decoder::new(Cursor::new(&bytes));
            let reader = decoder.read_info().unwrap();
            reader.info().pixel_dims
        };
        let dims = pixel_dims.expect("pHYs chunk");
        assert_eq!(dims.unit, png::Unit::Meter);
        assert_eq!(dims.xppu, 11_811);
        let resolution = read_png_resolution(&bytes).unwrap();
        assert!((resolution - 300.0).abs() < 0.1, "{resolution}");
        // The pixels survive the splice.
        assert_eq!(decode_raster(&bytes, &ImportOptions::default()).unwrap().image, image);
    }

    #[test]
    fn jpeg_carries_the_resolution_in_the_jfif_header() {
        let image = Bitmap8::filled(8, 8, [12, 34, 56, 255]);
        let bytes =
            encode_jpeg(&image, &JpegOptions { quality: 80, resolution: 300.0, ..JpegOptions::default() })
                .unwrap();
        assert_eq!(bytes[0..2], [0xFF, 0xD8]);
        // APP0 right after SOI: FF E0, length, "JFIF\0", version, units, x and y density.
        assert_eq!(bytes[2], 0xFF);
        assert_eq!(bytes[3], 0xE0);
        assert_eq!(&bytes[6..11], b"JFIF\0");
        assert_eq!(bytes[13], 1, "units are dots per inch");
        assert_eq!(u16::from_be_bytes([bytes[14], bytes[15]]), 300);
        assert_eq!(read_jpeg_resolution(&bytes), Some(300.0));
    }

    #[test]
    fn resolution_outside_one_to_9600_is_refused() {
        let image = Bitmap8::filled(2, 2, [0, 0, 0, 255]);
        assert!(matches!(encode_png(&image, 0.0), Err(IoError::Invalid(_))));
        assert!(matches!(encode_png(&image, 10_000.0), Err(IoError::Invalid(_))));
        assert!(matches!(encode_png(&image, f64::NAN), Err(IoError::Invalid(_))));
        assert!(matches!(
            encode_jpeg(&image, &JpegOptions { resolution: -1.0, ..JpegOptions::default() }),
            Err(IoError::Invalid(_))
        ));
    }

    #[test]
    fn exported_png_without_phys_has_no_resolution() {
        let image = Bitmap8::filled(2, 2, [1, 1, 1, 255]);
        let plain = png_io::encode_rgba8(&image).unwrap();
        assert_eq!(read_png_resolution(&plain), None);
    }

    #[test]
    fn document_takes_the_file_resolution_and_one_layer() {
        let image = sample(7, 5);
        let bytes = encode_png(&image, 144.0).unwrap();
        let raster = round_trip(&bytes);
        assert_eq!(raster.resolution, Some(read_png_resolution(&bytes).unwrap()));
        let document = raster.into_document(&ImportOptions::default());
        assert_eq!((document.width, document.height), (7, 5));
        assert_eq!(document.layers.len(), 1);
        assert_eq!(document.layers[0].image.as_ref().map(|i| i.width()), Some(7));
        assert!(document.active_layer.is_some());
        assert!((document.resolution - 144.0).abs() < 0.2, "{}", document.resolution);
    }

    #[test]
    fn import_options_can_force_the_resolution() {
        let image = sample(4, 3);
        let bytes = encode_png(&image, 72.0).unwrap();
        let options = ImportOptions { resolution: Some(600.0), ..ImportOptions::default() };
        let document = decode_raster(&bytes, &options).unwrap().into_document(&options);
        assert_eq!(document.resolution, 600.0);
    }

    #[test]
    fn placing_an_import_centers_it_like_the_macos_insert() {
        let mut document = Document::new(100, 80);
        let raster = ImportedRaster {
            image: Bitmap8::filled(20, 10, [1, 2, 3, 255]),
            format: RasterFormat::Png,
            resolution: None,
            name: "Dropped".into(),
            orientation_applied: false,
        };
        let id = place_imported(&mut document, raster, None).unwrap();
        let layer = document.layer(id).unwrap();
        assert_eq!(layer.name, "Dropped");
        assert_eq!(layer.transform.origin, PointF::new(40.0, 35.0));
        assert_eq!(layer.transform.size.width, 20.0);
        assert_eq!(document.active_layer, Some(id));
    }

    #[test]
    fn import_raster_and_document_read_from_disk() {
        let directory = std::env::temp_dir().join(format!("comp-io-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let image = sample(9, 6);
        let png = encode_png(&image, 96.0).unwrap();
        let jpeg =
            encode_jpeg(&image, &JpegOptions { quality: 95, resolution: 96.0, ..JpegOptions::default() })
                .unwrap();
        let png_path = directory.join("import sample.png");
        let jpeg_path = directory.join("import sample.jpeg");
        std::fs::write(&png_path, png).unwrap();
        std::fs::write(&jpeg_path, jpeg).unwrap();

        let raster = import_raster(&png_path, &ImportOptions::default()).unwrap();
        assert_eq!(raster.name, "import sample");
        assert_eq!(raster.image, image);
        let document = import_document(&png_path).unwrap();
        assert_eq!(document.layers[0].name, "import sample");
        assert_eq!((document.width, document.height), (9, 6));
        assert!(import_document(&jpeg_path).is_ok());

        let small = Bitmap8::filled(4, 4, [0, 0, 0, 255]);
        export_png(&small, directory.join("out.png"), 150.0).unwrap();
        export_jpeg(&small, directory.join("out.jpg"), 70, 150.0).unwrap();
        assert!(import_image(directory.join("out.png")).is_ok());
        let reloaded = import_document(directory.join("out.jpg")).unwrap();
        assert_eq!(reloaded.layers[0].transform.size.width, 4.0);
        std::fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn import_document_routes_photoshop_files_through_the_psd_reader() {
        let directory = std::env::temp_dir().join(format!("comp-io-psd-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let pixels = vec![[9u8, 8, 7, 255]; 4];
        let psd = crate::psd::test_support::single_layer("Artwork", 2, 2, &pixels, 0);
        let path = directory.join("layered.psd");
        std::fs::write(&path, psd).unwrap();

        let document = import_document(&path).unwrap();
        assert_eq!((document.width, document.height), (2, 2));
        assert_eq!(document.layers.len(), 1);
        assert_eq!(document.layers[0].name, "Artwork");
        assert_eq!(document.layers[0].image.as_ref().unwrap().get(1, 1), [9, 8, 7, 255]);
        // A Photoshop file is not a raster format, so the pixel-only entry point refuses it.
        assert!(matches!(import_image(&path), Err(IoError::UnsupportedFormat(_))));
        std::fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn import_image_returns_pixels_only() {
        let directory = std::env::temp_dir().join(format!("comp-io-image-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let image = sample(3, 3);
        let path = directory.join("plain.tiff");
        std::fs::write(&path, tiff_bytes(&image)).unwrap();
        assert_eq!(import_image(&path).unwrap(), image);
        std::fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn crc_matches_the_png_specification() {
        // The CRC of an empty chunk body is 0; IEND's is the well-known 0xAE426082.
        assert_eq!(crc32(b""), 0);
        assert_eq!(crc32(b"IEND"), 0xAE42_6082);
    }

    #[test]
    fn jpeg_density_can_be_centimeters() {
        let mut jpeg = vec![0xFF, 0xD8];
        jpeg.extend_from_slice(&[0xFF, 0xE0, 0x00, 0x10]);
        jpeg.extend_from_slice(b"JFIF\0");
        jpeg.extend_from_slice(&[1, 1, 2]); // version 1.1, units: dots per centimetre
        jpeg.extend_from_slice(&118u16.to_be_bytes());
        jpeg.extend_from_slice(&118u16.to_be_bytes());
        jpeg.extend_from_slice(&[0, 0]);
        assert_eq!(read_jpeg_resolution(&jpeg), Some(118.0 * 2.54));
    }

    /// A BMP with a DPI written into biXPelsPerMeter and biYPelsPerMeter.
    fn bmp_with_dpi(image: &Bitmap8, dpi: f64) -> Vec<u8> {
        let mut out = Vec::new();
        BmpEncoder::new(&mut out)
            .write_image(image.pixels(), image.width(), image.height(), ExtendedColorType::Rgba8)
            .unwrap();
        // The two fields are at DIB offset 24 and 28, which is file offset 38 and 42.
        let pixels_per_meter = (dpi / 0.0254).round() as u32;
        out[38..42].copy_from_slice(&pixels_per_meter.to_le_bytes());
        out[42..46].copy_from_slice(&pixels_per_meter.to_le_bytes());
        out
    }

    #[test]
    fn a_bmp_dpi_reaches_the_document_and_the_exported_png() {
        let directory = std::env::temp_dir().join(format!("comp-io-dpi-loop-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let image = Bitmap8::filled(6, 6, [12, 34, 56, 255]);
        let path = directory.join("resolved.bmp");
        std::fs::write(&path, bmp_with_dpi(&image, 300.0)).unwrap();

        let document = import_document(&path).unwrap();
        assert!((document.resolution - 300.0).abs() < 0.5, "{}", document.resolution);
        assert_eq!(document.layers[0].image.as_ref().unwrap().get(3, 3), [12, 34, 56, 255]);
        // What the document carries is what an export writes back out.
        let exported = directory.join("resolved.png");
        export_png(&image, &exported, document.resolution).unwrap();
        let bytes = std::fs::read(&exported).unwrap();
        let resolution = read_png_resolution(&bytes).unwrap();
        assert!((resolution - 300.0).abs() < 0.5, "{resolution}");
        std::fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn svg_files_import_as_documents_sized_to_the_drawing() {
        let directory = std::env::temp_dir().join(format!("comp-io-svg-{}", std::process::id()));
        std::fs::create_dir_all(&directory).unwrap();
        let markup = r##"<svg xmlns="http://www.w3.org/2000/svg" width="24" height="12" viewBox="0 0 48 24">
                <rect width="48" height="24" fill="#204080"/>
            </svg>"##;
        let path = directory.join("badge.svg");
        std::fs::write(&path, markup).unwrap();

        let raster = import_raster(&path, &ImportOptions::default()).unwrap();
        assert_eq!(raster.format, RasterFormat::Svg);
        assert_eq!(raster.name, "badge");
        assert_eq!((raster.image.width(), raster.image.height()), (24, 12));
        // A vector file has no DPI of its own, so the document keeps the default.
        assert!(raster.resolution.is_none());

        let document = import_document(&path).unwrap();
        assert_eq!((document.width, document.height), (24, 12));
        assert_eq!(document.layers.len(), 1);
        assert_eq!(document.layers[0].name, "badge");
        assert_eq!(document.layers[0].image.as_ref().unwrap().get(6, 6), [0x20, 0x40, 0x80, 255]);
        assert_eq!(document.resolution, 72.0);
        std::fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn an_oversized_svg_is_refused_through_the_codec() {
        let markup = format!(
            r##"<svg xmlns="http://www.w3.org/2000/svg" width="{}" height="{}"/>"##,
            limits::MAX_SIDE,
            limits::MAX_SIDE
        );
        match decode_raster(markup.as_bytes(), &ImportOptions::default()) {
            Err(IoError::TooLarge(message)) => assert!(message.contains("exceeds"), "{message}"),
            other => panic!("expected a size error, got {other:?}"),
        }
        // Damaged vector art is a read error, not a panic or an empty layer.
        let broken = decode_raster(b"<svg><rect", &ImportOptions::default()).unwrap_err();
        assert!(matches!(broken, IoError::Unreadable(_)), "{broken:?}");
    }

    #[test]
    fn jpeg_written_by_the_image_crate_still_imports() {
        let image = sample(8, 8);
        let rgb = flatten_over_background(&image, [255, 255, 255]);
        let mut out = Vec::new();
        JpegEncoder::new_with_quality(&mut out, 90)
            .write_image(&rgb, image.width(), image.height(), ExtendedColorType::Rgb8)
            .unwrap();
        assert_eq!(round_trip(&out).format, RasterFormat::Jpeg);
    }
}
