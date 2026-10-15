import CoreGraphics
import Foundation
import Testing
@testable import Compositor

@MainActor
struct VectorPathGeometryTests {
    @Test func straightPathProvidesArcLengthAndOrientationForText() throws {
        let nodes = [
            VectorPathNode(anchor: CGPoint(x: 10, y: 20)),
            VectorPathNode(anchor: CGPoint(x: 110, y: 20))
        ]
        let geometry = try #require(VectorPathGeometry(nodes: nodes, closed: false))
        #expect(abs(geometry.length - 100) < 0.001)

        let sample = try #require(geometry.sample(atFraction: 0.5))
        #expect(hypot(sample.position.x - 60, sample.position.y - 20) < 0.001)
        #expect(abs(sample.tangent.dx - 1) < 0.001)
        #expect(abs(sample.tangent.dy) < 0.001)
        #expect(abs(sample.normal.dx) < 0.001)
        #expect(abs(sample.normal.dy - 1) < 0.001)
    }

    @Test func textPlacementOffsetsAndReversesWithoutOwningTypography() throws {
        let id = UUID()
        let geometry = try #require(VectorPathGeometry(nodes: [
            VectorPathNode(anchor: CGPoint(x: 0, y: 0)),
            VectorPathNode(anchor: CGPoint(x: 100, y: 0))
        ], closed: false))
        let placement = TextPathPlacement(pathLayerID: id, startOffset: 0.75,
                                          baselineOffset: 8, side: .right, reversed: true)
        let sample = try #require(geometry.sample(for: placement, advance: 25))
        #expect(hypot(sample.position.x - 50, sample.position.y - 8) < 0.001)
        #expect(abs(sample.tangent.dx + 1) < 0.001)
        #expect(abs(sample.angle - .pi) < 0.001 || abs(sample.angle + .pi) < 0.001)
    }

    @Test func editorExposesTransformedPathByStableLayerID() throws {
        let session = EditorSession()
        session.createDocument(width: 200, height: 160, emptyLayer: true)
        session.selectTool(.pen)
        _ = session.beginPenAnchor(at: CGPoint(x: 20, y: 30), closeDistance: 2, constrain: false)
        _ = session.beginPenAnchor(at: CGPoint(x: 120, y: 30), closeDistance: 2, constrain: false)
        #expect(session.finishPen())
        let id = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex(where: { $0.id == id }))
        session.document?.layers[index].transform.rotation = 90

        let geometry = try #require(session.textPathGeometry(for: id))
        #expect(abs(geometry.length - 100) < 0.01)
        let placement = try #require(session.textPathPlacement(for: id, startOffset: 0.5, baselineOffset: 10))
        #expect(placement.pathLayerID == id)
        #expect(geometry.sample(for: placement) != nil)
        #expect(session.textPathPlacement(for: UUID()) == nil)
    }

    @Test func closedPathWrapsAndProjectsTextMarkers() throws {
        let geometry = try #require(VectorPathGeometry(nodes: [
            VectorPathNode(anchor: CGPoint(x: 0, y: 0)),
            VectorPathNode(anchor: CGPoint(x: 100, y: 0)),
            VectorPathNode(anchor: CGPoint(x: 100, y: 100)),
            VectorPathNode(anchor: CGPoint(x: 0, y: 100))
        ], closed: true))
        #expect(abs(geometry.length - 400) < 0.01)
        let wrapped = try #require(geometry.sample(atDistance: 450))
        #expect(hypot(wrapped.position.x - 50, wrapped.position.y) < 0.01)
        let nearest = try #require(geometry.nearestFraction(to: CGPoint(x: 98, y: 48)))
        #expect(abs(nearest - 0.37) < 0.02)
    }
}
