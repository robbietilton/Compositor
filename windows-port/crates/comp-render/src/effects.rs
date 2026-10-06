//! The six layer effects, drawn around a layer's pixels the way `LayerEffectsRenderer` draws them.
//!
//! Effects work in the layer's own pixel grid and grow the image by a margin; the caller places the
//! bigger image through a proportionally larger transform, so the layer lands where it did. The order is
//! the original's: drop shadow, outer glow and an outside stroke behind the pixels, then the pixels, then
//! a color overlay, an inner glow, an inner shadow and an inside stroke over them.

use comp_core::effects::{InnerGlowEffect, InnerShadowEffect, LayerEffects, OuterGlowEffect, ShadowEffect, StrokeEffect};

use crate::blend::composite_surface;
use crate::pixel::{round_u8, Plane, Surface};
use comp_core::BlendMode;

/// The effects that are switched on. A disabled effect draws nothing and needs no room.
pub fn visible(effects: &LayerEffects) -> LayerEffects {
    LayerEffects {
        stroke: effects.stroke.filter(|effect| effect.is_enabled()),
        shadow: effects.shadow.filter(|effect| effect.is_enabled()),
        color_overlay: effects.color_overlay.filter(|effect| effect.is_enabled()),
        inner_shadow: effects.inner_shadow.filter(|effect| effect.is_enabled()),
        outer_glow: effects.outer_glow.filter(|effect| effect.is_enabled()),
        inner_glow: effects.inner_glow.filter(|effect| effect.is_enabled()),
    }
}

/// How far past the layer's own pixels the effects reach, plus two pixels of room.
pub fn margin(effects: &LayerEffects) -> u32 {
    let effects = visible(effects);
    let mut margin = 0.0f64;
    if let Some(stroke) = effects.stroke {
        if !stroke.inside {
            margin = margin.max(stroke.size);
        }
    }
    if let Some(shadow) = effects.shadow {
        margin = margin.max(shadow.distance + shadow.blur * 3.0);
    }
    if let Some(glow) = effects.outer_glow {
        margin = margin.max(glow.size * 3.0);
    }
    margin.ceil() as u32 + 2
}

/// Where a shadow falls, in layer pixels with y counting down, as Photoshop's dial describes it: the
/// light comes from `angle` counterclockwise of the right, so the shadow goes the other way.
pub(crate) fn shadow_offset(angle: f64, distance: f64) -> (f64, f64) {
    let radians = angle.to_radians();
    (-radians.cos() * distance, radians.sin() * distance)
}

