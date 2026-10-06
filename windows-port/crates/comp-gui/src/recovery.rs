//! Autosave and crash recovery: when a copy is written, what is thrown away, and what to offer.
//!
//! The decisions live here as functions of a clock and a few flags, so they can be tested without a
//! file system or a window: the canvas only asks whether to write, and the IO worker does the writing.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

/// How long a document can hold unsaved changes before a copy is written.
pub const AUTOSAVE_INTERVAL: Duration = Duration::from_secs(30);
/// How long the document has to be still before a copy is written.
///
/// The interval says how often a copy may be taken; this says when it is worth taking. Waiting for a
/// pause costs nothing and avoids writing a copy in the middle of a burst of strokes.
pub const IDLE_AFTER: Duration = Duration::from_secs(2);
/// How many intervals may pass while someone keeps working before a copy is taken anyway, so a long
/// session of continuous typing is never left unprotected.
pub const FORCED_AFTER_INTERVALS: u32 = 4;

/// How old a copy can be before it is not worth offering.
pub const ENTRY_MAX_AGE: Duration = Duration::from_secs(7 * 24 * 60 * 60);
/// The folder under the data directory where the copies live.
pub const RECOVERY_DIR: &str = "recovery";

/// What to do about writing a recovery copy right now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Autosave {
    /// Write one now.
    Write,
    /// Not yet; ask again next frame.
    Wait,
    /// Nothing to write, and nothing will change that on its own.
    Skip(Skip),
}

/// Why there is nothing to write.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Skip {
    /// The document has not changed since the last copy.
    NotModified,
    /// The document has nothing in it worth recovering.
    Empty,
    /// Autosave is switched off.
    Disabled,
    /// The document was saved; the copy has been cleaned up and a new one is not due yet.
    Saved,
}

/// The autosave clock: when the last copy was written, and how many there have been.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AutosaveClock {
    pub last_write: Option<Instant>,
    pub writes: u64,
    /// When the document last changed, which is what the idle condition is measured from.
    pub last_edit: Option<Instant>,
}

impl AutosaveClock {
    /// Decides whether this instant should write a copy.
    ///
    /// A copy is written when the interval has gone by, the document has changed since the last copy,
    /// it has something in it, autosave is on, nothing else is already writing the document, and the
    /// document has been still for a moment. A busy worker means Wait rather than Skip: the moment it
    /// is free, the copy is due. Someone who never pauses still gets a copy once four intervals have
    /// gone by, which is the ceiling on how much work an unlucky crash can cost.
    pub fn decide(&self, now: Instant, modified: bool, has_content: bool, busy: bool, enabled: bool) -> Autosave {
        if !enabled {
            return Autosave::Skip(Skip::Disabled);
        }
        if !has_content {
            return Autosave::Skip(Skip::Empty);
        }
        if !modified {
            return Autosave::Skip(Skip::NotModified);
        }
        let since_write = match self.last_write {
            Some(last) => now.duration_since(last),
            None => Duration::MAX,
        };
        if since_write < AUTOSAVE_INTERVAL {
            return Autosave::Wait;
        }
        if busy {
            return Autosave::Wait;
        }
        // Still enough to be worth writing, or working so long that a copy is overdue.
        let still = match self.last_edit {
            Some(edit) => now.duration_since(edit),
            None => Duration::MAX,
        };
        if still >= IDLE_AFTER || since_write >= AUTOSAVE_INTERVAL * FORCED_AFTER_INTERVALS {
            Autosave::Write
        } else {
            Autosave::Wait
        }
    }

    /// Records that the document changed, which is what the idle condition counts from.
    pub fn edited(&mut self, now: Instant) {
        self.last_edit = Some(now);
    }

    /// Records that a copy was written.
    pub fn wrote(&mut self, now: Instant) {
        self.last_write = Some(now);
        self.writes += 1;
    }

    /// Records that the document was saved: the copy has been cleaned and the interval starts over.
    pub fn saved(&mut self) {
        self.last_write = None;
        self.last_edit = None;
    }

