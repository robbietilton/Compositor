//! Where the caret goes for the editing gestures, through comp-text's editing API.
//!
//! comp-text owns the boundary rules — UAX#29 words, paragraphs, soft-wrapped line bounds — and
//! counts every offset it takes or answers in UTF-16 units, while the caret this editor keeps is in
//! characters. This module is the adapter between the two and nothing else: no boundary logic of its
//! own, so a fix in comp-text is a fix here.

use std::ops::Range;

use comp_text::editing::{self, Selection};
use comp_text::TextLayout;

use crate::textedit::TextCaret;

/// The caret's position as comp-text counts it.
fn utf16_of(layout: &TextLayout, caret: &TextCaret) -> usize {
    editing::utf16_of_char(layout, caret.index)
}

/// The caret's position, snapped out of any cluster it might be sitting inside.
///
/// A caret can arrive from a click or from an older edit, so every entry point that is about to use
/// a boundary walks through here first: a caret inside a cluster would make the next edit split it.
fn snapped_offset(layout: &TextLayout, content: &str, caret: &TextCaret) -> usize {
    editing::snap_to_grapheme(content, utf16_of(layout, caret))
}

/// The caret's selection with both ends taken to cluster boundaries.
fn snapped_selection(layout: &TextLayout, content: &str, caret: &TextCaret) -> Selection {
    let selection = selection_of(layout, caret);
    Selection::new(
        editing::snap_to_grapheme(content, selection.anchor),
        editing::snap_to_grapheme(content, selection.head),
    )
}

/// A range pushed out to cluster boundaries: a start inside a cluster goes back to its start and an
/// end inside one on to its end, so no run offset can ever land in the middle of a cluster.
fn snapped_range(content: &str, range: std::ops::Range<usize>) -> std::ops::Range<usize> {
    editing::snap_range_to_graphemes(content, range)
}

/// The caret's selection as comp-text counts it, with a collapsed one where nothing is selected.
fn selection_of(layout: &TextLayout, caret: &TextCaret) -> Selection {
    Selection::new(
        editing::utf16_of_char(layout, caret.anchor.unwrap_or(caret.index)),
        utf16_of(layout, caret),
    )
}

/// Puts a selection comp-text answered with back onto the caret.
fn place(caret: &mut TextCaret, selection: Selection, layout: &TextLayout) {
    let anchor = editing::char_of_utf16(layout, selection.anchor);
    let head = editing::char_of_utf16(layout, selection.head);
    caret.index = head;
    caret.anchor = (anchor != head).then_some(anchor);
}

/// A double click: the word the caret is in.
pub fn select_word(layout: &TextLayout, content: &str, caret: &mut TextCaret) {
    let at = snapped_offset(layout, content, caret);
    place(caret, editing::word_at(content, at), layout);
}

/// A triple click: the paragraph the caret is in.
pub fn select_paragraph(layout: &TextLayout, content: &str, caret: &mut TextCaret) {
    let at = snapped_offset(layout, content, caret);
    place(caret, editing::paragraph_at(content, at), layout);
}

/// An arrow on its own: one grapheme cluster either way, with the selection dropped.
///
/// One cluster, not one character: a family emoji is eleven UTF-16 units and seven characters, and
/// the arrow has to cross it in one press.
pub fn move_grapheme(layout: &TextLayout, content: &str, caret: &mut TextCaret, forward: bool) {
    let at = snapped_offset(layout, content, caret);
    let moved = if forward {
        editing::next_grapheme(content, at)
    } else {
        editing::prev_grapheme(content, at)
    };
    caret.place(editing::char_of_utf16(layout, moved));
}

/// Ctrl and an arrow: the next or previous word start.
pub fn move_word(layout: &TextLayout, content: &str, caret: &mut TextCaret, forward: bool) {
    let at = snapped_offset(layout, content, caret);
    let moved = if forward {
        editing::next_word_start(content, at)
    } else {
        editing::prev_word_start(content, at)
    };
    caret.place(editing::char_of_utf16(layout, moved));
}

