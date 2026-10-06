# comp-text notes

Text layout, shaping, rasterization and shape drawing: the step that turns the metadata a `.comp` file
keeps into the pixels the macOS app stores when an edit is committed.

## Files

| File | Holds |
|---|---|
| `src/names.rs` | Minimal SFNT `name`-table reader (family, subfamily, full, PostScript, typographic names) and name normalization |
| `src/library.rs` | `FontLibrary`: scanning, indexing, macOS aliases, face caching, raw face bytes, fallback bookkeeping, linked faces |
| `src/layout.rs` | UTF-16 run resolution, script itemization, bidirectional levels, shaping, line breaking, alignment, baselines, glyph placement |
| `src/geometry.rs` | `hit_test`, `caret_rect` and `selection_rects` over a laid-out paragraph |
| `src/raster.rs` | `rasterize_text`, `text_bounds`, `rasterize_layout`, subpixel glyph drawing |
| `src/shape.rs` | `rasterize_shape` for rectangles, rounded rectangles, ellipses and lines |
| `src/paint.rs` | Channel conversion and source-over compositing of anti-aliased samples |
| `src/commit.rs` | `commit_text_layer`, `commit_shape_layer` and `CommitError` |

Dependencies beyond `comp-core` and `fontdue`: `rustybuzz` (HarfBuzz in Rust, already in the workspace's
dependency tree through resvg) and `unicode-script` (the script lookup rustybuzz uses internally but does
not expose). Both are pure Rust, so nothing here needs a C toolchain.

## Shaping

`layout_text` shapes; `layout_text_with(style, library, LayoutOptions::UNSHAPED)` lays text out one glyph
per character, which is what this crate did before, and is what the tests compare against.

The pipeline, in order:

1. **Characters.** `char_spans` splits the content into characters with their UTF-16 offsets, and each
   character takes its face and color from the run that covers its *first* UTF-16 unit.
2. **Face per character.** The style's face, the character's `fontRun` face, or a linked face when the
   chosen one has no glyph for the character (`FontLibrary::glyph_font`). Default-ignorable characters —
   joiners, variation selectors, direction marks — never trigger this: they have no glyph by design, and
   sending them elsewhere would draw a stray box inside a word.
3. **Runs.** Characters are grouped into runs that share a face and a script; a named script that differs
   from the run's starts a new run, while Common and Inherited characters stay where they are. The script
   comes from `unicode-script`, the direction is left to the shaper (`guess_segment_properties`).
4. **Shape.** Each run becomes one `UnicodeBuffer` pushed as a string, with the script set and the default
   feature set (an empty feature list means the font's own kern, liga, calt, ccmp, mark, mkmk, rlig, ...).
   Positions come back in font units and are scaled by fontSize / unitsPerEm.
5. **Clusters back to characters.** Every glyph carries the byte offset of the cluster it belongs to, which
   maps straight back to a character. Glyphs therefore carry their own face, so one word can draw from two
   faces when a character had to be linked in.
6. **Advances.** A character's advance is the sum of its glyphs' advances; a character a ligature or a mark
   swallowed keeps none of its own, which is what makes a line measure exactly as wide as the glyphs it
   draws. A run that produced no glyphs at all falls back to the face's own advance for each character, so
   text never collapses when a face cannot be parsed.
7. **Lines and placement.** Breaking, alignment and baselines are unchanged; they now measure shaped
   advances. A left-to-right run is placed forwards from its first character's pen. A right-to-left run
   arrives from the shaper in *visual* order — its first glyph is the leftmost — so it is placed forwards
   from the left edge of its span while the characters' own pens run the other way.

### Bidirectional text

~~LayoutOptions::direction~~ chooses how paragraphs run: ~~Auto~~ (the default) resolves each paragraph
from its own first strong character, and ~~LeftToRight~~ or ~~RightToLeft~~ force one. Every paragraph is
resolved on its own with `unicode-bidi`, so a right-to-left paragraph does not drag its neighbours with
it, and the resolved direction is kept on the layout (~~TextLayout::direction~~) and on every line
(~~LayoutLine::rtl~~).

Each character then carries its UAX #9 embedding level (~~CharCell::level~~). That level does three
things:

* **It ends a shaped run.** The shaper takes one direction per buffer, so a run boundary is a direction
  change as well as a face or script change, and the direction it is shaped with is the level's, not the
  script's. A number inside a right-to-left paragraph therefore keeps level two and stays left to right.
* **It orders the line.** The characters of a line are drawn in the order UAX #9 rule L2 gives: runs at
  the highest level are reversed first, then each level down, until the lowest odd level has been
  reversed. That turns an Arabic or Hebrew paragraph around, and leaves an embedded Latin word or a
  number the right way round inside it.
* **It decides what is drawn where.** ~~LayoutLine::display~~ holds the characters in drawn order with the
  pen position each starts at, which is what the geometry API reads.

Neutral characters (spaces, punctuation) take the direction of the text around them, and follow the
paragraph's when the two sides disagree, which is what the tests pin down.

**Mirrored characters** follow UAX #9 rule L4: a bracket or a comparison sign in a right-to-left run is
drawn as its partner, one in a left-to-right run is drawn as stored, and a symbol with no partner is never
touched. The pairs come from Unicode's `BidiMirroring.txt`, read through the `unicode-bidi-mirroring`
table, and `mirrored_char(ch, level)` is the helper that applies them.

One thing is worth writing down, because it is easy to get wrong twice: **the shaper applies the same rule
itself**. A shaped run is not pre-mirrored, because the shaper mirrors a right-to-left buffer on its own —
and does it better, since a font can carry a mirrored glyph of its own (the `rtlm` feature) before the
table is consulted — so substituting the character first only gets mirrored back, leaving the bracket as it
started. A test here pins that down: pre-mirroring a shaped run turns "()" into "()" again and the test
fails on the glyph ids. The unshaped layout has no shaper, so it mirrors through `mirrored_char` itself.

Alignment stays **absolute**, as the macOS app's paragraph style does: ~~TextAlignment::Left~~ puts a line
at the left of its box whatever the paragraph's direction, and a caller that wants the line to hug the
right in a right-to-left paragraph either asks for ~~Right~~ or reads ~~LayoutLine::rtl~~ and places the
layer itself.

### Per-glyph fallback

Windows links fonts per character, so a character the face at hand cannot draw is looked for in another
face. Which faces to ask depends on what the character is, and `ScriptClass` names those groups:

| Class | Faces, best first |
|---|---|
| Han | Microsoft YaHei, SimSun, SimHei, Microsoft JhengHei, MingLiU, MS Gothic, Malgun Gothic |
| Japanese | Yu Gothic, MS Gothic, Meiryo, Microsoft YaHei |
| Korean | Malgun Gothic, Batang, Gulim, Microsoft YaHei |
| Arabic | Segoe UI, Tahoma, Arial, Traditional Arabic, Microsoft Sans Serif |
| Hebrew | Segoe UI, Arial, Tahoma, David, Nirmala UI |
| Indic | Nirmala UI, Mangal, Aparajita, Utsaah, Kokila, Microsoft YaHei |
| Thai | Leelawadee UI, Leelawadee, Tahoma, Cordia New, Microsoft Sans Serif |
| Emoji | Segoe UI Emoji, Segoe UI Symbol, Segoe UI, Arial |
| Symbols | Segoe UI Symbol, Segoe UI, Arial, Cambria Math |
| Other | the general chain: Microsoft YaHei, SimSun, Malgun Gothic, Yu Gothic, Microsoft JhengHei, Segoe UI Symbol, Segoe UI Emoji, Arial Unicode MS, Segoe UI, Arial |

`ScriptClass::of(ch)` reads the character's Unicode script (and, for pictographs and symbol blocks, its
code point range), and `ScriptClass::faces()` is the list. `FontLibrary::script_chain(class)` returns the
faces of a chain this machine actually has, and it is worked out once per class and kept.
`FontLibrary::script_font(primary, ch)` — the shape `glyph_font` and `linked_font` use — asks the
chain in order and takes the first face that really has the glyph, skipping the face that just failed. A
face that has the glyph is never replaced, the chains never rewrite a name (they go through the same alias
and style resolution as any request), and when a script's own chain runs out the general chain is asked
before the answer is none, which leaves the missing-glyph box.

