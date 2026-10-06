# comp-gui - the Windows editor shell

A native Windows window (eframe/egui) around the Compositor document model: open a `.comp`
package, see the composite, paint, draw text, grade, mask, import, undo and save.

## How to run

```powershell
# from E:\Compositor-main\compositor_win
$env:CARGO_TARGET_DIR = "E:\Compositor-main\compositor_win\target-gui-tools"

cargo run -p comp-gui                                   # empty 1280x800 document
cargo run -p comp-gui -- path\to\Doc.comp               # open a package
cargo run -p comp-gui -- --flatten in.comp out.png      # headless composite, no window
cargo test -p comp-gui                                  # unit tests

# or with the wrapper script, which sets the target directory for you
.\tools\run-gui.ps1 path\to\Doc.comp
.\tools\run-gui.ps1 -Test                              # smoke test: 40 frames then exit,
                                                        # printing frames, texture size, flatten ms
```

A `.comp` project is a **folder** holding `manifest.json` and `images/`, exactly as on macOS, so
Open and Save As use the folder/file dialogs accordingly. Fixtures live in
`tools/verify/fixtures/` (`demo.comp` is a good first try).

## Shortcuts

| Keys | Action |
|---|---|
| Ctrl+N | New document |
| Ctrl+O | Open a .comp package |
| Ctrl+I | Import an image or PSD as a new layer |
| Ctrl+S / Ctrl+Shift+S | Save / Save As |
| Ctrl+E | Export the flattened composite as PNG |
| Ctrl+Shift+R | Camera Raw on the selected layer |
| G | Gradient: drag on the canvas to fill the selected layer's mask |
| Arrow keys / Shift+arrow | Nudge the selected guide or curve point by 1 / 10 |
| Double / triple click | Select the word / paragraph under the pointer while editing text |
| Ctrl+Left/Right, Ctrl+Shift+Left/Right | Move / extend by word while editing text |
| Home/End, Shift+Home/End | Line start and end, extending with Shift |
| Ctrl+Backspace, Ctrl+Delete | Delete the word before / after the caret (add Shift for the line edge) |
| Ctrl+M | Merge down, or merge the selected layers when several are selected |
| Ctrl+C | Copy the selected layer's pixels to the clipboard |
| Ctrl+Shift+C | Copy the merged composite to the clipboard |
| Ctrl+V | Paste the clipboard's picture as a new layer |
| Ctrl-click / Shift-click a layer row | Add a layer to the selection / select a range of rows |
| Ctrl+Shift+F | Flatten the image to one layer |
| Ctrl+Shift+C | Copy the composite into a new layer |
| Ctrl+Q | Close the window |
| Ctrl+Z | Undo the last step (the Edit menu names it) |
| Ctrl+Shift+Z, Ctrl+Y | Redo |
| Ctrl+A / Ctrl+D | Select all / Deselect |
| Ctrl++ / Ctrl+- | Zoom in / out around the view center |
| Ctrl+0 / Ctrl+1 | Fit to window / Actual pixels |
| Mouse wheel | Zoom around the cursor |
| Space + drag, middle drag | Pan |
| B / E / I / M / V / T | Brush, Eraser, Eyedropper, Marquee, Move, Text |
| [ / ] | Smaller / larger brush |
| Esc | Cancel the stroke, the drag or the selection |
| Double-click a layer name | Rename it |
| Drag a layer row | Reorder it; the strip above a row is where it lands, and dropping on a folder's strip moves it inside |

## Implemented

- **Window**: eframe/egui 0.36, dark theme. The title bar shows the file name and a modified
  marker from `History::is_modified`, which follows the save point through undo and redo.
- **Canvas**: the composite comes from `comp_render::flatten_document`, uploaded as an egui
  texture. Wheel zoom around the cursor, space-drag and middle-drag pan, Fit to window, Actual
  pixels, transparency checkerboard, texture filtering that switches between crisp and smooth at
  100%, brush ring and marquee overlays, and — while a text layer is being edited — its box, the
selection highlight and a caret placed by comp-text's own glyph geometry.
- **Dirty-rectangle repaint**: a stroke repaints only the pixels it changed. `StrokeOutcome.bounds`
  is mapped through the layer transform into canvas pixels, and `engine::flatten_region` composites
  just that rectangle by flattening a translated clone whose canvas *is* the region, with every
  layer narrowed to the pixels the region can show. Measured on a 2048x2048 canvas with a 128x128
  region: **810 ms full, 4.9 ms region (165x)**, pixel-identical to cropping a full flatten. The
  rectangle goes to comp-render's own region render, which pads it by the reach of the document's
  blurs and anchors Grain and Add Noise to the document, so a repaint equals the crop exactly even
  where the pixels come from outside the rectangle. The earlier hand-rolled repaint translated the
  document onto the rectangle and cropped each layer to it first; it was exact only while nothing
  reached across the rectangle's edge. The tests keep that code and show it disagreeing with the
  crop for a blur adjustment layer, Grain and Add Noise, while the region render matches in every
  case (blurred effect layer, blur adjustment, Grain, Add Noise, masked folder, clip chain, rotated
  and scaled layer, off-canvas layers).
  Structural edits (layer add/remove/opacity/undo) still repaint the whole canvas.
- **Layers panel**: top-to-bottom stack with group indentation and folding, visibility toggles,
  click to select, double-click to rename, opacity slider, blend-mode picker grouped by
  `BlendMode::GROUPS`, and New / Copy / Delete / Up / Down. Rows summarise mask, opacity and blend.
- **Row thumbnails**: every row shows its layer scaled to 28 px, with the mask beside it when it has
  one. The cache is keyed on the buffer addresses, the mask state and the document revision, so a
  stroke or a filter refreshes it, and at most two are rebuilt per frame.
