import AppKit

/// Cmd-T with a selection: the selected pixels float on a temporary layer, edited with the
/// normal transform handles, then merge back into their layer. The whole thing is one
/// "Transform Selection" undo step; Escape restores the document exactly.
struct FloatingTransform {
    let sourceID: UUID
    let before: CanvasDocument
    let beforeActive: UUID?
    let original: LayerTransform
    let pixelSize: CGSize
}

extension EditorSession {
    var canTransformSelection: Bool {
        guard transformEdit == nil, canEditPixels, !isMaskSelected, let selection, !selection.isEmpty,
              activeLayer?.asset != nil else { return false }
        return true
    }

    /// Cmd-T: transforms the selected pixels when there is a selection, else the layer.
    func transformCommand() {
        if canTransformSelection { Task { await beginSelectionTransform() } }
        else { beginTransform() }
    }

    func beginSelectionTransform() async {
        guard canTransformSelection, let document, let source = activeLayer else { NSSound.beep(); return }
        let lifted: (image: CGImage, region: CGRect)
        do {
            guard let pixels = try renderSelectedPixels(from: source, mask: false) else { NSSound.beep(); return }
            lifted = pixels
        } catch { brushError = error.localizedDescription; return }
        let before = document, beforeActive = activeLayerID
        // Outer edit: closed by commitTransform (merge) or cancelTransform (restore).
        beginEdit("Transform Selection")
        await clearSelectedPixels()
        guard let index = self.document?.layers.firstIndex(where: { $0.id == source.id }),
              let thumbnail = try? PixelInvert.thumbnail(of: lifted.image) else {
            self.document = before
            endEdit()
            return
        }
        var floating = ImageLayer(asset: ImportedImage(image: lifted.image, thumbnail: thumbnail, name: "Floating Selection".localized),
                                  origin: lifted.region.origin)
        floating.name = "Floating Selection".localized
        floating.parentID = source.parentID
        floating.opacity = source.opacity
        floating.blendMode = source.blendMode
        self.document?.layers.insert(floating, at: index + 1)
        activeLayerID = floating.id
        tool = .move
        transformEdit = TransformEdit(layerID: floating.id, draft: floating.transform, persistent: true,
            floating: FloatingTransform(sourceID: source.id, before: before, beforeActive: beforeActive,
                                        original: floating.transform, pixelSize: lifted.region.size))
    }

    /// Maps the original selection to where the floating pixels are now.
    func floatingSelectionTransform(_ edit: TransformEdit) -> CGAffineTransform? {
        guard let floating = edit.floating else { return nil }
        let width = Int(floating.pixelSize.width), height = Int(floating.pixelSize.height)
        return BrushRaster.pixelToDocument(floating.original, width: width, height: height).inverted()
            .concatenating(BrushRaster.pixelToDocument(edit.draft, width: width, height: height))
    }

    /// Composites the transformed pixels back into their layer, moves the selection with
    /// them, and closes the undo step. Synchronous so tool/layer switches and Save can call it.
    func mergeFloatingTransform(_ edit: TransformEdit, _ floating: FloatingTransform) {
        defer { endEdit() }
        do {
            guard edit.draft.isValid, let layers = document?.layers,
                  let pixels = layers.first(where: { $0.id == edit.layerID })?.asset?.image,
                  let source = layers.first(where: { $0.id == floating.sourceID }) else { throw ProjectError.invalid }
            // A distorted selection is warped into its new shape first, then merged like any other.
            let placed = try edit.corners.map { corners -> (image: CGImage, transform: LayerTransform) in
                let warped = try DistortWarp.warpTrimmed(pixels, transform: edit.draft, corners: corners)
                return (warped.image, warped.transform)
            } ?? (image: pixels, transform: edit.draft)
            let merged = try FloatingMerge.merge(placed.image, transform: placed.transform, into: source)
            let moved: DocumentSelection?
            if let corners = edit.corners {
                let placement = BrushRaster.pixelToDocument(floating.original, width: Int(floating.pixelSize.width),
                                                             height: Int(floating.pixelSize.height))
                moved = selection.flatMap { selection in
                    DistortWarp.mapPath(selection.path, pixelToDocument: placement, pixelSize: floating.pixelSize,
                                        transform: edit.draft, corners: corners)
                        .map { DocumentSelection(path: $0, antialiased: selection.antialiased) }
                }
            } else {
                moved = floatingSelectionTransform(edit).flatMap { transform -> DocumentSelection? in
                    var matrix = transform
                    guard let selection, let path = selection.path.copy(using: &matrix) else { return nil }
                    return DocumentSelection(path: path, antialiased: selection.antialiased)
                }
            }
            document?.layers.removeAll { $0.id == edit.layerID }
            guard let index = document?.layers.firstIndex(where: { $0.id == source.id }) else { throw ProjectError.invalid }
            document?.layers[index] = ImageLayer(id: source.id, asset: merged.asset, name: source.name, isVisible: source.isVisible,
                transform: merged.transform, parentID: source.parentID, isGroup: false,
                opacity: source.opacity, blendMode: source.blendMode, mask: merged.mask, maskSourceID: source.maskSourceID)
            document?.selection = moved
            activeLayerID = source.id
        } catch {
            document = floating.before
            activeLayerID = floating.beforeActive
            brushError = error.localizedDescription
        }
    }

