# LibRaw as the supplementary decoder

LibRaw is the pure Rust decoder's backup, not its replacement. The default build does not link it at
all; `--features libraw` turns it on.

## Versions, sources and checksums

| Part | Version | Source | SHA256 |
|---|---|---|---|
| LibRaw | 0.21.4 | `https://www.libraw.org/data/LibRaw-0.21.4.tar.gz` | `6BE43F19397E43214FF56AAB056BF3FF4925CA14012CE5A1538A172406A09E63` |
| libjpeg-turbo | 3.1.2 | `https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.1.2/libjpeg-turbo-3.1.2.tar.gz` | `8F0012234B464CE50890C490F18194F913A7B1F4E6A03D6644179FA0F867D0CF` |

libjpeg is what makes DNG lossy JPEG (compression 34892) work: LibRaw's `lossy_dng_load_raw` calls the
libjpeg API directly, and without it that function is a stub. libjpeg-turbo is BSD-3-Clause and IJG
licensed, so it adds no copyleft of its own.

    pwsh -File tools/libraw/fetch-libraw.ps1     # downloads, verifies both checksums, unpacks
    pwsh -File tools/libraw/build-libraw.ps1     # libjpeg-turbo + static libraw_r.lib
    pwsh -File tools/libraw/build-libraw.ps1 -Shared   # also raw.dll, for the packaging comparison
    pwsh -File tools/libraw/build-libraw.ps1 -Tools    # also LibRaw's own dcraw_emu / raw-identify

Everything lands under `target-raw-pipeline/libraw/`, which is a build directory: no source, no
object file and no library from this belongs in version control. `tools/libraw/CMakeLists.txt` is the
only build script that lives in the tree, because the official tarball has no CMake support of its own
(upstream moved it to a separate repository).

## Routing: who decodes, and why

    decode_raw_file / decode_raw_bytes
      ├─ .tif/.tiff  → the image crate first (a TIFF is usually a rendered image)
      ├─ .dng        → the sensor chain first (a DNG is usually sensor data)
      └─ vendor extensions → the sensor chain

    sensor chain:
      1. rawloader (pure Rust, no distribution cost)
      2. LibRaw, only when this build carries it and step 1 failed

Every decode reports which engine answered, which decoder LibRaw used, and what step 1 said:
`RawMetadata::{engine, decoder, fallback_reason}`, shown by `compc raw`:

    decoded with the LibRaw decoder: Canon EOS R6 (3584x2386, CFA RGGB, 3 channel(s), …)
      LibRaw used crxLoadRaw()
      the pure-Rust decoder was tried first and said: RawLoaderError: "Couldn't find a decoder for this file.

That last line is the point of the design: a file that LibRaw reads is still evidence about what
rawloader could not do, and the pure-Rust decoder keeps everything it already handled.

### What each sample proved

Real CC0 samples from raw.pixls.us, downloaded by `crates/comp-raw/tools/fetch-samples.ps1` with
pinned checksums. From `cargo test -p comp-raw --features libraw`:

| Sample | Before LibRaw | With LibRaw |
|---|---|---|
| `canon-eos-r6-craw.CR3` (5.3 MB) | rawloader: `Couldn't find a decoder for this file` | **decoded**, `crxLoadRaw()`, 3584x2386 declared, 3407x2271 image |
| `canon-5d3-compressed-lossy.DNG` (2.5 MB) | rawloader: `Don't know how to read DNGs with compression 34892` | **decoded**, `lossy_dng_load_raw()`, 3960x2640 |
| `blackmagic-micro-linear.dng` (1.2 MB) | rawloader: internal panic, reported as an error | **decoded**, `lossless_dng_load_raw()`, 1952x1104 |
| `RAW_KODAK_DC50.KDC` (93 KB) | rawloader: camera not in its database | **decoded**, `kodak_radc_load_raw()`, 768x512 |
| `nikon-1j2.DSC_0451.NEF` (8.5 MB) | rawloader: decoded | **still rawloader**, no fallback recorded |
| `kodak-dcs760c.DCR` (7.5 MB) | rawloader: decoded | **still rawloader**, no fallback recorded |

