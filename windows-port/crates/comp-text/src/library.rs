//! Finding, aliasing and caching the faces a document asks for.
//!
//! A `.comp` file written on macOS names faces this machine has never heard of ("Helvetica",
//! "SFProText"). The library indexes every face installed here by all of its names, so a request can
//! be answered by an alias, and records every request it could not answer exactly so a caller can
//! tell the user which text was re-drawn in another face.

use crate::cache::{Cache, CacheStats};
use comp_core::text::TextStyle;
use crate::layout::{ParagraphKey, ParagraphLayout, StageTimes};
use crate::names::{self, FontNames, StyleHints};
use fontdue::{Font, FontSettings};
use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use unicode_script::UnicodeScript;

/// An environment variable that replaces the font directories, for headless builds and tests:
/// a `PATH`-style list of directories.
pub const FONT_DIRS_ENV: &str = "COMPOSITOR_FONT_DIRS";

/// How much of a font file the initial scan reads. The `name` table sits near the front in
/// every font seen in practice; a file whose table is past this is read whole before giving up.
const NAME_SCAN_BYTES: u64 = 128 * 1024;

/// Faces read out of one collection file. Some CJK collections hold dozens; the limit keeps a scan
/// bounded without hiding the faces a document is likely to name.
const MAX_COLLECTION_FACES: u32 = 16;

/// Faces that stand in for a missing one, best first. The order is the Windows look-alike order for
/// the macOS system font, so text re-drawn without its own face stays close to what it looked like.
const DEFAULT_FACES: [&str; 8] =
    ["Segoe UI", "Arial", "Tahoma", "Calibri", "Verdana", "Liberation Sans", "DejaVu Sans", "Noto Sans"];

/// The faces the general chain offers, after a script's own chain has run out: whatever covers the
/// widest range of writing systems on this machine.
const OTHER_FACES: [&str; 10] = [
    "Microsoft YaHei",
    "SimSun",
    "Malgun Gothic",
    "Yu Gothic",
    "Microsoft JhengHei",
    "Segoe UI Symbol",
    "Segoe UI Emoji",
    "Arial Unicode MS",
    "Segoe UI",
    "Arial",
];

/// Chinese, in either form.
const HAN_FACES: [&str; 7] =
    ["Microsoft YaHei", "SimSun", "SimHei", "Microsoft JhengHei", "MingLiU", "MS Gothic", "Malgun Gothic"];
/// Japanese: the kana and the kanji as Japan draws them, before the Chinese faces.
const JAPANESE_FACES: [&str; 4] = ["Yu Gothic", "MS Gothic", "Meiryo", "Microsoft YaHei"];
/// Korean, where hangul lives in its own faces.
const KOREAN_FACES: [&str; 4] = ["Malgun Gothic", "Batang", "Gulim", "Microsoft YaHei"];
const ARABIC_FACES: [&str; 5] = ["Segoe UI", "Tahoma", "Arial", "Traditional Arabic", "Microsoft Sans Serif"];
const HEBREW_FACES: [&str; 5] = ["Segoe UI", "Arial", "Tahoma", "David", "Nirmala UI"];
/// Devanagari and the scripts around it, which Nirmala UI covers together.
const INDIC_FACES: [&str; 6] = ["Nirmala UI", "Mangal", "Aparajita", "Utsaah", "Kokila", "Microsoft YaHei"];
const THAI_FACES: [&str; 5] = ["Leelawadee UI", "Leelawadee", "Tahoma", "Cordia New", "Microsoft Sans Serif"];
const EMOJI_FACES: [&str; 4] = ["Segoe UI Emoji", "Segoe UI Symbol", "Segoe UI", "Arial"];
/// Arrows, mathematics, dingbats and the other symbol blocks, which have a face of their own.
const SYMBOL_FACES: [&str; 4] = ["Segoe UI Symbol", "Segoe UI", "Arial", "Cambria Math"];

/// A group of scripts that shares one fallback chain.
///
/// Windows links fonts per character rather than per run, and which face should stand in depends on
/// what the character is: a Han character wants a Chinese face, and asking a Latin face first would
/// only find a box. Each class names its faces best first, and a face is used only when it really
/// has the glyph.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ScriptClass {
    /// Han characters, in either the simplified or the traditional form.
    Han,
    /// Japanese: hiragana, katakana and the kanji as Japan sets them.
    Japanese,
    /// Korean hangul.
    Korean,
    /// Arabic and the scripts written with it.
    Arabic,
    Hebrew,
    /// Devanagari and the scripts Nirmala UI also covers.
    Indic,
    /// Thai and the neighbouring mainland scripts.
    Thai,
    /// Pictographs, which only an emoji face draws.
    Emoji,
    /// Arrows, mathematics and the other symbol blocks.
    Symbols,
    /// Latin, Greek, Cyrillic and everything else a general face already covers.
    Other,
}

impl ScriptClass {
    /// The class a character belongs to.
    pub fn of(ch: char) -> ScriptClass {
        if is_emoji(ch) {
            return ScriptClass::Emoji;
        }
        match ch.script().short_name() {
            "Hans" | "Hant" | "Hanb" | "Hani" => ScriptClass::Han,
            "Hira" | "Kana" | "Jpan" => ScriptClass::Japanese,
            "Hang" | "Kore" => ScriptClass::Korean,
            "Arab" | "Syrc" | "Thaa" | "Nkoo" | "Adlm" | "Mand" | "Samr" => ScriptClass::Arabic,
            "Hebr" => ScriptClass::Hebrew,
            "Deva" | "Beng" | "Guru" | "Gujr" | "Orya" | "Taml" | "Telu" | "Knda" | "Mlym" | "Sinh" => {
                ScriptClass::Indic
            }
            "Thai" | "Laoo" | "Khmr" | "Mymr" => ScriptClass::Thai,
            // Common and inherited characters are digits, punctuation and symbols; the symbol
            // blocks want a symbol face, and everything else is already in the face at hand.
            "Zyyy" | "Zinh" if is_symbol(ch) => ScriptClass::Symbols,
            _ => ScriptClass::Other,
        }
    }

    /// The faces that stand in for this class, best first. A name here is resolved like any other
    /// request, so an alias or a style still applies, and a face this machine does not have is
    /// skipped.
    pub fn faces(self) -> &'static [&'static str] {
        match self {
            ScriptClass::Han => &HAN_FACES,
            ScriptClass::Japanese => &JAPANESE_FACES,
            ScriptClass::Korean => &KOREAN_FACES,
            ScriptClass::Arabic => &ARABIC_FACES,
            ScriptClass::Hebrew => &HEBREW_FACES,
            ScriptClass::Indic => &INDIC_FACES,
            ScriptClass::Thai => &THAI_FACES,
            ScriptClass::Emoji => &EMOJI_FACES,
            ScriptClass::Symbols => &SYMBOL_FACES,
            ScriptClass::Other => &OTHER_FACES,
        }
    }
}

