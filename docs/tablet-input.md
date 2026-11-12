# Capability-aware tablet input

October 31, 2026 · Task `task-fd8b0747-a907-4de7-a613-fca669387254`.

## Input and rendering

`PenInput` keeps a local AppKit monitor installed instead of stopping after the first pen event. It tracks proximity capabilities by event device ID using the SDK's `NX_TABLET_CAPABILITY_*` flags. Pressure, both tilt axes and barrel rotation are independent. Zero tilt/rotation values from a reported channel are valid; an absent channel stays nil. Unknown vendor flags do not enable tilt or rotation. A zero/absent proximity mask retains the existing pressure fallback for valid tablet-point events; this is an unverified-driver fallback, not a hardware identification heuristic.

Both native `tabletPoint` events and tablet subtypes of actual mouse events are accepted. Tablet-only properties are never read from ordinary mouse, touch/trackpad gesture or Force Touch events. A plain mouse has no pressure channel and paints at full pressure, even if pressure mappings are enabled. A reported tilt-only stylus likewise uses full pressure. Actual devices/bridges must accurately report their channels; a synthetic profile is not evidence that a bridge does so.

`BrushInput` carries validated optional pressure, tilt vector, rotation, timestamp and device ID through canvas/preview → `EditorSession` → `BrushStroke`. Pressure is finite and bounded to 0–1; missing pressure resolves to 1 only at the rendering boundary. Tilt remains AppKit's normalized sensor-space vector in [-1,1] per axis; it is not converted into a fabricated azimuth or altitude near upright. Rotation converts driver degrees to wrapped radians at capture. Its positive direction remains the driver's convention until physically calibrated. Timestamps are finite nonnegative uptime seconds; the stroke keeps valid timestamps nondecreasing even across missing values. Release completion reuses the last input rather than sampling a zero-pressure lift.

Input interpolation is linear for pressure and tilt, shortest-arc for barrel rotation, and nondecreasing for valid time endpoints. Missing endpoints/channels stay missing. Different devices are never interpolated into an invented pen orientation. Brush strokes reject a second device's samples. Windowless native tablet events update the active pen at its last known cursor position; unrelated device events do not move the stroke. Driver layouts that move a separate non-cursor pen through absolute coordinates are not mapped to document coordinates here.

Stationary pressure changes now survive position smoothing and the duplicate-position filter. The CPU fallback deposits the changed-pressure dab without changing spacing phase. The GPU's shared zero-length segment builder uses the latest pressure instead of leaving it at the segment's starting value. Metadata-only stationary updates replace the latest metadata without adding paint. The four-sample curve window remains bounded; this task does not add dwell-dependent deposition or a full stroke event log. Existing native pressure size/opacity responses remain the only implemented dynamics. Tilt/rotation transport does not enable brush effects, source mappings, squeeze, hover or double-tap actions.

## Editor and calibration

Pen / Tablet prioritizes pressure toggles, Pressure Curve and other response controls. Device status and calibration are at the bottom. Unimplemented responses stay disabled as Coming soon. Pressure mappings stay editable without a pen in range; live device availability is diagnostic and never gates saved settings. Proximity exit clears current availability and sample diagnostics; it never rewrites a preset. Drivers that omit proximity exit cannot provide reliable unplug/range detection through this event stream alone.

The editor shows reported channels, normalized tilt, barrel angle and event time. Tablet calibration offers Zero Upright Tilt, Zero Barrel Rotation, reverse X/Y/rotation and Reset Calibration. Offsets/directions use existing `ToolDefaults` persistence and remain app-wide across launches, including while no pen is available. Calibration is explicitly sensor-space and applies to all tablets on this Mac; use Reset/recalibrate when changing pens. It does not change original Procreate archives or brush presets. Near-upright tilt remains a vector and has no singular angular conversion.

No `.comp` or brush collection format change is required. Existing source settings and pressure mapping flags remain intact. Debug unit tests now use the app's existing local ad-hoc signing configuration so Xcode can run them without a development certificate; Release signing is unchanged.

## Apple Pencil and hardware evidence

