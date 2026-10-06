# compc notes

`compc` is the non-GUI surface of the format: scripts and agents build, inspect, extract from,
rasterize and export projects with it, and the editor's save path is the same comp-core code. This
file records which check drives which subcommand, and what each check actually asserts, so a
command cannot quietly lose its coverage when a script is edited.

## Subcommand coverage

`tools/verify/check_cli.ps1` is the one that guarantees a *failure* path for every command; the
other checks own the deeper semantics of their subject.

| Subcommand | Covered by | Asserts |
|---|---|---|
| `create` | check_cli.ps1 | exit 0, `created`; the package validates (`ok: 1 layers, 8x8`); a render is the colour it was given, pixel for pixel; `--name`/`--resolution` reach `info` and `layers`. Fails: a bad hex colour, a missing `--height`, a zero side |
| `info` | check_cli.ps1 | exit 0; `--json` parses and its width/height match the manifest. Fails: a missing package, a damaged package, no argument |
| `layers` | check_cli.ps1 | names, kinds and sizes as the manifest has them (`Sky [raster] ... 12x7`). Fails: a missing package |
| `validate` | check_cli.ps1, check_versions.ps1, fuzz_hostile.py | exit 0 and `ok: N layers, WxH, digest <hex>`; a package whose asset was cut in half is refused. Fails: damaged, missing |
| `extract` | check_cli.ps1 | the written PNG is byte-for-byte the asset inside the package; `--mask` writes the mask at the canvas size. Fails: an unknown layer, no `--output`, no `--layer`, `--mask` on a layer without one |
| `render` | check_regions.ps1, acceptance.py, check_entrypoints.ps1, check_gpu.ps1 | pixels against the independent oracle, dirty regions, the editor path and the GPU. check_cli.ps1 adds: `--region` output size, and failures for a missing package, no `--output`, a malformed region |
| `resave` | check_cli.ps1 | the copy validates and keeps the canvas; a save creates the folder it needs. Fails: a missing source, an output path inside a file |
| `backends` | check_cli.ps1 | `cpu: always available`; with a package, `this project:`. Fails: a missing package |
| `export` | check_cli.ps1, verify_codecs.py | exit 0, `exported`, the file starts with the JPEG magic. Fails: quality 0, quality 250, a missing package |
| `import` | verify_codecs.py, check_cli.ps1 | the package validates and the canvas matches, with and without `--width`/`--height`. Fails: a missing image, no package argument |
| `psd` | check_psd.ps1, verify_psd.py | whole-file round trips against the Python PSD writer. check_cli.ps1 adds: one real PSD imports (`read ... (2 layers, 32x24)`), and failures for a PNG passed as a PSD and a missing file |
| `sample` | check_cli.ps1, make_fixtures.py, macos_interop.py | exit 0, `wrote sample`; the canvas is 320x200 and the text and shape layers are there; a save creates its folder. Fails: an output path inside a file |
| `filter` | check_filters.ps1 (Lens Correction, Dither), check_cli.ps1 | kernels match the Python oracle. check_cli.ps1 adds: `Gaussian Blur` writes at the same size, and failures for an unknown kind, no `--kind`, a missing input, a missing settings file |
| `filters` | check_cli.ps1 | exit 0 and the list contains the documented names (17 kinds) |
| `bench` | check_perf.ps1, check_cli.ps1 | the interaction budget. check_cli.ps1 adds: a small run reports `sample to pixels`, and failures for non-numeric `--samples`/`--canvas` |
| `update describe/check/verify/apply/status` | check_release.ps1, check_cli.ps1 | the whole update path: a newer build is offered, tampering is caught, apply parks the old build, cleanup removes it. check_cli.ps1 adds: failure paths — a garbage manifest, a missing manifest, no `--dir`, a missing staged binary, no `--version`, an unknown action |
| `rasterize` | check_cli.ps1 | a sampled project rasterizes to a new package that validates, and in place. Fails: a package with no text or shape, a missing package |
| `raw` | check_cli.ps1, verify_codecs.py | a PNG develops at the same size, with and without `--settings`. Fails: an unknown settings key, a missing input, a file that is not an image |
| the argument surface | check_cli.ps1 | `--help` exits 0, lists all 18 subcommands, no subcommand and an unknown subcommand exit non-zero |

`check_cli.ps1` runs 101 checks; every one of them is a real invocation, and every subcommand has at
least one check that expects a *non-zero* exit code, a diagnostic on stderr and no panic.

## Bugs this found

- A mistyped `--color`, `--region`, `--quality`, a layer name that is not there, a layer with no mask
  to extract, a project with nothing to rasterize and unusable raw settings all answered
  `this is not a valid Compositor project, or its metadata is damaged` (exit 1). That wording sends
  whoever ran the command looking at the project instead of at the command line. They now answer
  what is actually wrong: `zz is not a hex colour: use ff8800, ff880080, #ff8800 or the same in
  three digits`, `2,2 is not a region: use x,y,width,height, ...`, `JPEG quality 0 is outside 1-100`,
  `there is no layer named or identified by NoSuchLayer`, `the layer Background has no mask to
  extract`, `no layer in <package> carries text or a shape to rasterize`.
  Minimal reproduction: `compc create out.comp --width 4 --height 4 --color zz`.
- `store::create_fresh`, reached through the library rather than the CLI, reported a path that
  already exists as damaged *manifest* metadata (`Error::manifest("path", ...)`), which points a
  GUI at the wrong repair. It is `Error::IllegalPath { path, .. }` now.

## Not covered here

- `render --gpu` and `bench --full` are smoke-tested only where they share the CPU path; the GPU
  paths belong to check_gpu.ps1.
- `filter --settings` is exercised with a missing file; a valid settings file for each of the 17
  kinds is check_filters.ps1's subject.
- `extract --layer <id>` is covered by the unit test rather than by the script (the script uses a
  name, which is what a person types).
