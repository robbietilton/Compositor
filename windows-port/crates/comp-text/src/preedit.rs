//! The text an input method is composing, and the geometry a GUI draws it with.
//!
//! While a composition is open the characters are not in the document yet, but they are already on
//! screen: the input method reports its text, where the caret sits and which clause — the run of
//! characters it is currently working on — each part of the text belongs to. This module keeps that
//! report, normalises it, and answers the two questions a GUI has: where is each clause, and where
//! should the candidate window point.
//!
//! The layout the geometry is asked about is the one the caller laid the pre-edit out with — the
//! composing text on its own, in the style the finished text will have — so the space the pre-edit
//! takes is the space it keeps once it is committed, and nothing jumps when it is.

use crate::geometry::{caret_rect, drawn_span, line_index_for, line_top};
use crate::layout::TextLayout;
use comp_core::RectF;

/// How one clause of a pre-edit is drawn. The crate does not draw anything itself: these are the
/// flags a GUI needs to draw the overlay, and the active clause is the one an input method reports
/// as the clause it is working on.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct PreeditStyle {
    /// Underline the characters, as unconfirmed text usually is.
    pub underline: bool,
    /// Draw them heavier.
    pub bold: bool,
    /// Draw them highlighted, which is what the active clause gets.
    pub highlight: bool,
}

impl PreeditStyle {
    /// Nothing but the text itself.
    pub const PLAIN: PreeditStyle = PreeditStyle { underline: false, bold: false, highlight: false };
    /// Underlined and nothing else, the usual look for composing text.
    pub const UNDERLINED: PreeditStyle = PreeditStyle { underline: true, bold: false, highlight: false };
    /// The clause an input method is working on.
    pub const ACTIVE: PreeditStyle = PreeditStyle { underline: true, bold: true, highlight: true };

    pub fn is_plain(self) -> bool {
        self == PreeditStyle::PLAIN
    }
}

/// One clause of a pre-edit: a range of its text, in UTF-16 units, and how it is drawn.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct PreeditClause {
    /// Where the clause starts and ends in the pre-edit's text, in UTF-16 units, the unit every
    /// run offset in this crate uses.
    pub range: std::ops::Range<usize>,
    pub style: PreeditStyle,
}

impl PreeditClause {
    pub fn new(range: std::ops::Range<usize>, style: PreeditStyle) -> PreeditClause {
        PreeditClause { range, style }
    }
}

/// What an input method reports while it is composing.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Preedit {
    /// The composing text itself, which is not in the document yet.
    pub text: String,
    /// Where the caret sits in that text, in UTF-16 units.
    pub caret: usize,
    /// The clauses, sorted and clipped to the text.
    clauses: Vec<PreeditClause>,
}

impl Preedit {
    /// A pre-edit, normalised: the clauses are sorted, clipped to the text, never overlap and never
    /// run past it, and the caret is pulled back inside. An input method is free to report a clause
    /// that runs off the end of a text it is still assembling, and a GUI should not have to care.
    pub fn new(text: impl Into<String>, caret: usize, clauses: Vec<PreeditClause>) -> Preedit {
        let text = text.into();
        let length = text.encode_utf16().count();
        let mut sorted = clauses;
        // A stable sort, so clauses that start together keep the order they were reported in.
        sorted.sort_by_key(|clause| clause.range.start);
        let mut normalized: Vec<PreeditClause> = Vec::with_capacity(sorted.len());
        let mut cursor = 0usize;
        for clause in sorted {
            let start = clause.range.start.min(length).max(cursor);
            let end = clause.range.end.min(length).max(start);
            if end > start {
                normalized.push(PreeditClause { range: start..end, style: clause.style });
                cursor = end;
            }
        }
        Preedit { text, caret: caret.min(length), clauses: normalized }
    }

    /// A pre-edit with no clause reported: the whole of it is one plain clause.
    pub fn plain(text: impl Into<String>, caret: usize) -> Preedit {
        Preedit::new(text, caret, Vec::new())
    }

    /// The clauses, sorted and clipped.
    pub fn clauses(&self) -> &[PreeditClause] {
        &self.clauses
    }

