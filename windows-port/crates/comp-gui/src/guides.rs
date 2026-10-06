//! Rulers, the layout grid, guides and snapping.
//!
//! The rules follow the macOS app: rulers number every 1-2-5 step that is about 70 points wide, the
//! grid is a major line every spacing pixels cut into subdivisions, and a drag snaps to the nearest
//! target within about five screen points of it. Everything here is arithmetic on numbers, so it can
//! be tested without a canvas.

use comp_core::geom::{Guide, GuideAxis};

/// The layout grid, after Photoshop's Guides, Grid & Slices settings.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GridSettings {
    pub visible: bool,
    /// Pixels between major lines.
    pub spacing: u32,
    /// How many cells each major square is cut into.
    pub subdivisions: u32,
}

/// The ranges the grid settings allow, as macOS has them.
pub const GRID_SPACING_RANGE: (u32, u32) = (2, 4096);
pub const GRID_SUBDIVISION_RANGE: (u32, u32) = (1, 64);
/// The most lines a grid is drawn from, so a one-pixel grid on a huge canvas cannot stall a frame.
pub const MAX_GRID_LINES: usize = 4000;
/// The distance that counts as close enough, in screen points, as macOS uses for guides.
pub const SNAP_POINTS: f64 = 5.0;

impl Default for GridSettings {
    fn default() -> Self {
        GridSettings { visible: false, spacing: 64, subdivisions: 4 }
    }
}

impl GridSettings {
    /// The distance between two drawn lines.
    pub fn step(&self) -> f64 {
        self.spacing.max(1) as f64 / self.subdivisions.max(1) as f64
    }

    /// The settings inside the ranges the panel offers.
    pub fn normalized(self) -> Self {
        GridSettings {
            visible: self.visible,
            spacing: self.spacing.clamp(GRID_SPACING_RANGE.0, GRID_SPACING_RANGE.1),
            subdivisions: self.subdivisions.clamp(GRID_SUBDIVISION_RANGE.0, GRID_SUBDIVISION_RANGE.1),
        }
    }

    /// Every grid line along a document edge, in whole pixels.
    ///
    /// The lines are counted from the origin rather than added up, so an uneven step does not drift
    /// away from the majors, and the list stops at the cap the UI can draw.
    pub fn lines(&self, length: f64) -> Vec<f64> {
        if !length.is_finite() || length < 0.0 {
            return vec![0.0];
        }
        let step = self.step();
        if step <= 0.0 {
            return vec![0.0];
        }
        let count = ((length / step + 0.001).floor() as i64).clamp(0, MAX_GRID_LINES as i64);
        (0..=count).map(|index| (index as f64 * step).round()).collect()
    }

    /// True for a line that starts a major square.
    pub fn is_major(&self, value: f64) -> bool {
        let spacing = self.spacing.max(1) as f64;
        let remainder = value.round() % spacing;
        remainder.abs() < 0.001 || (remainder - spacing).abs() < 0.001
    }
}

/// What a drag snaps to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SnapSettings {
    pub enabled: bool,
    pub guides: bool,
    pub grid: bool,
    pub document: bool,
    pub layers: bool,
}

impl Default for SnapSettings {
    fn default() -> Self {
        SnapSettings { enabled: true, guides: true, grid: true, document: true, layers: true }
    }
}

impl SnapSettings {
    /// How many kinds are on, for the menu's summary.
    pub fn kinds(&self) -> usize {
        [self.guides, self.grid, self.document, self.layers].iter().filter(|on| **on).count()
    }
}

/// The snapping distance in document pixels: five screen points at this zoom.
pub fn snap_distance(zoom: f64) -> f64 {
    SNAP_POINTS / zoom.max(0.0001)
}

/// The nearest target within the tolerance, or the value itself when nothing is close enough.
///
/// A tie keeps the first target, which is the order macOS collects them in: grid, then guides, then
/// the document's own edges.
pub fn snap(value: f64, targets: &[f64], tolerance: f64) -> f64 {
    let mut best: Option<f64> = None;
    for target in targets.iter().copied().filter(|target| target.is_finite()) {
        if (target - value).abs() > tolerance {
            continue;
        }
        match best {
            Some(current) if (current - value).abs() <= (target - value).abs() => {}
            _ => best = Some(target),
        }
    }
    best.unwrap_or(value)
}

