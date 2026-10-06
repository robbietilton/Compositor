//! Watching the open package for edits made outside the editor.
//!
//! The state machine lives here so the decisions can be tested without a file system: the worker
//! thread reads the digest, this decides whether that is news. A digest that matches what the editor
//! recorded is silence; a different one is reported once, not on every poll, and stays reported
//! until the user answers.

use std::path::PathBuf;

/// What a poll found.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WatchEvent {
    /// Nothing worth telling the user about.
    Quiet,
    /// The package on disk differs from what the editor recorded.
    Changed,
    /// The package cannot be read any more: deleted, moved, or caught half written.
    Unreadable,
}

/// The digest the editor trusts, and whether it has already spoken about a difference.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct WatchState {
    path: Option<PathBuf>,
    digest: Option<String>,
    reported: bool,
}

impl WatchState {
    /// Starts watching a package from the digest the editor just read or wrote.
    pub fn watch(&mut self, path: PathBuf, digest: Option<String>) {
        self.path = Some(path);
        self.digest = digest;
        self.reported = false;
    }

    /// Stops watching, as closing or starting a new document does.
    pub fn forget(&mut self) {
        self.path = None;
        self.digest = None;
        self.reported = false;
    }

    pub fn is_watching(&self) -> bool {
        self.path.is_some()
    }

    pub fn path(&self) -> Option<&PathBuf> {
        self.path.as_ref()
    }

    /// True while a difference has been reported and not yet answered.
    pub fn pending(&self) -> bool {
        self.reported
    }

    /// Reads one poll result: the digest on disk now, or None when it could not be read.
    pub fn observe(&mut self, current: Option<String>) -> WatchEvent {
        if self.path.is_none() || self.reported {
            return WatchEvent::Quiet;
        }
        match current {
            Some(digest) if Some(&digest) == self.digest.as_ref() => WatchEvent::Quiet,
            // A package with no recorded digest is only interesting once it has one to compare with.
            Some(_) if self.digest.is_none() => WatchEvent::Quiet,
            Some(_) => {
                self.reported = true;
                WatchEvent::Changed
            }
            None => {
                self.reported = true;
                WatchEvent::Unreadable
            }
        }
    }

    /// Answers the prompt by keeping the edits in the editor.
    ///
    /// The recorded digest is dropped so the difference is not raised again on every poll; the user
    /// has already answered this one.
    pub fn resolve_keeping_edits(&mut self) {
        self.digest = None;
        self.reported = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn watching() -> WatchState {
        let mut state = WatchState::default();
        state.watch(PathBuf::from("C:/docs/Doc.comp"), Some("aaa".to_string()));
        state
    }

    #[test]
    fn nothing_is_reported_before_a_package_is_watched() {
        let mut state = WatchState::default();
        assert!(!state.is_watching());
        assert_eq!(state.observe(Some("aaa".to_string())), WatchEvent::Quiet);
        assert_eq!(state.observe(None), WatchEvent::Quiet);
    }

    #[test]
    fn the_same_digest_is_silence() {
        let mut state = watching();
        assert!(state.is_watching());
        assert_eq!(state.observe(Some("aaa".to_string())), WatchEvent::Quiet);
        assert!(!state.pending());
        assert_eq!(state.path().map(|path| path.to_string_lossy().to_string()).as_deref(), Some("C:/docs/Doc.comp"));
    }

    #[test]
    fn a_new_digest_is_reported_once() {
        let mut state = watching();
        assert_eq!(state.observe(Some("bbb".to_string())), WatchEvent::Changed);
        assert!(state.pending());
        assert_eq!(state.observe(Some("bbb".to_string())), WatchEvent::Quiet, "not on every poll");
        assert_eq!(state.observe(Some("ccc".to_string())), WatchEvent::Quiet, "still the same prompt");
    }

    #[test]
    fn an_unreadable_package_is_reported_once() {
        let mut state = watching();
        assert_eq!(state.observe(None), WatchEvent::Unreadable);
        assert!(state.pending());
        assert_eq!(state.observe(None), WatchEvent::Quiet);
        assert_eq!(state.observe(Some("aaa".to_string())), WatchEvent::Quiet, "the prompt is still open");
    }

    #[test]
    fn keeping_edits_closes_the_prompt() {
        let mut state = watching();
        assert_eq!(state.observe(Some("bbb".to_string())), WatchEvent::Changed);
        state.resolve_keeping_edits();
        assert!(state.pending(), "the user has answered, so the prompt is closed");
        assert_eq!(state.observe(Some("bbb".to_string())), WatchEvent::Quiet);
        assert_eq!(state.observe(Some("ccc".to_string())), WatchEvent::Quiet, "one answer covers one change");
    }

    #[test]
    fn reloading_starts_a_fresh_watch() {
        let mut state = watching();
        assert_eq!(state.observe(Some("bbb".to_string())), WatchEvent::Changed);
        state.watch(PathBuf::from("C:/docs/Doc.comp"), Some("bbb".to_string()));
        assert!(!state.pending());
        assert_eq!(state.observe(Some("bbb".to_string())), WatchEvent::Quiet);
        assert_eq!(state.observe(Some("ddd".to_string())), WatchEvent::Changed, "the next change is news again");
    }

    #[test]
    fn forgetting_stops_the_prompt_and_the_watch() {
        let mut state = watching();
        assert_eq!(state.observe(Some("bbb".to_string())), WatchEvent::Changed);
        state.forget();
        assert!(!state.is_watching());
        assert!(!state.pending());
        assert_eq!(state.observe(Some("bbb".to_string())), WatchEvent::Quiet);
    }

    #[test]
    fn a_package_with_no_recorded_digest_is_not_a_change() {
        let mut state = WatchState::default();
        state.watch(PathBuf::from("C:/docs/Doc.comp"), None);
        assert_eq!(state.observe(Some("aaa".to_string())), WatchEvent::Quiet, "there is nothing to compare with");
        assert_eq!(state.observe(Some("bbb".to_string())), WatchEvent::Quiet);
        assert_eq!(state.observe(None), WatchEvent::Unreadable, "but losing it is still news");
    }
}
