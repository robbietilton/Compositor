# comp-render: the CPU compositing engine

This crate holds everything that turns a `comp_core::Document` into pixels: the 24 blend modes, the 12
adjustment layers, the 6 layer effects, the 17 Filter-menu kinds, transform sampling, the downsample cache
pipeline that puts them together.

## Entry points

| Function | Use |
|---|---|
| `flatten_document(&Document) -> Bitmap8` | The whole document, canvas-sized, straight-alpha RGBA8. Never fails: an empty, pixel-less or fully hidden document comes back fully transparent. |
| `flatten_layer(&Document, Uuid) -> Option<Bitmap8>` | One layer on its own, with its mask, opacity, effects, clipping link and folder masks, over nothing. |
| `layer_bounds(&Document, Uuid) -> Option<(i64, i64, u32, u32)>` | The document rectangle a layer's pixels land in, for an editor that redraws lazily. |
| `Surface`, `Plane`, `Filter` | The premultiplied working buffers and the resampling filters, if a caller needs to composite by hand. |
| `effects::margin(&LayerEffects) -> u32` | How far a layer's effects reach, so a caller can grow a dirty rectangle. |
| `apply_filter(&Bitmap8, FilterKind, &FilterSettings)` | One of the 17 Filter-menu kinds, straight-alpha in and out. |
| `apply_filter_surface(&mut Surface, ...)` | The same on the premultiplied surface the kernels work in. |
| `blur_margin(FilterKind, &FilterSettings)` | How far a filter reaches past the layer, so a caller can pad it first. |
| `composite_gpu(&Bitmap8, &Bitmap8, BlendMode, f64)` | The same composite on the GPU, or `None` when there is no backend. |
| `flatten_document_preferring_gpu(&Document)` | The document on the GPU where it fits, on the CPU everywhere else. |

## How it composites

The order is the macOS original's (`EditorCanvas.gpuLayers`, `LiveMaskRenderer`), because that is what
the fixtures and the app agree on:

1. Layers composite bottom to top, skipping hidden ones and anything inside a hidden folder.
2. A folder is pass-through: it never blends on its own, and its opacity is multiplied into each of its
   children (macOS `LayerGroups.swift:49-52`).
3. Each layer's alpha carries its opacity (its own times every enclosing folder's), its own mask and
   every folder mask above it.