A face can also claim a character and still shape it to the box: Marlett lists Latin letters in the
character map `fontdue` reads and finds nothing for them in the tables the shaper uses. After a run is
shaped, any glyph left as `.notdef` whose character is drawable is shaped again on its own in a face from
the chain. If nothing has it the box stays, which is the honest answer for a character no installed face
can draw.

### Subpixel placement

fontdue rasterizes a glyph at three times the horizontal resolution, so each pixel of the result holds its
left, middle and right third as three samples. A pen position is therefore kept to a third of a pixel: the
fractional part is rounded to a phase, and the shifted pixel is the mean of the three thirds starting at
that phase, taking the samples past its right edge from the next pixel. Phase zero is the plain coverage of
the pixel, so integer positions are unaffected, and kerned or tracked advances no longer snap to whole
pixels. Vertical positions stay whole-pixel; only `y_offset` moves a glyph off the baseline.

## Font resolution

Scan order: %SystemRoot%\Fonts, %LOCALAPPDATA%\Microsoft\Windows\Fonts, $HOME/Library/Fonts,
/usr/share/fonts, /usr/local/share/fonts, /System/Library/Fonts. `COMPOSITOR_FONT_DIRS` replaces the list
entirely (a PATH-style list), which is what a build agent without system fonts should set. The default scan
is cached for the process; the scan reads the first 128 KB of each file and only reads a file whole when
its `name` table sits past that. On this machine the scan finds 391 faces in about 0.15 s.

A face answers to every one of its names, normalized (letters and digits only, case-folded): family
(ID 1), full name (ID 4), PostScript name (ID 6), family + subfamily, typographic family + typographic
subfamily (IDs 16/17), and the file stem. Two rules matter:

* Regular faces are indexed before other weights, so a bare family name means the regular cut.
* A typographic family only answers for a face that has no style of its own. "Arial Narrow" is typographic
  family "Arial" with subfamily "Narrow"; without this rule every "Helvetica" request landed on Arial
  Narrow, because ARIALN.TTF sorts before arial.ttf.

### macOS aliases

A request is resolved by exact name, then by the alias table below, then by taking the alias family in the
weight and slant the request asked for (Bold/Oblique/Italic/Semibold/Black/Heavy). So `Helvetica-Bold`
reaches Arial Bold without a per-weight entry.

| macOS | Windows |
|---|---|
| Helvetica, HelveticaNeue, ArialMT, Arial | Arial |
| SFPro, SFProText, SFProDisplay, SFCompactText, SFCompactDisplay, SFNS*, SanFrancisco, .AppleSystemUIFont, SystemFont | Segoe UI |
| Avenir, AvenirNext | Segoe UI |
| Times, Times-Roman, TimesNewRomanPS | Times New Roman |
| Courier, CourierNewPS | Courier New |
| LucidaGrande | Lucida Sans Unicode |
| Geneva | Tahoma |
| Monaco, Menlo, SFMono | Consolas |
| Chalkboard, ChalkboardSE, Chalkduster | Comic Sans MS |
| Didot, Bodoni, Bodoni72 | Bodoni MT |
| Baskerville | Baskerville Old Face |
| GillSans | Gill Sans MT |
| Copperplate | Copperplate Gothic Bold |
| Optima | Candara |
| Futura | Century Gothic |
| Zapfino | Segoe Script |
| Noteworthy, MarkerFelt | Segoe Print |
| Rockwell | Rockwell |
| Hiragino*, PingFang*, Heiti, YaHei | Microsoft YaHei |
| STSong, Songti, SimSun | SimSun |
| Kaiti | KaiTi |
| Osaka | MS Gothic |

### Falling back

* **A face that is missing or unreadable** becomes the system default, chosen in this order: Segoe UI,
  Arial, Tahoma, Calibri, Verdana, Liberation Sans, DejaVu Sans, Noto Sans, then the first face found.
  Every such request is appended to `FontLibrary::fallbacks()` (once per name) as requested -> used, so a
  caller can tell the user which text was re-drawn in another face. Nothing is recorded when a request is
  answered exactly.
