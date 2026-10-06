//! Text run editing: setting a color or a face on a range of characters.
//!
//! Run offsets count UTF-16 units, as the format stores them, so a character selection is converted
//! before it is applied. Applying a value splits the runs that straddle the range, merges the
//! neighbours that end up equal, and clips or drops whatever the text no longer covers.

use std::ops::Range;

use comp_core::text::{TextColorRun, TextFontRun};

/// A run as the rebuild works on it: a span and the value it carries.
type Span<T> = (usize, usize, T);

/// The UTF-16 offset a character index starts at, clamped to the text.
///
/// The editor and comp-text's geometry count characters, while the format counts UTF-16 units, and
/// the two differ as soon as the text holds anything outside the basic plane.
pub fn utf16_offset(content: &str, chars: usize) -> usize {
    content.chars().take(chars).map(char::len_utf16).sum()
}

/// The character index a UTF-16 offset falls on.
pub fn char_index(content: &str, utf16: usize) -> usize {
    let mut units = 0usize;
    for (index, ch) in content.chars().enumerate() {
        if units >= utf16 {
            return index;
        }
        units += ch.len_utf16();
    }
    content.chars().count()
}

/// The UTF-16 offsets of a character range, clamped to the text and ordered.
pub fn utf16_range(content: &str, chars: Range<usize>) -> (usize, usize) {
    let total = content.encode_utf16().count();
    let start = utf16_offset(content, chars.start).min(total);
    let end = utf16_offset(content, chars.end).min(total);
    (start.min(end), end.max(start))
}

/// Moves the runs over a text edit that replaced the UTF-16 range start..end with new text.
///
/// Runs after the edit move with it, and a run that covered the replaced text keeps the parts of
/// itself that are left, so a color painted over a word stays on the word when it is retyped.
fn rebuild_after_edit<T: Clone + PartialEq>(
    runs: &[Span<T>],
    start: usize,
    end: usize,
    inserted: usize,
    length: usize,
) -> Vec<Span<T>> {
    let delta = inserted as i64 - end.saturating_sub(start) as i64;
    let mut pieces: Vec<Span<T>> = Vec::new();
    for (location, run_length, value) in runs {
        let run_start = *location;
        let run_end = location.saturating_add(*run_length);
        // What sat before the edit does not move.
        if run_end.min(start) > run_start {
            pieces.push((run_start, run_end.min(start) - run_start, value.clone()));
        }
        // What sat after it moves by the length difference.
        let tail_start = run_start.max(end);
        if run_end > tail_start {
            let moved_start = (tail_start as i64 + delta).max(0) as usize;
            let moved_end = ((run_end as i64 + delta).max(0) as usize).min(length);
            if moved_end > moved_start {
                pieces.push((moved_start, moved_end - moved_start, value.clone()));
            }
        }
    }
    if inserted > 0 {
        // Typed characters take the formatting they were typed into, which is what a text editor
        // does; without this the new text would sit in a hole between two runs.
        let inserted_end = (start + inserted).min(length);
        let covered = pieces
            .iter()
            .any(|(location, run_length, _)| *location <= start && location + run_length >= inserted_end);
        if !covered {
            // The formatting the caret was sitting in, which is the run that covered the insertion
            // point before the edit; the pieces are only a fallback for an insertion past every run.
            let inherited = runs
                .iter()
                .find(|(location, run_length, _)| start >= *location && start < location.saturating_add(*run_length))
                .or_else(|| pieces.iter().find(|(location, run_length, _)| *location <= start && location + run_length >= start))
                .or_else(|| pieces.iter().find(|(location, _, _)| *location == inserted_end))
                .map(|(_, _, value)| value.clone());
            if let Some(value) = inherited {
                if inserted_end > start {
                    pieces.push((start, inserted_end - start, value));
                }
            }
        }
    }
    normalize(pieces, length)
}

