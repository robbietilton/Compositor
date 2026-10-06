//! Drawing a shape layer's pixels.
//!
//! A shape layer keeps its source, so resizing one redraws the shape at the new size instead of
//! stretching it: a rounded corner keeps its radius, and a line keeps its thickness. The geometry
//! here follows the macOS Shape tool: corners round by at most half the shorter side, ellipses
//! ignore the radius, and a line runs between the two fractional ends the drag recorded.

use crate::paint::{channel, put_pixel};
use comp_core::limits;
use comp_core::shape::{ShapeKind, ShapeStyle};
use comp_core::Bitmap8;

/// How many samples per axis the coverage of a curved edge is measured with. Sixteen steps give an
/// edge within a sixteenth of a pixel, which is finer than 8-bit alpha can show.
const SUPERSAMPLE_STEPS: u32 = 4;

/// The pixels a shape draws, anti-aliased where it curves.
pub fn rasterize_shape(style: &ShapeStyle, width: u32, height: u32) -> Bitmap8 {
    if width == 0 || height == 0 {
        return Bitmap8::new(width, height);
    }
    // A shape past the format's limits has no pixels to draw; one transparent pixel is the smallest
    // honest answer for a caller that ignored the size.
    if !limits::surface_fits(width, height) {
        return Bitmap8::new(1, 1);
    }
    let color = [channel(style.red), channel(style.green), channel(style.blue)];
    let mut bitmap = Bitmap8::new(width, height);
    match style.kind {
        ShapeKind::Rectangle => fill_rounded_rect(&mut bitmap, style.corner_radius, color),
        ShapeKind::Ellipse => fill_ellipse(&mut bitmap, color),
        ShapeKind::Line => stroke_line(&mut bitmap, style, color),
    }
    bitmap
}

/// The radius a corner may actually use: at most half the shorter side, so a large radius makes a
/// pill rather than eating the shape.
pub fn clamp_corner_radius(corner_radius: f64, width: u32, height: u32) -> f64 {
    if !corner_radius.is_finite() {
        return 0.0;
    }
    let limit = width.min(height) as f64 / 2.0;
    corner_radius.clamp(0.0, limit.max(0.0))
}

fn fill_rounded_rect(bitmap: &mut Bitmap8, corner_radius: f64, color: [u8; 3]) {
    let width = bitmap.width() as f64;
    let height = bitmap.height() as f64;
    let radius = clamp_corner_radius(corner_radius, bitmap.width(), bitmap.height());
    if radius <= 0.0 {
        for y in 0..bitmap.height() {
            for x in 0..bitmap.width() {
                put_pixel(bitmap, x as i64, y as i64, [color[0], color[1], color[2], 255]);
            }
        }
        return;
    }
    for y in 0..bitmap.height() {
        let top = y as f64;
        for x in 0..bitmap.width() {
            let left = x as f64;
            // The band between the corners is solid, so only the corners need sampling.
            let solid = (top >= radius && top + 1.0 <= height - radius)
                || (left >= radius && left + 1.0 <= width - radius);
            let alpha = if solid {
                255
            } else {
                supersample(|dx, dy| inside_rounded(left + dx, top + dy, width, height, radius))
            };
            if alpha > 0 {
                put_pixel(bitmap, x as i64, y as i64, [color[0], color[1], color[2], alpha]);
            }
        }
    }
}

/// True when a point is inside a rectangle with rounded corners. Clamping the point onto the inner
/// rectangle turns the test into a distance-to-corner-circle test.
fn inside_rounded(px: f64, py: f64, width: f64, height: f64, radius: f64) -> bool {
    let cx = px.clamp(radius, width - radius);
    let cy = py.clamp(radius, height - radius);
    let dx = px - cx;
    let dy = py - cy;
    dx * dx + dy * dy <= radius * radius
}

fn fill_ellipse(bitmap: &mut Bitmap8, color: [u8; 3]) {
    let width = bitmap.width() as f64;
    let height = bitmap.height() as f64;
    let (rx, ry) = (width / 2.0, height / 2.0);
    let (cx, cy) = (rx, ry);
    for y in 0..bitmap.height() {
        let top = y as f64;
        for x in 0..bitmap.width() {
            let left = x as f64;
            // Skip the pixels whose nearest corner is already outside the ellipse.
            let gap_x = ((left + 0.5 - cx).abs() - 0.5).max(0.0) / rx;
            let gap_y = ((top + 0.5 - cy).abs() - 0.5).max(0.0) / ry;
            if gap_x * gap_x + gap_y * gap_y > 1.0 {
                continue;
            }
            let alpha = supersample(|dx, dy| {
                let nx = (left + dx - cx) / rx;
                let ny = (top + dy - cy) / ry;
                nx * nx + ny * ny <= 1.0
            });
            if alpha > 0 {
                put_pixel(bitmap, x as i64, y as i64, [color[0], color[1], color[2], alpha]);
            }
        }
    }
}

