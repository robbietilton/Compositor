# MVP brush compatibility contract

October 31, 2026 · Task `task-f5f8a27d-be1f-4039-a0c3-812c477e0b28`.
Status: proposed contract for human review; no importer, persistence or engine changes in this task.

## Decision and evidence

Extend the current tiled brush engine with a local, versioned brush collection, lossless source retention and explicit compatibility diagnostics. Import success means data was read and retained; it never implies equivalent Procreate output. This contract uses [settings research](procreate-brush-settings-research.md), which supersedes the older engine note's pressure/import assumptions. Archive field meanings and source rendering equations remain unverified; no numeric field mapping is authorized by a similar name alone.

Verified repository boundaries:

- `CanvasView.penPressure` → `EditorSession.beginBrush/continueBrush` → `BrushStroke.append` already carries pressure. `BrushSettings.dynamics` clamps pressure and supports size/opacity; mouse fallback is full pressure. Tilt, timestamp and rotation are not brush samples yet.
- `BrushSettings` is a transient Sendable value, shared by paint and other tools. `EditorSession.brushSettings` owns current controls; per-tool parked tips already preserve size/hardness/opacity. Foreground color also feeds the gradient.
- `BrushStroke` owns immutable stroke settings, tiled coverage, provisional-tail replacement, preview patches and snapshot output. `makeRasterEdit` also serves gradient, selection edits and smudge paths; changing its defaults would change unrelated tools.
- `ProjectManifest.current` is 20; accepted versions also include GIF branch version 27. There is no persisted brush field. Existing tests cover pressure (`PenPressureTests`), stroke opacity, tails, masks, transforms and touched tiles (`BrushTests`, `RasterSnapshotTests`). These are source observations, not fresh test results.

Constraints: retain native Swift/AppKit, existing tile/commit/undo boundaries, source assets and legacy brush behavior. Quality goals are safe imports, deterministic strokes, honest limitations and preview/commit consistency. Assumption: the MVP collection belongs to the app, not a document; painting remains destructive raster editing.

## Settings inventory

S = supported now as Compositor behavior, not proven source equivalence. M = planned MVP behavior, disabled until implemented and checked. P = preserved but deferred, shown disabled with “Coming soon”. H = additionally requires a capable device; hardware availability never deletes a mapping. Unless explicitly S or M below, every researched control is P.

| Category | S | M | P / hardware qualification |
| --- | --- | --- | --- |
| Stroke Path | Internal round-tip spacing only | Editable fixed spacing | Spacing jitter, lateral/linear jitter, falloff; speed-based spacing |
| Stabilization | Existing screen-space rope smoothing | Reuse existing smoothing, explicitly named Compositor Smoothing | StreamLine amount/pressure, source stabilization, motion filtering/expression; do not equate these to the rope |
| Taper | None | Distance-based start/end size taper, independent lengths measured as fractions of completed stroke length, linear scale from/to zero | Touch/pressure-specific taper, linked size, opacity, pressure, tip, animation, classic taper; M is a native taper, source mapping requires evidence |
| Shape | Procedural round hardness | Known basic-source mapping; fixed roundness and angle, fixed count and angular scatter | Source image stamping, input styles, rotation response, count jitter, randomization, flips, roundness jitter, filtering; round angle/scatter has no effect for a circle and must not imply otherwise |
| Grain | None | None | Source, moving/texturized, movement, scale, zoom, rotation, depth/depth jitter, offset jitter, blend, brightness/contrast, filtering and source tiling |
| Rendering | Stroke-wide opacity cap and existing round coverage | Separate per-dab flow for procedural stamps | Source glaze/blending modes, wet/burnt edges, edge/stroke blend, luminance blend, alpha threshold, classic dual-normal |
| Wet Mix | Separate smudge tool only; not wet paint | None | Dilution, charge, attack, pull, grade, blur, blur jitter, wetness jitter |
| Color Dynamics | Foreground color only | None | Stamp/stroke jitter and pressure/tilt/rotation mappings (H for device inputs) |
| Dynamics | None | None | Speed size/opacity/spacing, random size/opacity jitter |
| Pen / Tablet | Pressure size/opacity (H) | Editable monotone pressure curve (H), sample timestamp and valid tilt/rotation transport (H) | Pressure flow/bleed and individual responses, tilt response/orientation, barrel mappings (H); transport alone does not enable rendering controls |
| Properties / preview | Current size 1–2000 px, opacity .01–1; interactive canvas stroke | Collection selection and shared drawing preview | Source size/opacity bounds, smudge pull and source preview settings |
| Dual | None | Preserve both components and combination metadata | Combined rendering; never flatten into a claimed equivalent single brush |

