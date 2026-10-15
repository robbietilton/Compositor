import CoreGraphics
import Foundation

/// Captures the source mask and frame identities while the destination picker is open.
nonisolated struct GIFFrameMaskCopyRequest: Sendable {
    let layerID: UUID
    let sourceFrameIndex: Int
    let source: GIFSource
    let geometry: GIFFrameGeometry?
    let frameReferences: [GIFFrameReference]
    let mask: LayerMask
}

extension EditorSession {
    /// Missing masks receive the same canvas selection, mapped through the layer's placement.
    /// Existing masks stay intact; immutable coverage can be shared until a frame is painted.
    @discardableResult
    func addGIFFrameMasks(at frameIndices: Set<Int>, for layerID: UUID) async -> Bool {
        guard !Task.isCancelled, gifTimelineCanEditFrameMask, activeLayerID == layerID, let layer = activeLayer,
              let animation = layer.gifAnimation, let canvas = document?.size, let documentID = document?.id,
              !frameIndices.isEmpty, frameIndices.isSubset(of: Set(animation.frameReferences.map(\.index))) else { return false }
        let targets = frameIndices.subtracting(layer.gifFrameMasks.keys)
        guard !targets.isEmpty else { return true }
        let width = animation.geometry?.width ?? animation.source.width
        let height = animation.geometry?.height ?? animation.source.height
        let selection = self.selection
        do {
            guard (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height),
                  width * height <= DocumentLimits.maxSurfacePixels,
                  retainedMaskPixels <= DocumentLimits.documentPixelBudget,
                  targets.count <= (DocumentLimits.documentPixelBudget - retainedMaskPixels) / (width * height) else {
                throw ProjectError.tooLarge
            }
            pauseGIFForEditing(for: layerID)
            finishOpacityEdit()
            isProjectBusy = true
            defer { isProjectBusy = false }
            let clip = try selection?.clip(canvas: canvas)
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let mask = try LayerMask.revealing(clip, over: layer.transform, width: width, height: height)
                var masks: [Int: LayerMask] = [:]
                for index in targets.sorted() {
                    try Task.checkCancellation()
                    masks[index] = mask
                }
                return masks
            }
            let masks = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            isProjectBusy = false
            guard !Task.isCancelled, gifTimelineCanEditFrameMask, activeLayerID == layerID,
                  document?.id == documentID, document?.size == canvas, self.selection == selection,
                  let layerIndex = document?.layers.firstIndex(where: { $0.id == layerID }),
                  let current = document?.layers[layerIndex], current.gifAnimation == animation,
                  current.transform == layer.transform, current.gifFrameMasks == layer.gifFrameMasks else { return false }
            guard retainedMaskPixels <= DocumentLimits.documentPixelBudget,
                  targets.count <= (DocumentLimits.documentPixelBudget - retainedMaskPixels) / (width * height) else {
                throw ProjectError.tooLarge
            }
            beginEdit(targets.count == 1 ? "Add Frame Mask" : "Add Frame Masks")
            document?.layers[layerIndex].gifFrameMasks.merge(masks) { existing, _ in existing }
            if selection != nil { document?.selection = nil }
            if targets.contains(gifTimelineSelectedFrameIndex) {
                isGIFFrameMaskSelected = true
                isMaskSelected = true
            }
            endEdit()
            brushRevision += 1
            refreshCanvasPreview?()
            return true
        } catch {
            if !(error is CancellationError), !Task.isCancelled { brushError = error.localizedDescription }
            return false
        }
    }

    /// Removes only attached frame masks, leaving unmasked frames and shared masks intact.
    @discardableResult
    func deleteGIFFrameMasks(at frameIndices: Set<Int>, for layerID: UUID) -> Bool {
        guard gifTimelineCanEditFrameMask, activeLayerID == layerID,
              let layerIndex = document?.layers.firstIndex(where: { $0.id == layerID }),
              let layer = document?.layers[layerIndex], let animation = layer.gifAnimation,
              !frameIndices.isEmpty, frameIndices.isSubset(of: Set(animation.frameReferences.map(\.index))) else { return false }
        let targets = frameIndices.intersection(layer.gifFrameMasks.keys)
        guard !targets.isEmpty else { return true }
        pauseGIFForEditing(for: layerID)
        finishOpacityEdit()
        beginEdit(targets.count == 1 ? "Delete Frame Mask" : "Delete Frame Masks")
        for index in targets { document?.layers[layerIndex].gifFrameMasks.removeValue(forKey: index) }
        if targets.contains(gifTimelineSelectedFrameIndex), isGIFFrameMaskSelected { isMaskSelected = false }
        endEdit()
        brushRevision += 1
        refreshCanvasPreview?()
        return true
    }

    func prepareGIFFrameMaskCopy(at frameIndex: Int, for layerID: UUID) -> GIFFrameMaskCopyRequest? {
        guard gifTimelineCanEditFrameMask, activeLayerID == layerID, let layer = activeLayer,
              let animation = layer.gifAnimation, animation.containsFrame(frameIndex), animation.frames.count > 1,
              let mask = layer.gifFrameMasks[frameIndex] else { return nil }
        pauseGIFForEditing(for: layerID)
        return GIFFrameMaskCopyRequest(layerID: layerID, sourceFrameIndex: frameIndex, source: animation.source,
            geometry: animation.geometry, frameReferences: animation.frameReferences, mask: mask)
    }

    /// Each destination owns its mask value; immutable pixels can be shared until a later edit replaces them.
    @discardableResult
    func copyGIFFrameMask(_ request: GIFFrameMaskCopyRequest, to frameIndices: Set<Int>) -> Bool {
        guard gifTimelineCanEditFrameMask, activeLayerID == request.layerID,
              let layerIndex = document?.layers.firstIndex(where: { $0.id == request.layerID }),
              let layer = document?.layers[layerIndex], let animation = layer.gifAnimation,
              animation.source === request.source, animation.geometry == request.geometry,
              layer.gifFrameMasks[request.sourceFrameIndex] == request.mask else { return false }
        let targets = frameIndices.subtracting([request.sourceFrameIndex])
        let references = Dictionary(uniqueKeysWithValues: request.frameReferences.map { ($0.index, $0.sourceIndex) })
        guard !targets.isEmpty, targets.union([request.sourceFrameIndex]).allSatisfy({ index in
            guard let expected = references[index] else { return false }
            return animation.sourceFrameIndex(for: index) == expected
        }) else { return false }
        let changed = targets.filter { layer.gifFrameMasks[$0] != request.mask }
        guard !changed.isEmpty else { return true }
        // Saved copies count separately, including shared assets. Replaced masks release their old budget.
        let replaced = changed.reduce(0) { total, index in
            total + (layer.gifFrameMasks[index].map { $0.asset.image.width * $0.asset.image.height } ?? 0)
        }
        let used = retainedMaskPixels - replaced
        let pixels = request.mask.asset.image.width * request.mask.asset.image.height
        guard pixels > 0, pixels <= DocumentLimits.maxSurfacePixels, used <= DocumentLimits.documentPixelBudget,
              changed.count <= (DocumentLimits.documentPixelBudget - used) / pixels else {
            brushError = ProjectError.tooLarge.localizedDescription
            return false
        }
        pauseGIFForEditing(for: request.layerID)
        finishOpacityEdit()
        beginEdit("Copy Frame Mask")
        for index in changed { document?.layers[layerIndex].gifFrameMasks[index] = request.mask }
        endEdit()
        brushRevision += 1
        refreshCanvasPreview?()
        return true
    }
}