/// Ctrl+Shift and an arrow: the same move, with the anchor left where it was.
pub fn extend_word(layout: &TextLayout, content: &str, caret: &mut TextCaret, forward: bool) {
    let selection = snapped_selection(layout, content, caret);
    let extended = if forward {
        editing::select_next_word(content, selection)
    } else {
        editing::select_prev_word(content, selection)
    };
    place(caret, extended, layout);
}

/// Shift and an arrow: one cluster, extending the selection.
pub fn extend_grapheme(layout: &TextLayout, content: &str, caret: &mut TextCaret, forward: bool) {
    // Both ends are taken to cluster boundaries first, so a selection can never hold half a cluster.
    let selection = snapped_selection(layout, content, caret);
    let extended = if forward {
        editing::select_next_grapheme(content, selection)
    } else {
        editing::select_prev_grapheme(content, selection)
    };
    place(caret, extended, layout);
}

/// Home or End: the edge of the line the caret is on.
pub fn move_line_edge(layout: &TextLayout, content: &str, caret: &mut TextCaret, end: bool) {
    let at = snapped_offset(layout, content, caret);
    let moved = if end { editing::line_end(layout, at) } else { editing::line_start(layout, at) };
    caret.place(editing::char_of_utf16(layout, moved));
}

/// Shift+Home or Shift+End: the same edge, extending the selection.
pub fn extend_line_edge(layout: &TextLayout, content: &str, caret: &mut TextCaret, end: bool) {
    let selection = snapped_selection(layout, content, caret);
    let extended = if end {
        editing::select_line_end(layout, selection)
    } else {
        editing::select_line_start(layout, selection)
    };
    place(caret, extended, layout);
}

/// Up or down a line, keeping the column as far as the line allows.
pub fn move_line(layout: &TextLayout, content: &str, caret: &mut TextCaret, down: bool) {
    let at = snapped_offset(layout, content, caret);
    let moved = if down { editing::next_line(layout, at) } else { editing::prev_line(layout, at) };
    caret.place(editing::char_of_utf16(layout, moved));
}

/// Shift+Up or Shift+Down.
pub fn extend_line(layout: &TextLayout, content: &str, caret: &mut TextCaret, down: bool) {
    let selection = snapped_selection(layout, content, caret);
    let extended = if down {
        editing::select_next_line(layout, selection)
    } else {
        editing::select_prev_line(layout, selection)
    };
    place(caret, extended, layout);
}

/// The UTF-16 range a single delete should remove: the selection when there is one, then one cluster.
///
/// This is what a backspace and a forward delete do, so a family emoji goes in one press.
pub fn delete_grapheme(layout: &TextLayout, content: &str, caret: &TextCaret, forward: bool) -> Option<Range<usize>> {
    if let Some(selection) = caret.selection() {
        let (start, end) = crate::runs::utf16_range(content, selection);
        return Some(snapped_range(content, start..end));
    }
    let at = snapped_offset(layout, content, caret);
    let range = if forward {
        editing::delete_grapheme_forward(content, at)
    } else {
        editing::delete_grapheme_backward(content, at)
    };
    range.map(|range| snapped_range(content, range))
}

/// The UTF-16 range an edit should remove: the selection when there is one, then the word.
///
/// The word set is comp-text's, entered from a cluster boundary and answered with a range that is
/// pushed out to cluster boundaries: a word boundary is a cluster boundary, but a range that started
/// inside a cluster would not be.
pub fn delete_word(layout: &TextLayout, content: &str, caret: &TextCaret, forward: bool) -> Option<Range<usize>> {
    if let Some(selection) = caret.selection() {
        let (start, end) = crate::runs::utf16_range(content, selection);
        return Some(snapped_range(content, start..end));
    }
    let at = snapped_offset(layout, content, caret);
    let range = if forward {
        editing::delete_word_forward(content, at)
    } else {
        editing::delete_word_backward(content, at)
    };
    range.map(|range| snapped_range(content, range))
}