/// True for the pictographs an emoji face draws: the pictographic blocks, the regional indicators
/// that make flags, and the older symbol and dingbat characters that carry an emoji presentation.
fn is_emoji(ch: char) -> bool {
    matches!(ch as u32,
        // The regional indicators that make flags sit inside the pictographic range.
        0x1F000..=0x1FAFF
        | 0x2600..=0x27BF
        | 0x2B00..=0x2BFF
        | 0x2049 | 0x203C | 0x2122 | 0x2139 | 0x231A..=0x231B | 0x2328 | 0x23CF | 0x23E9..=0x23FA
        | 0x24C2 | 0x25AA..=0x25AB | 0x25B6 | 0x25C0 | 0x25FB..=0x25FE | 0x2934..=0x2935
        | 0x3030 | 0x303D | 0x3297 | 0x3299 | 0xFE0F)
}

/// True for the blocks that hold arrows, mathematics and other symbols rather than letters.
fn is_symbol(ch: char) -> bool {
    matches!(ch as u32,
        0x2000..=0x2BFF | 0x3000..=0x303F | 0xFE30..=0xFE4F | 0xFF00..=0xFFEF | 0x1D000..=0x1D7FF)
}

/// Shaped runs held before the oldest are dropped.
pub const DEFAULT_SHAPE_CACHE: usize = 4096;

/// Laid-out paragraphs held before the oldest are dropped.
pub const DEFAULT_LAYOUT_CACHE: usize = 1024;

/// One glyph of a shaped run, as the shaper returned it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ShapedGlyph {
    /// Byte offset of the cluster this glyph belongs to, in the text that was shaped.
    pub cluster: u32,
    pub glyph_id: u16,
    pub x_advance: f64,
    pub x_offset: f64,
    pub y_offset: f64,
}

/// Everything that changes what a run of text shapes to.
///
/// The text is the run's own, so two runs that differ only in where they sit in the document share
/// an entry. Tracking does not change a glyph — it is added between characters when a line is
/// measured — and is part of the key so that a caller keying a whole text style stays consistent.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ShapeKey {
    /// The library's index of the face the run is set in.
    pub face: usize,
    /// The ISO 15924 tag of the script the run is shaped as.
    pub script: [u8; 4],
    /// True when the run runs right to left.
    pub rtl: bool,
    /// The font size in bits, since a float has no equality worth hashing.
    pub font_size: u32,
    /// Tracking in bits.
    pub tracking: u64,
    pub text: String,
}

impl ShapeKey {
    pub fn new(
        face: usize,
        script: [u8; 4],
        rtl: bool,
        font_size: f32,
        tracking: f64,
        text: impl Into<String>,
    ) -> ShapeKey {
        ShapeKey { face, script, rtl, font_size: font_size.to_bits(), tracking: tracking.to_bits(), text: text.into() }
    }
}

/// One face installed on this machine, with every name it answers to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FontFace {
    pub path: PathBuf,
    pub collection_index: u32,
    pub family: String,
    pub subfamily: String,
    pub full_name: String,
    pub post_script: String,
    pub bold: bool,
    pub italic: bool,
    keys: Vec<String>,
}

impl FontFace {
    /// Builds a face record. `None` when the font has no name at all and the file name
    /// carries none either.
    pub fn from_names(path: PathBuf, collection_index: u32, names: &FontNames) -> Option<FontFace> {
        let family = names
            .display_family()
            .map(str::to_string)
            .or_else(|| names.full_name.clone())
            .or_else(|| file_stem(&path))?;
        let full_name = names.full_name.clone().unwrap_or_else(|| family.clone());
        let subfamily = names.subfamily.clone().unwrap_or_default();
        let bold_italic = weight_of(&family, &subfamily, &full_name);
        let post_script = names.post_script.clone().unwrap_or_default();
        let mut keys = names.keys();
        push_key(&mut keys, &file_stem(&path).unwrap_or_default());
        Some(FontFace {
            path,
            collection_index,
            family,
            subfamily,
            full_name,
            post_script,
            bold: bold_italic.bold,
            italic: bold_italic.italic,
            keys,
        })
    }

    /// A face with no weight or slant of its own: the one a bare family name means.
    pub fn is_regular(&self) -> bool {
        !self.bold && !self.italic
    }

    /// The names this face answers to, normalized.
    pub fn keys(&self) -> &[String] {
        &self.keys
    }
}

/// Reads the weight and slant of a face.
///
/// The subfamily says it outright ("Bold", "Bold Italic"). Families like "Segoe UI Semibold" instead
/// carry the weight in the family name and call the subfamily "Regular", so the family is read next,
/// and finally the words the full name adds to the family. Every step matches whole words, so
/// "Blackadder ITC" is not mistaken for a bold face.
fn weight_of(family: &str, subfamily: &str, full_name: &str) -> StyleHints {
    let hints = word_hints(subfamily);
    if hints != StyleHints::default() {
        return hints;
    }
    let hints = word_hints(family);
    if hints != StyleHints::default() {
        return hints;
    }
    let family_key = names::normalize(family);
    let full_key = names::normalize(full_name);
    let extra = full_key.strip_prefix(&family_key).unwrap_or(&full_key);
    names::style_hints(extra)
}

/// The weight and slant a name asks for when it is read word by word.
fn word_hints(name: &str) -> StyleHints {
    const BOLD_WORDS: [&str; 8] =
        ["bold", "black", "heavy", "semibold", "demibold", "extrabold", "ultrabold", "ultrablack"];
    const ITALIC_WORDS: [&str; 2] = ["italic", "oblique"];
    let mut hints = StyleHints::default();
    for word in name.split(|c: char| !c.is_alphanumeric()) {
        let word = word.to_ascii_lowercase();
        hints.bold |= BOLD_WORDS.contains(&word.as_str());
        hints.italic |= ITALIC_WORDS.contains(&word.as_str());
    }
    hints
}

fn file_stem(path: &Path) -> Option<String> {
    path.file_stem().and_then(|stem| stem.to_str()).map(str::to_string)
}

fn push_key(keys: &mut Vec<String>, name: &str) {
    let key = names::normalize(name);
    if !key.is_empty() && !keys.iter().any(|existing| existing == &key) {
        keys.push(key);
    }
}

/// A request that could not be answered with the face it named.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FontFallback {
    pub requested: String,
    pub used: String,
}

