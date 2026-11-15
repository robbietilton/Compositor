# Core procedural brush dynamics

October 31, 2026 · `task-a892b4da-6256-4db6-a77d-01365afcdaa9`.

These are native Compositor semantics, not inferred Procreate equations. The Stroke Path, Shape and Rendering completion tasks reuse this implementation; they should extend its controls rather than introduce another renderer/settings model.

## Supported controls

| Control | Meaning and bounds |
| --- | --- |
| Pressure Curve | 2–16 finite points in [0,1]²; endpoints keep input 0/1, strictly increasing input, freely editable output (including rising/falling curves). Shape-preserving cubic interpolation with per-point Easing: 0% straight joins, 100% automatically smooth joins. Drag graph points or edit input/output/easing sliders; Linear, Soft, Firm and S-curve are editable starting profiles. Identity preserves existing response. Missing pressure bypasses the curve and remains full strength. |
| Smoothing | Existing screen-space rope, snapshotted at stroke start. It filters position while retaining stationary pressure changes. |
| Custom Spacing | Optional 0–400% of the full base diameter, minimum 0.25 document pixels. Off retains existing automatic spacing/continuous rendering. Distance remainder survives event boundaries and tail replacement. |
| Flow | 0–100% per dab. Optical densities accumulate as `-log(1 - flow × tipCoverage)` and convert back with `1 - exp(-density)`. Zero paints nothing. Floating-point storage retains sub-byte flow. Stroke Opacity remains the final cap; pressure-opacity caps accumulation at the firmest supported pressure per pixel. |
| Start/End Size Taper | Independent 0–100% fractions of completed centerline length. Linear size ramps, combined with min when overlapping. A zero-length click retains its tip. Live preview is provisional without taper; release/flush replays settled dabs at final length. |
| Roundness | Minor/major radius ratio 5–100%. Procedural ellipse in document space, including on transformed/flipped layers. |
| Angle | Clockwise document-space angle, -180°…180°. Disabled for a circle. |
| Count | 1–16 coincident dabs per stamp position, each using Flow. |
| Angular Scatter | Symmetric angular offset up to ±180°, meaningful only for elliptical tips. A stroke seed plus dab/copy index determines angles; it never varies with event count or preview-tail redraw. |

Pressure curve and calibration are separate: curve controls stay above device diagnostics and calibration. Curve editing retains mappings without connected hardware. Other tilt/barrel responses, speed size/opacity and random pressure dynamics, source pressure curves, touch/pressure-specific taper, grain, wet/glaze modes and remaining controls stay disabled pending their owning tasks. Stroke Path jitter, falloff and speed spacing are now implemented; see [Stroke Path semantics and qualification](stroke-path.md). Full category work is not claimed here.

## Rendering and storage

`RoundBrushDynamics` is the concrete native settings value shared by BrushSettings and BrushPreset. Legacy metadata without this field decodes to identity/automatic defaults. Validation runs at preset persistence and stroke creation. Applying/capturing presets includes the new value; original Procreate source data and explicit remapping preserve these native overrides. The collection remains schema 1 with an optional backward-compatible field; `.comp` pixels/manifest do not change.

Default settings retain the existing continuous Metal path and existing CPU fallback. Settings requiring discrete stamps use the new procedural CPU path even when Metal is available; no continuous sweep silently ignores spacing/shape/flow/taper. Its floating-point coverage reuses the existing tiles, selection/mask clipping, original-pixel composition, snapshots, undo and export. Only Brush paint/erase and its isolated drawing pad receive these controls. Healing/clone/blur and Smudge/Liquify commits reset them; gradients/selection edits continue with their existing default settings.

A stroke consumes at most 250,000 stamp positions (up to sixteen copies each), then fails through the existing cancellation/error path without committing partial pixels. Only taper retains settled dab records, bounded to 250,000 positions. Shape replay now includes full optional input and direction; the earlier 8 MB estimate for pressure-only records no longer applies. Coverage/caps allocate only for touched tiles. Dense, wide, high-count CPU stamping is more expensive than legacy continuous rounds; this task does not claim 4K latency qualification or introduce a GPU stamp kernel. Keep those measurements and any acceleration in the qualification/category tasks.

Tail replacement restores coverage, floating-point density/caps, distance phase, travelled length and dab index. Direct pixel writes cannot rely on CGContext image copy-on-write: stamped tails reconstruct grayscale coverage from immutable floating-point backups. Hard-ellipse antialiasing uses derivatives in layer-pixel space and conservative transformed bounds, avoiding sample-rate-dependent edge clipping. Straight spatial pressure ramps stay linear despite spline easing; nonlinear pressure curves apply at actual stamp positions. Preview replay retains each stroke's seed.

Settings changes coalesce into one drawing-pad replay after 200 ms without another change. Clear cancels pending replay; starting a stroke first applies the latest draft. Recorded taper replay collects settled dab positions without drawing untapered pixels or provisional tails, then rasterizes the completed taper once. Live canvas input retains its provisional feedback. This removes redundant work but does not establish a Release latency benchmark.

## Verification

`BrushDynamicsTests` verifies pressure curve validity and actual size/opacity response; spacing gaps; analytical flow/count values and opacity caps; tiny flow; ellipse angle; deterministic seed differences; sparse/dense replay; nonlinear pressure ramps; final taper and repeat flush; preset round-trip, legacy defaults and atomic invalid-save rejection; preview/canvas replay equality; sibling-tool defaults; transformed tips; selected mask painting across a tile boundary; undo/redo and `.comp` save/reopen.

Verification uses the already-open Xcode project and its incremental test actions, with no command-line rebuild or canary packaging. Native UI, reference Procreate matching and real-tablet feel remain separate from automated pixel/replay acceptance.

## Reported layout-test QoS warning

The user reported a Thread Performance Checker priority inversion at BrushPaletteTests' `panel.show` call. The existing Xcode result records that test location and raw stack addresses, but does not identify the lower-priority worker/queue. The exported stack is insufficient to attribute a root cause to an app-owned queue. The fresh 18:07 Xcode run passed all three palette tests with no runtime warnings, but non-reproduction does not establish a fix. The warning is not suppressed and no speculative thread-priority change is made. A symbolicated live capture of both sides of the wait is needed if it recurs.

The [Shape implementation](shape-brushes.md) now adds bounded image masks, orientation/input styles, flips, count/axis jitter and filtering, reusing this renderer and Stroke Path.

Pressure editor follow-up (October 31): both pressure mappings remain editable without hardware in range, for procedural and custom tips. Availability is diagnostic only. The graph samples the exact evaluator used by painting; optional per-point easing is stored in native preset JSON. Existing point-only presets decode with smooth easing. Nonlinear existing curves therefore become smoothly interpolated; identity defaults remain identical.

Flow is also available directly in the Brush toolbar as a percent field with scrubbing and arrow steps, sharing `roundDynamics.flow` with Rendering. Spacing retains distance-between-stamps semantics: decreasing it increases overlap. No mask conversion or spacing direction was changed for the replaced brushhead inventory.

Latest follow-up verification: 23 BrushDynamicsTests (including five foundational masks at three sizes/pressures), 10 importer tests, four native palette checks, and 10 existing pressure tests passed through open Xcode. The native pressure/palette screenshot run reproduced the Thread Performance Checker warning at `FloatingPanelController` initialization (the first panel construction), not an identified app-owned worker. No suppression or speculative priority change was made; a symbolicated two-sided wait capture remains necessary. [Per-point easing UI](evidence/shape/pressure-custom-curve.png). Bell is no longer a profile option.
