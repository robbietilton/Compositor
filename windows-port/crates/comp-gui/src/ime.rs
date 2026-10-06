//! The input-method composition on the canvas.
//!
//! egui reports an input method through Event::Ime: a preedit string that is still being composed, a
//! commit when the user picks a candidate, and a request to delete the text around the caret. This
//! is the state machine between those events and the text draft, so it can be tested without a
//! window. Only the composition lives here; inserting the committed text is the draft's business.

use std::ops::Range;

/// The characters an input method is composing, which are shown but not yet in the text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Preedit {
    pub text: String,
    /// The range inside the preedit the input method wants its own cursor in, in characters.
    pub active_range: Option<Range<usize>>,
}

/// What a preedit did to the composition.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PreeditOutcome {
    /// A composition started.
    Started,
    /// The candidate list changed.
    Updated,
    /// The input method let go without committing anything.
    Dismissed,
}

/// The pre-edit comp-text should draw, out of what egui reported.
///
/// egui hands over the composing text and, when the platform gave it one, the range of characters
/// the input method is working on. It does not hand over clause segmentation, and the range is in
/// characters rather than the UTF-16 units this editor stores runs in, so the conversion happens
/// here: the active range becomes the active clause, the text on either side of it is underlined,
/// and the caret goes at the end of the active clause — or at the end of the text when the platform
/// said nothing, which is where a composing caret sits anyway.
pub fn preedit_from_ime(text: &str, active_range: Option<Range<usize>>) -> comp_text::Preedit {
    let length = text.encode_utf16().count();
    let Some(range) = active_range.filter(|range| !range.is_empty()) else {
        // No active range: comp-text draws the whole of it as one underlined clause.
        return comp_text::Preedit::plain(text, length);
    };
    let (start, end) = crate::runs::utf16_range(text, range);
    if start >= end || length == 0 {
        return comp_text::Preedit::plain(text, length);
    }
    let mut clauses = Vec::new();
    if start > 0 {
        clauses.push(comp_text::PreeditClause::new(0..start, comp_text::PreeditStyle::UNDERLINED));
    }
    clauses.push(comp_text::PreeditClause::new(start..end, comp_text::PreeditStyle::ACTIVE));
    if end < length {
        clauses.push(comp_text::PreeditClause::new(end..length, comp_text::PreeditStyle::UNDERLINED));
    }
    comp_text::Preedit::new(text, end, clauses)
}

/// The composition of one text draft.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Composition {
    preedit: Option<Preedit>,
}

impl Composition {
    pub fn new() -> Self {
        Composition::default()
    }

    /// True while characters are being composed and are not in the text yet.
    pub fn is_composing(&self) -> bool {
        self.preedit.is_some()
    }

    pub fn preedit(&self) -> Option<&Preedit> {
        self.preedit.as_ref()
    }

    /// The characters being composed, or an empty string.
    pub fn preedit_text(&self) -> &str {
        self.preedit.as_ref().map(|preedit| preedit.text.as_str()).unwrap_or("")
    }

    /// What comp-text should draw for this composition, or None when nothing is composing.
    pub fn to_preedit(&self) -> Option<comp_text::Preedit> {
        let preedit = self.preedit.as_ref()?;
        Some(preedit_from_ime(&preedit.text, preedit.active_range.clone()))
    }

    /// A new candidate string. An empty one dismisses the composition, which is how egui reports an
    /// input method that gave up.
    pub fn set_preedit(&mut self, text: String, active_range: Option<Range<usize>>) -> PreeditOutcome {
        if text.is_empty() {
            let was_composing = self.preedit.is_some();
            self.preedit = None;
            return if was_composing { PreeditOutcome::Dismissed } else { PreeditOutcome::Dismissed };
        }
        let started = self.preedit.is_none();
        self.preedit = Some(Preedit { text, active_range });
        if started {
            PreeditOutcome::Started
        } else {
            PreeditOutcome::Updated
        }
    }