/// The installed faces, plus the fonts already parsed out of them.
///
/// Loading a face parses its outlines, so every face is loaded once and shared through `Arc`.
pub struct FontLibrary {
    dirs: Vec<PathBuf>,
    faces: Arc<Vec<FontFace>>,
    by_key: HashMap<String, usize>,
    default_index: Option<usize>,
    /// Loaded faces, with the index they came from so a caller can ask for the raw bytes again.
    fonts: HashMap<(PathBuf, u32), Option<(usize, Arc<Font>)>>,
    /// The bytes of every face that has been read, kept because the shaper parses the font itself:
    /// `fontdue` consumes the data it is given, and re-reading a 20 MB collection on every keystroke
    /// is not worth it.
    bytes: HashMap<(PathBuf, u32), Option<Arc<Vec<u8>>>>,
    resolutions: HashMap<String, Option<usize>>,
    glyph_faces: HashMap<char, Option<Arc<Font>>>,
    /// The face indices each script class resolves to on this machine, worked out once.
    chains: HashMap<ScriptClass, Vec<usize>>,
    /// Shaped runs, so typing in one paragraph does not shape the rest again.
    shapes: Cache<ShapeKey, Vec<ShapedGlyph>>,
    /// Laid-out paragraphs, so a keystroke only re-lays out the paragraph it changed.
    layouts: Cache<ParagraphKey, ParagraphLayout>,
    /// Where the last layout spent its time, for a benchmark or a diagnostics panel.
    stages: StageTimes,
    fallbacks: Vec<FontFallback>,
}

impl Default for FontLibrary {
    fn default() -> Self {
        FontLibrary::new()
    }
}

impl std::fmt::Debug for FontLibrary {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FontLibrary")
            .field("dirs", &self.dirs)
            .field("faces", &self.faces.len())
            .field("loaded", &self.fonts.len())
            .field("fallbacks", &self.fallbacks.len())
            .finish()
    }
}

/// The scan of the default directories is shared process-wide: it reads every installed font once,
/// and every library would otherwise repeat it.
static SYSTEM_FACES: OnceLock<Arc<Vec<FontFace>>> = OnceLock::new();

impl FontLibrary {
    /// The fonts installed on this machine.
    pub fn new() -> Self {
        let dirs = default_font_dirs();
        let faces = SYSTEM_FACES.get_or_init(|| Arc::new(scan_dirs(&dirs))).clone();
        FontLibrary::with_shared_faces(dirs, faces)
    }

    /// A library that only sees `dirs`, scanned now.
    pub fn with_font_dirs(dirs: Vec<PathBuf>) -> Self {
        let faces = Arc::new(scan_dirs(&dirs));
        FontLibrary::with_shared_faces(dirs, faces)
    }

    /// A library over faces the caller already found, for embedding a font set or for tests.
    pub fn from_faces(dirs: Vec<PathBuf>, faces: Vec<FontFace>) -> Self {
        FontLibrary::with_shared_faces(dirs, Arc::new(faces))
    }

    fn with_shared_faces(dirs: Vec<PathBuf>, faces: Arc<Vec<FontFace>>) -> Self {
        let by_key = build_index(&faces);
        let default_index = DEFAULT_FACES
            .iter()
            .find_map(|name| resolve_in(&faces, &by_key, name))
            .or(if faces.is_empty() { None } else { Some(0) });
        FontLibrary {
            dirs,
            faces,
            by_key,
            default_index,
            fonts: HashMap::new(),
            bytes: HashMap::new(),
            resolutions: HashMap::new(),
            glyph_faces: HashMap::new(),
            chains: HashMap::new(),
            shapes: Cache::new(DEFAULT_SHAPE_CACHE),
            layouts: Cache::new(DEFAULT_LAYOUT_CACHE),
            stages: StageTimes::default(),
            fallbacks: Vec::new(),
        }
    }

    /// Every face found, in scan order.
    pub fn faces(&self) -> &[FontFace] {
        &self.faces
    }

    pub fn len(&self) -> usize {
        self.faces.len()
    }

    pub fn is_empty(&self) -> bool {
        self.faces.is_empty()
    }

    /// The directories this library scanned.
    pub fn dirs(&self) -> &[PathBuf] {
        &self.dirs
    }

    /// Requests that had to be answered with another face, in the order they happened.
    pub fn fallbacks(&self) -> &[FontFallback] {
        &self.fallbacks
    }

    pub fn clear_fallbacks(&mut self) {
        self.fallbacks.clear();
    }

    /// The full name of the face `name` resolves to, without loading it.
    pub fn resolved_name(&mut self, name: &str) -> Option<String> {
        let index = self.resolve(name)?;
        self.faces.get(index).map(|face| face.full_name.clone())
    }

    /// The font for a face name, loading and caching it. Missing faces fall back to the system
    /// default and are recorded; `None` only when no face could be loaded at all.
    pub fn font_for(&mut self, name: &str) -> Option<Arc<Font>> {
        if let Some(index) = self.resolve(name) {
            if let Some(font) = self.load(index) {
                return Some(font);
            }
        }
        let index = self.default_index?;
        let font = self.load(index)?;
        self.record_fallback(name, index);
        Some(font)
    }

    /// The stand-in face for text whose own face is missing.
    pub fn default_font(&mut self) -> Option<Arc<Font>> {
        let index = self.default_index?;
        self.load(index)
    }

    /// The full name of the stand-in face.
    pub fn default_name(&self) -> Option<&str> {
        self.default_index.and_then(|index| self.faces.get(index)).map(|face| face.full_name.as_str())
    }

    /// A face that has a glyph for `ch`, preferring `primary`. Windows links fonts per
    /// character; this is the short version of that, so a document with two scripts still draws.
    pub fn glyph_font(&mut self, primary: Option<&Arc<Font>>, ch: char) -> Option<Arc<Font>> {
        if let Some(primary) = primary {
            if primary.has_glyph(ch) {
                return Some(primary.clone());
            }
        }
        if let Some(cached) = self.glyph_faces.get(&ch) {
            return cached.clone();
        }
        let found = self.linked_face(primary, ch);
        self.glyph_faces.insert(ch, found.clone());
        found
    }

    /// A face other than `primary` that has a glyph for `ch`.
    ///
    /// Shaping can leave a character as the missing-glyph box even though the face's character map
    /// claims it: faces disagree about which subtable matters, and Marlett maps Latin letters in the
    /// table `fontdue` reads while the shaper finds nothing there. The second chance therefore has
    /// to skip the face that just failed.
    pub fn linked_font(&mut self, primary: Option<&Arc<Font>>, ch: char) -> Option<Arc<Font>> {
        self.linked_face(primary, ch)
    }

