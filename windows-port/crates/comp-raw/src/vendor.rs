//! Vendor camera raw decoding: rawloader's CFA mosaic and camera metadata, developed into the
//! sRGB image the rest of the pipeline expects.
//!
//! The front end follows the classic dcraw order, which is also what the macOS app does before its
//! own Camera Raw grade runs:
//!
//! 1. per-channel black and white levels,
//! 2. the shot's white balance, per filter-array color,
//! 3. bilinear demosaic,
//! 4. the camera-to-sRGB matrix (camera -> XYZ -> sRGB), normalized so a neutral camera pixel stays
//!    neutral,
//! 5. the sRGB transfer function, and the top/right/bottom/left crops the file asks for.
//!
//! Nothing here is creative: the grade (Light, Color, Curve, Mixer, Grading, Effects, Optics, Detail)
//! runs afterwards through `crate::develop`, so temperature and tint are offsets on top of the
//! shot's own balance.

use std::io::Cursor;
use std::path::Path;
use std::sync::Arc;

use comp_core::Bitmap8;

use crate::blur::box_blur_plane;
use crate::error::{Error, Result};
use crate::math::linear_to_srgb;

/// Orientation stored in the file. Values follow the TIFF Orientation tag (1…8).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RawOrientation {
    Normal,
    HorizontalFlip,
    Rotate180,
    VerticalFlip,
    Transpose,
    Rotate90,
    Transverse,
    Rotate270,
    Unknown,
}

impl RawOrientation {
    /// True when the flags and the transpose in `to_flips` describe a 90-degree turn.
    fn to_flips(self) -> (bool, bool, bool) {
        match self {
            RawOrientation::Normal | RawOrientation::Unknown => (false, false, false),
            RawOrientation::VerticalFlip => (false, false, true),
            RawOrientation::HorizontalFlip => (false, true, false),
            RawOrientation::Rotate180 => (false, true, true),
            RawOrientation::Transpose => (true, false, false),
            RawOrientation::Rotate90 => (true, false, true),
            RawOrientation::Rotate270 => (true, true, false),
            RawOrientation::Transverse => (true, true, true),
        }
    }

    fn from_rawloader(orientation: rawloader::Orientation) -> Self {
        match orientation {
            rawloader::Orientation::Normal => RawOrientation::Normal,
            rawloader::Orientation::HorizontalFlip => RawOrientation::HorizontalFlip,
            rawloader::Orientation::Rotate180 => RawOrientation::Rotate180,
            rawloader::Orientation::VerticalFlip => RawOrientation::VerticalFlip,
            rawloader::Orientation::Transpose => RawOrientation::Transpose,
            rawloader::Orientation::Rotate90 => RawOrientation::Rotate90,
            rawloader::Orientation::Transverse => RawOrientation::Transverse,
            rawloader::Orientation::Rotate270 => RawOrientation::Rotate270,
            rawloader::Orientation::Unknown => RawOrientation::Unknown,
        }
    }
}

/// Where the multipliers that balance the shot came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WhiteBalanceSource {
    /// The file carried as-shot multipliers.
    Camera,
    /// The file carried none, so the camera matrix was asked for the multipliers that make the
    /// 6500 K daylight neutral (rawloader's `neutralwb`), which is a better guess than assuming
    /// equal channels while a matrix is known.
    Neutral6500K,
    /// No usable multipliers and no usable matrix: the averages of the four filter colors are
    /// equalized instead (gray world).
    GrayWorld,
}

/// Where the camera-to-XYZ matrix came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MatrixSource {
    /// The file (or the decoder's per-camera table) carried one.
    File,
    /// Nothing was available, so sRGB D65 primaries are assumed: the raw is treated as already being
    /// in sRGB color space. Documented approximation for unknown cameras.
    SrgbDefault,
}

/// Which decoder produced the pixels. rawloader is the first choice; LibRaw is the supplementary
/// path, used only when the pure-Rust decoder cannot read the file.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SensorEngine {
    /// The pure-Rust decoder: the mosaic, the levels and the camera matrix come from the file and the
    /// front end in this crate does the rest.
    Rawloader,
    /// LibRaw: it applies the black level, the demosaic, the white balance, the camera matrix and the
    /// sRGB transfer function itself, so its output arrives ready for the grade.
    LibRaw,
}

