import AppKit

nonisolated enum LiveMaskGraph {
    static func validate(_ layers: [ProjectLayerRecord]) throws {
        var records: [UUID: ProjectLayerRecord] = [:]
        for layer in layers {
            guard records.updateValue(layer, forKey: layer.id) == nil else { throw ProjectError.invalid }
        }
        for layer in layers {
            var path = Set<UUID>(), current: UUID? = layer.id
            while let id = current {
                guard path.count < 256, path.insert(id).inserted, let record = records[id] else { throw ProjectError.invalid }
                if let source = record.maskSourceID {
                    guard !((record.isGroup ?? false)), records[source] != nil, records[source]?.isGroup != true, records[source]?.adjustment == nil else { throw ProjectError.invalid }
                }
                current = record.maskSourceID
            }
        }
    }
}

extension EditorSession {
    func canLinkMask(source: UUID, target: UUID) -> Bool {
        guard canEditLayers, source != target, let layers = document?.layers,
              layers.contains(where: { $0.id == source && !$0.isGroup && $0.adjustment == nil }),
              layers.contains(where: { $0.id == target && !$0.isGroup }) else { return false }
        var records = layers.map(\.hierarchyRecord)
        records[records.firstIndex(where: { $0.id == target })!].maskSourceID = source
        return (try? LiveMaskGraph.validate(records)) != nil
    }
    @discardableResult func linkMask(source: UUID, target: UUID) -> Bool {
        guard canLinkMask(source: source, target: target), let index = document?.layers.firstIndex(where: { $0.id == target }) else { return false }
        guard document?.layers[index].maskSourceID != source else { return true }
        beginEdit("Create Clipping Mask")
        document?.layers[index].maskSourceID = source
        endEdit()
        return true
    }
    /// A layer dropped into the middle of a clipping group joins it, as in Photoshop: dropped between a base and a
    /// layer clipped to it, it is clipped to that base too. Run while the layers are being rearranged, before
    /// `releaseDetachedClipping` — an unclipped layer left in the middle of a group breaks it up instead.
    static func adoptClipping(_ id: UUID, in layers: inout [ImageLayer]) {
        guard let layer = layers.first(where: { $0.id == id }), !layer.isGroup else { return }
        let siblings = layers.filter { $0.parentID == layer.parentID }
        guard let index = siblings.firstIndex(where: { $0.id == id }), index > 0, index + 1 < siblings.count,
              let source = siblings[index + 1].maskSourceID, source != id else { return }
        let below = siblings[index - 1]
        guard below.id == source || below.maskSourceID == source,
              let position = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[position].maskSourceID = source
    }

    func removeLiveMask(from target: UUID) {
        guard canEditLayers, let document else { return }
        guard let targetLayer = document.layers.first(where: { $0.id == target }),
              let source = targetLayer.maskSourceID else { return }
        // Releasing a base releases its clipped children above it that share
        // that base. Releasing a child leaves lower siblings untouched.
        let siblings = document.layers.filter { $0.parentID == targetLayer.parentID }
        guard let targetIndex = siblings.firstIndex(where: { $0.id == target }) else { return }
        let releases = siblings[(targetIndex...)]
            .prefix { $0.id == target || $0.maskSourceID == source }
            .map(\.id)
        beginEdit("Release Clipping Mask")
        for id in releases {
            if let index = self.document?.layers.firstIndex(where: { $0.id == id }) {
                self.document?.layers[index].maskSourceID = nil
            }
        }
        endEdit()
    }
}