* **A face that lacks a character** falls back per character through `glyph_font`, which walks Microsoft
  YaHei, SimSun, Malgun Gothic, Yu Gothic, Microsoft JhengHei, Segoe UI Symbol, Segoe UI Emoji and Arial
  Unicode MS. This is the short version of Windows font linking: enough for a second script to draw instead
  of turning into blank boxes. A glyph the shaper still cannot produce is retried through `linked_font`
  (see *Per-glyph fallback* above).
* **No fonts at all** (an empty font set) is not an error: layout still measures every character at half the
  font size and draws nothing.

## Grapheme clusters, and which set of functions to use

A caret may not sit inside a character, and it may not sit inside a **grapheme cluster** either. Measured
on this machine rather than assumed: a family emoji is four emoji and three joiners, eleven UTF-16 units
and *one* cluster; a thumbs up with a skin tone is four units and one cluster; a flag is two regional
indicators; a heart with a variation selector is two units; `e` with a combining acute is two; a
Devanagari `क्क` is three code points that draw as one letter; a Thai syllable and its tone mark
are two; and a carriage return with its line feed is one cluster, so one backspace removes both. Moving or
deleting by code point cuts all of those in half, which is what the GUI saw.

`graphemes`, `grapheme_boundaries`, `snap_to_grapheme`,
`snap_range_to_graphemes`, `next_grapheme`, `prev_grapheme`,
`delete_grapheme_backward`, `delete_grapheme_forward`, `select_next_grapheme` and
`select_prev_grapheme` are the cluster-level set. They are additions: every function that was there
before keeps its signature and its behaviour, so the GUI can move one call site at a time.

**Which set a caller wants:**

* The arrow keys, shift and an arrow, backspace and delete, one step at a time: the **grapheme** set. This
  is what Core Text does, and it is what makes a family emoji move and disappear as one thing.
* The word-by-word moves and word deletions (Option or Control with an arrow, or with delete): the **word**
  set from the section above. Snap the caret with `snap_to_grapheme` first — a caret that came from
  a click can be anywhere — and the range that comes back is cluster-aligned, because a UAX #29 word
  boundary is always a grapheme boundary as well. A test holds that: every word segment of a text full of
  clusters starts and ends on a cluster boundary.
* A click, or anything coming from the layout: `hit_test` answers with a *layout* offset, and
  `char_of_utf16` turns it into the UTF-16 offset these functions speak.
* Before writing an edit back and shifting the runs: `snap_range_to_graphemes`, which moves a start
  inside a cluster back to its start and an end inside one on to its end, so no run offset can end up in
  the middle of a cluster.

`snap_to_boundary` is unchanged and stays what it always was — the code-point-level helper the word
functions use internally — so nothing that calls it changes meaning.

## First layout, window resizing, and where the time goes

`cargo test --release -p comp-text typing_in_a_long_document -- --nocapture` lays out a document of
10,689 characters in 200 paragraphs of mixed Chinese and Latin (400 lines in a 420-pixel box at 16 px,
Microsoft YaHei) and measures every path, with `stage_times()` splitting each one into shaping,
breaking and assembly:

| | time | shaping | breaking | assembly | what it shapes |
|---|---|---|---|---|---|
| first layout, faces not loaded | 197.3 ms | 6.3 | 0.2 | 190.4 | 203 runs |
| `prepare_style` | 184.6 ms | — | — | — | 1 face |
| **first layout, faces prepared** | **9.9 ms** | 6.2 | 0.2 | 3.1 | 203 runs |
| keystroke | 0.8 ms | 0.0 | 0.0 | 0.7 | 1 run |
| box 420 → 380 | 6.7 ms | 1.4 | 0.2 | 4.7 | **0 runs** |
| the same resize with no cache | 10.4 ms | 6.6 | 0.1 | 3.3 | 203 runs |
| the same keystroke with no cache | 11.0 ms | 7.1 | 0.1 | 3.4 | 203 runs |

**The first layout is not slow because of the layout.** Almost all of it is fontdue parsing the font
file, at about ten milliseconds per megabyte: measured directly on this machine, `std::fs::read`
takes 4.8 ms for Microsoft YaHei's 19.7 MB and `Font::from_bytes` takes 214.7 ms, while SimSun's
18.3 MB takes 203 ms and Arial's 1.0 MB takes 13.6 ms. Inside the layout, paragraph 0 pays 195 ms of that
and paragraphs 1 to 199 pay 0.02–0.05 ms each; a fine-grained probe of one 108-character paragraph shows
faces 0.015 ms, bidi 0.005, fallback advances 0.005, shaping 0.030, advancing 0.001, wrapping 0.003 and
placing 0.020.

So the fix is not a faster layout but an explicit place to pay the parse: `prepare` and
`prepare_style` load the faces a document names *and the fallbacks its characters will reach for*
(which is why a Latin face showing Chinese is prepared with two faces, not one). A GUI that is opening a
document can call it once, off the typing path, and its first layout is then 9.9 ms rather than 197 ms.

**Parallel shaping was measured and not worth it.** Shaping is 6.2 ms of a 9.9 ms prepared first layout
and 0.8 ms of a keystroke, and the work left after it — resolving faces, advancing, wrapping, placing and
splicing — is not shaped at all. Threads over paragraphs could save perhaps four of those ten
milliseconds, at the cost of a thread pool, a dependency and a second code path that has to be proved
identical to the first. The measurement does not support it, so there is no second path to get wrong.
(Fontdue's own substitution table, which nothing here consulted, is no longer built; for these faces it
measured the same, and the change is kept only because the work was never used.)

**A window resize re-wraps and re-places but shapes nothing**, and that is structural rather than
special-cased: the shaping cache is keyed by the run's text, face, script, direction, size and tracking,
and a box's width is not among them. The measurement shows it — 800 shaping-cache hits and **zero misses**
for the 203 runs the control shapes — and the counters are what the test asserts, because they do not
depend on how busy the machine is. Only the paragraphs are wrapped again (200 layout misses), and the
splice translates the rest.

