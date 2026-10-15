import CoreGraphics
import Foundation
import Observation

/// One neighboring frame for the canvas. Source pixels stay separate from document edits and export.
@MainActor @Observable
final class GIFOnionSkinPreview {
    enum Direction: String, CaseIterable {
        case previous = "Previous frame"
        case next = "Next frame"
    }

    var isEnabled = false
    var opacity = 0.25
    var direction = Direction.previous

    nonisolated struct Request: Equatable, Sendable {
        let layerID: UUID
        let sourceID: ObjectIdentifier
        let geometry: GIFFrameGeometry?
        let frameIndex: Int
        let sourceFrameIndex: Int
    }
    @ObservationIgnored private var request: Request?
    @ObservationIgnored private var sourceAsset: ImportedImage?
    @ObservationIgnored private var decode: Task<Void, Never>?
    @ObservationIgnored private var decodeID: UUID?
    @ObservationIgnored private var attemptedDecode = false
    private struct MaskKey: Equatable {
        let frame: LayerMask
        let shared: LayerMask?
        let transform: LayerTransform
        let placement: LayerTransform?
        let width: Int
        let height: Int
    }
    @ObservationIgnored private var combinedMask: (key: MaskKey, mask: LayerMask)?

    func clear() {
        decode?.cancel()
        decode = nil
        decodeID = nil
        request = nil
        sourceAsset = nil
        attemptedDecode = false
        combinedMask = nil
    }

    @discardableResult
    func update(for session: EditorSession, completion: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        guard let wanted = requestedFrame(in: session), let layer = session.activeLayer,
              var animation = layer.gifAnimation else { clear(); return nil }
        if request != wanted {
            clear()
            request = wanted
        }
        guard sourceAsset == nil, animation.framePixels[wanted.frameIndex] == nil,
              decode == nil, !attemptedDecode else { return decode }
        attemptedDecode = true
        // The worker needs immutable source bytes and geometry, rather than retaining every edited frame.
        animation.framePixels = [:]
        let name = layer.name, id = UUID()
        decodeID = id
        decode = Task { [weak self] in
            let asset = try? await ImageImporter.shared.decodeGIFFrame(animation, index: wanted.frameIndex, name: name)
            guard !Task.isCancelled, let self, self.decodeID == id else { return }
            self.decode = nil
            self.decodeID = nil
            guard self.requestedFrame(in: session) == wanted else {
                self.clear()
                completion()
                return
            }
            self.sourceAsset = asset
            completion()
        }
        return decode
    }

    func requestedFrame(in session: EditorSession) -> Request? {
        guard isEnabled, !session.gifTimelineIsPlaying, !session.viewsMaskAlone,
              let layer = session.activeLayer, let animation = layer.gifAnimation,
              let position = animation.frameReferences.firstIndex(where: { $0.index == session.gifTimelineSelectedFrameIndex }) else { return nil }
        let neighborPosition = position + (direction == .previous ? -1 : 1)
        guard animation.frameReferences.indices.contains(neighborPosition) else { return nil }
        let neighbor = animation.frameReferences[neighborPosition]
        return Request(layerID: layer.id, sourceID: ObjectIdentifier(animation.source), geometry: animation.geometry,
                       frameIndex: neighbor.index, sourceFrameIndex: neighbor.sourceIndex)
    }

    func layer(in session: EditorSession) -> ImageLayer? {
        guard let wanted = requestedFrame(in: session), request == wanted,
              var layer = session.activeLayer,
              let asset = layer.gifAnimation?.framePixels[wanted.frameIndex] ?? sourceAsset else { return nil }
        // Resolve linked coverage from the original placement before applying the pending transform.
        let placement = session.displayedSharedMaskPlacement(for: layer)
        layer.asset = asset
        layer.transform = session.displayedTransform(for: layer)
        layer.mask?.placement = placement
        if let frame = layer.gifFrameMasks[wanted.frameIndex], frame.isEnabled {
            if layer.mask?.isEnabled == true {
                let key = MaskKey(frame: frame, shared: layer.mask, transform: layer.transform, placement: placement,
                                  width: asset.image.width, height: asset.image.height)
                if combinedMask?.key != key {
                    combinedMask = LayerMask.combining(frame, with: layer.mask, layerTransform: layer.transform,
                        sharedPlacement: placement, width: asset.image.width, height: asset.image.height).map { (key, $0) }
                }
                layer.mask = combinedMask?.mask ?? frame
            } else { layer.mask = frame }
        } else if layer.mask != nil {
            layer.mask?.placement = placement
        }
        layer.gifAnimation = nil
        layer.gifFrameMasks = [:]
        return layer
    }

    /// A clipped frame's preview sits above its whole stack, leaving the stack's real alpha unchanged.
    static func anchor(for layerID: UUID, in document: CanvasDocument) -> UUID {
        let layers = document.renderLayers
        for (position, base) in layers.enumerated() where base.maskSourceID == nil && base.adjustment == nil {
            for child in layers.dropFirst(position + 1) {
                guard child.maskSourceID == base.id, child.parentID == base.parentID else { break }
                if child.id == layerID { return base.id }
            }
        }
        return layerID
    }
}
