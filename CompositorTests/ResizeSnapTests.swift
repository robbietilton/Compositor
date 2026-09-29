import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Resizing a layer by its handles snaps the edges it drags to the canvas and the other layers, as moving does.
@MainActor
struct ResizeSnapTests {
    /// A 300 × 200 canvas: the layer being resized, 100 × 100 at (10, 10), and another whose left edge is at x 150.
    private func session() throws -> (EditorSession, layer: UUID) {
        let session = EditorSession()
        session.createDocument(width: 300, height: 200)
        let image = try #require(try BrushRaster.context(width: 20, height: 20, mask: false).makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Other"))
        let other = try #require(session.document?.layers.firstIndex { $0.id == session.activeLayerID })
        session.document?.layers[other].transform = LayerTransform(origin: CGPoint(x: 150, y: 150), size: CGSize(width: 40, height: 40))
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Resized"))
        let index = try #require(session.document?.layers.firstIndex { $0.id == session.activeLayerID })
        session.document?.layers[index].transform = LayerTransform(origin: CGPoint(x: 10, y: 10), size: CGSize(width: 100, height: 100))
        return (session, try #require(session.activeLayerID))
    }

    private func resize(_ session: EditorSession, layer: UUID, handle: Int, from start: CGPoint, to point: CGPoint,
                        lockRatio: Bool) throws -> LayerTransform {
        let original = try #require(session.document?.layers.first { $0.id == layer }?.transform)
        let drag = TransformDrag(original: original, start: start, mode: .resize(handle))
        let snapped = session.snappedResizePoint(point, drag: drag, proportional: lockRatio, moving: [layer], tolerance: 5) {
            drag.updated(to: $0, lockRatio: lockRatio, shift: false)
        }
        return drag.updated(to: snapped, lockRatio: lockRatio, shift: false).rounded()
    }

    @Test func aSideHandleSnapsItsEdge() throws {
        let (session, layer) = try session()
        // The right edge dragged to 147, three pixels short of the other layer's left edge.
        let result = try resize(session, layer: layer, handle: 3, from: CGPoint(x: 110, y: 60), to: CGPoint(x: 147, y: 60), lockRatio: false)
        #expect(result.origin.x + result.size.width == 150)
        #expect(result.size.height == 100, "only the dragged edge moves")
        // Out of reach, it doesn't.
        let free = try resize(session, layer: layer, handle: 3, from: CGPoint(x: 110, y: 60), to: CGPoint(x: 130, y: 60), lockRatio: false)
        #expect(free.origin.x + free.size.width == 130)
    }

    @Test func aProportionalCornerSnapsItsNearerEdgeAndKeepsTheRatio() throws {
        let (session, layer) = try session()
        // Bottom right dragged toward (148, 146): the bottom edge is nearer 150 than the right edge is.
        let result = try resize(session, layer: layer, handle: 4, from: CGPoint(x: 110, y: 110), to: CGPoint(x: 146, y: 148), lockRatio: true)
        #expect(result.origin.y + result.size.height == 150)
        #expect(abs(result.size.width - result.size.height) <= 1, "still square: \(result.size)")
    }

    @Test func aTurnedLayerDoesntSnap() throws {
        let (session, layer) = try session()
        let index = try #require(session.document?.layers.firstIndex { $0.id == layer })
        session.document?.layers[index].transform.rotation = 20
        let original = try #require(session.document?.layers[index].transform)
        let drag = TransformDrag(original: original, start: CGPoint(x: 110, y: 60), mode: .resize(3))
        let point = CGPoint(x: 147, y: 60)
        #expect(session.snappedResizePoint(point, drag: drag, proportional: false, moving: [layer], tolerance: 5) {
            drag.updated(to: $0, lockRatio: false, shift: false)
        } == point)
    }
}