    /// How long the current changes have been waiting, when a copy is due or overdue.
    pub fn waited(&self, now: Instant) -> Option<Duration> {
        self.last_write.map(|last| now.duration_since(last))
    }
}

/// What is known about one recovery copy on disk.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecoveryEntry {
    /// The document's own id, which is also the folder the copy lives in.
    pub id: String,
    /// The package the copy came from, when the document had a path.
    pub original: Option<PathBuf>,
    /// When the copy was written.
    pub written: SystemTime,
    /// How big the copy is, for the prompt to say something about it.
    pub bytes: u64,
}

/// How a recovery copy stands against the file it came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Conflict {
    /// There is no original any more, so the copy is all there is.
    OriginalMissing,
    /// The file on disk is newer than the copy, so the copy is probably stale.
    OriginalNewer,
    /// The copy is newer than the file, which is the usual crash case.
    CopyNewer,
    /// Both were written at the same time, so there is nothing to choose between them.
    Same,
}

/// Compares the original's timestamp with the copy's.
pub fn conflict(original: Option<SystemTime>, copy: SystemTime) -> Conflict {
    match original {
        None => Conflict::OriginalMissing,
        Some(original) => match original.duration_since(copy) {
            Ok(gap) if gap.as_secs() > 2 => Conflict::OriginalNewer,
            Ok(_) => Conflict::Same,
            Err(_) => Conflict::CopyNewer,
        },
    }
}

/// What to do with a copy found at startup.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EntryAction {
    /// Offer it to the user.
    Offer,
    /// Throw it away: it is too old to be the work that was lost.
    Discard,
}

/// Decides what to do with one copy.
pub fn entry_action(entry: &RecoveryEntry, now: SystemTime) -> EntryAction {
    match now.duration_since(entry.written) {
        Ok(age) if age > ENTRY_MAX_AGE => EntryAction::Discard,
        // A copy with a timestamp in the future is the clock's problem, not the user's: offer it.
        _ => EntryAction::Offer,
    }
}

/// The copies worth offering, and the ones to throw away.
pub fn split_entries(entries: &[RecoveryEntry], now: SystemTime) -> (Vec<RecoveryEntry>, Vec<RecoveryEntry>) {
    let mut offer = Vec::new();
    let mut discard = Vec::new();
    for entry in entries {
        match entry_action(entry, now) {
            EntryAction::Offer => offer.push(entry.clone()),
            EntryAction::Discard => discard.push(entry.clone()),
        }
    }
    (offer, discard)
}

/// True when a copy can be cleaned: the document was saved to the file the copy belongs to, or the
/// editor is closing with nothing left to lose.
pub fn should_clean(entry: &RecoveryEntry, saved: Option<&Path>, clean_exit: bool) -> bool {
    if clean_exit {
        return true;
    }
    match (entry.original.as_deref(), saved) {
        (Some(original), Some(saved)) => original == saved,
        // A document that never had a path is only clean once it has been saved somewhere.
        (None, Some(_)) => true,
        _ => false,
    }
}

/// The line a prompt shows for one copy.
pub fn entry_label(entry: &RecoveryEntry) -> String {
    let name = entry
        .original
        .as_deref()
        .and_then(Path::file_name)
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_else(|| "An unsaved document".to_string());
    format!("{name} ({} KB)", entry.bytes / 1024)
}

/// The sentence the prompt shows for a copy, including what the original looks like now.
pub fn entry_note(conflict: Conflict) -> &'static str {
    match conflict {
        Conflict::OriginalMissing => "The project it came from is no longer there, so this copy is all that is left.",
        Conflict::OriginalNewer => "The file on disk is newer than this copy, so this copy may be out of date.",
        Conflict::CopyNewer => "This copy has changes the file on disk does not.",
        Conflict::Same => "The file on disk and this copy were written at the same time.",
    }
}

/// The folder the copies live in, under a data directory.
pub fn recovery_dir(data_dir: &Path) -> PathBuf {
    data_dir.join(RECOVERY_DIR)
}

