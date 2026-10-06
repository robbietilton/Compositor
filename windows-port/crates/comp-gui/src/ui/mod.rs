//! The egui layer: menus, toolbar, canvas, layers panel and status bar.
//!
//! Panels only read the editor state and call its commands. Anything that needs a decision lives in
//! the session, view or panel modules, where it can be tested without a window.

pub mod adjust;
pub mod canvas;
pub mod color;
pub mod filter;
pub mod guides;
pub mod layers;
pub mod menu;
pub mod status;
pub mod tabs;
pub mod text;
pub mod toolbar;

use egui::Color32;

/// A straight-alpha color as an egui color.
pub fn color32(rgba: [u8; 4]) -> Color32 {
    Color32::from_rgba_unmultiplied(rgba[0], rgba[1], rgba[2], rgba[3])
}

/// A short byte count for the status bar.
pub fn format_bytes(bytes: u64) -> String {
    const UNITS: [&str; 4] = ["B", "KB", "MB", "GB"];
    let mut value = bytes as f64;
    let mut unit = 0usize;
    while value >= 1024.0 && unit + 1 < UNITS.len() {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

/// A zoom percentage, with decimals only where they tell the user something.
pub fn format_zoom(zoom: f32) -> String {
    let percent = zoom * 100.0;
    if percent >= 100.0 {
        format!("{percent:.0}%")
    } else {
        format!("{percent:.1}%")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn byte_counts_use_the_largest_sensible_unit() {
        assert_eq!(format_bytes(0), "0 B");
        assert_eq!(format_bytes(999), "999 B");
        assert_eq!(format_bytes(1024), "1.0 KB");
        assert_eq!(format_bytes(1024 * 1024 * 3 / 2), "1.5 MB");
        assert_eq!(format_bytes(1024 * 1024 * 1024 * 2), "2.0 GB");
    }

    #[test]
    fn zoom_is_printed_the_way_the_status_bar_wants_it() {
        assert_eq!(format_zoom(1.0), "100%");
        assert_eq!(format_zoom(4.0), "400%");
        assert_eq!(format_zoom(0.125), "12.5%");
    }

    #[test]
    fn colors_keep_their_channels() {
        let color = color32([10, 20, 30, 255]);
        assert_eq!((color.r(), color.g(), color.b(), color.a()), (10, 20, 30, 255));
    }
}
