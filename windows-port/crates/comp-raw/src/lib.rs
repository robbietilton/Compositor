//! Camera Raw for Windows: the parameter model and pixel pipeline behind the Camera Raw filter,
//! plus the entry points that turn a decoded raw buffer or file into a `comp_core::Bitmap8`.
//!
//! The behavior is a port of the macOS sources — `Compositor/Document/CameraRaw*.swift` for the
//! parameters and the kernel order, `Compositor/Rendering/AdjustPixels.c` and `LensPixels.c` for the
//! pixel math. The order the pipeline runs in, quoted from `CameraRawSettings.apply`:
//!
//! 1. Geometry (the warp runs on the source image, before any pixel kernel, and Constrain Crop trims
//!    the transparent border it leaves).
//! 2. Camera calibration (shadow tint, primary hue and saturation).
//! 3. Light and Color as one kernel: white-balance gains, exposure, contrast, highlights, shadows,
//!    whites, blacks, vibrance, saturation.
//! 4. Curve: the parametric curve, then the RGB point curve, then the per-channel point curves.
//! 5. Color Mixer: the eight families, then the picked point colors.
//! 6. Color Grading: the shadow, midtone and highlight wheels plus the global wheel.
//! 7. Effects: Texture, Clarity, Dehaze, Glow and Vignette, then Grain.
//! 8. Optics: distortion, chromatic aberration, defringe, lens-vignetting correction.
//! 9. Detail: luminance noise reduction, color noise reduction, then sharpening.
//!
//! Steps 2-9 run in one pass over a floating-point raster with straight alpha; the difference from
//! macOS's premultiplied 8-bit buffer is recorded in NOTES.md.
//!
//! `decode_raw_file` produces the pixels those steps start from: a camera raw file goes through the
//! pure-Rust sensor decoder in `vendor` (levels, white balance, demosaic, camera matrix, sRGB), a
//! rendered DNG or TIFF through the `image` crate.

mod blur;
mod calibration;
mod curve;
mod curve_color;
mod decode;
mod detail;
mod effects;
mod error;
mod geometry;
mod light;
#[cfg(feature = "libraw")]
mod libraw_backend;
mod math;
mod optics;
mod raster;
mod settings;
mod vendor;

pub use crate::curve::{
    linear_points, medium_contrast_points, strong_contrast_points, RawCurvePoint, RawCurveRegion, RawPointChannel,
};
pub use crate::decode::{
    decode_bytes, decode_file, decode_raw_bytes, decode_raw_file, develop_file, needs_demosaic_engine, DecodedImage,
    RawSource, SUPPORTED_CONTAINERS, VENDOR_RAW_EXTENSIONS,
};
pub use crate::vendor::{
    decode_vendor_bytes, decode_vendor_file, decode_vendor_planes, orient, MatrixSource, RawMetadata,
    RawOrientation, SensorEngine, VendorImage, VendorPlanes, WhiteBalanceSource,
};

/// True when this build carries the supplementary LibRaw decoder for CR3, DNG lossy JPEG and the
/// camera bodies rawloader does not know. False for the default pure-Rust build.
#[cfg(feature = "libraw")]
pub use crate::libraw_backend::available as libraw_available;
#[cfg(not(feature = "libraw"))]
pub fn libraw_available() -> bool {
    false
}

/// The LibRaw version this build links against, or an empty string when it carries none.
#[cfg(feature = "libraw")]
pub use crate::libraw_backend::version as libraw_version;
#[cfg(not(feature = "libraw"))]
pub fn libraw_version() -> String {
    String::new()
}
pub use crate::error::{Error, Result};
pub use crate::settings::{
    auto_balance, guided_corrections, RawCalibrationSettings, RawClipping, RawCurveSettings, RawDetailSettings,
    RawGeometryGuide,
    RawGeometrySettings, RawGlowStyle, RawGradeWheel, RawGradingSettings, RawGroupVisibility, RawMixerSettings,
    RawOpticsSettings, RawPointColor, RawProcessVersion, RawProjection, RawSettings, RawUprightMode, RawVignetteStyle,
    RawWhiteBalance, EXPOSURE_RANGE, TEMPERATURE_GAIN, TINT_GREEN, TINT_RED_BLUE, TONE_RANGE, UNIT_RANGE,
};