    /// The clauses a caller should draw: the reported ones, or the whole text as one clause when
    /// the input method reported none.
    pub fn effective_clauses(&self) -> Vec<PreeditClause> {
        if !self.clauses.is_empty() {
            return self.clauses.clone();
        }
        let length = self.utf16_len();
        if length == 0 {
            Vec::new()
        } else {
            vec![PreeditClause { range: 0..length, style: PreeditStyle::UNDERLINED }]
        }
    }

    /// The length of the composing text, in UTF-16 units.
    pub fn utf16_len(&self) -> usize {
        self.text.encode_utf16().count()
    }

    /// True when there is nothing to draw.
    pub fn is_empty(&self) -> bool {
        self.utf16_len() == 0
    }
}

/// One clause and a box it occupies. A clause that runs over a line ending has one box per line.
#[derive(Clone, Debug, PartialEq)]
pub struct PreeditClauseRect {
    pub clause: PreeditClause,
    pub rect: RectF,
}

/// The boxes to draw the clauses in, in the layout's coordinates.
///
/// A clause that crosses a line ending has one box per line, which is why this is a list of boxes
/// rather than one per clause: an input method is free to report a clause longer than a line.
pub fn preedit_clause_rects(layout: &TextLayout, preedit: &Preedit) -> Vec<PreeditClauseRect> {
    let mut boxes = Vec::new();
    for clause in preedit.effective_clauses() {
        let range = characters_in(layout, &clause.range);
        if range.is_empty() {
            continue;
        }
        for line in &layout.lines {
            let Some((left, right)) = drawn_span(layout, line, &range) else { continue };
            boxes.push(PreeditClauseRect {
                clause: clause.clone(),
                rect: RectF::new(left, line_top(layout, line), right - left, layout.line_height),
            });
        }
    }
    boxes
}

/// The box around everything the pre-edit draws, or none when it draws nothing.
pub fn preedit_bounds(layout: &TextLayout) -> Option<RectF> {
    let range = 0..layout.chars.len();
    let mut bounds: Option<RectF> = None;
    for line in &layout.lines {
        let Some((left, right)) = drawn_span(layout, line, &range) else { continue };
        let rect = RectF::new(left, line_top(layout, line), right - left, layout.line_height);
        bounds = Some(match bounds {
            Some(existing) => existing.union(rect),
            None => rect,
        });
    }
    bounds
}

/// Which way a candidate window should open from its anchor.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AnchorDirection {
    /// Below the caret, which is what a window with room under it wants.
    Down,
    /// Above the caret, for a caret on the last line of the text.
    Up,
}

/// Where a candidate window should point for a caret at an index.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CaretAnchor {
    /// The caret's own box: one pixel wide and a line tall.
    pub rect: RectF,
    /// A suggestion, not a rule: the caller knows the window and the screen, and places the list.
    pub direction: AnchorDirection,
}