Two bugs were found and fixed while wiring this up, both worth remembering:

- **An ABI mistake that cost an access violation.** `libraw_processed_image_t` ends in a flexible
  array member `unsigned char data[1]`. Declaring it as `*const u8` puts the field at offset 24 (the
  pointer needs eight-byte alignment) while C puts the first pixel at offset 16, so every decode read
  a pointer out of the pixel data and died. It is a `[u8; 0]` now, which keeps offset 16, and the CR3
  test is what caught it.
- **The placeholder sources.** LibRaw's tarball contains `postprocessing_ph.cpp`,
  `preprocessing_ph.cpp` and `write_ph.cpp`, which reimplement the same symbols "to build LibRaw w/o
  postprocessing tools". Globbing every `.cpp` compiles both sets and the link fails with multiply
  defined symbols; the CMake file excludes `*_ph.cpp`.

## Distribution: size and licence

Measured on this machine with `cargo build --release -p comp-cli` (Rust 1.97, MSVC 19.44, thin LTO):

| Configuration | `compc.exe` | Delta | Files to ship besides the exe |
|---|---|---|---|
| default (no LibRaw) | 35,407,872 B (33.8 MiB) | — | none |
| `--features libraw`, static | 36,749,824 B (35.0 MiB) | **+1,341,952 B (+1.28 MiB)** | none |
| `--features libraw`, `LIBRAW_DLL=1` | 35,434,496 B (33.8 MiB) | **+26,624 B (+26 KiB)** | **`raw.dll`, 1,386,496 B (1.32 MiB)** |

So the choice is a megabyte and a half inside the executable, or a 1.3 MiB DLL next to it. Both were
built and run here: the DLL build decoded the CR3 sample to a PNG (`compc raw`, exit 0).

**Licences, stated plainly.** LibRaw 0.21.4 is dual licensed, `LGPL-2.1 OR CDDL-1.0`, and the person
distributing the built product chooses which one to rely on. Both licence texts sit in the tarball
(`LICENSE.LGPL`, `LICENSE.CDDL`) and in every source header. libjpeg-turbo is BSD-3-Clause/IJG, so
it imposes nothing beyond attribution. In practical terms:

- **Default build**: LibRaw is not linked at all, so a binary built without the `libraw` feature
  carries no LibRaw obligation.
- **Static link (`+1.28 MiB in the exe`)**: the LGPL route requires giving recipients the means to
  relink the program against a modified LibRaw — with a static library that means shipping object
  files or equivalent, which is awkward for a closed-source product. The CDDL route is file-based
  copyleft: LibRaw's own files (and any modification of them) stay under CDDL and must remain
  available, while the rest of the program may stay proprietary. LibRaw is used here unmodified, from
  the pinned tarball, which keeps that route simple.
- **DLL (`+26 KiB in the exe, raw.dll to ship`)**: replacing a DLL is the classic way to satisfy the
  LGPL relinking requirement, so shipping `raw.dll` (plus its licence text and the LibRaw source or a
  written offer for it) is the option that keeps both routes open with the least paperwork.

This is engineering documentation of what the code does and what the licences say, not legal advice:
whoever ships the product should confirm the choice with counsel.

## Not implemented

- **Camera-specific colour science.** LibRaw identifies the body and applies its own matrix and white
  balance; the panel's temperature and tint are still offsets on top of that, not a kelvin model.
- **Automatic brightness is off on purpose** (`no_auto_bright`), so a decode depends only on the file
  and not on the picture's own histogram. LibRaw's output is therefore flatter than a converter's; the
  grade's exposure is where that is meant to be fixed. This is also why the determinism test can assert
  byte equality between two decodes.
- **Orientation** is applied by LibRaw inside its own develop step, so `RawMetadata::orientation` is
  reported as `Unknown` with `crops` at zero for this path; the rawloader path still reports both.
- **Black levels** are not exposed by LibRaw's C accessors, and LibRaw has already applied them, so the
  metadata reports zero black and the white level the file declared.
- **CR3 C-RAW is decoded as LibRaw sees fit**; the extended crop mode and dual-pixel data are not
  reinterpreted here.