- **Drag and drop**: dragging a row moves it, with its subtree, to the strip above any row, into a
  folder (the strip above a folder's topmost child), or to the bottom of the list. `reorder` keeps
  the group rule, refuses a folder dropped inside itself, and reports no change when the drop lands
  the layer where it already was, so a pointless drag records no undo step.
- **Tools**: brush and eraser (size, hardness, opacity) painted by `comp_brush::StrokeSession`;
  eyedropper reading the flattened composite; rectangular marquee clipping the stroke through a
  `comp_brush::Selection` mask; move dragging the selected layer's transform; text (below).
- **Text tool**: click with T to create a text layer where you clicked, or to select the text layer
  under the pointer. The Text panel edits content, face (with a searchable list of installed faces),
  size, tracking, leading, color and alignment; the canvas frame is sized from
  `comp_text::text_bounds`, and Draw rasterizes through `comp_text::commit_text_layer` and sizes the
  layer box to the result. A face the engine had to substitute is reported in the status bar.
- **Text runs and paragraph boxes**: select characters in the content field and give them their own
  color or face, or take the runs off the selection again. Offsets are converted from the editor's
  character indices to the UTF-16 units the format stores, runs are split at the range boundaries,
  touching runs with the same value merge, and anything past the end of the text is clipped or
  dropped. A Paragraph box switch turns the text into a wrapping box with editable width and height.
- **Adjustment layers**: 12 kinds from `Adjustment::new`. The panel shows per-kind parameters:
  Hue/Saturation, Levels (per channel), Curves, Exposure, Gradient Map, Grain, Invert,
  Black & White (read-only note), Color Balance (9 sliders + preserve luminosity), Gaussian Blur,
  Motion Blur and Add Noise. Values are validated before they are stored, and a drag is one undo
  step.
- **Curves editor**: the panel draws the curve through comp-render's own interpolation — the line on
  screen is the line that renders. Click adds a control point, dragging moves it, right-click
  removes it; the two ends keep their x so the curve spans every tone, interior points stay a gap
  apart and x stays strictly increasing. Four channels share the channel picker with Levels, and a
  whole gesture is one undo step.
- **Layer effects**: the six effects with an enable switch, parameters, colors and a remove button,
  each change one undo step; Remove Effects in the Layer menu drops them all.
- **Masks**: add a white mask or one built from the layer's alpha, switch it on or off without
  losing it, remove it, and paint it: with Paint mask on, the brush writes the paint color's
  luminance and the eraser writes black, so a mask is painted rather than punched through.
- **Import**: File > Import as Layer (Ctrl+I), File > Import as Document, and drag and drop. A
  dropped `.comp` folder opens; a dropped image or PSD becomes a document. Layers are placed
  centered, as `EditorSession.insert` does.
- **Camera Raw**: exposure, contrast, highlights, shadows, temperature, saturation and vibrance,
  with Reset/Apply/Cancel. Every preview develops from the pixels the window opened with, and the
  whole session is one undo step.
- **Filter menu**: all 17 macOS filter kinds, run by `comp_render::apply_filter`. Nineteen of
  nothing is re-implemented here: the menu supplies names, groups and dialogs, and the engine
  supplies the pixels. Eight run on the selected layer's pixels (Gaussian Blur, Motion Blur,
  Add Noise, Vignette, Bloom / Glow, Dither, Tonal Contrast, Lens Correction), each with a dialog
  whose ranges are the ones the macOS FilterSettings documents; the six macOS files under Image are
  offered as adjustment-layer creators so their panel stays the only place their settings are
  edited; Camera Raw opens its own window, and Content-Aware Fill repaints the selection through
  comp-brush. Everything is one undo step.
- **External change detection**: the package digest is recorded on open and save, a worker thread
  re-reads it about once a second, and a difference raises "Project changed on disk" with Reload
  from disk, Keep my edits and, when the document is dirty, Save mine over it. The prompt says so
  when reloading would discard unsaved edits, and answering it does not raise the same change again.
- **Layer commands**: Merge Down composites the layer with the sibling below it (a folder merges its
  contents and goes away), Merge Layers does the same for a multi-selection — the picked layers plus
  whatever their folders hold, named and placed after the topmost one — Flatten Image composites the
  whole document into one Background layer, and Composite to Layer adds the composite as a new layer.
  All follow the macOS LayerMerge rules: the merge output is trimmed to what is there, clipped layers
  follow the result, and one step undoes the whole thing.
- **Autosave and recovery**: a document with unsaved changes gets a copy written to the recovery
  folder — the package plus a note saying which document it is and which file it came from — at most
  once every 30 seconds, never while the IO worker is already busy, and only once the document has been
  still for two seconds: the interval says how often a copy *may* be taken, the pause says when it is
  worth taking, so a burst of strokes does not produce a copy per stroke. Someone who never pauses is
  still covered, because four intervals of continuous work force a copy whatever the pause says. Saving the document, or
  closing the editor cleanly, throws its copy away. When the editor starts and finds copies, it
  offers them: recovering one opens it **as a new tab, unsaved, with the original path remembered and
  not written to**, and a copy whose original file is newer says so, because the copy may be stale.
  Copies older than a week are discarded without asking. The decisions are pure functions over a clock
  and a few flags (`src/recovery.rs`) and the writing goes through the IO worker, so a large document
  never stalls a frame.
- **Load failures say what went wrong**: a package that will not open is reported as one of eleven
  kinds — an unsupported version (with both version numbers), a damaged manifest (with the JSON line
  and column), a corrupt package, a missing or damaged asset (by name), a limit (with the limit), an
  unusable path, a damaged Photoshop file, an image kind the importer cannot take, an operating system
  refusal, or the reader's own words — each with a sentence of advice. The status bar shows the
  one-line summary and a dialog shows the reason and the advice.
