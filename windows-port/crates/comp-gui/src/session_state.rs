//! What the window remembers between runs, and what restoring it has to decide.
//!
//! The saved record itself is small: which packages were open, which tab was in front, the
//! compositor preference, and the view switches. Deciding what to do with a record whose packages
//! have moved or been deleted is the part worth testing, so it lives here rather than in the window.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// The saved window state.
///
/// The defaults are the first-run settings rather than the zeroes Rust would pick, because a record
/// written by an older build arrives without the newer fields and has to fill them sensibly.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct SessionState {
    /// The packages that were open, in tab order; None for a document that was never saved.
    pub tabs: Vec<Option<PathBuf>>,
    /// Which tab was in front.
    pub active: usize,
    /// True when whole-canvas renders preferred the GPU.
    pub prefer_gpu: bool,
    pub show_rulers: bool,
    pub show_guides: bool,
    pub grid_visible: bool,
    pub grid_spacing: u32,
    pub grid_subdivisions: u32,
    pub snap_enabled: bool,
    pub snap_guides: bool,
    pub snap_grid: bool,
    pub snap_document: bool,
    pub snap_layers: bool,
    pub mask_red_overlay: bool,
}

impl Default for SessionState {
    fn default() -> Self {
        SessionState {
            tabs: Vec::new(),
            active: 0,
            prefer_gpu: true,
            show_rulers: true,
            show_guides: true,
            grid_visible: false,
            grid_spacing: crate::guides::GridSettings::default().spacing,
            grid_subdivisions: crate::guides::GridSettings::default().subdivisions,
            snap_enabled: true,
            snap_guides: true,
            snap_grid: true,
            snap_document: true,
            snap_layers: true,
            mask_red_overlay: true,
        }
    }
}

impl SessionState {
    /// The defaults a first run starts from, matching the app's own.
    pub fn first_run() -> Self {
        SessionState::default()
    }
}

/// What the window opens at startup.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RestorePlan {
    /// The packages to open, in tab order.
    pub open: Vec<PathBuf>,
    /// Which of them to bring forward.
    pub active: usize,
    /// Packages that were open last time and are not there any more.
    pub missing: Vec<PathBuf>,
}

/// Works out what to open, and says which packages have gone.
///
/// A package that has been deleted or moved is reported rather than opened, and the tab that comes
/// forward is the saved one unless it was among them: a missing file must not stop the window.
pub fn plan_restore(state: &SessionState) -> RestorePlan {
    let mut open = Vec::new();
    let mut missing = Vec::new();
    let mut active = 0usize;
    let mut kept_before_active = 0usize;
    for (index, tab) in state.tabs.iter().enumerate() {
        let Some(path) = tab else { continue };
        if path.exists() {
            if index < state.active {
                kept_before_active += 1;
            }
            if index == state.active {
                active = open.len();
            }
            open.push(path.clone());
        } else {
            missing.push(path.clone());
        }
    }
    // The saved tab is gone, so the one that took its place comes forward instead.
    if open.is_empty() {
        active = 0;
    } else if active == 0 && kept_before_active > 0 {
        active = kept_before_active.min(open.len() - 1);
    } else if active == 0 && state.active >= state.tabs.len() {
        active = 0;
    }
    RestorePlan { open, active, missing }
}

/// The message a restore reports: what it opened, and what it could not find.
pub fn restore_message(plan: &RestorePlan) -> Option<String> {
    match (plan.open.len(), plan.missing.len()) {
        (0, 0) => None,
        (opened, 0) => Some(format!("Restored {opened} open project(s)")),
        (0, missing) => Some(format!("{missing} project(s) from last time are gone")),
        (opened, missing) => Some(format!("Restored {opened} project(s); {missing} are gone")),
    }
}