    func cancelFloatingTransform(_ floating: FloatingTransform) {
        document = floating.before
        activeLayerID = floating.beforeActive
        endEdit()
    }
}

nonisolated enum FloatingMerge {
    /// Draws the floating pixels (with their transform) onto the source layer's own pixel
    /// grid, growing the layer where they now extend past it. A mask grows with it, revealing
    /// the new area.
    static func merge(_ pixels: CGImage, transform: LayerTransform, into source: ImageLayer)
        throws -> (asset: ImportedImage, transform: LayerTransform, mask: LayerMask?) {
        guard let sourceImage = source.asset?.image else { throw ProjectError.invalid }
        let width = sourceImage.width, height = sourceImage.height
        let toDocument = BrushRaster.pixelToDocument(source.transform, width: width, height: height)
        let toPixels = toDocument.inverted()
        let floatingBounds = CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)
            .applying(BrushRaster.pixelToDocument(transform, width: pixels.width, height: pixels.height)).applying(toPixels)
        let original = CGRect(x: 0, y: 0, width: width, height: height)
        let extent = original.union(floatingBounds).integral
        guard extent.width <= 30_000, extent.height <= 30_000, extent.width * extent.height <= 100_000_000
        else { throw ProjectError.tooLarge }
        let context = try BrushRaster.context(width: Int(extent.width), height: Int(extent.height), mask: false)
        let placed = original.offsetBy(dx: -extent.minX, dy: -extent.minY)
        BrushRaster.draw(sourceImage, in: placed, mask: false, context: context)
        context.saveGState()
        context.translateBy(x: -extent.minX, y: -extent.minY)
        context.concatenate(toPixels)
        LayerRenderer.draw(pixels, transform: transform, center: transform.center, in: context)
        context.restoreGState()
        guard let image = context.makeImage() else { throw ExportError.render }
        let asset = ImportedImage(image: image, thumbnail: try PixelInvert.thumbnail(of: image), name: source.name)
        var merged = source.transform
        merged.size = CGSize(width: extent.width * source.size.width / CGFloat(width),
                             height: extent.height * source.size.height / CGFloat(height))
        let center = CGPoint(x: extent.midX, y: extent.midY).applying(toDocument)
        merged.origin = CGPoint(x: center.x - merged.size.width / 2, y: center.y - merged.size.height / 2)
        var mask = source.mask
        if let current = source.mask, current.placement == nil, extent != original {
            let grown = try BrushRaster.context(width: Int(extent.width), height: Int(extent.height), mask: true)
            grown.setFillColor(gray: 1, alpha: 1)
            grown.fill(CGRect(origin: .zero, size: extent.size))
            BrushRaster.draw(current.asset.image, in: placed, mask: true, context: grown)
            guard let maskImage = grown.makeImage() else { throw ExportError.render }
            mask = current.replacing(try LayerMask.asset(from: maskImage))
        }
        return (asset, merged, mask)
    }
}
