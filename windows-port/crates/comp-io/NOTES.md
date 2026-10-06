# comp-io notes

Everything outside the .comp package: raster import and export, Photoshop reading, and the
document-level size operations. The macOS sources under `compositor_mac/Compositor/IO/` are the
behavior reference; this crate ports the semantics, not the structure.

Build and test with your own target directory:

```
$env:CARGO_TARGET_DIR = "E:\Compositor-main\compositor_win\target-raster-io"
cargo test -p comp-io
```

## Public API

| Call | Purpose |
|---|---|
| `import_image(path) -> IoResult<Bitmap8>` | Pixels only. |
| `import_raster(path, &ImportOptions) -> IoResult<ImportedRaster>` | Pixels, format, file DPI, file stem, whether EXIF orientation was applied. |
| `import_document(path) -> IoResult<Document>` | One-layer document the size of the image, layer named after the file. |
| `decode_raster(bytes, &ImportOptions)` | The same without a file, for tests and in-memory callers. |
| `place_imported(&mut Document, raster, Option<PointF>)` | Adds a layer centered on the canvas, inside the active group (macOS `EditorSession.insert`). |
| `export_png(&Bitmap8, path, resolution)` / `encode_png` | RGBA8 PNG with a pHYs chunk. |
| `export_jpeg(&Bitmap8, path, quality, resolution)` / `encode_jpeg(&Bitmap8, &JpegOptions)` | Quality 0-100, JFIF density, alpha flattened over a background (white by default). |
| `read_psd(bytes) -> IoResult<Document>` | Layers only. |
| `read_psd_with_report(bytes) -> IoResult<PsdImport>` | Layers plus every conversion the import had to make. |
| `read_psd_with_options(bytes, &PsdReadOptions)` | Adds a pixel budget and strict reading. |
| `resize_image`, `crop_image`, `trim_rect`, `trim_image` | One raster. |
| `resize_document`, `canvas_resize`, `crop_document`, `trim_document` | A whole document, layers and masks included. |

## Support matrix

### Raster formats

| Format | Import | Export | Resolution metadata | Notes |
|---|---|---|---|---|
| PNG | Yes (through `comp_core::png_io`) | Yes (`encode_rgba8` plus pHYs) | Read and written | 8-bit stays in `comp_core::png_io` (palette, gray and gray+alpha expand to RGBA); a 16-bit PNG is scaled to 8 bits on import, see below. Export stays 8-bit because every layer is a `Bitmap8`. |
| JPEG | Yes | Yes | JFIF APP0 density, read and written | Alpha flattens over the background color, as the macOS JPEG export does. |
| TIFF | Yes | No | IFD0 tags 282, 283 and 296, read | 8-bit gray, RGB and RGBA, and 16-bit gray, gray+alpha, RGB and RGBA scaled like a PNG; 32-bit float is refused. Unit 1 (no absolute unit) is not a DPI and reads as none. |
| BMP | Yes | No | biXPelsPerMeter and biYPelsPerMeter, read | 24- and 32-bit BMPs import; alpha survives a 32-bit BMP. A BITMAPCOREHEADER has no resolution fields. |
| WebP | Yes | No | The EXIF chunk's IFD0, read | Lossy, lossless and extended; the first frame of an animation is imported. XMP-only resolution is not read; see the limits below. |
| SVG | Yes (rasterized) | No | - | Drawn once into pixels by resvg, the way macOS draws it with its own renderer; nothing stays vector. |
| HEIC, HEIF | Yes | No | Exif item tags 282, 283 and 296 | Read through the Windows Imaging Component, the Windows counterpart of ImageIO. Needs the HEIF Image Extension from the Store; without it the import says so. See the section below for the gaps. |
| AVIF, AVIFS | Yes | No | Exif item tags 282, 283 and 296 | The same container coded with AV1, read by the same system decoder, so it shares the whole HEIC path. |
| RAW | No | No | - | macOS has `RawImporter` (Core Image RAW). The `comp-raw` crate owns that work now. |
| PSD, PSB | Yes (read only) | No | Image resource 1005 | See below. |

Import always enforces `comp_core::limits`: at most 30000 pixels per side, 200 megapixels per
surface, and the remaining document budget. A PNG's IHDR is checked before decoding so an oversized
file never allocates, and an SVG's declared size is checked before a pixmap is created.

### SVG rasterization

