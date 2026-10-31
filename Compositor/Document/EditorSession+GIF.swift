import Foundation
import CoreGraphics

extension EditorSession {
    func setGIFFrameTiming(_ timing: GIFFrameTiming, for layerID: UUID) {
        guard gifTimelineCanEditTiming, activeLayerID == layerID,
              let layerIndex = document?.layers.firstIndex(where: { $0.id == layerID }),
              let animation = document?.layers[layerIndex].gifAnimation,
              timing.isValid(for: Set(animation.frameReferences.map(\.index))), timing != animation.timing else { return }
        // A timing edit can stop playback, but must let a pending manual frame selection finish.
        if gifTimelineIsPlaying { pauseGIFForEditing(for: layerID) }
        finishHeldDrags()
        beginEdit("Change GIF Delays")
        document?.layers[layerIndex].gifAnimation?.timing = timing
        endEdit()
    }

    func duplicateGIFFrame(at frameIndex: Int, for layerID: UUID) async {
        guard gifTimelineCanEditFrames, activeLayerID == layerID, let layer = activeLayer,
              let animation = layer.gifAnimation, animation.frames.count < GIFTimelineLimits.maxFrames,
              let position = animation.frameReferences.firstIndex(where: { $0.index == frameIndex }) else { return }
        let references = animation.frameReferences
        let usedIndices = Set(references.map(\.index))
        guard let newIndex = (animation.source.frames.count..<GIFTimelineLimits.frameIdentityLimit)
            .first(where: { !usedIndices.contains($0) }) else { return }
        pauseGIFForEditing(for: layerID)
        await selectGIFTimelineFrame(frameIndex)
        guard !Task.isCancelled, gifTimelineCanEditFrames, activeLayerID == layerID,
              let layerIndex = document?.layers.firstIndex(where: { $0.id == layerID }),
              var current = document?.layers[layerIndex], current.gifAnimation == animation,
              selectedGIFFrameIndex(for: layerID) == frameIndex,
              let asset = displayedAsset(for: current) else { return }
        var edited = animation
        var order = references
        order.insert(GIFFrameReference(index: newIndex, sourceIndex: references[position].sourceIndex), at: position + 1)
        edited.frameOrder = order
        edited.framePixels[newIndex] = animation.framePixels[frameIndex]
        edited.timing.frameDelays[newIndex] = animation.timing.frameDelays[frameIndex]
        edited.selectedFrameIndex = newIndex
        current.gifAnimation = edited
        current.asset = asset
        var layers = document?.layers ?? []
        layers[layerIndex] = current
        guard canRetainGIFSources(in: layers) else {
            brushError = ProjectError.tooLarge.localizedDescription
            return
        }
        finishHeldDrags()
        beginEdit("Duplicate GIF Frame")
        document?.layers[layerIndex] = current
        selectDuplicatedGIFFrame(newIndex, for: current)
        endEdit()
        brushRevision += 1
        refreshCanvasPreview?()
    }

    /// Validate the whole batch and its replacement preview before committing one deletion.
    func deleteGIFFrames(at frameIndices: Set<Int>, for layerID: UUID) async {
        guard !Task.isCancelled, gifTimelineCanEditFrames, activeLayerID == layerID, let layer = activeLayer,
              let animation = layer.gifAnimation, !frameIndices.isEmpty,
              frameIndices.isSubset(of: Set(animation.frameReferences.map(\.index))),
              frameIndices.count < animation.frames.count,
              let selectedIndex = selectedGIFFrameIndex(for: layerID) else { return }
        pauseGIFForEditing(for: layerID)
        let order = animation.frameReferences
        let remaining = order.filter { !frameIndices.contains($0.index) }
        guard let position = order.firstIndex(where: { $0.index == selectedIndex }), let last = remaining.last else { return }
        let nextIndex = frameIndices.contains(selectedIndex)
            ? (order.dropFirst(position + 1).first { !frameIndices.contains($0.index) } ?? last).index : selectedIndex
        // Decode the replacement before editing, so a failed read cannot leave a deleted frame on the canvas.
        await selectGIFTimelineFrame(nextIndex)
        guard !Task.isCancelled, gifTimelineCanEditFrames, activeLayerID == layerID,
              let layerIndex = document?.layers.firstIndex(where: { $0.id == layerID }),
              var current = document?.layers[layerIndex], current.gifAnimation == animation,
              selectedGIFFrameIndex(for: layerID) == nextIndex,
              let asset = displayedAsset(for: current) else { return }
        var edited = animation
        for index in frameIndices {
            if animation.source.frames.indices.contains(index) { edited.deletedFrameIndices.insert(index) }
            edited.framePixels.removeValue(forKey: index)
            edited.timing.frameDelays.removeValue(forKey: index)
        }
        edited.frameOrder?.removeAll { frameIndices.contains($0.index) }
        edited.selectedFrameIndex = nextIndex
        current.gifAnimation = edited
        current.asset = asset
        finishHeldDrags()
        beginEdit(frameIndices.count == 1 ? "Delete GIF Frame" : "Delete GIF Frames")
        document?.layers[layerIndex] = current
        endEdit()
        brushRevision += 1
        refreshCanvasPreview?()
    }

