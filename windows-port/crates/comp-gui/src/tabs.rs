//! Several open packages at once: which one is in front, and what closing one does.
//!
//! The document, its history and its view all live in the project that owns them, so switching tabs
//! is a swap rather than a reload. These are the decisions that swap has to make, kept apart from the
//! window so they can be tested.

use std::path::{Path, PathBuf};

/// What closing a tab has to ask about.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CloseAction {
    /// Nothing was changed, so the tab can just go.
    Close,
    /// The document has unsaved edits, so the user has to choose.
    Ask,
}

/// The tab that takes over after the one at this index goes away.
///
/// The neighbour on the right moves into the gap, which is what every tabbed application does; when
/// the last tab is closed there is no tab left.
pub fn active_after_close(active: usize, closed: usize, remaining: usize) -> Option<usize> {
    if remaining == 0 {
        return None;
    }
    if closed < active {
        return Some(active - 1);
    }
    if closed > active {
        return Some(active);
    }
    Some(closed.min(remaining - 1))
}

/// The tab already showing a package, so opening it again brings it forward instead of loading it
/// twice.
pub fn find_path(paths: &[Option<PathBuf>], path: &Path) -> Option<usize> {
    let wanted = normalize(path);
    paths.iter().position(|candidate| candidate.as_deref().map(normalize).as_deref() == Some(wanted.as_path()))
}

/// A path in the form two tabs would agree on: absolute where it can be, and case-insensitive on
/// Windows, so the same package opened twice is one tab.
fn normalize(path: &Path) -> PathBuf {
    let absolute = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    let text = absolute.to_string_lossy().to_string();
    if cfg!(windows) {
        PathBuf::from(text.to_lowercase())
    } else {
        PathBuf::from(text)
    }
}

/// What closing a tab should do about its unsaved edits.
pub fn close_action(modified: bool) -> CloseAction {
    if modified {
        CloseAction::Ask
    } else {
        CloseAction::Close
    }
}

/// The title a tab shows: the package's file name, or what an unsaved document is called.
pub fn tab_title(path: Option<&Path>, fallback: &str) -> String {
    match path {
        Some(path) => path
            .file_name()
            .map(|name| name.to_string_lossy().to_string())
            .unwrap_or_else(|| path.display().to_string()),
        None => fallback.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn closing_a_tab_hands_over_to_its_neighbour() {
        // Three tabs, the middle one closed: the third takes its place.
        assert_eq!(active_after_close(1, 1, 2), Some(1));
        // The first of three closed while the last is in front: the front tab shifts down with it.
        assert_eq!(active_after_close(2, 0, 2), Some(1));
        // A tab after the front one closes: the front one stays where it is.
        assert_eq!(active_after_close(0, 2, 2), Some(0));
        // Closing the last tab of all.
        assert_eq!(active_after_close(0, 0, 0), None);
        assert_eq!(active_after_close(2, 2, 2), Some(1), "the neighbour on the left takes over");
    }

    #[test]
    fn a_package_that_is_already_open_is_found() {
        let first = PathBuf::from("C:/work/One.comp");
        let second = PathBuf::from("C:/work/Two.comp");
        let paths = vec![Some(first.clone()), None, Some(second.clone())];
        assert_eq!(find_path(&paths, Path::new("C:/work/One.comp")), Some(0));
        assert_eq!(find_path(&paths, Path::new("C:/WORK/one.COMP")), Some(0), "case does not open it twice");
        assert_eq!(find_path(&paths, Path::new("C:/work/Two.comp")), Some(2));
        assert_eq!(find_path(&paths, Path::new("C:/work/Three.comp")), None, "a new package gets a new tab");
        assert_eq!(find_path(&[], Path::new("C:/work/One.comp")), None);
        assert_eq!(find_path(&[None], Path::new("C:/work/One.comp")), None, "an unsaved tab has no path");
    }

    #[test]
    fn only_a_changed_document_asks_before_it_closes() {
        assert_eq!(close_action(false), CloseAction::Close);
        assert_eq!(close_action(true), CloseAction::Ask);
    }

    #[test]
    fn a_tab_is_named_after_its_package() {
        assert_eq!(tab_title(Some(Path::new("C:/work/Portrait.comp")), "Untitled"), "Portrait.comp");
        assert_eq!(tab_title(None, "Untitled"), "Untitled");
    }
}
