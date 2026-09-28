import AppKit

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
        let flat = CanvasDocument(id: document.id, width: document.width, height: document.height,
                                  layers: subset, resolution: document.resolution)
        guard let context = try? BrushRaster.context(width: document.width, height: document.height, mask: false) else { return }
        drawLiveComposite(flat, in: context)
        let canvas = LayerTransform(origin: .zero, size: CGSize(width: document.width, height: document.height))
        guard let full = context.makeImage(),
              let trimmed = try? PixelFilter.trimmed(full, placed: canvas),
              let thumbnail = try? PixelAdjust.thumbnail(of: trimmed.image) else { NSSound.beep(); return }
        var merged = ImageLayer(asset: ImportedImage(image: trimmed.image, thumbnail: thumbnail, name: plan.name),
                                origin: trimmed.transform.origin)
        merged.transform = trimmed.transform
        merged.name = plan.name
        merged.parentID = plan.parent
        var next = layers.filter { !plan.removed.contains($0.id) }
        // Layers clipped to anything that was merged now clip to the result.
        for i in next.indices where next[i].maskSourceID.map(plan.removed.contains) == true { next[i].maskSourceID = merged.id }
        let slot = layers.firstIndex { $0.id == plan.anchor } ?? layers.count
        let insertion = slot - layers[..<slot].filter { plan.removed.contains($0.id) }.count
        next.insert(merged, at: min(max(0, insertion), next.count))
        guard (try? LayerHierarchy.validate(next.map(\.hierarchyRecord))) != nil else { NSSound.beep(); return }
        finishOpacityEdit()
        beginEdit(plan.action)
        self.document?.layers = next
        activeLayerID = merged.id
        endEdit()
    }
}

extension EditorSession {
    /// Whether Merge Visible has anything to combine: some visible layer actually carrying pixels.
    var canMergeVisible: Bool { canEditLayers && document?.renderLayers.contains { $0.asset != nil } == true }

    /// Composites every visible layer — groups, opacity, blend modes, masks, clipping and adjustments all taken
    /// into account, exactly as `mergeLayers` composites its own selection — into one pixel layer left in the
    /// topmost visible layer's place, as a top-level layer. Hidden layers are untouched; one left behind inside a
    /// folder that itself merged away moves up to the nearest folder that's still there.
    func mergeVisible() {
        commitTransform()
        guard canMergeVisible, let document, let topmost = document.renderLayers.last else { return }
        guard let context = try? BrushRaster.context(width: document.width, height: document.height, mask: false) else { return }
        drawLiveComposite(document, in: context)
        let canvas = LayerTransform(origin: .zero, size: CGSize(width: document.width, height: document.height))
        guard let full = context.makeImage(),
              let trimmed = try? PixelFilter.trimmed(full, placed: canvas),
              let thumbnail = try? PixelAdjust.thumbnail(of: trimmed.image) else { NSSound.beep(); return }
        var merged = ImageLayer(asset: ImportedImage(image: trimmed.image, thumbnail: thumbnail, name: topmost.name),
                                origin: trimmed.transform.origin)
        merged.transform = trimmed.transform
        merged.name = topmost.name
        let removed = document.effectiveVisibleIDs
        let byID = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0) })
        func survivingParent(of id: UUID?) -> UUID? {
            var current = id, steps = 0
            while let candidate = current, removed.contains(candidate), steps < 64 {
                current = byID[candidate]?.parentID
                steps += 1
            }
            return current
        }
        // Rebuilt in stacking order — the array orders only siblings — so the merged layer takes the top of the
        // visible stack, and a hidden layer left behind stays where it was in it, now at the top level.
        var next: [ImageLayer] = []
        for id in document.hierarchy.order {
            if id == topmost.id { next.append(merged) }
            guard !removed.contains(id), var layer = byID[id] else { continue }
            layer.parentID = survivingParent(of: layer.parentID)
            next.append(layer)
        }
        Self.releaseDetachedClipping(in: &next)
        guard (try? LayerHierarchy.validate(next.map(\.hierarchyRecord))) != nil else { NSSound.beep(); return }
        finishOpacityEdit()
        beginEdit("Merge Visible")
        self.document?.layers = next
        activeLayerID = merged.id
        endEdit()
    }

    /// Whether there's anything for Flatten Image to do.
    var canFlattenImage: Bool { canEditLayers && !(document?.layers.isEmpty ?? true) }

    /// Composites every visible layer into one layer named "Background" and discards hidden layers outright —
    /// unlike Merge Visible, which leaves them alone. It doesn't ask first: one Undo brings them all back.
    func flattenImage() {
        commitTransform()
        guard canFlattenImage, let document else { return }
        guard let context = try? BrushRaster.context(width: document.width, height: document.height, mask: false) else { return }
        drawLiveComposite(document, in: context)
        let canvas = LayerTransform(origin: .zero, size: CGSize(width: document.width, height: document.height))
        guard let full = context.makeImage(),
              let trimmed = try? PixelFilter.trimmed(full, placed: canvas),
              let thumbnail = try? PixelAdjust.thumbnail(of: trimmed.image) else { NSSound.beep(); return }
        var flat = ImageLayer(asset: ImportedImage(image: trimmed.image, thumbnail: thumbnail, name: "Background"),
                              origin: trimmed.transform.origin)
        flat.transform = trimmed.transform
        flat.name = "Background"
        finishOpacityEdit()
        beginEdit("Flatten Image")
        self.document?.layers = [flat]
        activeLayerID = flat.id
        collapsedGroupIDs = []
        endEdit()
    }
}
