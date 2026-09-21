import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Pixels copied from the canvas, with where they came from so Paste can put them back in place.
struct PixelClipboard {
    let image: CGImage
    let origin: CGPoint
    /// The system pasteboard's change count right after writing; a mismatch means another app copied since.
    let changeCount: Int
}

/// Decodes image data exposed by other apps, including browsers that advertise only a generic `public.image` UTI.
enum ClipboardImage {
    static func image(from pasteboard: NSPasteboard = .general) -> CGImage? {
        for type in imageTypes(for: pasteboard) {
            guard let data = pasteboard.data(forType: type),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            return image
        }
        return NSImage(pasteboard: pasteboard)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func dimensions(_ pasteboard: NSPasteboard = .general) -> (width: Int, height: Int)? {
        for type in imageTypes(for: pasteboard) {
            guard let data = pasteboard.data(forType: type),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  var width = properties[kCGImagePropertyPixelWidth] as? Int,
                  var height = properties[kCGImagePropertyPixelHeight] as? Int else { continue }
            if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
                swap(&width, &height)
            }
            if CanvasDocument.validDimension(String(width)) != nil,
               CanvasDocument.validDimension(String(height)) != nil { return (width, height) }
        }
        guard let image = image(from: pasteboard),
              CanvasDocument.validDimension(String(image.width)) != nil,
              CanvasDocument.validDimension(String(image.height)) != nil else { return nil }
        return (image.width, image.height)
    }

    private static func imageTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var result = [NSPasteboard.PasteboardType.png, .tiff]
        for type in pasteboard.types ?? [] where !result.contains(type) {
            if UTType(type.rawValue)?.conforms(to: .image) == true { result.append(type) }
        }
        return result
    }
}

