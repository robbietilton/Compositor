//! Word and line navigation, selection and deletion for a text editor.
//!
//! Everything here is arithmetic on text and on a laid-out paragraph; nothing touches a window. Two
//! units meet in this module and the split is deliberate:
//!
//! * A *text* offset is a UTF-16 unit, the unit every run offset in this crate uses, so a range that
//!   comes back from here can be handed straight to the code that fixes up color and font runs.
//! * A *layout* offset is an index into the layout's character list, the unit \`hit_test\` and
//!   \`caret_rect\` use. The two converters below move between them.
//!
//! Where a word begins and ends is UAX #29's business, which is what makes double-clicking a word
//! behave the way the platform does — including for Chinese and Japanese, where the standard makes
//! every ideograph a word of its own, so word-by-word movement steps character by character.

use crate::geometry::{caret_rect, line_index_for};
use crate::layout::{LayoutLine, TextLayout};
use unicode_segmentation::UnicodeSegmentation;

/// A selection: where it started, and where the caret is now.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Selection {
    /// The end that stays put while the caret moves: what a shift-click keeps.
    pub anchor: usize,
    /// The end the caret is at.
    pub head: usize,
}

impl Selection {
    pub fn new(anchor: usize, head: usize) -> Selection {
        Selection { anchor, head }
    }

    /// A selection with no width, as a click leaves behind.
    pub fn collapsed(index: usize) -> Selection {
        Selection { anchor: index, head: index }
    }

    /// The characters the selection covers, whichever way round it was made.
    pub fn range(&self) -> std::ops::Range<usize> {
        self.anchor.min(self.head)..self.anchor.max(self.head)
    }

    pub fn is_empty(&self) -> bool {
        self.anchor == self.head
    }

    /// The same selection with the caret moved, which is what every shift-extend below does.
    pub fn with_head(self, head: usize) -> Selection {
        Selection { anchor: self.anchor, head }
    }
}

/// The length of a text in UTF-16 units, the unit every offset here is counted in.
pub fn utf16_len(text: &str) -> usize {
    text.encode_utf16().count()
}

/// The nearest UTF-16 boundary at or before an offset.
///
/// A caret can be asked for an offset inside a character that takes two units — an emoji, say — and
/// no edit may ever land there, so every entry point snaps first.
pub fn snap_to_boundary(text: &str, index: usize) -> usize {
    let length = utf16_len(text);
    if index >= length {
        return length;
    }
    let mut offset = 0;
    for ch in text.chars() {
        if offset + ch.len_utf16() > index {
            return offset;
        }
        offset += ch.len_utf16();
    }
    length
}

/// The character index of a layout that a UTF-16 offset falls in.
pub fn char_of_utf16(layout: &TextLayout, index: usize) -> usize {
    layout
        .chars
        .iter()
        .position(|cell| cell.utf16_start + cell.utf16_len > index)
        .unwrap_or(layout.chars.len())
}

/// The UTF-16 offset a character index of a layout starts at.
pub fn utf16_of_char(layout: &TextLayout, index: usize) -> usize {
    match layout.chars.get(index) {
        Some(cell) => cell.utf16_start,
        None => layout
            .chars
            .last()
            .map(|cell| cell.utf16_start + cell.utf16_len)
            .unwrap_or(0),
    }
}

/// The word the offset is in, as a UTF-16 range, or the run of punctuation or spaces it is in when
/// it is not in a word at all.
pub fn word_boundaries(text: &str, index: usize) -> std::ops::Range<usize> {
    let index = snap_to_boundary(text, index);
    for (range, _) in segments(text) {
        if index < range.end {
            return range;
        }
    }
    let length = utf16_len(text);
    length..length
}

/// The selection a double click at an offset makes.
pub fn word_at(text: &str, index: usize) -> Selection {
    let range = word_boundaries(text, index);
    Selection::new(range.start, range.end)
}

/// The next word boundary at or after an offset: the end of the word the offset is inside, or the
/// start of the next word, and the end of the text when there is no next word.
///
/// This is what a word-by-word move lands on: from the middle of a word it finishes the word, and
/// from the space after one it crosses to the next.
pub fn next_word_start(text: &str, index: usize) -> usize {
    let index = snap_to_boundary(text, index);
    let segments = segments(text);
    if let Some((range, _)) = segments.iter().find(|(range, word)| *word && range.start <= index && index < range.end)
    {
        return range.end;
    }
    segments
        .iter()
        .find(|(range, word)| *word && range.start > index)
        .map(|(range, _)| range.start)
        .unwrap_or_else(|| utf16_len(text))
}

/// The start of the word before an offset, or of the word the offset is inside.
///
/// This is where a delete-word-backward lands, and where a word-by-word move back goes: once the
/// caret is at the start of a word, the next step takes it to the start of the one before.
pub fn prev_word_start(text: &str, index: usize) -> usize {
    let index = snap_to_boundary(text, index);
    segments(text)
        .iter()
        .filter(|(range, word)| *word && range.start < index)
        .map(|(range, _)| range.start)
        .next_back()
        .unwrap_or(0)
}