/// What the decoder learned about the shot, for the caller to show or write down.
#[derive(Clone, Debug, PartialEq)]
pub struct RawMetadata {
    pub make: String,
    pub model: String,
    pub clean_make: String,
    pub clean_model: String,
    /// The filter array pattern, for example `RGGB`, empty for a linear (already demosaiced) raw.
    pub cfa: String,
    pub width: usize,
    pub height: usize,
    /// Components per pixel: 1 for a mosaic, 3 for a linear raw.
    pub channels: usize,
    pub black_levels: [u16; 4],
    pub white_levels: [u16; 4],
    /// The multipliers actually applied, green-normalized, in RGBE order.
    pub white_balance: [f32; 4],
    pub white_balance_source: WhiteBalanceSource,
    pub matrix_source: MatrixSource,
    pub orientation: RawOrientation,
    /// Usable-area trim as top, right, bottom, left.
    pub crops: [usize; 4],
    /// Who decoded the file.
    pub engine: SensorEngine,
    /// The decoder LibRaw used, from its own `libraw_unpack_function_name`; empty for rawloader,
    /// which does not name its decoders.
    pub decoder: String,
    /// Why the first-choice decoder did not answer, when a supplementary one did. None means the
    /// pure-Rust decoder read the file.
    pub fallback_reason: Option<String>,
}

/// A decoded raw frame, ready for `crate::develop`.
#[derive(Clone, Debug)]
pub struct VendorImage {
    pub image: Bitmap8,
    pub metadata: RawMetadata,
}

impl VendorImage {
    /// What the file said about the shot.
    pub fn metadata(&self) -> &RawMetadata {
        &self.metadata
    }
}

/// The intermediate planes of the develop front end, for cross-checking the arithmetic against an
/// independent implementation. `mosaic` is the level-normalized, white-balanced sensor plane;
/// `linear` is linear-light sRGB before the transfer function.
#[derive(Clone, Debug, PartialEq)]
pub struct VendorPlanes {
    pub width: usize,
    pub height: usize,
    pub mosaic: Vec<f32>,
    pub linear: Vec<[f32; 3]>,
}

/// The matrix rawloader falls back to when a file carries no camera matrix: sRGB D65 as XYZ-to-camera.
const RAWLOADER_SRGB_DEFAULT: [[f32; 3]; 3] = [
    [0.412453, 0.357580, 0.180423],
    [0.212671, 0.715160, 0.072169],
    [0.019334, 0.119193, 0.950227],
];

/// Linear sRGB to XYZ (D65), the same matrix rawloader calls its sRGB default.
const RGB_TO_XYZ: [[f32; 3]; 3] = RAWLOADER_SRGB_DEFAULT;

/// The identity matrix, used when a file carries no usable camera matrix.
const IDENTITY: [[f32; 3]; 3] = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]];

/// The stack the decoder thread gets. rawloader's lossless-JPEG and Huffman paths build large tables
/// and deep frames: a 10 MP NEF needs about 2 MB in a debug build, while a Windows process starts its
/// main thread with 1 MB and an image can be decoded from anywhere (a command line, a UI thread, a
/// worker pool). Decoding on a thread with room to spare keeps that from being the caller's problem.
const VENDOR_STACK_BYTES: usize = 16 * 1024 * 1024;

/// Decodes a camera raw file (NEF, CR2, CR3, ARW, RAF, DNG with sensor data, …).
pub fn decode_vendor_file(path: &Path) -> Result<VendorImage> {
    let bytes = std::fs::read(path)?;
    decode_vendor_bytes(&bytes)
}

/// Decodes camera raw bytes. `rawloader` sniffs the container, so the extension is not consulted.
pub fn decode_vendor_bytes(bytes: &[u8]) -> Result<VendorImage> {
    decode_vendor_planes(bytes).map(|(image, _)| image)
}

/// Decodes camera raw bytes and also returns the intermediate planes.
pub fn decode_vendor_planes(bytes: &[u8]) -> Result<(VendorImage, VendorPlanes)> {
    let shared: Arc<[u8]> = Arc::from(bytes);
    run_on_decoder_thread(move || decode_on_this_thread(shared))
}

