import CoreGraphics
import Foundation

extension EditorSession {
    /// What ⌘E merges, in stacking order, and where the result goes; nil when there is nothing to merge.
    /// One layer merges with the layer beneath it in the same folder; several selected layers merge together
    /// (with anything their folders hold); a folder merges its contents, and the folder goes.
    private func mergePlan() -> (ids: [UUID], removed: Set<UUID>, name: String, parent: UUID?, anchor: UUID, action: String)? {
        guard canEditLayers, let document, let active = activeLayer else { return nil }
        let layers = document.layers
        if selectedLayerIDs.count > 1 {
            var picked = selectedLayerIDs
            for id in selectedLayerIDs { picked.formUnion(descendantIDs(of: id)) }
            let ordered = layers.filter { picked.contains($0.id) }
            guard ordered.contains(where: { !$0.isGroup }),
                  let top = ordered.last(where: { selectedLayerIDs.contains($0.id) }) else { return nil }
            return (ordered.map(\.id), picked, top.name, top.parentID, top.id, "Merge Layers")
        }
        if active.isGroup {
            let inside = descendantIDs(of: active.id)
            guard layers.contains(where: { inside.contains($0.id) && !$0.isGroup }) else { return nil }
            let ids = layers.filter { inside.contains($0.id) || $0.id == active.id }.map(\.id)
            return (ids, Set(ids), active.name, active.parentID, active.id, "Merge Group")
        }
        guard let index = layers.firstIndex(where: { $0.id == active.id }),
              let below = layers[..<index].last(where: { $0.parentID == active.parentID }), !below.isGroup else { return nil }
        return ([below.id, active.id], [below.id, active.id], below.name, active.parentID, active.id, "Merge Down")
    }

    var canMergeLayers: Bool { mergePlan() != nil }
    var mergeTitle: String { mergePlan()?.action ?? "Merge Down" }

    /// ⌘E: the layers composited as the canvas shows them — blend modes, opacity, masks, clipping and adjustments
    /// baked in — into one pixel layer, trimmed to what is there, in their place, as one undo step.
    func mergeLayers() {
        commitTransform()
        guard let plan = mergePlan(), let document else { return }
        let layers = document.layers
        let kept = Set(plan.ids)
        // Only the merged layers, cut loose from anything outside the merge.
        let subset = layers.filter { kept.contains($0.id) }.map { layer -> ImageLayer in
            var copy = layer
            if let parent = copy.parentID, !kept.contains(parent) { copy.parentID = nil }
            if let source = copy.maskSourceID, !kept.contains(source) { copy.maskSourceID = nil }
            return copy
        }
        let canvas = LayerTransform(origin: .zero, size: CGSize(width: document.width, height: document.height))
        let asset: ImportedImage, placed: LayerTransform
        if subset.contains(where: { $0.asset?.deep != nil }) {
            // With a 16-bit layer in it, the merge is drawn at 16 bits from each 16-bit layer's own pixels, and the
            // result is a 16-bit layer (`DeepLayer`).
            guard let made = try? mergedSixteenBit(subset, document: document, canvas: canvas, name: plan.name) else { Platform.beep(); return }
            (asset, placed) = made
        } else {
            let flat = CanvasDocument(id: document.id, width: document.width, height: document.height,
                                      layers: subset, resolution: document.resolution)
            guard let context = try? BrushRaster.context(width: document.width, height: document.height, mask: false) else { return }
            drawLiveComposite(flat, in: context)
            guard let full = context.makeImage(),
                  let trimmed = try? PixelFilter.trimmed(full, placed: canvas),
                  let thumbnail = try? PixelAdjust.thumbnail(of: trimmed.image) else { Platform.beep(); return }
            (asset, placed) = (ImportedImage(image: trimmed.image, thumbnail: thumbnail, name: plan.name), trimmed.transform)
        }
        var merged = ImageLayer(asset: asset, origin: placed.origin)
        merged.transform = placed
        merged.name = plan.name
        merged.parentID = plan.parent
        var next = layers.filter { !plan.removed.contains($0.id) }
        // Layers clipped to anything that was merged now clip to the result.
        for i in next.indices where next[i].maskSourceID.map(plan.removed.contains) == true { next[i].maskSourceID = merged.id }
        let slot = layers.firstIndex { $0.id == plan.anchor } ?? layers.count
        let insertion = slot - layers[..<slot].filter { plan.removed.contains($0.id) }.count
        next.insert(merged, at: min(max(0, insertion), next.count))
        guard (try? LayerHierarchy.validate(next.map(\.hierarchyRecord))) != nil else { Platform.beep(); return }
        finishHeldDrags()
        beginEdit(plan.action)
        self.document?.layers = next
        activeLayerID = merged.id
        endEdit()
    }

    /// The merged layers composited at 16 bits, 16-bit layers drawn from their whole 16-bit pixels, trimmed as an 8-bit
    /// merge is: the merged layer's asset and its placement.
    private func mergedSixteenBit(_ subset: [ImageLayer], document: CanvasDocument, canvas: LayerTransform,
                                  name: String) throws -> (ImportedImage, LayerTransform) {
        let deepLayers = try subset.map { layer -> ImageLayer in
            guard let asset = layer.asset, let deep = try DeepLayer.flattened(asset) else { return layer }
            var copy = layer
            copy.asset = ImportedImage(image: deep, thumbnail: asset.thumbnail, name: asset.name)
            return copy
        }
        let flat = CanvasDocument(id: document.id, width: document.width, height: document.height,
                                  layers: deepLayers, resolution: document.resolution)
        // With an HDR layer among them, the merge keeps light brighter than white too.
        let hdr = subset.contains { $0.asset?.isHDR == true }
        let context = try DeepLayer.context(width: document.width, height: document.height, hdr: hdr)
        drawLiveComposite(flat, in: context, sixteenBit: true, hdr: hdr)
        guard var full = context.makeImage() else { throw ExportError.render }
        var placed = canvas
        if let crop = try PixelFilter.trimCrop(try DeepLayer.dithered(full)), let cropped = full.cropping(to: crop) {
            placed = PixelFilter.trimmedTransform(canvas, crop: crop, width: full.width, height: full.height)
            full = cropped
        }
        return (try DeepLayer.asset(full, name: name), placed)
    }
}