/// The selection a triple click at an offset makes: the line between hard breaks that holds it.
///
/// A soft-wrapped line is a different thing, and \`line_bounds\` is the one that knows about those.
pub fn paragraph_at(text: &str, index: usize) -> Selection {
    let index = snap_to_boundary(text, index);
    let mut ranges = paragraph_ranges(text);
    if ranges.is_empty() {
        let length = utf16_len(text);
        return Selection::new(length, length);
    }
    for range in &ranges {
        if index < range.end {
            return Selection::new(range.start, range.end);
        }
    }
    let last = ranges.pop().unwrap_or(0..0);
    Selection::new(last.start, last.end)
}

/// The laid-out line an offset is on, as a UTF-16 range, soft wraps included.
pub fn line_bounds(layout: &TextLayout, index: usize) -> std::ops::Range<usize> {
    let line = line_of(layout, index);
    utf16_of_char(layout, line.range.start)..utf16_of_char(layout, line.range.end)
}

/// The start of the line an offset is on.
pub fn line_start(layout: &TextLayout, index: usize) -> usize {
    line_bounds(layout, index).start
}

/// The end of the line an offset is on.
pub fn line_end(layout: &TextLayout, index: usize) -> usize {
    line_bounds(layout, index).end
}

/// The offset one line down, keeping the column the caret is in as far as the next line allows.
pub fn next_line(layout: &TextLayout, index: usize) -> usize {
    let character = char_of_utf16(layout, index);
    let current = line_index_for(layout, character);
    let Some(line) = layout.lines.get(current + 1) else {
        return utf16_of_char(layout, layout.chars.len());
    };
    let x = caret_rect(layout, character).map(|rect| rect.x).unwrap_or(layout.lines[current].x);
    utf16_of_char(layout, snap_character_to_grapheme(layout, caret_at_x(layout, line, x)))
}

/// The offset one line up, keeping the column the caret is in as far as the line above allows.
pub fn prev_line(layout: &TextLayout, index: usize) -> usize {
    let character = char_of_utf16(layout, index);
    let current = line_index_for(layout, character);
    let Some(line) = current.checked_sub(1).and_then(|above| layout.lines.get(above)) else {
        return 0;
    };
    let x = caret_rect(layout, character).map(|rect| rect.x).unwrap_or(layout.lines[current].x);
    utf16_of_char(layout, snap_character_to_grapheme(layout, caret_at_x(layout, line, x)))
}

/// Shift and a word-by-word move forward.
pub fn select_next_word(text: &str, selection: Selection) -> Selection {
    selection.with_head(next_word_start(text, selection.head))
}

/// Shift and a word-by-word move back.
pub fn select_prev_word(text: &str, selection: Selection) -> Selection {
    selection.with_head(prev_word_start(text, selection.head))
}

/// Shift and Home: the caret goes to the start of the line it is on.
pub fn select_line_start(layout: &TextLayout, selection: Selection) -> Selection {
    selection.with_head(line_start(layout, selection.head))
}

/// Shift and End.
pub fn select_line_end(layout: &TextLayout, selection: Selection) -> Selection {
    selection.with_head(line_end(layout, selection.head))
}

/// Shift and Down.
pub fn select_next_line(layout: &TextLayout, selection: Selection) -> Selection {
    selection.with_head(next_line(layout, selection.head))
}

/// Shift and Up.
pub fn select_prev_line(layout: &TextLayout, selection: Selection) -> Selection {
    selection.with_head(prev_line(layout, selection.head))
}

/// The range a delete-word-backward would remove, or none when there is nothing before the caret.
pub fn delete_word_backward(text: &str, caret: usize) -> Option<std::ops::Range<usize>> {
    let caret = snap_to_boundary(text, caret);
    let start = prev_word_start(text, caret);
    (start < caret).then_some(start..caret)
}

/// The range a delete-word-forward would remove, or none when there is nothing after the caret.
pub fn delete_word_forward(text: &str, caret: usize) -> Option<std::ops::Range<usize>> {
    let caret = snap_to_boundary(text, caret);
    let end = next_word_start(text, caret);
    (caret < end).then_some(caret..end)
}

/// The range a delete-to-line-start would remove, or none at the start of a line.
///
/// The caret is pulled inside the text first: a caller can hold an offset from before an edit, and a
/// range that ran past the end of the text would be a slice out of bounds for whoever writes back.
pub fn delete_to_line_start(layout: &TextLayout, caret: usize) -> Option<std::ops::Range<usize>> {
    let caret = caret.min(utf16_of_char(layout, layout.chars.len()));
    let start = line_start(layout, caret);
    (start < caret).then_some(start..caret)
}

/// The range a delete-to-line-end would remove, or none at the end of a line.
pub fn delete_to_line_end(layout: &TextLayout, caret: usize) -> Option<std::ops::Range<usize>> {
    let caret = caret.min(utf16_of_char(layout, layout.chars.len()));
    let end = line_end(layout, caret);
    (caret < end).then_some(caret..end)
}

// ---- grapheme clusters --------------------------------------------------
//
// A caret may not sit inside a character, and it may not sit inside a *grapheme cluster* either: the
// man in a family emoji is four code points and three joiners, a skin tone is a modifier that belongs
// to the emoji before it, and a Devanagari consonant cluster is several code points that draw as one
// letter. UAX #29's extended grapheme clusters are what Core Text counts, so these are the functions
// an editor should use for the arrow keys and for backspace; the word functions above are for the
// word-by-word ones, and `snap_to_boundary` stays the code-point-level helper it always was.

