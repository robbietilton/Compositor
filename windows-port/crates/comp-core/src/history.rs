//! Snapshot undo, following the macOS `DocumentHistory`: value snapshots that share pixels.
//!
//! Two ceilings apply: a step count and the memory the history holds on its own. Pixel buffers are
//! shared with the live document through `Arc`, so a snapshot costs its metadata plus any buffer
//! that only that snapshot still holds.
use uuid::Uuid;

use crate::document::Document;

/// Steps kept before the oldest is dropped.
pub const HISTORY_LIMIT: usize = 100;
/// Bytes the history may hold beyond the live document.
pub const HISTORY_BYTE_LIMIT: usize = 256 * 1024 * 1024;

/// One undoable state.
#[derive(Clone, Debug)]
pub struct Snapshot {
    pub document: Document,
    /// What the edit was, for menu labels.
    pub label: String,
    /// The document revision this snapshot belongs to, so a save can mark it clean.
    pub revision: Uuid,
}

impl Snapshot {
    pub fn new(document: Document, label: impl Into<String>) -> Self {
        Snapshot { document, label: label.into(), revision: Uuid::new_v4() }
    }

    /// Bytes this snapshot's metadata adds, ignoring shared pixel buffers.
    pub fn metadata_bytes(&self) -> usize {
        let mut bytes = std::mem::size_of::<Document>();
        for layer in &self.document.layers {
            bytes += std::mem::size_of_val(layer);
            bytes += layer.name.len();
        }
        bytes
    }

    /// Total pixel bytes this snapshot references, counting each buffer once.
    pub fn pixel_bytes(&self) -> usize {
        let mut pointers: Vec<*const u8> = Vec::new();
        let mut bytes = 0usize;
        for layer in &self.document.layers {
            if let Some(image) = &layer.image {
                let pointer = image.pixels().as_ptr();
                if !pointers.contains(&pointer) {
                    pointers.push(pointer);
                    bytes += image.byte_len();
                }
            }
            if let Some(mask) = &layer.mask {
                let pointer = mask.pixels().as_ptr();
                if !pointers.contains(&pointer) {
                    pointers.push(pointer);
                    bytes += mask.byte_len();
                }
            }
        }
        bytes
    }
}

/// The undo and redo stacks.
#[derive(Debug)]
pub struct History {
    past: Vec<Snapshot>,
    future: Vec<Snapshot>,
    /// The revision the caller last saved, if any.
    saved_revision: Option<Uuid>,
    current_revision: Uuid,
    step_limit: usize,
    byte_limit: usize,
}

impl Default for History {
    fn default() -> Self {
        History::new(HISTORY_LIMIT, HISTORY_BYTE_LIMIT)
    }
}

impl History {
    pub fn new(step_limit: usize, byte_limit: usize) -> Self {
        History {
            past: Vec::new(),
            future: Vec::new(),
            saved_revision: None,
            current_revision: Uuid::new_v4(),
            step_limit,
            byte_limit,
        }
    }

    pub fn current_revision(&self) -> Uuid {
        self.current_revision
    }

    pub fn can_undo(&self) -> bool {
        !self.past.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.future.is_empty()
    }

    pub fn undo_label(&self) -> Option<&str> {
        self.past.last().map(|snapshot| snapshot.label.as_str())
    }

    pub fn redo_label(&self) -> Option<&str> {
        self.future.last().map(|snapshot| snapshot.label.as_str())
    }

    pub fn depth(&self) -> (usize, usize) {
        (self.past.len(), self.future.len())
    }

    /// Records an edit. The caller passes the state *before* the edit.
    ///
    /// The snapshot keeps the current revision, so undoing back to a save point reports a clean
    /// document again — the reason the app can track a save through later edits.
    pub fn record(&mut self, previous: Document, label: impl Into<String>) -> Uuid {
        let mut snapshot = Snapshot::new(previous, label);
        snapshot.revision = self.current_revision;
        self.past.push(snapshot);
        self.future.clear();
        self.current_revision = Uuid::new_v4();
        self.trim();
        self.current_revision
    }

    /// Steps back, returning the document to restore.
    pub fn undo(&mut self, current: &Document) -> Option<Document> {
        let snapshot = self.past.pop()?;
        self.future.push(Snapshot {
            document: current.clone(),
            label: snapshot.label.clone(),
            revision: self.current_revision,
        });
        self.current_revision = snapshot.revision;
        Some(snapshot.document)
    }

    /// Steps forward, returning the document to restore.
    pub fn redo(&mut self, current: &Document) -> Option<Document> {
        let snapshot = self.future.pop()?;
        self.past.push(Snapshot {
            document: current.clone(),
            label: snapshot.label.clone(),
            revision: self.current_revision,
        });
        self.current_revision = snapshot.revision;
        Some(snapshot.document)
    }

