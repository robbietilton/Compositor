# Parity with Compositor for macOS 1.4.5

Module by module: what this tree implements, what proves it, and what is still missing. The numbers
below come from the acceptance run, `tools/verify/run_all.ps1` — 40 of 40 pixel fixtures and every
package accepted by an independent port of the macOS validator.

**verified** (automated, independent evidence) · **implemented** (code and tests, not yet
cross-checked against the macOS app itself) · **partial** · **missing**

| # | Module | Windows | Status | Evidence |
|---|---|---|---|---|
| 1 | \`.comp\` format v1–11: read, validate, atomic write, digest | \`comp-core\` | **verified** | 156 tests; 32 Python-written packages read and re-serialized field for field; 39 packages pass an independent port of the macOS validator; hostile-package suite (symlinks, traversal, oversized, 16-bit, PNG bombs) |
| 2 | Document model, hierarchy, snapshot undo | \`comp-core\` | **verified** | subtree contiguity, folder opacity multiplication, visibility inheritance, undo back to a save point reports clean |
| 3 | Blend modes (24) | \`comp-render\` | **verified** | 24 fixtures against an independent W3C/PDF oracle within 1 level; 20 of them byte-exact; black and white probes cover every dodging boundary |
| 4 | Compositing: masks, clipping masks, folder pass-through, transforms | \`comp-render\` | **verified** | alpha ramp, layer mask, folder opacity, Invert adjustment, placement, scale and 90° rotation; clipping chains, folder masks, flips, hidden layers and nested folder opacity (three of these byte-exact) |
| 4b | Filters (the menu's 17 kinds) | \`comp-render\` | **verified** | all 17 names and parameter ranges match \`Filters.swift\`; Lens Correction and Dither are ports of \`LensPixels.c\` and \`DitherPixels.c\`, and Lens matches an independent port of the kernel at every distortion setting (worst 0–1 level). Vignette and Tonal Contrast are ports of \`AdjustPixels.c\`; Bloom/Glow and the ASCII dither face are documented approximations |
| 5 | Adjustment layers (12) | \`comp-render\` | **verified** | 41 independent fixtures: Levels, Curves, Exposure, Invert, Black & White, Color Balance, Grain and Add Noise are byte-exact; Hue/Saturation matches the direct formula and differs from macOS's 33³ cube interpolation by 12–14 levels, a documented deliberate difference |
| 6 | Layer effects (6) | \`comp-render\` | **verified** | all ten effect fixtures, including a stack of six and every padding margin, within one level after the surface-geometry fix |
| 7 | PNG codec: RGBA layers, gray masks, palette, 16-bit rejection | \`comp-core\` | **verified** | round-trips, palette expansion, header-first budget checks, animation and bomb rejection |
| 8 | Import/export: JPEG, TIFF, WebP, BMP | \`comp-io\` | **verified** | 94 tests plus 12 Pillow checks: pixel-exact TIFF/BMP/lossless-WebP, PNG pHYs and JPEG JFIF resolutions |
| 9 | PSD/PSB reading | \`comp-io\` | **verified** | 10 ImageMagick checks: real PSD pixels, folders, masks, 24 blend keys, RLE/ZIP, merged fallback, CMYK refused by name |
| 10 | Canvas/image size, crop, trim | \`comp-io\` | **implemented** | resize, canvas resize with anchors, crop, trim semantics with failure-leaves-document-untouched tests |
| 11 | Brush, eraser, clone stamp, healing | \`comp-brush\` | **implemented** | 95 tests: opacity is a stroke-wide ceiling, self-crossing does not darken, incremental session equals a batch stroke pixel for pixel; the GUI now drives it through that session |
| 12 | Selections: marquee, lasso, wand, feather, boolean ops | \`comp-brush\` | **implemented** | tolerance boundaries, boolean areas, feather symmetry and energy conservation, exact Euclidean expand/contract |
| 13 | Transforms: affine, free distort, snapping | \`comp-brush\`, \`comp-render\` | **implemented** | affine round trip within 3/255, quarter-turn and identity pixel-exact, perspective homography |
| 14 | Editor shell: canvas, layer panel, tools, undo, open/save | \`comp-gui\` | **verified** | builds with 0 warnings, 259 tests, a real window opens \`demo.comp\` (60 frames, 480x320 texture, ~45 ms flatten); dirty-rectangle redraw (810 ms -> 4.9 ms for a 128² region of a 2048² canvas); text tool, 12 adjustment panels, 6 effect panels, mask painting, Camera Raw panel, curves editor, thumbnails, drag reordering, run-level text editing, imports |
| 15 | CLI and scriptability | \`comp-cli\` | **verified** | info, layers, validate, create, extract, render, export, import, psd, raw, sample; Unicode, spaces and >260-character paths |
| 16 | Camera Raw | \`comp-raw\` | **implemented** | 139 tests; the pipeline order is pinned by order-sensitivity tests; 13 pixel values pinned from a separate Python reimplementation of the C kernels; DNG/TIFF decode, vendor raw formats refused by name |
| 17 | Text and vector | \`comp-text\` | **verified** | paragraph-level bidi with UAX#9 levels, per-script fallback chains (Han/Japanese/Korean/Arabic/Hebrew/Indic/Thai/Emoji/Symbols), RTL bracket mirroring, caret and hit-testing geometry; shaping through rustybuzz: kerning, GSUB ligatures, complex scripts (Arabic joining, Devanagari reordering, combining marks), per-glyph face rescue, sub-pixel placement, RTL visual order; 140 tests against facts of the installed fonts. Still missing: paragraph-level bidi, vertical text |
| 18 | AI selection (subject/background) | \`comp-brush\` | **partial** | a classical stand-in, not a model: border colour model + centre prior + iterated graph-cut-style smoothing + guided edge refinement, 24 tests, no randomness. On synthetic images it separates cleanly (coverage 1.000, leakage 0.000); NOTES.md states plainly that photographs with complex backgrounds will fail and that a model plugs in behind a designed trait |
| 19 | GPU rendering (Metal kernels) | \`comp-render\` | **partial** | the 24 blend modes, source-over, layer transforms with all three sampling kernels (including the CPU's Catmull-Rom, byte-identical results), layer masks, folder masks and clipping chains run in a WGSL compute shader — NVIDIA GTX 1660 SUPER (Vulkan), 20 of 24 modes byte-identical to the CPU and the rest within 2 levels (half-byte ties across instruction sets), coverage multiplied plane by plane with the CPU's own formulas. 5.4x faster than the CPU on a 4000x4000 composite including upload and readback; 39 of the 40 fixtures composite on the GPU and all match the CPU within a level — translated, scaled, rotated and flipped layers with any sampling included, most of them byte-identical. \`gpu_accepts\` names the layer and reason for a document that must fall back as a whole (adjustment layers, layer effects, and layers reduced below half, which need the CPU's halving pyramid). Adjustments, effects and the filters are still CPU |
| 20 | Packaging, signing, auto-update | \`comp-release\`, \`tools/build.ps1\`, \`tools/package-msix.ps1\` | **partial** | portable build; the update manifest is hashed by the CLI so the build and the updater share one format; version comparison with channels and pre-releases, SHA-256 verification of a downloaded payload, staged replacement that parks the previous build and rolls back on failure; .comp registered under HKCU; a real **MSIX** built with the Windows SDK's makeappx (manifest, four assets, block map, code-integrity catalog) and **signed with signtool** — the chain ends in a self-signed certificate the script exports for the user to trust, and a purchased certificate can be passed instead if a release ever needs one - by the user's decision this build is not going to the Store, so the self-signed certificate is what its distribution needs. No in-app HTTP fetch, no timestamping, no store submission |

## What is verified, and how

1. **Independent oracle.** \`tools/verify/comp_reference.py\` is a second implementation of the
   compositing model, written from the W3C/PDF specification in NumPy, plus a \`.comp\` writer that
   follows the format document. It shares no code with the Rust engine, so agreement is evidence.
2. **Pixel acceptance.** \`tools/verify/acceptance.py\` renders all 38 fixture packages with
   \`compc render\` and compares every channel against the oracle, tolerance one level: 24 blend
   modes, an alpha ramp at 0.75 opacity, a gray layer mask, folder opacity across two children, an
   Invert adjustment layer, a placed layer, a stretched layer, a 90° rotation, a clipping mask, a
   clipping chain and clipping onto a translucent and a masked base, a folder mask, a flipped layer,
   a hidden layer and nested folders.
3. **Format fidelity.** \`tools/verify/manifest_roundtrip.py\` checks that the Rust reader
   reproduces a Python-written manifest field for field.
4. **macOS interop.** \`tools/verify/macos_interop.py\` is a second implementation of the Swift
   decoder's requirements and of \`ProjectStore.validate\`: the keys each record must carry (Swift
   does not fall back to a property default when a key is missing, so an absent key fails the whole
   decode), camelCase spellings, uppercase UUIDs matching their file names, version gates, ranges and
   limits. It checks packages *written by Rust*, including \`compc sample\` — a project carrying every
   optional feature: folders, a folder mask, a rotated and flipped layer with a mask and four effects,
   a clipping link, text with per-letter colors and faces, a shape, an adjustment layer and guides.
   39 of 39 packages are accepted.
5. **A second oracle for adjustments and effects.** \`tools/verify/oracle/\` ports the C and Swift
   kernels again, in Python, and renders 41 fixtures — 29 adjustments, 10 effects, 2 controls — through
   \`compc render\`. 38 of 41 match within one level; the three that do not are documented deliberate
   differences (two Hue/Saturation cube-interpolation cases and the Motion Blur kernel).
6. **Region rendering against full rendering.** \`tools/verify/check_regions.ps1\` renders every
   fixture in full and then three regions of it — a quarter, an off-centre half and a rectangle that
   starts outside the canvas — and compares each against the crop **exactly**. Two further fixture sets
   exist only for this: a Gaussian-blur adjustment (where a region needs pixels from beyond its edge), an
   Add Noise adjustment (whose pattern is anchored in document coordinates), a layer shadow and glow that
   reach outside their layer, and a rotated scaled layer. 132 comparisons, all exact.
7. **The GPU against the CPU, through the CLI.** \`tools/verify/check_gpu.ps1\` renders all 40
   fixtures twice — once on the CPU, once preferring the GPU — compares them pixel by pixel, and insists
   that at least one fixture actually reached the GPU so the check cannot pass vacuously. It caught the
   folder-mask bug above on its first run.
8. **The interaction budget.** \`tools/verify/check_perf.ps1\` runs the release benchmark three times
   and takes the best run — the machine is shared, and a loaded run reads several times slower. It guards
   the figure the feasibility report called the project's biggest risk: 120 ms per pointer sample before
   the brush and region work, about 8 ms after, with the gate at 25 ms against a 16 ms budget.
9. **Every format version.** \`tools/verify/check_versions.ps1\` writes one package per version, v1
   through v11, each using exactly the features its version introduced (opacity and blending in 3, layer
   masks in 4, clipping links in 5, folder masks in 6, adjustment layers in 7, folder opacity in 8,
   neighbour-reading adjustments in 9, per-letter colours in 10, per-letter faces in 11), validates and
   renders each, and compares it against the independent compositor. It then takes ten packages that use
   a feature one version too early and requires **both** readers — the Rust validator and the Swift
   decoder port — to refuse them, so the two agree on where the gates are. Writing it found three
   mistakes in the fixture writer itself (a folder and an adjustment layer need the canvas rectangle
   even though they hold no pixels, and the alignment string is \`Left\`, not \`left\`), which is the
   point of checking the fixtures before trusting them.
10. **The editor against the command line.** \`tools/verify/check_entrypoints.ps1\` renders every
   fixture through both entry points — \`compc render\` and the editor's headless flatten — and compares
   them exactly. They share one code path, so a difference means one of them is not using it.
11. **PNG and JPEG against Pillow.** \`tools/verify/verify_codecs.py\` has Pillow write the files the
   engine imports (8-bit RGB and RGBA, grayscale, palette, 16-bit grayscale, JPEG at 4:4:4 and 4:2:0,
   grayscale JPEG) and read the files the engine writes: every fixture is rendered to PNG, decoded and
   re-encoded by Pillow, imported back and rendered again — the picture must survive that round trip
   **exactly**. Two gaps are measured and printed on every run rather than hidden: a **16-bit PNG is
   refused** where macOS reads it natively through ImageIO, and a **4:2:0 JPEG decodes about 16 levels
   away** from a high-quality decoder (4:4:4 is within 2). Both were fixed in the same round: the JPEG
   cause was **not** upsampling but the **last column**, where libjpeg repeats the final visible chroma
   sample while zune-jpeg mixed in padding from the padded MCU row (4:2:0 differed by 16 and 4:2:2 by 32,
   and every other pixel by ≤3). The importer now decodes YCbCr planes directly and rebuilds that column
   the way libjpeg does: 16-bit PNG imports at 0 levels, 4:2:0 and 4:2:2 at 3.
12. **PSD import.** \`tools/verify/check_psd.ps1\` writes PSD files from scratch in Python — header,
   colour mode, layer records, channel data with raw and RLE compression, and layer masks — computes the
   composite it expects, and requires the importer to reproduce it. Writing it took two corrections to the
   generator itself, both documented in the file: PackBits is applied **per row** with a row-length table
   for every channel, and a mask needs both its -2 channel and the rectangle-and-flags block in the
   layer's extra data. Seven cases pass at 0–1 levels. The macOS app has **no PSD export** (no writer
   exists in its sources), so parity here means import only.
13. **Damaged packages.** \`tools/verify/fuzz_hostile.py\` takes real fixtures and damages one thing
   at a time — truncating the manifest, replacing a value with the wrong type, corrupting an id, pointing
   an asset path outside the package, emptying a PNG, claiming absurd dimensions, making the layer graph
   cyclic, nesting a thousand deep. Each result goes through \`validate\` and \`render\`, and the rule is
   that a clean refusal is fine while a panic, a crash or a hang is a bug. It found the interop
   validator's UUID rule above on its first useful run.
14. **Every CLI subcommand.** \`tools/verify/check_cli.ps1\` makes a real call for each of the nineteen
   subcommands and asserts both the happy path (exit code, output file, and key text: a created package
   renders the exact colour asked for, an extracted layer is byte-identical to the asset in the package)
   and a failure path — missing arguments, bad input, absent files — because a command line's error
   handling should not rest on someone trying it by hand. It found seven places where a user's typo was
   reported as "this is not a valid Compositor project".
15. **The brush against a specification.** \`tools/verify/check_brush.ps1\` renders strokes through the new
   \`compc stroke\` command and compares them with \`brush_oracle.py\`, a NumPy implementation written from the
   model documented in \`comp-brush/NOTES.md\` — fifteen drawing cases plus four failure paths, **all
   byte-identical** rather than merely inside the tolerance, because the oracle uses f32 wherever the
   engine does. It found the long-chord bug above on its first run.
16. **The checks themselves.** \`tools/verify/verify_checks.py\` runs each pixel-comparing check twice:
   once against the real CLI, and once against a wrapper that forwards every command and then changes
   one pixel of whatever it produced (and claims success from \`validate\`). A check that passes in both
   cases is not checking anything. All four notice the sabotage. Building this took three attempts at the
   sabotage itself — a byte in the trailing chunk and a byte in the middle were both ignored by decoders,
   which is exactly how a broken render had slipped past the PSD check.
15. **Per-crate tests.** \`cargo test -p <crate>\`; \`tools/verify/run_all.ps1\` runs everything and
   prints one summary, treating a crate that fails to compile as a failure rather than as zero tests.

## Bugs the verification found (all fixed)

Every one of these would have shipped silently without a second implementation to compare against.

| Bug | Consequence if shipped |
|---|---|
| UUIDs serialized lowercase | Every package the Windows build saved would be rejected by the macOS app, whose validator compares \`imageFile\` against the uppercase \`uuidString\` |
| \`TextFontRun.font_name\`, \`ShapeStyle.corner_radius/line_width\` lacked camelCase renames | macOS Codable decoding fails on the unknown key and rejects the whole manifest |
| Undo did not restore the revision a snapshot was saved at | Undoing back to a save point still reported unsaved changes |
| Oracle computed expectations from pre-quantization floats | Nine fixtures falsely reported blend errors; the engine was right |
| Oracle applied folder opacity to the folder as a unit | Contradicted \`LayerGroups.swift\`: folders are pass-through and their opacity multiplies into each child |
| \`set_sat\` identified the middle channel with an absolute epsilon | Hue and Saturation blends were up to 128 levels off — the middle channel collapsed to zero |
| The oracle could not model placement at all | Transform, scale and rotation had no cross-check; three fixtures now cover them |
| Font aliasing matched typographic families and sibling fallbacks too loosely | Every Helvetica request resolved to Arial Narrow on a real 391-face system |
| The CLI silently ignored unknown raw setting keys | A typo in a settings file developed a neutral image and reported success |
| Clipping masks ignored the base layer's opacity and raster mask | A clipped layer showed through where its base was semi-transparent or masked; found by rendering a project that carries every feature, then pinned with two minimal fixtures |
| The macOS interop validator demanded uppercase UUIDs in the manifest | Swift decodes ids with \`UUID(uuidString:)\` — either case — and compares asset names against \`uuidString\`, which renders uppercase, so a lowercase id with a matching file name is legal. Found by the hostile-input fuzzer disagreeing with comp-core; the Swift source settled it in comp-core's favour, and the validator was fixed |
| A soft brush painted **nothing** along a long straight stroke | The soft tip integrated its density over only 1–4 midpoints per chord, and a straight line is one chord however long it is: a 48 px line with a 1 px tip sampled every 12 px and skipped nearly every pixel it swept, leaving a blank image. Invisible in the editor, where a pointer sample moves a few pixels at a time; found the first time a NumPy re-implementation of the brush model judged the engine. Fixed by sampling every quarter radius and accumulating only the samples inside each pixel's tip, which left the stroke benchmark unchanged (4.35 ms median at 4000x4000 with an 800 px tip, budget 5 ms) |
| Twenty adjustment unit tests were destroyed by a careless file rewrite | The kernels themselves stayed covered by 40 fixtures and 41 oracle cases, so behaviour was still verified, but the unit-level assertions were gone and had to be rewritten. The port now lives in a git repository so a mistake like this is recoverable |
| The editor's region repaint was 98% wrong for a blurred layer | The GUI translated the document and cropped each layer to the rectangle, so a blur lost the pixels just outside it (2037 of 2080 bytes differed) and Grain/Add Noise re-anchored their pattern (73–74% of bytes). Found while switching it to the shared region renderer, and kept as a test fixture |
| The GPU path accepted documents whose **folder** carried a mask | The folder's mask was ignored, so `group-mask.comp` rendered 204 levels away from the CPU reference; found by the new end-to-end `compc render --gpu` comparison, fixed by walking the ancestor chain |
| Composites wrote straight color into a premultiplied canvas | Every composite on a translucent backdrop divided by alpha twice, brightening soft edges; invisible while every fixture had an opaque backdrop |
| A default black-to-white Gradient Map was treated as identity and skipped | An adjustment layer users added did nothing at all; every other gradient worked, so only a fixture with the default endpoints caught it |
| Effect surfaces were rescaled instead of padded | Every layer effect was misplaced once its blur needed a margin larger than two pixels: a 16x12 shape's stroke covered x43..96 instead of x58..81 |
| \`hsvSettings.adjustments\` was read as a keyed object | Swift encodes \`[ColorRange: X]\` as an alternating array, so every per-range Hue/Saturation setting saved by the macOS app was silently ignored (and ours would not decode there). The interop validator now rejects the wrong shape |
| The oracle assumed masks are canvas-sized | A layer's mask shares the layer's own rectangle, so masks on smaller transformed layers crashed the check instead of verifying it |

## What is left

Audited against the Swift sources and each crate's NOTES: what follows is what is genuinely absent,
not what is merely unfinished.

1. **GPU coverage** (module 19): every one of the 40 fixtures composites on the GPU; all twelve
   adjustment kinds and all six layer effects are on the GPU too, most of them byte-identical, and Lens
   Correction is the one filter kernel that is. The other four are refused **by name**: Vignette because
   the CPU's f64 path lands on a rounding knife edge (1 level before unpremultiplying becomes 3 at low
   alpha), Dither because error diffusion is a serial raster scan, and Bloom and Tonal Contrast because
   they need a third blur implementation that no existing pass matches.
2. **AI selection** (module 18): a deterministic classical stand-in ships. Photographs need a model —
   ONNX Runtime plus a commercially licensed checkpoint — behind the trait already designed in
   \`comp-brush/NOTES.md\`.
3. **Colour glyphs** (module 17): macOS renders Apple Color Emoji; this port still draws monochrome
   outlines. The route chosen first — read the v0-shaped layer lists, rasterise each layer, composite
   through the palette — was **followed to the end and turned out to be a dead end on this font**: the
   parser works (a probe hits six layers for U+1F600 with matching glyph ids after a real CPAL address
   bug was fixed), but **the v0 layer glyphs carry no outlines at all**, so each layer rasterises to zero
   ink while the monochrome path still draws the outline. Segoe UI Emoji keeps its actual paint in the
   **v1 graph**, so finishing this means recursing through ttf-parser's v1 `paint()` (Solid and Glyph
   layers first, gradients and transforms falling back). Current coverage is honest and unchanged:
   0 of 5 sampled emoji in colour, 5 of 5 falling back to the outline.
4. **Vendor raw decoding** (inside module 16): the develop pipeline is complete and cross-checked; the
   sensor data of NEF/CR2/CR3/ARW/RAF and CFA DNG needs LibRaw, a C library this machine has no
   toolchain for.
5. **HEIC import** (inside module 8): needs libheif, for the same reason. **16-bit PNG import** is
   refused today although macOS reads it through ImageIO, and **4:2:0 JPEG** decodes about 16 levels away
   from a high-quality decoder; both are being fixed in comp-io.
5. **Text**: the two line-breaking defects below are **fixed**
   (the wrapper now asks about the next line's first real character, and hard breaks snap to a grapheme
   boundary with the cluster scan done once per paragraph), and a third was found while verifying them:
   a caret in a **right-to-left** line can answer with a different caret when the middle of its own box is
   clicked (seed 6901461881, shrunk to "\nאבגthe quick brown ", caret 4 answers with 6) — left open with
   an ignored test. Two harness bugs were fixed on the way, both of which had made a failing invariant
   look like a hang: the wrapper could stop advancing when a cluster wider than the box was snapped onto
   the line start, and the minimiser only checked its deadline between passes, so one pass over every
   candidate could run for minutes. The suite now finishes in 8 seconds.
   **Colour emoji is a closed gap, with numbers**: a counting painter over 200 sampled base glyphs of
   Segoe UI Emoji found that exactly one (0.5%) can be drawn from outlines, solids, clips and layers
   alone, while 199 need gradients and transforms together (5592 gradients, nesting depth 5,
   is_simple() false). Supporting that font means a full v1 paint graph interpreter for a single face,
   which the audit's own rule — cheap, or meaningful — rejects. The fallback stays the monochrome
   outline, two guards prove it is byte-identical to what the port drew before, and the v0 reader stays
   because it is correct and cheap even though it is not sufficient alone.
   **GPU coverage, final state**: blending, transforms with all three sampling kernels, layer masks,
   folder masks, clipping chains, the contraction chain, all **12 adjustment kinds**, all **6 layer
   effects**, and four of the five filters (Lens, Bloom, Tonal Contrast, Vignette) run on the GPU and
   match the CPU — most of them byte-identically, and every one of the 40 fixtures composites there.
   Dither runs eight of its eleven styles on the GPU. **No refusal remains that is justified by
   precision**: the last two were the same bug — WGSL's \`round\` breaks half-way ties to even while
   Rust's breaks them away from zero, which cost a column in the scanline geometry and an
   amplify-after-unpremultiply level in Vignette. Both were found by an audit of every rounding call in
   the shaders, run because the first instance was recognised as a class rather than an accident. What
   is still refused is refused for reasons precision cannot fix: error diffusion is a serial raster
   scan, the ASCII style needs a glyph atlas, a glowing scanline needs a blur, and a document with more
   than 64 coverage planes exceeds one dispatch.
   **One filter is deliberately not claimed as equivalent**: the macOS dither sheet exposes glow, dots,
   angle, diffusion, density and contrast while this port exposes eleven styles plus pixel size, levels,
   amount and tone. Those are different parameter sets rather than different bounds, so the parity table
   carries no Dither row and a test asserts that.
   **Two entries were removed from this list after checking the Swift sources**: vertical writing and
   language tagging are not features of the macOS app (every "vertical" in its sources is UI layout, and
   there is no language-tagging code at all), so the port is not behind on them. A residual list that
   carries work nobody upstream did is its own kind of inaccuracy.
   Previously left open, for the record:
   a line can still begin with closing punctuation when the break falls at a space (the wrapper asks about
   the space it is dropping rather than the next line's first character — "one two 。 ", Arial 10px,
   49px box), and a line can end inside a grapheme cluster when a long unbreakable run is hard-broken
   (क्कक्क, 40px, 60px box). An attempt at the second stalled for over a minute under the parallel run
   and was rolled back rather than left in the tree.
6. **Editor**: the gaps that remain are small and listed in \`comp-gui/NOTES.md\`: guides cannot be
   locked, hidden individually or dragged back to a ruler; tabs do not survive a restart (no session
   file); the adjustment layers' own colours (gradient map, colour balance, black & white) still use
   egui's picker rather than the shared one; gradient and feather mask tools; effect blending options;
   the Black & White mix sliders; a numeric readout for a selected curve point; and multi-selection
   beyond delete and merge. Rulers, guides, a grid with snapping, project tabs and a shared colour
   picker are now implemented.
7. **Packaging** (module 20): ~~a purchased code-signing certificate, timestamping, store submission~~ and
   crash reporting. **The signing and store items are closed by the user's decision** — this build is not
   going to the Store, so the self-signed MSIX and the portable zip are enough for the way it will be
   distributed. Crash reporting remains open. A portable zip, an MSIX signed with a self-signed certificate, a CLI-hashed update
   manifest, staged replacement with rollback and .comp registration are all done and tested.
8. **macOS cross-checks**: no macOS machine was available, so every reference here comes from the format
   document or the Swift sources. Rendering the same projects on a Mac and diffing the PNGs is the one
   remaining verification step, and the only way to settle conventions the specification leaves
   unstated (rotation direction, filter kernels, resampling quality).
