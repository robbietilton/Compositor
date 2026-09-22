# Darkroom

Darkroom is a finishing workspace for architectural renders: photographic tone, color and lens character in one live-preview stack, applied as a new layer. (In the code it is called Render Finish: `RenderFinish*` types and `FinishPixels.c`.)

Open an image, select its image layer, then choose **Filter → Darkroom…**. To finish the whole composition instead, choose **Filter → Darkroom on Merged Visible…**, or switch the Layer / Merged Visible control at the top of the workspace at any time; the settings and view are kept.
Darkroom expands the editor to the current screen's available area and restores its previous window frame on exit. Its dark workspace places the filter library on the left, a large preview in the center, and the selected filter's settings on the right, with warm gold accents. It also works inside an existing macOS full-screen window.

Enable effects with the checkboxes and click an effect name to edit its settings. The canvas previews the complete enabled stack. The toolbar above the canvas provides Single, Split and Side by Side comparison. Hold Original temporarily shows the input without discarding settings; press `\` to switch between before and after (reassignable under Keyboard Shortcuts). Split starts with a movable divider at 50%: original on the left, filtered image on the right. Drag the line on the canvas or use the accessible divider slider in the settings sidebar. Single shows the full image; Side by Side shows two complete views with synchronized zoom and pan. Fit shows the entire image in each pane; Fill covers each pane, 1:1 uses physical display pixels, and the ratio menu includes 1:3. Drag the image to pan; use the plus/minus controls, pinch or Option-scroll to zoom. The divider is display-only and never appears in committed pixels or exports. Preview switches between the original and the result; Cancel discards the preview.

**Apply creates and selects a new image layer** immediately above the source, named after the active effect, or Darkroom when several effects are enabled. The source pixels stay intact on the original layer, which is hidden to avoid doubling transparent edges, masks, opacity and shadows. The result retains the source's transform, group, opacity, blend mode, mask and layer effects; dependent clipping links follow the result. Existing selections limit the processing. The complete operation is one undo step, including original visibility and clipping links. Stacks that change nothing (effects disabled, zero strength, or Tonal Contrast and Warmth with all their controls at zero) create no layer. This produces rendered image pixels, not an editable adjustment layer. Undo and Redo wait until Darkroom is applied or cancelled, so the source cannot change under it; if the document does change, Apply reports it instead of silently doing nothing.

**Merged Visible** processes the canvas as shown (every visible layer, with masks, blend modes and adjustments) and adds the result as a new layer on top of the stack, trimmed to the pixels it holds. The original top-level layers and folders are hidden underneath rather than changed, since the result already contains them; showing them again brings the original composition back.

While Darkroom is open it is modal: Escape cancels, Return applies, Space pans, and the editor's tool shortcuts are ignored so they cannot change the source.

**Presets** (above the filter library) apply a complete look: six built-in starting points for renders (Natural Interior, Crisp Exterior, Evening Glow, Soft Daylight, Photographic, Carbon Monochrome) and your own. Save Current Settings as Preset stores every filter's settings, including which are enabled; saving under an existing name replaces it. Saved presets are available in every document.

## Controls

- **Tonal Contrast:** signed Shadows, Midtones and Highlights controls (−100 to 100), Saturation, Contrast Type (Standard, High Pass, Fine, Balanced, Strong), Protect Shadows and Protect Highlights. Strength mixes the effect with its input; Radius additionally sets the texture scale in original layer pixels. Negative contrast smooths detail. Protection lifts dark tones or pulls bright tones back; it cannot recover already clipped image information.
- **Ink:** six original duotone palettes and strength: Carbon, Sepia, Cyanotype, Warm Violet, Teal and Copper.
- **Pro Contrast:** restrained luminance S-curve, with strength.
- **Detail Extractor:** local detail enhancement and mild local tone compression, radius and saturation.
- **Bloom / Glow:** soft screen-blended bloom from bright regions, radius and strength.
- **Brilliance / Warmth:** warm/cool balance, saturation and strength.
- **Vignette:** soft elliptical edge darkening, with strength.

**Photo Realism** — camera and lens character that makes a render read as a photograph:

- **Sensor Grain:** fine, film-like grain, strongest in the midtones, with Grain size. The pattern is fixed for an open edit, so the preview, the zoomed-in detail and the applied result agree; at preview size its strength is reduced as a downscaled photo's grain would be.
- **Micro Texture:** boosts only the finest scale (Texture scale 1–6 px) with a small threshold, so fabric weave and rug fibres gain definition while flat areas and noise stay put. It can only strengthen detail the render has; see Enlarger for detail that isn't there.
- **Highlight Rolloff:** a shoulder above the upper midtones eases bright areas into white and lets them lose color as they near it, as a sensor does, with a warm Halation (and its radius) around windows and lamps.
- **Chromatic Aberration:** red and blue shifted apart radially, growing toward the corners (Fringe at the corners, in pixels); Strength scales the shift.
- **Lens Softness:** the image softened gradually toward the corners (Softness radius), the center kept sharp.

Processing order is Tonal Contrast → Detail Extractor → Micro Texture → Pro Contrast → Ink → Warmth → Highlight Rolloff → Bloom → Lens Softness → Chromatic Aberration → Vignette → Sensor Grain. Start gently: aggressive detail settings can emphasize noise or produce halos along high-contrast edges. The live preview is limited to 2048 pixels on its longest edge. When you zoom in further than that preview can show, the part on screen is rendered again at full resolution shortly after the view and sliders settle (up to 16 megapixels including blur margins, about a 4K display), so fine texture can be judged before applying. Layers with layer effects keep showing the preview resolution, as they do elsewhere on the canvas.

## Enlarger

Enlarger enlarges the canvas 2× or 4× with AI. (In the code: `AIUpscale*` and `ESRGAN*`.) It is available as Darkroom's last step — **Output → Enlarger** in the filter library, which runs after Apply with its own progress and undo step — and on its own as **Image → Enlarger…**.

Every visible image layer is first rebuilt by [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) x4plus (Xintao Wang et al., BSD 3-Clause), which adds convincing fine detail instead of only interpolating; the Image Size resampler then places the layers on the larger canvas. Hidden layers (such as a Darkroom source kept under its result), text, shape and adjustment layers and masks are resampled as Image Size does, layer effects are scaled to match, and the whole operation is one undo step. The canvas limits (100 megapixels, 30,000 pixels per side) apply to the result and to every rebuilt layer together.

The model is not bundled. The first time, **Download Model** fetches `RealESRGAN_x4plus.pth` (67 MB) from the authors' official GitHub release; the file is checked against its known size and SHA-256 before use and kept in the app's Application Support folder (**Remove** deletes it). The app reads the PyTorch checkpoint itself (an uncompressed zip with a pickled state dict; nothing in it is executed) and runs the network with Metal Performance Shaders Graph on the GPU, in half precision, in 256-pixel tiles with a 16-pixel overlap. 2× is the 4× result averaged down, as Real-ESRGAN's own smaller scales are. Nothing is uploaded. The GPU work dominates: about 1.1 s per 256-pixel tile on an 8-core Apple silicon Mac (the network is compute-bound; data layout and graph optimization level made no measurable difference), so a 1536 × 1024 render enlarges in about a minute. Tile packing, the opacity check and premultiplication are in C (`ESRGANPixels.c`), so unoptimized builds keep pace; they produce byte-identical results to the reference Swift loops they replaced. The checkpoint loads in about 0.2 s. Stop ends the run between tiles without changing the document.

A diffusion-based creative upscaler (Stable Diffusion with a tile ControlNet) would invent more detail but needs multi-gigabyte models and is planned as a separate step.

## Implementation and limits

These are independent algorithms inspired by photographic workflows, not reproductions of Nik's proprietary algorithms. Contrast types use different spatial scales and gain curves; Ink palettes are original. Pro Contrast currently provides an S-curve, not Nik's automatic color-cast correction or dynamic contrast. Nik U Point control points are not implemented; Compositor's existing selections provide local application.

The C processor uses premultiplied RGBA8, preserves alpha, and normalizes neighbourhood luminance by blurred alpha to avoid dark fringes around transparent layers. Sliding-window blur has linear pixel-count cost. Rows are processed in parallel, and the vertical pass reads strips of columns row by row instead of striding through memory. Spatial filters use two float planes (8 bytes per pixel) for opaque images, the usual case for renders, and three for images with transparency; the whole stack shares them. Spatial radii scale with the existing preview scale. Like the existing pixel filters, this is an 8-bit workflow, not HDR/EXR processing.

The live preview keeps each effect's output, so changing a later effect (Vignette, say) starts from the effect before it instead of redoing the stack; the results are identical. The zoomed-in preview processes a crop with a margin of three box radii per spatial effect, and places Vignette on the whole layer, so it matches the full render within one 8-bit level.

On an 8000 × 5333 opaque render on an 8-core Apple silicon Mac, Tonal Contrast, Detail Extractor, Bloom and Vignette together take about 1 s (previously about 9.6 s single-threaded); at the 2048-pixel preview size they take about 70 ms, and changing only Vignette about 8 ms. The per-pixel loop now dominates; faster arithmetic variants were measured and gave no gain.

Source reference for Nik controls: [DxO Color Efex guide](https://userguides.dxo.com/nikcollection/en/color-efex/). Archviz context: [Chaos lens effects guide](https://www.chaos.com/blog/the-light-touch-your-complete-guide-to-v-ray-lens-effects) and [Chaos color corrections](https://docs.chaos.com/display/ARENA/Color%2BCorrections%2BTab). The five additional effects are a practical selection for renders, not a measured popularity ranking.

## Validation

Run `sh scripts/test-render-finish.sh` for C tests under AddressSanitizer and UndefinedBehaviorSanitizer, and `python3 scripts/test-swift.py` for the Swift Testing suites without Xcode (set `COMPOSITOR_AI_MODEL_PATH` to the official checkpoint to include the GPU cases). The C tests cover all twelve effects, zero strength, alpha and row padding, separate tonal bands, negative contrast, distinct contrast modes, protection, transparent boundaries, tiny images and crops processed as regions. A standalone Swift check verifies Fit/Fill geometry, equal comparison panes, synchronized zoom anchors and Retina 1:1. `RenderFinishTests`, `RenderComparisonTests` and `AIUpscaleTests` cover settings normalization, neutral stacks, editor cancel/commit/undo (and Undo waiting for the edit), preset coding including older presets, Merged Visible, and the preview's stage cache matching a full render.

All of these pass on Compositor 1.2.2 with the macOS 26.5 SDK. The parallel processor was compared with the previous single-threaded one on 40 random images with and without transparency and row padding, and produced identical bytes; the preview's stage cache and the zoomed-in crops match full renders. Enlarger was checked against the official checkpoint: tiles, 2× and 4×, transparency, cancellation, undo, scaled layer effects and the Darkroom Output step. The rest of the project's suite passes as well, except eleven guide, crop, cursor, transform and slider tests that fail identically on an unmodified checkout in the same Command Line Tools environment. Build and run the Xcode test target with Xcode 26.5 or newer as a final check.