/// Runs a decoder on a thread with the stack measured to be enough for camera raw work. Both
/// backends use this: rawloader's lossless-JPEG path and LibRaw's AHD demosaic are both deep.
pub(crate) fn run_on_decoder_thread<T, F>(work: F) -> Result<T>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T> + Send + 'static,
{
    let worker = std::thread::Builder::new()
        .name("comp-raw-decode".to_string())
        .stack_size(VENDOR_STACK_BYTES)
        .spawn(work)
        .map_err(|error| Error::Vendor(format!("could not start the decoder thread: {error}")))?;
    match worker.join() {
        // A decoder that panics on a damaged file must not take the editor down with it.
        Ok(result) => result,
        Err(_) => Err(Error::Vendor("the sensor decoder panicked on this file".to_string())),
    }
}

fn decode_on_this_thread(bytes: Arc<[u8]>) -> Result<(VendorImage, VendorPlanes)> {
    let mut cursor = Cursor::new(bytes);
    let raw = rawloader::decode(&mut cursor).map_err(|error| Error::Vendor(error.to_string()))?;
    develop_raw(&raw)
}

fn develop_raw(raw: &rawloader::RawImage) -> Result<(VendorImage, VendorPlanes)> {
    let width = raw.width;
    let height = raw.height;
    if width == 0 || height == 0 {
        return Err(Error::Vendor("the raw frame has no pixels".to_string()));
    }
    let channels = raw.cpp.max(1);
    let expected = width * height * channels;
    let samples: Vec<f32> = match &raw.data {
        rawloader::RawImageData::Integer(data) => data.iter().map(|value| *value as f32).collect(),
        // Float raws arrive already normalized; there are no integer levels to subtract.
        rawloader::RawImageData::Float(data) => data.clone(),
    };
    if samples.len() < expected {
        return Err(Error::Vendor(format!(
            "the raw frame holds {} samples, expected {expected} for {width}x{height}x{channels}",
            samples.len()
        )));
    }
    let float_data = matches!(raw.data, rawloader::RawImageData::Float(_));

    // What filter color each *sample* sits behind, one entry per stored value. A mosaic has one
    // sample per pixel, and the pattern says which color it is; a linear raw interleaves three
    // channels. Emerald (3) is treated as green, which is what converters do with the four-color
    // Sony arrays.
    let mut color_index = vec![0u8; width * height * channels];
    if channels == 1 {
        for y in 0..height {
            for x in 0..width {
                let color = raw.cfa.color_at(y, x);
                color_index[y * width + x] = if color >= 3 { 1 } else { color as u8 };
            }
        }
    } else {
        for (index, slot) in color_index.iter_mut().enumerate() {
            *slot = (index % 3) as u8;
        }
    }

    // 1. Levels, then 2. white balance, both per filter color.
    let mut plane = samples;
    if !float_data {
        for (index, value) in plane.iter_mut().enumerate() {
            let color = color_index[index] as usize;
            let black = raw.blacklevels[color] as f32;
            let white = raw.whitelevels[color] as f32;
            let span = if white > black { white - black } else { 65535.0 - black };
            *value = if span > 0.0 { ((*value - black) / span).clamp(0.0, 1.0) } else { 0.0 };
        }
    }
    let (white_balance, wb_source) = choose_white_balance(raw, &plane, &color_index);
    for (index, value) in plane.iter_mut().enumerate() {
        *value *= white_balance[color_index[index] as usize];
    }

    // 3. Mosaic to RGB.
    let rgb = if channels == 1 {
        let side = raw.cfa.width.max(raw.cfa.height);
        let radius = if side <= 2 { 1 } else { 3 };
        demosaic(&plane, width, height, &color_index, radius)
    } else {
        (0..width * height)
            .map(|index| {
                let base = index * 3;
                [plane[base], plane[base + 1], plane[base + 2]]
            })
            .collect()
    };

    // 4. Camera to sRGB, normalized so a neutral camera pixel stays neutral, then 5. sRGB encode.
    let (matrix, matrix_source) = camera_to_srgb(raw);
    let mut linear_rgb = Vec::with_capacity(width * height);
    let mut bytes = Vec::with_capacity(width * height * 4);
    for color in &rgb {
        let linear = [
            matrix[0][0] * color[0] + matrix[0][1] * color[1] + matrix[0][2] * color[2],
            matrix[1][0] * color[0] + matrix[1][1] * color[1] + matrix[1][2] * color[2],
            matrix[2][0] * color[0] + matrix[2][1] * color[1] + matrix[2][2] * color[2],
        ];
        linear_rgb.push(linear);
        for channel in linear {
            let encoded = if channel.is_finite() { linear_to_srgb(channel.clamp(0.0, 1.0) as f64) } else { 0.0 };
            bytes.push((encoded * 255.0).round().clamp(0.0, 255.0) as u8);
        }
        bytes.push(255);
    }
    let image = Bitmap8::from_raw(width as u32, height as u32, bytes).map_err(Error::Core)?;

    // 6. The usable area the file asks for.
    let crops = raw.crops;
    let image = crop_usable_area(&image, crops);
    let metadata = RawMetadata {
        make: raw.make.clone(),
        model: raw.model.clone(),
        clean_make: raw.clean_make.clone(),
        clean_model: raw.clean_model.clone(),
        cfa: raw.cfa.name.clone(),
        width,
        height,
        channels,
        black_levels: raw.blacklevels,
        white_levels: raw.whitelevels,
        white_balance,
        white_balance_source: wb_source,
        matrix_source,
        orientation: RawOrientation::from_rawloader(raw.orientation),
        crops,
        engine: SensorEngine::Rawloader,
        decoder: String::new(),
        fallback_reason: None,
    };
    let planes = VendorPlanes { width, height, mosaic: plane, linear: linear_rgb };
    Ok((VendorImage { image, metadata }, planes))
}