## Editing: words, lines, selections

Navigation, selection and deletion live in `editing`, and are arithmetic on text and on a laid-out
paragraph: nothing there touches a window. Two units meet, and the split is deliberate. A *text* offset is
a UTF-16 unit — the unit every run offset in this crate uses — so a range that comes back from a deletion
can be handed straight to the code that fixes up color and font runs. A *layout* offset is an index into
the layout's character list, the unit `hit_test` and `caret_rect` use; `char_of_utf16` and
`utf16_of_char` move between them.

**Words are UAX #29's**, through `unicode-segmentation`, which is what makes a double click behave the
way the platform does. What that means in practice, measured on this machine rather than assumed:

* Every Chinese or Japanese ideograph is a word of its own (the standard gives them no word-forming
  property, so each stands alone), which is why word-by-word movement steps character by character through
  Chinese. Korean and Hebrew letters do form words, so `한글` and `אבג` move as units.
* Punctuation and runs of space are segments of their own and not words: `word_boundaries` returns them
  so a double click on a comma selects the comma, and `next_word_start` / `prev_word_start` step over
  them.
* Numbers stay whole — `3.14` is one word — and an apostrophe inside a word does not split it: `don't`
  is one word. An emoji is a segment of its own and never a word.

`next_word_start` is the boundary a word-by-word move lands on: the end of the word the caret is inside,
or the start of the next word when it is not in one, so `hello, world` steps 0 → 5 → 7 → 12 the way
Option+Right does on macOS. `prev_word_start` is where a delete-word-backward lands: the start of the
word before the caret, or of the word it is inside.

**Lines** come in two kinds and both are here. `line_bounds`, `line_start`, `line_end`,
`next_line` and `prev_line` work on the laid-out lines, soft wraps included — so End goes to the
end of the wrapped line and a down arrow keeps the caret's column, which is measured from the caret's own x
against the character spans the target line draws, in the order it draws them, so it answers the same way
in a right-to-left line. `paragraph_at` is the hard-break line instead: what a triple click selects.

Deletions — `delete_word_backward`, `delete_word_forward`, `delete_to_line_start`,
`delete_to_line_end` — return the UTF-16 range to remove, or none when there is nothing to remove, and
the caller writes it back and shifts the runs. Every entry point snaps an offset to a UTF-16 boundary first,
so no edit and no caret can ever land inside an emoji.

## Input method pre-edits

While a composition is open, the characters are not in the document yet but they are already on screen.
`Preedit` keeps what an input method reports — the composing text, where the caret is, and which clause
each part of it belongs to — and normalises it: clauses are sorted, clipped to the text, never overlap and
never run past its end, and the caret is pulled back inside. An input method is free to report a clause that
runs off the end of a text it is still assembling, and a GUI should not have to care.

The layout the geometry is asked about is the one the caller laid the *pre-edit* out with: the composing
text on its own, in the style the finished text will have. That is what makes the space the pre-edit takes
the space it keeps once it is committed, so nothing on the line jumps when the composition closes — a test
holds the two layouts to the same width. A `PreeditClause` carries a `PreeditStyle` of underline,
bold and highlight, which is what a GUI draws *over* the text; the flags never change the layout, which is
why the clause styles cannot make the line move.

* `preedit_clause_rects(layout, preedit)` gives one box per clause per line — a clause longer than a
  line, which is the usual case for a composition being wrapped, gets one box for each line it covers —
  in the layout's coordinates, and a clause of nothing but spaces gets none.
* `preedit_bounds(layout)` is the box around everything the pre-edit draws, or none when it draws
  nothing.
* `candidate_anchor(layout, caret_index)` is where a candidate window should point: the caret's own
  box, and a suggested direction — down from a caret with text below it, up from one on the last line. The
  suggestion is a hint, not a rule: where the list actually goes, and how far from the anchor it sits
  vertically, is the caller's business, because only the caller knows the window and the screen.

### Defects found by the random invariants, and how they were fixed

* **Kinsoku asked about the wrong character.** The wrapper asked whether the character *at* the break may
  begin a line, but that character is often the space the break then drops, so a line could still begin
  with the full stop after it. It now asks about the first character that is not a space the break skips,
  and about the last character the line really draws. Reproduction, now a test: `ab 。xy` in a box
  three characters wide — the full stop no longer starts a line.
* **A hard break could cut a grapheme cluster.** A run with no break opportunity in it is broken between
  characters as a last resort, and kinsoku moves a break back one character at a time; both could land
  between the characters of one cluster. The wrapper now reads the cluster starts once per paragraph (next
  to the break opportunities, so no line pays for a scan of its own) and moves every break to the nearest
  cluster boundary — backwards first, and forwards only when the line would otherwise be empty, which is
  the case of a cluster wider than the box: the whole cluster is taken. The forward search is bounded at
  64 characters, so a pathological cluster is broken between characters rather than dragging a line.
  Reproduction, now a test: `क्कक्क` in a box two characters wide.
* **A caret in a right-to-left line answered with another caret** (random seed 6901461881, shrunk to
  `"\nאבגthe quick brown "`, where the caret at 4 answered with 6 when the middle of its own box was
  clicked). Caret positions were read off the display list in pairs, but in a line the shaper reordered the
  caret *after* a character belongs to its logical successor, which is not the next cell in display order.
  `caret_at_point` now works each position out the way `caret_rect` does, and the test is strict
  again.

Two defects in the test harness itself, found while the above were being fixed by the lead: the wrapping
loop did not advance when a break was pulled back to the start of a line (a cluster boundary can do that),
so it could spin — a line now always takes at least one character; and the minimizer only checked its
deadline between passes, so a failing invariant could look like an eight-minute hang instead of a report —
it now checks the clock inside a pass too, and is bounded in both time and candidate documents.

### Colour emoji: what the version 1 paint graph costs (probe, 2026)