Native MVP spacing is a positive fraction of full brush diameter, minimum dab distance .25 document pixels; preserve current automatic spacing when no override exists. Flow is finite 0–1 per dab, independent of the existing stroke opacity cap. Roundness is minor/major radius ratio (0,1], angle is clockwise radians in document space, count is a positive bounded integer, scatter is a bounded symmetric angular offset. Implementation must select and document safe upper limits for new controls before enabling them. Do not apply new stamp semantics to existing presets implicitly. Start/end taper evaluation must replay at final stroke length; preview may be provisional but flush must match an identical completed replay. Pressure curve uses finite ordered points within [0,1]², fixed endpoints (0,0)/(1,1), monotone output and piecewise-linear interpolation; identity is the legacy default. Calibration remains editable. These are Compositor semantics, not inferred Procreate equations.

## Persisted brush and ownership

Use one concrete collection record and extend/reuse `BrushSettings` for implemented runtime values; no parallel renderer settings hierarchy or per-setting plugin system. The following is a data contract, not a demand to scaffold types now.

| Persisted item | Required meaning |
| --- | --- |
| Collection header | Independent schema version (initially 1), ordered brush IDs and selected ID; missing selected ID falls back to first valid brush or built-in default |
| Brush identity | App UUID, editable display name and source collection/order identity; source UUID is provenance, not a globally unique app key |
| Native overrides | Only implemented editable parameters, in documented native units with legacy defaults for absent values; edits never overwrite original source values |
| Source provenance | Original container bytes retained once per import, original filename/type, exact definition path and component identity; reference shared retained source rather than duplicating a library for every brush |
| Source definitions | Original keyed-plist bytes, reset archives, primary/secondary relationships, original shape/grain references and unknown fields retained through the original container; decoded inspection data may be rebuilt |
| Asset resolution | Separate shape/grain result: embedded asset path, explicit procedural mapping ID/revision, or unresolved reference. Preserve original reference and owning component in every case |
| Mapping provenance | Mapping revision used to derive native values; explicit user overrides are separate and survive remapping |

Store the collection and its owned source/assets in app Application Support, using existing coordinated/atomic persistence patterns. It must survive source-file deletion and relaunch. Write new data completely before replacing the previous collection; failure leaves the previous usable collection and active document intact. Unknown collection schema versions fail without rewriting the file. Retain exact source bytes rather than designing an arbitrary JSON serialization of NSKeyedArchiver objects. Do not add typed properties for unsupported parameters merely to preserve them.

Persist preset geometry/opacity/pressure behavior; keep foreground color, erase/mask state, healing mode, blur radius and clone sources in their existing session/tool owners. The session's current size/opacity edits update the selected brush's native overrides; existing unrelated tool parking remains authoritative for those tools. Collection edits do not dirty a document or enter pixel undo. Each stroke snapshots effective settings at begin; later preset edits affect the next stroke. Smoothing currently reads live session settings during a stroke: snapshot it too when implementing preset binding.

No `.comp` change or project-format bump is required for this app-owned collection; do not change `ProjectManifest.current` for this document. Saved pixels already preserve appearance without a brush installed. If project-embedded brushes or editable stroke replay are later requested, that is a separate format change: update `docs/project-format.md`, writer/reader validation and `ProjectManifest.current` together after checking version 27 compatibility. Do not reserve version 21 now.

## Import and resolution

