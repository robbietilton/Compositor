# comp-brush — implementation notes

Painting, selection and transform engines for Compositor for Windows. Pure CPU, no UI types:
every public input and output is a `comp-core` `Bitmap8` (straight-alpha RGBA), `Gray8`
(coverage) or `Document`. Behavior is ported from the macOS app, which stays the spec.

## Files

| File | Contents |
|---|---|
| `src/brush.rs` | `Brush` (size, hardness, spacing, flow, opacity, smoothing, erase), `BrushEngine`, `StrokeSession` (incremental painting), `dab_bounds`, coverage accumulation, spline, dab placement, `coverage_mask` |
| `src/clone.rs` | `CloneState` (source, aligned/unaligned offset), `clone_stamp`, `spot_heal`, `content_fill` |
| `src/wand.rs` | `WandSettings`/`WandSampleSize`, `magic_wand`, `color_range`, `trace_outline` |
| `src/selection.rs` | `Selection` over `Gray8`: rect/ellipse/lasso rasterization, feather, expand/contract, boolean ops, load from alpha/mask, clip/crop/fill/clear |
| `src/subject.rs` | `SubjectOptions`, `select_subject`, `select_background`, `remove_background`, `refine_edges` (classical substitute for Vision) |
| `src/transform.rs` | `sample`/`sample_mask`, `transform_bitmap`/`transform_mask`, `resample_bitmap`/`resample_mask`, `warp_perspective`, snapping (`SnapTargets`, `snap_offset`, `snap_point`, `LayoutGrid`) |

`cargo test -p comp-brush` runs 95 unit tests.

## Algorithm notes (why, not just what)