/// The same to the start or the end of the line, which is Ctrl+Shift+Backspace and Ctrl+Shift+Delete.
pub fn delete_to_line_edge(layout: &TextLayout, content: &str, caret: &TextCaret, end: bool) -> Option<Range<usize>> {
    if let Some(selection) = caret.selection() {
        let (start, end) = crate::runs::utf16_range(content, selection);
        return Some(snapped_range(content, start..end));
    }
    let at = snapped_offset(layout, content, caret);
    let range = if end {
        editing::delete_to_line_end(layout, at)
    } else {
        editing::delete_to_line_start(layout, at)
    };
    range.map(|range| snapped_range(content, range))
}

#[cfg(test)]
mod tests {
    use super::*;
    use comp_core::text::TextStyle;
    use comp_text::{layout_text, FontLibrary};

    /// A library with no faces: every character advances by half the font size, so the layout is
    /// arithmetic and no test depends on which fonts are installed.
    fn library() -> FontLibrary {
        FontLibrary::from_faces(Vec::new(), Vec::new())
    }

    /// A layout of this text, and the text itself, as the canvas holds them.
    fn laid_out(content: &str) -> (TextLayout, String) {
        let mut library = library();
        let style = TextStyle { content: content.to_string(), font_size: 10.0, ..TextStyle::default() };
        let layout = layout_text(&style, &mut library);
        (layout, content.to_string())
    }

    fn caret_at(index: usize) -> TextCaret {
        TextCaret { index, anchor: None }
    }

    #[test]
    fn a_double_click_selects_the_word_under_the_caret() {
        let (layout, content) = laid_out("hello brave world");
        let mut caret = caret_at(8);
        select_word(&layout, &content, &mut caret);
        assert_eq!(caret.selection(), Some(6..11), "the word the caret was inside");
        assert_eq!(caret.index, 11, "the caret goes to the end of what it selected");

        // comp-text owns the boundaries, and it gives a space a word of its own: a double click on
        // one selects just that space, which is what its own segmentation says.
        let mut on_space = caret_at(5);
        select_word(&layout, &content, &mut on_space);
        assert_eq!(on_space.selection(), Some(5..6));
    }

    #[test]
    fn a_triple_click_selects_the_paragraph() {
        let (layout, content) = laid_out("one\ntwo\nthree");
        let mut caret = caret_at(5);
        select_paragraph(&layout, &content, &mut caret);
        assert_eq!(caret.selection(), Some(4..7), "the line between the hard breaks");
    }

    #[test]
    fn ctrl_an_arrow_moves_a_word_at_a_time() {
        let (layout, content) = laid_out("hello brave world");
        // The boundaries comp-text reports for "hello brave world": 0..5 the first word, 5..6 the
        // space, 6..11 the second word, 11..12 the space, 12..17 the third.
        let mut caret = caret_at(0);
        move_word(&layout, &content, &mut caret, true);
        assert_eq!(caret.index, 5, "the end of the first word, which is the start of its space");
        assert_eq!(caret.selection(), None, "a plain move drops the selection");
        move_word(&layout, &content, &mut caret, true);
        assert_eq!(caret.index, 6, "the next press crosses the space to the next word");
        move_word(&layout, &content, &mut caret, true);
        assert_eq!(caret.index, 11);
        move_word(&layout, &content, &mut caret, false);
        assert_eq!(caret.index, 6, "back to the start of the word before");
        move_word(&layout, &content, &mut caret, false);
        assert_eq!(caret.index, 0);
        move_word(&layout, &content, &mut caret, false);
        assert_eq!(caret.index, 0, "and it stops at the start");
    }

