//! The Filter menu: the names, the groups, and how each kind runs.
//!
//! comp-render owns the filters themselves. This module is the menu's view of them: which kinds run
//! on the selected layer's pixels, which are really adjustment layers, and which need another crate
//! of this workspace. Every filter goes through comp_render::apply_filter, so the pixels are the
//! engine's, not a second implementation of them.

use comp_core::adjustment::AdjustmentKind;
use comp_core::bitmap::Bitmap8;

pub use comp_render::{FilterKind, FilterSettings};

/// A range as egui's sliders want it, so a panel and a dialog cannot spell the same limit differently.
pub fn range(pair: (f64, f64)) -> std::ops::RangeInclusive<f64> {
    pair.0..=pair.1
}

/// The ranges the dialogs offer, matching the limits the macOS FilterSettings documents.
pub const RADIUS_RANGE: (f64, f64) = (0.1, 250.0);
pub const ANGLE_RANGE: (f64, f64) = (-90.0, 90.0);
pub const DISTANCE_RANGE: (f64, f64) = (1.0, 2000.0);
pub const AMOUNT_RANGE: (f64, f64) = (0.1, 400.0);
pub const VIGNETTE_AMOUNT_RANGE: (f64, f64) = (0.0, 100.0);
pub const VIGNETTE_MIDPOINT_RANGE: (f64, f64) = (0.0, 100.0);
pub const VIGNETTE_ROUNDNESS_RANGE: (f64, f64) = (-100.0, 100.0);
pub const VIGNETTE_FEATHER_RANGE: (f64, f64) = (0.0, 100.0);
pub const VIGNETTE_HIGHLIGHTS_RANGE: (f64, f64) = (0.0, 100.0);
pub const BLOOM_AMOUNT_RANGE: (f64, f64) = (0.0, 100.0);
pub const BLOOM_RADIUS_RANGE: (f64, f64) = (1.0, 150.0);
pub const TONAL_AMOUNT_RANGE: (f64, f64) = (0.0, 100.0);
pub const TONAL_RADIUS_RANGE: (f64, f64) = (1.0, 100.0);
pub const TONAL_STRENGTH_RANGE: (f64, f64) = (-100.0, 100.0);
pub const DISTORTION_RANGE: (f64, f64) = (-100.0, 100.0);
pub const DITHER_PIXEL_RANGE: (f64, f64) = (1.0, 16.0);
pub const DITHER_LEVELS_RANGE: (f64, f64) = (2.0, 16.0);
pub const DITHER_PERCENT_RANGE: (f64, f64) = (0.0, 100.0);
pub const DITHER_TONE_RANGE: (f64, f64) = (-100.0, 100.0);

/// The menu, in the order macOS lists the filters.
pub const MENU: [FilterKind; 17] = FilterKind::ALL;

/// What the editor does with a filter kind.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FilterBackend {
    /// Runs on the selected layer's pixels through comp-render.
    Pixels,
    /// Adds an adjustment layer, which the existing adjustment panel edits.
    AdjustmentLayer(AdjustmentKind),
    /// The Camera Raw window, because the grade lives in comp-raw.
    CameraRaw,
    /// The subject extractors, which need the model the window holds.
    Subject,
    /// comp-brush repaints the selection from the rest of the layer.
    ContentAwareFill,
    /// Nothing in this build can run it; the string names what it would need.
    Unsupported(&'static str),
}

/// The menu's view of a comp-render filter kind.
pub trait FilterMenu: Copy + Sized {
    /// The name the menu shows.
    fn name(self) -> &'static str;
    fn backend(self) -> FilterBackend;
    /// True when the filter has settings worth a dialog.
    fn has_parameters(self) -> bool;
    /// True when the filter only makes sense with a selection.
    fn needs_selection(self) -> bool;
    /// True when the filter rewrites the layer's own pixels.
    fn is_destructive(self) -> bool;
    /// True when the menu offers it as a command rather than a disabled entry.
    fn is_available(self) -> bool {
        !matches!(self.backend(), FilterBackend::Unsupported(_))
    }
}