    fn linked_face(&mut self, primary: Option<&Arc<Font>>, ch: char) -> Option<Arc<Font>> {
        let class = ScriptClass::of(ch);
        let mut tried: Vec<usize> = self.chain(class);
        if class != ScriptClass::Other {
            // The general chain is the last resort, for a machine that has no face of the script.
            tried.extend(self.chain(ScriptClass::Other));
        }
        for index in tried {
            let Some(font) = self.load(index) else { continue };
            let already_tried = primary.map(|primary| Arc::ptr_eq(primary, &font)).unwrap_or(false);
            if !already_tried && font.has_glyph(ch) {
                return Some(font);
            }
        }
        None
    }

    /// The faces a script class resolves to on this machine, best first, worked out once.
    fn chain(&mut self, class: ScriptClass) -> Vec<usize> {
        if let Some(cached) = self.chains.get(&class) {
            return cached.clone();
        }
        let mut chain = Vec::new();
        for name in class.faces() {
            let Some(index) = resolve_in(&self.faces, &self.by_key, name) else { continue };
            if !chain.contains(&index) {
                chain.push(index);
            }
        }
        self.chains.insert(class, chain.clone());
        chain
    }

    /// The faces this machine has from a script's chain, best first.
    pub fn script_chain(&mut self, class: ScriptClass) -> Vec<FontFace> {
        self.chain(class).into_iter().filter_map(|index| self.faces.get(index).cloned()).collect()
    }

    /// The face that stands in for a character the face at hand has no glyph for: the first face of
    /// the character's script chain that really has one.
    ///
    /// A face is only used when it has the glyph, so a machine missing the first choice still draws
    /// the text; none when no installed face can draw the character at all.
    pub fn script_font(&mut self, primary: Option<&Arc<Font>>, ch: char) -> Option<Arc<Font>> {
        self.linked_face(primary, ch)
    }

    /// The shaped glyphs of a run, when the same run has been shaped before.
    pub fn cached_shape(&mut self, key: &ShapeKey) -> Option<Arc<Vec<ShapedGlyph>>> {
        self.shapes.get(key)
    }

    /// Keeps the shaped glyphs of a run, and hands back the shared copy.
    pub fn store_shape(&mut self, key: ShapeKey, glyphs: Vec<ShapedGlyph>) -> Arc<Vec<ShapedGlyph>> {
        self.shapes.insert(key, glyphs)
    }

    /// What the shaping cache has been doing.
    pub fn shape_stats(&self) -> CacheStats {
        self.shapes.stats()
    }

    pub fn clear_shape_cache(&mut self) {
        self.shapes.clear();
    }

    pub fn set_shape_cache_capacity(&mut self, capacity: usize) {
        self.shapes.set_capacity(capacity);
    }

    /// The laid-out paragraphs of a text, when the same paragraph with the same style was laid out
    /// before.
    pub(crate) fn cached_paragraph(&mut self, key: &ParagraphKey) -> Option<Arc<ParagraphLayout>> {
        self.layouts.get(key)
    }

    /// Keeps a laid-out paragraph, and hands back the shared copy.
    pub(crate) fn store_paragraph(
        &mut self,
        key: ParagraphKey,
        layout: ParagraphLayout,
    ) -> Arc<ParagraphLayout> {
        self.layouts.insert(key, layout)
    }

    /// What the layout cache has been doing.
    pub fn layout_stats(&self) -> CacheStats {
        self.layouts.stats()
    }

    /// Where the last layout spent its time, in nanoseconds.
    pub fn stage_times(&self) -> StageTimes {
        self.stages
    }

    pub(crate) fn report_stages(&mut self, stages: StageTimes) {
        self.stages = stages;
    }

    pub fn clear_layout_cache(&mut self) {
        self.layouts.clear();
    }

    pub fn set_layout_cache_capacity(&mut self, capacity: usize) {
        self.layouts.set_capacity(capacity);
    }

    /// Loads the faces a document names, before anything is laid out, and answers how many faces
    /// it actually loaded (a second call for the same names loads nothing).
    ///
    /// Parsing a large CJK face costs about a fifth of a second, which is nine tenths of what a
    /// first layout spends; a GUI that is opening a document can pay that once, off the typing
    /// path, and the first layout is then the layout.
    pub fn prepare<'a>(&mut self, names: impl IntoIterator<Item = &'a str>) -> usize {
        let mut loaded = 0;
        for name in names {
            let before = self.fonts.len();
            let resolved = self.font_for(name).is_some();
            if resolved && self.fonts.len() > before {
                loaded += 1;
            }
        }
        loaded
    }

    /// Loads everything a text layer will want: the face its style names, and the fallbacks its
    /// characters reach for, which is the same path the layout would take lazily.
    ///
    /// Falling back is lazy, so a Latin face asked to show Chinese loads a CJK face in the middle of
    /// the first layout; asking for it here keeps that out of the layout too.
    pub fn prepare_style(&mut self, style: &TextStyle) -> usize {
        let before = self.fonts.len();
        let base = self.font_for(&style.font_name);
        for ch in style.content.chars() {
            if ch.is_whitespace() || ch.is_control() || crate::layout::is_default_ignorable(ch) {
                continue;
            }
            self.glyph_font(base.as_ref(), ch);
        }
        self.fonts.len().saturating_sub(before)
    }

    /// The index of the face a request resolves to, cached per request.
    fn resolve(&mut self, name: &str) -> Option<usize> {
        let key = names::normalize(name);
        if let Some(cached) = self.resolutions.get(&key) {
            return *cached;
        }
        let resolved = resolve_in(&self.faces, &self.by_key, name);
        self.resolutions.insert(key, resolved);
        resolved
    }

    fn load(&mut self, index: usize) -> Option<Arc<Font>> {
        let face = self.faces.get(index)?.clone();
        let key = (face.path.clone(), face.collection_index);
        if let Some(cached) = self.fonts.get(&key) {
            return cached.clone().map(|(_, font)| font);
        }
        let font = std::fs::read(&face.path).ok().and_then(|data| {
            // Shaping is rustybuzz's job and rasterization is by glyph id, so fontdue's substitution
            // table is never consulted. Building it anyway costs a CJK face a fifth of a second, which
            // is most of the time the first layout takes.
            let settings = FontSettings {
                collection_index: face.collection_index,
                load_substitutions: false,
                ..FontSettings::default()
            };
            Font::from_bytes(data, settings).ok().map(Arc::new)
        });
        self.fonts.insert(key, font.clone().map(|font| (index, font)));
        font
    }

    /// The face a loaded font came from, for a caller that needs its file or its raw bytes.
    pub fn index_of(&self, font: &Arc<Font>) -> Option<usize> {
        self.fonts.values().flatten().find(|(_, cached)| Arc::ptr_eq(cached, font)).map(|(index, _)| *index)
    }

    /// One face, by the index this library gave it.
    pub fn face(&self, index: usize) -> Option<&FontFace> {
        self.faces.get(index)
    }

    /// The bytes of a face, read once and shared: the shaper parses the font itself, so unlike
    /// `fontdue` it cannot be handed an already parsed face.
    pub fn face_bytes(&mut self, index: usize) -> Option<Arc<Vec<u8>>> {
        let face = self.faces.get(index)?.clone();
        let key = (face.path.clone(), face.collection_index);
        if let Some(cached) = self.bytes.get(&key) {
            return cached.clone();
        }
        let data = std::fs::read(&face.path).ok().map(Arc::new);
        self.bytes.insert(key, data.clone());
        data
    }

    fn record_fallback(&mut self, requested: &str, used_index: usize) {
        if self.fallbacks.iter().any(|fallback| fallback.requested == requested) {
            return;
        }
        let used = self
            .faces
            .get(used_index)
            .map(|face| face.full_name.clone())
            .unwrap_or_else(|| "none".to_string());
        self.fallbacks.push(FontFallback { requested: requested.to_string(), used });
    }
}

