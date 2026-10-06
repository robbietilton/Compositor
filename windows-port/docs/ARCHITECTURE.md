# Compositor for Windows — architecture and working rules

This tree is the Windows port (goal C: feature parity with Compositor for macOS 1.4.5).
It is a **rewrite in Rust**, not a compilation of the Swift sources. The Swift original stays
read-only at \`../compositor_mac\` and is the specification for every behavior here.

## Crates

| Crate | Owns | Write scope owner |
|---|---|---|
| \`comp-core\` | \`.comp\` format v1–11, manifest DTO, document model, history, validation, PNG codec | Lead (interface) + format task (store/digest/tests) |
| \`comp-render\` | Compositing: 24 blend modes, 12 adjustment kinds, 6 layer effects, transforms, downsample cache | render task |
| \`comp-io\` | Import/export outside the format: JPEG, TIFF, BMP, WebP, PSD/PSB, resample/crop/canvas ops | raster task |
| \`comp-brush\` | Brush, eraser, clone stamp, spot heal, magic wand, selection and transform engines | brush task |
| \`comp-cli\` | \`compc\`: inspect, validate, render, create, convert | Lead |
| \`comp-gui\` | The Windows editor shell (eframe/egui): canvas, layers panel, tools, undo | gui task |

## Non-negotiable contracts

1. **The frozen interface is \`comp-core\`.** Only the Lead edits \`comp-core\`'s public API
   (\`lib.rs\`, \`geom.rs\`, \`layer.rs\`, \`document.rs\`, \`manifest.rs\`, \`adjustment.rs\`,
   \`effects.rs\`, \`text.rs\`, \`shape.rs\`, \`blend.rs\`, \`bitmap.rs\`, \`history.rs\`,
   \`validate.rs\`, \`limits.rs\`, \`error.rs\`). If you need a change there, send the Lead a
   message with the exact signature you need; do not edit it yourself.
2. **Pixels are straight (non-premultiplied) 8-bit RGBA** in \`Bitmap8\`; masks are 8-bit gray in
   \`Gray8\`. Premultiply inside the compositor, never in the buffers.
3. **Format fidelity beats convenience.** Anything \`comp-core\` writes must load in the macOS app.
   Field names, enum spellings and ranges come from \`../compositor_mac/docs/project-format.md\`
   and \`../compositor_mac/Compositor/IO/ProjectStore.swift\`.
4. **No placeholders.** Never leave \`todo!()\`, \`unimplemented!()\` or a silent wrong result. If a
   feature is out of scope for this pass, return a typed error and list it in your \`NOTES.md\`.
5. **Every module carries tests.** A crate is done when \`cargo test -p <crate>\` is green.

## Working rules for agents

- **Stay inside your write scope.** Other agents are editing sibling crates at the same time.
- **Build with your own target directory** so parallel builds never block each other:
  \`\`\`powershell
  $env:CARGO_TARGET_DIR = "E:\\Compositor-main\\compositor_win\\target-<your-name>"
  cargo test -p <your-crate>
  \`\`\`
  Never run \`cargo build --workspace\` or \`cargo test --workspace\`: it takes minutes and locks
  the shared target directory.
- **Read the Swift source for behavior, not for structure.** Port the *semantics*: the formula,
  the range check, the ordering rule. \`compositor_mac/Compositor/Rendering/\` and
  \`.../Document/\` are the reference; \`docs/project-format.md\` is the format contract.
- **American spelling** in code, comments and UI. Comments explain *why*, not *what*; match the
  density of the surrounding code.
- **No TODO/FIXME/HACK comments.** Track open work in your crate's \`NOTES.md\` instead.
- Report status to the Lead with: files touched, \`cargo test -p <crate>\` result, what is
  unfinished, and the next concrete step.

## Verification

\`comp-cli\` and \`docs/PARITY.md\` track progress against the macOS feature list. The Lead runs the
final acceptance: \`cargo test\` per crate, plus pixel comparisons against reference images
generated with Python/Pillow (see \`tools/verify/\`).
