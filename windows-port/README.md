# Compositor for Windows

A native Windows port of [Compositor](https://github.com/robbietilton/Compositor) — the free, open
source macOS image compositor — targeting **feature parity (goal C)** with the macOS 1.4.5 release.

The macOS app is written in Swift against AppKit, SwiftUI, Core Graphics, Core Image, Metal, Vision
and Accelerate. None of those exist on Windows, so this is a **rewrite in Rust**, not a build port:
the Swift sources stay read-only next to this tree and act as the specification.

## What is here

| Path | What it is |
|---|---|
| \`crates/comp-core\` | The \`.comp\` format (versions 1–11), document model, undo history, validation, PNG codec |
| \`crates/comp-render\` | The compositing engine: 24 blend modes, 12 adjustment layers, 6 layer effects |
| \`crates/comp-io\` | JPEG/TIFF/WebP/BMP import, JPEG export, PSD/PSB reading, canvas and image resizing |
| \`crates/comp-brush\` | Brush, eraser, clone stamp, healing, magic wand, selections, transforms |
| \`crates/comp-raw\` | The Camera Raw pipeline: nine parameter groups, the develop kernels, clipping previews |
| \`crates/comp-text\` | Text layout, font rasterization with per-run faces and colors, shape drawing |
| \`crates/comp-cli\` | \`compc\`: inspect, validate, create, extract, render, export, import, PSD, raw, release |
| \`crates/comp-release\` | Update manifests, version comparison, SHA-256 verification, staged replacement |
| \`crates/comp-gui\` | The editor window: canvas, layer panel, tools, undo, open/save |
| \`docs/ARCHITECTURE.md\` | Crate boundaries, the frozen core interface, working rules |
| \`docs/PARITY.md\` | Module-by-module parity with the macOS app and what is still missing |
| \`tools/verify/\` | An independent Python/NumPy oracle and 29 pixel-comparison fixtures |

## Build and test

\`\`\`powershell
cargo test -p comp-core      # format, document model, validation
cargo test -p comp-render    # blend modes, adjustments, effects
cargo test -p comp-io        # import/export
cargo test -p comp-brush     # painting and selections
cargo test -p comp-cli       # the command line tool
cargo build --release -p comp-cli -p comp-gui
\`\`\`

Run the editor:

\`\`\`powershell
cargo run -p comp-gui -- tools\\verify\\fixtures\\demo.comp
\`\`\`

Use the command line tool:

\`\`\`powershell
compc info   path\\to\\Project.comp
compc layers path\\to\\Project.comp
compc render path\\to\\Project.comp -o out.png
compc export path\\to\\Project.comp -o out.jpg --quality 92
compc import photo.jpg New.comp --name "Photo"
compc psd    design.psd Design.comp
compc raw    shot.dng -o graded.png --settings grade.json
compc sample out.comp                     # a project carrying every optional feature
compc rasterize out.comp                  # text and shape metadata becomes pixels

# releases and updates
compc update describe --dir dist/stage --version 0.2.0 -o update.json
compc update check update.json --current 0.1.0
compc update verify update.json --dir downloaded
compc update apply --staged downloaded/compositor.exe --target compositor.exe
\`\`\`

Package a portable build; the manifest is hashed by the CLI itself, so the build and the updater can
never disagree about what a release contains:

\`\`\`powershell
pwsh -File tools/build.ps1                      # tests, release build, dist/ + zip + update.json
pwsh -File tools/register-filetype.ps1          # associate .comp with the editor (current user)
\`\`\`

## Verify against the macOS semantics

\`tools/verify\` holds a second, independent implementation of the compositing model (W3C/PDF blend
formulas in sRGB, written from the specification) plus fixtures that the Rust engine must reproduce
pixel for pixel:

\`\`\`powershell
& $python tools\\verify\\make_fixtures.py
& $python tools\\verify\\acceptance.py
\`\`\`

## Compatibility contract

Anything this project writes must load in Compositor for macOS, and anything the macOS app writes
must load here. Field names, blend-mode spellings, version gates and limits come from
\`../compositor_mac/docs/project-format.md\` and \`ProjectStore.swift\`. The test suites in
\`comp-core\` and the Python fixtures in \`tools/verify\` both enforce that contract.

## License

MIT, like the original. The Compositor name and icon are the original author's trademarks and are
not covered by the license; a shipping Windows build needs its own name and artwork.

See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for third-party model and optional library notices.
