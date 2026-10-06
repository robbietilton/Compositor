# Independent oracle: 12 adjustment layers and 6 layer effects

The Windows port's adjustment and effect pixel math is checked against a second implementation
written from the macOS sources, never from the Rust crate. Adjustments and blends run on
sRGB-encoded values, as `compositor_mac/Compositor/Rendering/SeparableBlend.swift` states, so
nothing is converted to linear light unless the kernel itself does (Exposure's table).

## Run it

```powershell
$py = "C:\Users\leoevan\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
cd compositor_win\tools\verify\oracle
& $py make_fixtures.py; & $py run_oracle.py
```

`run_oracle.py` renders every fixture with `target-lead/debug/compc.exe render`, compares against
the oracle's PNG pixel by pixel, prints one line per fixture, and writes `report.md` (the table and
the worst-pixel evidence) and `report.json` (the same, machine readable, plus the size and
modification time of the `compc.exe` used). Options: `--only NAME`, `--no-render`,
`--compc PATH`.

Two more tools:

* `diagnose_oracle.py --name X [--row N] [--column N]` - where one fixture disagrees: the bounds
  each image changed, a coarse difference map, and the pixels along a row or column.
* `probe_effects.py` - five one-layer documents that isolate the effect geometry (see D2 below).

## Files

| File | What it is |
|---|---|
| `oracle_core.py` | premultiplied 8-bit helpers, 256-entry table lookup, 33-cube trilinear lookup, Gaussian and streak blurs, the square morphology and the effect fills |
| `oracle_adjust.py` | the twelve kernels: Hue/Saturation, Levels, Curves, Exposure, Gradient Map, Grain, Add Noise, Gaussian Blur, Motion Blur, Invert, Black & White, Color Balance |
| `oracle_effects.py` | the six effects in `LayerEffectsRenderer`'s order, on a margin-padded surface |
| `oracle_comp.py` | a minimal `.comp` writer/reader (version 11), used only for these fixtures |
| `make_fixtures.py` | builds `fixtures-oracle/*.comp` and the expected PNG for each |
| `run_oracle.py` | renders, compares, reports |
| `diagnose_oracle.py`, `probe_effects.py` | divergence tools |

`inspect_fixture.py` and `run_all.ps1` in this directory are not part of this package (they
came from the parallel attempt); they are left alone.

Everything this package writes lives under `fixtures-oracle/`. The packages are ordinary
documents: one opaque 64x48 chart layer (a red/green gradient crossed by a blue diagonal, eight
saturated blocks, black and white probes), then the adjustment layer, or a white 16x12 shape layer
with effects for the effect fixtures.

## Sources ported

```
compositor_mac/Compositor/Rendering/AdjustPixels.c      gradient map, grain, black & white, color balance
compositor_mac/Compositor/Rendering/LevelsPixels.c      levels_apply, cube_apply
compositor_mac/Compositor/Rendering/NoisePixels.c       add noise, uniform and Gaussian
compositor_mac/Compositor/Document/Levels.swift         LevelRange, composite range last
compositor_mac/Compositor/Document/Curves.swift         Hermite curve, channel then RGB
compositor_mac/Compositor/Document/ImageAdjustments.swift  Exposure, Gradient Map, Grain, Black & White, Color Balance
compositor_mac/Compositor/Document/HueSaturation.swift  HSL, band weights, the 33-cube
compositor_mac/Compositor/Document/Filters.swift        Gaussian and motion blur, add noise
compositor_mac/Compositor/Document/PixelInvert.swift    premultiplied invert
compositor_mac/Compositor/Document/LayerEffects.swift   LayerEffectsRenderer: order, margin, coverage, stroke ring
compositor_mac/Compositor/Rendering/GPUCanvas.swift      which kinds the canvas runs through a cube
```

## Conclusions

41 fixtures: 31 adjustment/control, 10 effect. `worst` is the largest absolute channel difference
over the whole canvas, `mean` the average over all RGB samples, tolerance 1 for the exact classes
(one unit is two equivalent float expressions rounding apart) and wider only where the kernel
itself may differ.

