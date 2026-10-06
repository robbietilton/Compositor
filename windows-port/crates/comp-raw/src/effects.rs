//! Camera Raw's Effects panel: Texture, Clarity, Dehaze, Glow and the post-crop Vignette, plus the
//! shared film Grain kernel.
//!
//! Ported from `adjust_camera_raw_effects` and `adjust_grain` in AdjustPixels.c.

use crate::blur::box_blur_plane;
use crate::blur::effects_radius;
use crate::math::{camera_clamp, rec709, scale_luminance};
use crate::raster::Raster;
use crate::settings::{RawGlowStyle, RawSettings};

pub(crate) fn apply_effects(raster: &mut Raster, settings: &RawSettings, scale: f64) {
    let width = raster.width;
    let height = raster.height;
    if width == 0 || height == 0 {
        return;
    }
    if settings.texture == 0.0
        && settings.clarity == 0.0
        && settings.dehaze == 0.0
        && !(settings.glow > 0.0)
        && settings.vignette_amount == 0.0
    {
        return;
    }
    let count = raster.len();
    let mut fine: Option<Vec<f32>> = None;
    let mut coarse: Option<Vec<f32>> = None;
    let mut glow_plane: Option<Vec<f32>> = None;
    if settings.texture != 0.0 || settings.clarity != 0.0 || settings.glow > 0.0 {
        let plane = raster.luma_plane();
        if settings.texture != 0.0 {
            let mut blurred = vec![0f32; count];
            box_blur_plane(&plane, &mut blurred, width, height, effects_radius(1.0, scale));
            fine = Some(blurred);
        }
        if settings.clarity != 0.0 {
            let mut blurred = vec![0f32; count];
            box_blur_plane(&plane, &mut blurred, width, height, effects_radius(4.0, scale));
            coarse = Some(blurred);
        }
        if settings.glow > 0.0 {
            let spread = settings.glow_spread / 100.0;
            let base = if settings.glow_style == RawGlowStyle::Bloom { 2.0 } else { 5.0 };
            let widened = (base * (1.0 + spread)).max(1.0);
            let radius = effects_radius(widened, scale);
            let threshold = (0.55 + 0.4 * (settings.glow_range / 100.0)) as f32;
            let denominator = (1.0 - threshold).max(0.05);
            let source: Vec<f32> = plane
                .iter()
                .map(|value| ((value - threshold) / denominator).clamp(0.0, 1.0))
                .collect();
            let mut blurred = vec![0f32; count];
            box_blur_plane(&source, &mut blurred, width, height, radius);
            glow_plane = Some(blurred);
        }
    }
    let warmth = settings.glow_warmth / 100.0;
    let (glow_red, glow_green, glow_blue, glow_gain) = if settings.glow_style == RawGlowStyle::Halation {
        // Halation's fringe is red. Warmth pushes it further that way, rather than toward yellow or blue.
        (1.0, 0.35 - 0.3 * warmth, 0.2 - 0.2 * warmth, 1.0)
    } else {
        (
            0.75 + 0.25 * warmth,
            0.6 + 0.2 * warmth,
            0.75 - 0.6 * warmth,
            if settings.glow_style == RawGlowStyle::Bloom { 1.4 } else { 1.0 },
        )
    };
    for y in 0..height {
        for x in 0..width {
            let index = raster.index(x, y);
            if raster.alpha[index] == 0 {
                continue;
            }
            let mut color = raster.rgb[index];
            if fine.is_some() || coarse.is_some() {
                let tone = rec709(color[0], color[1], color[2]);
                let mut detail = 0.0;
                if let Some(plane) = &fine {
                    detail += (settings.texture / 100.0) * (tone - plane[index] as f64);
                }
                if let Some(plane) = &coarse {
                    detail += (settings.clarity / 100.0) * (tone - plane[index] as f64);
                }
                if detail != 0.0 {
                    scale_luminance(&mut color, camera_clamp(tone + detail));
                }
            }
            if settings.dehaze != 0.0 {
                dehaze(&mut color, settings.dehaze);
            }
            if let Some(plane) = &glow_plane {
                if settings.glow > 0.0 {
                    let add = plane[index] as f64 * (settings.glow / 100.0) * glow_gain;
                    color[0] = camera_clamp(color[0] + add * glow_red);
                    color[1] = camera_clamp(color[1] + add * glow_green);
                    color[2] = camera_clamp(color[2] + add * glow_blue);
                }
            }
            vignette(
                &mut color,
                x,
                y,
                width,
                height,
                settings.vignette_amount,
                settings.vignette_midpoint,
                settings.vignette_roundness,
                settings.vignette_feather,
                settings.vignette_highlights,
                settings.vignette_style.kernel_value(),
            );
            raster.rgb[index] = color;
        }
    }
}

