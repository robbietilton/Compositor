//! Line breaking, alignment and glyph placement for a text layer.
//!
//! Every offset a `.comp` file stores for a text run counts UTF-16 units, because that is what
//! the macOS app's `NSRange` uses, while Rust strings are UTF-8. A character outside the BMP
//! ("😀") is one `char` here but two UTF-16 units there, so runs are resolved against the
//! character's *first* unit: a run that starts on a character always covers it whole.
//!
//! Text is shaped the way Core Text shapes it on macOS: the characters are split into runs that share
//! a face and a script, each run goes through HarfBuzz (rustybuzz here), and what comes back — kerned
//! advances, ligatures, attached marks, reordered Indic syllables — is what this module measures,
//! breaks into lines and places. `LayoutOptions::UNSHAPED` restores the older one-glyph-per-character
//! layout for callers that want to see the difference.

use crate::library::{FontLibrary, ShapeKey, ShapedGlyph};
use unicode_segmentation::UnicodeSegmentation;
use crate::paint::channel;
use comp_core::limits;
use comp_core::text::{TextAlignment, TextColorRun, TextFontRun, TextStyle};
use fontdue::Font;
use rustybuzz::{Direction, Face as ShaperFace, Script as ShaperScript, UnicodeBuffer};
use std::collections::HashMap;
use std::sync::Arc;
use unicode_bidi::{BidiInfo, Level};
use unicode_script::UnicodeScript;

/// The gap between the text and its box, in layer pixels, matching the macOS app.
pub const TEXT_PADDING: f64 = 12.0;

/// The smallest side a text raster may have: a caret's worth of room, so an empty line still has
/// somewhere to be typed.
pub const MIN_TEXT_SIDE: f64 = 16.0;

/// The share of the font size given to a character when no face is installed at all.
const FALLBACK_ADVANCE_RATIO: f64 = 0.5;

/// How many space widths a tab advances, the narrowest tab stop worth having.
const TAB_SPACES: f64 = 2.0;

/// Which way a paragraph runs.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum ParagraphDirection {
    /// The paragraph's first strong character decides, as UAX #9 rule P2 does.
    #[default]
    Auto,
    LeftToRight,
    RightToLeft,
}

/// The direction a paragraph was actually laid out in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TextDirection {
    LeftToRight,
    RightToLeft,
}

impl TextDirection {
    pub fn is_rtl(self) -> bool {
        matches!(self, TextDirection::RightToLeft)
    }
}

/// How a text layer is laid out.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LayoutOptions {
    /// Shape the text: kerning, ligatures, mark positioning and complex-script reordering. Off
    /// measures and places one glyph per character, the way this crate laid text out before it
    /// could shape, which is what a caller comparing the two wants.
    pub shaping: bool,
    /// Which way paragraphs run. Auto resolves every paragraph on its own.
    pub direction: ParagraphDirection,
}

impl LayoutOptions {
    /// Shaped, with each paragraph's direction taken from its own text.
    pub const SHAPED: LayoutOptions = LayoutOptions { shaping: true, direction: ParagraphDirection::Auto };
    /// One glyph per character, measured by the font's own advance widths.
    pub const UNSHAPED: LayoutOptions = LayoutOptions { shaping: false, direction: ParagraphDirection::Auto };
}

impl Default for LayoutOptions {
    fn default() -> Self {
        LayoutOptions::SHAPED
    }
}

/// One character of the content, with the UTF-16 span the runs address it by.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CharSpan {
    pub ch: char,
    /// Offset of the character's first UTF-16 unit inside the content.
    pub utf16_start: usize,
    /// UTF-16 units the character occupies: two outside the BMP.
    pub utf16_len: usize,
}

/// Splits content into characters with their UTF-16 offsets.
pub fn char_spans(content: &str) -> Vec<CharSpan> {
    let mut spans = Vec::with_capacity(content.len());
    let mut utf16_start = 0;
    for ch in content.chars() {
        let utf16_len = ch.len_utf16();
        spans.push(CharSpan { ch, utf16_start, utf16_len });
        utf16_start += utf16_len;
    }
    spans
}

/// The face name the UTF-16 unit at an offset is set in, or the style's own face. The first run that
/// covers the unit wins, so a run covering only half of a character still selects its face.
pub fn font_name_at(style: &TextStyle, index: usize) -> &str {
    if let Some(runs) = &style.font_runs {
        for run in runs {
            if run.location <= index && index < run.location + run.length {
                return &run.font_name;
            }
        }
    }
    &style.font_name
}

/// One laid-out character: its face, its color and how far the pen moves past it.
///
/// The advance is the *shaped* one: a character a ligature swallowed has none of its own, and a
/// character the shaper kerned carries the adjustment.
#[derive(Clone, Debug)]
pub struct CharCell {
    pub ch: char,
    pub utf16_start: usize,
    pub utf16_len: usize,
    /// Index into the layout's font list, or none when no face is installed.
    pub font: Option<usize>,
    /// How far the pen moves past this character, in layer pixels.
    pub advance: f64,
    pub color: [u8; 3],
    /// The character's bidirectional embedding level (UAX #9); odd levels run right to left.
    pub level: u8,
}

/// One line of the paragraph, after breaking and alignment.
#[derive(Clone, Debug)]
pub struct LayoutLine {
    /// Indices into the layout's character list, in logical order.
    pub cells: Vec<usize>,
    pub width: f64,
    /// Left edge of the line's first advance.
    pub x: f64,
    /// Where the line's glyphs sit on.
    pub baseline: f64,
    /// The paragraph's direction, which decides which end of the line its text starts at.
    pub rtl: bool,
    /// The characters this line covers, as a half-open range of character indices. A line from an
    /// empty paragraph covers nothing and sits at the range's start.
    pub range: std::ops::Range<usize>,
    /// The characters in the order they are drawn, each with the pen position it starts at. A
    /// right-to-left line runs the other way from the line's logical cells.
    pub display: Vec<(usize, f64)>,
}

/// A glyph about to be drawn: which character it came from, and where its pen started.
#[derive(Clone, Copy, Debug)]
pub struct PositionedGlyph {
    /// Index of the character the glyph came from.
    pub cell: usize,
    /// Face to draw it with, an index into the layout's font list. A glyph can belong to another
    /// face than its neighbours when the requested face had no shape for the character.
    pub font: Option<usize>,
    pub glyph_id: u16,
    /// Pen position at the glyph's origin, before its own offsets.
    pub x: f64,
    pub baseline: f64,
    /// Where the shaper moved the glyph from its pen, in layer pixels and screen directions.
    pub x_offset: f64,
    pub y_offset: f64,
}

/// The name this type had before shaping, kept so callers written against it still build.
pub type PlacedGlyph = PositionedGlyph;

/// A whole paragraph laid out, ready to rasterize.
#[derive(Debug)]
pub struct TextLayout {
    pub width: u32,
    pub height: u32,
    pub padding: f64,
    pub line_height: f64,
    pub font_size: f32,
    pub tracking: f64,
    /// The faces this text needs, in the order they were first met.
    pub fonts: Vec<Arc<Font>>,
    pub chars: Vec<CharCell>,
    pub lines: Vec<LayoutLine>,
    pub glyphs: Vec<PositionedGlyph>,
    /// True when the text is laid out inside a fixed box rather than around its own measured size.
    pub boxed: bool,
    /// True when at least one run went through the shaper.
    pub shaped: bool,
    /// The distance from a baseline to the lowest point of the base face, which is where a line's
    /// box ends below its text.
    pub descent: f64,
    /// The direction of the first paragraph.
    pub direction: TextDirection,
    /// The library's face index for each entry of `fonts`, for callers that need the file.
    face_ids: Vec<usize>,
}

impl TextLayout {
    /// True when the raster fits the format's per-side and per-surface limits.
    pub fn fits_limits(&self) -> bool {
        limits::surface_fits(self.width, self.height)
    }

    /// The library's face index for one of this layout's fonts.
    pub fn face_index(&self, font: usize) -> Option<usize> {
        self.face_ids.get(font).copied().filter(|index| *index != usize::MAX)
    }
}

/// Where a layout spent its time, in nanoseconds.
///
/// The three stages add up to the whole layout, so a benchmark can say what to work on next rather
/// than guess. Shaping covers the shaper and the shaping cache; breaking covers finding the break
/// opportunities and filling the lines; everything else — resolving faces, advancing, placing glyphs
/// and splicing the paragraphs together — is assembly.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct StageTimes {
    pub shaping_ns: u64,
    pub breaking_ns: u64,
    pub assembly_ns: u64,
}

impl StageTimes {
    /// The whole layout.
    pub fn total_ns(&self) -> u64 {
        self.shaping_ns + self.breaking_ns + self.assembly_ns
    }

    pub fn millis(&self) -> f64 {
        self.total_ns() as f64 / 1_000_000.0
    }

    /// Adds another measurement into this one, which is how the paragraphs are totalled up.
    pub fn add(&mut self, other: StageTimes) {
        self.shaping_ns += other.shaping_ns;
        self.breaking_ns += other.breaking_ns;
        self.assembly_ns += other.assembly_ns;
    }
}

/// Everything that changes how one paragraph is laid out.
///
/// The paragraph's own text, its runs clipped to it, and the width it wraps inside: two paragraphs
/// with the same content and the same style share an entry wherever they sit in the document. What
/// the paragraph does *not* depend on is deliberately absent — alignment, the box's height and the
/// line each paragraph starts on are applied when the paragraphs are spliced back together.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub(crate) struct ParagraphKey {
    text: String,
    font_name: String,
    font_size: u64,
    tracking: u64,
    leading: u64,
    color: [u64; 3],
    color_runs: Vec<(usize, usize, [u64; 3])>,
    font_runs: Vec<(usize, usize, String)>,
    /// The width the paragraph wraps inside, in bits.
    wrap_width: u64,
    shaping: bool,
    direction: ParagraphDirection,
}

impl ParagraphKey {
    fn of(style: &TextStyle, options: LayoutOptions, wrap_width: f64) -> ParagraphKey {
        ParagraphKey {
            text: style.content.clone(),
            font_name: style.font_name.clone(),
            font_size: style.font_size.to_bits(),
            tracking: style.tracking.to_bits(),
            leading: style.leading.to_bits(),
            color: [style.red.to_bits(), style.green.to_bits(), style.blue.to_bits()],
            color_runs: style
                .color_runs
                .iter()
                .flatten()
                .map(|run| (run.location, run.length, [run.red.to_bits(), run.green.to_bits(), run.blue.to_bits()]))
                .collect(),
            font_runs: style
                .font_runs
                .iter()
                .flatten()
                .map(|run| (run.location, run.length, run.font_name.clone()))
                .collect(),
            wrap_width: wrap_width.to_bits(),
            shaping: options.shaping,
            direction: options.direction,
        }
    }
}

/// One paragraph, laid out in its own coordinates.
///
/// Character indices start at zero, a font index indexes this paragraph's own font list, and a
/// baseline is measured from the paragraph's first line, so the same paragraph can be spliced into a
/// text wherever it sits.
#[derive(Debug)]
pub(crate) struct ParagraphLayout {
    chars: Vec<CharCell>,
    fonts: Vec<Arc<Font>>,
    lines: Vec<LayoutLine>,
    glyphs: Vec<PositionedGlyph>,
    shaped: bool,
    rtl: bool,
    descent: f64,
}

/// A glyph as the shaper produced it, before it is placed on a line.
#[derive(Clone, Copy, Debug)]
struct RunGlyph {
    cell: usize,
    font: Option<usize>,
    glyph_id: u16,
    x_advance: f64,
    x_offset: f64,
    y_offset: f64,
}

/// Consecutive characters sharing a direction, a face and a script, shaped together.
#[derive(Debug)]
struct ShapedRun {
    /// True when the shaper ran for this run and produced glyphs, so a character of this run with no
    /// glyph of its own was merged into a neighbour instead of being measured on its own.
    shaped: bool,
    cells: std::ops::Range<usize>,
    glyphs: Vec<RunGlyph>,
}

/// A stretch of characters that can be shaped together: one direction, one face, one script.
#[derive(Clone, Copy, Debug)]
struct Run {
    start: usize,
    end: usize,
    font: Option<usize>,
    script: ShaperScript,
    level: u8,
}

impl TextLayout {
    /// The face a font of this layout came from, by this layout's own font index. A caller that has
    /// the font but not the library needs this to reach the face's tables — reading backwards from
    /// the loaded font to the library is not reliable, because the layout may hold a face the library
    /// has since replaced.
    pub(crate) fn face_id(&self, index: usize) -> Option<usize> {
        self.face_ids.get(index).copied().filter(|face| *face != usize::MAX)
    }
}

/// Lays out a text layer, shaping its text.
pub fn layout_text(style: &TextStyle, library: &mut FontLibrary) -> TextLayout {
    layout_text_with(style, library, LayoutOptions::default())
}