nonisolated enum LiveMaskBaker {
    static func bake(_ snapshot: ProjectSnapshot, target: UUID) throws -> ImportedImage? {
        guard let record = snapshot.manifest.layers.first(where: { $0.id == target }), let original = snapshot.images[target] else { return nil }
        let w = original.image.width, h = original.image.height
        let context = try BrushRaster.context(width: w, height: h, mask: false)
        let inverse = BrushRaster.pixelToDocument(record.transform, width: w, height: h).inverted()
        let records = Dictionary(uniqueKeysWithValues: snapshot.manifest.layers.map { ($0.id, $0) })
        let live = LiveMaskRenderer(bounds: CGRect(x: 0, y: 0, width: w, height: h), source: { records[$0]?.maskSourceID }) { id, ctx in
            guard let layer = records[id], let image = snapshot.images[id]?.image else { return }
            if id == target {
                // Bake only the live dependency into pixels; retain the target's raster mask and appearance.
                LayerRenderer.draw(image, transform: LayerTransform(origin: .zero, size: CGSize(width: w, height: h)), center: CGPoint(x: CGFloat(w)/2, y: CGFloat(h)/2), in: ctx)
            } else {
                ctx.saveGState(); ctx.concatenate(inverse)
                LayerRenderer.draw(image, transform: layer.transform, center: layer.transform.center,
                    opacity: layer.effectiveOpacity(in: records),
                    mask: snapshot.mask(for: layer).flatMap { $0.clipImage(placement: $0.placement, over: layer.transform, width: image.width, height: image.height) }, in: ctx)
                ctx.restoreGState()
            }
        }
        live.draw(target, in: context)
        guard let image = context.makeImage() else { throw ExportError.render }
        return ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: original.name)
    }
}

extension EditorSession {
    func deleteWithLiveMaskChoice(_ id: UUID) -> Bool { deleteWithLiveMaskChoice([id]) }
    /// When layers being deleted supply live masks to layers that stay, asks whether to bake or unlink,
    /// then deletes them all; returns false, having done nothing, when none do.
    func deleteWithLiveMaskChoice(_ ids: [UUID]) -> Bool {
        let removed = ids.reduce(into: Set<UUID>()) { $0.formUnion(descendantIDs(of: $1).union([$1])) }
        let targets = (document?.layers ?? []).filter { !removed.contains($0.id) && $0.maskSourceID.map(removed.contains) == true }.map(\.id)
        guard !targets.isEmpty else { return false }
        let alert = NSAlert()
        alert.messageText = localized(ids.count == 1 ? "This layer supplies a live mask" : "These layers supply live masks")
        alert.informativeText = localized("Bake keeps the current masked appearance in the dependent layers’ pixels. Remove Links reveals their pixels. You can undo either choice.")
        alert.addButton(withTitle: localized("Bake and Delete"))
        alert.addButton(withTitle: localized("Cancel"))
        alert.addButton(withTitle: localized("Remove Links and Delete"))
        let response = alert.runModal()
        if response == .alertThirdButtonReturn { finishDeletingLayers(ids, baked: [:]); return true }
        guard response == .alertFirstButtonReturn, let snapshot = projectSnapshot() else { return true }
        isProjectBusy = true
        Task {
            defer { isProjectBusy = false }
            do {
                let baked = try await Task.detached(priority: .userInitiated) {
                    var result: [UUID: ImportedImage] = [:]
                    for target in targets { result[target] = try LiveMaskBaker.bake(snapshot, target: target) }
                    return result
                }.value
                finishDeletingLayers(ids, baked: baked)
            } catch { brushError = error.localizedDescription }
        }
        return true
    }
    func finishDeletingLayer(_ id: UUID, baked: [UUID: ImportedImage]) {
        guard let index = document?.layers.firstIndex(where: { $0.id == id }) else { return }
        let removed = descendantIDs(of: id).union([id])
        beginEdit("Delete Layer")
        document?.layers.removeAll { removed.contains($0.id) }
        for i in document?.layers.indices ?? 0..<0 {
            if let source = document?.layers[i].maskSourceID, removed.contains(source) {
                document?.layers[i].maskSourceID = nil
                if let asset = baked[document!.layers[i].id] { document?.layers[i].asset = asset }
            }
        }
        if activeLayerID.map({ removed.contains($0) }) == true {
            let layers = document?.layers ?? []
            activeLayerID = layers.isEmpty ? nil : layers[min(index, layers.count - 1)].id
        }
        endEdit()
    }
    /// Deletes several layers (a folder with its contents) as one undo step.
    func finishDeletingLayers(_ ids: [UUID], baked: [UUID: ImportedImage]) {
        guard ids.count > 1 else { if let id = ids.first { finishDeletingLayer(id, baked: baked) }; return }
        beginEdit("Delete Layers")
        for id in ids { finishDeletingLayer(id, baked: baked) }
        endEdit()
    }
}