4. A layer that names a clipping base has its alpha multiplied by that base's **coverage**: the base's
   placed pixels, times the base's raster mask, times the base's *effective* opacity (its own and every
   enclosing folder's), and then by the coverage of whatever clips the base in turn. Only coverage
   counts: a hidden base still shapes what is clipped to it, and its color and blend mode never do
   (`LiveMaskRenderer.swift`: "Coverage uses source alpha including its own masks, independent of
   source visibility and color"). Folder masks stay out of the coverage, because the clipped layer and
   its base share the same folders and the clipped layer already gets them.
5. An adjustment layer re-colors everything below it inside its folder, through its own mask and its
   folders' masks at its opacity; in a blend mode it blends at full coverage and restores the original
   coverage afterwards, so soft edges are not thickened.

Pixels are premultiplied 8-bit RGBA throughout, exactly like the original's Core Graphics contexts and
its C kernels: a channel is divided by its alpha before a lookup and multiplied back after. Straight
alpha only exists at the crate's edges, where `Bitmap8` is.

## The Hue/Saturation record on disk

`Adjustment.hsvSettings` is a Swift `HueSaturationSettings`, whose two maps are `[ColorRange: X]`.
A Swift dictionary whose key is not `String` or `Int` encodes as an **unkeyed container** - key,
value, key, value - so macOS writes:

```json
"hsvSettings": {
  "range": "Reds", "colorize": false, "invertRange": false,
  "adjustments": ["Reds", {"hue": 60, "saturation": -40, "lightness": 20}],
  "bands": ["Reds", {"falloffStart": 315, "rangeStart": 345, "rangeEnd": 15, "falloffEnd": 45}]
}
```

Reading accepts that array and the object shape (`{"Reds": {...}}`) an earlier build of ours could
write; writing always produces the array, because only that decodes on macOS. `HsvSettings` in
`adjustment.rs` owns both directions (`from_json` / `to_json`), so they cannot drift apart, and
`tools/verify/macos_interop.py` rejects a package whose `adjustments` is not an array. Nothing in
this crate serializes a manifest: a caller that fills in `Adjustment::hsv_settings` - a panel, an
importer - has to go through `HsvSettings::to_json`, since `comp-core` stores the field verbatim.

## The Filter menu

`filters.rs` carries all seventeen kinds macOS lists, so a menu can be built from `FilterKind::ALL` and a
caller can run any of them with `apply_filter(&Bitmap8, FilterKind, &FilterSettings)` (or
`apply_filter_surface` on a premultiplied `Surface`). `FilterSettings` is camelCase serde, mirrors the
Swift record's fields and ranges, and `normalized()` clamps every value the panel would; nothing
out-of-range reaches a kernel. `blur_margin` reports how far a kind reaches past the layer so a caller can
pad it first.

| Kind | Where the kernel comes from |
|---|---|
| Gaussian Blur, Motion Blur, Add Noise | the adjustment kernels in this crate |
| Curves, Exposure, Gradient Map, Grain, Black & White, Color Balance | the adjustment kernels in this crate |
| Vignette | `adjust_colored_vignette` in `AdjustPixels.c`, ported |
| Tonal Contrast | `adjust_tonal_contrast` in `AdjustPixels.c`, ported (its blur is this crate's Gaussian) |
| Dither | `DitherPixels.c`, ported, all eleven looks |
| Lens Correction | `LensPixels.c`, ported |
| Bloom / Glow | **an approximation** of `CIBloom`, see below |
| Camera Raw Filter, Remove Background, Content-Aware Fill | not here: `FilterError::Unsupported` |

The three unsupported kinds return a typed error rather than a wrong picture: Camera Raw lives in
`comp-raw`, Content-Aware Fill in `comp-brush`, and Remove Background needs a subject model this build
does not ship.

### The ported kernels

- **Dither** is `dither_apply` kernel for kernel: the tone planes (luminance, or one per channel in
  Original), `adjust_tone` with density as `2^(density * 1.5)` and contrast about mid gray, Atkinson
  (six taps over a divisor of eight) and Floyd-Steinberg (four taps over sixteen) diffused in serpentine
  order, the Bayer 2/4/8 ordered screens, halftone dots, lines and diamonds by their coverage shapes, the
  seventeen Mac patterns, ASCII and the CRT scanlines with their wobble, dots and glow. Two details are
  this crate's own, both recorded here: ASCII's characters come from a small built-in 5x7 bitmap font
  rather than CoreText (macOS lays them out with the system font and reads their ink coverage back, which
  needs a text stack), and the chunky-pixel average-down is a box average rather than Core Graphics'
  high-quality draw. Everything else is the C code.
- **Lens Correction** is `lens_distort`: the radial scale `1 - k * r^2 / halfDiagonal^2` with
  `k = distortion / 100 * 0.35`, sampled bilinearly with everything outside the image contributing
  nothing - which is why shrinking fades the corners.
- **Vignette** is `adjust_colored_vignette` with its `vignette_mask_at` falloff (square to circle by
  Roundness, Midpoint where the falloff starts, Feather for its width) and its Highlights protection of
  bright pixels.
- **Tonal Contrast** is `adjust_tonal_contrast`: local detail from a blurred copy, weighted by how dark
  the local tone is, with the untouched blur coming from this crate's Gaussian.

### Bloom / Glow is an approximation

macOS runs Core Image's `CIBloom(radius:intensity:)`, whose kernel Apple does not document, so this port
cannot be exact and does not pretend to be. What it does instead, in `filters.rs::bloom`:

1. take the pixels above a knee of 0.6 luminance, scaled by how far above it they sit, so a bloom only
   ever adds light to highlights;
2. blur that with a Gaussian of `radius / 2` (the same convention the adjustment blurs use);
3. add it back over the original at `intensity = bloomAmount / 50`, clamped to the pixel's own alpha.

The result is a highlights-only bloom that fades with distance and never leaves the alpha, which is what
the filter is for; it is not bit-compatible with Core Image.
## The GPU backend

`gpu.rs` runs the 24 blend modes on a wgpu compute shader; `blend.wgsl` is that shader. The CPU remains the
default and the reference: the GPU is an accelerator for one step of the pipeline, and every result is
checked against the CPU. On this machine (NVIDIA GeForce GTX 1660 SUPER) the backend reports
`NVIDIA GeForce GTX 1660 SUPER (Vulkan)` through wgpu 30.

| Entry point | Use |
|---|---|
| `gpu::available()` / `gpu::describe()` | Whether this machine has a usable backend, and what it runs on. |
| `gpu::composite_gpu(&Bitmap8, &Bitmap8, BlendMode, f64) -> Option<Bitmap8>` | One composite, straight alpha in and out. |
| `gpu::flatten_document_gpu(&Document) -> Option<Bitmap8>` | A whole document, when all of it maps onto the shader. |
| `gpu::flatten_document_preferring_gpu(&Document) -> Bitmap8` | That, or the CPU when it does not. |
| `gpu::gpu_accepts(&Document) -> Result<(), String>` | Whether the shader can take a document, and which layer it refuses when it cannot. |
| `gpu::unavailability()` / `GpuBackend::last_error()` | Why a backend is missing, or why a composite fell back. |

### Falling back, and never half way

Nothing here panics when a machine has no adapter: `GpuBackend::new` reports `None` and the caller keeps to
the CPU. Shader and pipeline creation run inside a wgpu validation error scope, so a driver that rejects the
shader is a reported failure rather than a crash, and the composite itself runs inside another, so a
validation error at dispatch time returns `None` too. `unavailability` says which it was - `no adapter`,
`no device` or `the blend shader was rejected` - and the tests insist on the difference: a missing GPU is
a skip, a rejected shader is a failure. That check exists because a shader that failed to parse once made
every GPU test pass by skipping.

`flatten_document_gpu` takes a document when every part of it maps onto the shader: visible raster layers
in any blend mode, opacity, mask, clipping chain or transform, sampled and composited on the GPU. It reports
`None` for a document with an adjustment layer, a layer effect, or a layer reduced below half, so a caller
falls back for the whole image rather than mixing two compositors in one picture. `gpu_accepts` answers the
same question without rendering and names the layer it refuses, which is what a coverage report needs.

### Masks and clipping coverage

A layer's mask, its folders' masks and its clipping coverage do not stop it reaching the GPU: they travel as
*coverage planes* - a canvas-sized byte per pixel each, packed four to a word into one storage buffer - which
the shader multiplies into the layer's alpha before it blends.

The planes arrive in the order the CPU multiplies them, and the shader applies each one with
`Surface::mask_by_plane`'s own arithmetic `(a * m + 127) / 255`, carrying the premultiplied colors along by
the same ratio, then scales by the opacity exactly as `Surface::scale_alpha` does. So the multiplication
happens on the GPU, in the CPU's order, with the CPU's rounding - not a folded approximation of it.

The clipping coverage is the CPU's own `clip_coverage` rule read on the alpha channel alone, which is all a
coverage plane is: the base's pixels' alpha - placed through the base's own transform - times the base's
raster mask, times its effective opacity, and then whatever clips the base in turn. A chain that loops back
on itself, a base whose transform lands nowhere, or more than four planes above one layer sends the whole
document to the CPU.

### Placement

A layer that does not fill the canvas is sampled from its own image on the GPU. The host hands the shader the
same affine `place_surface` uses, its inverse, the filter `sampling_filter` picked, and the destination box,
and the shader does the rest: the inverse maps a canvas pixel's centre back into the layer's pixels, the
coverage that softens a scaled or turned edge is the CPU's own arithmetic (the product of the two axes'
overlaps when the transform does not turn, and the destination pixel's quad clipped against the source
rectangle when it does), and the taps are premultiplied before they are weighted, because the CPU samples a
premultiplied surface.

All three filters are there, including **High quality**: the shader carries the same Catmull-Rom weights
`pixel.rs` does, so a high quality enlargement or turn does not fall back, and does not settle for bilinear
either. Measured on 64 x 64 patterns against the CPU, every placement case agrees **exactly** - an integer
offset, a 2x enlargement, a half-size reduction, a flip, a quarter turn, a 15 degree turn in both Smooth and
High quality, and an enlargement in both. Masks and clipping keep working through a transform, because their
coverage planes are placed by the CPU's own `place_coverage`.

The one placement the shader cannot do is a layer reduced **below half**: the CPU halves such a layer before
sampling it, which is what keeps a large reduction sharp, and the shader has only the full-size image. Those
documents, like an adjustment layer and a layer effect, are refused whole with a reason that names the layer
and says which of the three it is.

Measured against the CPU on the 40 fixtures in `tools/verify/fixtures`: **all 40 composite on the GPU**
(29 before coverage planes, 35 before placements, 39 before adjustment layers), every one of them within a
level. Individually, on 64 x 64 patterns
(reproduce with the report `report_gpu_fidelity`): a masked layer, a masked folder, a three-layer clipping
chain, a mask of 0 or 255, and every placement case agree **exactly**, and two layers with different masks
differ by at most one level - which is the composite's own rounding at a semi-transparent pixel, not the
coverage: the coverage multiplies happen in the CPU's order, with the CPU's arithmetic.

### What the shader reproduces, and where it cannot

Both buffers are straight RGBA8, one `u32` per pixel. The shader mirrors `blend::composite_texel_mode` step
for step: the blend function on sRGB-encoded values, the same alpha algebra, the same quantization to a
premultiplied byte and the same unpremultiply back out. It even reproduces the *inputs* the CPU sees - the
byte a premultiplied surface holds for a straight color, and the second rounding `Surface::scale_alpha`
applies - because the point of an accelerator is that switching backends does not move pixels. The
expressions keep the CPU's order (`(c - l) * l / d`, not `(c - l) * (l / d)`) for the same reason.

Measured per mode on a 64 x 64 pattern (reproduce with `bench::report_gpu_mode_fidelity`): twenty modes
agree exactly on opaque input, and the worst difference anywhere is two levels, in three of the four
component modes.

| Difference | Modes |
|---|---|
| 0 on every input tried | Normal, Darken, Multiply, Color Burn, Linear Burn, Lighten, Screen, Linear Dodge, Overlay, Soft Light, Hard Light, Vivid Light, Linear Light, Pin Light, Hard Mix, Difference, Exclusion, Subtract, Color |
| 1 on some inputs | Color Dodge, Divide, Hue |
| 2 on some inputs | Saturation, Color, Luminosity |

The two-level cases are not a formula difference: the composite's own premultiplied value lands exactly on a
half byte, and the CPU and the GPU round that tie the way their own float expressions came out. The test
`every_mode_matches_the_cpu_through_alpha_and_opacity` does not widen its tolerance for this: it recomputes
the value in f64 and allows the extra level *only* within `1e-4` of a half byte, and fails on any other
pixel past one level. A last-bit difference between two instruction sets is not fixable; everything that
was fixable was fixed.

### Benchmarks

`cargo test --release -p comp-render --lib bench::benchmark_gpu_against_cpu_4000x4000 -- --ignored --nocapture`,
Multiply at 0.75, with a worst channel difference of 0 at every size. The GPU figure is the whole round trip:
two uploads, the dispatch and the readback.

| Canvas | CPU | GPU (with readback) | Speedup |
|---|---|---|---|
| 16 x 16 | 0.000036 s | 0.000301 s | 0.1x |
| 64 x 64 | 0.000143 s | 0.000161 s | 0.9x |
| 256 x 256 | 0.001117 s | 0.000284 s | 3.9x |
| 1024 x 1024 | 0.014075 s | 0.002106 s | 6.7x |
| 4000 x 4000 | 0.211330 s | 0.038859 s | 5.4x |

A canvas under about a hundred pixels a side loses: the fixed cost of creating the buffers and the round trip
outweighs the arithmetic there. That is why the CPU stays the default for previews and the GPU is worth
reaching for on an export.

### Adjustment layers

An adjustment layer runs as a pass of its own over the canvas: the kernel, then - when the layer carries a
blend mode - the adjusted colors blended with what was under them at full coverage, shown only where the
canvas had coverage, and then the layer's coverage (its mask, its folders' masks and its effective opacity as
one plane) mixed back in. That is `adjust_into`, step for step.

**Eleven of the twelve kinds run on the GPU**: Invert, Levels, Curves, Exposure, Gradient map, Black & white,
Color balance, Hue/saturation, Grain and Add noise. Levels, Curves and Exposure do not reimplement their curves
in WGSL: this module's own table builders fill the 256-entry tables and the shader interpolates between
neighbouring entries exactly as `apply_tables` does, so a lookup cannot drift from the one the CPU runs. Grain
and Add noise carry their seeds and stay anchored to the document, so a pattern matches a whole-canvas render
wherever it is asked for.

Hue/saturation carries the CPU's per-degree band response - 361 entries of hue, saturation and lightness,
built by this module - and applies it with the same HSL conversion, the same saturation slider and the same
sector table. Two things had to match exactly rather than nearly, and each was worth a whole image: the sector
table's **zero arm**, which left to the default took the last arm's channel order and swapped green with blue,
and the response's saturation, which is already a percentage and must not be scaled twice.

Checked against the CPU on 24 x 18 graded canvases, every kind agrees exactly - including a semi-transparent
canvas, a masked adjustment, a half-opacity one, one in a blend mode, one inside a masked folder, a chain of
three, and hue/saturation both as a rotation and as a colorize.

**All twelve kinds run on the GPU.** The two blurs are passes rather than kernels, because they read their
neighbours: the canvas is premultiplied into a surface - what the CPU's blurs read - then the Gaussian runs its
horizontal and vertical passes with the CPU's own normalized weights (`taps = ceil(sigma * 3)`, taps outside
the canvas skipped so the blur spreads into transparency, and a rounding to bytes between the two axes), and the
motion blur walks its even streak through the CPU's transparent bilinear read. Both end with the same tail as
every other adjustment: the layer's blend mode, then its coverage.