/// Renders `image` (premultiplied, in the layer's pixel grid, its mask already applied) with its
/// effects, on a surface grown by `margin` on every side. Returns the image and the margin it was
/// grown by, which the caller needs to place it.
pub fn render(image: &Surface, effects: &LayerEffects) -> (Surface, u32) {
    let effects = visible(effects);
    let inset = margin(&effects);
    if effects.is_empty() || image.is_empty() {
        return (image.clone(), 0);
    }
    let width = image.width() + inset * 2;
    let height = image.height() + inset * 2;
    let mut canvas = Surface::new(width, height);
    blit(&mut canvas, image, inset as i64, inset as i64);
    // The shape everything is measured from: the layer's coverage in the grown canvas.
    let shape = canvas.alpha_plane();

    if let Some(shadow) = effects.shadow {
        if shadow.opacity > 0.0 {
            let coverage = shadow_coverage(&shape, &shadow);
            fill(&mut canvas, shadow.color().to_rgba8(), shadow.opacity as f32, &coverage);
        }
    }
    if let Some(glow) = effects.outer_glow {
        if glow.opacity > 0.0 {
            let coverage = outer_glow_coverage(&shape, &glow);
            fill(&mut canvas, glow.color().to_rgba8(), glow.opacity as f32, &coverage);
        }
    }
    let stroke = effects.stroke.filter(|stroke| stroke.size > 0.0 && stroke.opacity > 0.0);
    if let Some(stroke) = stroke {
        if !stroke.inside {
            let coverage = ring_coverage(&shape, &stroke);
            fill(&mut canvas, stroke.color().to_rgba8(), stroke.opacity as f32, &coverage);
        }
    }
    // Source over, so the effects behind show through the layer's transparent pixels.
    composite_surface(&mut canvas, &image_placed(image, inset, width, height), BlendMode::Normal);
    if let Some(overlay) = effects.color_overlay {
        if overlay.opacity > 0.0 {
            fill(&mut canvas, overlay.color().to_rgba8(), overlay.opacity as f32, &shape);
        }
    }
    if let Some(glow) = effects.inner_glow {
        if glow.size > 0.0 && glow.opacity > 0.0 {
            let coverage = inner_glow_coverage(&shape, &glow);
            fill(&mut canvas, glow.color().to_rgba8(), glow.opacity as f32, &coverage);
        }
    }
    if let Some(inner) = effects.inner_shadow {
        if inner.opacity > 0.0 {
            let coverage = inner_shadow_coverage(&shape, &inner);
            fill(&mut canvas, inner.color().to_rgba8(), inner.opacity as f32, &coverage);
        }
    }
    if let Some(stroke) = stroke {
        if stroke.inside {
            let coverage = ring_coverage(&shape, &stroke);
            fill(&mut canvas, stroke.color().to_rgba8(), stroke.opacity as f32, &coverage);
        }
    }
    (canvas, inset)
}

/// The layer's own pixels on the grown canvas, so they can be composited over the effects.
fn image_placed(image: &Surface, inset: u32, width: u32, height: u32) -> Surface {
    let mut placed = Surface::new(width, height);
    blit(&mut placed, image, inset as i64, inset as i64);
    placed
}

/// A drop shadow: the shape moved and softened.
fn shadow_coverage(shape: &Plane, shadow: &ShadowEffect) -> Plane {
    let (dx, dy) = shadow_offset(shadow.angle, shadow.distance);
    let moved = shift(shape, dx, dy);
    blur(moved, (shadow.blur / 2.0) as f32)
}

/// An inner shadow: what lies outside the shape, moved and softened, kept to the shape's own fill.
fn inner_shadow_coverage(shape: &Plane, shadow: &InnerShadowEffect) -> Plane {
    let (dx, dy) = shadow_offset(shadow.angle, shadow.distance);
    // The outside of the moved shape, blurred into the shape's own edge.
    let moved = shift(shape, dx, dy);
    let soft = blur(moved, (shadow.blur / 2.0) as f32);
    inside_minus(shape, &soft)
}

/// An outer glow: the shape softened omnidirectionally, minus the shape itself.
fn outer_glow_coverage(shape: &Plane, glow: &OuterGlowEffect) -> Plane {
    let soft = blur(shape.clone(), (glow.size / 2.0) as f32);
    let mut coverage = Plane::new(soft.width(), soft.height());
    for (index, value) in coverage.values_mut().iter_mut().enumerate() {
        let outside = 1.0 - shape.values()[index] as f32 / 255.0;
        *value = round_u8(soft.values()[index] as f32 * outside);
    }
    coverage
}

/// An inner glow: the shape softened inward, kept to the shape's own fill.
fn inner_glow_coverage(shape: &Plane, glow: &InnerGlowEffect) -> Plane {
    let soft = blur(shape.clone(), (glow.size / 2.0) as f32);
    inside_minus(shape, &soft)
}

/// `shape * (1 - soft)`: what the softened copy leaves uncovered inside the shape.
fn inside_minus(shape: &Plane, soft: &Plane) -> Plane {
    let mut coverage = Plane::new(shape.width(), shape.height());
    for (index, value) in coverage.values_mut().iter_mut().enumerate() {
        let inside = shape.values()[index] as f32 / 255.0;
        let covered = soft.values()[index] as f32 / 255.0;
        *value = round_u8(inside * (1.0 - covered) * 255.0);
    }
    coverage
}