/// The targets one axis offers a drag.
///
/// The layer edges are the near, middle and far edges of whatever is being dragged, already in
/// document pixels for this axis, so this function stays arithmetic.
pub fn targets(
    axis: GuideAxis,
    document: (f64, f64),
    guides: &[Guide],
    grid: &GridSettings,
    settings: &SnapSettings,
    layer_edges: &[f64],
) -> Vec<f64> {
    let mut found: Vec<f64> = Vec::new();
    let length = match axis {
        GuideAxis::Vertical => document.0,
        GuideAxis::Horizontal => document.1,
    };
    if settings.grid && grid.visible {
        found.extend(grid.lines(length));
    }
    if settings.guides {
        found.extend(guides.iter().filter(|guide| guide.axis == axis).map(|guide| guide.position));
    }
    if settings.document {
        found.extend([0.0, length / 2.0, length]);
    }
    if settings.layers {
        found.extend(layer_edges.iter().copied());
    }
    found
}

/// The numbered ruler step for a zoom: the smallest 1-2-5 step about 70 points wide.
pub fn ruler_step(points_per_pixel: f64) -> f64 {
    const NICE: [f64; 18] = [
        1.0, 2.0, 5.0, 10.0, 20.0, 25.0, 50.0, 100.0, 200.0, 250.0, 500.0, 1_000.0, 2_000.0, 2_500.0,
        5_000.0, 10_000.0, 20_000.0, 25_000.0,
    ];
    let target = 70.0 / points_per_pixel.max(0.0001);
    NICE.iter().copied().find(|step| *step >= target).unwrap_or(50_000.0)
}

