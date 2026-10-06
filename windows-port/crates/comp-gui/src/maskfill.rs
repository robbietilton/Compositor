//! Filling a layer mask with a gradient, and softening it.
//!
//! A mask is one Gray8 plane, so a gradient is a value per pixel between the two ends of a drag and a
//! feather is a blur of the plane. Both are arithmetic on a grid, which is what makes them testable
//! without a document.

use comp_core::bitmap::Gray8;

/// The shape a gradient fill takes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GradientShape {
    /// A straight ramp across the drag: the bands run perpendicular to it.
    Linear,
    /// A ramp out from the start point, reaching the end point's distance.
    Radial,
}

impl GradientShape {
    pub fn label(self) -> &'static str {
        match self {
            GradientShape::Linear => "Linear",
            GradientShape::Radial => "Radial",
        }
    }
}

/// A gradient drag, in the mask's own pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GradientDrag {
    pub shape: GradientShape,
    pub from: (f64, f64),
    pub to: (f64, f64),
    /// True to run the other way, so the drag starts white and ends black.
    pub invert: bool,
}

/// The largest feather radius the panel offers, in mask pixels.
pub const MAX_FEATHER: f64 = 250.0;

/// How far along the drag a point is: 0 at the start, 1 at the end, clamped.
///
/// A drag with no length has no direction, so it fills uniformly with the end value rather than
/// dividing by zero.
pub fn gradient_at(drag: &GradientDrag, x: f64, y: f64) -> f64 {
    let (from_x, from_y) = drag.from;
    let (to_x, to_y) = drag.to;
    let (dx, dy) = (to_x - from_x, to_y - from_y);
    let length_squared = dx * dx + dy * dy;
    let fraction = if length_squared <= f64::EPSILON {
        1.0
    } else {
        let along = match drag.shape {
            GradientShape::Linear => ((x - from_x) * dx + (y - from_y) * dy) / length_squared,
            GradientShape::Radial => {
                let distance = ((x - from_x).powi(2) + (y - from_y).powi(2)).sqrt();
                distance / length_squared.sqrt()
            }
        };
        along.clamp(0.0, 1.0)
    };
    let value = if drag.invert { 1.0 - fraction } else { fraction };
    value.clamp(0.0, 1.0)
}

/// How a gradient meets the mask that is already there.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GradientBlend {
    /// The ramp replaces the mask outright, which is what a fresh gradient wants.
    Replace,
    /// The ramp lightens: it only adds what the mask did not already keep.
    Add,
    /// The ramp darkens: it only hides what the mask did not already hide.
    Subtract,
}

impl GradientBlend {
    pub const ALL: [GradientBlend; 3] = [GradientBlend::Replace, GradientBlend::Add, GradientBlend::Subtract];

    pub fn label(self) -> &'static str {
        match self {
            GradientBlend::Replace => "Replace",
            GradientBlend::Add => "Add",
            GradientBlend::Subtract => "Subtract",
        }
    }
}

/// The ramp on its own, and the mask it produces once it meets what was there.
pub fn apply_gradient(existing: &Gray8, ramp: &Gray8, blend: GradientBlend) -> Gray8 {
    if blend == GradientBlend::Replace {
        return ramp.clone();
    }
    let (width, height) = (ramp.width(), ramp.height());
    if existing.width() != width || existing.height() != height {
        return ramp.clone();
    }
    let mut mask = Gray8::new(width, height);
    for index in 0..(width as usize * height as usize) {
        let (was, now) = (existing.pixels()[index], ramp.pixels()[index]);
        mask.pixels_mut()[index] = match blend {
            GradientBlend::Replace => now,
            // Lighten and darken, which is what adding ink or taking it away comes to.
            GradientBlend::Add => was.max(now),
            GradientBlend::Subtract => was.min(now),
        };
    }
    mask
}

/// A mask filled with that gradient, black at the start of the drag and white at the end.
pub fn gradient(width: u32, height: u32, drag: &GradientDrag) -> Gray8 {
    let mut mask = Gray8::new(width, height);
    for y in 0..height {
        for x in 0..width {
            // Sample pixel centres, so a ramp across an even number of pixels stays symmetric.
            let value = gradient_at(drag, x as f64 + 0.5, y as f64 + 0.5) * 255.0;
            mask.set(x, y, value.round().clamp(0.0, 255.0) as u8);
        }
    }
    mask
}

/// Softens a mask by blurring it with this radius, in mask pixels.
///
/// Three box passes approximate a gaussian, which is what a mask edge wants: no rings, and the
/// window shrinks at the borders so a uniform mask stays uniform instead of darkening at its edges.
pub fn feather(mask: &Gray8, radius: f64) -> Gray8 {
    let (width, height) = (mask.width(), mask.height());
    if width == 0 || height == 0 || !radius.is_finite() || radius <= 0.0 {
        return mask.clone();
    }
    let window = ((radius / 3.0).round() as i64).max(1);
    let mut plane: Vec<f64> = mask.pixels().iter().map(|value| *value as f64).collect();
    let mut scratch = vec![0.0; plane.len()];
    for _ in 0..3 {
        blur_rows(&plane, &mut scratch, width as usize, height as usize, window);
        blur_columns(&scratch, &mut plane, width as usize, height as usize, window);
    }
    let mut softened = Gray8::new(width, height);
    for (index, value) in plane.iter().enumerate() {
        softened.pixels_mut()[index] = value.round().clamp(0.0, 255.0) as u8;
    }
    softened
}