| Kind | Fixtures | worst | mean | Verdict |
|---|---|---|---|---|
| Hue/Saturation | hsv-identity / hsv-master / hsv-reds | 0 / 12 / 14 | 0.000 / 0.278 / 0.197 | identity exact; the two real cases match the **direct** formula (variant hsv-direct: worst 1) but not the mac's 33-cube path (D3) |
| Levels | identity / work / clip | 0 / 0 / 0 | 0 | consistent, exactly |
| Curves | identity / s-curve | 0 / 0 | 0 | consistent, exactly |
| Exposure | identity / +0.8 stops | 0 / 0 | 0 | consistent, exactly |
| Gradient Map | default / duotone / reversed-bw / warm-end | 237 / 0 / 0 / 0 | 55.4 / 0 | **default black-to-white ramp is a no-op (D1)**; the other three are exact |
| Grain | default / coarse | 0 / 0 | 0 | consistent, exactly (same seeded lattice) |
| Add Noise | uniform / Gaussian+mono | 0 / 0 | 0 | consistent, exactly (same hashes and seed) |
| Invert | chart / partial alpha | 0 / 1 | 0 / 0.001 | consistent, including the premultiplied path |
| Black & White | defaults / tinted | 0 / 0 | 0 | consistent, exactly |
| Color Balance | identity / warm / no luminosity | 0 / 0 / 0 | 0 | consistent, exactly |
| Gaussian Blur | radius 0.1 / radius 4 | 0 / 4 | 0 / 0.177 | consistent: sigma is the radius and the edges blur into transparent black (the edge-clamped variant is 63) |
| Motion Blur | distance 1 / 30 degrees, 9 px | 0 / 73 | 0 / 1.975 | identity exact; the angle's sign is confirmed (+30 gives 73, -30 gives 196); the residue is the streak profile (D4) |
| Stroke (outside, inside) | 2 | 255 / 252 | 22.8 / 0.699 | **diverges: effect geometry (D2)** |
| Drop Shadow | hard, horizontal, blurred | 222 / 255 / 185 | 8.3 / 94.7 / 8.5 | **diverges: effect geometry (D2)** |
| Outer Glow, Inner Glow, Inner Shadow | 3 | 175 / 155 / 104 | 7.7 / 0.5 / 0.8 | **diverges: effect geometry (D2)** |
| Color Overlay | 1 | 148 | 0.400 | **diverges: coverage one pixel wider each side (D2)**; the fill color itself matches within 1 |
| Stack (shadow + overlay + stroke) | 1 | 252 | 8.4 | diverges with the others |

Controls: `control-base` (the chart alone) and `control-identity-normal` (an identity Levels
adjustment layer) both render bit-identically, so the fixture scaffolding, the layer placement and
the identity path are sound.

## Divergences, with evidence

### D1 Gradient Map with the default ramp is skipped

`gradientmap-default` (shadows black, highlights white, `reversed` false) renders as if the
adjustment layer were absent: the render equals the `control-base` render exactly (mean difference
55.4 over the canvas, worst 237). The oracle's luminance ramp is a real change (Photoshop's
default gradient map is a desaturation, not an identity).

* worst pixel (19, 7): base [0, 0, 255] -> expected [18, 18, 18], actual [0, 0, 255].
* `gradientmap-reversed-bw` - the *same two ends* with `reversed` true - matches exactly (worst 0),
  and `gradientmap-warm-end` (black to orange) matches exactly, so the colors are read and only the
  default black/white pair is treated as identity.

### D2 The effect surface is not placed in a margin-grown rectangle

The macOS renderer grows the layer's transform by `LayerEffectsRenderer.margin` so the padded
surface lands one-to-one in the document. The Windows render samples land somewhere else, and where
depends on the margin: `probe_effects.py` renders the *same* 16x12 box at (62, 18) once per case.

| Case | Layer pixels | Expected coverage (macOS model) | Rendered coverage |
|---|---|---|---|
| no effect (control) | x 62..77, y 18..29 | - | x 62..77, y 18..29 |
| color overlay (margin 2) | x 62..77, y 18..29 | x 62..77, y 18..29 | x 61..78, y 18..29 |
| drop shadow, distance 3, margin 5 | x 62..77, y 18..29 | x 62..77, y 21..32 | x 57..82, y 15..35 |
| drop shadow, distance 10, margin 12 | x 62..77, y 18..29 | x 62..77, y 28..39 | x 67..72, y 22..28 |
| outside stroke, size 4, margin 6 | x 62..77, y 18..29 | x 58..81, y 14..33 | x 43..96, y 4..43 |

The coverage rectangle therefore grows with the margin in one case and shrinks in another, while
the layer's own pixels stay exact - so this is placement and scale, not the effect's color math.
The fixtures show the same thing: `effect-shadow-hard` expects white at (28, 28) (the layer's pixel
over its shadow) and renders the shadow's dark [33, 42, 57]; `effect-stroke-outside` expects
[176, 140, 0] at (44, 28) and renders white; `effect-coloroverlay` covers x 23..40 where the shape
is x 24..39, and inside that one-pixel band the color is right to within one unit.

