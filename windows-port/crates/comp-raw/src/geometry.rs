//! The Geometry panel: rotation, perspective, aspect, zoom, offsets and Constrain Crop.
//!
//! The macOS filter builds this warp with Core Image's `CIPerspectiveTransform`, mapping the source
//! rectangle's four corners onto the quad `CameraRawGeometrySettings.outputCorners` computes. There is
//! no Core Image on Windows, so this module builds the same projective mapping by hand, inverts it and
//! samples the source itself. Corner placement, Guided corrections and Constrain Crop follow the Swift
//! code exactly; the only difference is the resampler (see NOTES.md).

use comp_core::Bitmap8;

use crate::raster::{quantize, Raster};
use crate::settings::RawGeometrySettings;

pub(crate) fn apply_geometry(image: &Bitmap8, geometry: &RawGeometrySettings) -> Bitmap8 {
    let settings = geometry.normalized();
    if !settings.adjusts() {
        return image.clone();
    }
    let width = image.width() as usize;
    let height = image.height() as usize;
    if width == 0 || height == 0 {
        return image.clone();
    }
    let (vertical, horizontal, rotation) = settings.effective_corrections();
    let destination = output_corners(width, height, vertical, horizontal, rotation, &settings);
    // Core Image measures y upward from the bottom-left corner, and so does the corner math.
    let source = [
        (0.0, height as f64),
        (width as f64, height as f64),
        (width as f64, 0.0),
        (0.0, 0.0),
    ];
    let Some(forward) = homography(&source, &destination) else {
        return image.clone();
    };
    let Some(inverse) = invert3(&forward) else {
        return image.clone();
    };
    let source_raster = Raster::from_bitmap(image);
    let mut warped = Raster {
        width,
        height,
        rgb: vec![[0.0, 0.0, 0.0]; width * height],
        alpha: vec![0; width * height],
    };
    for y in 0..height {
        let ci_y = height as f64 - (y as f64 + 0.5);
        for x in 0..width {
            let ci_x = x as f64 + 0.5;
            let (sx, sy, sw) = project(&inverse, ci_x, ci_y);
            if sw.abs() < 1e-12 {
                continue;
            }
            let (sx, sy) = (sx / sw, sy / sw);
            // Outside the source rectangle the warp is transparent, which is what Constrain Crop
            // later trims away.
            if sx < 0.0 || sy < 0.0 || sx > width as f64 || sy > height as f64 {
                continue;
            }
            let (rgb, alpha) = source_raster.sample_premultiplied_skipped(sx - 0.5, (height as f64 - sy) - 0.5);
            let index = y * width + x;
            warped.rgb[index] = rgb;
            warped.alpha[index] = quantize(alpha);
        }
    }
    let result = warped.to_bitmap();
    if settings.constrain_crop {
        constrain_crop(&result)
    } else {
        result
    }
}

/// Core Image corner positions of the warped quad, in y-up coordinates.
fn output_corners(
    width: usize,
    height: usize,
    vertical: f64,
    horizontal: f64,
    rotation: f64,
    settings: &RawGeometrySettings,
) -> [(f64, f64); 4] {
    let w = width as f64;
    let h = height as f64;
    let strength = settings.projection.strength();
    let v = vertical / 100.0 * w * 0.18 * strength;
    let hz = horizontal / 100.0 * h * 0.18 * strength;
    let aspect_scale = 1.0 + settings.aspect / 200.0;
    let zoom = 1.0 + settings.scale / 100.0;
    let shift_x = settings.offset_x / 100.0 * w * 0.15;
    let shift_y = settings.offset_y / 100.0 * h * 0.15;
    let mut top_left = (-v + shift_x, h + shift_y);
    let mut top_right = (w + v + shift_x, h + shift_y);
    let mut bottom_right = (w + hz + shift_x, -shift_y);
    let mut bottom_left = (-hz + shift_x, -shift_y);
    let center = (w / 2.0 + shift_x, h / 2.0 + shift_y);
    let radians = rotation * std::f64::consts::PI / 180.0;
    let (sin, cos) = radians.sin_cos();
    let rotate = |point: (f64, f64)| {
        let dx = point.0 - center.0;
        let dy = point.1 - center.1;
        (center.0 + dx * cos - dy * sin, center.1 + dx * sin + dy * cos)
    };
    top_left = rotate(top_left);
    top_right = rotate(top_right);
    bottom_right = rotate(bottom_right);
    bottom_left = rotate(bottom_left);
    if aspect_scale != 1.0 {
        let scale = |point: (f64, f64)| {
            (
                center.0 + (point.0 - center.0) * aspect_scale,
                center.1 + (point.1 - center.1) / aspect_scale,
            )
        };
        top_left = scale(top_left);
        top_right = scale(top_right);
        bottom_right = scale(bottom_right);
        bottom_left = scale(bottom_left);
    }
    if zoom != 1.0 {
        let zoom_point =
            |point: (f64, f64)| (center.0 + (point.0 - center.0) * zoom, center.1 + (point.1 - center.1) * zoom);
        top_left = zoom_point(top_left);
        top_right = zoom_point(top_right);
        bottom_right = zoom_point(bottom_right);
        bottom_left = zoom_point(bottom_left);
    }
    [top_left, top_right, bottom_right, bottom_left]
}

