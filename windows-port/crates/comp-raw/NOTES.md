# comp-raw notes

Camera Raw for Windows: the parameter model and the pixel pipeline behind the Camera Raw filter,
plus the entry points that turn a decoded raw buffer or a DNG/TIFF file into a `comp_core::Bitmap8`.

Everything here is a port of the macOS 1.4.5 sources:

| macOS source | What was ported |
|---|---|
| `Compositor/Document/CameraRaw.swift` | ranges, defaults, gains, `normalize`/`isValid`, `applying` (panel eyes), `neutralize`, `autoBalance`, `grainKernelSize`, the order `apply` runs the kernels in |
| `Compositor/Document/CameraRawColor.swift` | parametric + point curves, the eight-family mixer, point colors, the four grading wheels |
| `Compositor/Document/CameraRawDetailOptics.swift` | sharpening, luminance/color noise reduction, defringe, lens distortion, lens-vignetting correction |
| `Compositor/Document/CameraRawGeometryCalibration.swift` | geometry settings, guided corrections, output corners, calibration |
| `Compositor/Rendering/AdjustPixels.c` | `adjust_camera_raw`, `adjust_camera_raw_effects`, `adjust_camera_raw_curve_color`, `adjust_camera_raw_detail`, `adjust_camera_raw_optics`, `adjust_camera_raw_calibration`, `adjust_grain`, `box_blur_plane` and their helpers |
| `Compositor/Rendering/LensPixels.c` | `lens_distort` |
| `Compositor/Document/Curves.swift` | the shape-preserving cubic Hermite point interpolation |

## Public API

```rust
comp_raw::develop(&Bitmap8, &RawSettings) -> Bitmap8              // full-size grade
comp_raw::develop_with(&Bitmap8, &RawSettings, scale, seed)       // preview scale in pixels per layer pixel, grain seed
comp_raw::develop_with_point_color(&Bitmap8, &RawSettings, index) // preview: dim everything outside one point color
comp_raw::develop_buffer(width, height, rgba, &RawSettings) -> Result<Bitmap8>
comp_raw::develop_buffer_with(width, height, rgba, &RawSettings, scale, seed) -> Result<Bitmap8>
comp_raw::decode_file(&Path) -> Result<Bitmap8>                   // DNG/TIFF only
comp_raw::decode_bytes(&[u8], extension) -> Result<Bitmap8>
comp_raw::develop_file(&Path, &RawSettings) -> Result<Bitmap8>
comp_raw::clipping_view(&Bitmap8, &RawSettings, RawClipping) -> Bitmap8 // Option-drag Light preview
comp_raw::clipping_indicator(&Bitmap8, shadows, highlights) -> Bitmap8     // clipping indicators
comp_raw::auto_balance(&Bitmap8) -> Option<(f64, f64)>                     // White Balance > Auto

comp_raw::decode_raw_file(&Path) -> Result<DecodedImage>   // sensor decoder or DNG/TIFF container
comp_raw::decode_raw_bytes(&[u8], ext) -> Result<DecodedImage>
comp_raw::decode_vendor_file(&Path) -> Result<VendorImage> // sensor decoder only
comp_raw::decode_vendor_bytes(&[u8]) -> Result<VendorImage>
comp_raw::decode_vendor_planes(&[u8]) -> Result<(VendorImage, VendorPlanes)> // + intermediate planes
comp_raw::orient(&Bitmap8, RawOrientation) -> Bitmap8      // applies the stored orientation
```

`DecodedImage` reports which backend read the file (`RawSource::Vendor(Box<RawMetadata>)` or
`RawSource::Container`) and, for a sensor decode, the camera, filter pattern, levels, the white
balance that was applied and where it came from, the matrix source and the orientation.

`RawSettings` and its nine groups are `Serialize`/`Deserialize` with camelCase keys and the macOS
enum spellings (`"Auto"`, `"Highlight Priority"`, `"Version 6"`, `"Diffusion"`, …). A test asserts
that no serialized key anywhere contains an underscore, because the Swift decoder reads property
names literally.