extension EditorSession {
    /// Whole-pixel bounds of what Copy takes: the selection, or the whole canvas without one.
    /// Path boolean operations leave tiny float noise (59.9999999), so round with a tolerance
    /// rather than letting it add a whole pixel.
    func selectionCopyRegion() -> CGRect? {
        guard let document else { return nil }
        let canvas = CGRect(origin: .zero, size: document.size)
        let bounds = selection?.coverageBounds ?? canvas
        let tolerance: CGFloat = 0.001
        let minX = floor(bounds.minX + tolerance), minY = floor(bounds.minY + tolerance)
        let region = CGRect(x: minX, y: minY, width: ceil(bounds.maxX - tolerance) - minX,
                            height: ceil(bounds.maxY - tolerance) - minY).intersection(canvas)
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return nil }
        return region
    }

    var canCopyPixels: Bool {
        guard canEditLayers, let layer = activeLayer, !layer.isGroup || isMaskSelected, selection?.isEmpty != true else { return false }
        return isMaskSelected ? layer.mask != nil : layer.asset != nil
    }

    /// The active layer's pixels (or mask as opaque gray) exactly as they sit on the canvas,
    /// clipped to the selection (soft edges kept), or the whole canvas without one.
    func renderSelectedPixels(from layer: ImageLayer, mask: Bool) throws -> (image: CGImage, region: CGRect)? {
        guard let document else { return nil }
        let clip = try selection?.clip(canvas: document.size)
        if clip != nil, clip?.coverage == nil { return nil }
        guard let region = selectionCopyRegion() else { return nil }
        let context = try BrushRaster.context(width: Int(region.width), height: Int(region.height), mask: false)
        context.translateBy(x: -region.minX, y: -region.minY)
        clip?.apply(to: context)
        let transform = displayedTransform(for: layer)
        if mask, let owned = layer.mask {
            let placement = displayedMaskPlacement(for: layer)
            context.setFillColor(gray: placement == nil ? 0 : LayerMask.background(of: owned.asset.thumbnail), alpha: 1)
            context.fill(region)
            LayerRenderer.drawCoverage(owned.asset.image, transform: placement ?? transform, in: context)
        } else if !mask, let image = layer.asset?.image {
            LayerRenderer.draw(image, transform: transform, center: transform.center, in: context)
        } else { return nil }
        guard let image = context.makeImage() else { throw ExportError.render }
        return (image, region)
    }

    var canCopyMerged: Bool {
        canEditLayers && selection?.isEmpty != true && document?.renderLayers.contains { $0.asset != nil } == true
    }

    /// Shift-Cmd-C (Copy Merged): the selection across every visible layer, composited as
    /// the canvas shows it, including opacity, blend modes, and masks.
    func renderMergedPixels() throws -> (image: CGImage, region: CGRect)? {
        guard let document else { return nil }
        let clip = try selection?.clip(canvas: document.size)
        if clip != nil, clip?.coverage == nil { return nil }
        guard let region = selectionCopyRegion() else { return nil }
        // Composited on its own first, then drawn through the selection: a transparency layer would do the same,
        // but Color Burn and Color Dodge need to read what they are blending with, which a group hides.
        let composite = try BrushRaster.context(width: Int(region.width), height: Int(region.height), mask: false)
        composite.translateBy(x: -region.minX, y: -region.minY)
        drawLiveComposite(document, in: composite)
        guard let merged = composite.makeImage() else { throw ExportError.render }
        let context = try BrushRaster.context(width: Int(region.width), height: Int(region.height), mask: false)
        context.translateBy(x: -region.minX, y: -region.minY)
        clip?.apply(to: context)
        BrushRaster.draw(merged, in: region, mask: false, context: context)
        guard let image = context.makeImage() else { throw ExportError.render }
        return (image, region)
    }

    func copyMergedSelection() {
        guard canCopyMerged else { return }
        do {
            guard let copied = try renderMergedPixels() else { NSSound.beep(); return }
            store(copied)
        } catch { brushError = error.localizedDescription }
    }

    /// Cmd-C: copies the selected pixels (or the whole layer) for Paste, and to the system
    /// pasteboard as PNG for other apps.
    func copySelection() {
        guard canCopyPixels, let layer = activeLayer else { return }
        do {
            guard let copied = try renderSelectedPixels(from: layer, mask: isMaskSelected) else { NSSound.beep(); return }
            store(copied)
        } catch { brushError = error.localizedDescription }
    }

    /// Keeps pixels for Paste and puts them on the system pasteboard as PNG.
    private func store(_ copied: (image: CGImage, region: CGRect)) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let png = NSBitmapImageRep(cgImage: copied.image).representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
        }
        pixelClipboard = PixelClipboard(image: copied.image, origin: copied.region.origin, changeCount: pasteboard.changeCount)
    }

    /// Cmd-X: copy, then clear the selected pixels.
    func cutSelection() async {
        guard selection != nil, canCopyPixels else { return }
        copySelection()
        await clearSelectedPixels()
    }

    var canPaste: Bool {
        guard document != nil, canEditLayers else { return false }
        if let pixelClipboard, NSPasteboard.general.changeCount == pixelClipboard.changeCount { return true }
        return ClipboardImage.image(from: NSPasteboard.general) != nil
    }

    /// A browser image can start the first document directly from the welcome canvas. Keep this separate from
    /// `canPaste`: a text field must continue to receive ordinary text paste while no document exists.
    var canPasteIntoNewCanvas: Bool {
        guard document == nil, textDraft == nil, !isProjectBusy, !isImporting,
              !showsImporter, importError == nil else { return false }
        return ClipboardImage.dimensions() != nil
    }

    /// Cmd-V: pastes as a new layer above the active one. Pixels copied here go back exactly
    /// where they came from; images copied in other apps are centered.
    func paste() {
        let pasteboard = NSPasteboard.general
        if document == nil {
            guard canPasteIntoNewCanvas, let size = ClipboardImage.dimensions(pasteboard) else {
                NSSound.beep()
                return
            }
            createDocument(width: size.width, height: size.height)
        }
        guard canPaste, let document else { return }
        if let clip = pixelClipboard, pasteboard.changeCount == clip.changeCount {
            addPixelLayer(clip.image, at: clip.origin, name: nextLayerName(), editName: "Paste")
        } else if let external = ClipboardImage.image(from: pasteboard),
                  let image = try? Self.sRGBCopy(of: external) {
            let origin = CGPoint(x: floor((document.size.width - CGFloat(image.width)) / 2),
                                 y: floor((document.size.height - CGFloat(image.height)) / 2))
            addPixelLayer(image, at: origin, name: nextLayerName(), editName: "Paste")
        } else { NSSound.beep() }
    }

    /// Cmd-J (Layer via Copy): the selection's pixels become a new layer in place; with no
    /// selection the whole layer is duplicated.
    func layerViaCopy() {
        guard canEditLayers, let layer = activeLayer, !layer.isGroup, selection?.isEmpty != true else { return }
        guard selection != nil else { duplicateActiveLayer(); return }
        do {
            guard let copied = try renderSelectedPixels(from: layer, mask: isMaskSelected) else { NSSound.beep(); return }
            addPixelLayer(copied.image, at: copied.region.origin, name: nextLayerName(), editName: "Layer via Copy")
        } catch { brushError = error.localizedDescription }
    }

    func duplicateActiveLayer() {
        guard canEditLayers, let layer = activeLayer,
              let index = document?.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        let included = descendantIDs(of: layer.id).union([layer.id])
        let originals = (document?.layers ?? []).filter { included.contains($0.id) }
        guard (document?.layers.count ?? 0) + originals.count <= 10_000 else { return }
        let mapping = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, UUID()) })
        let copies = originals.map { original in
            ImageLayer(id: mapping[original.id]!, asset: original.asset,
                name: original.name + (original.id == layer.id ? " copy" : ""), isVisible: original.isVisible,
                transform: original.transform, parentID: original.parentID.map { mapping[$0] ?? $0 },
                isGroup: original.isGroup, opacity: original.opacity, blendMode: original.blendMode,
                mask: original.mask, maskSourceID: original.maskSourceID.map { mapping[$0] ?? $0 },
                adjustment: original.adjustment, shape: original.shape, effects: original.effects, text: original.text)
        }
        beginEdit("Duplicate Layer")
        document?.layers.insert(contentsOf: copies, at: index + 1)
        for original in originals where collapsedGroupIDs.contains(original.id) {
            collapsedGroupIDs.insert(mapping[original.id]!)
        }
        activeLayerID = mapping[layer.id]
        endEdit()
    }

    /// Option-drag in the Layers panel: a copy of the layer placed where it was dropped (inside `parent`,
    /// above `target`, or at the very bottom), as one undo step. Folders carry all descendants.
    @discardableResult
    func duplicateLayer(_ id: UUID, in parent: UUID?, above target: UUID? = nil, atBottom: Bool = false) -> Bool {
        guard canEditLayers,
              document?.layers.first(where: { $0.id == id })?.isGroup != true,
              canPlaceLayer(id, in: parent) else { return false }
        beginEdit("Duplicate Layer")
        defer { endEdit() }
        selectLayer(id)
        duplicateActiveLayer()
        guard let copy = activeLayerID, copy != id else { return false }
        return placeLayer(copy, in: parent, above: target, atBottom: atBottom)
    }

    /// Inserts pixels as a new layer above the active one (inside its folder), all in one undo
    /// step. Pasting drops the selection, as in Photoshop; a drawn shape keeps it.
    func addPixelLayer(_ image: CGImage, at origin: CGPoint, name: String, editName: String, dropsSelection: Bool = true, shape: LayerShape? = nil, text: LayerText? = nil) {
        guard let document, let thumbnail = try? PixelInvert.thumbnail(of: image) else { return }
        var layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: thumbnail, name: name), origin: origin)
        layer.name = name
        layer.shape = shape
        layer.text = text
        layer.parentID = activeLayer?.isGroup == true ? activeLayerID : activeLayer?.parentID
        let index = document.layers.firstIndex { $0.id == activeLayerID }.map { $0 + 1 } ?? document.layers.count
        finishOpacityEdit()
        beginEdit(editName)
        self.document?.layers.insert(layer, at: index)
        if dropsSelection { self.document?.selection = nil }
        activeLayerID = layer.id
        endEdit()
    }

    func nextLayerName() -> String {
        let names = Set(document?.layers.map(\.name) ?? [])
        var number = 1
        while names.contains("Layer \(number)") { number += 1 }
        return "Layer \(number)"
    }

    /// Normalizes an image from another app to the working sRGB RGBA format.
    private static func sRGBCopy(of image: CGImage) throws -> CGImage {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        guard let copy = context.makeImage() else { throw ExportError.render }
        return copy
    }
}
