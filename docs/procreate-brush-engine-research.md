# Procreate brush engine research and a path for Compositor

Research date: October 30, 2026. This is a research and implementation proposal; no engine changes have been made.

## Finding

Compositor can develop a similar range of brush behavior by extending its existing engine. Its sparse tiles, stroke previews, transforms, and snapshot commits are useful foundations. The highest-value additions are expressive tablet input and textured tips, followed by controlled paint buildup and color pickup. Rebuilding the renderer or reproducing every Brush Studio setting is unnecessary for a first version.

The public material describes observable behavior, not the implementation of Procreate's shaders. Procreate identifies Valkyrie as Metal-native, but this does not establish its tile layout, sampling algorithm, latency, pigment model, or internal precision. Those details remain unverified. [Procreate's engine history](https://procreate.com/insight/2021/10-years).

## What is publicly documented

A brush combines a shape with grain. Brush Studio exposes controls for responsiveness, color variation, rendering, and wet media, with a drawing pad for immediate feedback. Wet Mix includes loading paint and mixing or dragging it through existing color. The useful lesson is that the brush appearance comes from interacting components and tuned presets. [Brush Studio overview](https://help.procreate.com/procreate/handbook/brushes/brush-studio).

The current handbook describes 14 adjustable attributes. Stroke spacing controls repeated shape placement; jitter varies the path or spacing. Stabilization and taper modify stroke behavior. Shape settings vary orientation and geometry; grain supplies texture. Rendering changes accumulation and blending. Dynamics respond to speed and randomness, while pressure and tilt can control multiple properties. Recent settings also accommodate Apple Pencil Pro barrel rotation. These are behavioral requirements to evaluate individually, rather than proof of a particular algorithm. [Brush Studio settings](https://help.procreate.com/procreate/handbook/brushes/brush-studio-settings).

The older versioned handbook makes an especially useful distinction: moving grain travels with the stroke, whereas texturized grain behaves like a stationary surface revealed through the brush. Grain scale, depth, rotation, and blending alter the result. It also distinguishes glazed rendering from blending-oriented rendering and describes wet controls such as dilution, charge, attack, and pull. These labels describe artistic outcomes; they do not specify physical simulation equations. [Procreate 5.3 settings](https://help.procreate.com/procreate/handbook/5.3/brushes/brush-studio-settings).

Kyle T. Webster's official masterclass demonstrates the interaction concretely: an ink brush couples pressure to size; a pencil combines grain, flow, pressure, and tilt; oil brushes use blending, grain, and wet-edge controls. The workshop is a stronger reference for creating acceptance examples than a checklist of isolated sliders. Its source images affect the outcome, so matching numeric settings alone will not reproduce a brush. [Official brush-making masterclass](https://help.procreate.com/articles/HqcYCo-kyle-t-webster-s-brush-making-masterclass).

Procreate imports `.brush`, `.brushset`, `.brushlibrary`, and Photoshop `.abr` files. The import documentation is not a file-format specification or a promise that another engine can reproduce those brushes. Treat compatibility as a separate investigation requiring sample files and mappings, after Compositor's own brush behavior works. [Importing brushes](https://help.procreate.com/articles/daaqbd-importing-your-brushes).

## What Compositor already has

The current flow is `CanvasView` → `EditorSession.beginBrush/continueBrush` → `BrushStroke.append` → tile coverage/composition → `commitPaintSnapshot`. Inspect [canvas input](../Compositor/Rendering/EditorCanvas.swift), [session operations](../Compositor/Document/EditorSession+Brush.swift), and [stroke implementation](../Compositor/Document/BrushStroke.swift).

| Area | Current behavior | Implication |
| --- | --- | --- |
| Storage | Writable 256 px tiles; immutable raster snapshots | Preserve touched-tile allocation and shared unchanged tiles. |
| Input | Brush operations receive `CGPoint` | Pressure, tilt, and sample time do not reach the brush. |
| Path | Curved interpolation with a replaceable provisional tail | Reuse it; any new random or wet state must survive tail replacement correctly. |
| Stabilization | A screen-space rope follows the pointer | Separate this from curve interpolation; avoid a duplicate smoothing feature. |
| Tip | Round hard/soft coverage; CPU fallback stamps | Custom texture support is a new capability, not just a UI addition. |
| GPU | Continuous round-tip sweep, soft optical-density accumulation | Preserve this efficient path for ordinary round brushes. |
| Color | Uniform paint color through grayscale coverage; stroke opacity cap | Per-dab color and wet mixing need richer state. |
| Smudge | `WarpStroke` carries RGBA pixels and deposits/picks up color | Existing pickup logic is a useful starting point. |

[MetalBrushCoverage](../Compositor/Rendering/MetalBrushCoverage.swift) waits for GPU completion and copies preview coverage into CPU-owned contexts. It is GPU-assisted, not an entirely GPU-resident painting/display pipeline. Measure this boundary before proposing an asynchronous rewrite.

[SmudgeLiquify](../Compositor/Document/SmudgeLiquify.swift) currently allocates a document-size working context, unlike the tiled paint path. Reuse its pickup/deposit concepts for wet painting, but do not copy its full-canvas allocation into every paint stroke. Existing [performance documentation](brush-performance.md) records historical measurements; they are not new measurements from this research.

## Recommended implementation sequence

The following is a Compositor proposal, not a reconstruction of Valkyrie.

1. **Carry expressive samples.** Extend the real input path with position, timestamp, pressure, and available tilt. AppKit already exposes [pressure](https://developer.apple.com/documentation/appkit/nsevent/pressure) and [tilt](https://developer.apple.com/documentation/appkit/nsevent/tilt). Read them only on valid event kinds/subtypes. Use device capabilities and an explicit full-pressure mouse fallback; ordinary mouse zero values must not make strokes disappear. Apple's [associated event guidance](https://developer.apple.com/documentation/appkit/nsevent/associatedeventsmask) distinguishes pressure-capable devices and tablet mouse events. Preserve stationary pressure changes instead of rejecting every duplicate position. Start with pressure-to-size and a small editable response curve for hardware calibration.

2. **Add textured stamping alongside the round fast path.** Accept a grayscale/alpha tip image and an optional repeating grain image. Reuse current tile allocation, mapping, clipping, preview, and commit behavior. Generate dabs by traveled distance, carrying spacing remainder across input events. Start with tip rotation, spacing, and fixed canvas grain; then add moving grain and limited scatter. Changing event frequency should not change material density. Seed randomness per stroke and restore the dab index, spacing phase, and random state when replacing a provisional tail, so texture does not flicker.

3. **Separate flow and opacity.** Keep the current stroke-wide cap for existing brushes. Add per-dab deposition strength for textured buildup, with explicit accumulation semantics. A single grayscale coverage image still suffices for constant-color dry brushes; defer RGBA stroke state until color variation or wet mixing requires it.

4. **Ship a small preset collection.** Target round paint, pressure ink, grainy pencil, dry bristle, and a scattered texture brush. Store only implemented settings and required image assets. A compact preset picker and shared live preview are enough initially. Route preset behavior only through intended paint/erase callers. Preserve healing, clone, blur, mask, gradient, selection-edit, and cursor-preview behavior; `BrushStroke` and `makeRasterEdit` also serve those paths.

5. **Add wet paint after the dry brushes feel right.** Introduce a limited paint reservoir, pickup, and deposition on touched tiles, drawing on existing smudge behavior. Wet operations depend on previous color and ordering: tail rollback must restore both pixels and reservoir state. Do not describe simple RGBA interpolation as spectral pigment mixing or watercolor simulation. Tune with painted examples before exposing many wet controls.

## Reuse option and boundaries

[libmypaint](https://github.com/mypaint/libmypaint) is an existing C brush engine under the ISC license, with `json-c` among its dependencies. It is worth studying or prototyping if broad painting behavior becomes more valuable than close integration with the current Metal path. Adopting it would still require surface callbacks, transforms, clipping, history, previews, packaging, and performance verification. It is not a drop-in Procreate engine. The [official MyPaint brush collection](https://github.com/mypaint/mypaint-brushes) requires public-domain/CC0 brush submissions, making it a potential source for evaluation assets; verify each asset's accompanying license before redistribution.

Defer dual brushes, full Brush Studio parity, proprietary brush import, and physical fluid simulation until a demonstrated use case needs them. The smallest useful release is pressure-sensitive ink plus textured dry brushes on the existing tiled infrastructure.

## Acceptance and remaining uncertainty

Extend the existing brush test target with a small deterministic sample-replay check covering event-rate invariance, changing pressure, and provisional-tail replacement. Retain coverage for opacity, tile seams, selections, transformed layers, masks, undo, export, and save/reopen. Benchmark narrow ink and wide textured strokes on blank and opaque 4K layers, including mouse-up and memory allocation.

Native visual acceptance remains separate: test light-to-heavy pressure, tilted shading, slow curves, fast zigzags, repeated crossings, transparent edges, and real tablet input. Compare a handful of deliberately chosen Procreate strokes with Compositor output using original or permitted assets. No source review can establish equivalent feel or input-to-photon latency; those require a running implementation and hardware testing.