    /// Marks this moment as saved, so `is_modified` can report a clean document.
    pub fn mark_saved(&mut self) {
        self.saved_revision = Some(self.current_revision);
    }

    /// True when edits happened since the last save.
    pub fn is_modified(&self) -> bool {
        self.saved_revision != Some(self.current_revision)
    }

    /// Drops the oldest steps until both ceilings hold.
    fn trim(&mut self) {
        while self.past.len() > self.step_limit {
            self.past.remove(0);
        }
        while self.past.len() > 1 && self.history_bytes() > self.byte_limit {
            self.past.remove(0);
        }
    }

    /// Approximate bytes the past stack holds: metadata plus buffers no live document shares.
    pub fn history_bytes(&self) -> usize {
        let mut total = 0usize;
        let mut newest_pointers: Vec<*const u8> = Vec::new();
        if let Some(newest) = self.past.last() {
            for layer in &newest.document.layers {
                if let Some(image) = &layer.image {
                    newest_pointers.push(image.pixels().as_ptr());
                }
                if let Some(mask) = &layer.mask {
                    newest_pointers.push(mask.pixels().as_ptr());
                }
            }
        }
        for snapshot in &self.past {
            total += snapshot.metadata_bytes();
            for layer in &snapshot.document.layers {
                if let Some(image) = &layer.image {
                    if !newest_pointers.contains(&image.pixels().as_ptr()) {
                        total += image.byte_len();
                    }
                }
                if let Some(mask) = &layer.mask {
                    if !newest_pointers.contains(&mask.pixels().as_ptr()) {
                        total += mask.byte_len();
                    }
                }
            }
        }
        total
    }

    /// Forgets everything, as reopening a file does.
    pub fn clear(&mut self) {
        self.past.clear();
        self.future.clear();
        self.saved_revision = None;
        self.current_revision = Uuid::new_v4();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bitmap::Bitmap8;
    use crate::layer::Layer;
    use std::sync::Arc;

    fn document_with(pixel: u8) -> Document {
        let mut document = Document::new(4, 4);
        let mut layer = Layer::raster("L", 4, 4);
        layer.image = Some(Arc::new(Bitmap8::filled(4, 4, [pixel, 0, 0, 255])));
        document.add_layer(layer, None);
        document
    }

    #[test]
    fn undo_and_redo_walk_the_stack() {
        let mut history = History::default();
        let first = document_with(1);
        let second = document_with(2);
        history.record(first.clone(), "Paint");
        assert!(history.can_undo());
        assert!(!history.can_redo());
        let restored = history.undo(&second).unwrap();
        assert_eq!(restored.layers[0].image.as_ref().unwrap().get(0, 0)[0], 1);
        assert!(history.can_redo());
        let forward = history.redo(&restored).unwrap();
        assert_eq!(forward.layers[0].image.as_ref().unwrap().get(0, 0)[0], 2);
    }

    #[test]
    fn recording_clears_redo() {
        let mut history = History::default();
        let first = document_with(1);
        let second = document_with(2);
        history.record(first.clone(), "Paint");
        let restored = history.undo(&second).unwrap();
        history.record(restored, "Paint again");
        assert!(!history.can_redo());
    }

    #[test]
    fn step_limit_drops_the_oldest() {
        let mut history = History::new(3, usize::MAX);
        for index in 0..10u8 {
            history.record(document_with(index), "Paint");
        }
        assert_eq!(history.depth().0, 3);
    }

    #[test]
    fn undoing_back_to_the_save_point_reports_a_clean_document() {
        let mut history = History::default();
        let saved = document_with(1);
        history.mark_saved();
        assert!(!history.is_modified());
        let edited = document_with(2);
        history.record(saved.clone(), "Paint");
        assert!(history.is_modified());
        let restored = history.undo(&edited).unwrap();
        assert!(!history.is_modified(), "undoing to the saved state must be clean");
        let forward = history.redo(&restored).unwrap();
        assert!(history.is_modified(), "redoing past the save point must be dirty");
        let _ = forward;
    }

    #[test]
    fn save_tracking_uses_revisions() {
        let mut history = History::default();
        history.record(document_with(1), "Paint");
        assert!(history.is_modified());
        history.mark_saved();
        assert!(!history.is_modified());
        history.record(document_with(2), "Paint");
        assert!(history.is_modified());
    }

    #[test]
    fn sharing_buffers_keeps_the_history_cheap() {
        let mut history = History::default();
        let shared = Arc::new(Bitmap8::filled(64, 64, [1, 2, 3, 255]));
        let mut first = Document::new(64, 64);
        let mut layer = Layer::raster("L", 64, 64);
        layer.image = Some(shared.clone());
        first.add_layer(layer, None);
        let second = first.clone();
        history.record(first.clone(), "Edit");
        // The buffer is shared, so only metadata is charged.
        assert!(history.history_bytes() < 64 * 64 * 4);
        let _ = second;
    }
}