/// The anchor a candidate window should hang off, or none when there is nothing to point at.
///
/// The box is the caret itself. The direction is a hint — down from a caret that has text below it,
/// up from one on the last line — and where the list actually goes, in particular how far from the
/// anchor it sits vertically, is the caller's business.
pub fn candidate_anchor(layout: &TextLayout, caret_index: usize) -> Option<CaretAnchor> {
    let rect = caret_rect(layout, caret_index)?;
    let index = caret_index.min(layout.chars.len());
    let line = line_index_for(layout, index);
    let last = layout.lines.len().saturating_sub(1);
    let direction = if line >= last { AnchorDirection::Up } else { AnchorDirection::Down };
    Some(CaretAnchor { rect, direction })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout::{layout_text, TEXT_PADDING};
    use crate::library::FontLibrary;
    use comp_core::text::TextStyle;

    /// A library with no faces: every character advances by half the font size, so every expected
    /// box is arithmetic and no test depends on which fonts are installed.
    fn bare_library() -> FontLibrary {
        FontLibrary::from_faces(Vec::new(), Vec::new())
    }

    /// The pre-edit text laid out on its own, the way a GUI lays composing text out before it is
    /// committed: characters of five pixels, the first starting at the padding, at x = 12.
    fn laid_out(text: &str) -> (TextLayout, FontLibrary) {
        let mut library = bare_library();
        let style = TextStyle { content: text.to_string(), font_size: 10.0, ..TextStyle::default() };
        let layout = layout_text(&style, &mut library);
        (layout, library)
    }

    fn clause(range: std::ops::Range<usize>, style: PreeditStyle) -> PreeditClause {
        PreeditClause::new(range, style)
    }

    // ---- normalisation --------------------------------------------------

    #[test]
    fn clauses_come_out_sorted() {
        let preedit = Preedit::new(
            "abcdef",
            0,
            vec![clause(4..6, PreeditStyle::ACTIVE), clause(0..2, PreeditStyle::UNDERLINED)],
        );
        let ranges: Vec<std::ops::Range<usize>> = preedit.clauses().iter().map(|c| c.range.clone()).collect();
        assert_eq!(ranges, vec![0..2, 4..6]);
        assert_eq!(preedit.clauses()[0].style, PreeditStyle::UNDERLINED);
    }

    #[test]
    fn overlapping_clauses_are_clipped() {
        let preedit = Preedit::new(
            "abcdef",
            0,
            vec![clause(0..4, PreeditStyle::UNDERLINED), clause(2..6, PreeditStyle::ACTIVE)],
        );
        let ranges: Vec<std::ops::Range<usize>> = preedit.clauses().iter().map(|c| c.range.clone()).collect();
        assert_eq!(ranges, vec![0..4, 4..6], "the second clause starts where the first ended");
    }

    #[test]
    fn a_clause_covered_by_another_is_dropped() {
        let preedit = Preedit::new(
            "abcdef",
            0,
            vec![clause(0..6, PreeditStyle::UNDERLINED), clause(2..4, PreeditStyle::ACTIVE)],
        );
        assert_eq!(preedit.clauses().len(), 1);
        assert_eq!(preedit.clauses()[0].range, 0..6);
    }

    #[test]
    fn clauses_past_the_end_of_the_text_are_clipped() {
        let preedit = Preedit::new("abc", 0, vec![clause(1..99, PreeditStyle::ACTIVE)]);
        assert_eq!(preedit.clauses()[0].range, 1..3);
    }

    #[test]
    fn clause_ranges_are_utf16_units() {
        // An emoji is two units, so a clause after it starts at three.
        let preedit = Preedit::new("a\u{1F600}b", 0, vec![clause(3..4, PreeditStyle::ACTIVE)]);
        assert_eq!(preedit.clauses()[0].range, 3..4);
        assert_eq!(preedit.utf16_len(), 4);
    }

    #[test]
    fn empty_and_backwards_clauses_are_dropped() {
        let preedit = Preedit::new(
            "abcdef",
            0,
            vec![clause(3..3, PreeditStyle::ACTIVE), clause(5..2, PreeditStyle::UNDERLINED)],
        );
        assert!(preedit.clauses().is_empty());
    }

    #[test]
    fn an_empty_text_has_no_clauses() {
        let preedit = Preedit::new("", 4, vec![clause(0..2, PreeditStyle::ACTIVE)]);
        assert!(preedit.clauses().is_empty());
        assert_eq!(preedit.caret, 0);
        assert!(preedit.is_empty());
        assert!(preedit.effective_clauses().is_empty());
    }

    #[test]
    fn the_caret_is_pulled_inside_the_text() {
        let preedit = Preedit::new("abc", 99, vec![]);
        assert_eq!(preedit.caret, 3);
        let preedit = Preedit::new("a\u{1F600}b", 3, vec![]);
        assert_eq!(preedit.caret, 3, "a caret between the halves of an emoji is still a caret");
    }

    #[test]
    fn a_preedit_without_clauses_is_one_plain_clause() {
        let preedit = Preedit::plain("abc", 1);
        let clauses = preedit.effective_clauses();
        assert_eq!(clauses.len(), 1);
        assert_eq!(clauses[0].range, 0..3);
        assert_eq!(clauses[0].style, PreeditStyle::UNDERLINED);
        assert!(PreeditStyle::PLAIN.is_plain());
    }

    // ---- clause geometry ------------------------------------------------

    #[test]
    fn each_clause_gets_its_own_box() {
        let (layout, _library) = laid_out("abcd");
        let preedit = Preedit::new(
            "abcd",
            2,
            vec![clause(0..2, PreeditStyle::ACTIVE), clause(2..4, PreeditStyle::UNDERLINED)],
        );
        let boxes = preedit_clause_rects(&layout, &preedit);
        assert_eq!(boxes.len(), 2);
        assert_eq!(boxes[0].rect.x, TEXT_PADDING);
        assert_eq!(boxes[0].rect.width, 10.0);
        assert_eq!(boxes[0].clause.style, PreeditStyle::ACTIVE);
        assert_eq!(boxes[1].rect.x, TEXT_PADDING + 10.0);
        assert_eq!(boxes[1].rect.width, 10.0);
        assert_eq!(boxes[0].rect.height, layout.line_height);
        assert_eq!(boxes[0].rect.y, line_top(&layout, &layout.lines[0]));
    }

    #[test]
    fn a_clause_that_crosses_a_line_gets_a_box_per_line() {
        let (layout, _library) = laid_out("abcd\nef");
        assert_eq!(layout.lines.len(), 2);
        let preedit = Preedit::new("abcd\nef", 0, vec![clause(2..7, PreeditStyle::ACTIVE)]);
        let boxes = preedit_clause_rects(&layout, &preedit);
        assert_eq!(boxes.len(), 2, "the clause is on both lines");
        assert_eq!(boxes[0].rect.x, TEXT_PADDING + 10.0, "characters 2 and 3 of the first line");
        assert_eq!(boxes[0].rect.width, 10.0);
        assert_eq!(boxes[1].rect.x, TEXT_PADDING);
        assert_eq!(boxes[1].rect.width, 10.0, "and the two characters of the second");
        assert!(boxes[1].rect.y > boxes[0].rect.y);
    }

    #[test]
    fn the_clauses_of_a_right_to_left_line_run_the_other_way() {
        let (layout, _library) = laid_out("\u{05D0}\u{05D1}\u{05D2}");
        assert!(layout.lines[0].rtl);
        let preedit = Preedit::new(
            "\u{05D0}\u{05D1}\u{05D2}",
            0,
            vec![clause(0..1, PreeditStyle::ACTIVE), clause(1..2, PreeditStyle::UNDERLINED)],
        );
        let boxes = preedit_clause_rects(&layout, &preedit);
        assert_eq!(boxes.len(), 2);
        assert!(
            boxes[0].rect.x > boxes[1].rect.x,
            "the first clause is drawn to the right: {} vs {}",
            boxes[0].rect.x,
            boxes[1].rect.x
        );
        assert_eq!(boxes[0].rect.x, TEXT_PADDING + 10.0);
    }

    #[test]
    fn a_clause_past_the_end_of_the_layout_is_ignored() {
        let (layout, _library) = laid_out("ab");
        let preedit = Preedit::new("abcdef", 0, vec![clause(4..6, PreeditStyle::ACTIVE)]);
        assert!(preedit_clause_rects(&layout, &preedit).is_empty());
    }

    #[test]
    fn a_clause_that_draws_nothing_gets_no_box() {
        let (layout, _library) = laid_out("a b");
        // A clause of spaces draws nothing, so there is nothing to put a box around.
        let preedit = Preedit::new("a b", 0, vec![clause(1..2, PreeditStyle::ACTIVE)]);
        assert!(preedit_clause_rects(&layout, &preedit).is_empty());
    }

    // ---- bounds ---------------------------------------------------------

    #[test]
    fn the_bounds_cover_the_whole_preedit() {
        let (layout, _library) = laid_out("abcd");
        let bounds = preedit_bounds(&layout).expect("the pre-edit draws");
        assert_eq!(bounds.x, TEXT_PADDING);
        assert_eq!(bounds.width, layout.lines[0].width);
        assert_eq!(bounds.height, layout.line_height);
        assert_eq!(bounds.y, line_top(&layout, &layout.lines[0]));
    }

    #[test]
    fn the_bounds_cover_every_line_of_a_wrapped_preedit() {
        let (layout, _library) = laid_out("abcd\nef");
        let bounds = preedit_bounds(&layout).expect("the pre-edit draws");
        assert!(bounds.height >= 2.0 * layout.line_height);
        assert!(bounds.width >= layout.lines[0].width);
    }

    #[test]
    fn an_empty_preedit_has_no_bounds() {
        let (layout, _library) = laid_out("");
        assert!(preedit_bounds(&layout).is_none());
        let (spaces, _library) = laid_out("   ");
        assert!(preedit_bounds(&spaces).is_none(), "spaces draw nothing");
    }

    // ---- candidate window anchor ----------------------------------------

    #[test]
    fn an_anchor_at_the_start_of_a_line_points_at_the_caret() {
        let (layout, _library) = laid_out("abcd\nef");
        let anchor = candidate_anchor(&layout, 0).expect("there is a caret");
        assert_eq!(anchor.rect.x, TEXT_PADDING);
        assert_eq!(anchor.rect.width, 1.0);
        assert_eq!(anchor.rect.height, layout.line_height);
        assert_eq!(anchor.direction, AnchorDirection::Down, "there is text below");
    }

    #[test]
    fn an_anchor_at_the_end_of_a_line_sits_at_its_edge() {
        let (layout, _library) = laid_out("abcd\nef");
        let anchor = candidate_anchor(&layout, 4).expect("there is a caret");
        assert_eq!(anchor.rect.x, TEXT_PADDING + layout.lines[0].width);
        assert_eq!(anchor.direction, AnchorDirection::Down);
    }

    #[test]
    fn an_anchor_on_the_last_line_opens_upwards() {
        let (layout, _library) = laid_out("abcd\nef");
        let anchor = candidate_anchor(&layout, 7).expect("there is a caret");
        assert_eq!(anchor.rect.x, TEXT_PADDING + layout.lines[1].width);
        assert_eq!(anchor.direction, AnchorDirection::Up, "there is nothing below it to cover");
    }

    #[test]
    fn an_anchor_past_the_end_of_the_text_is_clamped() {
        let (layout, _library) = laid_out("abcd\nef");
        let anchor = candidate_anchor(&layout, 99).expect("there is a caret");
        let end = candidate_anchor(&layout, 7).unwrap();
        assert_eq!(anchor, end);
        assert_eq!(anchor.direction, AnchorDirection::Up);
    }

    #[test]
    fn an_anchor_follows_the_caret_of_a_right_to_left_line() {
        let (layout, _library) = laid_out("\u{05D0}\u{05D1}\u{05D2}");
        let start = candidate_anchor(&layout, 0).expect("there is a caret");
        let end = candidate_anchor(&layout, 3).expect("there is a caret");
        assert!(start.rect.x > end.rect.x, "the first character is drawn rightmost");
    }

    // ---- the invariant the caller relies on -----------------------------

    #[test]
    fn the_preedit_occupies_the_width_it_will_keep() {
        // The clause styles are drawn over the text, they are not part of it, so composing text takes
        // the same room as the text it becomes: nothing moves when it is committed.
        let (layout, _library) = laid_out("今天 ab");
        let preedit = Preedit::new(
            "今天 ab",
            2,
            vec![clause(0..2, PreeditStyle::ACTIVE), clause(2..5, PreeditStyle::UNDERLINED)],
        );
        let mut library = bare_library();
        let committed = layout_text(
            &TextStyle { content: preedit.text.clone(), font_size: 10.0, ..TextStyle::default() },
            &mut library,
        );
        assert_eq!(committed.width, layout.width);
        assert_eq!(committed.lines[0].width, layout.lines[0].width);
        let bounds = preedit_bounds(&layout).expect("the pre-edit draws");
        assert_eq!(bounds.width, layout.lines[0].width);
        let boxes = preedit_clause_rects(&layout, &preedit);
        assert_eq!(boxes.len(), 2);
        assert_eq!(boxes[0].rect.x, bounds.x, "the clauses start where the text does");
    }
}

/// The characters of the layout that a UTF-16 range covers, clipped to what the layout holds.
fn characters_in(layout: &TextLayout, utf16: &std::ops::Range<usize>) -> std::ops::Range<usize> {
    let start = layout
        .chars
        .iter()
        .position(|cell| cell.utf16_start + cell.utf16_len > utf16.start)
        .unwrap_or(layout.chars.len());
    let end = layout
        .chars
        .iter()
        .position(|cell| cell.utf16_start >= utf16.end)
        .unwrap_or(layout.chars.len());
    start..end.max(start)
}