- **The window remembers itself**: the open tabs and their paths, the front tab, the compositor
  preference and the view switches come back after a restart, along with the window's size and
  position (eframe's persistence, which pulls in ron). A package that has since been moved or deleted
  is listed in the status bar instead of being opened, and an unsaved document has no path to restore.
  A path given on the command line wins over the saved session.
- **Rulers, guides and the grid**: rulers along the top and the left number every 1-2-5 step that is
  about seventy points wide and mark where the pointer is. A guide is pulled out of a ruler, dragged
  (snapped), moved again later, removed with a right-click, and every one of those is a single undo
  step; guides live in the document, so they save and reload with the package. The grid is drawn at
  the spacing and subdivisions the settings say, and View > Grid Settings sets them. Snapping pulls a
  guide or a layer move to the guides, the grid, the canvas edges and center, and other layers'
  edges, within five screen points, with a switch for each kind.
- **Tabs**: every open package gets a tab with its own document, history, view, textures and
  thumbnails; the tab strip adds a document with + and closes one with x. Closing a tab that has
  unsaved edits asks first (Save, Discard, Cancel), opening a package that is already open brings
  its tab forward instead of loading it twice, and the package watcher follows whichever tab is in
  front.
- **Colour panel**: one panel with a hue strip, a saturation/value square, HSV, RGB, alpha, a hex
  field, presets and the colours this session has used. The brush swatch, the text colour and the
  filter dialogs' colours all open it.
- **Guides, locking and hiding**: a guide can be locked against dragging and deleting, hidden one at
  a time from View > Show Guides, deleted by dropping it back on a ruler, and a drag shows a bubble
  with the pixel position it is at.
- **Masks**: a gradient tool (G) fills the selected layer's mask with a linear or radial ramp drawn by
  dragging on the canvas, replacing the mask, adding to it or subtracting from it; the mask panel sets
  the shape, the blend, the invert and a feather of any radius up to 250 pixels. Show draws the mask
  as a red overlay over the composite (the default, as Quick Mask does), as the gray plane itself, or
  not at all. Filling and feathering are one undo step each.
- **Black & White** has its six mix sliders (reds, yellows, greens, cyans, blues, magentas, -200 to
  300) and a tint whose colour comes from the shared panel.
- **Curves**: clicking a control point selects it and the panel shows its input and output as editable
  numbers; the arrow keys move it by one, or by ten with Shift held.
- **Text editing on the canvas**: the caret and selection follow comp-text's UAX#29 editing rules
  rather than any boundary logic of our own — a double click takes the word under the pointer and a
  triple click its paragraph, Ctrl+Left/Right move by word, Ctrl+Shift+Left/Right extend by word,
  Home/End go to the line edges and Shift+Home/End extend to them, Up/Down keep the column, and
  Ctrl+Backspace/Ctrl+Delete delete a word (Ctrl+Shift deletes to the line edge). Every range the
  deletes answer with is UTF-16, which is what the run offsets are, so colours and faces follow.

  **Which set of functions is used where**, following comp-text's own rule:

  | Gesture | comp-text API | Unit |
  |---|---|---|
  | Left/Right, Shift+Left/Right | `next_grapheme`/`prev_grapheme`, `select_next_grapheme`/`select_prev_grapheme` | one **grapheme cluster** |
  | Backspace, Delete | `delete_grapheme_backward`/`delete_grapheme_forward` | one cluster |
  | Ctrl+Left/Right, Ctrl+Shift+Left/Right | `next_word_start`/`prev_word_start`, `select_next_word`/`select_prev_word` | one word |
  | Ctrl+Backspace/Delete, Ctrl+Shift+... | `delete_word_backward`/`delete_word_forward`, `delete_to_line_start`/`delete_to_line_end` | one word, or to the line edge |
  | Double/triple click | `word_at`, `paragraph_at` | a word, a paragraph |
  | Home/End, Shift+Home/End, Up/Down, Shift+Up/Down | `line_start`/`line_end`/`next_line`/`prev_line` and their `select_` forms | one line |
  | A click on the canvas | `hit_test`, then `utf16_of_char` → `snap_to_grapheme` → `char_of_utf16` | snaps out of a cluster |
  | Before writing an edit back | `snap_range_to_graphemes` | no run offset lands inside a cluster |
  | Typing, including an input method's commit | `snap_range_to_graphemes` for a selection, `grapheme_boundaries` for a bare caret | text goes before a whole cluster, and typing over part of one takes all of it |

  The word set is entered through `snap_to_grapheme` (a caret can arrive from anywhere) and both
  ends of a selection are snapped before an extension, so a family emoji is one arrow step, one
  backspace and one delete however the caret is moved, and a colour run can never cover half of one.
  The input method's DeleteSurrounding is snapped the same way.
- **Multi-selection**: plain click replaces the selection, Ctrl-click adds or removes one layer,
  Shift-click takes the rows between the active layer and the clicked one, and the panel highlights
  every selected row with the active one in bold. Delete and the merge command follow the selection,
  and both say in their tooltip which of the two they will do.
- **Clipboard**: Copy writes the selected layer's pixels to the Windows clipboard through arboard,
  Copy Merged writes the composite, and Paste puts the clipboard's picture on the canvas as a new
  layer, centered. A clipboard with no picture answers with that sentence rather than pasting
  something blank. The editor's commands take a Clipboard trait, so the round trip is tested against
  an in-memory double instead of the real clipboard.
- **Canvas text editing**: with a text layer open, a click places the caret where the pointer landed
  and a drag selects from it; the caret and the highlight are drawn from comp-text's hit_test,
  caret_rect and selection_rects, and typing replaces the selection and redraws the pixels. Runs
  follow the edit, and typed characters take the formatting they were typed into.
- **Input methods**: the canvas takes egui's Ime events. The composing text is typeset on its own in
  the draft's own face — so the space it takes is the space it keeps once committed — and drawn over
  the layer clause by clause: an underlined clause is underlined, the active clause is tinted, boxed
  and drawn heavier, and the caret sits where the input method said rather than at the end of the
  string. The candidate window is anchored properly: the caret's box goes out through egui's
  `output.ime`, which egui-winit turns into winit's `set_ime_cursor_area`, which is what Windows'
  IME uses to place its list. A small tick is drawn where the anchor points, and up or down according
  to the direction comp-text suggests, so the anchor is visible even when no list is up. A commit
  inserts the text through the same run rules as typing, DeleteSurrounding removes what the input
  method asks for, plain text events still go straight in, and Backspace takes back a composition
  before it edits any text.
- **Undo/redo**: one step per stroke, per slider drag, per rename, per layer command, per text or
  filter session, through `comp_core::History`; the Edit menu spells out the action name.
- **Status bar**: document size, zoom, current tool, mask mode, selection rectangle, document and
  history memory, and the last composite time in milliseconds.

## Which subject extractor answered

comp-brush holds two extractors: the U-2-Netp network (Apache-2.0) run through tract, and the classical
colour-statistics extractor that always works. Until this round the editor ran neither, so a result
could not have told the two apart - and a silent fall back is exactly what makes a user distrust a
cut-out. Both are now wired, and which one answered is visible before, during and after a run.

- **Status bar, always**: @Subject: model u2netp (Apache-2.0) at <path>@ when a model file is there, or
  @Subject: classical algorithm (no model found)@ when it is not. The second carries, on hover, the
  three places a model file is looked for, in the order they are searched:
  @COMPOSITOR_SUBJECT_MODEL@, @models\u2netp.onnx@ beside the executable, and @models\u2netp.onnx@
  beside the comp-brush crate in a checkout. The line is decided from the file alone when the window
  opens, so it is right before anything has run.
- **After a run, one line naming who answered and how long it took**:
  @Subject: classical algorithm answered in 41 ms (the matte covers 38% of the layer)@, replaced when
  the model lands by @Subject: model u2netp answered in 412 ms (...)@. A model that is there but will
  not load says so and says which extractor answered instead.
- **While the model works**: @Subject: model u2netp is working (the classical result is on screen)@.
- **The actions**: Select Subject keeps the matte as the layer's mask (this editor has no free-form
  selection to hand back), and Remove Background cuts the background out of the layer's pixels. Both
  run the classical extractor on the click - milliseconds, so the canvas never freezes - and hand the
  model to comp-brush's background job (@SubjectPreview@, @SubjectJob@), taking its answer when it
  lands. Each applied answer is one undo step, so one undo steps back from the model's matte to the
  classical one, and another to where the action started.