impl FilterMenu for FilterKind {
    fn name(self) -> &'static str {
        self.as_str()
    }

    fn backend(self) -> FilterBackend {
        use FilterKind::*;
        match self {
            Curves => FilterBackend::AdjustmentLayer(AdjustmentKind::Curves),
            Exposure => FilterBackend::AdjustmentLayer(AdjustmentKind::Exposure),
            GradientMap => FilterBackend::AdjustmentLayer(AdjustmentKind::GradientMap),
            Grain => FilterBackend::AdjustmentLayer(AdjustmentKind::Grain),
            BlackWhite => FilterBackend::AdjustmentLayer(AdjustmentKind::BlackWhite),
            ColorBalance => FilterBackend::AdjustmentLayer(AdjustmentKind::ColorBalance),
            CameraRaw => FilterBackend::CameraRaw,
            ContentAwareFill => FilterBackend::ContentAwareFill,
            // comp-brush has both extractors now (the U-2-Netp model through tract, or the classical
            // one), so this is no longer waiting for anything: the window runs it so that which one
            // answered can be reported.
            RemoveBackground => FilterBackend::Subject,
            GaussianBlur | MotionBlur | AddNoise | Vignette | BloomGlow | Dither | TonalContrast | LensCorrection => {
                FilterBackend::Pixels
            }
        }
    }

    fn has_parameters(self) -> bool {
        !matches!(self, FilterKind::CameraRaw | FilterKind::ContentAwareFill | FilterKind::RemoveBackground)
    }

    fn needs_selection(self) -> bool {
        self == FilterKind::ContentAwareFill
    }

    fn is_destructive(self) -> bool {
        matches!(self.backend(), FilterBackend::Pixels)
    }
}