1. Accept `.brush` ZIP, `.brushset` directories within ZIP, and `.brushlibrary` outer ZIP containing `.brush` ZIPs. Inspect keyed plists as data with Foundation; never instantiate arbitrary archived classes. Follow declared collection ordering; preserve unlisted definitions deterministically with a diagnostic. Reset definitions are reset metadata, not additional selectable brushes. Secondary definitions are components of their parent, not extra palette entries.
2. Validate before publishing any collection changes. Reject absolute/traversal paths, escaping links, duplicate normalized paths, invalid object references and malformed required metadata. Bound compressed and expanded bytes, nested archive depth, entry/definition count, plist graph traversal and decoded image pixels before allocation. Implementers must record concrete limits and tests; no unbounded extraction or class unarchiving. A structurally unsafe container fails as a unit; missing assets and unsupported settings are recoverable per-brush diagnostics.
3. Resolve the explicitly referenced embedded asset relative to its owning component first, including arbitrary image names. Never guess “Shape.png”, prefer a similarly named sibling, or match a custom asset by basename. The Volcanic Ash grain-named shape reference is an acceptance case. Grain resolves independently.
4. Only a recognized built-in reference with no embedded image may use the centralized mapping table below. Ambiguous source identity remains unresolved. Source files are never modified. Missing reference and missing asset are explicit outcomes, never implicit hard circles.
5. Keep valid-but-unrenderable brushes selectable for inspection. Disable painting/drawing preview when required tip/grain behavior or dual composition cannot be rendered. An explicit “Preview primary only” or “Use round approximation” action may produce a clearly labeled approximation without modifying source or hiding diagnostics. Do not silently discard grain, a secondary component or active unsupported behavior.

| Exact recognized built-in reference | Native candidate | Compatibility claim |
| --- | --- | --- |
| `Brush-Preset-Hard.png` | Existing hard circle | User confirmed Gggg is round; pixel equivalence unverified |
| `Brush-Preset-Soft.png` | Tuned round falloff | Approximation pending reference comparison |
| `Brush-Preset-Medium.png` | Separately tuned round falloff | Approximation pending reference comparison |
| `Brush-Preset-Medium-Hard.png` | Separately tuned round falloff | Approximation pending reference comparison |
| `Brush-Preset-Ultra-Soft.jpg` | Separately tuned round falloff | Approximation pending reference comparison |

No invented hardness constants: tune against references in the mapping task. Retain mapping IDs and revisions; improvements can rederive imported values from retained source without another export. Apply remapping explicitly, preserve user overrides, and do not alter already painted pixels. Embedded image retention does not imply that image stamping is implemented.

## Capability and render boundary

Derive capability from implementation support, per-brush asset/feature requirements, and current device input independently. Do not persist a transient “tablet connected” Boolean as brush support. Each visible setting needs a stable native identifier, current/native or source value, implementation state (supported/planned), availability reason and source-mapping confidence (verified/approximate/unmapped). A small centralized table/switch is enough; no capability registry framework. Unknown fields stay in source and appear in diagnostics, without fabricating named controls.

All researched controls stay visible. Planned controls are disabled with “Coming soon”; implemented controls lacking device input explain “Requires compatible tablet”. Missing assets identify the exact reference/component. Imported source values remain inspectable when native editing is disabled. Parsing, renderability and visual qualification are separate reported results, with per-feature reasons; there is no single “fully compatible” Boolean.

Reuse the concrete input → stroke → patch/snapshot boundary:

- Input carries document position, monotonic timestamp and optional valid pressure/tilt/rotation. Missing pressure means 1 for mouse; missing tilt/rotation means no modulation, not a fabricated orientation. Device events must be validated before reading tablet-only properties; do not discard stationary pressure changes. Preserve mappings when a device disconnects. Normalize angular units once at the input boundary and verify near-upright tilt with hardware.
- Resolve selected preset + native overrides + session color/tool context into validated settings once at stroke begin. Gate new preset behavior at intended Brush paint/erase callers; keep masks grayscale and retain existing mask rules. Do not opt healing, clone, blur, smudge, gradients or selection edits into new dynamics by changing shared defaults.
- Interactive drawing preview creates an isolated small layer and uses `BrushStroke.append`, `flush`, patches and snapshot composition with the same settings resolution as canvas paint. It never mutates the active document, its undo or collection. No second SwiftUI brush renderer. A simulated pressure ramp is labeled as simulated; device qualification stays separate.
- New stamp behavior must use a path that implements it; disable the continuous round sweep for unsupported stamp settings rather than ignoring them on GPU. Preserve the existing fast path for legacy rounds. Carry distance remainder and deterministic stroke seed; tail replacement restores coverage, spacing phase, dab index and random state. Flow remains bounded by stroke opacity; no wet reservoir or RGBA brush state is needed for constant-color MVP rounds.

## Alternatives and risks

