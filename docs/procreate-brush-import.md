# Procreate brush import

October 31, 2026 · Task `task-4251a2f2-0085-4d01-93f0-9f592a1555ba`

The Brushes palette now imports `.brush`, `.brushset`, and `.brushlibrary` files through a native open panel. The supplied `.brushset.zip` layout is also accepted. Parsing runs off the main actor. Import adds the complete validated result atomically, leaves the active brush selected, and reports missing assets and rendering limitations. Reimporting identical source definitions skips existing records and preserves local edits.

Imported brushes are currently for inspection, not painting: source-to-engine mappings are a separate task. They use a document icon instead of a fabricated round-tip preview. Use the explicit Edit button to inspect Source Details, original references, collection/member identity, and limitations. The renderer never silently substitutes a round brush. Procreate export remains separate.

## Reader and preservation

`BrushZIP.swift` reads central/local ZIP records in memory using platform zlib for raw deflate and CRC-32. It never extracts entries or invokes shell tools. Stored and deflated entries are supported. Encrypted, split and ZIP64 containers, symbolic/special files, unsafe/duplicate normalized paths, overlapping payloads, truncated/inconsistent headers, invalid checksums and oversized entries are rejected.

`ProcreateBrushImporter.swift` parses keyed property lists with Foundation as data, never through `NSKeyedUnarchiver` or arbitrary archived classes. It validates the object table, reference bounds/cycles, graph depth and supported string fields. Only native UID scalars are serialized individually to expose their public XML representation: whole archives are never converted into a potentially expanding XML intermediate. Unknown settings and class descriptors are retained as source data without execution or guessed renderer mappings.

Modern sets use `brushset.plist` brush order/name. Valid unlisted definitions are appended in archive order with diagnostics. Classic libraries use their `.procreate_meta.*` alphabetic-index-plus-signed-offset records for collection and brush ordering. Missing or unrecognized ordering metadata produces a diagnostic and deterministic archive-order fallback. Nested member ZIPs are decoded once; further library nesting is rejected.

Primary definitions become palette brushes. `Sub*` definitions belong to their primary brush; reset archives are validated and retained but do not become extra palette entries. Shape and grain references resolve independently relative to the owning component. No basename matching or inferred “Shape.png” replacement occurs. Missing references are reported. The Volcanic Ash shape correctly remains `GL-Volcanic-Grain.png` when that is the actual source reference.

`BrushLibrary.importBrushes` reuses the existing content-addressed source store and atomic metadata writer. The complete original outer container is retained once by SHA-256, preserving unknown fields, embedded assets, resets, nested ZIPs and dual data. Optional `memberPath`, `collectionName` and `issues` extend source metadata without changing collection schema 1. Definitions keep exact paths within the owning member. Failed imports leave the prior metadata and selection unchanged; source bytes written before a failed metadata write can remain as harmless unreferenced files.

## Resource bounds

- Input container: 512 MiB, checked before mapping the selected file and again in the ZIP reader.
- Combined declared expansion across outer/member archives: 512 MiB; at most 20,000 entries.
- Individual expanded entry: 64 MiB; at most one nested `.brush` level.
- Property list: 2 MiB; 100,000 visited values, depth 64, 10,000 keyed objects.
- Image properties are checked without raster decoding: at most 32,768 per side and 64 megapixels.
- Existing collection bounds remain 8 MiB metadata and 1,000 records. An individual import is bounded to 998 brushes, leaving room for the two initial native presets.

Archive/resource rejection is a whole-container failure. Missing built-in/custom assets and unimplemented rendering settings are preserved per-brush diagnostics. Concrete limits intentionally reject unsupported layouts rather than attempting unbounded recovery.

## Verification

`ProcreateBrushImportTests` contains synthetic stored ZIPs and keyed plists; no user assets are bundled. Tests cover modern order, dual/reset ownership, unknown class descriptors, legacy signed-offset order/fallback, invalid/traversing/duplicate paths, symlinks, checksum corruption, truncation, expanded-size bounds, missing/orphan definitions, unsafe asset references, invalid/cyclic object references, repeated opaque data, atomic publication, selection preservation, deduplication, original bytes and relaunch.

A local optional acceptance test scans the user-supplied `procreate/` folder when available; CI can run the synthetic tests without redistributing those files. Warptuner was removed by the user and is not required. The current 18 containers were accepted by the native reader: 375 selectable brush records and 501 non-reset primary/secondary definitions. Counts describe the current supplied files; they are not the historical research count. Examples: Design has 10 brushes / 11 definitions, with Peregrine first; Classic Library has 214 brushes / 237 definitions, with Peppermint first. Gggg imports by filename when its archived name is null.

Automated import/data acceptance is separate from native open-panel interaction, rendering qualification and tablet feel. Importing does not certify source appearance. Follow up with the existing basic shape mapping, full Shape/Stroke Path/Rendering and qualification tasks. No `.comp` format change, source-asset redistribution or Procreate writer is introduced here.
