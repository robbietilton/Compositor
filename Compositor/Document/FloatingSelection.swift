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
            // A 16-bit layer's selection lifts at 16 bits, into a 16-bit floating layer.
            guard let pixels = try renderSelectedPixels(from: source, mask: false, sixteenBit: source.asset?.deep != nil) else {
                NSSound.beep(); return
            }
            lifted = pixels
        } catch { brushError = error.localizedDescription; return }
        let before = document, beforeActive = activeLayerID
        // Outer edit: closed by commitTransform (merge) or cancelTransform (restore).
        beginEdit("Transform Selection")
        await clearSelectedPixels()
        let asset = lifted.image.bitsPerComponent > 8
            ? try? DeepLayer.asset(lifted.image, name: "Floating Selection")
            : (try? PixelInvert.thumbnail(of: lifted.image)).map { ImportedImage(image: lifted.image, thumbnail: $0, name: "Floating Selection") }
        guard let index = self.document?.layers.firstIndex(where: { $0.id == source.id }), let asset else {
            self.document = before
            endEdit()
            return
        }
        var floating = ImageLayer(asset: asset, origin: lifted.region.origin)
        floating.name = "Floating Selection"
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
                  let floatingAsset = layers.first(where: { $0.id == edit.layerID })?.asset,
                  case let pixels = try DeepLayer.flattened(floatingAsset) ?? floatingAsset.image,
                  let source = layers.first(where: { $0.id == floating.sourceID }) else { throw ProjectError.invalid }
            // A distorted selection is warped into its new shape first, then merged like any other.
            let placed = try edit.corners.map { corners -> (image: CGImage, transform: LayerTransform) in
                let warped = try DistortWarp.warpTrimmed(pixels, transform: edit.draft, corners: corners,
                                                         sixteenBit: pixels.bitsPerComponent > 8)
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
                        .map { DocumentSelection(path: $0, antialiased: selection.antialiased, feather: selection.feather) }
                }
            } else {
                moved = floatingSelectionTransform(edit).flatMap { transform -> DocumentSelection? in
                    var matrix = transform
                    guard let selection, let path = selection.path.copy(using: &matrix) else { return nil }
                    return DocumentSelection(path: path, antialiased: selection.antialiased, feather: selection.feather)
                }
            }
            document?.layers.removeAll { $0.id == edit.layerID }
            guard let index = document?.layers.firstIndex(where: { $0.id == source.id }) else { throw ProjectError.invalid }
            document?.layers[index] = ImageLayer(id: source.id, asset: merged.asset, name: source.name, isVisible: source.isVisible,
                transform: merged.transform, parentID: source.parentID, isGroup: false,
                opacity: source.opacity, blendMode: source.blendMode, mask: merged.mask, maskSourceID: source.maskSourceID,
                effects: source.effects)
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
        guard source.cameraRawOperation == nil else { throw CameraRawSourceEditError.protectedSource }
        guard let sourceAsset = source.asset else { throw ProjectError.invalid }
        // A 16-bit layer, or 16-bit pixels going in, merge at 16 bits and leave a 16-bit layer (`DeepLayer`).
        let sourceDeep = try DeepLayer.flattened(sourceAsset)
        let sixteenBit = sourceDeep != nil || pixels.bitsPerComponent > 8
        let sourceImage = sourceDeep ?? sourceAsset.image
        let width = sourceImage.width, height = sourceImage.height
        let toDocument = BrushRaster.pixelToDocument(source.transform, width: width, height: height)
        let toPixels = toDocument.inverted()
        let floatingBounds = CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height)
            .applying(BrushRaster.pixelToDocument(transform, width: pixels.width, height: pixels.height)).applying(toPixels)
        let original = CGRect(x: 0, y: 0, width: width, height: height)
        let extent = original.union(floatingBounds).integral
        guard extent.width <= DocumentLimits.maxSideExtent, extent.height <= DocumentLimits.maxSideExtent, extent.width * extent.height <= DocumentLimits.maxSurfaceExtent
        else { throw ProjectError.tooLarge }
        // An HDR layer, or HDR pixels going in, keep light brighter than white.
        let hdr = sourceDeep.map(DeepLayer.isHDR) == true || DeepLayer.isHDR(pixels)
        let context = sixteenBit ? try DeepLayer.context(width: Int(extent.width), height: Int(extent.height), hdr: hdr)
                                 : try BrushRaster.context(width: Int(extent.width), height: Int(extent.height), mask: false)
        let placed = original.offsetBy(dx: -extent.minX, dy: -extent.minY)
        BrushRaster.draw(sourceImage, in: placed, mask: false, context: context)
        context.saveGState()
        context.translateBy(x: -extent.minX, y: -extent.minY)
        context.concatenate(toPixels)
        LayerRenderer.draw(pixels, transform: transform, center: transform.center, in: context)
        context.restoreGState()
        guard let image = context.makeImage() else { throw ExportError.render }
        let asset = sixteenBit ? try DeepLayer.asset(image, name: source.name)
                               : ImportedImage(image: image, thumbnail: try PixelInvert.thumbnail(of: image), name: source.name)
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
