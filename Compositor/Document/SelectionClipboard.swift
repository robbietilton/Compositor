import AppKit

/// Pixels copied from the canvas, with where they came from so Paste can put them back in place.
struct PixelClipboard {
    let image: CGImage
    let origin: CGPoint
    /// The system pasteboard's change count right after writing; a mismatch means another app copied since.
    let changeCount: Int
}

/// A whole layer copied with no selection. Paste brings it back complete — folder contents, mask, effects, editable
/// text: in this project as a copy above it, in another as dragging it onto that project's tab does.
struct CopiedLayer {
    /// Top to bottom as the document lists them; a layer inside a copied folder comes with the folder, not on its own.
    let ids: [UUID]
    /// As `PixelClipboard.changeCount`: anything copied since replaces it.
    let changeCount: Int
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

    /// Copy with no selection copies the layer itself, for Paste here or in another project. That works for folders
    /// and adjustments too, which have no pixels of their own to copy.
    var canCopyLayer: Bool { canEditLayers && activeLayer != nil && selection == nil && !isMaskSelected }

    /// Cmd-C: copies the selected pixels (or the whole layer) for Paste, and to the system
    /// pasteboard as PNG for other apps.
    func copySelection() {
        guard canCopyPixels || canCopyLayer, let layer = activeLayer else { return }
        guard canCopyPixels else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(layer.id.uuidString, forType: NSPasteboard.PasteboardType("com.compositor.copied-layer"))
            pixelClipboard = nil
            copiedLayer = CopiedLayer(ids: copiedLayerIDs(), changeCount: pasteboard.changeCount)
            return
        }
        do {
            guard let copied = try renderSelectedPixels(from: layer, mask: isMaskSelected) else { NSSound.beep(); return }
            store(copied)
            if canCopyLayer { copiedLayer = CopiedLayer(ids: copiedLayerIDs(), changeCount: NSPasteboard.general.changeCount) }
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
        copiedLayer = nil
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
        return NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// Cmd-V: pastes as a new layer above the active one. Pixels copied here go back exactly
    /// where they came from; images copied in other apps are centered.
    func paste() {
        guard canPaste, let document else { return }
        let pasteboard = NSPasteboard.general
        if let clip = pixelClipboard, pasteboard.changeCount == clip.changeCount {
            addPixelLayer(clip.image, at: clip.origin, name: nextLayerName(), editName: "Paste")
        } else if let external = NSImage(pasteboard: pasteboard)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let image = try? Self.sRGBCopy(of: external) {
            let origin = CGPoint(x: floor((document.size.width - CGFloat(image.width)) / 2),
                                 y: floor((document.size.height - CGFloat(image.height)) / 2))
            addPixelLayer(image, at: origin, name: nextLayerName(), editName: "Paste")
        } else { NSSound.beep() }
    }

    /// Cmd-J (Layer via Copy): the selection's pixels become a new layer in place; with no
    /// selection the whole layer is duplicated.
    func layerViaCopy() {
        guard canEditLayers, let layer = activeLayer, selection?.isEmpty != true else { return }
        // Without a selection it duplicates, folders included; with one it copies pixels, which a folder has none of.
        guard selection != nil else { duplicateActiveLayer(); return }
        guard !layer.isGroup else { return }
        do {
            guard let copied = try renderSelectedPixels(from: layer, mask: isMaskSelected) else { NSSound.beep(); return }
            addPixelLayer(copied.image, at: copied.region.origin, name: nextLayerName(), editName: "Layer via Copy")
        } catch { brushError = error.localizedDescription }
    }

    /// The selected layers Copy and Duplicate take whole, in document order, leaving out any inside a selected folder.
    private func copiedLayerIDs() -> [UUID] {
        let selected = selectedLayerIDs.union(activeLayerID.map { [$0] } ?? [])
        let nested = selected.reduce(into: Set<UUID>()) { $0.formUnion(descendantIDs(of: $1)) }
        return (document?.layers ?? []).map(\.id).filter { selected.contains($0) && !nested.contains($0) }
    }

    /// ⌘J and Duplicate Layer: every selected layer, as Photoshop does.
    func duplicateActiveLayer() {
        duplicateLayers(copiedLayerIDs())
    }

    /// A copy of each layer (a folder with all it holds), as one undo step: Duplicate Layer, and Paste of layers Copy
    /// took whole. One copy sits just above its original; several stack together, in their order, above the topmost
    /// original, as Photoshop's do. The copies end up selected.
    func duplicateLayers(_ ids: [UUID], editName: String = "Duplicate Layer") {
        guard canEditLayers, !ids.isEmpty else { return }
        let active = activeLayerID
        beginEdit(editName)
        var copiesOf: [UUID: UUID] = [:]
        for id in ids { if let copy = insertCopy(of: id) { copiesOf[id] = copy } }
        guard !copiesOf.isEmpty else { endEdit(); return }
        if copiesOf.count > 1, let layers = document?.layers {
            // Panel order, top first, so layers in different folders compare as they're seen.
            let panel = LayerHierarchy.entries(layers.map(\.hierarchyRecord), topFirst: true, collapsed: []).map(\.layer.id)
            let originals = panel.filter { copiesOf[$0] != nil }
            if let top = originals.first, let topLayer = layers.first(where: { $0.id == top }) {
                let parent = topLayer.parentID
                var below = top
                for original in originals.reversed() {
                    guard let copy = copiesOf[original], placeLayer(copy, in: parent, above: below) else { continue }
                    below = copy
                }
            }
        }
        activeLayerID = active.flatMap { copiesOf[$0] } ?? copiesOf[ids[0]] ?? copiesOf.values.first
        selectedLayerIDs = Set(copiesOf.values)
        endEdit()
    }

    /// Inserts a copy of the layer and anything it holds just above it; returns the copy's id.
    private func insertCopy(of id: UUID) -> UUID? {
        guard let layer = document?.layers.first(where: { $0.id == id }),
              let index = document?.layers.firstIndex(where: { $0.id == layer.id }) else { return nil }
        let included = descendantIDs(of: layer.id).union([layer.id])
        let originals = (document?.layers ?? []).filter { included.contains($0.id) }
        guard (document?.layers.count ?? 0) + originals.count <= 10_000 else { return nil }
        let mapping = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, UUID()) })
        let copies = originals.map { original in
            ImageLayer(id: mapping[original.id]!, asset: original.asset,
                name: original.name + (original.id == layer.id ? " copy" : ""), isVisible: original.isVisible,
                transform: original.transform, parentID: original.parentID.map { mapping[$0] ?? $0 },
                isGroup: original.isGroup, opacity: original.opacity, blendMode: original.blendMode,
                mask: original.mask, maskSourceID: original.maskSourceID.map { mapping[$0] ?? $0 },
                adjustment: original.adjustment, shape: original.shape, effects: original.effects, text: original.text)
        }
        document?.layers.insert(contentsOf: copies, at: index + 1)
        for original in originals where collapsedGroupIDs.contains(original.id) {
            collapsedGroupIDs.insert(mapping[original.id]!)
        }
        return mapping[layer.id]
    }

    /// Option-drag in the Layers panel: a copy of the layer placed where it was dropped (inside `parent`,
    /// above `target`, or at the very bottom), as one undo step. Folders carry all descendants.
    @discardableResult
    func duplicateLayer(_ id: UUID, in parent: UUID?, above target: UUID? = nil, atBottom: Bool = false) -> Bool {
        guard canEditLayers,
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