/// Dehaze raises contrast and saturation when positive and lifts the shadows when negative.
fn dehaze(color: &mut [f64; 3], amount: f64) {
    let d = amount / 100.0;
    let y = rec709(color[0], color[1], color[2]);
    let contrast = 1.0 + 0.8 * d;
    let pivot = 0.45 - 0.1 * if d > 0.0 { d } else { 0.0 };
    let mut target = camera_clamp(pivot + (y - 0.45) * contrast);
    if d < 0.0 {
        target = camera_clamp(target + (-d) * (1.0 - target) * 0.45);
    } else {
        target = camera_clamp(target - d * (0.4 - target).max(0.0));
    }
    scale_luminance(color, target);
    let target = rec709(color[0], color[1], color[2]);
    let saturation = 1.0 + 0.7 * d;
    color[0] = camera_clamp(target + (color[0] - target) * saturation);
    color[1] = camera_clamp(target + (color[1] - target) * saturation);
    color[2] = camera_clamp(target + (color[2] - target) * saturation);
}

/// The vignette's strength at one point: 0 at the middle of the frame, 1 past its edges.
fn vignette_mask_at(
    px: f64,
    py: f64,
    width: f64,
    height: f64,
    midpoint: f64,
    roundness: f64,
    feather: f64,
) -> f64 {
    let nx = px / width * 2.0 - 1.0;
    let ny = py / height * 2.0 - 1.0;
    let square = nx.abs().max(ny.abs());
    let circle = (nx * nx + ny * ny).sqrt() / std::f64::consts::SQRT_2;
    // Roundness mixes the square frame toward the inscribed circle.
    let shape = (1.0 - roundness / 100.0) * 0.5;
    let dist = circle + (square - circle) * shape;
    let start = (midpoint / 100.0) * 0.85;
    let soft = (feather / 100.0).max(0.05);
    let t = camera_clamp((dist - start) / soft);
    t * t * (3.0 - 2.0 * t)
}

#[allow(clippy::too_many_arguments)]
fn vignette(
    color: &mut [f64; 3],
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    amount: f64,
    midpoint: f64,
    roundness: f64,
    feather: f64,
    highlights: f64,
    style: i32,
) {
    if amount == 0.0 || width == 0 || height == 0 {
        return;
    }
    let mask = vignette_mask_at(
        x as f64 + 0.5,
        y as f64 + 0.5,
        width as f64,
        height as f64,
        midpoint,
        roundness,
        feather,
    );
    let mut effect = (amount / 100.0) * mask;
    // Highlight Priority eases a darkening vignette off bright pixels. The other styles do not.
    if effect < 0.0 && style == 0 {
        let bright = camera_clamp((rec709(color[0], color[1], color[2]) - 0.45) / 0.55);
        effect *= 1.0 - (highlights / 100.0) * bright;
    }
    if effect < 0.0 {
        let factor = 1.0 + effect;
        color[0] *= factor;
        color[1] *= factor;
        color[2] *= factor;
    } else if effect > 0.0 {
        for channel in color.iter_mut() {
            *channel += (1.0 - *channel) * effect;
        }
    }
    if style == 1 && mask > 0.0 {
        // Color Priority keeps the vignette from washing out the corners by pulling saturation down.
        let lum = rec709(color[0], color[1], color[2]);
        let saturation = 1.0 - 0.75 * mask * (amount / 100.0).abs();
        color[0] = camera_clamp(lum + (color[0] - lum) * saturation);
        color[1] = camera_clamp(lum + (color[1] - lum) * saturation);
        color[2] = camera_clamp(lum + (color[2] - lum) * saturation);
    }
}

/// Film grain. The pattern depends only on the pixel's document position and the seed, so a preview
/// crop shows the same grain as the full render.
pub(crate) fn apply_grain(raster: &mut Raster, settings: &RawSettings, scale: f64, seed: u32) {
    let amount = settings.grain_amount;
    let units_per_pixel = if scale > 0.0 { 1.0 / scale } else { 1.0 };
    if !(amount > 0.0) || !(units_per_pixel > 0.0) {
        return;
    }
    let size = if settings.grain_kernel_size() > 0.0 { settings.grain_kernel_size() } else { 1.0 };
    let strength = (if amount > 100.0 { 1.0 } else { amount / 100.0 }) * 0.35 * 255.0;
    let rough = if settings.grain_roughness < 0.0 {
        0.0
    } else if settings.grain_roughness > 100.0 {
        1.0
    } else {
        settings.grain_roughness / 100.0
    };
    let fine_seed = mix32(seed ^ 0xA511_E9B3);
    // Roughness adds smaller, less regular particles, but their size stays proportional to Size
    // instead of collapsing to one-pixel noise.
    let detail_size = (size * 0.35).max(0.5);
    for y in 0..raster.height {
        let v = (y as f64 + 0.5) * units_per_pixel;
        for x in 0..raster.width {
            let index = raster.index(x, y);
            let alpha = raster.alpha[index];
            if alpha == 0 {
                continue;
            }
            let u = (x as f64 + 0.5) * units_per_pixel;
            let smooth = grain_field(u, v, size, seed) as f64;
            let fine = grain_field(u, v, detail_size, fine_seed) as f64;
            let noise = smooth + (fine - smooth) * rough;
            let mut level = rec709(raster.rgb[index][0], raster.rgb[index][1], raster.rgb[index][2]);
            if level > 1.0 {
                level = 1.0;
            }
            // Film grain shows most in the midtones.
            let delta = noise * strength * (0.4 + 2.4 * level * (1.0 - level));
            let mut color = raster.rgb[index];
            for channel in color.iter_mut() {
                *channel = camera_clamp(*channel + delta / 255.0);
            }
            raster.rgb[index] = color;
        }
    }
}

