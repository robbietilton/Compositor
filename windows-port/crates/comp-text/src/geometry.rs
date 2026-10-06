//! Hit testing and caret geometry for a laid-out paragraph.
//!
//! Every line keeps its characters in the order they are drawn, each with the pen position it starts
//! at, so these functions only have to read that. A right-to-left line answers with the same kind of
//! positions as a left-to-right one; they simply run the other way.

use crate::layout::{LayoutLine, TextLayout};
use comp_core::{PointF, RectF};

/// The character under a point.
///
/// The point picks the nearest line by its vertical position — a click above or below the text still
/// lands on the closest line, the way a text editor behaves — and then the character whose advance
/// covers its horizontal position. A point past either end answers with the character at that end.
/// None only when there is nothing to hit, which is a layout of empty lines.
pub fn hit_test(layout: &TextLayout, point: PointF) -> Option<usize> {
    let line = nearest_line(layout, point.y)?;
    for &(cell, x) in &line.display {
        let advance = layout.chars[cell].advance.max(0.0);
        if point.x < x + advance {
            return Some(cell);
        }
    }
    line.display.last().map(|(cell, _)| *cell)
}

/// The caret position nearest a point, which is what a click puts a caret at.
///
/// `hit_test` answers with the character under a point, which is what selecting a character wants. A
/// caret is a position *between* characters, so this answers with the nearer of the two boundaries
/// around the character the point is in: the same click in the middle of a character can put the caret
/// before or after it, and a point past either end of a line gives that line's own edge. The middle of
/// a caret's own box answers with that caret again.
pub fn caret_at_point(layout: &TextLayout, point: PointF) -> Option<usize> {
    let line = nearest_line(layout, point.y)?;
    if line.display.is_empty() {
        return Some(line.range.start);
    }
    // Where the caret before each character of this line is drawn, worked out exactly the way
    // `caret_rect` works it out: at the character's left edge in a left-to-right line and at its right
    // edge in a right-to-left one, and at the line's far edge for an index the line does not draw.
    //
    // The caret *after* a character belongs to its logical successor, which in a line the shaper
    // reordered is not the next cell in display order — that is the whole reason this cannot be read
    // off the display list in pairs.
    let far = if line.rtl { line.x } else { line.x + line.width };
    let base = line.range.start;
    let mut before = vec![far; line.range.end.saturating_sub(base) + 2];
    for &(cell, x) in &line.display {
        if cell >= base {
            if let Some(slot) = before.get_mut(cell - base) {
                *slot = if line.rtl { x + layout.chars[cell].advance.max(0.0) } else { x };
            }
        }
    }
    let caret_x = |index: usize| -> f64 {
        index.checked_sub(base).and_then(|slot| before.get(slot).copied()).unwrap_or(far)
    };
    let mut best: Option<(f64, usize)> = None;
    let mut consider = |index: usize, x: f64| {
        let distance = (point.x - x).abs();
        if best.is_none_or(|(closest, _)| distance < closest) {
            best = Some((distance, index));
        }
    };
    for &(cell, _) in &line.display {
        consider(cell, caret_x(cell));
        consider(cell + 1, caret_x(cell + 1));
    }
    best.map(|(_, index)| index)
}

/// The box a caret sits in when it is put before the character at `index`.
///
/// The answer follows the line's direction: before a character means its left edge in a
/// left-to-right line and its right edge in a right-to-left one, and the end of a line is the far
/// end in that direction. An index past the end of the content sits at the end of the last line.
pub fn caret_rect(layout: &TextLayout, index: usize) -> Option<RectF> {
    if layout.lines.is_empty() {
        return None;
    }
    let index = index.min(layout.chars.len());
    let line = line_for(layout, index);
    let x = match line.display.iter().find(|(cell, _)| *cell == index) {
        Some(&(cell, x)) if line.rtl => x + layout.chars[cell].advance,
        Some(&(_, x)) => x,
        // The index is not a character of this line: it is the boundary at the line's far end.
        None if line.rtl => line.x,
        None => line.x + line.width,
    };
    Some(RectF::new(x, line_top(layout, line), 1.0, layout.line_height))
}

