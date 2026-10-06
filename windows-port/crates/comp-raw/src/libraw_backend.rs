//! Supplementary camera raw decoding through LibRaw.
//!
//! This module is only compiled with the `libraw` feature. It exists for the files the pure-Rust
//! decoder cannot read: CR3, DNG whose sensor data is lossy JPEG, and camera bodies missing from
//! rawloader's database. rawloader always runs first (see `crate::decode`), so a build without this
//! feature behaves exactly as before and nothing here is a dependency of the normal path.
//!
//! The C API is used rather than the C++ one, and only through the scalar accessors LibRaw exports
//! (`libraw_get_*` / `libraw_set_*`), because the two structs this file does declare are the ones with
//! a pinned, audited layout: the processed image header and the leading fields of `libraw_iparams_t`,
//! both checked against LibRaw 0.21.4's own headers. Setting the output parameters through the
//! accessors means the large `libraw_output_params_t` never has to be mirrored at all.
//!
//! LibRaw applies the black level, the demosaic, the white balance, the camera matrix and the sRGB
//! transfer function itself, so its output is the same kind of image the rest of the pipeline already
//! consumes: sRGB-encoded straight-alpha RGBA. The grade then runs on top of it unchanged.

use std::ffi::{c_char, c_int, c_uint, c_void, CStr};
use std::path::{Path, PathBuf};

use comp_core::Bitmap8;

use crate::error::{Error, Result};
use crate::vendor::{MatrixSource, RawMetadata, RawOrientation, SensorEngine, VendorImage, WhiteBalanceSource};

#[repr(C)]
struct LibrawData {
    _private: [u8; 0],
}

/// `libraw_processed_image_t`, LibRaw 0.21.4 (`libraw/libraw_types.h`). `data` is the flexible array
/// member the header declares as `data[1]`, so it must stay a zero-length array rather than a
/// pointer: a pointer field would be eight-byte aligned and Rust would place it at offset 24, while
/// the C struct puts the first pixel byte at offset 16. Reading through the shifted pointer is an
/// access violation, which is exactly what the CR3 sample did before this was a `[u8; 0]`.
#[repr(C)]
struct LibrawProcessedImage {
    image_type: c_int,
    height: u16,
    width: u16,
    colors: u16,
    bits: u16,
    data_size: c_uint,
    data: [u8; 0],
}

/// `LibRaw_image_formats` from LibRaw 0.21.4.
const LIBRAW_IMAGE_BITMAP: c_int = 2;

/// The leading fields of `libraw_iparams_t`, LibRaw 0.21.4. Everything after `xmpdata` is irrelevant
/// here, and the fields that are read are the strings plus `filters`, which holds the Bayer pattern.
#[repr(C)]
struct LibrawIparams {
    guard: [c_char; 4],
    make: [c_char; 64],
    model: [c_char; 64],
    software: [c_char; 64],
    normalized_make: [c_char; 64],
    normalized_model: [c_char; 64],
    maker_index: c_uint,
    raw_count: c_uint,
    dng_version: c_uint,
    is_foveon: c_uint,
    colors: c_int,
    filters: c_uint,
    xtrans: [[c_char; 6]; 6],
    xtrans_abs: [[c_char; 6]; 6],
    cdesc: [c_char; 5],
}