- The two session commands take a matte and a label; which extractor produced the matte is the
  window's business and the window is what reports it. They are in the undo-coverage table with every
  other entry, so a future change that forgets the history fails that test.
- The smoke test's evidence line carries the backend too: @subject=model u2netp@ on a machine with the
  model, @subject=classical (no model)@ without it.
## Undo coverage: every entry that changes the document

Following the journey test's find, the audit was done once and for all: every entry point that can
change the document is listed, classified, and held to its classification by a table-driven test in
`src/session.rs` (`every_entry_that_changes_the_document_records_history`). A new entry that forgets
to record a step, or that records one while a drag is still running, fails that test.

| How the entry changes the document | Entries | History |
|---|---|---|
| `edit(...)`: begin, change, finish in one call | add_layer, duplicate_active, delete_active, delete_selection, merge_down, flatten_image, copy_merged, move_active_layer, move_layer_to, paste_from_clipboard, add_text_layer, add_adjustment_layer, add_layer_mask, remove_layer_mask, add_guide, remove_guide, clear_guides | exactly one step |
| `change(...)`: one step when called on its own, joins the gesture when a panel already opened one | set_opacity, set_blend, set_visibility, set_name, translate_layer, move_guide, set_text_style, commit_text, update_adjustment, update_effects, clear_effects, set_mask_enabled, replace_layer_pixels, fill_mask_gradient, feather_mask, apply_filter | one step, or part of the drag's step |
| The stroke itself: begin_stroke and stroke_to mutate, end_stroke records | a brush stroke, a mask stroke | one step per stroke, however many samples it took |
| Wrapped by the window, not by the session | the Camera Raw panel, the guide drag, the layer-row drag, the curve drag | one step per gesture |
| Nothing, and this is deliberate | set_tool; select_all, deselect, set_selection; set_message and set_error; the view settings (zoom, pan, which panels are open, the grid and guide switches, the mask preview); the open tabs; the recovery and session state | not the document, so not in its history |

**What the audit found and fixed.** Eight entries recorded nothing at all: move_guide, set_text_style,
commit_text, update_adjustment, update_effects, clear_effects, set_mask_enabled and
replace_layer_pixels. Most of the panels happened to wrap them in begin_edit and finish_edit, so they
worked by luck of the caller - and one caller did not wrap: the curve editor returned its new points
and then called update_adjustment outside the drag it had just closed, so **dragging a curve point
recorded no step and could not be undone**. All eight now go through `change`, which records when it
is on its own and joins when it is not, so correctness no longer depends on every caller remembering.

**The redo side is asserted too**: an edit made after an undo clears the redo stack
(`an_edit_after_an_undo_clears_the_redo_stack`), and the coverage test checks after every entry that
an undo makes exactly one redo available.
## The end-to-end journey, and what it found

`tests/journey.rs` drives the editor the way a person does - open, add a layer, paint, blend and fade,
add an adjustment, blur, mask and feather, save, reopen - through the session API rather than the
panels, with no window. Every step checks the document, that the region render equals the crop of the
full one, and that undo and redo return the pixels byte for byte, including one undo that crosses a
save point. Three structural edits and three pixel edits are covered, each in its own test as well as
in the journey.

What it found, on its first run: **a visibility box, a blend mode chosen from the menu, a typed layer
name, a keyboard opacity digit and a one-shot move recorded no undo step at all**, because those
setters mutated the document directly and only a wrapped drag called begin_edit and finish_edit. The
panels' sliders were fine; everything a click drives was not. The setters now go through a helper that
records one step when the caller is not already inside a multi-frame edit, so a drag stays one step and
a click becomes one - and a test pins both halves.

Two expectations were wrong rather than the code, and are written down where they were found: an empty
transparent layer above a picture cannot change it, and feathering rewrites the mask but need not move
the composite, since that depends on where the layer has pixels.

Not driven here, and why: the panels, the menu bar, the dialogs and the input method need an egui
context and a window, so their behavior is covered by the smoke run and by unit tests of the logic
behind them (the shortcut table, the row layout, the gesture translation). The journey stops at the
session API, which is exactly the boundary the panels call across.

## Not implemented, and why

