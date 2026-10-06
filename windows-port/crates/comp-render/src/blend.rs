//! The 24 blend modes and the source-over composite that applies them.
//!
//! Every formula here follows the W3C/PDF compositing specification, the one Photoshop follows, and every
//! one runs on sRGB-encoded values: the macOS original goes out of its way to blend in sRGB rather than
//! Core Image's default linear space, because over 40% gray a linear Color Dodge lands at 62% where
//! Photoshop says 100% (see `SeparableBlend.swift`). Soft Light is the Photoshop cubic, not Core Image's
//! approximation, which is up to 25 levels off with a light blend color.

use rayon::prelude::*;

use comp_core::BlendMode;

use crate::pixel::{round_u8, Surface};

const EPSILON: f32 = 1e-12;

/// One channel of a separable mode, both values in 0..1.
pub fn blend_channel(mode: BlendMode, cb: f32, cs: f32) -> f32 {
    let value = match mode {
        BlendMode::Normal => cs,
        BlendMode::Darken => cb.min(cs),
        BlendMode::Multiply => cb * cs,
        BlendMode::ColorBurn => {
            if cs <= 0.0 {
                0.0
            } else {
                1.0 - (1.0f32).min((1.0 - cb) / cs.max(EPSILON))
            }
        }
        BlendMode::LinearBurn => cb + cs - 1.0,
        BlendMode::Lighten => cb.max(cs),
        BlendMode::Screen => cb + cs - cb * cs,
        BlendMode::ColorDodge => {
            if cs >= 1.0 {
                1.0
            } else {
                (cb / (1.0 - cs).max(EPSILON)).min(1.0)
            }
        }
        BlendMode::LinearDodge => cb + cs,
        BlendMode::Overlay => blend_channel(BlendMode::HardLight, cs, cb),
        BlendMode::SoftLight => soft_light(cb, cs),
        BlendMode::HardLight => {
            if cs <= 0.5 {
                (2.0 * cs) * cb
            } else {
                let doubled = 2.0 * cs - 1.0;
                doubled + cb - doubled * cb
            }
        }
        BlendMode::VividLight => {
            if cs <= 0.5 {
                blend_channel(BlendMode::ColorBurn, cb, 2.0 * cs)
            } else {
                blend_channel(BlendMode::ColorDodge, cb, 2.0 * cs - 1.0)
            }
        }
        BlendMode::LinearLight => cb + 2.0 * cs - 1.0,
        BlendMode::PinLight => {
            if cs <= 0.5 {
                cb.min(2.0 * cs)
            } else {
                cb.max(2.0 * cs - 1.0)
            }
        }
        BlendMode::HardMix => {
            // Hard Mix is Vivid Light posterized: every channel lands on 0 or 1.
            if blend_channel(BlendMode::VividLight, cb, cs) < 0.5 {
                0.0
            } else {
                1.0
            }
        }
        BlendMode::Difference => (cb - cs).abs(),
        BlendMode::Exclusion => cb + cs - 2.0 * cb * cs,
        BlendMode::Subtract => cb - cs,
        BlendMode::Divide => {
            if cs <= 0.0 {
                1.0
            } else {
                (cb / cs.max(EPSILON)).min(1.0)
            }
        }
        // The component modes need all three channels at once.
        BlendMode::Hue | BlendMode::Saturation | BlendMode::Color | BlendMode::Luminosity => {
            return cs;
        }
    };
    value.clamp(0.0, 1.0)
}

/// The Photoshop soft light curve: a cubic below 25% backdrop, a square root above it. Core Image's own
/// filter is a different curve, which is why the original routes this mode through a filter it controls.
#[inline]
fn soft_light(cb: f32, cs: f32) -> f32 {
    if cs <= 0.5 {
        cb - (1.0 - 2.0 * cs) * cb * (1.0 - cb)
    } else {
        let d = if cb <= 0.25 { ((16.0 * cb - 12.0) * cb + 4.0) * cb } else { cb.max(0.0).sqrt() };
        cb + (2.0 * cs - 1.0) * (d - cb)
    }
}

/// The PDF luminance, the weights the component modes use.
#[inline]
fn lum(color: [f32; 3]) -> f32 {
    0.3 * color[0] + 0.59 * color[1] + 0.11 * color[2]
}