    /// The composition ended with this text: what the caller has to insert, if anything.
    ///
    /// The preedit is dropped either way, so the composed characters are never both shown and
    /// inserted.
    pub fn commit(&mut self, text: String) -> Option<String> {
        self.preedit = None;
        (!text.is_empty()).then_some(text)
    }

    /// Drops the composition without inserting anything. True when there was one.
    pub fn cancel(&mut self) -> bool {
        self.preedit.take().is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_composition_starts_and_updates_with_the_candidates() {
        let mut composition = Composition::new();
        assert!(!composition.is_composing());
        assert_eq!(composition.preedit_text(), "");

        assert_eq!(composition.set_preedit("ni".to_string(), None), PreeditOutcome::Started);
        assert!(composition.is_composing());
        assert_eq!(composition.preedit_text(), "ni");

        assert_eq!(
            composition.set_preedit("nihao".to_string(), Some(2..4)),
            PreeditOutcome::Updated
        );
        let preedit = composition.preedit().expect("a preedit");
        assert_eq!(preedit.text, "nihao");
        assert_eq!(preedit.active_range, Some(2..4), "the input method's own cursor is kept");
    }

    #[test]
    fn an_empty_preedit_dismisses_the_composition() {
        let mut composition = Composition::new();
        composition.set_preedit("zhong".to_string(), None);
        assert_eq!(composition.set_preedit(String::new(), None), PreeditOutcome::Dismissed);
        assert!(!composition.is_composing());
        assert_eq!(composition.preedit_text(), "");
    }

    #[test]
    fn committing_hands_over_the_text_once_and_ends_the_composition() {
        let mut composition = Composition::new();
        composition.set_preedit("ni hao".to_string(), None);
        assert_eq!(composition.commit("你好".to_string()), Some("你好".to_string()));
        assert!(!composition.is_composing(), "the preedit must not stay on screen after a commit");
        assert_eq!(composition.preedit_text(), "");
        // A commit without a composition, as typing a character through an input method does.
        assert_eq!(composition.commit("a".to_string()), Some("a".to_string()));
    }

    #[test]
    fn an_empty_commit_inserts_nothing() {
        let mut composition = Composition::new();
        composition.set_preedit("ni".to_string(), None);
        assert_eq!(composition.commit(String::new()), None, "there is nothing to insert");
        assert!(!composition.is_composing());
    }

    #[test]
    fn cancelling_drops_the_candidates_and_reports_whether_there_were_any() {
        let mut composition = Composition::new();
        assert!(!composition.cancel(), "nothing to cancel");
        composition.set_preedit("hao".to_string(), None);
        assert!(composition.cancel());
        assert!(!composition.is_composing());
        assert_eq!(composition.preedit_text(), "");
    }

    #[test]
    fn an_empty_preedit_has_nothing_to_draw() {
        let preedit = preedit_from_ime("", None);
        assert!(preedit.is_empty());
        assert_eq!(preedit.caret, 0);
        assert!(preedit.effective_clauses().is_empty(), "an empty composition draws no clause");
    }

    #[test]
    fn a_platform_that_reports_no_active_clause_gets_one_underlined_clause() {
        // What egui usually has: the text and nothing else.
        let preedit = preedit_from_ime("nihao", None);
        let clauses = preedit.effective_clauses();
        assert_eq!(clauses.len(), 1);
        assert_eq!(clauses[0].range, 0..5);
        assert!(clauses[0].style.underline);
        assert!(!clauses[0].style.highlight, "nothing is claimed to be active");
        assert_eq!(preedit.caret, 5, "a composing caret sits at the end of what has been typed");
    }

    #[test]
    fn an_active_range_becomes_the_active_clause_with_the_rest_underlined() {
        let preedit = preedit_from_ime("woaini", Some(2..4));
        let clauses = preedit.clauses();
        assert_eq!(clauses.len(), 3);
        assert_eq!(clauses[0].range, 0..2);
        assert!(clauses[0].style.underline && !clauses[0].style.highlight);
        assert_eq!(clauses[1].range, 2..4);
        assert!(clauses[1].style.highlight && clauses[1].style.bold, "the active clause stands out");
        assert_eq!(clauses[2].range, 4..6);
        assert!(clauses[2].style.underline && !clauses[2].style.highlight);
        assert_eq!(preedit.caret, 4, "the caret is at the end of the clause being worked on");
    }

    #[test]
    fn an_active_clause_at_either_end_does_not_invent_empty_clauses() {
        let at_the_start = preedit_from_ime("abc", Some(0..2));
        assert_eq!(at_the_start.clauses().len(), 2, "there is nothing before the clause");
        assert_eq!(at_the_start.clauses()[0].range, 0..2);
        assert_eq!(at_the_start.caret, 2);

        let at_the_end = preedit_from_ime("abc", Some(1..3));
        assert_eq!(at_the_end.clauses().len(), 2, "there is nothing after it");
        assert_eq!(at_the_end.clauses()[1].range, 1..3);
        assert_eq!(at_the_end.caret, 3);
    }

    #[test]
    fn the_active_range_is_counted_in_characters_and_clauses_in_utf16() {
        // The emoji is one character and two UTF-16 units, and egui reports characters.
        let preedit = preedit_from_ime("a😀b", Some(1..2));
        assert_eq!(preedit.caret, 3, "the clause ends after the emoji's two units");
        let clauses = preedit.clauses();
        assert_eq!(clauses[0].range, 0..1);
        assert_eq!(clauses[1].range, 1..3);
        assert_eq!(clauses[2].range, 3..4);
    }

    #[test]
    fn a_range_the_platform_reported_too_long_is_clipped_by_comp_text() {
        let preedit = preedit_from_ime("ab", Some(1..99));
        assert_eq!(preedit.caret, 2);
        for clause in preedit.clauses() {
            assert!(clause.range.end <= 2, "{:?} runs past the text", clause.range);
        }
        // A range that is empty or backwards is treated as no active clause at all.
        let empty = preedit_from_ime("ab", Some(1..1));
        assert_eq!(empty.clauses().len(), 0, "comp-text then draws one underlined clause");
        assert_eq!(empty.effective_clauses().len(), 1);
        let backwards = preedit_from_ime("ab", Some(2..1));
        assert_eq!(backwards.effective_clauses().len(), 1);
    }

    #[test]
    fn the_composition_hands_the_pre_edit_to_comp_text() {
        let mut composition = Composition::new();
        assert!(composition.to_preedit().is_none(), "nothing is composing yet");
        composition.set_preedit("nihao".to_string(), Some(2..4));
        let preedit = composition.to_preedit().expect("a pre-edit");
        assert_eq!(preedit.text, "nihao");
        assert_eq!(preedit.clauses().len(), 3);
        assert_eq!(preedit.caret, 4);
        // Committing takes it away again, so nothing is drawn and nothing is inserted twice.
        assert_eq!(composition.commit("你好".to_string()), Some("你好".to_string()));
        assert!(composition.to_preedit().is_none());
    }

    #[test]
    fn plain_typing_does_not_disturb_a_composition() {
        // Text events and an open composition arrive on the same frame; the composition describes
        // only its own string, so a committed character elsewhere cannot move its clauses.
        let mut composition = Composition::new();
        composition.set_preedit("ni".to_string(), None);
        let before = composition.to_preedit().expect("a pre-edit");
        composition.set_preedit("nihao".to_string(), Some(3..5));
        let after = composition.to_preedit().expect("a pre-edit");
        assert_eq!(before.text, "ni");
        assert_eq!(after.text, "nihao");
        assert_eq!(after.clauses()[1].range, 3..5, "the clause follows the new string, not the old one");
        assert!(composition.is_composing());
    }

    #[test]
    fn a_dismissed_composition_leaves_nothing_behind() {
        // What the caller relies on when the input method is switched off mid-word.
        let mut composition = Composition::new();
        composition.set_preedit("zh".to_string(), None);
        composition.set_preedit(String::new(), None);
        assert_eq!(composition.commit("中".to_string()), Some("中".to_string()), "a commit still works");
        assert!(!composition.is_composing());
    }
}
