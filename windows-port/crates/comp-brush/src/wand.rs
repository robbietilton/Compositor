//! Magic Wand and Color Range: turning similar pixels into an 8-bit coverage mask.
//!
//! The matching rules come from `Rendering/WandPixels.c`. Tolerance is per channel and
//! inclusive (a difference of exactly `tolerance` still matches, so 0 selects only the exact
//! color and 255 selects everything), the reference color is a box average around the click,
//! and the contiguous mode is a scanline flood fill over 4-connected neighbors.

use comp_core::{Bitmap8, Error, Gray8, PointF, Result};

/// How much of the image around the click is averaged into the color to match.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum WandSampleSize {
    #[default]
    Point,
    ThreeByThree,
    FiveByFive,
}

impl WandSampleSize {
    /// Pixels either side of the click that are averaged into the reference color.
    pub fn radius(self) -> u32 {
        match self {
            WandSampleSize::Point => 0,
            WandSampleSize::ThreeByThree => 1,
            WandSampleSize::FiveByFive => 2,
        }
    }
}

/// The Magic Wand's options-bar settings.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WandSettings {
    /// How far (0-255) each channel may differ from the sampled color and still be selected.
    pub tolerance: u8,
    pub sample_size: WandSampleSize,
    /// Only similar pixels connected to the clicked one, rather than every similar pixel.
    pub contiguous: bool,
}

impl Default for WandSettings {
    fn default() -> Self {
        WandSettings { tolerance: 32, sample_size: WandSampleSize::Point, contiguous: true }
    }
}

impl WandSettings {
    pub fn new(tolerance: u8) -> Self {
        WandSettings { tolerance, ..WandSettings::default() }
    }

    pub fn with_contiguous(mut self, contiguous: bool) -> Self {
        self.contiguous = contiguous;
        self
    }

    pub fn with_sample_size(mut self, sample_size: WandSampleSize) -> Self {
        self.sample_size = sample_size;
        self
    }
}

#[inline]
fn matches(pixel: [u8; 4], reference: [i32; 4], tolerance: i32) -> bool {
    for channel in 0..4 {
        let difference = pixel[channel] as i32 - reference[channel];
        if difference < -tolerance || difference > tolerance {
            return false;
        }
    }
    true
}

/// The color the wand matches, averaged over the box around the click. Nil when the click is
/// outside the image.
pub fn reference_color(image: &Bitmap8, seed: (i64, i64), radius: u32) -> Option<[i32; 4]> {
    let (x, y) = seed;
    if x < 0 || y < 0 || x >= image.width() as i64 || y >= image.height() as i64 {
        return None;
    }
    let radius = radius as i64;
    let x0 = (x - radius).max(0);
    let y0 = (y - radius).max(0);
    let x1 = (x + radius).min(image.width() as i64 - 1);
    let y1 = (y + radius).min(image.height() as i64 - 1);
    let mut sums = [0i64; 4];
    let mut samples = 0i64;
    for py in y0..=y1 {
        for px in x0..=x1 {
            let pixel = image.get(px as u32, py as u32);
            for channel in 0..4 {
                sums[channel] += pixel[channel] as i64;
            }
            samples += 1;
        }
    }
    if samples == 0 {
        return None;
    }
    let mut reference = [0i32; 4];
    for channel in 0..4 {
        reference[channel] = ((sums[channel] + samples / 2) / samples) as i32;
    }
    Some(reference)
}

