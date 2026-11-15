# Native pen property responses

November 12, 2026 · Task `task-e14cdc34-007a-4728-ade2-caaac89d116f`.

The Pen / Tablet editor now implements Pressure Flow, Pressure Bleed, individual property curves, Tilt Response and Barrel Rotation for renderable brushes. Existing pressure size/opacity toggles and global curve, Shape orientation/roundness, Stroke Path mappings and app-wide sensor calibration are reused. Imported source equations remain unmapped; original archives and missing-component gates are preserved. This is native behavior, not Procreate visual equivalence. The [official settings reference](https://help.procreate.com/procreate/handbook/brushes/brush-studio-settings) informed the named scope; proprietary equations are not inferred from those names.

## Responses and order

`RoundBrushDynamics.penDynamics` is optional validated brush-library metadata. Nil/default amounts preserve legacy behavior. Amounts are finite signed percentages from −100 to 100; curves reuse `PressureCurve` validation and its 16-point limit. Pressure size/opacity each optionally refine their existing enabled mapping. Pressure Flow/Bleed, Tilt Size/Opacity/Flow/Bleed/Gradation and Barrel Rotation Size/Opacity/Flow/Bleed each have an independent optional curve. Controls remain editable without hardware. No new `.comp` field or version bump is required.

Inputs use the existing calibrated `BrushInput` transport. Pressure uses the existing global curve before its individual curve. Tilt uses clamped sensor-vector magnitude, including valid upright zero. Barrel uses the existing continuous `(1 + sin(angle)) / 2` signal; zero angle means half response, with no seam at ±π. This is an absolute sensor response; relative-to-stroke orientation remains the separate Shape control. Missing channels skip their mappings, including individual pressure curves, so a mouse retains full pressure and a pressureless tilt device can still shade. Existing shortest-angle interpolation, channel-loss handling and device isolation are reused.

For signed amount `a` and property-curved input `v`, the signal is `abs(a) × (a >= 0 ? v : 1-v)`. Size, opacity and flow use the multiplicative gain `1-abs(a)+signal`; zero amount is identity. Pressure size/opacity begin at the existing enabled pressure response. Tilt/barrel gains multiply those values. The nominal diameter and opacity remain maxima; existing minimum size/opacity floors apply after sensor gains. Taper and path opacity falloff apply afterward; speed and spacing remain governed by existing Stroke Path settings.

Bleed adds to Rendering Wet Edges using `b += (1-b) × signal`, once for each present mapped channel. It drives the existing five-tap diffusion, not pigment pickup or a new fluid simulation. Signed amounts reverse the input direction, never create negative diffusion. Shared dab/tail bounds now account for the rasterizer's actual 0.36-radius diffusion spread instead of the stale 0.2 value.

Tilt Gradation softens procedural hardness by `1-signal` and reduces per-dab flow by `1-0.75×signal`; the flow reduction also affects image tips. Wet Mix Grade can subsequently harden the deposited profile. Effective flow combines base Flow, sensor gains, gradation and existing Wet Mix reservoir/attack/dilution. Reservoir consumption uses the sensor-adjusted flow. Pickup, Color Dynamics, grain and settled-edge processing retain their existing order. This native shading approximation is explicitly separate from source gradation, size compression or source brush equations.

Active sensor amounts use the existing chronological CPU stamp path. Custom pressure size/opacity curves alone may use existing Metal stamp coverage. Zero/default metadata does not change renderer selection. Stationary mapped sensor changes produce dabs, including pressure availability changing under a custom pressure curve. Existing tail rollback, seeded replay, batch publication and full-input recovery apply unchanged. Masks and erasing keep these coverage responses, as they keep pressure size/opacity; pigment Color Dynamics/Wet Mix remain stripped by their existing policy. Other tools continue to clear brush dynamics through existing session setup.

## Qualification

Runnable checks live in `BrushDynamicsTests`, `BrushLibraryTests`, `BrushRecoveryTests`, `PenPressureTests` and `BrushPaletteTests`. Pixel tests cover every named response, nil/default equivalence, missing channels, pressureless tilt, upright tilt, angle wrap, wet spread bounds, stationary input, batching and tapered replay. Existing input tests cover calibration signs, independent capabilities, channel loss and device switching. Library checks cover round-trip/relaunch, atomic invalid-metadata rejection and retained source bytes/gates; recovery preserves the settings and full input.

Final qualification passes **136 selected tests**, excluding three previously reproduced baseline failures and the optional supplied-source fixture. Native UI captures and exact commands/results are recorded in [verification](evidence/pen-responses/verification.txt). [Editor top](evidence/pen-responses/editor-top.png), [editor bottom](evidence/pen-responses/editor-bottom.png) and [native response pixels](evidence/pen-responses/native-responses.png) were inspected. The editor device state in these AppKit test captures is synthetic. These are separate from live owner/VoiceOver acceptance and source visual comparisons. No source-equivalence result is claimed.

Physical acceptance remains owned by tablet task `task-fd8b0747-a907-4de7-a613-fca669387254`; its hardware checkbox remains open. No operator-driven PTH-851/K pen gestures, identified rotation-capable pen or Sidecar/Pencil session was available to qualify this work. Actual channel reporting, zero/reverse calibration, full-range pressure, shading feel and barrel response still need an operator with those devices. Synthetic channels do not qualify hardware or input-to-display latency.

To run the property regressions with the existing harness:

```sh
xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' test \
  -only-testing:'CompositorTests/BrushDynamicsTests/penResponsesEvaluateCurvesAndMissingChannels()' \
  -only-testing:'CompositorTests/BrushDynamicsTests/penResponsesChangePixelsAndDefaultsStayExact()' \
  -only-testing:'CompositorTests/BrushDynamicsTests/penResponsesKeepStationaryChannelsAndCoverageTools()'
```