### D3 Hue/Saturation: direct math versus the macOS colour cube

Both real HSV fixtures match the per-pixel formula to within one unit and differ from the cube by
up to 12 (mean 0.28). The mac runs Hue/Saturation through `cube_apply` with a 33-entry cube
(`HueSaturationFilter.run`), so the Windows engine is doing the more accurate thing rather than
reproducing the mac's interpolation error. Worst pixel (59, 42): expected [250, 158, 161] (cube),
actual [255, 146, 149], direct oracle [255, 146, 149]. Decide whether bit-parity with the mac
canvas matters; the same choice applies to Curves, Black & White, Color Balance, Exposure and
Gradient Map, whose cube variants are also one to six units off, but which match exactly here.

### D4 Motion Blur and Gaussian Blur are kernel-dependent

* Gaussian Blur is a genuinely good match: sigma is the radius (worst 4 at radius 4, mean 0.18) and
  the edges blend into transparent black, as `CIGaussianBlur` does - the edge-clamped variant is
  63, so the edge policy is confirmed, not assumed.
* Motion Blur: the mac uses `CIMotionBlur` with radius `distance / sqrt(12)`, a Gaussian-tapered
  streak; the oracle models Photoshop's even smear. The +30 degree variant matches far better than
  -30 (worst 73 versus 196, mean 1.98 versus 8.35), which pins the angle's sign and direction. The
  remaining difference is the streak profile and the alpha at the canvas corner (62, 47): expected
  alpha 57, rendered 78. Nothing here looks like a formula error, but the profile cannot be called
  identical either.

## Cross-check of the second oracle's findings

A parallel attempt at this task produced its own oracle and five findings before it was stopped.
I could not read its report (hand-off note: my comparison run had already rewritten the shared
`report.md` / `report.json` paths), so the verdicts below come from my own fixtures. Two of the
three findings the Lead flagged are confirmed, one is not supported.

| Claim | My evidence | Verdict |
|---|---|---|
| Gradient Map's identity skip is a formula-level divergence | D1: `gradientmap-default` renders as the untouched chart (mean 55.4, worst 237 at (19,7): expected [18,18,18], actual [0,0,255]) | Confirmed, and narrowed: only the plain black-to-white pair. `gradientmap-reversed-bw` (same ends, `reversed` true) and `gradientmap-warm-end` (black to orange) are exact |
| The `hsvSettings` dictionary shape is mishandled | `hsv-reds` does apply the range (`changed` true against the base render) and matches the direct Reds formula to worst 1; its 14-unit residual is the same cube-versus-direct difference the master range shows (12) | Not supported: the shape is read and applied. The residual is D3, not a parse problem |
| The effect surface geometry is wrong for margin > 2 | D2: it is already wrong at margin 2 (coverage 1 px wider each side) and the coverage rectangle grows or shrinks with the margin (shadow distance 3 -> 26x21, distance 10 -> 6x7, stroke size 4 -> 54x40, all centred on the layer) | Confirmed, and extended: it is a placement and scale defect, not a kernel difference |

## Unresolved, and what to do next

1. **Gradient Map default is a no-op (D1)** - a one-line identity shortcut or an unset table. Fix in
   `comp-render`; `gradientmap-default.comp` is the regression test.
2. **Effect surface placement (D2)** - nine of the ten effect fixtures fail because of it, so every
   effect should be re-checked after it is fixed. The cause is not visible from the outside; the
   render side should compare its placement against `LayerEffectsRenderer.margin` / `placed`
   (grow the transform by the margin, land the padded surface one-to-one). `probe_effects.py`
   reproduces all five geometries in one run.
3. **Blur radius and offset inside the effects** - once the surface is placed right, re-run this
   oracle: the unblurred effects (stroke, color overlay, hard shadow) must reach worst 1, and the
   blurred ones (glow, inner shadow, shadow with blur) can then be judged against the
   `CIGaussianBlur(sigma: blur / 2)` model with the tolerance explained by the kernel alone.
4. **Hue/Saturation and the cube (D3)** - decide the parity target. If bit-parity with the macOS
   canvas is wanted, the 33-cube path has to be ported too; if not, the current direct math is
   correct and the oracle's `hsv-direct` variant should be the reference.
5. **Verification identity** - `target-lead/debug/compc.exe` was rebuilt at 20:05:42 during this
   work, so earlier intermediate results were discarded; every number above comes from that build
   (9,979,392 bytes, recorded in `report.json`). Re-run this oracle after any render change before
   trusting the table.