use comp_core::Bitmap8;

use crate::raster::Raster;

/// Develops an image: the full Camera Raw grade at one preview pixel per layer pixel and grain seed 0.
pub fn develop(image: &Bitmap8, settings: &RawSettings) -> Bitmap8 {
    develop_with(image, settings, 1.0, 0)
}

/// Develops an image for a preview of `scale` preview pixels per layer pixel, drawing grain with
/// `seed` so the pattern stays put while a panel is open.
pub fn develop_with(image: &Bitmap8, settings: &RawSettings, scale: f64, seed: u32) -> Bitmap8 {
    develop_inner(image, settings, scale, seed, None)
}

/// Preview only: the grade with Color Mixer > Point Color's reach shown, dimming every pixel outside
/// the picked color. `point_index` past the last picked color renders the plain grade.
pub fn develop_with_point_color(image: &Bitmap8, settings: &RawSettings, point_index: usize) -> Bitmap8 {
    develop_inner(image, settings, 1.0, 0, Some(point_index))
}

fn develop_inner(image: &Bitmap8, settings: &RawSettings, scale: f64, seed: u32, visualize: Option<usize>) -> Bitmap8 {
    let settings = settings.normalized();
    if settings.is_identity() && visualize.is_none() {
        return image.clone();
    }
    let mut current = if settings.adjusts_geometry() {
        geometry::apply_geometry(image, &settings.geometry)
    } else {
        image.clone()
    };
    let needs_raster = settings.adjusts_calibration()
        || settings.adjusts_light()
        || settings.adjusts_color()
        || settings.adjusts_curve()
        || settings.adjusts_mixer()
        || settings.adjusts_grading()
        || settings.adjusts_effects()
        || settings.adjusts_detail()
        || settings.adjusts_optics()
        || visualize.is_some();
    if !needs_raster || current.is_empty() {
        return current;
    }
    let mut raster = Raster::from_bitmap(&current);
    if settings.adjusts_calibration() {
        calibration::apply_calibration(&mut raster, &settings.calibration);
    }
    if settings.adjusts_light() || settings.adjusts_color() {
        light::adjust_light_color(&mut raster, &settings);
    }
    if settings.adjusts_curve() || settings.adjusts_mixer() || settings.adjusts_grading() || visualize.is_some() {
        curve_color::apply_curve_color(&mut raster, &settings, visualize);
    }
    if settings.adjusts_effects() {
        effects::apply_effects(&mut raster, &settings, scale);
        if settings.grain_amount > 0.0 {
            effects::apply_grain(&mut raster, &settings, scale, seed);
        }
    }
    if settings.adjusts_optics() {
        optics::apply_optics(&mut raster, &settings.optics);
    }
    if settings.adjusts_detail() {
        detail::apply_detail(&mut raster, &settings.detail, scale);
    }
    current = raster.to_bitmap();
    current
}

/// Develops an already-decoded RGBA buffer. Straight alpha, four bytes per pixel, exactly the shape
/// `comp_core::Bitmap8` stores, which is what a decoder hands over.
pub fn develop_buffer(width: u32, height: u32, rgba: &[u8], settings: &RawSettings) -> Result<Bitmap8> {
    develop_buffer_with(width, height, rgba, settings, 1.0, 0)
}

/// `develop_buffer` for a preview scale and grain seed.
pub fn develop_buffer_with(
    width: u32,
    height: u32,
    rgba: &[u8],
    settings: &RawSettings,
    scale: f64,
    seed: u32,
) -> Result<Bitmap8> {
    let image = Bitmap8::from_raw(width, height, rgba.to_vec()).map_err(Error::Core)?;
    Ok(develop_with(&image, settings, scale, seed))
}