- **How a load failure is classified, path by path** (comp-core grew the finer kinds in its own
  round; this is what reads them):
  - A **package** failure arrives as a `comp_core::Error` and is **matched by variant**, with the
    place taken from the accessors — `field()` for the manifest path, `asset()` for an image name,
    `path()` for a file, `line()`/`column()` for a parse, `detail()` for the reason and `is_coarse()`
    to know that a kind can say no more. Nothing on this path reads a sentence. `asset()` answers for
    the coarse `MissingAsset` as well as for the fine kinds, and it answers with the file's own name:
    a producer that raised it with `images/A1B2.png` or with a path from disk still gets `A1B2.png`
    into the dialog, which a test pins down for both separators.
  - A **reader** failure — comp-io's importers, which answer with sentences rather than kinds — goes
    through `from_message`, and that is the one path that still depends on wording (which is why
    `classify_asset` still exists). It is used for imports, for Photoshop files and for image
    decoding, and its tests are the ones that pin the sentences down.
  - The **coarse kinds** kept for older producers (`Invalid`, `MissingAsset`, `Encode`, `Decode`,
    `Message`, `TooLarge`, `UnsupportedVersion`, `BufferSize`) are still mapped, each as far as its
    shape allows, so a failure that has not moved to a fine kind still shows something specific.
  - A **kind added after this file is written** falls through the wildcard arm to the sentence
    classifier: a new variant shows its own words rather than failing to compile, and the arm is
    marked `unreachable_patterns` because every kind that exists today is matched above it.
  - What the **caller** knows better than the error is added on top: a package that cannot be read and
    carries no path of its own is reported with the folder that was opened, and a path with nothing at
    it is caught before the read rather than after it.

- **Guides** can be locked, hidden one at a time, deleted by dropping them back on a ruler, nudged
  with the arrow keys once selected and typed to an exact position in the status bar. Locking and
  hiding are view settings: the package format's guide carries an id, an axis and a position.
- **Tabs** come back after a restart, but only the packages that live on disk: an unsaved document
  cannot be restored, and a package that has been moved or deleted is reported instead of opened.
- The **colour panel** is shared by everything that picks a colour: the brush, the text tool, the
  filter dialogs (including the two dither colours), the gradient map's ends, the Black & White tint
  and all six layer effect colours. Its popup is one `Area` drawn after the panels, so no control
  needs a window of its own.
- **Move tool and groups**: only the selected layer's transform moves. Moving a folder would have to
  cascade into its children's transforms, which the document model does not express.
- **Black & White** shows a note instead of its mix sliders; the other eleven adjustment kinds are
  fully editable. Curves has no numeric readout of a selected point.
- **Remove Background** is the one filter the menu lists and disables: it needs a
  subject-detection model this build does not ship, and the tooltip says so.
- **Effects** expose the six effects' own parameters. Their **blending options** — a per-effect blend
  mode and knockout — are **not in the format**: every effect record in comp-core carries colour,
  opacity, size, blur, angle and inside/outside and nothing else, so the panel shows a disabled
  "Blending options" row that says so. Adding them means new fields on those records and a format
  version bump; the UI is ready for them the moment the fields are.
- **Masks** are painted with the brush, filled with a linear or radial gradient (replace, add or
  subtract) and feathered. **Mask density** is **not in the format**: a mask is one Gray8 plane plus an
  on/off flag, so the panel shows a disabled density control explaining that it needs a new field on
  the mask record and a format version bump; the gradient's subtract blend and painting are what
  stands in for it today.
- **Input methods, and what the platform does not tell us**: comp-text can draw a pre-edit clause by
  clause, but egui's `Event::Ime::Preedit` carries only the composing string and, sometimes, the
  range of characters the input method is working on — `active_range_chars`, counted in characters
  and with no styles and no caret index of its own. winit 0.30 has the same shape (`Ime::Preedit {
  text, cursor }`): Windows' clause segmentation and clause attributes never reach this layer. What
  is drawn today is therefore the honest best: the active range becomes the active clause, everything
  around it is underlined, the caret goes at the end of the active clause, and an input method that
  reports nothing but a string gets one underlined clause for the whole of it. Real clause information
  needs a platform IME integration of our own — handling `WM_IME_COMPOSITION` and reading
  `ImmGetCompositionString` with `GCS_COMPSTR`/`GCS_COMPATTR`/`GCS_CSTRATTR` (IMM32), or an
  `ITfComposition`/`ITfDisplayAttributeInfo` sink (TSF) — and feeding comp-text's
  `PreeditClause` list from it; the drawing and the candidate anchor above are already in place for
  when that lands. The candidate list itself stays the platform's window, positioned from our anchor.
- **Camera Raw** previews synchronously on the UI thread, and only the seven basic sliders are
  exposed out of `RawSettings`'s full set.
- **Import** always centers the placed layer; there is no drag-to-place.
- **Tablet pressure and tilt**: pointer input is mouse-only.
- **Recent files**, the compositor preference and window-layout persistence: eframe persistence is
  not enabled, so the "Prefer GPU / Force CPU" switch resets with the session.

## Parameter parity with macOS (12 adjustments, 6 effects, the filters)

Extracted from `Document/LayerEffects.swift` (the six effects), `Document/ImageAdjustments.swift`
(exposure, Black & White, color balance, grain), `Document/Filters.swift` (the filter settings and
their defaults) and `Document/LayerAdjustment.swift` (the adjustment kinds). macOS keeps each
parameter in a struct whose **default is the document's default** and whose `isValid` gives the
**range**; both are written down in `src/parity.rs`, the panels take their slider ranges from there,
and tests hold the two together. A default that drifts renders the same document differently on the
two sides, which is why the defaults are asserted against comp-core's own.

### Same on both sides

| Parameter | Range | Default |
|---|---|---|
| Stroke size / opacity / color | 0-500 px, 0-1, RGB 0-1 | 4, 1, black |
| Shadow angle / distance / blur / opacity | -360-360, 0-5000 px, 0-500 px, 0-1 | 90, 20, 20, 0.5 |
| Inner shadow angle / distance / blur / opacity | the same | 90, 10, 10, 0.5 |
| Color overlay opacity / color | 0-1, RGB 0-1 | 1, black |
| Outer glow / inner glow size / opacity / color | 0-500 px, 0-1 | 20 and 10, 0.75, white |
| Exposure exposure / offset / gamma | -20-20, -0.5-0.5, 0.01-9.99 | 0, 0, 1 |
| Levels black / gamma / white / output black / output white | 0-255, 0.01-9.99, 0-255, 0-255, 0-255 | 0, 1, 255, 0, 255 (the identity) |
| Black & White six mixes | -200-300 | 40, 60, 40, 60, 20, 80 |
| Black & White tint hue / saturation | panel's own | 40, 20 |
| Color balance, nine values | -100-100 | 0 each |
| Grain amount / size / roughness | 0-100, 0.5-20 px, 0-100 | 25, 1.5, 50 |
| Hue/Saturation hue / saturation / lightness | -180-180, -100-100, -100-100 | 0, 0, 0 |
| Filter dialogs (vignette, bloom, tonal, dither, distortion, blur, noise) | from `filters.rs`, which a test already holds to what the engine clamps to | `FilterSettings` defaults |