### Brush coverage and the opacity cap
The whole stroke accumulates *coverage* in its own buffer; the paint is composited through that
coverage once, at `opacity`. Because the color is applied once, a stroke that crosses itself can
never darken past the cap — the macOS rule ("Caps the whole stroke, as in Photoshop: overlapping
dabs never exceed it", `BrushSettings.opacity`).

- Soft tips (`hardness < 1`) accumulate **optical density**: each dab adds
  `-ln(1 - tipWeight)` and coverage is `1 - exp(-min(density, 20))`. That is the closed form of
  source-over dabs at the deposition spacing, so coverage depends on the distance travelled rather
  than on how many pointer events arrived (`docs/brush-performance.md`, `MetalBrushCoverage.swift`).
  A self-crossing therefore lands exactly on source-over of its two arms, and its coverage caps
  at 1 rather than growing without bound.
- Hard tips (`hardness >= 1`) keep the antialiased silhouette from
  `brushCoverage = clamp((radius - d) / 1px + 0.5, 0, 1)` and take the **maximum** over the dabs
  that cover a pixel, exactly like the kernel's `max(permanent, coverage)` and the software
  fallback's `.lighten` blend.
- `flow` is the per-dab deposit strength (Photoshop's flow). macOS has no flow control and always
  deposits a full dab; `flow = 1` reproduces it exactly.
- Spacing defaults to the macOS fractions (1.5% of the diameter for hard tips, 2.5% for soft ones)
  and the leftover distance carries across corners, so a corner does not restart the rhythm.
- Pointer samples are smoothed with the string model (the tip trails the pointer on a string
  `smoothing` screen points long, converted to document pixels by the zoom), threaded through a
  centripetal Catmull-Rom spline subdivided to within 0.2 px, then stamped.
- Erasing takes coverage out of alpha and leaves the straight color alone, so a later edit restores
  the pixel's color instead of a black fringe.
- Coverage is accumulated over the stroke's own bounding box, never a full-canvas buffer, and the
  stroke reports the dirty rectangle it touched.

### Clone Stamp, Spot Healing, content-aware fill
- `CloneState` mirrors `CloneStamp.swift`: a new source clears the alignment, an aligned stroke
  keeps the first stroke's whole-pixel offset, an unaligned one runs from the brush to the source
  every time, and the crosshair point is the source itself until a stroke fixes the offset.
- `spot_heal` is a direct port of `Rendering/HealPixels.c`: coverage bounds, square-dilated ring,
  Content-Aware/Proximity-Match patch search over 24 angles x 5 distances with a ±3 px refinement,
  the membrane difference, the multigrid Gauss-Seidel solve (omega 1.8, 300 -> 40 iterations) and
  the grain that Create Texture adds back. One deviation: the C kernel writes into a premultiplied
  CGContext and clamps color to alpha; ours is a straight-alpha buffer, so color clamps to 0-255.
- `content_fill` is a port of `Rendering/ContentFill.c` (patch match with propagated offsets,
  randomized donor search and a 64 -> 1 halving refinement). It returns `false` when the image has
  no opaque unselected pixels to copy from.

### Wand and Color Range
- `magic_wand` follows `Rendering/WandPixels.c`: per-channel inclusive tolerance (0 selects only
  the exact color, 255 selects everything), the reference color is the rounded box average around
  the click (Point / 3x3 / 5x5), and contiguous mode is the same scanline flood fill over
  4-connected neighbors. A click outside the image returns an empty mask.
- `color_range` unpremultiplies before comparing (`(c * 255 + a/2) / a`), matches include minus
  exclude within one fuzziness, and never matches fully transparent pixels.
- `trace_outline` returns the pixel-edge boundary loops (clockwise, turning right at corners where
  two loops meet) that a marching-ants overlay draws. It refuses masks past the macOS 8M-edge
  limit with `Error::TooLarge`.

### Selection
A selection is a document-resolution `Gray8` coverage mask (white selected). Unlike the macOS
DocumentSelection, which keeps a vector path, the raster is the source of truth here: it carries
antialiased and feathered edges directly and clips painting without any path machinery.
- Rectangle/ellipse/lasso rasterize with exact horizontal coverage and 4 sub-scanlines per row; the
  fill rule is nonzero winding, as Core Graphics' `.winding`. With antialiasing off, coverage
  snaps at half a pixel.
- Boolean ops are coverage ops: union = max, intersect = min, difference = `a * (255 - b) / 255`.
  Replace/Add/Subtract/Intersect are all available through `SelectionOp`.
- Feather blurs with sigma = radius / 2 (the macOS `CIGaussianBlur(sigma: feather / 2)`), a
  normalized separable kernel with clamped edges, so a uniform field stays exactly uniform and the
  total coverage is preserved.
- Expand/contract use an exact Euclidean distance transform (Felzenszwalb-Huttenlocher) with a
  one-pixel antialiased ramp placed exactly on the new outline, so expanding by N grows the
  selection by N pixels and contracting by N removes N.
- `Selection::transformed` resamples the mask through an affine map and keeps the canvas size, so
  a moved selection still lines up with the document.
- Selections load from a layer's alpha (`from_alpha`) or any mask (`from_mask`/`from_gray`), and
  clip, crop, fill or clear pixels at document resolution.

### Transforms and snapping
- Sampling is premultiplied (a transparent neighbor never darkens a color edge) and follows the
  rule that a point inside the image clamps to the edge pixel while a point outside it is
  transparent — so upscaling does not eat a half-transparent border out of an opaque image, and a
  rotated layer fades to nothing instead of smearing its edge. `Nearest`, `Smooth` (bilinear) and
  `HighQuality` (Catmull-Rom bicubic) are implemented.
- `transform_bitmap`/`transform_mask` size their output to the mapped source's whole-pixel bounds
  (a rotation grows the rectangle rather than clipping corners); `resample_bitmap`/`resample_mask`
  map into a fixed-size frame, which is what a layer needs when its pixels move but the canvas does
  not. Output rows are independent and run on rayon.
- `warp_perspective` ports `DistortWarp`: the unit-square homography for a convex quad, and two
  affine triangles along the diagonal for a folded one (which no perspective can express).
- Snapping ports `TransformSnap` and `Guides`: canvas edges (+ centers on request), document
  guides, layout-grid lines and every layer's bounds; each axis independently, smallest move wins,
  ties keep the earlier target, and nothing moves outside the tolerance.

## Incremental strokes (what the GUI paints with)

`StrokeSession` feeds a stroke one pointer sample at a time, which is how a canvas paints live
without repainting the whole path on every mouse move:

    let mut session = engine.begin_stroke(start)?;      // or StrokeSession::begin(&brush, start)
    let update = session.extend(&mut layer, point);     // repaint update.bounds
    let last = session.finish(&mut layer);

`extend` returns a `StrokeOutcome` whose `bounds` and `changed` describe **that call alone** - the
pixels a GUI repaints - while `dab_count` and `path_length_milli` are cumulative for the stroke.
`session.bounds()` gives the union over the whole stroke, which is the rectangle an undo entry
wants. `dab_bounds(brush, at)` is the footprint of a single dab, for a hover preview or a click.

The pixels are identical to one batch `stroke` over the same path: `an_incremental_stroke_matches_a_batch_stroke_exactly`
covers straight runs, sharp corners and a self-crossing, five brush configurations (hard, soft,
reduced opacity, reduced flow, an eraser, plus a non-default spacing), two smoothing settings and a
30-sample jittery path, and asserts the pixels, the dab count and the path length. Two rules make
that hold:

1. **Coverage is kept, not re-stamped.** The session owns the stroke's density/coverage buffer and
   the dab placement state (previous dab, leftover spacing), so `extend` lays only the dabs that are
   new. A pixel is never composited twice, so a stroke that crosses itself cannot darken.
2. **Nothing is composited from the pixels it wrote.** The session keeps the target's pixels as they
   were when the stroke began and rebuilds each dirty pixel as `base + color x coverage x opacity`,
   which is what the batch path does in one pass.

The path is split the way the macOS engine splits `permanent` and `preview`. A spline segment needs
the sample *after* its end, and the newest pointer sample can still move, so segments are folded
into the permanent buffer only once their control points are fixed; the one or two segments still in
flux live in a separate tail buffer that is dropped and laid again from its saved dab state on the
next `extend`. The buffers combine exactly as the Metal kernel's do: densities add for soft tips,
silhouettes take the maximum for hard ones. `finish` promotes the tail; the tail a finished stroke
holds is already the curve the batch version draws for those segments (the last segment clamps its
"after" control point to its own end), so finishing changes no pixel - and a click that never moved
still lands its single dab.

Deviations and costs worth knowing:

- **`finish(self, target)` takes the target.** The agreed sketch was `finish(self)`, but a stroke
  that never extended (mouse down, mouse up) has its dab still to lay and it has to reach a bitmap.
  Everything else matches the agreed signature; `finish_clipped(self, target, selection)` sits next
  to `extend_clipped` for selection-limited painting.
- **`begin` is infallible and records the error.** `StrokeSession::begin(&brush, start)` keeps the
  agreed `-> Self` signature; an out-of-range brush is reported by `session.error()` and the session
  then paints nothing. `BrushEngine::begin_stroke(start)` validates up front and returns a `Result`,
  which is the entry point a GUI should use.
- **A session's buffer covers the stroke's own bounds**, at 12 bytes per pixel there (permanent
  density, tail density, base pixels). A full-canvas stroke on a 4K document reserves about 190 MB;
  ordinary strokes reserve a fraction of that, and the batch `stroke` path stays at 4 bytes per pixel.
- **Only solid-color strokes are incremental.** Clone Stamp and Spot Healing still run through the
  batch `clone_stamp` / `spot_heal` entry points.

## Subject and background extraction (a classical substitute for Vision)

The macOS app asks Vision for a foreground instance mask
(`VNGenerateForegroundInstanceMaskRequest`, `Document/SubjectRemoval.swift`). Windows has no
equivalent and this build ships no model, so `src/subject.rs` implements the feature classically.
It is **not** a segmentation model and does not pretend to be one: read the quality section below
before promising anything about a photograph.

Pipeline (all of it deterministic - no random sampling, no hash-map ordering, every loop in raster
order, so identical pixels always give identical bytes):

1. **Trimap seeding.** The outer `border_fraction` of the image and every transparent pixel are
   certain background; the center of the frame, minus what already looks like background, is the
   first subject model. Both are quantized color histograms with Laplace smoothing (half a count
   over the colors the region actually uses), which is GrabCut's seeding idea with histograms
   instead of Gaussian mixtures - reproducible beats slightly more accurate here.
2. **Data terms and the center prior.** `D_subject = -ln P(color | subject) + prior * (1 - center)`
   and `D_background = -ln P(color | background) + prior * center`, with a smooth elliptical
   `center` field (1 in the middle, about 0.1 at the corners) and the costs clamped at `ln(1e-6)`.
   The prior is what keeps a uniform image, and a subject that shares its color with the background,
   from collapsing to nothing.
3. **Iterated refinement.** Both models are re-estimated from the current labeling, then the
   labeling is re-solved by iterated conditional modes (Besag 1986) on
   `sum D(l_p) + sum lambda w_pq [l_p != l_q]` with GrabCut's contrast-sensitive weights
   `w_pq = exp(-beta |I_p - I_q|^2)` and `beta` estimated from the image's own mean neighbour
   contrast. ICM is the deterministic cousin of GrabCut's graph cut: same energy, local minimum,
   no max-flow. A straight boundary is already a local minimum of the smoothness term, which is why
   extra sweeps change nothing once the corners are settled.
4. **Cleanup.** 8-connected subject components smaller than `min_component_fraction` of the largest
   are dropped, and background pockets closed off from the frame and smaller than the same share of
   the subject are filled (a deliberate hole in the subject survives).
5. **Edge refinement.** `refine_edges` is a guided filter (He, Sun & Tang 2010) with the image's
   luminance as the guide, ported line for line from the app's `Document/GuidedMatte.swift`
   including its `epsilon = 1e-4` and its two-running-sum box means. This is the same "Refine
   Edges" the macOS panel offers, so a future model's mask gets the same treatment. The effective
   radius is capped at an eighth of the shorter side: a window wider than that averages the matte
   into flat gray. Afterwards the certain background is put back, so a window near the frame cannot
   lift subject back into the band the trimap ruled out.

### Parameters

| Field | Range | Default | Meaning |
|---|---|---|---|
| `border_fraction` | 0.01-0.25 | 0.08 | Share of the shorter side taken as certain background |
| `color_bins` | 2-32 | 8 | Histogram bins per channel |
| `center_prior` | 0-4 | 1.2 | Weight of the center prior (0 disables it) |
| `iterations` | 0-12 | 4 | Model re-estimation + ICM sweeps |
| `smoothing` | 0-8 | 1.0 | Boundary penalty `lambda` |
| `min_component_fraction` | 0-1 | 0.02 | Specks and pinholes below this share of the largest are dropped |
| `edge_radius` | 0-64 px | 1.5 | Guided-filter radius; below 0.5 px the matte stays hard |

Every value is clamped into range by `SubjectOptions::clamped()`, so no combination panics or
divides by zero. There is deliberately **no seed field**: the pipeline contains no randomness at
all, which is a stronger guarantee than a fixed seed.

### Measured on the synthetic cases the tests build

| Case | Subject coverage (inner 70% of the disc) | Background leakage (outside 1.25 r) |
|---|---|---|
| Flat background, saturated disc, 96 px | 1.000 | 0.000 |
| Speckled background (deterministic ±12 levels) | 1.000 | 0.000 |
| Horizontal gradient background | 1.000 | 0.000 |
| Two-tone background | 1.000 | 0.000 |

Those numbers are perfect because the synthetic cases are perfectly separable. They are a
correctness check on the pipeline, not an accuracy claim about photographs.

### Quality against Vision - what this is not

- Vision's request is a **trained instance segmentation model**. It knows what a person, an animal
  or a product looks like, follows hair and fur, and separates several instances. This module knows
  only color, position and edges. On a photograph with a busy background it will **fail**, and the
  failure mode is visible: either a ragged edge that follows color patches, or the center prior's
  blob when the background and subject colors overlap.
- It cannot separate two subjects from each other, cannot rank instances, and has no notion of
  "the person in front". `select_subject` returns one matte.
- The border band is background by construction, so a subject running off the frame loses its
  border pixels (tested: the interior is still selected).
- A subject that shares its color with the background is decided by the center prior alone, which
  returns a centered blob rather than the subject's outline (tested and documented).
- Low-contrast subjects (a gray object on a gray wall) and heavy texture are the other known
  failure modes. There is no semantic knowledge anywhere in the pipeline.
- What it does give: a deterministic, dependency-free, testable matte that is good enough for
  cutouts of clearly separated subjects (product shots, logos, flat or gradient backdrops), and a
  solid fallback before a model is wired in.

### Interface for a future model

The module is shaped so a model can be dropped in behind the same API without touching the rest of
the app:

1. **One entry point per outcome.** A model only has to produce what `select_subject` produces: a
   document-resolution `Gray8` matte. The GUI's actions (`select_background`, `remove_background`,
   `refine_edges`) are already model-independent and should be reused unchanged.
2. **A trait for the model, not a dependency for the crate.** `comp-brush` stays model-free; the
   model lives in the app layer:
   ```rust
   pub trait SubjectModel {
       /// The model's own matte, or None when it declines (no subject found, unsupported image).
       fn matte(&self, image: &Bitmap8) -> Option<Gray8>;
   }
   ```
   A future `select_subject_with(model: Option<&dyn SubjectModel>, image, options)` would call the
   model first and fall back to `select_subject` when it is absent or returns `None`, so the feature
   never regresses to "nothing happens".
3. **Run the model's mask through the same finishing steps.** The certain-background constraint, the
   component and hole cleanup and `refine_edges` all apply to a model's output as well; Vision's own
   mask in the macOS app is refined exactly that way.
4. **Where the model would live on Windows.** An ONNX Runtime or DirectML session behind a feature
   flag in the app layer, loaded lazily, with the model file next to the executable; `comp-brush`
   keeps taking plain buffers. If the runtime is missing, the classical path above is the fallback.

## Incremental stroke performance

The painter's budget is the delay between a pointer sample and the canvas showing it. The macOS
app records 2.6-3.1 ms per pointer update on a 4000x4000 canvas with an 800 px brush
(`docs/brush-performance.md`). `compc bench` measured this crate at **85.07 ms** median for the
same shape of stroke, so the cost was rewritten to follow the area a stroke actually sweeps.

### What was slow

| Stage | Share before | Why |
|---|---|---|
| Coverage accumulation | ~70% of a call | Every dab stamped its whole tip: an 800 px tip is ~640k pixels, a 60 px pointer step lays three dabs, and the provisional tail was re-stamped too - six passes per sample, each with an `exp` and a `sqrt` per pixel |
| Base rebuild (composite) | ~20% | Single threaded, an `exp` per pixel for density-to-coverage, a division per pixel in source-over, and it walked the whole dirty rectangle |
| Buffer growth | spikes to 55 ms | The stroke's single bounding box was reallocated and copied whenever the stroke grew past its margin - copies of up to 190 MB on a 4K canvas |

### What changed

1. **Discrete dabs became swept segments.** The path is flattened into chords (0.5 px tolerance,
   `CHORD_TOLERANCE`) and each chord is deposited once: a soft tip integrates its optical density
   along the segment and divides by the deposition spacing, a hard tip takes its antialiased
   silhouette at the nearest point of the segment. That is the macOS Metal kernel's continuous
   model, and it is both more correct (no ridges, coverage independent of the pointer event rate)
   and an order of magnitude less work: one pass over the swept capsule instead of one pass per dab.
2. **A profile table.** `ProfileLut` samples the soft falloff as optical density over squared
   distance, so a deposited pixel costs a table read instead of an `exp` and a `sqrt`. Hard tips
   keep the exact arithmetic - their rim is one pixel wide and a table would quantize it. The
   quadrature (1-4 midpoint samples) is worked out once per segment, not once per pixel.
3. **Rows in parallel.** Deposition and compositing both split the target's rows with rayon. Each
   pixel is written by exactly one row task and the segment passes stay sequential, so the result
   stays bit-for-bit deterministic whatever the thread count.
4. **A shared coverage table.** `1 - exp(-density)` is a 4096-entry table the batch and the session
   both read, so the two paths cannot disagree and neither pays an `exp` per pixel.
5. **An opaque fast path** in `composite_pixel`: opaque paint over an opaque pixel keeps full alpha,
   so source-over reduces to a lerp and the division drops out. The arithmetic is the same one, so
   the pixels do not depend on which branch ran.
6. **Tiled stroke buffers.** A stroke's permanent density, provisional tail and base pixels live in
   tiles allocated the first time paint reaches them (edge = `max(shorter side / 8, 2 x tip
   reach)`, clamped to 64-512 px). Growing a stroke therefore never copies a buffer, memory follows
   the painted area, and the per-sample cost follows the swept area: no bounding-box term is left.
   The provisional tail keeps its own tile buffer, which is what `finish` promotes.

`StrokeSession::timing()` returns a `StrokeTiming` with `deposit_ns`, `composite_ns`,
`reserve_ns` (tile allocation) and `calls`, for a benchmark or a diagnostics overlay.

### Measured (release)

Run with `cargo test --release -p comp-brush -- --ignored --nocapture bench_incremental_stroke`.
It mirrors `compc bench --canvas N --brush M --samples S`: hardness 0.6, opacity 1.0, one `extend`
per sample, timing only the `extend` call.

| Canvas / brush | Before (median) | After (median, quiet run) | After (range over runs) | Target |
|---|---|---|---|---|
| 2000 x 2000 / 400 px | 16.45 ms | **0.80 ms** | 0.80 - 2.76 ms | < 3 ms |
| 4000 x 4000 / 800 px | 85.07 ms | **2.84 ms** | 2.84 - 8.01 ms | < 5 ms |

Split, per sample, from the quiet run: 4000x800 - deposit 1.78 ms (14% of it tile allocation),
composite 1.54 ms; 2000x400 - deposit 0.63 ms, composite 0.45 ms. The swept area is 24.4 Mpx over
40 samples and 9.1 Mpx over 60 samples, roughly 610k and 150k pixels per sample - the numbers to
compare against if this ever regresses.

The range is real and worth stating: these runs share the machine with other builds, and a loaded
machine pushed the same binary to 8 ms median with a 55 ms worst sample. On an otherwise idle
machine the figures sit at the low end, which is where the macOS figures (2.6-3.1 ms) also sit.

### Guarantees that survive the speedup

- `an_incremental_stroke_matches_a_batch_stroke_exactly` still compares a session against one batch
  `stroke` pixel for pixel, over five brush configurations, two smoothing settings and two paths
  (one with straight runs, sharp corners and a self-crossing), and compares the deposition counts
  and path lengths too. The batch and the session share `deposit_segment`, `composite_pixel` and the
  coverage table, so they cannot drift apart.
- `StrokeOutcome::dab_count` now counts **deposition stamps**: one per swept segment, and one for a
  click that never moved. It is no longer a count of discrete dabs, because there are none; the
  field keeps its name for the GUI's sake and this note is the contract.

### Not done here

- `BrushEngine::stroke` (the batch path) still deposits every segment over its own capsule, so a
  stroke with hundreds of samples costs O(samples x capsule). That is fine for tests, for
  `coverage_mask` and for Clone Stamp, but a GUI should paint through a session. A tile-major batch
  (one pass per tile over every segment, like the Metal kernel) would fix it if it ever matters.
- The composite half of `compc bench` (`flatten_document` / `flatten_region`) is comp-render's
  cost, not this crate's.

## The brush model, as a specification

Until task-73 every brush check compared the engine with itself: an incremental stroke against a
batch one, two call shapes over the same pixels. The semantics - what a tip is, how much paint a
pixel gains while the tip sweeps past it, how that becomes coverage - were only ever the engine's
own word. This is the model written down, and `tools/verify/brush_oracle.py` recomputes it in NumPy,
so a run of `tools/verify/check_brush.ps1` judges the engine by something that was not written from
the Rust code: 19 cases at a tolerance of one level per channel, all of them `worst 0`.

`compc stroke` is the entry point: it paints one path onto a canvas and writes a PNG, with the same
flags the oracle takes, so a check hands the same list to both.

1. **The path.** Control points as given. `compc stroke` paints with smoothing 0, which is the
   identity; the editor's smoothing is `smooth_path`, which only ever moves a point along the line
   to the pointer and so cannot change the model below. Each consecutive pair of samples becomes one
   centripetal Catmull-Rom piece, flattened until the polyline stays within `CHORD_TOLERANCE` (0.5 px)
   of the curve or ten bisections have been spent. Each chord of that polyline is a deposition
   segment; a single click is one zero-length segment.
2. **Deposition** into the stroke's buffer, one pixel at a time at pixel centres `(x + 0.5, y + 0.5)`,
   walking the segments in path order:
   - *Soft tip* (`hardness < 1`): the optical density is integrated along the segment and divided by
     the deposition spacing `spacing_pixels()` - `spacing x diameter` (1.5% of it for a hard tip, 2.5%
     otherwise) floored at `MIN_SPACING_PIXELS` (0.25 px). The integral is a midpoint rule whose
     samples are at most a quarter of the tip's radius apart, and a pixel reads only the samples
     within the tip of it (the rest read zero from the table), so a pixel costs a fixed handful of
     reads however long the chord is. Dividing by the spacing is what makes paint depend on the
     distance travelled rather than on how the path happened to be sampled.
   - *Hard tip* (`hardness >= 1`): the antialiased silhouette at the nearest point of the segment,
     clamped over the segment's ends, kept with `max`: the same coverage as stamping every dab,
     without stamping them.
   - *Profile*: `tip_weight(d)` is 1 inside `hardness x radius` and falls to the rim as
     `(exp(-2.5 t^2) - exp(-2.5)) / (1 - exp(-2.5))` with `t = (d / radius - hardness) / (1 - hardness)`;
     a hard tip's rim is one pixel of antialiasing, `clamp((radius - d) + 0.5, 0, 1)`. Density is
     `-ln(max(1 - weight, 0.001))`, so densities add where coverage composes. Reach is `size / 2 + 1`.
   - *Tables*: a soft tip reads density from 1024 entries over squared distance to the reach, linearly
     interpolated in `f32`, zero past it. The stroke's buffers are `f32` and the quadrature sums in
     `f32`, which is why the oracle keeps those values in `float32` rather than `float64`.
3. **Coverage.** Soft: `1 - exp(-min(density, 20))` through a 4096-entry table over 0..20, interpolated
   in `float64` with `f32` endpoints. Hard: the strongest silhouette, clamped to 0..1.
4. **Paint.** `alpha = coverage x opacity`, then source-over with straight alpha over the pixel the
   target held before the stroke. The opaque-over-opaque fast path is the same arithmetic with the
   alpha that falls out of the general formula equal to 1, so the oracle mirrors both.
5. **Determinism.** Rows are deposited in parallel, but every pixel is written by exactly one row task
   and the segments are walked in path order, so the result does not depend on the thread count - which
   is what makes a comparison with another implementation possible at all.

### What the oracle found

A **quadrature that under-sampled a long chord**. The rule used to be 1..4 midpoint samples over the
whole segment. A straight line is a single chord however long it is, so a 48 px line with a 1 px tip
got four samples 12 px apart and the integral missed almost every pixel: the stroke came out empty,
and with a smaller tip dotted. Pointer-driven painting hid it, because a hand moves a few pixels
between samples and the chords stay short. The samples now follow the tip's radius, which is correct
and no slower where the old rule was already right: the 4000x4000 / 800 px benchmark is unchanged at
4.35 ms median. Minimal reproduction:
`compc stroke out.png --width 64 --height 32 --brush 1 --hardness 0.5 --path line --from 8,16 --to 56,16`
painted nothing; `a_long_chord_paints_every_pixel_the_tip_swept` pins it, and
`a_long_chord_matches_the_same_path_in_small_steps` keeps the two samplings of one path close.

Two smaller findings were in the harness rather than the engine: `compc stroke` refused negative
values such as `--start-deg -40` (clap read them as options), and the oracle's argparse did the same,
so `check_brush.ps1` passes those two flags as `--from=-10,32`.

### Outside the oracle's scope

- `smooth_path` (the pointer string) and the session's permanent/provisional split are the crate's own
  tests' subject; the first cannot change the model, the second is the equivalence test.
- Erasing, Clone Stamp and selection-clipped painting are comp-brush behaviors these five steps do not
  describe, and `check_brush.ps1` paints a solid colour on an opaque or a translucent canvas.

## Subject extraction with a real model (subject_model.rs)

The classical extractor in `subject.rs` decides from colour statistics. It has no model file, no
licence to carry and no download, and it cannot know what a person looks like. `subject_model.rs`
adds the other half: a small salient-object network run through **tract** (pure Rust ONNX
inference, MIT OR Apache-2.0, no C toolchain, no runtime to ship), answering with the same
contract as the classical path - a `Gray8` matte at the image's resolution.

### The model

| | |
|---|---|
| Weights | U-2-Netp, the lightweight U-2-Net of `xuebinqin/U-2-Net` |
| Licence | Apache-2.0 (code and weights), the same family as this crate's dependencies |
| ONNX export | `https://huggingface.co/BritishWerewolf/U-2-Netp/resolve/main/onnx/model.onnx` (Apache-2.0 model card) |
| Size | 4,574,861 bytes (4.36 MB) |
| SHA-256 | `309C8469258DDA742793DCE0EBEA8E6DD393174F89934733ECC8B14C76F4DDD8` |
| Input | `input.1`, float32 `[1, 3, 320, 320]` (NCHW, 0-1, ImageNet mean/std) |
| Outputs | 7 (the six side outputs then `d0`); the fused one, the last, is what this build reads |

It is **not committed**: `crates/comp-brush/models/.gitignore` keeps `*.onnx` out of the tree. A
checkout that wants the model downloads that URL into `crates/comp-brush/models/u2netp.onnx`;
any other build points `COMPOSITOR_SUBJECT_MODEL` at a file. Both are optional, and the tests that
need it skip with a printed reason when it is not there.

### Pre- and post-processing

- **In** (`input_tensor`): the image is squashed to 320x320 with bilinear sampling at pixel
  centres, RGB in 0-1, then `(value - mean) / std` per channel with ImageNet's statistics, laid out
  NCHW. Squashing rather than letterboxing keeps the resize and its inverse exact inverses of each
  other, which is what every published U-2-Net demo does.
- **Out** (`mask_from_map`): the network's map is not a probability - it is unbounded, and its
  *relative* values are the answer - so it is scaled by its own minimum and maximum to 0-1, then
  sampled bilinearly back to the canvas. A map with no range (a constant) or with no finite value
  answers with a flat matte rather than a division by zero or a NaN cast to white.
- Then the same edge pass the classical matte gets (`refine_edges` with `edge_radius`), so a caller
  cannot tell the two backends apart by anything but the pixels.

### Fallback

`select_subject_with(image, options, model)` is the entry point. Every one of these answers with the
classical extractor, which is what a build without a model has always done:

- no model file in any of the three places (`COMPOSITOR_SUBJECT_MODEL`, `models/` beside the
  executable, `models/` beside this crate),
- a file that is not an ONNX graph this build can read, or a graph that will not optimize or run,
- an output that is not a float map,
- any failure while running it.

Passing `None` as the model is byte for byte the old behaviour; a test asserts exactly that.

### Measured, this checkout, 96x96 synthetic frames

Coverage is the share of true subject pixels above the half threshold, leakage the share of true
background pixels above it. Lower leakage at the same coverage is a better cut-out.

| Frame | Model coverage | Model leakage | Classical coverage | Classical leakage |
|---|---|---|---|---|
| a bright square on a dark field | 0.997 | 0.000 | 1.000 | 0.000 |
| a warm subject on a cool field | 1.000 | 0.000 | 1.000 | 0.000 |
| a disc on a gradient | 0.958 | 0.055 | 0.958 | 0.055 |
| **a subject in the corner** | **0.997** | **0.000** | 1.000 | **0.164** |
| a subject almost its background's colour | 0.998 | 0.000 | 1.000 | 0.000 |

The corner case is the one that shows what the model is for: the classical extractor's centre prior
assumes the subject is in the middle, so a subject in the corner leaks 16% of the background, while
the network leaks none. The two mattes differ by 1,900-3,300 pixels on every frame, so this is the
model answering and not a silent fallback. On easy synthetic shapes both backends are already near
perfect, which is the honest reading: these are not photographs, and a real-model quality claim
needs real photos, which this checkout does not have.

### Not covered here

- **Photographic evidence.** The numbers above are synthetic shapes. Real portraits and busy
  backgrounds are the models' home ground and this repository has no photographs to test on.
- **Matting quality.** U-2-Net gives a coarse mask; MODNet (Apache-2.0, 24.69 MB, also on Hugging
  Face) is the portrait-matting model and would give better hair. The backend takes any model with
  one image input and a float map output, but only u2netp has been run here.
- **Speed.** tract's optimized plan on this machine is roughly 1-2 s per 320x320 inference in a
  debug build. The release numbers, the input side that meets the preview budget and the background
  job the editor should use are in the next section.
- A canvas with an extreme aspect gets a squashed input, which is what the published demo does and
  is measurable only on photographs.

### Making the model usable for a preview (task-79)

**Release, 1024x768 canvas, one warm-up then five runs, this machine (6 cores / 12 threads):**

| Input side | Threads | Plan load | Inference median (min-max) | End to end median |
|---|---|---|---|---|
| 320 (the export's own) | 1 | 119 ms | 355 ms (343-366) | 393 ms |
| 320 | 12 | 105 ms | 343 ms (340-371) | 392 ms |
| 288 | 12 | 105 ms | 293 ms (279-315) | 325 ms |
| **256 (the preview default)** | 12 | 104 ms | **228 ms** (221-234) | **248 ms** |
| 224 | 12 | 101 ms | 161 ms (161-163) | 200 ms |
| 320, low threading thresholds | 12 | - | 341 ms | - |
| classical extractor, for reference | - | - | - | 110 ms |

**The 300 ms target is met at an input side of 256 and below, and not at the model's own 320.**
U-2-Net is fully convolutional, so a smaller square is a valid input and the matte is stretched
back to the canvas either way; `PREVIEW_SIDE = 256` is what `cached_discovered` loads, and
`load_at_side` / `cached_at_side` are there for a caller that wants the full 320 for a final pass.
The cost of the coarser input is a coarser matte, which is not measured here (there are no
photographs in this checkout) and is the first thing to look at with real ones.

**Threading buys almost nothing, honestly reported.** 355 ms to 343 ms at 320 (about 3%), and
lowering tract's threading thresholds changes nothing (341 ms). The graph is a stack of many small
convolutions, so there is no single large matmul for the threads to split; the feature is enabled
(`tract-linalg/multithread-mm`) and an executor with `default_threads()` is installed on the first
load, because it costs nothing and helps a little, but the win here is the input side, not the
cores. `use_threads(n)` sets it, `default_threads()` reports the default, and a test asserts the
matte does not depend on the count (it differs by at most a level or two, because parallel sums
add in a different order).

**The plan is cached.** `SubjectModel::cached_at_side(path, side)` keeps the optimized plan in a
process-wide slot keyed by path and side, and re-loads only when the file's length or modification
time changed - which is what makes dropping a new export over the old one take effect. The 100 ms
load is therefore paid once, not per slider release, and `load_count()` reports how many times it
has happened. `cached_discovered()` is the whole thing in one call: locate, cache, load, or nil.

**Nothing blocks the caller.** `SubjectJob::start(image, options, model)` runs the cut-out on a
worker thread and returns at once; `poll()` answers `None` until the matte is ready and
`Some(Result<Gray8, Error>)` once, `wait()` blocks for a script or a test. `SubjectPreview::start`
is the shape the editor wants: it returns the classical matte immediately (110 ms on a 1 MP canvas,
2-4x faster than the model at 320) plus a job carrying the model's, so the canvas shows something
at once and swaps when the better matte lands. Jobs are numbered by `generation()`: a caller that
starts one per keystroke keeps the newest answer and ignores the rest. Dropping a job does not
interrupt its thread - Rust has no safe way to stop a running closure - it discards the answer and
returns immediately, which a test asserts.

One robustness fix came out of these tests: a NaN or infinity in the network's output map used to
spread through every pixel that interpolated it. A non-finite sample is now read as background
(0), so a model that misbehaves produces a wrong matte rather than a white one.

**Not done:** quantization. The obvious candidates are MODNet's quantized export (6.32 MB,
Apache-2.0) and an int8 u2netp, and neither was taken on: MODNet wants a 512x512 input, which is
larger than the 320 that is already too slow, and tract's quantized-kernel coverage would have to
be checked op by op before the numbers meant anything. With the input side at 256 the target is
already met, so quantization is now a quality question (a smaller file) rather than a speed one.

## Known gaps (not implemented in this pass)

- **Smudge, Blur and Liquify (warp) strokes** (`Document/SmudgeLiquify.swift`, `BlurTool.swift`,
  `Document/Distort.swift` beyond the four-corner warp). The brush coverage machinery is ready for
  them (a stroke that paints a sampled image already exists as `clone_stamp`), but the push/smear
  kernels themselves are not ported.
- **Object selection** (`ObjectSelection.swift`) and **subject removal** (`SubjectRemoval.swift`):
  these need model-assisted matting, which is out of scope for a pure CPU engine.
- **Guided matte / refine edge**, **mask tracing to a vector path** (`MaskTracing.swift`) and
  **selection clipboard paste into a new layer** (`SelectionClipboard.swift`).
- **Gradient and shape fills** (`Gradient.swift`, `ShapeTool.swift`): they build on the same
  `BrushStroke` fill path, but rendering gradients belongs in `comp-render`.
- **Airbrush-style flow accumulation across separate strokes**: like macOS, the cap is per stroke;
  a second stroke can deepen the same pixels.
- **GPU/Metal parity**: this is the CPU implementation. The stroke buffer is a full-stroke
  density/coverage raster over the stroke's bounds; the macOS tiled snapshot (256 px tiles, shared
  unchanged tiles, immutable `RasterSnapshot`) is a caller concern here, not part of this crate.
- **Layer-bounds snapping for rotated layers** uses `Transform::document_bounds()` (an
  axis-aligned box). macOS snaps to the four corners of the displayed quad; the axis-aligned box is
  what the frozen comp-core API exposes.

## API notes

- `magic_wand` takes a `WandSettings` rather than loose arguments, matching the options bar
  (tolerance, sample size, contiguous). `WandSettings::new(tolerance)` is the two-argument form.
- Spot Healing is exported as `spot_heal` (the C kernel's name) and `content_fill` for the
  content-aware fill used by larger selections.
- `BrushEngine::stroke_clipped` takes the selection explicitly instead of owning it, so a
  canvas-sized mask is never copied into the engine.
- Errors reuse `comp_core::Error`: `TooLarge` for settings or surfaces past the macOS limits,
  `Invalid` for degenerate transforms or non-finite input, and `BufferSize` for a mask that does
  not match the image it is applied to.
