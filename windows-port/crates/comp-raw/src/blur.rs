//! Edge-clamped box blur, the only spatial primitive the effects and detail kernels use.
//!
//! Ported from `box_blur_plane` in compositor_mac/Compositor/Rendering/AdjustPixels.c, including its
//! running-sum window so the result matches pixel for pixel.

/// `dst` receives the blurred `src`; the two must not be the same slice.
pub(crate) fn box_blur_plane(src: &[f32], dst: &mut [f32], width: usize, height: usize, radius: i64) {
    assert_eq!(src.len(), width * height, "the plane must hold one value per pixel");
    assert_eq!(dst.len(), width * height, "the plane must hold one value per pixel");
    if width == 0 || height == 0 {
        return;
    }
    if radius < 1 {
        dst.copy_from_slice(src);
        return;
    }
    let window = (radius * 2 + 1) as f64;
    let mut temp = vec![0f32; width * height];
    for y in 0..height {
        let row = y * width;
        let mut sum = 0.0;
        for k in -radius..=radius {
            sum += src[row + clamped_index(k, width)] as f64;
        }
        for x in 0..width {
            temp[row + x] = (sum / window) as f32;
            sum += src[row + clamped_index(x as i64 + radius + 1, width)] as f64;
            sum -= src[row + clamped_index(x as i64 - radius, width)] as f64;
        }
    }
    for x in 0..width {
        let mut sum = 0.0;
        for k in -radius..=radius {
            sum += temp[clamped_index(k, height) * width + x] as f64;
        }
        for y in 0..height {
            dst[y * width + x] = (sum / window) as f32;
            sum += temp[clamped_index(y as i64 + radius + 1, height) * width + x] as f64;
            sum -= temp[clamped_index(y as i64 - radius, height) * width + x] as f64;
        }
    }
}

/// The kernel's `clamped_index`: negative indices and past-the-end indices land on the border.
#[inline]
pub(crate) fn clamped_index(index: i64, limit: usize) -> usize {
    if index < 0 {
        0
    } else if index as usize >= limit {
        limit - 1
    } else {
        index as usize
    }
}

/// `effects_radius`: a radius in preview pixels, rounded, never below 1 and never above 64.
pub(crate) fn effects_radius(base: f64, scale: f64) -> i64 {
    let mut radius = base * if scale > 0.0 { scale } else { 1.0 };
    if radius < 1.0 {
        radius = 1.0;
    }
    if radius > 64.0 {
        radius = 64.0;
    }
    radius.round() as i64
}

/// `detail_radius`: sharper's own scale, 0.5…64 in preview pixels.
pub(crate) fn detail_radius(slider: f64, scale: f64) -> f64 {
    let base = 0.5 + (slider / 100.0) * 2.5;
    let mut radius = base * if scale > 0.0 { scale } else { 1.0 };
    if radius < 0.5 {
        radius = 0.5;
    }
    if radius > 64.0 {
        radius = 64.0;
    }
    radius
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_radius_copies() {
        let src = vec![1.0f32, 2.0, 3.0, 4.0];
        let mut dst = vec![0f32; 4];
        box_blur_plane(&src, &mut dst, 2, 2, 0);
        assert_eq!(dst, src);
    }

    #[test]
    fn a_flat_plane_survives_any_radius() {
        let src = vec![0.4f32; 12];
        let mut dst = vec![0f32; 12];
        box_blur_plane(&src, &mut dst, 4, 3, 5);
        for value in dst {
            assert!((value - 0.4).abs() < 1e-6);
        }
    }

    #[test]
    fn the_border_clamps_rather_than_darkening() {
        // The left column stays bright because the window clamps instead of sampling black.
        let src = vec![1.0f32, 0.0, 0.0, 0.0];
        let mut dst = vec![0f32; 4];
        box_blur_plane(&src, &mut dst, 4, 1, 1);
        assert!(dst[0] > dst[1], "{} vs {}", dst[0], dst[1]);
    }

    #[test]
    fn radii_follow_the_kernel_bounds() {
        assert_eq!(effects_radius(0.2, 1.0), 1);
        assert_eq!(effects_radius(4.0, 1.0), 4);
        assert_eq!(effects_radius(1000.0, 1.0), 64);
        assert_eq!(effects_radius(2.0, 2.0), 4);
        assert!((detail_radius(0.0, 1.0) - 0.5).abs() < 1e-12);
        assert!((detail_radius(100.0, 1.0) - 3.0).abs() < 1e-12);
    }
}