The version 0 route was walked to its end and disproved: the layer records of seguiemj are all there
(3372 base glyphs, 53071 layers) and the face id, the palette address and the layer list are all
correct — but the layer glyphs rasterize to **no ink at all**, while the monochrome base glyph draws.
This font keeps its paint in the version 1 graph, so the layers are not outlines to be filled.

What ttf-parser 0.25.1 offers for that graph, read from its source rather than guessed:

* `colr::Paint` has exactly four variants — `Solid(RgbaColor)`, `LinearGradient`,
  `RadialGradient`, `SweepGradient`. Layers, nesting, transforms and composite modes are *not*
  in that enum.
* They come through the `Painter` visitor: `Table::paint(glyph, painter)` walks the graph and
  calls back (clip boxes, layers, glyph outlines, the four paints), and `Table::is_simple()` says
  whether the whole table stays inside what the simple callbacks cover.
* `FaceTables` exposes no `cpal` field at all, so the palette stays hand-read, pinned by the
  table-length identity (14 + 64831 x 4 = 259338 bytes).

So a version 1 renderer is not "read a list and fill each glyph": it is an implementation of the painter
callbacks — outline a glyph, paint a solid or one of three gradients, push and pop clips and layers, and
honour composite modes — with the gradients and transforms the part that v0 never needed. The coverage
probe that would decide it (sample 200 base glyphs and count how many need only solids, outlines and
nesting) needs that visitor written first: about sixty lines of counting painter, and none of the drawing.
**Not done: this probe, and therefore the decision it was meant to support.** Until it is, colour emoji
stays a known gap with the monochrome outline as the fallback, and none of the four features the audit
listed as "needs a format upgrade" are touched.

#### The numbers, and the decision: not implemented

`tests/colour_v1_probe.rs` implements ttf-parser's `Painter` as a counter — it counts outlines,
solids, gradients, transforms, clips and layers, and how deep they nest — and walks the paint graph of
the first 200 painted base glyphs of seguiemj (867 glyph ids tried before 200 painted ones were found).
Measured on this machine:

| what a glyph's graph needs | glyphs |
|---|---|
| outlines, solids, clips and layers only | **1** |
| a gradient | 0 |
| a transform | 0 |
| **both a gradient and a transform** | **199** |
| totals | 6052 outlines, 462 solids, 5592 gradients, deepest nesting 5 |

So the share a renderer built on solids and outlines alone would cover is **0.5%**, against the 70% that
would have made it worth building: the emoji of this face are drawn with gradients inside transforms,
almost every one of them (`colr::Table::is_simple()` says the same about the table as a whole). A colour
emoji renderer here is not an extension of the version 0 work; it is a full version 1 paint graph
interpreter — gradient stops and extend modes, sweep and radial geometry, affine transforms, clip
boxes and composite modes — for one face, and the audit's own rule was that a gap is closed when it is
cheap or when it matters. It is neither: the monochrome outline that is drawn today is the whole of what
this face's version 0 records can give, and it is what a fallback is for.

**Decision: colour emoji stays a known gap.** The fallback is the outline path, which the guards in
`raster.rs` keep byte for byte identical to what was drawn before any of this work, and the version 0
reader in `colour.rs` stays because it is correct and cheap — it is simply not enough on its own for
this face. Nothing outside the crate changes, no format field is added, and the four capabilities the
audit listed as needing a format upgrade are untouched.

## Parity audit against the macOS text model

Read from the app's own source rather than from a feature list: `LayerTextStyle` in
`Compositor/Document/TypeTool.swift` is the whole of what a text layer *is*, and
`TypeTool.textAttributes` is the whole of what is handed to CoreText. That is the yardstick, and
it is a small one.

**What macOS actually has.** The style's fields are: `content`, `fontName`,
`fontSize`, `red`/`green`/`blue`, `alignment` (left, center, right),
`tracking`, `leading` (0 means Auto, 120% of the size), `boxSize` (nil for point text),
`colorRuns` and `fontRuns` in UTF-16 offsets. `padding` is a constant, not a field. The
attributes it builds are: `.font`, `.foregroundColor`, `.kern` (tracking), and a
`NSMutableParagraphStyle` with `alignment`, `minimumLineHeight` =
`maximumLineHeight` = the leading, and `lineBreakMode = .byWordWrapping`. Drawing goes through
`NSTextStorage` + `NSLayoutManager`, which is TextKit doing the layout, and fonts come from
`NSFont`/CoreText's own cascade.

| capability | macOS | comp-text |
|---|---|---|
| **Match** | | |
| content, one face, one size, one color | fields | `TextStyle` |
| per-run face and color, UTF-16 offsets | `fontRuns`, `colorRuns` | same |
| alignment left/center/right | `NSParagraphStyle.alignment` | same |
| tracking | `.kern` | same, applied between characters |
| leading, 0 = Auto at 120% | min/max line height | same |
| fixed box or point text, padding 12 | `boxSize`, `padding` | same |
| word wrapping | `.byWordWrapping` | UAX #14 greedy fill, plus kinsoku |
| point-text measurement | `boundingRect` + padding + 0.1 em | same formula |
| per-letter fallback | CoreText cascade | script chains, then glyph existence |
| bidi and combining marks | CoreText | UAX #9 levels, rustybuzz shaping |
| tabs | TextKit's default tab stops | two spaces' worth of advance |
| **Ours only** | | |
| break opportunities, kinsoku, cluster-safe breaks | — | `wrap_paragraph`, `cannot_*` |
| caret and selection geometry, hit testing | TextKit's, not exposed | `caret_rect`, `caret_at_point`, `hit_test`, `selection_rects` |
| word, line and grapheme-cluster editing ranges | NSTextView's | `editing` |
| IME pre-edit clauses and candidate anchor | AppKit's | `preedit` |
| shaping and layout caches, preparation, stage timings | — | `shape_stats`, `layout_stats`, `prepare*`, `stage_times` |
| **macOS has, we lack** | | |
| color emoji and color fonts | CoreText draws them | drawn as monochrome outlines |
| the system's exact font cascade | CoreText's tables | our own chains, so a face can differ |
| text rendering quality (gamma, stem darkening, hinting) | system rasterizer | fontdue outlines, subpixel positions |
| **Depends on system services (not portable, not a gap to close)** | | |
| layout and drawing | TextKit + CoreText | our own, which is the point of the port |
| font matching and optical sizing | NSFont/CoreText | the library's own resolution |
| editing services (undo, spell check, dictation) | NSTextView | the GUI's business |