/// A stroke's ring: the shape grown by the reach less the shape, or the shape less the shape shrunk.
fn ring_coverage(shape: &Plane, stroke: &StrokeEffect) -> Plane {
    let reach = stroke.size.round_ties_even().max(1.0) as usize;
    let moved = if stroke.inside {
        extreme(shape, reach, true)
    } else {
        extreme(shape, reach, false)
    };
    let mut coverage = Plane::new(shape.width(), shape.height());
    for (index, value) in coverage.values_mut().iter_mut().enumerate() {
        let inside = shape.values()[index] as f32;
        let other = moved.values()[index] as f32;
        *value = if stroke.inside { (inside - other).max(0.0) as u8 } else { (other - inside).max(0.0) as u8 };
    }
    coverage
}

/// The largest (or smallest) value within `reach` on each side, in two sweeping passes, so a wide
/// stroke costs the same as a narrow one.
fn extreme(plane: &Plane, reach: usize, smallest: bool) -> Plane {
    let (width, height) = (plane.width() as usize, plane.height() as usize);
    let radius = reach;
    let source: Vec<f32> = plane.values().iter().map(|value| *value as f32).collect();
    let mut pass = vec![0.0f32; width * height];
    let mut result = vec![0.0f32; width * height];
    sweep(&source, &mut pass, height, width, width, 1, radius, smallest);
    sweep(&pass, &mut result, width, height, 1, width, radius, smallest);
    let mut out = Plane::new(width as u32, height as u32);
    for (value, source) in out.values_mut().iter_mut().zip(result.iter()) {
        *value = round_u8(*source);
    }
    out
}

#[allow(clippy::too_many_arguments)]
fn sweep(
    source: &[f32],
    target: &mut [f32],
    lines: usize,
    count: usize,
    line_step: usize,
    element_step: usize,
    radius: usize,
    smallest: bool,
) {
    let mut queue = vec![0usize; count.max(1)];
    for line in 0..lines {
        let base = line * line_step;
        let mut head = 0usize;
        let mut tail = 0usize;
        let mut next = 0usize;
        for center in 0..count {
            while next <= (count - 1).min(center + radius) {
                let value = source[base + next * element_step];
                while tail > head {
                    let previous = source[base + queue[tail - 1] * element_step];
                    if if smallest { previous < value } else { previous > value } {
                        break;
                    }
                    tail -= 1;
                }
                queue[tail] = next;
                tail += 1;
                next += 1;
            }
            while head < tail && queue[head] + radius < center {
                head += 1;
            }
            let outside = center < radius || center + radius >= count;
            // An eroding filter has nothing to hold at beyond the edge; a dilating one holds the edge value.
            target[base + center * element_step] =
                if smallest && outside { 0.0 } else { source[base + queue[head] * element_step] };
        }
    }
}

/// The shape moved by its offset, landing on whole pixels.
///
/// The original lays the offset shape into the surface with Core Graphics, which puts it on the nearest
/// pixel rather than filtering the shape: a shadow at 45 degrees and distance 6 moves by (-4, +4), not by
/// a fraction that smears its edge over two rows. Offsets round half to even, like the reference.
fn shift(plane: &Plane, dx: f64, dy: f64) -> Plane {
    let mut out = Plane::new(plane.width(), plane.height());
    let width = plane.width() as i64;
    let height = plane.height() as i64;
    let offset_x = dx.round_ties_even() as i64;
    let offset_y = dy.round_ties_even() as i64;
    for y in 0..height {
        let source_y = y - offset_y;
        if source_y < 0 || source_y >= height {
            continue;
        }
        for x in 0..width {
            let source_x = x - offset_x;
            if source_x < 0 || source_x >= width {
                continue;
            }
            out.set(x as u32, y as u32, plane.get(source_x as u32, source_y as u32));
        }
    }
    out
}