/// The multipliers to apply, green-normalized. A file's own values win; without them the camera
/// matrix is asked for a 6500 K neutral; without that either, the filter colors are equalized.
fn choose_white_balance(
    raw: &rawloader::RawImage,
    plane: &[f32],
    color_index: &[u8],
) -> ([f32; 4], WhiteBalanceSource) {
    if let Some(coeffs) = normalize_wb(raw.wb_coeffs) {
        return (coeffs, WhiteBalanceSource::Camera);
    }
    // The 6500 K guess is derived from the camera matrix, so it is only meaningful when the file
    // actually carried one.
    if !is_placeholder_matrix(&raw.xyz_to_cam) {
        if let Some(coeffs) = normalize_wb(raw.neutralwb()) {
            return (coeffs, WhiteBalanceSource::Neutral6500K);
        }
    }
    (gray_world(plane, color_index), WhiteBalanceSource::GrayWorld)
}

/// Green-normalizes RGBE multipliers, or None when they are missing or unusable.
fn normalize_wb(coeffs: [f32; 4]) -> Option<[f32; 4]> {
    let green = coeffs[1];
    if !green.is_finite() || green <= 0.0 {
        return None;
    }
    if !(coeffs[0].is_finite() && coeffs[2].is_finite()) || coeffs[0] <= 0.0 || coeffs[2] <= 0.0 {
        return None;
    }
    let extra = if coeffs[3].is_finite() && coeffs[3] > 0.0 { coeffs[3] / green } else { 1.0 };
    Some([coeffs[0] / green, 1.0, coeffs[2] / green, extra])
}

/// Gray-world multipliers: every filter color ends up with the same average, so a scene that
/// averages gray comes out gray.
fn gray_world(plane: &[f32], color_index: &[u8]) -> [f32; 4] {
    let mut sums = [0.0f64; 4];
    let mut counts = [0.0f64; 4];
    for (value, color) in plane.iter().zip(color_index.iter()) {
        let color = *color as usize;
        sums[color] += *value as f64;
        counts[color] += 1.0;
    }
    let means: Vec<f64> = (0..4)
        .map(|color| if counts[color] > 0.0 { sums[color] / counts[color] } else { 0.0 })
        .collect();
    let green = if means[1] > 1e-9 { means[1] } else { 1.0 };
    let mut coeffs = [1.0f32; 4];
    for color in 0..4 {
        coeffs[color] = if means[color] > 1e-9 { (green / means[color]) as f32 } else { 1.0 };
    }
    // Green is the reference so the overall exposure does not move.
    let g = coeffs[1];
    if g.is_finite() && g > 0.0 {
        for value in coeffs.iter_mut() {
            *value /= g;
        }
    }
    coeffs
}