**The four candidates a parity pass might reach for are not in the macOS model**: there is no paragraph
spacing, no baseline offset, no truncation mode and no tab-stop list in `LayerTextStyle`, and
`textAttributes` sets none of them. So they are not gaps in this port; they are features *beyond*
macOS. Adding them to `TextStyle` would mean a project-format change (documented in
`docs/project-format.md`, with a version bump in `ProjectManifest.current`) and a decision by
whoever owns the format — not something to slip into the layout crate:

* **Paragraph spacing** would need a field and a format bump.
* **Baseline offset** would need a field and a format bump (per run, at that).
* **Truncating ellipsis** could be a *render-time* option: it would need a field to be saved, but a caller
  can already ask for it without one, because it is a drawing decision — the layout stays as it is and the
  last line is clipped and marked. Not implemented here.
* **Tab stops** would need a field (a list of positions) and a format bump; the current fixed advance is
  what TextKit's defaults amount to for the only text this app produces.

## Caches and incremental layout

Typing changes one paragraph, and nothing else should be shaped or wrapped again. Two caches live in
`FontLibrary`, so they persist for as long as the editor's library does.

**The shaping cache** holds what a run shaped to, keyed by the face, the script, the direction, the font
size, the tracking and the text of the run — everything that can change a glyph. It is *not* keyed by where
the run sits in the document, so the same words in another paragraph answer from the same entry. Tracking
changes nothing about a glyph, and is in the key only so that a caller keying a whole text style stays
consistent; the features are the shaper's defaults, which is what a run is always shaped with here.

**The layout cache** holds a laid-out paragraph, keyed by its text, its runs clipped to it, the face and
size, tracking, leading, color, the width it wraps inside, and the shaping and direction options. What it
deliberately leaves out is everything that can be applied after the fact: alignment, the box's height, and
which line the paragraph starts on. That is why changing the alignment re-lays out nothing at all, and why
editing one paragraph leaves the rest to be *translated* — their lines keep their widths and only their
baselines move — rather than laid out again.

Both caches are bounded (4096 shaped runs and 1024 paragraphs by default, `set_shape_cache_capacity`
and `set_layout_cache_capacity` to change that) and evict the least recently used eighth in one batch
when they fill, so a long document cannot grow them without limit and a miss does not cost a scan per
entry. `shape_stats()` and `layout_stats()` report hits, misses, entries, capacity, eviction
rounds and a hit rate for a GUI's diagnostics or a benchmark.

### The numbers

A document of 10,000 characters in 200 paragraphs of mixed Chinese and Latin, in a 420-pixel box at 16 px,
laid out with Microsoft YaHei, then one character typed into the middle paragraph. Measured on this machine,
release build, with `cargo test --release -p comp-text typing_in_a_long_document -- --nocapture`:

| | first layout | one keystroke | no cache at all |
|---|---|---|---|
| time | 221.4 ms | **1.4 ms** | 205.5 ms |
| shaped runs | 206 | 3 misses, 6 hits | 206 |
| laid-out paragraphs | 200 | 1 miss, 199 hits | 200 |

In a debug build the same document takes 1667 ms cold and 4.8 ms per keystroke, so the ratio — about 150×
in release, 350× in debug — is what the caches are worth; the absolute numbers depend on the build and the
machine. The shape cache answers 85% of the 1409 lookups it sees over the two passes, and the layout cache
99.5% of the lookups on the editing path (its overall rate is near 50% because the first pass is all misses
by definition).

The keystroke's layout is compared against one built from nothing, field by field — every character, line,
glyph position and offset — and the two have to be identical: that is the hard invariant the tests hold the
caches to, and it is what makes a cache worth having rather than a source of quiet wrongness.

## Line breaking

Where a line may end is Unicode's business, not the spaces': `wrap_paragraph` asks
`unicode-linebreak` for the opportunities UAX #14 gives, once per paragraph, and then fills each line
greedily — it takes the last opportunity before the character that would overflow the box. That is what Core
Text does and what a browser does, and it is why the rules matter:

* Chinese and Japanese break between characters, with no space anywhere in sight.
* A number keeps its digits and its decimal point together, so `3.14` never splits, and a unit after a
  space is a word like any other: it moves down whole rather than being cut in half.
* Closing punctuation is never left at the start of a line and an opening bracket never at the end (UAX #14
  rules LB13 and LB14 already refuse those breaks).
* A URL breaks after a slash and keeps its host together, because nothing may break before a full stop.

A stretch with no opportunity in it — a long Latin word, a URL with nowhere to break — is broken between
characters as a last resort, exactly as the macOS layout manager does.

**Kinsoku** is what answers that last resort. UAX #14 has already refused a break before `。` or after
`「`, but a line broken by hand can land anywhere, so `cannot_start_a_line` and
`cannot_end_a_line` name the characters that may not begin or end a line — the East Asian closing
brackets, full stops, commas, small kana and iteration marks on one side, the opening brackets and hanging
quote marks on the other — and `prohibited_break` ends the line earlier until neither applies. Ending
earlier rather than squeezing the punctuation in is what keeps every line inside its box; a line can
therefore come out one character short of the box, which is the trade Japanese typesetting calls 追い出し.

## Layout decisions

* Padding between the text and its box is 12 px, the same constant the macOS app uses.
* A **fixed box** is exactly `boxSize` (rounded up), its text area is the box minus the padding on each
  side, and lines break to that width. **Point text** (no `boxSize`) is as wide as its longest line plus
  the padding plus a caret's worth of width (10% of the font size), and is at least 16 px a side; it never
  wraps except at explicit breaks.
* Baseline of line *i* is padding + lineHeight * (i + 1) - descent, which is what the macOS app computes
  for the caret, and puts the descent's worth of the line below the letters.
* Auto leading is 120% of the font size; a custom leading is the whole line height, so lines close up and
  eventually overlap, as Photoshop's and the macOS app's do.