| Option | Benefit | Cost / decision |
| --- | --- | --- |
| Current round controls only | No persistence/import work | Cannot meet compatibility and editor task scope |
| Extend current engine + retained source (recommended) | Reuses tile, transforms, undo and round performance; incremental compatibility | Partial rendering must remain conspicuous; source retention costs disk space, bounded at import |
| Adopt another brush engine / full parity | Potential broader brush behavior | New integration/dependencies, unchanged proprietary mapping uncertainty; no demonstrated need for this MVP |

Largest risks are guessed archive semantics, substituted assets appearing accurate, and dynamics leaking into sibling tools. Mitigate with explicit mapping evidence, renderability gates and existing shared-tool regression tests. Unknown source equations and device behavior remain open qualification questions, not reasons to discard source. Team size is unspecified; existing project tasks separate design, implementation and qualification, with no new runtime/service ownership needed.

## Implementation handoff and acceptance

Follow the existing project tasks; do not implement downstream work in this contract task:

1. Presets/data (`task-234e68c8-1ded-4f2f-ac01-982363b24c61`): atomic collection, native overrides, retained source and legacy defaults. Prove round-trip, source deletion/relaunch, failed-save recovery and unchanged `.comp` pixels/undo.
2. Import (`task-4251a2f2-0085-4d01-93f0-9f592a1555ba`): bounded safe parsing, ordering/reset/dual handling. Exercise Gggg, Warptuner, modern sets and Classic Library locally; do not redistribute supplied assets. The research's 490 definitions include components and exclude Warptuner/Gggg; do not assert 490 selectable brushes.
3. Basic mappings (`task-75d82a04-f2d2-40db-939c-0ca09b06f44d`): embedded precedence, arbitrary names, Volcanic Ash, five explicit mappings, unresolved shapes and independent missing grain. Prove byte-preserved source and remapping without lost overrides.
4. Tablet input (`task-fd8b0747-a907-4de7-a613-fca669387254`) and dynamics (`task-a892b4da-6256-4db6-a77d-01365afcdaa9`): implement only M controls above. Extend `PenPressureTests` and existing brush tests with deterministic replay for sample-rate changes, stationary pressure, tail rollback, spacing, taper and flow; run GPU/fallback cases and preserve legacy defaults.
5. Palette design/build (`task-01e3782b-5718-42b1-a44d-ecb02bff6d82`, `task-4305d27c-2f13-493c-aa36-37f72371a37c`): show all categories, availability reasons and source values; verify keyboard/accessibility labels, persistence and preview/commit equality for supported settings.
6. Qualification (`task-73865b4c-97fb-48ec-8b0c-d1e5df3577bf`): run brush/pressure/snapshot and sibling-tool regressions, seams, selections, masks, transformed layers, cancel, undo/redo, save/reopen and export. Compare 4K narrow/wide strokes and mouse-up/allocation with `docs/brush-performance.md` under the same configuration; report measurements, not inherited claims.

Release evidence must separately report automated import/data checks, native UI acceptance, visual comparison and real-tablet acceptance. Compare pressure ramps, multiple sizes, overlaps and edge profiles with original/permitted Procreate references; record each mapping's observed differences. Missing references, dual composition, textures and wet features remain disclosed limitations. Source review and successful parsing cannot certify equivalent feel or latency.

Contract acceptance: each researched category has a status above; source/asset/dual preservation and failure semantics are explicit; ownership and existing render interfaces are identified; app versus project persistence is decided; downstream tasks have concrete verification targets. This document defines those targets—it does not claim they have passed. Remaining implementation decisions are concrete resource limits, archive-field mappings, tuned falloffs and hardware normalization, owned by the corresponding downstream tasks. Review the M subset and app-owned storage before implementation.

## Rendering delivery update · October 31, 2026

The inventory above records the original MVP boundary. [Native Rendering](rendering-brushes.md) now supplies all six modes, flow/opacity, wet/burnt edges, shared edge/stroke blend modes, luminance, alpha threshold and explicit minimal dual Normal/Classic composition. These are documented native equations; source archive mappings remain unverified and originals retained. Full Wet Mix, independent secondary dynamics and Grain are separate.

The subsequent [screenshot-gap delivery](brush-editor-gap-implementation.md) adds native primary Grain, property bounds/Smudge Pull/orientation, independent pen/touch Taper and Stabilization responses, and enlarged mask inspection. The original MVP inventory is historical; the linked record specifies current behavior, explicit native source overrides and qualification limits.
