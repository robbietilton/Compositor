# Compositor

Adobe Photoshop costs too much and tools like GIMP don’t feel familiar enough for me to stay in flow. That’s why I built Compositor.

The goal was to create a full-featured image editor that is completely free and open source. I use Photoshop for compositing and post-processing, so Compositor is built around that workflow - with the tools needed to create a pixel-perfect final image.

Because it’s open source, you can download the Xcode project and add, remove, or modify any feature to fit your workflow.

## Features

### Layers
- Layers and folders, with blend modes and opacity — a folder's opacity dims everything inside it
- Layer masks: paint, fill, invert, blur and feather them; link or unlink them to transform a mask on its own
- Clipping masks and folder masks
- Adjustment layers: Hue/Saturation, Levels, Curves, Exposure, Gradient Map and Grain
- Layer effects: Stroke, Drop Shadow, Color Overlay, Inner Shadow and Outer Glow, rendered on the GPU and editable at any time
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
- Rectangle and Ellipse Marquee, Freehand and Polygonal Lasso, and the Magic tool — Wand selects by color, Object traces whatever you click (Tab switches)
- Select Subject, and Expand, Contract and Feather on any selection
- Add to and subtract from selections, move the outline, or move and duplicate the pixels inside
- Load a layer's pixels or a mask as a selection
- Content-Aware Fill, which can also extend an image past its edges

### Painting and retouching
- Brush with size, hardness, opacity and smoothing, in Paint or Erase mode (B and E), and Shift for straight lines
- Spot Healing Brush (content-aware)
- Clone Stamp, aligned or not, sampling one layer or all of them
- Blur tool, on pixels or masks
- Gradient tool and Shape tool (rectangles, rounded rectangles, ellipses and lines), which stay editable rather than being rasterized
- Type tool (T): inline multiline editing in draggable, resizable paragraph boxes; font, size, color, alignment and spacing in the tool header; transform text and use it as a clipping mask
- Eyedropper and a full color picker

### Adjustments and filters
- Levels (with Auto), Curves, Hue/Saturation, Exposure, Gradient Map, Grain and Invert
- Gaussian Blur and Motion Blur that spread past a layer's edges
- Add Noise, Lens Correction and Remove Background
- Live previews, limited to the selection when there is one

### Generative AI (optional, with your own API key)
- Generative Fill: select an area, describe the change, and get it as a new masked layer. Nothing outside the selection changes, and the rest of the document keeps its full resolution
- Generative Remove, and Generative Expand from a crop frame dragged past the canvas
- Reference images, up to three results at a time, and a choice of model and size
- Uses Google's Gemini image models with a key of your own — see [Generative AI](#generative-ai) below

### Canvas and files
- Multiple projects in tabs
- Rulers (⌘R), guides dragged from them, a layout grid, and Snap To for guides, grid, layers and document bounds
- Crop with snapping, and Option for symmetric cropping
- Canvas Size and Image Size
- Sharp high-quality downsampling when zoomed out, and a pixel grid when zoomed in
- Import JPEG, PNG, HEIC, TIFF and Photoshop PSD (8-bit RGB only; not PSB or CMYK). PSD folders, masks, a subset of blend modes, and fill rectangles/ellipses stay editable; text and other vectors become pixels. A conversion report is shown before anything is applied.
- Export JPEG with a live preview (⇧⌥⌘S); Copy Merged
- Photoshop-style keyboard shortcuts throughout, remappable in Edit > Keyboard Shortcuts
- Automatic updates, signed and notarized

## Generative AI

Generative Fill, Generative Remove and Generative Expand are optional. They use Google's Gemini image models ("Nano Banana") with an API key of your own; Compositor ships without a key and works fully without one.

Everything else in Compositor runs on your Mac. These features are the exception: when you press Generate, the part of your image you selected, some of its surroundings, your prompt and any reference images are sent to Google, and each result is charged to your own Google account. Nothing is sent before that, and the first time you generate the app tells you so and waits for you to continue.

### Setting it up