    #[test]
    fn ctrl_shift_an_arrow_extends_word_by_word() {
        let (layout, content) = laid_out("hello brave world");
        let mut caret = caret_at(0);
        extend_word(&layout, &content, &mut caret, true);
        assert_eq!(caret.selection(), Some(0..5));
        extend_word(&layout, &content, &mut caret, true);
        assert_eq!(caret.selection(), Some(0..6), "the anchor stays where the first press left it");
        extend_word(&layout, &content, &mut caret, true);
        assert_eq!(caret.selection(), Some(0..11));
        extend_word(&layout, &content, &mut caret, false);
        assert_eq!(caret.selection(), Some(0..6));
        extend_word(&layout, &content, &mut caret, false);
        assert_eq!(caret.selection(), None, "back at the anchor, so nothing is selected");
    }

    #[test]
    fn home_and_end_go_to_the_edges_of_the_line() {
        let (layout, content) = laid_out("one\ntwo\nthree");
        let mut caret = caret_at(5);
        move_line_edge(&layout, &content, &mut caret, false);
        assert_eq!(caret.index, 4, "the start of the second line");
        caret = caret_at(5);
        move_line_edge(&layout, &content, &mut caret, true);
        assert_eq!(caret.index, 7, "and its end");
        caret.place(5);
        extend_line_edge(&layout, &content, &mut caret, true);
        assert_eq!(caret.selection(), Some(5..7));
        extend_line_edge(&layout, &content, &mut caret, false);
        assert_eq!(caret.selection(), Some(4..5), "shift and home drags the head back to the start");
    }

    #[test]
    fn up_and_down_keep_the_column() {
        let (layout, content) = laid_out("one\ntwo\nthree");
        let mut caret = caret_at(5);
        move_line(&layout, &content, &mut caret, false);
        assert_eq!(caret.index, 1, "one column into the line above");
        move_line(&layout, &content, &mut caret, true);
        assert_eq!(caret.index, 5, "and back down");
        move_line(&layout, &content, &mut caret, true);
        assert_eq!(caret.index, 9, "the third line has the column too");
        caret.place(5);
        extend_line(&layout, &content, &mut caret, false);
        assert_eq!(caret.selection(), Some(1..5));
    }

    /// The cluster boundaries of a text, in UTF-16 units, as comp-text reports them.
    fn clusters(text: &str) -> Vec<std::ops::Range<usize>> {
        editing::graphemes(text)
    }

    /// A caret's position in UTF-16 units, which is what the cluster functions speak.
    fn offset(layout: &TextLayout, caret: &TextCaret) -> usize {
        editing::utf16_of_char(layout, caret.index)
    }

    #[test]
    fn a_family_emoji_is_one_step_and_one_delete() {
        // Four people joined by three zero width joiners: eleven UTF-16 units, one cluster.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
        let (layout, content) = laid_out(&format!("a{family}b"));
        assert_eq!(clusters(&content), vec![0..1, 1..12, 12..13], "one cluster for the whole family");

        let mut caret = caret_at(1);
        move_grapheme(&layout, &content, &mut caret, true);
        assert_eq!(offset(&layout, &caret), 12, "one press crosses all eleven units");
        move_grapheme(&layout, &content, &mut caret, false);
        assert_eq!(offset(&layout, &caret), 1, "and one press comes back");

        // The caret after the family: one backspace takes the whole of it.
        caret = caret_at(editing::char_of_utf16(&layout, 12));
        let removal = delete_grapheme(&layout, &content, &caret, false).expect("something to delete");
        assert_eq!(removal, 1..12, "a backspace removes the whole family in one press");
        // And from inside it, a forward delete does the same.
        caret = caret_at(editing::char_of_utf16(&layout, 5));
        let forward = delete_grapheme(&layout, &content, &caret, true).expect("something to delete");
        assert_eq!(forward, 1..12, "a forward delete from inside the family removes all of it");
        // A caret forced inside the cluster is snapped to the cluster's start first, which is the
        // rule comp-text states; the step before it is then the character before the family. A real
        // caret never gets there, because clicks and arrows all snap out of clusters.
        let backward = delete_grapheme(&layout, &content, &caret, false).expect("something to delete");
        assert_eq!(backward, 0..1, "snapped to the cluster start, the step back is the character before it");
    }