/// Pixels similar to the one clicked: white where selected, at document resolution.
pub fn magic_wand(image: &Bitmap8, seed: PointF, settings: WandSettings) -> Gray8 {
    let width = image.width();
    let height = image.height();
    let mut mask = Gray8::new(width, height);
    if width == 0 || height == 0 || !seed.is_finite() {
        return mask;
    }
    let x = seed.x.floor() as i64;
    let y = seed.y.floor() as i64;
    if x < 0 || y < 0 || x >= width as i64 || y >= height as i64 {
        return mask;
    }
    let Some(reference) = reference_color(image, (x, y), settings.sample_size.radius()) else {
        return mask;
    };
    let tolerance = settings.tolerance as i32;
    let (x, y) = (x as usize, y as usize);
    if !settings.contiguous {
        for py in 0..height {
            for px in 0..width {
                if matches(image.get(px, py), reference, tolerance) {
                    mask.set(px, py, 255);
                }
            }
        }
        return mask;
    }
    // Scanline flood fill: each popped seed fills its whole horizontal run, then pushes one
    // seed per matching run in the rows directly above and below it.
    let mut stack = vec![(x, y)];
    while let Some((x, y)) = stack.pop() {
        if mask.get(x as u32, y as u32) != 0 || !matches(image.get(x as u32, y as u32), reference, tolerance) {
            continue;
        }
        let mut left = x;
        while left > 0
            && mask.get(left as u32 - 1, y as u32) == 0
            && matches(image.get(left as u32 - 1, y as u32), reference, tolerance)
        {
            left -= 1;
        }
        let mut right = x;
        while right + 1 < width as usize
            && mask.get(right as u32 + 1, y as u32) == 0
            && matches(image.get(right as u32 + 1, y as u32), reference, tolerance)
        {
            right += 1;
        }
        for px in left..=right {
            mask.set(px as u32, y as u32, 255);
        }
        for side in 0..2 {
            if (side == 0 && y == 0) || (side == 1 && y + 1 >= height as usize) {
                continue;
            }
            let ny = if side == 0 { y - 1 } else { y + 1 };
            let mut in_run = false;
            for nx in left..=right {
                let candidate =
                    mask.get(nx as u32, ny as u32) == 0 && matches(image.get(nx as u32, ny as u32), reference, tolerance);
                if candidate && !in_run {
                    stack.push((nx, ny));
                }
                in_run = candidate;
            }
        }
    }
    mask
}

/// Every pixel near one of the included colors and near none of the excluded ones. Colors are
/// matched on straight (unpremultiplied) RGB; fully transparent pixels never match.
pub fn color_range(
    image: &Bitmap8,
    include: &[[u8; 3]],
    exclude: &[[u8; 3]],
    fuzziness: u8,
    invert: bool,
) -> Gray8 {
    let width = image.width();
    let height = image.height();
    let mut mask = Gray8::new(width, height);
    let fuzziness = fuzziness as i32;
    for y in 0..height {
        for x in 0..width {
            let pixel = image.get(x, y);
            let mut selected = false;
            if pixel[3] != 0 {
                let mut rgb = [0i32; 3];
                for channel in 0..3 {
                    // Unpremultiply, the way the C kernel does before comparing.
                    rgb[channel] = ((pixel[channel] as i32 * 255 + pixel[3] as i32 / 2) / pixel[3] as i32).min(255);
                }
                selected = near_any(rgb, include, fuzziness) && !near_any(rgb, exclude, fuzziness);
            }
            if invert {
                selected = !selected;
            }
            if selected {
                mask.set(x, y, 255);
            }
        }
    }
    mask
}