/// Puts the pieces in order, drops what the text no longer covers and joins equal neighbours.
fn normalize<T: Clone + PartialEq>(mut pieces: Vec<Span<T>>, length: usize) -> Vec<Span<T>> {
    pieces.retain(|(location, run_length, _)| *run_length > 0 && location + run_length <= length);
    pieces.sort_by_key(|(location, _, _)| *location);
    let mut merged: Vec<Span<T>> = Vec::new();
    for (location, run_length, value) in pieces {
        match merged.last_mut() {
            Some((previous_start, previous_length, previous))
                if *previous == value && *previous_start + *previous_length == location =>
            {
                *previous_length += run_length;
            }
            _ => merged.push((location, run_length, value)),
        }
    }
    merged
}

/// Applies an edit to a style's runs, so their offsets still describe the text.
pub fn shift_text_runs(style: &mut comp_core::text::TextStyle, start: usize, end: usize, inserted: usize, length: usize) {
    if let Some(runs) = style.color_runs.as_ref() {
        let spans: Vec<Span<[f64; 3]>> = runs
            .iter()
            .map(|run| (run.location, run.length, [run.red, run.green, run.blue]))
            .collect();
        let rebuilt = rebuild_after_edit(&spans, start, end, inserted, length);
        style.color_runs = (!rebuilt.is_empty()).then(|| {
            rebuilt
                .into_iter()
                .map(|(location, length, value)| TextColorRun {
                    location,
                    length,
                    red: value[0],
                    green: value[1],
                    blue: value[2],
                })
                .collect()
        });
    }
    if let Some(runs) = style.font_runs.as_ref() {
        let spans: Vec<Span<String>> = runs
            .iter()
            .map(|run| (run.location, run.length, run.font_name.clone()))
            .collect();
        let rebuilt = rebuild_after_edit(&spans, start, end, inserted, length);
        style.font_runs = (!rebuilt.is_empty()).then(|| {
            rebuilt
                .into_iter()
                .map(|(location, length, font_name)| TextFontRun { location, length, font_name })
                .collect()
        });
    }
}

/// Rebuilds a run list over a UTF-16 range.
///
/// A value of None clears the range instead of painting it, which is how a run is taken off a
/// selection. Every span outside the range keeps the value it had.
fn rebuild<T: Clone + PartialEq>(runs: &[Span<T>], start: usize, end: usize, value: Option<T>, length: usize) -> Vec<Span<T>> {
    if length == 0 {
        return Vec::new();
    }
    let mut boundaries = vec![0usize, length];
    for (location, run_length, _) in runs {
        boundaries.push((*location).min(length));
        boundaries.push(location.saturating_add(*run_length).min(length));
    }
    boundaries.push(start.min(length));
    boundaries.push(end.min(length));
    boundaries.sort_unstable();
    boundaries.dedup();

    let mut rebuilt: Vec<Span<T>> = Vec::new();
    for window in boundaries.windows(2) {
        let (from, to) = (window[0], window[1]);
        if to <= from {
            continue;
        }
        let inside = from >= start && to <= end;
        let piece = if inside {
            value.clone()
        } else {
            runs.iter()
                .find(|(location, run_length, _)| from >= *location && from < location.saturating_add(*run_length))
                .map(|(_, _, existing)| existing.clone())
        };
        let Some(piece) = piece else { continue };
        // Neighbours that touch and ended up carrying the same value become one run. A skipped
        // window leaves a gap, so contiguity has to be checked rather than assumed.
        let touching = rebuilt
            .last()
            .map(|(previous_start, previous_length, _)| previous_start + previous_length == from)
            .unwrap_or(false);
        match rebuilt.last_mut() {
            Some((_, previous_length, previous)) if touching && *previous == piece => {
                *previous_length += to - from;
            }
            _ => rebuilt.push((from, to - from, piece)),
        }
    }
    rebuilt
}

