//! The scalar pixel math the macOS C kernels share, ported one function at a time from
//! `compositor_mac/Compositor/Rendering/AdjustPixels.c` so the numbers line up exactly.
//!
//! Every value here is straight (non-premultiplied) sRGB in 0…1 unless the name says otherwise.

/// The C kernel's own clamp: out-of-range values are pinned, NaN passes through unchanged
/// (`camera_clamp` in AdjustPixels.c tests the bounds rather than replacing the value).
#[inline]
pub(crate) fn camera_clamp(value: f64) -> f64 {
    if value < 0.0 {
        0.0
    } else if value > 1.0 {
        1.0
    } else {
        value
    }
}

/// The sRGB transfer function, decoding an encoded channel to linear light.
#[inline]
pub(crate) fn srgb_to_linear(encoded: f64) -> f64 {
    if encoded <= 0.04045 {
        encoded / 12.92
    } else {
        ((encoded + 0.055) / 1.055).powf(2.4)
    }
}

/// The sRGB transfer function, encoding linear light back to a stored channel.
#[inline]
pub(crate) fn linear_to_srgb(linear: f64) -> f64 {
    if linear <= 0.0 {
        return 0.0;
    }
    if linear >= 1.0 {
        return 1.0;
    }
    if linear <= 0.0031308 {
        linear * 12.92
    } else {
        1.055 * linear.powf(1.0 / 2.4) - 0.055
    }
}

/// Rec. 709 luminance of a straight sRGB color.
#[inline]
pub(crate) fn rec709(r: f64, g: f64, b: f64) -> f64 {
    0.2126 * r + 0.7152 * g + 0.0722 * b
}

/// Moves a color so its Rec. 709 luminance becomes `target`, keeping hue and chroma ratios.
/// Pure black cannot be scaled, so a lift paints neutral light of that luminance.
pub(crate) fn scale_luminance(rgb: &mut [f64; 3], target: f64) {
    let target = camera_clamp(target);
    let y = rec709(rgb[0], rgb[1], rgb[2]);
    if (target - y).abs() < 1e-8 {
        return;
    }
    if y < 1e-8 {
        if target > y {
            *rgb = [target, target, target];
        }
        return;
    }
    let scale = target / y;
    rgb[0] = camera_clamp(rgb[0] * scale);
    rgb[1] = camera_clamp(rgb[1] * scale);
    rgb[2] = camera_clamp(rgb[2] * scale);
}

/// Highlights: positive recovers bright pixels toward white, negative deepens them.
pub(crate) fn tone_highlights(y: f64, amount: f64) -> f64 {
    let t = camera_clamp((y - 0.5) / 0.5);
    let weight = t * t;
    if amount >= 0.0 {
        camera_clamp(y + amount * weight * (1.0 - y))
    } else {
        camera_clamp(y + amount * weight * (y - 0.5))
    }
}

/// Shadows: positive lifts dark pixels toward mid gray, negative crushes them.
pub(crate) fn tone_shadows(y: f64, amount: f64) -> f64 {
    let t = camera_clamp((0.5 - y) / 0.5);
    let weight = t * t;
    if amount >= 0.0 {
        camera_clamp(y + amount * weight * (0.5 - y))
    } else {
        camera_clamp(y + amount * weight * y)
    }
}

/// Whites: the top quarter is the white point, so +1 maps 0.875 to 1.
pub(crate) fn tone_whites(y: f64, amount: f64) -> f64 {
    if y <= 0.75 {
        return y;
    }
    camera_clamp(0.75 + (y - 0.75) * (1.0 + amount))
}

/// Blacks: the bottom quarter is the black point. Negative crushes toward 0, positive lifts toward 0.25.
pub(crate) fn tone_blacks(y: f64, amount: f64) -> f64 {
    if y >= 0.25 {
        return y;
    }
    camera_clamp(0.25 + (y - 0.25) * (1.0 - amount))
}

