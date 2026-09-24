import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Compositor

@MainActor
struct VectorPathTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VectorPathTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func pathElements(_ path: CGPath) -> [(type: CGPathElementType, points: [CGPoint])] {
        var elements: [(type: CGPathElementType, points: [CGPoint])] = []
        path.applyWithBlock { elementPtr in
            let element = elementPtr.pointee
            let pointCount: Int
            switch element.type {
            case .moveToPoint, .addLineToPoint: pointCount = 1
            case .addQuadCurveToPoint: pointCount = 2
            case .addCurveToPoint: pointCount = 3
            case .closeSubpath: pointCount = 0
            @unknown default: pointCount = 0
            }
            let pts = (0..<pointCount).map { element.points[$0] }
            elements.append((element.type, pts))
        }
        return elements
    }

    // 1. Empty vector model
    @Test func emptyVectorModel() throws {
        let model = VectorModel()
        #expect(model.subpaths.isEmpty)
        #expect(model.totalAnchorCount == 0)
        #expect(model.isValid)

        let path = VectorBridge.cgPath(from: model)
        #expect(path.isEmpty)
        #expect(pathElements(path).isEmpty)

        let rendered = try VectorRenderer.render(model, in: CGSize(width: 50, height: 50))
        #expect(rendered.width == 50 && rendered.height == 50)
    }

    // 2. Single-anchor subpath
    @Test func singleAnchorSubpath() {
        let point = VectorPoint(anchor: CGPoint(x: 25, y: 35))
        let model = VectorModel(subpaths: [VectorSubpath(points: [point], isClosed: false)])
        #expect(model.totalAnchorCount == 1)
        #expect(model.isValid)

        let path = VectorBridge.cgPath(from: model)
        let elements = pathElements(path)
        #expect(elements.count == 1)
        #expect(elements[0].type == .moveToPoint)
        #expect(elements[0].points[0] == CGPoint(x: 25, y: 35))
    }

    // 3. Open line path
    @Test func openLinePath() {
        let p1 = VectorPoint(anchor: CGPoint(x: 10, y: 10))
        let p2 = VectorPoint(anchor: CGPoint(x: 90, y: 50))
        let model = VectorModel(subpaths: [VectorSubpath(points: [p1, p2], isClosed: false)])

        let path = VectorBridge.cgPath(from: model)
        let elements = pathElements(path)
        #expect(elements.count == 2)
        #expect(elements[0].type == .moveToPoint && elements[0].points[0] == CGPoint(x: 10, y: 10))
        #expect(elements[1].type == .addLineToPoint && elements[1].points[0] == CGPoint(x: 90, y: 50))
    }

    // 4. Closed line path
    @Test func closedLinePath() {
        let p1 = VectorPoint(anchor: CGPoint(x: 10, y: 10))
        let p2 = VectorPoint(anchor: CGPoint(x: 80, y: 10))
        let p3 = VectorPoint(anchor: CGPoint(x: 50, y: 60))
        let model = VectorModel(subpaths: [VectorSubpath(points: [p1, p2, p3], isClosed: true)])

        let path = VectorBridge.cgPath(from: model)
        let elements = pathElements(path)
        #expect(elements.count == 5)
        #expect(elements[0].type == .moveToPoint && elements[0].points[0] == CGPoint(x: 10, y: 10))
        #expect(elements[1].type == .addLineToPoint && elements[1].points[0] == CGPoint(x: 80, y: 10))
        #expect(elements[2].type == .addLineToPoint && elements[2].points[0] == CGPoint(x: 50, y: 60))
        // Final closing segment back to first anchor:
        #expect(elements[3].type == .addLineToPoint && elements[3].points[0] == CGPoint(x: 10, y: 10))
        #expect(elements[4].type == .closeSubpath)
    }

    // 5. Cubic Bézier path
    @Test func cubicBezierPath() {
        let p1 = VectorPoint(anchor: CGPoint(x: 0, y: 0), nextControl: CGPoint(x: 20, y: 40))
        let p2 = VectorPoint(anchor: CGPoint(x: 100, y: 100), previousControl: CGPoint(x: 80, y: 60))
        let model = VectorModel(subpaths: [VectorSubpath(points: [p1, p2], isClosed: false)])

        let path = VectorBridge.cgPath(from: model)
        let elements = pathElements(path)
        #expect(elements.count == 2)
        #expect(elements[0].type == .moveToPoint)
        #expect(elements[1].type == .addCurveToPoint)
        #expect(elements[1].points[0] == CGPoint(x: 20, y: 40)) // control1
        #expect(elements[1].points[1] == CGPoint(x: 80, y: 60)) // control2
        #expect(elements[1].points[2] == CGPoint(x: 100, y: 100)) // destination
    }

    // 6. Missing Bézier handles fallback to anchors
    @Test func missingBezierHandlesFallbackToAnchors() {
        // p1 has nextControl, p2 has NO previousControl
        let p1 = VectorPoint(anchor: CGPoint(x: 10, y: 20), nextControl: CGPoint(x: 30, y: 40))
        let p2 = VectorPoint(anchor: CGPoint(x: 100, y: 80), previousControl: nil)
        let model = VectorModel(subpaths: [VectorSubpath(points: [p1, p2], isClosed: false)])

        let path = VectorBridge.cgPath(from: model)
        let elements = pathElements(path)
        #expect(elements.count == 2)
        #expect(elements[1].type == .addCurveToPoint)
        #expect(elements[1].points[0] == CGPoint(x: 30, y: 40)) // control1 from p1.nextControl
        #expect(elements[1].points[1] == CGPoint(x: 100, y: 80)) // control2 falls back to p2.anchor
        #expect(elements[1].points[2] == CGPoint(x: 100, y: 80)) // destination

        // Inverse: p1 has NO nextControl, p3 has previousControl
        let p3 = VectorPoint(anchor: CGPoint(x: 5, y: 5), nextControl: nil)
        let p4 = VectorPoint(anchor: CGPoint(x: 50, y: 50), previousControl: CGPoint(x: 40, y: 45))
        let model2 = VectorModel(subpaths: [VectorSubpath(points: [p3, p4], isClosed: false)])
        let elements2 = pathElements(VectorBridge.cgPath(from: model2))
        #expect(elements2[1].type == .addCurveToPoint)
        #expect(elements2[1].points[0] == CGPoint(x: 5, y: 5)) // control1 falls back to p3.anchor
        #expect(elements2[1].points[1] == CGPoint(x: 40, y: 45)) // control2 from p4.previousControl
        #expect(elements2[1].points[2] == CGPoint(x: 50, y: 50))
    }

    // 7. Multiple subpaths
    @Test func multipleSubpaths() {
        let subpath1 = VectorSubpath(points: [
            VectorPoint(anchor: CGPoint(x: 0, y: 0)),
            VectorPoint(anchor: CGPoint(x: 10, y: 10))
        ], isClosed: false)

        let subpath2 = VectorSubpath(points: [
            VectorPoint(anchor: CGPoint(x: 20, y: 20)),
            VectorPoint(anchor: CGPoint(x: 40, y: 20)),
            VectorPoint(anchor: CGPoint(x: 30, y: 40))
        ], isClosed: true)

        let model = VectorModel(subpaths: [subpath1, subpath2])
        let elements = pathElements(VectorBridge.cgPath(from: model))

        let moveElements = elements.filter { $0.type == .moveToPoint }
        let closeElements = elements.filter { $0.type == .closeSubpath }
        #expect(moveElements.count == 2)
        #expect(closeElements.count == 1)
    }

    // 8. Open path remains open
    @Test func openPathRemainsOpen() {
        let p1 = VectorPoint(anchor: CGPoint(x: 0, y: 0))
        let p2 = VectorPoint(anchor: CGPoint(x: 50, y: 50))
        let model = VectorModel(subpaths: [VectorSubpath(points: [p1, p2], isClosed: false)])

        let elements = pathElements(VectorBridge.cgPath(from: model))
        #expect(elements.last?.type != .closeSubpath)
    }

    // 9. Closed path closes correctly
    @Test func closedPathClosesCorrectly() {
        let p1 = VectorPoint(anchor: CGPoint(x: 0, y: 0))
        let p2 = VectorPoint(anchor: CGPoint(x: 50, y: 0))
        let model = VectorModel(subpaths: [VectorSubpath(points: [p1, p2], isClosed: true)])

        let elements = pathElements(VectorBridge.cgPath(from: model))
        #expect(elements.last?.type == .closeSubpath)
    }

    // 10. Fill rule behavior
    @Test func fillRuleBehavior() {
        #expect(VectorFillRule.nonZero.cgFillRule == .winding)
        #expect(VectorFillRule.evenOdd.cgFillRule == .evenOdd)

        let fill = VectorFillStyle(color: .white, fillRule: .evenOdd, isEnabled: true)
        #expect(fill.fillRule == .evenOdd)
        #expect(fill.color == .white)
    }

    // 11. Stroke width
    @Test func strokeWidth() {
        let stroke = VectorStrokeStyle(color: .black, width: 4.5)
        #expect(stroke.width == 4.5)
        #expect(stroke.isValid)

        let invalidZero = VectorStrokeStyle(color: .black, width: 0)
        #expect(!invalidZero.isValid)

        let invalidTooLarge = VectorStrokeStyle(color: .black, width: 1500)
        #expect(!invalidTooLarge.isValid)
    }

    // 12. Line cap
    @Test func lineCap() {
        #expect(VectorLineCap.butt.cgCap == .butt)
        #expect(VectorLineCap.round.cgCap == .round)
        #expect(VectorLineCap.square.cgCap == .square)
    }

    // 13. Line join
    @Test func lineJoin() {
        #expect(VectorLineJoin.miter.cgJoin == .miter)
        #expect(VectorLineJoin.round.cgJoin == .round)
        #expect(VectorLineJoin.bevel.cgJoin == .bevel)
    }

    // 14. Miter limit
    @Test func miterLimit() {
        let stroke = VectorStrokeStyle(color: .black, width: 2, miterLimit: 5)
        #expect(stroke.miterLimit == 5)
        #expect(stroke.isValid)

        let invalidLow = VectorStrokeStyle(color: .black, width: 2, miterLimit: 0.5)
        #expect(!invalidLow.isValid)

        let invalidHigh = VectorStrokeStyle(color: .black, width: 2, miterLimit: 200)
        #expect(!invalidHigh.isValid)
    }

    // 15. Codable round-trip
    @Test func codableRoundTrip() throws {
        let p1 = VectorPoint(anchor: CGPoint(x: 10, y: 15), nextControl: CGPoint(x: 25, y: 30))
        let p2 = VectorPoint(anchor: CGPoint(x: 80, y: 90), previousControl: CGPoint(x: 70, y: 65))
        let subpath = VectorSubpath(points: [p1, p2], isClosed: true)
        let fill = VectorFillStyle(color: PaletteColor(red: 0.2, green: 0.4, blue: 0.8), fillRule: .evenOdd, isEnabled: true)
        let stroke = VectorStrokeStyle(color: PaletteColor(red: 1, green: 0, blue: 0), width: 3.5, lineCap: .square, lineJoin: .bevel, miterLimit: 8, isEnabled: true)
        let original = VectorModel(subpaths: [subpath], fill: fill, stroke: stroke)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VectorModel.self, from: data)
        #expect(decoded == original)
    }

    // 16. Validation limits
    @Test func validationLimits() {
        let validPoint = VectorPoint(anchor: CGPoint(x: 100, y: 200))
        #expect(validPoint.isValid)

        let hugeCoord = VectorPoint(anchor: CGPoint(x: 2_000_000, y: 0))
        #expect(!hugeCoord.isValid)

        let subpath = VectorSubpath(points: [validPoint])
        #expect(subpath.isValid)

        let model = VectorModel(subpaths: [subpath])
        #expect(model.isValid)
    }

    // 17. NaN/infinity rejection
    @Test func nanInfinityRejection() {
        let nanPoint = VectorPoint(anchor: CGPoint(x: CGFloat.nan, y: 10))
        #expect(!nanPoint.isValid)

        let infPoint = VectorPoint(anchor: CGPoint(x: 10, y: CGFloat.infinity))
        #expect(!infPoint.isValid)

        let nanControl = VectorPoint(anchor: CGPoint(x: 10, y: 10), nextControl: CGPoint(x: CGFloat.nan, y: 20))
        #expect(!nanControl.isValid)

        let model = VectorModel(subpaths: [VectorSubpath(points: [nanPoint])])
        #expect(!model.isValid)
    }

    // 18. Excessive anchor rejection
    @Test func excessiveAnchorRejection() {
        var points: [VectorPoint] = []
        for i in 0 ..< 10_001 {
            points.append(VectorPoint(anchor: CGPoint(x: CGFloat(i), y: 0)))
        }
        let subpath = VectorSubpath(points: points)
        #expect(!subpath.isValid)

        let model = VectorModel(subpaths: [subpath])
        #expect(!model.isValid)
    }

    // 19. Semantic vector equality independent of raster identity
    @Test func semanticVectorEqualityIndependentOfRasterIdentity() throws {
        let vector = VectorModel(subpaths: [
            VectorSubpath(points: [
                VectorPoint(anchor: CGPoint(x: 0, y: 0)),
                VectorPoint(anchor: CGPoint(x: 50, y: 50))
            ], isClosed: false)
        ])

        let image1 = try VectorRenderer.render(vector, in: CGSize(width: 50, height: 50))
        let thumb1 = try PixelInvert.thumbnail(of: image1)

        let image2 = try VectorRenderer.render(vector, in: CGSize(width: 50, height: 50))
        let thumb2 = try PixelInvert.thumbnail(of: image2)

        #expect(image1 !== image2) // Different pointer identities

        let layer1 = ImageLayer(id: UUID(), asset: ImportedImage(image: image1, thumbnail: thumb1, name: "V1"),
                                name: "Vector 1", isVisible: true,
                                transform: LayerTransform(origin: .zero, size: CGSize(width: 50, height: 50)),
                                vector: vector)

        let layer2 = ImageLayer(id: layer1.id, asset: ImportedImage(image: image2, thumbnail: thumb2, name: "V1"),
                                name: "Vector 1", isVisible: true,
                                transform: LayerTransform(origin: .zero, size: CGSize(width: 50, height: 50)),
                                vector: vector)

        // Semantic vector equality holds:
        #expect(layer1.vector == layer2.vector)

        // Mutating vector makes them unequal:
        var modifiedVector = vector
        modifiedVector.subpaths[0].points[1].anchor = CGPoint(x: 60, y: 60)
        var layer3 = layer2
        layer3.vector = modifiedVector
        #expect(layer1.vector != layer3.vector)
        #expect(layer1 != layer3)
    }

    // 20. Project persistence round-trip
    @Test func projectPersistenceRoundTrip() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let vector = VectorModel(subpaths: [
            VectorSubpath(points: [
                VectorPoint(anchor: CGPoint(x: 10, y: 10), nextControl: CGPoint(x: 20, y: 30)),
                VectorPoint(anchor: CGPoint(x: 80, y: 70), previousControl: CGPoint(x: 60, y: 50))
            ], isClosed: true)
        ], fill: VectorFillStyle(color: .white), stroke: VectorStrokeStyle(color: .black, width: 2))

        let session = EditorSession()
        session.createDocument(width: 100, height: 100, emptyLayer: false)

        let image = try VectorRenderer.render(vector, in: CGSize(width: 100, height: 100))
        session.addPixelLayer(image, at: .zero, name: "Vector Path", editName: "New Vector Layer",
                              dropsSelection: false, vector: vector)

        let snapshot = try #require(session.projectSnapshot())
        let file = root.appendingPathComponent("VectorProject.comp")

        try await ProjectStore.shared.save(snapshot, to: file)
        let loaded = try await ProjectStore.shared.load(from: file)

        let reopened = EditorSession()
        reopened.installProject(loaded, from: file)

        let restoredLayer = try #require(reopened.document?.layers.first { $0.name == "Vector Path" })
        #expect(restoredLayer.vector == vector)
    }

    // 21. Existing document history detects a semantic vector change
    @Test func documentHistoryDetectsSemanticVectorChange() throws {
        let session = EditorSession()
        session.createDocument(width: 100, height: 100, emptyLayer: true)

        let initialVector = VectorModel(subpaths: [
            VectorSubpath(points: [
                VectorPoint(anchor: CGPoint(x: 0, y: 0)),
                VectorPoint(anchor: CGPoint(x: 50, y: 50))
            ])
        ])

        let image = try VectorRenderer.render(initialVector, in: CGSize(width: 50, height: 50))
        session.addPixelLayer(image, at: .zero, name: "Vector 1", editName: "Add Vector",
                              dropsSelection: false, vector: initialVector)

        let countBefore = session.history.undoCount

        // Mutate vector in an edit transaction
        session.beginEdit("Move Anchor")
        session.document?.layers[1].vector?.subpaths[0].points[1].anchor = CGPoint(x: 80, y: 80)
        session.endEdit()

        #expect(session.history.undoCount == countBefore + 1)
        #expect(session.document?.layers[1].vector?.subpaths[0].points[1].anchor == CGPoint(x: 80, y: 80))

        // Undo restores original vector
        session.undo()
        #expect(session.document?.layers[1].vector?.subpaths[0].points[1].anchor == CGPoint(x: 50, y: 50))

        // Redo restores modified vector
        session.redo()
        #expect(session.document?.layers[1].vector?.subpaths[0].points[1].anchor == CGPoint(x: 80, y: 80))
    }
}