/// Maps every name onto the face indices that answer to it. Regular faces are inserted first so a
/// bare family name means the regular weight even when a weightier face lists the family too.
fn build_index(faces: &[FontFace]) -> HashMap<String, usize> {
    let mut by_key = HashMap::new();
    for regular_pass in [true, false] {
        for (index, face) in faces.iter().enumerate() {
            if face.is_regular() != regular_pass {
                continue;
            }
            for key in face.keys() {
                by_key.entry(key.clone()).or_insert(index);
            }
        }
    }
    by_key
}

/// The face a name resolves to: the name itself, a macOS alias for it, or the same family in the
/// weight and slant the name asks for.
fn resolve_in(faces: &[FontFace], by_key: &HashMap<String, usize>, requested: &str) -> Option<usize> {
    let key = names::normalize(requested);
    if key.is_empty() {
        return None;
    }
    if let Some(&index) = by_key.get(&key) {
        return Some(index);
    }
    if let Some(alias) = macos_alias(&key) {
        if let Some(&index) = by_key.get(&names::normalize(alias)) {
            return Some(index);
        }
    }
    let hints = names::style_hints(&key);
    let base = names::strip_style_words(&key);
    if base.is_empty() {
        return None;
    }
    let base = macos_alias(&base).map(names::normalize).unwrap_or(base);
    let mut family_match = None;
    for (index, face) in faces.iter().enumerate() {
        // A face answers to its family only through its own keys: "Arial Narrow" is typographic
        // family "Arial", and taking that at face value would hand every Arial request to it.
        if !face.keys().contains(&base) {
            continue;
        }
        if face.bold == hints.bold && face.italic == hints.italic {
            return Some(index);
        }
        family_match.get_or_insert(index);
    }
    family_match
}

/// The macOS face names with no Windows counterpart, mapped onto the closest installed family.
///
/// Only base families are listed: "Helvetica-Bold" is answered by looking up "Helvetica" here and
/// then taking the alias family's bold face, so a new weight never needs a new entry.
pub fn macos_alias(key: &str) -> Option<&'static str> {
    Some(match key {
        "helvetica" | "helveticaneue" | "arialmt" | "arial" => "Arial",
        "sfpro" | "sfprotext" | "sfprodisplay" | "sfcompacttext" | "sfcompactdisplay" | "sfns"
        | "sfnsdisplay" | "sfnstext" | "sfnsmono" | "sanfrancisco" | "sanfranciscodisplay"
        | "sanfranciscotext" | "applesystemuifont" | "systemfont" | "system" => "Segoe UI",
        "avenir" | "avenirnext" => "Segoe UI",
        "times" | "timesroman" | "timesnewromanps" | "timesnewroman" => "Times New Roman",
        "courier" | "couriernewps" | "couriernew" => "Courier New",
        "lucidagrande" => "Lucida Sans Unicode",
        "geneva" => "Tahoma",
        "monaco" | "menlo" | "sfmono" => "Consolas",
        "chalkboard" | "chalkboardse" | "chalkduster" => "Comic Sans MS",
        "didot" | "bodoni" | "bodoni72" | "bodoni72oldstyle" => "Bodoni MT",
        "baskerville" => "Baskerville Old Face",
        "gillsans" | "gillsansmt" => "Gill Sans MT",
        "copperplate" => "Copperplate Gothic Bold",
        "optima" => "Candara",
        "futura" => "Century Gothic",
        "zapfino" => "Segoe Script",
        "noteworthy" | "markerfelt" => "Segoe Print",
        "rockwell" => "Rockwell",
        "hiraginosansgb" | "hiraginokakugothic" | "hiraginokakugothicpro" | "hiraginominchopro"
        | "pingfang" | "pingfangsc" | "heitisc" | "heiti" | "yahei" => "Microsoft YaHei",
        "stsong" | "songti" | "songtisc" | "simsun" => "SimSun",
        "kaiti" | "kaitisc" => "KaiTi",
        "osaka" | "osakamono" => "MS Gothic",
        _ => return None,
    })
}

/// The directories searched for fonts, most specific first.
fn default_font_dirs() -> Vec<PathBuf> {
    if let Some(dirs) = std::env::var_os(FONT_DIRS_ENV) {
        let dirs: Vec<PathBuf> = std::env::split_paths(&dirs).collect();
        if !dirs.is_empty() {
            return dirs;
        }
    }
    let mut dirs = Vec::new();
    match std::env::var_os("SystemRoot") {
        Some(root) => dirs.push(PathBuf::from(root).join("Fonts")),
        None if cfg!(windows) => dirs.push(PathBuf::from(r"C:\Windows\Fonts")),
        None => {}
    }
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        dirs.push(PathBuf::from(local).join("Microsoft").join("Windows").join("Fonts"));
    }
    if let Some(home) = std::env::var_os("HOME") {
        dirs.push(PathBuf::from(home).join("Library").join("Fonts"));
    }
    for shared in ["/usr/share/fonts", "/usr/local/share/fonts", "/System/Library/Fonts"] {
        dirs.push(PathBuf::from(shared));
    }
    dirs
}

/// Every face in every directory, in a stable order and without duplicates.
fn scan_dirs(dirs: &[PathBuf]) -> Vec<FontFace> {
    let mut faces = Vec::new();
    let mut seen: Vec<(String, String, String)> = Vec::new();
    for dir in dirs {
        let Ok(entries) = std::fs::read_dir(dir) else { continue };
        let mut paths: Vec<PathBuf> = entries
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| is_font_file(path))
            .collect();
        paths.sort();
        for path in paths {
            for face in faces_in(&path) {
                let key = (
                    names::normalize(&face.family),
                    names::normalize(&face.subfamily),
                    names::normalize(&face.full_name),
                );
                if seen.contains(&key) {
                    continue;
                }
                seen.push(key);
                faces.push(face);
            }
        }
    }
    faces
}