/// Preview only: the clipping view Option-dragging a Light slider puts in place of the grade.
/// `RawClipping::Highlights` lights the clipped channels on black, `RawClipping::Shadows` paints them
/// dark on white. Only Light and Color run, exactly as `CameraRawSettings.apply` does when a clipping
/// view is requested.
pub fn clipping_view(image: &Bitmap8, settings: &RawSettings, clipping: RawClipping) -> Bitmap8 {
    let settings = settings.normalized();
    let mut raster = Raster::from_bitmap(image);
    light::adjust_light_color_clipping(&mut raster, &settings, clipping);
    raster.to_bitmap()
}

/// Preview only: the shadow and highlight clipping indicators painted over an already graded image —
/// blue over clipped shadows, red over clipped highlights.
pub fn clipping_indicator(image: &Bitmap8, shadows: bool, highlights: bool) -> Bitmap8 {
    if !shadows && !highlights {
        return image.clone();
    }
    let mut raster = Raster::from_bitmap(image);
    light::clip_indicator(&mut raster, shadows, highlights);
    raster.to_bitmap()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_image_survives_the_whole_pipeline() {
        let image = Bitmap8::new(0, 0);
        let settings = RawSettings {
            exposure: 2.0,
            texture: 50.0,
            grain_amount: 50.0,
            ..RawSettings::default()
        };
        let out = develop(&image, &settings);
        assert!(out.is_empty());
    }

    #[test]
    fn a_one_pixel_image_survives_the_whole_pipeline() {
        let image = Bitmap8::from_raw(1, 1, vec![90, 110, 130, 255]).unwrap();
        let settings = RawSettings {
            exposure: 1.0,
            contrast: 30.0,
            temperature: 40.0,
            texture: 40.0,
            clarity: 40.0,
            dehaze: 30.0,
            glow: 30.0,
            vignette_amount: -50.0,
            grain_amount: 40.0,
            detail: RawDetailSettings { sharpen_amount: 80.0, noise_luminance: 40.0, ..Default::default() },
            optics: RawOpticsSettings { distortion: 30.0, purple_amount: 40.0, ..Default::default() },
            ..RawSettings::default()
        };
        let out = develop(&image, &settings);
        assert_eq!((out.width(), out.height()), (1, 1));
    }

    #[test]
    fn the_point_color_view_dims_pixels_outside_the_pick() {
        let image = Bitmap8::from_raw(2, 1, vec![200, 40, 40, 255, 40, 200, 40, 255]).unwrap();
        let points = vec![RawPointColor { hue: 0.0, saturation: 0.9, luminance: 0.5, ..RawPointColor::default() }];
        let settings = RawSettings {
            mixer: RawMixerSettings { points, ..RawMixerSettings::default() },
            ..RawSettings::default()
        };
        let out = develop_with_point_color(&image, &settings, 0);
        assert!(out.get(0, 0)[0] > 60, "the picked red stays");
        assert!(out.get(1, 0)[1] < 100, "the green outside the pick is dimmed");
        // An index past the last pick renders the plain grade instead.
        assert_eq!(develop_with_point_color(&image, &settings, 4), image);
    }

    #[test]
    fn the_clipping_views_are_preview_only_overrides() {
        // tools/oracle.py agrees on both views: (255, 128, 128) lights only the clipped red channel,
        // and (0, 40, 200) paints the clipped channels dark.
        let image = Bitmap8::from_raw(2, 1, vec![0, 0, 0, 255, 255, 128, 128, 255]).unwrap();
        let settings = RawSettings::default();
        // The Option-drag view replaces the grade for the light kernel's range: the clipped red
        // channel stays lit and the other two go dark.
        let view = clipping_view(&image, &settings, RawClipping::Highlights);
        assert_ne!(view, image);
        assert_eq!(view.get(1, 0), [255, 0, 0, 255]);
        assert_eq!(view.get(0, 0), [0, 0, 0, 255], "an unclipped pixel keeps its value");
        // The indicators blend over the image instead of replacing it.
        assert_eq!(clipping_indicator(&image, false, false), image);
        let marked = clipping_indicator(&image, true, false);
        assert!(marked.get(0, 0)[2] > marked.get(0, 0)[0], "a clipped shadow goes blue");
        assert_eq!(marked.get(1, 0), [255, 128, 128, 255], "an unclipped pixel is untouched");
    }
}