/// Lays out a text layer with explicit options.
pub fn layout_text_with(style: &TextStyle, library: &mut FontLibrary, options: LayoutOptions) -> TextLayout {
    let font_size = safe_font_size(style);
    let line_height = safe_line_height(style, font_size);
    let tracking = safe_tracking(style);
    let padding = TEXT_PADDING;
    let spans = char_spans(&style.content);
    let paragraph_ranges = paragraphs(&spans);

    // A fixed box wraps inside its padding; point text is as wide as it needs to be, which is how
    // the macOS app measures it (a container far wider than any line).
    let boxed = style.box_size.is_some();
    let wrap_width = style
        .box_size
        .map(|size| (size.width - 2.0 * padding).max(1.0))
        .unwrap_or(f64::INFINITY);
    let total_utf16 = spans.last().map(|span| span.utf16_start + span.utf16_len).unwrap_or(0);

    // One entry per paragraph, keyed by its own text: the line breaks between paragraphs are not
    // part of any paragraph, so two paragraphs with the same text share an entry wherever they sit.
    let mut stages = StageTimes::default();
    let mut laid_paragraphs: Vec<(usize, usize, Arc<ParagraphLayout>)> = Vec::with_capacity(paragraph_ranges.len());
    for range in &paragraph_ranges {
        let looked_up = std::time::Instant::now();
        let utf16_start = spans.get(range.start).map(|span| span.utf16_start).unwrap_or(total_utf16);
        let utf16_end = spans.get(range.end).map(|span| span.utf16_start).unwrap_or(total_utf16);
        let local = paragraph_style(style, &spans, range.clone(), utf16_start, utf16_end);
        let key = ParagraphKey::of(&local, options, wrap_width);
        let laid = match library.cached_paragraph(&key) {
            Some(cached) => {
                stages.assembly_ns += looked_up.elapsed().as_nanos() as u64;
                cached
            }
            None => {
                let (laid, times) = layout_paragraph(
                    &local, library, options, font_size, line_height, tracking, wrap_width, padding,
                );
                stages.add(times);
                library.store_paragraph(key, laid)
            }
        };
        laid_paragraphs.push((range.start, utf16_start, laid));
    }

    let splicing_started = std::time::Instant::now();
    let mut fonts: Vec<Arc<Font>> = Vec::new();
    let mut face_ids: Vec<usize> = Vec::new();
    let mut chars: Vec<CharCell> = Vec::with_capacity(spans.len());
    let mut lines: Vec<LayoutLine> = Vec::new();
    let mut glyphs: Vec<PositionedGlyph> = Vec::new();
    let mut shaped = false;
    let mut direction = TextDirection::LeftToRight;
    for (index, (char_start, utf16_start, laid)) in laid_paragraphs.iter().enumerate() {
        let mut remap = Vec::with_capacity(laid.fonts.len());
        for font in &laid.fonts {
            remap.push(intern(&mut fonts, &mut face_ids, library, font.clone()));
        }
        for cell in &laid.chars {
            let mut cell = cell.clone();
            cell.utf16_start += utf16_start;
            cell.font = cell.font.map(|local| remap[local]);
            chars.push(cell);
        }
        // The line breaks that separate this paragraph from the next belong to the text but not to
        // any paragraph, so they are made here rather than cached. They never reach a line.
        if let Some(next) = paragraph_ranges.get(index + 1) {
            let paragraph_end = laid_paragraphs[index].0 + laid.chars.len();
            let base = remap.first().copied();
            for span in &spans[paragraph_end..next.start] {
                let advance = match base.and_then(|index| fonts.get(index)) {
                    Some(font) => font.metrics(span.ch, font_size).advance_width as f64,
                    None => font_size as f64 * FALLBACK_ADVANCE_RATIO,
                };
                let (red, green, blue) = style.color_at(span.utf16_start);
                chars.push(CharCell {
                    ch: span.ch,
                    utf16_start: span.utf16_start,
                    utf16_len: span.utf16_len,
                    font: base,
                    advance,
                    color: [channel(red), channel(green), channel(blue)],
                    level: 0,
                });
            }
        }
        // A paragraph's lines start where the paragraphs before it left off, which is the "translate
        // the rest of the document" half of typing: nothing is laid out again, only moved.
        let line_offset = lines.len();
        let shifted = line_height * line_offset as f64;
        for line in &laid.lines {
            let mut line = line.clone();
            line.cells = line.cells.iter().map(|cell| cell + char_start).collect();
            line.display = line.display.iter().map(|(cell, x)| (cell + char_start, *x)).collect();
            line.range = (line.range.start + char_start)..(line.range.end + char_start);
            line.baseline += shifted;
            lines.push(line);
        }
        for glyph in &laid.glyphs {
            let mut glyph = *glyph;
            glyph.cell += char_start;
            glyph.baseline += shifted;
            glyphs.push(glyph);
        }
        shaped |= laid.shaped;
        if index == 0 {
            direction = if laid.rtl { TextDirection::RightToLeft } else { TextDirection::LeftToRight };
        }
    }

    let block_width = lines.iter().fold(0.0f64, |widest, line| widest.max(line.width));
    let align_width = match style.box_size {
        Some(size) => (size.width - 2.0 * padding).max(1.0),
        None => block_width,
    };
    let align_factor = match style.alignment {
        TextAlignment::Left => 0.0,
        TextAlignment::Center => 0.5,
        TextAlignment::Right => 1.0,
    };
    let line_count = lines.len().max(1) as f64;
    let descent = laid_paragraphs.first().map(|(_, _, laid)| laid.descent).unwrap_or(font_size as f64 * 0.25);
    // Alignment moves each line on its own, so the characters it drew move with it: a line that is
    // narrower than the box sits further along, and the glyphs placed inside the paragraph follow.
    let mut shifted_cells = vec![0.0f64; chars.len()];
    for (index, line) in lines.iter_mut().enumerate() {
        let delta = (align_width - line.width) * align_factor;
        line.x = padding + delta;
        line.baseline = baseline_at(index, padding, line_height, descent);
        if delta != 0.0 {
            line.display = line.display.iter().map(|(cell, x)| (*cell, x + delta)).collect();
            for &cell in &line.cells {
                shifted_cells[cell] = delta;
            }
        }
    }
    for glyph in glyphs.iter_mut() {
        glyph.x += shifted_cells[glyph.cell];
    }

    let (width, height) = match style.box_size {
        Some(size) => (size.width, size.height),
        None => (
            block_width + 2.0 * padding + font_size as f64 * 0.1,
            line_count * line_height + 2.0 * padding,
        ),
    };
    let width = raster_side(width, MIN_TEXT_SIDE);
    let height = raster_side(height, MIN_TEXT_SIDE);
    stages.assembly_ns += splicing_started.elapsed().as_nanos() as u64;
    library.report_stages(stages);

    TextLayout {
        width,
        height,
        padding,
        line_height,
        font_size,
        tracking,
        fonts,
        chars,
        lines,
        glyphs,
        boxed,
        shaped,
        descent,
        direction,
        face_ids,
    }
}

/// The style of one block of text: its own characters, and the run offsets moved to its start.
fn paragraph_style(
    style: &TextStyle,
    spans: &[CharSpan],
    range: std::ops::Range<usize>,
    utf16_start: usize,
    utf16_end: usize,
) -> TextStyle {
    let mut local = style.clone();
    local.content = spans[range].iter().map(|span| span.ch).collect();
    local.color_runs = style.color_runs.as_ref().map(|runs| {
        runs.iter()
            .filter_map(|run| clip_run(run.location, run.length, utf16_start, utf16_end).map(|(location, length)| {
                TextColorRun { location, length, red: run.red, green: run.green, blue: run.blue }
            }))
            .collect()
    });
    local.font_runs = style.font_runs.as_ref().map(|runs| {
        runs.iter()
            .filter_map(|run| {
                clip_run(run.location, run.length, utf16_start, utf16_end).map(|(location, length)| TextFontRun {
                    location,
                    length,
                    font_name: run.font_name.clone(),
                })
            })
            .collect()
    });
    local
}

/// The part of a run that falls inside a range, moved to the range's start, or none when it falls
/// outside it. A run that covers the whole text becomes one run per paragraph.
fn clip_run(location: usize, length: usize, start: usize, end: usize) -> Option<(usize, usize)> {
    let run_end = location.checked_add(length)?;
    let clipped_start = location.max(start);
    let clipped_end = run_end.min(end);
    (clipped_end > clipped_start).then(|| (clipped_start - start, clipped_end - clipped_start))
}

/// Lays out one paragraph on its own, which is the unit the layout cache holds.
#[allow(clippy::too_many_arguments)]
fn layout_paragraph(
    style: &TextStyle,
    library: &mut FontLibrary,
    options: LayoutOptions,
    font_size: f32,
    line_height: f64,
    tracking: f64,
    wrap_width: f64,
    padding: f64,
) -> (ParagraphLayout, StageTimes) {
    let started = std::time::Instant::now();
    let spans = char_spans(&style.content);
    // The block carries the line break that ends it; only the paragraph before that break is text.
    let text_range = paragraphs(&spans).first().cloned().unwrap_or(0..0);

    // The style's own face places every baseline, as the macOS app's single paragraph style does,
    // even on a line whose characters were all switched to another face.
    let base_font = library.font_for(&style.font_name);
    let descent =
        base_font.as_ref().map(|font| font_descent(font, font_size)).unwrap_or(font_size as f64 * 0.25);

    let mut fonts: Vec<Arc<Font>> = Vec::new();
    let mut face_ids: Vec<usize> = Vec::new();
    if let Some(font) = &base_font {
        intern(&mut fonts, &mut face_ids, library, font.clone());
    }
    let mut faces: HashMap<String, Option<usize>> = HashMap::new();
    let mut chars: Vec<CharCell> = Vec::with_capacity(spans.len());
    for span in &spans {
        let name = font_name_at(style, span.utf16_start).to_string();
        let mut index = match faces.get(&name) {
            Some(cached) => *cached,
            None => {
                let resolved =
                    library.font_for(&name).map(|font| intern(&mut fonts, &mut face_ids, library, font));
                faces.insert(name, resolved);
                resolved
            }
        };
        let mut font = index.map(|index| fonts[index].clone()).or_else(|| base_font.clone());
        // A joiner or a variation selector steers the shaper; it must not send the text to another
        // face just because this one has no glyph of its own for it. Whitespace never draws anyway.
        if !span.ch.is_whitespace() && !span.ch.is_control() && !is_default_ignorable(span.ch) {
            if let Some(linked) = library.glyph_font(font.as_ref(), span.ch) {
                let already_drawn = font.as_ref().map(|current| Arc::ptr_eq(current, &linked)).unwrap_or(false);
                if !already_drawn {
                    index = Some(intern(&mut fonts, &mut face_ids, library, linked.clone()));
                    font = Some(linked);
                }
            }
        }
        let (red, green, blue) = style.color_at(span.utf16_start);
        chars.push(CharCell {
            ch: span.ch,
            utf16_start: span.utf16_start,
            utf16_len: span.utf16_len,
            font: index,
            advance: 0.0,
            color: [channel(red), channel(green), channel(blue)],
            level: 0,
        });
    }

    // The bidirectional levels of the paragraph's text, and the direction it resolved to. The break
    // characters that end the block are not part of a line and keep level zero.
    let widest = text_range.end;
    let (levels, bases) = bidi_levels(&spans[..widest], &[0..widest], options.direction);
    for (cell, level) in chars.iter_mut().zip(&levels) {
        cell.level = *level;
    }
    let rtl = bases.first().copied().unwrap_or(TextDirection::LeftToRight).is_rtl();

    // What each character would measure on its own: both the unshaped layout and the fallback for a
    // run the shaper could not take.
    let fallback: Vec<f64> = chars.iter().map(|cell| unshaped_advance(cell, &fonts, font_size)).collect();
    let mut runs = Vec::new();
    let shaping_started = std::time::Instant::now();
    if options.shaping {
        shape_paragraph(&chars, &fallback, &mut fonts, &mut face_ids, library, font_size, tracking, &mut runs);
    } else {
        unshaped_runs(&chars, &fallback, &fonts, &mut runs);
    }
    let shaping_ns = shaping_started.elapsed().as_nanos() as u64;
    apply_advances(&mut chars, &runs, &fallback);

    let indices: Vec<usize> = (0..widest).collect();
    let mut broken = Vec::new();
    let breaking_started = std::time::Instant::now();
    wrap_paragraph(&indices, &chars, wrap_width, tracking, &mut broken);
    let breaking_ns = breaking_started.elapsed().as_nanos() as u64;
    let mut lines: Vec<LayoutLine> = Vec::new();
    for cells in broken {
        let width = measure(&cells, &chars, tracking);
        // A line covers the characters it drew; one from an empty paragraph covers none and sits
        // where that paragraph starts, which is where its caret belongs.
        let range = match (cells.first(), cells.last()) {
            (Some(&first), Some(&last)) => first..last + 1,
            _ => 0..0,
        };
        lines.push(LayoutLine { cells, width, x: padding, baseline: 0.0, rtl, range, display: Vec::new() });
    }
    for (index, line) in lines.iter_mut().enumerate() {
        line.baseline = baseline_at(index, padding, line_height, descent);
    }

    let mut glyphs = Vec::new();
    place_glyphs(&chars, &mut lines, &runs, tracking, &levels, &mut glyphs);

    // Whatever is left of the paragraph's own time is the work that is neither shaping nor
    // breaking: resolving faces, advancing, placing glyphs.
    let assembly_ns = (started.elapsed().as_nanos() as u64).saturating_sub(shaping_ns + breaking_ns);

    (
        ParagraphLayout {
            chars,
            fonts,
            lines,
            glyphs,
            shaped: runs.iter().any(|run| run.shaped),
            rtl,
            descent,
        },
        StageTimes { shaping_ns, breaking_ns, assembly_ns },
    )
}

/// The embedding level of every character, per UAX #9, and the direction each paragraph resolved to.
///
/// Paragraphs are resolved on their own, so Auto is the first strong character of *that* paragraph
/// rather than of the whole text, and a right-to-left paragraph does not drag its neighbours with it.
fn bidi_levels(
    spans: &[CharSpan],
    ranges: &[std::ops::Range<usize>],
    direction: ParagraphDirection,
) -> (Vec<u8>, Vec<TextDirection>) {
    let default = match direction {
        ParagraphDirection::Auto => None,
        ParagraphDirection::LeftToRight => Some(Level::ltr()),
        ParagraphDirection::RightToLeft => Some(Level::rtl()),
    };
    let mut levels = vec![0u8; spans.len()];
    let mut bases = Vec::with_capacity(ranges.len());
    for range in ranges {
        let text: String = spans[range.clone()].iter().map(|span| span.ch).collect();
        let info = BidiInfo::new(&text, default);
        let base = info.paragraphs.first().map(|paragraph| paragraph.level).unwrap_or(Level::ltr());
        bases.push(if base.is_rtl() { TextDirection::RightToLeft } else { TextDirection::LeftToRight });
        // Levels are indexed by byte offset, so the walk keeps its own byte cursor.
        let mut byte = 0;
        for (offset, span) in spans[range.clone()].iter().enumerate() {
            let level = info.levels.get(byte).copied().unwrap_or(base);
            levels[range.start + offset] = level.number();
            byte += span.ch.len_utf8();
        }
    }
    (levels, bases)
}

/// UAX #9 rule L2: the order the characters of one line are drawn in.
///
/// Every run at the highest level is reversed first, then the next level down, until the lowest odd
/// level has been reversed. That is what turns a right-to-left paragraph around while leaving an
/// embedded left-to-right number reading the right way.
fn display_order(cells: &[usize], levels: &[u8]) -> Vec<usize> {
    let mut order: Vec<usize> = cells.to_vec();
    let highest = cells.iter().map(|&cell| levels[cell]).max().unwrap_or(0);
    let Some(lowest_odd) = cells.iter().map(|&cell| levels[cell]).filter(|level| level % 2 == 1).min()
    else {
        return order;
    };
    for level in (lowest_odd..=highest).rev() {
        let mut index = 0;
        while index < order.len() {
            if levels[order[index]] >= level {
                let start = index;
                while index < order.len() && levels[order[index]] >= level {
                    index += 1;
                }
                order[start..index].reverse();
            } else {
                index += 1;
            }
        }
    }
    order
}

/// The baseline of one line: a fixed line height leaves its extra room above the letters, so the
/// baseline sits the face's descent up from the bottom of the line.
pub fn baseline_at(index: usize, padding: f64, line_height: f64, descent: f64) -> f64 {
    padding + line_height * (index as f64 + 1.0) - descent
}

/// The distance from the baseline to the lowest point of the face at this size.
pub fn font_descent(font: &Font, px: f32) -> f64 {
    font.horizontal_line_metrics(px).map(|metrics| metrics.descent.abs() as f64).unwrap_or(px as f64 * 0.25)
}

/// Sums the advances of a run of cells, with tracking between them — which is why the last glyph has
/// no tracking after it, exactly as Core Text's kerning attribute applies it.
pub fn measure(cells: &[usize], chars: &[CharCell], tracking: f64) -> f64 {
    if cells.is_empty() {
        return 0.0;
    }
    let advances: f64 = cells.iter().map(|&index| chars[index].advance).sum();
    (advances + tracking * (cells.len() as f64 - 1.0)).max(0.0)
}

/// True for a character that exists only to steer the shaper: a joiner, a variation selector, a
/// direction mark. None of them draws, and none should send text to another face.
pub fn is_default_ignorable(ch: char) -> bool {
    matches!(ch as u32,
        0x00AD | 0x034F | 0x061C | 0x115F..=0x1160 | 0x17B4..=0x17B5 | 0x180B..=0x180F
        | 0x200B..=0x200F | 0x202A..=0x202E | 0x2060..=0x206F | 0x3164 | 0xFE00..=0xFE0F
        | 0xFEFF | 0xFFA0 | 0x1BCA0..=0x1BCA3 | 0x1D173..=0x1D17A | 0xE0000..=0xE0FFF)
}

/// True for a character that ends a line rather than being drawn.
fn is_line_break(ch: char) -> bool {
    matches!(ch, '\n' | '\r')
}

/// The character as it is drawn at a bidirectional level: UAX #9 rule L4 turns a bracket round in a
/// right-to-left run, keeps a bracket in a left-to-right run as it is, and never touches a symbol
/// without a pair.
///
/// The pairs come from Unicode's BidiMirroring.txt, read through the unicode-bidi-mirroring table.
/// A shaped run does not need this: the shaper applies the same rule, and does it better, because a
/// font can carry a mirrored glyph of its own for the character (the `rtlm` feature) before the
/// table is consulted. Pre-mirroring a shaped run would be undone by the shaper and leave the
/// bracket as it started, which is what a test here pins down. The unshaped layout has no shaper, so
/// it mirrors the character itself.
pub fn mirrored_char(ch: char, level: u8) -> char {
    if level % 2 == 0 {
        return ch;
    }
    unicode_bidi_mirroring::get_mirrored(ch).unwrap_or(ch)
}

/// True for characters that put ink on the raster. Whitespace advances the pen but draws nothing,
/// and a default-ignorable never shows at all.
pub fn is_drawable(ch: char) -> bool {
    !ch.is_whitespace() && !ch.is_control() && !is_default_ignorable(ch)
}

/// The script of a character, or none when it belongs to whatever run surrounds it.
fn script_of(ch: char) -> Option<ShaperScript> {
    let short = ch.script().short_name();
    if short == "Zyyy" || short == "Zinh" {
        return None;
    }
    let bytes: [u8; 4] = short.as_bytes().try_into().ok()?;
    ShaperScript::from_iso15924_tag(rustybuzz::ttf_parser::Tag::from_bytes(&bytes))
}