/// The number a ruler prints.
pub fn ruler_label(value: f64) -> String {
    format!("{}", value.round() as i64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn guide(axis: GuideAxis, position: f64) -> Guide {
        Guide { id: Uuid::new_v4(), axis, position }
    }

    #[test]
    fn the_grid_counts_lines_from_the_origin() {
        let grid = GridSettings { visible: true, spacing: 10, subdivisions: 4 };
        assert_eq!(grid.step(), 2.5);
        assert_eq!(grid.lines(10.0), vec![0.0, 3.0, 5.0, 8.0, 10.0], "each line is rounded to a whole pixel");
        assert_eq!(grid.lines(0.0), vec![0.0]);
        assert!(grid.lines(f64::NAN).len() == 1, "a canvas with no sensible size still has an origin");
    }

    #[test]
    fn a_grid_of_one_pixel_cells_stops_at_the_cap() {
        let grid = GridSettings { visible: true, spacing: 2, subdivisions: 64 };
        let lines = grid.lines(100_000.0);
        assert!(lines.len() <= MAX_GRID_LINES + 1, "the grid cannot be drawn line by line forever");
        assert_eq!(lines[0], 0.0);
    }

    #[test]
    fn the_grid_says_which_lines_are_major() {
        let grid = GridSettings { visible: true, spacing: 50, subdivisions: 5 };
        assert!(grid.is_major(0.0));
        assert!(grid.is_major(50.0));
        assert!(grid.is_major(100.0));
        assert!(!grid.is_major(10.0));
        assert!(!grid.is_major(60.0), "a subdivision is not a major line");
    }

    #[test]
    fn the_grid_settings_clamp_to_their_ranges() {
        let wild = GridSettings { visible: true, spacing: 100_000, subdivisions: 0 }.normalized();
        assert_eq!(wild.spacing, GRID_SPACING_RANGE.1);
        assert_eq!(wild.subdivisions, GRID_SUBDIVISION_RANGE.0);
        let small = GridSettings { visible: false, spacing: 0, subdivisions: 999 }.normalized();
        assert_eq!(small.spacing, GRID_SPACING_RANGE.0);
        assert_eq!(small.subdivisions, GRID_SUBDIVISION_RANGE.1);
        assert!(!small.visible);
    }

    #[test]
    fn snapping_takes_the_nearest_target_within_the_tolerance() {
        let targets = [0.0, 100.0, 104.0];
        assert_eq!(snap(103.0, &targets, 5.0), 104.0, "the nearest wins");
        assert_eq!(snap(50.0, &targets, 5.0), 50.0, "nothing is close enough, so nothing moves");
        assert_eq!(snap(96.0, &targets, 5.0), 100.0);
        assert_eq!(snap(-2.0, &targets, 5.0), 0.0, "the canvas edge pulls a drag back");
        assert_eq!(snap(4.0, &targets, 0.0), 4.0, "a zero tolerance snaps only onto a target");
        assert_eq!(snap(0.0, &targets, 5.0), 0.0);
    }

    #[test]
    fn the_tolerance_is_five_screen_points_at_any_zoom() {
        assert_eq!(snap_distance(1.0), 5.0);
        assert_eq!(snap_distance(4.0), 1.25, "zoomed in, five points is a quarter of a document pixel");
        assert_eq!(snap_distance(0.25), 20.0, "zoomed out, five points covers more of the document");
        assert!(snap_distance(0.0).is_finite(), "a broken zoom cannot make the tolerance infinite");
    }

    #[test]
    fn the_targets_follow_the_switches() {
        // The horizontal guide sits off the grid, so the two cannot be confused for one another.
        let guides = [guide(GuideAxis::Vertical, 30.0), guide(GuideAxis::Horizontal, 45.0)];
        let grid = GridSettings { visible: true, spacing: 20, subdivisions: 1 };
        let all = SnapSettings::default();
        let vertical = targets(GuideAxis::Vertical, (100.0, 80.0), &guides, &grid, &all, &[55.0]);
        assert!(vertical.contains(&30.0), "a vertical guide is a target for a vertical drag");
        assert!(!vertical.contains(&45.0), "a horizontal guide is not a target for a vertical drag");
        assert!(vertical.contains(&20.0), "the grid is");
        assert!(vertical.contains(&0.0) && vertical.contains(&50.0) && vertical.contains(&100.0), "edges and center");
        assert!(vertical.contains(&55.0), "and the edges of what is being dragged");
        assert_eq!(all.kinds(), 4);

        let none = SnapSettings { enabled: true, guides: false, grid: false, document: false, layers: false };
        assert!(targets(GuideAxis::Vertical, (100.0, 80.0), &guides, &grid, &none, &[55.0]).is_empty());

        // A hidden grid offers nothing even when snapping to the grid is on.
        let hidden = GridSettings { visible: false, ..grid };
        let without_grid = targets(GuideAxis::Vertical, (100.0, 80.0), &guides, &hidden, &all, &[]);
        assert!(!without_grid.contains(&20.0));
        assert!(without_grid.contains(&30.0));
    }

    #[test]
    fn the_ruler_numbers_about_every_seventy_points() {
        // At 1:1 a step of 100 is the first one at least 70 points wide.
        assert_eq!(ruler_step(1.0), 100.0);
        assert_eq!(ruler_step(4.0), 20.0, "zoomed in, the numbers come closer together");
        assert_eq!(ruler_step(0.25), 500.0, "zoomed out, they spread apart");
        // The step covers the target and never grows as the zoom does.
        let mut previous = 0.0;
        for zoom in [0.01, 0.1, 0.5, 1.0, 2.0, 8.0, 32.0] {
            let step = ruler_step(zoom);
            assert!(step * zoom >= 70.0 || step >= 50_000.0, "zoom {zoom}: a step of {step} is too small");
            if previous > 0.0 {
                assert!(step <= previous, "zoom {zoom}: the step grew as the zoom did");
            }
            previous = step;
        }
        assert_eq!(ruler_step(0.0), 50_000.0, "a broken zoom still gets a step");
    }

    #[test]
    fn the_ruler_prints_whole_numbers() {
        assert_eq!(ruler_label(0.0), "0");
        assert_eq!(ruler_label(199.6), "200");
        assert_eq!(ruler_label(-50.0), "-50");
    }
}
