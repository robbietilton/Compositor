# Brushhead catalog and generated substitutes

The app ships a filename-only catalog of 286 identifiers from the replacement local inventory. `Compositor/Document/BrushHeadCatalog.swift` is about 10 KB of source text. It contains no image data. Catalog membership means a known identifier, not that its image is installed or that a generated style matches it.

`scripts/catalog_brushheads.py` inventories filenames in the ignored local `procreate/brushheads` directory. It never opens, decodes, copies, or packages image bytes. Run `python3 scripts/catalog_brushheads.py --check` to verify freshness against that local inventory. No extracted images are app resources; no download service or image bundle was added.

Import resolution retains exact owning embedded-image precedence, followed by existing basic procedural mappings. An absent catalogued reference receives an explicit missing-original diagnostic. Unknown references remain missing too. Names do not automatically select a replacement, and a primary replacement does not bypass grain or dual-brush requirements.

Generated Substitute prioritizes Ultra Soft Round, Soft Round, Medium Round, Medium Hard Round and Hard Round, alongside Ink Dab, Dry Bristles and Speckle. These are independently authored mathematical styles, without fitted or reconstructed source pixels. Users choose them explicitly in Shape. Presets save only the generator identifier; eight bounded 128×128 masks are generated and cached in memory on first use. No generated PNG is saved into the app or preset. User-supplied custom/embedded images retain their original source bytes through the existing library store.

This avoids image-package bloat and image acquisition requirements. It does not reproduce Procreate originals or solve the remaining CPU cost of wide, dense image stamping. See [Shape qualification](shape-brushes.md) for performance limits.

Automated evidence: [generated styles](evidence/shape/independent-generated-tips.png), Top to bottom: Ultra Soft Round, Soft Round, Medium Round, Medium Hard Round, Hard Round, Ink Dab, Dry Bristles and Speckle. Dynamics checks verify distinct deterministic output, sparse/dense replay, recipe-only persistence, and both renderer-request paths. Import checks verify supplied-image precedence, missing diagnostics and grain gates. These checks do not certify visual equivalence to original tips.

Verification through open Xcode: 21 dynamics tests (20:05), 10 importer tests (20:07), three native palette tests (20:07), all passed with zero runtime warnings. Existing earlier regression runs contribute another 39 passing tests; 73 relevant checks total across the Shape work. Catalog freshness and `git diff --check` passed. The freshly built Debug app contained none of the catalogued image filenames; the project references neither the extraction directory nor Experimental assets. Native generated-source [top](evidence/shape/generated-top.png) and [bottom](evidence/shape/generated-bottom.png) screenshots were inspected.

The user replaced the local inventory on October 31. The catalog now reflects those filenames; names alone still establish no preset mapping or visual equivalence. Earlier verification counts describe the original 159-name snapshot. No replacement image is bundled.