/// Pulls a color back into range without changing its luminance.
fn clip_color(mut color: [f32; 3]) -> [f32; 3] {
    let l = lum(color);
    let n = color[0].min(color[1]).min(color[2]);
    let x = color[0].max(color[1]).max(color[2]);
    if n < 0.0 {
        for c in color.iter_mut() {
            *c = l + (*c - l) * l / (l - n).max(EPSILON);
        }
    }
    if x > 1.0 {
        for c in color.iter_mut() {
            *c = l + (*c - l) * (1.0 - l) / (x - l).max(EPSILON);
        }
    }
    for c in color.iter_mut() {
        *c = c.clamp(0.0, 1.0);
    }
    color
}

/// A color moved to luminance `l`.
fn set_lum(color: [f32; 3], l: f32) -> [f32; 3] {
    let d = l - lum(color);
    clip_color([color[0] + d, color[1] + d, color[2] + d])
}

/// The spread between a color's brightest and darkest channels.
#[inline]
fn sat(color: [f32; 3]) -> f32 {
    color[0].max(color[1]).max(color[2]) - color[0].min(color[1]).min(color[2])
}

/// A color's channels rescaled to saturation `s`, keeping their order.
///
/// The channels are ranked by sorting rather than by comparing each one against the brightest and the
/// darkest: recovering the middle value as `r + g + b - min - max` and then testing it for equality is
/// a float comparison that one ulp of rounding defeats, which silently zeroes the middle channel.
fn set_sat(color: [f32; 3], s: f32) -> [f32; 3] {
    let mut order = [0usize, 1, 2];
    order.sort_by(|a, b| color[*a].partial_cmp(&color[*b]).unwrap_or(std::cmp::Ordering::Equal));
    let (cmin, cmid, cmax) = (color[order[0]], color[order[1]], color[order[2]]);
    let span = cmax - cmin;
    if span <= 0.0 {
        return [0.0; 3];
    }
    let scale = s / span;
    let mut out = [0.0f32; 3];
    out[order[0]] = 0.0;
    out[order[1]] = (cmid - cmin) * scale;
    out[order[2]] = (cmax - cmin) * scale;
    out
}

/// All three channels of one pixel, separable modes included.
pub fn blend_colors(mode: BlendMode, cb: [f32; 3], cs: [f32; 3]) -> [f32; 3] {
    match mode {
        BlendMode::Hue => set_lum(set_sat(cs, sat(cb)), lum(cb)),
        BlendMode::Saturation => set_lum(set_sat(cb, sat(cs)), lum(cb)),
        BlendMode::Color => set_lum(cs, lum(cb)),
        BlendMode::Luminosity => set_lum(cb, lum(cs)),
        _ => [
            blend_channel(mode, cb[0], cs[0]),
            blend_channel(mode, cb[1], cs[1]),
            blend_channel(mode, cb[2], cs[2]),
        ],
    }
}

/// Composites one premultiplied source texel over one premultiplied backdrop texel, both premultiplied.
///
/// `co = as (1 - ab) Cs + as ab B(Cb, Cs) + (1 - as) ab Cb` with `ao = as + ab (1 - as)`, the spec's
/// source-over with a blend function. The result stays premultiplied like its inputs: dividing it by
/// `ao` would store straight color in a premultiplied buffer, and every later composite would divide by
/// the alpha a second time. Straight colors appear only where the blend function is evaluated.
#[inline]
pub fn composite_texel(backdrop: [u8; 4], source: [u8; 4]) -> [u8; 4] {
    composite_texel_mode(BlendMode::Normal, backdrop, source)
}

/// The same, in a blend mode.
#[inline]
pub fn composite_texel_mode(mode: BlendMode, backdrop: [u8; 4], source: [u8; 4]) -> [u8; 4] {
    let alpha_s = source[3] as f32 / 255.0;
    if alpha_s <= 0.0 {
        return backdrop;
    }
    let alpha_b = backdrop[3] as f32 / 255.0;
    let inv_s = 1.0 - alpha_s;
    let inv_b = 1.0 - alpha_b;
    let mut cs = [0.0f32; 3];
    let mut cb = [0.0f32; 3];
    for c in 0..3 {
        cs[c] = source[c] as f32 / 255.0 / alpha_s;
        cb[c] = if alpha_b > 0.0 { backdrop[c] as f32 / 255.0 / alpha_b } else { 0.0 };
    }
    let blended = blend_colors(mode, cb, cs);
    let alpha_out = alpha_s + alpha_b * inv_s;
    if alpha_out <= 0.0 {
        return [0, 0, 0, 0];
    }
    let mut out = [0u8; 4];
    for c in 0..3 {
        let co = alpha_s * inv_b * cs[c] + alpha_s * alpha_b * blended[c] + inv_s * alpha_b * cb[c];
        out[c] = round_u8(co * 255.0);
    }
    out[3] = round_u8(alpha_out * 255.0);
    out
}

