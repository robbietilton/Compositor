# Brush editor gaps from supplied screenshots

October 31, 2026. Compared user-supplied screenshots with `BrushPalette.swift`, `BrushShape.swift`, `BrushDynamics.swift` and the shared stroke implementation. This is a source audit, not new device or visual-equivalence acceptance. Rendering has its separate delivery record in `rendering-brushes.md`.

## Confirmed gaps

| Tab / reference screenshot | Current implementation | Gap |
| --- | --- | --- |
| Properties · 21.49.22 | Current Size and Opacity are editable. Min/max size/opacity and Smudge Pull are disabled placeholders. | Implement actual brush-specific minimum/maximum size and opacity constraints, distinct from the current brush size/opacity. Implement Smudge Pull in the relevant tool path. Orient to Screen is absent from both the controls and the planned list. |
| Grain · 21.51.28 | Retains original grain reference/diagnostics; all Grain controls are placeholders. Brushes requiring grain remain gated. | No native Moving/Texturized grain, scale, depth, blend mode, brightness, contrast or filtering. The screenshot confirms these controls and the three filtering choices. A separate grain source preview/editor is absent. |
| Taper · 21.52.17 | Only start/end size taper lengths are active; one shared native distance-based taper. Pressure/Touch Taper groups are placeholders. | Separate pressure and touch taper behavior; graphical start/end length handles; linked tip sizes; Size, Opacity, Pressure and Tip responses; Tip Animation. The reference shows these under Pressure Taper, plus Touch Taper handles and linking. Lower cropped controls cannot be inferred from this screenshot. |
| Stabilization · 21.52.41 | Active Compositor Smoothing uses the existing trailing-string behavior. All five named reference controls are placeholders. | StreamLine Amount/Pressure, Stabilization Amount, Motion Filtering Amount/Expression. Existing Smoothing is not evidence that any of these algorithms is implemented. Screenshot shows StreamLine Amount plus stabilization/filtering/expression; StreamLine Pressure is in the existing researched inventory, outside this crop. |

Properties' percentage-based bounds also need documented native units/ranges and interaction with pressure/taper before importing source values. A current Size slider is not a Maximum Size implementation. The screenshot establishes controls, not the proprietary response equations.

## Present, with semantic or UX differences

| Tab / reference screenshot | Present | Remaining distinction |
| --- | --- | --- |
| Stroke Path · 21.53.00 | Spacing, Spacing Jitter, Lateral Jitter, Linear Jitter and Falloff all reach the renderer. | Spacing has an explicit Custom Spacing toggle/automatic mode. Falloff uses documented native distance semantics. Source percentage/response equivalence is unverified; the screenshot alone does not establish a missing control. Native numeric text fields already permit direct entry; no iPad numeric keypad is needed on macOS. |
| Shape · 21.51.58 | Touch/Mouse, Pen Azimuth and Azimuth + Barrel Rotation; stroke rotation, count, count jitter, scatter, randomized orientation and flips. | “Relative to stroke” is not established as equivalent: our switch is specifically barrel rotation relative to the initial barrel angle and is disabled outside barrel mode. Azimuth currently replaces stroke-direction orientation. The source reference's intended coordinate behavior needs verification. |
| Shape · 21.51.58 | Angular Scatter and Stroke Rotation are implemented. | Scatter is displayed in degrees, whereas the source screenshot shows a percentage. Rotation is a native −100…100% direction response, distinct from the fixed Angle control. Source scale mappings remain unverified. |
| Shape Editor · 18.43.48 | Shape import, mask polarity/alpha modes, retained originals and an 80 px mask preview. | No dedicated enlarged Shape Editor/inspection surface. Derived masks are capped at 256 × 256; that can discard source microtexture. This is a deliberate current resource bound, not proof of equivalent source detail. The screenshot's rich silhouette and internal texture cannot be recreated by Rendering controls alone. |

The Shape screenshot cuts off below Flip Horizontal; it cannot establish whether lower Shape controls are absent. The Grain screenshot cuts into “3D grain behaviour”; it establishes a separate 3D section exists in that source UI, but not its complete controls or relevance to this 2D editor.

## Tabs without enough reference evidence

No supplied control screenshot covers Wet Mix, Color Dynamics, Dynamics, Pen/Tablet (Apple Pencil), or full Dual Brush settings. Their current placeholders and limitations remain real, but are not newly verified against this screenshot set. Materials, Preview and About This Brush appear as source sidebar entries, not full control inventories. Do not add 3D Materials behavior solely to match a sidebar.

The earlier Compositor palette/editor screenshots document the old UI: Edit/delete selection controls, custom shape controls, pressure-curve editing and white/black preview changes have since been implemented. They should not be counted again as missing work.

## Suggested implementation order

1. Grain: the largest missing contributor to the textured reference stroke; implement source + sampling + deposition together, preserving missing-asset gates.
2. Properties: brush-specific size/opacity limits and Orient to Screen; distinguish editor values from bounds. Smudge Pull requires its own tool behavior.
3. Pressure/Touch Taper: independent responses and linked endpoint editing, reusing existing deterministic replay.
4. Stabilization: distinct algorithms with separate controls, preserving current Smoothing defaults.
5. Shape coordinate semantics and enlarged mask inspection; qualify detail loss with permitted local sources rather than increasing all mask sizes blindly.

No app behavior changed for this audit, and no new tasks or scope were inferred from sidebar-only entries.

## Implementation follow-up

The confirmed gaps above are implemented by the qualified native implementation described in [brush-editor-gap-implementation.md](brush-editor-gap-implementation.md). The tables preserve the pre-change audit; use the delivery record for current behavior and qualification limits.