/// The path to remember, or None for a document that was never saved.
///
/// The path is made absolute first: the window may be started from another directory next time, and
/// a package opened from a relative path on the command line would otherwise come back missing.
pub fn remember(path: Option<&Path>) -> Option<PathBuf> {
    let path = path?;
    Some(std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state(tabs: Vec<Option<PathBuf>>, active: usize) -> SessionState {
        SessionState { tabs, active, ..SessionState::first_run() }
    }

    /// A path that exists: the test binary's own file, which is always there.
    fn existing() -> PathBuf {
        std::env::current_exe().expect("the test binary has a path")
    }

    /// A path that cannot exist.
    fn gone() -> PathBuf {
        PathBuf::from("Z:/definitely/not/here/Gone.comp")
    }

    #[test]
    fn a_session_with_no_tabs_restores_nothing() {
        let plan = plan_restore(&SessionState::first_run());
        assert_eq!(plan.open, Vec::<PathBuf>::new());
        assert_eq!(plan.active, 0);
        assert!(plan.missing.is_empty());
        assert_eq!(restore_message(&plan), None, "a first run says nothing about restoring");
    }

    #[test]
    fn the_packages_that_are_still_there_come_back_in_order() {
        let state = state(vec![Some(existing()), None, Some(existing())], 2);
        let plan = plan_restore(&state);
        assert_eq!(plan.open.len(), 2, "the unsaved tab has no path to restore");
        assert_eq!(plan.active, 1, "the tab that was in front is found again");
        assert!(plan.missing.is_empty());
        assert_eq!(restore_message(&plan), Some("Restored 2 open project(s)".to_string()));
    }

    #[test]
    fn a_package_that_has_gone_is_reported_and_does_not_stop_the_rest() {
        let state = state(vec![Some(gone()), Some(existing()), Some(gone())], 0);
        let plan = plan_restore(&state);
        assert_eq!(plan.open.len(), 1);
        assert_eq!(plan.missing.len(), 2);
        assert_eq!(plan.active, 0);
        assert_eq!(
            restore_message(&plan),
            Some("Restored 1 project(s); 2 are gone".to_string())
        );
    }

    #[test]
    fn the_front_tab_moving_up_keeps_a_sensible_one_in_front() {
        // Two tabs before the active one are gone, so the active tab is the third that survives.
        let state = state(vec![Some(gone()), Some(gone()), Some(existing()), Some(existing())], 3);
        let plan = plan_restore(&state);
        assert_eq!(plan.open.len(), 2);
        assert_eq!(plan.active, 1, "the saved tab is the second survivor");
        assert_eq!(plan.missing.len(), 2);
    }

    #[test]
    fn a_session_whose_packages_all_went_reports_them() {
        let state = state(vec![Some(gone()), Some(gone())], 1);
        let plan = plan_restore(&state);
        assert!(plan.open.is_empty());
        assert_eq!(plan.active, 0);
        assert_eq!(restore_message(&plan), Some("2 project(s) from last time are gone".to_string()));
    }

    #[test]
    fn an_unsaved_document_is_not_remembered() {
        assert_eq!(remember(None), None);
        // A path that cannot be resolved is kept as it is, so a package on a detached drive is not
        // silently forgotten.
        assert_eq!(remember(Some(Path::new("Z:/gone/Doc.comp"))), Some(PathBuf::from("Z:/gone/Doc.comp")));
    }

    #[test]
    fn a_remembered_path_is_absolute() {
        // A package opened from a relative path still comes back next run.
        let relative = Path::new("compositor_win/Cargo.toml");
        if relative.exists() {
            let remembered = remember(Some(relative)).expect("a path");
            assert!(remembered.is_absolute(), "{remembered:?} should have been made absolute");
            assert!(remembered.exists());
        }
        // The test binary's own path is always there and always absolute.
        let existing = existing();
        assert!(remember(Some(&existing)).expect("a path").is_absolute());
    }

    #[test]
    fn the_saved_record_round_trips_through_json() {
        let state = state(vec![Some(PathBuf::from("C:/work/One.comp"))], 0);
        let text = serde_json::to_string(&state).expect("a session serializes");
        let back: SessionState = serde_json::from_str(&text).expect("and parses again");
        assert_eq!(back, state);
        // A record from an older build, missing the newer fields, still loads with the defaults.
        let partial: SessionState = serde_json::from_str("{\"tabs\":[],\"active\":0}").expect("a partial record loads");
        assert!(partial.prefer_gpu);
        assert!(partial.snap_guides);
    }
}
