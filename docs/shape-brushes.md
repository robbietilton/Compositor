# Shape brushes

October 31, 2026 · task-2b3541a0-57c5-4490-98eb-dabb9e9cbc45

## Audit before implementation

Existing: procedural round hardness, ellipse roundness/angle, fixed count and angular scatter, exact embedded-reference precedence and five centralized procedural source identities. Stroke Path supplies deterministic seed/index placement and tail rollback; CPU pixel loops, tile publication, preview, transforms, masks/selections and history/export are shared. Original archives remain immutable and dual/grain ownership is preserved. Embedded assets are recognized but not rendered.

Remaining: bounded decoded image masks/custom-source selection, image stamping, input style (touch, azimuth, azimuth plus barrel), stroke-follow/inverse rotation and orientation, relative barrel response, count jitter, stroke randomization, flips, horizontal/vertical roundness jitter and pressure modulation, pressure/tilt roundness, filtering, full-input/direction taper replay, native controls and qualification. Existing scatter is disabled for circular procedural tips, correctly; image tips need it even at roundness 1. Count currently stops at 8; the researched category specifies up to 16.

## Evidence boundary

The [official Shape handbook](https://help.procreate.com/procreate/handbook/brushes/brush-studio-settings) documents input styles, azimuth overriding touch rotation, barrel fallback to azimuth, relative barrel orientation, signed stroke-follow rotation, per-dab scatter, count/count jitter, per-stroke randomization, flips, pressure/tilt roundness, two axis jitters with pressure mapping, and no/classic/improved filtering. It does not publish rendering equations or numeric archive mappings. Native semantics will be explicit; retained source bytes and unsupported grain/dual components must never be silently replaced or flattened. The user's [Art with Flo video](https://www.youtube.com/watch?v=pzp-z1TiWj4) has a Shape chapter at 6:05–7:51 for qualitative comparison.

## Sources and persistence

`RoundBrushDynamics.shape` is optional; absent values preserve legacy behavior. Native source choices are Procedural, Original Embedded Image, Custom Image, and Generated Substitute. Generated substitutes are explicit independent native styles; see [the catalog and distribution policy](brushhead-catalog.md). Embedded masks are derived into their owning `BrushSource.Definition.tip`; a secondary component never overwrites its primary. Custom images retain original bytes through the existing digest-addressed source store before the preset is saved. Original archive references/assets and native overrides remain independent. Remapping rebuilds derived embedded masks while retaining native custom settings. No numeric source-setting equations are guessed.

Images are inspected with ImageIO before thumbnail decoding: at most 64 MiB compressed input, one image, each dimension ≤32,768 and total ≤64 million pixels. The derived square mask is at most 256×256, with aspect-preserving transparent padding; premultiplied sRGB-weighted grayscale and alpha are stored separately. White paints uses grayscale, Black paints uses alpha minus grayscale, Alpha uses alpha. The full original bytes remain retained. A brush-set/library import allows at most 8 MiB total decoded shape-mask bytes in addition to existing ZIP/graph/image limits. Existing 8 MiB collection metadata and atomic replacement limits still apply. Failed imports/saves never publish a partial collection.

Unsupported image decoding leaves the embedded reference and source bytes retained with an explicit diagnostic and no usable mask. No similarly named sibling is substituted. In particular, Volcanic Ash's grain-named shape file is decoded as the shape because that is its actual reference; grain resolves independently. Imported rendering remains opt-in. Grain/dual requirements still block full painting, even when a primary image can be inspected. A custom source explicitly chosen by the user may replace a missing single shape; it does not discard grain or flatten a dual brush. Legacy round approximation flags remain readable, with one native approximation toggle in the editor.

## Native Shape semantics

- Angle is clockwise in document coordinates. Touch/Mouse orientation adds signed stroke-direction response: 0 fixed, +100% follows the local path, −100% follows inversely. First/zero-length dabs use document +X.
- Pen Azimuth uses `atan2(tiltY, tiltX)` for a valid non-upright calibrated tilt vector, overriding touch rotation. Missing/upright tilt falls back to touch rotation. Azimuth + Barrel adds reported barrel angle; missing barrel retains azimuth. Relative mode subtracts the first valid barrel angle in the stroke. Hardware availability is labeled and never deletes a mapping.
- Count is 1–16. Count jitter chooses a seeded integer between `max(1, ceil(count * (1 - amount)))` and Count at each stamp position. Angular scatter remains the existing bounded ±angle per copy; it also works on image tips at roundness 1. Randomize adds one seeded orientation for the whole stroke.
- Horizontal/vertical flips reflect the mask axes. Roundness retains the minor/major ratio. Independent horizontal/vertical jitter randomly compresses each axis, never below 5%. Each axis optionally uses the common pressure mapping evaluator. Pressure roundness and tilt roundness multiply minor radius by `max(.05, 1 - amount * input)` when that channel exists. Pressure uses the existing pressure curve; tilt uses calibrated magnitude. Missing channels do not squash the tip. Symmetric circles are unchanged by angle/flips.
- Filtering: None uses nearest image samples and unfiltered hard procedural edges; Classic uses bilinear image samples and the existing procedural edge behavior; Improved averages four quarter-pixel samples. Intrinsic soft-tip falloff remains part of the shape. These are native kernels, not claimed implementations of Procreate's proprietary kernels.

Image masks and all nontrivial shape behavior use the existing tiled C stamp path; GPU-equipped and software-only requests produce the same discrete output. Legacy round defaults retain continuous Metal/CPU behavior. Rotated image-square bounds include their corners and the half-source-pixel support of zero-padded bilinear filtering, including one-pixel sources; provisional backups include the same conservative extent. Placement, deterministic random evaluation and path spacing remain shared with Stroke Path. Taper records now carry full optional input and local direction, so final replay preserves pen orientation, copy count and squash. The C bridge uses independent mutable density/cap buffers to satisfy Swift exclusivity. Empty selected masks allocate no paint tiles or transparent commits. Density conversion, clipping, masks, opacity, snapshots, undo and export continue through existing shared publication.

## Visual comparison and hardware boundary

The supplied Art with Flo video was inspected in browser playback at 6:38 (touch/stroke rotation), 6:53 (scatter/count/count-jitter controls and strokes), and 7:28 (angle/roundness squash). Its irregular tip, hand-drawn paths and unspecified scale differ from our controlled asymmetric L. Our generated fixture verifies independent flips/quarter-turn rotation, distinct filtering edges, seeded scatter/count/squash and input-preserving taper. Qualitative behavior agrees with the demonstrated category behavior; this is not a pixel-identical reconstruction of the video's brush or proof of its undocumented kernels. No supplied proprietary source images are redistributed in these evidence files.

Native AppKit/SwiftUI screenshots exercise procedural, custom-image, imported-inspection and existing round-approximation modes, with top and bottom scroll positions. Source selection/mask mode, orientation, count/jitter, flips, squash and filtering remain in the existing editor and shared drawing pad. Original component selection is inspection-only for unavailable dual rendering; native controls edit the primary only. Clicking a brush still activates it; editing stays explicit.

Physical Wacom PTH-851/K pen feel and Apple Pencil channel behavior were not exercised. Input availability/fallback is checked using the shared normalized sample path and tests, with device-dependent controls labeled. Owner/hardware acceptance remains separate.

## 4K Debug timing

The Xcode benchmark uses a blank 4000×4000 layer, a 2400 px straight path, 12 updates, 25% spacing, two rotated asymmetric image copies per position and a fixed seed. It verifies touched-tile limits and that commit snapshots remain unmaterialized. This measures stroke updates/flush, not display-frame latency or Release performance.

| Diameter | Filtering | Median update | Maximum update | Flush | Tiles |
| --- | --- | --- | --- | --- | --- |
| 40 px | None | 3.98 ms | 6.96 ms | 2.35 ms | 11 |
| 40 px | Classic | 4.94 ms | 5.67 ms | 2.95 ms | 11 |
| 40 px | Improved | 13.69 ms | 14.25 ms | 7.05 ms | 11 |
| 800 px | None | 50.01 ms | 55.17 ms | 31.42 ms | 90 |
| 800 px | Classic | 66.54 ms | 69.30 ms | 40.54 ms | 90 |
| 800 px | Improved | 234.10 ms | 346.19 ms | 126.87 ms | 90 |

Core image-stamp tile storage here estimates 9 bytes/pixel (RGBA 4, grayscale 1, density 4), about 6.49 MB / 53.08 MB for 11 / 90 tiles, plus the bounded mask. This excludes original/base images, immutable snapshots, temporary decode buffers and copy-on-write tail backups; it is not peak RSS. Falloff/pressure opacity adds cap storage. Wide, dense or high-count CPU image stamps—especially Improved filtering—remain a known performance limitation, not real-time qualified. Legacy rounds retain their existing fast path. No hidden dab skipping or spacing increase is used to conceal this cost. GPU stamp acceleration, Release measurement and source/hardware qualification remain follow-up work.


## Evidence and verification

Native editor: [custom source top](evidence/shape/custom-top.png), [custom controls bottom](evidence/shape/custom-bottom.png), [procedural top](evidence/shape/procedural-top.png), [procedural bottom](evidence/shape/procedural-bottom.png), [round approximation](evidence/shape/imported-round-approximation.png), [unavailable imported source](evidence/shape/imported-unavailable.png).

Renderer comparison: [flips, rotation and filtering](evidence/shape/rotation-flips-filtering.png) — top row original / horizontal flip / vertical flip / 90°; bottom row None / Classic / Improved, enlarged with nearest sampling for inspection. Also [seeded image jitter and taper](evidence/shape/image-jitter-taper.png), [selected transformed mask](evidence/shape/selected-transformed-mask.png), and [4K Debug timing](evidence/shape/4k-debug-image-timing.txt), final 19:46 Xcode run.

All 71 relevant tests passed in the open Xcode: BrushDynamicsTests 20, BrushPaletteTests 3, BrushTests 19, PenPressureTests 10, BrushIntersectionTests 4, BrushLibraryTests 6, ProcreateBrushImportTests 9. Native palette result had zero runtime warnings. No command-line build or canary packaging was used. `git diff --check` passed.

Checks cover asymmetric flips/rotation, signed stroke following, pen orientation and absent-channel fallback, actual count-jitter coverage, per-stroke randomization, filtering differences, sparse/dense replay, full-input taper and tail replacement, bilinear filter fringe bounds, empty-mask no-op, tile seams against unsplit coverage, source ownership/embedded precedence/Volcanic Ash, corrupt-image rejection versus valid unsupported-image retention, aggregate decoded-mask limits, persisted original bytes/legacy defaults/atomic invalid saves, shared preview/canvas output, sibling tools, transformed selected masks, undo/redo, export/reopen, snapshot materialization and 4K timing/tile counts. Hardware feel, exact source appearance and Release latency remain separate from these automated results.