    #[test]
    fn a_skin_tone_modifier_travels_with_its_hand() {
        // A thumbs up with a medium skin tone: four units, one cluster.
        let (layout, content) = laid_out("\u{1F44D}\u{1F3FD}x");
        assert_eq!(clusters(&content), vec![0..4, 4..5]);
        let mut caret = caret_at(0);
        move_grapheme(&layout, &content, &mut caret, true);
        assert_eq!(offset(&layout, &caret), 4);
        assert_eq!(delete_grapheme(&layout, &content, &caret, false), Some(0..4));
    }

    #[test]
    fn a_flag_is_one_cluster() {
        // Two regional indicators, which UAX #29 joins into one flag.
        let (layout, content) = laid_out("\u{1F1EF}\u{1F1F5}!");
        assert_eq!(clusters(&content), vec![0..4, 4..5]);
        let mut caret = caret_at(0);
        move_grapheme(&layout, &content, &mut caret, true);
        assert_eq!(offset(&layout, &caret), 4, "the flag is crossed in one press");
        assert_eq!(delete_grapheme(&layout, &content, &caret, false), Some(0..4));
    }

    #[test]
    fn a_variation_selector_stays_with_its_heart() {
        // A heart with the emoji variation selector: three units, one cluster.
        // U+2764 is one UTF-16 unit and the variation selector is another, so the cluster is two.
        let (layout, content) = laid_out("\u{2764}\u{FE0F}.");
        assert_eq!(clusters(&content), vec![0..2, 2..3]);
        let mut caret = caret_at(0);
        move_grapheme(&layout, &content, &mut caret, true);
        assert_eq!(offset(&layout, &caret), 2);
        assert_eq!(delete_grapheme(&layout, &content, &caret, false), Some(0..2));
    }

    #[test]
    fn a_combining_accent_is_one_cluster() {
        let (layout, content) = laid_out("e\u{301}e");
        assert_eq!(clusters(&content), vec![0..2, 2..3], "the accent belongs to the letter before it");
        let mut caret = caret_at(1);
        // The caret was asked for a position inside the cluster; it snaps out of it.
        move_grapheme(&layout, &content, &mut caret, true);
        assert_eq!(offset(&layout, &caret), 2, "the step leaves the whole accented letter behind");
        assert_eq!(delete_grapheme(&layout, &content, &caret, false), Some(0..2));
    }

    #[test]
    fn a_carriage_return_and_its_line_feed_go_together() {
        let (layout, content) = laid_out("a\r\nb");
        assert_eq!(clusters(&content), vec![0..1, 1..3, 3..4], "CRLF is one cluster, as UAX #29 says");
        // The caret after the line ending, taken there through the layout's own mapping: a layout
        // need not keep a cell for the carriage return, so the offset is what counts.
        let caret = caret_at(editing::char_of_utf16(&layout, 3));
        assert_eq!(
            delete_grapheme(&layout, &content, &caret, false),
            Some(1..3),
            "one backspace removes both halves of the line ending"
        );
        let mut moving = caret_at(editing::char_of_utf16(&layout, 1));
        move_grapheme(&layout, &content, &mut moving, true);
        assert_eq!(offset(&layout, &moving), 3, "and one arrow step crosses it");
    }

    #[test]
    fn a_caret_from_a_click_snaps_out_of_a_cluster() {
        // What the canvas does with a hit test: a layout position inside a cluster is taken to the
        // boundary before it, which is what text_index_at does with the same two calls.
        let content = "a\u{1F468}\u{200D}\u{1F469}b";
        let (layout, _) = laid_out(content);
        let boundaries = clusters(content);
        for inside in 0..=layout.chars.len() {
            let offset = editing::utf16_of_char(&layout, inside);
            let snapped = editing::snap_to_grapheme(content, offset);
            let character = editing::char_of_utf16(&layout, snapped);
            assert!(
                boundaries
                    .iter()
                    .any(|cluster| cluster.start == snapped || cluster.end == snapped),
                "a click at character {inside} landed on {snapped}, which is not a cluster boundary"
            );
            assert!(character <= layout.chars.len());
            // And what comes back is a character index the layout really has.
            assert_eq!(editing::utf16_of_char(&layout, character), snapped);
        }
    }

