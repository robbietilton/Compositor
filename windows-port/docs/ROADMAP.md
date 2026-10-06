# Goal C roadmap: from this tree to feature parity

The macOS app is ~34,300 lines of application Swift plus 13,000 lines of tests and 2,183 lines of C
pixel kernels. Goal C is parity with all of it. This file tracks the milestones, what each one
delivers, and what is genuinely left.

## Milestones

| # | Milestone | Delivers | State |
|---|---|---|---|
| M1 | Cross-platform core | \`.comp\` v1–11 read/write/validate, document model, snapshot undo, PNG codec, CLI | **in progress** |
| M2 | Compositing engine | 24 blend modes, 12 adjustment layers, 6 layer effects, masks, group pass-through, transforms | **in progress** |
| M3 | Format channels | JPEG/TIFF/WebP/BMP import, JPEG export, PSD/PSB reading, canvas/image resize, trim | **in progress** |
| M4 | Painting and selection | Brush, eraser, clone stamp, healing, magic wand, color range, layer/vector selections, transforms | **in progress** |
| M5 | Editor shell | Canvas, layer panel, tools, undo/redo, open/save, export, status bar | **in progress** |
| M6 | Camera Raw | Raw decode (LibRaw-class), the eight raw panels, develop preview | not started |
| M7 | AI selection | Subject/background extraction replacing Vision with an ONNX model | **classical stand-in done**: border colour model, centre prior, iterated graph-cut-style smoothing and guided edge refinement, deterministic and tested. A model still has to replace it for photographs; the trait is designed |
| M8 | GPU rendering | D3D12/wgpu compute kernels for brush coverage, layer effects, warp, noise | **first milestone done**: the 24 blend modes and source-over in WGSL on Vulkan, 5.4x faster at 4000x4000, 20 of 24 modes byte-identical to the CPU. Masks, adjustments, effects, sampling and filters still CPU |
| M9 | Text and vector | Inline text editing with IME, font runs, shape layers redrawn at scale | **mostly done**: shaping, bidi, fallback chains, mirroring, caret geometry and on-canvas editing are in; IME, vertical text and bracket-level refinements remain |
| M10 | Packaging and updates | MSIX/portable build, signing, auto-update, crash reporting | **mostly done**: portable zip, MSIX signed with signtool using a self-signed certificate, hashed update manifest, staged replacement, .comp registration. **Code signing is settled by the user's decision**: no purchased certificate and no store submission, because this build is not going to the Store - self-signing is what its distribution needs. Timestamping and crash reporting remain |

## Order of work and why

1. **M1 first.** Everything else serialises through the format: fixtures, tests, saves and exports
   all go through \`comp-core\`. It is also the only part that can be verified against the macOS app
   without running it.
2. **M2 next, verified against an independent oracle.** Blend semantics are the single largest
   correctness risk in the port. \`tools/verify\` contains a second implementation written from the
   W3C/PDF specification, and 29 fixtures compare the Rust output pixel by pixel.
3. **M3 and M4 in parallel with M2.** They depend only on the core types.
4. **M5 keeps the loop closed.** A working window makes every later feature testable by hand.
5. **M6–M10 are the long tail**, deliberately after the pixel core: Camera Raw alone is roughly a
   third of the remaining work, and the GPU kernels only pay off once the CPU path defines the
   behavior they must reproduce.

## What "parity" will require beyond this tree

- **Camera Raw**: LibRaw (or an equivalent raw decoder) plus the eight panels: light, color, curves,
   mixer, grading, detail, optics, geometry.
- **Vision replacement**: subject extraction needs an ONNX Runtime model with a commercial licence,
  plus edge refinement; the macOS app's Vision call has no drop-in equivalent.
- **HEIC/RAW import**: libheif and LibRaw are C libraries with their own licences and build steps.
- **GPU kernels**: D3D12 or wgpu compute shaders for brush coverage, the six layer effects, free
  transform warping and noise, all matching the CPU path bit for bit.
- **Packaging**: MSIX and the portable zip, antivirus false-positive handling, and an auto-updater
  (WinSparkle or Squirrel) replacing Sparkle. Signing is not an open item: a self-signed certificate is
  enough for how this is distributed (development and internal use), and a purchased one would only be
  needed to publish - which the user has decided against.
- **Upstream sync**: the macOS app releases often and the format is already at version 11. Keeping
  parity costs roughly 0.3–0.5 FTE per year.

## Measured performance, and what it means

The feasibility report's highest-risk item was brush latency: the macOS app records 2.6–3.1 ms per
pointer update and 8–9 ms at mouse-up on a 4000x4000 canvas with an 800 px brush. `compc bench`
measures the same shape of number here (`compc bench --canvas 4000 --brush 800 --samples 40`, release):

| Stage | 2000x2000, 400 px | 4000x4000, 800 px |
|---|---|---|
| Brush sample | 16.5 ms median | 85.1 ms median |
| Compositing the changed area | 8.8 ms median | 35.1 ms median |
| **Sample to pixels** | **25.3 ms** | **120.1 ms** |

So the budget was missed by roughly an order of magnitude, and the measurement pointed at two separate
causes rather than one: the stroke session painted a whole brush footprint per dab and rebuilt them
repeatedly, and the region composite re-sampled a layer that could be copied 1:1.

**The stroke half is fixed.** The session now uses a swept-segment deposit model (the same continuous
model the macOS Metal kernel uses), a density lookup instead of per-pixel `exp`/`sqrt`, row-parallel
deposit and compositing that stays bit-for-bit deterministic, and per-tile buffers that grow without
ever reallocating. The macOS-style measurement shape now reads:

| Stage | 2000x2000, 400 px | 4000x4000, 800 px |
|---|---|---|
| Brush sample, before | 16.45 ms | 85.07 ms |
| Brush sample, after | **1.10 ms** (p95 2.15) | **3.95 ms** (p95 6.15) |
| Swath painted per sample | 150k px | 610k px |

That is inside the macOS app's published band (2.6–3.1 ms) for the small case and close to it for the
large one. On a machine busy with another build the same binary reads 8 ms median, so the numbers above
are the quiet-machine figures and `compc bench` is the tool that reproduces them.

**The compositing half is fixed too.** `flatten_region` renders a frame instead of translating a whole
document, places each layer into its own dense box, pre-multiplies only the pixels inside that box,
copies whole rows when a layer is unscaled, and blends row-parallel. It carries the blur halo so a
blurred layer pulls in neighbours correctly, and anchors Grain and Add Noise in document coordinates.
Twenty tests assert `flatten_region(doc, r) == flatten_document(doc)` cropped to `r` **exactly**, not
within a tolerance.

| Stage | 2000x2000, 400 px | 4000x4000, 800 px |
|---|---|---|
| Compositing the changed area, before | 8.83 ms | 35.07 ms |
| Compositing the changed area, after | **1.05 ms** | **3.71 ms** |
| **Sample to pixels, before** | 25.3 ms | 120.1 ms |
| **Sample to pixels, after** | **2.11 ms** | **7.74 ms** (budget 16 ms) |

Both halves of the interaction are now inside the budget the feasibility report set as the project's
biggest risk.

The GPU backend changes the picture for large composites — 5.4x faster than the CPU at 4000x4000
including upload and readback — but for the small regions a brush touches, fixed dispatch and readback
costs dominate, which is why the region fast path has to be fixed on the CPU side first.

## Honest status

This tree is a foundation, not a finished editor. The format layer and the compositing engine are
being built and verified now; the remaining milestones above are scoped but not started. See
\`PARITY.md\` for the module-by-module state with the evidence behind each claim.