/// The boxes that highlight a range of characters, one per line it touches.
///
/// A range that runs over a line ending takes that line's own edge with it, so a selection covers
/// the whole line rather than stopping at its last glyph. On a line that mixes directions the box
/// spans both ends of the selection: a caller that needs one box per direction run can ask for the
/// two ends with `caret_rect` instead.
pub fn selection_rects(layout: &TextLayout, range: std::ops::Range<usize>) -> Vec<RectF> {
    let mut rects = Vec::new();
    if range.is_empty() {
        return rects;
    }
    for line in &layout.lines {
        if line.range.end <= range.start || line.range.start >= range.end {
            continue;
        }
        let mut left = f64::INFINITY;
        let mut right = f64::NEG_INFINITY;
        for &(cell, x) in &line.display {
            if cell >= range.start && cell < range.end {
                left = left.min(x);
                right = right.max(x + layout.chars[cell].advance);
            }
        }
        if !left.is_finite() {
            // A line the selection runs over without selecting a character of it — an empty line
            // between two paragraphs — still shows where the selection passes.
            let x = if line.rtl { line.x + line.width } else { line.x };
            left = x;
            right = x;
        }
        // The selection reaches past this line's own ends: take them, so the highlight covers the
        // line's trailing space instead of stopping at its last glyph.
        if range.start <= line.range.start {
            if line.rtl {
                right = right.max(line.x + line.width);
            } else {
                left = left.min(line.x);
            }
        }
        if range.end >= line.range.end {
            if line.rtl {
                left = left.min(line.x);
            } else {
                right = right.max(line.x + line.width);
            }
        }
        rects.push(RectF::new(left, line_top(layout, line), (right - left).max(1.0), layout.line_height));
    }
    rects
}

/// The top of a line's box: the line height above the baseline, less the descent that reaches below
/// it.
pub fn line_top(layout: &TextLayout, line: &LayoutLine) -> f64 {
    line.baseline - layout.line_height + layout.descent
}

/// The line whose vertical span holds `y`, or the closest one when it holds none.
fn nearest_line(layout: &TextLayout, y: f64) -> Option<&LayoutLine> {
    let mut closest = layout.lines.first()?;
    let mut distance = f64::INFINITY;
    for line in &layout.lines {
        let top = line_top(layout, line);
        let bottom = top + layout.line_height;
        if y >= top && y <= bottom {
            return Some(line);
        }
        let gap = if y < top { top - y } else { y - bottom };
        if gap < distance {
            distance = gap;
            closest = line;
        }
    }
    Some(closest)
}

/// The line the caret at an index belongs to: the line that covers the character, or the one that
/// ends just before it when the index is a break between lines.
pub(crate) fn line_for(layout: &TextLayout, index: usize) -> &LayoutLine {
    &layout.lines[line_index_for(layout, index)]
}

/// The index of the line the caret at an index belongs to.
pub(crate) fn line_index_for(layout: &TextLayout, index: usize) -> usize {
    let mut chosen = 0;
    for (line_index, line) in layout.lines.iter().enumerate() {
        if line.range.start <= index && index < line.range.end {
            return line_index;
        }
        if line.range.start <= index {
            chosen = line_index;
        }
    }
    chosen
}