## Pipeline order (confirmed against the source)

`CameraRawSettings.apply` (`CameraRaw.swift:221`) wraps one `ImageAdjustmentPixels.run` call; inside
it the kernel calls appear in this order, and `CameraRawGeometrySettings.apply` is called on the
`CGImage` *before* that run starts:

1. **Geometry** — perspective/rotation warp, then Constrain Crop trims the transparent border.
2. **Calibration** — `applyCalibration` (`CameraRawGeometryCalibration.swift:245`).
3. **Light and Color** — one kernel: white-balance gains, exposure, contrast, highlights, shadows,
   whites, blacks, vibrance, saturation (`CameraRaw.swift:242`).
4. **Curve** — parametric curve, then the RGB point curve, then the per-channel point curves.
5. **Color Mixer** — the eight families, then the picked point colors.
6. **Color Grading** — shadow, midtone and highlight wheels plus the global wheel, with Blending and
   Balance deciding how the three tonal wheels overlap.
   Steps 4-6 are one call, `applyCurveColor` (`CameraRawColor.swift:266`).
7. **Effects** — Texture, Clarity, Dehaze, Glow, Vignette (`CameraRaw.swift:249`), then Grain
   (`CameraRaw.swift:258`).
8. **Optics** — distortion, chromatic aberration, defringe, lens-vignetting correction
   (`CameraRawDetailOptics.swift:109`).
9. **Detail** — luminance noise reduction, color noise reduction, sharpening
   (`CameraRawDetailOptics.swift:119`).

`tests/pipeline.rs` pins the order with four composition tests: Light before Curve, Curve before
Mixer, Effects before Optics, and Geometry before every pixel kernel.

Two preview states that macOS folds into `apply` are exposed as their own entry points rather than
as grade settings, because that is what they are: the Option-drag clipping view
(`clipping_view`, the kernel's `clipping` argument — clipped channels lit on black for highlights,
dark on white for shadows) and the clipping indicators (`clipping_indicator`, the separate
`adjust_camera_raw_clip_overlay` kernel — blue over clipped shadows, red over clipped highlights).
The point-color visualization is available through `develop_with_point_color`.

## Differences from macOS

1. **Working representation.** macOS edits a *premultiplied 8-bit* buffer and rounds to bytes after
   every kernel. This crate reads `Bitmap8` (straight alpha), converts once to a floating-point
   raster, runs every kernel in `f64`, and quantizes once at the end. Consequences:
   - The result can differ from the macOS preview by a couple of LSB where a grade is steep,
     because macOS re-rounds between kernels.
   - Straight alpha is used throughout; macOS un-premultiplies with `min(255, p * 255 / alpha)`,
     which for a straight buffer is simply the stored channel.
   - Fully transparent pixels are skipped by every kernel, exactly as on macOS, and keep their
     stored channels. The one exception is the geometry warp, which resamples and therefore can
     cover a transparent pixel, as Core Image does.
   - Grain is added in floating point rather than written as bytes, so a grade that follows grain
     sees a slightly different value than macOS would.
2. **Geometry resampler.** Core Image's `CIPerspectiveTransform` is not available on Windows, so
   `geometry.rs` builds the same projective mapping from the four corner positions, inverts it and
   samples the source bilinearly with premultiplied weights. Corner placement, Guided corrections,
   Constrain Crop and the fit-back-into-the-frame step follow the Swift code exactly; only the
   resampler's interpolation differs from Core Image's, and samples outside the source rectangle
   come out transparent instead of whatever Core Image's sampler returns.
