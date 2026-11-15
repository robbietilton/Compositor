# Procreate brush settings and shape research

Research date: October 31, 2026. This records documented behavior and observed exports, not verified Procreate rendering equations or archive-field mappings.

## Brush Studio settings

The [official settings handbook](https://help.procreate.com/procreate/handbook/brushes/brush-studio-settings) describes the controls below. Advanced settings may map pressure, tilt or rotation to individual parameters; availability varies by version.

- Stroke Path: spacing, spacing jitter, lateral and linear jitter, falloff.
- Stabilization: StreamLine amount and pressure, stabilization amount, motion filtering amount and expression.
- Taper: pressure and touch taper, start and end lengths, linked size, size, opacity, pressure, tip, tip animation and classic taper.
- Shape: source image, orientation/input style, rotation, scatter, count and count jitter, randomization, horizontal and vertical flips, roundness and angle, roundness jitter and filtering.
- Grain: source image, moving or texturized behavior, movement, scale, zoom, rotation, depth and depth jitter, offset jitter, blend mode, brightness, contrast and filtering; source editing supports tiling.
- Rendering: light, uniform, intense and heavy glaze; uniform and intense blending; flow, wet and burnt edges, edge and stroke blend modes, luminance blending, alpha threshold and classic dual-normal behavior.
- Wet Mix: dilution, charge, attack, pull, grade, blur, blur jitter and wetness jitter.
- Color Dynamics: stamp and stroke color jitter, plus pressure, tilt and rotation mappings for color properties.
- Dynamics: speed affects size, opacity and spacing; random jitter affects size and opacity.
- Pen: pressure curve and individual property response, pressure size/opacity/flow/bleed, tilt response and shape orientation, and barrel rotation where supported.
- Properties and preview: size and opacity bounds, smudge pull and preview settings. Dual brushes combine two separately configured brushes.

[Procreate 5.4 release notes](https://help.procreate.com/articles/Ls9oMu-procreate-5-4-update-at-a-glance) identify newer settings including speed-based spacing, spacing and roundness jitter, alpha threshold and per-brush pressure graph. The [official brush-making masterclass](https://help.procreate.com/articles/HqcYCo-kyle-t-webster-s-brush-making-masterclass) demonstrates settings in context. The handbook includes screenshots; earlier versions do not necessarily show current controls. Screenshot appearance is not a specification of brush math.

## Pen support in Compositor

The [capability-aware input implementation](tablet-input.md) now transports optional pressure, sensor-space tilt, timestamp and reported rotation; physical Wacom/Pencil calibration remains open. Present a general Pen or Tablet section rather than an Apple Pencil-only section. Preserve mappings regardless of connected hardware and enable individual inputs based on actual device capabilities. Compositor already carries tablet pressure into size and opacity. [AppKit NSEvent](https://developer.apple.com/documentation/appkit/nsevent) exposes pressure, tilt, rotation and tablet proximity information; [tilt](https://developer.apple.com/documentation/appkit/nsevent/tilt) is valid only for tablet events and relevant mouse subtypes. Rotation varies by hardware and driver. Validate tilt conversion, azimuth and calibration against actual devices, including near-upright input. Mouse fallback remains full pressure.

## Shape sources and archive evidence

The [Procreate 5.3 handbook](https://help.procreate.com/procreate/handbook/5.3/brushes/brush-studio-settings) describes more than 150 built-in shape sources and 100 grain sources. The [current official source-library screenshot](https://cdn.sanity.io/images/skm640rd/production/80e8a01851b2116fb0a30e337b543e6d97779e74-2752x2064.png?auto=format&w=720) shows irregular ink shapes; it is not a complete catalog.

A scan of the supplied modern brush sets and Classic Library found 490 non-reset definitions (263 modern, 227 classic), including secondary components, and 282 distinct non-null shape references. Counts below describe definitions, not selectable brushes. Warptuner and standalone Gggg are excluded from those counts.

| Referenced built-in asset | Definitions | Evidence |
| --- | ---: | --- |
| Brush-Preset-Soft.png | 16 | Referenced, image absent; name suggests softness but does not establish geometry or falloff. |
| Brush-Preset-Medium.png | 12 | Referenced, image absent. Warptuner also references it. |
| Brush-Preset-Hard.png | 12 | Referenced, image absent; user confirmed standalone Gggg using it is a simple round brush. |
| Brush-Preset-Medium-Hard.png | 10 | Referenced, image absent; used by classic Gel Pen and Studio Pen. |
| Brush-Preset-Ultra-Soft.jpg | 2 | Referenced, image absent; used by classic Fine Tip and Soft Blend. |

Only three definitions had the referenced image in their own brush folder: Palm Husk, Limestone, and Volcanic Ash. Volcanic Ash references GL-Volcanic-Grain.png as its shape even though a similarly named shape image is also present: resolve the actual path rather than guessing from the filename. Other archives may use embedded custom images under arbitrary names.

A procedural hard circle is a reasonable starting approximation for the confirmed round tip; adjustable soft round falloff is a candidate for the other named presets, pending visual testing. Filenames do not prove the original pixels, exact softness, UI names, or appearance. Preserve unknown references, surface unsupported assets, and compare rendered strokes with Procreate.

The Classic Library outer ZIP contains individual .brush ZIPs; modern .brushsets contain brush directories. Both carry NSKeyedArchiver binary property lists. Those containers, dual-brush subdirectories, reset archives, and embedded versus built-in asset references must be handled explicitly. The earlier research note's suggestion to defer Procreate import and its statement that pressure is absent are superseded by the user's compatibility goal and current implementation.

## Import and shape mapping proposal

Procreate compatibility is a primary design goal. Loading a brush and reproducing its appearance are separate milestones: report supported and unsupported behavior honestly. The native importer is now implemented; see [import implementation and validation](procreate-brush-import.md). Exact basic-source identities and explicit native round approximations are now implemented; see [mapping and calibration limits](basic-brush-mappings.md). Soft falloffs remain uncalibrated, and successful parsing does not establish matching rendering.

At import time, decode the archive in native Compositor code and resolve the shape reference in this order:

1. Use the image explicitly referenced by the brush when it is embedded in that brush's archive or folder. Resolve paths relative to the owning brush, including dual-brush components.
2. For a recognized built-in reference whose image is absent, map it to a Compositor shape. The initial candidates are `Brush-Preset-Hard.png` to a hard round tip and the Soft, Medium, Medium-Hard, and Ultra-Soft references listed above to separately tuned round falloffs. Only the Hard reference has been confirmed as round by the user; the others remain approximations to validate.
3. For an unresolved reference, report the missing shape and retain the brush data. Do not silently present a substituted tip as an accurate import.

Use the existing procedural round-tip rendering for basic shapes when practical: it avoids shipping raster assets and keeps package size small. Embedded or custom irregular tips still need image-based rendering. Texture grain is a separate source and must be resolved independently; this proposal does not claim its references correspond to round shapes.

Preserve the original asset references, archive settings, unsupported values and enough source data to remap or reimport later. Apply the mapping in Compositor's imported representation instead of destructively rewriting the source brush file. Keep mappings centralized and explicit; avoid matching unrelated user assets by basename alone. A future mapping improvement should be able to update the imported result without requiring a fresh export from Procreate.

Validate mappings using the supplied Gggg round brush, Warptuner and the classic and modern libraries. Compare pressure ramps, multiple sizes, overlap and edge profiles with reference strokes in Procreate; names alone cannot establish exact falloff. Check embedded-asset precedence, unknown-asset reporting, preservation of original references, dual brushes and behavior when the referenced image is absent. Pen response requires real-device testing. A successful parse or procedural approximation does not establish visual parity.

## Native core dynamics implementation

The [native round-brush dynamics implementation](round-brush-dynamics.md) now supplies an editable monotone pressure curve, spacing, flow, distance-based size taper and ellipse/count/angular-scatter controls. These are Compositor overrides, not decoded Procreate equations. Unimplemented source behavior remains preserved and disabled.

The [native Shape implementation](shape-brushes.md) now supports bounded embedded/custom image masks and the researched Shape controls with explicit native semantics. Original references, grain/dual ownership and source bytes remain preserved; source equations and hardware feel are not certified.