/// The 3x3 projective transform taking `source` corners onto `destination` corners, or None when the
/// four points are degenerate.
fn homography(source: &[(f64, f64); 4], destination: &[(f64, f64); 4]) -> Option<[f64; 9]> {
    let mut matrix = [[0.0f64; 9]; 8];
    for index in 0..4 {
        let (x, y) = source[index];
        let (dx, dy) = destination[index];
        matrix[index * 2] = [x, y, 1.0, 0.0, 0.0, 0.0, -x * dx, -y * dx, dx];
        matrix[index * 2 + 1] = [0.0, 0.0, 0.0, x, y, 1.0, -x * dy, -y * dy, dy];
    }
    let mut solution = [0.0f64; 8];
    for column in 0..8 {
        let pivot = (column..8).max_by(|a, b| {
            matrix[*a][column]
                .abs()
                .partial_cmp(&matrix[*b][column].abs())
                .unwrap_or(std::cmp::Ordering::Equal)
        })?;
        if matrix[pivot][column].abs() < 1e-12 {
            return None;
        }
        matrix.swap(column, pivot);
        let divisor = matrix[column][column];
        for entry in column..9 {
            matrix[column][entry] /= divisor;
        }
        for row in 0..8 {
            if row == column {
                continue;
            }
            let factor = matrix[row][column];
            if factor == 0.0 {
                continue;
            }
            for entry in column..9 {
                matrix[row][entry] -= factor * matrix[column][entry];
            }
        }
    }
    for (index, value) in solution.iter_mut().enumerate() {
        *value = matrix[index][8];
    }
    Some([
        solution[0], solution[1], solution[2], solution[3], solution[4], solution[5], solution[6], solution[7], 1.0,
    ])
}

/// Applies a 3x3 projective transform in homogeneous coordinates.
fn project(matrix: &[f64; 9], x: f64, y: f64) -> (f64, f64, f64) {
    (
        matrix[0] * x + matrix[1] * y + matrix[2],
        matrix[3] * x + matrix[4] * y + matrix[5],
        matrix[6] * x + matrix[7] * y + matrix[8],
    )
}

/// The inverse of a 3x3 homogeneous transform, via its adjugate.
fn invert3(matrix: &[f64; 9]) -> Option<[f64; 9]> {
    let determinant = matrix[0] * (matrix[4] * matrix[8] - matrix[5] * matrix[7])
        - matrix[1] * (matrix[3] * matrix[8] - matrix[5] * matrix[6])
        + matrix[2] * (matrix[3] * matrix[7] - matrix[4] * matrix[6]);
    if determinant.abs() < 1e-12 || !determinant.is_finite() {
        return None;
    }
    let inverse = [
        matrix[4] * matrix[8] - matrix[5] * matrix[7],
        matrix[2] * matrix[7] - matrix[1] * matrix[8],
        matrix[1] * matrix[5] - matrix[2] * matrix[4],
        matrix[5] * matrix[6] - matrix[3] * matrix[8],
        matrix[0] * matrix[8] - matrix[2] * matrix[6],
        matrix[2] * matrix[3] - matrix[0] * matrix[5],
        matrix[3] * matrix[7] - matrix[4] * matrix[6],
        matrix[1] * matrix[6] - matrix[0] * matrix[7],
        matrix[0] * matrix[4] - matrix[1] * matrix[3],
    ];
    Some(inverse.map(|value| value / determinant))
}