extern "C" {
    fn libraw_init(flags: c_uint) -> *mut LibrawData;
    fn libraw_open_buffer(lr: *mut LibrawData, buffer: *const c_void, size: usize) -> c_int;
    #[cfg(windows)]
    fn libraw_open_wfile(lr: *mut LibrawData, file: *const u16) -> c_int;
    #[cfg(not(windows))]
    fn libraw_open_file(lr: *mut LibrawData, file: *const c_char) -> c_int;
    fn libraw_unpack(lr: *mut LibrawData) -> c_int;
    fn libraw_dcraw_process(lr: *mut LibrawData) -> c_int;
    fn libraw_dcraw_make_mem_image(lr: *mut LibrawData, errcode: *mut c_int) -> *mut LibrawProcessedImage;
    fn libraw_dcraw_clear_mem(image: *mut LibrawProcessedImage);
    fn libraw_free_image(lr: *mut LibrawData);
    fn libraw_close(lr: *mut LibrawData);
    fn libraw_strerror(code: c_int) -> *const c_char;
    fn libraw_version() -> *const c_char;
    fn libraw_unpack_function_name(lr: *mut LibrawData) -> *const c_char;
    fn libraw_get_iparams(lr: *mut LibrawData) -> *mut LibrawIparams;
    fn libraw_get_raw_width(lr: *mut LibrawData) -> c_int;
    fn libraw_get_raw_height(lr: *mut LibrawData) -> c_int;
    fn libraw_get_cam_mul(lr: *mut LibrawData, index: c_int) -> f32;
    fn libraw_get_pre_mul(lr: *mut LibrawData, index: c_int) -> f32;
    fn libraw_get_rgb_cam(lr: *mut LibrawData, row: c_int, column: c_int) -> f32;
    fn libraw_get_color_maximum(lr: *mut LibrawData) -> c_int;
    fn libraw_set_output_bps(lr: *mut LibrawData, value: c_int);
    fn libraw_set_output_color(lr: *mut LibrawData, value: c_int);
    fn libraw_set_no_auto_bright(lr: *mut LibrawData, value: c_int);
    fn libraw_set_user_mul(lr: *mut LibrawData, index: c_int, value: f32);
}

/// True when this build carries the supplementary decoder.
pub const fn available() -> bool {
    true
}

/// The LibRaw version the binary is linked against, for diagnostics and for the test that proves the
/// backend is really the one answering.
pub fn version() -> String {
    unsafe {
        let pointer = libraw_version();
        if pointer.is_null() {
            "unknown".to_string()
        } else {
            CStr::from_ptr(pointer).to_string_lossy().into_owned()
        }
    }
}

/// Owns the LibRaw handle so every exit path closes it.
struct Handle(*mut LibrawData);

impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { libraw_close(self.0) }
    }
}

/// How LibRaw is handed the file. The file datastream is LibRaw's native path and the one its own
/// tools use; a memory buffer is offered for callers that only have bytes, with the caveat recorded in
/// NOTES.md: LibRaw 0.21.4's CR3 path faults when it is fed a buffer (its CRX decoder seeks through
/// the stream in a way the buffer datastream does not survive), while the same file decodes from disk.
enum Input {
    File(PathBuf),
    Buffer(Vec<u8>),
}

/// Decodes a camera raw file with LibRaw, from a path. `fallback_reason` is why the pure-Rust decoder
/// was not the one that answered, recorded in the metadata so a caller can see who decoded the file
/// and why.
pub fn decode_libraw_file(path: &Path, fallback_reason: Option<String>) -> Result<VendorImage> {
    let owned = path.to_path_buf();
    crate::vendor::run_on_decoder_thread(move || decode_input(Input::File(owned), fallback_reason))
}

/// Decodes camera raw bytes with LibRaw. Callers that have a path should use `decode_libraw_file`.
pub fn decode_libraw_bytes(bytes: &[u8], fallback_reason: Option<String>) -> Result<VendorImage> {
    let owned = bytes.to_vec();
    crate::vendor::run_on_decoder_thread(move || decode_input(Input::Buffer(owned), fallback_reason))
}