fn stroke_line(bitmap: &mut Bitmap8, style: &ShapeStyle, color: [u8; 3]) {
    let width = bitmap.width() as f64;
    let height = bitmap.height() as f64;
    let thickness = match style.line_width {
        Some(value) if value.is_finite() && value > 0.0 => value,
        _ => 1.0,
    };
    let radius = thickness / 2.0;
    // Ends as fractions of the layer box. A line saved without them ran corner to corner, inset by
    // half its thickness so the stroke stayed inside the layer.
    let inset = (thickness.min(width) / 2.0, thickness.min(height) / 2.0);
    let from = end_point(style.start, width, height).unwrap_or((inset.0, inset.1));
    let to = end_point(style.end, width, height).unwrap_or((width - inset.0, height - inset.1));

    let left = (from.0.min(to.0) - radius - 1.0).floor().max(0.0) as u32;
    let top = (from.1.min(to.1) - radius - 1.0).floor().max(0.0) as u32;
    let right = (from.0.max(to.0) + radius + 1.0).ceil().min(width) as u32;
    let bottom = (from.1.max(to.1) + radius + 1.0).ceil().min(height) as u32;
    for y in top..bottom {
        for x in left..right {
            let distance = distance_to_segment(x as f64 + 0.5, y as f64 + 0.5, from, to);
            // A half pixel of feathering either side of the stroke gives the round caps and edges
            // their anti-aliasing without a second pass.
            let coverage = (radius + 0.5 - distance).clamp(0.0, 1.0);
            if coverage > 0.0 {
                let alpha = (coverage * 255.0).round() as u8;
                put_pixel(bitmap, x as i64, y as i64, [color[0], color[1], color[2], alpha]);
            }
        }
    }
}

/// A fractional end as layer pixels, or none when the style has no usable one.
fn end_point(fraction: Option<[f64; 2]>, width: f64, height: f64) -> Option<(f64, f64)> {
    let point = fraction?;
    if !point[0].is_finite() || !point[1].is_finite() {
        return None;
    }
    Some((point[0] * width, point[1] * height))
}

/// The distance from a point to a line segment, which is what a round-capped stroke measures.
fn distance_to_segment(px: f64, py: f64, from: (f64, f64), to: (f64, f64)) -> f64 {
    let (dx, dy) = (to.0 - from.0, to.1 - from.1);
    let length_squared = dx * dx + dy * dy;
    if length_squared <= 0.0 {
        return ((px - from.0).powi(2) + (py - from.1).powi(2)).sqrt();
    }
    let t = (((px - from.0) * dx + (py - from.1) * dy) / length_squared).clamp(0.0, 1.0);
    let cx = from.0 + t * dx;
    let cy = from.1 + t * dy;
    ((px - cx).powi(2) + (py - cy).powi(2)).sqrt()
}

/// The covered share of a pixel, sampled on a regular grid.
fn supersample(mut inside: impl FnMut(f64, f64) -> bool) -> u8 {
    let mut hits = 0u32;
    for row in 0..SUPERSAMPLE_STEPS {
        for column in 0..SUPERSAMPLE_STEPS {
            let dx = (column as f64 + 0.5) / SUPERSAMPLE_STEPS as f64;
            let dy = (row as f64 + 0.5) / SUPERSAMPLE_STEPS as f64;
            if inside(dx, dy) {
                hits += 1;
            }
        }
    }
    (hits * 255 / (SUPERSAMPLE_STEPS * SUPERSAMPLE_STEPS)) as u8
}

#[cfg(test)]
mod tests {
    use super::*;

    fn style(kind: ShapeKind) -> ShapeStyle {
        ShapeStyle { kind, red: 1.0, green: 0.0, blue: 0.0, corner_radius: 0.0, ..ShapeStyle::default() }
    }

    fn inked(bitmap: &Bitmap8) -> usize {
        let mut count = 0;
        for y in 0..bitmap.height() {
            for x in 0..bitmap.width() {
                if bitmap.get(x, y)[3] > 0 {
                    count += 1;
                }
            }
        }
        count
    }

    fn alpha(bitmap: &Bitmap8, x: u32, y: u32) -> u8 {
        bitmap.get(x, y)[3]
    }

    #[test]
    fn a_rectangle_covers_its_whole_box() {
        let bitmap = rasterize_shape(&style(ShapeKind::Rectangle), 10, 8);
        assert_eq!(inked(&bitmap), 80);
        for y in 0..8 {
            for x in 0..10 {
                assert_eq!(bitmap.get(x, y), [255, 0, 0, 255]);
            }
        }
    }