/// Applies a color over a UTF-16 range, splitting and merging runs as needed.
pub fn set_color(runs: &mut Vec<TextColorRun>, start: usize, end: usize, color: [f64; 3], length: usize) {
    let spans: Vec<Span<[f64; 3]>> = runs
        .iter()
        .map(|run| (run.location, run.length, [run.red, run.green, run.blue]))
        .collect();
    *runs = rebuild(&spans, start, end, Some(color), length)
        .into_iter()
        .map(|(location, run_length, [red, green, blue])| TextColorRun { location, length: run_length, red, green, blue })
        .collect();
}

/// Applies a face over a UTF-16 range.
pub fn set_font(runs: &mut Vec<TextFontRun>, start: usize, end: usize, font: &str, length: usize) {
    let spans: Vec<Span<String>> = runs.iter().map(|run| (run.location, run.length, run.font_name.clone())).collect();
    *runs = rebuild(&spans, start, end, Some(font.to_string()), length)
        .into_iter()
        .map(|(location, run_length, font_name)| TextFontRun { location, length: run_length, font_name })
        .collect();
}

/// Takes every color run off a UTF-16 range, so the text's own color shows through again.
pub fn clear_color(runs: &mut Vec<TextColorRun>, start: usize, end: usize, length: usize) {
    let spans: Vec<Span<[f64; 3]>> = runs
        .iter()
        .map(|run| (run.location, run.length, [run.red, run.green, run.blue]))
        .collect();
    *runs = rebuild(&spans, start, end, None, length)
        .into_iter()
        .map(|(location, run_length, [red, green, blue])| TextColorRun { location, length: run_length, red, green, blue })
        .collect();
}

