# Starter brushes

The November 1, 2026 saved collection supplies three editable starter presets in `Compositor/DefaultBrushes.json`: Flat Marker, Default Painting Brush (initial selection), and Pencil. Stable preset IDs, native parameters and pressure curves are retained from the saved collection.

With the user's approval, Flat Marker's custom Blotch image is replaced by the independently generated Ink Dab tip. All other active settings are retained. Inactive custom grain payloads are removed too. The resource contains about 8 KB of settings and no image pixels, original digests, external file dependencies or Procreate archives. Generated masks use the existing mathematical generators at runtime.

`BrushLibrary` uses this collection only when no saved user collection exists. It uses the same version/size/preset validation as saved collections. Existing user edits, brush deletion and selection take precedence; starter presets are ordinary editable/deletable records and are not reinserted on subsequent launches. The original saved collection is not rewritten by this change.

`BrushLibraryTests.bundledStarterBrushesArePortableEditableAndOnlySeedNewCollections` verifies resource packaging, names/initial selection, image-free portability, actual painting, edits and deletion persistence.

Verification: all seven BrushLibraryTests pass through the open Xcode project (`Test-Compositor-2026.11.01_02-28-22-+0200.xcresult`), including bundled resource loading and painting all three starters. `git diff --check` passes.
