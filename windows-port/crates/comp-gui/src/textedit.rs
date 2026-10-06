//! The text caret: where it sits, what is selected, and what typing does to the content.
//!
//! comp-text reports every position in characters, so the caret does too; the run helpers convert to
//! the UTF-16 offsets the format stores when a run is applied. The mapping between canvas points and
//! the layout's own pixels lives here as well, so hit testing can be tested without a window.

use std::ops::Range;

use comp_core::geom::{PointF, RectF};
use comp_core::layer::Layer;

use crate::runs;

/// A caret and its selection anchor, both in character indices.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct TextCaret {
    /// Where the caret sits.
    pub index: usize,
    /// The other end of the selection; None when nothing is selected.
    pub anchor: Option<usize>,
}

impl TextCaret {
    /// The selected range, ordered, or None when there is no selection.
    pub fn selection(&self) -> Option<Range<usize>> {
        let anchor = self.anchor?;
        if anchor == self.index {
            return None;
        }
        Some(anchor.min(self.index)..anchor.max(self.index))
    }

    /// Puts the caret at an index and drops the selection, as a click does.
    pub fn place(&mut self, index: usize) {
        self.index = index;
        self.anchor = None;
    }

    /// Moves the caret while the anchor stays, as a drag does; the anchor starts at the click.
    pub fn extend(&mut self, index: usize) {
        if self.anchor.is_none() {
            self.anchor = Some(self.index);
        }
        self.index = index;
    }

    /// Keeps both ends inside a text of this many characters.
    pub fn clamp(&mut self, length: usize) {
        self.index = self.index.min(length);
        self.anchor = self.anchor.map(|anchor| anchor.min(length));
        if self.anchor == Some(self.index) {
            self.anchor = None;
        }
    }
}

/// Inserts typed text at the caret, replacing the selection.
///
/// Returns the UTF-16 range the change covers, which is what a run has to be moved by.
pub fn insert(content: &mut String, caret: &mut TextCaret, typed: &str) -> (usize, usize) {
    let selection = caret.selection();
    // An insertion may not fall inside a grapheme cluster either. A selection is pushed out to cluster
    // boundaries so typing over half a family emoji takes the whole of it; a bare caret is taken to
    // the start of the cluster it is in, so what is typed lands before the cluster intact.
    let replace = match selection {
        Some(range) => {
            let (start, end) = runs::utf16_range(content, range);
            let snapped = comp_text::editing::snap_range_to_graphemes(content, start..end);
            runs::char_index(content, snapped.start)..runs::char_index(content, snapped.end)
        }
        None => {
            let offset = runs::utf16_offset(content, caret.index);
            let start = comp_text::editing::grapheme_boundaries(content, offset).start;
            // The caret moves to the boundary and nothing is replaced: an insertion into a cluster
            // would split it, so it goes before the whole cluster instead.
            let at = runs::char_index(content, start);
            caret.index = at;
            caret.anchor = None;
            at..at
        }
    };
    let (start, end) = runs::utf16_range(content, replace.clone());
    let mut next = String::with_capacity(content.len() + typed.len());
    next.extend(content.chars().take(replace.start));
    next.push_str(typed);
    next.extend(content.chars().skip(replace.end));
    *content = next;
    caret.place(replace.start + typed.chars().count());
    (start, end)
}

/// Removes the selection, or the character before the caret when there is none.
///
/// Returns the UTF-16 range the change removed, or None when there was nothing to remove.
pub fn backspace(content: &mut String, caret: &mut TextCaret) -> Option<(usize, usize)> {
    let remove = match caret.selection() {
        Some(range) => range,
        None if caret.index > 0 => caret.index - 1..caret.index,
        None => return None,
    };
    let (start, end) = runs::utf16_range(content, remove.clone());
    let mut next = String::with_capacity(content.len());
    next.extend(content.chars().take(remove.start));
    next.extend(content.chars().skip(remove.end));
    *content = next;
    caret.place(remove.start);
    Some((start, end))
}

