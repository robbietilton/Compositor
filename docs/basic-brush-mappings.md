# Foundational round brush profiles

October 31, 2026 · Task `task-75d82a04-f2d2-40db-939c-0ca09b06f44d`.

Five compact native round recipes are available for visual review. A single hardness value does not describe all five supplied tips: their peak coverage, solid-core radius, feather width and nominal-size padding differ. Ultra Soft retains a lower peak rather than normalizing every mask to opaque white. Flow and spacing independently control how these tips build into strokes.

## Exact identities and mapping revision 2

| Exact reference | Native recipe | New-import selection |
| --- | --- | --- |
| `Brush-Preset-Ultra-Soft.jpg` | Ultra Soft Round | Generated recipe |
| `Brush-Preset-Soft.png` | Soft Round | Generated recipe |
| `Brush-Preset-Medium.png` | Medium Round | Generated recipe |
| `Brush-Preset-Medium-Hard.png` | Medium Hard Round | Generated recipe |
| `Brush-Preset-Hard.png` | Hard Round | Existing fast hard renderer; padded generated recipe available explicitly |

Only complete case-sensitive identities match; custom folder suffixes and similar names do not. Explicit owning embedded images always win. Import retains original references, archives, unknown settings, per-component ownership and independent grain resolution. Invalid referenced images fail safely; a secondary component or missing grain is never dropped to make a brush paint.

Revision-one records remain usable with their existing native calibration. Refresh Mapping changes derived source metadata only, preserving UUID, native settings and opt-in. Existing brushes adopt a new recipe through **Use … Tip** in Shape, so refresh does not silently reset their tip or hardness. Future unsupported mapping revisions do not enable mapped round painting. No `.comp` format change is involved.

## Compact generated masks

| Recipe | Solid core / nominal radius | Rim / nominal radius | Gaussian exponent | Peak |
| --- | ---: | ---: | ---: | ---: |
| Ultra Soft Round | 0 | 0.9 | 2.5 | 0.45 |
| Soft Round | 0 | 1 | 2.2 | 1 |
| Medium Round | 0.45 | 1 | 5 | 1 |
| Medium Hard Round | 0.7 | 1 | 12 | 1 |
| Hard Round | Solid disk with one mask-pixel antialiasing | 0.8 | — | 1 |

Between core and rim, coverage is `peak × (exp(-k × t²) - exp(-k)) / (1 - exp(-k))`, where `t` is normalized feather distance clamped to [0,1]. Coverage outside the rim is zero. Hard uses an antialiased disk. `GeneratedBrushTip` creates bounded 128×128 masks in memory using these analytic recipes. Presets save identifiers, not generated pixels. No source images, sampled pixel tables, downloads or new dependencies are packaged.

These native starting recipes follow the broad radial distinctions in the user's replacement references. They do not reproduce proprietary source dynamics or rendering. Existing legacy native round defaults keep their previous renderer and hardness behavior. Generated recipes use the shared Shape image-stamp renderer, including its documented wide/dense CPU-stamping limits.

## Reference comparison

Qualification sampled 513 normalized radii in four cardinal directions, averaging source grayscale coverage at each radius. There was no center/scale optimization or source-stroke compositing. Native analytic profile versus local source samples:

| Recipe | Radial RMS difference, percentage points |
| --- | ---: |
| Ultra Soft | 1.49 |
| Soft | 0.96 |
| Medium | 2.04 |
| Medium Hard | 0.70 |
| Hard | 3.44 |

These are narrow mask-profile measurements, not source-pixel or stroke-rendering equivalence. Original images and sampled source pixels are not distributed. The generated Hard recipe's padding is separate from the existing full-size fast hard renderer.

## Controls and verification

Select a recognized imported brush → Edit → Shape → **Use … Tip** for an existing record, then enable the native approximation. New recognized soft-family imports already select their recipe, but painting still requires explicit opt-in. Native brushes can choose **Generated Substitute** and a round family directly. Grain/dual rendering requirements remain authoritative.

Flow is available both in Rendering and the painting toolbar: it controls per-stamp deposition, while Opacity caps the stroke. Lower spacing increases overlap; higher spacing separates stamps. Those values are native adjustments, not guesses from source filenames.

The [generated stroke atlas](evidence/shape/independent-generated-tips.png) starts with Ultra Soft, Soft, Medium, Medium Hard and Hard, all using identical native flow/spacing/size. Its final three rows are the separate generic Ink Dab, Dry Bristles and Speckle styles. It contains only independently generated output.

Xcode checks cover distinct bounded radial masks and peaks, real painting at sizes 16/64/128 and pressures 25/50/100%, deterministic sparse/dense replay and renderer requests, recipe persistence, exact embedded precedence, unknown references, grain/dual gates, legacy mapping revisions, preserved calibration on refresh, and actual preview/canvas output. Native editor screenshots remain separate visual evidence. Controlled Procreate stroke/pressure feel, physical tablet comparison and Release-wide-tip latency remain unqualified; see [Shape performance limits](shape-brushes.md).

Verification results: 23 dynamics checks passed at 21:25, 10 final importer checks at 21:27, four native palette checks at 21:23, and 10 existing pressure checks at 21:10. All ran through the open Xcode session, with no shell builds. The palette run had the existing native-panel initialization QoS warning; dynamics/importer/pressure had no runtime warnings. Catalog freshness and whitespace checks passed. The built app contained no files from the 286-name local brushhead inventory.