/// Trims the transparent border a warp leaves behind and scales what is left back into the original
/// frame, centered, exactly as the Swift code does after asking for the alpha bounds.
fn constrain_crop(image: &Bitmap8) -> Bitmap8 {
    let raster = Raster::from_bitmap(image);
    let Some((left, top, right, bottom)) = raster.alpha_bounds() else {
        return image.clone();
    };
    let crop_width = right - left;
    let crop_height = bottom - top;
    if crop_width < 1 || crop_height < 1 || (crop_width >= raster.width && crop_height >= raster.height) {
        return image.clone();
    }
    let scale = (raster.width as f64 / crop_width as f64).min(raster.height as f64 / crop_height as f64);
    let draw_width = crop_width as f64 * scale;
    let draw_height = crop_height as f64 * scale;
    let origin_x = (raster.width as f64 - draw_width) / 2.0;
    let origin_y = (raster.height as f64 - draw_height) / 2.0;
    let mut fitted = Raster {
        width: raster.width,
        height: raster.height,
        rgb: vec![[0.0, 0.0, 0.0]; raster.len()],
        alpha: vec![0; raster.len()],
    };
    for y in 0..raster.height {
        for x in 0..raster.width {
            let u = (x as f64 + 0.5 - origin_x) / scale;
            let v = (y as f64 + 0.5 - origin_y) / scale;
            if u < 0.0 || v < 0.0 || u > crop_width as f64 || v > crop_height as f64 {
                continue;
            }
            let (rgb, alpha) =
                raster.sample_premultiplied_skipped(left as f64 + u - 0.5, top as f64 + v - 0.5);
            let index = y * raster.width + x;
            fitted.rgb[index] = rgb;
            fitted.alpha[index] = quantize(alpha);
        }
    }
    fitted.to_bitmap()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{RawGeometrySettings, RawProjection, RawSettings, RawUprightMode};
    use comp_core::Bitmap8;

    /// A 16x16 frame with a marked center and a marked corner, so a warp's direction is visible.
    fn frame() -> Bitmap8 {
        let mut image = Bitmap8::filled(16, 16, [80, 80, 80, 255]);
        image.set(8, 8, [240, 240, 240, 255]);
        image.set(0, 0, [240, 40, 40, 255]);
        image
    }

    fn warped(geometry: RawGeometrySettings) -> Bitmap8 {
        let settings = RawSettings { geometry, ..RawSettings::default() };
        crate::develop(&frame(), &settings)
    }

    #[test]
    fn neutral_geometry_is_identity() {
        assert_eq!(warped(RawGeometrySettings::default()), frame());
    }

    #[test]
    fn guided_mode_without_usable_lines_does_nothing() {
        let geometry = RawGeometrySettings {
            upright: RawUprightMode::Guided,
            guides: vec![],
            ..RawGeometrySettings::default()
        };
        assert_eq!(warped(geometry.clone()), frame());
        // A line shorter than a hundredth of the frame cannot be read either.
        let too_short = RawGeometrySettings {
            upright: RawUprightMode::Guided,
            guides: vec![crate::settings::RawGeometryGuide { start_x: 0.5, start_y: 0.5, end_x: 0.505, end_y: 0.5 }],
            ..RawGeometrySettings::default()
        };
        assert_eq!(warped(too_short), frame());
    }

    #[test]
    fn rotation_moves_the_picture_and_keeps_the_frame() {
        let rotated = warped(RawGeometrySettings { rotate: 12.0, ..RawGeometrySettings::default() });
        assert_ne!(rotated, frame());
        assert_eq!((rotated.width(), rotated.height()), (16, 16));
    }

    #[test]
    fn perspective_and_offsets_change_pixels() {
        let vertical = warped(RawGeometrySettings { vertical: 60.0, ..RawGeometrySettings::default() });
        assert_ne!(vertical, frame());
        let horizontal = warped(RawGeometrySettings { horizontal: 60.0, ..RawGeometrySettings::default() });
        assert_ne!(horizontal, frame());
        let shifted = warped(RawGeometrySettings { offset_x: 50.0, offset_y: -50.0, ..RawGeometrySettings::default() });
        assert_ne!(shifted, frame());
    }

    #[test]
    fn rectilinear_projection_warps_less_than_perspective() {
        let corners = |projection: RawProjection| {
            output_corners(
                16,
                16,
                100.0,
                0.0,
                0.0,
                &RawGeometrySettings { projection, ..RawGeometrySettings::default() },
            )
        };
        let perspective = corners(RawProjection::Perspective);
        let rectilinear = corners(RawProjection::Rectilinear);
        // Vertical correction pushes the top corners sideways; Rectilinear does so at 55% strength.
        assert!(perspective[0].0.abs() > rectilinear[0].0.abs());
        assert!(rectilinear[0].0 != 0.0, "Rectilinear still warps");
    }

    #[test]
    fn scale_zooms_and_crop_keeps_the_frame() {
        let zoomed = warped(RawGeometrySettings { scale: 25.0, constrain_crop: true, ..RawGeometrySettings::default() });
        assert_eq!((zoomed.width(), zoomed.height()), (16, 16));
        assert_ne!(zoomed, frame());
    }

    #[test]
    fn constrain_crop_trims_the_empty_border_a_zoom_out_leaves() {
        // Shrinking the picture to half size leaves a transparent border all the way around, which is
        // the case Constrain Crop exists for.
        let geometry = RawGeometrySettings { scale: -50.0, ..RawGeometrySettings::default() };
        let uncropped = warped(geometry.clone());
        assert_eq!(uncropped.get(0, 0)[3], 0, "the border is cleared");
        let cropped = warped(RawGeometrySettings { constrain_crop: true, ..geometry });
        assert_eq!((cropped.width(), cropped.height()), (16, 16));
        assert!(cropped.get(0, 0)[3] > 0, "the crop pulls the picture back into the frame");
    }

    #[test]
    fn guided_lines_drive_rotation() {
        let (_, _, rotation) = crate::settings::guided_corrections(&[crate::settings::RawGeometryGuide {
            start_x: 0.1,
            start_y: 0.1,
            end_x: 0.9,
            end_y: 0.3,
        }]);
        assert!(rotation < 0.0, "a line falling to the right rotates the other way: {rotation}");
        let (vertical, horizontal, _) = crate::settings::guided_corrections(&[
            crate::settings::RawGeometryGuide { start_x: 0.1, start_y: 0.1, end_x: 0.9, end_y: 0.1 },
            crate::settings::RawGeometryGuide { start_x: 0.1, start_y: 0.1, end_x: 0.15, end_y: 0.9 },
        ]);
        assert_eq!(vertical, 25.0);
        assert_eq!(horizontal, 0.0);
    }

    #[test]
    fn the_homography_inverts_itself() {
        let source = [(0.0, 16.0), (16.0, 16.0), (16.0, 0.0), (0.0, 0.0)];
        let destination = [(2.0, 18.0), (15.0, 17.0), (16.5, 1.0), (-1.0, 0.5)];
        let forward = homography(&source, &destination).expect("the quad is not degenerate");
        let inverse = invert3(&forward).expect("invertible");
        for (x, y) in [(0.0, 0.0), (16.0, 16.0), (4.0, 9.0)] {
            let (dx, dy, dw) = project(&forward, x, y);
            let (rx, ry, rw) = project(&inverse, dx / dw, dy / dw);
            assert!((rx / rw - x).abs() < 1e-9 && (ry / rw - y).abs() < 1e-9);
        }
        assert!(invert3(&[0.0; 9]).is_none());
    }

    #[test]
    fn tiny_images_survive_every_slider() {
        let image = Bitmap8::from_raw(1, 1, vec![10, 20, 30, 255]).unwrap();
        let settings = RawSettings {
            geometry: RawGeometrySettings {
                rotate: 45.0,
                vertical: 100.0,
                horizontal: -100.0,
                aspect: 100.0,
                scale: -100.0,
                offset_x: 100.0,
                offset_y: 100.0,
                constrain_crop: true,
                ..RawGeometrySettings::default()
            },
            ..RawSettings::default()
        };
        let out = crate::develop(&image, &settings);
        assert_eq!((out.width(), out.height()), (1, 1));
    }
}