/// Deletes characters around the caret, as an input method asks for.
///
/// A selection goes first, the way any edit replaces it. Returns the UTF-16 range the change
/// removed, which is what the runs have to follow.
pub fn delete_surrounding(content: &mut String, caret: &mut TextCaret, before: usize, after: usize) -> Option<(usize, usize)> {
    let characters = content.chars().count();
    let remove = match caret.selection() {
        Some(range) => range,
        None => caret.index.saturating_sub(before)..caret.index.saturating_add(after).min(characters),
    };
    if remove.is_empty() {
        return None;
    }
    // An input method counts characters, but an edit may not cut a cluster in half.
    let (start, end) = runs::utf16_range(content, remove.clone());
    let snapped = comp_text::editing::snap_range_to_graphemes(content, start..end);
    let (start, end) = (snapped.start, snapped.end);
    let remove = runs::char_index(content, start)..runs::char_index(content, end);
    let mut next = String::with_capacity(content.len());
    next.extend(content.chars().take(remove.start));
    next.extend(content.chars().skip(remove.end));
    *content = next;
    caret.place(remove.start);
    Some((start, end))
}

/// The point in a text layer's own layout that a canvas point lands on.
///
/// The layer's box may be a different size from the layout — a text layer can be scaled — so the
/// point is placed in box coordinates and then scaled onto the layout's pixel grid, exactly as the
/// compositor does when it draws the layer.
pub fn canvas_to_layout(layer: &Layer, layout_size: (u32, u32), point: PointF) -> Option<PointF> {
    let inverse = layer.transform.affine().inverse()?;
    let local = inverse.apply(point);
    if layout_size.0 == 0 || layout_size.1 == 0 {
        return None;
    }
    let box_size = (layer.transform.size.width, layer.transform.size.height);
    if box_size.0 <= 0.0 || box_size.1 <= 0.0 {
        return None;
    }
    Some(PointF::new(
        local.x / box_size.0 * layout_size.0 as f64,
        local.y / box_size.1 * layout_size.1 as f64,
    ))
}

/// A rectangle of a text layer's layout, back in canvas pixels.
pub fn layout_to_canvas(layer: &Layer, layout_size: (u32, u32), rect: RectF) -> RectF {
    let box_size = (layer.transform.size.width, layer.transform.size.height);
    if layout_size.0 == 0 || layout_size.1 == 0 || box_size.0 <= 0.0 || box_size.1 <= 0.0 {
        return RectF::new(0.0, 0.0, 0.0, 0.0);
    }
    let to_box = |value: f64, layout: u32, size: f64| value / layout as f64 * size;
    let rect = RectF::new(
        to_box(rect.x, layout_size.0, box_size.0),
        to_box(rect.y, layout_size.1, box_size.1),
        to_box(rect.width, layout_size.0, box_size.0),
        to_box(rect.height, layout_size.1, box_size.1),
    );
    let affine = layer.transform.affine();
    let corners = [
        affine.apply(PointF::new(rect.x, rect.y)),
        affine.apply(PointF::new(rect.max_x(), rect.y)),
        affine.apply(PointF::new(rect.x, rect.max_y())),
        affine.apply(PointF::new(rect.max_x(), rect.max_y())),
    ];
    let min_x = corners.iter().map(|corner| corner.x).fold(f64::INFINITY, f64::min);
    let min_y = corners.iter().map(|corner| corner.y).fold(f64::INFINITY, f64::min);
    let max_x = corners.iter().map(|corner| corner.x).fold(f64::NEG_INFINITY, f64::max);
    let max_y = corners.iter().map(|corner| corner.y).fold(f64::NEG_INFINITY, f64::max);
    RectF::new(min_x, min_y, max_x - min_x, max_y - min_y)
}

#[cfg(test)]
mod tests {
    #[test]
    fn typing_never_lands_inside_a_cluster_and_a_whole_cluster_goes_with_it() {
        // A family of four joined by zero width joiners: eleven UTF-16 units, seven characters.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}";
        let content_text = format!("a{family}b");
        // A caret forced inside the cluster types before it, leaving the cluster whole.
        let mut content = content_text.clone();
        let mut caret = TextCaret { index: 3, anchor: None };
        let (start, end) = insert(&mut content, &mut caret, "X");
        assert_eq!((start, end), (1, 1), "nothing was replaced");
        let expected = format!("aX{family}b");
        assert_eq!(content, expected, "the cluster is intact after the insertion");
        assert!(content.contains(family));

        // A selection that covers half the cluster takes all of it, so no half cluster is left behind.
        let mut content = content_text.clone();
        let mut caret = TextCaret { index: 1, anchor: Some(3) };
        let (_start, _end) = insert(&mut content, &mut caret, "y");
        assert_eq!(content, "ayb", "the whole cluster went, not half of it");
    }