/// The extended grapheme clusters of a text, as UTF-16 ranges.
pub fn graphemes(text: &str) -> Vec<std::ops::Range<usize>> {
    let mut result = Vec::new();
    let mut byte = 0usize;
    let mut utf16 = 0usize;
    for (offset, cluster) in text.grapheme_indices(true) {
        utf16 += text[byte..offset].encode_utf16().count();
        byte = offset;
        let length = cluster.encode_utf16().count();
        result.push(utf16..utf16 + length);
        utf16 += length;
        byte += cluster.len();
    }
    result
}

/// The nearest cluster boundary at or before an offset, so a caret can never be put inside a cluster
/// — a combining mark, a skin tone, a joiner, or the second half of an emoji.
pub fn snap_to_grapheme(text: &str, index: usize) -> usize {
    let mut boundary = 0;
    for range in graphemes(text) {
        if range.end > index {
            return range.start;
        }
        boundary = range.end;
    }
    boundary
}

/// The cluster an offset is in, as a UTF-16 range, or an empty range at the end of the text.
pub fn grapheme_boundaries(text: &str, index: usize) -> std::ops::Range<usize> {
    let index = snap_to_grapheme(text, index);
    for range in graphemes(text) {
        if index < range.end {
            return range;
        }
    }
    let length = utf16_len(text);
    length..length
}

/// Moves a range out to cluster boundaries: a start inside a cluster moves back to its start and an
/// end inside one moves on to its end, so no edit can cut a cluster in half and no run offset can end
/// up in the middle of one.
pub fn snap_range_to_graphemes(text: &str, range: std::ops::Range<usize>) -> std::ops::Range<usize> {
    let length = utf16_len(text);
    let start = snap_to_grapheme(text, range.start.min(length));
    let end = range.end.min(length).max(start);
    let end = match graphemes(text).iter().find(|cluster| cluster.start < end && end < cluster.end) {
        Some(cluster) => cluster.end,
        None => end,
    };
    start..end
}

/// The boundary after the cluster an offset is in: one press of the right arrow.
pub fn next_grapheme(text: &str, index: usize) -> usize {
    grapheme_boundaries(text, index).end
}

/// The boundary before the cluster an offset is in: one press of the left arrow.
pub fn prev_grapheme(text: &str, index: usize) -> usize {
    let length = utf16_len(text);
    let index = index.min(length);
    let mut previous = 0;
    for range in graphemes(text) {
        if range.end >= index {
            return range.start;
        }
        previous = range.start;
    }
    previous
}

/// The range one backspace removes: the whole cluster before the caret.
pub fn delete_grapheme_backward(text: &str, caret: usize) -> Option<std::ops::Range<usize>> {
    let caret = snap_to_grapheme(text, caret);
    let start = prev_grapheme(text, caret);
    (start < caret).then_some(start..caret)
}

/// The range one delete removes: the whole cluster after the caret.
pub fn delete_grapheme_forward(text: &str, caret: usize) -> Option<std::ops::Range<usize>> {
    let caret = snap_to_grapheme(text, caret);
    let end = next_grapheme(text, caret);
    (caret < end).then_some(caret..end)
}

/// Shift and one press of the right arrow.
pub fn select_next_grapheme(text: &str, selection: Selection) -> Selection {
    selection.with_head(next_grapheme(text, selection.head))
}

/// Shift and one press of the left arrow.
pub fn select_prev_grapheme(text: &str, selection: Selection) -> Selection {
    selection.with_head(prev_grapheme(text, selection.head))
}

/// The laid-out line an offset belongs to. An offset that fell on a line break between two lines
/// belongs to the one before it, which is where its caret is drawn.
fn line_of(layout: &TextLayout, index: usize) -> &LayoutLine {
    let character = char_of_utf16(layout, index);
    &layout.lines[line_index_for(layout, character).min(layout.lines.len().saturating_sub(1))]
}

/// A character index moved back to the start of the cluster it is in.
///
/// A caret may not sit inside a cluster, and the column a line-to-line move keeps can land anywhere:
/// without this, an arrow key into the middle of a family emoji would leave the next backspace able
/// to split it.
fn snap_character_to_grapheme(layout: &TextLayout, character: usize) -> usize {
    let text: String = layout.chars.iter().map(|cell| cell.ch).collect();
    let offset = utf16_of_char(layout, character);
    char_of_utf16(layout, snap_to_grapheme(&text, offset))
}

/// The caret position nearest a horizontal position on a line.
///
/// The line is walked in the order it is drawn, so this answers the same way for a right-to-left
/// line: a point past its right end belongs after the character drawn there, which is the first
/// character in logical order.
fn caret_at_x(layout: &TextLayout, line: &LayoutLine, x: f64) -> usize {
    let mut last = None;
    for &(cell, start) in &line.display {
        if x < start + layout.chars[cell].advance {
            return cell;
        }
        last = Some(cell);
    }
    match last {
        Some(cell) => cell + 1,
        None => line.range.start,
    }
}