/// The script a run starting at an offset is shaped as: the first character that names one, or Latin
/// when the run is all punctuation and digits.
fn run_script(chars: &[CharCell], start: usize) -> ShaperScript {
    for cell in &chars[start..] {
        if is_line_break(cell.ch) {
            break;
        }
        if let Some(script) = script_of(cell.ch) {
            return script;
        }
    }
    rustybuzz::script::LATIN
}

/// The stretches of characters that can be shaped together: a face change or a script change ends
/// one and starts the next, and an explicit line break ends one too.
fn runs_in(chars: &[CharCell]) -> Vec<Run> {
    let mut runs = Vec::new();
    let mut index = 0;
    while index < chars.len() {
        if is_line_break(chars[index].ch) {
            index += 1;
            continue;
        }
        let font = chars[index].font;
        let level = chars[index].level;
        let script = run_script(chars, index);
        let start = index;
        index += 1;
        while index < chars.len() {
            let next = &chars[index];
            // A direction change is a run boundary: the shaper takes one direction per buffer.
            if is_line_break(next.ch) || next.font != font || next.level != level {
                break;
            }
            // Common and inherited characters join whatever run they are in; a named script that
            // differs needs a run of its own, since the shaper takes one script per buffer.
            if font.is_some() {
                if let Some(other) = script_of(next.ch) {
                    if other != script {
                        break;
                    }
                }
            }
            index += 1;
        }
        runs.push(Run { start, end: index, font, script, level });
    }
    runs
}

/// Shapes every run of a paragraph, in the face it is set in, reusing what the shaping cache holds.
fn shape_paragraph(
    chars: &[CharCell],
    fallback: &[f64],
    fonts: &mut Vec<Arc<Font>>,
    face_ids: &mut Vec<usize>,
    library: &mut FontLibrary,
    font_size: f32,
    tracking: f64,
    out: &mut Vec<ShapedRun>,
) {
    for run in runs_in(chars) {
        let Some(font_index) = run.font else {
            out.push(synthetic_run(chars, fallback, run.start, run.end));
            continue;
        };
        let Some(library_index) = face_ids.get(font_index).copied().filter(|index| *index != usize::MAX) else {
            out.push(synthetic_run(chars, fallback, run.start, run.end));
            continue;
        };
        // The run's own text, and where each character starts in it, so a shaped cluster can be
        // handed back to the character it came from.
        let mut text = String::new();
        let mut cell_at_byte: HashMap<u32, usize> = HashMap::new();
        for cell in run.start..run.end {
            cell_at_byte.insert(text.len() as u32, cell);
            text.push(chars[cell].ch);
        }
        let key = ShapeKey::new(
            library_index,
            run.script.tag().to_bytes(),
            run.level % 2 == 1,
            font_size,
            tracking,
            text.clone(),
        );
        let shaped = match library.cached_shape(&key) {
            Some(cached) => cached,
            None => {
                let Some(glyphs) = shape_fragment(library, library_index, &text, run.script, run.level, font_size)
                else {
                    out.push(synthetic_run(chars, fallback, run.start, run.end));
                    continue;
                };
                library.store_shape(key, glyphs)
            }
        };
        let mut glyphs: Vec<RunGlyph> = shaped
            .iter()
            .filter_map(|glyph| {
                cell_at_byte.get(&glyph.cluster).map(|&cell| RunGlyph {
                    cell,
                    font: Some(font_index),
                    glyph_id: glyph.glyph_id,
                    x_advance: glyph.x_advance,
                    x_offset: glyph.x_offset,
                    y_offset: glyph.y_offset,
                })
            })
            .collect();
        // A glyph the shaper left as the missing-glyph box gets one more chance in a face that has
        // the character: a face can claim a character its shaping tables cannot produce.
        for glyph in glyphs.iter_mut() {
            if glyph.glyph_id != 0 {
                continue;
            }
            let ch = chars[glyph.cell].ch;
            if !is_drawable(ch) {
                continue;
            }
            let current = glyph.font.and_then(|index| fonts.get(index)).cloned();
            let Some(rescued) =
                rescue_glyph(ch, run.script, run.level, font_size, fonts, face_ids, library, current.as_ref())
            else {
                continue;
            };
            *glyph = RunGlyph { cell: glyph.cell, ..rescued };
        }
        out.push(ShapedRun { shaped: !glyphs.is_empty(), cells: run.start..run.end, glyphs });
    }
}

/// Shapes one run of text in one face, and hands back the glyphs in layer pixels, in the order the
/// shaper returned them. The result depends on nothing but its arguments, which is what makes it
/// worth keeping: the caller caches it under the same facts.
fn shape_fragment(
    library: &mut FontLibrary,
    library_index: usize,
    text: &str,
    script: ShaperScript,
    level: u8,
    font_size: f32,
) -> Option<Vec<ShapedGlyph>> {
    let collection = library.face(library_index)?.collection_index;
    let data = library.face_bytes(library_index)?;
    let face = ShaperFace::from_slice(&data, collection)?;
    let units_per_em = face.units_per_em();
    if units_per_em <= 0 {
        return None;
    }
    let mut buffer = UnicodeBuffer::new();
    buffer.push_str(text);
    buffer.set_script(script);
    // The direction comes from the bidirectional level rather than from the script, so a number
    // inside a right-to-left paragraph is shaped left to right. The empty feature list means the
    // font's own defaults, which is where kerning, ligatures and mark positioning live.
    buffer.set_direction(if level % 2 == 1 { Direction::RightToLeft } else { Direction::LeftToRight });
    let output = rustybuzz::shape(&face, &[], buffer);
    let scale = font_size as f64 / units_per_em as f64;
    let mut glyphs = Vec::with_capacity(output.glyph_infos().len());
    for (info, position) in output.glyph_infos().iter().zip(output.glyph_positions()) {
        glyphs.push(ShapedGlyph {
            cluster: info.cluster,
            glyph_id: info.glyph_id as u16,
            x_advance: position.x_advance as f64 * scale,
            x_offset: position.x_offset as f64 * scale,
            y_offset: position.y_offset as f64 * scale,
        });
    }
    Some(glyphs)
}

/// Shapes one character again in a face that has it, for a glyph the shaper left as the
/// missing-glyph box.
fn rescue_glyph(
    ch: char,
    script: ShaperScript,
    level: u8,
    font_size: f32,
    fonts: &mut Vec<Arc<Font>>,
    face_ids: &mut Vec<usize>,
    library: &mut FontLibrary,
    current: Option<&Arc<Font>>,
) -> Option<RunGlyph> {
    let replacement = library.linked_font(current, ch)?;
    let replacement_index = library.index_of(&replacement)?;
    let collection = library.face(replacement_index)?.collection_index;
    let data = library.face_bytes(replacement_index)?;
    let face = ShaperFace::from_slice(&data, collection)?;
    if face.units_per_em() <= 0 {
        return None;
    }
    let mut buffer = UnicodeBuffer::new();
    buffer.push_str(&ch.to_string());
    buffer.set_script(script);
    // A single character has no neighbours to take a direction from, so its own level decides.
    buffer.set_direction(if level % 2 == 1 { Direction::RightToLeft } else { Direction::LeftToRight });
    let output = rustybuzz::shape(&face, &[], buffer);
    let (info, position) = output.glyph_infos().iter().zip(output.glyph_positions()).next()?;
    if info.glyph_id == 0 {
        return None;
    }
    let scale = font_size as f64 / face.units_per_em() as f64;
    let font = intern(fonts, face_ids, library, replacement);
    Some(RunGlyph {
        cell: 0,
        font: Some(font),
        glyph_id: info.glyph_id as u16,
        x_advance: position.x_advance as f64 * scale,
        x_offset: position.x_offset as f64 * scale,
        y_offset: position.y_offset as f64 * scale,
    })
}

/// One glyph per character for a run the shaper could not take, so text keeps a caret, a width and a
/// place even when no face could be loaded.
fn synthetic_run(chars: &[CharCell], fallback: &[f64], start: usize, end: usize) -> ShapedRun {
    let glyphs = (start..end)
        .filter(|&cell| chars[cell].font.is_none())
        .map(|cell| RunGlyph {
            cell,
            font: None,
            glyph_id: 0,
            x_advance: fallback[cell],
            x_offset: 0.0,
            y_offset: 0.0,
        })
        .collect();
    ShapedRun { shaped: false, cells: start..end, glyphs }
}

/// One glyph per character, measured by the font itself: the layout this crate had before shaping.
fn unshaped_runs(chars: &[CharCell], fallback: &[f64], fonts: &[Arc<Font>], out: &mut Vec<ShapedRun>) {
    for run in runs_in(chars) {
        let glyphs = (run.start..run.end)
            .filter(|&cell| is_drawable(chars[cell].ch))
            .map(|cell| RunGlyph {
                cell,
                font: run.font,
                glyph_id: run
                    .font
                    .map(|index| fonts[index].lookup_glyph_index(mirrored_char(chars[cell].ch, chars[cell].level)))
                    .unwrap_or(0),
                x_advance: fallback[cell],
                x_offset: 0.0,
                y_offset: 0.0,
            })
            .collect();
        out.push(ShapedRun { shaped: false, cells: run.start..run.end, glyphs });
    }
}

/// The advance a character has on its own, without shaping.
fn unshaped_advance(cell: &CharCell, fonts: &[Arc<Font>], font_size: f32) -> f64 {
    let Some(font) = cell.font.and_then(|index| fonts.get(index)) else {
        return font_size as f64 * FALLBACK_ADVANCE_RATIO;
    };
    if cell.ch == '\t' {
        return font.metrics(' ', font_size).advance_width as f64 * TAB_SPACES;
    }
    font.metrics(cell.ch, font_size).advance_width as f64
}

/// Turns shaped glyphs back into one advance per character. A character a ligature swallowed keeps
/// no width of its own, which is what makes a line measure the same as the glyphs it draws.
fn apply_advances(chars: &mut [CharCell], runs: &[ShapedRun], fallback: &[f64]) {
    let mut advance = vec![0.0f64; chars.len()];
    let mut covered = vec![false; chars.len()];
    let mut merged = vec![false; chars.len()];
    for run in runs {
        for glyph in &run.glyphs {
            covered[glyph.cell] = true;
            advance[glyph.cell] += glyph.x_advance;
        }
        if run.shaped {
            for cell in run.cells.clone() {
                merged[cell] = true;
            }
        }
    }
    for (index, cell) in chars.iter_mut().enumerate() {
        cell.advance = if covered[index] {
            advance[index]
        } else if merged[index] {
            0.0
        } else {
            fallback[index]
        };
    }
}

/// Gives every glyph its place on its line, and records where each character was drawn.
///
/// The characters are walked in display order (UAX #9 rule L2), so a right-to-left line runs the
/// other way round and an embedded left-to-right word stays readable. Within one character the
/// glyphs stay in the order the shaper returned them, which is visual order for that direction.
fn place_glyphs(
    chars: &[CharCell],
    lines: &mut [LayoutLine],
    runs: &[ShapedRun],
    tracking: f64,
    levels: &[u8],
    out: &mut Vec<PositionedGlyph>,
) {
    let mut by_cell: HashMap<usize, Vec<RunGlyph>> = HashMap::new();
    for run in runs {
        for glyph in &run.glyphs {
            by_cell.entry(glyph.cell).or_default().push(*glyph);
        }
    }
    let drawable: Vec<bool> = chars.iter().map(|cell| is_drawable(cell.ch)).collect();
    for line in lines.iter_mut() {
        let baseline = line.baseline;
        let order = display_order(&line.cells, levels);
        let mut pen = line.x;
        line.display.clear();
        for cell in order {
            line.display.push((cell, pen));
            if let Some(glyphs) = by_cell.get(&cell) {
                for glyph in glyphs {
                    if drawable[cell] {
                        out.push(positioned(glyph, pen, baseline));
                    }
                    pen += glyph.x_advance;
                }
            }
            // Tracking sits between characters, exactly as it does when a line is measured.
            pen += tracking;
        }
    }
}

fn positioned(glyph: &RunGlyph, pen: f64, baseline: f64) -> PositionedGlyph {
    PositionedGlyph {
        cell: glyph.cell,
        font: glyph.font,
        glyph_id: glyph.glyph_id,
        x: pen,
        baseline,
        x_offset: glyph.x_offset,
        y_offset: glyph.y_offset,
    }
}

/// The ranges of character indices that explicit line breaks separate. Content always has at least
/// one paragraph, so an empty text still has a line to put a caret on.
fn paragraphs(spans: &[CharSpan]) -> Vec<std::ops::Range<usize>> {
    let mut result = Vec::new();
    let mut start = 0;
    let mut index = 0;
    while index < spans.len() {
        let ch = spans[index].ch;
        if ch == '\n' || ch == '\r' {
            result.push(start..index);
            // A CRLF pair is one break, as every text editor treats it.
            if ch == '\r' && spans.get(index + 1).map(|span| span.ch) == Some('\n') {
                index += 1;
            }
            index += 1;
            start = index;
        } else {
            index += 1;
        }
    }
    result.push(start..spans.len());
    result
}

/// True for the whitespace a line may break at: a tab or a space, but not the no-break spaces that
/// exist precisely to keep words together.
fn is_break_space(ch: char) -> bool {
    matches!(ch, ' ' | '\t') || (ch.is_whitespace() && !matches!(ch, '\u{00A0}' | '\u{202F}' | '\u{FEFF}'))
}

/// Breaks one paragraph into lines no wider than the available width.
///
/// Where a line may end is Unicode's business, not the spaces': UAX #14 gives the break
/// opportunities, so Chinese and Japanese break between characters, a number keeps its digits and
/// its decimal point together, and closing punctuation is never left at the start of a line. A
/// stretch with no opportunity in it — a long Latin word, say — is broken between characters, as the
/// macOS layout manager does, and the East Asian line-start and line-end prohibitions are then
/// applied by hand, by ending the line earlier.
pub fn wrap_paragraph(
    indices: &[usize],
    chars: &[CharCell],
    available: f64,
    tracking: f64,
    out: &mut Vec<Vec<usize>>,
) {
    if indices.is_empty() {
        out.push(Vec::new());
        return;
    }
    let start = skip_leading_spaces(indices, chars, 0);
    if start == indices.len() {
        // A paragraph of nothing but spaces has no width to show.
        out.push(Vec::new());
        return;
    }
    let breaks = break_opportunities(indices, chars);
    let clusters = cluster_starts(indices, chars);
    let mut start = start;
    while start < indices.len() {
        let mut width = 0.0;
        let mut count = 0usize;
        let mut index = start;
        let mut last_break = None;
        while index < indices.len() {
            if index > start && breaks[index] {
                last_break = Some(index);
            }
            let advance = chars[indices[index]].advance + if count > 0 { tracking } else { 0.0 };
            if count > 0 && width + advance > available {
                break;
            }
            width += advance;
            count += 1;
            index += 1;
        }
        if index == indices.len() {
            push_line(out, indices, chars, start, indices.len());
            break;
        }
        // The line is full. It ends at the last opportunity before the character that overflowed,
        // or, when the text offers none, right before that character.
        let end = match last_break {
            Some(at) if at > start => at,
            _ => index,
        };
        let end = prohibited_break(chars, indices, &clusters, start, end);
        // A break may only fall between clusters: neither the last-resort break inside a run with no
        // opportunity in it nor the step kinsoku takes back from one may cut a cluster in half,
        // unless the whole cluster is wider than the box and has to be broken somewhere.
        let end = cluster_boundary_for(&clusters, start, end);
        // A line has to consume at least one character. Snapping to a cluster boundary can land back
        // on the start when the cluster that begins the line is itself wider than the box, and a line
        // that ends where it began would leave the outer loop with nothing to advance.
        let end = if end > start { end } else { (start + 1).min(indices.len()) };
        push_line(out, indices, chars, start, end);
        start = skip_leading_spaces(indices, chars, end);
    }
    if out.is_empty() {
        out.push(Vec::new());
    }
}