/// A gray plane softened by a Gaussian of `sigma`, with its border carried outwards - the original
/// clamps to the extent before blurring a coverage, so a shadow does not fade at the shape's edge.
pub fn blur(plane: Plane, sigma: f32) -> Plane {
    if !sigma.is_finite() || sigma <= 0.0 || plane.is_empty() {
        return plane;
    }
    let taps = (sigma * 3.0).ceil().max(1.0) as i64;
    let mut kernel = Vec::with_capacity((taps * 2 + 1) as usize);
    let mut sum = 0.0f32;
    for offset in -taps..=taps {
        let weight = (-((offset * offset) as f32) / (2.0 * sigma * sigma)).exp();
        kernel.push(weight);
        sum += weight;
    }
    for weight in kernel.iter_mut() {
        *weight /= sum;
    }
    let width = plane.width() as usize;
    let height = plane.height() as usize;
    let mut horizontal = vec![0.0f32; width * height];
    for y in 0..height {
        for x in 0..width {
            let mut value = 0.0;
            for (index, weight) in kernel.iter().enumerate() {
                let offset = index as i64 - taps;
                let sx = (x as i64 + offset).clamp(0, width as i64 - 1) as usize;
                value += plane.get(sx as u32, y as u32) as f32 * weight;
            }
            horizontal[y * width + x] = value;
        }
    }
    let mut out = Plane::new(plane.width(), plane.height());
    for y in 0..height {
        for x in 0..width {
            let mut value = 0.0;
            for (index, weight) in kernel.iter().enumerate() {
                let offset = index as i64 - taps;
                let sy = (y as i64 + offset).clamp(0, height as i64 - 1) as usize;
                value += horizontal[sy * width + x] * weight;
            }
            out.set(x as u32, y as u32, round_u8(value));
        }
    }
    out
}

/// Paints a solid color through a coverage, source over, at the effect's opacity.
///
/// The arithmetic stays in floats until the write, as the original's fill does: rounding the source to
/// bytes first would round twice and land a level away from the reference on soft coverage.
fn fill(canvas: &mut Surface, color: [u8; 4], opacity: f32, coverage: &Plane) {
    debug_assert_eq!(canvas.width(), coverage.width());
    debug_assert_eq!(canvas.height(), coverage.height());
    for (index, texel) in canvas.pixels_mut().chunks_exact_mut(4).enumerate() {
        let source_alpha = (coverage.values()[index] as f32 / 255.0 * opacity).clamp(0.0, 1.0);
        if source_alpha <= 0.0 {
            continue;
        }
        let inverse = 1.0 - source_alpha;
        for channel in 0..3 {
            let source = color[channel] as f32 * source_alpha;
            texel[channel] = round_u8(source + texel[channel] as f32 * inverse);
        }
        texel[3] = round_u8(source_alpha * 255.0 + texel[3] as f32 * inverse);
    }
}