* Tracking is added between characters, after shaping, so it never breaks a ligature up; a measured line is
  sum(advances) + tracking * (count - 1), and placement adds it between characters the same way.
* Wrapping follows UAX #14 (see *Line breaking* above): the whitespace that ends up at a line ending is
  dropped, and so is the whitespace a line would start with. A stretch with no opportunity in it is broken
  between characters, and a line always takes at least one character, so a box narrower than one glyph still
  makes progress.
* Explicit line breaks (LF and CRLF) are honored, and a trailing break leaves an empty last line so a caret
  has somewhere to sit. Empty content is one empty line.
* Tabs have no glyph of their own here and advance by two spaces.
* A damaged style (NaN size, infinite tracking, absurd box) lays out anyway, clamped to the format's limits,
  rather than panicking.

## Geometry

Three functions answer what a text editor asks of a laid-out paragraph, in `src/geometry.rs`:

* `hit_test(layout, point)` — the character under a point. The point picks the closest line by its
  vertical position, then the character whose advance covers it, and a point past either end answers with
  the character at that end. It is `None` only for a layout with nothing on any line.
* `caret_rect(layout, index)` — the box a caret sits in before the character at that index. The
  line's direction decides the edge: before a character is its left edge in a left-to-right line and its
  right edge in a right-to-left one, and the end of a line is the far end in that direction.
* `selection_rects(layout, range)` — one box per line the range touches, taking each line's own edge
  when the range runs past it, so a selection covers the whole line rather than stopping at its last glyph.
  On one line that mixes directions the box spans both ends of the selection; a caller that needs one box
  per direction run can take the two ends from `caret_rect`.

All three read `LayoutLine::display` and `LayoutLine::range`, so they need no font, no shaper
and no second guess at what was drawn. A line box is the line height tall, from `baseline - lineHeight +
descent` to `baseline + descent`.

## Known gaps

Tracked here rather than in the code.

1. **No vertical writing.** Every line runs left to right; `Direction::TopToBottom` is never set and
   vertical metrics are not consulted.
3. **No language tagging.** The shaper is told the script but not the language, so language-specific
   substitutions (a Turkish dotless i, a Serbian italic form) are not chosen. The style has no language
   field to carry one.
4. **A linked face shapes one character at a time.** When a character has to be linked in, it is shaped on
   its own, so a script that joins letters across that boundary gets the isolated form for that character.
   Fixing it properly means splitting runs by face coverage *before* shaping.
5. **Baselines use the base face's descent** even on a line whose characters were all switched to another
   face, and the first baseline follows the formula above rather than Core Text's own fixed-line-height
   placement, which can differ by a fraction of a pixel.
6. **Color emoji draw as monochrome outlines**: only a glyph's coverage is available, so a color font's
   layers are not composited. A ZWJ emoji sequence is shaped, but the joined glyph it asks for only exists
   in the color face.
7. **Curves are 4x4 supersampled** (ellipses and rounded corners), giving edge alpha in sixteenths; lines
   use a distance-based coverage. Both are anti-aliased, neither is exact area coverage.
8. **Oversized requests**: `rasterize_shape` and `rasterize_layout` return a single transparent pixel when
   the raster cannot fit the format's limits. `commit_text_layer` and `commit_shape_layer` refuse with
   `CommitError::TooLarge` instead, and a style the format would not accept is refused with
   `CommitError::InvalidStyle`.
9. **Committing leaves the layer transform alone.** The macOS app rescales a text layer's transform to the
   new image; here a caller that wants that sizes the box from `text_bounds` itself, so this crate never
   guesses at placement, rotation or flips.
10. **Nothing else is applied to the raster**: no layer opacity, mask, effect or blend, because the
    compositor owns those and the committed pixels stay straight RGBA8.
11. **A cache entry is only as good as the library it was made in.** Faces are keyed by the library's
    own index, so a library whose font set changed after it was built — a new face installed and rescanned
    — must clear the caches (`clear_shape_cache`, `clear_layout_cache`) rather than trust them. Nothing is
    shared between processes: the caches live as long as the `FontLibrary` the editor holds.
12. **No hyphenation.** A long word with nowhere to break is cut between characters, without a hyphen and
    without the language-aware hyphenation points a word processor would use. Adding it means a hyphenation
    dictionary per language, which the style has no field to select anyway.

## Verification

`cargo test -p comp-text`: 305 unit tests in the modules plus 5 integration tests in
`tests/system_fonts.rs` that skip themselves when the machine has no fonts. The unit tests cover UTF-16
run mapping (including surrogate pairs and runs that start inside one), wrapping and hard breaks,
alignment, tracking, leading, damaged and oversized styles, shape geometry, source-over compositing and the
commit path.

The bidirectional tests lay text out with no fonts installed, so the arithmetic is exact: Auto follows the
first strong character, a forced direction only changes the paragraph (a Latin word keeps level two and
still reads left to right inside a right-to-left paragraph), a Hebrew word inside a Latin paragraph turns
around where it stands, a right-to-left paragraph is drawn from its last character, a number inside it
keeps its digits in order, a neutral takes the direction around it, two paragraphs may run opposite ways,
a direction change ends a shaped run (checked against real glyph positions), and a right-to-left paragraph
keeps exactly the baselines, line widths and height of a left-to-right one.

The geometry tests use the same fontless layout: a point inside, past either end, above and below the text,
and on a right-to-left line; a caret at a character, at the end of a line, in a right-to-left line and past
the end of the content; and selections inside one line, over two lines, over whole lines, on a
right-to-left line, across an empty paragraph, and empty or backwards.

The line-breaking tests lay text out in a fixed box with no fonts installed, so every expected line
is arithmetic: Chinese breaks between characters and one character at a time in a very narrow box, no line
ever begins with closing punctuation or ends with an opening bracket, a line broken by hand moves a full
stop up and an opening bracket down, the prohibited characters are the ones kinsoku names, `3.14` is never
split, a number and its unit break at the space and nowhere else, a URL is kept whole when the box holds it
and otherwise breaks after its slash and keeps its host together, mixed Chinese and English keeps the
Latin words whole, an unbreakable run is broken between characters, every line of four awkward paragraphs
fits its box, explicit breaks still make lines, tracking counts against the box, a right-to-left paragraph
breaks by the same rules and still draws each line from its last character, a paragraph of spaces has no
width of its own, and a line of Chinese is as wide as its characters.