    use super::*;
    use comp_core::geom::{PointF, SizeF, Transform};

    fn layer_at(origin: (f64, f64), size: (f64, f64)) -> Layer {
        let mut layer = Layer::raster("Text", size.0 as u32, size.1 as u32);
        layer.transform = Transform::new(PointF::new(origin.0, origin.1), SizeF::new(size.0, size.1));
        layer
    }

    #[test]
    fn placing_the_caret_drops_the_selection_and_extending_keeps_it() {
        let mut caret = TextCaret::default();
        caret.place(4);
        assert_eq!(caret.index, 4);
        assert_eq!(caret.selection(), None, "a click selects nothing");

        caret.extend(9);
        assert_eq!(caret.selection(), Some(4..9), "a drag selects from the click");
        caret.extend(2);
        assert_eq!(caret.selection(), Some(2..4), "dragging back selects the other way round");
        caret.place(7);
        assert_eq!(caret.selection(), None);
    }

    #[test]
    fn the_caret_clamps_to_the_text_and_forgets_an_empty_selection() {
        let mut caret = TextCaret { index: 9, anchor: Some(4) };
        caret.clamp(6);
        assert_eq!(caret.index, 6);
        assert_eq!(caret.anchor, Some(4));
        caret.clamp(4);
        assert_eq!(caret.selection(), None, "both ends at the same place is no selection");
    }

    #[test]
    fn typing_inserts_at_the_caret_and_moves_it() {
        let mut content = "hello".to_string();
        let mut caret = TextCaret { index: 5, anchor: None };
        insert(&mut content, &mut caret, " there");
        assert_eq!(content, "hello there");
        assert_eq!(caret.index, 11);
        assert_eq!(caret.selection(), None);

        caret.place(0);
        insert(&mut content, &mut caret, ">");
        assert_eq!(content, ">hello there");
        assert_eq!(caret.index, 1);
    }

    #[test]
    fn typing_replaces_the_selection() {
        let mut content = "hello world".to_string();
        let mut caret = TextCaret { index: 11, anchor: Some(6) };
        let (start, end) = insert(&mut content, &mut caret, "there");
        assert_eq!(content, "hello there");
        assert_eq!(caret.index, 11);
        assert_eq!((start, end), (6, 11), "the replaced range is reported for the runs");
    }

    #[test]
    fn typing_into_an_empty_text_lands_at_the_start() {
        let mut content = String::new();
        let mut caret = TextCaret::default();
        insert(&mut content, &mut caret, "a");
        assert_eq!(content, "a");
        assert_eq!(caret.index, 1);
    }

    #[test]
    fn backspace_removes_the_selection_or_one_character() {
        let mut content = "hello".to_string();
        let mut caret = TextCaret { index: 5, anchor: None };
        assert_eq!(backspace(&mut content, &mut caret), Some((4, 5)));
        assert_eq!(content, "hell");
        assert_eq!(caret.index, 4);

        caret = TextCaret { index: 4, anchor: Some(1) };
        assert_eq!(backspace(&mut content, &mut caret), Some((1, 4)));
        assert_eq!(content, "h");
        assert_eq!(caret.index, 1);

        // At the start with nothing selected there is nothing to remove.
        caret.place(0);
        assert_eq!(backspace(&mut content, &mut caret), None);
        assert_eq!(content, "h");
    }

    #[test]
    fn utf16_offsets_follow_multibyte_text() {
        // One emoji is two UTF-16 units, so a run over it has to say so.
        let mut content = "a\u{1F600}b".to_string();
        // Selecting the emoji and the letter after it, then typing over them.
        let mut caret = TextCaret { index: 3, anchor: Some(1) };
        let (start, end) = insert(&mut content, &mut caret, "x");
        assert_eq!(content, "ax");
        assert_eq!((start, end), (1, 4), "the emoji occupied two units, so the range is one wider");
    }

