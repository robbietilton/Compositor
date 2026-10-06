# Building LibRaw for compositor\_win

Three scripts and one CMake file. They fetch the pinned sources, build them, and leave everything under
`target-raw-pipeline/libraw/` — nothing here writes into the source tree, and nothing here belongs in
version control.

## Commands

    pwsh -File tools/libraw/fetch-libraw.ps1              # download + verify checksums + unpack
    pwsh -File tools/libraw/build-libraw.ps1              # static libraw_r.lib (+ jpeg-static.lib)
    pwsh -File tools/libraw/build-libraw.ps1 -Shared      # also raw.dll, for the packaging choice
    pwsh -File tools/libraw/build-libraw.ps1 -Tools       # also LibRaw's dcraw_emu and raw-identify
    pwsh -File tools/libraw/build-libraw.ps1 -Force       # ignore existing build directories

Then build the crate with the feature:

    $env:CARGO_TARGET_DIR = "target-raw-pipeline"; cargo test -p comp-raw --features libraw
    cargo build --release -p comp-cli --features libraw            # static, +1.28 MiB in the exe
    $env:LIBRAW_DLL = "1"; cargo build --release -p comp-cli --features libraw   # +26 KiB + raw.dll

`comp-raw`'s `build.rs` finds the libraries through `LIBRAW_ROOT` (default
`target-raw-pipeline/libraw`) and fails with the command to run when they are missing. `LIBRAW_DLL=1`
switches it to the shared build's import library, and then `raw.dll` has to sit beside the executable.

## What gets built, and why

| Source | Version | SHA256 | Artefact |
|---|---|---|---|
| `LibRaw-0.21.4.tar.gz` (libraw.org) | 0.21.4 | `6BE43F19…A09E63` | `libraw_r.lib`, or `raw.dll`+`raw.lib` |
| `libjpeg-turbo-3.1.2.tar.gz` (GitHub releases) | 3.1.2 | `8F001223…67D0CF` | `jpeg-static.lib` |

libjpeg is not optional here: LibRaw's `lossy_dng_load_raw` is the only way to read a DNG whose sensor
data is lossy JPEG (compression 34892), and it is built against the libjpeg API. It is built with
`WITH_SIMD=OFF` so no NASM is needed, and with `WITH_CRT_DLL=ON` because Rust links the dynamic CRT:
LibRaw is built the same way, and mixing the two CRTs in one process is a bug waiting to happen.

The CMake file compiles the official source tree directly (the tarball has no CMake of its own — upstream
moved that to a separate repository) and excludes the `*_ph.cpp` placeholder sources, which reimplement
the same symbols for a build without postprocessing tools and would fail the link with duplicate symbols.

## Licence

LibRaw 0.21.4 is `LGPL-2.1 OR CDDL-1.0`; the distributor chooses. libjpeg-turbo is BSD-3-Clause/IJG.
The measured sizes for both linking modes and what each licence route requires are written up in
`crates/comp-raw/NOTES-libraw.md`. The default build of the crate does not link LibRaw at all.