The grapheme tests cover the cases UAX #29 exists for: a family emoji that is one cluster of eleven
UTF-16 units and is removed by one backspace, a skin tone that belongs to its base, a flag, a heart with a
variation selector, a combining acute, a Devanagari consonant cluster, a Thai tone mark, and a carriage
return with its line feed; an offset inside a surrogate pair, which snaps and never panics; movement
clamped at both ends of the text; stepping forward and back one cluster at a time; selections that keep
their anchor; deletions at the ends that remove nothing; a range snapped out to cluster boundaries; and two
properties — every offset these functions return is a cluster boundary, and the start and end of every word
segment and of every laid-out line is one too.

The preparation tests cover `prepare_style` loading a document's face once and not twice, `prepare`
by name, the fallback face a Latin face needs for Chinese, the stage times adding up, and a layout that is
answered entirely from the caches doing no shaping and no breaking at all. The benchmark asserts the
things that do not depend on how fast the machine is: that the prepared, unprepared, incremental and
resized layouts are all the same layout field by field, that a keystroke shapes one run and lays out one
paragraph, and that a resize shapes none.

The editing tests are laid out with no fonts installed, so every expected line and column is arithmetic:
words in mixed Chinese and English, an ideograph per word, punctuation and spaces as their own segments,
a decimal and an apostrophe kept whole, word-by-word movement forwards and back, double-click and
triple-click selections, an emoji that is never split by a move or a deletion, the converters between
UTF-16 and layout offsets, line bounds across a soft wrap and a hard break, the caret on a break belonging
to the line above, moving up and down between lines of different lengths (including a right-to-left one)
while keeping the column, the shift-extend variants keeping their anchor, and deletions in the middle of a
word, at the start of the text, and across a wrapped line.

The pre-edit tests cover the normalisation (clauses out of order, overlapping, covered by another, past
the end of the text, empty or backwards, ranges counted in UTF-16 units, a caret past the end) and the
geometry: a box per clause, a clause crossing a line getting one box per line, the clauses of a
right-to-left line running the other way, a clause past the end of the layout or over spaces getting no box,
the bounds of a whole pre-edit and of an empty one, and the candidate anchor at the start of a line, at its
end, on the last line (which opens upwards), past the end of the text, and on a right-to-left line. The last
test is the invariant the caller relies on: composing text and committed text measure the same, so nothing
moves when a composition is committed.

The cache tests cover the shaping cache answering a second layout and shaping again for another font
size, text, face or direction (and *not* for another direction only, where the glyphs are the same), its
capacity bound and eviction, the layout cache reusing the paragraphs an edit did not touch and laying out
only the edited one, a changed box width invalidating it while a changed alignment does not, two identical
paragraphs sharing one entry, clearing the caches, and the hit rate `shape_stats` reports. Two of them are
the hard invariant: a layout built from a warm cache after an edit, and one after a width and tracking
change, are compared field by field against layouts built from nothing.

The fallback-chain tests check the class a character belongs to (Han, kana, hangul, Arabic, Hebrew,
Devanagari, Thai, a pictograph, an arrow, a Latin letter, a digit), that every chain names the face that
covers it first, that a chain is ordered and repeats nothing, that a face this machine does not have is
skipped (a library built from one face answers with that face alone), that a chain is worked out once, that
a face which has the glyph is kept rather than replaced, that a Han, Arabic, Thai and emoji character each
land on the first face of their own chain (and that the emoji face really draws the picture, since a color
font's base glyph could have been empty), and that a chain with nothing left to offer answers with none.

The mirroring tests cover every pair the helper knows at an odd level and its form at even levels, a
character Unicode does not mirror, a `Bidi_Mirrored` symbol with no partner, a right-to-left paragraph drawing
"()" as ")(" and a left-to-right one drawing it as stored (against the glyph ids of a reference layout),
brackets around a Latin word in a right-to-left paragraph turning round while the same brackets around a
Hebrew word in a Latin paragraph do not, and a comparison sign turning round only in the right-to-left run.

The shaping tests assert facts that hold for the faces installed here, and skip when a face is missing:
Arial kerns "AV" narrower than the unshaped layout, Georgia (which has no kerning for it) does not change at
all, Calibri shapes "fi" and "ffi" as one glyph with the swallowed characters keeping no advance, Arial
leaves them as two, x + U+0301 keeps the mark as an attached glyph with an offset while e + U+0301 is
normalized into one glyph, lam + alef is one Arabic glyph, a right-to-left run draws its first character
rightmost, Nirmala UI merges the kssa conjunct and reorders the i vowel sign, a joiner and a variation
selector add no width and no ink and do not change face, Marlett's Latin letters are rescued through a
linked face, and an unshaped layout still matches the old advance-only widths. Subpixel placement is checked
by rendering the same text at tracking 0, 0.1 and 0.34: the first two are pixel-identical because a tenth of
a pixel rounds to no shift, and the third is not.

Sample sheets rendered through the public API and inspected by eye:

* `target-text-vector/visual/bidi.png` — a Latin paragraph with a Hebrew word in it, a Hebrew
  paragraph with a number and a Latin tail, an Arabic line with a Latin tail, and the same lines with a
  selection band and carets drawn from the geometry API.
* `target-text-vector/visual/shaping.png` — shaped text beside the unshaped layout: kerned Latin, Calibri
  ligatures against Arial's lack of them, joined and correctly ordered Arabic against isolated letters,
  Devanagari conjuncts and a reordered vowel sign, and attaching marks.
* `target-text-vector/visual/sheet.png` — the earlier sheet: color runs, font runs, the three alignments,
  tracking, tight leading, rounded rectangle, ellipse, thick round-capped line, pill, a CJK line, an emoji,
  12 px and 72 px text.