fn near_any(rgb: [i32; 3], colors: &[[u8; 3]], fuzziness: i32) -> bool {
    colors.iter().any(|color| {
        (0..3).all(|channel| (rgb[channel] - color[channel] as i32).abs() <= fuzziness)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn point(x: f64, y: f64) -> PointF {
        PointF::new(x, y)
    }

    fn all_selected(mask: &Gray8) -> bool {
        !mask.pixels().is_empty() && mask.pixels().iter().all(|value| *value == 255)
    }

    fn none_selected(mask: &Gray8) -> bool {
        mask.pixels().iter().all(|value| *value == 0)
    }

    #[test]
    fn a_wand_at_zero_tolerance_matches_only_the_exact_color() {
        let mut image = Bitmap8::filled(8, 8, [10, 20, 30, 255]);
        image.set(4, 4, [11, 20, 30, 255]);
        let exact = magic_wand(&image, point(1.0, 1.0), WandSettings::new(0).with_contiguous(false));
        assert_eq!(exact.get(1, 1), 255);
        assert_eq!(exact.get(4, 4), 0);
        assert_eq!(exact.pixels().iter().filter(|value| **value != 0).count(), 63);
        assert_eq!(exact.get(7, 7), 255);
        let loose = magic_wand(&image, point(1.0, 1.0), WandSettings::new(1).with_contiguous(false));
        assert_eq!(loose.get(4, 4), 255);
        assert!(loose.pixels().iter().all(|value| *value == 255));
    }

    #[test]
    fn a_wand_at_full_tolerance_selects_everything() {
        let mut image = Bitmap8::new(4, 4);
        for y in 0..4 {
            for x in 0..4 {
                image.set(x, y, [(x * 60) as u8, (y * 60) as u8, 7, 255]);
            }
        }
        let everything = magic_wand(&image, point(0.0, 0.0), WandSettings::new(255));
        assert!(all_selected(&everything), "full tolerance takes the whole image");
        // Zero tolerance takes only the pixels that match the reference exactly.
        let exact = magic_wand(&image, point(0.0, 0.0), WandSettings::new(0).with_contiguous(false));
        assert!(!all_selected(&exact));
        assert_eq!(exact.get(0, 0), 255);
        assert_eq!(exact.get(1, 0), 0);
    }

    #[test]
    fn contiguous_matching_stops_at_a_different_region() {
        let mut image = Bitmap8::filled(11, 5, [200, 200, 200, 255]);
        for y in 0..5 {
            image.set(5, y, [10, 10, 10, 255]);
        }
        let settings = WandSettings::new(10);
        let contiguous = magic_wand(&image, point(1.0, 1.0), settings);
        assert_eq!(contiguous.get(0, 0), 255);
        assert_eq!(contiguous.get(4, 2), 255);
        assert_eq!(contiguous.get(6, 2), 0, "the flood fill must not jump the divider");
        assert_eq!(contiguous.get(10, 2), 0);
        let everywhere = magic_wand(&image, point(1.0, 1.0), settings.with_contiguous(false));
        assert_eq!(everywhere.get(10, 2), 255);
        assert_eq!(everywhere.get(5, 2), 0);
        // The divider itself is never selected, in either mode.
        assert_eq!(everywhere.get(5, 0), 0);
    }

    #[test]
    fn the_sample_size_averages_the_click_neighborhood() {
        let mut image = Bitmap8::filled(8, 8, [100, 100, 100, 255]);
        for y in 0..3 {
            for x in 0..3 {
                image.set(x, y, [200, 200, 200, 255]);
            }
        }
        assert_eq!(reference_color(&image, (1, 1), 0), Some([200, 200, 200, 255]));
        // A 3 by 3 average around a pixel on the boundary mixes both colors.
        let averaged = reference_color(&image, (2, 2), 1).expect("average");
        assert_eq!(averaged, [144, 144, 144, 255]);
        assert_eq!(reference_color(&image, (-1, 0), 0), None);
        assert_eq!(reference_color(&Bitmap8::new(0, 0), (0, 0), 0), None);
        // The average widens what the wand accepts: the point sample still misses the far block.
        let point_sample = magic_wand(&image, point(2.0, 2.0), WandSettings::new(60));
        let averaged_sample =
            magic_wand(&image, point(2.0, 2.0), WandSettings::new(60).with_sample_size(WandSampleSize::ThreeByThree));
        assert_eq!(point_sample.get(5, 5), 0, "the point sample stops at the block's edge");
        assert_eq!(averaged_sample.get(5, 5), 255);
        assert_eq!(WandSampleSize::FiveByFive.radius(), 2);
        assert_eq!(WandSampleSize::Point.radius(), 0);
    }

    #[test]
    fn a_click_outside_the_image_selects_nothing() {
        let image = Bitmap8::filled(4, 4, [1, 1, 1, 255]);
        assert!(none_selected(&magic_wand(&image, point(-1.0, 0.0), WandSettings::default())));
        assert!(none_selected(&magic_wand(&image, point(9.0, 9.0), WandSettings::default())));
        assert!(none_selected(&magic_wand(&image, point(f64::NAN, 0.0), WandSettings::default())));
        assert!(none_selected(&magic_wand(&Bitmap8::new(0, 0), point(0.0, 0.0), WandSettings::default())));
    }

    #[test]
    fn color_range_matches_include_minus_exclude_and_inverts() {
        // A blue field with two reddish pixels in it.
        let mut image = Bitmap8::filled(4, 4, [10, 10, 200, 255]);
        image.set(0, 0, [200, 10, 10, 255]);
        image.set(1, 0, [205, 12, 10, 255]);
        image.set(2, 0, [208, 10, 10, 255]);
        let red = [[200u8, 10, 10]];
        let blue = [[10u8, 10, 200]];
        let mask = color_range(&image, &red, &[], 8, false);
        assert_eq!(mask.get(0, 0), 255);
        assert_eq!(mask.get(1, 0), 255);
        assert_eq!(mask.get(3, 3), 0);
        // Fuzziness is inclusive: exactly 8 away still matches, 9 does not.
        assert_eq!(color_range(&image, &red, &[], 8, false).get(2, 0), 255);
        assert_eq!(color_range(&image, &red, &[], 7, false).get(2, 0), 0);
        // Excluding a color takes it back out of the result.
        let both = color_range(&image, &[[200, 10, 10], [10, 10, 200]], &blue, 8, false);
        assert_eq!(both.get(0, 0), 255);
        assert_eq!(both.get(3, 3), 0);
        let inverted = color_range(&image, &red, &[], 8, true);
        assert_eq!(inverted.get(0, 0), 0);
        assert_eq!(inverted.get(3, 3), 255);
        // No included color at all selects nothing, or everything when inverted.
        assert!(none_selected(&color_range(&image, &[], &[], 8, false)));
        assert!(all_selected(&color_range(&image, &[], &[], 8, true)));
    }

    #[test]
    fn color_range_ignores_transparent_pixels_and_unpremultiplies() {
        let mut image = Bitmap8::new(2, 1);
        image.set(0, 0, [0, 0, 0, 0]);
        // Half-transparent white is stored premultiplied-ish; straight white must still match.
        image.set(1, 0, [128, 128, 128, 128]);
        let white = [[255u8, 255, 255]];
        let mask = color_range(&image, &white, &[], 2, false);
        assert_eq!(mask.get(0, 0), 0, "a transparent pixel has no color to match");
        assert_eq!(mask.get(1, 0), 255);
    }

    #[test]
    fn an_outline_follows_the_mask_edges() {
        let mut mask = Gray8::new(8, 8);
        for y in 2..5 {
            for x in 2..6 {
                mask.set(x, y, 255);
            }
        }
        let loops = trace_outline(&mask).expect("outline");
        assert_eq!(loops.len(), 1);
        assert_eq!(loops[0].len(), 4, "a rectangle has four corners: {:?}", loops[0]);
        for corner in [[2, 2], [6, 2], [6, 5], [2, 5]] {
            assert!(loops[0].contains(&corner), "missing corner {corner:?} in {:?}", loops[0]);
        }
        assert!(trace_outline(&Gray8::new(4, 4)).expect("empty").is_empty());
    }

    #[test]
    fn an_outline_traces_disjoint_regions_and_holes() {
        let mut islands = Gray8::new(8, 8);
        islands.set(1, 1, 255);
        islands.set(6, 6, 255);
        let loops = trace_outline(&islands).expect("outline");
        assert_eq!(loops.len(), 2);
        assert!(loops.iter().all(|looped| looped.len() == 4));

        let mut ring = Gray8::new(7, 7);
        for y in 1..6 {
            for x in 1..6 {
                ring.set(x, y, 255);
            }
        }
        ring.set(3, 3, 0);
        let loops = trace_outline(&ring).expect("outline");
        assert_eq!(loops.len(), 2, "a hole is its own loop");
        assert!(loops.iter().any(|looped| looped.len() == 4));
    }
}

const EAST: u8 = 1;
const SOUTH: u8 = 2;
const WEST: u8 = 4;
const NORTH: u8 = 8;
/// Outlines with more pixel edges than this are refused: the path would be too slow to draw.
const EDGE_LIMIT: usize = 8_000_000;

#[inline]
fn turn_right(direction: u8) -> u8 {
    if direction == NORTH {
        EAST
    } else {
        direction << 1
    }
}

#[inline]
fn turn_left(direction: u8) -> u8 {
    if direction == EAST {
        NORTH
    } else {
        direction >> 1
    }
}

/// The mask's outline as closed loops of corner points on the pixel grid, winding clockwise
/// around selected pixels. This is what a marching-ants overlay draws, and it follows the
/// mask exactly rather than approximating it.
pub fn trace_outline(mask: &Gray8) -> Result<Vec<Vec<[i32; 2]>>> {
    let width = mask.width() as usize;
    let height = mask.height() as usize;
    if width == 0 || height == 0 {
        return Ok(Vec::new());
    }
    let stride = width + 1;
    let vertices = stride * (height + 1);
    // Each vertex of the (width + 1) x (height + 1) grid records the directed boundary edges
    // leaving it: a selected pixel's unselected sides, walked clockwise around the pixel.
    let mut edges = vec![0u8; vertices];
    let mut edge_count = 0usize;
    for y in 0..height {
        for x in 0..width {
            if mask.get(x as u32, y as u32) == 0 {
                continue;
            }
            if y == 0 || mask.get(x as u32, y as u32 - 1) == 0 {
                edges[y * stride + x] |= EAST;
                edge_count += 1;
            }
            if x + 1 == width || mask.get(x as u32 + 1, y as u32) == 0 {
                edges[y * stride + x + 1] |= SOUTH;
                edge_count += 1;
            }
            if y + 1 == height || mask.get(x as u32, y as u32 + 1) == 0 {
                edges[(y + 1) * stride + x + 1] |= WEST;
                edge_count += 1;
            }
            if x == 0 || mask.get(x as u32 - 1, y as u32) == 0 {
                edges[(y + 1) * stride + x] |= NORTH;
                edge_count += 1;
            }
        }
        if edge_count > EDGE_LIMIT {
            return Err(Error::TooLarge("that selection is too detailed to outline".into()));
        }
    }
    let mut loops: Vec<Vec<[i32; 2]>> = Vec::new();
    for start in 0..vertices {
        while edges[start] != 0 {
            let mut points: Vec<[i32; 2]> = Vec::new();
            let mut vertex = start;
            let mut heading = 0u8;
            let mut initial = 0u8;
            loop {
                let bits = edges[vertex];
                // Where two loops meet at a corner, turning right keeps them apart.
                let direction = if heading == 0 {
                    bits & bits.wrapping_neg()
                } else if bits & turn_right(heading) != 0 {
                    turn_right(heading)
                } else if bits & heading != 0 {
                    heading
                } else if bits & turn_left(heading) != 0 {
                    turn_left(heading)
                } else {
                    bits & bits.wrapping_neg()
                };
                if direction == 0 {
                    break;
                }
                edges[vertex] &= !direction;
                if direction != heading {
                    points.push([(vertex % stride) as i32, (vertex / stride) as i32]);
                }
                if heading == 0 {
                    initial = direction;
                }
                heading = direction;
                vertex = match direction {
                    EAST => vertex + 1,
                    WEST => vertex - 1,
                    SOUTH => vertex + stride,
                    _ => vertex - stride,
                };
                if vertex == start {
                    break;
                }
            }
            // The start is a corner unless the loop arrives on the heading it left with.
            if heading == initial && !points.is_empty() {
                points.remove(0);
            }
            if !points.is_empty() {
                loops.push(points);
            }
        }
    }
    Ok(loops)
}