    #[test]
    fn shape_colors_come_from_the_style() {
        let style = ShapeStyle { kind: ShapeKind::Ellipse, red: 0.0, green: 0.5, blue: 1.0, corner_radius: 0.0, ..ShapeStyle::default() };
        let bitmap = rasterize_shape(&style, 8, 8);
        assert_eq!(bitmap.get(4, 4), [0, 128, 255, 255]);
    }

    #[test]
    fn a_damaged_color_does_not_panic() {
        let style = ShapeStyle { kind: ShapeKind::Rectangle, red: f64::NAN, green: 4.0, blue: -1.0, corner_radius: 0.0, ..ShapeStyle::default() };
        let bitmap = rasterize_shape(&style, 4, 4);
        assert_eq!(bitmap.get(0, 0), [0, 255, 0, 255]);
    }

    #[test]
    fn an_empty_box_draws_nothing() {
        let bitmap = rasterize_shape(&style(ShapeKind::Rectangle), 0, 10);
        assert!(bitmap.is_empty());
        assert_eq!(bitmap.byte_len(), 0);
    }

    #[test]
    fn an_oversized_shape_yields_a_placeholder() {
        let bitmap = rasterize_shape(&style(ShapeKind::Rectangle), 30_000, 30_000);
        assert_eq!((bitmap.width(), bitmap.height()), (1, 1));
        assert!(bitmap.is_fully_transparent());
    }

    #[test]
    fn a_zero_radius_rectangle_is_a_rectangle() {
        let square = rasterize_shape(&style(ShapeKind::Rectangle), 12, 12);
        let rounded = rasterize_shape(
            &ShapeStyle { corner_radius: 0.0, ..style(ShapeKind::Rectangle) },
            12,
            12,
        );
        assert_eq!(square.pixels(), rounded.pixels());
    }

    #[test]
    fn corners_round_by_the_radius() {
        let bitmap = rasterize_shape(
            &ShapeStyle { corner_radius: 4.0, ..style(ShapeKind::Rectangle) },
            20,
            20,
        );
        assert_eq!(alpha(&bitmap, 0, 0), 0, "the corner is cut off");
        assert_eq!(alpha(&bitmap, 19, 0), 0);
        assert_eq!(alpha(&bitmap, 0, 19), 0);
        assert_eq!(alpha(&bitmap, 19, 19), 0);
        assert_eq!(alpha(&bitmap, 10, 10), 255, "the middle stays solid");
        assert_eq!(alpha(&bitmap, 10, 0), 255, "the straight edges stay solid");
        assert_eq!(alpha(&bitmap, 0, 10), 255);
        // Only the corners lose anything, and at this radius each one loses a single pixel.
        assert_eq!(inked(&bitmap), 20 * 20 - 4);
    }

    #[test]
    fn a_large_radius_makes_a_pill() {
        let bitmap = rasterize_shape(
            &ShapeStyle { corner_radius: 500.0, ..style(ShapeKind::Rectangle) },
            20,
            20,
        );
        let circle = rasterize_shape(&style(ShapeKind::Ellipse), 20, 20);
        assert_eq!(bitmap.pixels(), circle.pixels(), "a radius past half the side is a circle");
        assert_eq!(clamp_corner_radius(500.0, 20, 20), 10.0);
        assert_eq!(clamp_corner_radius(-4.0, 20, 20), 0.0);
        assert_eq!(clamp_corner_radius(f64::NAN, 20, 20), 0.0);
    }

    #[test]
    fn an_ellipse_is_round() {
        let bitmap = rasterize_shape(&style(ShapeKind::Ellipse), 20, 10);
        assert_eq!(alpha(&bitmap, 10, 5), 255, "the center is solid");
        assert_eq!(alpha(&bitmap, 0, 0), 0, "the corner is outside");
        assert_eq!(alpha(&bitmap, 19, 9), 0);
        assert!(alpha(&bitmap, 0, 5) > 0 && alpha(&bitmap, 0, 5) < 255, "the edge is anti-aliased");
        assert!(alpha(&bitmap, 19, 5) > 0 && alpha(&bitmap, 19, 5) < 255);
    }

    #[test]
    fn an_ellipse_never_leaves_its_box() {
        let bitmap = rasterize_shape(&style(ShapeKind::Ellipse), 24, 16);
        for y in 0..16 {
            for x in 0..24 {
                let outside_x = (x as f64 + 0.5 - 12.0).abs() / 12.0;
                let outside_y = (y as f64 + 0.5 - 8.0).abs() / 8.0;
                if outside_x * outside_x + outside_y * outside_y > 1.2 {
                    assert_eq!(alpha(&bitmap, x, y), 0, "({x},{y}) is well outside the ellipse");
                }
            }
        }
    }

