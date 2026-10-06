//! The curve editor's rules, in the 0..255 units the format stores a curve in.
//!
//! Drawing uses comp-render's own interpolation, so the curve on screen is the curve that will be
//! rendered rather than a second approximation of it.

use comp_core::adjustment::CurvePoint;
use egui::{Pos2, Rect};

/// Curve units per axis; the format stores 0..255, not 0..1.
pub const CURVE_MAX: f64 = 255.0;
/// The smallest gap two control points may have on the x axis, in curve units.
pub const MIN_GAP: f64 = 2.0;

/// The curve that changes nothing: black to black, white to white.
pub fn identity() -> Vec<CurvePoint> {
    vec![CurvePoint { x: 0.0, y: 0.0 }, CurvePoint { x: CURVE_MAX, y: CURVE_MAX }]
}

/// True for a straight line with both endpoints where the format expects them.
pub fn is_identity(points: &[CurvePoint]) -> bool {
    points.len() == 2 && points[0] == CurvePoint { x: 0.0, y: 0.0 } && points[1] == CurvePoint { x: CURVE_MAX, y: CURVE_MAX }
}

/// True when the points can be stored: at least two, inside the range, x strictly increasing, and
/// the ends pinned to the full range so the curve always covers every tone.
pub fn is_valid(points: &[CurvePoint]) -> bool {
    if points.len() < 2 {
        return false;
    }
    let mut previous = f64::NEG_INFINITY;
    for point in points {
        if !point.x.is_finite() || !point.y.is_finite() {
            return false;
        }
        if !(0.0..=CURVE_MAX).contains(&point.x) || !(0.0..=CURVE_MAX).contains(&point.y) {
            return false;
        }
        if point.x <= previous {
            return false;
        }
        previous = point.x;
    }
    points[0].x == 0.0 && points[points.len() - 1].x == CURVE_MAX
}

/// Inserts a point, keeping x sorted and strictly increasing.
///
/// Returns the index it landed at, or None when it would sit on top of a neighbor or outside the
/// range. Endpoints are not addable: the curve always spans the whole axis.
pub fn add_point(points: &mut Vec<CurvePoint>, x: f64, y: f64) -> Option<usize> {
    if !x.is_finite() || !y.is_finite() || x <= 0.0 || x >= CURVE_MAX {
        return None;
    }
    let y = y.clamp(0.0, CURVE_MAX);
    if points.iter().any(|point| (point.x - x).abs() < MIN_GAP) {
        return None;
    }
    let index = points.iter().position(|point| point.x > x).unwrap_or(points.len());
    points.insert(index, CurvePoint { x, y });
    Some(index)
}

/// Moves a point. Interior points slide in x between their neighbors and in y across the range;
/// the ends keep their x so the curve stays anchored, but may still be dragged up and down.
pub fn move_point(points: &mut [CurvePoint], index: usize, x: f64, y: f64) -> bool {
    if index >= points.len() || !x.is_finite() || !y.is_finite() {
        return false;
    }
    let lower = if index == 0 { 0.0 } else { points[index - 1].x + MIN_GAP };
    let upper = if index + 1 == points.len() { CURVE_MAX } else { points[index + 1].x - MIN_GAP };
    let next_x = if index == 0 {
        0.0
    } else if index + 1 == points.len() {
        CURVE_MAX
    } else {
        x.clamp(lower.min(upper), upper.max(lower))
    };
    let next_y = y.clamp(0.0, CURVE_MAX);
    if points[index] == (CurvePoint { x: next_x, y: next_y }) {
        return false;
    }
    points[index] = CurvePoint { x: next_x, y: next_y };
    true
}

/// Removes an interior point. The two ends stay: a curve needs them to cover every tone.
pub fn remove_point(points: &mut Vec<CurvePoint>, index: usize) -> bool {
    if points.len() <= 2 || index == 0 || index + 1 >= points.len() {
        return false;
    }
    points.remove(index);
    true
}

/// The index of the point within a tolerance, nearest first.
pub fn nearest_point(points: &[CurvePoint], x: f64, y: f64, tolerance: f64) -> Option<usize> {
    let mut best: Option<(usize, f64)> = None;
    for (index, point) in points.iter().enumerate() {
        let distance = ((point.x - x).powi(2) + (point.y - y).powi(2)).sqrt();
        if distance <= tolerance && best.map(|(_, closest)| distance < closest).unwrap_or(true) {
            best = Some((index, distance));
        }
    }
    best.map(|(index, _)| index)
}

