# Native brush Color Dynamics

Task `task-f5e908c6-2ae2-4398-8e76-8967a64818ea`, November 12, 2026. Implemented on current integrated `main`; no branch changes or experimental merge are part of this task.

## Audit and reuse

Color Dynamics previously contained only disabled Stamp/Stroke/Pressure/Tilt/Rotation placeholders. `PaletteColor` already represented foreground/background paint in encoded sRGB; `HueSaturationFilter` already supplied HSL conversion; `BrushStroke` already carried evolving RGB pigment, deterministic dab placement, tile backups, full-input recovery and final taper replay. The native UI already supplied validated sliders and an isolated `EditorSession` drawing pad. These are reused.

Entry points: `BrushPreset.roundDynamics` → `BrushPreset.applying` → `EditorSession.beginBrush`/`makeRasterEdit` → `BrushStroke.dynamicDab` → existing `brush_render_stamp` pigment accumulation/publication → snapshot/undo/export. The preview takes the same path. The source importer, retained-byte store and shape/grain/dual asset gates are unchanged. No source color fields are decoded or guessed; imported brushes retain their explicit native-approximation opt-in.

## Native semantics

The [official handbook](https://help.procreate.com/procreate/handbook/brushes/brush-studio-settings) distinguishes per-stamp and per-stroke variation, sensor responses and a secondary paint color. It does not supply the proprietary response equations. The following are Compositor's explicit native units and order, not certified source mappings.

All values are normalized and shown as percentages. Stroke and Stamp fields are 0–1. Sensor Hue/Saturation allow −1–1; sensor Lightness, Darkness and Secondary Color are 0–1. Every stored value and secondary RGB component must be finite and in range. Optional `RoundBrushDynamics.colorDynamics` metadata is validated by existing preset persistence and again at stroke creation. Missing metadata and an all-zero group retain the original renderer and exact output. Changing only the secondary color does not activate an unused response. Primary stroke paint is also checked for finite normalized sRGB components at stroke creation.

Secondary Paint Color is an opaque, per-brush `PaletteColor`, white by default, saved with the preset. It is independent of the app's foreground paint, global background swatch and the display-only white/black preview backdrop. Native ColorPicker conversion and `PaletteColor` are shared; no parallel color representation is introduced. Painted documents still save existing raster pixels: `.comp` format remains 21.

Each logical dab/copy first performs the existing Rendering/Wet Mix pickup. Its pigment then receives Stroke, Stamp, Pressure, Tilt and Rotation responses, in that order. Within each group:

1. Mix toward Secondary Color by the response amount in encoded sRGB components (not linear-light or spectral mixing).
2. Convert with the existing HSL helpers. Hue adds up to ±180° and wraps to [0, 360). Saturation adds a normalized delta and clamps to [0, 1].
3. Lightness pulls toward white, then Darkness scales toward black; convert back with the same bounded HSL helper. Hue alone leaves gray/black/white achromatic. Nonzero Saturation can color a gray using its canonical hue of zero.

Zero responses bypass conversion. A pure secondary response reaches either RGB endpoint exactly. Groups compose sequentially, so later sensor responses can modify an earlier random response; Darkness follows Lightness within each group. Color processing does not change Flow, coverage, stroke Opacity or the pressure-size mappings. Existing stroke blend/luminance/threshold operators still apply afterward.

Stroke random values are resolved once during stroke construction from seed channels 1300–1304. Hue/Saturation are bipolar; the other amounts use positive unit samples. Stamp uses channels 1400–1404 with stable index `dabIndex × 16 + copyIndex`, independent of tile layout, event publication or scheduling. Count is already bounded to 16 and logical dabs to 250,000 by the existing engine. No mutable color RNG state or additional rollback buffers are needed. Pigment uses the existing bounded per-tile RGB buffers.

Pressure applies only when present and uses the existing per-brush pressure curve, independently of size/opacity buttons. Tilt applies only when present and uses the existing clamped tilt magnitude. Rotation applies only when present and reuses the existing continuous `(1 + sin(angle)) / 2` response. Inputs arrive through the existing device/calibration path. Missing channels are neutral; zero-valued present channels retain their defined response (rotation zero is half strength). Saved controls remain editable without attached hardware. Physical calibration/feel is unqualified.

Stationary sensor changes also produce dabs. The shared input interpolator now preserves real endpoint samples, including a channel that has just become available; interior interpolation still requires both endpoints to carry that channel and never mixes different devices. This fixes the endpoint rather than adding guards in individual color callers.

Active color dynamics deliberately use the existing chronological CPU pigment path, for either GPU request. Eligible dry brushes without color dynamics retain Metal rendering. Masks, erase and healing strip color dynamics from their stroke-local settings; existing sibling tool setup clears native brush dynamics. Preset mappings remain intact. Tail rollback restores pigment tiles as before; full-input recovery retains the same seed, and final taper replays the same stroke response and indexed Stamp values. The existing settled watercolor wash transport remains the native foreground-colored approximation; this task does not redesign that wash simulation.

## Preview and qualification

The preview records both paint colors and the seed for every stroke. Settings replay uses each record's colors; changing the current secondary picker does not recolor historical strokes. New drawing reapplies the visible preset, so it cannot accidentally inherit the last replayed stroke's secondary color. The shared editor sliders retain numeric validation, keyboard stepping and accessible group-qualified labels.

Automated results, native UI/stroke captures and 40/800 px CPU timing are recorded below. They do not establish source equivalence, physical-device feel, HDR/spectral mixing, release performance or input-to-display latency. Real source visual comparisons remain unqualified; no user source images were fetched or bundled.


### Automated and native evidence

[Exact run summary and local xcresult paths](evidence/color-dynamics/verification.txt).

- Focused qualification: **54 tests pass**, zero failures. Includes all 25 controls changing actual pixels, finite/range/legacy validation, color endpoints and hue wrap, achromatic input, optional sensor and pressure-curve behavior, stationary newly available channels, per-copy/Stroke scope, seeded sparse/dense/deferred-taper replay, coverage preservation, transformed selections/masks/undo/export/reopen, tile invariance with grain/Wet Mix, source retention/relaunch, HSL regressions, tablet calibration and full-input recovery.
- Broader brush/import/preview/Metal/pigment/sibling qualification: **163 distinct passes, three existing failures**. The same previously independently reproduced failures remain: `BrushDynamicsTests.presetsRoundTripAndRejectInvalidDynamicsAtomically` (preset validation error), `BrushDynamicsTests.transformedTipsAndSelectedMasksPreservePixelsUndoAndReopen` (mask alpha expectation), and `CloneStampTests.cloneStampKeepsItsOwnSoftBrushTip` (default hardness expectation). No full-suite green result is claimed. Nine synthetic Procreate import cases run; the optional supplied-export test was explicitly excluded, so no real-source fixture acceptance is implied.
- Final native palette suite passes after compacting the visible labels while retaining unique accessibility names on sliders and number fields. Panel bounds remain 850 px wide and within the existing height, with scroll access through Rotation. Numeric fields retain validation and keyboard stepping. These are native AppKit test captures/code checks, separate from live owner/VoiceOver acceptance.
- `git diff --check` passes. No dependency, original source data, source mapping, document format or hardware configuration changes.

[Editor top](evidence/color-dynamics/editor-top.png), [editor bottom](evidence/color-dynamics/editor-bottom.png), [native group strokes](evidence/color-dynamics/native-groups.png), [two recorded primary/secondary pairs after replay](evidence/color-dynamics/preview-paint-colors.png). Group-stroke rows are Stroke, Stamp, Pressure, Tilt and Rotation, with the same native path/seed/brush; sensor rows use synthetic 0–1 ramps. PNG backgrounds are transparent; display them over white or black as desired. Native images were inspected and do not establish proprietary source equivalence.

A runnable focused check using the existing harness:

```sh
xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' test '-only-testing:CompositorTests/BrushDynamicsTests/colorDynamicsPreservesAlphaAndSeededTailReplay()'
```

### Wide-brush costs

[Raw timing including unchanged comparison configurations](evidence/color-dynamics/4k-timing.txt). Debug, this Mac mini, 4000 × 4000 canvas, 2400 px path, 12 updates, 25% spacing, Intense Blending, wet/burnt edges 50%, Multiply. Color Dynamics uses Stroke Hue 50%, Stamp Hue 60%, Saturation 30%, Secondary 40%. No grain or separate Wet Mix on this configuration.

| Diameter | Median update | Maximum update | Final flush | Tiles |
| --- | ---: | ---: | ---: | ---: |
| 40 px | 9.89 ms | 10.52 ms | 427.35 ms | 11 |
| 800 px | 131.62 ms | 143.45 ms | 2685.34 ms | 56 |

The corresponding no-Color-Dynamics Intense Blending case measures 9.65/141.86 ms median updates and 482.38/2682.31 ms final flushes. Existing settled edge effects dominate release cost; these numbers are a measured workload, not a claim that color variation makes painting faster. Wide effects are not 60 Hz, and mouse-up settling is visibly expensive. Release builds, physical input latency, HDR/spectral mixing, physical Wacom/Pencil feel and source visual equivalence remain unqualified.