The input path has no Wacom-only or Apple-Pencil-only branch. Apple Pencil generations 1/2, USB-C and Pro are covered by whichever channels their macOS connection actually exposes, including a compatible iPad using [Sidecar](https://www.apple.com/macos/continuity/). [Apple's feature comparison](https://www.apple.com/apple-pencil/) distinguishes the USB-C model's tilt without pressure from Pro's pressure/tilt and barrel roll. These hardware features do not prove the same channels arrive through Sidecar. Unknown/unreported barrel roll remains unavailable, even for Pencil Pro.

Apple documents [Touch on the new PROLED XDR MacBook Pro](https://www.apple.com/macbook-pro/proled-xdr-display/specs/), while the current [Apple Pencil compatibility list](https://support.apple.com/en-gb/108937) does not list MacBooks. Touch support alone does not establish direct Pencil digitizer compatibility. Direct Pencil-on-Mac support remains unverified; valid AppKit stylus events will use the same path if the OS supplies them. No guessed device-generation table or speculative direct-touch adapter is added.

Local IORegistry inspection found a Wacom Wireless Receiver digitizer. The user identified the tablet as PTH-851/K. That confirms the hardware target/receiver, not live pen pressure/tilt, axis direction, barrel support or calibration. [Wacom lists the PTH851 as compatible with its rotation-sensitive Art Pen](https://estore.wacom.com/en-us/art-pen-kp701e2.html); the tablet model alone cannot identify the pen or enable rotation. No real pen movement or Sidecar/Pencil session has been qualified by the agent.

## Verification and remaining acceptance

Xcode-native verification passed 35 tests: 10 PenPressureTests, 19 BrushTests, 4 BrushIntersectionTests and 2 BrushPaletteTests. Checks ran incrementally through the already-open Xcode project; no additional command-line builds or canary packaging followed the user’s workflow correction.

`PenPressureTests` exercises native and mouse-subtype tablet capture, supported zero values, pressure-only/tilt-only/rotation-only profiles, zero-mask fallback, ordinary mouse/Force Touch fallback, invalid values, angle wrap, optional-channel interpolation, device switches, monotonic timestamps across missing values, neutral calibration, axis reversal, proximity exit/reentry, stationary hard/soft pressure changes with GPU requested and forced CPU fallback, smoothing, windowless native events and preview replay. Synthetic cases representing Pencil channel differences are not branded-device acceptance tests. `BrushPaletteTests` checks the existing isolated drawing preview and editor layout.

Physical acceptance remains open:

1. PTH-851/K: open Pen / Tablet, bring the actual pen into range and record reported channels; lift out of range and confirm controls disable while mappings remain checked. Compare pressure ramps and stationary pressure in canvas and preview.
2. Hold upright and zero tilt. Lean right/left and toward/away from the display; verify signs and reset/reverse as needed. Check near upright for stable finite values. Test barrel zero/direction/wrap only with a pen that reports rotation.
3. Repeat with Apple Pencil 1/2, USB-C and Pro through compatible iPads/Sidecar where available. Specifically verify full-strength pressureless input, reported tilt, Pro barrel availability, reconnection and release behavior. Do not claim Sidecar channel support from model branding.
4. Run native UI acceptance after the requested pressure-first ordering. No physical calibration, direct MacBook Pencil support or Apple Pencil event stream is certified by automated checks.

API evidence: [Apple's tablet event handling guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTabletEvents/HandlingTabletEvents.html) explicitly includes native pressure-only events; [capabilityMask](https://developer.apple.com/documentation/appkit/nsevent/capabilitymask) is a driver-provided mask, and the installed SDK's `IOKit/hidsystem/IOLLEvent.h` supplies the standard channel masks. Driver semantics and physical calibration remain separate from input validation.

## Native property response follow-up · November 12, 2026

[Native pen property responses](pen-brush-responses.md) implements the remaining pressure Flow/Bleed, individual curves, tilt shading/properties and named barrel-property mappings through this same transport. Hardware qualification remains in the original tablet task; no physical acceptance checkbox is closed by the synthetic/property work.