| Feature | Status |
|---|---|
| Shape, path, transform, group, clip, mask, gradient, pattern | Rendered by usvg and tiny-skia. |
| Filters, blend modes, markers, embedded raster images (including `data:` URIs) | Rendered; resvg's `raster-images` feature is on. |
| Text | Rendered from the system's font database, which is loaded lazily: only a document that mentions text, a font family or a stylesheet pays for the scan. An SVG that names a font the machine does not have falls back like any other renderer. |
| Size | The declared width and height win; a `viewBox` alone scales to the declared size; a document with neither is sized from its content. The result is rounded to whole pixels with at least one, as macOS rounds the drawn size. |
| Background | Transparent unless the document paints one, exactly like the macOS path. |
| Animation, scripting, external references | Ignored, as a still rasterization must. A `<script>` element is not executed, which is also what the macOS renderer does. |
| Alpha | tiny-skia renders premultiplied; the importer divides the alpha back out so `Bitmap8` stays straight. |
| Resolution | A vector file carries no DPI, so the document keeps the default (or the caller's `ImportOptions::resolution`). |

### Photoshop reading

| Feature | Status |
|---|---|
| Header, color mode, canvas, depth | 8-bit RGB accepted; CMYK, Lab, grayscale, indexed and 16/32-bit are refused with the mode and depth named. |
| PSD and PSB | Both; PSB 64-bit section and channel lengths, and 4-byte PackBits row counts. |
| Layer records, names | Yes. `luni` (UTF-16) first, MacRoman for legacy pascal names. |
| Folders | Yes, from `lsct`/`lsdk` sections 1, 2 and 3, reordered so a group precedes its subtree, which the document model requires. |
| Opacity | Yes, multiplied by the fill opacity (`iOpa`); a layer whose effects already carry the fill is not multiplied twice. |
| Blend modes | All 24 keys Compositor has. Dissolve, Darker Color and Lighter Color have no equivalent and become Normal with a conversion note. |
| Channels | RAW, PackBits and ZIP (with and without prediction). An unknown method is an error naming the number. Spot and extra channels are reported, never dropped quietly. |
| Layer masks | Yes, from channel -2, baked onto the layer's own pixel grid with the file's default value outside the patch (macOS's `maskOnLayerGrid`). |
| Clipping masks | Yes, `mask_source` points at the layer below; an unsupported base is reported. |
| Adjustment layers | Levels and Curves map onto `comp_core::Adjustment`. Hue/Saturation, Exposure, Gradient Map and the rest are reported and the layer is skipped, which is what macOS does for a block its parser does not know. |
| Text layers | Imported as their stored pixels, with a note that the text is not editable. macOS renders the type itself; this build has no font engine. |
| Vector shapes, smart objects, layer effects | Their pixels are imported and the loss is reported, as macOS does. |
| Files without layer records | The merged image is decoded (raw or PackBits) into one "Background" layer. ZIP in the merged section is refused by number. |

### Reading results

`PsdImport` carries the document, the header, the resolution and a `Vec<PsdConversion>`. Every
approximation lands there, so a caller can show it the way macOS shows its conversion sheet.
`PsdReadOptions::strict` turns any conversion into an `UnsupportedFeature` error instead.

### Intentional differences from macOS

- **File resolution on import.** macOS always starts a document at 72 dpi because it does not read
  ImageIO's DPI properties. Here an imported file's own DPI is used when it has one, so a 300 dpi
  PNG, JPEG, TIFF, BMP or WebP round-trips. `ImportOptions::resolution` overrides it, and 72 dpi is
  still the fallback.
- **SVG rasterization uses resvg**, macOS uses its own renderer through `NSImage`. Both draw the
  file once into pixels at the declared size; antialiasing and font substitution differ the way any
  two renderers differ.
- **ZIP layer channels** are read; macOS's `PSDChannelCoder` supports only raw and PackBits.
- **Masks are always linked.** macOS carries the PSD mask link flag; here the mask buffer is already
  on the layer's grid, so `mask_linked` is true and `mask_placement` stays unset. The geometry is
  identical; only the flag differs.
- **Image Size bakes rotation and flips into pixels** and writes an axis-aligned transform, as
  macOS's `ImageResizer` does by rasterizing each layer through Core Graphics.

## Wide samples and JPEG chroma

Two gaps found by comparing this crate with Pillow, both closed in this pass.

### 16-bit files are scaled, not refused

macOS reads 16-bit PNGs and TIFFs natively through ImageIO, and a layer holds straight 8-bit RGBA,
so the samples are converted on import: `round(value * 255 / 65535)`, which is `value / 257`
exactly. Zero and 65535 land on 0 and 255, every one of the 256 levels stays reachable, and the
middle rounds up (32768 becomes 128). Keeping the high byte instead (`value >> 8`) would floor the
value, so 1 through 256 would all read as black and 32896 would land a level low. Alpha stays
straight, and gray, gray+alpha, RGB and RGBA are all handled.

PNG goes through the image crate for this, because `comp_core::png_io` refuses anything wider than
8 bits on purpose: a package asset may not be one. 32-bit float rasters remain an explicit
`UnsupportedDepth` error; there is no 8-bit mapping that would not invent a tone curve.

### JPEG chroma upsampling matches libjpeg

JPEG is now decoded with `zune-jpeg` directly instead of through the image crate, so its YCbCr
planes can be read. `zune-jpeg` is the same release the image crate already depended on, so no new
crate joined the tree; the direct dependency exists only to reach `JpegDecoder` and
`DecoderOptions`.

zune-jpeg's chroma upsampling is libjpeg's triangle filter and agrees with libjpeg on every column
but the last. On an even-width subsampled image the last column has no neighbour to blend with, and
libjpeg repeats the last chroma sample into it; zune-jpeg instead upsamples the padded MCU row and
blends in a sample from outside the picture. That single column was the entire disagreement:
measured against Pillow on the 24x18 reference files, the worst difference was 16 levels at 4:2:0
and 32 at 4:2:2, and 2 at 4:4:4, with every other pixel within 3.

The decoder now rebuilds that column: the chroma sample follows from the two columns before it
through libjpeg's own filter, and the result is converted with libjpeg's fixed-point constants
(91881, 22554, 46802 and 116130 shifted right by 16 with one half added) so the arithmetic matches
what ImageIO and Pillow produce. Two neighbouring samples can share both filtered values, so the
reconstruction can be one level out, which is the resolution those columns have left.

After the change, against Pillow: 4:4:4 2 levels (unchanged), 4:2:2 3 (was 32), 4:2:0 3 (was 16),
grayscale 1. Files this path does not read itself - CMYK and YCCK, components tagged RGB, damaged
files - fall through to the image crate, which reports the same errors as before.

## Verification

Three scripts drive the crate against tools that were written separately, so agreement is evidence
rather than a restatement of the tests:

```
cargo build -p comp-io --example io_check
python verify/verify_formats.py    # Pillow writes and reads the files (12 checks)
python verify/verify_psd.py        # ImageMagick writes the PSDs, Pillow validates them (10 checks)
python verify/verify_svg_dpi.py    # ImageMagick rasterizes the SVG, Pillow tags the DPI (11 checks)
```

`examples/io_check.rs` is the bridge: it imports a file, exports PNG and JPEG, or reads a PSD, and
prints one `key=value` line per fact (dimensions, DPI, an FNV-1a checksum of the straight RGBA
bytes, the layer tree and the conversion report) that the scripts compare with their own numbers.

```
python tools/verify/verify_codecs.py --cli <compc>   # Pillow writes and reads the files
python tests/make_codec_fixtures.py                  # regenerates tests/fixtures
cargo test -p comp-io                                # includes tests/codec_reference.rs
```

`tests/codec_reference.rs` imports the Pillow-written files in `tests/fixtures` and compares every
pixel with Pillow's own decode of them, so a decoder and an encoder that are wrong in the same way
cannot hide behind a round trip: the 16-bit PNG must match exactly, and the JPEGs within a few
levels.

Last run on this machine: 12/12, 10/10 and 11/11. The SVG check is the interesting one: resvg's
rasterization of the probe drawing differs from ImageMagick's by a mean of 0.12 channel levels, with
99.7% of the filled pixels in the same place, which is antialiasing rather than geometry.

### HEIC and HEIF through the Windows Imaging Component

There is still no pure-Rust HEIF decoder, and macOS reads these files through ImageIO, a system
framework. The Windows equivalent is the system codec, so that is what `heic.rs` drives.

What the machine has (probed with WIC's component enumerator rather than guessed):

- `Microsoft.HEIFImageExtension` 1.2.48.0 and `Microsoft.HEVCVideoExtension` 2.5.33.0 are
  installed, which register "Microsoft HEIF Decoder" and "Microsoft HEIF Encoder" with container
  format `E1E62521-6787-405B-A339-500715B5763F` for .heic, .heif, .hif and .avci.
- On a machine without them, `CreateDecoderFromStream` fails with `WINCODEC_ERR_COMPONENTNOTFOUND`
  and the import answers with the command that fixes it:
  `winget install --source msstore 9PMMSR1CGPWG` (HEIF Image Extension).

Dependencies and distribution: `windows` 0.62 with only the Imaging, COM and Variant features, and
only for `cfg(windows)`. Nothing is bundled or redistributed; the decoder belongs to Windows. AVIF
shares the container but codes with AV1, so its brand is deliberately not accepted here; the same
system decoder could read it with one more brand check if that is wanted.

What works, measured against libheif 1.23.4 (the decoder inside pillow-heif) on files it wrote:

| Fixture | Content | Worst difference |
|---|---|---|
| heic-gray | grayscale, 24x18 | 0 levels (bit exact) |
| heic-soft | gentle color, 24x18 | 4 levels |
| heic-odd | gentle color, 23x17 | 10 levels |

The grayscale case is the strong one: with no chroma, no color matrix and no chroma upsampling can
differ, so it checks the geometry, the stride, the pixel order and the alpha against a separate
implementation exactly. The color cases are within a few levels because two HEVC decoders upsample
chroma differently; the odd width leaves the chroma plane's edge in the middle of a pixel pair,
which is where the ten levels come from.

A finding worth keeping: libheif's encoder defaults write a video usability matrix of BT.709 while
the container declares BT.601, and the Windows codec follows the bitstream. On the saturated color
patches of the probe image the two decoders then differ by up to 39 levels, and by 12 on a soft
gradient, while grays stay exact. Real cameras write both the same way; the fixtures therefore set
`matrix_coefficients` explicitly, and this is why the test files are not written with library
defaults.

Known gaps, all pinned by tests so a change is noticed:

- **Auxiliary alpha images are not applied, and that is a decision.** A HEIC whose transparency
  lives in an auxiliary item decodes opaque: the system decoder reports `24bppBGR` for it and
  never exposes the item, so no request through WIC can reach it. The two ways out, with costs:
  (a) build libheif with CMake, which the toolchain here can do, and ship it as an optional runtime
  dependency. libheif is LGPL-3.0: it has to stay a separate, replaceable DLL, the distribution has
  to carry its license text and a written offer of the corresponding source, and the crate grows a
  C build step with libde265 and an AV1 encoder beside it. That buys auxiliary alpha, bit-exact
  colour and one decoder instead of two. (b) keep the system codec: nothing to redistribute and no
  build step, at the price of dropping transparency in the rare HEIC that has it. (b) is what this
  pass chose. Either way `has_auxiliary_alpha(bytes)` reads the container's item references and
  says whether the file carried transparency, so a caller can tell the user it was dropped; turning
  that into a visible note needs a field on `ImportedRaster`, which is a decision for its callers.
- **Pictures under eight pixels a side are refused** by the system decoder with `E_INVALIDARG`
  during the pixel copy. The import reports it as a read error.
- **AVIF is read through the same decoder.** The brand check accepts avif and avis and the import is
  the HEIC path from there. Against libheif: a grayscale AVIF is bit exact, a colour one differs by
  nine levels, because two AV1 decoders upsample chroma differently. The codec comes from the same
  HEIF Image Extension; the machine also has Microsoft.AV1VideoExtension 2.0.35.0 installed, which
  is what Windows uses for AV1 video.
- **The resolution comes from the Exif item**, because the Windows metadata reader answers
  `WINCODEC_ERR_PROPERTYNOTFOUND` for every EXIF path on these files. isobmff.rs walks the
  container instead: ftyp, meta, the item table (iinf), the location table (iloc), then the Exif
  item's TIFF block through the same reader the TIFF importer uses. A real file declaring 300 dpi
  imports at 300, and one without the item keeps 72. The item table reader accepts both item-id
  widths, because libheif writes a 32-bit id under a version that says 16.
- **EXIF orientation covers all eight tags.** Transpose and transverse are a quarter turn with a
  flip, and the order WIC applies the two parts in is undocumented, so the table was derived by
  comparing every combination with the reference implementation in the image crate: a test pins all
  eight tags, and eight AVIF fixtures are checked against Pillow's own transpose. For AVIF the
  system decoder applies the container's rotation properties itself, so those files arrive turned
  and the EXIF path never runs; for HEIC it is the EXIF tag that matters.

## Open work

- **HEIC alpha is still missing** (see above, with both options and their costs); everything else
  in HEIC and AVIF import works through the system codec. Bundling libheif remains the option if
  alpha or bit-exact colour is needed, at the cost of redistributing a decoder and its dependencies.
- **XMP-only WebP resolution is not read.** WebP carries a DPI either in an EXIF chunk, which is
  read here, or in an XMP packet's `tiff:XResolution`, which is not. Most writers use EXIF.
- **SVG animation and scripting are ignored**, as any still rasterization must; an SVG whose whole
  picture is inside a `<script>` renders empty.
- Photoshop's `hue2` (Hue/Saturation), `expA`, `grdm`, `brit` and the other adjustment blocks are
  reported and skipped rather than mapped; only Levels and Curves have a typed record to land in.
- Text layers keep their pixels; nothing parses `TySh` into an editable `TextStyle`.
- PSD writing is out of scope: this crate reads Photoshop files only.
- Layer effects (`lfx2`, `lrFX`, `lmfx`) are discarded with a note rather than rendered.
