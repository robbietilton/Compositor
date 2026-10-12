import AppKit
import Testing
@testable import Compositor

@MainActor
struct PenToolTests {
    private func makeSession(mode: PenMode = .line) -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 120, height: 100, emptyLayer: true)
        session.selectTool(.pen)
        session.penMode = mode
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        return session
    }

    private func add(_ point: CGPoint, to session: EditorSession, handle: CGPoint? = nil) {
        session.beginPenAnchor(at: point, closeDistance: 0, constrain: false)
        if let handle { session.dragPenHandle(to: handle, constrain: false) }
    }

    @Test func openLineCommitsAsOneLiveVectorLayerAndUndoRemovesIt() {
        let session = makeSession()
        session.penLineWidth = 6
        let count = session.history.undoCount
        add(CGPoint(x: 10, y: 50), to: session)
        add(CGPoint(x: 100, y: 50), to: session)
        #expect(session.finishPen())
        let layer = session.activeLayer
        #expect(layer?.name == "Pen Line 1")
        #expect(layer?.liveVectorPath?.style.mode == .line)
        #expect(layer?.liveVectorPath?.style.closed == false)
        #expect(layer?.liveVectorPath?.style.lineWidth == 6)
        #expect(session.history.undoCount == count + 1)
        session.undo()
        #expect(session.document?.layers.map(\.name) == ["Layer 1"])
    }

    @Test func draggingAnchorsMakesCubicHandlesAndShiftConstrainsThem() {
        let session = makeSession()
        add(CGPoint(x: 20, y: 60), to: session, handle: CGPoint(x: 40, y: 42))
        session.beginPenAnchor(at: CGPoint(x: 90, y: 60), closeDistance: 0, constrain: false)
        session.dragPenHandle(to: CGPoint(x: 73, y: 31), constrain: true)
        let draft = session.penDraft
        #expect(draft?.nodes[0].inHandle == CGPoint(x: 0, y: 78))
        #expect(draft?.nodes[0].outHandle == CGPoint(x: 40, y: 42))
        let last = draft?.nodes[1]
        #expect(abs(abs((last?.outHandle.x ?? 0) - 90) - abs((last?.outHandle.y ?? 0) - 60)) < 0.01)
        #expect(abs((last?.inHandle.x ?? 0) + (last?.outHandle.x ?? 0) - 180) < 0.01)
        #expect(abs((last?.inHandle.y ?? 0) + (last?.outHandle.y ?? 0) - 120) < 0.01)
        #expect(session.finishPen())
        #expect(session.activeLayer?.liveVectorPath?.style.nodes.contains { $0.inHandle != $0.anchor } == true)
    }

    @Test func shapeClosesAtTheFirstAnchorAndFillsItsInterior() async throws {
        let session = makeSession(mode: .shape)
        add(CGPoint(x: 20, y: 20), to: session)
        add(CGPoint(x: 100, y: 20), to: session)
        add(CGPoint(x: 60, y: 80), to: session)
        #expect(session.beginPenAnchor(at: CGPoint(x: 21, y: 20), closeDistance: 4, constrain: false))
        let vector = try #require(session.activeLayer?.liveVectorPath)
        #expect(vector.style.mode == .shape && vector.style.closed && vector.style.nodes.count == 3)
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[(45 * image.width + 60) * 4] > 240)
        #expect(bytes[(45 * image.width + 60) * 4 + 3] > 240)
    }

    @Test func deleteCancelAndToolSwitchLeaveNoPartialLayer() {
        let session = makeSession()
        let count = session.history.undoCount
        add(CGPoint(x: 10, y: 10), to: session)
        add(CGPoint(x: 40, y: 40), to: session)
        session.removeLastPenAnchor()
        #expect(session.penDraft?.nodes.count == 1)
        session.cancelPen()
        #expect(session.penDraft == nil)
        add(CGPoint(x: 10, y: 10), to: session)
        add(CGPoint(x: 40, y: 40), to: session)
        session.selectTool(.brush)
        #expect(session.penDraft == nil && session.history.undoCount == count)
        #expect(session.document?.layers.count == 1)
    }

    @Test func committedLineAddsMovesAndDeletesAnchorsWithUndo() throws {
        let session = makeSession()
        add(CGPoint(x: 10, y: 50), to: session)
        add(CGPoint(x: 100, y: 50), to: session)
        #expect(session.finishPen())
        let before = session.history.undoCount

        let inserted = session.beginPenLineNodeGesture(at: CGPoint(x: 55, y: 50), tolerance: 3)
        #expect(inserted == 1)
        session.movePenLineNode(1, to: CGPoint(x: 55, y: 70))
        session.endPenLineNodeGesture()
        let edited = try #require(session.editablePenLine)
        #expect(edited.vector.style.nodes.count == 3)
        let moved = edited.vector.style.nodes[1].anchor.applying(edited.layer.transform.unitToDocument)
        #expect(abs(moved.x - 55) < 0.01 && abs(moved.y - 70) < 0.01)
        #expect(session.history.undoCount == before + 1)

        #expect(session.deleteSelectedPenNode())
        #expect(session.activeLayer?.liveVectorPath?.style.nodes.count == 2)
        session.undo()
        #expect(session.activeLayer?.liveVectorPath?.style.nodes.count == 3)
        session.undo()
        #expect(session.activeLayer?.liveVectorPath?.style.nodes.count == 2)
    }

    @Test func committedLineWidthRedrawsWithoutMovingItsAnchors() throws {
        let session = makeSession()
        add(CGPoint(x: 10, y: 50), to: session)
        add(CGPoint(x: 100, y: 50), to: session)
        #expect(session.finishPen())
        let original = try #require(session.editablePenLine)
        let originalHeight = try #require(session.activeLayer?.asset?.image.height)
        let originalPoints = original.vector.style.nodes.map { $0.anchor.applying(original.layer.transform.unitToDocument) }

        session.beginPenLineWidthEdit()
        session.setPenLineWidth(30)
        session.finishPenLineWidthEdit()
        let changed = try #require(session.editablePenLine)
        #expect(changed.vector.style.lineWidth == 30)
        #expect(try #require(session.activeLayer?.asset?.image.height) > originalHeight)
        let changedPoints = changed.vector.style.nodes.map { $0.anchor.applying(changed.layer.transform.unitToDocument) }
        #expect(zip(originalPoints, changedPoints).allSatisfy {
            abs($0.x - $1.x) < 0.01 && abs($0.y - $1.y) < 0.01
        })
        session.undo()
        #expect(session.activeLayer?.liveVectorPath?.style.lineWidth == 4)
    }

    @Test func committedLineUsesBoundedRasterWhileAnAnchorGestureIsLive() throws {
        let session = EditorSession()
        session.createDocument(width: 5_000, height: 1_200, emptyLayer: true)
        session.selectTool(.pen)
        session.penMode = .line
        add(CGPoint(x: 10, y: 10), to: session)
        add(CGPoint(x: 4_990, y: 1_190), to: session)
        #expect(session.finishPen())
        #expect(try #require(session.activeLayer?.asset?.image.width) > Int(EditorSession.maxInteractivePenSide))

        #expect(session.beginPenLineNodeGesture(at: CGPoint(x: 2_500, y: 600), tolerance: 3) == 1)
        let preview = try #require(session.activeLayer?.asset?.image)
        #expect(max(preview.width, preview.height) <= Int(EditorSession.maxInteractivePenSide))
        session.endPenLineNodeGesture()
        let committed = try #require(session.activeLayer?.asset?.image)
        #expect(max(committed.width, committed.height) > Int(EditorSession.maxInteractivePenSide))
    }

    @Test func switchingLayersFinalizesAnInteractivePenRaster() throws {
        let session = EditorSession()
        session.createDocument(width: 5_000, height: 1_200, emptyLayer: true)
        let background = try #require(session.activeLayerID)
        session.selectTool(.pen)
        session.penMode = .line
        add(CGPoint(x: 10, y: 10), to: session)
        add(CGPoint(x: 4_990, y: 1_190), to: session)
        #expect(session.finishPen())
        let lineID = try #require(session.activeLayerID)

        session.beginPenLineWidthEdit()
        session.setPenLineWidth(20)
        let preview = try #require(session.activeLayer?.asset?.image)
        #expect(max(preview.width, preview.height) <= Int(EditorSession.maxInteractivePenSide))
        session.selectLayer(background)

        let line = try #require(session.document?.layers.first { $0.id == lineID })
        #expect(max(try #require(line.asset?.image.width), try #require(line.asset?.image.height))
            > Int(EditorSession.maxInteractivePenSide))
        #expect(!session.penLineWidthEditing)
    }

    @Test func vectorRasterRejectsNonFiniteOrOversizedSurfaces() {
        let style = LayerVectorPathStyle(mode: .line,
            nodes: [VectorPathNode(anchor: .zero), VectorPathNode(anchor: CGPoint(x: 1, y: 1))],
            closed: false, red: 1, green: 0, blue: 0, lineWidth: 4)
        #expect(throws: (any Error).self) {
            try EditorSession.vectorPathImage(style, size: CGSize(width: CGFloat.infinity, height: 10))
        }
        #expect(throws: (any Error).self) {
            try EditorSession.vectorPathImage(style,
                size: CGSize(width: CGFloat(DocumentLimits.maxSide + 1), height: 10))
        }
    }

    @Test func vectorMetadataRoundTripsAndTransformRedrawsIt() async throws {
        let session = makeSession()
        add(CGPoint(x: 10, y: 20), to: session, handle: CGPoint(x: 30, y: 0))
        add(CGPoint(x: 90, y: 70), to: session, handle: CGPoint(x: 70, y: 90))
        #expect(session.finishPen())
        let before = try #require(session.activeLayer?.asset?.image)
        let snapshot = try #require(session.projectSnapshot())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pen-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.version == ProjectManifest.current)
        #expect(loaded.documentLayers.last?.liveVectorPath?.style == session.activeLayer?.liveVectorPath?.style)

        session.beginTransform()
        var transform = try #require(session.transformEdit?.draft)
        transform.size.width *= 1.5
        transform.size.height *= 1.5
        session.previewTransform(transform)
        session.commitTransform()
        #expect(session.activeLayer?.liveVectorPath != nil)
        #expect(session.activeLayer?.asset?.image !== before)
    }
}