/// Vibrance then saturation, in one pass: vibrance spares already-saturated pixels, and spares skin
/// tones further, while saturation is a flat swing around Rec. 709 luminance.
pub(crate) fn vibrance_and_saturation(rgb: &mut [f64; 3], vibrance: f64, saturation: f64) {
    let [r, g, b] = *rgb;
    let lum = rec709(r, g, b);
    let maxc = r.max(g).max(b);
    let minc = r.min(g).min(b);
    let chroma = maxc - minc;
    let sat = if maxc <= 1e-8 { 0.0 } else { chroma / maxc };
    let mut hue = 0.0;
    if chroma > 1e-8 {
        if r >= g && r >= b {
            hue = 60.0 * ((g - b) / chroma).rem_euclid(6.0);
        } else if g >= r && g >= b {
            hue = 60.0 * ((b - r) / chroma + 2.0);
        } else {
            hue = 60.0 * ((r - g) / chroma + 4.0);
        }
        if hue < 0.0 {
            hue += 360.0;
        }
    }
    let mut skin = 0.0;
    if (10.0..=50.0).contains(&hue) {
        skin = if hue <= 30.0 { (hue - 10.0) / 20.0 } else { (50.0 - hue) / 20.0 };
        skin *= camera_clamp((sat - 0.15) / 0.35);
    }
    let mut amount = vibrance * (1.0 - sat);
    if vibrance > 0.0 {
        amount *= 1.0 - 0.7 * skin;
    }
    let factor = 1.0 + amount;
    let mut out = [
        camera_clamp(lum + (r - lum) * factor),
        camera_clamp(lum + (g - lum) * factor),
        camera_clamp(lum + (b - lum) * factor),
    ];
    let lum = rec709(out[0], out[1], out[2]);
    let factor = 1.0 + saturation;
    out[0] = camera_clamp(lum + (out[0] - lum) * factor);
    out[1] = camera_clamp(lum + (out[1] - lum) * factor);
    out[2] = camera_clamp(lum + (out[2] - lum) * factor);
    *rgb = out;
}

/// HSL with all three components in 0…1, matching the kernel's private `rgb_to_hsl`.
pub(crate) fn rgb_to_hsl(r: f64, g: f64, b: f64) -> (f64, f64, f64) {
    let maxc = r.max(g).max(b);
    let minc = r.min(g).min(b);
    let l = (maxc + minc) * 0.5;
    let d = maxc - minc;
    if d < 1e-6 {
        return (0.0, 0.0, l);
    }
    let s = d / (1.0 - (2.0 * l - 1.0).abs());
    let mut h = if maxc == r {
        ((g - b) / d).rem_euclid(6.0)
    } else if maxc == g {
        (b - r) / d + 2.0
    } else {
        (r - g) / d + 4.0
    };
    h /= 6.0;
    if h < 0.0 {
        h += 1.0;
    }
    (h, s, l)
}

fn hue_to_rgb(p: f64, q: f64, mut t: f64) -> f64 {
    if t < 0.0 {
        t += 1.0;
    }
    if t > 1.0 {
        t -= 1.0;
    }
    if t < 1.0 / 6.0 {
        p + (q - p) * 6.0 * t
    } else if t < 0.5 {
        q
    } else if t < 2.0 / 3.0 {
        p + (q - p) * (2.0 / 3.0 - t) * 6.0
    } else {
        p
    }
}

/// The inverse of `rgb_to_hsl`.
pub(crate) fn hsl_to_rgb(h: f64, s: f64, l: f64) -> [f64; 3] {
    if s <= 1e-6 {
        return [l, l, l];
    }
    let q = if l < 0.5 { l * (1.0 + s) } else { l + s - l * s };
    let p = 2.0 * l - q;
    [hue_to_rgb(p, q, h + 1.0 / 3.0), hue_to_rgb(p, q, h), hue_to_rgb(p, q, h - 1.0 / 3.0)]
}

/// Hue distance on the color wheel, 0…0.5.
#[inline]
pub(crate) fn circular_distance(a: f64, b: f64) -> f64 {
    let d = (a - b).abs();
    if d > 0.5 {
        1.0 - d
    } else {
        d
    }
}

