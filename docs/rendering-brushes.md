# Native brush Rendering

Task `task-557e554b-5e29-4257-9f0e-61bdda72018b` · October 31, 2026.

## Audit and implementation contract

Existing flow/opacity, deterministic placement, shape sampling/filtering, per-tile density/caps, provisional-tail backups, selection clipping, color management, undo/export and isolated preview are reused. Before this delivery, Rendering exposed Flow only; color pickup, modes, edge treatment, threshold, stroke/edge blending and dual-normal composition were absent. Legacy masks are one-channel coverage painted with one fixed color.

The [official handbook](https://help.procreate.com/procreate/handbook/brushes/brush-studio-settings) identifies six rendering modes and the listed controls, but does not specify their kernels or versioned archive field mappings. No numeric source mapping is guessed. Original archives and unsupported values remain retained. The following are explicit Compositor semantics, not reconstructed proprietary equations.

| Control | Observable native semantics |
| --- | --- |
| Standard | Existing optical-density accumulation and stroke opacity cap; default remains unchanged. |
| Light Glaze | Maximum single-dab density at 0.35 gain; repeated passes inside one stroke remain restrained. |
| Uniform Glaze | Additive optical density at 0.5 gain. |
| Intense Glaze | Additive optical density at 1.5 gain. |
| Heavy Glaze | Additive optical density at 3 gain; no color pickup. |
| Uniform Blending | Additive density at 1 gain, carries/mixes 35% of sampled existing pigment per dab. |
| Intense Blending | Additive density at 2 gain, carries/mixes 65% per dab. |
| Flow / Opacity | Flow scales each dab before accumulation; Opacity applies to completed stroke coverage. |
| Wet Edges | Five-tap local tip diffusion, up to 0.2 normalized tip units; conservative expanded bounds retain the bleed. |
| Burnt Edges | Accumulated partial-coverage rim pigment, composited using the selected edge blend mode. |
| Stroke Blend Mode | Existing layer blend modes, including shared Core Image fallbacks, applied to the whole deposited stroke over original tile pixels. |
| Luminance Blending | Applies the resulting blend's lightness over the original destination hue/chroma using the native luminosity operator. Transparent destinations receive the deposited color. |
| Alpha Threshold | Optional binary threshold after pressure/flow/stroke opacity, before color compositing. |
| Dual / Classic Normal | Explicit secondary tip: modern native mask intersection versus classic source-over union. Primary/secondary share placement; full independent Dual Brush dynamics remain separate. |

Color pickup samples the evolving pigment state before final edge and stroke-blend composition, with selection coverage applied to deposited pigment at the dab center, in layer-pixel coordinates, independent of event batching/publication. Carried color and all per-tile density/pigment/edge state participate in provisional rollback and final taper replay. Advanced rendering uses the shared CPU stamp implementation for either GPU request; legacy defaults retain the existing fast path. Grain and unresolved dual assets remain explicit limitations. No separate Wet Mix controls are claimed.

Native values are optional preset metadata. Missing Rendering metadata means Standard with all effects off. Other tools reset RoundBrushDynamics as before; gradient/canvas fills do not enter the rendering-stamp branch. Source-backed painting remains opt-in; required grain and unresolved components are never discarded.

Mask and eraser painting use the current mask color / destination-out operation with the new rendering coverage and threshold. RGB pickup, edge pigment color and RGB blend operators are confined to normal color painting. Native secondary originals are sampled as white-paints luminance masks; independent secondary dynamics and mask editing remain outside this minimal Normal-combine support.

## Reference and qualification evidence

User-supplied `Screenshot 2026-10-31 at 21.50.20.png` (Downloads) confirms six-mode selection, Flow, Wet/Burnt Edges, Burnt Edges mode, Blend mode, Luminance Blending, Alpha Threshold/Threshold Amount, and conditional Classic Normal Combine. Its visible stroke has both edge effects and threshold off: it establishes the control inventory, not numeric kernels or a matched edge-effect baseline. The supplied Shape and Grain screenshots show that source silhouette and grain are separate contributors to the textured result; Rendering alone cannot recreate that brush. Screenshots remain local reference material and are not bundled with the app.

The user's [Art with Flo reference, 10:48–11:49](https://www.youtube.com/watch?v=pzp-z1TiWj4&t=648s) demonstrates restrained-to-heavy deposition and spread/darker overlaps. The native comparisons below use only generated and synthetic permitted tips. Light Glaze retains restrained same-stroke buildup, later modes accumulate more, wet edges diffuse, burnt edges darken partial-coverage rims. This is a qualitative control comparison. No matched Procreate stroke capture, exact preset settings, proprietary pigment kernels, source archive enum mapping, or pixel-equivalence claim is available.

- [Six-mode atlas](evidence/rendering/rendering-six-modes.png): top to bottom Light/Uniform/Intense/Heavy Glaze, Uniform/Intense Blending; identical repeated paths and 65% stroke opacity on white. Transparent backdrops distinguish accumulation, while the separate pickup example tests existing color.
- [Pickup and tapered overlap](evidence/rendering/rendering-pickup-taper.png): native pigment pickup over a synthetic green/blue layer; final sparse/dense/deferred replay pixels agree within one byte.
- [Two-color preview](evidence/rendering/rendering-preview-two-colors.png): per-stroke paint colors survive settings replay without flattening the display-only white/black backdrop into the layer.
- [Native editor top](evidence/rendering/rendering-editor-true-top.png) and [bottom](evidence/rendering/rendering-editor-true-bottom.png): existing 850 px panel, scrollable controls, enabled secondary setup, black/white display switch and independent preview paint color.

Advanced stamps deliberately use the same CPU implementation for GPU-requested and fallback strokes. Their outputs agree in tests; this does not qualify a separate Metal effect implementation or force Core Image's blend operator to software. Existing Standard defaults retain their previous renderer.

### Metal grain checkpoint — November 2, 2026

The tile-local Metal stamp path now supports primary Moving/Texturized grain for otherwise Standard, single-tip stamps. It consumes the existing per-dab grain coordinates and deterministic jitter, scale/zoom/rotation, depth, brightness/contrast, Multiply/Screen/Overlay/Subtract, and Texturized coverage cap. Classic bilinear and Improved four-sample filtering compare against `brush_render_stamp`; end-to-end Moving and Texturized stroke pixels also compare within one byte. The CPU path remains the fallback for nearest (`None`) grain filtering: its discontinuous lookup showed a sparse CPU/Metal precision mismatch, so that mode is intentionally not declared equivalent yet.

All non-Standard Rendering modes, pickup, wet/burnt edges, dual tips, stroke/edge blend operators, luminance, and alpha threshold remain on the existing CPU implementation. In particular, the 800 px Intense Blending + wet/burnt workload has not moved to Metal. No performance gain is claimed from this functional grain port. Release, visual comparison, and physical-device qualification remain outstanding.

## Performance

Xcode Debug on this Mac mini, 4K canvas, 2400 px path, 12 updates, 25% spacing, wet/burnt edges 50%, Multiply. [Raw timing](evidence/rendering/rendering-4k-timing.txt).

| Diameter | Mode | Median update | Maximum | Final flush | Tiles |
| --- | --- | ---: | ---: | ---: | ---: |
| 40 px | Uniform Glaze | 11.1 ms | 12.1 ms | 6.9 ms | 11 |
| 40 px | Intense Blending | 11.8 ms | 12.3 ms | 7.0 ms | 11 |
| 800 px | Uniform Glaze | 134.2 ms | 148.5 ms | 83.3 ms | 56 |
| 800 px | Intense Blending | 147.6 ms | 157.4 ms | 125.6 ms | 56 |

Shared C pixel publication replaces the initial Swift per-pixel loops, reducing these medians from about 251/252/2113/2250 ms respectively. This measures the test workload rather than input-to-display latency. Wide advanced effects remain slower than interactive 60 Hz; release builds, continuous physical-tablet input, HDR color pickup, and device feel are not qualified. Effect working buffers are 8-bit sRGB; untouched high-depth source preservation follows the existing raster pipeline.

[Edge/threshold/blend atlas](evidence/rendering/rendering-edges-threshold-blends.png), top to bottom: Standard single dab, Wet 100%, Burnt 100% Multiply, Burnt 100% Screen, binary threshold, ordinary paint over green/blue, Multiply, Screen, and luminance. The single-dab edge changes are subtle at this size; overlap darkening is stronger in the editor stroke. [Modern dual intersection](evidence/rendering/rendering-dual-modern.png) versus [Classic union](evidence/rendering/rendering-dual-classic.png) uses an asymmetric primary and independent speckled secondary, preserving both originals.

## Verification record

All runs use the already-open Xcode Compositor scheme, Debug, My Mac; no clean build or alternate DerivedData checkout. 100 distinct targeted tests passed:

| Suite | Passing tests |
| --- | ---: |
| BrushDynamicsTests | 31 |
| BrushPaletteTests | 7 |
| BrushTests | 19 |
| ProcreateBrushImportTests | 10 |
| BrushLibraryTests | 6 |
| CloneStampTests | 2 |
| SpotHealingTests | 2 |
| BlurBrushTests | 1 |
| GradientTests | 8 |
| PenPressureTests | 10 |
| BrushIntersectionTests | 4 |

Coverage includes all blend operators, binary alpha and untouched translucent pixels, distinct modes and caps, owned dual components/missing asset gates, mask and normal color painting on transformed selected layers, undo/redo, raster export and `.comp` reopen, settings JSON/relaunch/invalid-write atomicity, preview replay, and sibling tool defaults. Existing full-suite failures are outside these targeted results; a full-suite green result is not claimed.

The native palette test run retains the previously reported Thread Performance Checker warning at initial AppKit panel construction (user-interactive waiting on Default QoS). No new engine runtime warning appeared. Automated tests and native panel images are evidence of behavior/layout, not physical Wacom PTH-851/K or Apple Pencil acceptance. No physical device replay or release performance result was collected in this delivery.