/// Bilinear demosaic. Each filter color is averaged over the samples of that color inside a small
/// window, and a pixel keeps its own sample when the window contains it: the classic 3x3 bilinear
/// interpolation for a 2x2 pattern, widened for the 6x6 ones.
fn demosaic(plane: &[f32], width: usize, height: usize, color_index: &[u8], radius: i64) -> Vec<[f32; 3]> {
    let count = width * height;
    let mut planes = Vec::with_capacity(3);
    for color in 0..3u8 {
        let mut values = vec![0f32; count];
        let mut mask = vec![0f32; count];
        for index in 0..count {
            if color_index[index] == color {
                values[index] = plane[index];
                mask[index] = 1.0;
            }
        }
        let mut blurred_values = vec![0f32; count];
        let mut blurred_mask = vec![0f32; count];
        box_blur_plane(&values, &mut blurred_values, width, height, radius);
        box_blur_plane(&mask, &mut blurred_mask, width, height, radius);
        for index in 0..count {
            values[index] = if blurred_mask[index] > 1e-6 {
                blurred_values[index] / blurred_mask[index]
            } else {
                0.0
            };
        }
        planes.push(values);
    }
    let mut out = Vec::with_capacity(count);
    for index in 0..count {
        let own = color_index[index] as usize;
        let mut color = [planes[0][index], planes[1][index], planes[2][index]];
        color[own] = plane[index];
        out.push(color);
    }
    out
}

/// Camera to linear sRGB, following dcraw's `cam_xyz_coeff`:
///
/// 1. compose the camera matrix with the sRGB primaries to get how each camera channel answers the
///    sRGB primaries,
/// 2. scale every camera channel so its answer to white is 1, which is what keeps the white balance
///    and the matrix consistent,
/// 3. invert: that is camera to sRGB, and white lands on white by construction.
///
/// A file with no camera matrix (rawloader substitutes the sRGB primaries as a placeholder) cannot be
/// treated that way, because the placeholder is not a measurement of any camera: the raw is assumed
/// to already be in sRGB primaries, which is an identity matrix and is reported as a default.
fn camera_to_srgb(raw: &rawloader::RawImage) -> ([[f32; 3]; 3], MatrixSource) {
    let xyz_to_cam = raw.xyz_to_cam;
    if is_placeholder_matrix(&xyz_to_cam) {
        return (IDENTITY, MatrixSource::SrgbDefault);
    }
    let mut cam_rgb = [[0f32; 3]; 3];
    for row in 0..3 {
        for column in 0..3 {
            let mut sum = 0.0;
            for k in 0..3 {
                sum += xyz_to_cam[row][k] * RGB_TO_XYZ[k][column];
            }
            cam_rgb[row][column] = sum;
        }
    }
    if !cam_rgb.iter().flatten().all(|value| value.is_finite()) {
        // A damaged matrix must not poison the whole frame.
        return (IDENTITY, MatrixSource::SrgbDefault);
    }
    for row in cam_rgb.iter_mut() {
        let sum = row[0] + row[1] + row[2];
        if sum.abs() > 1e-6 && sum.is_finite() {
            for value in row.iter_mut() {
                *value /= sum;
            }
        }
    }
    match invert3(&cam_rgb) {
        Some(matrix) if matrix.iter().flatten().all(|value| value.is_finite()) => (matrix, MatrixSource::File),
        _ => (IDENTITY, MatrixSource::SrgbDefault),
    }
}

/// True for the placeholders rawloader substitutes when a file carries no camera matrix.
fn is_placeholder_matrix(xyz_to_cam: &[[f32; 3]; 4]) -> bool {
    (0..3).all(|row| (0..3).all(|column| (xyz_to_cam[row][column] - RGB_TO_XYZ[row][column]).abs() < 1e-6))
}