/// Composites a whole premultiplied surface over another, in place, across the cores.
///
/// The source's alpha already carries its opacity and its masks; the mode decides how the colors meet.
pub fn composite_surface(backdrop: &mut Surface, source: &Surface, mode: BlendMode) {
    debug_assert_eq!((backdrop.width(), backdrop.height()), (source.width(), source.height()));
    let row_bytes = backdrop.width() as usize * 4;
    let source_pixels = source.pixels();
    backdrop
        .pixels_mut()
        .par_chunks_mut(row_bytes)
        .enumerate()
        .for_each(|(y, row)| {
            let source_row = &source_pixels[y * row_bytes..(y + 1) * row_bytes];
            for x in 0..row_bytes / 4 {
                let i = x * 4;
                let top = [source_row[i], source_row[i + 1], source_row[i + 2], source_row[i + 3]];
                if top[3] == 0 {
                    continue;
                }
                let under = [row[i], row[i + 1], row[i + 2], row[i + 3]];
                let out = composite_texel_mode(mode, under, top);
                row[i..i + 4].copy_from_slice(&out);
            }
        });
}


/// A rectangle of a canvas, in the canvas's own pixels: `(x, y, width, height)`.
pub type Box = (i64, i64, u32, u32);

/// Copies a dense box-sized surface into a larger one at `box_`.
///
/// A fully opaque source in Normal mode *is* the result - source-over leaves nothing of the backdrop - so
/// a dirty rectangle of an ordinary layer is a row-by-row copy rather than a blend.
pub fn copy_box(backdrop: &mut Surface, source: &Surface, box_: Box) {
    debug_assert_eq!((source.width(), source.height()), (box_.2, box_.3));
    let backdrop_width = backdrop.width();
    let bytes = box_.2 as usize * 4;
    for row in 0..box_.3 {
        let y = box_.1 + row as i64;
        if y < 0 || y >= backdrop.height() as i64 {
            continue;
        }
        let start = box_.0.max(0);
        let end = (box_.0 + box_.2 as i64).min(backdrop_width as i64);
        if end <= start {
            continue;
        }
        let from = (start - box_.0) as usize * 4;
        let to = from + (end - start) as usize * 4;
        let source_row = source.row(row);
        let dst_row = backdrop.row_mut(y as u32);
        dst_row[start as usize * 4..end as usize * 4].copy_from_slice(&source_row[from..to]);
        let _ = bytes;
    }
}