    #[test]
    fn word_operations_start_from_a_cluster_boundary() {
        // The caret is put inside the emoji on purpose: the word move has to snap out first.
        let content = "one \u{1F468}\u{200D}\u{1F469} two";
        let (layout, content) = laid_out(content);
        let boundaries = clusters(&content);
        // Character 5 is the zero width joiner, which is inside the cluster on purpose.
        let mut caret = caret_at(5);
        assert!(
            !boundaries
                .iter()
                .any(|cluster| cluster.start == offset(&layout, &caret) || cluster.end == offset(&layout, &caret)),
            "the caret was meant to start inside the cluster"
        );
        move_word(&layout, &content, &mut caret, true);
        let landed = offset(&layout, &caret);
        assert!(
            boundaries.iter().any(|cluster| cluster.start == landed || cluster.end == landed),
            "a word move landed on {landed}, which is inside a cluster"
        );
    }

    #[test]
    fn deleting_a_word_never_leaves_half_a_cluster() {
        let content = "a\u{1F468}\u{200D}\u{1F469}b c";
        let (layout, content) = laid_out(content);
        let mut caret = caret_at(3);
        // Inside the cluster, so the word delete has to snap before it looks for a boundary.
        let removal = delete_word(&layout, &content, &caret, false).expect("something to delete");
        assert_cluster_aligned(&content, removal.clone());
        move_word(&layout, &content, &mut caret, true);
        let removal = delete_word(&layout, &content, &caret, true).expect("something to delete");
        assert_cluster_aligned(&content, removal);
    }

    #[test]
    fn the_line_edge_deletes_are_cluster_aligned() {
        let content = "x\r\n\u{1F600}y";
        let (layout, content) = laid_out(content);
        let caret = caret_at(3);
        if let Some(range) = delete_to_line_edge(&layout, &content, &caret, false) {
            assert_cluster_aligned(&content, range);
        }
        if let Some(range) = delete_to_line_edge(&layout, &content, &caret, true) {
            assert_cluster_aligned(&content, range);
        }
    }

    #[test]
    fn extending_by_cluster_keeps_both_ends_on_boundaries() {
        let content = "a\u{1F468}\u{200D}\u{1F469}\u{1F44D}\u{1F3FD}b";
        let (layout, content) = laid_out(content);
        let boundaries = clusters(&content);
        let mut caret = caret_at(1);
        for _ in 0..4 {
            extend_grapheme(&layout, &content, &mut caret, true);
            let selection = caret.selection().or_else(|| Some(caret.index..caret.index)).expect("a range");
            let (start, end) = crate::runs::utf16_range(&content, selection);
            assert!(
                boundaries.iter().any(|cluster| cluster.end == end),
                "the head landed at {end}, inside a cluster"
            );
            assert!(boundaries.iter().any(|cluster| cluster.start == start), "the anchor moved off a boundary");
        }
    }

    #[test]
    fn mixing_word_and_cluster_extension_never_makes_half_a_cluster() {
        let content = "alpha \u{1F468}\u{200D}\u{1F469} beta";
        let (layout, content) = laid_out(content);
        let mut caret = caret_at(0);
        extend_word(&layout, &content, &mut caret, true);
        extend_grapheme(&layout, &content, &mut caret, true);
        extend_word(&layout, &content, &mut caret, true);
        extend_grapheme(&layout, &content, &mut caret, false);
        let selection = caret.selection().expect("a selection");
        let (start, end) = crate::runs::utf16_range(&content, selection);
        assert_cluster_aligned(&content, start..end);

        // And the delete of that selection is aligned too, which is what keeps runs whole.
        let removal = delete_word(&layout, &content, &caret, true).expect("a range to remove");
        assert_cluster_aligned(&content, removal);
    }