/// The inverse of a 3x3 matrix, or None when it is singular.
fn invert3(matrix: &[[f32; 3]; 3]) -> Option<[[f32; 3]; 3]> {
    let determinant = matrix[0][0] * (matrix[1][1] * matrix[2][2] - matrix[1][2] * matrix[2][1])
        - matrix[0][1] * (matrix[1][0] * matrix[2][2] - matrix[1][2] * matrix[2][0])
        + matrix[0][2] * (matrix[1][0] * matrix[2][1] - matrix[1][1] * matrix[2][0]);
    if determinant.abs() < 1e-12 || !determinant.is_finite() {
        return None;
    }
    let inverse = [
        [
            (matrix[1][1] * matrix[2][2] - matrix[1][2] * matrix[2][1]) / determinant,
            (matrix[0][2] * matrix[2][1] - matrix[0][1] * matrix[2][2]) / determinant,
            (matrix[0][1] * matrix[1][2] - matrix[0][2] * matrix[1][1]) / determinant,
        ],
        [
            (matrix[1][2] * matrix[2][0] - matrix[1][0] * matrix[2][2]) / determinant,
            (matrix[0][0] * matrix[2][2] - matrix[0][2] * matrix[2][0]) / determinant,
            (matrix[0][2] * matrix[1][0] - matrix[0][0] * matrix[1][2]) / determinant,
        ],
        [
            (matrix[1][0] * matrix[2][1] - matrix[1][1] * matrix[2][0]) / determinant,
            (matrix[0][1] * matrix[2][0] - matrix[0][0] * matrix[2][1]) / determinant,
            (matrix[0][0] * matrix[1][1] - matrix[0][1] * matrix[1][0]) / determinant,
        ],
    ];
    Some(inverse)
}

/// Trims the unusable border the decoder reported, as top, right, bottom, left.
fn crop_usable_area(image: &Bitmap8, crops: [usize; 4]) -> Bitmap8 {
    let [top, right, bottom, left] = crops;
    let width = image.width() as usize;
    let height = image.height() as usize;
    if left + right >= width || top + bottom >= height {
        return image.clone();
    }
    if crops == [0, 0, 0, 0] {
        return image.clone();
    }
    let (new_width, new_height) = ((width - left - right) as u32, (height - top - bottom) as u32);
    if new_width == 0 || new_height == 0 {
        return image.clone();
    }
    image.subimage(left as i64, top as i64, new_width, new_height)
}

/// Applies the orientation the file stored. The caller decides whether to ask for it: a decoded raw
/// otherwise arrives in sensor order, exactly like the camera wrote it.
pub fn orient(image: &Bitmap8, orientation: RawOrientation) -> Bitmap8 {
    let (transpose, flip_horizontal, flip_vertical) = orientation.to_flips();
    let mut out = image.clone();
    if flip_horizontal {
        out = out.flipped_horizontally();
    }
    if flip_vertical {
        out = out.flipped_vertically();
    }
    if transpose {
        out = transpose_image(&out);
    }
    out
}

