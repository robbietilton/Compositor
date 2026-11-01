# Brush presets and retained compatibility data

October 31, 2026 · `task-234e68c8-1ded-4f2f-ac01-982363b24c61`

The existing `BrushLibrary`, native collection and explicit Edit action are retained. This implementation extends that model; it does not implement the separate Procreate importer or claim source rendering equivalence.

## Storage

The app-owned collection is `Application Support/Compositor/brushes.json` inside the application's sandbox container. Canary and standard bundle identities have separate containers. Schema version remains 1: `source` is an optional additive preset field, and missing native settings load the defaults from `BrushSettings`. Existing canary collections remain readable. Unsupported collection versions and malformed records leave the saved file untouched and block replacement.

Only size, hardness, stroke opacity, smoothing and pressure size/opacity are preset-owned. Foreground color, paint/erase mode, mask color, clone/healing/blur state and document history stay with their existing owners. Native settings continue through `BrushPreset.applying(to:)` into the existing `BrushSettings` and stroke renderer.

The metadata file is atomically replaced, bounded to 8 MiB and 1,000 presets. Save publishes new in-memory state only after disk writing succeeds. Selection and editor Save share `activateBrushPreset`; direct selection stays separate from intentional editing. Toolbar changes are saved by the existing header’s native settings-change observation, without a pending debounce that could lose the last edit on a tool switch, without adding pixel undo or marking the project modified.

## Source preservation API for the importer

1. After validating the incoming container, call `BrushLibrary.retainSource(data)`. It returns the SHA-256 digest and writes immutable original bytes to the sibling `brushes.sources/<digest>` file. Identical containers share one file. The source limit is 512 MiB per container; the importer must enforce its own ZIP expansion, image and graph limits before allocating data.
2. Attach `BrushSource(archiveDigest:filename:definitions:)` to each imported `BrushPreset`. Each definition records its original archive path and exact shape/grain references. Put the primary definition first and subsequent dual definitions after it. These strings are provenance; they are never opened as paths by this storage API. Reset definitions, embedded images, unsupported values and unknown archive fields remain byte-for-byte in the original container.
3. Save the preset through the existing library. It validates the source record and checks the retained bytes before publishing metadata. `sourceData(for:)` retrieves and verifies those bytes for future remapping/export. Native name/settings edits leave source metadata and bytes unchanged.

Source writes precede metadata writes: an interrupted import may leave an unreferenced source file, but cannot publish a reference to partially written bytes. No automatic deletion or source rewriting is introduced. Original input URLs are not stored as dependencies, so moving/deleting an imported file cannot break retention. Missing/tampered retained source fails retrieval or saving that source-backed preset; native presets remain usable.

Imported presets retain source details and default to inspection-only. The [basic-shape mapping implementation](basic-brush-mappings.md) adds explicit round approximation opt-in for a recognized procedural primary tip with no grain or secondary component. Other imported presets still refuse activation. Native calibration is separate from retained source settings; source retention alone is not a compatibility score.

## Project compatibility and validation

There is no `.comp` field change and no project format bump: `ProjectManifest.current` remains 20 and its existing supported-version set, including GIF branch version 27, is untouched. Saved layer pixels are independent of installed brushes.

`BrushLibraryTests` covers legacy missing-setting defaults, selection, native-context preservation, exact source bytes and dual references, deduplication, relaunch, native edits, unsafe digests, missing sources, invalid settings, unknown collection versions, failed writes and document/history round-trip invariants. Existing brush, pressure, clone, blur, gradient, history and project tests provide regression coverage. Actual source parsing, procedural mapping tuning, Procreate export and real-device qualification remain in their existing downstream scopes.

The separate [Procreate import task](procreate-brush-import.md) now consumes this storage API; its parsing, ordering, limits and local fixture results are recorded there.

Core native overrides now also include validated `RoundBrushDynamics` (pressure curve, spacing, flow, taper and ellipse/count/scatter). Missing metadata uses legacy defaults. See [supported dynamics and limits](round-brush-dynamics.md).

The [Shape delivery](shape-brushes.md) extends explicit approximation opt-in to supported single embedded/custom tips with no grain or dual composition. Derived masks are bounded per component; custom original bytes use the existing source store. Missing native Shape metadata keeps legacy defaults.

The [Rendering delivery](rendering-brushes.md) adds optional validated native mode, edge, blend, threshold and secondary-tip metadata. Explicit dual setup permits two supported components without grain; missing original secondary tips stay blocked unless the user chooses a native secondary override. Source archives remain unchanged.

[The screenshot-gap delivery](brush-editor-gap-implementation.md) adds optional native Grain, Properties, pen/touch Taper and Stabilization groups, bounded embedded grain masks and enlarged mask inspection. Explicit primary-grain setup now permits supported grain-backed sources; unresolved original grain and secondary-component grain stay gated. Missing groups preserve legacy defaults.
