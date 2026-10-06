//! The Camera Raw filter's editing state.
//!
//! Every preview develops from the pixels the panel opened with, never from the last preview, so
//! moving a slider back and forth cannot pile the grade up on itself.

use comp_core::bitmap::Bitmap8;
use comp_raw::RawSettings;
use uuid::Uuid;

/// One Camera Raw session on one layer.
pub struct RawEdit {
    pub layer: Uuid,
    /// The layer's pixels when the panel opened.
    source: Bitmap8,
    settings: RawSettings,
}

impl RawEdit {
    pub fn begin(layer: Uuid, source: Bitmap8) -> Self {
        RawEdit { layer, source, settings: RawSettings::default() }
    }

    pub fn settings(&self) -> &RawSettings {
        &self.settings
    }

    pub fn settings_mut(&mut self) -> &mut RawSettings {
        &mut self.settings
    }

    /// The pixels these settings produce from the original ones.
    pub fn preview(&self) -> Bitmap8 {
        comp_raw::develop(&self.source, &self.settings)
    }

    /// The pixels the panel opened with, for a reset.
    pub fn source(&self) -> &Bitmap8 {
        &self.source
    }

    /// True while every slider is back at its default, so a preview would change nothing.
    pub fn is_identity(&self) -> bool {
        self.settings.is_identity()
    }

    /// Puts every setting back to its default.
    pub fn reset(&mut self) {
        self.settings = RawSettings::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn source() -> Bitmap8 {
        let mut image = Bitmap8::new(8, 8);
        for y in 0..8 {
            for x in 0..8 {
                image.set(x, y, [(x * 30) as u8, (y * 30) as u8, 90, 255]);
            }
        }
        image
    }

    #[test]
    fn default_settings_preview_the_original_pixels() {
        let edit = RawEdit::begin(Uuid::nil(), source());
        assert!(edit.is_identity());
        assert_eq!(edit.preview().pixels(), edit.source().pixels());
    }

    #[test]
    fn a_changed_slider_changes_the_preview_and_a_reset_undoes_it() {
        let mut edit = RawEdit::begin(Uuid::nil(), source());
        edit.settings_mut().exposure = 1.5;
        assert!(!edit.is_identity());
        let brightened = edit.preview();
        assert_ne!(brightened.pixels(), edit.source().pixels());
        assert!(brightened.get(4, 4)[0] > edit.source().get(4, 4)[0], "exposure should brighten");

        edit.reset();
        assert!(edit.is_identity());
        assert_eq!(edit.preview().pixels(), edit.source().pixels());
    }

    #[test]
    fn a_second_preview_is_not_developed_on_top_of_the_first() {
        let mut edit = RawEdit::begin(Uuid::nil(), source());
        edit.settings_mut().exposure = 1.0;
        let once = edit.preview();
        let twice = edit.preview();
        assert_eq!(once.pixels(), twice.pixels(), "the source is the only input");
    }
}