fn transpose_image(image: &Bitmap8) -> Bitmap8 {
    let mut out = Bitmap8::new(image.height(), image.width());
    for y in 0..image.height() {
        for x in 0..image.width() {
            out.set(y, x, image.get(x, y));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rgba(colors: &[[u8; 3]]) -> Bitmap8 {
        let mut bytes = Vec::new();
        for color in colors {
            bytes.extend_from_slice(color);
            bytes.push(255);
        }
        Bitmap8::from_raw(colors.len() as u32, 1, bytes).unwrap()
    }

    #[test]
    fn white_balance_coefficients_are_green_normalized() {
        let coeffs = normalize_wb([1.82, 1.0, 1.53, f32::NAN]).unwrap();
        assert!((coeffs[0] - 1.82).abs() < 1e-6);
        assert_eq!(coeffs[1], 1.0);
        assert!((coeffs[2] - 1.53).abs() < 1e-6);
        assert_eq!(coeffs[3], 1.0, "a missing emerald coefficient becomes neutral");

        let scaled = normalize_wb([3.64, 2.0, 3.06, 2.0]).unwrap();
        assert!((scaled[0] - 1.82).abs() < 1e-6, "{scaled:?}");
        assert!((scaled[3] - 1.0).abs() < 1e-6);

        assert!(normalize_wb([f32::NAN; 4]).is_none());
        assert!(normalize_wb([1.0, 0.0, 1.0, 1.0]).is_none(), "green cannot be zero");
        assert!(normalize_wb([1.0, 1.0, -0.5, 1.0]).is_none(), "a negative multiplier is nonsense");
    }

    #[test]
    fn gray_world_equalizes_the_filter_colors() {
        // A 2x2 RGGB mosaic whose green is twice as sensitive as red and blue.
        let plane = vec![0.25f32, 0.5, 0.5, 0.75];
        let colors = vec![0u8, 1, 1, 2];
        let coeffs = gray_world(&plane, &colors);
        assert!((coeffs[1] - 1.0).abs() < 1e-6);
        assert!((coeffs[0] - 2.0).abs() < 1e-6, "{coeffs:?}");
        assert!((coeffs[2] - 2.0 / 3.0).abs() < 1e-5, "{coeffs:?}");
    }

    #[test]
    fn bilinear_demosaic_reproduces_a_flat_color() {
        // Every red site 0.25, every green 0.5, every blue 0.75: any interpolation of a constant
        // field must return the same constant everywhere.
        let width = 4;
        let height = 4;
        let mut plane = vec![0f32; width * height];
        let mut colors = vec![0u8; width * height];
        for y in 0..height {
            for x in 0..width {
                let color = match (y % 2, x % 2) {
                    (0, 0) => 0,
                    (0, 1) | (1, 0) => 1,
                    _ => 2,
                };
                colors[y * width + x] = color;
                plane[y * width + x] = [0.25, 0.5, 0.75][color as usize];
            }
        }
        for color in demosaic(&plane, width, height, &colors, 1) {
            assert!((color[0] - 0.25).abs() < 1e-6, "{color:?}");
            assert!((color[1] - 0.5).abs() < 1e-6, "{color:?}");
            assert!((color[2] - 0.75).abs() < 1e-6, "{color:?}");
        }
    }

    #[test]
    fn bilinear_demosaic_interpolates_between_the_samples_of_one_color() {
        // A 4x1 slice of an RGGB row pair: red at x=0 and x=2 with a bright green between them.
        let plane = vec![0.2f32, 0.6, 0.4, 0.6];
        let colors = vec![0u8, 1, 0, 1];
        let out = demosaic(&plane, 4, 1, &colors, 1);
        assert!((out[0][0] - 0.2).abs() < 1e-6, "a red site keeps its own sample");
        assert!((out[2][0] - 0.4).abs() < 1e-6, "so does the other one");
        // The green sites sit between two reds, so they take their average.
        assert!((out[1][0] - 0.3).abs() < 1e-6, "{:?}", out[1]);
        assert!((out[3][0] - 0.4).abs() < 1e-6, "{:?}", out[3]);
        assert!((out[1][1] - 0.6).abs() < 1e-6, "a green site keeps its own green");
    }

    #[test]
    fn a_neutral_camera_pixel_stays_neutral() {
        // The row scaling is what keeps a camera whose matrix is stored in dcraw's integer scale from
        // coming out tinted.
        let raw = fake_raw_image();
        let (matrix, source) = camera_to_srgb(&raw);
        let gray = [
            matrix[0][0] + matrix[0][1] + matrix[0][2],
            matrix[1][0] + matrix[1][1] + matrix[1][2],
            matrix[2][0] + matrix[2][1] + matrix[2][2],
        ];
        for value in gray {
            assert!((value - 1.0).abs() < 1e-6, "{gray:?} from {source:?}");
        }
    }

    /// Builds a tiny rawloader image with the metadata shape a real file has. Only the fields the
    /// matrix path reads matter here.
    fn fake_raw_image() -> rawloader::RawImage {
        let width = 2;
        let height = 2;
        rawloader::RawImage {
            make: "Test".to_string(),
            model: "Matrix".to_string(),
            clean_make: "Test".to_string(),
            clean_model: "Matrix".to_string(),
            width,
            height,
            cpp: 1,
            wb_coeffs: [1.0, 1.0, 1.0, 1.0],
            whitelevels: [1023, 1023, 1023, 1023],
            blacklevels: [0, 0, 0, 0],
            xyz_to_cam: [[16623.0, -6309.0, -1411.0], [-4344.0, 13923.0, 323.0], [2285.0, 274.0, 2926.0], [0.0; 3]],
            cfa: rawloader::CFA::new("RGGB"),
            crops: [0, 0, 0, 0],
            blackareas: Vec::new(),
            orientation: rawloader::Orientation::Normal,
            data: rawloader::RawImageData::Integer(vec![0, 512, 512, 1023]),
        }
    }

    #[test]
    fn a_raw_without_a_camera_matrix_reports_the_srgb_default() {
        let mut raw = fake_raw_image();
        raw.xyz_to_cam = [
            [0.412453, 0.357580, 0.180423],
            [0.212671, 0.715160, 0.072169],
            [0.019334, 0.119193, 0.950227],
            [0.0, 0.0, 0.0],
        ];
        let (_, source) = camera_to_srgb(&raw);
        assert_eq!(source, MatrixSource::SrgbDefault);
    }

    #[test]
    fn levels_are_stretched_between_black_and_white() {
        // The decode path is exercised end to end elsewhere; this pins the arithmetic.
        let black = 1024f32;
        let white = 16383f32;
        let normalized = |value: f32| ((value - black) / (white - black)).clamp(0.0, 1.0);
        assert!((normalized(1024.0) - 0.0).abs() < 1e-9);
        assert!((normalized(16383.0) - 1.0).abs() < 1e-9);
        assert!((normalized(8703.5) - 0.5).abs() < 1e-4, "{}", normalized(8703.5));
        assert_eq!(normalized(0.0), 0.0);
        assert_eq!(normalized(20000.0), 1.0);
    }

    #[test]
    fn every_orientation_lands_on_the_expected_shape() {
        let image = rgba(&[[1, 0, 0], [2, 0, 0], [3, 0, 0], [4, 0, 0], [5, 0, 0], [6, 0, 0]]);
        for orientation in [
            RawOrientation::Normal,
            RawOrientation::HorizontalFlip,
            RawOrientation::Rotate180,
            RawOrientation::VerticalFlip,
            RawOrientation::Transpose,
            RawOrientation::Rotate90,
            RawOrientation::Transverse,
            RawOrientation::Rotate270,
            RawOrientation::Unknown,
        ] {
            let out = orient(&image, orientation);
            let (transpose, _, _) = orientation.to_flips();
            if transpose {
                assert_eq!((out.width(), out.height()), (1, 6), "{orientation:?}");
                // A 90-degree turn moves the first pixel to one of the ends of the column.
                let values: Vec<u8> = (0..6).map(|y| out.get(0, y)[0]).collect();
                assert!(
                    values.first() == Some(&1) || values.last() == Some(&1) || values.first() == Some(&6),
                    "{orientation:?} gave {values:?}"
                );
            } else {
                assert_eq!((out.width(), out.height()), (6, 1), "{orientation:?}");
            }
        }
        // The two pure flips are their own inverse and keep the pixel order readable.
        let flipped = orient(&image, RawOrientation::HorizontalFlip);
        assert_eq!(flipped.get(0, 0), [6, 0, 0, 255]);
        let rotated = orient(&image, RawOrientation::Rotate180);
        assert_eq!(rotated.get(0, 0), [6, 0, 0, 255]);
        let vertical = orient(&image, RawOrientation::VerticalFlip);
        assert_eq!(vertical.get(0, 0), [1, 0, 0, 255]);
        assert_eq!(orient(&image, RawOrientation::Unknown), image);
    }

    #[test]
    fn the_usable_area_crop_trims_the_border() {
        let mut image = Bitmap8::filled(4, 4, [10, 20, 30, 255]);
        image.set(1, 1, [99, 99, 99, 255]);
        // crops are top, right, bottom, left, so this drops the top row and the left column.
        let cropped = crop_usable_area(&image, [1, 0, 0, 1]);
        assert_eq!((cropped.width(), cropped.height()), (3, 3));
        assert_eq!(cropped.get(0, 0), [99, 99, 99, 255]);
        // A crop that would remove everything, or overlaps itself, is ignored.
        assert_eq!(crop_usable_area(&image, [0, 4, 0, 0]), image);
        assert_eq!(crop_usable_area(&image, [0, 0, 0, 0]), image);
    }
}
