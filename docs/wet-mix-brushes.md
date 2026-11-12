# Native Wet Mix

Task `task-53cc9064-026f-4085-a560-adbfc65aef2d`. Implementation uses trunk `main`, without experimental optimization commits. Optional `RoundBrushDynamics.wetMix` lives in the existing preset JSON. Documents still save raster pixels; no `.comp` contract or version changes.

## Audit and reused flow

Wet Mix was an unavailable list in `BrushPalette.swift`; Rendering pickup and wet edges were already delivered and are not replaced. Palette preset application and `BrushDrawingView` both feed `EditorSession.beginBrush` → `makeRasterEdit` → `BrushStroke.append` → `walk` → `dynamicDab` → the shared C `brush_render_stamp`. Publication uses the existing pigment/density buffers, clipping and snapshots. `pickupColor` and Wet Mix share `sampledPigment`, reading evolving per-tile pigment rather than published images. No second paint engine, dependency, guessed source-field mapping or bundled image is added.

## Native units and order

The [official settings handbook](https://help.procreate.com/procreate/handbook/brushes/brush-studio-settings) describes Charge as initial loading with exhaustion/recharge, Grade as texture contrast, and Blur as paint softening. This implementation follows those control roles with explicit native approximations, not recovered source equations.

All eight values are finite normalized 0–1, shown as 0–100%. Missing metadata or the complete default group preserves the existing renderer and output. Values are validated by existing preset persistence and stroke creation boundaries.

| Control | Default | Per-dab native meaning |
| --- | ---: | --- |
| Dilution | 0 | Multiplies deposited Flow by `1 − dilution`; 1 deposits nothing. |
| Charge | 1 | Initial normalized reservoir, reloaded each stroke; 1 sustains the load, lower values exhaust. |
| Attack | 1 | Multiplies deposited Flow; 0 deposits nothing. |
| Pull | 0 | Pickup proportion, combined with Rendering pickup as `1 − (1 − pull)(1 − renderingPickup)`. Sample alpha scales pickup. |
| Grade | 0 | Raises tip hardness toward 1 and grain contrast toward 1: `base + (1 − base) × grade`. Image-tip mask coverage uses `coverage^(1 + 3 × grade)`, including a configured secondary tip. This changes native texture contrast; it does not control the reservoir. |
| Blur | 0 | Color pickup samples center and four axial points at up to half the nominal brush diameter, in document pixels. It averages premultiplied color and alpha before pickup; it does not blur the canvas image or tip silhouette. Needs Pull or a Blending mode. |
| Blur Jitter | 0 | Reduces the sampling radius by `1 − jitter × seededUnit(1200)`. |
| Wetness Jitter | 0 | Reduces deposition by `1 − jitter × seededUnit(1201)`. |

Each logical dab first samples existing pigment, mixes carried color, and refills the reservoir toward 1 by the alpha-weighted pickup proportion. Deposited Flow is `Flow × reservoir × attack × (1 − dilution) × wetnessJitterFactor`. Charge then consumes load by `(1 − charge) × Flow × pressure/taper strength × attack / 20` per logical dab, clamped at zero. Count copies share this one dab state; count does not multiply consumption. Zero Flow, zero pressure/taper strength, zero tip scale or an empty tip skips the dab. Spacing changes the number of dabs and therefore exhaustion distance. This is intentionally a native per-dab model, not a claim of source-equivalent units or equations.

The reservoir is a single bounded scalar, with the existing bounded carried RGB value. It is not saved across strokes or in a project. A transparent sample adds no load or color; zero-charge brushes can pick up existing paint. Masks, erase and healing strip Wet Mix from their stroke-local settings; sibling tool setup already clears round dynamics. Preset metadata stays intact. Color sampling follows the existing layer transform, canvas bounds and selection coverage. Selection clips pickup and deposited pixels; logical dabs still consume load when their output is clipped. Deposited pixels use the existing selection/mask publication. Provisional tail replay restores reservoir and carried color with dab spacing state; final taper replay resets both and rebuilds all density, cap, pigment and edge buffers in chronological order.

Charge is independent of stroke Opacity, per-dab Flow, tip wet-edge diffusion and Properties’ Smudge Pull. Black/white preview backgrounds remain display-only. Missing component/shape/grain gates and retained source containers are unchanged. Native settings do not prove Procreate parity; this model does not simulate fluid transport, spectral pigment or a pigment-free wash.

## Verification

November 12, 2026, Debug on this Mac mini. [Run summary and exact local xcresult paths](evidence/wet-mix/verification.txt).

- Seven focused Wet Mix tests pass (zero failures): defaults/finite ranges/JSON, exhaustion/reload/transparent pickup, mask and erase identity, each control changing output, image-tip Grade, controlled comparisons, seeded sparse/dense input and provisional/final taper replay. The final code builds successfully.
- The final BrushDynamics/BrushLibrary/BrushPalette run has 58 passes and two failures. The existing transformed selection/mask/undo/export/reopen and tile-partition tests now run with Wet Mix; source-byte retention/relaunch, missing component gates and two-color preview replay also pass. The native panel capture was generated by the existing AppKit test harness and inspected; owner live-app acceptance is separate.
- The broader Brush/Input/Intersection/Procreate import/Clone Stamp/Spot Healing/Blur run has 104 distinct passes and three failures. It preceded the final image-tip Grade extension; all three affected suites were rerun afterward. Real user-supplied Procreate fixtures are absent from this worktree, so their optional test returns early; this is not real-fixture acceptance.
- Untouched main independently reproduces both BrushDynamics failures: `presetsRoundTripAndRejectInvalidDynamicsAtomically` (validation error) and `transformedTipsAndSelectedMasksPreservePixelsUndoAndReopen` (mask alpha assertion). Untouched main also reproduces `CloneStampTests.cloneStampKeepsItsOwnSoftBrushTip` (initial brush hardness 0 versus expected 1). They remain unresolved; no full-suite green result is claimed. Unrelated compiler warnings remain.
- `git diff --check` passes. No physical Wacom/Pencil test, release performance, source-field mapping or source-equivalent visual/feel acceptance is claimed. Native wet effects use the existing 8-bit sRGB pigment buffers; HDR mixing remains unqualified.

To run a single new regression check using the existing framework:

```sh
xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' test '-only-testing:CompositorTests/BrushDynamicsTests/wetMixPickupJitterAndTaperReplayAreDeterministic()'
```

[Native editor](evidence/wet-mix/editor.png), [controlled native comparisons](evidence/wet-mix/native-comparisons.png), [pickup/taper replay](evidence/wet-mix/pickup-taper.png). Comparison rows are default wet settings, 70% Dilution, 20% Charge with full Grade, 30% Attack, and full Wetness Jitter, with identical seed/path/brush size/Flow/spacing. Pickup/taper uses an opaque green/blue backdrop, so strong pickup can blend almost into the underlying colors. These are native output examples, not source comparisons.

[Raw 4K Debug timing](evidence/wet-mix/4k-timing.txt): 2400 px path, 12 updates, 25% spacing, Intense Blending with wet/burnt edges 50%, Multiply, plus Wet Mix (Dilution 20%, Charge 70%, Pull 50%, Grade 30%, Blur 60%, Blur Jitter 40%, Wetness Jitter 30%).

| Diameter | Median update | Max update | Final flush | Tiles |
| --- | ---: | ---: | ---: | ---: |
| 40 px | 12.25 ms | 12.93 ms | 8.08 ms | 11 |
| 800 px | 146.43 ms | 157.29 ms | 89.64 ms | 56 |

The 800 px CPU workload is not 60 Hz. These timings measure test processing, not physical input-to-display latency. Experimental GPU changes were not integrated. Changes remain local and uncommitted in the dedicated `main` worktree; the original experimental checkout and its unrelated edits remain untouched.