fn decode_input(input: Input, fallback_reason: Option<String>) -> Result<VendorImage> {
    unsafe {
        let handle = libraw_init(0);
        if handle.is_null() {
            return Err(Error::Vendor("LibRaw could not be initialized".to_string()));
        }
        let handle = Handle(handle);
        let raw = handle.0;

        let code = match &input {
            Input::File(path) => open_path(raw, path),
            Input::Buffer(bytes) => libraw_open_buffer(raw, bytes.as_ptr() as *const c_void, bytes.len()),
        };
        if code != 0 {
            return Err(step_error("LibRaw could not open this file", code));
        }

        // The output contract: 8 bits per channel, sRGB, no automatic brightness. Auto brightness
        // would make the result depend on the picture's own histogram, and the pipeline above this
        // one is where exposure belongs.
        libraw_set_output_bps(raw, 8);
        libraw_set_output_color(raw, 1);
        libraw_set_no_auto_bright(raw, 1);

        // As-shot white balance: LibRaw's C API has no setter for "use camera white balance", so the
        // camera multipliers are read and handed back as user multipliers. Without usable camera
        // values LibRaw's own choice (daylight, from its camera database) is left in place.
        let camera_mul = [0, 1, 2, 3].map(|index| libraw_get_cam_mul(raw, index));
        let (white_balance, wb_source) = if let Some(normalized) = normalize_multipliers(camera_mul) {
            for (index, value) in normalized.iter().enumerate() {
                libraw_set_user_mul(raw, index as c_int, *value);
            }
            (normalized, WhiteBalanceSource::Camera)
        } else {
            let pre_mul = [0, 1, 2, 3].map(|index| libraw_get_pre_mul(raw, index));
            match normalize_multipliers(pre_mul) {
                Some(normalized) => (normalized, WhiteBalanceSource::Neutral6500K),
                None => ([1.0; 4], WhiteBalanceSource::GrayWorld),
            }
        };

        let code = libraw_unpack(raw);
        if code != 0 {
            return Err(step_error("LibRaw could not unpack this camera raw", code));
        }
        let code = libraw_dcraw_process(raw);
        if code != 0 {
            return Err(step_error("LibRaw could not develop this camera raw", code));
        }
        let mut error_code: c_int = 0;
        let image = libraw_dcraw_make_mem_image(raw, &mut error_code);
        if image.is_null() || error_code != 0 {
            if !image.is_null() {
                libraw_dcraw_clear_mem(image);
            }
            if error_code != 0 {
                return Err(step_error("LibRaw could not produce an image", error_code));
            }
            return Err(Error::Vendor("LibRaw returned no image".to_string()));
        }

        let header = &*image;
        let (width, height) = (header.width as usize, header.height as usize);
        let result = if header.image_type != LIBRAW_IMAGE_BITMAP {
            Err(Error::Vendor(format!(
                "LibRaw returned an embedded preview (type {}) instead of a bitmap",
                header.image_type
            )))
        } else if header.bits != 8 || header.colors < 3 || width == 0 || height == 0 {
            Err(Error::Vendor(format!(
                "LibRaw returned {}x{} with {} bits and {} channels, which this front end does not read",
                width, height, header.bits, header.colors
            )))
        } else {
            let pixels = std::slice::from_raw_parts(header.data.as_ptr(), header.data_size as usize);
            let expected = width * height * header.colors as usize;
            if pixels.len() < expected {
                Err(Error::Vendor(format!(
                    "LibRaw returned {} bytes for {width}x{height}x{}",
                    pixels.len(),
                    header.colors
                )))
            } else {
                let mut rgba = Vec::with_capacity(width * height * 4);
                for pixel in pixels[..expected].chunks_exact(header.colors as usize) {
                    rgba.extend_from_slice(&pixel[..3]);
                    rgba.push(255);
                }
                Bitmap8::from_raw(width as u32, height as u32, rgba).map_err(Error::Core)
            }
        };
        libraw_dcraw_clear_mem(image);
        let image = result?;

        // What the file said about the shot, through the accessors only.
        let iparams = libraw_get_iparams(raw);
        let (make, model, cfa) = if iparams.is_null() {
            (String::new(), String::new(), String::new())
        } else {
            let iparams = &*iparams;
            (fixed_string(&iparams.make), fixed_string(&iparams.model), bayer_name(iparams.filters))
        };
        let decoder = {
            let pointer = libraw_unpack_function_name(raw);
            if pointer.is_null() {
                String::new()
            } else {
                CStr::from_ptr(pointer).to_string_lossy().into_owned()
            }
        };
        let matrix_source = camera_matrix(raw);
        let maximum = libraw_get_color_maximum(raw).max(0) as u16;
        let metadata = RawMetadata {
            make: make.clone(),
            model: model.clone(),
            clean_make: make,
            clean_model: model,
            cfa,
            width: libraw_get_raw_width(raw).max(0) as usize,
            height: libraw_get_raw_height(raw).max(0) as usize,
            // LibRaw hands back a developed image, so what arrives here has three channels.
            channels: 3,
            // LibRaw applies the black level internally and its C accessors do not expose it, so the
            // reported black is zero and the white is the level the file declared.
            black_levels: [0; 4],
            white_levels: [maximum; 4],
            white_balance,
            white_balance_source: wb_source,
            matrix_source,
            orientation: RawOrientation::Unknown,
            crops: [0, 0, 0, 0],
            engine: SensorEngine::LibRaw,
            decoder,
            fallback_reason,
        };
        // The image the library produced is already cropped and oriented the way LibRaw decided.
        libraw_free_image(raw);
        Ok(VendorImage { image, metadata })
    }
}