    /// A tool's input is the raw selected frame, without its mask baked in.
    func pixelEditingLayer(for layer: ImageLayer) -> ImageLayer {
        guard layer.gifAnimation != nil else { return layer }
        var editing = layer
        editing.asset = displayedAsset(for: layer)
        editing.gifAnimation = currentGIFAnimation(for: layer)
        return editing
    }

    func pixelEditTargetMatches(_ current: ImageLayer, original: ImageLayer) -> Bool {
        current.transform == original.transform && displayedAsset(for: current)?.image === original.asset?.image
            && (original.gifAnimation == nil || (current.gifAnimation?.source === original.gifAnimation?.source
                && selectedGIFFrameIndex(for: current.id) == original.gifAnimation?.selectedFrameIndex))
    }

    func pixelEditTransformMatches(_ current: ImageLayer, original: ImageLayer) -> Bool {
        pixelEditTransformMatches(current, transform: original.transform)
    }

    func pixelEditTransformMatches(_ current: ImageLayer, transform: LayerTransform) -> Bool {
        current.transform == transform
    }

    /// GIF frames share one logical rectangle. Cropped or grown tool results are placed back on that grid.
    func layerByEditingPixels(_ layer: ImageLayer, asset: ImportedImage, transform: LayerTransform,
                              mask: LayerMask?) throws -> ImageLayer {
        guard var animation = layer.gifAnimation, let index = selectedGIFFrameIndex(for: layer.id) else {
            return ImageLayer(id: layer.id, asset: asset, name: layer.name, isVisible: layer.isVisible,
                transform: transform, parentID: layer.parentID, isGroup: false, opacity: layer.opacity,
                blendMode: layer.blendMode, mask: mask, maskSourceID: layer.maskSourceID, effects: layer.effects)
        }
        let width = animation.geometry?.width ?? animation.source.width
        let height = animation.geometry?.height ?? animation.source.height
        let used = (document?.layers ?? []).reduce(0) { total, candidate in
            total + (candidate.asset.map { $0.image.width * $0.image.height } ?? 0)
                + (candidate.gifAnimation?.framePixels.filter { candidate.id != layer.id || $0.key != index }
                    .values.reduce(0) { $0 + $1.image.width * $1.image.height } ?? 0)
        }
        guard width * height <= DocumentLimits.documentPixelBudget - used else { throw ProjectError.tooLarge }
        let pixels: ImportedImage
        if transform == layer.transform, asset.image.width == width, asset.image.height == height {
            // GIF frame overrides use the animation's 8-bit grid even when pasted from a deep still layer.
            pixels = asset.deep == nil ? asset : ImportedImage(image: asset.image, thumbnail: asset.thumbnail,
                                                              name: asset.name, raster: asset.raster)
        } else {
            let context = try BrushRaster.context(width: width, height: height, mask: false)
            let map = transform.unitToDocument.concatenating(layer.transform.unitToDocument.inverted())
                .concatenating(CGAffineTransform(scaleX: CGFloat(width), y: CGFloat(height)))
            context.concatenate(map)
            BrushRaster.draw(asset.image, in: CGRect(x: 0, y: 0, width: 1, height: 1), mask: false, context: context)
            guard let image = context.makeImage() else { throw ExportError.render }
            pixels = ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: layer.name)
        }
        animation.framePixels[index] = pixels
        var edited = layer
        edited.gifAnimation = animation
        return edited
    }
}