/// The positions a line may end at, from UAX #14: true at the index of a character that may begin a
/// line. The rules are read once per paragraph, on the paragraph's own text.
fn break_opportunities(indices: &[usize], chars: &[CharCell]) -> Vec<bool> {
    let mut text = String::new();
    let mut byte_of = Vec::with_capacity(indices.len());
    for &cell in indices {
        byte_of.push(text.len());
        text.push(chars[cell].ch);
    }
    let mut allowed = vec![false; indices.len()];
    let mut cursor = 0usize;
    for (byte, _) in unicode_linebreak::linebreaks(&text) {
        while cursor < byte_of.len() && byte_of[cursor] < byte {
            cursor += 1;
        }
        if cursor < allowed.len() && byte_of[cursor] == byte {
            allowed[cursor] = true;
        }
    }
    allowed
}

/// Pushes a line, without the spaces that would only hang off its end.
fn push_line(out: &mut Vec<Vec<usize>>, indices: &[usize], chars: &[CharCell], start: usize, end: usize) {
    let mut end = end;
    while end > start && is_break_space(chars[indices[end - 1]].ch) {
        end -= 1;
    }
    out.push(indices[start..end].to_vec());
}

/// The first index at or after one whose character is not a space a line may break at.
fn skip_leading_spaces(indices: &[usize], chars: &[CharCell], from: usize) -> usize {
    let mut index = from;
    while index < indices.len() && is_break_space(chars[indices[index]].ch) {
        index += 1;
    }
    index
}

/// Kinsoku: end the line earlier when it would otherwise begin with closing punctuation or end with
/// an opening bracket. UAX #14 already refuses those breaks, so this is what answers a line that has
/// to be broken by hand; ending earlier keeps the line inside the box, where squeezing the
/// punctuation in would not.
fn prohibited_break(
    chars: &[CharCell],
    indices: &[usize],
    clusters: &[bool],
    start: usize,
    end: usize,
) -> usize {
    let mut end = end;
    while end > start + 1 {
        // What matters is the character that would *begin* the next line, which is the first one that
        // is not a space the break skips, and the last character this line would draw, which is the
        // last one before the spaces a line drops from its end.
        let next = skip_leading_spaces(indices, chars, end);
        let begins_with_closing = next < indices.len() && cannot_start_a_line(chars[indices[next]].ch);
        let mut last = end;
        while last > start && is_break_space(chars[indices[last - 1]].ch) {
            last -= 1;
        }
        let ends_with_opening = last > start && cannot_end_a_line(chars[indices[last - 1]].ch);
        let between_clusters = clusters.get(end).copied().unwrap_or(true);
        if !begins_with_closing && !ends_with_opening && between_clusters {
            break;
        }
        end -= 1;
    }
    // One character is as far back as a line may be pulled; that is where a line broken by hand has
    // to give, and the cluster rule is answered by the caller.
    end
}

/// True at the character that begins a grapheme cluster, which is where a line may be broken. Read
/// once per paragraph, next to the break opportunities, so no line pays for a scan of its own.
fn cluster_starts(indices: &[usize], chars: &[CharCell]) -> Vec<bool> {
    let text: String = indices.iter().map(|&cell| chars[cell].ch).collect();
    let mut starts = vec![false; indices.len()];
    let mut position = 0usize;
    for cluster in text.graphemes(true) {
        if position < starts.len() {
            starts[position] = true;
        }
        position += cluster.chars().count();
    }
    starts
}

/// The nearest place to break between clusters, given where a line wants to end.
///
/// Backwards first, so a line never draws more than it has to. When there is no boundary after the
/// start the end is inside a cluster that begins where the line does, and the whole of it is taken:
/// forward to where it ends, which is no wider than the greedy pass already allowed. That search is
/// bounded, so a cluster longer than this is broken between characters rather than dragging a line.
fn cluster_boundary_for(starts: &[bool], start: usize, end: usize) -> usize {
    const LONGEST_CLUSTER: usize = 64;
    let mut at = end.min(starts.len());
    while at > start && !starts.get(at).copied().unwrap_or(true) {
        at -= 1;
    }
    if at > start {
        return at;
    }
    let mut at = end.min(starts.len());
    let limit = (start + LONGEST_CLUSTER).min(starts.len());
    while at < limit && !starts.get(at).copied().unwrap_or(true) {
        at += 1;
    }
    at.max(end)
}

/// True for a character that may not begin a line: the closing brackets, the full stops and commas
/// of East Asian text, the small kana, and the marks that hang off the character before them.
pub fn cannot_start_a_line(ch: char) -> bool {
    matches!(ch,
        '。' | '、' | '，' | '．' | '：' | '；' | '！' | '？' | '…' | '‥' | '・'
        | '）' | '］' | '｝' | '〉' | '》' | '」' | '』' | '】' | '〕' | '〗' | '〙' | '〛' | '｣'
        | 'ー' | '々' | '〻' | 'ゝ' | 'ゞ' | 'ヽ' | 'ヾ'
        | 'ぁ' | 'ぃ' | 'ぅ' | 'ぇ' | 'ぉ' | 'っ' | 'ゃ' | 'ゅ' | 'ょ' | 'ゎ'
        | 'ァ' | 'ィ' | 'ゥ' | 'ェ' | 'ォ' | 'ッ' | 'ャ' | 'ュ' | 'ョ' | 'ヮ' | 'ヵ' | 'ヶ'
        | ',' | '.' | '!' | '?' | ':' | ';' | ')' | ']' | '}' | '%' | '°')
}

/// True for a character that may not end a line: the opening brackets, and the quote marks that hang
/// off the character after them.
pub fn cannot_end_a_line(ch: char) -> bool {
    matches!(ch,
        '(' | '[' | '{' | '（' | '［' | '｛' | '〈' | '《' | '「' | '『' | '【' | '〔' | '〖' | '〘' | '〚' | '｢'
        | '‘' | '“' | '゛' | '゜')
}

/// Adds a face to the layout's font list, reusing the entry when the same face is already there.
fn intern(fonts: &mut Vec<Arc<Font>>, face_ids: &mut Vec<usize>, library: &FontLibrary, font: Arc<Font>) -> usize {
    if let Some(index) = fonts.iter().position(|existing| Arc::ptr_eq(existing, &font)) {
        return index;
    }
    let face = library.index_of(&font).unwrap_or(usize::MAX);
    fonts.push(font);
    face_ids.push(face);
    fonts.len() - 1
}

/// A raster side from a floating-point size, kept finite and inside the format's limits.
fn raster_side(value: f64, minimum: f64) -> u32 {
    let value = if value.is_finite() { value } else { minimum };
    value.ceil().clamp(1.0, limits::MAX_SIDE as f64) as u32
}

/// The font size actually laid out: a damaged style still lays out rather than panicking.
fn safe_font_size(style: &TextStyle) -> f32 {
    if style.font_size.is_finite() {
        style.font_size.clamp(1.0, 2000.0) as f32
    } else {
        16.0
    }
}

/// The line height actually used: zero leading means 120% of the size, as Photoshop's Auto does.
fn safe_line_height(style: &TextStyle, font_size: f32) -> f64 {
    let height = style.line_height();
    if height.is_finite() && height > 0.0 {
        height.clamp(1.0, 5000.0)
    } else {
        font_size as f64 * 1.2
    }
}