/// The word segments of a text, as UTF-16 ranges, each saying whether it holds a word or just the
/// punctuation and spaces between words.
fn segments(text: &str) -> Vec<(std::ops::Range<usize>, bool)> {
    let mut result = Vec::new();
    let mut byte = 0usize;
    let mut utf16 = 0usize;
    for (offset, segment) in text.split_word_bound_indices() {
        utf16 += text[byte..offset].encode_utf16().count();
        byte = offset;
        let start = utf16;
        let length = segment.encode_utf16().count();
        let word = segment.chars().any(|ch| ch.is_alphanumeric());
        result.push((start..start + length, word));
        utf16 += length;
        byte += segment.len();
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout::layout_text;
    use crate::library::FontLibrary;
    use comp_core::text::{SizeD, TextStyle};

    /// A layout with no fonts installed, in which every character advances by half the font size:
    /// the first character starts at the padding, x = 12, and each one after it moves five pixels.
    fn laid_out(text: &str, width: Option<f64>) -> (TextLayout, FontLibrary) {
        let mut library = FontLibrary::from_faces(Vec::new(), Vec::new());
        let style = TextStyle {
            content: text.to_string(),
            font_size: 10.0,
            box_size: width.map(|width| SizeD::new(width, 400.0)),
            ..TextStyle::default()
        };
        let layout = layout_text(&style, &mut library);
        (layout, library)
    }

    /// A box whose wrapping width is twenty-five pixels: four characters fit, five do not.
    const NARROW: Option<f64> = Some(49.0);

    // ---- words ----------------------------------------------------------

    #[test]
    fn a_word_around_an_index_is_found() {
        let text = "\u{4E2D}\u{6587} english";
        assert_eq!(word_boundaries(text, 0), 0..1, "the first ideograph");
        assert_eq!(word_boundaries(text, 1), 1..2, "the second");
        assert_eq!(word_boundaries(text, 2), 2..3, "the space");
        assert_eq!(word_boundaries(text, 5), 3..10, "inside the Latin word");
        assert_eq!(word_boundaries(text, 99), 10..10, "past the end");
    }

    #[test]
    fn cjk_is_one_word_per_character() {
        // UAX #29 gives every ideograph a word of its own, so word-by-word movement steps a
        // character at a time through Chinese, which is what the standard asks for.
        let text = "\u{4ECA}\u{5929}\u{5929}\u{6C14}\u{5F88}\u{597D}\u{3002}";
        for index in 0..6 {
            assert_eq!(word_boundaries(text, index), index..index + 1, "character {index}");
        }
        assert_eq!(next_word_start(text, 0), 1);
        assert_eq!(next_word_start(text, 5), 6);
        assert_eq!(prev_word_start(text, 6), 5);
        // The full stop is not a word, so a double click on it selects the stop itself.
        assert_eq!(word_boundaries(text, 6), 6..7);
    }

    #[test]
    fn punctuation_is_not_part_of_a_word() {
        let text = "hello, world!";
        assert_eq!(word_boundaries(text, 0), 0..5);
        assert_eq!(word_boundaries(text, 5), 5..6, "the comma");
        assert_eq!(word_boundaries(text, 6), 6..7, "the space");
        assert_eq!(word_boundaries(text, 9), 7..12);
        assert_eq!(word_boundaries(text, 12), 12..13, "the exclamation mark");
    }

    #[test]
    fn a_decimal_number_is_one_word() {
        let text = "3.14 kg";
        assert_eq!(word_boundaries(text, 2), 0..4, "the digits and the point stay together");
        assert_eq!(word_boundaries(text, 5), 5..7);
    }

    #[test]
    fn an_apostrophe_stays_inside_the_word() {
        let text = "don't stop";
        assert_eq!(word_at(text, 3), Selection::new(0, 5));
        assert_eq!(next_word_start(text, 0), 5);
    }

    #[test]
    fn next_word_start_moves_to_the_next_boundary() {
        let text = "hello, world";
        assert_eq!(next_word_start(text, 0), 5, "the end of the word it is in");
        assert_eq!(next_word_start(text, 5), 7, "the start of the next word");
        assert_eq!(next_word_start(text, 7), 12, "the end of that one");
        assert_eq!(next_word_start(text, 12), 12, "and the end of the text");
    }

    #[test]
    fn prev_word_start_walks_backwards() {
        let text = "hello, world";
        assert_eq!(prev_word_start(text, 12), 7);
        assert_eq!(prev_word_start(text, 7), 0, "over the punctuation and the space");
        assert_eq!(prev_word_start(text, 3), 0, "and from inside a word to its start");
        assert_eq!(prev_word_start(text, 0), 0);
    }

    #[test]
    fn word_at_selects_the_word_a_double_click_lands_in() {
        let text = "one two three";
        assert_eq!(word_at(text, 5), Selection::new(4, 7), "the middle word");
        assert_eq!(word_at(text, 10), Selection::new(8, 13), "the last");
    }

    #[test]
    fn word_at_on_a_space_selects_the_spaces() {
        let text = "  spaced  ";
        assert_eq!(word_at(text, 0), Selection::new(0, 2));
        assert_eq!(word_at(text, 9), Selection::new(8, 10));
        assert_eq!(word_at(text, 4), Selection::new(2, 8));
    }

    #[test]
    fn paragraph_at_selects_the_hard_break_line() {
        let text = "one\ntwo\nthree";
        assert_eq!(paragraph_at(text, 1), Selection::new(0, 3));
        assert_eq!(paragraph_at(text, 5), Selection::new(4, 7));
        assert_eq!(paragraph_at(text, 10), Selection::new(8, 13));
        let crlf = "one\r\ntwo";
        assert_eq!(paragraph_at(crlf, 6), Selection::new(5, 8), "a carriage return and a newline are one break");
    }

// ---- grapheme clusters ----------------------------------------------

    /// 👨‍👩‍👧‍👦: four emoji and three joiners, eleven UTF-16 units, one cluster.
    const FAMILY: &str = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";

    #[test]
    fn a_family_emoji_is_one_cluster() {
        assert_eq!(utf16_len(FAMILY), 11);
        assert_eq!(graphemes(FAMILY), vec![0..11]);
        assert_eq!(grapheme_boundaries(FAMILY, 5), 0..11, "an offset inside it belongs to it");
        assert_eq!(next_grapheme(FAMILY, 0), 11);
        assert_eq!(next_grapheme(FAMILY, 5), 11, "and there is nothing inside to stop at");
    }

    #[test]
    fn deleting_backward_removes_the_whole_family() {
        let text = format!("a{FAMILY}");
        assert_eq!(delete_grapheme_backward(&text, 12), Some(1..12), "one backspace, one cluster");
    }

    #[test]
    fn a_skin_tone_modifier_belongs_to_its_base() {
        let text = "\u{1F44D}\u{1F3FD}";
        assert_eq!(utf16_len(text), 4);
        assert_eq!(graphemes(text), vec![0..4]);
        assert_eq!(delete_grapheme_backward(text, 4), Some(0..4));
    }

    #[test]
    fn a_flag_is_one_cluster() {
        let text = "\u{1F1EF}\u{1F1F5}";
        assert_eq!(utf16_len(text), 4);
        assert_eq!(graphemes(text), vec![0..4]);
        assert_eq!(next_grapheme(text, 0), 4);
    }

    #[test]
    fn a_variation_selector_belongs_to_its_base() {
        let text = "\u{2764}\u{FE0F}!";
        assert_eq!(utf16_len(text), 3);
        assert_eq!(graphemes(text), vec![0..2, 2..3]);
        assert_eq!(next_grapheme(text, 0), 2, "the heart and its selector move as one");
    }

    #[test]
    fn a_combining_mark_belongs_to_its_base() {
        let text = "e\u{0301}";
        assert_eq!(utf16_len(text), 2);
        assert_eq!(graphemes(text), vec![0..2]);
        assert_eq!(next_grapheme(text, 0), 2);
        assert_eq!(delete_grapheme_backward(text, 2), Some(0..2), "and it is never left behind");
    }

    #[test]
    fn a_devanagari_consonant_cluster_is_one_cluster() {
        let text = "\u{0915}\u{094D}\u{0915}";
        assert_eq!(utf16_len(text), 3);
        assert_eq!(graphemes(text), vec![0..3], "ka, virama and ka draw as one letter");
        assert_eq!(next_grapheme(text, 0), 3);
        assert_eq!(delete_grapheme_backward(text, 3), Some(0..3));
    }

    #[test]
    fn a_thai_tone_mark_belongs_to_its_base() {
        let text = "\u{0E01}\u{0E49}";
        assert_eq!(utf16_len(text), 2);
        assert_eq!(graphemes(text), vec![0..2]);
        assert_eq!(delete_grapheme_backward(text, 2), Some(0..2));
    }

    #[test]
    fn a_carriage_return_and_a_line_feed_are_one_cluster() {
        let text = "a\r\nb";
        assert_eq!(graphemes(text), vec![0..1, 1..3, 3..4], "a break is one thing to delete");
        assert_eq!(delete_grapheme_backward(text, 3), Some(1..3));
        assert_eq!(next_grapheme(text, 1), 3);
    }

    #[test]
    fn an_offset_inside_a_surrogate_pair_does_not_panic() {
        let text = "a\u{1F600}b";
        assert_eq!(snap_to_grapheme(text, 2), 1, "the middle of the pair is not a boundary");
        assert_eq!(grapheme_boundaries(text, 2), 1..3);
        assert_eq!(next_grapheme(text, 2), 3, "a move from inside it leaves it whole");
        assert_eq!(delete_grapheme_backward(text, 2), Some(0..1), "and a delete does not cut it");
        assert_eq!(next_grapheme(text, 99), 4);
        assert_eq!(prev_grapheme(text, 99), 3);
    }

    #[test]
    fn grapheme_movement_clamps_at_the_ends() {
        let text = "a\u{1F600}";
        assert_eq!(next_grapheme(text, 0), 1);
        assert_eq!(next_grapheme(text, 1), 3);
        assert_eq!(next_grapheme(text, 3), 3, "the end of the text is where it stops");
        assert_eq!(next_grapheme(text, 99), 3);
        assert_eq!(prev_grapheme(text, 0), 0);
        assert_eq!(prev_grapheme(text, 3), 1);
        assert_eq!(prev_grapheme(text, 1), 0);
        assert_eq!(graphemes(""), Vec::<std::ops::Range<usize>>::new());
        assert_eq!(snap_to_grapheme("", 5), 0);
    }

    #[test]
    fn an_empty_text_has_no_graphemes() {
        assert!(graphemes("").is_empty());
        assert_eq!(next_grapheme("", 0), 0);
        assert_eq!(prev_grapheme("", 7), 0);
        assert_eq!(grapheme_boundaries("", 3), 0..0);
        assert_eq!(delete_grapheme_backward("", 0), None);
        assert_eq!(delete_grapheme_forward("", 0), None);
    }

    #[test]
    fn next_grapheme_steps_one_cluster_at_a_time() {
        let text = "a\u{0301}\u{1F468}\u{200D}\u{1F469}b";
        assert_eq!(utf16_len(text), 8);
        assert_eq!(next_grapheme(text, 0), 2, "the a and its acute are one step");
        assert_eq!(next_grapheme(text, 2), 7, "the joined pair is another");
        assert_eq!(next_grapheme(text, 7), 8);
    }

    #[test]
    fn prev_grapheme_walks_back_over_clusters() {
        let text = "a\u{0301}\u{1F468}\u{200D}\u{1F469}b";
        assert_eq!(prev_grapheme(text, 8), 7);
        assert_eq!(prev_grapheme(text, 7), 2);
        assert_eq!(prev_grapheme(text, 2), 0);
    }

    #[test]
    fn prev_grapheme_from_inside_a_cluster_goes_to_its_start() {
        let text = format!("x{FAMILY}");
        assert_eq!(prev_grapheme(&text, 6), 1);
        assert_eq!(prev_grapheme(&text, 12), 1, "and from its end, back over the whole of it");
    }

    #[test]
    fn select_next_grapheme_extends_the_head_and_keeps_the_anchor() {
        let text = format!("{FAMILY}b");
        let selection = select_next_grapheme(&text, Selection::collapsed(0));
        assert_eq!(selection, Selection::new(0, 11));
        let again = select_next_grapheme(&text, selection);
        assert_eq!(again, Selection::new(0, 12));
        assert_eq!(again.range(), 0..12);
    }

    #[test]
    fn select_prev_grapheme_extends_the_other_way() {
        let text = format!("{FAMILY}b");
        let selection = select_prev_grapheme(&text, Selection::new(12, 12));
        assert_eq!(selection, Selection::new(12, 11));
        assert_eq!(selection.range(), 11..12);
        assert_eq!(select_prev_grapheme(&text, selection), Selection::new(12, 0));
    }

    #[test]
    fn delete_grapheme_forward_removes_one_cluster() {
        let text = format!("{FAMILY}x");
        assert_eq!(delete_grapheme_forward(&text, 0), Some(0..11));
        assert_eq!(delete_grapheme_forward(&text, 11), Some(11..12));
        assert_eq!(delete_grapheme_forward(&text, 12), None);
    }

    #[test]
    fn deleting_at_the_ends_removes_nothing() {
        assert_eq!(delete_grapheme_backward("abc", 0), None);
        assert_eq!(delete_grapheme_forward("abc", 3), None);
        assert_eq!(delete_grapheme_backward(FAMILY, 0), None);
    }

    #[test]
    fn snapping_a_range_never_cuts_a_cluster() {
        let text = "a\u{0301}b";
        assert_eq!(utf16_len(text), 3);
        assert_eq!(snap_range_to_graphemes(text, 1..2), 0..2, "both ends move out of the cluster");
        assert_eq!(snap_range_to_graphemes(text, 0..1), 0..2, "the end moves on");
        assert_eq!(snap_range_to_graphemes(text, 2..3), 2..3, "a boundary stays put");
        assert_eq!(snap_range_to_graphemes(text, 0..99), 0..3);
        assert_eq!(snap_range_to_graphemes(FAMILY, 3..5), 0..11);
    }

    #[test]
    fn every_offset_these_functions_return_is_a_cluster_boundary() {
        // What the runs are keyed by: an edit may not leave an offset inside a cluster, or the run
        // that comes back from shift_text_runs would start in the middle of a character.
        let text = format!("a\u{0301}{FAMILY}\u{1F44D}\u{1F3FD}\u{1F1EF}\u{1F1F5} e\u{0301}");
        let mut boundaries: Vec<usize> = graphemes(&text).iter().map(|cluster| cluster.start).collect();
        boundaries.push(utf16_len(&text));
        for index in 0..utf16_len(&text) + 3 {
            for offset in [next_grapheme(&text, index), prev_grapheme(&text, index), snap_to_grapheme(&text, index)] {
                assert!(boundaries.contains(&offset), "{offset} is not a cluster boundary of {text:?}");
            }
            let range = delete_grapheme_backward(&text, index);
            if let Some(range) = range {
                assert!(boundaries.contains(&range.start) && boundaries.contains(&range.end), "{range:?}");
            }
        }
    }

    #[test]
    fn word_boundaries_fall_on_cluster_boundaries() {
        let text = format!("one two{FAMILY} three\u{0301} \u{0915}\u{094D}\u{0915}");
        let mut boundaries: Vec<usize> = graphemes(&text).iter().map(|cluster| cluster.start).collect();
        boundaries.push(utf16_len(&text));
        for range in segments(&text) {
            assert!(boundaries.contains(&range.0.start), "{:?} starts inside a cluster", range.0);
            assert!(boundaries.contains(&range.0.end), "{:?} ends inside a cluster", range.0);
        }
    }

    #[test]
    fn a_laid_out_line_starts_and_ends_on_cluster_boundaries() {
        let (layout, _library) = laid_out("a\u{0301}b\u{1F600}c\u{1F44D}\u{1F3FD} d", NARROW);
        let text = "a\u{0301}b\u{1F600}c\u{1F44D}\u{1F3FD} d";
        let mut boundaries: Vec<usize> = graphemes(text).iter().map(|cluster| cluster.start).collect();
        boundaries.push(utf16_len(text));
        for index in 0..utf16_len(text) {
            for offset in [line_start(&layout, index), line_end(&layout, index)] {
                assert!(boundaries.contains(&offset), "{offset} is not a cluster boundary");
            }
        }
        assert!(layout.lines.len() > 1, "the box wraps the text");
    }

    // ---- characters that take two units ---------------------------------

    #[test]
    fn an_emoji_is_never_split() {
        let text = "a\u{1F600}b";
        assert_eq!(utf16_len(text), 4);
        assert_eq!(word_boundaries(text, 1), 1..3, "the emoji is a segment of its own");
        assert_eq!(next_word_start(text, 0), 1, "the end of a");
        assert_eq!(next_word_start(text, 1), 3, "past the emoji to b");
        assert_eq!(prev_word_start(text, 4), 3);
        assert_eq!(delete_word_backward(text, 2), Some(0..1), "the emoji is not cut in half");
    }

    #[test]
    fn a_caret_inside_an_emoji_snaps_to_a_boundary() {
        let text = "a\u{1F600}b";
        assert_eq!(snap_to_boundary(text, 2), 1, "the middle of the pair is not a boundary");
        assert_eq!(snap_to_boundary(text, 3), 3);
        assert_eq!(snap_to_boundary(text, 99), 4);
        assert_eq!(next_word_start(text, 2), 3, "and no move lands inside it either");
    }

    #[test]
    fn the_converters_move_between_units() {
        let (layout, _library) = laid_out("a\u{1F600}b", None);
        assert_eq!(utf16_of_char(&layout, 1), 1);
        assert_eq!(utf16_of_char(&layout, 2), 3);
        assert_eq!(utf16_of_char(&layout, 3), 4, "past the end is the length of the text");
        assert_eq!(char_of_utf16(&layout, 0), 0);
        assert_eq!(char_of_utf16(&layout, 2), 1, "inside the emoji is the emoji's own cell");
        assert_eq!(char_of_utf16(&layout, 3), 2);
    }

    // ---- lines ----------------------------------------------------------

    #[test]
    fn line_bounds_follow_the_soft_wrap() {
        let (layout, _library) = laid_out("abcd efgh", NARROW);
        assert_eq!(layout.lines.len(), 2, "the box wraps between the words");
        assert_eq!(line_bounds(&layout, 0), 0..4);
        assert_eq!(line_bounds(&layout, 6), 5..9);
        assert_eq!(line_start(&layout, 6), 5);
        assert_eq!(line_end(&layout, 0), 4);
    }

    #[test]
    fn line_start_and_end_at_a_hard_break() {
        let (layout, _library) = laid_out("ab\ncd", None);
        assert_eq!(layout.lines.len(), 2);
        assert_eq!(line_bounds(&layout, 0), 0..2);
        assert_eq!(line_bounds(&layout, 4), 3..5);
        assert_eq!(line_start(&layout, 4), 3);
        assert_eq!(line_end(&layout, 3), 5);
    }

    #[test]
    fn a_caret_on_a_line_break_belongs_to_the_line_above_it() {
        let (layout, _library) = laid_out("ab\ncd", None);
        assert_eq!(line_bounds(&layout, 2), 0..2);
        assert_eq!(line_bounds(&layout, 3), 3..5, "the first character of the next line does not");
    }

    #[test]
    fn next_line_keeps_the_column() {
        // Three lines of different lengths: abcdef, gh, ijklmn.
        let (layout, _library) = laid_out("abcdef\ngh\nijklmn", None);
        assert_eq!(next_line(&layout, 1), 8, "the second column of the first line is the second of gh");
        assert_eq!(next_line(&layout, 4), 9, "a column past the end of gh lands at its end");
        assert_eq!(next_line(&layout, 3), 9, "and so does one past its last character");
    }

    #[test]
    fn prev_line_keeps_the_column() {
        let (layout, _library) = laid_out("abcdef\ngh\nijklmn", None);
        assert_eq!(prev_line(&layout, 13), 9, "the column is past the end of gh");
        assert_eq!(prev_line(&layout, 10), 7, "the first column of the third line is the first of gh");
    }

    #[test]
    fn moving_down_from_the_last_line_lands_at_the_end() {
        let (layout, _library) = laid_out("abcdef\ngh\nijklmn", None);
        assert_eq!(next_line(&layout, 13), 16, "the end of the text");
        assert_eq!(next_line(&layout, 16), 16);
    }

    #[test]
    fn moving_up_from_the_first_line_lands_at_the_start() {
        let (layout, _library) = laid_out("abcdef\ngh\nijklmn", None);
        assert_eq!(prev_line(&layout, 3), 0);
        assert_eq!(prev_line(&layout, 0), 0);
    }

    #[test]
    fn the_column_is_kept_in_a_right_to_left_line() {
        let (layout, _library) = laid_out("\u{05D0}\u{05D1}\u{05D2}\n\u{05D3}\u{05D4}\u{05D5}", None);
        assert!(layout.lines[0].rtl && layout.lines[1].rtl);
        // The right edge of the first line is its first character, and the same column on the line
        // below is the boundary after its first character.
        assert_eq!(next_line(&layout, 0), 5);
        // Coming back up, the leftmost column is the end of the line: the caret before the last
        // character of the second line belongs before the second character of the first.
        assert_eq!(prev_line(&layout, 6), 1);
    }

    // ---- selections -----------------------------------------------------

    #[test]
    fn select_next_word_extends_the_head_and_keeps_the_anchor() {
        let text = "hello, world";
        let selection = select_next_word(text, Selection::collapsed(0));
        assert_eq!(selection, Selection::new(0, 5));
        let twice = select_next_word(text, selection);
        assert_eq!(twice, Selection::new(0, 7));
        // Shift and left from the start of "world" takes the caret back over the word before it,
        // and the anchor is where it was: the selection grows the other way.
        let back = select_prev_word(text, Selection::new(3, 7));
        assert_eq!(back, Selection::new(3, 0));
        assert_eq!(back.range(), 0..3);
    }

    #[test]
    fn select_line_start_and_end_move_the_head() {
        let (layout, _library) = laid_out("ab\ncd", None);
        assert_eq!(select_line_end(&layout, Selection::collapsed(1)), Selection::new(1, 2));
        assert_eq!(select_line_start(&layout, Selection::collapsed(1)), Selection::new(1, 0));
        assert_eq!(select_line_start(&layout, Selection::collapsed(4)).range(), 3..4);
    }

    #[test]
    fn select_up_and_down_move_the_head() {
        let (layout, _library) = laid_out("abcdef\ngh\nijklmn", None);
        assert_eq!(select_next_line(&layout, Selection::collapsed(1)), Selection::new(1, 8));
        assert_eq!(select_prev_line(&layout, Selection::collapsed(10)), Selection::new(10, 7));
        assert!(Selection::new(5, 2).range() == (2..5));
        assert!(Selection::collapsed(3).is_empty());
    }

    // ---- deletions ------------------------------------------------------

    #[test]
    fn delete_word_backward_from_mid_word_removes_the_rest_of_it() {
        let text = "hello, world";
        assert_eq!(delete_word_backward(text, 3), Some(0..3));
        assert_eq!(delete_word_backward(text, 12), Some(7..12));
    }

    #[test]
    fn delete_word_backward_at_the_start_of_the_text_removes_nothing() {
        assert_eq!(delete_word_backward("hello", 0), None);
        assert_eq!(delete_word_forward("hello", 5), None);
    }

    #[test]
    fn delete_word_backward_before_a_word_takes_the_word_and_the_space() {
        let text = "hello, world";
        assert_eq!(delete_word_backward(text, 7), Some(0..7), "back to the start of the word before");
    }

    #[test]
    fn delete_word_forward_removes_to_the_end_of_the_word() {
        let text = "hello, world";
        assert_eq!(delete_word_forward(text, 3), Some(3..5), "the rest of the word");
        assert_eq!(delete_word_forward(text, 5), Some(5..7), "the punctuation and the space");
        assert_eq!(delete_word_forward(text, 0), Some(0..5));
    }

    #[test]
    fn delete_to_line_start_and_end_stay_inside_the_line() {
        let (layout, _library) = laid_out("ab\ncd", None);
        assert_eq!(delete_to_line_start(&layout, 4), Some(3..4));
        assert_eq!(delete_to_line_start(&layout, 3), None);
        assert_eq!(delete_to_line_end(&layout, 3), Some(3..5));
        assert_eq!(delete_to_line_end(&layout, 5), None);
        assert_eq!(delete_to_line_start(&layout, 1), Some(0..1));
    }

    #[test]
    fn deleting_by_line_follows_a_soft_wrap() {
        let (layout, _library) = laid_out("abcd efgh", NARROW);
        assert_eq!(delete_to_line_end(&layout, 2), Some(2..4), "the end of the wrapped line");
        assert_eq!(delete_to_line_start(&layout, 6), Some(5..6), "and its start");
    }
}

/// The lines of a text between hard breaks, as UTF-16 ranges without the break itself.
fn paragraph_ranges(text: &str) -> Vec<std::ops::Range<usize>> {
    let mut ranges = Vec::new();
    let mut start = 0usize;
    let mut offset = 0usize;
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        let length = ch.len_utf16();
        if ch == '\n' || ch == '\r' {
            ranges.push(start..offset);
            if ch == '\r' && chars.peek() == Some(&'\n') {
                chars.next();
                offset += 1;
            }
            offset += length;
            start = offset;
            continue;
        }
        offset += length;
    }
    ranges.push(start..offset);
    ranges
}