/// The horizontal span a range of characters occupies on one line, when any of them are on it.
///
/// Only characters that put ink on the page count: a range of nothing but spaces occupies width but
/// has no span to underline.
pub(crate) fn drawn_span(
    layout: &TextLayout,
    line: &LayoutLine,
    range: &std::ops::Range<usize>,
) -> Option<(f64, f64)> {
    let mut left = f64::INFINITY;
    let mut right = f64::NEG_INFINITY;
    for &(cell, x) in &line.display {
        if cell < range.start || cell >= range.end || !crate::layout::is_drawable(layout.chars[cell].ch) {
            continue;
        }
        left = left.min(x);
        right = right.max(x + layout.chars[cell].advance);
    }
    (right > left).then_some((left, right))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout::{layout_text, TextDirection, TEXT_PADDING};
    use crate::library::FontLibrary;
    use comp_core::text::{SizeD, TextStyle};

    /// A library with no faces: every character advances by half the font size, so positions are
    /// arithmetic and the tests do not depend on which fonts are installed.
    fn bare_library() -> FontLibrary {
        FontLibrary::from_faces(Vec::new(), Vec::new())
    }

    fn text_style(content: &str) -> TextStyle {
        TextStyle { content: content.to_string(), font_size: 10.0, ..TextStyle::default() }
    }

    /// Characters of five pixels each: the first starts at the padding, at x = 12.
    fn laid_out(content: &str) -> (TextLayout, FontLibrary) {
        let mut library = bare_library();
        let layout = layout_text(&text_style(content), &mut library);
        (layout, library)
    }

    /// A right-to-left paragraph, which the first strong character of Hebrew content resolves to.
    fn laid_out_rtl(content: &str) -> (TextLayout, FontLibrary) {
        let mut library = bare_library();
        let layout = layout_text(&text_style(content), &mut library);
        assert_eq!(layout.direction, TextDirection::RightToLeft);
        (layout, library)
    }

    fn middle(layout: &TextLayout) -> f64 {
        layout.lines[0].baseline - layout.line_height / 2.0
    }

    // ---- hit testing ----------------------------------------------------

    #[test]
    fn a_point_inside_a_character_returns_it() {
        let (layout, _library) = laid_out("abc");
        let y = middle(&layout);
        assert_eq!(hit_test(&layout, PointF::new(13.0, y)), Some(0));
        assert_eq!(hit_test(&layout, PointF::new(18.0, y)), Some(1));
        assert_eq!(hit_test(&layout, PointF::new(23.0, y)), Some(2));
    }

    #[test]
    fn a_point_past_either_end_returns_the_character_there() {
        let (layout, _library) = laid_out("abc");
        let y = middle(&layout);
        assert_eq!(hit_test(&layout, PointF::new(500.0, y)), Some(2));
        assert_eq!(hit_test(&layout, PointF::new(-20.0, y)), Some(0));
    }

    #[test]
    fn a_point_above_or_below_the_text_lands_on_the_closest_line() {
        let (layout, _library) = laid_out("one\ntwo");
        let second = layout.lines[1].baseline;
        assert_eq!(hit_test(&layout, PointF::new(13.0, -50.0)), Some(0));
        assert_eq!(hit_test(&layout, PointF::new(13.0, second)), Some(4), "the second line's first character");
    }

    #[test]
    fn a_point_on_a_right_to_left_line_returns_what_is_drawn_there() {
        let (layout, _library) = laid_out_rtl("אבג");
        let y = middle(&layout);
        // Reversed: the first character is drawn last, so the leftmost box holds the last character.
        assert_eq!(hit_test(&layout, PointF::new(13.0, y)), Some(2));
        assert_eq!(hit_test(&layout, PointF::new(23.0, y)), Some(0));
    }

    #[test]
    fn an_empty_line_has_nothing_to_hit() {
        let (layout, _library) = laid_out("");
        assert_eq!(hit_test(&layout, PointF::new(13.0, 10.0)), None);
    }

    // ---- carets ---------------------------------------------------------

    #[test]
    fn a_caret_sits_before_its_character() {
        let (layout, _library) = laid_out("abc");
        let caret = caret_rect(&layout, 0).unwrap();
        assert_eq!(caret.x, TEXT_PADDING);
        assert_eq!(caret_rect(&layout, 1).unwrap().x, TEXT_PADDING + 5.0);
        assert_eq!(caret.height, layout.line_height);
        assert_eq!(caret.y, layout.lines[0].baseline - layout.line_height + layout.descent);
    }

    #[test]
    fn the_caret_at_the_end_of_a_line_sits_at_its_far_end() {
        let (layout, _library) = laid_out("abc");
        let caret = caret_rect(&layout, 3).unwrap();
        assert_eq!(caret.x, TEXT_PADDING + layout.lines[0].width);
        assert_eq!(caret.width, 1.0);
    }

    #[test]
    fn a_caret_in_a_right_to_left_line_sits_on_the_other_side() {
        let (layout, _library) = laid_out_rtl("אבג");
        // The first character is drawn rightmost, and the caret before it is on its right edge.
        assert_eq!(caret_rect(&layout, 0).unwrap().x, TEXT_PADDING + 15.0);
        assert_eq!(caret_rect(&layout, 1).unwrap().x, TEXT_PADDING + 10.0);
        assert_eq!(caret_rect(&layout, 3).unwrap().x, TEXT_PADDING, "the end of the line is its left edge");
    }

    #[test]
    fn a_caret_past_the_end_of_the_content_lands_on_the_last_line() {
        let (layout, _library) = laid_out("ab\ncd");
        let caret = caret_rect(&layout, 99).unwrap();
        assert_eq!(caret.x, TEXT_PADDING + layout.lines[1].width);
        assert_eq!(caret.y, line_top(&layout, &layout.lines[1]));
    }

    // ---- selections -----------------------------------------------------

    #[test]
    fn a_selection_inside_one_line_is_one_box() {
        let (layout, _library) = laid_out("abc");
        let rects = selection_rects(&layout, 1..3);
        assert_eq!(rects.len(), 1);
        assert_eq!(rects[0].x, TEXT_PADDING + 5.0);
        assert_eq!(rects[0].width, 10.0);
        assert_eq!(rects[0].height, layout.line_height);
    }

    #[test]
    fn a_selection_over_two_lines_is_two_boxes() {
        let (layout, _library) = laid_out("ab\ncd");
        let rects = selection_rects(&layout, 1..4);
        assert_eq!(rects.len(), 2);
        assert_eq!(rects[0].x, TEXT_PADDING + 5.0, "from the second character of the first line");
        assert_eq!(rects[0].width, 5.0, "to the end of that line, which the selection reaches");
        assert_eq!(rects[1].x, TEXT_PADDING, "the second line up to its last character");
        assert_eq!(rects[1].width, 5.0);
    }

    #[test]
    fn a_selection_that_covers_whole_lines_takes_their_edges() {
        let (layout, _library) = laid_out("ab\ncd");
        let rects = selection_rects(&layout, 0..5);
        assert_eq!(rects.len(), 2);
        assert_eq!(rects[0].x, TEXT_PADDING);
        assert_eq!(rects[0].width, layout.lines[0].width);
        assert_eq!(rects[1].x, TEXT_PADDING);
        assert_eq!(rects[1].width, layout.lines[1].width);
    }

    #[test]
    fn a_selection_on_a_right_to_left_line_covers_what_it_selected() {
        let (layout, _library) = laid_out_rtl("אבג");
        // Characters 0 and 1 are drawn at the right-hand end, 1 to the left of 0.
        let rects = selection_rects(&layout, 0..2);
        assert_eq!(rects.len(), 1);
        assert_eq!(rects[0].x, TEXT_PADDING + 5.0);
        assert_eq!(rects[0].width, 10.0);
        let whole = selection_rects(&layout, 0..3);
        assert_eq!(whole[0].x, TEXT_PADDING);
        assert_eq!(whole[0].width, layout.lines[0].width);
    }

    #[test]
    fn an_empty_selection_has_no_box() {
        let (layout, _library) = laid_out("abc");
        assert!(selection_rects(&layout, 2..2).is_empty());
        assert!(selection_rects(&layout, 3..1).is_empty(), "a backwards range selects nothing");
    }

    #[test]
    fn a_selection_across_an_empty_paragraph_still_shows_it() {
        let mut library = bare_library();
        let mut style = text_style("a\n\nb");
        style.box_size = Some(SizeD::new(60.0, 80.0));
        let layout = layout_text(&style, &mut library);
        assert_eq!(layout.lines.len(), 3);
        let rects = selection_rects(&layout, 0..4);
        assert_eq!(rects.len(), 3, "the empty line gets a box of its own");
        assert_eq!(rects[1].width, 1.0);
    }
}