fn safe_tracking(style: &TextStyle) -> f64 {
    if style.tracking.is_finite() {
        style.tracking.clamp(-1000.0, 1000.0)
    } else {
        0.0
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    use comp_core::text::{SizeD, TextColorRun, TextFontRun};
    use std::collections::HashSet;

    /// A library with no faces: advances fall back to half the font size, so geometry is exact.
    fn bare_library() -> FontLibrary {
        FontLibrary::from_faces(Vec::new(), Vec::new())
    }

    /// The system library, or none when this machine has no fonts to test against.
    fn system_library() -> Option<FontLibrary> {
        let library = FontLibrary::new();
        (!library.is_empty()).then_some(library)
    }

    /// True when this machine really has the face, so a test can skip itself where it does not.
    fn has_face(library: &mut FontLibrary, name: &str) -> bool {
        library.resolved_name(name).is_some()
    }

    fn text(font: &str, content: &str, size: f64) -> TextStyle {
        TextStyle {
            content: content.to_string(),
            font_name: font.to_string(),
            font_size: size,
            ..TextStyle::default()
        }
    }

    fn width(layout: &TextLayout) -> f64 {
        layout.lines.first().map(|line| line.width).unwrap_or(0.0)
    }

    /// The glyphs drawn for one character. A ligature puts a whole cluster on its first character.
    fn glyphs_of(layout: &TextLayout, cell: usize) -> Vec<&PositionedGlyph> {
        layout.glyphs.iter().filter(|glyph| glyph.cell == cell).collect()
    }

    fn advances(layout: &TextLayout) -> Vec<f64> {
        layout.chars.iter().map(|cell| cell.advance).collect()
    }

    fn cells(text: &str, advance: f64) -> Vec<CharCell> {
        char_spans(text)
            .into_iter()
            .map(|span| CharCell {
                ch: span.ch,
                utf16_start: span.utf16_start,
                utf16_len: span.utf16_len,
                font: None,
                advance,
                color: [0, 0, 0],
                level: 0,
            })
            .collect()
    }

    fn wrapped(text: &str, advance: f64, available: f64) -> Vec<Vec<usize>> {
        let chars = cells(text, advance);
        let indices: Vec<usize> = (0..chars.len()).collect();
        let mut out = Vec::new();
        wrap_paragraph(&indices, &chars, available, 0.0, &mut out);
        out
    }

    fn line_text(cells: &[usize], chars: &[CharCell]) -> String {
        cells.iter().map(|&index| chars[index].ch).collect()
    }

    // ---- UTF-16 mapping -------------------------------------------------

    #[test]
    fn spans_count_utf16_units() {
        let spans = char_spans("a😀b");
        assert_eq!(spans.len(), 3);
        assert_eq!(spans[0], CharSpan { ch: 'a', utf16_start: 0, utf16_len: 1 });
        assert_eq!(spans[1], CharSpan { ch: '😀', utf16_start: 1, utf16_len: 2 });
        assert_eq!(spans[2], CharSpan { ch: 'b', utf16_start: 3, utf16_len: 1 });
    }

    #[test]
    fn spans_of_the_empty_string_are_empty() {
        assert!(char_spans("").is_empty());
    }

    #[test]
    fn font_runs_are_resolved_in_utf16_units() {
        let mut style = TextStyle { content: "a😀b".into(), ..TextStyle::default() };
        style.font_runs = Some(vec![TextFontRun { location: 1, length: 2, font_name: "Alt".into() }]);
        assert_eq!(font_name_at(&style, 0), "Helvetica");
        assert_eq!(font_name_at(&style, 1), "Alt");
        assert_eq!(font_name_at(&style, 2), "Alt");
        assert_eq!(font_name_at(&style, 3), "Helvetica");
        assert_eq!(style.utf16_len(), 4);
    }

    #[test]
    fn a_run_that_starts_inside_a_character_still_names_its_face() {
        let mut style = TextStyle { content: "a😀b".into(), ..TextStyle::default() };
        style.font_runs = Some(vec![TextFontRun { location: 2, length: 1, font_name: "Alt".into() }]);
        // The character begins at unit 1, so the face of unit 1 decides, not the half-covered one.
        assert_eq!(font_name_at(&style, 1), "Helvetica");
        assert_eq!(font_name_at(&style, 2), "Alt");
    }

    #[test]
    fn color_runs_are_resolved_in_utf16_units() {
        let mut style = TextStyle { content: "a😀b".into(), ..TextStyle::default() };
        style.color_runs =
            Some(vec![TextColorRun { location: 3, length: 1, red: 1.0, green: 0.5, blue: 0.0 }]);
        assert_eq!(style.color_at(0), (0.0, 0.0, 0.0));
        assert_eq!(style.color_at(3), (1.0, 0.5, 0.0));
        assert_eq!(channel(1.0), 255);
        assert_eq!(channel(0.5), 128);
        assert_eq!(channel(0.0), 0);
    }

    // ---- breaking and alignment -----------------------------------------

    #[test]
    fn paragraphs_split_on_explicit_breaks() {
        let spans = char_spans("one\ntwo\r\nthree");
        let ranges: Vec<std::ops::Range<usize>> = paragraphs(&spans);
        assert_eq!(ranges.len(), 3);
        assert_eq!(ranges[0], 0..3);
        assert_eq!(ranges[1], 4..7);
        assert_eq!(ranges[2], 9..14);
    }

    #[test]
    fn an_empty_text_still_has_one_paragraph() {
        assert_eq!(paragraphs(&char_spans("")).len(), 1);
        assert_eq!(paragraphs(&char_spans("a\n")).len(), 2);
    }

    #[test]
    fn wrapping_breaks_at_spaces() {
        // Six characters of ten pixels: "ab", a space and "cd" do not fit in 45.
        let chars = cells("ab cd", 10.0);
        let lines = wrapped("ab cd", 10.0, 45.0);
        assert_eq!(lines.len(), 2);
        assert_eq!(line_text(&lines[0], &chars), "ab");
        assert_eq!(line_text(&lines[1], &chars), "cd");
    }

    #[test]
    fn wrapping_drops_the_space_at_a_break() {
        let chars = cells("ab cd", 10.0);
        let lines = wrapped("ab cd", 10.0, 45.0);
        assert_eq!(line_text(&lines[1], &chars), "cd", "the break must not start with the space");
    }

    #[test]
    fn a_word_wider_than_the_line_is_broken_between_characters() {
        let chars = cells("abcdefgh", 10.0);
        let lines = wrapped("abcdefgh", 10.0, 25.0);
        assert_eq!(lines.len(), 4, "eight characters at ten pixels fit two per line");
        assert_eq!(line_text(&lines[0], &chars), "ab");
        assert_eq!(line_text(&lines[3], &chars), "gh");
        for line in &lines {
            assert!(measure(line, &chars, 0.0) <= 25.0);
        }
    }

    #[test]
    fn a_line_never_gives_up_making_progress() {
        // The box is narrower than one character; each line still takes one character.
        let chars = cells("abc", 10.0);
        let lines = wrapped("abc", 10.0, 1.0);
        assert_eq!(lines.len(), 3);
        assert_eq!(line_text(&lines[0], &chars), "a");
    }

    #[test]
    fn infinite_width_never_wraps() {
        let lines = wrapped("a very long line of words", 10.0, f64::INFINITY);
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].len(), 25);
    }

    #[test]
    fn leading_whitespace_of_a_wrapped_line_is_dropped() {
        let chars = cells("aa  bb", 10.0);
        let lines = wrapped("aa  bb", 10.0, 45.0);
        assert_eq!(line_text(&lines[1], &chars), "bb");
    }

    #[test]
    fn tracking_widens_every_gap_but_the_last() {
        let chars = cells("abc", 10.0);
        let indices = vec![0, 1, 2];
        assert_eq!(measure(&indices, &chars, 0.0), 30.0);
        assert_eq!(measure(&indices, &chars, 5.0), 40.0);
        assert_eq!(measure(&indices[..1], &chars, 5.0), 10.0, "one glyph has no gap after it");
        assert_eq!(measure(&[], &chars, 5.0), 0.0);
    }

    #[test]
    fn negative_tracking_never_measures_below_zero() {
        let chars = cells("ab", 1.0);
        assert_eq!(measure(&[0, 1], &chars, -50.0), 0.0);
    }

    #[test]
    fn baselines_follow_the_leading() {
        assert_eq!(baseline_at(0, 12.0, 100.0, 5.0), 107.0);
        assert_eq!(baseline_at(1, 12.0, 100.0, 5.0), 207.0);
        assert_eq!(baseline_at(2, 12.0, 100.0, 5.0) - baseline_at(1, 12.0, 100.0, 5.0), 100.0);
    }

    #[test]
    fn point_text_is_as_wide_as_its_lines() {
        let mut library = bare_library();
        let style = TextStyle { content: "abcd".into(), font_size: 20.0, ..TextStyle::default() };
        let layout = layout_text(&style, &mut library);
        assert!(!layout.boxed);
        let line_width = layout.lines[0].width;
        assert_eq!(line_width, 4.0 * 10.0);
        assert_eq!(layout.width as f64, (line_width + 2.0 * TEXT_PADDING + 2.0).ceil());
        assert_eq!(layout.height as f64, (20.0 * 1.2 + 2.0 * TEXT_PADDING).ceil());
    }

    #[test]
    fn a_box_sets_the_raster_size_exactly() {
        let mut library = bare_library();
        let style = TextStyle {
            content: "text in a box".into(),
            font_size: 10.0,
            box_size: Some(SizeD::new(200.0, 100.0)),
            ..TextStyle::default()
        };
        let layout = layout_text(&style, &mut library);
        assert!(layout.boxed);
        assert_eq!((layout.width, layout.height), (200, 100));
        assert_eq!(layout.lines[0].x, TEXT_PADDING);
    }

    #[test]
    fn a_tiny_box_still_lays_out() {
        let mut library = bare_library();
        let style = TextStyle {
            content: "wide text".into(),
            font_size: 10.0,
            box_size: Some(SizeD::new(16.0, 16.0)),
            ..TextStyle::default()
        };
        let layout = layout_text(&style, &mut library);
        assert_eq!((layout.width, layout.height), (16, 16));
        assert!(layout.lines.len() > 1, "text wider than the box has to break");
        assert!(layout.fits_limits());
    }

    #[test]
    fn alignment_moves_lines_inside_the_box() {
        let mut library = bare_library();
        let base = TextStyle {
            content: "aaaa\nbb".into(),
            font_size: 10.0,
            box_size: Some(SizeD::new(200.0, 100.0)),
            ..TextStyle::default()
        };
        let usable = 200.0 - 2.0 * TEXT_PADDING;
        let left = layout_text(&base, &mut library);
        assert_eq!(left.lines[0].x, TEXT_PADDING);
        assert_eq!(left.lines[1].x, TEXT_PADDING);

        let centered = layout_text(&TextStyle { alignment: TextAlignment::Center, ..base.clone() }, &mut library);
        assert_eq!(centered.lines[0].x, TEXT_PADDING + (usable - 4.0 * 5.0) * 0.5);
        assert_eq!(centered.lines[1].x, TEXT_PADDING + (usable - 2.0 * 5.0) * 0.5);

        let right = layout_text(&TextStyle { alignment: TextAlignment::Right, ..base.clone() }, &mut library);
        assert_eq!(right.lines[0].x, TEXT_PADDING + (usable - 4.0 * 5.0));
        assert_eq!(right.lines[1].x, TEXT_PADDING + (usable - 2.0 * 5.0));
    }

    #[test]
    fn point_text_aligns_inside_its_widest_line() {
        let mut library = bare_library();
        let style = TextStyle {
            content: "aaaa\nbb".into(),
            font_size: 10.0,
            alignment: TextAlignment::Right,
            ..TextStyle::default()
        };
        let layout = layout_text(&style, &mut library);
        // The widest line sets the block, so the short one moves right by their difference.
        assert_eq!(layout.lines[0].x, TEXT_PADDING);
        assert_eq!(layout.lines[1].x, TEXT_PADDING + 10.0);
    }

    #[test]
    fn explicit_breaks_make_lines_without_a_box() {
        let mut library = bare_library();
        let style = TextStyle { content: "one\ntwo\n".into(), font_size: 10.0, ..TextStyle::default() };
        let layout = layout_text(&style, &mut library);
        assert_eq!(layout.lines.len(), 3);
        assert!(layout.lines[2].cells.is_empty());
    }

    #[test]
    fn auto_leading_is_120_percent_and_custom_leading_wins() {
        let mut library = bare_library();
        let auto = TextStyle { content: "a\nb".into(), font_size: 50.0, ..TextStyle::default() };
        let tall = layout_text(&auto, &mut library);
        assert_eq!(tall.line_height, 60.0);
        let custom = TextStyle { leading: 30.0, ..auto.clone() };
        let short = layout_text(&custom, &mut library);
        assert_eq!(short.line_height, 30.0);
        assert_eq!(short.lines[1].baseline - short.lines[0].baseline, 30.0);
        assert!(short.height < tall.height);
    }

    #[test]
    fn tracking_moves_the_glyphs_apart() {
        let mut library = bare_library();
        let base = TextStyle { content: "abcd".into(), font_size: 10.0, ..TextStyle::default() };
        let tight = layout_text(&base, &mut library);
        let loose = layout_text(&TextStyle { tracking: 4.0, ..base.clone() }, &mut library);
        assert!(loose.width > tight.width);
        assert_eq!(loose.glyphs[1].x - loose.glyphs[0].x, 5.0 + 4.0);
    }

    #[test]
    fn a_bigger_font_size_lays_out_bigger() {
        let mut library = bare_library();
        let small =
            layout_text(&TextStyle { content: "hello".into(), font_size: 12.0, ..TextStyle::default() }, &mut library);
        let large =
            layout_text(&TextStyle { content: "hello".into(), font_size: 48.0, ..TextStyle::default() }, &mut library);
        assert!(large.width > small.width);
        assert!(large.height > small.height);
    }

    #[test]
    fn an_empty_text_is_as_big_as_its_padding() {
        let mut library = bare_library();
        let style = TextStyle { content: String::new(), font_size: 1.0, ..TextStyle::default() };
        let layout = layout_text(&style, &mut library);
        // Point text keeps the padding on both sides plus a caret's worth of width.
        assert_eq!((layout.width, layout.height), (25, 26));
        assert!(layout.width as f64 >= MIN_TEXT_SIDE);
    }

    #[test]
    fn whitespace_draws_nothing() {
        let mut library = bare_library();
        let style = TextStyle { content: "   \n\t".into(), font_size: 10.0, ..TextStyle::default() };
        let layout = layout_text(&style, &mut library);
        assert!(layout.glyphs.is_empty());
        assert_eq!(layout.lines.len(), 2);
    }

    #[test]
    fn control_characters_do_not_become_glyphs() {
        let mut library = bare_library();
        let style = TextStyle { content: "a\u{7}b".into(), font_size: 10.0, ..TextStyle::default() };
        let layout = layout_text(&style, &mut library);
        assert_eq!(layout.glyphs.len(), 2, "the bell character has nothing to draw");
    }

    #[test]
    fn a_damaged_style_still_lays_out() {
        let mut library = bare_library();
        let style = TextStyle {
            content: "broken".into(),
            font_size: f64::NAN,
            tracking: f64::INFINITY,
            leading: f64::NAN,
            ..TextStyle::default()
        };
        let layout = layout_text(&style, &mut library);
        assert!(layout.width >= 1 && layout.height >= 1);
        assert!(layout.line_height.is_finite() && layout.line_height > 0.0);
        assert_eq!(layout.tracking, 0.0);
    }

    #[test]
    fn the_maximum_font_size_stays_inside_the_format_limits() {
        let mut library = bare_library();
        let style = TextStyle { content: "big".into(), font_size: 2000.0, ..TextStyle::default() };
        let layout = layout_text(&style, &mut library);
        assert!(layout.fits_limits());
        assert!(layout.width <= limits::MAX_SIDE);
    }

    #[test]
    fn a_hundred_thousand_characters_still_lay_out() {
        let mut library = bare_library();
        let style = TextStyle { content: "a".repeat(limits::MAX_TEXT_UTF16), font_size: 4.0, ..TextStyle::default() };
        let layout = layout_text(&style, &mut library);
        assert_eq!(layout.chars.len(), limits::MAX_TEXT_UTF16);
        assert!(layout.fits_limits());
    }

    #[test]
    fn a_character_advances_the_pen_without_a_face() {
        let mut library = bare_library();
        // With no faces installed every character advances by half the font size.
        let style = TextStyle { content: "a\tb".into(), font_size: 10.0, ..TextStyle::default() };
        let layout = layout_text(&style, &mut library);
        assert_eq!(advances(&layout), vec![5.0, 5.0, 5.0]);
    }

    // ---- shaping --------------------------------------------------------

    #[test]
    fn shaping_is_on_by_default() {
        assert!(LayoutOptions::default().shaping);
        assert_eq!(LayoutOptions::default(), LayoutOptions::SHAPED);
        assert!(!LayoutOptions::UNSHAPED.shaping);
    }

    #[test]
    fn kerning_narrows_a_pair() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Arial") {
            return;
        }
        let style = text("Arial", "AV", 64.0);
        let shaped = layout_text(&style, &mut library);
        let plain = layout_text_with(&style, &mut library, LayoutOptions::UNSHAPED);
        assert!(shaped.shaped, "the shaper has to run");
        assert_eq!(shaped.glyphs.len(), 2);
        assert!(
            width(&shaped) < width(&plain),
            "Arial kerns AV: shaped {} vs plain {}",
            width(&shaped),
            width(&plain)
        );
    }

    #[test]
    fn a_pair_the_face_does_not_kern_keeps_its_width() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Georgia") {
            return;
        }
        // Georgia carries no kerning for AV, so shaping must not invent any.
        let style = text("Georgia", "AV", 64.0);
        let shaped = layout_text(&style, &mut library);
        let plain = layout_text_with(&style, &mut library, LayoutOptions::UNSHAPED);
        assert!((width(&shaped) - width(&plain)).abs() < 0.01, "{} vs {}", width(&shaped), width(&plain));
    }

    #[test]
    fn a_ligature_merges_two_characters() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Calibri") {
            return;
        }
        let style = text("Calibri", "fi", 64.0);
        let shaped = layout_text(&style, &mut library);
        let plain = layout_text_with(&style, &mut library, LayoutOptions::UNSHAPED);
        assert_eq!(plain.glyphs.len(), 2);
        assert_eq!(shaped.glyphs.len(), 1, "fi is one glyph in Calibri");
        assert_eq!(shaped.chars[1].advance, 0.0, "the swallowed character keeps no width");
        assert_eq!(shaped.chars[0].advance, width(&shaped));
    }

    #[test]
    fn an_ffi_ligature_is_narrower_than_its_letters() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Calibri") {
            return;
        }
        let style = text("Calibri", "ffi", 64.0);
        let shaped = layout_text(&style, &mut library);
        let plain = layout_text_with(&style, &mut library, LayoutOptions::UNSHAPED);
        assert_eq!(shaped.glyphs.len(), 1);
        assert!(width(&shaped) < width(&plain), "{} vs {}", width(&shaped), width(&plain));
        assert_eq!(advances(&shaped)[1..], [0.0, 0.0]);
    }

    #[test]
    fn a_face_without_ligatures_keeps_every_glyph() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Arial") {
            return;
        }
        // Arial shapes fi as two glyphs, so the ligature path has to leave them alone.
        let style = text("Arial", "fi", 64.0);
        let shaped = layout_text(&style, &mut library);
        let plain = layout_text_with(&style, &mut library, LayoutOptions::UNSHAPED);
        assert_eq!(shaped.glyphs.len(), 2);
        assert!((width(&shaped) - width(&plain)).abs() < 0.01, "and there is no kern to apply");
    }

    #[test]
    fn a_combining_mark_is_attached_not_advanced() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Arial") {
            return;
        }
        // x has no precomposed acute, so the mark stays a glyph of its own — moved into place by the
        // shaper rather than by an advance.
        let style = text("Arial", "x\u{0301}", 64.0);
        let layout = layout_text(&style, &mut library);
        assert_eq!(layout.chars.len(), 2);
        assert!(glyphs_of(&layout, 1).is_empty(), "the mark shares its base's cluster");
        assert_eq!(layout.chars[1].advance, 0.0);
        let cluster = glyphs_of(&layout, 0);
        assert_eq!(cluster.len(), 2, "base and mark");
        let mark = cluster[1];
        assert!(
            mark.x_offset != 0.0 || mark.y_offset != 0.0,
            "a mark is moved onto its base: {mark:?}"
        );
    }

    #[test]
    fn a_composable_pair_becomes_one_glyph() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Arial") {
            return;
        }
        // The shaper normalizes e + acute to é: two characters, one glyph.
        let style = text("Arial", "e\u{0301}", 64.0);
        let layout = layout_text(&style, &mut library);
        assert_eq!(layout.chars.len(), 2);
        assert_eq!(layout.glyphs.len(), 1);
        assert_eq!(layout.chars[1].advance, 0.0);
    }

    #[test]
    fn arabic_lam_alef_becomes_one_glyph() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Arial") {
            return;
        }
        // Lam + alef is a required ligature in Arabic.
        let style = text("Arial", "\u{0644}\u{0627}", 64.0);
        let layout = layout_text(&style, &mut library);
        assert_eq!(layout.chars.len(), 2);
        assert_eq!(layout.glyphs.len(), 1, "lam-alef is one glyph");
        assert_eq!(layout.chars[0].advance, width(&layout));
    }

    #[test]
    fn a_right_to_left_run_places_its_first_character_rightmost() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Arial") {
            return;
        }
        // The shaper hands back a right-to-left run in visual order; the first character has to land
        // at the right-hand end of the line.
        let style = text("Arial", "\u{0634}\u{0633}", 64.0);
        let layout = layout_text(&style, &mut library);
        assert_eq!(layout.glyphs.len(), 2);
        let first = glyphs_of(&layout, 0);
        let second = glyphs_of(&layout, 1);
        assert_eq!(first.len(), 1);
        assert_eq!(second.len(), 1);
        assert!(
            first[0].x > second[0].x,
            "the first character is drawn to the right: {} vs {}",
            first[0].x,
            second[0].x
        );
        assert!(width(&layout) > 0.0);
        assert!((width(&layout) - advances(&layout).iter().sum::<f64>()).abs() < 0.001);
    }

    #[test]
    fn arabic_text_keeps_every_character() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Arial") {
            return;
        }
        let style = text("Arial", "\u{0627}\u{0644}\u{0639}\u{0631}\u{0628}\u{064A}\u{0629}", 48.0);
        let layout = layout_text(&style, &mut library);
        assert_eq!(layout.chars.len(), 7);
        assert!(!layout.glyphs.is_empty());
        assert!(layout.glyphs.len() <= layout.chars.len(), "shaping joins, it does not invent");
        assert!(layout.glyphs.iter().all(|glyph| glyph.glyph_id != 0));
    }

    #[test]
    fn devanagari_merges_a_conjunct() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Nirmala UI") {
            return;
        }
        // क्ष is ka + virama + ssa: three characters, one glyph once the virama joins them.
        let style = text("Nirmala UI", "\u{0915}\u{094D}\u{0937}", 64.0);
        let layout = layout_text(&style, &mut library);
        assert_eq!(layout.chars.len(), 3);
        assert_eq!(layout.glyphs.len(), 1);
    }

    #[test]
    fn devanagari_reorders_a_vowel_sign() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Nirmala UI") {
            return;
        }
        let style = text("Nirmala UI", "\u{0915}\u{093F}", 64.0);
        let shaped = layout_text(&style, &mut library);
        let plain = layout_text_with(&style, &mut library, LayoutOptions::UNSHAPED);
        assert_eq!(shaped.chars.len(), 2);
        assert!(glyphs_of(&shaped, 1).is_empty(), "the vowel sign shares the consonant's cluster");
        assert_eq!(shaped.chars[1].advance, 0.0);
        let shaped_ids: Vec<u16> = shaped.glyphs.iter().map(|glyph| glyph.glyph_id).collect();
        let plain_ids: Vec<u16> = plain.glyphs.iter().map(|glyph| glyph.glyph_id).collect();
        assert_ne!(shaped_ids, plain_ids, "the syllable is shaped, not laid out letter by letter");
    }

    #[test]
    fn a_zero_width_joiner_adds_no_width_or_ink() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Arial") {
            return;
        }
        let style = text("Arial", "a\u{200D}b", 48.0);
        let layout = layout_text(&style, &mut library);
        assert!(glyphs_of(&layout, 1).is_empty(), "the joiner draws nothing of its own");
        assert_eq!(layout.chars[1].advance, 0.0);
        assert_eq!(glyphs_of(&layout, 2).len(), 1);
        let single = text("Arial", "ab", 48.0);
        let plain = layout_text(&single, &mut library);
        assert!((width(&layout) - width(&plain)).abs() < 0.01, "and takes no room");
    }

    #[test]
    fn a_variation_selector_keeps_the_face_it_was_given() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Arial") {
            return;
        }
        // Most faces have no glyph for a variation selector; it must not send the text to another
        // face, which would draw a stray box in the middle of the word.
        let style = text("Arial", "a\u{FE0F}b", 48.0);
        let layout = layout_text(&style, &mut library);
        let fonts: HashSet<usize> = layout.glyphs.iter().filter_map(|glyph| glyph.font).collect();
        assert_eq!(fonts.len(), 1, "one face draws the whole word");
        assert_eq!(layout.chars[1].advance, 0.0);
    }

    #[test]
    fn a_symbol_face_draws_letters_through_a_linked_face() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Marlett") {
            return;
        }
        // Marlett claims Latin letters in the character map this build reads and shapes them to
        // nothing, so only the per-glyph fallback can put letters on the page.
        let style = text("Marlett", "AVA", 48.0);
        let layout = layout_text(&style, &mut library);
        assert_eq!(layout.glyphs.len(), 3);
        let ids: Vec<u16> = layout.glyphs.iter().map(|glyph| glyph.glyph_id).collect();
        assert!(ids.iter().all(|id| *id != 0), "no missing-glyph boxes: {ids:?}");
        let primary = library.resolved_name("Marlett");
        let drawn = layout.face_index(layout.glyphs[0].font.unwrap()).and_then(|index| library.face(index));
        assert_ne!(drawn.map(|face| face.full_name.clone()), primary, "another face draws them");
    }

    #[test]
    fn an_uncovered_character_leaves_one_box() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Arial") {
            return;
        }
        // No installed face has this plane-16 private-use character.
        let style = text("Arial", "\u{10FFFD}", 32.0);
        let layout = layout_text(&style, &mut library);
        assert_eq!(layout.chars.len(), 1);
        assert_eq!(layout.glyphs.len(), 1);
        assert!(layout.chars[0].advance > 0.0, "a box still has a width");
    }

    #[test]
    fn shaping_does_not_move_a_fixed_box() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Arial") {
            return;
        }
        let mut style = text("Arial", "AV To", 32.0);
        style.box_size = Some(SizeD::new(300.0, 120.0));
        let shaped = layout_text(&style, &mut library);
        let plain = layout_text_with(&style, &mut library, LayoutOptions::UNSHAPED);
        assert_eq!((shaped.width, shaped.height), (plain.width, plain.height));
    }

    #[test]
    fn without_faces_shaping_matches_the_plain_layout() {
        let mut library = bare_library();
        let style = TextStyle { content: "hello world".into(), font_size: 20.0, ..TextStyle::default() };
        let shaped = layout_text(&style, &mut library);
        let plain = layout_text_with(&style, &mut library, LayoutOptions::UNSHAPED);
        assert!(!shaped.shaped);
        assert_eq!(advances(&shaped), advances(&plain));
        assert_eq!(shaped.lines[0].width, plain.lines[0].width);
    }

    #[test]
    fn a_line_is_as_wide_as_the_shaped_advances() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Arial") {
            return;
        }
        let style = text("Arial", "AV To fi office", 40.0);
        let layout = layout_text(&style, &mut library);
        let sum: f64 = advances(&layout).iter().sum();
        assert!((width(&layout) - sum).abs() < 0.001, "{} vs {sum}", width(&layout));
    }

    #[test]
    fn text_bounds_hold_the_shaped_line() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Arial") {
            return;
        }
        let style = text("Arial", "AV To", 48.0);
        let layout = layout_text(&style, &mut library);
        let expected = width(&layout) + 2.0 * TEXT_PADDING + 48.0 * 0.1;
        assert!(
            (layout.width as f64 - expected.ceil()).abs() <= 1.0,
            "bounds {} against line {}",
            layout.width,
            width(&layout)
        );
    }

    #[test]
    fn tracking_adds_to_the_shaped_advances() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Arial") {
            return;
        }
        let base = text("Arial", "AV", 64.0);
        let tight = layout_text(&base, &mut library);
        let loose = layout_text(&TextStyle { tracking: 10.0, ..base.clone() }, &mut library);
        assert!((width(&loose) - (width(&tight) + 10.0)).abs() < 0.001);
    }

    #[test]
    fn wrapping_measures_the_shaped_width() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Arial") {
            return;
        }
        // A box one pixel narrower than the unshaped line still holds it once AV is kerned.
        let mut style = text("Arial", "AVAVAVAV", 64.0);
        let plain_width = layout_text_with(&style, &mut library, LayoutOptions::UNSHAPED).lines[0].width;
        style.box_size = Some(SizeD::new(plain_width - 1.0 + 2.0 * TEXT_PADDING, 400.0));
        let shaped = layout_text(&style, &mut library);
        assert_eq!(shaped.lines.len(), 1, "kerning makes it fit");
        let plain = layout_text_with(&style, &mut library, LayoutOptions::UNSHAPED);
        assert!(plain.lines.len() > 1, "the unshaped line still does not fit");
    }

    #[test]
    fn a_line_broken_at_a_space_does_not_begin_with_punctuation() {
        // The break falls on the space before the full stop, and what begins the next line is the full
        // stop after it, not the space that is dropped: the line is pulled back instead.
        let layout = boxed("ab \u{3002}xy", 15.0);
        let lines = line_strings(&layout);
        for line in &lines {
            let first = line.chars().next().unwrap_or(' ');
            assert!(!cannot_start_a_line(first), "a line begins with {first:?}: {lines:?}");
        }
    }

    #[test]
    fn a_hard_break_does_not_cut_a_grapheme_cluster() {
        // A run of Devanagari with no break opportunity in it is broken between characters as a last
        // resort, but क्क is one cluster of three characters and is never cut in half.
        use unicode_segmentation::UnicodeSegmentation;
        let text = "\u{0915}\u{094D}\u{0915}\u{0915}\u{094D}\u{0915}";
        let layout = boxed(text, 10.0);
        let mut starts = vec![0usize];
        let mut position = 0usize;
        for cluster in text.graphemes(true) {
            position += cluster.chars().count();
            starts.push(position);
        }
        for line in &layout.lines {
            assert!(starts.contains(&line.range.start), "a line begins inside a cluster: {:?}", line.range);
            assert!(starts.contains(&line.range.end), "a line ends inside a cluster: {:?}", line.range);
        }
        assert!(layout.lines.len() >= 2, "the box is too narrow for one cluster");
    }

    // ---- caches and incremental layout ----------------------------------

    /// A stable description of a whole layout, for comparing one against another.
    fn signature(layout: &TextLayout) -> String {
        let face = |index: Option<usize>| {
            index
                .and_then(|index| layout.fonts.get(index))
                .and_then(|font| font.name())
                .unwrap_or("none")
                .to_string()
        };
        let mut out = format!(
            "{:.4}x{:.4} boxed={} shaped={} dir={:?} descent={:.4} line_height={:.4}\n",
            layout.width as f64, layout.height as f64, layout.boxed, layout.shaped, layout.direction,
            layout.descent, layout.line_height
        );
        for cell in &layout.chars {
            out.push_str(&format!(
                "c {:?} {} {} {} {:.4} {:?} {}\n",
                cell.ch, cell.utf16_start, cell.utf16_len, face(cell.font), cell.advance, cell.color, cell.level
            ));
        }
        for line in &layout.lines {
            out.push_str(&format!(
                "l {:.4} {:.4} {:.4} {} {:?} {:?} {:?}\n",
                line.x, line.width, line.baseline, line.rtl, line.range, line.cells, line.display
            ));
        }
        for glyph in &layout.glyphs {
            out.push_str(&format!(
                "g {} {} {} {:.4} {:.4} {:.4} {:.4}\n",
                glyph.cell, face(glyph.font), glyph.glyph_id, glyph.x, glyph.baseline, glyph.x_offset, glyph.y_offset
            ));
        }
        out
    }

    fn lookups(before: crate::cache::CacheStats, after: crate::cache::CacheStats) -> (u64, u64) {
        (after.hits - before.hits, after.misses - before.misses)
    }

    /// A document of several paragraphs, Chinese and Latin mixed, inside a box.
    fn document(paragraphs: &[&str]) -> TextStyle {
        TextStyle {
            content: paragraphs.join("\n"),
            font_name: "Microsoft YaHei".into(),
            font_size: 18.0,
            box_size: Some(SizeD::new(260.0, 800.0)),
            ..TextStyle::default()
        }
    }

    #[test]
    fn the_shaping_cache_answers_the_second_layout() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Microsoft YaHei") {
            return;
        }
        let style = document(&["今天天气很好，我们出去走走。", "The quick brown fox jumps."]);
        layout_text(&style, &mut library);
        let before = library.shape_stats();
        assert!(before.misses > 0, "the first layout shapes");
        // The paragraphs themselves are cached too, so ask for the layout again with those out of
        // the way: the runs are what the shaping cache answers for.
        library.clear_layout_cache();
        layout_text(&style, &mut library);
        let (hits, misses) = lookups(before, library.shape_stats());
        assert_eq!(misses, 0, "nothing has to be shaped twice");
        assert!(hits > 0);
    }

    #[test]
    fn a_changed_font_size_shapes_again() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Microsoft YaHei") {
            return;
        }
        let mut style = document(&["今天天气很好。"]);
        layout_text(&style, &mut library);
        let before = library.shape_stats();
        style.font_size = 19.0;
        layout_text(&style, &mut library);
        assert!(lookups(before, library.shape_stats()).1 > 0, "a different size shapes again");
    }

    #[test]
    fn changed_text_shapes_again() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Microsoft YaHei") {
            return;
        }
        let mut style = document(&["今天天气很好。"]);
        layout_text(&style, &mut library);
        let before = library.shape_stats();
        style.content = "今天天气很好。明天也不错。".into();
        layout_text(&style, &mut library);
        assert!(lookups(before, library.shape_stats()).1 > 0);
    }

    #[test]
    fn a_changed_face_shapes_again() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Microsoft YaHei") || !has_face(&mut library, "SimSun") {
            return;
        }
        let mut style = document(&["今天天气很好。"]);
        layout_text(&style, &mut library);
        let before = library.shape_stats();
        style.font_name = "SimSun".into();
        layout_text(&style, &mut library);
        assert!(lookups(before, library.shape_stats()).1 > 0);
    }

    #[test]
    fn a_changed_direction_shapes_again() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Arial") {
            return;
        }
        let style = TextStyle {
            content: "\u{05D0}\u{05D1} \u{05D2}".into(),
            font_name: "Arial".into(),
            font_size: 24.0,
            ..TextStyle::default()
        };
        layout_text(&style, &mut library);
        let before = library.shape_stats();
        let before_layout = library.layout_stats();
        layout_text_with(
            &style,
            &mut library,
            LayoutOptions { direction: ParagraphDirection::RightToLeft, ..LayoutOptions::SHAPED },
        );
        assert!(lookups(before_layout, library.layout_stats()).1 > 0, "another direction is another layout");
        assert_eq!(
            lookups(before, library.shape_stats()).1,
            0,
            "but the glyphs themselves are the same, so the shaper is not asked again"
        );
    }

    #[test]
    fn the_shaping_cache_never_grows_past_its_capacity() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Microsoft YaHei") {
            return;
        }
        library.set_shape_cache_capacity(4);
        for index in 0..40 {
            let style = document(&[&format!("第{index}段中文文本，各不相同。"), &format!("paragraph {index}")]);
            layout_text(&style, &mut library);
        }
        let stats = library.shape_stats();
        assert!(stats.entries <= 4, "{} entries", stats.entries);
        assert!(stats.evictions > 0);
        assert_eq!(stats.capacity, 4);
    }

    #[test]
    fn the_layout_cache_answers_paragraphs_that_did_not_change() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Microsoft YaHei") {
            return;
        }
        let mut style = document(&["第一段中文。", "第二段中文。", "第三段中文。", "第四段中文。"]);
        layout_text(&style, &mut library);
        let before = library.layout_stats();
        style.content = "第一段中文。\n第二段中文改了。\n第三段中文。\n第四段中文。".into();
        layout_text(&style, &mut library);
        let (hits, misses) = lookups(before, library.layout_stats());
        assert!(hits >= 3, "the three untouched paragraphs are reused: {hits} hits, {misses} misses");
        assert!(misses >= 1, "the edited one is laid out again");
    }

    #[test]
    fn only_the_edited_paragraph_is_shaped_again() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Microsoft YaHei") {
            return;
        }
        let mut style = document(&["第一段中文。", "第二段中文。", "第三段中文。"]);
        layout_text(&style, &mut library);
        let before = library.shape_stats();
        let before_layout = library.layout_stats();
        style.content = "第一段中文。\n第二段中文改了。\n第三段中文。".into();
        layout_text(&style, &mut library);
        let (_, shape_misses) = lookups(before, library.shape_stats());
        let (layout_hits, layout_misses) = lookups(before_layout, library.layout_stats());
        assert!(shape_misses <= 2, "only the edited paragraph asks the shaper again: {shape_misses}");
        assert_eq!(layout_misses, 1, "and only it is laid out again");
        assert!(layout_hits >= 2, "the paragraphs that did not change are reused: {layout_hits}");
    }

    #[test]
    fn a_changed_box_width_lays_the_paragraphs_out_again() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Microsoft YaHei") {
            return;
        }
        let mut style = document(&["今天天气很好，我们出去走走。"]);
        layout_text(&style, &mut library);
        let before = library.layout_stats();
        style.box_size = Some(SizeD::new(200.0, 800.0));
        layout_text(&style, &mut library);
        assert!(lookups(before, library.layout_stats()).1 > 0, "a narrower box wraps differently");
    }

    #[test]
    fn a_changed_alignment_reuses_the_paragraphs() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Microsoft YaHei") {
            return;
        }
        let mut style = document(&["今天天气很好。"]);
        let left = layout_text(&style, &mut library);
        let before = library.layout_stats();
        style.alignment = TextAlignment::Right;
        let right = layout_text(&style, &mut library);
        let (hits, misses) = lookups(before, library.layout_stats());
        assert_eq!(misses, 0, "alignment is applied after the paragraphs, so nothing is laid out twice");
        assert!(hits > 0);
        assert!(right.lines[0].x > left.lines[0].x, "and it does move the line");
    }

    #[test]
    fn the_same_paragraph_twice_is_laid_out_once() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Microsoft YaHei") {
            return;
        }
        let style = document(&["重复的一段中文。", "重复的一段中文。"]);
        let before = library.layout_stats();
        let layout = layout_text(&style, &mut library);
        let (hits, misses) = lookups(before, library.layout_stats());
        assert_eq!((hits, misses), (1, 1), "the second copy answers from the first");
        assert_eq!(layout.lines.len(), 2);
    }

    #[test]
    fn clearing_the_caches_makes_the_next_layout_a_miss() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Microsoft YaHei") {
            return;
        }
        let style = document(&["今天天气很好。"]);
        layout_text(&style, &mut library);
        library.clear_shape_cache();
        library.clear_layout_cache();
        let before = (library.shape_stats(), library.layout_stats());
        layout_text(&style, &mut library);
        assert!(library.shape_stats().misses > before.0.misses);
        assert!(library.layout_stats().misses > before.1.misses);
    }

    #[test]
    fn the_stats_report_a_hit_rate() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Microsoft YaHei") {
            return;
        }
        let style = document(&["今天天气很好。", "The quick brown fox."]);
        layout_text(&style, &mut library);
        layout_text(&style, &mut library);
        let stats = library.layout_stats();
        assert!(stats.lookups() > 0);
        assert_eq!(stats.hit_rate(), stats.hits as f64 / stats.lookups() as f64);
        assert!(stats.hit_rate() > 0.4, "half the lookups are the second layout: {}", stats.hit_rate());
        assert!(library.shape_stats().lookups() > 0, "and the shaper was asked at least once");
    }

    #[test]
    fn an_incremental_relayout_is_identical_to_a_fresh_one() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Microsoft YaHei") {
            return;
        }
        let mut style = document(&[
            "第一段中文，带 Latin words 和数字 3.14。",
            "第二段「引号」与标点，明天也不错。",
            "第三段 mixed text with a URL https://example.com here.",
        ]);
        layout_text(&style, &mut library);
        // A keystroke in the middle paragraph.
        style.content = style.content.replace("明天也不错", "明天也很好");
        let incremental = layout_text(&style, &mut library);
        let mut fresh_library = system_library().unwrap();
        let fresh = layout_text(&style, &mut fresh_library);
        assert_eq!(signature(&incremental), signature(&fresh), "warm and cold layouts agree exactly");
    }

    #[test]
    fn a_relayout_after_a_width_change_is_identical_to_a_fresh_one() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Microsoft YaHei") {
            return;
        }
        let mut style = document(&["今天天气很好，我们出去走走看看。", "The quick brown fox jumps over."]);
        layout_text(&style, &mut library);
        style.box_size = Some(SizeD::new(180.0, 800.0));
        style.tracking = 1.5;
        let incremental = layout_text(&style, &mut library);
        let mut fresh_library = system_library().unwrap();
        let fresh = layout_text(&style, &mut fresh_library);
        assert_eq!(signature(&incremental), signature(&fresh));
    }

    #[test]
    fn typing_in_a_long_document_is_cheap() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Microsoft YaHei") {
            return;
        }
        // Some ten thousand characters in two hundred paragraphs of mixed Chinese and Latin.
        let source = "今天天气很好，我们出去走走。The quick brown fox。中文混排 3.14 kg。";
        let mut content = String::new();
        for index in 0..200 {
            content.push_str(&format!("第{index}段：{source}"));
            if index + 1 < 200 {
                content.push('\n');
            }
        }
        assert!(content.chars().count() > 10_000, "{} characters", content.chars().count());
        let mut style = TextStyle {
            content: content.clone(),
            font_name: "Microsoft YaHei".into(),
            font_size: 16.0,
            box_size: Some(SizeD::new(420.0, 20_000.0)),
            ..TextStyle::default()
        };

        // The first layout on a library that has not loaded the faces yet: the parse of a large CJK
        // face is part of this number, which is why it is reported apart from the one below.
        let mut unprepared = system_library().unwrap();
        let started = std::time::Instant::now();
        let cold_first = layout_text(&style, &mut unprepared);
        let unprepared_ms = started.elapsed().as_secs_f64() * 1000.0;
        let unprepared_stages = unprepared.stage_times();

        // The first layout of a document whose faces were loaded when it was opened.
        let mut library = system_library().unwrap();
        let started = std::time::Instant::now();
        let prepared_faces = library.prepare_style(&style);
        let prepare_ms = started.elapsed().as_secs_f64() * 1000.0;
        let started = std::time::Instant::now();
        let first = layout_text(&style, &mut library);
        let first_ms = started.elapsed().as_secs_f64() * 1000.0;
        let first_stages = library.stage_times();
        assert!(first.lines.len() >= 200, "{} lines", first.lines.len());
        assert_eq!(signature(&first), signature(&cold_first), "loading a face changes nothing but the time");
        let cold_shapes = library.shape_stats().misses;
        let cold_paragraphs = library.layout_stats().misses;

        // One keystroke in the middle of the document.
        let middle = content.char_indices().nth(content.chars().count() / 2).map(|(byte, _)| byte).unwrap_or(0);
        let mut edited = content.clone();
        edited.insert(middle, '好');
        style.content = edited;
        let before = (library.shape_stats(), library.layout_stats());
        let started = std::time::Instant::now();
        let typed = layout_text(&style, &mut library);
        let typed_ms = started.elapsed().as_secs_f64() * 1000.0;
        let typed_stages = library.stage_times();
        let (shape_hits, shape_misses) = lookups(before.0, library.shape_stats());
        let (layout_hits, layout_misses) = lookups(before.1, library.layout_stats());

        // The control for the keystroke: the same document laid out with nothing cached, and the
        // faces already loaded, so this is the layout work and not the parse of a font.
        let mut cold = system_library().unwrap();
        cold.prepare_style(&style);
        let started = std::time::Instant::now();
        let fresh = layout_text(&style, &mut cold);
        let control_ms = started.elapsed().as_secs_f64() * 1000.0;
        let control_stages = cold.stage_times();
        let control_shapes = cold.shape_stats().misses;

        // The window is resized: the same text in a narrower box.
        style.box_size = Some(SizeD::new(380.0, 20_000.0));
        let before = (library.shape_stats(), library.layout_stats());
        let started = std::time::Instant::now();
        let resized = layout_text(&style, &mut library);
        let resized_ms = started.elapsed().as_secs_f64() * 1000.0;
        let resized_stages = library.stage_times();
        let (resize_shape_hits, resize_shape_misses) = lookups(before.0, library.shape_stats());
        let (resize_layout_hits, resize_layout_misses) = lookups(before.1, library.layout_stats());

        // The control for the resize: the same narrower box with every cache thrown away and the
        // faces already loaded, so the comparison is about what the caches save.
        let mut invalidated = system_library().unwrap();
        invalidated.prepare_style(&style);
        let started = std::time::Instant::now();
        let reference = layout_text(&style, &mut invalidated);
        let invalidated_ms = started.elapsed().as_secs_f64() * 1000.0;
        let invalidated_shapes = invalidated.shape_stats().misses;

        let stages = |name: &str, millis: f64, times: StageTimes| {
            println!(
                "  {name:<22} {millis:>8.1} ms   shaping {:>7.1}   breaking {:>7.1}   assembly {:>7.1}",
                times.shaping_ns as f64 / 1e6,
                times.breaking_ns as f64 / 1e6,
                times.assembly_ns as f64 / 1e6,
            );
        };
        println!(
            "{} chars / 200 paragraphs ({} lines in the first box, {cold_shapes} shaped runs, {cold_paragraphs} laid-out paragraphs):",
            content.chars().count(),
            first.lines.len()
        );
        stages("first layout (cold)", unprepared_ms, unprepared_stages);
        stages("prepare_style", prepare_ms, StageTimes::default());
        stages("first layout", first_ms, first_stages);
        println!("  prepare_style loaded {prepared_faces} faces");
        stages("keystroke", typed_ms, typed_stages);
        stages("box 420 -> 380", resized_ms, resized_stages);
        stages("resize, no cache", invalidated_ms, invalidated.stage_times());
        stages("keystroke, no cache", control_ms, control_stages);
        println!(
            "  the controls shape {invalidated_shapes} and {control_shapes} runs; the resize shapes none and the keystroke one"
        );
        println!(
            "  keystroke: shape {shape_hits} hits / {shape_misses} misses, layout {layout_hits} hits / {layout_misses} misses"
        );
        println!(
            "  resize:    shape {resize_shape_hits} hits / {resize_shape_misses} misses, layout {resize_layout_hits} hits / {resize_layout_misses} misses"
        );
        println!(
            "  shape cache {:.1}% of {} lookups, layout cache {:.1}% of {} lookups",
            library.shape_stats().hit_rate() * 100.0,
            library.shape_stats().lookups(),
            library.layout_stats().hit_rate() * 100.0,
            library.layout_stats().lookups(),
        );
        println!("  lines: {} in the first box, {} in the narrow one", first.lines.len(), resized.lines.len());

        assert_eq!(signature(&typed), signature(&fresh), "the incremental layout is the same layout");
        assert_eq!(signature(&first), signature(&cold_first), "and so is the first one");
        assert_eq!(signature(&resized), signature(&reference), "and so is the resized one");
        assert!(shape_misses < cold_shapes / 4, "a keystroke shapes {shape_misses} runs, a cold pass {cold_shapes}");
        assert!(layout_misses < 4, "a keystroke lays out {layout_misses} paragraphs");
        assert!(layout_hits > 150, "the rest are translated: {layout_hits} hits");
        assert_eq!(resize_shape_misses, 0, "a narrower box re-shapes nothing at all");
        assert!(resize_shape_hits > 0, "it answers from the shaping cache");
        assert_eq!(resize_layout_misses, 200, "every paragraph is wrapped again");
        assert!(resized.lines.len() >= first.lines.len(), "and a narrower box never needs fewer lines");
        let _ = fresh;
    }