/// `mix32`: the kernel's integer hash.
fn mix32(mut x: u32) -> u32 {
    x ^= x >> 16;
    x = x.wrapping_mul(0x7feb_352d);
    x ^= x >> 15;
    x = x.wrapping_mul(0x846c_a68b);
    x ^= x >> 16;
    x
}

/// A value in −1…1 for one integer lattice point: two uniform halves summed give a triangular spread,
/// closer to film grain than flat noise.
fn lattice(ix: i64, iy: i64, seed: u32) -> f32 {
    let hash = mix32((ix as u32).wrapping_mul(0x9E37_79B1) ^ mix32((iy as u32).wrapping_mul(0x85EB_CA77) ^ seed));
    (hash & 0xFFFF) as f32 / 65535.0 + (hash >> 16) as f32 / 65535.0 - 1.0
}

/// Smooth seeded noise whose features follow `scale` document pixels.
fn grain_field(u: f64, v: f64, scale: f64, seed: u32) -> f32 {
    let cell_x = (u / scale).floor();
    let cell_y = (v / scale).floor();
    let mut tx = (u / scale - cell_x) as f32;
    let mut ty = (v / scale - cell_y) as f32;
    tx = tx * tx * (3.0 - 2.0 * tx);
    ty = ty * ty * (3.0 - 2.0 * ty);
    let ix = cell_x as i64;
    let iy = cell_y as i64;
    let n00 = lattice(ix, iy, seed);
    let n10 = lattice(ix + 1, iy, seed);
    let n01 = lattice(ix, iy + 1, seed);
    let n11 = lattice(ix + 1, iy + 1, seed);
    let top = n00 + (n10 - n00) * tx;
    let bottom = n01 + (n11 - n01) * tx;
    // Blending neighboring lattice values narrows the spread; restore approximately its original range.
    (top + (bottom - top) * ty) * 1.6
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{RawGlowStyle, RawSettings, RawVignetteStyle};
    use comp_core::Bitmap8;

    /// A 9x9 gray frame with a bright center, so vignette and glow have something to work with.
    fn frame() -> Bitmap8 {
        let mut image = Bitmap8::filled(9, 9, [90, 90, 90, 255]);
        image.set(4, 4, [230, 230, 230, 255]);
        image
    }

    fn developed(settings: &RawSettings) -> Bitmap8 {
        crate::develop(&frame(), settings)
    }

    fn luma(image: &Bitmap8, x: u32, y: u32) -> f64 {
        let pixel = image.get(x, y);
        rec709(pixel[0] as f64 / 255.0, pixel[1] as f64 / 255.0, pixel[2] as f64 / 255.0)
    }

    #[test]
    fn idle_effects_leave_the_image_alone() {
        let mut raster = Raster::from_bitmap(&frame());
        apply_effects(&mut raster, &RawSettings::default(), 1.0);
        assert_eq!(raster.to_bitmap(), frame());
    }

    #[test]
    fn glow_settings_stay_idle_until_the_amount_moves() {
        // Range, spread and warmth are stored even at glow 0 and must change nothing.
        let settings = RawSettings {
            glow: 0.0,
            glow_range: 100.0,
            glow_spread: 80.0,
            glow_warmth: -50.0,
            ..RawSettings::default()
        };
        assert_eq!(developed(&settings), frame());
    }

    #[test]
    fn glow_brightens_and_halation_tints_red() {
        let diffuse = developed(&RawSettings { glow: 80.0, ..RawSettings::default() });
        assert!(luma(&diffuse, 0, 0) > luma(&frame(), 0, 0), "glow spreads light outward");

        let halation = developed(&RawSettings {
            glow: 80.0,
            glow_style: RawGlowStyle::Halation,
            glow_spread: 60.0,
            ..RawSettings::default()
        });
        let pixel = halation.get(4, 4);
        assert!(pixel[0] >= pixel[2], "the halation fringe stays red");
    }

    #[test]
    fn a_darkening_vignette_leaves_the_center_alone() {
        let settings = RawSettings { vignette_amount: -80.0, ..RawSettings::default() };
        let image = developed(&settings);
        assert!(luma(&image, 0, 0) < luma(&frame(), 0, 0), "corners darken");
        assert!(luma(&image, 4, 0) < luma(&frame(), 4, 0), "edge midpoints darken");
        assert!((luma(&image, 4, 4) - luma(&frame(), 4, 4)).abs() < 0.01, "the center holds");
    }

    #[test]
    fn a_lightening_vignette_brightens_the_corners() {
        let settings = RawSettings { vignette_amount: 80.0, ..RawSettings::default() };
        assert!(luma(&developed(&settings), 0, 0) > luma(&frame(), 0, 0));
    }

    #[test]
    fn highlight_priority_protects_bright_corners() {
        let mut image = frame();
        image.set(0, 0, [250, 250, 250, 255]);
        let neutral = RawSettings::default();
        let protected = RawSettings {
            vignette_amount: -80.0,
            vignette_highlights: 100.0,
            ..RawSettings::default()
        };
        let plain = crate::develop(&image, &RawSettings { vignette_amount: -80.0, ..neutral.clone() });
        let eased = crate::develop(&image, &protected);
        assert!(luma(&eased, 0, 0) > luma(&plain, 0, 0), "Highlights must ease the darkening");
    }

    #[test]
    fn texture_and_clarity_change_local_contrast() {
        let texture = developed(&RawSettings { texture: 80.0, ..RawSettings::default() });
        assert_ne!(texture, frame());
        let clarity = developed(&RawSettings { clarity: 80.0, ..RawSettings::default() });
        assert_ne!(clarity, frame());
    }

    #[test]
    fn dehaze_signs_are_opposite() {
        let positive = developed(&RawSettings { dehaze: 60.0, ..RawSettings::default() });
        let negative = developed(&RawSettings { dehaze: -60.0, ..RawSettings::default() });
        assert!(luma(&positive, 0, 0) < luma(&frame(), 0, 0), "dehaze deepens the shadows");
        assert!(luma(&negative, 0, 0) > luma(&frame(), 0, 0), "negative dehaze lifts them");
    }

    #[test]
    fn grain_is_seeded_and_optional() {
        let off = RawSettings::default();
        assert_eq!(developed(&off), frame());

        let grainy = RawSettings { grain_amount: 70.0, ..RawSettings::default() };
        let first = developed(&grainy);
        let second = developed(&grainy);
        assert_eq!(first, second, "the same seed draws the same grain");
        assert_ne!(first, frame());

        let mut other = Raster::from_bitmap(&frame());
        apply_grain(&mut other, &grainy, 1.0, 7);
        let mut reference = Raster::from_bitmap(&frame());
        apply_grain(&mut reference, &grainy, 1.0, 7);
        assert_eq!(other, reference);
        let mut different = Raster::from_bitmap(&frame());
        apply_grain(&mut different, &grainy, 1.0, 8);
        assert_ne!(different, reference, "a different seed draws different grain");
    }

    #[test]
    fn color_priority_vignette_removes_corner_color() {
        let mut image = frame();
        image.set(0, 0, [200, 90, 60, 255]);
        let settings = RawSettings {
            vignette_amount: -60.0,
            vignette_style: RawVignetteStyle::ColorPriority,
            ..RawSettings::default()
        };
        let plain = crate::develop(&image, &RawSettings { vignette_amount: -60.0, ..RawSettings::default() });
        let styled = crate::develop(&image, &settings);
        let saturation = |pixel: [u8; 4]| pixel[0] as i32 - pixel[2] as i32;
        assert!(
            saturation(styled.get(0, 0)) < saturation(plain.get(0, 0)),
            "Color Priority pulls the corners toward gray"
        );
    }

    #[test]
    fn extreme_effects_stay_bounded() {
        let settings = RawSettings {
            texture: 100.0,
            clarity: 100.0,
            dehaze: 100.0,
            glow: 100.0,
            glow_range: 100.0,
            glow_spread: 100.0,
            glow_warmth: 100.0,
            vignette_amount: 100.0,
            vignette_midpoint: 100.0,
            vignette_roundness: 100.0,
            vignette_feather: 0.0,
            vignette_highlights: 100.0,
            grain_amount: 100.0,
            ..RawSettings::default()
        };
        let image = developed(&settings);
        assert_eq!(image.width(), 9);
        assert_eq!(image.height(), 9);
    }
}