3. **Preview scale.** `develop` renders at one preview pixel per layer pixel (macOS's `scale` = 1).
   `develop_with` takes the scale, and every blur radius follows `effects_radius`/`detail_radius`
   the same way (`base * scale`, clamped to 1…64 pixels or 0.5…64 for sharpening).
4. **White balance** stays relative: `temperature`/`tint` are −100…100 offsets and there is no
   kelvin model, matching `CameraRawWhiteBalance` (`Custom`/`Auto` only). `auto_balance` averages
   the straight pixels of the layer in linear light; macOS un-premultiplies before averaging, which
   is the same thing for the opaque pixels it counts.
5. **Save format.** The macOS build keeps `CameraRawSettings` in the in-memory filter edit; it is not
   part of the `.comp` manifest, and `docs/project-format.md` has no raw entries. `RawSettings`
   nevertheless mirrors the Swift property names one-for-one, so a future manifest or sidecar entry
   can be decoded by `JSONDecoder` unchanged.

## Vendor camera raw decoding

Camera raw files are read by `rawloader` 0.37 (pure Rust, no C toolchain) in `src/vendor.rs`, which
returns the filter-array mosaic plus the camera metadata. The front end then runs the classic dcraw
order and hands the result to the grade:

1. **Levels** — per filter color, `(sample - black) / (white - black)`, from the file's BlackLevel and
   WhiteLevel tags. Float raws arrive normalized and skip this.
2. **White balance** — the file's as-shot multipliers when it has them; otherwise, if the file
   carried a real camera matrix, the 6500 K multipliers that matrix implies (rawloader's
   `neutralwb`); otherwise gray world over the filter colors. Which one was used is reported as
   `WhiteBalanceSource` and shown by `compc raw`.
3. **Demosaic** — each filter color is averaged over the samples of that color in a 3x3 window
   (widened to 7x7 for a 6x6 pattern such as X-Trans), and a pixel keeps its own sample. That is the
   classic bilinear interpolation; it is not the adaptive demosaic a converter would use.
4. **Camera matrix** — dcraw's `cam_xyz_coeff`: compose the camera matrix with the sRGB primaries,
   scale every camera channel so its answer to white is 1, then invert. A file with no matrix is
   assumed to be in sRGB primaries already (an identity matrix), which is reported as
   `MatrixSource::SrgbDefault` rather than pretending a placeholder is a measurement.
5. **sRGB encode** and the usable-area crop (active area / decoder crops, applied as
   top/right/bottom/left).

The grade then runs unchanged, so **temperature and tint are offsets from the shot's own balance**,
Auto white balance still works, and the curve, mixer, grading, effects, optics and detail panels
behave exactly as they do on an imported JPEG.

### Formats and what has been verified with real files

`rawloader` 0.37 carries decoders for ARI, ARW, CR2, CRW/CIFF, DCR, DCS, DNG, ERF, IIQ, KDC, MEF, MOS,
MRW, NEF, NRW, ORF, PEF, RAF, RW2, SRW, TFR and X3F. DNG support covers uncompressed (compression 1)
and lossless-JPEG (compression 7) sensor data, including linear (already demosaiced) DNGs.

Real, license-clear samples were downloaded while developing this (raw.pixls.us, whose archives are
CC0) and are exercised by `tests/vendor.rs`. They are **not** committed: run
`pwsh -File crates/comp-raw/tools/fetch-samples.ps1` (checksums pinned in that script), or point
`COMP_RAW_SAMPLES` at a directory holding them, and the tests run against them.

| File | Size | SHA256 | Result |
|---|---|---|---|
| `Kodak/DC50/RAW_KODAK_DC50.KDC` | 93 KB | `37E290DB…225ECC` | fails readably: the camera is not in rawloader's database |
| `Adobe DNG Converter/Canon EOS 5D Mark III/5G4A9395-compressed-lossy.DNG` | 2.5 MB | `B22F1E36…016A98` | fails readably: `Don't know how to read DNGs with compression 34892` |
| `Blackmagic/Micro Cinema Camera/CAM1_2000-01-01_1707_C0003_000100.dng` | 1.2 MB | `4C65B8CD…85B277` | fails readably: rawloader panics internally on the lossy-JPEG tiles and reports it as an error |
| `Nikon/1 J2/DSC_0451.NEF` | 8.5 MB | `81051EE3…A51219` | **decodes**: 3904x2606 RGGB, as-shot white balance, camera matrix, two unusable rows cropped |
| `Kodak/DCS760C/86L57188.DCR` | 7.5 MB | `D0E6BD0A…9D0DA8` | **decodes**: 3040x2016 GRBG, no as-shot white balance (takes the 6500 K matrix guess), camera matrix |

The URLs are `https://raw.pixls.us/data/<make>/<model>/<file>` with the spaces percent-encoded, e.g.
`https://raw.pixls.us/data/Nikon/1%20J2/DSC_0451.NEF`. End-to-end evidence from this machine:

    compc raw <nef> -o out.png
    decoded with the sensor decoder: Nikon 1 J2 (3904x2606, CFA RGGB, 1 channel(s), black [0,0,0,0],
      white [3300,…], white balance [1.8203125, 1.0, 1.5273438, 1.0] from Camera, matrix from File)
    developed <nef> -> out.png                       # 3904x2604, mean 144.7, deviation 39.0
    compc raw <dcr> -o out.png
    decoded with the sensor decoder: Kodak DCS760C (3040x2016, CFA GRBG, … from Neutral6500K, …)

### Cross-checked with an independent implementation

`tests/vendor.rs` writes a synthetic DNG (TIFF structure, RGGB CFA, BlackLevel, WhiteLevel,
ColorMatrix1, AsShotNeutral — written tag by tag in the test file) plus the intermediate planes the
decoder produced. `tools/vendor_oracle.py` then parses that DNG with its own TIFF reader and
recomputes the whole front end in NumPy from the DNG specification: levels, as-shot white balance,
bilinear demosaic, the dcraw matrix derivation and the sRGB transfer function. Result:

    mosaic plane    max|diff| = 5.064e-08     (float32 rounding)
    camera matrix   max|diff| = 3.019e-07
    sRGB bytes      max|diff| = 0             (256 pixels x 3 channels, not one byte off)
    RESULT: PASS

Pillow cannot open a CFA TIFF, so that third opinion is not available; the script says so and
continues. Run it with:

    COMP_RAW_ORACLE_DIR=<dir> cargo test -p comp-raw --test vendor the_oracle_fixture_is_written_when_asked
    python tools/vendor_oracle.py <dir>

### The decoder needs a big stack, so it gets one

rawloader's lossless-JPEG and Huffman paths use large frames and tables. Measured on this machine
with a 10 MP NEF in a debug build: **1 MB of stack overflows, 2 MB is enough**, and a Windows process
starts its main thread with 1 MB — `compc raw` aborted until this was found. `decode_vendor_planes`
therefore runs the decode on a 16 MB worker thread, so no caller (command line, UI thread, worker
pool) has to know about it, and a decoder panic becomes an `Error::Vendor` instead of taking the
process down.

## Supplementary decoding through LibRaw

CR3, DNG lossy JPEG and camera bodies missing from rawloader's database are covered by an optional
second decoder, LibRaw 0.21.4, behind the `libraw` cargo feature. It is never the first choice: the
pure-Rust decoder runs first and LibRaw only sees what it refused, with the reason recorded in the
metadata. The whole story — versions and checksums, the build scripts, what each sample proved, the
measured binary sizes and the licence/distribution conclusion — is in
**[NOTES-libraw.md](NOTES-libraw.md)**. The short version of the packaging decision: static linking
adds **1.28 MiB** to the executable, the DLL option adds **26 KiB** plus a **1.32 MiB `raw.dll`**;
LibRaw is `LGPL-2.1 OR CDDL-1.0` (the distributor chooses) and libjpeg-turbo is BSD/IJG.

## Not implemented

- **CR3 in the default build.** `rawloader` 0.37 has no CR3 decoder at all (CR3 is an ISO-BMFF
  container, not TIFF), and its per-camera tables do not cover every body. Both gaps are closed by the
  optional LibRaw path above; without that feature the files are refused with the pure-Rust decoder's
  own readable reason, never with a silent or generic failure.
- **No adaptive demosaic, highlight recovery or denoising** in the front end: bilinear demosaic is
  the documented approximation, and the Detail panel is where noise reduction and sharpening happen.
- **Orientation is reported, not applied.** `RawMetadata::orientation` and `orient()` are there; the
  importer decides, which matches how the DNG/TIFF path behaves. Nothing rotates a file silently.
- **Embedded previews** (`PreviewImage` tags in DNG/TIFF) are not extracted; the decoder renders the
  main image only.
- **Lens profile metadata** (distortion and vignetting tables in the file) is still ignored: the
  Optics panel's profile sliders scale a generic correction, exactly as the macOS filter does.
- **CameraRawScope** (the 256-bin histogram and the 64×64 vectorscope, `CameraRaw.swift:333`) is not
  ported. It operates on a rendered image, not on the grade, and belongs with the UI work.
- **Sharpen-mask overlay** (`adjust_camera_raw_sharpen_mask_overlay`) and the panel drag helpers
  (`beginCameraRawDrag`, `sampleCameraRawDefringe`, `commitCameraRawGeometryGuide`) are UI
  interactions. The math they need is present (`sharpen_edge_at`, `pixel_hue_degrees`,
  `guided_corrections`, `RawCurveSettings::nudged`, `RawMixerSettings::weights`), so the panel can be
  wired without touching the pixel code.

### How the pixels were verified

There is no C compiler on this machine (`cl`, `gcc`, `clang`, `zig` — none present), so the kernels
could not be run against `AdjustPixels.c` directly. Verification is two-layered:

1. **An independent oracle.** `tools/oracle.py` re-implements the Light and Color kernel and the
   Curve/Mixer/Grading kernel from the C source in Python. Its output for 13 pixels — exposure,
   contrast, the four tone sliders, vibrance, saturation, white-balance gains, the parametric and
   point curves, the mixer, the grading wheels, refine saturation and the two clipping views — is
   pinned in `src/light.rs`, `src/curve_color.rs` and `src/lib.rs` by tests that require exact
   equality with `comp_raw`. Both layers agree. Run `python tools/oracle.py` and copy the values
   back into those tests if the port changes.
2. **Behavioral tests** for everything the oracle does not cover: sign and monotonicity, locality,
   transparency, extreme-range bounds, determinism, and the four order-sensitive compositions.

Running the oracle (no system Python is assumed; any Python 3 works):

    cd compositor_win/crates/comp-raw
    python tools/oracle.py          # or: py -3 tools/oracle.py

It prints one `NAME = [r, g, b]` line per case. To re-pin after a port change, copy those arrays into
the `graded_pixels_match_the_python_oracle` tests in `src/light.rs` (8 cases) and
`src/curve_color.rs` (5 cases), and the two clipping views into `src/lib.rs`. The script has no
dependencies and never runs as part of `cargo test`.

If a C toolchain ever appears, the next step is to compile `AdjustPixels.c` and `LensPixels.c` into
a small driver and diff their output against `comp-raw` on the same buffers; the difference to
expect is the intermediate 8-bit rounding macOS performs between kernels.

## Going further with LibRaw

The supplementary path described above is already in the tree (see NOTES-libraw.md). The design notes
in this section are for the step beyond it: using LibRaw's *linear* output instead of its developed
sRGB image, which would let this crate's own front end own the matrix and the tone curve for those
files too, or moving the whole supplementary decoder into a helper process so that a native fault in a
third-party decoder cannot take the editor down.

rawloader covers the common formats, but it has no CR3 decoder, it does not know every camera body,
and it refuses DNG lossy JPEG — all three now handled by the optional LibRaw path. The pipeline is
deliberately split so a decoder can be swapped without touching any kernel: a decoder's job is to
produce pixels and metadata, and the grade stays here.

```rust
/// One decoded frame: linear-light RGB plus what the camera recorded about the shot.
pub struct DecodedRaw {
    pub width: u32,
    pub height: u32,
    /// Linear light, 0.0…1.0 after the black/white levels are applied, row-major, three per pixel.
    pub rgb: Vec<f32>,
    /// The camera's as-shot multipliers; `None` when the file carries none.
    pub camera_gains: Option<(f64, f64, f64)>,
    /// The calibration the pipeline must undo before applying the panel's temperature and tint.
    pub camera_temperature: f64,
    pub camera_tint: f64,
}

pub trait RawDecoder {
    fn decode(&self, bytes: &[u8]) -> Result<DecodedRaw, Error>;
}

/// Entry point a LibRaw backend would implement: decode, then develop.
pub fn develop_decoded(decoded: &DecodedRaw, settings: &RawSettings) -> Result<Bitmap8>;
```

Design notes for that work:

- `develop_decoded` needs a linear-light variant of the Light and Color kernel, because a raw frame is
  linear by definition while the current kernel expects sRGB-encoded input. The rest of the pipeline
  (curve, mixer, grading, effects, optics, detail) already works on encoded values and can run
  unchanged after the linear stage encodes its output.
- As-shot white balance maps onto the panel through `RawSettings::neutralize_linear` with the
  camera's linear average, so the eyedropper and Auto white balance keep working on decoded frames.
- A `libraw` backend would be a separate crate (`comp-raw-libraw`) with a `cc`/cmake build, behind a
  cargo feature, so the default build stays pure Rust. `rawloader` is a pure-Rust alternative but
  covers fewer cameras.
- `decode_file` should then consult a registry: try the pure-Rust path first (TIFF/DNG), then the
  optional decoder, then return `Error::Unsupported` with the extension.

## Tests

`cargo test -p comp-raw` (use `CARGO_TARGET_DIR=target-raw-pipeline`) runs 164 tests — 135 unit
tests, 12 pipeline tests and 17 vendor-decoder tests. With `--features libraw` the 12 tests in
`tests/libraw_path.rs` join them, for 176:

- `math.rs`, `blur.rs`, `raster.rs` — the shared primitives, including the kernel's clamp, the
  sRGB round trip, Rec. 709 luminance scaling, box-blur edge behavior and premultiplied sampling.
- `settings.rs` — defaults and ranges, camelCase serialization with no underscores, enum spellings,
  JSON round trip, clamping and non-finite repair, the eyedropper solve, Auto white balance, panel
  eyes, group predicates.
- `curve.rs` — identity detection, endpoint pinning, monotone S-curves, handle repair, parametric
  regions, table shape, the 0…255 ↔ 0…1 conversion.
- `light.rs`, `calibration.rs`, `curve_color.rs`, `effects.rs`, `detail.rs`, `optics.rs`,
  `geometry.rs` — per-panel identity, monotonicity, sign behavior, locality, transparency and
  extreme-value bounds.
- `decode.rs` — TIFF/DNG decode, unsupported extensions, damaged bytes, missing files, buffer sizes,
  the vendor-extension list.
- `tests/pipeline.rs` — the documented kernel order, the buffer entry point, every group acting on its
  own, and a sweep that drives 54 sliders to both ends of their range plus NaN and infinity.
- `tests/vendor.rs` — the synthetic DNG (metadata, CFA mapping, levels, as-shot and gray-world white
  balance, file matrices, linear raws, extension-independent routing), the real samples listed above,
  and the honest degradation when the `libraw` feature is off. Each skips with a note when the sample
  archive is not on this machine.
- `tests/libraw_path.rs` (only with `--features libraw`) — rawloader answers first for the files it
  can read, the four files it cannot decode through LibRaw, the metadata names the engine and the
  reason, the buffer and file entry points agree, decodes are deterministic, and damaged input comes
  back as an error.