    #[test]
    fn a_one_pixel_wide_ellipse_still_draws() {
        let bitmap = rasterize_shape(&style(ShapeKind::Ellipse), 1, 12);
        assert_eq!(bitmap.width(), 1);
        assert!(inked(&bitmap) > 0);
    }

    #[test]
    fn a_line_runs_between_its_fractional_ends() {
        let line = ShapeStyle {
            kind: ShapeKind::Line,
            line_width: Some(10.0),
            start: Some([0.1, 0.5]),
            end: Some([0.9, 0.5]),
            ..style(ShapeKind::Line)
        };
        let bitmap = rasterize_shape(&line, 100, 100);
        assert_eq!(alpha(&bitmap, 10, 50), 255, "the start point is solid");
        assert_eq!(alpha(&bitmap, 50, 50), 255, "so is the middle");
        assert_eq!(alpha(&bitmap, 50, 0), 0, "and nothing is drawn far away");
        assert_eq!(alpha(&bitmap, 50, 99), 0);
    }

    #[test]
    fn a_line_has_round_caps() {
        let line = ShapeStyle {
            kind: ShapeKind::Line,
            line_width: Some(10.0),
            start: Some([0.5, 0.5]),
            end: Some([0.5, 0.5]),
            ..style(ShapeKind::Line)
        };
        let dot = rasterize_shape(&line, 40, 40);
        assert!(alpha(&dot, 20, 20) > 0, "a line with no length is a dot");
        assert_eq!(alpha(&dot, 5, 5), 0);
        // A round cap reaches half a thickness past the end.
        let capped = ShapeStyle { end: Some([0.5, 0.5]), start: Some([0.5, 0.3]), ..line };
        let bitmap = rasterize_shape(&capped, 40, 40);
        assert!(alpha(&bitmap, 20, 9) > 0, "the cap reaches past the endpoint");
        assert_eq!(alpha(&bitmap, 20, 0), 0);
    }

    #[test]
    fn a_thicker_line_covers_more() {
        let thin = ShapeStyle { line_width: Some(2.0), ..style(ShapeKind::Line) };
        let thick = ShapeStyle { line_width: Some(20.0), ..style(ShapeKind::Line) };
        let thin = rasterize_shape(&thin, 40, 40);
        let thick = rasterize_shape(&thick, 40, 40);
        assert!(inked(&thick) > inked(&thin) * 4);
    }

    #[test]
    fn a_line_without_ends_runs_corner_to_corner() {
        let line = ShapeStyle { line_width: Some(4.0), ..style(ShapeKind::Line) };
        let bitmap = rasterize_shape(&line, 20, 20);
        assert!(alpha(&bitmap, 2, 2) > 0, "the stroke starts inside the corner");
        assert!(alpha(&bitmap, 17, 17) > 0);
        assert_eq!(alpha(&bitmap, 0, 19), 0, "the far corner is empty");
        assert_eq!(alpha(&bitmap, 19, 0), 0);
    }

    #[test]
    fn a_line_without_a_width_still_draws_a_thread() {
        let line = ShapeStyle { line_width: None, ..style(ShapeKind::Line) };
        let bitmap = rasterize_shape(&line, 20, 20);
        assert!(inked(&bitmap) > 0);
        assert!(inked(&bitmap) < 20 * 20, "one pixel of thread, not a filled box");
    }

    #[test]
    fn ends_outside_the_box_are_clipped_without_panicking() {
        let line = ShapeStyle {
            line_width: Some(6.0),
            start: Some([-1.0, 0.5]),
            end: Some([2.0, 0.5]),
            ..style(ShapeKind::Line)
        };
        let bitmap = rasterize_shape(&line, 20, 20);
        assert!(alpha(&bitmap, 0, 10) > 0);
        assert!(alpha(&bitmap, 19, 10) > 0);
        let damaged = ShapeStyle { start: Some([f64::NAN, 0.0]), end: Some([f64::INFINITY, 1.0]), ..line };
        assert!(inked(&rasterize_shape(&damaged, 20, 20)) > 0, "unusable ends fall back to the corners");
    }

    #[test]
    fn a_rectangle_and_an_ellipse_cover_different_areas() {
        let rectangle = rasterize_shape(&style(ShapeKind::Rectangle), 30, 30);
        let ellipse = rasterize_shape(&style(ShapeKind::Ellipse), 30, 30);
        assert_eq!(inked(&rectangle), 900);
        let circle = inked(&ellipse);
        assert!(circle > 600 && circle < 790, "a circle is about pi/4 of its box: {circle}");
    }
}