1. Create a key at [aistudio.google.com/apikey](https://aistudio.google.com/apikey). The image models have no free tier, so the key's Google project needs billing enabled.
2. In Compositor choose **Compositor › Settings…** (⌘,), paste the key and press **Save**. It is stored in your Mac's keychain, never in a preferences file or a project.
3. **Verify Key** checks that the key is accepted and can reach the image models. It only lists models; it generates nothing and costs nothing.

### Using it

- **Generative Fill** — make a selection, choose **Edit › Generative Fill…**, describe the change and press **Generate**. Leave the prompt empty to remove what is selected instead.
- **Generative Remove** — make a selection and choose **Edit › Generative Remove**. It starts at once, with no prompt.
- **Generative Expand** — with the Crop tool, drag the frame past the edge of the canvas, then press **Generative Expand…** in the tool's header. Keeping a result enlarges the canvas to the frame and fills the new area.

The panel also offers:

- **Add Reference…** — up to three pictures of the object, material or style to use
- **Results** — one to three at a time. Each is a separate request, charged separately
- **Model** — Nano Banana 2 (the default), Nano Banana 2 Lite (fastest and cheapest, 1K only) or Nano Banana Pro (slowest and most capable)
- **Size** — Automatic, or 1K, 2K or 4K. Next to it the panel shows how much of the document's detail the result will have

A result shows on the canvas straight away, in place, but is not part of the document yet. Click a thumbnail to compare results, **Generate More** to add to them, **Keep** (Return) to add the chosen one, or **Cancel** (Esc) to discard them all. Keeping a result is one undo step. While the panel is open the document cannot be edited, so that what was generated still fits the picture it was generated for; hold Space to pan, and zoom as usual.

What you keep is an ordinary layer with an ordinary layer mask, placed above the active layer: fade it, change its blend mode, or paint on its mask to show more or less of it. It is saved in the project like any other layer.

### How it works

The Gemini image models take no mask: they repaint the whole picture they are sent. So Compositor does the masking itself.

1. It takes the selection with some of its surroundings — about half the selection's size on each side — so the model can match the light, grain and perspective, and shapes that crop to an aspect ratio the model accepts.
2. It renders that crop as the picture looks from where the new layer will sit. Layers above that place, such as an adjustment layer grading the whole document, are left out: they will draw over the new layer too, and would otherwise be applied twice.
3. It sends the crop, never larger than the chosen size, with your prompt, a black-and-white picture showing where the change is wanted, and any references.
4. It scales the answer back to the document and keeps only the selection, through a layer mask made from the selection. A hard-edged selection is grown slightly and softened so the seam does not show; a feathered selection is used as you made it.

That is why nothing outside the selection can change, whatever the model does, and why the rest of the document keeps its full resolution. It also explains the main limit: the models produce at most about 4,000 pixels along the longer side, so a large area comes back smaller than the document and is enlarged to fit, which looks softer. A small selection has the opposite advantage — it gets the model's whole resolution to itself.

### Writing prompts

- Describe the change to what is there, not only the result. "Give this man clown makeup: white face paint, a red nose and a rainbow wig. Keep his head position and the lighting" works; "clown face" tends to produce an unrelated clown.
- Say what to keep — pose, hair, clothing, the angle — whenever you are changing something rather than replacing it.
- For something new, say how it sits in the scene: "a glowing blue lightsaber held in his raised hand, lighting his sleeve".
- Select the thing itself, with the Magic tool's Object mode or a lasso, rather than a box around it. The mask then follows its outline, and a rectangle can read to the model as a frame to put a picture in.
- Include everything that has to change: for a wig, select the hair as well as the face.
- Try wordings with Nano Banana 2 and two or three results; switch to Pro when an instruction keeps being misread.

### Cost, limits and privacy

- Google charges per generated image, by model and size — at the time of writing from a few cents to about a quarter of a dollar. See [Google's pricing](https://ai.google.dev/gemini-api/docs/pricing). A result you discard is still charged, and so is every retry: the models offer no seed to repeat a result.
- A request usually takes between a few seconds and a minute. **Stop** abandons it.
- The models decline some requests, most often ones that alter real people. The panel shows the reason they give.
- Generated images carry Google's invisible SynthID watermark, and what you send is handled under Google's terms for the Gemini API. Compositor uses the stateless `generateContent` API rather than the newer Interactions API, which keeps requests on Google's side by default.
- Everything is 8-bit sRGB, as the rest of Compositor is.

### In the code

The feature lives in `Compositor/Generative`, with its session state in `Compositor/Document/GenerativeEdit.swift` and its panels in `Compositor/UI`. `GenerativeImageProvider` is the one protocol a service has to implement, so a service that does take a mask (FLUX Fill, for example) can be added beside Gemini without the editor changing. The prompts sent to the model are all in `GenerativePrompt.swift`, and the model identifiers, which Google retires on its own schedule, in `GenerativeModel`. The tests use a stand-in provider and an in-memory key store: they never touch the network or your keychain.

## Requirements

- macOS 26.5
- Xcode 26 or later (to build from source)

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