### Fixed by this audit (the panel disagreed)

| Parameter | Was | Now | Where the number comes from |
|---|---|---|---|
| Shadow and inner shadow **angle** | -180-180 | **-360-360** | `LayerEffects.swift`: `(-360...360).contains(angle)` |
| Shadow and inner shadow **distance** | 0-500 | **0-5000** | the same: `(0...5000).contains(distance)` |
| Grain **size** | 0.1-10 | **0.5-20** | `ImageAdjustments.swift`: `sizeRange = 0.5...20` |
| Gaussian blur adjustment **radius** | 0-500 | **0.1-250** | the filter dialog's own range, which the engine clamps to |
| Motion blur adjustment **angle** | -180-180 | **-90-90** | the same |
| Motion blur adjustment **distance** | 0-500 | **1-2000** | the same |
| Add noise adjustment **amount** | 0-100 | **0.1-400** | the same |

The last four were inconsistencies **inside this build**: the blur and noise adjustments are the same
filters the dialogs offer, and the panels were offering different limits from the dialogs for the same
settings, so a value set in one place could not be reached in the other. The three effect and grain
ranges were narrower than macOS validates, so a document written on macOS could hold values this build
would not let anyone type.

### The 17 filters, one by one

The filter sheet (UI/FilterSheet.swift) states every slider's range, and Document/Filters.swift gives
the settings' defaults. The audit walks the 17 entries of the filter menu:

| Filter | Parameters checked | Ranges | Defaults |
|---|---|---|---|
| Gaussian Blur | radius 0.1-250 px | same | 1 |
| Motion Blur | angle -90-90, distance 1-2000 px | same | 0, 10 |
| Add Noise | amount 0.1-400 %, plus the Gaussian and Monochromatic switches | same | 10 |
| Vignette | amount, midpoint, feather, highlights 0-100 %, roundness -100-100, colour | same | 35, 50, 60, 25, 100 |
| Bloom/Glow | amount 0-100 %, radius 1-150 px | same | 40, 24 |
| Tonal Contrast | amount 0-100 %, shadows/midtones/highlights -100-100 %, radius 1-100 px | same | 50, 40, 60, 30, 16 |
| Lens Correction | remove distortion -100-100 | same | 0 |
| Remove Background | advanced only: refine 0-40 px, contrast 0-100 %, shift edge -10-10 px | same | 12, 25, 0 |
| Curves, Exposure, Gradient Map, Grain, Black & White, Color Balance | adjustment-layer kinds, audited with the adjustments above | same | same |
| Camera Raw | comp-raw's own panel, which has its own range test | - | - |
| Content-Aware Fill | no parameters | - | - |
| Dither | **this build's own parameters** (a style with pixel size, levels, amount and tone) | ours | ours |

Two entries are deliberately not claimed as parity:

- **Dither**: macOS's sheet drives glow, dots, angle, diffusion, density and contrast; this build's
  dither is a style plus four numbers, which is a different parameter set rather than a different
  range for the same one. comp-render owns that design, so nothing was changed and no parity is
  claimed (a test asserts the table records no macOS entry for it).
- **Remove Background**: the settings shown are the Advanced ones; Basic has none. The extraction
  itself is this build's own algorithm, which is why it is described here rather than compared.

The ranges in the dialogs were already the sheet's, so this round changed no filter range: what it
added is the table, the tests that hold the dialogs to it, and the defaults check that compares
comp-render's `FilterSettings::default()` with macOS's. Those defaults agree, item by item, which is
the property that keeps a document looking the same on both sides.

### Not settled, and honestly so

- **Levels gamma**: the panel offers 0.1-9.99, comp-core validates only `gamma > 0`, and macOS's
  levels filter reads a `LevelRange` whose gamma bounds are not written in the sources this audit read
  (`Filters.swift` clamps the stored range but states no limits). The exposure gamma range is 0.01-9.99
  in `ImageAdjustments.swift`, so 0.01 is the likely answer, but it is left as it is rather than
  guessed: it is listed here for whoever owns the format.
- **Black & White tint hue and saturation**: settled by the filter audit - the sheet gives hue 0-360
  and saturation 0-100, and the table now records those. This build edits the same two numbers through
  a colour picker rather than two sliders, which can express the same range.
- **comp-core's validation is wider than any panel**: `hue.abs() <= 360`, `saturation/lightness <= 100`,
  `noise_amount` in 0.1-400. The panels are narrower on purpose in places (the hue slider is -180-180,
  which covers the circle once). Nothing in the format was changed by this audit.
## Keyboard and menu parity with macOS

Extracted from `compositor_mac/Compositor/UI/KeyboardShortcuts.swift` (`ShortcutDefinition.all`, whose
modifier bits are Command 1, Option 2, Control 4, Shift 8) and the menu definitions in
`Compositor/CompositorApp.swift`. **The mapping rule**: Command becomes Ctrl, Option becomes Alt,
Shift stays Shift; macOS's own table never uses Control, so nothing collides with Ctrl. Where the
two would collide the macOS chord wins and the port's own binding moves, and an open text session
(or an input method composition) takes the keys it needs before any canvas binding sees them.

Every binding lives in `src/shortcuts.rs`, with its macOS chord and its parity recorded beside it, and
the dispatch reads that table, so the menus, the keys and this table cannot drift apart.

### Same as macOS (parity: same)