/// The curve sampled for drawing, through comp-render's shape-preserving interpolation.
pub fn sample(points: &[CurvePoint], steps: usize) -> Vec<(f64, f64)> {
    let steps = steps.max(2);
    (0..=steps)
        .map(|step| {
            let x = CURVE_MAX * step as f64 / steps as f64;
            (x, comp_render::adjustment::curve_value(points, x).clamp(0.0, CURVE_MAX))
        })
        .collect()
}

/// Curve units to a widget position: x to the right, y upwards.
pub fn to_screen(rect: Rect, point: (f64, f64)) -> Pos2 {
    Pos2::new(
        rect.left() + (point.0 / CURVE_MAX) as f32 * rect.width(),
        rect.bottom() - (point.1 / CURVE_MAX) as f32 * rect.height(),
    )
}

/// A widget position back in curve units.
pub fn to_curve(rect: Rect, position: Pos2) -> (f64, f64) {
    if rect.width() <= 0.0 || rect.height() <= 0.0 {
        return (0.0, 0.0);
    }
    (
        ((position.x - rect.left()) / rect.width()) as f64 * CURVE_MAX,
        ((rect.bottom() - position.y) / rect.height()) as f64 * CURVE_MAX,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_sorted(points: &[CurvePoint]) {
        assert!(is_valid(points), "the curve is not storable: {points:?}");
    }

    #[test]
    fn the_identity_curve_is_valid_and_recognised() {
        let points = identity();
        assert_sorted(&points);
        assert!(is_identity(&points));
        assert_eq!(points[0].x, 0.0);
        assert_eq!(points[1].x, CURVE_MAX);
    }

    #[test]
    fn adding_a_point_keeps_x_strictly_increasing() {
        let mut points = identity();
        let index = add_point(&mut points, 128.0, 200.0).expect("a middle point");
        assert_eq!(index, 1);
        assert_sorted(&points);
        assert_eq!(points[1], CurvePoint { x: 128.0, y: 200.0 });

        add_point(&mut points, 64.0, 20.0).expect("a lower point");
        assert_sorted(&points);
        assert_eq!(points[1].x, 64.0);
    }

    #[test]
    fn adding_refuses_points_that_would_collide_or_leave_the_range() {
        let mut points = identity();
        assert!(add_point(&mut points, 128.0, 100.0).is_some());
        assert!(add_point(&mut points, 129.0, 100.0).is_none(), "too close to the previous point");
        assert!(add_point(&mut points, 0.0, 0.0).is_none(), "the left end is fixed");
        assert!(add_point(&mut points, CURVE_MAX, CURVE_MAX).is_none(), "the right end is fixed");
        assert!(add_point(&mut points, -5.0, 10.0).is_none());
        assert!(add_point(&mut points, 300.0, 10.0).is_none());
        assert!(add_point(&mut points, f64::NAN, 10.0).is_none());
        assert_sorted(&points);
        assert_eq!(points.len(), 3);
    }

    #[test]
    fn an_interior_point_slides_between_its_neighbours() {
        let mut points = identity();
        add_point(&mut points, 128.0, 128.0).unwrap();
        assert!(move_point(&mut points, 1, 400.0, 128.0));
        assert_eq!(points[1].x, CURVE_MAX - MIN_GAP, "it stops a gap short of the right end");
        assert_sorted(&points);
        assert!(move_point(&mut points, 1, -50.0, 128.0));
        assert_eq!(points[1].x, MIN_GAP, "and a gap past the left end");
        assert_sorted(&points);
        assert!(move_point(&mut points, 1, 128.0, 900.0));
        assert_eq!(points[1].y, CURVE_MAX, "y is clamped to the axis");
        assert_sorted(&points);
    }

    #[test]
    fn the_ends_keep_their_x_but_still_move_in_y() {
        let mut points = identity();
        assert!(move_point(&mut points, 0, 200.0, 40.0));
        assert_eq!(points[0], CurvePoint { x: 0.0, y: 40.0 }, "the left end stays at x=0");
        let last = points.len() - 1;
        assert!(move_point(&mut points, last, 10.0, 220.0));
        assert_eq!(points[last], CurvePoint { x: CURVE_MAX, y: 220.0 });
        assert_sorted(&points);
    }

    #[test]
    fn moving_a_point_to_where_it_already_is_reports_no_change() {
        let mut points = identity();
        assert!(!move_point(&mut points, 1, CURVE_MAX + 10.0, CURVE_MAX + 10.0));
        assert!(!move_point(&mut points, 9, 0.0, 0.0), "there is no such point");
    }

    #[test]
    fn the_ends_cannot_be_deleted_and_two_points_always_remain() {
        let mut points = identity();
        assert!(!remove_point(&mut points, 0));
        assert!(!remove_point(&mut points, 1), "removing the last end would leave one point");
        add_point(&mut points, 100.0, 20.0).unwrap();
        assert!(remove_point(&mut points, 1));
        assert_eq!(points.len(), 2);
        assert_sorted(&points);
        assert!(!remove_point(&mut points, 5), "there is no such point");
    }

    #[test]
    fn validity_rejects_curves_the_format_would_refuse() {
        assert!(!is_valid(&[]));
        assert!(!is_valid(&[CurvePoint { x: 0.0, y: 0.0 }]));
        assert!(!is_valid(&[CurvePoint { x: 0.0, y: 0.0 }, CurvePoint { x: 0.0, y: 255.0 }]), "duplicate x");
        assert!(!is_valid(&[CurvePoint { x: 10.0, y: 0.0 }, CurvePoint { x: 255.0, y: 255.0 }]), "left end moved");
        assert!(!is_valid(&[CurvePoint { x: 0.0, y: 0.0 }, CurvePoint { x: 200.0, y: 255.0 }]), "right end moved");
        assert!(!is_valid(&[CurvePoint { x: 0.0, y: 0.0 }, CurvePoint { x: 255.0, y: 300.0 }]), "y out of range");
        assert!(!is_valid(&[CurvePoint { x: 0.0, y: 0.0 }, CurvePoint { x: f64::NAN, y: 1.0 }]));
    }

    #[test]
    fn the_drawn_curve_passes_through_every_control_point() {
        let mut points = identity();
        add_point(&mut points, 64.0, 30.0).unwrap();
        add_point(&mut points, 190.0, 220.0).unwrap();
        let drawn = sample(&points, 256);
        assert_eq!(drawn.first().unwrap().0, 0.0);
        assert_eq!(drawn.last().unwrap().0, CURVE_MAX);
        assert!(drawn.iter().all(|(_, y)| (0.0..=CURVE_MAX).contains(y)));
        for point in &points {
            let closest = drawn
                .iter()
                .map(|(x, y)| ((x - point.x).abs(), *y))
                .min_by(|left, right| left.0.partial_cmp(&right.0).unwrap())
                .unwrap();
            assert!(
                (closest.1 - point.y).abs() < 3.0,
                "the curve misses the point at x={} by {}",
                point.x,
                (closest.1 - point.y).abs()
            );
        }
    }

    #[test]
    fn the_widget_mapping_round_trips() {
        let rect = Rect::from_min_size(Pos2::new(10.0, 20.0), egui::Vec2::new(200.0, 200.0));
        for point in [(0.0, 0.0), (255.0, 255.0), (64.0, 200.0), (128.0, 128.0)] {
            // The widget works in f32 points, so the round trip is exact to about a thousandth of a
            // curve unit rather than to the last bit.
            let back = to_curve(rect, to_screen(rect, point));
            assert!((back.0 - point.0).abs() < 1e-3, "{point:?} came back as {back:?}");
            assert!((back.1 - point.1).abs() < 1e-3, "{point:?} came back as {back:?}");
        }
        // y grows downwards on screen, so the top-left corner is the top of the range.
        let top_left = to_curve(rect, rect.left_top());
        assert_eq!(top_left, (0.0, CURVE_MAX));
        let bottom_right = to_curve(rect, rect.right_bottom());
        assert!((bottom_right.0 - CURVE_MAX).abs() < 1e-6 && bottom_right.1.abs() < 1e-6);
    }

    #[test]
    fn the_nearest_point_search_respects_its_tolerance() {
        let mut points = identity();
        add_point(&mut points, 100.0, 100.0).unwrap();
        assert_eq!(nearest_point(&points, 102.0, 103.0, 8.0), Some(1));
        assert_eq!(nearest_point(&points, 102.0, 103.0, 1.0), None);
        assert_eq!(nearest_point(&points, 1.0, 1.0, 8.0), Some(0));
    }
}