/// A one-dimensional box blur along the rows, in linear time.
fn blur_rows(source: &[f64], target: &mut [f64], width: usize, height: usize, radius: i64) {
    let last = width as i64 - 1;
    for y in 0..height {
        let row = y * width;
        let mut sum = 0.0;
        let mut count = 0i64;
        for x in 0..=radius.min(last) {
            sum += source[row + x as usize];
            count += 1;
        }
        for x in 0..width as i64 {
            target[row + x as usize] = sum / count.max(1) as f64;
            let entering = x + radius + 1;
            if entering <= last {
                sum += source[row + entering as usize];
                count += 1;
            }
            let leaving = x - radius;
            if leaving >= 0 {
                sum -= source[row + leaving as usize];
                count -= 1;
            }
        }
    }
}

/// The same down the columns.
fn blur_columns(source: &[f64], target: &mut [f64], width: usize, height: usize, radius: i64) {
    let last = height as i64 - 1;
    for x in 0..width {
        let mut sum = 0.0;
        let mut count = 0i64;
        for y in 0..=radius.min(last) {
            sum += source[y as usize * width + x];
            count += 1;
        }
        for y in 0..height as i64 {
            target[y as usize * width + x] = sum / count.max(1) as f64;
            let entering = y + radius + 1;
            if entering <= last {
                sum += source[entering as usize * width + x];
                count += 1;
            }
            let leaving = y - radius;
            if leaving >= 0 {
                sum -= source[leaving as usize * width + x];
                count -= 1;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn linear(from: (f64, f64), to: (f64, f64)) -> GradientDrag {
        GradientDrag { shape: GradientShape::Linear, from, to, invert: false }
    }

    fn radial(from: (f64, f64), to: (f64, f64)) -> GradientDrag {
        GradientDrag { shape: GradientShape::Radial, from, to, invert: false }
    }

    /// A mask that is black on the left half and white on the right.
    fn split(width: u32, height: u32) -> Gray8 {
        let mut mask = Gray8::new(width, height);
        for y in 0..height {
            for x in 0..width {
                mask.set(x, y, if x < width / 2 { 0 } else { 255 });
            }
        }
        mask
    }

    #[test]
    fn a_linear_drag_ramps_from_black_to_white_across_it() {
        let drag = linear((0.0, 0.0), (10.0, 0.0));
        assert_eq!(gradient_at(&drag, -5.0, 3.0), 0.0, "before the start is black");
        assert_eq!(gradient_at(&drag, 20.0, 3.0), 1.0, "past the end is white");
        assert!((gradient_at(&drag, 5.0, 3.0) - 0.5).abs() < 1e-9, "the middle is half way");
        // Perpendicular to the drag the value does not change.
        assert!((gradient_at(&drag, 5.0, -100.0) - gradient_at(&drag, 5.0, 100.0)).abs() < 1e-9);
    }

    #[test]
    fn a_filled_linear_gradient_has_the_values_the_drag_asks_for() {
        let mask = gradient(16, 4, &linear((0.0, 0.0), (16.0, 0.0)));
        assert_eq!(mask.width(), 16);
        assert_eq!(mask.get(0, 0), 8, "the first pixel centre is half a pixel along");
        assert_eq!(mask.get(15, 0), 247);
        assert!(mask.get(0, 0) < mask.get(8, 0));
        assert!(mask.get(8, 0) < mask.get(15, 0));
        for y in 0..4 {
            assert_eq!(mask.get(8, y), mask.get(8, 0), "every row is the same");
        }
    }

    #[test]
    fn a_vertical_drag_ramps_down_the_mask() {
        let mask = gradient(4, 16, &linear((0.0, 0.0), (0.0, 16.0)));
        for x in 0..4 {
            assert_eq!(mask.get(x, 0), mask.get(0, 0), "every column is the same");
        }
        assert!(mask.get(0, 0) < mask.get(0, 15));
    }

    #[test]
    fn inverting_a_drag_runs_it_the_other_way() {
        let mut drag = linear((0.0, 0.0), (10.0, 0.0));
        let straight = gradient(10, 2, &drag);
        drag.invert = true;
        let inverted = gradient(10, 2, &drag);
        for x in 0..10 {
            assert_eq!(inverted.get(x, 0) as u32 + straight.get(x, 0) as u32, 255, "column {x}");
        }
    }

    #[test]
    fn a_radial_drag_is_black_at_the_centre_and_white_at_its_distance() {
        let drag = radial((5.0, 5.0), (15.0, 5.0));
        assert_eq!(gradient_at(&drag, 5.0, 5.0), 0.0, "the centre is black");
        assert_eq!(gradient_at(&drag, 15.0, 5.0), 1.0, "the end distance is white");
        assert_eq!(gradient_at(&drag, 5.0, 15.0), 1.0, "the ramp is a circle, not an axis");
        assert_eq!(gradient_at(&drag, 100.0, 5.0), 1.0, "past it stays white");
        // The fill samples pixel centres, so the pixel over the centre is nearly black rather than
        // exactly black: it sits half a pixel away from the start of the ramp.
        let mask = gradient(11, 11, &drag);
        assert!(mask.get(5, 5) <= 20, "the centre pixel is nearly black: {}", mask.get(5, 5));
        assert!(mask.get(10, 5) > mask.get(7, 5));
        assert_eq!(mask.get(8, 5), mask.get(5, 8), "the ramp is a circle: the same distance either way");
    }

    #[test]
    fn a_drag_with_no_length_fills_with_one_value() {
        let mask = gradient(4, 4, &linear((2.0, 2.0), (2.0, 2.0)));
        for y in 0..4 {
            for x in 0..4 {
                assert_eq!(mask.get(x, y), 255, "a degenerate drag is the end value everywhere");
            }
        }
    }

    #[test]
    fn blending_a_ramp_into_a_mask_keeps_what_the_mask_already_said() {
        let mut existing = Gray8::new(4, 1);
        for (x, value) in [0u8, 64, 192, 255].iter().enumerate() {
            existing.set(x as u32, 0, *value);
        }
        let mut ramp = Gray8::new(4, 1);
        for (x, value) in [0u8, 128, 128, 0].iter().enumerate() {
            ramp.set(x as u32, 0, *value);
        }

        let replaced = apply_gradient(&existing, &ramp, GradientBlend::Replace);
        assert_eq!(replaced.pixels(), ramp.pixels(), "replace ignores what was there");

        let added = apply_gradient(&existing, &ramp, GradientBlend::Add);
        assert_eq!(added.pixels(), &[0, 128, 192, 255], "adding only ever lightens");

        let subtracted = apply_gradient(&existing, &ramp, GradientBlend::Subtract);
        assert_eq!(subtracted.pixels(), &[0, 64, 128, 0], "subtracting only ever darkens");
    }

    #[test]
    fn blending_refuses_a_mask_of_another_size() {
        let existing = Gray8::filled(2, 2, 10);
        let ramp = Gray8::filled(4, 4, 200);
        let blended = apply_gradient(&existing, &ramp, GradientBlend::Add);
        assert_eq!((blended.width(), blended.height()), (4, 4));
        assert_eq!(blended.pixels(), ramp.pixels(), "a mismatched mask cannot be blended into");
        assert_eq!(GradientBlend::ALL.len(), 3);
        assert_eq!(GradientBlend::Add.label(), "Add");
    }

    #[test]
    fn a_feather_of_zero_changes_nothing() {
        let mask = split(8, 4);
        assert_eq!(feather(&mask, 0.0).pixels(), mask.pixels());
        assert_eq!(feather(&mask, -3.0).pixels(), mask.pixels());
    }

    #[test]
    fn a_feather_softens_the_edge_and_leaves_the_far_side_alone() {
        let mask = split(32, 8);
        let softened = feather(&mask, 9.0);
        assert_eq!((softened.width(), softened.height()), (32, 8));
        // The edge itself is now a ramp rather than a jump.
        let edge: Vec<u8> = (13..19).map(|x| softened.get(x, 4)).collect();
        assert!(edge.windows(2).all(|pair| pair[0] <= pair[1]), "the ramp must not go backwards: {edge:?}");
        assert!(edge[0] < edge[edge.len() - 1], "and it must actually rise: {edge:?}");
        assert_eq!(softened.get(0, 4), 0, "far from the edge the black side is untouched");
        assert_eq!(softened.get(31, 4), 255, "and so is the white side");
    }

    #[test]
    fn a_feather_does_not_darken_the_border_of_a_uniform_mask() {
        // The blur window shrinks at the borders, so a flat mask has to stay flat.
        for value in [0u8, 77, 255] {
            let flat = Gray8::filled(16, 16, value);
            let softened = feather(&flat, 12.0);
            for y in 0..16 {
                for x in 0..16 {
                    assert_eq!(softened.get(x, y), value, "a flat mask of {value} changed at {x},{y}");
                }
            }
        }
    }

    #[test]
    fn a_large_feather_still_runs_in_one_pass_per_direction() {
        // A 1024-wide mask with the largest radius the panel offers: this is the shape that would
        // crawl if the window were summed per pixel.
        let mut mask = Gray8::new(1024, 64);
        for x in 0..1024 {
            let value = if x < 512 { 0 } else { 255 };
            for y in 0..64 {
                mask.set(x, y, value);
            }
        }
        let started = std::time::Instant::now();
        let softened = feather(&mask, MAX_FEATHER);
        let elapsed = started.elapsed();
        assert!(softened.get(512, 32) > 0 && softened.get(512, 32) < 255, "the edge is a ramp");
        assert!(elapsed.as_millis() < 400, "a feather took {} ms", elapsed.as_millis());
    }
}