// ---- preparation and stages -----------------------------------------

    #[test]
    fn preparing_a_document_loads_its_faces_once() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Microsoft YaHei") {
            return;
        }
        let style = document(&["今天天气很好，我们出去走走。", "The quick brown fox jumps."]);
        let loaded = library.prepare_style(&style);
        assert!(loaded >= 1, "the style's face is loaded: {loaded} faces");
        assert_eq!(library.prepare_style(&style), 0, "a second call has nothing left to load");
    }

    #[test]
    fn preparing_by_name_loads_the_faces_it_is_given() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Microsoft YaHei") {
            return;
        }
        assert!(library.prepare(["Microsoft YaHei"]) >= 1, "the face is loaded");
        assert_eq!(library.prepare(["Microsoft YaHei"]), 0, "and not loaded twice");
        // A name this machine does not have still resolves to a substitute face, as every other
        // request does; whatever it settles on, it is loaded once.
        library.prepare(["NoSuchFontOnThisMachine"]);
        assert_eq!(library.prepare(["NoSuchFontOnThisMachine"]), 0);
    }

    #[test]
    fn preparing_loads_the_fallback_a_face_will_need() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Arial") || !has_face(&mut library, "Microsoft YaHei") {
            return;
        }
        // Arial has no Chinese, so laying this out loads a CJK face in the middle of the layout
        // unless the caller prepared for it.
        let style = TextStyle {
            content: "Arial 里的中文".into(),
            font_name: "Arial".into(),
            font_size: 18.0,
            ..TextStyle::default()
        };
        assert!(library.prepare_style(&style) >= 2, "Arial and the CJK face it falls back to");
    }

    #[test]
    fn the_stage_times_add_up() {
        let stages = StageTimes { shaping_ns: 5, breaking_ns: 3, assembly_ns: 2 };
        assert_eq!(stages.total_ns(), 10);
        assert_eq!(stages.millis(), 0.00001);
        let mut total = StageTimes::default();
        total.add(stages);
        total.add(stages);
        assert_eq!(total, StageTimes { shaping_ns: 10, breaking_ns: 6, assembly_ns: 4 });
    }

    #[test]
    fn a_cached_layout_does_no_shaping_at_all() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Microsoft YaHei") {
            return;
        }
        let style = document(&["今天天气很好。", "The quick brown fox."]);
        layout_text(&style, &mut library);
        assert!(library.stage_times().shaping_ns > 0, "the first layout shapes");
        layout_text(&style, &mut library);
        let cached = library.stage_times();
        assert_eq!(cached.shaping_ns, 0, "the second answers from the caches");
        assert_eq!(cached.breaking_ns, 0, "and breaks no lines");
        assert_eq!(cached.total_ns(), cached.assembly_ns, "only the splice is left to do");
    }

    // ---- UAX #14 line breaking ------------------------------------------

    /// A paragraph in a fixed box whose text area is exactly the available width. With no fonts
    /// installed every character advances by half the font size, so expected line contents are
    /// arithmetic rather than a guess about a face's metrics.
    fn boxed(content: &str, available: f64) -> TextLayout {
        let mut library = bare_library();
        let style = TextStyle {
            content: content.to_string(),
            font_size: 10.0,
            box_size: Some(SizeD::new(available + 2.0 * TEXT_PADDING, 400.0)),
            ..TextStyle::default()
        };
        layout_text(&style, &mut library)
    }

    fn line_strings(layout: &TextLayout) -> Vec<String> {
        layout
            .lines
            .iter()
            .map(|line| line.cells.iter().map(|&cell| layout.chars[cell].ch).collect::<String>())
            .collect()
    }

    #[test]
    fn chinese_breaks_between_characters() {
        // Six characters of five pixels fill the line, and there is no space to break at anywhere.
        let layout = boxed("你好世界今天天气很好", 30.0);
        assert_eq!(line_strings(&layout), vec!["你好世界今天", "天气很好"]);
    }

    #[test]
    fn a_narrow_box_breaks_chinese_one_character_at_a_time() {
        let layout = boxed("中文混排", 5.0);
        assert_eq!(line_strings(&layout), vec!["中", "文", "混", "排"]);
    }

    #[test]
    fn chinese_never_starts_a_line_with_closing_punctuation() {
        let layout = boxed("今天天气很好。明天也不错。", 30.0);
        let lines = line_strings(&layout);
        assert!(lines.len() > 2);
        for line in &lines {
            let first = line.chars().next().expect("no empty line here");
            assert!(!cannot_start_a_line(first), "a line begins with {first:?}: {lines:?}");
        }
        assert!(lines.iter().any(|line| line.ends_with('。')), "the full stop ends a line: {lines:?}");
    }

    #[test]
    fn an_opening_bracket_never_ends_a_line() {
        let layout = boxed("他说「今天很好」然后走了", 30.0);
        let lines = line_strings(&layout);
        assert!(lines.len() >= 2);
        assert_eq!(lines.concat(), "他说「今天很好」然后走了", "every character is kept");
        for line in &lines {
            let last = line.chars().last().expect("no empty line here");
            assert!(!cannot_end_a_line(last), "a line ends with {last:?}: {lines:?}");
        }
    }

    #[test]
    fn a_line_broken_by_hand_moves_closing_punctuation_up() {
        // "ab。" offers no break opportunity at all, so the line has to be broken by hand, and the
        // full stop may not be left at the start of the next line.
        let layout = boxed("ab。", 10.0);
        assert_eq!(line_strings(&layout), vec!["a", "b。"]);
    }

    #[test]
    fn a_line_broken_by_hand_moves_an_opening_bracket_down() {
        let layout = boxed("a(b", 10.0);
        assert_eq!(line_strings(&layout), vec!["a", "(b"]);
    }

    #[test]
    fn the_prohibited_characters_are_the_ones_kinsoku_names() {
        for ch in ['。', '、', '，', '．', '」', '）', '』', 'ー', 'っ', 'ァ', '!', '.', '?'] {
            assert!(cannot_start_a_line(ch), "{ch:?} may not begin a line");
        }
        for ch in ['「', '『', '（', '【', '(', '[', '“'] {
            assert!(cannot_end_a_line(ch), "{ch:?} may not end a line");
        }
        for ch in ['中', 'a', '1', ' ', '，', '。'] {
            assert!(!cannot_end_a_line(ch), "{ch:?} may end a line");
        }
    }

    #[test]
    fn a_decimal_number_is_not_split() {
        let layout = boxed("abc 3.14 def", 20.0);
        assert_eq!(line_strings(&layout), vec!["abc", "3.14", "def"]);
    }

    #[test]
    fn a_number_and_its_unit_break_at_the_space_and_nowhere_else() {
        assert_eq!(line_strings(&boxed("10 kg", 25.0)), vec!["10 kg"], "it fits on one line");
        assert_eq!(line_strings(&boxed("10 kg", 15.0)), vec!["10", "kg"], "otherwise the space breaks");
    }

    #[test]
    fn a_url_is_kept_whole_when_it_fits() {
        // "see https://example.com" is twenty-three characters of five pixels, so a box of a hundred
        // and twenty holds it whole, and the last word moves down.
        let layout = boxed("see https://example.com here", 120.0);
        assert_eq!(line_strings(&layout), vec!["see https://example.com", "here"]);
    }

    #[test]
    fn a_url_breaks_only_where_uax14_allows() {
        let layout = boxed("see https://example.com here", 70.0);
        assert_eq!(line_strings(&layout), vec!["see https://", "example.com", "here"]);
    }

    #[test]
    fn chinese_and_english_mix_keeps_the_words_whole() {
        let layout = boxed("中文 word 混排 text", 25.0);
        assert_eq!(line_strings(&layout), vec!["中文", "word", "混排", "text"]);
    }

    #[test]
    fn an_unbreakable_run_is_broken_between_characters() {
        let layout = boxed("abcdefghij", 20.0);
        assert_eq!(line_strings(&layout), vec!["abcd", "efgh", "ij"]);
    }

    #[test]
    fn every_line_stays_inside_the_box() {
        for (content, available) in [
            ("中文 mixed English 混排 3.14 kg と日本語", 35.0),
            ("supercalifragilisticexpialidocious", 25.0),
            ("他说「今天很好」然后走了。", 20.0),
            ("aaaa bbbb cccc dddd", 10.0),
        ] {
            let layout = boxed(content, available);
            assert!(layout.lines.len() > 1, "{content:?} has to wrap");
            for line in &layout.lines {
                assert!(line.width <= available + 1e-9, "{content:?}: a line is {} wide", line.width);
            }
        }
    }

    #[test]
    fn explicit_breaks_still_make_lines() {
        let layout = boxed("你好\n世界", 30.0);
        assert_eq!(line_strings(&layout), vec!["你好", "世界"]);
    }

    #[test]
    fn a_line_never_starts_or_ends_with_a_space() {
        let layout = boxed("aa   bb   cc", 20.0);
        assert_eq!(line_strings(&layout), vec!["aa", "bb", "cc"]);
    }

    #[test]
    fn tracking_counts_against_the_box() {
        let mut library = bare_library();
        let style = TextStyle {
            content: "中文中文中文".into(),
            font_size: 10.0,
            tracking: 5.0,
            box_size: Some(SizeD::new(30.0 + 2.0 * TEXT_PADDING, 400.0)),
            ..TextStyle::default()
        };
        let layout = layout_text(&style, &mut library);
        assert_eq!(layout.lines.len(), 2, "three characters plus tracking fill each line");
        for line in &layout.lines {
            assert_eq!(line.cells.len(), 3);
            assert!(line.width <= 30.0 + 1e-9, "a line is {} wide", line.width);
        }
    }

    #[test]
    fn a_right_to_left_paragraph_breaks_by_uax14() {
        // Hebrew words of two characters each: the breaks land on the spaces, and every line is
        // still drawn from its last character.
        let layout = boxed("\u{05D0}\u{05D1} \u{05D2}\u{05D3} \u{05D4}\u{05D5}", 15.0);
        assert_eq!(line_strings(&layout), vec!["\u{05D0}\u{05D1}", "\u{05D2}\u{05D3}", "\u{05D4}\u{05D5}"]);
        assert!(layout.lines.iter().all(|line| line.rtl));
        for line in &layout.lines {
            let drawn: String = line.display.iter().map(|(cell, _)| layout.chars[*cell].ch).collect();
            let logical: String = line.cells.iter().map(|&cell| layout.chars[cell].ch).collect();
            let reversed: String = logical.chars().rev().collect();
            assert_eq!(drawn, reversed, "a right-to-left line is drawn from its last character");
        }
    }

    #[test]
    fn a_paragraph_of_spaces_has_no_width_of_its_own() {
        let layout = boxed("    ", 30.0);
        assert_eq!(layout.lines.len(), 1);
        assert!(layout.lines[0].cells.is_empty(), "spaces hang off no line");
        assert_eq!(layout.lines[0].width, 0.0);
    }

    #[test]
    fn a_line_of_chinese_is_as_wide_as_its_characters() {
        let layout = boxed("中文混排测试", 30.0);
        assert_eq!(line_strings(&layout), vec!["中文混排测试"]);
        assert_eq!(layout.lines[0].width, 6.0 * 5.0);
    }

    // ---- paragraph direction --------------------------------------------

    /// A paragraph laid out with no fonts installed. The bidi tests are about directions, levels and
    /// display order, none of which needs glyphs, and every character then advances by 5 pixels.
    fn bidi_layout(content: &str, options: LayoutOptions) -> TextLayout {
        let mut library = bare_library();
        let style = TextStyle { content: content.to_string(), font_size: 10.0, ..TextStyle::default() };
        layout_text_with(&style, &mut library, options)
    }

    fn display_cells(layout: &TextLayout) -> Vec<usize> {
        layout.lines[0].display.iter().map(|(cell, _)| *cell).collect()
    }

    fn levels(layout: &TextLayout) -> Vec<u8> {
        layout.chars.iter().map(|cell| cell.level).collect()
    }

    #[test]
    fn auto_direction_follows_the_first_strong_character() {
        assert_eq!(LayoutOptions::default().direction, ParagraphDirection::Auto);
        assert_eq!(bidi_layout("abc", LayoutOptions::SHAPED).direction, TextDirection::LeftToRight);
        assert_eq!(bidi_layout("\u{05D0}\u{05D1}\u{05D2}", LayoutOptions::SHAPED).direction, TextDirection::RightToLeft);
        // A Latin word first, so the paragraph is left to right even though Hebrew follows.
        assert_eq!(bidi_layout("abc \u{05D0}\u{05D1}", LayoutOptions::SHAPED).direction, TextDirection::LeftToRight);
        // Digits and punctuation are not strong, so they leave the paragraph left to right.
        assert_eq!(bidi_layout("123!?", LayoutOptions::SHAPED).direction, TextDirection::LeftToRight);
    }

    #[test]
    fn a_paragraph_can_be_forced_either_way() {
        let right_to_left = LayoutOptions { direction: ParagraphDirection::RightToLeft, ..LayoutOptions::SHAPED };
        let left_to_right = LayoutOptions { direction: ParagraphDirection::LeftToRight, ..LayoutOptions::SHAPED };
        let hebrew = bidi_layout("\u{05D0}\u{05D1}", left_to_right);
        assert_eq!(hebrew.direction, TextDirection::LeftToRight);
        assert_eq!(levels(&hebrew), vec![1, 1], "the letters themselves still run right to left");
        assert_eq!(display_cells(&hebrew), vec![1, 0]);
        let latin = bidi_layout("ab", right_to_left);
        assert_eq!(latin.direction, TextDirection::RightToLeft);
        assert_eq!(levels(&latin), vec![2, 2], "and a Latin word keeps level two inside it");
        assert_eq!(display_cells(&latin), vec![0, 1], "so it still reads left to right");
    }

    #[test]
    fn two_paragraphs_may_run_opposite_ways() {
        let layout = bidi_layout("abc\n\u{05D0}\u{05D1}\u{05D2}", LayoutOptions::SHAPED);
        assert_eq!(layout.lines.len(), 2);
        assert!(!layout.lines[0].rtl);
        assert!(layout.lines[1].rtl);
        assert_eq!(layout.direction, TextDirection::LeftToRight, "the layout reports its first paragraph");
        assert_eq!(display_cells(&layout), vec![0, 1, 2]);
        let second: Vec<usize> = layout.lines[1].display.iter().map(|(cell, _)| *cell).collect();
        assert_eq!(second, vec![6, 5, 4], "the Hebrew line is drawn from its last character");
    }

    #[test]
    fn a_right_to_left_word_inside_a_left_to_right_paragraph_keeps_its_place() {
        // a b c _ א ב ג _ d e f
        let layout = bidi_layout("abc \u{05D0}\u{05D1}\u{05D2} def", LayoutOptions::SHAPED);
        assert_eq!(levels(&layout), vec![0, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0]);
        assert_eq!(
            display_cells(&layout),
            vec![0, 1, 2, 3, 6, 5, 4, 7, 8, 9, 10],
            "the Hebrew word turns around where it stands"
        );
    }

    #[test]
    fn a_right_to_left_paragraph_runs_from_the_right() {
        // א ב ג _ d e f
        let layout = bidi_layout("\u{05D0}\u{05D1}\u{05D2} def", LayoutOptions::SHAPED);
        assert_eq!(layout.direction, TextDirection::RightToLeft);
        assert_eq!(levels(&layout), vec![1, 1, 1, 1, 2, 2, 2]);
        assert_eq!(
            display_cells(&layout),
            vec![4, 5, 6, 3, 2, 1, 0],
            "the Latin word stays readable at the left end"
        );
        let x: Vec<f64> = layout.lines[0].display.iter().map(|(_, x)| *x).collect();
        assert!(x.windows(2).all(|pair| pair[1] > pair[0]), "and the pens only move rightwards");
    }

    #[test]
    fn digits_in_a_right_to_left_paragraph_keep_their_order() {
        // א ב _ 1 2 3
        let layout = bidi_layout("\u{05D0}\u{05D1} 123", LayoutOptions::SHAPED);
        assert_eq!(levels(&layout), vec![1, 1, 1, 2, 2, 2], "a number takes level two inside a level one");
        assert_eq!(display_cells(&layout), vec![3, 4, 5, 2, 1, 0]);
        let digits: Vec<usize> = display_cells(&layout).into_iter().take(3).collect();
        assert_eq!(digits, vec![3, 4, 5], "reading one two three, left to right");
    }

    #[test]
    fn a_neutral_character_takes_the_direction_around_it() {
        // The space between a Latin word and a Hebrew one belongs to neither, so it follows the
        // paragraph; the space inside the Hebrew run does not.
        let latin_first = bidi_layout("abc \u{05D0}\u{05D1}", LayoutOptions::SHAPED);
        assert_eq!(levels(&latin_first), vec![0, 0, 0, 0, 1, 1]);
        let hebrew_first = bidi_layout("\u{05D0}\u{05D1} abc", LayoutOptions::SHAPED);
        assert_eq!(levels(&hebrew_first), vec![1, 1, 1, 2, 2, 2]);
        // Punctuation between two Hebrew words is part of the right-to-left run.
        let with_hyphen = bidi_layout("\u{05D0}\u{05D1}-\u{05D2}\u{05D3}", LayoutOptions::SHAPED);
        assert_eq!(levels(&with_hyphen), vec![1, 1, 1, 1, 1]);
        assert_eq!(display_cells(&with_hyphen), vec![4, 3, 2, 1, 0]);
    }

    #[test]
    fn a_right_to_left_paragraph_keeps_the_baselines_of_a_left_to_right_one() {
        let style = TextStyle { content: "\u{05D0}\u{05D1}\n\u{05D2}".into(), font_size: 10.0, ..TextStyle::default() };
        let mut library = bare_library();
        let auto = layout_text(&style, &mut library);
        let forced = layout_text_with(
            &style,
            &mut library,
            LayoutOptions { direction: ParagraphDirection::LeftToRight, ..LayoutOptions::SHAPED },
        );
        assert_eq!(auto.direction, TextDirection::RightToLeft);
        assert_eq!(forced.direction, TextDirection::LeftToRight);
        assert_eq!(auto.line_height, forced.line_height);
        assert_eq!(auto.height, forced.height);
        assert_eq!(auto.chars.len(), forced.chars.len());
        for (rtl, ltr) in auto.lines.iter().zip(&forced.lines) {
            assert_eq!(rtl.baseline, ltr.baseline, "direction does not move a line up or down");
            assert_eq!(rtl.width, ltr.width, "nor does it change how wide the line is");
        }
        // The layout carries its direction, so a caller can align the way the text reads.
        assert!(auto.lines[0].rtl);
        assert!(!forced.lines[0].rtl);
    }

    // ---- mirrored brackets ----------------------------------------------

    #[test]
    fn a_bracket_turns_round_in_a_right_to_left_run() {
        for (from, to) in [
            ('(', ')'),
            (')', '('),
            ('[', ']'),
            (']', '['),
            ('{', '}'),
            ('}', '{'),
            ('<', '>'),
            ('>', '<'),
            ('\u{00AB}', '\u{00BB}'),
            ('\u{00BB}', '\u{00AB}'),
            ('\u{2039}', '\u{203A}'),
        ] {
            assert_eq!(mirrored_char(from, 1), to, "{from} at an odd level");
        }
    }

    #[test]
    fn a_bracket_keeps_its_form_in_a_left_to_right_run() {
        for ch in ['(', ')', '[', ']', '{', '}', '<', '>', '\u{00AB}', '\u{2039}'] {
            assert_eq!(mirrored_char(ch, 0), ch);
            assert_eq!(mirrored_char(ch, 2), ch, "an even level is left to right as well");
        }
    }

    #[test]
    fn a_character_without_a_mirror_is_never_touched() {
        // Letters, digits, and the quotation marks Unicode does not list as mirrored.
        for ch in ['a', 'A', '7', '+', '=', '*', '\u{201C}', '\u{201D}', '\u{0644}'] {
            assert_eq!(mirrored_char(ch, 1), ch, "{ch} has no mirror image");
        }
    }

    #[test]
    fn a_mirrored_symbol_without_a_pair_is_left_alone() {
        // U+2AFD carries the Bidi_Mirrored property but has no partner to swap with.
        assert!(unicode_bidi_mirroring::is_mirroring('\u{2AFD}'));
        assert_eq!(unicode_bidi_mirroring::get_mirrored('\u{2AFD}'), None);
        assert_eq!(mirrored_char('\u{2AFD}', 1), '\u{2AFD}');
    }

    #[test]
    fn a_right_to_left_paragraph_draws_brackets_mirrored() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Arial") {
            return;
        }
        let glyph_of = |layout: &TextLayout, cell: usize| {
            layout.glyphs.iter().find(|glyph| glyph.cell == cell).map(|glyph| glyph.glyph_id)
        };
        // Left to right, each bracket is drawn as the character it is stored as.
        let stored = layout_text(&text("Arial", "()", 48.0), &mut library);
        let stored_opening = glyph_of(&stored, 0);
        let stored_closing = glyph_of(&stored, 1);
        assert!(stored_opening.is_some() && stored_closing.is_some());
        assert_ne!(stored_opening, stored_closing);
        // Right to left, each one is drawn as its partner.
        let options = LayoutOptions { direction: ParagraphDirection::RightToLeft, ..LayoutOptions::SHAPED };
        let mirrored = layout_text_with(&text("Arial", "()", 48.0), &mut library, options);
        assert!(mirrored.chars.iter().all(|cell| cell.level % 2 == 1), "both brackets run right to left");
        assert_eq!(glyph_of(&mirrored, 0), stored_closing, "the opening bracket closes");
        assert_eq!(glyph_of(&mirrored, 1), stored_opening, "and the closing one opens");
    }

    #[test]
    fn a_left_to_right_paragraph_draws_brackets_as_stored() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Arial") {
            return;
        }
        let layout = layout_text(&text("Arial", "(a)", 48.0), &mut library);
        assert!(layout.chars.iter().all(|cell| cell.level == 0));
        let reference = layout_text(&text("Arial", "(", 48.0), &mut library);
        let drawn = layout.glyphs.iter().find(|glyph| glyph.cell == 0).map(|glyph| glyph.glyph_id);
        assert_eq!(drawn, reference.glyphs.first().map(|glyph| glyph.glyph_id));
    }

    #[test]
    fn brackets_around_a_latin_word_in_a_right_to_left_paragraph_turn_round() {
        // alef bet gimel, space, ( a b c ), space, dalet he vav
        let layout =
            bidi_layout("\u{05D0}\u{05D1}\u{05D2} (abc) \u{05D3}\u{05D4}\u{05D5}", LayoutOptions::SHAPED);
        assert!(layout.lines[0].rtl);
        assert_eq!(layout.chars[4].ch, '(');
        assert_eq!(layout.chars[8].ch, ')');
        assert_eq!(mirrored_char(layout.chars[4].ch, layout.chars[4].level), ')');
        assert_eq!(mirrored_char(layout.chars[8].ch, layout.chars[8].level), '(');
    }

    #[test]
    fn brackets_around_a_hebrew_word_in_a_latin_paragraph_stay_as_they_are() {
        // a b c, space, ( alef bet gimel ), space, d e f
        let layout = bidi_layout("abc (\u{05D0}\u{05D1}\u{05D2}) def", LayoutOptions::SHAPED);
        assert!(!layout.lines[0].rtl);
        assert_eq!(layout.chars[4].level, 0, "the brackets follow the paragraph, not the word inside");
        assert_eq!(layout.chars[8].level, 0);
        assert_eq!(mirrored_char(layout.chars[4].ch, layout.chars[4].level), '(');
        assert_eq!(mirrored_char(layout.chars[8].ch, layout.chars[8].level), ')');
    }

    #[test]
    fn a_comparison_sign_turns_round_in_a_right_to_left_run() {
        // alef, space, <, space, bet
        let layout = bidi_layout("\u{05D0} < \u{05D1}", LayoutOptions::SHAPED);
        assert!(layout.chars.iter().all(|cell| cell.level % 2 == 1));
        assert_eq!(mirrored_char(layout.chars[2].ch, layout.chars[2].level), '>');
        let left_to_right = bidi_layout("a < b", LayoutOptions::SHAPED);
        assert_eq!(mirrored_char(left_to_right.chars[2].ch, left_to_right.chars[2].level), '<');
    }

    #[test]
    fn a_direction_change_ends_a_shaped_run() {
        let Some(mut library) = system_library() else { return };
        if !has_face(&mut library, "Arial") {
            return;
        }
        let style = text("Arial", "abc \u{05D0}\u{05D1}\u{05D2}", 48.0);
        let layout = layout_text(&style, &mut library);
        assert!(layout.shaped);
        let x_of = |cell: usize| {
            layout.glyphs.iter().find(|glyph| glyph.cell == cell).map(|glyph| glyph.x).unwrap_or(f64::NAN)
        };
        assert!(
            x_of(4) > x_of(5) && x_of(5) > x_of(6),
            "the first Hebrew letter is drawn rightmost: {:?}",
            (4..=6).map(x_of).collect::<Vec<_>>()
        );
    }

}