| macOS | Action | Here |
|---|---|---|
| Cmd Z / Cmd Shift Z | Undo, Redo | Ctrl+Z, Ctrl+Shift+Z (+Ctrl+Y, a Windows habit) |
| Cmd N / Cmd O / Cmd S / Cmd Shift S | New, Open, Save, Save As | unchanged |
| Cmd Shift E | Export PNG | Ctrl+Shift+E (was Ctrl+E before this audit) |
| Cmd Opt Shift S | Export JPEG | unchanged, added this round |
| Cmd W / Cmd Q | Close the project, quit | Ctrl+W (closes the tab), Ctrl+Q |
| Cmd X / Cmd C / Cmd Shift C / Cmd V | Cut, Copy, Copy Merged, Paste | unchanged (Cut copies the layer, then deletes it) |
| Cmd A / Cmd D | Select All, Deselect | unchanged (a text session takes Ctrl+A) |
| Cmd 0 / Cmd 1 / Cmd = / Cmd - | Fit, Actual pixels, Zoom in, Zoom out | unchanged (+Ctrl+plus) |
| Cmd M / Cmd L / Cmd U / Cmd I | Curves, Levels, Hue/Saturation, Invert | added this round, as adjustment layers; Import moved to Ctrl+Shift+I |
| Cmd Shift N / Cmd J | New blank layer, Duplicate | added this round |
| Cmd ] / Cmd [ | Move layer up, down | added this round |
| Cmd E | Merge layers / merge down | added this round (was Ctrl+M, which macOS gives to Curves) |
| Delete | Delete the selection or the layer | added this round |
| Cmd ' / Cmd ; / Cmd R / Cmd Shift ; / Cmd Opt ; | Grid, guides, rulers, snap, lock guides | added this round |
| [ / ] | Smaller and larger brush | unchanged |
| Shift [ / Shift ] | Softer and harder brush | added this round |
| Shift - / Shift = | Previous and next blend mode | added this round |
| 0-9 | Layer opacity, one digit for the tens | added this round |
| arrow / Shift arrow | Nudge 1 px / 10 px | added this round (the arrows belong to a text session first, then a guide, then a curve point, then the layer) |
| Cmd Return | Finish editing text | Ctrl+Enter, added this round |
| B E I M V T G | Brush, eraser, eyedropper, marquee, move, type, gradient tools | unchanged, the same letters |
| Esc | Cancel what is in flight | unchanged |

### Implemented but on different keys (parity: rebound)

One was found and fixed during the audit: **Export PNG** was on Ctrl+E, which macOS gives to Merge
Layers. It is now Ctrl+Shift+E, exactly the macOS chord, and Merge Layers took Ctrl+E. **Export JPEG**
keeps the macOS chord too. Nothing in the table is left on a chord macOS uses for something else.

### macOS has it and this build does not (with the reason)

| macOS | Action | Why not |
|---|---|---|
| Cmd H | Show transform controls | no interactive transform tool yet |
| Cmd Opt C / Cmd Opt I | Canvas Size, Image Size | no such commands |
| Cmd T | Transform layer or selection | same as transform controls |
| Cmd G / Cmd Shift G / Cmd Opt G | Group, ungroup, clipping mask | the format has folders but the editor has no group commands |
| Cmd Shift I | Inverse selection | no selection-inverse command |
| Opt Delete / Cmd Delete / Shift Delete | Fill with foreground, background, content-aware | no Fill command (the content-aware path exists only as a filter) |
| Cmd arrows / Cmd Shift arrows | Move selected pixels | move is on the canvas tool, not the keyboard |
| A H Z J S U W L R C | Select, hand, zoom, healing, clone, shape, magic wand, lasso, blur, crop tools | those tools do not exist in this build; the seven that do use the macOS letters |
| X / D | Swap and reset colours | one colour slot, no foreground/background pair |
| Tab | Cycle tool mode | no tool modes to cycle |
| Return | Apply the current canvas operation | nothing to apply outside a text session |
| Shift U | Cycle shape kind | no shape tool |
| Opt arrows | Text tracking and leading | the text style has neither |
| Opt P | Toggle the Levels preview | an adjustment layer previews live, so there is no preview to toggle |
| Space | Temporary hand | space-drag panning exists, but it is not a binding in the table |

### This port's own bindings (macOS has nothing here)

| Here | Action |
|---|---|
| Ctrl+Y | Redo, because Windows fingers expect it |
| Ctrl+Shift+I | Import as a layer |
| Ctrl+Shift+F | Flatten Image |
| Ctrl+Shift+R | Camera Raw |
| Ctrl+plus | Zoom in, for keyboards without an equals key |
| Ctrl+M / Ctrl+L / ... | see above: these are macOS chords, not ours |

### Not feasible here, and why

Cmd Opt A (Select Subject) and Cmd Opt H (Hide Compositor) are macOS services: the first is Vision's
subject segmentation (this port has its own classical extractor, reached from the menus, with no
system service to bind), the second is the application-hide service an app gets from AppKit and
Windows has no equivalent of.

### Conflicts

`src/shortcuts.rs` holds the rules as tests: no two bindings in one scope share a chord; a chord may
appear in both scopes only when the text scope shadows it (Ctrl+A); every action is bound exactly
once; every binding records its macOS chord and its parity; a binding claiming parity has to have the
chord the platform mapping produces; and the arrow keys resolve to exactly one owner at a time.
## Performance notes

- Compositing and file IO run on worker threads; the UI thread only hands over a document clone and
  polls. Render jobs coalesce, merging their scopes so no queued area is lost.
- Two compositors: a whole-canvas render (a structural edit, an export) prefers
  `comp_render::gpu::flatten_document_gpu` and falls back to the CPU for the whole image the moment
  the device or the document refuses; a stroke's dirty rectangle always stays on the CPU, where a few
  milliseconds of work beats a round trip. The status bar names the device in use and carries the
  "Prefer GPU / Force CPU" switch, and the smoke line prints the same choice. On a machine with no
  adapter the line reads `CPU - no GPU: no adapter`, which is what this build machine reports.
- The package watcher has its own thread, so no digest is ever read on the UI thread.
- Preview renders during a stroke are throttled to one per 40 ms; the end of a stroke always forces
  an exact full render.
- `comp_brush::StrokeSession` keeps the stroke's own coverage and the pixels it started from, so a
  pointer sample only rewrites what it adds. The layer buffer is copied once per stroke when the undo
  snapshot or a render job shares it, which is the price of handing the document to a worker without
  a lock.

### The editor's own numbers

`src/bench.rs` holds release benchmarks for the editor's share of a frame — the panel, thumbnails,
the grid, the image egui uploads, and typing — with the compositor beside them for scale. Run them
with:

```
cargo test --release -p comp-gui --lib bench -- --ignored --nocapture --test-threads=1
```

| What | Time |
|---|---|
| 4000x4000, 20 layers: full repaint, CPU | ~1070 ms |
| 4000x4000, 20 layers: full repaint, preferred backend | ~1080 ms (this machine's layers have offsets, so the GPU refuses them and the CPU runs) |
| 4000x4000: layer order change, then the repaint | ~1115 ms (the repaint, not the edit: the swap itself is 0.00 ms) |
| 4000x4000, 20 layers: undo + redo | 0.00 ms (the history swap; the repaint that follows is the line above) |
| 4000x4000: one 256x256 region repaint | 5.1 ms |
| 4000x4000: a stroke frame (union + region) | 3.2 ms |
| 4000x4000: the whole composite as the image egui uploads | 17.2 ms, once per full render |
| 4000x4000: a 256x256 rectangle as an upload image | 0.03 ms |
| 100 layers: panel rows as data | 0.03 ms |
| 100 layers: thumbnail keys and the stale list | 0.00 ms |
| 100 layers: two thumbnails, the per-frame budget | 0.05 ms |
| 5000x5000: grid lines for both axes | 0.00 ms |
| 5000x5000: a pan/zoom frame of view arithmetic | 0.00 ms |
| 5000x5000: a frame of guide and snap targets | 0.00 ms |
| Typing: relayout a 400 character paragraph | 0.01 ms |
| Typing: relayout and rasterize one keystroke | 0.14 ms |
| 20 / 100 / 400 layers: one panel frame, every row drawn | 0.5 / 2.8 / 12.9 ms |
| 20 / 100 / 400 layers: one panel frame, visible rows only | 0.5 / 1.2 / 1.2 ms |

What that changed: **the layer panel now draws only the rows its viewport can show**
(`ScrollArea::show_rows` over a uniform 34 point row). At 400 layers that is 12.9 ms → 1.2 ms per
frame — the difference between dropping frames and not — and 10.7 times less work. The rows were
already cheap as data (0.03 ms); it was the widgets that cost.

What was measured and left alone, because it is already inside a frame:

- Thumbnails are built at most two per frame and cached by a key that covers pixels, mask and
  document revision, so 100 layers cost 0.05 ms. Virtualization makes them lazier still: a row that
  is off screen is never asked for one.
- A drag inside the virtualized layer list scrolls it when the pointer comes within 24 points of an
  edge, at up to 14 points a frame and faster the deeper into the margin it is (`panel::autoscroll_step`,
  tested): without that the list could only drop onto the rows it happened to be showing.
- The texture is uploaded when a render finishes, when the zoom crosses the filtering threshold, or
  when the mask preview's document changes — never once per frame. A region upload converts in
  0.03 ms; only a full-image upload pays the 17.2 ms above, and it follows a full render that costs
  fifty times as much.
- The grid, snapping and the pan/zoom arithmetic round to zero at 5000x5000, and typing costs a
  fraction of a frame per keystroke, so the per-keystroke relayout and rasterize stays as it is.
- The document is cloned when a render is asked for, which happens when the document changes, not
  every frame.

## Layout

| Module | Contents |
|---|---|
| `view.rs` | Canvas zoom/pan math and the checkerboard budget (pure, tested) |
| `tools.rs` | Tool enum and the pointer state machine (pure, tested) |
| `panel.rs` | Layers-panel row order, indentation and folding (pure, tested) |
| `curve.rs` | Curve control points: add, move, remove, sampling for the widget (pure, tested) |
| `thumbs.rs` | Thumbnail keys, invalidation budget and packing (pure, tested) |
| `reorder.rs` | Drag-and-drop placements and the group-subtree move rules (pure, tested) |
| `runs.rs` | Text run split, merge, clip, clear and shift over UTF-16 ranges (pure, tested) |
| `multiselect.rs` | Which layers a click selects: replace, toggle, extend (pure, tested) |
| `clipboard.rs` | The clipboard trait, the Windows clipboard and an in-memory double (tested) |
| `textedit.rs` | The text caret, typing and the canvas/layout mapping (pure, tested) |
| `textnav.rs` | Word, line and delete gestures through comp-text's editing rules (pure, tested) |
| `ime.rs` | The input-method composition: preedit, commit, cancel, and the comp-text pre-edit (pure, tested) |
| `guides.rs` | Rulers, the grid, snapping and the snap targets (pure, tested) |
| `tabs.rs` | Tab transitions: which is in front, closing, reopening (pure, tested) |
| `color.rs` | Colour conversions, hex parsing and the recent list (pure, tested) |
| `maskfill.rs` | Mask gradients, blend modes and the feather blur (pure, tested) |
| `bench.rs` | Release benchmarks for the editor's own frame costs (ignored by default) |
| `session_state.rs` | What a restart restores, and what to do with packages that have gone |
| `recovery.rs` | When a recovery copy is written, cleaned and offered (pure, tested) |
| `loaderror.rs` | Load failures classified into kinds with advice (pure, tested) |
| `shortcuts.rs` | Every key binding, its macOS chord and its parity (pure, tested) |
| `parity.rs` | The macOS parameter table, the panel ranges taken from it (pure, tested) |
| `subject.rs` | Which subject extractor answers, and how that is said (pure, tested) |
| `ui/guides.rs` | The ruler, grid and guide drawing and their pointer gestures |
| `ui/tabs.rs` | The tab strip and the close prompt |
| `ui/color.rs` | The shared colour panel |
| `filters.rs` | The Filter menu: kinds, backends, parameter ranges and clamping (pure, tested) |
| `merge.rs` | Merge plans, subset compositing and the flatten command (pure, tested) |
| `watch.rs` | The external-change state machine: what counts as news (pure, tested) |
| `raw.rs` | Camera Raw editing state: source pixels, settings, preview (pure, tested) |
| `session.rs` | Editor: document, history, view, tools, masks, text, adjustments; every mutation |
| `worker.rs` | IO worker (open/save/export/import) and render worker (full and region), off the UI thread |
| `engine/` | Engine adapters: `flatten_document`/`flatten_region` (comp-render), `Stroke`, marquee and mask buffers (comp-brush) |
| `app.rs` | `GuiApp`: frame loop, worker pumping, texture upload, dialogs, text and filter sessions |
| `ui/` | Menus and shortcuts, toolbar, canvas, layers panel, text panel, adjustment and effect panels, Camera Raw window, status bar |

Everything except `ui/` and `app.rs` is free of window state and is unit tested without a display.
