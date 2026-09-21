# Compositor

Adobe Photoshop costs too much and tools like GIMP don’t feel familiar enough for me to stay in flow. That’s why I built Compositor.

The goal was to create a full-featured image editor that is completely free and open source. I use Photoshop for compositing and post-processing, so Compositor is built around that workflow - with the tools needed to create a pixel-perfect final image.

Because it’s open source, you can download the Xcode project and add, remove, or modify any feature to fit your workflow.

## Features

### Layers
- Layers and folders, with blend modes and opacity
- Layer masks: paint, fill, invert, blur and feather them; link or unlink them to transform a mask on its own
- Clipping masks and folder masks
- Adjustment layers: Hue/Saturation, Levels, Curves, Exposure, Gradient Map and Grain
- Merge Down, Merge Layers and Merge Group (⌘E)
- Duplicate, rename inline, reorder and nest by drag and drop; Option-drag to duplicate
- Drag layers between open projects

### Transform
- Non-destructive move, scale, rotate and flip — images keep their full resolution however small you make them
- Free distort (⌘-drag a handle), with Shift to lock to an axis
- Transform several layers, or a whole folder, together
- Snapping to canvas and layer edges and centers, with guides
- Exact values for position, size, scale and angle, stepped with the arrow keys
- Flip Layer and Flip Canvas, horizontal and vertical

### Selections
- Rectangle and Ellipse Marquee, Freehand and Polygonal Lasso, and Magic Wand
- Add to and subtract from selections, move the outline, or move and duplicate the pixels inside
- Load a layer's pixels or a mask as a selection
- Content-Aware Fill, which can also extend an image past its edges

### Painting and retouching
- Brush with size, hardness and opacity, and Shift for straight lines
- Spot Healing Brush (content-aware)
- Clone Stamp, aligned or not, sampling one layer or all of them
- Blur tool, on pixels or masks
- Gradient tool and Shape tool (rectangles, rounded rectangles and ellipses)
- Type tool (T): inline multiline editing in draggable, resizable paragraph boxes; font, size, color, alignment and spacing in the tool header; transform text and use it as a clipping mask
- Eyedropper and a full color picker

### Adjustments and filters
- Levels (with Auto), Curves, Hue/Saturation, Exposure, Gradient Map, Grain and Invert
- Gaussian Blur and Motion Blur that spread past a layer's edges
- Add Noise, Lens Correction and Remove Background
- Live previews, limited to the selection when there is one

### Canvas and files
- Multiple projects in tabs
- Crop with snapping, and Option for symmetric cropping
- Canvas Size and Image Size
- Sharp high-quality downsampling when zoomed out, and a pixel grid when zoomed in
- Import JPEG, PNG, HEIC, TIFF and layered PSD — including dropped screenshots and images from other apps
- Layered Photoshop PSD import: artboards become separate documents, with pixel layers, smart objects, text and solid-fill layers rasterized; folders, layer masks, opacities, blend modes and clipping preserved
- Export PNG (⇧⌘E), JPEG with a live preview (⇧⌥⌘S) and layered Photoshop PSD with folders, masks, blend modes and clipping (⇧⌥⌘E); Copy Merged
- Photoshop-style keyboard shortcuts throughout

## Requirements

- macOS 26
- Xcode 26 (to build from source)

## Photoshop PSD support

PSD files import with their layer structure intact (8-bit RGB, PSD — not PSB):

- **Artboards.** A file with artboards becomes one document per artboard, each named after it — the only mapping that fits files whose full canvas exceeds the 100-megapixel budget. Layers are positioned relative to their artboard and cropped to it; files without artboards import as a single document, with a clear error if the canvas itself is over budget.
- **Layers.** Pixel layers, smart objects, text layers and solid-color fills all carry rendered pixels in the file and rasterize as pixel layers. Adjustment layers (Hue/Saturation and friends) hold no pixels and are skipped — the import summary tells you what was dropped.
- **Structure.** Folders (including pass-through groups), layer masks, per-layer opacity, hidden state, Unicode names, and clipping stacks all carry over. Darker Color has no equivalent blend mode here and downgrades to Darken.
- **Export** writes a layered PSD back out: folders as groups, masks as mask channels, the nine blend modes under their Photoshop keys, clipping flags, and a full flattened composite, as Photoshop requires. Adjustment layers keep their place in the stack as empty records; their effect lives on in the composite.
- Files that store only a flattened composite (no layer records) still import the old way, as a single image.

## Building

Open `Compositor.xcodeproj` and run the **Compositor** scheme.

## Releasing

`scripts/release.sh` builds a Release version, signs it with Developer ID, notarizes and staples it, and packages it into `dist/Compositor-<version>.dmg`.

It needs, all kept outside this repository:

- a **Developer ID Application** certificate in the login keychain
- notarization credentials saved with `xcrun notarytool store-credentials "compositor-notary" …`
- [`create-dmg`](https://github.com/create-dmg/create-dmg) (`brew install create-dmg`)

## License

MIT — see [LICENSE](LICENSE).