/// Hue in degrees 0…360, the form the mixer and defringe ranges use.
pub(crate) fn pixel_hue_degrees(r: f64, g: f64, b: f64) -> f64 {
    let maxc = r.max(g).max(b);
    let minc = r.min(g).min(b);
    let chroma = maxc - minc;
    if chroma < 1e-6 {
        return 0.0;
    }
    let hue = if maxc == r {
        ((g - b) / chroma).rem_euclid(6.0)
    } else if maxc == g {
        (b - r) / chroma + 2.0
    } else {
        (r - g) / chroma + 4.0
    };
    let mut degrees = hue * 60.0;
    if degrees < 0.0 {
        degrees += 360.0;
    }
    degrees
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clamp_matches_the_c_kernel() {
        assert_eq!(camera_clamp(-1.0), 0.0);
        assert_eq!(camera_clamp(2.0), 1.0);
        assert_eq!(camera_clamp(0.25), 0.25);
        assert!(camera_clamp(f64::NAN).is_nan());
    }

    #[test]
    fn srgb_round_trips() {
        for step in 0..=64 {
            let encoded = step as f64 / 64.0;
            let back = linear_to_srgb(srgb_to_linear(encoded));
            assert!((back - encoded).abs() < 1e-12, "{encoded} -> {back}");
        }
    }

    #[test]
    fn scale_luminance_hits_the_target_and_lifts_black() {
        let mut color = [0.2, 0.4, 0.6];
        scale_luminance(&mut color, 0.5);
        assert!((rec709(color[0], color[1], color[2]) - 0.5).abs() < 1e-9);

        let mut black = [0.0, 0.0, 0.0];
        scale_luminance(&mut black, 0.25);
        assert_eq!(black, [0.25, 0.25, 0.25]);
    }

    #[test]
    fn tones_bend_only_their_own_end() {
        // Whites leave everything at or below 0.75 alone; blacks leave everything at or above 0.25 alone.
        assert_eq!(tone_whites(0.5, 1.0), 0.5);
        assert!(tone_whites(0.875, 1.0) > 0.875);
        assert_eq!(tone_blacks(0.5, -1.0), 0.5);
        assert!(tone_blacks(0.1, -1.0) < 0.1);

        // Highlights act above the midpoint, shadows below it, and both are flat at the ends.
        assert_eq!(tone_highlights(0.25, 1.0), 0.25);
        assert_eq!(tone_shadows(0.75, 1.0), 0.75);
        assert!(tone_highlights(1.0, 1.0) >= 1.0 - 1e-12);
        assert!(tone_highlights(0.8, -1.0) < 0.8);
        assert!(tone_shadows(0.2, 1.0) > 0.2);
    }

    #[test]
    fn hsl_round_trips_primaries() {
        let (h, s, l) = rgb_to_hsl(1.0, 0.0, 0.0);
        assert!((h - 0.0).abs() < 1e-12 && (s - 1.0).abs() < 1e-12 && (l - 0.5).abs() < 1e-12);
        let rgb = hsl_to_rgb(h, s, l);
        assert!((rgb[0] - 1.0).abs() < 1e-9 && rgb[1].abs() < 1e-9 && rgb[2].abs() < 1e-9);
        assert_eq!(pixel_hue_degrees(1.0, 0.0, 0.0), 0.0);
        assert!((pixel_hue_degrees(0.0, 1.0, 0.0) - 120.0).abs() < 1e-9);
        assert!((pixel_hue_degrees(0.0, 0.0, 1.0) - 240.0).abs() < 1e-9);
    }

    #[test]
    fn circular_distance_wraps() {
        assert!((circular_distance(0.9, 0.1) - 0.2).abs() < 1e-12);
        assert!((circular_distance(0.25, 0.25)).abs() < 1e-12);
    }

    #[test]
    fn vibrance_spares_saturated_pixels() {
        let mut muted = [0.6, 0.5, 0.45];
        let before = muted;
        vibrance_and_saturation(&mut muted, 1.0, 0.0);
        let muted_shift = (muted[0] - before[0]).abs();

        let mut vivid = [1.0, 0.05, 0.0];
        let before = vivid;
        vibrance_and_saturation(&mut vivid, 1.0, 0.0);
        let vivid_shift = (vivid[0] - before[0]).abs() + (vivid[1] - before[1]).abs();
        assert!(muted_shift > vivid_shift, "vibrance must favor muted colors");
    }
}