What a blur has to get right is the distance the two sides can drift over: the rounding between the axes, taps
that fall off the canvas rather than clamping at its edge, and an angle that counts counterclockwise with y up
while the buffer counts y down. Checked against the CPU on 24 x 18 canvases: every radius tried (0.4 through 8,
including one small enough to blur nothing), every angle tried (across, down, diagonal and fractional, with
streaks from one step to twelve), a semi-transparent canvas, a masked half-opacity blur in a blend mode, a blur
inside a masked folder, and a chain of blur, invert and blur - all agree exactly.

### Reduced layers

A layer reduced below half samples a halved chain rather than the layer: `place::reduced_for_gpu` runs the
CPU's own `DownsampleCache` reduction - each step averaging 2 x 2 blocks, which is what keeps a large reduction
sharp - and hands the shader that image, the scale its coordinates take, and the layer's full rectangle for the
coverage. A 64 pixel layer shown in 16 is therefore reduced twice on both sides, and agrees exactly.

### Not on the GPU yet

Every adjustment layer kind, every placement, every mask and every layer effect composites on the GPU.

**Coverage planes are folded one at a time, up to 64 of them.** A mask, a clipping link and every masked
folder above a layer each contribute a plane, and the shader walks them in the CPU's own order, rounding at
each step exactly as the CPU's `mask_by_plane` and `scale_alpha` do - which is why the count is only a bound
on what one dispatch reads, not a correctness limit. It used to be four, and a layer under five masked
folders was refused outright; now a 64-plane document - 63 masked folders and the layer's own mask - agrees
with the CPU, and the refusal only starts one plane past that ("Crowded: more than 64 masks and clipping
links above it"). Measured at six, nine, seventeen and sixty-four planes, on a region render as well as
whole, and with masks and a clipping chain mixed in one document.

### The filter kernels

The five filters that are not adjustment layers run through `GpuBackend::filter_image`, which premultiplies
the image, runs one kernel, and straightens it again - the same three steps `filters::apply_filter` takes.

- **Lens correction is on the GPU and agrees with the CPU exactly**, measured pixel for pixel at distortions
  from -60 to 70. It is a per-pixel resample: the same radial scale, the same bilinear gather with everything
  outside the frame transparent, and the same rounding to a byte.
- **The vignette is on the GPU and agrees with the CPU exactly**, at five settings including the one that
  used to fail: amount 5, a feather of 0, where the mask's ramp is steepest and the alpha is low. It was
  refused for a long time as "the CPU works in f64 and its colour write lands on a rounding knife edge" - the
  premultiplied result was within a level, and unpremultiplying turned that into three where the alpha was
  low. **The knife edge was the shader's `round` being half to even**; the rounding audit below fixed it, and
  the pixel that used to be three levels away is now exact. Its mask is still built on the CPU in f64 (its
  ramp is steep enough that an f32 evaluation of the same formula is three levels away where the feather is
  small), which is what the pass reads.
- **Dither: the ordered screens are on the GPU and agree with the CPU exactly**, judged **style by style**
  through `GpuBackend::dither_accepts`. Bayer 2 x 2, 4 x 4 and 8 x 8 run the CPU's own `adjust_tone`, its
  threshold matrices and its quantization, pixel by pixel - measured at four combinations of density,
  contrast and levels, at both ends of the dark-to-light ramp, and with the tone's own colours. The rest each
  say why they do not: Atkinson and Floyd-Steinberg diffuse their error into their neighbours, one pixel
  depending on the last; ASCII needs a glyph atlas built from a font; Scanlines has its beam pass built and
  running (`fx_scanlines`: the line's own average recomputed per pixel, the bead, the wobble and the beam)
  but it is **one pixel away from the CPU at its simplest setting**, so it stays refused until that is
  settled, and a glow above zero blurs the result on top of the lines, which is a refusal of its own; a pixel
  size above one averages the image down first; and the dot shape rounds whole cells afterwards.

  That difference is now measured from both sides and left with one suspect. The pass reports its own
  intermediates (the probe is `probe_the_scanlines_intermediates`, behind the program's scalar 12), and they
  are self-consistent: tone 91, cover 127, beam 32 and the spacing it read - **2**, so the scalar slots are
  the pass's own and the suspicion of a slot collision is closed - give exactly the CPU's own [61, 61, 61].
  Yet the same settings through `filter_image` come back [255, 255, 255] against the CPU's [20, 20, 20], and a
  cover of one is impossible at spacing 2: the beam is `middle * (0.2 + 0.5 * sqrt(tone))` with `middle = 1`
  and the distance is half a pixel, so the cover cannot pass 0.7. The pass's own numbers cannot produce 255
  and the two stages around it have now both been read. On the **test's own image** (the earlier probes used a
  different one, which is what made them look self-consistent - see the lesson below), the pass receives
  [3, 43, 93, 255] at (10, 11), byte for byte what `Surface::from_bitmap` holds for the CPU, so
  `fx_prepare` is right; and the bytes it is about to **write** are [255, 255, 255] where the CPU ends at
  [20, 20, 20]. **The tone, the cover and the column the pass reads are all exactly right** - 0.149, 0.392
  and column 10, which is what the arithmetic above asks for - so the fault was in the one line after them:
  `dither_write` takes the pixel's coverage as a **fraction**, which is what the CPU hands it
  (`pixel[3] as f32 / 255.0`), and the scanlines pass handed it the raw byte instead, scaling every pixel by
  another 255 and saturating to white. With that fixed, two of the four scanline settings agree with the CPU
  exactly (spacing 2 and spacing 4); the wobble-and-beads settings are still one pixel away, so the style
  stays refused and says so.

  **A probe is only as good as its input.** The first scanlines probes built their own 23 x 17 image with
  `index * 31` where the test uses `effect_test_image`, whose colours are `index * 37`. The pass looked
  self-consistent against the CPU on the probe's image and wrong on the test's, which cost a round. Feeding
  the probe the test's own image - one line - is what turned the round into an answer. The measuring test is
  `the_scanlines_dither_matches_on_the_gpu`, ignored, its label carrying the settings.

  **A probe is only as good as its input.** The first scanlines probes built their own 23 x 17 image with
  `index * 31` where the test uses `effect_test_image`, whose colours are `index * 37`. The pass looked
  self-consistent against the CPU on the probe's image and wrong on the test's, which cost a round. Feeding
  the probe the test's own image - one line - is what turned the round into an answer. The measuring test is
  `the_scanlines_dither_matches_on_the_gpu`, ignored, its label carrying the settings.

  The program's scalar slots now have a table at the place they are written, so a third pass cannot collide
  with the first two the way the marks pass collided with the threshold screens: 0 gamma, 1 contrast, 2 levels
  and 3 through 8 for the ramp are shared by every pass and identical for all of them; 9, 10 and 11 are the
  only ones two styles share (marks: light_on_dark, cell size, angle; scanlines: spacing, beads, wobble) and
  they are written by the style's own branch; 12 is the probe flag.

  That is the whole list of eleven styles, each judged on its own: **eight run on the GPU** (Bayer 2, 4 and 8,
  the patterns, the dot, line and diamond screens, and the scanlines when their glow is zero, which is the
  one setting that blurs) and three say precisely why they do not (Atkinson, Floyd-Steinberg and ASCII) -
  plus the two settings that are passes of their own whatever the style (a pixel size above one, and the dot
  shape). Scanlines with a glow above zero is refused by name and says so.

  The scanlines cost two bugs, both of them unit mistakes rather than geometry, and both worth keeping:

  - **`dither_write` takes the coverage as a fraction.** The CPU hands it `pixel[3] as f32 / 255.0`; the pass
    handed it the raw byte, so every pixel was scaled by another 255 and came out white. Tone, cover and the
    column read were all measured correct before this was found - which is what a probe reporting the pass's
    own values is for.
  - **Rust's `f32::round` is half away from zero and WGSL's `round` is half to even.** A bead landing on
    `.5` - one did at (14, 13) - picks a different column, and a column is a whole pixel. The shader now has
    `round_away` for it. The marks and threshold passes still use `round`; their settings have not landed on
    a half yet, and if one ever does, this is the first thing to look at.

  The marks pass (`fx_dither_marks`) runs the patterns and the dot, line and diamond screens, and agrees with
  the CPU exactly: measured on the patterns at two colours, on the halftone screens at four combinations of
  cell size and angle with light-on-dark both ways, and on a two colour ramp.

  **It took three probe rounds to find why it did not, and the answer was worth the rounds.** The first two
  reported the tone, the slot, the pattern row and the shift, and all of them were right - `toned 182 slot 11`
  against the CPU's 0.7152, rows 0x81, 0x81, 0xAA, 0xFF, 0x88 for slots 11, 11, 10, 9, 8, shifts 7, 6, 5, 4,
  3 - yet the mark was wrong wherever the chosen bit was the top one, which sent the hunt after the bit
  extraction. Rewriting `(row >> bit) & 1u` as `(row & (1u << bit)) != 0u` changed nothing, and that is what
  gave the bug away: the row the probe printed came from the probe's **own** `dither_pattern` call, so it was
  correct whichever branch the pass took. The third probe reported the branch itself, and the pass was
  reading `style` **2** - the line screen - for a patterns pass, because the host still mapped every style
  but Bayer 2 and 4 to the same word (`_ => 2`). The patterns branch never ran at all.

  So: a probe that reports an intermediate the probe computed itself proves nothing about the code under
  test. The third probe reported what the *pass* read, and the bug fell out in one run. That is the lesson to
  keep from this file's longest hunt.

  One lesson worth keeping: the marks pass first wrote its own settings into the program's scalar slots 3
  through 8, which are where the **ordered** screens read their dark and light from. That broke Bayer 2, 4
  and 8 - the styles already delivered - as well as the new ones. The marks settings now live at 9 through
  11 and both passes have their own slots. A probe round earns its keep by catching that kind of collision,
  not only by finding the bug it was aimed at.
- **Bloom and tonal contrast are on the GPU and agree with the CPU exactly**, measured pixel for pixel at
  four settings each (bloom amount and radius, tonal amount, radius and the three tone weights).

The two of them turned out **not** to need a third blur, which is worth recording because it looked as if
they might: `filters.rs` imports `adjustment::gaussian_blur` itself (line 23, and it has a test asserting
that its own filter blur is that kernel), so bloom's and tonal contrast's Gaussian is the blur adjustment's
blur, rounded between the axes and spreading into transparency past the edges. The GPU path therefore
dispatches the `blur` entry point that already existed, with the CPU's own taps and weights, and adds only
the two per-pixel passes around it: the highlight weight for bloom, and the tanh detail term for tonal
contrast (written from its exponential, since WGSL has no `tanh` in its core).

### Layer effects

All six effects run on the GPU: `fx_prepare`, `fx_shape`, `fx_shift`, `fx_blur_h`/`fx_blur_v` (the effects
blur, which carries its border outwards and rounds once after both axes, unlike the adjustment blur),
`fx_extreme` (the separable morphological filter a stroke's ring is measured from), `fx_combine` (the plane
algebra), `fx_fill` (the CPU's float source over), `fx_over` and `fx_straighten` - driven in the order
`effects::render` paints: behind the layer, then the layer, then on top. The layer's own raster mask is
folded into the shape before the effects; its clip coverage and folder masks are applied after the grown
placement, through the ordinary planes.

Every one agrees with the CPU **exactly**, measured image against image by a test that compares
`effects_image` with `effects::render` directly, with the placement and the composite left out: strokes
inside and outside, drop shadow, outer glow, inner glow, inner shadow and colour overlay, each alone and all
six at once, with a mask and a blend mode, at radii wide enough to reach past the grown canvas, and through
a region render.

Four things had to match rather than nearly match, and each was worth a whole image:

- **The layer's own pixels are composited over the effects** with the CPU's texel function, not a plain
  source over - a first attempt passed the layer's *straight* bytes where the premultiplied placed image
  belonged, which doubled the alpha and landed 110 levels away.
- **The plane algebra's mode** travels in the pass parameters, not in the program's scalars: while it was
  wired to the wrong one, every combine ran as an outer glow and an inside stroke came out 227 levels away.
- **A shadow's offset is rounded half to even before the shader walks to it**: truncating instead moved a
  135 degree shadow one pixel and cost 15 levels of coverage.
- **The effects blur is not the adjustment blur**: it carries its border outwards where the placement blur
  spreads into transparency, and it rounds only once, after both axes, so its horizontal half leaves f32
  values in a buffer of their own.
## Region rendering

`flatten_region(document, bounds)` composites one rectangle of the canvas: pixel for pixel what
`flatten_document` would give, cropped to `bounds`. The editor redraws a dirty rectangle between pointer
samples, and the whole pipeline is per-pixel and position independent, so a rectangle can be rendered on its
own instead of compositing the canvas and throwing most of it away. The equality is exact, not approximate,
and twenty tests assert it.

### How a rectangle is rendered

- **The frame** is the rectangle, padded by the reach of the document's blurs and cropped back afterwards. A
  blur reads its neighbours, so a rectangle without that padding would show a soft edge where the whole
  render has none. Every blur in the document adds its own reach, because they stack.
- **Each layer lands in its own dense box** inside the frame: the pixels that fall in the rectangle and
  nothing else. A placement on whole pixels, unrotated and unscaled, is copied a row at a time; anything
  else is resampled exactly as it would be on the whole canvas.
- **A plain layer is painted straight into the canvas** - no mask, no clipping link, no effects, so there is
  nothing to build first - and a row whose pixels are all opaque is one memcpy, because at full alpha
  premultiplied bytes and straight bytes are the same bytes.
- **Masks and clipping coverage** land in the same box at the same offset and are multiplied into the
  layer's alpha there. Everything else about them is unchanged.
- **The seeded patterns** (Grain, Add Noise) are anchored to the document, so the frame tells the kernel
  where it sits; otherwise the grain would restart at the rectangle's corner and stop matching.

### What it cost before

`compc bench` (release) on a 4000 x 4000 canvas with an 800 pixel brush and 100 pointer samples:

| | before | after |
|---|---|---|
| composite (changed area), 757 x 798 | 35.07 ms | **3.89 ms** (9.0x) |
| sample to pixels | over the 16 ms budget | **7.78 ms, within budget** |

The 3.89 ms is `compc bench`'s own copy-the-document approach, which shares this compositor;
`flatten_region` itself measures **1.69 ms** for the same shape (800 x 800 on a 4000 x 4000 canvas, one
opaque layer), so the editor gains a little more by calling it. Four things made the difference, in the order
they mattered:

1. `Surface::from_bitmap` ran over the **whole layer** before placing it - sixteen million pixels to
   premultiply for an eight-hundred-pixel rectangle. Placement now premultiplies only the pixels inside the
   box, and none at all where they are opaque.
2. The 1:1 placement was a per-pixel loop with a bounds check each time. It copies rows now.
3. The per-pixel blend and opacity path ran on one core with an integer division per channel. It runs across
   the cores now, like the rest of the compositor.
4. A layer that misses the rectangle is skipped before anything is allocated for it.

`cargo test --release -p comp-render --lib bench::benchmark_region_composite -- --ignored --nocapture`
reproduces the table below, which also shows the shape where the region path cannot win: a layer at 80% in a
blend mode has to premultiply, scale and blend every pixel of the rectangle whatever the entry point, and that
is what it costs.

| Case (4000 x 4000 canvas, 800 x 800) | old (ms) | region (ms) |
|---|---|---|
| 1 layer, opaque, Normal | 1.89 | 1.69 |
| 1 layer, 80%, Multiply | 6.42 | 8.29 |
| 4 layers, 80%, Multiply | 13.54 | 12.80 |
| 10 layers, 80%, Multiply | 32.42 | 32.71 |
### Rounding: an audit, so it is not audited twice

Two bugs in a row came from the same place - a rounding convention that differs between Rust and WGSL - so
every rounding and integer conversion in the shader was compared against its CPU counterpart. The rule the
whole file follows now: **wherever the CPU calls `f32::round`/`f64::round`, the shader calls `round_away`**,
which is `select(floor(v + 0.5), ceil(v - 0.5), v < 0.0)` and so rounds half away from zero like Rust;
WGSL's own `round` is half to even and differs exactly on a half.

| Shader site | CPU counterpart | Verdict |
|---|---|---|
| `round_away` (three uses: the hue band index, `write_premultiplied`, the pattern slot) | `hue.round()`, `(value * alpha).round()`, `(coverage * 16).round()` | **Was inconsistent, fixed.** Each was `round` before; all three are the sites where a half changes an index, a slot or a byte. |
| `round_away` in the scanlines pass (the line shift and the bead column) | `(wobble * wave).round()`, `(x - along * dots).round()` | **Was inconsistent, fixed**, and was the bug that took a whole round to find. |
| `round_u8` = `floor(v + 0.5)` | `pixel.rs` rounds `v + 0.5` or `v - 0.5` by sign, then clamps | Consistent: the two agree on every value once the result is clamped to 0..255, which it always is. |
| `floor`, `ceil` | `f32::floor`, `f32::ceil` | Consistent, same definition, and used only on values that are far from a tie. |
| `%` on floats | Rust's `%` | Consistent: both are truncated remainders, and every use is on a positive value. |
| Integer `/` and casts (`i32(f)`, `u32(f)`, `f32(i)`) | Rust's `as` | Consistent: both truncate toward zero, and WGSL saturates where Rust saturates. |
| `select(a, b, c)` order | Rust's `if` | Consistent, but worth a note: WGSL's `select(f, t, cond)` takes the **false** value first, which is the opposite of reading order. Two near-misses came from this while writing the marks pass. |

The boundary tests are `the_dither_matches_across_a_sweep_of_grey_levels` (every grey in steps of 8 against
four dither styles: the sweep walks the pattern slot through its halves) and the half-way cases inside
`the_scanlines_dither_matches_on_the_gpu` (a bead and a line shift that both land on a half).

## Performance

Measured on this machine with `cargo test -p comp-render --release -- --ignored --nocapture`. The
composite loops run over rows with rayon.

Release (`opt-level = 3`, thin LTO; the profile the shipped CLI uses):

| Document | Time | Throughput |
|---|---|---|
| 512 x 512, one layer | 0.003 s | 81.1 Mpixel/s |
| 4000 x 4000, one layer | 0.131 s | 122.6 Mpixel/s |
| 4000 x 4000, ten layers (nine blend modes) | 0.861 s | 18.6 Mpixel/s |

`benchmark_whole_canvas_stages` splits a whole render into the passes it is made of, on a 4000 x 4000
canvas of 61 MiB apiece: canvas allocation 0.01 ms, one Normal placement 3.2 ms, one Multiply placement
42.1 ms, one mask 4.0 ms, one opacity scale 3.7 ms, the write back 6.8 ms, and eight canvas copies as the
memory floor at 43.8 ms. Two things follow. The write back was a serial pass over 61 MiB at 16.4 ms and is
now row-parallel at 6.8 ms, which is most of the ten-layer improvement above (1.061 s -> 0.861 s) - the same
`unpremultiply` per pixel, in any order, so nothing about the result changed. And the next target is plain
to see: a placement that blends costs 42 ms where the same placement in Normal costs 3 ms, because only
Normal with full opacity takes the direct paint path (place.rs line 409); the ten-layer render is nine of
those, so that single pass is about 90 per cent of it.

Debug build (`cargo test -p comp-render -- --ignored --nocapture`), which is what an unoptimized
`compc render` runs:

| Document | Time | Throughput |
|---|---|---|
| 512 x 512, one layer | 0.041 s | 6.4 Mpixel/s |
| 4000 x 4000, one layer | 1.918 s | 8.3 Mpixel/s |
| 4000 x 4000, ten layers (nine blend modes) | 12.764 s | 1.3 Mpixel/s |

The ten-layer case is slower per pixel because each blended layer needs the straight colors of both the
backdrop and the source before the blend function, and rounds back to 8 bits between layers - the same
work Core Graphics does per layer.

Memory: a document-sized surface is `width * height * 4` bytes, and the compositor holds two (the canvas
and one reused scratch surface) plus a document-sized coverage plane, so 4000 x 4000 needs about 144 MB
regardless of how many layers the document has.

## Differences from the macOS original, and why

Everything below is deliberate; the rest follows the Swift sources.

- **Blend math in `f32` on 8-bit buffers.** Core Graphics and Core Image work in floats internally. The
  port rounds to 8 bits once per composite instead, which keeps the buffers 64 MB rather than 256 MB at
  4000 x 4000 and matches what a Photoshop 8-bit document does. The reference fixtures are within one
  level everywhere; `alpha-ramp`, `layer-mask` and `group-opacity` differ by one level on about a
  fifth of their channels, which is the quantization of a premultiplied canvas at low alpha.
- **Soft Light uses the Photoshop cubic** (`blend.rs::soft_light`), not Core Image's filter: the macOS
  comment in `LayerAppearance.swift` records Core Image being up to 25 levels off Photoshop's curve with
  a light blend color. The task specification asks for Photoshop's.
- **Hue/Saturation is computed exactly**, per pixel in HSL. macOS builds a 33-cube lookup and interpolates
  between its corners, which is a preview speed trick; the cube approximates this result.
- **The hue-band response table** is sampled once per degree like `HueSaturationFilter.hueResponse`, and
  per-range settings are read from `hsvSettings` when a project carries them, falling back to the flat
  `hue`/`saturation`/`lightness` fields as the Master range.
- **Blurs** are true separable Gaussians with `sigma = radius` (the original calls
  `applyingGaussianBlur(sigma:)`), and motion blur is an even streak of `motionDistance` pixels along
  `motionAngle`, which is Photoshop's semantics; the original approximates the same streak with Core
  Image's `CIMotionBlur` at `distance / sqrt(12)`. Both spread into transparency past the canvas edge,
  as the unclamped Core Image blur does. Measured against the kernel oracle: a radius-4 Gaussian is
  within 4 levels, and a 12-pixel 30-degree motion blur within 73 - the oracle's own alternative
  angle differs by 196 on the same pixels, so that is the kernel, not the direction.
- **Hue/Saturation is exact rather than a color cube.** The oracle's `hsv-direct` variant, which runs
  the same formula, is within one level of this crate; macOS's 33-point cube is what differs, by up to
  16 levels. The direct formula is strictly more accurate, so no cube is ported.
- **Effects coverage is blurred with its border carried outwards**, as the original's
  `clampedToExtent()` does, so a shadow does not fade at the shape's own edge.
- **Effects are laid out on whole pixels.** The original draws the padded surface into the document
  with `LayerEffectsRenderer.placed(_:image:inset:)`, which grows the transform by the margin the
  effects added - one ratio per axis, so the padded surface covers the layer's pixels plus the margin
  one-to-one. Effect offsets land on the nearest pixel (a 45-degree shadow at distance 6 moves by
  `(-4, +4)`), rather than filtering the moved shape across two rows.
- **Shadow direction** is `(-cos(angle), sin(angle))`, from `LayerEffects.swift`'s `ShadowEffect.offset`.
  `comp_core::effects::ShadowEffect::offset()` uses `(+cos(angle), sin(angle))`, which agrees only at
  90 degrees; the effect renderer here follows the macOS original.
- **Downsample cache**: halvings are 2x2 box averages rather than vImage Lanczos, and enlarging samples
  with Catmull-Rom (Core Graphics's high quality). `Surface::downsample_level` keeps the original's
  thresholds (a level per doubling below half size, capped at 6).
- **Rotated layers** get analytic edge coverage (the destination pixel clipped against the source
  rectangle in source space) instead of Core Graphics antialiasing.
- **Adjustment layer masks** are placed through `Layer::effective_mask_transform()`, so an unlinked mask
  keeps its own placement; the original's GPU path places an adjustment's mask with the layer transform.

## Not implemented in this pass

- **Text and shape layers are not rasterized.** `Layer::text` and `Layer::shape` are metadata; the macOS
  app renders their pixels into the layer's image when an edit is committed, and the package stores the
  result. A layer with text or shape metadata but no image contributes nothing here, and
  `flatten_document` returns a transparent region for it. An editor that wants text or a shape on the
  canvas has to rasterize it into the layer image first (the same division of labor the format implies).
- **Filters outside the 12 adjustment kinds** (Camera Raw, vignette, bloom, tonal contrast, lens
  correction, content-aware fill, background removal) belong to `comp-io`/`comp-brush`, not here.
- **Live editing paths** - a brush stroke in progress, a transform being dragged, a floating selection -
  are the editor's business; this crate composites committed documents.
- **GPU compositing.** The pipeline is CPU only and rayon-parallel. `blend.rs` and `pixel.rs` are the
  seam a GPU backend would replace.
- **No dirty-rectangle path for adjustments or filters**: either re-runs over every pixel even when a
  caller knows only part of them changed. @@blur_margin@@ tells a caller how much to pad; nothing here
  tracks what actually moved.
- **ASCII's font**: the Dither filter's ASCII look draws a small built-in 5x7 font rather than the system
  font CoreText gives macOS, so the characters differ (their relative ink, and so the pick order, is the
  same idea). Bloom / Glow is likewise an approximation of an undocumented Core Image kernel.

## Tests

`cargo test -p comp-render` runs the unit tests in each module plus `tests/fixtures.rs`.

- `blend.rs`: the corner table for all 24 modes (backdrop and source at 0 and 1), known Photoshop
  midpoints, alpha 0 and alpha 1 behavior, channel extremes, the luminance and saturation identities of
  the component modes, and the two regression tests for the middle-channel bug the reference fixtures
  caught.
- `pixel.rs`, `place.rs`: premultiplied round trips, halving, downsample levels, sampling at edges, the
  half-covered edge, rotation coverage, and mask placement.
- `adjustment.rs`: identity settings for every kind that has one, Levels black/white/gamma, Curves,
  Exposure, Gradient Map, Invert, Black & White (gray stays gray, reds above blues), Color Balance,
  seeded Add Noise and Grain, blur spread, and alpha untouched by the color kinds.
- `effects.rs`: `enabled = false` draws nothing and needs no room, each effect lands where it should,
  and the layer stays where it was.
- `composite.rs`: empty documents, hidden layers, pixel-less layers, order, opacity, blend modes, masks
  (0/64/128/255 and disabled), folder opacity and folder masks, adjustment layers (below only, inside
  folders, with opacity), transforms, and a clipping cycle. Clipping has six tests of its own: a base's
  opacity, a base's raster mask, a folder opacity reaching the clip through its base, a chain that
  multiplies every coverage along it, a base with no pixels (no clip), and a hidden base (still clips).
- `tests/fixtures.rs`: renders both reference fixture sets with `flatten_document` and compares every
  channel with the expected PNGs - `tools/verify/fixtures` within one level, and the adjustment and
  effect oracle's `tools/verify/oracle/fixtures-oracle` within the tolerance each fixture declares.
  Both are skipped when the tools directory is absent, so the crate does not depend on it.
- `filters.rs`: all 17 kinds round-trip through their names and serde; the settings clamp to the panel's
  ranges and decode with camelCase keys; unsupported kinds return a typed error; every kind survives a
  1x1 and an odd-sized image. Then each new kernel: Dither is deterministic with only the colors it was
  given, quantizes to the tones it was asked for, keeps its alpha and leaves clear pixels alone, mixes
  its two tones near the input's mean, differs between the ordered screens, marks more of a dark area,
  picks denser characters for brighter cells and works in chunky blocks; Lens Correction is the identity
  at zero, keeps the center pixel, magnifies or shrinks with the sign of its setting and fades the
  corners it samples past; Vignette is the identity at zero amount, keeps the middle, darkens outwards
  monotonically, protects highlights and keeps alpha; Bloom is the identity at zero amount and on dark
  or mid-gray images, spreads a highlight without leaving the alpha, and leaves clear pixels clear;
  Tonal Contrast is the identity with no amount and on a flat image, favours the tones its sliders name,
  and keeps alpha. Finally, the kinds that reuse an adjustment kernel are checked against it directly.

## Status

- `cargo test -p comp-render`: 187 unit tests and both fixture comparisons pass; 5 benchmarks and reports
  are ignored until asked for. The GPU tests skip on a machine with no adapter and fail on a rejected
  shader, and 22 of the unit tests are the GPU ones here.
- `tools/verify/acceptance.py`: 40/40 fixtures within one level. The coverage fixtures are `clip-mask`,
  `clip-base-opacity`, `clip-base-mask` and `clip-chain` (a base's pixels, opacity, raster mask and
  upstream chain), `group-mask` and `group-opacity` (folder masks and folder opacity), `layer-mask` and
  `alpha-ramp` (per-layer coverage), `placement-offset`, `placement-scaled` and `placement-rotated`
  (transform sampling and its edge coverage), plus `hidden-layer`, `flip-horizontal` and `nested-groups`.
- `tools/verify/oracle/run_oracle.py`: 41 fixtures, 38 within the oracle's own tolerance. The nine
  `effect-*` fixtures are now exact or within one level (color overlay, strokes, hard shadow and the
  180-degree shadow are byte-exact; the blurred ones are within one); `gradientmap-default` is exact.
  The three outside are the two documented ones: `hsv-master` and `hsv-reds` (the exact formula against
  the reference's color cube) and `motionblur-30deg` (the even streak against Core Image's taper).
