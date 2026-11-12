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

## Watercolor target and acceptance reference

The target is the settled result of pigment and wash interacting on textured paper, not a fluid animation or an edge-noise overlay. Keep the pigment and wash contributions distinct: pigment deposits colored mass and forms granulating/accumulated edges; wash moves across the paper texture, blends pigment strength, and can rewet and dilute existing pigment. A wet stroke with little or no pigment should therefore alter pigment already on the canvas, while a pigment-loaded wet stroke deposits both. Flow irregularity must be spatially coherent, seeded, and influenced by the paper field. Final output must be deterministic for replay, undo, and export, with stroke order preserved.

[Sighack's generative watercolor article](https://sighack.com/post/generative-watercolor-in-processing) is the closest visual reference for irregular, layered pigment: it deforms a base polygon, stacks low-opacity variations, and interleaves layers from overlapping strokes. It does not model a separate wash field or drying-edge pigment pooling; those remain part of Compositor's target. [Susan Chiang's stroke exercises](https://susanchiang.com/blog/3-watercolor-brush-stroke-exercises-to-practice-control) provide a repeatable output-quality check: consistent thin lines, thin-thick-thin pressure ramps, and dab-turn-pull strokes with controlled lift-off. Review the completed marks for edge accumulation, paper-sensitive flow, pigment dilution and blending, the underlying wash, and seeded flow variation. A preview that looks good only during movement does not pass; evaluate the settled result.

The [morphogenesis-resources flow-field section](https://github.com/jasonwebb/morphogenesis-resources#flow-field) describes a spatial vector field that can be populated from noise or image data; its [fluid-simulation section](https://github.com/jasonwebb/morphogenesis-resources#fluid-simulation) describes the velocity field carrying visible dye through advection, diffusion, shear, and blending. Applied here, the useful next experiment is a 2D wash-velocity field whose direction and magnitude respond to the local moisture gradient and paper relief, with pigment concentration transported separately and then fixed into the paper. This is distinct from the existing Brush Flow slider, which controls pigment deposition per dab, and from the seeded noise field currently used to texture edges: noise can perturb a coherent transport field, but should not stand in for the flow itself.

For branching blooms and the user's drippy reference, the repository's [Saffman–Taylor / viscous-fingering overview](https://github.com/jasonwebb/morphogenesis-resources#saffman-taylor-instability) offers a possible shape-generation analogy: small interface irregularities grow into fingers, while surface tension limits tiny wrinkles and selects a broader finger scale. It is a stylization candidate, not a validated watercolor equation. The [watercolor simulation overview](https://github.com/jasonwebb/morphogenesis-resources/issues/65) usefully separates water state, suspended and fixed pigment, drying-edge transport, and optical composition, pointing to capillary flow, advection-diffusion, paper-relief-weighted pigment fixation, and Kubelka-Munk reflectance. Treat both resources as conceptual indexes rather than implementation recipes: the current prototype and production edge pass are static, deterministic approximations. Preserve deterministic seeds and chronological stroke order, and evaluate the settled image after each transport/settling experiment. A full Navier–Stokes solver or spectral renderer is not required to improve the final image.

The generated-mask flow experiment in [watercolor_flow_shape.py](../prototypes/watercolor/watercolor_flow_shape.py) uses the supplied generated base silhouette rather than a bristle tip. It adds a paper-potential curl to boundary-driven outward flow, transports suspended pigment and water separately in short deterministic settling steps, fixes pigment into the paper, and builds an irregular inward-pooling rim. Its [rendered comparison](../prototypes/watercolor/settled_flow_shape.png) is promising as a shape-preserving direction, but still needs visual tuning and is not integrated into the app renderer.

These are target semantics, not claims about the current renderer. The existing Wet Edges, Burnt Edges, and Backruns controls remain separate approximations until they are backed by the interacting pigment/wash model above.

Native values are optional preset metadata. Missing Rendering metadata means Standard with all effects off. Other tools reset RoundBrushDynamics as before; gradient/canvas fills do not enter the rendering-stamp branch. Source-backed painting remains opt-in; required grain and unresolved components are never discarded.

Mask and eraser painting use the current mask color / destination-out operation with the new rendering coverage and threshold. RGB pickup, edge pigment color and RGB blend operators are confined to normal color painting. Native secondary originals are sampled as white-paints luminance masks; independent secondary dynamics and mask editing remain outside this minimal Normal-combine support.

## Reference and qualification evidence

User-supplied `Screenshot 2026-10-31 at 21.50.20.png` (Downloads) confirms six-mode selection, Flow, Wet/Burnt Edges, Burnt Edges mode, Blend mode, Luminance Blending, Alpha Threshold/Threshold Amount, and conditional Classic Normal Combine. Its visible stroke has both edge effects and threshold off: it establishes the control inventory, not numeric kernels or a matched edge-effect baseline. The supplied Shape and Grain screenshots show that source silhouette and grain are separate contributors to the textured result; Rendering alone cannot recreate that brush. Screenshots remain local reference material and are not bundled with the app.

The user's [Art with Flo reference, 10:48–11:49](https://www.youtube.com/watch?v=pzp-z1TiWj4&t=648s) demonstrates restrained-to-heavy deposition and spread/darker overlaps. The native comparisons below use only generated and synthetic permitted tips. Light Glaze retains restrained same-stroke buildup, later modes accumulate more, wet edges diffuse, burnt edges darken partial-coverage rims. This is a qualitative control comparison. No matched Procreate stroke capture, exact preset settings, proprietary pigment kernels, source archive enum mapping, or pixel-equivalence claim is available.

- [Six-mode atlas](evidence/rendering/rendering-six-modes.png): top to bottom Light/Uniform/Intense/Heavy Glaze, Uniform/Intense Blending; identical repeated paths and 65% stroke opacity on white. Transparent backdrops distinguish accumulation, while the separate pickup example tests existing color.
- [Pickup and tapered overlap](evidence/rendering/rendering-pickup-taper.png): native pigment pickup over a synthetic green/blue layer; final sparse/dense/deferred replay pixels agree within one byte.
- [Two-color preview](evidence/rendering/rendering-preview-two-colors.png): per-stroke paint colors survive settings replay without flattening the display-only white/black backdrop into the layer.
- [Native editor top](evidence/rendering/rendering-editor-true-top.png) and [bottom](evidence/rendering/rendering-editor-true-bottom.png): existing 850 px panel, scrollable controls, enabled secondary setup, black/white display switch and independent preview paint color.

Advanced stamps deliberately use the same CPU implementation for GPU-requested and fallback strokes unless listed in the Metal checkpoint below; unsupported combinations retain the chronological CPU implementation. Existing Standard defaults retain their previous renderer.

### Metal grain checkpoint — November 2, 2026

The tile-local Metal stamp path supports primary Moving/Texturized grain with Standard and no-pickup Light/Uniform/Intense/Heavy Glaze modes on otherwise single-tip stamps. It consumes the existing per-dab grain coordinates and deterministic jitter, scale/zoom/rotation, depth, brightness/contrast, Multiply/Screen/Overlay/Subtract, Texturized coverage cap, and mode-specific accumulation gain. Wet-tip sampling runs in this ordered Metal pass for eligible single-tip strokes with no pickup. The interactive `BrushStroke` path applies burnt-edge pooling once, after the full stroke settles, using the final coverage silhouette; direct lower-level Metal stamps still retain their separate accumulation parameter. Classic bilinear and Improved four-sample filtering compare against `brush_render_stamp`; direct dab tests cover all five mode values, and stroke tests cover CPU/Metal parity, tile crossing, and provisional tail replay. Nearest (`None`) grain filtering remains CPU-only because its discontinuous lookup showed a sparse precision mismatch.

Pickup, dual tips, stroke/edge blend operators, luminance, alpha threshold, and nearest grain filtering remain on the CPU path, so combinations using them do not enter the Metal stamp renderer. Intense Blending + wet/burnt effects remain CPU-rendered. Settled Backruns now build a deterministic transport approximation from the completed stroke silhouette: boundary normals blend with a seeded curl field and a slight downward bias; pigment blooms are sampled back along this field and a pale wash fringe is composited beyond the mask. A multiscale field controls inward branch reach. This is one final CPU pass after stroke completion, not an animated or iterative fluid simulation. Burnt edges use a continuous darker rim with seeded multifractal reach into the stroke and exponential falloff; the silhouette and edge field are generated once on mouse-up, not per dab. Backruns no longer modify pickup coverage. Bloom alpha reduction is capped to preserve the wash body and avoid a broken, punched-out texture. Wet-edge diffusion still uses a normalized five-tap cross filter (four fewer tip samples per pixel than the previous nine-tap filter), mirrored in CPU and Metal. Black pigment has little tonal range for burnt edges to darken. These remain stylized watercolor effects, not a fluid simulation. Backruns still default to zero for older presets. See [brush-performance.md](brush-performance.md#settled-watercolor-edge-checkpoint--november-2-2026) for output and timing checks.

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