extension EditorSession {
    func drawLiveComposite(_ document: CanvasDocument, in context: CGContext, onSurface: Bool = false) {
        if !onSurface, document.layers.contains(where: { $0.adjustment != nil }) {
            AdjustmentSurface.draw(in: context) { self.drawLiveComposite(document, in: $0, onSurface: true) }
            return
        }
        let records = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0) })
        let live = LiveMaskRenderer(bounds: context.boundingBoxOfClipPath, source: { records[$0]?.maskSourceID }) { id, ctx in
            guard let layer = records[id], let image = layer.asset?.image else { return }
            let opacity = layer.effectiveOpacity(in: records)
            let transform = self.displayedTransform(for: layer)
            let mask = layer.mask?.clipImage(placement: self.displayedMaskPlacement(for: layer), over: transform, width: image.width, height: image.height)
            let effects = LayerEffectsRenderer.cached(image, mask: mask, effects: layer.effects)
            func drawLayer(_ mode: LayerBlendMode, _ target: CGContext) {
                if let effects {
                    let grown = LayerEffectsRenderer.placed(transform, image: effects.image, inset: effects.inset)
                    LayerRenderer.draw(effects.image, transform: grown, center: grown.center, opacity: opacity,
                        blendMode: mode, mask: nil, in: target)
                    return
                }
                LayerRenderer.draw(image, transform: transform, center: transform.center, opacity: opacity,
                    blendMode: mode, mask: mask, in: target)
            }
            let mode = self.displayedBlendMode(for: layer)
            // Core Graphics blends these two wrong; see SeparableBlend.
            if SeparableBlend.needsSurface(mode), SeparableBlend.draw(mode, in: ctx, body: { drawLayer(.normal, $0) }) { return }
            drawLayer(mode, ctx)
        }
        live.adjustment = { records[$0]?.adjustment }
        live.adjustmentOpacity = { records[$0]?.effectiveOpacity(in: records) ?? 1 }
        live.adjustmentClip = { id, ctx in
            if let layer = records[id], let image = layer.mask?.enabledImage {
                FolderMaskClip(image: image, transform: layer.transform).apply(center: layer.transform.center, in: ctx)
            }
        }
        live.prepareStacks(document.renderLayers.map(\.id), parent: { records[$0]?.parentID }, blend: { records[$0].map { self.displayedBlendMode(for: $0) } ?? .normal })
        FolderMaskClip.draw(document.renderLayers.map(\.id), parent: { records[$0]?.parentID }, clip: { id in
            guard let folder = records[id], let image = folder.mask?.enabledImage else { return nil }
            let transform = self.displayedTransform(for: folder)
            let clip = FolderMaskClip(image: image, transform: transform)
            return { clip.apply(center: transform.center, in: $0) }
        }, in: context) { live.drawComposite($0, in: context) }
    }
}


extension EditorSession {
    func canToggleClippingMask(_ id: UUID) -> Bool {
        guard canEditLayers, let layers = document?.layers,
              let layer = layers.first(where: { $0.id == id }), !layer.isGroup else { return false }
        if layer.maskSourceID != nil { return true }
        let siblings = layers.filter { $0.parentID == layer.parentID }
        guard let index = siblings.firstIndex(where: { $0.id == id }), index > 0, !siblings[index-1].isGroup else { return false }
        return canLinkMask(source: siblings[index-1].maskSourceID ?? siblings[index-1].id, target: id)
    }
    /// Option-click clips to the next lower sibling, sharing its base when it is already clipped.
    func toggleClippingMask(_ id: UUID) {
        guard canEditLayers, let layers = document?.layers,
              let layer = layers.first(where: { $0.id == id }), !layer.isGroup else { return }
        if layer.maskSourceID != nil { removeLiveMask(from: id); return }
        let siblings = layers.filter { $0.parentID == layer.parentID }
        guard let index = siblings.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let below = siblings[index-1]
        guard !below.isGroup else { return }
        linkMask(source: below.maskSourceID ?? below.id, target: id)
    }
    /// A moved layer stops clipping when it no longer belongs to the contiguous stack above its base.
    static func releaseDetachedClipping(in layers: inout [ImageLayer]) {
        let siblings = Dictionary(grouping: layers, by: \.parentID)
        var release = Set<UUID>()
        for stack in siblings.values {
            var base: UUID?
            for layer in stack {
                if let source = layer.maskSourceID {
                    if source != base { release.insert(layer.id); base = layer.id }
                } else { base = layer.isGroup ? nil : layer.id }
            }
        }
        for i in layers.indices where release.contains(layers[i].id) { layers[i].maskSourceID = nil }
    }
}
