//! Text layout, rasterization and shape drawing.
//!
//! The `.comp` format keeps a text layer's characters as metadata plus the pixels they produced, so
//! this crate is what turns that metadata back into pixels: line breaking inside a paragraph box,
//! alignment, tracking and leading, per-run faces and colors, and the shape tool's redraw.
//!
//! Two rules from the macOS app shape the whole crate:
//!
//! * Run offsets count UTF-16 units, so they are resolved against each character's first unit rather
//!   than against byte offsets.
//! * Text is shaped before it is measured: runs are split by direction, face and script, HarfBuzz
//!   (rustybuzz) applies kerning, ligatures, mark positioning and complex-script reordering, and the
//!   glyphs it returns are what gets placed and drawn.
//! * Paragraphs run the way the Unicode bidirectional algorithm says they do, and the layout keeps
//!   the drawn position of every character so a caller can hit test and place a caret.
//! * The metadata stays editable and the pixels are a snapshot. Nothing here is part of compositing;
//!   `commit_text_layer` and `commit_shape_layer` are the equivalents of the macOS app's "redraw on
//!   commit" step and write straight back into the document.
//!
//! Owned by the text task.

pub mod cache;
pub mod colour;
pub mod commit;
pub mod editing;
pub mod geometry;
pub mod layout;
pub mod library;
pub mod names;
pub mod paint;
pub mod preedit;
pub mod raster;
pub mod shape;

pub use colour::{colour_layers, colour_layers_rgba};
pub use commit::{commit_shape_layer, commit_text_layer, CommitError};
pub use editing::{
    char_of_utf16, delete_grapheme_backward, delete_grapheme_forward, delete_to_line_end,
    delete_to_line_start, delete_word_backward, delete_word_forward, grapheme_boundaries, graphemes,
    line_bounds, line_end, line_start, next_grapheme, next_line, next_word_start, paragraph_at,
    prev_grapheme, prev_line, prev_word_start, select_line_end, select_line_start, select_next_grapheme,
    select_next_line, select_next_word, select_prev_grapheme, select_prev_line, select_prev_word,
    snap_range_to_graphemes, snap_to_boundary, snap_to_grapheme, utf16_len, utf16_of_char, word_at,
    word_boundaries, Selection,
};
pub use geometry::{caret_at_point, caret_rect, hit_test, line_top, selection_rects};
pub use layout::{
    cannot_end_a_line, cannot_start_a_line, char_spans, font_descent, font_name_at, is_default_ignorable,
    layout_text, layout_text_with, measure, mirrored_char, wrap_paragraph, CharCell, CharSpan, LayoutLine,
    LayoutOptions, ParagraphDirection, PlacedGlyph, PositionedGlyph, TextDirection, TextLayout,
    MIN_TEXT_SIDE, TEXT_PADDING,
};
pub use library::{FontFace, FontFallback, FontLibrary, ScriptClass};
pub use names::{FontNames, StyleHints};
pub use paint::{blend_pixel, channel, put_pixel};
pub use preedit::{
    candidate_anchor, preedit_bounds, preedit_clause_rects, AnchorDirection, CaretAnchor, Preedit,
    PreeditClause, PreeditClauseRect, PreeditStyle,
};
pub use raster::{rasterize_layout, rasterize_text, text_bounds};
pub use shape::{clamp_corner_radius, rasterize_shape};

pub use comp_core as core;