    #[test]
    fn deleting_around_the_caret_takes_characters_from_each_side() {
        let mut content = "hello world".to_string();
        let mut caret = TextCaret { index: 5, anchor: None };
        // Two characters before the caret and three after it: "lo wo" goes, and the caret lands
        // where the removed run started.
        assert_eq!(delete_surrounding(&mut content, &mut caret, 2, 3), Some((3, 8)));
        assert_eq!(content, "helrld");
        assert_eq!(caret.index, 3);
    }

    #[test]
    fn deleting_around_the_caret_clamps_at_both_ends() {
        let mut content = "abc".to_string();
        let mut caret = TextCaret { index: 0, anchor: None };
        assert_eq!(delete_surrounding(&mut content, &mut caret, 5, 1), Some((0, 1)), "before is clamped to the start");
        assert_eq!(content, "bc");
        caret.place(2);
        assert_eq!(delete_surrounding(&mut content, &mut caret, 1, 9), Some((1, 2)), "after is clamped to the end");
        assert_eq!(content, "b");
    }

    #[test]
    fn deleting_with_nothing_to_delete_changes_nothing() {
        let mut content = "abc".to_string();
        let mut caret = TextCaret { index: 1, anchor: None };
        assert_eq!(delete_surrounding(&mut content, &mut caret, 0, 0), None);
        assert_eq!(content, "abc");
        assert_eq!(caret.index, 1);
    }

    #[test]
    fn deleting_with_a_selection_takes_the_selection_first() {
        let mut content = "hello world".to_string();
        let mut caret = TextCaret { index: 11, anchor: Some(6) };
        assert_eq!(delete_surrounding(&mut content, &mut caret, 1, 1), Some((6, 11)));
        assert_eq!(content, "hello ");
        assert_eq!(caret.index, 6);
    }

    #[test]
    fn canvas_points_map_into_the_layout_and_back() {
        // A 100x40 layout in a 100x40 box: one to one, offset by the layer's origin.
        let layer = layer_at((30.0, 20.0), (100.0, 40.0));
        let point = canvas_to_layout(&layer, (100, 40), PointF::new(45.0, 25.0)).expect("a transform");
        assert_eq!((point.x, point.y), (15.0, 5.0));

        let rect = layout_to_canvas(&layer, (100, 40), RectF::new(15.0, 5.0, 10.0, 8.0));
        assert_eq!((rect.x, rect.y, rect.width, rect.height), (45.0, 25.0, 10.0, 8.0));
    }

    #[test]
    fn a_scaled_text_layer_maps_through_its_box() {
        // The layout is 50x20 but its box is placed twice as large.
        let mut layer = layer_at((10.0, 10.0), (50.0, 20.0));
        layer.transform.size = SizeF::new(100.0, 40.0);
        let point = canvas_to_layout(&layer, (50, 20), PointF::new(60.0, 30.0)).expect("a transform");
        assert_eq!((point.x, point.y), (25.0, 10.0), "halfway across the box is halfway across the layout");
        let rect = layout_to_canvas(&layer, (50, 20), RectF::new(0.0, 0.0, 50.0, 20.0));
        assert_eq!((rect.x, rect.y, rect.width, rect.height), (10.0, 10.0, 100.0, 40.0));
    }

    #[test]
    fn a_hit_on_a_placed_layer_finds_the_character_under_the_pointer() {
        // comp-text's geometry answers in layout pixels; the mapping above has to line up with it.
        use comp_text::{hit_test, layout_text, FontLibrary};
        use comp_core::text::TextStyle;

        let mut library = FontLibrary::from_faces(Vec::new(), Vec::new());
        let style = TextStyle { content: "abc".to_string(), font_size: 10.0, ..TextStyle::default() };
        let layout = layout_text(&style, &mut library);
        let layer = layer_at((200.0, 100.0), (layout.width as f64, layout.height as f64));
        assert_eq!(layout.chars.len(), 3);

        let y = layout.lines[0].baseline - layout.line_height / 2.0;
        // Each character of a face-less library advances half the font size, so five pixels apart.
        let padding = comp_text::TEXT_PADDING;
        for (index, x) in [(0usize, padding + 1.0), (1, padding + 6.0), (2, padding + 11.0)] {
            let canvas = PointF::new(200.0 + x, 100.0 + y);
            let local = canvas_to_layout(&layer, (layout.width, layout.height), canvas).expect("a transform");
            assert_eq!(hit_test(&layout, local), Some(index), "canvas x={x} should hit character {index}");
        }
    }
}