/// The directory the copies live under on this machine.
pub fn data_dir() -> PathBuf {
    for variable in ["LOCALAPPDATA", "APPDATA", "XDG_DATA_HOME"] {
        if let Ok(value) = std::env::var(variable) {
            if !value.trim().is_empty() {
                return PathBuf::from(value).join("compositor");
            }
        }
    }
    std::env::temp_dir().join("compositor")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(written: SystemTime, original: Option<&str>) -> RecoveryEntry {
        RecoveryEntry {
            id: "6f1d".to_string(),
            original: original.map(PathBuf::from),
            written,
            bytes: 4096,
        }
    }

    #[test]
    fn nothing_is_written_until_the_interval_has_gone_by() {
        let started = Instant::now();
        let clock = AutosaveClock { last_write: Some(started), writes: 1, last_edit: Some(started) };
        assert_eq!(clock.decide(started, true, true, false, true), Autosave::Wait);
        let later = started + AUTOSAVE_INTERVAL + Duration::from_secs(1);
        assert_eq!(clock.decide(later, true, true, false, true), Autosave::Write);
    }

    #[test]
    fn a_copy_waits_for_a_pause_and_is_forced_after_four_intervals() {
        let started = Instant::now();
        let mut clock = AutosaveClock { last_write: Some(started), writes: 1, last_edit: Some(started) };
        let due = started + AUTOSAVE_INTERVAL + Duration::from_millis(1);
        // The interval has gone by, but a stroke landed a moment ago: wait for the pause.
        clock.edited(due - Duration::from_millis(100));
        assert_eq!(clock.decide(due, true, true, false, true), Autosave::Wait);
        // A pause of IDLE_AFTER is enough.
        let after_a_pause = due + IDLE_AFTER;
        assert_eq!(clock.decide(after_a_pause, true, true, false, true), Autosave::Write);
        // Someone who never pauses is still covered once four intervals have gone by.
        clock.edited(after_a_pause);
        let overdue = started + AUTOSAVE_INTERVAL * FORCED_AFTER_INTERVALS;
        clock.edited(overdue - Duration::from_millis(50));
        assert_eq!(
            clock.decide(overdue, true, true, false, true),
            Autosave::Write,
            "four intervals of continuous work is the ceiling"
        );
    }

    #[test]
    fn a_document_that_has_never_been_edited_is_still_enough_to_write() {
        // A document restored from a session with no edit recorded: the idle condition cannot hold it
        // back forever, so "never edited" counts as still.
        let clock = AutosaveClock { last_write: None, writes: 0, last_edit: None };
        assert_eq!(clock.decide(Instant::now(), true, true, false, true), Autosave::Write);
    }

    #[test]
    fn a_document_that_has_not_changed_is_never_written() {
        let clock = AutosaveClock::default();
        let later = Instant::now() + AUTOSAVE_INTERVAL * 2;
        assert_eq!(clock.decide(later, false, true, false, true), Autosave::Skip(Skip::NotModified));
    }

    #[test]
    fn an_empty_document_and_a_switched_off_autosave_are_both_skipped() {
        let clock = AutosaveClock::default();
        assert_eq!(clock.decide(Instant::now(), true, false, false, true), Autosave::Skip(Skip::Empty));
        assert_eq!(clock.decide(Instant::now(), true, true, false, false), Autosave::Skip(Skip::Disabled));
    }

    #[test]
    fn a_busy_worker_means_wait_rather_than_skip() {
        // The copy is due and the document has changed; something else is using the worker, so ask
        // again rather than deciding there is nothing to do.
        let clock = AutosaveClock::default();
        assert_eq!(clock.decide(Instant::now(), true, true, true, true), Autosave::Wait);
        assert_eq!(clock.decide(Instant::now(), true, true, false, true), Autosave::Write);
    }

    #[test]
    fn writing_a_copy_starts_the_interval_again_and_a_save_clears_it() {
        let mut clock = AutosaveClock::default();
        assert_eq!(clock.last_edit, None);
        let started = Instant::now();
        assert_eq!(clock.writes, 0);
        clock.wrote(started);
        assert_eq!(clock.writes, 1);
        assert_eq!(clock.waited(started + Duration::from_secs(5)), Some(Duration::from_secs(5)));
        assert_eq!(clock.decide(started + Duration::from_secs(5), true, true, false, true), Autosave::Wait);

        clock.saved();
        assert_eq!(clock.last_write, None, "a saved document has nothing to recover");
        assert_eq!(clock.decide(started, true, true, false, true), Autosave::Write);
    }

    #[test]
    fn the_conflict_between_a_copy_and_its_original_is_decided_by_time() {
        let copy = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000);
        assert_eq!(conflict(None, copy), Conflict::OriginalMissing);
        assert_eq!(
            conflict(Some(SystemTime::UNIX_EPOCH + Duration::from_secs(2_000)), copy),
            Conflict::OriginalNewer
        );
        assert_eq!(
            conflict(Some(SystemTime::UNIX_EPOCH + Duration::from_secs(500)), copy),
            Conflict::CopyNewer
        );
        assert_eq!(conflict(Some(copy), copy), Conflict::Same);
        assert_eq!(
            conflict(Some(copy + Duration::from_millis(900)), copy),
            Conflict::Same,
            "a second of filesystem clock skew is not a conflict"
        );
    }

    #[test]
    fn a_copy_too_old_to_be_the_lost_work_is_thrown_away() {
        let now = SystemTime::UNIX_EPOCH + Duration::from_secs(10_000_000);
        let fresh = entry(now - Duration::from_secs(3600), Some("C:/w/Doc.comp"));
        assert_eq!(entry_action(&fresh, now), EntryAction::Offer);
        let stale = entry(now - ENTRY_MAX_AGE - Duration::from_secs(60), None);
        assert_eq!(entry_action(&stale, now), EntryAction::Discard);
        // A copy stamped in the future is offered rather than silently dropped.
        let future = entry(now + Duration::from_secs(600), None);
        assert_eq!(entry_action(&future, now), EntryAction::Offer);

        let (offer, discard) = split_entries(&[fresh, stale, future], now);
        assert_eq!(offer.len(), 2);
        assert_eq!(discard.len(), 1);
    }

    #[test]
    fn a_copy_is_cleaned_when_its_own_file_is_saved_or_the_editor_closes_cleanly() {
        let copy = entry(SystemTime::now(), Some("C:/w/Doc.comp"));
        assert!(!should_clean(&copy, None, false), "nothing has been saved yet");
        assert!(!should_clean(&copy, Some(Path::new("C:/w/Other.comp")), false), "another file was saved");
        assert!(should_clean(&copy, Some(Path::new("C:/w/Doc.comp")), false), "its own file was saved");
        assert!(should_clean(&copy, None, true), "a clean exit takes every copy with it");

        let unsaved = entry(SystemTime::now(), None);
        assert!(!should_clean(&unsaved, None, false));
        assert!(should_clean(&unsaved, Some(Path::new("C:/w/New.comp")), false), "it was saved somewhere");
    }

    #[test]
    fn a_prompt_label_names_the_project_and_its_size() {
        let copy = entry(SystemTime::now(), Some("C:/work/Portrait.comp"));
        let label = entry_label(&copy);
        assert!(label.contains("Portrait.comp") && label.contains("KB"), "{label}");
        let unsaved = entry(SystemTime::now(), None);
        assert!(entry_label(&unsaved).contains("unsaved"), "{}", entry_label(&unsaved));
    }

    #[test]
    fn every_conflict_has_a_sentence() {
        for conflict in [Conflict::OriginalMissing, Conflict::OriginalNewer, Conflict::CopyNewer, Conflict::Same] {
            let note = entry_note(conflict);
            assert!(note.ends_with('.'), "{conflict:?} has no sentence: {note}");
            assert!(note.len() > 20);
        }
    }

    #[test]
    fn the_copies_live_under_the_data_directory() {
        let dir = recovery_dir(Path::new("C:/data"));
        assert!(dir.ends_with(RECOVERY_DIR), "{dir:?}");
        assert!(dir.starts_with("C:/data"));
        let real = data_dir();
        assert!(real.join(RECOVERY_DIR).ends_with(RECOVERY_DIR));
    }
}