/// Copies a surface into another at an offset, replacing pixels.
fn blit(dst: &mut Surface, src: &Surface, x: i64, y: i64) {
    for sy in 0..src.height() as i64 {
        let dy = y + sy;
        if dy < 0 || dy >= dst.height() as i64 {
            continue;
        }
        for sx in 0..src.width() as i64 {
            let dx = x + sx;
            if dx < 0 || dx >= dst.width() as i64 {
                continue;
            }
            dst.set(dx as u32, dy as u32, src.get(sx as u32, sy as u32));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use comp_core::effects::{ColorOverlayEffect, InnerGlowEffect, InnerShadowEffect, OuterGlowEffect, ShadowEffect, StrokeEffect};

    /// A square of color in the middle of a bigger transparent layer grid.
    fn square(size: u32, inset: u32, texel: [u8; 4]) -> Surface {
        let mut surface = Surface::new(size, size);
        for y in inset..size - inset {
            for x in inset..size - inset {
                let alpha = texel[3] as u32;
                surface.set(
                    x,
                    y,
                    [
                        (texel[0] as u32 * alpha / 255) as u8,
                        (texel[1] as u32 * alpha / 255) as u8,
                        (texel[2] as u32 * alpha / 255) as u8,
                        texel[3],
                    ],
                );
            }
        }
        surface
    }

    fn effects_with(effects: LayerEffects) -> LayerEffects {
        effects
    }

    #[test]
    fn a_disabled_effect_does_nothing() {
        let image = square(16, 4, [255, 0, 0, 255]);
        let (plain, margin) = render(&image, &LayerEffects::default());
        assert_eq!(margin, 0);
        assert_eq!(plain, image);
        let disabled = effects_with(LayerEffects {
            shadow: Some(ShadowEffect { enabled: Some(false), ..ShadowEffect::default() }),
            ..LayerEffects::default()
        });
        let (with_effects, margin) = render(&image, &disabled);
        assert_eq!(margin, 0, "a disabled effect needs no room");
        assert_eq!(with_effects, image);
    }

    #[test]
    fn a_drop_shadow_lands_below_the_shape() {
        let image = square(16, 4, [255, 0, 0, 255]);
        let effects = LayerEffects {
            shadow: Some(ShadowEffect { angle: 90.0, distance: 4.0, blur: 0.0, opacity: 1.0, ..ShadowEffect::default() }),
            ..LayerEffects::default()
        };
        let (out, margin) = render(&image, &effects);
        assert!(margin >= 6, "room for the distance and the blur: {margin}");
        let center = out.width() / 2;
        // The square starts four pixels in: four rows further down, over where the layer was
        // transparent, the shadow shows as black.
        let below = out.get(center, margin + 14);
        assert_eq!(below[3], 255, "the shadow is opaque: {below:?}");
        assert!(below[0] < 10 && below[1] < 10, "and black: {below:?}");
        // Above the shape there is nothing.
        assert_eq!(out.get(center, margin / 2)[3], 0);
    }

    #[test]
    fn a_color_overlay_paints_the_shape_and_keeps_its_alpha() {
        let image = square(16, 4, [255, 255, 255, 255]);
        let effects = LayerEffects {
            color_overlay: Some(ColorOverlayEffect { enabled: None, red: 0.0, green: 1.0, blue: 0.0, opacity: 1.0 }),
            ..LayerEffects::default()
        };
        let (out, _) = render(&image, &effects);
        let center = out.width() / 2;
        let texel = out.get(center, center);
        assert!(texel[1] > 250 && texel[0] < 5, "green over the shape: {texel:?}");
        assert_eq!(texel[3], 255);
        assert_eq!(out.get(0, 0)[3], 0, "and nothing outside it");
    }

    #[test]
    fn a_color_overlay_at_half_opacity_blends() {
        let image = square(16, 4, [255, 0, 0, 255]);
        let effects = LayerEffects {
            color_overlay: Some(ColorOverlayEffect { enabled: None, red: 0.0, green: 0.0, blue: 1.0, opacity: 0.5 }),
            ..LayerEffects::default()
        };
        let (out, _) = render(&image, &effects);
        let texel = out.get(out.width() / 2, out.height() / 2);
        assert!(texel[0] > 100 && texel[2] > 100, "half red, half blue: {texel:?}");
        assert_eq!(texel[3], 255);
    }

    #[test]
    fn an_outside_stroke_rings_the_shape() {
        let image = square(16, 5, [0, 255, 0, 255]);
        let effects = LayerEffects {
            stroke: Some(StrokeEffect { enabled: None, size: 2.0, red: 1.0, green: 0.0, blue: 0.0, opacity: 1.0, inside: false }),
            ..LayerEffects::default()
        };
        let (out, margin) = render(&image, &effects);
        assert!(margin >= 4);
        let center = out.width() / 2;
        // The square starts five pixels in, so one row above it is where the outside stroke lands.
        let ring = out.get(center, margin + 4);
        assert!(ring[3] > 200 && ring[0] > 200, "a red ring just outside the square: {ring:?}");
        assert_eq!(out.get(center, center)[1], 255, "the green fill is untouched");
    }

    #[test]
    fn an_inside_stroke_paints_over_the_edge() {
        let image = square(16, 5, [0, 255, 0, 255]);
        let effects = LayerEffects {
            stroke: Some(StrokeEffect { enabled: None, size: 2.0, red: 0.0, green: 0.0, blue: 1.0, opacity: 1.0, inside: true }),
            ..LayerEffects::default()
        };
        let (out, margin) = render(&image, &effects);
        let center = out.width() / 2;
        // The square runs five pixels in from the layer's edge: the inside stroke sits on that border.
        let edge = out.get(center, margin + 5);
        assert!(edge[2] > 200, "a blue edge inside the shape: {edge:?}");
        assert_eq!(out.get(center, center)[1], 255, "and the middle stays green");
    }

    #[test]
    fn an_outer_glow_haloes_the_shape() {
        let image = square(24, 8, [255, 255, 255, 255]);
        let effects = LayerEffects {
            outer_glow: Some(OuterGlowEffect { enabled: None, size: 6.0, red: 1.0, green: 0.0, blue: 0.0, opacity: 1.0 }),
            ..LayerEffects::default()
        };
        let (out, margin) = render(&image, &effects);
        assert!(margin >= 20, "an outer glow needs three times its size: {margin}");
        let center = out.width() / 2;
        let halo = out.get(center, center - 8 - 2);
        assert!(halo[3] > 0 && halo[0] > halo[1], "a red halo outside the shape: {halo:?}");
        let outside = out.get(center, center - 8 - 15);
        assert!(outside[3] < halo[3], "and it fades with distance");
    }

    #[test]
    fn an_inner_glow_softens_the_inside_edge() {
        let image = square(24, 5, [0, 0, 0, 255]);
        let effects = LayerEffects {
            inner_glow: Some(InnerGlowEffect { enabled: None, size: 5.0, red: 1.0, green: 1.0, blue: 0.0, opacity: 1.0 }),
            ..LayerEffects::default()
        };
        let (out, _) = render(&image, &effects);
        let center = out.width() / 2;
        let edge = out.get(center, center - 6);
        let middle = out.get(center, center);
        assert!(edge[1] > 20, "a yellow edge inside the shape: {edge:?}");
        assert_eq!(edge[3], 255);
        assert!(middle[1] < edge[1], "and it fades toward the middle: {middle:?}");
    }

    #[test]
    fn an_inner_shadow_darkens_inside_the_edge() {
        let image = square(24, 5, [255, 255, 255, 255]);
        let effects = LayerEffects {
            inner_shadow: Some(InnerShadowEffect { enabled: None, angle: 90.0, distance: 3.0, blur: 0.0, red: 0.0, green: 0.0, blue: 0.0, opacity: 1.0 }),
            ..LayerEffects::default()
        };
        let (out, margin) = render(&image, &effects);
        let center = out.width() / 2;
        // A shadow falling down darkens the top edge from the inside, and only the top.
        let top_edge = out.get(center, margin + 5);
        assert!(top_edge[0] < 40, "the top edge is shadowed: {top_edge:?}");
        assert!(out.get(center, margin + 9)[0] > 200, "and it fades a few rows in");
        assert!(out.get(center, center)[0] > 200, "the middle stays white");
    }

    #[test]
    fn effects_keep_the_layer_where_it_was() {
        let image = square(16, 4, [255, 0, 0, 255]);
        let effects = LayerEffects {
            color_overlay: Some(ColorOverlayEffect { enabled: None, red: 1.0, green: 1.0, blue: 1.0, opacity: 0.0 }),
            ..LayerEffects::default()
        };
        let (out, margin) = render(&image, &effects);
        let size = out.width();
        for y in 0..16 {
            for x in 0..16 {
                assert_eq!(out.get(x + margin, y + margin), image.get(x, y), "({x},{y})");
            }
        }
        assert_eq!(size, 16 + margin * 2);
    }
}