fn is_font_file(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|ext| ext.to_str()).map(str::to_ascii_lowercase).as_deref(),
        Some("ttf" | "otf" | "ttc" | "otc")
    )
}

/// The faces one font file holds. The head of the file answers in almost every case; a file whose
/// name table sits past it is read whole rather than indexed by file name alone.
fn faces_in(path: &Path) -> Vec<FontFace> {
    let Some(head) = read_head(path, NAME_SCAN_BYTES) else { return Vec::new() };
    let complete = (head.len() as u64) < NAME_SCAN_BYTES;
    let count = names::face_count(&head).min(MAX_COLLECTION_FACES);
    let mut faces = Vec::new();
    let mut unnamed = false;
    for index in 0..count {
        match names::parse(&head, index) {
            Some(found) => {
                if let Some(face) = FontFace::from_names(path.to_path_buf(), index, &found) {
                    faces.push(face);
                }
            }
            None => unnamed = true,
        }
    }
    if !unnamed || complete {
        return faces;
    }
    let Ok(data) = std::fs::read(path) else { return faces };
    let count = names::face_count(&data).min(MAX_COLLECTION_FACES);
    let mut faces = Vec::new();
    for index in 0..count {
        let found = names::parse(&data, index).unwrap_or_default();
        if let Some(face) = FontFace::from_names(path.to_path_buf(), index, &found) {
            faces.push(face);
        }
    }
    faces
}