/// Takes every font run off a UTF-16 range.
pub fn clear_font(runs: &mut Vec<TextFontRun>, start: usize, end: usize, length: usize) {
    let spans: Vec<Span<String>> = runs.iter().map(|run| (run.location, run.length, run.font_name.clone())).collect();
    *runs = rebuild(&spans, start, end, None, length)
        .into_iter()
        .map(|(location, run_length, font_name)| TextFontRun { location, length: run_length, font_name })
        .collect();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn colors(pairs: &[(usize, usize, f64)]) -> Vec<TextColorRun> {
        pairs
            .iter()
            .map(|(location, length, red)| TextColorRun { location: *location, length: *length, red: *red, green: 0.0, blue: 0.0 })
            .collect()
    }

    fn as_pairs(runs: &[TextColorRun]) -> Vec<(usize, usize, f64)> {
        runs.iter().map(|run| (run.location, run.length, run.red)).collect()
    }

    #[test]
    fn utf16_offsets_count_units_not_characters() {
        // The emoji is one character but two UTF-16 units, which is what the format stores.
        let content = "ab\u{1F600}c";
        assert_eq!(utf16_range(content, 0..2), (0, 2));
        assert_eq!(utf16_range(content, 2..3), (2, 4));
        assert_eq!(utf16_range(content, 3..4), (4, 5));
        assert_eq!(utf16_range(content, 0..4), (0, 5));
        assert_eq!(utf16_range("hello", 1..3), (1, 3));
        assert_eq!(utf16_range("hello", 0..0), (0, 0));
        // A selection past the end lands at the end rather than out of bounds.
        assert_eq!(utf16_range("hi", 5..9), (2, 2));
    }

    #[test]
    fn character_indices_and_utf16_offsets_convert_both_ways() {
        let content = "ab😀c";
        assert_eq!(utf16_offset(content, 0), 0);
        assert_eq!(utf16_offset(content, 2), 2);
        assert_eq!(utf16_offset(content, 3), 4, "the emoji is two units");
        assert_eq!(utf16_offset(content, 4), 5);
        assert_eq!(utf16_offset(content, 99), 5, "past the end is the end");
        assert_eq!(char_index(content, 0), 0);
        assert_eq!(char_index(content, 2), 2);
        assert_eq!(char_index(content, 4), 3, "an offset inside the emoji is its own character");
        assert_eq!(char_index(content, 5), 4);
        assert_eq!(char_index(content, 99), 4);
        for chars in 0..=4 {
            assert_eq!(char_index(content, utf16_offset(content, chars)), chars, "round trip at {chars}");
        }
    }

    #[test]
    fn typing_before_the_runs_moves_them_along() {
        let mut style = comp_core::text::TextStyle { content: "xhello".to_string(), ..Default::default() };
        style.color_runs = Some(colors(&[(0, 5, 1.0)]));
        // One character was typed at the start, and it takes the color of what it was typed into,
        // so the red run simply grows by one rather than sliding over.
        shift_text_runs(&mut style, 0, 0, 1, 6);
        assert_eq!(as_pairs(style.color_runs.as_ref().unwrap()), vec![(0, 6, 1.0)]);
    }

    #[test]
    fn typing_at_the_end_of_a_run_does_not_paint_the_text_before_it() {
        let mut style = comp_core::text::TextStyle::default();
        style.color_runs = Some(colors(&[(0, 3, 1.0)]));
        // Typing at offset 3 is inside the red run, so the new character is red too.
        shift_text_runs(&mut style, 3, 3, 1, 4);
        assert_eq!(as_pairs(style.color_runs.as_ref().unwrap()), vec![(0, 4, 1.0)]);

        // Typing past every run leaves the runs where they are.
        let mut plain = comp_core::text::TextStyle::default();
        plain.color_runs = Some(colors(&[(0, 2, 1.0)]));
        shift_text_runs(&mut plain, 5, 5, 1, 6);
        assert_eq!(as_pairs(plain.color_runs.as_ref().unwrap()), vec![(0, 2, 1.0)], "the gap stays unpainted");
    }

    #[test]
    fn typing_inside_a_run_leaves_it_covering_the_same_words() {
        let mut style = comp_core::text::TextStyle::default();
        style.color_runs = Some(colors(&[(0, 5, 1.0), (5, 5, 0.5)]));
        // Two characters typed in the middle of the red run: it grows, the other one moves over.
        shift_text_runs(&mut style, 3, 3, 2, 12);
        assert_eq!(as_pairs(style.color_runs.as_ref().unwrap()), vec![(0, 7, 1.0), (7, 5, 0.5)]);
    }

    #[test]
    fn deleting_text_pulls_the_runs_together_and_drops_empty_ones() {
        let mut style = comp_core::text::TextStyle::default();
        style.color_runs = Some(colors(&[(0, 2, 1.0), (2, 3, 0.5), (5, 2, 0.25)]));
        // The whole middle run was deleted.
        shift_text_runs(&mut style, 2, 5, 0, 4);
        assert_eq!(as_pairs(style.color_runs.as_ref().unwrap()), vec![(0, 2, 1.0), (2, 2, 0.25)]);

        // Deleting everything leaves no runs at all, which is what the format wants.
        shift_text_runs(&mut style, 0, 4, 0, 0);
        assert!(style.color_runs.is_none());
    }

    #[test]
    fn replacing_a_selection_with_text_keeps_the_runs_around_it() {
        let mut style = comp_core::text::TextStyle::default();
        style.color_runs = Some(colors(&[(0, 3, 1.0), (3, 4, 0.5), (7, 3, 0.25)]));
        // "abcdefgxyz" with "defg" replaced by "D": the middle run survives as one character.
        shift_text_runs(&mut style, 3, 7, 1, 7);
        assert_eq!(as_pairs(style.color_runs.as_ref().unwrap()), vec![(0, 3, 1.0), (3, 1, 0.5), (4, 3, 0.25)]);
    }

    #[test]
    fn font_runs_move_with_an_edit_too() {
        let mut style = comp_core::text::TextStyle::default();
        style.font_runs = Some(vec![
            TextFontRun { location: 0, length: 3, font_name: "Arial".to_string() },
            TextFontRun { location: 3, length: 3, font_name: "Times".to_string() },
        ]);
        shift_text_runs(&mut style, 6, 6, 2, 8);
        let runs = style.font_runs.as_ref().unwrap();
        assert_eq!(runs.len(), 2);
        assert_eq!((runs[0].location, runs[0].length), (0, 3));
        assert_eq!((runs[1].location, runs[1].length), (3, 5), "the last run grows with the typing");
    }

    #[test]
    fn a_color_over_the_whole_text_leaves_one_run() {
        let mut runs = Vec::new();
        set_color(&mut runs, 0, 10, [1.0, 0.0, 0.0], 10);
        assert_eq!(as_pairs(&runs), vec![(0, 10, 1.0)]);
    }

    #[test]
    fn a_color_inside_a_run_splits_it_in_three() {
        let mut runs = colors(&[(0, 10, 0.0)]);
        set_color(&mut runs, 3, 6, [1.0, 0.0, 0.0], 10);
        assert_eq!(as_pairs(&runs), vec![(0, 3, 0.0), (3, 3, 1.0), (6, 4, 0.0)]);
    }

    #[test]
    fn touching_runs_with_the_same_color_become_one() {
        let mut runs = colors(&[(0, 3, 1.0), (3, 4, 1.0)]);
        set_color(&mut runs, 0, 7, [1.0, 0.0, 0.0], 7);
        assert_eq!(as_pairs(&runs), vec![(0, 7, 1.0)]);

        // Two equal runs with a different one between them stay apart.
        let mut split = colors(&[(0, 2, 1.0), (2, 2, 0.5), (4, 2, 1.0)]);
        set_color(&mut split, 2, 4, [0.5, 0.0, 0.0], 6);
        assert_eq!(as_pairs(&split), vec![(0, 2, 1.0), (2, 2, 0.5), (4, 2, 1.0)]);
    }

    #[test]
    fn runs_are_clipped_to_the_text_and_past_the_end_ones_are_dropped() {
        let mut long = colors(&[(0, 20, 1.0)]);
        set_color(&mut long, 0, 0, [0.0, 0.0, 0.0], 10);
        assert_eq!(as_pairs(&long), vec![(0, 10, 1.0)], "a run past the end is clipped");

        let mut beyond = colors(&[(0, 4, 1.0), (20, 5, 1.0)]);
        set_color(&mut beyond, 0, 0, [0.0, 0.0, 0.0], 10);
        assert_eq!(as_pairs(&beyond), vec![(0, 4, 1.0)], "a run entirely past the end is gone");
    }

    #[test]
    fn clearing_takes_the_color_off_a_range() {
        let mut runs = colors(&[(0, 10, 1.0)]);
        clear_color(&mut runs, 3, 6, 10);
        assert_eq!(as_pairs(&runs), vec![(0, 3, 1.0), (6, 4, 1.0)]);
        clear_color(&mut runs, 0, 10, 10);
        assert!(runs.is_empty(), "clearing everything leaves no runs");
    }

    #[test]
    fn a_range_past_the_end_of_the_text_still_clips_what_is_there() {
        let mut runs = colors(&[(2, 100, 1.0)]);
        clear_color(&mut runs, 8, 99, 10);
        assert_eq!(as_pairs(&runs), vec![(2, 6, 1.0)]);
    }

    #[test]
    fn font_runs_follow_the_same_rules() {
        let mut runs: Vec<TextFontRun> = Vec::new();
        set_font(&mut runs, 2, 5, "Arial", 10);
        set_font(&mut runs, 5, 8, "Arial", 10);
        assert_eq!(runs.len(), 1, "two touching runs of the same face merge");
        assert_eq!((runs[0].location, runs[0].length), (2, 6));
        assert_eq!(runs[0].font_name, "Arial");

        set_font(&mut runs, 0, 10, "Times", 10);
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].font_name, "Times");
        assert_eq!((runs[0].location, runs[0].length), (0, 10));

        clear_font(&mut runs, 0, 4, 10);
        assert_eq!(runs.len(), 1);
        assert_eq!((runs[0].location, runs[0].length), (4, 6));
    }

    #[test]
    fn empty_text_has_no_runs_at_all() {
        let mut runs = colors(&[(0, 0, 1.0)]);
        set_color(&mut runs, 0, 5, [1.0, 0.0, 0.0], 0);
        assert!(runs.is_empty());
    }
}