/// Composites a dense box-sized source into a larger backdrop at `box_`, in a blend mode.
///
/// Only the rectangle is walked: a layer that covers a corner of a dirty rectangle costs what that corner
/// costs, not what the rectangle costs.
pub fn composite_box(backdrop: &mut Surface, source: &Surface, mode: BlendMode, box_: Box) {
    debug_assert_eq!((source.width(), source.height()), (box_.2, box_.3));
    let row_bytes = backdrop.width() as usize * 4;
    let source_row_bytes = source.width() as usize * 4;
    let source_pixels = source.pixels();
    let backdrop_width = backdrop.width() as i64;
    let (x0, y0, width, _height) = box_;
    backdrop
        .pixels_mut()
        .par_chunks_mut(row_bytes)
        .enumerate()
        .for_each(|(y, row)| {
            let local = y as i64 - y0;
            if local < 0 || local >= source.height() as i64 {
                return;
            }
            let source_row = &source_pixels[local as usize * source_row_bytes..][..source_row_bytes];
            for index in 0..width as usize {
                let dx = x0 + index as i64;
                if dx < 0 || dx >= backdrop_width {
                    continue;
                }
                let s = index * 4;
                let top = [source_row[s], source_row[s + 1], source_row[s + 2], source_row[s + 3]];
                if top[3] == 0 {
                    continue;
                }
                let i = dx as usize * 4;
                let under = [row[i], row[i + 1], row[i + 2], row[i + 3]];
                let out = composite_texel_mode(mode, under, top);
                row[i..i + 4].copy_from_slice(&out);
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every mode's blend at the corners of the unit square: `[f(0,0), f(0,1), f(1,0), f(1,1)]`.
    fn boundary_table(mode: BlendMode) -> [f32; 4] {
        let gray = |backdrop: f32, source: f32| blend_colors(mode, [backdrop; 3], [source; 3])[0];
        [gray(0.0, 0.0), gray(0.0, 1.0), gray(1.0, 0.0), gray(1.0, 1.0)]
    }

    #[test]
    fn every_mode_has_the_expected_boundaries() {
        let expected: [(BlendMode, [f32; 4]); 24] = [
            (BlendMode::Normal, [0.0, 1.0, 0.0, 1.0]),
            (BlendMode::Darken, [0.0, 0.0, 0.0, 1.0]),
            (BlendMode::Multiply, [0.0, 0.0, 0.0, 1.0]),
            (BlendMode::ColorBurn, [0.0, 0.0, 0.0, 1.0]),
            (BlendMode::LinearBurn, [0.0, 0.0, 0.0, 1.0]),
            (BlendMode::Lighten, [0.0, 1.0, 1.0, 1.0]),
            (BlendMode::Screen, [0.0, 1.0, 1.0, 1.0]),
            (BlendMode::ColorDodge, [0.0, 1.0, 1.0, 1.0]),
            (BlendMode::LinearDodge, [0.0, 1.0, 1.0, 1.0]),
            (BlendMode::Overlay, [0.0, 0.0, 1.0, 1.0]),
            (BlendMode::SoftLight, [0.0, 0.0, 1.0, 1.0]),
            (BlendMode::HardLight, [0.0, 1.0, 0.0, 1.0]),
            (BlendMode::VividLight, [0.0, 1.0, 0.0, 1.0]),
            (BlendMode::LinearLight, [0.0, 1.0, 0.0, 1.0]),
            (BlendMode::PinLight, [0.0, 1.0, 0.0, 1.0]),
            (BlendMode::HardMix, [0.0, 1.0, 0.0, 1.0]),
            (BlendMode::Difference, [0.0, 1.0, 1.0, 0.0]),
            (BlendMode::Exclusion, [0.0, 1.0, 1.0, 0.0]),
            (BlendMode::Subtract, [0.0, 0.0, 1.0, 0.0]),
            (BlendMode::Divide, [1.0, 0.0, 1.0, 1.0]),
            (BlendMode::Hue, [0.0, 0.0, 1.0, 1.0]),
            (BlendMode::Saturation, [0.0, 0.0, 1.0, 1.0]),
            (BlendMode::Color, [0.0, 0.0, 1.0, 1.0]),
            (BlendMode::Luminosity, [0.0, 1.0, 0.0, 1.0]),
        ];
        for (mode, want) in expected {
            let got = boundary_table(mode);
            for (index, value) in got.iter().enumerate() {
                assert!(
                    (value - want[index]).abs() < 1e-6,
                    "{mode:?} at corner {index}: got {value}, want {}",
                    want[index]
                );
            }
        }
        assert_eq!(expected.len(), BlendMode::ALL.len());
    }

    #[test]
    fn known_midpoint_values_match_photoshop() {
        let f = |mode: BlendMode, cb: f32, cs: f32| blend_channel(mode, cb, cs);
        assert!((f(BlendMode::Multiply, 0.5, 0.5) - 0.25).abs() < 1e-6);
        assert!((f(BlendMode::Screen, 0.5, 0.5) - 0.75).abs() < 1e-6);
        assert!((f(BlendMode::Overlay, 0.25, 0.5) - 0.25).abs() < 1e-6);
        assert!((f(BlendMode::Overlay, 0.75, 0.5) - 0.75).abs() < 1e-6);
        assert!((f(BlendMode::HardLight, 0.5, 0.25) - 0.25).abs() < 1e-6);
        // The Photoshop soft light: the Core Image filter would put this at about 0.404.
        assert!((f(BlendMode::SoftLight, 0.5, 0.25) - 0.375).abs() < 1e-6);
        assert!((f(BlendMode::ColorBurn, 0.5, 0.5) - 0.0).abs() < 1e-6);
        assert!((f(BlendMode::ColorDodge, 0.5, 0.5) - 1.0).abs() < 1e-6);
        assert!((f(BlendMode::LinearBurn, 0.6, 0.6) - 0.2).abs() < 1e-6);
        assert!((f(BlendMode::LinearDodge, 0.6, 0.6) - 1.0).abs() < 1e-6);
        assert!((f(BlendMode::VividLight, 0.5, 0.25) - 0.0).abs() < 1e-6);
        assert!((f(BlendMode::PinLight, 0.3, 0.6) - 0.3).abs() < 1e-6);
        assert!((f(BlendMode::HardMix, 0.5, 0.5) - 1.0).abs() < 1e-6);
        assert!((f(BlendMode::Difference, 0.3, 0.7) - 0.4).abs() < 1e-6);
        assert!((f(BlendMode::Exclusion, 0.5, 0.5) - 0.5).abs() < 1e-6);
        // The boundary cases the format cares about: black burns to nothing and dodges to nothing.
        assert_eq!(f(BlendMode::ColorBurn, 1.0, 0.0), 0.0);
        assert_eq!(f(BlendMode::ColorBurn, 0.0, 1.0), 0.0);
        assert_eq!(f(BlendMode::ColorDodge, 0.0, 1.0), 1.0);
        assert_eq!(f(BlendMode::ColorDodge, 1.0, 0.0), 1.0);
        assert_eq!(f(BlendMode::Divide, 0.0, 0.0), 1.0);
    }

    #[test]
    fn set_sat_keeps_a_middle_channel_that_almost_matches_the_brightest() {
        // The middle channel sits a rounding error away from the brightest, which an equality test on
        // `r + g + b - min - max` gets wrong: it must keep its share instead of dropping to zero.
        let color = [0.4f32, 0.2, 0.2 + 1e-7];
        let out = set_sat(color, 0.5);
        let smallest = color.iter().cloned().fold(f32::MAX, f32::min);
        let largest = color.iter().cloned().fold(0.0f32, f32::max);
        let index_of = |value: f32| color.iter().position(|c| *c == value).unwrap();
        assert!(out[index_of(0.4)] > 0.0, "the middle channel kept its share: {out:?}");
        assert_eq!(out[index_of(smallest)], 0.0, "the darkest channel is zero");
        assert!((out[index_of(largest)] - 0.5).abs() < 1e-5, "the brightest carries the saturation");
    }

    #[test]
    fn hue_matches_the_reference_for_a_probe_over_a_ramp() {
        // The pixel the reference fixtures caught: the source's middle channel is nearly the sum of the
        // other two, which used to collapse the hue result onto a single channel.
        let cb = [130.0f32 / 255.0, 8.0 / 255.0, 166.0 / 255.0];
        let cs = [130.0f32 / 255.0, 64.0 / 255.0, 125.0 / 255.0];
        let saturated = set_sat(cs, sat(cb));
        assert!((saturated[0] - 0.61960787).abs() < 1e-5);
        assert_eq!(saturated[1], 0.0);
        assert!((saturated[2] - 0.5726657).abs() < 1e-5, "blue keeps the middle share: {saturated:?}");
        let out = composite_texel_mode(BlendMode::Hue, [130, 8, 166, 255], [130, 64, 125, 255]);
        assert_eq!(out, [154, 0, 143, 255], "the reference implementation's own result");
        assert!((lum([out[0] as f32 / 255.0, out[1] as f32 / 255.0, out[2] as f32 / 255.0]) - lum(cb)).abs() < 5e-3);
    }

    #[test]
    fn component_modes_keep_the_luminance_they_should() {
        let backdrop = [0.8f32, 0.35, 0.2];
        let source = [0.2f32, 0.6, 0.9];
        let hue = blend_colors(BlendMode::Hue, backdrop, source);
        assert!((lum(hue) - lum(backdrop)).abs() < 1e-5, "hue luminance");
        assert!((sat(hue) - sat(backdrop)).abs() < 1e-5, "hue saturation follows the backdrop");
        let saturation = blend_colors(BlendMode::Saturation, backdrop, source);
        assert!((lum(saturation) - lum(backdrop)).abs() < 1e-5, "saturation luminance");
        assert!((sat(saturation) - sat(source)).abs() < 1e-5, "saturation follows the source");
        let color = blend_colors(BlendMode::Color, backdrop, source);
        assert!((lum(color) - lum(backdrop)).abs() < 1e-5, "color luminance");
        let luminosity = blend_colors(BlendMode::Luminosity, backdrop, source);
        assert!((lum(luminosity) - lum(source)).abs() < 1e-5, "luminosity luminance");
    }

    #[test]
    fn component_modes_leave_neutral_grays_neutral() {
        let gray = [0.4f32, 0.4, 0.4];
        let source = [0.9f32, 0.2, 0.5];
        for mode in [BlendMode::Hue, BlendMode::Saturation] {
            let out = blend_colors(mode, gray, source);
            assert!(
                (out[0] - out[1]).abs() < 1e-5 && (out[1] - out[2]).abs() < 1e-5,
                "{mode:?} turned a gray backdrop colorful: {out:?}"
            );
        }
    }

    #[test]
    fn source_over_obeys_the_alpha_boundaries() {
        // A fully transparent source leaves the backdrop exactly as it was.
        for mode in BlendMode::ALL {
            let backdrop = [10u8, 200, 30, 255];
            let source = [255u8, 0, 0, 0];
            assert_eq!(composite_texel_mode(mode, backdrop, source), backdrop, "{mode:?} alpha 0");
        }
        // An opaque source over nothing comes out as itself, in every mode.
        for mode in BlendMode::ALL {
            let source = [200u8, 100, 50, 255];
            assert_eq!(composite_texel_mode(mode, [0, 0, 0, 0], source), source, "{mode:?} over empty");
        }
    }

    #[test]
    fn channel_extremes_survive_the_composite() {
        let opaque = |rgb: [u8; 3]| [rgb[0], rgb[1], rgb[2], 255];
        for mode in BlendMode::ALL {
            for backdrop in [opaque([0, 0, 0]), opaque([255, 255, 255])] {
                for source in [opaque([0, 0, 0]), opaque([255, 255, 255])] {
                    let out = composite_texel_mode(mode, backdrop, source);
                    assert_eq!(out[3], 255, "{mode:?} kept the alpha");
                }
            }
        }
        // Half-transparent red over opaque blue stays in range on every channel.
        let out = composite_texel_mode(BlendMode::Normal, [0, 0, 255, 255], [255, 0, 0, 128]);
        assert_eq!(out[3], 255);
        assert!(out[0] > 100 && out[0] < 140, "half of red: {out:?}");
        assert!(out[2] > 100 && out[2] < 140, "half of blue: {out:?}");
    }

    #[test]
    fn a_composite_stays_premultiplied() {
        // Over nothing, a half-transparent source comes back as its own premultiplied bytes. Returning
        // straight color here would leave the buffer premultiplied-in-name-only, and the next composite
        // would divide by the alpha a second time, inflating every soft edge.
        let source = [128u8, 0, 0, 128];
        assert_eq!(composite_texel_mode(BlendMode::Normal, [0, 0, 0, 0], source), source);
        let mut backdrop = Surface::new(1, 1);
        let mut layer = Surface::new(1, 1);
        layer.set(0, 0, source);
        composite_surface(&mut backdrop, &layer, BlendMode::Normal);
        assert_eq!(backdrop.get(0, 0), source, "the surface keeps premultiplied bytes");
        // The bitmap the caller sees is straight: full red covering half the pixel.
        assert_eq!(backdrop.to_bitmap().get(0, 0), [255, 0, 0, 128]);
        // Two half-transparent layers over nothing must not brighten the second one: red at 0.5 over red
        // at 0.5 is red at 0.75, not red at some inflated alpha.
        let mut canvas = Surface::new(1, 1);
        let half_red = {
            let mut surface = Surface::new(1, 1);
            surface.set(0, 0, [128, 0, 0, 128]);
            surface
        };
        composite_surface(&mut canvas, &half_red, BlendMode::Normal);
        composite_surface(&mut canvas, &half_red, BlendMode::Normal);
        assert_eq!(canvas.get(0, 0)[3], 192, "0.5 over 0.5 of coverage");
        assert_eq!(canvas.to_bitmap().get(0, 0), [255, 0, 0, 192], "and the color stays saturated red");
    }

    #[test]
    fn composite_surface_matches_the_single_pixel_path() {
        let mut backdrop = Surface::new(4, 1);
        let mut source = Surface::new(4, 1);
        for x in 0..4 {
            backdrop.set(x, 0, [x as u8 * 20, 100, 200, 255]);
            source.set(x, 0, [250, x as u8 * 30, 10, 128]);
        }
        let mut expected = backdrop.clone();
        for x in 0..4 {
            expected.set(x, 0, composite_texel_mode(BlendMode::Multiply, backdrop.get(x, 0), source.get(x, 0)));
        }
        composite_surface(&mut backdrop, &source, BlendMode::Multiply);
        assert_eq!(backdrop, expected);
    }
}