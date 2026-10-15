# GIF workflow

Import a `.gif` through the image picker or drag and drop. It remains one image layer with an editable frame timeline below the canvas.

## Timeline and editing

Click a thumbnail to display its frame. Short strips stay centered; scroll, drag empty space, or use the scrollbar to reach hidden frames. Play loops through saved delays. Click the layer name beside Play to switch to **All**, which starts visible GIFs together and holds shorter timelines on their final frame. Preview speed (0.25×–4×) does not change saved or exported timing. Single-frame GIFs have playback disabled.

Painting, selections, filters, and color commands affect the displayed frame. Other frames retain their pixels. Layer placement, opacity, effects, clipping, and the shared layer mask apply across the animation. Edits use undo/redo; frame navigation does not add history entries. GIF pixels stay 8-bit alongside the document's 16-bit/HDR still layers.

Right-click a thumbnail to duplicate or delete it; drag thumbnails to reorder. Pixels, masks, and delays follow the frame, and at least one frame must remain. Command-click toggles selection. Hold Command and drag with the mouse or macOS three-finger dragging to select every thumbnail crossed; the strip scrolls at its edges. Only selection borders appear, with no rectangle or pointer trail. The displayed frame stays visible during batch selection. Right-click a selected frame for batch mask or deletion commands; a plain click returns to one frame.

The timeline mask button creates a frame mask from the canvas selection, or a white mask without a selection. Click it again to switch between mask and pixels. The eye enables or disables that mask in both canvas and export. Enabled frame and shared masks multiply. **Add Masks** preserves existing masks. **Copy Mask to Frames…** replaces chosen destination masks with independent copies, including the source mask's enabled state, placement, and linking. Batch operations form one undo step.

The onion-skin icon shows the previous or next frame over the current frame while paused. Its settings adjust direction and opacity; it does not wrap at the ends. The ghost follows edits, enabled masks, and layer appearance without changing edit targeting, saved pixels, or exports.

## Timing and export

Use **Frame delay › Edit…** for individual delays or **Same for all** for one delay. Return, leaving a field, or closing the editor confirms pending values; invalid input restores the previous value. Timeline timing is saved with the layer. Imported missing or zero delays use 100 ms; positive delays below 20 ms use 20 ms. Playback follows elapsed time and may skip expired display intervals if decoding falls behind. Resuming gives the displayed frame its full delay.

Choose **File › Export As… › GIF**. **All** animates visible GIFs together through the longest timeline, holding shorter ones on their final frame. Choosing one timeline advances only that GIF; other layers keep their captured frames. Set output size, export speed, **Once** or **Forever** looping, and transparency, then inspect the encoded preview before saving. Individual timelines also offer temporary delay overrides. Export settings leave document pixels, timing, selection, and history unchanged.

GIF supports up to 256 colors per frame and fully transparent or opaque pixels. With transparency enabled, coverage below 50% becomes transparent and the rest opaque. Turn it off to blend soft edges onto a background color. Delays use 10 ms ticks with a 20 ms minimum; closely spaced changes in **All** are combined to meet that minimum. Timing fields accept 20–655,350 ms, and export rejects delays that exceed the maximum after speed adjustment.

PNG/JPEG and other still exports use the displayed frames. Every export applies only enabled masks, matching the canvas.

## Saving and limits

Saving a `.comp` embeds the original GIF, edited pixels, masks, frame order, and delays, so it works after moving or deleting the imported file. Reopening restores the displayed frame with playback paused. Crop and Canvas Size preserve source pixels; Image Size resamples every frame and mask.

Each source is limited to 4,096 frames and 512 MiB. Layers, including duplicates, share thumbnail and encoded-source budgets; selected and edited pixels count toward the document raster budget, and masks share its mask budget. Full-size source frames decode on demand, and undo accounting includes retained animation assets. Export allows up to 4,096 frames, 200 megapixels across all output frames, and 512 MiB of encoded data. Reduce size or frame count if these limits are exceeded.

New saves use provisional project format 28. See [project format](project-format.md#gif-layers-version-28) for fields, validation, and compatibility. Gradual changes and APNG/animated WebP support are planned as separate features.