fn read_head(path: &Path, bytes: u64) -> Option<Vec<u8>> {
    let mut file = std::fs::File::open(path).ok()?;
    let mut buffer = Vec::with_capacity(bytes as usize);
    file.by_ref().take(bytes).read_to_end(&mut buffer).ok()?;
    Some(buffer)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn face(file: &str, family: &str, subfamily: &str, post_script: &str) -> FontFace {
        let names = FontNames {
            family: Some(family.to_string()),
            subfamily: Some(subfamily.to_string()),
            full_name: Some(if subfamily == "Regular" {
                family.to_string()
            } else {
                format!("{family} {subfamily}")
            }),
            post_script: Some(post_script.to_string()),
            ..FontNames::default()
        };
        FontFace::from_names(PathBuf::from(file), 0, &names).unwrap()
    }

    /// Two faces of one family, the shape every alias lookup has to get right.
    fn arial_like() -> Vec<FontFace> {
        vec![
            face("arial.ttf", "Arial", "Regular", "ArialMT"),
            face("arialbd.ttf", "Arial", "Bold", "Arial-BoldMT"),
            face("ariali.ttf", "Arial", "Italic", "Arial-ItalicMT"),
        ]
    }

    fn resolve(faces: &[FontFace], name: &str) -> Option<usize> {
        resolve_in(faces, &build_index(faces), name)
    }

    #[test]
    fn a_family_name_means_its_regular_face() {
        let faces = arial_like();
        assert_eq!(resolve(&faces, "Arial"), Some(0));
        assert_eq!(resolve(&faces, "ArialMT"), Some(0));
        assert_eq!(resolve(&faces, "Arial Regular"), Some(0));
    }

    #[test]
    fn a_style_name_picks_that_style() {
        let faces = arial_like();
        assert_eq!(resolve(&faces, "Arial Bold"), Some(1));
        assert_eq!(resolve(&faces, "Arial-BoldMT"), Some(1));
        assert_eq!(resolve(&faces, "Arial Italic"), Some(2));
    }

    #[test]
    fn macos_aliases_take_the_alias_family_style() {
        let faces = arial_like();
        assert_eq!(resolve(&faces, "Helvetica"), Some(0));
        assert_eq!(resolve(&faces, "Helvetica-Bold"), Some(1));
        assert_eq!(resolve(&faces, "Helvetica-Oblique"), Some(2));
    }

    #[test]
    fn a_style_alias_does_not_land_on_a_narrow_face() {
        // "Arial Narrow" is typographic family "Arial"; a Helvetica-Bold request has to reach the
        // bold Arial, not the narrow one that happens to share the typographic family.
        let narrow = FontFace::from_names(
            PathBuf::from("ARIALNB.TTF"),
            0,
            &FontNames {
                family: Some("Arial Narrow".into()),
                subfamily: Some("Bold".into()),
                full_name: Some("Arial Narrow Bold".into()),
                post_script: Some("ArialNarrow-Bold".into()),
                typographic_family: Some("Arial".into()),
                typographic_subfamily: Some("Narrow".into()),
            },
        )
        .unwrap();
        let mut faces = vec![narrow];
        faces.extend(arial_like());
        assert_eq!(resolve(&faces, "Arial"), Some(1));
        assert_eq!(resolve(&faces, "Helvetica-Bold"), Some(2));
        assert_eq!(resolve(&faces, "Arial Narrow"), Some(0));
        assert_eq!(resolve(&faces, "Arial Narrow Bold"), Some(0));
    }

    #[test]
    fn unknown_names_resolve_to_nothing() {
        let faces = arial_like();
        assert_eq!(resolve(&faces, "No Such Face"), None);
        assert_eq!(resolve(&faces, ""), None);
        assert_eq!(resolve(&faces, "---"), None);
    }

    #[test]
    fn alias_table_covers_the_macos_default_faces() {
        assert_eq!(macos_alias("helvetica"), Some("Arial"));
        assert_eq!(macos_alias("helveticaneue"), Some("Arial"));
        assert_eq!(macos_alias("sfprotext"), Some("Segoe UI"));
        assert_eq!(macos_alias("applesystemuifont"), Some("Segoe UI"));
        assert_eq!(macos_alias("menlo"), Some("Consolas"));
        assert_eq!(macos_alias("lucidagrande"), Some("Lucida Sans Unicode"));
        assert_eq!(macos_alias("pingfangsc"), Some("Microsoft YaHei"));
        assert_eq!(macos_alias("zapfinonotreal"), None);
    }

    #[test]
    fn weight_lives_in_the_family_when_the_subfamily_is_regular() {
        let semibold = face("seguisb.ttf", "Segoe UI Semibold", "Regular", "SegoeUI-Semibold");
        assert!(semibold.bold && !semibold.italic);
        let plain = face("segoeui.ttf", "Segoe UI", "Regular", "SegoeUI");
        assert!(plain.is_regular());
        let bold_italic = face("arialbi.ttf", "Arial", "Bold Italic", "Arial-BoldItalicMT");
        assert!(bold_italic.bold && bold_italic.italic);
    }

    #[test]
    fn a_library_without_fonts_reports_nothing() {
        let mut library = FontLibrary::from_faces(Vec::new(), Vec::new());
        assert!(library.is_empty());
        assert!(library.font_for("Helvetica").is_none());
        assert!(library.default_font().is_none());
        assert!(library.default_name().is_none());
        assert_eq!(library.resolved_name("Arial"), None);
    }

    #[test]
    fn unresolved_requests_are_recorded_once() {
        // The faces exist but their files do not, so nothing can be loaded: the library reports an
        // empty result rather than pretending, and a readable default is what a caller needs.
        let mut library = FontLibrary::from_faces(Vec::new(), arial_like());
        assert_eq!(library.len(), 3);
        assert_eq!(library.resolved_name("Helvetica-Bold").as_deref(), Some("Arial Bold"));
        assert_eq!(library.resolved_name("Helvetica").as_deref(), Some("Arial"));
        assert!(library.font_for("Arial").is_none());
        assert!(library.fallbacks().is_empty());
    }

    /// The system library, or `None` when this machine has no fonts to test against.
    fn system_library() -> Option<FontLibrary> {
        let library = FontLibrary::new();
        (!library.is_empty()).then_some(library)
    }

    #[test]
    fn the_system_index_finds_common_families() {
        let Some(mut library) = system_library() else { return };
        assert!(library.len() > 10, "expected an installed font set, found {}", library.len());
        let name = library.resolved_name("Arial");
        assert!(name.is_some(), "Arial should be installed on Windows");
        assert!(library.font_for("Arial").is_some());
        assert!(library.font_for("Arial").unwrap().units_per_em() > 0.0);
    }

    #[test]
    fn macos_faces_are_answered_or_recorded_as_fallbacks() {
        let Some(mut library) = system_library() else { return };
        for requested in ["Helvetica", "Helvetica-Bold", "SFProText", "NoSuchFaceAtAll"] {
            let font = library.font_for(requested);
            assert!(font.is_some(), "{requested} should fall back to the system default");
        }
        let unknown = library.fallbacks().iter().any(|fallback| fallback.requested == "NoSuchFaceAtAll");
        assert!(unknown, "a missing face must be recorded: {:?}", library.fallbacks());
        assert!(!library.fallbacks().iter().any(|fallback| fallback.used == "none"));
        let before = library.fallbacks().len();
        library.font_for("NoSuchFaceAtAll");
        assert_eq!(library.fallbacks().len(), before, "the same miss is recorded once");
        library.clear_fallbacks();
        assert!(library.fallbacks().is_empty());
    }

    #[test]
    fn a_character_the_face_lacks_finds_a_linked_face() {
        let Some(mut library) = system_library() else { return };
        let arial = library.font_for("Arial").unwrap();
        // Either Arial covers it or a CJK face is linked in; both are answers, `None` is only
        // correct on a machine with no CJK font at all.
        let drawn = library.glyph_font(Some(&arial), 'A').unwrap();
        assert!(drawn.has_glyph('A'));
        if let Some(cjk) = library.glyph_font(Some(&arial), '你') {
            assert!(cjk.has_glyph('你'));
        }
    }

    #[test]
    fn every_platform_offers_at_least_one_font_directory() {
        assert!(!default_font_dirs().is_empty());
    }

// ---- per-script fallback chains -------------------------------------

    #[test]
    fn a_character_belongs_to_the_class_of_its_script() {
        assert_eq!(ScriptClass::of('\u{4E00}'), ScriptClass::Han);
        assert_eq!(ScriptClass::of('\u{3042}'), ScriptClass::Japanese);
        assert_eq!(ScriptClass::of('\u{D55C}'), ScriptClass::Korean);
        assert_eq!(ScriptClass::of('\u{0644}'), ScriptClass::Arabic);
        assert_eq!(ScriptClass::of('\u{05D0}'), ScriptClass::Hebrew);
        assert_eq!(ScriptClass::of('\u{0915}'), ScriptClass::Indic);
        assert_eq!(ScriptClass::of('\u{0E01}'), ScriptClass::Thai);
        assert_eq!(ScriptClass::of('\u{1F600}'), ScriptClass::Emoji);
        assert_eq!(ScriptClass::of('\u{2192}'), ScriptClass::Symbols);
        assert_eq!(ScriptClass::of('a'), ScriptClass::Other);
        assert_eq!(ScriptClass::of('7'), ScriptClass::Other, "digits are in every face already");
        assert_eq!(ScriptClass::of(' '), ScriptClass::Other);
    }

    #[test]
    fn every_chain_names_the_face_that_covers_it_first() {
        assert_eq!(ScriptClass::Han.faces()[0], "Microsoft YaHei");
        assert_eq!(ScriptClass::Japanese.faces()[0], "Yu Gothic");
        assert_eq!(ScriptClass::Korean.faces()[0], "Malgun Gothic");
        assert_eq!(ScriptClass::Arabic.faces()[0], "Segoe UI");
        assert_eq!(ScriptClass::Hebrew.faces()[0], "Segoe UI");
        assert_eq!(ScriptClass::Indic.faces()[0], "Nirmala UI");
        assert_eq!(ScriptClass::Thai.faces()[0], "Leelawadee UI");
        assert_eq!(ScriptClass::Emoji.faces()[0], "Segoe UI Emoji");
        assert_eq!(ScriptClass::Symbols.faces()[0], "Segoe UI Symbol");
        assert_eq!(ScriptClass::Other.faces()[0], "Microsoft YaHei");
    }

    #[test]
    fn a_chain_is_ordered_and_has_no_repeats() {
        for class in [
            ScriptClass::Han,
            ScriptClass::Japanese,
            ScriptClass::Korean,
            ScriptClass::Arabic,
            ScriptClass::Hebrew,
            ScriptClass::Indic,
            ScriptClass::Thai,
            ScriptClass::Emoji,
            ScriptClass::Symbols,
            ScriptClass::Other,
        ] {
            let faces = class.faces();
            assert!(!faces.is_empty(), "{class:?} has no chain");
            let mut seen: Vec<&str> = Vec::new();
            for name in faces {
                assert!(!seen.contains(name), "{class:?} lists {name} twice");
                seen.push(name);
            }
        }
    }

    #[test]
    fn a_chain_skips_faces_this_machine_does_not_have() {
        // A library built from one face answers with that face alone, whatever the chain asks for.
        let yahei = face("msyh.ttc", "Microsoft YaHei", "Regular", "MicrosoftYaHei");
        let mut library = FontLibrary::from_faces(Vec::new(), vec![yahei]);
        let chain = library.script_chain(ScriptClass::Han);
        assert_eq!(chain.len(), 1, "only the installed Han face answers");
        assert_eq!(chain[0].full_name, "Microsoft YaHei");
        assert!(library.script_chain(ScriptClass::Thai).is_empty(), "no Thai face here");
        assert!(library.script_chain(ScriptClass::Emoji).is_empty());
    }

    #[test]
    fn a_chain_is_worked_out_once_per_class() {
        let Some(mut library) = system_library() else { return };
        let first: Vec<PathBuf> =
            library.script_chain(ScriptClass::Indic).into_iter().map(|face| face.path).collect();
        let second: Vec<PathBuf> =
            library.script_chain(ScriptClass::Indic).into_iter().map(|face| face.path).collect();
        assert_eq!(first, second, "the second ask answers from the cache");
        assert!(!first.is_empty(), "Nirmala UI is installed on this machine");
    }

    #[test]
    fn a_face_that_has_the_glyph_is_kept() {
        let Some(mut library) = system_library() else { return };
        let Some(yahei) = library.font_for("Microsoft YaHei") else { return };
        assert!(yahei.has_glyph('\u{4E00}'));
        let chosen = library.glyph_font(Some(&yahei), '\u{4E00}').expect("the face at hand answers");
        assert!(Arc::ptr_eq(&chosen, &yahei), "a face that has the glyph is never replaced");
    }

    #[test]
    fn a_han_character_lands_on_a_han_face() {
        let Some(mut library) = system_library() else { return };
        let Some(latin) = library.font_for("Arial") else { return };
        if latin.has_glyph('\u{4E00}') {
            return;
        }
        let chosen = library.glyph_font(Some(&latin), '\u{4E00}').expect("a Han face has to stand in");
        assert!(chosen.has_glyph('\u{4E00}'));
        assert!(!Arc::ptr_eq(&chosen, &latin));
        let expected = library.script_chain(ScriptClass::Han).first().map(|face| face.full_name.clone());
        let actual = library.index_of(&chosen).and_then(|index| library.face(index)).map(|face| face.full_name.clone());
        assert_eq!(actual, expected, "the first installed Han face answers");
    }

    #[test]
    fn an_arabic_character_lands_on_an_arabic_face() {
        let Some(mut library) = system_library() else { return };
        let Some(symbol) = library.font_for("Marlett") else { return };
        if symbol.has_glyph('\u{0644}') {
            return;
        }
        let chosen = library.linked_font(Some(&symbol), '\u{0644}').expect("an Arabic face has to stand in");
        assert!(chosen.has_glyph('\u{0644}'));
        let expected = library.script_chain(ScriptClass::Arabic).first().map(|face| face.full_name.clone());
        let actual = library.index_of(&chosen).and_then(|index| library.face(index)).map(|face| face.full_name.clone());
        assert_eq!(actual, expected);
    }

    #[test]
    fn a_thai_character_lands_on_a_thai_face() {
        let Some(mut library) = system_library() else { return };
        let Some(latin) = library.font_for("Arial") else { return };
        if latin.has_glyph('\u{0E01}') {
            return;
        }
        let chosen = library.glyph_font(Some(&latin), '\u{0E01}').expect("a Thai face has to stand in");
        assert!(chosen.has_glyph('\u{0E01}'));
        let expected = library.script_chain(ScriptClass::Thai).first().map(|face| face.full_name.clone());
        assert_eq!(expected.as_deref(), Some("Leelawadee UI"), "Leelawadee UI is installed here");
    }

    #[test]
    fn a_pictograph_lands_on_the_emoji_face() {
        let Some(mut library) = system_library() else { return };
        let Some(latin) = library.font_for("Arial") else { return };
        if latin.has_glyph('\u{1F600}') {
            return;
        }
        let chosen = library.glyph_font(Some(&latin), '\u{1F600}').expect("an emoji face has to stand in");
        assert!(chosen.has_glyph('\u{1F600}'));
        assert_eq!(
            library.index_of(&chosen).and_then(|index| library.face(index)).map(|face| face.full_name.clone()),
            library.script_chain(ScriptClass::Emoji).first().map(|face| face.full_name.clone())
        );
        // The emoji face's picture is a monochrome outline as far as a coverage rasterizer is
        // concerned, and it has to have one or the character would draw nothing at all.
        let (_, coverage) = chosen.rasterize('\u{1F600}', 48.0);
        assert!(coverage.iter().any(|sample| *sample > 0), "the emoji face draws the picture");
    }

    #[test]
    fn a_chain_that_runs_out_leaves_the_box() {
        let Some(mut library) = system_library() else { return };
        let Some(latin) = library.font_for("Arial") else { return };
        assert!(
            library.linked_font(Some(&latin), '\u{10FFFD}').is_none(),
            "no installed face has this character, so none is offered"
        );
    }

    #[test]
    fn the_general_chain_answers_for_a_class_with_no_face_of_its_own() {
        // One face, which is in the general chain and in no script chain of its own.
        let fallback = face("arialuni.ttf", "Arial Unicode MS", "Regular", "ArialUnicodeMS");
        let mut library = FontLibrary::from_faces(Vec::new(), vec![fallback]);
        // The chain for the character's own class is empty here, so the general chain is what is
        // asked, and this face is in it.
        assert!(library.script_chain(ScriptClass::Thai).is_empty());
        assert_eq!(library.script_chain(ScriptClass::Other).len(), 1);
    }

    #[test]
    fn whole_word_reading_ignores_letters_inside_a_word() {
        assert_eq!(word_hints("Blackadder ITC"), StyleHints::default());
        assert_eq!(word_hints("Segoe UI Semibold"), StyleHints { bold: true, italic: false });
        assert_eq!(word_hints("Bold Italic"), StyleHints { bold: true, italic: true });
        assert_eq!(word_hints("Regular"), StyleHints::default());
    }

    #[test]
    fn face_bytes_are_read_once_and_shared() {
        let Some(mut library) = system_library() else { return };
        let first = library.face_bytes(0).expect("the first face has a file");
        let second = library.face_bytes(0).expect("and it is cached");
        assert!(Arc::ptr_eq(&first, &second));
        assert!(first.len() > 1_000, "a font file is more than a header");
        assert!(library.face(0).is_some());
    }

    #[test]
    fn a_loaded_font_reports_the_face_it_came_from() {
        let Some(mut library) = system_library() else { return };
        let font = library.font_for("Arial").unwrap();
        let index = library.index_of(&font).expect("a loaded font knows the face it came from");
        assert!(!library.face(index).unwrap().full_name.is_empty());
    }

    #[test]
    fn a_linked_face_is_offered_for_a_character_the_primary_lacks() {
        let Some(mut library) = system_library() else { return };
        let Some(primary) = library.font_for("Marlett") else { return };
        if primary.has_glyph('\u{4E00}') {
            return;
        }
        let linked = library.linked_font(Some(&primary), '\u{4E00}');
        assert!(linked.is_some(), "a face with the character has to stand in");
        let linked = linked.unwrap();
        assert!(linked.has_glyph('\u{4E00}'));
        assert!(!Arc::ptr_eq(&primary, &linked), "and it is not the face that just failed");
    }
}