/// Opens a path with LibRaw's own datastream, which is what its command line tools do.
unsafe fn open_path(raw: *mut LibrawData, path: &Path) -> c_int {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        let wide: Vec<u16> = path.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
        libraw_open_wfile(raw, wide.as_ptr())
    }
    #[cfg(not(windows))]
    {
        match std::ffi::CString::new(path.to_string_lossy().as_bytes()) {
            Ok(text) => libraw_open_file(raw, text.as_ptr()),
            Err(_) => -1,
        }
    }
}

/// Reads one of the fixed-size C strings LibRaw stores, which are not guaranteed to be terminated.
fn fixed_string(field: &[c_char]) -> String {
    let bytes: Vec<u8> = field
        .iter()
        .take_while(|value| **value != 0)
        .map(|value| *value as u8)
        .collect();
    String::from_utf8_lossy(&bytes).trim().to_string()
}

/// The Bayer pattern from `libraw_iparams_t::filters`, using dcraw's `FC` bit layout.
fn bayer_name(filters: u32) -> String {
    if filters == 0 || filters == 9 {
        // No filter array recorded, or the 9 that marks an X-Trans sensor.
        return if filters == 9 { "X-Trans".to_string() } else { String::new() };
    }
    let mut name = String::with_capacity(4);
    for (row, column) in [(0u32, 0u32), (0, 1), (1, 0), (1, 1)] {
        let shift = (((row << 1) & 14) + (column & 1)) << 1;
        name.push(match (filters >> shift) & 3 {
            0 => 'R',
            1 => 'G',
            2 => 'B',
            _ => 'G',
        });
    }
    name
}

/// Whether LibRaw computed a camera-to-sRGB matrix. It applies the matrix itself, so only its
/// presence is reported here, exactly as the pure-Rust path reports the matrix's origin.
fn camera_matrix(raw: *mut LibrawData) -> MatrixSource {
    unsafe {
        let mut entries = Vec::with_capacity(9);
        for row in 0..3 {
            for column in 0..3 {
                entries.push(libraw_get_rgb_cam(raw, row as c_int, column as c_int));
            }
        }
        let usable = entries.iter().all(|value| value.is_finite()) && entries.iter().any(|value| value.abs() > 1e-6);
        if usable {
            MatrixSource::File
        } else {
            MatrixSource::SrgbDefault
        }
    }
}

/// Green-normalizes a set of channel multipliers, or None when they are missing.
fn normalize_multipliers(values: [f32; 4]) -> Option<[f32; 4]> {
    let green = values[1];
    if !green.is_finite() || green <= 0.0 {
        return None;
    }
    if !values.iter().take(3).all(|value| value.is_finite() && *value > 0.0) {
        return None;
    }
    Some([
        values[0] / green,
        1.0,
        values[2] / green,
        if values[3].is_finite() && values[3] > 0.0 { values[3] / green } else { 1.0 },
    ])
}

/// Turns a LibRaw status code into the error a caller can read.
fn step_error(context: &str, code: c_int) -> Error {
    let message = unsafe {
        let pointer = libraw_strerror(code);
        if pointer.is_null() {
            format!("error {code}")
        } else {
            CStr::from_ptr(pointer).to_string_lossy().into_owned()
        }
    };
    Error::Vendor(format!("{context}: {message} (LibRaw code {code})"))
}