/// Runs a filter over a layer's pixels through comp-render.
pub fn run(image: &Bitmap8, kind: FilterKind, settings: &FilterSettings) -> Result<Bitmap8, String> {
    comp_render::apply_filter(image, kind, settings).map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ramp() -> Bitmap8 {
        let mut image = Bitmap8::new(16, 16);
        for y in 0..16 {
            for x in 0..16 {
                let value = if x < 8 { 0 } else { 255 };
                image.set(x, y, [value, value, value, 255]);
            }
        }
        image
    }

    #[test]
    fn the_menu_lists_every_filter_with_a_name() {
        assert_eq!(MENU.len(), 17);
        for kind in MENU {
            assert!(!kind.name().is_empty(), "{kind:?} has no name");
            assert_eq!(kind.name(), kind.as_str(), "the menu and the engine agree on the name");
        }
    }

    #[test]
    fn the_backends_split_the_menu_the_way_macos_does() {
        let mut pixels = 0;
        let mut layers = 0;
        let mut unsupported = 0;
        let mut subject = 0;
        for kind in MENU {
            match kind.backend() {
                FilterBackend::Pixels => pixels += 1,
                FilterBackend::AdjustmentLayer(adjustment) => {
                    layers += 1;
                    assert!(kind.is_destructive() == false);
                    let _ = adjustment;
                }
                FilterBackend::Subject => {
                    subject += 1;
                    assert_eq!(kind, FilterKind::RemoveBackground, "only the subject filter runs here");
                }
                FilterBackend::CameraRaw | FilterBackend::ContentAwareFill => {}
                FilterBackend::Unsupported(reason) => {
                    unsupported += 1;
                    assert!(!reason.is_empty());
                }
            }
        }
        assert_eq!(pixels, 8, "the eight filters the engine runs on pixels");
        assert_eq!(layers, 6, "the six that are really adjustment layers");
        assert_eq!(subject, 1, "remove background runs the subject extractors");
        // Nothing waits on a missing piece any more: comp-brush has both extractors.
        assert_eq!(unsupported, 0, "no filter is waiting for something this build does not have");

        assert!(FilterKind::GaussianBlur.is_destructive());
        assert!(!FilterKind::Curves.is_destructive());
        assert!(FilterKind::ContentAwareFill.needs_selection());
        assert!(!FilterKind::ContentAwareFill.is_available() == false);
        assert!(!FilterKind::GaussianBlur.needs_selection());
        assert!(FilterKind::GaussianBlur.has_parameters());
        assert!(!FilterKind::CameraRaw.has_parameters());
    }

    #[test]
    fn the_dialog_ranges_match_what_the_engine_clamps_to() {
        // A wild value must come back inside the range the dialog offers, or the slider would lie.
        let wild = FilterSettings {
            radius: 10_000.0,
            angle: -400.0,
            distance: 0.0,
            amount: 10_000.0,
            ..Default::default()
        }
        .normalized();
        assert!((RADIUS_RANGE.0..=RADIUS_RANGE.1).contains(&wild.radius), "{}", wild.radius);
        assert!((ANGLE_RANGE.0..=ANGLE_RANGE.1).contains(&wild.angle), "{}", wild.angle);
        assert!((DISTANCE_RANGE.0..=DISTANCE_RANGE.1).contains(&wild.distance), "{}", wild.distance);
        assert!((AMOUNT_RANGE.0..=AMOUNT_RANGE.1).contains(&wild.amount), "{}", wild.amount);
        assert_eq!(wild.radius, RADIUS_RANGE.1);
        assert_eq!(wild.angle, ANGLE_RANGE.0);
    }

    #[test]
    fn a_blur_at_the_smallest_radius_leaves_the_pixels_alone() {
        let pixels = ramp();
        let settings = FilterSettings { radius: 0.0, ..Default::default() };
        let filtered = run(&pixels, FilterKind::GaussianBlur, &settings).expect("a blur runs");
        assert_eq!(filtered.pixels(), pixels.pixels());
    }

    #[test]
    fn a_blur_softens_the_edge_it_is_asked_to() {
        let pixels = ramp();
        let settings = FilterSettings { radius: 4.0, ..Default::default() };
        let filtered = run(&pixels, FilterKind::GaussianBlur, &settings).expect("a blur runs");
        assert_ne!(filtered.pixels(), pixels.pixels(), "the hard edge must soften");
        assert!(
            filtered.get(7, 8)[0] > 0 && filtered.get(7, 8)[0] < 255,
            "the pixel beside the edge takes some of both sides: {}",
            filtered.get(7, 8)[0]
        );
    }

    #[test]
    fn the_filters_that_live_elsewhere_say_so_instead_of_returning_a_wrong_picture() {
        let pixels = ramp();
        let settings = FilterSettings::default();
        let message = run(&pixels, FilterKind::CameraRaw, &settings).unwrap_err();
        assert!(message.contains("not available"), "{message}");
        assert!(run(&pixels, FilterKind::ContentAwareFill, &settings).is_err());
        assert!(run(&pixels, FilterKind::RemoveBackground, &settings).is_err());
    }

    #[test]
    fn every_filter_the_menu_offers_really_runs() {
        let pixels = ramp();
        let settings = FilterSettings::default();
        for kind in MENU {
            if !kind.is_destructive() {
                continue;
            }
            let outcome = run(&pixels, kind, &settings);
            assert!(outcome.is_ok(), "{} could not run: {:?}", kind.name(), outcome.err());
            let filtered = outcome.unwrap();
            assert_eq!((filtered.width(), filtered.height()), (pixels.width(), pixels.height()));
        }
    }

    #[test]
    fn an_empty_layer_survives_every_filter() {
        let empty = Bitmap8::new(0, 0);
        let settings = FilterSettings::default();
        for kind in MENU {
            if !kind.is_destructive() {
                continue;
            }
            let filtered = run(&empty, kind, &settings).expect("an empty image is not an error");
            assert!(filtered.is_empty());
        }
    }
}