    #[test]
    fn a_run_painted_over_a_selection_keeps_cluster_boundaries() {
        // The run offsets are UTF-16 and must land on cluster boundaries, or a colour would cover
        // half a family.
        let content = "a\u{1F468}\u{200D}\u{1F469}b";
        let (layout, content) = laid_out(content);
        let mut caret = caret_at(1);
        extend_grapheme(&layout, &content, &mut caret, true);
        let selection = caret.selection().expect("a selection");
        let (start, end) = crate::runs::utf16_range(&content, selection);
        let mut runs: Vec<comp_core::text::TextColorRun> = Vec::new();
        crate::runs::set_color(&mut runs, start, end, [1.0, 0.0, 0.0], content.encode_utf16().count());
        let boundaries = clusters(&content);
        for run in &runs {
            let run_end = run.location + run.length;
            assert!(
                boundaries.iter().any(|cluster| cluster.start == run.location),
                "a run starts at {} inside a cluster",
                run.location
            );
            assert!(
                boundaries.iter().any(|cluster| cluster.end == run_end || cluster.start == run_end),
                "a run ends at {run_end} inside a cluster"
            );
        }
    }

    /// Asserts that a range starts and ends on cluster boundaries of the text.
    fn assert_cluster_aligned(content: &str, range: std::ops::Range<usize>) {
        let boundaries = clusters(content);
        assert!(
            boundaries.iter().any(|cluster| cluster.start == range.start),
            "{} is inside a cluster",
            range.start
        );
        let end = range.end;
        assert!(
            boundaries.iter().any(|cluster| cluster.end == end) || end == content.encode_utf16().count(),
            "{end} is inside a cluster"
        );
    }

    #[test]
    fn a_word_delete_answers_with_the_utf16_range_to_remove() {
        let (layout, content) = laid_out("hello brave world");
        let caret = caret_at(11);
        assert_eq!(delete_word(&layout, &content, &caret, false), Some(6..11), "back to the word start");
        assert_eq!(
            delete_word(&layout, &content, &caret, true),
            Some(11..12),
            "forward over the space, which comp-text counts as a word of its own"
        );
        let at_start = caret_at(0);
        assert_eq!(delete_word(&layout, &content, &at_start, false), None, "nothing before the start");
        let at_end = caret_at(17);
        assert_eq!(delete_word(&layout, &content, &at_end, true), None, "nothing after the end");
    }

    #[test]
    fn a_delete_with_a_selection_takes_the_selection() {
        let (layout, content) = laid_out("hello brave world");
        let caret = TextCaret { index: 11, anchor: Some(0) };
        assert_eq!(delete_word(&layout, &content, &caret, true), Some(0..11));
        assert_eq!(
            delete_to_line_edge(&layout, &content, &caret, false),
            Some(0..11),
            "the line-edge deletes do the same with a selection"
        );
    }

    #[test]
    fn the_line_edge_deletes_stop_at_the_line() {
        let (layout, content) = laid_out("one\ntwo\nthree");
        let caret = caret_at(6);
        assert_eq!(delete_to_line_edge(&layout, &content, &caret, false), Some(4..6));
        assert_eq!(delete_to_line_edge(&layout, &content, &caret, true), Some(6..7));
        let at_start = caret_at(4);
        assert_eq!(delete_to_line_edge(&layout, &content, &at_start, false), None);
        let at_end = caret_at(7);
        assert_eq!(delete_to_line_edge(&layout, &content, &at_end, true), None);
    }

    #[test]
    fn a_delete_word_range_is_counted_in_utf16() {
        // The emoji takes two units, so the range that removes it is one wider than the characters.
        let (layout, content) = laid_out("a\u{1F600} b");
        let caret = caret_at(2);
        let range = delete_word(&layout, &content, &caret, false).expect("a word to remove");
        assert_eq!(range, 0..3, "the range covers the emoji's two units");
    }
}
