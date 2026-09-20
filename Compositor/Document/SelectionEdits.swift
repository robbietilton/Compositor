import AppKit

/// Carries a CGImage out of a detached task.
nonisolated private struct Box: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Selected pixels being dragged: the lifted raster plus the outline it started from.
final class PixelMove {
    let raster: BrushStroke
    let origin: DocumentSelection
    let duplicate: Bool
    var offset = CGSize.zero
    var movedSelection: DocumentSelection {
        var shift = CGAffineTransform(translationX: offset.width, y: offset.height)
        guard let path = origin.path.copy(using: &shift) else { return origin }
        return DocumentSelection(path: path, antialiased: origin.antialiased)
    }
    init(raster: BrushStroke, origin: DocumentSelection, duplicate: Bool = false) {
        self.raster = raster
        self.origin = origin
        self.duplicate = duplicate
    }
}

extension EditorSession {
    nonisolated enum FillSource: Sendable { case foreground, background }

    /// Whether the active layer (or its mask) can take a fill or clear right now.
    var canEditPixels: Bool { canPaint }

    /// Fills the selection with the foreground or background color, as one undo step.
    /// With no selection it fills the whole layer; an empty selection fills nothing.
    /// On a mask the palette is black/white, so this reveals or hides.
    func fillSelection(with source: FillSource) async {
        guard canEditPixels, let layer = activeLayer else { return }
        let value = paletteColor(background: source == .background)
        let color = isMaskSelected
            ? CGColor(gray: value.red, alpha: 1)
            : CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [value.red, value.green, value.blue, 1])!
        await applyPixelEdit(to: layer, name: isMaskSelected ? L10n.string("Fill Mask") : L10n.string("Fill")) { try $0.fill(color) }
    }

    /// Delete with a selection: image pixels become transparent; on a mask the
    /// selection fills with the background color, as in Photoshop.
    func clearSelectedPixels() async {
        guard selection != nil, canEditPixels, let layer = activeLayer else { return }
        if isMaskSelected { await fillSelection(with: .background); return }
        guard layer.asset != nil else { return }
        await applyPixelEdit(to: layer, name: L10n.string("Clear")) { try $0.clearPixels() }
    }

    /// The Delete key: clears the selection when there is one; otherwise deletes the
    /// targeted mask, or the layer when its pixels are targeted.
    func deleteKeyPressed() {
        if selection != nil { Task { await clearSelectedPixels() } }
        else { deleteLayerOrMask() }
    }

    /// The trash button and Delete without a selection: with one layer's mask thumbnail targeted
    /// only the mask goes; otherwise every selected layer does, in one undo step.
    func deleteLayerOrMask() {
        if isMaskSelected, activeLayer?.mask != nil, selectedLayerIDs.count <= 1 { deleteLayerMask() }
        else { deleteSelectedLayers() }
    }

    /// Cmd-I: inverts the layer's colors (transparency kept) or its mask, inside the
    /// selection or across the whole layer without one. Runs off the main thread in one
    /// vectorized pass; one undo step.
    /// Invert is available in every tool: a pending gradient or transform is applied
    /// first, and the Crop tool's rectangle doesn't block it.
    var canInvert: Bool {
        _ = showsBusy
        guard document != nil, let layer = activeLayer, !isProjectBusy, !isImporting, brushStroke == nil, pixelMove == nil,
              renamingLayerID == nil, !showsNewDocument, !showsImporter, selectedLayerIDs.count == 1, !layer.isGroup || isMaskSelected,
              document?.effectiveVisibleIDs.contains(layer.id) == true, selection?.isEmpty != true else { return false }
        return isMaskSelected ? layer.mask?.isEnabled == true : layer.asset != nil
    }

    func invertPixels() async {
        guard canInvert else { return }
        commitTransform()
        if gradientEdit != nil { await commitGradient() }
        guard canInvert, let document, let layer = activeLayer,
              let index = document.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        let mask = isMaskSelected
        guard var image = mask ? layer.mask?.asset.image : layer.asset?.image else { return }
        finishOpacityEdit()
        isProjectBusy = true
        defer { isProjectBusy = false }
        do {
            let clip = try selection?.clip(canvas: document.size)
            // A uniform 1×1 mask can't hold a partial selection; give it the layer's pixel grid first.
            if mask, clip != nil, image.width == 1, image.height == 1 {
                image = try Self.expandedUniformMask(image, width: layer.asset?.image.width ?? Int(layer.size.width.rounded()),
                                                     height: layer.asset?.image.height ?? Int(layer.size.height.rounded()))
            }
            let job = PixelInvert.Job(image: image, isMask: mask,
                pixelToDocument: BrushRaster.pixelToDocument(mask ? layer.maskTransform : layer.transform, width: image.width, height: image.height), selection: clip)
            let result = try await Task.detached(priority: .userInitiated) { Box(try PixelInvert.run(job)) }.value.image
            let asset = mask ? try LayerMask.asset(from: result)
                             : ImportedImage(image: result, thumbnail: try PixelInvert.thumbnail(of: result), name: layer.name)
            // Only write over the layer the invert was computed from.
            guard let current = self.document?.layers[safe: index], current.id == layer.id,
                  current.asset?.image === layer.asset?.image, current.mask?.asset.image === layer.mask?.asset.image else { return }
            beginEdit(mask ? L10n.string("Invert Mask") : L10n.string("Invert"))
            if mask {
                self.document?.layers[index].mask = current.mask.map { $0.replacing(asset) } ?? LayerMask(asset: asset)
            } else {
                self.document?.layers[index] = ImageLayer(id: current.id, asset: asset, name: current.name,
                    isVisible: current.isVisible, transform: current.transform, parentID: current.parentID, isGroup: false,
                    opacity: current.opacity, blendMode: current.blendMode, mask: current.mask, maskSourceID: current.maskSourceID)
            }
            endEdit()
            brushRevision += 1
        } catch { brushError = error.localizedDescription }
    }

    private static func expandedUniformMask(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0, width * height <= 100_000_000 else { throw ProjectError.tooLarge }
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: true, context: context)
        guard let expanded = context.makeImage() else { throw ExportError.render }
        return expanded
    }

    // MARK: Moving selected pixels (Cmd-drag / Cmd-arrow)

    /// Starts moving the selected image pixels; false when there is nothing to move
    /// (no selection, a mask target, or no pixels under the selection).
    func beginPixelMove(duplicate: Bool = false) -> Bool {
        guard pixelMove == nil, let selection, !selection.isEmpty, canPaint, !isMaskSelected,
              let layer = activeLayer, layer.asset != nil else { return false }
        do {
            let raster = try makeRasterEdit(for: layer)
            guard try raster.liftSelection() else { return false }
            finishOpacityEdit()
            pixelMove = PixelMove(raster: raster, origin: selection, duplicate: duplicate)
            return true
        } catch { brushError = error.localizedDescription; return false }
    }

    /// Previews the pixels `offset` document pixels (whole pixels) away. The stored
    /// selection stays put until commit; the outline is drawn from `displayedSelection`.
    func movePixels(by offset: CGSize) {
        guard let move = pixelMove else { return }
        let rounded = CGSize(width: offset.width.rounded(), height: offset.height.rounded())
        do { try move.raster.moveLifted(by: rounded, duplicate: move.duplicate) } catch { cancelPixelMove(); brushError = error.localizedDescription; return }
        move.offset = rounded
        brushRevision += 1
    }

    /// The outline to draw: during a pixel move, the original shifted by the drag.
    var displayedSelection: DocumentSelection? {
        if let moved = pixelMove?.movedSelection { return moved }
        // While transforming selected pixels the outline follows the handles.
        if let edit = transformEdit, var matrix = floatingSelectionTransform(edit), let selection,
           let path = selection.path.copy(using: &matrix) {
            return DocumentSelection(path: path, antialiased: selection.antialiased)
        }
        return selection
    }

    /// Commits the pixels and the moved outline together as one "Move Pixels" undo step.
    /// The outline keeps showing at its new place throughout, so nothing jumps back.
    func finishPixelMove() async {
        guard let move = pixelMove, !isProjectBusy else { return }
        if move.offset != .zero {
            let moved = move.movedSelection
            do { try await commitRasterEdit(move.raster, name: move.duplicate ? L10n.string("Duplicate Pixels") : L10n.string("Move Pixels")) { self.document?.selection = moved } }
            catch { brushError = error.localizedDescription }
        }
        pixelMove = nil
        brushRevision += 1
    }

    func cancelPixelMove() {
        guard pixelMove != nil else { return }
        pixelMove = nil
        brushRevision += 1
    }

    /// Cmd-arrow: moves the selected pixels 1 px (10 px with Shift) as one undo step.
    func nudgePixels(dx: CGFloat, dy: CGFloat) async {
        guard beginPixelMove() else { NSSound.beep(); return }
        movePixels(by: CGSize(width: dx, height: dy))
        await finishPixelMove()
    }

    private func applyPixelEdit(to layer: ImageLayer, name: String, _ paint: (BrushStroke) throws -> Void) async {
        finishOpacityEdit()
        do {
            let edit = try makeRasterEdit(for: layer)
            try paint(edit)
            guard !edit.patches.isEmpty else { return }
            try await commitRasterEdit(edit, name: name)
            brushRevision += 1
        } catch { brushError = error.localizedDescription }
    }
}
