//! The system clipboard, behind a trait so the editor's commands can be tested without one.
//!
//! Windows holds clipboard images as straight RGBA, which is what a layer keeps, so the round trip
//! is a copy in and a copy out.

use comp_core::bitmap::Bitmap8;

/// A place pixels can be put and taken from.
pub trait Clipboard {
    /// Puts a layer's pixels on the clipboard.
    fn set_image(&mut self, image: &Bitmap8) -> Result<(), String>;
    /// Takes the clipboard's pixels, or says why there are none.
    fn get_image(&mut self) -> Result<Bitmap8, String>;
}

/// The message every clipboard reports when it holds no picture.
pub const NO_IMAGE: &str = "The clipboard holds no image";

/// The Windows clipboard, through arboard.
pub struct SystemClipboard {
    inner: Option<arboard::Clipboard>,
}

impl SystemClipboard {
    pub fn new() -> Self {
        SystemClipboard { inner: None }
    }

    /// The clipboard handle, opened on first use because opening it can fail when no window is up.
    fn handle(&mut self) -> Result<&mut arboard::Clipboard, String> {
        if self.inner.is_none() {
            self.inner = Some(arboard::Clipboard::new().map_err(|error| error.to_string())?);
        }
        self.inner.as_mut().ok_or_else(|| "the clipboard is unavailable".to_string())
    }
}

impl Default for SystemClipboard {
    fn default() -> Self {
        SystemClipboard::new()
    }
}

impl Clipboard for SystemClipboard {
    fn set_image(&mut self, image: &Bitmap8) -> Result<(), String> {
        if image.is_empty() {
            return Err("There is nothing to copy".to_string());
        }
        let data = arboard::ImageData {
            width: image.width() as usize,
            height: image.height() as usize,
            bytes: std::borrow::Cow::Borrowed(image.pixels()),
        };
        self.handle()?.set_image(data).map_err(|error| error.to_string())
    }

    fn get_image(&mut self) -> Result<Bitmap8, String> {
        let data = self.handle()?.get_image().map_err(|_| NO_IMAGE.to_string())?;
        Bitmap8::from_raw(data.width as u32, data.height as u32, data.bytes.into_owned())
            .map_err(|_| NO_IMAGE.to_string())
    }
}

/// A clipboard in memory, for tests and for a session whose system clipboard is unavailable.
#[derive(Default)]
pub struct MemoryClipboard {
    slot: Option<Bitmap8>,
}

impl MemoryClipboard {
    pub fn new() -> Self {
        MemoryClipboard { slot: None }
    }

    /// True when something is on the clipboard.
    pub fn has_image(&self) -> bool {
        self.slot.is_some()
    }
}

impl Clipboard for MemoryClipboard {
    fn set_image(&mut self, image: &Bitmap8) -> Result<(), String> {
        if image.is_empty() {
            return Err("There is nothing to copy".to_string());
        }
        self.slot = Some(image.clone());
        Ok(())
    }

    fn get_image(&mut self) -> Result<Bitmap8, String> {
        self.slot.clone().ok_or_else(|| NO_IMAGE.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_clipboard_says_so_instead_of_returning_a_blank_image() {
        let mut clipboard = MemoryClipboard::new();
        assert!(!clipboard.has_image());
        let message = clipboard.get_image().unwrap_err();
        assert_eq!(message, NO_IMAGE);
    }

    #[test]
    fn pixels_survive_a_round_trip_through_the_clipboard() {
        let mut clipboard = MemoryClipboard::new();
        let mut image = Bitmap8::new(4, 3);
        image.set(0, 0, [255, 0, 0, 255]);
        image.set(3, 2, [1, 2, 3, 128]);
        clipboard.set_image(&image).expect("a copy");

        let back = clipboard.get_image().expect("a paste");
        assert_eq!(back.width(), 4);
        assert_eq!(back.height(), 3);
        assert_eq!(back.pixels(), image.pixels());
        assert!(clipboard.has_image());
    }

    #[test]
    fn copying_nothing_is_refused() {
        let mut clipboard = MemoryClipboard::new();
        assert!(clipboard.set_image(&Bitmap8::new(0, 0)).is_err());
        assert!(!clipboard.has_image());
        assert!(clipboard.set_image(&Bitmap8::new(4, 0)).is_err());
    }

    #[test]
    fn a_second_copy_replaces_the_first() {
        let mut clipboard = MemoryClipboard::new();
        clipboard.set_image(&Bitmap8::filled(2, 2, [1, 1, 1, 255])).unwrap();
        clipboard.set_image(&Bitmap8::filled(2, 2, [9, 9, 9, 255])).unwrap();
        assert_eq!(clipboard.get_image().unwrap().get(0, 0), [9, 9, 9, 255]);
    }
}
