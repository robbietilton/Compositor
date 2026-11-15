# Stroke Path

October 31, 2026 · task-8206438c-bda1-45d8-a17f-2b4ceff72e57

## Audit before implementation

The round-dynamics delivery already provides fixed optional spacing (diameter fraction, .25 px minimum), carried distance remainder, document-space procedural stamps, deterministic seed/index angular scatter, shared canvas/preview, taper replay, tile/mask/selection composition and snapshots. Tail replacement restores distance, dab index and floating-point coverage. Defaults retain continuous Metal rendering; discrete controls use CPU stamps. Preview changes already coalesce after 200 ms idle and recorded taper replay skips provisional pixels.

Missing: persisted spacing/lateral/linear jitter, opacity falloff, timestamp-based speed spacing, property input modulation, corresponding editor controls, path-specific replay/extreme/transform/mask tests and 4K measurement. Existing walkers carry pressure only, so they also need interpolated optional channels and sample time. The present deduplication ignores stationary tilt/rotation changes. Tail backup bounds cover only the unjittered radius. Extending these shared boundaries avoids a second placement engine.

## Evidence and qualification boundary

The [official handbook](https://help.procreate.com/procreate/handbook/brushes/brush-studio-settings) documents spacing variability, perpendicular lateral displacement, along-path linear displacement and progressive opacity fade. It explicitly documents pressure for spacing jitter and pressure/tilt/barrel rotation for lateral and linear jitter. Speed spacing belongs to the Dynamics category but shares the Stroke Path evaluator here. These descriptions do not establish source equations or numeric archive keys. No numeric import mapping is currently verified; original archives and native overrides must remain separate. Native implementation and automated replay checks cannot certify Procreate pixel parity. Representative source-stroke references and real-hardware comparison remain separate acceptance evidence.

## Native semantics

`RoundBrushDynamics.strokePath` is optional; absent values decode to inactive defaults. No `.comp` schema change is needed. All values are validated at preset persistence and stroke creation. Settings apply only to Brush paint/erase and masks, through the existing snapshot; sibling tools retain their default settings.

- Spacing: 0–400% of full diameter, with the existing .25 document-pixel minimum; automatic spacing remains the legacy default.
- Spacing jitter: 0–100%, adding a seeded uniform gap of 0…one diameter times the amount and optional pressure factor. It cannot reverse placement. Each upcoming gap is evaluated at the preceding dab and carried across input events.
- Lateral/linear jitter: 0–100%, independently uniform signed offsets of up to one diameter times amount and optional input factor, perpendicular/parallel to local path direction. The first dab and zero-length input use document +X as direction. Jitter does not add to path length or change the next placement anchor.
- Falloff: 0 disables it. Otherwise opacity is capped by `max(0, 1 - distance * amount / (20 * diameter))`; 100% reaches zero after 20 diameters. Overlapping earlier paint is retained. This is opacity fade, not size taper or an event counter.
- Speed spacing: 0–100%, multiplying each gap by `1 + 4 * amount * min(1, speed / referenceSpeed)`. Reference speed is adjustable 1–100,000 document px/s (default 1,000), so hardware and drawing scale can be tuned. Speed is original sample chord distance divided by valid increasing sample timestamps; missing/repeated times use zero speed. The control in Dynamics edits the same value/evaluator.
- Input factors: None = 1. Pressure uses the existing brush curve; tilt uses calibrated sensor-vector magnitude clamped to 1; barrel rotation uses `(1 + sin(angle)) / 2`. Missing channels use 1, retaining the fixed configured amount. Pressure is evidenced for spacing jitter; pressure, tilt and barrel rotation are evidenced for lateral/linear jitter. These are editable saved mappings even without current hardware, with an availability explanation. There is no inferred source pressure equation.

All placement randomness uses one stateless seed/index evaluator with independent channels. Tail rollback restores the walker input, remaining gap, traveled distance and dab index; its conservative bounds include both offset extents. Taper records retain the already shifted point and original path distance, so final replay does not randomize twice. Timestamp-only stationary updates do not create dabs; pressure/tilt/rotation changes do. Legacy automatic controls keep their existing renderer. Explicit path effects use the procedural CPU stamp implementation on both GPU-equipped and fallback machines; GPU support never silently ignores a setting.

## Supplied video reference

[Art with Flo, Make Your Own Procreate Brushes — A Beginners Guide](https://www.youtube.com/watch?v=pzp-z1TiWj4), Stroke Path chapter 3:20–4:19, supplied by the user. Browser playback was inspected at 3:35 (separated irregular stamps), 3:55 (broad scattered stamp cloud) and 4:10 (green strokes fading to a stop). The video demonstrates older combined Jitter, spacing and falloff. It does not separately demonstrate the newer spacing/lateral/linear jitter controls, speed spacing or their numerical equations. Compositor's round-tip examples should reproduce those qualitative changes; the irregular source tip in the video remains the separate Shape task's concern. Exact stamp/edge matching and source parameter equivalence are not established by this comparison.

## Native visual inspection

The Xcode-hosted AppKit/SwiftUI layout test rendered the actual 850 px Brush Editor in native, imported-inspection and round-approximation modes. The native Stroke Path panel was inspected at both scroll positions: [top](evidence/stroke-path/native-controls-top.png), [bottom](evidence/stroke-path/native-controls-bottom.png). All native path controls are active; unsupported imported rendering remains explicit. There is no new brush activation/edit gesture. These are native rendered screenshots, not a claim of owner/hardware acceptance.

The [rendered comparison examples](evidence/stroke-path/spacing-scatter-falloff.png) use the real stroke engine: top = separated round stamps; middle = lateral/linear scatter; bottom = distance-based fade to zero. Compared with the supplied video's 3:35, 3:55 and 4:10 frames, they show the same qualitative changes. The video uses an irregular tip, hand-drawn curves and unspecified scales; our example uses seeded round tips and straight paths. Edge texture, scatter distribution and exact slider/length equivalence differ or remain unqualified. The video does not qualify the newer individual jitter or speed controls; their native semantics are independently documented and tested above.

## 4K Debug measurements

Final [Xcode timing attachment](evidence/stroke-path/4k-debug-timing.txt), 18:28 run, same 2400 document-pixel path with 12 updates, blank 4000×4000 layer. No Release or display-frame timing claim. Modes: 0 = unchanged legacy automatic renderer; 1 = 25% spacing, jitter, falloff and speed response; 2 = dense automatic spacing, positional jitter and falloff.

| Diameter | Mode | Median update | Maximum update | Flush | Touched tiles |
| --- | --- | --- | --- | --- | --- |
| 40 px | Legacy | 1.05 ms | 2.70 ms | 0.62 ms | 11 |
| 40 px | Explicit spacing | 1.56 ms | 4.03 ms | 0.95 ms | 11 |
| 40 px | Dense automatic | 7.69 ms | 10.31 ms | 3.86 ms | 11 |
| 800 px | Legacy | 5.50 ms | 10.96 ms | 8.85 ms | 52 |
| 800 px | Explicit spacing | 14.81 ms | 23.78 ms | 6.34 ms | 51 |
| 800 px | Dense automatic | 101.39 ms | 113.46 ms | 60.75 ms | 69 |

The first Swift per-pixel implementation measured 350 ms for the wide explicit-spacing case. Stamp and density conversion loops now reuse the existing C pixel module. CPU gradient setup shares `brush_tip_falloff`; coverage bytes are generated at tile publication rather than per overlapping stamp, and saturated density is skipped without changing caps. Pixel/replay checks passed after these changes.

Discrete tiles use 13 core bytes/pixel here (RGBA 4 + grayscale 1 + density 4 + falloff cap 4), estimating 9.37 MB / 43.45 MB / 58.79 MB for the 11/51/69-tile cases. This is a core tile estimate, not measured peak RSS; immutable base images, provisional copy-on-write backups, snapshots and GPU buffers add memory. The runnable check rejects allocating all 256 tiles for this short band. Dense wide stamping remains substantially slower than legacy continuous coverage and is **not real-time performance qualified**. A GPU stamp implementation or additional measured acceleration remains future work; no quality-reducing dab skipping or silent spacing increase is used.

## Verification outcome

All 64 relevant tests passed through the already-open Xcode's native incremental test actions: BrushDynamicsTests 14, BrushPaletteTests 3, BrushTests 19, PenPressureTests 10, BrushIntersectionTests 4, BrushLibraryTests 6, ProcreateBrushImportTests 8. No command-line build or canary packaging was used. The native layout result had no runtime warnings. `git diff --check` passed.

The 14 dynamics tests cover persisted legacy-safe values and invalid atomic saves, sparse/dense replay, jitter extremes/different seeds, stationary mapped input and unmapped noise, zero-length/repeated samples, sharp turns, exact tail rollback and taper replay, real speed/falloff pixels, GPU-equipped/software choices, shared preview and sibling-tool defaults, transformed selected masks crossing tiles, undo/redo and save/reopen. Generated examples and timings are evidence attachments, separate from owner acceptance. Release timing, real-tablet feel and source pixel parity remain unqualified.
